"""Hub park bench (Prop_HubBench; the hub's part-built bench is the "Bench" kind in Hub.luau, the gym
weight bench keeps that name): two fat, almost cylinder-round tan seat slats and two orange-tan
backrest slats leaning back, on thick blue side legs with chunky white back posts and coral caps.
Sitting side faces the front (-Z)."""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _props import ck, mat, rbox, ship  # noqa: E402

ck.reset_scene()
plank = mat("Plank", "Tan")
plank2 = mat("PlankBack", ck.mix("Tan", "Orange", 0.45))
frame = mat("Frame", "White")
leg_m = mat("Leg", "Blue")
cap = mat("Cap", "Coral")
TILT = -9.0  # backrest leans back (+Y = Roblox +Z)
parts = []
for y in (-0.47, 0.47):
    parts.append(rbox((5.2, 0.9, 0.62), 0.3, plank, (0, y, 1.38), seg=3, name="Seat"))
for z in (2.2, 2.98):
    # Planks hinge about the seat's back edge, so offset y by the lean.
    dy = (z - 2.0) * 0.16
    parts.append(rbox((5.2, 0.52, 0.7), 0.25, plank2, (0, 0.58 + dy, z), seg=3, name="Back", rot=(TILT, 0, 0)))
for sx in (-1, 1):
    parts.append(rbox((0.8, 1.7, 1.42), 0.3, leg_m, (sx * 1.95, 0, 0), seg=2, name="Leg"))
    parts.append(rbox((0.66, 0.55, 2.1), 0.24, frame, (sx * 1.95, 0.74, 1.3), seg=2, name="Post",
                      rot=(TILT, 0, 0)))
    parts.append(rbox((0.8, 0.7, 0.36), 0.17, cap, (sx * 1.95, 1.04, 3.34), seg=2, name="PostCap",
                      rot=(TILT, 0, 0)))
ship(parts, "HubBench", tri_budget=1400)
