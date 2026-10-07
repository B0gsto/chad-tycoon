"""CARDIO candy prop pack: giant glossy sweets for the themed keyboard-runner stages (chocolate river, candy walls).

    tools/blender-run.sh art/blender/cardio/candy.py [-- Kind ...]
    python3 art/blender/cardio/candy_sheet.py        # contact sheet (system python3 + Pillow)

Same modelling space and finish as build.py / the props: 1 Blender unit = 1 stud, Blender Z = up, Blender -Y = the
front (Roblox -Z), origin at the base centre, colours baked into vertex colours. Each prop has a natural size of
about 6-12 studs; the game scales them. Flat sweets that read best face-on (cookie, peppermint, lollipop, candy bar)
stand upright facing -Y.

Outputs per kind: art/out/props/<Kind>.fbx/.json/.png/_game.png, preview/web/models/props__<Kind>.glb,
and art/out/cardio/candy_info.json (sizes + triangle counts for every kind).
"""

import json
import math
import os
import random
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "props"))
sys.path.insert(0, os.path.join(HERE, "..", "icons"))

from _gym import bmesh, bpy, ck, finish  # noqa: E402
from mathutils import Vector  # noqa: E402
import _icons  # noqa: E402,F401  (fills the Theme palette the render rig uses)

OUT = os.path.join(ck.ROOT, "art", "out", "cardio")
os.makedirs(OUT, exist_ok=True)
TAU = 2 * math.pi

# Candy palette (sRGB 0..255)
CHOC = (98, 52, 32)
CHOC_DARK = (66, 34, 22)
CHOC_MILK = (150, 92, 56)
RED = (236, 38, 58)
WHITE = (255, 252, 246)
PINK = (255, 132, 190)
PINK_LIGHT = (255, 196, 226)
CREAM = (255, 240, 214)
LEAF = (64, 196, 84)
LEAF_DARK = (40, 140, 60)
SEED = (255, 222, 96)
DOUGH = (238, 174, 96)
BISCUIT = (226, 164, 86)
TOAST = (192, 120, 58)
GOLD = (255, 200, 60)
SUNNY = (255, 222, 60)
CYAN = (70, 214, 255)
LIME = (130, 226, 60)
GRAPE = (170, 110, 240)
LAVENDER = (196, 156, 246)
MINT = (110, 236, 204)
WOOD = (226, 176, 112)
SPRINKLES = [(255, 92, 160), SUNNY, CYAN, WHITE, LIME, GRAPE, (255, 140, 50)]

_mats = {}


def M(rgb, **kw):
    key = (tuple(rgb), tuple(sorted(kw.items())))
    if key not in _mats:
        _mats[key] = ck.toy_material("Candy_%d_%d_%d_%d" % (*rgb, len(_mats)), tuple(rgb), **kw)
    return _mats[key]


# ------------------------------------------------------------------------------------------------
# Geometry helpers
# ------------------------------------------------------------------------------------------------

def surface(rings, mats, name, mf=None, smooth=55.0):
    """Mesh from rings of points (a 1-point ring is a pole), quads between neighbouring rings (closed loops);
    mf(i, j) gives the material index of the band i, column j."""
    bm = bmesh.new()
    vr = [[bm.verts.new(p) for p in ring] for ring in rings]
    n = max(len(r) for r in vr)
    for i, (a, b) in enumerate(zip(vr, vr[1:])):
        if len(a) == 1 and len(b) == 1:
            continue
        for j in range(n):
            k = (j + 1) % n
            if len(a) == 1:
                vs = (a[0], b[k], b[j])
            elif len(b) == 1:
                vs = (a[j], a[k], b[0])
            else:
                vs = (a[j], a[k], b[k], b[j])
            f = bm.faces.new(vs)
            f.material_index = mf(i, j) if mf else 0
    bmesh.ops.remove_doubles(bm, verts=bm.verts, dist=1e-5)
    ob = ck.mesh_object(name, bm, mats[0], smooth=False)
    for m in mats[1:]:
        ob.data.materials.append(m)
    ck.shade_smooth(ob, smooth)
    return ob


def lathe2(profile, seg, mats, name, rfn=None, mfn=None, smooth=55.0, phase=0.0):
    """Revolve a (r, z) profile (bottom -> top) around Z. rfn(theta, r, z, i) -> radius; mfn(i, theta, r, z) ->
    material index of the band between profile points i and i + 1."""
    rings = []
    for i, (r, z) in enumerate(profile):
        if r <= 1e-6:
            rings.append([(0.0, 0.0, z)])
            continue
        ring = []
        for j in range(seg):
            t = TAU * j / seg + phase
            rr = rfn(t, r, z, i) if rfn else r
            ring.append((rr * math.cos(t), rr * math.sin(t), z))
        rings.append(ring)

    def mf(i, j):
        if not mfn:
            return 0
        t = TAU * (j + 0.5) / seg + phase
        return mfn(i, t % TAU, (profile[i][0] + profile[i + 1][0]) / 2, (profile[i][1] + profile[i + 1][1]) / 2)

    return surface(rings, mats, name, mf, smooth)


