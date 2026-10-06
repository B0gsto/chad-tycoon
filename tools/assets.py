#!/usr/bin/env python3
"""Upload local art to Roblox through Open Cloud and keep a content-addressed manifest (Chad Aura Tycoon).

usage:
  tools/assets.py upload <GameDir> <file> [--type Model|Image|Decal|Audio] [--name NAME] [--route R]
  tools/assets.py show <GameDir>
  tools/assets.py download <GameDir> <assetId> --out FILE [--route R]      fetch an uploaded Model as .rbxm
  tools/assets.py refresh <GameDir>         re-read the moderation state of every manifest entry that is not final
  tools/assets.py moderation <assetId>      print the moderation state (Approved | Reviewing | Rejected)
  tools/assets.py creator <GameDir>         print the creator uploads are made as
  tools/assets.py selftest                  offline self-test (mock Open Cloud, forced routes, concurrent manifest writers)

pipeline/upload.py is the normal entry point (art/assets/<domain>.json -> assets/pins.json); this module does the
Open Cloud work for it.

Model uploads (.fbx/.gltf/.glb) are downloaded back as <GameDir>/assets/models/<name>.rbxm: the engine-serialized
.rbxm is the only file that carries MeshPart collision/mass data (PhysicalConfigData), so a Model upload is not finished
until it is downloaded. Images (.png/.jpg) upload as assetType "Image" (entry["imageId"] == assetId). Re-uploading
identical bytes is a no-op: the manifest (<GameDir>/assets/manifest.json) is keyed by "<type>:<sha256>".

Model download routes, tried in this order, each forceable (--route R, env CHAD_ASSET_ROUTE=R, or download(route=R)):
  delivery  Open Cloud asset-delivery-api (scope legacy-asset:manage): JSON {"location": CDN url} then the (gzip) file.
  luau      Open Cloud Luau Execution in the owned place (deploy/target.json universeId + placeId, or CHAD_LUAU_UNIVERSE /
            CHAD_LUAU_PLACE): LoadAssetAsync + SerializationService:SerializeInstancesAsync via binaryOutputUri.
            5 task creations/min per place: paced here.
Both return the same thing (root = the uploaded Model, MeshParts under it); bytes are checked for the rbxm magic and
written atomically.

Shared state: every manifest write is a locked read-merge-write (flock on a sidecar file under /tmp/roblox-locks)
through a unique temp file + os.replace. Callers that also hold the named lock assets.ChadTycoon (tools/locks.py) keep
whole upload runs apart.

The API key is read from the ROBLOX_API_KEY environment variable when set (CI), else from
~/RobloxProjects/.roblox-api-key, and never printed (nor are request headers). The creator comes from
<GameDir>/deploy/target.json ({"creator": {"type": "User"|"Group", "id": ...}}) and falls back to the owner's user id
(FALLBACK_USER_ID) when no target exists."""
import base64, contextlib, fcntl, gzip, hashlib, json, os, sys, tempfile, time, urllib.error, urllib.request, uuid

API = "https://apis.roblox.com"
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
# the key is git-ignored, so a git worktree has none of its own: fall back to the documented machine-wide location
KEY_PATH = next((p for p in (os.path.join(ROOT, ".roblox-api-key"), os.path.expanduser("~/RobloxProjects/.roblox-api-key"))
                 if os.path.isfile(p)), os.path.join(ROOT, ".roblox-api-key"))
FALLBACK_USER_ID = "11718681576"
MIME = {".fbx": "model/fbx", ".gltf": "model/gltf+json", ".glb": "model/gltf-binary",
        ".rbxm": "model/x-rbxm", ".png": "image/png", ".jpg": "image/jpeg", ".jpeg": "image/jpeg",
        ".tga": "image/tga", ".bmp": "image/bmp", ".mp3": "audio/mpeg", ".ogg": "audio/ogg",
        ".wav": "audio/wav", ".flac": "audio/flac"}
