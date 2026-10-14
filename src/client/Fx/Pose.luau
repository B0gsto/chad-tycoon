--!strict
--[[
	Fx.Pose: the 3D side of POSE COPY (Modes.Pose; docs/minigames.md). UI.PoseHud draws
	the screen.

	STUB (foundation): listens for this mode's Notify and calls start / stop.
	TODO(pose builder): the arena's client effects (World.Pose arena parts under
	workspace's map folder, Model with attribute Mode = "pose").

	Main.client.luau calls init() once (it is in the Fx list); nothing else needs editing:
	  init()            connects the Notify listener
	  start(payload)    a run began ("start")
	  stop(payload)     the run ended ("stop")
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Net = require(ReplicatedStorage.Shared.Net)

local Pose = {}

local running = false

function Pose.start(_payload: { [string]: any })
	running = true
end

function Pose.stop(_payload: { [string]: any })
	if not running then
		return
	end
	running = false
end

function Pose.init()
	Net.event("Notify").OnClientEvent:Connect(function(payload)
		if type(payload) ~= "table" or payload.kind ~= "Mode" or payload.mode ~= "pose" then
			return
		end
		if payload.event == "start" then
			Pose.start(payload)
		elseif payload.event == "stop" then
			Pose.stop(payload)
		end
	end)
end

return Pose
