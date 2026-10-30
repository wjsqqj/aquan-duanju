/// WebSocket / HTTP 的**注入点**与一次 chunk 的收发编排。
///
/// 为什么自己定义 `EdgeSocket` / `EdgeHttpClient` 这一层薄抽象：
/// 1. `dart:io` 的 `WebSocket.connect` **没有 `findProxy` 参数**（说明书 §10.1），
///    代理与 User-Agent 只能通过 `customClient: HttpClient()..userAgent=…` 提供；
///    `headers` 走的是 `add` 而非 `set`，再塞 UA 就会变成两个 UA（而服务卡 UA）。
///    所以「造客户端」这件事必须集中在 [HttpClientFactory]，由它一次做对；
/// 2. 测试不能联网（prd.md 的硬约束），而 `dart:io` 的 `WebSocket`/`HttpClient`
///    成员太多，假实现无法覆盖。抽象成「发消息 + 收消息 + 关闭」三个动作，
///    假对象十几行就能撑起完整的协议测试。
///
/// 绝不读环境变量当默认代理：`HttpClient` 的默认 `findProxy` 会继承
/// `HTTP(S)_PROXY`，所以这里**总是**显式覆写 `findProxy`（未配置即 DIRECT）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../tts_models.dart';
import 'edge_constants.dart';
import 'edge_frames.dart';
import 'edge_ssml.dart';
import 'edge_token.dart';

/// 一条已建立的 WebSocket 会话（最小动作集）。
abstract class EdgeSocket {
  /// 服务端推送：`String` 是文本帧，`List<int>` 是二进制帧。
  Stream<dynamic> get messages;

  void add(Object data);

  Future<void> close();
}

/// 一次 HTTP GET 的结果（只取本引擎用得上的三项）。
class EdgeHttpResponse {
  const EdgeHttpResponse({
    required this.statusCode,
    this.dateHeader,
    this.body = '',
  });

  final int statusCode;

  /// 标准 `Date` 头：时钟纠偏唯一可信的来源（`X-MSEdge-*` 的写法已作废）。
  final String? dateHeader;
  final String body;
}

/// HTTP 客户端抽象（音色列表 + 时钟探针）。
abstract class EdgeHttpClient {
  Future<EdgeHttpResponse> get(Uri uri, {Map<String, String>? headers});

  /// 给 `WebSocket.connect` 当 `customClient` 用；假客户端返回 `null`。
  HttpClient? get ioClient;

  /// 用完必须关掉，否则 keep-alive 的 socket 会拖住进程退出。
  void close({bool force = false});
}

/// 造客户端时需要的配置：代理 + UA + 固定头。
class EdgeHttpProfile {
  const EdgeHttpProfile({
    this.proxy = '',
    this.userAgent = kEdgeUserAgent,
    this.headers = const <String, String>{},
  });

  /// 空串 = 不用代理（且不继承环境变量）。
  final String proxy;
  final String userAgent;
  final Map<String, String> headers;
}

typedef HttpClientFactory = EdgeHttpClient Function(EdgeHttpProfile profile);
typedef WsFactory = Future<EdgeSocket> Function(
  Uri uri, {
  Map<String, String> headers,
  EdgeHttpClient? client,
});

/// 握手/连接失败。[statusCode] 是 HTTP 状态码（拿不到时为 null → 归为传输失败）。
class EdgeConnectFailure implements Exception {
  const EdgeConnectFailure({this.statusCode, this.reason = ''});

  final int? statusCode;

  /// 已经过 [redactEdgeSecrets] 处理：不含 token/key/muid 全值。
  final String reason;

  @override
  String toString() => 'EdgeConnectFailure($statusCode, $reason)';
}

/// 音频与时间点（一次 chunk 会话的产物，音频是**未清洗**的原始字节）。
class EdgeChunkResult {
  const EdgeChunkResult({
    required this.audio,
    required this.boundaries,
    required this.unknownPaths,
  });

