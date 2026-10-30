/// WebSocket 报文的编解码（全纯函数，不碰网络）。
///
/// 逐字节对齐说明书 §3/§4：
/// - `speech.config`：**无 `X-RequestId`**、无 `Content-Length`，头部区以 `\r\n\r\n`
///   结束，**JSON body 之后还有一个 `\r\n`**；`wordBoundaryEnabled` /
///   `sentenceBoundaryEnabled` 是**字符串** `"true"/"false"`（不是 JSON 布尔），
///   并且二者互斥；
/// - `ssml`：`X-Timestamp` 末尾**多一个 `Z`**（源码注释「This is not a mistake,
///   Microsoft Edge bug」），body 之后**不再**加 `\r\n`；
/// - 二进制音频帧：`hl = (f[0]<<8)|f[1]`，头部区 = `f[2 .. 2+hl]`，音频从 `2+hl`
///   开始（比上游更干净：上游把两字节长度前缀也算进头部，第一行 key 被污染）；
/// - 文本帧若**没有** `\r\n\r\n`：显式按心跳/无头帧处理，绝不复刻 Python 的
///   `find → -1 → 负索引切片`。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'edge_constants.dart';
import 'edge_ssml.dart';

/// 已知 `Path`（`communicate.py:485-501`）。
enum EdgePath {
  audio,
  audioMetadata,
  turnStart,
  turnEnd,
  response,

  /// 说明书 §4.1 之外的路径：上游抛 `UnknownResponse`。本实现**不中断**，
  /// 只记进诊断（协议漂移要在「一帧音频都没收到」时才升级为异常，见 `edge_stream`）。
  unknown,

  /// 文本帧里没有 `\r\n\r\n`：心跳/无头帧。
  heartbeat,
}

/// 一帧解析结果。
class EdgeFrame {
  const EdgeFrame({
    required this.path,
    required this.headers,
    required this.body,
    this.unknownPath = '',
  });

  final EdgePath path;
  final Map<String, String> headers;

  /// 文本帧是 JSON/字符串正文，二进制帧是音频字节。
  final Uint8List body;

  /// `path == EdgePath.unknown` 时的原始值，用于诊断信息。
  final String unknownPath;

  bool get isAudio => path == EdgePath.audio;
  bool get isMetadata => path == EdgePath.audioMetadata;
  bool get isTurnEnd => path == EdgePath.turnEnd;
  bool get isHeartbeat => path == EdgePath.heartbeat;

  @override
  String toString() =>
      'EdgeFrame(${path.name}, headers=${headers.length}, '
      'body=${body.length})';
}

/// 报文级异常（帧结构不对）。由 `edge_stream` 归到 `TtsErrorCode.emptyAudio`
/// 或 `transport`，不在解析层决定用户可见文案。
class EdgeFrameException implements Exception {
  const EdgeFrameException(this.message);
  final String message;

  @override
  String toString() => 'EdgeFrameException: $message';
}

/// `speech.config` 帧（`communicate.py:431-440`）。
///
/// [timestamp] 由调用方注入（[jsStyleDate]），保证本函数可被逐字节断言。
String encodeConfigFrame({
  required bool wordBoundary,
  required String timestamp,
}) {
  final wd = wordBoundary ? 'true' : 'false';
  final sq = wordBoundary ? 'false' : 'true';
  return 'X-Timestamp:$timestamp\r\n'
      'Content-Type:application/json; charset=utf-8\r\n'
      'Path:speech.config\r\n\r\n'
      '{"context":{"synthesis":{"audio":{"metadataoptions":{'
      '"sentenceBoundaryEnabled":"$sq","wordBoundaryEnabled":"$wd"'
      '},"outputFormat":"$kEdgeOutputFormat"}}}}\r\n';
}

/// `ssml` 帧（`communicate.py:304-318`）。注意时间戳后的 `Z` 与 body 后无 `\r\n`。
String encodeSsmlFrame({
  required String requestId,
  required String timestamp,
  required String ssml,
}) =>
    'X-RequestId:$requestId\r\n'
    'Content-Type:application/ssml+xml\r\n'
    'X-Timestamp:${timestamp}Z\r\n' // 不是笔误：微软的 bug。
    'Path:ssml\r\n\r\n'
    '$ssml';

/// 头部区与正文的分隔符。
const String _headBodySep = '\r\n\r\n';

/// 解析文本帧。
///
/// 没有 `\r\n\r\n` 的帧**显式**按心跳处理：上游是 `find(...)` 拿到 -1 之后继续
/// 做负索引切片（`communicate.py:425-447`），行为诡异且不可依赖，这里不复刻。
EdgeFrame decodeTextFrame(String raw) {
  final split = raw.indexOf(_headBodySep);
  if (split < 0) {
    return EdgeFrame(
      path: EdgePath.heartbeat,
      headers: const <String, String>{},
      body: Uint8List.fromList(utf8.encode(raw)),
    );
  }
  final head = raw.substring(0, split);
  final bodyStart = _skipBodyNewline(raw, split + 4);
  final headers = parseHeaderLines(head);
  final body = utf8.encode(raw.substring(bodyStart));
  return EdgeFrame(
    path: _pathOf(headers),
    headers: headers,
    body: Uint8List.fromList(body),
    unknownPath: headers['Path'] ?? '',
  );
}

