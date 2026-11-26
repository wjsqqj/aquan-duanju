import 'package:aquan_duanju/core/search/source_merge.dart';
import 'package:aquan_duanju/models/models.dart';
import 'package:flutter_test/flutter_test.dart';

SeriesSummary _hg(String id, [String title = '红果剧']) =>
    SeriesSummary(id: id, title: title);

SeriesSummary _xf(String id, [String title = '西饭剧']) => SeriesSummary(
      id: id,
      title: title,
      kind: 'xifan',
    );

void main() {
  group('composeSearchResults', () {
    test('全部来源：红果在前、西饭在后', () {
      final out = composeSearchResults(
        hongguo: [_hg('1'), _hg('2')],
        xifan: [_xf('xifan:a:b')],
        filter: SearchSourceFilter.all,
      );
      expect(out.map((e) => e.id), ['1', '2', 'xifan:a:b']);
    });

    test('只看红果', () {
      final out = composeSearchResults(
        hongguo: [_hg('1')],
        xifan: [_xf('xifan:a:b')],
        filter: SearchSourceFilter.hongguo,
      );
      expect(out.map((e) => e.id), ['1']);
    });

    test('只看西饭', () {
      final out = composeSearchResults(
        hongguo: [_hg('1')],
        xifan: [_xf('xifan:a:b')],
        filter: SearchSourceFilter.xifan,
      );
      expect(out.map((e) => e.id), ['xifan:a:b']);
    });

    test('跨源同剧不去重（两个来源各自可播，保留来源信息）', () {
      final out = composeSearchResults(
        hongguo: [_hg('1', '同名剧')],
        xifan: [_xf('xifan:a:b', '同名剧')],
        filter: SearchSourceFilter.all,
      );
      expect(out, hasLength(2));
    });

    test('空输入不抛', () {
      expect(
        composeSearchResults(
          hongguo: const [],
          xifan: const [],
          filter: SearchSourceFilter.all,
        ),
        isEmpty,
      );
    });
  });

  group('筛选能力位', () {
    test('showsHongguo / showsXifan 互补', () {
      expect(showsHongguo(SearchSourceFilter.all), isTrue);
      expect(showsXifan(SearchSourceFilter.all), isTrue);
      expect(showsHongguo(SearchSourceFilter.xifan), isFalse);
      expect(showsXifan(SearchSourceFilter.hongguo), isFalse);
    });

    test('来源角标只给西饭', () {
      expect(searchSourceBadge(_hg('1')), isNull);
      expect(searchSourceBadge(_xf('xifan:a:b')), '西饭');
    });

    test('每个筛选都有可读标签', () {
      for (final f in SearchSourceFilter.values) {
        expect(f.label.trim(), isNotEmpty);
      }
    });
  });
}
