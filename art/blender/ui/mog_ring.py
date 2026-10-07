"""MOG TEST skill-check ring textures (system python3 + numpy + Pillow; no Blender needed).

Everything is drawn analytically in polar coordinates at 4x supersampling and box-downscaled, so every edge
is anti-aliased. Geometry is in "design px" for a 180 px ring (src/client/UI/MogRing.luau uses the same
numbers); angles are degrees clockwise from 12 o'clock, like the ring's needle travel.

Outputs art/out/ui/MogRing*.png (listed in art/assets/hud.json):
  Base     full colour: drop shadow, thick gold rim, bright blue track with bold 30-degree ticks, centre plate (1.2 D)
  Halo     white soft glow around the rim (1.5 D canvas), tinted gold/cream/red for warn and flashes
  Flash    white rim annulus + outer glow (1.2 D), tinted and faded over the rim on a result
  Arc      white HALF zone band (right half, 0..180 deg) with a baked dark outline (takes the tint's hue) and tube
           shading; rotated + UIGradient-cut per arc
  ArcWide  full-colour gold half band, wider on both sides: the raised perfect slice (amber outline, highlight)
  ArcGlow  soft blurred half band with a feathered start, behind the perfect slice
  Edge     white radial edge tick with a dark outline at 12 o'clock, rotated to the zone bounds (caps the cut ends)
  Needle   full colour long hand pointing to 12 o'clock: gold hub at the plate edge, navy outline, red body, tip
           past the rim, soft shadow
  TrailL   white fading wedge 28 deg behind a clockwise needle (dir = 1); TrailR is its mirror (dir = -1)
  Burst    white thin soft ring (1.0 D canvas), grown and faded on results

Usage: python3 art/blender/ui/mog_ring.py
"""

import os

import numpy as np
from PIL import Image, ImageFilter

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
OUT = os.path.join(ROOT, "art", "out", "ui")
SS = 4

# Design geometry (px at a 180 px ring). Keep in sync with MogRing.luau.
D = 180
R_RIM = 90  # rim outer radius
R_RIM_IN = 79  # rim inner edge = track outer edge (thick gold rim)
R_PLATE = 49  # centre plate radius (track inner edge)
BAND_OUT = 79.5  # zone band outer radius (fills most of the 49..79 track)
BAND_IN = 49.5  # zone band inner radius
WIDE_OUT, WIDE_IN = 84.5, 45.5  # perfect slice: raised over the band on both sides
OUTLINE = 2.2  # baked dark outline on the tintable bands (value OUTLINE_V, so it takes the tint's hue)
OUTLINE_V = 0.16

# Theme colours (src/themes/chad/Theme.luau).
CREAM = (255, 247, 232)
EDGE = (38, 54, 124)
INK = (42, 54, 114)
NAVY = (24, 30, 72)

def grid(px, canvas):
    """Hi-res polar grid: x, y (design px from the centre, y down), r, phi (deg clockwise from up)."""
    n = px * SS
    s = canvas / n
    c = (np.arange(n) + 0.5) * s - canvas / 2
    x, y = np.meshgrid(c, c)
    r = np.hypot(x, y)
    phi = np.degrees(np.arctan2(x, -y)) % 360
    return x, y, r, phi, s


def smooth(v, a, b):
    t = np.clip((v - a) / (b - a), 0, 1)
    return t * t * (3 - 2 * t)


def band(r, r0, r1, aa):
    """Coverage of r0 <= r <= r1 with a ~1 hi-res pixel AA edge."""
    return np.clip((r - r0) / aa + 0.5, 0, 1) * np.clip((r1 - r) / aa + 0.5, 0, 1)


class Layer:
    """Premultiplied RGBA float canvas at hi-res."""

    def __init__(self, shape):
        self.rgb = np.zeros(shape + (3,))
        self.a = np.zeros(shape)

    def over(self, alpha, color):
        col = np.asarray(color, dtype=float) / 255.0
        alpha = np.clip(alpha, 0, 1)
        if col.ndim == 1:
            col = np.broadcast_to(col, alpha.shape + (3,))
        self.rgb = col * alpha[..., None] + self.rgb * (1 - alpha[..., None])
        self.a = alpha + self.a * (1 - alpha)

    def save(self, path, px):
        h = self.a.shape[0]
        f = h // px
        rgb = self.rgb.reshape(px, f, px, f, 3).mean(axis=(1, 3))
        a = self.a.reshape(px, f, px, f).mean(axis=(1, 3))
        out = np.where(a[..., None] > 1e-6, rgb / np.maximum(a[..., None], 1e-6), 0)
        img = np.dstack([np.clip(out, 0, 1), np.clip(a, 0, 1)])
        Image.fromarray((img * 255 + 0.5).astype(np.uint8)).save(path, optimize=True)
        print("wrote", os.path.relpath(path, ROOT))


