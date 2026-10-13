--!strict
--[[
	CardioRules: pure numbers of the CARDIO keyboard runner (no Roblox APIs; unit-tested in
	tests/cardio.luau). See docs/cardio.md.

	Speed is a permanent stat earned by stepping on keys (one step per KEY_STEP studs of ground
	run on keys, worth stepMultiplier Speed) and by standing on treadmills (treadmillRate Speed
	per second). Inside the mode, Humanoid WalkSpeed = walkSpeed(speed):
	  walkSpeed(s) = 16 + 104 * min(1, s / SPEED_AT_CAP) ^ CURVE      (16 at 0, 120 at the cap)
	Jumps use the default character (JumpHeight 7.2, Workspace.Gravity 196.2):
	  airtime(rise)      = (v0 + sqrt(v0^2 - 2 g rise)) / g,  v0 = sqrt(2 g JUMP_HEIGHT)
	  maxGap(walk, rise) = walk * airtime(rise) - SAFETY      the longest gap a stage may use
	  reach(walk, rise)  = walk * airtime(rise) + REACH_SLACK the longest gap physics may allow
	                       (the hitbox lets a body land partly over the edge)
	Stage n's longest (flat) gap is <= maxGap(walkSpeed(need_n)) and > reach(walkSpeed(need_n-1)),
	so the previous stage's Speed can never clear it, even with a perfect edge jump.
	Stage 3 is the first with a chaser, so its gaps are shorter than the curve allows: at
	exactly its need the longest jump keeps 2.9 studs of reach in reserve (2.4 with a 17), 3.5
	at the recommended Speed.
	The HUD also shows recommended(n) = RECOMMEND x need (15% more Speed) as the Speed to run a
	stage with comfortably.

	Stage table (gaps in studs, walk at exactly `need` Speed, no Sneakers):
	  stage  need     walk   maxGap  prev reach  longest gap
	    1        0    16.0     7.9        -          7
	    2      150    25.9    13.2      10.2        12
	    3    1,100    35.8    18.6      15.5        16.5
	    4    3,500    45.8    24.0      20.9        22.5
	    5    8,000    55.7    29.4      26.3        28
	    6   15,000    65.5    34.7      31.7        33
	    7   27,000    76.8    40.8      37.0        39
	    8   45,000    88.7    47.3      43.1        45
	    9   77,000   103.8    55.4      49.6        52.5
	   10  125,000   120.0    64.2      57.7        61

	Progression check (a coarse 1 s simulation, also run in tests/cardio.luau): a player who
	spends half the time running on keys (60% of the time actually stepping) and half on the
	best treadmill they have reached, and buys one treadmill level every 4 minutes, reaches
	  stage 2 ~1.5 min, 3 ~6 min, 4 ~12 min, 5 ~18 min, 6 ~23 min, 7 ~29 min, 8 ~34 min,
	  9 ~41 min, 10 ~49 min (about 70% of the Speed from treadmills).
	Step multiplier: (1 + 0.25 * bestStage) * (1 + 0.1 * treadmillLevel)  (x1 .. x7)
	Treadmill rate:  0.45 * (1 + zoneStage)^1.3 * (1 + 0.25 * level)
	                 * max(1, (speed / 150)^0.25)                         Speed/s
	Treadmill cost:  max(150 * (level + 1)^2, income * (120 + 24 * level)) cash for level -> level + 1
]]

local CardioRules = {}

