#!/usr/bin/env python3
"""tools/pack_atlas.py - pack square RGBA icon PNGs into 1024x1024 atlases for one Roblox image upload each.

usage: python3 tools/pack_atlas.py <domain> <icon dir or .png> [more dirs / .pngs ...] [--write-spec]

Each atlas is a 5x5 grid of 204 px cells (25 icons per atlas). Every icon is scaled to fit its cell with 4 px of
transparent padding (196 px of art) and centred. Icons are packed in sorted name order, so the same inputs always
give byte-identical PNGs and JSON. The icon name is the file name in PascalCase ("coin.png" and "Coin.png" -> Coin,
"cash_rain.png" -> CashRain), which is the key Kit.icon looks up.

Writes art/out/atlas/<domain>_<n>.png (n = 1, 2, ...) and art/out/atlas/<domain>.json:
  { "art/out/atlas/ui_1.png": { "Coin": [x, y, w, h], ... }, ... }
Stale <domain>_<n>.png files from an earlier, larger run are removed.

--write-spec also upserts one Image entry per atlas ("atlas_<n>", with its "cells") into art/assets/<domain>.json,
so `python3 pipeline/upload.py <domain>` uploads the atlases and gen_assets.py emits Assets.Icons."""
import glob
import json
import os
import re
import sys

from PIL import Image

GAME_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT_DIR = os.path.join(GAME_DIR, "art", "out", "atlas")
SPECS = os.path.join(GAME_DIR, "art", "assets")

ATLAS = 1024
GRID = 5
CELL = 204
PAD = 4
PER_ATLAS = GRID * GRID


def dump(obj, sort_keys=True):
    """Indented JSON with each [x, y, w, h] rect on one line."""
    text = json.dumps(obj, indent=2, sort_keys=sort_keys)
    return re.sub(r"\[\s*(-?\d+),\s*(-?\d+),\s*(-?\d+),\s*(-?\d+)\s*\]", r"[\1, \2, \3, \4]", text) + "\n"


def icon_name(path):
    stem = os.path.splitext(os.path.basename(path))[0]
    parts = [p for p in re.split(r"[\s_\-]+", stem) if p]
    return "".join(p[0].upper() + p[1:] for p in parts)


def collect(args):
    files = []
    for a in args:
        if os.path.isdir(a):
            files += [f for f in glob.glob(os.path.join(a, "*")) if f.lower().endswith(".png") and os.path.isfile(f)]
        elif a.lower().endswith(".png") and os.path.isfile(a):
            files.append(a)
        else:
            raise SystemExit(f"pack_atlas: not a directory or .png file: {a}")
    named = {}
    for f in files:
        name = icon_name(f)
        if not name:
            continue
        if name in named and os.path.abspath(named[name]) != os.path.abspath(f):
            raise SystemExit(f"pack_atlas: two icons are both named {name}: {named[name]} and {f}")
        named[name] = f
    return sorted(named.items())


def fit(img):
    """The icon scaled to fit CELL - 2 * PAD (keeping aspect), as RGBA."""
    img = img.convert("RGBA")
    box = CELL - 2 * PAD
    w, h = img.size
    s = min(box / w, box / h)
    nw, nh = max(1, round(w * s)), max(1, round(h * s))
    if (nw, nh) != (w, h):
        img = img.resize((nw, nh), Image.LANCZOS)
    return img


def pack(domain, icons):
    os.makedirs(OUT_DIR, exist_ok=True)
    layout = {}
    written = set()
    for a in range(0, len(icons), PER_ATLAS):
        n = a // PER_ATLAS + 1
        sheet = Image.new("RGBA", (ATLAS, ATLAS), (0, 0, 0, 0))
        cells = {}
        for i, (name, path) in enumerate(icons[a : a + PER_ATLAS]):
            cx, cy = (i % GRID) * CELL, (i // GRID) * CELL
            with Image.open(path) as src:
                img = fit(src)
            sheet.alpha_composite(img, (cx + (CELL - img.width) // 2, cy + (CELL - img.height) // 2))
            cells[name] = [cx, cy, CELL, CELL]
        fname = f"{domain}_{n}.png"
        path = os.path.join(OUT_DIR, fname)
        sheet.save(path, format="PNG", optimize=False, compress_level=9)
        written.add(fname)
        layout[os.path.relpath(path, GAME_DIR)] = cells
    for old in glob.glob(os.path.join(OUT_DIR, f"{domain}_*.png")):
        if re.fullmatch(re.escape(domain) + r"_\d+\.png", os.path.basename(old)) and os.path.basename(old) not in written:
            os.remove(old)
    with open(os.path.join(OUT_DIR, f"{domain}.json"), "w") as f:
        f.write(dump(layout))
    return layout


def write_spec(domain, layout):
    path = os.path.join(SPECS, f"{domain}.json")
    try:
        with open(path) as f:
            doc = json.load(f)
    except FileNotFoundError:
        doc = {"domain": domain, "assets": []}
    assets = [a for a in doc.get("assets", []) if not re.fullmatch(r"atlas_\d+", str(a.get("name", "")))]
    for file in sorted(layout, key=lambda p: int(re.search(r"_(\d+)\.png$", p).group(1))):
        n = re.search(r"_(\d+)\.png$", file).group(1)
        assets.append({"name": f"atlas_{n}", "file": file, "kind": "Image", "cells": layout[file]})
    doc["assets"] = assets
    os.makedirs(SPECS, exist_ok=True)
    with open(path, "w") as f:
        f.write(dump(doc, sort_keys=False))
    return path


def main(argv):
    flags = [a for a in argv if a.startswith("--")]
    args = [a for a in argv if not a.startswith("--")]
    if len(args) < 2 or any(f not in ("--write-spec",) for f in flags):
        print(__doc__.strip().splitlines()[2], file=sys.stderr)
        return 2
    domain = args[0]
    if not re.fullmatch(r"[A-Za-z0-9_\-]+", domain):
        print(f"pack_atlas: bad domain name: {domain}", file=sys.stderr)
        return 2
    icons = collect(args[1:])
    if not icons:
        print("pack_atlas: no .png icons found", file=sys.stderr)
        return 1
    layout = pack(domain, icons)
    for file, cells in layout.items():
        print(f"{file}: {len(cells)} icon(s)")
    print(os.path.relpath(os.path.join(OUT_DIR, f"{domain}.json"), GAME_DIR))
    if "--write-spec" in flags:
        print("updated " + os.path.relpath(write_spec(domain, layout), GAME_DIR))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
