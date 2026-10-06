"""Glyph icons: Plus, Close, Check, Star, Hash (chunky extruded symbols with big round bevels and
one gloss streak each), Merge (two small balls + arrows -> one big ball) and the small object icons
Lock, Music, Sound.

Standalone: tools/blender-run.sh art/blender/icons/glyphs.py [-- Plus Close ...]
"""

import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _icons import (argv_names, bake, ck, facing, front_streak, glyph, register, render,  # noqa: E402
                    rounded_poly, thick_polyline, vgrad)

NAMES = ["Plus", "Close", "Check", "Star", "Hash", "Merge", "Lock", "Music", "Sound"]
DEPTH = 0.5  # slab thickness of every flat glyph
TURN = (0, 0, 12)  # every flat glyph is turned a little toward the camera so its thickness shows


def cross_outline(arm=1.0, half=0.36):
    a, L = half, arm
    return [(a, -L), (a, -a), (L, -a), (L, a), (a, a), (a, L), (-a, L), (-a, a), (-L, a), (-L, -a), (-a, -a),
            (-a, -L)]


def rotate2d(pts, deg):
    c, s = math.cos(math.radians(deg)), math.sin(math.radians(deg))
    return [(x * c - y * s, x * s + y * c) for x, y in pts]


@register("Plus")
def plus():
    """Fat mint plus."""
    m = vgrad("Plus", ck.mix("Mint", "White", 0.22), "Emerald", -1.0, 1.0)
    body = glyph(rounded_poly(cross_outline(), 0.26, 0.1), DEPTH, m, "Plus", bevel=0.15, segments=5)
    streak = front_streak([(-0.11, 0.25), (-0.11, 0.5), (-0.09, 0.72)], 0.12, -DEPTH / 2)
    parts = [body, streak]
    ck.group(parts, "PlusIcon", rotation=TURN)
    return parts


@register("Close")
def close():
    """Fat coral X."""
    m = vgrad("Close", ck.mix("Coral", "Pink", 0.3), ck.mix("Coral", "HotPink", 0.45), -1.0, 1.0)
    body = glyph(rounded_poly(rotate2d(cross_outline(1.08, 0.35), 45), 0.26, 0.1), DEPTH, m, "Close", bevel=0.15,
                 segments=5)
    streak = front_streak([(-0.69, 0.81), (-0.49, 0.61), (-0.29, 0.41)], 0.12, -DEPTH / 2)
    parts = [body, streak]
    ck.group(parts, "CloseIcon", rotation=TURN)
    return parts


@register("Check")
def check():
    """Fat lime tick."""
    m = vgrad("Check", ck.mix("Lime", "White", 0.2), "Emerald", -0.9, 0.9)
    outline = rounded_poly(thick_polyline([(-0.95, 0.05), (-0.35, -0.6), (0.98, 0.82)], 0.31, 8), 0.12, 0.12, 4)
    body = glyph(outline, DEPTH, m, "Check", bevel=0.15, segments=5)
    streak = front_streak([(-0.01, -0.12), (0.257, 0.165), (0.52, 0.45)], 0.12, -DEPTH / 2)
    parts = [body, streak]
    ck.group(parts, "CheckIcon", rotation=TURN)
    return parts


@register("Star")
def star():
    """Puffy sunny star."""
    m = vgrad("Star", ck.mix("Sunny", "White", 0.25), "Orange", -0.9, 1.0)
    body = glyph(ck.star_points(5, 1.0, 0.52, round_steps=3), 0.56, m, "Star", bevel=0.2, segments=6)
    streak = front_streak([(-0.42, 0.28), (-0.22, 0.42), (-0.06, 0.6)], 0.12, -0.28)
    parts = [body, streak]
    ck.group(parts, "StarIcon", rotation=TURN)
    return parts


@register("Hash")
def hash_():
    """Chunky slanted # for rank numbers: thick bars with wide open gaps, a two-tone candy gradient
    (sunny orange on top to coral pink below) and one crisp gloss streak."""
    m = vgrad("Hash", ck.mix("Sunny", "Orange", 0.3), ck.mix("Coral", "HotPink", 0.35), -1.15, 1.15)
    bars = []
    # Two upright bars leaning right and two cross bars, as one outline each (the overlaps share
    # one front plane, so they read as a single moulded #). The square hole in the middle is wide
    # enough to stay open after the sticker outline, also at 48 px.
    hw, lean, gap = 0.25, 0.14, 0.63
    for x in (-gap, gap):
        bars.append(rounded_poly([(x - hw - lean, -1.18), (x + hw - lean, -1.18), (x + hw + lean, 1.18),
                                  (x - hw + lean, 1.18)], 0.2, 0.0))
    for z in (-gap, gap):
        bars.append(rounded_poly([(-1.24, z - hw), (1.24, z - hw), (1.24, z + hw), (-1.24, z + hw)], 0.2, 0.0))
    parts = []
    for i, outline in enumerate(bars):
        # Cross bars sit a hair behind the uprights so the front faces never fight.
        parts.append(glyph(outline, DEPTH, m, "Hash%d" % i, bevel=0.15, segments=5, y=0.0 if i < 2 else 0.012))
    # Streak up the upper part of the left upright (between the top cross bar and its top end).
    parts.append(front_streak([(-0.55, 1.0), (-0.59, 0.68), (-0.63, 0.36)], 0.13, -DEPTH / 2))
    ck.group(parts, "HashIcon", rotation=TURN)
    return parts


