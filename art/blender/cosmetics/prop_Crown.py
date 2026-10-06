"""Crown (props/Crown): the Golden Crown cosmetic worn on a player's head. A proper tall gold crown in
a rich glossy gold that stands off the honey sand: a chunky band with a crisp pale-gold top rim and a
deep orange-gold underside, five crown points (flat across, round-tipped, leaning a little outward),
each topped with a big pale-gold ball, the front point tallest; three big cabochon gems on the front
of the band (cobalt centre, teal left, coral right), a small cobalt velvet cushion peeking above the
band and one white gloss streak on the front point. All
colours baked as vertex colours. 1.6 studs wide (the game scales it by width), origin at the base
centre (it sits on top of the head), under 700 triangles.

    tools/blender-run.sh art/blender/props/_run_redo.py -- ../cosmetics/prop_Crown.py

Writes art/out/props/Crown.fbx / .json / .png / _game.png and preview/web/models/props__Crown.glb.
The crown icons (icons.py) still use the shared _crown.py model.
"""

import math
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "props"))
from _redo import AXES_PROPS, ball, ck, fit, m, ship  # noqa: E402
from mathutils import Euler, Vector  # noqa: E402

WIDTH = 1.6  # studs across X
GOLD = (255, 188, 18)  # rich saturated gold
GOLD_DEEP = (220, 118, 16)  # orange-gold underside
GOLD_LIGHT = (255, 238, 150)  # crisp pale-gold top rim and spike balls
ANGLES = [-90 + 72 * k for k in range(5)]  # spike azimuths, front (-Y) first
HEIGHTS = [0.98, 0.8, 0.7, 0.7, 0.8]  # spike heights above their base, front tallest
# Gems on the band: (azimuth, colour, radius, (segments, rings)). Three big ones across the front.
GEMS = [(-90, "Cobalt", 0.19, (8, 4)), (-128, "Teal", 0.155, (6, 4)), (-52, "Coral", 0.155, (6, 4))]
TILT = 7.0  # outward lean of the spikes, degrees
BALL_R = 0.15

ck.reset_scene()
gold = m("CrownGold", GOLD, roughness=0.18)
deep = m("CrownDeep", GOLD_DEEP, roughness=0.25)
light = m("CrownLight", GOLD_LIGHT, roughness=0.15)
velvet = m("CrownVelvet", "Cobalt", roughness=0.55, coat=0.2)
shine = m("CrownShine", (255, 255, 246), roughness=0.1)
parts = []

# Band: a solid rounded drum; the lower bevel is painted orange-gold, the upper bevel pale gold.
band = ck.lathe([(0, 0), (0.74, 0), (0.8, 0.06), (0.8, 0.38), (0.77, 0.44), (0, 0.44)], 12, gold, "Band",
                smooth_angle=60)
band.data.materials.append(deep)
band.data.materials.append(light)
for p in band.data.polygons:
    if p.center.z < 0.05:
        p.material_index = 1
    elif 0.385 < p.center.z < 0.435:
        p.material_index = 2
parts.append(band)

# Small velvet cushion just peeking above the band.
parts.append(ck.lathe([(0.7, 0.36), (0.62, 0.56), (0.38, 0.68), (0, 0.71)], 10, velvet, "Velvet", smooth_angle=80))

# Spikes: cones flattened radially into flat crown points, leaning out a little; the lowest ring of
# each point is painted orange-gold so the base reads shaded; a big pale-gold ball on each tip.
SPIKE_R = 0.64
SPIKE_Z = 0.3
for i, (a_deg, h) in enumerate(zip(ANGLES, HEIGHTS)):
    a = math.radians(a_deg)
    rot = Euler((0.0, math.radians(TILT), a), "XYZ")
    sp = ck.lathe([(0.3, 0.0), (0.2, h * 0.4), (0.1, h * 0.78), (0.05, h - 0.03), (0.0, h)], 6, gold, "Spike",
                  smooth_angle=70)
    sp.data.materials.append(deep)
    for p in sp.data.polygons:
        if p.center.z < h * 0.2:
            p.material_index = 1
    sp.location = (SPIKE_R * math.cos(a), SPIKE_R * math.sin(a), SPIKE_Z)
    sp.rotation_euler = rot
    sp.scale = (0.42, 1.0, 1.0)  # local X is radial: thin front to back, wide across
    parts.append(sp)
    tip = Vector(sp.location) + rot.to_matrix() @ Vector((0, 0, h - 0.01))
    parts.append(ball(BALL_R * (1.1 if i == 0 else 1.0), light, tuple(tip), 8, 4, name="SpikeBall"))

# Gloss streak up the front point's left face, toward the key light.
a = math.radians(-90)
fp = Vector((SPIKE_R * math.cos(a), SPIKE_R * math.sin(a), SPIKE_Z))
parts.append(ck.gloss_streak([fp + Vector((-0.1, -0.15, 0.2)), fp + Vector((-0.05, -0.155, 0.6))], 0.07,
                             (0, -1, 0), mat=shine, name="Shine", flatten=0.25, sides=4))

# Big cabochon gems on the band (half sunk, squashed radially).
for a_deg, col, size, seg in GEMS:
    a = math.radians(a_deg)
    g = ball(size, m("Gem" + col, col, roughness=0.1), (0.79 * math.cos(a), 0.79 * math.sin(a), 0.21), *seg,
             name="Gem")
    g.rotation_euler = (0, 0, a)
    g.scale = (0.5, 1.0, 1.0)
    parts.append(g)

lo, hi = ck.bounds(parts)
s = WIDTH / (hi.x - lo.x)
fit(parts, (WIDTH, (hi.y - lo.y) * s, (hi.z - lo.z) * s))
ship(parts, "Crown", tri_budget=699, axes=AXES_PROPS, finish={"ao_strength": 0.4, "gradient": (0.8, 1.0)},
     azimuth=28.0, elevation=24.0)
