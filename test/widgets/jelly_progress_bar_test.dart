import 'package:aquan_duanju/theme/app_theme.dart';
import 'package:aquan_duanju/widgets/jelly/jelly_progress_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget host(Widget child, {bool disableAnimations = false}) {
  return MaterialApp(
    theme: AppTheme.light(),
    home: MediaQuery(
      data: MediaQueryData(disableAnimations: disableAnimations),
      child: Scaffold(
        body: Center(child: SizedBox(width: 200, child: child)),
      ),
    ),
  );
}

void main() {
  testWidgets('确定态渲染：Semantics(进度 · 68%)，绘制不抛异常', (tester) async {
    final SemanticsHandle handle = tester.ensureSemantics();
    await tester.pumpWidget(host(const JellyProgressBar(value: 0.68)));
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.byType(JellyProgressBar), findsOneWidget);
    final data = tester
        .getSemantics(find.byType(JellyProgressBar))
        .getSemanticsData();
    expect(data.label, '进度');
    expect(data.value, '68%');
    handle.dispose();
  });

  testWidgets('value 变化经隐式动画过渡，Semantics 目标值立即更新', (tester) async {
    final SemanticsHandle handle = tester.ensureSemantics();
    await tester.pumpWidget(host(const JellyProgressBar(value: 0.2)));
    await tester.pump();

    await tester.pumpWidget(host(const JellyProgressBar(value: 0.9)));
    // hover(150ms) 动画中途：语义值已是目标值 90%
    await tester.pump(const Duration(milliseconds: 40));
    final data = tester
        .getSemantics(find.byType(JellyProgressBar))
        .getSemanticsData();
    expect(data.value, '90%');

    // 动画收尾后无异常
    await tester.pump(const Duration(milliseconds: 160));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    handle.dispose();
  });

  testWidgets('value == null → 不确定态：Semantics(加载中)，虚线动画持续运行', (tester) async {
    final SemanticsHandle handle = tester.ensureSemantics();
    await tester.pumpWidget(host(const JellyProgressBar()));
    await tester.pump();
    // 连续推进两帧：ticker 驱动的左移虚线持续重绘且不抛异常
    await tester.pump(const Duration(milliseconds: 120));
    await tester.pump(const Duration(milliseconds: 120));

    expect(tester.takeException(), isNull);
    final data = tester
        .getSemantics(find.byType(JellyProgressBar))
        .getSemanticsData();
    expect(data.label, '加载中');
    expect(data.value, isEmpty);
    handle.dispose();
  });

  testWidgets('reduceMotion：不确定态停帧（无常驻 ticker，pumpAndSettle 不超时）', (tester) async {
    await tester.pumpWidget(host(
      const JellyProgressBar(),
      disableAnimations: true,
    ));
    await tester.pump();
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.byType(JellyProgressBar), findsOneWidget);
  });

  testWidgets('reduceMotion：确定态瞬时到位（时长归零，无 150ms 过渡）', (tester) async {
    final SemanticsHandle handle = tester.ensureSemantics();
    await tester.pumpWidget(host(
      const JellyProgressBar(value: 0.2),
      disableAnimations: true,
    ));
    await tester.pump();

    await tester.pumpWidget(host(
      const JellyProgressBar(value: 0.9),
      disableAnimations: true,
    ));
    // 时长为 0：下一帧即到位
    await tester.pump(const Duration(milliseconds: 1));
    final data = tester
        .getSemantics(find.byType(JellyProgressBar))
        .getSemanticsData();
    expect(data.value, '90%');
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    handle.dispose();
  });

  testWidgets('不确定 ↔ 确定态切换（下载任务 0 字节起步场景）不抛异常', (tester) async {
    await tester.pumpWidget(host(
      const JellyProgressBar(value: 0.0),
    ));
    await tester.pump();

    // 进度未知（0 字节）→ 不确定态
    await tester.pumpWidget(host(const JellyProgressBar()));
    await tester.pump(const Duration(milliseconds: 50));
    // 拿到首块字节 → 确定态
    await tester.pumpWidget(host(const JellyProgressBar(value: 0.35)));
    await tester.pump(const Duration(milliseconds: 160));

    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
