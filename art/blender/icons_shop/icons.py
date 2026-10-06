"""Shop and reward icons (icons-shop set): 512 px transparent PNGs in art/out/icons/<Name>.png.

Run headless through the heavy lock, all icons or a subset by name:
    tools/blender-run.sh art/blender/icons_shop/icons.py -- [Name ...]
Prints "ICON <name> <triangles>" per icon.
"""

import math
import os
import random
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import shoplib as sl  # noqa: E402
from shoplib import M, ck, pose  # noqa: E402

sys.path.insert(0, os.path.join(HERE, "..", "icons"))
import _icons as gi  # noqa: E402  (HUD glyph helpers: rounded outlines extruded toward the camera)

# ------------------------------------------------------------------------------------------------
# Crates
# ------------------------------------------------------------------------------------------------


def crate_icon(tier):
    def build():
        parts = [sl.crate(tier)]
        opts = {}
        if tier == "Legendary":
            parts += [sl.sparkle((1.12, -0.9, 2.6), 0.5), sl.sparkle((-1.2, -0.6, 2.3), 0.34),
                      sl.sparkle((1.38, -1.0, 0.45), 0.28), sl.sparkle((-1.38, -1.0, 0.6), 0.22)]
            # Strong gold glow; rendered tighter than the kit's halo framing (see main) so the crate stays big.
            opts["glow"] = ("Sunny", 1.0)
        elif tier == "Epic":
            parts.append(sl.sparkle((1.5, -0.8, 1.95), 0.28))
        return parts, opts
    return build


# ------------------------------------------------------------------------------------------------
# Passes
# ------------------------------------------------------------------------------------------------


def pass_auto_collect():
    """Big chunky coral horseshoe magnet (chrome tips) pulling a trail of three big aura orbs."""
    red = M("Coral")
    tip = M("Chrome")
    R, r = 0.98, 0.6
    pts = [(R * math.cos(math.radians(a)), 0, R * math.sin(math.radians(a))) for a in range(0, 181, 10)]
    mag = [ck.sweep(pts, [r] * len(pts), 32, red, "MagnetArc", up=(0, 1, 0), caps=False)]
    for x in (-R, R):
        mag.append(ck.lathe([(0, -0.8), (r, -0.8), (r, 0.02), (0, 0.02)], 40, red, "Leg", (x, 0, 0)))
        mag.append(ck.lathe(ck.round_profile(0, r + 0.03, -1.42, -0.76, 0.18, 4), 40, tip, "Tip", (x, 0, 0)))
    up = sl.Vector((0, -0.85, 0.52)).normalized()
    mag.append(ck.gloss_streak([(R * math.cos(math.radians(a)), up.y * r * 1.03, R * math.sin(math.radians(a))
                                 + up.z * r * 1.03) for a in (96, 112, 128, 144, 160)], 0.2, up))
    for x in (-R, R):  # short streak down the front of each leg
        mag.append(ck.gloss_streak([(x - 0.22, -r * 0.97, -0.05), (x - 0.22, -r * 0.97, -0.35),
                                    (x - 0.22, -r * 0.97, -0.62)], 0.13, (-0.35, -0.94, 0)))
    # Opening points down-right after the tilt; the orbs trail away from the pole gap along it.
    tilt = math.radians(-52)
    base = sl.Vector((-0.9, 0, 0.7))
    d = sl.Vector((-math.sin(tilt), 0, -math.cos(tilt)))  # local -Z after rotating about Y
    gap = base + d * 1.42
    magnet = pose(mag, tuple(base), (0, -52, 0), name="Magnet")
    perp = sl.Vector((-d.z, 0, d.x))
    orbs, dist, prev = [], 0.0, 0.0
    for i, rad in enumerate((0.9, 0.72, 0.56)):
        dist += (0.18 if i == 0 else 0.06) + rad + (0 if i == 0 else prev)
        prev = rad
        c = gap + d * dist
        orbs.append(sl.orb((c.x, -0.2 + 0.05 * i, c.z), rad, sparkles=i == 0))
    # Pull lines: chunky pale dashes either side of the orb trail, parallel to the pull.
    dash = M(ck.mix("White", "Grape", 0.12), emission=0.4)
    lines = []
    phi = math.atan2(d.z, d.x)
    for t, off in ((0.75, 1.12), (0.75, -1.12), (2.35, 0.94), (2.35, -0.94)):
        c = gap + d * t + perp * off
        cap = ck.capsule(0.11, 0.6, 12, 3, dash, "Dash", (c.x, -0.3, c.z), axis="X")
        cap.rotation_euler = (0, math.pi / 2 - phi, 0)
        lines.append(cap)
    return [pose([magnet] + orbs + lines, rotation=(0, 0, -6))], {}


def circ_arrow(R, a0, a1, y, mat, minor=0.17):
    """Arc in the XZ plane from a0 to a1 degrees (counter-clockwise seen from -Y) with a fat head."""
    pts = [(R * math.cos(math.radians(a)), y, R * math.sin(math.radians(a)))
           for a in [a0 + (a1 - a0) * k / 16 for k in range(17)]]
    parts = [ck.sweep(pts, [minor] * len(pts), 16, mat, "ArrowArc", up=(0, 1, 0))]
    t = math.radians(a1)
    tx, tz = -math.sin(t), math.cos(t)  # tangent along increasing angle
    head = ck.extrude_shape([(0.42, 0.0), (-0.12, 0.38), (-0.12, -0.38)], depth=minor * 2, mat=mat,
                            name="ArrowHead", bevel=0.09, bevel_segments=4)
    e1 = (tx, 0, tz)
    e2 = (-tz, 0, tx)
    m = sl.Matrix(((e1[0], e2[0], 0, 0), (0, 0, -1, 0), (e1[2], e2[2], 0, 0), (0, 0, 0, 1)))
    sl.bake_matrix(head, m)
    head.location = (R * math.cos(t) + tx * 0.08, y, R * math.sin(t) + tz * 0.08)
    parts.append(head)
    return parts


