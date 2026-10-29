import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import 'package:aquan_duanju/core/sources/qr_share_server.dart';

void main() {
  late QrShareServer server;
  late String qrUrl;
  String? submitted;

  setUp(() async {
    server = QrShareServer();
    server.onSubmit = (text) => submitted = text;
    qrUrl = await server.start();
    submitted = null;
  });

  tearDown(() => server.stop());

  http.Client direct() {
    final inner = HttpClient()..findProxy = (_) => 'DIRECT';
    return IOClient(inner);
  }

  group('QrShareServer', () {
    test('QR URL 指向内网 IP 与 token 路径', () {
      expect(qrUrl, contains('/'));
      final uri = Uri.parse(qrUrl);
      expect(uri.scheme, 'http');
      expect(uri.pathSegments.length, 1);
      expect(uri.pathSegments.first, hasLength(32));
    });

    test('GET 表单页含 textarea 与 action', () async {
      final res = await direct().get(Uri.parse(qrUrl));
      expect(res.statusCode, 200);
      expect(res.body, contains('<textarea'));
      expect(res.body, contains('action="/${Uri.parse(qrUrl).pathSegments.first}/submit"'));
    });

    test('POST 提交 → 回调收到原文；二次提交失效', () async {
      final token = Uri.parse(qrUrl).pathSegments.first;
      final config = '{"sites":[{"key":"a","name":"A","type":1,"api":"http://x/vod"}]}';
      final res = await direct().post(
        Uri.parse('http://127.0.0.1:${Uri.parse(qrUrl).port}/$token/submit'),
        headers: {'Content-Type': 'application/x-www-form-urlencoded'},
        body: 'config=${Uri.encodeQueryComponent(config)}',
      );
      expect(res.statusCode, 200);
      expect(res.body, contains('已提交'));
      expect(submitted, config);

      // 一次性：提交后 token 失效。
      final again = await direct().post(
        Uri.parse('http://127.0.0.1:${Uri.parse(qrUrl).port}/$token/submit'),
        headers: {'Content-Type': 'application/x-www-form-urlencoded'},
        body: 'config=x',
      );
      expect(again.statusCode, isNot(200));
      expect(submitted, config, reason: '回调只触发一次');
    });

    test('错误 token 404', () async {
      final port = Uri.parse(qrUrl).port;
      final res = await direct().get(Uri.parse('http://127.0.0.1:$port/wrongtoken'));
      expect(res.statusCode, 404);
    });

    test('导出模式：GET 返回配置页 + raw 下载', () async {
      await server.stop();
      final exportServer = QrShareServer();
      const config = '{"sites":[{"key":"a","name":"A","type":1,"api":"http://x/vod"}]}';
      final url = await exportServer.startExport(config);
      final token = Uri.parse(url).pathSegments.first;
      final page = await direct().get(Uri.parse(url));
      expect(page.statusCode, 200);
      expect(page.body, contains('来自阿圈短剧的配置'));
      expect(page.body, contains('&quot;api&quot;'), reason: 'textarea 内为 HTML 转义后的配置');
      final raw = await direct()
          .get(Uri.parse('http://127.0.0.1:${Uri.parse(url).port}/$token/raw'));
      expect(raw.body, config);
      // GET 不消费：可反复打开。
      final again = await direct().get(Uri.parse(url));
      expect(again.statusCode, 200);
      await exportServer.stop();
    });

    test('TTL 过期后 404', () async {
      final token = Uri.parse(qrUrl).pathSegments.first;
      // 直接把过期时间拨过去（不动私有字段：重启一个短 TTL 场景用 sleep 太慢）。
      await server.stop();
      final url2 = await server.start();
      final token2 = Uri.parse(url2).pathSegments.first;
      expect(token2, isNot(token));
      final res = await direct().get(Uri.parse('http://127.0.0.1:${Uri.parse(url2).port}/$token'));
      expect(res.statusCode, 404);
    });
  });
}
