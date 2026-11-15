import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:aquan_duanju/widgets/motion/masthead_title.dart';

Widget _host(ScrollController controller, {bool disableAnimations = false}) =>
    MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(disableAnimations: disableAnimations),
        child: Scaffold(
          body: CustomScrollView(
            controller: controller,
            slivers: [
              SliverAppBar(
                pinned: true,
                title: FxMastheadTitle(
                  scrollController: controller,
                  title: '剧名标题',
                ),
              ),
              SliverToBoxAdapter(
                child: Container(height: 1000, color: Colors.white),
              ),
            ],
          ),
        ),
      ),
    );

/// FxMastheadTitle 内层 ClipRect 的裁切宽（揭示进度的观察口）。
double _clipWidth(WidgetTester tester) {
  final RenderClipRect clip = tester.renderObject<RenderClipRect>(
    find.descendant(
      of: find.byType(FxMastheadTitle),
      matching: find.byType(ClipRect),
    ),
  );
  return (clip.clipper! as dynamic).getClip(clip.size).width as double;
}

void main() {
  group('fxMastheadProgress（单 progress 派生）', () {
    test('offset 0 → p 0', () {
      expect(fxMastheadProgress(0, 180), 0);
    });

    test('offset 达阈值 → p 1；超出夹取 1', () {
      expect(fxMastheadProgress(180, 180), 1);
      expect(fxMastheadProgress(1000, 180), 1);
    });

    test('中途线性推进', () {
      expect(fxMastheadProgress(90, 180), closeTo(0.5, 1e-9));
    });

    test('threshold <= 0 直接全显', () {
      expect(fxMastheadProgress(0, 0), 1);
      expect(fxMastheadProgress(-5, 0), 1);
    });
  });

  group('widget 裁切揭示', () {
    testWidgets('p=0 零宽裁切但布局占位稳定；滚过阈值全显', (tester) async {
      final ScrollController controller = ScrollController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(_host(controller));
      await tester.pumpAndSettle();

      // 页顶：p=0 → 裁切宽 0（不可见），但组件布局尺寸保持 Text 原宽。
      expect(_clipWidth(tester), 0);
      final Size topSize = tester.getSize(find.byType(FxMastheadTitle));

      // 滚过阈值（180）→ 全显：裁切宽 = 组件宽。
      controller.jumpTo(260);
      await tester.pumpAndSettle();
      final double fullClipWidth = _clipWidth(tester);
      expect(fullClipWidth, greaterThan(0));
      final Size scrolledSize = tester.getSize(find.byType(FxMastheadTitle));
      expect(
        scrolledSize.width,
        topSize.width,
        reason: 'p=0 占位宽度保持（AppBar 布局不跳）',
      );
      expect(fullClipWidth, closeTo(scrolledSize.width, 0.5));
    });

    testWidgets('反向滚动收回：回到顶部裁切归零', (tester) async {
      final ScrollController controller = ScrollController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(_host(controller));
      await tester.pumpAndSettle();

      controller.jumpTo(260);
      await tester.pumpAndSettle();
      expect(_clipWidth(tester), greaterThan(0));

      controller.jumpTo(0);
      await tester.pumpAndSettle();
      expect(_clipWidth(tester), 0);
    });

    testWidgets('reduceMotion：p 恒 1，页顶也全显（AC20 条件分支）', (tester) async {
      final ScrollController controller = ScrollController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(_host(controller, disableAnimations: true));
      await tester.pumpAndSettle();

      expect(_clipWidth(tester), greaterThan(0), reason: 'reduceMotion 静态全显');
      expect(
        _clipWidth(tester),
        closeTo(tester.getSize(find.byType(FxMastheadTitle)).width, 0.5),
      );
    });

    testWidgets('无滚动 client（hasClients=false）：不读 offset，直接全显', (tester) async {
      // 未接任何滚动视口的 controller：路由/过渡期不读 offset 不炸。
      final ScrollController detached = ScrollController();
      addTearDown(detached.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: FxMastheadTitle(scrollController: detached, title: '剧名标题'),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('剧名标题'), findsOneWidget);
    });
  });
}