def pass_auto_cash():
    """Gold coin inside two chunky mint circular arrows (auto-collect cash loop)."""
    green = M("Mint")
    c = sl.coin()
    coin_e = pose(c, (0, 0.05, 0), (90, 0, 0), name="Coin")
    arrows = circ_arrow(1.28, 25, 150, -0.05, green) + circ_arrow(1.28, 205, 330, -0.05, green)
    return [pose([coin_e] + arrows, rotation=(-12, 0, 16))], {}


def pass_double_orbs():
    parts = [sl.orb((-0.72, 0.45, 0.3), 0.84, sparkles=False), sl.orb((0.3, -0.3, -0.12), 0.98)]
    parts.append(sl.x2_badge((1.15, -1.35, -0.72), 1.1))
    return parts, {}


def pass_double_cash():
    parts = [sl.bill_stack((-0.75, 0.45, -0.85), 5, rotation=(0, 0, 22), scale=1.2),
             sl.standing_coin((0.2, -0.35, 0.05), 0.92, turn=10)]
    parts.append(sl.x2_badge((1.15, -1.35, -0.7), 1.1))
    return parts, {}


def pass_vip_cracker():
    """Golden carnival mallet with pink end caps and a crown riding on the head."""
    gold = M("Sunny")
    pink = M("HotPink")
    head = [ck.lathe(ck.round_profile(0, 0.78, -1.0, 1.0, 0.28, 4), 40, gold, "Head")]
    for z in (-0.74, 0.74):
        head.append(ck.lathe(ck.round_profile(0.5, 0.83, z - 0.14, z + 0.14, 0.06, 2), 40, pink, "Cap"))
    head.append(ck.lathe(ck.round_profile(0.5, 0.81, -0.12, 0.12, 0.05, 2), 40, pink, "Belt"))
    head_e = pose(head, (0, 0, 0), (0, 90, 0), name="MalletHead")
    stripes = M("Cream")
    handle = [ck.capsule(0.24, 1.9, 20, 4, stripes, "Handle", (0, 0, -1.3))]
    for z in (-1.0, -1.5, -2.0):
        handle.append(ck.torus(0.24, 0.075, 24, 8, mat=M("Coral"), name="Stripe", location=(0, 0, z)))
    handle.append(ck.sphere(0.34, 24, 12, pink, "Knob", (0, 0, -2.3)))
    sn = sl.Vector((0, -math.sin(math.radians(62)), math.cos(math.radians(62))))
    streak = ck.gloss_streak([(x, sn.y * 0.81, sn.z * 0.81) for x in (-0.66, -0.44, -0.22, 0.0)], 0.12, sn)
    cr = sl.crown((0.05, 0.0, 0.6), 0.74, (0, 0, -8))
    mallet = pose([head_e, streak, cr] + handle, (0, 0, 0.5), (0, -24, 8), name="Mallet")
    parts = [mallet, sl.sparkle((-1.6, -0.6, 1.45), 0.34), sl.sparkle((1.2, -0.6, -1.0), 0.28)]
    return parts, {}


def golden_key():
    """Chunky golden key along X (bow at +X, teeth at -X), facing -Y: a big fat ring bow with a cobalt
    gem, a collar, a fat shaft and two square teeth. Unposed parts."""
    gold = M(ck.mix("Sunny", "White", 0.08))
    deep = M(ck.mix("Sunny", "Orange", 0.35))
    bow = ck.torus(0.58, 0.29, 48, 16, mat=gold, name="Bow", location=(1.05, 0, 0))
    bow.rotation_euler = (math.radians(90), 0, 0)
    gem = ck.sphere(0.32, 32, 16, M(ck.mix("Cobalt", "Blue", 0.3), roughness=0.1, coat=0.95), "BowGem",
                    (1.05, 0, 0))
    gem.scale = (1.0, 0.6, 1.0)
    parts = [bow, gem,
             ck.capsule(0.33, 0.4, 24, 4, deep, "Collar", (0.32, 0, 0), axis="X"),
             ck.capsule(0.25, 1.85, 24, 4, gold, "Shaft", (-0.5, 0, 0), axis="X")]
    for x, h in ((-1.17, 0.62), (-0.72, 0.48)):
        parts.append(ck.rounded_box((0.36, 0.42, h), 0.12, 3, gold, "Tooth", (x, 0, -h + 0.06)))
    parts.append(ck.gloss_streak([(x, -0.19, 0.15) for x in (-1.1, -0.8, -0.5, -0.2)], 0.12, (0, -0.6, 0.8)))
    parts.append(ck.gloss_streak([(1.05 + 0.58 * math.cos(math.radians(a)), -0.29, 0.58 * math.sin(math.radians(a)))
                                  for a in (115, 135, 155)], 0.13, (0, -1, 0)))
    return parts


def pass_crate_key():
    """Crate Master pass: a teal crate with a sunny lid and coral bands, and a smaller fat golden key in
    front of its lower-right corner at a diagonal (bow outside the crate), so both shapes read apart."""
    crate = sl.crate("KeyCrate", rotation=(0, 0, -16), location=(-0.3, 0.45, 0.2))
    key = pose(golden_key(), (0.9, -1.45, 0.35), (0, 38, 14), scale=0.66, name="Key")
    return [crate, key], dict(FULL)


# ------------------------------------------------------------------------------------------------
# Cash packs
# ------------------------------------------------------------------------------------------------


def cash_pack1():
    parts = [sl.coin_stack((-0.4, 0.3, 0), 3, 0.72, seed=2),
             sl.standing_coin((0.42, -0.55, 0.9), 0.9, turn=18),
             pose(sl.coin(0.5, sign=False, segments=36), (-0.75, -0.75, 0.1), (0, 0, 0))]
    return [pose(parts, rotation=(0, 0, 0))], {}


def cash_pack2():
    parts = [sl.coin_stack((-0.62, 0.45, 0), 7, 0.62, seed=4), sl.coin_stack((0.42, 0.5, 0), 4, 0.62, seed=7),
             sl.coin_stack((-0.1, -0.55, 0), 3, 0.62, seed=9),
             sl.standing_coin((0.95, -0.55, 0.62), 0.66, turn=22)]
    return [pose(parts)], {}


