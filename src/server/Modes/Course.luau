--!strict
--[[
	Course: pure layout data for the GAME MODES plaza and the Parkour course.

	No Roblox types: World.Modes builds parts from these numbers, Modes.Parkour polls player
	positions against them and the unit tests check that every jump is fair. All positions
	are world coordinates; a platform's `y` is its TOP surface.

	The plaza sits on the -X side of the hub, between the two plot rows: a boardwalk spur
	leaves the hub ring's -X side at z = 0 and ends on a square wooden deck with the three
	mode gates in a row on its west edge, under one big GAME MODES sign. Gate 1 is the
	Parkour start: the course runs west out over the sea along z = 0, turns south at its far
	end, comes back east along z = -53 and slides down to the finish deck on the beach.

	Course element kinds (`path = true` elements are walked on, in this order):
	  pad         static platform ("box": sx x sz, "disc": radius r)
	  checkpoint  static disc, numbered `index` 1..n in course order
	  mover       platform that moves (motion "slide" along `axis` or "bob" up/down) by
	              +-`distance` studs, one full cycle every `period` seconds, offset `phase`
	  slide       straight ramp from `from` to `to` (top surface), `width` wide
	  spinner     obstacle (not a path element): a bar `length` long turning about the
	              vertical axis at `speed` rad/s above the deck top `y`
	  wall        obstacle: a low wall `h` tall to hop over (sx thick along X, sz wide)
	  bounce      bounce pad of radius `r` on a deck: launches the player up at `power`
	              studs/s (the next path element may be higher than a normal jump)
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

-- Walking west across this line inside gate 1's opening starts a run.
Course.START_LINE_X = Course.GATE_X
-- Where a run (re)starts and checkpoint 0 respawns: the start deck, facing west.
Course.START = { x = -197, y = 0.6, z = 0, faceX = -1, faceZ = 0 }

-- The finish deck region (player feet inside it ends the run).
Course.FINISH = { x0 = -210, x1 = -192, z0 = -60, z1 = -46, y0 = 0, y1 = 10 }
Course.FINISH_ARCH_X = -204

-- Falling in: feet below WATER_Y beyond the island's shore (horizontal distance from the
-- world origin greater than WATER_RADIUS) sends a running player back to their checkpoint.
Course.WATER_Y = 1.5
Course.WATER_RADIUS = 219
-- The catch volume part ("ParkourWater") the client may use for splash effects.
Course.WATER_BOX = { x0 = -382, x1 = -218, z0 = -76, z1 = 18, y0 = -1.2, y1 = 1.5 }

-- A run stops (reason "left") when the player stays outside this box for LEAVE_SECONDS.
Course.BOUNDS = { x0 = -380, x1 = -186, z0 = -74, z1 = 16, y0 = -10, y1 = 80 }
Course.LEAVE_SECONDS = 2.5

-- Beach props the hub must not place here (palms, beach balls).
Course.CLEAR = {
	{ x0 = -222, x1 = -138, z0 = -36, z1 = 36 },
	{ x0 = -226, x1 = -186, z0 = -64, z1 = -40 },
}

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
	length: number?,
	speed: number?,
	h: number?,
	power: number?,
	from: { number }?,
	to: { number }?,
	width: number?,
	name: string?,
}

local function box(x: number, y: number, z: number, sx: number, sz: number, color: string, name: string?): Element
	return { kind = "pad", shape = "box", x = x, y = y, z = z, sx = sx, sz = sz, color = color, path = true, name = name }
end

local function disc(x: number, y: number, z: number, r: number, color: string): Element
	return { kind = "pad", shape = "disc", x = x, y = y, z = z, r = r, color = color, path = true }
end

local function checkpoint(index: number, x: number, y: number, z: number, r: number): Element
	return { kind = "checkpoint", shape = "disc", index = index, x = x, y = y, z = z, r = r, color = "Coral", path = true }
end

