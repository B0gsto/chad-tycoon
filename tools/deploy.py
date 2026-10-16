#!/usr/bin/env python3
"""Publish Chad Aura Tycoon to its Roblox place through Open Cloud.

usage:
  tools/deploy.py check   [--target live|test] [--file PATH] [--offline]
  tools/deploy.py publish [--target live|test] [--file PATH] [--saved] [--force]
  tools/deploy.py server-size [--target live|test] [N]
  tools/deploy.py restart-servers [--target live|test] [--all-versions] [--yes]

--target  live (default; deploy/target.json, the PUBLIC game) or test (deploy/test-target.json, the private test
          experience; publishes are logged in the git-ignored deploy/test-history.json). The environment variable
          DEPLOY_TARGET sets the default. While the test experience's universeId/placeId are null every --target test
          command prints "test experience not configured yet" and exits 0.

check    read-only pre-flight: the API key ($ROBLOX_API_KEY, else the key file: exists, not empty, mode 600/400,
         git-ignored when inside the repo),
         deploy/target.json, the place file (header, size, age, parsed with Lune: ReplicatedStorage.AssetModels holds
         one model per assets/models/*.rbxm, no classes the publish API rejects) and, unless --offline, what the key
         can read on Roblox (universe + place, including the place's serverSize = Max Players). Nothing on Roblox is
         changed. Exit 0 = no hard problem (warnings allowed), 1 = a hard problem.
         Open Cloud has no read-only call that proves the universe-places:write permission: only a publish does.
publish  uploads the place file as a new version of deploy/target.json's place:
           POST /universes/v1/{universeId}/places/{placeId}/versions?versionType=Published   (live for new servers)
           --saved uses versionType=Saved instead (stored in version history, does not go live).
         Content-Type is application/octet-stream for .rbxl and application/xml for .rbxlx. The new version number,
         a UTC timestamp, the file's sha256 and size are appended to deploy/history.json.
         Refuses a file older than 30 minutes (stale build) or one the API would reject, unless --force.
         The last line printed is VERSION=<n> (machine-readable, for CI).
server-size  prints the place's Max Players (Open Cloud Place resource field serverSize):
           GET   /cloud/v2/universes/{universeId}/places/{placeId}                        (no extra scope)
         with N, sets it when it differs and reads it back (idempotent; same value = no request):
           PATCH /cloud/v2/universes/{universeId}/places/{placeId}?updateMask=serverSize  (scope universe.place:write)
restart-servers  restarts the universe's running servers so they pick up the latest Published version:
           POST  /cloud/v2/universes/{universeId}:restartServers   (scope universe:write)
         By default only servers on an older version restart; --all-versions sets closeAllVersions.
         --target live (players get moved) is refused without --yes.

Default file: build/ChadAuraTycoon.rbxl (scripts/build-release.sh), falling back to build/ChadAuraTycoon.rbxlx for
`check` only. The API key comes from the ROBLOX_API_KEY environment variable when set (CI: the repository secret),
else from ~/RobloxProjects/.roblox-api-key (tools/assets.py); it is sent as the x-api-key header and never printed,
and request headers are never printed; errors show the HTTP status and the response body only."""
import argparse, datetime, hashlib, json, os, shutil, stat, subprocess, sys, tempfile, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import assets  # noqa: E402  (shared key path, HTTP with 429 retries, target.json, atomic writes)

ROOT = assets.ROOT
TARGET = os.path.join(ROOT, "deploy", "target.json")
HISTORY = os.path.join(ROOT, "deploy", "history.json")
# --target: (target file, publish log). main() points TARGET/HISTORY at the chosen pair.
TARGETS = {
    "live": (TARGET, HISTORY),
    "test": (os.path.join(ROOT, "deploy", "test-target.json"), os.path.join(ROOT, "deploy", "test-history.json")),
}
TARGET_NAME = "live"
RELEASE = os.path.join(ROOT, "build", "ChadAuraTycoon.rbxl")
XML_BUILD = os.path.join(ROOT, "build", "ChadAuraTycoon.rbxlx")
MODELS = os.path.join(ROOT, "assets", "models")
MAX_AGE_MIN = 30
PLOTS = 6  # PlotLayout: one plot per player
# Not documented for this endpoint; Roblox's general place upload ceiling. Our release file is ~1-2 MB.
SIZE_LIMIT = 100 * 1024 * 1024
# The publish API refuses places that contain these (docs: "publish from Studio after modifying them").
REJECTED = ("PartOperation", "UnionOperation", "NegateOperation", "IntersectOperation", "SurfaceAppearance",
            "EditableImage", "EditableMesh", "WrapLayer", "WrapTarget", "WrapDeformer")

