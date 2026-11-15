import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:aquan_duanju/widgets/motion/decode_reveal.dart'
    show kScrambleCharset;
import 'package:aquan_duanju/widgets/motion/speed_scramble.dart';

Widget _host(
  ValueNotifier<double> velocity, {
  bool disableAnimations = false,
}) => MaterialApp(
  home: MediaQuery(
    data: MediaQueryData(disableAnimations: disableAnimations),
    child: Scaffold(
      body: Center(
        child: FxSpeedScramble(text: '小说聚合', velocity: velocity),
      ),
    ),
  ),
);

dynamic _state(WidgetTester tester) =>
    tester.state(find.byType(FxSpeedScramble));

/// 乱码态的冻结单元格宽度序列（SizedBox.fromSize）。
List<double> _cellWidths(WidgetTester tester) => tester
    .widgetList<SizedBox>(find.byType(SizedBox))
    .map((SizedBox box) => box.width ?? -1)
    .where((double w) => w > 0)
    .toList();

void main() {
  const String title = '小说聚合';

  test('fxScrambleGlyph：确定性伪随机（同参数同字形、恒在字符集内、拍间替换）', () {
    for (int i = 0; i < 8; i++) {
      final Set<String> glyphs = <String>{};
      for (int step = 0; step < kScrambleCharset.length; step++) {
        final String g = fxScrambleGlyph(i, step);
        expect(g, fxScrambleGlyph(i, step)); // 确定性
        expect(kScrambleCharset.contains(g), isTrue);
        glyphs.add(g);
      }
      // (i*7 + step*13) 与表长 24 互素 → 全表覆盖
      expect(glyphs.length, kScrambleCharset.length);
    }
    expect(fxScrambleGlyph(0, 0), kScrambleCharset[0]);
    expect(fxScrambleGlyph(0, 1), kScrambleCharset[13]);
  });

  test('fxScrambleNoise：energy 越高噪声位越多（密度门限单调）', () {
    var low = 0;
    var high = 0;
    for (int i = 0; i < 50; i++) {
      for (int step = 0; step < 20; step++) {
        if (fxScrambleNoise(i, step, kScrambleDensity, 0.3)) low++;
        if (fxScrambleNoise(i, step, kScrambleDensity, 1.0)) high++;
      }
    }
    expect(low, greaterThan(0));
    expect(high, greaterThan(low));
    expect(high, lessThan(50 * 20)); // 满能量也不是全乱（density 0.67）
  });

  testWidgets('慢滚零变化：energy 低于地板不进乱码态', (tester) async {
    final ValueNotifier<double> velocity = ValueNotifier<double>(0);
    await tester.pumpWidget(_host(velocity));
    expect(find.text(title), findsOneWidget);

    velocity.value = 300; // energy = 0.15 < 0.2 地板
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    expect(_state(tester).debugScrambling, isFalse);
    expect(_state(tester).debugRestoring, isFalse);
    expect(find.text(title), findsOneWidget);
  });

  testWidgets('快滚乱码：energy 归一进乱码态，energy 指数衰减（120ms 时间常数）', (tester) async {
    final ValueNotifier<double> velocity = ValueNotifier<double>(0);
    await tester.pumpWidget(_host(velocity));

    velocity.value = 3000; // energy = min(1, 3000/2000) = 1
    await tester.pump(); // 起表首拍（不衰减）
    expect(_state(tester).debugScrambling, isTrue);
    expect(_state(tester).debugEnergy, closeTo(1.0, 0.05));
    expect(find.text(title), findsNothing); // 已切字符列

    // 停输入 120ms：energy = exp(-1) ≈ 0.368，仍在乱码态。
    await tester.pump(const Duration(milliseconds: 120));
    expect(_state(tester).debugEnergy, closeTo(0.368, 0.06));
    expect(_state(tester).debugScrambling, isTrue);
  });

  testWidgets('字宽冻结：乱码期间单元格宽度逐拍不变（行宽不抖）', (tester) async {
    final ValueNotifier<double> velocity = ValueNotifier<double>(0);
    await tester.pumpWidget(_host(velocity));
    velocity.value = 3000;
    await tester.pump();
    final List<double> first = _cellWidths(tester);
    expect(first, hasLength(4));

    await tester.pump(const Duration(milliseconds: 50));
    expect(_cellWidths(tester), first); // 步进换字形：宽度恒定
    await tester.pump(const Duration(milliseconds: 90));
    expect(_cellWidths(tester), first); // 跨拍仍恒定
  });

  testWidgets('复原窗口：停稳后逐字从左复原并停表，渲染回普通 Text', (tester) async {
    final ValueNotifier<double> velocity = ValueNotifier<double>(0);
    await tester.pumpWidget(_host(velocity));
    velocity.value = 3000;
    await tester.pump();
    expect(_state(tester).debugScrambling, isTrue);

    // 停输入：energy 衰减到地板（≈120ms·ln5 ≈ 193ms）→ 复原窗口（4 字
    // stagger 14ms×3 = 42ms）→ 总计远小于 672ms 窗口上限。
    await tester.pumpAndSettle();
    expect(find.text(title), findsOneWidget);
    expect(_state(tester).debugTickerActive, isFalse);
    expect(_state(tester).debugScrambling, isFalse);
    expect(_state(tester).debugRestoring, isFalse);
  });

  testWidgets('复原后再输入：重新进乱码态（能量只升不降的出口自愈）', (tester) async {
    final ValueNotifier<double> velocity = ValueNotifier<double>(0);
    await tester.pumpWidget(_host(velocity));
    velocity.value = 3000;
    await tester.pump();
    await tester.pumpAndSettle();
    expect(find.text(title), findsOneWidget);

    velocity.value = 2600; // 与上一拍不同值（ValueNotifier 同值不通知）
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));
    expect(_state(tester).debugScrambling, isTrue);
    expect(find.text(title), findsNothing);
    await tester.pumpAndSettle();
    expect(find.text(title), findsOneWidget);
  });

  testWidgets('reduceMotion：纯静态标题（不装 Ticker、速度源无效，AC20）', (tester) async {
    final ValueNotifier<double> velocity = ValueNotifier<double>(0);
    await tester.pumpWidget(_host(velocity, disableAnimations: true));
    expect(_state(tester).debugStaticOnly, isTrue);
    expect(_state(tester).debugTickerActive, isFalse);

    velocity.value = 4000; // reduceMotion 下速度源被忽略
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    expect(_state(tester).debugScrambling, isFalse);
    expect(find.text(title), findsOneWidget);
    expect(find.byType(Row), findsNothing);
  });
}
