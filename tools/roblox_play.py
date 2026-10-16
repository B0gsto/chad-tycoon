#!/usr/bin/env python3
"""Play the game on a real Roblox TEST server and take screenshots (docs/agent-playtest.md).

usage:
  tools/roblox_play.py join [--target test] [--timeout SEC] [--wait SEC]
        take the player lock, launch the Roblox Player into the TEST place, wait for its window and for a `ping`
        through the bridge that returns this user; prints the server's jobId. `--target live` is refused.
  tools/roblox_play.py cmd <name> [json-args] [--user ID] [--timeout SEC]
        run one bridge command (Server.TestBridge: ping, state, cash, teleport, mode, stopmode, ui, camera, hideui,
        list) and print its result JSON. Exit 1 when the command failed or nobody answered.
  tools/roblox_play.py shot <out.png> [--scale 0.5]
        capture ONLY the Roblox Player window (no shadow), downscaled with sips; prints path and size.
  tools/roblox_play.py key <step>...      e.g. `key w:1.5 space`, `key escape` (tools/roblox-player.swift)
  tools/roblox_play.py click <x> <y>      left click at a window-relative point (points, not pixels)
  tools/roblox_play.py quit [--keep-lock] close the Roblox Player and release the lock
  tools/roblox_play.py lock status | acquire [--wait SEC] | release [--force]
  tools/roblox_play.py windows            the Roblox Player windows as JSON (debug)

The player lock (/tmp/roblox-player.lock, an atomic mkdir) is held from `join` to `quit`, so parallel agents take
turns on the one Roblox Player this Mac runs. Owner = --owner, else $ROBLOX_PLAY_OWNER, else the caller's git
worktree. shot/key/click/cmd need the lock held by the caller. A lock idle for 20 min is stale and may be taken.

Commands travel as Open Cloud MessagingService messages (topic "TestBridge") to every server of the TEST universe;
the server holding the target player writes the result to the MemoryStore sorted map "TestBridge" under the
message id, which this tool polls. The API key comes from tools/assets.py (ROBLOX_API_KEY, else
~/RobloxProjects/.roblox-api-key) and is never printed. The live place is never launched or messaged."""
import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import time
import urllib.parse
import uuid

TOOLS = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(TOOLS)
sys.path.insert(0, TOOLS)

import assets  # noqa: E402  (key + HTTP with 429 retries)
import studio_window  # noqa: E402  (swift helper compile cache, caller_id)

LIVE_TARGET = os.path.join(ROOT, "deploy", "target.json")
TEST_TARGET = os.path.join(ROOT, "deploy", "test-target.json")
TEST_ENV_LUAU = os.path.join(ROOT, "src", "shared", "TestEnv.luau")
LIVE_PLACE_ID = 97313994892728
LIVE_UNIVERSE_ID = 10769596890
OWNER_USER_ID = 11718681576
TOPIC = "TestBridge"
MAP = "TestBridge"
LOCK_DIR = os.environ.get("ROBLOX_PLAY_LOCK", "/tmp/roblox-player.lock")
LOCK_STALE = 20 * 60
PLAYER_BUNDLE = "com.roblox.RobloxPlayer"
NOT_CONFIGURED = ("test experience not configured yet: universeId/placeId in deploy/test-target.json are null "
                  "(create the private test experience, fill them in and set TEST_UNIVERSE_ID in "
                  "src/shared/TestEnv.luau)")


def die(msg, code=1):
    print(msg, file=sys.stderr)
    sys.exit(code)


# -- target -------------------------------------------------------------------------------------------------------
def test_target():
    """(universeId, placeId) of the TEST experience; exits when not configured or when it points at the live game."""
    try:
        with open(TEST_TARGET) as f:
            t = json.load(f)
    except (OSError, ValueError):
        die(NOT_CONFIGURED)
    u, p = t.get("universeId"), t.get("placeId")
    if not u or not p:
        die(NOT_CONFIGURED)
    u, p = int(u), int(p)
    live_u, live_p = LIVE_UNIVERSE_ID, LIVE_PLACE_ID
    try:
        with open(LIVE_TARGET) as f:
            lt = json.load(f)
        live_u, live_p = int(lt.get("universeId") or live_u), int(lt.get("placeId") or live_p)
    except (OSError, ValueError):
        pass
    if u in (live_u, LIVE_UNIVERSE_ID) or p in (live_p, LIVE_PLACE_ID):
        die("deploy/test-target.json points at the LIVE game; refusing")
    return u, p


