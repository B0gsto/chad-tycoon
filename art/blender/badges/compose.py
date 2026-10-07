"""Badge composer and contact sheet (system python3 with Pillow + numpy; called by badges.py).

    python3 compose.py --badge <subject.png> <out.png> <bg-name>   one opaque 512 px badge
    python3 compose.py --sheet                                     art/out/badges/sheet.png

A badge is a radial-gradient disc with soft sunburst rays, a glow behind the subject and a two-tone
rim ring just inside the circle Roblox crops to; the corners outside the circle carry the edge colour
so the square file is fully opaque. The subject (transparent sticker render) is scaled so every
visible pixel sits within SUBJECT_R of the centre (8 % margin plus the rim ring).
"""

import math
import os
import sys

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", ".."))
OUT = os.path.join(ROOT, "art", "out", "badges")
NAMES = ["Welcome", "GymGraduate", "CertifiedChad", "AbsoluteChad", "ParkourMaster"]
S = 512
RING_OUT, RING_IN = 0.955, 0.91  # rim ring radii (fraction of the half size)
SUBJECT_R = 0.855  # every subject pixel within this radius (inside the ring, > 8 % margin)

# centre colour, edge colour, ray tint, ring colour, ring edge, glow behind the subject (sRGB)
BG = {
    "welcome": ((255, 236, 130), (255, 150, 10), (255, 255, 220), (255, 255, 255), (232, 110, 16), (255, 255, 236)),
    "graduate": ((190, 255, 186), (20, 160, 98), (230, 255, 220), (255, 255, 255), (14, 110, 74), (245, 255, 240)),
    "certified": ((70, 150, 250), (16, 40, 140), (120, 210, 255), (255, 255, 255), (12, 30, 110), (90, 235, 255)),
    "absolute": ((180, 100, 255), (60, 18, 150), (255, 210, 100), (255, 208, 64), (190, 100, 16), (255, 214, 90)),
    "parkour": ((255, 196, 170), (236, 56, 92), (255, 236, 220), (255, 255, 255), (170, 30, 70), (255, 240, 225)),
}


def backdrop(name):
    c0, c1, ray, ring, ring_edge, glow_rgb = BG[name]
    y, x = np.mgrid[0:S, 0:S].astype(np.float32)
    cx = cy = (S - 1) / 2
    r = np.hypot(x - cx, y - cy) / (S / 2)
    t = np.clip(r / RING_IN, 0, 1) ** 1.35
    img = np.zeros((S, S, 3), np.float32)
    for i in range(3):
        img[..., i] = c0[i] * (1 - t) + c1[i] * t
    # Sunburst: 16 soft wedges, stronger toward the rim, gone at the centre.
    ang = np.arctan2(y - cy, x - cx) + math.radians(8)
    w = (np.cos(ang * 16) > 0.15).astype(np.float32)
    w = np.asarray(Image.fromarray((w * 255).astype(np.uint8)).filter(ImageFilter.GaussianBlur(1.2)),
                   np.float32) / 255
    k = w * np.clip((r - 0.12) / 0.5, 0, 1) * (0.30 if name != "absolute" else 0.26)
    for i in range(3):
        img[..., i] = img[..., i] * (1 - k) + ray[i] * k
    # Soft light pool behind the subject.
    glow = np.clip(1 - r / 0.68, 0, 1) ** 1.6 * (0.6 if name in ("certified", "absolute") else 0.45)
    for i in range(3):
        img[..., i] = img[..., i] * (1 - glow) + glow_rgb[i] * glow
    # Soft inner rim light just inside the ring.
    rim = np.clip(1 - np.abs(r - (RING_IN - 0.035)) / 0.04, 0, 1) ** 2 * 0.22
    for i in range(3):
        img[..., i] = img[..., i] * (1 - rim) + 255 * rim
    # Rim ring (bright band with a darker inner/outer line) and the outside in the edge colour.
    def band(a, b, soft=1.2):
        return np.clip((r * S / 2 - a * S / 2) / soft + 0.5, 0, 1) * np.clip((b * S / 2 - r * S / 2) / soft + 0.5, 0, 1)
    for (a, b, col) in ((RING_IN - 0.02, RING_OUT + 0.02, ring_edge), (RING_IN, RING_OUT, ring)):
        m = band(a, b)
        for i in range(3):
            img[..., i] = img[..., i] * (1 - m) + col[i] * m
    # Ring highlight: lighter on the upper left.
    hl = band(RING_IN + 0.012, RING_OUT - 0.012) * np.clip(-((x - cx) + (y - cy)) / S * 1.4, 0, 1) * 0.5
    for i in range(3):
        img[..., i] = img[..., i] * (1 - hl) + 255 * hl
    outside = np.clip((r * S / 2 - (RING_OUT + 0.02) * S / 2) / 1.2 + 0.5, 0, 1)
    for i in range(3):
        img[..., i] = img[..., i] * (1 - outside) + ring_edge[i] * outside
    return Image.fromarray(np.clip(img, 0, 255).astype(np.uint8), "RGB").convert("RGBA")


