"""Cartoon hero faces for the intro cutscene (art/out/faces/<Name>.png, 512x512, transparent).

Every face is drawn as flat 2D shapes: filled polygons and round-capped strokes, each a mesh with a pure emission
material, seen by an orthographic camera straight down -Z with a transparent film and the Standard view transform,
so the PNG holds exactly the drawn colours. The layout follows a classic Roblox face decal: features centred and
kept inside the middle ~60% of the canvas so they wrap correctly on a classic head. Colours are skin independent:
navy Ink outlines, white eye fills, a dark mouth, pink only for the tongue and the soft cheek blush.

    tools/blender-run.sh art/blender/faces/faces.py                # every face + sheets
    tools/blender-run.sh art/blender/faces/faces.py -- Happy Sad    # some faces + sheets

Canvas units: the 512 px square spans -0.5..0.5 on X and Y, +Y up.
"""

import math
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "lib"))

import bmesh  # noqa: E402
import bpy  # noqa: E402
import chadkit as ck  # noqa: E402

OUT = os.path.join(ck.ROOT, "art", "out", "faces")
os.makedirs(OUT, exist_ok=True)

INK = (42, 54, 114)  # Theme.World.Ink: the darkest tone in the game
WHITE = (255, 255, 255)
MOUTH = (96, 34, 70)  # dark berry mouth inside
TONGUE = (255, 118, 150)
BLUSH = (255, 110, 140)
TEAR = (170, 232, 255)
CORAL = (255, 96, 96)
LINE = 0.024  # outline / stroke width

ORDER = ["Happy", "Proud", "Shock", "Awe", "Sad", "Idea", "Fury", "Smirk"]

_mats = {}
_z = [0.0]


def mat(rgb, alpha=1.0):
    key = (rgb, alpha)
    if key in _mats:
        return _mats[key]
    m = bpy.data.materials.new("Face_%d_%d_%d_%d" % (rgb + (int(alpha * 100),)))
    m.use_nodes = True
    nt = m.node_tree
    nt.nodes.clear()
    out = nt.nodes.new("ShaderNodeOutputMaterial")
    em = nt.nodes.new("ShaderNodeEmission")
    em.inputs["Color"].default_value = tuple(ck.lin(rgb)) + (1.0,)
    em.inputs["Strength"].default_value = 1.0
    if alpha < 1.0:
        tr = nt.nodes.new("ShaderNodeBsdfTransparent")
        mix = nt.nodes.new("ShaderNodeMixShader")
        mix.inputs["Fac"].default_value = alpha
        nt.links.new(tr.outputs[0], mix.inputs[1])
        nt.links.new(em.outputs[0], mix.inputs[2])
        nt.links.new(mix.outputs[0], out.inputs["Surface"])
        if hasattr(m, "surface_render_method"):
            m.surface_render_method = "BLENDED"
        else:
            m.blend_method = "BLEND"
    else:
        nt.links.new(em.outputs[0], out.inputs["Surface"])
    _mats[key] = m
    return m


def _object(bm, rgb, alpha=1.0, name="Shape"):
    _z[0] += 0.001
    me = bpy.data.meshes.new(name)
    bm.to_mesh(me)
    bm.free()
    ob = bpy.data.objects.new(name, me)
    ob.location.z = _z[0]
    ob.data.materials.append(mat(rgb, alpha))
    bpy.context.scene.collection.objects.link(ob)
    return ob


# ---------------------------------------------------------------- 2D geometry


def ellipse(cx, cy, rx, ry, n=64, rot=0.0):
    c, s = math.cos(rot), math.sin(rot)
    pts = []
    for i in range(n):
        a = 2 * math.pi * i / n
        x, y = rx * math.cos(a), ry * math.sin(a)
        pts.append((cx + x * c - y * s, cy + x * s + y * c))
    return pts


def _clip_half(poly, a, b):
    """Keeps the part of `poly` left of the directed line a->b."""

    def side(p):
        return (b[0] - a[0]) * (p[1] - a[1]) - (b[1] - a[1]) * (p[0] - a[0])

    out = []
    for i, p in enumerate(poly):
        q = poly[(i + 1) % len(poly)]
        sp, sq = side(p), side(q)
        if sp >= 0:
            out.append(p)
        if (sp >= 0) != (sq >= 0):
            t = sp / (sp - sq)
            out.append((p[0] + (q[0] - p[0]) * t, p[1] + (q[1] - p[1]) * t))
    return out


def clip(poly, convex):
    """Intersection of `poly` with the counter-clockwise convex polygon `convex`."""
    for i, a in enumerate(convex):
        if not poly:
            break
        poly = _clip_half(poly, a, convex[(i + 1) % len(convex)])
    return poly


def below(poly, a, b):
    """Part of `poly` below the line through a and b (a left of b)."""
    return _clip_half(poly, b, a)


