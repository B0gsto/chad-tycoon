"""Party speaker (Prop_Speaker, about 3.5 studs tall): a soft grape cabinet on a sunny stand
with a big hot-pink-rimmed woofer and a tweeter on the front (-Z), deep grape cones and sunny
dust caps. Matches the part-built Speaker."""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _props import ball, ck, mat, rbox, ship  # noqa: E402

ck.reset_scene()
body = mat("Cabinet", "Grape")
rim_m = mat("Rim", "HotPink")
stand = mat("Stand", "Sunny")
cone = mat("Cone", ck.DARK)
cap = mat("Cap", "Sunny")
parts = [
    rbox((2.0, 1.7, 0.34), 0.14, stand, (0, 0, 0), seg=2, name="Stand"),
    rbox((1.8, 1.5, 3.2), 0.36, body, (0, 0, 0.3), seg=3, name="Box"),
]
for z, r, tube, cap_r in ((1.4, 0.6, 0.14, 0.2), (2.8, 0.34, 0.12, 0.13)):
    rim = ck.torus(r, tube, 16 if r > 0.5 else 14, 6, mat=rim_m, name="Rim", location=(0, -0.84, z))
    rim.rotation_euler = (1.5708, 0, 0)
    ck.shade_smooth(rim, 80)
    # Shallow dish cone (lathe around Z, turned so +Z points out of the front face).
    dish = ck.lathe([(0, -0.02), (r * 0.45, 0.0), (r * 0.85, 0.06), (r + 0.02, 0.1), (r + 0.02, -0.1),
                     (0, -0.1)], 16, cone, "Cone", (0, -0.8, z), smooth_angle=60)
    dish.rotation_euler = (1.5708, 0, 0)
    parts += [rim, dish, ball(cap_r, cap, (0, -0.8, z), 10, 6, scale=(1, 0.6, 1), name="DustCap")]
ship(parts, "Speaker", tri_budget=1200)
