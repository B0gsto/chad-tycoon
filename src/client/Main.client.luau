-- Client entry point: builds the UI and routes server messages.

local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local StarterGui = game:GetService("StarterGui")
local Workspace = game:GetService("Workspace")

local Theme = require(ReplicatedStorage:WaitForChild("Theme"))
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Format = require(Shared.Format)
local Net = require(Shared.Net)

local Client = script.Parent
local State = require(Client.State)
local Sounds = require(Client.Sounds)
local Guide = require(Client.Guide)
local Kit = require(Client.UI.Kit)
local Animator = require(Client.Animator)
local Hud = require(Client.UI.Hud)
local Windows = require(Client.UI.Windows)
local Popups = require(Client.UI.Popups)
local AwayWindow = require(Client.UI.AwayWindow)
local Tutorial = require(Client.UI.Tutorial)
local MogHud = require(Client.UI.MogHud)
local CardioHud = require(Client.UI.CardioHud)
local ObbyHud = require(Client.UI.ObbyHud)

-- The opening cutscene (optional: the game runs without it if it fails to load).
local introOk, Cutscene = pcall(require, Client.Intro.Cutscene)
if not introOk then
	warn("[Intro] failed to load: " .. tostring(Cutscene))
	Cutscene = nil
end

local player = Players.LocalPlayer
local C = Theme.Colors
local I = Theme.Icons

local screen = Instance.new("ScreenGui")
screen.Name = "TycoonUI"
screen.ResetOnSpawn = false
screen.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
screen.IgnoreGuiInset = false
pcall(function()
	-- Keep clear of the Roblox top bar buttons and device notches.
	screen.ScreenInsets = Enum.ScreenInsets.CoreUISafeInsets
end)
screen.Parent = player:WaitForChild("PlayerGui")

-- Scale the whole UI from a 1280x720 design size. Touch screens get a little
-- extra so buttons stay comfortably tappable; a TV (10-foot console, or a
-- gamepad on a big screen) gets extra for the viewing distance and may go up
-- to 3x on 4K; short screens switch the HUD to its compact layout.
local uiScale = Instance.new("UIScale")
uiScale.Parent = screen
local function rescale()
	local camera = Workspace.CurrentCamera
	if not camera then
		return
	end
	local size = camera.ViewportSize
	local topInset = 58
	pcall(function()
		local topLeft = GuiService:GetGuiInset()
		topInset = topLeft.Y
	end)
	local fit = math.min(size.X / 1280, size.Y / 720)
	if Kit.touch then
		fit *= 1.15
	elseif Kit.tenFoot or (Kit.gamepad and size.X >= 1600) then
		fit *= 1.12
	end
	uiScale.Scale = math.clamp(fit, 0.5, if Kit.tenFoot then 3 else 1.5)
	screen:SetAttribute("Compact", (size.Y - topInset) / uiScale.Scale < 600)
	-- Text held at a size on the glass (Kit.holdText) follows the new scale, once the
	-- windows have re-fitted.
	task.defer(Kit.reflowText)
end
-- The viewport is not sized yet in the first frames of a session (it reads 1 x 1): wait for
-- it, or everything built below would be measured for the smallest scale.
do
	local started = os.clock()
	while os.clock() - started < 5 do
		local camera = Workspace.CurrentCamera
		if camera and camera.ViewportSize.X > 1 and camera.ViewportSize.Y > 1 then
			break
		end
		RunService.Heartbeat:Wait()
	end
end
rescale()
-- Kit.px reads the design scale from here, also for labels built off screen.
Kit.pixelScale(screen)
-- Modules that only hold the ScreenGui read the input mode from its Input attribute.
Kit.onInput(function(mode)
	screen:SetAttribute("Input", mode)
	rescale()
end)
-- Console navigation: the D-pad / left stick moves the selection between buttons.
pcall(function()
	GuiService.AutoSelectGuiEnabled = true
end)
pcall(function()
	GuiService.GuiNavigationEnabled = true
end)
Workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(rescale)
if Workspace.CurrentCamera then
	Workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(rescale)
end

Kit.setSoundPlayer(function(name)
	Sounds.play(name)
end)

