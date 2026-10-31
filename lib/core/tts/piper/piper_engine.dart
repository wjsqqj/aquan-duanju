/// Piper 离线合成：调用用户自备的 `piper` 可执行文件，把文本喂给它的 stdin，
/// 拿回一段 wav。
///
/// 为什么不打包模型：中文 Piper 模型单个几十 MB，且各有许可；把「可执行 + 模型」
/// 交给用户放，本工程只负责按路径调用 —— 与 WinRT 桥同一策略（进程隔离，好清理）。
///
/// **诚实边界（比什么都重要）**：
/// - Piper 不输出词/句边界，整块只有一段音频 → 精度声明为
///   [SpeechGranularity.paragraph]，UI 必须显示「段」，绝不能标成「句」。
/// - 每次合成起一个进程（1–2s），所以**不适合**按句切块调用；块越大越快，
///   代价是精度更粗 —— 这是离线方案的固有权衡。
/// - 可执行文件 / 模型缺失时 `isAvailable()` 为 false，设置页不提供该选项。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../speech_engine.dart';
import '../tts_models.dart';
import '../wav_info.dart';

/// `listen.tts.engine` 取这个值时走 Piper。
const String kPiperEngineId = 'piper';

/// 执行一次「喂文本 → 产文件」。可注入：单测不真的起 piper 进程。
typedef TextToFileRunner =
    Future<ProcessResult> Function(
      String executable,
      List<String> arguments,
      String stdinText,
    );

class PiperSpeechEngine implements SpeechEngine {
  PiperSpeechEngine({
    required this.executable,
    required this.model,
    this.extraArgs = const <String>[],
    this.timeout = const Duration(seconds: 60),
    TextToFileRunner? runner,
    Future<Directory> Function()? tempDirectory,
  }) : _runner = runner ?? _startAndFeed,
       _tempDirectory = tempDirectory ?? getTemporaryDirectory;

  /// `piper` 可执行文件路径（也可以在 PATH 里，如 `piper`）。
  final String executable;

  /// `.onnx` 模型路径；同名 `.onnx.json` 由 piper 自己找。
  final String model;

  /// 额外参数（如 `--speaker 3`）。
  final List<String> extraArgs;

  final Duration timeout;

  final TextToFileRunner _runner;
  final Future<Directory> Function() _tempDirectory;

  /// 引擎 id 进缓存键：换引擎/换模型要换键，否则命中旧产物。
  /// （模型路径不直接进键 —— 子类或调用方可换 id 前缀。）
  @override
  String get id => 'piper';

  @override
  TtsCaps get caps => const TtsCaps(
    wordBoundary: false,
    offline: true,
    needsApiKey: false,
    producesFile: true,
    container: 'wav',
    // 整块合成、连句边界都没有：必须显式降级为「段」，否则就是伪造精度。
    granularity: SpeechGranularity.paragraph,
  );

  /// 本机是否可用：路径填了、模型文件在、`--help` 能跑通。
  ///
  /// 超时 5 秒：某些发行版 `--help` 会等 stdin，卡住就当不可用（比挂死好）。
  Future<bool> isAvailable() async {
    if (executable.trim().isEmpty || model.trim().isEmpty) return false;
    try {
      if (!await File(model).exists()) return false;
      final result = await _runner(
        executable,
        <String>['--help'],
        '',
      ).timeout(const Duration(seconds: 5));
      return result.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  /// Piper 不提供音色列表：一个模型就是一套声音。
  @override
  Future<List<TtsVoice>> voices() async => const <TtsVoice>[];

  @override
  Future<void> dispose() async {}

  @override
  Future<TtsSegment> synthesize(SpeechJob job) async {
    if (executable.trim().isEmpty || model.trim().isEmpty) {
      throw const TtsException(
        TtsErrorCode.notConfigured,
        message: '还没配置 Piper 可执行文件或模型路径',
      );
    }
    final dir = await _ensureTempDir();
    final stamp = DateTime.now().microsecondsSinceEpoch;
    final wavPath = '${dir.path}${Platform.pathSeparator}aquan_piper_$stamp.wav';
    try {
      final result = await _runner(executable, <String>[
        '--model',
        model,
        '--output_file',
        wavPath,
        ...extraArgs,
      ], job.text).timeout(timeout);
      if (result.exitCode != 0) {
        throw TtsException(
          TtsErrorCode.transport,
          message: 'piper 退出码 ${result.exitCode}：${_brief(result.stderr)}',
        );
      }
      final file = File(wavPath);
      if (!await file.exists()) {
        throw const TtsException(
          TtsErrorCode.emptyAudio,
          message: 'piper 没有产出 wav（检查模型路径与磁盘权限）',
        );
      }
      final audio = await file.readAsBytes();
      final audioMs = WavInfo.parse(audio)?.durationMs ?? 0;
      if (audio.isEmpty || audioMs <= 0) {
        throw const TtsException(
          TtsErrorCode.emptyAudio,
          message: 'piper 产出的 wav 无效（头解析失败或数据为空）',
        );
      }
      // 整块一个点：时间已按 offsetBaseMs 平移，字符位相对 job.text（契约）。
      return TtsSegment(
        audio: audio,
        points: <SpeechPoint>[
          SpeechPoint(
            startMs: job.offsetBaseMs,
            endMs: job.offsetBaseMs + audioMs,
            charStart: 0,
            charEnd: job.text.length,
            unitIndex: 0,
            text: job.text,
          ),
        ],
        audioMs: audioMs,
        container: 'wav',
      );
    } finally {
      _deleteQuietly(wavPath);
    }
  }

  // ---------- 内部 ----------

  Future<Directory> _ensureTempDir() async {
    final dir = await _tempDirectory();
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  /// stderr 摘要：只留前 200 字并压平换行，避免把整段报错糊到 UI 上。
  static String _brief(String text) {
    final flat = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (flat.isEmpty) return '（无错误输出）';
    return flat.length <= 200 ? flat : '${flat.substring(0, 200)}…';
  }

  void _deleteQuietly(String path) {
    try {
      final file = File(path);
      if (file.existsSync()) file.deleteSync();
    } catch (_) {}
  }

  /// 默认执行器：起进程 → 写 stdin → 收 stdout/stderr 与退出码。
  static Future<ProcessResult> _startAndFeed(
    String executable,
    List<String> arguments,
    String stdinText,
  ) async {
    final process = await Process.start(executable, arguments);
    unawaited(
      () async {
        try {
          process.stdin.write(stdinText);
          await process.stdin.flush();
        } catch (_) {
          // 进程提前退出时写 stdin 会报错：交给 exitCode 判定。
        } finally {
          try {
            await process.stdin.close();
          } catch (_) {}
        }
      }(),
    );
    final out = process.stdout.transform(utf8.decoder).join();
    final err = process.stderr.transform(utf8.decoder).join();
    final code = await process.exitCode;
    return ProcessResult(process.pid, code, await out, await err);
  }
}