def bezier(p0, p1, p2, n=24):
    return [
        (
            (1 - t) ** 2 * p0[0] + 2 * (1 - t) * t * p1[0] + t * t * p2[0],
            (1 - t) ** 2 * p0[1] + 2 * (1 - t) * t * p1[1] + t * t * p2[1],
        )
        for t in (i / n for i in range(n + 1))
    ]


def fill(poly, rgb, alpha=1.0, name="Fill"):
    if len(poly) < 3:
        return None
    bm = bmesh.new()
    verts = [bm.verts.new((x, y, 0)) for x, y in poly]
    face = bm.faces.new(verts)
    bmesh.ops.triangulate(bm, faces=[face])
    return _object(bm, rgb, alpha, name)


def stroke(points, width=LINE, rgb=INK, closed=False, name="Stroke"):
    """Round-capped, round-jointed polyline: a quad per segment plus a disc at every point."""
    bm = bmesh.new()
    r = width / 2
    pts = list(points) + ([points[0]] if closed else [])
    for i in range(len(pts) - 1):
        (x0, y0), (x1, y1) = pts[i], pts[i + 1]
        dx, dy = x1 - x0, y1 - y0
        ln = math.hypot(dx, dy)
        if ln < 1e-9:
            continue
        nx, ny = -dy / ln * r, dx / ln * r
        bm.faces.new([bm.verts.new(v) for v in ((x0 + nx, y0 + ny, 0), (x0 - nx, y0 - ny, 0), (x1 - nx, y1 - ny, 0), (x1 + nx, y1 + ny, 0))])
    for x, y in pts:
        ring = [bm.verts.new((x + px - x, y + py - y, 0)) for px, py in ellipse(x, y, r, r, n=16)]
        bm.faces.new(ring)
    return _object(bm, rgb, 1.0, name)


def shape(poly, rgb, outline=True, name="Shape"):
    fill(poly, rgb, name=name)
    if outline:
        stroke(poly, closed=True, name=name + "Line")


# ---------------------------------------------------------------- features

EYE_X, EYE_Y = 0.125, 0.07
EYE_RX, EYE_RY = 0.068, 0.088


def eye(side, rx=EYE_RX, ry=EYE_RY, look=(0.0, -0.01), pupil=1.0, lid=None, lid_tilt=0.0, sparkle=0.0, tears=False):
    """One big eye. side = -1 left (viewer's), 1 right. `lid` (0..1 of the height from the top) cuts the top with a line
    tilted by `lid_tilt` (positive = inner end lower, the frowning lid). `look` shifts the pupil."""
    cx, cy = side * EYE_X, EYE_Y
    poly = ellipse(cx, cy, rx, ry)
    cut = None
    if lid is not None:
        top = cy + ry - 2 * ry * lid
        inner_y, outer_y = top - lid_tilt * ry, top + lid_tilt * ry
        a = (cx - rx * 1.5, inner_y if side > 0 else outer_y)
        b = (cx + rx * 1.5, outer_y if side > 0 else inner_y)
        poly = below(poly, a, b)
        cut = (a, b)
    fill(poly, WHITE, name="EyeWhite")
    px, py = cx + look[0], cy + look[1]
    prx, pry = rx * 0.66 * pupil, ry * 0.68 * pupil
    fill(clip(ellipse(px, py, prx, pry, n=48), poly), INK, name="Pupil")
    if tears:
        pool = clip(ellipse(cx, cy - ry * 0.9, rx * 1.1, ry * 0.42, n=48), poly)
        fill(pool, TEAR, name="TearPool")
    hl = clip(ellipse(px - prx * 0.38, py + pry * 0.38, prx * 0.34, pry * 0.32, n=32), poly)
    fill(hl, WHITE, name="Highlight")
    fill(clip(ellipse(px + prx * 0.4, py - pry * 0.42, prx * 0.15, prx * 0.15, n=24), poly), WHITE, name="Glint")
    if sparkle:
        sx, sy = px + prx * 0.42, py + pry * 0.3
        big = 0.022 * sparkle
        star = [(sx + math.cos(math.pi / 2 + i * math.pi / 4) * (big if i % 2 == 0 else big * 0.36),
                 sy + math.sin(math.pi / 2 + i * math.pi / 4) * (big if i % 2 == 0 else big * 0.36)) for i in range(8)]
        fill(clip(star, poly), WHITE, name="Sparkle")
    stroke(poly, closed=True, name="EyeLine")
    if cut is not None:
        # a heavier lid line along the cut
        (ax, ay), (bx, by) = cut
        on = sorted(p for p in poly if abs((bx - ax) * (p[1] - ay) - (by - ay) * (p[0] - ax)) < 1e-6)
        if len(on) >= 2:
            stroke([on[0], on[-1]], width=LINE * 1.6, name="Lid")