@register("Merge")
def merge():
    """Two become one bigger: two chunky cobalt balls tucked behind the left and right of one big
    glossy sunny ball (touching it), each with a fat short coral arrow on its face pointing inward,
    and a white star on the big ball."""
    small_m = vgrad("MergeSmall", ck.mix("Cobalt", "Blue", 0.6), ck.mix("Cobalt", "BlueDeep", 0.1), -0.7, 1.3)
    big_m = vgrad("MergeBig", ck.mix("Sunny", "White", 0.5), ck.mix("Sunny", "Butter", 0.25), -1.3, 1.3,
                  emission=0.08)
    arrow_m = vgrad("MergeArrow", ck.mix("Coral", "White", 0.18), ck.mix("Coral", "RedOrange", 0.3), -0.3, 1.0)
    star_m = ck.toy_material("MergeStar", "White")
    rs, rb = 0.98, 1.4
    parts = [ck.sphere(rb, 56, 28, big_m, "Big", (0, 0, 0))]
    parts.append(ball_streak((0, 0, 0), rb))
    # Arrow outline pointing +x from its tail at the origin: short fat shaft, wide round-cornered head.
    arrow = rounded_poly([(0.0, -0.25), (0.42, -0.25), (0.42, -0.56), (1.06, 0.0), (0.42, 0.56), (0.42, 0.25),
                          (0.0, 0.25)], 0.16, 0.08)
    for side in (-1, 1):
        c = (side * 1.6, 0.58)
        parts.append(ck.sphere(rs, 48, 24, small_m, "Small", (c[0], 0.55, c[1])))
        parts.append(ball_streak((c[0], 0.55, c[1]), rs))
        d = (-side * math.cos(math.radians(14)), -math.sin(math.radians(14)))
        ang = math.degrees(math.atan2(d[1], d[0]))
        tail = (c[0] + side * 0.36, c[1] + 0.06)
        pts = [(tail[0] + x, tail[1] + z) for x, z in rotate2d(arrow, ang)]
        parts.append(glyph(pts, 0.46, arrow_m, "Arrow", bevel=0.14, segments=4, y=-1.1))
    star = glyph(ck.star_points(5, 0.56, 0.29, round_steps=3), 0.24, star_m, "Star", bevel=0.08, segments=3,
                 y=-rb + 0.08)
    star.location = (0.12, 0, -0.12)
    parts.append(bake(star))
    ck.group(parts, "MergeIcon", rotation=TURN)
    return parts


