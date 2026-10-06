"""macOS helpers for driving Roblox Studio windows without a human (issue #213).

Used by tools/studio-open.py and tools/studio-window-shot.py. Needs Screen Recording (window titles, screencapture)
and Accessibility (System Events keystrokes, AX layout) granted to the host app.

  * cg_windows()           Studio's layer-0 windows from CGWindowListCopyWindowInfo (tools/studio-windows.swift,
                           compiled once into ~/.cache/chadtycoon/).
  * find_window(match)     the place window whose title contains `match` (else the largest Studio window).
  * viewport_rect(title)   the 3D viewport inside that window, in window-local points (largest AX group).
  * frontmost()/restore()  remember and give focus back to whatever app the user was in.
  * dismiss_dialogs()      click through known modal dialogs ("Lighting Technology Migration" -> Continue).
  * capture(win, path)     background capture (screencapture -l), works while Studio is behind other windows.

Hard rule: every action (keystrokes, presses, closes, kills, captures) is scoped to a process or window whose place
title contains "TestBench". A process that hosts any other place (the user's real game) is never touched.
"""
import json, os, subprocess, sys, tempfile, time

TOOLS = os.path.dirname(os.path.abspath(__file__))
SWIFT = os.path.join(TOOLS, "studio-windows.swift")
PROC = "Roblox"  # System Events process names contain it (RobloxStudio, one process per open place)
TESTBENCH = os.path.expanduser("~/RobloxProjects/.testbench")
KNOWN_DIALOGS = [("Lighting Technology Migration", "Continue")]
BENCH = "TestBench"
START_PAGE = "Roblox Studio"
PLACE_SUFFIX = " - Roblox Studio"


# -- pure logic (unit-tested headlessly by tools/studio-window-selftest.py) -----------------------------------
def is_place_title(t):
    return t.endswith(PLACE_SUFFIX)


def is_bench_title(t):
    return is_place_title(t) and BENCH in t


def bench_pids(rows):
    """Pids of Studio processes that are safe to drive: they host at least one TestBench place and no other place.
    rows: [(title, x, y, w, h, pid)] as from ax_windows()."""
    by_pid = {}
    for r in rows:
        by_pid.setdefault(r[5], []).append(r[0])
    return sorted(pid for pid, titles in by_pid.items()
                  if any(is_bench_title(t) for t in titles)
                  and not any(is_place_title(t) and not is_bench_title(t) for t in titles))


def bench_pid_of(rows, title):
    """The pid hosting `title`, only if `title` is a TestBench place and that process is a bench process."""
    if not is_bench_title(title):
        return None
    pid = next((r[5] for r in rows if r[0] == title), None)
    return pid if pid in bench_pids(rows) else None


def safe_to_kill(rows, pid):
    """A process may be ended only when it still has windows and every one of them is untitled or the "Roblox
    Studio" start page. No windows at all (gone, or an AX timeout) -> False."""
    mine = [r[0] for r in rows if r[5] == pid]
    return bool(mine) and all(t in ("", START_PAGE) for t in mine)


def dontsave_allowed(rows, pid):
    """The Don't Save helper may act on `pid` only if it currently shows a TestBench place title and no other place.
    Zero titles (e.g. after an AX timeout) -> refuse. studio-dontsave.swift re-checks the same rule."""
    places = [r[0] for r in rows if r[5] == pid and is_place_title(r[0])]
    return bool(places) and all(BENCH in t for t in places)


def is_studio_pid(pid):
    """Fresh check that `pid` is still a RobloxStudio process (pids get reused)."""
    try:
        r = subprocess.run(["ps", "-p", str(int(pid)), "-o", "comm="], capture_output=True, text=True, timeout=10)
    except (subprocess.TimeoutExpired, ValueError):
        return False
    return r.returncode == 0 and r.stdout.strip().endswith("/RobloxStudio")


def bench_start_page_pids(rows, args_of):
    """Studio processes showing only the start page / untitled windows (no place at all) that were launched on a
    ~/RobloxProjects/.testbench/TestBench-* file (args_of(pid) -> its command line). studio-open.py launches one
    with `open -a RobloxStudio <TestBench file>` (which lands on the start page) when no Studio runs at all, and may
    type Cmd-O into it. A start page the user opened is never driven."""
    by_pid = {}
    for r in rows:
        by_pid.setdefault(r[5], []).append(r[0])
    return sorted(pid for pid, titles in by_pid.items()
                  if all(t in ("", START_PAGE) for t in titles) and "/.testbench/TestBench-" in (args_of(pid) or ""))


