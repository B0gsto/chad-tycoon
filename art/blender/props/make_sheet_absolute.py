"""Builds the AbsoluteChad 4-view contact sheet (system python3 with Pillow, not Blender):

    python3 art/blender/props/make_sheet_absolute.py

art/out/props/sheet_absolute-chad.png        3/4 (with the in-game inset), front, side and back views,
                                             labelled with the triangle count and size in studs
art/out/props/sheet_absolute-chad_small.png  the same sheet at most 1024 px on the long side
"""

import json
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "lib"))
import chadkit as ck  # noqa: E402

OUT = os.path.join(ck.ROOT, "art", "out", "props")
BG = (52, 70, 138)  # Theme.World.Board
KIND = "AbsoluteChad"
VIEWS = [("34", "3/4"), ("front", "front"), ("side", "side"), ("back", "back")]

stats = json.load(open(os.path.join(OUT, KIND + ".json")))
size = " x ".join("%g" % v for v in stats["size"])
game = os.path.join(OUT, KIND + "_game.png")
shots, labels = [], []
for view, label in VIEWS:
    path = os.path.join(OUT, "%s_view_%s.png" % (KIND, view))
    shots.append(ck.inset_image(path, game, label="in-game") if view == "34" and os.path.exists(game) else path)
    labels.append(label)
sheet = ck.contact_sheet(shots, os.path.join(OUT, "sheet_absolute-chad.png"), cols=4, labels=labels, cell=440, bg=BG,
                         title="%s  %d tris  %s studs (Roblox X x Y x Z)" % (KIND, stats["tris"], size))
ck.stack_images([sheet], os.path.join(OUT, "sheet_absolute-chad_small.png"), bg=BG, max_side=1024)
print("sheet", sheet.size)
