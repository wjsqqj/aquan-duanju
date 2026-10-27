import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

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

class _HomeScreenState extends State<HomeScreen> {
  int _tab = 0;

  static const _tabs = [
    (Icons.explore_outlined, Icons.explore, '发现'),
    (Icons.shuffle_outlined, Icons.shuffle, '随机'),
    (Icons.leaderboard_outlined, Icons.leaderboard, '榜单'),
    (Icons.person_outline, Icons.person, '我的'),
  ];

  @override
  void initState() {
    super.initState();
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.windows) {
      _initWindow();
    }
  }

  Future<void> _initWindow() async {
    await windowManager.ensureInitialized();
    const options = WindowOptions(
      title: '阿圈短剧',
      minimumSize: Size(900, 560),
      size: Size(1180, 760),
      center: true,
      titleBarStyle: TitleBarStyle.normal,
    );
    await windowManager.waitUntilReadyToShow(options, () async {
      await windowManager.show();
      await windowManager.focus();
    });
  }

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
