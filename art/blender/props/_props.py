"""Shared helpers for the lifestyle / beach prop scripts (props-decor set).

Puts art/blender/lib on sys.path, defines the output folders and adds a few modelling helpers
chadkit lacks (soft rounded boxes, round discs, the chunky palm builder) plus ship(), which
finishes a prop for the game and writes every output:

    art/out/props/<Kind>.fbx          Roblox mesh (1 unit = 1 stud, origin at the base centre, front -Z)
    art/out/props/<Kind>.json         {"tris", "size": [x, y, z] studs, Roblox axes (Y up)}
    art/out/props/<Kind>.png          beauty shot
    art/out/props/<Kind>_game.png     honest in-game look (vertex colours on SmoothPlastic)
    preview/web/models/props__<Kind>.glb   same mesh with vertex colours, Y up, for the web preview

Blender space: Z up, -Y is the front (Roblox -Z), units = studs.
"""

import json
import math
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "lib"))

import bpy  # noqa: E402
import chadkit as ck  # noqa: E402
from mathutils import Vector  # noqa: E402

OUT = os.path.join(ck.ROOT, "art", "out", "props")
GLB_DIR = os.path.join(ck.ROOT, "preview", "web", "models")
os.makedirs(OUT, exist_ok=True)
os.makedirs(GLB_DIR, exist_ok=True)

TRI_CAP = 2500


def mat(name, color, **kw):
    return ck.toy_material(name, color, **kw)


def _weighted(ob):
    wn = ob.modifiers.new("ChadWeighted", "WEIGHTED_NORMAL")
    wn.keep_sharp = True
    wn.weight = 50
    return ob


def rbox(size, radius, m, loc=(0, 0, 0), seg=2, name="Box", rot=None, taper=1.0):
    """Rounded box (base at loc.z) shaded fully smooth with weighted normals, so the big round
    bevels read as soft plastic and the flat faces stay flat."""
    ob = ck.rounded_box(size, radius, seg, m, name, loc, taper)
    ck.shade_smooth(ob, 80)
    if rot:
        ob.rotation_euler = tuple(math.radians(a) for a in rot)
    return _weighted(ob)


def disc(radius, z0, z1, bevel, m, loc=(0, 0, 0), seg=16, steps=2, name="Disc", rot=None, r0=0.0):
    """Solid cylinder from z0 to z1 with round bevels (lathe), optional rotation in degrees."""
    ob = ck.lathe(ck.round_profile(r0, radius, z0, z1, bevel, steps), seg, m, name, loc, smooth_angle=70)
    if rot:
        ob.rotation_euler = tuple(math.radians(a) for a in rot)
    return ob


def ball(radius, m, loc, seg=10, rings=7, scale=None, name="Ball"):
    ob = ck.sphere(radius, seg, rings, m, name, loc)
    ck.shade_smooth(ob, 80)
    if scale:
        ob.scale = scale
    return ob


def _leaf_profile(tip=0.36):
    """(u, half-width) samples of a fat paddle leaf: a narrow root inside the crown, a wide flat
    middle and a semicircular blunt tip over the last `tip` of its length."""
    prof = [(0.0, 0.42), (0.13, 0.78), (0.3, 0.95), (1.0 - tip, 1.0)]
    for deg in (35, 64, 84):
        t = math.radians(deg)
        prof.append((1.0 - tip + tip * math.sin(t), math.cos(t)))
    prof.append((1.0, 0.0))
    return prof


