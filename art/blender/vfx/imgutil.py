"""Pillow helpers for the sprite / branding finish steps (system python3, not Blender)."""

import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "lib"))
import chadkit as ck  # noqa: E402,F401

import numpy as np  # noqa: E402
from PIL import Image, ImageFilter  # noqa: E402


def resize_rgba(im, size):
    """Premultiplied-alpha resize (no dark fringes from transparent pixels)."""
    return im.convert("RGBA").convert("RGBa").resize(size, Image.LANCZOS).convert("RGBA")


def bleed(im, passes=6):
    """Fills the colour of fully transparent pixels with the colour of the nearest visible pixels, so
    texture filtering in the engine never pulls a dark fringe in from the transparent area."""
    a = np.asarray(im.convert("RGBA")).astype(np.float32)
    rgb, al = a[..., :3], a[..., 3:] / 255.0
    filled = rgb * (al > 0)
    known = (al > 0).astype(np.float32)
    for k in range(passes):
        r = 2 ** k
        pre = Image.fromarray(np.clip(filled * known, 0, 255).astype(np.uint8), "RGB").filter(ImageFilter.BoxBlur(r))
        w = Image.fromarray((known[..., 0] * 255).astype(np.uint8), "L").filter(ImageFilter.BoxBlur(r))
        pre = np.asarray(pre).astype(np.float32)
        w = np.asarray(w).astype(np.float32)[..., None] / 255.0
        est = pre / np.maximum(w, 1e-4)
        newly = (known[..., 0] == 0) & (w[..., 0] > 0.01)
        filled[newly] = est[newly]
        known[newly] = 1.0
    out = np.concatenate([np.clip(filled, 0, 255), a[..., 3:]], axis=-1).astype(np.uint8)
    return Image.fromarray(out, "RGBA")


def dilate(mask, radius):
    """Round, anti-aliased dilation of a float mask (0..1) by `radius` pixels (max over disc offsets)."""
    r = float(radius)
    ri = int(np.ceil(r + 0.5))
    h, w = mask.shape
    pad = np.zeros((h + 2 * ri, w + 2 * ri), dtype=np.float32)
    pad[ri:ri + h, ri:ri + w] = mask
    out = mask.astype(np.float32).copy()
    for dy in range(-ri, ri + 1):
        for dx in range(-ri, ri + 1):
            wgt = min(1.0, max(0.0, r + 0.5 - float(np.hypot(dx, dy))))
            if wgt > 0:
                np.maximum(out, pad[ri + dy:ri + dy + h, ri + dx:ri + dx + w] * wgt, out=out)
    return out


def erode(mask, radius):
    return 1.0 - dilate(1.0 - mask, radius)
