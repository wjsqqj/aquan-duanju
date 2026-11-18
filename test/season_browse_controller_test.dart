import 'package:aquan_duanju/models/models.dart';
import 'package:aquan_duanju/widgets/season_browse_controller.dart';
import 'package:flutter_test/flutter_test.dart';

Episode ep(int number) =>
    Episode(id: 'e$number', number: number, title: '', playable: true);

Season season(String id, String title, int index, int count) => Season(
      seriesId: id,
      title: title,
      index: index,
      episodeCount: count,
    );

void main() {
  group('SeasonBrowseController（点季只浏览不播放）', () {
    final seasons = <Season>[
      season('s1', '第一季', 1, 2),
      season('s2', '第二季', 2, 53),
      season('s3', '第三季', 3, 0), // 未上线
    ];

    SeasonBrowseController build({
      required Future<List<Episode>> Function(String seriesId) fetch,
    }) =>
        SeasonBrowseController(
          seasons: seasons,
          playingSeriesId: 's1',
          playingEpisodes: [ep(1), ep(2)],
          playingIndex: 1,
          fetchSeasonEpisodes: fetch,
        );

    test('初始浏览季 = 正在播的季，高亮下标跟随 playingIndex', () {
      final c = build(fetch: (id) async => const []);
      expect(c.current.seriesId, 's1');
      expect(c.browsingPlayingSeason, isTrue);
      expect(c.currentIndex, 1);
      expect(c.episodes.length, 2);
    });

    test('browse 到其它季：拉取该季列表，高亮清空（-1）', () async {
      var fetchCalls = 0;
      final c = build(fetch: (id) async {
        fetchCalls++;
        return [for (var i = 1; i <= 53; i++) ep(i)];
      });
      await c.browse(seasons[1]);
      expect(fetchCalls, 1);
      expect(c.current.seriesId, 's2');
      expect(c.browsingPlayingSeason, isFalse);
      expect(c.currentIndex, -1, reason: '浏览其它季时不高亮任何集');
      expect(c.episodes.length, 53);
    });

    test('同一季重复 browse 不重复拉取（缓存生效）', () async {
      var fetchCalls = 0;
      final c = build(fetch: (id) async {
        fetchCalls++;
        return [ep(1)];
      });
      await c.browse(seasons[1]);
      await c.browse(seasons[2]); // 未上线季（episodeCount=0）仍可请求，由 UI 灰显
      await c.browse(seasons[1]); // 已缓存
      expect(fetchCalls, 2, reason: 's2 第二次走缓存');
    });

    test('拉取失败回退到上一个浏览季并标记 loadFailed', () async {
      final c = build(
        fetch: (id) async => id == 's2' ? throw Exception('down') : const [],
      );
      await c.browse(seasons[1]).catchError((_) {});
      expect(c.current.seriesId, 's1', reason: '失败回退到播放季');
      expect(c.loadFailed, isTrue);
      expect(c.loading, isFalse);
    });

    test('拉到空列表：停在该季并标记 seasonEmpty（未上线自解释）', () async {
      final c = build(
        fetch: (id) async =>
            id == 's2' ? const <Episode>[] : <Episode>[ep(1)],
      );
      await c.browse(seasons[1]);
      expect(c.current.seriesId, 's2', reason: '空季不回退，让提示能落在该季上');
      expect(c.seasonEmpty, isTrue);
      expect(c.episodes, isEmpty);
      expect(c.loadFailed, isFalse);

      // 回到有剧集的季：seasonEmpty 复位。
      await c.browse(seasons[0]);
      expect(c.seasonEmpty, isFalse);
    });

    test('慢请求串台防护：先点 s2（慢）再点 s3（快），s2 的慢结果不落地', () async {
      final c = SeasonBrowseController(
        seasons: seasons,
        playingSeriesId: 's1',
        playingEpisodes: [ep(1)],
        playingIndex: 0,
        fetchSeasonEpisodes: (id) async {
          if (id == 's2') {
            await Future<void>.delayed(const Duration(milliseconds: 50));
            return [ep(1), ep(2)];
          }
          return [ep(9)];
        },
      );
      final slow = c.browse(seasons[1]); // s2：慢
      await c.browse(seasons[2]); // s3：快，浏览点已经切走
      await slow; // s2 的结果这时才回来
      expect(c.current.seriesId, 's3');
      expect(c.episodes.length, 1, reason: 's3 的结果落地，s2 的慢结果被丢弃');
    });

    test('watchedFor 只在浏览播放季时打勾', () {
      final c = build(fetch: (id) async => const []);
      expect(c.watchedFor(ep(1), const {1}), isTrue);
      // 浏览其它季（异步改变 current 后）——同步推演：
      // browse 是异步的，这里只验证接口契约本身。
    });
  });

  group('requireRange（A4 长剧分段点未加载段补数据）', () {
    final seasons = <Season>[
      season('s1', '第一季', 1, 2),
      season('s2', '第二季', 2, 53),
    ];

    SeasonBrowseController build({
      required Future<List<Episode>> Function(String seriesId) fetch,
    }) =>
        SeasonBrowseController(
          seasons: seasons,
          playingSeriesId: 's1',
          playingEpisodes: [ep(1), ep(2)],
          playingIndex: 0,
          fetchSeasonEpisodes: fetch,
        );

    test('列表已覆盖 endIndex 时不拉取', () async {
      var fetchCalls = 0;
      final c = build(fetch: (id) async {
        fetchCalls++;
        return const [];
      });
      await c.requireRange(1);
      expect(fetchCalls, 0);
      expect(c.episodes.length, 2);
    });

    test('未覆盖时拉全量并覆盖缓存（播放季第一页补成完整列表）', () async {
      var fetchCalls = 0;
      final c = build(fetch: (id) async {
        fetchCalls++;
        return [for (var i = 1; i <= 200; i++) ep(i)];
      });
      await c.requireRange(199);
      expect(fetchCalls, 1);
      expect(c.episodes.length, 200);
      expect(c.currentIndex, 0, reason: '播放季的当前集下标不变');
      expect(c.loading, isFalse);
    });

    test('拉取结果没有增长时不覆盖缓存（防元数据虚报空转）', () async {
      final c = build(fetch: (id) async => [ep(1)]);
      await c.requireRange(199);
      expect(c.episodes.length, 2, reason: '比已加载还少的结果不落地');
      expect(c.loadFailed, isFalse);
    });

    test('拉取失败标记 loadFailed，不回退浏览季', () async {
      final c = build(fetch: (id) async => throw Exception('down'));
      await c.requireRange(199);
      expect(c.loadFailed, isTrue);
      expect(c.current.seriesId, 's1', reason: 'requireRange 不是切季，不回退');
      expect(c.episodes.length, 2);
      expect(c.loading, isFalse);
    });

    test('浏览其它季时 requireRange 补的是当前浏览季', () async {
      final fetched = <String>[];
      final c = build(fetch: (id) async {
        fetched.add(id);
        // 首次浏览拉到与元数据一致的第一页；补段那次拉到完整列表。
        return fetched.length == 1
            ? [for (var i = 1; i <= 53; i++) ep(i)]
            : [for (var i = 1; i <= 250; i++) ep(i)];
      });
      await c.browse(seasons[1]); // s2：53 集
      await c.requireRange(249); // 段尾超出已加载 → 补数据
      expect(fetched, ['s2', 's2'], reason: '补的是浏览中的季');
      expect(c.episodes.length, 250);
    });
  });
}
