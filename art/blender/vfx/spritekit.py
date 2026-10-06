"""spritekit: helpers shared by the VFX sprite and branding scripts (art/blender/vfx, art/blender/brand).

Builds on art/blender/lib/chadkit.py (palette, toy materials, light rig) and adds what sprites and
branding need: puffy "inflated" 2D shapes (voxel remesh + dome + smooth), a neutral self-lit white
finish for game-tinted particles, soft radial glow planes, painted gloss streaks found by ray cast,
non-square framed renders, fat bevelled text, and a few scene pieces (palm, dumbbell, cloud).

Font used for every wordmark: Arial Rounded MT Bold (macOS, /System/Library/Fonts/Supplemental/
Arial Rounded Bold.ttf), fattened with the Blender text "offset".
"""

import math
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "lib"))

import chadkit as ck  # noqa: E402

import bmesh  # noqa: E402
import bpy  # noqa: E402
from mathutils import Matrix, Vector  # noqa: E402
from mathutils.bvhtree import BVHTree  # noqa: E402

OUT_VFX = os.path.join(ck.ROOT, "art", "out", "vfx")
OUT_BRAND = os.path.join(ck.ROOT, "art", "out", "brand")
RAW_VFX = os.path.join(OUT_VFX, "raw")
RAW_BRAND = os.path.join(OUT_BRAND, "raw")
for _d in (RAW_VFX, RAW_BRAND):
    os.makedirs(_d, exist_ok=True)

FONT = ck.FONT_PATH  # Arial Rounded MT Bold


def script_args():
    """Arguments after "--" on the Blender command line."""
    return sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []


def view_frame(az, el):
    """(right, up, to_camera) world vectors for a chadkit camera at azimuth/elevation (degrees)."""
    to_cam = ck._view_dir(az, el)
    fwd = -to_cam
    right = fwd.cross(Vector((0, 0, 1))).normalized()
    up = right.cross(fwd).normalized()
    return right, up, to_cam


# ------------------------------------------------------------------------------------------------
# Mesh utilities
# ------------------------------------------------------------------------------------------------


def bake(ob):
    """Applies modifiers and the object transform into the mesh data (object ends at identity)."""
    dg = bpy.context.evaluated_depsgraph_get()
    mats = list(ob.data.materials)
    me = bpy.data.meshes.new_from_object(ob.evaluated_get(dg), depsgraph=dg)
    me.transform(ob.matrix_world)
    ob.modifiers.clear()
    ob.parent = None
    ob.data = me
    ob.matrix_world = Matrix.Identity(4)
    if not me.materials:
        for m in mats:
            me.materials.append(m)
    return ob


def join(objs, name="Joined", mat=None):
    """Merges meshes (world transforms applied) into one new object."""
    bm = bmesh.new()
    for ob in objs:
        me = ob.data.copy()
        me.transform(ob.matrix_world)
        bm.from_mesh(me)
        bpy.data.meshes.remove(me)
    for ob in objs:
        bpy.data.objects.remove(ob, do_unlink=True)
    return ck.mesh_object(name, bm, mat)


def remesh(ob, voxel, smooth_iters=0, smooth_factor=0.6):
    """Voxel remesh (fuses overlapping parts into one skin), then optional Laplacian-style smoothing
    that rounds every edge into a soft toy bevel. Baked."""
    m = ob.modifiers.new("Remesh", "REMESH")
    m.mode = "VOXEL"
    m.voxel_size = voxel
    m.adaptivity = 0.0
    m.use_smooth_shade = True
    if smooth_iters:
        s = ob.modifiers.new("Smooth", "SMOOTH")
        s.factor = smooth_factor
        s.iterations = smooth_iters
    bake(ob)
    ck.shade_smooth(ob, None)
    return ob


def smooth(ob, iters, factor=0.6):
    s = ob.modifiers.new("Smooth", "SMOOTH")
    s.factor = factor
    s.iterations = iters
    bake(ob)
    ck.shade_smooth(ob, None)
    return ob


