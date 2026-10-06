#!/usr/bin/env python3
"""Machine-wide locks for the shared Roblox tooling (M0-00, ARCHITECTURE 0.8 / 10.2).

What is locked
  studio            the one shared Roblox Studio instance (machine-wide, 1 holder)
  heavy             the heavy-job pool: Blender, Xcode, perf runs ... (machine-wide, 2 slots)
  assets.<game>     per-game asset manifest/pins/upload lock
  gen.<game>        per-game regeneration lock
Order when nesting: studio, heavy, assets, gen (gen may also be the outermost lock of a regen script).

How
  * The lock itself is an flock(2) on /tmp/roblox-locks/<slot>.flock. The kernel drops it the moment the
    holding process dies (kill -9 included), so a dead holder is never a problem.
  * FIFO tickets (/tmp/roblox-locks/<name>.q/): a waiter may only try to take the lock when its ticket is the
    oldest live one (priority first, then arrival order). A ticket is kept alive by the waiter touching it;
    tickets of dead or frozen waiters are pruned.
  * Heartbeat: the holder rewrites <slot>.holder every 10 s. A live, heartbeating holder is never stolen from.
    A holder whose heartbeat stays frozen for 60 s of the waiter's own (sleep-proof, monotonic) time, or whose
    process is dead, is stale: dead ones are already free (kernel), frozen ones are SIGKILLed by the head
    waiter (pid + process start time verified), which frees the flock.
  * Hold caps (studio/heavy 10 min, priority holds 25 min) are advisory: an overdue holder is flagged in
    `status` and in waiter messages; `run --enforce-cap` (with-lock.sh / with-heavy.sh) terminates the command.
  * Re-entrancy: a process started under a lock inherits ROBLOX_LOCKS_HELD, so `with-heavy.sh blender-run.sh`
    (which itself takes a heavy slot) or `with-lock.sh studio python studio-shot.py` do not deadlock.

  * Known limits: (a) the lock is bound to the `locks.py run` wrapper process, not to its child. Killing a frozen
    holder (or `break`) kills only the wrapper: its child (a Studio-driving script, a SIGSTOPped Blender ...) keeps
    running WITHOUT the lock, and a stopped Blender is still counted by blender-run.sh's pgrep guard until it is
    killed by hand. (b) Re-entrancy is keyed on the lock name only: `with-heavy.sh -- bash -c 'blender-run.sh a &
    blender-run.sh b'` runs 2 Blenders under 1 slot; only blender-run.sh's pgrep guard stops a third one.

Python:
    from locks import Lock
    with Lock("assets.ChadTycoon", owner="upload"): ...
    with Lock("heavy", slots=2, priority=1, owner="perf"): ...     # both slots (perf/gate runs)
CLI:
    locks.py run [opts] NAME -- cmd...    opts: --owner S --game G --priority N --slots K --timeout SEC
                                                 --cap SEC --enforce-cap --quiet
    locks.py status [--json]
    locks.py break NAME --force [--tickets]      kill the holder(s) (pid + start time verified), optionally clear the queue
Exit codes of `run`: the command's; 75 = timed out waiting; 127 = command not found.
Env: ROBLOX_LOCKS_DIR, ROBLOX_HEAVY_SLOTS (2), ROBLOX_LOCKS_HEARTBEAT (10), ROBLOX_LOCKS_STALE (60),
     ROBLOX_LOCKS_QUIET, ROBLOX_LOCK_OWNER, ROBLOX_GAME.
Needs only python3 (3.9+) stdlib. macOS/Linux."""
import atexit
import errno
import fcntl
import json
import os
import re
import signal
import socket
import subprocess
import sys
import threading
import time
import uuid

TOOLS_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.dirname(TOOLS_DIR)
# Lock-name of this repo's game (assets.ChadTycoon, gen.ChadTycoon). The lock directory, the heavy pool and the studio
# lock are machine-wide and identical to the other game repos' tools/locks.py, so all projects share the same slots.
GAME = "ChadTycoon"
PROJECT_FILES = ("chad.project.json", "default.project.json")

# pool name -> (env var for size, default size)
POOLS = {"heavy": ("ROBLOX_HEAVY_SLOTS", 2)}
DEFAULT_CAP = 600  # seconds, advisory
PRIORITY_CAP = 1500
EX_TEMPFAIL = 75
_NAME_RE = re.compile(r"^[A-Za-z0-9_][A-Za-z0-9_.-]*$")


