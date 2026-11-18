// R1 冷启动会话恢复的入口行为（11-19-ux-resume）：HomeScreen 首帧后按
// ui.lastRoute 把上次的详情/播放页盖回壳层。
// - 详情记录 → 直落详情页（autoplay false）；
// - 播放记录 → 借道详情页的「详情→播放」组装链路接力（autoplay true），
//   历史里的内容类型原样透传（继续观看分类不漂移）；
// - 24h 过期 / 设置关闭 / 深链命令 / 拉取失败 → 不恢复（后两类清键）；
// - 整棵树拆掉重建 = 状态杀进程等价，恢复可重复。
//
// HomeScreen 依赖 AppScope 全家桶，沿用 widgets/home_last_tab_test.dart 的
// 最小 AppScope 形状；history/follows 用内存桩（恢复链路会用 ensureLoaded/
// get/ackUpdate，真实文件 I/O 在 fake-async 区里永不完成，必须斩断），
// 其余 JSON store 沿用 home_last_tab 的 testDirectory 空库（只读空态、
// 永不写盘）。全程零 runAsync、零真实 I/O，动画与启动 Timer 用显式 pump。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:aquan_duanju/core/aqua_api.dart';
import 'package:aquan_duanju/core/aqua_client.dart';
import 'package:aquan_duanju/core/books/book_source_store.dart';
import 'package:aquan_duanju/core/download_service.dart';
import 'package:aquan_duanju/core/last_route.dart';
import 'package:aquan_duanju/core/player/player_engine.dart';
import 'package:aquan_duanju/core/reader/reader_speech_controller.dart';
import 'package:aquan_duanju/core/sources/auto_source_manager.dart';
import 'package:aquan_duanju/core/tv/tv_mode.dart';
import 'package:aquan_duanju/screens/detail_screen.dart';
import 'package:aquan_duanju/screens/home_screen.dart';
import 'package:aquan_duanju/screens/player_screen.dart';
import 'package:aquan_duanju/screens/session_resume.dart';
import 'package:aquan_duanju/store/stores.dart';
import 'package:aquan_duanju/widgets/common.dart';
import 'package:aquan_duanju/widgets/tv_scope.dart';

/// 桩客户端：getSeries / listEpisodes 给出可解析的最小 JSON，其余方法回
/// null（_map(null) 空表兜底，与 home_last_tab_test 的桩同语义——调用方
/// 全部按空数据优雅降级）。failGetSeries 模拟下架 / 网络失败。
class _SmartClient implements AquaClient {
  _SmartClient({
    Map<String, dynamic>? seriesJson,
    Map<String, dynamic>? episodesJson,
  }) : seriesJson =
           seriesJson ?? <String, dynamic>{'id': 's2', 'title': '测试剧名'},
       episodesJson = episodesJson ?? <String, dynamic>{'items': <Object>[]};

  final Map<String, dynamic> seriesJson;
  final Map<String, dynamic> episodesJson;
  bool failGetSeries = false;
  int getSeriesCalls = 0;

