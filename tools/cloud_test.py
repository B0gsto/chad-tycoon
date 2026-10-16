#!/usr/bin/env python3
"""Run the tests/cloud/*.luau integration tests inside a real Roblox server through Open Cloud Luau Execution.

usage:
  tools/cloud_test.py [--target test|live] [--version N] [--per-file] [--timeout S] [--print-script] [FILE ...]

The test files (default: every tests/cloud/*.luau except _harness.luau) are joined behind tests/cloud/_harness.luau
into ONE Luau script (one task: the create call is limited to 5 a minute per key owner), each file wrapped as
T.file(name, function() ... end), ending in `return T.finish()`. --per-file sends one task per file instead
(paced at 4 a minute). The script runs on a fresh server of the target place (no players):

  POST /cloud/v2/universes/{u}/places/{p}[/versions/{N}]/luau-execution-session-tasks   {"script", "timeout"}
  GET  /cloud/v2/{task.path}            until state is COMPLETE, FAILED or CANCELLED (gives up after --timeout)
  GET  /cloud/v2/{task.path}/logs       the server's output (print/warn/error lines), printed as is

Without --version the latest Published version runs. CI publishes a Saved version (tools/deploy.py publish
--target test --saved prints VERSION=<n>) and passes it here, so concurrent pull requests never overwrite each
other's build. The task returns {passed, failed, skipped, failures, skips, seconds} (tests/cloud/_harness.luau).

Exit 0 = every test passed (skips allowed) or the test experience is not configured yet (notice);
1 = a failed test, a task error, a timeout or an HTTP error (status and response body printed; never headers).
--target live runs read-only tests against the PUBLIC game and needs --yes (the DataStore test skips itself there).
The API key comes from $ROBLOX_API_KEY, else ~/RobloxProjects/.roblox-api-key (tools/assets.py)."""
import argparse, glob, json, os, subprocess, sys, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import assets  # noqa: E402  (key, HTTP with 429 retries, Luau Execution pacing)
import deploy  # noqa: E402  (targets: deploy/target.json and deploy/test-target.json)

ROOT = assets.ROOT
TESTS = os.path.join(ROOT, "tests", "cloud")
HARNESS = os.path.join(TESTS, "_harness.luau")
TASK_TIMEOUT_S = 300  # Roblox's maximum for one task
POLL_S = 3


def http_json(method, path, body=None):
    """(status, parsed body or text). assets._http already retries 429 (and 5xx on GET) with backoff."""
    data = json.dumps(body).encode() if body is not None else None
    status, raw = assets._http(method, path, data, "application/json" if data else None, timeout=60)
    text = raw.decode(errors="replace") if isinstance(raw, bytes) else str(raw)
    try:
        return status, json.loads(text)
    except ValueError:
        return status, text


def fail(msg):
    print(f"ERROR: {msg}", flush=True)
    if os.environ.get("GITHUB_ACTIONS"):
        print(f"::error title=Cloud tests::{msg.splitlines()[0][:300]}")
    return 1


def test_files(args):
    files = args or sorted(f for f in glob.glob(os.path.join(TESTS, "*.luau")) if os.path.basename(f) != "_harness.luau")
    for f in files:
        if not os.path.isfile(f):
            raise SystemExit(f"{f}: no such test file")
    return [os.path.abspath(f) for f in files]


def meta(target, version):
    models = sorted(os.path.splitext(n)[0] for n in os.listdir(os.path.join(ROOT, "assets", "models")) if n.endswith(".rbxm"))
    git = subprocess.run(["git", "-C", ROOT, "rev-parse", "--short", "HEAD"], capture_output=True, text=True).stdout.strip()
    return {"target": target, "version": version, "git": git or "unknown", "assetModels": models}


def build_script(files, info):
    blob = json.dumps(info)
    if "]==]" in blob:
        raise SystemExit("meta JSON contains ]==]")
    parts = [f'local META = game:GetService("HttpService"):JSONDecode([==[{blob}]==])\n']
    with open(HARNESS) as f:
        parts.append(f.read())
    for path in files:
        with open(path) as f:
            body = f.read()
        parts.append(f"\nT.file({json.dumps(os.path.basename(path))}, function()\n{body}\nend)\n")
    parts.append("\nreturn T.finish()\n")
    return "".join(parts)


def create_task(u, p, version, script):
    base = f"/cloud/v2/universes/{u}/places/{p}" + (f"/versions/{version}" if version else "")
    body = {"script": script, "timeout": f"{TASK_TIMEOUT_S}s"}
    for attempt in range(5):
        assets._pace_luau()
        status, doc = http_json("POST", f"{base}/luau-execution-session-tasks", body)
        if status != 429:
            break
        wait = 20 + attempt * 20  # 5 creates a minute per key owner, shared with other runs
        print(f"HTTP 429 creating the task; waiting {wait} s", flush=True)
        time.sleep(wait)
    if status != 200 or not isinstance(doc, dict) or "path" not in doc:
        hint = (" (key needs universe.place.luau-execution-session:write on this experience)" if status in (401, 403)
                else " (no such place version?)" if status == 404 else "")
        raise RuntimeError(f"create task: HTTP {status}: {str(doc)[:2000]}{hint}")
    return doc


