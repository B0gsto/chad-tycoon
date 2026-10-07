# Parkour maps

The ten Parkour levels are ten themed **maps**. Each map plays differently (its own recipe of
obstacles), looks different (its own palette, platform style and scenery) and is picked from a
**map picker** instead of being started blind. This file is the contract between the four parts:

| Part | File(s) | Owns |
|---|---|---|
| Course data | `src/server/Modes/Course.luau`, `tests/run.luau` | `Course.MAPS`, per-map recipes, `level.theme/blurb/icon/PROPS` |
| World build | `src/server/World/Modes.luau`, new `src/server/World/MapDecor.luau` | themed platforms, scenery from `level.PROPS`, tags/attributes below |
| Picker + server | `src/server/Modes/Parkour.luau`, new `src/client/UI/MapPicker.luau`, `src/client/UI/Windows.luau`, `src/client/UI/Popups.luau`, `src/client/Main.client.luau`, `src/client/UI/Hud.luau` | the Maps window, the "pick" notify, snapshot fields |
| Client fx | `src/client/Fx/Modes.luau` | themed ambience from the tags below |

## Course data (`Course.luau`)

```lua
Course.MAPS[i] = {
	theme = "beach" | "cove" | "bay" | "reef" | "bubble" | "coral" | "shark" | "storm" | "volcano" | "giga",
	name = Course.NAMES[i],
	blurb = "one short kid-friendly line, e.g. 'Hop the stepping discs under the palms!'",
	icon = "🏖️",            -- one emoji for the picker card
	accent = "Sunny",       -- Theme.World colour key for the card band
	recipe = { ... },       -- generator knobs (Course agent's own shape)
}
```

Every `Course.Level` gains:

- `theme: string`, `blurb: string`, `icon: string`, `accent: string` (copied from `MAPS[i]`).
- `PROPS: { Prop }` scenery placed by the generator **inside `level.BOUNDS`, never within 4 studs
  (horizontally) of any path element at any phase of its motion** and never over the finish or
  start deck. Positions are world coordinates, `y` = where the prop's base stands (sea props
  stand at `Course.WATER_Y`).

```lua
type Prop = { kind: string, x: number, y: number, z: number, yaw: number?, scale: number?, r: number?, speed: number? }  -- yaw in radians
```

Prop kinds (the world builder draws each with parts; unknown kinds are skipped with a warn):

| kind | used by | meaning |
|---|---|---|
| `islet` | all | a sand/rock disc at water level under a deck, `r` = radius |
| `palm` | beach, cove | palm tree |
| `umbrella` | beach | beach umbrella + towel |
| `beachball` | beach, bubble | striped ball |
| `rockarch` | cove | rock arch (two pillars + lintel) |
| `rock` | cove, volcano | boulder, `scale` |
| `coconut` | cove | pile of coconuts |
| `lighthouse` | bay | striped lighthouse with a lamp |
| `buoy` | bay, shark | bobbing buoy (world: tag `MapBob`) |
| `coral` | reef, coral | coral cluster (tubes + fans), `scale` |
| `bubblefield` | bubble | spawner spot: world builds ~8 translucent balls tagged `MapBubble` |
| `fin` | shark | shark fin circling a point: world builds a `ModeMover` root with `Mover = "spin"`, `MoveSpeed` = `speed` (default 0.6), and the fin `r` studs out from the root |
| `cloud` | storm | dark storm cloud (puffs) with a neon bolt tagged `MapLightning` |
| `volcano` | volcano | cone with a glowing crater (tag `MapGlow`) |
| `lavapool` | volcano | neon orange disc at water level (tag `MapGlow`), `r` |
| `statue` | giga | gold Giga statue (Props.mesh("GigaStatue") when available, else part-built) |
| `flagline` | giga, bay | bunting between two posts |

## World build (`World/Modes.luau` + `World/MapDecor.luau`)

- `Parkour/Level<i>` folder gets attributes `Theme`, `Blurb`, `Icon`, `Accent` next to the
  existing `Title`.
- Platforms keep their layout but take a per-theme **style**: `Course.STYLES[theme]` is not
  needed; the world builder keys its own table by theme (material, rim colour, edge trim). E.g.
  volcano = dark slate rims with orange trim, storm = steel with cyan trim, reef = sand with coral
  trim, giga = gold rims.
- Scenery: `MapDecor.build(level, folder)` draws every `level.PROPS` entry.
- Tags/attributes the client animates:
  - `MapBubble` (BasePart): attribute `Rise` studs/s, `Top` world y where it pops and restarts at
    its rest y. Client bobs/raises them.
  - `MapBob` (BasePart, buoy root): gentle bob + tilt. Children move with it.
  - `MapLightning` (Neon BasePart): client flashes it (transparency 1 → 0 bursts every few s).
  - `MapGlow` (Neon BasePart): client pulses its colour brightness.
  - Shark fins reuse the existing `ModeMover` / `Mover = "spin"` contract (client already animates).
- Build cost: at most ~250 extra parts per map.

## Picker + server

- Snapshot `modes.parkour.levels[i]` gains `theme`, `blurb`, `icon`, `accent`.
- Crossing gate 1's portal no longer auto-starts: the server sends
  `Notify { kind = "Mode", mode = "parkour", event = "pick", level = <default level> }` and the
  client opens the Maps window with that map selected. (`ModeStart { mode = "parkour", level = n }`
  still starts and teleports; the player stands on the plaza while picking.)
- New window `"Maps"` (`Windows.open("Maps")`): a header "PICK A MAP", a scrolling grid of 10
  map cards (2 columns): accent band with icon and `Level n`, name, difficulty pips, best time
  and clears, lock state (locked cards dim with a lock; tapping says "Clear <previous name> first!").
  Selecting a card shows it in a side panel: a `ViewportFrame` preview of that map (lazy clone of
  `Map/GameModes/Parkour/Level<n>` without triggers, cached per map, camera framed on the whole
  course, slowly orbiting), blurb, reward line and a gold **PLAY** that fires `ModeStart` and closes
  every window. On phones the side panel stacks under the grid.
- The Modes window's PARKOUR row keeps PLAY for the preselected map and gets a "CHOOSE MAP" button
  that opens the Maps window (chips may go).
- The finish card gets a third button "Choose map" (opens the Maps window).
- `Hud`: nothing new unless a button is needed; the Modes icon stays the way in.

## Client fx (`Fx/Modes.luau`)

- When a run starts on a level (start notify, `payload.level`), read the level folder's `Theme`
  and apply an ambience until the run ends or the player leaves the level bounds: storm = darker
  sky tint + fog, occasional lightning flash sound + `MapLightning` bursts; volcano = warm tint
  + ember particles from `MapGlow` parts; reef/bubble = none beyond bubbles; giga = gold sparkles.
  Restore defaults on finish/stop/invalid and on leaving the bounds.
- Animate `MapBubble`, `MapBob`, `MapLightning`, `MapGlow` only when within ~250 studs of the
  player (like movers).
