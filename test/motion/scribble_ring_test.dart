import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter/gestures.dart';

import 'package:aquan_duanju/models/models.dart';
import 'package:aquan_duanju/widgets/common.dart';
import 'package:aquan_duanju/widgets/motion/scribble_ring.dart';

Widget _host({required bool show, bool disableAnimations = false}) =>
    MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(disableAnimations: disableAnimations),
        child: Scaffold(
          body: Center(
            child: FxScribbleBadge(
              show: show,
              child: Container(
                width: 64,
                height: 22,
                alignment: Alignment.center,
                color: const Color(0x11223344),
                child: const Text('今日更新'),
              ),
            ),
          ),
        ),
      ),
    );

dynamic _state(WidgetTester tester) =>
    tester.state(find.byType(FxScribbleBadge));

ScribbleRingPainter? _painter(WidgetTester tester) {
  final List<CustomPaint> paints = tester
      .widgetList<CustomPaint>(find.byType(CustomPaint))
      .where((CustomPaint p) => p.painter is ScribbleRingPainter)
      .toList();
  return paints.isEmpty ? null : paints.first.painter as ScribbleRingPainter;
}

void main() {
  group('纯几何（fxScribble*）', () {
    test('可见度曲线：0 → 35%/65%/88% → 全显（design §5 公式）', () {
      expect(fxScribbleVisibility(0), 0);
      expect(fxScribbleVisibility(1), closeTo(0.35, 0.01));
      expect(fxScribbleVisibility(2), closeTo(0.65, 0.01));
      expect(fxScribbleVisibility(3), closeTo(0.88, 0.01));
      expect(fxScribbleVisibility(4), 1);
      expect(fxScribbleVisibility(9), 1); // 保持期封顶
    });

    test('沸腾结点：16 结点、确定性重随机（同 tick 同形、跨 tick 变形）', () {
      const Size size = Size(64, 22);
      final List<Offset> t0 = fxScribbleNodes(size, 0);
      expect(t0, hasLength(kScribbleNodes));
      expect(fxScribbleNodes(size, 0), t0); // 确定性
      expect(fxScribbleNodes(size, 1), isNot(equals(t0))); // 沸腾

      // 不闭合弧：首末结点绕环心的极角跨度远小于整圆（留缺口）。
      // 椭圆极角 ≠ 参数角，按区间断言（约 74%·360° 落在 60%..90% 内）。
      final Offset center = size.center(Offset.zero);
      double angle(Offset p) => math.atan2(p.dy - center.dy, p.dx - center.dx);
      double a0 = angle(t0.first);
      double a1 = angle(t0.last);
      final double span = (a1 - a0) + (a1 < a0 ? 2 * math.pi : 0);
      expect(span, greaterThan(2 * math.pi * 0.6));
      expect(span, lessThan(2 * math.pi * 0.9));
    });

    test('变宽笔迹 ribbon：visibility=0 空路径；越界外扩（fit 1.18）生效', () {
      const Size size = Size(64, 22);
      expect(fxScribbleRibbon(size, 0, 0).getBounds().isEmpty, isTrue);

      final Rect bounds = fxScribbleRibbon(size, 3, 1).getBounds();
      // 环比 child 大：右缘/上下越出 child 边界（74% 扫角，左缘不出界）。
      expect(bounds.width, greaterThan(size.width));
      expect(bounds.height, greaterThan(size.height));
      expect(bounds.right, greaterThan(size.width));
      expect(bounds.top, lessThan(0));
      // 画入进度截取：进度越小轮廓越窄（起笔钝头先出现）。
      final Rect partial = fxScribbleRibbon(size, 3, 0.4).getBounds();
      expect(partial.width, lessThan(bounds.width));
    });
  });

  testWidgets('show=false（从未 hover）：直通 child，零开销（无 Timer/painter）', (
    tester,
  ) async {
    await tester.pumpWidget(_host(show: false));
    expect(_state(tester).debugTicking, isFalse);
    expect(_painter(tester), isNull);
    expect(find.text('今日更新'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 500));
    expect(_state(tester).debugTicking, isFalse); // 时钟从未启动
  });

  testWidgets('show=true：10fps 步进画入（100ms 一跳）→ 保持期沸腾', (tester) async {
    await tester.pumpWidget(_host(show: true));
    expect(_state(tester).debugTicking, isTrue);
    // tick 0：可见度 0（无 painter 画内容——painter 在但可见度 0）。
    expect(fxScribbleVisibility(_state(tester).debugTick as int), 0);

    await tester.pump(kScribbleTickPeriod);
    expect(_state(tester).debugTick, 1);
    expect(_painter(tester)!.visibility, closeTo(0.35, 0.01));

    await tester.pump(kScribbleTickPeriod * 3);
    expect(_painter(tester)!.visibility, 1);

    // 保持期沸腾：继续 tick，可见度封顶 1，tick 递增换新随机相位。
    final int tickBefore = _state(tester).debugTick as int;
    await tester.pump(kScribbleTickPeriod);
    expect(_state(tester).debugTick, tickBefore + 1);
    expect(_painter(tester)!.visibility, 1);
  });

  testWidgets('show 翻 false：逐 tick 擦除，擦完停钟直通 child', (tester) async {
    await tester.pumpWidget(_host(show: true));
    await tester.pump(kScribbleTickPeriod * 5);
    expect(_painter(tester)!.visibility, 1);

    await tester.pumpWidget(_host(show: false));
    expect(_state(tester).debugErasing, isTrue);

    await tester.pump(kScribbleTickPeriod);
    expect(_painter(tester)!.visibility, closeTo(0.88, 0.01)); // 4→3
    await tester.pump(kScribbleTickPeriod);
    expect(_painter(tester)!.visibility, closeTo(0.65, 0.01)); // 3→2
    await tester.pump(kScribbleTickPeriod * 3);
    // 擦完：停钟，child 直通（无 painter、无 Timer）。
    expect(_state(tester).debugTicking, isFalse);
    expect(_painter(tester), isNull);
    expect(find.text('今日更新'), findsOneWidget);
  });

  group('SeriesCard 桌面 hover 接线门控（_hoverScribble）', () {
    Widget cardHost({
      TargetPlatform platform = TargetPlatform.android,
      bool disableAnimations = false,
      bool tvFocus = false,
    }) => MaterialApp(
      theme: ThemeData(platform: platform),
      home: MediaQuery(
        data: MediaQueryData(disableAnimations: disableAnimations),
        child: Scaffold(
          body: Center(
            child: SizedBox(
              width: 180,
              height: 300,
              child: SeriesCard(
                item: const SeriesSummary(
                  id: 'e4-1',
                  title: '圈注卡',
                  tags: <String>['古装'],
                ),
                badge: '今日更新',
                onTap: () {},
                tvFocus: tvFocus,
              ),
            ),
          ),
        ),
      ),
    );

    Future<TestGesture> hoverCard(WidgetTester tester, Offset location) async {
      final TestGesture gesture = await tester.createGesture(
        kind: PointerDeviceKind.mouse,
      );
      await gesture.addPointer(location: Offset.zero);
      await gesture.moveTo(location);
      addTearDown(gesture.removePointer);
      return gesture;
    }

    testWidgets('移动端（默认 android）：不挂 FxScribbleBadge（零开销）', (tester) async {
      await tester.pumpWidget(cardHost());
      await tester.pumpAndSettle();
      expect(find.text('今日更新'), findsOneWidget);
      expect(find.byType(FxScribbleBadge), findsNothing);
    });

    testWidgets('reduceMotion（桌面）：不挂 FxScribbleBadge（AC20）', (tester) async {
      await tester.pumpWidget(
        cardHost(platform: TargetPlatform.windows, disableAnimations: true),
      );
      await tester.pumpAndSettle();
      expect(find.byType(FxScribbleBadge), findsNothing);
    });

    testWidgets('TV 分支（tvFocus）：不挂 FxScribbleBadge', (tester) async {
      await tester.pumpWidget(
        cardHost(platform: TargetPlatform.windows, tvFocus: true),
      );
      await tester.pumpAndSettle();
      expect(find.byType(FxScribbleBadge), findsNothing);
    });

    testWidgets('桌面 hover：挂 FxScribbleBadge，hover 卡片起沸腾', (tester) async {
      await tester.pumpWidget(cardHost(platform: TargetPlatform.windows));
      await tester.pumpAndSettle();
      expect(find.byType(FxScribbleBadge), findsOneWidget);
      expect(_state(tester).debugTicking, isFalse); // 非 hover 期零开销

      await hoverCard(tester, tester.getCenter(find.byType(SeriesCard)));
      await tester.pump();
      expect(_state(tester).debugTicking, isTrue); // 时钟只在 hover 期运行

      await tester.pump(kScribbleTickPeriod);
      expect(_painter(tester)!.visibility, closeTo(0.35, 0.01)); // 画入首跳
    });
  });
}