  final Uint8List audio;
  final List<EdgeBoundary> boundaries;

  /// 遇到过的未知 `Path`：不致命，但「一帧音频都没收到」时要拼进诊断信息，
  /// 让版本漂移在日志里**可识别**（prd.md S4）。
  final List<String> unknownPaths;
}

/// chunk 间偏移统计（说明书 §6 的状态位，只保留本地字节口径那两项；
/// 已废弃的 `lastDurationOffset + 8750000` 那套公式不实现）。
class TtsStats {
  TtsStats();

  /// 当前 chunk 已收字节（清洗后）。
  int chunkBytes = 0;

  /// **已完成** chunk 的累计字节。
  int cumulativeBytes = 0;

  int get offsetCompensationTicks => compensationTicks(cumulativeBytes);

  /// `turn.end` 之后调用：本 chunk 计入累计并清零（上游在 403 重试前还会再清零一次，
  /// 避免半截音频被重复计入 —— 见 `stream()` 里的 `chunk_audio_bytes = 0`）。
  void finishChunk() {
    cumulativeBytes += chunkBytes;
    chunkBytes = 0;
  }
}

/// CBR 字节 → 100ns tick（`communicate.py:416-422` 的等价整数式）。
int compensationTicks(int bytes) =>
    bytes * 8 * kEdgeTicksPerSecond ~/ kEdgeMp3BitrateBps;

/// 100ns tick → 毫秒。
int edgeTicksToMs(int ticks) => ticks ~/ kEdgeTickDivisor;

/// 字节 → 毫秒（48kbps：`bytes / 6`）。
int edgeBytesToMs(int bytes) => bytes ~/ 6;

/// 合成端点的完整 URL。
///
/// 只带 `keyParamName` / `ConnectionId` / `Sec-MS-GEC` / `Sec-MS-GEC-Version`
/// 四项：上游 7.3.1 **没有 `CV`**（说明书 §2.6），也没有 `Sec-MS-Blob-*`，
/// 更没有 `Content-Length`（那是 POST 的东西，这里是 GET 升级）。
Uri edgeSynthesizeUri(
  EdgeEndpointPreset preset, {
  required String token,
  required String connectionId,
}) => preset.wssBaseUri.replace(
  queryParameters: <String, String>{
    ...preset.wssBaseUri.queryParameters,
    'ConnectionId': connectionId,
    'Sec-MS-GEC': token,
    'Sec-MS-GEC-Version': preset.gecVersion,
  },
);

