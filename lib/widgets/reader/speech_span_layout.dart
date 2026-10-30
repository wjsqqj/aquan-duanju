/// 朗读高亮与用户划线的**共用**行内切分。
///
/// 为什么抽成纯函数：改造前 `reader_page_view.dart` 里有一套「行区间 ∩ 划线区间 →
/// 前/中/后三段 `TextSpan`」的 cuts 合并算法，朗读高亮则另走「整行铺 `ColoredBox`」。
/// 两套切分迟早打架（词级高亮必须落在字符区间上，整行铺色做不到），而且词与划线
/// 重叠时的优先级无处落地。现在渲染层只消费这一个函数的结果
/// （`frontend/reader-paging-contract.md` §9.2 / §9.4）。
///
/// 优先级：**当前词实心 > 用户划线色 > 句底纹 > 无底色**。
library;

import 'package:flutter/painting.dart';

import '../../core/reader/reader_annotations.dart';
import '../../core/reader/reader_speech_settings.dart';

/// 这一行有没有需要切 span 的区间（渲染层用它决定走 [Text] 快路径还是 [Text.rich]）。
///
/// 快路径很重要：一页 40 行里通常只有 1~2 行撞上朗读区间，其余行必须仍然是
/// 单个 `Text`，不能为了高亮每帧构造 span 列表。
bool lineNeedsSpans({
  required int lineCharStart,
  required int lineCharEnd,
  required List<ReaderMarking> markings,
  required (int, int)? base,
  required (int, int)? active,
}) {
  if (_rangeHitsLine(base, lineCharStart, lineCharEnd)) return true;
  if (_rangeHitsLine(active, lineCharStart, lineCharEnd)) return true;
  for (final marking in markings) {
    if (marking.overlaps(lineCharStart, lineCharEnd)) return true;
  }
  return false;
}

bool _rangeHitsLine((int, int)? range, int lineCharStart, int lineCharEnd) =>
    range != null && range.$1 < lineCharEnd && lineCharStart < range.$2;

