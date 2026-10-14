--!strict
--[[
	Modes.Bowling: DUMBBELL BOWL, a solo mini-game (docs/minigames.md). Arena: World.BowlingLane
	(context.world.bowling); rules: Modes.BowlingRules (pure, tested in tests/bowling.luau).

	Walking in through the mode's plaza gate (Course.crossedGate) or the "ModeStart"
	{ mode = "bowling" } action starts a run on the lane's foul line (rollStart); the arena's
	exit pad (or the HUD's quit, "ModeQuit") ends it and brings the player back to the gates;
	a fall puts them back on the foul line.

	A run is one game of BowlingRules.FRAMES frames. On the player's turn ("ready") the HUD
	sweeps an aim arrow and a power meter and sends "BowlingRoll" { aim, power }; the server
	clamps both, plays the ball in pure code (BowlingRules.roll with a fresh seed) and sends
	the result ("roll") for the client to animate, so nothing on the lane is Roblox physics.
	The next "ready" comes when that animation is over. After the last ball the game ends
	with "win" (score >= PASS_SCORE: best, clears and the pay) or "lose"; "BowlingAgain"
	racks up a new game in the same run.

	Notify (kind = "Mode", mode = "bowling"):
	  "start"  { best, clears, target, maxScore, frames, lane, pins, ball, pin, aimSpread }
	           lane = { x, z (foul line), top, width, length, gutter }, pins = { { x, d } }
	           (lane space: BowlingRules header), ball / pin = their sizes
	  "ready"  { frame, ball, standing, card, total, rack } (your turn; rack = a full set)
	  "roll"   { aim, power, path, falls, knocked, mark, reset, frame, ball, card, total,
	           over, wait } (path / falls: BowlingRules.Roll; wait = seconds until "ready")
	  "win"    { score, target, best, newBest, first, cash, full, pay, packCash, repeatCash,
	           cooldownEnds, repeatEnds } (pay = "full" | "repeat" | "none": the repeat share
	           pays once per BowlingRules.REPEAT_GAP; repeatEnds = when the next is due, 0 = now)
	  "lose"   { score, target, best, newBest }
	  "again"  {} (a new game in the same run; a "ready" follows)
	  "stop"   { reason }
	Actions: "BowlingRoll" { aim, power }, "BowlingAgain" {}.
	Snapshot modes.bowling: { running, best, clears, cooldownEnds, rewardPreview, target }.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Economy = require(ReplicatedStorage.Shared.Economy)

local Course = require(script.Parent.Course)
local BowlingRules = require(script.Parent.BowlingRules)

local ID = "bowling"
-- Feet are about this far under the HumanoidRootPart's centre (R15 default rig).
local FEET_BELOW_ROOT = 3
-- After a ball's last pin falls: seconds for the pins to settle and the result to read,
-- plus the sweep when the rack is reset.
local SETTLE = 1.6
local RESET = 1.0
-- A roll sooner than this after the last one is ignored (the turn gate already blocks
-- rolls mid-animation; this stops a flood of remote calls).
local MIN_ROLL_GAP = 0.5

local Bowling = {}

type Run = {
	startedAt: number,
	game: BowlingRules.Game,
	-- "aim": waiting for this player's roll; "rolling": a ball is being animated; "done": over.
	phase: string,
	-- Bumped by every roll and new game, so a stale delayed "ready" does nothing.
	token: number,
	lastRollAt: number,
}

function Bowling.create(GameModes: any, context: { [string]: any }): any
	local built = context.world and context.world.bowling
	local Tycoon = context.Tycoon
	local def: any = { id = ID }
	local runs: { [Player]: Run } = {}
	local lastPos: { [Player]: Vector3 } = {}
	local seeds = Random.new()

	local function record(session: any): { best: number, clears: number, lastRewardAt: number }
		return session.profile.modes[ID]
	end

	-- When the next repeat share is due (os.time); 0 when it already is.
	local function repeatEnds(rec: any): number
		local last = rec.lastRepeatAt
		if BowlingRules.repeatDue(os.time(), last) then
			return 0
		end
		return last + BowlingRules.REPEAT_GAP
	end

	local function toSpawn(player: Player)
		local at = built.rollStart or built.spawn
		GameModes.teleport(player, at.Position, at.LookVector)
	end

	-- What the client needs to draw the lane, the pins and the dumbbell (lane space).
	local function laneInfo(): { [string]: any }
		local lane = BowlingRules.LANE
		local foul = built.rollStart.Position
		local pins = {}
		for i, spot in BowlingRules.PIN_SPOTS do
			pins[i] = { x = spot.x, d = spot.d }
		end
		return {
			lane = {
				x = built.lane.Position.X,
				z = foul.Z - 3,
				top = built.top,
				width = lane.width,
				length = lane.length,
				gutter = lane.gutter,
			},
			pins = pins,
			ball = { radius = BowlingRules.BALL.radius, halfLength = BowlingRules.BALL.halfLength },
			pin = { radius = BowlingRules.PIN.radius, height = BowlingRules.PIN.height },
			aimSpread = BowlingRules.AIM_SPREAD,
		}
	end

	local function cardOf(run: Run): ({ BowlingRules.CardFrame }, number)
		return BowlingRules.card(run.game.frames)
	end

	-- The player's turn: the next ball of the current frame.
	local function sendReady(player: Player, run: Run)
		run.phase = "aim"
		local game = run.game
		local card, total = cardOf(run)
		local rack = true
		for _, up in game.standing do
			rack = rack and up
		end
		GameModes.notify(player, "ready", ID, {
			frame = game.frame,
			ball = #game.frames[game.frame] + 1,
			standing = table.clone(game.standing),
			card = card,
			total = total,
			rack = rack,
		})
	end

	-- The last ball is down: best, clears and the pay on a pass.
	local function finish(player: Player, run: Run)
		run.phase = "done"
		local session = GameModes.session(player)
		if not session then
			return
		end
		local rec = record(session)
		local score = BowlingRules.score(run.game.frames)
		local newBest = score > rec.best
		if newBest then
			rec.best = score
		end
		if not BowlingRules.passed(score) then
			Tycoon.markDirty(session)
			GameModes.notify(player, "lose", ID, {
				score = score,
				target = BowlingRules.PASS_SCORE,
				best = rec.best,
				newBest = newBest,
			})
			GameModes.refresh(player)
			return
		end
		local first = rec.clears == 0
		local reward = GameModes.modeReward(session, ID, first)
		-- Inside the cooldown a pass still pays the smaller "run again" share, but only once
		-- per BowlingRules.REPEAT_GAP (stamped on the save, so a rejoin doesn't reset it).
		local pay = "full"
		local now = os.time()
		local stamps = rec :: any
		if not reward.full then
			if BowlingRules.repeatDue(now, stamps.lastRepeatAt) then
				reward.cash = reward.repeatCash
				pay = "repeat"
				stamps.lastRepeatAt = now
			else
				reward.cash = 0
				pay = "none"
			end
		end
		rec.clears += 1
		local paid = GameModes.payReward(player, ID, reward)
		GameModes.notify(player, "win", ID, {
			score = score,
			target = BowlingRules.PASS_SCORE,
			best = rec.best,
			newBest = newBest,
			first = first,
			cash = paid.cash,
			full = paid.full,
			pay = pay,
			packCash = paid.packCash,
			repeatCash = paid.repeatCash,
			cooldownEnds = rec.lastRewardAt + Economy.MODE_REWARD_COOLDOWN,
			repeatEnds = repeatEnds(rec),
		})
		GameModes.refresh(player)
	end

	local function newGame(run: Run)
		run.game = BowlingRules.newGame()
		run.token += 1
		run.phase = "aim"
	end

	function def.running(player: Player): boolean
		return runs[player] ~= nil
	end

	function def.start(player: Player, teleport: boolean, _options: { [string]: any }?): boolean
		local session = GameModes.session(player)
		if not session or not built then
			return false
		end
		local run: Run = { startedAt = os.clock(), game = BowlingRules.newGame(), phase = "aim", token = 0, lastRollAt = 0 }
		runs[player] = run
		if teleport then
			toSpawn(player)
		end
		local rec = record(session)
		local payload = laneInfo()
		payload.best = rec.best
		payload.clears = rec.clears
		payload.target = BowlingRules.PASS_SCORE
		payload.maxScore = BowlingRules.MAX_SCORE
		payload.frames = BowlingRules.FRAMES
		GameModes.notify(player, "start", ID, payload)
		sendReady(player, run)
		GameModes.refresh(player)
		return true
	end

	function def.stop(player: Player, reason: string)
		local run = runs[player]
		if not run then
			return
		end
		run.token += 1
		runs[player] = nil
		if reason ~= "leave" then
			GameModes.notify(player, "stop", ID, { reason = reason })
			GameModes.refresh(player)
		end
	end

	function def.tick(player: Player, root: BasePart, _now: number)
		local pos = root.Position
		local prev = lastPos[player]
		lastPos[player] = pos
		local feetY = pos.Y - FEET_BELOW_ROOT
		if not runs[player] then
			if prev and feetY < Course.PLAZA.top + 8 and Course.crossedGate(def.slot, prev.X, prev.Z, pos.X, pos.Z) then
				GameModes.start(player, ID, true)
			end
			return
		end
		if not built then
			return
		end
		local exit = built.exit.Position
		local flat = Vector3.new(pos.X - exit.X, 0, pos.Z - exit.Z)
		if flat.Magnitude <= built.exitRadius and math.abs(feetY - built.top) < 4 then
			def.stop(player, "quit")
			GameModes.toGates(player)
			return
		end
		if feetY < built.top - BowlingRules.FALL_BELOW then
			toSpawn(player)
		end
	end

	function def.rewardPreview(player: Player): { [string]: any }
		local session = GameModes.session(player)
		if not session then
			return { cash = 0, full = false, packCash = 0, repeatCash = 0 }
		end
		local rec = record(session)
		local r = GameModes.modeReward(session, ID, rec.clears == 0)
		-- The repeat share reads 0 until its gap is over.
		local repeatCash = if repeatEnds(rec) == 0 then r.repeatCash else 0
		return { cash = r.cash, full = r.full, packCash = r.packCash, repeatCash = repeatCash }
	end

	function def.snapshot(player: Player): { [string]: any }
		local session = GameModes.session(player)
		if not session then
			return { running = false }
		end
		local rec = record(session)
		return {
			running = runs[player] ~= nil,
			best = rec.best,
			clears = rec.clears,
			cooldownEnds = rec.lastRewardAt + Economy.MODE_REWARD_COOLDOWN,
			rewardPreview = def.rewardPreview(player),
			repeatEnds = repeatEnds(rec),
			target = BowlingRules.PASS_SCORE,
		}
	end

	-- One ball: only on the player's turn, at most every MIN_ROLL_GAP; aim and power clamped.
	Tycoon.addAction("BowlingRoll", function(session: any, data: { [string]: any })
		local player = session.player
		local run = runs[player]
		local clock = os.clock()
		if not run then
			return
		end
		if run.phase ~= "aim" or clock - run.lastRollAt < MIN_ROLL_GAP then
			-- A rejected roll on the player's turn: say "ready" again so the HUD shows its
			-- aim controls instead of waiting for a "roll" that never comes. (Mid-ball the
			-- delayed "ready" is on its way; after the game the result screen is up.)
			if run.phase == "aim" then
				sendReady(player, run)
			end
			return
		end
		run.lastRollAt = clock
		local game = run.game
		local frame = game.frame
		local ball = #game.frames[frame] + 1
		local result = BowlingRules.roll(game.standing, data.aim, data.power, seeds:NextInteger(1, 2147483646))
		local fallen = {}
		for _, fall in result.falls do
			table.insert(fallen, fall.pin)
		end
		local mark, reset = BowlingRules.applyRoll(game, fallen)
		local card, total = cardOf(run)
		local wait = result.duration + SETTLE + (if reset and not game.over then RESET else 0)
		run.phase = "rolling"
		run.token += 1
		local mine = run.token
		GameModes.notify(player, "roll", ID, {
			aim = result.aim,
			power = result.power,
			path = result.path,
			falls = result.falls,
			knocked = result.knocked,
			gutter = result.gutter,
			mark = mark,
			reset = reset,
			frame = frame,
			ball = ball,
			card = card,
			total = total,
			over = game.over,
			wait = wait,
		})
		task.delay(wait, function()
			if runs[player] ~= run or run.token ~= mine then
				return
			end
			if game.over then
				finish(player, run)
			else
				sendReady(player, run)
			end
		end)
	end)

	-- A new game after the last one ended (same run, same lane).
	Tycoon.addAction("BowlingAgain", function(session: any, _data: { [string]: any })
		local player = session.player
		local run = runs[player]
		if not run or run.phase ~= "done" then
			return
		end
		newGame(run)
		GameModes.notify(player, "again", ID, {})
		sendReady(player, run)
	end)

	Players.PlayerRemoving:Connect(function(player)
		lastPos[player] = nil
	end)

	return def
end

return Bowling