/// 一次 chunk 的收发：连接 → `speech.config` → `ssml` → 读到 `turn.end`。
///
/// 每个 chunk 都是**一条全新连接**（说明书 §3：上游也是 per-chunk 建连，
/// 不多路复用），所以并发必须节流（节流在编排层，不在这里）。
class EdgeSession {
  EdgeSession({
    required this.preset,
    required this.wsFactory,
    required this.httpClientFactory,
    required this.clock,
    this.proxy = '',
    this.connectTimeout = kEdgeConnectTimeout,
    this.receiveTimeout = kEdgeReceiveTimeout,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final EdgeEndpointPreset preset;
  final WsFactory wsFactory;
  final HttpClientFactory httpClientFactory;
  final DrmClock clock;
  final String proxy;
  final Duration connectTimeout;
  final Duration receiveTimeout;
  final DateTime Function() _now;

  /// 发 SSML 并收完整结果。403 走一次时钟纠偏重试（[edgeSkewGuarded]）。
  Future<EdgeChunkResult> runChunk(String ssml) => edgeSkewGuarded(
    attempt: () => _attempt(ssml),
    adjustClock: _adjustClockFromProbe,
  );

  Future<EdgeChunkResult> _attempt(String ssml) async {
    final headers = <String, String>{
      ...edgeWssConnectHeaders,
      // muid 每次连接重新生成（`drm.py:587-594`），结尾分号照上游。
      'Cookie': 'muid=${generateEdgeMuid()};',
    };
    final client = httpClientFactory(
      EdgeHttpProfile(proxy: proxy, headers: headers),
    );
    EdgeSocket? socket;
    final audio = BytesBuilder(copy: false);
    final boundaries = <EdgeBoundary>[];
    final unknownPaths = <String>[];
    var bytes = 0;
    try {
      final uri = edgeSynthesizeUri(
        preset,
        token: generateSecMsGec(now: _now(), skew: clock.skew),
        connectionId: newEdgeRequestId(),
      );
      socket = await wsFactory(
        uri,
        headers: headers,
        client: client,
      ).timeout(connectTimeout);
      // 同一会话里两处时间戳同源（上游也是先取一次 date_to_string 再复用）。
      final timestamp = jsStyleDate(_now());
      socket.add(encodeConfigFrame(wordBoundary: true, timestamp: timestamp));
      socket.add(
        encodeSsmlFrame(
          requestId: newEdgeRequestId(),
          timestamp: timestamp,
          ssml: ssml,
        ),
      );

      await for (final message in socket.messages.timeout(receiveTimeout)) {
        if (message is String) {
          final frame = decodeTextFrame(message);
          if (frame.isHeartbeat) continue;
          if (frame.isMetadata) {
            boundaries.addAll(parseBoundaries(frame.body));
            continue;
          }
          if (frame.isTurnEnd) break;
          if (frame.path == EdgePath.unknown) {
            unknownPaths.add(frame.unknownPath);
          }
          // response / turn.start：上游忽略，这里同样忽略。
          continue;
        }
        if (message is List<int>) {
          final frame = decodeBinaryFrame(
            message is Uint8List ? message : Uint8List.fromList(message),
          );
          if (frame.path != EdgePath.audio) {
            throw EdgeFrameException(
              'binary message path=${frame.unknownPath}',
            );
          }
          final contentType = frame.headers['Content-Type'];
          if (contentType != null && contentType != 'audio/mpeg') {
            throw EdgeFrameException('unexpected Content-Type=$contentType');
          }
          if (frame.body.isEmpty) {
            // 收尾帧：只有 body 为空才允许没有 Content-Type（说明书 §4.2）。
            if (contentType == null) continue;
            throw const EdgeFrameException('audio frame missing audio data');
          }
          if (contentType == null) {
            throw const EdgeFrameException(
              'audio frame has data but no Content-Type',
            );
          }
          audio.add(frame.body);
          bytes += frame.body.length;
        }
      }
      if (bytes == 0) {
        throw TtsException(
          TtsErrorCode.emptyAudio,
          message:
              'edge 没有收到任何音频帧'
              '${unknownPaths.isEmpty ? '' : '，未知 Path=${unknownPaths.join(",")}'}',
          retryable: true,
        );
      }
      return EdgeChunkResult(
        audio: audio.toBytes(),
        boundaries: boundaries,
        unknownPaths: unknownPaths,
      );
    } on WebSocketException catch (e) {
      // dart:io 在非 101 时丢掉响应头（说明书 §10.3）：状态码可用，Date 不可用，
      // 所以纠偏必须另发探针 GET（见 _adjustClockFromProbe）。
      throw EdgeConnectFailure(
        statusCode: e.httpStatusCode,
        reason: redactEdgeSecrets(e.message),
      );
    } on EdgeConnectFailure {
      rethrow;
    } on TtsException {
      rethrow;
    } on TimeoutException {
      throw const EdgeConnectFailure(reason: 'edge 连接/收包超时');
    } on EdgeFrameException catch (e) {
      // 帧结构坏了 = 协议漂移或响应被截断：按「这段没出声音」处理（可重试）。
      throw TtsException(
        TtsErrorCode.emptyAudio,
        message: 'edge 报文异常：${redactEdgeSecrets(e.message)}',
        retryable: true,
      );
    } on SocketException catch (e) {
      throw EdgeConnectFailure(
        reason: redactEdgeSecrets('socket: ${e.osError?.message ?? e.message}'),
      );
    } on HandshakeException catch (e) {
      throw EdgeConnectFailure(reason: redactEdgeSecrets('tls: ${e.message}'));
    } finally {
      await _quietClose(socket);
      client.close(force: true);
    }
  }

  /// 握手失败时 dart:io 会丢掉响应头，所以纠偏必须另发一个普通 GET，
  /// 与音色列表共用同一条探针实现（[edgeProbeClockSkew]）。
  Future<bool> _adjustClockFromProbe() => edgeProbeClockSkew(
    preset: preset,
    httpClientFactory: httpClientFactory,
    clock: clock,
    proxy: proxy,
    now: _now,
    timeout: receiveTimeout,
  );
}

/// 时钟探针：普通 `HttpClient` GET（音色列表 URL）读标准 `Date` 头，累加 [DrmClock.skew]。
///
/// 为什么要单独发一次请求：`WebSocket.connect` 在 HTTP 状态非 101 时由 dart:io 抛
/// `WebSocketException` 并**丢弃全部响应头**（说明书 §10.3），拿不到 `Date` 就无从纠偏；
/// 上游 `drm.py:541-566` 同样是 GET 这个音色列表 URL 来取 `Date`。
/// 探针自身失败不升级为业务错误 —— 只返回 false，由 [edgeSkewGuarded] 判 `authRejected`。
Future<bool> edgeProbeClockSkew({
  required EdgeEndpointPreset preset,
  required HttpClientFactory httpClientFactory,
  required DrmClock clock,
  String proxy = '',
  DateTime Function()? now,
  Duration timeout = kEdgeReceiveTimeout,
}) async {
  final client = httpClientFactory(EdgeHttpProfile(proxy: proxy));
  try {
    final response = await client.get(preset.voiceListUri).timeout(timeout);
    return clock.adjustFromHttpDate(
      response.dateHeader,
      localNow: (now ?? DateTime.now)(),
    );
  } catch (_) {
    // 探针失败（无 Date / 网络错）不等于业务失败：上层据此判 authRejected，
    // 这里抛别的异常只会掩盖 403 的真实原因。
    return false;
  } finally {
    client.close(force: true);
  }
}

/// 403 → 纠偏 → **只重试一次**；401 / 纠偏后仍失败 → `authRejected`；
/// 429 → `rateLimited`；其它（拿不到状态码）→ `transport`。
///
/// 上游只有 403 这一条自动纠偏路径（说明书 §9.2：401 直接抛，没有 429/退避/抖动），
/// 这里的分类是工程侧补的（design.md §5.6），语义与 `TtsErrorCode` 对齐。
Future<T> edgeSkewGuarded<T>({
  required Future<T> Function() attempt,
  required Future<bool> Function() adjustClock,
}) async {
  try {
    return await attempt();
  } on EdgeConnectFailure catch (failure) {
    if (failure.statusCode != HttpStatus.forbidden) {
      throw edgeFailureToException(failure);
    }
    if (!await adjustClock()) {
      throw const TtsException(
        TtsErrorCode.authRejected,
        message: 'edge 403，且时钟探针没有返回可解析的 Date',
      );
    }
    try {
      return await attempt();
    } on EdgeConnectFailure catch (retry) {
      throw edgeFailureToException(retry);
    }
  }
}

/// 把连接失败翻译成 [TtsException]。message 里只允许出现截断/哈希后的信息。
TtsException edgeFailureToException(EdgeConnectFailure failure) {
  final status = failure.statusCode;
  final code = switch (status) {
    401 || 403 => TtsErrorCode.authRejected,
    429 => TtsErrorCode.rateLimited,
    _ => TtsErrorCode.transport,
  };
  return TtsException(
    code,
    // 再过一遍脱敏：reason 由调用方拼装，不能假设每个来源都已清洗
    // （硬契约 10 要求「任何异常文案都不出现 token/key/muid 全值」）。
    message: redactEdgeSecrets('edge status=$status ${failure.reason}'),
    retryable:
        code == TtsErrorCode.rateLimited || code == TtsErrorCode.transport,
  );
}

/// 抹掉任意字符串里的 token / key / muid 全值（硬契约 10）。
///
/// 规则：80 字符的 `<16hex>-<64hex>` token、以及 32 位 hex（muid /
/// TrustedClientToken / ConnectionId）一律换成指纹。保留长度与形状，
/// 足够定位「是哪一次请求」，不足以重放。
String redactEdgeSecrets(String text) {
  var out = text;
  out = out.replaceAllMapped(
    RegExp(r'[0-9A-Fa-f]{16}-[0-9A-Fa-f]{64}'),
    (m) => 'GEC(${edgeSecretFingerprint(m.group(0)!)})',
  );
  out = out.replaceAllMapped(
    RegExp(r'\b[0-9A-Fa-f]{32}\b'),
    (m) => 'ID(${edgeSecretFingerprint(m.group(0)!)})',
  );
  return out;
}

/// 默认 WebSocket 工厂：`dart:io` + `customClient`（UA 与代理都在 client 里）。
Future<EdgeSocket> edgeIoWebSocket(
  Uri uri, {
  Map<String, String> headers = const <String, String>{},
  EdgeHttpClient? client,
}) async {
  try {
    final socket = await WebSocket.connect(
      uri.toString(),
      headers: headers,
      customClient: client?.ioClient,
    );
    return _IoEdgeSocket(socket);
  } on WebSocketException catch (e) {
    throw EdgeConnectFailure(
      statusCode: e.httpStatusCode,
      reason: redactEdgeSecrets(e.message),
    );
  }
}

/// 默认 HTTP 客户端工厂：显式覆写 `findProxy`，**不继承环境变量**。
EdgeHttpClient edgeIoHttpClient(EdgeHttpProfile profile) {
  final proxy = profile.proxy.trim();
  final client = HttpClient()
    ..userAgent = profile.userAgent
    ..connectionTimeout = kEdgeConnectTimeout
    // 未配置代理也必须显式写 DIRECT，否则 dart:io 会读 HTTP(S)_PROXY，
    // CI（voice-contract.md §6）与「不把环境变量当默认」的要求都会被打破。
    ..findProxy = (Uri _) => proxy.isEmpty ? 'DIRECT' : 'PROXY $proxy';
  return _IoEdgeHttpClient(client, profile.headers);
}

Future<void> _quietClose(EdgeSocket? socket) async {
  if (socket == null) return;
  try {
    await socket.close();
  } catch (_) {}
}

class _IoEdgeSocket implements EdgeSocket {
  _IoEdgeSocket(this._socket);

  final WebSocket _socket;

  @override
  Stream<dynamic> get messages => _socket;

  @override
  void add(Object data) => _socket.add(data);

  @override
  Future<void> close() async {
    try {
      await _socket.close();
    } catch (_) {}
  }
}

class _IoEdgeHttpClient implements EdgeHttpClient {
  _IoEdgeHttpClient(this._client, this._headers);

  final HttpClient _client;
  final Map<String, String> _headers;

  @override
  HttpClient? get ioClient => _client;

  @override
  Future<EdgeHttpResponse> get(Uri uri, {Map<String, String>? headers}) async {
    final request = await _client
        .openUrl('GET', uri)
        .timeout(kEdgeConnectTimeout);
    for (final entry in {..._headers, ...?headers}.entries) {
      request.headers.add(entry.key, entry.value);
    }
    final response = await request.close();
    final body = await response.transform(utf8.decoder).join();
    return EdgeHttpResponse(
      statusCode: response.statusCode,
      // 取原始 `Date` 头字符串（解析写在 edge_token.parseHttpDate）。
      dateHeader: response.headers[HttpHeaders.dateHeader]?.join(','),
      body: body,
    );
  }

  @override
  void close({bool force = false}) => _client.close(force: force);
}
