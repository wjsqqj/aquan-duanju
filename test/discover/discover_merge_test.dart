import 'package:aquan_duanju/core/discover_merge.dart';
import 'package:aquan_duanju/models/models.dart';
import 'package:flutter_test/flutter_test.dart';

SeriesSummary _series(String id) =>
    SeriesSummary(id: id, title: id, coverUrl: 'https://example.com/$id.jpg');

void main() {
  group('mergeDiscoverItems（新内容在前、缓存垫后）', () {
    test('新一页排前面，缓存里没出现过的补在后面', () {
      final merged = mergeDiscoverItems<SeriesSummary>(
        [_series('n1'), _series('n2')],
        [_series('c1'), _series('c2')],
        idOf: (item) => item.id,
      );
      expect(merged.map((e) => e.id), ['n1', 'n2', 'c1', 'c2']);
    });

    test('同一部剧只留新页里的那份（顺序以新页为准）', () {
      final merged = mergeDiscoverItems<SeriesSummary>(
        [_series('a'), _series('b')],
        [_series('b'), _series('a'), _series('c')],
        idOf: (item) => item.id,
      );
      expect(merged.map((e) => e.id), ['a', 'b', 'c']);
    });

    test('缓存为空时等于直接用新页', () {
      final merged = mergeDiscoverItems<SeriesSummary>(
        [_series('a')],
        const <SeriesSummary>[],
        idOf: (item) => item.id,
      );
      expect(merged.single.id, 'a');
    });

    test('新页为空时保留全部缓存（刷新回来空列表不闪没）', () {
      final merged = mergeDiscoverItems<SeriesSummary>(
        const <SeriesSummary>[],
        [_series('a'), _series('b')],
        idOf: (item) => item.id,
      );
      expect(merged.map((e) => e.id), ['a', 'b']);
    });

    test('id 为空的条目保留且不参与去重', () {
      final merged = mergeDiscoverItems<SeriesSummary>(
        [_series(''), _series('')],
        [_series('a')],
        idOf: (item) => item.id,
      );
      expect(merged.length, 3);
    });
  });
}
