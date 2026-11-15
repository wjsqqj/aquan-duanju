import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:aquan_duanju/widgets/motion/redrawn_arrow.dart';
import 'package:aquan_duanju/widgets/ui/app_icons.dart';

Widget _host(
  Widget child, {
  bool disableAnimations = false,
  TargetPlatform platform = TargetPlatform.android,
}) => MaterialApp(
  theme: ThemeData(platform: platform),
  home: MediaQuery(
    data: MediaQueryData(disableAnimations: disableAnimations),
    child: Scaffold(
      body: Center(
        child: IconButton(onPressed: () {}, icon: child),
      ),
    ),
  ),
);

const Widget _arrow = FxRedrawnArrow(icon: Icon(AppIcons.next));

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

dynamic _state(WidgetTester tester) =>
    tester.state(find.byType(FxRedrawnArrow));

void main() {
  testWidgets('移动端（默认 android）：静态透传 Icon，不装控制器', (tester) async {
    await tester.pumpWidget(_host(_arrow));
    expect(find.byIcon(AppIcons.next), findsOneWidget);
    expect(_state(tester).debugAnimated, isFalse);
  });

  testWidgets('reduceMotion（桌面）：静态透传，不装控制器（AC20）', (tester) async {
    await tester.pumpWidget(
      _host(_arrow, platform: TargetPlatform.windows, disableAnimations: true),
    );
    expect(find.byIcon(AppIcons.next), findsOneWidget);
    expect(_state(tester).debugAnimated, isFalse);
  });

  testWidgets('桌面 hover：擦除先行 60ms 重画起跑、杆先、倒钩 lag 一拍', (tester) async {
    await tester.pumpWidget(_host(_arrow, platform: TargetPlatform.windows));
    expect(_state(tester).debugAnimated, isTrue);
    // 桌面动效路径不再渲染原 Icon（换自绘箭头）。
    expect(find.byIcon(AppIcons.next), findsNothing);

    await _hover(tester, tester.getCenter(find.byType(FxRedrawnArrow)));
    // 40ms：erase 已起跑（easeInCubic > 0），重画未起跑（lag 60ms）。
    await tester.pump(); // hover 事件下一帧才路由到 MouseRegion
    await tester.pump(const Duration(milliseconds: 40));
    expect(_state(tester).debugEraseT, greaterThan(0));
    expect(_state(tester).debugShaftT, 0);
    expect(_state(tester).debugBarbT, 0);

    // 累计 100ms：杆已重画、倒钩仍未起跑（barb 窗口 120ms 才开始）。
    await tester.pump(const Duration(milliseconds: 60));
    expect(_state(tester).debugShaftT, greaterThan(0));
    expect(_state(tester).debugBarbT, 0);

    await tester.pumpAndSettle();
    expect(_state(tester).debugEraseT, 1);
    expect(_state(tester).debugShaftT, 1);
    expect(_state(tester).debugBarbT, 1);
  });

  testWidgets('桌面 hover 离开：瞬间复位满箭头，不播退场动画', (tester) async {
    await tester.pumpWidget(_host(_arrow, platform: TargetPlatform.windows));
    final TestGesture gesture = await _hover(
      tester,
      tester.getCenter(find.byType(FxRedrawnArrow)),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));
    expect(_state(tester).debugEraseT, greaterThan(0));

    // 移出 → 复位（无动画：一帧内归零）。
    await gesture.moveTo(const Offset(-200, -200));
    await tester.pump();
    expect(_state(tester).debugEraseT, 0);
    expect(_state(tester).debugShaftT, 0);
    expect(_state(tester).debugBarbT, 0);
  });
}