def interp(pts, z):
    """Piecewise-linear r(z) from sorted (r, z) points, smoothstepped between them."""
    if z <= pts[0][1]:
        return pts[0][0]
    for (r0, z0), (r1, z1) in zip(pts, pts[1:]):
        if z <= z1:
            t = (z - z0) / max(z1 - z0, 1e-6)
            t = t * t * (3 - 2 * t)
            return r0 + (r1 - r0) * t
    return pts[-1][0]


def blob(radius, scale, loc, mat, name, seg=16, rings=8, rot=(0, 0, 0)):
    ob = ck.sphere(radius, seg, rings, mat, name, loc)
    ob.scale = scale
    ob.rotation_euler = tuple(math.radians(a) for a in rot)
    ck.shade_smooth(ob, 80)
    return ob


def stick(a, b, radius, mat, name, sides=6, rings=1):
    """Cheap capsule from a to b (sprinkles, stems)."""
    a, b = Vector(a), Vector(b)
    d = b - a
    ob = ck.capsule(radius, d.length + 2 * radius, sides, rings, mat, name)
    ob.rotation_euler = d.to_track_quat("Z", "Y").to_euler()
    ob.location = (a + b) / 2
    ck.shade_smooth(ob, 80)
    return ob


def tube(points, radius, sides, mats, name, mfn=None, up=(0, 1, 0), cap_rings=3):
    """Tube along a polyline with round end caps; mfn(i, j, s) -> material (s = arc length at band i)."""
    pts = [Vector(p) for p in points]
    upv = Vector(up)
    frames = []
    for i, p in enumerate(pts):
        t = (pts[min(i + 1, len(pts) - 1)] - pts[max(i - 1, 0)]).normalized()
        side = t.cross(upv).normalized()
        nrm = side.cross(t).normalized()
        frames.append((p, t, side, nrm))

    def ring(p, side, nrm, r):
        return [p + side * (math.cos(TAU * j / sides) * r) + nrm * (math.sin(TAU * j / sides) * r)
                for j in range(sides)]

    rings, svals = [], []
    p0, t0, s0, n0 = frames[0]
    for k in range(cap_rings, 0, -1):
        a = math.pi / 2 * k / (cap_rings + 0.0)
        if k == cap_rings:
            rings.append([p0 - t0 * radius])
        else:
            rings.append(ring(p0 - t0 * radius * math.sin(a), s0, n0, radius * math.cos(a)))
        svals.append(-radius * math.sin(a))
    s = 0.0
    for i, (p, t, side, nrm) in enumerate(frames):
        if i:
            s += (p - frames[i - 1][0]).length
        rings.append(ring(p, side, nrm, radius))
        svals.append(s)
    p1, t1, s1, n1 = frames[-1]
    for k in range(1, cap_rings + 1):
        a = math.pi / 2 * k / cap_rings
        if k == cap_rings:
            rings.append([p1 + t1 * radius])
        else:
            rings.append(ring(p1 + t1 * radius * math.sin(a), s1, n1, radius * math.cos(a)))
        svals.append(s + radius * math.sin(a))
    return surface(rings, mats, name, (lambda i, j: mfn(i, j, (svals[i] + svals[i + 1]) / 2)) if mfn else None,
                   smooth=70)


def turn(parts, rx=0.0, rz=0.0, lift=0.0):
    """Rotate all parts (degrees) about the origin, then lift them; bakes the transform."""
    piv = ck.group(parts, "Pivot", location=(0, 0, lift), rotation=(rx, 0, rz))
    bpy.context.view_layer.update()
    ck.apply_transforms(parts)
    bpy.data.objects.remove(piv, do_unlink=True)
    return parts


def leaf_fan(centre, n, length, width, mat, droop=0.6, phase=0.0, name="Leaf"):
    out = []
    c = Vector(centre)
    for k in range(n):
        a = phase + TAU * k / n
        d = Vector((math.cos(a), math.sin(a), 0))
        pts = [c, c + d * length * 0.4 + Vector((0, 0, 0.12)), c + d * length * 0.78 - Vector((0, 0, droop * 0.4)),
               c + d * length - Vector((0, 0, droop))]
        out.append(ck.sweep(pts, [width * 0.55, width, width * 0.7, 0.0], 8, mat, name, flatten=0.28,
                            up=(0, 0, 1), smooth_angle=80))
    return out


# ------------------------------------------------------------------------------------------------
# Props
# ------------------------------------------------------------------------------------------------

