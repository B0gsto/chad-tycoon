"""Proof icon: gift box with a ribbon and a big bow."""

import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _common import ck, icon  # noqa: E402

ck.reset_scene()
box_m = ck.toy_material("Box", "Coral")
lid_m = ck.toy_material("Lid", ck.mix("Coral", "Pink", 0.4))
rib_m = ck.toy_material("Ribbon", "Sunny")

parts = [
    ck.rounded_box((1.6, 1.6, 1.15), 0.18, 4, box_m, "Box"),
    ck.rounded_box((1.82, 1.82, 0.42), 0.16, 4, lid_m, "Lid", (0, 0, 1.08)),
    ck.rounded_box((0.42, 1.66, 1.14), 0.12, 3, rib_m, "RibbonX", (0, 0, 0.005)),
    ck.rounded_box((1.66, 0.42, 1.14), 0.12, 3, rib_m, "RibbonY", (0, 0, 0.005)),
    ck.rounded_box((0.44, 1.86, 0.44), 0.13, 3, rib_m, "LidRibX", (0, 0, 1.07)),
    ck.rounded_box((1.86, 0.44, 0.44), 0.13, 3, rib_m, "LidRibY", (0, 0, 1.07)),
]
for side in (-1, 1):
    loop = ck.torus(0.3, 0.14, 32, 12, mat=rib_m, name="Loop")
    loop.location = (side * 0.36, 0, 1.8)
    loop.rotation_euler = (math.radians(90), math.radians(side * 30), 0)
    loop.scale = (1.15, 1.0, 1.0)
    parts.append(loop)
parts.append(ck.sphere(0.22, 24, 12, rib_m, "Knot", (0, 0, 1.56)))
ck.group(parts, "GiftIcon", rotation=(0, 0, -14))
icon(parts, "gift")