def blur(mask, radius_design, s):
    img = Image.fromarray((np.clip(mask, 0, 1) * 255).astype(np.uint8))
    img = img.filter(ImageFilter.GaussianBlur(radius_design / s))
    return np.asarray(img).astype(float) / 255.0


def mix(c0, c1, t):
    c0 = np.asarray(c0, dtype=float)
    c1 = np.asarray(c1, dtype=float)
    return c0 + (c1 - c0) * np.asarray(t)[..., None]


def make_base(px=512):
    canvas = D * 1.2
    x, y, r, phi, s = grid(px, canvas)
    L = Layer(r.shape)
    aa = s * 1.2
    # Soft drop shadow (offset down).
    shadow = band(np.hypot(x, y - 6), -1, R_RIM + 1, aa)
    L.over(blur(shadow, 5.5, s) * 0.5, INK)
    # Thick gold rim, lit from the top, with a dark-gold outline for definition on bright scenes.
    L.over(band(r, -1, R_RIM, aa), (150, 92, 18))
    rim = band(r, -1, R_RIM - 1.8, aa)
    shade = smooth(y, -R_RIM, R_RIM)
    L.over(rim, mix((255, 232, 120), (242, 168, 34), shade))
    # Bevel: bright top highlight crescent, warm lower lip, and a dark groove where the rim meets the track.
    mid = (R_RIM + R_RIM_IN) / 2
    hl = band(r, mid - 0.5, R_RIM - 3.2, aa) * smooth(-y, 10, 75)
    L.over(hl * 0.85, (255, 252, 226))
    L.over(band(r, R_RIM_IN + 1, R_RIM_IN + 3, aa) * smooth(y, -20, 70) * 0.45, (255, 240, 170))
    # Track face: bright royal-sky blue, a little lighter towards the bottom.
    track = band(r, -1, R_RIM_IN, aa)
    L.over(track, mix((74, 112, 222), (98, 142, 240), smooth(y, -R_RIM_IN, R_RIM_IN)))
    lip = np.clip(1 - (R_RIM_IN - r) / 5, 0, 1) ** 2 * track * (0.5 + 0.5 * smooth(-y, -40, 60))
    L.over(lip * 0.5, (20, 30, 90))
    L.over(band(r, R_RIM_IN - 0.3, R_RIM_IN + 1.2, aa), (122, 74, 14))
    # Bold tick marks every 30 deg from the rim inwards; 12 o'clock (the start of travel) crosses the track.
    for k in range(12):
        ang = np.radians(k * 30)
        along = x * np.sin(ang) - y * np.cos(ang)
        perp = np.abs(x * np.cos(ang) + y * np.sin(ang))
        if k == 0:
            line = band(perp, -1, 2.0, aa) * band(along, R_PLATE + 1, R_RIM_IN + 0.5, aa)
            L.over(blur(line, 1.2, s) * 0.5, NAVY)
            L.over(line, (255, 255, 255))
        else:
            major = k % 3 == 0
            w = 2.6 if major else 1.6
            line = band(perp, -1, w, aa) * band(along, R_RIM_IN - (17 if major else 9), R_RIM_IN + 0.5, aa)
            if major:
                L.over(blur(line, 1.0, s) * 0.45, NAVY)
            L.over(line * (1.0 if major else 0.8), (240, 246, 255))
    # Raised centre plate: cast shadow onto the track, navy edge ring, deeper blue face with a top-light.
    pshadow = band(np.hypot(x, y - 2.5), -1, R_PLATE, aa)
    L.over(blur(pshadow, 2.5, s) * 0.5, (14, 20, 60))
    L.over(band(r, -1, R_PLATE, aa), EDGE)
    face = band(r, -1, R_PLATE - 3, aa)
    L.over(face, mix((86, 116, 214), (58, 84, 176), smooth(y, -R_PLATE, R_PLATE * 0.6)))
    L.over(band(r, R_PLATE - 5, R_PLATE - 3, aa) * (0.3 + 0.4 * smooth(-y, -20, 50)), (186, 208, 255))
    L.save(os.path.join(OUT, "MogRingBase.png"), px)


