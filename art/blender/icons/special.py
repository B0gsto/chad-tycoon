"""Game-specific icons: Surge (lightning bolt on a scalloped cobalt badge) and Chad (square-jawed smiling head in
sunglasses).

Standalone: tools/blender-run.sh art/blender/icons/special.py [-- Surge Chad]
"""

import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _icons import (GOLD_HAIR, SKIN, argv_names, bake, ccw, ck, front_streak, glyph, register,  # noqa: E402
                    render, rounded_poly, vgrad)
from mathutils import Euler, Vector  # noqa: E402

NAMES = ["Surge", "Chad"]


@register("Surge")
def surge():
    """Fat flat-faced butter-yellow lightning bolt with a white gloss highlight on a smooth round
    cobalt badge with eight soft scallops, a coral rim ring and a raised brighter blue face."""
    badge_m = vgrad("Badge", ck.mix("Cobalt", "Blue", 0.35), ck.mix("Cobalt", "BlueDeep", 0.25), -1.4, 1.4)
    face_m = vgrad("Face", ck.mix("Blue", "White", 0.12), ck.mix("Cobalt", "Blue", 0.55), -1.1, 1.1)
    rim_m = vgrad("Rim", ck.mix("Coral", "White", 0.15), ck.mix("Coral", "RedOrange", 0.3), -1.2, 1.2)
    bolt_m = vgrad("Bolt", ck.mix("Butter", "White", 0.35), ck.mix("Butter", "Sunny", 0.45), -1.1, 1.1)
    R = 1.36
    scallops = [(R * (1 + 0.075 * math.cos(8 * t)) * math.cos(t), R * (1 + 0.075 * math.cos(8 * t)) * math.sin(t))
                for t in (2 * math.pi * k / 128 for k in range(128))]
    badge = glyph(scallops, 0.42, badge_m, "Badge", bevel=0.16, segments=5, y=0.16)
    rim = ck.torus(1.12, 0.1, 72, 12, mat=rim_m, name="Rim")
    rim.rotation_euler = (math.radians(90), 0, 0)
    rim.location = (0, -0.06, 0)
    face = glyph([(1.06 * math.cos(2 * math.pi * k / 64), 1.06 * math.sin(2 * math.pi * k / 64)) for k in range(64)],
                 0.3, face_m, "Face", bevel=0.12, segments=4, y=0.02)
    # Fat bolt: wide strokes and a big flat front face with a small round bevel.
    bolt_pts = [(-0.4, -1.32), (0.98, 0.34), (0.3, 0.34), (0.74, 1.26), (-0.36, 1.26), (-0.84, -0.2),
                (-0.1, -0.2)]
    bolt_pts = [(x * 0.86 + 0.03, z * 0.86) for x, z in bolt_pts]
    bolt = glyph(rounded_poly(bolt_pts, 0.16, 0.08, 5), 0.5, bolt_m, "Bolt", bevel=0.09, segments=4, y=-0.2)
    streak = front_streak([(0.12, 0.92), (-0.04, 0.64), (-0.2, 0.34), (-0.32, 0.12)], 0.16, -0.45)
    parts = [badge, rim, face, bolt, streak]
    ck.group(parts, "SurgeIcon", rotation=(0, 0, 12))
    return parts


