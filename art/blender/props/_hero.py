"""Shared setup for the hero props (props-hero): GigaStatue, TrophyPodium, Converter, Vault,
CrateCracker, Crate. Puts art/blender/lib on sys.path, defines output paths and ship(), which
finishes a built prop for the game and writes every deliverable:

  art/out/props/<Kind>.fbx              Roblox mesh (Y up, front = Roblox -Z = Blender -Y, 1 unit = 1 stud)
  art/out/props/<Kind>.json             {"tris", "size": [x, y, z] studs in Roblox axes (y = height)}
  art/out/props/<Kind>.png              beauty shot
  art/out/props/<Kind>_game.png         honest in-game look (baked vertex colours, SmoothPlastic-like)
  preview/web/models/props__<Kind>.glb  web preview mesh with vertex colours (glTF Y up)
"""

import json
import math
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "lib"))

import bpy  # noqa: E402
from mathutils import Vector  # noqa: E402
import chadkit as ck  # noqa: E402

OUT = os.path.join(ck.ROOT, "art", "out", "props")
WEB = os.path.join(ck.ROOT, "preview", "web", "models")
for d in (OUT, WEB):
    os.makedirs(d, exist_ok=True)

TRI_CAP = 2500


def place(ob, location=(0, 0, 0), rotation=(0, 0, 0), scale=(1, 1, 1)):
    """Sets an object's location, rotation (degrees) and scale; returns it."""
    ob.location = location
    ob.rotation_euler = tuple(math.radians(a) for a in rotation)
    ob.scale = scale
    return ob


def disc(radius, z0, z1, bevel, mat, name, segments=24, steps=2, location=(0, 0, 0), r0=0.0):
    """Solid round tier (cylinder from z0 to z1) with big round edges."""
    return ck.lathe(ck.round_profile(r0, radius, z0, z1, bevel, steps), segments, mat, name, location,
                    smooth_angle=60)


def dome(radius, height, mat, name, segments=16, steps=3, base=0.0):
    """Button / cap: a short cylinder of `base` height topped by a rounded dome, base at z = 0."""
    pts = [(0, 0), (radius, 0)]
    if base > 0:
        pts.append((radius, base))
    for k in range(1, steps + 1):
        a = (math.pi / 2) * k / steps
        pts.append((max(radius * math.cos(a), 0.0), base + (height - base) * math.sin(a)))
    return ck.lathe(pts, segments, mat, name, smooth_angle=70)


def ball(radius, mat, name, location, scale=(1, 1, 1), segments=12, rings=7):
    return place(ck.sphere(radius, segments, rings, mat, name), location, (0, 0, 0), scale)


def export_glb(obj, path):
    """GLB of `obj` alone with its vertex colours (COLOR_0), Y up."""
    ck._select_only([obj], obj)
    kw = dict(filepath=path, export_format="GLB", use_selection=True, export_yup=True, export_apply=True,
              export_materials="EXPORT", export_animations=False, export_normals=True)
    for extra in ({"export_vertex_color": "ACTIVE", "export_all_vertex_colors": False},
                  {"export_vertex_color": "ACTIVE"}, {"export_colors": True}, {}):
        try:
            bpy.ops.export_scene.gltf(**kw, **extra)
            return path
        except TypeError:
            continue
    raise RuntimeError("glTF export failed")


def ship(parts, kind, tri_budget=1000, renders=True, finish=None, post=None, **render_kw):
    """Finishes `parts` into the game mesh `kind` and writes all deliverables (see module doc).
    `finish` = extra finish_for_game kwargs; `post(obj)` runs on the finished mesh before export."""
    raw = sum(ck.triangle_count(o) for o in ck._as_objects(parts))
    obj, tris = ck.finish_for_game(parts, kind, tri_budget=tri_budget, tri_cap=TRI_CAP, **(finish or {}))
    if post:
        post(obj)
    ck.export_fbx(obj, os.path.join(OUT, kind + ".fbx"))
    export_glb(obj, os.path.join(WEB, "props__%s.glb" % kind))
    sx, sy, sz = (round(v, 2) for v in obj["chad_size"])
    stats = {"kind": kind, "tris": tris, "size": [sx, sz, sy], "axes": "roblox x, y (height), z (depth)"}
    with open(os.path.join(OUT, kind + ".json"), "w") as f:
        json.dump(stats, f, indent=1)
    if renders and not os.environ.get("HERO_NORENDER"):
        ck.render_prop(obj, os.path.join(OUT, kind + ".png"), **render_kw)
        ck.render_prop(obj, os.path.join(OUT, kind + "_game.png"), size=320, samples=32, game=True, **render_kw)
    print("CHADKIT_STATS", json.dumps(stats), "source tris", raw)
    return obj, tris


