"""Builds the redo-props contact sheet (system python3 with Pillow, not Blender):

    python3 art/blender/props/make_sheet_redo.py

art/out/props/sheet_redo-props.png        each prop's beauty shot with its in-game inset, labelled
                                          with triangle count and size in studs
art/out/props/sheet_redo-props_small.png  the same sheet at most 1024 px on the long side
"""

import json
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "lib"))
import chadkit as ck  # noqa: E402

OUT = os.path.join(ck.ROOT, "art", "out", "props")
BG = (24, 118, 128)  # Theme.World.TealDeep
KINDS = ["PalmTree", "PalmPlanter", "Vault", "CrateCracker", "CrateCrackerVip", "Crown", "Crate"]

shots, labels = [], []
for kind in KINDS:
    beauty = os.path.join(OUT, kind + ".png")
    game = os.path.join(OUT, kind + "_game.png")
    if not os.path.exists(beauty):
        continue
    stats = json.load(open(os.path.join(OUT, kind + ".json")))
    size = "x".join("%g" % round(v, 1) for v in stats["size"])
    shots.append(ck.inset_image(beauty, game, label="in-game") if os.path.exists(game) else beauty)
    labels.append("%s  %d tris  %s" % (kind, stats["tris"], size))
sheet = ck.contact_sheet(shots, os.path.join(OUT, "sheet_redo-props.png"), cols=4, labels=labels, cell=400, bg=BG,
                         title="redo-props (game meshes; inset = in-game look)")
ck.stack_images([sheet], os.path.join(OUT, "sheet_redo-props_small.png"), bg=BG, max_side=1024)
print("sheet", sheet.size)
