import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:aquan_duanju/widgets/motion/magnetic_field.dart';

Widget _host({
  bool disableAnimations = false,
  TargetPlatform platform = TargetPlatform.android,
}) => MaterialApp(
  theme: ThemeData(platform: platform),
  home: MediaQuery(
    data: MediaQueryData(disableAnimations: disableAnimations),
    child: Scaffold(
      body: FxMagneticField(
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const Icon(Icons.warning_amber_outlined),
              FilledButton(onPressed: () {}, child: const Text('重试')),
            ],
          ),
        ),
      ),
    ),
  ),
);

dynamic _state(WidgetTester tester) =>
    tester.state(find.byType(FxMagneticField));

/// 挂一个鼠标指针到 [location]（触发 MouseRegion hover）。
Future<TestGesture> _hover(WidgetTester tester, Offset location) async {
  final TestGesture gesture = await tester.createGesture(
    kind: PointerDeviceKind.mouse,
  );
  await gesture.addPointer(location: Offset.zero);
  await gesture.moveTo(location);
  addTearDown(gesture.removePointer);
  return gesture;
}

void main() {
  testWidgets('移动/TV（默认 android）：零构建——无卡片、无物理', (tester) async {
    await tester.pumpWidget(_host());
    expect(find.text('重试'), findsOneWidget);
    expect(_state(tester).debugPhysics, isFalse);
    expect(_state(tester).debugStaticOnly, isFalse);
    expect(_state(tester).debugTickerActive, isFalse);
    expect(_state(tester).debugCardCount, 0);
  });

  testWidgets('桌面：卡片建场（宽屏 11 张），静止态零位移', (tester) async {
    await tester.pumpWidget(_host(platform: TargetPlatform.windows));
    // 默认测试面 800×600 → 宽屏表 11 张。
    expect(_state(tester).debugCardCount, 11);
    expect(_state(tester).debugTickerActive, isFalse); // 静止自动停表
    expect(_state(tester).debugCardDisplacement(0).distance, lessThan(0.01));
    // 卡片确实画出来了。
    expect(find.byType(CustomPaint), findsWidgets);
  });

  testWidgets('弹簧推摆：指针靠近卡片被推开，随后沿弹簧摆回', (tester) async {
    await tester.pumpWidget(_host(platform: TargetPlatform.windows));
    // 卡 0 home ≈ (0.07×800, 0.14×600) = (56, 84)；指针停在它左侧 16px。
    final TestGesture gesture = await _hover(tester, const Offset(40, 84));
    await tester.pump(); // hover 事件下一帧路由到 MouseRegion
    await tester.pump(const Duration(milliseconds: 32));

    expect(_state(tester).debugTickerActive, isTrue);
    final Offset pushed = _state(tester).debugCardDisplacement(0);
    expect(pushed.distance, greaterThan(1.0));

    // 指针甩到对角（超出影响半径 230px）：目标回 home，弹簧摆回 + 停表。
    await gesture.moveTo(const Offset(790, 590));
    await tester.pumpAndSettle();
    expect(_state(tester).debugTickerActive, isFalse);
    expect(_state(tester).debugCardDisplacement(0).distance, lessThan(0.1));
  });

  testWidgets('指针离场（removePointer → onExit）：卡片弹回 home 并停表', (tester) async {
    await tester.pumpWidget(_host(platform: TargetPlatform.windows));
    final TestGesture gesture = await _hover(tester, const Offset(40, 84));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 32));
    expect(_state(tester).debugTickerActive, isTrue);

    await gesture.removePointer();
    await tester.pumpAndSettle();
    expect(_state(tester).debugTickerActive, isFalse);
    expect(_state(tester).debugCardDisplacement(0).distance, lessThan(0.1));
  });

  testWidgets('窄屏：切换到 7 张卡表', (tester) async {
    // 收缩测试窗口（MaterialApp 不受外层 SizedBox 约束）。
    tester.view.physicalSize = const Size(500, 600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_host(platform: TargetPlatform.windows));
    expect(_state(tester).debugCardCount, 7);
  });

  testWidgets('磁力卡层 IgnorePointer：不抢空态按钮手势', (tester) async {
    var tapped = false;
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.windows),
        home: Scaffold(
          body: FxMagneticField(
            child: Center(
              child: FilledButton(
                onPressed: () => tapped = true,
                child: const Text('重试'),
              ),
            ),
          ),
        ),
      ),
    );
    // 按钮在中央（磁力卡只在四周）：命中直达按钮，磁力卡层不拦截。
    await tester.tap(find.text('重试'));
    await tester.pump();
    expect(tapped, isTrue);
    // 空白处（卡片所在区域）点击：穿透装饰层，不抛命中异常。
    await tester.tapAt(const Offset(56, 84));
    await tester.pump();
    expect(tapped, isTrue); // 空白点击不触发按钮也不破坏场
  });

  testWidgets('reduceMotion（桌面）：静态卡场，无物理', (tester) async {
    await tester.pumpWidget(
      _host(platform: TargetPlatform.windows, disableAnimations: true),
    );
    expect(_state(tester).debugStaticOnly, isTrue);
    expect(_state(tester).debugPhysics, isFalse);
    expect(_state(tester).debugTickerActive, isFalse);
    expect(find.byType(CustomPaint), findsWidgets); // 卡片静态在场
    // hover 不引起任何物理响应（场保持静态完好）。
    await _hover(tester, const Offset(40, 84));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 32));
    expect(_state(tester).debugTickerActive, isFalse);
    expect(find.byType(CustomPaint), findsWidgets);
  });
}
