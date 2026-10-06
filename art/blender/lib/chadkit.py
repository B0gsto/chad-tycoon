"""chadkit: shared Blender style library for Chad Aura Tycoon ("Sunny Muscle Beach Gym").

One look for every Blender-made asset: chunky toy proportions, big round bevels, saturated candy
colours from Theme.World, glossy vinyl shading, a warm key light from the upper left and a cool
rim light from behind.

Import from a Blender script (Blender 5.2, run headless):

    import os, sys
    sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "lib"))
    import chadkit as ck
    ck.reset_scene()
    coin = ck.lathe([(0, 0), (1, 0), (1, 0.3), (0, 0.3)], segments=48, mat=ck.toy_material("Gold", "Sunny"))
    ck.render_icon(coin, "art/out/icons/coin.png", size=512)

The Pillow parts (sticker outline, drop shadow, contact sheets) run under the system python3,
because Blender's bundled Python has no Pillow. render_icon() calls them automatically through a
subprocess; from a shell use:

    python3 art/blender/lib/chadkit.py sticker raw.png out.png [--outline 0.03] [--no-shadow]

Units: 1 Blender unit = 1 Roblox stud. Blender is Z-up with -Y as the front; export_fbx() writes
Y-up / -Z-forward so -Y in Blender becomes the Roblox front face.
"""

import math
import os
import re
import subprocess
import sys

try:
    import bmesh
    import bpy
    from mathutils import Matrix, Vector
    from mathutils.bvhtree import BVHTree

    IN_BLENDER = True
except ImportError:  # system python3: only the Pillow helpers are usable
    IN_BLENDER = False

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
THEME_PATH = os.path.join(ROOT, "src", "themes", "chad", "Theme.luau")
FONT_PATH = "/System/Library/Fonts/Supplemental/Arial Rounded Bold.ttf"
FONT_BLACK = "/System/Library/Fonts/Supplemental/Arial Black.ttf"

# ------------------------------------------------------------------------------------------------
# Palette (Theme.World in src/themes/chad/Theme.luau)
# ------------------------------------------------------------------------------------------------

# Fallback copy of Theme.World (sRGB 0..255), used only if the Luau file cannot be parsed.
_FALLBACK = {
    "Sky": (118, 200, 255), "Ocean": (72, 190, 232), "Sand": (246, 226, 176),
    "SandDark": (232, 204, 150), "Grass": (132, 214, 108), "GrassDark": (98, 190, 92),
    "Path": (255, 242, 216), "PathEdge": (236, 214, 178), "Wood": (222, 170, 112),
    "WoodDark": (176, 122, 76), "Cream": (255, 247, 232), "White": (255, 255, 255),
    "Ink": (58, 48, 96), "Board": (52, 70, 138), "BoardHi": (70, 92, 170),
    "Mat": (84, 204, 196), "MatAlt": (104, 220, 210), "Pool": (130, 226, 244),
    "PoolDeep": (96, 204, 236), "Coral": (255, 122, 110), "Pink": (255, 138, 190),
    "Sunny": (255, 212, 64), "Orange": (255, 162, 72), "Mint": (98, 224, 160),
    "Blue": (92, 178, 255), "Grape": (170, 132, 255), "Chrome": (226, 232, 242),
    "Steel": (150, 164, 196),
}


def _parse_theme(path=THEME_PATH):
    """Reads Theme.World from the Luau theme. Nested tables become dotted keys ("Pads.Buy")."""
    try:
        with open(path, encoding="utf-8") as f:
            text = f.read()
    except OSError:
        return None
    start = text.find("Theme.World = {")
    if start < 0:
        return None
    out, stack = {}, []
    for line in text[start:].splitlines()[1:]:
        s = line.strip()
        if s.startswith("--") or not s:
            continue
        m = re.match(r"(\w+)\s*=\s*rgb\((\d+),\s*(\d+),\s*(\d+)\)", s)
        if m:
            key = ".".join(stack + [m.group(1)])
            out[key] = tuple(int(m.group(i)) for i in (2, 3, 4))
            continue
        m = re.match(r"(\w+)\s*=\s*\{", s)
        if m:
            stack.append(m.group(1))
            continue
        if s.startswith("}"):
            if not stack:
                break
            stack.pop()
    return out or None


PALETTE = _parse_theme() or dict(_FALLBACK)  # name -> sRGB (0..255)

# Extra fixed tones that are not world colours but keep icons readable (gold shading).
EXTRA = {
    "GoldDeep": (240, 150, 30),  # darker rim/emboss on gold coins and trophies
    "GrapeDeep": (128, 86, 236),  # orb core
    "BlueDeep": (52, 128, 236),  # gem pavilion
    "CyanPop": (48, 210, 255),  # saturated cyan for gem crowns
    "Magenta": (236, 92, 214),  # aura orb rim glow
    "HotPink": (255, 84, 170),  # saturated candy pink for props (Theme Pink is a pastel UI tone)
    "Lime": (126, 222, 64),  # palm frond tops: bright lime, a punchier Theme Grass
    "Emerald": (34, 186, 120),  # palm frond undersides and crown
    "Tan": (240, 178, 100),  # warm saturated trunk tan (Theme Wood pushed toward Orange)
}

# Darkest tone a Blender asset may use for a dark part (tyres, recesses): a saturated deep violet,
# never black or grey (Theme.World.Ink is the darkest world colour).
DARK = "GrapeDeep"


def _srgb_to_linear(c):
    return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4


def _linear_to_srgb(c):
    c = max(0.0, min(1.0, c))
    return c * 12.92 if c <= 0.0031308 else 1.055 * c ** (1 / 2.4) - 0.055


def srgb(name_or_rgb):
    """sRGB 0..1 tuple for a palette name ("Coral", "Pads.Buy") or a 0..255 triple."""
    if isinstance(name_or_rgb, str):
        rgb = PALETTE.get(name_or_rgb) or EXTRA.get(name_or_rgb)
        if rgb is None:
            raise KeyError("chadkit: unknown palette colour %r" % name_or_rgb)
    else:
        rgb = name_or_rgb
    if max(rgb) <= 1.0 and not isinstance(rgb[0], int):
        return tuple(rgb[:3])
    return tuple(v / 255.0 for v in rgb[:3])


def lin(name_or_rgb):
    """Linear RGB tuple (what Blender colour sockets expect)."""
    return tuple(_srgb_to_linear(v) for v in srgb(name_or_rgb))


def mix(a, b, t):
    """Linear mix of two colours (names or tuples), returns linear RGB."""
    a, b = lin(a), lin(b)
    return tuple(x + (y - x) * t for x, y in zip(a, b))


# ------------------------------------------------------------------------------------------------
# Scene + materials
# ------------------------------------------------------------------------------------------------


def reset_scene():
    """Empties the factory scene (cube, light, camera) and returns the scene."""
    scene = bpy.context.scene
    for ob in list(bpy.data.objects):
        bpy.data.objects.remove(ob, do_unlink=True)
    for coll in (bpy.data.meshes, bpy.data.materials, bpy.data.lights, bpy.data.cameras, bpy.data.curves):
        for block in list(coll):
            if block.users == 0:
                coll.remove(block)
    scene.unit_settings.system = "METRIC"
    scene.unit_settings.scale_length = 1.0
    return scene


def _principled(mat):
    mat.use_nodes = True
    nt = mat.node_tree
    p = nt.nodes.get("Principled BSDF")
    return nt, p


# The one shared "toy vinyl" finish: every icon material, prop material and the game-mesh vertex
# colour material default to these values, so icons and props read as the same plastic.
# Low base specular + a near-mirror clear coat: one crisp highlight instead of a hazy sheen over the
# whole surface. "rim" is the strength of the painted cool rim (see _add_rim).
LOOK = {"roughness": 0.34, "coat": 0.75, "coat_roughness": 0.05, "specular": 0.32, "rim": 0.75}

# Cool rim tint (linear): a cyan-blue edge on the upper-right of every silhouette.
RIM_TINT = (0.32, 0.78, 1.0)


def _as_linear(color):
    if isinstance(color, tuple) and len(color) >= 3 and isinstance(color[0], float):
        return tuple(color[:3])
    return lin(color)


