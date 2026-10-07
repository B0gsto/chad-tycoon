"""Contact sheet of the CARDIO art (run after build.py, with the system python3 + Pillow):

    python3 art/blender/cardio/make_sheet.py

art/out/cardio/sheet.png   group shot (keys tinted per stage) on top, then each mesh's beauty shot with its in-game
                           inset, and the Cardio icon
"""

import json
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "lib"))
import chadkit as ck  # noqa: E402

PROPS = os.path.join(ck.ROOT, "art", "out", "props")
OUT = os.path.join(ck.ROOT, "art", "out", "cardio")
BG = (52, 70, 138)

shots, labels = [], []
for k in ("Keycap", "KeycapWide", "CardioTreadmill"):
    st = json.load(open(os.path.join(PROPS, k + ".json")))
    shots.append(ck.inset_image(os.path.join(PROPS, k + ".png"), os.path.join(PROPS, k + "_game.png"), label="in-game"))
    x, y, z = st["size"]
    labels.append("%s  %gx%gx%g  (%d tris)" % (k, x, y, z, st["tris"]))
shots.append(os.path.join(OUT, "Cardio.png"))
labels.append("Cardio icon (512 px)")
row = ck.contact_sheet(shots, None, cols=4, labels=labels, cell=400, bg=BG)
group = ck.contact_sheet([os.path.join(OUT, "group.png")], None, cols=1, cell=(row.size[0] - 32, 760), bg=BG,
                         labels=["Keycaps tinted by MeshPart.Color (stage colours) + CardioTreadmill"],
                         title="CARDIO art")
sheet = ck.stack_images([group, row], os.path.join(OUT, "sheet.png"), bg=BG)
print("sheet", sheet.size)