def ball_streak(c, r):
    """Gloss streak hugging the upper left of a ball (toward the key light)."""
    pts = []
    for a in (-158, -142, -126, -110):
        aa, pp = math.radians(a), math.radians(48)
        n = (math.sin(pp) * math.cos(aa), math.sin(pp) * math.sin(aa), math.cos(pp))
        pts.append(tuple(c[i] + n[i] * (r + 0.015) for i in range(3)))
    mid = pts[len(pts) // 2]
    return ck.gloss_streak(pts, r * 0.2, tuple(mid[i] - c[i] for i in range(3)))


@register("Lock")
def lock():
    """Chunky gold padlock: silver shackle, violet keyhole, gloss streak on the body."""
    body_m = vgrad("LockBody", ck.mix("Sunny", "White", 0.15), "GoldDeep", 0.0, 1.4)
    shackle_m = ck.toy_material("Shackle", ck.mix("Chrome", "Steel", 0.45))
    hole_m = ck.toy_material("Keyhole", ck.DARK)
    d = 0.9
    body = ck.rounded_box((1.8, d, 1.4), 0.3, 5, body_m, "Body")
    shackle = facing(ck.torus(0.55, 0.19, 32, 14, arc=180, mat=shackle_m, name="Shackle"))
    shackle.location.z = 1.62
    parts = [body, shackle]
    for x in (-0.55, 0.55):
        parts.append(ck.capsule(0.19, 0.8, 20, 4, shackle_m, "Leg", (x, 0, 1.38), axis="Z"))
    keyhole = [(x, y + 0.2) for x, y in [(0.0 + 0.2 * math.cos(math.radians(a)), 0.2 * math.sin(math.radians(a)))
                                         for a in range(-60, 241, 15)]]
    keyhole += [(-0.14, -0.28), (0.14, -0.28)]
    hole = glyph(rounded_poly(keyhole, 0.06, 0.04, 3), 0.12, hole_m, "Keyhole", bevel=0.035, segments=2,
                 y=-d / 2 - 0.01)
    hole.location.z = 0.62
    parts.append(bake(hole))
    parts.append(front_streak([(-0.52, 0.4), (-0.55, 0.7), (-0.48, 1.0)], 0.12, -d / 2))
    ck.group(parts, "LockIcon", rotation=(0, 0, 10))
    return parts


@register("Music")
def music():
    """Beamed pair of eighth notes in lilac-grape with gloss on the note heads."""
    m = vgrad("Note", ck.mix("Grape", "White", 0.3), ck.mix("Grape", "GrapeDeep", 0.5), -1.1, 1.2)
    parts = []
    heads = [(-0.55, -0.72), (0.62, -0.5)]
    for i, (x, z) in enumerate(heads):
        h = ck.sphere(0.42, 40, 20, m, "Head%d" % i, (x, 0, z))
        h.scale = (1.0, 0.62, 0.74)
        h.rotation_euler = (0, math.radians(22), 0)
        parts.append(h)
        # Stem up the right side of the head.
        parts.append(ck.rounded_box((0.24, 0.32, 1.65), 0.1, 3, m, "Stem%d" % i, (x + 0.29, 0, z - 0.02)))
        # Gloss on the upper-left of the head, on the (unturned) ellipsoid surface.
        pts = []
        for dx, dz in ((-0.22, 0.0), (-0.14, 0.1), (-0.02, 0.16)):
            k = max(0.05, 1 - (dx / 0.42) ** 2 - (dz / 0.31) ** 2)
            pts.append((x + dx, -0.26 * math.sqrt(k) - 0.03, z + dz))
        parts.append(ck.gloss_streak(pts, 0.1, (-0.3, -1, 0.3)))
    # Thick beam joining the stem tops, sloping up to the right.
    (x0, z0), (x1, z1) = heads[0], heads[1]
    a, b = (x0 + 0.29 - 0.12, z0 + 1.63), (x1 + 0.29 + 0.12, z1 + 1.63)
    ang = math.atan2(b[1] - a[1], b[0] - a[0])
    n = (-math.sin(ang) * 0.42, math.cos(ang) * 0.42)
    beam = glyph(rounded_poly([(a[0] - n[0], a[1] - n[1]), (b[0] - n[0], b[1] - n[1]), b, a], 0.12, 0.0), 0.36, m,
                 "Beam", bevel=0.1)
    parts.append(beam)
    parts.append(front_streak([(a[0] + 0.15, a[1] - 0.12), (0.0, (a[1] + b[1]) / 2 - 0.12),
                               (b[0] - 0.35, b[1] - 0.17)], 0.08, -0.18))
    ck.group(parts, "MusicIcon", rotation=TURN)
    return parts


@register("Sound")
def sound():
    """Speaker with two sound waves: blue speaker, sunny waves."""
    m = vgrad("Speaker", ck.mix("Blue", "White", 0.2), "BlueDeep", -0.9, 0.9)
    wave_m = vgrad("Waves", ck.mix("Sunny", "White", 0.2), "Orange", -0.9, 0.9)
    outline = [(-1.0, -0.36), (-0.5, -0.36), (0.12, -0.9), (0.12, 0.9), (-0.5, 0.36), (-1.0, 0.36)]
    body = glyph(rounded_poly(outline, 0.16, 0.08), DEPTH, m, "Speaker", bevel=0.14)
    parts = [body]
    for i, (r, minor) in enumerate(((0.5, 0.14), (0.92, 0.15))):
        w = ck.torus(r, minor, 32, 12, arc=100, mat=wave_m, name="Wave%d" % i)
        w.rotation_euler = (math.radians(90), math.radians(50), 0)
        w.location = (0.12, 0, 0)
        w.scale = (1.0, 1.0, 1.25)  # (local Z becomes depth after the turn) fatter toward the camera
        parts.append(w)
        # Round end caps on the wave tubes.
        for a in (-50, 50):
            x, z = 0.12 + r * math.cos(math.radians(a)), r * math.sin(math.radians(a))
            cap = ck.sphere(minor, 20, 10, wave_m, "WaveCap", (x, 0, z))
            cap.scale = (1.0, 1.25, 1.0)
            parts.append(cap)
    parts.append(front_streak([(-0.86, 0.12), (-0.64, 0.2), (-0.4, 0.4)], 0.1, -DEPTH / 2))
    ck.group(parts, "SoundIcon", rotation=TURN)
    return parts


if __name__ == "__main__":
    render(argv_names() or NAMES)
