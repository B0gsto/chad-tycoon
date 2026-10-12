"""Branding art for Chad Aura Tycoon, rendered at 2x into art/out/brand/raw/ (art/blender/brand/finish.py
adds the outline / shadow and writes the shipped files into art/out/brand/).

Run:  tools/blender-run.sh art/blender/brand/brand.py [-- Logo TitleCard KeyArt]

Logo       "CHAD AURA TYCOON": fat bevelled Arial Rounded MT Bold letters with deep drop extrusions, one
           flat colour per word (orange CHAD, purple AURA with a sparkle, bigger sunny TYCOON), one
           gloss streak per letter, gently arched and tilted, candy dumbbell centred above.
TitleCard  rounded royal-blue plaque with a raised gold rim and corner rivets, empty centre for text;
           the vinyl panel has a soft inner shadow under the top rim and a diagonal gloss stripe.
KeyArt     loading-screen background: sunny beach gym (sand, sea, sky, puffy clouds, palms) with a
           flexing Chad on a posing stage, two cheering fans with heart signs, big candy dumbbells and
           a few aura orbs, all in focus; the top third is clear sky for the logo, the hero group sits
           in the middle and the bottom fifth is plain sand for the loading bar.
"""

import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "vfx"))
import spritekit as sk  # noqa: E402
from spritekit import ck  # noqa: E402
import theme_palette  # noqa: E402

theme_palette.fill(ck)  # Theme.World keys written as Luau constants (Sunny, Coral, White, ...)

import bmesh  # noqa: E402
import bpy  # noqa: E402
from bpy_extras.object_utils import world_to_camera_view  # noqa: E402
from mathutils import Matrix, Vector  # noqa: E402


def raw(name):
    return os.path.join(sk.RAW_BRAND, name + ".png")


# ------------------------------------------------------------------------------------------------
# Logo
# ------------------------------------------------------------------------------------------------

EXT, BEV, OFF = 0.16, 0.065, -0.03  # per unit of text size: extrude (half depth), deep front bevel, outline offset (keeps counters open)
SHEAR_Y, SHEAR_X = 0.3, -0.08  # drop extrusion: the back of the letters slides down and right
SPACE = 1.26  # letter spacing (room for the bevelled glyphs)


def dark(color, t):
    """`color` (palette name or linear tuple) scaled toward black in linear light (t < 1)."""
    return tuple(v * t for v in ck._as_linear(color))


def glyphs(body, size, front, side):
    """Fat bevelled word in XY (front +Z), one object per letter, with a drop extrusion (sheared
    back). Letters are split using per-character material indices on the text curve."""
    cu = bpy.data.curves.new(body, "FONT")
    cu.body = body
    cu.font = bpy.data.fonts.load(sk.FONT, check_existing=True)
    cu.size = size
    cu.extrude = EXT * size
    cu.bevel_depth = BEV * size
    cu.bevel_resolution = 5
    cu.offset = OFF * size
    cu.resolution_u = 12
    cu.space_character = SPACE
    for k in range(len(body)):
        cu.materials.append(bpy.data.materials.get("Idx%d" % k) or bpy.data.materials.new("Idx%d" % k))
        cu.body_format[k].material_index = k
    tmp = ck._link(bpy.data.objects.new(body + "_curve", cu))
    dg = bpy.context.evaluated_depsgraph_get()
    me = bpy.data.meshes.new_from_object(tmp.evaluated_get(dg), depsgraph=dg)
    bpy.data.objects.remove(tmp, do_unlink=True)
    zmax = max(v.co.z for v in me.vertices)
    letters = []
    for k, ch in enumerate(body):
        if ch == " ":
            continue
        bm = bmesh.new()
        bm.from_mesh(me)
        bmesh.ops.delete(bm, geom=[f for f in bm.faces if f.material_index != k], context="FACES")
        lm = bpy.data.meshes.new("%s_%d" % (body, k))
        bm.to_mesh(lm)
        bm.free()
        lm.materials.clear()
        lm.materials.append(front)
        lm.materials.append(side)
        for p in lm.polygons:
            p.material_index = 0 if p.normal.z > 0.55 else 1
        for v in lm.vertices:
            dz = v.co.z - zmax
            v.co.y += SHEAR_Y * dz
            v.co.x += SHEAR_X * dz
        lm.update()
        ob = ck._link(bpy.data.objects.new("%s_%s%d" % (body, ch, k), lm))
        ck.shade_smooth(ob, 35.0)
        ob["zmax"] = zmax
        ob["size"] = size
        letters.append(ob)
    bpy.data.meshes.remove(me)
    return letters


