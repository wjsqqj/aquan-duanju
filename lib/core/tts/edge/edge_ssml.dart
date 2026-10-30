/// SSML 构造、XML 转义、不可支持字符清洗与**按字节预算的分块**（全纯函数）。
///
/// 说明书 §3.2 / §7 的逐条落实：
/// - 属性**全单引号**、`xml:lang='en-US'` **硬编码**（服务端只接受 Edge 自己会生成的
///   SSML，locale 由 voice 全名决定，不由 `xml:lang` 决定）；
/// - **不加** `express-as` / `break` / `mark` / `xmlns:mstts`（README.md:55：自定义 SSML 已被
///   服务端拒绝，这是 design.md §5 取证修正的第 5 条）；
/// - 转义与还原**成对**：只转 `& < >` 三个。多转引号会让服务端回吐的 token 与原文
///   对不上，字符坐标随之漂移（硬契约 5）；
/// - 分块上限是 **4096 字节**，且**不复刻上游的 UTF-8 切块 bug**（说明书 §7.1 ★）：
///   安全切点只在窗口内找，所以任何一块都不会超限。
library;

import 'edge_constants.dart';

/// 一段待合成文本在源串里的字符区间（含起不含止）。
///
/// 分块只在**字符**空间里切，坐标即 `job.text` 的下标；字节预算单独核算，
/// 这样「切块」与「坐标」两件事不会互相污染。
class EdgeSpeakRange {
  const EdgeSpeakRange(this.start, this.end);

  final int start;
  final int end;

  int get length => end - start;

  String slice(String source) => source.substring(start, end);

  @override
  String toString() => 'EdgeSpeakRange($start, $end)';
}

/// 默认 `prosody` 三项（`communicate.py:332-334`）。
const String kEdgeDefaultRate = '+0%';
const String kEdgeDefaultVolume = '+0%';
const String kEdgeDefaultPitch = '+0Hz';

/// 上游 `remove_incompatible_characters`（`communicate.py:74-99`）：
/// 码位 0–8、11–12、14–31 换成空格（OCR 产物里的竖表会让服务端直接报错）。
///
/// **长度不变**，所以坐标仍然对得上原文 —— 这是它能安全用在朗读侧的前提。
String removeIncompatibleCharacters(String text) {
  final units = <int>[];
  var dirty = false;
  for (var i = 0; i < text.length; i++) {
    final code = text.codeUnitAt(i);
    if ((code <= 8) ||
        (code >= 11 && code <= 12) ||
        (code >= 14 && code <= 31)) {
      units.add(0x20);
      dirty = true;
    } else {
      units.add(code);
    }
  }
  return dirty ? String.fromCharCodes(units) : text;
}

/// XML 转义：只转 `& < >`（`xml.sax.saxutils.escape` 的默认行为）。
String ssmlEscapeText(String text) {
  final sb = StringBuffer();
  for (var i = 0; i < text.length; i++) {
    final ch = text[i];
    switch (ch) {
      case '&':
        sb.write('&amp;');
      case '<':
        sb.write('&lt;');
      case '>':
        sb.write('&gt;');
      default:
        sb.write(ch);
    }
  }
  return sb.toString();
}

/// 与 [ssmlEscapeText] **成对**的还原（只解这三个）。
String ssmlUnescapeText(String text) => text
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&amp;', '&');

/// 短名 → Azure 全名（`data_classes.py:43-73`）。
///
/// 服务端要的是 `Microsoft Server Speech Text to Speech Voice (zh-CN, XiaoxiaoNeural)`；
/// `edge_dart` 定义了 `fullVoiceName` 却没调用，是它被服务端拒绝的原因之一。
/// 区域方言（`zh-CN-liaoning-XiaobeiNeural`）要把首段并进 region，否则括号里的
/// 第一段变成三段。已经是全名的原样返回。
String azureVoiceName(String shortName) {
  final name = shortName.trim();
  final match = kEdgeVoiceShortNamePattern.firstMatch(name);
  if (match == null) {
    if (RegExp(r'^Microsoft Server Speech Text to Speech Voice \(.+,.+\)$')
        .hasMatch(name)) {
      return name;
    }
    throw FormatException('无法识别的音色名：$shortName');
  }
  var region = match.group(2)!;
  var tail = match.group(3)!;
  final dash = tail.indexOf('-');
  if (dash != -1) {
    region = '$region-${tail.substring(0, dash)}';
    tail = tail.substring(dash + 1);
  }
  final full =
      'Microsoft Server Speech Text to Speech Voice (${match.group(1)}-$region, $tail)';
  if (!RegExp(r'^Microsoft Server Speech Text to Speech Voice \(.+,.+\)$')
      .hasMatch(full)) {
    throw FormatException('音色名转换结果非法：$shortName');
  }
  return full;
}

