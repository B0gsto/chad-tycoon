"""Hero prop: AbsoluteChad, the tier 25 champion statue (about 4.7 studs wide, 6.5 tall, 2.6 deep).

A blocky Roblox-avatar champion in gold and cobalt (the hub GigaStatue's pair) on a deep-navy plinth with a
cobalt foot, a gold tier and a gold medallion with a big red star. Plain R6 / R15 blocks:
- body (warm skin): leg blocks, a plain torso block, a blocky double-biceps flex (horizontal upper arm,
  vertical forearm, plain hand block), a short neck and the classic rounded-cylinder head;
- armour layered on top: a gold cuirass with cobalt hem and neckline, gold pauldrons on cobalt rims,
  gold bracers with cobalt cuffs, a cobalt belt with a gold plate and a red star, gold greaves with cobalt
  rims; cobalt trunks, dark-red boots;
- a dark-red cape with a cobalt lining, curved round the back with deep pleats, a gold hem under a
  cobalt band, gold edges, a tall rolled collar with a gold edge and two gold clasps;
- a printed Roblox face (black shades with white glints, dark brows, a wide toothy grin), a brown swept
  quiff and a chunky five-point gold crown between cobalt rings with a red gem and cobalt side gems.
Front = -Y.

Colour is painted per vertex after finish_for_game (which here only joins and centres) with the
GigaStatue's palette and rule (light / deep pair per part, rim on upward curves, warm recesses); the gold
roles get a toon-metal pass on top (sky reflection, dark amber horizon band, near-white edge highlights).
The renders add the in-game Neon aura disc (AURA_*). Writes the standard props-hero deliverables (see
_hero.py) plus four views for the contact sheet (make_sheet_absolute.py):
  art/out/props/AbsoluteChad_view_{34,front,side,back}.png"""

import json
import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _hero import OUT, WEB, ck, dome, export_glb, place  # noqa: E402

import bmesh  # noqa: E402
import bpy  # noqa: E402
from mathutils import Vector  # noqa: E402
from mathutils.bvhtree import BVHTree  # noqa: E402

KIND = "AbsoluteChad"
TRI_BUDGET = 16000
TRI_CAP = 20000
SCALE = 0.82
# The Neon aura disc under the plinth (added in game by AssetModels.absoluteChad; drawn here for the renders).
AURA_RADIUS, AURA_HEIGHT, AURA_RGB = 2.35, 0.08, (255, 222, 110)

# Colour roles (sRGB 0..255): base (also the unique material colour that finds the role after the
# join), light (top / rim-lit), deep (recesses and undersides). Gold, cobalt, plinth and glint match
# the GigaStatue's roles exactly.
ROLES = {
    "skin": ((246, 190, 146), (255, 222, 188), (206, 128, 96)),
    "gold": ((255, 204, 48), (255, 232, 120), (232, 140, 28)),
    "amber": ((240, 162, 36), (255, 204, 88), (196, 108, 22)),
    "shine": ((255, 252, 226), (255, 255, 246), (255, 232, 150)),
    "cape": ((150, 26, 40), (206, 58, 66), (92, 12, 28)),
    "gem": ((228, 36, 60), (255, 120, 130), (160, 16, 40)),
    "cobalt": ((44, 120, 216), (104, 170, 246), (30, 84, 170)),
    "ink": ((24, 28, 46), (70, 92, 150), (12, 14, 26)),
    "glint": ((255, 255, 254), (255, 255, 255), (222, 238, 255)),
    "teeth": ((250, 246, 236), (255, 255, 252), (214, 206, 196)),
    "mouth": ((110, 30, 36), (140, 44, 48), (80, 20, 26)),
    "hair": ((112, 66, 36), (166, 108, 62), (70, 40, 22)),
    "teal": ((44, 170, 170), (104, 210, 202), (24, 118, 128)),
    "navy": ((30, 44, 104), (66, 96, 176), (16, 22, 60)),
    "cream": ((255, 247, 232), (255, 255, 250), (228, 210, 180)),
    "coral": ((255, 112, 96), (255, 162, 142), (214, 74, 66)),
}
RIM_WEIGHT = {"gold": 0.7, "amber": 0.6, "shine": 0.2, "glint": 0.0, "mouth": 0.0, "teeth": 0.1, "ink": 0.5,
              "cape": 0.45}
DEEP_WEIGHT = {"gold": 0.55, "amber": 0.55, "skin": 0.6, "teeth": 0.3}

