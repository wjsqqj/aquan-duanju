import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart' as rec;
import 'package:speech_to_text/speech_to_text.dart';

import 'vad.dart';

/// 语音输入错误：detail 只进日志，用户文案走 [VoiceException.friendlyText]。
class VoiceException implements Exception {
  VoiceException(this.code, [this.detail = '']);
  final VoiceErrorCode code;
  final String detail;

  String get friendlyText => switch (code) {
        VoiceErrorCode.permissionDenied => '需要麦克风权限才能语音输入，请在系统设置里允许',
        VoiceErrorCode.sttUnavailable => '系统语音识别不可用（可在设置里改用云 API）',
        VoiceErrorCode.notConfigured => '桌面语音识别需要先在「我的 → 设置」里配置语音端点',
        VoiceErrorCode.apiFailed => '语音识别服务无响应，请检查端点与密钥',
        VoiceErrorCode.tooShort => '没听清内容，请按住再说一次',
      };

  @override
  String toString() => 'VoiceException(${code.name}, $detail)';
}

enum VoiceErrorCode { permissionDenied, sttUnavailable, notConfigured, apiFailed, tooShort }

/// 一次识别结果；Android 流式出字时 partial=false 的最后一条是定稿。
class SttResult {
  const SttResult({required this.text, this.isFinal = true});
  final String text;
  final bool isFinal;
}

/// 录音会话（record 插件封装）：16k WAV 单声道 + 实时电平 + 静音自动结束。
///
/// 平台覆盖 Android/Windows/macOS/Linux（servllama 已验证该路径）。
class VoiceRecorder {
  VoiceRecorder();

  final rec.AudioRecorder _record = rec.AudioRecorder();
  final SilenceVad _vad = SilenceVad();
  StreamSubscription<rec.Amplitude>? _ampSub;
  Timer? _maxTimer;
  DateTime _startedAt = DateTime.now();
  String? _path;
  Completer<bool>? _vadStop;

  /// 实时电平（dBFS，约 -60..0），UI 波纹动画用。
  final _level = StreamController<double>.broadcast();

  Stream<double> get level => _level.stream;

  Future<void> start({
    Duration maxDuration = const Duration(seconds: 15),
    FutureOr<void> Function()? onAutoStop,
  }) async {
    if (!await _record.hasPermission()) {
      throw VoiceException(VoiceErrorCode.permissionDenied);
    }
    final dir = await getTemporaryDirectory();
    final path =
        '${dir.path}${Platform.pathSeparator}aquan_voice_${DateTime.now().millisecondsSinceEpoch}.wav';
    _path = path;
    _vad.reset();
    _startedAt = DateTime.now();
    await _record.start(
      const rec.RecordConfig(
        encoder: rec.AudioEncoder.wav,
        sampleRate: 16000,
        numChannels: 1,
      ),
      path: path,
    );
    _ampSub = _record.onAmplitudeChanged(const Duration(milliseconds: 100)).listen(
      (amp) {
        final dbfs = amp.current.isNaN ? -60.0 : amp.current;
        _level.add(dbfs);
        final now = DateTime.now();
        if (_vad.feed(dbfs, now)) {
          _vadStop ??= Completer<bool>()..complete(true);
        } else if (now.difference(_startedAt).inMilliseconds >=
            maxDuration.inMilliseconds) {
          _vadStop ??= Completer<bool>()..complete(false);
        }
      },
    );
    // 静音自动结束 / 超时兜底：调用方 await [waitAutoStop] 感知。
    _maxTimer = Timer.periodic(const Duration(milliseconds: 100), (_) async {
      if (_vadStop != null && !(_vadStop!.isCompleted)) return;
      final should = _vadStop?.future;
      if (should != null) {
        final heardSpeech = await should;
        _maxTimer?.cancel();
        await onAutoStop?.call();
        _autoStopHeardSpeech = heardSpeech;
      }
    });
  }

  /// 静音自动结束是否判定「说过话」（false = 超时且从未出声）。
  bool get autoStopHeardSpeech => _autoStopHeardSpeech;
  bool _autoStopHeardSpeech = false;

  /// 手动停止：返回录音文件路径（不删除；识别后由调用方清理）。
  Future<String?> stop() async {
    _maxTimer?.cancel();
    await _ampSub?.cancel();
    _ampSub = null;
    try {
      return await _record.stop();
    } catch (_) {
      return _path;
    }
  }

  /// 取消：停止并删除临时文件。
  Future<void> cancel() async {
    _maxTimer?.cancel();
    await _ampSub?.cancel();
    _ampSub = null;
    try {
      final path = await _record.stop();
      if (path != null) _deleteQuietly(path);
    } catch (_) {
      if (_path != null) _deleteQuietly(_path!);
    }
    await _record.dispose();
  }