def _add_rim(mat, strength=None):
    """Adds the shared cool rim to a node material: an emission of RIM_TINT on grazing surfaces
    that face the upper right of the camera view (opposite the warm key), added on top of the
    surface shader. Same width and strength on icons and props, independent of lighting."""
    strength = LOOK["rim"] if strength is None else strength
    if strength <= 0:
        return mat
    nt = mat.node_tree
    out = next((n for n in nt.nodes if n.type == "OUTPUT_MATERIAL"), None)
    if out is None or not out.inputs["Surface"].links:
        return mat
    src = out.inputs["Surface"].links[0].from_socket
    lw = nt.nodes.new("ShaderNodeLayerWeight")
    lw.inputs["Blend"].default_value = 0.3
    edge = nt.nodes.new("ShaderNodeMapRange")
    edge.interpolation_type = "SMOOTHSTEP"
    edge.inputs["From Min"].default_value = 0.55
    edge.inputs["From Max"].default_value = 0.92
    nt.links.new(lw.outputs["Facing"], edge.inputs["Value"])
    geo = nt.nodes.new("ShaderNodeNewGeometry")
    vt = nt.nodes.new("ShaderNodeVectorTransform")
    vt.vector_type = "NORMAL"
    vt.convert_from = "WORLD"
    vt.convert_to = "CAMERA"
    nt.links.new(geo.outputs["Normal"], vt.inputs["Vector"])
    dot = nt.nodes.new("ShaderNodeVectorMath")
    dot.operation = "DOT_PRODUCT"
    dot.inputs[1].default_value = (0.78, 0.62, 0.0)  # camera space: +X right, +Y up
    nt.links.new(vt.outputs["Vector"], dot.inputs[0])
    side = nt.nodes.new("ShaderNodeMapRange")
    side.inputs["From Min"].default_value = -0.25
    side.inputs["From Max"].default_value = 0.7
    nt.links.new(dot.outputs["Value"], side.inputs["Value"])
    mul = nt.nodes.new("ShaderNodeMath")
    mul.operation = "MULTIPLY"
    nt.links.new(edge.outputs["Result"], mul.inputs[0])
    nt.links.new(side.outputs["Result"], mul.inputs[1])
    amt = nt.nodes.new("ShaderNodeMath")
    amt.operation = "MULTIPLY"
    amt.inputs[1].default_value = strength
    nt.links.new(mul.outputs["Value"], amt.inputs[0])
    em = nt.nodes.new("ShaderNodeEmission")
    em.inputs["Color"].default_value = (*RIM_TINT, 1.0)
    nt.links.new(amt.outputs["Value"], em.inputs["Strength"])
    add = nt.nodes.new("ShaderNodeAddShader")
    nt.links.new(src, add.inputs[0])
    nt.links.new(em.outputs["Emission"], add.inputs[1])
    nt.links.new(add.outputs["Shader"], out.inputs["Surface"])
    return mat


def toy_material(name, color, roughness=None, coat=None, coat_roughness=None, subsurface=0.0,
                 metallic=0.0, specular=None, emission=0.0, sheen=0.0, rim=None):
    """Glossy vinyl toy plastic (defaults: LOOK). `color` is a palette name or 0..255 / linear tuple.
    `rim` overrides the painted cool rim strength (0 = none).

    The linear base colour is stored on the material as mat["chad_color"] so finish_for_game()
    can bake it into vertex colours.
    """
    roughness = LOOK["roughness"] if roughness is None else roughness
    coat = LOOK["coat"] if coat is None else coat
    coat_roughness = LOOK["coat_roughness"] if coat_roughness is None else coat_roughness
    specular = LOOK["specular"] if specular is None else specular
    base = _as_linear(color)
    mat = bpy.data.materials.new(name)
    nt, p = _principled(mat)
    p.inputs["Base Color"].default_value = (*base, 1.0)
    p.inputs["Roughness"].default_value = roughness
    p.inputs["Metallic"].default_value = metallic
    p.inputs["Specular IOR Level"].default_value = specular
    p.inputs["Coat Weight"].default_value = coat
    p.inputs["Coat Roughness"].default_value = coat_roughness
    if subsurface > 0:
        p.inputs["Subsurface Weight"].default_value = subsurface
        p.inputs["Subsurface Radius"].default_value = (0.4, 0.25, 0.15)
        p.inputs["Subsurface Scale"].default_value = 0.05
    if emission > 0:
        p.inputs["Emission Color"].default_value = (*base, 1.0)
        p.inputs["Emission Strength"].default_value = emission
    if sheen > 0:
        p.inputs["Sheen Weight"].default_value = sheen
    mat.diffuse_color = (*base, 1.0)
    mat["chad_color"] = list(base)
    _add_rim(mat, rim)
    return mat


def matte_material(name, color, roughness=0.85):
    """Non-glossy surface (sand, ground, fabric). No rim."""
    return toy_material(name, color, roughness=roughness, coat=0.0, specular=0.3, rim=0.0)


def gloss_material(name="ChadGloss"):
    """Self-lit white for painted highlight streaks (gloss_streak)."""
    mat = bpy.data.materials.get(name)
    if mat:
        return mat
    return toy_material(name, "White", roughness=0.3, coat=0.0, emission=1.3, rim=0.0)


def gloss_streak(points, width, normal, mat=None, name="Streak", flatten=0.3, sides=10):
    """A painted bright specular streak: a flat white pill swept through `points` (2+ points along
    the surface, slightly above it), `width` across at its middle, tapering to round ends, lying
    flat against a surface whose outward normal is `normal`. Part of the icon look: every glossy
    icon gets one streak on its upper-left, toward the key light."""
    pts = [Vector(p) for p in points]
    if len(pts) == 2:
        pts = [pts[0].lerp(pts[1], t) for t in (0.0, 0.2, 0.5, 0.8, 1.0)]
    n = len(pts)
    radii = [width / 2 * max(0.3, math.sin(math.pi * (0.08 + 0.84 * i / (n - 1)))) for i in range(n)]
    ob = sweep(pts, radii, sides, mat or gloss_material(), name, flatten=flatten, up=normal, smooth_angle=180)
    return ob


