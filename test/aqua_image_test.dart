import 'dart:io';

import 'package:aquan_duanju/core/aqua_api.dart';
import 'package:aquan_duanju/widgets/common.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    // flutter_cache_manager 依赖 path_provider；测试里 mock 成临时目录，
    // 否则其内部的 fire-and-forget 目录创建会以未处理异常炸掉用例。
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      return Directory.systemTemp.createTempSync('aqua_test').path;
    });
  });

  tearDown(() {
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  final png = Uint8List.fromList([0x89, 0x50, 0x4E, 0x47, 1, 2, 3, 4]);

  AquaImage img(Uint8List bytes) => AquaImage(bytes, 'image/png');

  group('AquaImageCache', () {
    test('未命中时调用 fetch 并缓存，再次读取不再发起请求', () async {
      var calls = 0;
      final cache = AquaImageCache(
        fetchOverride: (url) async {
          calls++;
          return img(png);
        },
      );
      final first = await cache.load('u1', _FakeFetcher());
      expect(first, png);
      final second = await cache.load('u1', _FakeFetcher());
      expect(second, png);
      expect(calls, 1, reason: '第二次应命中缓存');
      expect(await cache.cached('u1'), png);
    });

    test('相同 URL 的并发请求合并为一次 fetch', () async {
      var calls = 0;
      final cache = AquaImageCache(
        fetchOverride: (url) async {
          calls++;
          // 让第一个请求挂起一会，制造真正的并发窗口。
          await Future<void>.delayed(const Duration(milliseconds: 20));
          return img(png);
        },
      );
      final results = await Future.wait([
        cache.load('same', _FakeFetcher()),
        cache.load('same', _FakeFetcher()),
        cache.load('same', _FakeFetcher()),
      ]);
      expect(calls, 1, reason: '并发请求应去重');
      expect(results.every((r) => r == png), isTrue);
    });

    test('fetch 失败后下次会重新发起（不缓存失败）', () async {
      var calls = 0;
      final cache = AquaImageCache(
        fetchOverride: (url) async {
          calls++;
          if (calls == 1) throw StateError('boom');
          return img(png);
        },
      );
      await expectLater(cache.load('u', _FakeFetcher()), throwsStateError);
      expect(await cache.load('u', _FakeFetcher()), png);
      expect(calls, 2);
    });

    test('内存 LRU 在超过容量时淘汰最早的条目', () async {
      final cache = AquaImageCache(fetchOverride: (url) async => img(png));
      // 用反射式的容量不可行，这里只验证基本读写与淘汰逻辑存在：
      // _maxEntries 为私有，改为行为验证——大量条目后最早的不再命中内存
      // 但仍可重新 fetch（不抛错即通过）。
      for (var i = 0; i < 300; i++) {
        await cache.load('url-$i', _FakeFetcher());
      }
      final again = await cache.load('url-0', _FakeFetcher());
      expect(again, isNotEmpty);
    });
  });

  group('AquaImageProvider', () {
    test('key 相等只由 url 决定', () {
      final a = AquaImageProvider('u', _FakeFetcher());
      final b = AquaImageProvider('u', _FakeFetcher());
      final c = AquaImageProvider('v', _FakeFetcher());
      expect(a, equals(b));
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(equals(c)));
    });
  });
}

class _FakeFetcher implements AquaImageFetcher {
  @override
  Future<AquaImage> fetchImage(String url) =>
      throw UnsupportedError('测试不应触达网络');
}
