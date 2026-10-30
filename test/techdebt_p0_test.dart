import 'dart:io';

import 'package:aquan_duanju/core/search/query_intent.dart';
import 'package:aquan_duanju/store/stores.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('searchTerms：条件下翻译成搜索词', () {
    test('纯条件句 → 题材 + 类型 + 年份', () {
      expect(
        QueryIntent.parse('2024年9分以上的悬疑剧').searchTerms,
        '悬疑 电视剧 2024',
      );
    });

    test('有关键词时带上人名', () {
      expect(QueryIntent.parse('周星驰的喜剧').searchTerms, '喜剧 周星驰');
    });

    test('地区词转成搜索词', () {
      expect(QueryIntent.parse('韩剧').searchTerms, '电视剧 韩国');
    });

    test('普通词原样保留', () {
      expect(QueryIntent.parse('甄嬛传').searchTerms, '甄嬛传');
    });
  });

  group('章节缓存双阈值', () {
    late Directory dir;
    late BookChapterCache cache;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('cache_bytes');
      cache = BookChapterCache(testDirectory: dir);
      await cache.ensureLoaded();
      // setter 最小接受 1MB。
      cache.maxBytes = 1024 * 1024;
    });

    tearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    test('超出字节上限时淘汰最旧的', () async {
      final big = 'x' * 600 * 1024; // UTF-16 约 1.2MB
      await cache.put('a', big);
      await cache.put('b', big);
      expect(cache.totalBytes, greaterThan(cache.maxBytes));
      // 最新的保留，最旧的被淘汰。
      expect(cache.text('b'), isNotNull);
      expect(cache.text('a'), isNull);
    });

    test('至少保留一条（单条就超上限时）', () async {
      final huge = 'y' * 900 * 1024; // 约 1.8MB > 1MB
      await cache.put('only', huge);
      expect(cache.text('only'), isNotNull);
      expect(cache.totalBytes, greaterThan(cache.maxBytes));
    });

    test('未超限时全部保留', () async {
      await cache.put('a', 'short');
      await cache.put('b', 'short');
      expect(cache.totalBytes, lessThan(cache.maxBytes));
      expect(cache.text('a'), 'short');
      expect(cache.text('b'), 'short');
    });

    test('totalBytes 按 UTF-16 估算', () async {
      await cache.put('a', 'abcd');
      expect(cache.totalBytes, 8);
    });
  });
}