  static void _deleteQuietly(String path) {
    try {
      File(path).deleteSync();
    } catch (_) {}
  }
}

/// Android 系统语音识别（speech_to_text）：免费免配置、partial 实时出字。
class AndroidSpeechBackend {
  final SpeechToText _stt = SpeechToText();

  /// 流式识别；status done/error 时关闭流。
  Stream<SttResult> listen({String localeId = 'zh-CN'}) async* {
    var available = false;
    try {
      available = await _stt.initialize(
        onError: (e) {}, // 终态由 status 传递
        onStatus: (s) {},
      );
    } on PlatformException catch (e) {
      if (e.code == 'permission_denied') {
        throw VoiceException(VoiceErrorCode.permissionDenied);
      }
      throw VoiceException(VoiceErrorCode.sttUnavailable, e.code);
    }
    if (!available) {
      throw VoiceException(VoiceErrorCode.sttUnavailable);
    }
    final controller = StreamController<SttResult>();
    _stt.listen(
      onResult: (r) {
        controller.add(SttResult(text: r.recognizedWords, isFinal: r.finalResult));
      },
      listenOptions: SpeechListenOptions(
        localeId: localeId,
        partialResults: true,
        cancelOnError: true,
        listenMode: ListenMode.dictation,
      ),
    );
    try {
      yield* controller.stream;
    } finally {
      try {
        await _stt.stop();
      } catch (_) {}
      await controller.close();
    }
  }

  Future<void> stop() => _stt.stop();
}

/// 桌面（与未启用系统识别的端）：OpenAI 兼容 /audio/transcriptions 端点。
///
/// 一次 HTTP 上传 16k WAV；base_url/key/model 由用户在设置里配置
/// （Groq / 硅基流动 / 自建网关等任意 OpenAI 兼容服务）。
class OpenAiSpeechBackend {
  OpenAiSpeechBackend({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  Future<String> transcribeFile(
    String wavPath, {
    required String baseUrl,
    required String apiKey,
    String? model,
    String language = 'zh',
  }) async {
    final uri = Uri.parse(_normalizeEndpoint(baseUrl));
    final request = http.MultipartRequest('POST', uri)
      ..headers['Authorization'] = 'Bearer $apiKey'
      ..fields['language'] = language
      ..files.add(await http.MultipartFile.fromPath('file', wavPath,
          filename: 'voice.wav'));
    if (model != null && model.isNotEmpty) {
      request.fields['model'] = model;
    }
    try {
      final streamed =
          await _client.send(request).timeout(const Duration(seconds: 20));
      final body = await streamed.stream.bytesToString();
      if (streamed.statusCode != 200) {
        throw VoiceException(VoiceErrorCode.apiFailed, 'HTTP ${streamed.statusCode}');
      }
      final decoded = jsonDecode(body);
      if (decoded is! Map || decoded['text'] is! String) {
        throw VoiceException(VoiceErrorCode.apiFailed, '响应缺 text 字段');
      }
      return decoded['text'] as String;
    } on VoiceException {
      rethrow;
    } on TimeoutException {
      throw VoiceException(VoiceErrorCode.apiFailed, '超时');
    } catch (e) {
      throw VoiceException(VoiceErrorCode.apiFailed, e.toString());
    }
  }

  /// base_url 兼容三种写法：裸域名、/v1 结尾、完整 /v1/audio/transcriptions。
  static String _normalizeEndpoint(String baseUrl) {
    var url = baseUrl.trim();
    while (url.endsWith('/')) {
      url = url.substring(0, url.length - 1);
    }
    if (url.endsWith('/audio/transcriptions')) return url;
    if (url.endsWith('/v1')) return '$url/audio/transcriptions';
    return '$url/v1/audio/transcriptions';
  }

  void close() => _client.close();
}

/// 端点自检：POST 一段 0.5s 静音 WAV，返回耗时（毫秒）或抛 VoiceException。
Future<int> pingVoiceEndpoint({
  required String baseUrl,
  required String apiKey,
  String? model,
}) async {
  final silence =
      Uint8List(16000); // 0.5s 16k 16bit 单声道静音（振幅 0）。
  final wav = buildWavBytes(silence);
  final dir = await getTemporaryDirectory();
  final file = File(
      '${dir.path}${Platform.pathSeparator}aquan_voice_ping.wav');
  await file.writeAsBytes(wav);
  final backend = OpenAiSpeechBackend();
  final sw = Stopwatch()..start();
  try {
    await backend.transcribeFile(file.path,
        baseUrl: baseUrl, apiKey: apiKey, model: model);
  } finally {
    try {
      file.deleteSync();
    } catch (_) {}
    backend.close();
  }
  return sw.elapsedMilliseconds;
}
