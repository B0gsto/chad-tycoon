"""Builds the props-hero contact sheet (system python3 with Pillow):

    python3 art/blender/props/hero_sheet.py

art/out/props/sheet_props-hero.png        every hero prop's beauty shot with its in-game inset,
                                          labelled with the triangle count and size in studs
art/out/props/sheet_props-hero_small.png  the same, at most 1024 px on the long side
"""

import json
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "lib"))
import chadkit as ck  # noqa: E402

OUT = os.path.join(ck.ROOT, "art", "out", "props")
BG = (52, 70, 138)  # Theme.World.Board
KINDS = ["GigaStatue", "TrophyPodium", "Converter", "Vault", "CrateCracker", "Crate"]

shots, labels = [], []
for kind in KINDS:
    beauty = os.path.join(OUT, kind + ".png")
    game = os.path.join(OUT, kind + "_game.png")
    if not os.path.exists(beauty):
        continue
    stats = json.load(open(os.path.join(OUT, kind + ".json")))
    shots.append(ck.inset_image(beauty, game, label="in-game") if os.path.exists(game) else beauty)
    labels.append("%s  %d tris  %s" % (kind, stats["tris"], " x ".join("%g" % v for v in stats["size"])))
sheet = ck.contact_sheet(shots, os.path.join(OUT, "sheet_props-hero.png"), cols=3, labels=labels, cell=420, bg=BG,
                         title="props-hero: hero meshes (size = Roblox X x Y x Z studs)")
ck.stack_images([sheet], os.path.join(OUT, "sheet_props-hero_small.png"), bg=BG, max_side=1024)
print("sheet", sheet.size)
