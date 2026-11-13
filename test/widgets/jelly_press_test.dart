import 'package:aquan_duanju/widgets/jelly/jelly_press.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Matrix4 currentTransform(WidgetTester tester) {
  final transform = tester.widget<Transform>(
    find
        .descendant(of: find.byType(JellyPress), matching: find.byType(Transform))
        .first,
  );
  return transform.transform;
}

void main() {
  testWidgets('JellyPress 渲染不抛异常', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Center(
          child: JellyPress(child: SizedBox(width: 120, height: 60)),
        ),
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(currentTransform(tester).getMaxScaleOnAxis(), closeTo(1, 0.0001));
  });

  testWidgets('按下压扁、松手回弹到原状', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Center(
          child: JellyPress(child: SizedBox(width: 120, height: 60)),
        ),
      ),
    );
    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(JellyPress)),
    );
    await tester.pump(const Duration(milliseconds: 24));

    final pressed = currentTransform(tester);
    expect(pressed.entry(0, 0), greaterThan(1)); // 横向被拉宽
    expect(pressed.entry(1, 1), lessThan(1)); // 纵向被压扁

    await gesture.up();
    for (var i = 0; i < 120; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(currentTransform(tester).getMaxScaleOnAxis(), closeTo(1, 0.002));
  });

  testWidgets('松手后必须「duang」：反向鼓起且来回多次', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Center(
          child: JellyPress(child: SizedBox(width: 120, height: 60)),
        ),
      ),
    );
    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(JellyPress)),
    );
    // 按住到接近最大压缩
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    final pressedScale = currentTransform(tester).entry(0, 0);
    expect(pressedScale, greaterThan(1.02), reason: '按下要看得见压扁');

    await gesture.up();

    var previous = pressedScale - 1;
    var crossings = 0;
    var minValue = previous;
    for (var i = 0; i < 90; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      final value = currentTransform(tester).entry(0, 0) - 1;
      if (value * previous < 0) crossings++;
      if (value < minValue) minValue = value;
      previous = value;
    }

    // ζ≈0.19 的欠阻尼弹簧：松手后应先反向鼓起，再来回若干次
    expect(minValue, lessThan(-0.015), reason: '松手要反向鼓起（过冲）');
    expect(crossings, greaterThanOrEqualTo(3), reason: '要 duang 几下，不能一次收住');
  });

  testWidgets('disableAnimations 时不形变', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: const Center(
            child: JellyPress(child: SizedBox(width: 120, height: 60)),
          ),
        ),
      ),
    );
    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(JellyPress)),
    );
    await tester.pump(const Duration(milliseconds: 24));
    expect(currentTransform(tester).getMaxScaleOnAxis(), closeTo(1, 0.0001));
    await gesture.up();
    await tester.pump();
  });
}
