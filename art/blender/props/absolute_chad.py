"""Hero prop: AbsoluteChad, the tier 25 champion statue (about 4.7 studs wide, 6 tall, 2.4 deep).

A blocky Roblox-avatar champion on a mini plinth styled like the hub's GigaStatue plinth (cobalt trim,
teal body, cream lip, coral star). R15-style blocks with rounded edges:
- body (warm skin): two leg blocks, a torso block flaring from the waist to broad shoulders, upper
  arm / forearm / fist blocks, a short neck and the classic rounded-cylinder head;
- gold armour plates: a cuirass with two pec plates and a red sternum gem, layered shoulder
  pauldrons, forearm bracers, a champion belt with a big plate and a red star, greaves with knee
  guards; cobalt trunks, dark-red boots;
- a dark-red cape hanging from a rolled collar with two gold clasps, flaring back with soft folds;
- a printed Roblox face: black shades with white glints, one raised brow, a wide toothy grin with one
  corner lifted; a brown swept quiff and a small tilted gold crown with red gems.
Pose: right fist flexed up beside the head, left fist on the hip. Front = -Y.

Colour is painted per vertex after finish_for_game (which here only joins and centres) with the
GigaStatue's rule: each part's light / deep pair, a crisp rim on upward curves, warm shade only in the
recesses. Writes the standard props-hero deliverables (see _hero.py) plus four views for the
contact sheet (make_sheet_absolute.py):
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
TRI_BUDGET = 12000
TRI_CAP = 20000
SCALE = 0.88

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
P = 0.66  # plinth top, where the boots stand
LEG_X = 0.56
T0 = P + 2.0  # waist (top of the legs)
T1 = T0 + 2.0  # shoulder line (top of the torso)
TAPER = 1.17  # torso flare from the waist to the shoulders
HEAD_R, HEAD_H = 0.66, 1.28
H0 = T1 + 0.14  # bottom of the head
H1 = H0 + HEAD_H
ZE = H0 + 0.68  # eye line (shades centre)
MZ = H0 + 0.38  # mouth line
HAIR = H1 - 0.24  # hairline


def torso_half_depth(z):
    return 0.5 * (1 + (TAPER - 1) * (z - T0) / (T1 - T0))


# ---- Mini plinth: the GigaStatue's stepped plinth in small.
def open_bottom(ob, cut):
    bm = bmesh.new()
    bm.from_mesh(ob.data)
    bmesh.ops.delete(bm, geom=[f for f in bm.faces if all(v.co.z < cut for v in f.verts)], context="FACES")
    bm.to_mesh(ob.data)
    bm.free()
    return ob


add(open_bottom(ck.rounded_box((3.9, 2.7, 0.22), 0.1, 2, M["cobalt"], "PlinthTrim"), 0.05))
add(open_bottom(ck.rounded_box((3.66, 2.48, 0.42), 0.14, 2, M["teal"], "Plinth", (0, 0, 0.1)), 0.15))
add(ck.rounded_box((3.82, 2.62, 0.16), 0.07, 2, M["cream"], "PlinthLip", (0, 0, P - 0.16)))
star = ck.extrude_shape(ck.star_points(5, 0.14, 0.065), depth=0.1, mat=M["coral"], name="PlinthStar", bevel=0.0)
add(place(star, (0, -1.25, 0.32), (90, 0, 0)))

# ---- Legs: skin blocks under cobalt trunks, gold greaves with knee guards, dark-red boots.
for sx in (1, -1):
    x = sx * LEG_X
    box((1.0, 1.0, 2.0), (x, 0, P), "skin", r=0.12, name="Leg")
    box((1.08, 1.08, 0.86), (x, 0, P + 1.2), "cobalt", r=0.14, name="TrunkLeg")
    box((1.1, 1.12, 0.62), (x, 0, P + 0.34), "gold", r=0.16, name="Greave")
    box((0.6, 0.24, 0.4), (x, -0.56, P + 0.78), "gold", r=0.1, name="KneeGuard", rot=(-8, 0, 0))
    box((0.98, 0.16, 0.08), (x, -0.07, P + 0.9), "amber", r=0.03, name="GreaveRim")
    box((1.12, 1.4, 0.4), (x, -0.16, P), "cape", r=0.15, name="Boot")
box((2.2, 1.1, 0.5), (0, 0, T0 - 0.42), "cobalt", r=0.14, name="TrunkHips")

# ---- Torso: skin block flaring to the shoulders, abs at the waist, the champion belt.
box((2.1, 1.0, 2.0), (0, 0, T0), "skin", r=0.18, name="Torso", taper=TAPER)
for row, z in enumerate((T0 + 0.42, T0 + 0.72)):
    for sx in (1, -1):
        hd = torso_half_depth(z + 0.12)
        box((0.48, 0.12, 0.24), (sx * 0.27, -hd - 0.02, z), "skin", r=0.06, name="Ab")
box((2.22, 1.12, 0.38), (0, 0, T0 - 0.08), "gold", r=0.12, name="Belt")
box((1.0, 0.16, 0.62), (0, -0.6, T0 - 0.2), "gold", r=0.1, name="BeltPlate")
box((1.08, 0.12, 0.7), (0, -0.55, T0 - 0.24), "amber", r=0.08, name="BeltPlateRim")
star = ck.extrude_shape(ck.star_points(5, 0.24, 0.11), depth=0.08, mat=M["gem"], name="BeltStar", bevel=0.0)
add(place(star, (0, -0.7, T0 + 0.1), (90, 0, 0)))

# ---- Cuirass: gold plate over the chest with pec plates, an amber hem and a red sternum gem.
CZ = T0 + 0.97
box((2.42, 1.2, 1.08), (0, 0, CZ), "gold", r=0.2, name="Cuirass", taper=1.06)
box((2.5, 1.26, 0.14), (0, 0, CZ - 0.04), "amber", r=0.06, name="CuirassHem")
for sx in (1, -1):
    box((0.98, 0.3, 0.6), (sx * 0.53, -0.62, CZ + 0.3), "gold", r=0.15, name="Pec", rot=(0, 0, sx * -6))
box((0.7, 0.62, 0.24), (0, 0, T1 - 0.1), "skin", r=0.1, name="Neck")

# ---- Arms. Right (statue's right = -X): flexed, the fist up beside the head. Left: fist on the hip.
SR, SL = Vector((-1.32, 0, T1 - 0.5)), Vector((1.32, 0, T1 - 0.5))
ER, WR = Vector((-2.38, -0.05, T1 - 0.4)), Vector((-2.4, -0.12, T1 + 0.48))
EL, WL = Vector((1.98, 0.22, T0 + 0.98)), Vector((1.3, 0.04, T0 + 0.42))
limb(SR, ER, 0.96, 0.96, "skin", "UpperArmR")
box((0.78, 0.8, 0.46), (-2.0, -0.02, T1 - 0.2), "skin", r=0.22, name="BicepR")
box((0.98, 0.98, 0.98), (ER.x, ER.y, ER.z - 0.49), "skin", r=0.3, name="ElbowR")
limb(ER, WR, 0.9, 0.9, "skin", "ForearmR")
limb(ER.lerp(WR, 0.45), WR, 1.0, 1.0, "gold", "BracerR", r=0.14, over=0.0)
box((0.82, 0.82, 0.72), (WR.x, WR.y - 0.02, WR.z - 0.04), "skin", r=0.24, name="FistR")
limb(SL, EL, 0.96, 0.96, "skin", "UpperArmL")
box((0.96, 0.96, 0.96), (EL.x, EL.y, EL.z - 0.48), "skin", r=0.3, name="ElbowL")
limb(EL, WL, 0.9, 0.9, "skin", "ForearmL")
limb(EL.lerp(WL, 0.3), EL.lerp(WL, 0.8), 1.0, 1.0, "gold", "BracerL", r=0.14, over=0.0)
fist = ck.rounded_box((0.8, 0.8, 0.74), 0.24, 2, M["skin"], "FistL")
add(place(fist, (WL.x + 0.06, WL.y, WL.z - 0.37), (0, 30, 0)))

# ---- Pauldrons: a big gold dome over an amber flare plate, tilted out, with a shine streak.
for sx in (1, -1):
    tilt = (0, sx * 24, 0)
    add(place(dome(0.84, 0.36, M["amber"], "PauldronFlare", segments=18, steps=3), (sx * 1.36, 0, T1 - 0.46), tilt,
              (1, 0.88, 1)))
    add(place(dome(0.72, 0.6, M["gold"], "Pauldron", segments=18, steps=4), (sx * 1.33, 0, T1 - 0.32), tilt,
              (1, 0.88, 1)))
    a = math.radians(sx * 24)
    tip = Vector((sx * 1.33 + 0.6 * math.sin(a), 0, T1 - 0.32 + 0.6 * math.cos(a)))
    pts = [tip + Vector((sx * 0.08 * k - sx * 0.3, -0.32 + 0.12 * k, -0.08 - 0.03 * abs(k - 1.5)))
           for k in range(4)]
    add(ck.gloss_streak(pts, 0.1, Vector((sx * 0.3, -0.5, 0.8)).normalized(), mat=M["shine"], name="PauldronShine",
                        flatten=0.25, sides=4))

# ---- Cape: dark red, from a rolled collar behind the neck, flaring back with soft folds.
NR, NC = 12, 16
ZTOP, ZBOT = T1 - 0.02, P + 0.16
bm = bmesh.new()
grid = []
for i in range(NR + 1):
    t = i / NR
    row = []
    for j in range(NC + 1):
        s = j / NC * 2 - 1
        x = s * (1.16 + 0.62 * t)
        fold = 0.11 * t ** 0.8 * math.cos(s * math.pi * 2.5)
        y = 0.64 + 0.62 * t ** 1.4 + fold + 0.1 * (1 - t) * s * s
        z = ZTOP - t * (ZTOP - ZBOT) + 0.08 * t * abs(s) ** 2
        row.append(bm.verts.new((x, y, z)))
    grid.append(row)
for i in range(NR):
    for j in range(NC):
        bm.faces.new((grid[i][j], grid[i][j + 1], grid[i + 1][j + 1], grid[i + 1][j]))
cape = add(ck.mesh_object("Cape", bm, M["cape"]))
sol = cape.modifiers.new("Thick", "SOLIDIFY")
sol.thickness = 0.08
sol.offset = 0.0
ck.shade_smooth(cape, 60)
collar = [(-0.8, -0.56, T1 - 0.04), (-0.95, 0.0, T1 + 0.04), (-0.75, 0.5, T1 + 0.1), (0.0, 0.72, T1 + 0.14),
          (0.75, 0.5, T1 + 0.1), (0.95, 0.0, T1 + 0.04), (0.8, -0.56, T1 - 0.04)]
add(ck.sweep(collar, [0.13] * len(collar), 8, M["cape"], "Collar", flatten=0.8, smooth_angle=70))
for sx in (1, -1):
    clasp = ck.lathe(ck.round_profile(0, 0.22, 0, 0.12, 0.05, 2), 16, M["gold"], "Clasp")
    add(place(clasp, (sx * 0.78, -0.6, T1 - 0.1), (90, 0, 0)))
    ball(0.1, (sx * 0.78, -0.73, T1 - 0.1), "gem", "ClaspGem", scale=(1, 0.6, 1))


# ---- Head: the classic rounded cylinder, a brown swept quiff, a small tilted crown.
head = ck.lathe(ck.round_profile(0, HEAD_R, H0, H1, 0.26, 4), 28, M["skin"], "Head", smooth_angle=70)
add(head)
hair = [(0.0, HAIR), (HEAD_R + 0.05, HAIR), (HEAD_R + 0.05, HAIR + 0.1)]
hair += [(0.45 + (HEAD_R + 0.05 - 0.45) * math.cos(math.radians(a)), HAIR + 0.1 + 0.24 * math.sin(math.radians(a)))
         for a in (22.5, 45, 67.5, 90)]
add(ck.lathe(hair + [(0.0, HAIR + 0.34)], 28, M["hair"], "Hair", smooth_angle=70))
add(place(ck.rounded_box((1.06, 0.5, 0.34), 0.15, 2, M["hair"], "Quiff"), (0.06, -0.44, H1 - 0.18), (-24, 0, -4)))

crown = []
ring = ck.lathe(ck.round_profile(0.34, 0.44, 0, 0.24, 0.05, 2), 20, M["gold"], "CrownBand", smooth_angle=60)
crown.append(ring)
for k in range(5):
    a = math.radians(90 + 72 * k)
    p = (0.4 * math.cos(a), -0.4 * math.sin(a), 0.2)
    spike = ck.lathe([(0.13, 0.0), (0.1, 0.12), (0.0, 0.32)], 8, M["gold"], "CrownPoint", smooth_angle=50)
    crown.append(place(spike, p))
    crown.append(place(ck.sphere(0.065, 8, 5, M["gold"], "CrownTip"), (p[0], p[1], 0.53)))
    gem = ck.sphere(0.07, 8, 5, M["gem"], "CrownGem")
    crown.append(place(gem, (0.44 * math.cos(a + math.radians(36)), -0.44 * math.sin(a + math.radians(36)), 0.12),
                       (0, 0, 0), (1, 1, 1)))
for ob in crown:
    add(ob)
ck.group(crown, "Crown", location=(0.12, 0.08, H1 + 0.04), rotation=(-6, 12, 0))


# ---- Printed face: flat shapes laid on the front of the head and bent round its cylinder.
def wrap(ob, radius, step=0.05):
    """Bends a flat object built against the plane y = -radius round the head's axis (Z through 0, 0)."""
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
    """A printed shape (points in face x / height-offset studs, counter-clockwise) at height z, standing
    `lift` off the head surface."""
    ob = ck.extrude_shape(points, depth=depth, mat=M[mat], name=name, bevel=0.0)
    place(ob, (0, -(HEAD_R + lift), z), (90, 0, 0))
    return add(wrap(ob, HEAD_R))


