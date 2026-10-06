"""Building blocks for the cosmetics icons (icons.py): candy ribbons (trails), stars, cloud puffs,
the winged sneaker, jump chevrons, the leaf badge, the little flexing figure and the hi-res crown.

Reuses the shop icon kit (art/blender/icons_shop/shoplib.py: materials, pose(), sparkles, coins,
gems, crates, bold 3D text). Blender space: Z up, the camera looks from -Y (azimuth 28, elevation 20).
"""

import math
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "icons_shop"))
sys.path.insert(0, HERE)
import bpy  # noqa: E402
from mathutils import Matrix, Vector  # noqa: E402

import shoplib as sl  # noqa: E402  (puts art/blender/lib on sys.path first)
from shoplib import M, ck, pose  # noqa: E402

import _crown  # noqa: E402

SKIN = ck.mix("Sand", "Coral", 0.28)

RAINBOW = ["Grape", "Blue", "Mint", "Sunny", "Orange", "Coral"]  # inner -> outer band
SUNNY = [ck.mix("Sunny", "Orange", 0.55), "Sunny", ck.mix("Sunny", "White", 0.5)]
ROOKIE = [ck.mix("Mint", "Emerald", 0.5), "Mint", ck.mix("Mint", "White", 0.45)]


# ------------------------------------------------------------------------------------------------
# Ribbons
# ------------------------------------------------------------------------------------------------

def catmull(ctrl, n):
    """n points along a Catmull-Rom spline through the control points (end points repeated)."""
    c = [Vector(p) for p in ctrl]
    c = [c[0]] + c + [c[-1]]
    segs = len(c) - 3
    out = []
    for k in range(n):
        t = k / (n - 1) * segs
        i = min(int(t), segs - 1)
        u = t - i
        p0, p1, p2, p3 = c[i], c[i + 1], c[i + 2], c[i + 3]
        out.append(0.5 * ((2 * p1) + (-p0 + p2) * u + (2 * p0 - 5 * p1 + 4 * p2 - p3) * u * u
                          + (-p0 + 3 * p1 - 3 * p2 + p3) * u * u * u))
    return out


def _smooth(e0, e1, x):
    t = max(0.0, min(1.0, (x - e0) / (e1 - e0)))
    return t * t * (3 - 2 * t)


