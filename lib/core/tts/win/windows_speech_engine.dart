/// Windows **离线**朗读引擎：`Windows.Media.SpeechSynthesis`（OneCore 语音）。
///
/// 实现方式：调用 `scripts/win_tts_bridge.ps1`（powershell.exe 的 WinRT 互操作），
/// 拿回 **wav** 与**词边界标记**（`TextOffset` 字符偏移 + `TimeOffset` 音频时间）。
///
/// 为什么不写在 windows/runner 的 C++ 里：
/// - 要引 C++/WinRT 投影（NuGet）并改 CMake，构建链风险高；
/// - 这件事只需要「文本 → wav + markers」，进程隔离反而更容易清理临时文件。
///
/// **诚实边界**：
/// - 只在 Windows 上可用；非 Windows 直接 `notConfigured`。
/// - 机器没装语音引擎时 `AllVoices` 会抛错 → `isAvailable()` 为 false，设置页不提供该选项。
/// - 引擎声明 `wordBoundary: true`：拿不到 WordBoundary 标记时**报错**而不是退回比例插值
///   （否则就成了伪造词级，见 `listen-tts-contract.md` 的「精度不可伪造」）。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import '../speech_engine.dart';
import '../tts_models.dart';
import '../wav_info.dart';

/// `listen.tts.engine` 取这个值时走 Windows 本机离线语音。
const String kWindowsSpeechEngineId = 'win';

/// 进程执行器（可注入：单测不真的起 powershell）。
typedef ProcessRunner = Future<ProcessResult> Function(
  String executable,
  List<String> arguments,
);

/// 一个系统语音（OneCore）。
class WindowsSpeechVoice {
  const WindowsSpeechVoice({required this.name, this.language = ''});

  final String name;
  final String language;
}

class WindowsSpeechEngine implements SpeechEngine {
  WindowsSpeechEngine({
    ProcessRunner? runner,
    Future<Directory> Function()? tempDirectory,
    bool? isWindows,
  }) : _runner = runner ?? _defaultRunner,
       _tempDirectory = tempDirectory ?? getTemporaryDirectory,
       _isWindows = isWindows ?? Platform.isWindows;

  final ProcessRunner _runner;
  final Future<Directory> Function() _tempDirectory;
  final bool _isWindows;

  /// 仓库内脚本路径（相对工作目录；发布版会把 scripts 一起带上，见打包脚本）。
  static const String scriptPath = 'scripts/win_tts_bridge.ps1';

  /// 引擎 id 进缓存键：改了脚本行为要换 id，否则命中旧产物。
  @override
  String get id => 'win-speech';

  /// 离线、产文件、**词级**（靠 markers）。
  @override
  TtsCaps get caps => const TtsCaps(
    wordBoundary: true,
    offline: true,
    needsApiKey: false,
    producesFile: true,
    container: 'wav',
  );

  /// 本机是否可用（有没有装语音）。非 Windows / 脚本失败 / 没语音 → false。
  Future<bool> isAvailable() async {
    if (!_isWindows) return false;
    return (await probeVoices()).isNotEmpty;
  }

  Future<List<WindowsSpeechVoice>> probeVoices() async {
    if (!_isWindows) return const <WindowsSpeechVoice>[];
    final dir = await _ensureTempDir();
    final jsonPath = _path(dir, 'probe', 'json');
    try {
      final result = await _runner(_powershell, <String>[
        ..._scriptArgs,
        '-Mode',
        'probe',
        '-OutJson',
        jsonPath,
      ]);
      if (result.exitCode != 0) return const <WindowsSpeechVoice>[];
      final payload = _readJson(jsonPath);
      final raw = payload?['voices'];
      if (raw is! List) return const <WindowsSpeechVoice>[];
      return raw
          .whereType<Map>()
          .map(
            (v) => WindowsSpeechVoice(
              name: '${v['name'] ?? ''}',
              language: '${v['language'] ?? ''}',
            ),
          )
          .where((v) => v.name.isNotEmpty)
          .toList(growable: false);
    } catch (_) {
      return const <WindowsSpeechVoice>[];
    } finally {
      _deleteQuietly(jsonPath);
    }
  }

  @override
  Future<List<TtsVoice>> voices() async {
    final voices = await probeVoices();
    return voices
        .map((v) => TtsVoice(id: v.name, displayName: v.language))
        .toList(growable: false);
  }

