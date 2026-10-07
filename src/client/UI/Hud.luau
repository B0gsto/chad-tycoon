--[[
	Hud: always-on screen elements (design space 1280x720, below the top bar).
	Laid out like the owner's reference game: no panels or chips, just chunky
	icons and bold white Ink-outlined text straight over the world.

	  top bar right  Settings gear alone (Roblox's player list sits under it)
	  top centre     Chad icon + unit count "37/100" (sunny + "RACK FULL" when full)
	                 under it a low dark strip "Deposit bonus: x1.3 · 12s"
	                 ("AURA SURGE x2 · 1:23" in orange during a surge); the
	                 tutorial quest pill and the parkour run pill dock under that
	  left edge      icon grid with captions: Home Ranking Modes / Index Shop Invite
	                 promo under it: tilted "PERMANENT" tag, wide 2X CASH (or
	                 STARTER PACK) button, "Only 199 R$"
	  bottom left    status row (Premium, Friends, Boost), "Cash [ x1.0 ]",
	                 the big cash amount + square "+"
	  bottom centre  the dumbbell: "AURA" + the carried amount on its plaque
	  bottom right   FREE gift with its countdown, version in the corner

	Numbers roll, things pop and the HUD staggers in when it is built. While a
	window is open (attribute "WindowOpen") the groups slide off their edges.
	Short screens (attribute "Compact") get smaller grid icons, drop the status
	captions and the promo, and hide Roblox's player list.

	Input (Kit.onInput, re-placed live): on touch the wallet moves to the top
	left with the grid under it (one row on phones) so nothing sits on Roblox's
	thumbstick (bottom-left third, lower half) or jump button, the FREE gift
	rises above the jump button, the gear leaves the top bar and every button is
	at least 44 screen px (invisible hit pads on the small ones). On gamepad / TV
	the edges get a title-safe margin; every HUD button is Selectable (the Kit
	ring, hover scale on SelectionGained) unless a window or dialog is open.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local SocialService = game:GetService("SocialService")
local TextService = game:GetService("TextService")
local Workspace = game:GetService("Workspace")

local Economy = require(ReplicatedStorage.Shared.Economy)
local Format = require(ReplicatedStorage.Shared.Format)
local Net = require(ReplicatedStorage.Shared.Net)

local Kit = require(script.Parent.Kit)
local State = require(script.Parent.Parent.State)

local Theme = Kit.Theme
local C = Kit.C
local F = Kit.F
local W = Theme.Words

local Hud = {}

export type Handlers = {
	openWindow: (string, { focus: string? }?) -> (),
	guide: ((string?) -> ())?,
	toast: ((string, string?) -> ())?,
}

-- Buttons by name (Shop, Index, Ranking, Free, Home, Invite, Settings, Modes) so
-- other modules (tutorial, guide) can badge, glow or aim coin bursts at them.
Hud.buttons = {} :: { [string]: TextButton }

-- Filled in by build(); safe no-ops before that.
Hud.pulseTank = function(_big: boolean?) end
Hud.coinBurst = function(_amount: number, _padPos: Vector3?, _fromGui: GuiObject?) end
-- Aura orbs burst from the screen centre into the dumbbell tank (aura pack bought).
Hud.orbBurst = function(_amount: number) end
-- os.clock() of the last free-reward claim from the HUD (Main flies those coins from it).
Hud.freeClaimedAt = 0
-- Red shake on the cash amount ("can't afford").
Hud.shakeWallet = function() end
-- Game-mode run pill (timer + checkpoints + quit).
Hud.runStart = function(_startedAt: number, _checkpoint: number, _checkpoints: number, _level: number?) end
Hud.runCheckpoint = function(_index: number, _checkpoints: number) end
Hud.runStop = function() end
-- The sky obby docks the run pill into its own row (pos + anchor; nil puts it back).
Hud.dockRun = function(_pos: UDim2?, _anchor: Vector2?) end
-- A parkour run is on: the tycoon's top centre (units, deposit strip), the quest pill,
-- the promo and the FREE gift step aside for the obby HUD; off brings them back.
Hud.setObbyMode = function(_on: boolean) end
-- The dumbbell group (the obby gear hotbar sits on top of it).
Hud.tank = nil :: Frame?
-- True once the cash counter has finished rolling.
Hud.walletIdle = function(): boolean
	return true
end

-- Layout (design px). The top centre group sits just under the top bar.
local EDGE_X = 14
local UNITS_Y = 4 -- unit counter row: y 4..48
local STRIP_Y = 54 -- deposit strip: y 54..84
local STRIP_H = 30
local RUN_Y = 92 -- tutorial / run pill slot (Tutorial.luau TOP_Y matches)
local GRID_Y = 104 -- left icon grid, first row
local GRID_ICON = 64
local GRID_ICON_COMPACT = 48
local GRID_GAP_X = 10
local GRID_GAP_Y = 18 -- room for the caption under each row
local GEAR = 44
local DUMBBELL_W = 264
local DUMBBELL_W_COMPACT = 200
local DUMBBELL_ASPECT = 448 / 1024
local NARROW_PX = 900
local TAP_PX = 44 -- smallest touch target, in screen px
local TOP_BAR_PX = 58
local SAFE_X = 40 -- gamepad / TV title-safe edge (design px)
local SAFE_BOTTOM = 24
local PREMIUM_BONUS = 10

local function textWidth(text: string, size: number, font: Enum.Font): number
	local plain = string.gsub(text, "<[^>]->", "")
	local ok, bounds = pcall(function()
		return TextService:GetTextSize(plain, size, font, Vector2.new(2000, 200))
	end)
	if ok and typeof(bounds) == "Vector2" and bounds.X > 0 then
		return math.ceil(bounds.X)
	end
	return math.ceil(#plain * size * 0.6)
end

-- A row of guis laid out left to right and centred vertically: icons keep their
-- width, labels are measured. Hidden items take no space. Returns the end x.

function Hud.build(screen: ScreenGui, handlers: Handlers, sounds: any)
	local action = Net.event("Action")
	local compact = false
	local promoFits = true -- touch: the promo only shows where it clears the thumbstick
	local screenScale = screen:FindFirstChildOfClass("UIScale")

	local function toast(text: string, tone: string?)
		if handlers.toast then
			handlers.toast(text, tone)
		end
	end
	local function designSize(): Vector2
		local ok, absolute = pcall(function()
			return screen.AbsoluteSize
		end)
		if not ok or typeof(absolute) ~= "Vector2" then
			return Vector2.zero
		end
		return absolute / (if screenScale then screenScale.Scale else 1)
	end

	-- Rolling numbers: each label counts from what it last showed to the new
	-- value (Kit.countTo); unchanged values just re-render (number format setting).
	local rolled: { [Instance]: number } = {}
	local rollEnds: { [Instance]: number } = {}
	local function roll(label: TextLabel, value: number, format: (number) -> string, duration: number?)
		local last = rolled[label]
		rolled[label] = value
		if last == nil or last == value then
			if (rollEnds[label] or 0) <= os.clock() then
				label.Text = format(value)
			end
			return
		end
		local time = duration or 0.45
		Kit.countTo(label, last, value, format, time)
		rollEnds[label] = os.clock() + time
	end
	-- A transparent group frame (HUD blocks have no backing).
	local function group(name: string, props: { [string]: any }): Frame
		props.Name = name
		props.BackgroundTransparency = 1
		props.Parent = props.Parent or screen
		return Kit.new("Frame", props)
	end
	-- Invisible hit pads grow small buttons to TAP_PX on touch (sized in place()).
	local pads: { { pad: TextButton, button: GuiObject } } = {}
	local function hitPad(button: GuiObject, onClick: () -> ())
		local pad = Kit.new("TextButton", {
			Name = "Hit",
			Text = "",
			AutoButtonColor = false,
			BackgroundTransparency = 1,
			Selectable = false,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromScale(1, 1),
			Visible = false,
			ZIndex = 30,
			Parent = button,
		})
		pad.Activated:Connect(function()
			Kit.sound("Click")
			onClick()
		end)
		table.insert(pads, { pad = pad, button = button })
	end
	-- A panel-less tap target: icon + caption are children, the button itself is
	-- the icon square (badges and glow rings sit on it).
	local function bareButton(parent: Instance, name: string, size: number, onClick: () -> ()): TextButton
		local button = Kit.new("TextButton", {
			Name = name,
			Text = "",
			AutoButtonColor = false,
			BackgroundTransparency = 1,
			Size = UDim2.fromOffset(size, size),
			Parent = parent,
		})
		local scale = Kit.new("UIScale", { Parent = button })
		Kit.selectable(button)
		local function hover()
			Kit.tween(scale, 0.12, { Scale = 1.07 })
		end
		local function unhover()
			Kit.tween(scale, 0.12, { Scale = 1 })
		end
		button.MouseEnter:Connect(hover)
		button.MouseLeave:Connect(unhover)
		-- Gamepad selection shows the same lift as the mouse hover.
		pcall(function()
			button.SelectionGained:Connect(hover)
			button.SelectionLost:Connect(unhover)
		end)
		button.MouseButton1Down:Connect(function()
			Kit.tween(scale, 0.08, { Scale = 0.92 })
		end)
		button.MouseButton1Up:Connect(function()
			Kit.tween(scale, 0.15, { Scale = 1 }, Enum.EasingStyle.Back)
		end)
		button.Activated:Connect(function()
			Kit.sound("Click")
			onClick()
		end)
		return button
	end

	-- Top bar, far right: the Settings gear alone ----------------------------------------
	-- It sits on the top bar's line (above our safe area) so Roblox's player list,
	-- which starts under the top bar, never covers it.
	local gear = bareButton(screen, "Settings", GEAR, function()
		handlers.openWindow("Settings")
	end)
	gear.AnchorPoint = Vector2.new(1, 0)
	gear.Position = UDim2.new(1, -10, 0, -GEAR - 7)
	Kit.hudIcon(gear, "Settings", GEAR, C.Text, { Name = "Icon", ZIndex = 2 }).Size = UDim2.fromScale(1, 1)
	Hud.buttons.Settings = gear

	-- Left edge: icon grid with captions --------------------------------------------------
	local GRID_ROWS = { { "Home", "Ranking", "Modes" }, { "Index", "Shop", "Invite" } }
	local CAPTIONS: { [string]: string } = {
		Home = "Home",
		Ranking = "Ranking",
		Modes = "Modes",
		Index = "Index",
		Shop = "Shop",
		Invite = "Invite",
	}
	-- Modes draws the rendered finish-flag image; Star stands in if it is missing.
	local ICON_FOR: { [string]: string } = { Modes = Kit.pickIcon("Modes", "Star") }
	local grid = group("Menu", { Position = UDim2.fromOffset(EDGE_X, GRID_Y) })
	local captions: { TextLabel } = {}
	local function gridButton(name: string, onClick: () -> ()): TextButton
		local button = bareButton(grid, name, GRID_ICON, onClick)
		local icon = Kit.hudIcon(button, ICON_FOR[name] or name, GRID_ICON, C.Text, { Name = "Icon", ZIndex = 2 })
		icon.Size = UDim2.fromScale(1, 1)
		local caption = Kit.hudText(button, {
			Name = "Caption",
			Text = CAPTIONS[name],
			TextSize = 18,
			Size = UDim2.new(1, 16, 0, 20),
			Position = UDim2.new(0.5, 0, 1, 6),
			AnchorPoint = Vector2.new(0.5, 1),
			ZIndex = 4,
		})
		table.insert(captions, caption)
		button:SetAttribute("Label", CAPTIONS[name])
		Hud.buttons[name] = button
		return button
	end

	-- New discoveries since the Index was last opened (badge).
	local seenDiscoveries: number? = nil
	local function discoveredCount(data: { [string]: any }): number
		local found = 0
		for tier = 1, Economy.MAX_TIER do
			if (data.discovered[tier] or 0) > 0 then
				found += 1
			end
		end
		return found
	end
	local function refreshIndexBadge()
		local data = State.data
		if not data or not seenDiscoveries then
			return
		end
		local fresh = discoveredCount(data) - seenDiscoveries
		Kit.setBadge(Hud.buttons.Index, if fresh > 0 then tostring(fresh) else nil)
	end
	gridButton("Home", function()
		action:FireServer({ action = "Home" })
	end)
	gridButton("Ranking", function()
		handlers.openWindow("Ranking")
	end)
	gridButton("Modes", function()
		Kit.setGlow(Hud.buttons.Modes, false)
		handlers.openWindow("Modes")
	end)
	gridButton("Index", function()
		Kit.setGlow(Hud.buttons.Index, false)
		local data = State.data
		if data then
			seenDiscoveries = discoveredCount(data)
			refreshIndexBadge()
		end
		handlers.openWindow("Index")
	end)
	gridButton("Shop", function()
		handlers.openWindow("Shop")
	end)
	gridButton("Invite", function()
		pcall(function()
			SocialService:PromptGameInvite(Players.LocalPlayer)
		end)
	end)
	-- Right after the tutorial finishes (watched live this session), one toast and a
	-- soft glow point at the Modes button.
	local tutorialWasOpen = false
	State.changed.Event:Connect(function(data)
		if data.tutorialDone ~= true then
			tutorialWasOpen = true
		elseif tutorialWasOpen then
			tutorialWasOpen = false
			task.delay(9, function()
				Kit.setGlow(Hud.buttons.Modes, true)
				toast("New! " .. (if Kit.touch then "Tap" else "Open") .. " MODES to try Parkour and the Mog Test", "info")
			end)
		end
	end)

	-- Promo under the grid: tilted tag, wide button, price line ---------------------------
	-- Starter pack until it is owned, then 2X CASH until that is owned, then nothing.
	local PROMOS = {
		Starter = { tag = "LIMITED", text = "STARTER PACK", price = 59, focus = Theme.Cosmetics.Starter.Pass },
		DoubleMoney = { tag = "PERMANENT", text = "2X CASH", price = 199, focus = "DoubleMoney" },
	}
	local PROMO_W, PROMO_H = 3 * GRID_ICON + 2 * GRID_GAP_X, 44
	local promo = group("Promo", { Size = UDim2.fromOffset(PROMO_W, PROMO_H + 40), Visible = false })
	local promoMode = "DoubleMoney"
	local promoButton = Kit.button(promo, {
		Name = "Button",
		Text = "2X CASH",
		Font = F.Display,
		TextSize = 24,
		TextColor = Color3.new(1, 1, 1),
		Color = C.Cash,
		Size = UDim2.fromOffset(PROMO_W, PROMO_H),
		Position = UDim2.fromOffset(0, 12),
		Radius = 12,
		Depth = 4,
	}, function()
		handlers.openWindow("Shop", { focus = PROMOS[promoMode].focus })
	end)
	local promoLabel = Kit.buttonLabel(promoButton)
	if promoLabel then
		local stroke = promoLabel:FindFirstChildOfClass("UIStroke") or Kit.textStroke(promoLabel, 2.5, 0)
		stroke.Color = C.Ink
		stroke.Thickness = 2.5
		stroke.Transparency = 0
	end
	local promoTag = Kit.hudText(promo, {
		Name = "Tag",
		Text = "PERMANENT",
		TextSize = 15,
		TextColor3 = C.Gold,
		Size = UDim2.fromOffset(110, 18),
		Position = UDim2.fromOffset(-4, 2),
		Rotation = -8,
		ZIndex = 8,
	})
	local promoPrice = Kit.hudText(promo, {
		Name = "Price",
		Text = "Only 199 " .. Kit.ROBUX,
		TextSize = 18,
		Size = UDim2.fromOffset(PROMO_W, 22),
		Position = UDim2.fromOffset(0, PROMO_H + 18),
		ZIndex = 3,
	})
	local function dressPromo(mode: string)
		promoMode = mode
		local look = PROMOS[mode]
		if promoLabel then
			promoLabel.Text = look.text
		end
		promoTag.Text = look.tag
		promoPrice.Text = string.format("Only %d %s", look.price, Kit.ROBUX)
	end
	local stopPromoShine: (() -> ())? = nil
	local promoShown = false
	local function wantedPromo(): string?
		local data = State.data
		if not data then
			return nil
		end
		local cosmetics = data.cosmetics
		if not (type(cosmetics) == "table" and cosmetics.starterOwned == true) then
			return "Starter"
		elseif data.passes.DoubleMoney ~= true then
			return "DoubleMoney"
		end
		return nil
	end
	local function updatePromo()
		local mode = wantedPromo()
		local show = mode ~= nil
			and not compact
			and promoFits
			and screen:GetAttribute("WindowOpen") ~= true
			and screen:GetAttribute("ObbyMode") ~= true
			and screen:GetAttribute("CardioActive") ~= true -- a Cardio run keeps the screen clear
		if show and mode ~= promoMode then
			if promoShown then
				-- Switching offers: the old one eases out, the new one eases in.
				promoShown = false
				Kit.disappear(promo, {
					to = 0.85,
					time = 0.18,
					onDone = function()
						dressPromo(mode :: string)
						updatePromo()
					end,
				})
				return
			end
			dressPromo(mode :: string)
		end
		if show == promoShown then
			return
		end
		promoShown = show
		if show then
			Kit.appear(promo, { from = 0.8, time = 0.26 })
			local face = Kit.buttonFace(promoButton)
			if face and not stopPromoShine then
				stopPromoShine = Kit.shimmer(face, 7, 5)
			end
		else
			Kit.disappear(promo, { to = 0.85, time = 0.18 })
			if mode == nil and stopPromoShine then
				stopPromoShine()
				stopPromoShine = nil
			end
		end
	end
	dressPromo("DoubleMoney")

	-- Bottom right: FREE gift + countdown, version in the corner --------------------------
	local corner = group("FreeCorner", {
		Size = UDim2.fromOffset(84, 92),
		AnchorPoint = Vector2.new(1, 1),
	})
	local freeButton = bareButton(corner, "Free", 60, function()
		local data = State.data
		if not data then
			return
		end
		local left = math.max(0, (data.freeIn or 0) - State.age())
		if left <= 0 then
			-- Claim straight from the HUD; the server answers with a "Cash" effect
			-- (source "Free") that flies coins into the cash amount.
			action:FireServer({ action = "ClaimFree" })
			Hud.freeClaimedAt = os.clock()
			local button = Hud.buttons.Free
			if button then
				Kit.pop(button, 1.4)
				Kit.confetti(button, {
					Origin = UDim2.fromScale(0.5, 0.4),
					Count = 14,
					ZIndex = 12,
					Colors = { C.Cash, C.GoldLight, Color3.new(1, 1, 1) },
					Power = 0.5,
				})
			end
		else
			toast("Next free reward in " .. Format.time(left), "info")
		end
	end)
	freeButton.AnchorPoint = Vector2.new(0.5, 0)
	freeButton.Position = UDim2.fromScale(0.5, 0)
	freeButton:SetAttribute("Label", "Free")
	Kit.hudIcon(freeButton, Kit.pickIcon("Free", "Gift2"), 60, C.Gold, { Name = "Icon", ZIndex = 2 }).Size = UDim2.fromScale(1, 1)
	Hud.buttons.Free = freeButton
	local freeTimer = Kit.hudText(corner, {
		Name = "Timer",
		Text = "",
		TextSize = 20,
		Size = UDim2.new(1, 0, 0, 22),
		Position = UDim2.new(0.5, 0, 0, 62),
		AnchorPoint = Vector2.new(0.5, 0),
		ZIndex = 3,
	})
	local version = Kit.hudText(screen, {
		Name = "Version",
		Text = "v" .. Economy.VERSION,
		Font = F.UI,
		TextSize = 12,
		StrokeThickness = 1.5,
		Size = UDim2.fromOffset(80, 14),
		Position = UDim2.new(1, -8, 1, -4),
		AnchorPoint = Vector2.new(1, 1),
		TextXAlignment = Enum.TextXAlignment.Right,
		TextTransparency = 0.15,
	})
	version.ZIndex = 1

	-- Run pill: a game-mode run's timer under the multiplier chip (the tutorial pill's
	-- slot; ScreenGui attribute "RunActive" tells Tutorial to step aside). Timer from the
	-- server clock, checkpoint n/N, and an "x" that asks "QUIT?" before firing ModeQuit.
	-- A gold "L3" chip on the left names the Parkour level (the Star shows without one).
	local RUN_W, RUN_H = 236, 36
	local RUN_ANCHOR = Vector2.new(0.5, 0)
	local runRest = UDim2.new(0.5, 0, 0, RUN_Y)
	local runAway = UDim2.new(0.5, 0, 0, -RUN_H - 20)
	local runPill = Kit.panel(screen, {
		Name = "RunPill",
		Size = UDim2.fromOffset(RUN_W, RUN_H),
		Position = runAway,
		AnchorPoint = Vector2.new(0.5, 0),
		Radius = RUN_H // 2,
		Visible = false,
	})
	local runStar =
		Kit.icon(runPill, "Star", 22, C.Gold, { Position = UDim2.new(0, 10, 0.5, 0), AnchorPoint = Vector2.new(0, 0.5), ZIndex = 3 })
	local runLevel = Kit.text(runPill, {
		Name = "Level",
		Text = "L1",
		Font = Theme.Fonts.Display,
		TextSize = 15,
		TextWrapped = false,
		Size = UDim2.fromOffset(34, 24),
		Position = UDim2.new(0, 6, 0.5, 0),
		AnchorPoint = Vector2.new(0, 0.5),
		BackgroundColor3 = C.Gold,
		BackgroundTransparency = 0,
		TextColor3 = C.GoldInk,
		StrokeThickness = 0,
		Visible = false,
		ZIndex = 3,
	})
	Kit.round(runLevel)
	local runClock = Kit.number(runPill, {
		Name = "Clock",
		Text = "0:00.0",
		TextSize = 20,
		TextXAlignment = Enum.TextXAlignment.Left,
		Size = UDim2.fromOffset(82, RUN_H),
		Position = UDim2.fromOffset(42, 0),
		ZIndex = 3,
	})
	local runCheck = Kit.text(runPill, {
		Name = "Checkpoint",
		Text = "0/0",
		Font = F.UI,
		TextSize = 14,
		TextWrapped = false,
		Size = UDim2.fromOffset(62, 24),
		Position = UDim2.new(0, 124, 0.5, 0),
		AnchorPoint = Vector2.new(0, 0.5),
		BackgroundColor3 = C.Well,
		BackgroundTransparency = 0,
		ZIndex = 3,
	})
	Kit.round(runCheck)
	local runCheckScale = Kit.new("UIScale", { Parent = runCheck })
	local quitArmed = false
	local quitButton: TextButton
	local function onQuit()
		if quitArmed then
			quitArmed = false
			action:FireServer({ action = "ModeQuit" })
			return
		end
		-- First tap arms it: the button widens to "QUIT?" for a few seconds.
		quitArmed = true
		Kit.setButton(quitButton, "QUIT?", C.Bad)
		Kit.tween(quitButton, 0.2, { Size = UDim2.fromOffset(64, 28) }, Enum.EasingStyle.Back)
		-- The pill widens with it so "QUIT?" never covers the checkpoint chip.
		Kit.tween(runPill, 0.2, { Size = UDim2.fromOffset(RUN_W + 36, RUN_H) }, Enum.EasingStyle.Back)
		task.delay(3, function()
			if quitArmed then
				quitArmed = false
				Kit.setButton(quitButton, "X", C.SurfaceHi)
				Kit.tween(quitButton, 0.2, { Size = UDim2.fromOffset(30, 28) })
				Kit.tween(runPill, 0.2, { Size = UDim2.fromOffset(RUN_W, RUN_H) })
			end
		end)
	end
	quitButton = Kit.button(runPill, {
		Name = "Quit",
		Text = "X",
		Color = C.SurfaceHi,
		TextSize = 14,
		Size = UDim2.fromOffset(30, 28),
		Position = UDim2.new(1, -4, 0.5, 0),
		AnchorPoint = Vector2.new(1, 0.5),
		Radius = 14,
		Depth = 2,
		ZIndex = 4,
	}, onQuit)
	hitPad(quitButton, onQuit)
	local runStartedAt = 0
	local runShown = false
	local runConn: RBXScriptConnection? = nil
	local lastClockText = ""
	Hud.runStart = function(startedAt: number, checkpoint: number, checkpoints: number, level: number?)
		runStartedAt = startedAt
		runStar.Visible = level == nil
		runLevel.Visible = level ~= nil
		if level then
			runLevel.Text = "L" .. tostring(level)
		end
		runCheck.Text = string.format("%d/%d", checkpoint, checkpoints)
		quitArmed = false
		Kit.setButton(quitButton, "X", C.SurfaceHi)
		quitButton.Size = UDim2.fromOffset(30, 28)
		runPill.Size = UDim2.fromOffset(RUN_W, RUN_H)
		runPill.AnchorPoint = RUN_ANCHOR
		screen:SetAttribute("RunActive", true)
		if not runShown then
			runShown = true
			runPill.Visible = true
			runPill.Position = runAway
			Kit.tween(runPill, 0.3, { Position = runRest }, Enum.EasingStyle.Back)
		end
		if not runConn then
			runConn = RunService.Heartbeat:Connect(function()
				local tenths = math.floor(math.max(Workspace:GetServerTimeNow() - runStartedAt, 0) * 10)
				local text = string.format("%d:%02d.%d", tenths // 600, (tenths // 10) % 60, tenths % 10)
				if text ~= lastClockText then
					lastClockText = text
					runClock.Text = text
				end
			end)
		end
	end
	Hud.runCheckpoint = function(index: number, checkpoints: number)
		runCheck.Text = string.format("%d/%d", index, checkpoints)
		runCheckScale.Scale = 1.35
		Kit.tween(runCheckScale, 0.3, { Scale = 1 }, Enum.EasingStyle.Back)
		Kit.tween(runCheck, 0.12, { BackgroundColor3 = C.Good })
		task.delay(0.35, function()
			Kit.tween(runCheck, 0.3, { BackgroundColor3 = C.Well })
		end)
	end
	Hud.runStop = function()
		if runConn then
			runConn:Disconnect()
			runConn = nil
		end
		quitArmed = false
		screen:SetAttribute("RunActive", false)
		if runShown then
			runShown = false
			Kit.tween(runPill, 0.25, { Position = runAway }, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
			task.delay(0.26, function()
				if not runShown then
					runPill.Visible = false
				end
			end)
		end
	end

	Hud.dockRun = function(pos: UDim2?, anchor: Vector2?)
		local rest = pos or UDim2.new(0.5, 0, 0, RUN_Y)
		RUN_ANCHOR = anchor or Vector2.new(0.5, 0)
		runRest = rest
		runAway = UDim2.new(rest.X.Scale, rest.X.Offset, 0, -RUN_H - 20)
		if runShown then
			runPill.AnchorPoint = RUN_ANCHOR
			Kit.tween(runPill, 0.25, { Position = runRest }, Enum.EasingStyle.Quad)
		end
	end

	-- Top centre: Chad icon + unit count ------------------------------------------------
	local units = group("Units", {
		Size = UDim2.fromOffset(300, 44),
		Position = UDim2.new(0.5, 0, 0, UNITS_Y),
		AnchorPoint = Vector2.new(0.5, 0),
	})
	local unitsRow = Kit.new("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal,
		HorizontalAlignment = Enum.HorizontalAlignment.Center,
		VerticalAlignment = Enum.VerticalAlignment.Center,
		Padding = UDim.new(0, 6),
		SortOrder = Enum.SortOrder.LayoutOrder,
		Parent = units,
	})
	local counter = Kit.hudIcon(units, "Chad", 42, C.Rizz, { Name = "Counter", LayoutOrder = 1, ZIndex = 2 })
	local counterLabel = Kit.hudText(units, {
		Name = "Count",
		Text = "0/100",
		Font = F.Number,
		TextSize = 34,
		StrokeThickness = 3,
		AutomaticSize = Enum.AutomaticSize.X,
		Size = UDim2.fromOffset(0, 40),
		LayoutOrder = 2,
		ZIndex = 3,
	})
	local counterCaption = Kit.hudText(units, {
		Name = "Full",
		Text = "RACK FULL",
		TextSize = 14,
		TextColor3 = C.Gold,
		AutomaticSize = Enum.AutomaticSize.X,
		Size = UDim2.fromOffset(0, 18),
		LayoutOrder = 3,
		Visible = false,
		ZIndex = 3,
	})
	unitsRow.Padding = UDim.new(0, 6)
	local unitCap = 100
	local function unitsText(n: number): string
		return string.format("%d/%d", n, unitCap)
	end
	local rackFull: boolean? = nil
	local function setRackFull(full: boolean)
		if full == rackFull then
			return
		end
		local first = rackFull == nil
		rackFull = full
		counterCaption.Visible = full
		local color = if full then C.Gold else Color3.new(1, 1, 1)
		if first then
			counterLabel.TextColor3 = color
		else
			Kit.tween(counterLabel, 0.3, { TextColor3 = color })
			if full then
				Kit.pop(counter, 0.6)
			end
		end
	end

	-- The strip under it: "Deposit bonus: x1.3 · 12s" ------------------------------------
	local strip = Kit.new("Frame", {
		Name = "DepositStrip",
		BackgroundColor3 = C.Ink,
		BackgroundTransparency = 0.45,
		BorderSizePixel = 0,
		Size = UDim2.fromOffset(340, STRIP_H),
		Position = UDim2.new(0.5, 0, 0, STRIP_Y),
		AnchorPoint = Vector2.new(0.5, 0),
		Parent = screen,
	})
	Kit.corner(strip, 8)
	local stripRow = Kit.new("Frame", {
		Name = "Row",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		Parent = strip,
	})
	Kit.new("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal,
		HorizontalAlignment = Enum.HorizontalAlignment.Center,
		VerticalAlignment = Enum.VerticalAlignment.Center,
		Padding = UDim.new(0, 6),
		SortOrder = Enum.SortOrder.LayoutOrder,
		Parent = stripRow,
	})
	local function stripText(name: string, order: number, size: number): TextLabel
		return Kit.hudText(stripRow, {
			Name = name,
			Text = "",
			TextSize = size,
			StrokeThickness = 2,
			AutomaticSize = Enum.AutomaticSize.X,
			Size = UDim2.fromOffset(0, STRIP_H),
			LayoutOrder = order,
			ZIndex = 3,
		})
	end
	local stripLead = stripText("Lead", 1, 20)
	stripLead.Text = "Deposit bonus:"
	local gaugeValue = stripText("Value", 2, 22)
	local gaugeNext = stripText("Next", 3, 15)
	gaugeNext.TextColor3 = Color3.fromRGB(225, 230, 250)
	local surgeActiveNow = false
	-- Big-roll cheer: pops out to the right of the strip for a moment.
	local niceLabel = Kit.hudText(strip, {
		Name = "Nice",
		Text = "NICE!",
		TextSize = 24,
		TextColor3 = C.Gold,
		Size = UDim2.fromOffset(96, 30),
		Position = UDim2.new(1, 8, 0.5, 0),
		AnchorPoint = Vector2.new(0, 0.5),
		TextXAlignment = Enum.TextXAlignment.Left,
		Rotation = 6,
		Visible = false,
		ZIndex = 5,
	})
	local function paintSurge(active: boolean)
		surgeActiveNow = active
		stripLead.Text = if active then "AURA SURGE" else "Deposit bonus:"
		Kit.tween(strip, 0.3, {
			BackgroundColor3 = if active then C.Amber else C.Ink,
			BackgroundTransparency = if active then 0.15 else 0.45,
		})
	end

	-- Bottom centre: the dumbbell with "AURA" and the carried amount ----------------------
	local Assets = (function(): any
		local shared = ReplicatedStorage:FindFirstChild("Shared")
		local module = shared and shared:FindFirstChild("Assets")
		if module and module:IsA("ModuleScript") then
			local ok, result = pcall(require, module)
			if ok and type(result) == "table" then
				return result
			end
		end
		return nil
	end)()
	local images = if Assets and type(Assets.Images) == "table" then Assets.Images else {}
	local plainId: string? = images["hud/Dumbbell"]
	local glowId: string? = images["hud/DumbbellGlow"]
	local tank = group("Dumbbell", {
		Size = UDim2.fromOffset(DUMBBELL_W, DUMBBELL_W * DUMBBELL_ASPECT),
		Position = UDim2.new(0.5, 0, 1, -6),
		AnchorPoint = Vector2.new(0.5, 1),
	})
	local tankScale = Kit.new("UIScale", { Parent = tank })
	local glowImage: ImageLabel? = nil
	-- Text rectangles in image pixels (art/out/ui/HudDumbbell.json, x y w h of 1024x448).
	local function rect(x: number, y: number, w: number, h: number): (UDim2, UDim2)
		return UDim2.fromScale(x / 1024, y / 448), UDim2.fromScale(w / 1024, h / 448)
	end
	local captionPos, captionSize = rect(310, 66, 404, 87)
	local numberPos, numberSize = rect(310, 156, 404, 160)
	if plainId then
		Kit.new("ImageLabel", {
			Name = "Art",
			BackgroundTransparency = 1,
			Image = plainId,
			ScaleType = Enum.ScaleType.Fit,
			Size = UDim2.fromScale(1, 1),
			ZIndex = 1,
			Parent = tank,
		})
		if glowId then
			glowImage = Kit.new("ImageLabel", {
				Name = "Glow",
				BackgroundTransparency = 1,
				Image = glowId,
				ImageTransparency = 1,
				ScaleType = Enum.ScaleType.Fit,
				Size = UDim2.fromScale(1, 1),
				ZIndex = 2,
				Parent = tank,
			})
		end
	else
		-- No art: a code-drawn pill in the plaque's place with the same two lines.
		captionPos, captionSize = UDim2.fromScale(0.25, 0.12), UDim2.fromScale(0.5, 0.22)
		numberPos, numberSize = UDim2.fromScale(0.25, 0.34), UDim2.fromScale(0.5, 0.42)
		local pill = Kit.new("Frame", {
			Name = "Plaque",
			BackgroundColor3 = C.Ink,
			BackgroundTransparency = 0.2,
			Size = UDim2.fromScale(0.56, 0.8),
			Position = UDim2.fromScale(0.22, 0.08),
			ZIndex = 1,
			Parent = tank,
		})
		Kit.corner(pill, 18)
	end
	local tankCaption = Kit.hudText(tank, {
		Name = "Caption",
		Text = string.upper(W.Orb),
		TextScaled = true,
		StrokeThickness = 2,
		TextColor3 = C.GoldLight,
		Size = captionSize,
		Position = captionPos,
		ZIndex = 4,
	})
	local carriedLabel = Kit.hudText(tank, {
		Name = "Carried",
		Text = "0",
		Font = F.Number,
		TextScaled = true,
		StrokeThickness = 2.5,
		Size = numberSize,
		Position = numberPos,
		ZIndex = 4,
	})
	tankCaption.TextSize = 20
	carriedLabel.TextSize = 36
	-- A bounce and a short cross-fade to the glow art; deposits bounce a little more.
	local glowToken = 0
	Hud.pulseTank = function(big: boolean?)
		tankScale.Scale = if big then 1.16 else 1.08
		Kit.tween(tankScale, if big then 0.45 else 0.3, { Scale = 1 }, Enum.EasingStyle.Back)
		local glow = glowImage
		if glow then
			glowToken += 1
			local token = glowToken
			Kit.tween(glow, 0.12, { ImageTransparency = 0 })
			task.delay(if big then 0.5 else 0.3, function()
				if token == glowToken then
					Kit.tween(glow, 0.35, { ImageTransparency = 1 })
				end
			end)
		end
	end

	-- Bottom left: status row, cash multiplier line, cash amount + plus -------------------
	local wallet = group("Wallet", {
		Size = UDim2.fromOffset(420, 168),
		Position = UDim2.new(0, EDGE_X, 1, -6),
		AnchorPoint = Vector2.new(0, 1),
	})
	local function status(name: string, icon: string, color: Color3, x: number): (Frame, TextLabel)
		local holder = group(name, { Size = UDim2.fromOffset(64, 56), Position = UDim2.fromOffset(x, 0), Parent = wallet })
		Kit.hudIcon(holder, icon, 36, color, {
			Name = "Icon",
			Position = UDim2.fromScale(0.5, 0),
			AnchorPoint = Vector2.new(0.5, 0),
			ZIndex = 2,
		})
		local caption = Kit.hudText(holder, {
			Name = "Caption",
			Text = "",
			Font = F.UI,
			TextSize = 14,
			StrokeThickness = 2,
			Size = UDim2.new(1, 12, 0, 16),
			Position = UDim2.new(0.5, 0, 0, 38),
			AnchorPoint = Vector2.new(0.5, 0),
			ZIndex = 3,
		})
		table.insert(captions, caption)
		return holder, caption
	end
	local premiumRow, premiumText = status("Premium", Kit.pickIcon("Crown", "Star"), C.Gold, 0)
	local friendsRow, friendsText = status("Friends", Kit.pickIcon("Invite", "Fans"), C.Rizz, 70)
	local boostRow, boostText = status("Boost", "Surge", C.Amber, 140)
	local multLine = Kit.hudText(wallet, {
		Name = "CashMult",
		Text = "",
		RichText = true,
		TextSize = 20,
		Size = UDim2.fromOffset(200, 22),
		Position = UDim2.fromOffset(0, 62),
		TextXAlignment = Enum.TextXAlignment.Left,
		ZIndex = 3,
	})
	local moneyLabel = Kit.hudText(wallet, {
		Name = "Money",
		Text = "$0",
		Font = F.Number,
		TextSize = 46,
		StrokeThickness = 3,
		TextColor3 = C.MoneyText,
		AutomaticSize = Enum.AutomaticSize.X,
		Size = UDim2.fromOffset(0, 50),
		Position = UDim2.fromOffset(0, 88),
		TextXAlignment = Enum.TextXAlignment.Left,
		ZIndex = 3,
	})
	local coin = moneyLabel -- coin bursts fly into the cash amount
	local addButton = Kit.button(wallet, {
		Name = "Add",
		Icon = "Plus",
		IconColor = Color3.new(1, 1, 1),
		Color = C.Cash,
		Size = UDim2.fromOffset(44, 44),
		Radius = 10,
		Depth = 3,
		ZIndex = 3,
	}, function()
		handlers.openWindow("Shop", { focus = "Cash" })
	end)
	hitPad(addButton, function()
		handlers.openWindow("Shop", { focus = "Cash" })
	end)
	-- The plus follows the cash amount's width.
	local function layoutWallet()
		local x = math.max(textWidth(moneyLabel.Text, moneyLabel.TextSize, moneyLabel.Font) + 4, 60)
		addButton.Position = UDim2.fromOffset(x + 10, 92)
	end
	moneyLabel:GetPropertyChangedSignal("Text"):Connect(layoutWallet)

	-- Layout mode ------------------------------------------------------------------------
	-- Compact screens: smaller grid icons, no status captions, no promo, a smaller
	-- dumbbell. Touch (live, Kit.onInput): the wallet moves to the top left with the
	-- grid under it (one row when compact) so the thumbstick's bottom-left third stays
	-- clear, the FREE gift rises above the jump button, the gear leaves the top bar,
	-- and every button is >= TAP_PX on screen. Gamepad / TV: title-safe edges. While a
	-- window is open the grid slides off the left edge, the bottom groups below the
	-- bottom edge and the top groups up, and all glide back.
	local gridIcon = GRID_ICON
	local oneRow = false
	local L = { edge = EDGE_X, bottom = -6, walletTop = false, walletY = 0, gridY = GRID_Y, tap = 0, tankX = 0, freeY = -20 }
	local function gridRows(): { { string } }
		if oneRow then
			return { { "Home", "Ranking", "Modes", "Index", "Shop", "Invite" } }
		end
		return GRID_ROWS
	end
	local function gridHeight(): number
		local rows = #gridRows()
		return rows * gridIcon + (rows - 1) * GRID_GAP_Y
	end
	-- Viewport (screen px) and the UI scale Main applied.
	local function view(): (Vector2, number)
		local scale = if screenScale then screenScale.Scale else 1
		local ok, size = pcall(function()
			return Workspace.CurrentCamera.ViewportSize
		end)
		if not ok or typeof(size) ~= "Vector2" or size.X <= 0 then
			size = Vector2.new(1280, 720)
		end
		return size, math.max(scale, 0.01)
	end
	local function measure()
		local size, scale = view()
		local touch = Kit.touch
		local pad = Kit.gamepad or Kit.tenFoot
		L.edge = if pad then SAFE_X else EDGE_X
		L.bottom = if pad then -SAFE_BOTTOM else -6
		L.tap = if touch then math.ceil(TAP_PX / scale) else 0
		L.walletTop = touch
		oneRow = touch and compact
		gridIcon = math.max(if compact then GRID_ICON_COMPACT else GRID_ICON, L.tap)
		-- Top-left wallet: compact screens drop the status row (its 62 px) there.
		local skip = if touch and compact then 62 else 0
		L.walletY = 168 - skip
		L.gridY = if touch then 138 - skip + 12 else GRID_Y
		-- Thumbstick zone: left third, lower half of the screen (design px below the top bar).
		local designW = size.X / scale
		local halfY = (size.Y / 2 - TOP_BAR_PX) / scale
		promoFits = not touch or L.gridY + gridHeight() + 26 + PROMO_H + 40 <= halfY
		local tankW = if compact then DUMBBELL_W_COMPACT else DUMBBELL_W
		L.tankX = if touch then math.max(0, designW / 3 + 8 - (designW - tankW) / 2) else 0
		-- Jump button: 70 px at 20 px from the corner on small screens, 120 px 90 px up otherwise.
		local jumpTop = if math.min(size.X, size.Y) <= 500 then 90 else 210
		L.freeY = if touch then -math.ceil((jumpTop + 8) / scale) elseif pad then -SAFE_BOTTOM else -20
	end

	local slots: { { gui: GuiObject, rest: () -> UDim2, away: () -> UDim2 } } = {}
	local function slot(gui: GuiObject, rest: () -> UDim2, away: () -> UDim2)
		table.insert(slots, { gui = gui, rest = rest, away = away })
	end
	slot(grid, function()
		return UDim2.fromOffset(L.edge, L.gridY)
	end, function()
		return UDim2.fromOffset(-600, L.gridY)
	end)
	slot(promo, function()
		return UDim2.fromOffset(L.edge, L.gridY + gridHeight() + 26)
	end, function()
		return UDim2.fromOffset(-260, L.gridY + gridHeight() + 26)
	end)
	slot(wallet, function()
		return if L.walletTop then UDim2.new(0, L.edge, 0, L.walletY) else UDim2.new(0, L.edge, 1, L.bottom)
	end, function()
		return if L.walletTop then UDim2.new(0, L.edge, 0, -60) else UDim2.new(0, L.edge, 1, 200)
	end)
	slot(tank, function()
		return UDim2.new(0.5, L.tankX, 1, L.bottom)
	end, function()
		return UDim2.new(0.5, L.tankX, 1, 160)
	end)
	slot(corner, function()
		return UDim2.new(1, -L.edge, 1, L.freeY)
	end, function()
		return UDim2.new(1, 120, 1, L.freeY)
	end)
	slot(units, function()
		return UDim2.new(0.5, 0, 0, UNITS_Y)
	end, function()
		return UDim2.new(0.5, 0, 0, -140)
	end)
	slot(strip, function()
		return UDim2.new(0.5, 0, 0, STRIP_Y)
	end, function()
		return UDim2.new(0.5, 0, 0, -140)
	end)
	local targets: { [GuiObject]: UDim2 } = {}
	local function place(animate: boolean)
		local away = screen:GetAttribute("WindowOpen") == true
		-- The crate panel (Popups, attribute "CratePanelOpen") covers the right edge
		-- down to the FREE gift, so the gift steps aside while it is up.
		local crate = screen:GetAttribute("CratePanelOpen") == true
		for _, s in slots do
			local pos = if away or (crate and s.gui == corner) then s.away() else s.rest()
			if targets[s.gui] ~= pos then
				targets[s.gui] = pos
				if animate then
					Kit.tween(s.gui, 0.3, { Position = pos }, Enum.EasingStyle.Quad)
				else
					s.gui.Position = pos
				end
			end
		end
	end
	local function applyCompact()
		compact = screen:GetAttribute("Compact") == true
		measure()
		local step = gridIcon + GRID_GAP_X
		local columns = 0
		for row, names in gridRows() do
			columns = math.max(columns, #names)
			for column, name in names do
				local button = Hud.buttons[name]
				button.Size = UDim2.fromOffset(gridIcon, gridIcon)
				button.Position = UDim2.fromOffset((column - 1) * step, (row - 1) * (gridIcon + GRID_GAP_Y))
			end
		end
		grid.Size = UDim2.fromOffset(columns * step - GRID_GAP_X, gridHeight())
		for _, caption in captions do
			caption.TextSize = if compact then 15 else 18
		end
		-- Status captions go first on short screens; the icons stay (not on a touch
		-- phone, where the wallet sits in the top-left corner).
		for _, label in { premiumText, friendsText, boostText } do
			label.Visible = not compact
		end
		for _, row in { premiumRow, friendsRow, boostRow } do
			row.Visible = not (Kit.touch and compact)
		end
		local width = if compact then DUMBBELL_W_COMPACT else DUMBBELL_W
		tank.Size = UDim2.fromOffset(width, width * DUMBBELL_ASPECT)
		-- Gear: on the top bar's line with a mouse; below it (never on Roblox's bar) otherwise.
		local gearSize = math.max(GEAR, L.tap)
		gear.Size = UDim2.fromOffset(gearSize, gearSize)
		gear.Position = if Kit.input == "keyboard" and not Kit.tenFoot then UDim2.new(1, -10, 0, -GEAR - 7) else UDim2.new(1, -L.edge, 0, 4)
		-- FREE gift grows to a full touch target; the countdown follows it.
		local freeSize = math.max(60, L.tap)
		freeButton.Size = UDim2.fromOffset(freeSize, freeSize)
		corner.Size = UDim2.fromOffset(math.max(84, freeSize + 16), freeSize + 32)
		freeTimer.Position = UDim2.new(0.5, 0, 0, freeSize + 2)
		for _, p in pads do
			local w, h = p.button.Size.X.Offset, p.button.Size.Y.Offset
			p.pad.Size = UDim2.fromOffset(math.max(w, L.tap), math.max(h, L.tap))
			p.pad.Visible = Kit.touch and (w < L.tap or h < L.tap)
		end
		updatePromo()
		place(next(targets) ~= nil)
	end
	-- Gamepad: HUD buttons leave the D-pad's reach while a window or dialog is up.
	local selectables: { GuiObject } = { promoButton, addButton, quitButton }
	for _, button in Hud.buttons do
		table.insert(selectables, button)
	end
	local function updateSelectable()
		local blocked = screen:GetAttribute("WindowOpen") == true or screen:GetAttribute("ModalOpen") == true
		for _, button in selectables do
			Kit.selectable(button, not blocked)
		end
	end
	screen:GetAttributeChangedSignal("WindowOpen"):Connect(function()
		place(true)
		updatePromo()
		updateSelectable()
	end)
	screen:GetAttributeChangedSignal("ModalOpen"):Connect(updateSelectable)
	screen:GetAttributeChangedSignal("CardioActive"):Connect(updatePromo)
	screen:GetAttributeChangedSignal("CratePanelOpen"):Connect(function()
		place(true)
	end)
	State.changed.Event:Connect(updatePromo)
	-- Compact, narrow or touch screens: Roblox's player list would cover the top-right
	-- corner (the gear on touch) and the unit counter, so it stays hidden there.
	local function updatePlayerList()
		local size = designSize()
		local narrow = size.X > 0 and size.X * (if screenScale then screenScale.Scale else 1) < NARROW_PX
		Kit.hidePlayerList("smallscreen", screen:GetAttribute("Compact") == true or narrow or Kit.touch)
	end
	local function relayout()
		applyCompact()
		updatePlayerList()
	end
	screen:GetAttributeChangedSignal("Compact"):Connect(relayout)
	pcall(function()
		screen:GetPropertyChangedSignal("AbsoluteSize"):Connect(updatePlayerList)
	end)
	if screenScale then
		screenScale:GetPropertyChangedSignal("Scale"):Connect(relayout)
	end
	Kit.onInput(relayout)
	updateSelectable()

	-- Updates ------------------------------------------------------------------------------
	local moneyShown: number? = nil
	local moneyRollEnd = 0
	local lastMult: number? = nil
	local lastCarried: number? = nil
	local premiumOn: boolean? = nil
	local function refresh()
		local data = State.data
		if not data then
			return
		end
		-- Cash rolls up (longer for bigger gains) and quickly down when spent.
		if moneyShown ~= nil and data.money ~= moneyShown then
			local gain = data.money - (moneyShown :: number)
			local time = if gain > 0 then math.clamp(0.4 + 0.08 * math.log10(math.max(gain, 1)), 0.45, 0.9) else 0.25
			moneyRollEnd = os.clock() + time
			roll(moneyLabel, data.money, State.money, time)
		else
			roll(moneyLabel, data.money, State.money)
		end
		moneyShown = data.money
		if lastMult ~= nil and lastMult ~= data.moneyMult then
			Kit.pop(multLine, 0.8)
		end
		lastMult = data.moneyMult
		multLine.Text = string.format('Cash <font color="#%s">[ x%.1f ]</font>', C.Gold:ToHex(), data.moneyMult)
		local owned = 0
		if type(data.unitTotal) == "number" then
			owned = data.unitTotal
		elseif type(data.units) == "table" then
			for _, count in data.units do
				if type(count) == "number" then
					owned += count
				end
			end
		end
		unitCap = if type(data.unitCap) == "number" then data.unitCap else unitCap
		roll(counterLabel, owned, unitsText)
		setRackFull(owned >= unitCap)
		roll(carriedLabel, data.carried, State.num, 0.3)
		-- Carried aura dropping to nothing is a deposit: the bigger bounce.
		if lastCarried ~= nil and lastCarried > 0 and data.carried <= 0 then
			Hud.pulseTank(true)
		end
		lastCarried = data.carried

		local premium = data.premium == true
		premiumText.Text = if premium then string.format("Active +%d%%", PREMIUM_BONUS) else "Inactive"
		premiumText.TextColor3 = if premium then C.Gold else Color3.new(1, 1, 1)
		if premiumOn ~= nil and premium ~= premiumOn then
			Kit.pop(premiumRow, 0.6)
		end
		premiumOn = premium
		friendsText.Text = string.format("+%d%%", math.floor((data.friendBonus or 0) * 100 + 0.5))

		if seenDiscoveries == nil then
			seenDiscoveries = discoveredCount(data)
		end
		refreshIndexBadge()
		layoutWallet()
	end
	State.changed.Event:Connect(refresh)

	-- Coin burst to the wallet ------------------------------------------------------------
	-- Its own ScreenGui with no insets/scale so world->viewport points map 1:1.
	local fxGui = Instance.new("ScreenGui")
	fxGui.Name = "HudFx"
	fxGui.ResetOnSpawn = false
	fxGui.IgnoreGuiInset = true
	fxGui.DisplayOrder = 5
	fxGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	pcall(function()
		fxGui.ScreenInsets = Enum.ScreenInsets.None
	end)
	fxGui.Parent = screen.Parent
	local fxLayer = Kit.new("Frame", {
		Name = "Layer",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		Parent = fxGui,
	})
	local uiScale = screen:FindFirstChildOfClass("UIScale")
	local coinPitch = 1
	local lastCoinAt = 0

	local function makeCoin(size: number): Frame
		return Kit.icon(fxLayer, "Coin", size, C.Gold, { Name = "Coin", AnchorPoint = Vector2.new(0.5, 0.5) })
	end

	Hud.coinBurst = function(amount: number, padPos: Vector3?, fromGui: GuiObject?)
		local layerAt = fxLayer.AbsolutePosition
		local viewport = Workspace.CurrentCamera and Workspace.CurrentCamera.ViewportSize or Vector2.new(1280, 720)
		local origin = Vector2.new(viewport.X * 0.5, viewport.Y * 0.5)
		local camera = Workspace.CurrentCamera
		if fromGui then
			origin = fromGui.AbsolutePosition + fromGui.AbsoluteSize * 0.5 - layerAt
		elseif padPos and camera then
			local point, onScreen = camera:WorldToViewportPoint(padPos)
			if onScreen and point.Z > 0 then
				origin = Vector2.new(point.X, point.Y)
			end
		end
		local target = coin.AbsolutePosition + coin.AbsoluteSize * 0.5 - layerAt
		local scale = if uiScale then uiScale.Scale else 1
		local magnitude = math.log10(math.max(amount, 1))
		local count = math.clamp(8 + math.floor(magnitude * 1.2), 8, 16)
		local size = math.floor(30 * scale)
		if os.clock() - lastCoinAt > 1 then
			coinPitch = 1
		end
		for i = 1, count do
			local c = makeCoin(size)
			c.Position = UDim2.fromOffset(origin.X, origin.Y)
			c.Size = UDim2.fromOffset(size * 0.4, size * 0.4)
			local angle = math.random() * math.pi * 2
			local radius = (40 + math.random() * 90) * scale
			local spread = origin + Vector2.new(math.cos(angle), math.sin(angle) * 0.7 - 0.4) * radius
			Kit.tween(
				c,
				0.3,
				{ Position = UDim2.fromOffset(spread.X, spread.Y), Size = UDim2.fromOffset(size, size) },
				Enum.EasingStyle.Back
			)
			task.delay(0.3 + i * 0.045, function()
				local fly = 0.42 + math.random() * 0.08
				Kit.tween(c, fly, {
					Position = UDim2.fromOffset(target.X, target.Y),
					Size = UDim2.fromOffset(size * 0.6, size * 0.6),
				}, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
				task.delay(fly, function()
					c:Destroy()
					lastCoinAt = os.clock()
					sounds.play("Coin", 0.04, coinPitch)
					coinPitch = math.min(coinPitch + 0.035, 1.5)
					Kit.pop(moneyLabel, 0.4)
				end)
			end)
		end
	end

	-- Aura pack: a handful of orbs pop out at the screen centre and fly into the tank, each
	-- landing with the walk-over pickup pop at a rising pitch; the tank number rolls up from
	-- the State refresh that follows the grant.
	Hud.orbBurst = function(amount: number)
		local layerAt = fxLayer.AbsolutePosition
		local viewport = Workspace.CurrentCamera and Workspace.CurrentCamera.ViewportSize or Vector2.new(1280, 720)
		local origin = Vector2.new(viewport.X * 0.5, viewport.Y * 0.5)
		local target = carriedLabel.AbsolutePosition + carriedLabel.AbsoluteSize * 0.5 - layerAt
		local scale = if uiScale then uiScale.Scale else 1
		local count = math.clamp(6 + math.floor(math.log10(math.max(amount, 1))), 6, 12)
		local size = math.floor(34 * scale)
		for i = 1, count do
			local orb = Kit.icon(fxLayer, "Orb", size, C.Orb, { Name = "Orb", AnchorPoint = Vector2.new(0.5, 0.5) })
			orb.Position = UDim2.fromOffset(origin.X, origin.Y)
			orb.Size = UDim2.fromOffset(size * 0.4, size * 0.4)
			local angle = (i / count + math.random() * 0.1) * math.pi * 2
			local radius = (50 + math.random() * 70) * scale
			local spread = origin + Vector2.new(math.cos(angle), math.sin(angle) * 0.7) * radius
			Kit.tween(
				orb,
				0.3,
				{ Position = UDim2.fromOffset(spread.X, spread.Y), Size = UDim2.fromOffset(size, size) },
				Enum.EasingStyle.Back
			)
			task.delay(0.3 + i * 0.06, function()
				local fly = 0.45 + math.random() * 0.1
				Kit.tween(orb, fly, {
					Position = UDim2.fromOffset(target.X, target.Y),
					Size = UDim2.fromOffset(size * 0.5, size * 0.5),
				}, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
				task.delay(fly, function()
					orb:Destroy()
					sounds.play("OrbPickup", 0, math.min(1 + i * 0.05, 1.6))
					Hud.pulseTank(i == count)
				end)
			end)
		end
	end

	local shaking = false
	Hud.shakeWallet = function()
		if shaking then
			return
		end
		shaking = true
		local home = moneyLabel.Position
		moneyLabel.TextColor3 = C.Danger
		Kit.pop(moneyLabel, 0.4)
		task.spawn(function()
			for _, dx in { 9, -8, 6, -4, 2, 0 } do
				Kit.tween(moneyLabel, 0.045, { Position = home + UDim2.fromOffset(dx, 0) }, Enum.EasingStyle.Sine)
				task.wait(0.045)
			end
			moneyLabel.Position = home
			Kit.tween(moneyLabel, 0.35, { TextColor3 = C.MoneyText })
			shaking = false
		end)
	end
	Hud.walletIdle = function(): boolean
		return os.clock() >= moneyRollEnd
	end

	-- Deposit multiplier re-roll: the value flickers like a slot machine ------------------
	local spinning = false
	local function multColor(mult: number): Color3
		return if mult >= 1.2 then C.MoneyText elseif mult < 1 then C.Danger else C.Gold
	end
	local depositMult = ReplicatedStorage:GetAttribute("DepositMult") or 1
	local function showMult(mult: number)
		if surgeActiveNow then
			gaugeValue.Text = "x" .. Economy.SURGE_MULTIPLIER
			gaugeValue.TextColor3 = Color3.new(1, 1, 1)
		else
			gaugeValue.Text = string.format("x%.1f", mult)
			gaugeValue.TextColor3 = multColor(mult)
		end
	end
	showMult(depositMult)
	ReplicatedStorage:GetAttributeChangedSignal("DepositMult"):Connect(function()
		depositMult = ReplicatedStorage:GetAttribute("DepositMult") or 1
		if spinning or surgeActiveNow then
			showMult(depositMult)
			return
		end
		spinning = true
		task.spawn(function()
			local elapsed = 0
			local step = 0.035
			-- Silent visual roll: the value flickers, then lands with a pop.
			while elapsed < 0.6 do
				showMult(Economy.DEPOSIT_MIN + math.random() * (Economy.DEPOSIT_MAX - Economy.DEPOSIT_MIN))
				task.wait(step)
				elapsed += step
				step *= 1.22
			end
			depositMult = ReplicatedStorage:GetAttribute("DepositMult") or depositMult
			showMult(depositMult)
			Kit.pop(gaugeValue, 1)
			Kit.pop(strip, 0.4)
			if depositMult >= 1.5 then
				niceLabel.Text = if depositMult >= 2 then "HUGE!" else "NICE!"
				Kit.appear(niceLabel, { from = 0.3, time = 0.3 })
				task.delay(1.4, function()
					Kit.disappear(niceLabel, { to = 1.1, time = 0.25 })
				end)
			end
			spinning = false
		end)
	end)

	-- Aura Surge: the strip and boost icon change; the screen grade and music are Fx.Surge's.
	local surgeActive: boolean? = nil
	local lastSurgeSecond = -1

	local function setSurge(active: boolean, announce: boolean)
		paintSurge(active)
		showMult(depositMult)
		boostText.Text = if active then "200%" else "100%"
		boostText.TextColor3 = if active then C.Amber else Color3.new(1, 1, 1)
		if announce then
			Kit.pop(strip, if active then 0.8 else 0.4)
			if active then
				Kit.pop(boostRow, 0.8)
			end
		end
	end

	-- Free gift: countdown under it; sunny "CLAIM!" with a gentle bounce when ready.
	local freeText = ""
	local freeReady: boolean? = nil
	local stopFreeBounce: (() -> ())? = nil
	local function paintFree(text: string, ready: boolean)
		if ready ~= freeReady then
			freeReady = ready
			Kit.setBadge(freeButton, if ready then "!" else nil)
			freeTimer.TextColor3 = if ready then C.Gold else Color3.new(1, 1, 1)
			if ready then
				Kit.pop(freeButton, 0.8)
				stopFreeBounce = Kit.breathe(freeButton, 0.06)
			elseif stopFreeBounce then
				stopFreeBounce()
				stopFreeBounce = nil
			end
		end
		freeTimer.Text = text
	end
	local nextText = ""
	RunService.Heartbeat:Connect(function()
		local now = Workspace:GetServerTimeNow()
		local active, left = Economy.surgeState(now)
		if active ~= surgeActive then
			-- Announce only real transitions, not the state found on join.
			setSurge(active, surgeActive ~= nil)
			surgeActive = active
		end
		local text
		if active then
			-- Countdown pop in the last 10 seconds.
			local second = math.ceil(left)
			if left <= 10 and second ~= lastSurgeSecond then
				lastSurgeSecond = second
				Kit.pop(gaugeNext, 0.8)
			end
			text = "· " .. Format.time(left)
		else
			local nextAt = ReplicatedStorage:GetAttribute("DepositNextAt") or now
			text = string.format("· %ds", math.max(0, math.ceil(nextAt - now)))
		end
		if text ~= nextText then
			nextText = text
			gaugeNext.Text = text
		end
		local data = State.data
		if data then
			local freeLeft = math.max(0, (data.freeIn or 0) - State.age())
			local ready = freeLeft <= 0
			local label = if ready then "CLAIM!" else Format.time(freeLeft)
			if label ~= freeText then
				freeText = label
				paintFree(label, ready)
			end
		end
	end)
	refresh()
	layoutWallet()

	-- Obby mode: the run's own HUD owns the top centre ----------------------------------
	Hud.tank = tank
	local obbyOn = false
	local tutorialConn: RBXScriptConnection? = nil
	local tutorialWanted = false
	local forcing = false
	Hud.setObbyMode = function(on: boolean)
		if on == obbyOn then
			return
		end
		obbyOn = on
		screen:SetAttribute("ObbyMode", on)
		for _, gui in { units, strip, corner } :: { GuiObject } do
			gui.Visible = not on
		end
		updatePromo()
		-- The quest pill (Tutorial) stays down even if it re-renders mid-run; whatever
		-- it asked for meanwhile is applied when the run ends.
		local pill = screen:FindFirstChild("TutorialPill")
		if not (pill and pill:IsA("GuiObject")) then
			return
		end
		if on then
			tutorialWanted = pill.Visible
			pill.Visible = false
			tutorialConn = pill:GetPropertyChangedSignal("Visible"):Connect(function()
				if forcing then
					return
				end
				tutorialWanted = pill.Visible
				if pill.Visible then
					forcing = true
					pill.Visible = false
					forcing = false
				end
			end)
		else
			if tutorialConn then
				tutorialConn:Disconnect()
				tutorialConn = nil
			end
			pill.Visible = tutorialWanted
		end
	end

	-- Entrance: the HUD eases in a block at a time, top first.
	local entrance: { GuiObject } = { units, strip, gear }
	for _, row in GRID_ROWS do
		for _, name in row do
			table.insert(entrance, Hud.buttons[name])
		end
	end
	table.insert(entrance, wallet)
	table.insert(entrance, tank)
	table.insert(entrance, corner)
	Kit.stagger(entrance, 0.03)
end

return Hud
