# Sky obby

The parkour becomes a classic rainbow **sky obby**: one continuous candy-coloured course high above
the clouds, floating green islands with lighthouses, windmills and trees, a
hot-air balloon, a top progress bar of player heads, a stage leaderboard, a Skip Map button and
a gear hotbar (speed coil, jump coil, gravity coil) the player chooses from. The ten themed maps
stay as the ten sections (worlds) of the obby and the map picker still picks where to start.
This file is the contract between the parts (see docs/parkour-maps.md for the previous layer).

**Round 4 (current): no checkpoints.** See "No checkpoints" at the end: it overrides every
checkpoint, per-checkpoint stage and Skip Stage rule in the earlier sections.

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

## Hazards, second plaza, bigger signs (round 3)

- **Kill elements** (`Course`): element `{ kind = "kill", x, y, z, sx, sz, h = 0.6, color = "Lava",
  motion?, axis?, distance?, period?, phase? }` standing ON a path pad's top (`y` = the pad top).
  Two uses: a lava strip across a wide deck (hop over it; at least 4 studs of the deck stay clear
  on each side along the walking axis) and a sliding lava bar on big decks (`motion = "slide"`,
  same formula as movers). From map 2 up, 1 + difficulty // 3 per map. Pure check
  `Course.inKill(level, x, y, z, t) -> boolean` (feet inside the box at its pose at server
  time t, y in [top - 0.5, top + h + 2.5]). Kill elements are not path elements and never
  change jump fairness.
- **World**: kill boxes are parts named "KillBrick" (tag `KillBrick`, attribute `Hazard = "kill"`),
  red/black diagonal stripes (Neon red core `Lava` + black bands), CanCollide false; sliding ones
  are a `ModeMover` slide root with the brick as a child (client moves it; the server computes the
  same pose). Theme.World gains `Lava` (255, 60, 40) if missing.
- **Server** (`Parkour.tick`): `Course.inKill` → respawn at the last checkpoint with effect
  `"ModeKill" { pos }` and notify `{ event = "respawn", index, reason = "kill" }`.
