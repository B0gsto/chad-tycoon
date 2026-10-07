--!strict
--[[
	Course: pure layout data for the GAME MODES plaza and the rainbow sky obby (docs/sky-obby.md).

	No Roblox types: World.Modes builds parts from these numbers, Modes.Parkour polls player
	positions against them and the unit tests check that every jump is fair. All positions
	are world coordinates; a platform's `y` is its TOP surface.

	The plaza sits on the -X side of the hub, between the two plot rows: a boardwalk spur
	leaves the hub ring's -X side at z = 0 and ends on a square wooden deck with the three
	mode gates in a row on its west edge, under one big GAME MODES sign. Every gate is a
	portal: walking through gate 1 teleports the player onto the start deck of their
	current Parkour level.

	The ten Parkour levels are the ten sections (maps) of ONE sky obby high above the clouds
	(every path top >= SKY_Y, a fall is feet below FLOOR_Y). Each map is laid out in its own
	LOCAL frame (start deck at the local origin heading +X) and then placed by the CHAIN: map
	n+1's start deck stands BRIDGE_GAP studs past map n's finish deck along the runner's
	direction there, joined by Course.BRIDGES[n] (a rainbow stair), and every map is turned
	(90-degree steps, maybe mirrored) so the chain zigzags without regions overlapping.
	LEVEL 1 is hand-made (LEVEL1_ELEMENTS); LEVELS 2..10 are generated deterministically by
	Course.generate(n) (own seeded LCG) from Course.TUNING[n], a difficulty table that
	tightens every level: wider gaps, smaller discs, thinner beams, faster/longer movers,
	faster spinners, fewer checkpoints, longer paths, bigger height changes and (from level 4)
	blink pads. Every jump stays fair for the default character WITHOUT Double Jump
	(Course.maxGap). A generated path is a serpentine: lanes along local +-X joined by two
	turn pads stepping local +Z; the finish deck is placed one more step +Z, so the next map
	always leaves from the course's outer edge.

	Every level is a themed MAP (Course.MAPS[i], docs/parkour-maps.md): theme, blurb, icon,
	accent and, for 2..10, a `recipe` that makes it play differently on top of TUNING
	(element weights, gap/rise/climb, bounce count, beam length, lane length...).

	Level fields (Course.LEVELS[i] / Course.level(i)):
	  index, name, difficulty (1..10), remote (always true: every level is reached by teleport)
	  theme, blurb, icon, accent   copied from Course.MAPS[i]
	  PROPS       sky scenery (type Prop): floating islands beside the course (one carrying
	              the map's landmark), clouds below, balloons above, map extras
	  palette     Theme.World colour keys: { main, alt, checkpoint, mover, accent, blink }
	              (picker cards and landmark tints; path tops are rainbow, see RAINBOW)
	  ELEMENTS    every element (below); PATH = the `path` ones in walking order
	  CHECKPOINTS checkpoint elements by index; CHECKPOINT_COUNT
	  KILLS       the map's kill elements (lava), in ELEMENTS order
	  STAGE_FIRST global stage of the start deck; checkpoint k is stage STAGE_FIRST + k;
	  STAGE_LAST  the finish deck's stage (STAGE_FIRST + CHECKPOINT_COUNT + 1), which is the
	              next map's STAGE_FIRST
	  START       { x, y, z, faceX, faceZ }: start deck spawn (feet) and facing
	  FINISH      { x0, x1, z0, z1, y0, y1 }: feet inside it after the last checkpoint finish
	  FINISH_ARCH { x, y, z, faceX, faceZ }: arch centre on the finish deck top; its front
	              faces the incoming runner (faceX/faceZ is that front's direction)
	  WATER_BOX   { x0, x1, z0, z1, y0, y1 }: the cloud catch volume under the map
	              (y0 = FLOOR_Y - 20, y1 = FLOOR_Y)
	  BOUNDS      { x0, x1, z0, z1, y0, y1 }: outside it for LEAVE_SECONDS ends the run
	  MIN_LEG_SECONDS  minimum seconds per checkpoint leg (anti-cheat)
	  TUNING      the knobs it was generated from (nil for level 1)

	Element kinds (`path = true` elements are walked on, in PATH order). All have kind,
	x, y, z (y = top surface) and `color`:
	  pad         static platform; shape "box" (sx along X, sz along Z), "disc" (radius r),
	              "ring" (a hollow square sx by sz walked on its frame, `width` studs wide;
	              gaps measure it like a box) or "hex" (a six-sided tile of circumradius r, a
	              corner along X; gaps measure it like a disc of radius r, its reach from the
	              flat sides, r * sqrt(3) / 2); optional `name` ("StartDeck", "FinishDeck",
	              "Beam", "Bridge", ...)
	  checkpoint  static square arrow pad (shape "box", sx = sz = 2 * r), numbered `index`
	              1..n in course order, global `stage`
	  mover       box platform (sx, sz) that moves: motion "slide" along unit `axis` {x,y,z}
	              or "bob" (axis {0,1,0}) by +-`distance` studs around (x, y, z), one full
	              cycle every `period` seconds; offset = distance * sin(2 pi t / period + phase)
	  slide       straight ramp from `from` {x,y,z} to `to` {x,y,z} (top surface), `width`
	              wide; x, y, z is its midpoint
	  spinner     obstacle (not a path element): a bar `length` long turning about the
	              vertical axis at `speed` rad/s (angle = speed * t + phase) above deck top `y`
	  wall        obstacle: a low wall `h` tall standing on `y` to hop over (sx along X, sz
	              along Z)
	  bounce      bounce pad of radius `r` on a deck top `y`: launches the player up at `power`
	              studs/s (the next path element may be higher than a normal jump)
	  kill        lava box (not a path element) standing on a path deck's top `y`: sx by sz,
	              `h` tall, colour "Lava"; a sliding bar also has motion "slide", axis,
	              distance, period and phase (same formula as movers). Maps 2..10 carry
	              Course.killCount(n) of them (placeKills); Course.inKill checks feet.
	  blink       box pad (sx, sz; path) that is solid only part of the time: solid when
	              ((t + phase) % period) < on, with t = server time (workspace:
	              GetServerTimeNow()); otherwise non-collidable and faded. Never two in a row.

	Colours: every pad/slide path element's `color` cycles Course.RAINBOW in walking order
	along the whole obby (bridges included); checkpoints are "Checkpoint"; movers and blink
	pads keep their map's mover/blink colour.
]]

local Course = {}

-- The plaza deck (x0..x1, z0..z1) and the spur that joins it to the hub ring at x = -118.
Course.PLAZA = { x0 = -190, x1 = -140, z0 = -28, z1 = 28, top = 0.5 }
Course.SPUR = { x0 = -140, x1 = -118, half = 6, top = 0.3 }
-- Where GoModes / ModeQuit put the player (feet): the spur end facing the gates (-X), and
-- in front of the gates facing back toward the hub (+X). faceX: the direction faced.
Course.ARRIVAL = { x = -146, y = 0.5, z = 0, faceX = -1 }
Course.QUIT = { x = -180, y = 0.5, z = 0, faceX = 1 }

-- Mode gates: one per catalog slot, in a row on the plaza's west edge, fronts facing the
-- hub (+X). GATE_HALF is half the opening width of the open (slot 1) gate; locked gates are
-- narrower (World.Modes).
Course.GATE_X = -188
Course.GATES = {
	[1] = { z = 0 },
	[2] = { z = -19 },
	[3] = { z = 19 },
}
Course.GATE_HALF = 6
-- The big GAME MODES sign high above and behind the gates (front faces +X).
Course.BIG_SIGN = { x = -197, z = 0, width = 56, height = 15, bottom = 28 }
-- Best-times board on the plaza, facing the spur mouth.
Course.BOARD = { x = -152, z = 20, faceX = -140, faceZ = 4 }

-- Walking west across this line inside gate 1's opening starts a Parkour run (the player
-- is teleported onto the level's start deck).
Course.START_LINE_X = Course.GATE_X

-- The second plaza: the first mirrored onto the hub's +X side (x -> -x), its gates on the
-- east edge facing -X (toward the hub), the same catalog gates and signs. Walking EAST
-- across START_LINE2_X inside gate 1's opening starts a run there.
Course.PLAZA2 = { x0 = -Course.PLAZA.x1, x1 = -Course.PLAZA.x0, z0 = Course.PLAZA.z0, z1 = Course.PLAZA.z1, top = Course.PLAZA.top }
Course.SPUR2 = { x0 = -Course.SPUR.x1, x1 = -Course.SPUR.x0, half = Course.SPUR.half, top = Course.SPUR.top }
Course.ARRIVAL2 = { x = -Course.ARRIVAL.x, y = Course.ARRIVAL.y, z = Course.ARRIVAL.z, faceX = -Course.ARRIVAL.faceX }
Course.QUIT2 = { x = -Course.QUIT.x, y = Course.QUIT.y, z = Course.QUIT.z, faceX = -Course.QUIT.faceX }
Course.GATE2_X = -Course.GATE_X
Course.GATES2 = {
	[1] = { z = Course.GATES[1].z },
	[2] = { z = Course.GATES[2].z },
	[3] = { z = Course.GATES[3].z },
}
Course.BIG_SIGN2 = {
	x = -Course.BIG_SIGN.x,
	z = Course.BIG_SIGN.z,
	width = Course.BIG_SIGN.width,
	height = Course.BIG_SIGN.height,
	bottom = Course.BIG_SIGN.bottom,
}
Course.BOARD2 = { x = -Course.BOARD.x, z = Course.BOARD.z, faceX = -Course.BOARD.faceX, faceZ = Course.BOARD.faceZ }
Course.START_LINE2_X = Course.GATE2_X

-- Falling in: feet below WATER_Y beyond the island's shore (horizontal distance from the
-- world origin greater than WATER_RADIUS) sends a running player back to their checkpoint.
-- Holds for every level (all of them are far off the island).
Course.WATER_Y = 1.5
Course.WATER_RADIUS = 219
Course.LEAVE_SECONDS = 2.5

-- Jump limits (default character: JumpHeight 7.2, WalkSpeed 16, Workspace.Gravity 196.2):
-- edge-to-edge gaps never above MAX_GAP and step-ups never above MAX_STEP_UP (except onto
-- the element after a bounce pad).
Course.MAX_GAP = 9
Course.MAX_STEP_UP = 5
Course.GRAVITY = 196.2
Course.JUMP_HEIGHT = 7.2
Course.WALK_SPEED = 16
-- Studs of reach kept in reserve on every jump (phones, late jumps).
Course.SAFETY = 0.8

-- Integrity: nobody moves along the course faster than this (studs/s, about twice a
-- Speedy Sneakers run), so each checkpoint-to-checkpoint leg has a minimum time.
Course.MAX_PLAUSIBLE_SPEED = 40

Course.LEVEL_COUNT = 10

-- The sky: every path top stands at or above SKY_Y; feet below FLOOR_Y (the cloud floor)
-- is a fall (Course.inWater). WATER_Y / WATER_RADIUS above are the hub's sea line.
Course.SKY_Y = 320
Course.FLOOR_Y = Course.SKY_Y - 24

-- The chain: map n+1's start deck stands BRIDGE_GAP studs (edge to edge) past map n's finish
-- deck, joined by BRIDGE_STEPS boxes BRIDGE_STEP long, each BRIDGE_RISE above the last (the
-- start deck one more BRIDGE_RISE up). Every region keeps REGION_MARGIN studs around its
-- course and scenery; the whole chain stays within +-CHAIN_LIMIT in x and z.
Course.BRIDGE_GAP = 26
Course.BRIDGE_STEPS = 6
Course.BRIDGE_STEP = 3
Course.BRIDGE_WIDTH = 10
Course.BRIDGE_RISE = 1.2
Course.REGION_MARGIN = 9
Course.CHAIN_LIMIT = 1400

-- Path-top colours (Theme.World keys), cycled in walking order along the whole obby.
Course.RAINBOW = {
	"RainbowRed",
	"RainbowOrange",
	"RainbowYellow",
	"RainbowGreen",
	"RainbowCyan",
	"RainbowBlue",
	"RainbowPurple",
	"RainbowPink",
}

-- Longest fair edge-to-edge gap for a jump that lands `dy` studs higher (negative = drop)
-- than it took off, for a jump of apex `jumpHeight` (default 7.2): the walk-speed distance
-- covered while still at or above the landing height, minus SAFETY, capped at MAX_GAP.
-- Negative when the step is out of reach.
function Course.maxGap(dy: number, jumpHeight: number?): number
	local g = Course.GRAVITY
	local v = math.sqrt(2 * g * (jumpHeight or Course.JUMP_HEIGHT))
	local d = v * v - 2 * g * dy
	if d < 0 then
		return -1
	end
	local t = (v + math.sqrt(d)) / g
	return math.min(Course.MAX_GAP, Course.WALK_SPEED * t - Course.SAFETY)
end

export type Element = {
	kind: string,
	shape: string?,
	x: number,
	y: number,
	z: number,
	sx: number?,
	sz: number?,
	r: number?,
	color: string?,
	index: number?,
	path: boolean?,
	motion: string?,
	axis: { number }?,
	distance: number?,
	period: number?,
	phase: number?,
	on: number?,
	length: number?,
	speed: number?,
	h: number?,
	power: number?,
	from: { number }?,
	to: { number }?,
	width: number?,
	name: string?,
	stage: number?,
}

export type Box = { x0: number, x1: number, z0: number, z1: number, y0: number, y1: number }

export type Tuning = {
	gap: number, -- target edge-to-edge gap (clamped to Course.maxGap per jump)
	discR: number,
	beamW: number,
	padSize: number,
	checkpointR: number,
	moverTravel: number,
	moverPeriod: number,
	spinSpeed: number,
	spinBars: number,
	checkpointEvery: number, -- path elements per checkpoint
	pathLength: number,
	rise: number, -- largest height change per jump (up or down)
	blinkOn: number?, -- seconds solid per cycle (nil = no blink pads)
	blinkPeriod: number?,
}

-- Scenery (World.MapDecor draws it): `y` is where the prop's base stands (Course.WATER_Y for
-- sea props, Course.ISLET_TOP for props standing on an islet, above the course for clouds).
-- `scale` sizes most kinds; islet/lavapool use `r` (radius); a fin circles its (x, z) at `r`

