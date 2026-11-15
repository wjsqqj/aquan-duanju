import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:aquan_duanju/widgets/motion/chase_line.dart';

Widget _host(
  Widget child, {
  bool disableAnimations = false,
  TargetPlatform platform = TargetPlatform.android,
}) => MaterialApp(
  theme: ThemeData(platform: platform),
  home: MediaQuery(
    data: MediaQueryData(disableAnimations: disableAnimations),
    child: Scaffold(body: Center(child: child)),
  ),
);

Future<TestGesture> _hover(WidgetTester tester, Offset location) async {
  final TestGesture gesture = await tester.createGesture(
    kind: PointerDeviceKind.mouse,
  );
  await gesture.addPointer(location: Offset.zero);
  await gesture.moveTo(location);
  addTearDown(gesture.removePointer);
  return gesture;
}

dynamic _state(WidgetTester tester) => tester.state(find.byType(FxChaseLine));

void main() {
  const String text = '阅读链接';
  const Widget line = FxChaseLine(text: text);

  testWidgets('移动端（默认 android）：静态透传 Text，不装控制器', (tester) async {
    await tester.pumpWidget(_host(line));
    expect(find.text(text), findsOneWidget);
    expect(_state(tester).debugAnimated, isFalse);
  });

  testWidgets('reduceMotion（桌面）：静态透传（AC20 条件分支）', (tester) async {
    await tester.pumpWidget(
      _host(line, platform: TargetPlatform.windows, disableAnimations: true),
    );
    expect(find.text(text), findsOneWidget);
    expect(_state(tester).debugAnimated, isFalse);
  });

  testWidgets('hover：accent 先行、ink lag 追上；落定双线满', (tester) async {
    await tester.pumpWidget(_host(line, platform: TargetPlatform.windows));
    expect(_state(tester).debugAnimated, isTrue);

    await _hover(tester, tester.getCenter(find.byType(FxChaseLine)));
    // 30ms：accent 已起跑，ink 还在 lag 窗口（60ms 才起跑）。
    await tester.pump(); // hover 事件下一帧才路由到 MouseRegion
    await tester.pump(const Duration(milliseconds: 30));
    expect(_state(tester).debugAccentT, greaterThan(0));
    expect(_state(tester).debugInkT, 0);

    await tester.pump(const Duration(milliseconds: 120));
    // 累计 150ms：accent 窗口（hover 150ms）已走完，ink 追跑中。
    expect(_state(tester).debugAccentT, closeTo(1, 0.01));
    expect(_state(tester).debugInkT, greaterThan(0));

    await tester.pumpAndSettle();
    expect(_state(tester).debugInkT, 1);
  });

  testWidgets('离场反序：ink 先退、accent 跟退；从当前值续起不跳变', (tester) async {
    await tester.pumpWidget(_host(line, platform: TargetPlatform.windows));
    final TestGesture gesture = await _hover(
      tester,
      tester.getCenter(find.byType(FxChaseLine)),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));
    final double accentMid = _state(tester).debugAccentT as double;
    final double inkMid = _state(tester).debugInkT as double;
    expect(accentMid, greaterThan(0));
    expect(inkMid, greaterThan(0));
    expect(inkMid, lessThan(accentMid), reason: '追跑中 ink 落后于 accent');

    // 离场：ink（后段窗口）先退、accent 跟退。
    await gesture.moveTo(const Offset(-300, -300));
    await tester.pump(); // hover 离场事件下一帧才路由到 MouseRegion
    await tester.pump(const Duration(milliseconds: 50));
    expect(_state(tester).debugInkT, lessThan(inkMid), reason: 'ink 先退');
    expect(
      _state(tester).debugAccentT,
      closeTo(accentMid, 0.05),
      reason: 'accent 窗口未退完前基本保持（从当前值续起，不跳变）',
    );

    await tester.pumpAndSettle();
    expect(_state(tester).debugAccentT, 0);
    expect(_state(tester).debugInkT, 0);
  });

  testWidgets('快速反复 hover：值续起不归零', (tester) async {
    await tester.pumpWidget(_host(line, platform: TargetPlatform.windows));
    final TestGesture gesture = await _hover(
      tester,
      tester.getCenter(find.byType(FxChaseLine)),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));
    expect(_state(tester).debugAccentT, greaterThan(0));

    // 快速移出再移回：前进值不从 0 重来。
    await gesture.moveTo(const Offset(-300, -300));
    await tester.pump(const Duration(milliseconds: 16));
    await gesture.moveTo(tester.getCenter(find.byType(FxChaseLine)));
    await tester.pump(const Duration(milliseconds: 16));
    expect(_state(tester).debugAccentT, greaterThan(0), reason: '快速反复从当前值续起');

    await tester.pumpAndSettle();
    expect(_state(tester).debugAccentT, 1);
    expect(_state(tester).debugInkT, 1);
  });

  testWidgets('letterRoll：滚字中按字符拆列，落定回到整词', (tester) async {
    await tester.pumpWidget(
      _host(
        const FxChaseLine(text: text, letterRoll: true),
        platform: TargetPlatform.windows,
      ),
    );
    await _hover(tester, tester.getCenter(find.byType(FxChaseLine)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    // 滚字中：整词 Text 被字符列替换。
    expect(find.text(text), findsNothing);
    expect(find.text(text.characters.first), findsWidgets);

    await tester.pumpAndSettle();
    // 落定：回整词单 Text。
    expect(find.text(text), findsOneWidget);
  });

  testWidgets('letterRoll 离场回滚：不残留拆列', (tester) async {
    await tester.pumpWidget(
      _host(
        const FxChaseLine(text: text, letterRoll: true),
        platform: TargetPlatform.windows,
      ),
    );
    final TestGesture gesture = await _hover(
      tester,
      tester.getCenter(find.byType(FxChaseLine)),
    );
    await tester.pump(); // hover 事件下一帧才路由到 MouseRegion
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));
    await gesture.moveTo(const Offset(-300, -300));
    await tester.pumpAndSettle();
    expect(find.text(text), findsOneWidget);
    expect(_state(tester).debugAccentT, 0);
  });
}
