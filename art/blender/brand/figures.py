"""Chunky toy figures for the key art (art/blender/brand/brand.py): a flexing Chad on a posing stage
and cheering fans holding heart signs. Built from chadkit primitives, facing -Y (the camera), feet
on z = 0, about 4.3 units (Chad) and 3.3 units (fan, sign included 4.6) tall. Each builder returns
its list of parts (identity transforms baked) so the caller can group / place them.
"""

import math
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "vfx"))
import spritekit as sk  # noqa: E402
from spritekit import ck  # noqa: E402

from mathutils import Matrix  # noqa: E402

SKIN = ck.mix(ck.mix("Wood", "Cream", 0.45), "Coral", 0.1)
SKIN_DEEP = ck.mix("WoodDark", "Wood", 0.35)


def _mat(name, color, **kw):
    import bpy

    return bpy.data.materials.get(name) or ck.toy_material(name, color, **kw)


def _ellipsoid(r, scale, mat, name, loc):
    ob = ck.sphere(r, 32, 16, mat, name, loc)
    ob.scale = scale
    return ob


def _limb(a, b, radii, mat, name, mid_lift=(0, 0, 0)):
    m = tuple((x + y) / 2 + d for x, y, d in zip(a, b, mid_lift))
    return ck.sweep([a, m, b], radii, 16, mat, name, smooth_angle=80)


def _finish(parts):
    for ob in parts:
        sk.bake(ob)
    return parts


def chad(name="Chad"):
    """Double-biceps flex: square jaw, blue sunglasses, swoopy hair, coral tank top, blue shorts."""
    skin = _mat("ChadSkin", SKIN)
    tank = _mat("ChadTank", "Coral")
    shorts = _mat("ChadShorts", "Blue")
    shoe = _mat("ChadShoe", "White")
    hair = _mat("ChadHair", ck.mix("WoodDark", "Orange", 0.3))
    shades = _mat("ChadShades", "Board", roughness=0.12)
    teeth = _mat("ChadTeeth", "White", emission=0.2)
    p = []
    for sx in (-1, 1):
        p.append(ck.rounded_box((0.62, 0.95, 0.38), 0.17, 3, shoe, name + "Shoe", (sx * 0.42, -0.12, 0)))
        p.append(ck.capsule(0.28, 1.25, 20, 4, skin, name + "Leg", (sx * 0.42, 0, 0.85)))
        p.append(ck.sphere(0.4, 24, 12, skin, name + "Delt", (sx * 0.98, 0, 2.78)))
        sh, el, wr = (sx * 1.0, 0, 2.8), (sx * 1.88, 0, 2.92), (sx * 1.76, 0, 3.72)
        p.append(_limb(sh, el, [0.3, 0.46, 0.3], skin, name + "UpperArm", (0, 0, 0.12)))
        p.append(ck.sphere(0.3, 20, 10, skin, name + "Elbow", el))
        p.append(_limb(el, wr, [0.3, 0.33, 0.27], skin, name + "Forearm"))
        p.append(ck.sphere(0.34, 24, 12, skin, name + "Fist", (sx * 1.73, 0, 3.9)))
    p.append(ck.rounded_box((1.42, 0.86, 0.66), 0.26, 3, shorts, name + "Shorts", (0, 0, 1.18)))
    p.append(_ellipsoid(0.62, (1.0, 0.72, 0.85), tank, name + "Waist", (0, 0, 1.95)))
    p.append(_ellipsoid(1.0, (1.02, 0.6, 0.62), tank, name + "Chest", (0, 0, 2.5)))
    p.append(ck.capsule(0.3, 0.6, 20, 4, skin, name + "Neck", (0, 0, 3.05)))
    p.append(_ellipsoid(0.62, (1.0, 0.92, 1.05), skin, name + "Head", (0, 0, 3.62)))
    p.append(ck.rounded_box((0.98, 0.86, 0.52), 0.24, 3, skin, name + "Jaw", (0, -0.04, 3.03)))
    p.append(_ellipsoid(0.67, (1.03, 0.98, 0.52), hair, name + "Hair", (0, 0.08, 3.98)))
    p.append(_ellipsoid(0.34, (1.5, 1.0, 0.85), hair, name + "Quiff", (0.14, -0.3, 4.18)))
    p.append(ck.rounded_box((1.14, 0.24, 0.32), 0.11, 3, shades, name + "Shades", (0, -0.55, 3.48)))
    p.append(ck.rounded_box((0.44, 0.12, 0.15), 0.06, 2, teeth, name + "Grin", (0, -0.47, 3.16)))
    _finish(p)
    p.append(ck.gloss_streak([(-0.46, -0.68, 3.72), (-0.3, -0.68, 3.74), (-0.14, -0.68, 3.73)], 0.08, (0, -1, 0)))
    return p


