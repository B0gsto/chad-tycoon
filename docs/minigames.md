# Solo mini-games: SHAKE CATCH, POSE COPY, DUMBBELL BOWL

Three solo modes on plaza gates 4-6. The foundation (catalog entries, gates, arenas, stub
server modes, client stubs, saves, tests) is in place; each mode's builder fills in its own
files only.

| Mode | id | Gate slot | Gate colour | Arena (world module) | Arena centre (floor top) |
| --- | --- | --- | --- | --- | --- |
| SHAKE CATCH | `shake` | 4 (south edge, west) | Pink | `World/ShakeArena.luau` | (7000, 6, -7000) |
| POSE COPY | `pose` | 5 (north edge) | Blue | `World/PoseStage.luau` | (0, 6, -10000) |
| DUMBBELL BOWL | `bowling` | 6 (south edge, east) | RedOrange | `World/BowlingLane.luau` | (-7000, 6, -7000) |

Each arena is its own space: far out at sea, past the fog (Lighting FogEnd 4000) as seen from
the hub, the Mog stage (0, 6, 400), the Cardio track (-1296, 20, 1150) and the other arenas,
so none of them clutters the map. The hub's ocean only reaches about 3000 studs, so every
arena builds its own sea tile and horizon scenery around itself. `tests/minigames.luau`
keeps them out of sight of each other. The size in `XRules.ARENA` covers the lobby and the
play area together.

## Lobby first, then the game

A gate never drops the player straight into a game. Every run goes:

`lobby` -> `countdown` (3, 2, 1) -> `play` -> `results` -> back to `lobby`

- **Entry** (gate walk-in or "ModeStart"): teleport to `lobbySpawn`; phase `lobby`. Nothing
  is timed, scored or paid in the lobby; the player can walk around, read the boards and
  warm up. The "start" Notify carries `phase = "lobby"` plus best, clears and rewardPreview.
- **Lobby area** (part of the arena build, next to the play area): the mode's title sign, a
  HOW TO PLAY board (three big illustrated steps, readable from the spawn), a YOUR BEST /
  reward status board, a glowing START pad and the EXIT arch (back to the plaza). Each mode
  adds its own warm-up: Bowling has a ball rack to pick a dumbbell colour and a view down
  the lane, Shake Catch a practice tray with slow demo drops, Pose Copy a rehearsal mirror
  where the four flex buttons work without scoring.
- **Start**: stepping on the START pad or pressing the HUD's PLAY button (tap, Enter,
  gamepad A) sends the mode's own action `"<Mode>Begin" {}` ("ShakeBegin", "PoseBegin",
  "BowlingBegin"). The server accepts it only in phase `lobby`, moves the player to the
  play spot, sends `"countdown" { seconds = 3 }` and starts play when it ends.
- **End**: win/lose events and pay as before. The HUD shows a results card (score, best,
  pay) with PLAY AGAIN (sends Begin from `results`) and LOBBY; with no input the player is
  back in the lobby after about 6 s. A finished game never sends the player to the plaza.
- **Leave**: the EXIT arch in the lobby, or the HUD's LEAVE button ("ModeQuit"): stop
  "quit" plus `GameModes.toGates`.
- **Snapshot**: `modes.x.phase` = "lobby" | "countdown" | "play" | "results".
- **Several players**: the lobby is shared; each player's game runs on its own (as before).

