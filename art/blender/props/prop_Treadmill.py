"""Gym prop Treadmill (fallback: Decor.luau PROP_BUILDERS.Treadmill): the runner faces -Z (Blender -Y). A thick
deck with a bold mint side skirt, white side rails and a grape belt; a round white motor hood at the front, two
fat white handrails joined by a cross bar, fat mint grip pads on the rails, and a chunky mint console block
with a cream screen and sunny buttons sitting between the grips."""

import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _gym import bpy, ck, finish, rod  # noqa: E402

ck.reset_scene()
white = ck.toy_material("Frame", "White")
mint = ck.toy_material("Skirt", "Mint")
belt = ck.toy_material("Belt", ck.mix(ck.DARK, "Grape", 0.7))  # baked shade stays above GrapeDeep
cream = ck.toy_material("Screen", "Cream")
sunny = ck.toy_material("Button", "Sunny")

RAIL_R = 0.3  # 0.6 thick: rails, posts and cross bar
RX = 0.98  # rail centre x
parts = [
    # Thick deck: a mint skirt body with a white rail on each side of the grape belt.
    ck.rounded_box((2.6, 5.0, 0.62), 0.24, 2, mint, "Skirt", (0, 0.2, 0)),
    ck.rounded_box((2.0, 4.3, 0.2), 0.08, 1, belt, "Belt", (0, 0.45, 0.52)),
    ck.rounded_box((0.42, 4.6, 0.3), 0.14, 1, white, "SideRail", (-1.08, 0.3, 0.5)),
    ck.rounded_box((0.42, 4.6, 0.3), 0.14, 1, white, "SideRail", (1.08, 0.3, 0.5)),
    ck.capsule(0.55, 2.6, 12, 2, white, "Hood", (0, -2.05, 0.58), axis="X"),
]
for side in (-1, 1):
    x = side * RX
    # One fat bent rail per side: up the front post, then back toward the runner.
    pts = [(x, -2.15, 0.6), (x, -2.15, 2.7)]
    for k in range(1, 5):
        a = math.radians(90 * k / 4)
        pts.append((x, -2.15 + 0.4 * (1 - math.cos(a)), 2.7 + 0.4 * math.sin(a)))
    pts.append((x, -0.8, 3.1))
    parts.append(ck.sweep(pts, [RAIL_R] * len(pts), 10, white, "Rail", up=(1, 0, 0), smooth_angle=80))
    parts.append(ck.sphere(RAIL_R, 10, 5, white, "RailEnd", (x, -0.8, 3.1)))
    # Fat mint grip pad on the horizontal part.
    parts.append(rod((x, -1.45, 3.1), (x, -0.85, 3.1), 0.34, 10, mint, "Grip"))
# Cross bar joining the posts under the console.
parts.append(rod((-RX, -2.15, 2.55), (RX, -2.15, 2.55), RAIL_R, 10, white, "CrossBar"))
# Console: a chunky mint block between the grips, its face (+Y, toward the runner) tilted 25 degrees up,
# with a cream screen and two sunny buttons.
con = [
    ck.rounded_box((1.3, 0.75, 1.0), 0.28, 2, mint, "Console", (0, 0, -0.5)),
    ck.rounded_box((0.9, 0.12, 0.5), 0.06, 1, cream, "Screen", (0, 0.36, -0.2)),
    ck.sphere(0.13, 8, 4, sunny, "Button", (-0.28, 0.36, -0.36)),
    ck.sphere(0.13, 8, 4, sunny, "Button", (0.28, 0.36, -0.36)),
]
ck.group(con, "ConsolePivot", location=(0, -2.2, 3.35), rotation=(25, 0, 0))
bpy.context.view_layer.update()
ck.apply_transforms(con)
parts += con
obj, tris = finish(parts, "Treadmill", {"azimuth": 35.0, "elevation": 20.0})
