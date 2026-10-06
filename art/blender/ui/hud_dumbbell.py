"""HUD dumbbell (art/out/ui/HudDumbbell.png + HudDumbbellGlow.png, 1024x448, transparent).

The bottom-centre HUD shows the aura the player carries as a chunky toy dumbbell with a royal-blue
scoreboard panel mounted on the middle of the bar. The panel is left empty and flat: the game draws
a small caption ("AURA") and the big number on it with real text. Rectangles for both lines are
measured from mask renders of the panel and written to art/out/ui/HudDumbbell.json by
hud_post.py, which also adds the white sticker outline, the drop shadow and the violet glow.

    tools/blender-run.sh art/blender/ui/hud_dumbbell.py

Same look as the icon set (art/blender/icons): toy plastic, the shared _toy_rig light, one gloss
streak per form. Orthographic camera from the front, slightly from above; 1 unit = 100 px.
Front is -Y, up is +Z, the bar runs along X.
"""

import math
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "lib"))

import bpy  # noqa: E402
import chadkit as ck  # noqa: E402
import theme_palette  # noqa: E402
from mathutils import Matrix, Vector  # noqa: E402

theme_palette.fill(ck)

OUT = os.path.join(ck.ROOT, "art", "out", "ui")
RAW = os.path.join(OUT, "raw")
os.makedirs(RAW, exist_ok=True)

W, H = 1024, 448
PX = 100.0  # pixels per Blender unit
ELEV = math.radians(12.0)  # camera elevation: the plates and caps show a little of their top
BAR_Y = 268  # image row of the bar's centre line
PANEL = (460, 290, 46)  # panel outer width, height (px) and image row of its top edge
FACE_INSET = 10  # px between the panel's dark lip and its flat face

VIEW = Vector((0.0, -math.cos(ELEV), math.sin(ELEV)))  # subject -> camera
UP = Vector((0.0, math.sin(ELEV), math.cos(ELEV)))  # camera up


def bake(ob):
    """Applies the object's transform to its mesh, so Object texture coordinates follow world up."""
    bpy.context.view_layer.update()
    ck.apply_transforms([ob])
    return ob


def along_x(profile, mat, name):
    """Lathe around Z turned to run along +X (profile z = world x)."""
    ob = ck.lathe(profile, 48, mat, name)
    ob.rotation_euler = (0.0, math.radians(90.0), 0.0)
    return bake(ob)


def plate_mat(name, bottom, mid, top, r, glow):
    return ck.gradient_material(name, [(0.0, bottom), (0.55, mid), (1.0, top)], lo=-r, hi=r,
                                emission=0.55 if glow else 0.0, roughness=0.22)


def front_streak(x, r, a0=28.0, a1=68.0, width=0.13):
    """Gloss streak on the upper front of a cylinder of radius r along X, at x."""
    pts = [(x, -r * 1.015 * math.cos(math.radians(a)), r * 1.015 * math.sin(math.radians(a)))
           for a in (a0, (a0 + a1) / 2, a1)]
    mid = math.radians((a0 + a1) / 2)
    return ck.gloss_streak(pts, width, (0, -math.cos(mid), math.sin(mid)))


def panel_box(w, h, depth, radius, mat, name, offset):
    """Rounded box centred on the panel centre, turned to face the camera exactly."""
    ob = ck.rounded_box((w, depth, h), radius, 5, mat, name)
    ob.data.transform(Matrix.Translation(Vector((0, 0, -h / 2))))
    ob.rotation_euler = (-ELEV, 0.0, 0.0)
    v_centre = (BAR_Y - (PANEL[2] + PANEL[1] / 2)) / PX  # panel centre above the bar, screen units
    ob.location = Vector((0.0, -0.75, 0.0)) + UP * (v_centre + 0.75 * math.sin(ELEV)) + VIEW * offset
    return ob


