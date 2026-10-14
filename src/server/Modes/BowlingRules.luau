--!strict
--[[
	BowlingRules: the pure rules of DUMBBELL BOWL (Modes.Bowling; docs/minigames.md). No Roblox
	services: tests/bowling.luau loads it with Lune.

	A game is FRAMES frames of up to two balls at PINS pins; the last frame gives one bonus
	ball after a spare and two after a strike (classic scoring, so the most is 30 per frame:
	MAX_SCORE). A game passes at PASS_SCORE or more.

	Lane space: every distance is in studs on the lane, `x` across it (+ is the bowler's right,
	world +X) and `d` down it from the foul line (world -Z). LANE holds the lane's measures,
	PIN_SPOTS the classic triangle (head pin first) and World.BowlingLane builds from both.

	roll(standing, aim, power, seed) plays one ball in pure code, no Roblox physics: the
	dumbbell runs straight from the bowler toward `aim` (-1 left .. 1 right at the head pin),
	drops into a gutter past GUTTER_X, flattens every standing pin within HIT of its line and
	each falling pin may topple the standing pins in its way (a chance that grows with
	`power`, drawn from a seeded RNG so the server and the tests agree). The result carries
	the path keypoints and each fallen pin's time and direction; the client only animates it.

	ARENA is where World.BowlingLane builds the arena (floor top centre and size in studs,
	out over the sea away from the Parkour maps, the Mog stage and the Cardio track; tests/
	minigames.luau keeps every arena clear of the others).
]]

local BowlingRules = {}

BowlingRules.ARENA = { x = 740, y = 6, z = -380, sizeX = 30, sizeZ = 110 }
-- Feet more than this far under the floor top: the player fell off and goes back to the spawn.
BowlingRules.FALL_BELOW = 20

BowlingRules.FRAMES = 5
BowlingRules.PINS = 10
BowlingRules.MAX_SCORE = 30 * BowlingRules.FRAMES
-- A game at or over this passes (tuned so a kid passes in about 1-3 games; tests/bowling.luau
-- plays a sloppy bowler to check it).
BowlingRules.PASS_SCORE = 50

-- The lane (studs): the slab's width and length from the foul line, each gutter's width,
-- the head pin's distance and the triangle's spacing across (pinGap) and between rows.
BowlingRules.LANE = {
	width = 14,
	length = 86,
	gutter = 2,
	headD = 72,
	pinGap = 3,
	rowGap = 2.6,
	-- From the arena's +Z edge to the foul line.
	foulFromEdge = 14,
}
-- The dumbbell: plate radius (it rolls on its plates) and half its length across the lane.
BowlingRules.BALL = { radius = 1.5, halfLength = 1.9 }
-- A pin's radius at its belly and its height (the client builds to these).
BowlingRules.PIN = { radius = 0.6, height = 3.2 }

