--!strict
--[[
	Modes.Pose: POSE COPY, a solo mini-game (docs/minigames.md). Arena: World.PoseStage
	(context.world.pose); rules: Modes.PoseRules (pure).

	STUB (foundation): walking in through the mode's plaza gate (Course.crossedGate) or the
	"ModeStart" { mode = "pose" } action starts a run on the arena's spawn; the arena's
	exit pad (or the HUD's quit, "ModeQuit") ends it and brings the player back to the
	gates; a fall puts them back on the spawn. Nothing is played or paid yet.
	TODO(pose builder): copy the rival's growing flex sequence; a pass pays through GameModes.modeReward + GameModes.payReward
	(first clear: record(session).clears == 0).

	Notify (kind = "Mode", mode = "pose"): "start" { best, clears }, "stop" { reason }.
	Builders add their own events (docs/minigames.md lists the convention).
	Snapshot modes.pose: { running, best, clears, cooldownEnds, rewardPreview } (the Game
	Modes window reads exactly these).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Economy = require(ReplicatedStorage.Shared.Economy)

local Course = require(script.Parent.Course)
local PoseRules = require(script.Parent.PoseRules)

local ID = "pose"
-- Feet are about this far under the HumanoidRootPart's centre (R15 default rig).
local FEET_BELOW_ROOT = 3

local Pose = {}

type Run = { startedAt: number }

function Pose.create(GameModes: any, context: { [string]: any }): any
	local built = context.world and context.world.pose
	local def: any = { id = ID }
	local runs: { [Player]: Run } = {}
	local lastPos: { [Player]: Vector3 } = {}

	local function record(session: any): { best: number, clears: number, lastRewardAt: number }
		return session.profile.modes[ID]
	end

	local function toSpawn(player: Player)
		GameModes.teleport(player, built.spawn.Position, built.spawn.LookVector)
	end

	function def.running(player: Player): boolean
		return runs[player] ~= nil
	end

	function def.start(player: Player, teleport: boolean, _options: { [string]: any }?): boolean
		local session = GameModes.session(player)
		if not session or not built then
			return false
		end
		runs[player] = { startedAt = os.clock() }
		if teleport then
			toSpawn(player)
		end
		local rec = record(session)
		GameModes.notify(player, "start", ID, { best = rec.best, clears = rec.clears })
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
		if feetY < built.top - PoseRules.FALL_BELOW then
			toSpawn(player)
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
		return {
			running = runs[player] ~= nil,
			best = rec.best,
			clears = rec.clears,
			cooldownEnds = rec.lastRewardAt + Economy.MODE_REWARD_COOLDOWN,
			rewardPreview = def.rewardPreview(player),
		}
	end

	Players.PlayerRemoving:Connect(function(player)
		lastPos[player] = nil
	end)

	return def
end

return Pose