def inflate(ob, outline, height, reach, power=2.0):
    """Domes a flat slab built in XY (depth along Z, centred on z = 0): every vertex moves away from
    the z = 0 plane by height * ease(distance to the 2D outline / reach), so the middle swells like a
    balloon and the rim stays round."""
    import numpy as np

    me = ob.data
    n = len(me.vertices)
    co = np.empty(n * 3, dtype=np.float64)
    me.vertices.foreach_get("co", co)
    co = co.reshape(-1, 3)
    a = np.asarray(outline, dtype=np.float64)
    b = np.roll(a, -1, axis=0)
    ab = b - a
    ab2 = np.maximum((ab * ab).sum(1), 1e-12)
    dist = np.empty(n)
    for s in range(0, n, 4000):
        xy = co[s:s + 4000, None, :2]
        ap = xy - a[None]
        t = np.clip((ap * ab[None]).sum(2) / ab2[None], 0.0, 1.0)
        d = ap - t[..., None] * ab[None]
        dist[s:s + 4000] = np.sqrt((d * d).sum(2)).min(1)
    f = 1.0 - (1.0 - np.clip(dist / reach, 0.0, 1.0)) ** power
    co[:, 2] += np.sign(co[:, 2]) * height * f
    me.vertices.foreach_set("co", co.ravel())
    me.update()
    return ob


def _inside(xy, poly):
    """Even-odd point-in-polygon test for many points (numpy arrays)."""
    import numpy as np

    x, y = xy[:, 0], xy[:, 1]
    inside = np.zeros(len(xy), dtype=bool)
    a = np.asarray(poly, dtype=np.float64)
    b = np.roll(a, -1, axis=0)
    for (x1, y1), (x2, y2) in zip(a, b):
        cond = (y1 > y) != (y2 > y)
        xc = x1 + (y - y1) * (x2 - x1) / ((y2 - y1) if y2 != y1 else 1e-12)
        inside ^= cond & (x < xc)
    return inside


def inflate_union(ob, outlines, height, reach, power=2.0):
    """inflate() for a shape made of several overlapping outlines: the depth used for the dome is the
    largest inside-distance over the outlines (close to the distance to the union's boundary)."""
    import numpy as np

    me = ob.data
    n = len(me.vertices)
    co = np.empty(n * 3, dtype=np.float64)
    me.vertices.foreach_get("co", co)
    co = co.reshape(-1, 3)
    best = np.zeros(n)
    for outline in outlines:
        a = np.asarray(outline, dtype=np.float64)
        b = np.roll(a, -1, axis=0)
        ab = b - a
        ab2 = np.maximum((ab * ab).sum(1), 1e-12)
        dist = np.empty(n)
        for s in range(0, n, 4000):
            xy = co[s:s + 4000, None, :2]
            ap = xy - a[None]
            t = np.clip((ap * ab[None]).sum(2) / ab2[None], 0.0, 1.0)
            d = ap - t[..., None] * ab[None]
            dist[s:s + 4000] = np.sqrt((d * d).sum(2)).min(1)
        dist[~_inside(co[:, :2], outline)] = 0.0
        best = np.maximum(best, dist)
    f = 1.0 - (1.0 - np.clip(best / reach, 0.0, 1.0)) ** power
    co[:, 2] += np.sign(co[:, 2]) * height * f
    me.vertices.foreach_set("co", co.ravel())
    me.update()
    return ob


def puffy_union(outlines, depth, height, reach, mat=None, name="Puffy", voxel=0.02, iters=24, factor=0.6):
    """puffy_shape() for several overlapping outlines fused into one inflated piece."""
    slabs = [ck.extrude_shape(o, depth=depth, mat=None, name=name + "Part", bevel=0) for o in outlines]
    ob = join(slabs, name, mat)
    remesh(ob, voxel)
    inflate_union(ob, outlines, height, reach)
    smooth(ob, iters, factor)
    return ob


def star4_outline(r=1.0, rx=0.86, waist=0.42, n=24):
    """Fat 4-point star: tips at (0, +-r) and (+-rx, 0) joined by concave quadratic curves whose
    control points sit `waist` x r out on the diagonals (bigger waist = fatter star)."""
    tips = [(0.0, r), (-rx, 0.0), (0.0, -r), (rx, 0.0)]
    pts = []
    for i in range(4):
        a, b = tips[i], tips[(i + 1) % 4]
        c = (math.copysign(waist * r / math.sqrt(2), a[0] + b[0]), math.copysign(waist * r / math.sqrt(2), a[1] + b[1]))
        for k in range(n):
            t = k / n
            pts.append(((1 - t) ** 2 * a[0] + 2 * t * (1 - t) * c[0] + t * t * b[0],
                        (1 - t) ** 2 * a[1] + 2 * t * (1 - t) * c[1] + t * t * b[1]))
    return pts


