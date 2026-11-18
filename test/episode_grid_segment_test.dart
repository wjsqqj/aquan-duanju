import 'package:aquan_duanju/models/models.dart';
import 'package:aquan_duanju/widgets/episode_grid.dart';
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
            onRequireRange: (end) => required = end,
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
            onRequireRange: (_) => calls++,
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
}
