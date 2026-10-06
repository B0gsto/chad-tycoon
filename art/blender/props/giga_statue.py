"""Hero prop: GigaStatue, the hub centre piece (about 21 studs wide, 21 tall, 8 deep). A heroic,
friendly chunky toy trophy of a muscle man in bright gold, hitting a double-biceps flex on a chunky
stepped teal plinth, proportioned like a collectible vinyl figure.

The figure is modelled as signed distance fields and meshed with surface nets, so every joint is a
smooth union instead of a crease between separate primitives:
- body (gold, one mesh): short thick straight legs on big rounded shoes planted flat; small waist
  and hips flaring into one broad V torso (a cone flattened front to back, capped by a round chest
  dome with one soft centre line); a round shoulder ball each side; each arm a fat upper arm with
  one biceps bump, a round elbow ball, a thick vertical forearm and a big rounded fist at head
  height; a short thick neck under a big square-jawed head (about a third of the figure) with small
  ears, a button nose and one swept-back quiff (a single tilted ellipsoid, front raised).
- accents (each one mesh, an offset of the body cut to a region with rounded edges): sunglasses
  (a thin shell hugging the face, cut to two fat rounded-rectangle lenses and a bridge), smooth
  cobalt shorts, a red-orange belt with a plate and a sunny star buckle, red-orange wristbands
  seated tight under the fists.
- plinth: cobalt trim ring, teal body with big bevels, cream top lip, a coral star on the front.
- a short thick closed-mouth smirk (one corner lifted), one white glint per lens and one crisp shine
  streak along the quiff.
Symmetric; front = -Y.

Colour is painted per vertex after finish_for_game (which here only joins and centres): saturated
yellow gold with a crisp light rim on every upward-facing curve and a warm orange-gold only in the
recesses; every other part has its own light / deep pair, the lenses a top-to-bottom gloss gradient.
The beauty shot uses a glossier clear coat over the same vertex colours; the _game shot shows exactly
what ships. Writes the standard props-hero deliverables (see _hero.py)."""

import json
import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _hero import OUT, TRI_CAP, WEB, ck, export_glb, place  # noqa: E402

import bmesh  # noqa: E402
import bpy  # noqa: E402
import numpy as np  # noqa: E402
from mathutils import Vector  # noqa: E402
from mathutils.bvhtree import BVHTree  # noqa: E402

KIND = "GigaStatue"
VIEWS = os.environ.get("STATUE_VIEWS", "/tmp/chad-redesign/statue")
TRI_BUDGET = 2490

# Colour roles (sRGB 0..255): base (also the unique material colour used to find the role after the
# join), light (top / rim-lit), deep (recesses and undersides).
ROLES = {
    "gold": ((255, 204, 48), (255, 232, 120), (232, 140, 28)),
    "shine": ((255, 252, 226), (255, 255, 246), (255, 232, 150)),
    "shades": ((36, 96, 200), (112, 176, 252), (24, 62, 152)),
    "cobalt": ((44, 120, 216), (104, 170, 246), (30, 84, 170)),
    "glint": ((255, 255, 254), (255, 255, 255), (222, 238, 255)),
    "mouth": ((178, 62, 44), (204, 86, 60), (150, 50, 36)),
    "belt": ((242, 90, 54), (255, 146, 108), (196, 58, 36)),
    "sunny": ((255, 196, 36), (255, 234, 128), (236, 148, 24)),
    "coral": ((255, 112, 96), (255, 162, 142), (214, 74, 66)),
    "teal": ((44, 170, 170), (104, 210, 202), (24, 118, 128)),
    "cream": ((255, 247, 232), (255, 255, 250), (228, 210, 180)),
}
RIM_WEIGHT = {"gold": 0.7, "shine": 0.2, "glint": 0.0, "mouth": 0.0}
DEEP_WEIGHT = {"gold": 0.55}


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
M = {k: ck.toy_material("Statue_" + k, v[0]) for k, v in ROLES.items()}


# ---------------------------------------------------------------------------------------------
# Signed distance toolkit (numpy, points as (N, 3) arrays; negative inside).
# ---------------------------------------------------------------------------------------------
def _len(v):
    return np.sqrt(np.einsum("...i,...i->...", v, v))


def smin(a, b, k):
    """Smooth union: a rounded fillet of size ~k where a and b meet."""
    h = np.maximum(k - np.abs(a - b), 0.0) / k
    return np.minimum(a, b) - h * h * k * 0.25


