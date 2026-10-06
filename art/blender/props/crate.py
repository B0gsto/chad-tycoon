"""Hero prop: Crate, the chunky crate players carry (about 3.6 x 2.9 x 2.7 studs). Light
butter-yellow wood body in three fat rounded planks with dark brown seams between them, a bold
caramel X brace on the front and back so it reads as a smashable crate at 48 px, a butter lid with
one crisp pale highlight stripe; two wrapping corner bands baked white so the game can tint them per
rarity; a big sunny-gold latch plate with a deep-gold keyhole on the front. Front (latch) = -Y."""

import math

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _hero import ck, highlight_material, place, ship  # noqa: E402

ck.reset_scene()
wood = ck.toy_material("CrateWood", (255, 222, 120))
wood_b = ck.toy_material("CrateWoodB", (250, 208, 102))
seam = ck.toy_material("CrateSeam", (140, 82, 40))
brace = ck.toy_material("CrateBrace", (212, 132, 58))
lid = ck.toy_material("CrateLid", (255, 230, 138))
trim = ck.toy_material("CrateTrim", "White")
gold = ck.toy_material("CrateLock", "Sunny")
gold_deep = ck.toy_material("CrateKeyhole", "GoldDeep")
hl = highlight_material("CrateShine", ck.mix("Sunny", "White", 0.7))

parts = []
# Body: three stacked planks with deep round edges, so the seams read as chunky grooves.
PLANK_H = 0.7
for i in range(3):
    parts.append(ck.rounded_box((3.3, 2.35, PLANK_H + 0.02), 0.2, 2, wood if i % 2 == 0 else wood_b,
                                "Plank", (0, 0, i * PLANK_H)))
parts.append(ck.rounded_box((3.15, 2.2, 2.1), 0.1, 1, seam, "Core", (0, 0, 0)))
# Bold X brace on the front and back faces: two caramel slats from corner to corner (their ends
# tuck under the corner bands; the crossing shows under the latch plate).
X0, Z0, Z1 = 1.12, 0.12, 2.0
theta = math.degrees(math.atan2(2 * X0, Z1 - Z0))
length = math.hypot(2 * X0, Z1 - Z0)
for y in (-1.2, 1.2):
    for sx in (-1, 1):
        slat = ck.rounded_box((0.36, 0.2, length), 0.08, 1, brace, "Brace")
        parts.append(place(slat, (sx * -X0, y, Z0), (0, sx * theta, 0)))
# Lid: a fat rounded slab in a lighter honey tone, gently wider than the body, one crisp stripe.
parts.append(ck.rounded_box((3.55, 2.6, 0.78), 0.32, 3, lid, "Lid", (0, 0, 2.06)))
parts.append(ck.gloss_streak([(-0.75, -0.55, 2.86), (-0.2, -0.55, 2.865), (0.35, -0.55, 2.865), (0.75, -0.55, 2.86)],
                             0.32, (0, 0, 1), mat=hl, name="LidShine", flatten=0.2, sides=6))
# Two wrapping corner bands (white: tinted per rarity in game).
for sx in (-1, 1):
    parts.append(ck.rounded_box((0.4, 2.7, 2.92), 0.18, 2, trim, "CornerBand", (sx * 1.36, 0, 0)))
# Big gold lock plate on the front: rounded plate, a fat keyhole.
parts.append(place(ck.rounded_box((1.3, 1.25, 0.3), 0.2, 2, gold, "Lock"), (0, -1.05, 1.95), (90, 0, 0)))
parts.append(place(ck.capsule(0.13, 0.42, 8, 2, gold_deep, "Keyhole"), (0, -1.36, 1.9), (0, 0, 0)))
parts.append(ck.sphere(0.19, 10, 5, gold_deep, "KeyholeTop", (0, -1.34, 2.12)))
obj, tris = ship(parts, "Crate", tri_budget=1000, azimuth=30.0, elevation=20.0)
