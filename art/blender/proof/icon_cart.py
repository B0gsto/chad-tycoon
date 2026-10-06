"""Proof icon: chunky shopping cart (Shop). A big blue basket with a fat white rim, one bold pink
parcel, a short fat coral handle and two big wheels in deep violet with sunny hubs."""

import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _common import ck, icon  # noqa: E402

ck.reset_scene()
blue = ck.toy_material("Basket", "Blue")
white = ck.toy_material("Rim", "White")
coral = ck.toy_material("Handle", "Coral")
tyre_m = ck.toy_material("Tyre", ck.DARK)
hub_m = ck.toy_material("Hub", "Sunny")
parcel_m = ck.toy_material("Parcel", "HotPink")
ribbon_m = ck.toy_material("Ribbon", "Sunny")

parts = [
    ck.rounded_box((2.3, 1.5, 1.4), 0.28, 4, blue, "Basket", (0, 0, 0.62), taper=1.12),
    ck.rounded_box((2.7, 1.86, 0.3), 0.13, 3, white, "Rim", (0, 0, 1.94)),
    # One bold item: a big parcel with a sunny ribbon, poking well out of the basket.
    ck.rounded_box((1.12, 0.92, 1.0), 0.2, 3, parcel_m, "Parcel", (0.18, 0.0, 1.62)),
    ck.rounded_box((0.3, 0.98, 1.04), 0.1, 2, ribbon_m, "RibbonA", (0.18, 0.0, 1.61)),
    ck.rounded_box((1.18, 0.3, 1.04), 0.1, 2, ribbon_m, "RibbonB", (0.18, 0.0, 1.61)),
    # Handle: a short fat post from the back rim up to a chunky grip.
    ck.sweep([(-1.22, 0, 1.98), (-1.42, 0, 2.22), (-1.54, 0, 2.36)], [0.2, 0.2, 0.2], 14, coral, "Post",
             up=(0, 1, 0)),
    ck.capsule(0.27, 1.9, 20, 4, coral, "Grip", (-1.56, 0, 2.38), axis="Y"),
]
# Two big wheels on the front side (the back pair would only add clutter at small sizes).
for x in (-0.72, 0.78):
    tyre = ck.lathe(ck.round_profile(0, 0.48, -0.22, 0.22, 0.14, 3), 32, tyre_m, "Tyre")
    tyre.rotation_euler = (math.radians(90), 0, 0)
    tyre.location = (x, -0.7, 0.48)
    hub = ck.lathe(ck.round_profile(0, 0.22, -0.25, 0.25, 0.09, 2), 20, hub_m, "Hub")
    hub.rotation_euler = (math.radians(90), 0, 0)
    hub.location = (x, -0.7, 0.48)
    parts += [tyre, hub]
ck.group(parts, "CartIcon", rotation=(0, 0, -18))
icon(parts, "cart")
