import 'dart:async';

import 'package:flutter/foundation.dart';

import 'dlna_device.dart';
import 'local_media_server.dart';
import 'soap_client.dart';
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
  });

  final String url;
  final String title;
  final String coverUrl;
  final Duration position;
  final int episodeIndex;
  final int episodeCount;

  /// 本机文件路径。非空时由 [LocalMediaServer] 生成局域网 URL，[url] 被忽略。
  final String localPath;

  bool get isLocalFile => localPath.isNotEmpty;
}

/// 一次轮询到的远端状态。
class CastPoll {
  const CastPoll({
    required this.transportState,
    this.position = Duration.zero,
    this.duration = Duration.zero,
  });
  final String transportState; // RUNNING / PAUSED_PLAYBACK / STOPPED / NO_MEDIA_PRESENT…
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

/// 传输抽象：[DlnaTransport] 是 SOAP 实现；测试注入假实现驱动状态机。
abstract class CastTransport {
  Future<void> setUri(Uri url, {required String title, String? duration});
  Future<void> play();
  Future<void> pause();
  Future<void> stop();
  Future<void> seekTo(Duration position);
  Future<void> setVolume(int percent);
  Future<CastPoll> poll();
}

/// DLNA SOAP 实现。
class DlnaTransport implements CastTransport {
  DlnaTransport(this.device, {SoapClient? client})
      : _client = client ?? SoapClient();

  final DlnaDevice device;
  final SoapClient _client;

  static const _avt = 'urn:schemas-upnp-org:service:AVTransport:1';
  static const _rcs = 'urn:schemas-upnp-org:service:RenderingControl:1';

  @override
  Future<void> setUri(Uri url, {required String title, String? duration}) async {
    final metadata = buildDidlLite(title: title, duration: duration);
    await _client.sendAction(device.controlUrl, _avt, 'SetAVTransportURI', {
      'InstanceID': '0',
      'CurrentURI': url.toString(),
      'CurrentURIMetaData': metadata,
    });
  }

  @override
  Future<void> play() =>
      _client.sendAction(device.controlUrl, _avt, 'Play', {
        'InstanceID': '0',
        'Speed': '1',
      });

  @override
  Future<void> pause() =>
      _client.sendAction(device.controlUrl, _avt, 'Pause', {
        'InstanceID': '0',
      });

  @override
  Future<void> stop() =>
      _client.sendAction(device.controlUrl, _avt, 'Stop', {
        'InstanceID': '0',
      });

  @override
  Future<void> seekTo(Duration position) =>
      _client.sendAction(device.controlUrl, _avt, 'Seek', {
        'InstanceID': '0',
        'Unit': 'REL_TIME',
        'Target': formatUpnpTime(position),
      });

  @override
  Future<void> setVolume(int percent) async {
    if (device.renderingControlUrl.isEmpty) {
      throw SoapException('设备不支持音量控制');
    }
    await _client
        .sendAction(device.renderingControlUrl, _rcs, 'SetVolume', {
      'InstanceID': '0',
      'Channel': 'Master',
      'DesiredVolume': '$percent',
    });
  }

  /// 并发取状态与进度：任一路失败不拖累另一路。
  ///
  /// 串行发两个 SOAP 时，一个慢设备就能把 1s 轮询拖成 3s，
  /// 表现是进度条卡住、遥控器暂停要好几秒才反映。
  @override
  Future<CastPoll> poll() async {
    Future<Map<String, String>?> safe(Future<Map<String, String>> call) async {
      try {
        return await call;
      } on SoapException {
        return null;
      }
    }

    final both = await Future.wait<Map<String, String>?>([
      safe(_client.sendAction(device.controlUrl, _avt, 'GetTransportInfo', {
        'InstanceID': '0',
      })),
      safe(_client.sendAction(device.controlUrl, _avt, 'GetPositionInfo', {
        'InstanceID': '0',
      })),
    ]);
    final info = both[0];
    if (info == null) {
      throw SoapException('GetTransportInfo 失败');
    }
    final pos = both[1];
    return CastPoll(
      transportState: info['CurrentTransportState'] ?? '',
      position: parseUpnpTime(pos?['RelTime'] ?? '') ?? Duration.zero,
      duration: parseUpnpTime(pos?['TrackDuration'] ?? '') ?? Duration.zero,
    );
  }

