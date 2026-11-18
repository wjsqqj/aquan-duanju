import 'package:flutter_test/flutter_test.dart';

import 'package:aquan_duanju/models/models.dart';

/// 搜索结果行的类型标记（bridge `kind`）。
///
/// 综合搜索会把帖子 / 书籍 / 用户一起摊平成 SeriesSummary；漏掉类型就会被
/// 当成短剧打开并命中 101001（用户实测「图文点开报错」）。
void main() {
  group('SeriesSummary.kind', () {
    test('fromJson 解析 kind，非剧类型不可按剧打开', () {
      final s = SeriesSummary.fromJson(<String, dynamic>{
        'id': '1',
        'title': '两部外国短剧，泰国、韩国，换个口味瞅瞅！',
        'kind': 'post',
      });
      expect(s.kind, 'post');
      expect(s.isSeriesLike, isFalse);
    });

    test('缺省 kind 兼容旧数据 / 目录流，按剧处理', () {
      final s = SeriesSummary.fromJson(<String, dynamic>{
        'id': '2',
        'title': '某部短剧',
      });
      expect(s.kind, '');
      expect(s.isSeriesLike, isTrue);
    });

    test('withMeta 必须原样保留 kind', () {
      final s = SeriesSummary.fromJson(<String, dynamic>{
        'id': '3',
        'kind': 'book',
      });
      final copy = s.withMeta(heat: 10, playCount: 20);
      expect(copy.kind, 'book');
      expect(copy.isSeriesLike, isFalse);
    });

    test('series 类型可按剧打开', () {
      const s = SeriesSummary(id: '4', kind: 'series');
      expect(s.isSeriesLike, isTrue);
    });
  });
}