PROBE = r"""
local fs = require("@lune/fs")
local process = require("@lune/process")
local roblox = require("@lune/roblox")
local serde = require("@lune/serde")
local game = roblox.deserializePlace(fs.readFile(process.args[1]))
local counts = {}
for _, d in game:GetDescendants() do
	counts[d.ClassName] = (counts[d.ClassName] or 0) + 1
end
local models = {}
local rs = game:FindFirstChild("ReplicatedStorage")
local am = rs and rs:FindFirstChild("AssetModels")
if am then
	for _, m in am:GetChildren() do
		local meshes = 0
		for _, d in m:GetDescendants() do
			if d:IsA("MeshPart") then meshes += 1 end
		end
		if m:IsA("MeshPart") then meshes += 1 end
		models[m.Name] = meshes
	end
end
local services = {}
for _, s in game:GetChildren() do
	table.insert(services, s.ClassName)
end
print(serde.encode("json", { counts = counts, assetModels = if am then models else nil, services = services }))
"""


class Report:
    def __init__(self):
        self.hard = 0

    def line(self, level, what, detail=""):
        if level == "FAIL":
            self.hard += 1
        print(f"  {level:<4} {what}" + (f": {detail}" if detail else ""), flush=True)


class NotConfigured(Exception):
    """The test experience exists in deploy/test-target.json but its universeId/placeId are still null."""


NOT_CONFIGURED = ("test experience not configured yet: universeId/placeId in deploy/test-target.json are null "
                  "(create the private test experience, fill them in; docs/testing-on-roblox.md)")


def load_target():
    with open(TARGET) as f:
        t = json.load(f)
    if TARGET_NAME != "live" and (t.get("universeId") is None or t.get("placeId") is None):
        raise NotConfigured(NOT_CONFIGURED)
    u, p = int(t["universeId"]), int(t["placeId"])
    if u <= 0 or p <= 0:
        raise ValueError("universeId/placeId must be positive")
    return t, u, p


def default_file(for_check):
    if os.path.exists(RELEASE) or not for_check:
        return RELEASE
    return XML_BUILD


def content_type(path):
    ext = os.path.splitext(path)[1].lower()
    if ext == ".rbxl":
        return "application/octet-stream"
    if ext == ".rbxlx":
        return "application/xml"
    raise SystemExit(f"{path}: not a .rbxl or .rbxlx file")


def header_ok(path):
    with open(path, "rb") as f:
        head = f.read(64)
    if path.lower().endswith(".rbxl"):
        return head.startswith(assets.RBXM_MAGIC)
    return head.lstrip().startswith(b"<roblox") and b'version="4"' in head


def shown(path):
    path = os.path.abspath(path)
    return os.path.relpath(path, ROOT) if path.startswith(ROOT + os.sep) else path


def age_minutes(path):
    return (time.time() - os.path.getmtime(path)) / 60


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def probe(path):
    """Parse the place with Lune's roblox library. Returns the probe dict, or raises RuntimeError."""
    if not shutil.which("lune"):
        raise RuntimeError("lune is not on PATH (rokit install)")
    with tempfile.TemporaryDirectory(prefix="deploy-probe-") as d:
        script = os.path.join(d, "probe.luau")
        with open(script, "w") as f:
            f.write(PROBE)
        r = subprocess.run(["lune", "run", script, os.path.abspath(path)], capture_output=True, text=True, timeout=300)
    if r.returncode != 0:
        raise RuntimeError((r.stderr or r.stdout).strip()[-600:])
    return json.loads(r.stdout.strip().splitlines()[-1])


def place_problems(info):
    """(rejected-class findings, asset-model findings) of a probe result."""
    rejected = {c: info["counts"][c] for c in REJECTED if info["counts"].get(c)}
    expected = sorted(os.path.splitext(n)[0] for n in os.listdir(MODELS) if n.endswith(".rbxm"))
    models = info.get("assetModels")
    if models is None:
        return rejected, ["ReplicatedStorage.AssetModels is missing"], expected
    missing = [n for n in expected if n not in models]
    empty = [n for n in expected if n in models and models[n] == 0]
    issues = ([f"missing {', '.join(missing)}"] if missing else []) + ([f"no MeshPart in {', '.join(empty)}"] if empty else [])
    return rejected, issues, expected


