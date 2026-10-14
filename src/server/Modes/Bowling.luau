--!strict
--[[
	Modes.Bowling: DUMBBELL BOWL, a solo mini-game (docs/minigames.md). Arena: World.BowlingLane
	(context.world.bowling); rules: Modes.BowlingRules (pure, tested in tests/bowling.luau).

	A run goes lobby -> countdown -> play -> results -> lobby (docs/minigames.md, "Lobby
	first, then the game"). The plaza gate or "ModeStart" { mode = "bowling" } lands the
	player on the lobby spawn (phase "lobby": nothing timed, scored or paid). The START pad
	(feet within startRadius, after BowlingRules.REARM seconds in the lobby) or "BowlingBegin"
	moves them to the foul line (rollStart) for a BowlingRules.COUNTDOWN "3, 2, 1"; then a game
	of BowlingRules.FRAMES frames. On the player's turn ("ready") the HUD sweeps an aim arrow
	and a power meter and sends "BowlingRoll" { aim, power }; the server clamps both, plays
	the ball in pure code (BowlingRules.roll with a fresh seed) and sends the result ("roll")
	for the client to animate, so nothing on the lane is Roblox physics. The next "ready"
	comes when that animation is over. After the last ball: "win" (score >= PASS_SCORE: best,
	clears and the pay) or "lose", phase "results"; PLAY AGAIN is "BowlingBegin", LOBBY is
	"BowlingLobby", and with no input the player is back in the lobby after
	BowlingRules.RESULTS_SECONDS. The EXIT arch (lobby or results only) or "ModeQuit" ends the
	run (stop "quit", back to the gates). A fall goes back to the lobby spawn in the lobby,
	else to the foul line.

	PROTOCOL (for the client). Notify: kind = "Mode", mode = "bowling", event =
	  "start"     { phase = "lobby", best, clears, rewardPreview, target, maxScore, frames,
	              choice, balls, lane, pins, ball, pin, aimSpread, countdown, resultsSeconds }
	              lane = { x, z (foul line), top, width, length, gutter }, pins = { { x, d } }
	              (lane space: BowlingRules header); ball / pin = their sizes ({ radius,
	              halfLength } / { radius, height }); choice = the picked dumbbell (1..balls)
	  "lobby"     { best, clears, rewardPreview, choice } (back in the lobby: hide the
	              results card; also sent after "BowlingLobby" and the auto-return)
	  "ball"      { choice } (a "BowlingBall" pick was taken)
	  "countdown" { seconds } (3, 2, 1; the first "ready" follows when it ends)
	  "ready"     { frame, shot, ball, standing, card, total, rack } (your turn; shot = ball
	              number in the frame 1..3, ball = the picked dumbbell, rack = a full set)
	  "roll"      { aim, power, path, falls, knocked, gutter, mark, reset, frame, shot, ball,
	              card, total, over, wait } (path / falls: BowlingRules.Roll; ball = the
	              picked dumbbell 1..4 for its colour; wait = seconds until the next event)
	  "win"       { score, target, best, newBest, first, cash, full, pay, packCash,
	              repeatCash, cooldownEnds, repeatEnds, lobbyIn } (pay = "full" | "repeat" |
	              "none": the repeat share pays once per BowlingRules.REPEAT_GAP; repeatEnds =
	              when the next is due, 0 = now; lobbyIn = seconds until the auto-return)
	  "lose"      { score, target, best, newBest, lobbyIn }
	  "stop"      { reason }
	Actions (Tycoon "Action" remote, fields on the action table):
	  "BowlingBegin" {}          lobby or results only: a new game (countdown, then play).
	                             "BowlingAgain" is an alias (older clients).
	  "BowlingBall" { choice }   lobby or results only; integer 1..BowlingRules.BALL_CHOICES.
	  "BowlingRoll" { aim, power } play, on the player's turn only; aim -1..1, power 0..1.
	  "BowlingLobby" {}          results only: back to the lobby now.
	Snapshot modes.bowling: { running, phase, choice, best, clears, cooldownEnds,
	  rewardPreview, repeatEnds, target } (phase = "lobby" | "countdown" | "play" | "results").
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
	-- "lobby" | "countdown" | "play" | "results" (BowlingRules.PHASES).
	phase: string,
	-- In play: "aim" waiting for this player's roll, "rolling" a ball is being animated.
	turn: string,
	-- Bumped by every phase change and roll, so a stale delayed step does nothing.
	token: number,
	lastRollAt: number,
	-- The picked dumbbell (1..BowlingRules.BALL_CHOICES); run state only, not saved.
	choice: number,
	-- os.clock() from which the START pad works (BowlingRules.REARM after landing in the lobby).
	armAt: number,
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

	-- Where a game is played: the foul line (the arena's spawn if the lane has none).
	local function toPlay(player: Player)
		local at = built.rollStart or built.spawn
		GameModes.teleport(player, at.Position, at.LookVector)
	end

	-- The lobby spawn (the arena's spawn until the lobby is built).
	local function toLobby(player: Player)
		local at = built.lobbySpawn or built.spawn
		GameModes.teleport(player, at.Position, at.LookVector)
	end

	-- Feet on a pad part (its top face, within `radius` across).
	local function feetOn(pad: BasePart?, radius: number?, pos: Vector3, feetY: number): boolean
		if not pad or type(radius) ~= "number" then
			return false
		end
		local c = pad.Position
		return BowlingRules.onPad(pos.X - c.X, feetY - (c.Y + pad.Size.Y / 2), pos.Z - c.Z, radius)
	end

	-- What the client needs to draw the lane, the pins and the dumbbell (lane space).
	local function laneInfo(): { [string]: any }
		local lane = BowlingRules.LANE
		local foul = (built.rollStart or built.spawn).Position
		local pins = {}
		for i, spot in BowlingRules.PIN_SPOTS do
			pins[i] = { x = spot.x, d = spot.d }
		end
		return {
			lane = {
				x = if built.lane then built.lane.Position.X else foul.X,
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
		run.turn = "aim"
		local game = run.game
		local card, total = cardOf(run)
		local rack = true
		for _, up in game.standing do
			rack = rack and up
		end
		GameModes.notify(player, "ready", ID, {
			frame = game.frame,
			shot = #game.frames[game.frame] + 1,
			ball = run.choice,
			standing = table.clone(game.standing),
			card = card,
			total = total,
			rack = rack,
		})
	end

	-- Back in the lobby (entry, the results card's LOBBY, or its auto-return).
	local function enterLobby(player: Player, run: Run, teleport: boolean)
		run.phase = "lobby"
		run.turn = "none"
		run.token += 1
		run.armAt = os.clock() + BowlingRules.REARM
		if teleport then
			toLobby(player)
		end
	end

	local function lobbyInfo(session: any, run: Run): { [string]: any }
		local rec = record(session)
		return {
			best = rec.best,
			clears = rec.clears,
			rewardPreview = def.rewardPreview(session.player),
			choice = run.choice,
		}
	end

	-- Results card up: back to the lobby after RESULTS_SECONDS unless the player moved on.
	local function returnLater(player: Player, run: Run)
		local mine = run.token
		task.delay(BowlingRules.RESULTS_SECONDS, function()
			if runs[player] ~= run or run.token ~= mine or run.phase ~= "results" then
				return
			end
			local session = GameModes.session(player)
			if not session then
				return
			end
			enterLobby(player, run, true)
			GameModes.notify(player, "lobby", ID, lobbyInfo(session, run))
			GameModes.refresh(player)
		end)
	end

	-- The last ball is down: best, clears and the pay on a pass; then the results card.
	local function finish(player: Player, run: Run)
		run.phase = "results"
		run.turn = "none"
		run.token += 1
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
		returnLater(player, run)
		if not BowlingRules.passed(score) then
			Tycoon.markDirty(session)
			GameModes.notify(player, "lose", ID, {
				score = score,
				target = BowlingRules.PASS_SCORE,
				best = rec.best,
				newBest = newBest,
				lobbyIn = BowlingRules.RESULTS_SECONDS,
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
			lobbyIn = BowlingRules.RESULTS_SECONDS,
		})
		GameModes.refresh(player)
	end

	-- "BowlingBegin" (or the START pad): a fresh game at the foul line after the countdown.
	local function begin(player: Player, run: Run)
		if not BowlingRules.canBegin(run.phase) then
			return
		end
		run.phase = "countdown"
		run.turn = "none"
		run.game = BowlingRules.newGame()
		run.token += 1
		run.startedAt = os.clock()
		local mine = run.token
		toPlay(player)
		GameModes.notify(player, "countdown", ID, { seconds = BowlingRules.COUNTDOWN })
		GameModes.refresh(player)
		task.delay(BowlingRules.COUNTDOWN, function()
			if runs[player] ~= run or run.token ~= mine then
				return
			end
			run.phase = "play"
			-- The first ball can go straight away.
			run.lastRollAt = 0
			sendReady(player, run)
			GameModes.refresh(player)
		end)
	end

	function def.running(player: Player): boolean
		return runs[player] ~= nil
	end

	function def.start(player: Player, teleport: boolean, _options: { [string]: any }?): boolean
		local session = GameModes.session(player)
		if not session or not built then
			return false
		end
		-- "ModeStart" again mid-run starts over in the lobby but keeps the picked dumbbell.
		local old = runs[player]
		if old then
			old.token += 1
		end
		local run: Run = {
			startedAt = os.clock(),
			game = BowlingRules.newGame(),
			phase = "lobby",
			turn = "none",
			token = 0,
			lastRollAt = 0,
			choice = if old then old.choice else 1,
			armAt = 0,
		}
		runs[player] = run
		enterLobby(player, run, teleport)
		local payload = laneInfo()
		for key, value in lobbyInfo(session, run) do
			payload[key] = value
		end
		payload.phase = run.phase
		payload.target = BowlingRules.PASS_SCORE
		payload.maxScore = BowlingRules.MAX_SCORE
		payload.frames = BowlingRules.FRAMES
		payload.balls = BowlingRules.BALL_CHOICES
		payload.countdown = BowlingRules.COUNTDOWN
		payload.resultsSeconds = BowlingRules.RESULTS_SECONDS
		GameModes.notify(player, "start", ID, payload)
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
		local run = runs[player]
		if not run then
			if prev and feetY < Course.PLAZA.top + 8 and Course.crossedGate(def.slot, prev.X, prev.Z, pos.X, pos.Z) then
				GameModes.start(player, ID, true)
			end
			return
		end
		if not built then
			return
		end
		if BowlingRules.canExit(run.phase) and feetOn(built.exit, built.exitRadius, pos, feetY) then
			def.stop(player, "quit")
			GameModes.toGates(player)
			return
		end
		if feetY < built.top - BowlingRules.FALL_BELOW then
			if BowlingRules.fallTo(run.phase) == "lobby" then
				toLobby(player)
			else
				toPlay(player)
			end
			return
		end
		local onStart = feetOn(built.startPad, built.startRadius, pos, feetY)
		if BowlingRules.padStarts(run.phase, onStart, os.clock(), run.armAt) then
			begin(player, run)
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
		local run = runs[player]
		return {
			running = run ~= nil,
			phase = if run then run.phase else nil,
			choice = if run then run.choice else nil,
			best = rec.best,
			clears = rec.clears,
			cooldownEnds = rec.lastRewardAt + Economy.MODE_REWARD_COOLDOWN,
			rewardPreview = def.rewardPreview(player),
			repeatEnds = repeatEnds(rec),
			target = BowlingRules.PASS_SCORE,
		}
	end

	-- One ball: only in play, on the player's turn, at most every MIN_ROLL_GAP; aim and
	-- power clamped.
	Tycoon.addAction("BowlingRoll", function(session: any, data: { [string]: any })
		local player = session.player
		local run = runs[player]
		local clock = os.clock()
		if not run or not BowlingRules.canRoll(run.phase) then
			return
		end
		if run.turn ~= "aim" or clock - run.lastRollAt < MIN_ROLL_GAP then
			-- A rejected roll on the player's turn: say "ready" again so the HUD shows its
			-- aim controls instead of waiting for a "roll" that never comes. (Mid-ball the
			-- delayed "ready" is on its way.)
			if run.turn == "aim" then
				sendReady(player, run)
			end
			return
		end
		run.lastRollAt = clock
		local game = run.game
		local frame = game.frame
		local shot = #game.frames[frame] + 1
		local result = BowlingRules.roll(game.standing, data.aim, data.power, seeds:NextInteger(1, 2147483646))
		local fallen = {}
		for _, fall in result.falls do
			table.insert(fallen, fall.pin)
		end
		local mark, reset = BowlingRules.applyRoll(game, fallen)
		local card, total = cardOf(run)
		local wait = result.duration + SETTLE + (if reset and not game.over then RESET else 0)
		run.turn = "rolling"
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
			shot = shot,
			ball = run.choice,
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

	-- A new game: from the lobby (the HUD's PLAY) or the results card (PLAY AGAIN).
	local function onBegin(session: any, _data: { [string]: any })
		local run = runs[session.player]
		if run then
			begin(session.player, run)
		end
	end
	Tycoon.addAction("BowlingBegin", onBegin)
	-- The old results card's "again" button.
	Tycoon.addAction("BowlingAgain", onBegin)

	-- The ball rack: pick a dumbbell colour (lobby or results only).
	Tycoon.addAction("BowlingBall", function(session: any, data: { [string]: any })
		local player = session.player
		local run = runs[player]
		local choice = BowlingRules.ballChoice(data.choice)
		if not run or not choice or not BowlingRules.canPickBall(run.phase) then
			return
		end
		run.choice = choice
		GameModes.notify(player, "ball", ID, { choice = choice })
	end)

	-- The results card's LOBBY button.
	Tycoon.addAction("BowlingLobby", function(session: any, _data: { [string]: any })
		local player = session.player
		local run = runs[player]
		if not run or run.phase ~= "results" then
			return
		end
		enterLobby(player, run, true)
		GameModes.notify(player, "lobby", ID, lobbyInfo(session, run))
	end)

	Players.PlayerRemoving:Connect(function(player)
		lastPos[player] = nil
	end)

	return def
end

return Bowling