def strawberry():
    rng = random.Random(11)
    prof = [(0.0, 0.0), (0.5, 0.18), (1.15, 0.8), (1.85, 1.75), (2.45, 2.85), (2.9, 4.0), (3.12, 5.0),
            (3.12, 5.85), (2.85, 6.6), (2.25, 7.15), (1.35, 7.5), (0.0, 7.62)]
    lobes = lambda t: 1 + 0.035 * math.cos(3 * t)  # noqa: E731
    body = lathe2(prof, 28, [M(RED)], "Berry", rfn=lambda t, r, z, i: r * lobes(t), smooth=70)
    # Chocolate dip: a thick shell over the tip up to a wavy line, its top lip tucked into the berry.
    line = lambda t: 3.85 + 0.28 * math.sin(4 * t + 0.6) + 0.12 * math.sin(9 * t)  # noqa: E731
    seg, rings = 28, []
    rings.append([(0, 0, -0.16)])
    for u in (0.06, 0.16, 0.3, 0.45, 0.6, 0.74, 0.86, 0.95, 1.0):
        ring = []
        for j in range(seg):
            t = TAU * j / seg
            z = line(t) * u
            r = interp(prof, z) * lobes(t) + 0.16
            ring.append((r * math.cos(t), r * math.sin(t), z))
        rings.append(ring)
    for dz, dr in ((0.07, 0.08), (0.1, -0.12)):
        ring = []
        for j in range(seg):
            t = TAU * j / seg
            z = line(t) + dz
            r = interp(prof, z) * lobes(t) + dr
            ring.append((r * math.cos(t), r * math.sin(t), z))
        rings.append(ring)
    coat = surface(rings, [M(CHOC)], "Dip", smooth=70)
    parts = [body, coat]
    # Golden seeds on the red top, set in the skin.
    for k in range(20):
        t = TAU * (k * 0.618034 % 1.0) + rng.uniform(-0.1, 0.1)
        z = 4.75 + (k % 5) * 0.52 + rng.uniform(-0.1, 0.1)
        r = interp(prof, z) * lobes(t) + 0.02
        s = blob(0.2, (0.5, 0.75, 1.15), (r * math.cos(t), r * math.sin(t), z), M(SEED), "Seed", 6, 4,
                 rot=(0, 0, math.degrees(t)))
        parts.append(s)
    parts += leaf_fan((0, 0, 7.45), 6, 2.5, 0.62, M(LEAF), droop=0.75, phase=0.3)
    parts.append(stick((0, 0, 7.4), (0.25, 0.1, 8.55), 0.26, M(LEAF_DARK), "Stem", sides=8, rings=2))
    return parts, {"azimuth": 30.0, "elevation": 20.0}


def donut():
    rng = random.Random(5)
    R, r = 3.3, 1.42
    dough = ck.torus(R, r, 28, 12, mat=M(DOUGH), name="Dough", location=(0, 0, r))
    ck.shade_smooth(dough, 80)
    # Frosting: a torus-patch shell over the top, wavy drips on the outside, tucked into the dough at both edges.
    seg, rings = 28, []
    outer = lambda t: 0.12 - 0.5 * max(0.0, math.sin(5 * t + 0.4)) ** 3 + 0.07 * math.sin(11 * t)  # noqa: E731
    inner = math.pi - 0.15
    nband = 9
    for k in range(-1, nband + 2):
        ring = []
        for j in range(seg):
            t = TAU * j / seg
            if k == -1:
                p, rr = outer(t), r - 0.1
            elif k == nband + 1:
                p, rr = inner, r - 0.1
            else:
                p = outer(t) + (inner - outer(t)) * k / nband
                rr = r + (0.07 if k in (0, nband) else 0.17)
            x = R + rr * math.cos(p)
            ring.append((x * math.cos(t), x * math.sin(t), r + rr * math.sin(p)))
        rings.append(ring)
    frost = surface(rings, [M(CHOC_MILK)], "Frosting", smooth=70)
    parts = [dough, frost]
    for k in range(28):
        t = TAU * k / 28 + rng.uniform(-0.08, 0.08)
        p = rng.uniform(0.45, 2.7)
        x = R + (r + 0.2) * math.cos(p)
        c = Vector((x * math.cos(t), x * math.sin(t), r + (r + 0.2) * math.sin(p)))
        a = rng.uniform(0, TAU)
        tang = Vector((-math.sin(t), math.cos(t), 0)) * math.cos(a) + \
            Vector((-math.sin(p) * math.cos(t), -math.sin(p) * math.sin(t), math.cos(p))) * math.sin(a)
        parts.append(stick(c - tang * 0.36, c + tang * 0.36, 0.17, M(SPRINKLES[k % len(SPRINKLES)]), "Sprinkle"))
    turn(parts, rx=-24)  # tip it toward the camera a touch so the frosting reads from the runner's eye line
    return parts, {"azimuth": 30.0, "elevation": 26.0}


