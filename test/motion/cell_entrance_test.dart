import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:aquan_duanju/models/models.dart';
import 'package:aquan_duanju/widgets/common.dart';
import 'package:aquan_duanju/widgets/motion/cell_entrance.dart';

/// 入场的 scaleY 变换（alignment bottomCenter 是 smear 缩放的指纹）。
final Finder _entranceScale = find.descendant(
  of: find.byType(FxCellEntrance),
  matching: find.byWidgetPredicate(
    (w) => w is Transform && w.alignment == Alignment.bottomCenter,
  ),
);

double _scaleYOf(WidgetTester tester) {
  final Transform transform = tester.widget<Transform>(_entranceScale.first);
  return transform.transform.storage[5]; // 列主序：[5] = m11 = scaleY
}

/// 网格宿主：显式带真实视口尺寸的 MediaQuery（网格列数依赖宽度），
/// disableAnimations 单独叠加。
Widget _grid(
  WidgetTester tester,
  List<SeriesSummary> items, {
  bool disableAnimations = false,
}) {
  final MediaQueryData mq = MediaQueryData.fromView(tester.view)
      .copyWith(disableAnimations: disableAnimations);
  return MaterialApp(
    home: MediaQuery(
      data: mq,
      child: Scaffold(
        body: CustomScrollView(
          slivers: [SliverSeriesGrid(items: items, onTap: (_) {})],
        ),
      ),
    ),
  );
}

void main() {
  test('fxCellStaggerDelay：40ms 槽距、8 槽 cap', () {
    expect(fxCellStaggerDelay(0), Duration.zero);
    expect(fxCellStaggerDelay(1), const Duration(milliseconds: 40));
    expect(fxCellStaggerDelay(3), const Duration(milliseconds: 120));
    expect(fxCellStaggerDelay(8), const Duration(milliseconds: 320));
    expect(fxCellStaggerDelay(99), const Duration(milliseconds: 320));
  });

  testWidgets('首建播入场（scaleY 从 0.92 弹到 1），同 id 重建不重播', (tester) async {
    await tester.pumpWidget(
      _grid(tester, [const SeriesSummary(id: 'a', title: 'A')]),
    );
    await tester.pump();
    final double startScale = _scaleYOf(tester);
    expect(startScale, greaterThan(0.9));
    expect(startScale, lessThan(1.0), reason: '首帧处于压扁的入场中');

    await tester.pumpAndSettle();
    expect(_scaleYOf(tester), moreOrLessEquals(1.0, epsilon: 1e-9));

    // 重建（换新实例、同 id）：_entered 已收录 → 不重播。
    await tester.pumpWidget(
      _grid(tester, [const SeriesSummary(id: 'a', title: 'A')]),
    );
    await tester.pump(const Duration(milliseconds: 30));
    expect(
      _scaleYOf(tester),
      moreOrLessEquals(1.0, epsilon: 1e-9),
      reason: '同 id 重建不得重播入场',
    );
  });

  testWidgets('滚动往返：滚回已播过的条目不重播（State 重建 → 静态直出）', (tester) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final List<SeriesSummary> items = [
      for (var i = 0; i < 30; i++) SeriesSummary(id: 'i$i', title: 'T$i'),
    ];
    await tester.pumpWidget(_grid(tester, items));
    await tester.pumpAndSettle();

    await tester.drag(find.byType(CustomScrollView), const Offset(0, -6000));
    await tester.pumpAndSettle();
    await tester.drag(find.byType(CustomScrollView), const Offset(0, 6000));
    await tester.pump(); // 回到顶部后的第一帧

    // 判据：所有在树里的入场 Opacity 都必须是 1.0——若重播，重滚回来的
    // 那格首帧 opacity ≈ 0（delay 0 起跑）。settled 存活实例的 Opacity
    // 恒为 1，不受影响。
    final Iterable<Opacity> opacities = tester.widgetList<Opacity>(
      find.descendant(
        of: find.byType(FxCellEntrance),
        matching: find.byType(Opacity),
      ),
    );
    expect(opacities, isNotEmpty);
    for (final Opacity opacity in opacities) {
      expect(opacity.opacity, 1.0, reason: '滚动往返不得重播入场');
    }
    expect(find.text('T0'), findsOneWidget);
  });

  testWidgets('reduceMotion：直跳终态，无动画子树', (tester) async {
    await tester.pumpWidget(
      _grid(tester, [
        const SeriesSummary(id: 'a', title: 'A'),
      ], disableAnimations: true),
    );
    await tester.pump();
    expect(_entranceScale, findsNothing, reason: '静态路径直接出卡片，不建 transform 子树');
    expect(find.text('A'), findsOneWidget);
  });

  testWidgets('首屏交错：index 大的格子起跑更晚（delay 传入生效）', (tester) async {
    // 800×600 逻辑视口 → 4 列，6 格全在首屏（cols×3）内交错。
    final List<SeriesSummary> items = [
      for (var i = 0; i < 6; i++) SeriesSummary(id: 'i$i', title: 'T$i'),
    ];
    await tester.pumpWidget(_grid(tester, items));
    await tester.pump(const Duration(milliseconds: 20));

    double opacityAt(int index) {
      final Finder entrance = find.byType(FxCellEntrance).at(index);
      final Opacity opacity = tester.widget<Opacity>(
        find.descendant(of: entrance, matching: find.byType(Opacity)).first,
      );
      return opacity.opacity;
    }

    // index0（delay 0）已在淡入；index2（delay 80ms）还没起跑。
    expect(opacityAt(0), greaterThan(0));
    expect(opacityAt(2), 0.0);

    await tester.pumpAndSettle();
    expect(opacityAt(0), moreOrLessEquals(1.0));
    expect(opacityAt(2), moreOrLessEquals(1.0));
  });

  testWidgets('触底新条目即时入场（index ≥ cols×3 无交错延迟）', (tester) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final List<SeriesSummary> items = [
      for (var i = 0; i < 40; i++) SeriesSummary(id: 'i$i', title: 'T$i'),
    ];
    await tester.pumpWidget(_grid(tester, items));
    await tester.pumpAndSettle();

    // 滚到底，让底部新条目（index 32+）首次构建；第二拍让最底部格子的
    // 入场跑过至少一帧（首帧 opacity 恒 0）。
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -9000));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 50));

    // 底部条目没有交错延迟：入场当帧就已经起跑（opacity > 0）。
    final Finder entrance = find.byType(FxCellEntrance).last;
    final Opacity opacity = tester.widget<Opacity>(
      find.descendant(of: entrance, matching: find.byType(Opacity)).first,
    );
    expect(opacity.opacity, greaterThan(0));

    await tester.pumpAndSettle();
  });
}
