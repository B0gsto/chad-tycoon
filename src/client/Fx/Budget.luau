--[[
	Fx.Budget: how much effect work this device gets, so phones stay smooth.

	  Budget.tier()      "low" | "mid" | "high"
	  Budget.scale()     particle / count multiplier (low 0.4, mid 0.7, high 1)
	  Budget.count(n)    max(1, round(n * scale)): emitter rates, burst sizes, caps
	  Budget.low()       shorthand for tier() == "low"
	  Budget.onChange(fn) runs fn(tier) whenever the tier changes; returns a disconnect

	Tier:
	  low   touch input with Automatic or <= 4 graphics quality, or a touch device
	        whose screen's shorter side is under 500 px (a phone)
	  mid   touch otherwise, or graphics quality <= 6
	  high  everything else (desktop / console at quality 7+ or Automatic)

	Re-evaluated when the input mode changes (Kit.onInput), when the player moves
	the graphics slider and when the viewport resizes. Every engine call is in a
	pcall so the Lune preview (stubbed engine) lands on "high". Kit is required
	lazily (deferred) because Kit itself requires Animator and Fx.Sprites, which
	use this module.
]]

local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

export type Tier = "low" | "mid" | "high"

local Budget = {}

local SCALE: { [Tier]: number } = { low = 0.4, mid = 0.7, high = 1 }
local PHONE_SIDE = 500 -- px: a touch screen whose shorter side is under this is a phone

local current: Tier = "high"
local listeners: { (Tier) -> () } = {}
local kit: any = nil

local function touchInput(): boolean
	if kit then
		return kit.touch == true
	end
	local ok, touch = pcall(function()
		return UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled
	end)
	return ok and touch == true
end

-- SavedQualityLevel as a number: 0 = Automatic, 1-10 = the slider; nil when unknown.
local function quality(): number?
	local ok, level = pcall(function()
		local settings = UserSettings():GetService("UserGameSettings")
		return settings.SavedQualityLevel.Value
	end)
	if ok and type(level) == "number" then
		return level
	end
	return nil
end

local function smallTouchScreen(): boolean
	local ok, small = pcall(function()
		if not UserInputService.TouchEnabled then
			return false
		end
		local camera = Workspace.CurrentCamera
		if not camera then
			return false
		end
		local size = camera.ViewportSize
		local side = math.min(size.X, size.Y)
		return side > 1 and side < PHONE_SIDE
	end)
	return ok and small == true
end

local function evaluate(): Tier
	local level = quality()
	local touch = touchInput()
	if touch and (level == 0 or (level ~= nil and level <= 4)) then
		return "low"
	end
	if smallTouchScreen() then
		return "low"
	end
	if touch or (level ~= nil and level >= 1 and level <= 6) then
		return "mid"
	end
	return "high"
end

local function refresh()
	local tier = evaluate()
	if tier == current then
		return
	end
	current = tier
	for _, fn in table.clone(listeners) do
		task.spawn(fn, tier)
	end
end

function Budget.tier(): Tier
	return current
end

function Budget.low(): boolean
	return current == "low"
end

function Budget.scale(): number
	return SCALE[current]
end

function Budget.count(n: number): number
	return math.max(1, math.floor(n * SCALE[current] + 0.5))
end

-- Runs fn(tier) on every change (not now); returns a disconnect function.
function Budget.onChange(fn: (Tier) -> ()): () -> ()
	table.insert(listeners, fn)
	return function()
		local i = table.find(listeners, fn)
		if i then
			table.remove(listeners, i)
		end
	end
end

current = evaluate()

pcall(function()
	local settings = UserSettings():GetService("UserGameSettings")
	settings:GetPropertyChangedSignal("SavedQualityLevel"):Connect(refresh)
end)

local viewportConn: RBXScriptConnection? = nil
local function watchCamera()
	pcall(function()
		if viewportConn then
			viewportConn:Disconnect()
			viewportConn = nil
		end
		local camera = Workspace.CurrentCamera
		if camera then
			viewportConn = camera:GetPropertyChangedSignal("ViewportSize"):Connect(refresh)
		end
		refresh()
	end)
end
watchCamera()
pcall(function()
	Workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(watchCamera)
end)

-- Kit requires modules that require this one: hook its input mode once loading settles.
pcall(function()
	task.defer(function()
		pcall(function()
			local module = script.Parent.Parent:FindFirstChild("UI")
			module = module and module:FindFirstChild("Kit")
			if not module then
				return
			end
			kit = require(module :: any)
			kit.onInput(function()
				refresh()
			end)
		end)
	end)
end)

return Budget
