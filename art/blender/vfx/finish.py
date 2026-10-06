"""Scales the 512 px sprite renders (art/out/vfx/raw/) to the shipped 256 px transparent PNGs in
art/out/vfx/<Name>.png, with colour bled into the transparent area. Run with the system python3:

    python3 art/blender/vfx/finish.py
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from imgutil import Image, ImageFilter, bleed, ck, np, resize_rgba  # noqa: E402

OUT = os.path.join(ck.ROOT, "art", "out", "vfx")
# Sprites whose silhouette edge is feathered inward (soft alpha falloff), with the blur radius at 512 px.
FEATHER = {"Puff": 9}

NAMES = ["Heart", "StarPop", "Sparkle", "SoftDot", "Ring", "Puff", "CoinSpin", "Confetti", "Note", "Sweat"]

def feather(im, radius):
    """Soft inward alpha falloff along the silhouette edge."""
    a = np.asarray(im.getchannel("A"), dtype=np.float32) / 255.0
    b = np.asarray(im.getchannel("A").filter(ImageFilter.GaussianBlur(radius)), dtype=np.float32) / 255.0
    k = np.clip((b - 0.42) / 0.5, 0.0, 1.0) ** 0.9
    out = im.copy()
    out.putalpha(Image.fromarray((a * k * 255).astype(np.uint8)))
    return out


if __name__ == "__main__":
    for n in NAMES:
        src = os.path.join(OUT, "raw", n + ".png")
        im = Image.open(src).convert("RGBA")
        if n in FEATHER:
            im = feather(im, FEATHER[n])
        im = resize_rgba(im, (256, 256))
        bleed(im).save(os.path.join(OUT, n + ".png"))
        print("wrote", os.path.join(OUT, n + ".png"))