-- Studs of ground run on keys per counted step (one keycap).
CardioRules.KEY_STEP = 8
CardioRules.BASE_WALK = 16
CardioRules.WALK_CAP = 120
-- Speed at which walkSpeed reaches WALK_CAP (stage 10's need) and the curve exponent.
CardioRules.SPEED_AT_CAP = 125000
CardioRules.CURVE = 0.35

CardioRules.GRAVITY = 196.2
CardioRules.JUMP_HEIGHT = 7.2
-- Studs of reach kept in reserve on every designed jump (phones, late jumps).
CardioRules.SAFETY = 0.8
-- Speed the HUD recommends for a stage, as a multiple of its need.
CardioRules.RECOMMEND = 1.15
-- Studs past the pure take-off-to-landing travel a body can still clear (half the hitbox at
-- each end). Used only to prove a gap is NOT clearable.
CardioRules.REACH_SLACK = 1.5
-- Highest step-up between platforms anywhere in the mode.
CardioRules.MAX_STEP_UP = 5

CardioRules.TREADMILL_MAX = 10
CardioRules.TREADMILL_BASE = 0.45
-- Treadmills grow with the runner: x max(1, (speed / SPEED_REF) ^ SPEED_EXP) (x1 .. ~x5.4).
CardioRules.TREADMILL_SPEED_REF = 150
CardioRules.TREADMILL_SPEED_EXP = 0.25
CardioRules.TREADMILL_ZONE_EXP = 1.3
CardioRules.TREADMILL_LEVEL_BONUS = 0.25
CardioRules.STEP_STAGE_BONUS = 0.25
CardioRules.STEP_LEVEL_BONUS = 0.1
CardioRules.COST_SECONDS = 120
CardioRules.COST_SECONDS_PER_LEVEL = 24
CardioRules.COST_MINIMUM = 150
-- The run again bonus (a WIN plate inside the reward cooldown pays Economy.MODE_REPEAT_SHARE
-- of its pack) is paid no sooner than this many seconds after the last plate that paid, so
-- a short stage cannot be looped for it however fast the runner is.
CardioRules.REPEAT_GAP = 30

export type Movers = { travel: number, period: number }

export type Stage = {
	n: number,
	name: string,
	-- Theme.World colour key of the stage's keycaps and sign.
	color: string,
	need: number,
	-- walkSpeed(need), filled in below.
	walk: number,
	-- Longest edge-to-edge gap (studs, flat).
	gap: number,
	-- Bridge width (across the room: 9 keys on stage 1 down to 4 keys from stage 8) and
	-- platform length (along it), studs; whole keys (multiples of CardioLayout.KEY.size = 2.8).
	-- The whole stage bridge (run-up, jog, platforms) is this wide.
	width: number,
	plat: number,
	-- Number of jumps from the end of the stage's run-up carpet to its safe zone.
	jumps: number,
	-- Step-up / step-down height between platforms (<= MAX_STEP_UP).
	rise: number,
	-- Blinking keys: on for blinkOn seconds of every blinkPeriod (nil before stage 4).
	blinkOn: number?,
	blinkPeriod: number?,
	-- Sliding keys (side to side, +-travel studs over period seconds; nil before stage 6).
	movers: Movers?,
	-- Jump course length from the end of the stage's run-up carpet to this stage's safe zone,
	-- studs (gaps + platforms; the run-up itself is laid out by CardioLayout).
	length: number,
}

export type Jump = { gap: number, rise: number }

local function stage(
	name: string,
	color: string,
	need: number,
	gap: number,
	width: number,
	plat: number,
	jumps: number,
	rise: number,
	blink: { number }?,
	movers: Movers?
): Stage
	return {
		n = 0,
		name = name,
		color = color,
		need = need,
		walk = 0,
		gap = gap,
		width = width,
		plat = plat,
		jumps = jumps,
		rise = rise,
		blinkOn = if blink then blink[1] else nil,
		blinkPeriod = if blink then blink[2] else nil,
		movers = movers,
		length = 0,
	}
end

CardioRules.STAGE_COUNT = 10
-- stylua: ignore
CardioRules.STAGES = {
	stage("Home Row",         "Mint",      0,      7,  25.2, 25.2, 4, 0,   nil,          nil),
	stage("Shift Street",     "Sunny",     150,    12, 22.4, 25.2, 4, 1,   nil,          nil),
	stage("Tab Tunnel",       "Teal",      1100,   16.5, 22.4, 22.4, 4, 2,   nil,          nil),
	stage("Caps Lock Canyon", "Orange",    3500,   22.5, 16.8, 22.4, 3, 2.5, { 2.2, 3.2 }, nil),
	stage("Enter Expressway", "Pink",      8000,   28, 16.8, 22.4, 3, 3,   { 2.0, 3.0 }, nil),
	stage("Backspace Bridge", "Blue",      15000,  33, 14, 16.8, 3, 3.5, { 1.9, 2.9 }, { travel = 8, period = 5 }),
	stage("Function Falls",   "Grape",     27000,  39, 14, 16.8, 3, 4,   { 1.8, 2.8 }, { travel = 8, period = 4.5 }),
	stage("Arrow Key Alley",  "Coral",     45000,  45, 11.2, 16.8, 3, 4.5, { 1.7, 2.7 }, { travel = 10, period = 4.2 }),
	stage("Escape Heights",   "RedOrange", 77000,  52.5, 11.2, 16.8, 3, 5,  { 1.6, 2.6 }, { travel = 10, period = 4 }),
	stage("Spacebar Skyway",  "Butter",    125000, 61, 11.2, 16.8, 3, 5,   { 1.5, 2.5 }, { travel = 12, period = 3.8 }),
} :: { Stage }

-- Smooth, increasing, diminishing-returns WalkSpeed for a Speed stat.
function CardioRules.walkSpeed(speed: number): number
	local u = math.clamp(speed / CardioRules.SPEED_AT_CAP, 0, 1)
	return CardioRules.BASE_WALK + (CardioRules.WALK_CAP - CardioRules.BASE_WALK) * u ^ CardioRules.CURVE
end

-- Take-off speed of the default jump.
function CardioRules.jumpVelocity(): number
	return math.sqrt(2 * CardioRules.GRAVITY * CardioRules.JUMP_HEIGHT)
end

-- Seconds in the air for a jump that lands `rise` studs higher (negative = lower); nil when
-- the jump can't reach that height at all.
function CardioRules.airtime(rise: number?): number?
	local r = rise or 0
	local v0 = CardioRules.jumpVelocity()
	local d = v0 * v0 - 2 * CardioRules.GRAVITY * r
	if d < 0 then
		return nil
	end
	return (v0 + math.sqrt(d)) / CardioRules.GRAVITY
end

-- Longest edge-to-edge gap a stage may ask for at this WalkSpeed (with SAFETY in reserve).
function CardioRules.maxGap(walk: number, rise: number?): number
	local t = CardioRules.airtime(rise)
	if not t then
		return 0
	end
	return walk * t - CardioRules.SAFETY
end

-- Longest gap physics could possibly allow at this WalkSpeed (used to prove "not clearable").
function CardioRules.reach(walk: number, rise: number?): number
	local t = CardioRules.airtime(rise)
	if not t then
		return 0
	end
	return walk * t + CardioRules.REACH_SLACK
end

-- The jumps of stage n in order: the first leaves the previous safe zone, the last lands on
-- this stage's safe zone. Platform k (after jump k) sits `rise` higher when k % 4 is 1 or 2,
-- so jumps go up, flat, down, flat... and every zone is at the base height. Flat jumps at
-- even indexes are the stage's longest gap; rising jumps are cut to what the stage's need
-- can clear with the step-up.
function CardioRules.jumps(n: number): { Jump }
	local s = CardioRules.STAGES[n]
	local walk = CardioRules.walkSpeed(s.need)
	local list: { Jump } = {}
	local prevH = 0
	for k = 1, s.jumps do
		local h = if k < s.jumps and (k % 4 == 1 or k % 4 == 2) then s.rise else 0
		local rise = h - prevH
		local gap
		if rise > 0 then
			gap = math.min(0.75 * s.gap, CardioRules.maxGap(walk, rise) - 0.3)
		elseif rise < 0 then
			gap = 0.85 * s.gap
		else
			gap = if k % 2 == 0 then s.gap else 0.85 * s.gap
		end
		table.insert(list, { gap = math.floor(gap * 2) / 2, rise = rise })
		prevH = h
	end
	return list
end

for n, s in CardioRules.STAGES do
	s.n = n
	s.walk = CardioRules.walkSpeed(s.need)
end
for n, s in CardioRules.STAGES do
	local total = 0
	for _, j in CardioRules.jumps(n) do
		total += j.gap
	end
	s.length = total + (s.jumps - 1) * s.plat
end

-- Highest stage whose need this Speed meets (1..STAGE_COUNT).
function CardioRules.stageFor(speed: number): number
	local best = 1
	for n, s in CardioRules.STAGES do
		if speed >= s.need then
			best = n
		end
	end
	return best
end

-- Speed the HUD recommends for stage n: RECOMMEND x its need, a whole number, and never past
-- SPEED_AT_CAP (more Speed than that runs no faster, so the last stage recommends its need).
function CardioRules.recommended(n: number): number
	local s = CardioRules.STAGES[n]
	if not s then
		return 0
	end
	return math.max(s.need, math.min(math.ceil(s.need * CardioRules.RECOMMEND), CardioRules.SPEED_AT_CAP))
end

-- First clears are kept per WIN plate in a bit set (profile.cardio.firsts): bit n - 1 is set
-- once plate n's first-clear pay was taken, so running past a plate never loses its first
-- clear. Saves from before the set (nil) had one counter: every plate up to bestStage counts
-- as taken, as it did then.
local ALL_FIRSTS = 2 ^ CardioRules.STAGE_COUNT - 1

function CardioRules.firstsOf(firsts: number?, bestStage: number): number
	if type(firsts) == "number" and firsts == firsts and firsts >= 0 then
		return bit32.band(math.floor(math.min(firsts, ALL_FIRSTS)), ALL_FIRSTS)
	end
	return 2 ^ math.clamp(math.floor(bestStage), 0, CardioRules.STAGE_COUNT) - 1
end

-- Is plate n's first-clear pay still there?
function CardioRules.isFirst(firsts: number, n: number): boolean
	if n < 1 or n > CardioRules.STAGE_COUNT then
		return false
	end
	return not bit32.btest(firsts, bit32.lshift(1, n - 1))
end

-- The set after plate n's first-clear pay was taken.
function CardioRules.claimFirst(firsts: number, n: number): number
	if n < 1 or n > CardioRules.STAGE_COUNT then
		return firsts
	end
	return bit32.bor(firsts, bit32.lshift(1, n - 1))
end

-- Speed per counted step: grows with the deepest plate claimed and every treadmill level.
function CardioRules.stepMultiplier(bestStage: number, treadmillLevel: number): number
	local b = math.clamp(math.floor(bestStage), 0, CardioRules.STAGE_COUNT)
	local l = math.clamp(math.floor(treadmillLevel), 0, CardioRules.TREADMILL_MAX)
	return (1 + CardioRules.STEP_STAGE_BONUS * b) * (1 + CardioRules.STEP_LEVEL_BONUS * l)
end

-- Speed per second while standing on a treadmill in safe zone `zoneStage` (0 = lobby) with
-- `level` SPEED UP levels; grows on its own with the runner's current Speed (nil = 0).
function CardioRules.treadmillRate(zoneStage: number, level: number, speed: number?): number
	local z = math.clamp(math.floor(zoneStage), 0, CardioRules.STAGE_COUNT)
	local l = math.clamp(math.floor(level), 0, CardioRules.TREADMILL_MAX)
	local s = math.max(speed or 0, 0)
	local grow = math.max(1, (s / CardioRules.TREADMILL_SPEED_REF) ^ CardioRules.TREADMILL_SPEED_EXP)
	return CardioRules.TREADMILL_BASE * (1 + z) ^ CardioRules.TREADMILL_ZONE_EXP * (1 + CardioRules.TREADMILL_LEVEL_BONUS * l) * grow
end

-- Cash to raise the treadmill from `level` to level + 1: 2..5.6 minutes of income, never below
-- a small minimum; math.huge at TREADMILL_MAX.
function CardioRules.treadmillCost(level: number, income: number): number
	local l = math.max(0, math.floor(level))
	if l >= CardioRules.TREADMILL_MAX then
		return math.huge
	end
	local seconds = CardioRules.COST_SECONDS + CardioRules.COST_SECONDS_PER_LEVEL * l
	return math.floor(math.max(CardioRules.COST_MINIMUM * (l + 1) ^ 2, math.max(0, income) * seconds))
end

-- The first plate that can pay the run again bonus: the deepest one claimed so far (the
-- personal best), so a repeat is a run at least as long as the player's best one.
function CardioRules.repeatFrom(bestStage: number): number
	return math.clamp(math.floor(bestStage), 1, CardioRules.STAGE_COUNT)
end

-- Does claiming plate `stage` inside the reward cooldown earn the run again bonus? Only on
-- the best plate (`bestStage`, before this claim) or a deeper one, and only `sincePaid` >=
-- REPEAT_GAP seconds after the last plate that paid anything.
function CardioRules.repeatEarned(stage: number, bestStage: number, sincePaid: number): boolean
	return stage >= CardioRules.repeatFrom(bestStage) and sincePaid >= CardioRules.REPEAT_GAP
end

-- What a WIN plate pays: "first" (its first clear) and "full" (the cooldown is over) the
-- whole pack, "repeat" (inside the cooldown, `earned`) the run again bonus, "resting" (a
-- plate that would earn it, but inside REPEAT_GAP: `resting`) and "none" nothing.
function CardioRules.payKind(first: boolean, full: boolean, earned: boolean, resting: boolean?): string
	if first then
		return "first"
	elseif full then
		return "full"
	elseif earned then
		return "repeat"
	end
	return if resting then "resting" else "none"
end

-- Cash multiplier on stage n's reward (+25% per stage: stage 10 pays 3.25x the pack).
function CardioRules.stageBonus(n: number): number
	return 1 + 0.25 * (math.clamp(math.floor(n), 1, CardioRules.STAGE_COUNT) - 1)
end

return CardioRules