class LockTimeout(TimeoutError):
    pass


# ----------------------------------------------------------------------------------------------- settings
def root():
    return os.environ.get("ROBLOX_LOCKS_DIR", "/tmp/roblox-locks")


def heartbeat_interval():
    return float(os.environ.get("ROBLOX_LOCKS_HEARTBEAT", "10"))


def stale_after():
    return float(os.environ.get("ROBLOX_LOCKS_STALE", "60"))


def pool_size(name):
    if name in POOLS:
        var, default = POOLS[name]
        return max(1, int(os.environ.get(var, default)))
    return 1


def check_name(name):
    if not _NAME_RE.match(name or ""):
        raise ValueError("bad lock name %r" % (name,))
    for p in POOLS:
        if name.startswith(p + ".") and name[len(p) + 1:].isdigit():
            raise ValueError("lock name %r collides with a slot of pool %r" % (name, p))
    return name


def slot_names(name):
    n = pool_size(name)
    return ["%s.%d" % (name, i) for i in range(n)] if name in POOLS else [name]


def _p(*parts):
    return os.path.join(root(), *parts)


def _ensure_root():
    try:
        os.makedirs(root(), mode=0o755, exist_ok=True)
    except OSError:
        pass


def infer_game(cwd=None):
    """Game directory name (a top-level dir of the repo with default.project.json) containing cwd, else env, else None."""
    env = os.environ.get("ROBLOX_GAME")
    if env:
        return env
    cwd = os.path.abspath(cwd or os.getcwd())
    if cwd == REPO_ROOT or cwd.startswith(REPO_ROOT + os.sep):
        rel = os.path.relpath(cwd, REPO_ROOT).split(os.sep)[0]
        if rel not in (".", "tools") and os.path.exists(os.path.join(REPO_ROOT, rel, "default.project.json")):
            return rel
        if any(os.path.exists(os.path.join(REPO_ROOT, f)) for f in PROJECT_FILES):
            return game_name(REPO_ROOT, use_env=False)  # standalone game repo (or a git worktree of it): the repo is the game
    return None


def game_name(game_dir=None, use_env=True):
    """Name of the game whose repo is game_dir (default: this repo): $ROBLOX_GAME when use_env and set; else, when game_dir
    is the top of a linked git worktree (.claude/worktrees/<name>/), the MAIN checkout's folder name, so locks, build/<game>.rbxl
    and deploy targets match the main checkout; else the folder name."""
    if use_env and os.environ.get("ROBLOX_GAME"):
        return os.environ["ROBLOX_GAME"]
    import subprocess

    path = os.path.realpath(game_dir or REPO_ROOT)
    if path == os.path.realpath(REPO_ROOT):
        return GAME
    try:
        r =subprocess.run(["git", "-C", path, "rev-parse", "--path-format=absolute", "--show-toplevel", "--git-common-dir"],
                           capture_output=True, text=True, timeout=10)
        lines = r.stdout.split("\n")
        if r.returncode == 0 and len(lines) >= 2:
            top, common = os.path.realpath(lines[0].strip()), os.path.realpath(lines[1].strip())
            main = os.path.dirname(common)
            if top == path and os.path.basename(common) == ".git" and main != top:
                return GAME if os.path.exists(os.path.join(main, "chad.project.json")) else os.path.basename(main)
    except (OSError, subprocess.SubprocessError):
        pass
    return os.path.basename(path)


def default_cap(name, priority):
    if priority > 0:
        return PRIORITY_CAP
    return DEFAULT_CAP if (name == "studio" or name in POOLS) else None


# ----------------------------------------------------------------------------------------------- helpers
def pid_alive(pid):
    if not pid or pid <= 0:
        return False
    try:
        os.kill(pid, 0)
    except OSError as e:
        return e.errno == errno.EPERM
    return True


def pid_start(pid):
    """Process start time string (guards against pid reuse); '' when unknown."""
    try:
        out = subprocess.run(["ps", "-o", "lstart=", "-p", str(pid)], stdout=subprocess.PIPE,
                             stderr=subprocess.DEVNULL, timeout=5)
        return out.stdout.decode().strip()
    except Exception:
        return ""


