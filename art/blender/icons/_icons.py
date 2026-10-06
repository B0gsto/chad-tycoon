"""Shared setup for the HUD icon set (art/out/icons/<Name>.png).

Every icon is a build function registered under the exact name the UI code uses (Kit.ICONS). Icon
scripts are importable groups; render.py renders any selection in one Blender run:

    tools/blender-run.sh art/blender/icons/render.py -- Coin Gem      # some icons
    tools/blender-run.sh art/blender/icons/render.py                  # every icon

All icons go through ck.render_icon with the same 3/4 ortho camera, the same white sticker outline
and drop shadow, and the same framing: the projected bounding box of every icon fills ICON_BOX of
the square (no coverage-based fill), so the set has one bounding box and reads as one family. Front of every icon is
-Y, up is +Z. Flat glyphs (Plus, Close, Check, ...) are drawn as 2D outlines in the XZ plane and
extruded toward the camera with big round bevels (see glyph()).
"""

import math
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "lib"))
sys.path.insert(0, HERE)

import bpy  # noqa: E402
import chadkit as ck  # noqa: E402
import theme_palette  # noqa: E402
from mathutils import Matrix, Vector  # noqa: E402

theme_palette.fill(ck)  # Theme.World keys written as Luau constants (Sunny, Coral, White, ...)

OUT = os.path.join(ck.ROOT, "art", "out", "icons")
os.makedirs(OUT, exist_ok=True)

REGISTRY = {}  # icon name -> build function returning the list of parts
ORDER = []

SKIN = (255, 196, 148)  # warm peachy skin (Chad, Invite)
HAIR = (196, 128, 72)  # light caramel brown hair (never dark chocolate)
GOLD_HAIR = ((255, 214, 92), (255, 146, 56))  # golden-orange quiff: top, bottom
ICON_PAD = 0.075  # margin on each side: the bounding box fills 85% of the square


def register(name):
    def deco(fn):
        REGISTRY[name] = fn
        ORDER.append(name)
        return fn

    return deco


def render(names=None):
    """Builds and renders the given icon names (default: every registered icon) to OUT."""
    for name in names or list(ORDER):
        ck.reset_scene()
        parts = REGISTRY[name]()
        path = ck.render_icon(parts, os.path.join(OUT, name + ".png"), pad=ICON_PAD, fill=None)
        print("CHAD_ICON", name, path)


def argv_names():
    """Icon names given after `--` on the Blender command line."""
    if "--" in sys.argv:
        return [a for a in sys.argv[sys.argv.index("--") + 1:] if a]
    return []


# ------------------------------------------------------------------------------------------------
# 2D outline helpers (x right, y up; turned into the XZ plane by glyph())
# ------------------------------------------------------------------------------------------------


def signed_area(pts):
    return 0.5 * sum(pts[i][0] * pts[(i + 1) % len(pts)][1] - pts[(i + 1) % len(pts)][0] * pts[i][1]
                     for i in range(len(pts)))


def ccw(pts):
    return list(pts) if signed_area(pts) > 0 else list(reversed(pts))


def rounded_poly(pts, r_convex=0.15, r_concave=0.08, steps=5):
    """Rounds every corner of a closed polygon (convex corners by r_convex, concave by r_concave)
    with a quadratic curve between the two tangent points. Returns a CCW outline."""
    pts = ccw(pts)
    n = len(pts)
    out = []
    for i in range(n):
        p, v, q = Vector(pts[i - 1]), Vector(pts[i]), Vector(pts[(i + 1) % n])
        d1, d2 = p - v, q - v
        l1, l2 = d1.length, d2.length
        d1.normalize()
        d2.normalize()
        turn = (v.x - p.x) * (q.y - v.y) - (v.y - p.y) * (q.x - v.x)
        r = r_convex if turn > 0 else r_concave
        ang = math.acos(max(-1.0, min(1.0, d1.dot(d2))))
        if r <= 0 or ang > math.pi - 1e-3:
            out.append((v.x, v.y))
            continue
        t = min(r / math.tan(ang / 2), l1 * 0.48, l2 * 0.48)
        a, b = v + d1 * t, v + d2 * t
        for k in range(steps + 1):
            s = k / steps
            c = a * (1 - s) ** 2 + v * (2 * (1 - s) * s) + b * s * s
            out.append((c.x, c.y))
    return out


