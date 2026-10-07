-- Loader (ReplicatedFirst): replaces Roblox's default loading screen with the
-- game's own splash and keeps it up until the player is really in the game:
-- the first State snapshot has arrived (the client sets the player's
-- "GameReady" attribute), the character stands on its plot (the server sets
-- its "OnPlot" attribute), and the world around it has streamed in. Without
-- that the screen faded out over an empty blue sky while the save loaded.

local Players = game:GetService("Players")
local ReplicatedFirst = game:GetService("ReplicatedFirst")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local LoadingScreen = require(script:WaitForChild("LoadingScreen"))
local Brand = require(script:WaitForChild("Brand"))

local TIMEOUT = 45
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

-- If the splash ever fails to build, a plain dark cover still hides the sky.
local ok, built = pcall(LoadingScreen.build, gui, Brand)
local screen: LoadingScreen.Handle
if ok then
	screen = built
else
	warn("LoadingScreen failed:", built)
	local cover = Instance.new("Frame")
	cover.BackgroundColor3 = Color3.fromRGB(46, 62, 136)
	cover.BorderSizePixel = 0
	cover.Size = UDim2.fromScale(1, 1)
	cover.Parent = gui
	screen = {
		applyTheme = function() end,
		applyArt = function() end,
		setStatus = function() end,
		finish = function() end,
	} :: any
end
ReplicatedFirst:RemoveDefaultLoadingScreen()

local started = os.clock()

-- The brand art ships in ReplicatedFirst too, so it can show from the start
-- instead of after ReplicatedStorage arrives; fetch it ahead of everything else.
screen.applyArt({ keyArt = Brand.KeyArt, logo = Brand.Logo })
task.spawn(function()
	pcall(function()
		game:GetService("ContentProvider"):PreloadAsync({ Brand.KeyArt, Brand.Logo })
	end)
end)

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
local function timeLeft(): boolean
	return os.clock() - started < TIMEOUT
end
while player:GetAttribute("GameReady") ~= true and timeLeft() do
	task.wait(0.1)
end
-- The character on its plot (the server moves it there after loading the save).
local root: BasePart? = nil
while timeLeft() do
	local character = player.Character
	local part = character and character:FindFirstChild("HumanoidRootPart")
	if part and part:IsA("BasePart") and character:GetAttribute("OnPlot") == true then
		root = part
		break
	end
	task.wait(0.1)
end
-- With streaming on, wait for the parts around the plot before showing it.
if root and workspace.StreamingEnabled and timeLeft() then
	pcall(function()
		player:RequestStreamAroundAsync(root.Position, 10)
	end)
end
-- A few frames for the camera to settle behind the character.
for _ = 1, 3 do
	RunService.RenderStepped:Wait()
end
-- Keep the splash up briefly so it doesn't just flash on fast joins.
local shown = os.clock() - started
if shown < 1.2 then
	task.wait(1.2 - shown)
end
screen.finish()
task.delay(if ok then 1 else 0, function()
	gui:Destroy()
end)
