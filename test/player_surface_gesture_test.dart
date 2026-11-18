import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 播放页手势竞技场的实测：同一块 Surface 上长按（2 倍速）与竖直拖动
/// （移动端上下滑切集）并存时，**按住 500ms（kLongPressTimeout）后才开始的
/// 慢速拖动会被长按识别器整段抢走**——所以切集只认快速起拖的滑动手势。
///
/// 自动化验证（CUA 单跳拖动）永远瞬间越过 slop，拖动识别器立刻赢，
/// 所以之前真机自动化测不出这个冲突。
void main() {
  Future<void> pumpSurface(WidgetTester tester,
      {required VoidCallback onLongPress,
      required void Function(DragUpdateDetails) onVerticalUpdate}) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: GestureDetector(
          onLongPressStart: (_) => onLongPress(),
          onLongPressMoveUpdate: (_) {},
          onVerticalDragStart: (_) {},
          onVerticalDragUpdate: onVerticalUpdate,
          child: Container(color: Colors.white),
        ),
      ),
    ));
  }

  testWidgets('按住 600ms 后再拖：长按赢，竖直拖动收不到任何更新',
      (tester) async {
    var longPressStarts = 0;
    var verticalUpdates = 0;
    await pumpSurface(tester,
        onLongPress: () => longPressStarts++,
        onVerticalUpdate: (_) => verticalUpdates++);

    final center = tester.getCenter(find.byType(Container));
    final gesture = await tester.startGesture(center);
    // 真人操作：按下后先稳住（> kLongPressTimeout 500ms），再慢慢拖。
    await tester.pump(const Duration(milliseconds: 600));
    await gesture.moveBy(const Offset(0, -80));
    await tester.pump();
    await gesture.moveBy(const Offset(0, -80));
    await tester.pump();
    await gesture.up();
    await tester.pump();

    expect(longPressStarts, 1, reason: '按住 600ms 后长按已赢下手势竞技场');
    expect(verticalUpdates, 0, reason: '拖动更新全被长按吞掉——上下滑切集收不到');
  });

  testWidgets('按下后立刻拖（<500ms 越过 slop）：竖直拖动正常收到更新',
      (tester) async {
    var longPressStarts = 0;
    var verticalUpdates = 0;
    await pumpSurface(tester,
        onLongPress: () => longPressStarts++,
        onVerticalUpdate: (_) => verticalUpdates++);

    final center = tester.getCenter(find.byType(Container));
    final gesture = await tester.startGesture(center);
    await gesture.moveBy(const Offset(0, -60)); // 立刻大幅移动，拖动赢
    await tester.pump();
    await gesture.moveBy(const Offset(0, -60));
    await tester.pump();
    await gesture.up();
    await tester.pump();

    expect(verticalUpdates, greaterThan(0), reason: '快速起拖时拖动识别器赢');
    expect(longPressStarts, 0);
  });
}