def _fill_palette():
    """Adds Theme.World keys whose value is a named constant (`Blue = BLUE,`) to ck.PALETTE in this
    process: chadkit's parser only reads inline rgb() values, and the render rig mixes "Blue"."""
    import re

    with open(ck.THEME_PATH, encoding="utf-8") as fh:
        text = fh.read()
    consts = {m.group(1): tuple(int(m.group(i)) for i in (2, 3, 4))
              for m in re.finditer(r"local (\w+)\s*=\s*rgb\((\d+),\s*(\d+),\s*(\d+)\)", text)}
    world = text[text.find("Theme.World = {"):]
    world = world[:world.find("\n}")]
    for m in re.finditer(r"^\s*(\w+)\s*=\s*([A-Z_]+),", world, re.M):
        if m.group(2) in consts:
            ck.PALETTE.setdefault(m.group(1), consts[m.group(2)])


_fill_palette()
ck.reset_scene()
M = {k: ck.toy_material("Absolute_" + k, v[0]) for k, v in ROLES.items()}
parts = []


def add(ob):
    parts.append(ob)
    return ob


def box(size, loc, mat, r=0.14, seg=2, name="Block", rot=(0, 0, 0), taper=1.0):
    """Rounded box with its base centre at `loc` (studs), rotated about that point (degrees)."""
    return add(place(ck.rounded_box(size, r, seg, M[mat], name, taper=taper), loc, rot))


def limb(a, b, w, d, mat, name, r=0.16, over=0.08):
    """Rounded block from point a to point b (cross-section w x d), overlapping `over` at each end."""
    a, b = Vector(a), Vector(b)
    axis = b - a
    ob = ck.rounded_box((w, d, axis.length + 2 * over), r, 2, M[mat], name)
    ob.rotation_mode = "QUATERNION"
    ob.rotation_quaternion = Vector((0, 0, 1)).rotation_difference(axis)
    ob.location = a - axis.normalized() * over
    return add(ob)


def ball(r, loc, mat, name, scale=(1, 1, 1), seg=12, rings=7):
    return add(place(ck.sphere(r, seg, rings, M[mat], name), loc, (0, 0, 0), scale))


# ---------------------------------------------------------------------------------------------
# Proportions (Blender z up, studs). R6 / R15 blocks scaled up for a muscular champion.
# ---------------------------------------------------------------------------------------------
P = 1.2  # top of the plinth's cream lip, where the boots stand
LEG_X = 0.56
T0 = P + 2.0  # waist (top of the legs)
T1 = T0 + 2.0  # shoulder line (top of the torso)
TORSO = (2.2, 1.04)  # plain R6 torso block, width x depth
HEAD_R, HEAD_H = 0.66, 1.28
H0 = T1 + 0.14  # bottom of the head
H1 = H0 + HEAD_H
ZE = H0 + 0.7  # eye line (shades centre)
MZ = H0 + 0.36  # mouth line
HAIR = H1 - 0.22  # hairline


# ---- Plinth: a deep-navy block on a cobalt foot (high contrast on sand) under a gold tier with a cobalt
# hem and a cream lip, and a gold medallion with a cobalt rim and a big red star on the front.
def open_bottom(ob, cut):
    bm = bmesh.new()
    bm.from_mesh(ob.data)
    bmesh.ops.delete(bm, geom=[f for f in bm.faces if all(v.co.z < cut for v in f.verts)], context="FACES")
    bm.to_mesh(ob.data)
    bm.free()
    return ob


add(open_bottom(ck.rounded_box((4.5, 3.1, 0.24), 0.1, 2, M["cobalt"], "PlinthTrim"), 0.05))
add(open_bottom(ck.rounded_box((4.26, 2.88, 0.62), 0.14, 2, M["navy"], "Plinth", (0, 0, 0.1)), 0.15))
box((4.0, 2.7, 0.1), (0, 0, 0.7), "cobalt", r=0.04, name="TierHem")
box((3.88, 2.6, 0.42), (0, 0, 0.72), "gold", r=0.14, seg=3, name="GoldTier")
box((4.0, 2.72, 0.1), (0, 0, P - 0.1), "cream", r=0.05, name="PlinthLip")
MED = (0, -1.43, 0.48)
medal = ck.lathe(ck.round_profile(0, 0.5, 0, 0.14, 0.06, 2), 24, M["gold"], "Medallion", smooth_angle=50)
add(place(medal, MED, (90, 0, 0)))
ring = ck.lathe(ck.round_profile(0.42, 0.58, 0, 0.1, 0.04, 2), 24, M["cobalt"], "MedallionRim", smooth_angle=50)
add(place(ring, (0, MED[1] - 0.07, MED[2]), (90, 0, 0)))
star = ck.extrude_shape(ck.star_points(5, 0.36, 0.16), depth=0.1, mat=M["gem"], name="PlinthStar", bevel=0.0)
add(place(star, (0, MED[1] - 0.16, MED[2]), (90, 0, 0)))