Arena anchors added for the lobby (every arena's `build()`):

```
lobbySpawn: CFrame,   -- feet position + facing where a player lands from the gate
startPad: BasePart,   -- "StartPad": feet within startRadius of it in phase lobby = Begin
startRadius: number,
board: SurfaceGui,    -- the YOUR BEST board's face; the client fills it (it is under the
                      -- arena Model, named "BestBoard", so clients find it by name)
```

`spawn` stays the play spot where a game starts; `exit` and `exitRadius` now sit in the
lobby.

## Files each builder owns (and may edit)

For mode `X` in {Shake, Pose, Bowling} (id `x`):

- `src/server/Modes/X.luau`: the server mode (ModeDef: start, stop, running, tick,
  snapshot, rewardPreview). The stub already starts runs (gate walk-in through
  `Course.crossedGate` or the "ModeStart" `{ mode = "x" }` action), teleports to the arena
  spawn, ends runs on the arena's exit pad (stop "quit" + `GameModes.toGates`) and puts a
  fallen player back on the spawn.
- `src/server/Modes/XRules.luau`: pure rules (no Roblox services) plus `ARENA` (where the
  arena sits) and `FALL_BELOW`. Extra pure helpers belong here so Lune can test them.
- `src/server/World/<Arena>.luau`: the arena build (`ShakeArena`, `PoseStage`, `BowlingLane`).
- `src/client/UI/XHud.luau`: the screen side.
- `src/client/Fx/X.luau`: the 3D side.
- `tests/x.luau`: the mode's unit tests (already registered in `tests/run.luau`).
- `docs/x.md` if the mode needs its own notes.

New Blender meshes or sounds for a mode go in that mode's own new files and folders.

## Off-limits shared files

Builders must not edit these (ask the orchestrator if something there has to change):

- `src/server/GameModes.luau`, `src/server/Modes/Catalog.luau`, `src/server/Modes/Course.luau`
- `src/server/World/Modes.luau`, `src/server/World/Arena.luau`, `src/server/World/Common.luau`,
  `src/server/WorldBuilder.luau`
- `src/server/DataService.luau`, `src/server/Tycoon.luau`, `src/server/Main.server.luau`,
  `src/shared/Economy.luau`, `src/shared/Net.luau`, `src/themes/chad/Theme.luau`
- `src/client/Main.client.luau`, `src/client/UI/Windows.luau`, `src/client/UI/Kit.luau`,
  `src/client/UI/Hud.luau`, `src/client/UI/Popups.luau`, `src/client/Sounds.luau`
- `tests/run.luau`, `tests/minigames.luau`, `scripts/*`, `*.project.json`
- Every other mode's files (Parkour, Mog, Cardio and the two other mini-games).

## Arena API

Every arena's `build()` returns `World.Arena.Base` plus its own anchors. The server mode
reads it as `context.world.<id>` (WorldBuilder's result; `context.built` stays World.Modes'
plaza for Parkour).

```
Base = {
  folder: Model,        -- the arena Model (attribute Mode = id) under the map folder
  floor: BasePart,      -- "ArenaFloor", top at `top`
  spawn: CFrame,        -- feet position + facing where runs start
  exit: BasePart,       -- "ArenaExit" pad under the EXIT arch (+X/+Z corner)
  exitRadius: number,   -- feet within this of the exit pad end the run
  center: Vector3,      -- floor top centre
  top: number,          -- floor top y
}
ShakeArena.Built  = Base & { catchArea: {x0, x1, z0, z1}, dropY: number, items: Folder }
PoseStage.Built   = Base & { playerSpot: CFrame, rivalSpot: CFrame, rival: Model }
BowlingLane.Built = Base & { lane: BasePart, rollStart: CFrame, pinSpots: { CFrame } (10, head pin first), pins: Folder }
```

Teleport with `GameModes.teleport(player, cf.Position, cf.LookVector)`.

## Client modules

Main.client.luau already wires them; builders only edit the module bodies.

- `UI/XHud.luau`: `init(screen)` (once), `onNotify(payload)` (every Notify with
  `kind = "Mode"`, `mode = "x"`; routes "start"/"stop" to `start(payload)`/`stop(payload)`),
  `onState(data)` (every snapshot; hides when `modes.x.running` is false).
- `Fx/X.luau`: `init()` (once, from Main's Fx list; connects its own Notify listener),
  `start(payload)`, `stop(payload)`.

## Notify events

Payloads go through `GameModes.notify(player, event, "x", data)`, so every one has
`kind = "Mode"`, `event` and `mode = "x"`. The stubs send `"start" { best, clears }` and
`"stop" { reason }` (reason: "quit" | "left" | "respawn" | "leave" | "switch" | "invalid").
Builders add their own lower-case event names, for example `"round"`, `"score"`, `"fail"`,
and a finish event `"win"` (passed) or `"lose"`, with the pay fields `cash`, `full`,
`packCash` on a win, like Cardio. Effects go through `GameModes.effect(player, kind, data)`
with kind names prefixed by the mode (`"ShakeCatch"`, `"PoseFlex"`, `"BowlingPins"`).

## Snapshot (the Game Modes window reads it)

`modes.x = { running, best, clears, cooldownEnds, rewardPreview = { cash, full, packCash,
repeatCash } }`. Keep these fields; add others freely.

## Rewards

Same rule as the other modes: a pass pays a cash pack sized like the shop's
(`Theme.Modes.Reward` seconds and minimum, scaled by income and the best tier found). It
pays in full on the first clear ever and then at most once per
`Economy.MODE_REWARD_COOLDOWN` (30 min); inside the cooldown a pass pays nothing unless the
mode decides to pay the `repeatCash` share (`Economy.MODE_REPEAT_SHARE`). There is no Rizz
any more (it was removed; `DataService` drops old balances): the "first clear" bonus is the
full pack.

- Price: `GameModes.modeReward(session, "x", first)` (wraps `Economy.modeReward`; first =
  `session.profile.modes.x.clears == 0`).
- Pay: `GameModes.payReward(player, "x", reward, pos?)`: runs `GameModes.hooks.reward`
  (events and boosts), adds the cash, restarts the cooldown on a full pay
  (`profile.modes.x.lastRewardAt`), fires the "Cash" effect, calls
  `GameModes.hooks.rewarded` and marks the save dirty. Returns what was paid.
- Saves: `profile.modes.x = { best, clears, lastRewardAt }` (DataService). The mode updates
  `best` and `clears` itself before paying.