def api_get(path):
    status, raw = assets._http("GET", path, timeout=30)
    text = raw.decode(errors="replace") if isinstance(raw, bytes) else str(raw)
    try:
        body = json.loads(text) if text[:1] in ("{", "[") else text
    except ValueError:
        body = text
    return status, body


# ------------------------------------------------------------------------------------------------------------ check
def check_key(rep):
    if assets.key_source() == f"${assets.KEY_ENV}":
        n = len(os.environ[assets.KEY_ENV].strip())
        if n < 20:
            rep.line("FAIL", "API key", f"${assets.KEY_ENV} is too short to be an Open Cloud key")
            return False
        rep.line("OK", "API key", f"from ${assets.KEY_ENV} (contents not shown)")
        return True
    path = assets.KEY_PATH
    if not os.path.isfile(path):
        rep.line("FAIL", "API key file", f"{path} does not exist and ${assets.KEY_ENV} is not set")
        return False
    mode = stat.S_IMODE(os.stat(path).st_mode)
    if mode & 0o077:
        rep.line("FAIL", "API key file mode", f"{oct(mode)[2:]} lets other accounts read it; run chmod 600 {path}")
    else:
        rep.line("OK", "API key file", f"{path} (mode {oct(mode)[2:]}, contents not shown)")
    with open(path) as f:
        n = len(f.read().strip())
    if n < 20:
        rep.line("FAIL", "API key contents", "empty or too short to be an Open Cloud key")
        return False
    if os.path.realpath(path).startswith(ROOT + os.sep):
        r = subprocess.run(["git", "-C", ROOT, "check-ignore", "-q", path])
        if r.returncode != 0:
            rep.line("FAIL", "API key git-ignored", f"{path} is inside the repo and not ignored")
    return True


def check_file(rep, path, require_fresh):
    if not os.path.isfile(path):
        rep.line("FAIL", "place file", f"{shown(path)} does not exist; run scripts/build-release.sh")
        return
    rel, size, age = shown(path), os.path.getsize(path), age_minutes(path)
    if not header_ok(path):
        rep.line("FAIL", "place file header", f"{rel} is not a Roblox place file")
        return
    rep.line("OK", "place file", f"{rel}, {size / 1e6:.2f} MB ({content_type(path)}), sha256 {sha256(path)[:12]}")
    if size > SIZE_LIMIT:
        rep.line("FAIL", "place file size", f"{size / 1e6:.1f} MB is over the 100 MB place upload limit")
    if not path.lower().endswith(".rbxl"):
        rep.line("WARN", "release format", "this is the XML build; publish the binary build/ChadAuraTycoon.rbxl "
                 "from scripts/build-release.sh (about 2.6x smaller)")
    if age > MAX_AGE_MIN:
        rep.line("FAIL" if require_fresh else "WARN", "build age",
                 f"built {age:.0f} min ago; publish refuses builds older than {MAX_AGE_MIN} min without --force")
    else:
        rep.line("OK", "build age", f"built {age:.0f} min ago")
    try:
        info = probe(path)
    except (RuntimeError, ValueError, subprocess.TimeoutExpired) as e:
        rep.line("FAIL", "place parses (Lune)", str(e))
        return
    rejected, issues, expected = place_problems(info)
    meshes = sum((info.get("assetModels") or {}).values())
    if issues:
        rep.line("FAIL", "ReplicatedStorage.AssetModels", "; ".join(issues))
    else:
        rep.line("OK", "ReplicatedStorage.AssetModels", f"{len(expected)} models (all assets/models/*.rbxm), {meshes} MeshParts")
    if rejected:
        rep.line("FAIL", "publishable by API", "contains " + ", ".join(f"{k} x{v}" for k, v in rejected.items())
                 + " (Open Cloud refuses these; publish from Studio)")
    else:
        rep.line("OK", "publishable by API", "no unions, SurfaceAppearance, Editable* or wrap instances")


