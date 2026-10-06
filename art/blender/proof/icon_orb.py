"""Proof icon: the aura orb (core currency). Glowing violet sphere with a bright core, magenta rim,
a crisp gloss highlight and two chunky sparkles inside the silhouette. Same white sticker outline
and drop shadow as every other icon (no halo)."""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _common import ck, icon  # noqa: E402

ck.reset_scene()
# Facing ramp: bright lilac core where the orb faces the camera -> Grape violet -> magenta rim.
orb_m = ck.gradient_material("Orb", [(0.0, ck.mix("Grape", "White", 0.35)), (0.4, "Grape"), (0.75, "GrapeDeep"),
                                     (1.0, "Magenta")], mode="FACING", emission=0.14, roughness=0.15, coat=0.9)
white = ck.toy_material("Gloss", "White", roughness=0.3, coat=0.0, emission=1.2)
spark = ck.toy_material("Sparkle", ck.mix("Sunny", "White", 0.45), emission=0.6)

orb = ck.sphere(1.0, 48, 24, orb_m, "Orb")
# Crisp cartoon gloss: a big flattened white pill on the upper-left, toward the key light, plus a dot.
gloss = ck.capsule(0.15, 0.62, 16, 4, white, "Gloss", axis="Z")
gloss.location = (-0.5, -0.6, 0.5)
gloss.rotation_euler = (0.8, -0.6, 0.7)
gloss.scale = (1.0, 0.4, 1.0)
dot = ck.sphere(0.085, 16, 8, white, "GlossDot", (-0.2, -0.86, 0.5))
dot.scale = (1.0, 0.5, 1.0)
# Four-point sparkles with fat rounded arms, sitting on the front of the orb (inside its outline).
star = ck.extrude_shape(ck.star_points(4, 0.4, 0.15, round_steps=2, rotate=90), depth=0.14, mat=spark,
                        name="Sparkle", bevel=0.045)
star.location = (0.42, -1.0, 0.36)
star.rotation_euler = (1.45, 0.0, 0.4)
small = ck.extrude_shape(ck.star_points(4, 0.24, 0.09, round_steps=2, rotate=90), depth=0.1, mat=spark,
                         name="Sparkle2", bevel=0.03)
small.location = (-0.42, -0.98, -0.42)
small.rotation_euler = (1.45, 0.0, 0.4)
icon([orb, gloss, dot, star, small], "orb")
