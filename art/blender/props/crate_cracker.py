"""Hero prop: CrateCracker, the carnival high-striker booth that unlocks crates (about 11 x 17.9 x 6.5
studs, like buildUnlocker in src/server/World/Machines.luau on a 6 x 9 rect). Front = -Y (the
part-built booth's front is the rect's minX side). One chunky block with big bevels, in Blender
coordinates (y = u - 3 where u is the part-built distance from the rect front, x = offset along the
rect's Z):
  a fat rounded base slab under everything, a cream chamber floor, the striker plinth (the game's
  crate / "HoloCrate" sits on it at x 0, y -1.7, top z 1.3), the booth with one cream front panel and
  a coloured rim, a big four-stripe awning with fat scallops, the tower face (a cream board in a fat
  frame, a white track: the game's "StrikerPuck" rides it at y -0.45, z 9.3 .. 13.1, and three bold
  meter bars), two thick pillars with three wide bands and big knobs, a fat marquee bar, the big bell
  on top (centre z 16, the game's ring effect plays there) and a soft foam hammer leaning by the
  right pillar.
Two exports of the same model, painted in the world palette: CrateCracker (teal base, booth, frame
and pillars; cream panels; sunny awning stripes, pillar bands, rim, knobs, marquee and bell; sunny /
orange / red-orange bars; red-orange hammer) and CrateCrackerVip (saturated sunny gold body, frame,
pillars, marquee and awning stripes with butter and cream accents, teal only on the rim, plinth and
first bar, and a chunky gold crown with cream balls and gems on the bell)."""

import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _hero import ball, band, ck, disc, highlight_material, place, ship  # noqa: E402
from _redo import C, m  # noqa: E402
from mathutils import Vector  # noqa: E402


# Paint per variant: role -> colour (a _redo.C key or an sRGB triple).
PAINT = {
    "CrateCracker": {
        "base": "TealDeep", "body": "Teal", "frame": "Teal", "panel": "Cream", "floor": "Cream", "trim": "Sunny",
        "plinth": "TealLight", "awning": ("Sunny", "Cream"), "post": "Teal", "stripe": "Sunny", "knob": "Sunny",
        "marquee": "Sunny", "bell": "Sunny", "grip": "Teal", "bars": ("Sunny", "Orange", "RedOrange"),
    },
    "CrateCrackerVip": {
        "base": "Gold", "body": "Sunny", "frame": "Sunny", "panel": "Cream", "floor": "Butter", "trim": "Teal",
        "plinth": "Teal", "awning": ("Sunny", "Cream"), "post": "Sunny", "stripe": "Cream", "knob": "Butter",
        "marquee": "Gold", "bell": "Sunny", "grip": "Teal", "bars": ("Teal", "Orange", "RedOrange"),
    },
}
PILLAR_X = 4.4
PILLAR_R = 1.1
BANDS = (2.6, 8.2, 11.6)  # bottoms of the three wide pillar bands
BAND_H = 1.3


