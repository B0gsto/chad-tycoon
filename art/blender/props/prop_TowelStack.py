"""Towel stack (Prop_TowelStack, about 2.2 studs tall): four fat folded towels in hot pink, mint,
sunny and blue, slightly twisted, on a chunky white slab stool with thick pool-blue legs. Folded
edges face the front (-Z). Matches the part-built TowelStack."""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _props import ck, mat, rbox, ship  # noqa: E402

ck.reset_scene()
slab = mat("Stool", "White")
leg = mat("StoolLeg", "PoolDeep")
parts = [
    rbox((2.0, 1.5, 0.5), 0.22, slab, (0, 0, 0.42), seg=2, name="Seat"),
]
for sx in (-1, 1):
    parts.append(rbox((0.5, 1.36, 0.56), 0.2, leg, (sx * 0.7, 0, 0), seg=2, name="Leg"))
for i, key in enumerate(("HotPink", "Mint", "Sunny", "Blue")):
    m = mat("Towel%d" % i, key)
    z = 0.9 + i * 0.32
    twist = 4 if i % 2 else -3
    parts.append(rbox((1.7, 1.1, 0.33), 0.15, m, (0, 0.05, z), seg=2, name="Towel", rot=(0, 0, twist)))
ship(parts, "TowelStack", tri_budget=1200)