  @override
  Future<dynamic> call(String method, [List<Object?> args = const []]) async {
    switch (method) {
      case 'getSeries':
        getSeriesCalls++;
        if (failGetSeries) throw Exception('series gone');
        return seriesJson;
      case 'listEpisodes':
        return episodesJson;
      default:
        return null;
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

/// 历史内存桩：恢复链路只用到 ensureLoaded / get / entries；get 按 seed
/// 回记录（内容类型透传断言用）。
class _FakeHistory implements HistoryStore {
  _FakeHistory(this.seed);

  final HistoryEntry? seed;
  int ensureLoadedCalls = 0;

  @override
  Future<void> ensureLoaded() async {
    ensureLoadedCalls++;
  }

  @override
  HistoryEntry? get(String seriesId) =>
      seed?.seriesId == seriesId ? seed : null;

  @override
  List<HistoryEntry> get entries =>
      seed == null ? const <HistoryEntry>[] : <HistoryEntry>[seed!];

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

/// 追剧内存桩：ackUpdate 无记录时生产代码本就早退，这里直接空转；
/// isFollowing/get 给空态（详情头图的追剧按钮只读这些）。
class _FakeFollows implements FollowStore {
  int ackUpdateCalls = 0;

  @override
  Future<void> ensureLoaded() async {}

  @override
  Future<void> ackUpdate(String seriesId, int latestCount) async {
    ackUpdateCalls++;
  }

  @override
  bool isFollowing(String seriesId) => false;

  @override
  FollowEntry? get(String seriesId) => null;

  @override
  List<FollowEntry> get entries => const <FollowEntry>[];

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

/// 听书引擎桩：测试环境没有 media_kit（见 home_last_tab_test）。
class _StubSpeechEngine implements PlayerEngine {
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _HarnessStores {
  factory _HarnessStores(
    Directory dir,
    SettingsStore settings,
    SharedPreferences prefs,
    _SmartClient client, {
    HistoryEntry? historySeed,
  }) {
    final api = AquaApi(client);
    final listening = ListenProgressStore(testDirectory: dir);
    final discovery = SourceDiscoveryStore(testDirectory: dir);
    final seeds = SeedStore(testDirectory: dir);
    final sources = SourcesStore(testDirectory: dir);
    return _HarnessStores._(
      api: api,
      settings: settings,
      history: _FakeHistory(historySeed),
      follows: _FakeFollows(),
      reading: ReadingProgressStore(testDirectory: dir),
      listening: listening,
      bookCache: BookChapterCache(testDirectory: dir),
      searches: SearchHistoryStore(),
      playSkip: PlaySkipStore(),
      downloads: DownloadService(
        store: DownloadStore(),
        baseDir: dir,
        resolver: defaultResolver(api, () => 'best'),
      ),
      detailSnapshots: DetailSnapshotStore(testDirectory: dir),
      sources: sources,
      bookSources: BookSourceStore(prefs),
      sourceHealth: SourceHealthStore(testDirectory: dir),
      marketSites: MarketSitesStore(testDirectory: dir),
      seeds: seeds,
      discovery: discovery,
      autoSource: AutoSourceManager(
        seeds: seeds,
        sources: sources,
        discovery: discovery,
        marketSites: MarketSitesStore(testDirectory: dir),
        settings: settings,
      ),
      bookmarks: BookmarkStore(testDirectory: dir),
      markings: MarkingStore(testDirectory: dir),
      replaceRules: ReplaceRuleStore(testDirectory: dir),
      playbackHealth: PlaybackHealthStore(testDirectory: dir),
      cast: CastStore(testDirectory: dir),
      lives: LivesStore(testDirectory: dir),
      readerSettings: ReaderSettingsStore(testDirectory: dir),
      speech: ReaderSpeechController(
        api: api,
        store: listening,
        engine: _StubSpeechEngine(),
      ),
    );
  }

  _HarnessStores._({
    required this.api,
    required this.settings,
    required this.history,
    required this.follows,
    required this.reading,
    required this.listening,
    required this.bookCache,
    required this.searches,
    required this.playSkip,
    required this.downloads,
    required this.detailSnapshots,
    required this.sources,
    required this.bookSources,
    required this.sourceHealth,
    required this.marketSites,
    required this.seeds,
    required this.discovery,
    required this.autoSource,
    required this.bookmarks,
    required this.markings,
    required this.replaceRules,
    required this.playbackHealth,
    required this.cast,
    required this.lives,
    required this.readerSettings,
    required this.speech,
  });

  final AquaApi api;
  final SettingsStore settings;
  final _FakeHistory history;
  final _FakeFollows follows;
  final ReadingProgressStore reading;
  final ListenProgressStore listening;
  final BookChapterCache bookCache;
  final SearchHistoryStore searches;
  final PlaySkipStore playSkip;
  final DownloadService downloads;
  final DetailSnapshotStore detailSnapshots;
  final SourcesStore sources;
  final BookSourceStore bookSources;
  final SourceHealthStore sourceHealth;
  final MarketSitesStore marketSites;
  final SeedStore seeds;
  final SourceDiscoveryStore discovery;
  final AutoSourceManager autoSource;
  final BookmarkStore bookmarks;
  final MarkingStore markings;
  final ReplaceRuleStore replaceRules;
  final PlaybackHealthStore playbackHealth;
  final CastStore cast;
  final LivesStore lives;
  final ReaderSettingsStore readerSettings;
  final ReaderSpeechController speech;

  Widget build() {
    return AppScope(
      notifier: settings,
      api: api,
      settings: settings,
      history: history,
      reading: reading,
      listening: listening,
      bookCache: bookCache,
      follows: follows,
      searches: searches,
      playSkip: playSkip,
      downloads: downloads,
      detailSnapshots: detailSnapshots,
      sources: sources,
      bookSources: bookSources,
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
        child: MaterialApp(home: HomeScreen()),
      ),
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    // 测试环境没有桌面窗口插件 / 屏幕常亮插件：通道 mock 成空实现。
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(const MethodChannel('window_manager'), (
      call,
    ) async {
      switch (call.method) {
        case 'isFullScreen':
        case 'isMaximized':
        case 'isMinimized':
        case 'isVisible':
        case 'isAlwaysOnTop':
        case 'isFocused':
          return false;
        case 'getBounds':
          return <String, double>{'x': 0, 'y': 0, 'width': 800, 'height': 600};
        default:
          return null;
      }
    });
    // wakelock_plus 在测试环境回落到 pigeon MethodChannel 实现（真实插件
    // 注册只在真机发生）：屏幕常亮的开/关按 pigeon 的 BasicMessageChannel
    // 协议回一个空信封，避免 dispose 时的 unhandled channel error。
    messenger.setMockMessageHandler(
      'dev.flutter.pigeon.wakelock_plus_platform_interface.WakelockPlusApi.toggle',
      (message) async =>
          const StandardMessageCodec().encodeMessage(<Object?>[null]),
    );
  });

  setUp(() {
    SessionResume.suppressedByLaunchCommand = false;
  });

  /// 搭建宿主：mock prefs（含被测种子值）→ 临时目录 store + 内存桩。
  Future<(_HarnessStores, _SmartClient)> buildHarness(
    WidgetTester tester, {
    Map<String, Object> prefs = const {},
    HistoryEntry? historySeed,
    _SmartClient? client,
  }) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'ui.onboardingSeen': true, // 首启引导会挡住壳层，与恢复语义无关
      ...prefs,
    });
    final appPrefs = await SharedPreferences.getInstance();
    final settings = SettingsStore(appPrefs);
    settings.autoCheckUpdate = false; // 30s 的启动检查不进网络
    final dir = Directory.systemTemp.createTempSync('aquan_session_resume');
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    final smartClient = client ?? _SmartClient();
    final stores = _HarnessStores(
      dir,
      settings,
      appPrefs,
      smartClient,
      historySeed: historySeed,
    );
    return (stores, smartClient);
  }

  /// 推进到恢复落点：首帧 postFrame 触发恢复 → api 拉取 → push 目标页。
  Future<void> pumpToRestore(WidgetTester tester, _HarnessStores stores) async {
    await tester.pumpWidget(stores.build());
    await tester.pump();
    await tester.pump();
  }

  /// 冲掉两个启动 Timer（2s 预热 / 30s 更新检查），避免 pending timer。
  Future<void> flushStartupTimers(WidgetTester tester) =>
      tester.pump(const Duration(seconds: 35));

  testWidgets('详情页恢复：直落详情页；重建宿主（等价杀进程）恢复可重复', (tester) async {
    final record = LastRoute.detail(seriesId: 's2');
    final (stores, client) = await buildHarness(
      tester,
      prefs: {'ui.lastRoute': record.encode()},
    );

    await pumpToRestore(tester, stores);
    expect(find.byType(DetailScreen), findsOneWidget, reason: '直落详情页');
    final detail = tester.widget<DetailScreen>(find.byType(DetailScreen));
    expect(detail.autoplay, isFalse, reason: '详情记录不做播放接力');
    expect(detail.seriesId, 's2');
    // 恢复入口先拉一次详情做「下架/失败静默」预检，详情页自己再拉一次。
    expect(client.getSeriesCalls, 2);
    expect(stores.history.ensureLoadedCalls, greaterThanOrEqualTo(1));
    expect(stores.settings.uiLastRoute, record.encode(), reason: '恢复不清记录');

    // 整棵树拆掉重建 = 冷启动（状态杀进程等价）：恢复可重复。
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(stores.build());
    await tester.pump();
    await tester.pump();
    expect(find.byType(DetailScreen), findsOneWidget);

    await flushStartupTimers(tester);
  });

  testWidgets('播放页恢复：借道详情页接力（autoplay true）+ 内容类型透传', (tester) async {
    final record = LastRoute.player(seriesId: 's2', episode: 3);
    final (stores, client) = await buildHarness(
      tester,
      prefs: {'ui.lastRoute': record.encode()},
      historySeed: HistoryEntry(
        seriesId: 's2',
        title: '测试剧名',
        episode: 3,
        episodes: 20,
        position: 300,
        contentType: 'manga',
      ),
    );

    await pumpToRestore(tester, stores);
    expect(find.byType(DetailScreen), findsOneWidget);
    final detail = tester.widget<DetailScreen>(find.byType(DetailScreen));
    expect(detail.autoplay, isTrue, reason: '播放记录走既有「详情→播放」组装链路自动接力');
    expect(detail.contentType, 'manga', reason: '历史内容类型原样透传');
    expect(detail.seriesId, 's2');
    expect(client.getSeriesCalls, 2);
    // 桩数据没有可播分集，接力到播放页由既有 autoplay 链路在真机上完成；
    // 这里断言不越级构造播放页（组装责任仍归详情页）。
    expect(find.byType(PlayerScreen, skipOffstage: false), findsNothing);

    await flushStartupTimers(tester);
  });

  testWidgets('24h 过期：不恢复且清键', (tester) async {
    final stale = LastRoute.detail(
      seriesId: 's2',
      at: DateTime.now().subtract(kLastRouteTtl),
    );
    final (stores, client) = await buildHarness(
      tester,
      prefs: {'ui.lastRoute': stale.encode()},
    );

    await pumpToRestore(tester, stores);
    expect(find.byType(DetailScreen), findsNothing);
    expect(client.getSeriesCalls, 0, reason: '过期先判，不发请求');
    expect(stores.settings.uiLastRoute, '', reason: '隔天失效清掉旧记录');
    await flushStartupTimers(tester);
  });

  testWidgets('设置关闭：不恢复且记录保留', (tester) async {
    final record = LastRoute.detail(seriesId: 's2');
    final (stores, client) = await buildHarness(
      tester,
      prefs: {'ui.resumeSession': false, 'ui.lastRoute': record.encode()},
    );

    await pumpToRestore(tester, stores);
    expect(find.byType(DetailScreen), findsNothing);
    expect(client.getSeriesCalls, 0);
    expect(stores.settings.uiLastRoute, record.encode(), reason: '关闭只停恢复，记录留着');
    await flushStartupTimers(tester);
  });

  testWidgets('深链命令启动：跳过会话恢复（深链优先）', (tester) async {
    final record = LastRoute.detail(seriesId: 's2');
    final (stores, client) = await buildHarness(
      tester,
      prefs: {'ui.lastRoute': record.encode()},
    );
    SessionResume.suppressedByLaunchCommand = true;

    await pumpToRestore(tester, stores);
    expect(
      find.byType(DetailScreen),
      findsNothing,
      reason: '命令行/AI 的导航命令优先，恢复不叠加',
    );
    expect(client.getSeriesCalls, 0);
    expect(stores.settings.uiLastRoute, record.encode());
    await flushStartupTimers(tester);
  });

  testWidgets('拉取失败（下架/网络）：静默清键不弹错', (tester) async {
    final record = LastRoute.detail(seriesId: 's2');
    final (stores, client) = await buildHarness(
      tester,
      prefs: {'ui.lastRoute': record.encode()},
      client: _SmartClient()..failGetSeries = true,
    );

    await pumpToRestore(tester, stores);
    expect(find.byType(DetailScreen), findsNothing, reason: '下架/网络失败静默不恢复');
    expect(client.getSeriesCalls, 1, reason: '确实发起了拉取');
    expect(stores.settings.uiLastRoute, '', reason: '失败清键');
    await flushStartupTimers(tester);
  });
}
