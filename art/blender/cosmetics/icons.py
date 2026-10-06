"""Cosmetics shop icons: 512 px transparent PNGs in art/out/icons/<Name>.png, same camera, sticker
outline and shadow as the shop icon set (art/blender/icons_shop).

Run headless through the heavy lock, all icons or a subset by name:
    tools/blender-run.sh art/blender/cosmetics/icons.py -- [Name ...]
Prints "ICON <name> <triangles>" per icon.
"""

import math
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import _cos as cs  # noqa: E402
from _cos import M, ck, pose, sl  # noqa: E402

sys.path.insert(0, os.path.join(HERE, "..", "icons"))
import _icons as gi  # noqa: E402  (HUD glyph helpers: rounded outlines extruded toward the camera)

# Redone icons are framed like the HUD set: the bounding box fills 85% of the square.
FULL = {"pad": 0.075, "fill": None}
MINT_BRIGHT = (95, 240, 192)


def cos_speed():
    """Speedy Sneakers: chunky coral winged high-top with sunny speed dashes behind the heel."""
    return [pose(cs.sneaker(), rotation=(0, -8, 16))], {}


def chevron_bold(top, bottom, dz, depth=0.56):
    """Bold up-chevron with rounded corners in the XZ plane (front toward -Y), shifted up by dz, in a
    `bottom` -> `top` gradient, with a gloss streak down its upper-left arm."""
    pts = [(0.0, 0.72), (-1.22, -0.5), (-0.7, -1.02), (0.0, -0.32), (0.7, -1.02), (1.22, -0.5)]
    pts = gi.rounded_poly([(x, z + dz) for x, z in pts], 0.2, 0.1, 5)
    m = gi.vgrad("Chevron%d" % round(dz * 100), top, bottom, dz - 1.0, dz + 0.7)
    ch = gi.glyph(pts, depth, m, "Chevron", bevel=0.16, segments=5)
    a, b = (-1.22, -0.5 + dz), (0.0, 0.72 + dz)
    gp = [(a[0] + (b[0] - a[0]) * t + 0.15, a[1] + (b[1] - a[1]) * t - 0.15) for t in (0.3, 0.42, 0.54, 0.66)]
    return [ch, gi.front_streak(gp, 0.13, -depth / 2)]


def cos_double_jump():
    """Double Jump: two bold stacked up-chevrons (cyan below, cobalt above) over a puffy white cloud."""
    parts = chevron_bold(ck.mix("CyanPop", "White", 0.3), ck.mix("CyanPop", "Teal", 0.15), -0.4)
    parts += chevron_bold(ck.mix("Cobalt", "Blue", 0.6), "Cobalt", 0.82)
    parts.append(cs.puff([((-0.98, 0.05, -1.62), 0.66), ((-0.42, -0.05, -1.42), 0.82), ((0.32, -0.05, -1.42), 0.84),
                          ((0.98, 0.05, -1.62), 0.66), ((0.0, -0.2, -1.78), 0.76)]))
    return [pose(parts, rotation=(0, 0, 12))], dict(FULL)


def cos_trail_rainbow():
    """Rainbow Trail: a candy rainbow ribbon arching out of a thin tail into a white cloud puff."""
    parts = cs.ribbon([(-1.9, 0.5, -1.15), (-1.25, 0.3, -0.5), (-0.5, 0.1, 0.25), (0.35, -0.1, 0.78),
                       (1.1, -0.2, 0.82), (1.6, -0.25, 0.4)], cs.RAINBOW, band_r=0.13, spacing=0.21)
    parts.append(cs.puff([((1.42, -0.35, 0.28), 0.48), ((1.85, -0.35, 0.36), 0.55), ((2.22, -0.3, 0.16), 0.44),
                          ((1.68, -0.5, 0.0), 0.48), ((2.05, -0.5, -0.04), 0.44)]))
    parts += [sl.sparkle((-1.45, -0.4, 0.25), 0.3), sl.sparkle((-0.35, -0.5, -0.75), 0.22),
              sl.sparkle((0.3, -0.5, 1.5), 0.28)]
    return parts, {}


def cos_trail_star():
    """Star Trail: a sunny three-band ribbon streaming from a big star and shedding little stars."""
    parts = cs.ribbon([(-1.95, 0.5, -1.2), (-1.05, 0.3, -0.85), (-0.25, 0.1, -0.2), (0.5, -0.05, 0.55),
                       (1.1, -0.15, 0.95)], cs.SUNNY, band_r=0.17, spacing=0.26)
    parts.append(cs.star((1.3, -0.45, 1.08), 0.78, "Sunny", emission=0.1))
    for loc, size, col in (((-1.3, -0.55, -0.2), 0.2, "Sunny"), ((-0.6, -0.55, -1.15), 0.24, "Orange"),
                           ((-0.1, -0.55, 0.75), 0.22, ck.mix("Sunny", "White", 0.4)),
                           ((0.75, -0.55, -0.35), 0.28, "Sunny"), ((0.15, -0.55, -0.85), 0.17, "Orange")):
        parts.append(cs.star(loc, size, col, emission=0.2, turn=math.degrees(loc[0])))
    parts.append(sl.sparkle((2.0, -0.5, 0.35), 0.26))
    return parts, {}


