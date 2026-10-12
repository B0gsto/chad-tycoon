"""Joins screenshots into one labelled contact sheet (three columns).

python3 preview/render/sheet.py <out.png> <label> <shot.png>...
"""

import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

COLS, CELL, GAP = 3, 640, 6


def font(size):
    try:
        return ImageFont.truetype("/System/Library/Fonts/Helvetica.ttc", size)
    except OSError:
        return ImageFont.load_default()


def main():
    out, label, paths = sys.argv[1], sys.argv[2], sys.argv[3:]
    cells = []
    for path in paths:
        shot = Image.open(path).convert("RGB")
        shot = shot.resize((CELL, round(shot.height * CELL / shot.width)), Image.LANCZOS)
        draw = ImageDraw.Draw(shot)
        tag = f"{label}: {Path(path).stem.split('-', 2)[-1]}"
        face = font(20)
        draw.rectangle([6, 6, 18 + draw.textlength(tag, font=face), 34], fill=(0, 0, 0))
        draw.text((12, 9), tag, fill=(255, 255, 255), font=face)
        cells.append(shot)
    rows = (len(cells) + COLS - 1) // COLS
    height = max(cell.height for cell in cells)
    sheet = Image.new("RGB", (COLS * CELL + (COLS - 1) * GAP, rows * height + (rows - 1) * GAP), (20, 20, 20))
    for i, cell in enumerate(cells):
        sheet.paste(cell, ((i % COLS) * (CELL + GAP), (i // COLS) * (height + GAP)))
    sheet.save(out)


if __name__ == "__main__":
    main()
