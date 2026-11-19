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

  test('fxDecodeBlockGlyph：中文乱码帧用块状占位（确定性）', () {
    for (int i = 0; i < 6; i++) {
      expect(fxDecodeBlockGlyph(i, 0), fxDecodeBlockGlyph(i, 0)); // 确定性
      expect(kDecodeBlockGlyphs.contains(fxDecodeBlockGlyph(i, 0)), isTrue);
    }
    expect(fxDecodeBlockGlyph(0, 0), kDecodeBlockGlyphs[0]);
    expect(fxDecodeBlockGlyph(3, 1), kDecodeBlockGlyphs[0], reason: '(3+1)%4');
    expect(kDecodeBlockGlyphs.contains('A'), isFalse, reason: '块字集不含拉丁字母');
  });

  testWidgets('解码时序：首轮全乱码，按确定性轮数逐字符落定', (tester) async {
    await tester.pumpWidget(_host(const FxDecodeReveal(text: title)));
    expect(_state(tester).debugAnimated, isTrue);
    // 首帧 kick（contract 沉淀：pumpWidget 后首拍只吃部分时长，需先 pump 一次）。
    await tester.pump();
    // 首帧：全部字符还在乱码（锁定时刻 ≥165ms）。中文真字用块状占位，
    // 字符 0 的 0 轮字形 = fxDecodeBlockGlyph(0, 0)，不再是 ASCII '0'
    // （issue #2 截图：拉丁字母乱码被读成编码损坏）。
    for (int i = 0; i < title.characters.length; i++) {
      expect(_state(tester).debugDecoded(i), isFalse);
    }
    // 块字形按 (i+step)%4 循环，同帧可能有多个单元格取到同一块字，
    // 这里只要求首字所在块字在乱码帧里出现。
    expect(find.text(fxDecodeBlockGlyph(0, 0)), findsWidgets);
    expect(find.text(kScrambleCharset[0]), findsNothing);
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

  // issue #2：controller 依赖 vsync，路由/列表离屏（TickerMode 静音）或掉帧时
  // 动画可能长期停在乱码帧——必须有 Timer 兜底把文本落定为普通 Text。
  testWidgets('Ticker 被静音时 Timer 兜底落定（≤ 总时长 + 200ms）', (tester) async {
    await tester.pumpWidget(
      _host(
        const TickerMode(enabled: false, child: FxDecodeReveal(text: title)),
      ),
    );
    await tester.pump();
    expect(_state(tester).debugAnimated, isTrue);
    expect(find.byType(SizedBox), findsWidgets, reason: '静音时停在乱码单元格');
    expect(find.text(title), findsNothing);

    await tester.pump(const Duration(seconds: 2));
    expect(find.text(title), findsOneWidget);
    expect(find.byType(SizedBox), findsNothing);
  });

  // issue #2：`我的`页空态是 ListView 懒构建，滚进视口即重新挂载会重播乱码；
  // keep-alive 保留已落定的 State。
  testWidgets('滚动离屏再回来不重播（keep-alive 保留落定 State）', (tester) async {
    final ScrollController scroll = ScrollController();
    addTearDown(scroll.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(),
          child: Scaffold(
            body: ListView(
              controller: scroll,
              children: const <Widget>[
                SizedBox(height: 2000),
                Padding(
                  padding: EdgeInsets.all(16),
                  child: FxDecodeReveal(text: title),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    // 懒构建：首屏只有 2000px 占位，标题还没挂载。
    expect(find.byType(FxDecodeReveal), findsNothing);

    // 先滚到底：拿到含标题真实高度后的 maxScrollExtent（初次布局只有估算值，
    // 直接用它回滚会冲过头把标题留在视口外）。
    scroll.jumpTo(scroll.position.maxScrollExtent);
    await tester.pumpAndSettle();
    expect(find.text(title), findsOneWidget);
    final double bottom = scroll.position.maxScrollExtent;
    final State<StatefulWidget> settled = tester.state(
      find.byType(FxDecodeReveal),
    );

    // 滚出视口再滚回：State 身份不变，且不再出现块状占位。
    scroll.jumpTo(0);
    await tester.pumpAndSettle();
    scroll.jumpTo(bottom);
    // keep-alive 的复活在下一次布局里完成：多 pump 一帧（不推进时钟，
    // 若真重播此时仍停在首帧块状占位）。
    await tester.pump();
    await tester.pump();
    expect(
      tester.state(find.byType(FxDecodeReveal)),
      same(settled),
      reason: 'keep-alive 必须保留已落定的 State',
    );
    expect(find.text(fxDecodeBlockGlyph(0, 0)), findsNothing);
    await tester.pump();
    expect(find.text(title), findsOneWidget);
  });
}
