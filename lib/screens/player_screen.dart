import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:screen_retriever/screen_retriever.dart' as sr;
import 'package:share_plus/share_plus.dart';
import 'package:smtc_windows/smtc_windows.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:window_manager/window_manager.dart';

import '../cli/launch_command.dart';
import '../cli/player_bus.dart';
import '../core/aqua_api.dart';
import '../core/bili/api.dart' as bili;
import '../core/danmaku/danmaku_repository.dart';
import '../core/auto_retry.dart';
import '../core/cast/cast_diagnostics.dart';
import '../core/cast/cast_feature_flags.dart';
import '../core/error_log.dart';
import '../core/aqua_error.dart';
import '../core/last_route.dart';
import '../core/cast/cast_controller.dart';
import '../core/cast/cast_relay_probe.dart';
import '../core/muted_hint.dart';
import '../core/pip/pip_platform.dart';
import '../core/playback_diagnostics.dart';
import '../core/player/playback_buffer_monitor.dart';
import '../core/player/playback_health.dart';
import '../core/player/playback_ready.dart';
import '../core/playback_eof_trust.dart';
import '../core/playback_failure.dart';
import '../core/playback_fallback.dart';
import '../core/playback_recovery.dart';
import '../core/playback_storm_guard.dart';
import '../core/playback_utils.dart';
import '../core/sources/resolved_playback.dart' show headerOf;
import '../core/player_gestures.dart';
import '../core/search/season_order.dart';
import '../core/player_layout.dart';
import '../core/player_volume.dart';
import '../core/player/mpv_list_encoding.dart';
import '../core/player/player_engine.dart';
import '../core/player/track_preference.dart';
import '../core/progress_throttle.dart';
import '../core/video_media_session.dart';
import '../core/window_fullscreen.dart';
import '../models/models.dart';
import '../models/play_skip.dart';
import '../store/stores.dart';
import '../theme/app_metrics.dart';
import '../theme/app_tokens.dart';
import '../theme/player_overlay_theme.dart';
import '../widgets/jelly/jelly_chip.dart';
import '../widgets/jelly/jelly_progress_bar.dart';
import '../widgets/ui/app_gap.dart';
import '../widgets/ui/app_icons.dart';
import '../widgets/common.dart';
import '../widgets/cast_panel.dart';
import '../widgets/danmaku_settings_sheet.dart';
import '../widgets/download_sheet.dart';
import '../widgets/episode_picker.dart';
import '../widgets/player_episode_drawer.dart';
import '../widgets/player_guide_dialog.dart';
import '../widgets/jelly/jelly_progress_thumb.dart';
import '../widgets/jelly/jelly_sheet_reveal.dart';
import '../widgets/jelly/jelly_value_feedback.dart';
import '../widgets/motion/dock_menu.dart';
import '../widgets/motion/redrawn_arrow.dart';
import '../widgets/danmaku_block_dialog.dart';
import '../widgets/danmaku_overlay.dart';
import '../widgets/playback_error_panel.dart';
import '../widgets/player_controls_surface.dart';
import '../widgets/player_info_dialog.dart';
import '../widgets/player_track_sheet.dart';
import '../widgets/tv_scope.dart';
import '../widgets/loading.dart';

/// 播放器页。
///
/// 播放链路：resolvePlayback 选流 → 受保护流带 contentKey 经 mpv 的
/// demuxer-lavf-o decryption_key 解密（与 guoappxxx 验证过的方案一致）→
/// 完结/手势切换上下集 → 每 5 秒回写本地历史。
class PlayerScreen extends StatefulWidget {
  const PlayerScreen({
    super.key,
    required this.series,
    required this.episodes,
    required this.startIndex,
    this.startAt = Duration.zero,
    this.seasons = const <Season>[],
    this.contentType = '',
    this.keepFullscreen = false,
    this.initialSpeed,
  });

  final Series series;
  final List<Episode> episodes;
  final int startIndex;
  final Duration startAt;

  /// 整部剧的季列表（从详情带过来）；为空表示无跨季能力。
  final List<Season> seasons;

  /// 来源内容类型（短剧 / 漫剧 / 电影），进历史用于「继续观看」分类隔离。
  final String contentType;

  /// 跨季 pushReplacement 时保留已全屏的窗口状态。
  final bool keepFullscreen;

