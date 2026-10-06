"""Water cooler (Prop_WaterCooler, about 5 studs tall): a wide, squat white cabinet on a chunky
blue base with a blue top band, a clean smooth pool-blue jug (a bevelled capsule with a round
dome) and two big round coral / blue tap buttons over a chunky light blue drip tray on the front
(-Z). Matches the part-built WaterCooler footprint and height."""

import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _props import ck, disc, mat, rbox, ship  # noqa: E402

ck.reset_scene()
white = mat("Body", "White")
band = mat("Band", "Blue")
jug = mat("Jug", "Pool")
panel = mat("Panel", ck.mix("White", "Pool", 0.55))
hot = mat("TapHot", "Coral")
cold = mat("TapCold", "Blue")


def jug_profile(neck_r=0.4, z_neck=2.62, z_shoulder=2.84, r=0.8, top=4.96, shoulder=0.42, steps=3):
    """(r, z) lathe profile: a short neck, a round shoulder out to radius `r`, a straight wall and a
    hemispherical dome ending at `top`."""
    pts = [(0, z_neck), (neck_r, z_neck), (neck_r, z_shoulder)]
    for k in range(1, steps + 1):
        a = -math.pi / 2 + (math.pi / 2) * k / steps
        pts.append((r - shoulder + shoulder * math.cos(a), z_shoulder + shoulder + shoulder * math.sin(a)))
    dome_c = top - r
    for k in range(steps + 1):
        a = (math.pi / 2) * k / (steps + 1)
        pts.append((r * math.cos(a), dome_c + r * math.sin(a)))
    pts.append((0, top))
    return pts


parts = [
    rbox((1.74, 1.74, 0.5), 0.22, band, (0, 0, 0), seg=2, name="Base"),
    rbox((1.62, 1.62, 1.95), 0.32, white, (0, 0, 0.4), seg=2, name="Cabinet"),
    rbox((1.74, 1.74, 0.42), 0.2, band, (0, 0, 2.12), seg=2, name="Band"),
    disc(0.68, 2.48, 2.7, 0.1, white, seg=12, steps=1, name="Collar"),
    ck.lathe(jug_profile(), 16, jug, "Jug", smooth_angle=80),
    # Front panel framing the taps and a chunky drip tray.
    rbox((1.16, 0.2, 1.2), 0.1, panel, (0, -0.78, 0.82), seg=2, name="Panel"),
    rbox((1.2, 0.46, 0.26), 0.12, panel, (0, -0.98, 0.86), seg=2, name="Tray"),
]
for x, m in ((-0.34, hot), (0.34, cold)):
    # Big round push buttons with a short fat spout below each.
    parts.append(disc(0.27, 0.0, 0.3, 0.12, m, loc=(x, -0.8, 1.72), seg=12, steps=1, name="Tap", rot=(90, 0, 0)))
    parts.append(disc(0.12, 1.3, 1.52, 0.05, m, loc=(x, -0.98, 0), seg=8, steps=1, name="Spout"))
    parts.append(rbox((0.2, 0.3, 0.2), 0.08, m, (x, -0.92, 1.42), seg=1, name="SpoutArm"))
ship(parts, "WaterCooler", tri_budget=1450)