def make_halo(px=512):
    canvas = D * 1.5
    x, y, r, phi, s = grid(px, canvas)
    L = Layer(r.shape)
    a = np.where(r < R_RIM, smooth(r, R_RIM - 14, R_RIM), np.exp(-(((r - R_RIM) / 9.0) ** 2)))
    L.over(a * 0.95, (255, 255, 255))
    L.save(os.path.join(OUT, "MogRingHalo.png"), px)


def make_flash(px=512):
    canvas = D * 1.2
    x, y, r, phi, s = grid(px, canvas)
    L = Layer(r.shape)
    aa = s * 1.2
    glow = blur(band(r, R_RIM_IN, R_RIM + 1, aa), 4, s)
    L.over(glow * 0.8, (255, 255, 255))
    L.over(band(r, R_RIM_IN, R_RIM, aa), (255, 255, 255))
    L.save(os.path.join(OUT, "MogRingFlash.png"), px)


def band_tex(r, x, r_in, r_out, aa):
    """White half band (right half) with a dark baked outline and tube shading; returns (coverage, rgb)."""
    half = np.clip(x / aa + 0.5, 0, 1)
    cov = band(r, r_in, r_out, aa) * half
    mid = (r_in + r_out) / 2
    hw = (r_out - r_in) / 2
    t = np.abs(r - mid) / hw
    v = 1.0 - 0.2 * smooth(t, 0.45, 1.0)  # tube: full in the middle
    inner = band(r, r_in + OUTLINE, r_out - OUTLINE, aa)
    v = OUTLINE_V + (v - OUTLINE_V) * inner
    return cov, v


def make_arc(px=512):
    canvas = D * 1.2
    x, y, r, phi, s = grid(px, canvas)
    aa = s * 1.2
    L = Layer(r.shape)
    cov, v = band_tex(r, x, BAND_IN, BAND_OUT, aa)
    L.over(cov, v[..., None] * 255)
    L.save(os.path.join(OUT, "MogRingArc.png"), px)

    # The perfect slice is full colour (tinted white in game): dark-amber outline, saturated gold body darker on
    # the inner side, and a pale-yellow highlight stripe in the outer third, so it reads as a raised gold bar.
    W = Layer(r.shape)
    half = np.clip(x / aa + 0.5, 0, 1)
    W.over(band(r, WIDE_IN, WIDE_OUT, aa) * half, (122, 66, 0))
    inner = band(r, WIDE_IN + OUTLINE, WIDE_OUT - OUTLINE, aa) * half
    W.over(inner, mix((236, 160, 0), (255, 214, 24), smooth(r, WIDE_IN, WIDE_IN + 14)))
    mid = (WIDE_IN + WIDE_OUT) / 2
    W.over(band(r, mid + 6, WIDE_OUT - OUTLINE - 2.2, aa) * half * 0.9, (255, 246, 170))
    W.save(os.path.join(OUT, "MogRingArcWide.png"), px)

    # Glow: wider soft band, feathered over the first 6 degrees so the start never shows a hard edge.
    G = Layer(r.shape)
    g = blur(band(r, WIDE_IN - 3, WIDE_OUT + 3, aa), 5, s)
    g = g * (x > 0) * smooth(phi, 0, 6) * (1 - smooth(phi, 174, 180))
    G.over(np.clip(g * 1.1, 0, 1), (255, 255, 255))
    G.save(os.path.join(OUT, "MogRingArcGlow.png"), px)


def make_edge(px=512):
    canvas = D * 1.2
    x, y, r, phi, s = grid(px, canvas)
    L = Layer(r.shape)
    aa = s * 1.2
    along = -y
    perp = np.abs(x)
    outer = band(perp, -1, 2.6, aa) * band(along, WIDE_IN - 1, WIDE_OUT + 1, aa)
    core = band(perp, -1, 1.2, aa) * band(along, WIDE_IN + 0.5, WIDE_OUT - 0.5, aa)
    L.over(blur(outer, 1.5, s) * 0.6, (0, 0, 0))
    L.over(outer, (int(255 * OUTLINE_V),) * 3)
    L.over(core, (255, 255, 255))
    L.save(os.path.join(OUT, "MogRingEdge.png"), px)


