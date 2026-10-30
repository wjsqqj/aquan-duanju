"""生成阅读器内置背景纹理（webp，低调低对比，适合长时间阅读）。

产物：assets/reader/backgrounds/{paper,wood,linen,mist,charcoal}.webp
用法：pip install pillow numpy && python tool/gen_reader_backgrounds.py
"""
import os

import numpy as np
from PIL import Image, ImageFilter

OUT_DIR = os.path.join('assets', 'reader', 'backgrounds')
W, H = 720, 1600


def base(color):
    arr = np.zeros((H, W, 3), dtype=np.float32)
    arr[:, :] = color
    return arr


def add_noise(arr, amount):
    rng = np.random.default_rng(7)
    noise = rng.normal(0.0, amount, (H, W, 1)).astype(np.float32)
    return np.clip(arr + noise, 0, 255)


def smooth_noise(scale, seed):
    rng = np.random.default_rng(seed)
    small = rng.normal(0.0, 1.0, (max(2, H // scale), max(2, W // scale)))
    spread = float(small.max() - small.min()) + 1e-6
    img = Image.fromarray((((small - small.min()) / spread) * 255).astype(np.uint8))
    img = img.resize((W, H), Image.BICUBIC)
    return (np.asarray(img, dtype=np.float32) / 255.0 - 0.5)


def save(arr, name, quality=78):
    os.makedirs(OUT_DIR, exist_ok=True)
    path = os.path.join(OUT_DIR, name + '.webp')
    img = Image.fromarray(np.clip(arr, 0, 255).astype(np.uint8))
    img.save(path, 'WEBP', quality=quality, method=6)
    print(name, os.path.getsize(path), 'bytes')


def paper():
    arr = base((246, 241, 228))
    fibers = smooth_noise(3, 11) * 6.0
    blotch = smooth_noise(90, 12) * 4.0
    arr += fibers[..., None] + blotch[..., None]
    arr = add_noise(arr, 2.2)
    save(arr, 'paper')


def wood():
    x = np.linspace(0, 1, W)[None, :]
    y = np.linspace(0, 1, H)[:, None]
    warp = smooth_noise(60, 21) * 0.35
    grain = np.sin((x * 18 + warp + 0.02 * np.sin(y * 6)) * np.pi)
    grain = (grain * 0.5 + 0.5) ** 2
    arr = base((238, 228, 212))
    arr += (grain[..., None] - 0.45) * 14.0
    arr = add_noise(arr, 1.8)
    save(arr, 'wood')


def linen():
    yy, xx = np.mgrid[0:H, 0:W].astype(np.float32)
    weave = (np.sin(xx / 2.6) * np.sin(yy / 2.6)) * 0.5 + 0.5
    arr = base((240, 236, 228))
    arr += (weave[..., None] - 0.5) * 9.0
    arr = add_noise(arr, 2.6)
    save(arr, 'linen')


def mist():
    arr = base((232, 238, 238))
    grad = np.linspace(-1, 1, H)[:, None, None] * 6.0
    arr = arr + grad
    arr += smooth_noise(120, 31)[..., None] * 5.0
    arr = add_noise(arr, 1.6)
    save(arr, 'mist')


def charcoal():
    arr = base((20, 20, 22))
    arr += smooth_noise(40, 41)[..., None] * 6.0
    arr = add_noise(arr, 2.0)
    img = Image.fromarray(np.clip(arr, 0, 255).astype(np.uint8))
    img = img.filter(ImageFilter.GaussianBlur(0.4))
    path = os.path.join(OUT_DIR, 'charcoal.webp')
    os.makedirs(OUT_DIR, exist_ok=True)
    img.save(path, 'WEBP', quality=74, method=6)
    print('charcoal', os.path.getsize(path), 'bytes')


if __name__ == '__main__':
    paper()
    wood()
    linen()
    mist()
    charcoal()