def superellipse(cx, a, b, n=20, power=4.0, narrow=0.0):
    pts = []
    for k in range(n):
        t = 2 * math.pi * k / n
        c, s = math.cos(t), math.sin(t)
        y = b * math.copysign(abs(s) ** (2 / power), s)
        w = 1 - narrow * max(0.0, -y / b)
        pts.append((cx + a * w * math.copysign(abs(c) ** (2 / power), c), y))
    return pts


for sx in (1, -1):
    decal(superellipse(sx * 0.27, 0.24, 0.16, narrow=0.18), ZE, 0.012, 0.07, "ink", "Lens")
    g = [(-0.12, 0.02), (-0.02, 0.1), (0.04, 0.1), (-0.06, 0.02)]
    decal([(sx * 0.27 - 0.05 + x, y) for x, y in g], ZE, 0.03, 0.05, "glint", "Glint")
    decal([(sx * 0.27 + 0.06 + x * 0.5, y - 0.07) for x, y in g], ZE, 0.03, 0.05, "glint", "Glint")
decal([(-0.98, -0.03), (0.98, -0.03), (0.98, 0.04), (-0.98, 0.04)], ZE + 0.08, 0.004, 0.05, "ink", "Frame")


def bar(cx, cz, w, h, deg):
    a = math.radians(deg)
    out = []
    for x, y in ((-w / 2, -h / 2), (w / 2, -h / 2), (w / 2, h / 2), (-w / 2, h / 2)):
        out.append((cx + x * math.cos(a) - y * math.sin(a), cz + x * math.sin(a) + y * math.cos(a)))
    return out