def offset_path(center, widths, cap_steps=8):
    """Closed outline of a thick stroke along a 2D polyline (`widths` = full width per point), with a
    round cap at the end."""
    left, right = [], []
    for i, (x, y) in enumerate(center):
        a = center[max(i - 1, 0)]
        b = center[min(i + 1, len(center) - 1)]
        tx, ty = b[0] - a[0], b[1] - a[1]
        ln = math.hypot(tx, ty) or 1.0
        nx, ny = -ty / ln, tx / ln
        h = widths[i] / 2
        left.append((x + nx * h, y + ny * h))
        right.append((x - nx * h, y - ny * h))
    (ex, ey), h = center[-1], widths[-1] / 2
    a = center[-2]
    ang = math.atan2(ey - a[1], ex - a[0])
    cap = [(ex + h * math.cos(ang + math.pi / 2 - math.pi * k / cap_steps),
            ey + h * math.sin(ang + math.pi / 2 - math.pi * k / cap_steps)) for k in range(1, cap_steps)]
    return left + cap + right[::-1]


def metaball_mesh(balls, name="Blob", mat=None, resolution=0.02, threshold=0.6, stiffness=2.0):
    """Smooth fused blob from metaball spheres ((x, y, z), radius, (sx, sy, sz) scale), converted
    to a smooth-shaded mesh."""
    mb = bpy.data.metaballs.new(name)
    mb.resolution = resolution
    mb.render_resolution = resolution
    mb.threshold = threshold
    for (loc, r, sc) in balls:
        el = mb.elements.new()
        el.type = "ELLIPSOID" if sc != (1, 1, 1) else "BALL"
        el.co = loc
        el.radius = r
        el.stiffness = stiffness
        if el.type == "ELLIPSOID":
            el.size_x, el.size_y, el.size_z = (r * s for s in sc)
    tmp = ck._link(bpy.data.objects.new(name + "_mb", mb))
    bpy.context.view_layer.update()
    dg = bpy.context.evaluated_depsgraph_get()
    me = bpy.data.meshes.new_from_object(tmp.evaluated_get(dg), depsgraph=dg)
    bpy.data.objects.remove(tmp, do_unlink=True)
    ob = ck._link(bpy.data.objects.new(name, me))
    if mat is not None:
        me.materials.append(mat)
    ck.shade_smooth(ob, None)
    return ob


def puffy_shape(outline, depth, height, reach, mat=None, name="Puffy", voxel=0.02, iters=24, factor=0.6):
    """Chunky inflated toy shape from a closed 2D outline (XY): slab -> voxel remesh -> dome -> smooth.
    Built in XY facing +Z; call to_front() to face the -Y camera."""
    ob = ck.extrude_shape(outline, depth=depth, mat=mat, name=name, bevel=0)
    remesh(ob, voxel)
    inflate(ob, outline, height, reach)
    smooth(ob, iters, factor)
    return ob


def to_front(objs, extra=None):
    """Turns geometry built in XY (front = +Z) to stand in XZ facing the -Y camera; `extra` is an
    optional Matrix applied afterwards (tilts)."""
    rot = Matrix.Rotation(math.radians(90), 4, "X")
    if extra is not None:
        rot = extra @ rot
    for ob in objs if isinstance(objs, (list, tuple)) else [objs]:
        ob.data.transform(ob.matrix_world)
        ob.matrix_world = Matrix.Identity(4)
        ob.data.transform(rot)
        ob.data.update()
    return objs


def transform(objs, mat):
    for ob in objs if isinstance(objs, (list, tuple)) else [objs]:
        ob.data.transform(ob.matrix_world)
        ob.matrix_world = Matrix.Identity(4)
        ob.data.transform(mat)
        ob.data.update()
    return objs


def heart_outline(n=120, size=1.0):
    """Classic heart curve, about `size` wide, centred."""
    pts = []
    for i in range(n):
        t = 2 * math.pi * i / n
        x = 16 * math.sin(t) ** 3
        y = 13 * math.cos(t) - 5 * math.cos(2 * t) - 2 * math.cos(3 * t) - math.cos(4 * t)
        pts.append((x / 32 * size, (y + 2.5) / 32 * size))
    return pts[::-1]


