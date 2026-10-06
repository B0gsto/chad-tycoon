#!/usr/bin/env python3
"""Background screenshots of a Roblox Studio place window (Studio may stay behind other apps), plus contact sheets.

usage:
  tools/studio-window-shot.py --out shot.png [--match TEXT] [--crop viewport|none|X,Y,W,H]
  tools/studio-window-shot.py --burst EVERY --for SECONDS --out sheet.png [--frames DIR] [--match TEXT] [--crop ...]
  tools/studio-window-shot.py --sheet a.png=Label b.png=Label ... --out sheet.png
common: [--cols N] [--width PX] (sheet width, default 1600) [--title TEXT]

  --match   picks the window whose title contains TEXT (e.g. TestBench-integ.rbxl); default: the largest Studio
            window. Prefer an explicit --match when several places are open.
  --crop    viewport (default): the 3D viewport, found from the window's Accessibility layout (largest AXGroup);
            none: the whole window; X,Y,W,H: window-local points.
  --burst   capture every EVERY seconds for SECONDS (use it while an MCP play session runs). Frames go to --frames
            (default: <out stem>/) as f000.png ... and the sheet is labelled with the elapsed time.
  --sheet   only builds a labelled contact sheet from existing images (e.g. MCP-posed camera shots).
Captures use `screencapture -x -o -l <CGWindowID>`: no focus change, no sound, works when the window is covered
(not when it is minimised). Studio must not be minimised and the Mac must not be asleep.
"""
import os, sys, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import studio_window as sw  # noqa: E402
from PIL import Image, ImageDraw, ImageFont  # noqa: E402


def font(size):
    for p in ("/System/Library/Fonts/SFNS.ttf", "/System/Library/Fonts/Helvetica.ttc", "/Library/Fonts/Arial.ttf"):
        try:
            return ImageFont.truetype(p, size)
        except OSError:
            pass
    return ImageFont.load_default()


def contact_sheet(items, out, cols=None, width=1600, title=None):
    """items: [(path, label)]. Writes a grid no wider than `width` px with a label strip under each cell."""
    imgs = [(Image.open(p).convert("RGB"), lab) for p, lab in items if os.path.exists(p)]
    if not imgs:
        raise SystemExit("no images for the contact sheet")
    n = len(imgs)
    cols = cols or (1 if n == 1 else 2 if n <= 4 else 3 if n <= 9 else 4)
    cols = min(cols, n)
    gap, strip = 6, 26
    cw = (width - gap * (cols + 1)) // cols
    ar = imgs[0][0].height / imgs[0][0].width
    ch = int(cw * ar)
    rows = (n + cols - 1) // cols
    head = 34 if title else 0
    sheet = Image.new("RGB", (gap + cols * (cw + gap), head + gap + rows * (ch + strip + gap)), (24, 24, 28))
    d = ImageDraw.Draw(sheet)
    f = font(17)
    if title:
        d.text((gap + 4, 8), title, fill=(235, 235, 235), font=font(20))
    for i, (im, lab) in enumerate(imgs):
        r, c = divmod(i, cols)
        x, y = gap + c * (cw + gap), head + gap + r * (ch + strip + gap)
        im.thumbnail((cw, ch))
        sheet.paste(im, (x + (cw - im.width) // 2, y + (ch - im.height) // 2))
        d.text((x + 4, y + ch + 4), lab, fill=(235, 235, 235), font=f)
    sheet.save(out)
    return out


class Shooter:
    def __init__(self, match=None, crop="viewport"):
        self.match, self.crop_mode = match, crop
        self.win = self.rect = None
        self.refresh()

    def refresh(self):
        self.win = sw.find_window(self.match)
        if not self.win:
            raise SystemExit("no Roblox Studio window%s" % (" matching %r" % self.match if self.match else ""))
        self.rect = None
        if self.crop_mode not in (None, "none"):
            if self.crop_mode == "viewport":
                title = self.win["name"] or next((t for t in sw.place_windows() if not self.match or self.match in t), "")
                self.rect = sw.viewport_rect(title) if title else None
                if not self.rect:
                    sys.stderr.write("[shot] viewport not found; capturing the whole window\n")
            else:
                self.rect = tuple(int(v) for v in self.crop_mode.split(","))

    def shot(self, path):
        if not sw.capture(self.win["id"], path):  # window id changes when a place is reopened
            self.refresh()
            if not sw.capture(self.win["id"], path):
                raise SystemExit("screencapture failed (Screen Recording permission? window minimised?)")
        if self.rect:
            im = Image.open(path)
            s = im.width / self.win["w"]  # pixels per point (2 on Retina)
            x, y, w, h = self.rect
            im.crop((round(x * s), round(y * s), round((x + w) * s), round((y + h) * s))).save(path)
        return path


def main():
    a = sys.argv[1:]
    opt = lambda k, d=None: a[a.index(k) + 1] if k in a else d  # noqa: E731
    out = opt("--out")
    if not out:
        sys.exit(__doc__)
    out = os.path.abspath(out)
    os.makedirs(os.path.dirname(out), exist_ok=True)
    cols = int(opt("--cols")) if "--cols" in a else None
    width = int(opt("--width", 1600))
    title = opt("--title")
    if "--sheet" in a:
        items = []
        for tok in a[a.index("--sheet") + 1:]:
            if tok.startswith("--"):
                break
            p, _, lab = tok.partition("=")
            items.append((p, lab or os.path.basename(p)))
        print(contact_sheet(items, out, cols, width, title))
        return
    shooter = Shooter(opt("--match"), opt("--crop", "viewport"))
    if "--burst" not in a:
        print(shooter.shot(out))
        return
    every, total = float(opt("--burst")), float(opt("--for", 60))
    frames = opt("--frames", os.path.splitext(out)[0])
    os.makedirs(frames, exist_ok=True)
    items, t0, i = [], time.time(), 0
    while True:
        target = t0 + i * every
        if target - t0 > total + 1e-6:
            break
        time.sleep(max(0.0, target - time.time()))
        p = os.path.join(frames, "f%03d.png" % i)
        shooter.shot(p)
        items.append((p, "t=%.1fs" % (time.time() - t0)))
        i += 1
    print("frames:", frames, "(%d)" % len(items))
    print(contact_sheet(items, out, cols, width, title))


if __name__ == "__main__":
    main()