def smax(a, b, k):
    return -smin(-a, -b, k)


def rot_z(deg):
    c, s = math.cos(math.radians(deg)), math.sin(math.radians(deg))
    return np.array([[c, -s, 0], [s, c, 0], [0, 0, 1.0]])


def rot_x(deg):
    c, s = math.cos(math.radians(deg)), math.sin(math.radians(deg))
    return np.array([[1.0, 0, 0], [0, c, -s], [0, s, c]])


def sphere_d(p, c, r):
    return _len(p - np.asarray(c, float)) - r


def ellipsoid_d(p, c, r, rot=None):
    q = p - np.asarray(c, float)
    if rot is not None:
        q = q @ rot
    r = np.asarray(r, float)
    k0 = _len(q / r)
    k1 = _len(q / (r * r))
    return k0 * (k0 - 1.0) / np.maximum(k1, 1e-9)


def cone_d(p, a, b, r1, r2):
    """Round cone (tapered capsule) from a (radius r1) to b (radius r2)."""
    a, b = np.asarray(a, float), np.asarray(b, float)
    ba = b - a
    l2 = ba @ ba
    rr = r1 - r2
    a2 = l2 - rr * rr
    il2 = 1.0 / l2
    pa = p - a
    y = pa @ ba
    z = y - l2
    x = pa * l2 - y[:, None] * ba
    x2 = np.einsum("ij,ij->i", x, x)
    y2 = y * y * l2
    z2 = z * z * l2
    k = np.sign(rr) * rr * rr * x2
    return np.where(np.sign(z) * a2 * z2 > k, np.sqrt(x2 + z2) * il2 - r2,
                    np.where(np.sign(y) * a2 * y2 < k, np.sqrt(x2 + y2) * il2 - r1,
                             (np.sqrt(np.maximum(x2 * a2 * il2, 0.0)) + y * rr) * il2 - r1))


def box_d(p, c, half, r):
    q = np.abs(p - np.asarray(c, float)) - (np.asarray(half, float) - r)
    return _len(np.maximum(q, 0.0)) + np.minimum(q.max(axis=1), 0.0) - r


def slab(p, lo, hi, axis=2):
    return np.maximum(lo - p[:, axis], p[:, axis] - hi)


# ---------------------------------------------------------------------------------------------
# The figure.
# ---------------------------------------------------------------------------------------------
BASE = 3.05  # top of the plinth lip, where the feet stand
HEAD_C = np.array((0.0, -0.45, 17.5))
HA, HB, HC, HP, JAW = 2.8, 2.5, 2.55, 2.7, 0.09
ZE = 17.85  # eye line (lens centre)
BELT_LO, BELT_HI, BELT_MID = 8.75, 9.8, 9.27
SHOULDER = (4.85, 0.15, 13.25)
ELBOW = (8.55, 0.35, 13.65)
WRIST = (8.75, 0.35, 16.15)
FIST = ((8.8, 0.3, 17.25), (1.6, 1.5, 1.45))
QUIFF = ((0.0, -0.7, 19.9), (2.65, 2.95, 1.2), -22.0)


def squash_d(fn, p, sy):
    """fn evaluated on space stretched along y by sy (so fn's round shapes come out sy times thinner)."""
    return fn(p * np.array((1.0, sy, 1.0))) / sy


def legs_d(p):
    d = None
    for sx in (1, -1):
        shoe = ellipsoid_d(p, (sx * 2.1, -1.05, BASE + 0.6), (1.6, 2.4, 1.0))
        leg = cone_d(p, (sx * 2.0, -0.1, BASE + 1.2), (sx * 2.0, 0.0, 8.2), 1.42, 1.55)
        one = smin(shoe, leg, 0.3)
        d = one if d is None else np.minimum(d, one)
    return d


def pelvis_d(p):
    hips = ellipsoid_d(p, (0, 0.0, 8.1), (2.95, 1.95, 1.45))
    waist = ellipsoid_d(p, (0, 0.0, 9.6), (2.45, 1.7, 1.4))
    return smin(hips, waist, 1.0)


def lower_d(p):
    return smin(legs_d(p), pelvis_d(p), 0.6)


