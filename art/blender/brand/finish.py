"""Finishes the 2x brand renders (art/out/brand/raw/) into the shipped files in art/out/brand/.
Run with the system python3:

    python3 art/blender/brand/finish.py

Logo.png       1024x512 transparent: one smooth thick white sticker contour round the whole wordmark,
               a light lilac sticker edge under it and a clean soft drop shadow
LogoSmall.png  512x256 transparent: Logo.png scaled down
LogoShine.png  1024x512, white everywhere; alpha = the opaque sticker of Logo.png (letters, white contour
               and lilac edge, no drop shadow) pulled in 2 px. Drawn over the logo with a moving gradient
               band for the shine sweep, so it lines up with Logo.png pixel for pixel
TitleCard.png  1024x576 transparent: plaque with a soft drop shadow
KeyArt.png     1024x576 opaque
"""

import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "vfx"))
from PIL import ImageChops  # noqa: E402

from imgutil import Image, ImageFilter, bleed, ck, dilate, erode, np, resize_rgba  # noqa: E402

OUT = os.path.join(ck.ROOT, "art", "out", "brand")
RAW = os.path.join(OUT, "raw")


def path(name, raw=False):
    return os.path.join(RAW if raw else OUT, name + ".png")


def _layer(mask, rgb, alpha=1.0):
    lay = Image.new("RGBA", mask.size, tuple(rgb) + (0,))
    lay.putalpha(mask.point(lambda v: int(v * alpha)))
    return lay


def _mask(arr):
    return Image.fromarray((np.clip(arr, 0, 1) * 255).astype(np.uint8))


def logo_sticker(im, scale=1.0):
    """One smooth, even white contour round the whole logo: a morphological closing (radius 160 px at
    2048 wide) fills the gaps between letters, lines and the dumbbell, then the outline sits 44 px out
    from the letters. Done at quarter size, smoothed back up. Then a lilac sticker edge below it and a
    soft Ink drop shadow. Returns the sticker and the mask of its opaque part (everything but the shadow)."""
    a = np.asarray(im.getchannel("A"), dtype=np.float32) / 255.0
    q = 4
    small = im.getchannel("A").resize((im.width // q, im.height // q), Image.BOX)
    m = np.clip((np.asarray(small, dtype=np.float32) / 255.0 - 0.1) / 0.8, 0, 1)
    r1, rout = 40 * scale, 11 * scale
    closed = erode(dilate(m, r1), r1 - rout)
    up = _mask(closed).resize(im.size, Image.BILINEAR).filter(ImageFilter.GaussianBlur(3 * q * scale))
    up = np.asarray(up, dtype=np.float32) / 255.0
    sil = np.maximum(np.clip((up - 0.5) * 6 + 0.5, 0, 1), a)
    silm = _mask(sil)
    canvas = Image.new("RGBA", im.size, (0, 0, 0, 0))
    shadow = Image.new("L", im.size, 0)
    shadow.paste(silm, (0, int(22 * scale)))
    canvas.alpha_composite(_layer(shadow.filter(ImageFilter.GaussianBlur(9 * scale)), ck.PALETTE.get("Ink", (58, 48, 96)), 0.34))
    edge = Image.new("L", im.size, 0)
    edge.paste(silm, (0, int(9 * scale)))
    canvas.alpha_composite(_layer(edge, (214, 216, 240)))
    canvas.alpha_composite(_layer(silm, (255, 255, 255)))
    canvas.alpha_composite(im)
    return canvas, ImageChops.lighter(silm, edge)


def enclosed_holes(im, thresh=128):
    """Number of transparent regions fully enclosed by the logo (open letter counters)."""
    small = im.getchannel("A").resize((im.width // 2, im.height // 2))
    m = (np.asarray(small) < thresh).astype(np.uint8) * 255
    img = Image.fromarray(m).copy()
    from PIL import ImageDraw

    ImageDraw.floodfill(img, (0, 0), 128)
    holes = 0
    arr = np.asarray(img).copy()
    while True:
        ys, xs = np.nonzero(arr == 255)
        if len(ys) == 0:
            return holes
        img = Image.fromarray(arr).copy()
        ImageDraw.floodfill(img, (int(xs[0]), int(ys[0])), 128)
        arr = np.asarray(img).copy()
        holes += 1


if __name__ == "__main__":
    raw_logo = Image.open(path("Logo", True)).convert("RGBA")
    print("logo letter counters:", enclosed_holes(raw_logo), "(expect 8: A D A R A O O O)")
    # Outline on a roomier canvas, then crop to the sticker and fit it into 2048 x 1024 (contain).
    w, h = raw_logo.size
    roomy = Image.new("RGBA", (int(w * 1.3), int(h * 1.3)), (0, 0, 0, 0))
    roomy.paste(raw_logo, ((roomy.width - w) // 2, (roomy.height - h) // 2))
    big, solid = logo_sticker(roomy, w / 2048)
    x0, y0, x1, y1 = big.getchannel("A").point(lambda v: 255 if v > 2 else 0).getbbox()
    m = int(0.02 * w)
    box = (x0 - m, y0 - m, x1 + m, y1 + m)
    big = big.crop(box)
    k = min(w / big.width, h / big.height)
    big = resize_rgba(big, (round(big.width * k), round(big.height * k)))
    fit = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    fit.paste(big, ((w - big.width) // 2, (h - big.height) // 2))
    logo = bleed(resize_rgba(fit, (1024, 512)))
    logo.save(path("Logo"))
    bleed(resize_rgba(fit, (512, 256))).save(path("LogoSmall"))

    # Shine mask: the opaque sticker through the same crop / fit / downscale as the logo, pulled in 2 px
    # (erode radius 3 moves the anti-aliased edge by 2) and kept under the logo's own alpha so the shine
    # never pokes past the logo edge. RGB is white on every
    # pixel, so there is nothing for bleed() to fill.
    fit_solid = Image.new("L", (w, h), 0)
    fit_solid.paste(solid.crop(box).resize(big.size, Image.LANCZOS), ((w - big.width) // 2, (h - big.height) // 2))
    sm = np.asarray(fit_solid.resize((1024, 512), Image.LANCZOS), dtype=np.float32) / 255.0
    shine = Image.new("RGBA", (1024, 512), (255, 255, 255, 0))
    shine.putalpha(_mask(np.minimum(erode(sm, 3), np.asarray(logo.getchannel("A"), dtype=np.float32) / 255.0)))
    shine.save(path("LogoShine"))

    resize_rgba(Image.open(path("TitleCard", True)), (1024, 576)).save(path("TitleCard_1x", True))
    ck.sticker(path("TitleCard_1x", True), path("TitleCard_shadow", True), outline=0, shadow=True, shadow_alpha=0.34)
    bleed(Image.open(path("TitleCard_shadow", True)).convert("RGBA")).save(path("TitleCard"))

    Image.open(path("KeyArt", True)).convert("RGB").resize((1024, 576), Image.LANCZOS).save(path("KeyArt"))
    for n in ("Logo", "LogoSmall", "LogoShine", "TitleCard", "KeyArt"):
        print("wrote", path(n))
