--[[
	Hud: always-on screen elements (design space 1280x720, below the top bar).
	Laid out like the owner's reference game: chunky icons and bold white
	Ink-outlined text straight over the world; only the menu buttons sit on plates.

	  top bar right  Settings gear alone (Roblox's player list sits under it)
	  top centre     three rows at most, 6 px apart: Chad icon + unit count "37/100"
	                 (sunny + "AUTO-MERGING" at 100/100), a low glass strip
	                 "Deposit bonus: x1.3 · 12s" (never red; "AURA SURGE x2 · 1:23"
	                 in orange during a surge) and, once the tutorial is done, the
	                 "Next:" goal strip ("Next: Protein Bro 1/2" over "merge 2x Gym
	                 Rookie", Shared.NextGoal; above the dumbbell on compact
	                 screens). The tutorial quest pill and the parkour run pill use
	                 the third row before that.
	  left edge      menu grid: Home Ranking Modes / Index Shop Invite Daily, each an
	                 icon and its caption on its own dark glass plate, all the same
	                 size (Daily: a dot while a reward waits, else its countdown)
	                 promo under it, only below tier 15 and until it is opened once:
	                 a green-tinted glass card, STARTER PACK (then 2X CASH under a
	                 tilted "PERMANENT" tag) with a solid price chip
	  bottom left    bonus chips, each on screen only while it is on ("Premium
	                 +10%", "Friends +20%", "SURGE x2"), "Cash [ x1.0 ]", the big
	                 cash amount + square "+"
	  bottom centre  the dumbbell: "AURA" + the carried amount on its plaque
	  bottom right   FREE gift with its countdown, version in the corner

	Numbers roll, things pop and the HUD staggers in when it is built. While a
	window, modal or reveal is open (Kit.onWindowOpen, the one count behind the
	"WindowOpen" attribute) every group fades out in 0.15 s, parks off its edge
	so it takes no input or gamepad selection, and fades back on close. Toasts
	and the tutorial pill are not the HUD's: they stay.
	Short screens (attribute "Compact") get smaller grid icons, drop the promo
	and hide Roblox's player list.

	Input (Kit.onInput, re-placed live): on touch the wallet moves to the top
	left with the grid under it (one row on phones, the bonus chips beside the
	"Cash" line on tablets and gone on phones) so nothing sits on Roblox's
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
local NextGoal = require(ReplicatedStorage.Shared.NextGoal)

local Kit = require(script.Parent.Kit)
local State = require(script.Parent.Parent.State)

local Theme = Kit.Theme
local C = Kit.C
local G = Theme.Glass
local F = Kit.F
local W = Theme.Words

local Hud = {}

export type Handlers = {
	openWindow: (string, { focus: string?, origin: GuiObject? }?) -> (),
	guide: ((string?) -> ())?,
	toast: ((string, string?) -> ())?,
}

-- Buttons by name (Shop, Index, Ranking, Free, Home, Invite, Daily, Settings, Modes) so
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
-- Where a discovery flies to (Popups): the centre of the Index button at rest, in screen
-- pixels. nil while it is no landing spot (a window keeps the HUD away, the menu is hidden
-- or off screen).
Hud.indexPoint = function(): Vector2?
	return nil
end
-- A discovery landed on the Index button: it bounces, flashes and counts "+1".
Hud.punchIndex = function() end

-- Layout (design px). The top centre group sits just under the top bar.
local EDGE_X = 14
local UNITS_Y = 4 -- unit counter row: y 4..48
local STRIP_Y = 54 -- deposit strip: y 54..80 (slim and quiet: notifications outrank it)
local STRIP_H = 26
local RUN_Y = 92 -- tutorial / run pill slot (Tutorial.luau TOP_Y matches)
local STACK_GAP = 6 -- between the rows of the top stack (count, strip, goal)
local GOAL_H = 42 -- "Next:" goal strip (the third row once the tutorial is done)
local HIDE_TIME = 0.15 -- the HUD's fade while a window is open
local GOAL_MAX_W = 380
local GOAL_TEXT_X = 50
local GOAL_BAR_X = 12 -- the progress bar's inset, clear of the strip's round corners
local GRID_Y = 104 -- left menu grid, first row
local GRID_ICON = 56 -- the icon on a menu plate
local GRID_ICON_COMPACT = 44
local GRID_GAP = 6 -- between two plates
local GRID_PAD = 6 -- a plate's edge to its icon and caption
local CAPTION = 14 -- plate captions; never under Kit.captionPx on the glass
local PROMO_GAP = 4 -- the grid to the promo (whose tag overhangs its card by 12 more)
local PROMO_MAX_TIER = 15 -- from this best tier on the HUD stops advertising (the Shop keeps the offers)
local CHIP_H = 26 -- wallet bonus chips: icon + words
local CHIP_ICON = 24
local CHIP_TEXT = 16
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
	-- Text under the screen's UIScale is drawn at a whole pixel size, so on a small screen it
	-- runs a little wider than its design width: measured as drawn.
	local function drawnWidth(text: string, size: number, font: Enum.Font): number
		local scale = if screenScale then screenScale.Scale else 1
		local width = textWidth(text, size, font)
		if scale < 1 then
			width = math.max(width, math.ceil(textWidth(text, math.ceil(size * scale), font) / scale))
		end
		return width
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
	-- A HUD button's feel: the hover lift (mouse or gamepad selection), the press squash
	-- and the click.
	local function wire(button: TextButton, onClick: () -> ()): TextButton
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
	-- A panel-less tap target: the button itself is the icon square (badges and glow
	-- rings sit on it).
	local function bareButton(parent: Instance, name: string, size: number, onClick: () -> ()): TextButton
		return wire(
			Kit.new("TextButton", {
				Name = name,
				Text = "",
				AutoButtonColor = false,
				BackgroundTransparency = 1,
				Size = UDim2.fromOffset(size, size),
				Parent = parent,
			}),
			onClick
		)
	end

	-- Top bar, far right: the Settings gear alone ----------------------------------------
	-- It sits on the top bar's line (above our safe area) so Roblox's player list,
	-- which starts under the top bar, never covers it.
	local gear: TextButton
	gear = bareButton(screen, "Settings", GEAR, function()
		handlers.openWindow("Settings", { origin = gear })
	end)
	gear.AnchorPoint = Vector2.new(1, 0)
	gear.Position = UDim2.new(1, -10, 0, -GEAR - 7)
	Kit.hudIcon(gear, "Settings", GEAR, C.Text, { Name = "Icon", ZIndex = 2 }).Size = UDim2.fromScale(1, 1)
	Hud.buttons.Settings = gear

	-- Left edge: menu grid, a plate per button --------------------------------------------
	-- Each button is its own dark glass plate (Kit.hudGlass, 70% opaque: world signs behind
	-- the menu do not read through it) holding the icon and, inside it, the caption. The
	-- plates share one size, set by the widest caption as drawn (applyCompact), so two
	-- captions can never meet.
	local GRID_ROWS = { { "Home", "Ranking", "Modes" }, { "Index", "Shop", "Invite", "Daily" } }
	local CAPTIONS: { [string]: string } = {
		Home = "Home",
		Ranking = "Ranking",
		Modes = "Modes",
		Index = "Index",
		Shop = "Shop",
		Invite = "Invite",
		Daily = "Daily",
	}
	-- Modes draws the rendered finish-flag image; Star stands in if it is missing. Daily
	-- is the second gift of the atlas (the FREE gift keeps the first).
	local ICON_FOR: { [string]: string } = { Modes = Kit.pickIcon("Modes", "Star"), Daily = Kit.pickIcon("Gift2", "Free") }
	local grid = group("Menu", { Position = UDim2.fromOffset(EDGE_X, GRID_Y) })
	local captions: { TextLabel } = {}
	local gridIcons: { [string]: Frame } = {}
	local function gridButton(name: string, onClick: () -> ()): TextButton
		local button = Kit.hudGlass(grid, {
			Name = name,
			Button = true,
			Shadow = false,
			Size = UDim2.fromOffset(GRID_ICON + GRID_PAD * 2, GRID_ICON + CAPTION + GRID_PAD * 2),
			Radius = Kit.RADIUS.M,
		}) :: TextButton
		wire(button, onClick)
		gridIcons[name] = Kit.hudIcon(button, ICON_FOR[name] or name, GRID_ICON, C.Text, {
			Name = "Icon",
			Position = UDim2.new(0.5, 0, 0, GRID_PAD),
			AnchorPoint = Vector2.new(0.5, 0),
			ZIndex = 2,
		})
		local caption = Kit.hudText(button, {
			Name = "Caption",
			Text = CAPTIONS[name],
			TextSize = CAPTION,
			MinPx = true,
			StrokeThickness = 2,
			Size = UDim2.new(1, 0, 0, CAPTION + 4),
			Position = UDim2.new(0.5, 0, 1, -3),
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
		handlers.openWindow("Ranking", { origin = Hud.buttons.Ranking })
	end)
	gridButton("Modes", function()
		Kit.setGlow(Hud.buttons.Modes, false)
		handlers.openWindow("Modes", { origin = Hud.buttons.Modes })
	end)
	local function openIndex()
		Kit.setGlow(Hud.buttons.Index, false)
		local data = State.data
		if data then
			seenDiscoveries = discoveredCount(data)
			refreshIndexBadge()
		end
		handlers.openWindow("Index", { origin = Hud.buttons.Index })
	end
	gridButton("Index", openIndex)
	gridButton("Shop", function()
		handlers.openWindow("Shop", { origin = Hud.buttons.Shop })
	end)
	gridButton("Invite", function()
		pcall(function()
			SocialService:PromptGameInvite(Players.LocalPlayer)
		end)
	end)
	local dailyButton = gridButton("Daily", function()
		handlers.openWindow("Daily", { origin = Hud.buttons.Daily })
	end)
	local dailyCaption = dailyButton:FindFirstChild("Caption") :: TextLabel
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
	-- Starter pack until it is owned, then 2X CASH until that is owned, then nothing. A tag
	-- only says what is true: the Starter Pack has no deadline, so it wears none.
	local PROMOS: { [string]: { tag: string?, text: string, price: number, focus: string } } = {
		Starter = { text = "STARTER PACK", price = 59, focus = Theme.Cosmetics.Starter.Pass },
		DoubleMoney = { tag = "PERMANENT", text = "2X CASH", price = 199, focus = "DoubleMoney" },
	}
	-- A glass card in the HUD's language: the window tint with the money green mixed in,
	-- a green edge and a soft pulsing green glow; the offer's name is outlined HUD text and
	-- only the price sits on a small solid chip.
	local PROMO_W, PROMO_H = 286, 50
	local PROMO_CHIP_W = 70
	local promo = group("Promo", { Size = UDim2.fromOffset(PROMO_W, PROMO_H + 16), Visible = false })
	local promoMode = "DoubleMoney"
	-- Opened once: the offer has been seen, so it stays away until the next visit.
	local promoOpened = false
	local promoButton = Kit.hudGlass(promo, {
		Name = "Button",
		Button = true,
		Color = G.TintTop:Lerp(C.CashDeep, 0.4),
		Transparency = G.Tinted,
		Edge = C.Cash,
		Size = UDim2.fromOffset(PROMO_W, PROMO_H),
		Position = UDim2.fromOffset(0, 12),
		Radius = Kit.RADIUS.M,
	}) :: TextButton
	Kit.setGlow(promoButton, true, C.Cash)
	Kit.selectable(promoButton)
	Kit.bouncy(promoButton, 1.04)
	promoButton.Activated:Connect(function()
		Kit.sound("Click")
		promoOpened = true
		handlers.openWindow("Shop", { focus = PROMOS[promoMode].focus, origin = promoButton })
	end)
	local promoLabel = Kit.hudText(promoButton, {
		Name = "Label",
		Text = "2X CASH",
		MaxTextSize = 22,
		MinPx = true,
		Size = UDim2.new(1, -(PROMO_CHIP_W + 30), 1, -14),
		Position = UDim2.new(0, 14, 0.5, 0),
		AnchorPoint = Vector2.new(0, 0.5),
		TextXAlignment = Enum.TextXAlignment.Left,
		StrokeColor = G.TextInk,
		ZIndex = 3,
	})
	local promoTag = Kit.hudText(promo, {
		Name = "Tag",
		Text = "PERMANENT",
		TextSize = 15,
		MinPx = true,
		TextColor3 = C.Gold,
		Size = UDim2.fromOffset(110, 18),
		Position = UDim2.fromOffset(-4, 2),
		Rotation = -8,
		ZIndex = 8,
	})
	local promoPrice = Kit.pill(promoButton, {
		Name = "Price",
		Text = "199 " .. Kit.ROBUX,
		Color = C.Cash,
		Solid = true,
		TextSize = 16,
		MinPx = true,
		Size = UDim2.fromOffset(PROMO_CHIP_W, 30),
		Position = UDim2.new(1, -10, 0.5, 0),
		AnchorPoint = Vector2.new(1, 0.5),
		ZIndex = 3,
	})
	local function dressPromo(mode: string)
		promoMode = mode
		local look = PROMOS[mode]
		promoLabel.Text = look.text
		promoTag.Text = look.tag or ""
		promoTag.Visible = look.tag ~= nil
		promoPrice.Text = string.format("%d %s", look.price, Kit.ROBUX)
	end
	local promoShown = false
	-- An ad for a new player, not a fixture: gone from PROMO_MAX_TIER on and once it has
	-- been opened this visit. The Shop keeps both offers.
	local function wantedPromo(): string?
		local data = State.data
		if not data or promoOpened then
			return nil
		end
		if type(data.discovered) == "table" then
			for tier = PROMO_MAX_TIER, Economy.MAX_TIER do
				if (data.discovered[tier] or 0) > 0 then
					return nil
				end
			end
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
		else
			Kit.disappear(promo, { to = 0.85, time = 0.18 })
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
	-- Glass like the other top-centre notifications (Kit.hudGlass), with an outlined clock.
	local RUN_W, RUN_H = 236, 36
	local RUN_ANCHOR = Vector2.new(0.5, 0)
	local runRest = UDim2.new(0.5, 0, 0, RUN_Y)
	local runAway = UDim2.new(0.5, 0, 0, -RUN_H - 20)
	local runPill = Kit.hudGlass(screen, {
		Name = "RunPill",
		Size = UDim2.fromOffset(RUN_W, RUN_H),
		Position = runAway,
		AnchorPoint = Vector2.new(0.5, 0),
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
	local runClock = Kit.hudText(runPill, {
		Name = "Clock",
		Text = "0:00.0",
		Font = F.Number,
		TextSize = 20,
		StrokeThickness = 2,
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
		-- Modes without checkpoints (the obby, since maps have none) hide the n/N chip.
		runCheck.Visible = checkpoints > 0
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
	-- A full rack is not a stop: buying goes on and the extra Chads merge on their own.
	local counterCaption = Kit.hudText(units, {
		Name = "Full",
		Text = "AUTO-MERGING",
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
	-- A quiet glass pill (Kit.hudGlass Quiet: permanent, so it sits back behind toasts and
	-- the quest pill); an Aura Surge turns its tint amber and brings it forward.
	local strip = Kit.hudGlass(screen, {
		Name = "DepositStrip",
		Quiet = true,
		Size = UDim2.fromOffset(300, STRIP_H),
		Position = UDim2.new(0.5, 0, 0, STRIP_Y),
		AnchorPoint = Vector2.new(0.5, 0),
	})
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
	local stripLead = stripText("Lead", 1, 16)
	stripLead.Text = "Deposit bonus:"
	local gaugeValue = stripText("Value", 2, 18)
	local gaugeNext = stripText("Next", 3, 14)
	gaugeNext.TextColor3 = C.TextDim
	local STRIP_TEXT: { [TextLabel]: number } = { [stripLead] = 16, [gaugeValue] = 18, [gaugeNext] = 14 }
	-- The strip is as wide as its widest line (the longest value and countdown), never
	-- under its 300 px: text held at a size on a phone needs more room than the design's.
	local function fitStrip()
		local width = textWidth(stripLead.Text, stripLead.TextSize, F.Display)
			+ textWidth("x0.0", gaugeValue.TextSize, F.Display)
			+ textWidth("· 0:00", gaugeNext.TextSize, F.Display)
		strip.Size = UDim2.fromOffset(math.max(300, width + 6 * 2 + 20 * 2), STRIP_H)
	end
	-- A rescale re-sizes held text (Kit.reflowText): the strip follows.
	for label in STRIP_TEXT do
		label:GetPropertyChangedSignal("TextSize"):Connect(fitStrip)
	end
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
		fitStrip()
		Kit.tween(strip, 0.3, {
			BackgroundColor3 = if active then C.Amber else G.TintTop,
			BackgroundTransparency = if active then G.Pill else G.Quiet,
		})
	end

	-- Next goal: "Next: Protein Bro 1/2" over "merge 2x Gym Rookie" ------------------------
	-- One glass strip like the deposit strip, the third row of the top stack once the
	-- tutorial is done (above the dumbbell on compact screens): the target's thumbnail (a
	-- silhouette until it is discovered), its name and count, what to do under them, and a
	-- thin bar along the bottom. The target comes from Shared.NextGoal; the strip opens the
	-- Index.
	-- STACK_GAP under the deposit strip, and never under that many pixels on the glass (a
	-- small window's scale would close the gap).
	local function goalY(): number
		return STRIP_Y + STRIP_H + Kit.pxUp(STACK_GAP, STACK_GAP, screen)
	end
	local goal = Kit.hudGlass(screen, {
		Name = "NextGoal",
		Button = true,
		Quiet = true,
		Size = UDim2.fromOffset(280, GOAL_H),
		Position = UDim2.new(0.5, 0, 0, goalY()),
		AnchorPoint = Vector2.new(0.5, 0),
		Radius = Kit.RADIUS.M,
		Visible = false,
	}) :: TextButton
	Kit.selectable(goal)
	local goalThumb = group("Thumb", {
		Size = UDim2.fromOffset(36, 36),
		Position = UDim2.new(0, 7, 0.5, -2),
		AnchorPoint = Vector2.new(0, 0.5),
		ZIndex = 2,
		Parent = goal,
	})
	local function goalText(name: string, size: number, color: Color3, font: Enum.Font?): TextLabel
		return Kit.hudText(goal, {
			Name = name,
			Text = "",
			Font = font,
			TextSize = size,
			TextColor3 = color,
			StrokeThickness = 2,
			TextXAlignment = Enum.TextXAlignment.Left,
			Size = UDim2.fromOffset(10, 22),
			ZIndex = 3,
		})
	end
	local goalLead = goalText("Lead", 16, C.Gold)
	goalLead.Text = "Next:"
	local goalTitle = goalText("Title", 16, C.Text)
	-- The name is never cut off: short of room it is scaled into its box (paintGoal).
	local goalTitleFit = Kit.new("UITextSizeConstraint", { MinTextSize = 1, MaxTextSize = 200, Parent = goalTitle })
	local goalCount = goalText("Count", 14, C.Text, F.Number)
	local goalHint = goalText("Hint", 14, C.TextDim, F.UI)
	goalHint.Position = UDim2.fromOffset(GOAL_TEXT_X, 20)
	goalHint.Size = UDim2.fromOffset(10, 16)
	local goalBar = Kit.new("Frame", {
		Name = "Bar",
		BackgroundColor3 = C.Gold,
		BorderSizePixel = 0,
		Size = UDim2.new(0, 0, 0, 3),
		Position = UDim2.new(0, GOAL_BAR_X, 1, -5),
		ZIndex = 2,
		Parent = goal,
	})
	Kit.round(goalBar)
	-- Touch: an invisible pad grows the low strip to a full tap target (sized in applyCompact).
	local goalPad = Kit.new("TextButton", {
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
		Parent = goal,
	})
	for _, button in { goal, goalPad } do
		button.Activated:Connect(function()
			Kit.sound("Click")
			openIndex()
		end)
	end
	goal.MouseEnter:Connect(function()
		Kit.tween(goal, 0.12, { BackgroundTransparency = G.Quiet - 0.2 })
	end)
	goal.MouseLeave:Connect(function()
		Kit.tween(goal, 0.12, { BackgroundTransparency = G.Quiet })
	end)
	local function tierName(tier: number): string
		local entry = Theme.Tiers[tier]
		return if entry then entry.Name else ("Tier " .. tier)
	end
	local goalKey = ""
	local goalTitleShown = ""
	local goalThumbKey = ""
	local goalWidth = 280
	local function paintGoal(data: { [string]: any })
		if type(data.discovered) ~= "table" or type(data.units) ~= "table" then
			return
		end
		local picked = NextGoal.pick({
			discovered = data.discovered,
			units = data.units,
		})
		local title, hint, count = NextGoal.text(picked, tierName)
		local key = title .. "|" .. hint .. "|" .. count
		if key == goalKey then
			Kit.tween(goalBar, 0.3, { Size = UDim2.new(0, math.floor((goalWidth - GOAL_BAR_X * 2) * picked.progress), 0, 3) })
			return
		end
		goalKey = key
		-- Line 1: "Next:", the target and the count; line 2: what to do. The strip hugs the
		-- wider line up to GOAL_MAX_W. Nothing is ever cut off with an ellipsis: short of room
		-- the hint goes first, which leaves the name both lines to wrap onto, and only then
		-- is the name scaled down (to the phone caption floor at the least).
		local room = GOAL_MAX_W - GOAL_TEXT_X - 12
		local leadW = drawnWidth(goalLead.Text, goalLead.TextSize, goalLead.Font)
		local countW = drawnWidth(count, goalCount.TextSize, goalCount.Font)
		local titleRoom = room - leadW - countW - 14
		local titleNeed = drawnWidth(title, goalTitle.TextSize, goalTitle.Font)
		local hintNeed = drawnWidth(hint, goalHint.TextSize, goalHint.Font)
		local tight = titleNeed > titleRoom
		local dropHint = tight or hintNeed > room
		local titleW = math.min(titleNeed, titleRoom)
		local hintW = if dropHint then 0 else hintNeed
		local x = GOAL_TEXT_X
		-- Text held at its size on a phone (applyCompact) is taller than the design's two
		-- lines: they, and the strip, grow with it.
		local lineH = math.max(20, goalTitle.TextSize + 2)
		local hintH = math.max(16, goalHint.TextSize + 1)
		local rowH = if dropHint then lineH + hintH else lineH
		-- Scaled only when it has to shrink: text that fits keeps its exact size. The cap is
		-- the size it would have had (a text size constraint counts screen pixels).
		goalTitle.TextScaled = tight
		goalTitle.TextWrapped = tight
		local cap = if tight then math.ceil(goalTitle.TextSize * math.max(if screenScale then screenScale.Scale else 1, 1)) else 200
		goalTitleFit.MinTextSize = 1
		goalTitleFit.MaxTextSize = cap
		goalTitleFit.MinTextSize = if tight then math.min(G.TextMinPhone, cap) else 1
		local function put(label: TextLabel, text: string, width: number, gap: number)
			label.Text = text
			label.Size = UDim2.fromOffset(width + 4, rowH)
			label.Position = UDim2.fromOffset(x, 2)
			x += width + gap
		end
		put(goalLead, goalLead.Text, leadW, 6)
		put(goalTitle, title, titleW, 8)
		put(goalCount, count, countW, 0)
		goalCount.TextColor3 = if picked.ready then C.MoneyText else C.Text
		goalHint.Text = string.upper(string.sub(hint, 1, 1)) .. string.sub(hint, 2)
		goalHint.Position = UDim2.fromOffset(GOAL_TEXT_X, lineH)
		goalHint.Size = UDim2.fromOffset(hintW + 4, hintH)
		goalHint.Visible = not dropHint
		goalWidth = math.max(x, GOAL_TEXT_X + hintW) + 12
		goal.Size = UDim2.fromOffset(goalWidth, GOAL_H + (lineH - 20) + (hintH - 16))
		goalBar.Size = UDim2.new(0, math.floor((goalWidth - GOAL_BAR_X * 2) * picked.progress), 0, 3)
		-- A new target (not just a new count) gets a fresh thumbnail and a pop.
		local thumbKey = picked.kind .. picked.tier
		if thumbKey ~= goalThumbKey then
			goalThumbKey = thumbKey
			for _, child in goalThumb:GetChildren() do
				child:Destroy()
			end
			pcall(Kit.unitViewport, goalThumb, picked.tier, { Size = UDim2.fromScale(1, 1) }, picked.kind == "merge")
		end
		if title ~= goalTitleShown then
			goalTitleShown = title
			Kit.pop(goal, 0.6)
		end
	end
	-- The strip's texts are held at a readable size on a phone (applyCompact), where 16 and
	-- 14 design px are 10 px: a new size lays the strip out again.
	local GOAL_TEXT: { [TextLabel]: number } = { [goalLead] = 16, [goalTitle] = 16, [goalCount] = 14, [goalHint] = 14 }
	for label in GOAL_TEXT do
		label:GetPropertyChangedSignal("TextSize"):Connect(function()
			goalKey = ""
			if State.data then
				paintGoal(State.data)
			end
		end)
	end
	-- Shown once the tutorial is done, outside the intro and game-mode runs. A tutorial
	-- finished this session first lets its quest pill slide out of the slot.
	local goalShown = false
	local goalHoldUntil = 0
	local goalSawTutorial = false
	local function updateGoal()
		local data = State.data
		local player = Players.LocalPlayer
		local show = data ~= nil
			and data.tutorialDone == true
			and os.clock() >= goalHoldUntil
			and screen:GetAttribute("RunActive") ~= true
			and screen:GetAttribute("ObbyMode") ~= true
			and screen:GetAttribute("CardioActive") ~= true
			and not (player ~= nil and player:GetAttribute("IntroPlaying") == true)
		if show and data then
			paintGoal(data)
		end
		if show ~= goalShown then
			goalShown = show
			goal.Visible = show
		end
	end
	State.changed.Event:Connect(function(data)
		if data.tutorialDone ~= true then
			goalSawTutorial = true
		elseif goalSawTutorial then
			goalSawTutorial = false
			goalHoldUntil = os.clock() + 1.5
			task.delay(1.6, updateGoal)
		end
		updateGoal()
	end)
	for _, name in { "RunActive", "ObbyMode", "CardioActive" } do
		screen:GetAttributeChangedSignal(name):Connect(updateGoal)
	end
	pcall(function()
		Players.LocalPlayer:GetAttributeChangedSignal("IntroPlaying"):Connect(updateGoal)
	end)

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
	-- Scaled to its line of the plaque, but never under a phone caption on the glass (the
	-- compact dumbbell's line is 17 design px tall: 11 px on a phone).
	local tankCaption = Kit.hudText(tank, {
		Name = "Caption",
		Text = string.upper(W.Orb),
		TextScaled = true,
		MaxTextSize = 200,
		MinPx = G.TextMinPhone,
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

	-- Bottom left: bonus chips, cash multiplier line, cash amount + plus -------------------
	-- The cash amount is the anchor: the biggest text, at the corner, and it never moves.
	-- A bonus that is off shows nothing; one that is on is a small chip with its words.
	local wallet = group("Wallet", {
		Size = UDim2.fromOffset(420, 168),
		Position = UDim2.new(0, EDGE_X, 1, -6),
		AnchorPoint = Vector2.new(0, 1),
	})
	local chips = group("Status", {
		Size = UDim2.fromOffset(400, CHIP_H),
		Position = UDim2.fromOffset(0, 62 - CHIP_H - 4),
		Parent = wallet,
	})
	Kit.new("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal,
		VerticalAlignment = Enum.VerticalAlignment.Center,
		Padding = UDim.new(0, 12),
		SortOrder = Enum.SortOrder.LayoutOrder,
		Parent = chips,
	})
	local chipTexts: { TextLabel } = {}
	local function status(name: string, icon: string, color: Color3, order: number, text: string, textColor: Color3?): (Frame, TextLabel)
		local holder = group(name, {
			AutomaticSize = Enum.AutomaticSize.X,
			Size = UDim2.fromOffset(0, CHIP_H),
			LayoutOrder = order,
			Visible = false,
			Parent = chips,
		})
		Kit.new("UIListLayout", {
			FillDirection = Enum.FillDirection.Horizontal,
			VerticalAlignment = Enum.VerticalAlignment.Center,
			Padding = UDim.new(0, 4),
			SortOrder = Enum.SortOrder.LayoutOrder,
			Parent = holder,
		})
		Kit.hudIcon(holder, icon, CHIP_ICON, color, { Name = "Icon", LayoutOrder = 1, ZIndex = 2 })
		local caption = Kit.hudText(holder, {
			Name = "Caption",
			Text = text,
			Font = F.UI,
			TextSize = CHIP_TEXT,
			MinPx = true,
			StrokeThickness = 2,
			TextColor3 = textColor,
			AutomaticSize = Enum.AutomaticSize.X,
			Size = UDim2.fromOffset(0, CHIP_H),
			LayoutOrder = 2,
			ZIndex = 3,
		})
		table.insert(chipTexts, caption)
		return holder, caption
	end
	local premiumRow = status("Premium", Kit.pickIcon("Crown", "Star"), C.Gold, 1, string.format("Premium +%d%%", PREMIUM_BONUS), C.Gold)
	local friendsRow, friendsText = status("Friends", Kit.pickIcon("Invite", "Fans"), C.Rizz, 2, "Friends")
	local boostRow = status("Boost", "Surge", C.Amber, 3, "SURGE x" .. Economy.SURGE_MULTIPLIER, C.Amber)
	-- A chip comes on with a pop and goes off without a trace.
	local function setStatus(row: Frame, on: boolean)
		if row.Visible == on then
			return
		end
		row.Visible = on
		if on then
			Kit.pop(row, 0.6)
		end
	end
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
	-- The plus follows the cash amount's width. The chips sit over the "Cash" line, or
	-- beside it where the wallet is in the top-left corner (touch: nothing above it then).
	local function layoutWallet()
		local x = math.max(textWidth(moneyLabel.Text, moneyLabel.TextSize, moneyLabel.Font) + 4, 60)
		addButton.Position = UDim2.fromOffset(x + 10, 92)
		chips.Position = if Kit.touch
			then UDim2.fromOffset(drawnWidth(multLine.Text, multLine.TextSize, multLine.Font) + 14, 60)
			else UDim2.fromOffset(0, 62 - CHIP_H - 4)
	end
	moneyLabel:GetPropertyChangedSignal("Text"):Connect(layoutWallet)

	-- Layout mode ------------------------------------------------------------------------
	-- Compact screens: smaller grid icons, no promo, a smaller dumbbell. Touch (live,
	-- Kit.onInput): the wallet moves to the top left with the grid under it (one row
	-- when compact) so the thumbstick's bottom-left third stays clear, the bonus chips
	-- move beside the "Cash" line, the FREE gift rises above the jump button, the gear
	-- leaves the top bar,
	-- and every button is >= TAP_PX on screen. Gamepad / TV: title-safe edges. While a
	-- window is open the grid slides off the left edge, the bottom groups below the
	-- bottom edge and the top groups up, and all glide back.
	local gridIcon = GRID_ICON
	local cellH = GRID_ICON + CAPTION + GRID_PAD * 2
	local oneRow = false
	local L = { edge = EDGE_X, bottom = -6, walletTop = false, walletY = 0, gridY = GRID_Y, tap = 0, tankX = 0, freeY = -20 }
	local function gridRows(): { { string } }
		if oneRow then
			return { { "Home", "Ranking", "Modes", "Index", "Shop", "Invite", "Daily" } }
		end
		return GRID_ROWS
	end
	local function gridHeight(): number
		local rows = #gridRows()
		return rows * cellH + (rows - 1) * GRID_GAP
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
		-- The plate is the tap target, so the icon keeps its size on touch; the plate holds
		-- the icon and the caption at its held size (applyCompact holds it first).
		gridIcon = if compact then GRID_ICON_COMPACT else GRID_ICON
		cellH = math.max(GRID_PAD + gridIcon + captions[1].TextSize + 4 + 3, L.tap)
		-- Top-left wallet: nothing sits over the "Cash" line there (the chips move beside
		-- it), so the 62 px above it are dropped.
		local skip = if touch then 62 else 0
		L.walletY = 168 - skip
		L.gridY = if touch then 138 - skip + 12 else GRID_Y
		-- Thumbstick zone: left third, lower half of the screen (design px below the top bar).
		local designW = size.X / scale
		local halfY = (size.Y / 2 - TOP_BAR_PX) / scale
		promoFits = not touch or L.gridY + gridHeight() + PROMO_GAP + PROMO_H + 16 <= halfY
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
		return UDim2.fromOffset(L.edge, L.gridY + gridHeight() + PROMO_GAP)
	end, function()
		return UDim2.fromOffset(-PROMO_W - 60, L.gridY + gridHeight() + PROMO_GAP)
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
	-- The goal strip: under the deposit strip, or just above the (compact) dumbbell.
	slot(goal, function()
		if compact then
			return UDim2.new(0.5, L.tankX, 1, L.bottom - math.ceil(DUMBBELL_W_COMPACT * DUMBBELL_ASPECT) - 8)
		end
		return UDim2.new(0.5, 0, 0, goalY())
	end, function()
		return if compact then UDim2.new(0.5, L.tankX, 1, 200) else UDim2.new(0.5, 0, 0, -140)
	end)
	local targets: { [GuiObject]: UDim2 } = {}
	-- Groups that have faded out for an open window sit at their away spot.
	local parked: { [GuiObject]: boolean } = {}
	local function place(animate: boolean)
		-- The crate panel (Popups, attribute "CratePanelOpen") covers the right edge
		-- down to the FREE gift, so the gift steps aside while it is up.
		local crate = screen:GetAttribute("CratePanelOpen") == true
		for _, s in slots do
			local pos = if parked[s.gui] or (crate and s.gui == corner) then s.away() else s.rest()
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
		for _, caption in captions do
			-- The size is in design px: a small screen's UI scale would shrink it under the
			-- caption floor, so the size is held on the glass.
			Kit.holdText(caption, Kit.captionPx(), CAPTION)
		end
		measure()
		-- Every plate is as wide as the widest caption as drawn (the Daily countdown
		-- counts), so no caption can reach its neighbour. A phone's single row is the one
		-- exception: there each plate hugs its own caption, or the row would run under the
		-- top centre.
		local textSize = captions[1].TextSize
		local captionH = textSize + 4
		local function captionWidth(name: string): number
			local width = drawnWidth(CAPTIONS[name], textSize, F.Display)
			return if name == "Daily" then math.max(width, drawnWidth("00:00:00", textSize, F.Display)) else width
		end
		local widest = 0
		for name in CAPTIONS do
			widest = math.max(widest, captionWidth(name))
		end
		local gridW = 0
		for row, names in gridRows() do
			local x = 0
			for _, name in names do
				local button = Hud.buttons[name]
				local cellW = math.max((if oneRow then captionWidth(name) else widest) + GRID_PAD * 2, gridIcon + GRID_PAD * 2, L.tap)
				button.Size = UDim2.fromOffset(cellW, cellH)
				button.Position = UDim2.fromOffset(x, (row - 1) * (cellH + GRID_GAP))
				gridIcons[name].Size = UDim2.fromOffset(gridIcon, gridIcon)
				x += cellW + GRID_GAP
			end
			gridW = math.max(gridW, x - GRID_GAP)
		end
		grid.Size = UDim2.fromOffset(gridW, gridHeight())
		for _, caption in captions do
			caption.Size = UDim2.new(1, 0, 0, captionH)
		end
		-- The deposit strip's three texts are held the same way (a hard floor: 16, 18 and 14
		-- design px are 10 to 12 px on a phone), and the strip widens round them.
		for label, design in STRIP_TEXT do
			Kit.holdText(label, Kit.captionPx(), design, true)
		end
		fitStrip()
		-- So are the goal strip's (it lays itself out again when a size changes).
		for label, design in GOAL_TEXT do
			Kit.holdText(label, Kit.captionPx(), design, true)
		end
		-- The bonus chips keep their words at a readable size; a touch phone, where the
		-- wallet shares the top-left corner with the menu row, goes without them.
		for _, label in chipTexts do
			Kit.holdText(label, Kit.captionPx(), CHIP_TEXT)
		end
		chips.Visible = not (Kit.touch and compact)
		layoutWallet()
		local width = if compact then DUMBBELL_W_COMPACT else DUMBBELL_W
		tank.Size = UDim2.fromOffset(width, width * DUMBBELL_ASPECT)
		-- The caption's line of the compact plaque is shorter than the caption held at its
		-- phone size (MinPx): its box grows round the line to hold it.
		local captionRoom = math.max(0, math.ceil(Kit.pxUp(G.TextMinPhone, 0, tankCaption) - width * DUMBBELL_ASPECT * captionSize.Y.Scale))
		tankCaption.Size = captionSize + UDim2.fromOffset(0, captionRoom)
		tankCaption.Position = captionPos - UDim2.fromOffset(0, captionRoom // 2)
		goal.AnchorPoint = Vector2.new(0.5, if compact then 1 else 0)
		goalPad.Size = UDim2.new(1, 0, 0, math.max(GOAL_H, L.tap))
		goalPad.Visible = Kit.touch
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
	local selectables: { GuiObject } = { promoButton, addButton, quitButton, goal }
	for _, button in Hud.buttons do
		table.insert(selectables, button)
	end
	local function updateSelectable()
		local blocked = screen:GetAttribute("WindowOpen") == true or screen:GetAttribute("ModalOpen") == true
		for _, button in selectables do
			Kit.selectable(button, not blocked)
		end
	end
	-- A window, modal or reveal is up: the HUD fades out where it stands, then parks off
	-- screen (so nothing in it takes a tap) with its resting look back for whatever changes
	-- meanwhile; closing puts it back and fades it in. The promo eases itself out and in
	-- (updatePromo); toasts and the tutorial pill belong to their own modules and stay.
	local faders: { GuiObject } = { grid, wallet, tank, corner, units, strip, goal, gear }
	local hudHidden = false
	local function setHudHidden(hidden: boolean)
		if hidden == hudHidden then
			return
		end
		hudHidden = hidden
		if hidden then
			for _, gui in faders do
				Kit.fade(gui, false, HIDE_TIME, function()
					if gui == gear then
						gear.Visible = false
					else
						parked[gui] = true
						place(false)
					end
				end)
			end
		else
			table.clear(parked)
			gear.Visible = true
			place(false)
			for _, gui in faders do
				Kit.fade(gui, true, HIDE_TIME)
			end
		end
	end
	Kit.onWindowOpen(function(open: boolean)
		setHudHidden(open)
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

		setStatus(premiumRow, data.premium == true)
		local friends = math.floor((data.friendBonus or 0) * 100 + 0.5)
		friendsText.Text = string.format("Friends +%d%%", friends)
		setStatus(friendsRow, friends > 0)

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

	-- Discoveries land on the Index button -----------------------------------------------
	Hud.indexPoint = function(): Vector2?
		local button = Hud.buttons.Index
		if screen:GetAttribute("WindowOpen") == true or not (screen.Enabled and grid.Visible and button.Visible) then
			return nil
		end
		-- The rest position, not the current one: the menu may still be sliding back in.
		local scale = if screenScale then screenScale.Scale else 1
		local rest = Vector2.new(
			L.edge + button.Position.X.Offset + button.Size.X.Offset / 2,
			L.gridY + button.Position.Y.Offset + button.Size.Y.Offset / 2
		)
		local point = rest * scale
		local size = screen.AbsoluteSize
		if point.X < 0 or point.Y < 0 or point.X > size.X or point.Y > size.Y then
			return nil
		end
		return screen.AbsolutePosition + point
	end
	Hud.punchIndex = function()
		local button = Hud.buttons.Index
		Kit.pop(button, 2.4)
		sounds.play("Collect", 0.04, 1.25)
		-- A white ring spreads from the icon.
		local ring = Kit.new("Frame", {
			Name = "Punch",
			BackgroundColor3 = Color3.new(1, 1, 1),
			BackgroundTransparency = 0.3,
			Size = UDim2.fromScale(0.8, 0.8),
			Position = UDim2.fromScale(0.5, 0.5),
			AnchorPoint = Vector2.new(0.5, 0.5),
			ZIndex = 3,
			Parent = button,
		})
		Kit.round(ring)
		local edge = Kit.new("UIStroke", { Thickness = 4, Color = Color3.new(1, 1, 1), Transparency = 0.1, Parent = ring })
		Kit.tween(ring, 0.4, { Size = UDim2.fromScale(2, 2), BackgroundTransparency = 1 }, Enum.EasingStyle.Quart)
		Kit.tween(edge, 0.4, { Transparency = 1, Thickness = 1 }, Enum.EasingStyle.Quart)
		-- "+1" pops over the icon itself, big and gold, and rises only as far as the icon's
		-- top: the caption of the button above (Home) sits in the gap over it.
		local plus = Kit.hudText(button, {
			Name = "Plus",
			Text = "+1",
			TextSize = 38,
			MinPx = 22,
			TextColor3 = C.Gold,
			StrokeColor = G.TextInk,
			StrokeThickness = 3,
			Size = UDim2.new(1, 40, 0, 40),
			Position = UDim2.fromScale(0.5, 0.62),
			AnchorPoint = Vector2.new(0.5, 0.5),
			ZIndex = 6,
		})
		Kit.tween(plus, 0.7, { Position = UDim2.fromScale(0.5, 0.34) }, Enum.EasingStyle.Quad)
		local outline = plus:FindFirstChild("Outline")
		task.delay(0.4, function()
			Kit.tween(plus, 0.3, { TextTransparency = 1 })
			if outline then
				Kit.tween(outline, 0.3, { Transparency = 1 })
			end
		end)
		task.delay(0.75, function()
			ring:Destroy()
			plus:Destroy()
		end)
		-- The badge (new since the Index was last opened) pops with it.
		refreshIndexBadge()
		local badge = button:FindFirstChild("Badge")
		if badge and badge:IsA("GuiObject") and badge.Visible then
			Kit.pop(badge, 1.4)
		end
	end

	-- Deposit multiplier re-roll: the value flickers like a slot machine ------------------
	local spinning = false
	-- Never red: a deposit bonus is a bonus (x1 at the least).
	local function multColor(mult: number): Color3
		return if mult >= 1.2 then C.MoneyText else C.Gold
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
			-- Silent visual roll: the value flickers (from x1 up), then lands with a pop.
			local low = math.max(1, Economy.DEPOSIT_MIN)
			while elapsed < 0.6 do
				showMult(low + math.random() * math.max(0, Economy.DEPOSIT_MAX - low))
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

	-- Aura Surge: the strip changes and the "SURGE x2" chip joins the wallet; the screen grade
	-- and music are Fx.Surge's.
	local surgeActive: boolean? = nil
	local lastSurgeSecond = -1

	local function setSurge(active: boolean, announce: boolean)
		paintSurge(active)
		showMult(depositMult)
		setStatus(boostRow, active)
		if announce then
			Kit.pop(strip, if active then 0.8 else 0.4)
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
	-- Daily reward: a dot, a sunny caption and a gentle bounce while a reward waits; the
	-- countdown to the next one as the caption otherwise.
	local dailyText = ""
	local dailyReady: boolean? = nil
	local stopDailyBounce: (() -> ())? = nil
	local function paintDaily(text: string, ready: boolean)
		if ready ~= dailyReady then
			dailyReady = ready
			Kit.setBadge(dailyButton, if ready then "!" else nil)
			dailyCaption.TextColor3 = if ready then C.Gold else Color3.new(1, 1, 1)
			if ready then
				Kit.pop(dailyButton, 0.8)
				stopDailyBounce = Kit.breathe(dailyButton, 0.06)
			elseif stopDailyBounce then
				stopDailyBounce()
				stopDailyBounce = nil
			end
		end
		dailyCaption.Text = text
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
			local daily = data.daily
			if type(daily) == "table" then
				-- The dot and the bounce wait for the tutorial, like the window itself.
				local dailyNow = daily.claimable == true and data.tutorialDone == true
				local dailyLabel = if daily.claimable == true
					then CAPTIONS.Daily
					else Format.time(math.max(0, (tonumber(daily.nextIn) or 0) - State.age()))
				if dailyLabel ~= dailyText or dailyNow ~= dailyReady then
					dailyText = dailyLabel
					paintDaily(dailyLabel, dailyNow)
				end
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