def check_online(rep, u, p):
    status, body = api_get(f"/cloud/v2/universes/{u}")
    if status == 200 and isinstance(body, dict):
        rep.line("OK", "key can read the universe", f"{u} '{body.get('displayName')}', visibility {body.get('visibility')}")
        if body.get("ageRating") in (None, "", "AGE_RATING_UNSPECIFIED"):
            rep.line("WARN", "maturity rating", "ageRating unspecified: fill in the Maturity & Compliance questionnaire "
                     "(declare paid random items)")
    elif status == 404:
        rep.line("FAIL", "universe", f"{u} does not exist (HTTP 404): fix {shown(TARGET)}")
    elif status in (401, 403):
        rep.line("WARN", "key can read the universe", f"HTTP {status}: {str(body)[:200]}")
    else:
        rep.line("WARN", "universe read", f"HTTP {status}: {str(body)[:200]}")
    status, body = api_get(f"/cloud/v2/universes/{u}/places/{p}")
    if status == 200 and isinstance(body, dict):
        size = body.get("serverSize")
        rep.line("OK", "key can read the place", f"{p} '{body.get('displayName')}', root={body.get('root')}")
        if body.get("root") is False:
            rep.line("WARN", "start place", f"{p} is not the start place of universe {u}")
        if size is None:
            rep.line("WARN", "Max Players", "serverSize not returned")
        elif int(size) > PLOTS:
            rep.line("WARN", "Max Players", f"serverSize {size} > {PLOTS} plots: players beyond {PLOTS} are kicked "
                     f"('This server is full'). Run: python3 tools/deploy.py server-size {PLOTS}")
        else:
            rep.line("OK", "Max Players", f"serverSize {size} (game has {PLOTS} plots)")
    elif status == 404:
        rep.line("FAIL", "place", f"{p} is not in universe {u} (HTTP 404): fix {shown(TARGET)}")
    elif status in (401, 403):
        rep.line("WARN", "key can read the place", f"HTTP {status}: {str(body)[:200]} (read scope missing or the "
                 "experience is not added to the key; says nothing about write)")
    else:
        rep.line("WARN", "place read", f"HTTP {status}: {str(body)[:200]}")
    rep.line("INFO", "publish permission", "universe-places:write cannot be proven read-only; the first publish "
             "(or a --saved publish) confirms it. 401/403 there = add the experience to the key's universe-places write scope")


def cmd_check(a):
    rep = Report()
    print("deploy check (read-only, nothing on Roblox is changed)" + ("" if TARGET_NAME == "live" else f" [target {TARGET_NAME}]"))
    key_ok = check_key(rep)
    try:
        t, u, p = load_target()
        rep.line("OK", shown(TARGET), f"'{t.get('name')}' universe {u}, place {p}, creator "
                 f"{(t.get('creator') or {}).get('type')} {(t.get('creator') or {}).get('id')}")
    except NotConfigured as e:
        rep.line("INFO", shown(TARGET), str(e))
        u = p = None
    except (OSError, ValueError, KeyError, TypeError) as e:
        rep.line("FAIL", shown(TARGET), str(e))
        u = p = None
    check_file(rep, a.file or default_file(True), require_fresh=False)
    if a.offline:
        rep.line("INFO", "online checks", "skipped (--offline)")
    elif key_ok and u:
        try:
            check_online(rep, u, p)
        except OSError as e:
            rep.line("WARN", "online checks", f"network error {e}")
    print(f"result: {'FAIL' if rep.hard else 'OK'} ({rep.hard} hard problem(s))")
    return 1 if rep.hard else 0


# ---------------------------------------------------------------------------------------------------------- publish
def git_head():
    r = subprocess.run(["git", "-C", ROOT, "rev-parse", "--short", "HEAD"], capture_output=True, text=True)
    # build/ holds outputs (the tracked .rbxlx is rebuilt by every check), so it does not make the source dirty
    dirty = subprocess.run(["git", "-C", ROOT, "status", "--porcelain", "--", ".", ":!build"],
                           capture_output=True, text=True).stdout.strip()
    return (r.stdout.strip() or "unknown") + ("+dirty" if dirty else "")


def record(entry):
    with assets.file_lock(assets.sidecar_lock(HISTORY)):
        try:
            with open(HISTORY) as f:
                hist = json.load(f)
        except (OSError, ValueError):
            hist = []
        hist.append(entry)
        assets.atomic_write(HISTORY, (json.dumps(hist, indent=2) + "\n").encode())