def cos_trail_rookie():
    """Rookie Trail: a round glossy mint ball flying up and to the right, with three fat curved mint
    motion streaks (mint to white, rounded ends, clear gaps between them) trailing behind it."""
    head_m = ck.gradient_material("Comet", [(0.0, ck.mix(MINT_BRIGHT, "Teal", 0.25)), (0.55, MINT_BRIGHT),
                                            (1.0, ck.mix(MINT_BRIGHT, "White", 0.55))], lo=-0.2, hi=1.8,
                                  emission=0.08)
    c, r = (0.95, -0.1, 0.95), 0.86
    parts = [ck.sphere(r, 48, 24, head_m, "CometHead", c),
             sl.streak_on_sphere(c, r, (-160, -145, -130, -115), polar=50.0)]
    d = sl.Vector((math.cos(math.radians(36)), 0, math.sin(math.radians(36))))  # direction of travel
    n = sl.Vector((-d.z, 0, d.x))  # across the travel, up-left
    cols = [ck.mix(MINT_BRIGHT, "White", 0.5), MINT_BRIGHT, ck.mix(MINT_BRIGHT, "Teal", 0.2)]
    for off, length, half, col in ((0.68, 1.75, 0.22, cols[0]), (0.0, 2.45, 0.3, cols[1]),
                                   (-0.68, 1.75, 0.22, cols[2])):
        start = sl.Vector(c) - d * 0.25 + n * off + sl.Vector((0, 0.35, 0))
        pts, radii = [], []
        for k in range(9):
            t = k / 8
            # Each streak bows the same way (the ball came round a gentle curve) and tapers to a round tip.
            p = start - d * (r * 0.4 + length * t) - n * (0.42 * t * t) + sl.Vector((0, 0.1 * t, 0))
            pts.append(tuple(p))
            radii.append(half * (1.0 - 0.55 * t))
        parts.append(ck.sweep(pts, radii, 16, M(col, emission=0.06), "Streak", flatten=0.6, up=(0, -1, 0)))
    return [pose(parts)], dict(FULL)


def cos_aura():
    """Chad Aura: one bold glowing grape flame-ring halo (three round flame licks on top, a bright inner
    line) around a simple round cobalt head-and-shoulders silhouette. The glow is painted into the
    halo itself, so it stays inside the sticker outline."""
    hc = (0.0, 0.0, 0.62)  # head centre
    R = 1.2
    balls = [((hc[0] + R * math.cos(math.radians(a)), 0.5, hc[2] + R * math.sin(math.radians(a))), 0.66)
             for a in range(0, 360, 18)]
    chains = [balls]
    for a in (58, 90, 122):
        c, s_ = math.cos(math.radians(a)), math.sin(math.radians(a))
        chains.append([((hc[0] + c * (R + 0.18 * k), 0.5, hc[2] + s_ * (R + 0.18 * k)), 0.62 - 0.05 * k)
                       for k in range(5)])
    halo_m = ck.gradient_material("Halo", [(0.0, ck.mix("Grape", "White", 0.4)), (0.5, ck.mix("Grape", "Pink", 0.2)),
                                           (1.0, ck.mix("Grape", "Magenta", 0.45))], mode="FACING", emission=0.3,
                                  roughness=0.25)
    halo = sl.blob("Halo", chains, halo_m)
    sl.bake_matrix(halo, sl.Matrix.Translation((0, 0.5, 0)) @ sl.Matrix.Diagonal((1.0, 0.45, 1.0, 1.0))
                   @ sl.Matrix.Translation((0, -0.5, 0)))
    line = ck.torus(R, 0.11, 72, 12, mat=M(ck.mix("Grape", "White", 0.6), emission=0.6), name="HaloLine")
    line.rotation_euler = (math.radians(90), 0, 0)
    line.location = (hc[0], 0.12, hc[2])
    # Soft glow filling the ring behind the head, so the halo reads as one solid glowing shape.
    glow = ck.lathe(ck.round_profile(0, R, -0.06, 0.06, 0.04, 2), 64,
                    M(ck.mix("Grape", "White", 0.5), emission=0.35, coat=0.2), "HaloGlow")
    glow.rotation_euler = (math.radians(90), 0, 0)
    glow.location = (hc[0], 0.62, hc[2])
    body_m = ck.gradient_material("Bust", [(0.0, "Cobalt"), (1.0, ck.mix("Cobalt", "Blue", 0.55))], lo=-1.1,
                                  hi=1.2)
    head = ck.sphere(0.66, 48, 24, body_m, "Head", hc)
    shoulders = ck.rounded_box((1.9, 0.95, 0.95), 0.42, 5, body_m, "Shoulders", (0, 0, -1.08), taper=0.8)
    parts = [halo, glow, line, head, shoulders, sl.streak_on_sphere(hc, 0.66, (-160, -145, -130, -115), polar=48.0)]
    return parts, dict(FULL)