def cupcake():
    flute = lambda t, r, z, i: r * (1 + 0.045 * math.cos(16 * t))  # noqa: E731
    wrap = lathe2([(0.0, 0.0), (2.3, 0.0), (2.42, 0.12), (3.0, 3.3), (2.7, 3.3), (0.0, 3.0)], 48,
                  [M(MINT), M(WHITE)], "Wrapper", rfn=flute, smooth=35,
                  mfn=lambda i, t, r, z: int((t / TAU * 8 + 0.125) % 1.0 < 0.5))
    pink = M(PINK)
    parts = [wrap]
    for major, minor, z, ph in ((2.45, 0.95, 3.7, 0), (1.72, 0.85, 4.95, 20), (1.0, 0.74, 6.0, 40)):
        tor = ck.torus(major, minor, 24, 9, mat=pink, name="Frost", location=(0, 0, z))
        tor.rotation_euler = (0, 0, math.radians(ph))
        ck.shade_smooth(tor, 80)
        parts.append(tor)
    parts.append(lathe2([(0.0, 5.9), (1.15, 6.1), (0.95, 6.75), (0.0, 7.05)], 20, [pink], "FrostTop", smooth=80))
    parts.append(blob(0.95, (1, 1, 0.94), (0, 0, 7.75), M(RED), "Cherry", 18, 10))
    parts.append(ck.sweep([(0, 0, 8.45), (0.1, 0, 9.1), (0.45, 0.05, 9.7), (0.95, 0.1, 10.0)],
                          [0.13, 0.12, 0.11, 0.1], 6, M(LEAF_DARK), "CherryStem", up=(0, 1, 0)))
    parts.append(blob(0.22, (1.4, 1, 1), (0.25, -0.62, 8.15), M(WHITE), "Shine", 8, 4))
    rng = random.Random(3)
    for k in range(10):
        t = TAU * k / 10 + 0.3
        rad, z = (2.45 + 0.9 * 0.7, 3.7 + 0.62) if k % 2 == 0 else (1.72 + 0.85 * 0.7, 4.95 + 0.58)
        c = Vector((rad * math.cos(t), rad * math.sin(t), z))
        d = Vector((rng.uniform(-1, 1), rng.uniform(-1, 1), 0.3)).normalized()
        parts.append(stick(c - d * 0.25, c + d * 0.25, 0.12, M(SPRINKLES[k % len(SPRINKLES)]), "Sprinkle"))
    return parts, {"azimuth": 30.0, "elevation": 20.0}


def cookie():
    rng = random.Random(7)
    R, h = 4.2, 0.72
    prof = [(0.0, -h - 0.08), (1.6, -h - 0.06), (3.0, -h)]
    for k in range(5):
        a = -math.pi / 2 + math.pi * k / 4
        prof.append((R - 0.55 + 0.55 * math.cos(a), 0.9 * h * math.sin(a) / 1.0))
    prof += [(3.0, h), (1.6, h + 0.08), (0.0, h + 0.1)]
    bump = lambda t, r, z, i: r * (1 + 0.035 * math.sin(5 * t) + 0.02 * math.sin(11 * t + 1.3))  # noqa: E731
    disc = lathe2(prof, 32, [M(BISCUIT), M(TOAST)], "Cookie", rfn=bump, smooth=60,
                  mfn=lambda i, t, r, z: int(r > 3.3))
    parts = [disc]
    chips = [(0.3, 0.2), (-1.7, 1.2), (1.6, 1.6), (-0.9, -1.8), (1.9, -1.2), (-2.6, -0.3), (0.2, 2.8),
             (2.9, 0.6), (-2.2, 2.3), (0.9, -3.0), (-1.0, 0.9), (-2.6, -2.2)]
    for k, (x, y) in enumerate(chips):
        s = rng.uniform(0.85, 1.15)
        chip = lathe2([(0.0, -0.2), (0.62 * s, -0.15), (0.5 * s, 0.25), (0.0, 0.62 * s)], 8, [M(CHOC_DARK)], "Chip",
                      smooth=70, phase=rng.uniform(0, 1))
        chip.rotation_euler = (rng.uniform(-0.25, 0.25), rng.uniform(-0.25, 0.25), 0)
        chip.location = (x, y, h + 0.06)
        parts.append(chip)
        if k < 6:  # a few on the back too
            back = chip.copy()
            back.data = chip.data.copy()
            bpy.context.scene.collection.objects.link(back)
            back.rotation_euler = (math.pi + rng.uniform(-0.2, 0.2), 0, 0)
            back.location = (-y * 0.9, x * 0.9, -h - 0.06)
            parts.append(back)
    turn(parts, rx=90)  # stand it up, face toward -Y
    return parts, {"azimuth": 26.0, "elevation": 16.0}