def letter_highlight(ob, gloss):
    """One crisp white gloss streak on the flat front face of a letter, starting at its most upper-left
    point (inset from the bevel) and running along whichever direction stays on the face longest."""
    import numpy as np
    from mathutils.bvhtree import BVHTree

    size, zmax = ob["size"], ob["zmax"]
    bm = bmesh.new()
    bm.from_mesh(ob.data)
    tree = BVHTree.FromBMesh(bm)
    bm.free()
    front = [v.co for v in ob.data.vertices if v.co.z > zmax - 1e-3]
    x0, x1 = min(c.x for c in front), max(c.x for c in front)
    y0, y1 = min(c.y for c in front), max(c.y for c in front)
    step = 0.012 * size
    xs = np.arange(x0, x1 + step, step)
    ys = np.arange(y0, y1 + step, step)
    face = np.zeros((len(ys), len(xs)), dtype=bool)
    for j, y in enumerate(ys):
        for i, x in enumerate(xs):
            hit = tree.ray_cast(Vector((x, y, zmax + 1.0)), Vector((0, 0, -1)))
            face[j, i] = hit[0] is not None and abs(hit[1].z) > 0.9 and hit[0].z > zmax - 0.02 * size
    k = int(math.ceil(0.03 * size / step))
    inset = face.copy()
    for dj in range(-k, k + 1):
        for di in range(-k, k + 1):
            if di * di + dj * dj > k * k:
                continue
            sh = np.zeros_like(face)
            sh[max(dj, 0):len(ys) + min(dj, 0), max(di, 0):len(xs) + min(di, 0)] = \
                face[max(-dj, 0):len(ys) - max(dj, 0), max(-di, 0):len(xs) - max(di, 0)]
            inset &= sh
    if not inset.any():
        return None
    h = y1 - y0
    jj, ii = np.nonzero(inset)
    score = -(xs[ii] - x0) / h + 1.3 * (ys[jj] - y0) / h
    b = int(np.argmax(score))
    p0 = Vector((xs[ii[b]], ys[jj[b]]))

    def on_face(p):
        i, j = int(round((p.x - x0) / step)), int(round((p.y - y0) / step))
        return 0 <= i < len(xs) and 0 <= j < len(ys) and inset[j, i]

    cap = 0.3 * h
    best, best_len = None, 0.0
    for d in ((1, 0), (0.8, 0.6), (0.6, 0.8), (0.71, -0.71), (0, -1), (-0.45, -0.89), (0.45, -0.89)):
        dv = Vector(d).normalized()
        ln = 0.0
        while ln < cap and on_face(p0 + dv * (ln + step)):
            ln += step
        if ln > best_len + 1e-6:
            best, best_len = dv, ln
    if best is None or best_len < 0.08 * size:
        return None
    pts = [p0 + best * (best_len * t) for t in (0.0, 0.25, 0.5, 0.75, 1.0)]
    return ck.gloss_streak([(p.x, p.y, zmax + 0.012 * size) for p in pts], 0.075 * size, (0, 0, 1), mat=gloss,
                           name=ob.name + "_Hi", flatten=0.25)


def bounds_of(objs):
    lo = Vector((1e9, 1e9, 1e9))
    hi = Vector((-1e9, -1e9, -1e9))
    for ob in objs:
        a, b = sk.mesh_bounds(ob)
        lo = Vector(map(min, lo, a))
        hi = Vector(map(max, hi, b))
    return lo, hi


def shift(objs, dx, dy, dz=0.0):
    for ob in objs:
        ob.data.transform(Matrix.Translation((dx, dy, dz)))


def arch(objs, radius, y0):
    """Bends everything round a circle below the logo: x becomes arc length at radius + (y - y0)."""
    for ob in objs:
        me = ob.data
        for v in me.vertices:
            th = v.co.x / radius
            rho = radius + (v.co.y - y0)
            v.co.x = rho * math.sin(th)
            v.co.y = y0 - radius + rho * math.cos(th)
        me.update()


