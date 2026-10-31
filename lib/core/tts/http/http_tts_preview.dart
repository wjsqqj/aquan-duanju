/// 试听：把一次合成结果写到临时文件，用**现有播放器**播出来。
///
/// 为什么走文件而不是内存流：工程的播放链路（`PlayerEngine` / media_kit）以本地文件为
/// 主，写临时文件能保证「试听听到的」与「正式播放时听到的」是同一条链路 —— 用别的
/// 播放器试听会掩盖真正的问题（容器、码率、解密、路径）。
///
/// 生命周期：调用方在弹窗关闭时 `dispose()`；`stop()` 会**同时删除临时文件**，
/// 不留垃圾。目录与引擎都可注入，单测不需要真实 mpv。
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:media_kit/media_kit.dart';
import 'package:path_provider/path_provider.dart';

import '../../player/player_engine.dart';

class TtsPreviewPlayer {
  TtsPreviewPlayer({
    Future<Directory> Function()? directory,
    PlayerEngine Function()? engineFactory,
    this.onError,
  }) : _directory = directory ?? getTemporaryDirectory,
       _engineFactory = engineFactory ?? MpvPlayerEngine.new;

  final Future<Directory> Function() _directory;
  final PlayerEngine Function() _engineFactory;

  /// 试听失败不该弹错误页：交给调用方轻提示即可。
  final void Function(String message)? onError;

  PlayerEngine? _engine;
  String? _path;
  bool _prepared = false;

  /// 是否有一条临时音频正在播。
  bool get isPlaying => _path != null;

  /// 当前临时文件路径（诊断/测试用）。
  String? get currentPath => _path;

  Future<void> play(Uint8List bytes) async {
    if (bytes.isEmpty) return;
    // 先停掉上一段并删文件：连续点试听不该堆一地临时文件。
    await stop();
    try {
      final dir = await _directory();
      final path =
          '${dir.path}${Platform.pathSeparator}'
          'tts_preview_${DateTime.now().millisecondsSinceEpoch}.mp3';
      await File(path).writeAsBytes(bytes, flush: true);
      _path = path;

      final engine = _engine ??= _engineFactory();
      if (!_prepared) {
        await engine.initialize();
        _prepared = true;
      }
      await engine.open(Media(path), play: true);
    } catch (e) {
      onError?.call('$e');
      await stop();
    }
  }

  /// 停止并删除临时文件（保留引擎实例，方便再次试听）。
  Future<void> stop() async {
    try {
      await _engine?.stop();
    } catch (_) {}
    final path = _path;
    _path = null;
    if (path != null) {
      try {
        await File(path).delete();
      } catch (_) {
        // 文件可能已经被系统清理：忽略。
      }
    }
  }

  Future<void> dispose() async {
    await stop();
    try {
      await _engine?.dispose();
    } catch (_) {}
    _engine = null;
    _prepared = false;
  }
}
