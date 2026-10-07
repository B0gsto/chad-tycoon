"""CARDIO letter keys ("+1 Speed Keyboard Escape" look): 26 small lettered keycaps, a spacebar and a blank key.

    tools/blender-run.sh art/blender/cardio/keys.py

Outputs:
  art/out/props/Key_A.fbx .. Key_Z.fbx, KeySpace.fbx, KeyBlank.fbx (+ .json stats)    props/Key_<L>, ...
  preview/web/models/props__Key_<L>.glb ...                                           preview meshes
  art/out/cardio/keys_sheet.png                                                       6x5 tinted patch, 3/4 view
  art/out/cardio/info.json                                                            "keys" entry (merged in)

Key pitch 4 studs: cap base 3.9 x 3.9 (spacebar 15.9 x 3.9 along X), 1.6 tall, top face ~3.3 wide, a small
chamfer, a shallow dish and a dark band at the foot (same style as props/Keycap). The letter is raised geometry
(0.06 proud of the dish) in Arial Black, ~2.2 studs tall; the spacebar carries a small "SPACE" legend.

Colours are greyscale on purpose (Roblox multiplies the baked vertex colours by MeshPart.Color): near-white top,
light grey skirt, dark band, near-black letter, so a pastel Color tints the key and the letter stays dark.

Letter orientation. Roblox imports these FBX files as roblox = (-bx, bz, by) (tools/blender/rbxkit.py). The letter
is modelled with its up along Blender -X and its right along Blender +Y, which is mesh +X (up) and mesh +Z (right)
in Roblox: with the MeshPart unrotated, a runner looking along +X reads every letter upright.
"""

import json
import math
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "props"))
sys.path.insert(0, os.path.join(HERE, "..", "icons"))

from _gym import OUT as PROPS_OUT, WEB, _export_glb, bmesh, bpy, ck  # noqa: E402
import _icons  # noqa: E402,F401  (fills the Theme palette the render rig uses)
from mathutils import Vector  # noqa: E402
from mathutils.bvhtree import BVHTree  # noqa: E402

OUT = os.path.join(ck.ROOT, "art", "out", "cardio")
os.makedirs(OUT, exist_ok=True)

FONT = "/System/Library/Fonts/Supplemental/Arial Black.ttf"
KEY = 3.9  # cap base (pitch 4 studs)
KEY_H = 1.6
DISH = 0.025
LETTER_H = 2.2  # cap height of the letter along its up axis
LETTER_W_MAX = 2.8  # widest letters (M, W) are squeezed to this
EMBOSS = 0.06  # letter top above the dish
SINK = 0.04  # letter foot below the dish (hidden)
TRI_CAP = 1500

TOP_RGB = (255, 254, 250)
SKIRT_RGB = (206, 202, 198)
BAND_RGB = (92, 88, 98)
INK_RGB = (30, 28, 36)


def _rrect(hx, hy, r, z, seg):
    r = max(0.02, min(r, hx - 1e-3, hy - 1e-3))
    pts = []
    corners = [(hx - r, hy - r, 0), (-hx + r, hy - r, 90), (-hx + r, -hy + r, 180), (hx - r, -hy + r, 270)]
    for cx, cy, a0 in corners:
        for k in range(seg + 1):
            a = math.radians(a0 + 90.0 * k / seg)
            pts.append((cx + r * math.cos(a), cy + r * math.sin(a), z))
    return pts


def small_keycap(width, depth, name, mats, seg=4):
    """Rings (inset from the footprint edge, z, corner radius, material of the faces up to the next ring)."""
    hx, hy, h = width / 2, depth / 2, KEY_H
    S, T, B = 0, 1, 2
    rings = [
        (0.04, 0.00, 0.48, B),
        (0.00, 0.05, 0.50, B),
        (0.005, 0.24, 0.50, S),  # top of the dark band
        (0.22, h - 0.18, 0.44, S),  # gently tapered skirt
        (0.25, h - 0.14, 0.42, S),
        (0.28, h - 0.03, 0.38, T),  # small chamfer
        (0.30, h, 0.37, T),  # top face edge: 3.3 on a 3.9 key
        (0.38, h, 0.33, T),  # flat rim, then the very slight dish
    ]
    dish_in = hy - 0.3
    for t in (0.33, 0.66, 1.0):
        inset = 0.38 + (dish_in - 0.38) * t
        rings.append((inset, h - DISH * math.sin(t * math.pi / 2), max(0.12, 0.31 * (1 - t) + 0.15 * t), T))
    bm = bmesh.new()
    vrings = [[bm.verts.new(p) for p in _rrect(hx - i, hy - i, r, z, seg)] for i, z, r, _m in rings]
    n = len(vrings[0])
    fm = []
    for i, (ra, rb) in enumerate(zip(vrings, vrings[1:])):
        for j in range(n):
            k = (j + 1) % n
            bm.faces.new((ra[j], ra[k], rb[k], rb[j]))
            fm.append(rings[i][3])
    for ring, z, down in ((vrings[0], 0.0, True), (vrings[-1], h - DISH, False)):
        c = bm.verts.new((0, 0, z))
        for j in range(n):
            k = (j + 1) % n
            bm.faces.new((ring[k], ring[j], c) if down else (ring[j], ring[k], c))
            fm.append(B if down else T)
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces[:])
    for f, m in zip(bm.faces, fm):
        f.material_index = m
    ob = ck.mesh_object(name, bm, mats[0], smooth=False)
    ob.data.materials.append(mats[1])
    ob.data.materials.append(mats[2])
    ck.shade_smooth(ob, 40.0)
    return ob


