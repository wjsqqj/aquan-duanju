import 'package:aquan_duanju/core/reader/reader_settings.dart';
import 'package:aquan_duanju/core/search/query_intent.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('QueryIntent 结构化识别', () {
    test('年份 + 评分 + 题材 + 类型', () {
      final intent = QueryIntent.parse('2024年9分以上的悬疑剧');
      expect(intent.yearFrom, 2024);
      expect(intent.yearTo, 2024);
      expect(intent.minScore, 9);
      expect(intent.genres, contains('悬疑'));
      expect(intent.kinds, contains('电视剧'));
      expect(intent.keyword, isEmpty);
      expect(intent.summary, contains('2024年'));
      expect(intent.summary, contains('评分≥9'));
      expect(intent.summary, contains('悬疑'));
    });

    test('人名 + 题材', () {
      final intent = QueryIntent.parse('周星驰的喜剧');
      expect(intent.people, <String>['周星驰']);
      expect(intent.genres, contains('喜剧'));
      expect(intent.keyword, isEmpty);
    });

    test('地区词同时推断类型', () {
      final intent = QueryIntent.parse('韩剧');
      expect(intent.regions, contains('韩国'));
      expect(intent.kinds, contains('电视剧'));
      expect(intent.keyword, isEmpty);
    });

    test('年份区间', () {
      final intent = QueryIntent.parse('2022-2024年 科幻电影');
      expect(intent.yearFrom, 2022);
      expect(intent.yearTo, 2024);
      expect(intent.genres, contains('科幻'));
      expect(intent.kinds, contains('电影'));
    });

    test('近三年', () {
      final intent = QueryIntent.parse('近三年的高分剧');
      final now = DateTime.now().year;
      expect(intent.yearFrom, now - 2);
      expect(intent.yearTo, now);
    });

    test('显式导演标注', () {
      final intent = QueryIntent.parse('导演张艺谋');
      expect(intent.role, 'director');
      expect(intent.people, <String>['张艺谋']);
    });

    test('显式主演标注', () {
      final intent = QueryIntent.parse('主演周星驰');
      expect(intent.role, 'actor');
      expect(intent.people, <String>['周星驰']);
    });

    test('识别不到条件时原文不丢字', () {
      const raw = '甄嬛传';
      final intent = QueryIntent.parse(raw);
      expect(intent.keyword, raw);
      expect(intent.isEmpty, isFalse);
      expect(intent.yearFrom, isNull);
      expect(intent.genres, isEmpty);
    });

    test('部分识别时保留剩余关键词', () {
      final intent = QueryIntent.parse('悬疑 白夜追凶');
      expect(intent.genres, contains('悬疑'));
      expect(intent.keyword, '白夜追凶');
      expect(intent.summary, isNotEmpty);
    });

    test('停用词不被当人名', () {
      final intent = QueryIntent.parse('最好看的悬疑剧');
      expect(intent.people, isEmpty);
      expect(intent.genres, contains('悬疑'));
    });

    test('空输入', () {
      final intent = QueryIntent.parse('   ');
      expect(intent.isEmpty, isTrue);
      expect(intent.summary, isEmpty);
    });
  });

  group('双页设置', () {
    test('默认关闭并可往返', () {
      const base = ReaderSettings();
      expect(base.doublePage, isFalse);
      final restored = ReaderSettings.fromJson(
        base.copyWith(doublePage: true).toJson(),
      );
      expect(restored.doublePage, isTrue);
    });

    test('旧 JSON 缺字段时默认关闭', () {
      final restored = ReaderSettings.fromJson(<String, dynamic>{'schema': 2});
      expect(restored.doublePage, isFalse);
    });
  });
}
