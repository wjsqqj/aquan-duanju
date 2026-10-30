import 'dart:async';

import 'package:flutter/foundation.dart';

import 'cast_target.dart';
import 'dlna_transport.dart';
import 'local_media_server.dart';
import 'ssdp_discovery.dart';

/// 投屏会话状态。
enum CastSessionState { idle, discovering, connecting, casting, stopping }

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
    this.subtitleUrl = '',
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

  /// 外挂字幕地址（srt/vtt）。DLNA 走 DIDL `sec:SubtitleUri`；
  /// Chromecast 先转 VTT 再作为 textTrack 投送。空表示无字幕。
  final String subtitleUrl;

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
      // Step 3 前不会走到（面板只列已发现协议的设备）；防御性抛错。
      throw CastException('Chromecast 传输未就绪');
  }
}

/// 投屏会话控制器：状态机 + 1s 轮询 + 远端主动停止感知 + 多协议路由。
///
/// 本地联动（暂停本地播放器/断开回本地续播）由 UI 层订阅完成——控制器只管远端。
class CastController extends ChangeNotifier {
  CastController({
    CastTransport Function(CastTarget)? transportFactory,
    Stream<CastDeviceInfo> Function()? mdnsDiscover,
    String? Function(String url, Map<String, String> headers)? proxyResolver,
  })  : _transportFactory = transportFactory ?? defaultTransportFactory,
        _mdnsDiscover = mdnsDiscover,
        _proxyResolver = proxyResolver;

  final CastTransport Function(CastTarget) _transportFactory;

  /// mDNS 发现挂点（Chromecast）。null = 本构建未启用（Step 4 前的过渡态）。
  final Stream<CastDeviceInfo> Function()? _mdnsDiscover;

  /// 受保护流代理挂点（Step 5 接 CastMediaProxy）。返回 null 表示不代理、直投原 URL。
  final String? Function(String url, Map<String, String> headers)? _proxyResolver;

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

  CastSessionState get state => _state;
  List<CastTarget> get devices => List.unmodifiable(_devices);
  CastTarget? get currentDevice => _currentDevice;
  CastMedia? get currentMedia => _currentMedia;
  Duration get remoteDuration => _lastDuration;
  bool get isCasting => _state == CastSessionState.casting;

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
  DateTime? _polledAt;
  bool _lastRunning = false;
  int _pollFailures = 0;
  SsdpDiscovery? _discovery;
  StreamSubscription<SsdpEvent>? _discoverySub;
  StreamSubscription<CastDeviceInfo>? _mdnsSub;

  // ---------- 扫描 ----------

  void startScan() {
    if (_state == CastSessionState.discovering) return;
    _devices.clear();
    _state = CastSessionState.discovering;
    notifyListeners();
    final discovery = _discovery = SsdpDiscovery();
    _discoverySub?.cancel();
    _discoverySub = discovery.start().listen((event) {
      switch (event) {
        case SsdpDeviceFound(:final device):
          _upsertDevice(CastTarget.dlna(device));
        case SsdpDeviceOffline(:final udn):
          final i = _devices.indexWhere((d) => d.id == udn);
          if (i >= 0) {
            _devices[i].online = false;
            if (_devices[i].dlna != null) _devices[i].dlna!.online = false;
            notifyListeners();
          }
        case SsdpScanDone():
          break;
      }
    });
    _startMdnsScan();
  }

  /// Chromecast mDNS 扫描：多轮查询由 [MdnsDiscovery] 内部完成，这里只收流。
  void _startMdnsScan() {
    final discover = _mdnsDiscover;
    if (discover == null) return;
    _mdnsSub?.cancel();
    _mdnsSub = discover().listen((info) {
      _upsertDevice(CastTarget.chromecast(info));
    }, onError: (_) {
      // mDNS 失败不影响 DLNA 扫描（老机型/权限缺失场景）。
    });
  }

  void _upsertDevice(CastTarget target) {
    final i = _devices.indexWhere((d) => d.id == target.id);
    if (i >= 0) {
      _devices[i] = target;
    } else {
      _devices.add(target);
    }
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
    unawaited(_discovery?.stop());
    _discovery = null;
    notifyListeners();
  }

  /// 手动按 IP 添加 DLNA 设备（AP 隔离/组播被滤时的兜底）。
  Future<CastTarget?> addByIp(String host, {int port = 49152}) async {
    final discovery = _discovery ??= SsdpDiscovery();
    _discoverySub ??= discovery.start().listen((event) {
      if (event is SsdpDeviceFound) _upsertDevice(CastTarget.dlna(event.device));
    });
    final device = await discovery.addByIp(host, port: port);
    return device == null ? null : CastTarget.dlna(device);
  }