  void close() => _client.close();
}

/// 投屏会话控制器：状态机 + 1s 轮询 + 远端主动停止感知。
///
/// 本地联动（暂停本地播放器/断开回本地续播）由 UI 层订阅完成——控制器只管远端。
class CastController extends ChangeNotifier {
  CastController({CastTransport Function(DlnaDevice)? transportFactory})
      : _transportFactory = transportFactory ?? ((d) => DlnaTransport(d));

  final CastTransport Function(DlnaDevice) _transportFactory;

  CastSessionState _state = CastSessionState.idle;
  final List<DlnaDevice> _devices = [];
  DlnaDevice? _currentDevice;
  CastMedia? _currentMedia;
  CastTransport? _transport;
  Timer? _pollTimer;
  bool _userStopping = false;

  /// 电视端主动停止（用户在遥控器上按了停止）时回调，携带最后已知进度。
  void Function(DlnaDevice device, Duration lastPosition)? onRemoteStopped;

  /// 连续多次轮询失败（电视休眠/换网）时回调，UI 据此提示「连接已断开」。
  void Function(DlnaDevice device)? onSessionLost;

  CastSessionState get state => _state;
  List<DlnaDevice> get devices => List.unmodifiable(_devices);
  DlnaDevice? get currentDevice => _currentDevice;
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
          final i = _devices.indexWhere((d) => d.udn == device.udn);
          if (i >= 0) {
            _devices[i] = device;
          } else {
            _devices.add(device);
          }
          notifyListeners();
        case SsdpDeviceOffline(:final udn):
          final i = _devices.indexWhere((d) => d.udn == udn);
          if (i >= 0) {
            _devices[i].online = false;
            notifyListeners();
          }
        case SsdpScanDone():
          break;
      }
    });
  }

  void stopScan() {
    if (_state == CastSessionState.discovering) {
      _state = CastSessionState.idle;
    }
    _discoverySub?.cancel();
    _discoverySub = null;
    unawaited(_discovery?.stop());
    _discovery = null;
    notifyListeners();
  }

  /// 手动按 IP 添加设备（AP 隔离/组播被滤时的兜底）。
  Future<DlnaDevice?> addByIp(String host, {int port = 49152}) async {
    final discovery = _discovery ??= SsdpDiscovery();
    _discoverySub ??= discovery.start().listen((event) {
        if (event is SsdpDeviceFound) {
          final i = _devices.indexWhere((d) => d.udn == event.device.udn);
          if (i >= 0) {
            _devices[i] = event.device;
          } else {
            _devices.add(event.device);
          }
          notifyListeners();
        }
      });
    return discovery.addByIp(host, port: port);
  }

  // ---------- 会话 ----------

  /// 本地文件投屏用的 HTTP 服务（只有投本地文件时才启动）。
  final LocalMediaServer _mediaServer = LocalMediaServer();

  LocalMediaServer get mediaServer => _mediaServer;

  Future<void> castTo(DlnaDevice device, CastMedia media) async {
    _pollTimer?.cancel();
    _currentDevice = device;
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
        throw SoapException('本地媒体服务启动失败（检查是否在局域网内）');
      }
      playUrl = served;
      media = CastMedia(
        url: served,
        title: media.title,
        coverUrl: media.coverUrl,
        position: media.position,
        episodeIndex: media.episodeIndex,
        episodeCount: media.episodeCount,
        localPath: media.localPath,
      );
    }
    _currentMedia = media;

    final transport = _transport = _transportFactory(device);
    try {
      await transport.setUri(
        Uri.parse(playUrl),
        title: media.title,
        duration:
            media.episodeCount > 0 ? null : null, // 时长未知时省略，避免设备较真
      );
      if (media.position > const Duration(seconds: 3)) {
        // 起播后可能被设备忽略：投完再 seek 一次（部分盒子只认这条顺序）。
        await transport.play();
        try {
          await transport.seekTo(media.position);
        } on SoapException {
          // 设备不支持 Seek：从头播。
        }
      } else {
        await transport.play();
      }
      _state = CastSessionState.casting;
      notifyListeners();
      _startPolling();
    } on SoapException {
      _state = CastSessionState.idle;
      _transport = null;
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
        } on SoapException {
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
    unawaited(_discovery?.stop());
    unawaited(_mediaServer.stop());
    _transport = null;
    super.dispose();
  }
}