# ---- Legs: plain R6 leg blocks under cobalt trunks, gold greaves, dark-red boots.
for sx in (1, -1):
    x = sx * LEG_X
    box((1.0, 1.0, 2.0), (x, 0, P), "skin", r=0.1, name="Leg")
    box((1.06, 1.06, 0.84), (x, 0, P + 1.2), "cobalt", r=0.1, name="TrunkLeg")
    box((1.1, 1.1, 0.62), (x, 0, P + 0.36), "gold", r=0.12, seg=3, name="Greave")
    box((1.14, 1.14, 0.1), (x, 0, P + 0.92), "cobalt", r=0.04, name="GreaveRim")
    box((1.12, 1.36, 0.4), (x, -0.14, P), "cape", r=0.12, name="Boot")
box((2.24, 1.08, 0.5), (0, 0, T0 - 0.42), "cobalt", r=0.1, name="TrunkHips")

# ---- Torso: a plain R6 block; gold armour layered on top (belt, cuirass with low pec plates).
box((TORSO[0], TORSO[1], 2.0), (0, 0, T0), "skin", r=0.1, name="Torso")
box((2.3, 1.14, 0.38), (0, 0, T0 - 0.08), "cobalt", r=0.1, seg=3, name="Belt")
box((1.04, 0.14, 0.64), (0, -0.58, T0 - 0.21), "gold", r=0.06, name="BeltPlateRim")
box((0.94, 0.16, 0.56), (0, -0.62, T0 - 0.17), "gold", r=0.1, seg=3, name="BeltPlate")
star = ck.extrude_shape(ck.star_points(5, 0.22, 0.1), depth=0.08, mat=M["gem"], name="BeltStar", bevel=0.0)
add(place(star, (0, -0.71, T0 + 0.11), (90, 0, 0)))
CZ = T0 + 0.9
box((2.4, 1.18, 1.16), (0, 0, CZ), "gold", r=0.14, seg=3, name="Cuirass")
box((2.46, 1.24, 0.12), (0, 0, CZ - 0.04), "cobalt", r=0.05, name="CuirassHem")
box((1.2, 1.22, 0.1), (0, 0, CZ + 1.08), "cobalt", r=0.04, name="CuirassNeck")
box((0.7, 0.6, 0.24), (0, 0, T1 - 0.1), "skin", r=0.08, name="Neck")

# ---- Arms: a blocky double-biceps flex. Each arm is a horizontal upper-arm block out from the shoulder, a
# vertical forearm block up from the elbow with a gold bracer and a cobalt cuff, and a plain hand block on top.
ARM_Z = T1 - 0.46  # centre line of the upper arms
ELBOW_X = 2.3  # centre of the forearm blocks
for sx in (1, -1):
    box((ELBOW_X - 0.9, 0.94, 0.94), (sx * (0.9 + (ELBOW_X - 0.9) / 2), 0, ARM_Z - 0.47), "skin", r=0.1,
        name="UpperArm")
    box((0.94, 0.94, 1.5), (sx * ELBOW_X, 0, ARM_Z - 0.47), "skin", r=0.1, name="Forearm")
    box((1.04, 1.04, 0.6), (sx * ELBOW_X, 0, ARM_Z + 0.22), "gold", r=0.1, seg=3, name="Bracer")
    box((1.08, 1.08, 0.1), (sx * ELBOW_X, 0, ARM_Z + 0.78), "cobalt", r=0.04, name="Cuff")
    box((0.9, 0.9, 0.56), (sx * ELBOW_X, 0, ARM_Z + 1.02), "skin", r=0.12, name="Hand")