-- Sky scenery (World.MapDecor draws it): `y` is where the prop's base stands (an island's
-- grass top, and the props standing on it) or, for clouds/balloons/stars, their own
-- altitude. `scale` sizes most kinds; an island uses `r` (radius). Course.propFoot(p) is the
-- horizontal radius a prop may cover.
export type Prop = { kind: string, x: number, y: number, z: number, yaw: number?, scale: number?, r: number?, speed: number? }

-- How a generated map plays: element weights (pad, disc, beam, slide = sideways slider,
-- bob, spinner, walls, blink, ramp = a slide down onto a landing pad) and knobs that
-- override or bias Course.TUNING[n] (nil = keep the tuning).
export type Recipe = {
	weights: { [string]: number },
	gap: number?, -- target edge-to-edge gap
	rise: number?, -- largest random height change per jump
	climb: number?, -- studs added to every jump's height change (the path climbs or sinks)
	yMax: number?, -- highest platform top (default Y_MAX)
	bounces: number?, -- bounce decks along the path (default 1)
	bounceRise: number?, -- studs up after each bounce (default BOUNCE_RISE)
	beamLength: number?,
	lane: number?, -- centre-x span of one serpentine lane (default LANE)
	checkpointEvery: number?,
	spinBars: number?,
	moverTravel: number?,
	moverPeriod: number?,
	blinkEvery: number?, -- every k-th plain pad blinks (nil = only by weight)
}

export type Map = { theme: string, name: string, blurb: string, icon: string, accent: string, recipe: Recipe? }

export type Level = {
	index: number,
	name: string,
	difficulty: number,
	remote: boolean,
	theme: string,
	blurb: string,
	icon: string,
	accent: string,
	PROPS: { Prop },
	palette: { [string]: string },
	ELEMENTS: { Element },
	PATH: { Element },
	CHECKPOINTS: { Element },
	KILLS: { Element },
	CHECKPOINT_COUNT: number,
	STAGE_FIRST: number,
	STAGE_LAST: number,
	START: { x: number, y: number, z: number, faceX: number, faceZ: number },
	FINISH: Box,
	FINISH_ARCH: { x: number, y: number, z: number, faceX: number, faceZ: number },
	WATER_BOX: Box,
	BOUNDS: Box,
	MIN_LEG_SECONDS: { number },
	TUNING: Tuning?,
}

local function box(x: number, y: number, z: number, sx: number, sz: number, color: string, name: string?): Element
	return { kind = "pad", shape = "box", x = x, y = y, z = z, sx = sx, sz = sz, color = color, path = true, name = name }
end

local function disc(x: number, y: number, z: number, r: number, color: string): Element
	return { kind = "pad", shape = "disc", x = x, y = y, z = z, r = r, color = color, path = true }
end

local function checkpoint(index: number, x: number, y: number, z: number, r: number, color: string?): Element
	return {
		kind = "checkpoint",
		shape = "box",
		index = index,
		x = x,
		y = y,
		z = z,
		sx = 2 * r,
		sz = 2 * r,
		r = r,
		color = color or "Checkpoint",
		path = true,
	}
end

-- A hollow square tile walked on its frame (`width` studs wide) and a six-sided tile.
local RING_FRAME = 3
local function ring(x: number, y: number, z: number, size: number, color: string): Element
	return { kind = "pad", shape = "ring", x = x, y = y, z = z, sx = size, sz = size, width = RING_FRAME, color = color, path = true }
end

local function hex(x: number, y: number, z: number, r: number, color: string): Element
	return { kind = "pad", shape = "hex", x = x, y = y, z = z, r = r, color = color, path = true }
end

-- Level 1, drawn with its start deck at x = -197, z = 0 (where it once began on the beach):
-- its local frame. The chain (FRAMES[1]: oy = SKY_Y - 0.6) lifts it so the start deck stands
-- at SKY_Y and recolours its path tops rainbow (movers stay Orange).
local LEVEL1_ELEMENTS = {
	-- Start deck and two wide steps up.
	box(-197, 0.6, 0, 14, 14, "Sunny", "StartDeck"),
	box(-210, 2.4, 0, 9, 14, "Butter"),
	box(-221, 4.2, 0, 9, 14, "Sunny"),
	checkpoint(1, -234, 5, 0, 6),
	-- Stepping discs.
	disc(-247, 5, 4, 4.5, "Butter"),
	disc(-257, 5.5, -3, 4.5, "Sunny"),
	disc(-267, 6, 3, 4.5, "Butter"),
	disc(-277, 6.5, -2, 4.5, "Sunny"),
	checkpoint(2, -291, 7, 0, 6),
	-- Balance beam.
	box(-309, 7, 0, 18, 4, "Butter", "Beam"),
	checkpoint(3, -326, 7.5, 0, 6),
	-- A platform sliding back and forth along the course.
	{
		kind = "mover",
		shape = "box",
		x = -341,
		y = 7.5,
		z = 0,
		sx = 9,
		sz = 9,
		color = "Orange",
		path = true,
		motion = "slide",
		axis = { 1, 0, 0 },
		distance = 2.8,
		period = 5,
		phase = 0,
	},
	checkpoint(4, -356, 8, 0, 6),
	-- Turn south: a deck with two slow sweeper bars to jump over.
	box(-356, 8, -21, 14, 24, "Sunny", "SweeperDeck"),
	{ kind = "spinner", x = -356, y = 8, z = -15, length = 12, speed = 1.2, phase = 0 },
	{ kind = "spinner", x = -356, y = 8, z = -27, length = 12, speed = -1, phase = math.pi / 2 },
	-- Bounce pad up to the high return lane.
	box(-356, 8, -39, 12, 10, "Butter", "BounceDeck"),
	{ kind = "bounce", x = -356, y = 8, z = -39.5, r = 2.5, power = 78 },
	checkpoint(5, -356, 17, -53, 6),
	-- Back east: a bobbing platform, then the wall-hop deck.
	{
		kind = "mover",
		shape = "box",
		x = -341,
		y = 17,
		z = -53,
		sx = 10,
		sz = 10,
		color = "Orange",
		path = true,
		motion = "bob",
		axis = { 0, 1, 0 },
		distance = 2,
		period = 4,
		phase = 0,
	},
	box(-320, 17, -53, 26, 14, "Butter", "WallHopDeck"),
	{ kind = "wall", x = -326, y = 17, z = -53, sx = 1.2, sz = 14, h = 2.4, color = "Teal" },
	{ kind = "wall", x = -320, y = 17, z = -53, sx = 1.2, sz = 14, h = 2.4, color = "Teal" },
	{ kind = "wall", x = -314, y = 17, z = -53, sx = 1.2, sz = 14, h = 2.4, color = "Teal" },
	checkpoint(6, -298, 17, -53, 6),
	-- A platform sliding sideways across the lane.
	{
		kind = "mover",
		shape = "box",
		x = -282,
		y = 17,
		z = -53,
		sx = 10,
		sz = 10,
		color = "Orange",
		path = true,
		motion = "slide",
		axis = { 0, 0, 1 },
		distance = 4,
		period = 6,
		phase = math.pi / 2,
	},
	box(-268, 16, -53, 12, 12, "Sunny"),
	checkpoint(7, -254.5, 15, -53, 6),
	-- The big slide down to the finish deck.
	box(-242.5, 15, -53, 9, 9, "Butter", "SlideTop"),
	{
		kind = "slide",
		x = -224,
		y = 8.1,
		z = -53,
		from = { -238, 15, -53 },
		to = { -210, 1.2, -53 },
		width = 7,
		color = "Sunny",
		path = true,
	},
	box(-201, 1.2, -53, 18, 14, "Butter", "FinishDeck"),
} :: { Element }

Course.NAMES = {
	"Sunny Steps",
	"Coconut Cove",
	"Sweeper Bay",
	"Blink Reef",
	"Bubble Bounce",
	"Coral Climb",
	"Shark Fin Sprint",
	"Thunder Tide",
	"Volcano Vault",
	"Giga Gauntlet",
}

-- Theme.World colour keys per level: one hue family per map (path tops light, rims darker
-- in World.Modes STYLE): 1 sunny yellow, 2 mint green, 3 white on periwinkle navy, 4 hot
-- pink + teal, 5 white/butter on icy blue, 6 orange/terracotta, 7 coral/white on deep teal,
-- 8 storm slate + volt yellow, 9 lava orange on basalt, 10 cream + gold + grape.
Course.PALETTES = {
	{ main = "Sunny", alt = "Butter", checkpoint = "Coral", mover = "Orange", accent = "Teal", blink = "Pink" },
	{ main = "Mint", alt = "MintPale", checkpoint = "Coral", mover = "Butter", accent = "GrassDark", blink = "Pink" },
	{ main = "White", alt = "Chrome", checkpoint = "Sunny", mover = "Coral", accent = "Navy", blink = "Pink" },
	{ main = "Pink", alt = "TealLight", checkpoint = "Sunny", mover = "Teal", accent = "Teal", blink = "HotPink" },
	{ main = "Butter", alt = "White", checkpoint = "Mint", mover = "Blue", accent = "HotPink", blink = "Grape" },
	{ main = "Orange", alt = "Apricot", checkpoint = "Mint", mover = "Terracotta", accent = "Teal", blink = "Pink" },
	{ main = "Coral", alt = "White", checkpoint = "Sunny", mover = "Butter", accent = "Navy", blink = "Pink" },
	{ main = "Steel", alt = "Chrome", checkpoint = "Mint", mover = "Volt", accent = "Volt", blink = "Pink" },
	{ main = "Lava", alt = "Orange", checkpoint = "Butter", mover = "Steel", accent = "Butter", blink = "Mint" },
	{ main = "Cream", alt = "White", checkpoint = "Mint", mover = "Grape", accent = "Grape", blink = "Pink" },
}
-- The ten maps: look (theme, icon, accent = Theme.World key for the picker card) and, for
-- the generated ones (2..10), the recipe Course.generate plays them with.