/// 把一行文本按「划线区间 ∩ 句底纹 ∩ 当前词」切成若干 [InlineSpan]。
///
/// - [lineText] / [lineCharStart] / [lineCharEnd]：分页器给出的行文本与它的章内
///   字符区间 `[start,end)`。行止由分页器直接给，不从长度反推 —— 反推等于把
///   「行长 = 止 - 起」这条排版不变量再编码一遍，将来改排版就会悄悄错色；
/// - [indentChars]：**首行段首缩进的字符数**。缩进只参与测量、不占章内字符位
///   （§9.1），所以首行行内下标比绝对字符位多出一段，不补回来高亮会整体左移；
/// - [base]：句子（音轨路径则是段落）底纹区间，章内坐标 `[start,end)`；
/// - [active]：当前词实心区间；`null` 表示这一帧没有词级精度；
/// - [foregroundArgb]：正文色 ARGB，`outline` 的「反色」要用它当底色；传 0 时按
///   [night] 取黑/白兜底。
///
/// 只加装饰，不改文本：所有分段的 `text` 拼起来恒等于 [lineText]，
/// 因此渲染层继续用 `softWrap:false + maxLines:1 + clip`，不可能二次换行。
List<InlineSpan> lineSpansFor({
  required String lineText,
  required int lineCharStart,
  required int lineCharEnd,
  required List<ReaderMarking> markings,
  required (int, int)? base,
  required (int, int)? active,
  required SpeechHighlightStyle style,
  required int colorArgb,
  required bool night,
  int indentChars = 0,
  int foregroundArgb = 0,
}) {
  final length = lineText.length;
  if (length == 0) return const <InlineSpan>[];

  // 章内绝对下标 → 行内下标（越界 clamp，保证不越界取值）。
  int localOf(int absolute) =>
      (absolute - lineCharStart + indentChars).clamp(0, length);
  // 行内下标 → 绝对下标：用分段起点判断归属，边界一律「含起不含止」。
  int absoluteOf(int local) => lineCharStart + local - indentChars;

  final hits = <ReaderMarking>[
    for (final marking in markings)
      if (marking.overlaps(lineCharStart, lineCharEnd)) marking,
  ];
  final cuts = <int>{0, length};
  for (final marking in hits) {
    cuts.add(localOf(marking.charStart));
    cuts.add(localOf(marking.charEnd));
  }
  if (base != null) {
    cuts.add(localOf(base.$1));
    cuts.add(localOf(base.$2));
  }
  if (active != null) {
    cuts.add(localOf(active.$1));
    cuts.add(localOf(active.$2));
  }
  final sorted = cuts.toList()..sort();

  final solid = Color(speechSolidArgb(colorArgb, night));
  final shade = Color(speechShadeArgb(colorArgb, night));
  final spans = <InlineSpan>[];
  for (var i = 0; i < sorted.length - 1; i++) {
    final start = sorted[i];
    final end = sorted[i + 1];
    // 边界相等（同一个 cut 重复命中、区间正好接上）不产空 span。
    if (end <= start) continue;
    final absolute = absoluteOf(start);
    final activeHit = _covers(active, absolute);
    ReaderMarking? marking;
    for (final hit in hits) {
      if (hit.charStart <= absolute && absolute < hit.charEnd) {
        marking = hit;
        break;
      }
    }
    final TextStyle? decoded;
    if (activeHit) {
      decoded = _activeStyle(
        style,
        solid: solid,
        // 句子底纹照常铺在词下面：非「底色」样式时两者同时可见。
        shade: shade,
        foregroundArgb: foregroundArgb,
        night: night,
      );
    } else if (marking != null) {
      decoded = TextStyle(backgroundColor: Color(marking.color.argb));
    } else if (_covers(base, absolute)) {
      decoded = TextStyle(backgroundColor: shade);
    } else {
      decoded = null;
    }
    spans.add(TextSpan(text: lineText.substring(start, end), style: decoded));
  }
  return spans;
}

bool _covers((int, int)? range, int absolute) =>
    range != null && range.$1 <= absolute && absolute < range.$2;

/// 「当前词」这一段的画法。Flutter 没有 wavy 装饰，`squiggly` 用 `dotted` 近似。
TextStyle _activeStyle(
  SpeechHighlightStyle style, {
  required Color solid,
  required Color shade,
  required int foregroundArgb,
  required bool night,
}) {
  switch (style) {
    case SpeechHighlightStyle.highlight:
      return TextStyle(backgroundColor: solid);
    case SpeechHighlightStyle.underline:
      return TextStyle(
        backgroundColor: shade,
        decoration: TextDecoration.underline,
        decorationColor: solid,
        decorationStyle: TextDecorationStyle.solid,
        decorationThickness: 2,
      );
    case SpeechHighlightStyle.strikethrough:
      return TextStyle(
        backgroundColor: shade,
        decoration: TextDecoration.lineThrough,
        decorationColor: solid,
        decorationStyle: TextDecorationStyle.solid,
        decorationThickness: 2,
      );
    case SpeechHighlightStyle.squiggly:
      // TextDecorationStyle 只有 solid/double/dotted/dashed：没有 wavy，
      // 用 dotted 做最近似，不假装是波浪线（设置项里仍标「波浪线」）。
      return TextStyle(
        backgroundColor: shade,
        decoration: TextDecoration.underline,
        decorationColor: solid,
        decorationStyle: TextDecorationStyle.dotted,
        decorationThickness: 2,
      );
    case SpeechHighlightStyle.outline:
      // 反色：正文色当底色、高亮色当字色，形成一块「描边」色块。
      return TextStyle(
        backgroundColor: Color(
          foregroundArgb != 0
              ? foregroundArgb
              : (night ? 0xFFFFFFFF : 0xFF000000),
        ),
        color: solid,
      );
  }
}
