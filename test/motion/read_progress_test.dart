import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:aquan_duanju/widgets/continuous_chapters.dart';
import 'package:aquan_duanju/widgets/motion/read_progress.dart';

/// 与测试窗口同构的参数：视口高 600 → 焦点线 228。
const _viewportH = 600.0;
double get _focusLine => _viewportH * kFxReadFocusRatio;

List<String> _paragraphs(int count) =>
    List.generate(count, (k) => '第$k段落，内容足够长以铺满一行文字，滚动点亮按段计算已读度。');

Widget _host(
  FxReadProgress driver, {
  int? highlightParagraph,
  bool disableAnimations = false,
}) {
  return MaterialApp(
    home: MediaQuery(
      data: MediaQueryData(disableAnimations: disableAnimations),
      child: Scaffold(
        body: ContinuousChapters(
          chapters: const <String>['c1', 'c2'],
          initialChapter: 0,
          loadChapter: (i, _) async => _paragraphs(24),
          onPosition: (_, _, _) {},
          highlightChapter: highlightParagraph == null ? null : 0,
          highlightParagraph: highlightParagraph,
          readProgress: driver,
        ),
      ),
    ),
  );
}

/// 断言「每个可见段的透明度 == 按其矩形对焦点线的已读度」。
///
/// 返回违规描述列表（空 = 通过）；跳过朗读高亮段（由调用方单独断言不 dim）。
List<String> _assertDimMatchesGeometry(WidgetTester tester, Set<int> exempt) {
  final failures = <String>[];
  for (var k = 0; k < 24; k++) {
    final finder = find.text(_paragraphs(24)[k]);
    if (finder.evaluate().isEmpty) continue;
    if (exempt.contains(k)) continue;
    final rect = tester.getRect(finder);
    final readT = fxParagraphReadT(
      top: rect.top,
      bottom: rect.bottom,
      focusLine: _focusLine,
    );
    final expected = fxParagraphOpacity(readT);
    final opacityWidgets = find.ancestor(
      of: finder,
      matching: find.byType(Opacity),
    );
    if (expected >= 0.999) {
      if (opacityWidgets.evaluate().isNotEmpty) {
        final w = tester.widget<Opacity>(opacityWidgets.first);
        failures.add('段$k 已读(全亮)却带 Opacity(${w.opacity})');
      }
      continue;
    }
    if (opacityWidgets.evaluate().isEmpty) {
      failures.add('段$k 未读(期望 $expected)却没有 dim 包装');
      continue;
    }
    final w = tester.widget<Opacity>(opacityWidgets.first);
    if ((w.opacity - expected).abs() > 0.02) {
      failures.add('段$k 透明度 ${w.opacity} ≠ 期望 $expected');
    }
  }
  return failures;
}