# ---- Pauldrons: a modest gold dome over a cobalt rim plate on each shoulder.
for sx in (1, -1):
    tilt = (0, sx * 20, 0)
    add(place(dome(0.66, 0.2, M["cobalt"], "PauldronRim", segments=18, steps=2), (sx * 1.3, 0, T1 - 0.34), tilt,
              (1, 0.86, 1)))
    add(place(dome(0.58, 0.42, M["gold"], "Pauldron", segments=18, steps=4), (sx * 1.28, 0, T1 - 0.26), tilt,
              (1, 0.86, 1)))

# ---- Cape: dark red, curved round the back with deep pleats, edged with a bright gold trim, hanging
# from a tall rolled collar with a gold edge and two gold clasps.
NR, NC = 12, 20
ZTOP, ZBOT = T1 - 0.02, P + 0.14


def cape_pt(t, s):
    x = s * (1.08 + 0.62 * t)
    fold = 0.15 * t ** 0.7 * math.cos(s * math.pi * 3.0)
    y = 0.6 + 0.55 * t ** 1.3 + 0.26 * (1 - s * s) * (0.35 + 0.65 * t) + fold
    z = ZTOP - t * (ZTOP - ZBOT) + 0.06 * t * s * s
    return Vector((x, y, z))


bm = bmesh.new()
grid = [[bm.verts.new(cape_pt(i / NR, j / NC * 2 - 1)) for j in range(NC + 1)] for i in range(NR + 1)]
for i in range(NR):
    for j in range(NC):
        bm.faces.new((grid[i][j], grid[i][j + 1], grid[i + 1][j + 1], grid[i + 1][j]))
cape = add(ck.mesh_object("Cape", bm, M["cape"]))
sol = cape.modifiers.new("Thick", "SOLIDIFY")
sol.thickness = 0.05
sol.offset = 0.0
ck.shade_smooth(cape, 60)
# Cobalt lining: the same sheet just inside the red one (toward the body).
bm = bmesh.new()
grid = [[bm.verts.new(cape_pt(i / NR, (j / NC * 2 - 1) * 0.985) - Vector((0, 0.06, 0))) for j in range(NC + 1)]
        for i in range(NR + 1)]
for i in range(NR):
    for j in range(NC):
        bm.faces.new((grid[i][j], grid[i][j + 1], grid[i + 1][j + 1], grid[i + 1][j]))
lining = add(ck.mesh_object("CapeLining", bm, M["cobalt"]))
sol = lining.modifiers.new("Thick", "SOLIDIFY")
sol.thickness = 0.03
sol.offset = 0.0
ck.shade_smooth(lining, 60)
band = [cape_pt(0.93, -1 + 2 * j / (NC * 2)) + Vector((0, 0.03, 0)) for j in range(NC * 2 + 1)]
add(ck.sweep(band, [0.06] * len(band), 6, M["cobalt"], "CapeBand", flatten=0.6, smooth_angle=70))
hem = [cape_pt(1.0, -1 + 2 * j / (NC * 2)) for j in range(NC * 2 + 1)]
add(ck.sweep(hem, [0.075] * len(hem), 6, M["gold"], "CapeHem", smooth_angle=70))
for sx in (1, -1):
    side = [cape_pt(i / 16, sx) for i in range(17)]
    add(ck.sweep(side, [0.065] * len(side), 6, M["gold"], "CapeEdge", smooth_angle=70))
collar = [(-0.82, -0.54, T1 - 0.02), (-0.98, 0.0, T1 + 0.08), (-0.78, 0.5, T1 + 0.16), (0.0, 0.74, T1 + 0.22),
          (0.78, 0.5, T1 + 0.16), (0.98, 0.0, T1 + 0.08), (0.82, -0.54, T1 - 0.02)]
add(ck.sweep(collar, [0.18] * len(collar), 10, M["cape"], "Collar", flatten=1.4, up=(0, 0, 1), smooth_angle=70))
add(ck.sweep([Vector(p) + Vector((0, 0, 0.24)) for p in collar], [0.06] * len(collar), 6, M["gold"], "CollarEdge",
             smooth_angle=70))
for sx in (1, -1):
    clasp = ck.lathe(ck.round_profile(0, 0.24, 0, 0.12, 0.05, 2), 18, M["gold"], "Clasp")
    add(place(clasp, (sx * 0.8, -0.58, T1 - 0.08), (90, 0, 0)))
    ball(0.11, (sx * 0.8, -0.72, T1 - 0.08), "gem", "ClaspGem", scale=(1, 0.6, 1))

