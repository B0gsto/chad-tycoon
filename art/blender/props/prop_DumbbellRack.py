"""Gym prop DumbbellRack (fallback: Decor.luau PROP_BUILDERS.DumbbellRack): two fat blue end panels, two thick
white shelves (front shelf low, back shelf high, front = -Y) and three big dumbbells per shelf lying along the
shelf, so each one shows a short white handle between two chunky heads. Neighbouring head colours contrast
strongly (low: pink, blue, sunny; high: mint, coral, grape). Heads are low-poly lathes with a round bevel."""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _gym import ck, disc, finish  # noqa: E402

ck.reset_scene()
blue = ck.toy_material("End", "Blue")
white = ck.toy_material("Shelf", "White")

HR, HW = 0.46, 0.46  # dumbbell head radius and width
parts = []
for side in (-1, 1):
    parts.append(ck.rounded_box((0.8, 2.4, 2.5), 0.3, 2, blue, "End", (side * 3.1, 0, 0), taper=0.92))
# Shelves 0.5 thick: front one top at 1.1, back one top at 2.05.
parts.append(ck.rounded_box((5.8, 1.2, 0.5), 0.2, 2, white, "Shelf", (0, -0.55, 0.6)))
parts.append(ck.rounded_box((5.8, 1.2, 0.5), 0.2, 2, white, "Shelf", (0, 0.55, 1.55)))

rows = (
    (-0.55, 1.1 + HR, ("HotPink", "Blue", "Sunny")),
    (0.55, 2.05 + HR, ("Mint", "Coral", "Grape")),
)
mats = {}
for y, z, names in rows:
    for i, x in enumerate((-1.85, 0.0, 1.85)):
        key = names[i]
        mats.setdefault(key, ck.toy_material("Head" + key, key))
        parts.append(ck.capsule(0.27, 1.1, 8, 1, white, "Handle", (x, y, z), axis="X"))
        for s in (-1, 1):
            parts.append(disc(HR, HW, 0.15, 10, mats[key], "Head", steps=1, centre=(x + s * 0.5, y, z)))
obj, tris = finish(parts, "DumbbellRack", {"azimuth": 28.0, "elevation": 22.0})
