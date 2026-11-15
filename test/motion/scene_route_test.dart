import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:aquan_duanju/theme/app_metrics.dart';
import 'package:aquan_duanju/widgets/motion/scene_route.dart';

void main() {
  group('cross-lines 几何纯函数：0/0.5/1 三帧进度派生', () {
    const Size size = Size(390, 844);
    // 线长 = min(边长, 40% 短边) = 0.4 × 390 = 156。
    const double lineLength = 156;
    const double cx = 195;
    const double cy = 422;

    test('p=0（close=0）：四线压在四边', () {
      final lines = fxSceneCrossLines(size, 0, 0);
      // 返回顺序：横(top)、横(bottom)、竖(left)、竖(right)。
      expect(lines[0].$1.dy, 0);
      expect(lines[1].$1.dy, size.height);
      expect(lines[2].$1.dx, 0);
      expect(lines[3].$1.dx, size.width);
      // 线长固定：水平线沿 x 居中展开 156。
      expect(lines[0].$1.dx, cx - lineLength / 2);
      expect(lines[0].$2.dx, cx + lineLength / 2);
    });

    test('p=0.5（close=1, open=0）：四线交于屏幕中心成十字', () {
      final lines = fxSceneCrossLines(size, 1, 0);
      expect(lines[0].$1.dy, cy);
      expect(lines[1].$1.dy, cy);
      expect(lines[2].$1.dx, cx);
      expect(lines[3].$1.dx, cx);
    });

    test('p=1（open=1）：穿透到对边（越界出屏）', () {
      final lines = fxSceneCrossLines(size, 1, 1);
      expect(lines[0].$1.dy, size.height, reason: '上线从顶边穿到底边');
      expect(lines[1].$1.dy, 0);
      expect(lines[2].$1.dx, size.width);
      expect(lines[3].$1.dx, 0);
    });
  });

  testWidgets('push 后当前路由是 FxSceneRoute，三段转场无异常，pop 反放', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Center(
            child: TextButton(
              onPressed: () {
                Navigator.of(context).push(
                  FxSceneRoute<void>(
                    builder: (_) =>
                        const Scaffold(body: Center(child: Text('播放器'))),
                  ),
                );
              },
              child: const Text('go'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('go'));
    await tester.pump(); // 路由安装（push 目标页在这一拍之后才入树）
    await tester.pump(); // 转场第一帧
    final ModalRoute<Object?> route = ModalRoute.of(
      tester.element(find.text('播放器')),
    )!;
    expect(route, isA<FxSceneRoute>(), reason: '详情接线必须是编排转场路由');
    // pop 反放对称：reverse 与 forward 同长（close + open）。
    expect(
      route.transitionDuration,
      AppMetrics.standard.fxSceneClose + AppMetrics.standard.fxSceneOpen,
    );
    expect(route.reverseTransitionDuration, route.transitionDuration);

    // 转场进行中有画线 painter（私有类按 runtimeType 断言）。
    expect(
      find.byWidgetPredicate(
        (w) =>
            w is CustomPaint &&
            w.painter != null &&
            w.painter!.runtimeType.toString() == '_CrossLinesPainter',
      ),
      findsOneWidget,
    );

    await tester.pump(const Duration(milliseconds: 480)); // close→open 边界
    await tester.pump(const Duration(milliseconds: 520)); // 完成
    await tester.pumpAndSettle();
    expect(find.text('播放器'), findsOneWidget);

    // pop：同一路径反放（1000ms），落回原页无异常。
    tester.state<NavigatorState>(find.byType(Navigator)).pop();
    await tester.pumpAndSettle();
    expect(find.text('go'), findsOneWidget);
    expect(find.text('播放器'), findsNothing);
  });

  test('detail_screen._play：reduceMotion 分流（结构断言，detail 装配过重）', () {
    // 沿用 hero_tag_test 的降级口径：详情页依赖 AppScope 全家桶，widget 级
    // 装配过重；这里断言 _play 的分流结构。
    final String source = File('lib/screens/detail_screen.dart')
        .readAsStringSync();

    expect(
      source,
      contains("import '../widgets/motion/scene_route.dart';"),
      reason: 'FxSceneRoute 已接线进详情页',
    );
    expect(
      source,
      contains('AppMetrics.reduceMotionEnabled(context)'),
      reason: 'reduceMotion 由调用方（_play）分流',
    );
    expect(
      RegExp(r'reduceMotion\s*\?\s*MaterialPageRoute<void>\(').hasMatch(source),
      isTrue,
      reason: 'reduceMotion 走默认转场',
    );
    expect(
      RegExp(r'FxSceneRoute<void>\(').hasMatch(source),
      isTrue,
      reason: '非 reduceMotion 走裁切线编排转场',
    );
    // 接线点只有 _play 一处（downloads/其他 PlayerScreen push 点本批不动）。
    expect(RegExp(r'FxSceneRoute<void>\(').allMatches(source), hasLength(1));
  });
}
