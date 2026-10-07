"""Roblox badge icons (512 px, opaque, circle-safe) in art/out/badges/<Name>.png.

Each badge = a toy subject rendered with the shared icon rig (chadkit.render_icon: white sticker
outline, soft Ink shadow, optional halo) into art/out/badges/raw/, then composed by compose.py
(system python3 + Pillow) onto a radial-gradient sunburst disc with a rim ring, scaled so the subject
stays inside the circle Roblox crops to.

Run headless through the heavy lock, all badges or a subset by name:
    tools/blender-run.sh art/blender/badges/badges.py -- [Welcome GymGraduate CertifiedChad AbsoluteChad ParkourMaster]
Then the contact sheet:  python3 art/blender/badges/compose.py --sheet
(or art/blender/badges/run_all.sh for everything).
"""

import math
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "icons_shop"))
sys.path.insert(0, os.path.join(HERE, "..", "cosmetics"))
import shoplib as sl  # noqa: E402  (puts art/blender/lib on sys.path)
from shoplib import M, ck, pose  # noqa: E402

import _cos  # noqa: E402  (winged sneaker, stars, cloud puffs)

ck.PALETTE.setdefault("Cobalt", (44, 112, 208))  # crown_tall's gem; no longer in Theme.World

OUT = os.path.join(ck.ROOT, "art", "out", "badges")
RAW = os.path.join(OUT, "raw")
os.makedirs(RAW, exist_ok=True)


# ------------------------------------------------------------------------------------------------
# Parts
# ------------------------------------------------------------------------------------------------

def dumbbell(head="HotPink", ring="Sunny", grip="White", R=0.5, W=0.38, length=1.2):
    """The gym's candy dumbbell (prop_Dumbbell look, icon resolution) along Z, centred on the origin:
    fat round heads with a band round the rim, a white grip and a gloss streak on each head."""
    hm, rm = M(head), M(ring)
    bev, band = 0.12, 0.07
    parts = [ck.capsule(0.17, length, 32, 4, M(grip), "Grip")]
    zc = length / 2 - 0.015
    for side in (-1, 1):
        prof = [(0, -W / 2)]
        for k in range(5):
            a = -math.pi / 2 + (math.pi / 2) * k / 4
            prof.append((R - bev + bev * math.cos(a), -W / 2 + bev + bev * math.sin(a)))
        prof += [(R, -band), (R, band)]
        for k in range(5):
            a = (math.pi / 2) * k / 4
            prof.append((R - bev + bev * math.cos(a), W / 2 - bev + bev * math.sin(a)))
        prof.append((0, W / 2))
        h = ck.lathe(prof, 48, hm, "Head", (0, 0, side * zc), smooth_angle=60)
        h.data.materials.append(rm)
        for p in h.data.polygons:
            if abs(p.center.z) < band and math.hypot(p.center.x, p.center.y) > R - 0.04:
                p.material_index = 1
        parts.append(h)
        # gloss streak on the rim, facing the camera-left key light
        pts = [((R + 0.012) * math.cos(math.radians(a)), (R + 0.012) * math.sin(math.radians(a)),
                side * zc + W * 0.28) for a in (200, 215, 230, 245, 260)]
        parts.append(ck.gloss_streak(pts, 0.06, (-0.6, -0.8, 0.0)))
    return parts


def heart(location, size=0.5, color="HotPink", turn=0.0):
    pts = []
    for k in range(64):
        t = 2 * math.pi * k / 64
        x = 16 * math.sin(t) ** 3
        y = 13 * math.cos(t) - 5 * math.cos(2 * t) - 2 * math.cos(3 * t) - math.cos(4 * t)
        pts.append((x / 17 * size, y / 17 * size))
    pts = pts[::-1] if ck_area(pts) < 0 else pts
    h = ck.extrude_shape(pts, depth=size * 0.5, mat=M(color, emission=0.08), name="Heart", bevel=size * 0.16)
    h.location = location
    sl.facing(h)
    h.rotation_mode = "XYZ"
    h.rotation_euler.z += math.radians(turn)
    return h


