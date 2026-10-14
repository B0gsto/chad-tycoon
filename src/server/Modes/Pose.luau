--!strict
--[[
	Modes.Pose: POSE COPY, a solo mini-game (docs/minigames.md). Arena: World.PoseStage
	(context.world.pose); rules: Modes.PoseRules (pure).

	Walking in through the mode's plaza gate (Course.crossedGate) or the "ModeStart"
	{ mode = "pose" } action starts a run: the player is put on their podium (playerSpot,
	both chads facing the audience) and held still (HumanoidRootPart anchored, no jump).
	The rival chad beside them (built locally by Fx.Pose on rivalSpot) shows a growing
	sequence of flexes (PoseRules.sequence, seeded per run); the player copies it with the
	"PoseInput" action { flex = 1..4, step = n } (n = 1 for the round's first flex). The
	server validates every press in order (PoseRules.press) and times each one out after
	PoseRules.INPUT_TIMEOUT. A wrong or slow flex costs a heart and the round replays; no
	hearts left ends the run. Clearing PoseRules.PASS_ROUND rounds passes the test and pays
	(once per run) through GameModes.modeReward + GameModes.payReward: the full pack on the
	first clear or after the cooldown, else the repeat share. The run then goes on for a
	best (the longest sequence copied) until the hearts run out or MAX_ROUND is cleared.
	After the finish the player stands free on the stage (the exit pad or the finish card's
	buttons take them away); the HUD's quit ("ModeQuit") ends a run early.

	Notify (kind = "Mode", mode = "pose"):
	  "start" { best, clears, hearts, maxHearts, passRound, maxRound, timeout, playerPos,
	            rivalPos, facing }                 feet positions (Vector3), facing: both chads
	  "round" { round, seq, step, lead, length, hearts, replay }
	                                               seq: the round's flex indexes; the rival shows
	                                               one every `step` s after `lead`; the player's
	                                               turn starts `length` s after this arrives
	  "clear" { round, next, passed }             the round was copied (`next` comes up)
	  "miss"  { hearts, reason, step, expected }  reason: "wrong" | "slow"
	  "pass"  { round, cash, full, packCash, repeatCash, pay }
	                                               pay: "first" | "full" | "repeat"
	  "win" / "lose" { cleared, best, prevBest, newBest, passed, cash, full, packCash,
	            repeatCash, pay }                  win = passed this run (cash: what the pass paid)
	  "stop"  { reason }                          the stub's: quit, left, switch, ...
	Snapshot modes.pose: { running, best, clears, cooldownEnds, rewardPreview, round, hearts }.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Economy = require(ReplicatedStorage.Shared.Economy)

local Course = require(script.Parent.Course)
local PoseRules = require(script.Parent.PoseRules)

local ID = "pose"
-- Feet are about this far under the HumanoidRootPart's centre (R15 default rig).
local FEET_BELOW_ROOT = 3
-- The turn opens this much before the client's show ends (the "round" notify's trip).
local TURN_EARLY = 0.35
-- Presses closer together than this are a double tap and ignored.
local PRESS_GAP = 0.06
-- A player not running stands "in the arena" within this margin of its deck.
local ARENA_MARGIN = 4

local Pose = {}

type Held = { root: BasePart, humanoid: Humanoid?, jumpHeight: number, jumpPower: number }

type Run = {
	startedAt: number,
	seq: { number },
	round: number,
	done: number,
	hearts: number,
	-- "intro" | "gap" (waiting for the next show) | "show" | "input"
	phase: string,
	nextAt: number,
	turnAt: number,
	deadline: number,
	lastPress: number,
	replay: boolean,
	cleared: number,
	prevBest: number,
	passed: boolean,
	pay: { [string]: any }?,
	held: Held?,
}

function Pose.create(GameModes: any, context: { [string]: any }): any
	local built = context.world and context.world.pose
	local Tycoon = context.Tycoon
	local def: any = { id = ID }
	local runs: { [Player]: Run } = {}
	local lastPos: { [Player]: Vector3 } = {}

	local function record(session: any): { best: number, clears: number, lastRewardAt: number }
		return session.profile.modes[ID]
	end

	local function toSpawn(player: Player)
		GameModes.teleport(player, built.spawn.Position, built.spawn.LookVector)
	end

	-- Holds the player still on their podium (the arrow keys flex, they must not walk).
	local function hold(player: Player): Held?
		local root = GameModes.root(player)
		if not root then
			return nil
		end
		local humanoid = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
		local held: Held = {
			root = root,
			humanoid = humanoid,
			jumpHeight = if humanoid then humanoid.JumpHeight else 7.2,
			jumpPower = if humanoid then humanoid.JumpPower else 50,
		}
		root.AssemblyLinearVelocity = Vector3.zero
		root.Anchored = true
		if humanoid then
			humanoid.JumpHeight = 0
			humanoid.JumpPower = 0
		end
		return held
	end

	local function unhold(held: Held?)
		if not held then
			return
		end
		held.root.Anchored = false
		if held.humanoid then
			held.humanoid.JumpHeight = held.jumpHeight
			held.humanoid.JumpPower = held.jumpPower
		end
	end

	-- The pay fields of a "pass" / "win" / "lose" payload (zeros before a pass).
	local function payFields(payload: { [string]: any }, run: Run)
		local pay: any = run.pay or {}
		payload.cash = pay.cash or 0
		payload.full = pay.full == true
		payload.packCash = pay.packCash or 0
		payload.repeatCash = pay.repeatCash or 0
		payload.pay = pay.pay or "none"
	end

	local function beginRound(player: Player, run: Run)
		local now = os.clock()
		local step = PoseRules.showStep(run.round)
		local length = PoseRules.showLength(run.round)
		run.phase = "show"
		run.done = 0
		run.turnAt = now + length - TURN_EARLY
		run.deadline = now + length + PoseRules.INPUT_TIMEOUT
		GameModes.notify(player, "round", ID, {
			round = run.round,
			seq = table.move(run.seq, 1, run.round, 1, {}),
			step = step,
			lead = PoseRules.SHOW_LEAD,
			length = length,
			hearts = run.hearts,
			replay = run.replay,
		})
		run.replay = false
	end

	-- The end of a run (hearts out, or MAX_ROUND cleared): saves the best, sends "win" (the
	-- test was passed this run) or "lose" and lets the player go (they stay on the stage).
	local function finish(player: Player, run: Run)
		local session = GameModes.session(player)
		runs[player] = nil
		unhold(run.held)
		if not session then
			return
		end
		local rec = record(session)
		rec.best = PoseRules.newBest(rec.best, run.cleared)
		local payload: { [string]: any } = {
			cleared = run.cleared,
			best = rec.best,
			prevBest = run.prevBest,
			newBest = run.cleared > run.prevBest,
			passed = run.passed,
		}
		payFields(payload, run)
		GameModes.notify(player, if run.passed then "win" else "lose", ID, payload)
		Tycoon.markDirty(session)
		GameModes.refresh(player)
	end

	-- The run just cleared PASS_ROUND: one pay per run. Full on the first clear ever or after
	-- the cooldown; inside it the repeat share.
	local function pass(player: Player, run: Run)
		local session = GameModes.session(player)
		if not session or run.passed then
			return
		end
		run.passed = true
		local rec = record(session)
		local first = rec.clears == 0
		local priced = GameModes.modeReward(session, ID, first)
		local kind = if first then "first" elseif priced.full then "full" else "repeat"
		if not priced.full then
			priced.cash = priced.repeatCash
		end
		rec.clears += 1
		rec.best = PoseRules.newBest(rec.best, run.cleared)
		local root = GameModes.root(player)
		local paid = GameModes.payReward(player, ID, priced, root and root.Position)
		run.pay = { cash = paid.cash, full = paid.full, packCash = paid.packCash, repeatCash = paid.repeatCash, pay = kind }
		local payload: { [string]: any } = { round = run.cleared }
		payFields(payload, run)
		GameModes.notify(player, "pass", ID, payload)
		GameModes.refresh(player)
	end

	local function miss(player: Player, run: Run, reason: string)
		run.hearts -= 1
		GameModes.notify(player, "miss", ID, {
			hearts = run.hearts,
			reason = reason,
			step = run.done + 1,
			expected = run.seq[run.done + 1],
		})
		if run.hearts <= 0 then
			finish(player, run)
			return
		end
		run.phase = "gap"
		run.replay = true
		run.nextAt = os.clock() + PoseRules.MISS_GAP
	end

	local function clear(player: Player, run: Run)
		run.cleared = math.max(run.cleared, run.round)
		local passedNow = PoseRules.passed(run.cleared) and not run.passed
		if run.round >= PoseRules.MAX_ROUND then
			GameModes.notify(player, "clear", ID, { round = run.round, next = run.round, passed = true })
			if passedNow then
				pass(player, run)
			end
			finish(player, run)
			return
		end
		run.round += 1
		run.phase = "gap"
		run.nextAt = os.clock() + PoseRules.ROUND_GAP
		GameModes.notify(player, "clear", ID, { round = run.cleared, next = run.round, passed = run.passed or passedNow })
		if passedNow then
			pass(player, run)
		end
	end

	function def.running(player: Player): boolean
		return runs[player] ~= nil
	end

	function def.start(player: Player, teleport: boolean, _options: { [string]: any }?): boolean
		local session = GameModes.session(player)
		if not session or not built then
			return false
		end
		local old = runs[player]
		if old then
			-- Again from the finish card or the gate while a run is on: a fresh run.
			unhold(old.held)
			runs[player] = nil
		end
		local rec = record(session)
		local seed = (player.UserId % 100000) * 7919 + math.floor(os.clock() * 1000) % 1000003
		local run: Run = {
			startedAt = os.clock(),
			seq = PoseRules.sequence(seed, PoseRules.MAX_ROUND),
			round = 1,
			done = 0,
			hearts = PoseRules.HEARTS,
			phase = "intro",
			nextAt = os.clock() + PoseRules.INTRO,
			turnAt = math.huge,
			deadline = math.huge,
			lastPress = 0,
			replay = false,
			cleared = 0,
			prevBest = rec.best,
			passed = false,
			pay = nil,
			held = nil,
		}
		runs[player] = run
		local spot: CFrame = built.playerSpot
		if teleport or old then
			GameModes.teleport(player, spot.Position, spot.LookVector)
		end
		run.held = hold(player)
		GameModes.notify(player, "start", ID, {
			best = rec.best,
			clears = rec.clears,
			hearts = run.hearts,
			maxHearts = PoseRules.HEARTS,
			passRound = PoseRules.PASS_ROUND,
			maxRound = PoseRules.MAX_ROUND,
			timeout = PoseRules.INPUT_TIMEOUT,
			playerPos = spot.Position,
			rivalPos = built.rivalSpot.Position,
			facing = spot.LookVector,
		})
		GameModes.refresh(player)
		return true
	end

	function def.stop(player: Player, reason: string)
		local run = runs[player]
		if not run then
			return
		end
		runs[player] = nil
		unhold(run.held)
		if reason ~= "leave" then
			GameModes.notify(player, "stop", ID, { reason = reason })
			GameModes.refresh(player)
		end
	end

	-- Exit pad and falls for anyone on the deck without a run (after a finish).
	local function idleInArena(player: Player, pos: Vector3, feetY: number)
		local a = PoseRules.ARENA
		if math.abs(pos.X - a.x) > a.sizeX / 2 + ARENA_MARGIN or math.abs(pos.Z - a.z) > a.sizeZ / 2 + ARENA_MARGIN then
			return
		end
		local exit = built.exit.Position
		local flat = Vector3.new(pos.X - exit.X, 0, pos.Z - exit.Z)
		if flat.Magnitude <= built.exitRadius and math.abs(feetY - built.top) < 4 then
			GameModes.toGates(player)
		elseif feetY < built.top - PoseRules.FALL_BELOW then
			toSpawn(player)
		end
	end

	function def.tick(player: Player, root: BasePart, _now: number)
		local pos = root.Position
		local prev = lastPos[player]
		lastPos[player] = pos
		local feetY = pos.Y - FEET_BELOW_ROOT
		local run = runs[player]
		if not run then
			if prev and feetY < Course.PLAZA.top + 8 and Course.crossedGate(def.slot, prev.X, prev.Z, pos.X, pos.Z) then
				GameModes.start(player, ID, true)
			elseif built then
				idleInArena(player, pos, feetY)
			end
			return
		end
		if not built then
			return
		end
		-- A respawned character is a new root: hold that one (and put it back on the podium).
		if not run.held or run.held.root ~= root then
			local spot: CFrame = built.playerSpot
			GameModes.teleport(player, spot.Position, spot.LookVector)
			run.held = hold(player)
		end
		local clock = os.clock()
		if (run.phase == "intro" or run.phase == "gap") and clock >= run.nextAt then
			beginRound(player, run)
		elseif run.phase == "show" and clock >= run.turnAt then
			run.phase = "input"
		elseif run.phase == "input" and clock > run.deadline then
			miss(player, run, "slow")
		end
	end

	-- One flex of the player's turn: { flex = 1..4, step = the press's place in the round }.
	-- Out-of-turn, repeated or stale presses are ignored (never a miss: a lag spike must not
	-- cost a heart).
	Tycoon.addAction("PoseInput", function(session: any, data: { [string]: any })
		local player = session.player
		local run = runs[player]
		if not run then
			return
		end
		local clock = os.clock()
		if run.phase == "show" and clock >= run.turnAt then
			run.phase = "input"
		end
		if run.phase ~= "input" or clock - run.lastPress < PRESS_GAP then
			return
		end
		local flex, step = data.flex, data.step
		if type(flex) ~= "number" or type(step) ~= "number" or step ~= run.done + 1 then
			return
		end
		if flex ~= math.floor(flex) or flex < 1 or flex > #PoseRules.FLEXES then
			return
		end
		run.lastPress = clock
		local result = PoseRules.press(run.seq, run.round, run.done, flex)
		if result == "wrong" then
			miss(player, run, "wrong")
			return
		end
		run.done += 1
		run.deadline = clock + PoseRules.INPUT_TIMEOUT
		if result == "clear" then
			clear(player, run)
		end
	end)

	function def.rewardPreview(player: Player): { [string]: any }
		local session = GameModes.session(player)
		if not session then
			return { cash = 0, full = false, packCash = 0, repeatCash = 0 }
		end
		local r = GameModes.modeReward(session, ID, record(session).clears == 0)
		return { cash = r.cash, full = r.full, packCash = r.packCash, repeatCash = r.repeatCash }
	end

	function def.snapshot(player: Player): { [string]: any }
		local session = GameModes.session(player)
		if not session then
			return { running = false }
		end
		local rec = record(session)
		local run = runs[player]
		return {
			running = run ~= nil,
			best = rec.best,
			clears = rec.clears,
			cooldownEnds = rec.lastRewardAt + Economy.MODE_REWARD_COOLDOWN,
			rewardPreview = def.rewardPreview(player),
			round = if run then run.round else 0,
			hearts = if run then run.hearts else 0,
		}
	end

	Players.PlayerRemoving:Connect(function(player)
		lastPos[player] = nil
		runs[player] = nil
	end)

	return def
end

return Pose
