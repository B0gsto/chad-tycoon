"""Proof prop: chunky candy kettlebell (about 2.4 studs tall), low poly for repeated use on a plot.
Coral body, a thick round blue handle and a painted sunny star on the front so it reads as a
game item."""

import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _common import ck, prop  # noqa: E402

ck.reset_scene()
coral = ck.toy_material("Coral", "Coral")
blue = ck.toy_material("Handle", "Blue")
star_m = ck.toy_material("Star", "Sunny")

body = ck.lathe([(0, 0), (0.62, 0), (0.84, 0.09), (0.97, 0.36), (1.0, 0.68), (0.94, 0.98), (0.76, 1.24),
                 (0.44, 1.42), (0, 1.47)], 12, coral, "Body", smooth_angle=80)
# Handle: a thick, fully round loop rising from the shoulders.
HR = 0.28
pts = [(0.5, 0, 1.12), (0.6, 0, 1.42)]
for k in range(0, 9):
    a = math.pi * k / 8
    pts.append((0.62 * math.cos(a), 0, 1.68 + 0.56 * math.sin(a)))
pts += [(-0.6, 0, 1.42), (-0.5, 0, 1.12)]
handle = ck.sweep(pts, [HR] * len(pts), 8, blue, "Handle", up=(0, 1, 0), smooth_angle=80)
# Painted accent: a chunky star badge pressed into the front (-Y) of the belly.
star = ck.extrude_shape(ck.star_points(5, 0.4, 0.2), depth=0.24, mat=star_m, name="Star", bevel=0.04,
                        bevel_segments=1)
star.rotation_euler = (math.radians(90), 0, 0)
star.location = (0, -0.9, 0.66)
obj, tris = prop([body, handle, star], "kettlebell", "Kettlebell", tri_budget=600)
