"""Contact sheets for the redone icons (system python3 with Pillow):

    python3 art/blender/icons/make_sheet_redo.py

art/out/icons/sheet_redo-icons.png        every redone or new icon at 256 px with its name on the UI blue
                                          rgb(58, 84, 170), then a row of the same icons at 48 px
art/out/icons/sheet_redo-icons_small.png  at most 1024 px on the long side: the icons at 150 px in more rows,
                                          plus the 48 px rows
"""

import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "lib"))
import chadkit as ck  # noqa: E402

OUT = os.path.join(ck.ROOT, "art", "out", "icons")
BG = (58, 84, 170)
NAMES = ["Shop", "Merge", "Surge", "Modes", "Fire", "CashPack3", "CashPack4", "CashPack5", "CashPack6",
         "PassCrateKey", "CosDoubleJump", "CosTrailRookie", "CosAura", "CosCrown", "CosAll", "CosStarter"]
# Neighbours for context in the 48 px row: the approved icons and the packs that stay.
CONTEXT = ["Coin", "Gem", "Index", "Free", "Lock", "CashPack1", "CashPack2", "CosTrailStar", "CosTrailRainbow"]

paths = [os.path.join(OUT, n + ".png") for n in NAMES]
ctx = [os.path.join(OUT, n + ".png") for n in CONTEXT if os.path.exists(os.path.join(OUT, n + ".png"))]
missing = [p for p in paths if not os.path.exists(p)]
if missing:
    raise SystemExit("missing icons: " + ", ".join(missing))

big = ck.contact_sheet(paths, cols=6, labels=NAMES, cell=256, bg=BG, title="Redone icons @256")
tiny = ck.contact_sheet(paths, cols=len(paths), cell=48, bg=BG, title="@48", gap=24)
ladder = ck.contact_sheet([os.path.join(OUT, "CashPack%d.png" % k) for k in range(1, 7)], cols=6, cell=96, bg=BG,
                          labels=["Cash %d" % k for k in range(1, 7)], title="Cash ladder @96", gap=16)
parts = [big, tiny, ladder]
if ctx:
    parts.append(ck.contact_sheet(ctx, cols=len(ctx), cell=48, bg=BG, title="Approved neighbours @48", gap=24))
sheet = ck.stack_images(parts, os.path.join(OUT, "sheet_redo-icons.png"), bg=BG, gap=8)

small_big = ck.contact_sheet(paths, cols=6, labels=NAMES, cell=150, bg=BG, title="Redone icons @150", gap=14)
small_tiny = ck.contact_sheet(paths, cols=8, cell=48, bg=BG, title="@48", gap=36)
small = ck.stack_images([small_big, small_tiny], bg=BG, gap=4)
small = ck.stack_images([small], os.path.join(OUT, "sheet_redo-icons_small.png"), bg=BG, max_side=1024)
print("sheet_redo-icons", sheet.size, "sheet_redo-icons_small", small.size)
