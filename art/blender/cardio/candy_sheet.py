"""Contact sheet of the CARDIO candy props (run after candy.py, with the system python3 + Pillow):

    python3 art/blender/cardio/candy_sheet.py

art/out/cardio/candy_sheet.png        every candy prop's 3/4 beauty shot in a grid, labelled with size and tris
art/out/cardio/candy_sheet_small.png  the same, 768 px on the long side (sips -Z 768)
"""

import json
import os
import subprocess
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "lib"))
import chadkit as ck  # noqa: E402

PROPS = os.path.join(ck.ROOT, "art", "out", "props")
OUT = os.path.join(ck.ROOT, "art", "out", "cardio")
info = json.load(open(os.path.join(OUT, "candy_info.json")))
shots, labels = [], []
for key, st in info.items():
    if not key.startswith("props/"):
        continue
    kind = key.split("/", 1)[1]
    shots.append(os.path.join(PROPS, kind + ".png"))
    x, y, z = st["size"]
    labels.append("%s  %gx%gx%g  %d tris" % (kind[5:], x, y, z, st["tris"]))
path = os.path.join(OUT, "candy_sheet.png")
img = ck.contact_sheet(shots, path, cols=5, labels=labels, cell=360, bg=(255, 214, 232), label_rgb=(90, 40, 60),
                       title="CARDIO candy props")
subprocess.run(["sips", "-Z", "768", path, "--out", os.path.join(OUT, "candy_sheet_small.png")], check=True,
               stdout=subprocess.DEVNULL)
print("sheet", img.size, len(shots))
