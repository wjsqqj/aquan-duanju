/// 第三方 HTTP TTS 的 [SpeechEngine] 实现：请求源 → 拿回 mp3 → 按句切时间点。
///
/// **精度诚实声明**：这类接口通常只回音频、不回词/句时间戳，所以本引擎
/// `caps.wordBoundary = false`，时间点按**字符比例**在句之间分配（`granularity` 走
/// 句级）。消费端拿不到词级时必须显示「句」而不是伪装成词级 —— 见
/// `.trellis/spec/backend/listen-tts-contract.md` 的「精度位不可伪造」。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import '../../reader/speech/speech_unit.dart';
import '../mp3_frames.dart';
import '../speech_engine.dart';
import '../tts_models.dart';
import 'http_tts_source.dart';

class HttpTtsEngine implements SpeechEngine {
  HttpTtsEngine({
    required this.source,
    http.Client? client,
    this.timeout = const Duration(seconds: 30),
    String proxy = '',
  }) : _client = client ?? buildHttpClient(proxy);

  /// 共用同一套代理策略：空串直连（**不读环境变量**，与 Edge 引擎一致）。
  static http.Client buildHttpClient(String proxy) {
    if (proxy.trim().isEmpty) return http.Client();
    final io = HttpClient()
      ..findProxy = (_) => 'PROXY ${proxy.trim()}';
    return IOClient(io);
  }

  final HttpTtsSource source;
  final http.Client _client;
  final Duration timeout;

  /// 源标识进缓存键：换源（或改源配置时换 id）必须重新合成。
  @override
  String get id => 'http:${source.id}';

  /// 只回音频 → 没有词级时间戳；能产出文件（可 seek/缓存），不需要单独密钥
  /// （密钥放 headers 里，属于源配置的一部分）。
  @override
  TtsCaps get caps => const TtsCaps(
    wordBoundary: false,
    offline: false,
    needsApiKey: false,
    producesFile: true,
  );

  @override
  Future<List<TtsVoice>> voices() async => source.voices;

  @override
  Future<TtsSegment> synthesize(SpeechJob job) async {
    final audio = await _fetchAudio(job.text, job.voice.id);
    if (audio.isEmpty) {
      throw const TtsException(
        TtsErrorCode.emptyAudio,
        message: 'TTS 源返回空音频',
      );
    }
    // 只接受 mp3：拼接与 CBR 换算都依赖 mp3 帧（与 Edge 路径同一套）。
    final frames = extractMp3AudioFrames(audio);
    if (frames.isEmpty) {
      throw const TtsException(
        TtsErrorCode.emptyAudio,
        message: 'TTS 源返回的不是 mp3（或帧头损坏）',
      );
    }
    final durationMs = mp3BytesToMs(
      frames.length,
      bitrateKbps: source.bitrateKbps,
    );
    return TtsSegment(
      audio: audio,
      points: _proportionalPoints(job: job, durationMs: durationMs),
      audioMs: durationMs,
      bitrateKbps: source.bitrateKbps,
    );
  }

  @override
  Future<void> dispose() async => _client.close();

  // ---------- 内部 ----------

