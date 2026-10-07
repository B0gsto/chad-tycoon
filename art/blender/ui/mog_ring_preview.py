"""Mock composite of the MOG TEST ring (art/out/ui/MogRing*.png) with the same layer, rotation and UIGradient
math as src/client/UI/MogRing.luau, for review without Studio.

Usage: python3 art/blender/ui/mog_ring_preview.py [out_dir]   (default /tmp/mogring) -> sheet.png, detail.png
"""

import math
import os
import sys

import numpy as np
from PIL import Image, ImageDraw, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
UI = os.path.abspath(os.path.join(HERE, "..", "..", "out", "ui"))
TEX = {}

CREAM = (255, 247, 232)
GOLD = (255, 212, 64)
GOLD_LIGHT = (255, 236, 150)
BAD = (255, 112, 100)
ZONE = (56, 232, 120)
PERFECT = (255, 210, 31)
TEXT = (255, 255, 255)
TEXT_DIM = (212, 224, 255)
WHITE = (255, 255, 255)
DIM = (226, 230, 240)
HARD = [(0, 0), (0.4995, 0), (0.5005, 1), (1, 1)]
SOFT = [(0, 0), (0.475, 0), (0.525, 1), (1, 1)]


def tex(name):
    if name not in TEX:
        TEX[name] = Image.open(os.path.join(UI, f"MogRing{name}.png")).convert("RGBA")
    return TEX[name]


def seq(points, t):
    xs, ys = zip(*points)
    return np.interp(t, xs, ys)


def label(canvas, key, scale, size, rotation=0.0, color=WHITE, transparency=0.0, grad=None):
    """One ImageLabel centred in the ring: Size = scale * size, Rotation clockwise, optional UIGradient (rot, seq)
    evaluated in the label's local (unrotated) space like Roblox."""
    px = max(1, round(scale * size))
    img = tex(key).resize((px, px), Image.LANCZOS)
    a = np.asarray(img).astype(float) / 255
    a[..., :3] *= np.array(color) / 255
    a[..., 3] *= 1 - transparency
    if grad:
        g_rot, points = grad
        c = (np.arange(px) + 0.5) - px / 2
        u, v = np.meshgrid(c, c)
        gr = math.radians(g_rot)
        ext = abs(px * math.cos(gr)) + abs(px * math.sin(gr))
        t = (u * math.cos(gr) + v * math.sin(gr)) / ext + 0.5
        a[..., 3] *= 1 - seq(points, t)
    img = Image.fromarray((np.clip(a, 0, 1) * 255).astype(np.uint8))
    img = img.rotate(-rotation, resample=Image.BICUBIC)  # PIL turns counter-clockwise
    x = canvas.width // 2 - px // 2
    canvas.alpha_composite(img, (x, x)) if x >= 0 else canvas.alpha_composite(img.crop((-x, -x, -x + canvas.width, -x + canvas.width)))


def arcs(canvas, size, key, t0, t1, d, color, transparency, cut):
    span = t1 - t0
    a = t0 if d == 1 else -t1
    while span > 1e-3:
        part = min(span, 180)
        label(canvas, key, 1.2, size, a, color, transparency, (part, cut))
        a += part
        span -= part


def font(px):
    for path in ("/System/Library/Fonts/Supplemental/Arial Rounded Bold.ttf", "/System/Library/Fonts/Supplemental/Arial Bold.ttf"):
        if os.path.exists(path):
            return ImageFont.truetype(path, px)
    return ImageFont.load_default()


