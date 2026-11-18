// A5 首启新手引导：
// - 组件：四页 PageView、上一步 / 下一步 / 开始使用、跳过等效完成；
// - 内容按 TvScope 桌面 / 移动分流；
// - HomeScreen 首帧触发：seen=false 且非 TV 弹一次；完成 / 跳过写标记，
//   重建不再弹；TV 形态不弹、设置页入口隐藏；「重看新手引导」可再次弹出。
//
// HomeScreen 依赖 AppScope 全家桶，这里按 home_last_tab_test 的形状搭一个
// 可用的最小 AppScope（JSON store 一律 testDirectory、api 用 noSuchMethod
// 桩、window_manager 通道 mock 成空实现）。外壳有持续动画（液面/光斑），
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
import 'package:aquan_duanju/screens/mine_screen.dart';
import 'package:aquan_duanju/store/stores.dart';
import 'package:aquan_duanju/widgets/common.dart';
import 'package:aquan_duanju/widgets/onboarding_dialog.dart';
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

  Widget build({AppFormFactor formFactor = AppFormFactor.phone}) {
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
        formFactor: formFactor,
        child: MaterialApp(home: HomeScreen()),
      ),
    );
  }
}

Widget _guideHost(AppFormFactor formFactor, Widget child) => TvScope(
  formFactor: formFactor,
  child: MaterialApp(home: Scaffold(body: child)),
);

