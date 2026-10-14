--!strict
--[[
	BowlingHud: the screen side of DUMBBELL BOWL (Modes.Bowling; docs/minigames.md). Fx.Bowling
	does the 3D side.

	STUB (foundation): a hidden root frame that shows while a run is on.
	TODO(bowling builder): score, timer, round cards, the finish card.

	Wired from Main.client.luau (nothing else needs editing):
	  init(screen)        once, builds the HUD (hidden)
	  onNotify(payload)   every Notify with kind = "Mode" and mode = "bowling"; routes
	                      "start" -> start(payload) and "stop" -> stop(payload)
	  onState(data)       every State snapshot (safety net: hides when modes.bowling is not running)
	  start(payload) / stop(payload)
]]

local BowlingHud = {}

local root: Frame? = nil
local running = false

function BowlingHud.init(screen: ScreenGui)
	local frame = Instance.new("Frame")
	frame.Name = "BowlingHud"
	frame.BackgroundTransparency = 1
	frame.Size = UDim2.fromScale(1, 1)
	frame.Visible = false
	frame.Parent = screen
	root = frame
end

function BowlingHud.start(_payload: { [string]: any }?)
	running = true
	if root then
		root.Visible = true
	end
end

function BowlingHud.stop(_payload: { [string]: any }?)
	running = false
	if root then
		root.Visible = false
	end
end

function BowlingHud.onNotify(payload: { [string]: any })
	if payload.event == "start" then
		BowlingHud.start(payload)
	elseif payload.event == "stop" then
		BowlingHud.stop(payload)
	end
end

function BowlingHud.onState(data: any)
	local info = type(data) == "table" and type(data.modes) == "table" and data.modes.bowling
	if running and not (type(info) == "table" and info.running == true) then
		BowlingHud.stop(nil)
	end
end

return BowlingHud