def brow(side, lift=0.0, tilt=0.0, curve=0.012, width=0.03, length=0.1):
    """Brow above an eye. lift moves it up; tilt > 0 raises the inner end (worried), < 0 lowers it (determined)."""
    cx = side * EYE_X
    base = EYE_Y + EYE_RY + 0.055 + lift
    inner = (cx - side * length / 2, base + tilt)
    outer = (cx + side * length / 2, base - tilt * 0.4)
    mid = ((inner[0] + outer[0]) / 2, (inner[1] + outer[1]) / 2 + curve)
    stroke(bezier(inner, mid, outer, 12), width=width, name="Brow")


def blush():
    for side in (-1, 1):
        fill(ellipse(side * 0.2, -0.04, 0.05, 0.026), BLUSH, alpha=0.6, name="Blush")


MY = -0.13  # mouth line height


def open_smile(w=0.13, depth=0.13, top_curve=0.02, tongue=True, cy=MY):
    """D-shaped open smile: a gently curved top edge and a deep round bottom."""
    left, right = (-w, cy + 0.02), (w, cy + 0.02)
    top = bezier(right, (0, cy + 0.02 - top_curve), left, 16)
    bot = bezier(left, (0, cy - depth * 1.6), right, 32)[1:-1]
    poly = top + bot
    poly.reverse() if _area(poly) < 0 else None
    fill(poly, MOUTH, name="Mouth")
    if tongue:
        fill(clip(ellipse(0.02, cy - depth * 0.62, w * 0.55, depth * 0.4), poly), TONGUE, name="Tongue")
    fill(clip(ellipse(0, cy + 0.02, w * 0.9, 0.035), poly), WHITE, name="Teeth")
    stroke(poly, closed=True, name="MouthLine")


def _area(poly):
    return sum(poly[i][0] * poly[(i + 1) % len(poly)][1] - poly[(i + 1) % len(poly)][0] * poly[i][1] for i in range(len(poly))) / 2


def ccw(poly):
    return poly if _area(poly) > 0 else list(reversed(poly))


# ---------------------------------------------------------------- the faces


def happy():
    blush()
    for s in (-1, 1):
        eye(s, look=(0, 0.0))
        brow(s, lift=0.012, tilt=0.008)
    open_smile()


def proud():
    blush()
    for s in (-1, 1):
        eye(s, look=(0.0, 0.0))
        brow(s, lift=0.03 if s < 0 else 0.055, tilt=0.0 if s < 0 else 0.012, curve=0.02)
    # broad toothy grin: a white crescent of teeth, the right corner a little higher
    top = bezier((-0.12, MY + 0.035), (0.0, MY - 0.035), (0.125, MY + 0.05), 24)
    bot = bezier((0.125, MY + 0.05), (0.0, MY - 0.16), (-0.12, MY + 0.035), 24)[1:-1]
    grin = ccw(top + bot)
    fill(grin, WHITE, name="Teeth")
    stroke(grin, closed=True, name="MouthLine")


def shock():
    for s in (-1, 1):
        eye(s, rx=EYE_RX * 1.12, ry=EYE_RY * 1.12, pupil=0.55, look=(0, 0.0))
        brow(s, lift=0.05, tilt=0.012, curve=0.02)
    mouth = ellipse(0, MY - 0.035, 0.055, 0.075)
    fill(mouth, MOUTH, name="Mouth")
    fill(clip(ellipse(0, MY - 0.095, 0.04, 0.03), mouth), TONGUE, name="Tongue")
    stroke(mouth, closed=True, name="MouthLine")


def awe():
    blush()
    for s in (-1, 1):
        eye(s, rx=EYE_RX * 1.06, ry=EYE_RY * 1.06, pupil=0.95, look=(0.0, 0.042), sparkle=1.0)
        brow(s, lift=0.065, tilt=0.012, curve=0.022)
    mouth = ellipse(0, MY - 0.02, 0.05, 0.062)
    fill(mouth, MOUTH, name="Mouth")
    fill(clip(ellipse(0, MY - 0.068, 0.036, 0.026), mouth), TONGUE, name="Tongue")
    stroke(mouth, closed=True, name="MouthLine")


