import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import '../widgets/common.dart';

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

  static const _tabs = [
    (Icons.explore_outlined, Icons.explore, '发现'),
    (Icons.shuffle_outlined, Icons.shuffle, '随机'),
    (Icons.leaderboard_outlined, Icons.leaderboard, '榜单'),
    (Icons.person_outline, Icons.person, '我的'),
  ];

  @override
  void initState() {
    super.initState();
    if (!kIsWeb &&
        (Platform.isWindows || Platform.isMacOS || Platform.isLinux)) {
      _initWindow();
    }
  }

  Future<void> _initWindow() async {
    final saved = AppScope.read(context).settings.windowBounds;
    await windowManager.ensureInitialized();
    windowManager.addListener(this);
    WindowOptions options = const WindowOptions(
      title: '阿圈短剧',
      minimumSize: Size(380, 480),
      size: Size(1180, 760),
      center: true,
      titleBarStyle: TitleBarStyle.normal,
    );
    if (saved != null) {
      try {
        final raw = jsonDecode(saved) as Map<String, dynamic>;
        final rect = Rect.fromLTWH(
          (raw['x'] as num).toDouble(),
          (raw['y'] as num).toDouble(),
          (raw['w'] as num).toDouble(),
          (raw['h'] as num).toDouble(),
        );
        _savedRect = rect;
        options = WindowOptions(
          title: '阿圈短剧',
          minimumSize: const Size(380, 480),
          size: rect.size,
          titleBarStyle: TitleBarStyle.normal,
        );
      } catch (_) {}
    }
    await windowManager.waitUntilReadyToShow(options, () async {
      final rect = _savedRect;
      if (rect != null) {
        // WindowOptions 没有 position 参数，位置在显示前 setBounds。
        await windowManager.setBounds(rect);
      } else {
        await windowManager.center();
      }
      await windowManager.show();
      await windowManager.focus();
    });
  }

  /// 拖动/缩放会连续触发，节流 800ms 落盘一次。
  void _scheduleSaveBounds() {
    _boundsSaveTimer?.cancel();
    _boundsSaveTimer = Timer(const Duration(milliseconds: 800), _saveBounds);
  }

  Future<void> _saveBounds() async {
    if (!mounted) return;
    final settings = AppScope.read(context).settings;
    try {
      if (await windowManager.isMaximized()) return;
      final bounds = await windowManager.getBounds();
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
    final wide = MediaQuery.sizeOf(context).width >= 760;
    final pages = [
      const DiscoverScreen(),
      RandomFeedScreen(active: _tab == 1),
      const RankingsScreen(),
      const MineScreen(),
    ];
    return Scaffold(
      body: Row(
        children: [
          if (wide)
            NavigationRail(
              selectedIndex: _tab,
              onDestinationSelected: (i) => setState(() => _tab = i),
              labelType: NavigationRailLabelType.all,
              destinations: [
                for (final t in _tabs)
                  NavigationRailDestination(
                    icon: Icon(t.$1),
                    selectedIcon: Icon(t.$2),
                    label: Text(t.$3),
                  ),
              ],
              trailing: IconButton(
                icon: const Icon(Icons.search),
                tooltip: '搜索',
                onPressed: () => showSearchScreen(context),
              ),
            ),
          VerticalDivider(width: 1, thickness: 1,
              color: Theme.of(context).colorScheme.surfaceContainerHighest),
          Expanded(child: IndexedStack(index: _tab, children: pages)),
        ],
      ),
      bottomNavigationBar: wide
          ? null
          : NavigationBar(
              selectedIndex: _tab,
              onDestinationSelected: (i) => setState(() => _tab = i),
              destinations: [
                for (final t in _tabs)
                  NavigationDestination(
                    icon: Icon(t.$1),
                    selectedIcon: Icon(t.$2),
                    label: t.$3,
                  ),
              ],
            ),
    );
  }
}