OWNERS = os.path.join(TESTBENCH, ".owners.json")


def tag_of(title):
    """'.../TestBench-<tag>.rbxl - Roblox Studio' -> tag (None for anything else)."""
    import re
    m = re.search(r"/\.testbench/TestBench-([A-Za-z0-9_-]+)\.rbxl - Roblox Studio$", title or "")
    return m.group(1) if m else None


def caller_id(explicit=None):
    """Who is calling: --owner, else $STUDIO_OWNER, else the git top level of the cwd (each agent thread works in its
    own worktree), else the cwd."""
    if explicit:
        return explicit
    if os.environ.get("STUDIO_OWNER"):
        return os.environ["STUDIO_OWNER"]
    try:
        r = subprocess.run(["git", "rev-parse", "--show-toplevel"], capture_output=True, text=True, timeout=10)
        if r.returncode == 0 and r.stdout.strip():
            return r.stdout.strip()
    except (OSError, subprocess.TimeoutExpired):
        pass
    return os.getcwd()


def load_owners(path=None):
    try:
        with open(path or OWNERS) as f:
            d = json.load(f)
        return d if isinstance(d, dict) else {}
    except (OSError, ValueError):
        return {}


def record_owner(tag, owner, path=None):
    """Remember that `owner` opened TestBench-<tag> with studio-open (read by --close and host selection)."""
    path = path or OWNERS
    d = load_owners(path)
    d[tag] = {"owner": owner, "opened": int(time.time())}
    tmp = path + ".%d.tmp" % os.getpid()
    with open(tmp, "w") as f:
        json.dump(d, f, indent=1)
    os.replace(tmp, path)


def owns(owners, tag, me):
    return bool(tag) and (owners.get(tag) or {}).get("owner") == me


def pick_host(rows, args_of, owners, me, is_idle, via=None):
    """Which Studio process gets the Cmd-O (pure; unit-tested). Returns (kind, pid):
      ("start_page", pid)  a start-page-only process launched on a TestBench file (no place open, nobody's work);
      ("launch", None)     none of those: launch a fresh Studio (`open -n`) on the TestBench file;
      ("owned", pid)       only with --via: a bench process whose places are ALL TestBench places opened by this
                           caller (owners registry), one of them containing `via`, and idle (is_idle(pid), e.g. not
                           in Play). --via is a strict filter: nothing matching -> ("none", None).
    A TestBench process another thread uses is never driven."""
    if via:
        by_pid = {}
        for r in rows:
            by_pid.setdefault(r[5], []).append(r[0])
        cands = [pid for pid in bench_pids(rows)
                 if any(via in t for t in by_pid[pid] if is_bench_title(t))
                 and all(owns(owners, tag_of(t), me) for t in by_pid[pid] if is_place_title(t))]
        for pid in cands:
            if is_idle(pid):
                return ("owned", pid)
        return ("none", None)
    sp = bench_start_page_pids(rows, args_of)
    if sp:
        return ("start_page", sp[0])
    return ("launch", None)


def proc_args(pid):
    try:
        r = subprocess.run(["ps", "-p", str(int(pid)), "-o", "args="], capture_output=True, text=True, timeout=10)
    except (subprocess.TimeoutExpired, ValueError):
        return ""
    return r.stdout.strip() if r.returncode == 0 else ""


def studio_pids():
    r = subprocess.run(["pgrep", "-x", "RobloxStudio"], capture_output=True, text=True, timeout=10)
    return [int(x) for x in r.stdout.split()]


def safe_tag(tag):
    import re
    return bool(re.fullmatch(r"[A-Za-z0-9_-]+", tag or ""))



def osa(script, timeout=60):
    r = subprocess.run(["osascript", "-e", script], capture_output=True, text=True, timeout=timeout)
    if r.returncode != 0:
        raise RuntimeError("osascript: " + r.stderr.strip())
    return r.stdout.strip()


