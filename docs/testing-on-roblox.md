# Testing on real Roblox servers

Unit tests (`lune run tests/run`, part of `scripts/check.sh`) run the game's modules in Lune with stubs. The
cloud tests run the **published place on a real Roblox server** instead, through Open Cloud
[Luau Execution](https://create.roblox.com/docs/cloud/reference/features/luau-execution), against a separate
**private test experience**. Nothing here touches the public game.

| | |
|---|---|
| Test experience | `deploy/test-target.json` (`universeId`/`placeId` are `null` until the experience exists) |
| Live game | `deploy/target.json` (PUBLIC; only `deploy.yml` publishes there, on pushes to `main`) |
| Test publish log | `deploy/test-history.json` (git-ignored; CI uploads it in the `test-env-<sha>` artifact) |
| Cloud tests | `tests/cloud/*.luau`, harness `tests/cloud/_harness.luau`, runner `tools/cloud_test.py` |
| Workflows | `ci.yml` job `roblox` (every PR), `test-env.yml` ("Test environment") |

While the test ids are `null`, every `--target test` command and both workflows print
"test experience not configured yet" and exit 0, so CI stays green. To switch it on: create the private
experience, put its universe and start-place ids in `deploy/test-target.json`, add the experience to the API
key (scopes below), merge.

## What runs where

1. **Every pull request** (and every push to a branch other than `main`): `ci.yml` job `check` as before, then
   job `roblox` (needs `check`): `scripts/build-release.sh`, `tools/deploy.py publish --target test --saved`,
   then `tools/cloud_test.py --target test --version <that version>`. A **Saved** version never goes live, so
   two PRs testing at once do not overwrite each other's server: each task runs the exact version it
   published. The job is part of the workflow named CI, so a failing cloud test blocks auto-merge.
   Fork PRs get no secrets: the job skips with a notice. A branch with an open PR runs it twice (push and
   pull_request events), which only costs quota.
2. **Branch `test`** (push) or **`gh workflow run`**: `test-env.yml` publishes a **Published** version to the
   test experience, sets Max Players to 6, restarts its servers (`restart-servers`) so new joins get the build,
   and runs the cloud tests against it. Runs never overlap (concurrency group `test-env`, queued, not
   cancelled). Put any branch on the test server:

   ```sh
   gh workflow run test-env.yml --repo B0gsto/chad-tycoon --ref my-branch
   gh run watch --repo B0gsto/chad-tycoon "$(gh run list --repo B0gsto/chad-tycoon --workflow test-env.yml --limit 1 --json databaseId -q '.[0].databaseId')"
   ```

   or `git push origin my-branch:test --force` (the `test` branch is a disposable pointer).

## Local commands

```sh
scripts/build-release.sh                                    # checks + build/ChadAuraTycoon.rbxl
python3 tools/deploy.py check --target test                 # pre-flight (add --offline to skip API reads)
python3 tools/deploy.py publish --target test --saved       # last line: VERSION=<n>
python3 tools/cloud_test.py --target test --version <n>     # all tests/cloud/*.luau in one task
python3 tools/cloud_test.py tests/cloud/boot.luau           # one file, latest Published test version
python3 tools/cloud_test.py --per-file                      # one task per file (easier to read, slower)
python3 tools/cloud_test.py --print-script > /tmp/t.luau    # the exact Luau that would be sent, no API call
python3 tools/deploy.py publish --target test               # Published: what players of the test place get
python3 tools/deploy.py restart-servers --target test       # running test servers reload the latest version
```

`DEPLOY_TARGET=test` makes `--target test` the default for `deploy.py`. `restart-servers --target live`
(players are moved) is refused without `--yes`; `cloud_test.py --target live` too.

## How a cloud test run works

`tools/cloud_test.py` joins `_harness.luau` and the test files into one script (each file wrapped in
`T.file(name, function() ... end)`, preceded by `META` = target, version, git head and the
`assets/models/*.rbxm` names) and sends it as one task:

- `POST /cloud/v2/universes/{u}/places/{p}/versions/{v}/luau-execution-session-tasks` with
  `{"script": ..., "timeout": "300s"}` (without `/versions/{v}`: latest Published version);
- polls `GET /cloud/v2/{task.path}` every 3 s until `COMPLETE`, `FAILED` or `CANCELLED` (gives up after
  `--timeout`, default 420 s including queueing);
- prints the server log (`GET /cloud/v2/{task.path}/logs`, `messages`): every `[cloud-test] PASS/FAIL/SKIP` line;
- reads the summary `{passed, failed, skipped, failures, skips, seconds}` from the first entry of `output.results`.

Exit 1 on any failed test, task error, timeout or HTTP error (status and body printed, never headers).

### Writing a test

```lua
--!nocheck
local ReplicatedStorage = game:GetService("ReplicatedStorage")

T.test("something observable", function()
	local thing = T.waitFor(function()
		return ReplicatedStorage:FindFirstChild("Remotes")
	end, 30)
	T.ok(thing, "Remotes missing")          -- T.ok(cond, msg) returns cond
	T.eq(#thing:GetChildren(), 5, "remote count")
	if T.meta.target ~= "test" then
		T.skip("writes data")               -- counts as skipped, not failed
	end
end)
```

Keep tests fast (one task has 300 s for everything) and read-only on shared state; clean up anything written.
Test what the running server shows (instances, DataStores, MarketplaceService) or require modules
(`ServerScriptService.Server.DataService`, `ReplicatedStorage.Shared.*`); do not restructure game code for it.

Current files: `boot.luau` (Main.server ran: remotes, `Workspace.Map` with Plot1..6, no errors in the server
log), `assets.luau` (every `.rbxm` in `ReplicatedStorage.AssetModels` with mesh data, `AssetModels.clone`),
`datastore.luau` (DataService load/save round trip with session lock for a fake negative user id, key removed
afterwards; test target only), `economy.luau` (Economy curve sanity; every pass and developer product in
`Theme.Monetization` exists, is for sale and costs what the shop shows).

## Limits

- **No players.** A Luau Execution server has no clients: no joins, no characters, no remotes from a client,
  no UI. Test server state and modules, not gameplay; play the test server for that (below).
- **Place scripts don't run.** A Luau Execution server loads the place but never starts its Scripts (checked
  on 2026-10-16: not even a fresh clone of `Server.Main` runs). The start-up therefore lives in
  `src/server/Boot.luau`: `Main.server.luau` calls `Boot.start()`, and `boot.luau` calls the same function.
  Keep new start-up steps in `Boot.start()`, or the cloud tests won't see them.
- **Purchases** cannot be tested: no player can be prompted, and receipts only come from real purchases.
  `economy.luau` checks the ids and prices; `ProcessReceipt` stays covered by the Lune unit tests.
- **DataStores** are the test universe's own (empty at first, separate from live); MessagingService and
  MemoryStore too.
- **Quotas** (per API key owner): 5 task creations a minute (the runner paces at 4 and backs off on HTTP 429),
  200 task reads a minute, 45 log reads a minute; 10 tasks at once per place; one task runs at most 5 minutes
  and returns at most 4 MB. Publishing: 30 a minute. Restart servers: 30 a minute.
- **API key scopes** for the test experience: `universe-places:write` (publish),
  `universe.place.luau-execution-session:read` and `:write` (tests), `universe:write` (restart-servers);
  `universe.place:write` for `server-size` (the test workflow only warns when it is missing).

## Playing the test server (agents)

docs/agent-playtest.md covers it.
