/// Android 视频播放的系统媒体会话（通知栏 / 锁屏 / 耳机线控）桥（A7）。
///
/// 与听书桥（`listen_media_session.dart`）共用同一个 audio_service handler
/// ——复合路由见 `media_session_hub.dart`（audio_service 单 handler 约束）。
///
/// 平台门控集中在 hub（`ensureInit` 非 Android 返回 null）：本文件的方法在
/// 非 Android 上要么被播放页的 `Platform.isAndroid` 分支跳过，要么落到
/// hub 的 no-op——桌面零分支、零异常；Windows SMTC 路径（player_screen
/// 的 `_smtc` 块）不动。命令**全部转播放页回调**（进度语义只有宿主知道，
/// 与听书同一设计原则），回调在页 detach 时清空，后台按键不许崩。
library;

import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';

import 'media_session_hub.dart';

/// 播放页推给系统媒体会话的状态快照。
class VideoMediaState {
  const VideoMediaState({
    required this.mediaId,
    required this.seriesTitle,
    required this.episodeNumber,
    this.artUri,
    this.duration,
    required this.playing,
    required this.buffering,
    required this.position,
    required this.speed,
    required this.canNext,
    required this.canPrev,
  });

  /// 集的唯一 id（MediaItem.id）：换集即换 mediaId，元数据随之重建。
  final String mediaId;

  /// 剧名（album 与 title 前缀同源）。
  final String seriesTitle;

  /// 当前集号（title = 剧名 · 第N集）。
  final int episodeNumber;

  /// 封面 URL（空串/null 交给系统默认图标）。
  final String? artUri;

  /// 总时长（未知给 null：拿 0 冒充总长会让锁屏进度条一直是满的）。
  final Duration? duration;

  final bool playing;
  final bool buffering;
  final Duration position;

  /// 当前生效倍速（系统按它外推进度；长按 2x 期间跟随 `_displaySpeed`）。
  final double speed;

  /// 上一集/下一集可用态（跨季与边界禁用，与播放页 `_goNext/_goPrev` 同语义）。
  final bool canNext;
  final bool canPrev;
}

/// MediaItem 拼装（纯函数）：title=剧名 · 第N集、album=剧名、artUri=封面、
/// duration=时长。与 Windows SMTC 的 `_updateSmtcMetadata` 同一文案口径。
MediaItem buildVideoMediaItem(VideoMediaState state) {
  final art = state.artUri;
  return MediaItem(
    id: state.mediaId,
    album: state.seriesTitle,
    title: '${state.seriesTitle} · 第${state.episodeNumber}集',
    artist: '阿圈短剧',
    // 空串会被当成非法 Uri；解析失败同样交给系统默认图标。
    artUri: (art == null || art.isEmpty) ? null : Uri.tryParse(art),
    duration: state.duration,
  );
}

/// PlaybackState 拼装（纯函数）：上一集 / 播放暂停 / 下一集三键 + 拖动进度
/// （MediaAction.seek → 锁屏 scrubber）。
PlaybackState buildVideoPlaybackState(VideoMediaState state) {
  final controls = <MediaControl>[
    if (state.canPrev) MediaControl.skipToPrevious,
    if (state.playing) MediaControl.pause else MediaControl.play,
    if (state.canNext) MediaControl.skipToNext,
  ];
  return PlaybackState(
    controls: controls,
    // compact 索引不得越界（canPrev/canNext 禁用时控件数会少）。
    androidCompactActionIndices: List<int>.generate(
      controls.length > 3 ? 3 : controls.length,
      (i) => i,
    ),
    systemActions: const <MediaAction>{MediaAction.seek},
    processingState: state.buffering
        ? AudioProcessingState.buffering
        : AudioProcessingState.ready,
    playing: state.playing,
    updatePosition: state.position,
    speed: state.speed,
  );
}

/// 视频桥的命令 handler：系统动作全部转成会话回调（播放页注入）。
class VideoMediaAudioHandler extends BaseAudioHandler {
  VideoMediaAudioHandler(this._session);

  final VideoMediaSession _session;

  void _dispatch(void Function()? action) {
    if (action == null) return;
    try {
      action();
    } catch (_) {
      // 宿主内部异常不能冒到平台通道。
    }
  }

  @override
  Future<void> play() async => _dispatch(_session.onPlay);

  @override
  Future<void> pause() async => _dispatch(_session.onPause);

  /// 系统侧 stop：视频没有「销毁会话」的用户语义（生命周期归播放页管），
  /// 退化为暂停最安全。
  @override
  Future<void> stop() async => _dispatch(_session.onPause);

  @override
  Future<void> skipToNext() async => _dispatch(_session.onNext);

  @override
  Future<void> skipToPrevious() async => _dispatch(_session.onPrev);

  /// 锁屏 scrubber 拖动：走播放页统一 seek（弹幕时间轴/续播保护同路径）。
  @override
  Future<void> seek(Duration position) async =>
      _dispatch(() => _session.onSeek?.call(position));

