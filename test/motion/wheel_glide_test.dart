import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:aquan_duanju/widgets/common.dart';

Widget _host({bool disableAnimations = false}) => MaterialApp(
  home: MediaQuery(
    data: MediaQueryData(disableAnimations: disableAnimations),
    child: Scaffold(
      body: Center(
        child: SizedBox(
          width: 300,
          child: HorizontalScrollStrip(
            height: 52,
            children: [
              for (var i = 0; i < 20; i++)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: Chip(label: Text('源$i')),
                ),
            ],
          ),
        ),
      ),
    ),
  ),
);

ScrollController _controllerOf(WidgetTester tester) =>
    tester.widget<ListView>(find.byType(ListView)).controller!;

/// 注入一格滚轮（120，与 horizontal_scroll_strip_test 同款注入方式）。
Future<void> _wheel(WidgetTester tester, Offset delta) async {
  final TestPointer pointer = TestPointer(1, PointerDeviceKind.mouse);
  await tester.sendEventToBinding(
    pointer.hover(tester.getCenter(find.byType(ListView))),
  );
  await tester.sendEventToBinding(pointer.scroll(delta));
}

void main() {
  testWidgets('滚轮：指数滑行逐帧逼近目标（非瞬跳）', (tester) async {
    await tester.pumpWidget(_host());
    await tester.pump();
    final ScrollController controller = _controllerOf(tester);
    expect(controller.offset, 0);

    await _wheel(tester, const Offset(0, 120));
    await tester.pump();
    // 第一帧只走了收敛的一小步（rate 8 固定步长吃 ~6.4%），绝不是瞬跳。
    expect(controller.offset, greaterThan(0));
    expect(controller.offset, lessThan(120));

    // 逐帧单调逼近目标。
    var prev = controller.offset;
    var settled = false;
    for (var i = 0; i < 120; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      expect(controller.offset, greaterThanOrEqualTo(prev), reason: '收敛单调');
      prev = controller.offset;
      if (controller.offset >= 119.5) {
        settled = true;
        break;
      }
    }
    expect(settled, isTrue, reason: 'rate=8 时 120 帧内必须逼近到位');
    // epsilon 0.5：停稳钉在终值。
    await tester.pumpAndSettle();
    expect(controller.offset, closeTo(120, 0.6));
  });

  testWidgets('reduceMotion：滚轮退回 jumpTo 直跳', (tester) async {
    await tester.pumpWidget(_host(disableAnimations: true));
    await tester.pump();
    final ScrollController controller = _controllerOf(tester);

    await _wheel(tester, const Offset(0, 120));
    await tester.pump();
    expect(controller.offset, 120, reason: '位移无动画语义：直接落目标');
  });

  testWidgets('拖拽对齐：滑行中按下指针立即停滑（防双源打架）', (tester) async {
    await tester.pumpWidget(_host());
    await tester.pump();
    final ScrollController controller = _controllerOf(tester);

    await _wheel(tester, const Offset(0, 240));
    await tester.pump();
    expect(controller.offset, inExclusiveRange(0, 240), reason: '滑行进行中');

    // 按下（拖拽起点）：阻尼钉回当前 offset 并停表。
    final TestGesture gesture = await tester.startGesture(
      tester.getCenter(find.byType(ListView)),
    );
    await tester.pump();
    final double atDown = controller.offset;
    await tester.pump(const Duration(milliseconds: 60));
    expect(controller.offset, atDown, reason: '按下后滑行必须立即停住，用户位移不受滑行目标覆盖');
    await gesture.up();
    await tester.pump();
  });

  testWidgets('连发滚轮：以滑行目标为基累计（不折损成一小步）', (tester) async {
    await tester.pumpWidget(_host());
    await tester.pump();
    final ScrollController controller = _controllerOf(tester);

    // 三连滚，间隔一帧（offset 还没追上目标）。
    await _wheel(tester, const Offset(0, 120));
    await tester.pump(const Duration(milliseconds: 16));
    await _wheel(tester, const Offset(0, 120));
    await tester.pump(const Duration(milliseconds: 16));
    await _wheel(tester, const Offset(0, 120));
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pumpAndSettle();

    expect(
      controller.offset,
      closeTo(360, 2.0),
      reason: '目标基取滑行 target：连发三格累计 360',
    );
  });
}
