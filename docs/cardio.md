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
   stat (`profile.cardio.speed`). It never goes down and is never reset.
3. **Speed → walk speed.** Inside the mode only, WalkSpeed = `CardioRules.walkSpeed(speed)`:
   16 at 0, rising on a smooth, diminishing curve to a cap of about 120. It is set through the
   Humanoid `BaseWalkSpeed` attribute + `Cosmetics.refresh` and restored when the run stops.
   Speedy Sneakers still multiplies on top, so the stage checks assume no Sneakers. Players can
   set their own max ("Custom Speed", `CardioSpeedCap`, saved as `profile.cardio.speedCap`,
   0 = none): the base WalkSpeed is then `min(walkSpeed(speed), cap)`. The HUD shows it as a small
   "Custom Speed" chip on every screen; tapping it opens the box, OK and the run's end fold it.
4. **Stages 1..10** run in a line along the runway. Each stage is keyboard platforms with gaps
   and ends in a **safe zone**: a key deck as wide as the stage's room (45 x 16 keys = 126 x 44.8
   studs; the old one was 29 x 11 keys = 81.2 x 30.8, so about 2.3x the floor; the last zone is
   45 x 20 keys). Across it run three bands: a free lane in the middle that both doorways open
   into (every doorway is 9 keys = 25.2 studs wide, `CardioLayout.DOOR`, at most `DOOR_REACH` off
   the centre line), the gold **WIN plate** on one side and four treadmills on the other, so
   running from door to door touches neither.
   Each stage has `need` Speed, shown on a big sign at its entrance ("NEED 1,200 SPEED"). Its
   longest gap is clearable at walkSpeed(need) with the default jump, and NOT clearable at
   walkSpeed(previous stage's need). Physics decides; there are no walls. Every designed jump keeps
   some reach in reserve for phones and late jumps: stage 3 (need 830, recommended 955) asks for
   16 studs at most, which leaves 2.4 studs (3 x SAFETY) at exactly the need. 16 is the shortest
   gap that stage 2's need (150) cannot clear, and 830 the lowest need that keeps 2.4 over it, so
   a first session reaches the chaser about 3 minutes of running after stage 2 (2 minutes
   nonstop, 4.7 on the zone 2 treadmills; it was 1,100 and about 5 minutes). Stages 4-9 follow
   on a smooth curve: 2,400 / 5,800 / 12,000 / 23,000 / 41,000 / 72,000, stage 10 stays 125,000
   (the Speed cap); stage 10 comes after about 48 minutes in the coarse progression model.
   Saved Speed is never lowered: a save above a stage's new need simply has that stage open.
   The HUD's bar recommends 15% more Speed than the need (`CardioRules.RECOMMEND`); on the
   track a gold goal star with that number and a bobbing arrow stands beside the doorway of the
   stage you run next (Fx.Cardio).
   Later stages also add: narrower key bridges, step-ups (≤ 5 studs), blinking keys (on/off by
   server time from stage 4), sliding keys (moving platforms from stage 6). There are
   no checkpoints anywhere. Stage 10's zone holds the last WIN plate, in front of the FINISH podium.
5. **You cash out only on a WIN plate.** Reaching a safe zone pays nothing. Every safe zone
   1..10 has a WIN plate (`zone.winPad`, 5 x 5 keys, tag `CardioWinPad`) with a floating label
   showing what it pays you right now ("WIN  +$12.4K"). Stepping on it pays that stage
   (Economy.modeReward times `CardioRules.stageBonus(n)`), records `bestStage`, ends the run and
   puts you back in the lobby. Walking past it keeps the run going toward the next plate, which
   pays more. Anti-farm rule: a claim is a **first clear** the first time that plate is claimed
   (always paid). First clears are kept per plate in a bit set (`profile.cardio.firsts`, bit n - 1
   = plate n; `CardioRules.firstsOf`, `isFirst`, `claimFirst`), so a plate you ran past keeps its
   first clear for later; a save from before the set counts every plate up to `bestStage` as
   taken, as it did then. A claim deeper than `bestStage` raises it and the permanent **step
   multiplier** (`CardioRules.stepMultiplier(bestStage, treadmill level)`). Any other claim pays in full only once per
   `Economy.MODE_REWARD_COOLDOWN` (`profile.modes.cardio.lastRewardAt`, shared by all ten plates).
   Inside the cooldown a plate pays the **run again bonus**, `Economy.MODE_REPEAT_SHARE` (20%) of
   its pack, but only for a real run (`CardioRules.repeatEarned`): on your best plate (`bestStage`)
   or a deeper one, and no sooner than `CardioRules.REPEAT_GAP` (30 s) after the last plate that
   paid. Any other plate inside the cooldown pays $0 and still ends the run; the HUD says from
   which plate and when the bonus is back. The server decides: the runner must be in a run, alive, with the feet on
   the plate (`CardioLayout.onWinPad`; jumping over it does not count), in a zone reached this
   run. Zones are reached in order and on foot (zone n counts on its deck after bridge room n was
   entered this run with zone n - 1 reached), and the claim clears them, so one run pays once.
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
   **lobby, the start of stage 1**, wherever you were (`CardioLayout.spawn(0)`). The run starts
   over: no safe zone reached, chasers ready again. Speed, the treadmill level and `bestStage`
   are permanent and stay. Quitting (HUD button, Home, respawn) ends the run. Every run
   **starts at stage 1** (the lobby): there is no stage picker, and the server ignores any start
   stage a client sends. `bestStage` is only a record (the step multiplier, the ranking).
8. **Chasers** (`CardioChase.luau`; stages 3, 6 and 9). Walking onto the stage's run-up starts a
   chase: a big Chad appears in the west doorway and, after its head start, runs the path's centre
   line at `factor x walkSpeed(need)` until it catches you (back to the lobby) or you reach the
   end platform. Stage 3 is the first chase a runner meets, so its Chad is gentler: a 2 s head
   start at 0.85 of the walk speed, which lets a runner at exactly the need lose 2 seconds on the
   way. Stages 6 and 9 start after 1.2 s at the default `SPEED_FACTOR` and leave about 1.2 s.

## Module map (all new files unless marked)

| File | Role |
|---|---|
| `src/server/Modes/CardioRules.luau` | Pure numbers (no Roblox APIs): walkSpeed, airtime/maxGap, stepMultiplier, treadmillRate, treadmillCost, stageBonus, the STAGES table (need, gap, width, blink, movers...) |
| `src/server/Modes/CardioLayout.luau` | Pure, deterministic layout: Cardio.generate() → keys, safe zones, treadmills, the upgrade pad, WIN plates, signs, zone spawns, bounds; ORIGIN, KILL_Y |
| `src/server/Modes/CardioChase.luau`, `tests/cardio_chase.luau` | The chaser Chads: per-stage tuning (tier, size, head start, speed factor), the chase path and the catch / escape rules, with their tests |
| `tests/cardio.luau` (+ 1 line in `tests/run.luau`) | Curve, monotonicity and fairness tests (every gap clearable at need, not clearable at the previous need, no overlaps, inside the bounds, zone sizes, WIN plates), and the run rules against a stub server (stage 1 start, pay only on a WIN plate, fall = stage 1) |
| `src/server/World/CardioTrack.luau` (+ `WorldBuilder` hook) | Builds the arena from CardioLayout: keycaps (`AssetModels` keycap mesh with part fallback), treadmills, pads (SPEED UP, WIN plates), signs, arches, decor |
| `src/server/Modes/Cardio.luau` (+ `Catalog`, `GameModes.BUILTIN`, `DataService`) | The ModeDef: runs, steps, treadmills, falls, WIN plate claims, upgrade action, snapshot |
| `src/client/UI/CardioHud.luau`, `src/client/Fx/Cardio.luau` (+ `Main.client` wiring) | Speed counter, +N popups, stage progress, need hint, pending win line and WIN plate labels, treadmill upgrade card, stage clear / win banners and the finish card; key press-down + glow under feet, letter labels on nearby keys only (pooled), treadmill belt scroll + run-in-place, speed lines/FOV at high speed |
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
  `zone { stage, first, cash, full }` (reached a safe zone; cash = what its WIN plate pays now,
  nothing is paid yet), `win { stage, final, first, cash, full, newBest, prevBest }` (claimed a WIN
  plate: paid and back in the lobby; final = stage 10; newBest = deeper than the best plate
  before). Both carry the pay fields: `pay` (`"first"`, `"full"`, `"repeat"` = the run again bonus,
  `"resting"` = a plate that would pay it, inside the 30 s gap, or `"none"`), `packCash`, `repeatCash`, `repeatShare`, `repeatFrom` (the first plate that can pay
  the bonus) and `repeatReadyAt` (os.time() from which it is paid again, 0 = now); the win banner
  reads "Run again bonus +$X (20%)" for `"repeat"`, `fall { stage = 0, from, reason }` (back in the lobby
  from stage `from`; reason "fall" or "caught"; `zone = n` when the fall was off safe zone n's own deck, which
  the HUD shows as a plain fall instead of the next stage's need), `upgrade { level, cost }`, `stop { reason }`.
- Speed changes travel in the State snapshot (`modes.cardio`: speed, walkSpeed, multiplier,
  maxWalkSpeed (uncapped), speedCap (nil when none), bestStage, treadmill, treadmillRate,
  nextCost, stage, reached, wins and firsts (per plate, in a run: what the plate pays now and
  whether its first clear is still there), running, onTreadmill). The server also fires
  `Effect("CardioSteps", { gained, speed, walkSpeed, treadmill, multiplier, rate })` (rate = the current treadmillRate) at most ~4 times a second so the HUD can count
  up smoothly without a full refresh every tick.