DEFAULT_TYPE = {".fbx": "Model", ".gltf": "Model", ".glb": "Model", ".png": "Image",
                ".jpg": "Image", ".jpeg": "Image", ".tga": "Image", ".bmp": "Image", ".mp3": "Audio",
                ".ogg": "Audio", ".wav": "Audio", ".flac": "Audio"}
DOWNLOAD_ROUTES = ("delivery", "luau")
FINAL_MODERATION = ("Approved", "Rejected")
RBXM_MAGIC = b"<roblox!"


KEY_ENV = "ROBLOX_API_KEY"


def key_source():
    """Where the API key comes from: the ROBLOX_API_KEY environment variable when set (CI), else KEY_PATH. None when
    neither exists. Describes the source only; the key itself is never returned here, printed or logged."""
    if os.environ.get(KEY_ENV, "").strip():
        return f"${KEY_ENV}"
    return KEY_PATH if os.path.isfile(KEY_PATH) else None


def _key():
    env = os.environ.get(KEY_ENV, "").strip()
    if env:
        return env
    if not os.path.isfile(KEY_PATH):
        raise SystemExit(f"no Roblox API key: set ${KEY_ENV} or create {KEY_PATH}")
    with open(KEY_PATH) as f:
        return f.read().strip()


def _http(method, url, body=None, ctype=None, auth=True, timeout=180, headers=None):
    hdrs = {"x-api-key": _key()} if auth else {}
    if ctype:
        hdrs["Content-Type"] = ctype
    hdrs.update(headers or {})
    for attempt in range(6):
        req = urllib.request.Request(url if url.startswith("http") else API + url, data=body, method=method, headers=hdrs)
        try:
            with urllib.request.urlopen(req, timeout=timeout) as r:
                return r.status, r.read()
        except urllib.error.HTTPError as e:
            raw = e.read()
            if e.code == 429 or (e.code >= 500 and method == "GET"):
                time.sleep(2 + attempt * 3)
                continue
            return e.code, raw
        except (urllib.error.URLError, TimeoutError):
            if method != "GET" or attempt == 5:
                raise
            time.sleep(2 + attempt * 3)
    return 599, b"retries exhausted"


def _multipart(fields, files):
    b = uuid.uuid4().hex
    out = bytearray()
    for n, v in fields.items():
        out += f'--{b}\r\nContent-Disposition: form-data; name="{n}"\r\n\r\n{v}\r\n'.encode()
    for n, (fn, ct, blob) in files.items():
        out += (f'--{b}\r\nContent-Disposition: form-data; name="{n}"; filename="{fn}"\r\n'
                f"Content-Type: {ct}\r\n\r\n").encode() + blob + b"\r\n"
    out += f"--{b}--\r\n".encode()
    return bytes(out), f"multipart/form-data; boundary={b}"


def _gunzip(raw):
    try:
        return gzip.decompress(raw)
    except OSError:
        return raw


# --------------------------------------------------------------------------------------------- creator / target
def target(game_dir):
    """<GameDir>/deploy/target.json as a dict ({} when the owned place does not exist yet)."""
    try:
        with open(os.path.join(game_dir, "deploy", "target.json")) as f:
            data = json.load(f)
        return data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}


def creator(game_dir):
    """The Open Cloud `creator` object for uploads: {"userId": "..."} or {"groupId": "..."}.
    deploy/target.json wins; the owner's user id is the fallback."""
    t = target(game_dir)
    c = t.get("creator")
    if isinstance(c, dict):
        # {"type": "User"|"Group", "id": "<digits>"} (+ optional userId/groupId)
        ctype, cid = str(c.get("type", "")).lower(), c.get("id")
        if cid and ctype in ("group", "user"):
            return {"groupId" if ctype == "group" else "userId": str(cid)}
        for k in ("groupId", "userId"):
            if c.get(k):
                return {k: str(c[k])}
    ctype, cid = str(t.get("creatorType", "")).lower(), t.get("creatorId")
    if cid and ctype in ("group", "user"):
        return {"groupId" if ctype == "group" else "userId": str(cid)}
    for k in ("groupId", "userId"):
        if t.get(k):
            return {k: str(t[k])}
    return {"userId": FALLBACK_USER_ID}