def sparkle(cx, cy, size, mat, name, z=0.0):
    ob = sk.puffy_shape(sk.star4_outline(r=1.0, rx=0.84, waist=0.46), depth=0.3, height=0.18, reach=0.3, mat=mat,
                        name=name, voxel=0.012, iters=12, factor=0.5)
    ob.data.transform(Matrix.Translation((cx, cy, z)) @ Matrix.Scale(size, 4))
    return ob


def logo():
    """CHAD (orange) AURA (purple, with a sparkle) on line one, a bigger TYCOON (sunny yellow) on line
    two; flat colour faces, darker drop sides, one gloss streak per letter, a candy dumbbell centred
    above, the whole wordmark gently arched and tilted up to the right."""
    ck.reset_scene()
    gloss = ck.gloss_material()
    orange_f = ck.toy_material("LogoOrange", "Orange", emission=0.18, rim=0.15)
    orange_s = ck.toy_material("LogoOrangeSide", dark(ck.mix("Orange", "Coral", 0.45), 0.6), emission=0.25, rim=0.0)
    grape_f = ck.toy_material("LogoGrape", ck.mix("Grape", "GrapeDeep", 0.35), emission=0.18, rim=0.15)
    grape_s = ck.toy_material("LogoGrapeSide", dark("GrapeDeep", 0.62), emission=0.25, rim=0.0)
    sun_f = ck.toy_material("LogoSunny", "Sunny", emission=0.16, rim=0.15)
    sun_s = ck.toy_material("LogoSunnySide", dark(ck.mix("Orange", "GoldDeep", 0.4), 0.78), emission=0.25, rim=0.0)
    spark_m = ck.toy_material("LogoSparkle", ck.mix("Sunny", "White", 0.2), emission=0.35)

    s1, s2 = 1.0, 1.55
    chad = glyphs("CHAD", s1, orange_f, orange_s)
    aura = glyphs("AURA", s1, grape_f, grape_s)
    tyc = glyphs("TYCOON", s2, sun_f, sun_s)
    (clo, chi), (alo, ahi), (tlo, thi) = (bounds_of(w) for w in (chad, aura, tyc))
    gap = 0.5
    w1 = (chi.x - clo.x) + gap + (ahi.x - alo.x)
    shift(chad, -w1 / 2 - clo.x, 0)
    shift(aura, w1 / 2 - ahi.x, 0)
    top2 = clo.y - 0.12
    shift(tyc, -(tlo.x + thi.x) / 2, top2 - thi.y)
    for w in (chad, aura, tyc):
        gaps = [sk.mesh_bounds(b)[0].x - sk.mesh_bounds(a)[1].x for a, b in zip(w, w[1:])]
        print("LOGO_GAPS", w[0].name.split("_")[0], " ".join("%.3f" % g for g in gaps))
    lights = [letter_highlight(ob, gloss) for ob in chad + aura + tyc]
    lights = [o for o in lights if o is not None]
    print("LOGO_HIGHLIGHTS", len(lights), "of", len(chad + aura + tyc))

    (alo, ahi), (clo, chi) = bounds_of(aura), bounds_of(chad)
    zf = chad[0]["zmax"]
    spark = sparkle(ahi.x - 0.2, ahi.y - 0.12, 0.22, spark_m, "Sparkle", zf + 0.1)

    # Candy dumbbell centred above line one, tilted a little, with clear space around it.
    bell = sk.dumbbell("HotPink", "White", "Mint", name="LogoBell")
    m = (Matrix.Translation((0.0, chi.y + 0.6, 0.0)) @ Matrix.Rotation(math.radians(-8), 4, "Z")
         @ Matrix.Scale(0.36, 4))
    sk.transform(bell, m)

    allobs = chad + aura + tyc + lights + [spark] + bell
    lo, hi = bounds_of(allobs)
    arch(allobs, 30.0, (lo.y + hi.y) / 2)
    sk.transform(allobs, Matrix.Rotation(math.radians(2.5), 4, "Z"))
    sk.to_front(allobs)
    sk.render_frame(allobs, raw("Logo"), 2048, 1024, pad=0.09, samples=128)


# ------------------------------------------------------------------------------------------------
# Title card
# ------------------------------------------------------------------------------------------------


