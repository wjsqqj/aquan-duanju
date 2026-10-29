import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'dlna_device.dart';

/// SSDP 设备发现（UPnP 1.0）：M-SEARCH 三目标 × 4 轮 + NOTIFY 监听。
///
/// 参数对齐 CineFlow cast.cjs（实测有效）：ST 三目标各一轮、1.5s 一轮共 4 轮、
/// TTL 4、设备表 TTL 26s；`ssdp:byebye` 置离线；同一 LOCATION 只拉一次描述。
const String multicastGroup = '239.255.255.250';
const int multicastPort = 1900;
const Duration deviceTtl = Duration(seconds: 26);
const int discoveryRounds = 4;
const Duration roundInterval = Duration(milliseconds: 1500);
const Duration descriptionTimeout = Duration(milliseconds: 1800);
const int maxDescriptionBytes = 256 * 1024;
sealed class SsdpEvent {
  const SsdpEvent();
}

class SsdpDeviceFound extends SsdpEvent {
  const SsdpDeviceFound(this.device);
  final DlnaDevice device;
}

class SsdpDeviceOffline extends SsdpEvent {
  const SsdpDeviceOffline(this.udn);
  final String udn;
}

class SsdpScanDone extends SsdpEvent {
  const SsdpScanDone();
}

class SsdpDiscovery {
  SsdpDiscovery({DescriptionFetcherFactory? clientFactory})
      : _clientFactory = clientFactory ?? _defaultFactory;

  /// 描述文档拉取器抽象（测试可注入本地 HttpServer）。
  final DescriptionFetcherFactory _clientFactory;

  RawDatagramSocket? _socket;
  StreamController<SsdpEvent>? _events;
  Timer? _roundTimer;
  Timer? _pruneTimer;
  bool _scanning = false;
  int _roundsLeft = 0;

  /// LOCATION → 描述已请求（去重：同一 location 只拉一次）。
  final Set<String> _pendingLocations = {};

  /// USN → 设备（含 TTL 时间戳）。
  final Map<String, _DeviceEntry> _devices = {};


  Stream<SsdpEvent> start() {
    if (_scanning) return _events!.stream;
    _scanning = true;
    _pendingLocations.clear();
    final events = _events = StreamController<SsdpEvent>.broadcast();
    _bind().then((_) {
      _sendAllTargets();
      _roundsLeft = discoveryRounds - 1;
      _roundTimer = Timer.periodic(roundInterval, (_) {
        if (_roundsLeft <= 0) {
          _roundTimer?.cancel();
          _roundTimer = null;
          // 轮询结束不代表发现结束（NOTIFY 仍监听）；只发一次扫描完成信号。
          events.add(const SsdpScanDone());
          return;
        }
        _roundsLeft--;
        _sendAllTargets();
      });
      _pruneTimer = Timer.periodic(const Duration(seconds: 5), (_) {
        final now = DateTime.now();
        final expired = _devices.entries
            .where((e) => now.difference(e.value.seenAt) > deviceTtl)
            .toList();
        for (final e in expired) {
          _devices.remove(e.key);
          events.add(SsdpDeviceOffline(e.value.device.udn));
        }
      });
    }).catchError((Object e) {
      events.addError(e);
    });
    return events.stream;
  }

  Future<void> stop() async {
    _scanning = false;
    _roundTimer?.cancel();
    _roundTimer = null;
    _pruneTimer?.cancel();
    _pruneTimer = null;
    _socket?.close();
    _socket = null;
    _devices.clear();
    _pendingLocations.clear();
    await _events?.close();
    _events = null;
  }

  Future<void> _bind() async {
    final socket = await RawDatagramSocket.bind(
      InternetAddress.anyIPv4,
      0,
      reuseAddress: true,
    );
    socket.joinMulticast(InternetAddress(multicastGroup));
    socket.multicastLoopback = false;
    // TTL 固定走系统默认：Dart RawDatagramSocket 没有暴露 TTL 设置。
    socket.listen((event) {
      if (event != RawSocketEvent.read) return;
      final datagram = socket.receive();
      if (datagram == null) return;
      _handlePacket(utf8.decode(datagram.data, allowMalformed: true));
    });
    _socket = socket;
  }

  void _sendAllTargets() {
    const targets = [
      'urn:schemas-upnp-org:device:MediaRenderer:1',
      'upnp:rootdevice',
      'ssdp:all',
    ];
    for (final st in targets) {
      _sendPacket(buildSearchPacket(st));
    }
  }

  void _sendPacket(String packet) {
    final socket = _socket;
    if (socket == null) return;
    final data = Uint8List.fromList(utf8.encode(packet));
    try {
      socket.send(data, InternetAddress(multicastGroup), multicastPort);
    } catch (_) {
      // 发送失败留给下一轮。
    }
  }

