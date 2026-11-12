import 'package:flutter_test/flutter_test.dart';

import 'package:aquan_duanju/core/history_cover_refresh.dart';
import 'package:aquan_duanju/models/models.dart';

void main() {
  group('fetchSeriesDetailsBatched', () {
    test('过滤空 id 与站外源 id，并去重', () async {
      final calls = <List<String>>[];
      Future<List<SeriesDetail>> fetch(List<String> ids) async {
        calls.add(ids);
        return [const SeriesDetail()];
      }

      final details = await fetchSeriesDetailsBatched(fetch, [
        ' 123456 ',
        'bili:v:1', // 站外源历史 key：整批发过去会被 SDK 拒绝
        '123456',
        '',
        '7777777',
      ]);

      expect(calls, [
        ['123456', '7777777'],
      ]);
      expect(details.length, 1);
    });

    test('每批 10 个且顺序不变', () async {
      final calls = <List<String>>[];
      Future<List<SeriesDetail>> fetch(List<String> ids) async {
        calls.add(ids);
        return const [];
      }

      final ids = [for (var i = 0; i < 25; i++) '${100000 + i}'];
      await fetchSeriesDetailsBatched(fetch, ids);

      expect(calls.map((c) => c.length), [10, 10, 5]);
      expect(calls.expand((c) => c).toList(), ids);
    });

    test('单批失败跳过，继续后面的批次', () async {
      var calls = 0;
      Future<List<SeriesDetail>> fetch(List<String> ids) async {
        calls++;
        if (calls == 2) throw StateError('boom');
        return [const SeriesDetail()];
      }

      final ids = [for (var i = 0; i < 25; i++) '${100000 + i}'];
      final details = await fetchSeriesDetailsBatched(fetch, ids);

      expect(calls, 3);
      expect(details.length, 2); // 第 1、3 批成功
    });

    test('没有可用的数字 id 时不发请求', () async {
      var calls = 0;
      Future<List<SeriesDetail>> fetch(List<String> ids) async {
        calls++;
        return const [];
      }

      final details = await fetchSeriesDetailsBatched(fetch, const [
        'bili:v:1',
        '',
        '  ',
      ]);

      expect(calls, 0);
      expect(details, isEmpty);
    });
  });
}
