--!strict
--[[
	Fx.Shake: the 3D side of SHAKE CATCH (Modes.Shake; docs/minigames.md). UI.ShakeHud draws
	the screen.

	STUB (foundation): listens for this mode's Notify and calls start / stop.
	TODO(shake builder): the arena's client effects (World.Shake arena parts under
	workspace's map folder, Model with attribute Mode = "shake").

	Main.client.luau calls init() once (it is in the Fx list); nothing else needs editing:
	  init()            connects the Notify listener
	  start(payload)    a run began ("start")
	  stop(payload)     the run ended ("stop")
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Net = require(ReplicatedStorage.Shared.Net)

local Shake = {}

local running = false

function Shake.start(_payload: { [string]: any })
	running = true
end

function Shake.stop(_payload: { [string]: any })
	if not running then
		return
	end
	running = false
end

function Shake.init()
	Net.event("Notify").OnClientEvent:Connect(function(payload)
		if type(payload) ~= "table" or payload.kind ~= "Mode" or payload.mode ~= "shake" then
			return
		end
		if payload.event == "start" then
			Shake.start(payload)
		elseif payload.event == "stop" then
			Shake.stop(payload)
		end
	end)
end

return Shake