Course.ELEMENTS = {
	-- Start deck and two wide steps up off the beach. Path tops are warm (Sunny / Butter,
	-- Coral checkpoints, Orange movers) so they pop against the sea.
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
		distance = 3,
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
	-- The big slide down to the finish deck on the beach.
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

-- Path elements in order (what a player walks on), and each checkpoint by index.
Course.CHECKPOINTS = {} :: { Element }
Course.PATH = {} :: { Element }
for _, element in Course.ELEMENTS do
	if element.path then
		table.insert(Course.PATH, element)
	end
	if element.kind == "checkpoint" then
		Course.CHECKPOINTS[element.index :: number] = element
	end
end
Course.CHECKPOINT_COUNT = #Course.CHECKPOINTS

-- Jump limits the course is designed for (default character: JumpHeight 7.2, WalkSpeed 16,
-- Workspace.Gravity 196.2): edge-to-edge gaps and step-ups, conservative for phones.
Course.MAX_GAP = 9
Course.MAX_STEP_UP = 5

-- Integrity: nobody moves along the course faster than this (studs/s, about twice a
-- Speedy Sneakers run), so each checkpoint-to-checkpoint leg has a minimum time.
Course.MAX_PLAUSIBLE_SPEED = 40

-- Horizontal distance along the centres of consecutive path elements from checkpoint
-- `fromIndex` (0 = start deck) to checkpoint `toIndex` (CHECKPOINT_COUNT + 1 = finish deck).
function Course.legLength(fromIndex: number, toIndex: number): number
	local first: number? = if fromIndex == 0 then 1 else nil
	local last: number? = if toIndex > Course.CHECKPOINT_COUNT then #Course.PATH else nil
	for i, element in Course.PATH do
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
		local a, b = Course.PATH[i], Course.PATH[i + 1]
		total += math.sqrt((a.x - b.x) ^ 2 + (a.z - b.z) ^ 2)
	end
	return total
end

-- Minimum believable seconds for each leg: leg k runs from checkpoint k - 1 to checkpoint
-- k (leg CHECKPOINT_COUNT + 1 ends at the finish).
Course.MIN_LEG_SECONDS = {} :: { number }
for k = 1, Course.CHECKPOINT_COUNT + 1 do
	Course.MIN_LEG_SECONDS[k] = Course.legLength(k - 1, k) / Course.MAX_PLAUSIBLE_SPEED
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

function Course.inFinish(x: number, y: number, z: number): boolean
	local f = Course.FINISH
	return x >= f.x0 and x <= f.x1 and z >= f.z0 and z <= f.z1 and y >= f.y0 and y <= f.y1
end

function Course.inBounds(x: number, y: number, z: number): boolean
	local b = Course.BOUNDS
	return x >= b.x0 and x <= b.x1 and z >= b.z0 and z <= b.z1 and y >= b.y0 and y <= b.y1
end

function Course.inWater(x: number, y: number, z: number): boolean
	return y < Course.WATER_Y and x * x + z * z > Course.WATER_RADIUS * Course.WATER_RADIUS
end

-- Did a player's feet cross the start line westward inside gate 1's opening?
function Course.crossedStart(prevX: number, x: number, z: number): boolean
	return prevX > Course.START_LINE_X and x <= Course.START_LINE_X and math.abs(z - Course.GATES[1].z) <= Course.GATE_HALF + 1
end

-- Respawn spot for checkpoint `index` (0 = start deck): feet position { x, y, z } and the
-- horizontal direction { dx, dz } toward the next path element.
function Course.respawn(index: number): ({ number }, { number })
	local here: Element? = Course.CHECKPOINTS[index]
	local at = if here then { here.x, here.y, here.z } else { Course.START.x, Course.START.y, Course.START.z }
	local nextElement: Element? = nil
	for i, element in Course.PATH do
		if (here and element == here) or (not here and i == 1) then
			nextElement = Course.PATH[i + 1]
			break
		end
	end
	if not nextElement then
		return at, { Course.START.faceX, Course.START.faceZ }
	end
	local dx, dz = nextElement.x - at[1], nextElement.z - at[3]
	local length = math.max(1e-6, math.sqrt(dx * dx + dz * dz))
	return at, { dx / length, dz / length }
end

return Course
