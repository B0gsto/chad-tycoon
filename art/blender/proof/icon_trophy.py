"""Proof icon: big gold trophy cup with chunky loop handles and a deep violet star, on a short stem
and a wide violet plinth (strong gold-versus-violet value contrast so it holds up at 48 px)."""

import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _common import ck, icon  # noqa: E402

ck.reset_scene()
gold = ck.toy_material("Gold", "Sunny")
inner = ck.toy_material("Inner", "Orange")
base = ck.toy_material("Plinth", ck.DARK)
band = ck.toy_material("PlinthBand", "Grape")
star_m = ck.toy_material("Star", ck.DARK)

parts = [
    ck.rounded_box((2.1, 2.1, 0.56), 0.22, 4, base, "Plinth"),
    ck.rounded_box((1.6, 1.6, 0.2), 0.09, 3, band, "PlinthTop", (0, 0, 0.5)),
    # Short, fat stem flaring into the cup.
    ck.lathe([(0, 0.6), (0.62, 0.6), (0.66, 0.66), (0.58, 0.74), (0.34, 0.84), (0.32, 0.98), (0, 1.0)], 40,
             gold, "Stem"),
    # Big round bowl with a thick rolled rim.
    ck.lathe([(0, 0.92), (0.42, 0.94), (0.86, 1.1), (1.16, 1.44), (1.3, 1.9), (1.36, 2.28), (1.32, 2.4),
              (1.2, 2.44), (0, 2.4)], 48, gold, "Cup"),
    # The opening: a saturated orange disc (reads as the inside of the cup, never a dark hole).
    ck.lathe(ck.round_profile(0, 1.12, 2.36, 2.452, 0.035, 2), 40, inner, "Opening"),
]
for side in (1, -1):
    # Chunky loop handle: a fat bent tube from the rim down to the belly.
    h = ck.torus(0.44, 0.19, 24, 12, arc=230, mat=gold, name="Handle")
    h.location = (side * 1.22, 0, 1.78)
    h.rotation_euler = (math.radians(90), math.radians(115 if side > 0 else -65), 0)
    parts.append(h)
star = ck.extrude_shape(ck.star_points(5, 0.56, 0.3, round_steps=2), depth=0.2, mat=star_m, name="Star",
                        bevel=0.06)
star.location = (0, -1.17, 1.72)
star.rotation_euler = (math.radians(78), 0, 0)
parts.append(star)
ck.group(parts, "TrophyIcon", rotation=(0, 0, -10))
icon(parts, "trophy")
