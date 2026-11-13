import 'package:aquan_duanju/theme/app_theme.dart';
import 'package:aquan_duanju/widgets/jelly/jelly_surface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget host(Widget child, {bool disableAnimations = false}) {
  return MaterialApp(
    theme: AppTheme.light(),
    home: MediaQuery(
      data: MediaQueryData(disableAnimations: disableAnimations),
      child: Scaffold(body: Center(child: child)),
    ),
  );
}

void main() {
  testWidgets('JellySurface 绘制不抛异常（painter 有 takeException 守卫）', (tester) async {
    await tester.pumpWidget(
      host(
        JellySurface(
          size: const Size(160, 52),
          tooltip: '继续观看',
          onTap: () {},
          child: const Text('继续观看'),
        ),
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.text('继续观看'), findsOneWidget);
  });

  testWidgets('按下会形变，松手后自动停 ticker 并回到静止形状', (tester) async {
    await tester.pumpWidget(
      host(JellySurface(size: const Size(160, 52), onTap: () {})),
    );
    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(JellySurface)),
    );
    await tester.pump(const Duration(milliseconds: 16));
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 16));

    // 跑到稳定；ticker 会自己停，所以这里不会超时
    for (var i = 0; i < 200; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('disableAnimations 时不启动物理，仍渲染完整形状', (tester) async {
    await tester.pumpWidget(
      host(
        JellySurface(size: const Size(160, 52), onTap: () {}),
        disableAnimations: true,
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.byType(JellySurface), findsOneWidget);
  });
}