def fit_subject(path):
    """Crops the sticker to its visible pixels and scales it so the farthest one from the crop's
    centre lies at SUBJECT_R; returns (image, paste offset)."""
    im = Image.open(path).convert("RGBA")
    a = np.asarray(im.getchannel("A"), np.float32) / 255
    ys, xs = np.nonzero(a > 0.06)
    x0, x1, y0, y1 = xs.min(), xs.max() + 1, ys.min(), ys.max() + 1
    # Centre on (about) the smallest enclosing circle of the visible pixels, not the bounding box, so
    # odd shapes (a dumbbell on the diagonal) use the circle fully.
    px, py = xs[::7].astype(np.float32), ys[::7].astype(np.float32)
    bx, by = (x0 + x1) / 2, (y0 + y1) / 2
    gx, gy = np.meshgrid(np.linspace(-0.2, 0.2, 21) * (x1 - x0) + bx, np.linspace(-0.2, 0.2, 21) * (y1 - y0) + by)
    best = None
    for cx, cy in zip(gx.ravel(), gy.ravel()):
        far = np.hypot(px - cx, py - cy).max()
        if best is None or far < best[0]:
            best = (far, cx, cy)
    far, cx, cy = best
    far = max(far, np.hypot(xs - cx, ys - cy).max())
    scale = SUBJECT_R * S / 2 / far
    im = im.resize((max(1, round(im.width * scale)), max(1, round(im.height * scale))), Image.LANCZOS)
    return im, (round(S / 2 - cx * scale), round(S / 2 - cy * scale))


def badge(subject, out, name):
    bg = backdrop(name)
    sub, off = fit_subject(subject)
    bg.alpha_composite(sub, off)
    bg.convert("RGB").save(out)


def circle_crop(im, size):
    im = im.convert("RGBA").resize((size, size), Image.LANCZOS)
    m = Image.new("L", (size * 4, size * 4), 0)
    ImageDraw.Draw(m).ellipse((0, 0, size * 4 - 1, size * 4 - 1), fill=255)
    im.putalpha(m.resize((size, size), Image.LANCZOS))
    return im


def sheet():
    sys.path.insert(0, os.path.join(ROOT, "art", "blender", "lib"))
    import chadkit as ck

    paths = [os.path.join(OUT, n + ".png") for n in NAMES]
    missing = [p for p in paths if not os.path.exists(p)]
    if missing:
        sys.exit("missing badges: " + ", ".join(missing))
    bg = (40, 40, 56)
    big = ck.contact_sheet(paths, cols=5, labels=NAMES, cell=256, bg=bg, title="Badges @256 (square files)")
    ims = [Image.open(p) for p in paths]
    crop = ck.contact_sheet([circle_crop(i, 256) for i in ims], cols=5, cell=256, bg=bg,
                            title="Circle crop as Roblox shows it @256")
    def boxed(im, size):  # true-size crop centred in a 150 px cell (contact_sheet would upscale it)
        c = Image.new("RGBA", (150, 150), (0, 0, 0, 0))
        c.alpha_composite(circle_crop(im, size), ((150 - size) // 2, (150 - size) // 2))
        return c

    small = ck.contact_sheet([boxed(i, 64) for i in ims] + [circle_crop(i, 150) for i in ims], cols=5,
                             cell=(150, 150), bg=bg, title="Circle crop @64 and @150", gap=12)
    out = os.path.join(OUT, "sheet.png")
    ck.stack_images([big, crop, small], out, bg=bg, gap=8)
    print("sheet", out)


if __name__ == "__main__":
    if sys.argv[1] == "--badge":
        badge(*sys.argv[2:5])
    elif sys.argv[1] == "--sheet":
        sheet()
