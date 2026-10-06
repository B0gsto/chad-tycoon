"""Hero prop: Vault, a big friendly piggy bank (about 3.8 x 4.9 x 5.2 studs). Only the pig: it stands
on the game's teal "VaultBase" plinth (top at y = 0.8 in Machines.buildVault), so the game can keep
wobbling it as one "Piggy*" part. A smooth, round, glossy coral-pink body with one crisp highlight
stripe and a cream belly, a round snout puck with two nostrils, big simple Ink oval eyes with white
glints, small rounded ears, a curly tail, four stubby feet, and a sunny coin slot on top with a gold
coin half in it. The slot opening sits where Machines.luau's VAULT_SLOT expects it: x 0, 4.08 studs
above the base, 0.28 studs behind the bounding-box centre (Blender +Y). Front (snout) = -Y."""

import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _hero import band, highlight_material  # noqa: E402
from _redo import AXES_HERO, ball, ck, disc, fit, m, ship  # noqa: E402
from mathutils import Vector  # noqa: E402

SLOT = (0.28, 4.08)  # (behind the bbox centre, above the base) of the slot opening, from Machines.luau
BODY_C = Vector((0.0, 0.0, 2.3))
BODY_R = (1.92, 2.2, 1.75)

ck.reset_scene()
pink = m("PigPink", (255, 122, 138))
belly = m("PigBelly", "Cream")
snout_m = m("PigSnout", (255, 164, 168))
deep = m("PigDeep", (232, 88, 108))
foot_m = m("PigFoot", (246, 104, 122))
ink = m("PigEye", "Ink", roughness=0.15)
white = m("PigGlint", "White", emission=0.3)
gold = m("PigSlot", "Sunny")
gold_deep = m("PigSlotIn", (206, 124, 40))
coin_m = m("Coin", "Sunny", roughness=0.2)
coin_rim = m("CoinRim", "GoldDeep")
coin_face = m("CoinFace", "Butter")
hl = highlight_material("PigShine", ck.mix((255, 122, 138), "White", 0.8))


def surface(x, z, front=True):
    """Point and outward normal on the body ellipsoid at (x, z), on the front (-Y) or back side."""
    a, b, c = BODY_R
    dx, dz = x / a, (z - BODY_C.z) / c
    y = b * math.sqrt(max(0.0, 1 - dx * dx - dz * dz)) * (-1 if front else 1)
    p = Vector((x, y, z))
    n = Vector((x / a ** 2, y / b ** 2, (z - BODY_C.z) / c ** 2)).normalized()
    return p, n


def stick(ob, p, n, sink=0.0):
    """Turns `ob` so its local -Y faces along `n` and puts its centre at p + n * sink."""
    ob.rotation_mode = "QUATERNION"
    ob.rotation_quaternion = Vector((0, -1, 0)).rotation_difference(n)
    ob.location = p + n * sink
    return ob


# Body: one smooth ellipsoid, the lower band of faces painted cream as the belly.
body = ck.sphere(1.0, 22, 13, pink, "Body", tuple(BODY_C))
body.scale = BODY_R
body.data.materials.append(belly)
for p in body.data.polygons:
    if p.center.z < -0.45:
        p.material_index = 1
ck.shade_smooth(body, 85)
parts = [body]
parts.append(band(tuple(BODY_C), BODY_R, -72, -18, 44, 0.46, hl, "BodyShine", n=5))

# Four stubby round feet sunk into the belly.
for sx in (-1, 1):
    for sy in (-1, 1):
        parts.append(disc(0.55, 0.0, 1.45, 0.26, foot_m, loc=(sx * 0.98, sy * 1.18, 0), seg=8, steps=1,
                          name="Foot"))

# Snout: a fat round puck on the front with two oval nostrils.
SN_Z = 2.05
parts.append(disc(0.8, 0.0, 0.7, 0.24, snout_m, loc=(0, -1.88, SN_Z), seg=16, steps=2, name="Snout", rot=(90, 0, 0)))
for sx in (-1, 1):
    parts.append(ball(1.0, deep, (sx * 0.27, -2.58, SN_Z + 0.02), 8, 4, scale=(0.13, 0.06, 0.2), name="Nostril"))

# Big simple oval eyes (Ink) with a white glint, above the snout.
for sx in (-1, 1):
    p, n = surface(sx * 0.74, 2.95)
    parts.append(stick(ball(1.0, ink, (0, 0, 0), 12, 7, scale=(0.25, 0.1, 0.34), name="Eye"), p, n, 0.02))
    g = ball(1.0, white, (0, 0, 0), 6, 4, scale=(0.08, 0.05, 0.1), name="Glint")
    parts.append(stick(g, p + Vector((sx * 0.07 - 0.07, 0, 0.12)), n, 0.1))

# Small rounded ears leaning out.
for sx in (-1, 1):
    ear = ball(1.0, pink, (sx * 1.02, -0.85, 3.72), 10, 6, scale=(0.42, 0.2, 0.46), name="Ear")
    ear.rotation_euler = (math.radians(-18), math.radians(sx * 24), 0)
    parts.append(ear)

# Curly tail: a fat spiral on the back with a round end.
tail = []
for i in range(13):
    t = i / 12
    ang = math.radians(-90 + 400 * t)
    rad = 0.34 - 0.16 * t
    tail.append(Vector((rad * math.cos(ang), 2.08 + 0.42 * t, 2.55 + rad * math.sin(ang))))
parts.append(ck.sweep(tail, [0.12] * 12 + [0.1], 6, deep, "Tail", up=(0, 1, 0), smooth_angle=80))
parts.append(ball(0.1, deep, tuple(tail[-1]), 8, 5, name="TailEnd"))

# Body fitted to the old footprint (3.84 wide, 5.18 deep); the slot and coin go on afterwards.
fit(parts, (3.84, 5.18, None))
lo, hi = ck.bounds(parts)
sy = (lo.y + hi.y) / 2 + SLOT[0]
sz = lo.z + SLOT[1]
# Coin slot: a raised sunny plate across the back with a deep-gold opening.
parts.append(ck.rounded_box((1.75, 0.66, 0.32), 0.14, 2, gold, "SlotRim", (0, sy, sz - 0.3)))
parts.append(ck.rounded_box((1.3, 0.22, 0.06), 0.03, 1, gold_deep, "Slot", (0, sy, sz - 0.03)))
# A gold coin half in the slot: raised rim, butter face on the front.
coin = ck.lathe([(0, -0.12), (0.8, -0.12), (0.84, -0.06), (0.84, 0.06), (0.8, 0.12), (0.62, 0.12), (0.58, 0.09),
                 (0, 0.09)], 16, coin_m, "Coin", smooth_angle=50)
coin.data.materials.append(coin_rim)
for p in coin.data.polygons:
    if math.hypot(p.center.x, p.center.y) > 0.66:
        p.material_index = 1
coin.rotation_euler = (math.radians(90), 0, 0)
coin.location = (0, sy, sz + 0.02)
parts.append(coin)
parts.append(disc(0.38, 0.0, 0.05, 0.02, coin_face, loc=(0, sy - 0.08, sz + 0.02), seg=12, steps=1,
                  name="CoinFace", rot=(90, 0, 0)))
obj, tris = ship(parts, "Vault", tri_budget=2420, axes=AXES_HERO, finish={"ao_strength": 0.45}, azimuth=36.0,
                 elevation=18.0)
