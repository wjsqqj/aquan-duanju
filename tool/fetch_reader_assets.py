"""下载并子集化阅读器内置字体（霞鹜文楷）。

产物：assets/reader/fonts/LXGWWenKai-Regular.ttf
字符集：ASCII + GB2312 全部（6763 汉字 + 682 符号）+ 常用中文标点。
缺字时 Flutter 会回退到系统字体，不会出现方框。

用法：
    pip install fonttools
    python tool/fetch_reader_assets.py
"""
import io
import os
import sys
import urllib.request

FONT_URLS = [
    'https://cdn.jsdelivr.net/gh/lxgw/LxgwWenKai@v1.510/fonts/TTF/LXGWWenKai-Regular.ttf',
    'https://raw.githubusercontent.com/lxgw/LxgwWenKai/v1.510/fonts/TTF/LXGWWenKai-Regular.ttf',
]
OUT_DIR = os.path.join('assets', 'reader', 'fonts')
OUT_FONT = os.path.join(OUT_DIR, 'LXGWWenKai-Regular.ttf')
TMP_FONT = os.path.join(OUT_DIR, '_source.ttf')

EXTRA = (
    '　、。〃々〆〇〈〉《》「」『』【】〔〕〖〗〘〙〚〛〜〝〞〟'
    '〰〾〿–—‘’‛“”„‟…‧﹏'
    '·×÷±≈≠≤≥∞°′″℃％‰′'
    '①②③④⑤⑥⑦⑧⑨⑩'
)


def gb2312_chars():
    out = []
    for hi in range(0xA1, 0xF8):
        for lo in range(0xA1, 0xFF):
            try:
                out.append(bytes([hi, lo]).decode('gb2312'))
            except UnicodeDecodeError:
                continue
    return ''.join(out)


def download():
    os.makedirs(OUT_DIR, exist_ok=True)
    if os.path.exists(TMP_FONT) and os.path.getsize(TMP_FONT) > 5_000_000:
        print('reuse cached source font')
        return
    last = None
    for url in FONT_URLS:
        try:
            print('downloading', url)
            req = urllib.request.Request(url, headers={'User-Agent': 'Mozilla/5.0'})
            with urllib.request.urlopen(req, timeout=120) as resp:
                data = resp.read()
            if len(data) < 1_000_000:
                raise ValueError('too small: %d' % len(data))
            with open(TMP_FONT, 'wb') as f:
                f.write(data)
            print('downloaded', len(data), 'bytes')
            return
        except Exception as exc:  # noqa: BLE001
            last = exc
            print('failed:', exc)
    raise SystemExit('download failed: %s' % last)


def subset():
    from fontTools import subset as ft_subset

    text = ''.join(chr(c) for c in range(0x20, 0x7F)) + gb2312_chars() + EXTRA
    text = ''.join(sorted(set(text)))

    options = ft_subset.Options()
    options.layout_features = ['*']
    options.hinting = False
    options.desubroutinize = True
    options.name_IDs = ['*']
    options.notdef_outline = True
    options.recalc_bounds = True

    font = ft_subset.load_font(TMP_FONT, options)
    subsetter = ft_subset.Subsetter(options=options)
    subsetter.populate(text=text)
    subsetter.subset(font)
    ft_subset.save_font(font, OUT_FONT, options)

    size = os.path.getsize(OUT_FONT)
    print('subset glyphs', len(text), 'size', size, 'bytes ->', OUT_FONT)
    if size > 6 * 1024 * 1024:
        print('WARNING: font still large, consider trimming EXTRA')


if __name__ == '__main__':
    download()
    subset()
    try:
        os.remove(TMP_FONT)
    except OSError:
        pass
    sys.exit(0)
