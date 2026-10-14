--!strict
--[[
	PoseHud: the screen side of POSE COPY (Modes.Pose; docs/minigames.md). Fx.Pose
	does the 3D side.

	STUB (foundation): a hidden root frame that shows while a run is on.
	TODO(pose builder): score, timer, round cards, the finish card.

	Wired from Main.client.luau (nothing else needs editing):
	  init(screen)        once, builds the HUD (hidden)
	  onNotify(payload)   every Notify with kind = "Mode" and mode = "pose"; routes
	                      "start" -> start(payload) and "stop" -> stop(payload)
	  onState(data)       every State snapshot (safety net: hides when modes.pose is not running)
	  start(payload) / stop(payload)
]]

local PoseHud = {}

local root: Frame? = nil
local running = false

function PoseHud.init(screen: ScreenGui)
	local frame = Instance.new("Frame")
	frame.Name = "PoseHud"
	frame.BackgroundTransparency = 1
	frame.Size = UDim2.fromScale(1, 1)
	frame.Visible = false
	frame.Parent = screen
	root = frame
end

function PoseHud.start(_payload: { [string]: any }?)
	running = true
	if root then
		root.Visible = true
	end
end

function PoseHud.stop(_payload: { [string]: any }?)
	running = false
	if root then
		root.Visible = false
	end
end

function PoseHud.onNotify(payload: { [string]: any })
	if payload.event == "start" then
		PoseHud.start(payload)
	elseif payload.event == "stop" then
		PoseHud.stop(payload)
	end
end

function PoseHud.onState(data: any)
	local info = type(data) == "table" and type(data.modes) == "table" and data.modes.pose
	if running and not (type(info) == "table" and info.running == true) then
		PoseHud.stop(nil)
	end
end

return PoseHud