-- Aim 1 points the dumbbell this far right of the head pin (at the head pin's distance).
BowlingRules.AIM_SPREAD = 7.5
-- The dumbbell's speed in studs per second at power 0 and at power 1.
BowlingRules.SPEED = { min = 30, max = 58 }
-- Past this |x| the dumbbell drops into the gutter (and hits nothing more).
BowlingRules.GUTTER_X = BowlingRules.LANE.width / 2 - 0.5
-- The path ends this far past the lane's end (in the pit behind the pins).
BowlingRules.PIT = 3
-- A standing pin whose centre is within HIT of the dumbbell's line is struck.
BowlingRules.HIT = BowlingRules.BALL.halfLength + BowlingRules.PIN.radius
-- How a struck pin flies: SIDE turns it away from the dumbbell's line by how far off centre
-- it was hit (0 dead on, 1 at the edge), JITTER is the random wobble on its direction.
BowlingRules.SIDE = 1.6
BowlingRules.JITTER = 0.35
-- A falling pin sweeps REACH studs along its direction; a standing pin within KNOCK_R of
-- that sweep goes over with chance KNOCK_BASE + KNOCK_POWER * power (less off its edge).
BowlingRules.REACH = 3.4
BowlingRules.KNOCK_R = 1.4
BowlingRules.KNOCK_BASE = 0.5
BowlingRules.KNOCK_POWER = 0.45
-- Seconds from a pin starting to fall to it reaching the next one, per stud of distance.
BowlingRules.CHAIN_DELAY = 0.08
BowlingRules.CHAIN_PER_STUD = 0.05

export type Spot = { x: number, d: number }
export type Point = { x: number, d: number, t: number }
export type Fall = { pin: number, t: number, dx: number, dd: number, struck: boolean }
export type Roll = {
	aim: number,
	power: number,
	speed: number,
	path: { Point },
	gutter: boolean,
	falls: { Fall },
	knocked: number,
	duration: number,
}
export type Game = {
	frames: { { number } },
	frame: number,
	standing: { boolean },
	over: boolean,
}
export type CardFrame = { marks: { string }, total: number? }

-- The ten pin spots in lane space: rows of 1-4 from the head pin, head pin first.
local function pinSpots(): { Spot }
	local lane = BowlingRules.LANE
	local spots: { Spot } = {}
	for row = 0, 3 do
		for i = 0, row do
			table.insert(spots, { x = (i - row / 2) * lane.pinGap, d = lane.headD + row * lane.rowGap })
		end
	end
	return spots
end
BowlingRules.PIN_SPOTS = pinSpots()

local function clamp(value: any, low: number, high: number, default: number): number
	if type(value) ~= "number" or value ~= value then
		return default
	end
	return math.clamp(value, low, high)
end
BowlingRules.clamp = clamp

-- A seeded random source in [0, 1) (Park-Miller; products stay exact in doubles).
function BowlingRules.rng(seed: number): () -> number
	local state = math.floor(math.abs(seed)) % 2147483646 + 1
	return function()
		state = (state * 48271) % 2147483647
		return (state - 1) / 2147483646
	end
end

local function unit(x: number, d: number): (number, number)
	local len = math.sqrt(x * x + d * d)
	if len < 1e-6 then
		return 0, 1
	end
	return x / len, d / len
end

-- One ball at the `standing` pins (true = up). aim in -1..1, power in 0..1 (both clamped).
function BowlingRules.roll(standing: { boolean }, aim: number, power: number, seed: number): Roll
	aim = clamp(aim, -1, 1, 0)
	power = clamp(power, 0, 1, 0.5)
	local lane = BowlingRules.LANE
	local rand = BowlingRules.rng(seed)
	local speed = BowlingRules.SPEED.min + (BowlingRules.SPEED.max - BowlingRules.SPEED.min) * power
	local slope = aim * BowlingRules.AIM_SPREAD / lane.headD -- x per stud of d
	local stretch = math.sqrt(1 + slope * slope) -- path length per stud of d
	local endD = lane.length + BowlingRules.PIT

	-- The path: straight on, or into a gutter where it crosses GUTTER_X.
	local gutterD: number? = nil
	if math.abs(slope) > 1e-6 then
		local d = BowlingRules.GUTTER_X / math.abs(slope)
		if d < lane.length then
			gutterD = d
		end
	end
	local path: { Point } = { { x = 0, d = 0, t = 0 } }
	if gutterD then
		local side = if slope > 0 then 1 else -1
		local gx = side * (lane.width / 2 + lane.gutter / 2)
		local edgeT = gutterD * stretch / speed
		table.insert(path, { x = slope * gutterD, d = gutterD, t = edgeT })
		local dropD = gutterD + 2
		local dropT = edgeT + math.sqrt(4 + (gx - slope * gutterD) ^ 2) / speed
		table.insert(path, { x = gx, d = dropD, t = dropT })
		-- A gutter ball runs a little slower (it scrapes along the channel).
		table.insert(path, { x = gx, d = endD, t = dropT + (endD - dropD) / (speed * 0.85) })
	else
		table.insert(path, { x = slope * endD, d = endD, t = endD * stretch / speed })
	end

	-- Struck pins: within HIT of the line before the dumbbell leaves the lane.
	local spots = BowlingRules.PIN_SPOTS
	local down: { [number]: boolean } = {}
	local falls: { Fall } = {}
	local reachD = gutterD or math.huge
	for i, spot in spots do
		if standing[i] and spot.d < reachD then
			local off = spot.x - slope * spot.d
			if math.abs(off) < BowlingRules.HIT then
				local side = off / BowlingRules.HIT
				local dx, dd = unit(slope + side * BowlingRules.SIDE + (rand() - 0.5) * BowlingRules.JITTER, 1)
				local t = math.max(spot.d - BowlingRules.BALL.radius, 0) * stretch / speed
				down[i] = true
				table.insert(falls, { pin = i, t = t, dx = dx, dd = dd, struck = true })
			end
		end
	end

	-- Chain: the earliest falling pin not yet spread topples the standing pins in its sweep.
	local chance = BowlingRules.KNOCK_BASE + BowlingRules.KNOCK_POWER * power
	local spread: { [number]: boolean } = {}
	while true do
		local nextFall: Fall? = nil
		for _, fall in falls do
			if not spread[fall.pin] and (not nextFall or fall.t < nextFall.t) then
				nextFall = fall
			end
		end
		if not nextFall then
			break
		end
		local f = nextFall :: Fall
		spread[f.pin] = true
		local from = spots[f.pin]
		for j, spot in spots do
			if standing[j] and not down[j] then
				local vx, vd = spot.x - from.x, spot.d - from.d
				local along = vx * f.dx + vd * f.dd
				local across = math.abs(vx * f.dd - vd * f.dx)
				if along > 0 and along < BowlingRules.REACH and across < BowlingRules.KNOCK_R then
					local p = chance * (1 - 0.4 * across / BowlingRules.KNOCK_R)
					if rand() < p then
						local ux, ud = unit(vx, vd)
						local dx, dd = unit(ux + f.dx + (rand() - 0.5) * BowlingRules.JITTER, ud + f.dd)
						down[j] = true
						table.insert(falls, {
							pin = j,
							t = f.t + BowlingRules.CHAIN_DELAY + along * BowlingRules.CHAIN_PER_STUD,
							dx = dx,
							dd = dd,
							struck = false,
						})
					end
				end
			end
		end
	end
	table.sort(falls, function(a, b)
		return a.t < b.t
	end)
	local last = path[#path].t
	for _, fall in falls do
		last = math.max(last, fall.t)
	end
	return {
		aim = aim,
		power = power,
		speed = speed,
		path = path,
		gutter = gutterD ~= nil,
		falls = falls,
		knocked = #falls,
		duration = last,
	}
end

-- Game and score ---------------------------------------------------------------------------

function BowlingRules.allStanding(): { boolean }
	local list = {}
	for i = 1, BowlingRules.PINS do
		list[i] = true
	end
	return list
end

function BowlingRules.newGame(): Game
	local frames = {}
	for i = 1, BowlingRules.FRAMES do
		frames[i] = {}
	end
	return { frames = frames, frame = 1, standing = BowlingRules.allStanding(), over = false }
end

-- Books a ball that knocked the pins in `fallen` (pin indices): updates the frame, the
-- standing pins and the game's end. Returns the ball's mark ("strike", "spare", "gutter" for
-- none, or nil) and whether the pins are reset for the next ball.
function BowlingRules.applyRoll(game: Game, fallen: { number }): (string?, boolean)
	if game.over then
		return nil, false
	end
	local before = 0
	for _, up in game.standing do
		if up then
			before += 1
		end
	end
	for _, pin in fallen do
		game.standing[pin] = false
	end
	local n = 0
	for _, up in game.standing do
		if up then
			n += 1
		end
	end
	n = before - n
	local f = game.frames[game.frame]
	table.insert(f, n)
	local full = before == BowlingRules.PINS -- this ball faced a full rack
	local cleared = n == before
	local mark: string? = if cleared and full then "strike" elseif cleared then "spare" elseif n == 0 then "gutter" else nil
	local reset = false
	local lastFrame = game.frame == BowlingRules.FRAMES
	if not lastFrame then
		if cleared or #f >= 2 then
			game.frame += 1
			reset = true
		end
	else
		-- The last frame: a strike or a spare earns bonus balls (three balls at most).
		local bonus = f[1] == BowlingRules.PINS or (#f >= 2 and f[1] + f[2] == BowlingRules.PINS)
		if #f >= 3 or (#f == 2 and not bonus) then
			game.over = true
		elseif cleared then
			reset = true
		end
	end
	if reset then
		game.standing = BowlingRules.allStanding()
	end
	return mark, reset
end

-- The scorecard: each frame's marks ("X", "/", "-", digits) and its running total once its
-- bonus balls are known; plus the total so far (the last known running total).
function BowlingRules.card(frames: { { number } }): ({ CardFrame }, number)
	local rolls: { number } = {}
	local starts: { number } = {}
	for i, f in frames do
		starts[i] = #rolls + 1
		for _, n in f do
			table.insert(rolls, n)
		end
	end
	local out: { CardFrame } = {}
	local running = 0
	local known = true
	for i, f in frames do
		local marks: { string } = {}
		local lastFrame = i == #frames
		local standing = BowlingRules.PINS
		for b, n in f do
			if n == standing and (lastFrame or b == 1) and standing == BowlingRules.PINS then
				table.insert(marks, "X")
			elseif n == standing and b > 1 then
				table.insert(marks, "/")
			elseif n == 0 then
				table.insert(marks, "-")
			else
				table.insert(marks, tostring(n))
			end
			standing -= n
			if standing <= 0 then
				standing = BowlingRules.PINS
			end
		end
		local total: number? = nil
		if known and #f > 0 then
			local s = starts[i]
			local frameScore: number? = nil
			if lastFrame then
				local bonus = f[1] == BowlingRules.PINS or (#f >= 2 and f[1] + f[2] == BowlingRules.PINS)
				if #f == 3 or (#f == 2 and not bonus) then
					frameScore = f[1] + f[2] + (f[3] or 0)
				end
			elseif f[1] == BowlingRules.PINS then
				if rolls[s + 1] and rolls[s + 2] then
					frameScore = 10 + rolls[s + 1] + rolls[s + 2]
				end
			elseif #f >= 2 then
				if f[1] + f[2] == BowlingRules.PINS then
					if rolls[s + 2] then
						frameScore = 10 + rolls[s + 2]
					end
				else
					frameScore = f[1] + f[2]
				end
			end
			if frameScore then
				running += frameScore
				total = running
			else
				known = false
			end
		else
			known = false
		end
		out[i] = { marks = marks, total = total }
	end
	return out, running
end

-- The final score of a finished game (or the known running total of one in play).
function BowlingRules.score(frames: { { number } }): number
	local _, total = BowlingRules.card(frames)
	return total
end

function BowlingRules.passed(score: number): boolean
	return score >= BowlingRules.PASS_SCORE
end

return BowlingRules
