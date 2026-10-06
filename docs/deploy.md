# Deploying Chad Aura Tycoon

The game is published to its own experience through Open Cloud:

| | |
|---|---|
| Universe | `10769596890` (Chad Aura Tycoon, start place) |
| Place | `97313994892728` |
| Target file | `deploy/target.json` |
| Publish log | `deploy/history.json` (one entry per publish: version, type, UTC time, file, size, sha256, git head) |
| API key | `$ROBLOX_API_KEY` when set (CI), else `~/RobloxProjects/.roblox-api-key` (mode 600; sent as `x-api-key`, never printed) |
| CI/CD | `.github/workflows/ci.yml` (checks) and `.github/workflows/deploy.yml` (publish on push to `main`): see [CI/CD](#cicd) |

## Release

```sh
scripts/build-release.sh            # scripts/check.sh (fmt, lint, types, tests), then build/ChadAuraTycoon.rbxl
python3 tools/deploy.py check       # read-only pre-flight; exit 1 on a hard problem
python3 tools/deploy.py publish     # new Published version: live for every NEW server
```

- `publish --saved` uploads a **Saved** version instead: it appears in version history but does not go live.
  Use it once to prove the key's write permission without shipping.
- `publish` refuses a file built more than 30 minutes ago (`--force` overrides) and a place the API would
  reject (see below). It prints the new version number and appends it to `deploy/history.json`.
- `publish --file build/ChadAuraTycoon.rbxlx` also works (`application/xml`), but the release format is the
  binary `.rbxl` (`application/octet-stream`, about 1.2 MB against 3.2 MB for the XML build), the same format
  the TameATitan pipeline publishes.
- Servers that are already running keep the old version until they close. To move everyone over:
  Creator Dashboard > the experience > Places > ... > **Restart servers for updates** (players are moved).

Endpoint: `POST https://apis.roblox.com/universes/v1/{universeId}/places/{placeId}/versions?versionType=Published|Saved`,
body = the place file, response `{"versionNumber": N}`. Key permission: **universe-places: write** with this
experience added. Rate limit 30/min per key owner. No size limit is documented for this endpoint (the general
place upload ceiling is 100 MB; our file is ~1.2 MB).

The API refuses places that contain unions (`PartOperation`), `SurfaceAppearance`, `EditableImage`,
`EditableMesh` or wrap instances (`WrapLayer`/`WrapTarget`): those must be published from Studio.
`deploy.py check` scans the built place for them (today: none) and checks that
`ReplicatedStorage.AssetModels` holds one model per `assets/models/*.rbxm` with its MeshParts.

### What `check` proves

- The key (`$ROBLOX_API_KEY`, or else the key file) exists and is not empty; the file is not readable by other
  accounts.
- `deploy/target.json` is valid; the place file has a Roblox header, parses with Lune, its size and age.
- The key can **read** the universe and the place (`GET /cloud/v2/universes/{u}` and `.../places/{p}`); it
  also prints the place's `serverSize` (Max Players).
- It cannot prove the **write** permission: Open Cloud has no read-only call for `universe-places:write`.
  The first publish confirms it (`publish --saved` if you want to confirm without going live). HTTP 401/403
  on publish means: Creator Hub > Open Cloud > API Keys > the key > add *Chad Aura Tycoon* under
  **universe-places** with **Write**. A key also expires after 60 days without use.

## CI/CD

GitHub Actions on `B0gsto/chad-tycoon` (private repo):

| Trigger | Workflow | What runs |
|---|---|---|
| Pull request; push to any branch except `main` | `ci.yml` (CI) | `tools/ci-install-tools.sh`, `scripts/check.sh`; uploads `build/ChadAuraTycoon.rbxlx` as artifact `place-<sha>` (14 days). A newer push to the same ref cancels the running check. |
| Push to `main` (merging a PR included) | `deploy.yml` (Deploy) | the same toolchain, `scripts/build-release.sh` (all checks + `build/ChadAuraTycoon.rbxl`), `tools/deploy.py publish` (Published = live for new servers), then `tools/deploy.py server-size 6`. Uploads the `.rbxl` and `deploy/history.json` as artifact `release-<sha>` (90 days). |
| Actions > Deploy > **Run workflow** | `deploy.yml` | same, with `version_type` = `published` or `saved`. |

- A failing check stops the publish: nothing is uploaded unless `scripts/check.sh` passes.
- Deploys never overlap (concurrency group `deploy`, not cancelled): a second push to `main` waits for the
  running publish, then publishes its own build.
- Toolchain: Rojo 7.7.0, Lune 0.10.5, selene 0.31.0, StyLua 2.5.2, luau-lsp 1.70.0, pinned with sha256 sums
  in `tools/ci-install-tools.sh`; local development uses the same pins from `rokit.toml` (bump both together).
- **Max Players**: after a live publish the job runs `tools/deploy.py server-size 6`, which reads the place's
  `serverSize` and only PATCHes it when it is not 6, then reads it back. This needs the key's
  **universe.place: write** scope; without it the step fails with HTTP 401/403 after the publish succeeded.
- `deploy/history.json` in CI is written on the runner only and uploaded in the `release-<sha>` artifact; the
  job has read-only repository access and does not commit it back. Local publishes still append to the
  committed file.

### The one secret

```sh
gh secret set ROBLOX_API_KEY --repo B0gsto/chad-tycoon < ~/RobloxProjects/.roblox-api-key
```

The key reaches only the publish step, as the environment variable `ROBLOX_API_KEY`
(`tools/assets.py` prefers it over the key file). GitHub masks it in logs and the tools never print it or
request headers. Without the secret the Deploy job fails in its first step with "Repository secret
ROBLOX_API_KEY is not set" (CI checks do not need it). After rotating the key in Creator Hub, run the same
command again.

### Saved (not live) deploy

GitHub > Actions > **Deploy** > Run workflow > branch `main`, `version_type` = `saved`
(or `gh workflow run deploy.yml --repo B0gsto/chad-tycoon -f version_type=saved`). The version appears
in the place's version history but players do not get it; Max Players is left alone. Locally:
`python3 tools/deploy.py publish --saved`.

### Skipping a deploy

Put `[skip deploy]` in the commit message of the commit that lands on `main` (the head commit of the
push; for a merge, edit the merge commit message). The checks still run if you push to another branch
first; `[skip ci]` skips every workflow, checks included.

### Cost

Actions minutes on a private repo count against the account's monthly free quota (2,000 min on GitHub
Free; Linux minutes count 1x). One CI run takes a few minutes; a deploy run about as long plus the upload.

