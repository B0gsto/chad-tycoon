-- Loader (ReplicatedFirst): replaces Roblox's default loading screen with the
-- game's own splash and fades it out once the first State snapshot arrives
-- (the client sets the player's "GameReady" attribute) or after a timeout.

local Players = game:GetService("Players")
local ReplicatedFirst = game:GetService("ReplicatedFirst")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LoadingScreen = require(script:WaitForChild("LoadingScreen"))

local TIMEOUT = 25
local ART_TIMEOUT = 8

local player = Players.LocalPlayer
local gui = Instance.new("ScreenGui")
gui.Name = "LoadingScreen"
gui.IgnoreGuiInset = true
gui.ResetOnSpawn = false
gui.DisplayOrder = 100
pcall(function()
	gui.ScreenInsets = Enum.ScreenInsets.None
end)
gui.Parent = player:WaitForChild("PlayerGui")

local screen = LoadingScreen.build(gui, nil)
ReplicatedFirst:RemoveDefaultLoadingScreen()

local started = os.clock()

task.spawn(function()
	local themeModule = ReplicatedStorage:WaitForChild("Theme", TIMEOUT)
	if themeModule and themeModule:IsA("ModuleScript") then
		local ok, theme = pcall(require, themeModule)
		if ok then
			screen.applyTheme(theme)
		end
	end
end)

-- Brand art: ReplicatedFirst runs before ReplicatedStorage is guaranteed, so
-- wait (briefly) for Shared.Assets and read the brand/KeyArt and brand/Logo
-- ids from it; without them the code-drawn splash stays.
task.spawn(function()
	screen.applyArt(LoadingScreen.findArt(ART_TIMEOUT))
end)

if not game:IsLoaded() then
	game.Loaded:Wait()
end
while player:GetAttribute("GameReady") ~= true and os.clock() - started < TIMEOUT do
	task.wait(0.1)
end
-- Keep the splash up briefly so it doesn't just flash on fast joins.
local shown = os.clock() - started
if shown < 1.2 then
	task.wait(1.2 - shown)
end
screen.finish()
task.delay(1, function()
	gui:Destroy()
end)
