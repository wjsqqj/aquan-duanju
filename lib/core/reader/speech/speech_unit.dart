/// 朗读单元切分：把章节段落列表切成可送去合成的片段，并保证每个片段都带着
/// **章内绝对字符坐标**。
///
/// 坐标系与阅读页完全一致（`.trellis/spec/frontend/reader-paging-contract.md` §9.1）：
/// 段落之间以 `'\n'` 相接，`charStart` 含、`charEnd` 不含；段首缩进只参与测量，
/// **不进入**这个字符位。因此朗读算出的区间可以直接与分页行区间求交集。
///
/// 输入必须是阅读页已经清洗过的段落（`htmlToParagraphs` → 标题去重 → 替换规则 → 简繁），
/// 这里不再做第二轮清洗，否则「朗读文本 ≠ 阅读文本」，坐标就会串位。
library;

/// 一个送去合成的片段，以及它在章内字符坐标系中的位置。
class SpeechUnit {
  const SpeechUnit({
    required this.index,
    required this.paragraphIndex,
    required this.charStart,
    required this.charEnd,
    required this.text,
  });

  /// unit 序号，从 0 连续递增。时间点表用它回溯所属句子。
  final int index;

  /// 所属段落在 [paragraphs] 里的下标。
  final int paragraphIndex;

  /// 章内起始字符偏移（含）。
  final int charStart;

  /// 章内结束字符偏移（不含）。
  final int charEnd;

  /// 待合成文本，恒等于 `chapterPlain.substring(charStart, charEnd)`。
  final String text;

  int get length => charEnd - charStart;
}

/// 句末标点：切一句就切在它后面。
const Set<String> kSentenceEnders = <String>{
  '。',
  '！',
  '？',
  '…',
  '；',
  '!',
  '?',
  ';',
};

/// 紧跟句末标点的闭合符号，要归到同一句里（`。”` 不能切成两段）。
const Set<String> kClosingTails = <String>{
  '”',
  '』',
  '】',
  '》',
  '）',
  ')',
  '"',
  '\'',
};

/// 长句的次级切点：一句超过上限时优先在这些字符后断。
const Set<String> kSecondaryBreaks = <String>{
  '，',
  '、',
  ',',
  '：',
  ':',
  '—',
  '·',
};

/// 默认单片段上限（字符数）。上游合成接口有长度限制，留出 SSML 包装余量。
const int kDefaultMaxUnitChars = 200;

/// 把段落列表切成 speak unit。
///
/// 不变量（都有单测守住）：
/// 1. `unit.text == chapterPlain.substring(unit.charStart, unit.charEnd)`；
/// 2. unit 之间不重叠、按 [charStart] 递增；
/// 3. 相邻 unit 之间被跳过的字符只能是空白（不丢正文，标点必须归某一句）；
/// 4. 不产生全空白的 unit。
List<SpeechUnit> splitSpeechUnits(
  List<String> paragraphs, {
  int maxUnitChars = kDefaultMaxUnitChars,
}) {
  if (paragraphs.isEmpty) return const <SpeechUnit>[];
  final limit = maxUnitChars > 0 ? maxUnitChars : kDefaultMaxUnitChars;
  final units = <SpeechUnit>[];
  var base = 0; // 当前段落在章内坐标系的起点
  for (var p = 0; p < paragraphs.length; p++) {
    final text = paragraphs[p];
    // 段落之间用 '\n' 相接：段落为空也要推进坐标，否则后续段整体偏移。
    if (text.trim().isNotEmpty) {
      _splitParagraph(
        text: text,
        base: base,
        paragraphIndex: p,
        units: units,
        limit: limit,
      );
    }
    base += text.length + 1;
  }
  return units;
}

/// 章内明文（朗读坐标系里的正文），用于校验 [SpeechUnit.text]。
String chapterPlainText(List<String> paragraphs) => paragraphs.join('\n');

void _splitParagraph({
  required String text,
  required int base,
  required int paragraphIndex,
  required List<SpeechUnit> units,
  required int limit,
}) {
  var start = _leadingBlankEnd(text, 0);
  var i = start;
  while (i < text.length) {
    final ch = text[i];
    if (kSentenceEnders.contains(ch)) {
      // 句末之后吞掉连续的闭合符号，保证 `。”` 落在同一句。
      var end = i + 1;
      while (end < text.length && kClosingTails.contains(text[end])) {
        end++;
      }
      _emit(units, text, base, paragraphIndex, start, end);
      start = _leadingBlankEnd(text, end);
      i = start;
      continue;
    }
    if (i - start >= limit) {
      // 超长且迟迟等不到句末：先回退找次级切点，找不到就硬切。
      final cut =
          _secondaryCut(text, start, i) ?? _safeHardCut(text, start, limit);
      _emit(units, text, base, paragraphIndex, start, cut);
      start = _leadingBlankEnd(text, cut);
      i = start;
      continue;
    }
    i++;
  }
  if (start < text.length && text.substring(start).trim().isNotEmpty) {
    _emit(units, text, base, paragraphIndex, start, text.length);
  }
}

/// 落一个 unit；跳过纯空白片段。
void _emit(
  List<SpeechUnit> units,
  String text,
  int base,
  int paragraphIndex,
  int start,
  int end,
) {
  if (end <= start) return;
  final slice = text.substring(start, end);
  if (slice.trim().isEmpty) return;
  units.add(
    SpeechUnit(
      index: units.length,
      paragraphIndex: paragraphIndex,
      charStart: base + start,
      charEnd: base + end,
      text: slice,
    ),
  );
}

/// 在 `[start, before]` 内找最后一个次级标点作为切点（切在其后）。
int? _secondaryCut(String text, int start, int before) {
  for (var j = before; j > start; j--) {
    if (kSecondaryBreaks.contains(text[j - 1])) return j;
  }
  return null;
}

/// 定长硬切，但不能把代理对（emoji 等）从中间劈开。
int _safeHardCut(String text, int start, int limit) {
  var end = (start + limit).clamp(start, text.length);
  if (end > start &&
      end < text.length &&
      _isHighSurrogate(text.codeUnitAt(end - 1))) {
    end -= 1;
  }
  return end;
}

bool _isHighSurrogate(int codeUnit) => codeUnit >= 0xD800 && codeUnit <= 0xDBFF;

/// 返回 [from] 之后第一段连续空白的结束位置；整段都是空白则返回长度本身。
int _leadingBlankEnd(String text, int from) {
  var i = from;
  while (i < text.length && _isBlank(text.codeUnitAt(i))) {
    i++;
  }
  return i;
}

bool _isBlank(int codeUnit) =>
    codeUnit == 0x20 ||
    codeUnit == 0x09 ||
    codeUnit == 0x0A ||
    codeUnit == 0x0D;
