"""Shared building blocks for the shop and reward icons (icons-shop set).

Puts art/blender/lib on sys.path, defines the output folder (art/out/icons) and the reusable toy
parts: coins, coin heaps, cash bundles, money bags, gems, aura orbs, sparkles, bold 3D text with a
coloured backing layer, crowns (crown, crown_tall) and the treasure crate. Every builder returns plain objects or a
parent empty positioned with pose(); the icon scripts only compose them.
"""

import math
import os
import random
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "lib"))

import bpy  # noqa: E402
from mathutils import Matrix, Vector  # noqa: E402

import chadkit as ck  # noqa: E402
import theme_palette  # noqa: E402

theme_palette.fill(ck)  # Theme.World keys written as Luau constants (Sunny, Coral, White, ...)

OUT = os.path.join(ck.ROOT, "art", "out", "icons")
os.makedirs(OUT, exist_ok=True)

# Same framing as the proof icons (render_icon defaults: azimuth 28, elevation 20).
CAM_AZ, CAM_EL = 28.0, 20.0

_mats = {}


def reset():
    """Fresh scene and material cache for the next icon."""
    ck.reset_scene()
    _mats.clear()


def M(color, **kw):
    """Cached toy material for a palette name / colour tuple (+ toy_material overrides)."""
    key = (repr(color), tuple(sorted(kw.items())))
    if key not in _mats:
        _mats[key] = ck.toy_material("M%d" % len(_mats), color, **kw)
    return _mats[key]


def pose(parts, location=(0, 0, 0), rotation=(0, 0, 0), scale=1.0, name="Pose"):
    """Parents `parts` to an empty at `location` / `rotation` (degrees) / uniform `scale`."""
    e = ck.group(parts, name, location=location, rotation=rotation)
    e.scale = (scale, scale, scale)
    return e


def facing(ob, azimuth=CAM_AZ, elevation=CAM_EL):
    """Turns an object built facing +Z so it faces the camera direction (azimuth, elevation)."""
    d = ck._view_dir(azimuth, elevation)
    ob.rotation_mode = "QUATERNION"
    ob.rotation_quaternion = d.to_track_quat("Z", "Y")
    return ob


def bake_matrix(ob, m):
    """Applies matrix `m` to the mesh data (modifiers such as the soft bevel stay live)."""
    ob.data.transform(m)
    return ob


# Local x -> world Y, local y -> world Z, local z (extrusion) -> world X.
TO_YZ = Matrix(((0, 0, 1, 0), (1, 0, 0, 0), (0, 1, 0, 0), (0, 0, 0, 1)))
# Local x -> world X, local y -> world Z, local z (extrusion) -> world -Y (toward the viewer).
TO_XZ = Matrix(((1, 0, 0, 0), (0, 0, -1, 0), (0, 1, 0, 0), (0, 0, 0, 1)))


def arc(cx, cz, r, a0, a1, steps=4):
    return [(cx + r * math.cos(math.radians(a0 + (a1 - a0) * k / steps)),
             cz + r * math.sin(math.radians(a0 + (a1 - a0) * k / steps))) for k in range(steps + 1)]


# ------------------------------------------------------------------------------------------------
# Text
# ------------------------------------------------------------------------------------------------

def text_layer(body, size, depth, bevel, mat, offset=0.0, font=ck.FONT_PATH, name="Text"):
    """Like ck.text_mesh but with the curve `offset` (grows the glyphs: backing outline layers)."""
    cu = bpy.data.curves.new(name, "FONT")
    cu.body = body
    cu.font = bpy.data.fonts.load(font, check_existing=True)
    cu.size = size
    cu.extrude = depth / 2
    cu.bevel_depth = bevel
    cu.bevel_resolution = 4
    cu.offset = offset
    cu.resolution_u = 8
    cu.align_x = "CENTER"
    cu.align_y = "CENTER"
    cu.space_character = 0.92
    tmp = ck._link(bpy.data.objects.new(name + "_curve", cu))
    dg = bpy.context.evaluated_depsgraph_get()
    me = bpy.data.meshes.new_from_object(tmp.evaluated_get(dg), depsgraph=dg)
    bpy.data.objects.remove(tmp, do_unlink=True)
    ob = ck._link(bpy.data.objects.new(name, me))
    me.materials.append(mat)
    ck.shade_smooth(ob, 35.0)
    return ob


def bold_text(body, size=1.0, face="White", back="HotPink", depth=0.34, outline=0.075, font=ck.FONT_PATH):
    """Chunky 3D label: a bevelled `face` layer in front of a thicker, wider `back` layer that reads
    as a coloured outline all round the glyphs. Built facing +Z, centred on the face layer's bounds."""
    front = text_layer(body, size, depth * 0.55, 0.035 * size, M(face), 0.0, font, "TextFace")
    rear = text_layer(body, size, depth, 0.03 * size, M(back), outline * size, font, "TextBack")
    # Centre both on the front layer's X/Y bounds; the backing sits behind (-Z).
    xs = [v.co.x for v in front.data.vertices]
    ys = [v.co.y for v in front.data.vertices]
    shift = Matrix.Translation((-(min(xs) + max(xs)) / 2, -(min(ys) + max(ys)) / 2, 0))
    front.data.transform(shift)
    rear.data.transform(Matrix.Translation((-(min(xs) + max(xs)) / 2, -(min(ys) + max(ys)) / 2,
                                            -depth * 0.32)))
    return [front, rear]


