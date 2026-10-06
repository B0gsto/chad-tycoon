"""Potted palm (Prop_PalmPlanter, about 8 studs tall): a chunky teal pot with a fat rolled cream rim,
a deep-teal foot ring and a caramel soil disc, holding a small version of the hub palm: a thick
ringed honey-tan trunk with orange-tan grooves, a blobby crown of seven inflated lime leaf pillows
with light emerald undersides, and three coconuts. Fitted to the old 7.33 x 7.97 x 7.33 stud bounds."""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _redo import AXES_PROPS, ck, disc, fit, m, palm, ship  # noqa: E402

ck.reset_scene()
pot_m = m("Pot", "Teal")
foot_m = m("PotFoot", "TealDeep")
rim_m = m("PotRim", "Cream")
soil_m = m("Soil", "Soil")

parts = [
    # Chunky tapered pot on a deep-teal foot ring.
    ck.lathe([(0, 0.2), (1.3, 0.2), (1.42, 0.3), (1.72, 2.15), (0, 2.15)], 16, pot_m, "Pot", smooth_angle=70),
    disc(1.4, 0.0, 0.42, 0.16, foot_m, seg=14, steps=1, name="Foot"),
    # Fat rolled cream rim with the soil disc just below its top.
    ck.torus(1.72, 0.36, 14, 6, mat=rim_m, name="Rim", location=(0, 0, 2.2)),
    disc(1.55, 1.9, 2.32, 0.08, soil_m, seg=12, steps=1, name="Soil"),
]
ck.shade_smooth(parts[2], 80)
parts += palm(base=(0, 0, 2.25), height=4.0, lean=(0.0, 0.35), trunk_r=(1.2, 0.95), rings=3, flare=0.0,
              leaves=7, leaf_len=3.6, leaf_w=1.45, leaf_t=0.42, rise=0.45, droop=1.75, crown_r=1.35, nuts=3,
              nut_r=0.5, trunk_sides=10, leaf_sides=8, spin=0.2, nut_seg=(8, 6))
print("PALM_FIT", fit(parts, (7.33, 7.33, 7.97)))
ship(parts, "PalmPlanter", tri_budget=2300, axes=AXES_PROPS, finish={"ao_strength": 0.38, "gradient": (0.93, 1.0)})
