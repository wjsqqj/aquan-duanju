import 'package:flutter/widgets.dart';

/// 翻页动画样式。
enum PageAnimation { slide, cover, curl }

/// 一页在翻动过程中的呈现：横向偏移（占页宽比例）、缩放、暗度、卷曲进度。
class PageFrame {
  const PageFrame({
    required this.dxRatio,
    required this.scale,
    required this.dim,
    required this.curl,
  });

  /// 0 表示在正中，>0 表示还在右侧待进入。
  final double dxRatio;
  final double scale;

  /// 0..1，越大越暗（被压在下面的页）。
  final double dim;

  /// 0..1，卷曲程度，只有 [PageAnimation.curl] 用到。
  final double curl;

  static const PageFrame center = PageFrame(dxRatio: 0, scale: 1, dim: 0, curl: 0);
}

/// 翻页进度 [value]（当前页为 0，右侧待进入的页为 1，左侧已翻过的页为 -1）
/// 映射到这一页的呈现。纯函数，便于单测。
PageFrame pageFrameFor(double value, PageAnimation animation) {
  switch (animation) {
    case PageAnimation.slide:
      return PageFrame(dxRatio: value, scale: 1, dim: 0, curl: 0);
    case PageAnimation.cover:
      // 新页从右侧整页压上来，旧页留在原地略微缩小变暗。
      if (value > 0) {
        return PageFrame(dxRatio: value, scale: 1, dim: 0, curl: 0);
      }
      final t = value.abs().clamp(0.0, 1.0);
      return PageFrame(
        dxRatio: 0,
        scale: 1 - 0.04 * t,
        dim: 0.25 * t,
        curl: 0,
      );
    case PageAnimation.curl:
      // 卷曲：新页从右边缘被"揭开"，旧页随之变暗；用裁剪比例与阴影强度表达。
      final t = value.clamp(-1.0, 1.0);
      return PageFrame(
        dxRatio: t > 0 ? t * 0.35 : 0,
        scale: 1,
        dim: t < 0 ? 0.3 * t.abs() : 0,
        curl: t > 0 ? t : 0,
      );
  }
}

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
