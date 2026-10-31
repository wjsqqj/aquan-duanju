/// HTTP TTS 源的**一行式体检**：把「发送什么、回什么、能不能用」三段摊开给用户看。
///
/// 设计取舍：
/// - 复用 [HttpTtsEngine] 走同一条生产路径（不是另写一套请求），只在外面套一个
///   **记录型 client** 抓状态码与响应体 —— 否则"调试台通过、正式播放失败"就白测了。
/// - **绝不记录 query**：源 URL 常把 API key 放在 query 里。`requestLine` 只保留
///   `METHOD host/path`，响应摘要统一截断并压平换行。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../speech_engine.dart';
import '../tts_models.dart';
import 'http_tts_engine.dart';
import 'http_tts_source.dart';

/// 一次体检的结果。`ok == false` 时 [errorCode] 一定有值。
class HttpTtsProbeResult {
  const HttpTtsProbeResult({
    required this.ok,
    required this.requests,
    required this.statusCode,
    required this.elapsedMs,
    required this.bytes,
    this.audioMs,
    this.sentenceCount,
    this.errorCode,
    this.message = '',
    this.snippet = '',
    this.requestLines = const <String>[],
  });

  final bool ok;

  /// 实际发出的请求数（`jsonUrl` 模式正常就是 2 次）。
  final int requests;
  final int statusCode;
  final int elapsedMs;
  final int bytes;
  final int? audioMs;
  final int? sentenceCount;

  /// `TtsErrorCode.name`（成功时为 null）。
  final String? errorCode;
  final String message;

  /// 响应体摘要（JSON 时有用；音频模式为空串）。
  final String snippet;

  /// 每个请求的 `METHOD host/path`（**不含 query**，避免泄露密钥）。
  final List<String> requestLines;

  /// 给 UI 直接显示的一行结论。
  String get headline {
    if (ok) {
      final ms = audioMs == null ? '-' : '${(audioMs! / 1000).toStringAsFixed(1)}s';
      return '成功 · HTTP $statusCode · $requests 次请求 · $bytes 字节 · 音频 $ms';
    }
    return '失败 · ${errorCode ?? 'unknown'}${statusCode > 0 ? ' · HTTP $statusCode' : ''}';
  }
}

/// 体检器：一次合成 + 抓包，不落盘、不写缓存。
class HttpTtsProbe {
  const HttpTtsProbe._();

  static const int _snippetLimit = 200;

  static Future<HttpTtsProbeResult> run(
    HttpTtsSource source, {
    String text = '这是调试台的测试文本。第二句。',
    String voice = '',
    Duration timeout = const Duration(seconds: 20),
    http.Client? client,
  }) async {
    final recorder = _RecordingClient(
      client ?? HttpTtsEngine.buildHttpClient(''),
    );
    final engine = HttpTtsEngine(
      source: source,
      client: recorder,
      timeout: timeout,
    );
    final voiceId = voice.isNotEmpty
        ? voice
        : (source.voices.isEmpty ? 'default' : source.voices.first.id);

    final watch = Stopwatch()..start();
    try {
      final segment = await engine.synthesize(
        SpeechJob(
          text: text,
          voice: TtsVoice(id: voiceId),
          offsetBaseMs: 0,
          requestIndex: 0,
        ),
      );
      watch.stop();
      return HttpTtsProbeResult(
        ok: true,
        requests: recorder.requests,
        statusCode: recorder.lastStatusCode,
        elapsedMs: watch.elapsedMilliseconds,
        bytes: segment.audio.length,
        audioMs: segment.audioMs,
        sentenceCount: segment.points.length,
        snippet: recorder.snippet(limit: _snippetLimit),
        requestLines: recorder.requestLines,
      );
    } on TtsException catch (e) {
      watch.stop();
      return HttpTtsProbeResult(
        ok: false,
        requests: recorder.requests,
        statusCode: recorder.lastStatusCode,
        elapsedMs: watch.elapsedMilliseconds,
        bytes: recorder.lastBytes,
        // 失败也把「返回的不是 mp3」之外的信息带上：用户最想看到的是服务端说了什么。
        errorCode: e.code.name,
        message: e.message,
        snippet: recorder.snippet(limit: _snippetLimit),
        requestLines: recorder.requestLines,
      );
    } catch (e) {
      watch.stop();
      return HttpTtsProbeResult(
        ok: false,
        requests: recorder.requests,
        statusCode: recorder.lastStatusCode,
        elapsedMs: watch.elapsedMilliseconds,
        bytes: recorder.lastBytes,
        errorCode: TtsErrorCode.transport.name,
        message: '$e',
        snippet: recorder.snippet(limit: _snippetLimit),
        requestLines: recorder.requestLines,
      );
    }
  }
}

/// 只在调试台出现：把真实请求/响应记录下来，**不改变**任何请求行为。
class _RecordingClient extends http.BaseClient {
  _RecordingClient(this._inner);

  final http.Client _inner;

  int requests = 0;
  int lastStatusCode = 0;
  int lastBytes = 0;
  final List<String> requestLines = <String>[];
  Uint8List? _firstBody;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests++;
    // 只记 host/path：query 里常有 API key，绝不落日志、不上屏。
    requestLines.add('${request.method} ${request.url.host}${request.url.path}');
    final response = await _inner.send(request);
    lastStatusCode = response.statusCode;
    final bytes = await response.stream.toBytes();
    lastBytes = bytes.length;
    _firstBody ??= bytes;
    return http.StreamedResponse(
      Stream<List<int>>.value(bytes),
      response.statusCode,
      contentLength: bytes.length,
      request: response.request,
      headers: response.headers,
      isRedirect: response.isRedirect,
      persistentConnection: response.persistentConnection,
      reasonPhrase: response.reasonPhrase,
    );
  }

  /// 响应体摘要：能按 UTF-8 解就用（JSON 场景），否则返回空串（音频是二进制，
  /// 解码出来只会是乱码，没有诊断价值）。
  String snippet({required int limit}) {
    final body = _firstBody;
    if (body == null || body.isEmpty) return '';
    String text;
    try {
      text = utf8.decode(body);
    } catch (_) {
      return '';
    }
    final flat = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (flat.length <= limit) return flat;
    return '${flat.substring(0, limit)}…';
  }

  @override
  void close() => _inner.close();
}