Animator.start()
Popups.build(screen, Sounds)
Windows.build(screen)
MogHud.build(screen)
CardioHud.build(screen)
-- The Modes window's MOG TEST PLAY opens the VS RIVALS / 1v1 DUEL picker.
Windows.onMogPlay = MogHud.choose
-- "While you were away" (built with the Daily window) opens like any window; a player still
-- in the tutorial gets the plain "Welcome back" popup, one busy for minutes a toast.
AwayWindow.connect({
	open = function(name)
		Windows.open(name)
	end,
	fallback = Popups.offline,
	toast = Popups.toast,
})
Guide.build()
Hud.build(screen, {
	openWindow = Windows.open,
	toast = Popups.toast,
	guide = function(target)
		Guide.navigate(target, "CLAIM!", 45)
	end,
}, Sounds)
-- The sky obby's rainbow progress bar, stage counter, skip button and gear hotbar.
-- Hud's run pill docks into its row; its gear hotbar rides on Hud's dumbbell.
ObbyHud.build(screen, { sounds = Sounds, dockRun = Hud.dockRun, tank = Hud.tank })
-- Last "Cash" effect: the tutorial reward waits for the wallet count-up.
local lastCashAt = 0

Tutorial.build(screen, {
	popups = Popups,
	sounds = Sounds,
	guide = Guide,
	walletIdle = function(): boolean
		return os.clock() - lastCashAt >= 1.5 and Hud.walletIdle()
	end,
	highlight = function(name, on)
		local button = Hud.buttons[name]
		if button then
			Kit.setGlow(button, on)
		end
	end,
})

pcall(function()
	StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Backpack, false)
end)

-- The intro hides the default player list while it plays; registering it as a
-- reason keeps windows that close mid-intro from showing the list again.
player:GetAttributeChangedSignal("IntroPlaying"):Connect(function()
	Kit.hidePlayerList("intro", player:GetAttribute("IntroPlaying") == true)
end)
-- The loading screen hides the list too (the loader sets "Loading" before this
-- script exists); as a reason here, the list comes back once it has faded out.
local function loadingList()
	Kit.hidePlayerList("loading", player:GetAttribute("Loading") == true)
end
player:GetAttributeChangedSignal("Loading"):Connect(loadingList)
loadingList()

local action = Net.event("Action")

-- Plays the intro once, after the first snapshot, for players who haven't seen
-- it (the server sets the "IntroSeen" attribute before that snapshot). The
-- loading screen fades out over its first shot.
local introChecked = false
local function maybePlayIntro()
	if introChecked or not Cutscene then
		return
	end
	introChecked = true
	task.spawn(function()
		local waited = 0
		while player:GetAttribute("IntroSeen") == nil and waited < 3 do
			waited += task.wait(0.1)
		end
		if player:GetAttribute("IntroSeen") ~= false then
			return
		end
		-- Start after the loading screen (ReplicatedFirst) has faded out, not under it.
		local playerGui = player:WaitForChild("PlayerGui")
		while playerGui:FindFirstChild("LoadingScreen") and waited < 50 do
			waited += task.wait(0.1)
		end
		Cutscene.play({
			delay = 0.6,
			onDone = function(skipped: boolean, watched: number)
				action:FireServer({ action = "IntroSeen", skipped = skipped, seconds = watched })
			end,
		})
	end)
end

-- Studio-only capture hook: setting the LocalPlayer attribute "IntroPreview" to
-- "<beat>,<pauseSeconds>" replays the intro paused inside that beat.
if RunService:IsStudio() and Cutscene then
	player:GetAttributeChangedSignal("IntroPreview"):Connect(function()
		local spec = player:GetAttribute("IntroPreview")
		if typeof(spec) ~= "string" or spec == "" then
			return
		elseif spec == "skip" then
			Cutscene.skip()
			return
		end
		local beat, pause = string.match(spec, "^(%d+),?([%d%.]*)$")
		if beat then
			if Cutscene.isPlaying() then
				Cutscene.skip()
				task.wait(0.6)
			end
			-- Deferred so the Studio MCP's camera reset after execute_luau runs first.
			task.wait(0.8)
			Cutscene.preview(tonumber(beat) :: number, tonumber(pause))
		end
	end)
