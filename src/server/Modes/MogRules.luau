--[[
	MogRules: pure rules of the MOG TEST duel (no Roblox APIs; unit-tested in tests/mog.luau).

	A run is a chain of skill checks. Each check is a needle sweeping one lap (360 degrees of
	"travel") at `speed` deg/s; the zone covers travel in [zoneStart, zoneStart + zoneSize]
	and its first `perfectSize` degrees are the "perfect" part. A hit takes 1 HP off the
	rival (perfect: 2); at 0 HP the rival is mogged and the next, tougher one steps in.
	A miss costs a life; at 0 lives the run is finished. Mogging PASS_RIVALS rivals passes
	the Mog Test (the mode reward); the run goes on for a high score.

	Difficulty for the n-th check of a run (n >= 1):
	  speed(n)  = min(540, 220 + 12 * (n - 1))             deg/s
	  zoneSize  = max(40, 0.37 * 0.945^(n - 1) * speed)    degrees; never grows (the floor holds from n = 30)
	  window(n) = zoneSize / speed                         seconds of needle time inside the zone (370 ms .. 74 ms)
	  perfect   = max(0.25 * zoneSize, 0.04 * speed)       degrees: at least 40 ms of needle travel (from n = 16)
	  dir       = +1 for n <= 7, then random +-1
	  zoneStart = random in [120, 330 - zoneSize] (n <= 11), [70, 330 - zoneSize] after
	  lead      = max(0.6, 1.4 - 0.03 * (n - 1))     seconds between telling the client and the needle start
	  delay     = random in [0.5, 1.4]               seconds before the next check after a result
	A `hidden` check (PvP) keeps its zone secret until the needle starts, so the zone starts no
	sooner than REVEAL_TIME seconds of needle travel (time to see it): zoneStart from
	min(330 - zoneSize, max(the floor above, REVEAL_TIME * speed)).
	All randomness comes from the `rand()` function passed in (values in [0, 1)).

	Pay (Modes.Mog): a PvE pass and a PvP win share one reward cooldown. Inside it they pay
	the repeat share (Economy.MODE_REPEAT_SHARE of the pack), but only for a real run:
	  - a pass: PASS_RIVALS rivals mogged in this run, paid once per run (claimPass). No pass
	    takes less than minPassSeconds() of checks (about 15 s; a kid needs about 35 s).
	  - a PvP win: a duel fought to the end (a KO or the round cap, never a forfeit of any
	    kind) in which the loser pressed on PVP_REPEAT_PRESSES checks or more (duelFought).
	  - and per player no sooner than REPEAT_GAP seconds after their last repeat share (a pass
	    and a PvP win share the gap): an earned one inside it pays nothing and is "resting".
	payKind names what a pass or win pays: "first" | "full" | "repeat" | "resting" | "none".

	Pass rate of the first PASS_RIVALS rivals for a player whose presses miss the zone centre by
	a Gaussian timing error (4,000 runs each): 50 ms 100%, 70 ms 94%, 100 ms 57%, 140 ms 17%
	(before this curve: 94%, 62%, 18%, 3%).
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

MogRules.WINDOW_START = 0.37
MogRules.WINDOW_DECAY = 0.945
MogRules.SPEED_START = 220
MogRules.SPEED_STEP = 12
MogRules.SPEED_MAX = 540
-- Smallest zone, degrees (74 ms at SPEED_MAX): the zone shrinks to it and stays there.
MogRules.ZONE_MIN = 40
-- The perfect slice: a share of the zone, never less than this many seconds of needle travel.
MogRules.PERFECT_SHARE = 0.25
MogRules.PERFECT_MIN_TIME = 0.04
MogRules.FIXED_DIR_CHECKS = 7
MogRules.EASY_ZONE_CHECKS = 11
MogRules.ZONE_FROM_EASY = 120
MogRules.ZONE_FROM_HARD = 70
MogRules.ZONE_UNTIL = 330
MogRules.DELAY_MIN = 0.5
MogRules.DELAY_MAX = 1.4
-- PvP: HP per duelist, self-damage of a miss, extra lead (seconds) before the first check.
MogRules.PVP_HP = 8
MogRules.PVP_MISS_DAMAGE = 1
MogRules.PVP_FIRST_LEAD = 0.6
-- PvP checks are hidden: the zone is sent when the needle starts and begins no sooner than
-- REVEAL_TIME seconds later. A press sooner than MIN_REACTION seconds after the zone was sent
-- is not a human reaction and is ignored.
MogRules.REVEAL_TIME = 0.55
MogRules.MIN_REACTION = 0.15
-- PvP: a side that lets this many checks in a row time out forfeits; a duel that is still
-- undecided after PVP_MAX_ROUNDS rounds goes to the higher HP, then the higher score.
MogRules.PVP_IDLE_FORFEIT = 3
MogRules.PVP_MAX_ROUNDS = 40
-- PvP: a decided duel was close when the winner ended at most this many HP ahead (or it went
-- to sudden death); only then does the loser's card say "So close!".
MogRules.PVP_CLOSE_MARGIN = 2
-- PvP: a win inside the reward cooldown pays the repeat share only when the loser really
-- pressed (a timeout is not a press) on this many checks. A KO takes 3 rounds at the least.
MogRules.PVP_REPEAT_PRESSES = 3
-- The repeat share (a pass or a fought PvP win inside the reward cooldown) is paid to a player
-- no sooner than this many seconds after their last one, PvE and PvP together: a fast pass
-- cannot be looped for it and two accounts cannot trade duel wins for it.
MogRules.REPEAT_GAP = 90

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
	-- The pass of this run was paid (claimPass): one pay per run.
	claimed: boolean?,
}

export type Outcome = { moggedRival: Rival?, rival: Rival?, passed: boolean?, finished: boolean? }

-- One side of a PvP duel; `result` is this round's answer (nil = not answered yet), `idle`
-- the checks in a row this side let time out, `presses` the checks it really answered.
export type Duelist = {
	hp: number,
	maxHp: number,
	score: number,
	combo: number,
	bestCombo: number,
	result: string?,
	idle: number,
	presses: number,
}

-- A PvP duel: sides[1] and sides[2]; `rounds` played; once finished, winner = 1 | 2, or nil
-- for a draw (both sides idle, or level on HP and score at the round cap) and `reason` is
-- the Round's ("ko" | "afk" | "rounds").
export type Duel = {
	n: number,
	rounds: number,
	sides: { Duelist },
	finished: boolean,
	winner: number?,
	suddenDeath: boolean,
	reason: string?,
}

-- What a round did: each side's result (a missing answer counts as "miss"), suddenDeath when
-- a KO tie sent both back to 1 HP, and when the duel is over the winner (nil = draw) and why:
-- "ko", "afk" (PVP_IDLE_FORFEIT timeouts in a row) or "rounds" (PVP_MAX_ROUNDS played).
export type Round = {
	results: { string },
	finished: boolean,
	winner: number?,
	suddenDeath: boolean,
	reason: string?,
}

-- The saved Mog record's fields the reward rules read (profile.modes.mog).
export type Record = { clears: number, rivals: number }

export type BestEntry = { userId: number, name: string, score: number, rivals: number }

function MogRules.speed(n: number): number
	return math.min(MogRules.SPEED_MAX, MogRules.SPEED_START + MogRules.SPEED_STEP * (n - 1))
end

-- Degrees of zone: the decaying window at the needle's speed, floored at ZONE_MIN. The decay
-- outruns the speed-up, so the zone never grows from one check to the next.
function MogRules.zoneSize(n: number): number
	return math.max(MogRules.ZONE_MIN, MogRules.WINDOW_START * MogRules.WINDOW_DECAY ^ (n - 1) * MogRules.speed(n))
end

-- Seconds the needle spends inside the zone.
function MogRules.window(n: number): number
	return MogRules.zoneSize(n) / MogRules.speed(n)
end

-- Degrees of the zone's perfect part (at least PERFECT_MIN_TIME of needle travel).
function MogRules.perfectSize(n: number): number
	local zoneSize = MogRules.zoneSize(n)
	return math.min(zoneSize, math.max(MogRules.PERFECT_SHARE * zoneSize, MogRules.PERFECT_MIN_TIME * MogRules.speed(n)))
end

function MogRules.lead(n: number): number
	return math.max(0.6, 1.4 - 0.03 * (n - 1))
end

-- The n-th check of a run. Calls rand() for the direction (n > FIXED_DIR_CHECKS only), the
-- zone start and the delay, in that order. `hidden` (PvP): the zone is only shown when the
-- needle starts, so it starts at least REVEAL_TIME seconds of travel in.
function MogRules.check(n: number, rand: () -> number, hidden: boolean?): Check
	local window = MogRules.window(n)
	local speed = MogRules.speed(n)
	local zoneSize = MogRules.zoneSize(n)
	local perfectSize = MogRules.perfectSize(n)
	local dir = 1
	if n > MogRules.FIXED_DIR_CHECKS then
		dir = if rand() < 0.5 then -1 else 1
	end
	local from = if n <= MogRules.EASY_ZONE_CHECKS then MogRules.ZONE_FROM_EASY else MogRules.ZONE_FROM_HARD
	if hidden then
		from = math.min(MogRules.ZONE_UNTIL - zoneSize, math.max(from, MogRules.REVEAL_TIME * speed))
	end
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

-- Is a PvE pass still this record's first clear (always paid)? Only a pass uses it up: a PvP
-- win is paid on the cooldown alone. Saves whose `clears` was spent by a PvP win (the two
-- used to share it) get it back: they never mogged PASS_RIVALS rivals in one run.
function MogRules.firstPass(rec: Record): boolean
	return rec.clears == 0 or rec.rivals < MogRules.PASS_RIVALS
end

-- Books a paid result on the record: a PvE pass ("rivals") counts as a clear and records its
-- PASS_RIVALS rivals at once; a PvP win ("pvp") leaves both alone.
function MogRules.countClear(rec: Record, vs: string)
	if vs == "rivals" then
		rec.clears += 1
		rec.rivals = math.max(rec.rivals, MogRules.PASS_RIVALS)
	end
end

-- Takes this run's pass pay: true once, for a run that really mogged PASS_RIVALS rivals.
function MogRules.claimPass(run: Run): boolean
	if run.claimed or not run.passed or run.rivals < MogRules.PASS_RIVALS then
		return false
	end
	run.claimed = true
	return true
end

-- The fewest checks a pass takes: every hit a perfect.
function MogRules.minPassChecks(): number
	local checks = 0
	for i = 1, MogRules.PASS_RIVALS do
		checks += math.ceil(MogRules.rival(i).hp / MogRules.PERFECT_DAMAGE)
	end
	return checks
end

-- The shortest a pass can take, seconds from the first check's announcement: each check's
-- lead, the needle's travel to the earliest zone and the shortest delay to the next one.
function MogRules.minPassSeconds(): number
	local checks = MogRules.minPassChecks()
	local seconds = 0
	for n = 1, checks do
		local from = if n <= MogRules.EASY_ZONE_CHECKS then MogRules.ZONE_FROM_EASY else MogRules.ZONE_FROM_HARD
		seconds += MogRules.lead(n) + from / MogRules.speed(n)
		if n < checks then
			seconds += MogRules.DELAY_MIN
		end
	end
	return seconds
end

-- What a pass or a PvP win pays: "first" (the first pass ever) and "full" (the cooldown is
-- over) pay the whole pack, "repeat" (inside the cooldown, `earned` by a real run) the repeat
-- share, "resting" (the same, but `sincePaid` seconds after the player's last repeat share is
-- inside REPEAT_GAP) and "none" nothing.
function MogRules.payKind(first: boolean, full: boolean, earned: boolean, sincePaid: number?): string
	if first then
		return "first"
	elseif full then
		return "full"
	elseif not earned then
		return "none"
	end
	return if sincePaid and sincePaid < MogRules.REPEAT_GAP then "resting" else "repeat"
end

local function duelist(): Duelist
	return {
		hp = MogRules.PVP_HP,
		maxHp = MogRules.PVP_HP,
		score = 0,
		combo = 0,
		bestCombo = 0,
		result = nil,
		idle = 0,
		presses = 0,
	}
end

function MogRules.newDuel(): Duel
	return {
		n = 0,
		rounds = 0,
		sides = { duelist(), duelist() },
		finished = false,
		winner = nil,
		suddenDeath = false,
		reason = nil,
	}
end

-- Records side `side`'s answer ("perfect" | "hit" | "miss") to this round's check and
-- updates its score and combo; a press of any kind ends that side's idle streak and counts
-- as one of its `presses`. Returns
-- false (and changes nothing) when that side already answered or the duel is over. HP only
-- changes in duelRound.
function MogRules.duelPress(duel: Duel, side: number, result: string): boolean
	local d = duel.sides[side]
	if duel.finished or not d or d.result ~= nil then
		return false
	end
	d.result = result
	d.idle = 0
	d.presses += 1
	if result == "perfect" or result == "hit" then
		d.score += if result == "perfect" then MogRules.PERFECT_SCORE else MogRules.HIT_SCORE
		d.combo += 1
		d.bestCombo = math.max(d.bestCombo, d.combo)
	else
		d.combo = 0
	end
	return true
end

-- Has every side answered this round's check?
function MogRules.duelAnswered(duel: Duel): boolean
	return duel.sides[1].result ~= nil and duel.sides[2].result ~= nil
end

-- Ends the duel inside duelRound: `winner` nil is a draw.
local function decide(duel: Duel, round: Round, winner: number?, reason: string)
	duel.winner = winner
	duel.finished = true
	duel.reason = reason
	round.finished = true
	round.winner = winner
	round.reason = reason
	round.suddenDeath = false
end

-- Ends the round: a side that has not answered misses by timeout (one more idle check), then
-- both sides' damage lands at once and the duel is decided (or goes to sudden death). A KO
-- comes first; then a side idle for PVP_IDLE_FORFEIT checks in a row forfeits (both idle: a
-- draw), so two players who walked away cannot hold a duel spot; then the round cap. Clears
-- the answers for the next round.
function MogRules.duelRound(duel: Duel): Round
	local round: Round = { results = {}, finished = false, winner = nil, suddenDeath = false, reason = nil }
	if duel.finished then
		return round
	end
	duel.rounds += 1
	for side = 1, 2 do
		local d = duel.sides[side]
		if d.result == nil then
			local idle, presses = d.idle + 1, d.presses
			MogRules.duelPress(duel, side, "miss")
			d.idle, d.presses = idle, presses
		end
	end
	local damage = { 0, 0 }
	for side = 1, 2 do
		local result = duel.sides[side].result :: string
		round.results[side] = result
		if result == "perfect" then
			damage[3 - side] += MogRules.PERFECT_DAMAGE
		elseif result == "hit" then
			damage[3 - side] += MogRules.HIT_DAMAGE
		else
			damage[side] += MogRules.PVP_MISS_DAMAGE
		end
	end
	local a, b = duel.sides[1], duel.sides[2]
	a.hp -= damage[1]
	b.hp -= damage[2]
	a.result, b.result = nil, nil
	if a.hp <= 0 or b.hp <= 0 then
		if a.hp == b.hp then
			-- Sudden death: both back to 1 HP, the next round decides.
			a.hp, b.hp = 1, 1
			duel.suddenDeath = true
			round.suddenDeath = true
		else
			decide(duel, round, if a.hp > b.hp then 1 else 2, "ko")
			a.hp, b.hp = math.max(0, a.hp), math.max(0, b.hp)
		end
	end
	if not duel.finished then
		local idleA, idleB = a.idle >= MogRules.PVP_IDLE_FORFEIT, b.idle >= MogRules.PVP_IDLE_FORFEIT
		if idleA or idleB then
			decide(duel, round, if idleA and idleB then nil elseif idleB then 1 else 2, "afk")
		elseif duel.rounds >= MogRules.PVP_MAX_ROUNDS then
			local winner: number? = nil
			if a.hp ~= b.hp then
				winner = if a.hp > b.hp then 1 else 2
			elseif a.score ~= b.score then
				winner = if a.score > b.score then 1 else 2
			end
			decide(duel, round, winner, "rounds")
		end
	end
	return round
end

-- Was a decided duel close? It went to sudden death, or the winner ended at most
-- PVP_CLOSE_MARGIN HP ahead. False for a draw and for a duel that is not over (the caller
-- leaves out forfeits: a side that left or stopped pressing did not lose a close duel).
function MogRules.duelClose(duel: Duel): boolean
	local winner = duel.winner
	if not duel.finished or winner == nil then
		return false
	end
	return duel.suddenDeath or duel.sides[winner].hp - duel.sides[3 - winner].hp <= MogRules.PVP_CLOSE_MARGIN
end

-- Was the duel really fought? It ended by a KO or at the round cap (an idle forfeit and a
-- draw are not; the caller leaves out a side that left) and the loser pressed on
-- PVP_REPEAT_PRESSES checks or more. Only such a win earns the repeat share.
function MogRules.duelFought(duel: Duel): boolean
	local winner = duel.winner
	if not duel.finished or winner == nil or (duel.reason ~= "ko" and duel.reason ~= "rounds") then
		return false
	end
	return duel.sides[3 - winner].presses >= MogRules.PVP_REPEAT_PRESSES
end

return MogRules
