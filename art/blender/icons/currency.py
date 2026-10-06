"""Currency icons: Coin (cash), Gem (premium "Rizz"), Orb (aura orb, the core currency).

Built from the approved proofs (art/blender/proof/icon_coin.py, icon_gem.py, icon_orb.py).
Standalone: tools/blender-run.sh art/blender/icons/currency.py [-- Coin Gem Orb]
"""

import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _icons import argv_names, ck, register, render  # noqa: E402
from mathutils import Vector  # noqa: E402

NAMES = ["Coin", "Gem", "Orb"]


def _arc(cx, cz, r, a0, a1, steps=4):
    return [(cx + r * math.cos(math.radians(a0 + (a1 - a0) * k / steps)),
             cz + r * math.sin(math.radians(a0 + (a1 - a0) * k / steps))) for k in range(steps + 1)]


@register("Coin")
def coin():
    """Chunky gold coin with an embossed "$", a rolled rim and a gloss streak, stood up and turned
    a little so its thick edge shows."""
    gold = ck.toy_material("Gold", "Sunny")
    deep = ck.toy_material("GoldDeep", "GoldDeep")
    profile = [(0, -0.17), (0.4, -0.155), (0.68, -0.12), (0.76, -0.15)]
    profile += _arc(0.86, -0.06, 0.13, -110, 0)
    profile += _arc(0.86, 0.06, 0.13, 0, 110)
    profile += [(0.76, 0.15), (0.68, 0.12), (0.4, 0.155), (0, 0.17)]
    body = ck.lathe(profile, segments=56, mat=gold, name="Coin", smooth_angle=50)
    sign = ck.text_mesh("$", size=1.1, depth=0.12, bevel=0.035, mat=deep, name="Dollar", font=ck.FONT_BLACK)
    sign.location = (0, 0, 0.16)
    streak = ck.gloss_streak([(0.56 * math.cos(math.radians(a)), 0.56 * math.sin(math.radians(a)), 0.15)
                              for a in (104, 118, 132, 146, 160)], 0.11, (0, 0, 1))
    parts = [body, sign, streak]
    ck.group(parts, "CoinIcon", rotation=(78, 0, 14))
    return parts


@register("Gem")
def gem():
    """Tall brilliant-cut gem: cyan crown fading to deep blue, pale table, gloss streak on the
    front-left crown facet."""
    top, bottom = 0.62, -1.18
    body = ck.gradient_material("GemBody", [(0.0, ck.mix("BlueDeep", "Blue", 0.45)), (0.42, "Blue"),
                                            (0.72, "CyanPop"), (1.0, ck.mix("CyanPop", "White", 0.35))],
                                lo=bottom, hi=top, roughness=0.18, coat=0.8)
    table = ck.toy_material("GemTable", ck.mix("CyanPop", "White", 0.72), roughness=0.15, coat=0.8, emission=0.25)
    ob = ck.lathe([(0, bottom), (0.13, bottom + 0.06), (0.86, 0.0), (0.86, 0.15), (0.5, top), (0, top)],
                  segments=8, mat=body, name="Gem")
    ob.data.materials.append(table)
    for p in ob.data.polygons:
        p.material_index = 1 if p.center.z > top - 0.01 else 0
    ck.shade_flat(ob)
    ck.soften(ob, width=0.03, segments=2, limit_angle=10.0, weighted=True)
    ck.shade_flat(ob)
    ob.rotation_euler = (0.0, 0.0, 0.3927 / 2)
    fa = math.radians(-101.25)
    fn = Vector((math.cos(fa), math.sin(fa), 0.0))
    normal = Vector((fn.x * 0.62, fn.y * 0.62, 0.36)).normalized()
    inset = math.cos(math.radians(22.5))

    def on_crown(t, lift=0.025):
        r, z = 0.86 + (0.5 - 0.86) * t, top * t
        return fn * (r * inset) + Vector((0, 0, z)) + normal * lift

    streak = ck.gloss_streak([on_crown(t) for t in (0.14, 0.32, 0.5, 0.68, 0.84)], 0.12, normal)
    parts = [ob, streak]
    ck.group(parts, "GemIcon", rotation=(-10, 0, 0))
    return parts


@register("Orb")
def orb():
    """The aura orb: a glossy sphere with a glowing inner core (bright cyan at the centre through
    lilac and violet to a hot magenta-pink rim light at the silhouette), a bold white-gold
    four-point sparkle in the middle and a big cartoon highlight on the upper left."""
    orb_m = ck.gradient_material("Orb", [(0.0, ck.mix("CyanPop", "White", 0.35)), (0.22, "CyanPop"),
                                         (0.45, ck.mix("Grape", "CyanPop", 0.25)), (0.66, "GrapeDeep"),
                                         (0.84, "Magenta"), (1.0, ck.mix("Magenta", "Pink", 0.6))],
                                 mode="FACING", emission=0.32, roughness=0.15, coat=0.9)
    white = ck.toy_material("Gloss", "White", roughness=0.3, coat=0.0, emission=1.2)
    spark = ck.gradient_material("Sparkle", [(0.0, "White"), (0.6, ck.mix("Sunny", "White", 0.55)),
                                             (1.0, ck.mix("Sunny", "White", 0.2))], mode="FACING", emission=0.9)
    ball = ck.sphere(1.0, 48, 24, orb_m, "Orb")
    gloss = ck.capsule(0.15, 0.62, 16, 4, white, "Gloss", axis="Z")
    gloss.location = (-0.5, -0.6, 0.5)
    gloss.rotation_euler = (0.8, -0.6, 0.7)
    gloss.scale = (1.0, 0.4, 1.0)
    dot = ck.sphere(0.085, 16, 8, white, "GlossDot", (-0.2, -0.86, 0.5))
    dot.scale = (1.0, 0.5, 1.0)
    # The sparkle sits on the point of the sphere nearest the camera, so it is the visual centre of
    # the orb, and faces the camera.
    az, el = math.radians(28.0), math.radians(20.0)
    view = Vector((math.sin(az) * math.cos(el), -math.cos(az) * math.cos(el), math.sin(el)))
    star = ck.extrude_shape(ck.star_points(4, 0.52, 0.17, round_steps=2, rotate=90), depth=0.16, mat=spark,
                            name="Sparkle", bevel=0.05)
    star.rotation_euler = view.to_track_quat("Z", "Y").to_euler()
    star.location = view * 0.97
    return [ball, gloss, dot, star]


if __name__ == "__main__":
    render(argv_names() or NAMES)
