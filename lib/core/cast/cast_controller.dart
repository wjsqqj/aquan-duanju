import 'dart:async';

import 'package:flutter/foundation.dart';

import 'dlna_device.dart';
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
  });

  final String url;
  final String title;
  final String coverUrl;
  final Duration position;
  final int episodeIndex;
  final int episodeCount;
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

  bool get isRunning => transportState == 'RUNNING';
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

  @override
  Future<CastPoll> poll() async {
    final info =
        await _client.sendAction(device.controlUrl, _avt, 'GetTransportInfo', {
      'InstanceID': '0',
    });
    String position = '';
    String duration = '';
    try {
      final pos = await _client
          .sendAction(device.controlUrl, _avt, 'GetPositionInfo', {
        'InstanceID': '0',
      });
      position = pos['RelTime'] ?? '';
      duration = pos['TrackDuration'] ?? '';
    } on SoapException {
      // GetPositionInfo 失败不影响主状态。
    }
    return CastPoll(
      transportState: info['CurrentTransportState'] ?? '',
      position: parseUpnpTime(position) ?? Duration.zero,
      duration: parseUpnpTime(duration) ?? Duration.zero,
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

  CastSessionState get state => _state;
  List<DlnaDevice> get devices => List.unmodifiable(_devices);
  DlnaDevice? get currentDevice => _currentDevice;
  CastMedia? get currentMedia => _currentMedia;
  Duration get remotePosition => _lastPosition;
  Duration get remoteDuration => _lastDuration;
  bool get isCasting => _state == CastSessionState.casting;

  Duration _lastPosition = Duration.zero;
  Duration _lastDuration = Duration.zero;
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

  Future<void> castTo(DlnaDevice device, CastMedia media) async {
    _pollTimer?.cancel();
    _currentDevice = device;
    _currentMedia = media;
    _userStopping = false;
    _state = CastSessionState.connecting;
    notifyListeners();
    final transport = _transport = _transportFactory(device);
    try {
      await transport.setUri(
        Uri.parse(media.url),
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
    _pollTimer = Timer.periodic(const Duration(seconds: 1), (_) async {
      final transport = _transport;
      if (transport == null || _state != CastSessionState.casting) return;
      try {
        final poll = await transport.poll().timeout(const Duration(seconds: 3));
        _lastPosition = poll.position;
        _lastDuration = poll.duration;
        if (poll.isStopped && !_userStopping) {
          // 电视端主动停止：感知并交还本地（UI 通过 onRemoteStopped 决定续播）。
          final device = _currentDevice;
          final position = _lastPosition;
          await _finishSession();
          if (device != null) onRemoteStopped?.call(device, position);
          return;
        }
        notifyListeners();
      } catch (_) {
        // 单次轮询失败容忍（Wi-Fi 抖动）；连续失败由用户自行断开。
      }
    });
  }

  Future<void> pause() async => _transport?.pause();
  Future<void> resume() async => _transport?.play();
  Future<void> seekTo(Duration position) async => _transport?.seekTo(position);
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
    _currentDevice = null;
    _currentMedia = null;
    _lastPosition = Duration.zero;
    _lastDuration = Duration.zero;
    _userStopping = false;
    _state = CastSessionState.idle;
    notifyListeners();
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _discoverySub?.cancel();
    unawaited(_discovery?.stop());
    _transport = null;
    super.dispose();
  }
}