# --------------------------------------------------------------------------------------------- atomic + locked files
def atomic_write(path, data, mode="wb"):
    """Write through a UNIQUE temp file in the same directory, fsync, os.replace: concurrent writers of the same path
    never share a temp file and a reader sees the old or the new file, never a torn one."""
    d = os.path.dirname(os.path.abspath(path))
    os.makedirs(d, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix="." + os.path.basename(path) + ".", suffix=".tmp", dir=d)
    try:
        os.fchmod(fd, 0o644)  # mkstemp creates 0600; repo files (pins, models) should be normal files
        with os.fdopen(fd, mode) as f:
            f.write(data)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, path)
    except BaseException:
        with contextlib.suppress(OSError):
            os.unlink(tmp)
        raise


@contextlib.contextmanager
def file_lock(path):
    """Exclusive flock on a sidecar lock file (kernel-released when the process dies)."""
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    fd = os.open(path, os.O_RDWR | os.O_CREAT, 0o644)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        yield
    finally:
        with contextlib.suppress(OSError):
            fcntl.flock(fd, fcntl.LOCK_UN)
        os.close(fd)


def sidecar_lock(path):
    """flock file for a shared JSON file, kept under /tmp/roblox-locks (never inside a repo, nothing to ignore or commit)."""
    d = os.environ.get("ROBLOX_LOCKS_DIR", "/tmp/roblox-locks")
    return os.path.join(d, "file-%s-%s.flock" % (os.path.basename(path), hashlib.sha256(os.path.abspath(path).encode()).hexdigest()[:12]))


def _read_json(path):
    try:
        with open(path) as f:
            return json.load(f)
    except FileNotFoundError:
        return {}


class Manifest:
    """assets/manifest.json. `data` is a snapshot; put()/patch()/save() are locked read-merge-writes of the file on disk."""

    def __init__(self, game_dir):
        self.game_dir = os.path.abspath(game_dir)
        self.dir = os.path.join(self.game_dir, "assets")
        self.path = os.path.join(self.dir, "manifest.json")
        self.lock_path = sidecar_lock(self.path)
        os.makedirs(os.path.join(self.dir, "models"), exist_ok=True)
        self.data = _read_json(self.path)
        self._touched = {}

    def _write(self, data):
        atomic_write(self.path, json.dumps(data, indent=1, sort_keys=True), "w")

    def reload(self):
        self.data = _read_json(self.path)

    def put(self, key, entry):
        """Insert or replace one entry without losing what other writers added meanwhile."""
        with file_lock(self.lock_path):
            disk = _read_json(self.path)
            disk[key] = entry
            self._write(disk)
            self.data = disk
        self._touched.pop(key, None)

    def patch(self, key, fn):
        """fn(entry) mutates the CURRENT on-disk entry under the lock (missing key: no-op). Returns the entry."""
        with file_lock(self.lock_path):
            disk = _read_json(self.path)
            entry = disk.get(key)
            if entry is not None:
                fn(entry)
                self._write(disk)
            self.data = disk
        return entry

    def save(self):
        """Merge every entry this object touched (`data[key]` edited in place) into the file. Disk entries this
        object never saw are kept; our entries win for the keys present in our snapshot."""
        with file_lock(self.lock_path):
            disk = _read_json(self.path)
            for k, v in self.data.items():
                disk[k] = v
            self._write(disk)
            self.data = disk


# --------------------------------------------------------------------------------------------- download routes
def _check_rbxm(raw, what):
    if not raw.startswith(RBXM_MAGIC):
        raise RuntimeError(f"{what}: not an rbxm (first bytes {raw[:16]!r})")
    return raw


def _download_delivery(asset_id, game_dir=None):
    s, r = _http("GET", f"/asset-delivery-api/v1/assetId/{asset_id}")
    if s != 200:
        raise RuntimeError(f"asset-delivery {asset_id}: {s} {r[:300]!r}")
    doc = json.loads(r)
    loc = doc.get("location")
    if not loc:  # a missing asset can be HTTP 200 with an errors array
        raise RuntimeError(f"asset-delivery {asset_id}: no location ({str(doc.get('errors', doc))[:300]})")
    s, raw = _http("GET", loc, auth=False)
    if s != 200:
        raise RuntimeError(f"cdn {asset_id}: {s}")
    return _gunzip(raw)


