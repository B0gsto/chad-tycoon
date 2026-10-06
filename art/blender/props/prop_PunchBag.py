"""Gym prop PunchBag (fallback: Decor.luau PROP_BUILDERS.PunchBag): a big fat coral bag hanging at -X from a
chunky white stand (tall rounded base disc, a fat post and arm at +X), with a sunny band, a sunny hanger and a
sunny star on its front (-Y)."""

import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _gym import ck, curved_star, disc, finish, paint, rod  # noqa: E402

ck.reset_scene()
coral = ck.toy_material("Bag", "Coral")
white = ck.toy_material("Stand", "White")
sunny = ck.toy_material("Band", "Sunny")

BX, R, SX = -0.85, 1.32, 1.08  # bag axis x and radius (bag spans z 0.85 .. 6.05), stand post x
prof = []
for k in range(0, 5):
    t = math.radians(90 * k / 4)
    prof.append((R * math.sin(t), 1.5 - 0.65 * math.cos(t)))
prof += [(R * 1.02, 2.6), (R, 3.95), (R + 0.07, 4.0), (R + 0.07, 4.65), (R, 4.7), (R, 5.5)]
for k in range(1, 5):
    t = math.radians(90 * k / 4)
    prof.append((R * math.cos(t), 5.5 + 0.55 * math.sin(t)))
bag = ck.lathe(prof, 16, coral, "Bag", location=(BX, 0, 0), smooth_angle=40)
paint(bag, sunny, lambda c: 3.98 < c.z < 4.67)

parts = [
    bag,
    curved_star(0.5, 0.26, 0.13, sunny, 2.85, R, (BX, 0), cylinder=True),
    disc(0.5, 0.2, 0.08, 14, sunny, "HangerCap", steps=1, axis="Z", centre=(BX, 0, 6.02)),
    rod((BX, 0, 6.1), (BX, 0, 6.45), 0.28, 10, sunny, "Hanger"),
    disc(1.12, 0.62, 0.24, 18, white, "StandBase", steps=2, axis="Z", centre=(SX, 0, 0.31)),
    rod((SX, 0, 0.45), (SX, 0, 6.6), 0.44, 10, white, "StandPost"),
    rod((SX, 0, 6.6), (BX - 0.15, 0, 6.6), 0.4, 10, white, "StandArm"),
]
obj, tris = finish(parts, "PunchBag", {"azimuth": 30.0, "elevation": 14.0})