def twinkle_outline(n=160, rx=0.78, ry=1.0, p=2.7):
    """4-point twinkle with concave sides (superellipse with exponent p > 2)."""
    pts = []
    for i in range(n):
        t = 2 * math.pi * i / n
        c, s = math.cos(t), math.sin(t)
        pts.append((rx * math.copysign(abs(c) ** p, c), ry * math.copysign(abs(s) ** p, s)))
    return pts


def rounded_rect(w, h, r, k=10):
    """Counter-clockwise rounded rectangle outline, same vertex layout for any size (bridgeable)."""
    pts = []
    for cx, cy, a0 in ((w / 2 - r, h / 2 - r, 0), (-w / 2 + r, h / 2 - r, 90), (-w / 2 + r, -h / 2 + r, 180),
                       (w / 2 - r, -h / 2 + r, 270)):
        for i in range(k + 1):
            a = math.radians(a0 + 90 * i / k)
            pts.append((cx + r * math.cos(a), cy + r * math.sin(a)))
    return pts


def ring_slab(outer, inner, depth, mat=None, name="Ring"):
    """Closed frame between two matching outlines (XY), depth along Z centred on z = 0."""
    bm = bmesh.new()
    z0, z1 = -depth / 2, depth / 2
    of = [bm.verts.new((x, y, z1)) for x, y in outer]
    inf = [bm.verts.new((x, y, z1)) for x, y in inner]
    ob_ = [bm.verts.new((x, y, z0)) for x, y in outer]
    ib = [bm.verts.new((x, y, z0)) for x, y in inner]
    n = len(outer)
    for i in range(n):
        j = (i + 1) % n
        bm.faces.new((of[i], of[j], inf[j], inf[i]))
        bm.faces.new((ib[i], ib[j], ob_[j], ob_[i]))
        bm.faces.new((ob_[i], ob_[j], of[j], of[i]))
        bm.faces.new((inf[i], inf[j], ib[j], ib[i]))
    return ck.mesh_object(name, bm, mat, smooth=False)


# ------------------------------------------------------------------------------------------------
# Materials
# ------------------------------------------------------------------------------------------------


def _nodes(name):
    mat = bpy.data.materials.new(name)
    mat.use_nodes = True
    nt = mat.node_tree
    nt.nodes.clear()
    return mat, nt, nt.nodes.new("ShaderNodeOutputMaterial")


def _ramp(nt, stops):
    r = nt.nodes.new("ShaderNodeValToRGB")
    els = r.color_ramp.elements
    while len(els) < len(stops):
        els.new(0.5)
    for el, (pos, c) in zip(els, stops):
        el.position = pos
        el.color = (*c, 1.0)
    return r


def _math(nt, op, a, b=None, clamp=False):
    m = nt.nodes.new("ShaderNodeMath")
    m.operation = op
    m.use_clamp = clamp
    for i, v in enumerate((a, b)):
        if v is None:
            continue
        if isinstance(v, (int, float)):
            m.inputs[i].default_value = v
        else:
            nt.links.new(v, m.inputs[i])
    return m.outputs[0]


def _maprange(nt, value, fmin, fmax, mode="SMOOTHSTEP"):
    m = nt.nodes.new("ShaderNodeMapRange")
    m.interpolation_type = mode
    m.inputs["From Min"].default_value = fmin
    m.inputs["From Max"].default_value = fmax
    nt.links.new(value, m.inputs["Value"])
    return m.outputs["Result"]


# Shadow tone of the white particle finish (sRGB): a light cool lilac-grey, never dark, so a tinted
# particle keeps its hue and still shows its form.
WHITE_SHADE = (196, 200, 226)


