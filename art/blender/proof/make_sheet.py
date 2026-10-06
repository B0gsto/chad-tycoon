"""Builds the proof contact sheets (run with the system python3, which has Pillow):

    python3 art/blender/proof/make_sheet.py

art/out/proof/sheet.png        icons at 256 px, the same icons at 64 px and 48 px, prop beauty shots
                               (each with an in-game lighting inset)
art/out/proof/sheet_small.png  the same sheet scaled to at most 1024 px on the long side
"""

import json
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "lib"))
import chadkit as ck  # noqa: E402

OUT = os.path.join(ck.ROOT, "art", "out", "proof")
BG = (52, 70, 138)  # Theme.World.Board: a mid-blue, UI-like backdrop

ICONS = [("coin", "Cash"), ("gem", "Rizz gem"), ("orb", "Aura orb"), ("gift", "Gift"), ("trophy", "Trophy"),
         ("cart", "Shop")]
PROPS = [("dumbbell", "Dumbbell"), ("kettlebell", "Kettlebell"), ("palm", "PalmTree")]

icon_paths = [os.path.join(OUT, "icons", n + ".png") for n, _ in ICONS]
big = ck.contact_sheet(icon_paths, cols=3, labels=[l for _, l in ICONS], cell=256, bg=BG, title="Icons @256")
small = ck.contact_sheet(icon_paths, cols=6, cell=64, bg=BG, title="Icons @64", gap=20)
tiny = ck.contact_sheet(icon_paths, cols=6, cell=48, bg=BG, title="Icons @48", gap=36)
left = ck.stack_images([big, small, tiny], bg=BG)

prop_labels = []
for n, mesh in PROPS:
    stats_path = os.path.join(OUT, "meshes", mesh + ".json")
    tris = json.load(open(stats_path))["triangles"] if os.path.exists(stats_path) else "?"
    prop_labels.append("%s  (%s tris)" % (mesh, tris))
# Each beauty shot carries an inset of the same mesh under Roblox-like lighting (flat vertex colours,
# SmoothPlastic, one sun) to check the asset still reads in the engine.
shots = []
for n, _ in PROPS:
    beauty = os.path.join(OUT, "props", n + ".png")
    game = os.path.join(OUT, "props", n + "_game.png")
    shots.append(ck.inset_image(beauty, game, label="in-game") if os.path.exists(game) else beauty)
props = ck.contact_sheet(shots, cols=1,
                         labels=prop_labels, cell=300, bg=BG, title="Props (game meshes)")
sheet = ck.stack_images([left, props], os.path.join(OUT, "sheet.png"), bg=BG, gap=8, direction="horizontal")
ck.stack_images([sheet], os.path.join(OUT, "sheet_small.png"), bg=BG, max_side=1024)
print("sheet", sheet.size)
