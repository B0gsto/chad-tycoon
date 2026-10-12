> Historical working note from 2026-10-06. It no longer matches the game;
> see README.md for the current design.

# Juice pass: shared contract (all streams read this)

Context: `playtest/REPORT.md` lists every problem. Five streams work in parallel on DISJOINT files.
Only edit the files your stream owns. Do not commit. Do not touch other streams' files.

## File ownership
- **A (server)**: `src/server/Tycoon.luau`, `src/shared/Economy.luau`, `tests/run.luau`
- **B (world)**: `src/server/WorldBuilder.luau`, `src/client/Guide.luau`
- **C1 (client machines/orbs)**: new `src/client/Fx/Orbs.luau`, new `src/client/Fx/Machines.luau`
- **C2 (client shelf/units)**: new `src/client/Fx/Shelf.luau`, new `src/client/Fx/Camera.luau`,
  `src/client/Animator.luau`, `src/shared/CharacterFactory.luau`, `src/themes/chad/Theme.luau`
- **D (UI/sound)**: `src/client/UI/Hud.luau`, `src/client/UI/Popups.luau`, `src/client/UI/Tutorial.luau`,
  `src/client/Sounds.luau`, `src/client/Main.client.luau`, `src/client/UI/Kit.luau`, `src/client/UI/Windows.luau`

`src/client/Fx/` is a folder of ModuleScripts next to `Main.client.luau`. Each Fx module returns a
table with `init()`; it connects its own listeners (multiple `Net.event("Effect").OnClientEvent`
connections are fine). Main (stream D) calls `require(script.Parent.Fx.Camera).init()`,
`.Shelf`, `.Orbs`, `.Machines` after the UI is built (wrap each in pcall so one failing module
can't break the UI).

The player's own plot on the client: `workspace.Map["Plot" .. State.data.plotIndex]`
(`State` = `src/client/State.luau`, `State.changed` BindableEvent fires with each snapshot).

## Server → client effects (`Net.event("Effect")`, args `(kind, data)`), produced by A
Existing kinds keep working; A adds the fields below (all Vector3 are world space).
- `"Buy"` `{ amount: number, tier: number, padPos: Vector3 }`
- `"Merge"` `{ fromTier: number, toTier: number, from: {Vector3}, to: Vector3?, auto: boolean }`
  sent once per merge step (cap 6 steps per action; for big batch merges send one summarised effect).
  `from` = world positions of the shelf models consumed (≤ 4), `to` = position of the resulting unit's model.
- `"Deposit"` `{ amount, mult, from: Vector3 (player root), to: Vector3 (converter intake) }`
- `"OrbsPicked"` `{ amount: number, positions: {Vector3} }` sent every fastTick that collects orbs
  (positions ≤ 12). The existing batched `"Collect"` effect stays (UI float).
- `"Cash"` `{ amount, padPos: Vector3? }` (padPos = Collect pad when collecting)
- `"Upgrade"` `{ pad: string, padPos: Vector3, level: number? }`
- `"ChestPickup"` `{ rarity }`, `"ChestOpen"` `{ rarity, tier }`

## Instances / attributes (produced by A, consumed by C1/C2)
- Orb parts (in the plot's orb folder): server spawns them ANCHORED AT THE LANDING SPOT, no
  BillboardGui, no server tweens. Attributes: `Origin: Vector3` (where it flew from, may be nil),
  `Value: number`, `Big: boolean`, `Spawned: number` (workspace:GetServerTimeNow()). At the orb cap
  the server feeds an existing orb: increments attribute `Feed` (number) and sets `FeedFrom: Vector3`.
  Client animates everything (arc in, bob, feed pulse, pickup magnet).
- Unit models in `Plot.Units`: server REUSES models when the shelf reorders (PivotTo) and only
  creates models for new units. New models get attribute `Spawned` = workspace:GetServerTimeNow().
  Count label updates in place (no rebuild). Attribute `Tier: number` on every unit model.
- Pad parts `Pad_<Name>` get attribute `Dwell: number` (seconds you must stand on it; 0 = instant).
  Purchases (Buy*, AutoMerge, ProcUp*) use 0.7 s; Deposit/Collect/Merge/Unlock*/Free use 0.
- Floor crates are picked up with a ProximityPrompt (ActionText "Pick up", KeyCode E, HoldDuration 0,
  MaxActivationDistance 9, RequiresLineOfSight false). No more walk-over pickup.

## Sounds (D implements; C1/C2 call)
`Sounds.play(name: string, pitchJitter: number?, pitchMult: number?)`; unknown names are a no-op.
Names D must define: `OrbPickup` (short blip; C1 passes rising pitchMult for combos), `OrbLand`,
`BuyPop`, `MergeCharge`, `MergeBoom`, `Upgrade`, `DepositStream`, `Coin`, `ConverterHum`,
`SurgeStart`, `SurgeEnd`, `Tick`, `CrateShake`, `CrateBurst`, `Ready`, plus the existing names.
Main's Effect handler (D) plays sounds for `Cash`, `Deposit`, `Upgrade`, `ChestPickup`, `ChestOpen`,
`Buy`. The Fx modules play: `OrbPickup` (C1), `MergeCharge`/`MergeBoom` (C2), `BuyPop` (C2, on unit landing).
D must NOT play a sound for `"Merge"` (C2 owns it).

## Timing contract for merges
C2's fusion animation takes ~0.9 s. D's popup queue delays any `Reward` popup that arrives within
1 s of a `"Merge"` effect until 1.0 s after that effect, so the 3D moment is seen first.
