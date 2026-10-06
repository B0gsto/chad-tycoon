#!/usr/bin/env python3
"""pipeline/upload.py - upload the assets listed in art/assets/<domain>.json and pin them in assets/pins.json.

usage:
  pipeline/upload.py DOMAIN [DOMAIN ...]     e.g. proof ui props        (spec = art/assets/<domain>.json)
  pipeline/upload.py --all                   every art/assets/*.json (also what no DOMAIN means)
  options:
    --check            no network: list what would upload and which pins are not Approved (exit 1 if any)
    --allow-pending    exit 0 even when some pins are still Reviewing (a Rejected pin always fails)
    --poll-seconds N   wait at most N s for moderation to settle (default 300; 0 = do not wait)
    --route R          force one model download route (delivery | luau); default tries both in that order
    --no-codegen       do not regenerate src/shared/Assets.luau afterwards
    --json             machine-readable summary on stdout (logs go to stderr)

Spec (art/assets/<domain>.json):
  {"domain": "props", "assets": [{"name": "dumbbell", "file": "art/out/props/dumbbell.fbx", "kind": "Model"},
                                 {"name": "coin", "file": "art/out/ui/coin.png", "kind": "Image"}]}
  (a bare list of entries also works; the domain then comes from the file name). kind is Image (PNG/JPG) or
  Model (FBX/GLB); it defaults from the file extension. The pin key is "<domain>/<name>".

What a run does, holding the machine-wide lock assets.ChadTycoon (tools/locks.py) for the whole run:
  1. For every entry, sha256 of the file. Unchanged sha + Approved pin (+ the .rbxm for a Model) = skipped, no network.
     A missing source file with an existing pin is kept (warning), so a clean checkout never loses ids.
  2. Otherwise upload through tools/assets.py (content-addressed manifest: identical bytes never upload twice; creator
     from deploy/target.json). Models are downloaded back to assets/models/<domain>__<name>.rbxm and measured with
     pipeline/measure_rbxm.luau (Lune): the pin records the first MeshPart's MeshId and the model's size in studs.
  3. Pins are written to assets/pins.json (sorted, stable) and pending ones are polled until Approved / Rejected or
     --poll-seconds runs out. Then pipeline/gen_assets.py regenerates src/shared/Assets.luau.
Exit: 0 all Approved (or --allow-pending), 1 error / --check found work, 2 a pin was Rejected, 3 still pending."""
import argparse
import datetime
import glob
import hashlib
import json
import os
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
GAME_DIR = os.path.dirname(HERE)
TOOLS = os.path.join(GAME_DIR, "tools")
sys.path.insert(0, TOOLS)
import assets  # noqa: E402  (tools/assets.py)
import locks  # noqa: E402  (tools/locks.py)

PINS = os.path.join(GAME_DIR, "assets", "pins.json")
SPECS = os.path.join(GAME_DIR, "art", "assets")
LOCK = "assets." + locks.GAME
EXT_KIND = {".png": "Image", ".jpg": "Image", ".jpeg": "Image", ".fbx": "Model", ".glb": "Model", ".gltf": "Model"}
KINDS = ("Image", "Model")
LOG = sys.stdout


def log(msg):
    print(msg, file=LOG, flush=True)


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def now_iso():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def load_spec(path):
    with open(path) as f:
        doc = json.load(f)
    domain = os.path.splitext(os.path.basename(path))[0]
    items = doc
    if isinstance(doc, dict):
        domain = doc.get("domain", domain)
        items = doc.get("assets", [])
    if not isinstance(items, list):
        raise ValueError(f"{path}: expected a list of assets")
    out = []
    for i, it in enumerate(items):
        if not isinstance(it, dict) or not it.get("name") or not it.get("file"):
            raise ValueError(f"{path}: entry {i} needs name and file")
        kind = it.get("kind") or EXT_KIND.get(os.path.splitext(it["file"])[1].lower())
        if kind not in KINDS:
            raise ValueError(f"{path}: {it['name']}: kind must be one of {KINDS}")
        out.append({"key": f"{domain}/{it['name']}", "domain": domain, "name": it["name"], "file": it["file"], "kind": kind})
    return out


