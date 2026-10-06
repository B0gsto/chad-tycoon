#!/usr/bin/env python3
"""Open (or reuse) a built place in Roblox Studio without a human click and without leaving Studio in front.

usage: tools/studio-open.py <place.rbxl> [--tag NAME] [--via TEXT] [--owner ID] [--close-others] [--timeout SECONDS]
                             [--no-mcp]
       tools/studio-open.py --close TAG [--owner ID] [--force]   (close TestBench-<TAG>.rbxl only)

  * Copies the file to ~/RobloxProjects/.testbench/TestBench-<tag>.rbxl (tag defaults to the file's stem), so the
    window passes the TestBench guard (ARCHITECTURE 0.10) and the build output is never locked by Studio.
  * If a window for that TestBench file is already open it is reused (nothing is copied or typed; the window keeps
    its in-memory state; close it first, or use another --tag, to load a fresh build).
  * Otherwise, under the Studio lock (tools/studio.py studio_lock): remember the frontmost app, bring the chosen
    Studio process (see below) to the front, Cmd-O, Cmd-Shift-G, type the path, Return, Return, then give focus straight back (about 5 s in
    front). Focus and typing go through tools/studio-keys.swift by exact pid (no AppleScript process lookup, which
    resolves same-named RobloxStudio processes ambiguously: osascript -1728). Before each keystroke group it checks
    that this exact process is frontmost and aborts otherwise (a retry only if nothing was typed yet). The new place
    may land in any Studio process; its window is then found by title across all of them. With no bench process,
    a start-page-only process launched on a TestBench file is used; with no Studio process at all, one is launched
    (`open -g -a RobloxStudio <TestBench file>`, which lands on the start page) and receives the Cmd-O. A process hosting any
    non-TestBench place (the real game) is never driven; with no bench process the tool fails.
    `open -a RobloxStudio file.rbxl` does not work (it lands on the start page).
  * Waits for <file>.lock and the "<path> - Roblox Studio" window, dismisses known dialogs (Lighting Technology
    Migration -> Continue via AXPress on that process only, ~20 s poll; fails if any dialog is left on the
    place), and (unless --no-mcp) waits until the Studio MCP lists the place.
  * --tag must match [A-Za-z0-9_-]+.
  * Ownership: every place this tool opens is recorded in ~/RobloxProjects/.testbench/.owners.json as
    {tag: owner}; owner = --owner, else $STUDIO_OWNER, else the caller's git top level (its worktree).
  * Which process gets the Cmd-O (studio_window.pick_host), never a TestBench process another thread uses:
    1. a start-page-only Studio process (no place open) launched on a TestBench file;
    2. else a fresh Studio, `open -n -g -a RobloxStudio <TestBench file>` (lands on the start page);
    3. only with --via TEXT (a strict filter; fails if nothing matches): a bench process whose places were all
       opened by this owner, one containing TEXT, and idle (the Studio MCP reports Edit mode, else refused).
  * --close TAG: close just that TestBench place (same close path as --close-others: AX close, Don't Save, end the
    leftover start-page process), under the Studio lock, only if this owner opened it (owners registry), unless
    --force. Exit 1 if it is still open afterwards, 3 if refused.
  * --close-others: closes every other ~/RobloxProjects/.testbench/TestBench-* place opened by this owner (all of
    them with --force) (AX close button, then Don't
    Save in the save prompt via a brief raise + click, mouse and frontmost app restored, only after
    checking the prompt is topmost at the click point) and ends that process only when nothing but untitled /
    "Roblox Studio" start-page windows remain on it. Non-TestBench places and their processes are never touched.
Prints `title: ...` and `studio_id: ...` (the MCP id, when available).
"""
import os, shutil, subprocess, sys, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import studio_window as sw  # noqa: E402
from studio import StudioSession, studio_lock  # noqa: E402


OPEN_PANEL = "Open Roblox File"  # Studio's Cmd-O panel title


class NotFrontmost(RuntimeError):
    pass


