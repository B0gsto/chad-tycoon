"""VFX particle sprites for Chad Aura Tycoon, rendered at 512 px into art/out/vfx/raw/<Name>.png
(art/blender/vfx/finish.py scales them to the shipped 256 px art/out/vfx/<Name>.png).

Run:  tools/blender-run.sh art/blender/vfx/sprites.py [-- Name Name ...]

White sprites (Sparkle, SoftDot, Ring, Puff, Confetti, Note) use a self-lit white finish with a
light lilac-grey shadow side, so the game can tint them with ParticleEmitter.Color. Full-colour
sprites (Heart, StarPop, CoinSpin, Sweat) use the shared chadkit toy plastic and light rig.
No sticker outline, no drop shadow.
"""

import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import spritekit as sk  # noqa: E402
from spritekit import ck  # noqa: E402

import bpy  # noqa: E402
from mathutils import Matrix, Vector  # noqa: E402

SIZE = 512


def out(name):
    return os.path.join(sk.RAW_VFX, name + ".png")


def shot(objs, name, az=0.0, el=0.0, pad=0.05):
    ck.render_icon(objs, out(name), size=SIZE, azimuth=az, elevation=el, pad=pad, outline=0, shadow=False,
                   fill=0, samples=96)


def arc_pts(cx, cz, r, a0, a1, n=5):
    return [(cx + r * math.cos(math.radians(a0 + (a1 - a0) * k / (n - 1))),
             cz + r * math.sin(math.radians(a0 + (a1 - a0) * k / (n - 1)))) for k in range(n)]


# ------------------------------------------------------------------------------------------------


def heart():
    mat = ck.gradient_material("Heart", [(0.0, ck.mix("HotPink", "Coral", 0.25)), (0.5, "HotPink"),
                                         (1.0, ck.mix("HotPink", "Pink", 0.6))], mode="Z", lo=-0.9, hi=0.9)
    ob = sk.puffy_shape(sk.heart_outline(size=2.0), depth=0.36, height=0.3, reach=0.55, mat=mat, name="Heart",
                        voxel=0.016, iters=30)
    sk.to_front(ob, Matrix.Rotation(math.radians(8), 4, "Y"))
    streak = sk.surface_streak(ob, arc_pts(-0.48, 0.4, 0.3, 165, 100, 6), 0.15)
    shot([ob, streak], "Heart", az=12, el=8)


def star_pop():
    mat = ck.gradient_material("Star", [(0.0, ck.mix("Sunny", "Orange", 0.6)), (0.5, "Sunny"),
                                        (1.0, ck.mix("Sunny", "White", 0.35))], mode="Z", lo=-0.85, hi=1.0)
    ob = sk.puffy_shape(ck.star_points(5, 1.0, 0.56), depth=0.34, height=0.26, reach=0.4, mat=mat, name="Star",
                        voxel=0.014, iters=26)
    sk.to_front(ob, Matrix.Rotation(math.radians(9), 4, "Y"))
    streak = sk.surface_streak(ob, [(-0.05, 0.66), (-0.17, 0.48), (-0.33, 0.36), (-0.55, 0.27)], 0.13)
    shot([ob, streak], "StarPop", az=10, el=6)


def sparkle():
    """Fat 4-point star with concave curved sides on a soft round glow."""
    mat = sk.white_material("SparkleWhite")
    ob = sk.puffy_shape(sk.star4_outline(r=1.0, rx=0.86, waist=0.48), depth=0.32, height=0.2, reach=0.34, mat=mat,
                        name="Sparkle", voxel=0.012, iters=14, factor=0.5)
    sk.to_front(ob)
    halo = sk.glow_disc(sk.glow_material("SparkleHalo", "halo", edge=ck.lin(sk.WHITE_SHADE), peak=0.6),
                        (0, 0.4, 0), 1.08, name="SparkleHalo")
    shot([ob, halo], "Sparkle", pad=0.0)


