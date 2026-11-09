import 'package:flutter_test/flutter_test.dart';

import 'package:aquan_duanju/core/series_meta.dart';
import 'package:aquan_duanju/models/models.dart';

SeriesDetail _detail(
  String id, {
  int heat = 0,
  int playCount = 0,
  List<String> tags = const [],
}) =>
    SeriesDetail(
      series: Series(
        id: id,
        heat: heat,
        playCount: playCount,
        rows: [
          const InfoRow(kind: 0, text: '第1季'),
          for (final tag in tags) InfoRow(kind: 3, text: tag),
          // 空白标签行必须跳过（服务端偶尔下发空 content）。
          if (tags.isNotEmpty) const InfoRow(kind: 3, text: '  '),
        ],
      ),
    );

SeriesSummary _item(
  String id, {
  int heat = 0,
  int playCount = 0,
  List<String> tags = const [],
}) =>
    SeriesSummary(
      id: id,
      title: id,
      heat: heat,
      playCount: playCount,
      tags: tags,
    );

void main() {
  test('补全搜索行缺失的热度与标签，列表已有的播放量不被覆盖', () async {
    final enricher = SeriesMetaEnricher();
    final items = [
      _item('7000000000000000001', playCount: 10),
      _item('7000000000000000002'),
    ];
    var asked = <String>[];
    final out = await enricher.enrich(items, (ids) async {
      asked = ids;
      return [
        _detail('7000000000000000001',
            heat: 100, playCount: 999, tags: ['冒险', '3D']),
        _detail('7000000000000000002', heat: 200, tags: ['重生逆袭']),
      ];
    });

    expect(asked, ['7000000000000000001', '7000000000000000002']);
    expect(out.map((e) => e.id), ['7000000000000000001', '7000000000000000002']);
    expect(out[0].heat, 100);
    expect(out[0].playCount, 10, reason: '列表已有的播放量优先于详情');
    expect(out[0].tags, ['冒险', '3D']);
    expect(out[1].heat, 200);
    expect(out[1].tags, ['重生逆袭']);
  });

  test('列表自带标签只缺热度时，保留列表标签、只补热度', () async {
    final enricher = SeriesMetaEnricher();
    final out = await enricher.enrich(
      [_item('7000000000000000001', tags: ['古装'])],
      (ids) async => [
        _detail('7000000000000000001', heat: 48000000, tags: ['冒险', '3D']),
      ],
    );

    expect(out, hasLength(1));
    expect(out.single.heat, 48000000);
    expect(out.single.tags, ['古装'], reason: '列表标签优先，避免同源字段抖动');
  });

  test('热度与标签都齐的条目不请求详情', () async {
    final enricher = SeriesMetaEnricher();
    var called = 0;
    final out = await enricher.enrich(
      [_item('7000000000000000001', heat: 4800, tags: ['古装'])],
      (ids) async {
        called++;
        return const [];
      },
    );

    expect(called, 0);
    expect(out, isEmpty);
  });

  test('会话缓存：同一部剧只拉一次，后续页面直接命中', () async {
    final enricher = SeriesMetaEnricher();
    var calls = 0;
    Future<List<SeriesDetail>> fetch(List<String> ids) async {
      calls++;
      return [_detail(ids.single, heat: 123, tags: ['逆袭'])];
    }

    await enricher.enrich([_item('7000000000000000001')], fetch);
    final second = await enricher.enrich([_item('7000000000000000001')], fetch);

    expect(calls, 1);
    expect(second.single.heat, 123);
    expect(second.single.tags, ['逆袭']);
  });

  test('非数字 ID 不发送；重复 ID 只发一次', () async {
    final enricher = SeriesMetaEnricher();
    var asked = <String>[];
    final out = await enricher.enrich(
      [
        _item('BV1xx411c7mD'),
        _item('7000000000000000001'),
        _item('7000000000000000001'),
      ],
      (ids) async {
        asked = ids;
        return [_detail('7000000000000000001', heat: 1, tags: ['系统'])];
      },
    );

    expect(asked, ['7000000000000000001']);
    expect(out, hasLength(1));
  });

  test('详情没返回的 ID 记为 miss，本会话不再重试', () async {
    final enricher = SeriesMetaEnricher();
    var calls = 0;
    Future<List<SeriesDetail>> fetch(List<String> ids) async {
      calls++;
      return const [];
    }

    await enricher.enrich([_item('7000000000000000009')], fetch);
    await enricher.enrich([_item('7000000000000000009')], fetch);

    expect(calls, 1);
  });

  test('补全失败静默：不抛异常，封面维持列表数据', () async {
    final enricher = SeriesMetaEnricher();
    final out = await enricher.enrich(
      [_item('7000000000000000001', playCount: 5)],
      (ids) async => throw StateError('network down'),
    );

    expect(out, isEmpty);
  });
}