def read_pins():
    try:
        with open(PINS) as f:
            doc = json.load(f)
    except FileNotFoundError:
        doc = {}
    doc.setdefault("version", 1)
    doc.setdefault("pins", {})
    return doc


def write_pins(changes):
    """Locked read-merge-write of assets/pins.json (other writers' pins survive)."""
    with assets.file_lock(assets.sidecar_lock(PINS)):
        doc = read_pins()
        doc["pins"].update(changes)
        doc["pins"] = dict(sorted(doc["pins"].items()))
        assets.atomic_write(PINS, json.dumps(doc, indent=2, sort_keys=True) + "\n", "w")
        return doc


def measure_rbxm(rel):
    """{meshId, size: [x, y, z], meshParts} of a downloaded model (pipeline/measure_rbxm.luau)."""
    r = subprocess.run(["lune", "run", os.path.join(HERE, "measure_rbxm.luau"), os.path.join(GAME_DIR, rel)],
                       capture_output=True, text=True, timeout=120, cwd=GAME_DIR)
    if r.returncode != 0:
        raise RuntimeError(f"measure {rel}: {r.stderr.strip()[-400:]}")
    return json.loads(r.stdout.strip().splitlines()[-1])


def status(item, pin):
    """'upload' | 'poll' | 'ok' | 'missing' (file absent, pin kept) | 'error' (file absent, no pin)."""
    path = os.path.join(GAME_DIR, item["file"])
    if not os.path.isfile(path):
        return "missing" if pin else "error"
    if not pin or pin.get("sha256") != sha256_file(path) or pin.get("kind") != item["kind"]:
        return "upload"
    if item["kind"] == "Model" and not os.path.isfile(os.path.join(GAME_DIR, pin.get("rbxm", ""))):
        return "upload"
    return "ok" if pin.get("moderation") == "Approved" else "poll"


def upload_one(item, route):
    path = os.path.join(GAME_DIR, item["file"])
    safe = item["key"].replace("/", "__")
    entry = assets.upload(GAME_DIR, path, item["kind"], safe, log=log, route=route)
    pin = {"assetId": str(entry["assetId"]), "kind": item["kind"], "moderation": entry.get("moderation") or "Reviewing",
           "sha256": entry["sha"], "source": item["file"], "updatedAt": now_iso()}
    if item["kind"] == "Model":
        rel = entry.get("rbxm")
        want = os.path.join("assets", "models", safe + ".rbxm")
        if rel != want:  # identical bytes pinned under another name: keep a copy under this key's name too
            assets.atomic_write(os.path.join(GAME_DIR, want), open(os.path.join(GAME_DIR, rel), "rb").read())
        m = measure_rbxm(want)
        pin.update(rbxm=want, meshId=m.get("meshId"), size=m.get("size"), meshParts=m.get("meshParts"))
    return pin


def poll(pins, keys, seconds):
    """Re-read moderation for `keys` until all are final or `seconds` pass. Returns the changed pins."""
    changed = {}
    end = time.time() + seconds
    pending = [k for k in keys if pins[k].get("moderation") not in assets.FINAL_MODERATION]
    while pending:
        for k in list(pending):
            state = assets.moderation_state(pins[k]["assetId"])
            if state != "Unknown" and state != pins[k].get("moderation"):
                pins[k] = dict(pins[k], moderation=state)
                changed[k] = pins[k]
                log(f"{k}: {state}")
            if pins[k].get("moderation") in assets.FINAL_MODERATION:
                pending.remove(k)
        if not pending or time.time() >= end:
            break
        time.sleep(10)
    return changed


