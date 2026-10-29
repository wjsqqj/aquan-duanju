/// 播放诊断：mpv 日志环形缓冲 + 脱敏 + 可复制的诊断文本。
///
/// 设计原则：
/// - 原始错误只用于排查，不直接展示给用户（见 playback_failure.dart）；
/// - 诊断文本里 URL 与请求头中的 token/auth/sign/secret/expire 等敏感字段、
///   以及 CENC 的 `decryption_key` 一律打码——复制是用户主动行为，但文本
///   仍不应携带可复用的密钥；
/// - 全部为纯函数 / 独立数据结构，单测直接钉住。
library;

/// 敏感字段名：命中（不区分大小写）的 query 参数 / 请求头，其值整体打码。
final RegExp sensitiveFieldPattern = RegExp(
  r'(token|auth|key|sign|secret|pwd|password|credential|expire|decryption)',
  caseSensitive: false,
);

/// 引擎日志环形缓冲（固定容量，超出丢最旧）。
class RecentLogBuffer {
  RecentLogBuffer({this.capacity = 40});

  final int capacity;
  final List<String> _entries = [];

  List<String> get entries => List.unmodifiable(_entries);
  int get length => _entries.length;
  bool get isEmpty => _entries.isEmpty;

  void add(String line) {
    final text = line.trimRight();
    if (text.isEmpty) return;
    _entries.add(text);
    final overflow = _entries.length - capacity;
    if (overflow > 0) _entries.removeRange(0, overflow);
  }

  void clear() => _entries.clear();
}

/// URL 脱敏：隐藏 userinfo（`user:pass@`）、敏感 query 值与内联的
/// `decryption_key`；其余（id、清晰度等排查必需信息）保持原样。
///
/// 字符串级替换（不走 Uri.replace）：不改动 URL 其余部分、不做百分号
/// 重编码，也不受非常规地址形态影响。
String maskSensitiveUrl(String url) {
  var result = url;
  result = result.replaceAllMapped(
    RegExp(
      r'([?&](?:token|auth|key|sign|secret|pwd|password|credential|expire|decryption)[^=&#]*=)[^&#]*',
      caseSensitive: false,
    ),
    (match) => '${match.group(1)}***',
  );
  result = result.replaceAllMapped(
    RegExp(r'^([a-zA-Z][a-zA-Z0-9+.-]*://)[^/@]+@'),
    (match) => '${match.group(1)}***@',
  );
  result = result.replaceAllMapped(
    RegExp(r'(decryption_key\s*=\s*)[0-9a-fA-F]{16,}'),
    (match) => '${match.group(1)}***',
  );
  return result;
}

/// 请求头脱敏：只对敏感名（Authorization / Cookie / 带 token 的自定义头）打码；
/// Referer / User-Agent 保留——它们是排查防盗链问题的关键线索。
Map<String, String> maskSensitiveHeaders(Map<String, String>? headers) {
  if (headers == null || headers.isEmpty) return const {};
  return {
    for (final entry in headers.entries)
      entry.key: sensitiveFieldPattern.hasMatch(entry.key)
          ? '***'
          : entry.value,
  };
}

/// 日志脱敏：把日志里出现的完整地址替换为脱敏版，并抹掉敏感请求头的值
/// （mpv 日志会打印打开的 URL、部分请求头与 decryption_key）。
List<String> maskLogLines(
  List<String> lines, {
  String? rawUrl,
  String? maskedUrl,
  Map<String, String>? rawHeaders,
}) {
  final keyPattern = RegExp(r'(decryption_key\s*[=:]\s*)[0-9a-fA-F]{16,}');
  var result = [
    for (final line in lines)
      line.replaceAllMapped(keyPattern, (m) => '${m.group(1)}***'),
  ];
  if (rawUrl != null && rawUrl.isNotEmpty && maskedUrl != null) {
    result = [for (final line in result) line.replaceAll(rawUrl, maskedUrl)];
  }
  if (rawHeaders != null) {
    for (final entry in rawHeaders.entries) {
      if (sensitiveFieldPattern.hasMatch(entry.key) &&
          entry.value.length >= 4) {
        result = [
          for (final line in result) line.replaceAll(entry.value, '***'),
        ];
      }
    }
  }
  return result;
}

/// 对任意单段文本做「URL + 敏感头值」脱敏（原始错误 / 日志行复用）。
String maskDiagnosticText(
  String text, {
  String? rawUrl,
  String? maskedUrl,
  Map<String, String>? rawHeaders,
}) => maskLogLines(
  [text],
  rawUrl: rawUrl,
  maskedUrl: maskedUrl,
  rawHeaders: rawHeaders,
).first;

/// 拼装「复制诊断」文本。所有 URL / 请求头先脱敏；日志中的完整地址、
/// 敏感请求头值与 decryption_key 也会被替换。
String buildPlaybackDiagnosticText({
  required String? rawError,
  required List<String> engineLogs,
  String? url,
  Map<String, String>? headers,
  String? title,
  int? episodeNumber,
  String? episodeTitle,
  String? quality,
  DateTime? now,
}) {
  final maskedUrl = url == null ? null : maskSensitiveUrl(url);
  final maskedHeaders = maskSensitiveHeaders(headers);
  final logs = maskLogLines(
    engineLogs,
    rawUrl: url,
    maskedUrl: maskedUrl,
    rawHeaders: headers,
  );
  final buffer = StringBuffer('[阿圈短剧] 播放诊断信息')..writeln();
  buffer.writeln('时间: ${(now ?? DateTime.now()).toIso8601String()}');
  if (title != null && title.isNotEmpty) {
    buffer.writeln('影片: $title');
  }
  if (episodeNumber != null) {
    final epTitle = (episodeTitle ?? '').trim();
    buffer.writeln(
      '分集: 第$episodeNumber集${epTitle.isEmpty ? '' : ' · $epTitle'}',
    );
  }
  if (quality != null && quality.isNotEmpty) {
    buffer.writeln('清晰度: $quality');
  }
  final raw = rawError?.trim() ?? '';
  buffer.writeln(
    '原始错误: ${raw.isEmpty ? '(空)' : maskDiagnosticText(raw, rawUrl: url, maskedUrl: maskedUrl, rawHeaders: headers)}',
  );
  buffer.writeln('地址: ${maskedUrl ?? '(无)'}');
  if (maskedHeaders.isEmpty) {
    buffer.writeln('请求头: (无)');
  } else {
    buffer.writeln('请求头:');
    for (final entry in maskedHeaders.entries) {
      buffer.writeln('  ${entry.key}: ${entry.value}');
    }
  }
  buffer.writeln('引擎日志（最近 ${logs.length} 条）:');
  if (logs.isEmpty) {
    buffer.writeln('  (无)');
  } else {
    for (final line in logs) {
      buffer.writeln('  $line');
    }
  }
  return buffer.toString();
}
