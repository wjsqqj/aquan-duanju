import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:window_manager/window_manager.dart';

import '../core/ops_switches.dart';
import '../core/reader/reader_speech_controller.dart';
import '../core/window_geometry.dart';
import '../theme/app_metrics.dart';
import '../theme/app_tokens.dart';
import '../update/update_service.dart';
import '../widgets/common.dart';
import '../widgets/glass/glass_nav.dart';
import '../widgets/tv_scope.dart';
import '../widgets/reader/reader_audio_bar.dart';
import '../widgets/ui/shell_stage.dart';
import '../widgets/jelly/liquid_waves.dart';
import '../widgets/jelly/jelly_press.dart';
import '../widgets/ui/app_icons.dart';
import '../widgets/ui/app_interactive.dart';

import 'discover_screen.dart';
import 'mine_screen.dart';
import 'random_feed_screen.dart';
import 'rankings_screen.dart';
import 'search_screen.dart';

/// 应用壳：Android 底部导航 / Windows 左侧导航栏，四个 tab。
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WindowListener {
  int _tab = 0;
  Rect? _savedRect;
  Timer? _boundsSaveTimer;

  /// 四个 tab 的图标与中文标签，顺序即语义（发现 / 随机 / 榜单 / 我的）。
  ///
  /// 图标一律取 [AppIcons]（全库唯一的图标集），不写裸 `Icons.*`。
  static const _tabs = [
    (AppIcons.discover, '发现'),
    (AppIcons.shuffle, '随机'),
    (AppIcons.leaderboard, '榜单'),
    (AppIcons.person, '我的'),
  ];

  @override
  void initState() {
    super.initState();
    if (!kIsWeb &&
        (Platform.isWindows || Platform.isMacOS || Platform.isLinux)) {
      _initWindow();
    }
    // 启动后半分钟静默查一次新版本，失败不打扰；提示出现在「我的」页。
    // 开关与运维急停都在触发时现读，改设置不用重启。
    Timer(const Duration(seconds: 30), () {
      if (!mounted) return;
      final settings = AppScope.read(context).settings;
      if (!settings.autoCheckUpdate || OpsSwitches.disableAutoUpdate) return;
      UpdateService.instance.checkQuietly();
    });
  }

  Future<void> _initWindow() async {
    final saved = AppScope.read(context).settings.windowBounds;
    await windowManager.ensureInitialized();
    windowManager.addListener(this);
    var geometry = WindowGeometryGuard.sanitize(null);
    if (saved != null) {
      try {
        final raw = jsonDecode(saved) as Map<String, dynamic>;
        final rect = Rect.fromLTWH(
          (raw['x'] as num).toDouble(),
          (raw['y'] as num).toDouble(),
          (raw['w'] as num).toDouble(),
          (raw['h'] as num).toDouble(),
        );
        // 多显示器工作区用于判断保存的位置是否还看得见；取不到时退化为
        // 「只剔除明显的最小化占位坐标」。
        var workAreas = const <Rect>[];
        try {
          final displays = await screenRetriever.getAllDisplays();
          workAreas = [
            for (final d in displays)
              Rect.fromLTWH(
                d.visiblePosition?.dx ?? 0,
                d.visiblePosition?.dy ?? 0,
                d.visibleSize?.width ?? d.size.width,
                d.visibleSize?.height ?? d.size.height,
              ),
          ];
        } catch (_) {}
        geometry = WindowGeometryGuard.sanitize(rect, workAreas: workAreas);
      } catch (_) {}
    }
    _savedRect = geometry.position == null
        ? null
        : Rect.fromLTWH(geometry.position!.dx, geometry.position!.dy,
            geometry.size.width, geometry.size.height);
    await windowManager.waitUntilReadyToShow(
      WindowOptions(
        title: '阿圈短剧',
        minimumSize: const Size(380, 480),
        size: geometry.size,
        center: geometry.position == null,
        titleBarStyle: TitleBarStyle.normal,
      ),
      () async {
        final rect = _savedRect;
        if (rect != null) {
          // WindowOptions 没有 position 参数，位置在显示前 setBounds。
          await windowManager.setBounds(rect);
        } else {
          await windowManager.center();
        }
        await windowManager.show();
        await windowManager.focus();
      },
    );
  }

  /// 拖动/缩放会连续触发，节流 800ms 落盘一次。
  void _scheduleSaveBounds() {
    _boundsSaveTimer?.cancel();
    _boundsSaveTimer = Timer(const Duration(milliseconds: 800), _saveBounds);
  }

  Future<void> _saveBounds() async {
    if (!mounted) return;
    final settings = AppScope.read(context).settings;
    // 迷你小窗的尺寸不落盘，还原后的正常窗口才值得记住。
    if (settings.miniWindowActive) return;
    try {
      // 最小化 / 最大化时 Windows 给的是占位几何，不落盘。
      final minimized = await windowManager.isMinimized();
      if (minimized || await windowManager.isMaximized()) return;
      final bounds = await windowManager.getBounds();
      if (!WindowGeometryGuard.isPersistable(
          minimized: minimized, size: bounds.size)) {
        return;
      }
      settings.windowBounds = jsonEncode({
        'x': bounds.left,
        'y': bounds.top,
        'w': bounds.width,
        'h': bounds.height,
      });
    } catch (_) {}
  }

  @override
  void onWindowClose() async {
    await _saveBounds();
    await windowManager.destroy();
  }

  @override
  void onWindowResize() => _scheduleSaveBounds();

  @override
  void onWindowMove() => _scheduleSaveBounds();

  @override
  Widget build(BuildContext context) {
    final AppMetrics m = context.app.metrics;
    final width = MediaQuery.sizeOf(context).width;
    final wide = width >= 760;
    final tv = TvScope.isTvOf(context);
    final pages = [
      const DiscoverScreen(),
      RandomFeedScreen(active: _tab == 1),
      const RankingsScreen(),
      const MineScreen(),
    ];
    final speech = AppScope.read(context).speech;
    return Focus(
      autofocus: true,
      onKeyEvent: _onKeyEvent,
      child: Scaffold(
        body: Row(
          children: [
            if (wide) _rail(m, tv: tv),
            // 分隔线只给宽度，线宽与颜色全部来自 `dividerTheme`（1px hairline）。
            if (wide) VerticalDivider(width: m.hairline),
            Expanded(
              // 四页始终留在组件树上（`IndexedStack` 只切显示哪一页），切 tab
              // 不重建页面，滚动位置与 keepAlive 状态都不丢。所以这里**不加**
              // 切换过渡：任何换 key 的 switcher 都会把整棵子树换掉 = 丢状态，
              // 「保状态」优先于动效。
              child: ShellStage(child: IndexedStack(index: _tab, children: pages)),
            ),
          ],
        ),
        bottomNavigationBar: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (speech.isActive) _miniSpeechBar(speech),
            // 窄形态（手机 / 窄窗口）走底部导航条，高度 / 配色 / 指示器形状
            // 全部来自 `navigationBarTheme`。玻璃底板只换「面」：`selectedIndex`
            // / `destinations` / `onDestinationSelected` 原样透传，语义不变。
            if (!wide)
              GlassNavigationBar(
                child: NavigationBar(
                  selectedIndex: _tab,
                  onDestinationSelected: _selectTab,
                  destinations: [
                    for (final t in _tabs)
                      NavigationDestination(icon: Icon(t.$1), label: t.$2),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// 宽形态（桌面 / 电视）的左侧导航栏。
  Widget _rail(AppMetrics m, {required bool tv}) {
    // 电视观看距离远：导航图标与列宽都要放大，否则三米外看不清。
    final double iconSize = tv ? m.s32 : m.s24;
    final ThemeData theme = Theme.of(context);
    final AppTokens tokens = context.app;
    // 整条 Rail 是一块玻璃面（背后由 `GlassRailSurface` 铺舞台灯光，玻璃才看得见
    // 折射）。所以：Rail 自身底色设为透明、每一项不再单独铺玻璃（玻璃叠玻璃会
    // 出现重影接缝），选中态继续由 `AppInteractive` 的底色 + `brand` 描边表达。
    // 岩浆灯 Rail：暗底上文字/图标翻白（亮色主题下也是）——
    // Rail 玻璃内自成一套「暗色小主题」，与亮色内容区强碰撞。
    final Widget rail = Theme(
      data: theme.copyWith(
        navigationRailTheme: theme.navigationRailTheme.copyWith(
          unselectedLabelTextStyle:
              tokens.bodyStrong.copyWith(color: Colors.white.withValues(alpha: 0.88)),
          selectedLabelTextStyle:
              tokens.bodyStrong.copyWith(color: tokens.colors.brand),
        ),
      ),
      child: NavigationRail(
        backgroundColor: Colors.transparent,
        selectedIndex: _tab,
        onDestinationSelected: _selectTab,
        minWidth: tv ? m.s64 + m.s32 : null,
        useIndicator: false,
        destinations: [
          for (var i = 0; i < _tabs.length; i++)
            NavigationRailDestination(
              icon: _railItem(i, iconSize),
              label: Text(_tabs[i].$2),
            ),
        ],
        trailing: Padding(
          padding: EdgeInsets.only(top: m.s8, bottom: m.s8),
          child: AppInteractive(
            onTap: () => showSearchScreen(context),
            tooltip: '搜索',
            radius: BorderRadius.all(Radius.circular(m.radiusSm)),
            padding: _railTilePadding(m),
            // 果冻按压与其他 Rail 项一致（用户反馈：点搜索也要抖）。
            child: JellyPress(
              child: Icon(AppIcons.search, size: iconSize),
            ),
          ),
        ),
      ),
    );
    return GlassRailSurface(
      child: Stack(
        children: [
          // 液体层（用户反馈「去掉果冻滴，换成液体」）：Rail 底部一片
          // 缓慢起伏的水面，切 tab 时 slosh 振幅放大——不遮挡任何控件。
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: IgnorePointer(
              child: RailLiquidWaves(key: _wavesKey, height: 150),
            ),
          ),
          rail,
        ],
      ),
    );
  }

  /// 单个 Rail 项：hover / pressed / focus 与选中态仍然由 [AppInteractive] 给
  /// （`GlassRailItem` 内部就是它），玻璃只铺在当前选中项背后。
  Widget _railItem(int index, double iconSize) {
    final (IconData icon, String label) = _tabs[index];
    return GlassRailItem(
      icon: icon,
      label: label,
      selected: _tab == index,
      size: iconSize,
      // 整条 Rail 已是玻璃面，项内不再叠一层。
      glassPill: false,
      onTap: () => _selectTab(index),
    );
  }

  /// Rail 项的胶囊内边距：24 的图标 + 上下各 4 = 32 高、左右各 16 = 56 宽，
  /// 与 M3 原生指示器同尺寸，换掉指示器后外壳高度不变。
  EdgeInsetsGeometry _railTilePadding(AppMetrics m) =>
      EdgeInsets.fromLTRB(m.s16, m.s4, m.s16, m.s4);

  /// 液面 key：切 tab 时 slosh，水面振幅放大一下。
  final GlobalKey<RailLiquidWavesState> _wavesKey =
      GlobalKey<RailLiquidWavesState>();

  void _selectTab(int index) {
    setState(() => _tab = index);
    _wavesKey.currentState?.slosh();
  }

  /// 全局迷你听书条：朗读中离开阅读页也能控制。
  Widget _miniSpeechBar(ReaderSpeechController controller) =>
      ListenableBuilder(
        listenable: controller,
        builder: (context, _) => MiniSpeechBar(controller: controller),
      );

  /// 桌面全局快捷键：Ctrl+F 搜索、Ctrl+1..4 切页、F11 窗口全屏。
  /// 播放器页的按键它自己处理，未处理的会冒泡到这里（如 F11）。
  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (HardwareKeyboard.instance.isControlPressed) {
      if (key == LogicalKeyboardKey.keyF || key == LogicalKeyboardKey.keyK) {
        showSearchScreen(context);
        return KeyEventResult.handled;
      }
      final digitTabs = {
        LogicalKeyboardKey.digit1: 0,
        LogicalKeyboardKey.digit2: 1,
        LogicalKeyboardKey.digit3: 2,
        LogicalKeyboardKey.digit4: 3,
      };
      final tab = digitTabs[key];
      if (tab != null) {
        setState(() => _tab = tab);
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }
    if (key == LogicalKeyboardKey.f11) {
      windowManager.isFullScreen().then((full) async {
        await windowManager.setFullScreen(!full);
      });
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }
}
