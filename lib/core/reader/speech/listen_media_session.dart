/// 系统媒体会话（通知栏 / 锁屏 / 耳机线控）的**唯一适配层**。
///
/// 平台门控：`audio_service` 只声明 Android/iOS/macOS/Web，Windows 上直接调用会
/// `MissingPluginException`——而 Windows 既是我们的主力端也是开发机，所以
/// **非 Android 一律返回 [NoopListenMediaSession]**，所有方法安全空转（design §3）。
///
/// 会话不反向依赖桥：命令通过可注入的 `onCommand` 回调上抛，由
/// `ListenMediaBridge` 装配成「派发给当前宿主」。
library;

import 'dart:async';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';

import '../../media_session_hub.dart';
import 'listen_media_state.dart';

/// 会话能力的最小面：发布状态、释放、接收命令。
abstract class ListenMediaSession {
  /// 命令上抛口。桥装配时注入；为 `null` 时命令直接丢弃。
  set onCommand(void Function(ListenMediaCommand cmd, Duration? position)? sink);

  Future<void> publish(ListenMediaState state);

  Future<void> dispose();
}

/// 非 Android 平台的空实现：所有方法空转，绝不出错。
class NoopListenMediaSession implements ListenMediaSession {
  const NoopListenMediaSession();

  @override
  set onCommand(void Function(ListenMediaCommand cmd, Duration? position)? sink) {}

  @override
  Future<void> publish(ListenMediaState state) async {}

  @override
  Future<void> dispose() async {}
}

/// 平台工厂：**唯一入口**。非 Android 返回 Noop。
ListenMediaSession createListenMediaSession() {
  if (!Platform.isAndroid) return const NoopListenMediaSession();
  return AndroidListenMediaSession();
}

/// Android 实现：`audio_service` 一条通知 + `audio_session` 焦点/打断。
class AndroidListenMediaSession implements ListenMediaSession {
  void Function(ListenMediaCommand cmd, Duration? position)? _onCommand;

  _ListenAudioHandler? _handler;
  _ListenDelegate? _delegate;
  Future<void>? _init;
  StreamSubscription<AudioInterruptionEvent>? _interruptSub;
  StreamSubscription<void>? _noisySub;

  /// 打断前是否在播：`end` 时只有原本在播才恢复（来电挂断后继续，符合听书场景）。
  bool _playingBeforeInterruption = false;

  /// 最近一次发布的 mediaId：只在变化时重建 MediaItem，避免每帧刷通知。
  String? _mediaId;

  @override
  set onCommand(void Function(ListenMediaCommand cmd, Duration? position)? sink) {
    _onCommand = sink;
  }

  @override
  Future<void> publish(ListenMediaState state) async {
    await _ensureInit();
    final handler = _handler;
    if (handler == null) return;

    // A7：活着的发布上接管会话（与视频桥互斥，hub 负责让位）。收敛用的
    // finished 发布不许激活——正在播视频时听书会话收尾，不能把通知抢过来。
    if (!state.finished) {
      final delegate = _delegate;
      if (delegate != null) await MediaSessionHub.instance.activate(delegate);
    }

    if (_mediaId != state.mediaId) {
      _mediaId = state.mediaId;
      final art = state.artUri;
      handler.mediaItem.add(
        MediaItem(
          id: state.mediaId,
          album: state.title,
          title: state.chapterTitle.isEmpty ? state.title : state.chapterTitle,
          artist: state.title,
          // 空串会被当成非法 Uri；没有封面就交给系统默认图标。
          artUri: (art == null || art.isEmpty) ? null : Uri.tryParse(art),
          duration: state.total,
        ),
      );
    }

    handler.playbackState.add(
      PlaybackState(
        controls: <MediaControl>[
          if (state.canPrev) MediaControl.skipToPrevious,
          MediaControl.rewind,
          if (state.playing) MediaControl.pause else MediaControl.play,
          if (state.canNext) MediaControl.skipToNext,
          MediaControl.stop,
        ],
        systemActions: const <MediaAction>{MediaAction.seek},
        androidCompactActionIndices: const <int>[0, 1, 2],
        processingState: state.finished
            ? AudioProcessingState.idle
            : (state.buffering
                  ? AudioProcessingState.buffering
                  : AudioProcessingState.ready),
        playing: state.playing,
        updatePosition: state.position,
        speed: state.speed,
      ),
    );
  }

  Future<void> _ensureInit() {
    if (_handler != null) return Future<void>.value();
    return _init ??= _doInit();
  }

