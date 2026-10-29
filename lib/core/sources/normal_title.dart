/// 归一化标题：跨源去重键的基础（归一化标题 + 年份）。
///
/// 规则：全角转半角、去空白、去常见中西文标点/分隔符；年份后缀由调用方单独携带
/// （UnifiedSeries.year），这里只统一文本形态。
String normalizeTitle(String raw) {
  var s = raw.trim();
  if (s.isEmpty) return s;
  // 全角 ASCII 区转半角。
  final sb = StringBuffer();
  for (final ch in s.runes) {
    if (ch == 0x3000) {
      sb.write(' ');
    } else if (ch >= 0xFF01 && ch <= 0xFF5E) {
      sb.writeCharCode(ch - 0xFEE0);
    } else {
      sb.writeCharCode(ch);
    }
  }
  s = sb.toString();
  s = s.replaceAll(RegExp(r'\s+'), '');
  s = s.replaceAll(
      RegExp('[\'"\\[\\]()（）【】《》<>·•，,。.！!？?：:；;～~\\-—_+*/\\\\|&^%\$#@＝=]'),
      '');
  return s.toLowerCase();
}