/// 解析二进制（音频）帧：返回头部与**音频字节**。
///
/// 越界判据 `hl > f.length - 2`（上游写的是 `hl > f.length`，宽了两个字节，
/// 会让「头部区盖住 body」的坏帧被放行）。
EdgeFrame decodeBinaryFrame(Uint8List frame) {
  if (frame.length < 2) {
    throw const EdgeFrameException('binary message missing header length');
  }
  final hl = (frame[0] << 8) | frame[1];
  if (hl > frame.length - 2) {
    throw const EdgeFrameException('header length overruns frame');
  }
  final head = String.fromCharCodes(frame.sublist(2, 2 + hl));
  final body = Uint8List.fromList(frame.sublist(2 + hl));
  final headers = parseHeaderLines(head);
  return EdgeFrame(
    path: _pathOf(headers),
    headers: headers,
    body: body,
    unknownPath: headers['Path'] ?? '',
  );
}

/// 头部行解析：按**第一个** `:` 切（值里可以有冒号），不做大小写折叠。
///
/// 上游不 trim；服务端也不发 `Key: Value` 的空格形式，但 readest 的测试桩带空格
/// 照样能解析（说明书 §4 末）。这里容错 trim，只影响比较、不影响发出去的报文。
Map<String, String> parseHeaderLines(String head) {
  final headers = <String, String>{};
  for (final line in head.split('\r\n')) {
    if (line.isEmpty) continue;
    final colon = line.indexOf(':');
    if (colon <= 0) continue;
    headers[line.substring(0, colon).trim()] = line.substring(colon + 1).trim();
  }
  return headers;
}

/// 一个 boundary（`WordBoundary` / `SentenceBoundary`）。
class EdgeBoundary {
  const EdgeBoundary({
    required this.type,
    required this.offsetTicks,
    required this.durationTicks,
    required this.text,
  });

  final String type;

  /// 100 纳秒 tick，相对**本次请求**音频流起点（每个 chunk 都从 0 开始）。
  final int offsetTicks;
  final int durationTicks;
  final String text;

  int get offsetMs => offsetTicks ~/ kEdgeTickDivisor;
  int get durationMs => durationTicks ~/ kEdgeTickDivisor;

  @override
  String toString() =>
      'EdgeBoundary($type, +$offsetMs ms, $durationMs ms, "$text")';
}

/// 解析 `audio.metadata` 正文，**全量**收集所有 boundary。
///
/// 有意偏离上游：`__parse_metadata`（`communicate.py:386-403`）在 `for` 里直接
/// `return` 第一个 boundary，一帧带多个条目时其余被丢弃；中文场景一帧常带多条
/// （readest 是循环收集全部）。丢条目的代价是**高亮跳字**，比多收的代价大得多，
/// 所以这里全量收集，并对未知 `Type` **跳过不抛**（上游抛 `UnknownResponse`；
/// 服务端新增类型不应让朗读整体失败）。
List<EdgeBoundary> parseBoundaries(Object body) {
  final text = body is String
      ? body
      : utf8.decode(body as List<int>, allowMalformed: true);
  final Object? decoded;
  try {
    decoded = jsonDecode(text);
  } catch (_) {
    return const <EdgeBoundary>[];
  }
  if (decoded is! Map) return const <EdgeBoundary>[];
  final metadata = decoded['Metadata'];
  if (metadata is! List) return const <EdgeBoundary>[];
  final out = <EdgeBoundary>[];
  for (final item in metadata) {
    if (item is! Map) continue;
    final type = item['Type'];
    if (type != 'WordBoundary' && type != 'SentenceBoundary') continue;
    final data = item['Data'];
    if (data is! Map) continue;
    final offset = _asInt(data['Offset']);
    final duration = _asInt(data['Duration']);
    final textField = data['text'];
    final token = textField is Map ? textField['Text'] : null;
    if (offset == null || duration == null || token is! String) continue;
    out.add(
      EdgeBoundary(
        type: type,
        offsetTicks: offset,
        durationTicks: duration,
        // 服务端回吐的是转义后的片段，必须用同一套（只含 & < > 的）还原规则解回来，
        // 否则 token 与原文对不上 → 坐标漂移。
        text: ssmlUnescapeText(token),
      ),
    );
  }
  return out;
}

int? _asInt(Object? value) => value is num
    ? value.toInt()
    : (value is String ? int.tryParse(value) : null);

/// 跳过分隔符之后的换行：上游只跳 2 字节，于是 body 带一个前导 `\r\n`。
/// 这里直接跳到正文开头（`jsonDecode` 本来也能容忍，但让 body 干净更好核对）。
int _skipBodyNewline(String raw, int from) {
  var i = from;
  while (i < raw.length && (raw[i] == '\r' || raw[i] == '\n')) {
    i++;
  }
  return i;
}

EdgePath _pathOf(Map<String, String> headers) {
  switch (headers['Path']) {
    case 'audio':
      return EdgePath.audio;
    case 'audio.metadata':
      return EdgePath.audioMetadata;
    case 'turn.start':
      return EdgePath.turnStart;
    case 'turn.end':
      return EdgePath.turnEnd;
    case 'response':
      return EdgePath.response;
    default:
      return EdgePath.unknown;
  }
}