/// 校验 `prosody` 参数（`data_classes.py:74-76`）：**必须带符号**。
String validateProsody(String kind, String value, RegExp pattern) {
  if (!pattern.hasMatch(value)) {
    throw FormatException('Invalid $kind "$value".');
  }
  return value;
}

/// 构造 SSML 主体。**不含**报文头（报文头见 `encodeSsmlFrame`）。
///
/// [voice] 传短名也可以：内部会转全名。[escapeText] 为 false 时表示
/// 调用方已经转义过（分块路径就是先切再转义，见 `edge_engine`）。
String buildSsml({
  required String voice,
  required String text,
  String rate = kEdgeDefaultRate,
  String volume = kEdgeDefaultVolume,
  String pitch = kEdgeDefaultPitch,
  bool escapeText = true,
}) {
  validateProsody('rate', rate, kEdgeRatePattern);
  validateProsody('volume', volume, kEdgeRatePattern);
  validateProsody('pitch', pitch, kEdgePitchPattern);
  final full = voice.contains('(') ? voice : azureVoiceName(voice);
  return '<speak version=\'1.0\' xmlns=\'http://www.w3.org/2001/10/synthesis\' '
      'xml:lang=\'en-US\'>'
      '<voice name=\'$full\'>'
      '<prosody pitch=\'$pitch\' rate=\'$rate\' volume=\'$volume\'>'
      '${escapeText ? ssmlEscapeText(text) : text}'
      '</prosody>'
      '</voice>'
      '</speak>';
}

/// 把文本切成若干 `[start, end)` 区间，使每块的**转义后 UTF-8 字节数** ≤ [maxBytes]。
///
/// 与上游的三点差异（都是说明书点名的缺陷修复）：
/// 1. 上游先转义再按字节切，于是必须回头保护 `&amp;`；这里在字符空间切、
///    按转义后的字节数核算预算，实体天然不会被劈开；
/// 2. 上游的 UTF-8 安全切点把**整个剩余文本**传进去（`communicate.py:235`），
///    无空格长中文段会得到 `len(text)` → 产出远超 4096 字节的单块。这里切点只允许
///    落在窗口 `[start, hi)` 内，因此**结构上不可能超限**；
/// 3. 上游对块做 `strip()` 后丢弃坐标；这里把首尾空白直接从区间里扣掉，
///    坐标仍然指向原文（`job.text` 的下标）。
List<EdgeSpeakRange> splitSpeakRanges(
  String text, {
  int maxBytes = kEdgeMaxChunkBytes,
}) {
  if (text.isEmpty) return const <EdgeSpeakRange>[];
  final budget = maxBytes > 0 ? maxBytes : kEdgeMaxChunkBytes;
  final ranges = <EdgeSpeakRange>[];
  var start = 0;
  while (start < text.length) {
    final hi = _windowEnd(text, start, budget);
    // 剩余文本整体落在预算内就不再找切点：在空格处提前断开只会多开一条连接，
    // 而 Edge 每块都要新建一条 WSS，多开连接是本引擎最贵的操作。
    var cut = hi >= text.length ? hi : _splitPointWithin(text, start, hi);
    cut = _outsideEntity(text, start, cut);
    if (cut <= start) {
      // 防死循环：至少推进一个完整的码点（代理对不能只走一半）。
      cut = start + _codePointLen(text, start);
    }
    final from = _skipBlanks(text, start);
    final to = _trimBlanksBack(text, from, cut);
    if (to > from) ranges.add(EdgeSpeakRange(from, to));
    start = cut;
  }
  return ranges;
}

/// 单个字符转义后的 UTF-8 字节数。
///
/// 代理对按两个 code unit 各计 2 字节 = 4 字节，与码点本身（≥U+10000）的
/// UTF-8 长度一致，所以可以逐 code unit 累加而不必先解码。
int escapedCharBytes(String ch) {
  switch (ch) {
    case '&':
      return 5; // &amp;
    case '<':
      return 4; // &lt;
    case '>':
      return 4; // &gt;
    default:
      final code = ch.codeUnitAt(0);
      if (code < 0x80) return 1;
      if (code < 0x800) return 2;
      if (_isHighSurrogate(code)) return 2; // 与配对的低位各 2
      if (_isLowSurrogate(code)) return 2;
      return 3;
  }
}

