"""Navigation icons: Shop (market stall), Modes (big checkered finish flag), Ranking (trophy), Free
(gift), Home (house), Index (book with a star), Invite (friend + plus), Settings (gear).

Ranking and Free are the approved proofs (art/blender/proof/icon_trophy.py, icon_gift.py).
Standalone: tools/blender-run.sh art/blender/icons/nav.py [-- Home Index ...]
"""

import math
import os
import sys

import bmesh

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _icons import (HAIR, SKIN, argv_names, bake, ccw, center_mesh, circle_pts, ck, facing,  # noqa: E402
                    front_streak, glyph, register, render, rounded_poly, shade, vgrad)

NAMES = ["Shop", "Modes", "Ranking", "Free", "Home", "Index", "Invite", "Settings"]


@register("Shop")
def shop():
    """Market stall in three big shapes: a striped sunny/cream awning with a scalloped front edge, a
    teal counter with a cream top (on four chunky white posts) and one big gold coin sign on the
    counter front."""
    counter_m = vgrad("Counter", ck.mix("TealLight", "White", 0.12), "Teal", 0.0, 1.35)
    top_m = ck.toy_material("CounterTop", "Cream")
    post_m = ck.toy_material("Post", "White")
    stripe_m = [ck.toy_material("StripeSunny", "Sunny"), ck.toy_material("StripeCream", "Cream")]
    gold = ck.toy_material("Gold", ck.mix("Sunny", "White", 0.08))
    deep = ck.toy_material("GoldDeep", "GoldDeep")
    front = -0.66  # counter front face (y)
    parts = [
        ck.rounded_box((2.7, 1.32, 1.36), 0.22, 4, counter_m, "Counter", (0, 0, 0)),
        ck.rounded_box((2.98, 1.46, 0.28), 0.13, 4, top_m, "CounterTop", (0, 0, 1.24)),
    ]
    for x in (-1.2, 1.2):
        for y in (-0.5, 0.5):
            parts.append(ck.capsule(0.14, 1.62, 20, 4, post_m, "Post", (x, y, 2.2), axis="Z"))
    # Awning: seven stripes tilted 14 degrees down toward the front, with a scalloped valance.
    n, width, length, tilt = 7, 3.2, 1.75, 14.0
    w = width / n
    cy, cz = -0.05, 3.02
    fy = cy - (length / 2) * math.cos(math.radians(tilt))  # front edge
    fz = cz - (length / 2) * math.sin(math.radians(tilt))
    for i in range(n):
        x = -width / 2 + w * (i + 0.5)
        m = stripe_m[i % 2]
        s = ck.rounded_box((w + 0.012, length, 0.24), 0.08, 3, m, "Stripe", (0, 0, -0.12))
        s.rotation_euler = (math.radians(tilt), 0, 0)
        s.location = (x, cy, cz)
        parts.append(bake(s))
        x0, x1 = x - w / 2, x + w / 2
        top, drop = fz + 0.08, 0.2
        outline = [(x1, top), (x0, top)] + circle_pts(x, top - drop, w / 2, 10, 180, 360)
        parts.append(glyph(ccw(outline), 0.18, m, "Scallop", bevel=0.06, segments=3, y=fy - 0.02))
    # Back roll along the top edge of the awning.
    by = cy + (length / 2) * math.cos(math.radians(tilt))
    bz = cz + (length / 2) * math.sin(math.radians(tilt))
    parts.append(ck.capsule(0.17, width + 0.1, 20, 4, stripe_m[0], "Roll", (0, by - 0.05, bz - 0.06), axis="X"))
    # Gold coin sign standing on the counter front.
    coin = coin_disc(0.62, gold, deep)
    coin.rotation_euler = (math.radians(80), 0, 0)  # leans back on the counter, catching the key light
    coin.location = (0, front - 0.16, 0.66)
    parts.append(coin)
    parts.append(front_streak([(-1.12, 1.02), (-1.14, 0.76), (-1.14, 0.5)], 0.13, front))
    parts.append(ck.gloss_streak([(-1.2 + 0.36 * k, -0.86, 1.47) for k in range(4)], 0.1, (0, -0.4, 1)))
    ck.group(parts, "ShopIcon", rotation=(0, 0, 8))
    return parts


