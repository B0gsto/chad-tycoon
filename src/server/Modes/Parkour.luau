--[[
	Parkour: the first game mode. A timed run over the course in Modes.Course.

	- Walking west through gate 1 (Course.crossedStart) or the "ModeStart" action starts a run
	  (the action teleports the player onto the start deck first). Crossing the start again
	  restarts the run.
	- Checkpoints count only in order (Modes.Rules). Feet in the water past the shore send the
	  player back to their last checkpoint (0 = start deck) with a splash; the run goes on.
	- Standing on the finish deck after the last checkpoint ends the run; Rules.finish checks
	  that no leg was impossibly fast. Valid finishes record the personal best
	  (profile.modes.parkour) and the server best list, and pay Economy.modeReward: exactly the
	  smallest shop cash pack (Theme.Monetization.MoneyPacks[1], same Economy.moneyPackAmount
	  call as Monetization) on the first finish ever and then once per
	  Economy.MODE_REWARD_COOLDOWN; nothing inside the cooldown (players may still run
	  again at once); MODE_FIRST_CLEAR_GEMS Rizz on the first finish ever.
	- Leaving the course area for Course.LEAVE_SECONDS ends the run ("left").

	Notify payloads (kind = "Mode", mode = "parkour"):
	  { event = "start", checkpoints, startedAt, best? }          startedAt = server time
	  { event = "checkpoint", index, checkpoints, split }        split = seconds since start
	  { event = "respawn", index }                               back at checkpoint `index`
	  { event = "finish", time, best, newBest, first, cash, gems, full, cooldownEnds, rank? }
	  { event = "invalid", reason }                              "checkpoints" | "fast"
	  { event = "stop", reason }                                 run ended without a finish
	Effects: "ModeSplash" { pos } where the player hit the water; "ModeCheckpoint"
	{ pos, index }; "ModeFinish" { pos, newBest }; plus the usual "Cash" { amount,
	source = "Mode", padPos } when cash is paid.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Economy = require(ReplicatedStorage.Shared.Economy)
local Course = require(script.Parent.Course)
local Rules = require(script.Parent.Rules)

local Parkour = {}

local ID = "parkour"
local BEST_SIZE = 8
-- Seconds after a teleport during which position checks are skipped (the client may still
-- report its old position).
local TELEPORT_GRACE = 0.6
-- Feet are this far below the HumanoidRootPart's centre on a default character.
local FEET_BELOW_ROOT = 3

type State = {
	run: Rules.Run,
	outsideSince: number?,
	graceUntil: number,
}

local function escape(s: string): string
	return (string.gsub(s, "[&<>]", { ["&"] = "&amp;", ["<"] = "&lt;", [">"] = "&gt;" }))
end

local function vec(t: { number }): Vector3
	return Vector3.new(t[1], t[2], t[3])
end

function Parkour.create(GameModes: any, context: { built: any, theme: any, Tycoon: any })
	local theme = context.theme
	local Tycoon = context.Tycoon
	local runs: { [Player]: State } = {}
	local lastX: { [Player]: number } = {}
	-- Server best times (in memory; see Rules.recordBest for the OrderedDataStore shape).
	local serverBest: { Rules.BestEntry } = {}

	local function now(): number
		return workspace:GetServerTimeNow()
	end

	local function record(session: any): { best: number, clears: number, lastRewardAt: number }
		return session.profile.modes.parkour
	end

	local function rewardFor(session: any): Economy.ModeReward
		local p = session.profile
		local rec = record(session)
		local pack = theme.Monetization.MoneyPacks[1]
		local progression = Economy.progression(Economy.highestTier(p.discovered), p.processLevel)
		return Economy.modeReward(Tycoon.income(session), progression, pack.Seconds, pack.Min, rec.clears == 0, rec.lastRewardAt, os.time())
	end

	local function updateBoard()
		local label = context.built and context.built.bestList
		if not label then
			return
		end
		if #serverBest == 0 then
			label.Text = "Be the first to finish!"
			return
		end
		local lines = {}
		for i, entry in serverBest do
			table.insert(lines, string.format("%d. %s  <b>%.2fs</b>", i, escape(entry.name), entry.time))
		end
		label.Text = table.concat(lines, "\n")
	end

	local function teleportTo(player: Player, index: number)
		local at, look = Course.respawn(index)
		GameModes.teleport(player, vec(at), Vector3.new(look[1], 0, look[2]))
		lastX[player] = at[1]
	end

	local def = {} :: any
	def.id = ID

	function def.running(player: Player): boolean
		return runs[player] ~= nil
	end

	function def.start(player: Player, teleport: boolean): boolean
		local session = GameModes.session(player)
		if not session then
			return false
		end
		local t = now()
		runs[player] = { run = Rules.newRun(t), outsideSince = nil, graceUntil = t + TELEPORT_GRACE }
		if teleport then
			teleportTo(player, 0)
		end
		local best = record(session).best
		GameModes.notify(player, "start", ID, {
			checkpoints = Course.CHECKPOINT_COUNT,
			startedAt = t,
			best = if best > 0 then best else nil,
		})
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

	local function finish(player: Player, state: State, root: BasePart, t: number)
		runs[player] = nil
		local session = GameModes.session(player)
		if not session then
			return
		end
		local ok, result = Rules.finish(state.run, t)
		if not ok then
			GameModes.notify(player, "invalid", ID, { reason = result })
			GameModes.refresh(player)
			return
		end
		local time = Rules.roundTime(result :: number)
		local rec = record(session)
		local first = rec.clears == 0
		local reward = GameModes.hooks.reward(session, ID, rewardFor(session))
		rec.clears += 1
		if reward.full then
			rec.lastRewardAt = os.time()
		end
		local newBest = rec.best <= 0 or time < rec.best
		if newBest then
			rec.best = time
		end
		local rank = Rules.recordBest(serverBest, player.UserId, player.DisplayName, time, BEST_SIZE)
		updateBoard()

		local p = session.profile
		if reward.cash > 0 then
			p.money += reward.cash
			p.totalEarned += reward.cash
			GameModes.effect(player, "Cash", { amount = reward.cash, source = "Mode", padPos = root.Position })
		end
		p.gems += reward.gems
		GameModes.effect(player, "ModeFinish", { pos = root.Position, newBest = newBest })
		GameModes.notify(player, "finish", ID, {
			time = time,
			best = rec.best,
			newBest = newBest,
			first = first,
			cash = reward.cash,
			gems = reward.gems,
			full = reward.full,
			cooldownEnds = rec.lastRewardAt + Economy.MODE_REWARD_COOLDOWN,
			rank = rank,
		})
		GameModes.hooks.rewarded(session, ID, reward)
		Tycoon.markDirty(session)
		GameModes.refresh(player)
	end

	function def.tick(player: Player, root: BasePart, t: number)
		local pos = root.Position
		local x, y, z = pos.X, pos.Y - FEET_BELOW_ROOT, pos.Z
		local prevX = lastX[player]
		lastX[player] = x
		local state = runs[player]
		if prevX and Course.crossedStart(prevX, x, z) and y < Course.START.y + 8 then
			def.start(player, false)
			return
		end
		if not state or t < state.graceUntil then
			return
		end
		if Course.inWater(x, y, z) then
			GameModes.effect(player, "ModeSplash", { pos = Vector3.new(x, Course.WATER_BOX.y0 + 1.2, z) })
			state.graceUntil = t + TELEPORT_GRACE
			state.outsideSince = nil
			teleportTo(player, state.run.checkpoint)
			GameModes.notify(player, "respawn", ID, { index = state.run.checkpoint })
			return
		end
		if Course.inBounds(x, y, z) then
			state.outsideSince = nil
		else
			state.outsideSince = state.outsideSince or t
			if t - (state.outsideSince :: number) >= Course.LEAVE_SECONDS then
				def.stop(player, "left")
			end
			return
		end
		local nextCp = Course.CHECKPOINTS[state.run.checkpoint + 1]
		if nextCp and Course.onCheckpoint(nextCp, x, y, z) then
			local index = nextCp.index :: number
			Rules.touchCheckpoint(state.run, index, t)
			GameModes.effect(player, "ModeCheckpoint", { pos = Vector3.new(nextCp.x, nextCp.y, nextCp.z), index = index })
			GameModes.notify(player, "checkpoint", ID, {
				index = index,
				checkpoints = Course.CHECKPOINT_COUNT,
				split = Rules.roundTime(t - state.run.startedAt),
			})
			GameModes.refresh(player)
		elseif Course.inFinish(x, y, z) then
			finish(player, state, root, t)
		end
	end

	function def.rewardPreview(player: Player): { [string]: any }
		local session = GameModes.session(player)
		if not session then
			return { cash = 0, gems = 0, full = false, packCash = 0 }
		end
		local r = rewardFor(session)
		return { cash = r.cash, gems = r.gems, full = r.full, packCash = r.packCash }
	end

	function def.snapshot(player: Player): { [string]: any }
		local session = GameModes.session(player)
		local state = runs[player]
		local rec = session and record(session)
		return {
			best = if rec and rec.best > 0 then rec.best else nil,
			clears = if rec then rec.clears else 0,
			running = state ~= nil,
			checkpoint = if state then state.run.checkpoint else 0,
			checkpoints = Course.CHECKPOINT_COUNT,
			startedAt = if state then state.run.startedAt else nil,
			cooldownEnds = if rec and rec.lastRewardAt > 0 then rec.lastRewardAt + Economy.MODE_REWARD_COOLDOWN else 0,
			rewardPreview = def.rewardPreview(player),
		}
	end

	game:GetService("Players").PlayerRemoving:Connect(function(player)
		runs[player] = nil
		lastX[player] = nil
	end)
	updateBoard()
	return def
end

return Parkour
