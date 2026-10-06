"""Shared helpers for the redo-props set (PalmTree, PalmPlanter, Vault, CrateCracker(Vip), Crown).

- C: the world palette as explicit sRGB triples (Theme.World keeps several colours in Luau locals
  that chadkit's theme parser cannot see, so these scripts name the values directly).
- fit(): scales a finished set of parts to an exact bounding box (keeps each prop on its old stats).
- palm(): the chunky toy palm (fat ringed trunk, big blobby crown of inflated leaf pillows).
- ship(): finish_for_game with tunable AO, then FBX + GLB + stats json + beauty / in-game renders,
  written to the same paths as _props.ship / _hero.ship.

Blender space: Z up, -Y is the front (Roblox -Z), units = studs.
"""

import json
import math
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "lib"))
sys.path.insert(0, HERE)

import bpy  # noqa: E402
import chadkit as ck  # noqa: E402
from mathutils import Matrix, Vector  # noqa: E402

from _props import export_glb  # noqa: E402

OUT = os.path.join(ck.ROOT, "art", "out", "props")
GLB_DIR = os.path.join(ck.ROOT, "preview", "web", "models")
TRI_CAP = 2500

AXES_PROPS = "Roblox studs [X, Y up, Z]; front faces -Z; origin at the base centre"
AXES_HERO = "roblox x, y (height), z (depth)"

# Theme.World values (sRGB 0..255) plus a few prop tones mixed from them.
C = {
    "Teal": (44, 170, 170),
    "TealLight": (112, 210, 200),
    "TealDeep": (24, 118, 128),
    "Cobalt": (44, 112, 208),
    "Sunny": (255, 204, 48),
    "Butter": (255, 230, 110),
    "Gold": (255, 190, 36),
    "GoldDeep": (236, 150, 34),
    "RedOrange": (240, 92, 52),
    "Coral": (255, 112, 96),
    "Orange": (255, 162, 72),
    "Cream": (255, 247, 232),
    "White": (255, 255, 255),
    "Honey": (224, 186, 124),
    "Ink": (58, 48, 96),
    "Mint": (98, 224, 160),
    "Pink": (255, 138, 190),
    # palm
    "LeafLime": (132, 226, 58),
    "LeafRib": (176, 238, 92),
    "LeafUnder": (46, 196, 112),
    "CrownTop": (112, 214, 56),
    "TrunkHoney": (238, 182, 104),
    "TrunkGroove": (218, 128, 62),
    "Coconut": (190, 118, 64),
    "Soil": (176, 120, 72),
}

# chadkit's renderer and finisher look up a few world colours by name (render_prop's backdrop mixes
# "Blue"); Theme.World now sets those through Luau locals the parser skips, so fill them in here.
for _k, _v in {"Blue": (92, 178, 255), "White": (255, 255, 255), "Sunny": C["Sunny"], "Coral": C["Coral"],
               "Orange": C["Orange"], "Teal": C["Teal"], "Butter": C["Butter"]}.items():
    ck.PALETTE.setdefault(_k, _v)


def m(name, color, **kw):
    """Toy material from a C key or an sRGB triple."""
    return ck.toy_material(name, C.get(color, color) if isinstance(color, str) else color, **kw)


def ball(radius, mat, loc, seg=12, rings=7, scale=None, name="Ball"):
    ob = ck.sphere(radius, seg, rings, mat, name, loc)
    ck.shade_smooth(ob, 80)
    if scale:
        ob.scale = scale
    return ob


def disc(radius, z0, z1, bevel, mat, loc=(0, 0, 0), seg=16, steps=2, name="Disc", rot=None, r0=0.0):
    """Solid cylinder z0..z1 with round bevels (lathe), optional rotation in degrees."""
    ob = ck.lathe(ck.round_profile(r0, radius, z0, z1, bevel, steps), seg, mat, name, loc, smooth_angle=70)
    if rot:
        ob.rotation_euler = tuple(math.radians(a) for a in rot)
    return ob