def panel_material():
    """Royal-blue vinyl panel: deep at the bottom, lighter toward the top, a soft inner shadow under the
    top rim ("grad" = height 0..1) and a soft diagonal glossy stripe across the upper half ("diag")."""
    mat = sk.ramp_material("PlaqueBlue", [(0.0, ck.mix("BlueDeep", "Board", 0.55)),
                                          (0.55, ck.mix("BlueDeep", "Board", 0.2)),
                                          (0.84, ck.mix("BlueDeep", "Blue", 0.35)),
                                          (0.93, ck.mix("BlueDeep", "Board", 0.6)),
                                          (1.0, ck.mix("BlueDeep", "Board", 0.85))], emission=0.08, roughness=0.3,
                           coat=0.6, rim=0.0)
    nt = mat.node_tree
    p = nt.nodes.get("Principled BSDF")
    base = p.inputs["Base Color"].links[0].from_socket
    at = nt.nodes.new("ShaderNodeAttribute")
    at.attribute_name = "diag"
    g, g2 = 0.22, 0.12
    stripe = sk._ramp(nt, [(0.0, (0, 0, 0)), (0.6, (0, 0, 0)), (0.645, (g, g, g)), (0.7, (g, g, g)),
                           (0.745, (0, 0, 0)), (0.79, (0, 0, 0)), (0.81, (g2, g2, g2)), (0.83, (0, 0, 0)),
                           (1.0, (0, 0, 0))])
    stripe.color_ramp.interpolation = "EASE"
    nt.links.new(at.outputs["Fac"], stripe.inputs["Fac"])
    mix = nt.nodes.new("ShaderNodeMix")
    mix.data_type = "RGBA"
    nt.links.new(stripe.outputs["Color"], mix.inputs["Factor"])
    nt.links.new(base, mix.inputs[6])
    mix.inputs[7].default_value = (*ck.mix("Blue", "White", 0.7), 1.0)
    nt.links.new(mix.outputs[2], p.inputs["Base Color"])
    nt.links.new(mix.outputs[2], p.inputs["Emission Color"])
    return mat


def set_diag(ob, slope):
    """Float attribute "diag" = 0..1 position along y + slope * x (for the panel's gloss stripe)."""
    me = ob.data
    vals = [v.co.y + slope * v.co.x for v in me.vertices]
    lo, hi = min(vals), max(vals)
    at = me.attributes.get("diag") or me.attributes.new("diag", "FLOAT", "POINT")
    for i, val in enumerate(vals):
        at.data[i].value = (val - lo) / (hi - lo)
    return ob


def title_card():
    ck.reset_scene()
    W, H = 8.6, 4.6
    gold = sk.ramp_material("PlaqueGold", [(0.0, ck.mix("GoldDeep", "Orange", 0.3)), (0.5, "Sunny"),
                                           (1.0, ck.mix("Sunny", "White", 0.45))], emission=0.05)
    blue = panel_material()
    rivet_m = ck.toy_material("Rivet", ck.mix("Sunny", "White", 0.25))
    rim = sk.ring_slab(sk.rounded_rect(W, H, 1.0, 12), sk.rounded_rect(W - 1.1, H - 1.1, 0.45, 12), 0.5, gold, "Rim")
    sk.set_grad(rim, -H / 2, H / 2, axis=1)
    ck.soften(rim, width=0.2, segments=5, limit_angle=30)
    panel = ck.extrude_shape(sk.rounded_rect(W - 0.9, H - 0.9, 0.55, 12), depth=0.3, mat=blue, name="Panel",
                             bevel=0.06)
    sk.set_grad(panel, -(H - 0.9) / 2, (H - 0.9) / 2, axis=1)
    set_diag(panel, 0.2)
    parts = [rim, panel]
    c = 0.725 / math.sqrt(2)
    for sx in (-1, 1):
        for sy in (-1, 1):
            r = ck.sphere(0.15, 24, 12, rivet_m, "Rivet", (sx * (W / 2 - 1.0 + c), sy * (H / 2 - 1.0 + c), 0.27))
            r.scale = (1, 1, 0.6)
            parts.append(r)
    for ob in parts:
        sk.bake(ob)
    sk.to_front(parts)
    cx, cz = -(W / 2 - 1.0), H / 2 - 1.0
    streak = sk.surface_streak([rim], [(cx + 0.72 * math.cos(math.radians(a)), cz + 0.72 * math.sin(math.radians(a)))
                                       for a in (100, 115, 130, 145, 160, 172)], 0.16)
    streak2 = sk.surface_streak([rim], [(x, H / 2 - 0.28) for x in (-2.0, -1.4, -0.8)], 0.11)
    parts += [s for s in (streak, streak2) if s]
    sk.render_frame(parts, raw("TitleCard"), 2048, 1152, pad=0.05, samples=128)