def swirl_disc(R, h, arms, twist, colours, name, seg=40, dome=0.12):
    """Hard-candy disc lying in XY (faces +-Z): domed faces, round rim, `arms` spiral stripes cycling `colours`."""
    prof = [(0.0, -h - dome)]
    prof += [(R * f, -h - dome * (1 - f * f)) for f in (0.22, 0.44, 0.64, 0.8)]
    for k in range(7):
        a = -math.pi / 2 + math.pi * k / 6
        prof.append((R - h + h * math.cos(a), h * math.sin(a)))
    prof += [(R * f, h + dome * (1 - f * f)) for f in (0.8, 0.64, 0.44, 0.22)]
    prof.append((0.0, h + dome))
    n = len(colours)

    def mfn(i, t, r, z):
        ph = (t + twist * r * (1 if z > 0 else -1)) / TAU * arms
        return int(math.floor(ph)) % n

    return lathe2(prof, seg, [M(c) for c in colours], name, mfn=mfn, smooth=60)


def peppermint():
    disc = swirl_disc(4.2, 1.0, 16, 0.5, [RED, WHITE], "Peppermint", seg=64, dome=0.35)
    # Twisted cellophane-free wrapper knots would hide the swirl; a glossy white centre dot instead.
    dot = lathe2([(0.0, 1.25), (0.8, 1.3), (0.7, 1.44), (0.0, 1.48)], 20, [M(RED)], "Dot", smooth=70)
    parts = [disc, dot]
    turn(parts, rx=90)
    return parts, {"azimuth": 24.0, "elevation": 14.0}


def lollipop():
    disc = swirl_disc(3.4, 0.6, 4, 0.75, [(255, 92, 170), SUNNY, CYAN, WHITE], "Pop", seg=40)
    parts = [disc]
    turn(parts, rx=90)
    for p in parts:
        p.location = (0, 0, 0)
    # Lift the disc to the top of the stick.
    for v in disc.data.vertices:
        v.co.z += 9.0
    parts.append(stick((0, 0, 0.4), (0, 0, 6.2), 0.34, M(WHITE), "Stick", sides=12, rings=3))
    # Ribbon bow where the stick meets the candy.
    bow = M((255, 70, 120))
    parts.append(blob(0.5, (1, 1, 1), (0, 0, 5.6), bow, "Knot", 12, 6))
    parts.append(blob(0.75, (1.2, 0.55, 0.7), (-0.95, 0, 5.75), bow, "Loop", 12, 6, rot=(0, 25, 0)))
    parts.append(blob(0.75, (1.2, 0.55, 0.7), (0.95, 0, 5.75), bow, "Loop", 12, 6, rot=(0, -25, 0)))
    parts.append(stick((-0.25, 0, 5.4), (-0.7, -0.05, 4.4), 0.2, bow, "Tail", sides=8))
    parts.append(stick((0.25, 0, 5.4), (0.75, -0.05, 4.5), 0.2, bow, "Tail", sides=8))
    return parts, {"azimuth": 24.0, "elevation": 14.0}


def cone():
    rng = random.Random(9)
    prof = [(0.0, 0.0), (0.3, 0.22)]
    for k in range(1, 10):
        z = 0.22 + (6.0 - 0.22) * k / 9
        prof.append((0.3 + (2.25 - 0.3) * k / 9, z))
    prof += [(2.5, 6.05), (2.55, 6.45), (2.2, 6.55), (0.0, 6.5)]

    def waffle(i, t, r, z):
        if i >= 10:
            return 0
        j = int(t / TAU * 32)
        return 1 if ((j + i) % 4 == 0 or (j - i) % 4 == 0) else 0

    shell = lathe2(prof, 32, [M(BISCUIT), M(TOAST)], "Cone", mfn=waffle, smooth=50)
    scoop_prof = [(0.0, 6.3), (2.2, 6.32), (2.75, 6.55), (2.82, 6.85), (2.6, 7.05)]
    zc, rs = 8.35, 2.62
    for k in range(1, 9):
        a = -0.5 + (math.pi / 2 + 0.5) * k / 8
        scoop_prof.append((rs * math.cos(a), zc + rs * math.sin(a)))
    scoop_prof[-1] = (0.0, zc + rs)
    lip = lambda t, r, z, i: r * (1 + (0.07 * math.sin(7 * t) + 0.03 * math.sin(13 * t) if 1 <= i <= 4  # noqa: E731
                                      else 0.025 * math.sin(5 * t)))
    scoop = lathe2(scoop_prof, 32, [M(PINK)], "Scoop", rfn=lip, smooth=70)
    parts = [shell, scoop]
    for t, ln in ((0.6, 1.2), (2.3, 0.8), (4.4, 1.0)):
        x, y = 2.55 * math.cos(t), 2.55 * math.sin(t)
        parts.append(stick((x, y, 6.6), (x * 0.92, y * 0.92, 6.6 - ln), 0.3, M(PINK), "Drip", sides=8, rings=2))
    for k in range(14):
        t = TAU * k / 14 + rng.uniform(-0.2, 0.2)
        a = rng.uniform(0.25, 1.2)
        c = Vector((rs * math.cos(a) * math.cos(t), rs * math.cos(a) * math.sin(t), zc + rs * math.sin(a)))
        d = Vector((rng.uniform(-1, 1), rng.uniform(-1, 1), rng.uniform(-1, 1))).normalized()
        d = (d - c.normalized() * d.dot(c.normalized())).normalized()
        parts.append(stick(c - d * 0.3, c + d * 0.3, 0.15, M(SPRINKLES[k % len(SPRINKLES)]), "Sprinkle"))
    parts.append(stick((0.6, -0.3, 9.4), (1.6, 0.4, 12.0), 0.32, M(CHOC), "Wafer", sides=8, rings=2))
    return parts, {"azimuth": 30.0, "elevation": 18.0}


