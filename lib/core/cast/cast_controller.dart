import 'dart:async';

import 'package:flutter/foundation.dart';

import '../error_log.dart';
import 'cast_device_family.dart';
import 'cast_diagnostics.dart';
import 'cast_media_proxy.dart';
import 'cast_media_type.dart';
import 'cast_profile.dart';
import 'cast_recipe.dart';
import 'cast_route.dart';
import 'cast_target.dart';
import 'dlna_device.dart';
import 'didl.dart';
import 'gena_subscriber.dart';
import 'mirror/mirror_controller.dart';
import 'airplay/airplay_transport.dart';
import 'chromecast/chromecast_transport.dart';
import 'dlna_transport.dart';
import 'local_media_server.dart';
import 'mdns_discovery.dart';
import 'soap_client.dart';
import 'ssdp_discovery.dart';

/// 投屏会话状态。
enum CastSessionState { idle, discovering, connecting, casting, stopping }

/// 本机转码（Go castrelay，ffmpeg 管道）产物的 mime 提示：hls 档输出恒为
/// HLS（cast_media_fallback.relayMimeHint 同值，产物 URL 已是 .m3u8）。
const String kRelayProductMimeHint = 'application/vnd.apple.mpegurl';

/// 本机转码 ts 档（R2）产物的 mime 提示：产物 URL 为 `…/stream.ts`。
///
/// 11-09 起用 `video/mpeg` 而非 `video/mp2t`：这是 DLNA 电视对 MPEG-TS 最常见
/// 的声明写法（go2tv 转码产物、jellyfin mpegts 容器同口径）。设备 Sink 里有
/// `video/mp2t` / `video/vnd.dlna.mpeg-tts` 条目时，preferSinkSpelling 会照抄
/// 设备拼写，因此这里是「无证据时的最通用值」。
const String kRelayProductTsMimeHint = 'video/mpeg';

/// 本机转码产物的 mime 提示按产物 URL 扩展名分流（R2）：`.ts` → TS 档。
String _relayProductMimeHint(String url) =>
    url.toLowerCase().endsWith('.ts')
        ? kRelayProductTsMimeHint
        : kRelayProductMimeHint;

/// 兼容模式选路结果（M5-0）：最终投屏 URL + 已判定的源媒体类型
/// （复用避免二次嗅探）+ 是否经本机转码（产物恒 HLS）。
typedef _PreparedPlayUrl = ({
  String url,
  CastMediaType? sourceType,
  bool viaRelay,
});

/// 本机转码挂点形状：媒体 + 选路决定的输出档位（R2）+ 会话字幕（R3）+
/// 目标设备 host（11-09 取流修复：Go 侧据此探路由源 IP，避免产物 URL
/// 落到 127.0.0.1——只有会改写 loopback 的接收端才播得动）。
typedef CastTranscodeResolver = Future<String?> Function(
  CastMedia media, {
  String? relayFormat,
  Uri? relaySubtitleUrl,
  String relayHostHint,
});

/// 恢复投屏「重新解析」挂点形状（11-08-resume-reparse）：按恢复记录重新
/// 解析分集产出新鲜 [CastMedia]（红果直链带时效签名，跨天必失效）。
/// 返回 null / 抛异常由控制器归一为「回退记录 URL」现状分支。
typedef CastResumeProvider = Future<CastMedia?> Function(
  CastSessionRecord record,
);

/// 要投出去的媒体（URL 必须是电视可达的局域网/公网直链，绝不能是 127.0.0.1）。
class CastMedia {
  const CastMedia({
    required this.url,
    required this.title,
    this.coverUrl = '',
    this.position = Duration.zero,
    this.episodeIndex = 1,
    this.episodeCount = 0,
    this.localPath = '',
    this.headers = const {},
    this.recordUrl,
    this.subtitleUrl = '',
    this.isMirror = false,
    this.mimeHint = '',
    this.duration,
    this.viaRelay = false,
    this.relaySession = '',
    this.codecHint = '',
    this.sourceId = '',
  });

  final String url;
  final String title;
  final String coverUrl;
  final Duration position;
  final int episodeIndex;
  final int episodeCount;

  /// 本机文件路径。非空时由 [LocalMediaServer] 生成局域网 URL，[url] 被忽略。
  final String localPath;

  /// 源站请求头（Referer/UA 等）。非空且为 http(s) 直链时经 [CastMediaProxy]
  /// 包一层再投给电视（电视无法自带这些头）。本地文件路径下被忽略。
  final Map<String, String> headers;

  /// 会话恢复记录应使用的 URL（选路前的源地址）。null 时记录用 [url]。
  ///
  /// 连播 provider 对加密分集会把本机中继产物塞进 [url]（产物随会话回收
  /// 即死链）——恢复记录必须存源地址，否则「恢复上次投屏」传递死链
  /// （UI 冒烟实证：恢复后 6 秒停）。
  final String? recordUrl;

  /// 外挂字幕地址（srt/vtt）。DLNA 走 DIDL `sec:SubtitleUri`；
  /// Chromecast 先转 VTT 再作为 textTrack 投送。空表示无字幕。
  final String subtitleUrl;

  /// 屏幕镜像流（MirrorService 的 /stream.ts）。会话结束（断开/电视端停止）
  /// 时控制器自动停掉镜像服务。
  final bool isMirror;

  /// 调用方已知的媒体 mime（如 `ResolvedPlayback.mimeType`）。作为
  /// [resolveCastMediaType] 的第一级证据（显式 hint）；空 = 无提示，
  /// 由 URL 扩展名/内容嗅探判定。
  final String mimeHint;

  /// 真实时长（播放器手里有时长就传）。null/≤0 = 未知或直播——
  /// DIDL `<res duration>` 只在真实值时写（写错比不写更糟，AC-27）。
  final Duration? duration;

  /// 该 URL 已是本机中继（Go castrelay）产物。兼容模式选路（M5-0）对它恒
  /// 直投，不会再套一层转码：加密分集与 resolvePlay 源在调用方完成中继后
  /// 置位；屏幕镜像（[isMirror]）同理不受选路影响。
  final bool viaRelay;

  /// 本片的中继会话 id（Go `castRelayStart` 返回的 `session`）。
  ///
  /// 非空 = 本片是本机中继产物。诊断据此把「中继快照/本机 IP/投屏 URL」
  /// 限定在当前会话——播放页预起中继与 controller 选路中继可能并存，
  /// 不校验归属会把上一个会话的端口/地址显示到本次诊断（真机报告实证：
  /// 投屏 URL 端口 29173 与 SOAP CurrentURI 29172 不一致）。
  final String relaySession;

  /// 视频编码提示（如 `hevc` / `h265` / `av1`，红果 VideoStream.codec）。
  /// 兼容模式 auto 选路据此把 HEVC/AV1 分集路由到本机转码（统一转 H.264）。
  final String codecHint;

  /// 源剧集 id（红果 seriesId，11-08-resume-reparse）。随会话恢复记录持久化：
  /// 恢复场景经 [CastController.resumeProvider] 重新解析分集拿新鲜 URL
  /// （红果直链带时效签名，跨天必失效）。CMS 源（source_player_screen）无
  /// 红果剧集 id 留空，恢复走记录 URL 现状回退。
  final String sourceId;

  bool get isLocalFile => localPath.isNotEmpty;
}

/// 一次轮询到的远端状态。
class CastPoll {
  const CastPoll({
    required this.transportState,
    this.position = Duration.zero,
    this.duration = Duration.zero,
  });
  final String transportState; // PLAYING / RUNNING / PAUSED_PLAYBACK / STOPPED / NO_MEDIA_PRESENT…
  final Duration position;
  final Duration duration;

  /// 各厂商状态词不一致：标准 UPnP 是 `PLAYING`，部分设备回 `RUNNING`。
  /// 只认 RUNNING 会让正常播放被当成「未运行」，远程进度插值随之停摆。
  bool get isRunning {
    final state = transportState.trim().toUpperCase();
    return state == 'PLAYING' || state == 'RUNNING';
  }
  bool get isPaused => transportState == 'PAUSED_PLAYBACK';
  bool get isStopped => transportState == 'STOPPED' || transportState == 'NO_MEDIA_PRESENT';
}

/// DLNA 兼容加载所需的全部输入。
///
/// 它是「可选能力」[CastCompatTransport] 的入参：不感知配方的 transport
/// （Chromecast / 测试假件）根本不会收到它，控制器仍走标准三件套。
class CastLoadRequest {
  const CastLoadRequest({
    required this.url,
    required this.didl,
    this.recipes = const <CastRecipe>[],
    this.title = '',
    this.duration,
    this.subtitleUrl,
    this.position = Duration.zero,
    this.protocolInfo = const <String>{},
  });

  final Uri url;
  final DidlRequest didl;
  final List<CastRecipe> recipes;
  final String title;
  final String? duration;
  final Uri? subtitleUrl;
  final Duration position;

  /// GetProtocolInfo 预检拿到的 Sink 条目（控制器预检后回填）。
  final Set<String> protocolInfo;
}

/// 可选能力接口：DLNA 兼容层专用。
///
/// 刻意不往 [CastTransport] 加方法——`implements` 会要求所有既有实现
/// （Chromecast / 各测试假件）补实现；用 `is` 探测才能真正做到向后兼容。
abstract class CastCompatTransport {
  Future<Set<String>> preflight();

  /// 返回实际成功的配方（供控制器记忆）。
  Future<CastRecipe?> load(CastLoadRequest request);
}

/// 传输抽象：DLNA 是 SOAP 实现，Chromecast 是 CASTv2 实现；测试注入假实现驱动状态机。
abstract class CastTransport {
  Future<void> setUri(
    Uri url, {
    required String title,
    String? duration,
    Uri? subtitleUrl,
  });
  Future<void> play();
  Future<void> pause();
  Future<void> stop();
  Future<void> seekTo(Duration position);
  Future<void> setVolume(int percent);
  Future<void> setMute(bool muted);
  Future<CastPoll> poll();

  /// 释放底层连接（SOAP 客户端/CASTv2 socket）。会话结束时控制器调用。
  void close() {}
}

/// 默认 transport 工厂：按目标协议分派。
CastTransport defaultTransportFactory(CastTarget target) {
  switch (target.protocol) {
    case CastProtocol.dlna:
      return DlnaTransport(target.dlna!);
    case CastProtocol.chromecast:
      return ChromecastTransport(target.cast!);
    case CastProtocol.airplay:
      return AirPlayTransport(target.airplay!);
  }
}

/// 同 IP 降级链协议位次（design §3）：dlna → chromecast → airplay（末位追加）。
int castProtocolFallbackRank(CastProtocol protocol) => switch (protocol) {
      CastProtocol.dlna => 0,
      CastProtocol.chromecast => 1,
      CastProtocol.airplay => 2,
    };

/// 投屏会话控制器：状态机 + 1s 轮询 + 远端主动停止感知 + 多协议路由。
///
/// 本地联动（暂停本地播放器/断开回本地续播）由 UI 层订阅完成——控制器只管远端。
class CastController extends ChangeNotifier {
  CastController({
    CastTransport Function(CastTarget)? transportFactory,
    this.mdnsDiscover,
    this.airplayDiscover,
    this.proxyResolver,
    CastRecipeStore? recipeStore,
    CastProfileStore? profileStore,
    this.sessionRecorder,
  })  : _transportFactory = transportFactory ?? defaultTransportFactory,
        recipes = recipeStore ?? CastRecipeStore(),
        profiles = profileStore;

  final CastTransport Function(CastTarget) _transportFactory;

  /// 设备 → 成功配方（v4 双层键）。默认是一张不落盘的内存表；集成时把
  /// `CastStore.recipes`（v4 持久化）注入这里即可跨启动记住配方
  /// （`CastService.attachStores`，M3-4）。
  CastRecipeStore recipes;

  /// 设备画像（可选）：非 null 时投屏成功/会话收尾同步更新画像并落盘。
  /// 未接线（测试/独立使用）时为 null，不影响任何投屏行为。
  CastProfileStore? profiles;

  /// 会话恢复记录挂点（R1，[CastStore] 实现，bootstrap 注入）：投送成功
  /// 写全量、轮询进度 10s 节流更新、会话收尾更新 endedAt。null = 不记录，
  /// [resumeLastSession] 相应返回 false。
  CastSessionRecorder? sessionRecorder;

