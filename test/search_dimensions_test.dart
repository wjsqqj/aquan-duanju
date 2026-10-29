import 'package:flutter_test/flutter_test.dart';
import 'package:aquan_duanju/core/search_dimensions.dart';

void main() {
  group('SearchDimension', () {
    test('内容维度走综合 tab 并接受筛选', () {
      expect(SearchDimension.content.tab, isEmpty);
      expect(SearchDimension.content.allowsFilters, isTrue);
      expect(
        SearchDimension.content.filtersFor(const ['a']),
        const ['a'],
      );
    });

    test('讨论维度走讨论 tab 且丢弃筛选', () {
      expect(SearchDimension.discussion.tab, '讨论');
      expect(SearchDimension.discussion.allowsFilters, isFalse);
      expect(SearchDimension.discussion.filtersFor(const ['a']), isEmpty);
    });

    test('空筛选原样传递', () {
      expect(SearchDimension.content.filtersFor(const []), isEmpty);
      expect(SearchDimension.discussion.filtersFor(const []), isEmpty);
    });

    test('标签唯一且非空', () {
      final labels = SearchDimension.values.map((d) => d.label).toSet();
      expect(labels.length, SearchDimension.values.length);
      expect(labels.every((l) => l.isNotEmpty), isTrue);
    });
  });
}
