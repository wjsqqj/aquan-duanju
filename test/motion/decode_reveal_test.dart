import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:aquan_duanju/widgets/motion/decode_reveal.dart';

Widget _host(Widget child, {bool disableAnimations = false}) => MaterialApp(
  home: MediaQuery(
    data: MediaQueryData(disableAnimations: disableAnimations),
    child: Scaffold(body: Center(child: child)),
  ),
);

dynamic _state(WidgetTester tester) =>
    tester.state(find.byType(FxDecodeReveal));

/// 当前树里冻结单元格的宽度序列（单元格 = SizedBox.fromSize）。
List<double> _cellWidths(WidgetTester tester) => tester
    .widgetList<SizedBox>(find.byType(SizedBox))
    .map((SizedBox box) => box.width!)
    .toList();

void main() {
  const String title = '还没有书签';

  test('fxDecodeRoundCount：确定性 (i*7+3)%3+1，在 1..3 循环', () {
    expect(
      <int>[for (int i = 0; i < 6; i++) fxDecodeRoundCount(i)],
      <int>[1, 2, 3, 1, 2, 3],
    );
  });

  test('fxDecodeGlyph：确定性伪随机（同参数同字形、恒在字符集内、轮间替换）', () {
    for (int i = 0; i < 10; i++) {
      final Set<String> glyphs = <String>{};
      for (int step = 0; step < kDecodeRounds; step++) {
        final String g = fxDecodeGlyph(i, step);
        expect(g, fxDecodeGlyph(i, step)); // 确定性
        expect(kScrambleCharset.contains(g), isTrue);
        glyphs.add(g);
      }
      expect(glyphs.length, kDecodeRounds); // 三轮字形互不相同
    }
    expect(fxDecodeGlyph(0, 0), kScrambleCharset[0]);
    expect(fxDecodeGlyph(0, 1), kScrambleCharset[7]);
    expect(fxDecodeGlyph(0, 2), kScrambleCharset[14]);
  });

  testWidgets('解码时序：首轮全乱码，按确定性轮数逐字符落定', (tester) async {
    await tester.pumpWidget(_host(const FxDecodeReveal(text: title)));
    expect(_state(tester).debugAnimated, isTrue);
    // 首帧 kick（contract 沉淀：pumpWidget 后首拍只吃部分时长，需先 pump 一次）。
    await tester.pump();
    // 首帧：全部字符还在乱码（锁定时刻 ≥165ms）；字符 0 的 0 轮字形 = '0'。
    for (int i = 0; i < title.characters.length; i++) {
      expect(_state(tester).debugDecoded(i), isFalse);
    }
    expect(find.text(kScrambleCharset[0]), findsOneWidget);
    expect(find.text(title), findsNothing);

    // 165ms：字符 0（1 轮）落定；字符 1（2 轮，lock=45+330=375ms）未落定。
    await tester.pump(const Duration(milliseconds: 165));
    expect(_state(tester).debugDecoded(0), isTrue);
    expect(_state(tester).debugDecoded(1), isFalse);
    expect(find.text('还'), findsOneWidget);

    await tester.pumpAndSettle();
    // 解码完成停表：切回普通整句 Text，单元格撤除。
    expect(find.text(title), findsOneWidget);
    expect(find.byType(SizedBox), findsNothing);
  });

  testWidgets('字宽冻结：乱码期间单元格宽度逐帧不变（行宽不抖）', (tester) async {
    await tester.pumpWidget(_host(const FxDecodeReveal(text: title)));
    await tester.pump();
    final List<double> first = _cellWidths(tester);
    expect(first, hasLength(title.characters.length));

    await tester.pump(const Duration(milliseconds: 90));
    expect(_cellWidths(tester), first); // 轮内：宽度恒定
    await tester.pump(const Duration(milliseconds: 120)); // 跨轮换字形
    expect(_cellWidths(tester), first); // 冻结：宽度仍恒定
  });

  testWidgets('reduceMotion：静态直出整句 Text（AC20）', (tester) async {
    await tester.pumpWidget(
      _host(const FxDecodeReveal(text: title), disableAnimations: true),
    );
    expect(_state(tester).debugAnimated, isFalse);
    expect(find.text(title), findsOneWidget);
    expect(find.byType(SizedBox), findsNothing);
  });

  testWidgets('文本变更重播：新文本从乱码重新解码', (tester) async {
    await tester.pumpWidget(_host(const FxDecodeReveal(text: title)));
    await tester.pumpAndSettle();

    const String next = '没有找到结果';
    await tester.pumpWidget(_host(const FxDecodeReveal(text: next)));
    expect(_state(tester).debugCharCount, next.characters.length);
    await tester.pump(); // 首帧 kick（pumpWidget 后首拍只吃部分时长）
    expect(_state(tester).debugDecoded(0), isFalse); // 重新从乱码开始
    await tester.pumpAndSettle();
    expect(find.text(next), findsOneWidget);
  });
}