  /// 跨季接续的用户倍速档位（不含长按临时 2x）。
  ///
  /// 为空表示按「按剧记忆 > 全局默认」读取；跨季 `pushReplacement` 新建页面时
  /// 由上一页传入，避免连播换季悄悄回到默认倍速（issue #2 同类路径）。
  final double? initialSpeed;

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen>
    with WidgetsBindingObserver
    implements PlayerHandle {
  // 非 final：引擎周期重建（_episodesPerEngineRebuild）会整体换新实例，
  // 引用方一律读字段而非构造期闭包捕获。
  late PlayerEngine _engine;
  bool _prepared = false;
  bool _disposed = false;

  int _index = 0;
  PlaybackResult? _playback;
  String? _selectedDefinition;
  List<String> _definitions = const [];
  double _speed = 1.0;

  /// 长按倍速状态（按住 2x / 下滑锁定 / 上滑解锁）。
  ///
  /// 与 [_speed] 分离：长按只改引擎速率，**不写**按剧记忆的倍速偏好，
  /// 否则 5 秒节流的进度写盘会把临时 2x 当成用户选择存进历史。
  HoldSpeedState _holdSpeed = const HoldSpeedState();

  /// 实际生效倍速（用户档位 × 长按锁定）。换集/换线/缓存开播与弹幕都用它。
  ///
  /// 不能直接读 `_holdSpeed.rate`：未长按时它返回默认 baseRate=1.0，
  /// 会把用户倍速静默打回 1x（issue #2 回归）。
  double get _effectiveRate => _holdSpeed.effectiveRate(_speed);

  /// 控制栏显示的倍速：长按/锁定期间显示 2x，避免「在放 2x 但按钮写 1.0x」。
  double get _displaySpeed => _effectiveRate;

  /// 本页生命周期内是否已经尝试过弹指南（防止换集/换线重复触发）。
  bool _guideShown = false;

  /// 字幕时差（秒；mpv sub-delay，正=延后）。按剧记忆，开播时注入。
  double _subDelay = 0;

  /// 音轨/字幕选择按剧记忆（面板展示序；字幕 -1=关闭）。
  int? _prefAudioIndex;
  int? _prefSubtitleIndex;
  String? _prefAudioKey;
  String? _prefSubtitleKey;
  bool _trackPrefApplied = false;
  StreamSubscription? _tracksSub;

  /// 这部剧的清晰度偏好：初始化自该剧本的历史，跟随用户切换而更新。
  String _quality = '';

  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  bool _showControls = true;

  /// 桌面：鼠标指针是否可见（与控制栏显隐**解耦**，11-19 用户要求）。
  ///
  /// 用户要的行为：控制栏隐藏后鼠标移动**不**让控制栏回来，只让指针
  /// 重新可见；指针静止几秒后再消失。指针可见性原先直接绑在
  /// `_showControls` 上（隐藏即 `SystemMouseCursors.none`），无法表达
  /// 「控制栏隐藏但指针因移动而可见」，故拆成独立状态。
  bool _pointerVisible = true;

  /// 指针隐藏计时：鼠标停止移动后多久隐藏指针（控制栏隐藏态才生效）。
  Timer? _pointerHideTimer;

  /// 当前打开着的浮层菜单数量（dock / PopupMenu 各算一个）。
  ///
  /// 控制栏是 `if (_showControls)` 条件挂载的：4s 自动隐藏会把菜单连同
  /// OverlayPortal 一起卸载（用户实测「菜单刚点开就消失」）。计时器到点时
  /// 只要还有菜单开着就顺延，不用把控制栏改成常驻。
  int _menuOpenCount = 0;

  /// 取流空响应（`PLAYBACK_UNAVAILABLE`）的自动重试：已试次数 + 计时器。
  int _autoRetryCount = 0;
  Timer? _autoRetryTimer;

  /// 当前集的目标起点（最近一次 _openEpisode 传入的 startAt）。
  ///
  /// 错误面板重试必须用它：重试语义是「重新加载这一集」，归零起播会把
  /// 断点冲掉——回退保护虽然能保住盘上的旧断点，但用户观感是「从头播了」
  /// （安卓实测：选集 25s → 起播失败 → 重试 → 从 0 重播）。
  Duration _episodeStartAt = Duration.zero;

  /// 重试起播点：目标起点优先；连播场景（起点 0）退回同集历史断点。
  /// 查不到断点才归零——重试绝不静默从头播。
  Duration get _retryStartAt {
    if (_episodeStartAt > Duration.zero) return _episodeStartAt;
    final existing = _history.get(widget.series.id);
    final ep =
        widget.episodes[_index.clamp(0, widget.episodes.length - 1)];
    if (existing != null &&
        existing.episode == ep.number &&
        existing.position > 0) {
      return Duration(seconds: existing.position.floor());
    }
    return Duration.zero;
  }

  /// 引擎播放态：弹幕层用它对齐「暂停时冻结」的既有行为（源播放器同款）。
  bool _playing = false;

  /// 弹幕：当前集已拉取的条目（bili 形状喂给 DanmakuOverlay）+ 按集翻页仓库。
  /// 拉取失败静默降级——弹幕是装饰性功能，不影响播放主链路。
  List<bili.DanmakuItem> _danmaku = const [];
  /// 弹幕时间轴的重置令牌：seek / 换集 / 换线时递增。
  ///
  /// 弹幕层只在这个令牌变化时允许时间轴回退；单纯的位置事件回退
  /// （缓冲、切轨、事件乱序）按抖动处理，避免弹幕「飘过去又闪回来」。
  int _danmakuEpoch = 0;
  DanmakuRepository? _danmakuRepo;
  /// 最近一次拉取弹幕的集 ID；换集时用它丢弃仓库里上一集的缓存。
  ///
  /// 仓库按集 ID 无界累积（每集 items+seen 数十万字节级），222 集 binge
  /// 一次会话会留 250MB 量级——仓库注释里的 drop() 就是为此而写，11-20
  /// 取证发现从未被调用（死代码）。
  String? _danmakuEpisodeId;
  Timer? _hideTimer;
  StreamSubscription<Duration>? _posSub;
  StreamSubscription<Duration>? _durSub;
  StreamSubscription<bool>? _completedSub;
  StreamSubscription<bool>? _playingSub;
  StreamSubscription<PlayerLog>? _logSub;
  StreamSubscription<bool>? _bufferingSub;
  bool _buffering = false;

  /// 慢缓冲判定器：把「卡」分成起播超时/长缓冲/频繁/累计，命中后记线路健康度。
  final PlaybackBufferMonitor _bufferMonitor = PlaybackBufferMonitor();

  /// 错误风暴限流：相同 raw 错误 1s 内 ≥3 次（错密钥解 CENC 音频时每秒数百条
  /// `Error decoding audio`）→ 停止逐条记录与逐次决策，聚合一条后直接收尾。
  /// 每次成功开播重置（换线/换集后的错误是新一轮证据）。
  final PlaybackStormGuard _stormGuard = PlaybackStormGuard();

  /// 位置跳变超过这个幅度就当作 seek（3 倍速正常播放远小于它）。
  static const Duration _seekJumpThreshold = Duration(seconds: 5);

  /// dispose 里不能再查 context：历史 store 先缓存一次。
  late final HistoryStore _history = AppScope.read(context).history;
  Timer? _bufferTimer;

  /// 加载超时兜底：长时间无时长且无进度 → 停流并给错误面板（防 broken
  /// stream 无限挂着，缩小 native 层异常窗口；用户实测崩溃场景）。
  Timer? _loadWatchdog;

  /// mpv 引擎日志环形缓冲（诊断面板用）。
  final RecentLogBuffer _logBuffer = RecentLogBuffer();
  StreamSubscription<String>? _errorSub;
  String? _rawPlaybackError;
  PlaybackFailure? _playbackFailure;

  /// 历史写盘节流 + 并发保护。
  final ProgressWriteThrottle _historyThrottle = ProgressWriteThrottle();
  bool _historyWriteInFlight = false;

  /// 本集是否已自然播完（防止 stop / dispose 用未完成进度覆盖「已看完」）。
  bool _episodeEnded = false;

  /// 当前线路是否已记过「时长就绪」日志（每条线路一次，换线/重开重置）。
  bool _durationLogged = false;

  /// 续播保护：换线/切清晰度/本地起播的期望位置。
  ///
  /// 新线路从 0 起播、起播 seek 又没生效时，位置事件会一路从中段掉到 0；
  /// 旧实现直接用它覆盖 `_position` 与历史断点，用户看到「跳回开头」。
  /// 目标未到位前不采信位置事件，允许一次补救 seek，8 秒仍不到位才放弃。
  Duration? _resumeTarget;
  DateTime? _resumeArmedAt;
  bool _resumeRetried = false;

  /// 用户主动 seek 后允许一次历史回退写盘（回拖是用户意图）。
  bool _allowHistoryRewind = false;

  /// 本集内最近一次用户显式 seek 的目标秒数（0 = 未 seek）。
  ///
  /// 拖到近片尾后自然播完时，服务端时长/续播下限可能都缺、watched 又不够
  /// 45s——显式 seek 是「用户亲手把播放头移到这里」的正证据，作为 EOF
  /// 真值判定的第三层下限（2026-11-19 误判「流异常中断」现场）。
  double _lastExplicitSeekSec = 0;

  /// 位置回退日志节流（拖动时会连续回退，避免刷屏）。
  DateTime? _lastRewindLogAt;

  /// 智能换线状态。
  final Set<String> _triedUrls = {};
  List<PlaybackCandidate> _candidates = const [];
  Timer? _fallbackTimer;
  bool _fallbackInFlight = false;

  /// 本集自动恢复预算（换线次数上限，防「错误→防抖→换线」循环折腾）。
  final PlaybackRecoveryBudget _recoveryBudget = PlaybackRecoveryBudget();
  int _playEpoch = 0;
  Duration _attemptStart = Duration.zero;
  static const Duration _earlyWindow = Duration(seconds: 15);

  /// 本集是否已经重新解析过播放地址（签名 URL 过期兜底，每集只做一次）。
  bool _reResolved = false;
  bool _reResolving = false;

  /// 换集 epoch：快速连点时，旧的解析结果直接丢弃。
  int _openEpoch = 0;

  /// 片头片尾。
  PlaySkipEntry? _playSkip;
  bool _openingNoticePending = false;
  bool _endingHandled = false;

  /// 累计「位置真实前进量」（秒）：相邻位置正增量之和、忽略 seek 跳变。
  /// broken stream 可以谎报 duration/position 甚至提前发 completed，
  /// 但**无法伪造平滑的位置推进**——这是自动连播的硬判据（用户实测：
  /// 加载不出来 → completed 提前发 → 误标已看完 + 连跳集数）。
  double _watchedSeconds = 0;
  Duration _lastWatchPos = Duration.zero;

  /// 静音起播提醒（同一部剧只提醒一次，进程内去重）。
  static final MutedPlaybackHintRegistry _mutedHints =
      MutedPlaybackHintRegistry();
  bool _mutedHintVisible = false;

  Timer? _mutedHintTimer;

  /// 播放器 OSD。
  String? _osdText;
  IconData? _osdIcon;
  Timer? _osdTimer;

  // Windows 系统媒体控制（SMTC）。
  SMTCWindows? _smtc;
  StreamSubscription<PressedButton>? _smtcSub;
  int _lastSmtcSecond = -1;

  // Android 系统媒体会话（A7）的进度节流（每秒最多一次，系统按倍速外推）。
  int _lastVideoMediaSecond = -1;

  // 手势状态。
  Timer? _sleepTimer;
  int _sleepMinutes = 0;

  /// 当前播放的流（备用容错用）；本地播放为 null。
  VideoStream? _currentVideoStream;

  /// 投屏解密中继会话（castrelay.go）：投屏结束/退出时回收。
  String? _relaySession;

  /// 该会话服务的**源**地址与产物地址（11-10 P0）：重新打开投屏面板时据此
  /// 判断「能不能复用现有中继」——同一 URL 直接复用，绝不为了看一眼管理页
  /// 再起第二个 ffmpeg（双拉同一签名流会把正在播的电视拖停）。
  String _relaySourceUrl = '';
  String _relayProductUrl = '';

  /// 中继会话对应的 API 引用（M4-1）：回收路径（[_stopRelayIfAny]）可能发生在
  /// await 之后甚至页面已卸载时，不能再摸 context 取 api，随会话存引用。
  AquaApi? _relayApi;

  /// 连播预解析：集下标 → 已解析的播放结果（本会话内复用）。
  final Map<int, PlaybackResult> _prefetched = {};

  double? _dragStartPos;
  double? _seekPreviewMs;
  double? _overlayValue;

  /// 移动端全屏竖直滑动累计位移：上滑为负（下一集），下滑为正（上一集）。
  double _verticalDragDy = 0;

  /// 竖直滑动切集的位移阈值（dp）：低于它视为误触，不做任何动作。
  static const double _verticalSwipeThreshold = 60;

  Object? _loadError;
  bool _loadingStream = true;
  bool _fittedWindow = false;

  /// 电视形态（启动时判定一次，见 TvScope）。
  bool _isTv = false;

  // ---------- Android 原生画中画（PiP）----------
  //
  // 入口只放「更多」菜单：底栏槽位恒定，横屏/竖屏按钮永远不会被挤掉
  // （1.12.21 之前常驻底栏，360dp 竖屏下直接溢出）。
  //
  // 探测不通过就完全不渲染入口——不依赖系统 toast 告诉用户「不支持」。

  /// 静态探测通过，且本应用版本没有被实际进入失败否定。
  bool _pipSupported = false;

  /// 是否已发起过探测（`didChangeDependencies` 可能多次触发）。
  bool _pipProbeStarted = false;

  /// 当前处于系统 PiP 小窗：控制栏 / 手势层 / 弹幕 / OSD 一律不渲染。
  bool _inPip = false;

  /// PiP 监听身份句柄。dispose 时按身份摘除——跨季 `pushReplacement` 是新页
  /// 先 attach、旧页后 dispose，无条件摘除会擦掉新页的回调。
  Object? _pipListener;

  /// 本页曾真正进入过 PiP（过滤 ROM 误发的 onPipClosed，避免误暂停）。
  bool _pipEntered = false;

  /// 应用版本号（`version+buildNumber`），懒取一次，供失败记忆比对。
  String? _appVersion;

  /// 遥控器长按左右键的连发定时器与累计位移。
  Timer? _seekRepeat;
  Duration _seekAccum = Duration.zero;

  /// 当前音量（0-100），由 `stream.volume` 同步驱动底栏滑块。
  double _volume = 100;

  /// 静音前的音量：取消静音时回到这个值，而不是硬拉 100。
  double _lastVolume = 100;

  StreamSubscription<double>? _volumeSub;

  /// 桌面迷你置顶小窗状态（还原时恢复原窗口位置）。
  bool _mini = false;
  Rect? _preMiniBounds;

  /// 桌面「铺满」模式：画面 cover 裁剪填充窗口（抖音式），再点切回 contain。
  bool _fill = false;

  /// 播放方向：auto = 跟随传感器；locked = 由「横屏/竖屏」按钮锁定。
  ///
  /// 移动端进页**一律先竖屏**（含横屏电影），横屏画面靠 `BoxFit.contain`
  /// 在竖屏容器里上下留黑边；用户旋转设备或点按钮才横过来。
  _OrientationMode _orientMode = _OrientationMode.auto;
  bool _lockedLandscape = false;

  /// 首次 `_applyOrientation` 已执行（换集不再强制竖屏）。
  bool _orientationReady = false;
  Timer? _orientationUnlockTimer;

  bool get _isDesktop =>
      Platform.isWindows || Platform.isMacOS || Platform.isLinux;

  @override
  void initState() {
    super.initState();
    // 恢复 PiP 态校正（部分 ROM 不回 onPictureInPictureModeChanged）。
    WidgetsBinding.instance.addObserver(this);
    // 跨季换乘：窗口本来就是全屏，先把 UI 状态同步上，右侧选集热区立即可用。
    if (widget.keepFullscreen) _fullscreen = true;
    if (widget.episodes.isEmpty) {
      // 防御：调用方应保证非空；空列表直接报错态而不是崩溃。
      _loadingStream = false;
      _loadError = AquaException(
          code: AquaCode.contentUnavailable,
          message: '没有可播放的分集',
          retryable: false);
      return;
    }
    _index = widget.startIndex.clamp(0, widget.episodes.length - 1);
    // 播放偏好按剧记忆：上次用的倍速/清晰度优先，否则用全局默认。
    final scope = AppScope.read(context);
    final prefs = scope.history.get(widget.series.id);
    // 跨季接续优先用上一页传入的档位；否则按剧记忆 > 全局默认。
    _speed = widget.initialSpeed ??
        ((prefs != null && prefs.speed > 0)
            ? prefs.speed
            : (double.tryParse(scope.settings.defaultSpeed) ?? 1.0));
    _quality = (prefs != null && prefs.quality.isNotEmpty)
        ? prefs.quality
        : scope.settings.defaultQuality;
    _subDelay = (prefs?.subtitleDelayMs ?? 0) / 1000.0;
    _prefAudioIndex = prefs?.audioTrackIndex;
    _prefSubtitleIndex = prefs?.subtitleTrackIndex;
    _prefAudioKey =
        (prefs?.audioTrackKey ?? '').isEmpty ? null : prefs!.audioTrackKey;
    _prefSubtitleKey = (prefs?.subtitleTrackKey ?? '').isEmpty
        ? null
        : prefs!.subtitleTrackKey;
    // 恢复上次音量；滑块状态由 stream.volume 双向同步（滚轮/滑块/静音改也跟得上）。
    // 先读后建：_createAndWireEngine 会把音量应用到新引擎。
    _volume = AppScope.read(context).settings.volume;
    _lastVolume = _volume > 0 ? _volume : 100;
    _createAndWireEngine();
    // 投屏：电视端主动停止时按设置回本地续播（M1：加密分集不可投，入口处拦截）。
    castController.onRemoteStopped = (device, position) {
      if (!mounted) return;
      unawaited(_stopRelayIfAny());
      _resumeLocalAfterCast(
        position,
        // mounted 已确认且中间无 await，此处读 context 安全（M4-1 审计口径）。
        resumeLocal: AppScope.read(context)
                .settings
                .castDisconnectBehavior ==
            'resumeLocal',
      );
    };
    // 中断自动恢复成功（11-07-cast-auto-reconnect）：toast 一次固定文案
    // （SnackBar 全局可见，投屏面板开与不开都显示）。
    castController.onAutoReconnected = () {
      if (!mounted) return;
      _showToast('已自动恢复投屏');
    };
    // 投屏连接断开（11-07-cast-reliability R1）：电视不可达（复检失败/恢复
    // 失败）时会话静默结束，这里给用户一个明确提示（与 onAutoReconnected
    // 同一注入模式；固定文案，原始异常只进诊断日志）。
    castController.onSessionLost = (device) {
      if (!mounted) return;
      _showToast('投屏连接已断开');
    };
    _playSkip = AppScope.read(context).playSkip.entryFor(widget.series.id);
    WakelockPlus.enable();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    PlayerBus.instance.attach(this);
    if (Platform.isWindows) _initSmtc();
    // A7：Android 系统媒体会话（通知栏/锁屏/熄屏播放）。
    if (Platform.isAndroid) _initVideoMedia();
    // 播放页的首次打开都源于用户动作（详情页点「第 N 集」/继续播放/立即播放）：
    // 立刻把「想去这一集」写进历史，否则起播慢/失败时退出，历史还停在旧集。
    // 页内的自动连播/换线不经这里，语义不变。
    //
    // 11-19：首集预热与开挂并行 —— 先把取流挂上，`_openEpisode` 走到取流
    // 时结果通常已在手（`_prefetched` 命中 → 零等待），消掉「进页黑屏
    // 1~2 秒」。失败静默，主路径照常报错。
    _prefetchFirst();
    _openEpisode(_index, widget.startAt, manual: true);
  }

  /// 创建引擎并接上全部事件订阅（initState 调用；dispose 走
  /// [_teardownEngine] 对称拆除）。
  ///
  /// 只做引擎耦合的部分；投屏回调 / PlayerBus / SMTC 等屏幕级接线留在
  /// initState（attach 不幂等，不能重复）。音量由调用方先读好（[_volume]）。
  void _createAndWireEngine() {
    _engine = MpvPlayerEngine();
    // 轨道就绪事件驱动：每集只应用一次偏好（换集重置标记）。
    _tracksSub = _engine.stream.tracks.listen((_) => _applyTrackPreference());
    unawaited(_installMpvOptions());
    _engine.setVolume(_volume);
    _volumeSub = _engine.stream.volume.listen((v) {
      if (!mounted || v == _volume) return;
      setState(() {
        _volume = v;
        if (v > 0) _lastVolume = v;
      });
    });
    _posSub = _engine.stream.position.listen(_onPosition);
    _durSub = _engine.stream.duration.listen((d) {
      if (!mounted) return;
      setState(() => _duration = d);
      // A7：时长就绪刷新媒体通知（MediaItem 时长变化触发元数据重建）。
      _syncVideoMedia();
      // 每条线路记一次时长就绪：引擎元数据 vs 服务端真值并排进日志，
      // 排查「连播间隔异常短」时可直接对账（流截断/谎报 vs 倍速/集短）。
      if (d > Duration.zero && !_durationLogged) {
        _durationLogged = true;
        final host =
            Uri.tryParse(_currentVideoStream?.url ?? '')?.host ?? '';
        ErrorLog.instance.record(
          '播放',
          '时长就绪 dur=${(d.inMilliseconds / 1000).toStringAsFixed(1)}s'
          ' · server=${_playback?.playback.durationSeconds ?? 0}s'
          '${host.isEmpty ? '' : ' · host=$host'}',
        );
      }
    });
    _playingSub = _engine.stream.playing.listen((playing) {
      if (!playing && _prepared && !_disposed) _flushHistory();
      if (playing) _bufferMonitor.onPlaying();
      if (mounted) setState(() => _playing = playing);
      // A7：Android 通知栏/锁屏跟随播放态（会话内部短路，桌面零流量）。
      _syncVideoMedia();
      if (!Platform.isWindows) return;
      try {
        _smtc?.setPlaybackStatus(
            playing ? PlaybackStatus.playing : PlaybackStatus.paused);
      } catch (_) {}
    });
    _completedSub = _engine.stream.completed.listen((completed) {
      if (completed) _onEnded();
    });
    _errorSub = _engine.stream.error.listen(_onPlaybackError);
    _logSub = _engine.stream.log.listen((log) {
      _logBuffer.add('[${log.level}] ${log.text}');
    });
    _bufferingSub = _engine.stream.buffering.listen((buffering) {
      _bufferMonitor.onBuffering(buffering);
      if (mounted) setState(() => _buffering = buffering);
      // A7：缓冲态映射到媒体通知的 processingState。
      _syncVideoMedia();
    });
  }

  /// 撤销 [_createAndWireEngine] 的全部接线并释放引擎实例。
  ///
  /// dispose 与周期重建共用。取消订阅是同步的；engine.dispose 的完成可以
  /// 滞后——新旧 mpv 实例短暂共存是安全的（各自独立上下文）。
  void _teardownEngine() {
    _tracksSub?.cancel();
    _volumeSub?.cancel();
    _posSub?.cancel();
    _durSub?.cancel();
    _completedSub?.cancel();
    _playingSub?.cancel();
    _errorSub?.cancel();
    _logSub?.cancel();
    _bufferingSub?.cancel();
    _engine.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // TvScope 运行期不变，这里只是取一次；放 didChangeDependencies 而不是
    // build，避免每次重建都去查 InheritedWidget。
    _isTv = TvScope.isTvOf(context);
    _initPip();
  }

  // ---------- Android 原生画中画（PiP）----------

  /// 探测能力并订阅 PiP 事件。只在 Android 且非电视形态下发起。
  void _initPip() {
    if (_pipProbeStarted || !Platform.isAndroid || _isTv) return;
    _pipProbeStarted = true;
    _pipListener = bindPipStateListener(
      onChanged: _onPipChanged,
      onDismissed: _onPipClosed,
    );
    unawaited(_probePip());
  }

  Future<void> _probePip() async {
    final capability = await probePipCapability();
    if (!mounted) return;
    // 通道瞬时失败（引擎重建等）：结论不可信，不复用，允许下次依赖变更重试。
    if (capability.reason == 'channel_error') {
      _pipProbeStarted = false;
      return;
    }
    final version = await _currentAppVersion();
    if (!mounted) return;
    final show = shouldShowPipEntry(
      isAndroid: Platform.isAndroid,
      isTv: _isTv,
      capability: capability,
      unsupportedVersion: AppScope.read(context).settings.pipUnsupportedVersion,
      appVersion: version,
    );
    if (show != _pipSupported) setState(() => _pipSupported = show);
    // 上一次异常离场可能把 _inPip 留在 true：用原生真值校正。
    if (await isInPip() && mounted) _onPipChanged(true);
  }

  /// 应用版本号（`version+buildNumber`）。取不到返回空串——空串不参与
  /// 「同版本已失败」比对，避免 `unknown == unknown` 让入口永久消失。
  Future<String> _currentAppVersion() async {
    final cached = _appVersion;
    if (cached != null) return cached;
    try {
      final info = await PackageInfo.fromPlatform();
      _appVersion = '${info.version}+${info.buildNumber}';
    } catch (_) {
      _appVersion = '';
    }
    return _appVersion!;
  }

  /// 进入画中画：宽高比取当前流真实尺寸，缺省按剧（竖屏 9:16 / 横屏 16:9）。
  ///
  /// 原生返回 `false` 表示设备/ROM 拒绝：立刻隐藏入口 + 记住本版本失败，
  /// 避免每次启动都出现一个点了必然失败的菜单项。
  Future<void> _enterPip() async {
    double aspect;
    try {
      final pb = _playback;
      final stream = pb != null ? _currentStream(pb.playback) : null;
      if (stream != null && stream.width > 0 && stream.height > 0) {
        aspect = stream.width / stream.height;
      } else {
        final ep = widget.episodes[_index.clamp(0, widget.episodes.length - 1)];
        aspect = ep.vertical ? 9 / 16 : 16 / 9;
      }
    } catch (_) {
      // `_currentStream` 在流列表为空时会抛 StateError；入口是用户可点的，
      // 不能让异常冒成未捕获异步错误（否则点了静默无效）。
      aspect = kDefaultPipAspectRatio;
    }
    final ok = await enterPip(aspectRatio: aspect);
    if (ok || !mounted) return;
    final version = await _currentAppVersion();
    if (!mounted) return;
    // 版本号取不到时不写记忆：否则下次 `'' == ''` 会把入口永久判死。
    if (version.isNotEmpty) {
      AppScope.read(context).settings.pipUnsupportedVersion = version;
    }
    setState(() => _pipSupported = false);
    _showOsd(Icons.picture_in_picture, '当前设备不支持画中画');
  }

  /// 进入 / 退出 PiP：激活态只留画面（控制栏、手势层、弹幕、OSD 全卸载）。
  void _onPipChanged(bool inPip) {
    if (!mounted || _inPip == inPip) return;
    _hideTimer?.cancel();
    _pointerHideTimer?.cancel();
    _osdTimer?.cancel();
    setState(() {
      _inPip = inPip;
      if (inPip) _pipEntered = true;
      // 小窗里没有可点控件：进入即收起，展开即恢复可操作状态。
      _showControls = !inPip;
      if (inPip) {
        _osdText = null;
        _osdIcon = null;
      }
    });
    if (!inPip) _scheduleHide();
  }

  /// 用户划掉小窗（不是展开）：暂停播放并立即落盘进度。
  ///
  /// 只有本页真的进过 PiP 才响应：ROM 误发该事件时不得误暂停。
  void _onPipClosed() {
    if (!mounted || !_pipEntered) return;
    _pipEntered = false;
    unawaited(_engine.pause());
    unawaited(_recordHistory(finished: false));
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 部分 ROM 不回 onPictureInPictureModeChanged：回到前台时用原生真值
    // **双向**校正——漏了「进入」会让控制栏留在小窗里，漏了「退出」会让
    // 控制层永久消失。
    if (state != AppLifecycleState.resumed || !Platform.isAndroid) return;
    if (!_pipProbeStarted) return;
    unawaited(isInPip().then((inPip) {
      if (mounted && inPip != _inPip) _onPipChanged(inPip);
    }));
  }

  // ---------- Windows 系统媒体控制（SMTC）：媒体键 + 音量浮层 ----------

  /// 每秒最多同步一次时间轴，避免高频调用系统接口。
  void _syncSmtcTimeline() {
    if (!Platform.isWindows) return;
    final second = _position.inSeconds;
    if (second == _lastSmtcSecond) return;
    _lastSmtcSecond = second;
    try {
      _smtc?.updateTimeline(PlaybackTimeline(
        startTimeMs: 0,
        endTimeMs: _duration.inMilliseconds,
        positionMs: _position.inMilliseconds,
        minSeekTimeMs: 0,
        maxSeekTimeMs: _duration.inMilliseconds,
      ));
    } catch (_) {}
  }

  /// 初始化系统媒体控制：键盘媒体键、蓝牙耳机、音量浮层都能看到并控制播放。
  /// 失败（如系统不支持）只静默放弃，不影响播放本身。
  Future<void> _initSmtc() async {
    try {
      await SMTCWindows.initialize();
      _smtc = SMTCWindows(
        config: const SMTCConfig(
          fastForwardEnabled: true,
          nextEnabled: true,
          pauseEnabled: true,
          playEnabled: true,
          rewindEnabled: true,
          prevEnabled: true,
          stopEnabled: false,
        ),
        metadata: MusicMetadata(
          title: widget.series.title,
          album: '阿圈短剧',
          thumbnail: widget.series.coverUrl,
        ),
      );
      _smtcSub = _smtc!.buttonPressStream.listen((event) {
        if (!mounted || _disposed) return;
        switch (event) {
          case PressedButton.play:
            _engine.play();
          case PressedButton.pause:
            _engine.pause();
          case PressedButton.next:
            _goNext(manual: true);
          case PressedButton.previous:
            _goPrev(manual: true);
          case PressedButton.fastForward:
            unawaited(_seekBy(const Duration(seconds: 10)));
          case PressedButton.rewind:
            unawaited(_seekBy(const Duration(seconds: -10)));
          default:
            break;
        }
      });
      _smtc!.setPlaybackStatus(PlaybackStatus.playing);
    } catch (_) {
      _smtc = null;
    }
  }

  /// 分集切换后同步系统媒体浮层的标题。
  void _updateSmtcMetadata() {
    if (!Platform.isWindows || _smtc == null) return;
    final ep = widget.episodes[_index.clamp(0, widget.episodes.length - 1)];
    try {
      _smtc?.updateMetadata(MusicMetadata(
        title: '${widget.series.title} · 第${ep.number}集',
        album: '阿圈短剧',
        thumbnail: widget.series.coverUrl,
      ));
    } catch (_) {}
  }

  // ---------- Android 系统媒体会话（A7）：通知栏 / 锁屏 / 熄屏播放 ----------

  /// 进入播放页接管系统媒体会话：命令（播放/暂停/拖动/换集）经复合路由
  /// （media_session_hub）回到本页回调；状态由各事件源推送。听书在播时
  /// hub 会先让它走既有 stop 命令停播（互斥让位）。
  /// 媒体会话失败绝不影响播放（与 Windows SMTC 同口径）。
  Future<void> _initVideoMedia() async {
    try {
      await VideoMediaSession.instance.attach(
        this,
        onPlay: () => _engine.play(),
        onPause: () => _engine.pause(),
        onSeek: (position) => unawaited(_seekTo(position)),
        onNext: () => _goNext(manual: true),
        onPrev: () => _goPrev(manual: true),
      );
      _syncVideoMedia();
    } catch (_) {}
  }

  /// 全量同步当前快照：播放态翻转 / 缓冲 / 时长就绪 / 换集后调用。
  /// 非 Android 桥本身不激活（hub no-op），这里再短路一次省掉无谓的快照拼装。
  void _syncVideoMedia() {
    if (!Platform.isAndroid) return;
    final ep = widget.episodes[_index.clamp(0, widget.episodes.length - 1)];
    unawaited(VideoMediaSession.instance.publish(VideoMediaState(
      mediaId: ep.id,
      seriesTitle: widget.series.title,
      episodeNumber: ep.number,
      artUri: widget.series.coverUrl,
      // 时长未知给 null：拿 0 冒充总长会让锁屏进度条一直是满的（听书同口径）。
      duration: _duration > Duration.zero ? _duration : null,
      playing: _playing,
      buffering: _buffering,
      position: _position,
      speed: _displaySpeed,
      // 与 _goNext/_goPrev 同语义：跨季可进、首集禁用上一集。
      canNext: _index < widget.episodes.length - 1 ||
          nextPlayableSeason(widget.seasons, widget.series.id) != null,
      canPrev: _index > 0,
    )));
  }

  /// 进度同步：每秒最多一次（updatePosition 带时间戳，系统按倍速外推，
  /// 事件点已有校准）。
  void _syncVideoMediaPosition() {
    final second = _position.inSeconds;
    if (second == _lastVideoMediaSecond) return;
    _lastVideoMediaSecond = second;
    _syncVideoMedia();
  }

  /// mpv 全局参数：解密、协议白名单、硬件解码、缓冲、音画同步、画面比例。
  Future<void> _installMpvOptions() async {
    final settings = AppScope.read(context).settings;
    await _engine.setProperty('network-timeout', '20');
    await _engine.setProperty('cache', 'yes');
    await _engine.setProperty('demuxer-max-bytes', '64MiB');
    await _engine.setProperty('force-seekable', 'yes');
    // Android 走 mediacodec；其余平台用用户选择的硬解方式（白名单已校验）。
    // 默认值是 auto-copy（拷回）：零拷贝直通在 ANGLE 下会因解码纹理 16 像素对齐
    // 在画面右侧/底部留下绿边，见 SettingsStore.defaultHwdecMode。
    final hwdec = Platform.isAndroid
        ? (settings.hwdecMode == 'no' ? 'no' : 'mediacodec')
        : settings.hwdecMode;
    await _engine.setProperty('hwdec', hwdec);
    await _engine.setProperty('cache-secs', '${settings.cacheSecs}');
    await _engine.setProperty(
        'audio-delay', (settings.audioDelayMs / 1000).toStringAsFixed(3));
    await _engine.setProperty(
      'video-aspect-override',
      switch (settings.scale) {
        '16:9' => '16:9',
        '4:3' => '4:3',
        _ => '-1',
      },
    );
    // 填充 = 保持比例放大并裁掉溢出部分（panscan）。
    await _engine.setProperty(
        'panscan', settings.scale == 'fill' ? '1.0' : '0');
    // 字幕样式。
    await _engine.setProperty(
        'sub-font-size', '${settings.subtitleFontSize}');
    await _engine.setProperty(
        'sub-border-size', settings.subtitleBorder ? '3' : '0');
    await _engine.setProperty('sub-back-color',
        settings.subtitleBackground ? '#80000000' : '#00000000');
    // 字幕时差按剧记忆（每次开播注入，换剧即切换）。
    await _engine.setProperty('sub-delay', '$_subDelay');
  }


  @override
  void dispose() {
    // 长按状态不跨实例保留；引擎由基类统一释放，这里只清 UI 状态。
    _holdSpeed = const HoldSpeedState();
    _edgeCloseTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    // PiP 回调按**身份**摘除：跨季 pushReplacement 是新页先 attach、旧页后
    // dispose，无条件摘除会把新页刚注册的回调擦掉（该页 PiP 从此全静默）。
    final pipListener = _pipListener;
    if (pipListener != null) {
      unbindPipStateListener(pipListener);
      _pipListener = null;
    }
    if (castController.onRemoteStopped != null) {
      castController.onRemoteStopped = null;
    }
    castController.onAutoReconnected = null;
    castController.onSessionLost = null;
    unawaited(_stopRelayIfAny());
    PlayerBus.instance.detach(this);
    // 记住本次音量，下次启动恢复。
    try {
      AppScope.read(context).settings.volume = _engine.state.volume;
    } catch (_) {}
    if (!_episodeEnded) _recordHistory(finished: false);
    _sleepTimer?.cancel();
    _hideTimer?.cancel();
    _pointerHideTimer?.cancel();
    _autoRetryTimer?.cancel();
    _fallbackTimer?.cancel();
    _stopSeekRepeat();
    _osdTimer?.cancel();
    _mutedHintTimer?.cancel();
    _teardownEngine();
    _bufferTimer?.cancel();
    _loadWatchdog?.cancel();
    _smtcSub?.cancel();
    try {
      _smtc?.dispose();
    } catch (_) {}
    _smtc = null;
    // A7：退出播放页停用视频媒体会话（通知收敛）。跨季 pushReplacement 时
    // 新页已先 attach（owner 不配对），这里无害跳过、会话由新页续持。
    unawaited(VideoMediaSession.instance.detach(this));
    _disposed = true;
    // 全屏/置顶残留会把主窗口卡在全屏态：退播放页时还原（含自建全屏的
    // 标题栏与 bounds 恢复）。跨季换乘时由新页继承窗口状态，这里跳过。
    if (_isDesktop && !_skipFullscreenRestoreOnDispose) {
      unawaited(() async {
        try {
          if (await windowManager.isFullScreen()) {
            await _applyFullscreen(false);
          }
        } catch (_) {}
      }());
    }
    WakelockPlus.disable();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    _orientationUnlockTimer?.cancel();
    _restoreOrientation();
    super.dispose();
  }

  void _restoreOrientation() {
    if (_isDesktop) return;
    // 退出播放器后交还给系统，首页可自由旋转。
    SystemChrome.setPreferredOrientations(DeviceOrientation.values);
  }

  /// 进页首次摆正：**一律先竖屏**（含横屏电影），随后按模式放开给传感器。
  ///
  /// 换集不再强制竖屏，也不重置用户的手动锁定——横屏看剧换集被掰回竖屏很难受。
  void _applyOrientation() {
    if (_isDesktop) return;
    if (_orientationReady) {
      if (_orientMode == _OrientationMode.auto) _applyAutoOrientation();
      return;
    }
    _orientationReady = true;
    _portraitOnly();
    if (_orientMode != _OrientationMode.auto) return;
    // 立刻竖屏 → 400ms 后放开三方向：既满足「进页竖屏」，又让物理旋转能生效。
    // 锁定方向后 MediaQuery 不再变化，跟随传感器只能交给系统按
    // preferredOrientations 处理（在 build 里判断会形成锁定循环）。
    _orientationUnlockTimer?.cancel();
    _orientationUnlockTimer = Timer(const Duration(milliseconds: 400), () {
      if (!mounted || _orientMode != _OrientationMode.auto) return;
      _applyAutoOrientation();
    });
  }

  void _portraitOnly() {
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  }

  void _applyAutoOrientation() {
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
  }

  void _applyLockedOrientation() {
    if (_lockedLandscape) {
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
    } else {
      _portraitOnly();
    }
  }

  /// 「横屏/竖屏」按钮：自动 ⇄ 锁定；锁定方向取当前姿态的反方向。
  void _toggleOrientation() {
    if (_isDesktop) return;
    final isLandscape =
        MediaQuery.orientationOf(context) == Orientation.landscape;
    _orientationUnlockTimer?.cancel();
    setState(() {
      if (_orientMode == _OrientationMode.auto) {
        _orientMode = _OrientationMode.locked;
        _lockedLandscape = !isLandscape;
      } else {
        _orientMode = _OrientationMode.auto;
      }
    });
    if (_orientMode == _OrientationMode.locked) {
      _applyLockedOrientation();
    } else {
      _applyAutoOrientation();
    }
  }

  /// 桌面端首次打开视频时，把窗口调成和片源一致的比例（参考「自动摆正」）。
  Future<void> _maybeFitWindow(VideoStream stream, Episode episode) async {
    if (!_isDesktop || _fittedWindow) return;
    _fittedWindow = true;
    final settings = AppScope.read(context).settings;
    if (!settings.autoFitWindow) return;
    await _fitWindowToStream(stream, episode);
  }

  Future<void> _fitWindowToStream(VideoStream stream, Episode episode) async {
    if (!_isDesktop) return;
    try {
      if (_mini ||
          await windowManager.isFullScreen() ||
          await windowManager.isMaximized()) {
        return;
      }
      final double aspect;
      if (stream.width > 0 && stream.height > 0) {
        aspect = stream.width / stream.height;
      } else {
        aspect = episode.vertical ? 9 / 16 : 16 / 9;
      }
      final bounds = await windowManager.getBounds();
      var height = bounds.height;
      if (height < 500) height = 760;
      var width = height * aspect;
      width = width.clamp(380.0, 1600.0);
      await windowManager.setBounds(Rect.fromLTWH(
        bounds.center.dx - width / 2,
        bounds.top,
        width,
        height,
      ));
    } catch (_) {}
  }

  /// 自建全屏：window_manager 0.5.2 的 Windows setFullScreen 只剥
  /// THICKFRAME/MAXIMIZEBOX 而保留 WS_CAPTION（标题栏还在）且盖不住任务栏——
  /// 用户实测「全屏后仍有状态栏」。这里按 [kFullscreenEnterSteps] /
  /// [fullscreenExitSteps] 的有序步骤执行（隐标题栏 + 铺满显示器 + 原生标记
  /// 同步；退出按序还原）。**所有**进入/退出路径（按钮、F、Esc、退出页面）
  /// 必须走这里，不允许直接调 windowManager.setFullScreen——历史上 Esc 路径
  /// 绕过标题栏恢复，出现「ESC 退出后标题栏消失」。
  Rect? _preFullscreenBounds;

  /// 当前是否全屏（只用于右侧选集热区的显隐；真实状态仍以 windowManager 为准）。
  bool _fullscreen = false;

  /// 跨季 pushReplacement 时旧页不要还原全屏：新页会继承同一个窗口状态。
  bool _skipFullscreenRestoreOnDispose = false;

  /// PC 全屏右侧选集抽屉。
  bool _edgePanelOpen = false;

  /// 手动关闭后置位：指针先离开热区才允许再次自动弹出（否则在边缘抖动）。
  bool _edgePanelSuppressed = false;
  bool _edgeHovered = false;
  bool _edgePanelHovered = false;

  /// 季下拉菜单是否打开（期间豁免抽屉的「鼠标离开即收起」）。
  bool _edgeSeasonMenuOpen = false;

  /// 每次打开递增，作为抽屉的 key：让 [EpisodeGrid] 重新初始化并居中当前集。
  int _edgePanelToken = 0;
  Timer? _edgeCloseTimer;

  Future<void> _applyFullscreen(bool on) async {
    if (on) {
      for (final step in kFullscreenEnterSteps) {
        switch (step) {
          case FullscreenStep.saveBounds:
            _preFullscreenBounds = await windowManager.getBounds();
          case FullscreenStep.clearMinimumSize:
            await windowManager.setMinimumSize(const Size(0, 0));
          case FullscreenStep.hideTitleBar:
            await windowManager.setTitleBarStyle(TitleBarStyle.hidden);
          case FullscreenStep.coverDisplay:
            try {
              // screen_retriever 的坐标是逻辑像素，与 windowManager.setBounds
              // 同一体系；visiblePosition 是该屏工作区原点（多显示器下的偏移）。
              final display = await sr.screenRetriever.getPrimaryDisplay();
              final origin = display.visiblePosition ?? Offset.zero;
              await windowManager.setBounds(Rect.fromLTWH(
                origin.dx,
                origin.dy,
                display.size.width,
                display.size.height,
              ));
            } catch (e, stack) {
              ErrorLog.instance.record('全屏', '取显示器尺寸失败：$e', stack);
            }
          case FullscreenStep.nativeFullscreenOn:
            await windowManager.setFullScreen(true);
          default:
            break;
        }
      }
      _setFullscreenUi(true);
      return;
    }
    for (final step in fullscreenExitSteps(
        restorableBounds: _preFullscreenBounds != null)) {
      switch (step) {
        case FullscreenStep.nativeFullscreenOff:
          await windowManager.setFullScreen(false);
        case FullscreenStep.showTitleBar:
          await windowManager.setTitleBarStyle(TitleBarStyle.normal);
        case FullscreenStep.restoreMinimumSize:
          await windowManager.setMinimumSize(const Size(380, 480));
        case FullscreenStep.restoreBounds:
          final restore = _preFullscreenBounds;
          if (restore != null) await windowManager.setBounds(restore);
        default:
          break;
      }
    }
    // 已退出：清掉还原点，避免下一次退出还原到过期的 bounds。
    _preFullscreenBounds = null;
    _setFullscreenUi(false);
  }

  /// 同步全屏 UI 状态（右侧选集热区只在全屏时存在）。
  void _setFullscreenUi(bool on) {
    if (!mounted || _fullscreen == on) return;
    setState(() {
      _fullscreen = on;
      if (!on) {
        _edgePanelOpen = false;
        _edgePanelSuppressed = false;
      }
    });
  }

  Future<void> _toggleFullscreen() async {
    if (!_isDesktop) return;
    try {
      if (_mini) await _toggleMiniWindow();
      final full = await windowManager.isFullScreen();
      final target = !full;
      await _applyFullscreen(target);
      // setFullScreen 是异步系统调用，执行完立即回读真实状态；
      // 与目标不符（用户报过「全屏后仍有标题栏」）留痕进错误日志。
      await Future<void>.delayed(const Duration(milliseconds: 120));
      final actual = await windowManager.isFullScreen();
      _setFullscreenUi(actual);
      if (actual != target) {
        ErrorLog.instance.record(
          '全屏',
          'setFullScreen($target) 后回读 isFullScreen=$actual，与预期不符',
        );
      }
    } catch (e, stack) {
      ErrorLog.instance.record('全屏', e, stack);
    }
  }

  /// 迷你置顶小窗：缩成小尺寸 + 窗口置顶，边干活边看；再按一次还原。
  /// 竖屏剧竖着缩（宽 380），横屏剧横着缩。
  Future<void> _toggleMiniWindow() async {
    if (!_isDesktop) return;
    try {
      final settings = AppScope.read(context).settings;
      if (_mini) {
        await windowManager.setAlwaysOnTop(false);
        await windowManager.setMinimumSize(const Size(380, 480));
        final restore = _preMiniBounds;
        if (restore != null) {
          await windowManager.setBounds(restore);
        } else {
          await windowManager.center();
        }
        settings.miniWindowActive = false;
        if (mounted) setState(() => _mini = false);
        return;
      }
      final bounds = await windowManager.getBounds();
      _preMiniBounds = bounds;
      final stream = _playback != null
          ? _currentStream(_playback!.playback)
          : null;
      final double aspect;
      if (stream != null && stream.width > 0 && stream.height > 0) {
        aspect = stream.width / stream.height;
      } else {
        aspect = widget.episodes[_index.clamp(0, widget.episodes.length - 1)]
                .vertical
            ? 9 / 16
            : 16 / 9;
      }
      const width = 380.0;
      final height = (width / aspect).clamp(160.0, 780.0);
      await windowManager.setMinimumSize(const Size(240, 160));
      await windowManager.setBounds(
          Rect.fromLTWH(bounds.left, bounds.top, width, height));
      await windowManager.setAlwaysOnTop(true);
      settings.miniWindowActive = true;
      if (mounted) setState(() => _mini = true);
    } catch (_) {}
  }

  /// 桌面端键盘快捷键：空格暂停、←/→ 快进退 10 秒、↑/↓ 上/下一集、
  /// F 全屏、M 静音、D 弹幕开关、PageUp/PageDown 上下集、Esc 退出全屏/返回。
  ///
  /// 电视遥控器只有方向键 + 确定 + 返回：确定键显隐控制栏、左右键快退快进、
  /// 媒体键播放暂停与切集。控制栏可见时方向键让给焦点移动（返回 ignored）。
  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    // 遥控器长按左右键：按下开始连发，松手停止。KeyUp 必须在下面的
    // KeyDown/KeyRepeat 过滤之前处理，否则永远收不到「松手」。
    if (_isTv && event is KeyUpEvent) {
      final k = event.logicalKey;
      if (k == LogicalKeyboardKey.arrowLeft ||
          k == LogicalKeyboardKey.arrowRight ||
          k == LogicalKeyboardKey.mediaRewind ||
          k == LogicalKeyboardKey.mediaFastForward) {
        _stopSeekRepeat();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;

    if (_isTv) {
      if (key == LogicalKeyboardKey.select ||
          key == LogicalKeyboardKey.enter) {
        _toggleControls();
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.mediaRewind ||
          key == LogicalKeyboardKey.mediaFastForward) {
        if (event is KeyRepeatEvent) return KeyEventResult.handled;
        _startSeekRepeat(
            key == LogicalKeyboardKey.mediaRewind ? -1 : 1);
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.arrowLeft ||
          key == LogicalKeyboardKey.arrowRight) {
        // 控制栏可见时左右键在按钮之间移动焦点，不抢。
        if (_showControls) return KeyEventResult.ignored;
        // 系统自己也会送 KeyRepeatEvent；这里只认第一下，后续交给我们的
        // 400ms 定时器，避免按住 1 秒就跳了几十次。
        if (event is KeyRepeatEvent) return KeyEventResult.handled;
        _startSeekRepeat(key == LogicalKeyboardKey.arrowLeft ? -1 : 1);
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.escape) {
        if (_showControls) {
          setState(() => _showControls = false);
          return KeyEventResult.handled;
        }
        // 控制栏已收：交给 Navigator 逐级返回。
        return KeyEventResult.ignored;
      }
    }

    if (key == LogicalKeyboardKey.mediaPlayPause) {
      _togglePlayPause();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.mediaTrackNext) {
      _goNext(manual: true);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.mediaTrackPrevious) {
      _goPrev(manual: true);
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.space) {
      _engine.playOrPause();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowLeft || key == LogicalKeyboardKey.keyJ) {
      unawaited(_seekBy(const Duration(seconds: -10)));
      _showOsd(AppIcons.fastRewind, '快退 10 秒');
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowRight || key == LogicalKeyboardKey.keyL) {
      unawaited(_seekBy(const Duration(seconds: 10)));
      _showOsd(AppIcons.fastForward, '快进 10 秒');
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      // PC：↑ = 上一集（用户口径「上下集」）。按住不连跳——系统 KeyRepeat
      // 会把一次长按变成十几次切集，每次都要重新解析播放地址。
      if (!_isTv) {
        if (event is KeyRepeatEvent) return KeyEventResult.handled;
        _goPrev(manual: true);
        return KeyEventResult.handled;
      }
      // 电视遥控器保持音量语义；控制栏可见时把上下键让给焦点移动。
      if (_showControls) return KeyEventResult.ignored;
      final v = (_engine.state.volume + 5).clamp(0.0, 100.0);
      _engine.setVolume(v);
      _showOsd(AppIcons.volume, '音量 ${v.round()}%');
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowDown) {
      // PC：↓ = 下一集（连发同样忽略）。
      if (!_isTv) {
        if (event is KeyRepeatEvent) return KeyEventResult.handled;
        _goNext(manual: true);
        return KeyEventResult.handled;
      }
      if (_showControls) return KeyEventResult.ignored;
      final v = (_engine.state.volume - 5).clamp(0.0, 100.0);
      _engine.setVolume(v);
      _showOsd(Icons.volume_down_rounded, '音量 ${v.round()}%');
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyF) {
      _toggleFullscreen();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyI) {
      _toggleMiniWindow();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyM) {
      _toggleMute();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyD) {
      // 弹幕开关：与控制栏弹幕按钮同一路径（_toggleDanmaku 内含 OSD 提示
      // 「弹幕已开启/已关闭」与持久化）。
      _toggleDanmaku();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyC) {
      _applySpeed(_speed + 0.25, source: '键盘');
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyX) {
      _applySpeed(_speed - 0.25, source: '键盘');
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyZ) {
      _applySpeed(1.0, source: '键盘');
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyE) {
      _openEpisodePicker();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.f1) {
      _showShortcutHelp();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.pageDown) {
      _goNext(manual: true);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.pageUp) {
      _goPrev(manual: true);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.escape) {
      // 参考实现（view_player.go）的 Esc 优先级：先收选集侧栏，再退全屏。
      if (_edgePanelOpen) {
        _closeEdgePanel();
        return KeyEventResult.handled;
      }
      if (_isDesktop) {
        // 退出全屏必须走 _applyFullscreen：直接 setFullScreen(false) 不恢复
        // 标题栏/最小尺寸/bounds（用户实测「ESC 退出后标题栏消失」）。
        unawaited(windowManager.isFullScreen().then((full) async {
          if (full) await _applyFullscreen(false);
        }));
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
  }

  /// 每集起播前重置判定器并开始 1s 采样。
  void _startBufferMonitor() {
    _bufferTimer?.cancel();
    _loadWatchdog?.cancel();
    _bufferTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_disposed) return;
      final verdict = _bufferMonitor.tick();
      if (verdict == null) return;
      unawaited(_recordPlaybackHealth(PlaybackHealthEvent.slowBuffer));
      ErrorLog.instance.record(
        '播放',
        '慢缓冲命中：${verdict.detail}（${verdict.issue.name}）'
        '${_candidates.isEmpty ? ' → 仅提示' : ' → 尝试换线'}',
      );
      if (_candidates.isNotEmpty) {
        // 有备选线路就直接换，别让用户盯着缓冲圈手动操作；预算耗尽后只提示。
        if (_recoveryBudget.exhausted) {
          if (mounted) _showToast(verdict.message);
          return;
        }
        final label = _candidates.first.label;
        _showOsd(AppIcons.swapHoriz, '画面卡顿，换到「$label」…');
        unawaited(_attemptFallback());
        return;
      }
      if (mounted) _showToast(verdict.message);
    });
  }

  /// 记录「源/影片/集/线路」的健康度；失败静默（不能因为统计挂掉播放）。
  ///
  /// 线路下标用「已尝试地址数 - 1」：第 0 条是原始线路，每次换线 +1。
  /// 不区分线路的话，同一集换三条线的记录会全写在一个键上，换线排序就没数据。
  Future<void> _recordPlaybackHealth(PlaybackHealthEvent event) async {
    try {
      final key = PlaybackHealthRegistry.keyOf(
        sourceKey: '',
        seriesId: widget.series.id,
        episode: _index,
        line: (_triedUrls.length - 1).clamp(0, 99),
      );
      await AppScope.read(context).playbackHealth.record(key, event);
    } catch (_) {}
  }

  /// 应用按剧轨道偏好（stream.tracks 驱动，每集一次）。
  ///
  /// 等待轨道就绪：偏好存在但对应列表还空 → 不置标记，等下一次事件。
  void _applyTrackPreference() {
    if (_trackPrefApplied || _disposed || !mounted) return;
    final tracks = _engine.state.tracks;
    final audio =
        tracks.audio.where((t) => t.id != 'auto' && t.id != 'no').toList();
    final subs =
        tracks.subtitle.where((t) => t.id != 'auto' && t.id != 'no').toList();
    if (_prefAudioIndex == null &&
        _prefSubtitleIndex == null &&
        (_prefAudioKey ?? '').isEmpty &&
        (_prefSubtitleKey ?? '').isEmpty) {
      _trackPrefApplied = true;
      return;
    }
    if (audio.isEmpty && subs.isEmpty) return; // 轨道事件未到
    _trackPrefApplied = true;
    final audioTarget = _resolveTrackTarget(
        _prefAudioIndex, _prefAudioKey, audio, (t) => TrackPreference.stableTrackKey(
            language: t.language, title: t.title));
    final subTarget = _resolveTrackTarget(
        _prefSubtitleIndex, _prefSubtitleKey, subs, (t) => TrackPreference.stableTrackKey(
            language: t.language, title: t.title));
    if (audioTarget != null) {
      unawaited(_engine.setAudioTrack(audio[audioTarget]));
    }
    if (_prefSubtitleIndex == TrackPreference.subtitleOff) {
      unawaited(_engine.setSubtitleTrack(SubtitleTrack.no()));
    } else if (subTarget != null) {
      unawaited(_engine.setSubtitleTrack(subs[subTarget]));
    }
  }

  /// 轨道目标解析（Pathfin 语义）：稳定身份键**唯一命中**优先——命中多条
  /// 宁可保持默认（不错配语言）；键缺失/失配时序号在界内兜底。
  static int? _resolveTrackTarget(
    int? index,
    String? key,
    List<dynamic> tracks,
    String? Function(dynamic track) keyOf,
  ) {
    final keys = [for (final t in tracks) keyOf(t)];
    if (key != null && key.isNotEmpty) {
      final unique = TrackPreference.uniqueMatchIndex(key, keys);
      if (unique != null) return unique;
    }
    if (index != null && index >= 0 && index < tracks.length) return index;
    return null;
  }

  Future<void> _openEpisode(
    int index,
    Duration startAt, {
    bool manual = false,
  }) async {
    _bufferMonitor.reset();
    _bufferMonitor.onOpen();
    _startBufferMonitor();
    final epoch = ++_openEpoch;
    _episodeStartAt = startAt;
    _lastExplicitSeekSec = 0;
    final ep = widget.episodes[index];
    ErrorLog.instance.record(
      '播放',
      '打开第${ep.number}集 startAt=${startAt.inSeconds}s'
      '${manual ? '（用户选集）' : '（自动）'}',
    );
    final scope = AppScope.read(context);
    // 冷启动会话恢复（R1）：起播/换集即刷新「上次停留页」。换集不开新
    // 路由，导航观察者看不见，只能在这里自报（首次起播与观察者的 push
    // 写入同值幂等；覆盖离线播放等不带 arguments 的入口）。
    scope.settings.uiLastRoute = LastRoute.player(
      seriesId: widget.series.id,
      episode: ep.number,
    ).encode();
    // 用户显式选集：立刻把「想去第 N 集」写进历史。原先只有起播成功且播过
    // 5 秒才落盘，点开失败/秒退就退出的话历史还停在旧集（用户的断点意图丢了）。
    // 自动连播不提前记：起播失败不该挪断点，播起来后节流器照常写。
    if (manual) {
      // 用户手动选集算一次新的尝试：自动重试额度重置。
      _autoRetryCount = 0;
      _autoRetryTimer?.cancel();
      _position = startAt;
      await _recordHistory(
        finished: false,
        force: true,
        episodeIndex: index,
      );
      if (_disposed || epoch != _openEpoch) return;
    }
    _playSkip = scope.playSkip.entryFor(widget.series.id);
    _endingHandled = false;
    _watchedSeconds = 0;
    _lastWatchPos = Duration.zero;
    _stopSeekRepeat();
    _openingNoticePending = false;
    _playbackFailure = null;
    _rawPlaybackError = null;
    _reResolved = false;
    _reResolving = false;
    _recoveryBudget.attempts = 0;
    _trackPrefApplied = false;
    _fallbackTimer?.cancel();
    _fallbackTimer = null;
    _fallbackInFlight = false;
    var effectiveStart = startAt;
    if (startAt == Duration.zero &&
        scope.settings.skipIntroOutro &&
        (_playSkip?.openingMs ?? 0) > 0) {
      effectiveStart = Duration(milliseconds: _playSkip!.openingMs);
      _openingNoticePending = true;
    }
    // 换集先停掉上一集，避免旧位置事件在解析期间写进新一集的进度。
    await _engine.stop();
    if (_disposed || epoch != _openEpoch) return;
    _episodeEnded = false;
    setState(() {
      _position = Duration.zero;
      _duration = Duration.zero;
      _danmakuEpoch++;
      _loadingStream = true;
      _loadError = null;
      _playback = null;
      _selectedDefinition = null;
      _definitions = const [];
    });
    await _installMpvOptions();
    // 已缓存的集直接播本地文件（带密钥解密），不发起任何网络请求。
    final local = scope.downloads.localEntryOf(ep.id);
    if (local != null) {
      if (_disposed || epoch != _openEpoch) return;
      setState(() {
        _playback = null;
        _definitions = local.keyHex.isEmpty ? const [] : const ['本地'];
        _selectedDefinition = local.keyHex.isEmpty ? null : '本地';
        _loadingStream = false;
        _index = index;
      });
      await _playLocal(local, effectiveStart);
      if (_disposed || epoch != _openEpoch) return;
      _applyOrientation();
      _updateSmtcMetadata();
      _syncVideoMedia();
      _recordHistory(finished: false);
      _showOpeningNoticeIfNeeded();
      return;
    }
    try {
      final api = scope.api;
      final quality = _quality;
      // 连播预解析命中直接用（过期则重新解析），换集零等待。
      final cached = _prefetched.remove(index);
      PlaybackResult? resolved =
          cached != null && prefetchUsable(cached, DateTime.now()) ? cached : null;
      // 红果官方 App 取流接口自 2026-10-15 起对第三方客户端封死（返回空 body），
      // 先走官网 protected/play-info 通道；失败或空流时回落旧接口，
      // 以兼容非红果剧集和通道临时不可用。
      if (resolved == null) {
        // 11-19：游客墙（403 protected_playback_unavailable）不再直接抛错。
        //
        // 原实现假设「游客墙换设备/回落旧接口都无效」，遇到
        // `webLoginRequired` 立刻 rethrow。但用户日志实证相反：
        // 第 8 集 webplay 报 403 后，回落 appchain 通道能正常取到流
        // （19:32:35 失败 → 19:32:53 再点即走 appchain 开播成功，
        // 表现为「第一次点集失败、再点一次才好」）。
        // 改为：记住该错误先回落，只有回落也失败才把准确的游客墙错误
        // 抛给错误面板，避免无谓的失败首击。
        AquaException? webLoginError;
        try {
          final web = await api.resolvePlaybackWeb(
            widget.series.id,
            ep.id,
            definition: _quality == '480p' ? '480p' : '720p',
          );
          if (web.playback.streams.isNotEmpty) resolved = web;
        } catch (e) {
          if (e is AquaException && e.code == AquaCode.webLoginRequired) {
            webLoginError = e;
          }
          ErrorLog.instance.record('播放', 'webplay 取流失败，回落旧接口: $e');
        }
        if (resolved == null) {
          try {
            resolved = await api.resolvePlayback(ep.id);
          } catch (e) {
            // 回落也失败：游客墙错误更能解释原因（比笼统的网络失败准）。
            if (webLoginError != null) throw webLoginError;
            rethrow;
          }
        }
      }
      final pb = resolved;
      if (_disposed || epoch != _openEpoch) return;
      if (pb.playback.streams.isEmpty) {
        throw AquaException(
            code: AquaCode.contentUnavailable,
            message: '没有可用播放流',
            retryable: false);
      }
      final stream = _selectStream(pb.playback, quality);
      setState(() {
        _playback = pb;
        _definitions = _definitionLabels(pb.playback);
        _selectedDefinition = _definitionLabel(stream);
        _loadingStream = false;
        _index = index;
      });
      await _playStream(stream, effectiveStart);
      if (_disposed || epoch != _openEpoch) return;
      // 起播成功：清掉取流空响应的自动重试额度。
      _autoRetryCount = 0;
      _autoRetryTimer?.cancel();
      _applyOrientation();
      await _maybeFitWindow(stream, ep);
      _updateSmtcMetadata();
      _syncVideoMedia();
      _recordHistory(finished: false);
      _showOpeningNoticeIfNeeded();
    } catch (e, stack) {
      if (_disposed || epoch != _openEpoch) return;
      // 「打开」必须与结果行成对：解析失败此前只落 UI 面板，日志里只剩一句
      // 「打开第N集」，事后无法区分「卡在取流」还是「开播失败」。
      // `_playback` 非空说明解析已完成（失败在 _playStream 内），据此标注阶段。
      ErrorLog.instance.record(
        '播放',
        '打开失败 第${ep.number}集'
        ' · 阶段=${_playback == null ? '解析' : '开播'}'
        ' · error=${_clipForLog('$e')}',
        stack,
      );
      setState(() {
        _loadError = e;
        _loadingStream = false;
      });
      _schedulePlaybackAutoRetry();
    }
  }

  /// 取流空响应的自动重试（最多 2 次，间隔 1.2s）。
  ///
  /// `PLAYBACK_UNAVAILABLE` 多是服务端对匿名取流的**间歇性**空响应（SDK 的
  /// 哨兵注释也这么写），隔一两秒重取往往就恢复了；让用户自己反复点「重试」
  /// 体验很差，而「重置设备」对这类错误无效（实测连点两次仍失败）。
  void _schedulePlaybackAutoRetry() {
    _autoRetryTimer?.cancel();
    final Object? e = _loadError;
    if (e is! AquaException) return;
    if (e.code != AquaCode.playbackUnavailable) return;
    if (_autoRetryCount >= 2) return;
    _autoRetryTimer = Timer(const Duration(milliseconds: 1200), () {
      if (!mounted || _disposed || _loadError == null) return;
      _autoRetryCount++;
      ErrorLog.instance.record(
        '播放',
        '取流空响应自动重试 $_autoRetryCount/2',
      );
      unawaited(_openEpisode(_index, _retryStartAt, manual: false));
    });
  }

  /// 与 SDK Playback.Select 相同语义的选流：best/worst/具体清晰度标签。
  ///
  /// 先剔除开源内核解不了的编码（bytevc2）：同一档位混编码时优先可播的；
  /// 全部不可播时保留原列表，让开播拦截给出明确文案而不是误报「没有流」。
  VideoStream _selectStream(Playback pb, String quality) {
    final all = pb.streams.where((s) => s.url.isNotEmpty).toList();
    if (all.isEmpty) {
      throw AquaException(
          code: AquaCode.contentUnavailable,
          message: '没有可用播放流',
          retryable: false);
    }
    final decodable =
        all.where((s) => !isUnsupportedStreamCodec(s.codec)).toList();
    final usable = decodable.isNotEmpty ? decodable : all;
    int rank(VideoStream s) {
      if (s.height > 0) return s.height;
      final digits = RegExp(r'^(\d+)').firstMatch(s.definition)?.group(1);
      return digits == null ? 0 : int.parse(digits);
    }

    usable.sort((a, b) {
      final ra = rank(a);
      final rb = rank(b);
      if (ra != rb) return ra.compareTo(rb);
      return a.bitrate.compareTo(b.bitrate);
    });
    switch (quality) {
      case 'worst':
        return usable.first;
      case '':
      case 'best':
        return usable.last;
      default:
        return usable.lastWhere(
          (s) =>
              s.definition == quality ||
              s.quality == quality ||
              s.codec == quality,
          orElse: () => usable.last,
        );
    }
  }

  List<String> _definitionLabels(Playback pb) {
    final set = <String>{};
    for (final s in pb.streams) {
      if (s.url.isEmpty) continue;
      set.add(_definitionLabel(s));
    }
    return set.toList();
  }

  String _definitionLabel(VideoStream s) =>
      s.definition.isNotEmpty ? s.definition : (s.quality.isEmpty ? '默认' : s.quality);

  /// 开播日志的取流留痕：通道 + 轨数。本地播放没有模型，返回空串不带这截。
  String _channelLogSuffix() {
    final channel = (_playback?.channel ?? '').trim();
    if (channel.isEmpty) return '';
    return ' · 通道=$channel · 轨=${_playback!.playback.streams.length}';
  }

  VideoStream _currentStream(Playback pb) {
    final label = _selectedDefinition;
    if (label != null) {
      for (final stream in pb.streams) {
        if (stream.url.isNotEmpty && _definitionLabel(stream) == label) {
          return stream;
        }
      }
    }
    return pb.streams.firstWhere((s) => s.url.isNotEmpty,
        orElse: () => pb.streams.first);
  }

  Future<void> _playStream(VideoStream stream, Duration startAt) async {
    final epoch = _openEpoch;
    _currentVideoStream = stream;
    // 必败场景快速失败：不开播、不进换线，直接给明确错误。
    final blocker = _openBlocker(stream);
    if (blocker != null) {
      _rawPlaybackError = blocker.raw;
      _logBuffer.add('[error] ${blocker.raw}');
      ErrorLog.instance.record('播放', '开播拦截 · ${blocker.raw}');
      unawaited(_recordPlaybackHealth(PlaybackHealthEvent.failed));
      if (mounted && !_disposed) {
        setState(() => _playbackFailure = blocker);
        // 密钥可能随后端更新，给重解析留一次机会；编码不支持是内容固有
        // 属性，重解析不变编码，直接定板。_reResolved 防循环。
        if (!_reResolved && _playback?.contentKey == null) {
          unawaited(_finalizeFailure());
        }
      }
      return;
    }
    _playbackFailure = null;
    _rawPlaybackError = null;
    _fallbackTimer?.cancel();
    _fallbackTimer = null;
    _fallbackInFlight = false;
    _stormGuard.reset();
    _attemptStart = startAt;
    _playEpoch++;
    _durationLogged = false;
    _triedUrls
      ..clear()
      ..add(stream.url.trim());
    final pb = _playback;
    _candidates = pb == null
        ? const []
        : planPlaybackCandidates(
            // 备用候选同样先剔除解不了的编码：混编码剧集里失败换线时，
            // 别把注定报错的 bytevc2 流塞进 6 轮预算里。
            streams: pb.playback.streams
                .where((s) => !isUnsupportedStreamCodec(s.codec))
                .toList(),
            current: stream,
            tried: _triedUrls,
          );
    _logBuffer.clear();
    ErrorLog.instance.record(
      '播放',
      '开播 ${widget.series.title} 第${widget.episodes[_index.clamp(0, widget.episodes.length - 1)].number}集'
          ' · ${_definitionLabel(stream)} · startAt=${startAt.inSeconds}s'
          ' · 候选=${_candidates.length}${_channelLogSuffix()}'
          // 实际写入引擎的速率：换集后核对「倍速是否继承」的直接证据。
          ' · rate=${_trimSpeed(_effectiveRate)}x',
    );
    await _prepareLavf();
    // DASH 双轨（官网 play-info 通道）：视频与音轨是两个独立加密流，
    // 外挂音轨必须在 open 前设置（与 source_player_screen 的做法一致）。
    // audio-files 是 mpv 的路径列表（OPT_PATHLIST）：parse_str_list 按平台
    // 分隔符（POSIX ':' / Windows ';'）切条目，且不支持 %n% 长度前缀——URL
    // 必须经 mpvListEntry 转义才是一个完整条目（Android 现场把 'https://...'
    // 切成 'https' + '//host/...' 两个坏条目，带外挂音轨的候选全部开播失败，
    // 11-20 取证）。audioUrl 为空（v5 系通道 audio=false）时**必须清残留**：
    // setProperty 传空串会被 parse_str_list 的 while(1) 循环先放入一条空
    // 条目（实测「Cannot open file ''」假失败弹窗，11-17 老剧事故），唯一
    // 干净的清法是 change-list clr（OP_CLR 在解析前直接释放整个列表）。
    // 同剧内 webplay(带音轨) 与 v5(无音轨) 混合，不清残留会让 mpv 拿本集
    // 密钥去解上一集的加密音频 → AAC 解码风暴 → 进程闪退（11-20 PC 根因）。
    final audioUrl = _playback?.playback.audioUrl ?? '';
    if (audioUrl.isNotEmpty) {
      await _engine.setProperty('audio-files', mpvListEntry(audioUrl));
    } else {
      await _engine.command(mpvClearPathListCommand('audio-files'));
    }
    // 换集/换线沿用当前生效速率：锁定 2 倍速时不能悄悄回到用户档位。
    await _engine.setRate(_effectiveRate);
    await _engine.open(Media(stream.url), play: true);
    // open 后补一次，防个别内核 load 时重置 speed（幂等，不影响续播顺序）。
    await _engine.setRate(_effectiveRate);
    await _seekResume(startAt);
    if (!mounted || _disposed || epoch != _openEpoch) return;
    setState(() => _prepared = true);
    unawaited(_maybeShowPlayerGuide());
    // 加载超时兜底：75s 内既无时长也无播放进度 → 停流 + 错误面板（可重试），
    // 不让 broken stream 无限挂着。
    _loadWatchdog?.cancel();
    _loadWatchdog = Timer(const Duration(seconds: 75), () {
      if (_disposed || !mounted || epoch != _openEpoch || _episodeEnded) return;
      final bool loaded = _engine.state.duration > Duration.zero ||
          _engine.state.position > startAt + const Duration(seconds: 2);
      if (loaded) return;
      ErrorLog.instance.record(
        '播放',
        '加载超时：75s 内无时长且无进度（startAt=${startAt.inSeconds}s）→ 停流提示重试',
        StackTrace.current,
      );
      unawaited(_engine.pause());
      if (mounted) {
        setState(() =>
            _playbackFailure = classifyPlaybackFailure('加载超时：视频源长时间无响应'));
      }
    });
    _historyThrottle.reset(
      baseline: startAt,
      floor: startAt > const Duration(seconds: 1)
          ? startAt - const Duration(seconds: 1)
          : null,
    );
    _prefetchNext(_index);
    _refreshDanmaku(startAt.inMilliseconds);
    _maybeShowMutedHint();
  }

  /// 写入 mpv 的 demuxer-lavf-o（解密、协议白名单、分片重试）。
  Future<void> _prepareLavf() async {
    final key = _playback?.contentKey?.key ?? '';
    final lavf = [
      'seg_max_retry=3',
      'strict=experimental',
      'allowed_extensions=ALL',
      // 白名单值含逗号：必须 %n% 引用（keyvalue 列表的 read_subparam 语义），
      // 内联方括号写法在部分版本会把整条 demuxer-lavf-o 解析失败。
      lavfProtocolWhitelist(protocols: kMpvLavfNetworkProtocols),
      if (key.isNotEmpty) 'decryption_key=$key',
    ].join(',');
    await _engine.setProperty('demuxer-lavf-o', lavf);
  }

  /// 换线 / 重试时打开一个新地址（沿用当前播放模型与解密密钥）。
  Future<void> _openUrl(String url, Duration startAt) async {
    _resetEndedStateForRetry();
    _stormGuard.reset();
    final host = Uri.tryParse(url)?.host ?? '';
    ErrorLog.instance
        .record('播放', '换线打开 startAt=${startAt.inSeconds}s · host=$host');
    await _prepareLavf();
    // 换线沿用同一播放模型的音轨（DASH 双轨时不能丢）；audioUrl 为空时清
    // 残留——理由同 _playStream（空串=空路径条目、残留=错密钥解码风暴，
    // 编码与清空机制见 mpv_list_encoding.dart）。
    final audioUrl = _playback?.playback.audioUrl ?? '';
    if (audioUrl.isNotEmpty) {
      await _engine.setProperty('audio-files', mpvListEntry(audioUrl));
    } else {
      await _engine.command(mpvClearPathListCommand('audio-files'));
    }
    // 换集/换线沿用当前生效速率：锁定 2 倍速时不能悄悄回到用户档位。
    await _engine.setRate(_effectiveRate);
    await _engine.open(Media(url), play: true);
    // open 后补一次，防个别内核 load 时重置 speed（幂等，不影响续播顺序）。
    await _engine.setRate(_effectiveRate);
    await _seekResume(startAt);
    if (!mounted || _disposed) return;
    setState(() => _prepared = true);
    unawaited(_maybeShowPlayerGuide());
    // 与 _playStream 同一套续播保护：换线后位置回退不得覆盖断点
    // （旧实现漏了这里，新线路从 0 起播时 5 秒后就把断点写成 5s）。
    _historyThrottle.reset(
      baseline: startAt,
      floor: startAt > const Duration(seconds: 1)
          ? startAt - const Duration(seconds: 1)
          : null,
    );
  }

  /// 当前集开播后预解析下一集；静默失败（离线/限流都不影响当前播放）。
  /// 路由与主路径一致：官网/v5 通道优先，空流/失败回落旧接口。
  void _prefetchNext(int index) {
    final next = index + 1;
    if (next >= widget.episodes.length) return;
    if (_prefetched.containsKey(next)) return;
    final ep = widget.episodes[next];
    if (!ep.playable) return;
    final api = AppScope.read(context).api;
    void fallback() {
      if (_disposed) return;
      api.resolvePlayback(ep.id).then((pb2) {
        if (_disposed) return;
        _prefetched[next] = pb2;
      }, onError: (_) {});
    }

    api.resolvePlaybackWeb(widget.series.id, ep.id, definition: '720p').then(
      (pb) {
        if (_disposed) return;
        if (pb.playback.streams.isNotEmpty) {
          _prefetched[next] = pb;
          return;
        }
        fallback();
      },
      // webplay 抛错（含 403 游客墙）同样回落。
      onError: (_) => fallback(),
    );
  }

  /// 11-19：进页即预解析**首集**，让取流与页面转场并行。
  ///
  /// 原先首集要等 `_openEpisode` 才发起取流，而 `_openEpisode` 在页面
  /// 构建完成后才跑 —— 用户看到的是「转场结束 → 黑屏 1~2 秒 → 出画面」。
  /// 这里在 `initState` 就把首集流解析挂上，等 `_openEpisode` 走到取流时
  /// 结果通常已在手（`_prefetched` 命中 → 零等待）。
  ///
  /// 失败静默：预热只是加速，取流失败仍走主路径的正常报错。
  ///
  /// 11-19：webplay 抛错（含游客墙 403）时也要回落旧接口 —— 否则这一集
  /// 永远预热不中，首播又退回到主路径的串行取流。
  void _prefetchFirst() {
    if (_prefetched.containsKey(_index)) return;
    final ep = widget.episodes[_index];
    if (!ep.playable) return;
    final api = AppScope.read(context).api;
    void fallback() {
      if (_disposed) return;
      api.resolvePlayback(ep.id).then((pb2) {
        if (_disposed) return;
        _prefetched[_index] = pb2;
      }, onError: (_) {});
    }

    api.resolvePlaybackWeb(widget.series.id, ep.id, definition: '720p').then(
      (pb) {
        if (_disposed) return;
        if (pb.playback.streams.isNotEmpty) {
          _prefetched[_index] = pb;
          return;
        }
        fallback();
      },
      // webplay 抛错（含 403 游客墙）同样回落，别让这一集白白错过预热。
      onError: (_) => fallback(),
    );
  }

  // ---------- 弹幕 ----------

  bool get _danmakuOn => AppScope.read(context).settings.danmakuEnabled;

  /// 拉取/续拉当前集弹幕（fire-and-forget）：仓库决定翻页还是回缓存；
  /// 结果转成 overlay 的条目形状。任何失败静默，只进 ErrorLog。
  void _refreshDanmaku(int positionMs) {
    if (!_danmakuOn || _disposed) return;
    final ep =
        widget.episodes[_index.clamp(0, widget.episodes.length - 1)];
    final repo = _danmakuRepo ??= DanmakuRepository(AppScope.read(context).api);
    // 换集先丢弃上一集的仓库缓存：_episodes 按集 ID 无界累积，不 drop 的话
    // 长 binge（一次会话看几百集）会按集线性涨内存（11-20 soak 取证）。
    if (_danmakuEpisodeId != null && _danmakuEpisodeId != ep.id) {
      repo.drop(_danmakuEpisodeId!);
    }
    _danmakuEpisodeId = ep.id;
    final epoch = _openEpoch;
    unawaited(repo
        .load(widget.series.id, ep.id, positionMs)
        .then((items) {
      if (!mounted || _disposed || epoch != _openEpoch) return;
      setState(() {
        _danmaku = [
          for (final d in items)
            bili.DanmakuItem(progressMs: d.offsetMs, text: d.text),
        ];
      });
    }).catchError((Object e, StackTrace st) {
      ErrorLog.instance.record('弹幕', '加载失败（episode=${ep.id}）：$e', st);
    }));
  }

  /// 弹幕开关：写全局设置（持久化 + 设置页可同步看到），开启即拉取。
  void _toggleDanmaku() {
    final settings = AppScope.read(context).settings;
    settings.danmakuEnabled = !settings.danmakuEnabled;
    if (mounted) setState(() {});
    if (settings.danmakuEnabled) {
      _refreshDanmaku(_position.inMilliseconds);
      _showOsd(AppIcons.danmaku, '弹幕已开启');
    } else {
      _showOsd(AppIcons.danmaku, '弹幕已关闭');
    }
  }

  /// 用户主动 seek（拖动/键盘/快退/投屏回本地/AI 命令）的唯一入口。
  ///
  /// 显式通知缓冲监控（不再靠位置事件反推），清掉续播保护，并允许一次
  /// 历史回退写盘；同时立即刷新 UI，避免进度条被滞后的位置事件拉回去。
  Future<void> _seekTo(Duration position) async {
    var target = position;
    if (target < Duration.zero) target = Duration.zero;
    if (_duration > Duration.zero && target > _duration) target = _duration;
    _resumeTarget = null;
    _resumeArmedAt = null;
    _resumeRetried = false;
    _allowHistoryRewind = true;
    // 显式 seek 目标留作 EOF 真值下限（拖到近片尾后播完不再被误判异常 EOF）。
    _lastExplicitSeekSec = target.inMilliseconds / 1000;
    _bufferMonitor.onSeek();
    if (mounted && !_disposed) {
      setState(() {
        _position = target;
        // 用户主动 seek：允许弹幕时间轴回到目标位置。
        _danmakuEpoch++;
      });
    }
    await _engine.seek(target);
    // seek 可能跳出已覆盖的弹幕区间：仓库自己判断要不要续拉。
    _refreshDanmaku(target.inMilliseconds);
  }

  Future<void> _seekBy(Duration delta) => _seekTo(_position + delta);

  /// 起播 / 换线 / 切清晰度的续播 seek：武装保护后再 seek。
  Future<void> _seekResume(Duration startAt) async {
    final epoch = _openEpoch;
    _armResume(startAt);
    _bufferMonitor.onSeek();
    if (startAt <= Duration.zero) return;
    // mpv 的 open 返回时文件可能还没 loaded，此时 seek 会被丢弃（实测每次续播
    // 都要靠 _onPosition 的补救再 seek 一次，起播先停在 0s）。duration/playing
    // 都可能早于解码器真正跑起来，等首个正播放位置再 seek；最多等 2s，超时按
    // 原行为直接 seek。
    await waitForPlaybackReady(
      position: _engine.stream.position,
      timeout: const Duration(seconds: 2),
    );
    // 等待期间用户可能切集/换线：旧等待者不能再 seek 旧位置。
    if (!mounted || _disposed || epoch != _openEpoch) return;
    await _engine.seek(startAt);
  }

  void _armResume(Duration startAt) {
    if (startAt <= Duration.zero) {
      _resumeTarget = null;
      _resumeArmedAt = null;
      _resumeRetried = false;
      return;
    }
    _resumeTarget = startAt;
    _resumeArmedAt = DateTime.now();
    _resumeRetried = false;
  }

  /// 播放位置事件：UI、SMTC、换线取消、历史节流、片尾跳过统一入口。
  void _onPosition(Duration position) {
    if (!mounted) return;
    // 真在播放（≥3s）→ 加载超时兜底解除。
    if (position > const Duration(seconds: 3)) _loadWatchdog?.cancel();

    // 累计真实前进量：正增量且 <5s（正常播放步进）才计入——
    // seek 跳变（±大增量）与 broken stream 的位置谎报都不算「看过」。
    final double deltaSec =
        (position - _lastWatchPos).inMilliseconds / 1000;
    if (deltaSec > 0 && deltaSec < 5) _watchedSeconds += deltaSec;
    _lastWatchPos = position;

    // 续播保护：新线路还没 seek 到位时，不采信位置事件。
    final resume = _resumeTarget;
    if (resume != null) {
      if (position >= resume - const Duration(seconds: 1)) {
        _resumeTarget = null;
        _resumeArmedAt = null;
        _resumeRetried = false;
      } else if (position < resume - const Duration(seconds: 5)) {
        if (!_resumeRetried && _prepared) {
          _resumeRetried = true;
          ErrorLog.instance.record(
            '播放',
            '续播未到位：期望 ${resume.inSeconds}s，实际 ${position.inSeconds}s → 补救 seek',
          );
          unawaited(_engine.seek(resume));
        } else if (_resumeArmedAt != null &&
            DateTime.now().difference(_resumeArmedAt!) >=
                const Duration(seconds: 8)) {
          ErrorLog.instance.record(
            '播放',
            '续播放弃保护：期望 ${resume.inSeconds}s，实际 ${position.inSeconds}s',
          );
          _resumeTarget = null;
          _resumeArmedAt = null;
        }
        return;
      }
    }

    final previous = _position;
    // 两次采样之间的大跳变只可能来自 seek（3 倍速下每次采样也只前进约 3 秒）。
    // 正常播放不会回退：回退超过阈值只可能是换线重载/新线路从 0 起播，
    // 记一条面包屑便于事后区分「卡」与「跳开头」。
    final delta = position - previous;
    if (delta > _seekJumpThreshold) {
      _bufferMonitor.onSeek();
    } else if (delta < -_seekJumpThreshold) {
      _bufferMonitor.onSeek();
      final lastLog = _lastRewindLogAt;
      if (lastLog == null ||
          DateTime.now().difference(lastLog) >= const Duration(seconds: 5)) {
        _lastRewindLogAt = DateTime.now();
        ErrorLog.instance.record(
          '播放',
          '位置回退 ${previous.inSeconds}s → ${position.inSeconds}s',
        );
      }
    }
    setState(() => _position = position);
    _syncSmtcTimeline();
    _syncVideoMediaPosition();
    // 错误后位置确实前进（≥1 秒）：说明还能播，取消本次换线。
    if (_fallbackTimer != null &&
        position >= _attemptStart + const Duration(seconds: 1)) {
      _fallbackTimer?.cancel();
      _fallbackTimer = null;
    }
    if (_historyThrottle.shouldWrite(position)) {
      _flushHistory();
    }
    _maybeSkipEnding(previous, position);
  }

  /// 原始错误文本截断进持久日志：media_kit 转发的 mpv 文本可能一行几百字
  /// （带完整 URL），截到 200 字防刷屏；换行压平成一行。
  String _clipForLog(String text, [int max = 200]) {
    final oneLine = text.replaceAll('\n', ' ⏎ ').trim();
    return oneLine.length <= max ? oneLine : '${oneLine.substring(0, max)}…';
  }

  /// 开播前拦截两类已知必败场景，直接给明确错误（不开播、不进换线）：
  ///
  /// 1. 加密剧集但解密密钥缺失：bridge 的 contentKeyError 透传后仍没有 key；
  /// 2. 流编码是开源内核解不了的字节自研编码（bytevc2）。
  ///
  /// 两类都是「同一集所有候选共用同一属性，换线必败」，裸开只会让 mpv 在
  /// ~2 秒后报 unknown 再走 6 轮白等。raw 带诊断字段供面板复制。
  /// 未命中拦截的剧集返回 null，行为不变。
  PlaybackFailure? _openBlocker(VideoStream stream) {
    final pb = _playback;
    if (pb != null &&
        pb.playback.protected &&
        (pb.contentKey == null || pb.contentKey!.key.isEmpty)) {
      final err = pb.contentKeyError;
      final detail = err == null || err.isEmpty
          ? '未随流返回解密密钥'
          : [
              if (err.code.isNotEmpty) err.code,
              if (err.message.isNotEmpty) err.message,
            ].join('：');
      final methods = pb.playback.streams
          .map((s) => s.encryption)
          .where((m) => m.isNotEmpty)
          .toSet()
          .join('/');
      return PlaybackFailure(
        message: '该集是加密剧集，本机未能解出解密密钥（$detail）。'
            '换线路无法解决，可稍后重试或反馈日志',
        kind: PlaybackFailureKind.permanent,
        raw:
            'contentKeyError=$detail · encryption=${methods.isEmpty ? '未知' : methods}',
      );
    }
    if (isUnsupportedStreamCodec(stream.codec)) {
      final codecs = pb?.playback.streams
              .map((s) => s.codec)
              .where((c) => c.isNotEmpty)
              .toSet()
              .join('/') ??
          stream.codec;
      return PlaybackFailure(
        message: '该集使用了字节自研编码（${stream.codec}），当前播放内核暂不支持解码，'
            '换清晰度或线路都无法解决，可换其他片源或反馈日志',
        kind: PlaybackFailureKind.permanent,
        raw: 'codec=${stream.codec} · streams=$codecs · 开源内核无解码器',
      );
    }
    return null;
  }

  /// 播放器报错：按错误类型分级 + 多候选自动换线。
  ///
  /// - 永久性错误（域名解析失败 / HTTP 4xx-5xx / 格式不支持）立即换线；
  /// - 瞬时错误保留 2 秒防抖，期间位置前进就取消；
  /// - 已播放超过 15 秒的晚期错误不自动换线，避免打断正常观看；
  /// - 候选耗尽后进错误面板（含诊断复制）。
  Future<void> _onPlaybackError(String error) async {
    if (_disposed) return;
    _bufferMonitor.onError();
    // 错误风暴（错密钥解 CENC 音频时每秒数百条同文本错误）：保留
    // _bufferMonitor.onError() 之外的逐条记录与决策都会把日志缓冲和换线
    // 预算瞬间刷爆——聚合一条后直接走收尾（重解析一次 → 错误面板），
    // _finalizeFailure 内部有 _reResolving/_reResolved 防重入。
    if (_stormGuard.shouldSuppress(error, DateTime.now())) {
      // 只在窗口计数首次越过阈值的那一条上记聚合日志（含次数），同一场
      // 风暴的后续命中静默。
      if (_stormGuard.lastStormHits <= PlaybackStormGuard.threshold) {
        ErrorLog.instance.record(
          '播放',
          '播放错误风暴：同一错误 1s 内 ${_stormGuard.lastStormHits} 次 → '
          '停止逐次换线，聚合收尾',
        );
      }
      // 面板已定板就静默：收尾在 _reResolved 后的每次调用都会重算
      // classify(_rawPlaybackError)（风暴路径不更新它）并 setState 同一个
      // 值——风暴余波每秒数百条命中时纯属冗余重建。
      if (_playbackFailure != null) return;
      unawaited(_finalizeFailure());
      return;
    }
    unawaited(_recordPlaybackHealth(PlaybackHealthEvent.failed));
    _rawPlaybackError = error;
    _logBuffer.add('[error] $error');
    final failure = classifyPlaybackFailure(error);
    final action = decideRecovery(
      kind: failure.kind,
      playedAheadOfAttempt: _position >= _attemptStart + _earlyWindow,
      hasCandidates: _candidates.isNotEmpty,
      budgetExhausted: _recoveryBudget.exhausted,
    );
    ErrorLog.instance.record(
      '播放',
      '播放错误 ${failure.kind.name} → ${action.name}'
      '${error.trim().isEmpty ? '' : ' · raw=${_clipForLog(error)}'}',
    );
    if (action == RecoveryAction.none) {
      // 晚期错误：不自动换线；先给 OSD 提示，若播放确实停了再给错误面板。
      _showOsd(AppIcons.errorOutline, '播放出错，可在菜单重试');
      unawaited(Future<void>.delayed(const Duration(seconds: 2), () {
        if (_disposed || !mounted) return;
        if (!_engine.state.playing &&
            _rawPlaybackError == error &&
            _playbackFailure == null) {
          setState(() => _playbackFailure = failure);
        }
      }));
      return;
    }
    if (action == RecoveryAction.finalize) {
      unawaited(_finalizeFailure());
      return;
    }
    if (action == RecoveryAction.immediateFallback) {
      unawaited(_attemptFallback());
      return;
    }
    _fallbackTimer ??= Timer(const Duration(seconds: 2), () {
      if (!_disposed) _attemptFallback();
    });
  }

  /// 依次尝试候选线路。每次只打开下一条；若它继续报错，错误事件会再驱动
  /// 下一轮尝试（[_triedUrls] 保证不回头）。
  Future<void> _attemptFallback() async {
    if (_disposed || _fallbackInFlight) return;
    _fallbackTimer?.cancel();
    _fallbackTimer = null;
    final candidates = List<PlaybackCandidate>.from(_candidates);
    if (candidates.isEmpty) {
      await _finalizeFailure();
      return;
    }
    _fallbackInFlight = true;
    final epoch = _playEpoch;
    try {
      while (candidates.isNotEmpty) {
        if (_disposed || epoch != _playEpoch) return;
        if (_recoveryBudget.exhausted) break;
        final candidate = candidates.removeAt(0);
        if (_triedUrls.contains(candidate.url)) continue;
        _candidates = List<PlaybackCandidate>.unmodifiable(candidates);
        _triedUrls.add(candidate.url);
        _recoveryBudget.recordAttempt();
        _playbackFailure = null;
        ErrorLog.instance.record(
          '播放',
          '自动换线 → ${candidate.label}（第 ${_recoveryBudget.attempts}/'
          '${_recoveryBudget.maxAttempts} 次）',
        );
        setState(() => _selectedDefinition = streamLabel(candidate.stream));
        _showOsd(AppIcons.swapHoriz, '线路不可用，尝试「${candidate.label}」…');
        try {
          await _openUrl(candidate.url, _fallbackResumePos());
          // 换线成功：给新线路记一次成功，把它的健康分拉回来。
          unawaited(_recordPlaybackHealth(PlaybackHealthEvent.success));
          return;
        } catch (e) {
          _rawPlaybackError = '$e';
          _logBuffer.add('[error] $e');
          // 打开直接抛错：继续尝试下一条候选。
        }
      }
      // 预算耗尽但候选未用完：转入过期重解析收尾，不再继续硬切。
      if (_recoveryBudget.exhausted && _candidates.isNotEmpty && mounted) {
        unawaited(_finalizeFailure());
        return;
      }
      if (mounted) {
        setState(() =>
            _playbackFailure = classifyPlaybackFailure(_rawPlaybackError));
      }
    } finally {
      _fallbackInFlight = false;
    }
  }

  /// 候选耗尽：先尝试重新解析一次播放地址（签名 URL 过期 / 换 CDN 场景），
  /// 仍失败才显示错误面板。
  Future<void> _finalizeFailure() async {
    if (_disposed || !mounted || _reResolving) return;
    final epoch = _openEpoch;
    final failure = classifyPlaybackFailure(_rawPlaybackError);
    if (_reResolved) {
      setState(() => _playbackFailure = failure);
      return;
    }
    _reResolving = true;
    try {
      final ok = await _tryReResolve();
      if (!ok &&
          // 快速失败路径已给出更具体的错误面板（如密钥缺失），别用
          // 重解析异常的泛化分类覆盖它。
          _playbackFailure == null &&
          mounted &&
          !_disposed &&
          epoch == _openEpoch) {
        setState(() => _playbackFailure = failure);
      }
    } finally {
      _reResolving = false;
    }
  }

  Future<bool> _tryReResolve() async {
    if (_reResolved || _disposed || _playback == null) return false;
    final epoch = _openEpoch;
    _reResolved = true;
    final ep = widget.episodes[_index.clamp(0, widget.episodes.length - 1)];
    final quality = _selectedDefinition ?? _quality;
    try {
      _showOsd(AppIcons.refresh, '播放地址可能已过期，正在重新解析…');
      final api = AppScope.read(context).api;
      PlaybackResult pb;
      try {
        pb = await api.resolvePlaybackWeb(
          widget.series.id,
          ep.id,
          definition: _quality == '480p' ? '480p' : '720p',
        );
        if (!pb.playback.streams.isNotEmpty) {
          pb = await api.resolvePlayback(ep.id);
        }
      } on AquaException catch (e) {
        if (e.code == AquaCode.webLoginRequired) rethrow;
        pb = await api.resolvePlayback(ep.id);
      }
      if (_disposed || !mounted || epoch != _openEpoch) return false;
      final stream = _selectStream(pb.playback, quality);
      setState(() {
        _playback = pb;
        _definitions = _definitionLabels(pb.playback);
        _selectedDefinition = _definitionLabel(stream);
      });
      _resetEndedStateForRetry();
      await _playStream(stream, _fallbackResumePos());
      return true;
    } catch (e) {
      _rawPlaybackError = '$e';
      _logBuffer.add('[error] $e');
      return false;
    }
  }

  /// 首次从片头起播且设置了片头偏移：提示「已跳过片头」并给 5 秒撤销。
  void _showOpeningNoticeIfNeeded() {
    if (!_openingNoticePending) return;
    _openingNoticePending = false;
    final skip = _playSkip;
    if (skip == null || skip.openingMs <= 0) return;
    _showOsdWithUndo(
      AppIcons.next,
      '已跳过片头 ${_fmtSkipMs(skip.openingMs)}',
      () => unawaited(_seekTo(Duration.zero)),
    );
  }

  /// 静音起播提醒：同一部剧只提醒一次，提供一键开声。
  ///
  /// 延迟 600ms 再判断：初始化时 setVolume 是异步的，立即读可能误判为静音。
  void _maybeShowMutedHint() {
    if (_disposed) return;
    final url = _currentVideoStream?.url;
    unawaited(Future<void>.delayed(const Duration(milliseconds: 600), () {
      if (_disposed || !mounted || _engine.state.volume > 0) return;
      final key = MutedPlaybackHintRegistry.keyFor(
        title: widget.series.title,
        url: url,
      );
      if (!_mutedHints.shouldHint(key)) return;
      _mutedHintTimer?.cancel();
      setState(() => _mutedHintVisible = true);
      _mutedHintTimer = Timer(const Duration(seconds: 6), () {
        if (mounted) setState(() => _mutedHintVisible = false);
      });
    }));
  }

  /// 片尾跳过：只在「自然播放」越过阈值时触发，用户手动拖到结尾不算。
  /// 额外硬判据：累计真实前进量 ≥45s——broken stream 谎报的位置/时长
  /// 也会以小步进「自然」越过阈值（用户实测连跳集数），此门禁它。
  void _maybeSkipEnding(Duration previous, Duration current) {
    final skip = _playSkip;
    if (skip == null || _endingHandled || skip.endingMs <= 0) return;
    // 片尾跳过路径直接 _goNext（绕过 _onEnded），必须独立做时长真值验证，
    // 否则 broken stream 谎报小时长的「自然」推进可以借道提前跳下一集
    //（60688de 的连跳路径之一）。
    if (!durationTruthOk(
      durationSec: _duration.inMilliseconds / 1000,
      watchedSec: _watchedSeconds,
      serverDurationSec: _playback?.playback.durationSeconds ?? 0,
      resumeLowerBoundSec: _episodeStartAt.inMilliseconds / 1000,
      explicitSeekLowerBoundSec: _lastExplicitSeekSec,
    )) {
      return;
    }
    if (!AppScope.read(context).settings.skipIntroOutro) return;
    if (_duration <= Duration.zero) return;
    final threshold =
        _duration - Duration(milliseconds: skip.endingMs);
    if (threshold <= Duration.zero) return;
    final naturalForward = current > previous &&
        (current - previous) < const Duration(seconds: 5);
    if (!naturalForward || current < threshold) return;
    _endingHandled = true;
    final settings = AppScope.read(context).settings;
    // 最后一集且有下一季时也允许自动前进（切季由 _goNext 负责）。
    final bool canAutoNext = settings.autoNext &&
        (_index < widget.episodes.length - 1 ||
            hasNextPlayableSeason(widget.seasons, widget.series.id));
    // 跳过分支原先只有 OSD，日志里会凭空多出一条「打开第X集（自动）」；
    // 补一行判定依据（阈值/片尾偏移/真实前进量）与去向，便于对账。
    ErrorLog.instance.record(
      '播放',
      '片尾跳过 pos=${(current.inMilliseconds / 1000).toStringAsFixed(1)}s'
      ' · dur=${(_duration.inMilliseconds / 1000).toStringAsFixed(1)}s'
      ' · threshold=${(threshold.inMilliseconds / 1000).toStringAsFixed(1)}s'
      ' · ending=${skip.endingMs}ms'
      ' · watched=${_watchedSeconds.toStringAsFixed(1)}s'
      ' → ${canAutoNext ? '自动连播' : '停在本集'}',
    );
    if (canAutoNext) {
      _episodeEnded = true;
      _recordHistory(finished: true);
      _showOsd(AppIcons.next, '已跳过片尾，播放下一集');
      _goNext();
    } else {
      _engine.pause();
      unawaited(_seekTo(threshold));
      _showOsd(AppIcons.next, '已跳过片尾');
    }
  }

  Future<void> _flushHistory() async {
    if (_historyWriteInFlight || _disposed || !_prepared || _episodeEnded) {
      return;
    }
    _historyWriteInFlight = true;
    try {
      await _recordHistory(finished: false);
      _historyThrottle.markWritten(_position);
    } finally {
      _historyWriteInFlight = false;
    }
  }

  /// 中央 OSD 提示（音量 / 快进 / 倍速 / 换线等）。
  void _showOsd(IconData icon, String text) {
    if (!mounted) return;
    _osdTimer?.cancel();
    setState(() {
      _osdIcon = icon;
      _osdText = text;
    });
    _osdTimer = Timer(const Duration(milliseconds: 1400), () {
      if (mounted) {
        setState(() {
          _osdIcon = null;
          _osdText = null;
        });
      }
    });
  }

  /// 带「撤销」动作的提示（跳过片头等）。
  void _showOsdWithUndo(IconData icon, String text, VoidCallback onUndo) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Row(
          children: [
            Icon(icon, color: PlayerOverlayTokens.textPrimary, size: 18),
            AppGap.h(AppGapSize.s8),
            Expanded(child: Text(text)),
          ],
        ),
        duration: const Duration(seconds: 5),
        // 浮起并抬到底栏之上：默认贴底的 SnackBar 会压住进度条与
        // 播放/选集按钮 5 秒（点击被它吃掉，用户以为按钮坏了）。
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.fromLTRB(24, 0, 24, 96),
        action: SnackBarAction(label: '撤销', onPressed: onUndo),
      ));
  }

  /// 倍速统一入口：限制范围、应用、按剧记忆、OSD。
  ///
  /// [source] 只用于诊断日志（菜单/键盘/CLI）：换集后看到 `rate=2x` 时，
  /// 能区分「用户改的」还是「长按临时态」，不用猜。
  Future<void> _applySpeed(double value, {String source = '菜单'}) async {
    final history = AppScope.read(context).history;
    // 用户显式改倍速 = 退出长按锁定，否则引擎会被临时 2x 覆盖。
    _cancelHoldSpeed();
    final v = value.clamp(0.5, 3.0).toDouble();
    setState(() => _speed = v);
    ErrorLog.instance
        .record('播放', '倍速 ${_trimSpeed(v)}x（来源：$source）');
    await _engine.setRate(v);
    _showOsd(Icons.speed_rounded, '倍速 ${_trimSpeed(v)}x');
    try {
      await history.setPlaybackPrefs(seriesId: widget.series.id, speed: v);
    } catch (_) {}
  }

  /// 播放本地缓存文件：密钥为空说明未加密，直接播；否则带 decryption_key。
  Future<void> _playLocal(DownloadEntry entry, Duration startAt) async {
    _currentVideoStream = null;
    _playbackFailure = null;
    _rawPlaybackError = null;
    _fallbackTimer?.cancel();
    _fallbackTimer = null;
    _fallbackInFlight = false;
    _candidates = const [];
    _triedUrls.clear();
    _playEpoch++;
    _attemptStart = startAt;
    _durationLogged = false;
    _logBuffer.clear();
    final lavf = [
      'seg_max_retry=3',
      'strict=experimental',
      'allowed_extensions=ALL',
      lavfProtocolWhitelist(protocols: kMpvLavfLocalProtocols),
      if (entry.keyHex.isNotEmpty) 'decryption_key=${entry.keyHex}',
    ].join(',');
    await _engine.setProperty('demuxer-lavf-o', lavf);
    // 本地文件没有外挂音轨：清掉上一集可能残留的 audio-files，否则 mpv 会
    // 把残留 URL 当本集外挂音轨去打开（机制与理由同 _playStream）。
    await _engine.command(mpvClearPathListCommand('audio-files'));
    // 换集/换线沿用当前生效速率：锁定 2 倍速时不能悄悄回到用户档位。
    await _engine.setRate(_effectiveRate);
    await _engine.open(Media(entry.filePath), play: true);
    // open 后补一次，防个别内核 load 时重置 speed（幂等，不影响续播顺序）。
    await _engine.setRate(_effectiveRate);
    await _seekResume(startAt);
    if (_disposed) return;
    setState(() => _prepared = true);
    unawaited(_maybeShowPlayerGuide());
    _historyThrottle.reset(
      baseline: startAt,
      floor: startAt > const Duration(seconds: 1)
          ? startAt - const Duration(seconds: 1)
          : null,
    );
    _maybeShowMutedHint();
  }

  Future<void> _switchDefinition(String label) async {
    final pb = _playback;
    if (pb == null) return;
    final stream = pb.playback.streams.firstWhere(
      (s) => s.url.isNotEmpty && _definitionLabel(s) == label,
      orElse: () => pb.playback.streams.first,
    );
    final resumeAt = _position;
    _reResolved = false;
    setState(() {
      _selectedDefinition = label;
      _quality = label;
    });
    // 清晰度按剧记忆，换集与下次打开沿用。
    try {
      await AppScope.read(context)
          .history
          .setPlaybackPrefs(seriesId: widget.series.id, quality: label);
    } catch (_) {}
    await _playStream(stream, resumeAt);
  }

  /// 换线/重解析重开位置：取已播位置与断点的较大者；已知时长时钳到终点前
  /// 5s——异常 EOF 常发生在终点附近，seek 到「正好终点」会让新线路立刻再
  /// completed 白耗一轮候选（2026-11-15 实测：51s 集 seek 51s → 秒 EOF）。
  Duration _fallbackResumePos() {
    Duration resume = _position > _attemptStart ? _position : _attemptStart;
    final double durSec = _engine.state.duration.inMilliseconds / 1000;
    if (durSec > 10 && resume.inMilliseconds >= (durSec - 5) * 1000) {
      resume = Duration(milliseconds: ((durSec - 5) * 1000).floor());
    }
    return resume;
  }

  /// 换线/重解析重开前清干净上一条线路的 EOF 状态（与 _openEpisode 开播
  /// 重置同语义）：否则新线路再发 completed 会被 _onEnded 的
  /// _episodeEnded 早退吞掉，用户看到的就是停在终点不动。
  void _resetEndedStateForRetry() {
    _episodeEnded = false;
    _endingHandled = false;
    _watchedSeconds = 0;
    _lastWatchPos = Duration.zero;
    _durationLogged = false;
  }

  void _onEnded() {
    if (_episodeEnded || _disposed) return;
    // 异常 EOF 防误判（用户实测：长时间加载不出来 → broken stream 也发
    // completed → 被当正常播完 → 历史误标「已看完」+ 连跳集数）。
    // 三重独立证据见 trustPlaybackCompletion：位置真实到达终点 + 时长真值
    // 交叉验证（服务端时长 / 续播下限，无真值时 45s 硬门禁兜底）+ 确实
    // 播过。60688de 的唯一 45s 门禁误伤短剧集续播近片尾（51s 集从 50s 续播
    // 只前进 1s 就合法播完）→ 换线死循环，2026-11-15 改多信号判定。
    final double posSec = _engine.state.position.inMilliseconds / 1000;
    final double durSec = _engine.state.duration.inMilliseconds / 1000;
    final int serverDur = _playback?.playback.durationSeconds ?? 0;
    final double resumeBound = _episodeStartAt.inMilliseconds / 1000;
    // 真值来源单独取一次（进日志）；信任布尔仍走 trustPlaybackCompletion，
    // 两者内部都落在 durationTruthSource，不会漂移。
    final DurationTruthSource? truth = durationTruthSource(
      durationSec: durSec,
      watchedSec: _watchedSeconds,
      serverDurationSec: serverDur,
      resumeLowerBoundSec: resumeBound,
      explicitSeekLowerBoundSec: _lastExplicitSeekSec,
    );
    final bool realEnded = trustPlaybackCompletion(
      positionSec: posSec,
      durationSec: durSec,
      watchedSec: _watchedSeconds,
      serverDurationSec: serverDur,
      resumeLowerBoundSec: resumeBound,
      explicitSeekLowerBoundSec: _lastExplicitSeekSec,
    );
    _episodeEnded = true;
    if (!realEnded) {
      unawaited(_recordPlaybackHealth(PlaybackHealthEvent.failed));
      final String detail = '流异常中断（position=${posSec.toStringAsFixed(1)}s / '
          'duration=${durSec.toStringAsFixed(1)}s / '
          'watched=${_watchedSeconds.toStringAsFixed(1)}s）';
      ErrorLog.instance.record(
        '播放',
        '$detail → 忽略 completed，不记「已看完」；'
        '${_candidates.isEmpty ? '无候选线路，提示重试' : '尝试换线'}',
        StackTrace.current,
      );
      if (mounted) _showOsd(AppIcons.errorOutline, '播放流异常中断，尝试换源…');
      // 异常 EOF 走与慢缓冲同一条换线恢复链：有候选就换线重开本集
      // （_openEpisode 会重置 _episodeEnded/_watchedSeconds）；无候选
      // 自动落到错误面板（可重试）。绝不写「已看完」、绝不连跳集数。
      _rawPlaybackError = detail;
      unawaited(_attemptFallback());
      return;
    }
    unawaited(_recordPlaybackHealth(PlaybackHealthEvent.success));
    // 观测：真播完路径也留一行，与异常 EOF 对账；标注信任判定命中的
    // 真值层级（服务端真值 / 续播下限 / watched 兜底），排查「连播间隔
    // 异常短」时直接区分倍速/集短 vs 流截断。
    final bool autoNext = AppScope.read(context).settings.autoNext;
    final String truthLabel = switch (truth) {
      DurationTruthSource.server => '服务端真值',
      DurationTruthSource.resumeBound => '续播下限',
      DurationTruthSource.seekBound => '显式seek下限',
      DurationTruthSource.watchedFallback => 'watched兜底',
      null => '无真值',
    };
    ErrorLog.instance.record(
      '播放',
      '自然播完 pos=${posSec.toStringAsFixed(1)}s'
      ' · dur=${durSec.toStringAsFixed(1)}s'
      ' · watched=${_watchedSeconds.toStringAsFixed(1)}s'
      ' · server=$serverDur'
      ' · 真值=$truthLabel'
      ' → ${autoNext && _index < widget.episodes.length - 1 ? '自动连播' : '停在本集'}',
    );
    _recordHistory(finished: true);
    if (autoNext) {
      _goNext();
    }
  }

  void _goNext({bool manual = false}) {
    if (_index < widget.episodes.length - 1) {
      // 连播意图先落盘：自动进下一集前把断点挪过去（position=0）。崩溃
      // 高发场景（安卓连播）下，没有这条的话整段连播进度可能一行都不落盘
      // ——每集刚开播几秒就崩，节流窗口（5s）与 position>0 门槛都过不去，
      // 重启后历史停在很久以前的旧集。起播失败断点留在下一集 0s，比留在
      // 旧集尾部更符合「我在连播」的预期；manual（用户点下一集）同理。
      unawaited(_recordHistory(
        finished: false,
        force: true,
        episodeIndex: _index + 1,
        positionOverride: Duration.zero,
      ));
      _openEpisode(_index + 1, Duration.zero, manual: manual);
    } else {
      // 本季播完：有下一季就接着播下一季第 1 集（参考实现的 following()）。
      final next = nextPlayableSeason(widget.seasons, widget.series.id);
      if (next != null) {
        unawaited(_openSeasonEpisode(next));
        return;
      }
      _showToast('已经是最后一集了');
    }
  }

  /// 拉取某季的剧与全集（分页聚合）。选集面板按季浏览也走同一份数据。
  Future<(Series, List<Episode>)> _fetchSeason(String seriesId) async {
    final api = AppScope.read(context).api;
    final series = await api.getSeries(seriesId);
    final episodes = <Episode>[];
    var cursor = '';
    while (true) {
      final page = await api.listEpisodes(seriesId, cursor: cursor);
      episodes.addAll(page.items);
      if (!page.hasMore || page.items.isEmpty) break;
      if (page.cursor.isEmpty || page.cursor == cursor) break;
      cursor = page.cursor;
    }
    return (series, episodes);
  }

  /// 切季播放：拉目标季的剧与全集，替换当前播放器页，从 [startIndex] 起播。
  ///
  /// 不改 `widget.*`（final），用 pushReplacement 让路由栈保持一层；
  /// 旧页 dispose 跳过全屏还原、新页继承 `_fullscreen`，所以全屏观看不会被打断。
  ///
  /// 二轮反馈：选集面板点季标签只**浏览**不播放，起播唯一入口是
  /// `_openEpisodePicker` / 边缘抽屉里点到具体某一集（跨季走这里），
  /// 以及本季播完的自动连播。
  Future<void> _openSeasonEpisode(Season season, {int startIndex = 0}) async {
    if (_disposed || season.seriesId.isEmpty ||
        season.seriesId == widget.series.id) {
      return;
    }
    try {
      final (series, episodes) = await _fetchSeason(season.seriesId);
      if (episodes.isEmpty || !mounted) {
        _showToast('这一季还没有可播放的剧集');
        return;
      }
      final bool fullscreen = _isDesktop &&
          await windowManager.isFullScreen();
      if (!mounted) return;
      final int start = startIndex.clamp(0, episodes.length - 1);
      _skipFullscreenRestoreOnDispose = true;
      await Navigator.of(context).pushReplacement(
        MaterialPageRoute<void>(
          // 冷启动会话恢复（R1）：跨季换页也带上 name + arguments，观察者
          // 把「上次停留页」跟到新季（新页 _openEpisode 的自报兜底同值）。
          settings: RouteSettings(
            name: kRouteNamePlayer,
            arguments: LastRoute.player(
              seriesId: series.id,
              episode: episodes[start].number,
            ),
          ),
          builder: (_) => PlayerScreen(
            series: series,
            episodes: episodes,
            startIndex: start,
            startAt: Duration.zero,
            seasons: widget.seasons,
            contentType: widget.contentType,
            keepFullscreen: fullscreen,
            // 换季接续用户档位（长按 2x 属临时态，不跨页、不写偏好）。
            initialSpeed: _speed,
          ),
        ),
      );
    } catch (e, stack) {
      ErrorLog.instance.record('播放', '切季失败 ${season.seriesId}：$e', stack);
      if (mounted) _showToast('切季失败，请稍后重试');
    }
  }

  void _goPrev({bool manual = false}) {
    if (_index > 0) {
      _openEpisode(_index - 1, Duration.zero, manual: manual);
    } else {
      _showToast('已经是第一集了');
    }
  }

  /// AI / aquan-cli 的播放控制入口（PlayerHandle）。
  @override
  Map<String, dynamic> control(LaunchCommand command) {
    if (!mounted || _disposed) {
      return {'ok': false, 'playing': false, 'message': '播放器已关闭'};
    }
    final kind = command.kind;
    switch (kind) {
      case 'pause':
        _engine.pause();
        return {'ok': true, 'playing': false};
      case 'resume':
        _engine.play();
        return {'ok': true, 'playing': true};
      case 'toggle':
        _engine.playOrPause();
        return {'ok': true, 'playing': _engine.state.playing};
      case 'next':
        _goNext(manual: true);
        return {'ok': true};
      case 'prev':
        _goPrev(manual: true);
        return {'ok': true};
      case 'status':
        return _statusPayload();
      case 'seek':
        return _controlSeek(command.value);
      case 'volume':
        return _controlVolume(command.value);
      case 'speed':
        return _controlSpeed(command.value);
      case 'quality':
        return _controlQuality(command.value);
      case 'open':
        // 窗口已由命令处理方置顶，这里只回报状态摘要。
        return _statusPayload();
    }
    return {'ok': false, 'error': '未知命令 $kind'};
  }

  /// seek：纯数字按秒（绝对）；`+30`/`-15` 相对当前；也认 `mm:ss` / `hh:mm:ss`。
  Map<String, dynamic> _controlSeek(String value) {
    final target = _parseSeek(value);
    if (target == null) {
      return {'ok': false, 'error': '无法解析进度 "$value"'};
    }
    final text = value.trim();
    final absolute = !text.startsWith('+') && !text.startsWith('-');
    var dest = absolute ? target : _position + target;
    if (dest < Duration.zero) dest = Duration.zero;
    if (_duration > Duration.zero && dest > _duration) dest = _duration;
    unawaited(_seekTo(dest));
    _showOsd(AppIcons.fastForward, '跳转 ${_fmtDur(dest)}');
    return {'ok': true, 'position': _fmtDur(dest)};
  }

  Duration? _parseSeek(String raw) {
    final text = raw.trim().replaceFirst(RegExp(r'^\+'), '');
    final negative = text.startsWith('-');
    final body = negative ? text.substring(1) : text;
    // mm:ss / hh:mm:ss
    if (body.contains(':')) {
      var seconds = 0;
      for (final part in body.split(':')) {
        final v = int.tryParse(part.trim());
        if (v == null) return null;
        seconds = seconds * 60 + v;
      }
      return Duration(seconds: negative ? -seconds : seconds);
    }
    final seconds = double.tryParse(body);
    if (seconds == null) return null;
    final d = Duration(milliseconds: (seconds * 1000).round());
    return negative ? -d : d;
  }

  /// volume：`up`/`down` ±10，数字 0-100 绝对设置。
  Map<String, dynamic> _controlVolume(String value) {
    final text = value.trim().toLowerCase();
    double volume;
    switch (text) {
      case 'up':
        volume = (_engine.state.volume + 10).clamp(0.0, 100.0);
      case 'down':
        volume = (_engine.state.volume - 10).clamp(0.0, 100.0);
      default:
        final v = double.tryParse(text);
        if (v == null || v < 0 || v > 100) {
          return {'ok': false, 'error': '音量要在 0-100 之间（或 up/down）'};
        }
        volume = v;
    }
    unawaited(_engine.setVolume(volume));
    _showOsd(AppIcons.volume, '音量 ${volume.round()}%');
    return {'ok': true, 'volume': volume.round()};
  }

  /// speed：倍速 0.5-3.0，按剧记忆（与播放器菜单同一份偏好）。
  Map<String, dynamic> _controlSpeed(String value) {
    final v = double.tryParse(value.trim().replaceAll('x', ''));
    if (v == null || v < 0.5 || v > 3.0) {
      return {'ok': false, 'error': '倍速支持 0.5-3.0'};
    }
    _applySpeed(v, source: 'CLI');
    return {'ok': true, 'speed': v};
  }

  static String _trimSpeed(double v) =>
      v == v.roundToDouble() ? v.round().toString() : v.toString();

  /// quality：切换清晰度（如 1080p / 720p / best / worst）。
  /// 未指明的标签按包含匹配当前可选清晰度。
  Map<String, dynamic> _controlQuality(String value) {
    final want = value.trim().toLowerCase();
    final candidates = _definitions.where((d) => d.toLowerCase().contains(want)).toList();
    if (candidates.isEmpty && (want == 'best' || want == 'worst')) {
      final usable = _playback?.playback.streams
              .where((s) => s.url.isNotEmpty)
              .toList() ??
          const <VideoStream>[];
      if (usable.isNotEmpty) {
        final target = _selectStream(_playback!.playback, want);
        final label = _definitionLabel(target);
        final resumeAt = _position;
        _reResolved = false;
        setState(() {
          _selectedDefinition = label;
          // 记住的是「最高/最低」意图，而不是当时命中的具体档位，
          // 片源增加更高清晰度时会自动跟上。
          _quality = want;
        });
        unawaited(_persistQualityAndPlay(want, target, resumeAt));
        return {'ok': true, 'quality': label};
      }
    }
    if (candidates.isEmpty) {
      return {'ok': false, 'error': '没有「$value」清晰度，可选：${_definitions.join(" / ")}'};
    }
    _switchDefinition(candidates.last);
    return {'ok': true, 'quality': candidates.last};
  }

  Future<void> _persistQualityAndPlay(
      String quality, VideoStream target, Duration resumeAt) async {
    try {
      await AppScope.read(context)
          .history
          .setPlaybackPrefs(seriesId: widget.series.id, quality: quality);
    } catch (_) {}
    await _playStream(target, resumeAt);
  }

  Map<String, dynamic> _statusPayload() {
    final ep = widget.episodes[_index.clamp(0, widget.episodes.length - 1)];
    return {
      'ok': true,
      'playing': _engine.state.playing,
      'series': widget.series.title,
      'episode': ep.number,
      'episode_title': ep.title,
      'position': _fmtDur(_position),
      'duration': _fmtDur(_duration),
      'speed': _speed,
      'quality': _selectedDefinition ?? _quality,
      'mini': _mini,
    };
  }

  /// 操作说明面板（F1 / 「更多 → 快捷键 / 操作说明」）。
  ///
  /// 按输入设备分流：桌面讲键盘，TV 讲遥控器，移动端讲手势——移动端不再
  /// 展示一份用不上的键盘快捷键（用户实测反馈）。
  void _showShortcutHelp() {
    final List<_Shortcut> rows;
    final String title;
    if (_isDesktop) {
      title = '键盘快捷键';
      rows = const [
        _Shortcut(key_: '空格', action: '暂停 / 播放'),
        _Shortcut(key_: '← / →', action: '快退 / 快进 10 秒'),
        _Shortcut(key_: '↑ / ↓', action: '上一集 / 下一集'),
        _Shortcut(key_: 'F', action: '全屏切换'),
        _Shortcut(key_: 'M', action: '静音'),
        _Shortcut(key_: 'D', action: '弹幕开关'),
        _Shortcut(key_: 'C / X', action: '倍速 +0.25 / -0.25'),
        _Shortcut(key_: 'Z', action: '恢复 1.0x'),
        _Shortcut(key_: 'E', action: '选集'),
        _Shortcut(key_: 'F1', action: '本帮助'),
        _Shortcut(key_: 'PgUp / PgDn', action: '上一集 / 下一集'),
        _Shortcut(key_: 'Esc', action: '退出全屏'),
      ];
    } else if (_isTv) {
      title = '遥控器操作';
      rows = const [
        _Shortcut(key_: '确定键', action: '显示 / 隐藏控制栏'),
        _Shortcut(key_: '← / →', action: '快退 / 快进 10 秒（控制栏隐藏时）'),
        _Shortcut(key_: '上一曲 / 下一曲', action: '上一集 / 下一集'),
        _Shortcut(key_: '播放 / 暂停键', action: '暂停 / 继续'),
        _Shortcut(key_: 'D 键', action: '弹幕开关（带键盘的遥控器）'),
        _Shortcut(key_: '返回键', action: '收起控制栏 / 返回上一页'),
      ];
    } else {
      title = '手势操作';
      rows = const [
        _Shortcut(key_: '单击画面', action: '显示 / 隐藏控制栏'),
        _Shortcut(key_: '双击画面', action: '暂停 / 继续'),
        _Shortcut(key_: '上滑', action: '下一集'),
        _Shortcut(key_: '下滑', action: '上一集'),
        _Shortcut(key_: '左右拖动', action: '快进 / 快退'),
        _Shortcut(key_: '长按画面', action: '2 倍速（下滑锁定）'),
        _Shortcut(key_: '底部「选集」', action: '切换分集'),
      ];
    }
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: rows,
        ),
        actions: [
          FilledButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('知道了')),
        ],
      ),
    );
  }

  /// 窄屏底栏放不下时，「更多」里的睡眠定时二级选择。
  Future<void> _pickSleepTimer() async {
    const options = <int>[0, 15, 30, 60];
    final picked = await showModalBottomSheet<int>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final m in options)
              ListTile(
                title: Text(m == 0 ? '不定时' : '$m 分钟后暂停'),
                trailing: _sleepMinutes == m ? const Icon(AppIcons.check) : null,
                onTap: () => Navigator.pop(sheetContext, m),
              ),
          ],
        ),
      ),
    );
    if (picked != null && mounted) _setSleepTimer(picked);
  }

  /// 弹幕显示设置（行数 / 速度 / 字号 / 不透明度 + 屏蔽词入口）。
  Future<void> _openDanmakuSettings() async {
    await showDanmakuSettingsSheet(context);
    if (mounted) setState(() {});
  }

  /// 窄屏底栏放不下时，「更多」里的倍速二级选择。
  Future<void> _pickSpeed() async {
    const options = <double>[0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0];
    // 玻璃在播放器上下文不可见（GlassContainer own-layer × media_kit ANGLE
    // 纹理冲突，批次⑤实测）→ OSD 面板退回实体表面（§11.6 出口），果冻展开保留。
    final picked = await showModalBottomSheet<double>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: JellySheetReveal(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final v in options)
                ListTile(
                  title: Text('${_trimSpeed(v)}x'),
                  trailing: _speed == v ? const Icon(AppIcons.check) : null,
                  onTap: () => Navigator.pop(sheetContext, v),
                ),
            ],
          ),
        ),
      ),
    );
    if (picked != null && mounted) await _applySpeed(picked);
  }

  /// 睡眠定时：到点暂停播放；选「关」取消。
  void _setSleepTimer(int minutes) {
    _sleepTimer?.cancel();
    if (!mounted) return;
    setState(() => _sleepMinutes = minutes);
    if (minutes <= 0) {
      _showToast('已取消睡眠定时');
      return;
    }
    _sleepTimer = Timer(Duration(minutes: minutes), () {
      if (_disposed) return;
      _engine.pause();
      _showToast('睡眠时间到，已暂停');
      if (mounted) setState(() => _sleepMinutes = 0);
    });
    _showToast('将在 $minutes 分钟后暂停');
  }

  // ---------- PC 全屏：右侧边缘选集 ----------

  /// 选集面板点季标签：底部抽屉与全屏侧栏共用。
  /// 选集面板点到其它季的某一集：切到那一季从该集起播。
  void _onPlaySeasonEpisode(Season season, int indexInSeason) =>
      unawaited(_openSeasonEpisode(season, startIndex: indexInSeason));

  /// 已看完的集号（旧记录没有该字段时为空表，不打勾）。
  Set<int> _watchedEpisodeNumbers() {
    final history = AppScope.read(context).history;
    return history.get(widget.series.id)?.watchedEpisodes.toSet() ??
        const <int>{};
  }

  void _handleEdgeEnter() {
    _edgeHovered = true;
    final bool shouldOpen = edgePanelShouldOpen(
      hoverEdge: true,
      suppressed: _edgePanelSuppressed,
    );
    if (!shouldOpen || !mounted) return;
    _edgeCloseTimer?.cancel();
    setState(() {
      _edgePanelOpen = true;
      // 每次打开换 key：EpisodeGrid 重新初始化 → 当前集重新居中。
      _edgePanelToken++;
    });
  }

  void _handleEdgeExit() {
    _edgeHovered = false;
    // 指针离开边缘即解除「手动关闭」的抑制，下次靠近才会再弹。
    _edgePanelSuppressed = false;
    _scheduleEdgeClose();
  }

  void _handlePanelEnter() {
    _edgePanelHovered = true;
    _edgeCloseTimer?.cancel();
  }

  void _handlePanelExit() {
    _edgePanelHovered = false;
    // 季下拉是独立 overlay 路由：菜单一开，鼠标对抽屉的 MouseRegion 必然
    // onExit。不豁免的话抽屉 260ms 后自动收起、控制器 dispose、用户选的
    // 新季直接丢掉（用户实测「点了换季抽屉消失、选了也不生效」）。
    if (_edgeSeasonMenuOpen) return;
    _scheduleEdgeClose();
  }

  /// 延迟收起：进出热区与抽屉之间会有 1 帧的空档，立即收会闪。
  void _scheduleEdgeClose() {
    _edgeCloseTimer?.cancel();
    _edgeCloseTimer = Timer(const Duration(milliseconds: 260), () {
      if (!mounted || !_edgePanelOpen) return;
      if (!edgePanelShouldClose(
        hoverEdge: _edgeHovered,
        hoverPanel: _edgePanelHovered,
      )) {
        return;
      }
      setState(() => _edgePanelOpen = false);
    });
  }

  void _closeEdgePanel() {
    _edgeCloseTimer?.cancel();
    // 抑制位只在「指针此刻仍压在 16px 热区里」才有意义：那种情况指针不动
    // 就不会有 exit→enter，防止原地立即重开。选集时指针在抽屉中部（热区
    // 之外），置位会让下一次靠近右边缘的第一次 enter 被吞——「选完集再靠
    // 近右边缘面板出不来、过几秒（先离开热区）才能出来」的根因（用户实测）。
    _edgePanelSuppressed = _edgeHovered;
    if (!mounted) return;
    if (_edgePanelOpen) setState(() => _edgePanelOpen = false);
  }

  /// 右侧 16px 热区 + 滑出抽屉。只画在视频层之上、控制栏之下。
  ///
  /// 抽屉高度避开底部控制栏（二轮反馈：最后一行集数被控制栏遮住）——
  /// 底部留出进度条 + 按钮行的高度，抽屉不再延伸到控制栏区域。
  Widget _buildEdgeEpisodePanel(BuildContext context) {
    final double width = MediaQuery.sizeOf(context).width < 760
        ? MediaQuery.sizeOf(context).width * 0.46
        : 320;
    return Positioned.fill(
      child: Stack(
        children: <Widget>[
          Positioned(
            right: 0,
            top: 0,
            bottom: 0,
            width: kEdgePanelHotZoneWidth,
            child: MouseRegion(
              opaque: false,
              onEnter: (_) => _handleEdgeEnter(),
              onExit: (_) => _handleEdgeExit(),
              child: const SizedBox.expand(),
            ),
          ),
          AnimatedSlide(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOutCubic,
            offset: _edgePanelOpen ? Offset.zero : const Offset(1, 0),
            child: Align(
              alignment: Alignment.centerRight,
              child: MouseRegion(
                onEnter: (_) => _handlePanelEnter(),
                onExit: (_) => _handlePanelExit(),
                child: Padding(
                  // 与控制栏视觉错开：进度条(24) + 底栏(48) + 安全间距。
                  padding: const EdgeInsets.only(bottom: kEdgePanelBottomInset),
                  child: SizedBox(
                    width: width,
                    height: double.infinity,
                    child: PlayerEpisodeDrawer(
                      key: ValueKey<int>(_edgePanelToken),
                      title: widget.series.title,
                      episodes: widget.episodes,
                      currentIndex: _index,
                      playingSeriesId: widget.series.id,
                      seasons: widget.seasons,
                      fetchSeasonEpisodes: (seriesId) async =>
                          (await _fetchSeason(seriesId)).$2,
                      watchedEpisodes: _watchedEpisodeNumbers(),
                      isDownloaded: (ep) =>
                          AppScope.read(context).downloads.store.has(ep.id),
                      onSelect: (i) {
                        _closeEdgePanel();
                        if (_disposed || i == _index) return;
                        _openEpisode(i, Duration.zero, manual: true);
                      },
                      onPlaySeasonEpisode: _onPlaySeasonEpisode,
                      onClose: _closeEdgePanel,
                      onSeasonMenuOpenChanged: (open) {
                        if (_edgeSeasonMenuOpen == open) return;
                        _edgeSeasonMenuOpen = open;
                        if (open) {
                          _edgeCloseTimer?.cancel();
                        } else {
                          // 菜单关掉后重新裁决：鼠标回到抽屉 → onEnter 会
                          // 取消计时；点在外面关的 → 260ms 后正常收起。
                          _scheduleEdgeClose();
                        }
                      },
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 选集抽屉：点任意一集直接换集；点季标签只浏览（见 R6）。
  Future<void> _openEpisodePicker() async {
    if (widget.episodes.isEmpty || _disposed) return;
    final scope = AppScope.read(context);
    final downloads = scope.downloads;
    await showEpisodePicker(
      context,
      title: widget.series.title,
      episodes: widget.episodes,
      currentIndex: _index,
      playingSeriesId: widget.series.id,
      seasons: widget.seasons,
      fetchSeasonEpisodes: (seriesId) async =>
          (await _fetchSeason(seriesId)).$2,
      watchedEpisodes: _watchedEpisodeNumbers(),
      onSelect: (i) {
        if (_disposed || i == _index) return;
        _openEpisode(i, Duration.zero, manual: true);
      },
      onPlaySeasonEpisode: _onPlaySeasonEpisode,
      isDownloaded: (ep) => downloads.store.has(ep.id),
      onDownload: () {
        Navigator.of(context).pop();
        showDownloadSheet(
          context,
          series: widget.series,
          episodes: widget.episodes,
        );
      },
    );
  }

  /// 清晰度选择面板：即使源只提供一路，也能看到当前清晰度；
  /// 「最高可用」会忽略按剧记忆切到最高。
  Future<void> _openQualitySheet() async {
    if (_definitions.isEmpty) {
      _showToast('当前源没有提供清晰度信息');
      return;
    }
    final picked = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: JellySheetReveal(
          child: ListView(
            shrinkWrap: true,
            children: [
              ListTile(
                title: const Text('清晰度'),
                subtitle: Text(
                    '当前：${_selectedDefinition ?? '最高可用'}；默认清晰度在「我的 → 设置」调整'),
              ),
            for (final definition in _definitions)
              ListTile(
                title: Text(definition),
                trailing: definition == _selectedDefinition
                    ? const Icon(AppIcons.check)
                    : null,
                onTap: () => Navigator.pop(sheetContext, definition),
              ),
              if (_playback != null)
                ListTile(
                  leading: const Icon(AppIcons.hd),
                  title: const Text('最高可用'),
                  subtitle: const Text('忽略按剧记忆，切到当前源最高清晰度'),
                  onTap: () => Navigator.pop(sheetContext, 'best'),
                ),
            ],
          ),
        ),
      ),
    );
    if (picked == null || !mounted) return;
    if (picked == 'best') {
      _controlQuality('best');
    } else {
      _switchDefinition(picked);
    }
  }

  /// 截取当前画面：桌面端保存为 PNG，Android 走系统分享。
  Future<void> _captureScreenshot() async {
    try {
      final bytes = await _engine.screenshot(
        format: 'image/png',
        includeLibassSubtitles: true,
      );
      if (bytes == null) {
        _showToast('截图失败：当前画面不可用');
        return;
      }
      final stamp = DateTime.now()
          .toIso8601String()
          .replaceAll(RegExp(r'[:.]'), '-');
      final name = 'aquan_$stamp.png';
      if (Platform.isAndroid) {
        final dir = await getTemporaryDirectory();
        final file = File('${dir.path}${Platform.pathSeparator}$name');
        await file.writeAsBytes(bytes);
        await SharePlus.instance
            .share(ShareParams(files: [XFile(file.path)]));
        return;
      }
      final location = await getSaveLocation(
        suggestedName: name,
        acceptedTypeGroups: const [
          XTypeGroup(label: 'PNG 图片', extensions: ['png'])
        ],
      );
      if (location == null) return;
      await File(location.path).writeAsBytes(bytes);
      _showToast('截图已保存');
    } catch (e) {
      _showToast('截图失败：$e');
    }
  }

  /// 播放信息：分辨率、编码、硬解状态、音轨、缓冲、引擎版本。
  Future<void> _openPlaybackInfo() async {
    String? engineVersion;
    String? hwdec;
    try {
      engineVersion = await _engine.getProperty('mpv-version');
      hwdec = await _engine.getProperty('hwdec-current');
    } catch (_) {}
    if (!mounted) return;
    final ep = widget.episodes[_index.clamp(0, widget.episodes.length - 1)];
    await showPlayerInfoDialog(
      context,
      PlayerInfoData(
        engine: _engine,
        title: widget.series.title,
        episodeLabel:
            '第${ep.number}集${ep.title.isEmpty ? '' : ' · ${ep.title}'}',
        quality: _selectedDefinition,
        url: _currentVideoStream?.url,
        engineVersion: engineVersion,
        hwdecCurrent: hwdec,
      ),
    );
  }

  /// 片头片尾设置：按时长/当前位置设置，按剧记忆；打开开关后立即生效。
  Future<void> _openSkipSettings() async {
    final scope = AppScope.read(context);
    final current = _playSkip ?? const PlaySkipEntry();
    var enabled = scope.settings.skipIntroOutro;
    var opening = current.openingMs;
    var ending = current.endingMs;
    final saved = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) {
          final theme = Theme.of(context);
          return AlertDialog(
            title: const Text('片头片尾'),
            content: SizedBox(
              width: 420,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('启用片头片尾跳过'),
                      subtitle: const Text('按剧记忆，换集沿用'),
                      value: enabled,
                      onChanged: (v) => setDialogState(() => enabled = v),
                    ),
                    const Divider(),
                    Text(opening > 0
                            ? '片头：从开头跳过 ${_fmtSkipMs(opening)}'
                            : '片头：未设置',
                        style: theme.textTheme.bodyMedium
                            ?.copyWith(fontWeight: FontWeight.w600)),
                    AppGap.v(AppGapSize.s6),
                    Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      children: [
                        for (final sec in const [15, 30, 45, 60, 90])
                          JellyChip(
                            label: '$sec 秒',
                            selected: opening == sec * 1000,
                            onSelected: (_) =>
                                setDialogState(() => opening = sec * 1000),
                          ),
                        ActionChip(
                          avatar: const Icon(AppIcons.myLocation, size: 16),
                          label: const Text('设为当前位置'),
                          onPressed: _position.inMilliseconds > 500
                              ? () => setDialogState(
                                  () => opening = _position.inMilliseconds)
                              : null,
                        ),
                        ActionChip(
                          label: const Text('清除'),
                          onPressed: opening > 0
                              ? () => setDialogState(() => opening = 0)
                              : null,
                        ),
                      ],
                    ),
                    AppGap.v(AppGapSize.s12),
                    const Divider(),
                    Text(ending > 0
                            ? '片尾：提前 ${_fmtSkipMs(ending)} 结束'
                            : '片尾：未设置',
                        style: theme.textTheme.bodyMedium
                            ?.copyWith(fontWeight: FontWeight.w600)),
                    AppGap.v(AppGapSize.s6),
                    Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      children: [
                        for (final sec in const [30, 60, 90, 120])
                          JellyChip(
                            label: '$sec 秒',
                            selected: ending == sec * 1000,
                            onSelected: (_) =>
                                setDialogState(() => ending = sec * 1000),
                          ),
                        ActionChip(
                          avatar: const Icon(Icons.last_page, size: 16),
                          label: const Text('从当前位置算起'),
                          onPressed: _duration > const Duration(seconds: 5) &&
                                  _position <
                                      _duration - const Duration(seconds: 3)
                              ? () => setDialogState(() {
                                    final tail = (_duration - _position)
                                        .inMilliseconds
                                        .clamp(3000, 600000);
                                    ending = tail;
                                  })
                              : null,
                        ),
                        ActionChip(
                          label: const Text('清除'),
                          onPressed: ending > 0
                              ? () => setDialogState(() => ending = 0)
                              : null,
                        ),
                      ],
                    ),
                    AppGap.v(AppGapSize.s12),
                    Text(
                      '片尾只在自然播放接近末尾时触发；手动拖动进度条不会触发。',
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: theme.colorScheme.outline),
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(dialogContext, false),
                  child: const Text('取消')),
              FilledButton(
                  onPressed: () => Navigator.pop(dialogContext, true),
                  child: const Text('保存')),
            ],
          );
        },
      ),
    );
    if (saved != true || !mounted) return;
    scope.settings.skipIntroOutro = enabled;
    await scope.playSkip.upsert(
      widget.series.id,
      PlaySkipEntry(openingMs: opening, endingMs: ending),
    );
    if (!mounted) return;
    setState(() {
      _playSkip = (opening <= 0 && ending <= 0)
          ? null
          : PlaySkipEntry(openingMs: opening, endingMs: ending);
      _endingHandled = false;
    });
    _showOsd(Icons.content_cut_rounded,
        enabled ? '片头片尾设置已保存' : '已关闭片头片尾跳过');
    if (enabled &&
        opening > 0 &&
        _position < Duration(milliseconds: opening)) {
      await _seekTo(Duration(milliseconds: opening));
    }
  }

  String _fmtSkipMs(int ms) {
    if (ms <= 0) return '未设置';
    final seconds = (ms / 1000).round();
    if (seconds < 60) return '$seconds 秒';
    final minutes = seconds ~/ 60;
    final rest = seconds % 60;
    return rest == 0 ? '$minutes 分钟' : '$minutes 分 $rest 秒';
  }

  Future<void> _recordHistory({
    required bool finished,
    bool force = false,
    int? episodeIndex,
    Duration? positionOverride,
  }) async {
    if (widget.series.id.isEmpty) return;
    final ep = widget
        .episodes[(episodeIndex ?? _index).clamp(0, widget.episodes.length - 1)];
    // positionOverride 给「断点挪到另一集」的调用用（连播进下一集写 0）：
    // 默认读 _position 是「本集进度」，跨集复用会把 A 集位置写到 B 集上。
    final position = finished
        ? 0.0
        : (positionOverride?.inSeconds.toDouble() ??
            _position.inSeconds.toDouble());
    // 没真正播起来（起播失败 / 秒退 / 缓冲中退出）时不要用 0 覆盖已有断点；
    // 用户显式选集的「意图记录」（force）除外——那一步就是要挪断点。
    if (!finished && position <= 0 && !force) return;
    // 回退保护：同集、非用户主动回拖时，拒绝用明显更小的位置覆盖断点。
    // 换线后新线路从 0 起播是最常见的触发场景（用户反馈「跳到开头」）。
    if (!finished && !force) {
      final existing = _history.get(widget.series.id);
      final sameEpisode = existing != null && existing.episode == ep.number;
      if (_allowHistoryRewind) {
        _allowHistoryRewind = false;
      } else if (sameEpisode && existing.position > position + 10) {
        ErrorLog.instance.record(
          '播放',
          '历史回退被拒：第${ep.number}集 存量 ${existing.position}s > 新 ${position}s',
        );
        return;
      }
    }
    await _history.record(
      seriesId: widget.series.id,
      title: widget.series.title,
      coverUrl: widget.series.coverUrl,
      episode: ep.number,
      episodes: widget.episodes.length,
      episodeId: ep.id,
      position: position,
      finished: finished,
      speed: _speed,
      // 清晰度只在用户手动切换时持久化（_switchDefinition），
      // 自动选流 / 自动换线不能覆盖「最高」偏好。
      quality: '',
      // 发现页来源类型，供「继续观看」按短剧/漫剧/电影分类隔离。
      contentType: widget.contentType,
    );
  }

  // ---------- 手势 ----------

  void _scheduleHide() {
    // PiP 小窗里没有任何可点控件：不进自动隐藏计时（退出时统一恢复）。
    if (_inPip) return;
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 4), () {
      // 菜单开着时顺延：这一刻藏掉控制栏会连带卸载菜单（点不到/凭空消失）。
      if (!mounted) return;
      if (_menuOpenCount > 0) {
        _scheduleHide();
        return;
      }
      setState(() => _showControls = false);
      // 控制栏自动收起后，指针按「鼠标是否在动」决定可见性。
      _schedulePointerHide();
    });
  }

  /// 浮层菜单开合计数（dock 菜单与 PopupMenu 共用）。
  void _onMenuOpenChanged(bool open) {
    final next = open ? _menuOpenCount + 1 : _menuOpenCount - 1;
    _menuOpenCount = next < 0 ? 0 : next;
    if (open) {
      _hideTimer?.cancel();
    } else if (_showControls) {
      _scheduleHide();
    }
  }

  /// PopupMenuButton 的开合接线（打开暂停自动隐藏，关闭恢复）。
  void _onPopupOpened() => _onMenuOpenChanged(true);
  void _onPopupClosed() => _onMenuOpenChanged(false);

  void _toggleControls() {
    // PiP 期间控制栏恒定收起，点击不得把它唤回来。
    if (_inPip) return;
    final willShow = !_showControls;
    setState(() => _showControls = willShow);
    if (willShow) {
      // 控制栏可见：指针必须可见（控件要能点），指针隐藏计时作废。
      _pointerHideTimer?.cancel();
      if (!_pointerVisible) setState(() => _pointerVisible = true);
      _scheduleHide();
    } else {
      // 控制栏收起：指针按「鼠标是否在动」决定可见性（静止则隐藏）。
      _schedulePointerHide();
    }
  }

  /// 桌面（11-19 用户要求）：控制栏隐藏后鼠标移动**不**恢复控制栏 ——
  /// 只有单击视频才切换控制栏显隐。鼠标移动只负责让**指针**重新可见。
  ///
  /// 指针可见性独立于 `_showControls`：控制栏隐藏时指针仍可因移动而出现，
  /// 静止几秒后再次隐藏（[_schedulePointerHide]）。
  ///
  /// 注：11-18 的 A10 曾是「onHover 恢复控制栏」，与本需求冲突，已按
  /// 用户新需求改写（对应 spec：card-menu-and-episode-segment-contract）。
  void _bumpPointer() {
    if (!mounted) return;
    if (!_pointerVisible) {
      setState(() => _pointerVisible = true);
    }
    _schedulePointerHide();
  }

  /// 指针静止后隐藏：控制栏可见时指针跟随控制栏（不单独隐藏），
  /// 控制栏隐藏时才由本计时器收走指针。
  void _schedulePointerHide() {
    _pointerHideTimer?.cancel();
    _pointerHideTimer = Timer(const Duration(seconds: 3), () {
      if (!mounted) return;
      if (_showControls) return;
      setState(() => _pointerVisible = false);
    });
  }

  /// 画面手势层外层的桌面指针层（11-19）：控制栏隐藏时画面区指针不可见；
  /// 鼠标移动经 [onHover] 只恢复**指针**（[_bumpPointer]），不再呼出控制栏。
  /// `opaque: false` 且不发手势 —— 空白处点击仍由内层 Listener 的
  /// `_onSurfaceTap` 独家处理（player-overlay-hit-contract：任何铺满
  /// 全屏又吸收命中的节点都会吃掉下层点击）。移动/TV 无鼠标，原样返回。
  Widget _wrapDesktopPointer(Widget surface) {
    if (!_isDesktop) return surface;
    return MouseRegion(
      opaque: false,
      cursor: _pointerVisible ? MouseCursor.defer : SystemMouseCursors.none,
      onHover: (_) => _bumpPointer(),
      child: surface,
    );
  }

  /// 空白处单击 / 双击判定（按钮之外的所有区域）。
  ///
  /// 按下记时刻、抬手消费（见 [SurfaceTapArbiter]）：单击**立即**切控制栏；
  /// 双击（第二下落在窗口内）先撤销第一次的显隐，再执行双击动作 ——
  /// 桌面切全屏、移动切播放/暂停。
  final SurfaceTapArbiter _surfaceTapArbiter = SurfaceTapArbiter();

  void _onSurfacePointerDown(PointerDownEvent _) {
    // PiP 里画面点击由系统小窗接管（单击展开、拖动挪窗），本页手势全短路。
    if (_inPip) return;
    _surfaceTapArbiter.onDown(DateTime.now());
  }

  void _onSurfaceTap() {
    if (_inPip) return;
    if (_surfaceTapArbiter.consumeIsDoubleTap(DateTime.now())) {
      _toggleControls(); // 撤销第一次单击的显隐
      ErrorLog.instance.record('手势', _isDesktop ? '双击 → 切全屏' : '双击 → 播放/暂停');
      if (_isDesktop) {
        unawaited(_toggleFullscreen());
      } else {
        _togglePlayPause();
      }
      return;
    }
    _toggleControls();
  }

  /// 遥控器长按左右键的连发：每 400ms 跳 10 秒，松手停止。
  void _startSeekRepeat(int sign) {
    _stopSeekRepeat();
    _seekAccum = Duration.zero;
    _seekStep(sign);
    _seekRepeat = Timer.periodic(
      const Duration(milliseconds: 400),
      (_) => _seekStep(sign),
    );
  }

  void _seekStep(int sign) {
    final delta = Duration(seconds: 10 * sign);
    _seekAccum += delta;
    unawaited(_seekBy(delta));
    final back = sign < 0;
    _showOsd(
      back ? AppIcons.fastRewind : AppIcons.fastForward,
      '${back ? '快退' : '快进'} ${_seekAccum.inSeconds.abs()} 秒',
    );
  }

  void _stopSeekRepeat() {
    _seekRepeat?.cancel();
    _seekRepeat = null;
  }

  /// 静音 / 恢复。恢复时回到静音前的音量，而不是硬拉 100。
  ///
  /// 本地状态先改再调引擎：引擎的 volume 事件是异步推的，等它回来再刷滑块会
  /// 有一帧滞后（拖动时尤其明显）。
  void _toggleMute() {
    if (_volume > 0) {
      _lastVolume = _volume;
      setState(() => _volume = 0);
      unawaited(_engine.setVolume(0));
      _showOsd(AppIcons.volumeOff, '已静音');
    } else {
      final v = _lastVolume > 0 ? _lastVolume : 100.0;
      setState(() => _volume = v);
      unawaited(_engine.setVolume(v));
      _showOsd(AppIcons.volume, '取消静音');
    }
  }

  /// 双击暂停/继续，并给出 OSD 反馈。
  ///
  /// 读 `state.playing` 要在 `playOrPause` 之前：之后读到的已经是新状态，
  /// 提示会反着说。
  void _togglePlayPause() {
    final wasPlaying = _engine.state.playing;
    unawaited(_engine.playOrPause());
    _showOsd(
      wasPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
      wasPlaying ? '已暂停' : '继续播放',
    );
  }

  void _onHorizontalDragStart(DragStartDetails d) {
    // PiP 里的拖动是系统「挪窗」，本页不得同时进入快进预览。
    if (_inPip) return;
    _dragStartPos = d.localPosition.dx;
    _seekPreviewMs = _position.inMilliseconds.toDouble();
  }

  void _onHorizontalDragUpdate(DragUpdateDetails d) {
    if (_inPip) return;
    if (_seekPreviewMs == null || _duration == Duration.zero) return;
    final delta = d.localPosition.dx - (_dragStartPos ?? 0);
    final ms = (_seekPreviewMs ?? 0) + delta * 300;
    setState(() {
      _overlayValue = ms.clamp(0.0, _duration.inMilliseconds.toDouble()).toDouble();
    });
  }

  void _onHorizontalDragEnd(DragEndDetails d) async {
    if (_inPip) return;
    final target = _overlayValue;
    if (target != null) {
      await _seekTo(Duration(milliseconds: target.floor()));
    }
    setState(() {
      _seekPreviewMs = null;
      _overlayValue = null;
    });
    _dragStartPos = null;
  }

  /// 移动端全屏竖直滑动：上滑下一集、下滑上一集。
  ///
  /// 原先左右半屏分别是亮度 / 音量（用户口径已下线）。只在松手时结算一次，
  /// 拖动过程中不切集；位移不足 [_verticalSwipeThreshold] 当作误触忽略。
  void _onVerticalDragEnd(DragEndDetails _) {
    if (_inPip) return;
    final double dy = _verticalDragDy;
    _verticalDragDy = 0;
    if (dy <= -_verticalSwipeThreshold) {
      _goNext(manual: true);
    } else if (dy >= _verticalSwipeThreshold) {
      _goPrev(manual: true);
    }
  }

  // ---------- 长按倍速（移动端手势，11-17） ----------

  /// 按住画面：立刻 2 倍速，并提示下一步手势。
  ///
  /// 只调 [PlayerEngine.setRate]，不走 [_applySpeed]——后者会按剧记忆倍速，
  /// 长按是临时状态，松手就恢复。
  void _beginHoldSpeed() {
    if (_inPip) return;
    final HoldSpeedState next = _holdSpeed.begin(_speed);
    setState(() => _holdSpeed = next);
    ErrorLog.instance.record(
        '播放', '长按倍速：按下（基准 ${_trimSpeed(next.baseRate)}x）');
    unawaited(_engine.setRate(HoldSpeedState.doubleRate));
    _showOsd(
      Icons.speed_rounded,
      next.phase == HoldSpeedPhase.locked
          ? '已锁定 2 倍速 · 长按上滑取消'
          : '2 倍速播放中 · 下滑锁定',
    );
  }

  /// 按住期间累计纵向位移：下滑布防锁定，锁定后上滑布防解锁。
  void _updateHoldSpeed(double dy) {
    if (!_holdSpeed.active) return;
    final HoldSpeedState next = _holdSpeed.drag(dy);
    if (next.armed == _holdSpeed.armed) return;
    setState(() => _holdSpeed = next);
    _showOsd(
      Icons.speed_rounded,
      next.phase == HoldSpeedPhase.held ? '松手锁定 2 倍速' : '松手恢复正常速度',
    );
  }

  /// 松手结算：锁定继续 2x，否则恢复长按前的用户倍速。
  void _endHoldSpeed() {
    if (!_holdSpeed.active) return;
    final HoldSpeedState next = _holdSpeed.release();
    setState(() => _holdSpeed = next);
    ErrorLog.instance.record(
      '播放',
      next.phase == HoldSpeedPhase.locked
          ? '长按倍速：锁定 2x'
          : '长按倍速：松开 → ${_trimSpeed(next.rate)}x',
    );
    unawaited(_engine.setRate(next.rate));
    _showOsd(
      Icons.speed_rounded,
      next.phase == HoldSpeedPhase.locked
          ? '已锁定 2 倍速 · 长按上滑取消'
          : '已恢复 ${_trimSpeed(next.rate)}x 播放',
    );
  }

  /// 打断长按流程（换集 / 打开面板 / 退出）：直接把引擎拉回用户倍速。
  void _cancelHoldSpeed() {
    if (!_holdSpeed.active) return;
    final double base = _holdSpeed.baseRate;
    _holdSpeed = const HoldSpeedState();
    ErrorLog.instance.record('播放', '长按倍速：打断 → ${_trimSpeed(base)}x');
    unawaited(_engine.setRate(base));
    if (mounted) setState(() {});
  }

  // ---------- 首启指南 ----------

  /// 第一次成功开播后弹一次播放器指南。
  ///
  /// 参考 `kaixinguo/view_tutorial.go`：说明期间先暂停视频（`setHold(true)`），
  /// 关掉再恢复播放——用户读说明时剧情不该在背后跑掉。标记在弹之前就落盘，
  /// 这样中途被杀进程也不会第二天再弹一次。
  Future<void> _maybeShowPlayerGuide() async {
    if (_disposed || !mounted || _guideShown) return;
    _guideShown = true;
    final settings = AppScope.read(context).settings;
    if (settings.playerGuideSeen) return;
    settings.playerGuideSeen = true;
    await _engine.pause();
    if (_disposed || !mounted) return;
    await showPlayerGuide(context);
    if (_disposed || !mounted) return;
    unawaited(_engine.play());
  }

  /// 长按倍速状态徽标：按住/锁定时常驻，松手且未锁定时消失。
  Widget _buildHoldSpeedBadge(BuildContext context) {
    final bool locked = _holdSpeed.phase == HoldSpeedPhase.locked;
    return Positioned(
      top: 16,
      left: 0,
      right: 0,
      child: IgnorePointer(
        child: Center(
          child: Container(
            padding: const EdgeInsets.fromLTRB(14, 7, 14, 7),
            decoration: BoxDecoration(
              color: PlayerOverlayTokens.pillFill,
              borderRadius: BorderRadius.all(
                Radius.circular(PlayerOverlayTokens.radiusPill),
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  locked ? Icons.lock_rounded : Icons.fast_forward_rounded,
                  color: PlayerOverlayTokens.textPrimary,
                  size: 16,
                ),
                AppGap.h(AppGapSize.s8),
                Text(
                  locked ? '已锁定 2 倍速 · 长按上滑取消' : '2 倍速播放中',
                  style: PlayerOverlayTokens.stylePrimaryLabel,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ---------- 投屏（DLNA 发送端） ----------

  /// 断开投屏回本地。[resumeLocal] 由调用方在 await 之前捕获（M4-1：
  /// 本方法在 `disconnect()` 等多个 await 之后执行，不再摸 context）。
  void _resumeLocalAfterCast(Duration position, {required bool resumeLocal}) {
    if (!resumeLocal) return;
    if (position > Duration.zero) {
      unawaited(_seekTo(position));
    }
    _engine.play();
    if (mounted) setState(() {});
  }

  Future<void> _openCastSheet() async {
    final playback = _playback;
    if (playback == null) {
      _showToast('播放地址未就绪');
      return;
    }
    final stream = _currentVideoStream ?? _currentStream(playback.playback);
    if (stream.url.isEmpty) {
      _showToast('没有可投屏的视频流');
      return;
    }
    var castUrl = stream.url;
    // M4-1（安卓低风险确定项）：发起投屏前先暂停本地解码——中继（ffmpeg）
    // 起解时 libmpv 不再同时解码同一路流，避免双解码叠加内存峰值。原实现是
    // 投屏成功（面板 'started'）后才 pause，双解码窗口横跨整个中继启动期。
    // 用户取消投屏时在 sheet 返回后恢复播放。
    _engine.pause();
    // 中继起不来（典型：系统没有可执行的 ffmpeg）时不再把整条投屏路堵死：
    // 用户可选「直投原 URL」（M1-6 / AC-21）。镜像入口 11-10 起隐藏
    // （kCastMirrorEntryEnabled），此处的 needsMirror 恒 false。
    var needsMirror = false;
    // 加密分集中继成功时产物带 viaRelay（M5-0）：兼容模式选路对中继产物
    // 恒直投，不会把已解密的 HLS 再送进转码。
    var viaRelay = false;
    // 11-10（P0 真机）：正在投屏且中继服务的就是这一集 → 复用，不再起新中继。
    final wasCasting = castController.isCasting;
    final reuseRelay = _relaySession != null &&
        _relaySourceUrl.isNotEmpty &&
        _relaySourceUrl == stream.url &&
        _relayProductUrl.isNotEmpty;
    // 本次打开若要换会话，旧会话先留着（电视还在拉），投送成功后再回收。
    String? staleSession;
    // 本次打开是否真的新起了中继（取消时只有这种情况才回收）。
    var relayStartedHere = false;
    if (playback.contentKey != null) {
      if (reuseRelay) {
        castUrl = _relayProductUrl;
        viaRelay = true;
        CastDiagnostics.instance
            .recordTimeline('打开投屏面板：复用中继会话（不重复起 ffmpeg）');
      } else {
        relayStartedHere = true;
        // M3：加密分集走本机中继（ffmpeg 解密转 HLS）。
        // scope 在 await 前捕获：不摸 await 之后的 context（M4-1 约定）。
        final api = AppScope.read(context).api;
        // R2：画质三档随设置透传（Go 侧空/未知值缺省回 balanced）。
        final relayQuality = AppScope.read(context).settings.castRelayQuality;
        final previousSession = _relaySession;
        try {
          final relay = await api.castRelayStart(
            url: stream.url,
            backupUrl: stream.backupUrl,
            decKey: playback.contentKey!.key,
            audioUrl: playback.playback.audioUrl,
            quality: relayQuality,
            // 11-09 二期：预起中继也要带目标 host（用最近一次投屏设备），
            // 多网卡下产物 URL 才不会落回 127.0.0.1。
            hostHint: castController.lastTargetHost,
          );
          _relaySession = relay['session'] as String?;
          _relayApi = api;
          _relaySourceUrl = stream.url;
          final relayUrl = relay['url'] as String? ?? '';
          _relayProductUrl = relayUrl;
          if (previousSession != null && previousSession != _relaySession) {
            // 旧会话仍在为电视服务：等本次投送成功再停（否则电视立刻断流）。
            staleSession = previousSession;
          }
          // M0-5：跟随中继取流日志进诊断（探针在会话回收时自停）。
          final relaySession = _relaySession;
          if (relaySession != null) {
            CastRelayProbe.instance.watch(api.castRelayStatus, relaySession);
          }
          if (relayUrl.isNotEmpty) {
            castUrl = relayUrl;
            viaRelay = true;
          }
          _showToast('已启动本机解密中继');
        } on AquaException catch (e) {
          ErrorLog.instance.record('投屏', '中继启动失败：${e.friendlyText}',
              StackTrace.current);
          // 真因进诊断时间线（11-08）：面板诊断报告据此区分「目录/端口」与
          // 「ffmpeg 早退」等失败面，不再只看到固定文案。
          CastDiagnostics.instance
              .recordTimeline('中继启动失败：${e.friendlyText}');
          if (mounted) {
            await _chooseRelayFallback(
              e.friendlyText,
              detail: e.message,
              onChoose: (mirror) {
                needsMirror = mirror;
              },
            );
          }
        } catch (e) {
          ErrorLog.instance.record('投屏', '中继启动失败：$e', StackTrace.current);
          CastDiagnostics.instance.recordTimeline('中继启动失败：$e');
          if (mounted) {
            await _chooseRelayFallback(
              '加密中继启动失败',
              detail: '$e',
              onChoose: (mirror) {
                needsMirror = mirror;
              },
            );
          }
        }
      }
    }
    if (!mounted) {
      unawaited(_stopRelayIfAny());
      return;
    }
    final ep = widget.episodes[_index];
    final media = CastMedia(
      url: castUrl,
      title:
          '${widget.series.title} · ${ep.title.isEmpty ? '第${ep.number}集' : ep.title}',
      // 剧封面投 DIDL albumArtURI（电视端显示海报）；缺失空串即不出该标签。
      coverUrl: widget.series.coverUrl,
      position: _position,
      episodeIndex: _index + 1,
      episodeCount: widget.episodes.length,
      // 播放器手里有真实时长才传（AC-27）；未知/直播不写 DIDL duration。
      // 11-11 真机「接收端显示 00:00」：本地已解码的时长必须随 DIDL
      // `<res duration>` 投出去——多数接收端据此显示总时长；而连播/恢复
      // 路径原先完全没带 duration，接收端只能显示 00:00。
      duration: _duration > Duration.zero ? _duration : null,
      // M5-0：加密分集已由本机中继产出 HLS → 选路恒直投；编码提示供
      // auto 选路把 HEVC/AV1 分集路由到本机转码。
      viaRelay: viaRelay,
      // 诊断按中继会话隔离（11-09 二期）：非空时只接受本会话的快照/地址。
      relaySession: viaRelay ? (_relaySession ?? '') : '',
      // 档位降级回源用（11-09 二期）：中继产物随会话回收即死链，降级重投
      // 必须回到源地址重新选路（极光TV：PLAYING 但零取流 → 自动转 TS）。
      recordUrl: viaRelay ? stream.url : null,
      codecHint: stream.codec,
      // 恢复重新解析的定位键（11-08-resume-reparse）：随会话恢复记录持久化，
      // 面板一键恢复按它重新解析分集拿新鲜 URL。
      sourceId: widget.series.id,
      // M5-2 字幕接线点：红果源目前不提供外挂字幕 URL，源无字幕就不传
      // （DIDL 不写字幕标签、不制造噪声）；源补齐外挂字幕数据后在此
      // 传入 CastMedia.subtitleUrl 即全链路生效。
    );
    // 连播：电视端播完自动解析并投下一集（本地缓存集投本地文件；加密分集
    // 停旧中继、起新中继）。scope 在发起时捕获，避免异步后摸 context。
    final castScope = AppScope.read(context);
    final castIndex = _index;
    // M5-0：兼容模式选路的本机转码执行体（Go castRelayStart 适配器）。
    // 中继会话沿用 _relaySession 生命周期（停旧 → 起新 → 断开/收尾回收）。
    // R2/R3：选路决定的输出档位（hls/ts）与已登记的会话字幕一起透传。
    castController.transcodeResolver = (m,
        {relayFormat, relaySubtitleUrl, relayHostHint = ''}) async {
      final oldSession = _relaySession;
      _relaySession = null;
      if (oldSession != null) {
        try {
          await castScope.api.castRelayStop(oldSession);
        } catch (_) {}
      }
      final relay = await castScope.api.castRelayStart(
        url: m.url,
        userAgent: headerOf(m.headers, 'user-agent') ?? '',
        referer: headerOf(m.headers, 'referer') ?? '',
        format: relayFormat ?? '',
        subtitleUrl: relaySubtitleUrl?.toString() ?? '',
        quality: castScope.settings.castRelayQuality,
        // 11-09：按目标设备路由源 IP 生成产物 URL（否则多网卡下是 127.0.0.1）；
        // 编码提示让 ts 档对 HEVC/AV1 源重编码（多数电视不认 HEVC over TS）。
        hostHint: relayHostHint,
        codecHint: m.codecHint,
      );
      _relaySession = relay['session'] as String?;
      _relayApi = castScope.api;
      // 11-10：记录会话服务的源与产物，供下次打开面板判断能否复用。
      _relaySourceUrl = m.url;
      _relayProductUrl = relay['url'] as String? ?? '';
      // M0-5：跟随中继取流日志进诊断（探针在会话回收时自停）。
      final relaySession = _relaySession;
      if (relaySession != null) {
        CastRelayProbe.instance.watch(castScope.api.castRelayStatus, relaySession);
      }
      return relay['url'] as String?;
    };
    // 中继完成度快照（11-09 连播修复）：本集是否播完不依赖电视上报的
    // TrackDuration（实时 event HLS 多数报 0），改读产物进度。
    castController.relaySnapshotReader = () => CastRelayProbe.instance.snapshot;
    // 解析第 n 集的投屏媒体（连播下一集与手动跳集共用）：本地缓存集投本地
    // 文件；加密分集停旧中继、起新中继。越界返回 null（连播归一为远端停止，
    // 手动跳集由控制器保持会话）。
    Future<CastMedia?> resolveCastEpisode(int n) async {
      if (n < 0 || n >= widget.episodes.length) return null;
      final nep = widget.episodes[n];
      final local = castScope.downloads.localEntryOf(nep.id);
      if (local != null) {
        return CastMedia(
          url: '',
          localPath: local.filePath,
          title: '${widget.series.title} · ${nep.title.isEmpty ? '第${nep.number}集' : nep.title}',
          coverUrl: widget.series.coverUrl,
          episodeIndex: nep.number,
          episodeCount: widget.episodes.length,
          // 恢复重新解析定位键（11-08-resume-reparse）；本地文件会话本身
          // 不写恢复记录，此处仅保持字段口径一致。
          sourceId: widget.series.id,
        );
      }
      final cached = _prefetched.remove(n);
      final pb = cached != null && prefetchUsable(cached, DateTime.now())
          ? cached
          : await castScope.api.resolvePlayback(nep.id);
      if (pb.playback.streams.isEmpty) {
        // 连播终止可观测（UI 冒烟发现 143/144 静默未达接收端）：解析空流
        // 是候选根因之一，记时间线与日志供诊断报告定位。
        CastDiagnostics.instance.recordTimeline('连播终止：第${nep.number}集解析无可用流');
        ErrorLog.instance.record('投屏', '连播解析无可用流：第${nep.number}集（${nep.id}）', null);
        return null;
      }
      final stream = _selectStream(pb.playback, _quality);
      var nextUrl = stream.url;
      var nextViaRelay = false;
      if (pb.contentKey != null) {
        // 换集：停旧中继 → 起新中继（会话随 provider 闭包管理）。
        final oldSession = _relaySession;
        _relaySession = null;
        if (oldSession != null) {
          try {
            await castScope.api.castRelayStop(oldSession);
          } catch (_) {}
        }
        try {
          final relay = await castScope.api.castRelayStart(
            url: stream.url,
            backupUrl: stream.backupUrl,
            decKey: pb.contentKey!.key,
            audioUrl: pb.playback.audioUrl,
            quality: castScope.settings.castRelayQuality,
            // 11-09 二期：连播换集同样带目标 host，避免产物 URL 落回环。
            hostHint: castController.lastTargetHost,
          );
          _relaySession = relay['session'] as String?;
          _relayApi = castScope.api;
          _relaySourceUrl = stream.url;
          _relayProductUrl = relay['url'] as String? ?? '';
          // M0-5：连播换集中继也跟随取流日志。
          final relaySession = _relaySession;
          if (relaySession != null) {
            CastRelayProbe.instance
                .watch(castScope.api.castRelayStatus, relaySession);
          }
          nextUrl = relay['url'] as String? ?? stream.url;
          nextViaRelay = true;
        } catch (e) {
          // 中继起不来：本轮连播终止，走远端停止路径——原因入时间线与日志
          //（UI 冒烟发现连播部分集数静默未达接收端，此处原为静默 null）。
          CastDiagnostics.instance
              .recordTimeline('连播终止：第${nep.number}集中继启动失败');
          ErrorLog.instance
              .record('投屏', '连播中继启动失败：第${nep.number}集：$e', StackTrace.current);
          return null;
        }
      }
      return CastMedia(
        url: nextUrl,
        title: '${widget.series.title} · ${nep.title.isEmpty ? '第${nep.number}集' : nep.title}',
        coverUrl: widget.series.coverUrl,
        episodeIndex: nep.number,
        episodeCount: widget.episodes.length,
        // M5-0：连播加密分集的产物已是本机中继 HLS，选路恒直投。
        viaRelay: nextViaRelay,
        // 诊断按中继会话隔离（11-09 二期）。
        relaySession: nextViaRelay ? (_relaySession ?? '') : '',
        // 恢复记录存源地址（产物随会话回收即死链，见 CastMedia.recordUrl）。
        recordUrl: stream.url,
        // 编码提示与首投同口径：缺了它 HEVC/AV1 分集连播时 auto 选路无证据
        // → 直投 → 接收端解不动（UI 冒烟实证的连播风暴根因之一）。
        codecHint: stream.codec,
        // 恢复重新解析的定位键（11-08-resume-reparse）：连播换集也把记录
        // 跟到当前集，跨天恢复按它重新解析。
        sourceId: widget.series.id,
      );
    }
    // 连播/跳集基准 = 会话当前集（currentMedia.episodeIndex 为 1-based，
    // 下一集的 0-based 下标恰等于该值）；捕获的 castIndex 仅作会话无媒体时
    // 的回退——恢复投送后本地索引与会话集数错位，用捕获值会跳集（UI 冒烟
    // 实证：恢复第134集播完后 next 跳到第142集并重复投同一集）。
    int nextEpisodeBase() =>
        castController.currentMedia?.episodeIndex ?? castIndex + 1;
    castController.onNextEpisode = () => resolveCastEpisode(nextEpisodeBase());
    // 遥控器上一集/手动跳集（delta 语义；0 与越界返回 null）。
    castController.onEpisodeJump = (delta) async {
      if (delta == 0) return null;
      return resolveCastEpisode(nextEpisodeBase() - 1 + delta);
    };
    // 断开回本地时的行为设置：在 sheet 之前捕获（M4-1：await 之后不摸 context）。
    final resumeLocal =
        AppScope.read(context).settings.castDisconnectBehavior == 'resumeLocal';
    final result = await showCastSheet(
      context,
      media: media,
      onLocalPause: () => _engine.pause(),
      initialMirrorMode: needsMirror,
    );
    if (!mounted || result == null) {
      // 用户取消/只是看了一眼管理页（11-10 P0 真机）：**正在投屏时绝不能
      // 停中继**——旧实现无条件 `_stopRelayIfAny()`，把电视正在拉的分片源
      // 直接关掉，表现为「打开投屏管理页后原本能播的电视立刻停」。
      // 只有「本次新起了中继且打开前没在投屏」才回收，避免白占端口/CPU。
      if (relayStartedHere && !wasCasting) unawaited(_stopRelayIfAny());
      // 发起前暂停了本地解码（M4-1）：取消投屏即恢复本地播放。
      if (mounted) _engine.play();
      return;
    }
    if (result == 'started') {
      // 投送成功 → 旧会话已无人使用，回收（换集/换设备后的残留 ffmpeg）。
      unawaited(_stopRelaySession(staleSession));
      _showToast('已投屏，电视端播放中');
    } else if (result == 'disconnect') {
      final position = await castController.disconnect();
      await _stopRelayIfAny();
      _resumeLocalAfterCast(position, resumeLocal: resumeLocal);
    }
  }

  /// 回收中继会话（断开/远端停止/取消/退出各路径）。
  /// 不摸 context：调用点可能发生在 await 之后甚至页面已卸载（M4-1）。
  Future<void> _stopRelayIfAny() async {
    final session = _relaySession;
    _relaySession = null;
    _relaySourceUrl = '';
    _relayProductUrl = '';
    CastRelayProbe.instance.unwatch();
    final api = _relayApi;
    _relayApi = null;
    if (session == null || api == null) return;
    try {
      await api.castRelayStop(session);
    } catch (_) {}
  }

  /// 只回收指定会话（不动当前 `_relaySession`）：换集/换设备投送成功后清理
  /// 旧会话用（11-10：旧会话在投送成功前必须继续服务电视）。
  Future<void> _stopRelaySession(String? session) async {
    final api = _relayApi;
    if (session == null || session.isEmpty || api == null) return;
    try {
      await api.castRelayStop(session);
    } catch (_) {}
  }

  void _showToast(String text) {
    if (!mounted) return;
    if (context.mounted) {
      if (context.mounted) {
        ScaffoldMessenger.maybeOf(context)
          ?..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(content: Text(text)));
      }
    }
  }

  /// 中继失败后的选择（M1-6 / AC-21）：直投原 URL 或切换镜像屏幕。
  /// [onChoose] 收到 true = 切换镜像；false = 直投原 URL（默认项）。
  /// 原始异常已由调用方记入 ErrorLog 与诊断时间线；[detail] 是 Go 侧原始
  /// 原因（11-08：ffmpeg stderr 尾部已去 URL，可安全展示——不再让用户只
  /// 看到「中继启动失败，请重试」而无法反馈真因）。
  Future<void> _chooseRelayFallback(String reason,
      {String? detail, required void Function(bool mirror) onChoose}) async {
    final mirror = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('本机中继不可用'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 镜像入口隐藏（11-10，kCastMirrorEntryEnabled）：不再把用户引到
            // 一条实测投不出来的通路；置 true 时文案与「切换镜像」一起回来。
            Text(kCastMirrorEntryEnabled
                ? '$reason。\n\n可选择直接投送原始地址'
                    '（部分格式电视可能不支持），或改用镜像屏幕投屏。'
                : '$reason。\n\n可改为直接投送原始地址（部分格式电视可能不支持）。'),
            if (detail != null && detail.isNotEmpty) ...[
              AppGap.v(AppGapSize.s8),
              Text(
                detail.length > 200 ? '${detail.substring(0, 200)}…' : detail,
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: Theme.of(context).colorScheme.outline),
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ],
        ),
        actions: [
          if (kCastMirrorEntryEnabled)
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('切换镜像'),
            ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('直投原 URL'),
          ),
        ],
      ),
    );
    if (!mounted) return;
    if (kCastMirrorEntryEnabled && mirror == true) {
      onChoose(true);
      _showToast('已切换为镜像屏幕投屏');
    } else {
      onChoose(false);
      _showToast('已改为直投，部分格式电视可能不支持');
    }
  }

  @override
  Widget build(BuildContext context) {
    // 弹幕显示设置每帧现取：设置面板改完 setState 即可生效，不必重建监听。
    final settings = AppScope.read(context).settings;
    return Focus(
      autofocus: true,
      onKeyEvent: _onKeyEvent,
      child: PopScope(
        // 电视返回键：控制栏可见时先收起，再按才退出播放页。
        // 非电视形态 canPop 恒 true，旧行为完全不变。
        canPop: !_isTv || !_showControls,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop && mounted) setState(() => _showControls = false);
        },
        child: Scaffold(
        backgroundColor: PlayerOverlayTokens.videoBlack,
        body: Stack(
          fit: StackFit.expand,
          children: [
            _wrapDesktopPointer(
            Listener(
              // 双击判定必须拿「按下」时刻：抬手时比时间戳会把按压时长算进
              // 间隔，慢一点的连点就判不出来（见 [SurfaceTapArbiter]）。
              onPointerDown: _onSurfacePointerDown,
              onPointerSignal: (event) {
                if (event is PointerScrollEvent) {
                  // 桌面滚轮调音量：向下滚减小，向上滚增大。
                  final v = (_engine.state.volume +
                          (event.scrollDelta.dy > 0 ? -5 : 5))
                      .clamp(0.0, 100.0);
                  _engine.setVolume(v);
                  _showOsd(AppIcons.volume, '音量 ${v.round()}%');
                }
              },
              child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              // 单击/双击用时间戳自己判：`onDoubleTap` 会让识别器把指针
              // hold 到 kDoubleTapTimeout(300ms)，控件栏里每个按钮的单击都被
              // 拖慢；自定义判定后按钮即时响应、空白单击也即时收起控制栏。
              onTap: _onSurfaceTap,
              // 长按 = 2 倍速（11-17，对齐参考实现）：按住即 2x，松手恢复；
              // 按住时下滑锁定、锁定后按住上滑取消。原「长按左右 1/3 快退/
              // 快进 10s」让位——同一手势不能两用，进度拖动仍可快进快退。
              onLongPressStart: (_) => _beginHoldSpeed(),
              onLongPressMoveUpdate: (d) =>
                  _updateHoldSpeed(d.offsetFromOrigin.dy),
              onLongPressEnd: (_) => _endHoldSpeed(),
              onHorizontalDragStart: _onHorizontalDragStart,
              onHorizontalDragUpdate: _onHorizontalDragUpdate,
              onHorizontalDragEnd: _onHorizontalDragEnd,
              // 桌面不挂竖直拖动：长按 2 倍速与拖动在手势竞技场互斥——真人
              // 「按下、稳住、慢慢拖」必然先踩满 kLongPressTimeout(500ms)，
              // 长按赢下后拖动更新整段被吞（test/player_surface_gesture_test.dart
              // 实证）。移动端竖直滑动改为切集：上滑下一集、下滑上一集。
              onVerticalDragStart: _isDesktop ? null : (_) => _verticalDragDy = 0,
              onVerticalDragUpdate:
                  _isDesktop ? null : (d) => _verticalDragDy += d.delta.dy,
              onVerticalDragEnd: _isDesktop ? null : _onVerticalDragEnd,
              child: Stack(
                children: [
                  _buildVideo(context),
                  // 弹幕层：画面之上、控件之下。暂停时不隐藏（冻结在原位），
                  // 只停掉 30fps ticker —— 「随视频暂停」而不是「暂停即消失」。
                  if (_prepared && _danmakuOn && !_inPip)
                    Positioned.fill(
                      child: IgnorePointer(
                        child: DanmakuOverlay(
                          items: _danmaku,
                          position: _position,
                          animating: _playing,
                          // 位置只在播放器上报时更新（约 1 秒一次），弹幕层按
                          // Ticker 插值到每一帧；倍率参与插值，快进时弹幕同步加速。
                          // 用实际生效倍速：锁定 2x 时弹幕与画面同速（issue #2）。
                          rate: _effectiveRate,
                          // 显式 seek/换集才允许时间轴回退，其余位置回退按抖动处理。
                          resetEpoch: _danmakuEpoch,
                          blockWords: settings.biliDanmakuBlockWords,
                          rows: settings.danmakuRows,
                          areaFraction: settings.danmakuArea / 100,
                          scrollDuration:
                              Duration(milliseconds: settings.danmakuSpeedMs),
                          textSize: settings.danmakuFontSize.toDouble(),
                          opacity: settings.danmakuOpacity / 100,
                          stroke: settings.danmakuStroke,
                          mergeSame: settings.danmakuMergeSame,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            ),
            ),
            // PC 全屏：鼠标靠近右侧边缘自动呼出选集（离开自动收起）。
            if (_isDesktop && _fullscreen) _buildEdgeEpisodePanel(context),
            // PiP（`_inPip`）：小窗里只留画面，下列浮层全部不渲染——既省性能，
            // 也避免小窗里出现点不到的按钮（系统小窗的点击由系统接管）。
            if (_loadingStream && !_inPip) _buildPreparingOverlay(context),
            // 控制栏只画视觉、不吸收手势；错误面板压在它上面，保证
            // 「重置设备并重试 / 复制错误」这类按钮一定点得到。
            if (_showControls && !_inPip) _buildControls(context),
            if (_loadError != null && !_inPip) _buildLoadError(context),
            if (_playbackFailure != null && !_inPip)
              _buildPlaybackErrorPanel(context),
            if (_overlayValue != null && !_inPip)
              _buildGestureOverlay(context),
            // 长按倍速状态：只画不挡（IgnorePointer），不吃空白处点击。
            if (_holdSpeed.active && !_inPip) _buildHoldSpeedBadge(context),
            if (_osdText != null && !_inPip) _buildOsdOverlay(context),
            if (_mutedHintVisible && !_inPip) _buildMutedHint(context),
            if (_buffering &&
                _prepared &&
                !_loadingStream &&
                _playbackFailure == null &&
                !_inPip)
              _buildBufferingBadge(),
            // 投屏入口常驻：控件条 4 秒自动隐藏后，顶栏按钮会一起消失。
            // 电视自己就是播放端，投屏没有意义，直接不显示。
            if (!_showControls && !_isTv && !_inPip)
              Positioned(
                top: 10,
                right: 10,
                child: CastFabButton(onPressed: _openCastSheet),
              ),
          ],
        ),
        ),
      ),
    );
  }

  Widget _buildVideo(BuildContext context) {
    // 11-19：Video 一直挂载，不再等 `_prepared` 才建树。
    //
    // 原实现用 `_prepared` 把 Video 整个挡掉，等 `engine.open()` + `_seekResume()`
    // 跑完才挂 → 这段窗口里画面纯黑，用户感知为「进入视频卡 1~2 秒」。
    // media_kit 的 texture 提前挂载可与取流/解码并行就绪，这里改成
    // 「Video 常驻 + 未就绪时叠一层黑幕」，首帧出现即可见。
    //
    // 黑幕用 Stack 叠在 Video 之上（只画不挡命中），保持手势分层不变。
    return Stack(
      fit: StackFit.expand,
      children: [
        Video(
          controller: _engine.videoController,
          controls: NoVideoControls,
          fit: _fill ? BoxFit.cover : BoxFit.contain,
        ),
        if (!_prepared)
          const ColoredBox(color: PlayerOverlayTokens.videoBlack),
      ],
    );
  }

  /// 桌面「铺满」：进全屏（若尚未全屏）+ 画面 cover 裁剪填充；再点切回 contain。
  /// 全屏开关仍归「全屏(F)」按钮管，这里只负责画面填充方式。
  Future<void> _toggleFill() async {
    if (!_isDesktop) return;
    try {
      if (!await windowManager.isFullScreen()) {
        await _applyFullscreen(true);
      }
      if (mounted) setState(() => _fill = !_fill);
    } catch (e, stack) {
      ErrorLog.instance.record('全屏', e, stack);
    }
  }

  /// 重置匿名设备后立刻重新解析并播放当前集。
  ///
  /// 「当前设备已达到匿名访问上限 / 设备被拒绝 / 取流接口没给地址」都可能只是
  /// 这台匿名设备的问题：换一台新注册的设备最直接。放在播放页错误面板里，
  /// 用户不必退回「我的 → 设置 → 重置匿名设备」再重新进剧。
  Future<void> _resetDeviceAndReload() async {
    final api = AppScope.read(context).api;
    final ok = await resetAnonymousDevice(context, api.resetDevice);
    if (!ok || _disposed || !mounted) return;
    // 预解析缓存来自旧设备的一次取流，重置后一律重取，避免继续沿用旧结果。
    _prefetched.clear();
    await _openEpisode(_index, _retryStartAt, manual: true);
  }

  Widget _buildLoadError(BuildContext context) {
    final e = _loadError!;
    final text =
        e is AquaException ? e.friendlyText : '加载失败，请稍后再试';
    final detail =
        e is AquaException ? '${e.code}: ${e.message}' : '$e';
    // 只有「换台设备真能恢复」的错误才给重置入口。
    //
    // `PLAYBACK_UNAVAILABLE` 不属于这一类：它是取流接口返回空 body（服务端
    // 风控间歇下发），重置设备无效——用户实测连点两次「重置设备并重试」，
    // 两次都是同一句 anonymous response was empty。这类错误走「重试」+
    // 自动重试（见 `_schedulePlaybackAutoRetry`）。
    final canReset = deviceRecoverable(e);
    return Center(
      child: Container(
        constraints: const BoxConstraints(maxWidth: 460),
        margin: const EdgeInsets.symmetric(horizontal: 24),
        padding: const EdgeInsets.fromLTRB(AppSpacing.s20, AppSpacing.s20, AppSpacing.s20, AppSpacing.s20),
        decoration: BoxDecoration(
          color: PlayerOverlayTokens.scrimStrong,
          borderRadius: BorderRadius.all(Radius.circular(PlayerOverlayTokens.radiusPanel)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(AppIcons.errorOutline,
                color: PlayerOverlayTokens.textSecondary, size: 34),
            AppGap.v(AppGapSize.s8),
            Text(text,
                textAlign: TextAlign.center,
                style: PlayerOverlayTokens.stylePrimaryTitle),
            AppGap.v(AppGapSize.s8),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 90),
              child: SingleChildScrollView(
                child: SelectableText(detail,
                    style: PlayerOverlayTokens.styleTertiaryCaption),
              ),
            ),
            const SizedBox(height: 14),
            Wrap(
              spacing: 12,
              runSpacing: 8,
              alignment: WrapAlignment.center,
              children: [
                if (canReset)
                  FilledButton.icon(
                    onPressed: _resetDeviceAndReload,
                    icon: const Icon(Icons.autorenew_rounded, size: 18),
                    label: const Text('重置设备并重试'),
                  )
                else
                  OutlinedButton(
                    onPressed: () =>
                        _openEpisode(_index, _retryStartAt, manual: true),
                    child: const Text('重试',
                        style: PlayerOverlayTokens.stylePrimary),
                  ),
                OutlinedButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('返回',
                      style: PlayerOverlayTokens.stylePrimary),
                ),
                TextButton.icon(
                  onPressed: () async {
                    await Clipboard.setData(
                        ClipboardData(text: '$text\n$detail'));
                    if (mounted) _showToast('错误信息已复制');
                  },
                  icon: const Icon(AppIcons.copy,
                      size: 16, color: PlayerOverlayTokens.textTertiary),
                  label: const Text('复制错误',
                      style: PlayerOverlayTokens.styleTertiary),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// 起播准备层：封面 + 片名 + 集号立即显示；进度条延迟出现，
  /// 避免解析只用了 80ms 时闪一下。
  Widget _buildPreparingOverlay(BuildContext context) {
    final ep = widget.episodes[_index.clamp(0, widget.episodes.length - 1)];
    return Container(
      color: PlayerOverlayTokens.scrimStrong,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxHeight < 320;
          return Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (!compact) ...[
                    SizedBox(
                      width: 96,
                      height: 128,
                      child: ClipRRect(
                        borderRadius: BorderRadius.all(Radius.circular(PlayerOverlayTokens.radiusSm)),
                        child: CoverImage(url: widget.series.coverUrl),
                      ),
                    ),
                    const SizedBox(height: 14),
                  ],
                  Text(widget.series.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: PlayerOverlayTokens.stylePrimaryTitleStrong),
                  AppGap.v(AppGapSize.s4),
                  Text(
                    '第${ep.number}集${ep.title.isEmpty ? '' : ' · ${ep.title}'}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: PlayerOverlayTokens.styleTertiaryCaption,
                  ),
                  const SizedBox(height: 18),
                  const SizedBox(
                    width: 160,
                    child: _DelayedProgressBar(),
                  ),
                  AppGap.v(AppGapSize.s8),
                  const Text('正在解析播放地址…',
                      style: PlayerOverlayTokens.styleTertiaryCaption),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildPlaybackErrorPanel(BuildContext context) {
    final failure = _playbackFailure!;
    final ep = widget.episodes[_index.clamp(0, widget.episodes.length - 1)];
    return PlaybackErrorPanel(
      failure: failure,
      rawError: _rawPlaybackError,
      url: _currentVideoStream?.url,
      logs: _logBuffer.entries,
      seriesTitle: widget.series.title,
      episodeNumber: ep.number,
      episodeTitle: ep.title,
      quality: _selectedDefinition,
      onRetry: () => _openEpisode(
        _index,
        // 播过一段才失败的用当前位置；否则回到本集目标起点（断点），
        // 绝不静默归零——那会把用户的断点冲掉（安卓实测教训）。
        _position > const Duration(seconds: 10)
            ? _position
            : _retryStartAt,
        manual: true,
      ),
      onBack: () => Navigator.pop(context),
    );
  }

  /// 缓冲中提示：网络抖动时给明确反馈，避免用户以为卡死。
  Widget _buildBufferingBadge() {
    return Positioned(
      top: 78,
      left: 0,
      right: 0,
      child: Center(
        child: Container(
          padding: const EdgeInsets.fromLTRB(14, AppSpacing.s8, 14, AppSpacing.s8),
          decoration: BoxDecoration(
            color: PlayerOverlayTokens.scrimMedium,
            borderRadius: BorderRadius.all(Radius.circular(PlayerOverlayTokens.radiusBadge)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: const [
              AppLoading.inline(),
              AppGap.h(AppGapSize.s8),
              Text('缓冲中…',
                  style: PlayerOverlayTokens.stylePrimaryCaption),
            ],
          ),
        ),
      ),
    );
  }

  /// 静音起播提示胶囊：不占用 SnackBar，避免盖掉「已跳过片头 · 撤销」。
  Widget _buildMutedHint(BuildContext context) {
    return Positioned(
      right: 20,
      bottom: 100,
      child: Material(
        color: PlayerOverlayTokens.scrimStrong,
        borderRadius: BorderRadius.all(Radius.circular(PlayerOverlayTokens.radiusPill)),
        child: Padding(
          padding: const EdgeInsets.only(left: 14, right: 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(AppIcons.volumeOff,
                  color: PlayerOverlayTokens.textPrimary, size: 18),
              AppGap.h(AppGapSize.s8),
              const Text('当前静音',
                  style: PlayerOverlayTokens.stylePrimaryLabel),
              TextButton(
                onPressed: () {
                  _mutedHintTimer?.cancel();
                  setState(() => _mutedHintVisible = false);
                  _engine.setVolume(100);
                  _showOsd(AppIcons.volume, '音量 100%');
                },
                child: const Text('开启声音',
                    style: PlayerOverlayTokens.styleAccent),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildOsdOverlay(BuildContext context) {
    return IgnorePointer(
      child: Center(
        child: Container(
          padding: const EdgeInsets.fromLTRB(18, 11, 18, 11),
          decoration: BoxDecoration(
            color: PlayerOverlayTokens.pillFill,
            borderRadius: BorderRadius.all(Radius.circular(PlayerOverlayTokens.radiusPill)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_osdIcon != null) ...[
                // 电视 3 米外观看：图标与文字都要放大，否则等于没提示。
                Icon(_osdIcon, color: PlayerOverlayTokens.textPrimary, size: _isTv ? 28 : 20),
                SizedBox(width: _isTv ? 10 : 8),
              ],
              Text(_osdText ?? '',
                  style: _isTv
                      ? PlayerOverlayTokens.styleOsdValueTv
                      : PlayerOverlayTokens.styleOsdValue),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildGestureOverlay(BuildContext context) {
    final v = _overlayValue!;
    // 竖直滑动已改为切集，HUD 只剩横向拖动的进度预览。
    return JellyValueFeedback(
      text:
          '${_fmtDur(Duration(milliseconds: v.floor()))} / ${_fmtDur(_duration)}',
      icon: AppIcons.fastForward,
    );
  }

  /// 全屏（桌面）/ 横屏（移动/TV）时控制栏右端显示当前时间。
  bool get _showClock {
    if (_isTv) return true;
    if (_isDesktop) return _fullscreen;
    return MediaQuery.orientationOf(context) == Orientation.landscape;
  }

  Widget _buildControls(BuildContext context) {
    final ep = widget.episodes[_index];
    // 竖屏 360dp 级设备上，底栏固定子项合计约 394dp，会把最右侧「横屏/竖屏」
    // 按钮裁掉一半。窄屏把睡眠定时与倍速收进「更多」菜单（见 player_layout.dart）。
    final compactBar = useCompactPlayerBar(
      desktop: _isDesktop,
      width: MediaQuery.sizeOf(context).width,
    );
    // 只画视觉层：**不挂背景手势，也不吸收命中**。
    //
    // 在这里挂 opaque 的 `GestureDetector` 会盖住下层（错误面板的「重置/复制」
    // 按钮点不到）且与外层视频手势层抢同一次 tap（安卓上「点一下屏幕收不起
    // 控制栏」）；而 scrim 铺满全屏自己吸收命中同样致命——`Stack` 命中到
    // 控制栏就停，下层的 `_onSurfaceTap` 收不到点击，表现为「单击收不起、
    // 双击全屏 / 双击暂停全失效」（11-17 用户实测回归）。
    // 空白处的单击/双击统一交给外层视频层（`_onSurfaceTap`），按钮自己赢，
    // 见 [PlayerControlsSurface] 的命中契约。
    return PlayerControlsSurface(
      // 鼠标在控件上移动就重置 4s 隐藏计时：正在点按钮时控制栏不该自己消失。
      onHover: (_) {
        if (_showControls) _scheduleHide();
      },
      child: Column(
          children: [
            // 顶栏（③ 玻璃接线：玻璃前有全屏 scrimSoft，带内再叠本地 scrim）
            SafeArea(
              bottom: false,
              child: Padding(
                padding: EdgeInsets.fromLTRB(context.app.metrics.s8, 0, context.app.metrics.s8, 0),
                child: Row(
                    children: [
                  const BackButton(color: PlayerOverlayTokens.textPrimary),
                  Expanded(
                    // 单行省略是版式需要，但名字不能被吃掉：悬停/长按看完整。
                    child: Tooltip(
                      message:
                          '${widget.series.title} · ${ep.title.isEmpty ? '第${ep.number}集' : ep.title}',
                      waitDuration: const Duration(milliseconds: 400),
                      child: Text(
                        '${widget.series.title} · ${ep.title.isEmpty ? '第${ep.number}集' : ep.title}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: PlayerOverlayTokens.stylePrimaryTitle,
                      ),
                    ),
                  ),
                  ListenableBuilder(
                    listenable: castController,
                    // 电视自己就是播放端，顶栏也不给投屏入口（下载仍保留）。
                    builder: (context, _) => _isTv
                        ? const SizedBox.shrink()
                        : IconButton(
                            tooltip: '投屏',
                            icon: Icon(castController.isCasting
                                ? AppIcons.castConnected
                                : AppIcons.cast),
                            color: PlayerOverlayTokens.textPrimary,
                            onPressed: _openCastSheet,
                          ),
                  ),
                  if (_definitions.isNotEmpty)
                    // 清晰度菜单：TV 走 PopupMenuButton（焦点导航优先），
                    // 桌面/移动走 FxDockMenu（开慢关快 + 行交错，E2）。
                    _isTv
                        ? PopupMenuButton<String>(
                            initialValue: _selectedDefinition,
                            color: PlayerOverlayTokens.panelFill,
                            onOpened: _onPopupOpened,
                            onCanceled: _onPopupClosed,
                            onSelected: (v) {
                              _onPopupClosed();
                              _switchDefinition(v);
                            },
                            itemBuilder: (_) => [
                              for (final d in _definitions)
                                PopupMenuItem(
                                    value: d,
                                    child: Text(d,
                                        style:
                                            PlayerOverlayTokens.stylePrimary)),
                            ],
                            child: Padding(
                              // 竖向补到 ~40dp 触达高度：原来只有文本行高
                              // （~20dp），鼠标稍偏一点就点不中。
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 12, vertical: 10),
                              child: Text(_selectedDefinition ?? '清晰度',
                                  style: PlayerOverlayTokens.stylePrimary),
                            ),
                          )
                        : FxDockMenu<String>(
                            value: _selectedDefinition,
                            onSelected: _switchDefinition,
                            onOpenChanged: _onMenuOpenChanged,
                            items: [
                              for (final d in _definitions)
                                FxDockMenuItem(value: d, label: d),
                            ],
                            child: Padding(
                              // 竖向补到 ~40dp 触达高度：原来只有文本行高
                              // （~20dp），鼠标稍偏一点就点不中。
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 12, vertical: 10),
                              child: Text(_selectedDefinition ?? '清晰度',
                                  style: PlayerOverlayTokens.stylePrimary),
                            ),
                          ),
                  ],
                ),
              ),
            ),
            ListenableBuilder(
              listenable: castController,
              builder: (context, _) {
                final device = castController.currentDevice;
                if (!castController.isCasting || device == null) {
                  return const SizedBox.shrink();
                }
                return CastStatusBar(
                  deviceName: device.name,
                  onOpenSession: _openCastSheet,
                );
              },
            ),
            const Spacer(),
            // 底栏
            SafeArea(
              top: false,
              child: Padding(
                padding: EdgeInsets.fromLTRB(context.app.metrics.s8, 0, context.app.metrics.s8, 0),
                child: Column(
                    children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Row(
                      children: [
                        Text(_fmtDur(_position),
                            style: PlayerOverlayTokens.stylePrimaryCaption),
                        Expanded(
                          child: SliderTheme(
                            data: SliderTheme.of(context).copyWith(
                              trackHeight: 3,
                              thumbShape: JellyProgressThumb(
                                  color: context.app.colors.brand),
                            ),
                            child: Slider(
                              value: _duration == Duration.zero
                                  ? 0
                                  : _position.inMilliseconds
                                      .clamp(0, _duration.inMilliseconds)
                                      .toDouble(),
                              max: _duration.inMilliseconds
                                  .toDouble()
                                  .clamp(1, double.infinity),
                              onChanged: (v) => unawaited(
                                  _seekTo(Duration(milliseconds: v.floor()))),
                              // 拖动期间暂停慢缓冲判定，抬手后重新起算宽限。
                              onChangeStart: (_) =>
                                  _bufferMonitor.beginSeekInteraction(),
                              onChangeEnd: (_) =>
                                  _bufferMonitor.endSeekInteraction(),
                            ),
                          ),
                        ),
                        Text(_fmtDur(_duration),
                            style: PlayerOverlayTokens.stylePrimaryCaption),
                      ],
                    ),
                  ),
                  _playerBar(
                    // 窄窗也走横向滚动（桌面窗口可以拉得很窄），否则右侧
                    // 按钮会溢出到不可点区域。
                    scrollable: useScrollablePlayerBar(
                        MediaQuery.sizeOf(context).width),
                    child: Row(
                    children: [
                      IconButton(
                        onPressed: () => _goPrev(manual: true),
                        icon: const Icon(AppIcons.prev,
                            color: PlayerOverlayTokens.textPrimary),
                      ),
                      IconButton(
                        onPressed: () => _engine.playOrPause(),
                        icon: StreamBuilder<bool>(
                          stream: _engine.stream.playing,
                          // initialData 必须读引擎真实状态（11-08 用户真机反馈）：
                          // media_kit 的 stream.playing 是普通 broadcast 流——
                          // 订阅时不回放当前值；而控制栏随 _showControls 条件
                          // 整棵移出树（2787 行），重新显示即全新 StreamBuilder。
                          // 写死 true 时「隐藏期间被双击暂停 → 再呼出控制栏」
                          // 图标必然停在播放态，直到下一次 playing 事件才纠正。
                          initialData: _engine.state.playing,
                          builder: (context, snap) => DecoratedBox(
                            // brandGlowStrong（§4.6 唯三光晕之一）：外发光
                            // 只给主操作按钮。
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              boxShadow: <BoxShadow>[
                                context.app.metrics.brandGlowStrong
                                    .shadow(context.app.colors.brand),
                              ],
                            ),
                            child: Icon(
                              snap.data == true
                                  ? Icons.pause_circle_filled
                                  : AppIcons.play,
                              color: PlayerOverlayTokens.textPrimary,
                              size: 36,
                            ),
                          ),
                        ),
                      ),
                      IconButton(
                        onPressed: () => _goNext(manual: true),
                        // 下一集：桌面 hover 重画箭头（擦除→重画，E2）；
                        // 移动/TV/reduceMotion 原样透传静态 Icon。
                        icon: FxRedrawnArrow(
                          color: PlayerOverlayTokens.textPrimary,
                          icon: const Icon(
                            AppIcons.next,
                            color: PlayerOverlayTokens.textPrimary,
                          ),
                        ),
                      ),
                      // 选集：长剧不用退回详情页翻找。
                      IconButton(
                        tooltip: _isDesktop ? '选集 (E)' : '选集',
                        onPressed: _openEpisodePicker,
                        icon: const Icon(Icons.format_list_numbered,
                            color: PlayerOverlayTokens.textPrimary),
                      ),
                      // 弹幕开关（窄屏收进「更多」）。
                      if (!compactBar)
                        IconButton(
                          tooltip: '弹幕',
                          onPressed: _toggleDanmaku,
                          icon: Icon(AppIcons.danmaku,
                              color: _danmakuOn
                                  ? context.app.colors.brand
                                  : PlayerOverlayTokens.textPrimary),
                        ),
                      // 横向滚动时不能有 Spacer（无限宽约束下会撑爆布局）。
                      if (useScrollablePlayerBar(
                          MediaQuery.sizeOf(context).width))
                        AppGap.h(AppGapSize.s8)
                      else
                        const Spacer(),
                      // 音量：桌面端专用。窗口太窄时隐藏（见 player_volume.dart）。
                      if (showVolumeBar(
                        desktop: _isDesktop,
                        width: MediaQuery.sizeOf(context).width,
                      )) ...[
                        IconButton(
                          tooltip: _volume > 0 ? '静音 (M)' : '取消静音 (M)',
                          onPressed: _toggleMute,
                          icon: Icon(volumeIconFor(_volume),
                              color: PlayerOverlayTokens.textPrimary),
                        ),
                        SizedBox(
                          width: 100,
                          child: SliderTheme(
                            data: SliderTheme.of(context).copyWith(
                              trackHeight: 3,
                              thumbShape: const RoundSliderThumbShape(
                                  enabledThumbRadius: 6),
                              overlayShape: SliderComponentShape.noOverlay,
                            ),
                            child: Slider(
                              value: _volume.clamp(0.0, 100.0),
                              max: 100,
                              onChanged: (v) {
                                // 本地先更新：只等引擎回调的话滑块跟不上手指。
                                setState(() => _volume = v);
                                unawaited(_engine.setVolume(v));
                              },
                              onChangeEnd: (v) => _showOsd(
                                volumeIconFor(v),
                                v <= 0 ? '已静音' : '音量 ${v.round()}%',
                              ),
                            ),
                          ),
                        ),
                      ],
                      // 更多：片头片尾 / 音轨字幕 / 播放信息 / 快捷键。
                      // 收进一个菜单，避免窄屏底栏溢出。
                      PopupMenuButton<String>(
                        tooltip: '更多',
                        color: PlayerOverlayTokens.panelFill,
                        icon: const Icon(Icons.more_horiz, color: PlayerOverlayTokens.textPrimary),
                        // 菜单开着时不许自动隐藏：控制栏一卸载菜单就没了。
                        onOpened: _onPopupOpened,
                        onCanceled: _onPopupClosed,
                        onSelected: (value) {
                          _onPopupClosed();
                          switch (value) {
                            case 'skip':
                              _openSkipSettings();
                              break;
                            case 'danmaku':
                              _toggleDanmaku();
                              break;
                            case 'danmaku_block':
                              unawaited(showDanmakuBlockDialog(context));
                              break;
                            case 'danmaku_settings':
                              unawaited(_openDanmakuSettings());
                              break;
                            case 'tracks':
                              showPlayerTracksSheet(context, _engine,
                                initialSubtitleDelay: _subDelay,
                                onAudioTrackSelected: (idx, key) async {
                                  setState(() {
                                    _prefAudioIndex = idx;
                                    _prefAudioKey =
                                        key.isEmpty ? null : key;
                                  });
                                  try {
                                    await AppScope.read(context)
                                        .history
                                        .setPlaybackPrefs(
                                      seriesId: widget.series.id,
                                      audioTrackIndex: idx,
                                      audioTrackKey: key,
                                    );
                                  } catch (_) {}
                                },
                                onSubtitleTrackSelected: (idx, key) async {
                                  setState(() {
                                    _prefSubtitleIndex = idx;
                                    _prefSubtitleKey =
                                        key.isEmpty ? null : key;
                                  });
                                  try {
                                    await AppScope.read(context)
                                        .history
                                        .setPlaybackPrefs(
                                      seriesId: widget.series.id,
                                      subtitleTrackIndex: idx,
                                      subtitleTrackKey: key,
                                    );
                                  } catch (_) {}
                                },
                                onSubtitleDelayChanged: (delayMs) async {
                                  setState(
                                      () => _subDelay = delayMs / 1000.0);
                                  try {
                                    await AppScope.read(context)
                                        .history
                                        .setPlaybackPrefs(
                                      seriesId: widget.series.id,
                                      subtitleDelayMs: delayMs.round(),
                                    );
                                  } catch (_) {}
                                });
                              break;
                            case 'quality':
                              _openQualitySheet();
                              break;
                            case 'info':
                              _openPlaybackInfo();
                              break;
                            case 'screenshot':
                              _captureScreenshot();
                              break;
                            case 'sleep':
                              unawaited(_pickSleepTimer());
                              break;
                            case 'speed':
                              unawaited(_pickSpeed());
                              break;
                            case 'help':
                              _showShortcutHelp();
                              break;
                            case 'pip':
                              unawaited(_enterPip());
                              break;
                          }
                        },
                        itemBuilder: (_) => [
                          PopupMenuItem(
                            value: 'danmaku',
                            child: Text(_danmakuOn ? '弹幕：开' : '弹幕：关',
                                style: PlayerOverlayTokens.stylePrimary),
                          ),
                          PopupMenuItem(
                            value: 'danmaku_settings',
                            child: Text('弹幕设置',
                                style: PlayerOverlayTokens.stylePrimary),
                          ),
                          PopupMenuItem(
                            value: 'danmaku_block',
                            child: Text('弹幕屏蔽词',
                                style: PlayerOverlayTokens.stylePrimary),
                          ),
                          PopupMenuItem(
                            value: 'skip',
                            child: Text('片头片尾',
                                style: PlayerOverlayTokens.stylePrimary),
                          ),
                          PopupMenuItem(
                            value: 'tracks',
                            child: Text('音轨 / 字幕',
                                style: PlayerOverlayTokens.stylePrimary),
                          ),
                          PopupMenuItem(
                            value: 'quality',
                            child: Text('清晰度',
                                style: PlayerOverlayTokens.stylePrimary),
                          ),
                          PopupMenuItem(
                            value: 'info',
                            child: Text('播放信息',
                                style: PlayerOverlayTokens.stylePrimary),
                          ),
                          PopupMenuItem(
                            value: 'screenshot',
                            child: Text('截图',
                                style: PlayerOverlayTokens.stylePrimary),
                          ),
                          PopupMenuItem(
                            value: 'help',
                            child: Text(_isDesktop ? '快捷键' : '操作说明',
                                style: PlayerOverlayTokens.stylePrimary),
                          ),
                          // 画中画：只在能力探测通过时出现。**永远不占底栏
                          // 槽位**——旧版常驻底栏会把横屏按钮挤出屏幕。
                          if (_pipSupported)
                            PopupMenuItem(
                              value: 'pip',
                              child: Text('画中画',
                                  style: PlayerOverlayTokens.stylePrimary),
                            ),
                          // 窄屏（含窄窗桌面）内联按钮已隐藏，入口必须在
                          // 「更多」里；条件此前写反，导致紧凑模式下彻底没有
                          // 倍速/睡眠入口（用户实测「倍速点不了」）。
                          if (compactBar) ...[
                            PopupMenuItem(
                              value: 'sleep',
                              child: Text('睡眠定时',
                                  style: PlayerOverlayTokens.stylePrimary),
                            ),
                            PopupMenuItem(
                              value: 'speed',
                              child: Text('播放倍速',
                                  style: PlayerOverlayTokens.stylePrimary),
                            ),
                          ],
                        ],
                      ),
                      // 睡眠定时（窄屏收进「更多」）
                      if (!compactBar)
                        PopupMenuButton<int>(
                        tooltip: '睡眠定时',
                        initialValue: _sleepMinutes,
                        color: PlayerOverlayTokens.panelFill,
                        onOpened: _onPopupOpened,
                        onCanceled: _onPopupClosed,
                        onSelected: (v) {
                          _onPopupClosed();
                          _setSleepTimer(v);
                        },
                        itemBuilder: (_) => const [
                          PopupMenuItem(
                              value: 0,
                              child: Text('不定时',
                                  style: PlayerOverlayTokens.stylePrimary)),
                          PopupMenuItem(
                              value: 15,
                              child: Text('15 分钟',
                                  style: PlayerOverlayTokens.stylePrimary)),
                          PopupMenuItem(
                              value: 30,
                              child: Text('30 分钟',
                                  style: PlayerOverlayTokens.stylePrimary)),
                          PopupMenuItem(
                              value: 60,
                              child: Text('60 分钟',
                                  style: PlayerOverlayTokens.stylePrimary)),
                        ],
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          child: Icon(
                            _sleepMinutes > 0
                                ? Icons.timer
                                : AppIcons.timer,
                            color: _sleepMinutes > 0
                                ? PlayerOverlayTokens.accent
                                : PlayerOverlayTokens.textPrimary,
                          ),
                        ),
                      ),
                      // 倍速（窄屏收进「更多」）：TV 走 PopupMenuButton，
                      // 桌面/移动走 FxDockMenu（E2 dock 化）。
                      if (!compactBar)
                        _isTv
                            ? PopupMenuButton<double>(
                                initialValue: _speed,
                                color: PlayerOverlayTokens.panelFill,
                                onOpened: _onPopupOpened,
                                onCanceled: _onPopupClosed,
                                // 倍速按剧记忆，换剧不再重调。
                                onSelected: (v) {
                                  _onPopupClosed();
                                  _applySpeed(v);
                                },
                                itemBuilder: (_) => [
                                  for (final v in const [
                                    0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0,
                                  ])
                                    PopupMenuItem(
                                        value: v,
                                        child: Text('${v}x',
                                            style: PlayerOverlayTokens
                                                .stylePrimary)),
                                ],
                                child: Padding(
                                  // 同上：文本行高撑不起 40dp 触达目标。
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 10, vertical: 10),
                                  child: Text('${_displaySpeed}x',
                                      style:
                                          PlayerOverlayTokens.stylePrimary),
                                ),
                              )
                            : FxDockMenu<double>(
                                value: _speed,
                                // 倍速按剧记忆，换剧不再重调。
                                onSelected: _applySpeed,
                                onOpenChanged: _onMenuOpenChanged,
                                items: [
                                  for (final v in const [
                                    0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0,
                                  ])
                                    FxDockMenuItem(value: v, label: '${v}x'),
                                ],
                                child: Padding(
                                  // 同上：文本行高撑不起 40dp 触达目标。
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 10, vertical: 10),
                                  child: Text('${_displaySpeed}x',
                                      style:
                                          PlayerOverlayTokens.stylePrimary),
                                ),
                              ),
                      // 桌面端：窗口调成片源比例；移动端：横竖屏切换。
                      if (_isDesktop)
                        IconButton(
                          tooltip: '适应片源',
                          onPressed: () {
                            final pb = _playback;
                            if (pb == null) return;
                            _fitWindowToStream(
                              _currentStream(pb.playback),
                              widget.episodes[_index],
                            );
                          },
                          icon: const Icon(AppIcons.aspectRatio,
                              color: PlayerOverlayTokens.textPrimary),
                        ),
                      // 桌面端：铺满——全屏 + 画面裁剪填充（竖屏剧也能无黑边）。
                      if (_isDesktop)
                        IconButton(
                          tooltip: _fill ? '适应画面' : '铺满全屏',
                          onPressed: _toggleFill,
                          icon: Icon(
                            _fill ? Icons.fit_screen : Icons.crop_free,
                            color: PlayerOverlayTokens.textPrimary,
                          ),
                        ),
                      // 桌面端：迷你置顶小窗（I 键），边干活边看。
                      // 移动端原生画中画（PiP）功能已按用户要求整体移除。
                      if (_isDesktop)
                        IconButton(
                          tooltip: _mini ? '还原窗口 (I)' : '迷你置顶 (I)',
                          onPressed: _toggleMiniWindow,
                          icon: Icon(
                              _mini
                                  ? Icons.picture_in_picture_alt
                                  : Icons.picture_in_picture,
                              color: PlayerOverlayTokens.textPrimary),
                        ),
                      // 电视恒横屏（启动时已锁定），不显示方向切换。
                      if (!_isTv)
                      IconButton(
                        tooltip: _isDesktop
                            ? '全屏 (F)'
                            : _orientMode == _OrientationMode.locked
                                ? '恢复自动旋转'
                                : MediaQuery.orientationOf(context) ==
                                        Orientation.landscape
                                    ? '锁定竖屏'
                                    : '锁定横屏',
                        onPressed: () {
                          if (_isDesktop) {
                            unawaited(_toggleFullscreen());
                            return;
                          }
                          _toggleOrientation();
                        },
                        icon: Icon(
                            _isDesktop
                                ? Icons.fullscreen
                                : _orientMode == _OrientationMode.locked
                                    ? Icons.screen_lock_rotation
                                    : Icons.screen_rotation,
                            color: PlayerOverlayTokens.textPrimary),
                      ),
                      // 全屏时控制栏右端显示当前时间 + 星期几：全屏看剧时
                      // 没有系统任务栏可看（用户反馈），随分钟自刷新。
                      if (_showClock) const _PlayerClock(),
                    ],
                  ),
                  ),
                ],
                ),
              ),
            ),
          ],
      ),
    );
  }

  /// 底栏容器：宽窗直接铺满（Spacer 把右侧组顶到边上）；窄窗改为横向滚动，
  /// 每个按钮都能滑到，不再被 Row 溢出裁掉。
  Widget _playerBar({required bool scrollable, required Widget child}) {
    if (!scrollable) return child;
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: child,
    );
  }
}

/// 播放方向模式：跟随传感器 / 手动锁定。
enum _OrientationMode { auto, locked }



/// 全屏控制栏右端的当前时间（HH:mm 周X）。
///
/// 自带分钟级刷新：控制栏没有周期性重建（进度由流驱动，暂停时不动），
/// 时钟必须自己走；15s 步进对齐分钟粒度足够。
class _PlayerClock extends StatefulWidget {
  const _PlayerClock();

  @override
  State<_PlayerClock> createState() => _PlayerClockState();
}

class _PlayerClockState extends State<_PlayerClock> {
  Timer? _timer;
  DateTime _now = DateTime.now();

  static const List<String> _weekdays = <String>[
    '周一', '周二', '周三', '周四', '周五', '周六', '周日',
  ];

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 15), (_) {
      if (mounted) setState(() => _now = DateTime.now());
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  String _two(int v) => v.toString().padLeft(2, '0');

  @override
  Widget build(BuildContext context) {
    final String weekday = _weekdays[_now.weekday - 1];
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10),
      child: Text(
        '${_two(_now.hour)}:${_two(_now.minute)} $weekday',
        style: PlayerOverlayTokens.stylePrimary,
      ),
    );
  }
}

String _fmtDur(Duration d) {
  final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
  final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  final h = d.inHours;
  return h > 0 ? '$h:$m:$s' : '$m:$s';
}


/// 延迟出现的进度条：解析极快（<120ms）时不闪一下。
class _DelayedProgressBar extends StatefulWidget {
  const _DelayedProgressBar();

  @override
  State<_DelayedProgressBar> createState() => _DelayedProgressBarState();
}

class _DelayedProgressBarState extends State<_DelayedProgressBar> {
  Timer? _timer;
  bool _visible = false;

  @override
  void initState() {
    super.initState();
    _timer = Timer(const Duration(milliseconds: 120), () {
      if (mounted) setState(() => _visible = true);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_visible) return AppGap.v(AppGapSize.s2);
    // 轨道走播放器 OSD 体系暗色（DESIGN.md §14 挂账）：深色 scrimStrong
    // 面板上 surface3 在浅色主题下近白刺眼。选不透明的 panelFill 而非
    // 半透明档（pill/hud/scrim）——后者会与底下的 scrim+画面二次叠加，
    // 轨道对比度随片源明暗漂移；panelFill 在明暗画面下都稳定可读。
    // 进度（虚线）色不变：缺省仍取品牌橙。
    return const JellyProgressBar(trackColor: PlayerOverlayTokens.panelFill);
  }
}

/// 帮助面板里的一行：按键 + 说明。
class _Shortcut extends StatelessWidget {
  const _Shortcut({required this.key_, required this.action});

  final String key_;
  final String action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          SizedBox(
            width: 110,
            child: Text(key_,
                style: theme.textTheme.bodyMedium
                    ?.copyWith(fontWeight: FontWeight.bold)),
          ),
          Expanded(child: Text(action, style: theme.textTheme.bodyMedium)),
        ],
      ),
    );
  }
}