def torso_d(p):
    # Big smooth V: a cone flattened front-to-back from the small waist up to the wide chest,
    # capped by a round chest dome, with one round shoulder ball each side.
    v = squash_d(lambda q: cone_d(q, (0, 0, 9.5), (0, 0, 11.8), 2.3, 4.2), p, 1.75)
    chest = ellipsoid_d(p, (0, -0.15, 12.5), (4.5, 2.6, 2.2))
    d = smin(smin(lower_d(p), v, 0.8), chest, 1.0)
    groove = cone_d(p, (0, -2.95, 11.3), (0, -3.05, 12.8), 0.42, 0.36)
    d = smax(d, -groove, 0.55)
    for sx in (1, -1):
        d = smin(d, sphere_d(p, (sx * SHOULDER[0], SHOULDER[1], SHOULDER[2]), 1.85), 0.9)
    neck = cone_d(p, (0, -0.1, 13.4), (0, -0.3, 15.4), 1.75, 1.6)
    return smin(d, neck, 1.0)


def mirror(pt, sx):
    return (sx * pt[0], pt[1], pt[2])


def fore_d(p, sx):
    return cone_d(p, mirror(ELBOW, sx), mirror(WRIST, sx), 1.2, 1.35)


def arm_d(p, sx):
    upper = cone_d(p, mirror(SHOULDER, sx), mirror(ELBOW, sx), 1.4, 1.2)
    bic = ellipsoid_d(p, (sx * 6.6, 0.1, 14.35), (1.75, 1.4, 1.5))
    elbow = sphere_d(p, mirror(ELBOW, sx), 1.32)
    fc, fr = FIST
    fist = ellipsoid_d(p, mirror(fc, sx), fr)
    d = smin(smin(upper, bic, 0.7), elbow, 0.5)
    return smin(smin(d, fore_d(p, sx), 0.55), fist, 0.45)


def head_d(p):
    q = p - HEAD_C
    zn = q[:, 2] / HC
    w = 1.0 - JAW * np.clip(zn, -1.3, 1.3)
    f = (np.abs(q[:, 0] / (HA * w)) ** HP + np.abs(q[:, 1] / HB) ** HP + np.abs(zn) ** HP) ** (1.0 / HP)
    return (f - 1.0) * min(HA, HB, HC)


def head_full_d(p):
    d = head_d(p)
    qc, qr, qt = QUIFF
    d = smin(d, ellipsoid_d(p, qc, qr, rot_x(qt)), 0.45)
    for sx in (1, -1):
        d = smin(d, ellipsoid_d(p, (sx * 2.8, -0.2, 17.3), (0.42, 0.6, 0.78)), 0.25)
    return smin(d, ellipsoid_d(p, (0, -2.9, 16.95), (0.45, 0.4, 0.45)), 0.25)


def body_d(p):
    d = torso_d(p)
    for sx in (1, -1):
        d = smin(d, arm_d(p, sx), 0.6)
    d = smin(d, head_full_d(p), 0.7)
    return np.maximum(d, (BASE - 0.25) - p[:, 2])


def rrect2(x, z, cx, cz, hx, hz, r):
    qx = np.abs(x - cx) - (hx - r)
    qz = np.abs(z - cz) - (hz - r)
    return np.hypot(np.maximum(qx, 0.0), np.maximum(qz, 0.0)) + np.minimum(np.maximum(qx, qz), 0.0) - r


LENS = (1.32, 1.18, 0.86, 0.52)  # centre |x|, half width, half height, corner radius


def shades_region(p):
    x, z = np.abs(p[:, 0]), p[:, 2]
    lx, hx, hz, r = LENS
    lens = rrect2(x, z, lx, ZE, hx, hz, r)
    bridge = rrect2(x, z, 0.0, ZE + 0.28, 0.5, 0.2, 0.18)
    return np.maximum(np.minimum(lens, bridge), p[:, 1] - (HEAD_C[1] - 1.2))


def visor_d(p):
    """Sunglasses: a shell hugging the face (0.15 inside to 0.42 outside the head surface), cut to two
    rounded-rectangle lenses and a bridge."""
    h = head_d(p)
    return smax(np.maximum(h - 0.42, -(h + 0.15)), shades_region(p), 0.12)


def belt_d(p):
    band = smax(torso_d(p) - 0.3, slab(p, BELT_LO, BELT_HI), 0.12)
    plate = box_d(p, (0, PLATE_Y, BELT_MID), (1.45, 0.3, 0.95), 0.35)
    return smin(band, plate, 0.2)


def trunks_d(p):
    return smax(lower_d(p) - 0.16, slab(p, 6.35, 8.95), 0.14)