LUAU_DOWNLOAD = r'''
local AssetService = game:GetService("AssetService")
local InsertService = game:GetService("InsertService")
local ok, holder = pcall(function() return AssetService:LoadAssetAsync(%ID%) end)
if not ok or holder == nil then holder = InsertService:LoadAsset(%ID%) end
for _, d in holder:GetDescendants() do
	if d:IsA("PackageLink") then d:Destroy() end
end
local buf = game:GetService("SerializationService"):SerializeInstancesAsync(holder:GetChildren())
return { BinaryOutput = buf, ReturnValues = { buffer.len(buf) } }
'''

_luau_starts = []


def _pace_luau(per_minute=4, clock=time.monotonic, sleep=time.sleep):
    """Luau Execution allows 5 task creations a minute per place: stay at 4."""
    while True:
        now = clock()
        _luau_starts[:] = [t for t in _luau_starts if now - t < 60.0]
        if len(_luau_starts) < per_minute:
            _luau_starts.append(now)
            return
        sleep(60.0 - (now - _luau_starts[0]) + 0.05)


def luau_place(game_dir):
    """(universeId, placeId) of the owned place, or raise with the reason."""
    u, p = os.environ.get("CHAD_LUAU_UNIVERSE"), os.environ.get("CHAD_LUAU_PLACE")
    if not (u and p) and game_dir:
        t = target(game_dir)
        u, p = u or t.get("universeId"), p or t.get("placeId")
    if not (u and p):
        raise RuntimeError("luau route needs the owned place: deploy/target.json with universeId and placeId "
                           "or CHAD_LUAU_UNIVERSE + CHAD_LUAU_PLACE")
    return str(u), str(p)


def _download_luau(asset_id, game_dir=None, timeout=300):
    universe, place = luau_place(game_dir)
    _pace_luau()
    body = json.dumps({"script": LUAU_DOWNLOAD.replace("%ID%", str(int(asset_id))), "timeout": "120s",
                       "enableBinaryOutput": True}).encode()
    s, r = _http("POST", f"/cloud/v2/universes/{universe}/places/{place}/luau-execution-session-tasks", body,
                 "application/json")
    if s != 200:
        raise RuntimeError(f"luau-execution create {asset_id}: {s} {r[:300]!r}")
    task = json.loads(r)
    path, end, doc = task["path"], time.time() + timeout, task
    while doc.get("state") not in ("COMPLETE", "FAILED", "CANCELLED"):
        if time.time() > end:
            raise RuntimeError(f"luau-execution {path}: timed out in state {doc.get('state')}")
        time.sleep(1.5)
        s, r = _http("GET", f"/cloud/v2/{path}")
        if s != 200:
            raise RuntimeError(f"luau-execution poll {path}: {s} {r[:200]!r}")
        doc = json.loads(r)
    if doc.get("state") != "COMPLETE":
        raise RuntimeError(f"luau-execution {path}: {doc.get('state')} {json.dumps(doc.get('error', ''))[:300]}")
    uri = doc.get("binaryOutputUri") or (doc.get("output") or {}).get("binaryOutputUri")
    if not uri:
        raise RuntimeError(f"luau-execution {path}: no binaryOutputUri in {json.dumps(doc)[:300]}")
    s, raw = _http("GET", uri, auth=False)
    if s != 200:
        raise RuntimeError(f"luau-execution output {path}: {s}")
    return _gunzip(raw)


ROUTE_FNS = {"delivery": _download_delivery, "luau": _download_luau}


