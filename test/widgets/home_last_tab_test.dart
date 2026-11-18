// A3 冷启动恢复上次 tab（ui.lastTab）：
// - 首次安装（无记录）→ 落发现页（tab 0）；
// - 切到「榜单」→ 整棵树重建（等价冷启动）→ 直接落在榜单页；
// - ui.lastTab 随备份导出 / 导入往返；越界值 clamp 到 0–3。
//
// HomeScreen 依赖 AppScope 全家桶，这里按 main.dart 的形状搭一个可用的
// 最小 AppScope：JSON store 一律 testDirectory、api 用桩客户端（沿用
// danmaku_repository_test 的 noSuchMethod 桩）、window_manager 通道 mock
// 成空实现（测试环境没有桌面窗口插件）。外壳有持续动画（液面/光斑），
// 一律用显式 pump 推进，不用 pumpAndSettle。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:aquan_duanju/core/aqua_api.dart';
import 'package:aquan_duanju/core/aqua_client.dart';
import 'package:aquan_duanju/core/books/book_source_store.dart';
import 'package:aquan_duanju/core/download_service.dart';
import 'package:aquan_duanju/core/player/player_engine.dart';
import 'package:aquan_duanju/core/reader/reader_speech_controller.dart';
import 'package:aquan_duanju/core/sources/auto_source_manager.dart';
import 'package:aquan_duanju/core/tv/tv_mode.dart';
import 'package:aquan_duanju/screens/home_screen.dart';
import 'package:aquan_duanju/store/stores.dart';
import 'package:aquan_duanju/widgets/common.dart';
import 'package:aquan_duanju/widgets/tv_scope.dart';
import 'package:aquan_duanju/widgets/ui/app_icons.dart';

class _StubClient implements AquaClient {
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

/// 听书引擎桩：测试环境没有 media_kit（ReaderSpeechController 默认会懒建
/// MpvPlayerEngine，构造即触发 MediaKit.ensureInitialized 断言）。
class _StubSpeechEngine implements PlayerEngine {
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _HarnessStores {
  factory _HarnessStores(
    Directory dir,
    SettingsStore settings,
    SharedPreferences prefs,
  ) {
    final api = AquaApi(_StubClient());
    final listening = ListenProgressStore(testDirectory: dir);
    final discovery = SourceDiscoveryStore(testDirectory: dir);
    final seeds = SeedStore(testDirectory: dir);
    final sources = SourcesStore(testDirectory: dir);
    return _HarnessStores._(
      api: api,
      settings: settings,
      history: HistoryStore(testDirectory: dir),
      reading: ReadingProgressStore(testDirectory: dir),
      listening: listening,
      bookCache: BookChapterCache(testDirectory: dir),
      follows: FollowStore(testDirectory: dir),
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
    required this.reading,
    required this.listening,
    required this.bookCache,
    required this.follows,
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
  final HistoryStore history;
  final ReadingProgressStore reading;
  final ListenProgressStore listening;
  final BookChapterCache bookCache;
  final FollowStore follows;
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

  Widget build({Key? key}) {
    return AppScope(
      key: key,
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
    // 测试环境没有桌面窗口插件：window_manager 通道 mock 成空实现；
    // waitUntilReadyToShow 会回读 isFullScreen/isMaximized/isMinimized，
    // 这几个必须给 bool，否则 `_RawReceivePort` 收到 null 直接 TypeError。
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('window_manager'), (
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
              return <String, double>{
                'x': 0,
                'y': 0,
                'width': 800,
                'height': 600,
              };
            default:
              return null;
          }
        });
  });

  Finder stackInHome() => find.descendant(
    of: find.byType(HomeScreen),
    matching: find.byType(IndexedStack),
  );

  int stackIndexOf(WidgetTester tester) =>
      tester.widget<IndexedStack>(stackInHome()).index ?? -1;

  testWidgets('首次安装默认发现页；切到榜单后重建 HomeScreen 落回榜单页', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final settings = SettingsStore(prefs);
    settings.autoCheckUpdate = false; // 30s 的启动检查不进网络
    final dir = Directory.systemTemp.createTempSync('aquan_home_tab');
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    final stores = _HarnessStores(dir, settings, prefs);

    // 冷启动：无记录 → 发现页。
    await tester.pumpWidget(stores.build());
    await tester.pump(const Duration(milliseconds: 400));
    expect(stackIndexOf(tester), 0, reason: '首次安装默认 tab 0');
    expect(settings.uiLastTab, 0);

    // 切到「榜单」（rail 第 3 项，点图标；未选中项的 label 不保证可命中）：
    // IndexedStack 立即换页并写回设置。
    await tester.tap(
      find.descendant(
        of: find.byType(NavigationRail),
        matching: find.byIcon(AppIcons.leaderboard),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));
    expect(stackIndexOf(tester), 2);
    expect(settings.uiLastTab, 2, reason: '切 tab 写回 ui.lastTab');

    // 整棵树拆掉重建 = 冷启动（新 HomeScreen State 重读设置）。
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(stores.build());
    await tester.pump(const Duration(milliseconds: 400));
    expect(stackIndexOf(tester), 2, reason: '冷启动恢复上次停留的 tab');

    // 冲掉两个启动 Timer（2s 预热 / 30s 更新检查），避免 pending timer。
    await tester.pump(const Duration(seconds: 35));
  });

  testWidgets('恢复值越界回落发现页；重建后再次切 tab 继续记忆', (tester) async {
    SharedPreferences.setMockInitialValues({'ui.lastTab': 9});
    final prefs = await SharedPreferences.getInstance();
    final settings = SettingsStore(prefs);
    settings.autoCheckUpdate = false;
    final dir = Directory.systemTemp.createTempSync('aquan_home_tab2');
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    final stores = _HarnessStores(dir, settings, prefs);

    await tester.pumpWidget(stores.build());
    await tester.pump(const Duration(milliseconds: 400));
    expect(settings.uiLastTab, 3, reason: 'getter clamp 到 0–3');
    expect(stackIndexOf(tester), 3, reason: '越界恢复值 clamp 后仍按 tab 3 打开');

    // 重建后再切「我的」→ 设置里是 3；再回发现页 → 设置里是 0。
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(stores.build());
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(
      find.descendant(
        of: find.byType(NavigationRail),
        matching: find.byIcon(AppIcons.discover),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));
    expect(settings.uiLastTab, 0);

    await tester.pump(const Duration(seconds: 35));
  });

  test('ui.lastTab 进备份导出，importBackup 可还原；非法值回落 0', () async {
    SharedPreferences.setMockInitialValues({});
    final s = SettingsStore(await SharedPreferences.getInstance());
    expect(s.uiLastTab, 0, reason: '首次安装默认发现页');

    s.uiLastTab = 2;
    final exported = s.exportBackup();
    expect(exported['ui.lastTab'], 2);

    SharedPreferences.setMockInitialValues({});
    final s2 = SettingsStore(await SharedPreferences.getInstance());
    s2.importBackup(Map<String, dynamic>.from(exported));
    expect(s2.uiLastTab, 2);

    // 非法类型：不写入（仍为 0）。
    SharedPreferences.setMockInitialValues({});
    final s3 = SettingsStore(await SharedPreferences.getInstance());
    s3.importBackup(<String, dynamic>{'ui.lastTab': 'bad'});
    expect(s3.uiLastTab, 0);
  });
}
