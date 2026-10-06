#!/usr/bin/env python3
"""Minimal client for Roblox Studio's built-in MCP server (StudioMCP proxy).

CLI:    tools/studio.py <tool> ['<json args>']      (prints text, saves images as PNG)
Module: with StudioSession() as s: s.call("execute_luau", {...})

Enable in Studio: Assistant > ... > Manage MCP Servers > "Enable Studio as MCP server".
Every tool call needs "studio_id" (see list_roblox_studios)."""
import base64, json, os, re, select, shutil, subprocess, sys, threading, time

PROXY = "/Applications/RobloxStudio.app/Contents/MacOS/StudioMCP"
# Legacy mkdir lock (pre-M0-00). Still held next to the new flock during the transition so that any tool or
# agent still running the old studio_lock keeps excluding us (and vice versa).
LOCK_DIR = os.environ.get("STUDIO_LEGACY_LOCK_DIR", "/tmp/roblox-studio.lock")

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import locks  # noqa: E402  (tools/locks.py, machine-wide flock locks)


class studio_lock:
    """Exclusive use of the single shared Studio instance across agents and games.

    Same API as before (owner, timeout, max_age; `with` or __enter__/__exit__), now on tools/locks.py: an flock on
    /tmp/roblox-locks/studio.flock with FIFO tickets and a 10 s heartbeat (a kill -9'd holder frees it at once),
    plus the legacy mkdir directory /tmp/roblox-studio.lock which is held too and honoured when a holder of the old
    kind owns it. Hold it only while driving Studio (load, play, capture).

    On acquire a per-game normalize hook runs (stop play, Edit mode, restore camera/HUD, console marker, reload the
    build when the previous holder died). Hook resolution: normalize=callable, else $STUDIO_NORMALIZE_HOOK (a .py
    file), else <repo>/<game>/pipeline/bench_normalize.py when the game is known (game=, $ROBLOX_GAME or the cwd).
    The hook module exports normalize(ctx) with ctx = {game, owner, died, previous, waited}; `died` is True when the
    previous holder never released (crashed/killed). Games without a hook are unaffected; $STUDIO_NORMALIZE=0 or
    normalize=False disables it. A failing or hanging (> $STUDIO_NORMALIZE_TIMEOUT, 180 s) hook only warns."""

    def __init__(self, owner="agent", timeout=1800, max_age=900, game=None, priority=0, cap=None,
                 normalize=None, quiet=None):
        self.owner, self.timeout, self.max_age = owner, timeout, max_age
        self.game = game if game is not None else locks.infer_game()
        self.priority, self.cap, self.normalize, self.quiet = priority, cap, normalize, quiet
        self._lock = None
        self._legacy_mine = False
        self.died = False
        self.previous = None

    # -- legacy mkdir lock -------------------------------------------------------------------------------
    def _legacy_owner_text(self):
        try:
            with open(os.path.join(LOCK_DIR, "owner")) as f:
                return f.read().strip()
        except OSError:
            return "unknown holder"

    def _legacy_stale(self):
        text = self._legacy_owner_text()
        m = re.search(r"pid=(\d+)", text)
        try:
            age = time.time() - os.path.getmtime(LOCK_DIR)
        except OSError:
            return False
        if m:
            if not locks.pid_alive(int(m.group(1))):
                return True
            return age > self.max_age * 2  # live but silent for a very long time
        return age > self.max_age  # no pid recorded: the old rule

    def _take_legacy(self, deadline):
        last_msg = 0.0
        while True:
            try:
                os.mkdir(LOCK_DIR)
                with open(os.path.join(LOCK_DIR, "owner"), "w") as f:
                    f.write("%s pid=%d t=%d game=%s" % (self.owner, os.getpid(), int(time.time()), self.game or ""))
                self._legacy_mine = True
                return
            except FileExistsError:
                if self._legacy_stale():
                    self.died = True
                    shutil.rmtree(LOCK_DIR, ignore_errors=True)
                    continue
                if deadline is not None and time.monotonic() >= deadline:
                    raise locks.LockTimeout("Studio lock busy: " + self._legacy_owner_text())
                if time.monotonic() - last_msg > 30:
                    if not self._lock.quiet:
                        sys.stderr.write("[locks] waiting for legacy studio lock held by %s\n" % self._legacy_owner_text())
                    last_msg = time.monotonic()
                time.sleep(1)

    def _legacy_beat(self, _lock=None):
        if self._legacy_mine:
            try:
                os.utime(LOCK_DIR, None)
            except OSError:
                pass

    def _release_legacy(self, _lock=None):
        if not self._legacy_mine:
            return
        self._legacy_mine = False
        if re.search(r"pid=%d\b" % os.getpid(), self._legacy_owner_text()):
            shutil.rmtree(LOCK_DIR, ignore_errors=True)

    # -- normalize hook ----------------------------------------------------------------------------------
    def _find_hook(self):
        if callable(self.normalize):
            return self.normalize
        if self.normalize is False or os.environ.get("STUDIO_NORMALIZE") == "0":
            return None
        path = os.environ.get("STUDIO_NORMALIZE_HOOK")
        if not path and self.game:
            cands = [os.path.join(locks.REPO_ROOT, self.game, "pipeline", "bench_normalize.py")]
            if self.game in (os.path.basename(locks.REPO_ROOT), locks.game_name(locks.REPO_ROOT, use_env=False)):  # standalone game repo / git worktree: tools/ is in the game
                cands.append(os.path.join(locks.REPO_ROOT, "pipeline", "bench_normalize.py"))
            path = next((c for c in cands if os.path.exists(c)), None)
        if not path or not os.path.exists(path):
            return None
        import importlib.util
        spec = importlib.util.spec_from_file_location("studio_normalize_hook", path)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        return getattr(mod, "normalize")

    def _run_normalize(self):
        try:
            hook = self._find_hook()
        except Exception as e:  # noqa: BLE001
            sys.stderr.write("[studio] normalize hook not loadable: %r\n" % (e,))
            return
        if hook is None:
            return
        ctx = {"game": self.game, "owner": self.owner, "died": self.died, "previous": self.previous,
               "waited": self._lock.waited}
        box = {}

        def run():
            try:
                hook(ctx)
            except BaseException as e:  # noqa: BLE001
                box["err"] = e

        t = threading.Thread(target=run, name="studio-normalize", daemon=True)
        t.start()
        t.join(float(os.environ.get("STUDIO_NORMALIZE_TIMEOUT", "180")))
        if t.is_alive():
            sys.stderr.write("[studio] normalize hook timed out; continuing\n")
        elif "err" in box:
            sys.stderr.write("[studio] normalize hook failed: %r\n" % (box["err"],))

    # -- context manager ---------------------------------------------------------------------------------
    def __enter__(self):
        deadline = None if self.timeout is None else time.monotonic() + self.timeout
        self._lock = locks.Lock("studio", owner=self.owner, game=self.game, priority=self.priority,
                                timeout=self.timeout, cap=self.cap, quiet=self.quiet,
                                on_beat=self._legacy_beat, on_release=self._release_legacy)
        self._lock.acquire()
        if self._lock._reentrant:  # an ancestor of this process already holds the lock and ran the hook
            return self
        try:
            self._take_legacy(deadline)
        except BaseException:
            self._lock.release()
            raise
        self.previous = self._lock.previous
        if self.previous and self.previous.get("died"):
            self.died = True
        self._run_normalize()
        return self

    def __exit__(self, *exc):
        if self._lock is not None:
            self._lock.release()
            self._lock = None

    acquire = __enter__

    def release(self):
        self.__exit__()