def fit(parts, size, keep_base=True):
    """Scales `parts` (per axis, about the base centre) so their bounds are exactly `size` (Blender
    x, y, z studs; None keeps that axis). Returns the factors."""
    bpy.context.view_layer.update()
    lo, hi = ck.bounds(parts)
    cur = hi - lo
    f = [1.0 if s is None else s / max(c, 1e-6) for s, c in zip(size, cur)]
    pivot = Vector(((lo.x + hi.x) / 2, (lo.y + hi.y) / 2, lo.z if keep_base else (lo.z + hi.z) / 2))
    mat = Matrix.Translation(pivot) @ Matrix.Diagonal((*f, 1.0)) @ Matrix.Translation(-pivot)
    ck.apply_transforms(parts)
    for ob in ck._as_objects(parts):
        ob.data.transform(mat)
    bpy.context.view_layer.update()
    return f


def _ring_mats(ob, z_lo, z_hi, groove=0.16):
    """Faces of a trunk segment near its two ends get material index 1 (the groove colour)."""
    span = max(z_hi - z_lo, 1e-6)
    for p in ob.data.polygons:
        f = (p.center.z - z_lo) / span
        if f < groove or f > 1.0 - groove:
            p.material_index = 1


def palm(base=(0.0, 0.0, 0.0), height=11.0, lean=(0.0, 1.0), trunk_r=(2.7, 2.05), rings=4, flare=0.9,
         leaves=7, leaf_len=5.6, leaf_w=2.2, leaf_t=0.42, rise=0.8, droop=3.3, crown_r=2.5, nuts=3,
         nut_r=1.05, trunk_sides=10, leaf_sides=10, spin=0.3, nut_seg=(10, 7), trunk="TrunkHoney",
         groove="TrunkGroove", foot=None, nut="Coconut"):
    """Toy palm. A thick, gently curved trunk of `rings` bulging honey-tan ring segments with
    orange-tan grooves on a rounded foot; a lime crown dome; `leaves` inflated leaf pillows (fat
    teardrops, widest past the middle, real thickness, fully round tips) that arch a little and then
    droop into one overlapping umbrella; bright lime tops, a light emerald underside; `nuts` big
    caramel coconuts tucked under the crown. `trunk` / `groove` / `foot` / `nut` (C keys or sRGB
    triples) paint the ring segments, the bands where they meet, the rounded foot (default: the
    groove colour) and the coconuts. Returns the list of parts."""
    base = Vector(base)
    lv = Vector((lean[0], lean[1], 0.0))
    up = Vector((-lean[1], lean[0], 0.0)).normalized() if lv.length > 1e-4 else Vector((1, 0, 0))
    honey = m("Trunk", trunk)
    groove_m = m("TrunkBand", groove)
    foot_m = m("TrunkFoot", foot) if foot else groove_m
    lime = m("Leaf", "LeafLime")
    rib = m("LeafRib", "LeafRib")
    under = m("LeafUnder", "LeafUnder")
    dome_m = m("CrownDome", "CrownTop")
    nut_m = m("Coconut", nut)

    def centre(t):
        # Gentle curve: the lean grows with t^1.6, so the trunk bends more near the top.
        return base + lv * (t ** 1.6) + Vector((0, 0, height * t))

    parts = []
    if flare > 0:
        r = trunk_r[0]
        prof = [(0, 0), (r + flare - 0.35, 0), (r + flare - 0.06, 0.14), (r + flare, 0.42),
                (r + flare * 0.55, 0.95), (r * 0.98, 1.6), (0, 1.6)]
        parts.append(ck.lathe(prof, trunk_sides, foot_m, "Flare", tuple(base), smooth_angle=80))
    for i in range(rings):
        t0, t1 = i / rings, (i + 1) / rings
        r = trunk_r[0] + (trunk_r[1] - trunk_r[0]) * (i / max(1, rings - 1))
        d = t1 - t0
        fr = [0.0, 0.12, 0.45, 0.82, 1.0 + 0.04]
        rs = [r * 0.82, r * 0.98, r * 1.05, r * 1.0, r * 0.84]
        ts = [t0 + f * d for f in fr]
        seg = ck.sweep([centre(t) for t in ts], rs, trunk_sides, honey, "Trunk%d" % i, up=tuple(up),
                       smooth_angle=80)
        seg.data.materials.append(groove_m)
        _ring_mats(seg, centre(ts[0]).z, centre(ts[-1]).z)
        parts.append(seg)

    top = centre(1.0)
    # Crown dome: a squashed lime ball that hides the leaf roots and rounds off the top.
    parts.append(ball(crown_r, dome_m, top + Vector((0, 0, crown_r * 0.42)), 12, 8,
                      scale=(1.0, 1.0, 0.78), name="CrownDome"))

    # Leaf pillow plan shape: (u along the leaf, half-width as a share of leaf_w). Widest at the start
    # of the tip; the tip is a true half circle (its length equals the half width), so it ends round.
    S = leaf_sides
    var = [1.0, 0.93, 1.04, 0.95, 1.0, 0.91, 1.03]
    for k in range(leaves):
        a = 2 * math.pi * k / leaves + spin
        dvec = Vector((math.cos(a), math.sin(a), 0))
        ln = leaf_len * var[k % len(var)]
        tip = min(0.48, leaf_w / ln)
        prof = [(0.0, 0.42), (0.12, 0.66), (0.3, 0.86), (0.5 * (1 - tip) + 0.3 * tip, 0.96), (1 - tip, 1.0)]
        for deg in (28, 52, 72, 86):
            tr = math.radians(deg)
            prof.append((1 - tip + tip * math.sin(tr), math.cos(tr)))
        prof.append((1.0, 0.0))
        r0 = crown_r * 0.32
        lift = crown_r * 0.18 * (1 if k % 2 else 0.4)
        pts = []
        for u, _ in prof:
            h = rise * 4 * u * (1 - u) - droop * (u ** 2.0)
            reach = r0 + ln * (u - 0.18 * u ** 3)  # tips curl in a little as they droop
            pts.append(top + dvec * reach + Vector((0, 0, lift + h)))
        leaf = ck.sweep(pts, [w * leaf_w for _, w in prof], S, lime, "Leaf", flatten=leaf_t, smooth_angle=85)
        me = leaf.data
        me.materials.append(rib)
        me.materials.append(under)
        n_ring = (len(prof) - 1) * S  # vertices before the tip point
        for p in me.polygons:
            if len(p.vertices) > 4:
                p.material_index = 2  # root cap, hidden in the dome
                continue
            js = {v % S for v in p.vertices if v < n_ring}
            if not js:
                continue
            tops = [math.sin(2 * math.pi * j / S) for j in js]
            if min(tops) < -1e-3:
                p.material_index = 2
            elif S >= 10 and min(tops) > 0.9:
                p.material_index = 1  # lighter midrib stripe along the top
        parts.append(leaf)

    for k in range(nuts):
        a = 2 * math.pi * k / max(1, nuts) + spin + 0.5
        off = Vector((math.cos(a), math.sin(a), 0)) * (trunk_r[1] * 0.9)
        parts.append(ball(nut_r, nut_m, top + off + Vector((0, 0, -nut_r * 0.85)), *nut_seg, name="Coconut"))
    return parts