# Packs 3 to 6 climb one clear ladder with a few big shapes each: one money bag, two bags and a coin
# stack, an open teal treasure chest full of gold, and a big chunky teal vault with a sunny door wheel
# and a gold heap at its base. Every redone icon is framed like the HUD set (FULL: bounding box at 85%).
FULL = {"pad": 0.075, "fill": None}


def cash_pack3():
    """One money bag with a big "$"."""
    return [sl.money_bag((0, 0, 0), 1.0, rotation=(0, 0, 18))], dict(FULL)


def cash_pack4():
    """Two money bags side by side and a short coin stack in front."""
    parts = [sl.money_bag((-0.62, 0.3, 0), 1.0, rotation=(0, 0, 22)),
             sl.money_bag((1.0, 0.75, 0), 0.8, rotation=(0, 0, 8)),
             sl.coin_stack((0.42, -1.05, 0), 3, 0.66, seed=4)]
    return [pose(parts)], dict(FULL)


def cash_pack5():
    """Open teal treasure chest with gold bands, heaped with gold and three big coins."""
    chest = sl.crate("Treasure", open_deg=105, rotation=(0, 0, -14))
    fill = sl.gold_heap((0, -0.05, sl.H - 0.15), 1.32, 1.1, [(-90, 0.6, 0.52, 22), (-30, 0.32, 0.5, 16),
                                                            (-150, 0.32, 0.5, 16)], ry=0.72)
    return [chest, pose([fill], rotation=(0, 0, -14))], dict(FULL)


def vault():
    """Big chunky teal vault on a cobalt plinth with a cobalt top trim: a round cobalt door on the front
    with a fat sunny four-spoke wheel (ball ends, round hub) and a gold heap with big coins at its base.
    Front toward -Y, base at z = 0."""
    body_m = ck.gradient_material("Vault", [(0.0, ck.mix("Teal", "TealDeep", 0.45)), (0.55, "Teal"),
                                            (1.0, ck.mix("Teal", "TealLight", 0.6))], lo=0.3, hi=3.0)
    trim = M(ck.mix("Cobalt", "Blue", 0.25))
    door_m = M(ck.mix("Cobalt", "Blue", 0.45))
    rim_m = M(ck.mix("Cobalt", "BlueDeep", 0.15))
    wheel = M(ck.mix("Sunny", "White", 0.1))
    knob = M(ck.mix("Sunny", "White", 0.4))
    bw, bd, bh = 2.7, 2.0, 2.75
    fy = -bd / 2
    parts = [ck.rounded_box((bw + 0.34, bd + 0.34, 0.42), 0.16, 4, trim, "Plinth", (0, 0, 0.0)),
             ck.rounded_box((bw, bd, bh), 0.38, 5, body_m, "Vault", (0, 0, 0.3)),
             ck.rounded_box((bw + 0.18, bd + 0.18, 0.32), 0.14, 4, trim, "TopTrim", (0, 0, 0.3 + bh - 0.26))]
    dz, dr = 1.72, 0.98
    door = ck.lathe(ck.round_profile(0, dr, -0.14, 0.14, 0.1, 4), 56, door_m, "Door")
    door.rotation_euler = (math.radians(90), 0, 0)
    door.location = (0, fy - 0.08, dz)
    rim = ck.torus(dr + 0.02, 0.12, 64, 12, mat=rim_m, name="DoorRim")
    rim.rotation_euler = (math.radians(90), 0, 0)
    rim.location = (0, fy - 0.1, dz)
    parts += [door, rim]
    # Sunny door wheel: a fat ring, two crossing spokes with ball ends and a round hub.
    wy = fy - 0.36
    ring = ck.torus(0.5, 0.13, 48, 12, mat=wheel, name="WheelRing")
    ring.rotation_euler = (math.radians(90), 0, 0)
    ring.location = (0, wy, dz)
    parts.append(ring)
    for ang in (45, 135):
        c, sn = math.cos(math.radians(ang)), math.sin(math.radians(ang))
        parts.append(ck.sweep([(-0.74 * c, wy, dz - 0.74 * sn), (0.74 * c, wy, dz + 0.74 * sn)], [0.11, 0.11], 16,
                              wheel, "Spoke", up=(0, -1, 0)))
        for sgn in (-1, 1):
            parts.append(ck.sphere(0.2, 24, 12, knob, "Knob", (sgn * 0.8 * c, wy, dz + sgn * 0.8 * sn)))
    hub = ck.lathe(ck.round_profile(0, 0.26, -0.1, 0.1, 0.07, 3), 36, wheel, "Hub")
    hub.rotation_euler = (math.radians(90), 0, 0)
    hub.location = (0, wy - 0.06, dz)
    parts.append(hub)
    for z in (dz - 0.55, dz + 0.55):  # hinges on the door's left edge
        parts.append(ck.capsule(0.14, 0.5, 20, 4, rim_m, "Hinge", (-dr - 0.06, fy - 0.12, z), axis="Z"))
    pile = sl.gold_heap((0.3, fy - 0.5, 0.0), 1.3, 0.9, [(-62, 0.45, 0.5, 18), (-118, 0.28, 0.46, 12),
                                                        (-12, 0.3, 0.44, 12)], ry=0.6)
    gl = ck.gloss_streak([(-1.06, fy - 0.02, z) for z in (2.75, 2.5, 2.25, 2.0)], 0.14, (0, -1, 0))
    gl2 = ck.gloss_streak([(-1.0 + 0.34 * k, -0.3, 0.3 + bh + 0.065) for k in range(4)], 0.12, (0, -0.3, 1))
    return parts + [pile, gl, gl2]


def cash_pack6():
    """The top pack: a big chunky teal vault with a sunny door wheel and a gold heap at its base."""
    return [pose(vault(), rotation=(0, 0, -8))], dict(FULL)


# ------------------------------------------------------------------------------------------------
# Gem packs
# ------------------------------------------------------------------------------------------------


# All three gem packs use the same vivid blue-cyan gem (pale highlight facet); the containers step
# from a bare cluster to a grape pouch to a big candy-pink gold-studded chest with a spilling heap.


