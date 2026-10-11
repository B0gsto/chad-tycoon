--!strict
--[[
	CardioLayout: pure, deterministic layout of the CARDIO keyboard runner (no Roblox APIs,
	no math.random; unit-tested in tests/cardio.luau), shared by World.CardioTrack (builds it),
	Modes.Cardio (teleports, steps, treadmills, safe zones, falls) and
	Modes.CardioChase.

	THEMED ROOMS along +X, centred on z = ORIGIN.z, from ORIGIN.x to at most X_END. `rooms`
	tiles the X axis with no gaps, in this order:
	  lobby (stage 0)   a full key-carpet room (treadmills, upgrade pad), CORRIDOR.width wide;
	  for n = 1..10:
	    bridge room n   ROOM.width wide, ROOM.height tall: a hazard floor (theme's melted
	                    chocolate / candy tiles / ...) ROOM.floorDrop studs below the deck
	                    height, crossed by a NARROW KEY BRIDGE Rules.STAGES[n].width wide
	                    (9 keys on stage 1 .. 4 keys from stage 8). Its west and east walls are
	                    DOOR_WALL (= one key) thick with a doorway each (`doors`), DOOR.keys
	                    wide and at most DOOR_REACH off the centre line;
	    safe zone n     a full key-carpet room as wide as the bridge rooms (ZONE_KEYS; zone
	                    10 = FINISH_KEYS) between bridge room n's east wall and bridge room
	                    n+1's west wall. Across Z it has three bands: the LANE in the middle
	                    (every doorway opens inside it, so the run from door to door is
	                    free), the WIN pad (`winPad`, WIN_PAD square) in the north band and
	                    four treadmills in the south band. Zone 10's WIN pad is the finish: it
	                    sits on the centre line in front of the podium (`finish`).
	A bridge room's walkable path, in order (all `platforms`, x-disjoint and increasing):
	  "sill"  one key long, door-width wide: the floor of the west doorway (inside the wall;
	          a porch wider than the bridge on every stage but the first);
	  "run"   the run-up (index 0) as three pieces: a straight run along X, a sideways LEG (a
	          90-degree jog: the leg is `width` long along X and spans both runs across Z),
	          then a second straight run at another lateral offset. Steps are farmed here;
	  "key" | "blink" | "mover"  stage n's jump platforms (index k = after jump k), with the
	          gaps / rises of CardioRules.jumps(n) (jump 1 leaves the run-up's far edge);
	  "end"   the raised landing platform (index = #jumps; the last jump lands here), END_KEYS
	          wide, in front of the east door;
	  "sill"  the floor of the east doorway, then safe zone n's deck.
	Consecutive surfaces either touch (flush walk, same top) or are a CardioRules jump along
	+X; across Z they always share >= 2 keys. Everything outside the path in a bridge room is
	hazard: feet below killYAt(x) (= the room's killY, just above its floorY) is a fall.

	Keys: (x, z) is the centre, `y` the TOP surface (feet level); the part's centre is
	y - KEY.height / 2. Letters run in keyboard rows across Z; each key has a `tint` (1..3)
	into THEMES[themeOf(stage)].keys (= PALETTES[stage + 1]). Blinking keys are solid while
	((t + phase) % blinkPeriod) < blinkOn; sliding keys are offset along `axis` ("z") by
	travel * sin(2 pi (t + phase) / period), t = server time. Keys of one platform (`group`)
	blink / slide together. kind "block" keys belong to `blocks` (decor islands, group 0).
	Walls and bases are boxes by CENTRE (x, y, z) and size (sx, sy, sz).
	Treadmills: (x, z) centre, y = belt top; TREADMILL.length along X; yaw for
	CFrame.Angles(0, yaw, 0).

	New fields for World.CardioTrack (see the export types below for every field):
	  rooms    Room boxes { id, kind "lobby"|"bridge"|"zone", stage, theme, x0, x1 (whole
	           span incl. a bridge room's end walls), z0, z1 (side walls' inner faces),
	           floorY (hazard surface top; build a slab with its top here over x0..x1/z0..z1),
	           killY, wallTop }.
	  THEMES   by id: keys (3 RGB), hazard { color, material "Neon"|"Glass"|"SmoothPlastic"|
	           "Foil", liquid, pattern "tiles"|"river"|"waves"|"clouds"|"grid"|"stripes" },
	           wall, truss (neon X frames), edge (neon key-block edges), props (mesh names).
	  doors    { x (wall centre), y (= sill top, the doorway's bottom), z, width, height,
	           stage, side "west"|"east", timed, open, period, phase }: the doorway is open
	           while ((t + phase) % period) < open (doorOpen()); timed = false doors never
	           close (no slab, just a frame). Timed doors (east walls from stage 3) want a
	           countdown sign above them.
	  trusses  { a = {x,y,z}, b = {x,y,z}, thick, stage, wall } beam segments (square
	           section `thick`) of the orange X frames on a bridge room's inner wall faces.
	  props    { kind, x, y, z, yaw, scale, stage, wall, normal?, float }: candy meshes
	           (CandyDonut ...) scaled so their largest side = scale. Floor props: (x, y, z) =
	           bottom centre on the hazard floor (float = sunk into a liquid, y below
	           floorY). Wall props (wall = true): (x, y, z) = centre on the wall's inner face,
	           normal = unit vector into the room. yaw is radians about +Y.
	  blocks   { id, stage, x0, x1, z0, z1, top }: raised neon-edged key islands beside the
	           path (keys kind "block"); their `bases` (block = id) reach down to floorY.
	  signs    stage banner over the west doorway, inside the room (archSpan / archHeight
	           = the doorway frame's outer width / height above the deck).
]]

local Rules = require(script.Parent.CardioRules)

local CardioLayout = {}

CardioLayout.ORIGIN = { x = -1296, y = 20, z = 1150 }
-- The finish deck's far edge never passes this X (the east cap wall stands just past it):
-- the runway mirrors ORIGIN.x about x = 0.
CardioLayout.X_END = 1296
-- Key pitch (studs), keycap height and the visible cap size (keys touch at the pitch; the
-- thin seams show the base). The props/Key_A..Z meshes are scaled to (cap, height, cap).
CardioLayout.KEY = { size = 2.8, height = 1.16, cap = 2.72 }
-- Keys are visual only: every walkable surface has one invisible collision slab whose top is
-- PRESS below the key tops, and the client sinks the keys under feet by exactly PRESS (World.
-- CardioTrack sets it as the CardioTrack folder's PressDepth attribute), so feet rest on
-- pressed keys and the character never rides keys up and down (~0.85 x KEY.height: a key bottoms out almost flush with its base).
CardioLayout.PRESS = 1
-- Lobby width (studs, keys); bridge rooms and safe zones are ROOM.width wide.
CardioLayout.CORRIDOR = { width = 29 * CardioLayout.KEY.size, lanes = 29 }
-- Deck sizes in keys (along X, across Z). Safe zones span the bridge rooms' full width.
CardioLayout.LOBBY_KEYS = { long = 20, wide = 29 }
CardioLayout.ZONE_KEYS = { long = 16, wide = 45 }
CardioLayout.FINISH_KEYS = { long = 20, wide = 45 }
-- Safe zones: the middle band across Z (studs) that every doorway opens into. The WIN pad
-- and the treadmills stand outside it, so running from door to door touches neither.
CardioLayout.LANE = 25 * CardioLayout.KEY.size
-- The raised landing platform at a bridge room's far end (keys).
CardioLayout.END_KEYS = { long = 5, wide = 19 }
-- Bridge rooms: width between the side walls' inner faces, wall top above ORIGIN.y, hazard
-- floor depth below ORIGIN.y, and the margin the bridge (with mover sweeps) keeps from the
-- side walls.
CardioLayout.ROOM = { width = 126, height = 45, floorDrop = 10, margin = 22 }
-- Lobby / safe zone wall top above ORIGIN.y.
CardioLayout.ZONE_WALL_HEIGHT = 30
-- Feet this far above a room's floorY still count as standing (killY = floorY + KILL_ABOVE).
CardioLayout.KILL_ABOVE = 1.5
-- Feet below this (anywhere in the mode) count as a fall; every room's killY equals it.
CardioLayout.KILL_Y = CardioLayout.ORIGIN.y - CardioLayout.ROOM.floorDrop + CardioLayout.KILL_ABOVE
-- Shortest run-up a stage may get (studs, incl. the jog leg); generate() errors below it.
CardioLayout.RUNUP_MIN = 48
-- Side / cap walls: thickness and bottom Y (below the hazard floor).
CardioLayout.WALL = { thick = 2, bottom = 4 }
-- Bridge room end walls are one key thick so a sill key row fills each doorway.
CardioLayout.DOOR_WALL = CardioLayout.KEY.size
-- Doorways (both end walls): width in keys, height above the sill top; exit door timing per
-- stage (from stage 3).
CardioLayout.DOOR = { keys = 9, height = 14 }
-- Farthest a doorway's centre sits from the centre line (studs, whole keys): the doorway
-- stays inside the LANE, which is narrower than the lobby.
CardioLayout.DOOR_REACH = math.floor((CardioLayout.LANE / CardioLayout.KEY.size - CardioLayout.DOOR.keys) / 2 + 1e-6)
	* CardioLayout.KEY.size
CardioLayout.DOOR_TIMES = {
	[3] = { open = 4, period = 6 },
	[4] = { open = 3.8, period = 6 },
	[5] = { open = 3.5, period = 6 },
	[6] = { open = 3.3, period = 5.8 },
	[7] = { open = 3, period = 5.5 },
	[8] = { open = 2.8, period = 5.2 },
	[9] = { open = 2.6, period = 5 },
	[10] = { open = 2.5, period = 5 },
} :: { [number]: { open: number, period: number } }
-- Chocolate slab under every static carpet: thickness, and the air between its top and the
-- key bottoms.
CardioLayout.BASE = { depth = 2, drop = 0.2 }
-- X-truss frames: beam thickness and target bay width (studs).
CardioLayout.TRUSS = { thick = 1.6, bay = 52 }
-- Per bridge room: floor props, wall props, decor key blocks, extra floor props in clusters
-- along the side walls, and groups of three wall props.
CardioLayout.PROPS = { floor = 26, wall = 8, blocks = 4, edgeFloor = 9, wallGroups = 4 }
-- Clearance (studs) between floor props / blocks and the path's footprint (incl. gaps).
CardioLayout.PROP_CLEAR = 4
CardioLayout.TREADMILL = { length = 10, width = 6, height = 1.2 }
CardioLayout.UPGRADE_PAD = 6
-- WIN pad side (studs, whole keys) and, in keys from the centre line, where its centre and
-- the two treadmill rows sit across Z in safe zones 1..9 (zone 10's pad is on the centre line).
CardioLayout.WIN_PAD = 5 * CardioLayout.KEY.size
CardioLayout.WIN_PAD_SIDE = 18
CardioLayout.TREADMILL_ROWS = { 15.5, 19.5 }
-- Stage banner centre height above the deck (over the west doorway).
CardioLayout.SIGN_HEIGHT = 24
CardioLayout.ARCH = { frame = 2 }
-- Chance a key's tint avoids both its left and back neighbours' tints (else fully random).
CardioLayout.TINT_SPREAD = 0.8

export type RGB = { r: number, g: number, b: number }

local function rgb(r: number, g: number, b: number): RGB
	return { r = r, g = g, b = b }
end

export type Hazard = { color: RGB, material: string, liquid: boolean, pattern: string }
export type Theme = {
	id: string,
	name: string,
	-- Key tints 1..3.
	keys: { RGB },
	hazard: Hazard,
	wall: RGB,
	truss: RGB,
	edge: RGB,
	props: { string },
}

local function theme(id: string, name: string, keys: { RGB }, hazard: Hazard, wall: RGB, truss: RGB, edge: RGB, props: { string }): Theme
	return { id = id, name = name, keys = keys, hazard = hazard, wall = wall, truss = truss, edge = edge, props = props }
end

local ORANGE = rgb(255, 112, 12)

CardioLayout.THEMES = {
	candy = theme(
		"candy",
		"Candy Pixels",
		{ rgb(255, 182, 222), rgb(214, 168, 255), rgb(200, 196, 255) },
		{ color = rgb(255, 130, 210), material = "SmoothPlastic", liquid = false, pattern = "tiles" },
		rgb(255, 168, 214),
		ORANGE,
		rgb(255, 90, 200),
		{ "CandyLollipop", "CandySwirl", "CandyMacaron", "CandyGummyBear", "CandyCupcake", "CandyStrawberry" }
	),
	choco = theme(
		"choco",
		"Chocolate River",
		{ rgb(214, 160, 112), rgb(242, 198, 132), rgb(255, 234, 200) },
		{ color = rgb(168, 102, 58), material = "SmoothPlastic", liquid = true, pattern = "river" },
		rgb(196, 128, 82),
		ORANGE,
		rgb(255, 170, 60),
		{ "CandyBar", "CandyCookie", "CandyTruffle", "CandyDonut", "CandyStrawberry", "CandyCone" }
	),
	mint = theme(
		"mint",
		"Mint Ice",
		{ rgb(170, 240, 215), rgb(205, 248, 255), rgb(140, 220, 200) },
		{ color = rgb(110, 232, 214), material = "Glass", liquid = true, pattern = "waves" },
		rgb(160, 236, 216),
		ORANGE,
		rgb(60, 255, 210),
		{ "CandyIceCube", "CandyCane", "CandySwirl", "CandyMacaron", "CandyCone" }
	),
	cotton = theme(
		"cotton",
		"Cotton Clouds",
		{ rgb(255, 200, 230), rgb(200, 220, 255), rgb(240, 240, 255) },
		{ color = rgb(255, 212, 240), material = "SmoothPlastic", liquid = false, pattern = "clouds" },
		rgb(200, 186, 255),
		ORANGE,
		rgb(140, 170, 255),
		{ "CandyCottonCloud", "CandyLollipop", "CandyCupcake", "CandyMacaron", "CandyGummyBear" }
	),
	caramel = theme(
		"caramel",
		"Caramel Falls",
		{ rgb(250, 196, 120), rgb(255, 224, 160), rgb(236, 176, 104) },
		{ color = rgb(238, 162, 60), material = "Foil", liquid = true, pattern = "river" },
		rgb(245, 182, 100),
		ORANGE,
		rgb(255, 230, 90),
		{ "CandyDonut", "CandyCookie", "CandyBar", "CandyCone", "CandyTruffle" }
	),
	berry = theme(
		"berry",
		"Berry Jam",
		{ rgb(255, 150, 182), rgb(255, 192, 212), rgb(242, 128, 168) },
		{ color = rgb(255, 70, 140), material = "Glass", liquid = true, pattern = "waves" },
		rgb(255, 150, 186),
		ORANGE,
		rgb(255, 60, 140),
		{ "CandyStrawberry", "CandyMacaron", "CandyCupcake", "CandyGummyBear", "CandyLollipop" }
	),
	cherry = theme(
		"cherry",
		"Cherry Candy",
		{ rgb(255, 146, 146), rgb(255, 184, 160), rgb(246, 124, 140) },
		{ color = rgb(255, 72, 96), material = "SmoothPlastic", liquid = false, pattern = "tiles" },
		rgb(244, 104, 118),
		ORANGE,
		rgb(255, 200, 40),
		{ "CandyCane", "CandyGummyBear", "CandyTruffle", "CandyBar", "CandyIceCube" }
	),
	grape = theme(
		"grape",
		"Grape Soda",
		{ rgb(204, 164, 255), rgb(226, 198, 255), rgb(184, 142, 244) },
		{ color = rgb(170, 96, 255), material = "Glass", liquid = true, pattern = "waves" },
		rgb(192, 146, 255),
		ORANGE,
		rgb(200, 90, 255),
		{ "CandyGummyBear", "CandySwirl", "CandyIceCube", "CandyLollipop", "CandyMacaron" }
	),
	midnight = theme(
		"midnight",
		"Midnight Neon",
		{ rgb(156, 176, 255), rgb(196, 160, 255), rgb(140, 228, 255) },
		{ color = rgb(20, 240, 255), material = "Neon", liquid = false, pattern = "grid" },
		rgb(104, 82, 196),
		ORANGE,
		rgb(0, 255, 230),
		{ "CandySwirl", "CandyLollipop", "CandyCane", "CandyDonut", "CandyIceCube" }
	),
	rainbow = theme(
		"rainbow",
		"Rainbow Finale",
		{ rgb(255, 172, 172), rgb(166, 226, 255), rgb(255, 238, 150) },
		{ color = rgb(255, 255, 255), material = "Neon", liquid = false, pattern = "stripes" },
		rgb(255, 200, 236),
		ORANGE,
		rgb(255, 120, 255),
		{
			"CandyStrawberry",
			"CandyDonut",
			"CandyCupcake",
			"CandyCookie",
			"CandySwirl",
			"CandyCone",
			"CandyBar",
			"CandyCane",
			"CandyLollipop",
			"CandyGummyBear",
			"CandyMacaron",
			"CandyTruffle",
			"CandyCottonCloud",
			"CandyIceCube",
		}
	),
} :: { [string]: Theme }

-- Theme id of every stage's bridge room and safe zone; STAGE_THEMES[0] is the lobby.
CardioLayout.STAGE_THEMES = {
	[0] = "candy",
	[1] = "candy",
	[2] = "choco",
	[3] = "mint",
	[4] = "cotton",
	[5] = "caramel",
	[6] = "berry",
	[7] = "cherry",
	[8] = "grape",
	[9] = "midnight",
	[10] = "rainbow",
} :: { [number]: string }

function CardioLayout.themeOf(stage: number): Theme
	return CardioLayout.THEMES[CardioLayout.STAGE_THEMES[stage] or "candy"]
end

-- Key palettes, PALETTES[stage + 1][tint] (stage 0 = lobby), from the themes.
CardioLayout.PALETTES = {} :: { { RGB } }
for stage = 0, Rules.STAGE_COUNT do
	CardioLayout.PALETTES[stage + 1] = CardioLayout.themeOf(stage).keys
end

local ROWS = { "QWERTYUIOP", "ASDFGHJKL", "ZXCVBNM" }

export type Key = {
	x: number,
	y: number,
	z: number,
	sx: number,
	sz: number,
	-- "A".."Z".
	letter: string,
	stage: number,
	-- "deck" (lobby / safe zones) | "key" (run / key / end / sill platforms) | "blink" |
	-- "mover" | "block" (decor islands).
	kind: string,
	-- Platform id = index into Layout.platforms (keys of one platform blink / slide together);
	-- 0 for decks and blocks.
	group: number,
	-- Colour: index 1..3 into PALETTES[stage + 1] (see CardioLayout.tintOf).
	tint: number,
	-- Index into Layout.blocks for kind "block".
	block: number?,
	blinkOn: number?,
	blinkPeriod: number?,
	phase: number?,
	axis: string?,
	travel: number?,
	period: number?,
}

export type Point = { x: number, y: number, z: number }
export type Pad = { x: number, z: number, size: number }
export type Treadmill = { x: number, y: number, z: number, yaw: number }

export type Zone = {
	stage: number,
	x0: number,
	x1: number,
	z0: number,
	z1: number,
	top: number,
	-- A key centre near the zone's entrance, on the centre line (the lobby's is where every
	-- run starts and where a fall, a catch and a WIN pad claim put you).
	spawn: Point,
	treadmills: { Treadmill },
	upgradePad: Pad?,
	-- Safe zones 1..10: the square WIN pad (cash out here; Modes.Cardio).
	winPad: Pad?,
}

export type Platform = {
	id: number,
	stage: number,
	-- 0 for the run-up pieces and the west sill, k = the platform after jump k, #jumps for
	-- the end platform and the east sill.
	index: number,
	x0: number,
	x1: number,
	z0: number,
	z1: number,
	top: number,
	-- "sill" | "run" | "key" | "blink" | "mover" | "end".
	kind: string,
	-- For sills: index into Layout.doors.
	door: number?,
	blinkOn: number?,
	blinkPeriod: number?,
	phase: number?,
	travel: number?,
	period: number?,
}

-- Stage banner: (x, y, z) is its centre, inside bridge room n just past the west doorway;
-- the doorway frame around the entrance is archSpan wide (outer) and archHeight tall above
-- the deck (ORIGIN.y).
export type Sign = {
	stage: number,
	need: number,
	name: string,
	x: number,
	y: number,
	z: number,
	archSpan: number,
	archHeight: number,
}

-- Box by centre and size. side = "north" (+Z) | "south" (-Z) side walls, "west" | "east"
-- end walls (bridge room doors, lobby / finish caps). part = "full" | "left" | "right" |
-- "lintel" | "under" (end wall pieces around a doorway). gap = true where the wall runs
-- along hazard (bridge rooms).
export type Wall = {
	x: number,
	y: number,
	z: number,
	sx: number,
	sy: number,
	sz: number,
	stage: number,
	room: number,
	side: string,
	part: string,
	gap: boolean,
}
-- Slab under a static carpet: group = platform id (0 for decks / blocks); block = block id
-- for a block's pillar (reaches the hazard floor).
export type Base = {
	x: number,
	y: number,
	z: number,
	sx: number,
	sy: number,
	sz: number,
	stage: number,
	group: number,
	block: number?,
}
export type Bounds = { x0: number, x1: number, z0: number, z1: number }

export type Room = {
	id: number,
	-- "lobby" | "bridge" | "zone".
	kind: string,
	stage: number,
	theme: string,
	x0: number,
	x1: number,
	z0: number,
	z1: number,
	-- Hazard floor top (bridge rooms; under the deck elsewhere).
	floorY: number,
	-- Feet below this inside the room = fall.
	killY: number,
	wallTop: number,
}

export type Door = {
	x: number,
	y: number,
	z: number,
	width: number,
	height: number,
	stage: number,
	side: string,
	timed: boolean,
	open: number,
	period: number,
	phase: number,
}

export type Beam = { a: Point, b: Point, thick: number, stage: number, wall: string }

export type Prop = {
	kind: string,
	x: number,
	y: number,
	z: number,
	yaw: number,
	scale: number,
	stage: number,
	wall: boolean,
	normal: Point?,
	float: boolean,
}

export type Block = { id: number, stage: number, x0: number, x1: number, z0: number, z1: number, top: number }

export type Layout = {
	keys: { Key },
	zones: { Zone },
	-- Every walkable bridge surface in course order; platforms[id].id == id.
	platforms: { Platform },
	signs: { Sign },
	walls: { Wall },
	bases: { Base },
	rooms: { Room },
	doors: { Door },
	trusses: { Beam },
	props: { Prop },
	blocks: { Block },
	finish: Point,
	bounds: Bounds,
}

-- Park-Miller LCG: exact in doubles, values in [0, 1).
local function lcg(seed: number): () -> number
	local state = seed
	return function()
		state = (state * 16807) % 2147483647
		return state / 2147483647
	end
end

local function round1(v: number): number
	return math.floor(v * 10 + 0.5) / 10
end

type Rect = { x0: number, x1: number, z0: number, z1: number }
type Surface = { x0: number, x1: number, z0: number, z1: number, top: number, stage: number }

-- Horizontal distance between two rectangles (0 when they touch or overlap).
local function rectDist(a: Rect, b: Rect): number
	local dx = math.max(0, a.x0 - b.x1, b.x0 - a.x1)
	local dz = math.max(0, a.z0 - b.z1, b.z0 - a.z1)
	return math.sqrt(dx * dx + dz * dz)
end
CardioLayout.rectDist = rectDist

-- The path's footprint in one bridge room: every surface (sliding ones over their sweep)
-- plus the air box over every gap (spanning both sides across Z).
function CardioLayout.footprint(platforms: { Platform }, stage: number): { Rect }
	local out: { Rect } = {}
	local prev: Rect? = nil
	for _, p in platforms do
		if p.stage == stage then
			local t = p.travel or 0
			local r = { x0 = p.x0, x1 = p.x1, z0 = p.z0 - t, z1 = p.z1 + t }
			table.insert(out, r)
			if prev and r.x0 > prev.x1 + 1e-6 then
				table.insert(out, { x0 = prev.x1, x1 = r.x0, z0 = math.min(prev.z0, r.z0), z1 = math.max(prev.z1, r.z1) })
			end
			prev = r
		end
	end
	return out
end

function CardioLayout.generate(): Layout
	local rand = lcg(20261007)
	local K = CardioLayout.KEY.size
	local O = CardioLayout.ORIGIN
	local HALF = CardioLayout.CORRIDOR.width / 2
	local R = CardioLayout.ROOM
	local RHALF = R.width / 2
	local DW = CardioLayout.DOOR_WALL
	local W = CardioLayout.WALL
	local floorY = O.y - R.floorDrop
	local keys: { Key } = {}
	local zones: { Zone } = {}
	local platforms: { Platform } = {}
	local signs: { Sign } = {}
	local walls: { Wall } = {}
	local bases: { Base } = {}
	local rooms: { Room } = {}
	local doors: { Door } = {}
	local trusses: { Beam } = {}
	local props: { Prop } = {}
	local blocks: { Block } = {}
	-- Global key column counter (letters shift one key per column).
	local column = 0

	local function pickTint(left: number?, back: number?): number
		local strict = rand() < CardioLayout.TINT_SPREAD
		local options = {}
		for t = 1, 3 do
			if not strict or (t ~= left and t ~= back) then
				table.insert(options, t)
			end
		end
		return options[math.floor(rand() * #options) + 1]
	end

	local function letterAt(z: number): string
		local row = ROWS[column % 3 + 1]
		local lane = math.floor((z - (O.z - HALF)) / K + 1e-6)
		local c = (lane + column) % #row + 1
		return string.sub(row, c, c)
	end

	-- Lays a carpet of `lanes` keys across from z0, `cols` keys along X from x0.
	local function carpet(
		stage: number,
		x0: number,
		cols: number,
		z0: number,
		lanes: number,
		top: number,
		kind: string,
		group: number,
		p: Platform?,
		block: number?
	)
		local back: { number } = {}
		for i = 0, cols - 1 do
			local left: number? = nil
			local row: { number } = {}
			for l = 0, lanes - 1 do
				local tint = pickTint(left, back[l])
				local z = z0 + K / 2 + l * K
				local key: Key = {
					x = x0 + i * K + K / 2,
					y = top,
					z = z,
					sx = K,
					sz = K,
					letter = letterAt(z),
					stage = stage,
					kind = kind,
					group = group,
					tint = tint,
					block = block,
				}
				if p and (p.kind == "blink" or p.kind == "mover") then
					key.blinkOn = p.blinkOn
					key.blinkPeriod = p.blinkPeriod
					key.phase = p.phase
					key.axis = if p.kind == "mover" then "z" else nil
					key.travel = p.travel
					key.period = p.period
				end
				table.insert(keys, key)
				row[l] = tint
				left = tint
			end
			back = row
			column += 1
		end
	end

	local function addBase(box: Surface, group: number)
		local B = CardioLayout.BASE
		table.insert(bases, {
			x = (box.x0 + box.x1) / 2,
			y = box.top - CardioLayout.KEY.height - B.drop - B.depth / 2,
			z = (box.z0 + box.z1) / 2,
			sx = box.x1 - box.x0,
			sy = B.depth,
			sz = box.z1 - box.z0,
			stage = box.stage,
			group = group,
		})
	end

	-- Snap a spawn to a key centre: a respawn on a key seam drops the Humanoid's floor ray
	-- between the caps, so the character sinks into the keys.
	local function spawnOn(box: Surface, x: number, y: number, z: number): Point
		return {
			x = box.x0 + (math.floor((x - box.x0) / K) + 0.5) * K,
			y = y,
			z = box.z0 + (math.floor((z - box.z0) / K) + 0.5) * K,
		}
	end

	local function addWall(
		x0: number,
		x1: number,
		y0: number,
		y1: number,
		z0: number,
		z1: number,
		stage: number,
		room: number,
		side: string,
		part: string,
		gap: boolean
	)
		if x1 - x0 < 1e-6 or y1 - y0 < 1e-6 or z1 - z0 < 1e-6 then
			return
		end
		table.insert(walls, {
			x = (x0 + x1) / 2,
			y = (y0 + y1) / 2,
			z = (z0 + z1) / 2,
			sx = x1 - x0,
			sy = y1 - y0,
			sz = z1 - z0,
			stage = stage,
			room = room,
			side = side,
			part = part,
			gap = gap,
		})
	end

	local function addRoom(kind: string, stage: number, x0: number, x1: number, half: number, wallTop: number): Room
		local room: Room = {
			id = #rooms + 1,
			kind = kind,
			stage = stage,
			theme = CardioLayout.STAGE_THEMES[stage],
			x0 = x0,
			x1 = x1,
			z0 = O.z - half,
			z1 = O.z + half,
			floorY = floorY,
			killY = floorY + CardioLayout.KILL_ABOVE,
			wallTop = wallTop,
		}
		table.insert(rooms, room)
		-- Side walls.
		for _, side in { "south", "north" } do
			local zIn = if side == "north" then room.z1 else room.z0 - W.thick
			addWall(x0, x1, W.bottom, wallTop, zIn, zIn + W.thick, stage, room.id, side, "full", kind == "bridge")
		end
		return room
	end

	local function deck(stage: number, x0: number, long: number, wide: number): Zone
		local z0 = O.z - wide * K / 2
		carpet(stage, x0, long, z0, wide, O.y, "deck", 0, nil)
		local zone: Zone = {
			stage = stage,
			x0 = x0,
			x1 = x0 + long * K,
			z0 = z0,
			z1 = z0 + wide * K,
			top = O.y,
			spawn = { x = x0 + 6, y = O.y + 3, z = O.z },
			treadmills = {},
			upgradePad = nil,
			winPad = nil,
		}
		table.insert(zones, zone)
		local box = { x0 = zone.x0, x1 = zone.x1, z0 = zone.z0, z1 = zone.z1, top = O.y, stage = stage }
		addBase(box, 0)
		zone.spawn = spawnOn(box, zone.spawn.x, zone.spawn.y, zone.spawn.z)
		addRoom(if stage == 0 then "lobby" else "zone", stage, zone.x0, zone.x1, wide * K / 2, O.y + CardioLayout.ZONE_WALL_HEIGHT)
		return zone
	end

	local function platform(p: Platform): Surface
		table.insert(platforms, p)
		local box = { x0 = p.x0, x1 = p.x1, z0 = p.z0, z1 = p.z1, top = p.top, stage = p.stage }
		local kind = if p.kind == "blink" or p.kind == "mover" then p.kind else "key"
		local cols = math.floor((p.x1 - p.x0) / K + 0.5)
		local lanes = math.floor((p.z1 - p.z0) / K + 0.5)
		carpet(p.stage, p.x0, cols, p.z0, lanes, p.top, kind, p.id, p)
		if kind == "key" then
			addBase(box, p.id)
		end
		return box
	end

	-- An end wall (one key thick, x0..x0+DW) across a bridge room with a doorway; the sill
	-- platform fills the doorway's floor.
	local function endWall(
		x0: number,
		room: Room,
		side: string,
		zc: number,
		width: number,
		stage: number,
		timing: { open: number, period: number }?
	)
		local B = CardioLayout.BASE
		local zA, zB = O.z - RHALF - W.thick, O.z + RHALF + W.thick
		local dz0, dz1 = zc - width / 2, zc + width / 2
		local under = O.y - CardioLayout.KEY.height - B.drop - B.depth
		local doorTop = O.y + CardioLayout.DOOR.height
		addWall(x0, x0 + DW, W.bottom, room.wallTop, zA, dz0, stage, room.id, side, "left", false)
		addWall(x0, x0 + DW, W.bottom, room.wallTop, dz1, zB, stage, room.id, side, "right", false)
		addWall(x0, x0 + DW, doorTop, room.wallTop, dz0, dz1, stage, room.id, side, "lintel", false)
		addWall(x0, x0 + DW, W.bottom, under, dz0, dz1, stage, room.id, side, "under", false)
		table.insert(doors, {
			x = x0 + DW / 2,
			y = O.y,
			z = zc,
			width = width,
			height = CardioLayout.DOOR.height,
			stage = stage,
			side = side,
			timed = timing ~= nil,
			open = if timing then timing.open else 1,
			period = if timing then timing.period else 1,
			phase = if timing then round1(rand() * timing.period) else 0,
		})
		local sill: Platform = {
			id = #platforms + 1,
			stage = stage,
			index = 0,
			x0 = x0,
			x1 = x0 + DW,
			z0 = dz0,
			z1 = dz1,
			top = O.y,
			kind = "sill",
			door = #doors,
		}
		return sill
	end

	-- X-truss frame on a wall face: u runs along the wall (X for side walls, Z for end walls),
	-- `at(u, y)` maps to world; bays between u0..u1 and y0..y1 (two tiers when tall).
	local function frame(
		u0: number,
		u1: number,
		y0: number,
		y1: number,
		stage: number,
		wall: string,
		at: (number, number) -> Point,
		skip: ((number, number) -> boolean)?
	)
		local T = CardioLayout.TRUSS
		local bays = math.max(1, math.floor((u1 - u0) / T.bay + 0.5))
		local tiers = if y1 - y0 > 40 then 2 else 1
		local bw, th = (u1 - u0) / bays, (y1 - y0) / tiers
		local function beam(ua: number, ya: number, ub: number, yb: number)
			table.insert(trusses, { a = at(ua, ya), b = at(ub, yb), thick = T.thick, stage = stage, wall = wall })
		end
		for t = 0, tiers - 1 do
			local ya, yb = y0 + t * th, y0 + (t + 1) * th
			for b = 0, bays - 1 do
				local ua, ub = u0 + b * bw, u0 + (b + 1) * bw
				if not (skip and skip(ua, ub)) then
					beam(ua, ya, ub, yb)
					beam(ua, yb, ub, ya)
					beam(ua, yb, ub, yb)
					if t == 0 then
						beam(ua, ya, ub, ya)
					end
					beam(ua, ya, ua, yb)
					if b == bays - 1 or (skip and skip(ub, ub + bw)) then
						beam(ub, ya, ub, yb)
					end
				end
			end
		end
	end

	-- Run-up length: what is left of ORIGIN.x..X_END, shared evenly, in whole keys.
	local fixed = (CardioLayout.LOBBY_KEYS.long + CardioLayout.ZONE_KEYS.long * (Rules.STAGE_COUNT - 1) + CardioLayout.FINISH_KEYS.long) * K
	for _, s in Rules.STAGES do
		fixed += s.length + 2 * DW + CardioLayout.END_KEYS.long * K
	end
	local runCols = math.floor((CardioLayout.X_END - O.x - fixed) / Rules.STAGE_COUNT / K)
	if runCols * K < CardioLayout.RUNUP_MIN then
		error(`CardioLayout: run-ups would be {runCols * K} studs (< {CardioLayout.RUNUP_MIN})`)
	end

	local belt = O.y + CardioLayout.TREADMILL.height
	local face = -math.pi / 2

	-- Warm-Up lobby.
	local lobby = deck(0, O.x, CardioLayout.LOBBY_KEYS.long, CardioLayout.LOBBY_KEYS.wide)
	-- Two neat rows of four treadmills along the side walls, the lane between them free.
	for _, dz in { -28, 28 } do
		for _, dx in { 9, 20, 31, 42 } do
			table.insert(lobby.treadmills, { x = lobby.x0 + dx, y = belt, z = O.z + dz, yaw = face })
		end
	end
	lobby.upgradePad = { x = lobby.x0 + 46, z = O.z - 20, size = CardioLayout.UPGRADE_PAD }
	addWall(O.x - W.thick, O.x, W.bottom, rooms[1].wallTop, O.z - HALF - W.thick, O.z + HALF + W.thick, 0, 1, "west", "full", false)

	local function gridLat(v: number): number
		return math.floor(v / K + 0.5) * K
	end

	local prevZone = lobby
	for n = 1, Rules.STAGE_COUNT do
		local s = Rules.STAGES[n]
		local w = s.width
		local wCols = math.floor(w / K + 0.5)
		local look = CardioLayout.themeOf(n)
		local room: Room = {
			id = #rooms + 1,
			kind = "bridge",
			stage = n,
			theme = look.id,
			x0 = prevZone.x1,
			x1 = prevZone.x1,
			z0 = O.z - RHALF,
			z1 = O.z + RHALF,
			floorY = floorY,
			killY = floorY + CardioLayout.KILL_ABOVE,
			wallTop = O.y + R.height,
		}
		table.insert(rooms, room)
		local reach = math.floor((RHALF - R.margin - w / 2) / K) * K
		local doorMax = CardioLayout.DOOR_REACH
		local doorWide = CardioLayout.DOOR.keys * K
		local first = #platforms + 1

		-- West doorway and run-up: a straight run, a sideways leg, a second run.
		local latA = gridLat((rand() * 2 - 1) * math.min(doorMax, reach))
		local cur = room.x0
		platform(endWall(cur, room, "west", O.z + latA, math.max(w, doorWide), n, nil))
		local sillIn = doors[#doors]
		cur += DW
		local shift = (2 + math.floor(rand() * 5)) * K
		local latC = if latA + shift <= reach and (latA - shift < -reach or rand() < 0.5) then latA + shift else latA - shift
		latC = math.clamp(latC, -reach, reach)
		local legCols = wCols
		local aCols = math.floor((runCols - legCols) / 2)
		local cCols = runCols - legCols - aCols
		local function run(x0: number, cols: number, z0: number, z1: number): Surface
			return platform({
				id = #platforms + 1,
				stage = n,
				index = 0,
				x0 = x0,
				x1 = x0 + cols * K,
				z0 = z0,
				z1 = z1,
				top = O.y,
				kind = "run",
			})
		end
		run(cur, aCols, O.z + latA - w / 2, O.z + latA + w / 2)
		cur += aCols * K
		run(cur, legCols, O.z + math.min(latA, latC) - w / 2, O.z + math.max(latA, latC) + w / 2)
		cur += legCols * K
		run(cur, cCols, O.z + latC - w / 2, O.z + latC + w / 2)
		cur += cCols * K
		table.insert(signs, {
			stage = n,
			need = s.need,
			name = s.name,
			x = room.x0 + DW + 1,
			y = O.y + CardioLayout.SIGN_HEIGHT,
			z = sillIn.z,
			archSpan = sillIn.width + 2 * CardioLayout.ARCH.frame,
			archHeight = sillIn.height + CardioLayout.ARCH.frame,
		})

		-- Jump platforms.
		local jumps = Rules.jumps(n)
		local top = O.y
		local prevLat, prevW = latC, w
		local endHalf = CardioLayout.END_KEYS.wide * K / 2
		for k = 1, #jumps - 1 do
			local j = jumps[k]
			cur += j.gap
			top += j.rise
			-- From stage 4 every odd platform is special (its neighbours are solid): blinking,
			-- or sliding from stage 6 (alternating, starting with a slider on even stages).
			local kind = "key"
			if k % 2 == 1 and s.blinkOn then
				kind = if s.movers and (n + (k + 1) / 2) % 2 == 1 then "mover" else "blink"
			end
			-- Sideways shift on the key grid; consecutive surfaces share >= 2 keys of width;
			-- the last platform stays within reach of the end platform.
			local lat = prevLat
			if kind ~= "mover" then
				local options = {}
				for l = -reach, reach, K do
					local ok = math.abs(l - prevLat) <= (w + prevW) / 2 - 2 * K
					if k == #jumps - 1 then
						ok = ok and math.abs(l - math.clamp(l, -doorMax, doorMax)) <= endHalf + w / 2 - 2 * K
					end
					if ok then
						table.insert(options, l)
					end
				end
				lat = options[math.floor(rand() * #options) + 1]
			end
			local zc = O.z + lat
			local p: Platform = {
				id = #platforms + 1,
				stage = n,
				index = k,
				x0 = cur,
				x1 = cur + s.plat,
				z0 = zc - w / 2,
				z1 = zc + w / 2,
				top = top,
				kind = kind,
			}
			if kind == "blink" then
				p.blinkOn = s.blinkOn
				p.blinkPeriod = s.blinkPeriod
				p.phase = round1(rand() * (s.blinkPeriod :: number))
			elseif kind == "mover" then
				local m = s.movers :: Rules.Movers
				p.travel = m.travel
				p.period = m.period
				p.phase = round1(rand() * m.period)
			end
			platform(p)
			prevLat, prevW = lat, w
			cur += s.plat
		end

		-- End platform and the east doorway.
		cur += jumps[#jumps].gap
		local latE = math.clamp(prevLat, -doorMax, doorMax)
		platform({
			id = #platforms + 1,
			stage = n,
			index = #jumps,
			x0 = cur,
			x1 = cur + CardioLayout.END_KEYS.long * K,
			z0 = O.z + latE - endHalf,
			z1 = O.z + latE + endHalf,
			top = O.y,
			kind = "end",
		})
		cur += CardioLayout.END_KEYS.long * K
		local sillOut = endWall(cur, room, "east", O.z + latE, doorWide, n, CardioLayout.DOOR_TIMES[n])
		sillOut.index = #jumps
		platform(sillOut)
		cur += DW
		room.x1 = cur
		for _, side in { "south", "north" } do
			local zIn = if side == "north" then room.z1 else room.z0 - W.thick
			addWall(room.x0, room.x1, W.bottom, room.wallTop, zIn, zIn + W.thick, n, room.id, side, "full", true)
		end

		-- The path's footprint (with the gaps' air) keeps decor clear of every run and jump.
		local roomPlats = {}
		for id = first, #platforms do
			table.insert(roomPlats, platforms[id])
		end
		local foot = CardioLayout.footprint(roomPlats, n)
		local ix0, ix1 = room.x0 + DW, room.x1 - DW
		local function clearOf(r: Rect, d: number): boolean
			for _, f in foot do
				if rectDist(r, f) < d then
					return false
				end
			end
			return true
		end

		-- Trusses: side walls full height; end walls above the doorways' head room, and full
		-- height only away from the path. The top chord sits a beam below the wall top so
		-- every beam has wall behind it.
		local tk = CardioLayout.TRUSS.thick
		frame(ix0, ix1, floorY, room.wallTop - tk, n, "south", function(u, y)
			return { x = u, y = y, z = room.z0 + tk / 2 }
		end)
		frame(ix0, ix1, floorY, room.wallTop - tk, n, "north", function(u, y)
			return { x = u, y = y, z = room.z1 - tk / 2 }
		end)
		local band = O.y + CardioLayout.DOOR.height + 4
		for _, e in { { side = "west", x = ix0 + tk / 2 }, { side = "east", x = ix1 - tk / 2 } } do
			local function at(u: number, y: number): Point
				return { x = e.x, y = y, z = u }
			end
			frame(room.z0, room.z1, band, room.wallTop - tk, n, e.side, at)
			frame(room.z0, room.z1, floorY, band, n, e.side, at, function(u0: number, u1: number)
				return not clearOf({ x0 = e.x - tk, x1 = e.x + tk, z0 = u0, z1 = u1 }, CardioLayout.PROP_CLEAR)
			end)
		end

		-- Raised neon-edged key blocks beside the path.
		local roomBlocks: { Rect } = {}
		for _ = 1, 80 do
			if #roomBlocks >= CardioLayout.PROPS.blocks then
				break
			end
			local cols = 3 + math.floor(rand() * 2)
			local lanes = 3 + math.floor(rand() * 2)
			local bx = ix0 + 8 + rand() * (ix1 - ix0 - 16 - cols * K)
			local bz = room.z0 + 8 + rand() * (R.width - 16 - lanes * K)
			local r = { x0 = bx, x1 = bx + cols * K, z0 = bz, z1 = bz + lanes * K }
			local ok = clearOf(r, 2 * CardioLayout.PROP_CLEAR)
			for _, o in roomBlocks do
				ok = ok and rectDist(r, o) >= 8
			end
			if ok then
				table.insert(roomBlocks, r)
				local btop = O.y + math.floor(rand() * 7) / 2
				local id = #blocks + 1
				table.insert(blocks, { id = id, stage = n, x0 = r.x0, x1 = r.x1, z0 = r.z0, z1 = r.z1, top = btop })
				carpet(n, r.x0, cols, r.z0, lanes, btop, "block", 0, nil, id)
				local pillarTop = btop - CardioLayout.KEY.height - CardioLayout.BASE.drop
				table.insert(bases, {
					x = (r.x0 + r.x1) / 2,
					y = (pillarTop + floorY) / 2,
					z = (r.z0 + r.z1) / 2,
					sx = r.x1 - r.x0,
					sy = pillarTop - floorY,
					sz = r.z1 - r.z0,
					stage = n,
					group = 0,
					block = id,
				})
			end
		end

		-- Candy props on the hazard floor (sunk into liquids) and stuck on the side walls.
		local placed: { { x: number, z: number, r: number } } = {}
		local floorCount = 0
		for _ = 1, 400 do
			if floorCount >= CardioLayout.PROPS.floor then
				break
			end
			local scale = round1(6 + rand() * 10)
			local r = scale / 2
			local x = ix0 + r + 2 + rand() * (ix1 - ix0 - 2 * r - 4)
			local z = room.z0 + r + 2 + rand() * (R.width - 2 * r - 4)
			local kind = look.props[math.floor(rand() * #look.props) + 1]
			local yaw = math.floor(rand() * 628) / 100
			local box = { x0 = x - r, x1 = x + r, z0 = z - r, z1 = z + r }
			local ok = clearOf(box, CardioLayout.PROP_CLEAR)
			for _, b in roomBlocks do
				ok = ok and rectDist(box, b) >= 2
			end
			for _, q in placed do
				ok = ok and math.sqrt((q.x - x) ^ 2 + (q.z - z) ^ 2) >= 0.8 * (q.r + r)
			end
			if ok then
				x, z = round1(x), round1(z)
				table.insert(placed, { x = x, z = z, r = r })
				floorCount += 1
				local liquid = look.hazard.liquid
				table.insert(props, {
					kind = kind,
					x = x,
					y = if liquid then round1(floorY - 0.3 * scale) else floorY,
					z = z,
					yaw = yaw,
					scale = scale,
					stage = n,
					wall = false,
					normal = nil,
					float = liquid,
				})
			end
		end
		for i = 1, CardioLayout.PROPS.wall do
			local scale = round1(9 + rand() * 7)
			local north = i % 2 == 0
			local x =
				round1(ix0 + (math.floor((i - 1) / 2) + 0.5 + (rand() - 0.5) * 0.6) * (ix1 - ix0) / math.ceil(CardioLayout.PROPS.wall / 2))
			table.insert(props, {
				kind = look.props[math.floor(rand() * #look.props) + 1],
				x = x,
				y = round1(O.y + 10 + rand() * (R.height - 18)),
				z = if north then room.z1 else room.z0,
				yaw = math.floor(rand() * 628) / 100,
				scale = scale,
				stage = n,
				wall = true,
				normal = { x = 0, y = 0, z = if north then -1 else 1 },
				float = false,
			})
		end

		-- Extra candy clusters from their own generator (the course's rand sequence, and so
		-- every path, stays as it was): big groups along the side walls' foot, and groups of
		-- three stuck on the walls.
		local extra = lcg(7700 + n * 131)
		local wanted = floorCount + CardioLayout.PROPS.edgeFloor
		for _ = 1, 300 do
			if floorCount >= wanted then
				break
			end
			local north = extra() < 0.5
			local ax = ix0 + 14 + extra() * (ix1 - ix0 - 28)
			for c = 1, 3 do
				local scale = round1(if c == 1 then 13 + extra() * 7 else 7 + extra() * 6)
				local r = scale / 2
				local x = ax + (if c == 1 then 0 else (extra() - 0.5) * 22)
				local inset = r + 1 + extra() * (if c == 1 then 3 else 9)
				local z = if north then room.z1 - inset else room.z0 + inset
				local box = { x0 = x - r, x1 = x + r, z0 = z - r, z1 = z + r }
				local ok = box.x0 >= ix0 + 1 and box.x1 <= ix1 - 1 and clearOf(box, CardioLayout.PROP_CLEAR)
				for _, b in roomBlocks do
					ok = ok and rectDist(box, b) >= 2
				end
				for _, q in placed do
					ok = ok and math.sqrt((q.x - x) ^ 2 + (q.z - z) ^ 2) >= 0.7 * (q.r + r)
				end
				if ok and floorCount < wanted then
					x, z = round1(x), round1(z)
					table.insert(placed, { x = x, z = z, r = r })
					floorCount += 1
					local liquid = look.hazard.liquid
					table.insert(props, {
						kind = look.props[math.floor(extra() * #look.props) + 1],
						x = x,
						y = if liquid then round1(floorY - 0.3 * scale) else floorY,
						z = z,
						yaw = math.floor(extra() * 628) / 100,
						scale = scale,
						stage = n,
						wall = false,
						normal = nil,
						float = liquid,
					})
				end
			end
		end
		local groups = CardioLayout.PROPS.wallGroups
		for g = 1, groups do
			local north = g % 2 == 1
			local ax = ix0 + (math.floor((g - 1) / 2) + 0.5 + (extra() - 0.5) * 0.4) * (ix1 - ix0) / math.ceil(groups / 2)
			local ay = O.y + 18 + extra() * (R.height - 30)
			for c = 1, 3 do
				local scale = round1(if c == 1 then 11 + extra() * 5 else 6 + extra() * 4)
				local r = scale / 2
				local x = math.clamp(ax + (if c == 1 then 0 else (c - 2.5) * 2 * (r + 6)), ix0 + r + 1, ix1 - r - 1)
				local y = math.clamp(ay + (if c == 1 then 0 else (extra() - 0.5) * 12), O.y + r + 1, room.wallTop - r - 1)
				table.insert(props, {
					kind = look.props[math.floor(extra() * #look.props) + 1],
					x = round1(x),
					y = round1(y),
					z = if north then room.z1 else room.z0,
					yaw = math.floor(extra() * 628) / 100,
					scale = scale,
					stage = n,
					wall = true,
					normal = { x = 0, y = 0, z = if north then -1 else 1 },
					float = false,
				})
			end
		end

		-- Safe zone n: the WIN pad in the north band (the last zone's on the centre line, in
		-- front of the finish podium), two rows of two treadmills in the south band.
		local final = n == Rules.STAGE_COUNT
		local size = if final then CardioLayout.FINISH_KEYS else CardioLayout.ZONE_KEYS
		local zone = deck(n, cur, size.long, size.wide)
		local mid = zone.x0 + CardioLayout.ZONE_KEYS.long * K / 2
		for _, row in CardioLayout.TREADMILL_ROWS do
			for _, dx in { -3.5 * K, 3.5 * K } do
				table.insert(zone.treadmills, { x = mid + dx, y = belt, z = O.z - row * K, yaw = face })
			end
		end
		local pad = CardioLayout.WIN_PAD
		local padCol = math.floor((size.long * K - pad) / 2 / K)
		zone.winPad = {
			x = zone.x0 + padCol * K + pad / 2,
			z = if final then O.z else O.z + CardioLayout.WIN_PAD_SIDE * K,
			size = pad,
		}
		prevZone = zone
	end
	local last = zones[#zones]
	addWall(
		last.x1,
		last.x1 + W.thick,
		W.bottom,
		rooms[#rooms].wallTop,
		last.z0 - W.thick,
		last.z1 + W.thick,
		Rules.STAGE_COUNT,
		#rooms,
		"east",
		"full",
		false
	)

	local bx0, bx1, bz0, bz1 = math.huge, -math.huge, math.huge, -math.huge
	local function grow(x0: number, x1: number, z0: number, z1: number)
		bx0, bx1 = math.min(bx0, x0), math.max(bx1, x1)
		bz0, bz1 = math.min(bz0, z0), math.max(bz1, z1)
	end
	for _, key in keys do
		local reachZ = key.sz / 2 + (key.travel or 0)
		grow(key.x - key.sx / 2, key.x + key.sx / 2, key.z - reachZ, key.z + reachZ)
	end
	for _, w in walls do
		grow(w.x - w.sx / 2, w.x + w.sx / 2, w.z - w.sz / 2, w.z + w.sz / 2)
	end
	return {
		keys = keys,
		zones = zones,
		platforms = platforms,
		signs = signs,
		walls = walls,
		bases = bases,
		rooms = rooms,
		doors = doors,
		trusses = trusses,
		props = props,
		blocks = blocks,
		finish = { x = last.x1 - 12, y = last.top, z = O.z },
		bounds = { x0 = bx0, x1 = bx1, z0 = bz0, z1 = bz1 },
	}
end

-- A key's colour as { r, g, b } (0..255).
function CardioLayout.tintOf(key: Key): RGB
	local palette = CardioLayout.PALETTES[key.stage + 1] or CardioLayout.PALETTES[1]
	return palette[key.tint] or palette[1]
end

-- The one layout every helper below reads (generate() is deterministic).
local LAYOUT = CardioLayout.generate()
CardioLayout.LAYOUT = LAYOUT

-- Keys hashed into CELL-stud squares (a key sits in every cell it touches, sliding keys over
-- their whole sweep).
local CELL = 8
local cells: { [number]: { Key } } = {}
local function cellId(cx: number, cz: number): number
	return cx * 65536 + cz
end
for _, key in LAYOUT.keys do
	local reachZ = key.sz / 2 + (key.travel or 0)
	for cx = math.floor((key.x - key.sx / 2) / CELL), math.floor((key.x + key.sx / 2) / CELL) do
		for cz = math.floor((key.z - reachZ) / CELL), math.floor((key.z + reachZ) / CELL) do
			local id = cellId(cx, cz)
			local list = cells[id]
			if not list then
				list = {}
				cells[id] = list
			end
			table.insert(list, key)
		end
	end
end

-- Safe zone of `stage` (0 = lobby).
function CardioLayout.zone(stage: number): Zone?
	return LAYOUT.zones[stage + 1]
end

-- The spawn of the safe zone of `stage` (0 = lobby). Modes.Cardio only uses the lobby's: every
-- run starts there, and a fall, a catch and a WIN pad claim all send you back to it.
function CardioLayout.spawn(stage: number): Point?
	local z = LAYOUT.zones[stage + 1]
	return if z then z.spawn else nil
end

-- The last safe zone passed at this X (the HUD runs stage + 1): n - 1 in bridge room n (not
-- stageAt's n), else stageAt(x).
function CardioLayout.startStageAt(x: number): number
	local room = CardioLayout.roomAt(x)
	return if room and room.kind == "bridge" then room.stage - 1 else CardioLayout.stageAt(x)
end

-- The safe zone whose deck is under (x, z); with y, only when the feet are near its top.
function CardioLayout.zoneAt(x: number, z: number, y: number?): Zone?
	for _, zone in LAYOUT.zones do
		if x >= zone.x0 and x <= zone.x1 and z >= zone.z0 and z <= zone.z1 then
			if y == nil or (y >= zone.top - 2 and y <= zone.top + 12) then
				return zone
			end
		end
	end
	return nil
end

-- Stage of the course at this X: 0 up to the lobby's far edge, n from safe zone n-1's far
-- edge through safe zone n.
function CardioLayout.stageAt(x: number): number
	for _, zone in LAYOUT.zones do
		if x <= zone.x1 then
			return zone.stage
		end
	end
	return Rules.STAGE_COUNT
end

-- Is a key solid at time t, and how far has it slid along its axis?
function CardioLayout.keyState(key: Key, t: number): (boolean, number)
	local on = true
	if key.blinkOn and key.blinkPeriod then
		on = ((t + (key.phase or 0)) % key.blinkPeriod) < key.blinkOn
	end
	local offset = 0
	if key.travel and key.period then
		offset = key.travel * math.sin(2 * math.pi * (t + (key.phase or 0)) / key.period)
	end
	return on, offset
end

-- The key under feet at (x, y, z) (y = feet height); with t, blinking keys that are off are
-- skipped and sliding keys are taken where they are at t (at rest without t).
function CardioLayout.isOverKey(x: number, y: number, z: number, t: number?): Key?
	local list = cells[cellId(math.floor(x / CELL), math.floor(z / CELL))]
	if not list then
		return nil
	end
	for _, key in list do
		if y >= key.y - 2.5 and y <= key.y + 6 and math.abs(x - key.x) <= key.sx / 2 then
			local on, offset = true, 0
			if t then
				on, offset = CardioLayout.keyState(key, t)
			end
			if on and math.abs(z - (key.z + offset)) <= key.sz / 2 then
				return key
			end
		end
	end
	return nil
end

-- Zone stage and treadmill index under feet at (x, y, z), if standing on a treadmill belt.
function CardioLayout.onTreadmill(x: number, y: number, z: number): (number?, number?)
	local T = CardioLayout.TREADMILL
	local zone = CardioLayout.zoneAt(x, z)
	if not zone then
		return nil, nil
	end
	for i, tm in zone.treadmills do
		if math.abs(x - tm.x) <= T.length / 2 and math.abs(z - tm.z) <= T.width / 2 and y >= tm.y - 1 and y <= tm.y + 5 then
			return zone.stage, i
		end
	end
	return nil, nil
end

-- Stage of the safe zone whose WIN pad is under feet at (x, y, z): inside the pad's square,
-- feet between the deck and WIN_PAD_ABOVE studs over it (a jump across the pad does not count).
CardioLayout.WIN_PAD_ABOVE = 4
function CardioLayout.onWinPad(x: number, y: number, z: number): number?
	local zone = CardioLayout.zoneAt(x, z)
	local pad = zone and zone.winPad
	if not zone or not pad then
		return nil
	end
	local half = pad.size / 2
	if math.abs(x - pad.x) <= half and math.abs(z - pad.z) <= half and y >= zone.top - 2 and y <= zone.top + CardioLayout.WIN_PAD_ABOVE then
		return zone.stage
	end
	return nil
end

-- The room spanning this X (lobby, bridge room or safe zone), if any.
function CardioLayout.roomAt(x: number): Room?
	for _, room in LAYOUT.rooms do
		if x >= room.x0 and x <= room.x1 then
			return room
		end
	end
	return nil
end

-- Stage n's bridge room.
function CardioLayout.room(stage: number): Room?
	for _, room in LAYOUT.rooms do
		if room.kind == "bridge" and room.stage == stage then
			return room
		end
	end
	return nil
end

-- Feet below this at X are a fall (the room's killY; KILL_Y outside every room).
function CardioLayout.killYAt(x: number): number
	local room = CardioLayout.roomAt(x)
	return if room then room.killY else CardioLayout.KILL_Y
end

-- Is a doorway open at server time t?
function CardioLayout.doorOpen(door: Door, t: number): boolean
	return not door.timed or ((t + door.phase) % door.period) < door.open
end

return CardioLayout
