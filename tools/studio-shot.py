#!/usr/bin/env python3
"""Run Luau in the open Studio place and capture camera shots into a contact sheet (holds the Studio lock).

usage: tools/studio-shot.py [--setup file.luau ...] [--per-shot file.luau] --shots shots.json --out sheet.png
                            [--cols 3] [--cell 640x400] [--dm Edit] [--keep DIR]

shots.json: [{"name": "golden_wide", "cam": [x, y, z], "look": [x, y, z], "lua": "optional code run before this shot"}, ...]
- Every --setup file runs once (Edit datamodel by default), in order, before any capture.
- --per-shot file runs before each shot with the global `SHOT` table ({name=..., index=...}) available.
- Each shot's own "lua" snippet runs right before its capture (e.g. apply a lighting preset).
- Individual full-size captures are saved to --keep DIR (default: next to --out) as <name>.png.
Studio must be frontmost for screen_capture; the script activates it."""
import base64, io, json, os, subprocess, sys, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from studio import StudioSession, studio_lock
from PIL import Image, ImageDraw, ImageFont


def main():
    args = sys.argv[1:]
    if not args or "--shots" not in args or "--out" not in args:
        sys.exit(__doc__)
    setups = [args[i + 1] for i, a in enumerate(args) if a == "--setup"]
    opt = lambda k, d=None: args[args.index(k) + 1] if k in args else d  # noqa: E731
    shots = json.load(open(opt("--shots")))
    out = opt("--out")
    per_shot = opt("--per-shot")
    dm = opt("--dm", "Edit")
    cols = int(opt("--cols", 3))
    cw, ch = (int(v) for v in opt("--cell", "640x400").split("x"))
    keep = opt("--keep", os.path.join(os.path.dirname(os.path.abspath(out)), os.path.splitext(os.path.basename(out))[0]))
    os.makedirs(keep, exist_ok=True)
    per_code = open(per_shot).read() if per_shot else ""
    results = []
    with studio_lock("studio-shot " + os.path.basename(out)):
        subprocess.run(["osascript", "-e", 'tell application "RobloxStudio" to activate'], check=False)
        with StudioSession() as s:
            sid = s.studio_id()

            def lua(code, timeout=300):
                ok, texts, _ = s.call("execute_luau", {"studio_id": sid, "datamodel_type": dm, "code": code}, timeout)
                if not ok:
                    raise RuntimeError("luau failed: " + " ".join(texts))
                return " ".join(texts)

            for f in setups:
                print(f"setup {f}: {lua(open(f).read())[:300]}")
            first = True
            for i, shot in enumerate(shots):
                if per_code:
                    lua(f'local SHOT = {{name = "{shot["name"]}", index = {i + 1}}}\n' + per_code)
                if shot.get("lua"):
                    lua(shot["lua"])
                time.sleep(float(shot.get("settle", 0.6)))
                cap = {"studio_id": sid, "capture_id": f"Shot_{i}", "camera_position": shot["cam"], "look_at_position": shot["look"]}
                if first:  # auto-exposure warm-up capture, discarded
                    s.call("screen_capture", cap)
                    time.sleep(1.0)
                    first = False
                ok, texts, images = s.call("screen_capture", cap)
                if not images:
                    raise RuntimeError("capture failed: " + " ".join(texts))
                img = Image.open(io.BytesIO(base64.b64decode(images[0]))).convert("RGB")
                path = os.path.join(keep, f"{shot['name']}.png")
                img.save(path)
                results.append((shot["name"], img))
                print("shot", shot["name"], path)
    rows = (len(results) + cols - 1) // cols
    sheet = Image.new("RGB", (cw * cols, (ch + 26) * rows), (20, 22, 26))
    d = ImageDraw.Draw(sheet)
    try:
        font = ImageFont.truetype("/System/Library/Fonts/Supplemental/Arial Bold.ttf", 17)
    except OSError:
        font = ImageFont.load_default()
    for i, (name, img) in enumerate(results):
        x, y = (i % cols) * cw, (i // cols) * (ch + 26)
        w, h = img.size
        scale = max(cw / w, ch / h)
        im = img.resize((int(w * scale), int(h * scale)))
        ox, oy = (im.size[0] - cw) // 2, (im.size[1] - ch) // 2
        sheet.paste(im.crop((ox, oy, ox + cw, oy + ch)), (x, y + 26))
        d.text((x + 8, y + 4), name, fill=(235, 235, 235), font=font)
    sheet.save(out)
    print("SHEET:", out)


if __name__ == "__main__":
    main()
