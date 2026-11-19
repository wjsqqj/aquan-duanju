// 榜单会话缓存（1.12.16）+ 回显静默刷新（1.12.18 R1）：
// - 首拉成功写缓存；重挂（等价重进）先渲染缓存、后台静默刷新覆盖；
// - 下拉刷新强制走网络并替换列表；
// - 失败不写缓存（重挂后仍走网络加载）；
// - 壳层切回榜单 tab 且距上次加载 >5min → 静默刷新当前 tab+榜第一页，
//   <5min 不请求；失败保留旧数据；与切榜并发 _seq 防串台。
//
// RankingsScreen 依赖 AppScope 全家桶，按 test/widgets/home_last_tab_test.dart
// 的形状搭最小宿主：JSON store 一律 testDirectory、api 用 shortRank 桩客户端。
// 外壳可能有常驻动画，一律显式 pump 推进，不用 pumpAndSettle。
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:aquan_duanju/core/aqua_api.dart';
import 'package:aquan_duanju/core/aqua_client.dart';
import 'package:aquan_duanju/core/books/book_source_store.dart';
import 'package:aquan_duanju/core/download_service.dart';
import 'package:aquan_duanju/core/player/player_engine.dart';
import 'package:aquan_duanju/core/rankings_session_cache.dart';
import 'package:aquan_duanju/core/reader/reader_speech_controller.dart';
import 'package:aquan_duanju/core/sources/auto_source_manager.dart';
import 'package:aquan_duanju/core/tv/tv_mode.dart';
import 'package:aquan_duanju/models/models.dart';
import 'package:aquan_duanju/screens/rankings_screen.dart';
import 'package:aquan_duanju/store/stores.dart';
import 'package:aquan_duanju/widgets/common.dart';
import 'package:aquan_duanju/widgets/loading.dart';
import 'package:aquan_duanju/widgets/tv_scope.dart';

/// shortRank 桩客户端：按调用次数返回 [pages] 中的预置页；
/// 非 Map 元素按失败抛出（Exception/Error/None 皆可，模拟网络失败），
/// 其余方法视为意外调用。[gates] 按**调用序号**挂起对应请求（测试放行
/// 后才返回），用来制造在途窗口测并发串台。
class _RankStubClient implements AquaClient {
  _RankStubClient(this.pages, {this.gates = const <int, Completer<void>>{}});

  final List<Object?> pages;
  final Map<int, Completer<void>> gates;
  int shortRankCalls = 0;
  List<Object?> lastShortRankArgs = const [];

  @override
  Future<dynamic> call(String method, [List<Object?> args = const []]) async {
    if (method != 'shortRank') throw StateError('unexpected: $method');
    lastShortRankArgs = args;
    final index = shortRankCalls;
    shortRankCalls++;
    if (index >= pages.length) throw StateError('no stub page for call $index');
    final gate = gates[index];
    if (gate != null) await gate.future;
    final page = pages[index];
    // 注意 StateError 属于 Error 而非 Exception，不能只判 Exception。
    if (page is Map<String, dynamic>) return page;
    if (page == null) throw StateError('network down');
    throw page;
  }
}

class _StubSpeechEngine implements PlayerEngine {
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

/// 最小 AppScope 宿主（沿 home_last_tab_test 的形状）。
class _Harness {
  _Harness(Directory dir, this.settings, this.prefs, this.client)
    : api = AquaApi(client),
      listening = ListenProgressStore(testDirectory: dir),
      seeds = SeedStore(testDirectory: dir),
      sources = SourcesStore(testDirectory: dir),
      discovery = SourceDiscoveryStore(testDirectory: dir) {
    history = HistoryStore(testDirectory: dir);
    reading = ReadingProgressStore(testDirectory: dir);
    bookCache = BookChapterCache(testDirectory: dir);
    follows = FollowStore(testDirectory: dir);
    detailSnapshots = DetailSnapshotStore(testDirectory: dir);
    sourceHealth = SourceHealthStore(testDirectory: dir);
    marketSites = MarketSitesStore(testDirectory: dir);
    bookmarks = BookmarkStore(testDirectory: dir);
    markings = MarkingStore(testDirectory: dir);
    replaceRules = ReplaceRuleStore(testDirectory: dir);
    playbackHealth = PlaybackHealthStore(testDirectory: dir);
    cast = CastStore(testDirectory: dir);
    lives = LivesStore(testDirectory: dir);
    readerSettings = ReaderSettingsStore(testDirectory: dir);
    autoSource = AutoSourceManager(
      seeds: seeds,
      sources: sources,
      discovery: discovery,
      marketSites: marketSites,
      settings: settings,
    );
    speech = ReaderSpeechController(
      api: api,
      store: listening,
      engine: _StubSpeechEngine(),
    );
  }