def gem_pack1():
    parts = [sl.gem((-0.66, 0.4, 1.25), 0.74, (-8, 14, 0), kind="vivid"),
             sl.gem((0.7, 0.35, 1.05), 0.68, (-10, -16, 0), kind="vivid"),
             sl.gem((0.0, -0.4, 1.25), 1.0, (-10, 0, 0), kind="vivid")]
    return parts + [sl.sparkle((1.05, -0.9, 2.25), 0.3)], {"fill": 0.42}


def gem_pack2():
    """Grape velvet pouch with gems poking out of the open top and one in front."""
    pouch_m = M("Grape", roughness=0.45, coat=0.4)
    prof = [(0, 0.0), (0.6, 0.02), (0.98, 0.2), (1.16, 0.55), (1.12, 0.9), (0.92, 1.18), (0.66, 1.34),
            (0.58, 1.4), (0.72, 1.5), (0.86, 1.62), (0.84, 1.72), (0.7, 1.74), (0, 1.62)]
    pouch = ck.lathe(prof, 48, pouch_m, "Pouch", smooth_angle=70)
    for v in pouch.data.vertices:
        if v.co.z > 1.42:
            a = math.atan2(v.co.y, v.co.x)
            f = 1 + 0.12 * math.sin(6 * a) * min(1.0, (v.co.z - 1.42) / 0.25)
            v.co.x *= f
            v.co.y *= f
    cord = ck.torus(0.62, 0.1, 32, 10, mat=M("Sunny"), name="Cord", location=(0, 0, 1.36))
    tassel = ck.sweep([(0.2, -0.58, 1.36), (0.3, -0.75, 1.1), (0.34, -0.8, 0.85)], [0.08, 0.08, 0.08], 10,
                      M("Sunny"), "Tassel")
    bead = ck.sphere(0.14, 16, 8, M("Sunny"), "Bead", (0.34, -0.8, 0.8))
    gl = ck.gloss_streak([(-0.64, -0.82, 0.98), (-0.84, -0.62, 0.78), (-0.98, -0.4, 0.56)], 0.13,
                         (-0.6, -0.6, 0.3))
    gems = [sl.gem((-0.28, 0.1, 1.88), 0.5, (-12, -24, 0), kind="vivid"),
            sl.gem((0.32, 0.18, 1.98), 0.56, (-14, 20, 0), kind="vivid"),
            sl.gem((0.0, -0.22, 1.82), 0.44, (-30, 0, 0), kind="vivid"),
            sl.gem((1.15, -0.85, 0.6), 0.5, (-12, -12, 0), kind="vivid")]
    return [pose([pouch, cord, tassel, bead, gl] + gems, rotation=(0, 0, -6))], {"fill": 0.45}


def gem_pack3():
    """Big candy-pink, gold-studded chest with a heap of vivid gems spilling out and sparkles."""
    chest = sl.crate("GemChest", open_deg=108, rotation=(0, 0, -14))
    fill = sl.heap((0, 0, sl.H - 0.12), 1.32, 0.75, 0, seed=41, mound_color=ck.mix("Blue", "CyanPop", 0.5),
                   ry=0.74)
    rng = random.Random(42)
    gems = []
    spots = [(-0.72, 0.1, 0.5), (0.72, 0.15, 0.5), (-0.3, 0.3, 0.56), (0.3, 0.32, 0.56), (0.0, -0.05, 0.72),
             (-0.55, -0.45, 0.5), (0.55, -0.42, 0.5)]
    for i, (x, y, sc) in enumerate(spots):
        z = sl.H + 0.75 - 0.4 * (abs(x) + abs(y))
        gems.append(sl.gem((x, y, z + 0.3), sc, (rng.uniform(-30, 5), rng.uniform(-24, 24), rng.uniform(0, 45)),
                           kind="vivid"))
    inner = pose([fill] + gems, rotation=(0, 0, -14))
    front = [sl.gem((-0.72, -1.25, 0.3), 0.46, (-78, 0, 30), kind="vivid"),
             sl.gem((0.7, -1.2, 0.5), 0.5, (-14, -10, 8), kind="vivid")]
    return [chest, inner] + front + [sl.sparkle((1.0, -0.7, 3.05), 0.48), sl.sparkle((-1.05, -0.7, 2.8), 0.3)], \
        {"fill": 0.52}


# ------------------------------------------------------------------------------------------------
# Aura packs
# ------------------------------------------------------------------------------------------------


# The game's aura orb paint (Theme.OrbColors tiers 1..5): violet, hot pink, sunny yellow, mint, sky
# blue. Each orb is the shoplib proof orb (self-lit sphere, white gloss pill and dot) with a
# FACING ramp in its tier colour: pale core, full colour, a deeper band and a coloured rim.
AURA = {
    "violet": [(0.0, ck.mix("Grape", "White", 0.35)), (0.4, "Grape"), (0.75, "GrapeDeep"), (1.0, "Magenta")],
    "pink": [(0.0, ck.mix((255, 92, 170), "White", 0.4)), (0.4, (255, 92, 170)),
             (0.75, ck.mix((255, 92, 170), "GrapeDeep", 0.3)), (1.0, "Magenta")],
    "yellow": [(0.0, ck.mix((255, 208, 64), "White", 0.45)), (0.4, (255, 208, 64)),
               (0.75, ck.mix((255, 208, 64), "Orange", 0.6)), (1.0, ck.mix("Orange", "Coral", 0.35))],
    "mint": [(0.0, ck.mix((72, 214, 150), "White", 0.4)), (0.4, (72, 214, 150)),
             (0.75, ck.mix((72, 214, 150), "Emerald", 0.6)), (1.0, ck.mix((72, 214, 150), "CyanPop", 0.45))],
    "sky": [(0.0, ck.mix((80, 170, 255), "White", 0.4)), (0.4, (80, 170, 255)), (0.75, "BlueDeep"),
            (1.0, ck.mix((80, 170, 255), "Grape", 0.4))],
}