def coin_disc(r, gold, deep):
    """Thick gold coin lying flat (faces +Z) with a rolled rim, an embossed "$" and a gloss streak:
    the HUD Coin scaled to radius r. Returns the coin body; the "$" and streak are its children."""
    k = r / 0.86
    profile = [(0, -0.17), (0.4, -0.155), (0.68, -0.12), (0.76, -0.15)]
    profile += circle_pts(0.86, -0.06, 0.13, 4, -110, 0)
    profile += circle_pts(0.86, 0.06, 0.13, 4, 0, 110)
    profile += [(0.76, 0.15), (0.68, 0.12), (0.4, 0.155), (0, 0.17)]
    body = ck.lathe([(x * k, z * k) for x, z in profile], segments=56, mat=gold, name="Coin", smooth_angle=50)
    sign = ck.text_mesh("$", size=1.1 * k, depth=0.12 * k, bevel=0.035 * k, mat=deep, name="Dollar",
                        font=ck.FONT_BLACK)
    sign.location = (0, 0, 0.16 * k)
    streak = ck.gloss_streak([(0.56 * k * math.cos(math.radians(a)), 0.56 * k * math.sin(math.radians(a)), 0.15 * k)
                              for a in (104, 118, 132, 146, 160)], 0.11 * k, (0, 0, 1))
    for ob in (sign, streak):
        ob.parent = body
    return body