def ship(parts, kind, tri_budget=1500, axes=AXES_PROPS, renders=True, finish=None, **render_kw):
    """Finishes `parts` into one game mesh named `kind`, writes FBX + GLB + stats json and (unless
    renders=False) the beauty shot and the in-game look. Returns (object, triangles)."""
    counts = {}
    for o in ck._as_objects(parts):
        key = o.name.split(".")[0]
        counts[key] = counts.get(key, 0) + ck.triangle_count(o)
    raw = sum(counts.values())
    print("REDO_RAW", kind, raw, sorted(counts.items(), key=lambda kv: -kv[1])[:10])
    if raw > tri_budget:
        print("REDO_WARN %s: %d raw triangles over budget %d, decimating" % (kind, raw, tri_budget))
    obj, tris = ck.finish_for_game(parts, kind, tri_budget=tri_budget, tri_cap=TRI_CAP, **(finish or {}))
    ck.export_fbx(obj, os.path.join(OUT, kind + ".fbx"))
    export_glb(obj, os.path.join(GLB_DIR, "props__%s.glb" % kind))
    sx, sy, sz = (float(v) for v in obj["chad_size"])
    stats = {"kind": kind, "tris": tris, "size": [round(sx, 2), round(sz, 2), round(sy, 2)], "axes": axes}
    with open(os.path.join(OUT, kind + ".json"), "w") as f:
        json.dump(stats, f, indent=1)
    if renders:
        ck.render_prop(obj, os.path.join(OUT, kind + ".png"), **render_kw)
        ck.render_prop(obj, os.path.join(OUT, kind + "_game.png"), size=320, samples=32, game=True, **render_kw)
    print("REDO_STATS", json.dumps(stats), "raw", raw)
    return obj, tris