def soft_dot():
    disc = sk.glow_disc(sk.glow_material("SoftDot", "dot", edge=ck.lin(sk.WHITE_SHADE)), name="SoftDot")
    shot(disc, "SoftDot", pad=0.0)


def ring():
    rim = ck.lin((150, 192, 250))  # faint blue rim: keeps the white ring readable on sand
    disc = sk.glow_disc(sk.glow_material("Ring", "ring", edge=ck.lin(sk.WHITE_SHADE), rim=rim), name="Ring")
    shot(disc, "Ring", pad=0.0)


PUFF_SHADE = (184, 200, 230)  # subtle blue-grey underside


def puff():
    """Soft cartoon dust cloud: four round metaball lobes fused smoothly (finish.py feathers the edge)."""
    el = 4.0
    lobes = [((0.05, 0, 0.3), 1.25), ((-0.95, 0, -0.18), 0.98), ((0.98, 0, -0.12), 1.02), ((0.05, -0.25, -0.22), 0.88)]
    ob = sk.metaball_mesh([(c, r, (1, 1, 1)) for c, r in lobes], "Puff",
                          sk.white_material("PuffWhite", el=el, shade=PUFF_SHADE, spec_power=24.0),
                          resolution=0.025, threshold=0.6)
    ob.data.transform(Matrix.Diagonal((1.0, 0.72, 1.0, 1.0)))
    ob.data.update()
    shot(ob, "Puff", el=el)


def coin_spin():
    gold = ck.toy_material("Gold", "Sunny")
    deep = ck.toy_material("GoldDeep", "GoldDeep")

    def arc(cx, cz, r, a0, a1, steps=6):
        return [(cx + r * math.cos(math.radians(a0 + (a1 - a0) * k / steps)),
                 cz + r * math.sin(math.radians(a0 + (a1 - a0) * k / steps))) for k in range(steps + 1)]

    # Raised rolled rim around a gently domed face, embossed "$" (as the Cash icon).
    profile = [(0, -0.17), (0.4, -0.155), (0.68, -0.12), (0.76, -0.15)]
    profile += arc(0.86, -0.06, 0.13, -110, 0)
    profile += arc(0.86, 0.06, 0.13, 0, 110)
    profile += [(0.76, 0.15), (0.68, 0.12), (0.4, 0.155), (0, 0.17)]
    coin = ck.lathe(profile, segments=72, mat=gold, name="Coin", smooth_angle=50)
    sign = ck.text_mesh("$", size=1.1, depth=0.12, bevel=0.035, mat=deep, name="Dollar", font=ck.FONT_BLACK)
    sign.location = (0, 0, 0.16)
    streak = ck.gloss_streak([(0.56 * math.cos(math.radians(a)), 0.56 * math.sin(math.radians(a)), 0.15)
                              for a in (104, 118, 132, 146, 160)], 0.11, (0, 0, 1))
    # Face the camera, turned a touch about the vertical so the thick edge shows (mid-spin).
    ck.group([coin, sign, streak], "CoinSpin", rotation=(90, 0, 14))
    shot([coin, sign, streak], "CoinSpin")


def confetti():
    """One chunky confetti piece: a thick rounded card with soft bevels, twisted and curled a little."""
    az, el = 0.0, 10.0
    mat = sk.white_material("ConfettiWhite", az=az, el=el, shade=(184, 190, 216))
    w, h = 1.3, 0.8
    ob = ck.extrude_shape(sk.rounded_rect(w, h, 0.2, 8), depth=0.2, mat=mat, name="Confetti", bevel=0)
    sk.remesh(ob, 0.012, 14, 0.5)
    me = ob.data
    for v in me.vertices:
        u = v.co.x / (w / 2)
        th = math.radians(26) * u  # twist about the long axis
        y, z = v.co.y, v.co.z
        v.co.y = y * math.cos(th) - z * math.sin(th)
        v.co.z = y * math.sin(th) + z * math.cos(th) - 0.2 * u * u  # curl: ends bend back
    me.update()
    sk.to_front(ob, Matrix.Rotation(math.radians(-24), 4, "Y") @ Matrix.Rotation(math.radians(-14), 4, "Z"))
    ck.shade_smooth(ob, None)
    shot(ob, "Confetti", az=az, el=el)


