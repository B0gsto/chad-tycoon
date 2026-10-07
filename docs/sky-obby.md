# Sky obby

The parkour becomes a classic rainbow **sky obby**: one continuous candy-coloured course high above
the clouds, numbered stages, floating green islands with lighthouses, windmills and trees, a
hot-air balloon, a top progress bar of player heads, a stage leaderboard, a Skip Stage button and
a gear hotbar (speed coil, jump coil, gravity coil) the player chooses from. The ten themed maps
stay as the ten sections (worlds) of the obby and the map picker still picks where to start.
This file is the contract between the parts (see docs/parkour-maps.md for the previous layer).

| Part | Owns |
|---|---|
| Course | `src/server/Modes/Course.luau`, parkour tests in `tests/run.luau` |
| World | `src/server/World/Modes.luau`, `src/server/World/MapDecor.luau`, colour keys in `src/themes/chad/Theme.luau` |
| Server | `src/server/Modes/Parkour.luau`, `src/server/Modes/Rules.luau`, `src/server/DataService.luau`, `src/server/Ranking.luau`, `src/shared/Economy.luau`, `src/server/GameModes.luau` |
| Client | `src/client/UI/Hud.luau`, new `src/client/UI/ObbyHud.luau`, `src/client/UI/Windows.luau` (Ranking + Modes), `src/client/UI/MapPicker.luau`, `src/client/Main.client.luau`, `src/client/Fx/Modes.luau`, `src/client/UI/Popups.luau` |

## Course (geometry data)

- **Altitude.** Every map is lifted into the sky: `Course.SKY_Y = 320` is the lowest path top;
  `Course.FLOOR_Y = SKY_Y - 24` is the cloud floor. `Course.inWater(x, y, z)` keeps its name
  and signature but now means "fell": `y < Course.FLOOR_Y`. `level.WATER_BOX` is the cloud
  catch volume (y0 = FLOOR_Y - 20, y1 = FLOOR_Y). No sea bases: `level.BASE` is removed.
- **Chain.** Maps are chained in walking order: map n+1's start deck stands 26 studs past map
  n's finish deck along the finish arch's facing, with `Course.BRIDGES[n]` (n = 1..9) a list of
  walkable `pad` elements (rainbow stair: 6 thin boxes stepping up 1.2 studs each) joining them.
  `Course.CENTRES` is recomputed from the chain (the picker preview and tests read it). Regions
  still never overlap. The whole chain stays within x, z in [-1400, 1400].
- **Stages.** Global stage numbers: `level.STAGE_FIRST` is the stage of the map's start deck
  (map 1: 1); checkpoint k of a map has `stage = STAGE_FIRST + k`; the finish deck is stage
  `STAGE_FIRST + CHECKPOINT_COUNT + 1`, which equals the next map's STAGE_FIRST.
  `Course.STAGE_COUNT` is map 10's finish stage. `Course.stageOf(level, checkpointIndex)` and
  `Course.levelOfStage(stage) -> (level, checkpointIndex)` helpers.
- **Rainbow.** Every path element's `color` cycles the rainbow in path order:
  `Course.RAINBOW = { "RainbowRed", "RainbowOrange", "RainbowYellow", "RainbowGreen", "RainbowCyan", "RainbowBlue", "RainbowPurple", "RainbowPink" }`
  (Theme.World keys, World adds them). Checkpoints keep `color = "Checkpoint"` (a sky blue;
  World adds the key) and movers/blinks keep their map's mover/blink colours. Map palettes stay
  only as the `accent` for picker cards and landmark tints.
- **Sky scenery.** `level.PROPS` kinds become: `island` (floating green disc, `r`, grass top at
  `y`, rock cone below), `lighthouse`, `windmill` (spinning blades), `tree`, `balloon` (hot-air
  balloon, bobbing), `cloud` (white puffs), `star`, `rainbowarch`, `landmark` (the map's themed
  landmark, standing on an island). Every map gets 2-4 islands beside the course (never within 4
  studs of the path), one carrying the landmark, plus 4-8 clouds below and beside, 1-2 balloons
  high up, and the map's own extras (bay: lighthouse; storm: clouds only; giga: stars). Prop `y`
  is the island's grass top or, for clouds/balloons, their own altitude.

## World

- Theme.World gains the RAINBOW keys (saturated candy: red 255,80,80; orange 255,150,50; yellow
  255,225,60; green 90,220,100; cyan 70,220,230; blue 70,140,255; purple 170,110,255; pink
  255,120,200) and `Checkpoint` (sky blue 90,170,255), `Cloud` (white 250,250,255).