def aura_orb(location, r, tier="violet", sparkles=False):
    """One aura orb of radius r in a Theme.OrbColors tier colour (see AURA), as a posable empty."""
    key = "aura_" + tier
    mat = sl._mats.get(key)
    if mat is None:
        mat = ck.gradient_material("Aura_" + tier, AURA[tier], mode="FACING", emission=0.14, roughness=0.15,
                                   coat=0.9)
        sl._mats[key] = mat
    white = M("White", roughness=0.3, coat=0.0, emission=1.2)
    o = ck.sphere(1.0, 48, 24, mat, "AuraOrb")
    gl = ck.capsule(0.15, 0.62, 16, 4, white, "Gloss", axis="Z")
    gl.location = (-0.5, -0.6, 0.5)
    gl.rotation_euler = (0.8, -0.6, 0.7)
    gl.scale = (1.0, 0.4, 1.0)
    dot = ck.sphere(0.085, 16, 8, white, "GlossDot", (-0.2, -0.86, 0.5))
    dot.scale = (1.0, 0.5, 1.0)
    parts = [o, gl, dot]
    if sparkles:
        st = ck.extrude_shape(ck.star_points(4, 0.4, 0.15, round_steps=2, rotate=90), depth=0.14,
                              mat=M(ck.mix("Sunny", "White", 0.45), emission=0.6), name="OrbSparkle", bevel=0.045)
        st.location = (0.42, -1.0, 0.36)
        st.rotation_euler = (1.45, 0.0, 0.4)
        parts.append(st)
    return pose(parts, location, scale=r, name="AuraOrb")


def orbs(spec):
    """[(x, y, z, r, tier[, sparkles]), ...] -> aura orbs."""
    return [aura_orb((x, y, z), r, tier, bool(rest and rest[0])) for x, y, z, r, tier, *rest in spec]


def aura_pack1():
    """A small cluster of three orbs: violet and pink side by side, a sunny one on top."""
    parts = orbs([(-0.8, 0.0, 0.0, 0.85, "violet", True), (0.8, 0.15, 0.0, 0.8, "pink"),
                  (0.02, 0.35, 1.22, 0.74, "yellow")])
    return [pose(parts, rotation=(0, 0, -6))], {}


def aura_pack2():
    """A heap of seven orbs (three, two, one, and one rolling in front) with two sparkles."""
    r = 0.62
    parts = orbs([(-1.24, 0.0, 0.0, r, "pink"), (0.0, -0.1, 0.0, r, "violet", True), (1.24, 0.0, 0.0, r, "mint"),
                  (-0.62, 0.25, 1.05, r, "sky"), (0.62, 0.25, 1.05, r, "yellow"),
                  (0.0, 0.45, 2.08, r, "violet"), (1.55, -1.0, -0.2, 0.44, "pink")])
    parts = [pose(parts, rotation=(0, 0, -6))]
    return parts + [sl.sparkle((-1.55, -0.8, 1.75), 0.32), sl.sparkle((1.3, -0.7, 2.15), 0.26)], {}


def aura_bowl(radius=1.75, height=1.0):
    """Wide sunny gold bowl (gold-deep foot and fat rim) with a glowing violet mound filling it."""
    gold = M(ck.mix("Sunny", "White", 0.06))
    deep = M(ck.mix("Sunny", "Orange", 0.4))
    prof = [(0, 0.0), (radius * 0.45, 0.0), (radius * 0.62, 0.08), (radius * 0.86, height * 0.4),
            (radius * 0.98, height * 0.85), (radius, height)]
    bowl = ck.lathe(prof, 56, gold, "Bowl", smooth_angle=60)
    foot = ck.lathe(ck.round_profile(0, radius * 0.5, -0.22, 0.04, 0.08, 3), 48, deep, "Foot")
    rim = ck.torus(radius, 0.13, 64, 12, mat=deep, name="BowlRim", location=(0, 0, height))
    band = ck.torus(radius * 0.88, 0.07, 64, 8, mat=deep, name="BowlBand", location=(0, 0, height * 0.5))
    fill = ck.lathe([(0, height + 0.45), (radius * 0.6, height + 0.32), (radius * 0.97, height - 0.05), (0, height - 0.05)],
                    48, sl._mats["aura_violet"], "AuraFill", smooth_angle=80)
    gl = ck.gloss_streak([(radius * 0.92 * math.cos(math.radians(a)), radius * 0.92 * math.sin(math.radians(a)),
                           height * 0.68) for a in (-150, -138, -126, -114)], 0.14, (-0.5, -0.6, 0.3))
    return [bowl, foot, rim, band, fill, gl]


def aura_pack3():
    """A big golden bowl brimming with a glowing heap of nine big orbs, sparkles and a soft violet glow."""
    r = 0.6
    heap = orbs([(-1.15, -0.55, 1.2, r, "pink"), (0.0, -0.95, 1.15, r, "violet", True), (1.15, -0.55, 1.2, r, "mint"),
                 (-1.05, 0.65, 1.3, r, "sky"), (1.05, 0.65, 1.3, r, "violet"),
                 (-0.6, -0.15, 2.05, r, "yellow"), (0.62, -0.1, 2.05, r, "sky"), (0.0, 0.7, 2.05, r, "pink"),
                 (0.0, 0.1, 2.95, 0.62, "violet")])
    bowl = aura_bowl()  # after the orbs: the bowl's fill reuses the violet orb material
    parts = [pose(bowl + heap, rotation=(0, 0, -8))]
    parts += [sl.sparkle((-1.75, -0.9, 2.75), 0.36), sl.sparkle((1.6, -0.9, 3.1), 0.3),
              sl.sparkle((1.95, -1.2, 0.9), 0.24)]
    return parts, {"glow": ("Grape", 0.6)}