def letter(ch, cap, mat, height=LETTER_H, wmax=LETTER_W_MAX):
    """Raised legend on the cap's dish: flat Arial Black outline, up = Blender -X, right = Blender +Y."""
    cu = bpy.data.curves.new("L_" + ch, "FONT")
    cu.body = ch
    cu.font = bpy.data.fonts.load(FONT, check_existing=True)
    cu.size = 1.0
    cu.extrude = 0.05
    cu.bevel_depth = 0.0
    cu.resolution_u = 3
    cu.align_x = "CENTER"
    cu.align_y = "CENTER"
    tmp = bpy.data.objects.new("tmp_" + ch, cu)
    bpy.context.scene.collection.objects.link(tmp)
    dg = bpy.context.evaluated_depsgraph_get()
    me = bpy.data.meshes.new_from_object(tmp.evaluated_get(dg), depsgraph=dg)
    bpy.data.objects.remove(tmp, do_unlink=True)

    bm = bmesh.new()
    bm.from_mesh(me)
    bpy.data.meshes.remove(me)
    bmesh.ops.remove_doubles(bm, verts=bm.verts[:], dist=1e-4)
    bm.normal_update()
    bmesh.ops.delete(bm, geom=[f for f in bm.faces if f.normal.z < -0.5], context="FACES_ONLY")
    xs = [v.co.x for v in bm.verts]
    ys = [v.co.y for v in bm.verts]
    cx, cy = (min(xs) + max(xs)) / 2, (min(ys) + max(ys)) / 2
    w, hgt = max(xs) - min(xs), max(ys) - min(ys)
    s = min(height / hgt, wmax / w)
    capmesh = cap.data
    bvh = BVHTree.FromPolygons([v.co for v in capmesh.vertices], [p.vertices for p in capmesh.polygons])
    for v in bm.verts:
        top = v.co.z > 0
        lx, ly = (v.co.x - cx) * s, (v.co.y - cy) * s  # letter right, letter up
        bx, by = -ly, lx  # +90 deg about Z: up -> -X, right -> +Y
        hit = bvh.ray_cast(Vector((bx, by, KEY_H + 1.0)), Vector((0, 0, -1)), 5.0)
        zs = hit[0].z if hit[0] is not None else KEY_H - DISH
        v.co = (bx, by, zs + (EMBOSS if top else -SINK))
    ob = ck.mesh_object("Letter_" + ch, bm, mat, smooth=False)
    ck.shade_smooth(ob, 30.0)
    return ob


def ship(parts, kind):
    obj, tris = ck.finish_for_game(parts, kind, tri_budget=TRI_CAP, tri_cap=TRI_CAP, smooth_angle=35.0)
    ck.export_fbx(obj, os.path.join(PROPS_OUT, kind + ".fbx"))
    _export_glb(obj, os.path.join(WEB, "props__" + kind + ".glb"))
    sx, sy, sz = obj["chad_size"]
    stats = {"kind": kind, "tris": tris, "size": [round(sx, 3), round(sz, 3), round(sy, 3)],
             "axes": "Roblox studs: size = [X, Y up, Z]; letter up = mesh +X, letter right = mesh +Z"}
    with open(os.path.join(PROPS_OUT, kind + ".json"), "w") as f:
        json.dump(stats, f, indent=1)
    print("KEYS_STATS", json.dumps(stats))
    obj.hide_render = True
    obj.hide_set(True)
    return obj, stats