end
-- Studio-only capture hook: "UiPreview" = "<WindowName>", "Shop,<focus>", "close", "starter",
-- "reward,<tier>", "rewards,<from>,<to>" (one reveal per tier), "gift", "surge", "tutorialdone"
-- or "away" (the "While you were away" card, with made-up offline cash).
if RunService:IsStudio() then
	player:GetAttributeChangedSignal("UiPreview"):Connect(function()
		local spec = player:GetAttribute("UiPreview")
		if typeof(spec) ~= "string" or spec == "" then
			return
		end
		local tier = string.match(spec, "^reward,(%d+)$")
		local from, to = string.match(spec, "^rewards,(%d+),(%d+)$")
		if tier then
			-- The production pair is made up here: the "+X Aura/sec" line needs a gain to show.
			Popups.reward({
				kind = "Reward",
				tier = tonumber(tier),
				tiers = { tonumber(tier) },
				new = true,
				productionBefore = 0,
				productionAfter = 12 * 2.4 ^ (tonumber(tier) :: number),
			})
		elseif from and to then
			local tiers = {}
			for t = tonumber(from) :: number, tonumber(to) :: number do
				table.insert(tiers, t)
			end
			Popups.reward({
				kind = "Reward",
				tier = tonumber(to),
				tiers = tiers,
				new = true,
				productionBefore = 0,
				productionAfter = 12 * 2.4 ^ #tiers,
			})
		elseif spec == "gift" then
			Popups.gift({ cash = 3290 })
		elseif spec == "surge" then
			Popups.surge({ phase = "start" })
		elseif spec == "tutorialdone" then
			Popups.tutorialDone(200, function() end)
		elseif spec == "away" then
			AwayWindow.show({ kind = "Offline", seconds = 3 * 3600 + 720, orbs = 5200, cash = 12400 }, true)
		elseif spec == "close" then
			Windows.closeAll()
			Popups.closeModals()
		elseif spec == "starter" then
			Popups.starterOffer()
		elseif string.match(spec, "^Shop,") then
			Windows.open("Shop", { focus = string.sub(spec, 6) })
		else
			Windows.open(spec)
		end
	end)
end

Net.event("State").OnClientEvent:Connect(function(data)
	State.set(data)
	CardioHud.onState(data)
	maybePlayIntro()
	Sounds.updateMusic()
	if data.freeIn and data.freeIn > 0 then
		Guide.clearNavigate("Free")
	end
	-- Tells the loading screen (ReplicatedFirst) that the game is ready.
	if player:GetAttribute("GameReady") ~= true then
		player:SetAttribute("GameReady", true)
	end
end)