def build(glow=False):
    ck.reset_scene()
    parts = []
    bar_m = ck.toy_material("Bar", "Sunny", emission=0.3)  # stubs sit in a narrow gap: keep them sunny
    cream_m = ck.toy_material("Cap", "Cream")
    white_m = ck.toy_material("Collar", "White")
    violet = [(112, 72, 222), (150, 110, 255), (200, 172, 255)]
    pink = [(206, 58, 168), (240, 98, 202), (255, 164, 226)]
    if glow:
        violet = [ck.mix(c, "White", 0.12) for c in violet]
        pink = [ck.mix(c, "White", 0.12) for c in pink]

    bar = ck.capsule(0.4, 8.4, 32, 6, bar_m, "Bar", axis="X")
    parts.append(bar)
    for side in (-1, 1):
        def span(a, b):
            return (a, b) if side > 0 else (-b, -a)

        groups = [
            (2.60, 3.22, 1.30, plate_mat("PlateA", *violet, 1.30, glow), 0.2),  # big violet plate
            (3.22, 3.74, 1.05, plate_mat("PlateB", *pink, 1.05, glow), 0.18),  # smaller pink plate
            (3.74, 3.96, 0.64, white_m, 0.08),  # white collar
            (3.96, 4.70, 0.56, cream_m, 0.26),  # cream end cap
        ]
        for i, (a, b, r, mat, bev) in enumerate(groups):
            lo, hi = span(a, b)
            ob = along_x(ck.round_profile(0.0, r, lo, hi, bev, 5), mat, "Part%d_%d" % (i, side))
            parts.append(ob)
            if i in (0, 1, 3):
                x = lo + (hi - lo) * 0.36
                parts.append(front_streak(x, r, width=0.12 if i else 0.15))
    # Bar highlight on the visible stubs between the panel and the plates.
    for side in (-1, 1):
        parts.append(ck.gloss_streak([(side * 2.36, -0.36, 0.2), (side * 2.56, -0.36, 0.2)], 0.09,
                                     (0, -0.7, 0.7)))
    # Aura sparkle on the right violet plate.
    spark = ck.gradient_material("Sparkle", [(0.0, "White"), (0.6, ck.mix("Sunny", "White", 0.55)),
                                             (1.0, ck.mix("Sunny", "White", 0.2))], mode="FACING", emission=0.9)
    star = ck.extrude_shape(ck.star_points(4, 0.23, 0.075, round_steps=2, rotate=90), depth=0.1, mat=spark,
                            name="Sparkle", bevel=0.03)
    star.rotation_euler = VIEW.to_track_quat("Z", "Y").to_euler()
    a = math.radians(-24)  # lower front of the right violet plate, inside its silhouette
    star.location = (2.91, -1.33 * math.cos(a), 1.33 * math.sin(a))
    parts.append(star)

    # Scoreboard panel: a dark moulded lip and the flat royal-blue face in front of it.
    w, h = PANEL[0] / PX, PANEL[1] / PX
    lip_m = ck.toy_material("PanelLip", (36, 54, 124), roughness=0.5, coat=0.3, rim=0.0)
    fi = FACE_INSET / PX
    fh = h - 2 * fi
    face_m = ck.gradient_material("PanelFace", [(0.0, (40, 60, 136)), (0.05, (64, 93, 186)), (0.9, (64, 93, 186)),
                                                (1.0, (126, 154, 232))], lo=-fh / 2, hi=fh / 2, roughness=0.75,
                                  coat=0.0, specular=0.05, rim=0.0)
    lip = panel_box(w, h, 0.34, 0.34, lip_m, "PanelLip", 0.0)
    face = panel_box(w - 2 * fi, fh, 0.2, 0.26, face_m, "PanelFace", 0.12)
    for ob in (lip, face):
        ob.visible_shadow = False  # the panel stands in front of the bar; keep the bar stubs sunlit
    parts += [lip, face]
    return parts, (lip, face)


def camera(scene, parts):
    ck._clear_rig()
    ck._setup_render(scene, W, H, True, 96, 0.15)
    ck._toy_rig(scene, VIEW, Vector((0, 0, 0.4)), 4.9)
    # A wide subject makes the shared softbox huge; dim it so the painted streak stays the one
    # crisp highlight per form.
    bpy.data.objects["ChadRig_Gloss"].data.energy *= 0.4
    cd = bpy.data.cameras.new("ChadRig_Cam")
    cam = ck._link(bpy.data.objects.new("ChadRig_Cam", cd))
    cd.type = "ORTHO"
    cd.sensor_fit = "HORIZONTAL"
    cd.ortho_scale = W / PX
    cd.clip_start, cd.clip_end = 0.1, 100
    v_centre = (BAR_Y - H / 2) / PX  # image centre sits this far above the bar
    cam.location = VIEW * 30 + UP * v_centre
    cam.rotation_euler = (-VIEW).to_track_quat("-Z", "Y").to_euler()
    scene.camera = cam


def shoot(scene, path, samples=96):
    scene.eevee.taa_render_samples = samples
    scene.render.filepath = path
    bpy.ops.render.render(write_still=True)
    print("CHAD_HUD", path)


def main():
    scene = bpy.context.scene
    parts, (lip, face) = build(False)
    camera(scene, parts)
    shoot(scene, os.path.join(RAW, "HudDumbbell_raw.png"))
    others = [o for o in scene.objects if o.type == "MESH" and o not in (lip, face)]
    for o in others:
        o.hide_render = True
    shoot(scene, os.path.join(RAW, "HudDumbbell_mask_panel.png"), 8)
    lip.hide_render = True
    shoot(scene, os.path.join(RAW, "HudDumbbell_mask_face.png"), 8)

    parts, _ = build(True)
    camera(scene, parts)
    shoot(scene, os.path.join(RAW, "HudDumbbellGlow_raw.png"))

    r = subprocess.run([ck._pillow_python(), os.path.join(HERE, "hud_post.py")], env=ck._clean_env(),
                       capture_output=True, text=True)
    print(r.stdout)
    if r.returncode != 0:
        raise RuntimeError(r.stderr[-2000:])


main()
