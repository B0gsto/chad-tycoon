"""Gym prop Bench (fallback: Decor.luau PROP_BUILDERS.Bench): a tall puffy hot-pink pad on two fat white
pedestal legs, and at its +Z end (Blender +Y) a fat rounded white rack base with two chunky blue uprights and
round sunny J-hooks that hold the Barbell (bar 0.84 thick, centre 4.05 high and 2.2 studs behind the bench
origin when Decor places it at y = 2.6)."""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _gym import ck, finish, rod  # noqa: E402

ck.reset_scene()
pink = ck.toy_material("Pad", "HotPink")
white = ck.toy_material("Frame", "White")
blue = ck.toy_material("Post", "Blue")
sunny = ck.toy_material("Hook", "Sunny")

BAR_Y, BAR_Z, BAR_R = 2.2, 4.05, 0.42  # where the Barbell's bar rests
POST_X, POST_Y = 1.0, 2.95  # uprights stand just behind the bar (bar back at y 2.62)

parts = [
    # Puffy pad: 1.7 x 4.2, 0.78 tall, top at 2.0.
    ck.rounded_box((1.7, 4.2, 0.78), 0.34, 3, pink, "Pad", (0, -0.2, 1.22)),
    # Fat pedestal legs, flared at the foot.
    ck.rounded_box((1.45, 0.8, 1.32), 0.2, 2, white, "Leg", (0, -1.75, 0), taper=0.86),
    ck.rounded_box((1.45, 0.8, 1.32), 0.2, 2, white, "Leg", (0, 1.2, 0), taper=0.86),
    # Fat rounded rack base across the head end.
    ck.rounded_box((3.5, 1.0, 0.5), 0.22, 2, white, "RackBase", (0, POST_Y, 0)),
]
for side in (-1, 1):
    x = side * POST_X
    # Chunky upright: 0.75 wide, 0.62 deep, round-topped, standing in the base.
    parts.append(ck.rounded_box((0.75, 0.62, 3.95), 0.27, 2, blue, "Post", (x, POST_Y, 0.3)))
    # J-hook: a fat sunny saddle under the bar, running from the post to a round front lip.
    saddle_top = BAR_Z - BAR_R
    parts.append(ck.rounded_box((0.62, 1.55, 0.46), 0.18, 2, sunny, "Hook", (x, 2.2, saddle_top - 0.46)))
    parts.append(rod((x, 1.52, saddle_top - 0.2), (x, 1.52, saddle_top + 0.22), 0.24, 10, sunny, "HookLip"))
obj, tris = finish(parts, "Bench", {"azimuth": 38.0, "elevation": 18.0})
