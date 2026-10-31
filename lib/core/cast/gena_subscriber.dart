import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:xml/xml.dart';

import 'cast_controller.dart';
import 'local_media_server.dart';
import 'soap_client.dart';

/// GENA 事件订阅（UPnP AVTransport LastChange 推送）。
///
/// SUBSCRIBE(eventSubURL, CALLBACK=<http://lan:port/cb>) → 电视主动 NOTIFY 状态变化，
/// 替代高频轮询（省 Wi-Fi 唤醒、遥控器停止即时感知）；续订在过期前半程触发。
/// 任何失败都归一为「无事件」——控制器回退纯轮询，绝不因订阅失败影响投屏。
class GenaSubscriber {
  GenaSubscriber(
    this.eventSubUrl, {
    HttpClient? client,
    this.hostOverride,
    this.defaultPort = 18480,
    this.portAttempts = 10,
  }) : _client = client ?? HttpClient() {
    _client.connectionTimeout = const Duration(seconds: 6);
  }

  final String eventSubUrl;
  final String? hostOverride;
  final int defaultPort;
  final int portAttempts;
  final HttpClient _client;

  final _events = StreamController<CastPoll>.broadcast();
  ServerSocket? _callbackServer;
  Timer? _renewTimer;
  String? _sid;
  Duration _timeout = const Duration(seconds: 300);
  bool _stopping = false;

  Stream<CastPoll> get events => _events.stream;

  /// 回调服务实际端口（诊断/测试）。
  int? get callbackPort => _callbackServer?.port;

  bool get active => _sid != null;

  /// 发起订阅并启动回调服务；失败返回 false。
  Future<bool> subscribe() async {
    final host = hostOverride ?? await LocalMediaServer.resolveLanIPv4();
    if (host == null) return false;
    ServerSocket? server;
    for (var i = 0; i < portAttempts; i++) {
      try {
        server = await ServerSocket.bind(InternetAddress.anyIPv4, defaultPort + i);
        break;
      } on SocketException {
        continue;
      }
    }
    if (server == null) return false;
    _callbackServer = server;
    server.listen(_handleNotify, onError: (Object _) {});

    final ok = await _subscribeRequest(host, server.port, renew: false);
    if (!ok) {
      await _closeServer();
      return false;
    }
    _scheduleRenewal(host, server.port);
    return true;
  }

  /// 退订并关闭回调服务（幂等）。
  Future<void> stop() async {
    if (_stopping) return;
    _stopping = true;
    _renewTimer?.cancel();
    _renewTimer = null;
    final sid = _sid;
    _sid = null;
    if (sid != null) {
      try {
        final req = await _client
            .openUrl('UNSUBSCRIBE', Uri.parse(eventSubUrl))
            .timeout(const Duration(seconds: 4));
        req.headers.set('SID', sid);
        await req.close().timeout(const Duration(seconds: 4));
      } catch (_) {
        // 设备已离线：忽略。
      }
    }
    await _events.close();
    await _closeServer();
  }

  Future<void> _closeServer() async {
    final server = _callbackServer;
    _callbackServer = null;
    await server?.close();
  }