def gradient_material(name, stops, mode="Z", lo=-1.0, hi=1.0, emission=0.0, **toy):
    """Toy plastic whose base colour ramps through `stops` [(pos 0..1, colour), ...].

    mode "Z": along the object's local Z from `lo` (pos 0) to `hi` (pos 1), e.g. a gem that runs
    cyan at the top to deep blue at the bottom. mode "FACING": by view angle, pos 0 where the
    surface faces the camera and pos 1 at the silhouette (glowing cores, rim tints).
    `emission` > 0 also feeds the ramp colour into emission (self-lit aura orbs).
    """
    cols = [(pos, _as_linear(c)) for pos, c in stops]
    mid = cols[len(cols) // 2][1]
    mat = toy_material(name, mid, emission=0.0, **toy)
    nt = mat.node_tree
    p = nt.nodes.get("Principled BSDF")
    ramp = nt.nodes.new("ShaderNodeValToRGB")
    ramp.location = (-320, 260)
    els = ramp.color_ramp.elements
    while len(els) > len(cols):
        els.remove(els[-1])
    while len(els) < len(cols):
        els.new(0.5)
    for el, (pos, c) in zip(els, cols):
        el.position = pos
        el.color = (*c, 1.0)
    ramp.color_ramp.interpolation = "EASE"
    if mode == "FACING":
        lw = nt.nodes.new("ShaderNodeLayerWeight")
        lw.inputs["Blend"].default_value = 0.5
        lw.location = (-520, 260)
        nt.links.new(lw.outputs["Facing"], ramp.inputs["Fac"])
    else:
        tc = nt.nodes.new("ShaderNodeTexCoord")
        sep = nt.nodes.new("ShaderNodeSeparateXYZ")
        mr = nt.nodes.new("ShaderNodeMapRange")
        tc.location, sep.location, mr.location = (-900, 260), (-720, 260), (-540, 260)
        mr.inputs["From Min"].default_value = lo
        mr.inputs["From Max"].default_value = hi
        nt.links.new(tc.outputs["Object"], sep.inputs[0])
        nt.links.new(sep.outputs["Z"], mr.inputs["Value"])
        nt.links.new(mr.outputs["Result"], ramp.inputs["Fac"])
    nt.links.new(ramp.outputs["Color"], p.inputs["Base Color"])
    if emission > 0:
        nt.links.new(ramp.outputs["Color"], p.inputs["Emission Color"])
        p.inputs["Emission Strength"].default_value = emission
    return mat


def vcol_material(name="ChadVcol", attribute="Col", game=False):
    """The LOOK toy plastic with its base colour from the attribute baked by finish_for_game().

    game=True gives a stand-in for Roblox SmoothPlastic instead (no clear coat, no painted rim,
    medium roughness): render_prop(..., game=True) uses it to show what ships in the engine."""
    mat = bpy.data.materials.get(name)
    if mat:
        return mat
    mat = bpy.data.materials.new(name)
    nt, p = _principled(mat)
    attr = nt.nodes.new("ShaderNodeVertexColor")
    attr.layer_name = attribute
    attr.location = (-320, 200)
    nt.links.new(attr.outputs["Color"], p.inputs["Base Color"])
    if game:
        p.inputs["Roughness"].default_value = 0.5
        p.inputs["Specular IOR Level"].default_value = 0.5
        p.inputs["Coat Weight"].default_value = 0.0
        return mat
    p.inputs["Roughness"].default_value = LOOK["roughness"]
    p.inputs["Specular IOR Level"].default_value = LOOK["specular"]
    p.inputs["Coat Weight"].default_value = LOOK["coat"]
    p.inputs["Coat Roughness"].default_value = LOOK["coat_roughness"]
    _add_rim(mat)
    return mat


# ------------------------------------------------------------------------------------------------
# Modelling helpers. All build in Blender space (Z up, -Y front), units = studs.
# ------------------------------------------------------------------------------------------------


def _link(obj, collection=None):
    (collection or bpy.context.scene.collection).objects.link(obj)
    return obj


def mesh_object(name, bm, mat=None, location=(0, 0, 0), smooth=True, collection=None):
    """Turns a bmesh into a linked object with `mat`, smooth shaded (see smooth())."""
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    me = bpy.data.meshes.new(name)
    bm.to_mesh(me)
    bm.free()
    ob = bpy.data.objects.new(name, me)
    ob.location = location
    if mat is not None:
        me.materials.append(mat)
    _link(ob, collection)
    if smooth:
        shade_smooth(ob)
    return ob


def shade_smooth(obj, angle=40.0):
    """Smooth shading with auto-smooth: edges sharper than `angle` degrees stay crisp."""
    me = obj.data
    me.shade_smooth()
    if angle is not None and angle < 180:
        me.set_sharp_from_angle(angle=math.radians(angle))
    return obj


def shade_flat(obj):
    obj.data.shade_flat()
    return obj


def soften(obj, width=0.08, segments=3, angle=40.0, weighted=True, limit_angle=30.0):
    """Big round bevel on hard edges + weighted normals, the core of the chunky toy look.

    Adds (non-destructive) BEVEL and WEIGHTED_NORMAL modifiers; finish_for_game() applies them.
    """
    bev = obj.modifiers.new("ChadBevel", "BEVEL")
    bev.width = width
    bev.segments = segments
    bev.profile = 0.5
    bev.limit_method = "ANGLE"
    bev.angle_limit = math.radians(limit_angle)
    bev.harden_normals = False
    bev.use_clamp_overlap = True
    shade_smooth(obj, angle)
    if weighted:
        wn = obj.modifiers.new("ChadWeighted", "WEIGHTED_NORMAL")
        wn.keep_sharp = True
        wn.weight = 50
    return obj


def rounded_box(size=(1, 1, 1), radius=0.15, segments=4, mat=None, name="Box", location=(0, 0, 0),
                taper=1.0):
    """Box (size = full extents) with every edge rounded by `radius`. Base sits at z = 0.

    `taper` scales the top face in X/Y (e.g. 1.15 for a flared basket)."""
    bm = bmesh.new()
    bmesh.ops.create_cube(bm, size=1.0)
    for v in bm.verts:
        v.co = Vector((v.co.x * size[0], v.co.y * size[1], (v.co.z + 0.5) * size[2]))
        if taper != 1.0 and v.co.z > size[2] * 0.5:
            v.co.x *= taper
            v.co.y *= taper
    r = min(radius, min(size) * 0.499)
    if r > 0:
        bmesh.ops.bevel(bm, geom=bm.verts[:] + bm.edges[:], offset=r, offset_type="OFFSET",
                        segments=segments, profile=0.5, affect="EDGES", clamp_overlap=True)
    ob = mesh_object(name, bm, mat, location)
    return ob


def lathe(profile, segments=32, mat=None, name="Lathe", location=(0, 0, 0), smooth_angle=40.0):
    """Revolves a (radius, z) profile around Z. Points with radius 0 become poles.

    Give the profile bottom -> top; repeat a point (or add a tiny step) for crisp edges."""
    bm = bmesh.new()
    rings = []
    for r, z in profile:
        if r <= 1e-6:
            rings.append([bm.verts.new((0, 0, z))])
        else:
            rings.append([bm.verts.new((r * math.cos(2 * math.pi * i / segments),
                                        r * math.sin(2 * math.pi * i / segments), z))
                          for i in range(segments)])
    for a, b in zip(rings, rings[1:]):
        if len(a) == 1 and len(b) == 1:
            continue
        for i in range(segments):
            j = (i + 1) % segments
            if len(a) == 1:
                bm.faces.new((a[0], b[i], b[j]))
            elif len(b) == 1:
                bm.faces.new((a[i], b[0], a[j]))
            else:
                bm.faces.new((a[i], a[j], b[j], b[i]))
    # Close open ends with an n-gon cap.
    for ring in (rings[0], rings[-1]):
        if len(ring) > 2:
            bm.faces.new(ring)
    bmesh.ops.remove_doubles(bm, verts=bm.verts, dist=1e-5)
    ob = mesh_object(name, bm, mat, location, smooth=False)
    shade_smooth(ob, smooth_angle)
    return ob


def round_profile(r0, r1, z0, z1, bevel, steps=4):
    """(r, z) profile of a disc/cylinder from z0 to z1, radius r1 (r0 = inner radius, 0 = solid),
    with round bevels of size `bevel` on its outer edges. Feed to lathe()."""
    pts = [(r0, z0)]
    for k in range(steps + 1):
        a = -math.pi / 2 + (math.pi / 2) * k / steps
        pts.append((r1 - bevel + bevel * math.cos(a), z0 + bevel + bevel * math.sin(a)))
    for k in range(steps + 1):
        a = (math.pi / 2) * k / steps
        pts.append((r1 - bevel + bevel * math.cos(a), z1 - bevel + bevel * math.sin(a)))
    pts.append((r0, z1))
    return pts


def capsule(radius=0.5, length=2.0, segments=24, rings=6, mat=None, name="Capsule", location=(0, 0, 0),
            axis="Z"):
    """Pill along `axis`, total length `length` (including caps), centred on `location`."""
    half = max(length / 2 - radius, 0.0)
    prof = []
    for k in range(rings + 1):
        a = -math.pi / 2 + (math.pi / 2) * k / rings
        prof.append((radius * math.cos(a), -half + radius * math.sin(a)))
    for k in range(rings + 1):
        a = (math.pi / 2) * k / rings
        prof.append((radius * math.cos(a), half + radius * math.sin(a)))
    ob = lathe(prof, segments, mat, name, location)
    _orient(ob, axis)
    return ob


def sphere(radius=0.5, segments=32, rings=16, mat=None, name="Sphere", location=(0, 0, 0)):
    bm = bmesh.new()
    bmesh.ops.create_uvsphere(bm, u_segments=segments, v_segments=rings, radius=radius)
    return mesh_object(name, bm, mat, location)


def torus(major=1.0, minor=0.25, seg_major=32, seg_minor=12, arc=360.0, mat=None, name="Torus",
          location=(0, 0, 0), caps=True):
    """Torus in the XY plane; `arc` < 360 gives a bent tube (handles), starting on +X."""
    bm = bmesh.new()
    full = arc >= 359.999
    n = seg_major if full else seg_major + 1
    rings = []
    for i in range(n):
        t = math.radians(arc) * i / seg_major
        c, s = math.cos(t), math.sin(t)
        ring = []
        for j in range(seg_minor):
            p = 2 * math.pi * j / seg_minor
            rr = major + minor * math.cos(p)
            ring.append(bm.verts.new((rr * c, rr * s, minor * math.sin(p))))
        rings.append(ring)
    pairs = list(zip(rings, rings[1:])) + ([(rings[-1], rings[0])] if full else [])
    for a, b in pairs:
        for j in range(seg_minor):
            k = (j + 1) % seg_minor
            bm.faces.new((a[j], a[k], b[k], b[j]))
    if not full and caps:
        bm.faces.new(rings[0])
        bm.faces.new(rings[-1])
    return mesh_object(name, bm, mat, location)


def sweep(points, radii, sides=12, mat=None, name="Sweep", flatten=1.0, up=(0, 0, 1), caps=True,
          smooth_angle=60.0):
    """Tube along a polyline. `radii` = one radius per point (taper); `flatten` < 1 squashes the
    cross-section along the frame normal (leaves, straps). Radius 0 at an end makes a point."""
    pts = [Vector(p) for p in points]
    upv = Vector(up)
    bm = bmesh.new()
    rings = []
    for i, p in enumerate(pts):
        if i == 0:
            t = pts[1] - pts[0]
        elif i == len(pts) - 1:
            t = pts[-1] - pts[-2]
        else:
            t = pts[i + 1] - pts[i - 1]
        t.normalize()
        side = t.cross(upv)
        if side.length < 1e-4:
            side = t.cross(Vector((0, 1, 0)))
        side.normalize()
        nrm = side.cross(t).normalized()
        r = radii[i]
        if r <= 1e-6:
            rings.append([bm.verts.new(p)])
            continue
        ring = []
        for j in range(sides):
            a = 2 * math.pi * j / sides
            ring.append(bm.verts.new(p + side * (math.cos(a) * r) + nrm * (math.sin(a) * r * flatten)))
        rings.append(ring)
    for a, b in zip(rings, rings[1:]):
        for j in range(sides):
            k = (j + 1) % sides
            if len(a) == 1:
                bm.faces.new((a[0], b[j], b[k]))
            elif len(b) == 1:
                bm.faces.new((a[j], a[k], b[0]))
            else:
                bm.faces.new((a[j], a[k], b[k], b[j]))
    if caps:
        for ring in (rings[0], rings[-1]):
            if len(ring) > 2:
                bm.faces.new(ring)
    ob = mesh_object(name, bm, mat, smooth=False)
    shade_smooth(ob, smooth_angle)
    return ob


def extrude_shape(points2d, depth=0.2, mat=None, name="Shape", location=(0, 0, 0), bevel=0.05,
                  bevel_segments=3):
    """Extrudes a closed 2D outline (XY, counter-clockwise) by `depth` along +Z, centred on z = 0,
    with rounded edges (stars, badges, sparkles)."""
    bm = bmesh.new()
    verts = [bm.verts.new((x, y, -depth / 2)) for x, y in points2d]
    face = bm.faces.new(verts)
    res = bmesh.ops.extrude_face_region(bm, geom=[face])
    top = [e for e in res["geom"] if isinstance(e, bmesh.types.BMVert)]
    bmesh.ops.translate(bm, verts=top, vec=(0, 0, depth))
    bmesh.ops.triangulate(bm, faces=[f for f in bm.faces if len(f.verts) > 4])
    ob = mesh_object(name, bm, mat, location, smooth=False)
    if bevel > 0:
        soften(ob, width=bevel, segments=bevel_segments, limit_angle=25.0)
    return ob


def star_points(n=5, r_out=1.0, r_in=0.5, round_steps=0, rotate=90.0):
    """Outline of an n-point star (counter-clockwise). round_steps > 0 rounds the tips with arcs."""
    pts = []
    for i in range(2 * n):
        a = math.radians(rotate) + math.pi * i / n
        r = r_out if i % 2 == 0 else r_in
        if round_steps and i % 2 == 0:
            tip = 0.18 * r_out
            for k in range(-round_steps, round_steps + 1):
                aa = a + (k / round_steps) * 0.18
                rr = r - tip * (1 - math.cos((k / round_steps) * math.pi / 2))
                pts.append((rr * math.cos(aa), rr * math.sin(aa)))
        else:
            pts.append((r * math.cos(a), r * math.sin(a)))
    return pts


def text_mesh(body, size=1.0, depth=0.1, bevel=0.03, mat=None, name="Text", font=FONT_PATH,
              resolution=4):
    """Extruded, bevelled text converted to a mesh, centred on the origin, facing +Z."""
    cu = bpy.data.curves.new(name, "FONT")
    cu.body = body
    if font and os.path.exists(font):
        cu.font = bpy.data.fonts.load(font, check_existing=True)
    cu.size = size
    cu.extrude = depth / 2
    cu.bevel_depth = bevel
    cu.bevel_resolution = resolution
    cu.resolution_u = 6
    cu.align_x = "CENTER"
    cu.align_y = "CENTER"
    tmp = _link(bpy.data.objects.new(name + "_curve", cu))
    dg = bpy.context.evaluated_depsgraph_get()
    me = bpy.data.meshes.new_from_object(tmp.evaluated_get(dg), depsgraph=dg)
    bpy.data.objects.remove(tmp, do_unlink=True)
    # Optical centre: centre the mesh bounds on X/Y.
    xs = [v.co.x for v in me.vertices]
    ys = [v.co.y for v in me.vertices]
    me.transform(Matrix.Translation((-(min(xs) + max(xs)) / 2, -(min(ys) + max(ys)) / 2, 0)))
    ob = _link(bpy.data.objects.new(name, me))
    if mat is not None:
        me.materials.append(mat)
    shade_smooth(ob, 35.0)
    return ob


def _orient(ob, axis):
    if axis == "X":
        ob.rotation_euler = (0, math.radians(90), 0)
    elif axis == "Y":
        ob.rotation_euler = (math.radians(90), 0, 0)


def group(objects, name="Group", location=(0, 0, 0), rotation=(0, 0, 0)):
    """Parents objects to an empty so a whole asset can be posed (rotation in degrees)."""
    empty = _link(bpy.data.objects.new(name, None))
    empty.location = location
    empty.rotation_euler = tuple(math.radians(a) for a in rotation)
    for ob in objects:
        ob.parent = empty
    return empty


def apply_transforms(objs):
    """Bakes object transforms (including parent) into mesh data."""
    for ob in _as_objects(objs):
        if ob.type != "MESH":
            continue
        mw = ob.matrix_world.copy()
        ob.parent = None
        ob.data.transform(mw)
        ob.matrix_world = Matrix.Identity(4)


# ------------------------------------------------------------------------------------------------
# Object set helpers
# ------------------------------------------------------------------------------------------------


def _as_objects(target):
    """Object, list, Collection or parent empty -> flat list of renderable objects."""
    if target is None:
        return []
    if IN_BLENDER and isinstance(target, bpy.types.Collection):
        return [o for o in target.all_objects if o.type in {"MESH", "CURVE", "FONT"}]
    if isinstance(target, (list, tuple, set)):
        out = []
        for t in target:
            out.extend(_as_objects(t))
        return out
    out = [target] if target.type in {"MESH", "CURVE", "FONT"} else []
    for child in target.children_recursive:
        if child.type in {"MESH", "CURVE", "FONT"}:
            out.append(child)
    return out


def _world_points(objs):
    dg = bpy.context.evaluated_depsgraph_get()
    pts = []
    for ob in objs:
        ev = ob.evaluated_get(dg)
        me = ev.to_mesh()
        mw = ev.matrix_world
        pts.extend(mw @ v.co for v in me.vertices)
        ev.to_mesh_clear()
    return pts


def bounds(target):
    """(min Vector, max Vector) of the evaluated world-space geometry."""
    pts = _world_points(_as_objects(target))
    lo = Vector((min(p.x for p in pts), min(p.y for p in pts), min(p.z for p in pts)))
    hi = Vector((max(p.x for p in pts), max(p.y for p in pts), max(p.z for p in pts)))
    return lo, hi


# ------------------------------------------------------------------------------------------------
# Render rigs. Icons and prop beauty shots share one light rig (_toy_rig) and one material finish
# (LOOK), so a prop shot and an icon of the same object read as the same glossy toy.
# ------------------------------------------------------------------------------------------------

KEY_COLOR = (1.0, 0.88, 0.72)  # warm sun, upper left
FILL_COLOR = (0.8, 0.88, 1.0)  # soft cool fill, right
RIM_COLOR = (0.38, 0.78, 1.0)  # cool cyan-blue rim from behind
BOUNCE_COLOR = (0.74, 0.62, 1.0)  # lavender bounce from below: shadow sides shift to purple
SKY_UP = (0.82, 0.9, 1.0)  # hemisphere light from above (linear)
SKY_DOWN = (0.62, 0.5, 0.95)  # hemisphere light from below: purple-blue, keeps undersides saturated

# Light levels shared by every render. Tuned so a lit Theme colour lands near its palette value
# (no clipped channels on saturated faces) while white highlights still pop.
RIG = {
    "key": 2.3, "key_angle": 10.0, "key_spec": 0.4,
    "fill": 0.45, "rim": 5.5, "bounce": 0.7,
    "sky": 0.42,  # hemisphere world strength
    "gloss": 1.6,  # multiplier on the specular-only softbox that paints the big white highlight
    "gloss_size": 1.5,  # softbox diameter / subject radius (bigger = bigger, softer highlight)
    "gloss_dist": 2.6,  # softbox distance / subject radius
    "ao_distance": 0.12,  # crevice-only AO reach as a fraction of the subject radius
}


def _setup_render(scene, size_x, size_y, transparent, samples=64, ao_distance=0.2):
    scene.render.engine = "BLENDER_EEVEE"
    scene.eevee.taa_render_samples = samples
    for attr, val in (("use_raytracing", True), ("use_shadows", True), ("use_fast_gi", True),
                      ("fast_gi_method", "GLOBAL_ILLUMINATION"), ("fast_gi_distance", ao_distance),
                      ("shadow_ray_count", 2), ("shadow_step_count", 8)):
        try:
            setattr(scene.eevee, attr, val)
        except (AttributeError, TypeError):
            pass
    scene.render.resolution_x = size_x
    scene.render.resolution_y = size_y
    scene.render.resolution_percentage = 100
    scene.render.film_transparent = transparent
    scene.render.image_settings.file_format = "PNG"
    scene.render.image_settings.color_mode = "RGBA" if transparent else "RGB"
    scene.render.image_settings.color_depth = "8"
    scene.display_settings.display_device = "sRGB"
    scene.view_settings.view_transform = "Standard"  # keeps candy colours saturated (AgX greys them)
    scene.view_settings.look = "None"
    scene.view_settings.exposure = 0.0
    scene.view_settings.gamma = 1.0


def _clear_rig():
    for ob in list(bpy.data.objects):
        if ob.name.startswith("ChadRig_"):
            bpy.data.objects.remove(ob, do_unlink=True)


def _world(scene, strength, backdrop=None, flat=None):
    """Hemisphere world: SKY_UP light from above, SKY_DOWN (purple-blue) from below, so shadow
    sides pick up a cool hue instead of going grey. `backdrop` = (top, horizon) linear colours
    shown to the camera only (prop shots); None leaves the film transparent (icons).
    `flat` = one linear colour for even ambient light instead (Roblox-like preview)."""
    sky_up, sky_down = (flat, flat) if flat is not None else (SKY_UP, SKY_DOWN)
    world = bpy.data.worlds.get("ChadWorld") or bpy.data.worlds.new("ChadWorld")
    world.use_nodes = True
    nt = world.node_tree
    nt.nodes.clear()
    out = nt.nodes.new("ShaderNodeOutputWorld")
    tc = nt.nodes.new("ShaderNodeTexCoord")
    sep = nt.nodes.new("ShaderNodeSeparateXYZ")
    nt.links.new(tc.outputs["Generated"], sep.inputs[0])

    def ramp(stops):
        r = nt.nodes.new("ShaderNodeValToRGB")
        mr = nt.nodes.new("ShaderNodeMapRange")
        mr.inputs["From Min"].default_value = -1.0
        mr.inputs["From Max"].default_value = 1.0
        nt.links.new(sep.outputs["Z"], mr.inputs["Value"])
        nt.links.new(mr.outputs["Result"], r.inputs["Fac"])
        els = r.color_ramp.elements
        els.new(0.5)
        for el, (pos, c) in zip(els, stops):
            el.position = pos
            el.color = (*c, 1.0)
        return r

    light = nt.nodes.new("ShaderNodeBackground")
    light.inputs["Strength"].default_value = strength
    hemi = ramp([(0.3, sky_down), (0.5, tuple((a + b) / 2 for a, b in zip(sky_up, sky_down))), (0.75, sky_up)])
    nt.links.new(hemi.outputs["Color"], light.inputs["Color"])
    if backdrop is None:
        nt.links.new(light.outputs[0], out.inputs["Surface"])
    else:
        top, horizon = backdrop
        cam = nt.nodes.new("ShaderNodeBackground")
        sky = ramp([(0.48, horizon), (0.51, horizon), (0.66, top)])
        nt.links.new(sky.outputs["Color"], cam.inputs["Color"])
        path = nt.nodes.new("ShaderNodeLightPath")
        mixn = nt.nodes.new("ShaderNodeMixShader")
        nt.links.new(path.outputs["Is Camera Ray"], mixn.inputs[0])
        nt.links.new(light.outputs[0], mixn.inputs[1])
        nt.links.new(cam.outputs[0], mixn.inputs[2])
        nt.links.new(mixn.outputs[0], out.inputs["Surface"])
    scene.world = world


def _view_dir(azimuth, elevation):
    """Unit vector from the subject toward the camera. azimuth 0 = front (-Y), + = toward +X."""
    az, el = math.radians(azimuth), math.radians(elevation)
    return Vector((math.sin(az) * math.cos(el), -math.cos(az) * math.cos(el), math.sin(el)))


def _sun(name, direction_to_light, strength, color, angle_deg, shadow=True, spec=1.0):
    ld = bpy.data.lights.new(name, "SUN")
    ld.energy = strength
    ld.color = color
    ld.angle = math.radians(angle_deg)
    ld.use_shadow = shadow
    ld.specular_factor = spec
    ob = _link(bpy.data.objects.new(name, ld))
    ob.rotation_euler = (-direction_to_light).to_track_quat("-Z", "Y").to_euler()
    return ob


def _toy_rig(scene, cam_dir, centre, radius, backdrop=None):
    """The shared toy light rig, framed on the camera direction:
    - warm key sun from the upper left (casts the only shadows)
    - hemisphere world (cool sky above, purple-blue below) + a cool fill from the right
    - lavender bounce from below so undersides stay saturated (hue-shifted, not darkened)
    - strong cool rim sun from behind for a bright edge
    - a big specular-only softbox (upper left, near the camera) that paints one large, soft
      white highlight blob on every glossy surface.
    """
    fwd = -cam_dir  # camera -> subject
    right = fwd.cross(Vector((0, 0, 1))).normalized()
    up = right.cross(fwd).normalized()
    _world(scene, RIG["sky"], backdrop)
    _sun("ChadRig_Key", (-0.85 * right + 1.15 * up - 0.75 * fwd).normalized(), RIG["key"], KEY_COLOR,
         RIG["key_angle"], spec=RIG["key_spec"])
    _sun("ChadRig_Fill", (1.2 * right + 0.1 * up - 0.9 * fwd).normalized(), RIG["fill"], FILL_COLOR, 50.0,
         False, spec=0.0)
    _sun("ChadRig_Bounce", (0.3 * right - 1.0 * up - 0.6 * fwd).normalized(), RIG["bounce"], BOUNCE_COLOR,
         60.0, False, spec=0.0)
    _sun("ChadRig_Rim", (0.75 * right + 0.9 * up + 1.3 * fwd).normalized(), RIG["rim"], RIM_COLOR, 8.0,
         False, spec=0.6)
    # Softbox: a disk light about the size of the subject, specular only. Radiance is kept constant
    # whatever the subject size, so the highlight has the same brightness on a coin and a palm tree.
    d = (-0.55 * right + 0.75 * up - 1.0 * fwd).normalized()
    size = radius * RIG["gloss_size"]
    ld = bpy.data.lights.new("ChadRig_Gloss", "AREA")
    ld.shape = "DISK"
    ld.size = size
    ld.color = (1.0, 0.98, 0.94)
    ld.diffuse_factor = 0.0
    ld.volume_factor = 0.0
    ld.specular_factor = 1.0
    ld.use_shadow = False
    radiance = 9.0 * RIG["gloss"]
    ld.energy = radiance * math.pi * (size / 2) ** 2 * math.pi
    ob = _link(bpy.data.objects.new("ChadRig_Gloss", ld))
    ob.location = centre + d * radius * RIG["gloss_dist"]
    ob.rotation_euler = (-d).to_track_quat("-Z", "Y").to_euler()
    return right, up


def _isolate(objs):
    """Hides every other mesh from the render; returns a restore callback."""
    keep = set(o.name for o in objs)
    hidden = []
    for ob in bpy.context.scene.objects:
        if ob.type in {"MESH", "CURVE", "FONT"} and ob.name not in keep and not ob.name.startswith("ChadRig_"):
            if not ob.hide_render:
                ob.hide_render = True
                hidden.append(ob)

    def restore():
        for ob in hidden:
            ob.hide_render = False

    return restore


ICON_FILL = 0.43  # target share of the icon square covered by the subject (before the sticker)


def _coverage(path):
    """Fraction of pixels in a rendered PNG with alpha > 0.5 (Blender side, numpy)."""
    import numpy as np

    img = bpy.data.images.load(path, check_existing=False)
    buf = np.empty(img.size[0] * img.size[1] * 4, dtype=np.float32)
    img.pixels.foreach_get(buf)
    bpy.data.images.remove(img)
    return float((buf[3::4] > 0.5).mean())


def render_icon(target, path, size=512, azimuth=28.0, elevation=20.0, pad=0.11, outline=0.028,
                shadow=True, ortho=True, samples=64, keep_raw=True, halo=None, fill=ICON_FILL):
    """Renders a transparent square UI icon of `target` (object, list, parent empty or collection).

    Camera: orthographic (or 85 mm when ortho=False) at a friendly 3/4 angle, auto-framed so the
    silhouette fills the square minus `pad`. With `fill` (default ICON_FILL) the render is redone
    with a corrected pad so the subject covers about `fill` of the square, which gives a set of
    icons one optical size (a slim gem is framed tighter than a round coin); the pad stays within
    0.075..0.14 (0.13..0.17 with a halo) so the outline and shadow never touch the edge. Ortho
    only. Lit by the shared _toy_rig. Then (system python3 + Pillow) a white sticker
    outline of exactly `outline` x size pixels all round and a soft Ink drop shadow are added;
    `halo` = (palette name or 0..255 rgb, strength 0..1) adds a soft coloured glow behind the
    sticker (aura orbs). The untouched render is kept as raw/<name>_raw.png when keep_raw is true.
    """
    scene = bpy.context.scene
    objs = _as_objects(target)
    _clear_rig()
    lo, hi = bounds(objs)
    centre = (lo + hi) / 2
    radius = max((hi - lo).length / 2, 1e-3)
    _setup_render(scene, size, size, True, samples, radius * RIG["ao_distance"])
    cam_dir = _view_dir(azimuth, elevation)
    _toy_rig(scene, cam_dir, centre, radius)

    cd = bpy.data.cameras.new("ChadRig_Cam")
    cam = _link(bpy.data.objects.new("ChadRig_Cam", cd))
    cd.clip_start = radius * 0.01
    cd.clip_end = radius * 40
    dist = radius * 8
    cam.location = centre + cam_dir * dist
    cam.rotation_euler = (-cam_dir).to_track_quat("-Z", "Y").to_euler()
    scene.camera = cam
    bpy.context.view_layer.update()

    # Frame on the projected silhouette, not the bounding box, so icons fill the square evenly.
    inv = cam.matrix_world.inverted()
    pts = [inv @ p for p in _world_points(objs)]
    xs = [p.x for p in pts]
    ys = [p.y for p in pts]
    cx, cy = (min(xs) + max(xs)) / 2, (min(ys) + max(ys)) / 2
    extent = max(max(xs) - min(xs), max(ys) - min(ys))
    if ortho:
        cd.type = "ORTHO"
        cd.ortho_scale = extent / (1 - 2 * pad)
        cam.location = cam.matrix_world @ Vector((cx, cy, 0))
    else:
        cd.type = "PERSP"
        cd.lens = 85
        cd.sensor_fit = "AUTO"
        half = math.atan(cd.sensor_width / (2 * cd.lens))
        cam.location = cam.matrix_world @ Vector((cx, cy, 0))
        cam.location = centre + cam_dir * ((extent / (1 - 2 * pad)) / 2 / math.tan(half) + radius)

    restore = _isolate(objs)
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    post = outline > 0 or shadow or halo
    raw = path
    if post:
        rawdir = os.path.join(os.path.dirname(os.path.abspath(path)), "raw")
        os.makedirs(rawdir, exist_ok=True)
        raw = os.path.join(rawdir, os.path.splitext(os.path.basename(path))[0] + "_raw.png")
    scene.render.filepath = raw
    bpy.ops.render.render(write_still=True)
    if fill and ortho:
        cov = _coverage(raw)
        e = 1 - 2 * pad
        lo_pad, hi_pad = (0.13, 0.17) if halo else (0.075, 0.14)
        if cov > 0:
            e_new = math.sqrt(fill / (cov / (e * e)))
            new_pad = min(hi_pad, max(lo_pad, (1 - e_new) / 2))
            if abs(new_pad - pad) > 0.004:
                cd.ortho_scale = extent / (1 - 2 * new_pad)
                bpy.ops.render.render(write_still=True)
    restore()
    if post:
        args = ["sticker", raw, path, "--outline", str(outline)]
        if not shadow:
            args.append("--no-shadow")
        if halo:
            rgb = tuple(round(v * 255) for v in srgb(halo[0]))
            args += ["--halo", "%d,%d,%d" % tuple(rgb), "--halo-strength", str(halo[1])]
        run_pillow(args)
        if not keep_raw:
            os.remove(raw)
    return path


def render_prop(target, path, size=(640, 640), azimuth=32.0, elevation=16.0, lens=50.0, pad=0.12,
                samples=96, ground_color="Sand", sky_color="Sky", game=False):
    """Beauty shot of a prop standing on warm sand under a deep sky-blue backdrop, lit by the same
    _toy_rig as the icons (warm key upper left, cyan rim, same highlight softbox), with a soft Ink
    contact shadow under the parts that touch the ground. No sticker outline.

    game=True renders a Roblox-like preview instead: the baked vertex colours on a SmoothPlastic
    stand-in material (no clear coat, no painted rim), one sun and flat ambient light, so you can
    check that an asset still reads without the beauty-shot lighting.
    The subject keeps its own position; the ground plane is placed at its lowest point."""
    scene = bpy.context.scene
    objs = _as_objects(target)
    if isinstance(size, int):
        size = (size, size)
    _clear_rig()
    lo, hi = bounds(objs)
    centre = (lo + hi) / 2
    radius = max((hi - lo).length / 2, 1e-3)
    _setup_render(scene, size[0], size[1], False, samples, radius * RIG["ao_distance"])
    cam_dir = _view_dir(azimuth, elevation)
    backdrop = (mix(sky_color, "Blue", 0.8), mix(sky_color, "Pool", 0.35))
    swapped = []
    if game:
        fwd = -cam_dir
        right = fwd.cross(Vector((0, 0, 1))).normalized()
        up = right.cross(fwd).normalized()
        _world(scene, 0.75, backdrop, flat=(0.78, 0.82, 0.9))
        _sun("ChadRig_Sun", (-0.7 * right + 1.3 * up - 0.5 * fwd).normalized(), 2.6, (1.0, 0.96, 0.9), 2.0)
        game_mat = vcol_material("ChadGame", game=True)
        for ob in objs:
            if ob.type == "MESH":
                swapped.append((ob, list(ob.data.materials)))
                ob.data.materials.clear()
                ob.data.materials.append(game_mat)
    else:
        _toy_rig(scene, cam_dir, centre, radius, backdrop=backdrop)

    gm = bpy.data.meshes.new("ChadRig_Ground")
    bm = bmesh.new()
    bmesh.ops.create_circle(bm, cap_ends=True, radius=radius * 60, segments=64)
    bm.to_mesh(gm)
    bm.free()
    ground = _link(bpy.data.objects.new("ChadRig_Ground", gm))
    ground.location = (centre.x, centre.y, lo.z)
    gm.materials.append(bpy.data.materials.get("ChadRig_Sand") or _ground_mat(ground_color))
    blob = _contact_shadow(objs, lo, hi)

    cd = bpy.data.cameras.new("ChadRig_Cam")
    cd.lens = lens
    cd.clip_start = radius * 0.02
    cd.clip_end = radius * 400
    cam = _link(bpy.data.objects.new("ChadRig_Cam", cd))
    cam.rotation_euler = (-cam_dir).to_track_quat("-Z", "Y").to_euler()
    scene.camera = cam
    half = math.atan(cd.sensor_width / (2 * lens))
    dist = radius / math.sin(half) * (1 - pad) ** -1 * 0.82
    cam.location = centre + cam_dir * dist
    bpy.context.view_layer.update()
    # Re-centre on the projected silhouette (perspective: shift so the prop sits mid-frame).
    inv = cam.matrix_world.inverted()
    pts = [inv @ p for p in _world_points(objs)]
    sx = [p.x / -p.z for p in pts]
    sy = [p.y / -p.z for p in pts]
    tan_half = math.tan(half)
    cd.shift_x = (min(sx) + max(sx)) / 2 / (2 * tan_half)
    cd.shift_y = (min(sy) + max(sy)) / 2 / (2 * tan_half)
    span = max(max(sx) - min(sx), max(sy) - min(sy)) / (2 * tan_half)
    if span > 0:
        target_span = 1 - 2 * pad
        cam.location = centre + cam_dir * dist * (span / target_span)
        bpy.context.view_layer.update()
        inv = cam.matrix_world.inverted()
        pts = [inv @ p for p in _world_points(objs)]
        sx = [p.x / -p.z for p in pts]
        sy = [p.y / -p.z for p in pts]
        cd.shift_x = (min(sx) + max(sx)) / 2 / (2 * tan_half)
        cd.shift_y = (min(sy) + max(sy)) / 2 / (2 * tan_half)

    restore = _isolate(objs + [ground, blob])
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    scene.render.filepath = path
    bpy.ops.render.render(write_still=True)
    restore()
    for ob, mats in swapped:
        ob.data.materials.clear()
        for m in mats:
            ob.data.materials.append(m)
    return path


def _ground_mat(color):
    # Warm, saturated sand (Theme Sand pushed toward Orange) at a lower albedo than the palette
    # value: under the bright toy rig it lands on a golden beach tone instead of a pale beige.
    albedo = tuple(v * 0.74 for v in mix(mix(color, "SandDark", 0.5), "Orange", 0.22))
    return matte_material("ChadRig_Sand", albedo, roughness=0.92)


def _contact_shadow(objs, lo, hi, strength=0.62):
    """Soft Ink blob on the ground under the parts that touch it (lowest 12% of the height), so a
    prop sits on the ground instead of floating. Not a shadow caster itself."""
    pts = [p for p in _world_points(objs) if p.z < lo.z + 0.12 * (hi.z - lo.z)] or [lo, hi]
    xs, ys = [p.x for p in pts], [p.y for p in pts]
    cx, cy = (min(xs) + max(xs)) / 2, (min(ys) + max(ys)) / 2
    rx = max((max(xs) - min(xs)) / 2, 0.05) * 1.35 + 0.08
    ry = max((max(ys) - min(ys)) / 2, 0.05) * 1.35 + 0.08
    me = bpy.data.meshes.new("ChadRig_Shadow")
    bm = bmesh.new()
    bmesh.ops.create_circle(bm, cap_ends=True, radius=1.0, segments=48)
    bm.to_mesh(me)
    bm.free()
    ob = _link(bpy.data.objects.new("ChadRig_Shadow", me))
    ob.location = (cx, cy, lo.z + 0.004 * max(rx, ry))
    ob.scale = (rx, ry, 1.0)
    ob.visible_shadow = False
    mat = bpy.data.materials.get("ChadRig_ShadowMat")
    if mat is None:
        mat = bpy.data.materials.new("ChadRig_ShadowMat")
        mat.use_nodes = True
        nt = mat.node_tree
        nt.nodes.clear()
        out = nt.nodes.new("ShaderNodeOutputMaterial")
        tc = nt.nodes.new("ShaderNodeTexCoord")
        grad = nt.nodes.new("ShaderNodeTexGradient")
        grad.gradient_type = "SPHERICAL"
        nt.links.new(tc.outputs["Object"], grad.inputs["Vector"])
        pw = nt.nodes.new("ShaderNodeMath")
        pw.operation = "POWER"
        pw.inputs[1].default_value = 1.4
        nt.links.new(grad.outputs["Fac"], pw.inputs[0])
        k = nt.nodes.new("ShaderNodeMath")
        k.operation = "MULTIPLY"
        k.inputs[1].default_value = strength
        nt.links.new(pw.outputs["Value"], k.inputs[0])
        dif = nt.nodes.new("ShaderNodeBsdfDiffuse")
        dif.inputs["Color"].default_value = (*tuple(v * 0.5 for v in lin("Ink")), 1.0)
        tr = nt.nodes.new("ShaderNodeBsdfTransparent")
        mx = nt.nodes.new("ShaderNodeMixShader")
        nt.links.new(k.outputs["Value"], mx.inputs[0])
        nt.links.new(tr.outputs[0], mx.inputs[1])
        nt.links.new(dif.outputs[0], mx.inputs[2])
        nt.links.new(mx.outputs[0], out.inputs["Surface"])
        for attr, val in (("surface_render_method", "BLENDED"), ("blend_method", "BLEND")):
            try:
                setattr(mat, attr, val)
            except (AttributeError, TypeError):
                pass
    me.materials.append(mat)
    return ob


# ------------------------------------------------------------------------------------------------
# Game mesh finisher + export
# ------------------------------------------------------------------------------------------------


def _material_color(mat):
    if mat is None:
        return lin("White")
    if "chad_color" in mat:
        return tuple(mat["chad_color"])
    if mat.node_tree and mat.node_tree.nodes.get("Principled BSDF"):
        return tuple(mat.node_tree.nodes["Principled BSDF"].inputs["Base Color"].default_value[:3])
    return tuple(mat.diffuse_color[:3])


# Multiplier for occluded vertex colours: darker, and shifted toward purple-blue.
SHADE_TINT = (0.86, 0.8, 1.0)


def _hemisphere(n):
    """Cosine-ish distributed directions (Fibonacci) on the +Z hemisphere."""
    dirs = []
    golden = math.pi * (3 - math.sqrt(5))
    for i in range(n):
        z = 1 - (i + 0.5) / n
        z = math.sqrt(z)  # bias toward the normal (cosine weighting)
        r = math.sqrt(max(0.0, 1 - z * z))
        a = golden * i
        dirs.append(Vector((r * math.cos(a), r * math.sin(a), z)))
    return dirs


def triangle_count(obj):
    dg = bpy.context.evaluated_depsgraph_get()
    ev = obj.evaluated_get(dg)
    me = ev.to_mesh()
    me.calc_loop_triangles()
    n = len(me.loop_triangles)
    ev.to_mesh_clear()
    return n


def _select_only(objs, active):
    for ob in bpy.context.view_layer.objects:
        ob.select_set(False)
    for ob in objs:
        ob.select_set(True)
    bpy.context.view_layer.objects.active = active


def finish_for_game(target, name, tri_budget=1500, tri_cap=3000, ao_strength=0.55, ao_distance=None,
                    ao_samples=48, gradient=(0.9, 1.0), ground=True, smooth_angle=None):
    """Turns a built asset into one export-ready game mesh and returns (object, triangle count).

    - applies all modifiers and transforms, joins every part into one mesh named `name`
    - triangulates; decimates (collapse) when above `tri_budget`, never ships above `tri_cap`
    - bakes the material colours, crevice-only ambient occlusion (short reach, default 8% of the
      asset size) and a gentle top-down gradient into the corner colour attribute "Col" (linear
      float; FBX writes sRGB), so it reads with depth untextured. Occluded corners shift toward a
      purple-tinted shade of the same colour instead of grey.
    - moves the origin to the base centre (min Z = 0, centred on X/Y), 1 unit = 1 stud
    - replaces all materials with vcol_material() so renders show exactly what ships
    The source objects are left untouched (hidden from render).
    """
    objs = _as_objects(target)
    dg = bpy.context.evaluated_depsgraph_get()
    parts = []
    for ob in objs:
        me = bpy.data.meshes.new_from_object(ob.evaluated_get(dg), preserve_all_data_layers=True, depsgraph=dg)
        me.transform(ob.matrix_world)
        part = _link(bpy.data.objects.new(name + "_part", me))
        parts.append(part)
        ob.hide_render = True
        ob.hide_set(True)
    _select_only(parts, parts[0])
    if len(parts) > 1:
        bpy.ops.object.join()
    obj = bpy.context.view_layer.objects.active
    obj.name = name
    obj.data.name = name

    tri = obj.modifiers.new("Tri", "TRIANGULATE")
    tri.quad_method = "BEAUTY"
    tri.ngon_method = "BEAUTY"
    _select_only([obj], obj)
    bpy.ops.object.modifier_apply(modifier=tri.name)
    tris = len(obj.data.polygons)
    if tris > tri_budget:
        # Collapse decimation loses custom normals; re-derive them after.
        for _ in range(4):
            dec = obj.modifiers.new("Dec", "DECIMATE")
            dec.decimate_type = "COLLAPSE"
            dec.ratio = max(0.05, tri_budget / tris * 0.98)
            dec.use_collapse_triangulate = True
            bpy.ops.object.modifier_apply(modifier=dec.name)
            tris = len(obj.data.polygons)
            if tris <= tri_budget:
                break
        shade_smooth(obj, smooth_angle or 40.0)
        wn = obj.modifiers.new("ChadWeighted", "WEIGHTED_NORMAL")
        wn.keep_sharp = True
        bpy.ops.object.modifier_apply(modifier=wn.name)
    elif smooth_angle is not None:
        shade_smooth(obj, smooth_angle)
    if tris > tri_cap:
        raise RuntimeError("chadkit: %s has %d triangles (hard cap %d)" % (name, tris, tri_cap))

    me = obj.data
    # Origin at the base centre.
    xs = [v.co.x for v in me.vertices]
    ys = [v.co.y for v in me.vertices]
    zs = [v.co.z for v in me.vertices]
    me.transform(Matrix.Translation((-(min(xs) + max(xs)) / 2, -(min(ys) + max(ys)) / 2, -min(zs))))
    obj.matrix_world = Matrix.Identity(4)
    height = max(zs) - min(zs)
    size = max(max(xs) - min(xs), max(ys) - min(ys), height)

    # Soft ambient occlusion per vertex (BVH ray casts) + an optional ground plane at z = 0.
    verts = [v.co.copy() for v in me.vertices]
    polys = [tuple(p.vertices) for p in me.polygons]
    bvh = BVHTree.FromPolygons(verts, polys, all_triangles=True)
    maxd = ao_distance or size * 0.08
    dirs = _hemisphere(ao_samples)
    ao = []
    for v in me.vertices:
        n = v.normal.normalized()
        t = n.orthogonal().normalized()
        b = n.cross(t)
        origin = v.co + n * (size * 0.002)
        occl = 0.0
        for d in dirs:
            w = t * d.x + b * d.y + n * d.z
            hit = bvh.ray_cast(origin, w, maxd)
            dist = hit[3] if hit[0] is not None else None
            if ground and w.z < -1e-4:
                gd = -origin.z / w.z
                if gd >= 0 and (dist is None or gd < dist) and gd < maxd:
                    dist = gd
            if dist is not None:
                occl += 1.0 - (dist / maxd) ** 0.5 * 0.6
        ao.append(1.0 - ao_strength * min(1.0, occl / len(dirs) * 1.6))

    base = [_material_color(s.material) for s in obj.material_slots] or [lin("White")]
    g0, g1 = gradient
    colours = [0.0] * (len(me.loops) * 4)
    for p in me.polygons:
        c = base[min(p.material_index, len(base) - 1)]
        dark = tuple((x ** 1.2) * 0.6 * t for x, t in zip(c, SHADE_TINT))  # cool saturated shade
        for li in p.loop_indices:
            vi = me.loops[li].vertex_index
            a = ao[vi]
            h = (verts[vi].z / height) if height > 0 else 1.0
            g = g0 + (g1 - g0) * (h ** 0.7)
            for k in range(3):
                colours[li * 4 + k] = (dark[k] + (c[k] - dark[k]) * a) * g
            colours[li * 4 + 3] = 1.0
    for attr in list(me.color_attributes):
        me.color_attributes.remove(attr)
    col = me.color_attributes.new("Col", "FLOAT_COLOR", "CORNER")
    col.data.foreach_set("color", colours)
    me.color_attributes.active_color = col
    me.color_attributes.render_color_index = 0

    me.materials.clear()
    me.materials.append(vcol_material())
    obj["chad_tris"] = tris
    obj["chad_size"] = [max(xs) - min(xs), max(ys) - min(ys), height]
    return obj, tris


def export_fbx(obj, path):
    """Writes `obj` as FBX for the Roblox 3D importer: Y up, -Z forward (Blender -Y = Roblox front),
    transforms baked, vertex colours as sRGB, 1 Blender unit = 1 stud.

    Roblox reads FBX centimetres as studs, so the scene unit is set to centimetres for the export
    (UnitScaleFactor 1) and restored afterwards."""
    scene = bpy.context.scene
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    old = scene.unit_settings.scale_length
    scene.unit_settings.scale_length = 0.01
    _select_only([obj], obj)
    try:
        bpy.ops.export_scene.fbx(
            filepath=path, use_selection=True, object_types={"MESH"}, axis_forward="-Z", axis_up="Y",
            apply_unit_scale=True, apply_scale_options="FBX_SCALE_NONE", global_scale=1.0,
            bake_space_transform=True, use_mesh_modifiers=True, mesh_smooth_type="FACE",
            colors_type="SRGB", prioritize_active_color=True, use_triangles=True, add_leaf_bones=False,
            path_mode="STRIP", embed_textures=False)
    finally:
        scene.unit_settings.scale_length = old
    return path


# ------------------------------------------------------------------------------------------------
# Pillow side (system python3)
# ------------------------------------------------------------------------------------------------

_PY = None


def _pillow_python():
    global _PY
    if _PY:
        return _PY
    env = _clean_env()
    for cand in (os.environ.get("CHADKIT_PYTHON"), "/usr/bin/python3", "/opt/homebrew/bin/python3", "python3"):
        if not cand:
            continue
        try:
            r = subprocess.run([cand, "-c", "import PIL"], env=env, capture_output=True, timeout=30)
        except (OSError, subprocess.TimeoutExpired):
            continue
        if r.returncode == 0:
            _PY = cand
            return cand
    raise RuntimeError("chadkit: no python3 with Pillow found (set CHADKIT_PYTHON)")


def _clean_env():
    env = dict(os.environ)
    for k in ("PYTHONHOME", "PYTHONPATH", "PYTHONNOUSERSITE"):
        env.pop(k, None)
    return env


def run_pillow(args):
    """Runs `python3 chadkit.py <args>` under a Pillow-capable system python."""
    r = subprocess.run([_pillow_python(), os.path.abspath(__file__)] + list(args), env=_clean_env(),
                       capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError("chadkit pillow step failed: %s\n%s" % (args, r.stderr[-2000:]))
    return r.stdout


def _dilate(alpha, radius):
    """Exact round dilation of a float alpha array (0..1) by `radius` pixels, anti-aliased: the
    outline has the same thickness everywhere (thin tips, flat sides and corners alike)."""
    import numpy as np

    r = float(radius)
    ri = int(math.ceil(r + 0.5))
    h, w = alpha.shape
    padded = np.zeros((h + 2 * ri, w + 2 * ri), dtype=np.float32)
    padded[ri:ri + h, ri:ri + w] = alpha
    out = alpha.astype(np.float32).copy()
    for dy in range(-ri, ri + 1):
        for dx in range(-ri, ri + 1):
            wgt = min(1.0, max(0.0, r + 0.5 - math.hypot(dx, dy)))
            if wgt <= 0:
                continue
            shifted = padded[ri + dy:ri + dy + h, ri + dx:ri + dx + w]
            np.maximum(out, shifted * wgt if wgt < 1 else shifted, out=out)
    return out


def sticker(src, dst, outline=0.028, shadow=True, outline_rgb=(255, 255, 255), shadow_rgb=None,
            shadow_alpha=0.32, halo=None, halo_strength=0.7):
    """Adds a thick round white sticker outline (exactly outline x size px everywhere), a soft Ink
    drop shadow and an optional soft coloured `halo` (0..255 rgb) glow to a transparent icon."""
    import numpy as np
    from PIL import Image, ImageFilter

    im = Image.open(src).convert("RGBA")
    w, h = im.size
    a = np.asarray(im.getchannel("A"), dtype=np.float32) / 255.0
    # Ignore faint semi-transparent fringe so the outline hugs the solid silhouette.
    solid = np.clip((a - 0.08) / 0.84, 0.0, 1.0)
    px = outline * max(w, h)
    sil = _dilate(solid, px) if outline > 0 else a
    sil = np.maximum(sil, a)
    sil_img = Image.fromarray((sil * 255).astype(np.uint8), "L")
    canvas = Image.new("RGBA", im.size, (0, 0, 0, 0))
    if halo:
        glow = sil_img.filter(ImageFilter.GaussianBlur(0.04 * w))
        g = np.asarray(glow, dtype=np.float32) / 255.0
        g = np.clip(g * 1.6, 0, 1) * halo_strength
        layer = Image.new("RGBA", im.size, tuple(halo) + (0,))
        layer.putalpha(Image.fromarray((g * 255).astype(np.uint8), "L"))
        canvas.alpha_composite(layer)
    if shadow:
        srgb_shadow = shadow_rgb or PALETTE.get("Ink", (58, 48, 96))
        sh = sil_img.filter(ImageFilter.GaussianBlur(max(1.0, 0.012 * w)))
        sh = sh.point(lambda v: int(v * shadow_alpha))
        layer = Image.new("RGBA", im.size, tuple(srgb_shadow) + (0,))
        layer.putalpha(sh)
        canvas.alpha_composite(layer, (0, int(round(0.022 * h))))
    if outline > 0:
        ring = Image.new("RGBA", im.size, tuple(outline_rgb) + (0,))
        ring.putalpha(sil_img)
        canvas.alpha_composite(ring)
    canvas.alpha_composite(im)
    canvas.save(dst)
    return dst


def _font(size, bold=True):
    from PIL import ImageFont

    for p in (FONT_PATH, FONT_BLACK, "/System/Library/Fonts/Helvetica.ttc"):
        if os.path.exists(p):
            try:
                return ImageFont.truetype(p, size)
            except OSError:
                continue
    return ImageFont.load_default()


def contact_sheet(paths, out=None, cols=4, labels=None, cell=256, bg=(52, 70, 138), title=None,
                  label_rgb=(255, 255, 255), gap=16, fit="contain"):
    """Grid of images (paths or Pillow images; transparent icons composite onto `bg`), each scaled into a `cell` square
    (or (w, h) tuple), optional label under each and a title on top. Returns the Pillow image and
    saves it when `out` is given."""
    from PIL import Image, ImageDraw

    cw, ch = (cell, cell) if isinstance(cell, int) else cell
    n = len(paths)
    cols = max(1, min(cols, n))
    rows = (n + cols - 1) // cols
    label_h = int(max(14, min(cw, 256) * 0.11)) if labels else 0
    title_h = 48 if title else 0
    W = cols * cw + (cols + 1) * gap
    H = title_h + rows * (ch + label_h) + (rows + 1) * gap
    sheet = Image.new("RGBA", (W, H), tuple(bg) + (255,))
    d = ImageDraw.Draw(sheet)
    if title:
        d.text((gap, 12), title, font=_font(28), fill=label_rgb)
    lf = _font(max(11, int(label_h * 0.72))) if labels else None
    for i, p in enumerate(paths):
        r, c = divmod(i, cols)
        x = gap + c * (cw + gap)
        y = title_h + gap + r * (ch + label_h + gap)
        im = p.convert("RGBA") if hasattr(p, "convert") else Image.open(p).convert("RGBA")
        scale = min(cw / im.width, ch / im.height) if fit == "contain" else max(cw / im.width, ch / im.height)
        im = im.resize((max(1, int(im.width * scale)), max(1, int(im.height * scale))), Image.LANCZOS)
        if fit != "contain":
            left, top = (im.width - cw) // 2, (im.height - ch) // 2
            im = im.crop((left, top, left + cw, top + ch))
        sheet.alpha_composite(im, (x + (cw - im.width) // 2, y + (ch - im.height) // 2))
        if labels and i < len(labels) and labels[i]:
            tw = d.textlength(labels[i], font=lf)
            d.text((x + (cw - tw) / 2, y + ch + 2), labels[i], font=lf, fill=label_rgb)
    if out:
        os.makedirs(os.path.dirname(os.path.abspath(out)), exist_ok=True)
        sheet.convert("RGB").save(out)
    return sheet


def inset_image(main, inset, scale=0.36, label=None, border=4, bg=(255, 255, 255)):
    """Returns a copy of `main` with `inset` (paths or Pillow images) scaled to `scale` of its width
    in the bottom-right corner, in a white frame with an optional small label above it."""
    from PIL import Image, ImageDraw

    m = (main if hasattr(main, "convert") else Image.open(main)).convert("RGBA")
    i = (inset if hasattr(inset, "convert") else Image.open(inset)).convert("RGBA")
    w = int(m.width * scale)
    i = i.resize((w, int(i.height * w / i.width)), Image.LANCZOS)
    margin = int(m.width * 0.025)
    x, y = m.width - w - margin, m.height - i.height - margin
    d = ImageDraw.Draw(m)
    d.rounded_rectangle((x - border, y - border, x + w + border, y + i.height + border), radius=border * 2,
                        fill=tuple(bg) + (255,))
    m.alpha_composite(i, (x, y))
    if label:
        f = _font(max(12, int(m.width * 0.04)))
        tw = d.textlength(label, font=f)
        th = int(m.width * 0.05)
        d.rounded_rectangle((x - border, y - border - th, x - border + tw + 12, y - border), radius=border * 2,
                            fill=tuple(bg) + (255,))
        d.text((x - border + 6, y - border - th + 2), label, font=f, fill=PALETTE.get("Ink", (58, 48, 96)))
    return m


def stack_images(images, out=None, bg=(52, 70, 138), gap=0, direction="vertical", max_side=None):
    """Stacks Pillow images (or paths) vertically or horizontally; optional downscale to max_side."""
    from PIL import Image

    ims = [Image.open(i).convert("RGBA") if isinstance(i, str) else i for i in images]
    if direction == "vertical":
        W = max(i.width for i in ims)
        H = sum(i.height for i in ims) + gap * (len(ims) - 1)
    else:
        W = sum(i.width for i in ims) + gap * (len(ims) - 1)
        H = max(i.height for i in ims)
    sheet = Image.new("RGBA", (W, H), tuple(bg) + (255,))
    pos = 0
    for i in ims:
        if direction == "vertical":
            sheet.alpha_composite(i, (0, pos))
            pos += i.height + gap
        else:
            sheet.alpha_composite(i, (pos, 0))
            pos += i.width + gap
    if max_side and max(sheet.size) > max_side:
        s = max_side / max(sheet.size)
        sheet = sheet.resize((int(sheet.width * s), int(sheet.height * s)), Image.LANCZOS)
    if out:
        os.makedirs(os.path.dirname(os.path.abspath(out)), exist_ok=True)
        sheet.convert("RGB").save(out)
    return sheet


def _main(argv):
    import argparse

    ap = argparse.ArgumentParser(prog="chadkit")
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("sticker", help="white sticker outline + drop shadow for an icon")
    s.add_argument("src")
    s.add_argument("dst")
    s.add_argument("--outline", type=float, default=0.028)
    s.add_argument("--no-shadow", action="store_true")
    s.add_argument("--halo", default="", help="r,g,b glow colour behind the sticker")
    s.add_argument("--halo-strength", type=float, default=0.7)
    c = sub.add_parser("sheet", help="simple contact sheet")
    c.add_argument("out")
    c.add_argument("paths", nargs="+")
    c.add_argument("--cols", type=int, default=4)
    c.add_argument("--cell", type=int, default=256)
    c.add_argument("--labels", default="", help="comma-separated labels")
    a = ap.parse_args(argv)
    if a.cmd == "sticker":
        halo = tuple(int(v) for v in a.halo.split(",")) if a.halo else None
        sticker(a.src, a.dst, a.outline, not a.no_shadow, halo=halo, halo_strength=a.halo_strength)
    elif a.cmd == "sheet":
        labels = a.labels.split(",") if a.labels else None
        contact_sheet(a.paths, a.out, a.cols, labels, a.cell)


if __name__ == "__main__" and not IN_BLENDER:
    _main(sys.argv[1:])
