/// 正文指纹：FNV-1a 32 位，用来判断「同一章的正文有没有被源站换过」。
///
/// 只需要稳定与够快，不需要抗碰撞——它的唯一用途是参与分页缓存键，
/// 以及和磁盘缓存里存下的签名比对。1 万字章节约 0.05ms。
library;

const int _fnvOffset = 0x811c9dc5;
const int _fnvPrime = 0x01000193;
const int _mask = 0xffffffff;

/// 计算 [text] 的 FNV-1a 32 位签名，输出 8 位十六进制。
String contentSignature(String text) {
  if (text.isEmpty) return '00000000';
  var hash = _fnvOffset;
  // 直接按 UTF-16 code unit 迭代，避免额外 encode 开销。
  for (var i = 0; i < text.length; i++) {
    final unit = text.codeUnitAt(i);
    hash ^= unit & 0xff;
    hash = (hash * _fnvPrime) & _mask;
    hash ^= (unit >> 8) & 0xff;
    hash = (hash * _fnvPrime) & _mask;
  }
  return hash.toRadixString(16).padLeft(8, '0');
}

/// 段落列表的签名（先按段落拼一次，保持与缓存写入时同一口径）。
String paragraphsSignature(List<String> paragraphs) =>
    contentSignature(paragraphs.join('\n'));
