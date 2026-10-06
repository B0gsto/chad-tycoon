--[[
	MogRules: pure rules of the MOG TEST duel (no Roblox APIs; unit-tested in tests/mog.luau).

	A run is a chain of skill checks. Each check is a needle sweeping one lap (360 degrees of
	"travel") at `speed` deg/s; the zone covers travel in [zoneStart, zoneStart + zoneSize]
	and its first `perfectSize` degrees are the "perfect" part. A hit takes 1 HP off the
	rival (perfect: 2); at 0 HP the rival is mogged and the next, tougher one steps in.
	A miss costs a life; at 0 lives the run is finished. Mogging PASS_RIVALS rivals passes
	the Mog Test (the mode reward); the run goes on for a high score.

	Difficulty for the n-th check of a run (n >= 1):
	  window(n) = max(0.075, 0.30 * 0.93^(n - 1))   seconds of needle time inside the zone
	  speed(n)  = min(540, 220 + 12 * (n - 1))       deg/s
	  zoneSize  = max(16, window * speed)            degrees
	  perfect   = max(6, 0.25 * zoneSize)            degrees
	  dir       = +1 for n <= 7, then random +-1
	  zoneStart = random in [120, 330 - zoneSize] (n <= 11), [70, 330 - zoneSize] after
	  lead      = max(0.6, 1.4 - 0.03 * (n - 1))     seconds between telling the client and the needle start
	  delay     = random in [0.5, 1.4]               seconds before the next check after a result
	All randomness comes from the `rand()` function passed in (values in [0, 1)).
]]

local MogRules = {}

MogRules.LIVES = 3
MogRules.PASS_RIVALS = 3
-- Score per result (perfect also does PERFECT_DAMAGE to the rival).
MogRules.HIT_SCORE = 1
MogRules.PERFECT_SCORE = 2
MogRules.HIT_DAMAGE = 1
MogRules.PERFECT_DAMAGE = 2
-- Rival tiers when no tier name list is given (Theme.Tiers has 25).
MogRules.DEFAULT_TIERS = 25

MogRules.WINDOW_START = 0.30
MogRules.WINDOW_DECAY = 0.93
MogRules.WINDOW_MIN = 0.075
MogRules.SPEED_START = 220
MogRules.SPEED_STEP = 12
MogRules.SPEED_MAX = 540
MogRules.ZONE_MIN = 16
MogRules.PERFECT_MIN = 6
MogRules.PERFECT_SHARE = 0.25
MogRules.FIXED_DIR_CHECKS = 7
MogRules.EASY_ZONE_CHECKS = 11
MogRules.ZONE_FROM_EASY = 120
MogRules.ZONE_FROM_HARD = 70
MogRules.ZONE_UNTIL = 330
MogRules.DELAY_MIN = 0.5
MogRules.DELAY_MAX = 1.4

export type Check = {
	n: number,
	window: number,
	speed: number,
	dir: number,
	zoneStart: number,
	zoneSize: number,
	perfectSize: number,
	duration: number,
	lead: number,
	delay: number,
}

export type Rival = { index: number, name: string, tier: number, hp: number, maxHp: number }

export type Run = {
	startedAt: number,
	n: number,
	score: number,
	combo: number,
	bestCombo: number,
	lives: number,
	rival: Rival,
	rivals: number,
	passed: boolean,
	finished: boolean,
	names: { string }?,
}

export type Outcome = { moggedRival: Rival?, rival: Rival?, passed: boolean?, finished: boolean? }

export type BestEntry = { userId: number, name: string, score: number, rivals: number }

function MogRules.window(n: number): number
	return math.max(MogRules.WINDOW_MIN, MogRules.WINDOW_START * MogRules.WINDOW_DECAY ^ (n - 1))
end

function MogRules.speed(n: number): number
	return math.min(MogRules.SPEED_MAX, MogRules.SPEED_START + MogRules.SPEED_STEP * (n - 1))
end

function MogRules.lead(n: number): number
	return math.max(0.6, 1.4 - 0.03 * (n - 1))
end

