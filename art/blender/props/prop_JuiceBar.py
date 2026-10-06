"""Hub juice bar (Prop_JuiceBar, about 11 x 10 studs, 10 tall): a little hut built from a few big
chunky parts: a wooden deck, a pink counter (cream top, white kick, two big orange-slice
emblems and two big smoothie cups), a mint back wall, four fat bevelled posts, a
thick coral / white striped roof sloping down to the front with a deep striped fascia, a big
sunny "JUICE" sign and two chunky coral-topped stools. The counter faces the front (-Z).
Matches the part-built JuiceBar footprint and height."""

import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _props import ck, disc, flat_text, mat, rbox, ship  # noqa: E402

ck.reset_scene()
wood = mat("Deck", "Wood")
post_m = mat("Post", ck.mix("Wood", "Orange", 0.3))
pink = mat("Counter", ck.mix("Pink", "HotPink", 0.5))
white = mat("White", "White")
cream = mat("Cream", "Cream")
mint = mat("Wall", "Mint")
coral = mat("Coral", "Coral")
sunny = mat("Sunny", "Sunny")
orange = mat("Orange", "Orange")
hot = mat("HotPink", "HotPink")

parts = [
    rbox((11.0, 8.6, 0.5), 0.2, wood, (0, 0.4, 0), seg=1, name="Deck"),
    rbox((9.8, 1.8, 0.62), 0.24, white, (0, -2.4, 0.48), seg=1, name="Kick"),
    rbox((9.6, 1.6, 3.0), 0.34, pink, (0, -2.4, 0.7), seg=2, name="Counter"),
    rbox((10.2, 2.3, 0.56), 0.26, cream, (0, -2.4, 3.62), seg=2, name="CounterTop"),
    rbox((9.6, 0.8, 4.8), 0.3, mint, (0, 4.1, 0.48), seg=1, name="BackWall"),
]
# Big orange-slice emblems on the counter front: an orange disc with a white rolled rim.
for x in (-2.7, 2.7):
    sl = disc(1.05, 0.0, 0.28, 0.12, orange, loc=(x, -3.14, 2.15), seg=14, steps=1, name="Slice", rot=(90, 0, 0))
    sl.data.materials.append(white)
    for p in sl.data.polygons:
        if p.center.length > 0.86:
            p.material_index = 1
    parts.append(sl)
# Posts (front ones shorter: the roof slopes down to the counter).
FRONT_Y, BACK_Y, FRONT_Z, BACK_Z = -3.5, 4.1, 7.0, 8.7
for sx in (-1, 1):
    for y, top in ((FRONT_Y, FRONT_Z), (BACK_Y, BACK_Z)):
        parts.append(disc(0.72, 0.4, top + 0.2, 0.3, post_m, loc=(sx * 4.85, y, 0), seg=8, steps=2, name="Post"))
# Roof: five thick stripes along the slope, each running down into a deep fascia block at the front.
STRIPES, AW_W = 5, 11.6
sw = AW_W / STRIPES
y0, y1 = -4.8, 4.9
slope = math.degrees(math.atan2(BACK_Z - FRONT_Z, y1 - y0))
length = math.hypot(BACK_Z - FRONT_Z, y1 - y0)
for i in range(STRIPES):
    x = -AW_W / 2 + (i + 0.5) * sw
    m = coral if i % 2 == 0 else white
    s = rbox((sw + 0.02, length, 0.8), 0.36, m, (x, 0, 0), seg=1, name="Roof", rot=(slope, 0, 0))
    s.location = (x, (y0 + y1) / 2, (FRONT_Z + BACK_Z) / 2 - 0.1)
    parts.append(s)
    parts.append(rbox((sw + 0.02, 0.9, 1.25), 0.4, m, (x, y0 + 0.35, FRONT_Z - 0.75), seg=1, name="Fascia"))
# Big sign standing on the front of the roof: sunny board, cream card, hot-pink lettering.
parts.append(rbox((7.6, 0.6, 2.5), 0.4, sunny, (0, -3.3, 7.35), seg=2, name="Sign"))
parts.append(rbox((6.9, 0.14, 1.9), 0.1, cream, (0, -3.62, 7.65), seg=1, name="SignCard"))
txt = flat_text("JUICE", 1.55, hot, name="SignText")
txt.location = (0, -3.7, 8.6)
txt.rotation_euler = (math.radians(90), 0, 0)
parts.append(txt)
# Two big smoothie cups with white domed lids and fat straws on the counter.
for x, m in ((-2.6, mint), (2.6, orange)):
    cup = ck.lathe([(0, 4.1), (0.5, 4.1), (0.64, 5.15), (0.68, 5.22), (0.5, 5.48), (0, 5.56)], 12, m, "Cup",
                   smooth_angle=50)
    cup.location = (x, -2.5, 0)
    cup.data.materials.append(white)
    for p in cup.data.polygons:
        if p.center.z > 5.18:
            p.material_index = 1
    straw = ck.capsule(0.19, 1.2, 8, 1, hot, "Straw", (x + 0.16, -2.5, 5.85))
    straw.rotation_euler = (0, math.radians(14), 0)
    parts += [cup, straw]
# Two chunky stools in front of the counter: a fat white pole on a flared foot and a thick coral seat.
for x in (-3.0, 3.0):
    parts.append(ck.lathe([(0, 0), (0.78, 0), (0.7, 0.24), (0.44, 0.6), (0.42, 2.2), (0, 2.2)], 10, white,
                          "StoolPole", (x, -4.7, 0), smooth_angle=50))
    parts.append(disc(1.1, 2.1, 2.75, 0.28, coral, loc=(x, -4.7, 0), seg=12, steps=1, name="StoolSeat"))
ship(parts, "JuiceBar", tri_budget=2480)