- **Client** (`Fx.Modes`): `ModeKill` = red/black poof + screen flash; `KillBrick` parts pulse.
- **Second plaza** (`Course.PLAZA2`, `GATES2`, `ARRIVAL2`, `QUIT2`): the GAME MODES plaza mirrored
  on the hub's +X side (x -> -x), gates facing -X toward the hub, same catalog gates and signs.
  `Course.crossedStart(prevX, x, z)` is true for crossing either portal (west through gate 1,
  east through the mirrored gate 1); `Course.nearestQuit(x, z)` / `nearestArrival(x, z)` return the
  closer spot; GameModes.toGates / toPlaza use them (the player's current x decides).
- **Bigger signs**: the start arch's "GO GO GO!" sign 1.4x taller with text to match, standing on
  the arch's crown (across the opening the pillars cut through its text); the arch stands at the
  start deck's leading edge, ahead of the spawn, so the runner starts looking through it; every
  checkpoint flag and its number sign 2x; the finish "FINISH" banner 1.4x.
- **Flicker**: no two coplanar faces anywhere in the obby builders (lips, undersides, stripes,
  decals: offset by 0.05), no overlapping translucent parts (clouds and foam become opaque
  Transparency 0, or non-overlapping), blink pads fade via Transparency only on one part.

## No checkpoints (round 4, owner's decision)

There are no checkpoints inside a map. Each of the ten maps is a section of the obby and the map
picker picks where to start; falling sends the player back to the **start of the map they are on**.

- **Course**: no `checkpoint` elements. Where the generator placed them it now places a plain
  wide square `pad` named `"RestDeck"` (same size and spot, so the layout and every fairness
  check are unchanged; rainbow coloured, chevron toward the next pad, never carries lava).
  `CHECKPOINTS`, `CHECKPOINT_COUNT`, `MIN_LEG_SECONDS`, `legLength`, `onCheckpoint` and `stageOf`
  are gone. New: `level.PATH_LENGTH` (`Course.pathLength(level)`, start deck to finish deck along
  PATH) and `level.MIN_SECONDS = PATH_LENGTH / MAX_PLAUSIBLE_SPEED`. `Course.respawn(level)` is
  always the start deck. `Course.levelOfStage(stage) -> level`.
- **Stages are maps**: map n is stage n (`STAGE_FIRST = n`, `STAGE_LAST = n + 1`), and
  `Course.STAGE_COUNT = LEVEL_COUNT + 1` (map 10's finish). Stage numbers are progress labels
  (progress bar, STAGE board), never a saved respawn spot. Unlocking and saving stays per map
  (finishing map n unlocks n + 1 in the picker).
- **Server**: `Course.inWater` (fell) and `Course.inKill` (lava) teleport to the map's start deck
  and notify `{ event = "respawn", index = 0, stage = STAGE_FIRST, reason? }`; the clock keeps
  running. No "checkpoint" notify, no `ModeCheckpoint` effect. Payload fields `checkpoints` and
  `index` stay, always 0, for older client code.
- **Anti-cheat**: `Rules.finish` checks one start-to-finish minimum, `MIN_SECONDS` (scaled by
  28/16 when the speed coil was worn); the only invalid reason is `"fast"`.
- **Skip Map** (was Skip Stage): the same cash action `ParkourSkip` and cost
  (`Economy.parkourSkipCost`). It only unlocks the next map (`profile.parkour.skipped[level] = 1`;
  unlocks read "cleared or skipped"): no finish, so no reward, no clear, no best time, no stage and
  no reward cooldown, and the map's real first clear still pays later. The run stops and the player
  stands at the gates with the map picker on the next map (notifies `skip { level, paid = 0,
  nextLevel, unlocked }`, `stop { reason = "skip" }`, `pick { level }`). With nothing to unlock
  (map 10, or the next map is already open) it is refused and costs nothing. It is a cash action,
  so no Robux receipts are involved.
- **Saved data**: `profile.parkour.stage` is now in map units (0..11) and `stageMaps = true`
  marks it. Saves without the marker (checkpoint-era stages) are rebuilt on load from the maps
  cleared in a row from map 1 (cleared n: stage n + 1; none cleared but a stage: 1; never ran: 0).
- **World**: no arrow pads, flags or `Checkpoint` parts; the `Level<i>` folder loses its
  `Checkpoints` attribute (`StageFirst` / `StageLast` stay).
- **Client**: ObbyHud shows "MAP n / 10" and a "SKIP MAP $X" button; Fx.Modes drops the
  next-flag pulse and the checkpoint pop, and the idle hint points toward the finish deck.

## Pay per run, a clearer HUD, a safer map 1 (round 5, playtest fixes)

There are still no checkpoints.

- **Pay per run.** Inside the 30 minute reward cooldown a clean finish (no gear worn) pays
  `Economy.MODE_REPEAT_SHARE` (20%) of that map's pack on every run; an assisted finish inside the
  cooldown pays nothing. A map's first clear and the full reward once per cooldown are unchanged,
  and only a full reward restarts the cooldown. The finish payload adds `pay` (`"first"`, `"full"`,
  `"repeat"` or `"assisted"`), `packCash`, `repeatCash`, `repeatShare` and `falls`; the snapshot's
  `rewardPreview` adds `repeatCash` and `repeatShare`, and its `cash` is what a finish would pay
  now (0 inside the cooldown with a coil chosen).
- **Progress.** `Course.progress(level, x, z)` is how far along the map's path a point is (0 on
  the start deck, 1 on the finish deck: the nearest point on the line through the path elements'
  centres). The server publishes it for every runner as the player attribute `ParkourProgress`
  (hundredths, 0 when not running) and in the snapshot (`progress`).
- **Falls.** A run counts its trips back to the start deck (cloud floor or lava): `falls` in the
  `respawn` notify, the snapshot and the finish payload.
- **ObbyHud.** The bar is now the map being run: the local head rides it at `ParkourProgress`,
  with the heads of other players on the same map. Under it: "MAP 3 / 10 · Sweeper Bay", and
  "Best 0:34.4 · Falls 2" under the run pill. "ASSISTED: no best time" shows from the moment a
  coil is worn; "Oops! Back to the start" shows for 1.5 s after a fall. SKIP MAP is a small grey
  button that opens a question ("Skip Sweeper Bay for $250? You get no reward for a skipped map.",
  YES, SKIP / NO, KEEP GOING); only YES fires `ParkourSkip`.
- **One word: MAP.** The HUD and the picker say "MAP n" (the picker said "Level n").
- **Picker.** The side panel labels its pips "Difficulty n/10". A locked card shows "Clear
  <previous map> first" where its pips were and what its first clear pays beside the lock, and
  still shakes with the bubble when tapped. Inside the cooldown the reward line of a cleared map
  reads "Run again: +$X · full in m:ss" ("Gear on: no reward · full in m:ss" with a coil chosen).
- **Map 1 "Sunny Steps"** (hand-made, `LEVEL1_ELEMENTS`; maps 2 to 10 are untouched and the chain
  has not moved): the bounce pad is 9 studs wide (was 5) and centred on its 12-stud deck; the
  sweeper deck and the bounce deck have low side rails (1.5 studs, `wall` elements named "Rail");
  the first sweeper turns 30% slower (0.84 rad/s) and both bars are 10.6 long (were 12) so their
  end caps pass inside the rails. A pad that long is touched up to 5 studs earlier, so its power
  went from 78 to 94 and the landing deck above grew half a stud toward it (12 x 13): a runner
  launched at walking speed from either edge of the pad lands on that deck
  (tests/parkour_bugs.luau pins this).
