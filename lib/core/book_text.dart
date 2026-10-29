/// 章节正文清洗：上游 `content` 是 HTML 片段（`<article><h1 class="chapterTitle1">…`），
/// 阅读器要的是段落列表。
library;

/// 章节 HTML → 段落列表。
///
/// - `<br>`、`</p>`、`</div>`、标题结束标签视为换行；
/// - 去掉 script/style/注释与其余标签；
/// - 解码常见实体与数字实体；
/// - 行内空白折叠、首尾空白（含全角空格）去掉、空行丢弃。
List<String> htmlToParagraphs(String html) {
  if (html.trim().isEmpty) return const [];

  var text = html
      .replaceAll(RegExp(r'<!--[\s\S]*?-->'), '')
      .replaceAll(RegExp(r'<(script|style)[^>]*>[\s\S]*?</\1>',
          caseSensitive: false),
          '');

  // 块级边界 → 换行。先处理自闭合与前后的空白，避免拼行。
  text = text.replaceAll(
      RegExp(r'<br\s*/?>|</p\s*>|</div\s*>|</h[1-6]\s*>|</li\s*>',
          caseSensitive: false),
      '\n');
  // 其余标签整段去掉（含属性），标签本身不产生内容。
  text = text.replaceAll(RegExp(r'<[^>]+>'), '');
  text = _decodeEntities(text);

  final out = <String>[];
  for (final rawLine in text.split('\n')) {
    // 全角空格与不换行空格都按普通空格处理，再折叠连续空白。
    final line = rawLine
        .replaceAll('\u00a0', ' ')
        .replaceAll('\ufeff', '')
        .replaceAll(RegExp(r'[ \t\u3000]+'), ' ')
        .trim();
    if (line.isEmpty) continue;
    out.add(line);
  }
  return out;
}

/// 段落列表 → 纯文本（复制/分享用）。
String paragraphsToPlainText(List<String> paragraphs) =>
    paragraphs.join('\n\n');

const Map<String, String> _entities = {
  'nbsp': ' ',
  'amp': '&',
  'lt': '<',
  'gt': '>',
  'quot': '"',
  'apos': "'",
  'ldquo': '“',
  'rdquo': '”',
  'lsquo': '‘',
  'rsquo': '’',
  'hellip': '…',
  'mdash': '—',
  'ndash': '–',
  'middot': '·',
  'times': '×',
  'copy': '©',
};

String _decodeEntities(String input) {
  return input.replaceAllMapped(
    RegExp(r'&(#x?[0-9a-fA-F]+|[a-zA-Z]+);'),
    (match) {
      final body = match.group(1)!;
      if (body.startsWith('#')) {
        final isHex = body.length > 1 && (body[1] == 'x' || body[1] == 'X');
        final digits = isHex ? body.substring(2) : body.substring(1);
        final code = int.tryParse(digits, radix: isHex ? 16 : 10);
        if (code == null || code <= 0 || code > 0x10FFFF) return match.group(0)!;
        return String.fromCharCode(code);
      }
      return _entities[body.toLowerCase()] ?? match.group(0)!;
    },
  );
}
