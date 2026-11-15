import 'dart:math' as math;

import 'package:flutter/widgets.dart'
    show
        Directionality,
        MediaQuery,
        MediaQueryData,
        Offset,
        PathFillType,
        Size,
        SizedBox,
        Text,
        TextDirection,
        Widget;
import 'package:flutter_test/flutter_test.dart';

import 'package:aquan_duanju/core/reader/reader_settings.dart';
import 'package:aquan_duanju/widgets/motion/dissolve_painter.dart';
import 'package:aquan_duanju/widgets/reader/reader_pager.dart';

const _page = Size(420, 820);

void main() {
  group('buildDissolveLoops（纯算法）', () {
    test('progress=0 退化：不吃任何区域（无环）', () {
      final loops = buildDissolveLoops(
        progress: 0,
        phase: 0,
        size: _page,
        fromTop: false,
      );
      expect(loops, isEmpty);
    });

    test('progress=1 退化：整页吃光（单环覆盖全页）', () {
      final loops = buildDissolveLoops(
        progress: 1,
        phase: 0,
        size: _page,
        fromTop: false,
      );
      expect(loops.length, 1);
      final xs = loops[0].map((p) => p.dx);
      final ys = loops[0].map((p) => p.dy);
      expect(xs.reduce(math.min), lessThanOrEqualTo(0));
      expect(ys.reduce(math.min), lessThanOrEqualTo(0));
      expect(xs.reduce(math.max), greaterThanOrEqualTo(_page.width));
      expect(ys.reduce(math.max), greaterThanOrEqualTo(_page.height));
    });

    test('环闭合性：相邻顶点间距不超网格对角（链条无断点）', () {
      final loops = buildDissolveLoops(
        progress: 0.5,
        phase: 13.7,
        size: _page,
        fromTop: false,
      );
      expect(loops, isNotEmpty);
      final g = kDissolveGridSize * 3;
      for (final loop in loops) {
        expect(loop.length, greaterThanOrEqualTo(3));
        for (var i = 0; i < loop.length; i++) {
          final a = loop[i];
          final b = loop[(i + 1) % loop.length];
          final d = (a - b).distance;
          expect(d, lessThan(g), reason: '链断裂会产生远超网格步长的跳点');
        }
      }
    });

    test('主环包围盒横贯页宽（外扩 padding 闭合，evenOdd 裁剪前提）', () {
      final loops = buildDissolveLoops(
        progress: 0.4,
        phase: 0,
        size: _page,
        fromTop: false,
      );
      // 主环（吃入区）必然横贯全宽：minX/maxX 覆盖页宽。
      final xs = loops.expand((l) => l.map((p) => p.dx));
      expect(
        xs.reduce(math.max) - xs.reduce(math.min),
        greaterThanOrEqualTo(_page.width),
      );
    });

    test('确定性：同输入同环（固定种子）', () {
      final a = buildDissolveLoops(
        progress: 0.37,
        phase: 9,
        size: _page,
        fromTop: false,
      );
      final b = buildDissolveLoops(
        progress: 0.37,
        phase: 9,
        size: _page,
        fromTop: false,
      );
      expect(a.length, b.length);
      for (var i = 0; i < a.length; i++) {
        expect(a[i].length, b[i].length);
        for (var k = 0; k < a[i].length; k++) {
          expect(a[i][k], b[i][k]);
        }
      }
    });

    test('行采样优化成立：15px 网格每帧构建 <2ms（性能预算）', () {
      var total = 0;
      const runs = 60;
      final sw = Stopwatch()..start();
      for (var i = 0; i < runs; i++) {
        final p = (i + 1) / (runs + 1);
        final t0 = Stopwatch()..start();
        buildDissolveLoops(
          progress: p,
          phase: i * 3.0,
          size: _page,
          fromTop: i.isEven,
        );
        t0.stop();
        total += t0.elapsedMicroseconds;
      }
      sw.stop();
      final avgMs = total / runs / 1000;
      expect(
        avgMs,
        lessThan(2.0),
        reason: '低端机按 3-5x 折算；桌面均值 $avgMs ms 必须远低于 2ms 预算',
      );
    });
  });

  group('buildDissolvePath（evenOdd 裁剪语义）', () {
    test('progress=0：路径即页矩形（全保留）', () {
      final path = buildDissolvePath(
        progress: 0,
        phase: 0,
        size: _page,
        fromTop: false,
      );
      expect(path.contains(Offset(_page.width / 2, 10)), isTrue);
      expect(path.contains(Offset(_page.width / 2, _page.height - 10)), isTrue);
    });

    test('progress=1：整页剪光', () {
      final path = buildDissolvePath(
        progress: 1,
        phase: 0,
        size: _page,
        fromTop: false,
      );
      expect(path.fillType, PathFillType.evenOdd);
      expect(path.contains(Offset(_page.width / 2, _page.height / 2)), isFalse);
    });

    test('下缘向上吃：上半保留、下半剪掉（中段为毛边过渡带）', () {
      final path = buildDissolvePath(
        progress: 0.5,
        phase: 0,
        size: _page,
        fromTop: false,
      );
      expect(
        path.contains(Offset(_page.width / 2, 10)),
        isTrue,
        reason: '页顶远离过渡带（±32px），必保留',
      );
      expect(
        path.contains(Offset(_page.width / 2, _page.height - 10)),
        isFalse,
        reason: '页底远离过渡带，必剪掉',
      );
    });

    test('上缘向下吃：方向镜像', () {
      final path = buildDissolvePath(
        progress: 0.5,
        phase: 0,
        size: _page,
        fromTop: true,
      );
      expect(
        path.contains(Offset(_page.width / 2, 10)),
        isFalse,
        reason: '上缘向下吃：页顶必剪掉',
      );
      expect(
        path.contains(Offset(_page.width / 2, _page.height - 10)),
        isTrue,
        reason: '页底必保留',
      );
    });

    test('蠕动：相位推进改变毛边（同一 progress 两个相位路径不同）', () {
      final a = buildDissolvePath(
        progress: 0.5,
        phase: 0,
        size: _page,
        fromTop: false,
      );
      final b = buildDissolvePath(
        progress: 0.5,
        phase: 120,
        size: _page,
        fromTop: false,
      );
      // 逐点采样：两相位在过渡带附近的保留集合必有差异（噪声窗平移）。
      var diff = false;
      for (var y = _page.height / 2 - 60; y < _page.height / 2 + 60; y += 3) {
        for (double x = 10; x < _page.width; x += 24) {
          final pt = Offset(x, y);
          if (a.contains(pt) != b.contains(pt)) {
            diff = true;
            break;
          }
        }
        if (diff) break;
      }
      expect(diff, isTrue, reason: '蠕动只在翻动中发生，但相位必须真实改变边缘');
    });
  });

  group('readerTurnFrame 第 7 模式（dissolve）', () {
    test('当前页帧：dissolve=|progress|，方向随翻向（下一页从下缘吃）', () {
      final next = readerTurnFrame(
        progress: -0.6,
        isCurrent: true,
        isPrev: false,
        isNext: false,
        anim: ReaderPageAnim.dissolve,
      );
      expect(next.dissolve, 0.6);
      expect(next.dissolveFromTop, isFalse);
      expect(next.dx, 0);
      expect(next.dim, 0);

      final prev = readerTurnFrame(
        progress: 0.6,
        isCurrent: true,
        isPrev: false,
        isNext: false,
        anim: ReaderPageAnim.dissolve,
      );
      expect(prev.dissolve, 0.6);
      expect(prev.dissolveFromTop, isTrue);
    });

    test('下层（目标）页静置：零位移零透明度差（ dissolved 模式下不参与变换）', () {
      final frame = readerTurnFrame(
        progress: -0.6,
        isCurrent: false,
        isPrev: false,
        isNext: true,
        anim: ReaderPageAnim.dissolve,
      );
      expect(frame.dissolve, 0);
      expect(frame.dx, 0);
      expect(frame.dy, 0);
      expect(frame.opacity, 1);
    });

    test('既有 6 模式帧不受新字段影响（默认 0/false，向后兼容）', () {
      for (final anim in ReaderPageAnim.values) {
        if (anim == ReaderPageAnim.dissolve) continue;
        final frame = readerTurnFrame(
          progress: -0.5,
          isCurrent: true,
          isPrev: false,
          isNext: false,
          anim: anim,
        );
        expect(frame.dissolve, 0, reason: '${anim.name} 不得携带溶解帧');
        expect(frame.dissolveFromTop, isFalse);
      }
    });
  });

  group('reduceMotion 门控（AC20：dissolve 是唯一被门控的新模式）', () {
    Widget host({required bool disableAnimations}) {
      return Directionality(
        textDirection: TextDirection.ltr,
        child: MediaQuery(
          data: MediaQueryData(disableAnimations: disableAnimations),
          child: SizedBox(
            width: _page.width,
            height: _page.height,
            child: ReaderPager(
              pageCount: 3,
              index: 1,
              animation: ReaderPageAnim.dissolve,
              duration: const Duration(milliseconds: 280),
              builder: (_, i) => Text('page$i'),
            ),
          ),
        ),
      );
    }

    Future<TestGesture> dragHalfLeft(WidgetTester tester) async {
      final gesture = await tester.startGesture(
        Offset(_page.width / 2, _page.height / 2),
      );
      await gesture.moveBy(const Offset(-120, 0));
      await tester.pump();
      return gesture;
    }

    testWidgets('常规：拖动中当前页挂 DissolveReveal（毛边吃入）', (tester) async {
      tester.view.physicalSize = _page;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(host(disableAnimations: false));
      final gesture = await dragHalfLeft(tester);
      expect(find.byType(DissolveReveal), findsOneWidget);
      await gesture.up();
      await tester.pumpAndSettle();
    });

    testWidgets('reduceMotion：同一手势退化为 fade，不出现溶解层', (tester) async {
      tester.view.physicalSize = _page;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(host(disableAnimations: true));
      final gesture = await dragHalfLeft(tester);
      expect(find.byType(DissolveReveal), findsNothing);
      expect(find.text('page1'), findsOneWidget, reason: 'fade 仍在渲染当前页');
      await gesture.up();
      await tester.pumpAndSettle();
    });
  });
}
