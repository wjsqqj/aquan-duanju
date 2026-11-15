import 'package:aquan_duanju/theme/app_theme.dart';
import 'package:aquan_duanju/widgets/ui/stage_blobs.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _host({bool dark = false, bool disableAnimations = false}) {
  return MaterialApp(
    theme: dark ? AppTheme.dark() : AppTheme.light(),
    home: MediaQuery(
      data: MediaQueryData(disableAnimations: disableAnimations),
      child: StageBlobs(dark: dark),
    ),
  );
}

/// 4 团光斑的基色 alpha（RadialGradient 首色；树序稳定 = blob 1..4，
/// 与 stage_blobs.dart 的 _blob 调用顺序一致）。
List<double> _blobAlphas(WidgetTester tester) {
  return tester
      .widgetList<Container>(
        find.descendant(
          of: find.byType(StageBlobs),
          matching: find.byType(Container),
        ),
      )
      .map((Container container) {
        final BoxDecoration decoration = container.decoration! as BoxDecoration;
        return (decoration.gradient! as RadialGradient).colors.first.a;
      })
      .toList();
}

/// ramp 走满后的全量基色 alpha：浅色 (dark?X:Y)·0.55 / 深色 ·1.0。
const List<double> _lightFullAlphas = <double>[
  0.10 * 0.55,
  0.08 * 0.55,
  0.16 * 0.55,
  0.06 * 0.55,
];
const List<double> _darkFullAlphas = <double>[0.22, 0.16, 0.10, 0.12];

void main() {
  testWidgets('挂载淡入：首帧 alpha≈0 → easeOutCubic 推进 → 1.2s 后全量', (tester) async {
    await tester.pumpWidget(_host());
    await tester.pump();
    // 首帧：ticker 尚未真正 tick（elapsed 恒 0）→ ramp=0 → 全透明起点；
    // 且挂表恰 1 个（26s repeat ticker，无新 Timer/Controller）。
    expect(
      _blobAlphas(tester),
      everyElement(moreOrLessEquals(0, epsilon: 0.001)),
    );
    expect(tester.binding.transientCallbackCount, 1);

    // 300ms：easeOutCubic(0.25)≈0.6——已显影但未全量。上界排除「无 ramp
    // 恒全量」，下界排除线性（0.25）与钉 0。
    await tester.pump(const Duration(milliseconds: 300));
    final List<double> mid = _blobAlphas(tester);
    for (int i = 0; i < mid.length; i++) {
      expect(mid[i], greaterThan(_lightFullAlphas[i] * 0.4));
      expect(mid[i], lessThan(_lightFullAlphas[i] * 0.8));
    }

    // 累计 1.3s > 1.2s：ramp 走满 → 全量基色 alpha。
    await tester.pump(const Duration(milliseconds: 1000));
    final List<double> full = _blobAlphas(tester);
    for (int i = 0; i < full.length; i++) {
      expect(full[i], moreOrLessEquals(_lightFullAlphas[i], epsilon: 0.002));
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('reduceMotion：静态渲染绕过 ramp 直接全量（防钉 0 永久隐身）', (tester) async {
    await tester.pumpWidget(_host(dark: true, disableAnimations: true));
    await tester.pump();
    // 红线断言：首帧即全量基色 alpha——若 ramp 误入静态分支，这里会是 0
    // （elapsed 恒空 → ramp 钉 0 → 永久隐身事故）。
    final List<double> first = _blobAlphas(tester);
    for (int i = 0; i < first.length; i++) {
      expect(first[i], moreOrLessEquals(_darkFullAlphas[i], epsilon: 0.002));
    }
    expect(tester.binding.transientCallbackCount, 0);
    // 持续静止：帧间 alpha 恒定、无动画挂表。
    await tester.pump(const Duration(seconds: 2));
    expect(_blobAlphas(tester), first);
    expect(tester.binding.transientCallbackCount, 0);
    expect(tester.takeException(), isNull);
  });
}