def bridge_universe_in_source():
    """TEST_UNIVERSE_ID as written in src/shared/TestEnv.luau (0 = bridge inert everywhere)."""
    try:
        with open(TEST_ENV_LUAU) as f:
            m = re.search(r"TEST_UNIVERSE_ID\s*=\s*(\d+)", f.read())
        return int(m.group(1)) if m else 0
    except OSError:
        return 0


def warn_bridge_mismatch(u):
    src = bridge_universe_in_source()
    if src != u:
        print(f"warning: src/shared/TestEnv.luau TEST_UNIVERSE_ID = {src}, test universe = {u}: the published build's "
              "bridge only answers if it was built with the right id", file=sys.stderr)


# -- lock ---------------------------------------------------------------------------------------------------------
def owner_id(explicit=None):
    return explicit or os.environ.get("ROBLOX_PLAY_OWNER") or studio_window.caller_id()


def _info_path():
    return os.path.join(LOCK_DIR, "owner.json")


def lock_info():
    try:
        with open(_info_path()) as f:
            info = json.load(f)
        info["idle"] = int(time.time() - os.path.getmtime(_info_path()))
        return info
    except (OSError, ValueError):
        if os.path.isdir(LOCK_DIR):
            # mkdir'd but owner.json not written yet (or lost): age of the dir itself
            return {"owner": "?", "idle": int(time.time() - os.path.getmtime(LOCK_DIR))}
        return None


def _write_info(info):
    tmp = _info_path() + ".%d.tmp" % os.getpid()
    with open(tmp, "w") as f:
        json.dump(info, f)
    os.replace(tmp, _info_path())


def touch_lock(**extra):
    info = lock_info() or {}
    info.pop("idle", None)
    info.update(extra)
    _write_info(info)


def acquire(owner, wait=0):
    deadline = time.time() + wait
    while True:
        try:
            os.mkdir(LOCK_DIR)
            _write_info({"owner": owner, "since": int(time.time()), "pid": os.getpid()})
            return True
        except FileExistsError:
            info = lock_info() or {}
            if info.get("owner") == owner:
                touch_lock()
                return True
            if info.get("idle", 0) > LOCK_STALE:
                print(f"taking stale player lock from {info.get('owner')} (idle {info['idle']} s)", file=sys.stderr)
                shutil.rmtree(LOCK_DIR, ignore_errors=True)
                continue
            if time.time() >= deadline:
                die(f"Roblox Player lock held by {info.get('owner')} (idle {info.get('idle')} s); "
                    "retry later or pass --wait SEC", 75)
            time.sleep(5)


def require_lock(owner):
    info = lock_info()
    if not info or info.get("owner") != owner:
        die(f"you do not hold the Roblox Player lock (holder: {info and info.get('owner')}); run `join` "
            "or `lock acquire` first", 75)
    touch_lock()


def release(owner, force=False):
    info = lock_info()
    if not info:
        return False
    if info.get("owner") != owner and not force:
        die(f"lock held by {info.get('owner')}, not you; `lock release --force` breaks it")
    shutil.rmtree(LOCK_DIR, ignore_errors=True)
    return True


# -- bridge -------------------------------------------------------------------------------------------------------
def publish(u, payload):
    body = json.dumps({"topic": TOPIC, "message": json.dumps(payload, separators=(",", ":"))}).encode()
    status, raw = assets._http("POST", f"/cloud/v2/universes/{u}:publishMessage", body, "application/json", timeout=30)
    if status != 200:
        die(f"publishMessage failed: HTTP {status} {raw[:300].decode('utf-8', 'replace')}")


def read_result(u, item_id):
    status, raw = assets._http("GET", f"/cloud/v2/universes/{u}/memory-store/sorted-maps/{MAP}/items/"
                                      f"{urllib.parse.quote(item_id)}", timeout=30)
    if status == 404:
        return None
    if status != 200:
        die(f"memory store read failed: HTTP {status} {raw[:300].decode('utf-8', 'replace')}")
    value = json.loads(raw).get("value")
    if isinstance(value, str):
        try:
            value = json.loads(value)
        except ValueError:
            pass
    return value