def type_open(pid, path, start_page=False):
    """Cmd-O, (wait for the Open panel, make it key), Cmd-Shift-G, (wait for the Go-to sheet), path, Return, Return,
    (wait for the panel to go) into bench process `pid` via tools/studio-keys.swift: it activates
    that exact pid (NSRunningApplication), re-checks before every key group that this pid is frontmost (NSWorkspace),
    stops otherwise, and re-activates the previously frontmost app. (The AppleScript version ran its frontmost check
    inside `tell <process>`, where `first process whose frontmost is true` means a child of the Studio process:
    osascript -1728 "Can't get process 1 of item 1 of every process ...".)
    Raises NotFrontmost when nothing was typed (caller may retry), RuntimeError when focus was lost mid-way."""
    env = {"STUDIO_KEYS_START_PAGE": "1"} if start_page else None
    try:
        r = sw.run_helper("studio-keys", [pid, "cmd+o", "waitwin:" + OPEN_PANEL, "cmd+shift+g", "waitsheet:" + OPEN_PANEL,
                                          # the Go-to field is set through AX: typed characters race its
                                          # autocompletion, and a second Return often missed the file list
                                          "sheetvalue:" + path, "sleep:0.5", "return", "sleep:1.5",
                                          "waitwin:" + OPEN_PANEL, "press:%s|Open" % OPEN_PANEL,
                                          "gonewin:" + OPEN_PANEL], timeout=60, env=env)
    except subprocess.TimeoutExpired:
        r = None
    out = (r.stdout + r.stderr).strip() if r else "timed out"
    if r and r.returncode == 0:
        return
    if r and r.returncode == 3:
        raise NotFrontmost(out)
    # Something was typed: cancel a leftover Open panel (sheet, then panel) on that pid; do not retry blindly.
    if any(t == OPEN_PANEL and p == pid for t, *_x, p in sw.ax_windows()):
        sw.run_helper("studio-keys", [pid, "waitwin:" + OPEN_PANEL, "escape", "sleep:0.8", "escape",
                                      "gonewin:" + OPEN_PANEL], timeout=60, env=env)
    raise RuntimeError("the Open dialog sequence failed mid-way; aborted (%s)" % out)


def is_idle(pid):
    """True only if the Studio MCP reports the place in pid as being in Edit mode (not Play / Run). Anything
    unexpected (not listed, no answer, unknown text) counts as busy: fail closed."""
    import json, re
    rows = sw.ax_windows()
    names = [os.path.basename(r[0][:-len(sw.PLACE_SUFFIX)]) for r in rows if r[5] == pid and sw.is_bench_title(r[0])]
    try:
        with StudioSession(settle=3) as s:
            ok, texts, _ = s._call_once("list_roblox_studios", {}, 60)
            ids = []
            for t in texts:
                try:
                    ids += [st["id"] for st in json.loads(t).get("studios", []) if st.get("name") in names]
                except (ValueError, AttributeError, KeyError):
                    pass
            if len(ids) != len(names) or not ids:
                return False
            for sid in ids:
                ok, texts, _ = s._call_once("get_studio_state", {"studio_id": sid}, 60)
                text = " ".join(texts)
                if not ok or not re.search(r"\bedit\b", text, re.I) or re.search(r"\b(play|playing|run|running)\b",
                                                                                    text, re.I):
                    return False
            return True
    except Exception as e:  # noqa: BLE001  (fail closed)
        sys.stderr.write("[studio-open] idle check failed (%s); treating pid %s as busy\n" % (e, pid))
        return False


def mcp_id(name, timeout):
    end = time.time() + timeout
    with StudioSession(settle=3) as s:
        while time.time() < end:
            ok, texts, _ = s._call_once("list_roblox_studios", {}, 60)
            for t in texts:
                try:
                    for st in __import__("json").loads(t).get("studios", []):
                        if st.get("name") == name:
                            return st["id"]
                except ValueError:
                    pass
            time.sleep(3)
    return None