  /// 倍速由 App 内控件驱动；系统侧改速不接（避免两套真值）。
  @override
  Future<void> setSpeed(double speed) async {}

  /// 不提供 ±10s 跳转控件（拖动进度覆盖）；系统若发这两键按 no-op 处理。
  @override
  Future<void> fastForward() async {}

  @override
  Future<void> rewind() async {}
}

/// 视频媒体会话（单例；播放页 attach/detach，进程内同一时刻至多一个宿主）。
///
/// 换季 `pushReplacement` 时「新页先 attach、旧页后 dispose」：detach 按
/// owner 身份配对，只有当前宿主能摘除（与 `ListenMediaBridge.detach` 同款）。
class VideoMediaSession implements MediaSessionDelegate {
  VideoMediaSession._();

  static final VideoMediaSession instance = VideoMediaSession._();

  /// 播放页注册的命令回调（detach 时清空；后台按键不许崩）。
  void Function()? onPlay;
  void Function()? onPause;
  void Function(Duration position)? onSeek;
  void Function()? onNext;
  void Function()? onPrev;

  VideoMediaAudioHandler? _handler;
  Object? _owner;

  /// 元数据重建判定：mediaId 或时长变化才重建 MediaItem，避免每帧刷通知。
  String? _lastMediaId;
  Duration? _lastItemDuration;

  @override
  String get id => 'video';

  @override
  BaseAudioHandler get handler {
    final handler = _handler;
    if (handler == null) {
      throw StateError('VideoMediaSession.handler 在 attach 前不可用');
    }
    return handler;
  }

  /// 播放页进入时调用：注册命令回调 + 接管会话（若听书在播则先停听书）。
  /// 非 Android（hub no-op）与重复接管均安全。
  Future<void> attach(
    Object owner, {
    required void Function() onPlay,
    required void Function() onPause,
    required void Function(Duration position) onSeek,
    required void Function() onNext,
    required void Function() onPrev,
  }) async {
    _owner = owner;
    this.onPlay = onPlay;
    this.onPause = onPause;
    this.onSeek = onSeek;
    this.onNext = onNext;
    this.onPrev = onPrev;
    final handler = _handler ??= VideoMediaAudioHandler(this);
    // 跨季 pushReplacement 时会话没断过：旧状态保持连续，等新页首帧发布覆盖；
    // 其余情况（首次进入/退出后重进）清掉上一页的残留，避免旧集闪进通知。
    if (!identical(MediaSessionHub.instance.activeDelegate, this)) {
      handler.playbackState.add(
        PlaybackState(
          controls: const <MediaControl>[],
          systemActions: const <MediaAction>{},
          processingState: AudioProcessingState.idle,
          playing: false,
        ),
      );
      handler.mediaItem.add(null);
      _lastMediaId = null;
      _lastItemDuration = null;
    }
    await MediaSessionHub.instance.activate(this);
  }

  /// 播放页退出时调用：只有配对的 owner 能摘除（回调清空 + 通知收敛）。
  /// 新页先 attach 的场景（owner 不配对）无害跳过，会话由新页续持。
  Future<void> detach(Object owner) async {
    if (!identical(_owner, owner)) return;
    _owner = null;
    onPlay = onPause = onNext = onPrev = null;
    onSeek = null;
    _lastMediaId = null;
    _lastItemDuration = null;
    await MediaSessionHub.instance.deactivate(this);
  }

  /// 发布状态（换集/播放态翻转/缓冲/时长就绪/每秒进度）。
  /// mediaId 或时长变化才重建 MediaItem；playbackState 每次都发
  /// （updatePosition 带时间戳，系统按 speed 外推）。异常全部吞掉。
  Future<void> publish(VideoMediaState state) async {
    final handler = _handler;
    if (handler == null) return;
    try {
      if (_lastMediaId != state.mediaId ||
          _lastItemDuration != state.duration) {
        _lastMediaId = state.mediaId;
        _lastItemDuration = state.duration;
        handler.mediaItem.add(buildVideoMediaItem(state));
      }
      handler.playbackState.add(buildVideoPlaybackState(state));
    } catch (_) {
      // 媒体会话失败绝不影响播放。
    }
  }

  /// 会话被听书夺走：让位 = 暂停当前视频（互斥；用户回到播放页看到暂停态，
  /// 点播放会重新接管——那时听书走既有 stop 命令停播）。
  @override
  Future<void> onSuspended() async {
    final pause = onPause;
    if (pause == null) return;
    try {
      pause();
    } catch (_) {}
  }

  /// 测试重置（生产路径从不调用）。
  @visibleForTesting
  void debugReset() {
    _owner = null;
    onPlay = onPause = onNext = onPrev = null;
    onSeek = null;
    _handler = null;
    _lastMediaId = null;
    _lastItemDuration = null;
  }

  /// 仅供测试核对宿主配对。
  @visibleForTesting
  Object? get debugOwner => _owner;
}