def x2_badge(location, size=1.0, face="White", back="HotPink", azimuth=12.0, elevation=14.0):
    """The bold "x2" label, turned toward the camera but a little less than it, so its thickness shows."""
    e = pose(bold_text("x2", size, face, back), location, name="X2")
    facing(e, azimuth, elevation)
    return e


# ------------------------------------------------------------------------------------------------
# Sparkles and gloss
# ------------------------------------------------------------------------------------------------

def sparkle(location, size=0.4, color=None):
    """Chunky four-point sparkle (rounded tips) facing the camera, unparented (world space)."""
    col = color or ck.mix("Sunny", "White", 0.45)
    s = ck.extrude_shape(ck.star_points(4, size, size * 0.36, round_steps=2, rotate=90), depth=size * 0.34,
                         mat=M(col, emission=0.6), name="Sparkle", bevel=size * 0.11)
    s.location = location
    facing(s, CAM_AZ, CAM_EL)
    return s


def streak_on_sphere(centre, r, angles, polar=55.0, width=None, lift=0.02):
    """Gloss streak hugging a sphere of radius r: `angles` are azimuths (deg, around the camera
    view's upper-left), `polar` the angle from the top."""
    pts, c = [], Vector(centre)
    for a in angles:
        aa, pp = math.radians(a), math.radians(polar)
        n = Vector((math.sin(pp) * math.cos(aa), math.sin(pp) * math.sin(aa), math.cos(pp)))
        pts.append(c + n * (r + lift))
    mid = (pts[len(pts) // 2] - c).normalized()
    return ck.gloss_streak(pts, width or r * 0.16, mid)


# ------------------------------------------------------------------------------------------------
# Coins and cash
# ------------------------------------------------------------------------------------------------

def coin_profile(r=0.86, t=0.17):
    k = r / 0.86
    p = [(0, -t), (0.4 * k, -t + 0.015), (0.68 * k, -t + 0.05), (0.76 * k, -t + 0.02)]
    rr = 0.13 * k
    p += arc(r, -t + rr, rr, -110, 0)
    p += arc(r, t - rr, rr, 0, 110)
    p += [(0.76 * k, t - 0.02), (0.68 * k, t - 0.05), (0.4 * k, t - 0.015), (0, t)]
    return p


def coin(r=0.86, sign=True, streak=True, segments=56):
    """Gold coin lying flat (faces +Z), centred on the origin, embossed "$" and a gloss streak."""
    t = 0.17 * r / 0.86
    parts = [ck.lathe(coin_profile(r, t), segments, M("Sunny"), "Coin", smooth_angle=50)]
    if sign:
        s = ck.text_mesh("$", size=1.1 * r / 0.86, depth=0.12 * r / 0.86, bevel=0.035 * r / 0.86,
                         mat=M("GoldDeep"), name="Dollar", font=ck.FONT_BLACK)
        s.location = (0, 0, t - 0.01)
        parts.append(s)
    if streak:
        k = r / 0.86
        parts.append(ck.gloss_streak([(0.56 * k * math.cos(math.radians(a)), 0.56 * k * math.sin(math.radians(a)),
                                       t - 0.02) for a in (104, 118, 132, 146, 160)], 0.11 * k, (0, 0, 1)))
    return parts


def standing_coin(location, r=0.86, turn=14.0, tilt=78.0, sign=True):
    """A coin stood up to face the viewer (like the HUD coin)."""
    return pose(coin(r, sign), location, (tilt, 0, turn), name="StandingCoin")


def coin_stack(location, n, r=0.62, jitter=0.05, seed=1, top_sign=True):
    """A neat stack of n flat coins with a little sideways jitter."""
    rng = random.Random(seed)
    t = 0.17 * r / 0.86
    parts = []
    for i in range(n):
        top = i == n - 1
        cp = coin(r, sign=top and top_sign, streak=top, segments=40)
        e = pose(cp, (rng.uniform(-jitter, jitter), rng.uniform(-jitter, jitter), t + i * 2 * t * 0.96),
                 (0, 0, rng.uniform(0, 360)))
        parts.append(e)
    return pose(parts, location, name="CoinStack")


def heap(location, radius, height, n_coins, seed=3, coin_r=0.36, mound_color="Sunny", ry=1.0):
    """A mound of gold with coins lying all over its surface (piles, chest fillings, the vault).
    `ry` squashes the footprint along Y (chest fillings) without squashing the coins."""
    rng = random.Random(seed)
    prof = []
    for k in range(13):
        u = k / 12
        prof.append((radius * (1 - u) ** 0.9 if u < 1 else 0, height * math.sin(u * math.pi / 2) ** 0.8))
    # Profile goes from the rim (u=0) to the top pole: reorder bottom -> top for the lathe.
    prof = [(0, 0.0)] + prof
    mound = ck.lathe(prof, 40, M(mound_color), "Mound", smooth_angle=80)
    mound.scale = (1.0, ry, 1.0)
    parts = [mound]
    for i in range(n_coins):
        # Even-ish coverage: golden-angle spiral over the mound, slightly randomised.
        frac = math.sqrt((i + 0.5) / n_coins)
        rho = min(0.97, frac + rng.uniform(-0.04, 0.04))
        th = i * 2.39996 + rng.uniform(-0.2, 0.2)
        u = 1 - rho  # 0 at rim, 1 at top (matches the profile)
        z = height * math.sin(u * math.pi / 2) ** 0.8
        rad = radius * (1 - u) ** 0.9
        # Surface normal from the profile slope.
        du = 0.02
        z2 = height * math.sin(min(1, u + du) * math.pi / 2) ** 0.8
        r2 = radius * (1 - min(1, u + du)) ** 0.9
        dr, dz = r2 - rad, z2 - z
        n_r, n_z = dz, -dr  # outward normal in the (r, z) plane
        nl = math.hypot(n_r, n_z) or 1.0
        n = Vector((math.cos(th) * n_r / nl, math.sin(th) * n_r / nl, n_z / nl))
        n = (n + Vector((rng.uniform(-0.35, 0.35), rng.uniform(-0.35, 0.35), rng.uniform(0, 0.3)))).normalized()
        cr = coin_r * rng.uniform(0.85, 1.12)
        c = pose(coin(cr, sign=rng.random() < 0.3, streak=False, segments=28),
                 (math.cos(th) * rad, math.sin(th) * rad * ry, z + 0.03), name="HeapCoin")
        c.rotation_mode = "QUATERNION"
        c.rotation_quaternion = n.to_track_quat("Z", "Y")
        parts.append(c)
    return pose(parts, location, name="Heap")


def gold_heap(location, radius, height, coins, ry=1.0, mound_color="Sunny", streak=True):
    """Smooth gold mound with a few big chunky coins resting on it (reads as one blob of gold at 48 px).
    `coins` = list of (azimuth deg, u 0 rim..1 top, coin radius, extra tilt deg); azimuth -62 faces
    the camera. `ry` squashes the footprint along Y (chest fillings) without squashing the coins."""
    def surf(u):
        return radius * (1 - u) ** 0.9 if u < 1 else 0.0, height * math.sin(u * math.pi / 2) ** 0.8

    prof = [(0, 0.0)] + [surf(k / 16) for k in range(17)]
    mound = ck.lathe(prof, 48, M(mound_color), "Mound", smooth_angle=80)
    mound.scale = (1.0, ry, 1.0)
    parts = [mound]
    for az, u, cr, tilt in coins:
        th = math.radians(az)
        rad, z = surf(u)
        r2, z2 = surf(min(1.0, u + 0.02))
        n_r, n_z = z2 - z, -(r2 - rad)
        nl = math.hypot(n_r, n_z) or 1.0
        n = Vector((math.cos(th) * n_r / nl, math.sin(th) * n_r / nl * ry, n_z / nl)).normalized()
        # Lean each coin a little toward the camera so its face and "$" read.
        n = (n + Vector((0.0, -math.radians(tilt), 0.0))).normalized()
        c = pose(coin(cr, sign=True, streak=True, segments=40),
                 (math.cos(th) * rad, math.sin(th) * rad * ry, z + 0.04), name="HeapCoin")
        c.rotation_mode = "QUATERNION"
        c.rotation_quaternion = n.to_track_quat("Z", "Y")
        parts.append(c)
    if streak:
        pts = []
        for a in (-150, -138, -126, -114):
            u = 0.42
            rad, z = surf(u)
            pts.append((rad * math.cos(math.radians(a)) * 1.01, rad * math.sin(math.radians(a)) * ry * 1.01,
                        z + 0.02))
        parts.append(ck.gloss_streak(pts, radius * 0.1, (-0.5, -0.5, 0.7)))
    return pose(parts, location, name="GoldHeap")


def view_streak(ob, uvs, width, view=None, lift=0.02):
    """Gloss streak painted onto `ob` (mesh at identity transform) where rays from the camera view hit
    it: `uvs` are (right, up) offsets in the view plane through the object origin."""
    d = view or ck._view_dir(CAM_AZ, CAM_EL)
    right = Vector((0, 0, 1)).cross(d).normalized()
    up = d.cross(right).normalized()
    pts, nrms = [], []
    for u, v in uvs:
        o = right * u + up * v + d * 20
        hit, loc, nrm, _ = ob.ray_cast(o, -d)
        if hit:
            pts.append(loc + nrm * lift)
            nrms.append(nrm)
    if len(pts) < 2:
        return None
    n = sum(nrms, Vector()).normalized()
    return ck.gloss_streak(pts, width, n)


def blob(name, chains, mat, resolution=0.035):
    """Metaball blob converted to a mesh: `chains` = lists of ((x, y, z), radius) balls. Gives round,
    soft shapes (flames) with naturally rounded tips."""
    mb = bpy.data.metaballs.new(name)
    mb.resolution = resolution
    mb.render_resolution = resolution
    mb.threshold = 0.6
    for chain in chains:
        for co, r in chain:
            el = mb.elements.new()
            el.co = co
            el.radius = r
    tmp = ck._link(bpy.data.objects.new(name, mb))
    bpy.context.view_layer.update()
    dg = bpy.context.evaluated_depsgraph_get()
    me = bpy.data.meshes.new_from_object(tmp.evaluated_get(dg), depsgraph=dg)
    bpy.data.objects.remove(tmp, do_unlink=True)
    ob = ck._link(bpy.data.objects.new(name + "_mesh", me))
    me.materials.append(mat)
    ck.shade_smooth(ob, 180.0)
    return ob


def bill_stack(location, n=5, size=(1.3, 0.72), rotation=(0, 0, 0), seed=5, scale=1.0):
    """Bundle of green bills with a white paper band."""
    rng = random.Random(seed)
    th = 0.12
    parts = []
    for i in range(n):
        col = "Mint" if i % 2 == 0 else ck.mix("Mint", "Emerald", 0.35)
        b = ck.rounded_box((size[0], size[1], th), 0.045, 2, M(col), "Bill", (0, 0, i * th * 0.92))
        b.rotation_euler = (0, 0, math.radians(rng.uniform(-3, 3)))
        parts.append(b)
    top = (n - 1) * th * 0.92 + th
    # Pale oval print on the top bill.
    oval = ck.lathe(ck.round_profile(0, 0.2, 0, 0.03, 0.012, 2), 28, M(ck.mix("Mint", "White", 0.55)), "Print",
                    location=(0, 0, top - 0.01))
    oval.scale = (1.0, 0.82, 1.0)
    band = ck.rounded_box((0.3, size[1] + 0.06, top + 0.05), 0.05, 2, M("Cream"), "Band", (0, 0, -0.025))
    parts += [oval, band]
    return pose(parts, location, rotation, scale, name="Bills")


def money_bag(location, scale=1.0, color="Mint", rope="Sunny", sign_color="Sunny", rotation=(0, 0, 0),
              ruffle=True):
    """Round sack pinched at the neck, ruffled top, rope tie and a bold "$" on the front."""
    prof = [(0, 0.0), (0.55, 0.02), (0.88, 0.16), (1.06, 0.45), (1.1, 0.72), (1.02, 1.0), (0.82, 1.26),
            (0.52, 1.46), (0.36, 1.56), (0.34, 1.62)]
    if ruffle:
        prof += [(0.46, 1.72), (0.62, 1.86), (0.66, 1.96), (0.56, 2.04), (0.34, 2.03), (0, 2.0)]
    else:
        prof += [(0.4, 1.7), (0.3, 1.78), (0, 1.8)]
    sack = ck.lathe(prof, 48, M(color), "Sack", smooth_angle=70)
    if ruffle:
        for v in sack.data.vertices:
            if v.co.z > 1.66:
                a = math.atan2(v.co.y, v.co.x)
                w = min(1.0, (v.co.z - 1.66) / 0.3)
                f = 1 + 0.16 * w * math.sin(7 * a)
                v.co.x *= f
                v.co.y *= f
    tie = ck.torus(0.4, 0.1, 32, 10, mat=M(rope), name="Rope", location=(0, 0, 1.6))
    knot = ck.sphere(0.15, 16, 8, M(rope), "Knot", (0.12, -0.38, 1.58))
    sign = bold_text("$", 1.0, sign_color, ck.mix(color, "Emerald", 0.6) if color == "Mint" else "GrapeDeep",
                     depth=0.3, outline=0.05, font=ck.FONT_BLACK)
    se = pose(sign, (0, -1.17, 0.68), (90, 0, 0), name="BagSign")
    gl = ck.gloss_streak([(-0.62, -0.78, 1.1), (-0.8, -0.62, 0.9), (-0.92, -0.42, 0.66)], 0.13,
                         (-0.6, -0.6, 0.3))
    return pose([sack, tie, knot, se, gl], location, rotation, scale, name="Bag")


# ------------------------------------------------------------------------------------------------
# Gems and orbs
# ------------------------------------------------------------------------------------------------

GEM_BLUE = [(0.0, ck.mix("BlueDeep", "Blue", 0.45)), (0.42, "Blue"), (0.72, "CyanPop"),
            (1.0, ck.mix("CyanPop", "White", 0.35))]
GEM_PINK = [(0.0, ck.mix("HotPink", "Grape", 0.45)), (0.45, "HotPink"), (0.75, ck.mix("HotPink", "Pink", 0.5)),
            (1.0, ck.mix("Pink", "White", 0.4))]
GEM_GREEN = [(0.0, "Emerald"), (0.45, ck.mix("Emerald", "Mint", 0.5)), (0.75, "Mint"),
             (1.0, ck.mix("Mint", "White", 0.4))]
# "vivid": the saturated blue-cyan used by every gem pack, with one pale highlight facet.
GEM_VIVID = [(0.0, "BlueDeep"), (0.38, ck.mix("Blue", "CyanPop", 0.35)), (0.7, "CyanPop"),
             (1.0, ck.mix("CyanPop", "White", 0.22))]
GEM_TABLE = {"blue": ck.mix("CyanPop", "White", 0.72), "pink": ck.mix("Pink", "White", 0.6),
             "green": ck.mix("Mint", "White", 0.6), "vivid": ck.mix("CyanPop", "White", 0.62)}
_gem_mats = {}


def gem(location, scale=1.0, rotation=(-10, 0, 0), kind="blue", streak=None):
    """The proof brilliant-cut gem (blue = the Rizz gem currency), as a posable empty. kind "vivid"
    paints the front-left crown facet pale cyan (a crisp highlight facet) instead of a gloss streak."""
    top, bottom = 0.62, -1.18
    vivid = kind == "vivid"
    if streak is None:
        streak = not vivid
    key = kind
    if key not in _gem_mats or _gem_mats[key][0].name not in bpy.data.materials:
        stops = {"blue": GEM_BLUE, "pink": GEM_PINK, "green": GEM_GREEN, "vivid": GEM_VIVID}[kind]
        body = ck.gradient_material("GemBody_" + kind, stops, lo=bottom, hi=top, roughness=0.16, coat=0.85)
        table = ck.toy_material("GemTable_" + kind, GEM_TABLE[kind], roughness=0.15, coat=0.8, emission=0.25)
        facet = ck.toy_material("GemFacet_" + kind, ck.mix("CyanPop", "White", 0.8), roughness=0.1, coat=0.9,
                                emission=0.45)
        _gem_mats[key] = (body, table, facet)
    body, table, facet = _gem_mats[key]
    g = ck.lathe([(0, bottom), (0.13, bottom + 0.06), (0.86, 0.0), (0.86, 0.15), (0.5, top), (0, top)],
                 segments=8, mat=body, name="Gem")
    g.data.materials.append(table)
    g.data.materials.append(facet)
    for p in g.data.polygons:
        p.material_index = 1 if p.center.z > top - 0.01 else 0
        if vivid and 0.2 < p.center.z < top - 0.01:
            az = math.degrees(math.atan2(p.center.y, p.center.x))
            if abs(az + 112.5) < 10:  # world -101.25 deg after the 11.25 deg turn: front-left
                p.material_index = 2
    ck.shade_flat(g)
    ck.soften(g, width=0.03, segments=2, limit_angle=10.0, weighted=True)
    ck.shade_flat(g)
    g.rotation_euler = (0.0, 0.0, 0.3927 / 2)
    parts = [g]
    if streak:
        fa = math.radians(-101.25)
        fn = Vector((math.cos(fa), math.sin(fa), 0.0))
        normal = Vector((fn.x * 0.62, fn.y * 0.62, 0.36)).normalized()
        inset = math.cos(math.radians(22.5))

        def on_crown(t, lift=0.025):
            r, z = 0.86 + (0.5 - 0.86) * t, top * t
            return fn * (r * inset) + Vector((0, 0, z)) + normal * lift

        parts.append(ck.gloss_streak([on_crown(t) for t in (0.14, 0.32, 0.5, 0.68, 0.84)], 0.12, normal))
    return pose(parts, location, rotation, scale, name="GemPose")


def reset_gem_cache():
    _gem_mats.clear()


def orb(location, r=1.0, sparkles=True):
    """The proof aura orb (violet glow sphere with gloss and inner sparkles) as a posable empty."""
    orb_m = _mats.get("orb")
    if orb_m is None:
        orb_m = ck.gradient_material("Orb", [(0.0, ck.mix("Grape", "White", 0.35)), (0.4, "Grape"),
                                             (0.75, "GrapeDeep"), (1.0, "Magenta")], mode="FACING",
                                     emission=0.14, roughness=0.15, coat=0.9)
        _mats["orb"] = orb_m
    white = M("White", roughness=0.3, coat=0.0, emission=1.2)
    o = ck.sphere(1.0, 48, 24, orb_m, "Orb")
    gl = ck.capsule(0.15, 0.62, 16, 4, white, "Gloss", axis="Z")
    gl.location = (-0.5, -0.6, 0.5)
    gl.rotation_euler = (0.8, -0.6, 0.7)
    gl.scale = (1.0, 0.4, 1.0)
    dot = ck.sphere(0.085, 16, 8, white, "GlossDot", (-0.2, -0.86, 0.5))
    dot.scale = (1.0, 0.5, 1.0)
    parts = [o, gl, dot]
    if sparkles:
        spark = M(ck.mix("Sunny", "White", 0.45), emission=0.6)
        st = ck.extrude_shape(ck.star_points(4, 0.4, 0.15, round_steps=2, rotate=90), depth=0.14, mat=spark,
                              name="OrbSparkle", bevel=0.045)
        st.location = (0.42, -1.0, 0.36)
        st.rotation_euler = (1.45, 0.0, 0.4)
        parts.append(st)
    return pose(parts, location, scale=r, name="OrbPose")


# ------------------------------------------------------------------------------------------------
# Crown
# ------------------------------------------------------------------------------------------------

def crown(location=(0, 0, 0), scale=1.0, rotation=(0, 0, 0), gems=True, bright=False):
    """Chunky gold crown: thick band, five fat rounded points with pearl balls, a pink velvet cap
    and gems on the band. Base at z = 0. `bright` (the Crown icon): lighter gold with warm rims
    instead of GoldDeep, a low velvet cap and one big faceted gem under the front point."""
    gold = M(ck.mix("Sunny", "White", 0.12)) if bright else M("Sunny")
    rim = M(ck.mix("Sunny", "Orange", 0.3)) if bright else M("GoldDeep")
    parts = [ck.lathe(ck.round_profile(0.62, 0.84, 0.0, 0.52, 0.12, 3), 48, gold, "Band")]
    # Raised rims top and bottom of the band (reads as a crafted crown, not a cup).
    parts.append(ck.torus(0.84, 0.07, 48, 8, mat=rim, name="RimLo", location=(0, 0, 0.08)))
    parts.append(ck.torus(0.84, 0.07, 48, 8, mat=rim, name="RimHi", location=(0, 0, 0.46)))
    vt = 0.78 if bright else 1.0
    parts.append(ck.lathe([(0, 0.2), (0.66, 0.24), (0.68, 0.5), (0.58, 0.5 + 0.28 * vt), (0.32, 0.5 + 0.46 * vt),
                           (0, 0.5 + 0.5 * vt)], 40, M("HotPink", roughness=0.5, coat=0.3), "Velvet", smooth_angle=80))
    for k in range(5):
        a = math.radians(-90 + 72 * k)
        c, s = math.cos(a), math.sin(a)
        pts = [(0.76 * c, 0.76 * s, 0.36), (0.8 * c, 0.8 * s, 0.75), (0.84 * c, 0.84 * s, 1.08)]
        parts.append(ck.sweep(pts, [0.3, 0.22, 0.12], 16, gold, "Point", up=(c, s, 0)))
        parts.append(ck.sphere(0.17, 20, 10, M(ck.mix("Sunny", "White", 0.55)), "Pearl",
                               (0.85 * c, 0.85 * s, 1.16)))
    if bright:
        # One big faceted gem on the band under the front point (table facing outward, -Y).
        parts.append(gem((0, -0.88, 0.27), 0.29, (90, 180, 0), kind="vivid"))  # highlight facet up
        for a_deg in (-90 - 46, -90 + 46):
            a = math.radians(a_deg)
            g = ck.sphere(0.15, 24, 12, M("HotPink", roughness=0.15, coat=0.9), "BandGem",
                          (0.87 * math.cos(a), 0.87 * math.sin(a), 0.27))
            g.rotation_euler = (0, 0, a)
            g.scale = (0.55, 1.0, 1.0)
            parts.append(g)
    elif gems:
        for a_deg, col, sz in ((-90, "CyanPop", 0.17), (-90 - 42, "HotPink", 0.12), (-90 + 42, "HotPink", 0.12)):
            a = math.radians(a_deg)
            g = ck.sphere(sz, 24, 12, M(col, roughness=0.15, coat=0.9), "BandGem",
                          (0.87 * math.cos(a), 0.87 * math.sin(a), 0.27))
            g.rotation_euler = (0, 0, a)
            g.scale = (0.55, 1.0, 1.0)  # flattened against the band (local X = outward)
            parts.append(g)
    parts.append(ck.gloss_streak([(0.86 * math.cos(math.radians(a)), 0.86 * math.sin(math.radians(a)), 0.34)
                                  for a in (-150, -138, -126, -114)], 0.1,
                                 (math.cos(math.radians(-132)), math.sin(math.radians(-132)), 0.2)))
    return pose(parts, location, rotation, scale, name="Crown")


def crown_tall(location=(0, 0, 0), scale=1.0, rotation=(0, 0, 0)):
    """Tall gold crown (the cosmetic crown design): a thick band with two raised rims, five tall
    round-tipped spikes each topped with a gold ball, a big cobalt gem in a gold bezel on the front
    of the band and a small red-orange velvet cushion inside. Base at z = 0, front (gem) toward -Y,
    about 1.9 wide and 1.85 tall before scaling."""
    gold = M(ck.mix("Sunny", "White", 0.1))
    rim = M(ck.mix("Sunny", "Orange", 0.35))
    ball = M(ck.mix("Sunny", "White", 0.42))
    parts = [ck.lathe(ck.round_profile(0.64, 0.86, 0.0, 0.62, 0.13, 3), 56, gold, "Band")]
    parts.append(ck.torus(0.86, 0.075, 56, 10, mat=rim, name="RimLo", location=(0, 0, 0.1)))
    parts.append(ck.torus(0.86, 0.075, 56, 10, mat=rim, name="RimHi", location=(0, 0, 0.53)))
    parts.append(ck.lathe([(0, 0.24), (0.68, 0.27), (0.7, 0.52), (0.58, 0.74), (0.34, 0.86), (0, 0.89)], 40,
                          M("RedOrange", roughness=0.5, coat=0.3), "Cushion", smooth_angle=80))
    for k in range(5):
        a = math.radians(-90 + 72 * k)
        c, s = math.cos(a), math.sin(a)
        pts = [(0.76 * c, 0.76 * s, 0.42), (0.79 * c, 0.79 * s, 0.98), (0.82 * c, 0.82 * s, 1.5)]
        parts.append(ck.sweep(pts, [0.3, 0.2, 0.12], 18, gold, "Spike", up=(c, s, 0)))
        parts.append(ck.sphere(0.2, 24, 12, ball, "Ball", (0.83 * c, 0.83 * s, 1.62)))
    # Cobalt cabochon in a gold bezel on the front of the band, with a white glint.
    gem_m = M(ck.mix("Cobalt", "Blue", 0.3), roughness=0.1, coat=0.95)
    g = ck.sphere(0.27, 32, 16, gem_m, "Gem", (0, -0.86, 0.31))
    g.scale = (1.0, 0.5, 1.0)
    bezel = ck.torus(0.28, 0.06, 32, 8, mat=rim, name="Bezel", location=(0, -0.87, 0.31))
    bezel.rotation_euler = (math.radians(90), 0, 0)
    glint = ck.sphere(0.06, 12, 6, M("White", emission=0.8), "Glint", (-0.09, -0.995, 0.4))
    glint.scale = (1.0, 0.4, 1.0)
    parts += [g, bezel, glint]
    parts.append(ck.gloss_streak([(0.875 * math.cos(math.radians(a)), 0.875 * math.sin(math.radians(a)), 0.34)
                                  for a in (-158, -146, -134, -122)], 0.1,
                                 (math.cos(math.radians(-140)), math.sin(math.radians(-140)), 0.2)))
    return pose(parts, location, rotation, scale, name="CrownTall")


# ------------------------------------------------------------------------------------------------
# Treasure crate
# ------------------------------------------------------------------------------------------------

def _arch(w, h, depth, mat, x=0.0, z=0.0, bevel=0.1, steps=18, name="Arch"):
    """Half-ellipse slab (w = half-depth in Y, h = height) extruded `depth` along X at (x, 0, z)."""
    pts = [(w * math.cos(math.pi * k / steps), h * math.sin(math.pi * k / steps)) for k in range(steps + 1)]
    ob = ck.extrude_shape(pts, depth=depth, mat=mat, name=name, bevel=bevel, bevel_segments=4)
    bake_matrix(ob, TO_YZ)
    ob.location = (x, 0, z)
    return ob


TIERS = {
    "Common": dict(wood="Tan", wood2=ck.mix("Tan", "Orange", 0.22), band="Steel", lock="Chrome", trim=False,
                   studs=False, gems=False),
    "Uncommon": dict(wood="Mint", wood2=ck.mix("Mint", "Emerald", 0.3), band="Chrome", lock="Chrome",
                     trim=False, studs=False, gems=False),
    "Rare": dict(wood="Blue", wood2=ck.mix("Blue", "BlueDeep", 0.3), band="Sunny", lock="Sunny", trim=True,
                 studs=False, gems=False),
    "Epic": dict(wood="Grape", wood2=ck.mix("Grape", "GrapeDeep", 0.35), band="Sunny", lock="Sunny",
                 trim=True, studs=True, gems=False),
    "Legendary": dict(wood="Sunny", wood2=ck.mix("Sunny", "Orange", 0.28), band="Cream", lock="White",
                      trim=True, studs=True, gems=True, lid_h=1.02, stud="Sunny"),
    # Cash packs 5 and 6: money-green chest with gold bands (6 adds studs).
    "Cash": dict(wood="Mint", wood2=ck.mix("Mint", "Emerald", 0.3), band="Sunny", lock="Sunny", trim=True,
                 studs=False, gems=False),
    "CashBig": dict(wood="Mint", wood2=ck.mix("Mint", "Emerald", 0.3), band="Sunny", lock="Sunny", trim=True,
                    studs=True, gems=False),
    # Gem pack 3: candy-pink chest with gold bands and studs, so it differs from the grape pouch.
    "GemChest": dict(wood="HotPink", wood2=ck.mix("HotPink", "Magenta", 0.35), band="Sunny", lock="Sunny",
                     trim=True, studs=True, gems=False),
    # Cash pack 5: teal treasure chest with gold bands.
    "Treasure": dict(wood="Teal", wood2=ck.mix("Teal", "TealDeep", 0.3), band="Sunny", lock="Sunny", trim=True,
                     studs=False, gems=False),
    # Cosmetics "All" pack: teal chest with gold bands, gold studs and a gold trim.
    "TealGold": dict(wood="Teal", wood2=ck.mix("Teal", "TealDeep", 0.3), band="Sunny", lock="Sunny", trim=True,
                     studs=True, gems=False, stud=ck.mix("Sunny", "White", 0.35)),
    # Crate Master pass: teal crate with deep teal corner bands, a sunny lid, a coral lock band under the
    # lid and a cream lock plate.
    "KeyCrate": dict(wood="Teal", wood2=ck.mix("Teal", "TealDeep", 0.3), lid=ck.mix("Sunny", "White", 0.08),
                     band=ck.mix("Teal", "TealDeep", 0.65), rim=ck.mix("Coral", "RedOrange", 0.2), lock="Cream",
                     trim=False, studs=False, gems=False),
}

W, D, H = 2.4, 1.6, 1.16  # crate body extents (X, Y, Z)
LID_H = 0.72


def crate(tier="Common", open_deg=0.0, location=(0, 0, 0), rotation=(0, 0, -16), scale=1.0, lid_streak=True):
    """Chunky treasure crate: three rounded planks, banded corners, an arched lid and a front lock.
    open_deg > 0 swings the lid back on its rear hinge. Returns the posed empty."""
    t = TIERS[tier]
    lid_h = t.get("lid_h", LID_H)
    band = M(t["band"])
    parts = []
    for i in range(3):
        parts.append(ck.rounded_box((W, D, H / 3 + 0.02), 0.11, 3, M(t["wood"] if i % 2 == 0 else t["wood2"]),
                                    "Plank", (0, 0, i * (H / 3) - 0.01)))
    if t["trim"]:
        parts.append(ck.rounded_box((W + 0.12, D + 0.12, 0.26), 0.1, 3, band, "Trim", (0, 0, -0.03)))
    for x in (-0.76, 0.76):
        parts.append(ck.rounded_box((0.34, D + 0.1, H + 0.02), 0.1, 3, band, "Band", (x, 0, -0.02)))
    parts.append(ck.rounded_box((W + 0.1, D + 0.1, 0.22), 0.09, 3, M(t.get("rim", t["band"])), "Rim",
                                (0, 0, H - 0.12)))

    # Lid parts are built relative to the hinge (back top edge) so the lid can swing open.
    hinge_y, hinge_z = D / 2, H
    lid = [_arch(D / 2, lid_h, W, M(t.get("lid", t["wood"])), 0, 0, bevel=0.14, name="Lid")]
    for x in (-0.76, 0.76):
        lid.append(_arch(D / 2 + 0.06, lid_h + 0.06, 0.34, band, x, -0.0, bevel=0.08, name="LidBand"))
    if t["studs"]:
        stud = M(t.get("stud", ck.mix("Sunny", "White", 0.4)))
        for x in (-0.76, 0.76):
            for a in (35, 90, 145):
                aa = math.radians(a)
                y = (D / 2 + 0.07) * math.cos(aa)
                z = (lid_h + 0.07) * math.sin(aa)
                lid.append(ck.sphere(0.075, 16, 8, stud, "Stud", (x, y, z)))
            for z in (0.24, 0.62):
                parts.append(ck.sphere(0.075, 16, 8, stud, "Stud", (x, -D / 2 - 0.05, z)))
    if t["gems"]:
        # Big gems on the lid bands and a crest gem standing on top of the lid.
        for x in (-0.76, 0.76):
            g = gem((x, -0.4, lid_h * 0.93), 0.24, (40, 0, 0), kind="pink" if x < 0 else "green", streak=False)
            lid.append(g)
        crest = ck.lathe(ck.round_profile(0, 0.36, 0.0, 0.16, 0.07, 3), 32, M("Cream"), "CrestBase",
                         (0, 0, lid_h - 0.04))
        lid.append(crest)
        lid.append(gem((0, 0, lid_h + 0.26), 0.42, (-8, 0, 0), kind="vivid"))
    if lid_streak:
        aa = math.radians(118)
        pts = []
        for x in (-0.52, -0.32, -0.1, 0.12, 0.32):
            pts.append((x, (D / 2 + 0.035) * math.cos(aa), (lid_h + 0.035) * math.sin(aa)))
        nrm = Vector((0, math.cos(aa) / (D / 2), math.sin(aa) / lid_h)).normalized()
        lid.append(ck.gloss_streak(pts, 0.11, nrm))
    for ob in lid:
        ob.location = (ob.location.x, ob.location.y - hinge_y, ob.location.z)
    lid_e = pose(lid, (0, hinge_y, hinge_z), (-open_deg, 0, 0), name="LidHinge")
    parts.append(lid_e)

    # Front lock plate across the seam with a keyhole (or a big gem on the legendary crate).
    lock = M(t["lock"])
    lock_h = 0.7 if open_deg <= 0 else 0.46
    parts.append(ck.rounded_box((0.62, 0.24, lock_h), 0.13, 3, lock, "Lock", (0, -D / 2 - 0.04, H - 0.42)))
    if t["gems"]:
        parts.append(gem((0, -D / 2 - 0.2, H - 0.07), 0.24, (80, 0, 0), kind="blue", streak=False))
    else:
        kh = M(ck.DARK)
        kz = H - 0.02 if open_deg <= 0 else H - 0.14
        parts.append(ck.sphere(0.085, 16, 8, kh, "Keyhole", (0, -D / 2 - 0.16, kz)))
        k2 = ck.rounded_box((0.09, 0.08, 0.2), 0.035, 2, kh, "KeySlot", (0, -D / 2 - 0.16, kz - 0.22))
        parts.append(k2)
    return pose(parts, location, rotation, scale, name="Crate_" + tier)


def tri_count(target):
    return sum(ck.triangle_count(o) for o in ck._as_objects(target) if o.type == "MESH")