  /// 当前会话是否已写入恢复记录：轮询进度与会话收尾只在已记录会话上生效，
  /// 防止镜像/本地文件会话把上一条记录的进度与时间戳改掉。
  bool _sessionRecorded = false;

  /// 中断自动恢复一次性 flag（R1，任务 11-07-cast-auto-reconnect）：失联触发
  /// 恢复尝试即置位，会话结束（[_finishSession]）复位——本会话内无论恢复
  /// 成败都不再触发（恰一次，无重试风暴）。
  bool _autoReconnectAttempted = false;

  /// 恢复尝试进行中（复检 + 重投期间）：失联批次的重复触发在此静默，避免
  /// 与恢复流程竞争（也不重复打 [onSessionLost]）。
  bool _autoReconnecting = false;

  /// mDNS 发现挂点（Chromecast）注入点；null = 用默认 [MdnsDiscovery]。
  final Stream<CastDeviceInfo> Function()? mdnsDiscover;

  /// mDNS 发现挂点（AirPlay `_airplay._tcp`）注入点；null = 用默认实现。
  final Stream<AirPlayDeviceInfo> Function()? airplayDiscover;

  /// 受保护流代理挂点。非 null 时带源站头的直链经它包一层；返回 null 表示不代理。
  /// null 时用控制器自带的 [CastMediaProxy]。
  final Future<String?> Function(String url, Map<String, String> headers)?
      proxyResolver;

  /// 兼容模式（本机转码）挂点（M5-0）：选路判定为「走中继」时由控制器调用，
  /// UI 层在发起投屏时注入 Go `castRelayStart` 适配器（闭包内停旧会话、挂
  /// 取流探针，与 [onNextEpisode] 同一注入模式；断开/收尾由 [_finishSession]
  /// 清引用）。返回中继产物 URL；null = 中继不可用（选路回退直投/代理）。
  /// 未注入 = 本机转码路由不可用，auto/always 一律回退。
  ///
  /// [relayFormat] 是选路决定的输出档位（R2：Sink 含 HLS → hls；无 HLS 有
  /// TS → ts；证据缺失 → hls）。[relaySubtitleUrl] 是已按目标设备登记的
  /// 会话字幕（R3：Go 侧借此给媒体响应补 `CaptionInfo.sec` 第三通道）。
  CastTranscodeResolver? transcodeResolver;

  /// 中继完成度快照读取器（11-09 连播修复）：投屏时由播放页注入
  /// `() => CastRelayProbe.instance.snapshot`。null = 非中继会话/未注入：
  /// 连播判定回落到「设备上报 duration」的旧口径，行为与旧版一致。
  CastRelaySnapshot? Function()? relaySnapshotReader;

  /// 投送前刷新设备描述的注入点（11-11）：默认 [fetchDlnaDescription]；
  /// 单测注入固定值，避免真发 HTTP。
  Future<DlnaDevice?> Function(String location)? describeFetcher;

  /// 兜底快照读取器（bootstrap 注入）：[_finishSession] 收尾后恢复回本值而非
  /// null——恢复投屏发生在面板上，播放页可能没开，连播判定仍需读到快照。
  CastRelaySnapshot? Function()? defaultRelaySnapshotReader;

  /// 无播放页场景（恢复投屏）的兜底转码执行体：播放页注入的
  /// [transcodeResolver] 收尾后恢复回本值而非 null——否则恢复场景的
  /// 加密分集「转码不可用→回退直投」→ 接收端秒停（UI 冒烟实证）。
  CastTranscodeResolver? defaultTranscodeResolver;

  /// 恢复投屏「重新解析」挂点（11-08-resume-reparse）：恢复链路
  /// （[_replayLastSessionRecord]，resumeLastSession 与中断自动恢复共用）
  /// 遇记录带 sourceId 时由它重新解析分集产出新鲜媒体；返回 null / 抛异常
  /// （只进 ErrorLog）→ 回退记录 URL 现状分支，绝不让解析失败堵死恢复。
  /// 注入模式同 [onNextEpisode]；会话收尾由 [_finishSession] 恢复回
  /// [defaultResumeProvider] 而非 null——面板随时可能一键恢复，兜底
  /// provider 必须常驻（同 [transcodeResolver] / [defaultTranscodeResolver]
  /// 双字段先例）。
  CastResumeProvider? resumeProvider;

  /// 无播放页场景（恢复投屏）的兜底重新解析执行体：bootstrap 注入
  /// （default_resume_provider.dart：listEpisodes 翻页定位集 →
  /// resolvePlayback → 加密分集本机中继）；会话收尾恢复回本值。
  CastResumeProvider? defaultResumeProvider;

  /// 深度诊断重试一次性开关（R1.2，任务 11-07-cast-final-hygiene）：面板
  /// 诊断分区打开后，下一次投送（仅 DLNA 目标）走全组合扫描模式
  /// （[DlnaTransport.scanAll]）；投送时即消费（无论成败），扫描结果**不写
  /// 配方记忆**（成功不 remember、失败不清既有配方）。开关关 = 现状路径。
  bool _deepScanArmed = false;

  /// 「深度诊断重试」开关当前状态（面板诊断分区回显用）。
  bool get deepDiagnosticScanArmed => _deepScanArmed;

  /// 打开「深度诊断重试」：下一次投送走扫描模式（幂等）。
  void armDeepDiagnosticScan() {
    if (_deepScanArmed) return;
    _deepScanArmed = true;
    notifyListeners();
  }

  /// 关闭「深度诊断重试」（未被投送消费前可撤销；幂等）。
  void disarmDeepDiagnosticScan() {
    if (!_deepScanArmed) return;
    _deepScanArmed = false;
    notifyListeners();
  }

  CastSessionState _state = CastSessionState.idle;
  final List<CastTarget> _devices = [];
  CastTarget? _currentDevice;
  CastMedia? _currentMedia;
  CastTransport? _transport;
  Timer? _pollTimer;
  bool _userStopping = false;

  /// 电视端主动停止（用户在遥控器上按了停止）时回调，携带最后已知进度。
  void Function(CastTarget device, Duration lastPosition)? onRemoteStopped;

  /// 连续多次轮询失败（电视休眠/换网）时回调，UI 据此提示「连接已断开」。
  void Function(CastTarget device)? onSessionLost;

  /// 中断自动恢复成功（R3）：UI 据此 toast 一次「已自动恢复投屏」。播放器
  /// 页注入（与 [onRemoteStopped] 同一注入模式；SnackBar 全局可见，投屏面板
  /// 开与不开都显示）；未注入 = 只记诊断时间线。
  void Function()? onAutoReconnected;

  /// 中断自动恢复的可达性复检挂点（R2）：默认实现 GET DLNA 描述 URL / 无
  /// 描述 URL 的协议按端口 TCP 探活（见 `_probeTargetReachable`）。测试注入
  /// 假件（404/超时路径）；返回 false = 目标不可达 → 静默走既有「电视端
  /// 停止」路径。
  Future<bool> Function(CastTarget)? reachabilityProbe;

  /// 连播队列：电视端播完当前集后取下一集；返回 null 表示没有更多。
  /// 由 UI 在发起投屏时注入（捕获当时的集数上下文），会话结束自动清空。
  Future<CastMedia?> Function()? onNextEpisode;

  /// 跳集队列（遥控器上一集/手动跳集）：与 [onNextEpisode] 同一注入模式。
  /// [delta] 语义由 UI 队列决定（-1 = 上一集）；0 或越界返回 null。
  /// 会话结束自动清空。未注入时 UI 按钮置灰（直播/无队列场景）。
  Future<CastMedia?> Function(int delta)? onEpisodeJump;

  bool _autoAdvancing = false;

  CastSessionState get state => _state;
  List<CastTarget> get devices => List.unmodifiable(_devices);
  CastTarget? get currentDevice => _currentDevice;
  CastMedia? get currentMedia => _currentMedia;

  /// 最近一次投屏目标的 host（当前会话 → 上次会话记录 → 空串）。
  ///
  /// 播放页在「还没选设备」时就要起中继（resolvePlay / 加密分集），拿不到本次
  /// 目标；用上一次的 host 作 `hostHint`，Go 侧据此探路由源 IP，多网卡下也能
  /// 选对网卡。空串 = 回落 Go 的网卡枚举。
  String get lastTargetHost {
    final current = _currentDevice;
    if (current != null && current.host.isNotEmpty) return current.host;
    try {
      final target = sessionRecorder?.lastSession?.resolveTarget();
      if (target != null && target.host.isNotEmpty) return target.host;
    } catch (_) {
      // 记录损坏：视作无提示（Go 回落枚举）。
    }
    return '';
  }
  /// 有效时长：远端上报 > 媒体真实时长 > 中继已转出时长。
  ///
  /// 为何需要（11-09 用户反馈「投屏端选不了进度条控制位置」）：中继 HLS 会话里
  /// 电视把 `TrackDuration` 报成 0 / NOT_IMPLEMENTED，若只用远端值，
  /// `remoteDuration` 恒 0 → 会话面板整条隐藏进度条，拖动 seek 无处可拖。
  Duration get effectiveDuration {
    final computed = _computeEffectiveDuration();
    if (computed > Duration.zero) {
      // 记住最近一次「有证据」的时长（11-11 真机：进度条消失）。
      // 电视报 0（`<TrackDuration></TrackDuration>`）且中继快照在会话回收/
      // 探针自停后变 null 时，旧实现会一路回落成 0 → 进度条整条消失；
      // 同一媒体内保留上次的已知时长，页面至少能继续拖动/显示总长。
      _lastKnownDuration = computed;
      return computed;
    }
    return _lastKnownDuration > Duration.zero ? _lastKnownDuration : Duration.zero;
  }

  Duration _computeEffectiveDuration() {
    if (_lastDuration > Duration.zero) return _lastDuration;
    final mediaDuration = _currentMedia?.duration;
    if (mediaDuration != null && mediaDuration > Duration.zero) {
      return mediaDuration;
    }
    // 边转边播时清单累计时长是唯一已知刻度（会随转码增长）。
    final relay = relaySnapshotReader?.call();
    if (relay != null && relay.duration > Duration.zero) return relay.duration;
    return Duration.zero;
  }

  /// 进度条总长（会话面板消费；保留旧名，等价于 [effectiveDuration]）。
  Duration get remoteDuration => effectiveDuration;

  /// 可拖动上限：中继边转边播时只能跳到**已转出**的区间（ffmpeg 还没写出
  /// 的分片，接收端 seek 过去会失败或立刻跳回）。非中继/已转完 → 有效时长。
  Duration get seekUpperBound {
    final relay = relaySnapshotReader?.call();
    if (relay != null &&
        !relay.completedCleanly &&
        relay.duration > Duration.zero) {
      return relay.duration;
    }
    return effectiveDuration;
  }

  bool get isCasting => _state == CastSessionState.casting;

  /// 最近一次轮询到的远端 transportState（原始 UPnP/CASTv2 词汇，未映射）。
  /// 空串 = 尚未轮询到（UI 据此隐藏状态徽标）。
  String get remoteTransportState => _lastTransportState;

  /// 远端进度：两次轮询之间按本地时钟插值，进度条不再「一秒一跳」。
  ///
  /// 上限 5s：轮询卡住时不至于把进度条推到离谱的位置。
  Duration get remotePosition {
    if (_state != CastSessionState.casting || !_lastRunning) {
      return _lastPosition;
    }
    final at = _polledAt;
    if (at == null) return _lastPosition;
    var extra = DateTime.now().difference(at);
    if (extra > const Duration(seconds: 5)) {
      extra = const Duration(seconds: 5);
    }
    if (extra.isNegative) extra = Duration.zero;
    return _lastPosition + extra;
  }

  Duration _lastPosition = Duration.zero;
  Duration _lastDuration = Duration.zero;

  /// 最近一次「有证据」的有效时长（11-11）：电视报 0 + 中继快照消失时兜底，
  /// 避免投屏管理页进度条整条消失。换媒体/收尾会话时清零。
  Duration _lastKnownDuration = Duration.zero;
  DateTime? _polledAt;
  bool _lastRunning = false;
  String _lastTransportState = '';
  int _pollFailures = 0;
  SsdpDiscovery? _discovery;
  StreamSubscription<SsdpEvent>? _discoverySub;
  StreamSubscription<CastDeviceInfo>? _mdnsSub;
  StreamSubscription<AirPlayDeviceInfo>? _airplaySub;
  GenaSubscriber? _gena;
  StreamSubscription<CastPoll>? _genaSub;
  DateTime? _lastGenaAt;
  int _pollTick = 0;