def white_material(name, az=0.0, el=0.0, shade=WHITE_SHADE, body=0.95, spec_power=36.0):
    """Self-lit white for game-tinted sprites: soft key-light shading from the upper left (lilac-grey
    shadow side, near-white lit side) and one crisp pure-white highlight. Lighting is computed in
    the shader for the camera at (az, el), so it ignores the scene lights and stays neutral."""
    right, up, to_cam = view_frame(az, el)
    lv = (-0.55 * right + 0.8 * up + 0.7 * to_cam).normalized()
    hv = (lv + to_cam).normalized()
    mat, nt, out = _nodes(name)
    geo = nt.nodes.new("ShaderNodeNewGeometry")
    d1 = nt.nodes.new("ShaderNodeVectorMath")
    d1.operation = "DOT_PRODUCT"
    d1.inputs[1].default_value = tuple(lv)
    nt.links.new(geo.outputs["Normal"], d1.inputs[0])
    lam = _maprange(nt, d1.outputs["Value"], -0.5, 0.95)
    d2 = nt.nodes.new("ShaderNodeVectorMath")
    d2.operation = "DOT_PRODUCT"
    d2.inputs[1].default_value = tuple(hv)
    nt.links.new(geo.outputs["Normal"], d2.inputs[0])
    sp = _math(nt, "POWER", _math(nt, "MAXIMUM", d2.outputs["Value"], 0.0), spec_power)
    sp = _maprange(nt, sp, 0.35, 0.8)
    s = _math(nt, "MAXIMUM", _math(nt, "MULTIPLY", lam, 0.9), sp)
    ramp = _ramp(nt, [(0.0, ck.lin(shade)), (0.9, (body, body, body)), (1.0, (1.0, 1.0, 1.0))])
    ramp.color_ramp.interpolation = "EASE"
    nt.links.new(s, ramp.inputs["Fac"])
    em = nt.nodes.new("ShaderNodeEmission")
    nt.links.new(ramp.outputs["Color"], em.inputs["Color"])
    nt.links.new(em.outputs[0], out.inputs["Surface"])
    mat.diffuse_color = (1, 1, 1, 1)
    return mat


def glow_material(name, kind="dot", color=(1.0, 1.0, 1.0), edge=None, peak=1.0, strength=1.0, rim=None):
    """Soft radial glow for a disc of radius 1 (object coordinates): alpha follows a profile of the
    distance from the centre, colour runs from `edge` (faint parts) to `color` (dense parts).
    kind "dot": soft round glow, solid core fading to 0 at r = 1.
    kind "ring": shockwave ring, soft trailing inner fade, peak at r ~ 0.82, soft outer edge.
    kind "halo": a faint wide glow (behind sparkles, orbs).
    `rim` (linear rgb) tints the outer band and inner edge (keeps a white ring visible on light ground)."""
    edge = color if edge is None else edge
    mat, nt, out = _nodes(name)
    tc = nt.nodes.new("ShaderNodeTexCoord")
    ln = nt.nodes.new("ShaderNodeVectorMath")
    ln.operation = "LENGTH"
    nt.links.new(tc.outputs["Object"], ln.inputs[0])
    r = ln.outputs["Value"]
    if kind == "ring":
        # Soft trailing inner fade plus a firmer band with a crisp-ish inner edge at r ~ 0.68.
        trail = _math(nt, "MULTIPLY", _math(nt, "POWER", _maprange(nt, r, 0.36, 0.7), 1.6), 0.45)
        band = _maprange(nt, r, 0.64, 0.71)
        inner = _math(nt, "MAXIMUM", trail, band)
        outer = _maprange(nt, r, 0.985, 0.86)
        a = _math(nt, "MULTIPLY", inner, outer)
    elif kind == "halo":
        a = _math(nt, "POWER", _maprange(nt, r, 1.0, 0.0), 2.4)
    else:
        # Wide soft glow with a denser core (solid to r ~ 0.22, gone by r ~ 0.5) on top.
        glow = _math(nt, "POWER", _maprange(nt, r, 1.0, 0.1, "SMOOTHERSTEP"), 1.25)
        a = _math(nt, "MAXIMUM", glow, _maprange(nt, r, 0.5, 0.2))
    a = _math(nt, "MULTIPLY", a, peak, clamp=True)
    ramp = _ramp(nt, [(0.0, edge), (1.0, color)])
    nt.links.new(a, ramp.inputs["Fac"])
    col = ramp.outputs["Color"]
    if rim is not None:
        # Tint by radius: the rim colour shows on the outer band and the inner edge of a ring.
        tint = _math(nt, "MAXIMUM", _maprange(nt, r, 0.83, 0.95), _math(nt, "MULTIPLY", _maprange(nt, r, 0.75, 0.66), 0.7))
        mix = nt.nodes.new("ShaderNodeMix")
        mix.data_type = "RGBA"
        nt.links.new(tint, mix.inputs["Factor"])
        nt.links.new(col, mix.inputs[6])
        mix.inputs[7].default_value = (*rim, 1.0)
        col = mix.outputs[2]
    em = nt.nodes.new("ShaderNodeEmission")
    em.inputs["Strength"].default_value = strength
    nt.links.new(col, em.inputs["Color"])
    tr = nt.nodes.new("ShaderNodeBsdfTransparent")
    mx = nt.nodes.new("ShaderNodeMixShader")
    nt.links.new(a, mx.inputs[0])
    nt.links.new(tr.outputs[0], mx.inputs[1])
    nt.links.new(em.outputs[0], mx.inputs[2])
    nt.links.new(mx.outputs[0], out.inputs["Surface"])
    for attr, val in (("surface_render_method", "BLENDED"), ("blend_method", "BLEND")):
        try:
            setattr(mat, attr, val)
        except (AttributeError, TypeError):
            pass
    return mat


