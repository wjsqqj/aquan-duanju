import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:aquan_duanju/widgets/motion/velocity_squash.dart';

/// squash 缩放指纹：scope 内唯一的 Transform（alignment null = Transform.scale）。
double _scaleOf(WidgetTester tester) {
  final Transform transform = tester.widget<Transform>(
    find
        .descendant(
          of: find.byType(FxSquashCard),
          matching: find.byWidgetPredicate((w) => w is Transform),
        )
        .first,
  );
  return transform.transform.storage[0]; // scaleX = 等比缩放值
}

/// 往 scope 里注入一次滚动更新（delta px，间隔由 pump 推进）。
void _dispatch(BuildContext context, [double delta = 300]) {
  ScrollUpdateNotification(
    metrics: FixedScrollMetrics(
      minScrollExtent: 0,
      maxScrollExtent: 1000,
      pixels: 0,
      viewportDimension: 300,
      axisDirection: AxisDirection.right,
      devicePixelRatio: 1,
    ),
    context: context,
    scrollDelta: delta,
  ).dispatch(context);
}

Widget _host({bool disableAnimations = false, bool enabled = true}) =>
    MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(disableAnimations: disableAnimations),
        child: Scaffold(
          body: FxSquashScope(
            enabled: enabled,
            child: Builder(
              builder: (context) => Center(
                child: FxSquashCard(
                  child: TextButton(
                    onPressed: () => _dispatch(context),
                    child: const Text('dispatch'),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );

void main() {
  test('fxSquashForVelocity：软膝无硬帽，渐近 0.08', () {
    expect(fxSquashForVelocity(0), 0);
    expect(fxSquashForVelocity(-500), fxSquashForVelocity(500), reason: '取模');
    final double at3600 = fxSquashForVelocity(3600);
    expect(at3600, greaterThan(0.04), reason: '3600px/s 处已明显缩');
    expect(at3600, lessThan(0.06));
    expect(
      fxSquashForVelocity(360000),
      lessThan(0.081),
      reason: '无硬帽：极速也只渐近 0.08',
    );
  });

  testWidgets('滚动更新注入 → squash > 0（卡片轻缩）', (tester) async {
    await tester.pumpWidget(_host());
    await tester.tap(find.text('dispatch'));
    await tester.pump(); // 首次 delta 只记时刻，squash 还是 0
    await tester.pump(const Duration(milliseconds: 16));
    await tester.tap(find.text('dispatch'));
    await tester.pump(); // damper 起表推进一帧

    final double scale = _scaleOf(tester);
    expect(scale, lessThan(1.0), reason: '快滚时卡片轻缩');
    expect(scale, greaterThan(0.92), reason: '软膝：缩量不超过 8%');
  });

  testWidgets('停稳（空闲窗后拖尾归零）→ 复原为 1', (tester) async {
    await tester.pumpWidget(_host());
    await tester.tap(find.text('dispatch'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    await tester.tap(find.text('dispatch'));
    await tester.pump();
    expect(_scaleOf(tester), lessThan(1.0));

    // 空闲窗（fxSquashFollow 220ms）到点 → 拖尾目标归 0 → 阻尼收敛回 1。
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(_scaleOf(tester), 1.0);
  });

  testWidgets('reduceMotion：squash 不启用（无 Transform）', (tester) async {
    await tester.pumpWidget(_host(disableAnimations: true));
    await tester.tap(find.text('dispatch'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    await tester.tap(find.text('dispatch'));
    await tester.pump();
    expect(
      find.descendant(
        of: find.byType(FxSquashCard),
        matching: find.byWidgetPredicate((w) => w is Transform),
      ),
      findsNothing,
      reason: 'reduceMotion 整域停用，卡片原样直出',
    );
    expect(find.text('dispatch'), findsOneWidget);
  });

  testWidgets('enabled=false（TV 形态）与无 scope 祖先：卡片原样直出', (tester) async {
    await tester.pumpWidget(_host(enabled: false));
    await tester.tap(find.text('dispatch'));
    await tester.pump();
    expect(
      find.descendant(
        of: find.byType(FxSquashCard),
        matching: find.byWidgetPredicate((w) => w is Transform),
      ),
      findsNothing,
    );

    // FxSquashCard 没有 FxSquashScope 祖先 → 优雅退化。
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FxSquashCard(
            child: TextButton(onPressed: () {}, child: const Text('bare')),
          ),
        ),
      ),
    );
    expect(
      find.descendant(
        of: find.byType(FxSquashCard),
        matching: find.byWidgetPredicate((w) => w is Transform),
      ),
      findsNothing,
      reason: '无 scope 时不包 Transform（子树不被重挂载）',
    );
  });
}