def q(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def helper(name="studio-windows"):
    """Command for tools/<name>.swift, compiled once into ~/.cache/chadtycoon/ (falls back to the interpreter).
    Compiles to a temp file and renames it into place, so racing agents never run a half-written binary."""
    src = os.path.join(TOOLS, name + ".swift")
    cache = os.path.expanduser("~/.cache/chadtycoon")
    exe = os.path.join(cache, "%s-%d" % (name, int(os.path.getmtime(src))))
    if not os.path.exists(exe):
        os.makedirs(cache, exist_ok=True)
        fd, tmp = tempfile.mkstemp(prefix=name + ".", dir=cache)
        os.close(fd)
        try:
            ok = subprocess.run(["swiftc", "-O", src, "-o", tmp], capture_output=True, timeout=600).returncode == 0
            if not ok:
                return ["swift", src]
            os.chmod(tmp, 0o755)
            os.rename(tmp, exe)
        finally:
            if os.path.exists(tmp):
                os.remove(tmp)
    return [exe]


def run_helper(name, args=(), timeout=30, env=None):
    return subprocess.run(helper(name) + [str(a) for a in args], capture_output=True, text=True, timeout=timeout,
                          env=dict(os.environ, **env) if env else None)


def cg_windows():
    out = subprocess.run(helper(), capture_output=True, text=True, check=True, timeout=30).stdout
    return json.loads(out or "[]")


def parse_ax_rows(text):
    """Rows (title, x, y, w, h, pid) from tab-separated helper / AppleScript output."""
    rows = []
    for line in text.splitlines():
        p = line.split("\t")
        if len(p) == 6:
            try:
                rows.append((p[0], *(int(float(v)) for v in p[1:])))
            except ValueError:
                pass
    return rows


def ax_windows():
    """[(title, x, y, w, h, pid)] of Studio's AX windows (screen points). Every open place is its own RobloxStudio
    process, so all of them are walked, by pid (tools/studio-axwindows.swift). The old System Events walk failed
    with -1728 whenever a Studio process or window came or went mid-walk (e.g. while a new place is opening); it is
    kept only as a fallback, retried."""
    for attempt in range(3):
        try:
            r = run_helper("studio-axwindows", timeout=30)
            if r.returncode == 0:
                return parse_ax_rows(r.stdout)
        except subprocess.TimeoutExpired:
            pass
        time.sleep(0.5 + attempt)
    script = '''set o to ""
tell application "System Events"
repeat with p in (every process whose name contains "%s")
try
set pid to unix id of p
repeat with w in (every window of p)
set {px, py} to position of w
set {sw, sh} to size of w
set o to o & (name of w) & tab & px & tab & py & tab & sw & tab & sh & tab & pid & linefeed
end repeat
end try
end repeat
end tell
return o''' % PROC
    for attempt in range(3):
        try:
            return parse_ax_rows(osa(script))
        except (RuntimeError, subprocess.TimeoutExpired):
            if attempt == 2:
                raise
            time.sleep(1 + attempt)


def pid_of(title):
    """Pid of the bench process hosting TestBench place `title` (None for anything else)."""
    return bench_pid_of(ax_windows(), title)


def in_process(pid, body):
    """AppleScript running `body` inside `tell p`, p being the Studio process with that pid. (`first process whose
    unix id is N` can resolve to the wrong Studio process, so walk them.) Inside `body`, element references resolve
    against the PROCESS: `first process whose frontmost is true` there is "process 1 of <Studio process>" and fails
    with -1728. Do focus / frontmost checks in Swift (tools/studio-keys.swift), not in `body`."""
    return '''tell application "System Events"
repeat with c in (every process whose name contains "%s")
if unix id of c is %d then
tell c
%s
end tell
return
end if
end repeat
error "no Studio process %d"
end tell''' % (PROC, pid, body, pid)


def place_windows():
    """Titles of open place windows: "<path> - Roblox Studio"."""
    return [r[0] for r in ax_windows() if r[0].endswith(" - Roblox Studio") and "/" in r[0]]


def pick_window(wins, ax_rows, match=None):
    """Pure part of find_window. wins: CG dicts; ax_rows: ax_windows() rows (only consulted when CG names are empty).
    Returns the largest TestBench place window whose title contains `match` (any TestBench window if no match)."""
    wins = [w for w in wins if w["w"] > 400 and w["h"] > 300]
    if any(w["name"] for w in wins):
        cands = [w for w in wins if is_bench_title(w["name"])]
    else:  # no Screen Recording: titles from AX, matched by bounds
        cands = []
        for title, x, y, ww, hh, _pid in ax_rows():
            if is_bench_title(title):
                cands += [dict(w, name=title) for w in wins
                          if (int(w["x"]), int(w["y"]), int(w["w"]), int(w["h"])) == (x, y, ww, hh)]
    cands = [w for w in cands if not match or match in w["name"]]
    return max(cands, key=lambda w: w["w"] * w["h"], default=None)


def find_window(match=None):
    """The CG window (dict with id/x/y/w/h/name) of the TestBench place whose title contains `match` (default: the
    largest TestBench window). Never returns a non-TestBench window. No match -> None."""
    return pick_window(cg_windows(), ax_windows, match)


def viewport_rect(title):
    """The 3D viewport of the window titled `title`, as (x, y, w, h) window-local points: the largest AX group
    (Studio exposes the edit/play viewport as a plain AXGroup below the document tab bar). None if not found."""
    pid = bench_pid_of(ax_windows(), title)
    if pid is None:
        return None
    script = in_process(pid, '''set o to ""
tell window %s
set {wx, wy} to position
repeat with e in (every UI element whose role is "AXGroup")
set {px, py} to position of e
set {sw, sh} to size of e
set o to o & (px - wx) & tab & (py - wy) & tab & sw & tab & sh & linefeed
end repeat
end tell
return o''' % q(title))
    best, text = None, None
    for attempt in range(4):  # System Events sometimes fails with -10000 (AppleEvent handler failed); retry
        try:
            text = osa(script, timeout=20)
            break
        except (RuntimeError, subprocess.TimeoutExpired):
            time.sleep(1 + attempt)
    if text is None:
        return None
    for line in text.splitlines():
        x, y, w, h = (int(float(v)) for v in line.split("\t"))
        if w * h > 0 and (best is None or w * h > best[2] * best[3]):
            best = (x, y, w, h)
    return best


def frontmost():
    """Bundle id of the frontmost app (a by-name process reference is fine here: only the bundle id is read)."""
    return osa('tell application "System Events" to get bundle identifier of first application process '
               'whose frontmost is true')


def restore(bundle_id):
    if bundle_id and bundle_id.lower() != "com.roblox.robloxstudio":
        subprocess.run(["osascript", "-e", "tell application id %s to activate" % q(bundle_id)], capture_output=True,
                       timeout=15)


def dismiss_dialogs(pid):
    """Press the button of every known dialog up on bench process `pid`, with no focus change
    (tools/studio-axpress.swift walks kAXChildren recursively: the buttons sit inside an AXGroup that AppleScript's
    `button of window` misses). Returns the names of the dialogs dismissed."""
    rows = ax_windows()
    if pid is None or pid not in bench_pids(rows):
        return []
    done = []
    up = {r[0] for r in rows if r[5] == pid}
    for name, button in KNOWN_DIALOGS:
        if name in up:
            try:
                r = run_helper("studio-axpress", [pid, name, button])
            except subprocess.TimeoutExpired:
                continue
            if r.returncode == 0:
                done.append(name)
            else:
                sys.stderr.write("[studio] could not press %r in %r: %s\n" % (button, name, r.stdout.strip()))
    return done


def close_place(title, timeout=30):
    """Close a TestBench place and answer Don't Save. The close button is pressed through AX (no focus change); the
    save prompt's buttons are not in the AX tree, so tools/studio-dontsave.swift raises that process's prompt for a
    moment, verifies it is topmost at the click point, clicks Don't Save, and restores the mouse and the frontmost
    app. The process is left with a ~1.5 GB start-page window, so it is ended once only untitled / start-page
    windows remain on it. Returns True when the place is gone."""
    pid = bench_pid_of(ax_windows(), title)
    if pid is None:
        return title not in place_windows()
    run_helper("studio-axclose", [pid, title])
    end = time.time() + timeout
    while time.time() < end and title in place_windows():
        time.sleep(1.5)
        rows = ax_windows()
        if any(r[0] == "" and r[5] == pid for r in rows) and dontsave_allowed(rows, pid):
            try:
                run_helper("studio-dontsave", [pid])
            except subprocess.TimeoutExpired:
                pass
    if title in place_windows():
        return False
    time.sleep(1)
    if safe_to_kill(ax_windows(), pid) and is_studio_pid(pid):
        try:
            os.kill(pid, 15)
        except OSError:
            pass
    return True


def stray_windows(place_title):
    """Non-place windows (dialogs) left on the process that owns `place_title`."""
    rows = ax_windows()
    pid = next((r[5] for r in rows if r[0] == place_title), None)
    return [r[0] for r in rows if r[5] == pid and r[0] != place_title]


def capture(win_id, path):
    """Background capture of one window (no shadow, no sound). Returns True on success."""
    try:
        r = subprocess.run(["screencapture", "-x", "-o", "-l", str(win_id), path], capture_output=True, timeout=30)
    except subprocess.TimeoutExpired:
        return False
    return r.returncode == 0 and os.path.exists(path) and os.path.getsize(path) > 0