def bridge(u, name, args=None, user=None, timeout=20.0, quiet_timeout=False):
    """Publishes one command and waits for its result dict ({ok, result|error, jobId, placeVersion, at}).
    None when nobody answered within `timeout` (target player in no server)."""
    item_id = uuid.uuid4().hex
    msg = {"id": item_id, "cmd": name, "args": args or {}}
    if user:
        msg["userId"] = int(user)
    publish(u, msg)
    deadline = time.time() + timeout
    delay = 0.4
    while time.time() < deadline:
        time.sleep(delay)
        delay = min(delay * 1.4, 2.0)
        res = read_result(u, item_id)
        if res is not None:
            return res
    if not quiet_timeout:
        print(f"no answer to `{name}` in {timeout:.0f} s: is user {user or OWNER_USER_ID} in a TEST server, and was "
              "the build published with TEST_UNIVERSE_ID set?", file=sys.stderr)
    return None


# -- window -------------------------------------------------------------------------------------------------------
def helper(*args, timeout=60):
    return subprocess.run(studio_window.helper("roblox-player") + [str(a) for a in args], capture_output=True,
                          text=True, timeout=timeout)


def player_windows():
    r = helper("windows")
    if r.returncode != 0:
        die("roblox-player windows failed: " + (r.stdout + r.stderr).strip())
    return json.loads(r.stdout or "[]")


def main_window():
    """The Roblox Player's largest on-screen window (the game/home view), or None."""
    wins = [w for w in player_windows() if w.get("onscreen") and w["w"] >= 200 and w["h"] >= 150]
    return max(wins, key=lambda w: w["w"] * w["h"]) if wins else None


def player_running():
    return subprocess.run(["pgrep", "-x", "RobloxPlayer"], capture_output=True).returncode == 0


# -- commands -----------------------------------------------------------------------------------------------------
def cmd_join(a):
    if a.target != "test":
        die("refusing: agents only ever join the TEST experience (--target test)")
    u, p = test_target()
    warn_bridge_mismatch(u)
    owner = owner_id(a.owner)
    acquire(owner, a.wait)
    print(f"launching Roblox Player into test place {p} (universe {u})")
    link = f"roblox://experiences/start?placeId={p}"
    deadline = time.time() + a.timeout
    # A cold-started Player drops the deep link and opens its home screen (seen 2026-10-16), so start the app
    # first, wait for its window, then hand it the link; re-send the link every 60 s until the bridge answers.
    if not player_running():
        subprocess.run(["open", "-a", "/Applications/Roblox.app"], check=True)
    while time.time() < deadline and not main_window():
        time.sleep(2)
    win = main_window()
    if not win:
        die("the Roblox Player window never appeared")
    print(f"window {win['id']} {int(win['w'])}x{int(win['h'])}")
    time.sleep(3)
    sent = 0.0
    while time.time() < deadline:
        if time.time() - sent >= 60:
            subprocess.run(["open", link], check=True)
            sent = time.time()
        res = bridge(u, "ping", user=a.user, timeout=8, quiet_timeout=True)
        if res and res.get("ok") and int(res["result"].get("userId", 0)) == int(a.user or OWNER_USER_ID):
            touch_lock(jobId=res.get("jobId"), placeVersion=res.get("placeVersion"))
            print(json.dumps({"jobId": res.get("jobId"), "placeVersion": res.get("placeVersion"),
                              "loaded": res["result"].get("loaded"), "players": res["result"].get("players")}))
            return
        touch_lock()
    die(f"joined window but no bridge ping answer in {a.timeout} s (still loading? bridge inert?)")


def cmd_cmd(a):
    u, _ = test_target()
    require_lock(owner_id(a.owner))
    try:
        args = json.loads(a.args) if a.args else {}
    except ValueError as e:
        die(f"args must be JSON: {e}")
    if not isinstance(args, dict):
        die("args must be a JSON object")
    res = bridge(u, a.name, args, user=a.user, timeout=a.timeout)
    if res is None:
        sys.exit(1)
    print(json.dumps(res, indent=1))
    sys.exit(0 if res.get("ok") else 1)


