import 'package:flutter/painting.dart';

import 'reader_typography.dart';

/// 一页里的一行。`text` 已经被裁成「渲染时一定不会换行」的一段。
class ReaderPageLine {
  const ReaderPageLine({
    required this.text,
    required this.paragraph,
    required this.firstOfParagraph,
    required this.height,
    required this.charStart,
    required this.charEnd,
    this.gapAfter = 0,
  });

  final String text;

  /// 段落下标。
  final int paragraph;
  final bool firstOfParagraph;

  /// 该行实际行高（来自 `LineMetrics.height`）。
  final double height;

  /// 章内字符区间。
  final int charStart;
  final int charEnd;

  /// 段末额外间距；非段末为 0。
  final double gapAfter;

  ReaderPageLine copyWith({double? gapAfter}) => ReaderPageLine(
        text: text,
        paragraph: paragraph,
        firstOfParagraph: firstOfParagraph,
        height: height,
        charStart: charStart,
        charEnd: charEnd,
        gapAfter: gapAfter ?? this.gapAfter,
      );

  double get totalHeight => height + gapAfter;
}

/// 一页。
class ReaderPage {
  const ReaderPage({
    required this.lines,
    required this.charStart,
    required this.charEnd,
    required this.paragraphStart,
    required this.paragraphEnd,
  });

  final List<ReaderPageLine> lines;
  final int charStart;
  final int charEnd;
  final int paragraphStart;
  final int paragraphEnd;

  double get height {
    var sum = 0.0;
    for (final line in lines) {
      sum += line.totalHeight;
    }
    return sum;
  }

  bool get isEmpty => lines.isEmpty;
}

/// 分页结果。
class ReaderPagination {
  const ReaderPagination({required this.pages, required this.totalChars});

  static const ReaderPagination empty =
      ReaderPagination(pages: <ReaderPage>[], totalChars: 0);

  final List<ReaderPage> pages;
  final int totalChars;

  bool get isEmpty => pages.isEmpty;
  int get pageCount => pages.length;

  /// 章内字符偏移 → 页码。二分，落在区间外时收敛到首/末页。
  int pageForChar(int charOffset) {
    if (pages.isEmpty) return 0;
    if (charOffset <= pages.first.charStart) return 0;
    var low = 0;
    var high = pages.length - 1;
    var best = 0;
    while (low <= high) {
      final mid = (low + high) >> 1;
      if (pages[mid].charStart <= charOffset) {
        best = mid;
        low = mid + 1;
      } else {
        high = mid - 1;
      }
    }
    return best;
  }

  /// 章内字符偏移 → 章内比例（0..1）。
  double ratioForChar(int charOffset) {
    if (pages.isEmpty) return 0;
    final index = pageForChar(charOffset);
    final page = pages[index];
    if (pageCount == 1) {
      final span = page.charEnd - page.charStart;
      if (span <= 0) return 0;
      return ((charOffset - page.charStart) / span).clamp(0.0, 1.0);
    }
    return ((index + (page.charEnd > page.charStart
                ? (charOffset - page.charStart) /
                    (page.charEnd - page.charStart)
                : 0)) /
            pageCount)
        .clamp(0.0, 1.0);
  }
}

/// 内容区几何：由 `LayoutBuilder` 实测后传入，渲染与分页共用同一份。
class ReaderPageGeometry {
  const ReaderPageGeometry({
    required this.contentWidth,
    required this.contentHeight,
    this.textScaler = TextScaler.noScaling,
    this.textDirection = TextDirection.ltr,
  });

  final double contentWidth;
  final double contentHeight;
  final TextScaler textScaler;
  final TextDirection textDirection;

  bool get isValid => contentWidth > 1 && contentHeight > 1;

  @override
  bool operator ==(Object other) =>
      other is ReaderPageGeometry &&
      other.contentWidth == contentWidth &&
      other.contentHeight == contentHeight &&
      other.textScaler == textScaler &&
      other.textDirection == textDirection;

  @override
  int get hashCode =>
      Object.hash(contentWidth, contentHeight, textScaler, textDirection);

  @override
  String toString() =>
      'ReaderPageGeometry(${contentWidth.toStringAsFixed(1)}×${contentHeight.toStringAsFixed(1)}, $textScaler)';
}

/// 章标题块与首行正文之间的间距。
const double kReaderTitleGap = 18;

