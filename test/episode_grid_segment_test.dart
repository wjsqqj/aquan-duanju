import 'dart:async';

import 'package:aquan_duanju/models/models.dart';
import 'package:aquan_duanju/widgets/episode_grid.dart';
import 'package:aquan_duanju/widgets/loading.dart';
import 'package:aquan_duanju/widgets/season_browse_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Episode ep(int number, {bool playable = true}) =>
    Episode(id: 'e$number', number: number, title: '', playable: playable);

Widget host(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  group('EpisodeGrid 长剧 100 集分段（A4）', () {
    testWidgets('101 集出现 2 段且默认段含当前集', (tester) async {
      final eps = [for (var i = 1; i <= 101; i++) ep(i)];
      await tester.pumpWidget(
        host(
          EpisodeGrid(
            episodes: eps,
            currentIndex: 100, // 第 101 集
            onSelect: (_) {},
          ),
        ),
      );
      expect(find.text('1-100'), findsOneWidget);
      expect(find.text('101-101'), findsOneWidget);
      // 默认段 = 当前集下标 ~/ 100 = 1：第 101 集可见。
      expect(find.text('101'), findsOneWidget);
      // 第 1 集属于另一段，不在当前显示范围里。
      expect(find.text('1'), findsNothing);
    });

    testWidgets('100 集不出现分段 UI（零视觉变化）', (tester) async {
      final eps = [for (var i = 1; i <= 100; i++) ep(i)];
      await tester.pumpWidget(
        host(EpisodeGrid(episodes: eps, currentIndex: 0, onSelect: (_) {})),
      );
      expect(find.text('1-100'), findsNothing);
      expect(find.text('101-200'), findsNothing);
      // 网格本体照旧。
      expect(find.text('1'), findsOneWidget);
    });

    testWidgets('点段切换显示范围正确，选集回调真实下标', (tester) async {
      final eps = [for (var i = 1; i <= 150; i++) ep(i)];
      var picked = -1;
      await tester.pumpWidget(
        host(
          EpisodeGrid(
            episodes: eps,
            currentIndex: 0,
            onSelect: (i) => picked = i,
          ),
        ),
      );
      // 默认段 1-100。
      expect(find.text('1'), findsOneWidget);
      expect(find.text('101-150'), findsOneWidget);

      await tester.tap(find.text('101-150'));
      await tester.pump();

      // 显示范围切到 101-150：段内最深的一集可见，段外的不在树里。
      expect(find.text('150'), findsOneWidget);
      expect(find.text('99'), findsNothing);
      // 点第 150 集 → 回调真实下标 149（不是段内下标）。
      await tester.tap(find.text('150'));
      expect(picked, 149);
    });

    testWidgets('点未加载段触发 onRequireRange（需要的最后下标）', (tester) async {
      final eps = [for (var i = 1; i <= 100; i++) ep(i)];
      int? required;
      await tester.pumpWidget(
        host(
          EpisodeGrid(
            episodes: eps,
            totalEpisodes: 300, // 元数据总集数 > 已加载列表
            currentIndex: 0,
            onSelect: (_) {},
            onRequireRange: (end) async {
              required = end;
            },
          ),
        ),
      );
      // 段数按元数据与已加载的较大者算。
      expect(find.text('201-300'), findsOneWidget);
      await tester.tap(find.text('101-200'));
      await tester.pump();
      expect(required, 199);
    });

    testWidgets('点已完整加载的段不触发 onRequireRange', (tester) async {
      final eps = [for (var i = 1; i <= 150; i++) ep(i)];
      var calls = 0;
      await tester.pumpWidget(
        host(
          EpisodeGrid(
            episodes: eps,
            currentIndex: 0,
            onSelect: (_) {},
            onRequireRange: (_) async {
              calls++;
            },
          ),
        ),
      );
      await tester.tap(find.text('101-150'));
      await tester.pump();
      expect(calls, 0, reason: '第二段已完整加载，不需要补数据');
    });

    testWidgets('当前集高亮与打勾跨段保持（切回段内仍在）', (tester) async {
      final eps = [for (var i = 1; i <= 150; i++) ep(i)];
      await tester.pumpWidget(
        host(
          EpisodeGrid(
            episodes: eps,
            currentIndex: 0,
            watchedEpisodes: const <int>{150},
            onSelect: (_) {},
          ),
        ),
      );
      // 默认段 1-100：第 1 集在段内。
      expect(find.text('1'), findsOneWidget);
      expect(find.byIcon(Icons.check_rounded), findsNothing);

      // 切到第二段：第 150 集的打勾出现（逻辑不动，只是显示范围变了）。
      await tester.tap(find.text('101-150'));
      await tester.pump();
      expect(find.byIcon(Icons.check_rounded), findsOneWidget);
    });
  });

  group('EpisodeGrid 未加载段的补拉反馈（1.12.16）', () {
    testWidgets('≤100 集永远不出现补拉反馈（零视觉变化）', (tester) async {
      final eps = [for (var i = 1; i <= 100; i++) ep(i)];
      await tester.pumpWidget(
        host(
          EpisodeGrid(
            episodes: eps,
            currentIndex: 0,
            onSelect: (_) {},
            totalEpisodes: 100,
            onRequireRange: (_) async {},
          ),
        ),
      );
      expect(find.byType(AppLoading), findsNothing);
      expect(find.text('加载失败，点按重试'), findsNothing);
      expect(find.text('101-200'), findsNothing);
    });

    testWidgets('点未加载段：拉取中显示规范加载件，供数后正常渲染', (tester) async {
      final key = GlobalKey<_RangeHostState>();
      await tester.pumpWidget(_RangeHost(key: key, behavior: _RangeLoad.supply));
      await tester.tap(find.text('101-200'));
      await tester.pump();

      // 成功路径：一格反馈都不停留，101-200 段正常渲染（视口内可见段首）。
      expect(key.currentState!.requests, <int>[199]);
      expect(find.byType(AppLoading), findsNothing);
      expect(find.text('加载失败，点按重试'), findsNothing);
      expect(find.text('101'), findsOneWidget);
      expect(find.text('99'), findsNothing);
    });

    testWidgets('拉取挂起：空段显示加载中反馈（规范加载件）', (tester) async {
      final key = GlobalKey<_RangeHostState>();
      await tester.pumpWidget(_RangeHost(key: key, behavior: _RangeLoad.hold));
      await tester.tap(find.text('101-200'));
      await tester.pump();

      expect(find.byType(AppLoading), findsOneWidget);
      expect(find.text('101'), findsNothing, reason: '该段尚未供数，只有反馈');
    });

    testWidgets('补拉失败：空段出现「加载失败，点按重试」，点按再次回调',
        (tester) async {
      final key = GlobalKey<_RangeHostState>();
      await tester.pumpWidget(_RangeHost(key: key, behavior: _RangeLoad.fail));
      await tester.tap(find.text('101-200'));
      await tester.pump();

      expect(find.text('加载失败，点按重试'), findsOneWidget);
      expect(find.byType(AppLoading), findsNothing);

      // 点按重试：再次回调 onRequireRange（同样的段尾下标）；仍失败回到
      // 可重试文案（加载中反馈的存在性已由 hold 用例覆盖）。
      await tester.tap(find.text('加载失败，点按重试'));
      await tester.pump();
      expect(key.currentState!.requests, <int>[199, 199]);
      expect(find.text('加载失败，点按重试'), findsOneWidget);
    });

    testWidgets('回调完成但段仍未覆盖（吞错/早退）：按失败给重试入口',
        (tester) async {
      final key = GlobalKey<_RangeHostState>();
      await tester.pumpWidget(_RangeHost(key: key, behavior: _RangeLoad.hold));
      await tester.tap(find.text('101-200'));
      await tester.pump();
      expect(find.byType(AppLoading), findsOneWidget);

      // 放行回调但不供数：完成 ≠ 成功，空段在下一帧转为可重试。
      key.currentState!.release();
      await tester.pump();
      await tester.pump();
      expect(find.text('加载失败，点按重试'), findsOneWidget);
      expect(find.byType(AppLoading), findsNothing);
    });

    testWidgets('无 onRequireRange：点未加载段只切范围，无反馈', (tester) async {
      final eps = [for (var i = 1; i <= 100; i++) ep(i)];
      await tester.pumpWidget(
        host(
          EpisodeGrid(
            episodes: eps,
            currentIndex: 0,
            onSelect: (_) {},
            totalEpisodes: 300,
          ),
        ),
      );
      await tester.tap(find.text('101-200'));
      await tester.pump();

      expect(find.byType(AppLoading), findsNothing);
      expect(find.text('加载失败，点按重试'), findsNothing);
      expect(find.text('101'), findsNothing);
    });
  });

  group('分段补拉在途排队（1.12.17 R2）', () {
    testWidgets('A 段在途点 B 段：B 走加载中不误报失败，最终正确渲染',
        (tester) async {
      final gates = <Completer<void>>[];
      var calls = 0;
      await tester.pumpWidget(_BrowseHost(fetch: (id) async {
        calls++;
        final gate = Completer<void>();
        gates.add(gate);
        await gate.future;
        // 第一次（A 段）只补到 150，覆盖不了 B 段的段尾。
        return calls == 1
            ? [for (var i = 1; i <= 150; i++) ep(i)]
            : [for (var i = 1; i <= 300; i++) ep(i)];
      }));
      expect(find.text('101-200'), findsOneWidget);

      // 点 A 段：进入加载中（gate 未放行）。
      await tester.tap(find.text('101-200'));
      await tester.pump();
      expect(find.byType(AppLoading), findsOneWidget);

      // A 还在途时点 B 段：B 显示加载中，而不是「失败」误报。
      await tester.tap(find.text('201-300'));
      await tester.pump();
      expect(find.text('加载失败，点按重试'), findsNothing);
      expect(find.byType(AppLoading), findsOneWidget);

      // A 落地（150 集）：B 段仍等自己的补拉，保持加载中不误报。
      gates.first.complete();
      await tester.pump();
      expect(find.text('加载失败，点按重试'), findsNothing);
      expect(find.byType(AppLoading), findsOneWidget);

      // B 落地（300 集）：B 段正确渲染。
      gates.last.complete();
      await tester.pump();
      expect(find.text('加载失败，点按重试'), findsNothing);
      expect(find.byType(AppLoading), findsNothing);
      expect(find.text('201'), findsOneWidget);
      expect(find.text('150'), findsNothing, reason: 'B 段只显示本段范围');
    });
  });
}

