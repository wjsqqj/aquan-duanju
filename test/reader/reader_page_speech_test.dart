/// 渲染层 Gate（implement.md 步骤 4 / prd.md AC「高亮不得改变排版」）：
/// 朗读高亮**只切 span、不改行结构**。
///
/// 直接喂分页器形状的 [ReaderPage] / [ReaderPageLine]，钉住四件事：
/// 1. 每行永远是 `SizedBox(height: line.height)` 里**唯一**的一个 `Text`，
///    `softWrap:false / maxLines:1 / overflow:clip` 三件套一个不少；
/// 2. 开/关高亮两帧里每行的位置与文本**逐项相同** —— 高亮不可能引起二次换行
///    （`frontend/reader-paging-contract.md` §9.1）；
/// 3. 没撞上区间的行走 `Text` 快路径（`text != null`），撞上才 `Text.rich`；
/// 4. 段首缩进不占字符位：首行绝对字符位 0 的词要落在**跳过缩进**的那个字符上。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:aquan_duanju/core/reader/reader_paginator.dart';
import 'package:aquan_duanju/core/reader/reader_speech_settings.dart';
import 'package:aquan_duanju/core/reader/reader_theme.dart';
import 'package:aquan_duanju/core/reader/reader_typography.dart';
import 'package:aquan_duanju/widgets/reader/reader_page_view.dart';

const double _lineHeight = 34;

ReaderPageLine _line(
  String text,
  int charStart,
  int charEnd, {
  bool first = false,
}) =>
    ReaderPageLine(
      text: text,
      paragraph: 0,
      firstOfParagraph: first,
      height: _lineHeight,
      charStart: charStart,
      charEnd: charEnd,
    );

/// 三行正文，章内坐标连成 0..12。
final List<ReaderPageLine> _lines = <ReaderPageLine>[
  _line('甲乙丙丁', 0, 4, first: true),
  _line('戊己庚辛', 4, 8),
  _line('壬癸甲乙', 8, 12),
];

ReaderPageRenderSpec _spec({
  (int, int)? base,
  (int, int)? active,
  SpeechHighlightStyle style = SpeechHighlightStyle.highlight,
}) =>
    ReaderPageRenderSpec(
      typography: const ReaderTypography(),
      theme: defaultReaderThemes().first,
      night: false,
      chapterTitle: '第一章 起风了',
      bookName: '一本书',
      chapterIndex: 0,
      chapterSize: 1,
      headerHeight: 20,
      footerHeight: 20,
      speechBase: base,
      speechActive: active,
      speechStyle: style,
    );

Future<void> _pump(WidgetTester tester, ReaderPageRenderSpec spec) =>
    _pumpLines(tester, _lines, spec);

Future<void> _pumpLines(
  WidgetTester tester,
  List<ReaderPageLine> lines,
  ReaderPageRenderSpec spec,
) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 360,
          height: 600,
          // pageIndex 用 1：避开第 0 页的章标题 Text，行计数才干净。
          child: ReaderPageContent(
            page: ReaderPage(
              lines: lines,
              charStart: lines.first.charStart,
              charEnd: lines.last.charEnd,
              paragraphStart: 0,
              paragraphEnd: 1,
            ),
            pageIndex: 1,
            pageSize: 2,
            spec: spec,
          ),
        ),
      ),
    ),
  );
}

List<Text> _texts(WidgetTester tester) =>
    tester.widgetList<Text>(find.byType(Text)).toList();

/// `Text.rich` 的 `textSpan` 静态类型是 `InlineSpan?`，取 children 要先收窄到
/// [TextSpan]（渲染层切出来的每一段都是普通 `TextSpan`）。
List<TextSpan> _spans(Text text) =>
    (text.textSpan as TextSpan?)!.children!.cast<TextSpan>();

/// 每行的 top：行结构没变时，两帧的这个列表逐项相等。
List<double> _tops(WidgetTester tester, int count) => [
      for (var i = 0; i < count; i++)
        tester.getRect(find.byType(Text).at(i)).top,
    ];

List<String> _plain(WidgetTester tester) => [
      for (final t in _texts(tester)) t.data ?? t.textSpan!.toPlainText(),
    ];

void main() {
  testWidgets('每行仍是 softWrap:false / maxLines:1 / clip 的单个 Text', (
    tester,
  ) async {
    await _pump(tester, _spec(base: (0, 8), active: (5, 6)));

    final texts = _texts(tester);
    expect(texts.length, _lines.length, reason: '一行一个 Text，不许插第二个文本节点');
    for (final text in texts) {
      expect(text.softWrap, false, reason: '物理上不可能二次换行');
      expect(text.maxLines, 1);
      expect(text.overflow, TextOverflow.clip);
    }
  });

  testWidgets('开高亮与关高亮两帧的行位置与文本逐项相同', (tester) async {
    await _pump(tester, _spec());
    final off = _tops(tester, _lines.length);
    final offText = _plain(tester);

    await _pump(
      tester,
      _spec(base: (0, 12), active: (5, 6), style: SpeechHighlightStyle.outline),
    );
    final on = _tops(tester, _lines.length);
    final onText = _plain(tester);

    expect(on, off, reason: '行 top 变了 = 分页与渲染脱钩，这是排版回归');
    expect(onText, offText, reason: '切分只能重排字符归属，一个字都不能变');
  });

  testWidgets('只有撞上区间的行切 Text.rich，其余走 Text 快路径', (tester) async {
    await _pump(tester, _spec(active: (5, 6)));

    final rich = _texts(tester).where((t) => t.textSpan != null).toList();
    expect(rich.length, 1, reason: '一页几十行只该有 1~2 行切分（性能）');
    final spans = _spans(rich.single);
    expect(spans.map((s) => s.text).join(), '戊己庚辛');
    expect(spans.length, 3, reason: '前 / 词 / 后三段');
    expect(spans[0].style, isNull);
    expect(spans[2].style, isNull);
    expect(
      spans[1].style!.backgroundColor,
      Color(speechSolidArgb(kSpeechColorFollowTheme, false)),
    );
  });

  testWidgets('朗读区间为 null 时整页零个 Text.rich', (tester) async {
    await _pump(tester, _spec());
    expect(_texts(tester).where((t) => t.textSpan != null), isEmpty);
  });

  testWidgets('段首缩进不进字符位（§9.1）：绝对位 0 的词高亮第一个汉字', (
    tester,
  ) async {
    // 首行行文本带缩进「　　甲乙丙」，但 charStart..charEnd 只数正文三个汉字。
    final indented = <ReaderPageLine>[
      _line('　　甲乙丙', 0, 3, first: true),
    ];
    await _pumpLines(tester, indented, _spec(active: (0, 1)));

    final spans = _spans(_texts(tester).single);
    expect(
      spans.map((s) => s.text).join(),
      '　　甲乙丙',
      reason: '缩进照常渲染，只是不参与字符位换算',
    );
    final lit = spans.where((s) => s.style?.backgroundColor != null).toList();
    expect(lit.length, 1);
    expect(
      lit.single.text,
      '甲',
      reason: '绝对位 0 = 第一个汉字；少算缩进会亮成全角空格，多算会亮成「乙」',
    );
  });
}
