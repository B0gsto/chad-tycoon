"""Gym prop Kettlebell (fallback: Decor.luau PROP_BUILDERS.Kettlebell, 1.4 wide, 1.95 tall).
A symmetric coral ball sitting in a chunky white foot ring, a thick evenly round coral handle arching left-right over
the top, and a chunky sunny star badge centred on the front (-Y) of the belly."""

import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _gym import ck, curved_star, disc, finish  # noqa: E402

ck.reset_scene()
coral = ck.toy_material("Body", "Coral")
white = ck.toy_material("Foot", "White")
sunny = ck.toy_material("Star", "Sunny")

R, C = 0.7, 0.76  # ball radius and centre height
# A true sphere (same radius all round) sitting in a chunky white foot ring.
prof = [(0, C - R)]
for k in range(-5, 6):
    a = math.radians(15 * k)
    prof.append((R * math.cos(a), C + R * math.sin(a)))
prof.append((0, C + R))
body = ck.lathe(prof, 20, coral, "Body", smooth_angle=70)
foot = disc(0.5, 0.2, 0.07, 16, white, "Foot", steps=2, axis="Z", centre=(0, 0, 0.1))

# Handle: one round tube (same radius end to end) rising from the shoulders and arching over the top.
HR = 0.16
pts = [(0.42, 0, 1.12), (0.44, 0, 1.3)]
for k in range(0, 11):
    a = math.pi * k / 10
    pts.append((0.44 * math.cos(a), 0, 1.45 + 0.33 * math.sin(a)))
pts += [(-0.44, 0, 1.3), (-0.42, 0, 1.12)]
handle = ck.sweep(pts, [HR] * len(pts), 10, coral, "Handle", up=(0, 1, 0), smooth_angle=80)

star = curved_star(0.3, 0.16, 0.1, sunny, C - 0.02, R, (0, 0), lift=0.0)
obj, tris = finish([foot, body, handle, star], "Kettlebell")