Net.event("Notify").OnClientEvent:Connect(function(payload)
	if type(payload) ~= "table" then
		return
	end
	if payload.kind == "Toast" then
		Popups.toast(payload.text, payload.tone)
	elseif payload.kind == "Reward" then
		Popups.reward(payload)
	elseif payload.kind == "Offline" then
		-- Back after a while: the "While you were away" card, once the screen is calm.
		AwayWindow.show(payload)
	elseif payload.kind == "Confirm" then
		Popups.confirm(payload.text, function()
			action:FireServer(payload.action)
		end)
	elseif payload.kind == "Tutorial" then
		Tutorial.onNotify(payload)
	elseif payload.kind == "Gift" then
		-- The free gift's card: { cash, nextIn } (the "Cash" effect of the same claim brings
		-- the sound and the coins).
		Popups.gift(payload)
	elseif payload.kind == "Surge" then
		-- Aura Surge: the countdown chip 30 s ahead and the banner at the start.
		Popups.surge(payload)
	elseif payload.kind == "Mode" and payload.mode == "mog" then
		-- MOG TEST (vs rivals or a 1v1 duel): the picker, queue panel, ring, HP and finish card
		-- (Fx.Mog does the 3D side).
		MogHud.onNotify(payload)
		if payload.event == "stop" and payload.reason == "full" then
			-- All six duel spots are taken: the test never started.
			Popups.toast("The Mog stage is full right now, try again in a moment", "info")
		end
	elseif payload.kind == "Mode" and payload.mode == "cardio" then
		-- CARDIO (keyboard runner): speed counter, stage strip, cards and banners
		-- (Fx.Cardio does the 3D side).
		CardioHud.onNotify(payload)
	elseif payload.kind == "Mode" then
		-- Game-mode runs: the HUD run pill and the finish card (Fx.Modes does the 3D side).
		local event = payload.event
		if event == "pick" then
			-- Walked through gate 1's portal: pick a map (opening the window plays "Open").
			Windows.openMaps(tonumber(payload.level))
		elseif event == "start" then
			-- A run teleports the player onto the course: no window (the map picker, the
			-- Modes window) may stay up over it.
			Windows.closeAll()
			if payload.mode == "parkour" then
				-- The obby HUD owns the top centre for the run: the tycoon's counter, deposit
				-- strip, quest pill, promo and FREE gift step aside; it docks the run pill
				-- before the pill slides in.
				Hud.setObbyMode(true)
				ObbyHud.show(tonumber(payload.stage), tonumber(payload.stageCount))
			end
			Hud.runStart(
				tonumber(payload.startedAt) or workspace:GetServerTimeNow(),
				0,
				tonumber(payload.checkpoints) or 0,
				tonumber(payload.level)
			)
			Sounds.play("Ready")
		elseif event == "checkpoint" then
			Hud.runCheckpoint(tonumber(payload.index) or 0, tonumber(payload.checkpoints) or 0)
			if payload.stage ~= nil then
				ObbyHud.setStage(tonumber(payload.stage), tonumber(payload.stageCount))
			end
			Sounds.play("Step")
		elseif event == "respawn" then
			-- Fell through the clouds (or touched lava): back to the start of the map, the run
			-- goes on. The obby HUD says it ("Oops! Back to the start"); lava adds the sound.
			if payload.stage ~= nil then
				ObbyHud.setStage(tonumber(payload.stage), tonumber(payload.stageCount))
			end
			if payload.reason == "kill" then
				Sounds.play("Error")
			end
		elseif event == "skip" then
			-- Paid a map skip: on to the next map (the run is now assisted).
			ObbyHud.setStage(tonumber(payload.stage), tonumber(payload.stageCount))
			if payload.index ~= nil then
				Hud.runCheckpoint(tonumber(payload.index) or 0, tonumber(payload.checkpoints) or 0)
			end
			Sounds.play("Step")
		elseif event == "finish" then
			Hud.setObbyMode(false)
			Hud.runStop()
			ObbyHud.hide()
			-- "Run again" replays the same level; "Next level" starts the one just unlocked;
			-- "Choose map" opens the Maps window on the next level (or this one).
			local onPick = if payload.mode == "parkour"
				then function()
					Windows.openMaps(tonumber(payload.nextLevel) or tonumber(payload.level))
				end
				else nil
			Popups.modeFinish(payload, function()
				action:FireServer({ action = "ModeStart", mode = payload.mode, level = tonumber(payload.level) })
			end, function()
				action:FireServer({ action = "Home" })
			end, function()
				action:FireServer({ action = "ModeStart", mode = payload.mode, level = tonumber(payload.nextLevel) })
			end, onPick)
		elseif event == "invalid" then
			Hud.setObbyMode(false)
			Hud.runStop()
			ObbyHud.hide()
			Popups.toast(
				if payload.reason == "fast" then "Whoa, too fast! Try the course again" else "Something went wrong, try the map again",
				"info"
			)
		elseif event == "stop" then
			Hud.setObbyMode(false)
			Hud.runStop()
			ObbyHud.hide()
			if payload.reason == "left" then
				Popups.toast("You left the course. Run ended", "info")
			elseif payload.reason == "respawn" then
				Popups.toast("Run reset. Hop back in at the gate!", "info")
			elseif payload.reason == "quit" then
				Popups.toast("Run ended", "info")
			end
		end
	end
end)

-- Floating "+X" anchors: beside the HUD dumbbell (bottom centre) and above the
-- cash amount (bottom left).
local TANK = UDim2.new(0.5, 170, 1, -90)
local WALLET = UDim2.new(0, 150, 1, -110)