/// 把章节段落按「行」精确切页。
///
/// 每个段落只 layout 一次，用 `computeLineMetrics()` 拿行几何，再用
/// `getPositionForOffset()` 反查每行的字符区间，从而把「渲染时的换行结果」
/// 固化成字符串。渲染层再用 `softWrap: false` 画出这些行，永远不会二次换行。
ReaderPagination paginateReader({
  required List<String> paragraphs,
  required ReaderTypography typography,
  required ReaderPageGeometry geometry,
  String? chapterTitle,
}) {
  if (paragraphs.isEmpty || !geometry.isValid) return ReaderPagination.empty;

  const measureColor = Color(0xFF000000);
  final bodyStyle = typography.bodyStyle(
    color: measureColor,
    textScaler: geometry.textScaler,
  );
  final titleStyle = typography.titleStyle(
    color: measureColor,
    textScaler: geometry.textScaler,
  );

  final paragraphStarts = <int>[];
  var totalChars = 0;
  for (final paragraph in paragraphs) {
    paragraphStarts.add(totalChars);
    totalChars += paragraph.length + 1;
  }

  var titleBlock = 0.0;
  final title = chapterTitle?.trim() ?? '';
  if (title.isNotEmpty && typography.includeChapterTitle) {
    final painter = TextPainter(
      text: TextSpan(text: title, style: titleStyle),
      textDirection: geometry.textDirection,
      textScaler: geometry.textScaler,
      maxLines: 4,
      ellipsis: '…',
    )..layout(maxWidth: geometry.contentWidth);
    titleBlock = painter.height + kReaderTitleGap;
    painter.dispose();
  }

  final pages = <ReaderPage>[];
  var current = <ReaderPageLine>[];
  var used = 0.0;
  // 首页要扣掉章标题；后续页恢复满高。
  var capacity = geometry.contentHeight - titleBlock;
  if (capacity <= 0) capacity = geometry.contentHeight;

  void flush() {
    if (current.isEmpty) return;
    pages.add(ReaderPage(
      lines: List<ReaderPageLine>.unmodifiable(current),
      charStart: current.first.charStart,
      charEnd: current.last.charEnd,
      paragraphStart: current.first.paragraph,
      paragraphEnd: current.last.paragraph,
    ));
    current = <ReaderPageLine>[];
    used = 0;
    capacity = geometry.contentHeight;
  }

  for (var index = 0; index < paragraphs.length; index++) {
    final paragraphText = paragraphs[index];
    final lines = _layoutParagraph(
      text: typography.paragraphIndent + paragraphText,
      paragraph: index,
      charBase: paragraphStarts[index],
      charLength: paragraphText.length,
      // 段首缩进只参与测量，不能进入章内字符位（否则批注/朗读高亮会连缩进一起染色）。
      indentLength: typography.paragraphIndent.length,
      style: bodyStyle,
      geometry: geometry,
    );
    if (lines.isEmpty) continue;
    for (var i = 0; i < lines.length; i++) {
      final isLastLine = i == lines.length - 1;
      final gap = isLastLine ? typography.paragraphSpacing : 0.0;
      final line = lines[i].copyWith(gapAfter: gap);
      if (current.isNotEmpty && used + line.totalHeight > capacity) {
        flush();
      }
      current.add(line);
      used += line.totalHeight;
    }
  }
  flush();

  return ReaderPagination(pages: pages, totalChars: totalChars);
}

List<ReaderPageLine> _layoutParagraph({
  required String text,
  required int paragraph,
  required int charBase,
  required int charLength,
  required int indentLength,
  required TextStyle style,
  required ReaderPageGeometry geometry,
}) {
  if (text.isEmpty) return const <ReaderPageLine>[];
  /// 渲染下标 → 原文章内下标：减掉段首缩进并夹在段落范围内。
  int toCharOffset(int renderOffset) =>
      charBase + (renderOffset - indentLength).clamp(0, charLength);
  final painter = TextPainter(
    text: TextSpan(text: text, style: style),
    textDirection: geometry.textDirection,
    textScaler: geometry.textScaler,
    maxLines: null,
  )..layout(maxWidth: geometry.contentWidth);

  final metrics = painter.computeLineMetrics();
  final lines = <ReaderPageLine>[];
  for (var i = 0; i < metrics.length; i++) {
    final metric = metrics[i];
    final sampleY = metric.baseline - metric.ascent + metric.height / 2;
    var start =
        painter.getPositionForOffset(Offset(0, sampleY)).offset.clamp(0, text.length);
    var end = painter
        .getPositionForOffset(Offset(geometry.contentWidth, sampleY))
        .offset
        .clamp(0, text.length);
    if (end <= start) {
      end = (start + 1).clamp(0, text.length);
    }
    if (start >= text.length) continue;
    final slice = text.substring(start, end);
    final trimmed = _trimRight(slice);
    final charStart = toCharOffset(start);
    var charEnd = toCharOffset(end);
    if (charEnd <= charStart) {
      charEnd = (charStart + 1).clamp(charBase, charBase + charLength);
    }
    lines.add(ReaderPageLine(
      text: trimmed.isEmpty ? ' ' : trimmed,
      paragraph: paragraph,
      firstOfParagraph: i == 0,
      height: metric.height,
      charStart: charStart,
      charEnd: charEnd,
    ));
  }
  painter.dispose();
  return lines;
}

String _trimRight(String value) {
  var end = value.length;
  while (end > 0) {
    final unit = value.codeUnitAt(end - 1);
    // 空格、全角空格、制表、换行都不该占着行尾把它顶到下一行。
    if (unit == 0x20 || unit == 0x09 || unit == 0x0A || unit == 0x0D || unit == 0x3000) {
      end--;
    } else {
      break;
    }
  }
  return value.substring(0, end);
}