  @override
  Future<TtsSegment> synthesize(SpeechJob job) async {
    if (!_isWindows) {
      throw const TtsException(
        TtsErrorCode.notConfigured,
        message: 'Windows 语音引擎仅支持 Windows',
      );
    }
    final dir = await _ensureTempDir();
    final stamp = DateTime.now().microsecondsSinceEpoch;
    final wavPath = _path(dir, 'wav_$stamp', 'wav');
    final jsonPath = _path(dir, 'wav_$stamp', 'json');
    try {
      final result = await _runner(_powershell, <String>[
        ..._scriptArgs,
        '-Mode',
        'synth',
        '-TextB64',
        base64Encode(utf8.encode(job.text)),
        '-OutWav',
        wavPath,
        '-OutJson',
        jsonPath,
        if (job.voice.id.isNotEmpty) ...<String>['-Voice', job.voice.id],
        // 语速由播放器负责；这里固定 1.0，保证时间点与产物一致。
        '-Rate',
        '1.0',
      ]);
      final payload = _readJson(jsonPath);
      if (payload == null) {
        throw TtsException(
          TtsErrorCode.notConfigured,
          message: '语音桥没有产出结果（exit=${result.exitCode}）',
        );
      }
      if (payload['ok'] != true) {
        final error = '${payload['error'] ?? ''}';
        // 没装语音引擎属于「本机不具备能力」，不是网络/内容问题。
        final code = error.contains('未安装语音引擎')
            ? TtsErrorCode.notConfigured
            : TtsErrorCode.emptyAudio;
        throw TtsException(code, message: error);
      }

      final audio = await File(wavPath).readAsBytes();
      final info = WavInfo.parse(audio);
      final audioMs = info?.durationMs ?? 0;
      if (audio.isEmpty || audioMs <= 0) {
        throw const TtsException(
          TtsErrorCode.emptyAudio,
          message: '语音桥返回的 wav 无效（头解析失败或数据为空）',
        );
      }

      final points = _pointsFromMarkers(payload['markers'], job, audioMs);
      return TtsSegment(
        audio: audio,
        points: points,
        audioMs: audioMs,
        container: 'wav',
      );
    } finally {
      _deleteQuietly(wavPath);
      _deleteQuietly(jsonPath);
    }
  }

  @override
  Future<void> dispose() async {}

  // ---------- 内部 ----------

  List<String> get _scriptArgs => <String>[
    '-NoProfile',
    '-ExecutionPolicy',
    'Bypass',
    '-File',
    scriptPath,
  ];

  String get _powershell => 'powershell.exe';

  Future<Directory> _ensureTempDir() async {
    final dir = await _tempDirectory();
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  String _path(Directory dir, String stem, String ext) =>
      '${dir.path}${Platform.pathSeparator}aquan_tts_$stem.$ext';

  Map<String, dynamic>? _readJson(String path) {
    try {
      final file = File(path);
      if (!file.existsSync()) return null;
      final decoded = jsonDecode(file.readAsStringSync());
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (_) {
      return null;
    }
  }

  void _deleteQuietly(String path) {
    try {
      final file = File(path);
      if (file.existsSync()) file.deleteSync();
    } catch (_) {}
  }

  /// markers → 词级时间点。
  ///
  /// `TextOffset` 是原文 UTF-16 偏移（与 `SpeechPoint.charStart` 同一坐标系）；
  /// 每个词的结束 = 下一个词的开始，最后一个词的结束 = 音频末尾。
  List<SpeechPoint> _pointsFromMarkers(
    Object? rawMarkers,
    SpeechJob job,
    int audioMs,
  ) {
    if (rawMarkers is! List) {
      throw const TtsException(
        TtsErrorCode.emptyAudio,
        message: '语音桥没有返回词边界标记',
      );
    }
    final words = <({int charOffset, int timeMs})>[];
    for (final item in rawMarkers) {
      if (item is! Map) continue;
      if ('${item['kind'] ?? ''}' != 'WordBoundary') continue;
      final offset = (item['textOffset'] as num?)?.toInt();
      final time = (item['timeMs'] as num?)?.round();
      if (offset == null || time == null) continue;
      words.add((charOffset: offset, timeMs: time));
    }
    if (words.isEmpty) {
      // 引擎声明了词级；拿不到就**报错**，不退回比例插值（那就是伪造精度）。
      throw const TtsException(
        TtsErrorCode.emptyAudio,
        message: '该语音未返回词边界（WordBoundary），无法做词级高亮',
      );
    }
    words.sort((a, b) => a.timeMs.compareTo(b.timeMs));

    final textLength = job.text.length;
    final points = <SpeechPoint>[];
    for (var i = 0; i < words.length; i++) {
      final start = job.offsetBaseMs + words[i].timeMs;
      final end = i + 1 < words.length
          ? job.offsetBaseMs + words[i + 1].timeMs
          : job.offsetBaseMs + audioMs;
      final charStart = words[i].charOffset.clamp(0, textLength);
      final charEnd = i + 1 < words.length
          ? words[i + 1].charOffset.clamp(charStart, textLength)
          : textLength;
      points.add(
        SpeechPoint(
          startMs: start,
          endMs: end < start ? start : end,
          charStart: charStart,
          charEnd: charEnd,
          unitIndex: 0,
          text: textLength > charStart
              ? job.text.substring(charStart, charEnd)
              : '',
        ),
      );
    }
    return points;
  }

  static Future<ProcessResult> _defaultRunner(
    String executable,
    List<String> arguments,
  ) => Process.run(executable, arguments);
}

/// 便于测试与外部复用：把 [Uint8List] 包一层（避免调用方再 import typed_data）。
Uint8List asBytes(List<int> value) => Uint8List.fromList(value);