def ribbon(ctrl, colors, band_r=0.13, spacing=0.22, n=56, sides=14, tail=0.25, grow=0.6, flatten=0.5,
           gloss=(0.55, 0.85)):
    """Candy ribbon of parallel round bands (one per colour, inner -> outer) running through `ctrl`
    (x, y, z), flat side toward the viewer. It starts thin (`tail` of full width) at the first control
    point and reaches full width at `grow` of its length. The band offset is in the XZ plane, so the
    last colour sits on the left of the direction of travel (outside of a clockwise arch).
    A gloss streak rides the outermost band between the `gloss` fractions of its length."""
    pts = catmull(ctrl, n)
    nb = len(colors)
    w = [tail + (1 - tail) * _smooth(0.0, grow, k / (n - 1)) for k in range(n)]
    normals = []
    for k in range(n):
        t = pts[min(k + 1, n - 1)] - pts[max(k - 1, 0)]
        nn = Vector((-t.z, 0.0, t.x))
        normals.append(nn.normalized() if nn.length > 1e-6 else Vector((0, 0, 1)))
    parts = []
    for b, col in enumerate(colors):
        off = (b - (nb - 1) / 2) * spacing
        bp = [p + normals[k] * off * w[k] for k, p in enumerate(pts)]
        parts.append(ck.sweep(bp, [band_r * x for x in w], sides, M(col), "Band", flatten=flatten, up=(0, -1, 0)))
    if gloss:
        off = ((nb - 1) / 2) * spacing
        k0, k1 = int(gloss[0] * (n - 1)), int(gloss[1] * (n - 1))
        gp = [pts[k] + normals[k] * off * w[k] + Vector((0, -band_r * w[k] * flatten - 0.015, 0))
              for k in range(k0, k1 + 1, max(1, (k1 - k0) // 5))]
        parts.append(ck.gloss_streak(gp, band_r * 0.8, (0, -1, 0)))
    return parts


# ------------------------------------------------------------------------------------------------
# Stars, puffs, badges
# ------------------------------------------------------------------------------------------------

def star(location, size=0.4, color="Sunny", emission=0.12, depth=0.42, turn=0.0):
    """Chunky five-point star with round tips, facing the camera (world space)."""
    s = ck.extrude_shape(ck.star_points(5, size, size * 0.52, round_steps=2, rotate=90 + turn),
                         depth=size * depth, mat=M(color, emission=emission), name="Star", bevel=size * 0.14)
    s.location = location
    sl.facing(s)
    return s


def puff(balls, color="White"):
    """Soft cloud puff: a metaball blob of ((x, y, z), r) balls."""
    return sl.blob("Puff", [balls], M(color, emission=0.05))


def leaf_points(L=0.44, W=0.25, n=14):
    """Pointed-oval leaf outline along X, counter-clockwise."""
    pts = []
    for k in range(n):
        s = k / n
        pts.append((-L + 2 * L * s, -W * math.sin(math.pi * s) ** 0.8))
    for k in range(n):
        s = k / n
        pts.append((L - 2 * L * s, W * math.sin(math.pi * s) ** 0.8))
    return pts


def leaf(color="Lime", size=1.0):
    """Glossy leaf lying in XY facing +Z with a pale midrib and a little stem (unposed parts)."""
    lf = ck.extrude_shape([(x * size, y * size) for x, y in leaf_points()], depth=0.13 * size, mat=M(color),
                          name="Leaf", bevel=0.05 * size)
    rib = ck.capsule(0.03 * size, 0.62 * size, 10, 2, M(ck.mix(color, "White", 0.55)), "Rib", axis="X")
    rib.location = (0.02 * size, 0, 0.07 * size)
    rib.scale = (1, 1, 0.5)
    stem = ck.sweep([(-0.4 * size, 0, 0), (-0.55 * size, -0.05 * size, 0), (-0.66 * size, -0.14 * size, 0)],
                    [0.05 * size, 0.045 * size, 0.04 * size], 10, M(ck.mix(color, "Emerald", 0.5)), "Stem")
    return [lf, rib, stem]


def leaf_badge(location, size=1.0, turn=-6.0):
    """Round cream "rookie" badge with a thick mint rim and a lime leaf on its face, facing the camera."""
    r = 0.62
    rim_m = M(ck.mix("Mint", "Emerald", 0.35))
    parts = [ck.lathe(ck.round_profile(0, r, -0.12, 0.08, 0.07, 3), 56, M("Cream"), "BadgeFace"),
             ck.torus(r, 0.11, 56, 14, mat=rim_m, name="BadgeRim", location=(0, 0, 0.0))]
    lf = pose(leaf("Lime", 0.9), (0.04, -0.02, 0.12), (0, 0, 38), name="BadgeLeaf")
    parts.append(lf)
    parts.append(ck.gloss_streak([(r * 0.98 * math.cos(math.radians(a)), r * 0.98 * math.sin(math.radians(a)), 0.1)
                                  for a in (118, 132, 146, 160)], 0.08, (0, 0, 1)))
    inner = pose(parts, (0, 0, 0), (0, 0, turn), scale=size, name="Badge")
    outer = pose([inner], location, name="BadgeFacing")
    sl.facing(outer)
    return outer


# ------------------------------------------------------------------------------------------------
# Sneaker
# ------------------------------------------------------------------------------------------------

def fit(ob, lo, hi):
    """Scales and moves mesh `ob` (identity transform) so its bounds become lo..hi."""
    vs = [v.co for v in ob.data.vertices]
    mn = Vector((min(v.x for v in vs), min(v.y for v in vs), min(v.z for v in vs)))
    mx = Vector((max(v.x for v in vs), max(v.y for v in vs), max(v.z for v in vs)))
    s = [(hi[i] - lo[i]) / max(mx[i] - mn[i], 1e-6) for i in range(3)]
    m = Matrix.Translation(Vector(lo)) @ Matrix.Diagonal((s[0], s[1], s[2], 1.0)) @ Matrix.Translation(-mn)
    ob.data.transform(m)
    return ob


def hit(ob, origin, direction):
    """First surface point of `ob` (identity transform) along a ray, or None."""
    bpy.context.view_layer.update()
    ok, loc, nrm, _ = ob.ray_cast(Vector(origin), Vector(direction).normalized())
    return (loc, nrm) if ok else None


def sneaker(body="Coral", wings=True, lines=True):
    """Chunky high-top sneaker along X (toe +X), outer side toward -Y: white sole with a sunny outsole,
    a coral metaball upper with a white toe bumper, collar and laces, a sunny side stripe, a white
    feather wing on each side of the heel and three sunny speed dashes behind it. Unposed parts."""
    parts = [ck.rounded_box((2.6, 1.06, 0.36), 0.16, 4, M("White"), "Sole", (0, 0, 0.1)),
             ck.rounded_box((2.5, 1.0, 0.2), 0.09, 3, M("Sunny"), "Outsole", (0, 0, 0.0))]
    up = sl.blob("Upper", [[((1.0, 0, 0.0), 0.5), ((0.55, 0, 0.1), 0.6), ((0.05, 0, 0.25), 0.66),
                            ((-0.45, 0, 0.35), 0.7), ((-0.65, 0, 0.8), 0.62), ((-0.6, 0, 1.15), 0.52)]],
                 M(body))
    fit(up, (-1.22, -0.48, 0.3), (1.2, 0.48, 1.62))
    parts.append(up)
    # Toe bumper and heel tab.
    toe = ck.sphere(0.42, 40, 20, M("White"), "Toe", (0.95, 0, 0.5))
    toe.scale = (1.0, 1.12, 0.62)
    parts.append(toe)
    top = hit(up, (-0.62, 0, 4), (0, 0, -1))
    tz = top[0].z if top else 1.55
    collar = ck.torus(0.36, 0.12, 40, 14, mat=M("White"), name="Collar", location=(-0.62, 0, tz - 0.08))
    collar.scale = (1.15, 1.0, 1.0)
    collar.rotation_euler = (0, math.radians(-12), 0)
    parts.append(collar)
    # Laces across the top of the foot, each sitting on the upper.
    for x in (0.5, 0.18, -0.14):
        h = hit(up, (x, 0, 4), (0, 0, -1))
        z = h[0].z if h else 1.0
        parts.append(ck.capsule(0.08, 0.72, 14, 3, M("White"), "Lace", (x, 0, z + 0.02), axis="Y"))
    # Side stripe (a swoosh) on the outer side.
    stripe = []
    for x, z in ((-0.85, 0.55), (-0.45, 0.62), (-0.05, 0.75), (0.3, 0.92)):
        h = hit(up, (x, -4, z), (0, 1, 0))
        if h:
            stripe.append(h[0] + Vector((0, -0.02, 0)))
    if len(stripe) >= 3:
        parts.append(ck.sweep(stripe, [0.07, 0.12, 0.11, 0.05][:len(stripe)], 12, M("Sunny"), "Stripe",
                              flatten=0.35, up=(0, -1, 0)))
    if wings:
        for side in (-1, 1):
            h = hit(up, (-0.55, side * 4, 0.95), (0, -side, 0))
            root = h[0] if h else Vector((-0.55, side * 0.5, 0.95))
            root = root + Vector((0, side * 0.06, 0))
            feathers = [(118, 1.15, 0.2), (142, 1.0, 0.18), (166, 0.82, 0.16)]
            for k, (ang, ln, r) in enumerate(feathers):
                a = math.radians(ang)
                d = Vector((math.cos(a), side * 0.12, math.sin(a)))
                pts = [root + d * (ln * t) + Vector((0, side * 0.04 * k, 0)) for t in (0.0, 0.3, 0.65, 1.0)]
                col = ck.mix("White", "Blue", 0.1 + 0.08 * k)
                parts.append(ck.sweep(pts, [r * 0.7, r, r * 0.85, r * 0.42], 14, M(col), "Feather",
                                      flatten=0.42, up=(0, side, 0)))
            parts.append(ck.sphere(0.2, 20, 10, M("White"), "WingRoot", tuple(root)))
    if lines:
        for z, ln, x0 in ((0.45, 0.95, -1.55), (0.95, 1.25, -1.62), (1.42, 0.8, -1.5)):
            parts.append(ck.capsule(0.1, ln, 16, 3, M(ck.mix("Sunny", "White", 0.25), emission=0.15), "Dash",
                                    (x0 - ln / 2, -0.25, z), axis="X"))
    return parts


# ------------------------------------------------------------------------------------------------
# Jump chevrons
# ------------------------------------------------------------------------------------------------

def chevron(color, location, size=1.0, depth=0.5):
    """Chunky rounded up-chevron in the XZ plane (front face toward -Y) with a gloss streak."""
    pts = [(0.0, 0.6), (-1.1, -0.5), (-0.66, -0.94), (0.0, -0.28), (0.66, -0.94), (1.1, -0.5)]
    ch = ck.extrude_shape(pts, depth=depth, mat=M(color), name="Chevron", bevel=0.14, bevel_segments=4)
    sl.bake_matrix(ch, sl.TO_XZ)
    a, b = Vector((-1.1, -0.5)), Vector((0.0, 0.6))
    inward = Vector((0.707, -0.707)) * 0.2
    gp = [a.lerp(b, t) + inward for t in (0.22, 0.34, 0.46, 0.58, 0.68)]
    gl = ck.gloss_streak([(p.x, -depth / 2 - 0.012, p.y) for p in gp], 0.12, (0, -1, 0))
    return pose([ch, gl], location, scale=size, name="ChevronPose")


# ------------------------------------------------------------------------------------------------
# Little flexing figure
# ------------------------------------------------------------------------------------------------

def figure():
    """Tiny toy Chad flexing both arms: blue tank top, sunny swoop hair, happy closed eyes and a big
    smile. Feet at z = -1.25, head top near z = 1.0, facing -Y. Unposed parts."""
    sk = M(SKIN)
    ink = M("Ink")
    parts = [ck.rounded_box((1.0, 0.62, 0.95), 0.26, 4, M("Blue"), "Torso", (0, 0, -0.85), taper=1.22),
             ck.rounded_box((0.86, 0.56, 0.42), 0.16, 3, M("Steel"), "Shorts", (0, 0, -1.2))]
    parts.append(ck.sphere(0.5, 40, 20, sk, "Head", (0, 0, 0.48)))
    hair = ck.sphere(0.5, 40, 20, M("Sunny"), "Hair", (0.0, 0.1, 0.66))
    hair.scale = (1.06, 1.0, 0.78)
    parts.append(hair)
    swoop = ck.sphere(0.24, 24, 12, M("Sunny"), "Swoop", (-0.2, -0.3, 0.95))
    swoop.scale = (1.4, 0.9, 0.7)
    parts.append(swoop)
    for x in (-0.17, 0.17):
        eye = ck.torus(0.085, 0.042, 16, 8, arc=180, mat=ink, name="Eye")
        eye.location = (x, -0.47, 0.5)
        eye.rotation_euler = (math.radians(90), 0, 0)
        parts.append(eye)
        blush = ck.sphere(0.08, 14, 7, M("HotPink"), "Blush", (x * 1.75, -0.41, 0.36))
        blush.scale = (1.0, 0.4, 0.7)
        parts.append(blush)
    smile = [(0.2 * math.cos(math.radians(a)), 0.17 * math.sin(math.radians(a))) for a in range(180, 361, 12)]
    mouth = ck.extrude_shape(smile, depth=0.12, mat=M(ck.mix("Coral", "Ink", 0.5)), name="Mouth", bevel=0.035,
                             bevel_segments=2)
    sl.bake_matrix(mouth, sl.TO_XZ)
    mouth.location = (0, -0.44, 0.34)
    parts.append(mouth)
    for side in (-1, 1):
        sh = Vector((side * 0.58, 0, -0.08))
        el = Vector((side * 1.08, -0.05, -0.02))
        fist = Vector((side * 1.02, -0.08, 0.5))
        parts.append(ck.sweep([sh, sh.lerp(el, 0.5) + Vector((0, 0, 0.06)), el], [0.2, 0.25, 0.19], 18, sk,
                              "UpperArm"))
        parts.append(ck.sphere(0.24, 24, 12, sk, "Bicep", tuple(sh.lerp(el, 0.55) + Vector((0, 0, 0.14)))))
        parts.append(ck.sweep([el, el.lerp(fist, 0.5), fist], [0.19, 0.18, 0.17], 18, sk, "Forearm"))
        parts.append(ck.sphere(0.21, 24, 12, sk, "Fist", tuple(fist + Vector((0, 0, 0.06)))))
        parts.append(ck.sphere(0.22, 24, 12, M("Blue"), "Shoulder", tuple(sh + Vector((0, 0, 0.02)))))
    return parts


def flame_chain(base, height, radius, lean=0.0, n=10, tip=0.2, y=0.0):
    """Metaball balls for one flame tongue (same shape as the shop Fire icon)."""
    balls = []
    for k in range(n):
        t = k / (n - 1)
        balls.append(((base[0] + lean * t ** 1.8, y, base[1] + height * t), tip + (radius - tip) * (1 - t) ** 1.1))
    return balls


# ------------------------------------------------------------------------------------------------
# Crown (hi-res icon version of the game mesh)
# ------------------------------------------------------------------------------------------------

def crown(location=(0, 0, 0), scale=1.0, rotation=(0, 0, 0)):
    parts = _crown.crown(lambda name, color, **kw: M(color, **kw), lod="icon")
    return pose(parts, location, rotation, scale, name="Crown")
