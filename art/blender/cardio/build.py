"""CARDIO art (docs/cardio.md): keycap meshes, the arcade treadmill, the Cardio UI icon and a group shot.

    tools/blender-run.sh art/blender/cardio/build.py
    python3 art/blender/cardio/make_sheet.py        # contact sheet (system python3 + Pillow)

Modelling space is the props one (art/blender/props/_gym.py): 1 Blender unit = 1 stud, Blender X = Roblox X,
Blender Y = Roblox Z, Blender Z = up. The front (Roblox -Z) is Blender -Y. Every mesh ships with its origin at the
base centre of its bounding box (finish_for_game), so in Roblox the MeshPart's bottom face is the floor.

Outputs:
  art/out/props/Keycap.fbx / .json / .png / _game.png       8 x 2.5 x 8 studs key (props/Keycap)
  art/out/props/KeycapWide.fbx / ...                         24 x 2.5 x 8 studs spacebar (props/KeycapWide)
  art/out/props/CardioTreadmill.fbx / ...                    6 x ~6.2 x 12 studs arcade treadmill (props/CardioTreadmill)
  art/out/cardio/Cardio.png                                  512 px RGBA UI icon (cardio/Cardio)
  art/out/cardio/group.png                                   3/4 group shot (keys tinted per stage)
  art/out/cardio/info.json                                   measured sizes, belt rectangle, conventions
  preview/web/models/props__<Kind>.glb                       preview meshes

Keycaps are greyscale on purpose: Roblox multiplies baked vertex colours by MeshPart.Color, so the game recolours
keys per stage by setting Color. The top face is near white (shows the stage colour as is) and the skirt is about
80% grey (the same colour, one shade darker). Keep MeshPart.Color = the stage colour and Material = SmoothPlastic.
"""

import json
import math
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "props"))
sys.path.insert(0, os.path.join(HERE, "..", "icons"))

from _gym import bmesh, bpy, ck, finish, rod  # noqa: E402
import _icons  # noqa: E402,F401  (fills the Theme palette: Blue, Pool, ...)

OUT = os.path.join(ck.ROOT, "art", "out", "cardio")
os.makedirs(OUT, exist_ok=True)

KEY_H = 2.5
TOP_RGB = (255, 254, 250)  # near white, a breath of cream
SKIRT_RGB = (206, 202, 198)  # ~80% grey: the skirt reads one shade darker than the top under any tint
BAND_RGB = (92, 88, 98)  # ~36% grey: the dark band at the foot of the skirt


# ------------------------------------------------------------------------------------------------
# Keycap
# ------------------------------------------------------------------------------------------------

def _rrect(hx, hy, r, z, seg):
    """Rounded rectangle ring (CCW from +X+Y corner), half sizes hx, hy, corner radius r, at height z."""
    r = max(0.02, min(r, hx - 1e-3, hy - 1e-3))
    pts = []
    corners = [(hx - r, hy - r, 0), (-hx + r, hy - r, 90), (-hx + r, -hy + r, 180), (hx - r, -hy + r, 270)]
    for cx, cy, a0 in corners:
        for k in range(seg + 1):
            a = math.radians(a0 + 90.0 * k / seg)
            pts.append((cx + r * math.cos(a), cy + r * math.sin(a), z))
    return pts