def cmd_publish(a):
    path = os.path.abspath(a.file or default_file(False))
    vtype = "Saved" if a.saved else "Published"
    if not configured():
        return 0
    if not os.path.isfile(path):
        raise SystemExit(f"{path} does not exist; run scripts/build-release.sh")
    ctype = content_type(path)
    if not assets.key_source():
        raise SystemExit(f"no Roblox API key: set ${assets.KEY_ENV} or create {assets.KEY_PATH}")
    _, u, p = load_target()
    if not header_ok(path):
        raise SystemExit(f"{path} is not a Roblox place file")
    age = age_minutes(path)
    if age > MAX_AGE_MIN and not a.force:
        raise SystemExit(f"refusing: {shown(path)} was built {age:.0f} min ago (> {MAX_AGE_MIN}). "
                         "Run scripts/build-release.sh, or pass --force")
    try:
        rejected, issues, _ = place_problems(probe(path))
    except (RuntimeError, ValueError, subprocess.TimeoutExpired) as e:
        rejected, issues = {}, [f"could not parse the place: {e}"]
    if (rejected or issues) and not a.force:
        raise SystemExit("refusing: " + "; ".join(issues + [f"contains {k} x{v}" for k, v in rejected.items()]))
    digest, size = sha256(path), os.path.getsize(path)
    with open(path, "rb") as f:
        data = f.read()
    print(f"publishing {shown(path)} ({size / 1e6:.2f} MB, sha256 {digest[:12]}) "
          f"to universe {u} place {p} as versionType={vtype}" + ("" if TARGET_NAME == "live" else f" [target {TARGET_NAME}]"),
          flush=True)
    url = f"/universes/v1/{u}/places/{p}/versions?versionType={vtype}"
    try:
        status, raw = assets._http("POST", url, data, ctype, timeout=600)
    except OSError as e:
        raise SystemExit(f"network error ({e}); the upload may still have gone through: check the place's version "
                         "history in the Creator Dashboard before retrying")
    text = raw.decode(errors="replace") if isinstance(raw, bytes) else str(raw)
    if status != 200:
        hint = " (the version may still have been created: check version history before retrying)" if status >= 500 else ""
        raise SystemExit(f"publish failed: HTTP {status}: {text[:2000]}{hint}")
    try:
        version = json.loads(text)["versionNumber"]
    except (ValueError, KeyError, TypeError):
        raise SystemExit(f"published (HTTP 200) but the response has no versionNumber: {text[:500]}")
    record({
        "versionNumber": version,
        "versionType": vtype,
        "publishedAt": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "universeId": u,
        "placeId": p,
        "file": shown(path),
        "bytes": size,
        "sha256": digest,
        "builtAt": datetime.datetime.fromtimestamp(os.path.getmtime(path), datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "git": git_head(),
        "forced": bool(a.force),
    })
    print(f"{vtype} place version {version}" + (" (live for new servers)" if vtype == "Published" else " (not live)"))
    print(f"recorded in {shown(HISTORY)}")
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a") as f:
            f.write(f"### {vtype} version {version} of place {p} from `{git_head()}`"
                    + ("" if TARGET_NAME == "live" else f" ({TARGET_NAME} experience)") + "\n")
    print(f"VERSION={version}", flush=True)
    return 0


# ------------------------------------------------------------------------------------------------------ server-size
MAX_SERVER_SIZE = 700  # Roblox's ceiling for Max Players


def read_server_size(u, p):
    status, body = api_get(f"/cloud/v2/universes/{u}/places/{p}")
    if status != 200 or not isinstance(body, dict):
        raise SystemExit(f"reading place {p} failed: HTTP {status}: {str(body)[:500]}")
    size = body.get("serverSize")
    if size is None:
        raise SystemExit(f"place {p}: the response has no serverSize")
    return int(size)


def cmd_server_size(a):
    if not assets.key_source():
        raise SystemExit(f"no Roblox API key: set ${assets.KEY_ENV} or create {assets.KEY_PATH}")
    if not configured():
        return 0
    _, u, p = load_target()
    current = read_server_size(u, p)
    print(f"place {p} (universe {u}): serverSize (Max Players) = {current}")
    if a.size is None:
        return 0
    if not 1 <= a.size <= MAX_SERVER_SIZE:
        raise SystemExit(f"server size must be 1..{MAX_SERVER_SIZE}, got {a.size}")
    if current == a.size:
        print(f"already {a.size}; nothing changed")
        return 0
    body = json.dumps({"serverSize": a.size}).encode()
    status, raw = assets._http("PATCH", f"/cloud/v2/universes/{u}/places/{p}?updateMask=serverSize", body,
                               "application/json", timeout=60)
    if status != 200:
        text = raw.decode(errors="replace") if isinstance(raw, bytes) else str(raw)
        hint = (" (the key needs the universe.place:write scope for this experience)" if status in (401, 403) else "")
        raise SystemExit(f"setting serverSize failed: HTTP {status}: {text[:1000]}{hint}")
    after = read_server_size(u, p)
    if after != a.size:
        raise SystemExit(f"serverSize reads back as {after}, expected {a.size}")
    print(f"serverSize set {current} -> {after}")
    return 0


# -------------------------------------------------------------------------------------------------- restart-servers
def cmd_restart_servers(a):
    if not configured():
        return 0
    if TARGET_NAME == "live" and not a.yes:
        raise SystemExit("refusing to restart the LIVE game's servers (players get moved): pass --yes if you mean it")
    if not assets.key_source():
        raise SystemExit(f"no Roblox API key: set ${assets.KEY_ENV} or create {assets.KEY_PATH}")
    _, u, _ = load_target()
    req = {"closeAllVersions": True} if a.all_versions else {}
    print(f"restarting servers of universe {u} [target {TARGET_NAME}]"
          + (" (all versions)" if a.all_versions else " (servers on an older version)"), flush=True)
    status, raw = assets._http("POST", f"/cloud/v2/universes/{u}:restartServers", json.dumps(req).encode(),
                               "application/json", timeout=60)
    if status != 200:
        text = raw.decode(errors="replace") if isinstance(raw, bytes) else str(raw)
        hint = " (the key needs the universe:write scope for this experience)" if status in (401, 403) else ""
        raise SystemExit(f"restart-servers failed: HTTP {status}: {text[:1000]}{hint}")
    print("restart requested (HTTP 200)")
    return 0


def configured():
    """False (after printing the notice) when the chosen target's IDs are still null."""
    try:
        load_target()
    except NotConfigured as e:
        print(f"NOTICE: {e}; nothing to do")
        if os.environ.get("GITHUB_ACTIONS"):
            print(f"::notice title=Test experience not configured::{e}")
        return False
    return True


def add_target(parser):
    default = os.environ.get("DEPLOY_TARGET") or "live"
    if default not in TARGETS:
        raise SystemExit(f"DEPLOY_TARGET={default!r}: expected one of {', '.join(TARGETS)}")
    parser.add_argument("--target", choices=sorted(TARGETS), default=default,
                        help="live = deploy/target.json (PUBLIC game, default), test = deploy/test-target.json "
                             "(default from $DEPLOY_TARGET)")


def main():
    global TARGET, HISTORY, TARGET_NAME
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    c = sub.add_parser("check", help="read-only pre-flight")
    c.add_argument("--file", help="place file (default build/ChadAuraTycoon.rbxl, else the .rbxlx)")
    c.add_argument("--offline", action="store_true", help="skip the Open Cloud reads")
    pb = sub.add_parser("publish", help="upload a new place version")
    pb.add_argument("--file", help="place file (default build/ChadAuraTycoon.rbxl)")
    pb.add_argument("--saved", action="store_true", help="versionType=Saved: stored, not live")
    pb.add_argument("--force", action="store_true", help="skip the build-age and place-content guards")
    ss = sub.add_parser("server-size", help="read (or with N, set) the place's Max Players")
    ss.add_argument("size", nargs="?", type=int, help="new Max Players; omitted = read only")
    rs = sub.add_parser("restart-servers", help="restart running servers so they load the latest Published version")
    rs.add_argument("--all-versions", action="store_true", help="closeAllVersions: also restart up-to-date servers")
    rs.add_argument("--yes", action="store_true", help="required for --target live")
    for p in (c, pb, ss, rs):
        add_target(p)
    a = ap.parse_args()
    TARGET_NAME = a.target
    TARGET, HISTORY = TARGETS[a.target]
    return {"check": cmd_check, "publish": cmd_publish, "server-size": cmd_server_size,
            "restart-servers": cmd_restart_servers}[a.cmd](a)


if __name__ == "__main__":
    sys.exit(main())