-- The n-th check of a run. Calls rand() for the direction (n > FIXED_DIR_CHECKS only), the
-- zone start and the delay, in that order.
function MogRules.check(n: number, rand: () -> number): Check
	local window = MogRules.window(n)
	local speed = MogRules.speed(n)
	local zoneSize = math.max(MogRules.ZONE_MIN, window * speed)
	local perfectSize = math.max(MogRules.PERFECT_MIN, MogRules.PERFECT_SHARE * zoneSize)
	local dir = 1
	if n > MogRules.FIXED_DIR_CHECKS then
		dir = if rand() < 0.5 then -1 else 1
	end
	local from = if n <= MogRules.EASY_ZONE_CHECKS then MogRules.ZONE_FROM_EASY else MogRules.ZONE_FROM_HARD
	local to = math.max(from, MogRules.ZONE_UNTIL - zoneSize)
	local zoneStart = from + (to - from) * rand()
	local delay = MogRules.DELAY_MIN + (MogRules.DELAY_MAX - MogRules.DELAY_MIN) * rand()
	return {
		n = n,
		window = window,
		speed = speed,
		dir = dir,
		zoneStart = zoneStart,
		zoneSize = zoneSize,
		perfectSize = perfectSize,
		duration = 360 / speed,
		lead = MogRules.lead(n),
		delay = delay,
	}
end

-- Judges a press at `travel` degrees of needle travel. Returns the result and, for a miss,
-- "early" or "late".
function MogRules.judge(check: Check, travel: number): (string, string?)
	if travel < check.zoneStart then
		return "miss", "early"
	elseif travel > check.zoneStart + check.zoneSize then
		return "miss", "late"
	elseif travel <= check.zoneStart + check.perfectSize then
		return "perfect", nil
	end
	return "hit", nil
end

-- The i-th rival of a run: tougher (more HP, up to 6) and a higher unit tier each time.
-- `names` are the theme's tier names (Theme.Tiers[k].Name); the tier index is capped at #names.
function MogRules.rival(i: number, names: { string }?): Rival
	local count = if names and #names > 0 then #names else MogRules.DEFAULT_TIERS
	local tier = math.clamp(1 + 2 * i, 1, count)
	local hp = 3 + math.min(i - 1, 3)
	local base = if names and names[tier] then names[tier] else "Rival"
	return { index = i, name = base .. " #" .. i, tier = tier, hp = hp, maxHp = hp }
end

function MogRules.newRun(now: number, names: { string }?): Run
	return {
		startedAt = now,
		n = 0,
		score = 0,
		combo = 0,
		bestCombo = 0,
		lives = MogRules.LIVES,
		rival = MogRules.rival(1, names),
		rivals = 0,
		passed = false,
		finished = false,
		names = names,
	}
end

-- Applies a check result ("perfect" | "hit" | "miss") to the run. The outcome says whether
-- the rival was mogged (moggedRival, and the next `rival`), whether that mog passed the
-- test (the PASS_RIVALS-th) and whether the run is finished (no lives left).
function MogRules.apply(run: Run, result: string): Outcome
	local outcome: Outcome = {}
	if run.finished then
		return outcome
	end
	if result == "perfect" or result == "hit" then
		local perfect = result == "perfect"
		run.score += if perfect then MogRules.PERFECT_SCORE else MogRules.HIT_SCORE
		run.combo += 1
		run.bestCombo = math.max(run.bestCombo, run.combo)
		local rival = run.rival
		rival.hp = math.max(0, rival.hp - (if perfect then MogRules.PERFECT_DAMAGE else MogRules.HIT_DAMAGE))
		if rival.hp <= 0 then
			run.rivals += 1
			local passed = run.rivals == MogRules.PASS_RIVALS
			if passed then
				run.passed = true
			end
			run.rival = MogRules.rival(run.rivals + 1, run.names)
			outcome.moggedRival = rival
			outcome.rival = run.rival
			outcome.passed = passed
		end
	else
		run.combo = 0
		run.lives = math.max(0, run.lives - 1)
		if run.lives <= 0 then
			run.finished = true
			outcome.finished = true
		end
	end
	return outcome
end

-- Records a score on a best list (one entry per player, highest first, ties keep the
-- earlier entry ahead, at most `size` entries). Returns the player's rank, or nil.
function MogRules.recordBest(list: { BestEntry }, userId: number, name: string, score: number, rivals: number, size: number): number?
	for i, entry in list do
		if entry.userId == userId then
			if entry.score >= score then
				return i
			end
			table.remove(list, i)
			break
		end
	end
	local at = #list + 1
	for i, entry in list do
		if entry.score < score then
			at = i
			break
		end
	end
	if at > size then
		return nil
	end
	table.insert(list, at, { userId = userId, name = name, score = score, rivals = rivals })
	while #list > size do
		table.remove(list)
	end
	return at
end

return MogRules