  /// 诊断时间线去重：只记录电视状态变化（M0 纯采集）。
  String _lastTimelineState = '';

  /// 本会话预检到的 Sink 清单与预检结果（画像构建用，M3）。
  /// 连播期间沿用会话内的 Sink 记忆（预检失败也不阻断连播）。
  Set<String> _sessionSink = const <String>{};
  bool _sessionPreflightOk = false;

  // ---------- 中继档位自动降级（11-09） ----------

  /// 强制指定的中继档位（降级后置 'ts'；null = 按 Sink 选路）。
  String? _forcedRelayFormat;

  /// 本会话实际使用的中继档位（hls/ts；非中继会话为 null）。
  String? _sessionRelayFormat;

  /// 档位自动降级是否已有结论（每会话恰一次；无论成功/无需降级都置位）。
  bool _relayFormatFallbackDone = false;

  /// 本集投送时刻（降级等待窗口起点）。
  DateTime? _mediaCastAt;

  /// 本集投送时刻的取流记录基线（只看本集新增请求）。
  int _mediaRequestBaseline = 0;

  /// 当前投送的**源**媒体（选路前）：档位降级重投必须回到源 URL 重新转码，
  /// 不能拿中继产物再走一遍选路（viaRelay 恒直投）。
  CastMedia? _sourceMedia;

  // ---------- 扫描 ----------

  /// 本轮 SSDP 已见到的 DLNA udn（[startScan] 重置；ScanDone 据此标离线）。
  final Set<String> _scanSeenDlna = <String>{};

  void startScan() {
    if (_state == CastSessionState.discovering) return;
    // 11-09 用户反馈修复：不再 _devices.clear()。清空后按本轮发现顺序重填，
    // 顺序完全由网络时序决定——每次打开面板顺序都不一样。保留上一轮列表，
    // 本轮未出现的设备在 ScanDone 标离线（原位保留、仍可点击直连）。
    _scanSeenDlna.clear();
    _state = CastSessionState.discovering;
    notifyListeners();
    final discovery = _discovery = SsdpDiscovery();
    _discoverySub?.cancel();
    // P0 崩溃护栏：组播绑定失败等异常只写 ErrorLog，不中断扫描。
    // cancelOnError: false 保证单次错误不会把发现流整个关掉。
    _discoverySub = discovery.start().listen((event) {
      switch (event) {
        case SsdpDeviceFound(:final device):
          _scanSeenDlna.add(device.udn);
          _upsertDevice(CastTarget.dlna(device));
        case SsdpDeviceOffline(:final udn):
          final i = _devices.indexWhere((d) => d.id == udn);
          if (i >= 0) {
            _devices[i].online = false;
            if (_devices[i].dlna != null) _devices[i].dlna!.online = false;
            notifyListeners();
          }
        case SsdpScanDone():
          // 本轮没扫到的 DLNA 设备标离线（不删除、不重排）。
          markStaleDlnaOffline(_devices, _scanSeenDlna);
          notifyListeners();
      }
    }, onError: (Object error, StackTrace stack) {
      ErrorLog.instance.record('投屏扫描', error, stack);
    }, cancelOnError: false);
    _startMdnsScan();
  }

  /// Chromecast mDNS 扫描：多轮查询由 [MdnsDiscovery] 内部完成，这里只收流。
  void _startMdnsScan() {
    final discover = mdnsDiscover ?? _defaultMdnsDiscover;
    _mdnsSub?.cancel();
    _mdnsSub = discover().listen((info) {
      _upsertDevice(CastTarget.chromecast(info));
    }, onError: (_) {
      // mDNS 失败不影响 DLNA 扫描（老机型/权限缺失场景）。
    });
    // AirPlay `_airplay._tcp` 同一扫描周期并行收流（失败同样静默，不影响
    // DLNA/Chromecast；`_raop._tcp` 纯音频设备不进列表——见 MdnsDiscovery）。
    final discoverAirplay = airplayDiscover ?? _defaultAirplayDiscover;
    _airplaySub?.cancel();
    _airplaySub = discoverAirplay().listen((info) {
      _upsertDevice(CastTarget.airplay(info));
    }, onError: (_) {});
  }

  static Stream<CastDeviceInfo> _defaultMdnsDiscover() =>
      MdnsDiscovery.discover(MdnsDiscovery.chromecastServiceType);

  static Stream<AirPlayDeviceInfo> _defaultAirplayDiscover() =>
      MdnsDiscovery.discoverAirplay();

  void _upsertDevice(CastTarget target) {
    final merged = mergeCastTarget(_devices, target);
    // 被策略丢弃（同 IP 已有 DLNA 的 AirPlay）：记一条时间线便于诊断。
    if (!merged.any((d) => d.id == target.id)) {
      CastDiagnostics.instance
          .recordTimeline('已隐藏同 IP 的 AirPlay 目标：${target.name}');
      return;
    }
    _devices
      ..clear()
      ..addAll(merged);
    notifyListeners();
  }

  void stopScan() {
    if (_state == CastSessionState.discovering) {
      _state = CastSessionState.idle;
    }
    _discoverySub?.cancel();
    _discoverySub = null;
    _mdnsSub?.cancel();
    _mdnsSub = null;
    _airplaySub?.cancel();
    _airplaySub = null;
    unawaited(_discovery?.stop());
    _discovery = null;
    notifyListeners();
  }

  /// 手动按 IP 添加 DLNA 设备（AP 隔离/组播被滤时的兜底）。
  Future<CastTarget?> addByIp(String host, {int port = 49152}) async {
    final discovery = _discovery ??= SsdpDiscovery();
    _discoverySub ??= discovery.start().listen((event) {
      if (event is SsdpDeviceFound) _upsertDevice(CastTarget.dlna(event.device));
    }, onError: (Object error, StackTrace stack) {
      ErrorLog.instance.record('投屏扫描', error, stack);
    }, cancelOnError: false);
    final device = await discovery.addByIp(host, port: port);
    return device == null ? null : CastTarget.dlna(device);
  }

  // ---------- 会话 ----------

  /// 本地文件投屏用的 HTTP 服务（只有投本地文件时才启动）。
  final LocalMediaServer _mediaServer = LocalMediaServer();

  /// 受保护流/字幕代理（默认实现；proxyResolver 注入可整体替换）。
  final CastMediaProxy _castProxy = CastMediaProxy();

  /// 受保护流代理登记：默认走 [CastMediaProxy.register] 并按目标设备取
  /// 路由源 IP（M0.5 per-device IP）；注入的 [proxyResolver] 不感知目标
  /// 设备（测试/替代实现），行为保持不变。
  /// [urlSuffixMode] 是目标设备配方里的 URL 形态旋钮（M1，默认带扩展名）。
  /// [subtitleUrl] 是已登记的字幕地址（M5-1）：代理媒体响应借此附加
  /// `CaptionInfo.sec` 第三通道。
  Future<String?> _proxyResolve(
    String url,
    Map<String, String> headers, {
    String? targetHost,
    String? hintMime,
    bool live = false,
    CastUrlSuffixMode urlSuffixMode = CastUrlSuffixMode.withExtension,
    String? subtitleUrl,
  }) =>
      proxyResolver != null
          ? proxyResolver!(url, headers)
          : _castProxy.register(
              url,
              headers: headers,
              targetHost: targetHost,
              hintMime: hintMime,
              live: live,
              urlSuffixMode: urlSuffixMode,
              subtitleUrl: subtitleUrl,
            );

  /// 源编码提示合并后的媒体副本：显式提示（红果 `stream.codec`）优先，
  /// 嗅探结果只在显式缺失时生效。ts 档据此决定 remux 还是重编码
  /// （HEVC/AV1 必须转 H.264，多数 DLNA 电视不认 HEVC over TS）。
  CastMedia _mediaWithCodecHint(CastMedia media, String? sniffed) {
    final merged = mergeCodecHint(media.codecHint, sniffed);
    if (merged.isEmpty || merged == media.codecHint) return media;
    return CastMedia(
      url: media.url,
      title: media.title,
      coverUrl: media.coverUrl,
      position: media.position,
      episodeIndex: media.episodeIndex,
      episodeCount: media.episodeCount,
      localPath: media.localPath,
      headers: media.headers,
      recordUrl: media.recordUrl,
      subtitleUrl: media.subtitleUrl,
      isMirror: media.isMirror,
      mimeHint: media.mimeHint,
      duration: media.duration,
      viaRelay: media.viaRelay,
      codecHint: merged,
      sourceId: media.sourceId,
    );
  }

  /// 兼容模式选路（M5-0/M5-3，design §4.10 判定表）：按配方三态 +
  /// 媒体类型三级判定 + 预检 Sink 决定「直投 / 本机代理 / 本机转码」。
  /// 首投（[_castWith]）与连播（[_tryAdvance]）共用同一段选路代码。
  ///
  /// - 本地文件：恒走 [LocalMediaServer]（选路不涉及）；
  /// - 镜像流 / Chromecast：保持现状（镜像已是本机产物；Chromecast 播放
  ///   路径按 P0 契约不动，只允许字幕转换开关影响它）；
  /// - 转码执行体是 [transcodeResolver]（UI 注入的 Go `castRelayStart`
  ///   适配器，中继会话生命周期由闭包管理）；未注入或启动失败回退
  ///   代理/直投，不让转码失败堵死投屏（M1-6 / AC-21 同语义）。
  Future<_PreparedPlayUrl> _preparePlayUrl(
    CastTarget target,
    CastMedia media, {
    required Set<String> sink,
    required CastTranscodeMode transcodeMode,
    required CastUrlSuffixMode urlSuffixMode,
    Uri? subtitleUrl,
  }) async {
    if (media.isLocalFile) {
      // M0.5：按目标设备取路由源 IP 生成对外 URL（电视拉得到流的地址）。
      final served = await _mediaServer.urlFor(media.localPath,
          targetHost: target.host,
          urlSuffixMode: urlSuffixMode,
          subtitleUrl: subtitleUrl?.toString());
      if (served == null) {
        throw CastException('本地媒体服务启动失败（检查是否在局域网内）');
      }
      return (url: served, sourceType: null, viaRelay: false);
    }
    if (target.protocol != CastProtocol.dlna || media.isMirror) {
      return _proxyOrDirect(
        media,
        target: target,
        urlSuffixMode: urlSuffixMode,
        hintMime: media.mimeHint,
      );
    }
    // 源媒体类型三级判定（显式 hint → URL 扩展名 → 内容嗅探；嗅探到
    // HTML/JSON 抛 CastException，把「错误页不喂电视」前移到投屏前）。
    final sourceType = await resolveCastMediaType(
      url: Uri.parse(media.url),
      hintMime: media.mimeHint,
      sinkMimes: sink,
      sniffHead: defaultSniffHead,
    );
    // 设备族（11-10）：只作默认值来源（Sink 证据优先），用于诊断与档位兜底。
    final family = castDeviceFamilyOf(target);
    final forceRelay = _forcedRelayFormat != null;
    final route = resolveCastRoute(
      mode: transcodeMode,
      mediaType: sourceType,
      sinkMimes: sink,
      viaRelay: media.viaRelay,
      needsProxy: media.headers.isNotEmpty,
      // 编码提示合并口径（R1）：红果显式 stream.codec 优先，内容嗅探其次
      // （MP4 ftyp brand / HLS 主清单 CODECS）；嗅探只影响选路。
      codecHint: mergeCodecHint(media.codecHint, sourceType.codecHint),
      forceRelay: forceRelay,
    );
    if (transcodeMode == CastTranscodeMode.never && route == CastRoute.relay) {
      // R3（11-09 二期）：设备自述的格式集合里没有 HLS，直投只会「受理成功
      // 但永不取流」。能播优先——明确告诉用户设置被覆盖，而不是静默失败。
      CastDiagnostics.instance.recordTimeline(
          '设备 Sink 未宣告 HLS，已忽略兼容模式「从不」，改走本机转码');
    }
    CastDiagnostics.instance.recordTimeline(
        '选路：${_routeLabel(route)}（模式 ${transcodeMode.name}，${sourceType.mime}'
        '${forceRelay ? '，档位降级强制转码' : ''}）');
    CastDiagnostics.instance
        .recordTimeline('设备族：${castDeviceFamilyLabel(family)}');
    switch (route) {
      case CastRoute.relay:
        // 输出档位（R2）：Sink 含 HLS → hls；无 HLS 有 TS → ts；
        // Sink 缺失/未知 → 设备族默认（WMP 族 ts，其余 hls；11-10）。
        // 自动降级（11-09）：上一轮判定 hls 播不出时，_forcedRelayFormat 强制 ts。
        final relayFormat =
            _forcedRelayFormat ?? relayFormatFor(sink, family: family);
        _sessionRelayFormat = relayFormat;
        final relayed = await _transcodeResolve(
          // 编码提示合并（显式 stream.codec 优先，嗅探其次）：ts 档据此决定
          // 是 -c copy 还是重编码（HEVC/AV1 必须转 H.264）。
          _mediaWithCodecHint(media, sourceType.codecHint),
          relayFormat: relayFormat,
          relaySubtitleUrl: subtitleUrl,
          // 电视侧可达地址按「到目标设备的路由源 IP」生成（多网卡/运营商
          // NAT 下枚举网卡会落回 127.0.0.1，只有 airpin 改写 loopback 能播）。
          relayHostHint: target.host,
        );
        if (relayed != null && relayed.isNotEmpty) {
          return (url: relayed, sourceType: sourceType, viaRelay: true);
        }
        // 中继不可用：回退代理/直投（记时间线，不算投屏失败）。
        CastDiagnostics.instance.recordTimeline(
            '本机转码不可用，回退${media.headers.isNotEmpty ? '代理' : '直投'}');
        return _proxyOrDirect(
          media,
          target: target,
          urlSuffixMode: urlSuffixMode,
          sourceType: sourceType,
          subtitleUrl: subtitleUrl,
        );
      case CastRoute.proxy:
        return _proxyOrDirect(
          media,
          target: target,
          urlSuffixMode: urlSuffixMode,
          sourceType: sourceType,
          subtitleUrl: subtitleUrl,
        );
      case CastRoute.direct:
        return (url: media.url, sourceType: sourceType, viaRelay: false);
    }
  }