# ---- Head: the classic rounded cylinder, a brown swept quiff and a bold four-point crown.
add(ck.lathe(ck.round_profile(0, HEAD_R, H0, H1, 0.24, 4), 28, M["skin"], "Head", smooth_angle=70))
hair = [(0.0, HAIR), (HEAD_R + 0.05, HAIR), (HEAD_R + 0.05, HAIR + 0.1)]
hair += [(0.45 + (HEAD_R + 0.05 - 0.45) * math.cos(math.radians(a)), HAIR + 0.1 + 0.22 * math.sin(math.radians(a)))
         for a in (22.5, 45, 67.5, 90)]
add(ck.lathe(hair + [(0.0, HAIR + 0.32)], 28, M["hair"], "Hair", smooth_angle=70))
add(place(ck.rounded_box((1.0, 0.44, 0.3), 0.13, 2, M["hair"], "Quiff"), (0.04, -0.46, H1 - 0.16), (-24, 0, -4)))

# A chunky five-point crown: a tall gold band between two cobalt rings, five fat points with round tips,
# a big red gem at the front and cobalt gems on the sides.
CROWN_R = 0.66
crown = [ck.lathe(ck.round_profile(CROWN_R - 0.12, CROWN_R, 0, 0.46, 0.07, 2), 30, M["gold"], "CrownBand",
                  smooth_angle=50)]
for z0 in (0.0, 0.36):
    crown.append(ck.lathe(ck.round_profile(CROWN_R - 0.04, CROWN_R + 0.05, z0, z0 + 0.1, 0.03, 1), 30, M["cobalt"],
                          "CrownRing", smooth_angle=50))
for k in range(5):
    a = math.radians(72 * k)
    p = ((CROWN_R - 0.2) * math.sin(a), -(CROWN_R - 0.2) * math.cos(a), 0.4)
    crown.append(place(ck.lathe([(0.26, 0.0), (0.24, 0.22), (0.13, 0.56), (0.0, 0.8)], 12, M["gold"], "CrownPoint",
                                smooth_angle=50), p))
    crown.append(place(ck.sphere(0.13, 12, 7, M["gold"], "CrownTip"), (p[0], p[1], 1.2)))
    if k:
        g = place(ck.sphere(0.1, 10, 6, M["cobalt"], "CrownSideGem"), (0, 0, 0))
        a2 = a + math.radians(36)
        crown.append(place(g, ((CROWN_R + 0.03) * math.sin(a2), -(CROWN_R + 0.03) * math.cos(a2), 0.23)))
crown.append(place(ck.sphere(0.2, 14, 8, M["gem"], "CrownGem"), (0, -CROWN_R - 0.04, 0.23), (0, 0, 0),
                   (1, 0.55, 1.05)))
for ob in crown:
    add(ob)
ck.group(crown, "Crown", location=(0.0, 0.04, H1), rotation=(-4, 0, 0))


# ---- Printed face: flat high-contrast shapes laid on the front of the head and bent round its cylinder.
def wrap(ob, radius, step=0.04):
    """Bends a flat object built against the plane y = -radius round the head's axis (Z through 0, 0)."""
    bpy.context.view_layer.update()  # matrix_world must include the placement before it is baked
    ck.apply_transforms([ob])
    bm = bmesh.new()
    bm.from_mesh(ob.data)
    xs = [v.co.x for v in bm.verts]
    lo, hi = min(xs), max(xs)
    cuts = max(2, int((hi - lo) / step))
    for i in range(1, cuts):
        geom = bm.verts[:] + bm.edges[:] + bm.faces[:]
        bmesh.ops.bisect_plane(bm, geom=geom, plane_co=(lo + (hi - lo) * i / cuts, 0, 0), plane_no=(1, 0, 0))
    bm.to_mesh(ob.data)
    bm.free()
    for v in ob.data.vertices:
        x, y, z = v.co
        d = -y
        t = x / radius
        v.co = Vector((d * math.sin(t), -d * math.cos(t), z))
    ob.data.update()
    return ob


def decal(points, z, lift, depth, mat, name):
    """A printed shape (points in face x / height-offset studs, counter-clockwise) at height z, its front
    standing `lift` + depth / 2 off the head surface."""
    ob = ck.extrude_shape(points, depth=depth, mat=M[mat], name=name, bevel=0.0)
    place(ob, (0, -(HEAD_R + lift), z), (90, 0, 0))
    ob = add(wrap(ob, HEAD_R))
    ys = [v.co.y for v in ob.data.vertices]
    zs = [v.co.z for v in ob.data.vertices]
    print("DECAL %s front y %.3f z %.2f..%.2f" % (name, min(ys), min(zs), max(zs)))
    return ob