def ck_area(pts):
    return sum(x0 * y1 - x1 * y0 for (x0, y0), (x1, y1) in zip(pts, pts[1:] + pts[:1])) / 2


def wave_arcs(centre, radii=(0.9, 1.25), a0=20, a1=80, color="White"):
    """Little 'hello' motion arcs (curved pills) around a point, in the camera-facing XZ plane."""
    out = []
    for r in radii:
        pts = [(centre[0] + r * math.cos(math.radians(a)), centre[1] - 0.3,
                centre[2] + r * math.sin(math.radians(a))) for a in range(a0, a1 + 1, 6)]
        n = len(pts)
        rad = [0.075 * (0.55 + 0.45 * math.sin(math.pi * i / (n - 1))) + 0.02 for i in range(n)]
        out.append(ck.sweep(pts, rad, 14, M(color, emission=0.35), "Wave"))
    return out


def mortarboard(color="Ink", tassel="Sunny"):
    """Graduation cap built on z = 0 (bottom of the skull): a round skull cap, a flat square board,
    a sunny button and a cord running to one corner and hanging into a fat tassel."""
    cap = M(ck.mix(color, "GrapeDeep", 0.25))
    board = M(ck.mix(color, "GrapeDeep", 0.15), roughness=0.45)
    gold = M(tassel)
    skull = ck.lathe([(0, 0.0), (0.46, 0.0), (0.5, 0.06), (0.5, 0.3), (0.46, 0.36), (0, 0.38)], 48, cap, "Skull",
                     smooth_angle=50)
    top = 0.44
    b = ck.rounded_box((1.6, 1.6, 0.12), 0.05, 3, board, "Board", (0, 0, top - 0.06))
    button = ck.sphere(0.1, 24, 12, gold, "Button", (0, 0, top + 0.04))
    button.scale = (1.0, 1.0, 0.6)
    c = 0.74
    cord = [(0, 0, top + 0.05), (c * 0.5, -c * 0.5, top + 0.05), (c, -c, top + 0.03), (c + 0.03, -c - 0.03, top - 0.2),
            (c + 0.03, -c - 0.03, top - 0.48)]
    parts = [skull, b, button, ck.sweep(cord, [0.04] * 5, 10, gold, "Cord")]
    knot = ck.sphere(0.085, 20, 10, gold, "Knot", (c + 0.03, -c - 0.03, top - 0.5))
    tas = ck.lathe([(0, top - 0.5), (0.07, top - 0.55), (0.13, top - 0.82), (0.14, top - 0.9), (0, top - 0.92)], 24,
                   gold, "Tassel", (c + 0.03, -c - 0.03, 0))
    gl = ck.gloss_streak([(-0.55, -0.55 + 0.1 * k, top + 0.005) for k in range(5)], 0.06, (0, 0, 1))
    return parts + [knot, tas, gl]