def routes_from(route=None, env=None):
    """The ordered routes to try. route (or $CHAD_ASSET_ROUTE) names one route, a comma list, or 'auto'/None = all of them."""
    want = route or (env if env is not None else os.environ).get("CHAD_ASSET_ROUTE") or "auto"
    if want == "auto":
        return list(DOWNLOAD_ROUTES)
    names = [w.strip() for w in str(want).split(",") if w.strip()]
    bad = [n for n in names if n not in DOWNLOAD_ROUTES]
    if bad or not names:
        raise ValueError(f"unknown download route {bad or want!r} (routes: {', '.join(DOWNLOAD_ROUTES)}, auto)")
    return names


def download(asset_id, route=None, game_dir=None, log=print):
    """Model bytes (.rbxm). Tries the routes in order (or only the forced one); a forced route never falls back.
    Returns (bytes, route_used)."""
    names = routes_from(route)
    errors = []
    for name in names:
        for attempt in range(3 if name == "delivery" else 1):
            try:
                raw = _check_rbxm(ROUTE_FNS[name](asset_id, game_dir), f"{name} {asset_id}")
                return raw, name
            except Exception as e:  # noqa: BLE001
                errors.append(f"{name}: {e}")
                if attempt < 2 and name == "delivery" and "404" not in str(e):
                    time.sleep(3)  # a fresh upload can need a moment before delivery serves it
                    continue
                break
        if len(names) > 1:
            log(f"download route {name} failed ({errors[-1][:160]}), trying the next")
    raise RuntimeError(f"could not download model {asset_id}: " + " | ".join(errors))


# --------------------------------------------------------------------------------------------- moderation
def moderation_state(asset_id):
    """Approved | Reviewing | Rejected | Unknown (Open Cloud GET assets with readMask=moderationResult)."""
    s, r = _http("GET", f"/assets/v1/assets/{asset_id}?readMask=moderationResult")
    if s != 200:
        return "Unknown"
    return (json.loads(r).get("moderationResult") or {}).get("moderationState") or "Unknown"


def refresh_moderation(m, log=print):
    """Re-read the state of every entry that is not final; returns {key: new state} for the ones that changed."""
    changed = {}
    for key, entry in list(m.data.items()):
        if not isinstance(entry, dict) or not entry.get("assetId") or entry.get("moderation") in FINAL_MODERATION:
            continue
        state = moderation_state(entry["assetId"])
        if state != "Unknown" and state != entry.get("moderation"):
            m.patch(key, lambda e, s=state: e.__setitem__("moderation", s))
            changed[key] = state
            log(f"{entry.get('name', key)}: {state}")
    return changed


# --------------------------------------------------------------------------------------------- upload
def upload(game_dir, path, asset_type=None, name=None, manifest=None, log=print, route=None, models_dir=None):
    """Returns the manifest entry: {assetId, type, name, sha, imageId? (Decal), rbxm? (Model)}.
    route forces one download route for a Model; models_dir (absolute or relative to game_dir) replaces assets/models."""
    m = manifest or Manifest(game_dir)
    m.reload()
    ext = os.path.splitext(path)[1].lower()
    asset_type = asset_type or DEFAULT_TYPE.get(ext)
    if not asset_type:
        raise ValueError(f"cannot infer asset type for {path}")
    name = name or os.path.splitext(os.path.basename(path))[0]
    blob = open(path, "rb").read()
    sha = hashlib.sha256(blob).hexdigest()
    key = f"{asset_type}:{sha}"
    entry = m.data.get(key)
    if entry and entry.get("assetId"):
        # identical bytes already uploaded; make sure derived artifacts exist
        if asset_type == "Model":
            want = _model_rel(m, name, models_dir)
            have = entry.get("rbxm")
            if not (have and os.path.exists(os.path.join(m.game_dir, have))) or (models_dir and have != want):
                fetch_model(m, key, entry, route=route, models_dir=models_dir, log=log)
                entry = m.data[key]
        if entry.get("name") != name and name not in entry.get("aliases", []):
            m.patch(key, lambda e: e.setdefault("aliases", []).append(name))
            entry = m.data[key]
        return entry
    display = name[:50]
    req = {"assetType": asset_type, "displayName": display, "description": f"Chad Aura Tycoon art: {name}",
           "creationContext": {"creator": creator(m.game_dir)}}
    body, ct = _multipart({"request": json.dumps(req)}, {"fileContent": (os.path.basename(path), MIME.get(ext, "application/octet-stream"), blob)})
    s, r = _http("POST", "/assets/v1/assets", body, ct, timeout=300)
    if s != 200:
        raise RuntimeError(f"upload {name}: {s} {r[:400]!r}")
    op = json.loads(r)["path"]
    d = {}
    for i in range(120):
        time.sleep(1.5 if i < 10 else 4)
        s, r = _http("GET", "/assets/v1/" + op)
        if s == 200:
            d = json.loads(r)
            if d.get("done"):
                break
    if not d.get("done"):
        raise RuntimeError(f"upload {name}: operation {op} did not finish")
    if "error" in d:
        raise RuntimeError(f"upload {name}: {d['error']}")
    resp = d["response"]
    entry = {"assetId": resp["assetId"], "type": asset_type, "name": name, "sha": sha,
             "moderation": resp.get("moderationResult", {}).get("moderationState"), "source": os.path.relpath(path, m.game_dir)}
    if asset_type == "Image":
        entry["imageId"] = entry["assetId"]
    m.put(key, entry)  # the id is on disk before anything below can fail
    if asset_type == "Decal":
        _resolve_image(entry)
        m.put(key, entry)
    elif asset_type == "Model":
        fetch_model(m, key, entry, route=route, models_dir=models_dir, log=log)
    log(f"uploaded {asset_type} {name} -> {entry['assetId']}" + (f" (image {entry['imageId']})" if entry.get("imageId") else ""))
    return m.data[key]