def superellipse(cx, a, b, n=24, power=4.0, narrow=0.0):
    pts = []
    for k in range(n):
        t = 2 * math.pi * k / n
        c, s = math.cos(t), math.sin(t)
        y = b * math.copysign(abs(s) ** (2 / power), s)
        w = 1 - narrow * max(0.0, -y / b)
        pts.append((cx + a * w * math.copysign(abs(c) ** (2 / power), c), y))
    return pts


for sx in (1, -1):
    decal(superellipse(sx * 0.27, 0.25, 0.17, narrow=0.2), ZE, 0.012, 0.07, "ink", "Lens")
    g = [(-0.13, 0.02), (-0.02, 0.12), (0.05, 0.12), (-0.06, 0.02)]
    decal([(sx * 0.27 - 0.06 + x, y) for x, y in g], ZE, 0.035, 0.05, "glint", "Glint")
    decal([(sx * 0.27 + 0.07 + x * 0.5, y - 0.08) for x, y in g], ZE, 0.035, 0.05, "glint", "Glint")
decal([(-0.98, -0.035), (0.98, -0.035), (0.98, 0.045), (-0.98, 0.045)], ZE + 0.09, 0.006, 0.05, "ink", "Frame")


def bar(cx, cz, w, h, deg):
    a = math.radians(deg)
    out = []
    for x, y in ((-w / 2, -h / 2), (w / 2, -h / 2), (w / 2, h / 2), (-w / 2, h / 2)):
        out.append((cx + x * math.cos(a) - y * math.sin(a), cz + x * math.sin(a) + y * math.cos(a)))
    return out


decal(bar(-0.27, 0.0, 0.32, 0.08, 6), ZE + 0.25, 0.01, 0.05, "ink", "Brow")
decal(bar(0.27, 0.04, 0.32, 0.08, 14), ZE + 0.25, 0.01, 0.05, "ink", "Brow")


def mouth_top(u):
    return 0.03 + 0.05 * u + 0.04 * u * u


W = 0.38
US = [-1 + 2 * k / 16 for k in range(17)]
mouth = [(u * W, mouth_top(u) - 0.24 * (1 - u * u) ** 0.75 - 0.014) for u in US]
mouth += [(u * W, mouth_top(u) + 0.014) for u in reversed(US)]
decal(mouth, MZ, 0.006, 0.05, "mouth", "Mouth")
UT = [u * 0.86 for u in US]
teeth = [(u * W, mouth_top(u) - 0.1 * (1 - (u / 0.9) ** 2) ** 0.5 - 0.02) for u in UT]
teeth += [(u * W, mouth_top(u) - 0.008) for u in reversed(UT)]
decal(teeth, MZ, 0.022, 0.04, "teeth", "Teeth")


# ---------------------------------------------------------------------------------------------
# Finish: join + centre (no baked colour), then paint the toy colours per vertex (GigaStatue rule).
# ---------------------------------------------------------------------------------------------
def smoothstep(a, b, x):
    t = min(1.0, max(0.0, (x - a) / (b - a)))
    return t * t * (3 - 2 * t)


SHINE = ck.lin(ROLES["shine"][1])


def metal(base, light, deep, n, convex, ao):
    """Toon metal for the gold roles: a sky reflection on up-facing curves (light), a dark amber horizon
    band just under the side faces, a warm ground bounce underneath (deep), near-white highlights on
    every convex edge and bevel, and deep amber in the recesses."""
    nz = n.z
    t = smoothstep(-0.25, 0.6, nz)
    rgb = [deep[i] + (base[i] - deep[i]) * smoothstep(-0.6, -0.1, nz) for i in range(3)]
    rgb = [x + (light[i] - x) * t for i, x in enumerate(rgb)]
    band = math.exp(-((nz + 0.12) / 0.16) ** 2)
    rgb = [x + (deep[i] * 0.72 - x) * 0.6 * band for i, x in enumerate(rgb)]
    edge = smoothstep(0.08, 0.32, convex) * (0.55 + 0.45 * smoothstep(-0.2, 0.5, nz))
    rgb = [x + (SHINE[i] - x) * 0.85 * edge for i, x in enumerate(rgb)]
    k_deep = min(0.8, ao * 1.4)
    return [x + (deep[i] * 0.6 - x) * k_deep for i, x in enumerate(rgb)]