  /// 防盗链直链经本机代理中转（电视无法自带 Referer/UA）；代理不可用回退
  /// 直投。[sourceType] 给定时作登记 hint，上游不再重复嗅探。
  Future<_PreparedPlayUrl> _proxyOrDirect(
    CastMedia media, {
    required CastTarget target,
    required CastUrlSuffixMode urlSuffixMode,
    CastMediaType? sourceType,
    Uri? subtitleUrl,
    String? hintMime,
  }) async {
    final proxied = media.headers.isEmpty
        ? null
        : await _proxyResolve(
            media.url,
            media.headers,
            targetHost: target.host,
            hintMime: sourceType?.mime ?? hintMime,
            urlSuffixMode: urlSuffixMode,
            subtitleUrl: subtitleUrl?.toString(),
          );
    return (url: proxied ?? media.url, sourceType: sourceType, viaRelay: false);
  }

  /// 调用本机转码挂点（M5-0）。任何失败只进 ErrorLog 并返回 null——
  /// 转码失败走选路回退，不算投屏失败（原始异常不与用户见面）。
  Future<String?> _transcodeResolve(
    CastMedia media, {
    String? relayFormat,
    Uri? relaySubtitleUrl,
    String relayHostHint = '',
  }) async {
    final resolver = transcodeResolver;
    if (resolver == null) return null;
    try {
      return await resolver(
        media,
        relayFormat: relayFormat,
        relaySubtitleUrl: relaySubtitleUrl,
        relayHostHint: relayHostHint,
      );
    } on Exception catch (e, stack) {
      ErrorLog.instance.record('投屏兼容模式转码', e, stack);
      return null;
    }
  }

  String _routeLabel(CastRoute route) => switch (route) {
        CastRoute.direct => '直投',
        CastRoute.proxy => '本机代理',
        CastRoute.relay => '本机转码',
      };

  /// 剧封面 → DIDL `upnp:albumArtURI`（R1，11-07-cast-cover-art）：空串/
  /// 非法 URL/非 http(s) 一律 null——不带封面的源 DIDL 零变化（接收端只认
  /// http(s)，写了也提取不出）。
  static Uri? _albumArtUri(String coverUrl) {
    final raw = coverUrl.trim();
    if (raw.isEmpty) return null;
    final uri = Uri.tryParse(raw);
    if (uri == null || !uri.hasScheme) return null;
    final scheme = uri.scheme.toLowerCase();
    return (scheme == 'http' || scheme == 'https') ? uri : null;
  }

  /// 配方链按产物形态调整（R2 DIDL 对齐）：中继 TS 档产物把默认 standard
  /// 模板升级为 sinkEntry——Sink 有 TS 条目时照抄设备第 4 段（WMP 族对
  /// protocolInfo 第 4 段敏感），无条目时模板自身回落 standard。其余产物
  /// 形态走 [CastRecipeStore.fallbackChain] 原样。
  List<CastRecipe> _recipeChainFor(
    CastTarget target,
    Set<String> sink, {
    required bool viaRelay,
    required String productMime,
  }) {
    final chain = recipes.fallbackChain(target,
        sink: sink.toList(), profile: profiles?.lookup(target.id));
    if (viaRelay) {
      // 11-09：转码产物一律改成「真实能力」模板（ts → sinkEntry，
      // hls → stream：OP=00/CI=1），不再对不可 seek 的流转发 OP=01+FLAGS。
      return upgradeChainForRelayProduct(chain, ts: isTsMime(productMime));
    }
    return chain;
  }

  /// 字幕投送前的准备：带源站头的字幕必须经代理；SRT 是否转 VTT 按协议
  /// 分流（M5-1）——DLNA 保持 SRT 原样（修正「转 VTT 却在 DIDL 声明
  /// text/srt」的错配），Chromecast 转 VTT（Chromecast 只认 VTT）。
  Future<Uri?> _prepareSubtitle(CastTarget target, CastMedia media,
      {CastUrlSuffixMode urlSuffixMode = CastUrlSuffixMode.withExtension}) async {
    final raw = media.subtitleUrl;
    if (raw.isEmpty) return null;
    final uri = Uri.tryParse(raw);
    if (uri == null) return null;
    final isChromecast = target.protocol == CastProtocol.chromecast;
    final needsProxy = media.headers.isNotEmpty ||
        (isChromecast && raw.toLowerCase().endsWith('.srt'));
    if (!needsProxy) return uri;
    final proxied = await _castProxy.registerSubtitle(raw,
        headers: media.headers,
        targetHost: target.host,
        urlSuffixMode: urlSuffixMode,
        convertToVtt: isChromecast);
    return proxied == null ? uri : Uri.tryParse(proxied);
  }

  LocalMediaServer get mediaServer => _mediaServer;

  /// 投到指定目标。同 IP 存在另一协议目标且首选失败时自动降级重试一次
  /// （如 Chromecast 就绪超时 → 同 IP 的 DLNA MediaRenderer）。
  ///
  /// 降级链位次 [castProtocolFallbackRank]：dlna → chromecast → airplay
  /// （AirPlay 一期排末位——经典 `/play` 接收端覆盖面最小，其余协议优先）。
  /// 无 UI 直投：把指定剧集（[sourceId]/[episode]）投到「上次投屏设备」。
  ///
  /// 供 `aquan-cli cast <seriesId>` 使用（AI 助手/脚本全自动投屏）：解析走
  /// [defaultResumeProvider]（新鲜 URL + 加密中继，与恢复同款链路），目标设备
  /// 复用最近会话记录。返回错误文案（null = 成功）。
  Future<String?> castSeriesToLastTarget(String sourceId, int episode) async {
    final record = sessionRecorder?.lastSession;
    if (record == null) return '没有投屏记录，请先在应用里投屏一次';
    final target = record.resolveTarget();
    if (target == null) return '上次投屏设备不可用，请重新投屏';
    final provider = defaultResumeProvider;
    if (provider == null) return '本机转码初始化未完成，请稍后再试';
    final positioned = CastSessionRecord(
      targetPersistJson: record.targetPersistJson,
      title: record.title,
      mediaUrl: record.mediaUrl,
      positionMs: 0,
      sourceId: sourceId,
      episodeIndex: episode,
      endedAt: record.endedAt,
    );
    try {
      final media = await provider(positioned);
      if (media == null) return '该剧集解析不到可投的流';
      await castTo(target, media);
      return null;
    } on CastException catch (e) {
      ErrorLog.instance.record('投屏 · CLI 直投', e, StackTrace.current);
      return e.message;
    } on Exception catch (e, stack) {
      ErrorLog.instance.record('投屏 · CLI 直投', e, stack);
      return '恢复/投送失败，请重新投屏';
    }
  }

  Future<void> castTo(CastTarget target, CastMedia media) async {
    try {
      await _castWith(target, media);
    } on Exception {
      final alt = _devices
          .where((d) =>
              d.host.isNotEmpty &&
              d.host == target.host &&
              d.protocol != target.protocol)
          .toList()
        ..sort((a, b) => castProtocolFallbackRank(a.protocol)
            .compareTo(castProtocolFallbackRank(b.protocol)));
      if (alt.isEmpty) rethrow;
      // 降级目标再失败则直接抛给 UI（不再继续找）。
      await _castWith(alt.first, media);
    }
  }