def _resolve_image(entry):
    for attempt in range(10):
        try:
            xml = _download_delivery(entry["assetId"]).decode(errors="replace")
            i = xml.find("?id=")
            if i < 0:
                i = xml.find("rbxassetid://")
                start = i + len("rbxassetid://")
            else:
                start = i + 4
            digits = ""
            for ch in xml[start:]:
                if not ch.isdigit():
                    break
                digits += ch
            if digits:
                entry["imageId"] = digits
                return
        except RuntimeError:
            pass
        time.sleep(3)
    raise RuntimeError(f"could not resolve image id for decal {entry['assetId']}")


def _safe(name):
    return "".join(c if c.isalnum() or c in "-_" else "_" for c in name)


def _model_rel(m, name, models_dir=None):
    base = models_dir if models_dir else os.path.join("assets", "models")
    if os.path.isabs(base):
        base = os.path.relpath(base, m.game_dir)
    return os.path.join(base, f"{_safe(name)}.rbxm")


def fetch_model(m, key, entry, route=None, models_dir=None, log=print):
    """Download the Model of manifest entry `key` through the route chain and record entry["rbxm"] and ["route"]."""
    rel = _model_rel(m, entry["name"], models_dir)
    raw, used = download(entry["assetId"], route, m.game_dir, log)
    atomic_write(os.path.join(m.game_dir, rel), raw)

    def set_fields(e):
        e["rbxm"] = rel
        e["route"] = used
    if m.patch(key, set_fields) is None:
        entry.update(rbxm=rel, route=used)
        m.put(key, entry)
    return rel