/// 从 [at] 开始的**整个码点**转义后的字节数。
///
/// 分块预算必须走这个口径：`escapedCharBytes` 是逐码元的，代理对只会被算成 2 字节，
/// 于是含 emoji 的块实际能到预算的两倍 —— 与上游「按剩余文本找切点」是同一类越界。
int escapedCodePointBytes(String text, int at) {
  final len = _codePointLen(text, at);
  var sum = 0;
  for (var i = 0; i < len; i++) {
    sum += escapedCharBytes(text[at + i]);
  }
  return sum;
}

/// 转义后整段的 UTF-8 字节数（测试与预算都走它，避免和 `utf8.encode` 两套口径）。
int escapedUtf8Bytes(String text) {
  var sum = 0;
  for (var i = 0; i < text.length; i++) {
    sum += escapedCharBytes(text[i]);
  }
  return sum;
}

/// JS `Date.toString()` 风格的时间戳（`communicate.py:288-301`）。
///
/// `%d` **零填充**；括号里的时区名是 UTC 全称。SSML 帧还要在它后面再加一个 `Z`
/// （微软的 bug，不是笔误），那一处写在 `encodeSsmlFrame` 里。
String jsStyleDate(DateTime now) {
  final utc = now.toUtc();
  final day = utc.day.toString().padLeft(2, '0');
  String two(int v) => v.toString().padLeft(2, '0');
  return '${_weekdays[utc.weekday - 1]} ${_months[utc.month - 1]} $day ${utc.year} '
      '${two(utc.hour)}:${two(utc.minute)}:${two(utc.second)} '
      'GMT+0000 (Coordinated Universal Time)';
}

/// 窗口内能容纳的最大字符终点（不含）：按转义后的字节数累加。
int _windowEnd(String text, int start, int budget) {
  var bytes = 0;
  var i = start;
  while (i < text.length) {
    final size = escapedCodePointBytes(text, i);
    if (i > start && bytes + size > budget) break;
    bytes += size;
    i += _codePointLen(text, i);
    if (bytes >= budget) break;
  }
  return i > start ? i : start + _codePointLen(text, start);
}

/// 优先在窗口内取**最靠后**的换行，其次空格（`_find_last_newline_or_space_within_limit`），
/// 都没有就用窗口末端（并回退到合法码点边界）。
int _splitPointWithin(String text, int start, int hi) {
  for (var i = hi - 1; i > start; i--) {
    if (text[i] == '\n') return i + 1;
  }
  for (var i = hi - 1; i > start; i--) {
    if (text[i] == ' ') return i + 1;
  }
  return _codePointSafeBack(text, hi);
}

/// 切点落在 `&...` 未闭合中间时前移到 `&` 之前（循环，防 `&amp` 套 `&lt`）。
///
/// 对**源文本本身**含实体的情况才起作用（例如章节里直接写了 `&amp;`）；
/// 由转义产生的实体已被字节预算整体预留，切不开。
int _outsideEntity(String text, int start, int cut) {
  var at = cut;
  while (at > start) {
    final amp = text.lastIndexOf('&', at - 1);
    if (amp < start) break;
    final semi = text.indexOf(';', amp);
    // 两种「不必回避」：①后面根本没有分号 —— 这是裸 &，转义后是完整的
    // `&amp;`，劈不到它；②分号已在块内闭合 —— 实体整段落在本块里。
    // 只有分号跑到切点之后（实体会被劈开）才把切点退到 & 之前。
    if (semi == -1 || semi < at) break;
    at = amp;
  }
  return at;
}

/// 码点安全的回退：切点不能落在代理对中间。
int _codePointSafeBack(String text, int at) {
  if (at <= 0 || at >= text.length) return at;
  return _isLowSurrogate(text.codeUnitAt(at)) ? at - 1 : at;
}

int _codePointLen(String text, int at) =>
    at + 1 < text.length &&
        _isHighSurrogate(text.codeUnitAt(at)) &&
        _isLowSurrogate(text.codeUnitAt(at + 1))
    ? 2
    : 1;

bool _isHighSurrogate(int code) => code >= 0xD800 && code <= 0xDBFF;
bool _isLowSurrogate(int code) => code >= 0xDC00 && code <= 0xDFFF;

int _skipBlanks(String text, int from) {
  var i = from;
  while (i < text.length && _isBlank(text.codeUnitAt(i))) {
    i++;
  }
  return i;
}

int _trimBlanksBack(String text, int from, int to) {
  var end = to;
  while (end > from && _isBlank(text.codeUnitAt(end - 1))) {
    end--;
  }
  return end;
}

bool _isBlank(int code) =>
    code == 0x20 || code == 0x09 || code == 0x0A || code == 0x0D;

const List<String> _weekdays = <String>[
  'Mon',
  'Tue',
  'Wed',
  'Thu',
  'Fri',
  'Sat',
  'Sun',
];

const List<String> _months = <String>[
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];
