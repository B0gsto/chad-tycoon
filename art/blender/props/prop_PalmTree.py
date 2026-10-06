"""Hub palm tree (Prop_PalmTree, about 15 studs tall at the Height 16 reference; the game scales it
by its Height attribute / 16). A chunky toy palm: a thick, gently curved trunk of four big bulging
warm-brown ring segments with lighter caramel bands where they meet, on a darker, richer brown
rounded foot (so the trunk stands out from the honey sand), a big blobby crown of seven
inflated leaf pillows (fat teardrops with real thickness and fully round tips, bright lime tops,
light emerald undersides) drooping into one overlapping umbrella over a lime dome, and three big
caramel coconuts. Fitted to the old 13.05 x 14.84 x 13.05 stud bounds so it still fits where the
game places it."""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _redo import AXES_PROPS, ck, fit, palm, ship  # noqa: E402

ck.reset_scene()
parts = palm(height=11.5, lean=(0.0, 0.9), trunk_r=(2.75, 2.1), rings=4, flare=0.85, leaves=7, leaf_len=6.6,
             leaf_w=2.6, leaf_t=0.42, rise=0.9, droop=3.4, crown_r=2.6, nuts=3, nut_r=1.1,
             trunk=(170, 100, 50), groove=(222, 156, 88), foot=(146, 76, 32), nut=(206, 128, 62))
print("PALM_FIT", fit(parts, (13.05, 13.05, 14.84)))
ship(parts, "PalmTree", tri_budget=2300, axes=AXES_PROPS, finish={"ao_strength": 0.38, "gradient": (0.93, 1.0)})
