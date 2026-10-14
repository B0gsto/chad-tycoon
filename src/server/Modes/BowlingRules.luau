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
	dumbbell runs from the bowler toward `aim` (-1 left .. 1 right at the head pin), drops
	into a gutter past GUTTER_X, flattens every standing pin within HIT of its line and each
	falling pin may topple the standing pins in its way (drawn from a seeded RNG so the server
	and the tests agree). The result carries the path keypoints and each fallen pin's time and
	direction; the client only animates it.

	Power is a choice, not "more is better" (POWER): under the sweet spot the dumbbell is soft
	(fewer chain falls); in the sweet spot (POWER.sweetLo..sweetHi) it carries best; over it
	the dumbbell goes wild and hooks off its line, up to HOOK studs at the head pin at full
	power, to a random side. powerZone(power) names the zone for the HUD.

	ARENA is where World.BowlingLane builds the arena (floor top centre and size in studs,
	out over the sea away from the Parkour maps, the Mog stage and the Cardio track; tests/
	minigames.luau keeps every arena clear of the others).
]]

local BowlingRules = {}

-- 54 wide: the lane in the middle, a decorative neighbouring lane on the left, bleachers
-- and a scoreboard on the right (World.BowlingLane). 150 long: the lobby lounge takes the
-- 40 studs at the +Z end, behind the lane's approach.
BowlingRules.ARENA = { x = -7000, y = 6, z = -7000, sizeX = 54, sizeZ = 150 }
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
-- However far off centre a pin is struck, it flies at most SPLAY studs sideways per stud
-- forward (about 39 degrees): an edge hit sends it into its neighbour, not across the rack
-- past it (an uncapped splay left the 7 and 10 pins up just right of centre: a dead zone
-- inside the praised aim).
BowlingRules.SPLAY = 0.8
-- A falling pin sweeps REACH studs along its direction; a standing pin within KNOCK_R of
-- that sweep goes over with chance (KNOCK_BASE + KNOCK_POWER * drive(power)) * carry(entry)
-- (less off its edge).
BowlingRules.REACH = 3.4
BowlingRules.KNOCK_R = 1.4
BowlingRules.KNOCK_BASE = 0.42
BowlingRules.KNOCK_POWER = 0.53
-- THE POCKET. |aim| <= POCKET is the praised aim (the HUD's gold band and "PERFECT AIM!"
-- come from this number, sent in "start"): the dumbbell meets the head pin within
-- POCKET * AIM_SPREAD studs of square and drives through the rack. Past that a thinner hit
-- deflects the dumbbell and the rack carries less: carry(entry) falls by CARRY_FALL per stud
-- of `entry` (the line's x at the head pin) beyond the pocket, down to CARRY_MIN.
-- tests/bowling.luau plays fixed aims to check the pocket really is the best region.
BowlingRules.POCKET = 0.12
BowlingRules.CARRY_FALL = 0.35
BowlingRules.CARRY_MIN = 0.3

-- How well the rack carries (0..1) for a line `entry` studs across at the head pin.
function BowlingRules.carry(entry: number): number
	local off = math.abs(entry) - BowlingRules.POCKET * BowlingRules.AIM_SPREAD
	if off <= 0 then
		return 1
	end
	return math.max(BowlingRules.CARRY_MIN, 1 - off * BowlingRules.CARRY_FALL)
end

-- Whether an aim is in the pocket (the HUD's "PERFECT AIM!").
function BowlingRules.inPocket(aim: number): boolean
	return math.abs(aim) <= BowlingRules.POCKET
end

-- The power meter's zones: under sweetLo the dumbbell is soft, sweetLo..sweetHi is the sweet
-- spot, over sweetHi it goes wild (hooks off its line: HOOK studs at the head pin at power 1).
BowlingRules.POWER = { sweetLo = 0.72, sweetHi = 0.9 }
BowlingRules.HOOK = 3.5
-- A hooking path is sampled every HOOK_STEP studs down the lane.
BowlingRules.HOOK_STEP = 6

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
	-- Studs the line bends at the head pin (0 unless over-powered; + is right).
	hook: number,
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

-- "soft" | "sweet" | "wild": where `power` (0..1) sits on the meter.
function BowlingRules.powerZone(power: number): string
	local p = BowlingRules.POWER
	if power < p.sweetLo then
		return "soft"
	elseif power <= p.sweetHi then
		return "sweet"
	end
	return "wild"
end

-- How hard the dumbbell carries through the pins (0..1): it grows up to the sweet spot.
function BowlingRules.drive(power: number): number
	return math.clamp(power / BowlingRules.POWER.sweetLo, 0, 1)
end

-- How wild an over-powered ball goes (0 up to the sweet spot's top, 1 at full power).
function BowlingRules.wildness(power: number): number
	local hi = BowlingRules.POWER.sweetHi
	return math.clamp((power - hi) / (1 - hi), 0, 1)
end

-- A seeded random source in [0, 1) (Park-Miller; products stay exact in doubles). The seed
-- is scrambled first (xorshift rounds): straight Park-Miller from a small seed starts right
-- next to 0 and neighbouring seeds start almost alike, which tilted the first pin's wobble
-- and made the first chain check a sure thing.
function BowlingRules.rng(seed: number): () -> number
	local x = bit32.band(math.floor(math.abs(seed)) % 4294967296, 0xFFFFFFFF)
	for _ = 1, 3 do
		x = bit32.bxor(x, bit32.lshift(x, 13))
		x = bit32.bxor(x, bit32.rshift(x, 17))
		x = bit32.bxor(x, bit32.lshift(x, 5))
		x = bit32.bxor(x, 0x9E3779B9)
	end
	local state = x % 2147483646 + 1
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
	local endD = lane.length + BowlingRules.PIT

	-- Over the sweet spot the dumbbell hooks off its line to a random side: `hook` studs at
	-- the head pin, growing with the square of the distance.
	local hook = 0
	local wild = BowlingRules.wildness(power)
	if wild > 0 then
		local side = if rand() < 0.5 then -1 else 1
		hook = side * wild * BowlingRules.HOOK * (0.6 + 0.4 * rand())
	end
	local function xAt(d: number): number
		return slope * d + hook * (d / lane.headD) ^ 2
	end
	local function slopeAt(d: number): number
		return slope + 2 * hook * d / (lane.headD * lane.headD)
	end

	-- Where the line first crosses GUTTER_X on the lane (nil: it stays on).
	local gutterD: number? = nil
	do
		local prev, d = 0, 0.5
		while d <= lane.length do
			if math.abs(xAt(d)) > BowlingRules.GUTTER_X then
				local lo, hi = prev, d
				for _ = 1, 24 do
					local mid = (lo + hi) / 2
					if math.abs(xAt(mid)) > BowlingRules.GUTTER_X then
						hi = mid
					else
						lo = mid
					end
				end
				gutterD = hi
				break
			end
			prev = d
			d += 0.5
		end
	end

	-- The path: keypoints along the line (straight: just its ends; a hook every HOOK_STEP),
	-- then into a gutter where it crosses GUTTER_X.
	local path: { Point } = { { x = 0, d = 0, t = 0 } }
	local lineEnd = gutterD or endD
	local stepD = if hook ~= 0 then BowlingRules.HOOK_STEP else lineEnd
	local d = 0
	while d < lineEnd - 1e-6 do
		d = math.min(d + stepD, lineEnd)
		local last = path[#path]
		local x = xAt(d)
		local len = math.sqrt((x - last.x) ^ 2 + (d - last.d) ^ 2)
		table.insert(path, { x = x, d = d, t = last.t + len / speed })
	end
	if gutterD then
		local edge = path[#path]
		local side = if edge.x > 0 then 1 else -1
		local gx = side * (lane.width / 2 + lane.gutter / 2)
		local dropD = gutterD + 2
		local dropT = edge.t + math.sqrt(4 + (gx - edge.x) ^ 2) / speed
		table.insert(path, { x = gx, d = dropD, t = dropT })
		-- A gutter ball runs a little slower (it scrapes along the channel).
		table.insert(path, { x = gx, d = endD, t = dropT + (endD - dropD) / (speed * 0.85) })
	end

	-- When the dumbbell is `d` studs down the lane (on the line, before any gutter).
	local function timeAt(target: number): number
		for i = 2, #path do
			local a, b = path[i - 1], path[i]
			if target <= b.d or i == #path then
				local f = if b.d > a.d then math.clamp((target - a.d) / (b.d - a.d), 0, 1) else 1
				return a.t + (b.t - a.t) * f
			end
		end
		return 0
	end

	-- Struck pins: within HIT of the line before the dumbbell leaves the lane.
	local spots = BowlingRules.PIN_SPOTS
	local down: { [number]: boolean } = {}
	local falls: { Fall } = {}
	local reachD = gutterD or math.huge
	for i, spot in spots do
		if standing[i] and spot.d < reachD then
			local off = spot.x - xAt(spot.d)
			if math.abs(off) < BowlingRules.HIT then
				local side = off / BowlingRules.HIT
				local splay = math.clamp(side * BowlingRules.SIDE, -BowlingRules.SPLAY, BowlingRules.SPLAY)
				local dx, dd = unit(slopeAt(spot.d) + splay + (rand() - 0.5) * BowlingRules.JITTER, 1)
				local t = timeAt(math.max(spot.d - BowlingRules.BALL.radius, 0))
				down[i] = true
				table.insert(falls, { pin = i, t = t, dx = dx, dd = dd, struck = true })
			end
		end
	end

	-- Chain: the earliest falling pin not yet spread topples the standing pins in its sweep.
	local chance = (BowlingRules.KNOCK_BASE + BowlingRules.KNOCK_POWER * BowlingRules.drive(power)) * BowlingRules.carry(xAt(lane.headD))
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
		hook = hook,
		path = path,
		gutter = gutterD ~= nil,
		falls = falls,
		knocked = #falls,
		duration = last,
	}
end

-- The bowler on screen ---------------------------------------------------------------------
--
-- Fx.Bowling has the player's own avatar bowl each ball: approach steps, backswing and the
-- release take WINDUP seconds from the "roll" event (the path's times start at the release),
-- then the pins fall and the avatar reacts. Modes.Bowling waits WINDUP + the roll's duration
-- + settle(mark) before the next "ready".

BowlingRules.WINDUP = 0.9
-- Seconds after the last pin falls (or the dumbbell reaches the pit) for the pins to settle
-- and the bowler's reaction: a strike's celebration is the longest. Kept short so a game
-- moves; a tap skips the rest of it anyway (skipAt).
BowlingRules.SETTLE = { strike = 2.4, spare = 1.9, gutter = 1.7, open = 1.6 }
-- "BowlingSkip" ends the settle early, but only this many seconds after the bowler's
-- reaction starts (reactAt), so the pins and the reaction have been seen (skipAt): the
-- whole of a strike's leap, roar and flex (Fx.Bowling's reaction, ~1.6 s), about a second
-- of the others.
BowlingRules.SKIP_AFTER = { strike = 1.6, other = 1.0 }

-- Seconds after the reaction starts before a skip is taken, for a ball marked `mark`.
function BowlingRules.skipAfter(mark: string?): number
	local s = BowlingRules.SKIP_AFTER
	return if mark == "strike" then s.strike else s.other
end

function BowlingRules.settle(mark: string?): number
	local s = BowlingRules.SETTLE
	return if mark == "strike" then s.strike elseif mark == "spare" then s.spare elseif mark == "gutter" then s.gutter else s.open
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
		-- A fresh rack: the frame's first ball, or (last frame only) a ball after a clear.
		-- All ten off a fresh rack is a strike; clearing what was left is a spare.
		local fresh = true
		for _, n in f do
			if fresh and n == BowlingRules.PINS then
				table.insert(marks, "X")
			elseif not fresh and n == standing then
				table.insert(marks, "/")
			elseif n == 0 then
				table.insert(marks, "-")
			else
				table.insert(marks, tostring(n))
			end
			standing -= n
			fresh = standing <= 0 and lastFrame
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

-- Inside the full-pay cooldown a pass pays the smaller repeat share at most once per
-- REPEAT_GAP seconds (os.time; the stamp lives in profile.modes.bowling.lastRepeatAt).
BowlingRules.REPEAT_GAP = 300

function BowlingRules.repeatDue(now: number, lastRepeatAt: any): boolean
	local last = if type(lastRepeatAt) == "number" and lastRepeatAt == lastRepeatAt then lastRepeatAt else 0
	-- A stamp from the future (clock skew, a bad save) counts as long ago.
	return last > now or now >= last + BowlingRules.REPEAT_GAP
end

function BowlingRules.passed(score: number): boolean
	return score >= BowlingRules.PASS_SCORE
end

--[[
	STARS. A finished game earns a star at each of STAR_TIERS points (the first is the pass).
	Every star a game reaches pays a bonus of TIER_SHARE[i] repeat shares (Economy repeatCash:
	MODE_REPEAT_SHARE of the cash pack), on top of the pass pay. All the bonuses together pay
	at most BONUS_CAPS[stars] repeat shares per REPEAT_GAP window (its start and what it paid
	are saved with the record: bonusAt, bonusUsed), the cap set by the stars of the game being
	paid: a 1-star game tops a window up to 0.4 repeat shares, a 2-star one to 0.7 and a
	3-star one to 1.2, so the higher tiers stay worth chasing after the first game. With the
	pass's own repeat share (at most one per REPEAT_GAP) a player earns at most
	1 + BONUS_CAPS[3] = 2.2 repeat shares per 5 minutes outside the full pack, however many
	games they play. Bonuses never restart the full pack's cooldown.
]]
-- Tuned with tests/bowling.luau's bowlers: perfect play (aim always in the pocket, power
-- always sweet) earns 3 stars in about a third of its games, a skilled one in about a
-- quarter and a decent one in about one in nine.
BowlingRules.STAR_TIERS = { 50, 80, 105 }
BowlingRules.TIER_SHARE = { 0.2, 0.3, 0.5 }
BowlingRules.BONUS_CAPS = { 0.4, 0.7, 1.2 }

-- Stars for a score (0..#STAR_TIERS).
function BowlingRules.stars(score: number): number
	local n = 0
	if type(score) ~= "number" or score ~= score then
		return 0
	end
	for i, tier in BowlingRules.STAR_TIERS do
		if score >= tier then
			n = i
		end
	end
	return n
end

-- The repeat shares the stars of a game with `stars` stars are worth (before the cap).
function BowlingRules.starShare(stars: number): number
	local share = 0
	for i = 1, math.clamp(math.floor(stars), 0, #BowlingRules.TIER_SHARE) do
		share += BowlingRules.TIER_SHARE[i]
	end
	return share
end

-- The most repeat shares a window's bonuses may reach once a game with `stars` stars is
-- paid (0 for no stars).
function BowlingRules.bonusCap(stars: number): number
	local n = if type(stars) == "number" and stars == stars then math.floor(stars) else 0
	return BowlingRules.BONUS_CAPS[math.clamp(n, 0, #BowlingRules.BONUS_CAPS)] or 0
end

-- A bonus of `share` repeat shares for a game with `stars` stars against the window that
-- started at `windowAt` (os.time, 0 = none) and has paid `used` shares: returns the share
-- paid now (0..share, topping the window up to bonusCap(stars) at most) and the window's new
-- start and used shares. A window older than REPEAT_GAP (or from the future) starts afresh.
function BowlingRules.bonusTake(windowAt: number, used: number, now: number, share: number, stars: number): (number, number, number)
	if windowAt <= 0 or now - windowAt >= BowlingRules.REPEAT_GAP or now < windowAt then
		windowAt, used = now, 0
	end
	local paid = math.clamp(BowlingRules.bonusCap(stars) - math.max(0, used), 0, math.max(0, share))
	return paid, windowAt, used + paid
end

function BowlingRules.bonusCash(repeatCash: number, share: number): number
	return math.max(0, math.floor(repeatCash * share))
end

-- Turn guards ---------------------------------------------------------------------------------

-- A roll this soon after its "ready" is refused (a scripted or mashed roll).
BowlingRules.READY_GAP = 0.8
-- A turn left this long: the server bowls a weak centre ball for the player (AFK_AIM,
-- AFK_POWER) so a kid who wandered off comes back to the same game, not a lost one. A game
-- with AUTO_LIMIT or more such balls is "auto-bowled": it pays nothing and counts for no
-- best, clears or stars (autoGame).
BowlingRules.AFK_SECONDS = 45
BowlingRules.AFK_AIM = 0
BowlingRules.AFK_POWER = 0.45
BowlingRules.AUTO_LIMIT = 2

function BowlingRules.autoGame(autoBalls: number): boolean
	return autoBalls >= BowlingRules.AUTO_LIMIT
end

-- A "BowlingRoll"'s aim and power: both must be real numbers (anything else is no roll at
-- all: nil, nil); then clamped to -1..1 and 0..1.
function BowlingRules.rollInput(aim: any, power: any): (number?, number?)
	if type(aim) ~= "number" or aim ~= aim or type(power) ~= "number" or power ~= power then
		return nil, nil
	end
	return math.clamp(aim, -1, 1), math.clamp(power, 0, 1)
end

-- A roll at `now` for a turn that opened at `readyAt` is early (refused).
function BowlingRules.tooEarly(now: number, readyAt: number): boolean
	return now - readyAt < BowlingRules.READY_GAP
end

-- Seconds from the release to the bowler's reaction (Fx.Bowling and other players' views
-- play it then; sent as the roll's `react`): after the pins settle (a strike's burst
-- first), as a gutter ball drops off the lane, or as the dumbbell reaches the pit.
function BowlingRules.reactAt(roll: Roll, mark: string?): number
	local path = roll.path
	local endT = path[#path].t
	if roll.knocked > 0 then
		local lastT = 0
		for _, fall in roll.falls do
			lastT = math.max(lastT, fall.t)
		end
		return lastT + (if mark == "strike" then 0.7 elseif mark == "spare" then 0.6 else 0.4)
	elseif roll.gutter and #path >= 4 then
		return path[#path - 2].t + 0.35
	end
	return endT
end

-- Seconds from the "roll" event after which "BowlingSkip" is taken: the run-up, the reaction's
-- start and skipAfter(mark) of it (a strike's whole celebration).
function BowlingRules.skipAt(roll: Roll, mark: string?): number
	return BowlingRules.WINDUP + BowlingRules.reactAt(roll, mark) + BowlingRules.skipAfter(mark)
end

-- "BowlingSkip": the settle may end early once `now` is past `skipFrom` (the reaction has
-- played a while).
function BowlingRules.canSkip(now: number, skipFrom: number): boolean
	return now >= skipFrom
end

-- Lobby and phases ---------------------------------------------------------------------------
--
-- A run goes lobby -> countdown -> play -> results -> lobby (docs/minigames.md, "Lobby first,
-- then the game"). Modes.Bowling keeps the phase; these say what each phase allows.

BowlingRules.PHASES = { "lobby", "countdown", "play", "results" }
-- Seconds of "3, 2, 1" before the first ball.
BowlingRules.COUNTDOWN = 3
-- Seconds the results card stays up before the player is back in the lobby.
BowlingRules.RESULTS_SECONDS = 6
-- Seconds after landing in the lobby before the START pad works (a player who lands on it,
-- or stands on it as they come back, is not thrown straight into another game).
BowlingRules.REARM = 1.5
-- Feet within this many studs above or below a pad's top count as standing on it.
BowlingRules.PAD_HEIGHT = 4
-- Dumbbells to pick, all on the lobby rack (World.BowlingLane's BallChoice1..RACK_BALLS):
-- four colours (the client reads them off the rack) and the gold-striped PRO dumbbell
-- (PRO_BALL), the rack's showpiece.
BowlingRules.RACK_BALLS = 5
BowlingRules.PRO_BALL = 5
BowlingRules.BALL_CHOICES = 5
-- The stars a player must have reached in some game (starsEver) to pick each dumbbell: two
-- free, then one more for each star tier.
BowlingRules.BALL_STARS = { 0, 0, 1, 2, 3 }

function BowlingRules.isPhase(phase: any): boolean
	return table.find(BowlingRules.PHASES, phase) ~= nil
end

-- "BowlingBegin": from the lobby, or PLAY AGAIN on the results card.
function BowlingRules.canBegin(phase: string): boolean
	return phase == "lobby" or phase == "results"
end

-- "BowlingBall": the rack is in the lobby; the results card may change it too.
function BowlingRules.canPickBall(phase: string): boolean
	return phase == "lobby" or phase == "results"
end

-- "BowlingRoll": only while a game is on.
function BowlingRules.canRoll(phase: string): boolean
	return phase == "play"
end

-- The EXIT arch ends the run in the lobby, or once the game is over (results); never
-- mid-game or mid-countdown.
function BowlingRules.canExit(phase: string): boolean
	return phase == "lobby" or phase == "results"
end

-- Where a fallen player goes back to: the lobby spawn in the lobby, else the play spot.
function BowlingRules.fallTo(phase: string): string
	return if phase == "lobby" then "lobby" else "play"
end

-- A valid ball pick (an integer 1..BALL_CHOICES), or nil.
function BowlingRules.ballChoice(value: any): number?
	if type(value) ~= "number" or value ~= value or value % 1 ~= 0 then
		return nil
	end
	if value < 1 or value > BowlingRules.BALL_CHOICES then
		return nil
	end
	return value
end

-- The most stars ever: the best score's stars and the saved topStars (profile.modes.bowling;
-- kept even if the tiers move later). Broken values count as 0.
function BowlingRules.starsEver(best: any, topStars: any): number
	local saved = if type(topStars) == "number" and topStars == topStars
		then math.clamp(math.floor(topStars), 0, #BowlingRules.STAR_TIERS)
		else 0
	return math.max(BowlingRules.stars(if type(best) == "number" then best else 0), saved)
end

-- Dumbbell `choice` (a valid ballChoice) is unlocked for a player with `stars` stars ever.
function BowlingRules.ballUnlocked(choice: number, stars: number): boolean
	local need = BowlingRules.BALL_STARS[choice]
	return need ~= nil and stars >= need
end

-- Feet at (dx, dy, dz) from a pad's top centre: on the pad when within `radius` across
-- and PAD_HEIGHT up or down.
function BowlingRules.onPad(dx: number, dy: number, dz: number, radius: number): boolean
	return dx * dx + dz * dz <= radius * radius and math.abs(dy) < BowlingRules.PAD_HEIGHT
end

-- The START pad begins a game: phase lobby, feet on it, and the re-arm time (armAt) over.
function BowlingRules.padStarts(phase: string, onPad: boolean, now: number, armAt: number): boolean
	return phase == "lobby" and onPad and now >= armAt
end

return BowlingRules
