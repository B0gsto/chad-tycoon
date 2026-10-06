"""Contact sheet of the gym props (props-gym), run with the system python3 (Pillow):

    python3 art/blender/props/make_sheet_gym.py

art/out/props/sheet_props-gym.png        every prop's beauty shot with its in-game inset, labelled with tris
art/out/props/sheet_props-gym_small.png  the same, at most 1024 px on the long side
"""

import json
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "lib"))
import chadkit as ck  # noqa: E402

OUT = os.path.join(ck.ROOT, "art", "out", "props")
BG = (52, 70, 138)
KINDS = ["Dumbbell", "DumbbellRack", "Barbell", "Bench", "Kettlebell", "Treadmill", "PunchBag", "YogaBall"]

shots, labels = [], []
for k in KINDS:
    st = json.load(open(os.path.join(OUT, k + ".json")))
    shots.append(ck.inset_image(os.path.join(OUT, k + ".png"), os.path.join(OUT, k + "_game.png"), label="in-game"))
    labels.append("%s  (%d tris)" % (k, st["tris"]))
sheet = ck.contact_sheet(shots, os.path.join(OUT, "sheet_props-gym.png"), cols=4, labels=labels, cell=400, bg=BG,
                         title="Gym props (props-gym): beauty shot + in-game inset")
ck.stack_images([sheet], os.path.join(OUT, "sheet_props-gym_small.png"), bg=BG, max_side=1024)
print("sheet", sheet.size)
