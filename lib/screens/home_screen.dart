import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import '../cli/launch_command.dart';
import '../cli/player_bus.dart';
import '../core/error_log.dart';
import '../core/ops_switches.dart';
import '../core/reader/reader_speech_controller.dart';
import '../core/window_geometry.dart';
import '../theme/app_metrics.dart';
import '../theme/app_tokens.dart';
import '../update/update_flow.dart';
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

class _HomeScreenState extends State<HomeScreen>
    with WindowListener, TrayListener {
  int _tab = 0;
  Rect? _savedRect;
  Timer? _boundsSaveTimer;

  /// 窗口是否已收进托盘（幂等守卫，避免关闭事件重入重复 hide）。
  bool _trayHidden = false;

  /// 托盘图标是否已显式删除（避免退出路径与 dispose 重复 destroy）。
  bool _trayDestroyed = false;

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
    // 启动后半分钟查一次新版本：有新版本直接弹窗（附更新说明），
    // 同时「我的」页仍有进度/待安装卡片。开关与运维急停都在触发时现读。
    Timer(const Duration(seconds: 30), _checkUpdateOnStart);
    // 启动 2 秒后预热 V5 会话（匿名设备 / 官方素材 / mssdk 令牌）：
    // 只建会话不取流，**不消耗**播放配额，用户点播放时少等几秒。
    // 延迟 2 秒避免与首屏加载抢资源；失败静默。
    unawaited(
      Future<void>.delayed(const Duration(seconds: 2), () async {
        if (!mounted) return;
        try {
          await AppScope.read(context).api.warmup();
        } catch (_) {
          // 预热是锦上添花：失败不影响任何功能。
        }
      }),
    );
  }

  /// 本会话已弹过更新的版本号：静默检查可能因重建/手动触发再次跑，
  /// 同一版本只打扰用户一次。
  final Set<String> _promptedUpdateVersions = <String>{};

  Future<void> _checkUpdateOnStart() async {
    if (!mounted) return;
    final settings = AppScope.read(context).settings;
    if (!settings.autoCheckUpdate || OpsSwitches.disableAutoUpdate) return;
    await UpdateService.instance.checkQuietly();
    if (!mounted) return;
    final service = UpdateService.instance;
    final version = service.latestVersion;
    if (version == null || !service.hasUpdate) return;
    // 用户点过「跳过此版本」时 service 已清空提示，这里再加一道保险。
    if (!_promptedUpdateVersions.add(version)) return;
    // 只有首页在前台才弹：播放页/详情页里弹更新会打断观看。
    if (ModalRoute.of(context)?.isCurrent != true) return;
    await updateInteractive(context, fromStartup: true);
  }

  Future<void> _initWindow() async {
    final saved = AppScope.read(context).settings.windowBounds;
    await windowManager.ensureInitialized();
    windowManager.addListener(this);
    // 关键：window_manager 默认不拦截 WM_CLOSE——onWindowClose 只是事件通知，
    // 系统仍会照常关窗退出。必须先 setPreventClose(true)，X 才能被改写成
    // 「收进托盘」；真正退出仍走 windowManager.destroy()（绕过 WM_CLOSE）。
    if (Platform.isWindows) {
      try {
        await windowManager.setPreventClose(true);
      } catch (e, stack) {
        ErrorLog.instance.record('托盘', e, stack);
      }
    }
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
    // 托盘只在 Windows 初始化：图标走 assets（插件自动拼到 flutter_assets）。
    // 失败不能拖垮启动，写进应用内错误日志后按普通窗口行为继续。
    if (Platform.isWindows) {
      try {
        await trayManager.setIcon('assets/tray/app_icon.ico');
        await trayManager.setToolTip('阿圈短剧');
        await trayManager.setContextMenu(Menu(
          items: [
            MenuItem(key: 'show_window', label: '显示主窗口'),
            MenuItem.separator(),
            MenuItem(key: 'exit_app', label: '退出'),
          ],
        ));
        trayManager.addListener(this);
        ErrorLog.instance.record('托盘', '托盘已初始化（X 收进托盘 / 右键菜单可退出）');
      } catch (e, stack) {
        ErrorLog.instance.record('托盘', e, stack);
      }
    }
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
    // 异步回调：settings 在 await 前取，避免跨 await 摸 context（M4-1）。
    final settings = AppScope.read(context).settings;
    await _saveBounds();
    if (settings.trayOnClose && Platform.isWindows) {
      ErrorLog.instance.record('托盘', '关闭按钮 → 收进托盘');
      await _hideToTray();
      return;
    }
    ErrorLog.instance.record('托盘', '关闭按钮 → 退出');
    await _exitApp();
  }

  /// 统一退出路径：先显式删除托盘图标，再关窗。
  ///
  /// 参考 zcode-switch 的「菜单 quit → app.exit(0)」：退出时必须清托盘。
  /// Flutter 进程被 PostQuitMessage 结束时 HomeScreen.dispose 不保证执行，
  /// Windows Shell 会留下幽灵图标，直到鼠标划过才清掉（11-19 用户实测）。
  Future<void> _exitApp() async {
    if (Platform.isWindows && !_trayDestroyed) {
      _trayDestroyed = true;
      try {
        await trayManager.destroy();
        ErrorLog.instance.record('托盘', '退出：托盘图标已移除');
      } catch (e, stack) {
        ErrorLog.instance.record('托盘', e, stack);
      }
    }
    await windowManager.destroy();
  }

  @override
  void onWindowMinimize() async {
    final settings = AppScope.read(context).settings;
    if (settings.trayOnMinimize && Platform.isWindows) {
      await _hideToTray();
    }
  }

  /// 收进托盘：隐藏窗口，按需进入轻量模式；下载脱离 UI 照常推进。
  Future<void> _hideToTray() async {
    if (_trayHidden) return;
    _trayHidden = true;
    final settings = AppScope.read(context).settings;
    try {
      await windowManager.hide();
    } catch (e, stack) {
      // 隐藏失败就退回普通窗口行为：复原守卫，别把窗口卡在「假托盘」态。
      _trayHidden = false;
      ErrorLog.instance.record('托盘', e, stack);
      return;
    }
    // 隐藏期间用户可能已从托盘唤回：此时不能再进轻量，否则窗口可见却停帧。
    if (!_trayHidden) return;
    if (settings.lightweightOnTray) {
      PlayerBus.instance.dispatch(LaunchCommand.parse(['--pause']));
      settings.lightweightActive = true;
    }
  }

  /// 托盘唤回：只恢复帧动画，不自动恢复播放（避免意外出声）。
  Future<void> _restoreFromTray() async {
    final settings = AppScope.read(context).settings;
    await windowManager.show();
    await windowManager.focus();
    _trayHidden = false;
    settings.lightweightActive = false;
  }

  @override
  void onTrayIconMouseDown() {
    unawaited(_restoreFromTray());
  }

  @override
  void onTrayIconRightMouseDown() {
    // tray_manager 0.5.x 在 Windows 上右键只发事件、不自动弹菜单；
    // 必须显式 popUpContextMenu()，否则「显示主窗口 / 退出」永远点不到。
    unawaited(trayManager.popUpContextMenu());
  }

  @override
  void onTrayMenuItemClick(MenuItem item) async {
    if (item.key == 'show_window') {
      await _restoreFromTray();
      return;
    }
    if (item.key == 'exit_app') {
      // 必须真退出，不能被关闭窗口时的托盘隐藏分支吞掉。
      // 保持 _trayHidden=true：若销毁途中冒出重入的关闭/最小化事件，
      // _hideToTray 的幂等守卫会直接吞掉，不会把退出又拽回托盘。
      final settings = AppScope.read(context).settings;
      _trayHidden = true;
      settings.lightweightActive = false;
      await _saveBounds();
      await _exitApp();
    }
  }

  @override
  void onWindowResize() => _scheduleSaveBounds();

  @override
  void onWindowMove() => _scheduleSaveBounds();

  @override
  void dispose() {
    _boundsSaveTimer?.cancel();
    if (!kIsWeb &&
        (Platform.isWindows || Platform.isMacOS || Platform.isLinux)) {
      windowManager.removeListener(this);
    }
    if (!kIsWeb && Platform.isWindows) {
      trayManager.removeListener(this);
      if (!_trayDestroyed) {
        _trayDestroyed = true;
        unawaited(trayManager.destroy());
      }
    }
    super.dispose();
  }

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
        backgroundColor: Colors.transparent,
        body: Row(
          children: [
            if (wide) _rail(m, tv: tv),
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
    // 整条 Rail 是一块玻璃面（背后由 `GlassRailSurface` 铺舞台灯光，玻璃才看得见
    // 折射）。所以：Rail 自身底色设为透明、每一项不再单独铺玻璃（玻璃叠玻璃会
    // 出现重影接缝），选中态继续由 `AppInteractive` 的底色 + `brand` 描边表达。
    final Widget rail = NavigationRail(
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
