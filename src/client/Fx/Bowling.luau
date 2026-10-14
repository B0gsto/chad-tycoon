--!strict
--[[
	Fx.Bowling: the 3D side of DUMBBELL BOWL (Modes.Bowling; docs/minigames.md). UI.BowlingHud draws
	the screen.

	STUB (foundation): listens for this mode's Notify and calls start / stop.
	TODO(bowling builder): the arena's client effects (World.Bowling arena parts under
	workspace's map folder, Model with attribute Mode = "bowling").

	Main.client.luau calls init() once (it is in the Fx list); nothing else needs editing:
	  init()            connects the Notify listener
	  start(payload)    a run began ("start")
	  stop(payload)     the run ended ("stop")
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Net = require(ReplicatedStorage.Shared.Net)

local Bowling = {}

local running = false

function Bowling.start(_payload: { [string]: any })
	running = true
end

function Bowling.stop(_payload: { [string]: any })
	if not running then
		return
	end
	running = false
end

function Bowling.init()
	Net.event("Notify").OnClientEvent:Connect(function(payload)
		if type(payload) ~= "table" or payload.kind ~= "Mode" or payload.mode ~= "bowling" then
			return
		end
		if payload.event == "start" then
			Bowling.start(payload)
		elseif payload.event == "stop" then
			Bowling.stop(payload)
		end
	end)
end

return Bowling