def paint(obj):
    me = obj.data
    col = me.color_attributes.get("Col")
    vals = [0.0] * (len(me.loops) * 4)
    col.data.foreach_get("color", vals)
    roles = {k: tuple(ck.lin(c) for c in v) for k, v in ROLES.items()}

    def role_of(c):
        return min(roles, key=lambda k: sum((a - b) ** 2 for a, b in zip(roles[k][0], c)))

    verts = [v.co.copy() for v in me.vertices]
    bvh = BVHTree.FromPolygons(verts, [tuple(p.vertices) for p in me.polygons], all_triangles=True)
    height = max(v.z for v in verts)
    maxd = height * 0.07
    dirs = ck._hemisphere(40)
    ao = []
    for v in me.vertices:
        n = v.normal.normalized()
        t = n.orthogonal().normalized()
        b = n.cross(t)
        o = v.co + n * 0.01
        occ = 0.0
        for d in dirs:
            w = t * d.x + b * d.y + n * d.z
            hit = bvh.ray_cast(o, w, maxd)
            dist = hit[3] if hit[0] is not None else None
            if w.z < -1e-4:
                gd = -o.z / w.z
                if 0 <= gd < maxd and (dist is None or gd < dist):
                    dist = gd
            if dist is not None:
                occ += 1.0 - (dist / maxd) ** 0.5 * 0.6
        ao.append(min(1.0, occ / len(dirs) * 1.7))
    # Convexity per vertex (rounded edges and bevels > 0): how far the neighbours fall behind the normal.
    nbrs = [[] for _ in me.vertices]
    for e in me.edges:
        i, j = e.vertices
        nbrs[i].append(j)
        nbrs[j].append(i)
    convex = []
    for v in me.vertices:
        ns = nbrs[v.index]
        if not ns:
            convex.append(0.0)
            continue
        avg = sum((verts[j] - verts[v.index] for j in ns), Vector()) / len(ns)
        span = sum((verts[j] - verts[v.index]).length for j in ns) / len(ns)
        convex.append(-avg.dot(v.normal.normalized()) / max(span, 1e-6))
    key = Vector((-0.35, -0.45, 0.82)).normalized()
    rim = Vector((-0.25, -0.2, 1.0)).normalized()
    lens_lo = ZE - 0.16 - obj["chad_z0"]
    cache = {}
    per_role = {}
    for p in me.polygons:
        c0 = tuple(vals[p.loop_indices[0] * 4: p.loop_indices[0] * 4 + 3])
        r0 = cache.get(c0) or cache.setdefault(c0, role_of(c0))
        per_role[r0] = per_role.get(r0, 0) + 1
        for li in p.loop_indices:
            c = tuple(vals[li * 4: li * 4 + 3])
            r = cache.get(c) or cache.setdefault(c, role_of(c))
            base, light, deep = roles[r]
            vi = me.loops[li].vertex_index
            n = me.vertices[vi].normal
            z = verts[vi].z
            h = z / height
            if r == "ink":
                # Shades: a top-to-bottom gloss gradient, deep navy at the bottom to a blue sheen on top.
                k = smoothstep(0.0, 1.0, (z - lens_lo) / 0.32)
                rgb = [base[i] + (light[i] - base[i]) * k ** 1.6 for i in range(3)]
            elif r in ("glint", "teeth", "mouth"):
                rgb = list(base)
            elif r in ("gold", "amber"):
                rgb = metal(base, light, deep, n, convex[vi], ao[vi])
            else:
                up = max(0.0, n.dot(key))
                k_light = 0.18 * h + 0.3 * up ** 1.5 + RIM_WEIGHT.get(r, 0.35) * smoothstep(0.6, 0.85, n.dot(rim))
                k_light = min(0.92, k_light)
                k_deep = min(DEEP_WEIGHT.get(r, 0.85), ao[vi] * 1.1 + 0.3 * max(0.0, -n.z) * (1 - 0.5 * h))
                rgb = []
                for i in range(3):
                    x = base[i] + (light[i] - base[i]) * k_light
                    rgb.append(x + (deep[i] - x) * k_deep)
            vals[li * 4: li * 4 + 3] = rgb
            vals[li * 4 + 3] = 1.0
    col.data.foreach_set("color", vals)
    me.update()
    print("ROLE_TRIS", json.dumps(per_role, sort_keys=True))