  final SharedPreferences prefs;

  final AquaApi api;
  final _RankStubClient client;
  final SettingsStore settings;
  final ListenProgressStore listening;
  final SeedStore seeds;
  final SourcesStore sources;
  final SourceDiscoveryStore discovery;
  late final HistoryStore history;
  late final ReadingProgressStore reading;
  late final BookChapterCache bookCache;
  late final FollowStore follows;
  late final DetailSnapshotStore detailSnapshots;
  late final SourceHealthStore sourceHealth;
  late final MarketSitesStore marketSites;
  late final BookmarkStore bookmarks;
  late final MarkingStore markings;
  late final ReplaceRuleStore replaceRules;
  late final PlaybackHealthStore playbackHealth;
  late final CastStore cast;
  late final LivesStore lives;
  late final ReaderSettingsStore readerSettings;
  late final AutoSourceManager autoSource;
  late final ReaderSpeechController speech;

  Widget build(Widget child) {
    return AppScope(
      notifier: settings,
      api: api,
      settings: settings,
      history: history,
      reading: reading,
      listening: listening,
      bookCache: bookCache,
      follows: follows,
      searches: SearchHistoryStore(),
      playSkip: PlaySkipStore(),
      downloads: DownloadService(
        store: DownloadStore(),
        baseDir: Directory.systemTemp,
        resolver: defaultResolver(api, () => 'best'),
      ),
      detailSnapshots: detailSnapshots,
      sources: sources,
      bookSources: BookSourceStore(prefs),
      sourceHealth: sourceHealth,
      marketSites: marketSites,
      seeds: seeds,
      discovery: discovery,
      autoSource: autoSource,
      bookmarks: bookmarks,
      markings: markings,
      replaceRules: replaceRules,
      playbackHealth: playbackHealth,
      cast: cast,
      lives: lives,
      readerSettings: readerSettings,
      speech: speech,
      child: TvScope(
        formFactor: AppFormFactor.phone,
        child: MaterialApp(home: Scaffold(body: child)),
      ),
    );
  }
}

/// 占位已移除：prefs 直接作为 _Harness 字段传入。

Map<String, dynamic> _rankPage({
  required List<Map<String, dynamic>> items,
  String cursor = '',
  bool hasMore = false,
}) => <String, dynamic>{
  'contents': <Map<String, dynamic>>[
    {
      'id': 'c1',
      'name': '全部',
      'selected': true,
      'boards': <Map<String, dynamic>>[
        {'id': 'b1', 'name': '热播榜', 'selected': true},
        {'id': 'b2', 'name': '新剧榜', 'selected': false},
      ],
    },
  ],
  'items': items,
  'has_more': hasMore,
  'cursor': cursor,
};

Map<String, dynamic> _rankItem(String title, int position) =>
    <String, dynamic>{
      'rank': position,
      'title': title,
      'series_id': '700000000000000000$position',
      'position': position,
    };

Future<_Harness> _makeHarness(_RankStubClient client) async {
  // 不 mock 的话测试宿主上平台通道无人应答，getInstance 永远不返回。
  SharedPreferences.setMockInitialValues(<String, Object>{});
  final prefs = await SharedPreferences.getInstance();
  final settings = SettingsStore(prefs)..autoCheckUpdate = false;
  final dir = Directory.systemTemp.createTempSync('aquan_rankings_cache');
  return _Harness(dir, settings, prefs, client);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    // 静态会话缓存跨用例隔离。
    RankingsSessionCache.instance.clear();
  });

  group('RankingsSessionCache（纯内存语义）', () {
    test('rememberFirst 记 tab 结构与默认榜页，pageOf 按 tab+榜维度取', () {
      final cache = RankingsSessionCache.instance;
      final contents = [
        const RankContent(
          id: 'c1',
          name: '全部',
          selected: true,
          boards: [RankBoard(id: 'b1', name: '热播榜', selected: true)],
        ),
      ];
      cache.rememberFirst(
        contents: contents,
        contentId: 'c1',
        boardId: 'b1',
        items: [const RankItem(title: '剧甲', position: 1)],
        cursor: 'cur-1',
        hasMore: true,
      );

      expect(cache.contents, same(contents));
      final page = cache.pageOf('c1', 'b1')!;
      expect(page.items.single.title, '剧甲');
      expect(page.cursor, 'cur-1');
      expect(page.hasMore, isTrue);
      expect(cache.pageOf('c1', 'b2'), isNull, reason: '别的榜没有缓存');
    });

    test('空 id 不写不取；失败语义 = 不调用 remember 即无缓存', () {
      final cache = RankingsSessionCache.instance;
      cache.rememberPage(
        contentId: '',
        boardId: 'b1',
        items: const [RankItem()],
        cursor: '',
        hasMore: false,
      );
      expect(cache.contents, isNull);
      expect(cache.pageOf('', 'b1'), isNull);
    });

    test('单页上限 maxItemsPerPage；clear 清空全部', () {
      final cache = RankingsSessionCache.instance;
      cache.rememberPage(
        contentId: 'c1',
        boardId: 'b1',
        items: [
          for (var i = 0; i < RankingsSessionCache.maxItemsPerPage + 10; i++)
            RankItem(title: '剧$i'),
        ],
        cursor: '',
        hasMore: false,
      );
      expect(
        cache.pageOf('c1', 'b1')!.items.length,
        RankingsSessionCache.maxItemsPerPage,
      );

      cache.clear();
      expect(cache.contents, isNull);
      expect(cache.pageOf('c1', 'b1'), isNull);
    });
  });

  group('RankingsScreen 会话缓存', () {
    testWidgets('首拉成功写缓存；重挂先渲染缓存、后台静默刷新覆盖',
        (tester) async {
      final client = _RankStubClient([
        _rankPage(items: [_rankItem('剧甲', 1)]),
        _rankPage(items: [_rankItem('剧乙', 1)]),
      ]);
      final harness = await _makeHarness(client);

      // 首拉：加载态 → 页 A 落地。
      await tester.pumpWidget(harness.build(const RankingsScreen()));
      await tester.pump(const Duration(milliseconds: 20));
      await tester.pump(const Duration(milliseconds: 20));
      expect(find.text('剧甲'), findsOneWidget);
      expect(client.shortRankCalls, 1);

      // 拆树重挂 = 重进：第一帧就渲染缓存页 A（无骨架、无等待感）。
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpWidget(harness.build(const RankingsScreen()));
      expect(find.text('剧甲'), findsOneWidget, reason: '缓存先渲染');
      expect(find.text('剧乙'), findsNothing, reason: '后台刷新还没落地');
      expect(find.byType(AppLoading), findsNothing, reason: '命中缓存不闪骨架');

      // 后台刷新（网络）落地：替换为新页且不闪骨架。
      await tester.pump(const Duration(milliseconds: 20));
      await tester.pump(const Duration(milliseconds: 20));
      expect(find.text('剧乙'), findsOneWidget, reason: '刷新完成替换');
      expect(find.text('剧甲'), findsNothing);
      expect(client.shortRankCalls, 2, reason: '后台刷新走网络');
    });

    testWidgets('下拉刷新强制走网络并替换列表', (tester) async {
      final client = _RankStubClient([
        _rankPage(items: [_rankItem('剧甲', 1)]),
        _rankPage(items: [_rankItem('剧乙', 1)]),
      ]);
      final harness = await _makeHarness(client);
      await tester.pumpWidget(harness.build(const RankingsScreen()));
      await tester.pump(const Duration(milliseconds: 20));
      await tester.pump(const Duration(milliseconds: 20));
      expect(find.text('剧甲'), findsOneWidget);

      // 下拉刷新（当前 tab+榜，绕过缓存强制请求第一页）。页面里还有两个
      // 横向 tab 条 ListView，用纵向谓词定位主列表。
      final listFinder = find.byWidgetPredicate(
        (w) => w is ListView && w.scrollDirection == Axis.vertical,
      );
      await tester.drag(listFinder, const Offset(0, 200));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 300));

      expect(client.shortRankCalls, 2, reason: '下拉刷新强制请求');
      expect(
        client.lastShortRankArgs,
        [
          {'content': 'c1', 'board': 'b1', 'cursor': ''},
        ],
        reason: '刷新当前 tab+榜，不带游标',
      );
      expect(find.text('剧乙'), findsOneWidget);
      expect(find.text('剧甲'), findsNothing);
    });

    testWidgets('首拉失败不写缓存：重挂仍走网络加载', (tester) async {
      final client = _RankStubClient([
        StateError('network down'),
        _rankPage(items: [_rankItem('剧甲', 1)]),
      ]);
      final harness = await _makeHarness(client);

      // 第一次：失败进错误页，缓存为空。
      await tester.pumpWidget(harness.build(const RankingsScreen()));
      await tester.pump(const Duration(milliseconds: 20));
      await tester.pump(const Duration(milliseconds: 20));
      expect(find.text('重试'), findsOneWidget, reason: '失败进错误页');
      expect(client.shortRankCalls, 1);

      // 重挂：无缓存 → 仍是加载态（不是秒开），网络重试成功后渲染。
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpWidget(harness.build(const RankingsScreen()));
      expect(find.byType(AppLoading), findsOneWidget, reason: '失败未写缓存');
      expect(find.text('剧甲'), findsNothing);

      await tester.pump(const Duration(milliseconds: 20));
      await tester.pump(const Duration(milliseconds: 20));
      expect(find.text('剧甲'), findsOneWidget);
      expect(client.shortRankCalls, 2, reason: '无缓存可复用，只能走网络');
    });
  });

  group('RankingsScreen 回显静默刷新（R1：切回榜单 tab，5min 节流）', () {
    // 可见性通道 + 假时钟：节流窗口按注入的 now 计（DateTime.now 在测试
    // 环境不随 pump 推进，所以页面留了 now 注入口）。
    ValueNotifier<int> tabOf() => ValueNotifier<int>(2);

    testWidgets('>5min 切回榜单：静默刷新当前 tab+榜，无骨架替换',
        (tester) async {
      final tab = tabOf();
      final clock = _FakeClock();
      final client = _RankStubClient([
        _rankPage(items: [_rankItem('剧甲', 1)]),
        _rankPage(items: [_rankItem('剧乙', 1)]),
      ]);
      final harness = await _makeHarness(client);

      // 首拉落地（首拉已把节流基准打在加载发起时刻）。
      await tester.pumpWidget(
        harness.build(
          RankingsScreen(visibleTab: tab, tabIndex: 2, now: clock.call),
        ),
      );
      await tester.pump(const Duration(milliseconds: 20));
      await tester.pump(const Duration(milliseconds: 20));
      expect(find.text('剧甲'), findsOneWidget);
      expect(client.shortRankCalls, 1);

      // 切走 → 推进 6 分钟（>5min 节流期）→ 切回：静默刷新立即发起，
      // 列表不清空、无骨架（刷新落地前旧数据在屏）。
      tab.value = 0;
      await tester.pump();
      clock.advance(RankingsScreen.revisibleRefreshThrottle +
          const Duration(minutes: 1));
      tab.value = 2;
      expect(client.shortRankCalls, 2, reason: '超节流期 → 静默刷新发起');
      expect(client.lastShortRankArgs, [
        {'content': 'c1', 'board': 'b1', 'cursor': ''},
      ], reason: '刷新当前 tab+榜第一页，不带游标');
      expect(find.byType(AppLoading), findsNothing, reason: '不闪骨架');
      expect(find.text('剧甲'), findsOneWidget, reason: '新数据落地前旧内容在屏');

      // 刷新落地：新数据无闪烁替换。
      await tester.pump(const Duration(milliseconds: 20));
      await tester.pump(const Duration(milliseconds: 20));
      expect(find.text('剧乙'), findsOneWidget, reason: '静默刷新替换为新页');
      expect(find.text('剧甲'), findsNothing);
      expect(client.shortRankCalls, 2);
    });

    testWidgets('<5min 切回榜单：不发起请求', (tester) async {
      final tab = tabOf();
      final clock = _FakeClock();
      final client = _RankStubClient([
        _rankPage(items: [_rankItem('剧甲', 1)]),
      ]);
      final harness = await _makeHarness(client);
      await tester.pumpWidget(
        harness.build(
          RankingsScreen(visibleTab: tab, tabIndex: 2, now: clock.call),
        ),
      );
      await tester.pump(const Duration(milliseconds: 20));
      await tester.pump(const Duration(milliseconds: 20));
      expect(find.text('剧甲'), findsOneWidget);
      expect(client.shortRankCalls, 1);

      // 切走 → 只推进 4 分钟（<5min）→ 切回：不请求，列表原样。
      tab.value = 0;
      await tester.pump();
      clock.advance(RankingsScreen.revisibleRefreshThrottle -
          const Duration(minutes: 1));
      tab.value = 2;
      await tester.pump(const Duration(milliseconds: 20));
      await tester.pump(const Duration(milliseconds: 20));
      expect(client.shortRankCalls, 1, reason: '节流期内重见不发请求');
      expect(find.text('剧甲'), findsOneWidget);
    });

    testWidgets('>5min 切回后刷新失败：旧数据保留、无报错 UI', (tester) async {
      final tab = tabOf();
      final clock = _FakeClock();
      final client = _RankStubClient([
        _rankPage(items: [_rankItem('剧甲', 1)]),
        null, // 第二次调用（静默刷新）模拟网络失败
      ]);
      final harness = await _makeHarness(client);
      await tester.pumpWidget(
        harness.build(
          RankingsScreen(visibleTab: tab, tabIndex: 2, now: clock.call),
        ),
      );
      await tester.pump(const Duration(milliseconds: 20));
      await tester.pump(const Duration(milliseconds: 20));
      expect(find.text('剧甲'), findsOneWidget);

      tab.value = 0;
      await tester.pump();
      clock.advance(RankingsScreen.revisibleRefreshThrottle +
          const Duration(minutes: 1));
      tab.value = 2;
      expect(client.shortRankCalls, 2);
      await tester.pump(const Duration(milliseconds: 20));
      await tester.pump(const Duration(milliseconds: 20));

      expect(find.text('剧甲'), findsOneWidget, reason: '失败保留旧数据');
      expect(find.text('重试'), findsNothing, reason: '静默失败不进错误页');
      expect(find.byType(AppLoading), findsNothing);
    });

    testWidgets('静默刷新与切榜并发：_seq 防串台，慢的静默结果不落地',
        (tester) async {
      final tab = tabOf();
      final clock = _FakeClock();
      final gate = Completer<void>();
      final client = _RankStubClient([
        _rankPage(items: [_rankItem('剧甲', 1)]), // call0：首拉
        _rankPage(items: [_rankItem('剧乙', 1)]), // call1：静默刷新（门控）
        _rankPage(items: [_rankItem('剧丙', 1)]), // call2：切到新剧榜
      ], gates: {1: gate});
      final harness = await _makeHarness(client);
      await tester.pumpWidget(
        harness.build(
          RankingsScreen(visibleTab: tab, tabIndex: 2, now: clock.call),
        ),
      );
      await tester.pump(const Duration(milliseconds: 20));
      await tester.pump(const Duration(milliseconds: 20));
      expect(find.text('剧甲'), findsOneWidget);

      // 超节流期切回：静默刷新发起并挂在门上（在途）。
      tab.value = 0;
      await tester.pump();
      clock.advance(RankingsScreen.revisibleRefreshThrottle +
          const Duration(minutes: 1));
      tab.value = 2;
      expect(client.shortRankCalls, 2, reason: '静默刷新在途');

      // 在途期间用户切到「新剧榜」（b2）：立即发出请求并落地。
      await tester.tap(find.text('新剧榜'));
      await tester.pump(const Duration(milliseconds: 20));
      await tester.pump(const Duration(milliseconds: 20));
      expect(client.shortRankCalls, 3);
      expect(find.text('剧丙'), findsOneWidget, reason: '切榜结果落地');

      // 静默刷新这时才回来：_seq 已被切榜抢占，旧响应不得覆盖新榜。
      gate.complete();
      await tester.pump(const Duration(milliseconds: 20));
      await tester.pump(const Duration(milliseconds: 20));
      expect(find.text('剧乙'), findsNothing, reason: '过期的静默结果被丢弃');
      expect(find.text('剧丙'), findsOneWidget);
    });
  });
}

/// 假时钟：R1 节流窗口用它计（DateTime.now 在测试环境不随 pump 推进）。
class _FakeClock {
  _FakeClock() : now = DateTime(2026, 1, 1, 12);

  DateTime now;

  DateTime call() => now;

  void advance(Duration duration) => now = now.add(duration);
}
