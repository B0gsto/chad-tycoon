--!strict
--[[
	Modes.Shake: SHAKE CATCH, a solo mini-game (docs/minigames.md). Arena: World.ShakeArena
	(context.world.shake); rules: Modes.ShakeRules (pure).

	Walking in through the mode's plaza gate (Course.crossedGate) or the "ModeStart"
	{ mode = "shake" } action starts a run on the arena's spawn. After READY_SECONDS the first
	wave drops: shakes, golden dumbbells and aura orbs to catch, junk food to dodge. The server
	owns the run: the drops come from a seed (ShakeRules.schedule), each wave's drops go to the
	client before it starts (Fx.Shake animates them against the server clock), and every drop
	is judged here from the root positions sampled each tick (ShakeRules.caught). The run ends
	when the clock runs out or the hearts do (ShakeRules.outcome); a pass pays through
	GameModes.modeReward + GameModes.payReward (in full on the first clear and once per
	cooldown, else the repeat share at most once per ShakeRules.REPEAT_GAP). The arena's exit
	pad (or the HUD's quit, "ModeQuit") ends a run and brings the player back to the gates; a
	fall puts them back on the spawn. After a finish the player may walk out through the exit
	or is brought back to the gates a little later.

	Notify (kind = "Mode", mode = "shake"); times are workspace:GetServerTimeNow() seconds:
	  "start" { best, clears, target, hearts, seconds, goAt, endAt, waves }
	  "wave"  { wave, waves, at, drops = { { id, kind, x, z, spawnAt, landAt } } } (sent
	          WAVE_LEAD seconds before the wave starts; the first one with "start")
	  "catch" { id, kind, points, score, x, z }   a good item caught
	  "splat" { id, kind, hearts, x, z }           junk food caught: a heart lost
	  "win"   { score, target, best, prevBest, newBest, caught, hearts, first, cash, full,
	          packCash, repeatCash, repeatShare, pay, cooldownEnds }
	          (pay: "full" | "repeat" | "resting": the repeat share waits for REPEAT_GAP)
	  "lose"  { score, target, best, prevBest, newBest, caught, hearts, why = "hearts" | "time" }
	  "stop"  { reason }
	Snapshot modes.shake: { running, best, clears, cooldownEnds, rewardPreview, score, hearts,
	target, endAt } (the Game Modes window reads the first five).
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
-- After a finish the player is brought back to the gates this long later (unless they left).
local RETURN_AFTER = 25
-- During a run the feet must be this close to the exit pad's centre to quit (drops land at
-- least ShakeRules.EXIT_CLEAR away, so a chase never brushes it).
local EXIT_RUN_RADIUS = 2.5

local Shake = {}

type Run = {
	startedAt: number,
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
}

function Shake.create(GameModes: any, context: { [string]: any }): any
	local built = context.world and context.world.shake
	local Tycoon = context.Tycoon
	local def: any = { id = ID }
	local runs: { [Player]: Run } = {}
	local lastPos: { [Player]: Vector3 } = {}
	-- Bumped on every finish; a finish's return-to-gates timer only fires if still current.
	local finishes: { [Player]: number } = {}

	-- lastRepeatAt (os.time() of the last repeat-share pay) rides on the save record too:
	-- DataService keeps a mode record's extra keys, so the REPEAT_GAP survives rejoins.
	local function record(session: any): { best: number, clears: number, lastRewardAt: number, lastRepeatAt: number? }
		return session.profile.modes[ID]
	end

	local function toSpawn(player: Player)
		GameModes.teleport(player, built.spawn.Position, built.spawn.LookVector)
	end

	-- True when `pos` (a root) stands over the arena deck.
	local function inArena(pos: Vector3): boolean
		local a = ShakeRules.ARENA
		return math.abs(pos.X - a.x) <= a.sizeX / 2 + 2
			and math.abs(pos.Z - a.z) <= a.sizeZ / 2 + 2
			and pos.Y > a.y - ShakeRules.FALL_BELOW
			and pos.Y < a.y + 40
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

	function def.running(player: Player): boolean
		return runs[player] ~= nil
	end

	function def.start(player: Player, teleport: boolean, _options: { [string]: any }?): boolean
		local session = GameModes.session(player)
		if not session or not built then
			return false
		end
		local now = Workspace:GetServerTimeNow()
		local run: Run = {
			startedAt = os.clock(),
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
		}
		runs[player] = run
		if teleport then
			toSpawn(player)
		end
		local rec = record(session)
		GameModes.notify(player, "start", ID, {
			best = rec.best,
			clears = rec.clears,
			target = ShakeRules.TARGET,
			hearts = run.hearts,
			seconds = ShakeRules.RUN_SECONDS,
			goAt = run.goAt,
			endAt = run.goAt + ShakeRules.RUN_SECONDS,
			waves = #ShakeRules.WAVES,
		})
		sendWave(player, run, 1)
		GameModes.refresh(player)
		return true
	end

	function def.stop(player: Player, reason: string)
		if not runs[player] then
			return
		end
		runs[player] = nil
		if reason ~= "leave" then
			GameModes.notify(player, "stop", ID, { reason = reason })
			GameModes.refresh(player)
		end
	end

	-- The run is over: best and clears, the pay on a pass, the finish Notify.
	local function finish(player: Player, run: Run, result: string, root: BasePart)
		runs[player] = nil
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
				local now = os.time()
				pay = if type(last) == "number" and last <= now and now - last < ShakeRules.REPEAT_GAP then "resting" else "repeat"
				r.cash = if pay == "repeat" then r.repeatCash else 0
				if r.cash > 0 then
					rec.lastRepeatAt = now
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
		local token = (finishes[player] or 0) + 1
		finishes[player] = token
		GameModes.returnLater(player, RETURN_AFTER, function(r: BasePart)
			-- A newer run (and its own finish) supersedes this timer.
			return finishes[player] == token and inArena(r.Position)
		end)
	end

	-- Judges every drop whose window has closed and ends the run when it is over.
	-- `prev`: the root's position last tick (a jump past MAX_STEP is a teleport, not a run).
	local function play(player: Player, run: Run, root: BasePart, now: number, prev: Vector3?)
		local ok, ping = pcall(function()
			return player:GetNetworkPing()
		end)
		run.lag = ShakeRules.lagOf(if ok and type(ping) == "number" then ping else 0)
		-- Samples are stamped with when the player stood there (the server sees it `lag` late).
		local t = now - run.goAt - run.lag
		local pos = root.Position
		local step = if prev then Vector3.new(pos.X - prev.X, 0, pos.Z - prev.Z).Magnitude else 0
		if inArena(pos) and step <= ShakeRules.MAX_STEP then
			table.insert(run.samples, { t = t, x = pos.X, z = pos.Z })
		end
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
			finish(player, run, result, root)
		end
	end

	function def.tick(player: Player, root: BasePart, now: number)
		local pos = root.Position
		local prev = lastPos[player]
		lastPos[player] = pos
		local feetY = pos.Y - FEET_BELOW_ROOT
		local run = runs[player]
		if not built then
			return
		end
		local exit = built.exit.Position
		local flat = Vector3.new(pos.X - exit.X, 0, pos.Z - exit.Z)
		local radius = if run then math.min(EXIT_RUN_RADIUS, built.exitRadius) else built.exitRadius
		local onExit = flat.Magnitude <= radius and math.abs(feetY - built.top) < 4
		if not run then
			if prev and feetY < Course.PLAZA.top + 8 and Course.crossedGate(def.slot, prev.X, prev.Z, pos.X, pos.Z) then
				GameModes.start(player, ID, true)
			elseif onExit and not GameModes.active(player) then
				-- Walking out after a finish.
				GameModes.toGates(player)
			end
			return
		end
		if onExit then
			def.stop(player, "quit")
			GameModes.toGates(player)
			return
		end
		if feetY < built.top - ShakeRules.FALL_BELOW then
			toSpawn(player)
		end
		play(player, run, root, now, prev)
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
		local run = runs[player]
		return {
			running = run ~= nil,
			best = rec.best,
			clears = rec.clears,
			cooldownEnds = rec.lastRewardAt + Economy.MODE_REWARD_COOLDOWN,
			rewardPreview = def.rewardPreview(player),
			score = if run then run.score else nil,
			hearts = if run then run.hearts else nil,
			target = ShakeRules.TARGET,
			endAt = if run then run.goAt + ShakeRules.RUN_SECONDS else nil,
		}
	end

	Players.PlayerRemoving:Connect(function(player)
		lastPos[player] = nil
		finishes[player] = nil
	end)

	return def
end

return Shake