## Roll back

1. **Creator Dashboard** > Creations > Chad Aura Tycoon > Places > the place > **Version History** >
   pick the previous version > **Restore** (or in Studio: File > Version History). Then restart servers.
2. Or republish an older build: `git revert` the bad commit and push to `main` (CI publishes the
   reverted tree), or download the `release-<sha>` artifact of an older Deploy run and publish it locally with
   `python3 tools/deploy.py publish --file ChadAuraTycoon.rbxl --force` (`--force` because the file is older
   than 30 minutes), or check out that commit, `scripts/build-release.sh`, then `python3 tools/deploy.py publish`.
   `deploy/history.json` (and, for CI publishes, the run's `release-<sha>` artifact and step summary) has the
   sha256 and git head of every publish, so you can tell which build a version number was.
3. A restore by hand does not stop the next push to `main` from publishing again: fix or revert on `main`
   before pushing.

## Pre-flight checklist (experience settings the place file cannot set)

Status read through Open Cloud on 2026-10-06: universe **PUBLIC**, all platforms on, voice chat on,
`ageRating` unspecified, place `serverSize` **50**. A Published version therefore goes straight to players.

1. **Max Players = 6** (Creator Dashboard > Places > the place > Configure > Server Size, or Studio Game
   Settings > Places). The map has 6 plots; a 7th player is kicked with "This server is full".
   `Players.MaxPlayers` in the place file is not used: live servers take the place's configured server
   size. `python3 tools/deploy.py server-size` reads it (`GET /cloud/v2/universes/{u}/places/{p}`, field
   `serverSize`); `server-size 6` sets it (`PATCH ...?updateMask=serverSize` with `{"serverSize": 6}`, scope
   **universe.place: write**) and reads it back. The Deploy workflow runs `server-size 6` after every live publish.
2. **Avatar type R15** (Studio > Game Settings > Avatar, or the Avatar Settings window). The intro cutscene
   clones the player's own character as the hero and needs an R15 rig; with R6 (or "Player choice" and an
   R6 player) it falls back to the part-built hero. Open Cloud has no endpoint to read this setting.
3. **Maturity & Compliance questionnaire** (Creator Dashboard > Audience): `ageRating` is still unspecified.
   Declare the **paid random items** (crates; odds are shown in the crate panel). Unrated experiences get
   restricted discovery/access.
4. **Icon and thumbnails** (`marketing/`, `preview/screenshots/`).
5. Optional: turn off platforms the UI was not tested on (console, VR) and voice chat if not wanted.

Not needed on live servers:

- *Enable Studio Access to API Services* only affects Studio; live servers always have DataStores
  (`DataService` kicks a player whose profile cannot load rather than overwrite it).
- HTTP requests: off is fine (`HttpService` is only used for `GenerateGUID`).
- Third-party sales: not needed. Every pass and product in `Theme.Monetization` belongs to this universe
  (24 ids set, none 0).
