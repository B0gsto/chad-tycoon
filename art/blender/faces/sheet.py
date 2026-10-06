"""Contact sheet for the hero faces: each face on a light and a dark skin-coloured circle.

    python3 art/blender/faces/sheet.py art/out/faces Happy Proud ...   (faces.py runs it after rendering)
Writes <dir>/sheet.png and <dir>/sheet_small.png (max 1024 px).
"""

import os
import sys

from PIL import Image, ImageDraw, ImageFont

SKINS = [(255, 214, 170), (124, 78, 50)]  # light and dark skin
CELL = 300
LABEL = 40


def main():
    out, names = sys.argv[1], sys.argv[2:]
    cols = len(names)
    sheet = Image.new("RGB", (cols * CELL, len(SKINS) * CELL + LABEL), (236, 240, 248))
    draw = ImageDraw.Draw(sheet)
    try:
        font = ImageFont.truetype("/System/Library/Fonts/Supplemental/Arial Rounded Bold.ttf", 28)
    except OSError:
        font = ImageFont.load_default()
    for c, name in enumerate(names):
        face = Image.open(os.path.join(out, name + ".png")).convert("RGBA").resize((CELL - 20, CELL - 20), Image.LANCZOS)
        draw.text((c * CELL + CELL // 2, LABEL // 2), name, fill=(42, 54, 114), font=font, anchor="mm")
        for r, skin in enumerate(SKINS):
            x, y = c * CELL + 10, LABEL + r * CELL + 10
            draw.ellipse((x, y, x + CELL - 20, y + CELL - 20), fill=skin)
            sheet.paste(face, (x, y), face)
    sheet.save(os.path.join(out, "sheet.png"))
    small = sheet.copy()
    small.thumbnail((1024, 1024), Image.LANCZOS)
    small.save(os.path.join(out, "sheet_small.png"))
    print("[faces] sheet", sheet.size, "small", small.size)


main()
