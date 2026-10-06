"""Gym prop Dumbbell: one chunky candy dumbbell lying on the floor along X (fallback: Decor.luau
PROP_BUILDERS.Dumbbell, 1.5 x 1 x 1 studs). A white grip between two identical fat hot-pink heads, each with
the same sunny ring round the middle of its rim and a painted white highlight streak on its upper front edge."""

import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _gym import ck, finish, paint  # noqa: E402

ck.reset_scene()
pink = ck.toy_material("Head", (255, 58, 158))  # a touch more saturated than HotPink
sunny = ck.toy_material("Ring", "Sunny")
white = ck.toy_material("Grip", "White")

Z = 0.5  # bar height: the dumbbell rests on its heads (radius 0.5)
R, W, BEV = 0.5, 0.36, 0.11  # head radius, width, edge bevel
RING = 0.065  # half width of the sunny ring band


def head(xc):
    """A fat round head (lathe along X) whose rim carries a sunny band; same bevel on both edges."""
    prof = [(0, -W / 2)]
    for k in range(4):
        a = -math.pi / 2 + (math.pi / 2) * k / 3
        prof.append((R - BEV + BEV * math.cos(a), -W / 2 + BEV + BEV * math.sin(a)))
    prof += [(R, -RING), (R, RING)]
    for k in range(4):
        a = (math.pi / 2) * k / 3
        prof.append((R - BEV + BEV * math.cos(a), W / 2 - BEV + BEV * math.sin(a)))
    prof.append((0, W / 2))
    ob = ck.lathe(prof, 18, pink, "Head", smooth_angle=60)
    paint(ob, sunny, lambda c: abs(c.z) < RING and math.hypot(c.x, c.y) > R - 0.03)
    ob.rotation_euler = (0, math.radians(90), 0)
    ob.location = (xc, 0, Z)
    return ob


parts = [ck.capsule(0.165, 1.2, 14, 3, white, "Grip", (0, 0, Z), axis="X")]
for side in (-1, 1):
    xc = side * 0.585
    parts.append(head(xc))
    # Highlight: a short white streak on the outer half of the rim, upper front (toward the key light).
    xs = xc + side * 0.1
    pts = []
    for k in range(5):
        phi = math.radians(28 + 36 * k / 4)  # angle from straight up toward the front (-Y)
        pts.append((xs, -(R - 0.008) * math.sin(phi), Z + (R - 0.008) * math.cos(phi)))
    mid = math.radians(46)
    parts.append(ck.gloss_streak(pts, 0.06, (0, -math.sin(mid), math.cos(mid)), mat=white, name="Shine"))
obj, tris = finish(parts, "Dumbbell")
