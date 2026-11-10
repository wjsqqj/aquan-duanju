import 'package:flutter_test/flutter_test.dart';

import 'package:aquan_duanju/core/cast/cast_diagnostics.dart';

void main() {
  group('五类 verdict 判定（design §3.5）', () {
    test('notSent：从未发出 SetAVTransportURI', () {
      final d = CastDiagnostics();
      d.beginSession(protocol: 'dlna');
      d.recordSsdpResponse('HTTP/1.1 200 OK\r\nST: upnp:rootdevice\r\n\r\n');
      expect(d.computeVerdict(), CastVerdict.notSent);
    });

    test('notAccepted：SetAVTransportURI 被 fault 拒绝', () {
      final d = CastDiagnostics();
      d.beginSession(protocol: 'dlna');
      d.recordSoap(SoapTrace(
        action: 'SetAVTransportURI',
        requestBody: '<s:Envelope/>',
        httpStatus: 500,
        faultCode: 's:Client',
        faultDescription: 'UPnPError 401',
      ));
      expect(d.computeVerdict(), CastVerdict.notAccepted);
    });

    test('notAccepted：命令接受但 Play 被拒绝', () {
      final d = CastDiagnostics();
      d.beginSession(protocol: 'dlna');
      d.recordSoap(SoapTrace(
        action: 'SetAVTransportURI',
        requestBody: '<s:Envelope/>',
        httpStatus: 200,
      ));
      d.recordSoap(SoapTrace(
        action: 'Play',
        requestBody: '<s:Envelope/>',
        httpStatus: 200,
        faultDescription: 'errorCode 401',
      ));
      expect(d.computeVerdict(), CastVerdict.notAccepted);
    });

    test('acceptedButNotFetched：命令接受但电视没来取流', () {
      final d = CastDiagnostics();
      d.beginSession(protocol: 'dlna');
      d.recordSoap(SoapTrace(
        action: 'SetAVTransportURI',
        requestBody: '<s:Envelope/>',
        httpStatus: 200,
      ));
      expect(d.computeVerdict(), CastVerdict.acceptedButNotFetched);
    });

    test('fetchedButNotDecoded：来取流但没有一次 2xx', () {
      final d = CastDiagnostics();
      d.beginSession(protocol: 'dlna');
      d.recordSoap(SoapTrace(
        action: 'SetAVTransportURI',
        requestBody: '<s:Envelope/>',
        httpStatus: 200,
      ));
      d.recordMediaRequest(MediaRequestTrace(
        url: '/p/AbCdEf0123456789AbCdEf0123456789/index.m3u8',
        method: 'GET',
        statusCode: 404,
      ));
      expect(d.computeVerdict(), CastVerdict.fetchedButNotDecoded);
    });

    test('playingNotConfirmed：取到流（2xx）但没进 PLAYING', () {
      final d = CastDiagnostics();
      d.beginSession(protocol: 'dlna');
      d.recordSoap(SoapTrace(
        action: 'SetAVTransportURI',
        requestBody: '<s:Envelope/>',
        httpStatus: 200,
      ));
      d.recordMediaRequest(MediaRequestTrace(
        url: '/m/AbCdEf0123456789AbCdEf0123456789',
        method: 'GET',
        statusCode: 200,
        bytesServed: 4096,
      ));
      d.recordTimeline('transportState=BUFFERING');
      expect(d.computeVerdict(), CastVerdict.playingNotConfirmed);
    });

    test('播放已确认 → 无失败判定', () {
      final d = CastDiagnostics();
      d.beginSession(protocol: 'dlna');
      d.recordSoap(SoapTrace(
        action: 'SetAVTransportURI',
        requestBody: '<s:Envelope/>',
        httpStatus: 200,
      ));
      d.recordMediaRequest(MediaRequestTrace(
        url: '/m/AbCdEf0123456789AbCdEf0123456789',
        method: 'GET',
        statusCode: 206,
        bytesServed: 1024,
      ));
      d.recordTimeline('transportState=PLAYING');
      expect(d.playingConfirmed, isTrue);
      expect(d.computeVerdict(), isNull);
    });

    test('RUNNING 也算播放确认（各厂商状态词差异）', () {
      final d = CastDiagnostics();
      d.beginSession(protocol: 'dlna');
      d.recordTimeline('transportState=RUNNING');
      expect(d.playingConfirmed, isTrue);
      expect(d.computeVerdict(), isNull);
    });

    test('非 DLNA 会话不出判定', () {
      final d = CastDiagnostics();
      d.beginSession(protocol: 'chromecast');
      expect(d.computeVerdict(), isNull);
    });

    test('beginSession 清空会话级数据（重投后按新会话判定）', () {
      final d = CastDiagnostics();
      d.beginSession(protocol: 'dlna');
      d.recordMediaRequest(MediaRequestTrace(
        url: '/m/x',
        method: 'GET',
        statusCode: 200,
        bytesServed: 10,
      ));
      d.beginSession(deviceName: '客厅电视', protocol: 'dlna');
      expect(d.mediaRequests, isEmpty);
      expect(d.computeVerdict(), CastVerdict.notSent);
      expect(d.deviceName, '客厅电视');
    });
  });

  group('导出级脱敏', () {
    test('token 路径段替换为 <token>', () {
      const token = 'Ab3xY9_0123456789abcdefghijklmnop';
      final out = CastDiagnostics.redactReportText(
          'http://192.168.1.5:18280/p/$token/index.m3u8');
      expect(out.contains(token), isFalse);
      expect(out.contains('/p/<token>/index.m3u8'), isTrue);
    });

    test('本地服务 /cast/ 与 /w/ 的 token 同样替换', () {
      const token = 'AbCdEf0123456789AbCdEf0123456789';
      for (final shape in [
        'http://192.168.1.5:29170/cast/$token/index.m3u8',
        'http://192.168.1.5:18480/w/$token',
        'http://192.168.1.7:18080/m/$token',
      ]) {
        final out = CastDiagnostics.redactReportText(shape);
        expect(out.contains(token), isFalse, reason: shape);
        expect(out.contains('<token>'), isTrue, reason: shape);
      }
    });

    test('签名 query 值替换为 <redacted>，普通参数保留', () {
      final out = CastDiagnostics.redactReportText(
          'http://cdn.example.com/video.m3u8?sign=abc123&t=1700000000&ext=mp4');
      expect(out.contains('abc123'), isFalse);
      expect(out.contains('1700000000'), isFalse);
      expect(out.contains('sign=<redacted>'), isTrue);
      expect(out.contains('t=<redacted>'), isTrue);
      // 非敏感参数值保留（保住扩展名与路径形状）。
      expect(out.contains('ext=mp4'), isTrue);
    });

    test('变体拼写的签名/凭据键按词根匹配替换', () {
      final out = CastDiagnostics.redactReportText('http://cdn.example.com/live'
          '?wsSecret=9f8e7d6c&auth_key=1700000000-0-abcdef'
          '&access_token=eyJhbGciOi.X.Y&X-Amz-Signature=cafe01&v=2');
      expect(out.contains('9f8e7d6c'), isFalse);
      expect(out.contains('1700000000-0-abcdef'), isFalse);
      expect(out.contains('eyJhbGciOi'), isFalse);
      expect(out.contains('cafe01'), isFalse);
      expect(out.contains('wsSecret=<redacted>'), isTrue);
      expect(out.contains('auth_key=<redacted>'), isTrue);
      expect(out.contains('access_token=<redacted>'), isTrue);
      expect(out.contains('X-Amz-Signature=<redacted>'), isTrue);
      // 短键 t/v 保持精确匹配（design §3.5 口径，v 常为上游签名版本参数）。
      expect(out.contains('v=<redacted>'), isTrue);
    });

    test('凭据类请求头整键删除', () {
      final out = CastDiagnostics.redactedHeaders(const {
        'Cookie': 'sid=secret-value',
        'Authorization': 'Bearer secret-token',
        'X-Api-Key': 'secret-key',
        'SOAPACTION': '"urn:schemas-upnp-org:service:AVTransport:1#Play"',
        'Content-Type': 'text/xml; charset="utf-8"',
      });
      expect(out.containsKey('Cookie'), isFalse);
      expect(out.containsKey('Authorization'), isFalse);
      expect(out.containsKey('X-Api-Key'), isFalse);
      expect(out['SOAPACTION'], '"urn:schemas-upnp-org:service:AVTransport:1#Play"');
      expect(out['Content-Type'], 'text/xml; charset="utf-8"');
    });

    test('DIDL 的 dc:description 整体替换为 <headers-redacted>', () {
      final out = CastDiagnostics.redactReportText(
          '<item><dc:description>{"Referer":"https://example.com/a?token=x"}</dc:description>'
          '<dc:title>剧名</dc:title></item>');
      expect(out.contains('Referer'), isFalse);
      expect(out.contains('example.com'), isFalse);
      expect(out.contains('<headers-redacted>'), isTrue);
      expect(out.contains('<dc:title>剧名</dc:title>'), isTrue);
    });

    test('SOAP 记录进入报告但不泄露凭据/token/签名', () {
      const token = 'Zx9Wv8Ut7Sr6Qp5On4Ml3Kj2Jh1Gf0Dc';
      final d = CastDiagnostics();
      d.beginSession(deviceName: '客厅电视', protocol: 'dlna');
      d.setTarget(
        selectedIp: '192.168.1.5',
        mediaUrl: 'http://192.168.1.5:18280/p/$token/index.m3u8',
        mediaPort: 18280,
      );
      d.recordSoap(SoapTrace(
        action: 'SetAVTransportURI',
        requestHeaders: const {
          'Cookie': 'sid=leak-me',
          'Authorization': 'Bearer leak-me-too',
          'SOAPACTION': '"urn:x#SetAVTransportURI"',
        },
        requestBody: '<CurrentURI>http://192.168.1.5:18280/p/$token/index.m3u8'
            '?sign=abcdef</CurrentURI>'
            '<CurrentURIMetaData><![CDATA[<DIDL-Lite>'
            '<dc:description>{"Referer":"https://priv.example.com/v.m3u8"}</dc:description>'
            '</DIDL-Lite>]]></CurrentURIMetaData>',
        httpStatus: 200,
        responseBody: '<u:SetAVTransportURIResponse/>',
      ));
      final report = d.toRedactedReport();
      expect(report.contains('leak-me'), isFalse);
      expect(report.contains('Cookie'), isFalse);
      expect(report.contains('Authorization'), isFalse);
      expect(report.contains(token), isFalse);
      expect(report.contains('<token>'), isTrue);
      expect(report.contains('abcdef'), isFalse);
      expect(report.contains('sign=<redacted>'), isTrue);
      expect(report.contains('priv.example.com'), isFalse);
      expect(report.contains('<headers-redacted>'), isTrue);
      // 非敏感信息保留。
      expect(report.contains('SOAPACTION'), isTrue);
      expect(report.contains('HTTP 200'), isTrue);
      expect(report.contains('SetAVTransportURIResponse'), isTrue);
    });
  });

  group('面板级 vs 导出级（review §8.4 两级脱敏）', () {
    test('面板 mediaUrl 保留完整 token，导出报告不出现 token', () {
      const token = 'Qw8Er5Ty2Ui1Op0As9Df7Gh4Jk3Lz6Xc';
      final d = CastDiagnostics();
      d.beginSession(protocol: 'dlna');
      d.setTarget(
        selectedIp: '192.168.1.5',
        mediaUrl: 'http://192.168.1.5:18280/p/$token/index.m3u8',
        mediaPort: 18280,
      );
      // 面板级：完整 URL（含 token），供另一台设备浏览器自测。
      expect(d.mediaUrl, 'http://192.168.1.5:18280/p/$token/index.m3u8');
      // 导出级：token 被抹掉。
      final report = d.toRedactedReport();
      expect(report.contains(token), isFalse);
      expect(report.contains('/p/<token>/index.m3u8'), isTrue);
      expect(report.contains('http://192.168.1.5:18280'), isTrue);
    });

    test('无会话时目标字段为空态', () {
      final d = CastDiagnostics();
      expect(d.mediaUrl, isNull);
      expect(d.selectedIp, isNull);
      expect(d.mediaPort, isNull);
      expect(d.hasSession, isFalse);
      final report = d.toRedactedReport();
      expect(report.contains('未采集'), isTrue);
    });
  });

  group('报告生成', () {
    test('包含判定/设备/Sink/取流/时间线章节', () {
      final d = CastDiagnostics();
      d.beginSession(deviceName: '客厅电视', protocol: 'dlna');
      d.setTarget(selectedIp: '192.168.1.5', mediaPort: 18280);
      d.recordSinks(const ['http-get:*:video/mp4:*', 'http-get:*:video/mpeg:*']);
      d.recordSoap(SoapTrace(
        action: 'SetAVTransportURI',
        requestBody: '<s:Envelope/>',
        httpStatus: 200,
      ));
      d.recordMediaRequest(MediaRequestTrace(
        url: '/m/AbCdEf0123456789AbCdEf0123456789',
        method: 'GET',
        range: 'bytes=0-',
        userAgent: 'DALISHI/1.0',
        statusCode: 206,
        bytesServed: 2048,
        source: 'local',
      ));
      d.recordTimeline('connecting → 客厅电视（192.168.1.8）');
      d.recordDeviceSummary('friendlyName=客厅电视 · model=X1 · udn=uuid:1');
      d.recordSsdpResponse('HTTP/1.1 200 OK\r\nST: upnp:rootdevice\r\n\r\n');
      final report = d.toRedactedReport();
      expect(report.contains('== 投屏诊断报告 =='), isTrue);
      expect(report.contains('失败判定'), isTrue);
      expect(report.contains('目标设备：客厅电视'), isTrue);
      expect(report.contains('本机 IP：192.168.1.5'), isTrue);
      expect(report.contains('监听端口：18280'), isTrue);
      expect(report.contains('http-get:*:video/mp4:*'), isTrue);
      expect(report.contains('SOAP 记录'), isTrue);
      expect(report.contains('电视取流记录'), isTrue);
      expect(report.contains('Range=bytes=0-'), isTrue);
      expect(report.contains('206'), isTrue);
      expect(report.contains('2048B'), isTrue);
      expect(report.contains('状态时间线'), isTrue);
      expect(report.contains('transportState='),
          isFalse); // 本测试时间线没有状态条目
      expect(report.contains('connecting → 客厅电视'), isTrue);
      expect(report.contains('设备描述摘要'), isTrue);
      expect(report.contains('SSDP 原始响应'), isTrue);
    });

    test('判定为 acceptedButNotFetched 时报告含人话解释', () {
      final d = CastDiagnostics();
      d.beginSession(protocol: 'dlna');
      d.recordSoap(SoapTrace(
        action: 'SetAVTransportURI',
        requestBody: '<s:Envelope/>',
        httpStatus: 200,
      ));
      final report = d.toRedactedReport();
      expect(report.contains(CastVerdict.acceptedButNotFetched.label), isTrue);
      expect(report.contains(CastVerdict.acceptedButNotFetched.hint), isTrue);
    });

    test('SOAP trace 上限保留最近', () {
      final d = CastDiagnostics();
      final n = CastDiagnostics.maxSoapTraces + 5;
      for (var i = 0; i < n; i++) {
        d.recordSoap(SoapTrace(action: 'A$i', requestBody: ''));
      }
      expect(d.soapTraces.length, CastDiagnostics.maxSoapTraces);
      expect(d.soapTraces.last.action, 'A${n - 1}');
      expect(d.soapTraces.first.action, 'A5');
    });

    test('R2.1：时间线逐行过导出级脱敏（URL token/签名 query 不外泄）', () {
      const token = 'Aa1Bb2Cc3Dd4Ee5Ff6Gg7Hh8Ii9Jj0Kk';
      final d = CastDiagnostics();
      d.beginSession(deviceName: '客厅电视', protocol: 'dlna');
      // 时间线可能内嵌异常消息里的投屏 URL（防御纵深：不能只靠面板拼接脱敏）。
      d.recordTimeline('投屏失败：http://192.168.1.5:18280/p/$token/index.m3u8'
          '?sign=abc123 已被设备拒绝');
      final report = d.toRedactedReport();
      expect(report.contains(token), isFalse);
      expect(report.contains('/p/<token>/index.m3u8'), isTrue);
      expect(report.contains('sign=<redacted>'), isTrue);
      // 面板级时间线视图保持原样（供自测）。
      expect(d.timeline.first.contains(token), isTrue);
    });

    test('R1.3：深度诊断扫描汇总入报告（recordScanSummary / beginSession 清空）',
        () {
      final d = CastDiagnostics();
      d.beginSession(protocol: 'dlna');
      d.recordScanSummary(const [
        '共尝试 10 个组合，受理 2 个；仅验证受理，不验证播放；结果不写入配方记忆',
        '  full+standard → 受理 (0.3s)',
        '  compact+standard → fault 401 (0.1s)',
      ]);
      final report = d.toRedactedReport();
      expect(report.contains('-- 深度诊断扫描汇总 --'), isTrue);
      expect(report.contains('full+standard → 受理 (0.3s)'), isTrue);
      expect(report.contains('fault 401'), isTrue);
      // 新会话清空汇总（重投后不残留旧扫描）。
      d.beginSession(protocol: 'dlna');
      expect(d.scanSummary, isEmpty);
      expect(d.toRedactedReport().contains('深度诊断扫描汇总'), isFalse);
    });

    test('SSDP 报文截断、去重与上限', () {
      final d = CastDiagnostics();
      final packet =
          'HTTP/1.1 200 OK\r\nST: upnp:rootdevice\r\nUSN: uuid:1\r\nLOCATION: http://192.168.1.8/dd.xml\r\n\r\n';
      d.recordSsdpResponse(packet);
      d.recordSsdpResponse(packet); // 去重
      expect(d.ssdpResponses.length, 1);
      final huge = 'HTTP/1.1 200 OK\r\nX: ${'a' * 9000}\r\n\r\n';
      d.recordSsdpResponse(huge);
      expect(d.ssdpResponses.last.length,
          lessThanOrEqualTo(CastDiagnostics.maxRawLength + 10));
      for (var i = 0; i < CastDiagnostics.maxSsdpResponses + 3; i++) {
        d.recordSsdpResponse('HTTP/1.1 200 OK\r\nUSN: uuid:$i\r\n\r\n');
      }
      expect(d.ssdpResponses.length, CastDiagnostics.maxSsdpResponses);
    });

    test('setTarget 只覆盖非 null 字段（连播换集只换 URL）', () {
      final d = CastDiagnostics();
      d.setTarget(selectedIp: '192.168.1.5', mediaPort: 18280,
          mediaUrl: 'http://192.168.1.5:18280/p/a/index.m3u8');
      d.setTarget(mediaUrl: 'http://192.168.1.5:18280/p/b/index.m3u8');
      expect(d.selectedIp, '192.168.1.5');
      expect(d.mediaPort, 18280);
      expect(d.mediaUrl, 'http://192.168.1.5:18280/p/b/index.m3u8');
    });
  });

  group('防火墙指引', () {
    test('program 级放行命令形状（M0-4）', () {
      expect(
        CastDiagnostics.buildWindowsFirewallCommand(
            programPath: r'C:\app\aquan_duanju.exe'),
        r'netsh advfirewall firewall add rule name="aquan-duanju" dir=in '
        r'action=allow program="C:\app\aquan_duanju.exe" profile=private,domain '
        r'remoteip=localsubnet',
      );
    });
  });

  // 中继完成度（11-09-cast-dlna-android-fix）：中途停止取流要能被判出来，
  // 否则报告一直显示「无失败」，用户只能猜。
  group('中继会话快照（11-09）', () {
    CastRelaySnapshot snapshot({
      bool ended = false,
      int exitCode = -1,
      bool stalled = false,
      int segments = 14,
      int lastSegIndex = 10,
      Duration duration = const Duration(seconds: 30),
      String session = '',
    }) =>
        CastRelaySnapshot(
          session: session,
          format: 'hls',
          segments: segments,
          duration: duration,
          ended: ended,
          endlisted: ended,
          stalled: stalled,
          lastAccess: const Duration(seconds: 13),
          exitCode: exitCode,
          lastSegIndex: lastSegIndex,
        );

    test('fromStatus：旧核心（无 ended 字段）返回 null，不误判', () {
      expect(CastRelaySnapshot.fromStatus(const {'format': 'hls'}), isNull);
      final snap = CastRelaySnapshot.fromStatus(const {
        'format': 'hls',
        'segments': 14,
        'durationMs': 42000,
        'ended': true,
        'endlisted': true,
        'stalled': false,
        'lastAccessMs': 900,
        'exitCode': 0,
        'lastSegIndex': 13,
      });
      expect(snap, isNotNull);
      expect(snap!.duration, const Duration(seconds: 42));
      expect(snap.completedCleanly, isTrue);
      expect(snap.playedToEnd, isTrue);
      expect(snap.lastAccess, const Duration(milliseconds: 900));
    });

    test('播放确认后转码未结束且已停止取流 → streamStalled', () {
      final d = CastDiagnostics();
      d.beginSession(protocol: 'dlna');
      d.recordSoap(SoapTrace(
        action: 'SetAVTransportURI',
        requestBody: '<s:Envelope/>',
        httpStatus: 200,
      ));
      d.recordMediaRequest(MediaRequestTrace(
        url: '/cast/AbCdEf0123456789AbCdEf0123456789/seg_00003.ts',
        method: 'GET',
        statusCode: 206,
        bytesServed: 1024,
      ));
      d.recordTimeline('transportState=PLAYING');
      d.recordRelayState(snapshot(stalled: true, lastSegIndex: 10));
      expect(d.computeVerdict(), CastVerdict.streamStalled);
      expect(d.toRedactedReport().contains('-- 中继会话 --'), isTrue);
      expect(d.toRedactedReport().contains('停滞判定：是'), isTrue);
    });

    test('正常收尾的中继不报停滞（播放确认 → 无判定）', () {
      final d = CastDiagnostics();
      d.beginSession(protocol: 'dlna');
      d.recordTimeline('transportState=PLAYING');
      d.recordRelayState(snapshot(ended: true, exitCode: 0, lastSegIndex: 13));
      expect(d.computeVerdict(), isNull);
      final report = d.toRedactedReport();
      expect(report.contains('ffmpeg：已退出（code=0）'), isTrue);
      expect(report.contains('已产出分片：14（电视已取到 #13）'), isTrue);
      expect(report.contains('ENDLIST=是'), isTrue);
    });

    test('报告段：只取清单未拉分片 / 转码中 / 明细字段（11-10 口径）', () {
      final d = CastDiagnostics();
      d.beginSession(protocol: 'dlna');
      d.recordRelayState(snapshot(lastSegIndex: -1));
      final report = d.toRedactedReport();
      expect(report.contains('电视只取了清单，未拉分片'), isTrue);
      expect(report.contains('ffmpeg：转码中'), isTrue);
      expect(report.contains('清单时长：30.0s'), isTrue);
      expect(report.contains('最近取流：13.0s前'), isTrue);
    });

    test('报告段：hls 无任何产物 → 未取流（不再与分片数自相矛盾）', () {
      final d = CastDiagnostics();
      d.beginSession(protocol: 'dlna');
      d.recordRelayState(snapshot(segments: 0, lastSegIndex: -1));
      final report = d.toRedactedReport();
      expect(report.contains('已产出分片：0（未取流）'), isTrue);
    });

    test('报告段：ts 档用已送出字节表达进度 + 最近产出（11-10）', () {
      final d = CastDiagnostics();
      d.beginSession(protocol: 'dlna');
      d.recordRelayState(CastRelaySnapshot(
        format: 'ts',
        segments: 0,
        duration: Duration.zero,
        ended: false,
        endlisted: false,
        stalled: false,
        lastAccess: const Duration(seconds: 1),
        exitCode: -1,
        lastSegIndex: -1,
        servedBytes: 873 * 1024,
        lastProduce: const Duration(seconds: 2),
      ));
      final report = d.toRedactedReport();
      expect(report.contains('已送出 873KB'), isTrue);
      expect(report.contains('最近产出：2.0s前'), isTrue);
      expect(report.contains('电视只取了清单，未拉分片'), isFalse);
    });

    test('fromStatus：servedBytes / lastProduceMs 透传，旧核心保持 null', () {
      final snap = CastRelaySnapshot.fromStatus(const {
        'format': 'ts',
        'segments': 0,
        'durationMs': 0,
        'ended': false,
        'endlisted': false,
        'stalled': false,
        'lastAccessMs': 100,
        'exitCode': -1,
        'lastSegIndex': -1,
        'servedBytes': 2048,
        'lastProduceMs': 1500,
      });
      expect(snap!.servedBytes, 2048);
      expect(snap.lastProduce, const Duration(milliseconds: 1500));
      final old = CastRelaySnapshot.fromStatus(const {
        'format': 'hls',
        'segments': 0,
        'durationMs': 0,
        'ended': false,
        'endlisted': false,
        'stalled': false,
        'lastAccessMs': 0,
        'exitCode': -1,
        'lastSegIndex': -1,
      });
      expect(old!.servedBytes, 0);
      expect(old.lastProduce, isNull, reason: '旧核心无该字段不能误报停滞');
    });

    test('beginSession 清空中继快照（重投不残留旧会话）', () {
      final d = CastDiagnostics();
      d.beginSession(protocol: 'dlna');
      d.recordRelayState(snapshot(ended: true, exitCode: 0));
      expect(d.relayState, isNotNull);
      d.beginSession(protocol: 'dlna');
      expect(d.relayState, isNull);
      expect(d.toRedactedReport().contains('-- 中继会话 --'), isFalse);
    });

    test('会话归属：非当前会话的快照与目标字段被丢弃（11-09 二期）', () {
      final d = CastDiagnostics();
      d.beginSession(protocol: 'dlna');
      d.activeRelaySession = 'S-current';

      // 旧会话（换集/重投前）的快照不得覆盖本次会话。
      d.recordRelayState(snapshot(session: 'S-old', stalled: true));
      expect(d.relayState, isNull);
      d.recordRelayState(snapshot(session: 'S-current'));
      expect(d.relayState, isNotNull);

      // 目标字段同样按会话过滤：真机报告里「本机 IP 127.0.0.1」就是旧会话写的。
      d.setTarget(selectedIp: '127.0.0.1', relaySession: 'S-old');
      expect(d.selectedIp, isNull);
      d.setTarget(selectedIp: '192.168.31.163', relaySession: 'S-current');
      expect(d.selectedIp, '192.168.31.163');

      // 不带会话的调用（_traceTarget 等）不受影响。
      d.setTarget(mediaUrl: 'http://192.168.31.163:29171/cast/x/index.m3u8');
      expect(d.mediaUrl, contains('29171'));
    });

    test('beginSession 清空 activeRelaySession', () {
      final d = CastDiagnostics();
      d.beginSession(protocol: 'dlna');
      d.activeRelaySession = 'S1';
      expect(d.activeRelaySession, 'S1');
      d.beginSession(protocol: 'dlna');
      expect(d.activeRelaySession, isEmpty);
    });
  });
}