- Platforms: bright SmoothPlastic tops in their rainbow colour, a thin white underside, no dark
  rims (one 0.3-stud lighter lip is fine). Movers keep their stripes.
- **Checkpoint pads** become the reference's arrow pads: a 12x12 box in `Checkpoint` blue with a
  big white arrow (SurfaceGui) pointing at the next path element and the global stage number
  in the pad's far corner ("12"); the flag pole stays. Attributes: `Index` (per map), `Stage`
  (global), `Level`, `Mode`.
- The start deck of map 1 is a green checkered lobby deck with "CHAD OBBY" block letters
  (parts) and a START arch; other start decks keep their arch and show "STAGE n".
- **Cloud floor:** per map, a big soft cloud layer (overlapping white balls/boxes, 20-40 parts)
  at FLOOR_Y under the course footprint, CanCollide false (the catch volume handles falls),
  plus `Lighting` gets `Clouds` in Terrain when available (`workspace.Terrain:FindFirstChildOfClass("Clouds")`
  or create; Cover 0.7, Density 0.3; wrap in pcall for Lune).
- `Level<i>` folder attributes add `StageFirst`, `StageLast`.
- Windmill blades: `ModeMover` root with `Mover = "spin"` about the blade axle: use the existing
  spin contract but set attribute `SpinAxis = "Z"` (World) and Client.Fx.Modes honours it
  (rotation about the root's look vector instead of world up).
- Hot-air balloon: `MapBob` root.

## Server

- Profile: `profile.parkour.stage` (max global stage reached, saved; reconcile in DataService),
  `profile.parkour.gear` (last chosen gear name or "none").
- Player attributes replicated for the HUD bar: `ParkourStage` (current stage this run, 0 when
  not running), `ParkourBestStage`.
- Notify `start/checkpoint/respawn/finish` payloads add `stage` (current global stage) and
  `stageCount`; `finish` adds `assisted` (bool).
- **Gear.** Action `ParkourGear { gear = "none" | "speed" | "jump" | "gravity" }`: saved,
  applied to the Humanoid only while a parkour run is active (speed: WalkSpeed 16 -> 28; jump:
  JumpHeight 7.2 -> 14; gravity: a `VectorForce` on the root cancelling 55% of weight,
  `Name = "GravityCoil"`), removed on stop/finish/respawn. A run on which gear was active at any
  point is `assisted`: it still pays and unlocks and counts clears, but never sets a best time or
  a board entry. Snapshot `modes.parkour.gear`.
- **Skip stage.** Action `ParkourSkip`: costs cash, `Economy.parkourSkipCost(income)`: two minutes of
  income (`PARKOUR_SKIP_SECONDS = 120`), at least `PARKOUR_SKIP_MIN = 250` (refused with a
  "Not enough cash!" toast when short; snapshot `modes.parkour.skipCost`), teleports the player to the next checkpoint (or the finish deck, which
  then finishes the run as assisted), advances the run as if touched, marks assisted. Notify
  `{ event = "skip", stage }`.
- **Stage board.** `Ranking.luau` gets a third board "STAGE" (top 10 by `profile.parkour.stage`,
  with clears) alongside the existing ones; the snapshot/Notify used by the Ranking window gains
  `stage = { { name, stage, clears } }`.
- `Rules.finish` anti-cheat: minimum leg seconds assume WalkSpeed 16; with speed gear active the
  server uses 28/16 of MAX_PLAUSIBLE_SPEED (just scale the check by the active gear).

## Client

- **ObbyHud** (new, shown while running or standing on the obby): the top rainbow progress bar
  with every parkour player's avatar head (Players:GetUserThumbnailAsync, cached) positioned by
  `ParkourStage / STAGE_COUNT`, the local player's head highlighted with a white caret, a trophy
  at the end; a "STAGE n" counter under it; a `SKIP STAGE $X` button (coin icon, cash cost from the snapshot's `skipCost`); a 3-slot gear
  hotbar bottom centre (Speed, Jump, Gravity coils; keys 1-3 / tap toggle; the chosen slot is
  outlined gold; "none" when the chosen one is tapped again) that fires `ParkourGear`.
  The existing run pill (timer) stays.
- Ranking window: a third tab/board "STAGE" (People / Stage / Clears).
- Fx.Modes: falling below the cloud floor shows a cloud poof instead of a water splash; the
  per-map colour grades are toned down to a single sunny sky look (keep storm and volcano hints
  very light); `SpinAxis` support for windmills.
- Finish card shows "Assisted run" instead of best/rank lines when `assisted`.
- Map picker preview camera still frames the level's bounding box (now including islands).
