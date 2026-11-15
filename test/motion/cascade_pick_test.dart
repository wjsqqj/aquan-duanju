import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:aquan_duanju/models/models.dart';
import 'package:aquan_duanju/widgets/motion/cascade_pick.dart';

const List<SeriesSummary> _items = [
  SeriesSummary(id: '1', title: '剧名一'),
  SeriesSummary(id: '2', title: '剧名二'),
  SeriesSummary(id: '3', title: '剧名三'),
  SeriesSummary(id: '4', title: '剧名四'),
  SeriesSummary(id: '5', title: '剧名五'),
  SeriesSummary(id: '6', title: '剧名六'),
];

dynamic _state(WidgetTester tester) => tester.state(find.byType(FxCascadePick));

/// 400 宽宿主：卡宽 = 400×0.62 = 248（≤380 cap），高 155。
/// 卡宽×0.8 = 198.4 是拖拽翻一张卡的行程。
Widget _host({
  required ValueChanged<SeriesSummary> onPick,
  List<SeriesSummary> items = _items,
  bool disableAnimations = false,
}) => MaterialApp(
  home: MediaQuery(
    data: MediaQueryData(disableAnimations: disableAnimations),
    child: Scaffold(
      body: Center(
        child: SizedBox.fromSize(
          size: const Size(400, 155),
          child: FxCascadePick(items: items, onPick: onPick),
        ),
      ),
    ),
  ),
);

/// 缓慢拖拽（无甩动速度）：拖 [dx] 后松手。
///
/// 起点取面板中心（800×600 视口里 400×155 面板居中 → (400, 300)）。
Future<void> _slowDrag(WidgetTester tester, double dx) async {
  final TestGesture gesture = await tester.startGesture(const Offset(400, 300));
  await gesture.moveBy(Offset(dx / 2, 0));
  await tester.pump();
  await gesture.moveBy(Offset(dx - dx / 2, 0));
  await tester.pump();
  await gesture.up();
  await tester.pump();
}

void main() {
  testWidgets('拖拽跟手：拖动中 offset 连续推进（不吸附），松手 0.7s 归位整卡', (tester) async {
    final List<SeriesSummary> picked = <SeriesSummary>[];
    await tester.pumpWidget(_host(onPick: picked.add));
    await tester.pump();
    expect(_state(tester).debugOffset, 0);

    final TestGesture gesture = await tester.startGesture(
      const Offset(400, 300),
    );
    // 首段 move 被手势竞技场当起步 slop 吃掉（DragStartBehavior.start），
    // 第二段起才真正跟手——这里分段推进来观察连续偏移。
    await gesture.moveBy(const Offset(-50, 0));
    await tester.pump();
    await gesture.moveBy(const Offset(-110, 0));
    await tester.pump();
    // 跟手：110/198.4 ≈ 0.55，处于 0..1 之间（不吸附整卡）。
    expect(_state(tester).debugOffset, allOf(greaterThan(0), lessThan(1)));
    await gesture.up();
    await tester.pump();
    expect(
      _state(tester).debugSettleDuration,
      fxCascadeDock,
      reason: '松手归位走 kit 常量 700ms（Fx.dockIn）',
    );
    await tester.pumpAndSettle();
    expect(_state(tester).debugOffset, 1, reason: '≈0.55 就近落整卡');
    expect(_state(tester).debugSettling, isFalse);
    expect(picked, isEmpty, reason: '拖拽/切换不触发确认回调');
  });

  testWidgets('点侧卡切换 0.7s 归位；点当前卡确认 onPick', (tester) async {
    final List<SeriesSummary> picked = <SeriesSummary>[];
    await tester.pumpWidget(_host(onPick: picked.add));
    await tester.pumpAndSettle();

    // 侧卡（rel=+1）右缘露出条：屏 x ∈ [400+124, 400+198.4]，点 560。
    await tester.tapAt(const Offset(560, 300));
    await tester.pump(const Duration(milliseconds: 120));
    expect(_state(tester).debugSettling, isTrue);
    await tester.pumpAndSettle();
    expect(_state(tester).debugOffset, 1);
    expect(picked, isEmpty);

    // 点当前卡（中心）= 确认。
    await tester.tapAt(const Offset(400, 300));
    await tester.pumpAndSettle();
    expect(picked, <SeriesSummary>[_items[1]]);
  });

  testWidgets('无限循环：连翻 n 张回到起点（取模）', (tester) async {
    await tester.pumpWidget(_host(onPick: (_) {}));
    await tester.pumpAndSettle();
    for (var i = 0; i < _items.length; i++) {
      await _slowDrag(tester, -210);
      await tester.pumpAndSettle();
    }
    expect(_state(tester).debugOffset, 0, reason: '6 张翻完归一取模回 0');
    // 反方向也成立：往回一张落到最后一张（环上 -1）。
    await _slowDrag(tester, 210);
    await tester.pumpAndSettle();
    expect(_state(tester).debugOffset, _items.length - 1);
  });

  testWidgets('甩动顺向多翻一张：慢拖 + 快速甩尾 → 落下一张', (tester) async {
    await tester.pumpWidget(_host(onPick: (_) {}));
    await tester.pump();
    final TestGesture gesture = await tester.startGesture(
      const Offset(400, 300),
    );
    // 首段吃 slop；两段真实推进 160px（0.81 卡），末段 40px/16ms 甩尾
    // 速度 ≈2500px/s ≥ 400 → fling 判定。
    await gesture.moveBy(const Offset(-30, 0));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    await gesture.moveBy(const Offset(-120, 0));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    await gesture.moveBy(const Offset(-40, 0));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(_state(tester).debugOffset, 1);
  });

  testWidgets('reduceMotion：切卡直跳终态（时长归零）', (tester) async {
    await tester.pumpWidget(_host(onPick: (_) {}, disableAnimations: true));
    await tester.pump();
    expect(_state(tester).debugSettleDuration, Duration.zero);
    await _slowDrag(tester, -210);
    await tester.pump();
    expect(_state(tester).debugOffset, 1, reason: '无动画直跳，无需 settle');
    await tester.pumpAndSettle();
    expect(_state(tester).debugOffset, 1);
  });

  testWidgets('单卡：无侧卡可切，点卡直接确认', (tester) async {
    final List<SeriesSummary> picked = <SeriesSummary>[];
    await tester.pumpWidget(
      _host(onPick: picked.add, items: _items.take(1).toList()),
    );
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(400, 300));
    await tester.pumpAndSettle();
    expect(picked, <SeriesSummary>[_items[0]]);
    await _slowDrag(tester, -210);
    await tester.pumpAndSettle();
    expect(_state(tester).debugOffset, 0, reason: '单卡翻不动');
  });
}