def main():
    a = sys.argv[1:]
    opt = lambda k, d=None: a[a.index(k) + 1] if k in a and a.index(k) + 1 < len(a) else d  # noqa: E731
    me = sw.caller_id(opt("--owner"))
    if a and a[0] == "--close":
        tag = opt("--close")
        if not sw.safe_tag(tag):
            sys.exit("--close TAG must match [A-Za-z0-9_-]+ (got %r)" % tag)
        t = os.path.join(sw.TESTBENCH, "TestBench-%s.rbxl" % tag) + " - Roblox Studio"
        if t not in sw.place_windows():
            print("not open:", t)
            return
        if not sw.owns(sw.load_owners(), tag, me) and "--force" not in a:
            print("REFUSED: TestBench-%s was not opened by %s (owners: %s); pass --force to close it anyway"
                  % (tag, me, sw.OWNERS))
            sys.exit(3)
        a = [tag]
        with studio_lock("studio-open close " + tag, timeout=600):
            ok = sw.close_place(t)
        print("closed:" if ok else "FAILED to close:", t)
        sys.exit(0 if ok else 1)
    if not a or a[0].startswith("-"):
        sys.exit(__doc__)
    src = os.path.abspath(a[0])
    tag = opt("--tag", os.path.splitext(os.path.basename(src))[0])
    if not sw.safe_tag(tag):
        sys.exit("--tag must match [A-Za-z0-9_-]+ (got %r)" % tag)
    timeout = float(opt("--timeout", 180))
    dest = os.path.join(sw.TESTBENCH, "TestBench-%s.rbxl" % tag)
    title = dest + " - Roblox Studio"
    if not os.path.exists(src):
        sys.exit("no such file: " + src)

    if title in sw.place_windows():
        print("reusing open window (in-memory state kept)")
    else:
        os.makedirs(sw.TESTBENCH, exist_ok=True)
        if os.path.abspath(src) != dest:
            shutil.copyfile(src, dest)
        with studio_lock("studio-open " + tag, timeout=600):
            rows = sw.ax_windows()
            via = opt("--via")
            kind, host = sw.pick_host(rows, sw.proc_args, sw.load_owners(), me, is_idle, via)
            if kind == "none":
                sys.exit("--via %r: no idle bench process whose places were all opened by %s matches; nothing typed"
                         % (via, me))
            if kind == "launch":
                # A fresh Studio process (-n: never hand the file to a running one) lands on the start page.
                subprocess.run(["open", "-n", "-g", "-a", "RobloxStudio", dest], timeout=30)
                end = time.time() + 120
                while time.time() < end and host is None and title not in sw.place_windows():
                    time.sleep(3)
                    sp = sw.bench_start_page_pids(sw.ax_windows(), sw.proc_args)
                    host = sp[0] if sp else None
                time.sleep(3)
                if title in sw.place_windows():
                    host = None  # Studio loaded the file by itself after all
                elif host is None:
                    sys.exit("launched Studio but no start-page process showed up within 120 s; nothing typed")
            start_page = kind in ("start_page", "launch")
            hosts = [host] if host is not None else []
            for attempt in range(3 if hosts else 0):
                try:
                    front = sw.frontmost()
                except (RuntimeError, subprocess.TimeoutExpired) as e:
                    # studio-keys.swift still re-activates the app that was frontmost when it started (its defer)
                    sys.stderr.write("[studio-open] could not read the frontmost app (%s); relying on the Swift "
                                     "helper's focus restore\n" % e)
                    front = None
                try:
                    type_open(hosts[0], dest, start_page)
                    sw.record_owner(tag, me)
                    break
                except NotFrontmost:
                    sys.stderr.write("[studio-open] Studio did not stay frontmost; retrying\n")
                finally:
                    sw.restore(front)
                time.sleep(5)
            else:
                if hosts:
                    sys.exit("FAILED: could not keep the bench Studio process frontmost to type into it")
            if not hosts:
                sw.record_owner(tag, me)  # Studio opened the launched file by itself
            end = time.time() + timeout
            while time.time() < end and not (os.path.exists(dest + ".lock") and title in sw.place_windows()):
                time.sleep(2)
            if title not in sw.place_windows():
                sys.exit("timed out waiting for the window %r (open windows: %s)" % (title, sw.place_windows()))
        # Dialogs (Lighting Technology Migration ...) show up a few seconds after the window: poll ~20 s.
        pid = sw.pid_of(title)
        end = time.time() + 20
        while time.time() < end:
            for d in sw.dismiss_dialogs(pid):
                print("dismissed dialog:", d)
            time.sleep(2)
    stray = sw.stray_windows(title)
    if stray:
        sys.exit("FAILED: dialogs still open on the place: %s" % stray)

    if "--close-others" in a:
        owners = sw.load_owners()  # only places this owner opened; other threads' benches are left alone
        others = [t for t in sw.place_windows() if t != title and "/.testbench/TestBench-" in t
                  and (sw.owns(owners, sw.tag_of(t), me) or "--force" in a)]
        if others:
            with studio_lock("studio-open close-others", timeout=600):
                for t in others:
                    print("closed:" if sw.close_place(t) else "FAILED to close:", t)

    print("title:", title)
    if "--no-mcp" not in a:
        sid = mcp_id(os.path.basename(dest), min(timeout, 90))
        print("studio_id:", sid or "(not listed by the Studio MCP yet)")


if __name__ == "__main__":
    main()