def candy_bar():
    choc, wrapper, foil = M(CHOC), M(RED), M(GOLD)
    core = ck.rounded_box((5.6, 1.1, 9.6), 0.3, 2, choc, "Bar", (0, 0, 0.2))
    parts = [core]
    for col in (-1, 1):
        for row in range(3):
            z = 5.45 + row * 1.42
            for side in (-1, 1):
                parts.append(ck.rounded_box((2.35, 0.4, 1.15), 0.18, 2, choc, "Block",
                                            (col * 1.33, side * 0.55, z)))
    # Bite out of the top right corner (the bite face gets a lighter milk chocolate).
    bite = M(CHOC_MILK)
    cutters = []
    for c, rr in (((2.9, 0, 9.85), 1.35), ((1.75, 0, 10.45), 1.0), ((3.25, 0, 8.6), 0.95)):
        cu = ck.sphere(rr, 20, 10, bite, "Bite", c)
        cu.hide_render = True
        cu.hide_set(True)
        cutters.append(cu)
    for ob in parts:
        for cu in cutters:
            mod = ob.modifiers.new("Bite", "BOOLEAN")
            mod.operation = "DIFFERENCE"
            mod.object = cu
            mod.solver = "EXACT"
            try:
                mod.material_mode = "TRANSFER"
            except (AttributeError, TypeError):
                pass
    parts.append(ck.rounded_box((6.1, 1.7, 4.9), 0.32, 3, wrapper, "Wrapper", (0, 0, 0.0)))
    parts.append(ck.rounded_box((5.85, 1.42, 0.5), 0.12, 1, foil, "Foil", (0, 0, 4.75)))
    parts.append(ck.rounded_box((6.25, 1.85, 0.42), 0.16, 1, M((200, 20, 40)), "Crimp", (0, 0, 0.0)))
    parts.append(ck.rounded_box((4.5, 0.2, 2.5), 0.2, 2, M(WHITE), "Label", (0, -0.82, 1.1)))
    star = ck.extrude_shape(ck.star_points(5, 0.95, 0.45, round_steps=1), depth=0.26, mat=M(SUNNY), name="Star",
                            bevel=0.06, bevel_segments=1)
    star.rotation_euler = (math.radians(90), 0, 0)
    star.location = (0, -0.98, 2.35)
    parts.append(star)
    return parts, {"azimuth": 28.0, "elevation": 16.0}


def candy_cane():
    pts = [(0, 0, 0.0)]
    n = 18
    for k in range(1, n + 1):
        pts.append((0, 0, 7.2 * k / n))
    for k in range(1, 15):
        a = math.pi - math.pi * k / 14
        pts.append((1.55 + 1.55 * math.cos(a), 0, 7.2 + 1.55 * math.sin(a)))
    pts += [(3.1, 0, 6.75), (3.1, 0, 6.3)]
    sides = 16

    def stripe(i, j, s):
        ph = (s / 1.5 + j / sides) % 1.0
        return 0 if ph < 0.42 else (2 if ph < 0.5 or ph > 0.92 else 1)

    cane = tube(pts, 0.62, sides, [M(RED), M(WHITE), M((80, 200, 110))], "Cane", mfn=stripe)
    return [cane], {"azimuth": 24.0, "elevation": 14.0}