def keycap(width, depth, name, top_mat, skirt_mat, band_mat, dish=0.25, seg=5, height=KEY_H):
    """Chunky keycap: a dark band at the foot, a skirt tapering in to a 0.4 stud chamfer, a top face 80% of the base
    width (8 -> 6.4) with a thin flat rim and a concave dish `dish` deep. Rings are (inset from the footprint edge,
    z, corner radius, material of the faces from this ring to the next: 0 skirt, 1 top, 2 band)."""
    hx, hy = width / 2, depth / 2
    h = height
    S, T, B = 0, 1, 2
    rings = [
        (0.08, 0.00, 1.00, B),  # foot, tucked in a touch
        (0.00, 0.10, 1.05, B),
        (0.01, 0.42, 1.05, S),  # top of the dark band
        (0.36, h - 0.44, 0.95, S),  # top of the tapered skirt (half 3.64)
        (0.42, h - 0.38, 0.93, S),
        (0.74, h - 0.05, 0.80, T),  # end of the 0.4 chamfer
        (0.80, h, 0.78, T),  # top face edge: 6.4 wide on an 8 key
        (1.10, h, 0.68, T),  # flat rim, then the dish
    ]
    dish_in = hy - 0.45
    for t in (0.25, 0.5, 0.75, 1.0):
        inset = 1.10 + (dish_in - 1.10) * t
        rings.append((inset, h - dish * 0.97 * math.sin(t * math.pi / 2), max(0.25, 0.68 * (1 - t) + 0.3 * t), T))
    bm = bmesh.new()
    vrings = []
    for inset, z, r, _m in rings:
        vrings.append([bm.verts.new(p) for p in _rrect(hx - inset, hy - inset, r, z, seg)])
    n = len(vrings[0])
    mats = []
    for i, (ra, rb) in enumerate(zip(vrings, vrings[1:])):
        for j in range(n):
            k = (j + 1) % n
            bm.faces.new((ra[j], ra[k], rb[k], rb[j]))
            mats.append(rings[i][3])
    # Bottom cap (faces down) and dish centre cap, both fans around a centre vertex for clean triangles.
    for ring, z, down in ((vrings[0], 0.0, True), (vrings[-1], h - dish, False)):
        c = bm.verts.new((0, 0, z))
        for j in range(n):
            k = (j + 1) % n
            bm.faces.new((ring[k], ring[j], c) if down else (ring[j], ring[k], c))
            mats.append(B if down else T)
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces[:])
    for f, m in zip(bm.faces, mats):
        f.material_index = m
    ob = ck.mesh_object(name, bm, skirt_mat, smooth=False)
    ob.data.materials.append(top_mat)
    ob.data.materials.append(band_mat)
    ck.shade_smooth(ob, 40.0)
    return ob


def build_keycap(kind, width, dish):
    top = ck.toy_material(kind + "Top", TOP_RGB)
    skirt = ck.toy_material(kind + "Skirt", SKIRT_RGB)
    band = ck.toy_material(kind + "Band", BAND_RGB)
    ob = keycap(width, 8.0, kind, top, skirt, band, dish=dish)
    obj, tris = finish([ob], kind, {"azimuth": 32.0, "elevation": 24.0})
    return obj, tris


# ------------------------------------------------------------------------------------------------
# Arcade treadmill (runner faces -Z in Roblox = Blender -Y; console at the front)
# ------------------------------------------------------------------------------------------------

BELT_TOP = 1.2  # belt top surface height above the mesh base (studs)
BELT_X = 2.15  # belt half width
BELT_Y0, BELT_Y1 = -3.2, 5.4  # belt extent along Blender Y (front .. back) before recentring
CHEVRON_H = 0.035  # the belt chevrons stand this far above the belt top


def bolt_outline(scale=1.0):
    from _icons import rounded_poly

    pts = [(-0.4, -1.32), (0.98, 0.34), (0.3, 0.34), (0.74, 1.26), (-0.36, 1.26), (-0.84, -0.2), (-0.1, -0.2)]
    pts = [(x * 0.86 * scale + 0.03 * scale, z * 0.86 * scale) for x, z in pts]
    return rounded_poly(pts, 0.16 * scale, 0.08 * scale, 4)