def note():
    """Chunky eighth note: fat tilted oval head, thick rounded stem and a bold curved flag, inflated
    into one soft piece."""
    az, el = 6.0, 4.0
    mat = sk.white_material("NoteWhite", az=az, el=el)
    cx, cy, rx, ry, tilt = -0.3, -0.8, 0.52, 0.38, math.radians(24)
    head = [(cx + rx * math.cos(t) * math.cos(tilt) - ry * math.sin(t) * math.sin(tilt),
             cy + rx * math.cos(t) * math.sin(tilt) + ry * math.sin(t) * math.cos(tilt))
            for t in (2 * math.pi * k / 72 for k in range(72))]
    stem = [(x + 0.17, y + 0.12) for x, y in sk.rounded_rect(0.32, 1.9, 0.15, 8)]
    flag_c = [(0.22, 0.95), (0.48, 0.8), (0.7, 0.58), (0.81, 0.32), (0.78, 0.07), (0.66, -0.12)]
    flag = sk.offset_path(flag_c, [0.4, 0.37, 0.33, 0.29, 0.25, 0.23])[::-1]
    ob = sk.puffy_union([head, stem, flag], depth=0.32, height=0.2, reach=0.3, mat=mat, name="Note",
                        voxel=0.012, iters=16, factor=0.5)
    sk.to_front(ob, Matrix.Rotation(math.radians(8), 4, "Y"))
    shot(ob, "Note", az=az, el=el)


def sweat():
    mat = ck.gradient_material("Drop", [(0.0, ck.mix("Pool", "White", 0.45)), (0.45, "Pool"),
                                        (0.8, ck.mix("Pool", "Blue", 0.6)), (1.0, "Blue")], mode="FACING",
                               roughness=0.15, coat=0.9)
    prof = [(math.cos(math.radians(a)), math.sin(math.radians(a))) for a in range(-90, 36, 5)]
    p0 = Vector(prof[-1])
    t = Vector((-math.sin(math.radians(35)), math.cos(math.radians(35))))
    for s in (0.3, 0.6, 0.9, 1.1):
        q = p0 + t * s
        prof.append((q.x, q.y))
    tip = prof[-1]
    for k in range(1, 5):
        a = math.radians(90 * k / 4)
        prof.append((tip[0] * math.cos(a), tip[1] + 0.12 * math.sin(a)))
    prof[-1] = (0.0, prof[-1][1])
    ob = ck.lathe(prof, segments=64, mat=mat, name="Drop", smooth_angle=80)
    ob.rotation_euler = (0, math.radians(-16), 0)
    sk.bake(ob)
    ck.shade_smooth(ob, None)
    streak = sk.surface_streak(ob, arc_pts(0.0, 0.0, 0.62, 165, 105, 6), 0.17)
    dot = sk.surface_streak(ob, [(0.42, -0.5), (0.5, -0.38)], 0.1)
    shot([ob, streak, dot], "Sweat", az=10, el=5)


SPRITES = {
    "Heart": heart, "StarPop": star_pop, "Sparkle": sparkle, "SoftDot": soft_dot, "Ring": ring, "Puff": puff,
    "CoinSpin": coin_spin, "Confetti": confetti, "Note": note, "Sweat": sweat,
}

if __name__ == "__main__":
    names = sk.script_args() or list(SPRITES)
    for nm in names:
        ck.reset_scene()
        SPRITES[nm]()
        print("SPRITE_DONE", nm, out(nm))