  Future<Uint8List> _fetchAudio(String text, String voice) async {
    try {
      final uri = source.buildUri(text: text, voice: voice);
      final response = source.isPost
          ? await _client
                .post(
                  uri,
                  headers: source.headers,
                  body: source.buildBody(text: text, voice: voice),
                )
                .timeout(timeout)
          : await _client.get(uri, headers: source.headers).timeout(timeout);
      _throwIfBad(response);

      switch (source.mode) {
        case HttpTtsResponseMode.audio:
          return response.bodyBytes;
        case HttpTtsResponseMode.jsonUrl:
          final url = _fieldOf(response.body, source.audioField);
          if (url.isEmpty) {
            throw TtsException(
              TtsErrorCode.emptyAudio,
              message: 'JSON 里没有 ${source.audioField}（音频直链）',
            );
          }
          final audioResponse = await _client
              .get(Uri.parse(url), headers: source.headers)
              .timeout(timeout);
          _throwIfBad(audioResponse);
          return audioResponse.bodyBytes;
        case HttpTtsResponseMode.jsonBase64:
          final data = _fieldOf(response.body, source.audioField);
          if (data.isEmpty) {
            throw TtsException(
              TtsErrorCode.emptyAudio,
              message: 'JSON 里没有 ${source.audioField}（base64）',
            );
          }
          try {
            return base64Decode(data);
          } catch (_) {
            throw const TtsException(
              TtsErrorCode.emptyAudio,
              message: 'base64 解码失败',
            );
          }
      }
    } on TtsException {
      rethrow;
    } on TimeoutException {
      throw TtsException(
        TtsErrorCode.transport,
        message: 'TTS 源超时（>${timeout.inSeconds}s）',
        retryable: true,
      );
    } on http.ClientException catch (e) {
      throw TtsException(
        TtsErrorCode.transport,
        message: 'TTS 源连接失败：${e.message}',
        retryable: true,
      );
    }
  }

  /// 状态码 → 错误分类（与 Edge 引擎同一套码，UI 文案复用 `friendlyText`）。
  void _throwIfBad(http.Response response) {
    final code = response.statusCode;
    if (code >= 200 && code < 300) return;
    if (code == 401 || code == 403) {
      throw TtsException(
        TtsErrorCode.authRejected,
        message: 'TTS 源拒绝访问（HTTP $code）',
      );
    }
    if (code == 429) {
      throw TtsException(
        TtsErrorCode.rateLimited,
        message: 'TTS 源限流（HTTP 429）',
        retryable: true,
      );
    }
    throw TtsException(
      TtsErrorCode.transport,
      message: 'TTS 源返回 HTTP $code',
      retryable: code >= 500,
    );
  }

  /// 取 JSON 字段，支持一层点号路径（`data.audio`）。
  static String _fieldOf(String body, String field) {
    if (body.isEmpty) return '';
    Object? decoded;
    try {
      decoded = jsonDecode(body);
    } catch (_) {
      return '';
    }
    Object? current = decoded;
    for (final part in field.split('.')) {
      if (current is Map) {
        current = current[part];
      } else {
        return '';
      }
    }
    if (current is String) return current;
    return '';
  }

  /// 按字符比例把总时长分给每个句子。
  ///
  /// 为什么不“真实对齐”：接口没给时间戳，任何声称词级/精确句级的做法都是伪造。
  /// 这里只保证：单调递增、总长等于音频时长、落在 `job.text` 的字符坐标内。
  List<SpeechPoint> _proportionalPoints({
    required SpeechJob job,
    required int durationMs,
  }) {
    final units = splitSpeechUnits(<String>[job.text]);
    if (units.isEmpty) {
      return <SpeechPoint>[
        SpeechPoint(
          startMs: job.offsetBaseMs,
          endMs: job.offsetBaseMs + durationMs,
          charStart: 0,
          charEnd: job.text.length,
          unitIndex: 0,
        ),
      ];
    }
    final totalChars = units.fold<int>(0, (sum, u) => sum + u.length);
    final safeTotal = totalChars <= 0 ? 1 : totalChars;

    var cursorMs = 0;
    final out = <SpeechPoint>[];
    for (var i = 0; i < units.length; i++) {
      final unit = units[i];
      final isLast = i == units.length - 1;
      final spanMs = isLast
          ? durationMs - cursorMs
          : (durationMs * unit.length / safeTotal).round();
      final start = job.offsetBaseMs + cursorMs;
      final end = job.offsetBaseMs + cursorMs + (spanMs < 0 ? 0 : spanMs);
      out.add(
        SpeechPoint(
          startMs: start,
          endMs: end,
          charStart: unit.charStart,
          charEnd: unit.charEnd,
          unitIndex: unit.index,
          text: unit.text,
        ),
      );
      cursorMs += spanMs < 0 ? 0 : spanMs;
    }
    return out;
  }
}