def tint_material(name, rgb):
    mat = bpy.data.materials.new(name)
    nt, p = ck._principled(mat)
    attr = nt.nodes.new("ShaderNodeVertexColor")
    attr.layer_name = "Col"
    mix = nt.nodes.new("ShaderNodeMix")
    mix.data_type = "RGBA"
    mix.blend_type = "MULTIPLY"
    mix.inputs["Factor"].default_value = 1.0
    mix.inputs[6].default_value = (*ck.lin(rgb), 1.0)
    nt.links.new(attr.outputs["Color"], mix.inputs[7])
    nt.links.new(mix.outputs[2], p.inputs["Base Color"])
    p.inputs["Roughness"].default_value = 0.8  # Roblox SmoothPlastic look
    p.inputs["Coat Weight"].default_value = 0.0
    p.inputs["Specular IOR Level"].default_value = 0.2
    return mat


PASTELS = [(255, 179, 214), (214, 170, 255), (226, 208, 255), (255, 204, 232), (196, 168, 250), (240, 186, 245)]
CHOC = (92, 56, 38)


def sheet(objs):
    """6 columns along the run (Blender -X = Roblox +X) x 5 rows, pitch 4; the spacebar spans 4 columns of row 2."""
    placed = []

    def place(src, x, y, i):
        ob = src.copy()
        ob.data = src.data.copy()
        ob.location = (x, y, 0.0)
        bpy.context.scene.collection.objects.link(ob)
        ob.hide_render = False
        ob.hide_set(False)
        ob.data.materials.clear()
        ob.data.materials.append(tint_material("KTint%d" % i, PASTELS[(i * 7 + i // 6) % len(PASTELS)]))
        placed.append(ob)

    letters = [chr(ord("A") + i) for i in range(26)]
    li = 0
    for row in range(5):
        y = (row - 2) * 4.0
        col = 0
        while col < 6:
            x = -(col - 2.5) * 4.0  # column 0 nearest the camera (+X), reading order runs toward -X
            if row == 2 and col == 1:
                place(objs["KeySpace"], 0.0, y, 99)  # columns 1..4 centre on x = 0
                col += 4
                continue
            place(objs["Key_" + letters[li]], x, y, li)
            li += 1
            col += 1
    # Chocolate base slab under the patch.
    slab_m = ck.matte_material("Choc", CHOC, roughness=0.8)
    slab = ck.rounded_box((6 * 4.0 + 1.2, 5 * 4.0 + 1.2, 0.4), 0.1, 1, slab_m, "Slab", (0, 0, -0.2))
    placed.append(slab)
    ground = ck.matte_material("ChadRig_Sand", tuple(c * 0.8 for c in CHOC), roughness=0.9)  # render_prop reuses it
    path = os.path.join(OUT, "keys_sheet.png")
    ck.render_prop(placed, path, size=(1400, 1000), azimuth=72.0, elevation=38.0, pad=0.04, samples=64)
    return path


def main():
    top = ck.toy_material("KTop", TOP_RGB)
    skirt = ck.toy_material("KSkirt", SKIRT_RGB)
    band = ck.toy_material("KBand", BAND_RGB)
    ink = ck.toy_material("KInk", INK_RGB, roughness=0.5)
    mats = (skirt, top, band)
    objs, info = {}, {}
    for i in range(26):
        ch = chr(ord("A") + i)
        cap = small_keycap(KEY, KEY, "Cap_" + ch, mats)
        let = letter(ch, cap, ink)
        kind = "Key_" + ch
        objs[kind], st = ship([cap, let], kind)
        info["props/" + kind] = {"size": st["size"], "tris": st["tris"]}
    for kind, w in (("KeySpace", 15.9), ("KeyBlank", KEY)):
        cap = small_keycap(w, KEY, "Cap_" + kind, mats)
        parts = [cap]
        if kind == "KeySpace":
            parts.append(letter("SPACE", cap, ink, height=0.62, wmax=2.9))
        objs[kind], st = ship(parts, kind)
        info["props/" + kind] = {"size": st["size"], "tris": st["tris"]}
    path = sheet(objs)

    ipath = os.path.join(OUT, "info.json")
    full = json.load(open(ipath)) if os.path.exists(ipath) else {}
    full["keys"] = {
        "script": "art/blender/cardio/keys.py",
        "pitch": 4.0,
        "letter": "raised 0.06 above the dish, Arial Black, ~2.2 studs tall (KeySpace: small SPACE legend, same orientation); baked near-black, cap near-white "
                  "(tint with MeshPart.Color, Material SmoothPlastic)",
        "orientation": "unrotated MeshPart: letter up = mesh +X, letter right = mesh +Z, read from above; a runner "
                       "looking along +X reads letters upright (Blender: up = -X, right = +Y; roblox = (-bx, bz, by))",
        "sheet": os.path.relpath(path, ck.ROOT),
        "meshes": info,
    }
    with open(ipath, "w") as f:
        json.dump(full, f, indent=1)
    print("KEYS_INFO", json.dumps(info))


main()