void main() {
  group('纯函数：readT 边界与透明度映射', () {
    test('段底 ≤ 焦线 → 全亮；段顶 ≥ 焦线 → 未读', () {
      expect(fxParagraphReadT(top: 100, bottom: 150, focusLine: 200), 1.0);
      expect(fxParagraphReadT(top: 250, bottom: 300, focusLine: 200), 0.0);
    });

    test('边界段线性插值（连续、可逆）', () {
      final up = fxParagraphReadT(top: 180, bottom: 220, focusLine: 200);
      expect(up, closeTo(0.5, 1e-9));
      final down = fxParagraphReadT(top: 220, bottom: 180, focusLine: 200);
      expect(down, closeTo(0.5, 1e-9), reason: 'top/bottom 反序按退化处理不越界');
      // 同一段随焦线从段中滑向段顶：readT 单调升到 1。
      final a = fxParagraphReadT(top: 180, bottom: 220, focusLine: 190);
      final b = fxParagraphReadT(top: 180, bottom: 220, focusLine: 210);
      expect(a, lessThan(b));
      expect(b, lessThan(1.0));
    });

    test('透明度映射：0.55..1.0，clamp', () {
      expect(fxParagraphOpacity(0), kFxReadDimMin);
      expect(fxParagraphOpacity(1), 1.0);
      expect(fxParagraphOpacity(0.44), closeTo(0.748, 1e-9));
      expect(fxParagraphOpacity(-1), kFxReadDimMin);
      expect(fxParagraphOpacity(2), 1.0);
    });
  });

  group('驱动源信号分离', () {
    test('enabledListenable 只在开关翻转时通知；tick 走 ChangeNotifier', () {
      final driver = FxReadProgress();
      var structureChanges = 0;
      driver.enabledListenable.addListener(() => structureChanges++);
      expect(driver.enabled, isFalse, reason: '默认关');

      driver.tick();
      expect(structureChanges, 0, reason: '滚动帧不得触发结构通知');

      var notified = 0;
      driver.addListener(() => notified++);
      driver.tick();
      expect(notified, 0, reason: '关态 tick 零开销零通知');

      driver.enabled = true;
      expect(structureChanges, 1);
      expect(driver.introPending, isTrue, reason: '接通后第一拍走 enter 过渡');
      driver.tick();
      expect(driver.introPending, isFalse, reason: '首拍后滚动直接取实时值');
      expect(notified, 1);
    });
  });

  group('ContinuousChapters 接线（滚动模式段级 dim）', () {
    testWidgets('默认关：段落不带任何 Opacity（关态与现状等价）', (tester) async {
      final driver = FxReadProgress();
      await tester.pumpWidget(_host(driver));
      await tester.pump();
      await tester.pump();
      expect(driver.enabled, isFalse);
      expect(find.byType(Opacity), findsNothing);
    });

    testWidgets('开启后：明暗随焦点线连续变化（已读全亮/未读 0.55/边界插值）', (tester) async {
      final driver = FxReadProgress();
      await tester.pumpWidget(_host(driver));
      await tester.pump();
      await tester.pump();

      driver.enabled = true;
      // 接通首拍走一次 enter 档过渡（AnimatedOpacity），过渡结束才落直接
      // Opacity——pumpAndSettle 等它走完再断言。
      await tester.pumpAndSettle();
      expect(
        _assertDimMatchesGeometry(tester, const <int>{}),
        isEmpty,
        reason: '每段的透明度必须与几何×焦点线推导一致',
      );
    });

    testWidgets('滚动驱动、反向可逆（无 Timer）：下滚后上滚回到同一分布', (tester) async {
      final driver = FxReadProgress();
      await tester.pumpWidget(_host(driver));
      await tester.pump();
      await tester.pump();
      driver.enabled = true;
      await tester.pumpAndSettle();

      // 下滚 300px：分界上移，先前已读的分布整体变化。
      await tester.drag(find.byType(ContinuousChapters), const Offset(0, -300));
      await tester.pumpAndSettle(const Duration(milliseconds: 50));
      expect(_assertDimMatchesGeometry(tester, const <int>{}), isEmpty);

      // 回滚到顶：分布回到初始（可逆）。
      await tester.drag(find.byType(ContinuousChapters), const Offset(0, 300));
      await tester.pumpAndSettle(const Duration(milliseconds: 50));
      expect(_assertDimMatchesGeometry(tester, const <int>{}), isEmpty);
      // 拖拽回滚带惯性，不钉死在 0：只断言首段回到焦点线上方（可逆）。
      final top = tester.getRect(find.text(_paragraphs(24)[0]));
      expect(
        top.bottom,
        lessThanOrEqualTo(_focusLine),
        reason: '滚回后首段重新落到已读区（可逆）',
      );
    });

    testWidgets('TTS 高亮段永不 dim（实心/底纹优先级高）', (tester) async {
      final driver = FxReadProgress();
      // 高亮第 5 段（首屏内位于焦点线以下）。
      await tester.pumpWidget(_host(driver, highlightParagraph: 5));
      await tester.pump();
      await tester.pump();
      driver.enabled = true;
      await tester.pumpAndSettle();

      final highlighted = find.text(_paragraphs(24)[5]);
      expect(highlighted.evaluate(), isNotEmpty);
      final rect = tester.getRect(highlighted);
      expect(rect.top, greaterThan(_focusLine), reason: '前置条件：高亮段位于焦点线以下（未读区）');
      expect(
        find.ancestor(of: highlighted, matching: find.byType(Opacity)),
        findsNothing,
        reason: '朗读高亮段不得被 dim 包装',
      );
      // 其余段落照常点亮。
      expect(_assertDimMatchesGeometry(tester, const <int>{5}), isEmpty);
    });

    testWidgets('reduceMotion：接通首拍直切终值（intro 过渡零时长）', (tester) async {
      final driver = FxReadProgress();
      await tester.pumpWidget(_host(driver, disableAnimations: true));
      await tester.pump();
      await tester.pump();
      driver.enabled = true;
      await tester.pump(); // 重建列表，段落包上 wrapper
      await tester.pumpAndSettle(); // intro 零时长直切完成
      expect(
        _assertDimMatchesGeometry(tester, const <int>{}),
        isEmpty,
        reason: 'disableAnimations 下接通即终值，无中间过渡帧残留',
      );
      expect(
        find.byType(TweenAnimationBuilder),
        findsNothing,
        reason: '直切后 intro 过渡器必须已退场',
      );
    });
  });
}
