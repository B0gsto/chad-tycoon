"""Contact sheets for the VFX sprites and branding (system python3 + Pillow):

    python3 art/blender/vfx/make_sheet.py

art/out/vfx/sheet_sprites.png        sprites at 256 and 64 px on mid-blue and on light sand, the logo on
                                     blue, the key art, the title card and the small logo
art/out/vfx/sheet_sprites_small.png  the same, at most 1024 px on the long side
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from finish import NAMES, OUT  # noqa: E402
from imgutil import ck  # noqa: E402

BLUE = tuple(ck.PALETTE.get("Board", (52, 70, 138)))
SAND = tuple(ck.PALETTE.get("Sand", (246, 226, 176)))
INK = tuple(ck.PALETTE.get("Ink", (58, 48, 96)))
BRAND = os.path.join(ck.ROOT, "art", "out", "brand")

paths = [os.path.join(OUT, n + ".png") for n in NAMES]
blocks = []
for bg, lab, title in ((BLUE, (255, 255, 255), "Sprites on blue"), (SAND, INK, "Sprites on sand")):
    big = ck.contact_sheet(paths, cols=5, labels=NAMES, cell=256, bg=bg, title=title + " (256 px)", label_rgb=lab)
    small = ck.contact_sheet(paths, cols=10, cell=64, bg=bg, gap=72, title="@64", label_rgb=lab)
    blocks.append(ck.stack_images([big, small], bg=bg))
brand = ck.contact_sheet([os.path.join(BRAND, n + ".png") for n in ("Logo", "KeyArt", "TitleCard", "LogoSmall")],
                         cols=2, cell=(672, 378), bg=BLUE, title="Branding",
                         labels=["Logo 1024x512", "KeyArt 1024x576", "TitleCard 1024x576", "LogoSmall 512x256"])
sheet = ck.stack_images(blocks + [brand], os.path.join(OUT, "sheet_sprites.png"), bg=BLUE, gap=8)
ck.stack_images([sheet], os.path.join(OUT, "sheet_sprites_small.png"), bg=BLUE, max_side=1024)
print("sheet", sheet.size)
