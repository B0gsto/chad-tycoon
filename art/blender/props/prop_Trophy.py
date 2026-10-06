"""Trophy (Prop_Trophy, about 2.6 studs tall at scale 1): a big shiny gold cup with chunky loop
handles, a white star on the front (-Z) and a golden-orange inside, on a thick stem and a chunky
grape plinth with a white step. Matches the part-built Trophy footprint and height."""

import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _props import ck, mat, rbox, ship  # noqa: E402

ck.reset_scene()
GOLD = (255, 204, 24)  # brighter, more saturated than Theme Sunny for the shiny cup
gold = mat("Gold", GOLD)
deep = mat("GoldDeep", ck.mix(GOLD, "GoldDeep", 0.55))
inner = mat("Inner", "Orange")
plinth = mat("Plinth", "Grape")
step = mat("Step", "White")
star_m = mat("Star", "White")
lip = mat("Lip", ck.mix(GOLD, "White", 0.3))

parts = [
    rbox((1.3, 1.3, 0.5), 0.17, plinth, (0, 0, 0), seg=2, name="Plinth"),
    rbox((0.92, 0.92, 0.28), 0.1, step, (0, 0, 0.46), seg=2, name="Step"),
    # Foot, knot and stem flaring into the bowl.
    ck.lathe([(0, 0.72), (0.46, 0.72), (0.45, 0.84), (0.31, 0.93), (0.27, 1.02), (0.37, 1.14), (0.27, 1.26),
              (0.32, 1.36), (0, 1.38)], 12, deep, "Stem", smooth_angle=60),
    # Bowl with a rolled lip.
    ck.lathe([(0, 1.3), (0.3, 1.33), (0.49, 1.45), (0.6, 1.66), (0.65, 1.95), (0.67, 2.3), (0.74, 2.44),
              (0.73, 2.56), (0.66, 2.62), (0.56, 2.56), (0, 2.5)], 16, gold, "Bowl", smooth_angle=60),
]
bowl = parts[3]
bowl.data.materials.append(lip)
bowl.data.materials.append(inner)
for p in bowl.data.polygons:
    r = math.hypot(p.center.x, p.center.y)
    if p.center.z > 2.4 and r > 0.6:
        p.material_index = 1  # pale gold rolled lip
    elif p.center.z > 2.45:
        p.material_index = 2  # golden-orange inside of the cup
for side in (1, -1):
    h = ck.torus(0.35, 0.18, 10, 8, arc=200, mat=gold, name="Handle")
    ck.shade_smooth(h, 80)
    h.location = (side * 0.62, 0, 2.03)
    h.rotation_euler = (math.radians(90), math.radians(100 if side > 0 else -80), 0)
    parts.append(h)
star = ck.extrude_shape(ck.star_points(5, 0.27, 0.14, round_steps=0), depth=0.12, mat=star_m, name="Star",
                        bevel=0.03, bevel_segments=1)
star.location = (0, -0.63, 1.92)
star.rotation_euler = (math.radians(82), 0, 0)
parts.append(star)
ship(parts, "Trophy", tri_budget=1200)