def aura_pack4():
    """The top pack: the golden bowl overflowing with a tall heap of big orbs in every aura colour,
    orbs spilling over the rim and onto the ground, the strongest violet glow and big sparkles."""
    r = 0.6
    heap = orbs([(-1.15, -0.55, 1.2, r, "pink"), (0.0, -0.95, 1.15, r, "violet", True), (1.15, -0.55, 1.2, r, "mint"),
                 (-1.05, 0.65, 1.3, r, "sky"), (1.05, 0.65, 1.3, r, "violet"),
                 # a wide dome of five on top, two more above it and a crowning orb
                 (-1.25, -0.2, 2.15, r, "yellow"), (0.0, -0.35, 2.0, r, "sky"), (1.25, -0.15, 2.15, r, "pink"),
                 (-0.6, 0.75, 2.1, r, "mint"), (0.6, 0.8, 2.1, r, "yellow"),
                 (-0.62, 0.05, 2.95, r, "violet"), (0.62, 0.1, 2.95, r, "mint"), (0.0, 0.55, 3.6, 0.58, "pink", True),
                 # spilling over the front rim, then out on the ground in front of the bowl
                 (-1.6, -1.3, 1.0, 0.5, "yellow"), (1.7, -1.15, 0.98, 0.5, "sky"),
                 (-0.55, -2.15, 0.25, 0.46, "mint"), (0.75, -2.2, 0.2, 0.4, "violet")])
    bowl = aura_bowl()
    parts = [pose(bowl + heap, rotation=(0, 0, -8))]
    parts += [sl.sparkle((-1.75, -1.0, 3.25), 0.46), sl.sparkle((1.7, -1.0, 3.35), 0.4),
              sl.sparkle((2.15, -1.4, 1.75), 0.28), sl.sparkle((-2.15, -1.4, 0.3), 0.26)]
    return parts, {"glow": ("Grape", 1.0)}


# ------------------------------------------------------------------------------------------------
# Rewards and misc
# ------------------------------------------------------------------------------------------------


def heart_points(n=72):
    pts = []
    for k in range(n):
        t = 2 * math.pi * (1 - k / n)  # reversed: counter-clockwise
        x = 16 * math.sin(t) ** 3
        y = 13 * math.cos(t) - 5 * math.cos(2 * t) - 2 * math.cos(3 * t) - math.cos(4 * t)
        pts.append((x / 16 * 1.08, (y + 2) / 16))
    return pts


def heart():
    h = ck.extrude_shape(heart_points(), depth=0.82, mat=M("HotPink"), name="Heart", bevel=0.34,
                         bevel_segments=6)
    sl.bake_matrix(h, sl.TO_XZ)
    gl = ck.gloss_streak([(-0.72, -0.43, 0.18), (-0.68, -0.43, 0.36), (-0.56, -0.43, 0.48), (-0.4, -0.43, 0.52)],
                         0.14, (0, -1, 0))
    dot = ck.sphere(0.07, 14, 7, ck.gloss_material(), "GlossDot", (-0.74, -0.43, -0.02))
    dot.scale = (1, 0.4, 1)
    return [pose([h, gl, dot], rotation=(0, 0, 14))], {}


def timer():
    body = M("Blue")
    parts = [ck.lathe(ck.round_profile(0, 1.0, -0.26, 0.26, 0.17, 4), 56, body, "Case"),
             ck.lathe(ck.round_profile(0, 0.8, 0.12, 0.3, 0.06, 2), 56, M("Cream"), "Face")]
    wedge = [(0.0, 0.0)] + [(0.66 * math.cos(math.radians(a)), 0.66 * math.sin(math.radians(a)))
                            for a in range(-40, 91, 10)]
    w = ck.extrude_shape(wedge, depth=0.05, mat=M("Mint"), name="Elapsed", bevel=0.02, bevel_segments=2)
    w.location = (0, 0, 0.31)
    parts.append(w)
    tick = M(ck.mix("Blue", "BlueDeep", 0.4))
    for a in (90, 0, 180, 270):
        aa = math.radians(a)
        tb = ck.rounded_box((0.1, 0.2, 0.07), 0.04, 2, tick, "Tick", (0.64 * math.cos(aa), 0.64 * math.sin(aa), 0.3))
        tb.rotation_euler = (0, 0, aa - math.pi / 2)
        parts.append(tb)
    hand = ck.capsule(0.07, 0.72, 12, 3, M("Coral"), "Hand", axis="X")
    hand.location = (0.26 * math.cos(math.radians(-40)), 0.26 * math.sin(math.radians(-40)), 0.37)
    hand.rotation_euler = (0, math.radians(90), math.radians(-40))
    parts.append(hand)
    parts.append(ck.sphere(0.12, 20, 10, M("Coral"), "Hub", (0, 0, 0.36)))
    # Crown stem and button on top (+Y = up once stood), and a small side button.
    parts.append(ck.capsule(0.14, 0.44, 16, 3, M("Steel"), "Stem", (0, 1.06, 0), axis="Y"))
    parts.append(ck.capsule(0.22, 0.62, 20, 4, M("Coral"), "Button", (0, 1.3, 0), axis="X"))
    side = ck.capsule(0.13, 0.4, 16, 3, M("Coral"), "SideButton", axis="Y")
    side.location = (0.82, 0.82, 0)
    side.rotation_euler = (math.radians(90), 0, math.radians(-45))
    parts.append(side)
    parts.append(ck.gloss_streak([(0.9 * math.cos(math.radians(a)), 0.9 * math.sin(math.radians(a)), 0.27)
                                  for a in (112, 126, 140, 154, 168)], 0.11, (0, 0, 1)))
    return [pose(parts, rotation=(78, 0, 14))], {}


def crown_icon():
    # Turned so the front point and the big band gem face the camera (azimuth 28).
    return [sl.crown(rotation=(10, 0, 28), bright=True)], {}


def chaikin(pts, rounds=3):
    """Closed-curve corner cutting: every round replaces each edge by its 1/4 and 3/4 points, so
    sharp hand-placed outlines become smooth, round-tipped curves."""
    for _ in range(rounds):
        out = []
        for i, p in enumerate(pts):
            q = pts[(i + 1) % len(pts)]
            out += [(0.75 * p[0] + 0.25 * q[0], 0.75 * p[1] + 0.25 * q[1]),
                    (0.25 * p[0] + 0.75 * q[0], 0.25 * p[1] + 0.75 * q[1])]
        pts = out
    return pts