# ------------------------------------------------------------------------------------------------
# Key art
# ------------------------------------------------------------------------------------------------


SHORE = 15.0  # mean distance of the waterline from the scene origin (camera at y = -22.3)


def shore(x):
    return SHORE + 1.2 * math.sin(0.21 * x + 0.4) + 0.5 * math.sin(0.53 * x + 1.1)


def strip(name, mat, xs, y_lo, y_hi, z):
    """Ground band between two y(x) functions (wavy edges)."""
    bm = bmesh.new()
    lo = [bm.verts.new((x, y_lo(x), z)) for x in xs]
    hi = [bm.verts.new((x, y_hi(x), z)) for x in xs]
    for i in range(len(xs) - 1):
        bm.faces.new((lo[i], lo[i + 1], hi[i + 1], hi[i]))
    ob = ck.mesh_object(name, bm, mat, smooth=False)
    return ob


def sea(mat, xs):
    bm = bmesh.new()
    offs = [0.5, 2, 5, 10, 20, 40, 80, 160, 400, 1200, 3000]
    rows = []
    for o in offs:
        rows.append([bm.verts.new((x * (1 + o / 60), shore(x) + o if o < 40 else SHORE + o, -0.02)) for x in xs])
    for a, b in zip(rows, rows[1:]):
        for i in range(len(xs) - 1):
            bm.faces.new((a[i], a[i + 1], b[i + 1], b[i]))
    ob = ck.mesh_object("Sea", bm, mat, smooth=False)
    sk.set_grad(ob, SHORE, SHORE + 236, axis=1)
    return ob


def place(parts, loc, rot=(0, 0, 0), scale=1.0, name="Group"):
    g = ck.group(parts, name, location=loc, rotation=rot)
    g.scale = (scale, scale, scale)
    return g


def orb(i, loc, r, col, rim, cam_loc, glow=0.5):
    m = ck.gradient_material("Orb%d" % i, [(0.0, ck.mix(col, "White", 0.5)), (0.45, col), (1.0, rim)],
                             mode="FACING", emission=0.35, roughness=0.15, coat=0.9)
    ball = ck.sphere(r, 48, 24, m, "Orb%d" % i, loc)
    ball.visible_shadow = False
    g = sk.glow_material("OrbGlow%d" % i, "halo", color=ck.mix(col, "White", 0.3), peak=glow, strength=1.2)
    sk.glow_disc(g, Vector(loc) + (Vector(loc) - cam_loc).normalized() * r * 1.2, r * 2.4, facing=cam_loc,
                 name="OrbGlow%d" % i)
    return ball


def frame_box(scene, cam, objs):
    """Bounds of the objects' vertices in the camera frame: (left, right, top, bottom), as fractions of
    the frame width from the left edge and of its height from the top edge."""
    pts = [world_to_camera_view(scene, cam, ob.matrix_world @ v.co) for ob in objs for v in ob.data.vertices]
    return min(p.x for p in pts), max(p.x for p in pts), min(1 - p.y for p in pts), max(1 - p.y for p in pts)


