"""Proof prop: chunky candy dumbbell (about 2.4 studs long), low poly for repeated use on a plot.
Fat hot-pink disc plates with big round edges and a white hub, a thick sunny-yellow grip."""

import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _common import ck, prop  # noqa: E402

ck.reset_scene()
plate_m = ck.toy_material("Plate", "HotPink")
hub_m = ck.toy_material("Hub", "White")
grip_m = ck.toy_material("Grip", "Sunny")

R = 0.78  # plate radius: the dumbbell rests on its plates
W = 0.6  # plate thickness
B = 0.24  # plate edge bevel (big and round)
HUB_R, HUB_H = 0.34, 0.08


def plate_profile():
    """Fat disc: flat inner face, big two-step round edge, a raised hub on the outer face."""
    pts = ck.round_profile(0, R, -W / 2, W / 2, B, 2)[:-1]
    return pts + [(HUB_R + 0.07, W / 2), (HUB_R, W / 2 + HUB_H), (0, W / 2 + HUB_H)]


parts = [ck.capsule(0.3, 1.5, 10, 2, grip_m, "Grip", (0, 0, R), axis="X")]
for side in (-1, 1):
    plate = ck.lathe(plate_profile(), 12, plate_m, "Plate", smooth_angle=50)
    plate.data.materials.append(hub_m)
    for p in plate.data.polygons:
        if p.center.z > W / 2 - 0.01 and math.hypot(p.center.x, p.center.y) < HUB_R + 0.04:
            p.material_index = 1
    plate.rotation_euler = (0, math.radians(90 * side), 0)
    plate.location = (side * (0.46 + W / 2), 0, R)
    parts.append(plate)
obj, tris = prop(parts, "dumbbell", "Dumbbell", tri_budget=600)
