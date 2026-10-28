#!/usr/bin/env python3
"""生成阿圈短剧的应用图标源图（1024×1024 PNG）。

设计：暖橙渐变圆角方块（与 App 主题色一致的观感）+ 白色「圈」字（微软雅黑粗体）
+ 右上一枚小播放三角，暗示「看剧」。
产物：assets/icon/icon.png（flutter_launcher_icons 的输入）。
"""

from __future__ import annotations

from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

REPO = Path(__file__).resolve().parent.parent
OUT = REPO / "assets" / "icon" / "icon.png"
FONT = Path(r"C:\Windows\Fonts\msyhbd.ttc")  # 微软雅黑 Bold

SIZE = 1024
RADIUS = 180


def rounded_gradient(size: int, radius: int) -> Image.Image:
    """对角渐变（浅橙 → 深橙）裁进圆角矩形。"""
    top_left = (255, 158, 88)
    bottom_right = (240, 96, 40)
    base = Image.new("RGB", (size, size))
    px = base.load()
    for y in range(size):
        for x in range(size):
            t = (x + y) / (2 * size)
            px[x, y] = tuple(
                int(a + (b - a) * t) for a, b in zip(top_left, bottom_right)
            )
    mask = Image.new("L", (size, size), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        [0, 0, size - 1, size - 1], radius=radius, fill=255
    )
    icon = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    icon.paste(base, (0, 0), mask)
    return icon


def main() -> None:
    icon = rounded_gradient(SIZE, RADIUS)
    draw = ImageDraw.Draw(icon)

    # 主体「圈」字，垂直略上移给底部留白。
    font = ImageFont.truetype(str(FONT), int(SIZE * 0.58))
    text = "圈"
    left, top, right, bottom = draw.textbbox((0, 0), text, font=font)
    draw.text(
        ((SIZE - (right - left)) / 2 - left, (SIZE - (bottom - top)) / 2 - top - SIZE * 0.03),
        text,
        font=font,
        fill=(255, 255, 255, 255),
    )

    # 右下角播放三角，弱化白。
    tri = int(SIZE * 0.11)
    cx, cy = int(SIZE * 0.78), int(SIZE * 0.80)
    draw.polygon(
        [(cx - tri // 2, cy - tri), (cx - tri // 2, cy + tri), (cx + tri, cy)],
        fill=(255, 255, 255, 220),
    )

    OUT.parent.mkdir(parents=True, exist_ok=True)
    icon.save(OUT, "PNG")
    print(f"written {OUT}")


if __name__ == "__main__":
    main()