@register("Chad")
def chad():
    """Friendly Chad head: big rounded square-jawed head in warm peach, a tall golden quiff, big
    glossy wrap-around blue shades with a white glint on each lens, rosy cheeks and a wide open
    grin."""
    skin_m = vgrad("Skin", ck.mix(SKIN, "White", 0.15), ck.mix(SKIN, "Coral", 0.28), 0.0, 2.1)
    hair_m = vgrad("Hair", GOLD_HAIR[0], GOLD_HAIR[1], 1.6, 3.0)
    lens_m = vgrad("Lens", ck.mix("Ink", "BlueDeep", 0.45), ck.mix("BlueDeep", "CyanPop", 0.35), 0.9, 1.55,
                   roughness=0.12, coat=0.9)
    frame_m = ck.toy_material("Frame", ck.mix("Ink", "BlueDeep", 0.3))
    mouth_m = ck.toy_material("Mouth", ck.mix("Coral", "Ink", 0.3))
    tongue_m = ck.toy_material("Tongue", ck.mix("Coral", "Pink", 0.5))
    teeth_m = ck.toy_material("Teeth", "White")
    cheek_m = ck.toy_material("Cheek", ck.mix("Coral", "Pink", 0.55), roughness=0.5, coat=0.2)
    w, d, r = 1.0, 0.8, 0.62  # head half-width, half-depth, corner radius
    head = ck.rounded_box((2 * w, 2 * d, 2.1), r, 6, skin_m, "Head")
    parts = [head]

    def face_y(x):
        """Front surface of the head at x (the rounded box curves back past |x| > w - r)."""
        e = max(0.0, abs(x) - (w - r))
        return -d + r - math.sqrt(max(0.0, r * r - e * e))

    for side in (-1, 1):
        ear = ck.sphere(0.24, 24, 12, skin_m, "Ear", (side * 1.0, 0.1, 1.0))
        ear.scale = (0.55, 1.0, 1.25)
        parts.append(ear)
        cheek = ck.sphere(0.17, 24, 12, cheek_m, "Cheek", (side * 0.66, face_y(0.66), 0.76))
        cheek.scale = (1.25, 0.35, 0.8)
        parts.append(cheek)
    # Hair: a rounded dome over the crown plus a tall swept quiff rising at the front-left.
    cap = ck.sphere(1.07, 40, 20, hair_m, "HairCap", (0, 0.06, 1.85))
    cap.scale = (0.95, 0.86, 0.48)
    q_c, q_r, q_s, q_rot = Vector((-0.18, -0.3, 2.3)), 0.62, Vector((1.45, 0.95, 0.88)), (15, -16, 0)
    quiff = ck.sphere(q_r, 40, 20, hair_m, "Quiff", q_c)
    quiff.scale = q_s
    quiff.rotation_euler = tuple(math.radians(a) for a in q_rot)
    lobe = ck.sphere(0.46, 32, 16, hair_m, "Lobe", (0.5, -0.12, 2.18))
    lobe.scale = (1.2, 1.0, 0.8)
    parts += [cap, quiff, lobe]
    # Quiff gloss: a crisp streak over the upper-left of the swoop (points on the ellipsoid).
    rot = Euler(tuple(math.radians(a) for a in q_rot)).to_matrix()
    pts, nrm = [], Vector()
    for u in ((-0.55, -0.6, 0.58), (-0.3, -0.62, 0.72), (0.0, -0.6, 0.8)):
        u = Vector(u).normalized()
        n = (rot @ Vector((u.x / q_s.x, u.y / q_s.y, u.z / q_s.z))).normalized()
        pts.append(q_c + rot @ Vector((u.x * q_s.x, u.y * q_s.y, u.z * q_s.z)) * q_r + n * 0.02)
        nrm += n
    parts.append(ck.gloss_streak(pts, 0.16, nrm.normalized()))
    # Shades: two big lenses, each a flat slab turned back toward its side so the pair wraps
    # round the face, with a white glint across the upper-left of each lens.
    lens_pts = rounded_poly([(0.0, 1.5), (0.9, 1.5), (0.84, 1.02), (0.68, 0.9), (0.14, 0.9), (0.04, 1.0)], 0.2,
                            0.05)
    turn = math.radians(16)
    ly = -d - 0.11
    for side in (-1, 1):
        pts = ccw([(side * x, z) for x, z in lens_pts])
        lens = glyph(pts, 0.16, lens_m, "Lens", bevel=0.06, y=0.0)
        x0 = side * 0.42
        glint = front_streak([(x0 - 0.24, 1.36), (x0 - 0.06, 1.22), (x0 + 0.14, 1.06)], 0.12, -0.08, lift=0.012)
        dot = front_streak([(x0 + 0.24, 1.38), (x0 + 0.3, 1.33)], 0.08, -0.08, lift=0.012)
        for ob in (lens, glint, dot):
            ob.rotation_euler = (0, 0, side * turn)
            ob.location = (side * 0.07, ly, 0)
            bake(ob)
        parts += [lens, glint, dot]
        arm = ck.rounded_box((0.12, 0.9, 0.14), 0.05, 2, frame_m, "Arm", (side * 1.0, -0.3, 1.3))
        parts.append(arm)
    parts.append(ck.rounded_box((0.3, 0.14, 0.14), 0.06, 2, frame_m, "Bridge", (0, ly, 1.24)))
    # Wide open grin: a big D of dark coral with a white teeth band and a pink tongue.
    mouth = [(0.5 * math.cos(math.radians(a)), 0.36 * math.sin(math.radians(a))) for a in range(180, 361, 12)]
    my = face_y(0.0) - 0.02
    m = glyph(rounded_poly(mouth, 0.08, 0.05, 3), 0.1, mouth_m, "Mouth", bevel=0.035, segments=2, y=my)
    m.location.z = 0.66
    parts.append(bake(m))
    teeth = glyph(rounded_poly([(-0.4, 0.0), (0.4, 0.0), (0.34, -0.12), (-0.34, -0.12)], 0.05, 0.0, 2), 0.06,
                  teeth_m, "Teeth", bevel=0.02, segments=2, y=my - 0.05)
    teeth.location.z = 0.645
    parts.append(bake(teeth))
    tongue = ck.sphere(0.2, 24, 12, tongue_m, "Tongue", (0.0, my - 0.02, 0.43))
    tongue.scale = (1.25, 0.3, 0.6)
    parts.append(tongue)
    ck.group(parts, "ChadIcon", rotation=(0, 0, 12))
    return parts


if __name__ == "__main__":
    render(argv_names() or NAMES)