  // ---------- 会话 ----------

  /// 本地文件投屏用的 HTTP 服务（只有投本地文件时才启动）。
  final LocalMediaServer _mediaServer = LocalMediaServer();

  LocalMediaServer get mediaServer => _mediaServer;

  /// 投到指定目标。同 IP 存在另一协议目标且首选失败时自动降级重试一次
  /// （如 Chromecast 就绪超时 → 同 IP 的 DLNA MediaRenderer）。
  Future<void> castTo(CastTarget target, CastMedia media) async {
    try {
      await _castWith(target, media);
    } on Exception {
      final alt = _devices
          .where((d) =>
              d.host.isNotEmpty &&
              d.host == target.host &&
              d.protocol != target.protocol)
          .toList();
      if (alt.isEmpty) rethrow;
      // 降级目标再失败则直接抛给 UI（不再继续找）。
      await _castWith(alt.first, media);
    }
  }

  Future<void> _castWith(CastTarget target, CastMedia media) async {
    _pollTimer?.cancel();
    _currentDevice = target;
    _userStopping = false;
    _state = CastSessionState.connecting;
    notifyListeners();

    var playUrl = media.url;
    if (media.isLocalFile) {
      final served = await _mediaServer.urlFor(media.localPath);
      if (served == null) {
        _state = CastSessionState.idle;
        _currentDevice = null;
        notifyListeners();
        throw CastException('本地媒体服务启动失败（检查是否在局域网内）');
      }
      playUrl = served;
    } else if (media.headers.isNotEmpty && _proxyResolver != null) {
      // 带源站头的直链：经本机代理中转（电视无法自带 Referer/UA）。
      final resolve = _proxyResolver;
      final proxied = resolve?.call(media.url, media.headers);
      if (proxied != null) playUrl = proxied;
    }
    media = CastMedia(
      url: playUrl,
      title: media.title,
      coverUrl: media.coverUrl,
      position: media.position,
      episodeIndex: media.episodeIndex,
      episodeCount: media.episodeCount,
      localPath: media.localPath,
      headers: media.headers,
      subtitleUrl: media.subtitleUrl,
    );
    _currentMedia = media;

    final transport = _transport = _transportFactory(target);
    try {
      await transport.setUri(
        Uri.parse(playUrl),
        title: media.title,
        duration: null, // 时长未知时省略，避免设备较真
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
      _state = CastSessionState.casting;
      notifyListeners();
      _startPolling();
    } on Exception {
      _state = CastSessionState.idle;
      _transport = null;
      _currentDevice = null;
      notifyListeners();
      rethrow;
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
    final device = _currentDevice;
    try {
      final poll = await transport.poll().timeout(const Duration(seconds: 3));
      _pollFailures = 0;
      _lastPosition = poll.position;
      _lastDuration = poll.duration;
      _polledAt = DateTime.now();
      _lastRunning = poll.isRunning;
      if (poll.isStopped && !_userStopping) {
        // 电视端主动停止：感知并交还本地（UI 通过 onRemoteStopped 决定续播）。
        final position = _lastPosition;
        await _finishSession();
        if (device != null) onRemoteStopped?.call(device, position);
        return;
      }
      notifyListeners();
    } catch (_) {
      // 单次轮询失败容忍（Wi-Fi 抖动）；连续 5 次判失联，交 UI 决定是否重连。
      _pollFailures++;
      if (_pollFailures >= 5) {
        _pollFailures = 0;
        if (device != null) onSessionLost?.call(device);
      }
    }
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
    _transport?.close();
    _transport = null;
    final wasLocal = _currentMedia?.isLocalFile ?? false;
    _currentDevice = null;
    _currentMedia = null;
    // 本地文件投屏结束后关掉 HTTP 服务，别让端口一直开着。
    if (wasLocal) await _mediaServer.stop();
    _lastPosition = Duration.zero;
    _lastDuration = Duration.zero;
    _polledAt = null;
    _lastRunning = false;
    _pollFailures = 0;
    _userStopping = false;
    _state = CastSessionState.idle;
    notifyListeners();
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _discoverySub?.cancel();
    _mdnsSub?.cancel();
    unawaited(_discovery?.stop());
    unawaited(_mediaServer.stop());
    _transport = null;
    super.dispose();
  }
}