def build(kind, renders=True):
    ck.reset_scene()
    P = PAINT[kind]

    def mk(role, color=None):
        return m(kind + role, color or P[role])

    base = mk("base")
    body = mk("body")
    frame = mk("frame")
    panel = mk("panel")
    floor = mk("floor")
    trim = mk("trim")
    plinth = mk("plinth")
    awning = [mk("AwningA", P["awning"][0]), mk("AwningB", P["awning"][1])]
    post_m = mk("post")
    stripe = mk("stripe")
    knob = mk("knob")
    marquee = mk("marquee")
    white = mk("White", "White")
    cream = mk("Cream", "Cream")
    sunny = mk("bell")
    bell_lip = mk("BellLip", ck.mix(C["Sunny"], C["Orange"], 0.45))
    wood = mk("Wood", "Honey")
    grip = mk("grip")
    hammer = mk("Hammer", "RedOrange")
    bars = [mk("Bar%d" % i, c) for i, c in enumerate(P["bars"])]
    hl = highlight_material(kind + "Shine")

    parts = []
    # One fat rounded base slab under the whole machine, a cream chamber floor on it, and the
    # striker plinth with a white rim and top.
    parts.append(ck.rounded_box((10.2, 6.3, 0.75), 0.34, 2, base, "Base", (0, 0.0, 0)))
    parts.append(ck.rounded_box((8.6, 2.6, 0.22), 0.1, 1, floor, "ChamberFloor", (0, -1.75, 0.6)))
    parts.append(disc(1.4, 0.0, 1.15, 0.3, plinth, "Plinth", segments=20, location=(0, -1.7, 0)))
    parts.append(ck.torus(1.42, 0.17, 20, 6, mat=white, name="PlinthRim", location=(0, -1.7, 1.08)))
    parts.append(disc(1.08, 0.0, 0.2, 0.08, white, "PlinthTop", segments=20, location=(0, -1.7, 1.1)))

    # Booth: a big rounded block, one cream front panel, a coloured rim on top.
    parts.append(ck.rounded_box((8.6, 3.6, 7.0), 0.75, 2, body, "Booth", (0, 1.2, 0)))
    parts.append(ck.rounded_box((6.0, 0.32, 3.9), 0.15, 2, panel, "BoothPanel", (0, -0.62, 2.0)))
    parts.append(ck.rounded_box((9.0, 4.0, 0.6), 0.28, 2, trim, "Rim", (0, 1.2, 6.7)))

    # Big four-stripe awning sloping down to the front, fat scallops along its edge.
    slope = math.degrees(math.atan2(0.8, 2.5))
    stripes = 4
    sw = 9.6 / stripes
    for i in range(stripes):
        x = -4.8 + (i + 0.5) * sw
        am = awning[i % 2]
        parts.append(place(ck.rounded_box((sw + 0.03, 3.0, 0.5), 0.22, 2, am, "Awning"), (x, -1.75, 6.1), (slope, 0, 0)))
        parts.append(ball(0.62, am, "Scallop", (x, -2.93, 5.85), (1.5, 0.75, 1.0), 10, 5))

    # Tower: a cream board in a fat frame, a white striker track up the middle and three bold
    # meter bars across it (low to high).
    parts.append(ck.rounded_box((8.4, 1.4, 7.2), 0.8, 2, frame, "BoardFrame", (0, 0.6, 6.9)))
    parts.append(ck.rounded_box((6.4, 0.4, 5.7), 0.35, 2, panel, "Board", (0, -0.05, 7.55)))
    parts.append(ck.rounded_box((2.0, 0.4, 6.1), 0.3, 2, white, "Track", (0, -0.15, 7.4)))
    for i, bm in enumerate(bars):
        parts.append(ck.rounded_box((4.6, 0.42, 1.25), 0.36, 2, bm, "Bar", (0, -0.27, 8.6 + i * 1.6)))

    # Thick pillars with three wide bands, a big knob on top.
    PR = PILLAR_R
    prof = [(0, 0), (PR, 0)]
    for z0 in BANDS:
        prof += [(PR, z0), (PR + 0.12, z0 + 0.14), (PR + 0.12, z0 + BAND_H - 0.14), (PR, z0 + BAND_H)]
    prof += [(PR, 14.0), (0, 14.0)]
    for sx in (-1, 1):
        post = ck.lathe(prof, 14, post_m, "Pillar", location=(sx * PILLAR_X, 0.0, 0), smooth_angle=50)
        post.data.materials.append(stripe)
        for p in post.data.polygons:
            if math.hypot(p.center.x, p.center.y) > PR + 0.005 and 0.5 < p.center.z < 13.9:
                p.material_index = 1
        parts.append(post)
        parts.append(ball(1.22, knob, "Knob", (sx * PILLAR_X, 0.0, 14.45), (1, 1, 1), 14, 7))
    parts.append(ck.capsule(1.0, 8.8, 14, 3, marquee, "Marquee", (0, 0.0, 14.0), axis="X"))

    # Big bell on top.
    parts.append(disc(1.55, 0.0, 0.5, 0.2, bell_lip, "BellLip", segments=20, location=(0, 0, 14.75)))
    parts.append(ball(1.42, sunny, "Bell", (0, 0, 16.0), (1, 1, 1), 16, 8))
    if kind == "CrateCrackerVip":
        parts += crown_topper(kind, (0, 0, 17.12))
    else:
        parts.append(ball(0.42, cream, "BellKnob", (0, 0, 17.45), (1, 1, 1), 10, 5))
    parts.append(band((0, 0, 16.0), (1.42, 1.42, 1.42), -60, 10, 40, 0.42, hl, "BellShine"))

    # Soft foam hammer leaning by the right pillar.
    a = Vector((2.7, -2.75, 0.8))
    b = Vector((2.7, -1.7, 4.3))
    d = (b - a).normalized()
    parts.append(ck.sweep([a, b], [0.26, 0.26], 10, wood, "Handle", smooth_angle=70))
    parts.append(ck.sweep([a + d * 0.1, a + d * 1.2], [0.34, 0.34], 10, grip, "Grip", smooth_angle=70))
    head = b + d * 0.3
    parts.append(place(disc(0.82, -1.1, 1.1, 0.3, hammer, "HammerHead", segments=16), head, (0, 90, 0)))
    for sx in (-1, 1):
        parts.append(place(disc(0.88, -0.18, 0.18, 0.1, cream, "HammerCap", segments=16), head + Vector((sx * 1.1, 0, 0)),
                           (0, 90, 0)))
    return ship(parts, kind, tri_budget=1800 if kind == "CrateCracker" else 2100, renders=renders, azimuth=30.0,
                elevation=12.0)