def key_art():
    """Sunny beach gym: a flexing Chad on a sunny posing stage, two fans cheering with heart signs,
    big candy dumbbells on the sand, palms, sea, sky and puffy clouds; all in focus. Composed for the
    loading screen: the top third is clear sky with clouds for the logo, the hero group sits in the
    middle (Chad's hair at ~37.5 % from the top, stage and feet at ~75.5 %, fans inside the central
    75 % of the width for 4:3 crops) and the bottom fifth is plain sand for the loading bar and tip.
    Prints the measured frame fractions as a KEYART_LAYOUT line."""
    from figures import chad, fan, place as fplace, stage, SKIN, SKIN_DEEP

    ck.reset_scene()
    scene = bpy.context.scene
    ck._clear_rig()
    ck._setup_render(scene, 2048, 1152, False, samples=128, ao_distance=1.2)
    ck._world(scene, 0.62, backdrop=(ck.mix("Sky", "Blue", 0.6), ck.mix("Sky", "White", 0.55)))
    ck._sun("ChadRig_Key", Vector((-0.5, -0.6, 0.65)).normalized(), 3.0, ck.KEY_COLOR, 3.0, spec=0.6)
    ck._sun("ChadRig_Fill", Vector((0.7, -0.5, 0.25)).normalized(), 0.6, ck.FILL_COLOR, 40.0, False, spec=0.0)
    ck._sun("ChadRig_Bounce", Vector((0.0, -0.3, -1.0)).normalized(), 0.35, ck.BOUNCE_COLOR, 60.0, False, spec=0.0)

    xs = [x * 1.5 for x in range(-70, 71)]
    sand_m = ck.matte_material("Sand", tuple(v * 0.8 for v in ck.mix("Sand", "SandDark", 0.3)), roughness=0.95)
    wet_m = ck.matte_material("WetSand", ck.mix("SandDark", "Orange", 0.12), roughness=0.6)
    foam_m = ck.toy_material("Foam", "White", roughness=0.5, coat=0.0, emission=0.25, rim=0.0)
    sea_m = sk.ramp_material("SeaRamp", [(0.0, ck.mix("Pool", "White", 0.2)), (0.05, "Pool"), (0.2, "Ocean"),
                                         (1.0, ck.mix("Ocean", "Blue", 0.45))], roughness=0.3, coat=0.35, rim=0.0)
    strip("Sand", sand_m, xs, lambda x: -60, lambda x: shore(x) - 1.3, 0.0)
    strip("Wet", wet_m, xs, lambda x: shore(x) - 1.3, lambda x: shore(x) - 0.1, 0.0)
    strip("Foam", foam_m, xs, lambda x: shore(x) - 0.25, lambda x: shore(x) + 0.6, 0.012)
    sea(sea_m, xs)
    for i, (x, y, s) in enumerate([(-30, 41, 1.0), (-8, 61, 1.3), (18, 36, 0.9), (40, 76, 1.4), (-55, 86, 1.5),
                                   (6, 111, 1.8), (62, 51, 1.1)]):
        w = ck.torus(2.4, 0.32, 24, 8, arc=80, mat=foam_m, name="Wave%d" % i)
        w.rotation_euler = (0, 0, math.radians(50))
        w.scale = (s, s * 0.6, 0.35)
        w.location = (x, y, 0.0)

    cloud_m = ck.toy_material("Cloud", "White", roughness=0.7, coat=0.0, emission=0.22, rim=0.0)
    proto = sk.cloud(cloud_m, voxel=0.05, iters=12, name="Cloud", flat_bottom=-0.62)
    for i, (loc, s) in enumerate([((-62, 230, 34), 15), ((22, 265, 56), 20), ((78, 215, 30), 12),
                                  ((-100, 205, 58), 13), ((-18, 300, 84), 12), ((110, 240, 76), 14)]):
        c = proto if i == 0 else proto.copy()
        if i:
            ck._link(c)
        c.location = loc
        c.scale = (s * (1.0 if i % 2 == 0 else -1.0), s, s * 0.85)

    # Palms with tan / wood banded trunks along the back of the beach.
    ck.toy_material("TrunkOrange", ck.mix("Tan", "WoodDark", 0.35))
    ck.toy_material("TrunkTan", ck.mix("Wood", "Cream", 0.3))
    for i, (loc, rot, s) in enumerate([((-11, 10.5, 0), (0, 0, 20), 0.85), ((11.5, 11.5, 0), (0, 0, 195), 0.9),
                                       ((-17, 12.5, 0), (0, 0, 35), 0.72), ((17.5, 13, 0), (0, 0, 160), 0.7)]):
        place(sk.palm(name="Palm%d" % i), loc, rot, s, "PalmG%d" % i)

    # Hero group: Chad flexing on the stage, a fan either side cheering with heart signs (signs on the
    # outer sides), big dumbbells resting on the sand.
    stage_p = fplace(stage(), (0, -1, 0))
    chad_p = fplace(chad(), (0, -1, 0.46), rot_z=0, scale=1.05)
    fans = [fplace(fan("Pink", "Mint", ck.mix("Orange", "WoodDark", 0.4), SKIN, "HotPink", "FanA"), (-3.7, -2.6, 0),
                   rot_z=24, scale=1.0, mirror=True),
            fplace(fan("Mint", "Blue", ck.mix("WoodDark", "Ink", 0.45), SKIN_DEEP, "Blue", "FanB"), (3.8, -2.4, 0),
                   rot_z=-24, scale=1.0)]
    bells = []
    for i, (plate, grip, loc, rz, s) in enumerate([("Grape", "Sunny", (-6.9, 0.2, 0), 28, 1.55),
                                                   ("Coral", "Mint", (7.1, 1.0, 0), -32, 1.4)]):
        bell = sk.dumbbell(plate, "White", grip, name="Bell%d" % i)
        bells += fplace(bell, (loc[0], loc[1], 0.78 * s), rot_z=rz, scale=s)

    cam_loc = Vector((0, -22.3, 2.45))
    # Aura: a soft warm glow behind Chad and a few crisp aura orbs floating round him.
    aura = sk.glow_disc(sk.glow_material("ChadAura", "halo", color=ck.mix("Sunny", "White", 0.55), peak=0.42),
                        (0, 0.4, 2.6), 3.3, facing=cam_loc, name="ChadAura")
    orbs = [orb(i, loc, r, col, rim, cam_loc)
            for i, (loc, r, col, rim) in enumerate([((-2.55, -0.6, 4.25), 0.3, "Grape", "Magenta"),
                                                    ((2.6, -0.4, 4.55), 0.34, "HotPink", "Grape"),
                                                    ((1.75, 0.3, 5.35), 0.22, "Mint", "Blue"),
                                                    ((-1.6, 0.4, 5.25), 0.2, "Sunny", "Orange")])]

    cd = bpy.data.cameras.new("ChadRig_Cam")
    cd.lens = 30
    cd.sensor_fit = "HORIZONTAL"
    cd.sensor_width = 36
    cd.clip_start = 0.1
    cd.clip_end = 5000
    # Level camera with the view shifted up: horizon at ~57 % from the top, Chad's hair at ~37.5 %, the
    # stage and the fans' feet at ~75.5 %. The top third stays clear sky for the logo, the bottom fifth
    # calm sand for the loading bar.
    cd.shift_y = 0.037
    cd.dof.use_dof = False
    cam = ck._link(bpy.data.objects.new("ChadRig_Cam", cd))
    cam.location = cam_loc
    cam.rotation_euler = (math.radians(90), 0, 0)
    scene.camera = cam

    # Where things land in the frame (fractions of the width from the left, of the height from the top);
    # the loading screen's Luau layout is built round these numbers.
    bpy.context.view_layer.update()
    chad_b = frame_box(scene, cam, chad_p)
    fan_b = [frame_box(scene, cam, f) for f in fans]
    ground = [frame_box(scene, cam, g)[3] for g in [stage_p] + fans]
    bell_b = frame_box(scene, cam, bells)
    orb_tops = [frame_box(scene, cam, [o])[2] for o in orbs]
    aura_c = world_to_camera_view(scene, cam, aura.matrix_world.translation)
    horizon = world_to_camera_view(scene, cam, Vector((0, SHORE + 3000, -0.02)))
    print("KEYART_LAYOUT chad_top=%.3f chad_x=%.3f..%.3f group_bottom=%.3f (stage %.3f fans %.3f %.3f) "
          "fans_x=%.3f..%.3f sign_top=%.3f orb_tops=%s aura_centre=%.3f horizon=%.3f bells_x=%.3f..%.3f "
          "bells_y=%.3f..%.3f" % (chad_b[2], chad_b[0], chad_b[1], max(ground), ground[0], ground[1], ground[2],
                                  min(f[0] for f in fan_b), max(f[1] for f in fan_b), min(f[2] for f in fan_b),
                                  "/".join("%.3f" % t for t in orb_tops), 1 - aura_c.y, 1 - horizon.y,
                                  bell_b[0], bell_b[1], bell_b[2], bell_b[3]))
    scene.render.filepath = raw("KeyArt")
    bpy.ops.render.render(write_still=True)


JOBS = {"Logo": logo, "TitleCard": title_card, "KeyArt": key_art}

if __name__ == "__main__":
    for nm in sk.script_args() or list(JOBS):
        JOBS[nm]()
        print("BRAND_DONE", nm, raw(nm))
