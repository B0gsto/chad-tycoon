"""Draws bold "x3" / "x14" / "x30" value tags over the orb pile render (system python3 + Pillow).

Usage: python3 art/blender/orbs/tag_sheet.py art/out/props/sheet_orbs.png
Reads the tag anchors make_orbs.py wrote next to the image (<png>.tags.json) and overwrites the PNG.
Text is a lightened ball colour with a dark ink outline (40, 34, 60).
"""

import json
import os
import sys

from PIL import Image, ImageDraw, ImageFont

FONT = "/System/Library/Fonts/Supplemental/Arial Rounded Bold.ttf"
INK = (40, 34, 60)


def main(path):
	tags_path = path + ".tags.json"
	with open(tags_path) as f:
		tags = json.load(f)
	img = Image.open(path).convert("RGB")
	draw = ImageDraw.Draw(img)
	font = ImageFont.truetype(FONT, 58)
	for t in tags:
		r, g, b = t["rgb"]
		light = tuple(int(c + (255 - c) * 0.45) for c in (r, g, b))
		draw.text((t["x"], t["y"]), t["text"], font=font, fill=light, anchor="ms", stroke_width=7, stroke_fill=INK)
	img.save(path)
	os.remove(tags_path)


if __name__ == "__main__":
	main(sys.argv[1])
