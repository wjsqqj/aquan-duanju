import 'package:aquan_duanju/core/reader/reader_annotations.dart';
import 'package:aquan_duanju/core/reader/reader_speech_settings.dart';
import 'package:aquan_duanju/widgets/reader/speech_span_layout.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';

/// 行内切分的回归锁。改造前「划线」与「朗读高亮」各有一套切分，
/// 这里把 design.md §4 的优先级、边界与快路径判据钉死。
void main() {
  ReaderMarking marking(
    int start,
    int end, {
    MarkingColor color = MarkingColor.blue,
  }) => ReaderMarking(
    id: 'm$start-$end',
    bookId: 'b',
    chapterId: 'c',
    chapterIndex: 0,
    charStart: start,
    charEnd: end,
    text: '',
    color: color,
    createdAt: DateTime(2026),
  );

  // 拼起来必须恒等于行文本：这是「高亮不引起二次换行」的函数级前提。
  void expectReconstructs(List<InlineSpan> spans, String lineText) {
    final joined = spans.whereType<TextSpan>().map((s) => s.text ?? '').join();
    expect(joined, lineText);
    for (final span in spans.whereType<TextSpan>()) {
      expect((span.text ?? '').isEmpty, isFalse, reason: '不许产空 span');
    }
  }

  group('lineNeedsSpans（快路径判据）', () {
    test('三者皆空 → false，渲染层走原 Text', () {
      expect(
        lineNeedsSpans(
          lineCharStart: 0,
          lineCharEnd: 4,
          markings: const <ReaderMarking>[],
          base: null,
          active: null,
        ),
        isFalse,
      );
    });

    test('底纹 / 当前词 / 划线任一命中 → true', () {
      const line = (0, 4);
      expect(
        lineNeedsSpans(
          lineCharStart: line.$1,
          lineCharEnd: line.$2,
          markings: const <ReaderMarking>[],
          base: (2, 6),
          active: null,
        ),
        isTrue,
      );
      expect(
        lineNeedsSpans(
          lineCharStart: 0,
          lineCharEnd: 4,
          markings: const <ReaderMarking>[],
          base: null,
          active: (1, 2),
        ),
        isTrue,
      );
      expect(
        lineNeedsSpans(
          lineCharStart: 0,
          lineCharEnd: 4,
          markings: <ReaderMarking>[marking(3, 9)],
          base: null,
          active: null,
        ),
        isTrue,
      );
    });

    test('半开区间：贴边不算命中', () {
      expect(
        lineNeedsSpans(
          lineCharStart: 4,
          lineCharEnd: 8,
          markings: const <ReaderMarking>[],
          base: (0, 4),
          active: (8, 9),
        ),
        isFalse,
      );
    });
  });

  group('lineSpansFor 切分', () {
    test('词 ∩ 划线 ∩ 句：优先级 当前词 > 划线 > 句底纹 > 无', () {
      final spans = lineSpansFor(
        lineText: '甲乙丙丁',
        lineCharStart: 0,
        lineCharEnd: 4,
        markings: <ReaderMarking>[marking(1, 3)],
        base: (0, 4),
        active: (2, 3),
        style: SpeechHighlightStyle.highlight,
        colorArgb: kSpeechColorFollowTheme,
        night: false,
      );
      final textSpans = spans.whereType<TextSpan>().toList();
      expectReconstructs(spans, '甲乙丙丁');
      expect(textSpans.length, 4);
      expect(
        textSpans[0].style?.backgroundColor,
        Color(speechShadeArgb(0, false)),
      );
      expect(
        textSpans[1].style?.backgroundColor,
        Color(MarkingColor.blue.argb),
      );
      // 第 3 段同时被划线与当前词覆盖：词级实心赢。
      expect(
        textSpans[2].style?.backgroundColor,
        Color(speechSolidArgb(0, false)),
      );
      expect(
        textSpans[3].style?.backgroundColor,
        Color(speechShadeArgb(0, false)),
      );
    });

    test('用章内绝对字符位判断归属，不是行内下标', () {
      final spans = lineSpansFor(
        lineText: '戊己庚辛',
        lineCharStart: 8,
        lineCharEnd: 12,
        markings: const <ReaderMarking>[],
        base: (8, 12),
        active: (10, 11),
        style: SpeechHighlightStyle.highlight,
        colorArgb: kSpeechColorFollowTheme,
        night: false,
      );
      final textSpans = spans.whereType<TextSpan>().toList();
      expectReconstructs(spans, '戊己庚辛');
      expect(textSpans.map((s) => s.text), <String>['戊己', '庚', '辛']);
      expect(
        textSpans[0].style?.backgroundColor,
        Color(speechShadeArgb(0, false)),
      );
      // 绝对字符位 10 = 行内第 3 个字：只有按绝对位判断才会切出单独的「庚」。
      expect(textSpans[1].text, '庚');
      expect(
        textSpans[1].style?.backgroundColor,
        Color(speechSolidArgb(0, false)),
      );
      expect(
        textSpans[2].style?.backgroundColor,
        Color(speechShadeArgb(0, false)),
      );
    });

    test('段首缩进：行内下标比绝对字符位多 indentChars，要补回来', () {
      // 行文本含两个全角空格，但缩进不占章内字符位（§9.1）。
      final spans = lineSpansFor(
        lineText: '　　甲乙丙丁',
        lineCharStart: 0,
        lineCharEnd: 4,
        markings: <ReaderMarking>[marking(1, 2)],
        base: (0, 2),
        active: (3, 4),
        style: SpeechHighlightStyle.highlight,
        colorArgb: kSpeechColorFollowTheme,
        night: false,
        indentChars: 2,
      );
      final textSpans = spans.whereType<TextSpan>().toList();
      expectReconstructs(spans, '　　甲乙丙丁');
      expect(textSpans[0].text, '　　');
      expect(textSpans[0].style, isNull, reason: '缩进不参与上色');
      expect(textSpans[1].text, '甲');
      expect(
        textSpans[1].style?.backgroundColor,
        Color(speechShadeArgb(0, false)),
      );
      expect(textSpans[2].text, '乙');
      expect(
        textSpans[2].style?.backgroundColor,
        Color(MarkingColor.blue.argb),
      );
      expect(textSpans.last.text, '丁');
      expect(
        textSpans.last.style?.backgroundColor,
        Color(speechSolidArgb(0, false)),
      );
    });

    test('区间完全在行外：不产空 span，也不上色', () {
      for (final outside in <(int, int)>[(-10, 0), (10, 12)]) {
        final spans = lineSpansFor(
          lineText: '甲乙丙丁',
          lineCharStart: 0,
          lineCharEnd: 4,
          markings: const <ReaderMarking>[],
          base: outside,
          active: outside,
          style: SpeechHighlightStyle.highlight,
          colorArgb: kSpeechColorFollowTheme,
          night: false,
        );
        expectReconstructs(spans, '甲乙丙丁');
        expect(spans.length, 1);
        expect((spans.first as TextSpan).style, isNull);
      }
    });

    test('相邻区间共用一个边界：不切出空 span', () {
      final spans = lineSpansFor(
        lineText: '甲乙丙丁',
        lineCharStart: 0,
        lineCharEnd: 4,
        markings: <ReaderMarking>[marking(0, 2), marking(2, 4)],
        base: (0, 2),
        active: (2, 4),
        style: SpeechHighlightStyle.highlight,
        colorArgb: kSpeechColorFollowTheme,
        night: false,
      );
      expectReconstructs(spans, '甲乙丙丁');
      expect(spans.length, 2);
    });

    test('空行文本直接返回空列表', () {
      expect(
        lineSpansFor(
          lineText: '',
          lineCharStart: 0,
          lineCharEnd: 0,
          markings: const <ReaderMarking>[],
          base: (0, 2),
          active: null,
          style: SpeechHighlightStyle.highlight,
          colorArgb: 0,
          night: false,
        ),
        isEmpty,
      );
    });
  });

  group('五种高亮样式', () {
    List<TextSpan> activeSpans(SpeechHighlightStyle style) {
      final spans = lineSpansFor(
        lineText: '甲乙丙丁',
        lineCharStart: 0,
        lineCharEnd: 4,
        markings: const <ReaderMarking>[],
        base: (0, 4),
        active: (1, 2),
        style: style,
        colorArgb: 0xFF123456,
        night: false,
      );
      return spans.whereType<TextSpan>().where((s) => s.text == '乙').toList();
    }

    test('底色：只铺实心 backgroundColor', () {
      final span = activeSpans(SpeechHighlightStyle.highlight).single;
      expect(span.style?.backgroundColor, const Color(0xFF123456));
      expect(span.style?.decoration, isNull);
    });

    test('下划线 / 删除线：实心 decorationColor + 底纹垫底', () {
      final under = activeSpans(SpeechHighlightStyle.underline).single.style;
      expect(under?.decoration, TextDecoration.underline);
      expect(under?.decorationStyle, TextDecorationStyle.solid);
      expect(under?.decorationColor, const Color(0xFF123456));
      expect(under?.backgroundColor, Color(speechShadeArgb(0xFF123456, false)));
      final through = activeSpans(SpeechHighlightStyle.strikethrough)
          .single
          .style;
      expect(through?.decoration, TextDecoration.lineThrough);
    });

    test('波浪线：Flutter 无 wavy，落为 dotted 近似', () {
      final span = activeSpans(SpeechHighlightStyle.squiggly).single.style;
      expect(span?.decoration, TextDecoration.underline);
      expect(span?.decorationStyle, TextDecorationStyle.dotted);
    });

    test('描边：正文色当底色、高亮色当字色', () {
      final span = activeSpans(SpeechHighlightStyle.outline).single.style;
      expect(span?.color, const Color(0xFF123456));
      expect(span?.backgroundColor, isNotNull);
    });

    test('描边未传正文色时按日/夜兜底', () {
      List<TextSpan> spans(bool night) => lineSpansFor(
        lineText: '甲乙丙丁',
        lineCharStart: 0,
        lineCharEnd: 4,
        markings: const <ReaderMarking>[],
        base: null,
        active: (1, 2),
        style: SpeechHighlightStyle.outline,
        colorArgb: 0xFF123456,
        night: night,
      ).whereType<TextSpan>().where((s) => s.text == '乙').toList();
      expect(
        spans(true).single.style?.backgroundColor,
        const Color(0xFFFFFFFF),
      );
      expect(
        spans(false).single.style?.backgroundColor,
        const Color(0xFF000000),
      );
    });

    test('全透明配置色被补成不透明', () {
      expect(speechSolidArgb(0x00FF0000, false), 0xFFFF0000);
    });
  });
}