  Future<void> _castWith(CastTarget target, CastMedia media) async {
    // 会话恢复记录取选路前的源 URL（R1.1）：media 在下方会被改写成代理/
    // 中继产物地址，token 重启后失效，记录必须留可重投的原始地址。调用方
    // 已带 recordUrl（恢复重解析产物，url 是随会话回收即死的中继产物）时
    // 以它为准（11-08-resume-reparse）；下方重建会丢掉 recordUrl，这里一并
    // 捕获。sourceId 同理（恢复重新解析的定位键，记录重写不能丢）。
    final sessionSourceUrl = media.recordUrl ?? media.url;
    final sessionSourceId = media.sourceId;
    final sessionIsMirror = media.isMirror;
    final sessionIsLocalFile = media.isLocalFile;
    _sessionRecorded = false;
    _pollTimer?.cancel();
    _currentDevice = target;
    _userStopping = false;
    _state = CastSessionState.connecting;
    _lastTimelineState = '';
    _lastTransportState = '';
    _sessionSink = const <String>{};
    _sessionPreflightOk = false;
    // 诊断会话（M0）：重置会话级采集，保留发现阶段证据。纯采集，不影响链路。
    CastDiagnostics.instance.beginSession(
      deviceName: target.name,
      protocol: target.protocol.name,
    );
    CastDiagnostics.instance
        .recordTimeline('connecting → ${target.name}（${target.host}）');
    notifyListeners();

    final remembered = recipes.lookup(target);
    // URL 形态旋钮（M1 / 回滚点 R1）与兼容模式三态（M5-0 / AC-22）：都来自
    // 按 UDN 记忆的配方。此时预检未跑（Sink 未知），共享层只能命中 nosink
    // 键——尽力而为；预检后的配方链按真实 Sink 查询（udn 精确层命中则与
    // Sink 无关）。
    final suffixMode =
        remembered?.urlSuffixMode ?? CastUrlSuffixMode.withExtension;
    final transcodeMode = remembered?.transcodeMode ?? CastTranscodeMode.auto;

    // 端点刷新（11-11 真机）：airpin / IQIYI-WMP / Cling 重启后会换 control
    // 端口，SSDP 缓存里的旧记录会让所有 SOAP 动作被回 `-1 Invalid Action`、
    // 连接被拒或 500。投送前按 location 重取一次描述，端点有变就用新的；
    // 失败（超时/描述 404）静默保持旧记录，不阻断投屏。
    if (target.dlna != null && target.dlna!.location.isNotEmpty) {
      final old = target.dlna!;
      final fresh = await (describeFetcher ?? fetchDlnaDescription)(
        old.location,
      );
      if (fresh != null &&
          (fresh.controlUrl != old.controlUrl ||
              fresh.connectionManagerUrl != old.connectionManagerUrl ||
              fresh.eventSubUrl != old.eventSubUrl ||
              fresh.serviceType != old.serviceType)) {
        CastDiagnostics.instance.recordTimeline(
            '设备描述刷新：controlUrl ${old.controlUrl} → ${fresh.controlUrl}'
            '（${old.serviceType} → ${fresh.serviceType}）');
        target = CastTarget.dlna(DlnaDevice(
          udn: old.udn,
          friendlyName: old.friendlyName,
          modelName: fresh.modelName.isEmpty ? old.modelName : fresh.modelName,
          manufacturer:
              fresh.manufacturer.isEmpty ? old.manufacturer : fresh.manufacturer,
          serviceType: fresh.serviceType,
          controlUrl: fresh.controlUrl,
          renderingControlUrl: fresh.renderingControlUrl.isEmpty
              ? old.renderingControlUrl
              : fresh.renderingControlUrl,
          connectionManagerUrl: fresh.connectionManagerUrl.isEmpty
              ? old.connectionManagerUrl
              : fresh.connectionManagerUrl,
          eventSubUrl:
              fresh.eventSubUrl.isEmpty ? old.eventSubUrl : fresh.eventSubUrl,
          location: old.location,
          online: old.online,
        ));
        _currentDevice = target;
      }
    }

    // transport 与能力预检提前（M5-0）：兼容模式选路（直投/代理/本机转码）
    // 依赖设备 Sink 的 HLS 支持判定，必须在媒体准备之前完成。
    final transport = _transport = _transportFactory(target);
    // DLNA 走兼容层（预检 → 配方链 → setUri → Play 门控 → Seek 容错）；
    // Chromecast 与所有不实现该能力的 transport 保持既有标准序列。
    final compat =
        transport is CastCompatTransport ? transport as CastCompatTransport : null;
    // Sink 提升到 try 外：失败路径的配方清空也要按同一口径（M3 双层键）。
    var sink = const <String>{};
    // 深度诊断重试（R1.2）：一次性开关在投送时消费；catch 里据此跳过
    // 配方清空（扫描失败 ≠ 既有配方失败，配方记忆双向都不动）。
    var scanMode = false;
    try {
      if (compat != null) {
        try {
          sink = await compat.preflight().timeout(const Duration(seconds: 2));
          _sessionSink = sink;
          _sessionPreflightOk = true;
          CastDiagnostics.instance.recordSinks(sink);
          CastDiagnostics.instance
              .recordTimeline('能力预检完成：Sink ${sink.length} 条');
        } on Exception catch (e) {
          ErrorLog.instance.record('投屏能力预检', e, StackTrace.current);
        }
      }

      // 字幕先于媒体登记准备（M5-1）：代理/本地服务的媒体响应要靠登记好的
      // 字幕 URL 补 CaptionInfo.sec 第三通道。
      final subtitleUri =
          await _prepareSubtitle(target, media, urlSuffixMode: suffixMode);

      // M5-0/M5-3 兼容模式选路（直投 / 本机代理 / 本机转码）。
      // 本地文件、镜像流与 Chromecast 路径不受选路影响。
      // 源媒体先留档：下面 media 会被替换成产物副本（档位降级要回到源重投）。
      _sourceMedia = media;
      final prepared = await _preparePlayUrl(
        target,
        media,
        sink: sink,
        transcodeMode: transcodeMode,
        urlSuffixMode: suffixMode,
        subtitleUrl: subtitleUri,
      );
      final playUrl = prepared.url;
      media = CastMedia(
        url: playUrl,
        title: media.title,
        coverUrl: media.coverUrl,
        position: media.position,
        episodeIndex: media.episodeIndex,
        episodeCount: media.episodeCount,
        localPath: media.localPath,
        headers: media.headers,
        subtitleUrl: subtitleUri?.toString() ?? '',
        isMirror: media.isMirror,
        mimeHint: media.mimeHint,
        duration: media.duration,
        // 11-09 二期：prepared.viaRelay 只表示「本次选路做了转码」；播放页
        // 预起中继后直投的产物（media.viaRelay=true、prepared=false）必须
        // 保留标记，否则降级判定与诊断都会把它当普通直投。
        viaRelay: prepared.viaRelay || media.viaRelay,
        relaySession: media.relaySession,
        codecHint: media.codecHint,
      );
      _currentMedia = media;
      _traceTarget(media);

      // M1-1：媒体类型三级判定（显式 hint → URL 扩展名 → 内容嗅探），
      // 替代旧 `_mimeForCast`（.m3u8 判 video/mp2t、无扩展名兜底 video/mp4）。
      // 设备 Sink 只参与「拼写选择」，绝不用它覆盖判定结果（AC-13）。
      // 嗅探到 HTML/JSON 会抛 CastException：投屏前就报「这个地址不是视频」。
      // 选路阶段已判定源类型时直接复用（直投同 URL、代理不改 mime）；
      // 本机转码产物按产物 URL 形态判 hint（hls 档恒 HLS，ts 档 stream.ts）。
      final mediaType = prepared.viaRelay
          ? await resolveCastMediaType(
              url: Uri.parse(playUrl),
              hintMime: _relayProductMimeHint(playUrl),
              sinkMimes: sink,
            )
          : prepared.sourceType ??
              await resolveCastMediaType(
                url: Uri.parse(playUrl),
                hintMime: media.mimeHint,
                sinkMimes: sink,
                sniffHead: defaultSniffHead,
              );
      CastDiagnostics.instance
          .recordTimeline('媒体类型：${mediaType.mime}（${mediaType.fileName}）');
      final durationText =
          media.duration == null ? null : formatUpnpTime(media.duration!);
      CastRecipe? succeeded;
      // 深度诊断重试（R1.2）：一次性开关在此消费（无论成败）。仅 DLNA
      // transport 支持扫描（Chromecast/AirPlay 无 DIDL/模板组合概念）。
      final scanTransport = transport is DlnaTransport ? transport : null;
      scanMode = _deepScanArmed && scanTransport != null && compat != null;
      if (scanMode) _deepScanArmed = false;
      if (compat != null) {
        final loadRequest = CastLoadRequest(
          url: Uri.parse(playUrl),
          title: media.title,
          duration: durationText, // 真实时长才有（AC-27）
          subtitleUrl: media.subtitleUrl.isEmpty
              ? null
              : Uri.tryParse(media.subtitleUrl),
          position: media.position,
          didl: DidlRequest(
            uri: Uri.parse(playUrl),
            title: media.title,
            mimeType: mediaType.mime,
            duration: media.duration,
            live: mediaType.live,
            subtitleUri: media.subtitleUrl.isEmpty
                ? null
                : Uri.tryParse(media.subtitleUrl),
            albumArtUrl: _albumArtUri(media.coverUrl),
            headers: media.headers,
          ),
          // M3 配方链（design §4.5）：udn → model(+sinkHash) → 画像预设 → 梯度；
          // 中继 TS 档产物把默认 standard 模板升级 sinkEntry（R2）。
          // 扫描模式不消费它（scanAll 自建全组合链）。
          recipes: _recipeChainFor(
            target,
            sink,
            viaRelay: prepared.viaRelay,
            productMime: mediaType.mime,
          ),
          protocolInfo: sink,
        );
        if (scanMode) {
          final result = await scanTransport.scanAll(loadRequest);
          CastDiagnostics.instance.recordScanSummary(result.summaryLines());
          if (!result.anyAccepted) {
            throw SoapException(
                '深度诊断扫描：${result.attempts.length} 个组合均未被受理');
          }
        } else {
          succeeded = await compat.load(loadRequest);
        }
      } else {
        await transport.setUri(
          Uri.parse(playUrl),
          title: media.title,
          duration: durationText,
          subtitleUrl: media.subtitleUrl.isEmpty
              ? null
              : Uri.tryParse(media.subtitleUrl),
        );
        if (media.position > const Duration(seconds: 3)) {
          // 起播后可能被设备忽略：投完再 seek 一次（部分盒子只认这条顺序）。
          await transport.play();
          try {
            await transport.seekTo(media.position);
          } on Exception {
            // 设备不支持 Seek：从头播。
          }
        } else {
          await transport.play();
        }
      }
      if (succeeded != null) await _rememberRecipe(target, succeeded, sink: sink);
      _state = CastSessionState.casting;
      // 档位降级窗口（11-09）：首投也从这里起算（_pushMedia 只覆盖连播换集）。
      _mediaCastAt = DateTime.now();
      _mediaRequestBaseline = CastDiagnostics.instance.mediaRequests.length;
      _relayFormatFallbackDone = false;
      // 播放页预起中继后直投的会话（加密分集 / resolvePlay）也要参与档位
      // 降级：之前只在「选路 relay」分支赋值，这类会话永远不被判定
      // （极光TV 真机：PLAYING 但零取流且无降级记录）。
      if (prepared.viaRelay || media.viaRelay) {
        _sessionRelayFormat =
            playUrl.toLowerCase().endsWith('.ts') ? 'ts' : 'hls';
        CastDiagnostics.instance.activeRelaySession = media.relaySession;
      }
      CastDiagnostics.instance.recordTimeline(scanMode
          ? 'casting（深度诊断扫描完成，投屏命令已接受；配方记忆未改写）'
          : 'casting（投屏命令已接受'
              '${succeeded == null ? '' : '，配方 ${succeeded.didl.name}'}）');
      notifyListeners();
      _startPolling();
      unawaited(_startGena(target));
      // 会话恢复记录（R1.1）：投送成功写全量。尽力而为，失败只进日志，
      // 绝不让记录写入拖垮已成功的投屏。
      await _recordSessionStart(
        target,
        media,
        sourceUrl: sessionSourceUrl,
        sourceId: sessionSourceId,
        isMirror: sessionIsMirror,
        isLocalFile: sessionIsLocalFile,
      );
    } on Exception catch (e) {
      // 命中配方失败一次即清空，下次投屏重回梯度扫描；深度诊断扫描路径
      // 例外——扫描失败不代表既有配方失败，配方记忆双向都不动（R1.3）。
      if (remembered != null && !scanMode) await _forgetRecipe(target);
      CastDiagnostics.instance.recordTimeline('投屏失败：$e');
      _state = CastSessionState.idle;
      // transport 已提前创建（M5-0）：失败路径同样要释放底层连接。
      _transport?.close();
      _transport = null;
      _currentDevice = null;
      notifyListeners();
      rethrow;
    }
  }

  /// 诊断目标字段（M0.5 接真实值）：本机伺服（本地文件/代理/本机转码）时
  /// 投屏 URL 的 host 就是按目标设备解析出的路由源 IP（per-device IP）；
  /// 直投公网 URL 时 IP/端口为空态。纯采集。
  ///
  /// 中继产物（viaRelay）的 IP/端口随后由 [CastRelayProbe] 按 Go
  /// `castRelayStatus` 回传的监听值转写校正（R3）——这里先按产物 URL
  /// 取值，防盗链源不再误报成代理端口。
  void _traceTarget(CastMedia media) {
    final uri = Uri.tryParse(media.url);
    final servedLocally =
        media.isLocalFile || media.headers.isNotEmpty || media.viaRelay;
    int? servingPort;
    if (media.isLocalFile) {
      servingPort = _mediaServer.port;
    } else if (media.viaRelay) {
      servingPort = uri?.port;
    } else if (media.headers.isNotEmpty) {
      servingPort = _castProxy.port;
    }
    CastDiagnostics.instance.recordTimeline(
        '媒体地址：${media.isLocalFile ? '本地文件' : media.viaRelay ? '本机转码' : (media.headers.isNotEmpty ? '本机代理' : '直投')}');
    // 产物地址单独记一行（11-10）：报告里「投屏 URL」可能被后续重投覆盖，
    // 而 SOAP CurrentURI 是权威投送地址——把两者对齐才能一眼看出
    // 「电视拿到的到底是不是本机中继产物」（报告 A 的 127.0.0.1 就是这么漏的）。
    if (media.viaRelay && uri != null) {
      final session = media.relaySession.isEmpty ? '未知' : media.relaySession;
      CastDiagnostics.instance
          .recordTimeline('产物地址：${uri.host}:${uri.port}${uri.path}（session=$session）');
    }
    CastDiagnostics.instance.setTarget(
      selectedIp: servedLocally ? uri?.host : null,
      mediaPort: servingPort,
      mediaUrl: media.url,
    );
  }

  /// 配方记忆是尽力而为：写盘失败只进日志，绝不让已成功的投屏失败。
  /// 成功后同步更新设备画像并落盘（M3 时序：remember(recipe) → profiles）。
  ///
  /// 兼容模式三态是用户显式偏好（AC-22）：成功配方若来自梯度/共享层
  /// （默认 auto），记忆时沿用设备已有配方里的三态，避免把用户设置的
  /// always/never 冲掉；成功配方本身带非 auto 三态时以它为准。
  Future<void> _rememberRecipe(
    CastTarget target,
    CastRecipe recipe, {
    Set<String> sink = const <String>{},
  }) async {
    final mode = recipe.transcodeMode != CastTranscodeMode.auto
        ? recipe.transcodeMode
        : recipes.lookup(target)?.transcodeMode ?? CastTranscodeMode.auto;
    try {
      await recipes.remember(
          target, recipe.copyWith(transcodeMode: mode), sink: sink.toList());
    } on Exception catch (e) {
      ErrorLog.instance.record('投屏配方记忆', e, StackTrace.current);
    }
    await _rememberProfile(target);
  }

