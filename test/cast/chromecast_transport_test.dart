import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:aquan_duanju/core/cast/cast_target.dart';
import 'package:aquan_duanju/core/cast/chromecast/castv2_channel.dart';
import 'package:aquan_duanju/core/cast/chromecast/chromecast_transport.dart';
import 'package:aquan_duanju/core/cast/chromecast/proto/cast_channel.dart';

/// 本地假 Chromecast 接收器：讲 CASTv2 协议（4 字节大端帧 + CastMessage）。
class _FakeCastServer {
  _FakeCastServer({this.silent = false, this.loadFailed = false});

  /// 不回应任何消息（就绪超时测试用）。
  final bool silent;

  /// LOAD 回 LOAD_FAILED 错误帧。
  final bool loadFailed;

  late ServerSocket _server;
  final requests = <Map<String, dynamic>>[];
  Socket? _client;
  int _mediaState = 0; // 0=idle 1=playing

  Future<int> start() async {
    _server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen((socket) {
      _client = socket;
      CastV2Channel.parseMessages(socket).listen(_onMessage);
    });
    return _server.port;
  }

  Future<void> stop() async {
    await _client?.close();
    await _server.close();
  }

  void _onMessage(CastMessage message) {
    Map<String, dynamic> json;
    try {
      json = jsonDecode(message.payloadUtf8) as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    requests.add({'ns': message.namespace_, ...json});
    if (silent) return;
    final type = json['type'] as String?;
    final requestId = json['requestId'] as int?;
    switch (message.namespace_) {
      case 'urn:x-cast:com.google.cast.tp.heartbeat':
        if (type == 'PING') _reply('urn:x-cast:com.google.cast.tp.heartbeat',
            'receiver-0', {'type': 'PONG'});
      case 'urn:x-cast:com.google.cast.receiver':
        switch (type) {
          case 'LAUNCH':
            _reply('urn:x-cast:com.google.cast.receiver', 'sender-0', {
              'type': 'RECEIVER_STATUS',
              'requestId': requestId,
              'applications': [
                {'appId': 'CC1AD845', 'sessionId': 'sess-1', 'transportId': 'tr-1'},
              ],
            });
          case 'GET_STATUS':
            _reply('urn:x-cast:com.google.cast.receiver', 'sender-0', {
              'type': 'RECEIVER_STATUS',
              'requestId': requestId,
              'volume': {'level': 1.0},
            });
          case 'SET_VOLUME':
            _reply('urn:x-cast:com.google.cast.receiver', 'sender-0', {
              'type': 'RECEIVER_STATUS',
              'requestId': requestId,
              'volume': json['volume'],
            });
          case 'STOP':
            _reply('urn:x-cast:com.google.cast.receiver', 'sender-0', {
              'type': 'RECEIVER_STATUS',
              'requestId': requestId,
              'applications': [],
            });
        }
      case 'urn:x-cast:com.google.cast.media':
        switch (type) {
          case 'LOAD':
            if (loadFailed) {
              _reply('urn:x-cast:com.google.cast.media', 'tr-1',
                  {'type': 'LOAD_FAILED', 'requestId': requestId});
              return;
            }
            _mediaState = 1;
            _replyMedia(requestId, 'BUFFERING');
          case 'GET_STATUS':
            _replyMedia(requestId,
                _mediaState == 1 ? 'PLAYING' : 'IDLE',
                withSession: _mediaState == 1);
          case 'PLAY':
            _mediaState = 1;
            _replyMedia(requestId, 'PLAYING');
          case 'PAUSE':
            _replyMedia(requestId, 'PAUSED');
          case 'SEEK':
            _replyMedia(requestId, 'PLAYING');
          case 'STOP':
            _mediaState = 0;
            _replyMedia(requestId, 'IDLE', withSession: false);
        }
    }
  }

  void _replyMedia(int? requestId, String state, {bool withSession = true}) {
    _reply('urn:x-cast:com.google.cast.media', 'tr-1', {
      'type': 'MEDIA_STATUS',
      'requestId': requestId,
      'status': [
        if (withSession)
          {
            'mediaSessionId': 1,
            'playerState': state,
            'currentTime': 42.5,
            'media': {'duration': 600},
          },
      ],
    });
  }

  void _reply(String namespace, String destinationId, Map<String, dynamic> payload) {
    final socket = _client;
    if (socket == null) return;
    final message = CastMessage()
      ..protocolVersion = CastMessage_ProtocolVersion.CASTV2_1_0
      ..sourceId = destinationId
      ..destinationId = 'sender-0'
      ..namespace_ = namespace
      ..payloadType = CastMessage_PayloadType.STRING
      ..payloadUtf8 = jsonEncode(payload);
    socket.add(CastV2Channel.frameMessage(message));
  }
}

CastDeviceInfo _device(int port) =>
    const CastDeviceInfo(host: '127.0.0.1', port: 0);

void main() {
  test('帧编解码：长度前缀往返 + 半包重组', () async {
    final message = CastMessage()
      ..protocolVersion = CastMessage_ProtocolVersion.CASTV2_1_0
      ..sourceId = 's'
      ..destinationId = 'd'
      ..namespace_ = 'ns'
      ..payloadType = CastMessage_PayloadType.STRING
      ..payloadUtf8 = '{"type":"PING"}';
    final frame = CastV2Channel.frameMessage(message);
    expect(CastV2Channel.readLength(frame), message.writeToBuffer().length);

    // 帧拆成两半喂进 parseMessages → 仍解析出一条完整消息。
    final got = await CastV2Channel.parseMessages(Stream.fromIterable([
      frame.sublist(0, 3),
      frame.sublist(3),
    ])).toList();
    expect(got, hasLength(1));
    expect(got.first.payloadUtf8, '{"type":"PING"}');
  });

  test('全序列：connect→LAUNCH→LOAD→poll→音量→暂停→stop', () async {
    final server = _FakeCastServer();
    final port = await server.start();
    addTearDown(server.stop);

    final transport = ChromecastTransport(
      CastDeviceInfo(host: '127.0.0.1', port: port),
      channel: CastV2Channel(
        socketFactory: (host, p) => Socket.connect(host, p),
      ),
      readyTimeout: const Duration(seconds: 2),
    );
    addTearDown(transport.close);

    await transport.setUri(Uri.parse('http://192.168.1.5:18280/p/t1'),
        title: '测试集');
    final load = server.requests.firstWhere((r) => r['type'] == 'LOAD');
    expect(load['media']['contentId'], 'http://192.168.1.5:18280/p/t1');
    expect(load['media']['metadata']['title'], '测试集');
    expect(load['autoplay'], isTrue);

    final poll = await transport.poll();
    expect(poll.transportState, 'PLAYING');
    expect(poll.position, const Duration(milliseconds: 42500));
    expect(poll.duration, const Duration(minutes: 10));

    await transport.setVolume(40);
    final volume = server.requests.lastWhere((r) => r['type'] == 'SET_VOLUME');
    expect((volume['volume'] as Map)['level'], closeTo(0.4, 1e-9));

    await transport.pause();
    expect(server.requests.lastWhere((r) => r['type'] == 'PAUSE'), isNotNull);

    await transport.stop();
    // media STOP + receiver STOP（带 sessionId）。
    expect(server.requests.any((r) => r['type'] == 'STOP' && r['ns'] != null),
        isTrue);
    final receiverStop = server.requests
        .where((r) => r['ns'] == 'urn:x-cast:com.google.cast.receiver')
        .lastWhere((r) => r['type'] == 'STOP');
    expect(receiverStop['sessionId'], 'sess-1');
  });

  test('LOAD 换集：上一会话先 STOP 再 LOAD', () async {
    final server = _FakeCastServer();
    final port = await server.start();
    addTearDown(server.stop);
    final transport = ChromecastTransport(
      CastDeviceInfo(host: '127.0.0.1', port: port),
      channel: CastV2Channel(
        socketFactory: (host, p) => Socket.connect(host, p),
      ),
      readyTimeout: const Duration(seconds: 2),
    );
    addTearDown(transport.close);

    await transport.setUri(Uri.parse('http://x/1.mp4'), title: 'e1');
    await transport.setUri(Uri.parse('http://x/2.mp4'), title: 'e2');
    final types = server.requests.map((r) => r['type']).toList();
    final firstLoad = types.indexOf('LOAD');
    final secondLoad = types.lastIndexOf('LOAD');
    expect(types.sublist(firstLoad + 1, secondLoad), contains('STOP'),
        reason: '第二次 LOAD 前应先 STOP 旧会话');
  });

  test('就绪超时：LAUNCH 无响应 → CastException', () async {
    final server = _FakeCastServer(silent: true);
    final port = await server.start();
    addTearDown(server.stop);
    final transport = ChromecastTransport(
      CastDeviceInfo(host: '127.0.0.1', port: port),
      channel: CastV2Channel(
        socketFactory: (host, p) => Socket.connect(host, p),
      ),
      readyTimeout: const Duration(milliseconds: 300),
    );
    addTearDown(transport.close);
    await expectLater(
      transport.setUri(Uri.parse('http://x/1.mp4'), title: 't'),
      throwsA(isA<CastException>()),
    );
  });

  test('LOAD_FAILED：错误帧上抛 CastException', () async {
    final server = _FakeCastServer(loadFailed: true);
    final port = await server.start();
    addTearDown(server.stop);
    final transport = ChromecastTransport(
      CastDeviceInfo(host: '127.0.0.1', port: port),
      channel: CastV2Channel(
        socketFactory: (host, p) => Socket.connect(host, p),
      ),
      readyTimeout: const Duration(seconds: 2),
    );
    addTearDown(transport.close);
    await expectLater(
      transport.setUri(Uri.parse('http://x/1.mp4'), title: 't'),
      throwsA(isA<CastException>()),
    );
  });

  test('未启动会话时 poll 直接返回 STOPPED（不发 media 消息）', () async {
    final server = _FakeCastServer();
    final port = await server.start();
    addTearDown(server.stop);
    final transport = ChromecastTransport(
      CastDeviceInfo(host: '127.0.0.1', port: port),
      channel: CastV2Channel(
        socketFactory: (host, p) => Socket.connect(host, p),
      ),
      readyTimeout: const Duration(seconds: 2),
    );
    addTearDown(transport.close);
    final poll = await transport.poll();
    expect(poll.transportState, 'STOPPED');
    expect(server.requests.where((r) => r['type'] == 'GET_STATUS'), isEmpty);
  });
}