/// R2 排队场景的测试宿主：真实 [SeasonBrowseController] + 真实
/// [EpisodeGrid]，接线与 episode_picker / player_episode_drawer 一致
/// （AnimatedBuilder 重建、episodes/totalEpisodes/onRequireRange 三件套）。
class _BrowseHost extends StatefulWidget {
  const _BrowseHost({required this.fetch});

  final Future<List<Episode>> Function(String seriesId) fetch;

  @override
  State<_BrowseHost> createState() => _BrowseHostState();
}

class _BrowseHostState extends State<_BrowseHost> {
  late final SeasonBrowseController controller = SeasonBrowseController(
    seasons: const <Season>[
      Season(seriesId: 's1', title: '第一季', index: 1, episodeCount: 300),
    ],
    playingSeriesId: 's1',
    playingEpisodes: <Episode>[ep(1), ep(2)],
    playingIndex: 0,
    fetchSeasonEpisodes: widget.fetch,
  );

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: AnimatedBuilder(
          animation: controller,
          builder: (context, _) => EpisodeGrid(
            episodes: controller.episodes,
            currentIndex: controller.currentIndex,
            onSelect: (_) {},
            totalEpisodes: controller.current.episodeCount,
            onRequireRange: controller.requireRange,
          ),
        ),
      ),
    );
  }
}