def cos_crown():
    """Golden Crown: the tall gold crown (five round-tipped spikes with balls, cobalt centre gem, small
    red-orange cushion), gem toward the camera."""
    return [sl.crown_tall(rotation=(12, 0, 28), scale=1.25), sl.sparkle((1.3, -0.7, 1.95), 0.3)], dict(FULL)


def cos_all():
    """All Cosmetics Pack: one open gold-and-teal treasure chest with exactly three big chunky items
    bursting out of it: the tall gold crown in the middle, a glossy aura orb on the left and a big coral
    star on the right."""
    H = sl.H
    chest = sl.crate("TealGold", open_deg=105, rotation=(0, 0, -14))
    inside = [sl.crown_tall((0.05, 0.1, H - 0.1), 1.05, (6, 0, 30)),
              sl.orb((-1.05, -0.3, H + 0.5), 0.78, sparkles=False),
              cs.star((1.12, -0.55, H + 0.72), 0.86, ck.mix("Coral", "White", 0.08), emission=0.05, depth=0.5,
                      turn=-8)]
    contents = pose(inside, rotation=(0, 0, -14), name="Contents")
    return [chest, contents], dict(FULL)


def cos_starter():
    """Starter Pack: one big coral gift box with a mint ribbon and bow and a single large gold star
    badge (on a white backing star) on the front."""
    box_m = M("Coral")
    lid_m = M(ck.mix("Coral", "White", 0.14))
    rib = M("Mint")
    box = [
        ck.rounded_box((1.8, 1.8, 1.4), 0.2, 4, box_m, "Box"),
        ck.rounded_box((2.04, 2.04, 0.46), 0.17, 4, lid_m, "Lid", (0, 0, 1.3)),
        ck.rounded_box((0.46, 1.86, 1.39), 0.12, 3, rib, "RibbonX", (0, 0, 0.005)),
        ck.rounded_box((1.86, 0.46, 1.39), 0.12, 3, rib, "RibbonY", (0, 0, 0.005)),
        ck.rounded_box((0.48, 2.08, 0.48), 0.13, 3, rib, "LidRibX", (0, 0, 1.29)),
        ck.rounded_box((2.08, 0.48, 0.48), 0.13, 3, rib, "LidRibY", (0, 0, 1.29)),
    ]
    for side in (-1, 1):
        loop = ck.torus(0.4, 0.18, 32, 12, mat=rib, name="Loop")
        loop.location = (side * 0.46, 0, 2.14)
        loop.rotation_euler = (math.radians(90), math.radians(side * 30), 0)
        loop.scale = (1.15, 1.0, 1.0)
        box.append(loop)
    box.append(ck.sphere(0.27, 24, 12, rib, "Knot", (0, 0, 1.93)))
    # Gold star badge on the front face, over the ribbon.
    star_m = gi.vgrad("Star", ck.mix("Sunny", "White", 0.3), ck.mix("Sunny", "Orange", 0.4), 0.1, 1.3)
    back = gi.glyph(ck.star_points(5, 0.8, 0.44, round_steps=3), 0.16, M("White"), "StarBack", bevel=0.06,
                    segments=3, y=-0.95)
    star = gi.glyph(ck.star_points(5, 0.66, 0.36, round_steps=3), 0.3, star_m, "Star", bevel=0.11, segments=4,
                    y=-1.02)
    for ob in (back, star):
        ob.location = (0, 0, 0.68)
        gi.bake(ob)
    box += [back, star, gi.front_streak([(-0.1, 0.9), (-0.08, 1.04), (-0.05, 1.16)], 0.08, -1.17)]
    box.append(ck.gloss_streak([(-0.8, -0.92, z) for z in (1.15, 0.9, 0.65)], 0.11, (0, -1, 0)))
    return [pose(box, rotation=(0, 0, 12), name="Gift")], dict(FULL)


ICONS = {
    "CosSpeed": cos_speed,
    "CosDoubleJump": cos_double_jump,
    "CosTrailRainbow": cos_trail_rainbow,
    "CosTrailStar": cos_trail_star,
    "CosTrailRookie": cos_trail_rookie,
    "CosAura": cos_aura,
    "CosCrown": cos_crown,
    "CosAll": cos_all,
    "CosStarter": cos_starter,
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
            # Same as the shop's Legendary crate: frame at a fixed pad, then redo the sticker with a halo.
            ck.render_icon(target, path, fill=None, pad=0.11, **opts)
            raw = os.path.join(sl.OUT, "raw", name + "_raw.png")
            rgb = tuple(round(v * 255) for v in ck.srgb(glow[0]))
            ck.run_pillow(["sticker", raw, path, "--outline", "0.028", "--halo", "%d,%d,%d" % rgb,
                           "--halo-strength", str(glow[1])])
        else:
            ck.render_icon(target, path, **opts)
        print("ICON", name, tris, flush=True)


main()
