/// 影视源封面 URL 归一：相对路径补全 + 源级 Referer。
///
/// CMS / spider 源的 `vod_pic` 常见相对路径（`/upload/x.jpg`）或协议相对
/// （`//img.host/x.jpg`）：原样塞给 `Image.network` 必然是裂图
/// （索尼影视类源的主诉）。补全基准统一取源 api 的域名。
library;

/// 封面相对路径补全：`/path` 与 `//host/path` 以源 api 为基准。
String absoluteCoverUrl(String raw, String api) {
  // XML 的 <pic> 可能带格式化空白；既有实现会原样发出，这里统一清理。
  final url = raw.trim();
  if (url.isEmpty || url.startsWith('http://') || url.startsWith('https://')) {
    return url;
  }
  try {
    if (url.startsWith('//')) return 'https:$url';
    final base = Uri.tryParse(api);
    if (base == null || !base.hasScheme) return url;
    return base.resolve(url).toString();
  } catch (_) {
    return url;
  }
}

/// 源 api 的 origin（`scheme://host[:port]/`），用于补 `Referer`；非法返回 null。
///
/// 用 host + port 而不是 authority：源 api 可能带 `user:pass@`，
/// 凭据不能随 Referer 发给图床（同 `playback_diagnostics.dart` 的脱敏口径）。
String? coverRefererOf(String api) {
  if (api.isEmpty) return null;
  try {
    final base = Uri.tryParse(api);
    if (base == null || !base.hasScheme || base.host.isEmpty) return null;
    final port = base.hasPort ? ':${base.port}' : '';
    return '${base.scheme}://${base.host}$port/';
  } catch (_) {
    return null;
  }
}

/// 合并封面请求头：大小写不敏感，`Referer` 优先源配置、其次 [referer] 参数。
///
/// 旧实现只认大写 `User-Agent`，源配置写成小写时会同时发默认 UA 与源 UA，
/// 部分图床直接 403；这里统一成单键。
Map<String, String> mergeCoverHeaders(
  Map<String, String> headers, {
  String? referer,
  required String defaultUa,
}) {
  final merged = <String, String>{};
  String? sourceReferer;
  for (final entry in headers.entries) {
    switch (entry.key.toLowerCase()) {
      case 'user-agent':
        merged['User-Agent'] = entry.value;
      case 'referer':
        sourceReferer = entry.value;
      default:
        merged[entry.key] = entry.value;
    }
  }
  if (!merged.containsKey('User-Agent')) merged['User-Agent'] = defaultUa;
  final effective =
      (sourceReferer != null && sourceReferer.trim().isNotEmpty)
          ? sourceReferer
          : referer;
  if (effective != null && effective.trim().isNotEmpty) {
    merged['Referer'] = effective;
  }
  return merged;
}