def ring(size, state):
    """Render one state to an RGBA image 2 x size square (transparent background)."""
    s = size * state.get("scale", 1.0)
    canvas = Image.new("RGBA", (size * 2, size * 2), (0, 0, 0, 0))
    halo = state.get("halo")
    if halo:
        label(canvas, "Halo", 1.5, s, color=halo[0], transparency=halo[1])
    burst = state.get("burst")
    if burst:
        label(canvas, "Burst", burst[1], s, color=burst[0], transparency=burst[2])
    label(canvas, "Base", 1.2, s, color=state.get("base", WHITE))
    z = state.get("zone")
    if z:
        zs, zsize, ps, d = z
        ze = min(zs + zsize, 360)
        pe = min(zs + ps, ze)
        layers = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
        arcs(layers, s, "ArcGlow", zs, pe, d, state.get("glow", GOLD_LIGHT), state.get("glowT", 0.2), SOFT)
        canvas.alpha_composite(layers)
        arcs(canvas, s, "Arc", zs, ze, d, ZONE, 0, HARD)
        arcs(canvas, s, "ArcWide", zs, pe, d, WHITE, 0, HARD)
        label(canvas, "Edge", 1.2, s, d * pe, WHITE)
        label(canvas, "Edge", 1.2, s, d * zs, GOLD_LIGHT)
        label(canvas, "Edge", 1.2, s, d * ze, WHITE)
    n = state.get("needle")
    if n:
        travel, d = n
        shown = min(max(travel, 0), 28)
        if shown > 0.5 and state.get("trail", True):
            g = 180 - shown if d == 1 else shown
            label(canvas, "TrailL" if d == 1 else "TrailR", 1.2, s, d * travel, GOLD_LIGHT, 0.1, (g, HARD))
    fl = state.get("flash")
    if fl:
        label(canvas, "Flash", 1.2, s, color=fl[0], transparency=fl[1])
    if n:
        label(canvas, "Needle", 1.2, s, n[1] * n[0])
    text, color = state["centre"]
    draw = ImageDraw.Draw(canvas)
    f = font(round(26 * s / 180))
    draw.text((size, size), text, fill=color + (255,), font=f, anchor="mm", stroke_width=max(1, round(s / 120)), stroke_fill=(38, 54, 124, 255))
    return canvas


STATES = [
    ("idle", {"scale": 0.86, "base": DIM, "centre": ("SPACE", TEXT_DIM)}),
    ("check + warn", {"zone": (150, 50, 12, 1), "halo": (GOLD, 0.15), "centre": ("SPACE", GOLD)}),
    ("needle sweep", {"zone": (150, 50, 12, 1), "needle": (118, 1), "centre": ("#3", TEXT)}),
    ("dir -1 start", {"zone": (95, 45, 10, -1), "needle": (24, -1), "centre": ("#4", TEXT)}),
    (
        "perfect flash",
        {
            "zone": (150, 50, 12, 1),
            "needle": (156, 1),
            "trail": False,
            "flash": (GOLD_LIGHT, 0.25),
            "halo": (GOLD, 0.3),
            "burst": (GOLD, 1.35, 0.45),
            "glow": WHITE,
            "glowT": 0.0,
            "centre": ("#3", TEXT),
        },
    ),
]


def background(w, h):
    top, bottom = np.array([120, 200, 255.0]), np.array([150, 225, 120.0])
    t = np.linspace(0, 1, h)[:, None, None]
    grad = top + (bottom - top) * t
    return Image.fromarray(np.broadcast_to(grad, (h, w, 3)).astype(np.uint8)).convert("RGBA")


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else "/tmp/mogring"
    os.makedirs(out, exist_ok=True)
    cell = 300
    sheet = background(cell * len(STATES), cell + 760)
    draw = ImageDraw.Draw(sheet)
    for i, (name, st) in enumerate(STATES):
        sheet.alpha_composite(ring(180, st), (i * cell + cell // 2 - 180, cell // 2 - 190))
        draw.text((i * cell + cell // 2, cell - 6), name + " (1x)", fill=(30, 40, 90, 255), font=font(16), anchor="mb")
    for j, idx in enumerate((2, 4)):
        x0 = j * 750 + 15
        sheet.alpha_composite(ring(360, STATES[idx][1]), (x0, cell))
        draw.text((x0 + 360, cell + 750), STATES[idx][0] + " (2x)", fill=(30, 40, 90, 255), font=font(18), anchor="mb")
    sheet.convert("RGB").save(os.path.join(out, "sheet.png"))
    detail = background(720, 720)
    detail.alpha_composite(ring(360, STATES[2][1]), (0, 0))
    detail.convert("RGB").save(os.path.join(out, "detail.png"))
    print("wrote", out)


if __name__ == "__main__":
    main()