Course.MAPS = {
	{
		theme = "beach",
		name = Course.NAMES[1],
		blurb = "Hop the sunny steps and zoom down the big slide!",
		icon = "🏖️",
		accent = "Butter",
	},
	{
		theme = "cove",
		name = Course.NAMES[2],
		blurb = "Hop the stepping discs under the palms!",
		icon = "🥥",
		accent = "Mint",
		recipe = {
			weights = { pad = 2, disc = 5, beam = 1, slide = 1, spinner = 0.5, ramp = 12 },
			climb = 0.6,
		},
	},
	{
		theme = "bay",
		name = Course.NAMES[3],
		blurb = "Jump the spinning sweepers by the lighthouse!",
		icon = "🌀",
		accent = "Navy",
		recipe = {
			weights = { pad = 2, disc = 1, beam = 1, slide = 1, bob = 0.5, spinner = 7, walls = 0.5 },
			spinBars = 2,
		},
	},
	{
		theme = "reef",
		name = Course.NAMES[4],
		blurb = "Blink pads vanish! Time every hop!",
		icon = "🐠",
		accent = "HotPink",
		recipe = {
			weights = { pad = 2, disc = 2, beam = 1, slide = 0.5, bob = 0.5, spinner = 0.5, walls = 0.5, blink = 10 },
			blinkEvery = 2,
		},
	},
	{
		theme = "bubble",
		name = Course.NAMES[5],
		blurb = "Boing up the bounce pads through the bubbles!",
		icon = "🫧",
		accent = "Blue",
		recipe = {
			weights = { pad = 3, disc = 3, beam = 1, slide = 1.5, bob = 2, spinner = 1, walls = 0.5, blink = 1 },
			bounces = 3,
			climb = -0.7,
			yMax = 36,
		},
	},
	{
		theme = "coral",
		name = Course.NAMES[6],
		blurb = "Climb the coral tower all the way to the top!",
		icon = "🪸",
		accent = "Terracotta",
		recipe = {
			weights = { pad = 3, disc = 3, beam = 1.5, slide = 1, bob = 1.5, spinner = 1, walls = 1, blink = 1 },
			climb = 1.6,
			yMax = 46,
		},
	},
	{
		theme = "shark",
		name = Course.NAMES[7],
		blurb = "Sprint the long beams past the shark fins!",
		icon = "🦈",
		accent = "TealDeep",
		recipe = {
			weights = { pad = 2, disc = 1, beam = 6, spinner = 1, walls = 0.5, blink = 0.5 },
			gap = 9,
			rise = 1.2,
			beamLength = 26,
			lane = 150,
			checkpointEvery = 10,
		},
	},
	{
		theme = "storm",
		name = Course.NAMES[8],
		blurb = "Ride the zooming platforms through the storm!",
		icon = "⚡",
		accent = "Slate",
		recipe = {
			weights = { pad = 3, disc = 1, beam = 1, slide = 6, bob = 6, spinner = 1, walls = 0.5, blink = 1 },
			moverTravel = 6,
			moverPeriod = 2.7,
		},
	},
	{
		theme = "volcano",
		name = Course.NAMES[9],
		blurb = "Hop the walls and bounce high over the lava!",
		icon = "🌋",
		accent = "Lava",
		recipe = {
			weights = { pad = 2, disc = 1, beam = 1, slide = 1, bob = 1, spinner = 1, walls = 6, blink = 1 },
			bounces = 2,
			bounceRise = 10,
			lane = 140,
			rise = Course.MAX_STEP_UP,
			climb = 0.4,
			yMax = 40,
		},
	},
	{
		theme = "giga",
		name = Course.NAMES[10],
		blurb = "Every trick at once. Only true Gigas finish!",
		icon = "👑",
		accent = "Gold",
		recipe = {
			weights = { pad = 2, disc = 3, beam = 2, slide = 3, bob = 3, spinner = 3, walls = 3, blink = 2, ramp = 1 },
			lane = 140,
			bounces = 2,
		},
	},
} :: { Map }

local function round2(x: number): number
	return math.floor(x * 100 + 0.5) / 100
end

local function lerp(a: number, b: number, t: number): number
	return round2(a + (b - a) * t)
end

-- The difficulty table: level 2 (t = 0) to level 10 (t = 1).
Course.TUNING = {} :: { [number]: Tuning }
for n = 2, Course.LEVEL_COUNT do
	local t = (n - 2) / (Course.LEVEL_COUNT - 2)
	local b = (n - 4) / (Course.LEVEL_COUNT - 4)
	Course.TUNING[n] = {
		gap = lerp(5.5, 8.3, t),
		discR = lerp(5.5, 4.6, t),
		beamW = lerp(5, 3, t),
		padSize = lerp(12, 9.5, t),
		checkpointR = lerp(6, 5, t),
		moverTravel = lerp(3, 7, t),
		moverPeriod = lerp(5, 2.6, t),
		spinSpeed = lerp(1.2, 2.8, t),
		spinBars = 1 + (n - 2) // 3,
		checkpointEvery = 4 + (n - 2) // 2,
		pathLength = 24 + 4 * (n - 2),
		rise = lerp(1.5, Course.MAX_STEP_UP, t),
		blinkOn = if n >= 4 then lerp(3, 1.3, b) else nil,
		blinkPeriod = if n >= 4 then lerp(4.5, 3.3, b) else nil,
	}
end

-- Positions { x, y, z } an element takes along its motion (movers sampled, else itself).
function Course.poses(e: Element): { { number } }
	if e.kind ~= "mover" then
		return { { e.x, e.y, e.z } }
	end
	local axis, distance = e.axis :: { number }, e.distance :: number
	local out = {}
	for s = -1, 1, 0.125 do
		local d = distance * s
		table.insert(out, { e.x + axis[1] * d, e.y + axis[2] * d, e.z + axis[3] * d })
	end
	return out
end

local HEX_APOTHEM = math.sqrt(3) / 2

-- Is e measured as a rectangle (sx by sz)? Boxes and rings are; discs and hexes are round.
local function boxy(e: Element): boolean
	return e.shape == "box" or e.shape == "ring"
end

-- Edge-to-edge horizontal distance between element a at (ax, az) and b at (bx, bz). A hex
-- counts as a disc of its corner radius, or, with `inner`, of its flat-side radius (the
-- longest a jump onto or off it can be).
function Course.edgeGap(a: Element, ax: number, az: number, b: Element, bx: number, bz: number, inner: boolean?): number
	local function half(e: Element): (number, number, number)
		if boxy(e) then
			return (e.sx :: number) / 2, (e.sz :: number) / 2, 0
		end
		local r = e.r or 0
		return 0, 0, if inner and e.shape == "hex" then r * HEX_APOTHEM else r
	end
	local ahx, ahz, ar = half(a)
	local bhx, bhz, br = half(b)
	local dx = math.max(0, math.abs(ax - bx) - ahx - bhx)
	local dz = math.max(0, math.abs(az - bz) - ahz - bhz)
	return math.sqrt(dx * dx + dz * dz) - ar - br
end

-- Can a player jump from a to b at EVERY phase of their motion (no touching either)?
local function fits(a: Element, b: Element, jumpHeight: number?): boolean
	for _, pa in Course.poses(a) do
		for _, pb in Course.poses(b) do
			local gap = Course.edgeGap(a, pa[1], pa[3], b, pb[1], pb[3])
			local far = Course.edgeGap(a, pa[1], pa[3], b, pb[1], pb[3], true)
			if gap < 0.6 or far > Course.maxGap(pb[2] - pa[2], jumpHeight) then
				return false
			end
		end
	end
	return true
end

local function halfAlong(e: Element, alongX: boolean): number
	if boxy(e) then
		return (if alongX then e.sx :: number else e.sz :: number) / 2
	end
	return e.r :: number
end

-- Park-Miller LCG in [0, 1).
local function rng(seed: number): () -> number
	local s = seed % 2147483646 + 1
	return function(): number
		s = s * 16807 % 2147483647
		return (s - 1) / 2147483646
	end
end

local LANE = 120 -- centre-x span of one serpentine lane
local Y_MIN, Y_MAX = 3, 30
local BOUNCE_POWER = 78
local BOUNCE_RISE = 8
-- Nothing of a generated map reaches past this local x: the start deck's back edge (x = -6)
-- less 2 studs, so the bridge from the previous map arrives over open sky.
local X_FLOOR = -8
-- Apex of a bounce launch, less the 3 studs from the pad to the feet landing height.
local BOUNCE_HEIGHT = BOUNCE_POWER * BOUNCE_POWER / (2 * Course.GRAVITY) - 3

-- Scenery keeps PROP_CLEARANCE studs (horizontally) between its footprint and every path
-- element at every phase. Props standing on an island share its footprint; the giant
-- rainbow arch stands over the bridge into its map on purpose (only its feet keep clear).
Course.PROP_CLEARANCE = 4
-- Footprint radius of each kind at scale 1 (island: r, its radius).
Course.PROP_FOOT = {
	island = 1,
	lighthouse = 5,
	windmill = 7,
	tree = 3,
	balloon = 6,
	cloud = 11.5,
	star = 2,
	rainbowarch = 9,
	landmark = 16,
	loop = 22,
	spiral = 11,
} :: { [string]: number }
-- How far each kind reaches above its y at scale 1 (Course bounds' top; landmark: the
-- tallest one).
Course.PROP_HEIGHT = {
	landmark = 82,
	balloon = 22,
	rainbowarch = 21,
	loop = 42,
	spiral = 38,
	cloud = 6.5,
} :: { [string]: number }
-- Sky clouds never come within CLOUD_CLEAR studs under the path: a `cloud` prop's top
-- (y + PROP_HEIGHT.cloud * scale) stays CLOUD_CLEAR under the lowest path top, or the cloud
-- sits CLOUD_BESIDE studs (beyond its footprint) off every element. The cloud floor floats
-- CLOUD_FLOOR_DEPTH studs under the lowest path top, CLOUD_FLOOR_SPREAD past the bounds.
Course.CLOUD_CLEAR = 30
Course.CLOUD_BESIDE = 40
Course.CLOUD_FLOOR_DEPTH = { 150, 220 }
Course.CLOUD_FLOOR_SPREAD = 80
-- The giant rainbow arch over the bridge into maps 1, 4, 7 and 10 (maps 1: behind its lobby
-- deck): scale, and its two cloud feet at +-ARCH_FEET[1] along the arch, ARCH_FEET[2] wide
-- (radius) at scale 1 (World.MapDecor rainbowarch).
Course.ARCH_SCALE = 2.5
Course.ARCH_FEET = { 15.2, 4.5 }
-- The other anchor set pieces beside the course: a rainbow loop (maps 2, 5, 8) and a spiral
-- rainbow stair (maps 3, 6, 9), at this scale.
Course.ANCHOR_SCALE = 1.5