def medal(face="Sunny"):
    """Big gold medal standing up toward the viewer: a lathed coin with a raised rim ring and a fat
    white star, on a V of hot-pink ribbon (white centre stripes) with a gold clasp."""
    r, t = 1.0, 0.2
    disc = [ck.lathe(sl.coin_profile(r, t), 64, M(face), "Medal", smooth_angle=50),
            ck.torus(0.74, 0.055, 64, 10, mat=M("GoldDeep"), name="Ring", location=(0, 0, t - 0.02))]
    st = ck.extrude_shape(ck.star_points(5, 0.56, 0.27, round_steps=2), depth=0.16, mat=M("White"), name="Star",
                          bevel=0.05, bevel_segments=3)
    st.location = (0, 0, t + 0.02)
    disc.append(st)
    disc.append(ck.gloss_streak([(0.86 * math.cos(math.radians(a)), 0.86 * math.sin(math.radians(a)), t - 0.03)
                                 for a in (104, 118, 132, 146, 160)], 0.09, (0, 0, 1)))
    medal_e = pose(disc, (0, 0, 0), (82, 0, 10), name="MedalPose")
    parts = [medal_e]
    pink, white = M("HotPink"), M("White")
    for side in (-1, 1):
        quad = [(-0.5, 0.45), (0.05, 0.45), (-0.4, 1.95), (-1.0, 1.85)]
        if side > 0:
            quad = [(-x, y) for x, y in quad][::-1]
        s = ck.extrude_shape(quad, depth=0.12, mat=pink, name="Ribbon", bevel=0.03, bevel_segments=2)
        sl.bake_matrix(s, sl.TO_XZ)
        s.location = (0, 0.35 if side < 0 else 0.42, 0)
        mid = [((a[0] + b[0]) / 2, (a[1] + b[1]) / 2) for a, b in ((quad[0], quad[1]), (quad[2], quad[3]))]
        lo, hi = mid if side < 0 else mid
        dx, dz = hi[0] - lo[0], hi[1] - lo[1]
        ln = math.hypot(dx, dz)
        stripe = ck.capsule(0.07, ln * 0.92, 16, 3, white, "Stripe", ((lo[0] + hi[0]) / 2, 0.26 if side < 0 else 0.33,
                                                                          (lo[1] + hi[1]) / 2), axis="Z")
        stripe.scale = (1.0, 0.45, 1.0)
        stripe.rotation_euler = (0, math.atan2(dx, dz), 0)
        parts += [s, stripe]
    parts.append(ck.rounded_box((0.5, 0.3, 0.32), 0.1, 3, M("GoldDeep"), "Clasp", (0, 0.18, 1.0)))
    return parts


def island():
    """Floating grass platform: a lime grass slab with a scalloped drip edge over a sandy rock cone."""
    grass, dark = M("Lime"), M(ck.mix("Lime", "Emerald", 0.45))
    rock = ck.lathe([(0, -1.25), (0.25, -1.15), (0.6, -0.85), (1.0, -0.5), (1.28, -0.2), (1.32, -0.05)], 48,
                    M("Tan"), "Rock", smooth_angle=70)
    band = ck.lathe(ck.round_profile(0, 1.38, -0.28, -0.02, 0.1, 3), 56, M(ck.mix("Tan", "Coral", 0.25)), "Dirt")
    top = ck.lathe(ck.round_profile(0, 1.45, -0.08, 0.18, 0.12, 4), 64, grass, "Grass")
    parts = [rock, band, top]
    for k in range(14):  # grass drips round the rim
        a = 2 * math.pi * k / 14
        d = ck.sphere(0.2, 20, 10, dark if k % 2 else grass, "Drip", (1.36 * math.cos(a), 1.36 * math.sin(a), -0.05))
        d.scale = (1.0, 1.0, 1.25)
        parts.append(d)
    for (x, y) in ((-0.55, -0.85), (0.15, -1.05), (0.75, -0.8)):  # rock stripes
        parts.append(ck.sphere(0.13, 16, 8, M(ck.mix("Tan", "Sand", 0.5)), "Pebble", (x * 0.8, y * 0.62, -0.62)))
    e = pose(parts, name="Island")
    e.scale = (1.0, 0.62, 1.0)
    return e


# ------------------------------------------------------------------------------------------------
# Badges: each returns (parts, render opts, compose opts)
# ------------------------------------------------------------------------------------------------

def welcome():
    """Hot-pink gym dumbbell raised in a friendly wave, hello arcs, a little heart and sparkles."""
    db = pose(dumbbell("HotPink", "Sunny", R=0.6, W=0.46), (0, 0, 0), (0, 55, -14), name="Dumbbell")
    parts = [db] + wave_arcs((0.6, 0, 0.6), radii=(1.0, 1.28), a0=22, a1=72, color="Coral")
    parts += [heart((-1.05, -0.5, 0.95), 0.3, "Coral", 12),
              sl.sparkle((1.25, -0.6, -0.7), 0.3), sl.sparkle((-1.15, -0.6, -0.55), 0.22)]
    return parts, {}, {"bg": "welcome"}


