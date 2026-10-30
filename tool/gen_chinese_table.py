"""生成 lib/core/reader/chinese_table.dart。

数据源：pip install zhconv （zhconv 自带 zh2Hans / zh2TW 字典）。
只导出「单字映射」与「2~4 字词表」，产物是纯 Dart 常量，运行时零依赖。

用法：
    pip install zhconv
    python tool/gen_chinese_table.py
"""
import io
import os

import zhconv.zhconv as zz

OUT = os.path.join('lib', 'core', 'reader', 'chinese_table.dart')


def is_bmp(text):
    """只保留 BMP 内的字符。

    单字表是「两条并行字符串按 UTF-16 code unit 逐位配对」的紧凑表示；
    一旦某侧出现扩展区汉字（surrogate pair 占两个 unit），配对就会整体错位。
    生僻扩展区字对小说阅读几乎无影响，直接跳过。
    """
    return all(ord(ch) <= 0xFFFF for ch in text)


def pairs(locale):
    table = zz.getdict(locale)
    single = {}
    words = {}
    for src, dst in table.items():
        if src == dst:
            continue
        if not is_bmp(src) or not is_bmp(dst):
            continue
        if len(src) == 1:
            single[src] = dst
        elif 2 <= len(src) <= 4 and len(dst) <= 4:
            words[src] = dst
    return single, words


def dart_literal(text):
    out = []
    for ch in text:
        if ch == '\\':
            out.append('\\\\')
        elif ch == "'":
            out.append("\\'")
        elif ch == '$':
            out.append('\\$')
        elif ch == '\n':
            out.append('\\n')
        elif ch == '\r':
            out.append('\\r')
        else:
            out.append(ch)
    return ''.join(out)


def emit_string_map(name, mapping, key_sorted):
    src = ''.join(k for k in key_sorted)
    dst = ''.join(mapping[k] for k in key_sorted)
    return (
        f"const String {name}From = '{dart_literal(src)}';\n\n"
        f"const String {name}To = '{dart_literal(dst)}';\n\n"
    )


def emit_word_lists(name, mapping, key_sorted):
    keys = ', '.join(f"'{dart_literal(k)}'" for k in key_sorted)
    values = ', '.join(f"'{dart_literal(mapping[k])}'" for k in key_sorted)
    return (
        f"const List<String> {name}Keys = <String>[{keys}];\n\n"
        f"const List<String> {name}Values = <String>[{values}];\n\n"
    )


def build():
    t2s_single, t2s_words = pairs('zh-cn')
    s2t_single, s2t_words = pairs('zh-tw')

    # 长词优先：转换时按 4→2 字尝试，这里按长度降序再按字典序稳定输出。
    t2s_keys = sorted(t2s_words, key=lambda w: (-len(w), w))
    s2t_keys = sorted(s2t_words, key=lambda w: (-len(w), w))

    header = (
        '// GENERATED FILE — do not edit by hand.\n'
        '// Run `python tool/gen_chinese_table.py` to regenerate.\n'
        '//\n'
        '// Data source: zhconv (zh2Hans / zh2TW). Single-character maps are stored as\n'
        '// two parallel strings and rebuilt into a Map<int, int> on first use; the\n'
        '// word lists keep long entries first so 词表优先于单字表.\n'
        '//\n'
        '// ignore_for_file: lines_longer_than_80_chars\n'
        '\n'
    )

    body = []
    body.append(emit_string_map('kT2s', t2s_single, sorted(t2s_single)))
    body.append(emit_string_map('kS2t', s2t_single, sorted(s2t_single)))
    body.append(emit_word_lists('kT2sWord', t2s_words, t2s_keys))
    body.append(emit_word_lists('kS2tWord', s2t_words, s2t_keys))

    text = header + ''.join(body)
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with io.open(OUT, 'w', encoding='utf-8', newline='\n') as f:
        f.write(text)
    print(
        'wrote', OUT,
        't2s', len(t2s_single), '+', len(t2s_words), 'words',
        's2t', len(s2t_single), '+', len(s2t_words), 'words',
        'size', len(text),
    )


if __name__ == '__main__':
    build()