def gummy_bear():
    g, light, dark = M((120, 222, 60), coat=1.0), M((190, 246, 140), coat=1.0), M((30, 40, 50))
    parts = [
        blob(1.0, (2.25, 1.75, 2.6), (0, 0, 3.0), g, "Body", 20, 10),
        blob(1.0, (1.5, 0.5, 1.7), (0, -1.45, 2.9), light, "Belly", 14, 7),
        blob(1.0, (2.0, 1.65, 1.8), (0, 0, 6.35), g, "Head", 20, 10),
        blob(0.78, (1, 0.62, 1), (-1.45, 0, 7.85), g, "Ear", 12, 6),
        blob(0.78, (1, 0.62, 1), (1.45, 0, 7.85), g, "Ear", 12, 6),
        blob(0.42, (1, 0.5, 1), (-1.45, -0.4, 7.85), light, "EarIn", 10, 5),
        blob(0.42, (1, 0.5, 1), (1.45, -0.4, 7.85), light, "EarIn", 10, 5),
        blob(1.0, (0.95, 0.62, 0.7), (0, -1.38, 5.95), light, "Muzzle", 14, 7),
        blob(0.3, (1.2, 0.8, 0.85), (0, -1.98, 6.3), dark, "Nose", 10, 5),
        blob(0.26, (1, 0.6, 1.2), (-0.72, -1.5, 6.95), dark, "Eye", 10, 5),
        blob(0.26, (1, 0.6, 1.2), (0.72, -1.5, 6.95), dark, "Eye", 10, 5),
        blob(0.09, (1, 1, 1), (-0.64, -1.68, 7.1), M(WHITE), "Glint", 6, 3),
        blob(0.09, (1, 1, 1), (0.8, -1.68, 7.1), M(WHITE), "Glint", 6, 3),
        blob(1.0, (0.78, 0.78, 1.3), (-2.05, -0.45, 4.0), g, "Arm", 12, 6, rot=(0, -32, 0)),
        blob(1.0, (0.78, 0.78, 1.3), (2.05, -0.45, 4.0), g, "Arm", 12, 6, rot=(0, 32, 0)),
        blob(1.0, (1.05, 1.15, 1.0), (-1.2, -0.55, 1.0), g, "Leg", 12, 6),
        blob(1.0, (1.05, 1.15, 1.0), (1.2, -0.55, 1.0), g, "Leg", 12, 6),
    ]
    return parts, {"azimuth": 28.0, "elevation": 16.0}


def macaron():
    shell, foot, fill = M((178, 128, 242)), M((236, 222, 255)), M((255, 251, 242))
    R = 3.6
    bot = lathe2([(0.0, 0.0), (2.4, 0.04), (3.15, 0.3), (3.5, 0.75), (3.45, 1.05), (0.0, 1.05)], 36, [shell],
                 "ShellLow", smooth=60)
    top_prof = [(0.0, 3.05), (3.45, 3.05), (3.55, 3.35)]
    for k in range(1, 7):
        a = math.pi / 2 * k / 6
        top_prof.append((3.55 * math.cos(a) if k < 6 else 0.0, 3.35 + 1.75 * math.sin(a)))
    top = lathe2(top_prof, 36, [shell], "ShellTop", smooth=60)
    parts = [bot, top]
    for z in (1.2, 2.88):
        tor = ck.torus(3.42, 0.3, 36, 6, mat=foot, name="Foot", location=(0, 0, z))
        for v in tor.data.vertices:
            t = math.atan2(v.co.y, v.co.x)
            k = 1 + 0.035 * math.sin(23 * t)
            v.co.x *= k
            v.co.y *= k
        ck.shade_smooth(tor, 80)
        parts.append(tor)
    filling = lathe2(ck.round_profile(0, 3.3, 1.2, 2.95, 0.5, 3), 36, [fill], "Filling", smooth=60)
    parts.append(filling)
    turn(parts, rx=-12)
    return parts, {"azimuth": 30.0, "elevation": 22.0}


def truffle():
    prof = [(0.0, 0.15), (2.85, 0.15), (3.15, 0.45), (3.18, 0.95), (2.95, 1.7), (2.45, 2.6), (1.8, 3.6),
            (1.15, 4.6), (0.62, 5.6), (0.3, 6.4), (0.0, 6.95)]
    ridge = lambda t, r, z, i: r * (1 + (0.06 * math.cos(6 * t + z * 1.1) if z > 0.8 else 0))  # noqa: E731
    kiss = lathe2(prof, 36, [M(CHOC)], "Kiss", rfn=ridge, smooth=70)
    cup = lathe2([(0.0, 0.0), (2.95, 0.0), (3.6, 1.45), (3.42, 1.45), (2.85, 0.16), (0.0, 0.16)], 60,
                 [M(PINK), M(PINK_LIGHT)], "Cup", rfn=lambda t, r, z, i: r * (1 + 0.04 * math.cos(20 * t)),
                 mfn=lambda i, t, r, z: int((t / TAU * 10 + 0.1) % 1.0 < 0.5), smooth=35)
    plume = ck.sweep([(0, 0, 6.6), (0.12, 0, 7.6), (0.55, -0.05, 8.5), (1.3, -0.1, 9.0), (1.9, -0.12, 9.05)],
                     [0.32, 0.36, 0.36, 0.34, 0.2], 8, M(WHITE), "Plume", flatten=0.2, up=(0, 1, 0),
                     smooth_angle=80)
    pts = []
    for k in range(49):
        a = TAU * k / 48
        z = 3.0 + 0.5 * math.sin(4 * a)
        rr = interp(prof, z) * (1 + 0.06 * math.cos(6 * a + z * 1.1)) + 0.06
        pts.append((rr * math.cos(a), rr * math.sin(a), z))
    drizzle = ck.sweep(pts, [0.17] * 49, 6, M(CREAM), "Drizzle", up=(0, 0, 1), smooth_angle=80, caps=False)
    return [kiss, cup, plume, drizzle], {"azimuth": 30.0, "elevation": 18.0}


