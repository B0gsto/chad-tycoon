"""Contact sheets for the shop and reward icons (system python3 with Pillow):

    python3 art/blender/icons_shop/make_sheet.py

art/out/icons/sheet_shop.png        every icon at 256 px on the UI blue, labelled, plus the set at 48 px
art/out/icons/sheet_shop_small.png  the same set at 128 px plus the 48 px rows, at most 1024 px long side
"""

import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "lib"))
import chadkit as ck  # noqa: E402

OUT = os.path.join(ck.ROOT, "art", "out", "icons")
BG = (58, 84, 170)
NAMES = ["CrateCommon", "CrateUncommon", "CrateRare", "CrateEpic", "CrateLegendary",
         "PassAutoCollect", "PassAutoCash", "PassAutoMerge", "PassDoubleOrbs", "PassDoubleCash", "PassVipCracker", "PassCrateKey",
         "CashPack1", "CashPack2", "CashPack3", "CashPack4", "CashPack5", "CashPack6",
         "GemPack1", "GemPack2", "GemPack3", "Heart", "Timer", "Crown", "Fire", "Gift2", "Fans"]

paths = [os.path.join(OUT, n + ".png") for n in NAMES]
missing = [p for p in paths if not os.path.exists(p)]
if missing:
    sys.exit("missing icons: " + ", ".join(missing))

big = ck.contact_sheet(paths, cols=5, labels=NAMES, cell=256, bg=BG, title="Shop + reward icons @256")
tiny = ck.contact_sheet(paths, cols=13, cell=48, bg=BG, title="@48", gap=12)
ck.stack_images([big, tiny], os.path.join(OUT, "sheet_shop.png"), bg=BG, gap=8)

mid = ck.contact_sheet(paths, cols=7, labels=NAMES, cell=128, bg=BG, title="Shop + reward icons @128", gap=12)
tiny2 = ck.contact_sheet(paths, cols=13, cell=48, bg=BG, title="@48", gap=12)
small = ck.stack_images([mid, tiny2], bg=BG, gap=4, max_side=1024)
small.convert("RGB").save(os.path.join(OUT, "sheet_shop_small.png"))
print("sheet", big.size, "small", small.size)
