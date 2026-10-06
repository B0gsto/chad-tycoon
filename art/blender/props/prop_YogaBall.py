"""Gym prop YogaBall (fallback: Decor.luau PROP_BUILDERS.YogaBall, a 2.4 stud ball). A glossy grape ball with
a white band around a tilted axis, squashed a touch where it rests and flattened into a small round foot so it
sits on the floor."""

import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _gym import bpy, ck, finish, paint  # noqa: E402

ck.reset_scene()
grape = ck.toy_material("Ball", "Grape")
white = ck.toy_material("Band", "White")

R = 1.2
ball = ck.sphere(R, 22, 14, grape, "Ball")
paint(ball, white, lambda c: abs(c.z) < R * 0.2)
# tilt the ball so the band reads as a jaunty stripe
ball.rotation_euler = (math.radians(-28), math.radians(18), 0)
ball.location = (0, 0, R)
bpy.context.view_layer.update()
ck.apply_transforms([ball])
# a gentle squash where it sits on the floor (bouncy toy look), ending in a flat round foot
for v in ball.data.vertices:
    if v.co.z < 0.3:
        v.co.z = 0.3 - (0.3 - v.co.z) * 0.7
    v.co.z = max(v.co.z, 0.19)
obj, tris = finish([ball], "YogaBall")