def build_treadmill():
    kind = "CardioTreadmill"
    pink = ck.toy_material("CT_Skirt", "HotPink")
    white = ck.toy_material("CT_White", "White")
    belt = ck.toy_material("CT_Belt", (52, 40, 112))  # deep navy-purple
    stripe = ck.toy_material("CT_Chevron", ck.mix("CyanPop", "White", 0.55))
    sunny = ck.toy_material("CT_Sunny", "Sunny")
    mint = ck.toy_material("CT_Mint", "Mint")
    sky = ck.toy_material("CT_Sky", "Sky")
    screen = ck.toy_material("CT_Screen", ck.mix("Cream", "White", 0.6))
    grape = ck.toy_material("CT_Grape", ck.mix(ck.DARK, "Grape", 0.3))

    belt_len = BELT_Y1 - BELT_Y0
    parts = [
        # Deck: a fat hot-pink body, white step rails each side of the navy belt.
        ck.rounded_box((5.4, 10.6, 1.0), 0.38, 2, pink, "Deck", (0, 0.65, 0)),
        ck.rounded_box((2 * BELT_X, belt_len, 0.3), 0.08, 1, belt, "Belt", (0, (BELT_Y0 + BELT_Y1) / 2, BELT_TOP - 0.3)),
        ck.rounded_box((0.8, 10.0, 0.4), 0.16, 2, white, "StepRail", (-2.6, 0.75, 0.98)),
        ck.rounded_box((0.8, 10.0, 0.4), 0.16, 2, white, "StepRail", (2.6, 0.75, 0.98)),
        # Sunny racing stripe along each side of the skirt.
        ck.rounded_box((0.16, 8.6, 0.28), 0.07, 1, sunny, "Stripe", (-2.68, 0.75, 0.38)),
        ck.rounded_box((0.16, 8.6, 0.28), 0.07, 1, sunny, "Stripe", (2.68, 0.75, 0.38)),
        # Small rear roller cap and a slimmer front motor hood: the console end stays the big one.
        ck.capsule(0.32, 5.4, 10, 2, white, "Roller", (0, 5.63, 0.72), axis="X"),
        ck.capsule(0.72, 5.2, 12, 3, sunny, "Hood", (0, -4.0, 0.85), axis="X"),
    ]
    # Light chevrons on the belt, pointing to the front (-Y), raised CHEVRON_H above the belt top.
    from _icons import ccw

    chev = ccw([(0, -0.8), (1.85, 0.35), (1.85, 1.15), (0, 0.0), (-1.85, 1.15), (-1.85, 0.35)])
    y = BELT_Y0 + 1.2
    while y < BELT_Y1 - 1.0:
        c = ck.extrude_shape(chev, depth=0.06, mat=stripe, name="Chevron", bevel=0.0)
        c.location = (0, y, BELT_TOP + CHEVRON_H - 0.03)
        parts.append(c)
        y += 2.0
    # Grape feet under the four corners.
    for sx in (-1, 1):
        for y in (-4.3, 5.3):
            parts.append(ck.rounded_box((0.9, 0.9, 0.3), 0.14, 1, grape, "Foot", (sx * 2.2, y, -0.2)))
    RX, PY, R = 2.55, -4.75, 0.54
    for side in (-1, 1):
        x = side * RX
        # One fat bent rail per side: up the front post, then back toward the runner.
        pts = [(x, PY, 0.9), (x, PY, 3.9)]
        for k in range(1, 5):
            a = math.radians(90 * k / 4)
            pts.append((x, PY + 0.6 * (1 - math.cos(a)), 3.9 + 0.6 * math.sin(a)))
        pts.append((x, -1.3, 4.5))
        parts.append(ck.sweep(pts, [R] * len(pts), 12, white, "Rail", up=(1, 0, 0), smooth_angle=80))
        parts.append(ck.sphere(R, 12, 6, white, "RailEnd", (x, -1.3, 4.5)))
    parts.append(rod((-RX, PY, 3.5), (RX, PY, 3.5), R, 12, white, "CrossBar"))

    # Console: a flat sky-blue display slab on its own white neck above the cross bar, between the handrail posts,
    # tilted 40 degrees toward the runner (+Y). A bright cream-white screen with a sunny bolt fills its upper face
    # and three chunky candy buttons sit in a row below it.
    parts.append(rod((0, PY, 3.5), (0, -4.45, 4.05), 0.32, 10, white, "Neck"))
    con = [
        ck.rounded_box((3.8, 0.5, 2.5), 0.16, 2, sky, "Panel", (0, 0, -1.25)),
        ck.rounded_box((3.3, 0.12, 1.45), 0.08, 1, screen, "Screen", (0, 0.27, -0.2)),
    ]
    bolt = ck.extrude_shape(bolt_outline(0.5), depth=0.12, mat=sunny, name="ScreenBolt", bevel=0.03,
                            bevel_segments=1)
    bolt.rotation_euler = (math.radians(90), 0, math.radians(180))
    bolt.location = (0, 0.36, 0.52)
    con.append(bolt)
    for bx, m in ((-1.1, ck.toy_material("CT_Btn1", "HotPink")), (0.0, mint), (1.1, sunny)):
        con.append(ck.rounded_box((0.8, 0.34, 0.5), 0.12, 1, m, "Button", (bx, 0.2, -1.05)))
    ck.group(con, "ConsolePivot", location=(0, -4.95, 4.95), rotation=(40, 0, 0))
    bpy.context.view_layer.update()
    ck.apply_transforms(con)
    parts += con

    lo, hi = ck.bounds(parts)
    cx, cy = (lo.x + hi.x) / 2, (lo.y + hi.y) / 2
    obj, tris = finish(parts, kind, {"azimuth": 30.0, "elevation": 38.0})
    # Belt rectangle in the shipped mesh frame (origin = base centre), Roblox axes (z = Blender y).
    belt_info = {
        "topY": round(BELT_TOP - lo.z, 3),
        "chevronTopY": round(BELT_TOP + CHEVRON_H - lo.z, 3),
        "x": [round(-BELT_X - cx, 3), round(BELT_X - cx, 3)],
        "z": [round(BELT_Y0 - cy, 3), round(BELT_Y1 - cy, 3)],
    }
    return obj, tris, belt_info