def sad():
    for s in (-1, 1):
        eye(s, look=(0.0, -0.03), tears=True)
        brow(s, lift=0.025, tilt=0.05, curve=0.0, width=0.034)
    # wobbly frown
    pts = []
    for i in range(41):
        t = i / 40
        x = -0.12 + 0.24 * t
        y = MY - 0.04 + 0.075 * math.sin(math.pi * t) + 0.004 * math.sin(t * math.pi * 4)
        pts.append((x, y))
    stroke(pts, width=LINE * 1.7, name="Frown")
    # one tear rolling down the viewer's right cheek
    tx, ty = EYE_X + 0.035, EYE_Y - EYE_RY - 0.06
    drop = [(tx, ty + 0.085)] + [(tx + 0.042 * math.cos(a), ty + 0.042 * math.sin(a)) for a in
                                (math.radians(d) for d in range(-20, 201, 10))]
    drop = ccw(drop)
    fill(drop, TEAR, name="Tear")
    stroke(drop, closed=True, width=LINE * 0.8, name="TearLine")
    fill(ellipse(tx - 0.011, ty + 0.006, 0.008, 0.012), WHITE, name="TearGlint")


def idea():
    blush()
    for s in (-1, 1):
        eye(s, rx=EYE_RX * 1.08, ry=EYE_RY * 1.08, look=(0.0, 0.012), sparkle=1.7)
        brow(s, lift=0.075, tilt=0.0, curve=0.03)
    open_smile(w=0.09, depth=0.1, top_curve=-0.01, tongue=False)


def fury():
    for s in (-1, 1):
        eye(s, lid=0.24, lid_tilt=0.3, look=(-s * 0.012, -0.012))
        brow(s, lift=-0.005, tilt=-0.045, curve=-0.004, width=0.046)
    # gritted grin: one rounded bar of teeth with two tooth lines
    w, h, cy = 0.12, 0.045, MY + 0.005
    band = ccw(bezier((-w, cy + h * 0.8), (0, cy + h * 0.2), (w, cy + h * 1.0), 20)
               + bezier((w, cy - h * 0.4), (0, cy - h * 1.7), (-w, cy - h * 0.5), 20))
    fill(band, WHITE, name="Teeth")
    for x in (-0.04, 0.04):
        stroke([(x, cy + h * 0.55), (x, cy - h * 0.85)], width=LINE * 0.7, name="Gap")
    stroke(band, closed=True, name="MouthLine")
    # comedic anger mark at the temple
    mx, my, r = 0.27, 0.22, 0.03
    for ang in (45, 135, 225, 315):
        a = math.radians(ang)
        c = (mx + math.cos(a) * r * 1.1, my + math.sin(a) * r * 1.1)
        stroke(bezier((c[0] + math.cos(a + 2.0) * r * 0.7, c[1] + math.sin(a + 2.0) * r * 0.7),
                      (mx + math.cos(a) * r * 0.35, my + math.sin(a) * r * 0.35),
                      (c[0] + math.cos(a - 2.0) * r * 0.7, c[1] + math.sin(a - 2.0) * r * 0.7), 8),
               width=LINE * 1.1, rgb=CORAL, name="Anger")


def smirk():
    blush()
    for s in (-1, 1):
        eye(s, look=(0.022, -0.005))
        brow(s, lift=0.07 if s > 0 else 0.0, tilt=0.02 if s > 0 else -0.012, curve=0.02 if s > 0 else 0.0)
    pts = bezier((-0.05, MY - 0.005), (0.05, MY - 0.045), (0.11, MY + 0.045), 24)
    stroke(pts, width=LINE * 1.6, name="Smirk")


FACES = {"Happy": happy, "Proud": proud, "Shock": shock, "Awe": awe, "Sad": sad, "Idea": idea, "Fury": fury,
         "Smirk": smirk}


# ---------------------------------------------------------------- render


def setup(scene):
    for name in ("BLENDER_EEVEE", "BLENDER_EEVEE_NEXT"):
        try:
            scene.render.engine = name
            break
        except TypeError:
            continue
    scene.render.resolution_x = scene.render.resolution_y = 512
    scene.render.resolution_percentage = 100
    scene.render.film_transparent = True
    scene.render.image_settings.file_format = "PNG"
    scene.render.image_settings.color_mode = "RGBA"
    scene.view_settings.view_transform = "Standard"
    scene.view_settings.look = "None"
    if hasattr(scene, "eevee"):
        scene.eevee.taa_render_samples = 32
    cam_data = bpy.data.cameras.new("FaceCam")
    cam_data.type = "ORTHO"
    cam_data.ortho_scale = 1.0
    cam = bpy.data.objects.new("FaceCam", cam_data)
    cam.location = (0, 0, 5)
    scene.collection.objects.link(cam)
    scene.camera = cam


def render(name):
    scene = ck.reset_scene()
    _mats.clear()
    _z[0] = 0.0
    setup(scene)
    FACES[name]()
    scene.render.filepath = os.path.join(OUT, name + ".png")
    bpy.ops.render.render(write_still=True)
    print("[faces] wrote", scene.render.filepath)


def main():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    for name in argv or ORDER:
        render(name)
    subprocess.run([ck._pillow_python(), os.path.join(HERE, "sheet.py"), OUT] + ORDER, env=ck._clean_env(), check=True)


main()
