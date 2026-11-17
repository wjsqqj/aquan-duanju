import 'package:aquan_duanju/core/history_filters.dart';
import 'package:aquan_duanju/store/stores.dart';
import 'package:flutter_test/flutter_test.dart';

HistoryEntry entry(String id, String contentType, {bool finished = false}) =>
    HistoryEntry(
      seriesId: id,
      title: id,
      episode: 1,
      episodes: 10,
      position: 30,
      finished: finished,
      contentType: contentType,
    );

void main() {
  group('继续观看分类隔离', () {
    test('只看当前类型的未看完记录', () {
      final all = [
        entry('a', '短剧'),
        entry('b', '漫剧'),
        entry('c', '电影'),
        entry('d', '短剧', finished: true),
      ];
      expect(
        resumableHistoryFor(all, '短剧').map((e) => e.seriesId),
        ['a'],
      );
      expect(
        resumableHistoryFor(all, '漫剧').map((e) => e.seriesId),
        ['b'],
      );
      expect(
        resumableHistoryFor(all, '电影').map((e) => e.seriesId),
        ['c'],
      );
    });

    test('旧记录（contentType 为空）归到短剧，不会从所有分类消失', () {
      final legacy = entry('legacy', '');
      expect(contentTypeForHistory(legacy), '短剧');
      expect(resumableHistoryFor([legacy], '短剧').length, 1);
      expect(resumableHistoryFor([legacy], '漫剧'), isEmpty);
    });

    test('limit 生效', () {
      final many = [for (var i = 0; i < 20; i++) entry('s$i', '短剧')];
      expect(resumableHistoryFor(many, '短剧', limit: 5).length, 5);
    });

    test('HistoryEntry JSON 往返保留 contentType', () {
      final original = entry('x', '漫剧');
      final restored = HistoryEntry.fromJson(original.toJson());
      expect(restored.contentType, '漫剧');
    });

    test('旧 JSON 没有 content_type → 空字符串（兜底由读取端处理）', () {
      final restored = HistoryEntry.fromJson(<String, dynamic>{
        'series_id': 'old',
      });
      expect(restored.contentType, '');
    });
  });
}