def cmd_shot(a):
    require_lock(owner_id(a.owner))
    win = main_window()
    if not win:
        die("no Roblox Player window on screen")
    out = os.path.abspath(a.out)
    os.makedirs(os.path.dirname(out), exist_ok=True)
    if not studio_window.capture(win["id"], out):
        die("screencapture failed (Screen Recording permission? window minimised?)")
    dims = subprocess.run(["sips", "-g", "pixelWidth", "-g", "pixelHeight", out], capture_output=True, text=True).stdout
    w = int(re.search(r"pixelWidth: (\d+)", dims).group(1))
    h = int(re.search(r"pixelHeight: (\d+)", dims).group(1))
    if a.scale and 0 < a.scale < 1:
        side = max(1, int(max(w, h) * a.scale))
        subprocess.run(["sips", "-Z", str(side), out], capture_output=True, check=True)
        w, h = round(w * a.scale), round(h * a.scale)
    print(f"{out} {w}x{h}")


def _pid():
    win = main_window()
    if not win:
        die("no Roblox Player window on screen")
    return win["pid"]


def cmd_key(a):
    require_lock(owner_id(a.owner))
    r = helper("key", _pid(), *a.steps, timeout=120)
    if r.returncode != 0:
        die("key failed: " + r.stdout.strip(), r.returncode)


def cmd_click(a):
    require_lock(owner_id(a.owner))
    r = helper("click", _pid(), a.x, a.y)
    if r.returncode != 0:
        die("click failed: " + r.stdout.strip(), r.returncode)


def cmd_quit(a):
    owner = owner_id(a.owner)
    info = lock_info()
    if info and info.get("owner") != owner and not a.force:
        die(f"lock held by {info.get('owner')}: not quitting their Roblox Player (--force to override)")
    if player_running():
        subprocess.run(["osascript", "-e", f'tell application id "{PLAYER_BUNDLE}" to quit'], capture_output=True,
                       timeout=30)
        for _ in range(20):
            if not player_running():
                break
            time.sleep(0.5)
        if player_running():
            subprocess.run(["pkill", "-x", "RobloxPlayer"], capture_output=True)
    print("Roblox Player closed")
    if not a.keep_lock and release(owner, force=a.force):
        print("lock released")


def cmd_lock(a):
    owner = owner_id(a.owner)
    if a.action == "status":
        info = lock_info()
        print(json.dumps({"held": bool(info), **(info or {}), "you": owner, "playerRunning": player_running()}))
    elif a.action == "acquire":
        acquire(owner, a.wait)
        print(f"lock held by {owner}")
    elif a.action == "release":
        print("lock released" if release(owner, force=a.force) else "lock was free")


def cmd_windows(_a):
    print(json.dumps(player_windows(), indent=1))


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--owner", help="lock owner id (default $ROBLOX_PLAY_OWNER or the git worktree)")
    sub = ap.add_subparsers(dest="sub", required=True)

    j = sub.add_parser("join")
    j.add_argument("--target", default="test")
    j.add_argument("--user", type=int, default=None, help=f"userId expected in the ping (default {OWNER_USER_ID})")
    j.add_argument("--timeout", type=float, default=180)
    j.add_argument("--wait", type=float, default=0, help="seconds to wait for the player lock")
    j.set_defaults(fn=cmd_join)

    c = sub.add_parser("cmd")
    c.add_argument("name")
    c.add_argument("args", nargs="?", default="")
    c.add_argument("--user", type=int, default=None)
    c.add_argument("--timeout", type=float, default=20)
    c.set_defaults(fn=cmd_cmd)

    s = sub.add_parser("shot")
    s.add_argument("out")
    s.add_argument("--scale", type=float, default=0.5)
    s.set_defaults(fn=cmd_shot)

    k = sub.add_parser("key")
    k.add_argument("steps", nargs="+")
    k.set_defaults(fn=cmd_key)

    cl = sub.add_parser("click")
    cl.add_argument("x", type=float)
    cl.add_argument("y", type=float)
    cl.set_defaults(fn=cmd_click)

    q = sub.add_parser("quit")
    q.add_argument("--keep-lock", action="store_true")
    q.add_argument("--force", action="store_true")
    q.set_defaults(fn=cmd_quit)

    lk = sub.add_parser("lock")
    lk.add_argument("action", choices=["status", "acquire", "release"])
    lk.add_argument("--wait", type=float, default=0)
    lk.add_argument("--force", action="store_true")
    lk.set_defaults(fn=cmd_lock)

    w = sub.add_parser("windows")
    w.set_defaults(fn=cmd_windows)

    a = ap.parse_args(argv)
    a.fn(a)


if __name__ == "__main__":
    main()