  /// 设备画像同步（尽力而为）：按本会话观测构建画像并落盘。
  ///
  /// 投屏成功时立即记一次（serviceType/Sink/预检证据）；电视取流记录随
  /// 会话推进变全，会话收尾（[CastDiagnostics] 数据仍在）再刷一次
  /// fetchedStream / rangeSupport。
  Future<void> _rememberProfile(CastTarget target) async {
    final store = profiles;
    final dlna = target.dlna;
    if (store == null || dlna == null) return;
    try {
      final diag = CastDiagnostics.instance;
      await store.remember(buildProfile(
        dlna,
        sink: _sessionSink.toList(),
        preflightOk: _sessionPreflightOk,
        mediaRequests: diag.mediaRequests,
        soapTraces: diag.soapTraces,
      ));
    } on Exception catch (e) {
      ErrorLog.instance.record('投屏画像记忆', e, StackTrace.current);
    }
  }

  Future<void> _forgetRecipe(CastTarget target) async {
    try {
      await recipes.forget(target);
    } on Exception catch (e) {
      ErrorLog.instance.record('投屏配方重置', e, StackTrace.current);
    }
  }

  /// 投送成功 → 写会话恢复记录（R1.1）。镜像（无 URL 可恢复）与本地文件
  /// （记录结构不含路径，恢复不了）会话跳过；[sourceUrl] 是选路前的源
  /// URL；[sourceId] / media.episodeIndex 是恢复重新解析的定位键
  /// （11-08-resume-reparse）。失败只进 ErrorLog，绝不让记录拖垮投屏成功路径。
  Future<void> _recordSessionStart(
    CastTarget target,
    CastMedia media, {
    required String sourceUrl,
    required String sourceId,
    required bool isMirror,
    required bool isLocalFile,
  }) async {
    final recorder = sessionRecorder;
    if (recorder == null || isMirror || isLocalFile || sourceUrl.isEmpty) {
      return;
    }
    try {
      await recorder.recordSession(
        target: target,
        title: media.title,
        mediaUrl: sourceUrl,
        positionMs: media.position.inMilliseconds,
        sourceId: sourceId,
        episodeIndex: media.episodeIndex,
      );
      _sessionRecorded = true;
    } on Exception catch (e, stack) {
      ErrorLog.instance.record('投屏会话记录', e, stack);
    }
  }

  /// 轮询进度 → 恢复记录（R1.1）：10s 节流在 recorder 实现内（CastStore），
  /// 控制器只透传；失败只进日志。仅已记录会话调用（[_sessionRecorded] 守卫）。
  Future<void> _recordSessionPosition(Duration position) async {
    final recorder = sessionRecorder;
    if (recorder == null) return;
    try {
      await recorder.updateSessionPosition(position.inMilliseconds);
    } on Exception catch (e, stack) {
      ErrorLog.instance.record('投屏会话进度记录', e, stack);
    }
  }

  /// 恢复上次投屏会话（R1.2）：读记录 → 重建 CastTarget → 复用 [castTo]
  /// 的标准投屏序列（选路/配方/同 IP 降级链照常，不新加报文）→ 记录位置
  /// >3s 时既有序列自动 seek（DLNA compat.load 与标准三件套都带 position）。
  /// 记录带 sourceId 时优先经 [resumeProvider] 重新解析分集拿新鲜 URL
  /// （11-08-resume-reparse，跨天可用）；解析失败回退记录 URL 现状分支。
  ///
  /// 返回 false = 无可恢复记录（未注入 recorder / 无记录 / 记录或目标
  /// 损坏）——调用方应静默清理记录并隐藏恢复入口。恢复尝试失败时异常
  /// 原样上抛（与 [castTo] 同语义；UI 显示固定文案「恢复失败，请重新投屏」，
  /// 原始异常只进 ErrorLog）。
  Future<bool> resumeLastSession() => _replayLastSessionRecord();

  /// 从恢复记录重投（[resumeLastSession] 与中断自动恢复 [_handleSessionLost]
  /// 共用的私有链路，R3）：读记录 → 重建 target → 走 [castTo] 标准投屏序列
  /// （选路/配方/同 IP 降级链照常，不新加报文）→ 记录位置 >3s 由既有序列
  /// 自动 seek——lastSession 在会话中被持续更新，天然就是「最后位置」。
  ///
  /// 重新解析分支（11-08-resume-reparse）：记录带 sourceId 且注入了
  /// [resumeProvider] 时优先重新解析分集产出新鲜媒体（红果直链带时效签名，
  /// 跨天/跨会话必失效）；返回 null / 抛异常（只进 ErrorLog）→ 回退记录 URL
  /// 现状分支。position 接续逻辑不变：无论哪条分支都用记录位置，标准序列
  /// >3s 自动 seek。
  ///
  /// 返回 false = 无可恢复记录（未注入 recorder / 无记录 / 记录或目标损坏）。
  /// 重投失败异常原样上抛（与 [castTo] 同语义），由调用方决定呈现方式。
  Future<bool> _replayLastSessionRecord() async {
    final record = sessionRecorder?.lastSession;
    if (record == null) return false;
    final target = record.resolveTarget();
    if (target == null) return false;
    if (record.mediaUrl.isEmpty) return false;
    // 回退基线（现状分支）：记录 URL。sourceId / episodeIndex 一并透传——
    // 恢复重投成功后记录会被重写，定位键不能在这里丢（provider 缺席/失败的
    // 后续恢复仍可重试重新解析）。
    var media = CastMedia(
      url: record.mediaUrl,
      title: record.title,
      position: Duration(milliseconds: record.positionMs),
      sourceId: record.sourceId,
      episodeIndex: record.episodeIndex,
    );
    final provider = resumeProvider;
    if (provider != null && record.sourceId.isNotEmpty) {
      try {
        final fresh = await provider(record);
        if (fresh != null) {
          media = CastMedia(
            url: fresh.url,
            title: fresh.title,
            coverUrl: fresh.coverUrl,
            // position 接续逻辑不变：一律用记录位置（provider 不感知进度）。
            position: Duration(milliseconds: record.positionMs),
            episodeIndex: fresh.episodeIndex,
            episodeCount: fresh.episodeCount,
            localPath: fresh.localPath,
            headers: fresh.headers,
            recordUrl: fresh.recordUrl,
            subtitleUrl: fresh.subtitleUrl,
            isMirror: fresh.isMirror,
            mimeHint: fresh.mimeHint,
            duration: fresh.duration,
            viaRelay: fresh.viaRelay,
            codecHint: fresh.codecHint,
            // provider 产物不带 sourceId（按记录解析）——重写记录的定位键
            // 以记录为准。
            sourceId: record.sourceId,
          );
        }
      } on Exception catch (e, stack) {
        ErrorLog.instance.record('投屏会话恢复解析', e, stack);
      }
    }
    await castTo(target, media);
    return true;
  }

  /// 尝试在当前会话上连投下一集（不回 idle，避免状态闪烁）。
  /// 失败（无下一集/推送出错）返回 false，由调用方走 onRemoteStopped。
  ///
  /// M3-5：DLNA 连播换集走 `compat.load()`（预检 → 配方链 → setUri →
  /// Play 门控），不再用旧 `transport.setUri()` 三件套——恢复 full 变体、
  /// 真实 duration 写入 DIDL 与空 metadata 门控（M2 遗留问题收口，
  /// AC-27/AC-11 在连播路径同样成立）。
  Future<bool> _tryAdvance() async {
    final provider = onNextEpisode;
    final device = _currentDevice;
    final transport = _transport;
    if (provider == null || device == null || transport == null) return false;
    _autoAdvancing = true;
    try {
      // 注意：不要写 provider().timeout(..., onTimeout: () => null)——
      // async 闭包的运行时类型是 Future<CastMedia> Function()，timeout 的
      // onTimeout 会被校验为 FutureOr<CastMedia>，返回 null 触发 TypeError。
      // 超时直接抛 TimeoutException，由下面的 catch 归一为「连投失败」。
      final next = await provider().timeout(const Duration(seconds: 10));
      if (next == null) return false;
      return await _pushMedia(device, transport, next);
    } on Exception {
      // 提供器超时/推送失败：按「没有下一集」处理，走远端停止路径。
      return false;
    } finally {
      _autoAdvancing = false;
    }
  }

  /// 遥控器「下一集」：复用连播链路（预取/选路/中继语义与自动连投一致，
  /// 在当前 transport 上换集，不重复起停中继）。
  ///
  /// 与自动连投的差异：手动换集时当前集仍在播，提供器返回 null 或推送
  /// 失败都**不**归一为远端停止路径——会话保持，返回 false 由 UI 给固定文案。
  Future<bool> advanceNextEpisode() {
    if (_autoAdvancing) return Future<bool>.value(false);
    return _tryAdvance();
  }

  /// 遥控器跳集（上一集/任意 delta）：走 [onEpisodeJump] 取目标媒体后
  /// 复用 [_pushMedia]（连播推送链路）。未注入 / delta == 0 / 提供器返回
  /// null（越界）/ 推送失败都返回 false；会话保持，UI 给固定文案。
  Future<bool> jumpEpisode(int delta) async {
    final provider = onEpisodeJump;
    final device = _currentDevice;
    final transport = _transport;
    if (provider == null || device == null || transport == null) return false;
    if (delta == 0) return false;
    if (_autoAdvancing) return false;
    _autoAdvancing = true;
    try {
      // 与 _tryAdvance 同口径：不带 onTimeout（泛型协变坑，见 P1a 契约）。
      final media = await provider(delta).timeout(const Duration(seconds: 10));
      if (media == null) return false;
      return await _pushMedia(device, transport, media);
    } on Exception {
      return false;
    } finally {
      _autoAdvancing = false;
    }
  }