def gym_graduate():
    """Blue dumbbell standing upright wearing a graduation cap (sunny tassel), with a diploma scroll."""
    db = dumbbell("Blue", "Sunny", R=0.66, W=0.5)
    cap = pose(mortarboard(), (0, 0, 0.82), (6, -4, 12), 0.85, name="Cap")
    scroll = [ck.capsule(0.2, 1.5, 32, 4, M("Cream"), "Scroll", axis="X"),
              ck.torus(0.205, 0.06, 32, 8, mat=M("Sunny"), name="Tie")]
    scroll[1].rotation_euler = (0, math.radians(90), 0)
    for x in (-0.75, 0.75):
        scroll.append(ck.lathe([(0, -0.02), (0.13, -0.02), (0.13, 0.02), (0, 0.02)], 24, M(ck.mix("Cream", "Tan", 0.4)),
                               "End", (x, 0, 0)))
        scroll[-1].rotation_euler = (0, math.radians(90), 0)
    sc = pose(scroll, (0.62, -0.7, -0.6), (0, -18, 30), 1.3, name="Diploma")
    parts = [pose(db + [cap], (0, 0, 0), (0, -8, 0)), sc,
             sl.sparkle((-1.0, -0.5, 1.35), 0.3), sl.sparkle((1.05, -0.5, 0.75), 0.22)]
    return parts, {}, {"bg": "graduate"}


def certified_chad():
    """Gold star medal on a pink ribbon with a strong cyan aura glow and sparkles."""
    parts = medal()
    parts += [sl.sparkle((1.1, -0.6, 0.85), 0.32), sl.sparkle((-1.05, -0.6, -0.75), 0.26),
              sl.sparkle((0.95, -0.6, -0.9), 0.18)]
    return parts, {"halo": ("CyanPop", 1.0)}, {"bg": "certified"}


def absolute_chad():
    """The top tier: tall gold crown over a big glowing violet aura orb, gold glow, big sparkles."""
    orb = sl.orb((0, 0, 0), 1.15, sparkles=True)
    crown = sl.crown_tall((0, 0.1, 0.8), 1.45, (4, 0, 28))
    parts = [orb, crown, sl.sparkle((-1.45, -0.6, 1.9), 0.34), sl.sparkle((1.35, -0.6, -0.35), 0.26)]
    return parts, {"halo": ("Sunny", 1.0)}, {"bg": "absolute"}


def parkour_master():
    """Blue winged sneaker leaping off a floating grass platform."""
    shoe = pose(_cos.sneaker(body=ck.mix("Blue", "BlueDeep", 0.45)), (0.05, 0, 1.0), (0, -14, -8), 1.0,
                name="Sneaker")
    plat = island()
    plat.scale = (0.8, 0.5, 0.8)
    plat.location = (0, 0, -0.35)
    parts = [shoe, plat, sl.sparkle((1.25, -0.6, 1.95), 0.26), sl.sparkle((-1.3, -0.6, -0.3), 0.2)]
    return parts, {}, {"bg": "parkour"}


BADGES = {
    "Welcome": welcome,
    "GymGraduate": gym_graduate,
    "CertifiedChad": certified_chad,
    "AbsoluteChad": absolute_chad,
    "ParkourMaster": parkour_master,
}


def main():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    names = argv or list(BADGES)
    for name in names:
        sl.reset()
        sl.reset_gem_cache()
        parts, ropts, copts = BADGES[name]()
        sticker = os.path.join(RAW, name + "_subject.png")
        ck.render_icon(parts, sticker, fill=None, pad=0.14 if "halo" in ropts else 0.1, **ropts)
        out = os.path.join(OUT, name + ".png")
        r = subprocess.run([ck._pillow_python(), os.path.join(HERE, "compose.py"), "--badge", sticker, out,
                            copts["bg"]], env=ck._clean_env(), capture_output=True, text=True)
        if r.returncode != 0:
            raise RuntimeError(r.stderr[-2000:])
        print("BADGE", name, sl.tri_count(parts), flush=True)


main()