def spec_paths(domains, all_):
    if domains and not all_:
        return [os.path.join(SPECS, d + ".json") for d in domains]
    return sorted(glob.glob(os.path.join(SPECS, "*.json")))


def main(argv=None):
    global LOG
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("domains", nargs="*")
    ap.add_argument("--all", action="store_true")
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--allow-pending", action="store_true")
    ap.add_argument("--poll-seconds", type=int, default=300)
    ap.add_argument("--route")
    ap.add_argument("--no-codegen", action="store_true")
    ap.add_argument("--json", action="store_true")
    a = ap.parse_args(argv)
    if a.json:
        LOG = sys.stderr
    items = []
    for p in spec_paths(a.domains, a.all):
        if not os.path.isfile(p):
            log(f"no spec {os.path.relpath(p, GAME_DIR)}")
            return 1
        items += load_spec(p)
    keys = [it["key"] for it in items]
    if len(set(keys)) != len(keys):
        log("duplicate pin keys in the specs")
        return 1

    def summary(pins, states, rc):
        if a.json:
            print(json.dumps({"exit": rc, "assets": {k: dict(pins.get(k, {}), status=states.get(k)) for k in keys}}, indent=2))
        return rc

    pins = read_pins()["pins"]
    states = {it["key"]: status(it, pins.get(it["key"])) for it in items}
    if a.check:
        for k, s in states.items():
            log(f"{s:8} {k}" + (f"  ({pins[k].get('moderation')})" if k in pins else ""))
        return summary(pins, states, 0 if all(s == "ok" for s in states.values()) else 1)

    rc = 0
    with locks.Lock(LOCK, owner="pipeline/upload.py " + " ".join(a.domains or ["--all"])):
        pins = read_pins()["pins"]
        changes = {}
        for it in items:
            k = it["key"]
            st = status(it, pins.get(k))
            states[k] = st
            if st == "error":
                log(f"ERROR {k}: {it['file']} does not exist and has no pin")
                rc = 1
            elif st == "missing":
                log(f"warning {k}: {it['file']} is not built; keeping pin {pins[k]['assetId']}")
            elif st == "upload":
                try:
                    pins[k] = changes[k] = upload_one(it, a.route)
                    write_pins({k: pins[k]})  # the id is on disk before anything else can fail
                    states[k] = "uploaded"
                    log(f"pinned {k} -> {pins[k]['assetId']} ({pins[k]['moderation']})")
                except Exception as e:  # noqa: BLE001
                    log(f"ERROR {k}: {e}")
                    states[k] = "error"
                    rc = 1
        polled = [k for k in keys if k in pins and pins[k].get("moderation") not in assets.FINAL_MODERATION]
        if polled and a.poll_seconds > 0:
            log(f"waiting up to {a.poll_seconds}s for moderation of {len(polled)} asset(s)")
        moved = poll(pins, polled, a.poll_seconds) if polled else {}
        for k, p in moved.items():
            p["updatedAt"] = now_iso()
        changes.update(moved)
        if moved:
            write_pins(moved)
        if changes and not a.no_codegen:
            r = subprocess.run([sys.executable, os.path.join(HERE, "gen_assets.py")], cwd=GAME_DIR, capture_output=True, text=True)
            log(r.stdout.strip() or r.stderr.strip())
            if r.returncode != 0:
                rc = 1
    mods = {k: pins[k].get("moderation") for k in keys if k in pins}
    if any(m == "Rejected" for m in mods.values()):
        log("REJECTED: " + ", ".join(k for k, m in mods.items() if m == "Rejected"))
        rc = rc or 2
    pending = [k for k, m in mods.items() if m not in assets.FINAL_MODERATION]
    if pending:
        log(("still pending: " if a.allow_pending else "PENDING: ") + ", ".join(pending))
        if not a.allow_pending:
            rc = rc or 3
    return summary(pins, states, rc)


if __name__ == "__main__":
    sys.exit(main())
