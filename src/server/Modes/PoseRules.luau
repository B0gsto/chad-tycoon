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

-- 104 wide: the 56-stud show (stage and fan zone) in the middle, the green-room lobby on the
-- +X wing and a TV-crew corner on the -X wing (World.PoseStage).
PoseRules.ARENA = { x = 0, y = 6, z = -10000, sizeX = 104, sizeZ = 48 }
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
-- The longest sequence a run can reach (the run ends as a win there): out of human reach,
-- so after the pass the run is an endless chase for a best.
PoseRules.MAX_ROUND = 99

-- Show timing: seconds per flex at round 1, the fastest it gets, and the speed-up per round.
-- The floor stays readable: a flex shown twice in a row still needs a visible reset.
PoseRules.STEP_START = 0.95
PoseRules.STEP_MIN = 0.5
PoseRules.STEP_DROP = 0.04
-- Seconds before the first flex of a show (the "WATCH" banner) and after the last.
PoseRules.SHOW_LEAD = 1.2
PoseRules.SHOW_TAIL = 0.35
-- Seconds the player gets for each flex of their turn (generous: kids think).
PoseRules.INPUT_TIMEOUT = 6
-- Seconds between a cleared round (or a miss) and the next show.
PoseRules.ROUND_GAP = 1.6
PoseRules.MISS_GAP = 2.2
-- Lobby flow: the 3-2-1 before play, how long the results card holds the player before
-- the lobby, the START pad's re-arm, its reach above/below the pad top and the podium cap.
PoseRules.COUNTDOWN = 3
PoseRules.RESULTS_TIME = 6
PoseRules.PAD_REARM = 1.5
PoseRules.PAD_HEIGHT = 4
PoseRules.MAX_LANES = 3
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

function PoseRules.canBegin(phase: string?): boolean
	return phase == "lobby" or phase == "results"
end

function PoseRules.acceptsInput(phase: string?): boolean
	return phase == "play"
end

-- Where a fallen player goes back to: the podium while held there, else the lobby spawn.
function PoseRules.fallBack(phase: string?): string
	return if phase == "countdown" or phase == "play" then "podium" else "lobby"
end

-- The feet's offset from the START pad's top centre: inside `radius` on the flat and within
-- PAD_HEIGHT up or down.
function PoseRules.onPad(dx: number, dy: number, dz: number, radius: number): boolean
	return dx * dx + dz * dz <= radius * radius and math.abs(dy) < PoseRules.PAD_HEIGHT
end

export type Pad = { off: boolean, armAt: number }

-- A freshly armed pad: it fires only after the player was seen off it and PAD_REARM passed.
function PoseRules.newPad(now: number): Pad
	return { off = false, armAt = now + PoseRules.PAD_REARM }
end

-- One tick of the pad: true when this step on it starts a game (the pad then needs a step
-- off before it fires again).
function PoseRules.padStep(pad: Pad, on: boolean, now: number): boolean
	if not on then
		pad.off = true
		return false
	end
	if pad.off and now >= pad.armAt then
		pad.off = false
		pad.armAt = now + PoseRules.PAD_REARM
		return true
	end
	return false
end

-- A podium lane for a Begin. `used[lane]` is "busy" (a countdown or game holds it) or
-- "results" (a results-card player still stands on it); nil is free. Returns the lane (nil:
-- every podium is busy) and whether a results-card player must be moved off it first.
function PoseRules.pickLane(used: { [number]: string }, count: number, prefer: number?): (number?, boolean)
	local n = math.min(count, PoseRules.MAX_LANES)
	if prefer and prefer >= 1 and prefer <= n and used[prefer] == nil then
		return prefer, false
	end
	for lane = 1, n do
		if used[lane] == nil then
			return lane, false
		end
	end
	for lane = 1, n do
		if used[lane] == "results" then
			return lane, true
		end
	end
	return nil, false
end

function PoseRules.newBest(best: number, cleared: number): number
	return math.max(best, math.floor(cleared))
end

return PoseRules
