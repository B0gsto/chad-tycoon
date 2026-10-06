"""Shared setup for the gym prop scripts (props-gym): paths, a few modelling helpers chadkit lacks, and
finish(), which turns the built parts into the shipped game mesh and writes every output.

Modelling space = the fallback builder's prop-local frame in src/server/World/Decor.luau, written in Blender
axes: Blender X = Roblox X, Blender Y = Roblox Z (the front, Roblox -Z, is Blender -Y), Blender Z = up.

Outputs per prop <Kind>:
  art/out/props/<Kind>.fbx              game mesh (chadkit.export_fbx)
  art/out/props/<Kind>.json             {"kind", "tris", "size": [x, y, z] studs (Roblox axes, y = up),
                                         "offset": base centre of the mesh in the fallback's prop frame}
  art/out/props/<Kind>.png              beauty shot
  art/out/props/<Kind>_game.png         honest in-game look (vertex colours, SmoothPlastic stand-in)
  preview/web/models/props__<Kind>.glb  same mesh with vertex colours for the web preview (Y up)
"""

import json
import math
import os
import sys

import bpy
import bmesh

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "lib"))

import chadkit as ck  # noqa: E402

OUT = os.path.join(ck.ROOT, "art", "out", "props")
WEB = os.path.join(ck.ROOT, "preview", "web", "models")
for d in (OUT, WEB):
    os.makedirs(d, exist_ok=True)

TRI_TARGET = 1200  # soft target; finish() warns above it
TRI_CAP = 2500  # hard cap: finish_for_game raises above it


def disc(radius, width, bevel, segments, mat, name, steps=3, axis="X", centre=(0, 0, 0), smooth=60.0):
    """Solid disc (weight plate, hub, base) `width` thick along `axis`, centred on `centre`, with the same
    round bevel of size `bevel` on both outer edges."""
    ob = ck.lathe(ck.round_profile(0, radius, -width / 2, width / 2, bevel, steps), segments, mat, name,
                  smooth_angle=smooth)
    if axis == "X":
        ob.rotation_euler = (0, math.radians(90), 0)
    elif axis == "Y":
        ob.rotation_euler = (math.radians(90), 0, 0)
    ob.location = centre
    return ob


def rod(a, b, radius, sides, mat, name, smooth=70.0):
    """Capsule (round-ended tube) from point a to point b, `radius` thick."""
    from mathutils import Vector

    a, b = Vector(a), Vector(b)
    d = b - a
    ob = ck.capsule(radius, d.length + 2 * radius, sides, max(2, sides // 4), mat, name)
    ob.rotation_euler = d.to_track_quat("Z", "Y").to_euler()
    ob.location = (a + b) / 2
    ck.shade_smooth(ob, smooth)
    return ob


def paint(ob, mat, predicate):
    """Appends `mat` to `ob` and assigns it to the faces whose centre (object space) passes `predicate`."""
    ob.data.materials.append(mat)
    idx = len(ob.data.materials) - 1
    for p in ob.data.polygons:
        if predicate(p.center):
            p.material_index = idx
    return ob


def curved_star(r_out, r_in, depth, mat, centre_z, sphere_r, sphere_c, name="Star", bevel=0.035,
                lift=0.0, cylinder=False):
    """A chunky star badge on the front (-Y) of a sphere/body of revolution: an extruded star whose back
    sits inside the surface and whose front face follows the curve `lift` + depth/2 proud of it, so it
    reads as a pressed-on badge from every angle. `sphere_r` is the surface radius around the vertical
    axis through `sphere_c` (x, y): a sphere centred at height centre_z, or a vertical cylinder."""
    star = ck.extrude_shape(ck.star_points(5, r_out, r_in, round_steps=1), depth=depth, mat=mat, name=name,
                            bevel=bevel, bevel_segments=1)
    me = star.data
    for v in me.vertices:
        x, zz, front = v.co.x, v.co.y, v.co.z  # star built in XY, extruded along Z
        h2 = sphere_r * sphere_r - x * x - (0.0 if cylinder else zz * zz)
        surf = math.sqrt(max(h2, 0.0))
        # front face (z > 0) proud of the surface, back face sunk into it
        off = surf + lift + (depth / 2 if front > 0 else -depth)
        v.co = (sphere_c[0] + x, sphere_c[1] - off, centre_z + zz)
    me.update()
    return star


def _export_glb(obj, path):
    """GLB of `obj` only, Y up, with the baked vertex colour attribute as COLOR_0."""
    ck._select_only([obj], obj)
    props = bpy.ops.export_scene.gltf.get_rna_type().properties.keys()
    kw = dict(filepath=path, export_format="GLB", use_selection=True, export_yup=True, export_apply=True)
    optional = {
        "export_normals": True,
        "export_texcoords": False,
        "export_materials": "EXPORT",
        "export_vertex_color": "ACTIVE",
        "export_all_vertex_colors": False,
        "export_active_vertex_color_when_no_material": True,
        "export_colors": True,
        "export_animations": False,
        "export_extras": False,
    }
    for k, v in optional.items():
        if k in props:
            kw[k] = v
    bpy.ops.export_scene.gltf(**kw)
    return path


def finish(parts, kind, render_kw=None):
    """Finishes `parts` into the game mesh <kind> and writes FBX, GLB, stats json, beauty + game renders."""
    lo, hi = ck.bounds(parts)
    offset = [round((lo.x + hi.x) / 2, 3), round(lo.z, 3), round((lo.y + hi.y) / 2, 3)]
    obj, tris = ck.finish_for_game(parts, kind, tri_budget=TRI_CAP - 100, tri_cap=TRI_CAP)
    ck.export_fbx(obj, os.path.join(OUT, kind + ".fbx"))
    _export_glb(obj, os.path.join(WEB, "props__" + kind + ".glb"))
    sx, sy, sz = obj["chad_size"]
    stats = {
        "kind": kind,
        "tris": tris,
        "size": [round(sx, 3), round(sz, 3), round(sy, 3)],
        "offset": offset,
        "axes": "Roblox studs: size = [X, Y up, Z]; offset = mesh base centre in the fallback prop frame",
    }
    with open(os.path.join(OUT, kind + ".json"), "w") as f:
        json.dump(stats, f, indent=1)
    rk = dict(render_kw or {})
    ck.render_prop(obj, os.path.join(OUT, kind + ".png"), **rk)
    ck.render_prop(obj, os.path.join(OUT, kind + "_game.png"), size=320, samples=32, game=True, **rk)
    if tris > TRI_TARGET:
        print("PROPS_GYM_WARN %s has %d triangles (target %d)" % (kind, tris, TRI_TARGET))
    print("PROPS_GYM_STATS", json.dumps(stats))
    return obj, tris


__all__ = ["ck", "bpy", "bmesh", "disc", "rod", "paint", "curved_star", "finish"]