def march(fn, origin, direction, tmax=8.0):
    """First point where the ray origin + t * direction (origin inside) leaves fn's solid."""
    o, d = np.asarray(origin, float), np.asarray(direction, float)
    d = d / np.linalg.norm(d)
    lo, hi = 0.0, tmax
    for _ in range(40):
        mid = (lo + hi) / 2
        if fn((o + d * mid)[None])[0] < 0:
            lo = mid
        else:
            hi = mid
    return o + d * lo


PLATE_Y = march(torso_d, (0, 0, BELT_MID), (0, -1, 0))[1] - 0.25


# ---------------------------------------------------------------------------------------------
# Surface nets mesher.
# ---------------------------------------------------------------------------------------------
def _eval(fn, pts, chunk=400000):
    return np.concatenate([fn(pts[i:i + chunk]) for i in range(0, len(pts), chunk)])


def sdf_mesh(fn, lo, hi, step, mat, name, tris, smooth_angle=180.0):
    """Meshes fn's zero surface inside the box lo..hi with cells of `step`, snaps the vertices onto
    the surface, then collapse-decimates (X-symmetric) to about `tris` triangles."""
    axes = [np.arange(lo[i], hi[i] + step, step) for i in range(3)]
    grid = np.stack(np.meshgrid(*axes, indexing="ij"), -1)
    shape = grid.shape[:3]
    F = _eval(fn, grid.reshape(-1, 3)).reshape(shape)
    cells = tuple(n - 1 for n in shape)
    acc = np.zeros(cells + (3,))
    cnt = np.zeros(cells)
    edges = []
    for axis in range(3):
        s0, s1 = [slice(None)] * 3, [slice(None)] * 3
        s0[axis], s1[axis] = slice(0, -1), slice(1, None)
        f0, f1 = F[tuple(s0)], F[tuple(s1)]
        cross = (f0 < 0) != (f1 < 0)
        idx = np.argwhere(cross)
        a, b = f0[cross], f1[cross]
        pts = grid[tuple(idx.T)].copy()
        pts[:, axis] += a / (a - b) * step
        o1, o2 = [k for k in range(3) if k != axis]
        quad = []
        for d1, d2 in ((-1, -1), (0, -1), (0, 0), (-1, 0)):
            c = idx.copy()
            c[:, o1] += d1
            c[:, o2] += d2
            quad.append(c)
            ok = (c >= 0).all(1) & (c < np.array(cells)).all(1)
            np.add.at(acc, tuple(c[ok].T), pts[ok])
            np.add.at(cnt, tuple(c[ok].T), 1)
        edges.append((axis, quad, a < 0))
    active = cnt > 0
    vid = -np.ones(cells, dtype=np.int64)
    vid[active] = np.arange(active.sum())
    verts = acc[active] / cnt[active][:, None]
    faces = []
    for axis, quad, start_in in edges:
        ids = np.stack([vid[tuple(np.clip(c, 0, np.array(cells) - 1).T)] for c in quad], 1)
        valid = np.stack([((c >= 0) & (c < np.array(cells))).all(1) for c in quad], 1).all(1) & (ids >= 0).all(1)
        flip = start_in != (axis != 1)
        ids = np.where(flip[:, None], ids[:, ::-1], ids)
        faces.append(ids[valid])
    faces = np.concatenate(faces)
    # Snap onto the surface (two Newton steps on the field).
    e = step * 0.25
    for _ in range(2):
        d = _eval(fn, verts)
        g = np.stack([(_eval(fn, verts + ax * e) - _eval(fn, verts - ax * e)) / (2 * e) for ax in np.eye(3)], 1)
        g2 = np.maximum(np.einsum("ij,ij->i", g, g), 1e-6)
        verts = verts - (d / g2)[:, None] * g
    me = bpy.data.meshes.new(name)
    me.from_pydata(verts.tolist(), [], faces.tolist())
    me.validate()
    ob = ck._link(bpy.data.objects.new(name, me))
    me.materials.append(mat)
    bpy.context.view_layer.update()
    ck._select_only([ob], ob)
    for _ in range(3):
        n = ck.triangle_count(ob)
        if n <= tris * 1.02:
            break
        dec = ob.modifiers.new("Dec", "DECIMATE")
        dec.decimate_type = "COLLAPSE"
        dec.ratio = tris / n
        dec.use_collapse_triangulate = True
        dec.use_symmetry = True
        dec.symmetry_axis = "X"
        bpy.ops.object.modifier_apply(modifier=dec.name)
    ck.shade_smooth(ob, smooth_angle)
    bm = bmesh.new()
    bm.from_mesh(me)
    vol = bm.calc_volume(signed=True)
    open_edges = sum(1 for ed in bm.edges if not ed.is_manifold)
    bm.free()
    print("SDF_MESH", name, len(verts), "verts ->", ck.triangle_count(ob), "tris, volume %.2f" % vol,
          "non-manifold edges", open_edges)
    return ob