  Future<void> _doInit() async {
    // 听书是长时语音：speech 配置会自动 duck/暂停掉背景音乐，而不是被静音。
    final audioSession = await AudioSession.instance;
    await audioSession.configure(const AudioSessionConfiguration.speech());

    final handler = _ListenAudioHandler((cmd, position) {
      _onCommand?.call(cmd, position);
    });
    _handler = handler;

    // A7：audio_service 单 handler 约束——全进程 init 一次落到复合路由器
    // （`media_session_hub.dart`，config 原样搬了过去），听书的命令流与
    // 发布流不变，handler 只是挂到 hub 的委托位，由「活着的发布」接管会话。
    _delegate = _ListenDelegate(handler, requestStop: () {
      _onCommand?.call(ListenMediaCommand.stop, null);
    });
    await MediaSessionHub.instance.ensureInit();

    _interruptSub = audioSession.interruptionEventStream.listen((event) {
      if (event.begin) {
        switch (event.type) {
          case AudioInterruptionType.duck:
            // 短提示（导航播报等）：只压低，不打断。
            _onCommand?.call(ListenMediaCommand.duck, null);
          case AudioInterruptionType.pause:
          case AudioInterruptionType.unknown:
            _playingBeforeInterruption = handler.playbackState.value.playing;
            _onCommand?.call(ListenMediaCommand.pause, null);
        }
        return;
      }
      // 打断结束：原本在播才恢复；duck 结束只还原音量。
      switch (event.type) {
        case AudioInterruptionType.duck:
          _onCommand?.call(ListenMediaCommand.unduck, null);
        case AudioInterruptionType.pause:
        case AudioInterruptionType.unknown:
          if (_playingBeforeInterruption) {
            _onCommand?.call(ListenMediaCommand.play, null);
          }
          _playingBeforeInterruption = false;
      }
    });

    // 拔耳机/断开蓝牙：直接暂停（继续外放会吵到别人）。
    _noisySub = audioSession.becomingNoisyEventStream.listen((_) {
      _onCommand?.call(ListenMediaCommand.pause, null);
    });
  }

  @override
  Future<void> dispose() async {
    await _interruptSub?.cancel();
    await _noisySub?.cancel();
    _interruptSub = null;
    _noisySub = null;
    _onCommand = null;
    // 会话委托一并摘除：hub 里若还指着它会路由到一个无人接听的 handler。
    final delegate = _delegate;
    _delegate = null;
    _handler = null;
    _init = null;
    _mediaId = null;
    if (delegate != null) {
      unawaited(MediaSessionHub.instance.deactivate(delegate));
    }
  }
}

/// `audio_service` 的 handler：把系统动作**全部**转成 [ListenMediaCommand]，
/// 自己绝不碰播放器与进度（进度语义只有宿主知道，见 design §5）。
class _ListenAudioHandler extends BaseAudioHandler {
  _ListenAudioHandler(this._emit);

  final void Function(ListenMediaCommand cmd, Duration? position) _emit;

  @override
  Future<void> play() async => _emit(ListenMediaCommand.play, null);

  @override
  Future<void> pause() async => _emit(ListenMediaCommand.pause, null);

  @override
  Future<void> stop() async => _emit(ListenMediaCommand.stop, null);

  @override
  Future<void> skipToNext() async => _emit(ListenMediaCommand.nextChapter, null);

  @override
  Future<void> skipToPrevious() async =>
      _emit(ListenMediaCommand.prevChapter, null);

  /// 通知上的「后退」按钮：按**句**后退，比整章后退更符合听书预期。
  @override
  Future<void> rewind() async => _emit(ListenMediaCommand.prevSentence, null);

  @override
  Future<void> fastForward() async =>
      _emit(ListenMediaCommand.nextSentence, null);

  @override
  Future<void> seek(Duration position) async =>
      _emit(ListenMediaCommand.seekTo, position);

  /// 倍速由 App 内控件驱动；系统侧改速不接（避免两套真值）。
  @override
  Future<void> setSpeed(double speed) async {}
}

/// 听书在复合路由（`media_session_hub.dart`）中的委托位：会话被视频桥接管时
/// 走**既有 stop 命令**停播（ReaderSpeechController 是收尾关闭、音轨页是
/// 暂停——与通知栏停止键同一语义，零新路径）。
class _ListenDelegate implements MediaSessionDelegate {
  _ListenDelegate(this._handler, {required this.requestStop});

  final BaseAudioHandler _handler;
  final void Function() requestStop;

  @override
  String get id => 'listen';

  @override
  BaseAudioHandler get handler => _handler;

  @override
  Future<void> onSuspended() async => requestStop();
}
