/// 听书背景音乐：一个**独立的**低音量循环播放器，跟随朗读起停。
///
/// 为什么不往章节音频里混音：
/// 1. 混音要解码 + 重编码 MP3，会动「字节 ÷ 码率 = 时间」这条不变式；
/// 2. BGM 是用户自选文件（可能几十分钟），塞进每章缓存等于每章复制一份。
///
/// 生命周期跟「朗读会话」走、不跟页面走：用户切页或收起控制条时 BGM 不该断。
///
/// **降级优先**：打不开/播不了一律静默放弃 —— BGM 是锦上添花，
/// 绝不能因为它让朗读起不来。
library;

import 'dart:async';

import 'package:media_kit/media_kit.dart';

import '../../player/player_engine.dart';

/// 默认音量：压到 20%。再高就会盖住朗读（真人音轨本来就不响）。
const double kDefaultBgmVolume = 0.2;

class ListenBgm {
  ListenBgm({PlayerEngine Function()? engineFactory})
    : _create = engineFactory ?? (() => MpvPlayerEngine());

  final PlayerEngine Function() _create;

  PlayerEngine? _engine;
  StreamSubscription<bool>? _doneSub;
  String _file = '';
  double _volume = kDefaultBgmVolume;
  bool _playing = false;

  /// 当前有没有 BGM 挂着（不代表正在出声）。
  bool get isActive => _file.isNotEmpty;

  /// 当前 BGM 文件（空 = 未启用）。
  String get file => _file;

  /// 起播。同一文件重复调用只做 resume（不重建播放器）。
  Future<void> start(String file, {double volume = kDefaultBgmVolume}) async {
    final path = file.trim();
    if (path.isEmpty) {
      await stop();
      return;
    }
    _volume = volume.clamp(0.0, 1.0).toDouble();
    if (path == _file && _engine != null) {
      await resume();
      return;
    }
    await stop();
    _file = path;
    final engine = _create();
    _engine = engine;
    try {
      await engine.initialize();
      await engine.setVolume(_volume);
      // 单曲循环用「播完 seek 回 0」实现：mpv 的 loop 属性各平台实现不一，
      // 而 completed 事件是引擎抽象层保证有的。
      _doneSub = engine.stream.completed.listen((done) {
        if (!done || !_playing) return;
        unawaited(_restart());
      });
      await engine.open(Media(path));
      _playing = true;
    } catch (_) {
      await stop();
    }
  }

  Future<void> _restart() async {
    try {
      await _engine?.seek(Duration.zero);
      await _engine?.play();
    } catch (_) {
      await stop();
    }
  }

  /// 朗读暂停时 BGM 也停（不要出现"人声停了音乐还在响"）。
  Future<void> pause() async {
    _playing = false;
    try {
      await _engine?.pause();
    } catch (_) {}
  }

  Future<void> resume() async {
    if (_engine == null) return;
    _playing = true;
    try {
      await _engine?.play();
    } catch (_) {}
  }

  Future<void> setVolume(double volume) async {
    _volume = volume.clamp(0.0, 1.0).toDouble();
    try {
      await _engine?.setVolume(_volume);
    } catch (_) {}
  }

  /// 停掉并释放播放器（关会话 / 换文件 / 宿主销毁都要调）。
  Future<void> stop() async {
    _playing = false;
    _file = '';
    await _doneSub?.cancel();
    _doneSub = null;
    final engine = _engine;
    _engine = null;
    if (engine == null) return;
    try {
      await engine.stop();
    } catch (_) {}
    try {
      await engine.dispose();
    } catch (_) {}
  }

  Future<void> dispose() => stop();
}
