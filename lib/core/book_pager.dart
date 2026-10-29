import 'package:flutter/widgets.dart';

/// 把章节段落按可用区域与字体度量切成页（翻页模式用）。
///
/// 逐行贪心排版：每一行用二分查找求出「这一段从当前位置起最多能放下多少个
/// 字」，行高按 `fontSize * height` 估算，页面高度用满即换页；段落之间额外留
/// [paragraphGap]。返回每页的纯文本，顺序与原文一致。
///
/// 不用 `computeLineMetrics` —— 它只给几何信息，不给字符偏移，切不出行文本。
List<String> paginateParagraphs({
  required List<String> paragraphs,
  required TextStyle style,
  required double width,
  required double height,
  double paragraphGap = 14,
}) {
  if (paragraphs.isEmpty || width <= 0 || height <= 0) return const [];

  final fontSize = style.fontSize ?? 16;
  final lineHeight = fontSize * (style.height ?? 1.2);
  final painter = TextPainter(textDirection: TextDirection.ltr);
  final pages = <StringBuffer>[];
  var current = StringBuffer();
  var used = 0.0;

  double measure(String text) {
    if (text.isEmpty) return 0;
    painter.text = TextSpan(text: text, style: style);
    painter.layout();
    return painter.width;
  }

  /// 从 [start] 起，宽度不超过 width 的最大字符数（至少 1）。
  int fitLength(String text, int start) {
    var lo = 1;
    var hi = text.length - start;
    var best = 1;
    while (lo <= hi) {
      final mid = (lo + hi) ~/ 2;
      if (measure(text.substring(start, start + mid)) <= width) {
        best = mid;
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    return best;
  }

  for (final paragraph in paragraphs) {
    var start = 0;
    while (start < paragraph.length) {
      final take = fitLength(paragraph, start);
      if (used + lineHeight > height && current.isNotEmpty) {
        pages.add(current);
        current = StringBuffer();
        used = 0;
      }
      current.writeln(paragraph.substring(start, start + take));
      used += lineHeight;
      start += take;
    }
    used += paragraphGap;
  }
  if (current.isNotEmpty) pages.add(current);

  return [for (final page in pages) page.toString().trimRight()];
}
