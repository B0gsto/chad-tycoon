"""Gym prop Barbell along X (fallback: Decor.luau PROP_BUILDERS.Barbell). A short fat white bar (0.84 thick,
4.82 long) with a chunky stack of two plates on each side: a big blue inner plate and a sunny outer plate, every
plate edge rounded by the same bevel, closed by a round white hub. Origin under the plates; the bar centre sits
1.45 above it, so placed at Decor's y = 2.6 the bar rests in the Bench's J-hooks (bar centre 4.05)."""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _gym import ck, disc, finish  # noqa: E402

ck.reset_scene()
blue = ck.toy_material("Plate", "Blue")
sunny = ck.toy_material("OuterPlate", "Sunny")
white = ck.toy_material("Bar", "White")

Z = 1.45  # bar height = big plate radius
BAR_R = 0.42
parts = [ck.capsule(BAR_R, 4.5, 14, 1, white, "Bar", (0, 0, Z), axis="X")]
for side in (-1, 1):
    # Plates: x 1.46 .. 1.90 (blue, radius 1.45) and 1.90 .. 2.28 (sunny, radius 1.12).
    parts.append(disc(1.45, 0.44, 0.17, 20, blue, "Plate", steps=2, centre=(side * 1.68, 0, Z)))
    parts.append(disc(1.12, 0.38, 0.14, 18, sunny, "OuterPlate", steps=2, centre=(side * 2.09, 0, Z)))
    # Round hub capping the bar end on the outer plate's face.
    parts.append(disc(0.56, 0.18, 0.08, 12, white, "Hub", steps=1, centre=(side * 2.32, 0, Z)))
obj, tris = finish(parts, "Barbell", {"azimuth": 24.0, "elevation": 20.0})