  Future<bool> _subscribeRequest(String host, int port, {required bool renew}) async {
    try {
      final req = await _client
          .openUrl('SUBSCRIBE', Uri.parse(eventSubUrl))
          .timeout(const Duration(seconds: 6));
      if (renew) {
        req.headers.set('SID', _sid!);
      } else {
        req.headers.set('CALLBACK', '<http://$host:$port/cb>');
        req.headers.set('NT', 'upnp:event');
      }
      req.headers.set('TIMEOUT', 'Second-300');
      final res = await req.close().timeout(const Duration(seconds: 6));
      if (res.statusCode != 200) return false;
      final newSid = res.headers.value('sid');
      final timeoutHeader = res.headers.value('timeout') ?? '';
      if (newSid == null || newSid.isEmpty) return false;
      _sid = newSid;
      final seconds =
          RegExp(r'Second-(\d+)').firstMatch(timeoutHeader)?.group(1);
      _timeout = Duration(seconds: int.tryParse(seconds ?? '') ?? 300);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 过期前半程续订；连续失败 3 次停止续订（控制器会在 15s 无事件后回纯轮询）。
  void _scheduleRenewal(String host, int port) {
    _renewTimer?.cancel();
    final delay = _timeout ~/ 2;
    _renewTimer = Timer(delay, () async {
      if (_stopping || _sid == null) return;
      final ok = await _subscribeRequest(host, port, renew: true);
      if (ok && !_stopping) {
        _scheduleRenewal(host, port);
      }
    });
  }

  Future<void> _handleNotify(Socket socket) async {
    final buffer = BytesBuilder(copy: true);
    try {
      await for (final chunk in socket) {
        buffer.add(chunk);
        final bytes = buffer.toBytes();
        final bodyStart = _indexOfHeaderEnd(bytes);
        if (bodyStart < 0) {
          if (bytes.length > LocalMediaServer.maxHeaderBytes) break;
          continue;
        }
        final header = utf8.decode(bytes.sublist(0, bodyStart));
        // 校验 SID（不匹配的订阅通知直接忽略）。
        final sid = _headerValue(header, 'SID');
        if (sid != null && sid == _sid) {
          final body = utf8.decode(bytes.sublist(bodyStart + 4), allowMalformed: true);
          final poll = parseAvtLastChange(body);
          if (poll != null) {
            _events.add(poll);
          }
        }
        socket.add(utf8.encode('HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n'));
        await socket.flush();
        break;
      }
    } catch (_) {
      // 单条 NOTIFY 失败不影响订阅。
    } finally {
      try {
        await socket.close();
      } catch (_) {}
    }
  }

  static String? _headerValue(String header, String name) {
    for (final line in header.split('\r\n').skip(1)) {
      final idx = line.indexOf(':');
      if (idx <= 0) continue;
      if (line.substring(0, idx).trim().toLowerCase() == name.toLowerCase()) {
        return line.substring(idx + 1).trim();
      }
    }
    return null;
  }

  static int _indexOfHeaderEnd(Uint8List bytes) {
    for (var i = 0; i + 3 < bytes.length; i++) {
      if (bytes[i] == 13 &&
          bytes[i + 1] == 10 &&
          bytes[i + 2] == 13 &&
          bytes[i + 3] == 10) {
        return i;
      }
    }
    return -1;
  }
}

/// 解析 GENA NOTIFY body（propertyset→LastChange 内嵌 XML）→ [CastPoll]。
///
/// LastChange 形如：
/// ```xml
/// <Event xmlns="urn:schemas-upnp-org:metadata-1-0/AVT/">
///   <InstanceID val="0">
///     <TransportState val="PLAYING"/>
///     <CurrentTrackDuration val="0:10:00"/>
///     <RelativeTimePosition val="0:01:23"/>
///   </InstanceID>
/// </Event>
/// ```
/// 不是 AVT 事件（无 InstanceID/TransportState）返回 null。
CastPoll? parseAvtLastChange(String body) {
  XmlDocument doc;
  try {
    doc = XmlDocument.parse(body);
  } catch (_) {
    return null;
  }
  String? lastChange;
  for (final e in doc.rootElement.descendantElements) {
    if (e.name.local == 'LastChange') {
      lastChange = e.innerText.trim();
      break;
    }
  }
  if (lastChange == null || lastChange.isEmpty) return null;
  XmlDocument inner;
  try {
    inner = XmlDocument.parse(lastChange);
  } catch (_) {
    return null;
  }
  String? state;
  String? duration;
  String? position;
  for (final e in inner.rootElement.descendantElements) {
    if (e.name.local != 'InstanceID') continue;
    final instance = e.getAttribute('val') ?? '0';
    if (instance != '0') continue;
    for (final child in e.descendantElements) {
      final value = child.getAttribute('val') ?? '';
      switch (child.name.local) {
        case 'TransportState':
          state ??= value;
        case 'CurrentTrackDuration':
          duration ??= value;
        case 'RelativeTimePosition':
          position ??= value;
      }
    }
    break;
  }
  if (state == null) return null;
  return CastPoll(
    transportState: state,
    position: parseUpnpTime(position ?? '') ?? Duration.zero,
    duration: parseUpnpTime(duration ?? '') ?? Duration.zero,
  );
}