class StudioSession:
    def __init__(self, settle=None):
        self.settle = float(settle if settle is not None else os.environ.get("STUDIO_SETTLE", "6"))
        self.next_id = 10

    def __enter__(self):
        self.p = subprocess.Popen([PROXY], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                  stderr=subprocess.DEVNULL, text=True, bufsize=1)
        self._send({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
            "protocolVersion": "2025-06-18", "capabilities": {},
            "clientInfo": {"name": "claude-bridge", "version": "1"}}})
        self._recv(1, 30)
        self._send({"jsonrpc": "2.0", "method": "notifications/initialized"})
        self._send({"jsonrpc": "2.0", "id": 2, "method": "tools/list"})
        self._recv(2, 30)
        time.sleep(self.settle)  # the proxy needs a moment to discover running Studios
        return self

    def __exit__(self, *exc):
        self.p.terminate()

    def _send(self, obj):
        self.p.stdin.write(json.dumps(obj) + "\n")
        self.p.stdin.flush()

    def _recv(self, want_id, timeout):
        end = time.time() + timeout
        while time.time() < end:
            ready, _, _ = select.select([self.p.stdout], [], [], 0.5)
            if ready:
                line = self.p.stdout.readline()
                if not line:
                    break
                if line.strip():
                    msg = json.loads(line)
                    if msg.get("id") == want_id:
                        return msg
        return None

    def studio_id(self, prefer=None):
        """Resolve a Studio instance id: $STUDIO_ID, else the instance whose name contains `prefer`
        (or $STUDIO_NAME), else the first instance with an open place."""
        env = os.environ.get("STUDIO_ID")
        if env and env != "auto":
            return env
        prefer = prefer or os.environ.get("STUDIO_NAME")
        for attempt in range(6):
            ok, texts, _ = self._call_once("list_roblox_studios", {}, 60)
            try:
                studios = json.loads(texts[0]).get("studios", []) if texts else []
            except (ValueError, IndexError):
                studios = []
            if studios:
                if prefer:
                    for st in studios:
                        if prefer.lower() in str(st.get("name") or "").lower():
                            return st["id"]
                named = [st for st in studios if st.get("name")]
                return (named or studios)[0]["id"]
            time.sleep(3 + 2 * attempt)
        raise RuntimeError("no Roblox Studio instance connected (is a place open with the MCP server enabled?)")

    def call(self, tool, args=None, timeout=180):
        """Returns (ok, texts, images_b64). Retries while the proxy hasn't discovered Studio yet.
        A studio_id of "auto" (or missing, for tools that need one) is resolved automatically."""
        args = dict(args or {})
        if args.get("studio_id") in (None, "auto") and tool != "list_roblox_studios":
            args["studio_id"] = self.studio_id()
        for attempt in range(4):
            ok, texts, images = self._call_once(tool, args, timeout)
            if not any("No Roblox Studio instances are connected" in t for t in texts):
                break
            time.sleep(4 + 3 * attempt)
        return ok, texts, images

    def _call_once(self, tool, args, timeout):
        self.next_id += 1
        self._send({"jsonrpc": "2.0", "id": self.next_id, "method": "tools/call",
                    "params": {"name": tool, "arguments": args or {}}})
        r = self._recv(self.next_id, timeout)
        if r is None:
            return False, ["ERROR: timed out"], []
        if "error" in r:
            return False, ["ERROR: " + json.dumps(r["error"])], []
        res = r["result"]
        texts = [c["text"] for c in res.get("content", []) if c.get("type") == "text"]
        images = [c["data"] for c in res.get("content", []) if c.get("type") == "image"]
        return not res.get("isError"), texts, images


def main():
    tool = sys.argv[1]
    args = json.loads(sys.argv[2]) if len(sys.argv) > 2 else {}
    out_dir = os.environ.get("STUDIO_IMG_DIR", os.getcwd())
    with StudioSession() as s:
        ok, texts, images = s.call(tool, args, float(os.environ.get("STUDIO_TIMEOUT", "180")))
    for t in texts:
        print(t)
    for i, data in enumerate(images, 1):
        path = os.path.join(out_dir, f"{tool}_{int(time.time())}_{i}.png")
        with open(path, "wb") as f:
            f.write(base64.b64decode(data))
        print("IMAGE:", path)
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
