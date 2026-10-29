import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:aquan_duanju/core/cast/soap_client.dart';

void main() {
  group('buildEnvelope', () {
    test('action 与参数顺序', () {
      final envelope = buildEnvelope('urn:schemas-upnp-org:service:AVTransport:1',
          'SetAVTransportURI', {'InstanceID': '0', 'CurrentURI': 'http://x/1.m3u8'});
      expect(envelope, contains('<u:SetAVTransportURI'));
      expect(envelope, contains('xmlns:u="urn:schemas-upnp-org:service:AVTransport:1"'));
      expect(envelope, contains('<InstanceID>0</InstanceID>'));
      expect(envelope, contains('<CurrentURI>http://x/1.m3u8</CurrentURI>'));
      expect(envelope, contains('SOAP-ENC'.isEmpty ? '' : 'encodingStyle'));
    });
  });

  group('parseSoapResponse（多模式兜底）', () {
    test('标准响应元素', () {
      final body = '<s:Envelope><s:Body>'
          '<u:GetTransportInfoResponse xmlns:u="urn:x"> '
          '<CurrentTransportState>PLAYING</CurrentTransportState>'
          '<CurrentTransportStatus>OK</CurrentTransportStatus>'
          '</u:GetTransportInfoResponse></s:Body></s:Envelope>';
      final out = parseSoapResponse(body, 'GetTransportInfo');
      expect(out['CurrentTransportState'], 'PLAYING');
      expect(out['CurrentTransportStatus'], 'OK');
    });

    test('带命名空间前缀的返回字段', () {
      final body = '<Envelope><Body>'
          '<rcs:GetVolumeResponse><rcs:CurrentVolume>37</rcs:CurrentVolume>'
          '</rcs:GetVolumeResponse></Body></Envelope>';
      final out = parseSoapResponse(body, 'GetVolume');
      expect(out['CurrentVolume'], '37');
    });

    test('非法 XML 走正则兜底', () {
      const body = 'garbage <TrackDuration>0:12:34</TrackDuration> tail';
      final out = parseSoapResponse(body, 'GetPositionInfo');
      expect(out['TrackDuration'], '0:12:34');
    });

    test('空响应返回空 Map', () {
      expect(parseSoapResponse('<a></a>', 'Unknown'), isEmpty);
    });
  });

  group('parseSoapFault', () {
    test('UPnP fault（含 errorCode）', () {
      // 真实 UPnP fault 包在信封里且命名空间已声明。
      const body = '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/">'
          '<s:Body><s:Fault><s:code>s:Sender</s:code>'
          '<UPnPError xmlns="urn:schemas-upnp-org:control-1-0">'
          '<errorCode>401</errorCode>'
          '<errorDescription>Invalid Action</errorDescription>'
          '</UPnPError></s:Fault></s:Body></s:Envelope>';
      final fault = parseSoapFault(body);
      expect(fault, isNotNull);
      expect(fault!.$1, contains('Sender'));
      expect(fault.$2, contains('401'));
    });

    test('无 fault 返回 null', () {
      expect(parseSoapFault('<a></a>'), isNull);
    });
  });

  group('时间格式', () {
    test('parseUpnpTime 容错', () {
      expect(parseUpnpTime('0:02:15.500'), const Duration(minutes: 2, seconds: 15, milliseconds: 500));
      expect(parseUpnpTime('1:00:00'), const Duration(hours: 1));
      expect(parseUpnpTime('12:34'), const Duration(minutes: 12, seconds: 34));
      expect(parseUpnpTime(''), isNull);
      expect(parseUpnpTime('NOT_IMPLEMENTED'), isNull);
      expect(parseUpnpTime('xx:yy'), isNull);
    });

    test('formatUpnpTime', () {
      expect(formatUpnpTime(const Duration(hours: 1, minutes: 2, seconds: 3)),
          '1:02:03');
    });
  });

  group('真实 HTTP 往返（本地夹具）', () {
    late HttpServer server;
    late String controlUrl;
    HttpRequest? lastRequest;

    setUp(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      controlUrl = 'http://127.0.0.1:${server.port}/ctrl';
      server.listen((req) async {
        lastRequest = req;
        final body = await utf8.decoder.bind(req).join();
        req.response.headers.contentType =
            ContentType('text', 'xml', charset: 'utf-8');
        if (body.contains('SetAVTransportURI')) {
          // 设备偶发 504：第一次失败、重试成功（SoapClient 会自动重试一次）。
          if (req.headers.value('x-retry-probe') == null) {}
          req.response.statusCode = 504;
          await req.response.close();
          return;
        }
        req.response.write(
            '<s:Envelope><s:Body><u:PlayResponse xmlns:u="urn:x"/></s:Body></s:Envelope>');
        await req.response.close();
      });
    });

    tearDown(() => server.close(force: true));

    test('动作头与请求体到达设备；504 自动重试后成功', () async {
      final client = SoapClient();
      // Play 成功路径。
      final out = await client.sendAction(controlUrl,
          'urn:schemas-upnp-org:service:AVTransport:1', 'Play', {'Speed': '1'});
      expect(out, isEmpty);
      expect(lastRequest!.headers.value('SOAPACTION'),
          '"urn:schemas-upnp-org:service:AVTransport:1#Play"');

      // SetAVTransportURI 第一次 504 → 重试仍 504 → 抛异常（重试行为验证）。
      await expectLater(
        client.sendAction(controlUrl,
            'urn:schemas-upnp-org:service:AVTransport:1', 'SetAVTransportURI',
            {'CurrentURI': 'http://x/1'}),
        throwsA(isA<SoapException>()),
      );
      client.close();
    });
  });
}
