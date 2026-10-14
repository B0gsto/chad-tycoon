--!strict
--[[
	ShakeHud: the screen side of SHAKE CATCH (Modes.Shake; docs/minigames.md). Fx.Shake
	does the 3D side.

	STUB (foundation): a hidden root frame that shows while a run is on.
	TODO(shake builder): score, timer, round cards, the finish card.

	Wired from Main.client.luau (nothing else needs editing):
	  init(screen)        once, builds the HUD (hidden)
	  onNotify(payload)   every Notify with kind = "Mode" and mode = "shake"; routes
	                      "start" -> start(payload) and "stop" -> stop(payload)
	  onState(data)       every State snapshot (safety net: hides when modes.shake is not running)
	  start(payload) / stop(payload)
]]

local ShakeHud = {}

local root: Frame? = nil
local running = false

function ShakeHud.init(screen: ScreenGui)
	local frame = Instance.new("Frame")
	frame.Name = "ShakeHud"
	frame.BackgroundTransparency = 1
	frame.Size = UDim2.fromScale(1, 1)
	frame.Visible = false
	frame.Parent = screen
	root = frame
end

function ShakeHud.start(_payload: { [string]: any }?)
	running = true
	if root then
		root.Visible = true
	end
end

function ShakeHud.stop(_payload: { [string]: any }?)
	running = false
	if root then
		root.Visible = false
	end
end

function ShakeHud.onNotify(payload: { [string]: any })
	if payload.event == "start" then
		ShakeHud.start(payload)
	elseif payload.event == "stop" then
		ShakeHud.stop(payload)
	end
end

function ShakeHud.onState(data: any)
	local info = type(data) == "table" and type(data.modes) == "table" and data.modes.shake
	if running and not (type(info) == "table" and info.running == true) then
		ShakeHud.stop(nil)
	end
end

return ShakeHud