def highlight_material(name="HeroHighlight", color=None):
    """Crisp toy specular band: a pale warm white that also bakes as a light stripe in-game."""
    return ck.toy_material(name, color or ck.mix("Sunny", "White", 0.82), roughness=0.2, coat=0.0, emission=0.5,
                           rim=0.0)


def ell_pt(centre, radii, az, el, lift=0.0):
    """Point on an ellipsoid (centre, radii) at azimuth `az` (deg, 0 = front -Y, + toward +X) and
    elevation `el` (deg), pushed `lift` (fraction) outward; returns (point, outward normal)."""
    a, e = math.radians(az), math.radians(el)
    u = Vector((math.cos(e) * math.sin(a), -math.cos(e) * math.cos(a), math.sin(e)))
    c, r = Vector(centre), Vector(radii)
    p = c + Vector((r.x * u.x, r.y * u.y, r.z * u.z)) * (1.0 + lift)
    n = Vector((u.x / r.x, u.y / r.y, u.z / r.z)).normalized()
    return p, n


def band(centre, radii, az0, az1, el, width, mat, name="Highlight", n=4, lift=0.04, sides=6):
    """One crisp highlight band lying on an ellipsoid, sweeping azimuth az0..az1 at elevation el."""
    pts, nrm = [], Vector((0, 0, 0))
    for i in range(n):
        p, nn = ell_pt(centre, radii, az0 + (az1 - az0) * i / (n - 1), el, lift)
        pts.append(p)
        nrm += nn
    return ck.gloss_streak(pts, width, nrm.normalized(), mat=mat, name=name, flatten=0.22, sides=sides)


def wrap_cylinder(ob, radius):
    """Bends an object built flat against the plane y = -radius (front facing -Y) round the
    Z axis so it hugs a cylinder wall of that radius (plaques on round tiers)."""
    ck.apply_transforms([ob])
    import bmesh
    bm = bmesh.new()
    bm.from_mesh(ob.data)
    xs = [v.co.x for v in bm.verts]
    lo, hi = min(xs), max(xs)
    cuts = max(2, int((hi - lo) / 0.6))
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


def toy_light(obj, top, top_amount=0.3, warm=None, warm_amount=0.35):
    """Paints a toy key light into the baked vertex colours: faces that look up blend toward `top`
    (lighter), faces that look down / away get a warm, softer shade instead of a dull dark one."""
    me = obj.data
    col = me.color_attributes.get("Col")
    if col is None:
        return obj
    top = ck.lin(top) if isinstance(top, str) else tuple(top)
    warm = (ck.lin(warm) if isinstance(warm, str) else tuple(warm)) if warm else None
    vals = [0.0] * (len(me.loops) * 4)
    col.data.foreach_get("color", vals)
    key = Vector((-0.35, -0.45, 0.82)).normalized()
    for p in me.polygons:
        for li in p.loop_indices:
            n = me.vertices[me.loops[li].vertex_index].normal
            up = max(0.0, n.dot(key))
            k = top_amount * (up ** 1.5)
            for i in range(3):
                c = vals[li * 4 + i]
                c = c + (top[i] - c) * k
                if warm and up < 0.25:
                    w = warm_amount * (1.0 - up / 0.25)
                    c = c + (warm[i] * 0.75 - c) * w * (1.0 if c < warm[i] * 0.75 else 0.0)
                vals[li * 4 + i] = c
    col.data.foreach_set("color", vals)
    me.update()
    return obj