FLAME_OUTER = [(0.0, -1.42), (0.88, -1.22), (1.3, -0.5), (1.24, 0.25), (1.5, 1.12), (1.28, 1.2), (0.72, 0.7),
               (0.66, 1.36), (0.12, 2.3), (-0.12, 2.3), (-0.72, 1.38), (-0.8, 0.82), (-1.36, 1.3), (-1.58, 1.2),
               (-1.3, 0.3), (-1.34, -0.5), (-0.9, -1.22)]
FLAME_INNER = [(0.0, -1.08), (0.66, -0.88), (0.86, -0.25), (0.62, 0.55), (0.12, 1.3), (-0.12, 1.3),
               (-0.64, 0.55), (-0.86, -0.25), (-0.66, -0.88)]


def fire():
    """Friendly multiplier flame: one fat, puffy three-lobed flame (a tall round-tipped centre lobe and
    two shorter round side lobes) in red-orange, a sunny inner flame and a cream core, each a thick
    slab with big round bevels stacked toward the camera."""
    outer_m = gi.vgrad("FlameOuter", ck.mix("RedOrange", "Orange", 0.35), "RedOrange", -1.4, 2.3)
    inner_m = gi.vgrad("FlameInner", ck.mix("Sunny", "White", 0.3), ck.mix("Sunny", "Orange", 0.3), -1.1, 1.3)
    core_m = M("Cream", emission=0.12)
    outer = gi.glyph(gi.ccw(chaikin(FLAME_OUTER)), 0.62, outer_m, "FlameOuter", bevel=0.26, segments=6, y=0.1)
    inner = gi.glyph(gi.ccw(chaikin(FLAME_INNER)), 0.5, inner_m, "FlameInner", bevel=0.2, segments=5, y=-0.2)
    core_pts = [(x * 0.52, -0.62 + (z + 1.08) * 0.52) for x, z in FLAME_INNER]
    core = gi.glyph(gi.ccw(chaikin(core_pts)), 0.36, core_m, "FlameCore", bevel=0.14, segments=4, y=-0.46)
    parts = [outer, inner, core,
             gi.front_streak([(-1.0, 0.0), (-1.02, 0.35), (-0.96, 0.7)], 0.16, -0.21),
             gi.front_streak([(-0.42, 0.2), (-0.3, 0.5), (-0.16, 0.8)], 0.12, -0.45)]
    return [pose(parts, rotation=(0, 0, 12))], dict(FULL)


def gift2():
    """Big golden daily gift: gold box and lid, hot-pink ribbon and bow, a couple of sparkles."""
    box_m = M("Sunny")
    lid_m = M(ck.mix("Sunny", "Orange", 0.3))
    rib = M("HotPink")
    parts = [
        ck.rounded_box((1.7, 1.7, 1.35), 0.2, 4, box_m, "Box"),
        ck.rounded_box((1.94, 1.94, 0.46), 0.17, 4, lid_m, "Lid", (0, 0, 1.26)),
        ck.rounded_box((0.44, 1.76, 1.34), 0.12, 3, rib, "RibbonX", (0, 0, 0.005)),
        ck.rounded_box((1.76, 0.44, 1.34), 0.12, 3, rib, "RibbonY", (0, 0, 0.005)),
        ck.rounded_box((0.46, 1.98, 0.48), 0.13, 3, rib, "LidRibX", (0, 0, 1.25)),
        ck.rounded_box((1.98, 0.46, 0.48), 0.13, 3, rib, "LidRibY", (0, 0, 1.25)),
    ]
    for side in (-1, 1):
        loop = ck.torus(0.36, 0.16, 32, 12, mat=rib, name="Loop")
        loop.location = (side * 0.42, 0, 2.06)
        loop.rotation_euler = (math.radians(90), math.radians(side * 30), 0)
        loop.scale = (1.15, 1.0, 1.0)
        parts.append(loop)
        tail = ck.sweep([(side * 0.12, -0.25, 1.8), (side * 0.32, -0.7, 1.8), (side * 0.5, -1.04, 1.6)],
                        [0.13, 0.12, 0.11], 12, rib, "Tail", flatten=0.5)
        parts.append(tail)
    parts.append(ck.sphere(0.25, 24, 12, rib, "Knot", (0, 0, 1.86)))
    parts.append(ck.gloss_streak([(-0.78, -0.985, 1.5), (-0.62, -0.985, 1.5), (-0.46, -0.985, 1.5), (-0.34, -0.985, 1.5)],
                                 0.1, (0, -1, 0)))
    parts.append(ck.gloss_streak([(-0.6, -0.86, 0.95), (-0.6, -0.86, 0.6), (-0.6, -0.86, 0.3)], 0.11,
                                 (0, -1, 0)))
    g = pose(parts, rotation=(0, 0, -14))
    return [g, sl.sparkle((1.35, -0.6, 2.3), 0.36), sl.sparkle((-1.42, -0.5, 1.6), 0.26)], {}


SKINS = [ck.mix("Sand", "Coral", 0.28), ck.mix("Tan", "Coral", 0.12), ck.mix("WoodDark", "Coral", 0.2)]


