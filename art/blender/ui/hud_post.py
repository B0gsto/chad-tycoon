"""Post step for hud_dumbbell.py (system python3 + Pillow, called by it after the renders).

- Sticker outline + drop shadow on both raw renders (chadkit.sticker), violet glow on the Glow one.
- Measures the panel and its flat face from the mask renders and writes art/out/ui/HudDumbbell.json:
  { "size": [w, h], "plaque": [x, y, w, h], "face": [...], "caption": [...], "number": [...] }
  (image pixels, top-left origin). caption = the small "AURA" line (30% of the panel height),
  number = the big value line (55%), both inside the flat face.
- Contact sheets art/out/ui/sheet_hud_dumbbell.png and sheet_hud_dumbbell_small.png.
"""

import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "lib"))

import numpy as np  # noqa: E402
from PIL import Image, ImageDraw, ImageFilter  # noqa: E402

import chadkit as ck  # noqa: E402

OUT = os.path.join(ck.ROOT, "art", "out", "ui")
RAW = os.path.join(OUT, "raw")
OUTLINE = 0.009  # 9 px at 1024 wide: the icon set's sticker weight at the HUD's on-screen size
GLOW_RGB = (176, 124, 255)


def bbox(path):
    a = np.asarray(Image.open(path).getchannel("A")) > 127
    ys, xs = np.nonzero(a)
    return [int(xs.min()), int(ys.min()), int(xs.max() - xs.min() + 1), int(ys.max() - ys.min() + 1)]


def glow(src, dst):
    im = Image.open(src).convert("RGBA")
    a = im.getchannel("A")
    canvas = Image.new("RGBA", im.size, (0, 0, 0, 0))
    for radius, strength in ((12, 0.75), (5, 0.9)):
        g = np.asarray(a.filter(ImageFilter.GaussianBlur(radius)), dtype=np.float32) / 255.0
        layer = Image.new("RGBA", im.size, GLOW_RGB + (0,))
        layer.putalpha(Image.fromarray((np.clip(g * 1.7, 0, 1) * strength * 255).astype(np.uint8), "L"))
        canvas.alpha_composite(layer)
    canvas.alpha_composite(im)
    canvas.save(dst)


def busy(w, h):
    """Screenshot-like busy backdrop: sky-to-sand gradient with blobs and stripes."""
    y = np.linspace(0, 1, h)[:, None, None]
    x = np.linspace(0, 1, w)[None, :, None]
    top, bottom = np.array([120, 190, 255]), np.array([236, 206, 150])
    arr = top * (1 - y) + bottom * y + 40 * np.sin(x * 18 + y * 6)
    im = Image.fromarray(np.clip(arr, 0, 255).astype(np.uint8), "RGB").convert("RGBA")
    d = ImageDraw.Draw(im)
    for i, col in enumerate([(255, 120, 150), (90, 210, 140), (255, 210, 80), (130, 100, 230), (255, 255, 255)]):
        cx = 60 + i * 210
        d.ellipse([cx - 50, h * 0.3 - 50 + i * 12, cx + 50, h * 0.3 + 50 + i * 12], fill=col + (255,))
        d.rectangle([cx - 90, h - 40 - i * 6, cx + 20, h - 20 - i * 6], fill=col[::-1] + (255,))
    return im


def sheets(normal, glow_path, rects):
    pad = 24
    blue, sand = (52, 96, 200, 255), (240, 214, 160, 255)
    img, gim = Image.open(normal), Image.open(glow_path)
    w, h = img.size
    marked = img.copy()
    d = ImageDraw.Draw(marked)
    for key, col in (("plaque", (255, 230, 0)), ("caption", (0, 255, 120)), ("number", (255, 60, 60))):
        x, y, rw, rh = rects[key]
        d.rectangle([x, y, x + rw - 1, y + rh - 1], outline=col + (255,), width=2)
    small_h = round(h * 220 / w)
    strip_h = small_h * 2 + pad * 3
    sheet = Image.new("RGBA", (w + 2 * pad, 3 * (h + pad) + strip_h + pad), (30, 30, 40, 255))
    for i, (bg, im) in enumerate(((blue, marked), (sand, img), (blue, gim))):
        tile = Image.new("RGBA", (w, h), bg)
        tile.alpha_composite(im)
        sheet.alpha_composite(tile, (pad, pad + i * (h + pad)))
    strip = busy(w, strip_h)
    for j, im in enumerate((img, gim)):  # both at the HUD size, the normal one also at 2x
        strip.alpha_composite(im.resize((220, small_h), Image.LANCZOS), (pad, pad + j * (small_h + pad)))
    sm = img.resize((220, small_h), Image.LANCZOS)
    strip.alpha_composite(sm.resize((440, small_h * 2), Image.NEAREST), (pad + 280, pad))
    sheet.alpha_composite(strip, (pad, pad + 3 * (h + pad)))
    out = os.path.join(OUT, "sheet_hud_dumbbell.png")
    sheet.convert("RGB").save(out)
    s = 1024 / max(sheet.size)
    sheet.convert("RGB").resize((round(sheet.width * s), round(sheet.height * s)), Image.LANCZOS).save(
        os.path.join(OUT, "sheet_hud_dumbbell_small.png"))


def main():
    normal = os.path.join(OUT, "HudDumbbell.png")
    glow_path = os.path.join(OUT, "HudDumbbellGlow.png")
    ck.sticker(os.path.join(RAW, "HudDumbbell_raw.png"), normal, OUTLINE)
    tmp = os.path.join(RAW, "HudDumbbellGlow_sticker.png")
    ck.sticker(os.path.join(RAW, "HudDumbbellGlow_raw.png"), tmp, OUTLINE)
    glow(tmp, glow_path)

    size = list(Image.open(normal).size)
    plaque = bbox(os.path.join(RAW, "HudDumbbell_mask_panel.png"))
    face = bbox(os.path.join(RAW, "HudDumbbell_mask_face.png"))
    px, py, pw, ph = plaque
    fx, fw = face[0], face[2]
    inset = round(fw * 0.04)
    rects = {
        "size": size,
        "plaque": plaque,
        "face": face,
        "caption": [fx + inset, py + round(ph * 0.07), fw - 2 * inset, round(ph * 0.30)],
        "number": [fx + inset, py + round(ph * 0.38), fw - 2 * inset, round(ph * 0.55)],
    }
    # flat face colour at the centre of the number line, for the HUD agent's text contrast
    rgba = Image.open(normal).getpixel((fx + fw // 2, py + round(ph * 0.65)))
    rects["faceColor"] = list(rgba[:3])
    with open(os.path.join(OUT, "HudDumbbell.json"), "w") as f:
        json.dump(rects, f, indent=1)
        f.write("\n")
    a = np.asarray(Image.open(glow_path).getchannel("A"))
    ys, xs = np.nonzero(a > 8)
    print("HUD_RECTS", json.dumps(rects))
    print("HUD_MARGIN glow alpha>8 bounds x", xs.min(), xs.max(), "y", ys.min(), ys.max())
    a = np.asarray(Image.open(normal).getchannel("A"))
    ys, xs = np.nonzero(a > 8)
    print("HUD_MARGIN normal alpha>8 bounds x", xs.min(), xs.max(), "y", ys.min(), ys.max())
    sheets(normal, glow_path, rects)


main()
