import 'chinese_table.dart';
import 'reader_settings.dart';

/// 一对多歧义字的保护词：这些词里的「乾」读 qián，不该转成「干」。
const Set<String> _kT2sKeep = <String>{
  '乾隆',
  '乾坤',
  '乾卦',
  '乾陵',
  '乾县',
  '乾清宫',
  '乾元',
  '乾嘉',
};

/// 繁简转换。纯 Dart，数据来自 `chinese_table.dart`（由 `tool/gen_chinese_table.py` 生成）。
///
/// 转换顺序：保护词 → 2~4 字词表（长词优先）→ 单字表 → 原样保留。
/// 词表优先是为了避免「乾隆 → 干隆」这类单字替换造成的误转。
class ChineseConverter {
  ChineseConverter._();

  static _Tables? _t2s;
  static _Tables? _s2t;

  static String convert(String text, ChineseConvert mode) {
    if (mode == ChineseConvert.off || text.isEmpty) return text;
    final tables = mode == ChineseConvert.t2s
        ? (_t2s ??= _Tables.build(kT2sFrom, kT2sTo, kT2sWordKeys, kT2sWordValues,
            keep: _kT2sKeep))
        : (_s2t ??= _Tables.build(kS2tFrom, kS2tTo, kS2tWordKeys, kS2tWordValues));
    return tables.translate(text);
  }

  /// 是否有可转换的内容（UI 用来提示「本章无需转换」）。
  static bool hasWork(String text, ChineseConvert mode) {
    if (mode == ChineseConvert.off || text.isEmpty) return false;
    final tables = mode == ChineseConvert.t2s ? _t2s : _s2t;
    final chars = mode == ChineseConvert.t2s ? kT2sFrom : kS2tFrom;
    if (tables == null) {
      for (var i = 0; i < text.length; i++) {
        if (chars.contains(text[i])) return true;
      }
      return false;
    }
    return tables.containsAny(text);
  }
}

class _Tables {
  _Tables._(this.chars, this.wordMap, this.wordFirst, this.maxWordLen,
      this.keepWords);

  final Map<int, int> chars;
  final Map<String, String> wordMap;
  final Set<int> wordFirst;
  final int maxWordLen;

  /// 原样保留的词（歧义保护）。
  final Set<String> keepWords;

  static _Tables build(
    String from,
    String to,
    List<String> wordKeys,
    List<String> wordValues, {
    Set<String> keep = const <String>{},
  }) {
    final chars = <int, int>{};
    final length = from.length < to.length ? from.length : to.length;
    for (var i = 0; i < length; i++) {
      chars[from.codeUnitAt(i)] = to.codeUnitAt(i);
    }
    final wordMap = <String, String>{};
    final wordFirst = <int>{};
    var maxWordLen = 0;
    for (var i = 0; i < wordKeys.length && i < wordValues.length; i++) {
      final key = wordKeys[i];
      if (key.isEmpty) continue;
      wordMap[key] = wordValues[i];
      wordFirst.add(key.codeUnitAt(0));
      if (key.length > maxWordLen) maxWordLen = key.length;
    }
    for (final word in keep) {
      wordFirst.add(word.codeUnitAt(0));
      if (word.length > maxWordLen) maxWordLen = word.length;
    }
    return _Tables._(chars, wordMap, wordFirst, maxWordLen, keep);
  }

  String translate(String text) {
    final buffer = StringBuffer();
    var i = 0;
    final length = text.length;
    while (i < length) {
      final first = text.codeUnitAt(i);
      // 只有首字可能出现在词表里才做词匹配，避免每字符 3 次 substring。
      if (wordFirst.contains(first)) {
        var matched = false;
        final maxLen = maxWordLen < length - i ? maxWordLen : length - i;
        for (var len = maxLen; len >= 2; len--) {
          final candidate = text.substring(i, i + len);
          if (keepWords.contains(candidate)) {
            buffer.write(candidate);
            i += len;
            matched = true;
            break;
          }
          final mapped = wordMap[candidate];
          if (mapped != null) {
            buffer.write(mapped);
            i += len;
            matched = true;
            break;
          }
        }
        if (matched) continue;
      }
      final mapped = chars[first];
      if (mapped != null) {
        buffer.writeCharCode(mapped);
      } else {
        buffer.writeCharCode(first);
      }
      i++;
    }
    return buffer.toString();
  }

  bool containsAny(String text) {
    for (var i = 0; i < text.length; i++) {
      if (chars.containsKey(text.codeUnitAt(i))) return true;
      if (wordFirst.contains(text.codeUnitAt(i))) return true;
    }
    return false;
  }
}
