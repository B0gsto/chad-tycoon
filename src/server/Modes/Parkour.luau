--[[
	Parkour: the first game mode. Timed runs over the ten levels in Modes.Course.

	- Levels: every level is out at sea and reached only by teleport. A player has unlocked
	  level 1 + (number of consecutive cleared levels from 1); "ModeStart" may pick any
	  unlocked level (options.level), else the lowest level not yet cleared. Walking west
	  through gate 1's portal (Course.crossedStart) starts that default level too. Starting
	  again restarts.
	- Checkpoints count only in order (Modes.Rules). Feet in the water past the shore send the
	  player back to their last checkpoint (0 = start deck) with a splash; the run goes on.
	- Standing on the finish deck after the last checkpoint ends the run; Rules.finish checks
	  that no leg was impossibly fast. Valid finishes record the per-level best/clears
	  (profile.parkour; level 1 is mirrored into profile.modes.parkour) and the server best
	  list of that level, and pay Economy.modeReward × Economy.parkourLevelBonus(level):
	  Theme.Modes.Reward (Seconds of income, at least Min, sized like a cash pack) on the
	  first clear OF THAT LEVEL and then once per
	  Economy.MODE_REWARD_COOLDOWN (one cooldown shared by all levels, modes.parkour.
	  lastRewardAt); MODE_FIRST_CLEAR_GEMS Rizz on each level's first clear. After a remote
	  finish the player is brought back to the gates (GameModes.returnLater).
	- Leaving the level's bounds for Course.LEAVE_SECONDS ends the run ("left"); on a remote
	  level the player goes back to the gates.

	Notify payloads (kind = "Mode", mode = "parkour"):
	  { event = "start", checkpoints, startedAt, best?, level, levelName, levels, remote }
	  { event = "checkpoint", index, checkpoints, split }        split = seconds since start
	  { event = "respawn", index }                               back at checkpoint `index`
	  { event = "finish", time, best, newBest, first, cash, gems, full, cooldownEnds, rank?,
	    level, levelName, nextLevel?, unlockedNew, unlocked, levels }
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
-- Seconds after a remote finish before the player is taken back to the gates.
local RETURN_SECONDS = 15

type State = {
	run: Rules.Run,
	outsideSince: number?,
	graceUntil: number,
}

type Record = { best: { number }, clears: { number } }

local function escape(s: string): string
	return (string.gsub(s, "[&<>]", { ["&"] = "&amp;", ["<"] = "&lt;", [">"] = "&gt;" }))
end

local function vec(t: { number }): Vector3
	return Vector3.new(t[1], t[2], t[3])
end

-- Levels unlocked: 1 + consecutive cleared levels from level 1 (at most LEVEL_COUNT).
local function unlockedOf(rec: Record): number
	local n = 1
	while n < Course.LEVEL_COUNT and (rec.clears[n] or 0) > 0 do
		n += 1
	end
	return n
end

-- The lowest level not cleared yet (the last level once all are cleared).
local function defaultOf(rec: Record): number
	for i = 1, Course.LEVEL_COUNT do
		if (rec.clears[i] or 0) == 0 then
			return i
		end
	end
	return Course.LEVEL_COUNT
end

function Parkour.create(GameModes: any, context: { built: any, theme: any, Tycoon: any })
	local theme = context.theme
	local Tycoon = context.Tycoon
	local runs: { [Player]: State } = {}
	local lastX: { [Player]: number } = {}
	-- Server best times per level (in memory; see Rules.recordBest for the OrderedDataStore
	-- shape).
	local serverBest: { { Rules.BestEntry } } = {}
	for i = 1, Course.LEVEL_COUNT do
		serverBest[i] = {}
	end

	local function now(): number
		return workspace:GetServerTimeNow()
	end

	-- Shared cooldown + level 1 mirror (old UI).
	local function shared(session: any): { best: number, clears: number, lastRewardAt: number }
		return session.profile.modes.parkour
	end

	local function levels(session: any): Record
		return session.profile.parkour
	end

	local function rewardFor(session: any, level: number): Economy.ModeReward
		local p = session.profile
		local pack = theme.Modes.Reward
		local progression = Economy.progression(Economy.highestTier(p.discovered), p.processLevel)
		local first = (levels(session).clears[level] or 0) == 0
		local r =
			Economy.modeReward(Tycoon.income(session), progression, pack.Seconds, pack.Min, first, shared(session).lastRewardAt, os.time())
		local bonus = Economy.parkourLevelBonus(level)
		r.packCash = math.floor(r.packCash * bonus + 0.5)
		r.cash = if r.full then r.packCash else 0
		return r
	end

	local function updateBoard()
		local label = context.built and context.built.bestList
		if not label then
			return
		end
		local lines = {}
		for i = 1, Course.LEVEL_COUNT do
			local top = serverBest[i][1]
			if top then
				table.insert(lines, string.format("L%d  %s  <b>%.2fs</b>", i, escape(top.name), top.time))
			else
				table.insert(lines, string.format("L%d  —", i))
			end
		end
		label.Text = table.concat(lines, "\n")
	end

	local function teleportTo(player: Player, level: Course.Level, index: number)
		local at, look = Course.respawn(level, index)
		GameModes.teleport(player, vec(at), Vector3.new(look[1], 0, look[2]))
		lastX[player] = at[1]
	end

	local def = {} :: any
	def.id = ID

	function def.running(player: Player): boolean
		return runs[player] ~= nil
	end

	function def.start(player: Player, teleport: boolean, options: { [string]: any }?): boolean
		local session = GameModes.session(player)
		if not session then
			return false
		end
		local rec = levels(session)
		local index = defaultOf(rec)
		local asked = options and options.level
		if type(asked) == "number" then
			if asked ~= asked or asked < 1 or asked > unlockedOf(rec) then
				return false
			end
			index = math.floor(asked)
		end
		local level = Course.level(index)
		local t = now()
		runs[player] = { run = Rules.newRun(t, level), outsideSince = nil, graceUntil = t + TELEPORT_GRACE }
		if teleport or level.remote then
			teleportTo(player, level, 0)
		end
		local best = rec.best[index] or 0
		GameModes.notify(player, "start", ID, {
			checkpoints = level.CHECKPOINT_COUNT,
			startedAt = t,
			best = if best > 0 then best else nil,
			level = index,
			levelName = level.name,
			levels = Course.LEVEL_COUNT,
			remote = level.remote,
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
			if state.run.level.remote then
				GameModes.returnLater(player, 4, nil)
			end
			return
		end
		local level = state.run.level
		local index = level.index
		local time = Rules.roundTime(result :: number)
		local rec = levels(session)
		local cooldown = shared(session)
		local first = rec.clears[index] == 0
		local unlockedBefore = unlockedOf(rec)
		local reward = GameModes.hooks.reward(session, ID, rewardFor(session, index))
		rec.clears[index] += 1
		if reward.full then
			cooldown.lastRewardAt = os.time()
		end
		local newBest = rec.best[index] <= 0 or time < rec.best[index]
		if newBest then
			rec.best[index] = time
		end
		if index == 1 then
			cooldown.best, cooldown.clears = rec.best[1], rec.clears[1]
		end
		local unlocked = unlockedOf(rec)
		local rank = Rules.recordBest(serverBest[index], player.UserId, player.DisplayName, time, BEST_SIZE)
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
			best = rec.best[index],
			newBest = newBest,
			first = first,
			cash = reward.cash,
			gems = reward.gems,
			full = reward.full,
			cooldownEnds = cooldown.lastRewardAt + Economy.MODE_REWARD_COOLDOWN,
			rank = rank,
			level = index,
			levelName = level.name,
			nextLevel = if index < Course.LEVEL_COUNT then index + 1 else nil,
			unlockedNew = unlocked > unlockedBefore,
			unlocked = unlocked,
			levels = Course.LEVEL_COUNT,
		})
		GameModes.hooks.rewarded(session, ID, reward)
		Tycoon.markDirty(session)
		GameModes.refresh(player)
		if level.remote then
			GameModes.returnLater(player, RETURN_SECONDS, function(r: BasePart): boolean
				local at = r.Position
				return Course.inBounds(level, at.X, at.Y - FEET_BELOW_ROOT, at.Z)
			end)
		end
	end

	function def.tick(player: Player, root: BasePart, t: number)
		local pos = root.Position
		local x, y, z = pos.X, pos.Y - FEET_BELOW_ROOT, pos.Z
		local prevX = lastX[player]
		lastX[player] = x
		local state = runs[player]
		if prevX and Course.crossedStart(prevX, x, z) and y < Course.PLAZA.top + 8 then
			def.start(player, false)
			return
		end
		if not state or t < state.graceUntil then
			return
		end
		local level = state.run.level
		if Course.inWater(x, y, z) then
			GameModes.effect(player, "ModeSplash", { pos = Vector3.new(x, level.WATER_BOX.y0 + 1.2, z) })
			state.graceUntil = t + TELEPORT_GRACE
			state.outsideSince = nil
			teleportTo(player, level, state.run.checkpoint)
			GameModes.notify(player, "respawn", ID, { index = state.run.checkpoint })
			return
		end
		if Course.inBounds(level, x, y, z) then
			state.outsideSince = nil
		else
			state.outsideSince = state.outsideSince or t
			if t - (state.outsideSince :: number) >= Course.LEAVE_SECONDS then
				def.stop(player, "left")
				if level.remote then
					GameModes.toGates(player)
				end
			end
			return
		end
		local nextCp = level.CHECKPOINTS[state.run.checkpoint + 1]
		if nextCp and Course.onCheckpoint(nextCp, x, y, z) then
			local index = nextCp.index :: number
			Rules.touchCheckpoint(state.run, index, t)
			GameModes.effect(player, "ModeCheckpoint", { pos = Vector3.new(nextCp.x, nextCp.y, nextCp.z), index = index })
			GameModes.notify(player, "checkpoint", ID, {
				index = index,
				checkpoints = level.CHECKPOINT_COUNT,
				split = Rules.roundTime(t - state.run.startedAt),
			})
			GameModes.refresh(player)
		elseif Course.inFinish(level, x, y, z) then
			finish(player, state, root, t)
		end
	end

	-- Reward preview for `level` (default: the player's default level).
	function def.rewardPreview(player: Player, level: number?): { [string]: any }
		local session = GameModes.session(player)
		if not session then
			return { cash = 0, gems = 0, full = false, packCash = 0 }
		end
		local r = rewardFor(session, level or defaultOf(levels(session)))
		return { cash = r.cash, gems = r.gems, full = r.full, packCash = r.packCash }
	end

	function def.snapshot(player: Player): { [string]: any }
		local session = GameModes.session(player)
		local state = runs[player]
		local rec = session and levels(session)
		local cooldown = session and shared(session)
		local default = if rec then defaultOf(rec) else 1
		local current = if state then state.run.level else Course.level(default)
		local list = {}
		for i, level in Course.LEVELS do
			list[i] = {
				name = level.name,
				difficulty = level.difficulty,
				best = if rec then rec.best[i] else 0,
				clears = if rec then rec.clears[i] else 0,
				checkpoints = level.CHECKPOINT_COUNT,
				bonus = Economy.parkourLevelBonus(i),
			}
		end
		local best = if rec then rec.best[default] else 0
		return {
			best = if best > 0 then best else nil,
			clears = if rec then rec.clears[default] else 0,
			running = state ~= nil,
			checkpoint = if state then state.run.checkpoint else 0,
			checkpoints = current.CHECKPOINT_COUNT,
			startedAt = if state then state.run.startedAt else nil,
			cooldownEnds = if cooldown and cooldown.lastRewardAt > 0 then cooldown.lastRewardAt + Economy.MODE_REWARD_COOLDOWN else 0,
			rewardPreview = def.rewardPreview(player, current.index),
			level = current.index,
			unlocked = if rec then unlockedOf(rec) else 1,
			levelCount = Course.LEVEL_COUNT,
			levels = list,
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