def crown_topper(kind, base):
    """Chunky gold crown (about 2.2 wide, 1.3 tall) sitting on the bell top: a gold band with a deep
    gold lower rim, five round-tipped points with big cream balls, a teal gem on the front and coral
    gems at the front corners."""
    gold = m(kind + "CrownGold", (255, 184, 24))
    deep = m(kind + "CrownDeep", (232, 132, 22))
    pearl = m(kind + "CrownPearl", "Cream")
    teal = m(kind + "CrownGem", "Teal")
    coral = m(kind + "CrownGemB", "Coral")
    bx, by, bz = base
    band_ob = ck.lathe([(0, 0), (1.0, 0), (1.06, 0.08), (1.06, 0.46), (1.0, 0.52), (0, 0.52)], 18, gold, "CrownBand",
                       location=(bx, by, bz), smooth_angle=60)
    band_ob.data.materials.append(deep)
    for p in band_ob.data.polygons:
        if p.center.z < 0.07:
            p.material_index = 1
    out = [band_ob]
    for k in range(5):
        a = math.radians(-90 + 72 * k)
        h = 0.82 if k == 0 else 0.7
        cx, cy = bx + 0.86 * math.cos(a), by + 0.86 * math.sin(a)
        pt = ck.lathe([(0.36, 0.0), (0.22, h * 0.5), (0.08, h - 0.04), (0.0, h)], 8, gold, "CrownPoint",
                      location=(cx, cy, bz + 0.36), smooth_angle=80)
        pt.rotation_euler = (0, math.radians(8), a)
        pt.scale = (0.55, 1.0, 1.0)
        out.append(pt)
        tip_r = 0.86 + math.sin(math.radians(8)) * h
        out.append(ball(0.24, pearl, "CrownPearl", (bx + tip_r * math.cos(a), by + tip_r * math.sin(a), bz + 0.36 + h),
                        (1, 1, 1), 10, 5))
    out.append(ball(0.26, teal, "CrownGem", (bx, by - 1.04, bz + 0.26), (1, 0.5, 1), 10, 5))
    for sx in (-1, 1):
        a = math.radians(-90 + sx * 40)
        out.append(ball(0.18, coral, "CrownGem", (bx + 1.03 * math.cos(a), by + 1.03 * math.sin(a), bz + 0.26),
                        (1, 1, 1), 8, 4))
    return out


build("CrateCracker")
build("CrateCrackerVip")