def wait_task(doc, timeout):
    path, end = doc["path"], time.time() + timeout
    last = None
    while doc.get("state") not in ("COMPLETE", "FAILED", "CANCELLED"):
        if doc.get("state") != last:
            last = doc.get("state")
            print(f"  task state {last}", flush=True)
        if time.time() > end:
            raise TimeoutError(f"task {path} still {doc.get('state')} after {timeout} s")
        time.sleep(POLL_S)
        status, doc = http_json("GET", f"/cloud/v2/{path}")
        if status != 200 or not isinstance(doc, dict):
            raise RuntimeError(f"poll {path}: HTTP {status}: {str(doc)[:1000]}")
    return doc


def print_logs(path):
    token, lines = "", 0
    for _ in range(20):
        q = "?maxPageSize=10000" + (f"&pageToken={token}" if token else "")
        status, doc = http_json("GET", f"/cloud/v2/{path}/logs{q}")
        if status != 200 or not isinstance(doc, dict):
            print(f"  (logs unavailable: HTTP {status}: {str(doc)[:500]})")
            return
        for chunk in doc.get("luauExecutionSessionTaskLogs") or []:
            for m in chunk.get("messages") or []:
                print(f"  | {m}")
                lines += 1
        token = doc.get("nextPageToken") or ""
        if not token:
            break
    if not lines:
        print("  (no log lines)")


def run_task(u, p, version, script, label, timeout):
    print(f"== {label}: {len(script)} bytes of Luau -> universe {u} place {p} "
          f"{'version ' + str(version) if version else 'latest Published version'}", flush=True)
    t0 = time.time()
    doc = create_task(u, p, version, script)
    print(f"  task {doc['path']}", flush=True)
    try:
        doc = wait_task(doc, timeout)
    finally:
        print("  server log:")
        print_logs(doc["path"])
    print(f"  finished {doc.get('state')} in {time.time() - t0:.0f} s", flush=True)
    if doc.get("state") != "COMPLETE":
        raise RuntimeError(f"task {doc.get('state')}: {json.dumps(doc.get('error') or {})[:2000]}")
    results = (doc.get("output") or {}).get("results") or []
    summary = results[0] if results else None
    if not isinstance(summary, dict) or "failed" not in summary:
        raise RuntimeError(f"task returned no test summary: {json.dumps(doc.get('output'))[:1000]}")
    return summary


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("files", nargs="*", help="test files (default tests/cloud/*.luau)")
    ap.add_argument("--target", choices=sorted(deploy.TARGETS), default="test", help="test (default) or live")
    ap.add_argument("--version", type=int, help="place version to run (default: latest Published)")
    ap.add_argument("--per-file", action="store_true", help="one task per test file (slower: 4 tasks a minute)")
    ap.add_argument("--timeout", type=int, default=420, help="seconds to wait for each task, queueing included")
    ap.add_argument("--print-script", action="store_true", help="print the assembled Luau and exit (no API call)")
    ap.add_argument("--yes", action="store_true", help="required for --target live")
    a = ap.parse_args()

    files = test_files(a.files)
    if a.print_script:
        sys.stdout.write(build_script(files, meta(a.target, a.version)))
        return 0
    deploy.TARGET_NAME = a.target
    deploy.TARGET, deploy.HISTORY = deploy.TARGETS[a.target]
    if not deploy.configured():
        return 0
    if a.target == "live" and not a.yes:
        raise SystemExit("refusing to run tests on the PUBLIC game's servers without --yes")
    if not assets.key_source():
        return fail(f"no Roblox API key: set ${assets.KEY_ENV} or create {assets.KEY_PATH}")
    _, u, p = deploy.load_target()
    info = meta(a.target, a.version)
    batches = [[f] for f in files] if a.per_file else [files]
    total = {"passed": 0, "failed": 0, "skipped": 0, "failures": [], "skips": []}
    errors = []
    for batch in batches:
        label = os.path.basename(batch[0]) if len(batch) == 1 else f"{len(batch)} test files"
        try:
            s = run_task(u, p, a.version, build_script(batch, info), label, a.timeout)
        except (RuntimeError, TimeoutError, OSError) as e:
            errors.append(f"{label}: {e}")
            print(f"  ERROR {e}", flush=True)
            continue
        for k in ("passed", "failed", "skipped"):
            total[k] += int(s.get(k) or 0)
        total["failures"] += list(s.get("failures") or [])
        total["skips"] += list(s.get("skips") or [])

    print(f"\ncloud tests [{a.target}]: {total['passed']} passed, {total['failed']} failed, {total['skipped']} skipped"
          + (f", {len(errors)} task error(s)" if errors else ""))
    for s in total["skips"]:
        print(f"  skipped: {s}")
    for f in total["failures"]:
        print(f"  FAILED: {f}")
    for e in errors:
        print(f"  TASK ERROR: {e}")
    summary_file = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary_file:
        with open(summary_file, "a") as f:
            f.write(f"### Cloud tests ({a.target}, version {a.version or 'latest'}): {total['passed']} passed, "
                    f"{total['failed']} failed, {total['skipped']} skipped, {len(errors)} task error(s)\n")
            for line in total["failures"] + errors:
                f.write(f"- `{line.splitlines()[0][:300]}`\n")
    if total["failed"] or errors:
        return fail(f"{total['failed']} failed test(s), {len(errors)} task error(s)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