@register("Modes")
def modes():
    """Game modes: a big, wide, waving checkered finish flag (3 x 3 cobalt and cream squares) on a fat
    red-orange pole with a small sunny star on top and a chunky round teal foot."""
    pole_m = vgrad("Pole", ck.mix("RedOrange", "Coral", 0.45), ck.mix("RedOrange", "Coral", 0.1), 0.0, 3.6)
    foot_m = vgrad("Foot", ck.mix("Teal", "TealLight", 0.35), ck.mix("Teal", "TealDeep", 0.35), 0.0, 0.5)
    check_m = [vgrad("CheckBlue", ck.mix("Cobalt", "Blue", 0.4), "Cobalt", 1.0, 3.4),
               ck.toy_material("CheckCream", "Cream", emission=0.08)]
    star_m = vgrad("Star", ck.mix("Sunny", "White", 0.3), ck.mix("Sunny", "Orange", 0.5), -0.45, 0.45)
    cols, rows, sub = 3, 3, 8
    pr = 0.32  # pole radius
    W, H, x0, z0 = 3.0, 2.25, pr - 0.04, 1.1

    def at(u, v):
        # Two big soft waves across the cloth, the free end dipping a little.
        y = 0.34 * math.sin(math.pi * 1.7 * u) * min(1.0, u * 2.5)
        return (x0 + W * u, y, z0 + H * v - 0.22 * u * u + 0.08 * math.sin(math.pi * 1.7 * u) * u)

    bm = bmesh.new()
    nu, nv = cols * sub, rows * sub
    grid = [[bm.verts.new(at(i / nu, j / nv)) for j in range(nv + 1)] for i in range(nu + 1)]
    faces = []
    for i in range(nu):
        for j in range(nv):
            f = bm.faces.new((grid[i][j], grid[i + 1][j], grid[i + 1][j + 1], grid[i][j + 1]))
            faces.append((f, (i // sub + j // sub) % 2))
    for f, idx in faces:
        f.material_index = idx
    flag = ck.mesh_object("Flag", bm, check_m[0])
    flag.data.materials.append(check_m[1])
    solid = flag.modifiers.new("Thick", "SOLIDIFY")
    solid.thickness = 0.2
    solid.offset = 0.0
    ck.soften(flag, width=0.07, segments=2, limit_angle=40.0)
    top = z0 + H + 0.2
    parts = [
        flag,
        ck.capsule(pr, top, 28, 6, pole_m, "Pole", (0, 0, top / 2), axis="Z"),
        ck.lathe(ck.round_profile(0, 0.92, 0.0, 0.46, 0.2, 5), 48, foot_m, "Foot"),
        ck.torus(pr + 0.04, 0.12, 28, 10, mat=ck.toy_material("Collar", "Sunny"), name="Collar",
                 location=(0, 0, top - 0.18)),
    ]
    star = glyph(ck.star_points(5, 0.56, 0.3, round_steps=3), 0.34, star_m, "Star", bevel=0.11, segments=4)
    star.location = (0, 0, top + 0.42)
    parts.append(bake(star))
    parts.append(front_streak([(-0.16, top + 0.52), (-0.09, top + 0.64), (0.0, top + 0.72)], 0.08, -0.19))
    parts.append(ck.gloss_streak([(-0.2, -0.24, z) for z in (0.75, 1.25, 1.75, 2.25, 2.75)], 0.13, (-0.6, -0.8, 0)))
    ck.group(parts, "FlagIcon", rotation=(0, 0, 14))
    return parts


@register("Ranking")
def ranking():
    """Big bright gold trophy cup with fat loop handles and a deep violet star, on a short stem and
    a small rounded orange foot."""
    gold = vgrad("Gold", ck.mix("Sunny", "White", 0.3), ck.mix("Sunny", "Orange", 0.35), 0.6, 2.45)
    handle_m = ck.toy_material("HandleGold", ck.mix("Sunny", "White", 0.12))
    inner = ck.toy_material("Inner", "Orange")
    foot_m = vgrad("Foot", ck.mix("Orange", "Sunny", 0.3), ck.mix("Orange", "Coral", 0.4), 0.0, 0.5)
    star_m = ck.toy_material("Star", ck.DARK)
    parts = [
        ck.lathe(ck.round_profile(0, 0.82, 0.0, 0.42, 0.16, 4), 48, foot_m, "Foot"),
        ck.lathe([(0, 0.36), (0.5, 0.38), (0.36, 0.56), (0.3, 0.98), (0, 1.0)], 40, gold, "Stem"),
        ck.lathe([(0, 0.92), (0.42, 0.94), (0.86, 1.1), (1.16, 1.44), (1.3, 1.9), (1.36, 2.28), (1.32, 2.4),
                  (1.2, 2.44), (0, 2.4)], 48, gold, "Cup"),
        ck.lathe(ck.round_profile(0, 1.12, 2.36, 2.452, 0.035, 2), 40, inner, "Opening"),
    ]
    for side in (1, -1):
        h = ck.torus(0.46, 0.24, 28, 14, arc=230, mat=handle_m, name="Handle")
        h.location = (side * 1.24, 0, 1.78)
        h.rotation_euler = (math.radians(90), math.radians(115 if side > 0 else -65), 0)
        parts.append(h)
    star = ck.extrude_shape(ck.star_points(5, 0.56, 0.3, round_steps=2), depth=0.2, mat=star_m, name="Star",
                            bevel=0.06)
    star.location = (0, -1.17, 1.72)
    star.rotation_euler = (math.radians(78), 0, 0)
    parts.append(star)
    # Gloss streak down the upper-left of the cup, on its lathe surface.
    a = math.radians(236)
    pts = [(math.cos(a) * (r + 0.03), math.sin(a) * (r + 0.03), z) for z, r in ((1.5, 1.18), (1.8, 1.27), (2.12, 1.33))]
    parts.append(ck.gloss_streak(pts, 0.16, (-0.55, -0.8, 0.1)))
    ck.group(parts, "TrophyIcon", rotation=(0, 0, -10))
    return parts


@register("Free")
def free():
    """Coral gift box with a pink lid, sunny ribbon and a big bow."""
    box_m = ck.toy_material("Box", "Coral")
    lid_m = ck.toy_material("Lid", ck.mix("Coral", "Pink", 0.4))
    rib_m = ck.toy_material("Ribbon", "Sunny")
    parts = [
        ck.rounded_box((1.6, 1.6, 1.15), 0.18, 4, box_m, "Box"),
        ck.rounded_box((1.82, 1.82, 0.42), 0.16, 4, lid_m, "Lid", (0, 0, 1.08)),
        ck.rounded_box((0.42, 1.66, 1.14), 0.12, 3, rib_m, "RibbonX", (0, 0, 0.005)),
        ck.rounded_box((1.66, 0.42, 1.14), 0.12, 3, rib_m, "RibbonY", (0, 0, 0.005)),
        ck.rounded_box((0.44, 1.86, 0.44), 0.13, 3, rib_m, "LidRibX", (0, 0, 1.07)),
        ck.rounded_box((1.86, 0.44, 0.44), 0.13, 3, rib_m, "LidRibY", (0, 0, 1.07)),
    ]
    for side in (-1, 1):
        loop = ck.torus(0.3, 0.14, 32, 12, mat=rib_m, name="Loop")
        loop.location = (side * 0.36, 0, 1.8)
        loop.rotation_euler = (math.radians(90), math.radians(side * 30), 0)
        loop.scale = (1.15, 1.0, 1.0)
        parts.append(loop)
    parts.append(ck.sphere(0.22, 24, 12, rib_m, "Knot", (0, 0, 1.56)))
    ck.group(parts, "GiftIcon", rotation=(0, 0, -14))
    return parts


@register("Home")
def home():
    """Little house: butter-yellow walls, a fat coral roof with a ridge roll and chimney, a blue
    door with a sunny knob and a round sky-blue window in a white frame."""
    wall_m = vgrad("Walls", ck.mix("Sunny", "Cream", 0.6), ck.mix("Sunny", "Orange", 0.25), 0.0, 1.9)
    roof_m = vgrad("Roof", ck.mix("Coral", "Pink", 0.25), shade("Coral", "HotPink", 0.35), 1.0, 2.4)
    ridge_m = ck.toy_material("Ridge", shade("Coral", "HotPink", 0.3))
    door_m = vgrad("Door", "Blue", "BlueDeep", 0.0, 0.9)
    knob_m = ck.toy_material("Knob", "Sunny")
    glass_m = ck.toy_material("Window", ck.mix("Pool", "Blue", 0.3), emission=0.1)
    frame_m = ck.toy_material("Frame", "White")
    depth = 1.5
    walls = glyph(rounded_poly([(-0.9, 0), (0.9, 0), (0.9, 1.15), (0, 1.95), (-0.9, 1.15)], 0.14, 0.05),
                  depth, wall_m, "Walls", bevel=0.12)
    parts = [walls]
    slope = math.atan2(0.8, 0.9)
    run = math.hypot(0.9, 0.8)
    thick, over = 0.36, 0.42
    for side in (-1, 1):
        slab = ck.rounded_box((run + over, depth + 0.36, thick), 0.15, 4, roof_m, "Roof")
        center_mesh(slab, (0, 0, -thick / 2))
        nx, nz = side * 0.8 / run, 0.9 / run  # outward normal of this slope
        mx, mz = side * 0.45, 1.55  # middle of the wall's slope edge
        dx, dz = -side * 0.9 / run, 0.8 / run  # up-slope direction
        shift = over / 2 - 0.06
        slab.location = (mx + nx * (thick / 2 - 0.02) - dx * shift, 0, mz + nz * (thick / 2 - 0.02) - dz * shift)
        slab.rotation_euler = (0, side * slope, 0)
        parts.append(bake(slab))
    parts.append(ck.capsule(0.22, depth + 0.42, 20, 4, ridge_m, "Ridge", (0, 0, 2.2), axis="Y"))
    chimney = ck.rounded_box((0.34, 0.34, 0.8), 0.1, 3, ridge_m, "Chimney", (0.5, 0.32, 1.62))
    parts.append(chimney)
    door = ck.rounded_box((0.52, 0.24, 0.86), 0.1, 3, door_m, "Door", (0.27, -depth / 2, 0.0))
    parts.append(door)
    parts.append(ck.sphere(0.07, 16, 8, knob_m, "Knob", (0.4, -depth / 2 - 0.13, 0.42)))
    glass = facing(ck.lathe(ck.round_profile(0, 0.24, -0.08, 0.08, 0.04, 2), 32, glass_m, "Glass"), -depth / 2 - 0.02)
    glass.location.x, glass.location.z = -0.38, 0.82
    frame = facing(ck.torus(0.26, 0.075, 32, 10, mat=frame_m, name="Frame"), -depth / 2 - 0.06)
    frame.location.x, frame.location.z = -0.38, 0.82
    parts += [glass, frame]
    # Gloss streak up the camera-facing (right) roof slope toward the ridge, near the front edge.
    n = (0.8 / run, 0.9 / run)
    d = (-0.9 / run, 0.8 / run)
    base = (0.45 + n[0] * (thick + 0.01), 1.55 + n[1] * (thick + 0.01))
    parts.append(ck.gloss_streak([(base[0] + d[0] * s, -0.64, base[1] + d[1] * s) for s in (-0.35, -0.08, 0.2, 0.45)],
                                 0.16, (n[0], 0, n[1])))
    ck.group(parts, "HomeIcon", rotation=(0, 0, -8))
    return parts


@register("Index")
def index():
    """Chunky closed book seen from the front: teal covers and a rounded spine, cream page block
    showing on the open side, a big sunny star on the cover."""
    cover_m = vgrad("Cover", ck.mix("Mat", "MatAlt", 0.5), "Emerald", 0.0, 2.2)
    spine_m = ck.toy_material("Spine", ck.mix("Emerald", "Mat", 0.3))
    page_m = ck.toy_material("Pages", "Cream")
    star_m = vgrad("Star", ck.mix("Sunny", "White", 0.25), "Orange", 0.6, 1.6)
    band_m = ck.toy_material("Band", "Sunny")
    parts = [
        ck.rounded_box((1.62, 0.52, 1.98), 0.08, 3, page_m, "Pages", (0.08, 0, 0.11)),
        ck.rounded_box((1.82, 0.2, 2.2), 0.09, 3, cover_m, "FrontCover", (0.02, -0.33, 0)),
        ck.rounded_box((1.82, 0.2, 2.2), 0.09, 3, cover_m, "BackCover", (0.02, 0.33, 0)),
        ck.capsule(0.42, 2.2, 24, 4, spine_m, "Spine", (-0.82, 0, 1.1), axis="Z"),
        # A sunny band down the spine side of the cover.
        ck.rounded_box((0.16, 0.08, 2.16), 0.035, 2, band_m, "Band", (-0.42, -0.45, 0.02)),
    ]
    parts[3].scale = (0.9, 0.95, 1.0)
    star = glyph(ck.star_points(5, 0.62, 0.32, round_steps=3), 0.2, star_m, "Star", bevel=0.07, y=-0.47)
    star.location = (0.18, 0, 1.08)
    parts.append(bake(star))
    parts.append(front_streak([(-0.15, 1.9), (0.25, 1.95), (0.65, 1.9)], 0.1, -0.43))
    ck.group(parts, "BookIcon", rotation=(0, 0, -10))
    return parts


@register("Invite")
def invite():
    """Add a friend: a big round-headed friend (head and shoulders, saturated blue shirt, simple
    happy face) with a round lime badge holding a white plus, set off at the top right."""
    shirt_m = vgrad("Shirt", ck.mix("Blue", "CyanPop", 0.25), ck.mix("BlueDeep", "Blue", 0.2), 0.0, 1.1)
    skin_m = vgrad("Skin", ck.mix(SKIN, "White", 0.12), ck.mix(SKIN, "Coral", 0.25), 0.9, 2.4)
    hair_m = vgrad("Hair", ck.mix(HAIR, "Sunny", 0.25), HAIR, 1.7, 2.45)
    face_m = ck.toy_material("Face", ck.mix("Ink", "Grape", 0.15))
    mouth_m = ck.toy_material("Mouth", ck.mix("Coral", "Ink", 0.3))
    cheek_m = ck.toy_material("Cheek", ck.mix("Coral", "Pink", 0.55), roughness=0.5, coat=0.2)
    badge_m = vgrad("Badge", ck.mix("Lime", "Mint", 0.3), "Emerald", 1.45, 2.65)
    plus_m = ck.toy_material("PlusWhite", "White")
    body = ck.lathe([(0, 0), (0.92, 0), (1.0, 0.12), (1.0, 0.42), (0.87, 0.78), (0.56, 1.0), (0.28, 1.06), (0, 1.07)],
                    48, shirt_m, "Body")
    body.scale = (1.0, 0.72, 1.0)
    hr, hz = 0.78, 1.68  # head radius and centre height
    head = ck.sphere(hr, 48, 24, skin_m, "Head", (0, 0, hz))
    hair = ck.sphere(hr + 0.05, 48, 24, hair_m, "Hair", (0, 0.1, hz + 0.16))
    hair.scale = (0.96, 0.98, 0.82)
    fringe = ck.sphere(0.34, 32, 16, hair_m, "Fringe", (-0.24, -0.36, hz + 0.6))
    fringe.scale = (1.6, 0.8, 0.62)
    fringe.rotation_euler = (0, math.radians(-14), 0)
    parts = [body, head, hair, fringe]

    def on_head(x, z, lift=0.0):
        """Point on the front of the head sphere at (x, z)."""
        return (x, -math.sqrt(max(0.0, hr * hr - x * x - (z - hz) ** 2)) - lift, z)

    for x in (-0.27, 0.27):
        eye = ck.sphere(0.1, 20, 10, face_m, "Eye", on_head(x, hz + 0.1, -0.03))
        eye.scale = (1.0, 0.55, 1.35)
        glint = ck.sphere(0.035, 12, 6, plus_m, "Glint", on_head(x - 0.03, hz + 0.16, 0.02))
        cheek = ck.sphere(0.13, 20, 10, cheek_m, "Cheek", on_head(x * 1.75, hz - 0.12, -0.02))
        cheek.scale = (1.3, 0.35, 0.8)
        parts += [eye, glint, cheek]
    # Big open smile: a D of dark coral, each vertex pushed onto the front of the head.
    smile = [(0.32 * math.cos(math.radians(a)), 0.24 * math.sin(math.radians(a))) for a in range(180, 361, 12)]
    mouth = glyph(rounded_poly(smile, 0.07, 0.05, 3), 0.12, mouth_m, "Smile", bevel=0.035, segments=2)
    for v in mouth.data.vertices:
        x, z = v.co.x, v.co.z + hz - 0.2
        v.co.z = z
        v.co.y += -math.sqrt(max(0.0, hr * hr - x * x - (z - hz) ** 2)) + 0.03
    parts.append(mouth)
    # Head gloss: a crisp streak on the upper-left of the head, below the hair line.
    pts = [on_head(x, z, 0.015) for x, z in ((-0.6, hz - 0.08), (-0.64, hz + 0.08), (-0.6, hz + 0.24))]
    parts.append(ck.gloss_streak(pts, 0.11, (-0.75, -0.6, 0.15)))
    # Badge: a round lime disc with a fat white plus, separated from the head at the top right.
    bx, bz, br = 1.66, 2.6, 0.46
    disc = facing(ck.lathe(ck.round_profile(0, br, -0.16, 0.16, 0.12, 3), 40, badge_m, "Badge"), -0.1)
    disc.location.x, disc.location.z = bx, bz
    parts.append(bake(disc))
    a, L = 0.11, 0.31
    plus = glyph(rounded_poly([(a, -L), (a, -a), (L, -a), (L, a), (a, a), (a, L), (-a, L), (-a, a), (-L, a), (-L, -a),
                               (-a, -a), (-a, -L)], 0.09, 0.04), 0.14, plus_m, "Plus", bevel=0.05, y=-0.27)
    plus.location = (bx, 0, bz)
    parts.append(bake(plus))
    parts.append(front_streak([(bx - 0.36, bz + 0.04), (bx - 0.3, bz + 0.2), (bx - 0.18, bz + 0.32)], 0.08,
                              -0.25))
    # Shoulder gloss on the front-left of the body, following the (squashed) lathe profile.
    prof = [(0.0, 1.0), (0.12, 1.0), (0.42, 1.0), (0.78, 0.87), (1.0, 0.56), (1.06, 0.28)]

    def body_point(z, ang):
        for (z0, r0), (z1, r1) in zip(prof, prof[1:]):
            if z0 <= z <= z1:
                r = r0 + (r1 - r0) * (z - z0) / (z1 - z0) + 0.03
                return (r * math.cos(math.radians(ang)), 0.72 * r * math.sin(math.radians(ang)), z)
        return (0, 0, z)

    pts = [body_point(z, a) for z, a in ((0.4, 220), (0.6, 214), (0.8, 208))]
    parts.append(ck.gloss_streak(pts, 0.13, (-0.6, -0.6, 0.5)))
    ck.group(parts, "InviteIcon", rotation=(0, 0, -6))
    return parts


@register("Settings")
def settings():
    """Chunky six-tooth gear in saturated candy teal with a fat orange hub ring round a recessed
    centre, and a crisp gloss streak on the upper-left of the face."""
    gear_m = vgrad("Gear", ck.mix("MatAlt", "CyanPop", 0.35), ck.mix("Mat", "Emerald", 0.55), -1.0, 1.0)
    hole_m = ck.toy_material("Hole", ck.mix("Emerald", "Ink", 0.45))
    ring_m = vgrad("Ring", ck.mix("Orange", "Sunny", 0.35), ck.mix("Orange", "Coral", 0.35), -0.45, 0.45)
    pts = []
    teeth, rr, rt = 6, 0.72, 1.04
    for k in range(teeth):
        base = 2 * math.pi * k / teeth + math.pi / 2
        for a, r in ((-0.36, rr), (-0.24, rt), (0.24, rt), (0.36, rr)):
            pts.append((r * math.cos(base + a), r * math.sin(base + a)))
        mid = base + math.pi / teeth
        pts.append((rr * math.cos(mid), rr * math.sin(mid)))
    depth = 0.56
    gear = glyph(rounded_poly(pts, 0.12, 0.12, 4), depth, gear_m, "Gear", bevel=0.15, segments=5)
    ring = facing(ck.torus(0.33, 0.15, 40, 14, mat=ring_m, name="Ring"), -depth / 2 - 0.02)
    hole = facing(ck.lathe(ck.round_profile(0, 0.24, -0.06, 0.06, 0.03, 2), 32, hole_m, "Hub"), -depth / 2 + 0.02)
    arc = [(0.58 * math.cos(math.radians(a)), 0.58 * math.sin(math.radians(a))) for a in (102, 122, 142, 162)]
    streak = front_streak(arc, 0.12, -depth / 2)
    ring_gloss = front_streak([(0.33 * math.cos(math.radians(a)), 0.33 * math.sin(math.radians(a)))
                               for a in (120, 140, 160)], 0.07, -depth / 2 - 0.18, lift=0.0)
    parts = [gear, ring, hole, streak, ring_gloss]
    ck.group(parts, "GearIcon", rotation=(0, 0, 10))
    return parts


if __name__ == "__main__":
    render(argv_names() or NAMES)
