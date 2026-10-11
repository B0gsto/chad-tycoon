# CARDIO: the keyboard runner mode (gate 3)

The loop comes from Roblox "+1 Speed Keyboard Escape": every key you step on adds Speed, Speed
makes you run faster, and running faster lets you clear longer jumps. Treadmills give Speed while
you stand still. Stages need more and more Speed. In Chad Aura Tycoon it is the third plaza gate
(catalog id `cardio`, title `CARDIO`, colour key `Mint` or similar from Theme.World).

## The loop

1. Walk through gate 3. You land in the **Warm-Up lobby** at the start of a giant keyboard runway
   far out at sea. The whole floor is giant keycaps (8x8 studs, letters on top). It has free
   treadmills and the arch to stage 1.
2. **Steps → Speed.** Every key you cross (server-measured ground distance while running on
   keys, KEY_STEP = 8 studs per step, i.e. one step per two 4-stud keys of the carpet) adds `+1 × stepMultiplier` Speed. Speed is a permanent saved
   stat (`profile.cardio.speed`). It never goes down and there is no rebirth.
3. **Speed → walk speed.** Inside the mode only, WalkSpeed = `CardioRules.walkSpeed(speed)`:
   16 at 0, rising on a smooth, diminishing curve to a cap of about 120. It is set through the
   Humanoid `BaseWalkSpeed` attribute + `Cosmetics.refresh` and restored when the run stops.
   Speedy Sneakers still multiplies on top, so the stage checks assume no Sneakers. Players can
   set their own max ("Custom Speed", `CardioSpeedCap`, saved as `profile.cardio.speedCap`,
   0 = none): the base WalkSpeed is then `min(walkSpeed(speed), cap)`. The HUD shows it as a small
   "Custom Speed" chip on every screen; tapping it opens the box, OK and the run's end fold it.
4. **Stages 1..10** run in a line along the runway. Each stage is keyboard platforms with gaps
   and ends in a **safe zone**: a wide key deck with treadmills (no pads to step on).
   Each stage has `need` Speed, shown on a big sign at its entrance ("NEED 1,200 SPEED"). Its
   longest gap is clearable at walkSpeed(need) with the default jump, and NOT clearable at
   walkSpeed(previous stage's need). Physics decides; there are no walls.
   Later stages also add: narrower key bridges, step-ups (≤ 5 studs), blinking keys (on/off by
   server time from stage 4), sliding keys (moving platforms from stage 6). There are
   no checkpoints anywhere. Stage 10 ends at the FINISH podium.
5. **Stage rewards** are automatic: reaching stage n's safe zone deck the first time ever pays a first clear
   (Economy.modeReward with firstClear, times `CardioRules.stageBonus(n)`) and raises
   `bestStage`. Later arrivals pay through the normal mode reward cooldown
   (`profile.modes.cardio.lastRewardAt`). Every first clear also raises the permanent
   **step multiplier** (`CardioRules.stepMultiplier(bestStage, treadmill level)`).
6. **Treadmills.** Stand on one and your character runs in place. You gain
   `CardioRules.treadmillRate(zone, level, speed)` Speed per second, server-ticked: lobby
   treadmills are tier 1, the treadmills in deeper safe zones are stronger, and every treadmill
   grows on its own with your Speed (x `max(1, (speed / 150)^0.25)`, about x5 by the finish) so it
   never stops being worth it. The belt scrolls and the run-in-place cycle plays at your own
   WalkSpeed. A **SPEED UP** console pad next to
   the lobby treadmills spends tycoon cash to raise your treadmill level by 1
   (`profile.cardio.treadmill`, max 10, cost `CardioRules.treadmillCost(level, income)`,
   scaled on income so it stays a real sink). This is the "increase the treadmill speed" part.
7. **Falling** (below the room's killY) or being **caught** by the chaser sends you back to the
   start of the stage you are running: the spawn of the safe zone before it (zone n-1 for
   stage n, the lobby for stage 1; `CardioLayout.startStageAt(x)` + `CardioLayout.spawn(stage)`). Quitting (HUD button, Home, respawn) ends the run. Every run **starts at stage 1** (the
   lobby): there is no stage picker, and the server ignores any start stage a client sends.
   `bestStage` is only a record (first-clear rewards, the step multiplier, the ranking).

## Module map (all new files unless marked)

| File | Role |
|---|---|
| `src/server/Modes/CardioRules.luau` | Pure numbers (no Roblox APIs): walkSpeed, airtime/maxGap, stepMultiplier, treadmillRate, treadmillCost, stageBonus, the STAGES table (need, gap, width, blink, movers...) |
| `src/server/Modes/CardioLayout.luau` | Pure, deterministic layout: Cardio.generate() → keys, safe zones, treadmills, the upgrade pad, signs, zone spawns, bounds; ORIGIN, KILL_Y |
| `tests/cardio.luau` (+ 1 line in `tests/run.luau`) | Curve, monotonicity and fairness tests (every gap clearable at need, not clearable at the previous need, no overlaps, inside the bounds) |
| `src/server/World/CardioTrack.luau` (+ `WorldBuilder` hook) | Builds the arena from CardioLayout: keycaps (`AssetModels` keycap mesh with part fallback), treadmills, pads, signs, arches, decor |
| `src/server/Modes/Cardio.luau` (+ `Catalog`, `GameModes.BUILTIN`, `DataService`) | The ModeDef: runs, steps, treadmills, falls, rewards, upgrade action, snapshot |
| `src/client/UI/CardioHud.luau`, `src/client/Fx/Cardio.luau` (+ `Main.client` wiring) | Speed counter, +N popups, stage progress, need hint, treadmill upgrade card, stage clear/finish cards; key press-down + glow under feet, letter labels on nearby keys only (pooled), treadmill belt scroll + run-in-place, speed lines/FOV at high speed |
| `art/blender/cardio/*` | Keycap mesh, arcade treadmill, Cardio icon |

## Placement

The arena is a straight runway along +X with its centre line at **z = 1150** (north of everything,
clear of the Mog stage at z=400 and the parkour level rectangles, which end below z ≈ 700), from
x ≈ -1300 to +1300 at most, deck tops around y = 20 above the sea. It is reached only by teleport.

## Remotes / notify (kind = "Mode", mode = "cardio")

- Actions: `ModeStart { mode = "cardio" }` (always starts in the lobby; other fields are ignored),
  `CardioUpgrade` (buy treadmill level), `CardioSpeedCap { cap? }` (own max WalkSpeed; nil / 0 /
  invalid clears it, else rounded and clamped to [16, walkSpeed(speed)]), and the existing `ModeQuit`.
- Notify events: `start { speed, walkSpeed, bestStage, multiplier }`,
  `stage { stage, first, cash, full }` (reached a safe zone),
  `fall { stage }` (back at that safe zone), `finish { cash, full }`, `upgrade { level, cost }`,
  `stop { reason }`.
- Speed changes travel in the State snapshot (`modes.cardio`: speed, walkSpeed, multiplier,
  maxWalkSpeed (uncapped), speedCap (nil when none), bestStage, treadmill, treadmillRate,
  nextCost, stage, running, onTreadmill). The server also fires
  `Effect("CardioSteps", { gained, speed, walkSpeed, treadmill, multiplier, rate })` (rate = the current treadmillRate) at most ~4 times a second so the HUD can count
  up smoothly without a full refresh every tick.
