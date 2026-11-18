/// 系统媒体会话的**复合路由**：audio_service 全进程只允许 init 一次
/// （二次 init 会触发插件侧断言并重复 configure 平台），而本工程有两条
/// 会话宿主——听书桥（`listen_media_session.dart`）与视频桥
/// （`video_media_session.dart`，A7）。
///
/// 结构（design A7）：
/// - [MediaHubAudioHandler] 是**唯一**传给 `AudioService.init` 的 handler：
///   系统命令转发给「当前激活宿主」，宿主发布的 playbackState/mediaItem
///   被镜像上来（BehaviorSubject 订阅即回放当前值）；
/// - [MediaSessionHub] 负责懒 init（沿用听书「首次用到才 init」的时机，
///   避免应用启动即拉起前台服务）与宿主接管/让位。
///
/// 互斥语义（prd A7）：视频桥激活时听书在播 → 听书先停（走既有 stop 命令）；
/// 听书接管时视频桥激活 → 视频桥让位（暂停）。让位后的宿主**不许自己抢回**
/// ——让位瞬间可能还有在途的状态发布，放行会造成会话来回横跳；必须等当前
/// 宿主退场（[MediaSessionHub.deactivate]）才解除锁定。
///
/// 非 Android 平台：`ensureInit` 返回 null，activate/deactivate 全部空转；
/// 本文件与具体播放实现零耦合，Windows 上零开销、零异常。
library;

import 'dart:async';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';

/// 接管系统媒体会话的宿主委托：听书桥与视频桥各一份。
abstract class MediaSessionDelegate {
  /// 宿主标识（诊断用）。
  String get id;

  /// 本宿主发布状态的 handler：状态镜像到复合 handler，命令从这里进。
  BaseAudioHandler get handler;

  /// 会话被别的宿主接管：让位（停声/暂停）并停止对外发布有效状态。
  Future<void> onSuspended();
}

/// 复合 AudioHandler：唯一交给 `AudioService.init` 的 handler。
///
/// - 命令：转发给当前激活委托（无激活委托时静默丢弃，后台按键不许崩）；
/// - 状态：镜像激活委托的 playbackState / mediaItem。
class MediaHubAudioHandler extends BaseAudioHandler {
  MediaSessionDelegate? _active;
  StreamSubscription<PlaybackState>? _stateSub;
  StreamSubscription<MediaItem?>? _itemSub;

  /// 当前激活的委托（诊断/测试）。
  MediaSessionDelegate? get activeDelegate => _active;

  /// [delegate] 接管：命令路由与状态镜像切过去。**幂等**：已是激活委托则无副作用。
  void attachDelegate(MediaSessionDelegate delegate) {
    if (identical(_active, delegate)) return;
    _detachMirrors();
    _active = delegate;
    // BehaviorSubject 订阅即回放当前值：接管瞬间通知立即呈现宿主现态。
    _stateSub = delegate.handler.playbackState.listen(playbackState.add);
    _itemSub = delegate.handler.mediaItem.listen(mediaItem.add);
  }

  /// [delegate] 退场：只有当前激活的委托能摘除（镜像断开、路由清空）。
  /// 是否收敛通知由调用方决定（[collapse]）。
  void detachDelegate(MediaSessionDelegate delegate) {
    if (!identical(_active, delegate)) return;
    _detachMirrors();
    _active = null;
  }

  /// 收敛通知：idle 态让 Android 侧停掉前台服务并撤通知
  /// （audio_service：processingState 进入 idle → service.stop）。
  void collapse() {
    playbackState.add(
      PlaybackState(
        controls: const <MediaControl>[],
        systemActions: const <MediaAction>{},
        processingState: AudioProcessingState.idle,
        playing: false,
      ),
    );
    mediaItem.add(null);
  }

  void _detachMirrors() {
    unawaited(_stateSub?.cancel());
    _stateSub = null;
    unawaited(_itemSub?.cancel());
    _itemSub = null;
  }

  Future<void> _forward(
    Future<void> Function(BaseAudioHandler handler) action,
  ) async {
    final delegate = _active;
    if (delegate == null) return;
    try {
      await action(delegate.handler);
    } catch (_) {
      // 委托内部异常不能冒到平台通道（会让通知键无响应且日志难查）。
    }
  }

  @override
  Future<void> play() => _forward((h) => h.play());

  @override
  Future<void> pause() => _forward((h) => h.pause());

  @override
  Future<void> stop() => _forward((h) => h.stop());

  @override
  Future<void> skipToNext() => _forward((h) => h.skipToNext());

  @override
  Future<void> skipToPrevious() => _forward((h) => h.skipToPrevious());

  @override
  Future<void> fastForward() => _forward((h) => h.fastForward());

  @override
  Future<void> rewind() => _forward((h) => h.rewind());

