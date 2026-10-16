# Agent playtests on the Roblox TEST server

Agents can play a branch's build on a real Roblox server and take screenshots, without touching the
public game. The pieces:

| Piece | What it does |
| --- | --- |
| `deploy/test-target.json` | universe and place of the private TEST experience (the live one is `deploy/target.json`) |
| `src/shared/TestEnv.luau` | `TEST_UNIVERSE_ID` and `isTest()`, the security boundary |
| `src/server/TestBridge.luau` | server bridge: MessagingService topic `TestBridge` in, MemoryStore sorted map `TestBridge` out |
| `src/client/TestBridge.client.luau` | client bridge: panels, camera, hiding the UI (RemoteEvent `ReplicatedStorage.TestBridgeClient`) |
| `tools/roblox_play.py` | join, run bridge commands, screenshot, keys/clicks, quit, player lock |
| `tools/roblox-player.swift` | Roblox Player window list, key presses and clicks (compiled once into `~/.cache/chadtycoon/`) |

## Security boundary

`TestEnv.isTest()` is true only when `game.GameId == TEST_UNIVERSE_ID` and that id is neither 0
nor the live universe. On the live game and in unpublished Studio (GameId 0) the bridge creates
nothing and subscribes to nothing. Commands come from a fixed table (no `loadstring`), and only
the Open Cloud API key holder can publish to the test universe. The client's Studio-only
`UiPreview` capture hook (Main.client) is also turned on in the TEST experience, because the `ui`
command uses it.

Once the test experience exists, set `TEST_UNIVERSE_ID` in `src/shared/TestEnv.luau` to its
universe id. Until then `tools/roblox_play.py` stops with "test experience not configured yet".

## Workflow

```sh
git push -u origin my-branch                         # never main: main publishes to live
gh workflow run test-env.yml --ref my-branch         # publishes the branch to the TEST place
python3 tools/roblox_play.py join                    # takes the lock, launches the player, waits for ping
python3 tools/roblox_play.py cmd state
python3 tools/roblox_play.py cmd teleport '{"spot":"plaza"}'
python3 tools/roblox_play.py cmd hideui '{"hidden":true}'
python3 tools/roblox_play.py cmd camera '{"preset":"spot:plaza"}'
python3 tools/roblox_play.py shot /tmp/shots/plaza.png   # half size by default (--scale 0.5)
python3 tools/roblox_play.py cmd camera '{"preset":"reset"}'
python3 tools/roblox_play.py quit                    # closes the player, releases the lock
```

`join` prints the server's `jobId` and `placeVersion`: check `placeVersion` against the version
the workflow published, so you know you are looking at your build. A server started before the
publish keeps the old version; quit and join again (or restart the test servers) if it is stale.

## Bridge commands (`cmd <name> [json-args]`)

The result is printed as `{ok, result | error, cmd, jobId, placeVersion, at}`; exit 1 when
`ok` is false or nobody answered within `--timeout` (20 s). `--user ID` targets another player
(default the owner, 11718681576).

| Command | Args | Does |
| --- | --- | --- |
| `ping` | | userId, players in the server, whether the tycoon session is loaded |
| `state` | | cash, income, production, plot index, passes, active mode, position, every scalar profile field (tables as `name#` counts) |
| `cash` / `give` | `{amount}` | adds cash via `Tycoon.grantMoney` (the game's own path, saved like real cash) |
| `teleport` | `{spot}` or `{pos:[x,y,z], look?:[x,y,z]}` | moves the character (quits a running mini-game unless `stopMode:false`) |
| `mode` | `{id, options?}` | enters a mini-game the way its gate does (`GameModes.start` with teleport) |
| `stopmode` | | quits the current mini-game run |
| `ui` | `{panel}` | opens a window or popup on the client (opening an open window closes it; `close` closes all) |
| `camera` | `{preset}` or `{pos, look, fov?}` | holds the camera there every frame until `{"preset":"reset"}` |
| `hideui` | `{hidden?}` | hides or shows every ScreenGui and the core UI (toggles without args) |
| `list` | | all of the above, live from the server |

Spots: `hub`, `plot` (your own), `plaza` (GAME MODES arrival), `gates`, `mog` (stage centre),
`cardio` (warm-up lobby), `shake`, `pose`, `bowling` (island lobbies). Raw spots do not start a
mode; use `mode` with `parkour`, `mog`, `cardio`, `shake`, `pose` or `bowling` for the real entry.

Panels: `Shop`, `Shop,Passes`, `Shop,Cosmetics`, `Shop,Cash`, `Shop,Aura`, `Index`, `Ranking`,
`Settings`, `Modes`, `Maps`, `Daily`, popups `starter`, `gift`, `surge`, `away`, `tutorialdone`,
`reward,<tier>`, `rewards,<from>,<to>`, `crate,<Rarity>,<tier>`, and `close`.

Camera presets: `front` (facing the avatar), `back` (over the shoulder), `overhead`, all
following the character (`distance` changes how far); `plot` (your plot from above the
entrance); `spot:<name>` (a spot framed from behind and above); `reset`.

## Input and screenshots

- `shot <out.png> [--scale 0.5]` captures only the Roblox Player window (no shadow, works behind
  other windows) and downsizes it with `sips`. Read shots at half size or smaller.
- `key <step>...` brings the player to the front, types, then gives focus back: `w:1.5` holds W
  for 1.5 s, `space`, `escape`, `return`, arrows, `text:abc`, `sleep:0.5`.
- `click <x> <y>` clicks a point in window coordinates (points; a half-size shot's pixels are
  close to points on a Retina screen).

Keys and clicks move the real mouse and focus for a moment. Prefer bridge commands.

## Limits

- One Roblox Player on this Mac. The lock `/tmp/roblox-player.lock` is held from `join` to
  `quit`; `cmd`, `shot`, `key` and `click` refuse without it. `lock status`, `lock acquire
  [--wait SEC]`, `lock release [--force]`. Owner = `--owner`, `$ROBLOX_PLAY_OWNER`, else your git
  worktree. A lock idle for 20 minutes is stale and the next `join` takes it. Always `quit`.
- `join --wait 600` queues for the lock instead of failing at once.
- Robux purchases cannot be tested here: prompts in the TEST experience are not real sales. Use
  `cash` to test what money buys.
- Messages reach every TEST server; the one holding the target player answers. If the player is
  in no server, `cmd` times out.
- MessagingService and MemoryStore have rate limits: keep to a few commands per second.
- Never launch the live place (97313994892728). `join --target live` is refused, and so is a
  test target that points at the live game.
- Roblox shows a "Ready to playtest?" notice in the top-left corner of every private experience. It is part
  of the Roblox client, so `hideui` can't remove it, and `click` only works while the Player is the frontmost
  app (macOS won't let a background tool bring it forward). Leave it in the shot, or crop it out.
- A cold-started Player ignores the join link and opens its home screen. `join` therefore starts the app first
  and then re-sends the link every 60 s until the bridge answers (verified 2026-10-16).
