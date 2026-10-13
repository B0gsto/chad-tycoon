-- Loader (ReplicatedFirst): replaces Roblox's default loading screen with the
-- game's own, which is an animation and not a picture. A sky cover with the
-- logo and the progress bar holds until the map has arrived; then the camera
-- circles high over the map while the rest loads: the first State snapshot
-- (the client sets the player's "GameReady" attribute), the character on its
-- plot (the server sets its "OnPlot" attribute) and the world round it. Then
-- the logo and bar leave and the camera comes down to the spawn shot behind
-- the character (LoadingScreen, Flyover). The HUD and the controls stay off
-- until it has landed.

local Players = game:GetService("Players")
local ReplicatedFirst = game:GetService("ReplicatedFirst")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local LoadingScreen = require(script:WaitForChild("LoadingScreen"))
local Brand = require(script:WaitForChild("Brand"))
local Flyover = require(script:WaitForChild("Flyover"))

local TIMEOUT = 45
local ART_TIMEOUT = 8
-- The least time the camera circles before it comes down (seconds).
local MIN_FLIGHT = 3

local player = Players.LocalPlayer
local StarterGui = game:GetService("StarterGui")

-- Puts the loading screen up. Returns its gui and its handle.
local function show(): (ScreenGui, LoadingScreen.Handle)
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
			open = function()
				cover:Destroy()
			end,
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

	-- The logo and sprites ship in ReplicatedFirst too, so they can show from
	-- the start instead of after ReplicatedStorage arrives.
	screen.applyArt({
		logo = Brand.Logo,
		logoShine = Brand.LogoShine,
		softDot = Brand.SoftDot,
		sparkle = Brand.Sparkle,
		orb = Brand.Orb,
	})
	return gui, screen
end

-- The game's own screens (the HUD) would sit on top of the flight: keep them
-- off until it has landed. Returns the function that puts them back.
local function hideGame(own: ScreenGui): () -> ()
	local hidden: { ScreenGui } = {}
	local connection = RunService.RenderStepped:Connect(function()
		local playerGui = player:FindFirstChild("PlayerGui")
		for _, child in if playerGui then playerGui:GetChildren() else {} do
			if child:IsA("ScreenGui") and child ~= own and child.Enabled and child.DisplayOrder < 100 then
				child.Enabled = false
				table.insert(hidden, child)
			end
		end
	end)
	return function()
		connection:Disconnect()
		for _, child in hidden do
			child.Enabled = true
		end
	end
end

-- Walking about under a camera that is somewhere else: the controls stay off
-- until the flight has landed. Returns the function that puts them back.
local function lockControls(): () -> ()
	local controls: any = nil
	local released = false
	task.spawn(function()
		local scripts = player:WaitForChild("PlayerScripts", TIMEOUT)
		local module = scripts and scripts:WaitForChild("PlayerModule", TIMEOUT)
		if released or not module or not module:IsA("ModuleScript") then
			return
		end
		local ok, found = pcall(function()
			return (require(module) :: any):GetControls()
		end)
		if ok and found and not released then
			controls = found
			controls:Disable()
		end
	end)
	return function()
		released = true
		if controls then
			controls:Enable()
		end
	end
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

-- One loading screen from the moment the world may be seen: the sky cover
-- fades off the camera circling the map; `ready` yields until the player is
-- in the game and returns the character's root part; then the logo and band
-- leave and the camera comes down to the character.
local function fly(gui: ScreenGui, screen: LoadingScreen.Handle, ready: () -> BasePart?, speed: number)
	local showGame = hideGame(gui)
	local freeControls = lockControls()
	local flight = Flyover.start(speed)
	screen.open(speed)
	local opened = os.clock()
	local root = ready()
	-- Long enough over the map to read as a flight, even on a fast join.
	local short = MIN_FLIGHT / speed - (os.clock() - opened)
	if short > 0 then
		task.wait(short)
	end
	screen.finish(speed)
	if reducedMotion() then
		flight.stop()
	else
		flight.land(root, speed)
	end
	freeControls()
	showGame()
	gui:Destroy()
	-- The list comes back only once the flight has landed.
	player:SetAttribute("Loading", false)
	-- Without the client (it sets "GameReady") nobody else would bring it back.
	if player:GetAttribute("GameReady") ~= true then
		pcall(function()
			StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.PlayerList, true)
		end)
	end
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
local function timeLeft(): boolean
	return os.clock() - started < TIMEOUT
end

task.spawn(function()
	pcall(function()
		game:GetService("ContentProvider"):PreloadAsync({
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

-- ReplicatedFirst runs before ReplicatedStorage is guaranteed, so wait
-- (briefly) for Shared.Assets and take the art ids from it as well.
task.spawn(function()
	screen.applyArt(LoadingScreen.findArt(ART_TIMEOUT))
end)

-- The bar follows the stages of the join below. Under the sky cover: the map.
if not game:IsLoaded() then
	game.Loaded:Wait()
end
while timeLeft() do
	local map = workspace:FindFirstChild("Map")
	if map and #map:GetChildren() > 0 then
		break
	end
	task.wait(0.1)
end
screen.setProgress(0.4)
fly(gui, screen, function(): BasePart?
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
	-- With streaming on, wait for the parts around the plot before landing there.
	if root and workspace.StreamingEnabled and timeLeft() then
		pcall(function()
			player:RequestStreamAroundAsync(root.Position, 10)
		end)
	end
	screen.setProgress(0.95)
	return root
end, 1)

-- Studio-only capture hook: setting the LocalPlayer attribute "LoadingPreview"
-- to "<seconds>,<speed>" plays the loading screen again: that long under the
-- sky cover, then the flight and the landing at that time scale (e.g. "1,0.2"
-- for slow motion).
if RunService:IsStudio() then
	player:GetAttributeChangedSignal("LoadingPreview"):Connect(function()
		local spec = player:GetAttribute("LoadingPreview")
		local hold, speed = string.match(if typeof(spec) == "string" then spec else "", "^([%d%.]+),([%d%.]+)$")
		local playerGui = player:FindFirstChild("PlayerGui")
		if not hold or not playerGui or playerGui:FindFirstChild("LoadingScreen") then
			return
		end
		local againGui, again = show()
		local theme = ReplicatedStorage:FindFirstChild("Theme")
		if theme and theme:IsA("ModuleScript") then
			again.applyTheme(require(theme) :: any)
		end
		again.setProgress(0.4)
		task.wait(tonumber(hold) or 0)
		fly(againGui, again, function()
			again.setProgress(0.95)
			return rootOnPlot()
		end, math.max(tonumber(speed) or 1, 0.01))
	end)
end
