import 'package:flutter/material.dart';

/// 乱码/字符级动效的**字宽冻结**共享工具（E4 [FxDecodeReveal] 与 E5
/// FxSpeedScramble 共用；effect-atlas mask-decode-reveal「乱码期间字母
/// 宽度冻结防抖行」的手法沉淀）。
///
/// 乱码字形与真字符宽度不同，逐帧替换会让行宽抖动——每个字符单元格取
/// 「真字符 + 本格可能出现的乱码字形」的**最大实测宽**（TextPainter +
/// 缓存），高取统一行高。中文场景单元格宽 ≈ 最终字宽，动效结束切回普通
/// `Text` 时不跳行。
///
/// 缓存语义与 E4 原实现逐位一致：同一样式下实测一次；样式变更整表清空；
/// `lineHeight` 记录**最近一次**实测的行高（同一样式全部字符等高）。
class FxGlyphMeter {
  final Map<String, double> _widths = <String, double>{};
  TextDirection _direction = TextDirection.ltr;
  double _lineHeight = 0;

  /// 最近一次实测的行高（同一样式下全部字符等高，取最后一次即可）。
  double get lineHeight => _lineHeight;

  /// 方向变更（极少发生）：方向进 TextPainter，缓存作废。
  void updateDirection(TextDirection direction) {
    if (_direction == direction) return;
    _direction = direction;
    _widths.clear();
    _lineHeight = 0;
  }

  /// 样式变更（字号/字重不同则宽不同）：整表清空。
  void clearCache() {
    _widths.clear();
    _lineHeight = 0;
  }

  /// 实测单字符宽（含缓存；副作用：刷新 [lineHeight]）。
  double widthOf(String s, TextStyle style) {
    final double? cached = _widths[s];
    if (cached != null) return cached;
    final TextPainter painter = TextPainter(
      text: TextSpan(text: s, style: style),
      textDirection: _direction,
      maxLines: 1,
    )..layout();
    _lineHeight = painter.height;
    return _widths[s] = painter.width;
  }

  /// 单字符单元格尺寸：真字符与候选乱码字形取最大宽，高 = 统一行高。
  Size cellSize({
    required String char,
    required Iterable<String> glyphCandidates,
    required TextStyle style,
  }) {
    double width = widthOf(char, style);
    for (final String glyph in glyphCandidates) {
      final double glyphWidth = widthOf(glyph, style);
      if (glyphWidth > width) width = glyphWidth;
    }
    return Size(width, _lineHeight);
  }
}