def beauty_material():
    """Same vertex colours as the game mesh under a glossier vinyl clear coat (beauty shots only)."""
    mat = ck.vcol_material("AbsoluteBeauty")
    p = next(nd for nd in mat.node_tree.nodes if nd.type == "BSDF_PRINCIPLED")
    p.inputs["Roughness"].default_value = 0.22
    p.inputs["Coat Weight"].default_value = 1.0
    p.inputs["Coat Roughness"].default_value = 0.03
    p.inputs["Specular IOR Level"].default_value = 0.6
    return mat


# Built at R6-like proportions (8 studs), shipped scaled to SCALE (about 6 studs with the plinth).
root = ck._link(bpy.data.objects.new("Root", None))
root.scale = (SCALE, SCALE, SCALE)
for ob in list(bpy.data.objects):
    if ob.parent is None and ob is not root:
        ob.parent = root
bpy.context.view_layer.update()
raw = sum(ck.triangle_count(o) for o in parts)
z0 = min((o.matrix_world @ Vector(c)).z for o in parts for c in o.bound_box)
corners = [o.matrix_world @ Vector(c) for o in parts for c in o.bound_box]
# Plinth centre relative to the mesh's bounding-box centre (where Roblox puts the MeshPart's origin).
plinth = [-(min(c[i] for c in corners) + max(c[i] for c in corners)) / 2 for i in (0, 1)]
obj, tris = ck.finish_for_game(parts, KIND, tri_budget=TRI_BUDGET, tri_cap=TRI_CAP, ao_strength=0.0, ao_samples=1,
                               gradient=(1.0, 1.0))
obj["chad_z0"] = z0
paint(obj)
ck.export_fbx(obj, os.path.join(OUT, KIND + ".fbx"))
export_glb(obj, os.path.join(WEB, "props__%s.glb" % KIND))
sx_, sy_, sz_ = (round(v, 2) for v in obj["chad_size"])
stats = {"kind": KIND, "tris": tris, "size": [sx_, sz_, sy_], "axes": "roblox x, y (height), z (depth)",
         "plinth_offset": [round(plinth[0], 3), round(plinth[1], 3)]}
with open(os.path.join(OUT, KIND + ".json"), "w") as f:
    json.dump(stats, f, indent=1)
print("CHADKIT_STATS", json.dumps(stats), "source tris", raw)


def aura_ring():
    """Render stand-in for the Neon aura disc AssetModels.absoluteChad adds under the plinth in game
    (AURA_RADIUS studs, AURA_HEIGHT thick, pale gold): emissive in the beauty shots, and a bright
    vertex colour for the game shot (whose material swap uses the Col attribute)."""
    ob = ck.lathe(ck.round_profile(0, AURA_RADIUS, 0, AURA_HEIGHT, 0.02, 1), 48, None, "AuraRing")
    ob.location = (plinth[0], plinth[1], 0.0)
    me = ob.data
    col = me.color_attributes.new("Col", "FLOAT_COLOR", "CORNER")
    glow = tuple(ck.lin(AURA_RGB))
    col.data.foreach_set("color", [c for _ in me.loops for c in (glow[0], glow[1], glow[2], 1.0)])
    mat = bpy.data.materials.new("AuraGlow")
    mat.use_nodes = True
    p = next(nd for nd in mat.node_tree.nodes if nd.type == "BSDF_PRINCIPLED")
    p.inputs["Base Color"].default_value = glow + (1.0,)
    p.inputs["Emission Color"].default_value = glow + (1.0,)
    p.inputs["Emission Strength"].default_value = 2.5
    me.materials.append(mat)
    return ob


if not os.environ.get("HERO_NORENDER"):
    ring = aura_ring()
    ck.render_prop([obj, ring], os.path.join(OUT, KIND + "_game.png"), size=360, samples=32, game=True,
                   azimuth=24.0, elevation=10.0)
    obj.data.materials.clear()
    obj.data.materials.append(beauty_material())
    ck.render_prop([obj, ring], os.path.join(OUT, KIND + ".png"), size=640, azimuth=28.0, elevation=6.0, lens=40.0)
    for view, az, el in (("34", 28.0, 6.0), ("front", 0.0, 6.0), ("side", 90.0, 6.0), ("back", 180.0, 8.0)):
        ck.render_prop([obj, ring], os.path.join(OUT, "%s_view_%s.png" % (KIND, view)), size=480, samples=48,
                       azimuth=az, elevation=el)