-- Sounds for effects owned by the UI. Fx modules (Client.Fx.*) listen to the
-- same remote for their 3D work and their own sounds (OrbPickup, MergeCharge,
-- MergeBoom, BuyPop): no sound here for "Merge".
Net.event("Effect").OnClientEvent:Connect(function(kind, data)
	data = if type(data) == "table" then data else {}
	if kind == "Collect" then
		-- Silent: Fx.Orbs already popped for each pickup.
		Hud.pulseTank()
		Popups.float("+" .. I.Orb .. Format.short(data.amount or 0), C.Orb, TANK)
	elseif kind == "Cash" then
		-- Auto Cash pays out every few seconds: no sound, float or coin burst for it, the
		-- wallet number simply rolls up.
		if data.source == "Auto" then
			return
		end
		local amount = if type(data.amount) == "number" then data.amount else 0
		lastCashAt = os.clock()
		if data.source == "Purchase" then
			-- Developer-product cash pack: full-screen celebration (plays its own sounds).
			Popups.purchase(amount)
			Hud.coinBurst(amount, nil)
			return
		end
		if data.source == "Daily" then
			-- Daily reward: the amount pops over the Daily window and the coins fly out of it.
			Sounds.play("Cash")
			Popups.float("+" .. Format.money(amount), C.Good, UDim2.fromScale(0.5, 0.42))
			Hud.coinBurst(amount, nil, nil)
			return
		end
		Sounds.play("Cash")
		-- The free gift's amount is on its card (the Gift notify), not in a small float.
		if data.source ~= "Free" then
			Popups.float("+" .. Format.money(amount), C.Good, WALLET)
		end
		-- Claimed from the Free menu button: coins fly from the button.
		local fromMenu = data.source == "Free" and os.clock() - Hud.freeClaimedAt < 3
		-- A pad's coins (Collect, the Free pad walked onto) are Fx.Machines' fountain, which
		-- flies to the wallet: no second stream of flat coins from the same pad.
		if data.source == "Collect" or (data.source == "Free" and not fromMenu) then
			return
		end
		Hud.coinBurst(amount, if typeof(data.padPos) == "Vector3" then data.padPos else nil, if fromMenu then Hud.buttons.Free else nil)
	elseif kind == "Pad" then
		-- Fx.Machines plays the deny sound and pad wobble; the wallet shake
		-- guards against double calls.
		if data.ok == false and data.reason == "money" then
			Hud.shakeWallet()
		end
	elseif kind == "Deposit" then
		Sounds.play("Deposit")
		-- `amount` is the aura queued in the converter; the deposit multiplier's part is `bonus`,
		-- cash paid at once (Economy.depositSplit), so the float names it as cash.
		local text = I.Orb .. Format.short(if type(data.amount) == "number" then data.amount else 0)
		if type(data.bonus) == "number" and data.bonus >= 1 then
			text ..= "  +" .. Format.money(data.bonus) .. " bonus"
		end
		Popups.float(text, C.Primary, TANK)
	elseif kind == "Buy" then
		Sounds.play("Buy", 0.1)
	elseif kind == "Merge" then
		Popups.noteMerge()
	elseif kind == "Upgrade" then
		Sounds.play("Upgrade")
	elseif kind == "ChestOpen" then
		-- The crate reveal (Popups) plays its own shake/burst sounds.
		Popups.noteChestOpen(data.rarity)
	elseif kind == "ChestPickup" then
		Sounds.play("Pickup")
	elseif kind == "CardioSteps" then
		CardioHud.onSteps(data)
	end
end)

-- 3D effect modules (built by other streams; any may be missing or fail).
local fxFolder = Client:FindFirstChild("Fx")
if fxFolder then
	for _, name in
		{
			"Camera",
			"Shelf",
			"Orbs",
			"Machines",
			"Crates",
			"Fans",
			"PlotRank",
			"Ambient",
			"Plates",
			"Cosmetics",
			"Modes",
			"Mog",
			"Surge",
			"Cardio",
			"CardioChase",
			"Interactive",
		}
	do
		local moduleScript = fxFolder:FindFirstChild(name)
		if moduleScript and moduleScript:IsA("ModuleScript") then
			local ok, err = pcall(function()
				local fx = require(moduleScript) :: any
				if type(fx) == "table" and type(fx.init) == "function" then
					fx.init()
				end
			end)
			if not ok then
				warn("[Fx] " .. name .. " failed: " .. tostring(err))
			end
		end
	end
end

-- Ask for a fresh snapshot now that every listener is connected.
action:FireServer({ action = "Sync" })
