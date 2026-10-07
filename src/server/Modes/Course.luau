--!strict
--[[
	Course: pure layout data for the GAME MODES plaza and the ten Parkour levels.

	No Roblox types: World.Modes builds parts from these numbers, Modes.Parkour polls player
	positions against them and the unit tests check that every jump is fair. All positions
	are world coordinates; a platform's `y` is its TOP surface.

	The plaza sits on the -X side of the hub, between the two plot rows: a boardwalk spur
	leaves the hub ring's -X side at z = 0 and ends on a square wooden deck with the three
	mode gates in a row on its west edge, under one big GAME MODES sign. Every gate is a
	portal: walking through gate 1 teleports the player onto the start deck of their
	current Parkour level. Nothing of the course stands next to the plaza.

	Every level is "remote": each is built out at sea inside its own rectangle
	(level.BOUNDS, also Course.REGIONS[i], centred on Course.CENTRES[i]) and reached only by
	teleport. LEVEL 1 is hand-made (LEVEL1_ELEMENTS, drawn beside the plaza and then moved
	onto its centre): it runs west along one lane, turns south at its far end, comes back
	east along a second lane and slides down to the finish deck. LEVELS 2..10 are generated
	deterministically by Course.generate(n) (own seeded LCG) from Course.TUNING[n], a
	difficulty table that tightens every level: wider gaps, smaller discs, thinner beams,
	faster/longer movers, faster spinners, fewer checkpoints, longer paths, bigger height
	changes and (from level 4) blink pads. Every jump stays fair for the default character
	WITHOUT Double Jump (Course.maxGap). The path is a serpentine: lanes along +-X joined by
	two turn pads stepping +Z.

	Level fields (Course.LEVELS[i] / Course.level(i)):
	  index, name, difficulty (1..10), remote (always true: every level is reached by teleport)
	  palette     Theme.World colour keys: { main, alt, checkpoint, mover, accent, blink }.
	              Every element's `color` is already one of these.
	  ELEMENTS    every element (below); PATH = the `path` ones in walking order
	  CHECKPOINTS checkpoint elements by index; CHECKPOINT_COUNT
	  START       { x, y, z, faceX, faceZ }: start deck spawn (feet) and facing
	  FINISH      { x0, x1, z0, z1, y0, y1 }: feet inside it after the last checkpoint finish
	  FINISH_ARCH { x, y, z, faceX, faceZ }: arch centre on the finish deck top; its front
	              faces the incoming runner (faceX/faceZ is that front's direction)
	  WATER_BOX   { x0, x1, z0, z1, y0, y1 }: the "ParkourWater" catch volume (splash fx)
	  BOUNDS      { x0, x1, z0, z1, y0, y1 }: outside it for LEAVE_SECONDS ends the run
	  MIN_LEG_SECONDS  minimum seconds per checkpoint leg (anti-cheat)
	  TUNING      the knobs it was generated from (nil for level 1)

	Element kinds (`path = true` elements are walked on, in PATH order). All have kind,
	x, y, z (y = top surface) and `color`:
	  pad         static platform; shape "box" (sx along X, sz along Z) or "disc" (radius r);
	              optional `name` ("StartDeck", "FinishDeck", "Beam", ...)
	  checkpoint  static disc (shape "disc", r), numbered `index` 1..n in course order
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
	  blink       box pad (sx, sz; path) that is solid only part of the time: solid when
	              ((t + phase) % period) < on, with t = server time (workspace:
	              GetServerTimeNow()); otherwise non-collidable and faded. Never two in a row.
]]

local Course = {}

-- The plaza deck (x0..x1, z0..z1) and the spur that joins it to the hub ring at x = -118.
Course.PLAZA = { x0 = -190, x1 = -140, z0 = -28, z1 = 28, top = 0.5 }
Course.SPUR = { x0 = -140, x1 = -118, half = 6, top = 0.3 }
-- Where GoModes / ModeQuit put the player (feet): the spur end facing the gates (-X), and
-- in front of the gates facing back toward the hub (+X).
Course.ARRIVAL = { x = -146, y = 0.5, z = 0 }
Course.QUIT = { x = -180, y = 0.5, z = 0 }

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

export type Level = {
	index: number,
	name: string,
	difficulty: number,
	remote: boolean,
	palette: { [string]: string },
	ELEMENTS: { Element },
	PATH: { Element },
	CHECKPOINTS: { Element },
	CHECKPOINT_COUNT: number,
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
	return { kind = "checkpoint", shape = "disc", index = index, x = x, y = y, z = z, r = r, color = color or "Coral", path = true }
end

-- Level 1, drawn with its start deck at x = -197, z = 0 (where it once began on the beach)
-- and moved out to sea by LEVEL1_OFFSET below. Path tops are warm (Sunny / Butter, Coral
-- checkpoints, Orange movers) so they pop against the sea.
local LEVEL1_ELEMENTS = {
	-- Start deck and two wide steps up.
	box(-197, 0.6, 0, 14, 14, "Sunny", "StartDeck"),
	box(-210, 2.4, 0, 9, 14, "Butter"),
	box(-221, 4.2, 0, 9, 14, "Sunny"),
	checkpoint(1, -234, 5, 0, 7),
	-- Stepping discs.
	disc(-247, 5, 4, 4.5, "Butter"),
	disc(-257, 5.5, -3, 4.5, "Sunny"),
	disc(-267, 6, 3, 4.5, "Butter"),
	disc(-277, 6.5, -2, 4.5, "Sunny"),
	checkpoint(2, -291, 7, 0, 7),
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
		sx = 8,
		sz = 8,
		color = "Orange",
		path = true,
		motion = "slide",
		axis = { 1, 0, 0 },
		distance = 2.8,
		period = 5,
		phase = 0,
	},
	checkpoint(4, -356, 8, 0, 7),
	-- Turn south: a deck with two slow sweeper bars to jump over.
	box(-356, 8, -21, 14, 24, "Sunny", "SweeperDeck"),
	{ kind = "spinner", x = -356, y = 8, z = -15, length = 12, speed = 1.2, phase = 0 },
	{ kind = "spinner", x = -356, y = 8, z = -27, length = 12, speed = -1, phase = math.pi / 2 },
	-- Bounce pad up to the high return lane.
	box(-356, 8, -39, 12, 8, "Butter", "BounceDeck"),
	{ kind = "bounce", x = -356, y = 8, z = -39.5, r = 2.5, power = 78 },
	checkpoint(5, -356, 17, -53, 7),
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
	checkpoint(6, -298, 17, -53, 7),
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
	checkpoint(7, -252, 15, -53, 7),
	-- The big slide down to the finish deck.
	box(-241, 15, -53, 6, 8, "Butter", "SlideTop"),
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

-- Theme.World colour keys per level.
Course.PALETTES = {
	{ main = "Sunny", alt = "Butter", checkpoint = "Coral", mover = "Orange", accent = "Teal", blink = "Pink" },
	{ main = "Mint", alt = "Butter", checkpoint = "Coral", mover = "Orange", accent = "Teal", blink = "Pink" },
	{ main = "Blue", alt = "Mint", checkpoint = "Sunny", mover = "Orange", accent = "Coral", blink = "Pink" },
	{ main = "Teal", alt = "Mint", checkpoint = "Sunny", mover = "Coral", accent = "Grape", blink = "Pink" },
	{ main = "Pink", alt = "Butter", checkpoint = "Mint", mover = "Blue", accent = "Grape", blink = "Sunny" },
	{ main = "Coral", alt = "Pink", checkpoint = "Sunny", mover = "Teal", accent = "Blue", blink = "Mint" },
	{ main = "Blue", alt = "TealLight", checkpoint = "Sunny", mover = "Coral", accent = "Grape", blink = "Pink" },
	{ main = "Grape", alt = "Blue", checkpoint = "Sunny", mover = "Mint", accent = "Coral", blink = "Pink" },
	{ main = "RedOrange", alt = "Orange", checkpoint = "Sunny", mover = "Grape", accent = "Blue", blink = "Mint" },
	{ main = "Grape", alt = "Pink", checkpoint = "Sunny", mover = "RedOrange", accent = "Teal", blink = "Mint" },
}

-- Centre (x, z) of each level's rectangle.
Course.CENTRES = {
	[1] = { -600, 480 },
	[2] = { 400, 0 },
	[3] = { 300, -400 },
	[4] = { -50, -410 },
	[5] = { -450, -210 },
	[6] = { -560, 110 },
	[7] = { -250, 610 },
	[8] = { 410, 560 },
	[9] = { 650, -250 },
	[10] = { 100, -710 },
}

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
		discR = lerp(4.5, 2.25, t),
		beamW = lerp(4, 1.6, t),
		padSize = lerp(9, 6, t),
		checkpointR = lerp(6, 4.5, t),
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

-- Edge-to-edge horizontal distance between element a at (ax, az) and b at (bx, bz).
function Course.edgeGap(a: Element, ax: number, az: number, b: Element, bx: number, bz: number): number
	local function half(e: Element): (number, number, number)
		if e.shape == "box" then
			return (e.sx :: number) / 2, (e.sz :: number) / 2, 0
		end
		return 0, 0, e.r or 0
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
			if gap < 0.6 or gap > Course.maxGap(pb[2] - pa[2], jumpHeight) then
				return false
			end
		end
	end
	return true
end

local function halfAlong(e: Element, alongX: boolean): number
	if e.shape == "box" then
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
-- Apex of a bounce launch, less the 3 studs from the pad to the feet landing height.
local BOUNCE_HEIGHT = BOUNCE_POWER * BOUNCE_POWER / (2 * Course.GRAVITY) - 3

local function finalize(level: Level)
	level.PATH, level.CHECKPOINTS = {}, {}
	for _, element in level.ELEMENTS do
		if element.path then
			table.insert(level.PATH, element)
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

-- Builds remote level n (2..LEVEL_COUNT) from TUNING[n]; same result on every call.
function Course.generate(n: number): Level
	local T = Course.TUNING[n]
	local pal = Course.PALETTES[n]
	local rand = rng(n * 7919 + 17)
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
	local sinceCp, cpIndex, bounced, afterBounce = 0, 0, false, false
	local plainPads = 0
	local weights: { { kind: string, weight: number } } = {
		{ kind = "pad", weight = 3 },
		{ kind = "disc", weight = 3 },
		{ kind = "beam", weight = 2 },
		{ kind = "slide", weight = 2 },
		{ kind = "bob", weight = if n >= 3 then 1 else 0 },
		{ kind = "spinner", weight = 1.5 },
		{ kind = "walls", weight = if n >= 3 then 1 else 0 },
		{ kind = "blink", weight = if T.blinkOn then (if n == 4 then 8 else 3) else 0 }, -- level 4 is Blink Reef
	}
	while count < T.pathLength do
		if turnLeft == 0 and (prev.x - laneStart) * dir >= LANE then
			turnLeft = 2
		end
		local turning = turnLeft > 0
		local kind
		if count == T.pathLength - 1 then
			kind = "finish"
		elseif sinceCp >= T.checkpointEvery - 1 then
			kind = "checkpoint"
		elseif turning then
			kind = "pad"
		elseif not bounced and count >= T.pathLength // 2 and not afterBounce then
			kind = "bounce"
		else
			-- No two moving/blinking pads in a row, none right after a bounce, and no
			-- sideways slider where the lane turns (it would slide into the turn pad).
			local calm = prev.kind == "mover" or prev.kind == "blink" or afterBounce or (prev.x - laneStart) * dir >= LANE - 24
			local total = 0
			for _, w in weights do
				if not (calm and (w.kind == "slide" or w.kind == "bob" or w.kind == "blink")) then
					total += w.weight
				end
			end
			local pick = rand() * total
			kind = "pad"
			for _, w in weights do
				if not (calm and (w.kind == "slide" or w.kind == "bob" or w.kind == "blink")) then
					pick -= w.weight
					if pick < 0 then
						kind = w.kind
						break
					end
				end
			end
			-- From level 4 every second plain pad blinks, so blink pads never run dry.
			if kind == "pad" and T.blinkOn and not calm then
				plainPads += 1
				if plainPads % 2 == 0 then
					kind = "blink"
				end
			end
		end
		local size = T.padSize
		local colour = if count % 2 == 0 then pal.main else pal.alt
		local e: Element
		local extras: { Element } = {}
		if kind == "finish" then
			e = box(0, 0, 0, 16, 14, pal.main, "FinishDeck")
		elseif kind == "checkpoint" then
			cpIndex += 1
			e = checkpoint(cpIndex, 0, 0, 0, T.checkpointR, pal.checkpoint)
		elseif kind == "disc" then
			e = disc(0, 0, 0, T.discR, colour)
		elseif kind == "beam" then
			e = box(0, 0, 0, 16, T.beamW, colour, "Beam")
		elseif kind == "slide" or kind == "bob" then
			local bob = kind == "bob"
			e = box(0, 0, 0, size - 1, size - 1, pal.mover)
			e.kind, e.name = "mover", nil
			e.motion = if bob then "bob" else "slide"
			e.axis = if bob then { 0, 1, 0 } else { 0, 0, 1 }
			e.distance = if bob then round2(T.moverTravel / 2) else T.moverTravel
			e.period = T.moverPeriod
			e.phase = round2(rand() * 2 * math.pi)
		elseif kind == "blink" then
			e = box(0, 0, 0, size, size, pal.blink)
			e.kind = "blink"
			e.on, e.period = T.blinkOn, T.blinkPeriod
			e.phase = round2(rand() * (T.blinkPeriod :: number))
		elseif kind == "spinner" then
			local bars = T.spinBars
			e = box(0, 0, 0, 8 + 9 * bars, 12, colour, "SweeperDeck")
			for k = 1, bars do
				local sign = if k % 2 == 0 then -1 else 1
				local bar = { kind = "spinner", x = (k - (bars + 1) / 2) * 9, y = 0, z = 0, length = 10 }
				bar.speed, bar.phase = sign * T.spinSpeed, round2(k * 1.3)
				table.insert(extras, bar :: Element)
			end
		elseif kind == "walls" then
			e = box(0, 0, 0, 20, size + 3, colour, "WallHopDeck")
			for k = -1, 1 do
				table.insert(extras, { kind = "wall", x = k * 6, y = 0, z = 0, sx = 1.2, sz = size + 3, h = 2.4, color = pal.accent })
			end
		elseif kind == "bounce" then
			bounced = true
			e = box(0, 0, 0, 8, size + 2, colour, "BounceDeck")
			table.insert(extras, { kind = "bounce", x = 0, y = 0, z = 0, r = 2.5, power = BOUNCE_POWER, color = pal.accent })
		else
			e = box(0, 0, 0, size, size, colour)
		end
		-- Height change and spacing: the widest gap up to the target that is fair at every
		-- phase; smaller steps if nothing fits.
		local alongX = not turning
		local jumpHeight = if afterBounce then BOUNCE_HEIGHT else nil
		local wantUp = if afterBounce then BOUNCE_RISE else (rand() * 2 - 1) * T.rise
		if prev.y + wantUp < Y_MIN then
			wantUp = -wantUp
		end
		wantUp = math.clamp(wantUp, Y_MIN - prev.y, Y_MAX - prev.y)
		local target = T.gap * (0.9 + 0.1 * rand())
		local jitter = if e.shape == "disc" and alongX then (rand() * 2 - 1) * 1.5 else 0
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
				if fits(prev, e, jumpHeight) then
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

	-- Move the layout onto its region and frame it.
	local x0, x1, z0, z1, top = math.huge, -math.huge, math.huge, -math.huge, 0
	for _, e in elements do
		local hx = (e.sx or 2 * (e.r or (e.length or 0) / 2)) / 2
		local hz = (e.sz or 2 * (e.r or (e.length or 0) / 2)) / 2
		if e.kind == "mover" and e.motion == "slide" then
			hz += e.distance :: number
		end
		x0, x1 = math.min(x0, e.x - hx), math.max(x1, e.x + hx)
		z0, z1 = math.min(z0, e.z - hz), math.max(z1, e.z + hz)
		top = math.max(top, e.y + (e.distance or 0))
	end
	local centre = Course.CENTRES[n]
	local ox, oz = round2(centre[1] - (x0 + x1) / 2), round2(centre[2] - (z0 + z1) / 2)
	for _, e in elements do
		e.x, e.z = e.x + ox, e.z + oz
	end
	x0, x1, z0, z1 = x0 + ox, x1 + ox, z0 + oz, z1 + oz
	local first, last = elements[1], prev
	local before: Element? = nil
	for i = #elements - 1, 1, -1 do
		if elements[i].path then
			before = elements[i]
			break
		end
	end
	local from = before :: Element
	local fx, fz = from.x - last.x, from.z - last.z
	local faceX, faceZ = if math.abs(fx) >= math.abs(fz) then math.sign(fx) else 0, if math.abs(fx) < math.abs(fz) then math.sign(fz) else 0
	local hx, hz = (last.sx :: number) / 2, (last.sz :: number) / 2
	local level: Level = {
		index = n,
		name = Course.NAMES[n],
		difficulty = n,
		remote = true,
		palette = pal,
		ELEMENTS = elements,
		PATH = {},
		CHECKPOINTS = {},
		CHECKPOINT_COUNT = 0,
		START = { x = first.x, y = first.y, z = first.z, faceX = 1, faceZ = 0 },
		FINISH = { x0 = last.x - hx, x1 = last.x + hx, z0 = last.z - hz, z1 = last.z + hz, y0 = last.y - 1, y1 = last.y + 10 },
		FINISH_ARCH = { x = last.x, y = last.y, z = last.z, faceX = faceX, faceZ = faceZ },
		WATER_BOX = { x0 = x0 - 4, x1 = x1 + 4, z0 = z0 - 4, z1 = z1 + 4, y0 = -1.2, y1 = Course.WATER_Y },
		BOUNDS = { x0 = x0 - 14, x1 = x1 + 14, z0 = z0 - 14, z1 = z1 + 14, y0 = -10, y1 = top + 40 },
		MIN_LEG_SECONDS = {},
		TUNING = T,
	}
	finalize(level)
	return level
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

-- Level 1 as drawn spans x -380..-186, z -74..16 (centre -283, -29); this moves it onto
-- CENTRES[1] and lifts every top 2 studs so the low decks sit clear of the water line.
local LEVEL1_OFFSET = { x = Course.CENTRES[1][1] + 283, y = 2, z = Course.CENTRES[1][2] + 29 }

local function shifted(b: Box): Box
	local o = LEVEL1_OFFSET
	return { x0 = b.x0 + o.x, x1 = b.x1 + o.x, z0 = b.z0 + o.z, z1 = b.z1 + o.z, y0 = b.y0, y1 = b.y1 }
end

for _, e in LEVEL1_ELEMENTS do
	e.x, e.y, e.z = e.x + LEVEL1_OFFSET.x, e.y + LEVEL1_OFFSET.y, e.z + LEVEL1_OFFSET.z
	for _, key in { "from", "to" } do
		local point = (e :: any)[key]
		if point then
			point[1], point[2], point[3] = point[1] + LEVEL1_OFFSET.x, point[2] + LEVEL1_OFFSET.y, point[3] + LEVEL1_OFFSET.z
		end
	end
end

local level1: Level = {
	index = 1,
	name = Course.NAMES[1],
	difficulty = 1,
	remote = true,
	palette = Course.PALETTES[1],
	ELEMENTS = LEVEL1_ELEMENTS,
	PATH = {},
	CHECKPOINTS = {},
	CHECKPOINT_COUNT = 0,
	-- The start deck, facing west.
	START = { x = -197 + LEVEL1_OFFSET.x, y = 0.6 + LEVEL1_OFFSET.y, z = LEVEL1_OFFSET.z, faceX = -1, faceZ = 0 },
	FINISH = shifted({ x0 = -210, x1 = -192, z0 = -60, z1 = -46, y0 = LEVEL1_OFFSET.y, y1 = 10 + LEVEL1_OFFSET.y }),
	-- The runner comes off the slide at the deck's west edge.
	FINISH_ARCH = { x = -204 + LEVEL1_OFFSET.x, y = 1.2 + LEVEL1_OFFSET.y, z = -53 + LEVEL1_OFFSET.z, faceX = -1, faceZ = 0 },
	WATER_BOX = shifted({ x0 = -382, x1 = -218, z0 = -76, z1 = 18, y0 = -1.2, y1 = Course.WATER_Y }),
	BOUNDS = shifted({ x0 = -380, x1 = -186, z0 = -74, z1 = 16, y0 = -10, y1 = 80 }),
	MIN_LEG_SECONDS = {},
	TUNING = nil,
}
finalize(level1)

Course.LEVELS = { level1 } :: { Level }
for n = 2, Course.LEVEL_COUNT do
	Course.LEVELS[n] = Course.generate(n)
end
-- Each level's rectangle (its BOUNDS).
Course.REGIONS = {} :: { Box }
for i, level in Course.LEVELS do
	Course.REGIONS[i] = level.BOUNDS
end

function Course.level(i: number): Level
	return Course.LEVELS[math.clamp(math.floor(i), 1, Course.LEVEL_COUNT)]
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
	local r = (cp.r :: number) + 0.5
	return (x - cp.x) ^ 2 + (z - cp.z) ^ 2 <= r * r and y >= cp.y - 1 and y <= cp.y + 6
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

function Course.inWater(x: number, y: number, z: number): boolean
	return y < Course.WATER_Y and x * x + z * z > Course.WATER_RADIUS * Course.WATER_RADIUS
end

-- Did a player's feet cross the start line westward inside gate 1's opening?
function Course.crossedStart(prevX: number, x: number, z: number): boolean
	return prevX > Course.START_LINE_X and x <= Course.START_LINE_X and math.abs(z - Course.GATES[1].z) <= Course.GATE_HALF + 1
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

-- Beach props the hub must not place here (palms, beach balls): the plaza, its spur and the
-- big sign behind the gates.
Course.CLEAR = {
	{ x0 = -210, x1 = -138, z0 = -36, z1 = 36 },
}

return Course