def palm(base=(0.0, 0.0, 0.0), height=11.0, lean=(0.0, 1.4), trunk_r=(1.85, 1.3), rings=4, flare=0.0,
         leaves=8, leaf_len=6.0, leaf_w=1.9, leaf_t=0.34, rise=0.9, fall=1.25, crown_r=2.1, nuts=3,
         nut_r=0.95, trunk_sides=10, leaf_sides=8, spin=0.35):
    """Stocky toy palm: a fat, gently tapering and leaning trunk of `rings` bulging ring segments
    (alternating warm tan / orange-tan) on an optional rounded base flare, a round emerald crown,
    `leaves` short fat paddle leaves with blunt round tips that arch up then down (bright lime top,
    lighter midrib, emerald underside; alternate leaves sit higher and shorter so the crown reads
    as one chunky starburst) and a cluster of fat caramel coconuts. Returns the list of parts."""
    base = Vector(base)
    lv = Vector((lean[0], lean[1], 0.0))
    up = Vector((-lean[1], lean[0], 0.0)).normalized() if lv.length > 1e-4 else Vector((1, 0, 0))
    tan_a = mat("TrunkTan", "Tan")
    tan_b = mat("TrunkOrange", ck.mix("Tan", "Orange", 0.55))
    crown_m = mat("Crown", "Emerald")
    nut_m = mat("Coconut", ck.mix("WoodDark", "Coral", 0.3))
    lime = mat("Leaf", "Lime")
    rib = mat("LeafRib", ck.mix("Lime", "Sunny", 0.25))
    under = mat("LeafUnder", "Emerald")

    def centre(t):
        return base + lv * (t ** 1.6) + Vector((0, 0, height * t))

    parts = []
    if flare > 0:
        r = trunk_r[0]
        parts.append(ck.lathe([(0, 0), (r + flare - 0.3, 0), (r + flare - 0.05, 0.12), (r + flare, 0.36),
                               (r + flare * 0.55, 0.85), (r + flare * 0.2, 1.3), (r * 0.98, 1.75), (0, 1.75)],
                              trunk_sides, tan_b, "Flare", base, smooth_angle=80))
    for i in range(rings):
        t0, t1 = i / rings, (i + 1) / rings
        r = trunk_r[0] + (trunk_r[1] - trunk_r[0]) * (i / max(1, rings - 1))
        ts = [t0, t0 + 0.35 * (t1 - t0), t0 + 0.78 * (t1 - t0), t1 + 0.05 * (t1 - t0)]
        rs = [r * 0.8, r * 1.02, r * 1.04, r * 0.84]
        parts.append(ck.sweep([centre(t) for t in ts], rs, trunk_sides, tan_a if i % 2 == 0 else tan_b,
                              "Trunk%d" % i, up=tuple(up), smooth_angle=80))
    top = centre(1.0) + Vector((0, 0, crown_r * 0.3))
    parts.append(ball(crown_r, crown_m, top, 10, 7, name="Crown"))

    prof = _leaf_profile()
    S = leaf_sides
    for k in range(leaves):
        a = 2 * math.pi * k / leaves + spin
        d = Vector((math.cos(a), math.sin(a), 0))
        upper = k % 2 == 1
        ln = leaf_len * (0.84 if upper else 1.0)
        lift = (0.16 if upper else -0.12) * crown_r
        r_up = rise * (1.35 if upper else 1.0)
        pts = []
        for u, _ in prof:
            # Arch: rises to about `rise` a third of the way out, then droops `fall` below the root.
            h = (4 * r_up * u * (1 - u) * 1.15) - (fall + 0.2 * r_up) * u ** 2.2
            pts.append(top + d * (crown_r * 0.4 + ln * u) + Vector((0, 0, lift + h)))
        blade = ck.sweep(pts, [w * leaf_w for _, w in prof], S, lime, "Leaf", flatten=leaf_t / leaf_w * 1.0,
                         smooth_angle=75)
        me = blade.data
        me.materials.append(rib)
        me.materials.append(under)
        # Ring vertices: index j at angle 2*pi*j/S; sin > 0 is the top face. Faces j..j+1 with both
        # ends on the top half are lime, the two around the top centre are the midrib, the rest
        # (bottom half) emerald.
        for p in me.polygons:
            js = {v % S for v in p.vertices if v < (len(prof) - 1) * S}
            if len(p.vertices) > 4:
                p.material_index = 2  # root cap, hidden in the crown
                continue
            tops = [math.sin(2 * math.pi * j / S) for j in js]
            if not tops:
                continue
            if min(tops) < -1e-3:
                p.material_index = 2
            elif S % 4 == 0 and (S // 4) in js and min(tops) > 0.5:
                p.material_index = 1
        parts.append(blade)
    for k in range(nuts):
        a = 2 * math.pi * k / max(1, nuts) + spin + 0.4
        off = Vector((math.cos(a), math.sin(a), 0)) * (crown_r * 0.6)
        parts.append(ball(nut_r, nut_m, top + off + Vector((0, 0, -crown_r * 0.72)), 8, 6, name="Coconut"))
    return parts


def flat_text(body, size, m, font=ck.FONT_PATH, res=2, name="Text"):
    """Flat (front-facing, no extrude) text mesh lying in XY facing +Z, centred on the origin: a cheap
    painted-on lettering decal (curve resolution `res` keeps it to a few hundred triangles)."""
    cu = bpy.data.curves.new(name, "FONT")
    cu.body = body
    cu.font = bpy.data.fonts.load(font, check_existing=True)
    cu.size = size
    cu.resolution_u = res
    cu.align_x = "CENTER"
    cu.align_y = "CENTER"
    tmp = bpy.data.objects.new(name + "_curve", cu)
    bpy.context.scene.collection.objects.link(tmp)
    dg = bpy.context.evaluated_depsgraph_get()
    me = bpy.data.meshes.new_from_object(tmp.evaluated_get(dg), depsgraph=dg)
    bpy.data.objects.remove(tmp, do_unlink=True)
    xs = [v.co.x for v in me.vertices]
    ys = [v.co.y for v in me.vertices]
    for v in me.vertices:
        v.co.x -= (min(xs) + max(xs)) / 2
        v.co.y -= (min(ys) + max(ys)) / 2
    me.materials.append(m)
    ob = bpy.data.objects.new(name, me)
    bpy.context.scene.collection.objects.link(ob)
    ck.shade_flat(ob)
    return ob


def export_glb(obj, path):
    """GLB of `obj` only, Y up, with the baked "Col" vertex colours (COLOR_0)."""
    ck._select_only([obj], obj)
    kw = dict(filepath=path, export_format="GLB", use_selection=True, export_yup=True, export_apply=True,
              export_materials="EXPORT", export_animations=False, export_normals=True, export_texcoords=False)
    try:
        bpy.ops.export_scene.gltf(export_vertex_color="ACTIVE", **kw)
    except TypeError:
        bpy.ops.export_scene.gltf(export_colors=True, **kw)
    return path


def ship(parts, kind, tri_budget=1200, **render_kw):
    """Finishes `parts` into one game mesh named `kind`, exports FBX + GLB + stats json and renders
    the beauty shot and the in-game look. Returns (object, triangles)."""
    counts = sorted(((ck.triangle_count(p), p.name) for p in parts), reverse=True)
    raw = sum(c for c, _ in counts)
    print("PROPS_RAW", kind, raw, counts[:8])
    if raw > tri_budget:
        print("PROPS_WARN %s: %d raw triangles over budget %d, decimating" % (kind, raw, tri_budget))
    obj, tris = ck.finish_for_game(parts, kind, tri_budget=tri_budget, tri_cap=TRI_CAP)
    ck.export_fbx(obj, os.path.join(OUT, kind + ".fbx"))
    export_glb(obj, os.path.join(GLB_DIR, "props__%s.glb" % kind))
    sx, sy, sz = (float(v) for v in obj["chad_size"])
    stats = {"kind": kind, "tris": tris, "size": [round(sx, 2), round(sz, 2), round(sy, 2)],
             "axes": "Roblox studs [X, Y up, Z]; front faces -Z; origin at the base centre"}
    with open(os.path.join(OUT, kind + ".json"), "w") as f:
        json.dump(stats, f, indent=1)
    ck.render_prop(obj, os.path.join(OUT, kind + ".png"), **render_kw)
    ck.render_prop(obj, os.path.join(OUT, kind + "_game.png"), size=320, samples=32, game=True, **render_kw)
    print("PROPS_STATS", json.dumps(stats))
    return obj, tris
