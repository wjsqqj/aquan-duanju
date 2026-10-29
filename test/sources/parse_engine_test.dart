import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:aquan_duanju/core/sources/parse_engine.dart';
import 'package:aquan_duanju/core/sources/source_adapter.dart';
import 'package:aquan_duanju/core/sources/source_import.dart';

void main() {
  test('isDirectMedia / needsParse', () {
    expect(ParseEngine.isDirectMedia('http://a/1.m3u8'), isTrue);
    expect(ParseEngine.isDirectMedia('http://a/1.mp4?sign=x'), isTrue);
    expect(ParseEngine.isDirectMedia('http://a/page/1'), isFalse);
    expect(ParseEngine.needsParse('http://a/page/1'), isTrue);
    expect(ParseEngine.needsParse('http://a/1.m3u8'), isFalse);
    expect(ParseEngine.needsParse('http://a/1.m3u8', jx: true), isTrue);
  });

  group('resolve（本地夹具）', () {
    late HttpServer server;
    late String base;

    setUp(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      base = 'http://127.0.0.1:${server.port}';
      server.listen((req) async {
        if (req.uri.path == '/p1') {
          req.response
              .write(jsonEncode({'code': 200, 'url': '$base/slow.m3u8'}));
        } else if (req.uri.path == '/p2') {
          // 慢接口：先到的 p1 应胜出。
          await Future<void>.delayed(const Duration(milliseconds: 200));
          req.response.write(jsonEncode({'url': '$base/other.m3u8'}));
        } else if (req.uri.path == '/bad') {
          req.response.statusCode = 500;
        }
        await req.response.close();
      });
    });

    tearDown(() => server.close(force: true));

    test('先返回者胜，其余被打断', () async {
      final engine = ParseEngine();
      final winner = await engine.resolve('http://page/1', parses: [
        ParseApi(name: '慢', url: '$base/p2?url='),
        ParseApi(name: '快', url: '$base/p1?url='),
      ]);
      expect(winner, isNotNull);
      expect(winner!.url, '$base/slow.m3u8');
      engine.close();
    });

    test('全部失败返回 null', () async {
      final engine = ParseEngine();
      final winner = await engine.resolve('http://page/1', parses: [
        ParseApi(name: '坏', url: '$base/bad?url='),
      ]);
      expect(winner, isNull);
      engine.close();
    });

    test('空解析列表直接 null；调用方 CancelToken 取消时不发请求', () async {
      final engine = ParseEngine();
      expect(await engine.resolve('http://page/1', parses: const []), isNull);
      final token = CancelToken()..cancel();
      final started = DateTime.now();
      final winner = await engine.resolve('http://page/1',
          parses: [ParseApi(name: '快', url: '$base/p1?url=')], cancel: token);
      expect(winner, isNull);
      expect(DateTime.now().difference(started).inMilliseconds, lessThan(100));
      engine.close();
    });
  });
}