def cotton_cloud():
    """Fluffy pink cotton-candy cloud: big lumpy puffs, lighter toward the top, flat-ish underside."""
    puffs = [((0, 0, 2.7), 2.5), ((-2.7, 0.2, 2.0), 1.9), ((2.75, 0.1, 2.1), 2.0), ((-1.3, -0.4, 3.9), 1.8),
             ((1.5, -0.3, 3.75), 1.75), ((-4.5, 0.0, 1.45), 1.3), ((4.55, 0.2, 1.5), 1.35), ((0.2, 1.3, 2.2), 2.1),
             ((0.1, -0.7, 5.0), 1.35), ((-2.9, -0.9, 3.2), 1.15), ((3.0, -0.8, 3.3), 1.2), ((-0.9, -1.6, 2.4), 1.3),
             ((1.3, -1.7, 2.3), 1.2), ((-5.6, 0.1, 1.0), 0.8)]
    shades = [(232, 150, 236), PINK, (255, 170, 214), PINK_LIGHT, (255, 222, 238)]
    parts = []
    for c, r in puffs:
        top = c[2] + r
        col = shades[min(len(shades) - 1, int((top - 2.4) / 1.0))]
        ob = ck.sphere(r, 14, 7, M(col, roughness=0.5, coat=0.15), "Puff", c)
        for v in ob.data.vertices:
            # lumpy, fluffy surface; squashed flat-ish underside
            n = v.co.normalized()
            v.co *= 1 + 0.07 * math.sin(5 * n.x + 3 * n.z) * math.cos(4 * n.y + 2 * n.x)
            wz = c[2] + v.co.z
            if wz < 0.9:
                v.co.z = 0.9 - c[2] + (wz - 0.9) * 0.3
        ck.shade_smooth(ob, 80)
        parts.append(ob)
    return parts, {"azimuth": 30.0, "elevation": 18.0}


def ice_cube():
    body = ck.rounded_box((5.6, 5.6, 6.6), 0.95, 4, M((140, 240, 214), coat=1.0), "Ice", (0, 0, 0))
    frost = ck.rounded_box((5.75, 5.75, 0.9), 0.42, 3, M((225, 255, 246)), "Frost", (0, 0, 5.95))
    parts = [body, frost]
    for (ax, az), (bx, bz) in (((-2.0, 1.4), (-1.0, 4.8)), ((-1.0, 1.2), (-0.5, 2.6))):
        parts.append(stick((ax, -2.86, az), (bx, -2.86, bz), 0.2, M(WHITE), "Glint", sides=8))
    for x in (-1.6, 0.0, 1.6):  # pop grooves on the side faces
        parts.append(ck.rounded_box((0.5, 5.72, 4.2), 0.2, 2, M((150, 246, 222)), "Groove", (x, 0, 1.0)))
    parts.append(ck.rounded_box((1.7, 0.65, 4.8), 0.32, 3, M(WOOD), "PopStick", (0, 0, 5.6)))
    # Frost drips over the front edge.
    for x, ln in ((-1.9, 0.9), (-0.4, 0.55), (1.2, 1.1), (2.3, 0.6)):
        parts.append(stick((x, -2.78, 6.3), (x, -2.86, 6.1 - ln), 0.38, M((225, 255, 246)), "Drip", sides=8,
                           rings=2))
    return parts, {"azimuth": 30.0, "elevation": 20.0}


KINDS = {
    "CandyStrawberry": strawberry,
    "CandyDonut": donut,
    "CandyCupcake": cupcake,
    "CandyCookie": cookie,
    "CandySwirl": peppermint,
    "CandyCone": cone,
    "CandyBar": candy_bar,
    "CandyCane": candy_cane,
    "CandyLollipop": lollipop,
    "CandyGummyBear": gummy_bear,
    "CandyMacaron": macaron,
    "CandyTruffle": truffle,
    "CandyCottonCloud": cotton_cloud,
    "CandyIceCube": ice_cube,
}


def main():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    kinds = argv or list(KINDS)
    info_path = os.path.join(OUT, "candy_info.json")
    info = json.load(open(info_path)) if os.path.exists(info_path) else {}
    info["axes"] = "Roblox studs, size = [X, Y up, Z]; mesh origin = base centre; front = -Z (Blender -Y)"
    for kind in kinds:
        parts, rk = KINDS[kind]()
        obj, tris = finish(parts, kind, rk)
        obj.hide_render = True
        obj.hide_set(True)
        sx, sy, sz = obj["chad_size"]
        info["props/" + kind] = {"size": [round(sx, 3), round(sz, 3), round(sy, 3)], "tris": tris}
        print("CANDY", kind, info["props/" + kind])
    with open(info_path, "w") as f:
        json.dump(info, f, indent=1)


main()