# --------------------------------------------------------------------------------------------- selftest
def selftest():
    """Offline: a mock Open Cloud replaces _http; covers upload + forced routes + chain fallback + creator + concurrency."""
    import multiprocessing, shutil
    failures = []

    def check(name, cond, detail=""):
        print(("PASS " if cond else "FAIL ") + name + (f"  [{detail}]" if detail and not cond else ""))
        if not cond:
            failures.append(name)

    tmp = tempfile.mkdtemp(prefix="assets-selftest-")
    game = os.path.join(tmp, "Game")
    os.makedirs(os.path.join(game, "assets"))
    rbxm = RBXM_MAGIC + b"\x00" * 40
    calls = []
    state = {"delivery_alive": True, "ops": {}, "n": 0}

    def fake_http(method, url, body=None, ctype=None, auth=True, timeout=180, headers=None):
        calls.append((method, url.split("?")[0]))
        if url.startswith("/assets/v1/assets") and method == "POST":
            state["n"] += 1
            req = json.loads(body.split(b"\r\n\r\n")[1].split(b"\r\n")[0])
            state["last_request"] = req
            state["ops"]["op%d" % state["n"]] = str(1000 + state["n"])
            return 200, json.dumps({"path": "operations/op%d" % state["n"]}).encode()
        if url.startswith("/assets/v1/operations/"):
            oid = url.rsplit("/", 1)[1]
            return 200, json.dumps({"done": True, "response": {"assetId": state["ops"][oid], "moderationResult": {"moderationState": "Reviewing"}}}).encode()
        if url.startswith("/assets/v1/assets/"):
            return 200, json.dumps({"moderationResult": {"moderationState": "Approved"}}).encode()
        if url.startswith("/asset-delivery-api/"):
            if not state["delivery_alive"]:
                return 404, b"gone"
            return 200, json.dumps({"location": "https://cdn.example/x"}).encode()
        if url == "https://cdn.example/x":
            return 200, gzip.compress(rbxm)
        if "luau-execution-session-tasks" in url and method == "POST":
            return 200, json.dumps({"path": "universes/1/places/2/luau-execution-sessions/s/tasks/t", "state": "QUEUED"}).encode()
        if "/luau-execution-sessions/" in url:
            return 200, json.dumps({"state": "COMPLETE", "binaryOutputUri": "https://cdn.example/luau"}).encode()
        if url == "https://cdn.example/luau":
            return 200, rbxm
        return 404, b"?" + url.encode()

    real_http, real_sleep = _http, time.sleep
    globals()["_http"] = fake_http
    time.sleep = lambda s: None
    try:
        # creator resolution
        check("creator falls back to the legacy user", creator(game) == {"userId": FALLBACK_USER_ID})
        os.makedirs(os.path.join(game, "deploy"))
        for doc, want in (({"creator": {"type": "Group", "id": "777"}}, {"groupId": "777"}), ({"creator": {"type": "User", "id": "888"}}, {"userId": "888"}),
                          ({"creator": {"type": "Group", "id": "777", "groupId": "777"}}, {"groupId": "777"}),
                          ({"creator": {"groupId": 77}}, {"groupId": "77"}), ({"creatorType": "User", "creatorId": 5}, {"userId": "5"}),
                          ({"groupId": 9}, {"groupId": "9"}), ({"universeId": 1}, {"userId": FALLBACK_USER_ID})):
            with open(os.path.join(game, "deploy", "target.json"), "w") as f:
                json.dump(doc, f)
            check(f"creator from target.json {doc}", creator(game) == want, creator(game))
        with open(os.path.join(game, "deploy", "target.json"), "w") as f:
            json.dump({"universeId": 1, "placeId": 2, "creator": {"userId": 5}}, f)
        # route parsing
        check("routes auto = all routes in order", routes_from("auto") == ["delivery", "luau"])
        check("routes force one", routes_from("luau") == ["luau"])
        check("routes env force", routes_from(None, {"CHAD_ASSET_ROUTE": "luau"}) == ["luau"])
        try:
            routes_from("nope")
            check("unknown route raises", False)
        except ValueError:
            check("unknown route raises", True)
        # a forced route uses only that route
        for forced in ("delivery", "luau"):
            calls.clear()
            raw, used = download("123", forced, game)
            hit = {"delivery": "asset-delivery-api", "luau": "luau-execution"}[forced]
            other = {"delivery": "luau-execution", "luau": "asset-delivery-api"}[forced]
            check(f"forced {forced} downloads via {forced}", used == forced and raw == rbxm and any(hit in c[1] for c in calls))
            check(f"forced {forced} touches no other route", not any(other in c[1] for c in calls))
        # forced delivery does not fall back when delivery is dead
        state["delivery_alive"] = False
        try:
            download("123", "delivery", game, log=lambda *a: None)
            check("forced dead delivery raises (no fallback)", False)
        except RuntimeError as e:
            check("forced dead delivery raises (no fallback)", "delivery" in str(e) and "luau" not in str(e).lower(), str(e))
        raw, used = download("123", None, game, log=lambda *a: None)
        check("auto chain falls back delivery -> luau", used == "luau")
        state["delivery_alive"] = True
        # upload: 1st uploads, 2nd is a no-op
        fbx = os.path.join(tmp, "Thing.fbx")
        open(fbx, "wb").write(b"fbx-bytes")
        calls.clear()
        e1 = upload(game, fbx, "Model", "Thing", log=lambda *a: None, route="delivery")
        posts = [c for c in calls if c[0] == "POST"]
        check("upload posts once", len(posts) == 1, posts)
        check("upload records the creator from target.json", state["last_request"]["creationContext"]["creator"] == {"userId": "5"})
        check("model downloaded to assets/models", os.path.exists(os.path.join(game, e1["rbxm"])) and e1["route"] == "delivery")
        calls.clear()
        e2 = upload(game, fbx, "Model", "Thing", log=lambda *a: None)
        check("re-upload is a no-op (no network)", not calls and e2["assetId"] == e1["assetId"], calls)
        e3 = upload(game, fbx, "Model", "Thing", log=lambda *a: None, route="luau", models_dir="assets/alt-models")
        check("models_dir redirects the download", e3["rbxm"] == os.path.join("assets", "alt-models", "Thing.rbxm") and os.path.exists(os.path.join(game, e3["rbxm"])) and e3["route"] == "luau", e3)
        # moderation refresh
        m = Manifest(game)
        ch = refresh_moderation(m, log=lambda *a: None)
        check("refresh flips Reviewing to Approved", list(ch.values()) == ["Approved"] and m.data[list(ch)[0]]["moderation"] == "Approved", ch)
    finally:
        globals()["_http"] = real_http
        time.sleep = real_sleep
    # concurrent writers: N processes x K distinct keys, nothing lost, file always valid JSON
    mp = os.path.join(tmp, "Conc")
    os.makedirs(os.path.join(mp, "assets"))
    n_proc, per = 6, 25
    procs = [multiprocessing.Process(target=_selftest_writer, args=(mp, i, per)) for i in range(n_proc)]
    for p in procs:
        p.start()
    for p in procs:
        p.join(120)
    doc = json.load(open(os.path.join(mp, "assets", "manifest.json")))
    check("concurrent writers lose no entries", len(doc) == n_proc * per, len(doc))
    check("no stray temp files left", not [f for f in os.listdir(os.path.join(mp, "assets")) if f.endswith(".tmp")])
    shutil.rmtree(tmp, ignore_errors=True)
    print("SELFTEST " + ("FAILED: " + ", ".join(failures) if failures else "PASSED"))
    return 1 if failures else 0