  /// 把 [next] 推到当前会话的 [transport] 上（连播/手动换集共用）：
  /// URL 选路 → compat.load 或标准序列 → 更新会话媒体与进度。推送期间
  /// [_autoAdvancing] 为 true（调用方设置），轮询到 STOPPED 不会误判为
  /// 电视端主动停止。
  ///
  /// [timelineLabel] 覆盖时间线里的动作文案（档位降级重投不是「连播下一集」）。
  Future<bool> _pushMedia(
    CastTarget device,
    CastTransport transport,
    CastMedia next, {
    String? timelineLabel,
  }) async {
    // URL 形态旋钮与兼容模式三态沿用会话配方（连播与首投同选路）。
    final remembered = recipes.lookup(device);
    final suffixMode =
        remembered?.urlSuffixMode ?? CastUrlSuffixMode.withExtension;
    final transcodeMode = remembered?.transcodeMode ?? CastTranscodeMode.auto;
    final compat =
        transport is CastCompatTransport ? transport as CastCompatTransport : null;
    // 预检刷新 Sink（失败沿用会话内记忆，不阻断连播）；提前到媒体准备
    // 之前——兼容模式选路依赖 Sink 判定（M5-3）。
    var sink = _sessionSink;
    if (compat != null) {
      try {
        final probed =
            await compat.preflight().timeout(const Duration(seconds: 2));
        if (probed.isNotEmpty) {
          sink = probed;
          _sessionSink = probed;
        }
      } on Exception {
        // 预检失败不阻断连播。
      }
    }
    final subtitleUri = await _prepareSubtitle(device, next,
        urlSuffixMode: suffixMode);
    // 记住源媒体（降级重投用：产物 URL 带 viaRelay，不能再转码）。
    _sourceMedia = next;
    // 连播与首投共用同一段选路代码（M5-0/M5-3）。
    final prepared = await _preparePlayUrl(
      device,
      next,
      sink: sink,
      transcodeMode: transcodeMode,
      urlSuffixMode: suffixMode,
      subtitleUrl: subtitleUri,
    );
    final playUrl = prepared.url;
    // 连播换集：诊断目标只换 URL（IP/端口仍是本会话的服务）。
    CastDiagnostics.instance.setTarget(mediaUrl: playUrl);
    CastDiagnostics.instance
        .recordTimeline(timelineLabel ?? '连播下一集：${next.title}');
    if (compat != null) {
      // 媒体类型判定：选路已判定源类型时复用；本机转码产物按产物 URL
      // 形态判 hint（与首投同口径）。
      final mediaType = prepared.viaRelay
          ? await resolveCastMediaType(
              url: Uri.parse(playUrl),
              hintMime: _relayProductMimeHint(playUrl),
              sinkMimes: sink,
            )
          : prepared.sourceType ??
              await resolveCastMediaType(
                url: Uri.parse(playUrl),
                hintMime: next.mimeHint,
                sinkMimes: sink,
                sniffHead: defaultSniffHead,
              );
      CastDiagnostics.instance.recordTimeline(
          '连播媒体类型：${mediaType.mime}（${mediaType.fileName}）');
      final succeeded = await compat.load(CastLoadRequest(
        url: Uri.parse(playUrl),
        title: next.title,
        duration:
            next.duration == null ? null : formatUpnpTime(next.duration!),
        subtitleUrl: subtitleUri,
        position: next.position,
        didl: DidlRequest(
          uri: Uri.parse(playUrl),
          title: next.title,
          mimeType: mediaType.mime,
          duration: next.duration,
          live: mediaType.live,
          subtitleUri: subtitleUri,
          albumArtUrl: _albumArtUri(next.coverUrl),
          headers: next.headers,
        ),
        recipes: _recipeChainFor(
          device,
          sink,
          viaRelay: prepared.viaRelay,
          productMime: mediaType.mime,
        ),
        protocolInfo: sink,
      ));
      if (succeeded != null) {
        await _rememberRecipe(device, succeeded, sink: sink);
      }
    } else {
      // 非 compat transport（Chromecast / 测试假件）：保持既有标准序列。
      await transport.setUri(
        Uri.parse(playUrl),
        title: next.title,
        duration:
            next.duration == null ? null : formatUpnpTime(next.duration!),
        subtitleUrl: subtitleUri,
      );
      await transport.play();
    }
    _currentMedia = CastMedia(
      url: playUrl,
      title: next.title,
      coverUrl: next.coverUrl,
      episodeIndex: next.episodeIndex,
      episodeCount: next.episodeCount,
      localPath: next.localPath,
      headers: next.headers,
      subtitleUrl: subtitleUri?.toString() ?? '',
      isMirror: next.isMirror,
      mimeHint: next.mimeHint,
      duration: next.duration,
      viaRelay: prepared.viaRelay || next.viaRelay,
      relaySession: next.relaySession,
      codecHint: next.codecHint,
    );
    _lastPosition = Duration.zero;
    _lastDuration = Duration.zero;
    // 新媒体的时长未知：清掉上一集的兜底值，避免进度条沿用上一集的刻度。
    _lastKnownDuration = next.duration ?? Duration.zero;
    _polledAt = DateTime.now();
    _lastRunning = true;
    // 档位降级窗口（11-09）：每次投送（含连播换集）重新计时与重新取基线——
    // 上一集的取流记录不能算到本集头上。
    _mediaCastAt = DateTime.now();
    _mediaRequestBaseline = CastDiagnostics.instance.mediaRequests.length;
    _relayFormatFallbackDone = false;
    if (prepared.viaRelay || next.viaRelay) {
      _sessionRelayFormat = playUrl.toLowerCase().endsWith('.ts') ? 'ts' : 'hls';
      CastDiagnostics.instance.activeRelaySession = next.relaySession;
    } else {
      _sessionRelayFormat = null;
      CastDiagnostics.instance.activeRelaySession = '';
    }
    notifyListeners();
    // 连播/换集成功 = 新媒体投送成功（R1.1）：恢复记录跟着走到当前集，
    // 重启后「恢复上次投屏」才与电视实况一致。镜像/本地文件会话内部跳过。
    unawaited(_recordSessionStart(
      device,
      next,
      sourceUrl: next.recordUrl ?? next.url,
      sourceId: next.sourceId,
      isMirror: next.isMirror,
      isLocalFile: next.isLocalFile,
    ));
    return true;
  }

  Future<void> setMute(bool muted) async => _transport?.setMute(muted);

  /// 尝试 GENA 订阅（仅 DLNA 且设备有 eventSubURL）；任何失败都静默回纯轮询。
  Future<void> _startGena(CastTarget target) async {
    final dlna = target.dlna;
    if (dlna == null || dlna.eventSubUrl.isEmpty) return;
    try {
      final gena = _gena = GenaSubscriber(dlna.eventSubUrl);
      final sub = _genaSub = gena.events.listen((poll) {
        if (_state != CastSessionState.casting) return;
        _lastGenaAt = DateTime.now();
        unawaited(_handlePoll(poll, _currentDevice));
      }, onError: (_) {});
      final ok = await gena.subscribe().timeout(const Duration(seconds: 8));
      if (!ok) {
        await sub.cancel();
        if (identical(_gena, gena)) _gena = null;
      }
    } catch (_) {
      // 订阅失败不影响投屏。
    }
  }