/// 补拉行为（测试宿主参数）。
enum _RangeLoad { supply, hold, fail }

/// 段补拉反馈的测试宿主：episodes 由宿主持有，[_RangeLoad] 决定回调行为。
class _RangeHost extends StatefulWidget {
  const _RangeHost({super.key, this.behavior = _RangeLoad.supply});

  final _RangeLoad behavior;

  @override
  State<_RangeHost> createState() => _RangeHostState();
}

class _RangeHostState extends State<_RangeHost> {
  final List<int> requests = <int>[];

  final Completer<void> _gate = Completer<void>();
  late List<Episode> _eps = <Episode>[
    for (var i = 1; i <= 100; i++) ep(i),
  ];

  /// 放行挂起中的补拉回调（hold 行为用）。
  void release() => _gate.complete();

  Future<void> _load(int endIndex) async {
    requests.add(endIndex);
    switch (widget.behavior) {
      case _RangeLoad.supply:
        setState(() {
          _eps = <Episode>[for (var i = 1; i <= 300; i++) ep(i)];
        });
        return;
      case _RangeLoad.hold:
        await _gate.future;
        return;
      case _RangeLoad.fail:
        throw StateError('network down');
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: EpisodeGrid(
          episodes: _eps,
          currentIndex: 0,
          onSelect: (_) {},
          totalEpisodes: 300,
          onRequireRange: _load,
        ),
      ),
    );
  }
}
