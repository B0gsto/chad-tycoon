"""Proof icon: chunky gold coin with an embossed "$" and a bright gloss streak (Cash)."""

import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _common import ck, icon  # noqa: E402

ck.reset_scene()
gold = ck.toy_material("Gold", "Sunny")
deep = ck.toy_material("GoldDeep", "GoldDeep")


def arc(cx, cz, r, a0, a1, steps=4):
    return [(cx + r * math.cos(math.radians(a0 + (a1 - a0) * k / steps)),
             cz + r * math.sin(math.radians(a0 + (a1 - a0) * k / steps))) for k in range(steps + 1)]


# Raised rolled rim around a gently domed face (the dome catches a light-to-shade gradient).
profile = [(0, -0.17), (0.4, -0.155), (0.68, -0.12), (0.76, -0.15)]
profile += arc(0.86, -0.06, 0.13, -110, 0)
profile += arc(0.86, 0.06, 0.13, 0, 110)
profile += [(0.76, 0.15), (0.68, 0.12), (0.4, 0.155), (0, 0.17)]
coin = ck.lathe(profile, segments=56, mat=gold, name="Coin", smooth_angle=50)
sign = ck.text_mesh("$", size=1.1, depth=0.12, bevel=0.035, mat=deep, name="Dollar", font=ck.FONT_BLACK)
sign.location = (0, 0, 0.16)
# Bright specular streak curving round the upper-left of the face, inside the rolled rim.
streak = ck.gloss_streak([(0.56 * math.cos(math.radians(a)), 0.56 * math.sin(math.radians(a)), 0.15)
                          for a in (104, 118, 132, 146, 160)], 0.11, (0, 0, 1))
# Stand the coin up facing the camera, turned a little so its thick edge shows.
ck.group([coin, sign, streak], "CoinIcon", rotation=(78, 0, 14))
icon([coin, sign, streak], "coin")