decal(bar(-0.28, 0.0, 0.32, 0.075, 6), ZE + 0.24, 0.01, 0.05, "hair", "Brow")
decal(bar(0.28, 0.05, 0.32, 0.075, 12), ZE + 0.24, 0.01, 0.05, "hair", "Brow")


def mouth_top(u):
    return 0.02 + 0.06 * u + 0.035 * u * u


W = 0.33
US = [-1 + 2 * k / 14 for k in range(15)]
mouth = [(u * W, mouth_top(u) - 0.21 * (1 - u * u) ** 0.8 - 0.012) for u in US]
mouth += [(u * W, mouth_top(u) + 0.012) for u in reversed(US)]
decal(mouth, MZ, 0.006, 0.05, "mouth", "Mouth")
UT = [u * 0.86 for u in US]
teeth = [(u * W, mouth_top(u) - 0.08 * (1 - (u / 0.9) ** 2) ** 0.5 - 0.02) for u in UT]
teeth += [(u * W, mouth_top(u) - 0.006) for u in reversed(UT)]
decal(teeth, MZ, 0.02, 0.04, "teeth", "Teeth")


# ---------------------------------------------------------------------------------------------
# Finish: join + centre (no baked colour), then paint the toy colours per vertex (GigaStatue rule).
# ---------------------------------------------------------------------------------------------
def smoothstep(a, b, x):
    t = min(1.0, max(0.0, (x - a) / (b - a)))
    return t * t * (3 - 2 * t)


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


# Built at R6-like proportions (6.8 studs), shipped scaled to SCALE (about 6 studs with the plinth).
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

if not os.environ.get("HERO_NORENDER"):
    ck.render_prop(obj, os.path.join(OUT, KIND + "_game.png"), size=320, samples=32, game=True, azimuth=24.0,
                   elevation=10.0)
    obj.data.materials.clear()
    obj.data.materials.append(beauty_material())
    ck.render_prop(obj, os.path.join(OUT, KIND + ".png"), size=640, azimuth=28.0, elevation=6.0, lens=40.0)
    for view, az, el in (("34", 28.0, 6.0), ("front", 0.0, 6.0), ("side", 90.0, 6.0), ("back", 180.0, 8.0)):
        ck.render_prop(obj, os.path.join(OUT, "%s_view_%s.png" % (KIND, view)), size=480, samples=48, azimuth=az,
                       elevation=el)