function Course.propFoot(p: Prop): number
	if p.kind == "island" then
		return p.r or 0
	end
	return (Course.PROP_FOOT[p.kind] or 3) * (p.scale or 1)
end

-- Horizontal distance from (px, pz) to element e's footprint at the nearest phase of its
-- motion (negative inside it).
function Course.footDistance(e: Element, px: number, pz: number): number
	if e.kind == "slide" then
		local a, b = e.from :: { number }, e.to :: { number }
		local dx, dz = b[1] - a[1], b[3] - a[3]
		local t = math.clamp(((px - a[1]) * dx + (pz - a[3]) * dz) / math.max(1e-9, dx * dx + dz * dz), 0, 1)
		local cx, cz = a[1] + dx * t, a[3] + dz * t
		return math.sqrt((px - cx) ^ 2 + (pz - cz) ^ 2) - (e.width or 0) / 2
	end
	local best = math.huge
	for _, pose in Course.poses(e) do
		local d
		if e.sx then
			local dx = math.max(0, math.abs(px - pose[1]) - (e.sx :: number) / 2)
			local dz = math.max(0, math.abs(pz - pose[3]) - (e.sz :: number) / 2)
			d = math.sqrt(dx * dx + dz * dz)
		else
			d = math.sqrt((px - pose[1]) ^ 2 + (pz - pose[3]) ^ 2) - (e.r or (e.length or 0) / 2)
		end
		best = math.min(best, d)
	end
	return best
end

-- Smallest footprint distance from (x, z) to any element of the list.
local function clearOf(elements: { Element }, x: number, z: number): number
	local best = math.huge
	for _, e in elements do
		best = math.min(best, Course.footDistance(e, x, z))
	end
	return best
end

-- Uniform scale of each theme's landmark (World.MapDecor LANDMARKS), sizing it 110-145 studs
-- tall; its footprint is PROP_FOOT.landmark * scale. (The shark's fin arch stands on a wide
-- sea disc, so it grows a little less, to stay on its island.)
Course.LANDMARK_SCALE = {
	beach = 2.7,
	cove = 2.6,
	bay = 2.7,
	reef = 2.9,
	bubble = 2.7,
	coral = 2.6,
	shark = 3.2,
	storm = 2.6,
	volcano = 2.25,
	giga = 3,
} :: { [string]: number }
-- Islands: the landmark's is LANDMARK_ISLAND wide (radius), the others ISLAND_R.
Course.LANDMARK_ISLAND = 48
Course.ISLAND_R = { 28, 44 }

local function clearOfTaken(taken: { { number } }, x: number, z: number, foot: number): boolean
	for _, t in taken do
		if math.sqrt((x - t[1]) ^ 2 + (z - t[2]) ^ 2) < foot + t[3] + 1 then
			return false
		end
	end
	return true
end

-- Rectangle (x0, x1, z0, z1) covering every element's footprint at every phase.
local function footprint(elements: { Element }): (number, number, number, number)
	local x0, x1, z0, z1 = math.huge, -math.huge, math.huge, -math.huge
	local function cover(x: number, z: number, hx: number, hz: number)
		x0, x1 = math.min(x0, x - hx), math.max(x1, x + hx)
		z0, z1 = math.min(z0, z - hz), math.max(z1, z + hz)
	end
	for _, e in elements do
		if e.kind == "slide" then
			local w = (e.width or 0) / 2
			for _, point in { e.from :: { number }, e.to :: { number } } do
				cover(point[1], point[3], w, w)
			end
		else
			local half = e.r or (e.length or 0) / 2
			for _, pose in Course.poses(e) do
				cover(pose[1], pose[3], (e.sx or 2 * half) / 2, (e.sz or 2 * half) / 2)
			end
		end
	end
	return x0, x1, z0, z1
end

-- Lowest and highest path top at any phase.
local function pathHeights(elements: { Element }): (number, number)
	local lo, hi = math.huge, -math.huge
	for _, e in elements do
		if e.path then
			for _, pose in Course.poses(e) do
				lo, hi = math.min(lo, pose[2]), math.max(hi, pose[2])
			end
			for _, point in { e.from, e.to } do
				if point then
					lo, hi = math.min(lo, point[2]), math.max(hi, point[2])
				end
			end
		end
	end
	return lo, hi
end

-- What stands on each map's floating islands: the first carries the landmark, then (every
-- map but storm) a windmill island, and the map's extras.
local function islandCrews(theme: string): { { string } }
	local crews = { { "landmark" } }
	if theme == "beach" or theme == "cove" then
		table.insert(crews, { "windmill", "tree", "tree" })
		table.insert(crews, { "tree", "tree", "tree" })
	elseif theme == "bay" then
		table.insert(crews, { "windmill" })
		table.insert(crews, { "lighthouse" })
	elseif theme == "storm" then
		table.insert(crews, {})
	else
		table.insert(crews, { "windmill" })
		if theme == "reef" or theme == "coral" or theme == "giga" then
			table.insert(crews, {})
		end
	end
	return crews
end

local function propSpot(x0: number, x1: number, z0: number, z1: number, foot: number, rand: () -> number): (number, number)
	local x = if x1 - x0 > 2 * foot then x0 + foot + rand() * (x1 - x0 - 2 * foot) else (x0 + x1) / 2
	local z = if z1 - z0 > 2 * foot then z0 + foot + rand() * (z1 - z0 - 2 * foot) else (z0 + z1) / 2
	return round2(x), round2(z)
end

-- Does a rainbow arch (feet at y, centred on (x, z), spanning across `face`, at `scale`) stand
-- clear of `elements`: its two cloud feet PROP_CLEARANCE off every footprint, and every
-- element under its span inside the opening (ARCH_INNER) with 8 studs of headroom?
Course.ARCH_INNER = 9.6
Course.ARCH_OUTER = 21
function Course.archFits(elements: { Element }, x: number, y: number, z: number, face: { number }, scale: number): boolean
	local rx, rz = -face[2], face[1]
	local spread, feetR = Course.ARCH_FEET[1] * scale, Course.ARCH_FEET[2] * scale
	local inner, outer = Course.ARCH_INNER * scale, Course.ARCH_OUTER * scale
	for _, sign in { -1, 1 } do
		if clearOf(elements, x + rx * spread * sign, z + rz * spread * sign) < feetR + Course.PROP_CLEARANCE then
			return false
		end
	end
	for _, e in elements do
		if math.abs(e.x - x) + math.abs(e.z - z) < outer + 40 then
			for d = -outer, outer, 1 do
				if Course.footDistance(e, x + rx * d, z + rz * d) < 2.5 then
					local top = e.y + (if e.kind == "spinner" or e.kind == "wall" then 3 else 0)
					if math.abs(d) >= inner - 1 or top + 8 > y + math.sqrt(inner * inner - d * d) then
						return false
					end
				end
			end
		end
	end
	return true
end