def glow_disc(mat, centre=(0, 0, 0), radius=1.0, facing=None, name="Glow", segments=64):
    """Disc of radius `radius` (object coordinates normalised to 1) facing -Y, or facing the point
    `facing` (a camera location)."""
    bm = bmesh.new()
    bmesh.ops.create_circle(bm, cap_ends=True, radius=1.0, segments=segments)
    ob = ck.mesh_object(name, bm, mat, smooth=False)
    ob.visible_shadow = False
    if facing is None:
        ob.rotation_euler = (math.radians(90), 0, 0)
    else:
        d = (Vector(facing) - Vector(centre)).normalized()
        ob.rotation_euler = d.to_track_quat("Z", "Y").to_euler()
    ob.location = centre
    ob.scale = (radius, radius, radius)
    return ob


def ramp_material(name, stops, attr="grad", emission=0.0, **toy):
    """Toy plastic whose base colour ramps through `stops` along a per-vertex float attribute."""
    cols = [(p, ck._as_linear(c)) for p, c in stops]
    mat = ck.toy_material(name, cols[len(cols) // 2][1], **toy)
    nt = mat.node_tree
    p = nt.nodes.get("Principled BSDF")
    at = nt.nodes.new("ShaderNodeAttribute")
    at.attribute_name = attr
    ramp = _ramp(nt, cols)
    ramp.color_ramp.interpolation = "EASE"
    nt.links.new(at.outputs["Fac"], ramp.inputs["Fac"])
    nt.links.new(ramp.outputs["Color"], p.inputs["Base Color"])
    if emission > 0:
        nt.links.new(ramp.outputs["Color"], p.inputs["Emission Color"])
        p.inputs["Emission Strength"].default_value = emission
    return mat


def set_grad(ob, lo, hi, axis=1):
    """Stores a 0..1 float attribute "grad" = position along `axis` between lo and hi."""
    me = ob.data
    at = me.attributes.get("grad") or me.attributes.new("grad", "FLOAT", "POINT")
    for i, v in enumerate(me.vertices):
        at.data[i].value = min(1.0, max(0.0, (v.co[axis] - lo) / (hi - lo)))
    return ob


# ------------------------------------------------------------------------------------------------
# Gloss streak placed on a surface by ray casting from the camera side (-Y)
# ------------------------------------------------------------------------------------------------


def surface_streak(objs, pts_xz, width, lift=0.03, flatten=0.3, mat=None, direction=(0, 1, 0)):
    """Painted white gloss streak through the front surface points found under `pts_xz` (x, z)
    when looking along `direction`. Objects must be baked (identity transforms)."""
    dg = bpy.context.evaluated_depsgraph_get()
    trees = [BVHTree.FromObject(o, dg) for o in (objs if isinstance(objs, (list, tuple)) else [objs])]
    dvec = Vector(direction).normalized()
    pts, nsum = [], Vector((0, 0, 0))
    for x, z in pts_xz:
        best = None
        for t in trees:
            hit = t.ray_cast(Vector((x, 0, z)) - dvec * 50, dvec)
            if hit[0] is not None and (best is None or hit[3] < best[3]):
                best = hit
        if best is None:
            continue
        pts.append(best[0] + best[1] * lift)
        nsum += best[1]
    if len(pts) < 2:
        return None
    return ck.gloss_streak(pts, width, tuple(nsum.normalized()), mat=mat, flatten=flatten)


# ------------------------------------------------------------------------------------------------
# Renders
# ------------------------------------------------------------------------------------------------


def render_frame(target, path, w, h, pad=0.06, az=0.0, el=0.0, samples=96, transparent=True):
    """Orthographic toy-rig render of `target` framed to fit a w x h frame (contain) minus `pad`."""
    scene = bpy.context.scene
    objs = ck._as_objects(target)
    ck._clear_rig()
    lo, hi = ck.bounds(objs)
    centre = (lo + hi) / 2
    radius = max((hi - lo).length / 2, 1e-3)
    ck._setup_render(scene, w, h, transparent, samples, radius * ck.RIG["ao_distance"])
    cam_dir = ck._view_dir(az, el)
    ck._toy_rig(scene, cam_dir, centre, radius)
    cd = bpy.data.cameras.new("ChadRig_Cam")
    cam = ck._link(bpy.data.objects.new("ChadRig_Cam", cd))
    cd.type = "ORTHO"
    cd.sensor_fit = "AUTO"
    cd.clip_start = radius * 0.01
    cd.clip_end = radius * 40
    cam.location = centre + cam_dir * radius * 8
    cam.rotation_euler = (-cam_dir).to_track_quat("-Z", "Y").to_euler()
    scene.camera = cam
    bpy.context.view_layer.update()
    inv = cam.matrix_world.inverted()
    pts = [inv @ p for p in ck._world_points(objs)]
    xs, ys = [p.x for p in pts], [p.y for p in pts]
    cx, cy = (min(xs) + max(xs)) / 2, (min(ys) + max(ys)) / 2
    ex, ey = max(xs) - min(xs), max(ys) - min(ys)
    aspect = w / h
    big = max(ex, ey * aspect) if aspect >= 1 else max(ex / aspect, ey)
    cd.ortho_scale = big / (1 - 2 * pad)
    cam.location = cam.matrix_world @ Vector((cx, cy, 0))
    restore = ck._isolate(objs)
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    scene.render.filepath = path
    bpy.ops.render.render(write_still=True)
    restore()
    return path


# ------------------------------------------------------------------------------------------------
# Text
# ------------------------------------------------------------------------------------------------


def text_mesh(body, size=1.0, extrude=0.15, bevel=0.04, offset=0.0, font=FONT, name="Text", space=1.0):
    """Extruded text mesh in XY (front +Z), not centred (baseline at y = 0, left at x = 0).
    `offset` fattens the glyph outlines."""
    cu = bpy.data.curves.new(name, "FONT")
    cu.body = body
    cu.font = bpy.data.fonts.load(font, check_existing=True)
    cu.size = size
    cu.extrude = extrude
    cu.bevel_depth = bevel
    cu.bevel_resolution = 4
    cu.offset = offset
    cu.resolution_u = 10
    cu.space_character = space
    tmp = ck._link(bpy.data.objects.new(name + "_curve", cu))
    dg = bpy.context.evaluated_depsgraph_get()
    me = bpy.data.meshes.new_from_object(tmp.evaluated_get(dg), depsgraph=dg)
    bpy.data.objects.remove(tmp, do_unlink=True)
    ob = ck._link(bpy.data.objects.new(name, me))
    ck.shade_smooth(ob, 35.0)
    return ob


def mesh_bounds(ob):
    xs = [v.co.x for v in ob.data.vertices]
    ys = [v.co.y for v in ob.data.vertices]
    zs = [v.co.z for v in ob.data.vertices]
    return Vector((min(xs), min(ys), min(zs))), Vector((max(xs), max(ys), max(zs)))


# ------------------------------------------------------------------------------------------------
# Scene pieces (same construction as art/blender/proof/prop_palm.py and prop_dumbbell.py)
# ------------------------------------------------------------------------------------------------


def dumbbell(plate="HotPink", hub="White", grip="Sunny", name="Dumbbell"):
    """Chunky candy dumbbell along X, centred on the origin, about 2.4 units long."""
    plate_m = ck.toy_material(name + "Plate", plate)
    hub_m = ck.toy_material(name + "Hub", hub)
    grip_m = ck.toy_material(name + "Grip", grip)
    r, w, b, hub_r, hub_h = 0.78, 0.6, 0.24, 0.34, 0.08
    prof = ck.round_profile(0, r, -w / 2, w / 2, b, 4)[:-1]
    prof += [(hub_r + 0.07, w / 2), (hub_r, w / 2 + hub_h), (0, w / 2 + hub_h)]
    parts = [ck.capsule(0.3, 1.5, 24, 4, grip_m, name + "Grip", (0, 0, 0), axis="X")]
    for side in (-1, 1):
        p = ck.lathe(prof, 40, plate_m, name + "Plate", smooth_angle=50)
        p.data.materials.append(hub_m)
        for poly in p.data.polygons:
            if poly.center.z > w / 2 - 0.01 and math.hypot(poly.center.x, poly.center.y) < hub_r + 0.04:
                poly.material_index = 1
        p.rotation_euler = (0, math.radians(90 * side), 0)
        p.location = (side * (0.46 + w / 2), 0, 0)
        parts.append(p)
    for ob in parts:
        bake(ob)
    return parts


def palm(height=6.0, name="Palm"):
    """Chunky toy palm (trunk leans toward +X), base at the origin; returns its parts."""
    stripe_a = bpy.data.materials.get("TrunkOrange") or ck.toy_material("TrunkOrange", "Orange")
    stripe_b = bpy.data.materials.get("TrunkTan") or ck.toy_material("TrunkTan", "Tan")
    leaf = bpy.data.materials.get("Leaf") or ck.toy_material("Leaf", "Lime")
    band = bpy.data.materials.get("LeafBand") or ck.toy_material("LeafBand", ck.mix("Lime", "Sunny", 0.45))
    under = bpy.data.materials.get("LeafUnder") or ck.toy_material("LeafUnder", "Emerald")
    nut = bpy.data.materials.get("Coconut") or ck.toy_material("Coconut", ck.mix("Orange", "Coral", 0.45))

    def trunk_at(t):
        return Vector((1.1 * t * t, 0.15 * t, height * t))

    parts = []
    seg = 4
    for i in range(seg):
        t0, t1 = i / seg, (i + 1) / seg + 0.02
        r = 1.15 - 0.3 * (i / (seg - 1))
        ts = [t0, (t0 + t1) / 2, t1]
        parts.append(ck.sweep([trunk_at(t) for t in ts], [r * 0.86, r, r * 0.86], 16,
                              stripe_a if i % 2 == 0 else stripe_b, name + "Trunk", smooth_angle=70))
    top = trunk_at(1.0) + Vector((0, 0, 0.25))
    parts.append(ck.sphere(0.95, 16, 8, under, name + "Crown", top))
    us = (0.0, 0.2, 0.42, 0.64, 0.84, 1.0)
    wid = (0.5, 0.98, 1.08, 0.96, 0.66, 0.0)
    sides = 6
    for k in range(7):
        a = 2 * math.pi * k / 7 + 0.25
        d = Vector((math.cos(a), math.sin(a), 0))
        reach, rise = (3.9, 0.7) if k % 2 == 0 else (3.4, 1.2)
        pts = [top + d * (0.3 + reach * u) + Vector((0, 0, 0.15 + rise * u + 1.3 * u ** 3)) for u in us]
        blade = ck.sweep(pts, wid, sides, leaf, name + "Leaf", flatten=0.4, smooth_angle=50)
        blade.data.materials.append(band)
        blade.data.materials.append(under)
        for p in blade.data.polygons:
            if len(p.vertices) != 4:
                p.material_index = 2 if p.normal.z < 0 else 0
                continue
            js = sorted({v % sides for v in p.vertices})
            if js == [1, 2]:
                p.material_index = 1
            elif p.normal.z < -0.1:
                p.material_index = 2
        parts.append(blade)
    for k in range(3):
        a = 2 * math.pi * k / 3 + 1.1
        parts.append(ck.sphere(0.52, 16, 8, nut, name + "Coconut",
                               top + Vector((0.8 * math.cos(a), 0.8 * math.sin(a), -0.75))))
    return parts


CLOUD_BALLS = [((0, 0, 0.15), 0.95), ((-0.95, 0, -0.12), 0.7), ((0.95, 0, -0.08), 0.75), ((-0.45, 0, 0.62), 0.62),
               ((0.5, 0, 0.58), 0.66), ((0, 0, -0.3), 0.8), ((-1.55, 0, -0.32), 0.45), ((1.6, 0, -0.3), 0.48)]


def cloud(mat, balls=CLOUD_BALLS, depth=0.75, voxel=0.035, iters=14, name="Cloud", flat_bottom=None):
    """Puffy cartoon cloud from overlapping balls in the XZ plane (squashed in Y), fused by remesh.
    `flat_bottom` (z) slices the underside flat."""
    parts = []
    for (x, y, z), r in balls:
        s = ck.sphere(r, 32, 16, None, name + "Ball", (x, y, z))
        s.scale = (1.0, depth, 1.0)
        parts.append(s)
    ob = join(parts, name, mat)
    if flat_bottom is not None:
        for v in ob.data.vertices:
            v.co.z = max(v.co.z, flat_bottom)
    remesh(ob, voxel, iters, 0.6)
    return ob
