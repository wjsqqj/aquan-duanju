// 榜单会话缓存（1.12.16）：
// - 首拉成功写缓存；重挂（等价重进）先渲染缓存、后台静默刷新覆盖；
// - 下拉刷新强制走网络并替换列表；
// - 失败不写缓存（重挂后仍走网络加载）。
//
// RankingsScreen 依赖 AppScope 全家桶，按 test/widgets/home_last_tab_test.dart
// 的形状搭最小宿主：JSON store 一律 testDirectory、api 用 shortRank 桩客户端。
// 外壳可能有常驻动画，一律显式 pump 推进，不用 pumpAndSettle。
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
/// 其余方法视为意外调用。
class _RankStubClient implements AquaClient {
  _RankStubClient(this.pages);

  final List<Object?> pages;
  int shortRankCalls = 0;
  List<Object?> lastShortRankArgs = const [];

  @override
  Future<dynamic> call(String method, [List<Object?> args = const []]) async {
    if (method != 'shortRank') throw StateError('unexpected: $method');
    lastShortRankArgs = args;
    final index = shortRankCalls;
    shortRankCalls++;
    if (index >= pages.length) throw StateError('no stub page for call $index');
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
}
