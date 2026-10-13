-- Loader (ReplicatedFirst): replaces Roblox's default loading screen with the
-- game's own splash and keeps it up until the player is really in the game:
-- the first State snapshot has arrived (the client sets the player's
-- "GameReady" attribute), the character stands on its plot (the server sets
-- its "OnPlot" attribute), and the world around it has streamed in. Without
-- that the screen faded out over an empty blue sky while the save loaded.
-- It then leaves with a reveal instead of a fade: the splash bursts into a
-- cover that opens as an iris on the player while the camera sweeps in to the
-- spawn shot behind the character (LoadingScreen.finish, Swoop).

local Players = game:GetService("Players")
local ReplicatedFirst = game:GetService("ReplicatedFirst")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local LoadingScreen = require(script:WaitForChild("LoadingScreen"))
local Brand = require(script:WaitForChild("Brand"))
local Swoop = require(script:WaitForChild("Swoop"))

local TIMEOUT = 45
local ART_TIMEOUT = 8

local player = Players.LocalPlayer
local StarterGui = game:GetService("StarterGui")

-- Puts the splash up. Returns its gui, its handle and whether it built.
local function show(): (ScreenGui, LoadingScreen.Handle, boolean)
	local gui = Instance.new("ScreenGui")
	gui.Name = "LoadingScreen"
	gui.IgnoreGuiInset = true
	gui.ResetOnSpawn = false
	-- A script-made ScreenGui defaults to Global z-order, which drew the splash's
	-- whole contents behind its own background: players saw only the gradient.
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
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
			setProgress = function() end,
			finish = function()
				return 0
			end,
		} :: any
	end

	-- Roblox's player list would draw over the splash's top right corner. Hide it
	-- while the player's "Loading" attribute is on; the client keeps it hidden as
	-- one of its own reasons (Kit.hidePlayerList) and puts it back afterwards.
	player:SetAttribute("Loading", true)
	task.spawn(function()
		-- CoreGui calls can fail this early: retry until one lands.
		while player:GetAttribute("Loading") == true do
			local set = pcall(function()
				StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.PlayerList, false)
			end)
			if set then
				break
			end
			task.wait(0.25)
		end
	end)

	-- The brand art ships in ReplicatedFirst too, so it can show from the start
	-- instead of after ReplicatedStorage arrives; fetch it ahead of everything else.
	screen.applyArt({
		keyArt = Brand.KeyArt,
		logo = Brand.Logo,
		logoShine = Brand.LogoShine,
		softDot = Brand.SoftDot,
		sparkle = Brand.Sparkle,
		orb = Brand.Orb,
	})
	return gui, screen, ok
end

-- The player's "reduced motion" setting, from the client's State once it is there.
local function reducedMotion(): boolean
	local scripts = player:FindFirstChild("PlayerScripts")
	local client = scripts and scripts:FindFirstChild("Client")
	local module = client and client:FindFirstChild("State")
	if not module or not module:IsA("ModuleScript") then
		return false
	end
	local ok, state = pcall(require, module :: any)
	local data = if ok and type(state) == "table" then (state :: any).data else nil
	return type(data) == "table" and type(data.settings) == "table" and data.settings.reducedMotion == true
end

-- Takes the splash down with the reveal (a plain fade with reduced motion).
-- `root` is the character's root part when it stands on its plot.
local function leave(gui: ScreenGui, screen: LoadingScreen.Handle, root: BasePart?, speed: number)
	local swooping = false
	local gone = screen.finish(if reducedMotion()
		then nil
		else {
			speed = speed,
			focus = function()
				return if root and root.Parent then Swoop.focus(root) else nil
			end,
			onCovered = function()
				-- First-timers get the intro cutscene next: it takes the camera itself.
				if root and root.Parent and player:GetAttribute("IntroSeen") ~= false then
					swooping = true
					Swoop.play(root, speed)
					swooping = false
				end
			end,
		})
	task.delay(gone, function()
		-- Popups and the intro wait for this gui to go: not before the camera lands.
		while swooping do
			task.wait()
		end
		gui:Destroy()
		-- The list comes back only once the splash has gone.
		player:SetAttribute("Loading", false)
		-- Without the client (it sets "GameReady") nobody else would bring it back.
		if player:GetAttribute("GameReady") ~= true then
			pcall(function()
				StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.PlayerList, true)
			end)
		end
	end)
end

-- The character's root part once the character stands on its plot.
local function rootOnPlot(): BasePart?
	local character = player.Character
	local part = character and character:FindFirstChild("HumanoidRootPart")
	if part and part:IsA("BasePart") and character:GetAttribute("OnPlot") == true then
		return part
	end
	return nil
end

local gui, screen = show()
ReplicatedFirst:RemoveDefaultLoadingScreen()

local started = os.clock()

task.spawn(function()
	pcall(function()
		game:GetService("ContentProvider"):PreloadAsync({
			Brand.KeyArt,
			Brand.Logo,
			Brand.LogoShine,
			Brand.SoftDot,
			Brand.Sparkle,
			Brand.Orb.image,
		})
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

-- The bar follows the stages of the join below.
if not game:IsLoaded() then
	game.Loaded:Wait()
end
screen.setProgress(0.5)
local function timeLeft(): boolean
	return os.clock() - started < TIMEOUT
end
while player:GetAttribute("GameReady") ~= true and timeLeft() do
	task.wait(0.1)
end
screen.setProgress(0.7)
-- The character on its plot (the server moves it there after loading the save).
local root: BasePart? = nil
while timeLeft() do
	root = rootOnPlot()
	if root then
		break
	end
	task.wait(0.1)
end
screen.setProgress(0.85)
-- With streaming on, wait for the parts around the plot before showing it.
if root and workspace.StreamingEnabled and timeLeft() then
	pcall(function()
		player:RequestStreamAroundAsync(root.Position, 10)
	end)
end
screen.setProgress(0.95)
-- A few frames for the camera to settle behind the character.
for _ = 1, 3 do
	RunService.RenderStepped:Wait()
end
-- Keep the splash up briefly so it doesn't just flash on fast joins.
local shown = os.clock() - started
if shown < 1.2 then
	task.wait(1.2 - shown)
end
leave(gui, screen, root, 1)

-- Studio-only capture hook: setting the LocalPlayer attribute "LoadingPreview"
-- to "<holdSeconds>,<speed>" shows the splash again for that long and plays
-- the reveal at that time scale (e.g. "2,0.1" for slow motion).
if RunService:IsStudio() then
	player:GetAttributeChangedSignal("LoadingPreview"):Connect(function()
		local spec = player:GetAttribute("LoadingPreview")
		local hold, speed = string.match(if typeof(spec) == "string" then spec else "", "^([%d%.]+),([%d%.]+)$")
		local playerGui = player:FindFirstChild("PlayerGui")
		if not hold or not playerGui or playerGui:FindFirstChild("LoadingScreen") then
			return
		end
		local againGui, again, ok = show()
		if not ok then
			againGui:Destroy()
			player:SetAttribute("Loading", false)
			return
		end
		local theme = ReplicatedStorage:FindFirstChild("Theme")
		if theme and theme:IsA("ModuleScript") then
			again.applyTheme(require(theme) :: any)
		end
		again.setProgress(0.95)
		task.wait(tonumber(hold) or 0)
		leave(againGui, again, rootOnPlot(), math.max(tonumber(speed) or 1, 0.01))
	end)
end
