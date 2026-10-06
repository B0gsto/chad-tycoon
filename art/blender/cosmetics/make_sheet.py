"""Contact sheets for the cosmetics icons and the Crown prop (system python3 with Pillow):

    python3 art/blender/cosmetics/make_sheet.py

art/out/icons/sheet_cosmetics.png        every icon at 256 px on the UI blue, labelled, the set at 48 px and the
                                         Crown prop beauty shot + in-game render
art/out/icons/sheet_cosmetics_small.png  the same at 128 px icons, at most 1024 px long side
"""

import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "lib"))
import chadkit as ck  # noqa: E402

OUT = os.path.join(ck.ROOT, "art", "out", "icons")
PROPS = os.path.join(ck.ROOT, "art", "out", "props")
BG = (58, 84, 170)
NAMES = ["CosSpeed", "CosDoubleJump", "CosTrailRainbow", "CosTrailStar", "CosTrailRookie", "CosAura", "CosCrown",
         "CosAll", "CosStarter"]
CROWN = [os.path.join(PROPS, "Crown.png"), os.path.join(PROPS, "Crown_game.png")]

paths = [os.path.join(OUT, n + ".png") for n in NAMES]
missing = [p for p in paths + CROWN if not os.path.exists(p)]
if missing:
    sys.exit("missing: " + ", ".join(missing))

big = ck.contact_sheet(paths, cols=5, labels=NAMES, cell=256, bg=BG, title="Cosmetics icons @256")
tiny = ck.contact_sheet(paths, cols=9, cell=48, bg=BG, title="@48", gap=12)
crown = ck.contact_sheet(CROWN, cols=2, labels=["Crown prop", "Crown in-game"], cell=320, bg=BG,
                         title="props/Crown")
ck.stack_images([big, tiny, crown], os.path.join(OUT, "sheet_cosmetics.png"), bg=BG, gap=8)

mid = ck.contact_sheet(paths, cols=5, labels=NAMES, cell=128, bg=BG, title="Cosmetics icons @128", gap=12)
tiny2 = ck.contact_sheet(paths, cols=9, cell=48, bg=BG, title="@48", gap=12)
crown2 = ck.contact_sheet(CROWN, cols=2, labels=["Crown prop", "Crown in-game"], cell=200, bg=BG, gap=12)
small = ck.stack_images([mid, tiny2, crown2], bg=BG, gap=4, max_side=1024)
small.convert("RGB").save(os.path.join(OUT, "sheet_cosmetics_small.png"))
print("sheet", big.size, "small", small.size)