  @override
  Future<void> seek(Duration position) => _forward((h) => h.seek(position));

  @override
  Future<void> setSpeed(double speed) => _forward((h) => h.setSpeed(speed));
}

/// 全进程唯一的会话路由器：懒 init 一次，宿主接管/让位。
class MediaSessionHub {
  MediaSessionHub._();

  static final MediaSessionHub instance = MediaSessionHub._();

  MediaHubAudioHandler? _handler;
  Future<MediaHubAudioHandler?>? _init;
  MediaSessionDelegate? _active;
  MediaSessionDelegate? _suspended;

  /// activate/deactivate 串行闸门：接管涉及「让位旧宿主」的异步序列，
  /// 并发调用必须排队，避免镜像与路由的交错换手。
  Future<void> _lock = Future<void>.value();

  /// 当前激活的委托（诊断/测试）。
  MediaSessionDelegate? get activeDelegate => _active;

  /// 全进程一次 init；非 Android 返回 null（调用方据此完全不参与）。
  ///
  /// 通知渠道沿用听书的既有配置：audio_service 的 config 在 init 时一次性
  /// 下发，不支持运行期切换；拆独立渠道需要换渠道 id（系统设置里会残留
  /// 旧渠道），本轮不动（见任务交付说明）。
  Future<MediaHubAudioHandler?> ensureInit() async {
    final existing = _handler;
    if (existing != null) return existing;
    if (!Platform.isAndroid) return null;
    return _init ??= _doInit();
  }

  Future<MediaHubAudioHandler?> _doInit() async {
    final handler = MediaHubAudioHandler();
    try {
      await AudioService.init(
        builder: () => handler,
        // 与原听书 init 完全同参：渠道、常驻通知、暂停不撤（听书行为零变化；
        // 视频通知同渠道展示，且「暂停留通知可续播」也是视频想要的语义）。
        config: AudioServiceConfig(
          androidNotificationChannelId: 'com.aquan.duanju.listen',
          androidNotificationChannelName: '听书播放',
          androidNotificationChannelDescription: '听书的后台播放控制',
          androidNotificationOngoing: true,
          androidStopForegroundOnPause: false,
        ),
      );
    } catch (_) {
      // init 失败（无插件/平台异常）：允许后续重试，本壳静默——
      // 媒体会话失败绝不影响播放。
      _init = null;
      return null;
    }
    _handler = handler;
    return handler;
  }

  /// [delegate] 接管会话：让位当前宿主 → 命令路由与状态镜像切到 [delegate]。
  Future<void> activate(MediaSessionDelegate delegate) {
    return _queued(() => _activateNow(delegate));
  }

  /// [delegate] 退场（页面销毁/会话结束）：只有当前激活的委托能摘除。
  /// 收敛通知并解除让位锁（被让位的宿主此后可以重新接管）。
  Future<void> deactivate(MediaSessionDelegate delegate) {
    return _queued(() => _deactivateNow(delegate));
  }

  Future<void> _activateNow(MediaSessionDelegate delegate) async {
    final handler = await ensureInit();
    if (handler == null) return;
    if (identical(_active, delegate)) return;
    // 让位后不许自动抢回：必须等当前宿主退场。让位瞬间可能还有在途的
    // 状态发布（旧宿主的最后一次 publish），放行会让会话来回横跳。
    if (identical(_suspended, delegate)) return;
    final current = _active;
    if (current != null) {
      // 先断镜像再让位：让位过程中的状态发布（暂停等）不再进通知。
      handler.detachDelegate(current);
      _suspended = current;
      try {
        await current.onSuspended();
      } catch (_) {
        // 让位失败不阻断接管（旧宿主内部异常不能卡死新宿主）。
      }
    }
    handler.attachDelegate(delegate);
    _active = delegate;
  }

  Future<void> _deactivateNow(MediaSessionDelegate delegate) async {
    final handler = _handler;
    if (handler == null) return;
    if (!identical(_active, delegate)) return;
    handler.detachDelegate(delegate);
    _active = null;
    _suspended = null;
    handler.collapse();
  }

  Future<void> _queued(Future<void> Function() body) {
    final result = _lock.then((_) => body());
    // 闸门永远自愈：body 抛错只外抛给本次调用方，不堵后续接管。
    _lock = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  /// 测试注入预构建的复合 handler（Windows 测试宿主跑不了 AudioService.init）。
  /// 已 init 过（或已注入）时此方法不覆盖。
  @visibleForTesting
  void debugAttachHandler(MediaHubAudioHandler handler) {
    _handler ??= handler;
  }

  /// 测试重置全部状态（生产路径从不调用）。
  @visibleForTesting
  void debugReset() {
    _handler = null;
    _init = null;
    _active = null;
    _suspended = null;
    _lock = Future<void>.value();
  }
}
