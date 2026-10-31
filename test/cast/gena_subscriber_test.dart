import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:aquan_duanju/core/cast/cast_controller.dart';
import 'package:aquan_duanju/core/cast/gena_subscriber.dart';

String _lastChangeBody(String state,
        {String duration = '0:10:00', String position = '0:01:23'}) =>
    '<?xml version="1.0" encoding="utf-8"?>\r\n'
    '<e:propertyset xmlns:e="urn:schemas-upnp-org:event-1-0">\r\n'
    '<e:property><LastChange>&lt;Event xmlns="urn:schemas-upnp-org:metadata-1-0/AVT/"&gt;'
    '&lt;InstanceID val="0"&gt;&lt;TransportState val="$state"/&gt;'
    '&lt;CurrentTrackDuration val="$duration"/&gt;'
    '&lt;RelativeTimePosition val="$position"/&gt;'
    '&lt;/InstanceID&gt;&lt;/Event&gt;</LastChange></e:property>\r\n'
    '</e:propertyset>';

void main() {
  group('parseAvtLastChange', () {
    test('标准 NOTIFY body：双层 XML 解析出状态与时间', () {
      final poll = parseAvtLastChange(_lastChangeBody('PLAYING'));
      expect(poll, isNotNull);
      expect(poll!.transportState, 'PLAYING');
      expect(poll.duration, const Duration(minutes: 10));
      expect(poll.position, const Duration(minutes: 1, seconds: 23));
    });

    test('非 AVT 事件 / 非法 XML → null', () {
      expect(parseAvtLastChange('<foo/>'), isNull);
      expect(parseAvtLastChange('not xml'), isNull);
      expect(
        parseAvtLastChange(_lastChangeBody('PAUSED_PLAYBACK')),
        isNotNull,
        reason: 'PAUSED_PLAYBACK 也是合法状态',
      );
    });
  });

  group('GenaSubscriber（本地假设备端到端）', () {
    late HttpServer device; // 假设备：SUBSCRIBE/UNSUBSCRIBE + NOTIFY 发送
    late GenaSubscriber subscriber;
    final notifications = <HttpRequest>[];

    setUp(() async {
      device = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      device.listen((req) async {
        notifications.add(req);
        if (req.method == 'SUBSCRIBE') {
          req.response.headers.set('SID', 'uuid:test-sid-1');
          req.response.headers.set('TIMEOUT', 'Second-1800');
          await req.response.close();
        } else {
          await req.response.close();
        }
      });
      subscriber = GenaSubscriber(
        'http://127.0.0.1:${device.port}/evt',
        hostOverride: '127.0.0.1',
      );
    });

    tearDown(() async {
      await subscriber.stop();
      await device.close();
    });

    test('subscribe：SUBSCRIBE 头规范（CALLBACK/NT/TIMEOUT），事件到达', () async {
      final eventFuture =
          subscriber.events.first.timeout(const Duration(seconds: 3));

      expect(await subscriber.subscribe(), isTrue);
      expect(subscriber.active, isTrue);
      // 等订阅请求到达（回调服务先起，SUBSCRIBE 后发）。
      while (notifications.isEmpty) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      final req = notifications.first;
      expect(req.method, 'SUBSCRIBE');
      expect(req.headers.value('nt'), 'upnp:event');
      expect(req.headers.value('callback'), contains('/cb'));
      expect(req.headers.value('timeout'), 'Second-300');

      // 设备推 NOTIFY（POST body = propertyset）。
      final socket = await Socket.connect('127.0.0.1', subscriber.callbackPort!);
      final body = _lastChangeBody('PAUSED_PLAYBACK');
      socket.write('NOTIFY /cb HTTP/1.1\r\n'
          'HOST: 127.0.0.1:${subscriber.callbackPort}\r\n'
          'SID: uuid:test-sid-1\r\n'
          'CONTENT-TYPE: text/xml; charset="utf-8"\r\n'
          'CONTENT-LENGTH: ${utf8.encode(body).length}\r\n\r\n'
          '$body');
      await socket.flush();

      final poll = await eventFuture;
      expect(poll.transportState, 'PAUSED_PLAYBACK');
      await socket.close();
    });

    test('SID 不匹配的 NOTIFY 被忽略', () async {
      final got = <CastPoll>[];
      final sub = subscriber.events.listen(got.add);
      addTearDown(sub.cancel);
      await subscriber.subscribe();

      final socket = await Socket.connect('127.0.0.1', subscriber.callbackPort!);
      final body = _lastChangeBody('PLAYING');
      socket.write('NOTIFY /cb HTTP/1.1\r\n'
          'SID: uuid:other\r\n'
          'CONTENT-LENGTH: ${utf8.encode(body).length}\r\n\r\n'
          '$body');
      await socket.flush();
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(got, isEmpty, reason: '非本订阅的 NOTIFY 不应产生事件');
      await socket.close();
    });

    test('stop：UNSUBSCRIBE 带 SID，事件流关闭', () async {
      await subscriber.subscribe();
      notifications.clear();
      await subscriber.stop();
      expect(subscriber.active, isFalse);
      while (notifications.isEmpty) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(notifications.first.method, 'UNSUBSCRIBE');
      expect(notifications.first.headers.value('sid'), 'uuid:test-sid-1');
    });
  });
}
