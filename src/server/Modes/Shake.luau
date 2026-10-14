--!strict
--[[
	Modes.Shake: SHAKE CATCH, a solo mini-game (docs/minigames.md). Arena: World.ShakeArena
	(context.world.shake); rules: Modes.ShakeRules (pure).

	PROTOCOL (Notify kind = "Mode", mode = "shake"; every time is a
	workspace:GetServerTimeNow() second):
	  "start"     { phase = "lobby", best, clears, rewardPreview, target, hearts, seconds, waves }
	              entering the mode (gate walk-in or "ModeStart"): the player is in the lobby
	  "countdown" { phase = "countdown", seconds, goAt, endAt, target, hearts, waves }
	              after "ShakeBegin" / the START pad: the player is on the court; waves start at goAt
	  "wave"      { wave, waves, at, drops = { { id, kind, x, z, spawnAt, landAt } } }
	              sent WAVE_LEAD seconds before the wave starts (wave 1 right after "countdown")
	  "go"        { phase = "play", goAt, endAt }      the countdown ended
	  "catch"     { id, kind, points, score, x, z }    a good item caught
	  "splat"     { id, kind, hearts, x, z }           junk food caught: a heart lost
	  "win"       { phase = "results", returnAt, score, target, best, prevBest, newBest, caught,
	              hearts, first, cash, full, packCash, repeatCash, repeatShare, pay, cooldownEnds }
	              (pay: "full" | "repeat" | "resting": the repeat share waits for REPEAT_GAP)
	  "lose"      { phase = "results", returnAt, score, target, best, prevBest, newBest, caught,
	              hearts, why = "hearts" | "time" }
	  "lobby"     { phase = "lobby", best, clears, rewardPreview }
	              back in the lobby (RESULTS_SECONDS after a finish, or a fall on the results card)
	  "stop"      { reason }   the visit is over ("quit" | "left" | "respawn" | "switch" | ...)
	Actions (Tycoon.addAction):
	  "ShakeBegin" {}   start a run; accepted in phase "lobby" and "results" only
	  ("ModeStart" { mode = "shake" } and "ModeQuit" are GameModes' own)
	Snapshot modes.shake: { running, phase, best, clears, cooldownEnds, rewardPreview, target,
	score, hearts, goAt, endAt } (score / hearts / goAt / endAt only with a run, kept on the
	results card). running is true for the whole visit, lobby included.

	A visit: entry teleports to the arena's lobbySpawn (phase "lobby"); nothing is timed or
	paid there. "ShakeBegin" or standing on the START pad (feet within startRadius, after
	PAD_REARM seconds off it) moves the player to the court spawn for a READY_SECONDS
	countdown, then the waves drop: shakes, golden dumbbells and aura orbs to catch, junk food
	to dodge. The server owns the run: the drops come from a seed (ShakeRules.schedule), each
	wave's drops go to the client before it starts (Fx.Shake animates them against the server
	clock), and every drop is judged here from root positions sampled each tick, stamped back
	by the player's ping (ShakeRules.lagOf) and kept only at a walkable speed
	(ShakeRules.plausible). The run ends when the clock or the hearts run out
	(ShakeRules.outcome); a pass pays through GameModes.modeReward + GameModes.payReward (in
	full on the first clear and once per cooldown, else the repeat share at most once per
	ShakeRules.REPEAT_GAP). The results card stays RESULTS_SECONDS, then the player is back in
	the lobby. The EXIT arch (lobby only) or "ModeQuit" ends the visit and brings the player
	back to the gates; a fall puts them on the lobby spawn (lobby, results) or the court spawn
	(countdown, play).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Economy = require(ReplicatedStorage.Shared.Economy)

local Course = require(script.Parent.Course)
local ShakeRules = require(script.Parent.ShakeRules)

local ID = "shake"
-- Feet are about this far under the HumanoidRootPart's centre (R15 default rig).
local FEET_BELOW_ROOT = 3
-- A wave's drops go to the client this many seconds before the wave starts.
local WAVE_LEAD = 1.5
-- Root samples older than this (seconds) are dropped.
local SAMPLE_KEEP = 1.5
-- START pad radius when the arena gives none.
local DEFAULT_START_RADIUS = 4
-- A visitor whose root stays this far (studs, flat) outside the arena for AWAY_SECONDS has
-- left some other way (a teleport home, a portal): the visit ends with "left".
local AWAY_MARGIN = 80
local AWAY_SECONDS = 2

local Shake = {}

type Run = {
	-- Server time the first wave starts (run time 0).
	goAt: number,
	drops: { ShakeRules.Drop },
	-- The next drop (land order) still to judge, and the last wave sent.
	nextDrop: number,
	sentWave: number,
	score: number,
	hearts: number,
	caught: number,
	samples: { ShakeRules.Sample },
	-- Seconds the server sees this player late (ShakeRules.lagOf, refreshed every tick).
	lag: number,
	-- The last trusted root position (server time, x, z); nil right after a teleport.
	trusted: { at: number, x: number, z: number }?,
}

type Visit = {
	phase: string, -- "lobby" | "countdown" | "play" | "results"
	run: Run?,
	-- Server time the results card ends (phase "results").
	returnAt: number,
	-- START pad re-arm (ShakeRules.padStep): when the feet were last seen stepping off it.
	padOff: number?,
	-- Server time the root was first seen far outside the arena (nil while inside).
	awaySince: number?,
}

function Shake.create(GameModes: any, context: { [string]: any }): any
	local built = context.world and context.world.shake
	local Tycoon = context.Tycoon
	local def: any = { id = ID }
	local visits: { [Player]: Visit } = {}
	local lastPos: { [Player]: Vector3 } = {}

	-- lastRepeatAt (os.time() of the last repeat-share pay) rides on the save record too:
	-- DataService keeps a mode record's extra keys, so the REPEAT_GAP survives rejoins.
	local function record(session: any): { best: number, clears: number, lastRewardAt: number, lastRepeatAt: number? }
		return session.profile.modes[ID]
	end

	-- The lobby anchors, falling back to the play spawn / exit pad while the arena has none.
	local function lobbySpawn(): CFrame
		local cf = built.lobbySpawn
		return if typeof(cf) == "CFrame" then cf else built.spawn
	end

	local function startPad(): (BasePart?, number)
		local pad = built.startPad
		local radius = built.startRadius
		return if typeof(pad) == "Instance" and pad:IsA("BasePart") then pad else nil,
			if type(radius) == "number" and radius > 0 then radius else DEFAULT_START_RADIUS
	end

	local function toCourt(player: Player)
		GameModes.teleport(player, built.spawn.Position, built.spawn.LookVector)
	end

	local function toLobbySpawn(player: Player)
		local cf = lobbySpawn()
		GameModes.teleport(player, cf.Position, cf.LookVector)
	end

	-- True when `pos` (a root) stands over the arena deck (lobby and court).
	local function inArena(pos: Vector3): boolean
		local a = ShakeRules.ARENA
		return math.abs(pos.X - a.x) <= a.sizeX / 2 + 2
			and math.abs(pos.Z - a.z) <= a.sizeZ / 2 + 2
			and pos.Y > a.y - ShakeRules.FALL_BELOW
			and pos.Y < a.y + 40
	end

	local function farAway(pos: Vector3): boolean
		local a = ShakeRules.ARENA
		return math.abs(pos.X - a.x) > a.sizeX / 2 + AWAY_MARGIN or math.abs(pos.Z - a.z) > a.sizeZ / 2 + AWAY_MARGIN
	end

	local function lobbyInfo(player: Player, session: any): { [string]: any }
		local rec = record(session)
		return {
			phase = "lobby",
			best = rec.best,
			clears = rec.clears,
			rewardPreview = def.rewardPreview(player),
		}
	end

	-- Sends wave `index`'s drops (absolute server times).
	local function sendWave(player: Player, run: Run, index: number)
		run.sentWave = index
		local wave = ShakeRules.WAVES[index]
		local list = {}
		for _, d in run.drops do
			if d.wave == index then
				table.insert(list, {
					id = d.id,
					kind = d.kind,
					x = d.x,
					z = d.z,
					spawnAt = run.goAt + d.spawnAt,
					landAt = run.goAt + d.landAt,
				})
			end
		end
		GameModes.notify(player, "wave", ID, {
			wave = index,
			waves = #ShakeRules.WAVES,
			at = run.goAt + wave.from,
			drops = list,
		})
	end

	-- Puts the visitor (back) in the lobby phase; `event` is the Notify to send.
	local function enterLobby(player: Player, visit: Visit, event: string)
		local session = GameModes.session(player)
		visit.phase = "lobby"
		visit.run = nil
		visit.padOff = nil
		toLobbySpawn(player)
		if session then
			GameModes.notify(player, event, ID, lobbyInfo(player, session))
		end
		GameModes.refresh(player)
	end

	-- Starts a run from the lobby or the results card: court spawn, countdown, wave 1.
	local function begin(player: Player): boolean
		local visit = visits[player]
		if not visit or not built or not ShakeRules.canBegin(visit.phase) then
			return false
		end
		local now = Workspace:GetServerTimeNow()
		local run: Run = {
			goAt = now + ShakeRules.READY_SECONDS,
			drops = ShakeRules.schedule(
				Random.new():NextInteger(1, 2 ^ 30),
				built.catchArea,
				{ x = built.exit.Position.X, z = built.exit.Position.Z }
			),
			nextDrop = 1,
			sentWave = 0,
			score = 0,
			hearts = ShakeRules.HEARTS,
			caught = 0,
			samples = {},
			lag = 0,
			trusted = nil,
		}
		visit.phase = "countdown"
		visit.run = run
		visit.padOff = nil
		toCourt(player)
		GameModes.notify(player, "countdown", ID, {
			phase = "countdown",
			seconds = ShakeRules.READY_SECONDS,
			goAt = run.goAt,
			endAt = run.goAt + ShakeRules.RUN_SECONDS,
			target = ShakeRules.TARGET,
			hearts = run.hearts,
			waves = #ShakeRules.WAVES,
		})
		sendWave(player, run, 1)
		GameModes.refresh(player)
		return true
	end

	function def.running(player: Player): boolean
		return visits[player] ~= nil
	end

	function def.start(player: Player, teleport: boolean, _options: { [string]: any }?): boolean
		local session = GameModes.session(player)
		if not session or not built then
			return false
		end
		-- A second "ModeStart" while already here (any phase) goes back to the lobby; a run in
		-- progress is dropped unscored.
		local visit: Visit = visits[player] or { phase = "lobby", returnAt = 0 }
		visit.phase = "lobby"
		visit.run = nil
		visit.padOff = nil
		visit.awaySince = nil
		visits[player] = visit
		if teleport then
			toLobbySpawn(player)
		end
		local payload = lobbyInfo(player, session)
		payload.target = ShakeRules.TARGET
		payload.hearts = ShakeRules.HEARTS
		payload.seconds = ShakeRules.RUN_SECONDS
		payload.waves = #ShakeRules.WAVES
		GameModes.notify(player, "start", ID, payload)
		GameModes.refresh(player)
		return true
	end

	function def.stop(player: Player, reason: string)
		if not visits[player] then
			return
		end
		visits[player] = nil
		if reason ~= "leave" then
			GameModes.notify(player, "stop", ID, { reason = reason })
			GameModes.refresh(player)
		end
	end

	-- The run is over: best and clears, the pay on a pass, the finish Notify, the results card.
	local function finish(player: Player, visit: Visit, run: Run, result: string, root: BasePart, now: number)
		visit.phase = "results"
		visit.returnAt = now + ShakeRules.RESULTS_SECONDS
		local session = GameModes.session(player)
		if not session then
			return
		end
		local rec = record(session)
		local prevBest = rec.best
		local newBest = run.score > prevBest
		if newBest then
			rec.best = run.score
		end
		local payload: { [string]: any } = {
			phase = "results",
			returnAt = visit.returnAt,
			score = run.score,
			target = ShakeRules.TARGET,
			best = rec.best,
			prevBest = prevBest,
			newBest = newBest,
			caught = run.caught,
			hearts = run.hearts,
		}
		if result == "win" then
			local first = rec.clears == 0
			rec.clears += 1
			local r = GameModes.modeReward(session, ID, first)
			local pay = "full"
			if not r.full then
				local last = rec.lastRepeatAt
				local clock = os.time()
				pay = if type(last) == "number" and last <= clock and clock - last < ShakeRules.REPEAT_GAP then "resting" else "repeat"
				r.cash = if pay == "repeat" then r.repeatCash else 0
				if r.cash > 0 then
					rec.lastRepeatAt = clock
				end
			end
			local paid = GameModes.payReward(player, ID, r, root.Position)
			payload.first = first
			payload.cash = paid.cash
			payload.full = paid.full
			payload.packCash = paid.packCash
			payload.repeatCash = paid.repeatCash
			payload.repeatShare = Economy.MODE_REPEAT_SHARE
			payload.pay = pay
			payload.cooldownEnds = rec.lastRewardAt + Economy.MODE_REWARD_COOLDOWN
		else
			payload.why = if run.hearts <= 0 then "hearts" else "time"
			if newBest and Tycoon then
				-- payReward saves a pass; a lost run's new best is saved here.
				Tycoon.markDirty(session)
			end
		end
		GameModes.notify(player, result, ID, payload)
		GameModes.refresh(player)
	end

	-- Records the root sample if it is plausible (walkable from the last trusted one).
	local function sample(player: Player, run: Run, root: BasePart, now: number, t: number)
		local pos = root.Position
		if not inArena(pos) then
			return
		end
		local trusted = run.trusted
		if trusted then
			local dist = Vector3.new(pos.X - trusted.x, 0, pos.Z - trusted.z).Magnitude
			local dt = now - trusted.at
			local humanoid = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
			local walk = if humanoid then humanoid.WalkSpeed else nil
			if not ShakeRules.plausible(dist, dt, walk) then
				if dt < ShakeRules.REANCHOR then
					return
				end
				-- Long enough without a trusted sample (a fling, a lag spike): start over here.
				run.trusted = { at = now, x = pos.X, z = pos.Z }
			elseif dt >= ShakeRules.ANCHOR_EVERY then
				run.trusted = { at = now, x = pos.X, z = pos.Z }
			end
		else
			run.trusted = { at = now, x = pos.X, z = pos.Z }
		end
		table.insert(run.samples, { t = t, x = pos.X, z = pos.Z })
	end

	-- Judges every drop whose window has closed and ends the run when it is over.
	local function play(player: Player, visit: Visit, run: Run, root: BasePart, now: number)
		local ok, ping = pcall(function()
			return player:GetNetworkPing()
		end)
		run.lag = ShakeRules.lagOf(if ok and type(ping) == "number" then ping else 0)
		-- Samples are stamped with when the player stood there (the server sees it `lag` late).
		local t = now - run.goAt - run.lag
		sample(player, run, root, now, t)
		while run.samples[1] and run.samples[1].t < t - SAMPLE_KEEP do
			table.remove(run.samples, 1)
		end
		local nextWave = ShakeRules.WAVES[run.sentWave + 1]
		if nextWave and t >= nextWave.from - WAVE_LEAD then
			sendWave(player, run, run.sentWave + 1)
		end
		local settled = t - ShakeRules.SETTLE
		while run.hearts > 0 do
			local drop = run.drops[run.nextDrop]
			if not drop or drop.landAt > settled then
				break
			end
			run.nextDrop += 1
			if ShakeRules.caught(run.samples, drop) then
				if ShakeRules.isJunk(drop.kind) then
					run.hearts -= 1
					GameModes.notify(player, "splat", ID, { id = drop.id, kind = drop.kind, hearts = run.hearts, x = drop.x, z = drop.z })
				else
					local points = ShakeRules.points(drop.kind)
					run.score += points
					run.caught += 1
					GameModes.notify(player, "catch", ID, {
						id = drop.id,
						kind = drop.kind,
						points = points,
						score = run.score,
						x = drop.x,
						z = drop.z,
					})
				end
			end
		end
		local result = ShakeRules.outcome(run.score, run.hearts, settled)
		if result then
			finish(player, visit, run, result, root, now)
		end
	end

	function def.tick(player: Player, root: BasePart, now: number)
		local pos = root.Position
		local prev = lastPos[player]
		lastPos[player] = pos
		if not built then
			return
		end
		local feetY = pos.Y - FEET_BELOW_ROOT
		local visit = visits[player]
		local exit = built.exit.Position
		local onExit = Vector3.new(pos.X - exit.X, 0, pos.Z - exit.Z).Magnitude <= built.exitRadius and math.abs(feetY - built.top) < 4
		if not visit then
			if prev and feetY < Course.PLAZA.top + 8 and Course.crossedGate(def.slot, prev.X, prev.Z, pos.X, pos.Z) then
				GameModes.start(player, ID, true)
			elseif onExit and not GameModes.active(player) then
				-- Standing on the exit with no visit (a respawn ended it): back to the gates.
				GameModes.toGates(player)
			end
			return
		end

		-- Gone some other way (a home teleport, another feature): the visit is over.
		if farAway(pos) then
			visit.awaySince = visit.awaySince or now
			if now - (visit.awaySince :: number) >= AWAY_SECONDS then
				def.stop(player, "left")
			end
			return
		end
		visit.awaySince = nil

		local phase = visit.phase
		local fallFloor = if ShakeRules.fallTo(phase) == "court" then built.top else math.min(built.top, lobbySpawn().Position.Y)
		if feetY < fallFloor - ShakeRules.FALL_BELOW then
			if ShakeRules.fallTo(phase) == "court" then
				toCourt(player)
				if visit.run then
					visit.run.trusted = nil
				end
			elseif phase == "results" then
				enterLobby(player, visit, "lobby")
			else
				toLobbySpawn(player)
				visit.padOff = nil
			end
			return
		end

		if phase == "lobby" then
			if onExit then
				def.stop(player, "quit")
				GameModes.toGates(player)
				return
			end
			local pad, radius = startPad()
			if pad then
				local top = pad.Position + Vector3.new(0, pad.Size.Y / 2, 0)
				local on = ShakeRules.onPad(pos.X, feetY, pos.Z, { x = top.X, y = top.Y, z = top.Z }, radius)
				local go, offSince = ShakeRules.padStep(on, visit.padOff, now)
				visit.padOff = offSince
				if go then
					begin(player)
				end
			end
		elseif phase == "countdown" then
			local run = visit.run
			if run and now >= run.goAt then
				visit.phase = "play"
				GameModes.notify(player, "go", ID, { phase = "play", goAt = run.goAt, endAt = run.goAt + ShakeRules.RUN_SECONDS })
				GameModes.refresh(player)
				play(player, visit, run, root, now)
			end
		elseif phase == "play" then
			local run = visit.run
			if run then
				play(player, visit, run, root, now)
			end
		elseif phase == "results" then
			if now >= visit.returnAt then
				enterLobby(player, visit, "lobby")
			end
		end
	end

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
		local visit = visits[player]
		local run = visit and visit.run
		return {
			running = visit ~= nil,
			phase = if visit then visit.phase else nil,
			best = rec.best,
			clears = rec.clears,
			cooldownEnds = rec.lastRewardAt + Economy.MODE_REWARD_COOLDOWN,
			rewardPreview = def.rewardPreview(player),
			target = ShakeRules.TARGET,
			score = if run then run.score else nil,
			hearts = if run then run.hearts else nil,
			goAt = if run then run.goAt else nil,
			endAt = if run then run.goAt + ShakeRules.RUN_SECONDS else nil,
		}
	end

	if Tycoon then
		Tycoon.addAction("ShakeBegin", function(session: any)
			begin(session.player)
		end)
	end

	Players.PlayerRemoving:Connect(function(player)
		lastPos[player] = nil
		visits[player] = nil
	end)

	return def
end

return Shake
