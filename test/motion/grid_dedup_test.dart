import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:aquan_duanju/models/models.dart';
import 'package:aquan_duanju/widgets/common.dart';

/// E0 质检遗留防护：服务端把同一部剧回进两页时，同路由重复 Hero tag 会
/// debug 断言崩——网格构建前必须按 id first-wins 保序去重。
void main() {
  group('SliverSeriesGrid 按 id 去重', () {
    testWidgets('重复 id 收敛为单卡，onTap 收到首条', (tester) async {
      final List<SeriesSummary> tapped = <SeriesSummary>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CustomScrollView(
              slivers: [
                SliverSeriesGrid(
                  items: const [
                    SeriesSummary(id: 'a', title: 'first'),
                    SeriesSummary(id: 'a', title: 'second'),
                    SeriesSummary(id: 'b', title: 'B'),
                  ],
                  onTap: tapped.add,
                ),
              ],
            ),
          ),
        ),
      );
      // 入场落定（pumpAndSettle 期间无重复 tag 断言 = Hero 撞 tag 面收敛）。
      await tester.pumpAndSettle();

      expect(find.byType(SeriesCard), findsNWidgets(2), reason: 'a×2 → 1 张');
      expect(find.text('first'), findsOneWidget);
      expect(find.text('second'), findsNothing);

      await tester.tap(find.text('first'));
      await tester.pump();
      expect(tapped.single.title, 'first', reason: 'onTap 闭包取去重后列表首条');
    });

    testWidgets('hasMore 占位计数按去重后列表（onLoadMore 不炸）', (tester) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      var loads = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CustomScrollView(
              slivers: [
                SliverSeriesGrid(
                  items: const [
                    SeriesSummary(id: 'a', title: 'first'),
                    SeriesSummary(id: 'a', title: 'second'),
                    SeriesSummary(id: 'b', title: 'B'),
                  ],
                  hasMore: true,
                  onLoadMore: () => loads++,
                  onTap: (_) {},
                ),
              ],
            ),
          ),
        ),
      );
      // 不用 pumpAndSettle：触底占位 AppLoading 是常驻动画，永不 settle。
      await tester.pump();
      await tester.pump();
      expect(find.byType(SeriesCard), findsNWidgets(2), reason: 'a×2+b → 2 张');
      expect(loads, greaterThanOrEqualTo(1), reason: '触底触发器正常挂上');
    });
  });

  group('SeriesGrid 按 id 去重', () {
    testWidgets('重复 id 收敛为单卡，onTap 收到首条', (tester) async {
      final List<SeriesSummary> tapped = <SeriesSummary>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SeriesGrid(
              items: const [
                SeriesSummary(id: 'a', title: 'first'),
                SeriesSummary(id: 'a', title: 'second'),
              ],
              onTap: tapped.add,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(SeriesCard), findsNWidgets(1));
      await tester.tap(find.text('first'));
      await tester.pump();
      expect(tapped.single.title, 'first');
    });
  });
}