def make_needle(px=512):
    canvas = D * 1.2
    x, y, r, phi, s = grid(px, canvas)
    L = Layer(r.shape)
    aa = s * 1.2
    r0, r1 = 42.0, 104.0  # hub at the plate edge .. pointed tip past the rim
    along = -y
    t = np.clip((along - r0) / (r1 - r0), 0, 1)

    def shape_at(grow):
        # Long bold hand: wide near the hub, slight taper, then a pointed tip over the last 9 px.
        hw = 5.4 - 1.6 * t + grow
        tipt = np.clip((along - (r1 - 11)) / 11, 0, 1)
        hw = hw * (1 - tipt) + grow * tipt
        body = np.clip((hw - np.abs(x)) / aa + 0.5, 0, 1) * band(along, r0, r1 + grow, aa)
        hub = band(np.hypot(x, along - r0), -1, 7.6 + grow, aa)
        return np.maximum(body, hub)

    out = shape_at(1.9)
    rim = shape_at(3.0)
    L.over(blur(rim, 2.4, s) * 0.45, (10, 12, 40))  # soft shadow (symmetric: it turns with the needle)
    L.over(rim * 0.9, (255, 250, 236))  # thin cream outer line: reads on the green band and the gold slice
    L.over(out, NAVY)  # bold dark outline
    body = shape_at(0.0)
    L.over(body, mix((232, 40, 52), (255, 92, 80), np.clip(t * 1.4, 0, 1)))
    # Highlight stripe down one side and a bright core near the tip.
    stripe = np.clip((1.3 - np.abs(x + 1.4)) / aa + 0.5, 0, 1) * band(along, r0 + 8, r1 - 12, aa)
    L.over(stripe * 0.75, (255, 214, 200))
    # Hub cap: gold disc with a white glint and a navy pin.
    L.over(band(np.hypot(x, along - r0), -1, 5.8, aa), (255, 206, 60))
    L.over(band(np.hypot(x, along - r0), -1, 4.2, aa), (255, 248, 220))
    L.over(band(np.hypot(x + 1.4, along - r0 - 1.4), -1, 1.6, aa) * 0.9, (255, 255, 255))
    L.over(band(np.hypot(x, along - r0), -1, 1.6, aa), NAVY)
    L.save(os.path.join(OUT, "MogRingNeedle.png"), px)


def make_trail(px=512):
    canvas = D * 1.2
    x, y, r, phi, s = grid(px, canvas)
    aa = s * 1.2
    span = 28.0
    behind = (360 - phi) % 360  # 0 at 12 o'clock growing counter-clockwise
    fade = np.clip(1 - behind / span, 0, 1) ** 0.85 * (behind < span)
    fade = fade * smooth(behind, 0, 0.6)  # no hard edge on the leading side either
    lo, hi = R_PLATE + 2, R_RIM - 2
    cov = band(r, lo, hi, aa)
    radial = 1 - 0.3 * (np.abs(r - (lo + hi) / 2) / ((hi - lo) / 2)) ** 2
    a = blur(cov * fade * radial, 0.6, s)
    L = Layer(r.shape)
    L.over(np.clip(a * 1.6, 0, 1), (255, 255, 255))
    L.save(os.path.join(OUT, "MogRingTrailL.png"), px)
    R = Layer(r.shape)
    R.rgb, R.a = L.rgb[:, ::-1], L.a[:, ::-1]
    R.save(os.path.join(OUT, "MogRingTrailR.png"), px)


def make_burst(px=256):
    canvas = float(D)
    x, y, r, phi, s = grid(px, canvas)
    L = Layer(r.shape)
    aa = s * 1.2
    ring = band(r, R_RIM - 7, R_RIM - 2, aa)
    L.over(blur(ring, 6, s) * 0.9, (255, 255, 255))
    L.over(blur(ring, 1.2, s) * 0.75, (255, 255, 255))
    L.save(os.path.join(OUT, "MogRingBurst.png"), px)


if __name__ == "__main__":
    os.makedirs(OUT, exist_ok=True)
    make_base()
    make_halo()
    make_flash()
    make_arc()
    make_edge()
    make_needle()
    make_trail()
    make_burst()