-- A map's sky scenery in its local frame, deterministic from `rand`: 2-4 floating islands
-- just past the course's `side` edge (+1: +X, -1: -X) within the course's z span, never within
-- PROP_CLEARANCE of the path nor overlapping each other (one carries the landmark), its
-- anchor set piece beside them (a rainbow loop on maps 2, 5, 8, a spiral rainbow stair on
-- 3, 6, 9), 4-8 clouds (CLOUD_CLEAR under the path or CLOUD_BESIDE off it), 1-2 balloons
-- 25-40 studs above it, giga's stars and the giant rainbow arch over the bridge into maps 1,
-- 4, 7 and 10 (`face`: the local direction the start deck faces). Nothing but the arch
-- reaches past the course's z span, so the chain's bridges and neighbours stay clear.
local function placeScenery(
	elements: { Element },
	theme: string,
	index: number,
	side: number,
	face: { number },
	rand: () -> number
): { Prop }
	local fx0, fx1, fz0, fz1 = footprint(elements)
	local lo, hi = pathHeights(elements)
	local clearance = Course.PROP_CLEARANCE
	local cx, cz = (fx0 + fx1) / 2, (fz0 + fz1) / 2
	local props: { Prop } = {}
	local taken: { { number } } = {}
	local edge = if side > 0 then fx1 else fx0
	-- The frame the islands span (grows as they land).
	local ax0, ax1, az0, az1 = fx0, fx1, fz0, fz1
	-- A spot just past the course's side edge for something `foot` wide, clear of the path
	-- and of everything placed so far; nil when 200 tries find none.
	local function besideSpot(foot: number): (number?, number?)
		for attempt = 1, 200 do
			local x = round2(edge + side * (foot + clearance + 1 + rand() * (10 + 2 * attempt)))
			local _, z = propSpot(0, 0, fz0, fz1, foot, rand)
			if clearOf(elements, x, z) >= foot + clearance and clearOfTaken(taken, x, z, foot) then
				table.insert(taken, { x, z, foot })
				ax0, ax1 = math.min(ax0, x - foot), math.max(ax1, x + foot)
				az0, az1 = math.min(az0, z - foot), math.max(az1, z + foot)
				return x, z
			end
		end
		return nil, nil
	end
	local function facingCourse(x: number, z: number): number
		return round2(math.atan2(-(cx - x), -(cz - z)))
	end
	for _, crew in islandCrews(theme) do
		local landmark: Prop? = if crew[1] == "landmark"
			then { kind = "landmark", x = 0, y = 0, z = 0, scale = Course.LANDMARK_SCALE[theme] or 2.7 }
			else nil
		local lo_r, hi_r = Course.ISLAND_R[1], Course.ISLAND_R[2]
		local r = if landmark then Course.LANDMARK_ISLAND else round2(lo_r + (hi_r - lo_r) * rand())
		local foot = if landmark then math.max(r, Course.propFoot(landmark)) else r
		local x, z = besideSpot(foot)
		assert(x and z, `Course: no room for an island on map {index}`)
		local y = round2(lo - 6 - 10 * rand())
		table.insert(props, { kind = "island", x = x, y = y, z = z, r = r, yaw = round2(rand() * 2 * math.pi) })
		for k, kind in crew do
			local c: Prop = { kind = kind, x = x, y = y, z = z, scale = 1, yaw = round2(rand() * 2 * math.pi) }
			if landmark and k == 1 then
				c.scale = landmark.scale
				c.yaw = facingCourse(x, z)
			elseif kind == "windmill" then
				c.scale = round2(1.7 + 0.3 * rand())
			elseif kind == "lighthouse" then
				c.scale = 1.8
			elseif kind == "tree" then
				c.scale = round2(1.4 + 0.6 * rand())
			end
			if k > 1 then
				local angle = (k / #crew + 0.15 * rand()) * 2 * math.pi
				local dist = r - Course.propFoot(c) - 1.5
				c.x, c.z = round2(x + math.cos(angle) * dist), round2(z + math.sin(angle) * dist)
			end
			table.insert(props, c)
		end
	end
	-- The anchor set piece beside the islands, facing the course.
	local anchor = if index % 3 == 2 then "loop" elseif index % 3 == 0 then "spiral" else nil
	if anchor then
		local scale = Course.ANCHOR_SCALE
		local x, z = besideSpot(Course.PROP_FOOT[anchor] * scale)
		assert(x and z, `Course: no room for the {anchor} on map {index}`)
		local y = round2(if anchor == "loop" then lo - 4 - 6 * rand() else lo - 10 - 4 * rand())
		table.insert(props, { kind = anchor, x = x, y = y, z = z, scale = scale, yaw = facingCourse(x, z) })
	end
	-- Clouds: about half beside the course (CLOUD_BESIDE off every element, near path
	-- height), the rest under it, their tops CLOUD_CLEAR under the lowest path top.
	-- (Clouds keep off the islands and each other; the balloons above ignore them.)
	local low: { { number } } = {}
	local clouds = if theme == "storm" then 8 else 4 + math.floor(rand() * 4)
	for _ = 1, clouds do
		local beside = rand() < 0.5
		for attempt = 1, 80 do
			local scale = round2(1 + 0.8 * rand() * (1 - attempt / 80))
			local foot = Course.PROP_FOOT.cloud * scale
			local x, z = propSpot(ax0, ax1, az0, az1, foot, rand)
			local need = if beside and attempt <= 40 then Course.CLOUD_BESIDE + foot else 2
			if clearOf(elements, x, z) >= need and clearOfTaken(taken, x, z, foot) and clearOfTaken(low, x, z, foot) then
				local y = if need > 2
					then round2(lo - 6 - 16 * rand())
					else round2(lo - Course.CLOUD_CLEAR - 2 - Course.PROP_HEIGHT.cloud * scale - 14 * rand())
				table.insert(props, { kind = "cloud", x = x, y = y, z = z, scale = scale, yaw = round2(rand() * 2 * math.pi) })
				table.insert(low, { x, z, foot })
				break
			end
		end
	end
	-- Hot-air balloons high above, beside the course.
	local balloons = if rand() < 0.5 then 1 else 2
	for _ = 1, balloons do
		for _ = 1, 80 do
			local foot = Course.PROP_FOOT.balloon * 2
			local x, z = propSpot(ax0, ax1, az0, az1, foot, rand)
			if clearOf(elements, x, z) >= foot and clearOfTaken(taken, x, z, foot) then
				table.insert(props, { kind = "balloon", x = x, y = round2(hi + 25 + 15 * rand()), z = z, scale = 2 })
				table.insert(taken, { x, z, foot })
				break
			end
		end
	end
	if theme == "giga" then
		for _ = 1, 6 do
			for _ = 1, 80 do
				local scale = round2(1.5 + 0.7 * rand())
				local foot = Course.PROP_FOOT.star * scale
				local x, z = propSpot(ax0, ax1, az0, az1, foot, rand)
				if clearOf(elements, x, z) >= foot + clearance and clearOfTaken(taken, x, z, foot) then
					local y = round2(hi + 8 + 14 * rand())
					table.insert(props, { kind = "star", x = x, y = y, z = z, scale = scale, yaw = round2(rand() * 2 * math.pi) })
					table.insert(taken, { x, z, foot })
					break
				end
			end
		end
	end
	if index % 3 == 1 then
		-- The giant arch across the walking line, facing along the start: over the bridge into
		-- the map, as far back as its feet need to clear the course; map 1 (no bridge in)
		-- straddles its first lane where it fits.
		local s = elements[1]
		local spots: { { number } } = {}
		if index > 1 then
			for back = 15, 24, 0.5 do
				local along = (s.sx :: number) / 2 + back
				table.insert(spots, { s.x - face[1] * along, s.z - face[2] * along })
			end
		else
			for _, e in elements do
				if e.path and e ~= s and math.abs(e.z - s.z) < 1 then
					for k = 0, 32 do
						local shift = (if k % 2 == 0 then 1 else -1) * math.ceil(k / 2)
						table.insert(spots, { e.x, e.z + shift })
					end
				end
			end
		end
		local placed = false
		for _, spot in spots do
			local x, z = round2(spot[1]), round2(spot[2])
			if Course.archFits(elements, x, s.y, z, face, Course.ARCH_SCALE) then
				local yaw = round2(math.atan2(-face[1], -face[2]))
				table.insert(props, { kind = "rainbowarch", x = x, y = s.y, z = z, scale = Course.ARCH_SCALE, yaw = yaw })
				placed = true
				break
			end
		end
		assert(placed, `Course: no room for the rainbow arch on map {index}`)
	end
	return props
end

-- A map's local region: every element and prop footprint (the arch over the bridge aside)
-- grown by REGION_MARGIN; y is filled in when the map is placed.
local function localBounds(elements: { Element }, props: { Prop }): Box
	local x0, x1, z0, z1 = footprint(elements)
	for _, p in props do
		if p.kind ~= "rainbowarch" then
			local foot = Course.propFoot(p)
			x0, x1 = math.min(x0, p.x - foot), math.max(x1, p.x + foot)
			z0, z1 = math.min(z0, p.z - foot), math.max(z1, p.z + foot)
		end
	end
	local m = Course.REGION_MARGIN
	return { x0 = round2(x0 - m), x1 = round2(x1 + m), z0 = round2(z0 - m), z1 = round2(z1 + m), y0 = 0, y1 = 0 }
end

-- Highest local y anything of the map reaches (landmarks stand up to ~145 studs tall).
local function topOf(elements: { Element }, props: { Prop }): number
	local _, hi = pathHeights(elements)
	local top = hi + 40
	for _, p in props do
		top = math.max(top, p.y + (Course.PROP_HEIGHT[p.kind] or 15) * (p.scale or 1) + 5)
	end
	return round2(top)
end

-- Is box deck `e` at least 1 stud clear of every element but `except`, at every phase?
local function deckClear(elements: { Element }, except: Element, e: Element): boolean
	local hx, hz = (e.sx :: number) / 2, (e.sz :: number) / 2
	for _, o in elements do
		if o ~= except and math.abs(o.x - e.x) < hx + 45 and math.abs(o.z - e.z) < hz + 45 then
			for x = -hx, hx, 1 do
				for z = -hz, hz, 1 do
					if Course.footDistance(o, e.x + x, e.z + z) < 1 then
						return false
					end
				end
			end
		end
	end
	return true
end

-- Kill elements (lava) on map n's wide path decks, in its local frame: up to 1 + n // 3 of
-- them (Course.killCount), at most KILL_PER_DECK per deck, KILL_SPACING studs clear of each
-- other; fewer when the decks run out. A deck qualifies when it is a plain box pad (not the start/finish deck, a
-- checkpoint, mover, blink pad or ring) at least KILL_MIN_DECK long along the walking axis
-- (the direction from the previous path element). A strip lies across the deck KILL_WIDTH
-- wide, leaving KILL_CLEAR studs of the deck free on each side along the walking axis and
-- KILL_GAP studs from every wall and bounce pad on it; a deck KILL_SLIDE_DECK long or more
-- with no wall or bounce pad may instead carry a sliding bar (centre of the deck, moving
-- +-(extent / 2 - KILL_CLEAR) along the walking axis). Decks with spinners (they already guard
-- them) carry lava only when the map has no other deck.
Course.KILL_WIDTH = 1.6
Course.KILL_PER_DECK = 2
Course.KILL_SPACING = 6
Course.KILL_HEIGHT = 0.6
Course.KILL_CLEAR = 4
Course.KILL_GAP = 2
Course.KILL_MIN_DECK = 16
Course.KILL_SLIDE_DECK = 20

function Course.killCount(n: number): number
	return if n >= 2 then 1 + n // 3 else 0
end

local function placeKills(elements: { Element }, n: number, rand: () -> number): { Element }
	local want = Course.killCount(n)
	if want == 0 then
		return {}
	end
	type Spot = { deck: Element, alongX: boolean, length: number, offsets: { number }, slide: boolean, used: { number } }
	local w = Course.KILL_WIDTH / 2
	local calmSpots, busySpots = {} :: { Spot }, {} :: { Spot }
	local before: Element? = nil
	for _, e in elements do
		if not e.path then
			continue
		end
		local from = before
		before = e
		if not from or e.kind ~= "pad" or e.shape ~= "box" or e.name == "StartDeck" or e.name == "FinishDeck" or e.name == "Bridge" then
			continue
		end
		local alongX = math.abs(e.x - from.x) >= math.abs(e.z - from.z)
		local length = (if alongX then e.sx else e.sz) :: number
		if length < Course.KILL_MIN_DECK then
			continue
		end
		-- Walls and bounce pads on this deck ({ along-axis offset, half extent }), and spinners.
		local blocks: { { number } } = {}
		local spinners = false
		for _, o in elements do
			local on = math.abs(o.y - e.y) < 0.01
				and math.abs(o.x - e.x) <= (e.sx :: number) / 2
				and math.abs(o.z - e.z) <= (e.sz :: number) / 2
			if on and o.kind == "wall" then
				table.insert(blocks, { if alongX then o.x - e.x else o.z - e.z, ((if alongX then o.sx else o.sz) :: number) / 2 })
			elseif on and o.kind == "bounce" then
				table.insert(blocks, { if alongX then o.x - e.x else o.z - e.z, o.r :: number })
			elseif on and o.kind == "spinner" then
				spinners = true
			end
		end
		-- Strip centres every 0.2 studs, KILL_CLEAR from both ends and KILL_GAP from blocks.
		local limit = length / 2 - Course.KILL_CLEAR - w
		local offsets = {}
		for k = -math.floor(limit * 5 + 1e-6), math.floor(limit * 5 + 1e-6) do
			local c = k / 5
			local ok = true
			for _, b in blocks do
				ok = ok and math.abs(c - b[1]) - w - b[2] >= Course.KILL_GAP - 1e-6
			end
			if ok then
				table.insert(offsets, c)
			end
		end
		local slide = length >= Course.KILL_SLIDE_DECK and #blocks == 0
		if #offsets > 0 or slide then
			local spot = { deck = e, alongX = alongX, length = length, offsets = offsets, slide = slide, used = {} }
			table.insert(if spinners then busySpots else calmSpots, spot)
		end
	end
	local kills: { Element } = {}
	local function add(spot: Spot, slide: boolean, offset: number)
		local e = spot.deck
		local across = (if spot.alongX then e.sz else e.sx) :: number
		local kill: Element = {
			kind = "kill",
			x = if spot.alongX then round2(e.x + offset) else e.x,
			y = e.y,
			z = if spot.alongX then e.z else round2(e.z + offset),
			sx = if spot.alongX then Course.KILL_WIDTH else across,
			sz = if spot.alongX then across else Course.KILL_WIDTH,
			h = Course.KILL_HEIGHT,
			color = "Lava",
		}
		if slide then
			kill.motion = "slide"
			kill.axis = if spot.alongX then { 1, 0, 0 } else { 0, 0, 1 }
			kill.distance = round2(spot.length / 2 - Course.KILL_CLEAR)
			kill.period = round2(4 + 2 * rand())
			kill.phase = round2(rand() * 2 * math.pi)
			spot.offsets = {}
		end
		table.insert(spot.used, offset)
		table.insert(kills, kill)
	end
	-- Strip centres on a deck still KILL_SPACING (plus both half widths) from its other strips.
	local function free(spot: Spot): { number }
		local out = {}
		if #spot.used >= Course.KILL_PER_DECK then
			return out
		end
		for _, c in spot.offsets do
			local ok = true
			for _, u in spot.used do
				ok = ok and math.abs(c - u) >= 2 * w + Course.KILL_SPACING - 1e-6
			end
			if ok then
				table.insert(out, c)
			end
		end
		return out
	end
	-- One per deck, picked at random (spinner decks only when there is no other); then, if
	-- decks run short, a second strip on decks that already have one.
	local order: { Spot } = {}
	local list = if #calmSpots > 0 then calmSpots else busySpots
	-- (A sliding bar takes its whole deck: none when decks are short.)
	local plenty = #list >= want
	do
		while #kills < want and #list > 0 do
			local spot = table.remove(list, 1 + math.floor(rand() * #list)) :: Spot
			table.insert(order, spot)
			local slide = spot.slide and (#spot.offsets == 0 or (plenty and rand() < 0.5))
			add(spot, slide, if slide then 0 else spot.offsets[1 + math.floor(rand() * #spot.offsets)])
		end
	end
	local progress = true
	while #kills < want and progress do
		progress = false
		for _, spot in order do
			local room = free(spot)
			if #kills < want and #room > 0 then
				add(spot, false, room[1 + math.floor(rand() * #room)])
				progress = true
			end
		end
	end
	assert(#kills >= 1, `Course.generate: level {n} has no deck for lava`)
	return kills
end

-- One map before it is placed: everything in its local frame.
type Local = {
	n: number,
	elements: { Element },
	props: { Prop },
	bounds: Box,
	start: Element,
	finish: Element,
	startFace: { number }, -- local { x, z } the start deck faces
	exit: { number }, -- local { x, z } the runner leaves the finish deck along
	arch: { number }, -- local { x, z } of the finish arch
	top: number,
	tuning: Tuning?,
}

local KINDS = { "pad", "disc", "beam", "slide", "bob", "spinner", "walls", "blink", "ramp" }
-- Kinds never placed right after a mover/blink pad, a bounce or near a lane's turn.
local LIVELY = { slide = true, bob = true, blink = true, ramp = true }

local function finalize(level: Level)
	level.PATH, level.CHECKPOINTS, level.KILLS = {}, {}, {}
	for _, element in level.ELEMENTS do
		if element.path then
			table.insert(level.PATH, element)
		end
		if element.kind == "kill" then
			table.insert(level.KILLS, element)
		end
		if element.kind == "checkpoint" then
			level.CHECKPOINTS[element.index :: number] = element
		end
	end
	level.CHECKPOINT_COUNT = #level.CHECKPOINTS
	level.MIN_LEG_SECONDS = {}
	for k = 1, level.CHECKPOINT_COUNT + 1 do
		level.MIN_LEG_SECONDS[k] = Course.legLength(level, k - 1, k) / Course.MAX_PLAUSIBLE_SPEED
	end
end

-- Lays out level n (2..LEVEL_COUNT) in its local frame from TUNING[n] and its map's recipe
-- (Course.MAPS[n].recipe); same result on every call.
local function generateLocal(n: number): Local
	local T = Course.TUNING[n]
	local map = Course.MAPS[n]
	local R = map.recipe :: Recipe
	local pal = Course.PALETTES[n]
	local rand = rng(n * 7919 + 17)
	local gapTarget = R.gap or T.gap
	local rise = R.rise or T.rise
	local climb = R.climb or 0
	local yMax = R.yMax or Y_MAX
	local bounceCount = R.bounces or 1
	local bounceRise = R.bounceRise or BOUNCE_RISE
	local beamLength = R.beamLength or 16
	local lane = R.lane or LANE
	local checkpointEvery = R.checkpointEvery or T.checkpointEvery
	local spinBars = R.spinBars or T.spinBars
	local moverTravel = R.moverTravel or T.moverTravel
	local moverPeriod = R.moverPeriod or T.moverPeriod
	local elements: { Element } = {}
	local count = 0
	local function add(e: Element)
		table.insert(elements, e)
		if e.path then
			count += 1
		end
	end
	local prev = box(0, Y_MIN + 2, 0, 12, 12, pal.main, "StartDeck")
	add(prev)
	local dir, laneStart, laneZ, turnLeft = 1, 0, 0, 0
	-- Studs one more element may take along a lane (the widest kind, its gap and a turn
	-- pad's overhang): lanes heading back -X turn before anything reaches X_FLOOR, behind the
	-- start deck, where the bridge from the previous map arrives.
	local reach = math.max(beamLength, 8 + 9 * spinBars, 26) + gapTarget + 6
	local function room(): number
		local left = lane - (prev.x - laneStart) * dir
		if dir < 0 then
			left = math.min(left, prev.x - halfAlong(prev, true) - reach - X_FLOOR)
		end
		return left
	end
	local sinceCp, cpIndex, bounced, afterBounce = 0, 0, 0, false
	local plainPads = 0
	while count < T.pathLength do
		if turnLeft == 0 and room() <= 0 then
			turnLeft = 2
		end
		local turning = turnLeft > 0
		local kind
		if count == T.pathLength - 1 then
			kind = "finish"
		elseif sinceCp >= checkpointEvery - 1 then
			kind = "checkpoint"
		elseif turning then
			kind = "pad"
		elseif bounced < bounceCount and count >= T.pathLength * (bounced + 1) // (bounceCount + 1) and not afterBounce then
			kind = "bounce"
		else
			-- No two moving/blinking pads in a row, none right after a bounce, and no
			-- sideways slider where the lane turns (it would slide into the turn pad).
			local left = room()
			-- (nor right before the finish deck, which steps off sideways).
			local calm = prev.kind == "mover" or prev.kind == "blink" or afterBounce or left <= 24 or count >= T.pathLength - 2
			local rampOk = not calm
				and left > 32
				and count < T.pathLength - 3
				and prev.y >= Y_MIN + 2.5
				and (
					(prev.kind == "pad" and prev.shape ~= "hex" and (prev.name == nil or prev.name == "Beam" or prev.name == "StartDeck"))
					or prev.kind == "checkpoint"
				)
			local function weight(k: string): number
				if (calm and LIVELY[k]) or (k == "ramp" and not rampOk) or (k == "blink" and not T.blinkOn) then
					return 0
				end
				return R.weights[k] or 0
			end
			local total = 0
			for _, k in KINDS do
				total += weight(k)
			end
			local pick = rand() * total
			kind = "pad"
			for _, k in KINDS do
				local w = weight(k)
				if w > 0 then
					pick -= w
					if pick < 0 then
						kind = k
						break
					end
				end
			end
			-- Blink maps: every k-th plain pad blinks, so blink pads never run dry.
			if kind == "pad" and T.blinkOn and R.blinkEvery and not calm then
				plainPads += 1
				if plainPads % R.blinkEvery == 0 then
					kind = "blink"
				end
			end
		end
		local size = T.padSize
		local colour = if count % 2 == 0 then pal.main else pal.alt
		if kind == "ramp" then
			-- A slide from prev's far edge down onto a landing pad, straight along the lane.
			local drop = round2(math.min(prev.y - Y_MIN, 2.5 + 2.5 * rand()))
			local length = round2(12 + 4 * rand())
			local fromX = prev.x + dir * halfAlong(prev, true)
			local toX = fromX + dir * length
			local ramp: Element = {
				kind = "slide",
				x = round2((fromX + toX) / 2),
				y = round2(prev.y - drop / 2),
				z = prev.z,
				from = { fromX, prev.y, prev.z },
				to = { toX, round2(prev.y - drop), prev.z },
				width = 6,
				color = pal.accent,
				path = true,
			}
			local landing = box(round2(toX + dir * size / 2), round2(prev.y - drop), prev.z, size, size + 1, colour)
			add(ramp)
			add(landing)
			sinceCp += 2
			afterBounce = false
			prev = landing
			continue
		end
		local e: Element
		local extras: { Element } = {}
		if kind == "finish" then
			e = box(0, 0, 0, 16, 14, pal.main, "FinishDeck")
		elseif kind == "checkpoint" then
			cpIndex += 1
			e = checkpoint(cpIndex, 0, 0, 0, T.checkpointR, pal.checkpoint)
		elseif kind == "disc" then
			-- Every other round tile or so is a big hex.
			e = if rand() < 0.45 then hex(0, 0, 0, round2(6 + rand()), colour) else disc(0, 0, 0, T.discR, colour)
		elseif kind == "beam" then
			e = box(0, 0, 0, beamLength, T.beamW, colour, "Beam")
		elseif kind == "slide" or kind == "bob" then
			local bob = kind == "bob"
			e = box(0, 0, 0, size, size, pal.mover)
			e.kind, e.name = "mover", nil
			e.motion = if bob then "bob" else "slide"
			e.axis = if bob then { 0, 1, 0 } else { 0, 0, 1 }
			e.distance = if bob then round2(moverTravel / 2) else moverTravel
			e.period = moverPeriod
			e.phase = round2(rand() * 2 * math.pi)
		elseif kind == "blink" then
			e = box(0, 0, 0, size, size, pal.blink)
			e.kind = "blink"
			e.on, e.period = T.blinkOn, T.blinkPeriod
			e.phase = round2(rand() * (T.blinkPeriod :: number))
		elseif kind == "spinner" then
			e = box(0, 0, 0, 8 + 9 * spinBars, 12, colour, "SweeperDeck")
			for k = 1, spinBars do
				local sign = if k % 2 == 0 then -1 else 1
				local bar = { kind = "spinner", x = (k - (spinBars + 1) / 2) * 9, y = 0, z = 0, length = 10 }
				bar.speed, bar.phase = sign * T.spinSpeed, round2(k * 1.3)
				table.insert(extras, bar :: Element)
			end
		elseif kind == "walls" then
			e = box(0, 0, 0, 20, size + 3, colour, "WallHopDeck")
			for k = -1, 1 do
				table.insert(extras, { kind = "wall", x = k * 6, y = 0, z = 0, sx = 1.2, sz = size + 3, h = 2.4, color = pal.accent })
			end
		elseif kind == "bounce" then
			bounced += 1
			e = box(0, 0, 0, 10, size + 2, colour, "BounceDeck")
			table.insert(extras, { kind = "bounce", x = 0, y = 0, z = 0, r = 2.5, power = BOUNCE_POWER, color = pal.accent })
		elseif not turning and rand() < 0.35 then
			e = ring(0, 0, 0, round2(12 + 2 * rand()), colour)
		else
			e = box(0, 0, 0, size, size, colour)
		end
		-- Height change and spacing: the widest gap up to the target that is fair at every
		-- phase; smaller steps if nothing fits.
		-- The finish deck always steps +Z off the last lane: the course's outer edge.
		local alongX = not turning and kind ~= "finish"
		local jumpHeight = if afterBounce then BOUNCE_HEIGHT else nil
		local wantUp = if afterBounce then bounceRise else math.min(Course.MAX_STEP_UP, (rand() * 2 - 1) * rise + climb)
		if prev.y + wantUp < Y_MIN then
			wantUp = -wantUp
		end
		wantUp = math.clamp(wantUp, Y_MIN - prev.y, yMax - prev.y)
		local target = gapTarget * (0.9 + 0.1 * rand())
		local jitter = if (e.shape == "disc" or e.shape == "hex") and alongX then (rand() * 2 - 1) * 1.5 else 0
		local placed = false
		for _, dy in { wantUp, wantUp / 2, 0, -1, -2.5, -4 } do
			e.y = round2(math.max(Y_MIN, prev.y + dy))
			local g = target
			while g >= 1 do
				local centre = halfAlong(prev, alongX) + g + halfAlong(e, alongX)
				if alongX then
					e.x, e.z = round2(prev.x + dir * centre), round2(laneZ + jitter)
				else
					e.x, e.z = prev.x, round2(prev.z + centre)
				end
				if fits(prev, e, jumpHeight) and (kind ~= "finish" or deckClear(elements, prev, e)) then
					placed = true
					break
				end
				g -= 0.2
			end
			if placed then
				break
			end
		end
		assert(placed, `Course.generate: no fair spot (level {n}, {kind} after {prev.kind}, turning {turning}, prev y {prev.y})`)
		for _, x in extras do
			x.x, x.y, x.z = e.x + x.x, e.y, e.z
		end
		add(e)
		for _, x in extras do
			add(x)
		end
		afterBounce = kind == "bounce"
		sinceCp = if kind == "checkpoint" then 0 else sinceCp + 1
		if turning then
			turnLeft -= 1
			laneZ = e.z
			if turnLeft == 0 then
				dir, laneStart = -dir, e.x
			end
		end
		prev = e
	end

	local x0, _, _, z1 = footprint(elements)
	assert(x0 >= X_FLOOR - 1e-6, `Course.generate: level {n} reaches behind its start deck`)
	assert(z1 <= prev.z + (prev.sz :: number) / 2 + 1e-6, `Course.generate: level {n} finish is not its outer edge`)
	local props = placeScenery(elements, map.theme, n, 1, { 1, 0 }, rand)
	-- Lava last (after the scenery, from the same rng), so nothing above shifts.
	for _, kill in placeKills(elements, n, rand) do
		table.insert(elements, kill)
	end
	return {
		n = n,
		elements = elements,
		props = props,
		bounds = localBounds(elements, props),
		start = elements[1],
		finish = prev,
		startFace = { 1, 0 },
		exit = { 0, 1 },
		arch = { prev.x, prev.z },
		top = topOf(elements, props),
		tuning = T,
	}
end

-- Horizontal distance along the centres of consecutive path elements from checkpoint
-- `fromIndex` (0 = start deck) to checkpoint `toIndex` (CHECKPOINT_COUNT + 1 = finish deck).
function Course.legLength(level: Level, fromIndex: number, toIndex: number): number
	local path = level.PATH
	local first: number? = if fromIndex == 0 then 1 else nil
	local last: number? = if toIndex > level.CHECKPOINT_COUNT then #path else nil
	for i, element in path do
		if element.kind == "checkpoint" then
			if element.index == fromIndex then
				first = i
			end
			if element.index == toIndex then
				last = i
			end
		end
	end
	if not first or not last then
		return 0
	end
	local total = 0
	for i = first, last - 1 do
		local a, b = path[i], path[i + 1]
		total += math.sqrt((a.x - b.x) ^ 2 + (a.z - b.z) ^ 2)
	end
	return total
end

local function copyElement(e: Element): Element
	local c = table.clone(e)
	for _, key in { "axis", "from", "to" } do
		local list = (e :: any)[key]
		if list then
			(c :: any)[key] = table.clone(list)
		end
	end
	return c
end

-- Level 1 in its local frame: LEVEL1_ELEMENTS as drawn (start deck at x = -197, z = 0,
-- facing west; the finish deck at the east end of the south lane, left eastward), its
-- islands on the west side.
local function level1Local(): Local
	local elements: { Element } = {}
	local finish: Element? = nil
	for _, e in LEVEL1_ELEMENTS do
		local c = copyElement(e)
		table.insert(elements, c)
		if c.path then
			finish = c
		end
	end
	local props = placeScenery(elements, Course.MAPS[1].theme, 1, -1, { -1, 0 }, rng(1 * 7919 + 17))
	return {
		n = 1,
		elements = elements,
		props = props,
		bounds = localBounds(elements, props),
		start = elements[1],
		finish = finish :: Element,
		startFace = { -1, 0 },
		exit = { 1, 0 },
		-- The runner comes off the slide at the deck's west edge.
		arch = { -204, -53 },
		top = topOf(elements, props),
		tuning = nil,
	}
end

local function buildLocal(n: number): Local
	return if n == 1 then level1Local() else generateLocal(n)
end

-- Where a map's local frame lands: world (x, z) = (ox, oz) + x * u + z * v and y + oy, with
-- u, v unit axes (a 90-degree turn, maybe mirrored). stageFirst / rainbowFirst: the map's
-- first global stage and its start deck's slot in the RAINBOW cycle.
type Frame = { u: { number }, v: { number }, ox: number, oz: number, oy: number, stageFirst: number, rainbowFirst: number }

local function toWorld(f: Frame, x: number, z: number): (number, number)
	return round2(f.ox + x * f.u[1] + z * f.v[1]), round2(f.oz + x * f.u[2] + z * f.v[2])
end

local function turnDir(f: Frame, x: number, z: number): (number, number)
	return x * f.u[1] + z * f.v[1] + 0, x * f.u[2] + z * f.v[2] + 0
end

local function boxToWorld(f: Frame, b: Box): Box
	local ax, az = toWorld(f, b.x0, b.z0)
	local bx, bz = toWorld(f, b.x1, b.z1)
	return {
		x0 = math.min(ax, bx),
		x1 = math.max(ax, bx),
		z0 = math.min(az, bz),
		z1 = math.max(az, bz),
		y0 = round2(b.y0 + f.oy),
		y1 = round2(b.y1 + f.oy),
	}
end

-- The frame of map `nextL` chained after map `L` (placed by `f`): its start deck BRIDGE_GAP
-- past L's finish deck along L's exit, its lanes running on along that direction and its
-- serpentine advancing to one side (flip = +1: left of the exit, -1: right), its start deck
-- (BRIDGE_STEPS + 1) * BRIDGE_RISE above L's finish deck.
local function nextFrame(f: Frame, L: Local, nextL: Local, flip: number): Frame
	local fin, s = L.finish, nextL.start
	local fx, fz = toWorld(f, fin.x, fin.z)
	local dx, dz = turnDir(f, L.exit[1], L.exit[2])
	local half = if math.abs(L.exit[1]) > 0.5 then (fin.sx :: number) / 2 else (fin.sz :: number) / 2
	local dist = half + Course.BRIDGE_GAP + (s.sx :: number) / 2
	local u = { dx, dz }
	local v = { -dz * flip + 0, dx * flip + 0 }
	local sx, sz = fx + dx * dist, fz + dz * dist
	return {
		u = u,
		v = v,
		ox = round2(sx - (s.x * u[1] + s.z * v[1])),
		oz = round2(sz - (s.x * u[2] + s.z * v[2])),
		oy = round2(fin.y + f.oy + (Course.BRIDGE_STEPS + 1) * Course.BRIDGE_RISE - s.y),
		stageFirst = 0,
		rainbowFirst = 0,
	}
end

local function overlaps(a: Box, b: Box): boolean
	return not (a.x1 < b.x0 or b.x1 < a.x0 or a.z1 < b.z0 or b.z1 < a.z0)
end

-- The chain: map 1 as drawn (lifted so its start deck is at SKY_Y), then every next map on
-- the side that keeps the regions apart and the whole chain within 2 * CHAIN_LIMIT, trying
-- the staircase side (towards +X / +Z) first; finally the chain is centred on the origin.
local LOCALS: { Local } = {}
for n = 1, Course.LEVEL_COUNT do
	LOCALS[n] = buildLocal(n)
end
local FRAMES: { Frame } = {
	{ u = { 1, 0 }, v = { 0, 1 }, ox = 0, oz = 0, oy = round2(Course.SKY_Y - LOCALS[1].start.y), stageFirst = 1, rainbowFirst = 0 },
}
do
	local regions: { Box } = { boxToWorld(FRAMES[1], LOCALS[1].bounds) }
	local span = 2 * Course.CHAIN_LIMIT - 20
	local function solve(n: number): boolean
		if n > Course.LEVEL_COUNT then
			return true
		end
		local prev, L = FRAMES[n - 1], LOCALS[n - 1]
		local dx, dz = turnDir(prev, L.exit[1], L.exit[2])
		local first = if -dz + dx > 0 then 1 else -1
		for _, flip in { first, -first } do
			local f = nextFrame(prev, L, LOCALS[n], flip)
			local r = boxToWorld(f, LOCALS[n].bounds)
			local ok = true
			local x0, x1, z0, z1 = r.x0, r.x1, r.z0, r.z1
			for j = 1, n - 1 do
				local o = regions[j]
				ok = ok and not overlaps(r, o)
				x0, x1, z0, z1 = math.min(x0, o.x0), math.max(x1, o.x1), math.min(z0, o.z0), math.max(z1, o.z1)
			end
			if ok and x1 - x0 <= span and z1 - z0 <= span then
				FRAMES[n], regions[n] = f, r
				if solve(n + 1) then
					return true
				end
			end
		end
		FRAMES[n], regions[n] = nil :: any, nil :: any
		return false
	end
	assert(solve(2), "Course: the sky chain does not fit")
	local x0, x1, z0, z1 = math.huge, -math.huge, math.huge, -math.huge
	for _, r in regions do
		x0, x1, z0, z1 = math.min(x0, r.x0), math.max(x1, r.x1), math.min(z0, r.z0), math.max(z1, r.z1)
	end
	local shiftX, shiftZ = -math.floor((x0 + x1) / 2 + 0.5), -math.floor((z0 + z1) / 2 + 0.5)
	-- Global stages and rainbow slots run on from map to map (a bridge takes BRIDGE_STEPS).
	local stage, slot = 1, 0
	for n, f in FRAMES do
		f.ox, f.oz = round2(f.ox + shiftX), round2(f.oz + shiftZ)
		f.stageFirst, f.rainbowFirst = stage, slot
		local checkpoints, path = 0, 0
		for _, e in LOCALS[n].elements do
			if e.path then
				path += 1
			end
			if e.kind == "checkpoint" then
				checkpoints += 1
			end
		end
		stage += checkpoints + 1
		slot += path + Course.BRIDGE_STEPS
	end
	-- Map 10's finish deck.
	Course.STAGE_COUNT = stage
end

local function rainbow(slot: number): string
	return Course.RAINBOW[slot % #Course.RAINBOW + 1]
end

-- Turns map L (its tables, in place) into its world Level with frame f.
local function place(L: Local, f: Frame): Level
	local n = L.n
	local map = Course.MAPS[n]
	local swap = math.abs(f.u[1]) < 0.5
	local slot = f.rainbowFirst
	for _, e in L.elements do
		e.x, e.z = toWorld(f, e.x, e.z)
		e.y = round2(e.y + f.oy)
		if swap and e.sx then
			e.sx, e.sz = e.sz, e.sx
		end
		local axis = e.axis
		if axis then
			local ax, az = turnDir(f, axis[1], axis[3])
			e.axis = { ax, axis[2], az }
		end
		for _, key in { "from", "to" } do
			local point = (e :: any)[key]
			if point then
				local px, pz = toWorld(f, point[1], point[3]);
				(e :: any)[key] = { px, round2(point[2] + f.oy), pz }
			end
		end
		if e.path then
			if e.kind == "checkpoint" then
				e.color = "Checkpoint"
				e.stage = f.stageFirst + (e.index :: number)
			elseif e.kind == "pad" or e.kind == "slide" then
				e.color = rainbow(slot)
			end
			slot += 1
		end
	end
	for _, p in L.props do
		p.x, p.z = toWorld(f, p.x, p.z)
		p.y = round2(p.y + f.oy)
		if p.yaw then
			local lx, lz = turnDir(f, -math.sin(p.yaw), -math.cos(p.yaw))
			p.yaw = round2(math.atan2(-lx, -lz))
		end
	end
	local s, fin = L.start, L.finish
	local faceX, faceZ = turnDir(f, L.startFace[1], L.startFace[2])
	local archX, archZ = toWorld(f, L.arch[1], L.arch[2])
	local archFaceX, archFaceZ = turnDir(f, -L.exit[1], -L.exit[2])
	local hx, hz = (fin.sx :: number) / 2, (fin.sz :: number) / 2
	local bounds = boxToWorld(f, L.bounds)
	bounds.y0, bounds.y1 = Course.FLOOR_Y - 30, round2(L.top + f.oy)
	local checkpoints = 0
	for _, e in L.elements do
		if e.kind == "checkpoint" then
			checkpoints += 1
		end
	end
	local level: Level = {
		index = n,
		name = Course.NAMES[n],
		difficulty = n,
		remote = true,
		theme = map.theme,
		blurb = map.blurb,
		icon = map.icon,
		accent = map.accent,
		PROPS = L.props,
		palette = Course.PALETTES[n],
		ELEMENTS = L.elements,
		PATH = {},
		CHECKPOINTS = {},
		KILLS = {},
		CHECKPOINT_COUNT = 0,
		STAGE_FIRST = f.stageFirst,
		STAGE_LAST = f.stageFirst + checkpoints + 1,
		START = { x = s.x, y = s.y, z = s.z, faceX = faceX, faceZ = faceZ },
		FINISH = { x0 = fin.x - hx, x1 = fin.x + hx, z0 = fin.z - hz, z1 = fin.z + hz, y0 = fin.y - 1, y1 = fin.y + 10 },
		FINISH_ARCH = { x = archX, y = fin.y, z = archZ, faceX = archFaceX, faceZ = archFaceZ },
		WATER_BOX = { x0 = bounds.x0, x1 = bounds.x1, z0 = bounds.z0, z1 = bounds.z1, y0 = Course.FLOOR_Y - 20, y1 = Course.FLOOR_Y },
		BOUNDS = bounds,
		MIN_LEG_SECONDS = {},
		TUNING = L.tuning,
	}
	finalize(level)
	return level
end

-- Builds level n (1..LEVEL_COUNT) afresh, placed on the chain; same result on every call.
function Course.generate(n: number): Level
	return place(buildLocal(n), FRAMES[n])
end

Course.LEVELS = {} :: { Level }
-- Each level's rectangle (its BOUNDS) and centre (x, z).
Course.REGIONS = {} :: { Box }
Course.CENTRES = {} :: { { number } }
for n = 1, Course.LEVEL_COUNT do
	local level = place(LOCALS[n], FRAMES[n])
	Course.LEVELS[n] = level
	Course.REGIONS[n] = level.BOUNDS
	local b = level.BOUNDS
	Course.CENTRES[n] = { round2((b.x0 + b.x1) / 2), round2((b.z0 + b.z1) / 2) }
end

-- The rainbow stairs: BRIDGES[n] joins map n's finish deck to map n + 1's start deck.
Course.BRIDGES = {} :: { { Element } }
for n = 1, Course.LEVEL_COUNT - 1 do
	local level, f = Course.LEVELS[n], FRAMES[n + 1]
	local fin = level.PATH[#level.PATH]
	local dx, dz = f.u[1], f.u[2]
	local alongX = math.abs(dx) > 0.5
	local half = if alongX then (fin.sx :: number) / 2 else (fin.sz :: number) / 2
	local steps, step = Course.BRIDGE_STEPS, Course.BRIDGE_STEP
	local gap = (Course.BRIDGE_GAP - steps * step) / (steps + 1)
	local list: { Element } = {}
	for k = 1, steps do
		local along = half + gap * k + step * (k - 0.5)
		local sx = if alongX then step else Course.BRIDGE_WIDTH
		local sz = if alongX then Course.BRIDGE_WIDTH else step
		local slot = FRAMES[n].rainbowFirst + #level.PATH + k - 1
		local x, z = round2(fin.x + dx * along), round2(fin.z + dz * along)
		table.insert(list, box(x, round2(fin.y + Course.BRIDGE_RISE * k), z, sx, sz, rainbow(slot), "Bridge"))
	end
	Course.BRIDGES[n] = list
end

-- The cloud floor far under a map (World draws it, never colliding: the WATER_BOX catch
-- volume at FLOOR_Y handles falls): 40-80 thin, wide, overlapping puffs, each an upright
-- cylinder { x, y, z, d (diameter), h (height) } with y its centre, in loose clusters on a
-- jittered grid with whole cells left open so the blue sky shows through. They spread
-- CLOUD_FLOOR_SPREAD studs past the map's bounds and float CLOUD_FLOOR_DEPTH studs under its
-- lowest path top (every part, top to bottom). Same result on every call.
export type Puff = { x: number, y: number, z: number, d: number, h: number }
function Course.cloudLayer(level: Level): { Puff }
	local lo = pathHeights(level.ELEMENTS)
	local b, spread = level.BOUNDS, Course.CLOUD_FLOOR_SPREAD
	local x0, x1, z0, z1 = b.x0 - spread, b.x1 + spread, b.z0 - spread, b.z1 + spread
	local w, d = x1 - x0, z1 - z0
	local top, bottom = lo - Course.CLOUD_FLOOR_DEPTH[1], lo - Course.CLOUD_FLOOR_DEPTH[2]
	-- About 28 cells; whole cells stay open (never more than 8 of them).
	local nx = math.clamp(math.floor(math.sqrt(28 * w / d) + 0.5), 3, 9)
	local nz = math.clamp(math.floor(28 / nx + 0.5), 3, 9)
	local cw, cd = w / nx, d / nz
	local rand = rng(level.index * 97 + 5)
	local puffs: { Puff } = {}
	local open, cells = 0, nx * nz
	local function add(x: number, y: number, z: number, dia: number, h: number)
		if #puffs < 80 then
			table.insert(puffs, { x = round2(x), y = round2(y), z = round2(z), d = round2(dia), h = round2(h) })
		end
	end
	for i = 0, nx - 1 do
		for j = 0, nz - 1 do
			if rand() < 0.25 and open < math.min(8, cells - 20) then
				open += 1
				continue
			end
			local x = x0 + (i + 0.5 + (rand() - 0.5) * 0.4) * cw
			local z = z0 + (j + 0.5 + (rand() - 0.5) * 0.4) * cd
			local main = math.clamp(math.min(cw, cd) * (0.7 + 0.3 * rand()), 40, 120)
			local h = 6 + 2 * rand()
			local y = bottom + h / 2 + 4 + (top - bottom - h - 12) * rand()
			add(x, y, z, main, h)
			-- One or two smaller, taller puffs heaped on its edge.
			for _ = 1, if rand() < 0.5 then 1 else 2 do
				local a = rand() * 2 * math.pi
				local dia = math.clamp(main * (0.45 + 0.25 * rand()), 40, 120)
				local hh = 8 + 2 * rand()
				add(x + math.cos(a) * main * 0.3, y + 2.5, z + math.sin(a) * main * 0.3, dia, hh)
			end
		end
	end
	return puffs
end

function Course.level(i: number): Level
	return Course.LEVELS[math.clamp(math.floor(i), 1, Course.LEVEL_COUNT)]
end

-- Global stage of checkpoint `checkpointIndex` on `level` (0 = start deck,
-- CHECKPOINT_COUNT + 1 = finish deck).
function Course.stageOf(level: Level, checkpointIndex: number): number
	return level.STAGE_FIRST + math.clamp(math.floor(checkpointIndex), 0, level.CHECKPOINT_COUNT + 1)
end

-- The level and checkpoint index of global stage `stage` (clamped to 1..STAGE_COUNT). A
-- stage shared by a finish deck and the next start deck belongs to the next map (index 0);
-- the last stage is map 10's finish deck (CHECKPOINT_COUNT + 1).
function Course.levelOfStage(stage: number): (Level, number)
	local s = math.clamp(math.floor(stage), 1, Course.STAGE_COUNT)
	for _, level in Course.LEVELS do
		if s < level.STAGE_LAST then
			return level, s - level.STAGE_FIRST
		end
	end
	local last = Course.LEVELS[Course.LEVEL_COUNT]
	return last, last.CHECKPOINT_COUNT + 1
end

-- Is (x, z) outside every CLEAR rectangle (free for hub props)?
function Course.isClear(x: number, z: number): boolean
	for _, r in Course.CLEAR do
		if x >= r.x0 and x <= r.x1 and z >= r.z0 and z <= r.z1 then
			return false
		end
	end
	return true
end

-- Are a player's feet standing on checkpoint `cp`?
function Course.onCheckpoint(cp: Element, x: number, y: number, z: number): boolean
	if y < cp.y - 1 or y > cp.y + 6 then
		return false
	end
	if cp.sx then
		return math.abs(x - cp.x) <= (cp.sx :: number) / 2 + 0.5 and math.abs(z - cp.z) <= (cp.sz :: number) / 2 + 0.5
	end
	local r = (cp.r :: number) + 0.5
	return (x - cp.x) ^ 2 + (z - cp.z) ^ 2 <= r * r
end

local function inBox(b: Box, x: number, y: number, z: number): boolean
	return x >= b.x0 and x <= b.x1 and z >= b.z0 and z <= b.z1 and y >= b.y0 and y <= b.y1
end

function Course.inFinish(level: Level, x: number, y: number, z: number): boolean
	return inBox(level.FINISH, x, y, z)
end

function Course.inBounds(level: Level, x: number, y: number, z: number): boolean
	return inBox(level.BOUNDS, x, y, z)
end

-- Fell: feet below the cloud floor (the name stays from the sea days; x and z are unused).
function Course.inWater(_x: number, y: number, _z: number): boolean
	return y < Course.FLOOR_Y
end

-- Did a player's feet cross a start line inside gate 1's opening: westward at the first
-- plaza (-X) or eastward at the second (+X)?
function Course.crossedStart(prevX: number, x: number, z: number): boolean
	if prevX > Course.START_LINE_X and x <= Course.START_LINE_X then
		return math.abs(z - Course.GATES[1].z) <= Course.GATE_HALF + 1
	end
	if prevX < Course.START_LINE2_X and x >= Course.START_LINE2_X then
		return math.abs(z - Course.GATES2[1].z) <= Course.GATE_HALF + 1
	end
	return false
end

export type Spot = { x: number, y: number, z: number, faceX: number }

local function closer(a: Spot, b: Spot, x: number, z: number): Spot
	return if (x - b.x) ^ 2 + (z - b.z) ^ 2 < (x - a.x) ^ 2 + (z - a.z) ^ 2 then b else a
end

-- The quit spot (in front of the gates, facing the hub) of the plaza nearer to (x, z).
function Course.nearestQuit(x: number, z: number): Spot
	return closer(Course.QUIT, Course.QUIT2, x, z)
end

-- The arrival spot (the spur end, facing the gates) of the plaza nearer to (x, z).
function Course.nearestArrival(x: number, z: number): Spot
	return closer(Course.ARRIVAL, Course.ARRIVAL2, x, z)
end

-- Are a player's feet in one of the level's kill boxes at server time t (a sliding bar at
-- its pose then): inside it horizontally and y in [top - 0.5, top + h + 2.5]?
function Course.inKill(level: Level, x: number, y: number, z: number, t: number): boolean
	for _, k in level.KILLS do
		if y < k.y - 0.5 or y > k.y + (k.h or 0) + 2.5 then
			continue
		end
		local cx, cz = k.x, k.z
		if k.motion == "slide" then
			local axis = k.axis :: { number }
			local d = (k.distance :: number) * math.sin(2 * math.pi * t / (k.period :: number) + (k.phase or 0))
			cx, cz = cx + axis[1] * d, cz + axis[3] * d
		end
		if math.abs(x - cx) <= (k.sx :: number) / 2 and math.abs(z - cz) <= (k.sz :: number) / 2 then
			return true
		end
	end
	return false
end

-- Respawn spot for checkpoint `index` (0 = start deck) on `level`: feet position
-- { x, y, z } and the horizontal direction { dx, dz } toward the next path element.
function Course.respawn(level: Level, index: number): ({ number }, { number })
	local here: Element? = level.CHECKPOINTS[index]
	local start = level.START
	local at = if here then { here.x, here.y, here.z } else { start.x, start.y, start.z }
	local nextElement: Element? = nil
	for i, element in level.PATH do
		if (here and element == here) or (not here and i == 1) then
			nextElement = level.PATH[i + 1]
			break
		end
	end
	if not nextElement then
		return at, { start.faceX, start.faceZ }
	end
	local dx, dz = nextElement.x - at[1], nextElement.z - at[3]
	local length = math.max(1e-6, math.sqrt(dx * dx + dz * dz))
	return at, { dx / length, dz / length }
end

-- Beach props the hub must not place here (palms, beach balls): both plazas, their spurs
-- and the big signs behind the gates (the second mirrors the first).
Course.CLEAR = {
	{ x0 = -210, x1 = -138, z0 = -36, z1 = 36 },
	{ x0 = 138, x1 = 210, z0 = -36, z1 = 36 },
}

return Course
