import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:aquan_duanju/widgets/motion/film_jitter.dart';

Widget _host({
  bool disableAnimations = false,
  TargetPlatform platform = TargetPlatform.android,
}) => MaterialApp(
  theme: ThemeData(platform: platform),
  home: MediaQuery(
    data: MediaQueryData(disableAnimations: disableAnimations),
    child: Scaffold(
      body: Center(
        child: SizedBox(
          width: 200,
          height: 48,
          child: FxFilmJitter(child: const Text('立即播放')),
        ),
      ),
    ),
  ),
);

dynamic _state(WidgetTester tester) => tester.state(find.byType(FxFilmJitter));

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
  testWidgets('移动端（默认 android）：静态透传，不装 MouseRegion/控制器', (tester) async {
    await tester.pumpWidget(_host());
    expect(find.text('立即播放'), findsOneWidget);
    expect(_state(tester).debugAnimated, isFalse);
    // MaterialApp 自带一个 MouseRegion（文本选择/光标域），限定在本件子树内查。
    expect(
      find.descendant(
        of: find.byType(FxFilmJitter),
        matching: find.byType(MouseRegion),
      ),
      findsNothing,
    );
    expect(find.byType(AnimatedScale), findsNothing);
  });

  testWidgets('reduceMotion（桌面）：静态透传（AC20）', (tester) async {
    await tester.pumpWidget(
      _host(platform: TargetPlatform.windows, disableAnimations: true),
    );
    expect(find.text('立即播放'), findsOneWidget);
    expect(_state(tester).debugAnimated, isFalse);
    expect(
      find.descendant(
        of: find.byType(FxFilmJitter),
        matching: find.byType(MouseRegion),
      ),
      findsNothing,
    );
  });

  testWidgets('桌面 hover：外层微倾放大（1.035 / -1°）+ 内容层阶梯抖动起跑', (tester) async {
    await tester.pumpWidget(_host(platform: TargetPlatform.windows));
    expect(_state(tester).debugAnimated, isTrue);
    expect(_state(tester).debugHovered, isFalse);
    // 静置态：内容层零偏移（与无动效渲染逐像素一致，不吃 0 帧哈希值）。
    expect(_state(tester).debugJitter, (0.0, 0.0, 0.0));

    await _hover(tester, tester.getCenter(find.byType(FxFilmJitter)));
    await tester.pump(); // hover 事件下一帧才路由到 MouseRegion

    expect(_state(tester).debugHovered, isTrue);
    expect(_state(tester).debugJittering, isTrue);
    // 外层目标值：AnimatedScale/AnimatedRotation 的配置（150ms spring 内插）。
    expect(
      tester.widget<AnimatedScale>(find.byType(AnimatedScale)).scale,
      FxFilmJitterTuning.hoverScale,
    );
    expect(
      tester.widget<AnimatedRotation>(find.byType(AnimatedRotation)).turns,
      FxFilmJitterTuning.hoverTiltTurns,
    );

    // 内容层阶梯抖动值在 ±0.4° / ±0.5px / ±0.3px 包络内（任意帧成立）。
    final (double rot, double dx, double dy) = _state(tester).debugJitter;
    expect(
      rot.abs(),
      lessThanOrEqualTo(FxFilmJitterTuning.jitterRotateDegrees),
    );
    expect(dx.abs(), lessThanOrEqualTo(FxFilmJitterTuning.jitterDxPx));
    expect(dy.abs(), lessThanOrEqualTo(FxFilmJitterTuning.jitterDyPx));
  });

  testWidgets('桌面 hover 离开：外层回位（1.0/0 turns）、内容层停表归零', (tester) async {
    await tester.pumpWidget(_host(platform: TargetPlatform.windows));
    final TestGesture gesture = await _hover(
      tester,
      tester.getCenter(find.byType(FxFilmJitter)),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(_state(tester).debugJittering, isTrue);

    await gesture.moveTo(const Offset(-500, -500));
    await tester.pump();
    expect(_state(tester).debugHovered, isFalse);
    expect(tester.widget<AnimatedScale>(find.byType(AnimatedScale)).scale, 1.0);
    expect(
      tester.widget<AnimatedRotation>(find.byType(AnimatedRotation)).turns,
      0.0,
    );
    // 内容层 stop+reset：不再动画，且抖动值显式归零（离开即复位）。
    expect(_state(tester).debugJittering, isFalse);
    expect(_state(tester).debugJitter, (0.0, 0.0, 0.0));
  });

  test('fxHash01：确定性伪随机（同输入同输出、通道间解耦、落在 [0,1)）', () {
    for (int a = 0; a < 8; a++) {
      for (int b = 0; b < 8; b++) {
        final double v = fxHash01(a, b);
        expect(v, greaterThanOrEqualTo(0));
        expect(v, lessThan(1));
        expect(fxHash01(a, b), v); // 确定性
        expect(fxHash01(a + 1, b), isNot(v)); // 步号扰动
        expect(fxHash01(a, b + 1), isNot(v)); // 通道扰动
      }
    }
  });
}