def circle_pts(cx, cy, r, steps=24, a0=0.0, a1=360.0):
    return [(cx + r * math.cos(math.radians(a0 + (a1 - a0) * k / steps)),
             cy + r * math.sin(math.radians(a0 + (a1 - a0) * k / steps))) for k in range(steps + 1)]


def thick_polyline(pts, half, cap_steps=8):
    """Outline of a fat stroke through `pts` (round caps, mitred joints), CCW."""
    P = [Vector(p) for p in pts]
    n = len(P)

    def normal(i):
        d = (P[i + 1] - P[i]).normalized()
        return Vector((-d.y, d.x))

    def side(sign):
        res = []
        for i in range(n):
            if i == 0:
                res.append(P[0] + normal(0) * half * sign)
            elif i == n - 1:
                res.append(P[-1] + normal(n - 2) * half * sign)
            else:
                n1, n2 = normal(i - 1), normal(i)
                m = (n1 + n2).normalized()
                res.append(P[i] + m * (half / max(0.3, m.dot(n1))) * sign)
        return res

    left, right = side(1), side(-1)
    out = [(v.x, v.y) for v in right]
    d = (P[-1] - P[-2]).normalized()
    a0 = math.degrees(math.atan2(-d.x, d.y))  # from the right side round the end cap
    out += circle_pts(P[-1].x, P[-1].y, half, cap_steps, a0, a0 + 180)[1:-1]
    out += [(v.x, v.y) for v in reversed(left)]
    d = (P[1] - P[0]).normalized()
    a0 = math.degrees(math.atan2(d.x, -d.y))
    out += circle_pts(P[0].x, P[0].y, half, cap_steps, a0, a0 + 180)[1:-1]
    return ccw(out)


# ------------------------------------------------------------------------------------------------
# 3D builders
# ------------------------------------------------------------------------------------------------


def bake(ob):
    """Applies the object's own transform to its mesh (keeps modifiers), so Object texture
    coordinates (gradient_material mode "Z") follow world up."""
    bpy.context.view_layer.update()  # matrix_world is stale until the depsgraph updates
    ck.apply_transforms([ob])
    return ob


def glyph(outline, depth, mat, name, bevel=0.14, segments=4, y=0.0):
    """Extrudes a 2D outline (x, up) into a chunky front-facing slab: front face at y - depth/2."""
    ob = ck.extrude_shape(outline, depth=depth, mat=mat, name=name, bevel=bevel, bevel_segments=segments)
    ob.rotation_euler = (math.radians(90), 0, 0)
    ob.location = (0, y, 0)
    return bake(ob)


def front_streak(points2d, width, front_y, lift=0.025):
    """Gloss streak lying on a front-facing (-Y) flat face at front_y; points are (x, z)."""
    return ck.gloss_streak([(x, front_y - lift, z) for x, z in points2d], width, (0, -1, 0))


def facing(ob, y=None):
    """Turns a lathe/torus built around +Z so it faces the camera (-Y)."""
    ob.rotation_euler = (math.radians(90), 0, 0)
    if y is not None:
        ob.location.y = y
    return ob


def shade(color, toward="Ink", t=0.2):
    return ck.mix(color, toward, t)


def vgrad(name, top, bottom, lo, hi, **kw):
    """Toy plastic ramping from `bottom` (z = lo) to `top` (z = hi), with a lighter lip at the top."""
    return ck.gradient_material(name, [(0.0, bottom), (0.55, ck.mix(bottom, top, 0.7)), (1.0, top)], lo=lo, hi=hi,
                                **kw)


def center_mesh(ob, offset):
    ob.data.transform(Matrix.Translation(Vector(offset)))
    return ob
