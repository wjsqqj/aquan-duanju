import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:aquan_duanju/theme/app_metrics.dart';
import 'package:aquan_duanju/widgets/motion/chapter_map.dart';

/// 三章、权重 1/1/2：条带高 600 时章带为 [0,150]/[150,300]/[300,600]。
const _weights = <double>[1, 1, 2];
const _stripH = 600.0;

Widget _host({
  required ValueNotifier<FxMapPosition> position,
  required ValueChanged<int> onTap,
  bool reduceMotion = false,
  double logicalWidth = 800,
}) {
  return Directionality(
    textDirection: TextDirection.ltr,
    child: MediaQuery(
      data: MediaQueryData(
        size: Size(logicalWidth, 800),
        disableAnimations: reduceMotion,
      ),
      child: Align(
        alignment: Alignment.centerRight,
        child: SizedBox(
          height: _stripH,
          child: FxChapterMap(
            weights: _weights,
            position: position,
            onChapterTap: onTap,
          ),
        ),
      ),
    ),
  );
}

void main() {
  group('分段线性映射（纯函数）', () {
    test('章带边界：单位区间 [0,1][1,2][2,4] 线性映到 [0,150][150,300][300,600]', () {
      expect(fxMapStripY(weights: _weights, unit: 0, stripHeight: _stripH), 0);
      expect(
        fxMapStripY(weights: _weights, unit: 1, stripHeight: _stripH),
        150,
      );
      expect(
        fxMapStripY(weights: _weights, unit: 2, stripHeight: _stripH),
        300,
      );
      expect(
        fxMapStripY(weights: _weights, unit: 4, stripHeight: _stripH),
        600,
      );
      // 章内中点：unit 3.0（第 3 章走到一半）→ 450。
      expect(
        fxMapStripY(weights: _weights, unit: 3, stripHeight: _stripH),
        450,
      );
    });

    test('章内比例 → 单位：ratio 按本章权重插值', () {
      expect(fxMapUnitOf(0, 0.5, _weights), 0.5);
      expect(fxMapUnitOf(1, 0.5, _weights), 1.5);
      expect(fxMapUnitOf(2, 0.5, _weights), 3.0);
    });

    test('逆映射往返：stripY → unit → stripY 恒等（容差内）', () {
      for (final y in <double>[0, 40, 150, 260, 300, 480, 600]) {
        final unit = fxMapUnitAt(
          weights: _weights,
          stripY: y,
          stripHeight: _stripH,
        );
        final back = fxMapStripY(
          weights: _weights,
          unit: unit,
          stripHeight: _stripH,
        );
        expect(back, closeTo(y, 1e-6), reason: 'y=$y 往返必须一致');
      }
    });

    test('点击命中：条带 y → 章下标（跳章目标值）', () {
      expect(
        fxMapChapterAt(weights: _weights, stripY: 75, stripHeight: _stripH),
        0,
      );
      expect(
        fxMapChapterAt(weights: _weights, stripY: 200, stripHeight: _stripH),
        1,
      );
      expect(
        fxMapChapterAt(weights: _weights, stripY: 450, stripHeight: _stripH),
        2,
      );
      // 越界 clamp 到首/尾章，绝不返回 -1。
      expect(
        fxMapChapterAt(weights: _weights, stripY: -50, stripHeight: _stripH),
        0,
      );
      expect(
        fxMapChapterAt(weights: _weights, stripY: 900, stripHeight: _stripH),
        2,
      );
    });

    test('坏权重兜底：空表/非正权重不崩不除零', () {
      // 空表归一成单章带：unit 1 = 带末 → 条带底。
      expect(
        fxMapStripY(weights: const <double>[], unit: 1, stripHeight: _stripH),
        closeTo(_stripH, 1e-6),
      );
      final y = fxMapStripY(
        weights: <double>[0, 0, 2],
        unit: 1,
        stripHeight: _stripH,
      );
      expect(y.isFinite, isTrue);
      expect(
        fxMapChapterAt(
          weights: <double>[0, 0, 0],
          stripY: 10,
          stripHeight: _stripH,
        ),
        isNonNegative,
      );
    });
  });

  group('双段追踪（widget）', () {
    testWidgets('reduceMotion：位置变化直跳终值（80ms/40ms 阻尼全跳过）', (tester) async {
      final position = ValueNotifier<FxMapPosition>(const FxMapPosition(0, 0));
      await tester.pumpWidget(
        _host(position: position, onTap: (_) {}, reduceMotion: true),
      );
      await tester.pump();
      await tester.pump();

      position.value = const FxMapPosition(2, 0.5); // unit 3 → y 450
      await tester.pump();
      final state = tester.state<FxChapterMapState>(find.byType(FxChapterMap));
      expect(state.boxY, closeTo(450, 0.5), reason: 'reduceMotion 必须直跳');
      await tester.pump(const Duration(milliseconds: 200));
      expect(state.boxY, closeTo(450, 0.5), reason: '直跳后无残余动画');
    });

    testWidgets('非 reduceMotion：框平滑追踪（先中间值、后收敛）', (tester) async {
      final position = ValueNotifier<FxMapPosition>(const FxMapPosition(0, 0));
      await tester.pumpWidget(_host(position: position, onTap: (_) {}));
      await tester.pump();
      await tester.pump();
      final state = tester.state<FxChapterMapState>(find.byType(FxChapterMap));

      position.value = const FxMapPosition(2, 0.5); // 目标 y 450
      // 两拍：第一拍第一段阻尼推进并给第二段定标，第二拍第二段（框）推进。
      await tester.pump(const Duration(milliseconds: 40));
      await tester.pump(const Duration(milliseconds: 40));
      expect(state.boxY, greaterThan(1.0), reason: '阻尼必须已开始推进');
      expect(state.boxY, lessThan(449), reason: '阻尼必须还在途中（80ms/40ms 常数）');
      await tester.pumpAndSettle(const Duration(milliseconds: 16));
      expect(state.boxY, closeTo(450, 1.0), reason: 'settled 后钉在终值');
    });
  });

  group('交互（widget）', () {
    testWidgets('宽屏（≥720）常显：点击章带 → onChapterTap 命中分段线性章', (tester) async {
      final position = ValueNotifier<FxMapPosition>(const FxMapPosition(0, 0));
      var tapped = -1;
      await tester.pumpWidget(
        _host(position: position, onTap: (c) => tapped = c),
      );
      await tester.pump();
      await tester.pump();

      final rect = tester.getRect(find.byType(FxChapterMap));
      // y=450 → unit 3.0 → 第 3 章。
      await tester.tapAt(Offset(rect.left + 10, rect.top + 450));
      await tester.pump();
      expect(tapped, 2);
    });

    testWidgets('窄屏：4px 折叠 → 点按展开 → 点章带跳章 → 点当前章收起', (tester) async {
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final position = ValueNotifier<FxMapPosition>(
        const FxMapPosition(1, 0.5),
      );
      final tapped = <int>[];
      await tester.pumpWidget(
        _host(position: position, onTap: tapped.add, logicalWidth: 400),
      );
      await tester.pump();
      await tester.pump();

      final rect = tester.getRect(find.byType(FxChapterMap));
      expect(rect.width, kFxChapterMapHitWidth, reason: '窄屏默认折叠（命中区）');

      // 第一次点按：展开（不跳章）。
      await tester.tapAt(Offset(rect.left + 12, rect.top + 300));
      await tester.pumpAndSettle();
      expect(tapped, isEmpty, reason: '折叠态点按只展开');

      // 展开后点第 3 章带（y=450）→ 跳章，面板保持展开。
      final rect2 = tester.getRect(find.byType(FxChapterMap));
      await tester.tapAt(Offset(rect2.left + 40, rect2.top + 450));
      await tester.pumpAndSettle();
      expect(tapped, <int>[2]);

      // 点当前章（第 2 章带 [150,300] 的中心 y=225）→ 收起，不再跳章。
      final rect3 = tester.getRect(find.byType(FxChapterMap));
      await tester.tapAt(Offset(rect3.left + 40, rect3.top + 225));
      await tester.pumpAndSettle();
      expect(tapped, <int>[2], reason: '命中当前章 = 收起，不再跳章');
    });

    testWidgets('条带带 Semantics：描述当前章/总章数', (tester) async {
      final handle = tester.ensureSemantics();
      final position = ValueNotifier<FxMapPosition>(
        const FxMapPosition(1, 0.5),
      );
      await tester.pumpWidget(_host(position: position, onTap: (_) {}));
      await tester.pump();
      final semantics = tester.getSemantics(find.byType(FxChapterMap));
      expect(semantics.label, contains('第 2 章'));
      expect(semantics.label, contains('共 3 章'));
      handle.dispose();
    });
  });

  test('追踪常数：80ms/40ms 的 rate 值落档（atlas scroll-minimap 出处）', () {
    expect(kFxChapterMapGlideRate, closeTo(1000 / 80, 1e-9));
    expect(kFxChapterMapFrameRate, closeTo(1000 / 40, 1e-9));
    expect(AppMetrics.standard.enter, const Duration(milliseconds: 200));
  });
}