def surf(fn, origin, direction, lift):
    """Point on fn's surface along a ray from inside, lifted `lift` off it."""
    d = np.asarray(direction, float)
    return Vector(march(fn, origin, d) + d / np.linalg.norm(d) * lift)


accents = []

# ---- Plinth: chunky stepped block: a cobalt trim ring at the foot, a tall teal body with big
# bevels, a cream top lip the feet stand on, and a coral star on the front.


def open_bottom(ob, cut):
    """Deletes the faces lying entirely below local z = cut (they rest on the ground / sink in)."""
    bm = bmesh.new()
    bm.from_mesh(ob.data)
    bmesh.ops.delete(bm, geom=[f for f in bm.faces if all(v.co.z < cut for v in f.verts)], context="FACES")
    bm.to_mesh(ob.data)
    bm.free()
    return ob


accents.append(open_bottom(ck.rounded_box((12.8, 8.2, 0.7), 0.3, 2, M["cobalt"], "PlinthTrim"), 0.15))
accents.append(open_bottom(ck.rounded_box((12.0, 7.6, 2.1), 0.5, 2, M["teal"], "Plinth", (0, 0, 0.55)), 0.3))
accents.append(open_bottom(ck.rounded_box((12.4, 7.95, 0.5), 0.24, 2, M["cream"], "PlinthLip", (0, 0, 2.55)), 0.12))
plaque = ck.extrude_shape(ck.star_points(5, 0.95, 0.45), depth=0.4, mat=M["coral"], name="PlinthStar", bevel=0.0)
accents.append(place(plaque, (0, -3.82, 1.58), (90, 0, 0)))

# ---- Accent meshes cut from offsets of the body.
accents.append(sdf_mesh(visor_d, (-3.0, -3.8, ZE - 1.1), (3.0, -1.4, ZE + 1.1), 0.05, M["shades"], "Shades", 190,
                        smooth_angle=70))
accents.append(sdf_mesh(belt_d, (-4.0, -3.9, 8.0), (4.0, 3.0, 10.5), 0.06, M["belt"], "Belt", 115, smooth_angle=70))
accents.append(sdf_mesh(trunks_d, (-4.6, -3.0, 6.0), (4.6, 3.0, 9.4), 0.07, M["cobalt"], "Trunks", 120,
                        smooth_angle=70))
# Wristbands: a ring square to the forearm just under the fist, its edges sunk into the forearm.
for sx in (1, -1):
    e, w = Vector(mirror(ELBOW, sx)), Vector(mirror(WRIST, sx))
    ring = ck.lathe([(1.2, -0.38), (1.55, -0.22), (1.55, 0.22), (1.2, 0.38)], 8, M["belt"],
                    "Wristband", smooth_angle=70)
    ring.rotation_mode = "QUATERNION"
    ring.rotation_quaternion = Vector((0, 0, 1)).rotation_difference(w - e)
    ring.location = e.lerp(w, 0.8)
    accents.append(ring)

star_front = march(belt_d, (0, 0, BELT_MID), (0, -1, 0))
star = ck.extrude_shape(ck.star_points(5, 0.9, 0.42), depth=0.3, mat=M["sunny"], name="BeltStar", bevel=0.0)
accents.append(place(star, (0, star_front[1] - 0.08, BELT_MID), (90, 0, 0)))

# Confident closed-mouth smirk: a short thick curve lying on the face, one corner lifted.
SX = np.linspace(-0.85, 0.95, 6)
smile = [surf(body_d, (x, HEAD_C[1], 15.85 + 0.2 * ((x - 0.05) / 0.9) ** 2 + 0.16 * x), (0, -1, 0), 0.02)
         for x in SX]
accents.append(ck.sweep(smile, [0.14, 0.2, 0.23, 0.23, 0.2, 0.15], 6, M["mouth"], "Smirk", flatten=0.5,
                        up=(0, -1, 0), smooth_angle=80))

