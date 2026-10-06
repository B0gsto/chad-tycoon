"""Hero prop: TrophyPodium, the three-tier round podium under the hub statue (about 19 studs across,
like the part-built one in src/server/World/Hub.luau, but with tiers twice as tall so the steps
read: 6.9 studs to the top). Cream bottom tier on a fat white lip, coral middle tier, glossy gold
top pedestal with a white band and a crisp highlight stripe; a big white plaque with a sunny frame
wraps the front of the middle tier (the game writes "GIGA CHAD" on it) between two big sunny
stars. Front = -Y. Statue stands on the top tier (top at z = 6.9, radius 4.5)."""

import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _hero import ck, disc, highlight_material, place, ship, wrap_cylinder  # noqa: E402

ck.reset_scene()
cream = ck.toy_material("PodCream", "Cream")
white = ck.toy_material("PodWhite", "White")
coral = ck.toy_material("PodCoral", "Coral")
sunny = ck.toy_material("PodSunny", "Sunny")
gold = ck.toy_material("PodGold", ck.mix("Sunny", "Orange", 0.2))
hl = highlight_material("PodShine")

T1, T2, T3 = 2.3, 4.6, 6.9  # tier tops
parts = [
    ck.torus(9.05, 0.42, 40, 8, mat=white, name="Lip", location=(0, 0, 0.42)),
    disc(9.1, 0.0, T1, 0.45, cream, "Tier1", segments=40),
    disc(6.7, T1 - 0.12, T2, 0.45, coral, "Tier2", segments=32),
    disc(4.5, T2 - 0.12, T3, 0.45, gold, "Tier3", segments=28),
    ck.torus(4.55, 0.3, 28, 6, mat=white, name="Band", location=(0, 0, T2 + 0.55)),
]
# One crisp highlight stripe round the upper front-left of the gold pedestal.
pts = []
for i in range(5):
    a = math.radians(-150 + i * 18)
    pts.append((4.53 * math.cos(a), 4.53 * math.sin(a), T3 - 0.95))
parts.append(ck.gloss_streak(pts, 0.42, (-0.5, -0.86, 0), mat=hl, name="PedestalShine", flatten=0.2, sides=6))

# Plaque: big white card with a sunny frame, wrapped round the front of the middle tier.
PZ = T1 + 1.15
frame = place(ck.rounded_box((7.0, 1.95, 0.5), 0.3, 2, sunny, "PlaqueFrame"), (0, -6.45, PZ), (90, 0, 0))
card = place(ck.rounded_box((6.3, 1.4, 0.3), 0.2, 2, white, "Plaque"), (0, -6.85, PZ), (90, 0, 0))
parts += [wrap_cylinder(frame, 6.55), wrap_cylinder(card, 6.55)]
# Big stars either side of the plaque, facing outward from the tier wall.
for sx in (-1, 1):
    a = math.radians(-90 + sx * 46)
    r = 6.8
    star = ck.extrude_shape(ck.star_points(5, 1.15, 0.58, round_steps=1), 0.4, sunny, "Star", bevel=0.12,
                            bevel_segments=2)
    place(star, (r * math.cos(a), r * math.sin(a), PZ), (90, 0, math.degrees(a) + 90))
    parts.append(star)
obj, tris = ship(parts, "TrophyPodium", tri_budget=1200, azimuth=24.0, elevation=24.0)
