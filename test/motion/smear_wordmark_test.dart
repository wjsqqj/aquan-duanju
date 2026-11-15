import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:aquan_duanju/widgets/motion/smear_wordmark.dart';

Widget _host(Widget child, {bool disableAnimations = false}) => MaterialApp(
  home: MediaQuery(
    data: MediaQueryData(disableAnimations: disableAnimations),
    child: Scaffold(body: Center(child: child)),
  ),
);

const TextStyle _style = TextStyle(
  fontSize: 28,
  fontWeight: FontWeight.w600,
  color: Color(0xFF111111),
);

dynamic _state(WidgetTester tester) =>
    tester.state(find.byType(FxSmearWordmark));

void main() {
  test('歪斜五次幂缓动：端点/值域/单调/前段慢爬/硬启动/长着陆', () {
    expect(fxSmearSkewEase(0), 0);
    expect(fxSmearSkewEase(1), 1);
    expect(fxSmearSkewEase(-0.5), 0);
    expect(fxSmearSkewEase(1.5), 1);
    // 单调递增（分段幂函数，无跳变）。
    double prev = -1;
    for (int i = 0; i <= 100; i++) {
      final double v = fxSmearSkewEase(i / 100);
      expect(v, greaterThanOrEqualTo(prev));
      prev = v;
    }
    // 前段慢爬：t=0.2 才走了 ~1.5%（开局贴地）。
    expect(fxSmearSkewEase(0.2), lessThan(0.05));
    // 硬启动：t=0.5 已越过 0.75（K 转折后猛窜）。
    expect(fxSmearSkewEase(0.5), greaterThan(0.75));
    // 长着陆：t=0.9 已到 0.99+（五次幂长尾）。
    expect(fxSmearSkewEase(0.9), greaterThan(0.99));
  });

  test('歪斜缓动在 K=0.38 转折处连续（值与一阶导）', () {
    final double k = fxSmearSkewK;
    expect(k, 0.38);
    // C0：K 两侧逼近同值 ≈ K。
    final double fLeft = fxSmearSkewEase(k - 1e-6);
    final double fAt = fxSmearSkewEase(k);
    final double fRight = fxSmearSkewEase(k + 1e-6);
    expect((fLeft - fAt).abs(), lessThan(1e-4));
    expect((fAt - fRight).abs(), lessThan(1e-4));
    expect(fAt, moreOrLessEquals(k, epsilon: 1e-9));
    // C1：K 两侧差商同为 ~5（无速度跳变）。
    const double h = 1e-4;
    final double slopeLeft = (fAt - fxSmearSkewEase(k - h)) / h;
    final double slopeRight = (fxSmearSkewEase(k + h) - fAt) / h;
    expect((slopeLeft - slopeRight).abs(), lessThan(0.5));
  });

  test(
    '残影公式与 atlas 常量：22/36 枚、回看 560/800ms、(i/n)^1.7 聚拢、base·(1−i/n)^1.5 衰减',
    () {
      expect(fxSmearSweep, const Duration(milliseconds: 1650));
      expect(fxSmearSweepCompact, const Duration(milliseconds: 1100));
      expect(fxSmearHeadGhosts, 22);
      expect(fxSmearHeadLookback, const Duration(milliseconds: 560));
      expect(fxSmearTailGhosts, 36);
      expect(fxSmearTailLookback, const Duration(milliseconds: 800));
      // 聚拢：小 i 贴字母（明显小于线性间距）。
      expect(
        fxSmearGhostOffsetRatio(1, 22),
        moreOrLessEquals(math.pow(1 / 22, 1.7).toDouble(), epsilon: 1e-12),
      );
      expect(fxSmearGhostOffsetRatio(1, 22), lessThan(1 / 22));
      expect(fxSmearGhostOffsetRatio(22, 22), 1);
      expect(fxSmearGhostOffsetRatio(36, 36), 1);
      // 衰减：首枚最浓（< base）、末枚 0。
      expect(
        fxSmearGhostAlphaAt(1, 22),
        moreOrLessEquals(
          fxSmearGhostAlpha * math.pow(21 / 22, 1.5).toDouble(),
          epsilon: 1e-12,
        ),
      );
      expect(fxSmearGhostAlphaAt(1, 22), lessThan(fxSmearGhostAlpha));
      expect(fxSmearGhostAlphaAt(22, 22), 0);
      expect(fxSmearGhostAlphaAt(36, 36), 0);
    },
  );

  testWidgets('甩入→落定切普通 Text：动效期绘制、外框尺寸一致、落定后零动画', (tester) async {
    await tester.pumpWidget(
      _host(const FxSmearWordmark(text: '阿圈短剧', style: _style)),
    );
    expect(_state(tester).debugAnimated as bool, isTrue);
    expect(tester.binding.transientCallbackCount, greaterThanOrEqualTo(1));
    // 动效期：painter 绘制（无整行 Text 节点，语义走 Semantics label）。
    expect(
      find.descendant(
        of: find.byType(FxSmearWordmark),
        matching: find.byType(CustomPaint),
      ),
      findsOneWidget,
    );
    expect(find.text('阿圈短剧'), findsNothing);
    final Size animatedBox = tester.getSize(find.byType(FxSmearWordmark));

    // 落定（>1100ms）：切普通 Text，外框尺寸与动效期一致（零跳动）。
    await tester.pump(const Duration(milliseconds: 1200));
    expect(_state(tester).debugAnimated as bool, isFalse);
    expect(
      find.descendant(
        of: find.byType(FxSmearWordmark),
        matching: find.byType(CustomPaint),
      ),
      findsNothing,
    );
    expect(find.text('阿圈短剧'), findsOneWidget);
    expect(tester.binding.transientCallbackCount, 0);
    final Size settledBox = tester.getSize(find.byType(FxSmearWordmark));
    expect(settledBox.width, moreOrLessEquals(animatedBox.width, epsilon: 0.1));
    expect(
      settledBox.height,
      moreOrLessEquals(animatedBox.height, epsilon: 0.1),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('reduceMotion：不装 controller，静态直出 wordmark', (tester) async {
    await tester.pumpWidget(
      _host(
        const FxSmearWordmark(text: '阿圈短剧', style: _style),
        disableAnimations: true,
      ),
    );
    await tester.pump();
    expect(
      find.descendant(
        of: find.byType(FxSmearWordmark),
        matching: find.byType(CustomPaint),
      ),
      findsNothing,
    );
    expect(find.text('阿圈短剧'), findsOneWidget);
    expect(tester.binding.transientCallbackCount, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('文本变更不重播（启动页一次性）：落定后换文本仍静态', (tester) async {
    await tester.pumpWidget(
      _host(const FxSmearWordmark(text: '阿圈短剧', style: _style)),
    );
    await tester.pump(const Duration(milliseconds: 1200));
    expect(tester.binding.transientCallbackCount, 0);
    await tester.pumpWidget(
      _host(const FxSmearWordmark(text: '阿圈短剧上线', style: _style)),
    );
    await tester.pump();
    expect(find.text('阿圈短剧上线'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(FxSmearWordmark),
        matching: find.byType(CustomPaint),
      ),
      findsNothing,
    );
    await tester.pump(const Duration(milliseconds: 500));
    expect(tester.binding.transientCallbackCount, 0);
    expect(tester.takeException(), isNull);
  });
}