# One white glint on the upper outer corner of each lens.
for sx in (1, -1):
    cx = sx * LENS[0]
    pts = [surf(visor_d, (cx + sx * dx, -2.8, ZE + dz), (0, -1, 0), 0.02) for dx, dz in
           ((-0.55, 0.38), (-0.25, 0.12))]
    accents.append(ck.gloss_streak(pts, 0.26, Vector((0, -1, 0.2)).normalized(), mat=M["glint"], name="Glint",
                                   flatten=0.25, sides=4))

# One crisp toy shine streak along the quiff, toward the upper-left key light.
pts = [surf(body_d, (-0.8, y, 20.0), (0, -0.2, 1), 0.03) for y in (0.6, -0.5, -1.6, -2.6)]
accents.append(ck.gloss_streak(pts, 0.55, Vector((0, -0.2, 1)).normalized(), mat=M["shine"], name="QuiffShine",
                               flatten=0.22, sides=4))

accent_tris = sum(ck.triangle_count(o) for o in accents)
body_target = TRI_BUDGET - 10 - accent_tris
print("STATUE_SPLIT accents", accent_tris, "body target", body_target)
body = sdf_mesh(body_d, (-10.7, -4.4, BASE - 0.5), (10.7, 3.4, 22.0), 0.1, M["gold"], "Body", body_target)
parts = accents + [body]
if os.environ.get("STATUE_PARTS"):
    for o in parts:
        print("PART", o.name, ck.triangle_count(o))


# ---------------------------------------------------------------------------------------------
# Finish: join + centre (no baked colour), then paint the toy colours per vertex.
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
        o = v.co + n * 0.03
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
    # Lens gloss gradient spans the lens height (ZE - 0.85 .. ZE + 0.85, shifted by the centring).
    lens_lo = ZE - 0.85 - obj["chad_z0"]
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
            if r == "shades":
                k = smoothstep(0.0, 1.0, (z - lens_lo) / 1.7)
                k = min(1.0, k + 0.5 * smoothstep(0.6, 0.9, n.dot(rim)))
                rgb = [deep[i] + (light[i] - deep[i]) * k ** 1.2 for i in range(3)]
                k_deep = min(0.5, ao[vi] * 0.8)
                rgb = [x + (deep[i] - x) * k_deep for i, x in enumerate(rgb)]
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
    mat = ck.vcol_material("StatueBeauty")
    p = next(nd for nd in mat.node_tree.nodes if nd.type == "BSDF_PRINCIPLED")
    p.inputs["Roughness"].default_value = 0.22
    p.inputs["Coat Weight"].default_value = 1.0
    p.inputs["Coat Roughness"].default_value = 0.03
    p.inputs["Specular IOR Level"].default_value = 0.6
    return mat


raw = sum(ck.triangle_count(o) for o in parts)
z0 = min((o.matrix_world @ Vector(c)).z for o in parts for c in o.bound_box)
obj, tris = ck.finish_for_game(parts, KIND, tri_budget=TRI_CAP, tri_cap=TRI_CAP, ao_strength=0.0, ao_samples=1,
                               gradient=(1.0, 1.0))
obj["chad_z0"] = z0
paint(obj)
ck.export_fbx(obj, os.path.join(OUT, KIND + ".fbx"))
export_glb(obj, os.path.join(WEB, "props__%s.glb" % KIND))
sx_, sy_, sz_ = (round(v, 2) for v in obj["chad_size"])
stats = {"kind": KIND, "tris": tris, "size": [sx_, sz_, sy_], "axes": "roblox x, y (height), z (depth)"}
with open(os.path.join(OUT, KIND + ".json"), "w") as f:
    json.dump(stats, f, indent=1)
print("CHADKIT_STATS", json.dumps(stats), "source tris", raw)

if not os.environ.get("HERO_NORENDER"):
    # Renders for the look-and-fix loop: beauty 3/4, front, side, back and the in-game look; the
    # contact sheet is composed outside Blender (system python3 with Pillow).
    os.makedirs(VIEWS, exist_ok=True)
    ck.render_prop(obj, os.path.join(OUT, KIND + "_game.png"), size=240, samples=32, game=True, azimuth=24.0,
                   elevation=12.0)
    obj.data.materials.clear()
    obj.data.materials.append(beauty_material())
    ck.render_prop(obj, os.path.join(OUT, KIND + ".png"), size=640, azimuth=28.0, elevation=4.0, lens=40.0)
    for view, az, el in (("front", 0.0, 6.0), ("side", 90.0, 6.0), ("back", 180.0, 8.0)):
        ck.render_prop(obj, os.path.join(VIEWS, view + ".png"), size=400, samples=48, azimuth=az, elevation=el)