  void _startPolling() {
    _pollTimer?.cancel();
    _pollFailures = 0;
    _pollTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      unawaited(_pollOnce());
    });
  }

  Future<void> _pollOnce() async {
    final transport = _transport;
    if (transport == null || _state != CastSessionState.casting) return;
    // GENA 事件活跃时轮询降为 1/5 兜底（断流 15s 自动恢复高频）。
    if (_genaHealthy) {
      _pollTick++;
      if (_pollTick % 5 != 0) return;
    }
    final device = _currentDevice;
    try {
      final poll = await transport.poll().timeout(const Duration(seconds: 3));
      _pollFailures = 0;
      await _handlePoll(poll, device);
      // 档位自动降级（11-09）：HLS 迟迟没有分片取流 → 换 TS 重投一次。
      unawaited(_maybeFallbackRelayFormat());
    } catch (_) {
      // 单次轮询失败容忍（Wi-Fi 抖动）；连续 5 次判失联：先做恰一次中断
      // 自动恢复（R1），不符合条件（镜像/未记录/已尝试过）维持既有
      // onSessionLost 行为（默认路径不变）。
      _pollFailures++;
      if (_pollFailures >= 5) {
        _pollFailures = 0;
        if (device != null) unawaited(_handleSessionLost(device));
      }
    }
  }

  /// 档位降级等待窗口：HLS 正常起播 3–6s 内就会拉首片，10s 仍无分片即判
  /// 接收端不认清单（11-09 二期从 15s 收紧，让极光TV 这类设备更快拿到可播格式）。
  /// 实例字段（非 const）供单测注入更短值。
  Duration relayFormatFallbackDelay = const Duration(seconds: 10);

  /// 中继档位自动降级（11-09）：HLS 会话投送 [_relayFallbackDelay] 后电视仍未
  /// 请求任何分片（只取了清单，或完全没取流），说明接收端不认 HLS——改用 TS
  /// 档重投同一集一次。
  ///
  /// 为什么不只靠 Sink 判定：国产电视的 GetProtocolInfo 普遍不准（有的回空、
  /// 有的把不支持的 mime 也列上），按自述能力猜格式必然漏。这里以「实际有没有
  /// 拉到分片」为证据，符合本项目「按观测能力分叉，不做厂商名分支」的原则。
  Future<void> _maybeFallbackRelayFormat() async {
    if (_relayFormatFallbackDone || _autoAdvancing) return;
    if (_state != CastSessionState.casting) return;
    if (_sessionRelayFormat != 'hls') return;
    final media = _currentMedia;
    final device = _currentDevice;
    final transport = _transport;
    final castAt = _mediaCastAt;
    if (media == null || device == null || transport == null || castAt == null) {
      return;
    }
    if (!media.viaRelay || media.isMirror || media.isLocalFile) return;
    // 重投必须回到**源**媒体：中继产物带 viaRelay，选路会恒直投，转不了码。
    // 播放页预起中继后直投的会话（加密分集 / resolvePlay）里 _sourceMedia 本身
    // 就是产物，此时用 CastMedia.recordUrl 回源（极光TV 真机场景）。
    var source = _sourceMedia;
    if (source == null) return;
    if (source.viaRelay) {
      final origin = source.recordUrl;
      if (origin == null || origin.isEmpty) return;
      source = CastMedia(
        url: origin,
        title: source.title,
        coverUrl: source.coverUrl,
        // 带上当前位置：compat.load 的「起播后补一次 Seek」会按它续播，
        // 用户不会因为降级重投被打回片头。
        position: _lastPosition,
        episodeIndex: source.episodeIndex,
        episodeCount: source.episodeCount,
        headers: source.headers,
        subtitleUrl: source.subtitleUrl,
        mimeHint: source.mimeHint,
        duration: source.duration,
        codecHint: source.codecHint,
        sourceId: source.sourceId,
      );
    }
    if (DateTime.now().difference(castAt) < relayFormatFallbackDelay) return;

    final requests = CastDiagnostics.instance.mediaRequests;
    final fresh = requests.length > _mediaRequestBaseline
        ? requests.sublist(_mediaRequestBaseline)
        : const <MediaRequestTrace>[];
    // 已拉到分片 = HLS 在播：定案，不再检查（避免长片中途误降级）。
    if (fresh.any((r) => r.url.toLowerCase().contains('.ts') && r.isOk)) {
      _relayFormatFallbackDone = true;
      return;
    }

    _relayFormatFallbackDone = true;
    _forcedRelayFormat = 'ts';
    CastDiagnostics.instance.recordTimeline(
        '接收端 ${relayFormatFallbackDelay.inSeconds}s 内未取到 HLS 分片，自动改用 TS 重投');
    // 重投把 _lastPosition 归零：先记下进度，成功后按它续播。
    final resume = _lastPosition;
    // 换集护栏必须先上（11-10）：Stop 之后的 1s 轮询会读到 STOPPED，没有
    // _autoAdvancing 会被判成「电视端主动停止」直接把会话收掉。
    _autoAdvancing = true;
    try {
      // 重投前先让电视停下旧 URI（11-10）：不 Stop 直接覆盖 SetAVTransportURI，
      // 部分固件会把它当「同一媒体的重复加载」继续用旧清单（日志表现为配方
      // 命中后 0 取流）。Stop 失败不影响后续（有的盒子根本不支持）。
      try {
        await transport.stop();
      } on Exception catch (e, stack) {
        ErrorLog.instance.record('投屏档位自动降级 · Stop', e, stack);
      }
      final ok = await _pushMedia(device, transport, source,
          timelineLabel: '档位降级重投（ts）：${media.title}');
      if (!ok) {
        _forcedRelayFormat = null;
        return;
      }
      // 产物校验（11-10）：降级必须真的落到本机中继产物上。若最终投的还是
      // 源地址（`_forceRelay` 未生效/中继启动失败回退直投），立刻回滚并记账，
      // 否则报告里会出现「已降级」却对电视投了 CDN 地址的假象。
      final current = _currentMedia;
      if (current == null || !current.viaRelay) {
        _forcedRelayFormat = null;
        CastDiagnostics.instance
            .recordTimeline('档位降级未命中本机中继产物，已回滚（仍为直投）');
        return;
      }
      // _pushMedia 会把本地进度归零：按重投前的位置恢复（设备不支持 Seek
      // 时也只影响进度条，播放从 0 开始由 compat.load 已尝试过）。
      if (resume > const Duration(seconds: 3)) {
        _lastPosition = resume;
        _polledAt = DateTime.now();
        notifyListeners();
      }
    } on Exception catch (e, stack) {
      _forcedRelayFormat = null;
      ErrorLog.instance.record('投屏档位自动降级', e, stack);
    } finally {
      _autoAdvancing = false;
    }
  }

  /// GENA 事件是否健康（15s 内有推送）。
  bool get _genaHealthy =>
      _gena != null &&
      _gena!.active &&
      _lastGenaAt != null &&
      DateTime.now().difference(_lastGenaAt!) < const Duration(seconds: 15);

  /// 连续轮询失联（≥5 次）的统一入口（R1~R4，任务 11-07-cast-auto-reconnect）：
  /// 符合条件（当前会话已写恢复记录、非镜像、本会话未尝试过、无并发推送）
  /// 时做恰一次自动恢复——先复检门控（R2），目标不可达即静默走既有「电视端
  /// 停止」路径；可达则复用会话恢复链路重投并 seek 最后位置（R3），成功记
  /// 时间线「中断自动恢复」并回调 [onAutoReconnected]（面板 toast），失败走
  /// 既有错误路径（原始异常只进 ErrorLog）。不符合条件维持既有 onSessionLost
  /// 行为（默认路径不变）。
  Future<void> _handleSessionLost(CastTarget device) async {
    if (_autoReconnecting) return;
    final media = _currentMedia;
    if (_autoReconnectAttempted ||
        _autoAdvancing ||
        (media?.isMirror ?? false) ||
        !_sessionRecorded) {
      onSessionLost?.call(device);
      return;
    }
    _autoReconnectAttempted = true;
    _autoReconnecting = true;
    // 触发时的会话记录状态：恢复重投失败的收尾要用（_castWith 会先复位它）。
    final wasRecorded = _sessionRecorded;
    // 恢复尝试全程（复检 + 重投）沿用换集推送护栏（R4）：期间的瞬态 STOPPED
    // 不误判电视端主动停止，用户换集/连投暂不受理。
    _autoAdvancing = true;
    try {
      final reachable = await _probeTargetReachable(device);
      if (_state != CastSessionState.casting) return; // 复检期间会话已被结束
      if (!reachable) {
        // 电视不可达：静默走现有「电视端停止」路径（不 toast、不打扰）。
        CastDiagnostics.instance.recordTimeline('中断自动恢复：目标不可达');
        CastDiagnostics.instance.recordTimeline('电视端停止投屏');
        final position = _lastPosition;
        await _finishSession();
        onRemoteStopped?.call(device, position);
        return;
      }
      // 旧连接已失联：先释放，避免恢复 castTo 覆盖 _transport 引用后泄漏。
      try {
        _transport?.close();
      } catch (_) {}
      final ok = await _replayLastSessionRecord();
      if (ok) {
        CastDiagnostics.instance.recordTimeline('中断自动恢复');
        onAutoReconnected?.call();
      } else {
        // 记录在恢复前被清（损坏清理/外部清理）：既有失联路径。
        onSessionLost?.call(device);
      }
    } on Exception catch (e, stack) {
      // 恢复失败（R3）：现有错误路径——异常只进 ErrorLog，会话完整收尾，
      // 失联交既有 onSessionLost 通道（记录保留，用户可手动重投）。
      ErrorLog.instance.record('投屏中断自动恢复', e, stack);
      // 恢复重投失败时 _castWith 已把 _sessionRecorded 复位：还原触发时的
      // 值，让 _finishSession 的会话收尾（endedAt 更新）按原会话语义执行。
      _sessionRecorded = wasRecorded;
      try {
        await _finishSession();
      } catch (_) {}
      onSessionLost?.call(device);
    } finally {
      _autoAdvancing = false;
      _autoReconnecting = false;
    }
  }

  /// 复检门控（R2）：注入的 [reachabilityProbe] 优先；默认 GET DLNA 描述
  /// URL（与发现期同 1.8s 超时口径），Chromecast/AirPlay 无描述 URL → 按
  /// 端口 TCP 探活。判定不出（无 location/无端口）→ 放行重投（真不可达时
  /// castTo 有界失败走错误路径，不会悬挂）。
  Future<bool> _probeTargetReachable(CastTarget device) {
    final probe = reachabilityProbe;
    if (probe != null) return probe(device);
    final location = device.dlna?.location ?? '';
    if (location.isNotEmpty) return probeDeviceDescriptionReachable(location);
    final port = device.cast?.port ?? device.airplay?.port ?? 0;
    if (device.host.isEmpty || port <= 0) return Future<bool>.value(true);
    return probeHostPortReachable(device.host, port);
  }

  /// 轮询与 GENA 事件共用的状态处理（含播完连投判定）。
  Future<void> _handlePoll(CastPoll poll, CastTarget? device) async {
    // 设备报告 STOPPED 时常不带位置：保留最后一次已知进度（回本地续播语义依赖它）。
    if (poll.isStopped && poll.position == Duration.zero && _lastPosition > Duration.zero) {
      poll = CastPoll(
        transportState: poll.transportState,
        position: _lastPosition,
        duration: poll.duration,
      );
    }
    _lastPosition = poll.position;
    // 只在远端给出真实时长时更新（11-09）：中继 HLS 常态报 0，无条件覆盖会
    // 把已知时长（媒体真实时长 / 上次有效值）打回 0，进度条随之消失。
    if (poll.duration > Duration.zero) _lastDuration = poll.duration;
    _polledAt = DateTime.now();
    _lastRunning = poll.isRunning;
    _lastTransportState = poll.transportState;
    if (poll.transportState != _lastTimelineState) {
      _lastTimelineState = poll.transportState;
      CastDiagnostics.instance.recordTimeline(
          'transportState=${poll.transportState.isEmpty ? '未知' : poll.transportState}');
    }
    // 会话恢复进度（R1.1）：轮询位置按 10s 节流落盘（recorder 内节流）；
    // 只在已记录会话上生效（镜像/本地文件会话不动旧记录）。
    if (_sessionRecorded && poll.position > Duration.zero) {
      await _recordSessionPosition(poll.position);
    }
    // 换集推送进行中（连投/手动跳集）设备可能短暂上报 STOPPED：不是电视端
    // 主动停止，不打断会话；推送失败时 _autoAdvancing 已复位，下一次轮询
    // 照常走远端停止路径。
    if (poll.isStopped && !_userStopping && !_autoAdvancing) {
      final position = _lastPosition;
      // 播完自动连投：三条并列判定（任一成立即视为本集播完）。
      //
      // 1) 设备上报的 duration 可信（部分接收端能给出 event 清单总长）；
      // 2) 中继产物已正常收尾且清单累计时长已播到尾部——**中继链路的
      //    主判据**：实时转码的 event HLS 让多数电视把 TrackDuration 报成
      //    0/NOT_IMPLEMENTED，只靠 (1) 会永远不连投（11-09 真机现象：
      //    一集快播完时电视退出，没有下一集）；
      // 3) 产物已收尾且电视已取到最后两个分片——position 也不可信时按
      //    实际取流进度兜底。
      //
      // 停在中途仍视为遥控器手动停止（不连投）。(_autoAdvancing 已由上方
      // 外层守卫覆盖——外层检查到此行之间无 await，不可能翻转。)
      final endedByRemote = _lastDuration > Duration.zero &&
          position >= _lastDuration - const Duration(seconds: 5);
      final relay = relaySnapshotReader?.call();
      final relayDone = relay?.completedCleanly ?? false;
      final endedByRelayClock = relayDone &&
          relay!.duration > Duration.zero &&
          position >= relay.duration - const Duration(seconds: 8);
      final endedByRelaySegments = relayDone && relay!.playedToEnd;
      if ((endedByRemote || endedByRelayClock || endedByRelaySegments) &&
          await _tryAdvance()) {
        return;
      }
      // 中继异常退出（源 403/密钥错/被 kill）：不连播——内容不完整时跳集
      // 会让用户莫名丢剧情；只把原因记进诊断。
      if (relay != null && relay.ended && !relay.completedCleanly) {
        CastDiagnostics.instance
            .recordTimeline('中继异常退出（code=${relay.exitCode}），本集可能不完整');
      }
      // 电视端主动停止：感知并交还本地（UI 通过 onRemoteStopped 决定续播）。
      CastDiagnostics.instance.recordTimeline('电视端停止投屏');
      await _finishSession();
      if (device != null) onRemoteStopped?.call(device, position);
      return;
    }
    notifyListeners();
  }

  /// 用户拖动进度条后立刻对齐远端，不等下一次轮询。
  Future<void> forceRefresh() => _pollOnce();

  Future<void> pause() async => _transport?.pause();
  Future<void> resume() async => _transport?.play();

  Future<void> seekTo(Duration position) async {
    await _transport?.seekTo(position);
    // 先本地对齐，下一次轮询再用远端真值校正，避免进度条回跳。
    _lastPosition = position;
    _polledAt = DateTime.now();
    notifyListeners();
  }

  Future<void> setVolume(int percent) async => _transport?.setVolume(percent);

  /// 主动断开：返回电视端最后进度（供本地续播）。
  Future<Duration> disconnect() async {
    final device = _currentDevice;
    _userStopping = true;
    _state = CastSessionState.stopping;
    CastDiagnostics.instance.recordTimeline('用户断开投屏');
    notifyListeners();
    var position = _lastPosition;
    try {
      final transport = _transport;
      if (transport != null) {
        try {
          final poll =
              await transport.poll().timeout(const Duration(seconds: 2));
          if (poll.position > Duration.zero) position = poll.position;
        } catch (_) {}
        try {
          await transport.stop();
        } on Exception {
          // Stop 失败回退 Pause（CineFlow 做法：有的盒子 Stop 501）。
          try {
            await transport.pause();
          } catch (_) {}
        }
      }
    } finally {
      await _finishSession();
    }
    if (device != null) {
      // 断开后保留设备记忆（由 CastStore 持久化，控制器不碰盘）。
    }
    return position;
  }

  Future<void> _finishSession() async {
    _pollTimer?.cancel();
    _pollTimer = null;
    final finishedDevice = _currentDevice;
    _transport?.close();
    _transport = null;
    final wasLocal = _currentMedia?.isLocalFile ?? false;
    final wasMirror = _currentMedia?.isMirror ?? false;
    // 会话收尾画像刷新：此时电视取流记录最全（fetchedStream/rangeSupport）。
    // 尽力而为，绝不让画像写入拖垮会话清理。
    if (finishedDevice != null) await _rememberProfile(finishedDevice);
    _currentDevice = null;
    _currentMedia = null;
    // 本地文件投屏结束后关掉 HTTP 服务，别让端口一直开着。
    if (wasLocal) await _mediaServer.stop();
    // 镜像会话结束（断开/电视端停止）→ 停掉采集服务。
    if (wasMirror) await MirrorController.instance.stop();
    // 退订 GENA（事件流关闭 + UNSUBSCRIBE）。
    _genaSub?.cancel();
    _genaSub = null;
    final gena = _gena;
    _gena = null;
    _lastGenaAt = null;
    _pollTick = 0;
    if (gena != null) await gena.stop();
    // 代理条目随会话结束清空（下次投屏重新登记）。
    await _castProxy.stop();
    _lastPosition = Duration.zero;
    _lastDuration = Duration.zero;
    _lastKnownDuration = Duration.zero;
    _polledAt = null;
    _lastRunning = false;
    _lastTransportState = '';
    _pollFailures = 0;
    _userStopping = false;
    // 档位降级状态随会话收尾复位（下一会话重新按 Sink 选路）。
    _forcedRelayFormat = null;
    _sessionRelayFormat = null;
    _relayFormatFallbackDone = false;
    _mediaCastAt = null;
    _mediaRequestBaseline = 0;
    _sourceMedia = null;
    // 中断自动恢复一次性 flag（R1）：会话结束复位，新会话重新获得恰一次机会。
    _autoReconnectAttempted = false;
    // 会话恢复记录（R1.1）：断开/电视端停止只更新 endedAt，不删记录——
    // 重启后仍可恢复。未记录的会话（镜像/本地文件）不动旧记录。
    if (_sessionRecorded) {
      try {
        await sessionRecorder?.markSessionEnded();
      } on Exception catch (e, stack) {
        ErrorLog.instance.record('投屏会话收尾记录', e, stack);
      }
    }
    _sessionRecorded = false;
    onNextEpisode = null;
    onEpisodeJump = null;
    // 快照读取器随会话收尾恢复兜底值（旧会话产物已回收，留着会误判；
    // 直接置 null 会让恢复投屏失去连播判定）。
    relaySnapshotReader = defaultRelaySnapshotReader;
    // 恢复默认兜底而非 null：面板随时可能一键恢复，兜底 resolver 必须常驻。
    transcodeResolver = defaultTranscodeResolver;
    // 重新解析挂点同款（11-08-resume-reparse）：兜底 provider 常驻，跨会话
    // 的一键恢复不因会话收尾失去重新解析能力。
    resumeProvider = defaultResumeProvider;
    _state = CastSessionState.idle;
    notifyListeners();
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _discoverySub?.cancel();
    _mdnsSub?.cancel();
    _airplaySub?.cancel();
    unawaited(_discovery?.stop());
    unawaited(_mediaServer.stop());
    unawaited(_castProxy.stop());
    _genaSub?.cancel();
    unawaited(_gena?.stop());
    _gena = null;
    if (_currentMedia?.isMirror ?? false) {
      unawaited(MirrorController.instance.stop());
    }
    _transport = null;
    super.dispose();
  }
}