def _read_json(path):
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def _write_json_atomic(path, obj):
    tmp = "%s.%d.%s.tmp" % (path, os.getpid(), uuid.uuid4().hex[:6])
    try:
        with open(tmp, "w") as f:
            json.dump(obj, f)
        os.replace(tmp, path)
    except OSError:
        try:
            os.unlink(tmp)
        except OSError:
            pass


def _fmt_dur(s):
    s = int(max(0, s))
    return "%dm%02ds" % (s // 60, s % 60) if s >= 60 else "%ds" % s


class FrozenTracker:
    """Tells how long (monotonic, so a laptop sleep does not count) a value has stayed unchanged."""

    def __init__(self):
        self.seen = {}

    def idle(self, key, value):
        now = time.monotonic()
        prev = self.seen.get(key)
        if prev is None or prev[0] != value:
            self.seen[key] = (value, now)
            return 0.0
        return now - prev[1]


def describe_holder(info):
    if not info:
        return "unknown holder"
    age = time.time() - info.get("started", time.time())
    s = "%s (pid %s, %s, held %s" % (info.get("owner", "?"), info.get("pid"), info.get("game") or "no game", _fmt_dur(age))
    cap = info.get("cap")
    if cap and age > cap:
        s += ", OVERDUE cap %s" % _fmt_dur(cap)
    return s + ")"


# ----------------------------------------------------------------------------------------------- tickets
def _next_seq(name):
    fd = os.open(_p(name + ".seq"), os.O_RDWR | os.O_CREAT, 0o644)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        raw = os.read(fd, 32)
        n = (int(raw) if raw.strip().isdigit() else 0) + 1
        os.lseek(fd, 0, 0)
        os.ftruncate(fd, 0)
        os.write(fd, str(n).encode())
        return n
    finally:
        os.close(fd)


def _qdir(name):
    return _p(name + ".q")


def _parse_ticket(fname):
    parts = fname.split("-")
    try:
        return int(parts[0]), int(parts[1]), int(parts[2])  # 9-prio, seq, pid
    except (ValueError, IndexError):
        return None


def live_tickets(name, tracker, stale=None):
    """Sorted live ticket file names; prunes dead / frozen ones."""
    stale = stale_after() if stale is None else stale
    qd = _qdir(name)
    try:
        names = os.listdir(qd)
    except OSError:
        return []
    live = []
    for fn in names:
        parsed = _parse_ticket(fn)
        path = os.path.join(qd, fn)
        if parsed is None:
            continue
        pid = parsed[2]
        dead = not pid_alive(pid)
        frozen = False
        if not dead:
            try:
                mt = os.stat(path).st_mtime
            except OSError:
                continue
            frozen = (time.time() - mt > stale) and tracker.idle(("t", fn), mt) >= stale
        if dead or frozen:
            try:
                os.unlink(path)
            except OSError:
                pass
            continue
        live.append(fn)
    live.sort()
    return live


# ----------------------------------------------------------------------------------------------- held-env (re-entrancy)
def _held_entries():
    out = []
    for e in os.environ.get("ROBLOX_LOCKS_HELD", "").split(";"):
        parts = e.split(":")
        if len(parts) == 3 and parts[1].isdigit() and parts[2].isdigit():
            out.append((parts[0], int(parts[1]), int(parts[2])))
    return out


def _set_held(entries):
    val = ";".join("%s:%d:%d" % e for e in entries)
    if val:
        os.environ["ROBLOX_LOCKS_HELD"] = val
    else:
        os.environ.pop("ROBLOX_LOCKS_HELD", None)


def _reentrant_holder(name, want):
    """pid of a live ancestor lock holder that covers `want` slots of `name`, else None."""
    for (n, pid, k) in _held_entries():
        if n != name or k < want or not pid_alive(pid):
            continue
        matched = 0
        for slot in slot_names(name):
            info = _read_json(_p(slot + ".holder"))
            if info and info.get("state") == "held" and info.get("pid") == pid:
                matched += 1
        if matched >= want:
            return pid
    return None


# ----------------------------------------------------------------------------------------------- the lock
class Lock:
    def __init__(self, name, owner=None, game=None, priority=0, slots=1, timeout=None, cap=None,
                 quiet=None, on_acquired=None, on_beat=None, on_release=None):
        self.name = check_name(name)
        self.owner = owner or os.environ.get("ROBLOX_LOCK_OWNER") or "agent"
        self.game = game if game is not None else infer_game()
        self.priority = max(0, min(9, int(priority)))
        self.slots = int(slots)
        if self.slots < 1 or self.slots > pool_size(name):
            raise ValueError("%s has %d slot(s), asked for %d" % (name, pool_size(name), self.slots))
        self.timeout = timeout
        self.cap = default_cap(name, self.priority) if cap is None else (cap or None)
        self.quiet = bool(os.environ.get("ROBLOX_LOCKS_QUIET")) if quiet is None else quiet
        self.on_acquired, self.on_beat, self.on_release = on_acquired, on_beat, on_release
        self.previous = None  # info of the previous holder ({'died': bool, ...}) once acquired
        self.waited = 0.0
        self.held = False
        self._fds = []
        self._reentrant = False
        self._stop = threading.Event()
        self._thread = None
        self._infos = {}
        self._beat_n = 0
        self._tracker = FrozenTracker()
        self._lsof_at = {}
        self._wlock = threading.Lock()  # serializes holder-file writes (heartbeat thread vs _drop)
        self._env_entry = None

    # -- messaging
    def _log(self, msg):
        if not self.quiet:
            sys.stderr.write("[locks] %s\n" % msg)
            sys.stderr.flush()

    def _holders_desc(self):
        parts = []
        for slot in slot_names(self.name):
            info = _read_json(_p(slot + ".holder"))
            if info and info.get("state") == "held":
                parts.append(describe_holder(info))
        return "; ".join(parts) or "unknown holder"

    # -- acquire
    def acquire(self, timeout=None):
        if self.held:
            return self
        timeout = self.timeout if timeout is None else timeout
        self._warn_order()
        rp = _reentrant_holder(self.name, self.slots)
        if rp:
            self._reentrant = True
            self.held = True
            return self
        _ensure_root()
        os.makedirs(_qdir(self.name), exist_ok=True)
        start = time.monotonic()
        deadline = None if timeout is None else start + timeout
        ticket = None
        last_msg = 0.0
        last_touch = 0.0
        stale = stale_after()
        try:
            while True:
                now = time.monotonic()
                if ticket is None or not os.path.exists(os.path.join(_qdir(self.name), ticket)):
                    ticket = self._make_ticket()
                if now - last_touch > 2.0:
                    try:
                        os.utime(os.path.join(_qdir(self.name), ticket), None)
                    except OSError:
                        pass
                    last_touch = now
                tickets = live_tickets(self.name, self._tracker, stale)
                if tickets and tickets[0] == ticket:
                    fds = self._try_take()
                    if fds:
                        self._fds = fds
                        break
                    self._reap_frozen(stale)
                if deadline is not None and time.monotonic() >= deadline:
                    raise LockTimeout("%s lock busy: %s" % (self.name.capitalize(), self._holders_desc()))
                if now - last_msg > (30.0 if last_msg else 0.0):
                    pos = tickets.index(ticket) + 1 if ticket in tickets else 0
                    self._log("waiting for %s: held by %s; queue position %d/%d" %
                              (self.name, self._holders_desc(), pos, len(tickets)))
                    last_msg = now
                time.sleep(0.2)
        finally:
            if ticket:
                try:
                    os.unlink(os.path.join(_qdir(self.name), ticket))
                except OSError:
                    pass
        self.waited = time.monotonic() - start
        try:
            self._after_take()
        except BaseException:
            self._drop()
            raise
        return self

    def _warn_order(self):
        rank = lambda n: 0 if n == "studio" else 1 if n in POOLS else 2 if n.startswith("assets.") else None  # noqa: E731
        mine = rank(self.name)
        if mine is None:
            return
        for (n, pid, _k) in _held_entries():
            r = rank(n)
            if r is not None and r > mine and pid_alive(pid):
                msg = "lock order inversion: taking %s while holding %s (order: studio, heavy, assets, gen)" % (self.name, n)
                if os.environ.get("ROBLOX_LOCKS_STRICT"):
                    raise RuntimeError(msg)
                self._log("WARNING " + msg)

    def _make_ticket(self):
        seq = _next_seq(self.name)
        fn = "%d-%012d-%d-%s" % (9 - self.priority, seq, os.getpid(), uuid.uuid4().hex[:4])
        with open(os.path.join(_qdir(self.name), fn), "w") as f:
            json.dump({"owner": self.owner, "game": self.game, "pid": os.getpid(), "t": time.time()}, f)
        return fn

    def _try_take(self):
        fds = []
        for slot in slot_names(self.name):
            fd = os.open(_p(slot + ".flock"), os.O_RDWR | os.O_CREAT, 0o644)
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except OSError as e:
                os.close(fd)
                if e.errno in (errno.EAGAIN, errno.EACCES, errno.EWOULDBLOCK):
                    continue
                raise
            fds.append((slot, fd))
            if len(fds) == self.slots:
                return fds
        for _slot, fd in fds:
            os.close(fd)
        return None

    def _slot_locked(self, slot):
        """True when the flock of `slot` is actually held by somebody else (probed with a non-blocking flock)."""
        try:
            fd = os.open(_p(slot + ".flock"), os.O_RDWR | os.O_CREAT, 0o644)
        except OSError:
            return False
        try:
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except OSError as e:
                return e.errno in (errno.EAGAIN, errno.EACCES, errno.EWOULDBLOCK)
            return False  # we got it, so it was free; closing the fd frees it again
        finally:
            os.close(fd)

    def _reap_frozen(self, stale):
        for slot in slot_names(self.name):
            info = _read_json(_p(slot + ".holder"))
            nokey = ("nohold", slot)
            if not info or info.get("state") != "held":
                # Only a slot whose flock is really held can have a holder that froze/died between flock and its
                # first record write. A free slot (stale 'released' record) must never trigger the lsof kill:
                # lsof lists every process that merely has the file open (status probes ...).
                if not self._slot_locked(slot):
                    self._tracker.seen.pop(nokey, None)
                    continue
                idle = self._tracker.idle(nokey, (info or {}).get("token"))
                if idle >= stale and time.monotonic() - self._lsof_at.get(slot, -1e9) >= stale:
                    self._lsof_at[slot] = time.monotonic()
                    self._kill_by_lsof(slot)
                continue
            self._tracker.seen.pop(nokey, None)
            pid = info.get("pid")
            if pid == os.getpid() or not pid_alive(pid):
                continue
            idle = self._tracker.idle(("h", slot, info.get("token")), (info.get("beat"), info.get("hb")))
            if idle >= stale and time.time() - info.get("hb", 0) >= stale:
                if info.get("pstart") and pid_start(pid) != info.get("pstart"):
                    continue
                self._log("holder %s of %s has a frozen heartbeat for %s: killing it" %
                          (describe_holder(info), self.name, _fmt_dur(idle)))
                try:
                    os.kill(pid, signal.SIGKILL)
                except OSError:
                    pass

    def _kill_by_lsof(self, slot):
        if not self._slot_locked(slot):  # freed meanwhile: nobody to kill
            return
        try:
            out = subprocess.run(["lsof", "-t", _p(slot + ".flock")], stdout=subprocess.PIPE,
                                 stderr=subprocess.DEVNULL, timeout=10).stdout.decode().split()
        except Exception:
            return
        for tok in out:
            if tok.isdigit() and int(tok) != os.getpid():
                self._log("%s is locked without a holder record for a long time: killing pid %s" % (slot, tok))
                try:
                    os.kill(int(tok), signal.SIGKILL)
                except OSError:
                    pass

    def _after_take(self):
        first_slot = self._fds[0][0]
        prev = _read_json(_p(first_slot + ".holder"))
        if prev:
            self.previous = {"owner": prev.get("owner"), "game": prev.get("game"), "pid": prev.get("pid"),
                             "died": prev.get("state") == "held", "ended": prev.get("ended")}
        token = uuid.uuid4().hex[:12]
        now = time.time()
        base = {"name": self.name, "owner": self.owner, "game": self.game, "pid": os.getpid(),
                "pstart": "", "host": socket.gethostname(), "started": now, "hb": now,
                "beat": 0, "cap": self.cap, "priority": self.priority, "group": self.slots,
                "token": token, "state": "held"}
        for slot, _fd in self._fds:
            info = dict(base)
            info["slot"] = slot
            self._infos[slot] = info
            _write_json_atomic(_p(slot + ".holder"), info)
        pstart = pid_start(os.getpid())  # slow (spawns ps): after the holder files exist, so a crash here is identifiable
        for slot, info in self._infos.items():
            info["pstart"] = pstart
            _write_json_atomic(_p(slot + ".holder"), info)
        entries = [e for e in _held_entries() if e[0] != self.name]
        self._env_entry = (self.name, os.getpid(), self.slots)
        _set_held(entries + [self._env_entry])
        self.held = True
        if self.on_acquired:
            self.on_acquired(self)
        self._stop.clear()
        self._thread = threading.Thread(target=self._beat_loop, name="lock-heartbeat", daemon=True)
        self._thread.start()
        atexit.register(self.release)

    def _beat_loop(self):
        while not self._stop.wait(heartbeat_interval()):
            self._beat()

    def _beat(self):
        with self._wlock:
            if self._stop.is_set() or not self._infos:  # released meanwhile: never resurrect state='held'
                return
            self._beat_n += 1
            for slot, info in self._infos.items():
                info["hb"] = time.time()
                info["beat"] = self._beat_n
                _write_json_atomic(_p(slot + ".holder"), info)
        if self.on_beat and not self._stop.is_set():
            try:
                self.on_beat(self)
            except Exception:
                pass

    # -- release
    def _drop(self):
        self._stop.set()
        with self._wlock:  # a beat in flight finishes first; later beats see _stop and write nothing
            for slot, info in self._infos.items():
                info["state"] = "released"
                info["ended"] = time.time()
                _write_json_atomic(_p(slot + ".holder"), info)
            self._infos = {}
            for _slot, fd in self._fds:
                try:
                    os.close(fd)
                except OSError:
                    pass
            self._fds = []
        if self._env_entry:
            _set_held([e for e in _held_entries() if e != self._env_entry])
            self._env_entry = None
        self.held = False

    def release(self):
        if not self.held:
            return
        if self._reentrant:
            self._reentrant = False
            self.held = False
            return
        if self.on_release:
            try:
                self.on_release(self)
            except Exception:
                pass
        self._drop()

    def overdue(self):
        return bool(self.cap and self._infos and time.time() - next(iter(self._infos.values()))["started"] > self.cap)

    def __enter__(self):
        return self.acquire()

    def __exit__(self, *exc):
        self.release()


# ----------------------------------------------------------------------------------------------- status / break
def status():
    """[{name, slots:[{slot, state: free|held, info}], queue:[...]}]"""
    _ensure_root()
    names = set()
    for fn in os.listdir(root()):
        if fn.endswith(".flock"):
            slot = fn[:-6]
            m = re.match(r"^(.*)\.(\d+)$", slot)
            names.add(m.group(1) if m and m.group(1) in POOLS else slot)
    names.update(POOLS)
    out = []
    tracker = FrozenTracker()
    for name in sorted(names):
        slots = []
        for slot in slot_names(name):
            fd = os.open(_p(slot + ".flock"), os.O_RDWR | os.O_CREAT, 0o644)
            try:
                try:
                    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    state = "free"
                except OSError:
                    state = "held"
            finally:
                os.close(fd)
            info = _read_json(_p(slot + ".holder"))
            slots.append({"slot": slot, "state": state, "info": info if state == "held" else None,
                          "last": None if state == "held" else info})
        queue = []
        for fn in live_tickets(name, tracker, stale_after()):
            t = _read_json(os.path.join(_qdir(name), fn)) or {}
            t["ticket"] = fn
            queue.append(t)
        out.append({"name": name, "slots": slots, "queue": queue})
    return out


def _print_status(as_json):
    st = status()
    if as_json:
        print(json.dumps(st, indent=2))
        return
    for lk in st:
        for s in lk["slots"]:
            if s["state"] == "held":
                info = s["info"] or {}
                extra = ""
                hb = time.time() - info.get("hb", time.time())
                if hb > stale_after():
                    extra = "  HEARTBEAT STALE %s" % _fmt_dur(hb)
                print("%-22s HELD   %s%s" % (s["slot"], describe_holder(info), extra))
            else:
                last = s["last"]
                tail = ""
                if last and last.get("state") == "held":
                    tail = "  (previous holder %s died)" % last.get("owner")
                print("%-22s free%s" % (s["slot"], tail))
        for i, t in enumerate(lk["queue"], 1):
            print("%-22s   queue %d: %s (pid %s)" % (lk["name"], i, t.get("owner", "?"), t.get("pid")))


def break_lock(name, tickets=False):
    check_name(name)
    killed = []
    for slot in slot_names(name):
        info = _read_json(_p(slot + ".holder"))
        if not info or info.get("state") != "held":
            continue
        pid = info.get("pid")
        if pid_alive(pid) and (not info.get("pstart") or pid_start(pid) == info["pstart"]):
            try:
                os.kill(pid, signal.SIGKILL)
                killed.append(pid)
            except OSError:
                pass
    if tickets:
        qd = _qdir(name)
        for fn in (os.listdir(qd) if os.path.isdir(qd) else []):
            try:
                os.unlink(os.path.join(qd, fn))
            except OSError:
                pass
    return killed


# ----------------------------------------------------------------------------------------------- run
def make_lock(name, opts, on_the_fly_owner):
    """Lock for `run`: `studio` goes through studio.studio_lock (legacy dir + normalize hook) unless --raw."""
    kw = dict(owner=opts["owner"] or on_the_fly_owner, priority=opts["priority"], timeout=opts["timeout"])
    if opts["game"] is not None:
        kw["game"] = opts["game"]
    if opts["cap"] is not None:
        kw["cap"] = opts["cap"]
    if opts["quiet"]:
        kw["quiet"] = True
    if name == "studio" and not opts["raw"]:
        sys.path.insert(0, TOOLS_DIR)
        import studio  # noqa: WPS433
        return studio.studio_lock(**kw)
    return Lock(name, slots=opts["slots"], **kw)


def cmd_run(argv):
    opts = {"owner": None, "game": None, "priority": 0, "slots": 1, "timeout": None, "cap": None,
            "enforce": False, "quiet": False, "raw": False}
    i = 0
    name = None
    while i < len(argv):
        a = argv[i]
        if a == "--":
            i += 1
            break
        if a in ("--owner", "--game", "--priority", "--slots", "--timeout", "--cap"):
            key = a[2:]
            val = argv[i + 1]
            opts[key] = val if key in ("owner", "game") else float(val) if key in ("timeout", "cap") else int(val)
            i += 2
        elif a == "--enforce-cap":
            opts["enforce"] = True
            i += 1
        elif a == "--quiet":
            opts["quiet"] = True
            i += 1
        elif a == "--raw":
            opts["raw"] = True
            i += 1
        elif a.startswith("--"):
            sys.exit("locks.py run: unknown option " + a)
        elif name is None:
            name = a
            i += 1
        else:
            break
    cmd = argv[i:]
    if not name or not cmd:
        sys.exit("usage: locks.py run [opts] NAME -- cmd...")
    lock = make_lock(name, opts, " ".join(os.path.basename(c) for c in cmd[:3])[:60])
    try:
        lock.acquire()
    except LockTimeout as e:
        sys.stderr.write("[locks] timed out: %s\n" % e)
        return EX_TEMPFAIL
    proc = None
    pending = []

    def forward(signum, _frame):
        if proc is None:
            pending.append(signum)
            return
        try:
            proc.send_signal(signum)
        except OSError:
            pass

    try:
        for s in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
            signal.signal(s, forward)
        try:
            proc = subprocess.Popen(cmd)
        except OSError as e:
            sys.stderr.write("[locks] cannot run %s: %s\n" % (cmd[0], e))
            return 127
        for sg in pending:
            forward(sg, None)
        cap = opts["cap"] if opts["cap"] is not None else default_cap(name, opts["priority"])
        if opts["enforce"] and cap:
            def enforce():
                if not stop_evt.wait(cap):
                    sys.stderr.write("[locks] hold cap %ss exceeded: terminating %s\n" % (int(cap), cmd[0]))
                    forward(signal.SIGTERM, None)
                    if not stop_evt.wait(10):
                        try:
                            proc.kill()
                        except OSError:
                            pass
            stop_evt = threading.Event()
            threading.Thread(target=enforce, daemon=True).start()
        else:
            stop_evt = threading.Event()
        rc = proc.wait()
        stop_evt.set()
        return 128 - rc if rc < 0 else rc
    finally:
        lock.release()


def main(argv):
    if not argv or argv[0] in ("-h", "--help", "help"):
        print(__doc__)
        return 0
    cmd, rest = argv[0], argv[1:]
    if cmd == "run":
        return cmd_run(rest)
    if cmd == "status":
        _print_status("--json" in rest)
        return 0
    if cmd == "break":
        if "--force" not in rest:
            sys.exit("locks.py break NAME --force [--tickets]")
        names = [a for a in rest if not a.startswith("--")]
        killed = break_lock(names[0], "--tickets" in rest)
        print("killed holder pids: %s" % (killed or "none"))
        return 0
    sys.exit("unknown command %r (run, status, break)" % cmd)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