def fan_head(location, skin, hair, style, scale=1.0):
    """Tiny cheering fan: round head, happy closed eyes, big open smile, blush, hair by `style`."""
    sk = M(skin)
    hm = M(hair)
    ink = M("Ink")
    parts = [ck.sphere(0.5, 32, 16, sk, "Head")]
    for x in (-0.17, 0.17):
        # Bold happy closed eyes (upturned arcs).
        eye = ck.torus(0.085, 0.045, 16, 8, arc=180, mat=ink, name="Eye")
        eye.location = (x, -0.465, 0.07)
        eye.rotation_euler = (math.radians(90), 0, 0)
        parts.append(eye)
        blush = ck.sphere(0.085, 14, 7, M("HotPink"), "Blush", (x * 1.7, -0.4, -0.08))
        blush.scale = (1.0, 0.4, 0.7)
        parts.append(blush)
    # Big open "D" smile (flat top, round bottom), dark inside with a pink tongue.
    smile = [(0.22 * math.cos(math.radians(a)), 0.2 * math.sin(math.radians(a))) for a in range(180, 361, 12)]
    mouth = ck.extrude_shape(smile, depth=0.12, mat=M(ck.mix("Coral", "Ink", 0.55)), name="Mouth", bevel=0.035,
                             bevel_segments=2)
    sl.bake_matrix(mouth, sl.TO_XZ)
    mouth.location = (0, -0.43, -0.08)
    parts.append(mouth)
    tongue = ck.sphere(0.09, 16, 8, M("Coral"), "Tongue", (0, -0.475, -0.22))
    tongue.scale = (1.0, 0.45, 0.55)
    parts.append(tongue)
    if style == "cap":
        cap = ck.sphere(0.5, 32, 16, hm, "Cap", (0, 0.05, 0.2))
        cap.scale = (1.05, 1.05, 0.75)
        parts.append(cap)
        brim = ck.lathe(ck.round_profile(0, 0.32, 0, 0.06, 0.03, 2), 24, hm, "Brim", (0, -0.55, 0.22))
        brim.scale = (1.0, 0.8, 1.0)
        brim.rotation_euler = (math.radians(-8), 0, 0)
        parts.append(brim)
    else:
        # Hair cap set back from the face so the hairline sits above the eyes.
        cap = ck.sphere(0.5, 32, 16, hm, "Hair", (0, 0.14, 0.16))
        cap.scale = (1.05, 1.0, 1.0)
        parts.append(cap)
        if style == "pony":
            parts.append(ck.capsule(0.16, 0.66, 14, 3, hm, "Tail", (0.5, 0.36, 0.12)))
            parts[-1].rotation_euler = (0, math.radians(-28), 0)
            parts.append(ck.sphere(0.1, 12, 6, M("HotPink"), "Scrunchie", (0.42, 0.3, 0.4)))
        else:  # two buns
            for x in (-0.36, 0.36):
                parts.append(ck.sphere(0.2, 16, 8, hm, "Bun", (x, 0.16, 0.5)))
    return pose(parts, location, scale=scale, name="Fan")


def fans():
    """Two big cheering fan faces under a big hot-pink heart sign with a bold white "#1"."""
    hp = [(x * 1.25, y * 1.25) for x, y in heart_points()]
    hrt = ck.extrude_shape(hp, depth=0.42, mat=M("HotPink"), name="SignHeart", bevel=0.16, bevel_segments=5)
    sl.bake_matrix(hrt, sl.TO_XZ)
    label = pose(sl.bold_text("#1", 1.0, "White", ck.mix("HotPink", "Grape", 0.45), depth=0.24, outline=0.05),
                 (0.0, -0.3, 0.12), (90, 0, 0))
    gl = ck.gloss_streak([(-0.98, -0.23, 0.42), (-0.9, -0.23, 0.68), (-0.72, -0.23, 0.86), (-0.52, -0.23, 0.92)],
                         0.15, (0, -1, 0))
    stick = ck.capsule(0.1, 1.5, 12, 3, M("Wood"), "Stick", (0, 0.1, -1.25))
    sign_e = pose([hrt, label, gl, stick], (0, 0.45, 1.75), (4, 0, 0), name="SignBoard")
    heads = [fan_head((-0.68, -0.25, 0.0), SKINS[0], "Sunny", "pony", 1.35),
             fan_head((0.7, -0.15, 0.0), SKINS[2], "Blue", "cap", 1.35)]
    hands = [ck.sphere(0.2, 16, 8, M(SKINS[0]), "Hand", (-1.45, -0.2, 0.95)),
             ck.sphere(0.2, 16, 8, M(SKINS[2]), "Hand", (1.5, -0.1, 0.95))]
    return [pose([sign_e] + heads + hands, rotation=(0, 0, 14)), sl.sparkle((1.75, -0.4, 2.7), 0.32)], {}


ICONS = {
    "CrateCommon": crate_icon("Common"),
    "CrateUncommon": crate_icon("Uncommon"),
    "CrateRare": crate_icon("Rare"),
    "CrateEpic": crate_icon("Epic"),
    "CrateLegendary": crate_icon("Legendary"),
    "PassAutoCollect": pass_auto_collect,
    "PassAutoCash": pass_auto_cash,
    "PassDoubleOrbs": pass_double_orbs,
    "PassDoubleCash": pass_double_cash,
    "PassVipCracker": pass_vip_cracker,
    "PassCrateKey": pass_crate_key,
    "CashPack1": cash_pack1,
    "CashPack2": cash_pack2,
    "CashPack3": cash_pack3,
    "CashPack4": cash_pack4,
    "CashPack5": cash_pack5,
    "CashPack6": cash_pack6,
    "GemPack1": gem_pack1,
    "GemPack2": gem_pack2,
    "GemPack3": gem_pack3,
    "AuraPack1": aura_pack1,
    "AuraPack2": aura_pack2,
    "AuraPack3": aura_pack3,
    "AuraPack4": aura_pack4,
    "Heart": heart,
    "Timer": timer,
    "Crown": crown_icon,
    "Fire": fire,
    "Gift2": gift2,
    "Fans": fans,
}


def main():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    names = argv or list(ICONS)
    for name in names:
        sl.reset()
        sl.reset_gem_cache()
        target, opts = ICONS[name]()
        tris = sl.tri_count(target)
        path = os.path.join(sl.OUT, name + ".png")
        glow = opts.pop("glow", None)
        if glow:
            # The kit's halo forces a 0.13+ pad; frame at a fixed 0.1 pad instead, then redo the sticker
            # from the raw render with the halo (its faint outer tail fades out before the edge).
            ck.render_icon(target, path, fill=None, pad=0.11, **opts)
            raw = os.path.join(sl.OUT, "raw", name + "_raw.png")
            rgb = tuple(round(v * 255) for v in ck.srgb(glow[0]))
            ck.run_pillow(["sticker", raw, path, "--outline", "0.028", "--halo", "%d,%d,%d" % rgb,
                           "--halo-strength", str(glow[1])])
        else:
            ck.render_icon(target, path, **opts)
        print("ICON", name, tris, flush=True)


main()