def _selftest_writer(game_dir, idx, per):
    m = Manifest(game_dir)
    for j in range(per):
        m.put(f"Image:{idx}-{j}", {"assetId": str(idx * 1000 + j), "type": "Image", "name": f"n{idx}_{j}"})
        if j % 5 == 0:
            m.patch(f"Image:{idx}-{j}", lambda e: e.__setitem__("moderation", "Approved"))


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    cmd = sys.argv[1]
    if cmd == "selftest":
        sys.exit(selftest())
    if cmd == "moderation":
        print(moderation_state(sys.argv[2]))
        return
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    game = sys.argv[2]
    args = sys.argv[3:]
    opt = lambda k: args[args.index(k) + 1] if k in args else None  # noqa: E731
    if cmd == "upload":
        print(json.dumps(upload(game, args[0], opt("--type"), opt("--name"), route=opt("--route")), indent=1))
    elif cmd == "show":
        print(json.dumps(Manifest(game).data, indent=1))
    elif cmd == "download":
        raw, used = download(args[0], opt("--route"), game)
        out = opt("--out")
        if not out:
            sys.exit("download needs --out FILE")
        atomic_write(out, raw)
        print(f"{out}: {len(raw)} bytes via {used}")
    elif cmd == "refresh":
        print(json.dumps(refresh_moderation(Manifest(game)), indent=1))
    elif cmd == "creator":
        print(json.dumps(creator(game)))
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()
