"""Builds the HUD icon contact sheets (system python3 with Pillow):

    python3 art/blender/icons/make_sheet.py

art/out/icons/sheet_hud.png        every icon at 256 px with its name, then a row of all icons at 48 px,
                                   on royal blue rgb(58, 84, 170)
art/out/icons/sheet_hud_small.png  at most 1024 px on the long side: every icon at about 160 px with its
                                   name (more rows instead of smaller icons), plus the 48 px row
"""

import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "lib"))
import chadkit as ck  # noqa: E402

OUT = os.path.join(ck.ROOT, "art", "out", "icons")
BG = (58, 84, 170)
NAMES = ["Orb", "Coin", "Gem", "Shop", "Modes", "Index", "Ranking", "Home", "Free", "Invite", "Settings", "Surge", "Chad",
         "Plus", "Close", "Check", "Star", "Music", "Sound", "Hash", "Merge", "Lock"]

paths = [os.path.join(OUT, n + ".png") for n in NAMES]
missing = [p for p in paths if not os.path.exists(p)]
if missing:
    raise SystemExit("missing icons: " + ", ".join(missing))

big = ck.contact_sheet(paths, cols=7, labels=NAMES, cell=256, bg=BG, title="HUD icons @256")
tiny = ck.contact_sheet(paths, cols=len(paths), cell=48, bg=BG, title="@48", gap=24)
sheet = ck.stack_images([big, tiny], os.path.join(OUT, "sheet_hud.png"), bg=BG, gap=8)

# Small sheet: 6 columns of 150 px cells fit in 1024 px; the 48 px row wraps to two lines.
small_big = ck.contact_sheet(paths, cols=6, labels=NAMES, cell=150, bg=BG, title="HUD icons @150", gap=14)
small_tiny = ck.contact_sheet(paths, cols=11, cell=48, bg=BG, title="@48", gap=36)
small = ck.stack_images([small_big, small_tiny], bg=BG, gap=4)
ck.stack_images([small], os.path.join(OUT, "sheet_hud_small.png"), bg=BG, max_side=1024)
print("sheet_hud", sheet.size, "sheet_hud_small", small.size)
