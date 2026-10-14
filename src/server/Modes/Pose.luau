--!strict
--[[
	Modes.Pose: POSE COPY, a solo mini-game (docs/minigames.md). Arena: World.PoseStage
	(context.world.pose); rules: Modes.PoseRules (pure).

	Every visit runs lobby -> countdown -> play -> results -> lobby (docs/minigames.md, "Lobby
	first, then the game"). The gate (Course.crossedGate) or "ModeStart" { mode = "pose" }
	puts the player on lobbySpawn (phase lobby: free to walk, the rehearsal mirror's flexes
	are client-only, nothing is timed or paid). The START pad or "PoseBegin" takes one of up
	to three podium lanes, holds the player there (root anchored, no jump) and counts 3-2-1.
	Then the rival chad (built locally by Fx.Pose on rivalSpot) shows a growing sequence of
	flexes (PoseRules.sequence, seeded per game); the player copies it with "PoseInput". A
	wrong or slow flex costs a heart and the round replays; no hearts left ends the game.
	Copying PoseRules.PASS_ROUND flexes passes and pays once per game (GameModes.modeReward +
	payReward: the full pack on the first clear or after the cooldown, else the repeat share
	at most once per PoseRules.REPEAT_GAP); the game then goes on for a best (the longest
	sequence copied). The results phase frees the podium and returns the player to the lobby
	after PoseRules.RESULTS_TIME s. Only the lobby's EXIT pad (or "ModeQuit") leaves.

	PROTOCOL. Notify (kind = "Mode", mode = "pose"):
	  "start"     { phase = "lobby", best, clears, rewardPreview, maxHearts, passRound,
	                maxRound, timeout, lobbyPos, rivalPos, facing, mirrorPos? }
	                                       entered the mode (Vector3 positions; facing: the chads')
	  "countdown" { seconds, lane, playerPos, rivalPos, facing, hearts, maxHearts, passRound,
	                maxRound, timeout }    on the podium; play starts `seconds` s later
	  "round"     { round, seq, step, lead, length, hearts, replay }
	                                       seq: the round's flex indexes; the rival shows one every
	                                       `step` s after `lead`; the player's turn starts `length`
	                                       s after this arrives (the first round comes as play starts)
	  "clear"     { round, next, passed }  the round was copied (`next` comes up)
	  "miss"      { hearts, reason, step, expected }   reason: "wrong" | "slow"
	  "pass"      { round, cash, full, packCash, repeatCash, pay }
	                                       pay: "first" | "full" | "repeat" | "none"
	  "win" / "lose" { cleared, best, prevBest, newBest, passed, cash, full, packCash,
	                repeatCash, pay, resultsTime }
	                                       win = passed this game; phase results for resultsTime s
	  "lobby"     { reason, best, clears, rewardPreview }
	                                       back on lobbySpawn; reason: "timeout" | "button" |
	                                       "fall" | "full" | "bumped" (another player needed the
	                                       podium a results card was standing on)
	  "full"      { text }                 every podium is busy: the Begin was refused (lobby)
	  "stop"      { reason }               left the mode: "quit" (EXIT pad / ModeQuit), "left",
	                                       "respawn", "switch", "invalid" (moved off the arena)
	Actions:
	  "PoseBegin" {}                       phase lobby or results: take a podium, countdown
	  "PoseLobby" {}                       phase results: back to the lobby now
	  "PoseInput" { flex = 1..4, step = n }  phase play only (n = 1 for a round's first flex)
	Snapshot modes.pose: { running, phase, best, clears, cooldownEnds, rewardPreview, round,
	  hearts, lane }   phase: "lobby" | "countdown" | "play" | "results" (nil when not running)
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Economy = require(ReplicatedStorage.Shared.Economy)

local Course = require(script.Parent.Course)
local PoseRules = require(script.Parent.PoseRules)

local ID = "pose"
-- Feet are about this far under the HumanoidRootPart's centre (R15 default rig).
local FEET_BELOW_ROOT = 3
-- Presses are taken this long before the client's show ends (the "round" notify's trip, and
-- a player who already knows the sequence's start may begin while the last flex shows).
local TURN_EARLY = 0.8
-- The first flex's deadline gets this much extra: the client's bar starts when the "round"
-- notify arrives (after its trip), the server's clock when it was sent.
local TURN_GRACE = 0.75
-- A held player whose feet end up this far from their podium (moved away by something
-- else) has the mode ended as "invalid" (walking free: PoseRules.LEAVE_MARGIN off the deck).
local LEAVE_SPOT = 30
-- A player not in the mode stands "in the arena" within this margin of its deck.
local ARENA_MARGIN = 4
-- Begin requests closer together than this are dropped (spam from a held button).
local BEGIN_GAP = 0.4
local START_RADIUS = 5
local FULL_TEXT = "Every posing podium is busy. Try again in a moment!"

local Pose = {}

type Held = { root: BasePart, humanoid: Humanoid?, jumpHeight: number, jumpPower: number }

type Run = {
	seq: { number },
	round: number,
	done: number,
	hearts: number,
	-- "gap" (waiting for the next show) | "show" | "input"
	stage: string,
	nextAt: number,
	turnAt: number,
	deadline: number,
	replay: boolean,
	cleared: number,
	prevBest: number,
	passed: boolean,
	pay: { [string]: any }?,
}

type Entry = {
	-- "lobby" | "countdown" | "play" | "results"
	phase: string,
	-- The podium lane: held in countdown/play, still stood on in results, nil in the lobby.
	lane: number?,
	spot: CFrame?,
	run: Run?,
	phaseEnds: number,
	pad: PoseRules.Pad,
	held: Held?,
	lastBegin: number,
}

function Pose.create(GameModes: any, context: { [string]: any }): any
	local built = context.world and context.world.pose
	local Tycoon = context.Tycoon
	local def: any = { id = ID }
	local entries: { [Player]: Entry } = {}
	local lastPos: { [Player]: Vector3 } = {}

	local function record(session: any): { best: number, clears: number, lastRewardAt: number, lastRepeatAt: number? }
		return session.profile.modes[ID]
	end

	-- When the repeat share last paid (os.time; an extra field on the saved record).
	local function repeatAt(rec: { [string]: any }): number
		local at = rec.lastRepeatAt
		return if type(at) == "number" and at == at and at >= 0 and at < math.huge then at else 0
	end

	-- Anchors, with fallbacks for an arena built before the lobby existed.
	local function lobbySpawn(): CFrame
		return built.lobbySpawn or built.spawn
	end

	local function lanes(): { CFrame }
		return built.playerSpots or { built.playerSpot or built.spawn }
	end

	local function teleportTo(player: Player, cf: CFrame)
		GameModes.teleport(player, cf.Position, cf.LookVector)
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

	local function unhold(entry: Entry)
		local held = entry.held
		entry.held = nil
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

	-- Back to the lobby spawn (from results, a refused Begin or a fall there).
	local function toLobby(player: Player, entry: Entry, reason: string)
		unhold(entry)
		entry.phase = "lobby"
		entry.run = nil
		entry.lane = nil
		entry.spot = nil
		entry.pad = PoseRules.newPad(os.clock())
		teleportTo(player, lobbySpawn())
		local session = GameModes.session(player)
		if session then
			local rec = record(session)
			GameModes.notify(player, "lobby", ID, {
				reason = reason,
				best = rec.best,
				clears = rec.clears,
				rewardPreview = def.rewardPreview(player),
			})
		end
		GameModes.refresh(player)
	end

	local function beginRound(player: Player, run: Run)
		local now = os.clock()
		local step = PoseRules.showStep(run.round)
		local length = PoseRules.showLength(run.round)
		run.stage = "show"
		run.done = 0
		run.turnAt = now + length - TURN_EARLY
		run.deadline = now + length + PoseRules.INPUT_TIMEOUT + TURN_GRACE
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

	-- The end of a game (hearts out, or MAX_ROUND cleared): saves the best, sends "win" (the
	-- test was passed this game) or "lose", frees the podium and shows the results phase.
	local function finish(player: Player, entry: Entry, run: Run)
		unhold(entry)
		entry.run = nil
		entry.phase = "results"
		entry.phaseEnds = os.clock() + PoseRules.RESULTS_TIME
		local session = GameModes.session(player)
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
			resultsTime = PoseRules.RESULTS_TIME,
		}
		payFields(payload, run)
		GameModes.notify(player, if run.passed then "win" else "lose", ID, payload)
		Tycoon.markDirty(session)
		GameModes.refresh(player)
	end

	-- The game just cleared PASS_ROUND: one pay per game. Full on the first clear ever or
	-- after the cooldown; inside it the repeat share.
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
			-- The repeat share pays at most once per PoseRules.REPEAT_GAP (saved with the
			-- record, so a rejoin does not reset it); between those a pass pays nothing.
			local now = os.time()
			if PoseRules.repeatReady(repeatAt(rec), now) then
				priced.cash = priced.repeatCash
				rec.lastRepeatAt = now
			else
				priced.cash = 0
				kind = "none"
			end
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

	local function miss(player: Player, entry: Entry, run: Run, reason: string)
		run.hearts -= 1
		GameModes.notify(player, "miss", ID, {
			hearts = run.hearts,
			reason = reason,
			step = run.done + 1,
			expected = run.seq[run.done + 1],
		})
		if run.hearts <= 0 then
			finish(player, entry, run)
			return
		end
		run.stage = "gap"
		run.replay = true
		run.nextAt = os.clock() + PoseRules.MISS_GAP
		GameModes.refresh(player)
	end

	local function clear(player: Player, entry: Entry, run: Run)
		run.cleared = math.max(run.cleared, run.round)
		local passedNow = PoseRules.passed(run.cleared) and not run.passed
		if run.round >= PoseRules.MAX_ROUND then
			GameModes.notify(player, "clear", ID, { round = run.round, next = run.round, passed = true })
			if passedNow then
				pass(player, run)
			end
			finish(player, entry, run)
			return
		end
		run.round += 1
		run.stage = "gap"
		run.nextAt = os.clock() + PoseRules.ROUND_GAP
		GameModes.notify(player, "clear", ID, { round = run.cleared, next = run.round, passed = run.passed or passedNow })
		if passedNow then
			pass(player, run)
		end
		GameModes.refresh(player)
	end

	-- "PoseBegin" or the START pad: take a podium and count down (phase lobby or results).
	local function begin(player: Player, entry: Entry)
		local session = GameModes.session(player)
		local clock = os.clock()
		if not session or not built or not PoseRules.canBegin(entry.phase) or clock - entry.lastBegin < BEGIN_GAP then
			return
		end
		entry.lastBegin = clock
		local used: { [number]: string } = {}
		local standing: { [number]: Player } = {}
		for other, e in entries do
			if other ~= player and e.lane then
				if e.phase == "results" then
					used[e.lane] = used[e.lane] or "results"
					standing[e.lane] = other
				else
					used[e.lane] = "busy"
				end
			end
		end
		local spots = lanes()
		local lane, bump = PoseRules.pickLane(used, #spots, entry.lane)
		if not lane then
			if entry.phase ~= "lobby" then
				toLobby(player, entry, "full")
			end
			GameModes.notify(player, "full", ID, { text = FULL_TEXT })
			return
		end
		local other: Player? = if bump then standing[lane] else nil
		local otherEntry = other and entries[other]
		if other and otherEntry then
			toLobby(other, otherEntry, "bumped")
		end
		local rec = record(session)
		local seed = (player.UserId % 100000) * 7919 + math.floor(clock * 1000) % 1000003
		entry.run = {
			seq = PoseRules.sequence(seed, PoseRules.MAX_ROUND),
			round = 1,
			done = 0,
			hearts = PoseRules.HEARTS,
			stage = "gap",
			nextAt = math.huge,
			turnAt = math.huge,
			deadline = math.huge,
			replay = false,
			cleared = 0,
			prevBest = rec.best,
			passed = false,
			pay = nil,
		}
		local spot: CFrame = spots[lane]
		unhold(entry)
		entry.phase = "countdown"
		entry.phaseEnds = clock + PoseRules.COUNTDOWN
		entry.lane = lane
		entry.spot = spot
		teleportTo(player, spot)
		entry.held = hold(player)
		GameModes.notify(player, "countdown", ID, {
			seconds = PoseRules.COUNTDOWN,
			lane = lane,
			playerPos = spot.Position,
			rivalPos = built.rivalSpot.Position,
			facing = spot.LookVector,
			hearts = PoseRules.HEARTS,
			maxHearts = PoseRules.HEARTS,
			passRound = PoseRules.PASS_ROUND,
			maxRound = PoseRules.MAX_ROUND,
			timeout = PoseRules.INPUT_TIMEOUT,
		})
		GameModes.refresh(player)
	end

	function def.running(player: Player): boolean
		return entries[player] ~= nil
	end

	-- Entering the mode (gate or "ModeStart"; again while in it: back to a fresh lobby).
	function def.start(player: Player, teleport: boolean, _options: { [string]: any }?): boolean
		local session = GameModes.session(player)
		if not session or not built then
			return false
		end
		local old = entries[player]
		if old then
			unhold(old)
		end
		local entry: Entry = {
			phase = "lobby",
			lane = nil,
			spot = nil,
			run = nil,
			phaseEnds = math.huge,
			pad = PoseRules.newPad(os.clock()),
			held = nil,
			lastBegin = -math.huge,
		}
		entries[player] = entry
		if teleport or old then
			teleportTo(player, lobbySpawn())
		end
		local rec = record(session)
		local mirror: CFrame? = built.mirrorSpot
		GameModes.notify(player, "start", ID, {
			phase = "lobby",
			best = rec.best,
			clears = rec.clears,
			rewardPreview = def.rewardPreview(player),
			maxHearts = PoseRules.HEARTS,
			passRound = PoseRules.PASS_ROUND,
			maxRound = PoseRules.MAX_ROUND,
			timeout = PoseRules.INPUT_TIMEOUT,
			lobbyPos = lobbySpawn().Position,
			rivalPos = built.rivalSpot.Position,
			facing = built.rivalSpot.LookVector,
			mirrorPos = if mirror then mirror.Position else nil,
		})
		GameModes.refresh(player)
		return true
	end

	function def.stop(player: Player, reason: string)
		local entry = entries[player]
		if not entry then
			return
		end
		entries[player] = nil
		unhold(entry)
		if reason ~= "leave" then
			GameModes.notify(player, "stop", ID, { reason = reason })
			GameModes.refresh(player)
		end
	end

	-- Feet on a pad part's top (flat distance within `radius`).
	local function onPart(part: BasePart, radius: number, pos: Vector3, feetY: number): boolean
		local p = part.Position
		return PoseRules.onPad(pos.X - p.X, feetY - (p.Y + part.Size.Y / 2), pos.Z - p.Z, radius)
	end

	local function outsideArena(pos: Vector3, margin: number): boolean
		local a = PoseRules.ARENA
		return PoseRules.outsideArena(pos.X - a.x, pos.Z - a.z, margin)
	end

	-- Anyone on the deck without the mode (it ended some other way): exit pad and falls.
	local function idleInArena(player: Player, pos: Vector3, feetY: number)
		if outsideArena(pos, ARENA_MARGIN) then
			return
		end
		if onPart(built.exit, built.exitRadius, pos, feetY) or feetY < built.top - PoseRules.FALL_BELOW then
			GameModes.toGates(player)
		end
	end

	local function tickPlay(player: Player, entry: Entry, run: Run, clock: number)
		if run.stage == "gap" and clock >= run.nextAt then
			beginRound(player, run)
		elseif run.stage == "show" and clock >= run.turnAt then
			run.stage = "input"
		elseif run.stage == "input" and clock > run.deadline then
			miss(player, entry, run, "slow")
		end
	end

	function def.tick(player: Player, root: BasePart, _now: number)
		local pos = root.Position
		local prev = lastPos[player]
		lastPos[player] = pos
		local feetY = pos.Y - FEET_BELOW_ROOT
		local entry = entries[player]
		if not entry then
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
		local clock = os.clock()
		local fell = feetY < built.top - PoseRules.FALL_BELOW
		local phase = entry.phase
		if PoseRules.fallBack(phase) == "podium" then
			local spot = entry.spot :: CFrame
			-- A respawned character is a new root: hold that one (and put it back on the podium).
			if not entry.held or entry.held.root ~= root or fell then
				unhold(entry)
				teleportTo(player, spot)
				entry.held = hold(player)
			elseif (Vector3.new(pos.X, feetY, pos.Z) - spot.Position).Magnitude > LEAVE_SPOT then
				-- Moved off the stage by something else (an admin, a teleport pad): it is off.
				def.stop(player, "invalid")
				return
			end
			if phase == "countdown" then
				if clock >= entry.phaseEnds then
					entry.phase = "play"
					GameModes.refresh(player)
					-- The first sequence shows only now (its "WATCH" lead covers the "GO!").
					beginRound(player, entry.run :: Run)
				end
			elseif entry.run then
				tickPlay(player, entry, entry.run, clock)
			end
			return
		end
		-- Lobby and results: walking free on the deck.
		if not fell and outsideArena(pos, PoseRules.LEAVE_MARGIN) then
			def.stop(player, "invalid")
			return
		end
		if phase == "results" then
			if fell then
				toLobby(player, entry, "fall")
			elseif clock >= entry.phaseEnds then
				toLobby(player, entry, "timeout")
			end
			return
		end
		if fell then
			teleportTo(player, lobbySpawn())
			return
		end
		if onPart(built.exit, built.exitRadius, pos, feetY) then
			def.stop(player, "quit")
			GameModes.toGates(player)
			return
		end
		local pad: BasePart? = built.startPad
		if pad and PoseRules.padStep(entry.pad, onPart(pad, built.startRadius or START_RADIUS, pos, feetY), clock) then
			begin(player, entry)
		end
	end

	Tycoon.addAction("PoseBegin", function(session: any, _data: { [string]: any })
		local entry = entries[session.player]
		if entry then
			begin(session.player, entry)
		end
	end)

	Tycoon.addAction("PoseLobby", function(session: any, _data: { [string]: any })
		local entry = entries[session.player]
		if entry and entry.phase == "results" then
			toLobby(session.player, entry, "button")
		end
	end)

	-- One flex of the player's turn: { flex = 1..4, step = the press's place in the round }.
	-- Only in phase play. Out-of-turn, repeated or stale presses are ignored (never a miss: a
	-- lag spike must not cost a heart).
	Tycoon.addAction("PoseInput", function(session: any, data: { [string]: any })
		local player = session.player
		local entry = entries[player]
		local run = entry and entry.run
		if not entry or not run or not PoseRules.acceptsInput(entry.phase) then
			return
		end
		local clock = os.clock()
		if run.stage == "show" and clock >= run.turnAt then
			run.stage = "input"
		end
		if run.stage ~= "input" then
			return
		end
		local flex, step = data.flex, data.step
		if type(flex) ~= "number" or type(step) ~= "number" or step ~= run.done + 1 then
			return
		end
		if flex ~= math.floor(flex) or flex < 1 or flex > #PoseRules.FLEXES then
			return
		end
		local result = PoseRules.press(run.seq, run.round, run.done, flex)
		if result == "wrong" then
			miss(player, entry, run, "wrong")
			return
		end
		run.done += 1
		run.deadline = clock + PoseRules.INPUT_TIMEOUT
		if result == "clear" then
			clear(player, entry, run)
		end
	end)

	function def.rewardPreview(player: Player): { [string]: any }
		local session = GameModes.session(player)
		if not session then
			return { cash = 0, full = false, packCash = 0, repeatCash = 0 }
		end
		local rec = record(session)
		local r = GameModes.modeReward(session, ID, rec.clears == 0)
		-- The repeat share is resting until PoseRules.REPEAT_GAP has passed since it last paid.
		local repeatCash = if PoseRules.repeatReady(repeatAt(rec), os.time()) then r.repeatCash else 0
		return { cash = r.cash, full = r.full, packCash = r.packCash, repeatCash = repeatCash }
	end

	function def.snapshot(player: Player): { [string]: any }
		local session = GameModes.session(player)
		if not session then
			return { running = false }
		end
		local rec = record(session)
		local entry = entries[player]
		local run = entry and entry.run
		return {
			running = entry ~= nil,
			phase = if entry then entry.phase else nil,
			best = rec.best,
			clears = rec.clears,
			cooldownEnds = rec.lastRewardAt + Economy.MODE_REWARD_COOLDOWN,
			rewardPreview = def.rewardPreview(player),
			round = if run then run.round else 0,
			hearts = if run then run.hearts else 0,
			lane = if entry then entry.lane else nil,
		}
	end

	Players.PlayerRemoving:Connect(function(player)
		lastPos[player] = nil
		entries[player] = nil
	end)

	return def
end

return Pose
