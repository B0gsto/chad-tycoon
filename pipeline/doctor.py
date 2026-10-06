#!/usr/bin/env python3
"""pipeline/doctor.py - check the Blender -> Roblox asset pipeline on this machine.

usage: python3 pipeline/doctor.py [--online]
Offline: tools on PATH (python3, lune, rojo, stylua), Blender 5.x, the API key file (existence only, never read
aloud), deploy/target.json, pins.json <-> .rbxm consistency, Assets.luau up to date, the lock and rbxkit self-tests.
--online: the key is accepted by Open Cloud (GET of a pinned asset, or the public universe lookup + an assets read)
and target.json's universe matches the published place.
Exit 0 when every check passes."""
import json
import os
import shutil
import subprocess
import sys
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
GAME_DIR = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(GAME_DIR, "tools"))
import assets  # noqa: E402
import locks  # noqa: E402

BLENDER = "/Applications/Blender.app/Contents/MacOS/Blender"
results = []


def check(name, ok, detail=""):
    results.append(ok)
    print(("ok   " if ok else "FAIL ") + name + (f"  ({detail})" if detail else ""))


def run(cmd, timeout=120):
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, cwd=GAME_DIR)
        return r.returncode, (r.stdout + r.stderr).strip()
    except (OSError, subprocess.TimeoutExpired) as e:
        return 1, str(e)


def main():
    online = "--online" in sys.argv[1:]
    for tool in ("python3", "lune", "rojo", "stylua"):
        path = shutil.which(tool)
        check(f"{tool} on PATH", bool(path), path or "missing")
    if os.path.exists(BLENDER):
        rc, out = run([BLENDER, "--version"], 60)
        first = out.splitlines()[0] if out else ""
        check("Blender 5.x", rc == 0 and first.startswith("Blender 5"), first)
    else:
        check("Blender installed", False, BLENDER)
    check("API key file present", os.path.isfile(assets.KEY_PATH), "~/RobloxProjects/.roblox-api-key")
    t = assets.target(GAME_DIR)
    check("deploy/target.json", bool(t.get("placeId") and t.get("universeId")), f"place {t.get('placeId')} universe {t.get('universeId')}")
    check("creator", True, json.dumps(assets.creator(GAME_DIR)))
    check("lock name", locks.game_name() == "ChadTycoon", "assets." + locks.game_name())
    try:
        with open(os.path.join(GAME_DIR, "assets", "pins.json")) as f:
            pins = json.load(f).get("pins", {})
    except FileNotFoundError:
        pins = {}
    missing = [k for k, p in pins.items() if p.get("kind") == "Model" and not os.path.isfile(os.path.join(GAME_DIR, p.get("rbxm", "")))]
    check(f"pins.json ({len(pins)} pins), every Model has its .rbxm", not missing, ", ".join(missing))
    rc, out = run([sys.executable, os.path.join(HERE, "gen_assets.py"), "--check"])
    check("src/shared/Assets.luau up to date", rc == 0, out)
    rc, out = run([sys.executable, os.path.join(GAME_DIR, "tools", "blender", "rbxkit.py")])
    check("rbxkit self-test", rc == 0, out.splitlines()[-1] if out else "")
    rc, out = run([sys.executable, os.path.join(GAME_DIR, "tools", "assets.py"), "selftest"], 300)
    check("assets.py self-test", rc == 0, out.splitlines()[-1] if out else "")
    rc, out = run([os.path.join(GAME_DIR, "tools", "with-lock.sh"), "assets.ChadTycoon", "--quiet", "--timeout", "30", "--", "true"])
    check("machine-wide lock assets.ChadTycoon", rc == 0, out[-200:])

    if online:
        try:
            with urllib.request.urlopen(f"https://apis.roblox.com/universes/v1/places/{t.get('placeId')}/universe", timeout=30) as r:
                uni = json.loads(r.read()).get("universeId")
            check("universe of the published place matches target.json", str(uni) == str(t.get("universeId")), str(uni))
        except Exception as e:  # noqa: BLE001
            check("universe lookup", False, str(e)[:200])
        probe = next((p["assetId"] for p in pins.values() if p.get("assetId")), None)
        if probe:
            s, _ = assets._http("GET", f"/assets/v1/assets/{probe}?readMask=moderationResult")
            check("Open Cloud accepts the key (assets read)", s == 200, f"HTTP {s} for asset {probe}")
        else:
            # no pin yet: an empty-operation read still proves authentication (401/403 = bad key, 404 = accepted)
            s, _ = assets._http("GET", "/assets/v1/operations/00000000-0000-0000-0000-000000000000")
            check("Open Cloud accepts the key", s not in (401, 403), f"HTTP {s}")
    ok = all(results)
    print("DOCTOR " + ("OK" if ok else "FAILED"))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
