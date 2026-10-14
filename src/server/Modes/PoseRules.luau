--!strict
--[[
	PoseRules: the pure rules of POSE COPY (Modes.Pose; docs/minigames.md). No Roblox
	services: tests/pose.luau loads it with Lune.

	A Simon-says memory game. The rival chad on the stage shows a sequence of flexes (one of
	the four FLEXES each beat), then the player copies it. Every cleared round adds one flex
	to the same run-long sequence (round n plays the first n flexes). A wrong flex or a
	too-slow one costs a heart and the round replays; no hearts left ends the run. Clearing
	PASS_ROUND passes the test (paid once per run); the run then keeps going for a best
	(the longest sequence copied).

	  FLEXES                      the four flexes: Poses name, button label, key direction
	  sequence(seed, length)      a run's flex indexes (1..4), seeded; never three in a row
	  press(seq, round, done, f)  "good" | "clear" (the round's last flex) | "wrong"
	  passed(cleared)             cleared rounds reach PASS_ROUND
	  showStep(round)             seconds per flex while the rival shows, faster each round
	  showLength(round)           seconds from "round" to the player's turn
	  repeatReady(lastAt, now)    the repeat share may pay again (REPEAT_GAP since the last)
	  newBest(best, cleared)      the saved best after a run that cleared `cleared` rounds

	ARENA is where World.PoseStage builds the arena (floor top centre and size in studs,
	out over the sea away from the Parkour maps, the Mog stage and the Cardio track; tests/
	minigames.luau keeps every arena clear of the others).
]]

local PoseRules = {}

PoseRules.ARENA = { x = 560, y = 6, z = -380, sizeX = 56, sizeZ = 48 }
-- Feet more than this far under the floor top: the player fell off and goes back to the spawn.
PoseRules.FALL_BELOW = 20

export type Flex = { pose: string, label: string, dir: string, rgb: { number } }

-- The four flexes, in button order (index = what the "PoseInput" action sends). `dir` is the
-- arrow / WASD / D-pad direction that strikes it; `rgb` its colour (stage lamps, buttons).
-- Fx.Pose.FLEXES is the client's copy: keep the two in the same order and colours.
PoseRules.FLEXES = {
	{ pose = "DoubleBiceps", label = "DOUBLE BICEPS", dir = "Up", rgb = { 255, 196, 40 } },
	{ pose = "SideChest", label = "SIDE CHEST", dir = "Left", rgb = { 255, 64, 158 } },
	{ pose = "LatSpread", label = "LAT SPREAD", dir = "Right", rgb = { 70, 140, 255 } },
	{ pose = "MostMuscular", label = "MOST MUSCULAR", dir = "Down", rgb = { 60, 206, 120 } },
} :: { Flex }

PoseRules.HEARTS = 3
-- Cleared rounds that pass the test (a sequence this long copied).
PoseRules.PASS_ROUND = 8
-- The longest sequence a run can reach (the run ends as a win there).
PoseRules.MAX_ROUND = 30

-- Show timing: seconds per flex at round 1, the fastest it gets, and the speed-up per round.
PoseRules.STEP_START = 0.95
PoseRules.STEP_MIN = 0.42
PoseRules.STEP_DROP = 0.05
-- Seconds before the first flex of a show (the "WATCH" banner) and after the last.
PoseRules.SHOW_LEAD = 1.2
PoseRules.SHOW_TAIL = 0.35
-- Seconds the player gets for each flex of their turn (generous: kids think).
PoseRules.INPUT_TIMEOUT = 6
-- Seconds between a cleared round (or a miss) and the next show.
PoseRules.ROUND_GAP = 1.6
PoseRules.MISS_GAP = 2.2
-- Seconds from "start" to the first show.
PoseRules.INTRO = 2.6
-- Inside the full reward's cooldown a pass pays the repeat share at most this often (s).
PoseRules.REPEAT_GAP = 300

local function lcg(seed: number): () -> number
	local state = math.floor(math.abs(seed)) % 2147483648
	return function()
		state = (state * 1103515245 + 12345) % 2147483648
		return state / 2147483648
	end
end

-- The run's sequence: `length` flex indexes (1..#FLEXES) from `seed`. The same seed gives the
-- same sequence; no flex comes three times in a row (two is fine: kids see "again!").
function PoseRules.sequence(seed: number, length: number): { number }
	local rng = lcg(seed)
	local n = #PoseRules.FLEXES
	local seq: { number } = {}
	for i = 1, math.max(0, math.floor(length)) do
		local pick = math.floor(rng() * n) + 1
		if i >= 3 and seq[i - 1] == pick and seq[i - 2] == pick then
			pick = pick % n + 1
		end
		seq[i] = pick
	end
	return seq
end

-- One press of the player's turn: `done` flexes of round `round` are already copied and
-- the player struck `flex`. "good" (go on), "clear" (that was the round's last) or "wrong".
function PoseRules.press(seq: { number }, round: number, done: number, flex: number): string
	local want = seq[done + 1]
	if done >= round or want == nil or flex ~= want then
		return "wrong"
	end
	return if done + 1 >= round then "clear" else "good"
end

-- Whether the repeat share may pay again (`lastAt`: os.time of its last pay, 0 = never).
function PoseRules.repeatReady(lastAt: number, now: number): boolean
	return lastAt <= 0 or now - lastAt >= PoseRules.REPEAT_GAP
end

function PoseRules.passed(cleared: number): boolean
	return cleared >= PoseRules.PASS_ROUND
end

function PoseRules.showStep(round: number): number
	return math.max(PoseRules.STEP_MIN, PoseRules.STEP_START - PoseRules.STEP_DROP * (math.max(1, round) - 1))
end

function PoseRules.showLength(round: number): number
	return PoseRules.SHOW_LEAD + math.max(1, round) * PoseRules.showStep(round) + PoseRules.SHOW_TAIL
end

function PoseRules.newBest(best: number, cleared: number): number
	return math.max(best, math.floor(cleared))
end

return PoseRules