def fan(top="Pink", bottom="Mint", hair="Orange", skin=SKIN, band="HotPink", name="Fan"):
    """Cheering fan: one hand holds a cream sign with a coloured header band and a pink heart up on
    the +X side, the other waves."""
    skin_m = _mat(name + "Skin", skin)
    top_m = _mat(name + "Top", top)
    bot_m = _mat(name + "Bottom", bottom)
    hair_m = _mat(name + "Hair", hair)
    shoe = _mat("FanShoe", "White")
    ink = _mat("FanEye", "Ink", roughness=0.2)
    cheek = _mat("FanCheek", ck.mix("Pink", "Coral", 0.3), emission=0.1)
    card = _mat("SignCard", "Cream", emission=0.12)
    band_m = _mat(name + "SignBand", band)
    heart_m = _mat("SignHeart", "HotPink", emission=0.1)
    stick = _mat("SignStick", "Wood")
    p = []
    for sx in (-1, 1):
        p.append(ck.rounded_box((0.46, 0.7, 0.3), 0.14, 3, shoe, name + "Shoe", (sx * 0.27, -0.08, 0)))
        p.append(ck.capsule(0.2, 1.0, 16, 4, skin_m, name + "Leg", (sx * 0.27, 0, 0.7)))
    p.append(ck.rounded_box((0.98, 0.66, 0.5), 0.2, 3, bot_m, name + "Shorts", (0, 0, 0.98)))
    p.append(_ellipsoid(0.52, (0.96, 0.66, 1.0), top_m, name + "Body", (0, 0, 1.78)))
    p.append(ck.capsule(0.17, 0.4, 16, 3, skin_m, name + "Neck", (0, 0, 2.3)))
    p.append(ck.sphere(0.56, 32, 16, skin_m, name + "Head", (0, 0, 2.72)))
    p.append(_ellipsoid(0.6, (1.04, 1.0, 0.72), hair_m, name + "Hair", (0, 0.1, 2.94)))
    p.append(ck.sphere(0.3, 20, 10, hair_m, name + "Bun", (0, 0.42, 3.22)))
    p.append(ck.capsule(0.19, 0.85, 16, 3, hair_m, name + "Tail", (0, 0.58, 2.8)))
    for sx in (-1, 1):
        p.append(ck.sphere(0.08, 12, 6, ink, name + "Eye", (sx * 0.19, -0.5, 2.74)))
        p.append(_ellipsoid(0.09, (1.3, 0.5, 0.8), cheek, name + "Cheek", (sx * 0.33, -0.45, 2.58)))
    smile = ck.torus(0.13, 0.04, 16, 6, arc=150, mat=ink, name=name + "Smile")
    smile.rotation_euler = (math.radians(90), math.radians(165), 0)
    smile.location = (0, -0.53, 2.6)
    p.append(smile)
    # Sign arm (+X) straight up holding the stick; wave arm (-X) up and out.
    p.append(_limb((0.42, 0, 2.05), (0.62, 0, 2.95), [0.16, 0.16, 0.14], skin_m, name + "SignArm"))
    p.append(ck.sphere(0.17, 16, 8, skin_m, name + "Hand", (0.64, -0.02, 3.05)))
    p.append(_limb((-0.42, 0, 2.05), (-0.95, 0, 2.85), [0.16, 0.16, 0.14], skin_m, name + "WaveArm"))
    p.append(ck.sphere(0.17, 16, 8, skin_m, name + "Hand", (-1.0, 0, 2.95)))
    p.append(ck.capsule(0.09, 1.2, 12, 3, stick, name + "Stick", (0.64, 0.05, 3.3)))
    p.append(ck.rounded_box((1.4, 0.16, 1.0), 0.14, 3, card, name + "Card", (0.64, -0.02, 3.62)))
    p.append(ck.rounded_box((1.4, 0.2, 0.28), 0.12, 3, band_m, name + "Band", (0.64, -0.03, 4.34)))
    heart = ck.extrude_shape(sk.heart_outline(size=0.62), depth=0.12, mat=heart_m, name=name + "Heart", bevel=0.04)
    heart.data.transform(Matrix.Rotation(math.radians(90), 4, "X"))
    heart.location = (0.64, -0.12, 3.97)
    p.append(heart)
    _finish(p)
    return p


def stage(name="Stage"):
    """Low round posing stage: white base ring under a sunny top."""
    base = ck.lathe(ck.round_profile(0, 2.15, 0, 0.24, 0.09, 4), 64, _mat("StageBase", "White"), name + "Base")
    top = ck.lathe(ck.round_profile(0, 1.9, 0.16, 0.46, 0.11, 4), 64, _mat("StageTop", "Sunny"), name + "Top")
    return _finish([base, top])


def place(parts, loc, rot_z=0.0, scale=1.0, mirror=False):
    """Moves baked parts: optional X mirror, uniform scale, turn about Z (degrees), then translate."""
    m = Matrix.Translation(loc) @ Matrix.Rotation(math.radians(rot_z), 4, "Z") @ Matrix.Scale(scale, 4)
    if mirror:
        m = m @ Matrix.Scale(-1, 4, (1, 0, 0))
    sk.transform(parts, m)
    if mirror:
        for ob in parts:
            ob.data.flip_normals()
    return parts