void main() {
  group('新手引导弹层', () {
    testWidgets('桌面端四步：下一步 / 最后一步「开始使用」关闭', (tester) async {
      await tester.pumpWidget(
        _guideHost(
          AppFormFactor.desktop,
          Builder(
            builder: (context) => Center(
              child: FilledButton(
                onPressed: () => showOnboardingGuide(context),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.text('Ctrl+F / Ctrl+K 随时搜剧'), findsOneWidget);
      expect(find.text('下一步'), findsOneWidget);
      expect(find.text('跳过'), findsOneWidget);
      expect(find.text('开始使用'), findsNothing);

      await tester.tap(find.text('下一步'));
      await tester.pumpAndSettle();
      expect(find.text('右键卡片收藏追剧'), findsOneWidget);
      expect(find.text('上一步'), findsOneWidget);

      await tester.tap(find.text('下一步'));
      await tester.pumpAndSettle();
      expect(find.text('双击进出全屏影院'), findsOneWidget);

      await tester.tap(find.text('下一步'));
      await tester.pumpAndSettle();
      expect(find.text('长按 2 倍速，D 键开关弹幕'), findsOneWidget);
      expect(find.text('开始使用'), findsOneWidget);

      await tester.tap(find.text('开始使用'));
      await tester.pumpAndSettle();
      expect(find.byType(OnboardingDialog), findsNothing);
    });

    testWidgets('移动端四步：内容为触屏手势，最后一页「开始使用」', (tester) async {
      await tester.pumpWidget(
        _guideHost(
          AppFormFactor.phone,
          Builder(
            builder: (context) => Center(
              child: FilledButton(
                onPressed: () => showOnboardingGuide(context),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.text('搜索有联想和热搜'), findsOneWidget);
      // 桌面内容不串台。
      expect(find.text('Ctrl+F / Ctrl+K 随时搜剧'), findsNothing);

      await tester.tap(find.text('下一步'));
      await tester.pumpAndSettle();
      expect(find.text('长按海报收藏追剧'), findsOneWidget);

      await tester.tap(find.text('下一步'));
      await tester.pumpAndSettle();
      expect(find.text('上下滑切集，双击暂停'), findsOneWidget);

      await tester.tap(find.text('下一步'));
      await tester.pumpAndSettle();
      expect(find.text('长按 2 倍速，弹幕随手开关'), findsOneWidget);
      expect(find.text('开始使用'), findsOneWidget);

      await tester.tap(find.text('开始使用'));
      await tester.pumpAndSettle();
      expect(find.byType(OnboardingDialog), findsNothing);
    });

    testWidgets('跳过立即关闭，不要求翻完；上一步可回退', (tester) async {
      await tester.pumpWidget(
        _guideHost(
          AppFormFactor.phone,
          Builder(
            builder: (context) => Center(
              child: FilledButton(
                onPressed: () => showOnboardingGuide(context),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('下一步'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('上一步'));
      await tester.pumpAndSettle();
      expect(find.text('搜索有联想和热搜'), findsOneWidget);

      await tester.tap(find.text('跳过'));
      await tester.pumpAndSettle();
      expect(find.byType(OnboardingDialog), findsNothing);
    });
  });

  group('ui.onboardingSeen 设置项', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('默认未看过，写入后读回 true', () async {
      final settings = SettingsStore(await SharedPreferences.getInstance());
      expect(settings.onboardingSeen, isFalse);
      settings.onboardingSeen = true;
      expect(settings.onboardingSeen, isTrue);
    });

    test('进备份导出，importBackup 可还原；非法值忽略', () async {
      final s = SettingsStore(await SharedPreferences.getInstance());
      expect(s.onboardingSeen, isFalse, reason: '首次安装默认弹引导');
      s.onboardingSeen = true;

      final exported = s.exportBackup();
      expect(exported['ui.onboardingSeen'], isTrue);

      SharedPreferences.setMockInitialValues({});
      final s2 = SettingsStore(await SharedPreferences.getInstance());
      s2.importBackup(Map<String, dynamic>.from(exported));
      expect(s2.onboardingSeen, isTrue);

      // 非法类型：不写入（仍为 false）。
      SharedPreferences.setMockInitialValues({});
      final s3 = SettingsStore(await SharedPreferences.getInstance());
      s3.importBackup(<String, dynamic>{'ui.onboardingSeen': 'bad'});
      expect(s3.onboardingSeen, isFalse);
    });
  });

  group('HomeScreen 首帧触发', () {
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

    Future<Directory> makeTempDir(String name) async {
      final dir = Directory.systemTemp.createTempSync(name);
      return dir;
    }

    /// 冲掉两个启动 Timer（2s 预热 / 30s 更新检查），避免 pending timer。
    Future<void> flushTimers(WidgetTester tester) =>
        tester.pump(const Duration(seconds: 35));

    /// 推进一次翻页：外壳有持续动画不能用 pumpAndSettle，改为
    /// 「半程 → 完成 → onPageChanged setState 的重建帧」显式推进。
    Future<void> settlePageTurn(WidgetTester tester) async {
      await tester.pump(const Duration(milliseconds: 150));
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pump(const Duration(milliseconds: 50));
    }

    /// 关闭弹层：route 退场 180ms 需要两帧才真正把弹层摘下来
    /// （第一帧启动反向动画，第二帧完成并卸载）。
    Future<void> settleClose(WidgetTester tester) async {
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pump(const Duration(milliseconds: 300));
    }

    /// 我的页外层 ListView（唯一滚动容器；懒建，滚到才会构建出子项）。
    Finder mineList() => find
        .descendant(
          of: find.byType(MineScreen),
          matching: find.byType(ListView),
        )
        .first;

    /// 切到「我的」tab，直接驱动外层 ListView 的 scroll position 分步
    /// jumpTo（不经手势，避免 fling 惯性越过懒建窗口），直到 [text]
    /// 对应的入口被构建出来；返回停稳后的入口 finder，可直接 tap。
    Future<Finder> scrollToMineEntry(WidgetTester tester, String text) async {
      await tester.tap(
        find.descendant(
          of: find.byType(NavigationRail),
          matching: find.byIcon(AppIcons.person),
        ),
      );
      await tester.pump(const Duration(milliseconds: 50));
      final entry = find.text(text);
      // Scrollable 由 ScrollView 在内部构建，是 ListView 的后代而非祖先。
      final ScrollableState state = tester.state<ScrollableState>(
        find
            .descendant(of: mineList(), matching: find.byType(Scrollable))
            .first,
      );
      // ListView 懒建：maxScrollExtent 是随子项构建而增长的估计值，分步
      // jumpTo（自 clamp 到当前估计），直到目标真正可见可点（hitTestable）；
      // 已到底且估计不再增长就停，避免空转。
      bool entryVisible() => entry.hitTestable().evaluate().isNotEmpty;
      double offset = 0;
      for (var i = 0; !entryVisible() && i < 100; i++) {
        final double maxNow = state.position.maxScrollExtent;
        final double target = (offset + 200).clamp(0.0, maxNow);
        state.position.jumpTo(target);
        offset = target;
        await tester.pump(const Duration(milliseconds: 30));
        if (offset >= maxNow - 0.5 &&
            state.position.maxScrollExtent <= maxNow + 0.5) {
          break; // 到底且估计不再增长
        }
      }
      expect(entryVisible(), isTrue, reason: '滚动后「$text」应可见可点');
      await tester.pump(const Duration(milliseconds: 100));
      return entry;
    }

    Future<_HarnessStores> buildStores(SettingsStore settings) async {
      final dir = await makeTempDir('aquan_onboarding');
      addTearDown(() {
        if (dir.existsSync()) dir.deleteSync(recursive: true);
      });
      return _HarnessStores(
        dir,
        settings,
        await SharedPreferences.getInstance(),
      );
    }

    testWidgets('首启弹一次；跳过即写标记且不再出现', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final settings = SettingsStore(await SharedPreferences.getInstance());
      settings.autoCheckUpdate = false;
      final stores = await buildStores(settings);

      await tester.pumpWidget(stores.build());
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(OnboardingDialog), findsOneWidget);
      expect(find.text('搜索有联想和热搜'), findsOneWidget);

      await tester.tap(find.text('跳过'));
      await settleClose(tester);
      expect(find.byType(OnboardingDialog), findsNothing);
      expect(settings.onboardingSeen, isTrue, reason: '跳过与完成等效');

      // 稍后再等一帧也不复弹（触发只在 initState 的首帧回调里跑一次）。
      await tester.pump(const Duration(seconds: 2));
      expect(find.byType(OnboardingDialog), findsNothing);

      await flushTimers(tester);
    });

    testWidgets('TV 形态不弹，「重看新手引导」入口隐藏', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final settings = SettingsStore(await SharedPreferences.getInstance());
      settings.autoCheckUpdate = false;
      final stores = await buildStores(settings);

      await tester.pumpWidget(stores.build(formFactor: AppFormFactor.tv));
      await tester.pump(const Duration(milliseconds: 400));
      expect(settings.onboardingSeen, isFalse, reason: 'TV 不写标记');
      expect(find.byType(OnboardingDialog), findsNothing);

      // 我的页设置区滚出来（ListView 懒建）：「播放器指南」仍在，
      // 而紧随其后的「重看新手引导」入口应被 TV 守卫隐藏。
      final guide = await scrollToMineEntry(tester, '播放器指南');
      expect(guide, findsOneWidget);
      expect(find.text('重看新手引导'), findsNothing, reason: 'TV 设置页无重看入口');

      await flushTimers(tester);
    });

    testWidgets('桌面端走完四页「开始使用」→ 重建不再弹', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final settings = SettingsStore(await SharedPreferences.getInstance());
      settings.autoCheckUpdate = false;
      final stores = await buildStores(settings);

      await tester.pumpWidget(stores.build(formFactor: AppFormFactor.desktop));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(OnboardingDialog), findsOneWidget);
      expect(find.text('Ctrl+F / Ctrl+K 随时搜剧'), findsOneWidget);

      await tester.tap(find.text('下一步'));
      await settlePageTurn(tester);
      await tester.tap(find.text('下一步'));
      await settlePageTurn(tester);
      await tester.tap(find.text('下一步'));
      await settlePageTurn(tester);
      expect(find.text('开始使用'), findsOneWidget);

      await tester.tap(find.text('开始使用'));
      await settleClose(tester);
      expect(find.byType(OnboardingDialog), findsNothing);
      expect(settings.onboardingSeen, isTrue);

      // 整棵树拆掉重建 = 冷启动：已看过 → 不弹。
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpWidget(stores.build(formFactor: AppFormFactor.desktop));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(OnboardingDialog), findsNothing);

      await flushTimers(tester);
    });

    testWidgets('已看过（含备份恢复回来的设备）重建不弹', (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'ui.onboardingSeen': true,
      });
      final settings = SettingsStore(await SharedPreferences.getInstance());
      settings.autoCheckUpdate = false;
      final stores = await buildStores(settings);

      await tester.pumpWidget(stores.build());
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(OnboardingDialog), findsNothing);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpWidget(stores.build());
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(OnboardingDialog), findsNothing);

      await flushTimers(tester);
    });

    testWidgets('设置页「重看新手引导」可再次弹出', (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'ui.onboardingSeen': true,
      });
      final settings = SettingsStore(await SharedPreferences.getInstance());
      settings.autoCheckUpdate = false;
      final stores = await buildStores(settings);

      await tester.pumpWidget(stores.build());
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(OnboardingDialog), findsNothing);

      // 切到「我的」tab，把设置区滚出来，点设置页里的重看入口。
      final entry = await scrollToMineEntry(tester, '重看新手引导');
      await tester.tap(entry);
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.byType(OnboardingDialog), findsOneWidget);
      expect(find.text('搜索有联想和热搜'), findsOneWidget);

      await tester.tap(find.text('跳过'));
      await settleClose(tester);
      expect(find.byType(OnboardingDialog), findsNothing);

      await flushTimers(tester);
    });
  });
}
