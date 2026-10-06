"""Hero prop: Converter, a giant toy smoothie blender / protein shaker (about 6.8 studs across,
11.9 tall, like buildConverter in src/server/World/Machines.luau). White foot, fat blue motor
base with a big coral push button on the front (-Y) flanked by two small candy buttons, a
saturated sky-cyan cup with one bright vertical highlight stripe (hollow, thick lip, flat floor at z = 4.0: the spinning blade "ConverterCore" /
"ConverterBlade" stays a separate game part at z ~ 4.4), white measuring ticks on the front, a
fat white handle on the -X side (the part-built handle's side), a white lid rim, blue lid and a
sunny fill cap (where the game's "ConverterIntake" sits) offset 0.6 toward the front."""

import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _hero import ck, disc, dome, highlight_material, place, ship  # noqa: E402

ck.reset_scene()
blue = ck.toy_material("ConvBlue", "Pads.Deposit")
blue_light = ck.toy_material("ConvBlueLight", ck.mix("Pads.Deposit", "White", 0.32))
white = ck.toy_material("ConvWhite", "White")
cup_mat = ck.toy_material("ConvCup", ck.mix("CyanPop", "Pool", 0.35))
cup_in = ck.toy_material("ConvCupIn", ck.mix("CyanPop", "Blue", 0.45))
hl = highlight_material("ConvShine", ck.mix("Pool", "White", 0.85))
coral = ck.toy_material("ConvCoral", "Coral")
sunny = ck.toy_material("ConvSunny", "Sunny")
mint = ck.toy_material("ConvMint", "Mint")

parts = []
# Motor base: white foot, a fat bulging blue body, white rim, light-blue collar.
parts.append(disc(3.35, 0.0, 0.62, 0.26, white, "Foot", segments=28))
base_prof = [(0, 0.5), (2.95, 0.5), (3.12, 0.75), (3.2, 1.3), (3.2, 2.1), (3.1, 2.65), (2.85, 2.95), (0, 2.95)]
parts.append(ck.lathe(base_prof, 28, blue, "Base", smooth_angle=60))
parts.append(ck.torus(3.0, 0.3, 28, 8, mat=white, name="BaseRim", location=(0, 0, 2.95)))
parts.append(disc(2.72, 2.9, 3.85, 0.25, blue_light, "Collar", segments=28))

# Big friendly push button on the front, two small candy buttons beside it.
parts.append(place(ck.torus(0.88, 0.2, 18, 6, mat=white, name="ButtonRing"), (0, -3.12, 1.7), (90, 0, 0)))
parts.append(place(dome(0.82, 0.62, coral, "Button", segments=18, base=0.25), (0, -3.0, 1.7), (90, 0, 0)))
for sx, m in ((-1, sunny), (1, mint)):
    x = sx * 1.95
    y = -(3.2 ** 2 - x ** 2) ** 0.5 + 0.08
    parts.append(place(dome(0.42, 0.34, m, "SmallButton", segments=12, base=0.12), (x, y, 1.7), (90, 0, sx * 37)))

# Cup: hollow tapered shell (thick round lip), flat floor inside.
cup_prof = [(0, 3.8), (2.38, 3.8), (2.42, 4.4), (2.6, 9.0), (2.62, 9.55), (2.36, 9.55), (2.32, 9.0),
            (2.16, 4.35), (0, 4.0)]
cup = ck.lathe(cup_prof, 28, cup_mat, "Cup", smooth_angle=50)
cup.data.materials.append(cup_in)
for p in cup.data.polygons:
    r = (p.center.x ** 2 + p.center.y ** 2) ** 0.5
    if r < 2.34 and p.center.z < 9.5:
        p.material_index = 1
parts.append(cup)
# Measuring ticks on the front of the cup.
for z, w in ((5.6, 0.75), (6.8, 1.15), (8.0, 0.75)):
    r = 2.42 + (2.6 - 2.42) * (z - 4.4) / 4.6
    a = math.radians(22 + (1.15 - w) * 18)
    parts.append(place(ck.capsule(0.14, w, 8, 2, white, "Tick", axis="X"), (r * math.sin(a), -r * math.cos(a), z),
                       (0, 90, math.degrees(a))))
# One bright vertical highlight stripe on the front-left of the cup.
shine = []
for z in (4.9, 6.0, 7.2, 8.4, 9.0):
    r = 2.42 + (2.6 - 2.42) * (z - 4.4) / 4.6 + 0.03
    ang = math.radians(-38)
    shine.append((r * math.sin(ang), -r * math.cos(ang), z))
parts.append(ck.gloss_streak(shine, 0.55, (math.sin(math.radians(-38)), -math.cos(math.radians(-38)), 0), mat=hl,
                             name="CupShine", flatten=0.2, sides=6))
# Fat C handle on the -X side.
hx = -2.2
handle_pts = [(hx + 0.1, 0, 4.9), (hx - 1.0, 0, 5.1), (hx - 1.55, 0, 5.85), (hx - 1.65, 0, 7.0),
              (hx - 1.5, 0, 8.1), (hx - 1.0, 0, 8.8), (hx + 0.15, 0, 9.0)]
parts.append(ck.sweep(handle_pts, [0.78, 0.85, 0.85, 0.85, 0.85, 0.85, 0.78], 10, white, "Handle", flatten=0.9,
                      up=(0, 1, 0), smooth_angle=70))

# Lid: white rim, blue domed lid, sunny fill cap offset toward the front.
parts.append(ck.torus(2.62, 0.3, 28, 8, mat=white, name="LidRim", location=(0, 0, 9.7)))
parts.append(ck.lathe([(0, 9.5), (2.6, 9.5), (2.62, 10.15), (2.4, 10.62), (2.0, 10.8), (0, 10.86)], 28, blue,
                      "Lid", smooth_angle=60))
parts.append(place(disc(1.2, 0.0, 0.7, 0.25, sunny, "Cap", segments=20), (0, -0.6, 10.62)))
parts.append(place(disc(0.78, 0.0, 0.2, 0.08, white, "CapTop", segments=16), (0, -0.6, 11.25)))
obj, tris = ship(parts, "Converter", tri_budget=1200, azimuth=28.0, elevation=16.0)