  void _handlePacket(String text) {
    final headers = parseSsdpHeaders(text);
    if (headers == null) return;
    final location = headers['LOCATION'] ?? headers['Location'];
    final usn = headers['USN'] ?? headers['Usn'] ?? location ?? '';
    final nts = headers['NTS'];

    if (nts != null && nts.toLowerCase() == 'ssdp:byebye') {
      final entry = _devices.remove(usn);
      if (entry != null) {
        _events?.add(SsdpDeviceOffline(entry.device.udn));
      }
      return;
    }
    if (location == null || location.isEmpty) return;
    final existing = _devices[usn];
    if (existing != null) {
      existing.seenAt = DateTime.now(); // 心跳刷新
      if (!existing.device.online) existing.device.online = true;
      return;
    }
    if (!_pendingLocations.add(location)) return;
    _fetchDescription(location, usn);
  }

  Future<void> _fetchDescription(String location, String usn) async {
    try {
      final body = await _clientFactory().fetchDescription(location);
      final device = parseDeviceDescription(body, location);
      if (device == null) return; // 无 AVTransport：不是投屏目标。
      _devices[usn] = _DeviceEntry(device: device, seenAt: DateTime.now());
      _events?.add(SsdpDeviceFound(device));
    } catch (_) {
      // 描述拉取失败：跳过该设备（下一轮 NOTIFY 或 M-SEARCH 会再触发）。
    } finally {
      // 拉取失败时放行重试；成功则保持去重。
      if (!_devices.containsKey(usn)) {
        _pendingLocations.remove(location);
      }
    }
  }

  /// 手动添加 IP：按常见描述路径逐个探测。
  Future<DlnaDevice?> addByIp(String host, {int port = 49152}) async {
    const paths = ['/description.xml', '/DeviceDescription.xml', '/dd.xml', '/'];
    for (final path in paths) {
      final location = 'http://$host:$port$path';
      try {
        final body = await _clientFactory().fetchDescription(location);
        final device = parseDeviceDescription(body, location);
        if (device != null) {
          _devices[device.udn] =
              _DeviceEntry(device: device, seenAt: DateTime.now());
          _events?.add(SsdpDeviceFound(device));
          return device;
        }
      } catch (_) {
        continue;
      }
    }
    return null;
  }

  List<DlnaDevice> get devices =>
      _devices.values.map((e) => e.device).toList();
}

class _DeviceEntry {
  _DeviceEntry({required this.device, required this.seenAt});
  final DlnaDevice device;
  DateTime seenAt;
}

typedef DescriptionFetcherFactory = DescriptionFetcher Function();

abstract class DescriptionFetcher {
  Future<String> fetchDescription(String url);
}

class _HttpClientFetcher implements DescriptionFetcher {
  final http.Client _client = http.Client();

  @override
  Future<String> fetchDescription(String url) async {
    final res = await _client
        .get(Uri.parse(url))
        .timeout(descriptionTimeout);
    if (res.statusCode != 200) {
      throw HttpException('HTTP ${res.statusCode}');
    }
    if (res.bodyBytes.length > maxDescriptionBytes) {
      throw HttpException('描述过大');
    }
    return utf8.decode(res.bodyBytes, allowMalformed: true);
  }
}

DescriptionFetcher _defaultFactory() => _HttpClientFetcher();

/// 构造 M-SEARCH 报文（CineFlow 同款格式）。
String buildSearchPacket(String st) {
  return 'M-SEARCH * HTTP/1.1\r\n'
      'HOST: $multicastGroup:$multicastPort\r\n'
      'MAN: "ssdp:discover"\r\n'
      'MX: 2\r\n'
      'ST: $st\r\n'
      '\r\n';
}

/// 解析 SSDP 响应/NOTIFY 头（键大小写不敏感，保留原样大写键）；
/// 非 SSDP 报文（无 HTTP 头）返回 null。
Map<String, String>? parseSsdpHeaders(String text) {
  final headEnd = text.indexOf('\r\n\r\n');
  final headerBlock =
      headEnd >= 0 ? text.substring(0, headEnd) : text.split('\n\n').first;
  final lines = headerBlock.split(RegExp(r'\r?\n'));
  if (lines.isEmpty) return null;
  final first = lines.first.trim();
  if (!first.startsWith('HTTP/1.') &&
      !first.startsWith('NOTIFY') &&
      !first.startsWith('M-SEARCH')) {
    return null;
  }
  final out = <String, String>{};
  for (var i = 1; i < lines.length; i++) {
    final colon = lines[i].indexOf(':');
    if (colon <= 0) continue;
    final key = lines[i].substring(0, colon).trim().toUpperCase();
    out[key] = lines[i].substring(colon + 1).trim();
  }
  return out;
}