# ------------------------------------------------------------------------------------------------
# Icon and group shot
# ------------------------------------------------------------------------------------------------

def build_icon():
    """Cardio icon: a mint keycap (dark green sides) with a huge sunny lightning bolt standing on it."""
    import _icons  # noqa: F401  (theme palette fill)

    top = ck.toy_material("IconTop", ck.mix("Mint", "White", 0.2))
    skirt = ck.toy_material("IconSkirt", ck.mix("Emerald", ck.DARK, 0.25))
    band = ck.toy_material("IconBand", ck.mix("Emerald", ck.DARK, 0.6))
    cap = keycap(8.0, 8.0, "IconKey", top, skirt, band, dish=0.25, seg=8)
    bolt_m = ck.toy_material("IconBolt", "Sunny")
    # Huge fat bolt standing upright on the key, facing the camera (-Y).
    sc = 4.4
    bolt = ck.extrude_shape(bolt_outline(sc), depth=1.6, mat=bolt_m, name="IconBolt", bevel=0.34, bevel_segments=3)
    bolt.rotation_euler = (math.radians(90), 0, 0)
    bolt.location = (0, 0, KEY_H - 0.4 + 1.32 * 0.86 * sc)
    # Plain render here; icon_post.py (system python3) adds the dark ink outline, the white sticker and the shadow.
    path = os.path.join(OUT, "Cardio_raw.png")
    ck.render_icon([cap, bolt], path, size=512, azimuth=-24.0, elevation=24.0, keep_raw=False, outline=0.0,
                   shadow=False, pad=0.16, fill=None)
    return path


def tint_material(name, rgb):
    """Baked vertex colour x `rgb`, like Roblox multiplies vertex colours by MeshPart.Color."""
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
    p.inputs["Roughness"].default_value = 0.4
    p.inputs["Coat Weight"].default_value = 0.5
    return mat


def group_shot(key, wide, tread):
    """Keys tinted in four stage colours with the treadmill standing on a spacebar, 3/4 view."""
    objs = []

    def place(src, loc, rgb=None):
        ob = src.copy()
        ob.data = src.data.copy() if rgb else src.data
        ob.location = loc
        bpy.context.scene.collection.objects.link(ob)
        ob.hide_render = False
        ob.hide_set(False)
        if rgb:
            ob.data.materials.clear()
            ob.data.materials.append(tint_material("Tint%d" % len(objs), rgb))
        objs.append(ob)
        return ob

    colours = ["Mint", "Sky", "Pink", "Sunny", "Grape", "Coral"]
    i = 0
    for gx in range(3):
        for gy in range(2):
            place(key, (gx * 8.6 - 8.6, gy * 8.6 + 1.0, 0), ck.srgb(colours[i % len(colours)]))
            i += 1
    place(wide, (0, -8.0, 0), ck.srgb("Cream"))
    place(tread, (17.5, -4.0, 0))
    path = os.path.join(OUT, "group.png")
    ck.render_prop(objs, path, size=(1200, 800), azimuth=30.0, elevation=34.0, pad=0.08)
    return path


def main():
    key, key_tris = build_keycap("Keycap", 8.0, 0.25)
    key.hide_render = True
    wide, wide_tris = build_keycap("KeycapWide", 24.0, 0.12)
    wide.hide_render = True
    tread, tread_tris, belt = build_treadmill()
    tread.hide_render = True
    for ob in (key, wide, tread):
        ob.hide_set(True)
    icon = build_icon()
    group = group_shot(key, wide, tread)

    def size(ob):
        sx, sy, sz = ob["chad_size"]
        return [round(sx, 3), round(sz, 3), round(sy, 3)]

    info = {
        "axes": "Roblox studs, size = [X, Y up, Z]; mesh origin = base centre; front = -Z (Blender -Y)",
        "props/Keycap": {"size": size(key), "tris": key_tris},
        "props/KeycapWide": {"size": size(wide), "tris": wide_tris},
        "props/CardioTreadmill": {"size": size(tread), "tris": tread_tris, "belt": belt,
                                  "note": "runner faces -Z; console + handrails at the -Z end"},
        "cardio/Cardio": {"file": "art/out/cardio/Cardio.png", "px": 512, "post": "art/blender/cardio/icon_post.py"},
        "group": os.path.relpath(group, ck.ROOT),
    }
    with open(os.path.join(OUT, "info.json"), "w") as f:
        json.dump(info, f, indent=1)
    print("CARDIO_INFO", json.dumps(info))


main()
