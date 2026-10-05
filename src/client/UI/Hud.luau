--[[
	Hud: always-on screen elements (design space 1280x720, below the top bar).

	  top left      wallet (rolling cash counter, gems, cash multiplier),
	                bonus chips, menu buttons (with badges), 2x cash promo
	  top centre    unit counter + live deposit multiplier gauge
	  top right     surge timer + settings
	  bottom centre orb tank (what you are carrying)
	  bottom left   version

	The bottom corners stay clear for the touch thumbstick and jump button.
	When the screen is short (attribute "Compact" on the ScreenGui) the promo
	and bonus chips hide.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local SocialService = game:GetService("SocialService")
local Workspace = game:GetService("Workspace")

local Economy = require(ReplicatedStorage.Shared.Economy)
local Format = require(ReplicatedStorage.Shared.Format)
local Net = require(ReplicatedStorage.Shared.Net)

local Kit = require(script.Parent.Kit)
local State = require(script.Parent.Parent.State)

local Theme = Kit.Theme
local C = Kit.C
local T = Kit.TEXT
local W = Theme.Words
local I = Theme.Icons

local Hud = {}

export type Handlers = {
	openWindow: (string) -> (),
	guide: ((string?) -> ())?,
	toast: ((string, string?) -> ())?,
}

-- Menu buttons by name (Shop, Index, Ranking, Free, Home, Invite) so other
-- modules (tutorial) can badge or highlight them.
Hud.buttons = {} :: { [string]: TextButton }

local GOLD_HEX = "#FFD23C"

function Hud.build(screen: ScreenGui, handlers: Handlers, sounds: any)
	local action = Net.event("Action")
	local cell = if Kit.touch then 84 else 76

	local function toast(text: string, tone: string?)
		if handlers.toast then
			handlers.toast(text, tone)
		end
	end

	-- Wallet (top left) --------------------------------------------------------------
	local wallet = Kit.panel(screen, {
		Name = "Wallet",
		Size = UDim2.fromOffset(300, 122),
		Position = UDim2.fromOffset(12, 10),
		Color = C.Panel,
		Radius = Kit.RADIUS.L,
	})
	local coin = Kit.new("Frame", {
		Name = "Coin",
		BackgroundColor3 = Color3.new(1, 1, 1),
		Size = UDim2.fromOffset(52, 52),
		Position = UDim2.fromOffset(10, 9),
		Parent = wallet,
	})
	Kit.round(coin)
	Kit.stroke(coin, 3)
	Kit.gradient(coin, Kit.lighten(C.Good, 0.35), Kit.darken(C.Good, 0.15))
	Kit.title(coin, { Text = "$", TextSize = 32, Size = UDim2.fromScale(1, 1), Position = UDim2.fromOffset(1, 2) })
	local moneyLabel = Kit.title(wallet, {
		Name = "Money",
		Text = "$0",
		TextSize = 38,
		TextWrapped = false,
		Size = UDim2.new(1, -84, 0, 40),
		Position = UDim2.fromOffset(72, 6),
		TextXAlignment = Enum.TextXAlignment.Left,
		TextColor3 = C.Good,
		StrokeThickness = 3,
	})
	local moneyPop = Kit.new("UIScale", { Parent = moneyLabel })
	local multLabel = Kit.title(wallet, {
		Name = "CashMult",
		Text = "CASH x1.0",
		TextSize = T.Small,
		TextWrapped = false,
		RichText = true,
		Size = UDim2.new(1, -84, 0, 18),
		Position = UDim2.fromOffset(73, 46),
		TextXAlignment = Enum.TextXAlignment.Left,
		TextColor3 = C.TextDim,
		StrokeThickness = 1.5,
	})
	local gemWell = Kit.well(wallet, {
		Name = "Gems",
		Size = UDim2.new(1, -16, 0, 44),
		Position = UDim2.fromOffset(8, 70),
		Radius = Kit.RADIUS.M,
	})
	Kit.text(
		gemWell,
		{ Text = I.Gem, TextSize = 26, Size = UDim2.fromOffset(40, 44), Position = UDim2.fromOffset(4, 0), StrokeThickness = 0 }
	)
	local gemsLabel = Kit.title(gemWell, {
		Name = "Amount",
		Text = "0",
		TextSize = 25,
		TextWrapped = false,
		Size = UDim2.new(1, -100, 1, 0),
		Position = UDim2.fromOffset(44, 1),
		TextXAlignment = Enum.TextXAlignment.Left,
		TextColor3 = Kit.lighten(C.Secondary, 0.2),
	})
	Kit.button(gemWell, {
		Name = "Add",
		Text = "+",
		Color = C.Good,
		Size = UDim2.fromOffset(48, 40),
		Position = UDim2.new(1, -3, 0.5, 0),
		AnchorPoint = Vector2.new(1, 0.5),
		TextSize = 28,
		Depth = 4,
	}, function()
		handlers.openWindow("Shop")
	end)

	-- Bonus chips under the wallet.
	local chips = Kit.new("Frame", {
		Name = "Chips",
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(300, 26),
		Position = UDim2.fromOffset(14, 140),
		Parent = screen,
	})
	Kit.list(chips, 6, true)
	local function chip(order: number, color: Color3): TextLabel
		return Kit.pill(chips, {
			Text = "",
			Color = color,
			TextSize = T.Tiny,
			Size = UDim2.fromOffset(0, 24),
			AutomaticSize = Enum.AutomaticSize.X,
			LayoutOrder = order,
		})
	end
	local friendsChip = chip(1, Kit.darken(C.Primary, 0.55))
	local premiumChip = chip(2, Kit.darken(C.Primary, 0.55))
	local surgeChip = chip(3, Kit.darken(C.Good, 0.35))

	-- Menu (left) ----------------------------------------------------------------------
	local menu = Kit.new("Frame", {
		Name = "Menu",
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(cell * 2 + 10, cell * 3 + 20),
		Position = UDim2.fromOffset(12, 176),
		Parent = screen,
	})
	Kit.new("UIGridLayout", {
		CellSize = UDim2.fromOffset(cell, cell),
		CellPadding = UDim2.fromOffset(10, 10),
		SortOrder = Enum.SortOrder.LayoutOrder,
		Parent = menu,
	})
	local function menuButton(name: string, icon: string, text: string, order: number, color: Color3, onClick: () -> ())
		local button = Kit.button(menu, {
			Name = name,
			Icon = icon,
			Text = text,
			Layout = "Stack",
			Color = color,
			Size = UDim2.fromOffset(cell, cell),
			LayoutOrder = order,
			Radius = Kit.RADIUS.L,
		}, onClick)
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

	menuButton("Shop", I.Shop, "Shop", 1, C.Window.Shop, function()
		handlers.openWindow("Shop")
	end)
	menuButton("Index", I.Index, "Index", 2, C.Window.Index, function()
		Kit.setGlow(Hud.buttons.Index, false)
		local data = State.data
		if data then
			seenDiscoveries = discoveredCount(data)
			refreshIndexBadge()
		end
		handlers.openWindow("Index")
	end)
	menuButton("Ranking", I.Ranking, "Ranking", 3, C.Window.Ranking, function()
		handlers.openWindow("Ranking")
	end)
	local freeButton = menuButton("Free", I.Free, "Free", 4, C.Good, function()
		local data = State.data
		if not data then
			return
		end
		local left = math.max(0, data.freeIn - State.age())
		if left <= 0 then
			if handlers.guide then
				handlers.guide("Free")
			end
			toast(I.Free .. " Your free reward is ready! Follow the arrow to the " .. W.Free .. " pad.", "good")
		else
			toast("Next free reward in " .. Format.time(left), "info")
		end
	end)
	menuButton("Home", I.Home, "Home", 5, C.Secondary, function()
		action:FireServer({ action = "Home" })
	end)
	menuButton("Invite", I.Invite, "Invite", 6, C.Accent, function()
		pcall(function()
			SocialService:PromptGameInvite(Players.LocalPlayer)
		end)
	end)

	-- Permanent 2x cash promo.
	local promoPass = Theme.Monetization.Passes.DoubleMoney
	local promo = Kit.new("Frame", {
		Name = "Promo",
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(cell * 2 + 10, 74),
		Position = UDim2.fromOffset(12, 176 + cell * 3 + 34),
		Parent = screen,
	})
	Kit.button(promo, {
		Name = "Buy",
		Icon = "💰",
		Text = promoPass.Title,
		Color = C.Primary,
		TextColor = C.Text,
		Size = UDim2.new(1, 0, 0, 58),
		Position = UDim2.fromOffset(0, 8),
		TextSize = 26,
	}, function()
		action:FireServer({ action = "PromptPass", name = "DoubleMoney" })
	end)
	Kit.pill(promo, {
		Name = "Tag",
		Text = "PERMANENT",
		Color = C.Secondary,
		TextSize = T.Tiny,
		Size = UDim2.fromOffset(96, 22),
		Position = UDim2.fromOffset(-4, -4),
		Rotation = -5,
		ZIndex = 3,
	})
	Kit.pill(promo, {
		Name = "Price",
		Text = promoPass.Price .. " R$",
		Color = C.Good,
		TextSize = T.Tiny,
		Size = UDim2.fromOffset(70, 22),
		Position = UDim2.new(1, 6, 1, -2),
		AnchorPoint = Vector2.new(1, 1),
		ZIndex = 3,
	})

	-- Top centre: unit counter + multiplier gauge ------------------------------------
	local counter = Kit.panel(screen, {
		Name = "Counter",
		Size = UDim2.fromOffset(190, 44),
		Position = UDim2.new(0.5, 0, 0, 8),
		AnchorPoint = Vector2.new(0.5, 0),
		Color = C.PanelLight,
		Radius = 22,
	})
	local counterLabel = Kit.title(counter, {
		Text = I.Unit .. " 0",
		TextSize = 28,
		TextWrapped = false,
		Size = UDim2.new(1, -16, 1, 0),
		Position = UDim2.fromOffset(8, 1),
	})

	local gauge = Kit.panel(screen, {
		Name = "Gauge",
		Size = UDim2.fromOffset(336, 72),
		Position = UDim2.new(0.5, 0, 0, 60),
		AnchorPoint = Vector2.new(0.5, 0),
		Color = C.Panel,
		Radius = Kit.RADIUS.L,
	})
	Kit.title(gauge, {
		Text = string.upper(W.Multiplier),
		TextSize = T.Small,
		TextWrapped = false,
		Size = UDim2.new(1, -90, 0, 22),
		Position = UDim2.fromOffset(14, 5),
		TextXAlignment = Enum.TextXAlignment.Left,
		TextColor3 = C.TextDim,
		StrokeThickness = 1.5,
	})
	local gaugeValue = Kit.title(gauge, {
		Name = "Value",
		Text = "x1.0",
		TextSize = 26,
		TextWrapped = false,
		Size = UDim2.fromOffset(80, 26),
		Position = UDim2.new(1, -12, 0, 2),
		AnchorPoint = Vector2.new(1, 0),
		TextXAlignment = Enum.TextXAlignment.Right,
		TextColor3 = C.Primary,
	})
	local bar = Kit.new("Frame", {
		Name = "Bar",
		BackgroundColor3 = Color3.new(1, 1, 1),
		Size = UDim2.new(1, -28, 0, 14),
		Position = UDim2.fromOffset(14, 31),
		Parent = gauge,
	})
	Kit.round(bar)
	Kit.stroke(bar, 2.5)
	Kit.new("UIGradient", {
		Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, C.Bad),
			ColorSequenceKeypoint.new(0.25, Color3.fromRGB(255, 200, 40)),
			ColorSequenceKeypoint.new(1, C.Good),
		}),
		Parent = bar,
	})
	-- Tick at 1.0x (break-even).
	local even = (1 - Economy.DEPOSIT_MIN) / (Economy.DEPOSIT_MAX - Economy.DEPOSIT_MIN)
	Kit.new("Frame", {
		Name = "Even",
		BackgroundColor3 = C.Stroke,
		BackgroundTransparency = 0.3,
		Size = UDim2.new(0, 2, 1, 0),
		Position = UDim2.fromScale(even, 0),
		Parent = bar,
	})
	local marker = Kit.new("Frame", {
		Name = "Marker",
		BackgroundColor3 = Color3.new(1, 1, 1),
		Size = UDim2.fromOffset(10, 24),
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.2, 0.5),
		Parent = bar,
	})
	Kit.corner(marker, 4)
	Kit.stroke(marker, 2.5)
	local gaugeNext = Kit.text(gauge, {
		Text = "",
		TextSize = T.Tiny,
		RichText = true,
		TextWrapped = false,
		Size = UDim2.new(1, -20, 0, 16),
		Position = UDim2.fromOffset(10, 50),
		TextColor3 = C.TextDim,
		StrokeThickness = 1.2,
	})

	-- Top right: surge timer + settings ----------------------------------------------
	local gear = Kit.button(screen, {
		Name = "Settings",
		Text = I.Settings,
		Color = C.Window.Settings,
		Font = Enum.Font.GothamBold,
		Size = UDim2.fromOffset(58, 58),
		Position = UDim2.new(1, -12, 0, 8),
		AnchorPoint = Vector2.new(1, 0),
		TextSize = 30,
	}, function()
		handlers.openWindow("Settings")
	end)
	Hud.buttons.Settings = gear

	local surge = Kit.panel(screen, {
		Name = "Surge",
		Size = UDim2.fromOffset(196, 58),
		Position = UDim2.new(1, -80, 0, 10),
		AnchorPoint = Vector2.new(1, 0),
		Color = C.Panel,
		Radius = Kit.RADIUS.L,
	})
	Kit.text(
		surge,
		{ Text = I.Surge, TextSize = 30, Size = UDim2.fromOffset(46, 58), Position = UDim2.fromOffset(4, 0), StrokeThickness = 0 }
	)
	local surgeTitle = Kit.title(surge, {
		Text = "NEXT " .. string.upper(W.Surge),
		TextSize = T.Tiny,
		TextWrapped = false,
		Size = UDim2.new(1, -54, 0, 18),
		Position = UDim2.fromOffset(48, 7),
		TextXAlignment = Enum.TextXAlignment.Left,
		TextColor3 = Kit.lighten(C.Secondary, 0.25),
		StrokeThickness = 1.5,
	})
	local surgeTime = Kit.title(surge, {
		Text = "0:00",
		TextSize = 26,
		TextWrapped = false,
		Size = UDim2.new(1, -54, 0, 28),
		Position = UDim2.fromOffset(48, 24),
		TextXAlignment = Enum.TextXAlignment.Left,
	})
	local surgeStroke = surge:FindFirstChildOfClass("UIStroke") :: UIStroke

	-- Bottom centre: carried tank ------------------------------------------------------
	local tank = Kit.panel(screen, {
		Name = "Tank",
		Size = UDim2.fromOffset(330, 96),
		Position = UDim2.new(0.5, 0, 1, -10),
		AnchorPoint = Vector2.new(0.5, 1),
		Color = C.Panel,
		Radius = Kit.RADIUS.XL,
		StrokeThickness = 4,
	})
	local tankStroke = tank:FindFirstChildOfClass("UIStroke") :: UIStroke
	Kit.text(
		tank,
		{ Text = I.Orb, TextSize = 28, Size = UDim2.fromOffset(40, 40), Position = UDim2.fromOffset(12, 6), StrokeThickness = 0 }
	)
	Kit.title(tank, {
		Text = string.upper(W.Orb),
		TextSize = T.H3,
		TextWrapped = false,
		Size = UDim2.fromOffset(120, 40),
		Position = UDim2.fromOffset(54, 6),
		TextXAlignment = Enum.TextXAlignment.Left,
		TextColor3 = Kit.lighten(C.Orb, 0.2),
	})
	local carriedLabel = Kit.title(tank, {
		Name = "Carried",
		Text = "0",
		TextSize = 30,
		TextWrapped = false,
		Size = UDim2.new(1, -150, 0, 40),
		Position = UDim2.new(1, -16, 0, 6),
		AnchorPoint = Vector2.new(1, 0),
		TextXAlignment = Enum.TextXAlignment.Right,
	})
	local carriedPop = Kit.new("UIScale", { Parent = carriedLabel })
	local _, setFill, fillLabel = Kit.progress(tank, {
		Name = "Fill",
		Color = C.Orb,
		Size = UDim2.new(1, -28, 0, 28),
		Position = UDim2.fromOffset(14, 52),
		TextSize = T.Small,
	})

	-- Version (bottom left, tiny) -----------------------------------------------------
	Kit.text(screen, {
		Name = "Version",
		Text = "v" .. Economy.VERSION,
		TextSize = 12,
		TextWrapped = false,
		Size = UDim2.fromOffset(100, 16),
		Position = UDim2.new(0, 12, 1, -6),
		AnchorPoint = Vector2.new(0, 1),
		TextXAlignment = Enum.TextXAlignment.Left,
		TextColor3 = C.TextDim,
		TextTransparency = 0.3,
		StrokeThickness = 1,
	})

	-- Layout mode ------------------------------------------------------------------------
	local function applyCompact()
		local compact = screen:GetAttribute("Compact") == true
		local data = State.data
		promo.Visible = not compact and not (data and data.passes.DoubleMoney)
		chips.Visible = not compact
	end
	screen:GetAttributeChangedSignal("Compact"):Connect(applyCompact)

	-- Updates ------------------------------------------------------------------------------
	local shownMoney: number? = nil
	local targetMoney = 0
	local lastCarried = 0
	local tankFull = false

	local function refresh()
		local data = State.data
		if not data then
			return
		end
		if shownMoney == nil then
			shownMoney = data.money
			moneyLabel.Text = State.money(data.money)
		elseif data.money > targetMoney + 0.5 then
			moneyPop.Scale = 1.1
			Kit.tween(moneyPop, 0.3, { Scale = 1 }, Enum.EasingStyle.Back)
		end
		targetMoney = data.money
		gemsLabel.Text = State.num(data.gems) .. " " .. W.Gem
		multLabel.Text = string.format('CASH <font color="%s">x%.1f</font>', GOLD_HEX, data.moneyMult)
		counterLabel.Text = I.Unit .. " " .. State.num(data.totalObtained)
		carriedLabel.Text = State.num(data.carried)

		friendsChip.Text = string.format("%s FRIENDS +%d%%", I.Friends, math.floor(data.friendBonus * 100 + 0.5))
		premiumChip.Visible = data.premium == true
		premiumChip.Text = I.Premium .. " PREMIUM +10%"
		applyCompact()

		local capacity = math.max(data.production * 30, 1)
		local ratio = data.carried / capacity
		setFill(ratio)
		local full = ratio >= 1
		if full ~= tankFull then
			tankFull = full
			if full then
				sounds.play("Toast")
			end
		end
		fillLabel.Text = if full then "FULL! DEPOSIT IT" elseif data.carried <= 0 then "WALK OVER " .. string.upper(W.Orb) else ""
		if data.carried > lastCarried then
			carriedPop.Scale = 1.15
			Kit.tween(carriedPop, 0.25, { Scale = 1 })
		end
		lastCarried = data.carried

		if seenDiscoveries == nil then
			seenDiscoveries = discoveredCount(data)
		end
		refreshIndexBadge()
	end
	State.changed.Event:Connect(refresh)

	local pulse = 0
	local freeText = ""
	RunService.Heartbeat:Connect(function(dt)
		local now = Workspace:GetServerTimeNow()
		pulse += dt

		-- Rolling cash counter.
		if shownMoney ~= nil and shownMoney ~= targetMoney then
			local shown = shownMoney :: number
			local diff = targetMoney - shown
			-- Earnings roll up; spending snaps so purchases feel instant.
			if diff < 0 or math.abs(diff) <= math.max(1, math.abs(targetMoney) * 0.0005) then
				shown = targetMoney
			else
				shown += diff * math.min(1, dt * 7)
			end
			shownMoney = shown
			moneyLabel.Text = State.money(shown)
		end

		local mult = ReplicatedStorage:GetAttribute("DepositMult") or 1
		local nextAt = ReplicatedStorage:GetAttribute("DepositNextAt") or now
		local color = if mult >= 1.2 then C.Good elseif mult < 1 then C.Bad else C.Primary
		gaugeValue.Text = string.format("x%.1f", mult)
		gaugeValue.TextColor3 = color
		gaugeNext.Text = string.format('changes in <font color="%s">%ds</font>', GOLD_HEX, math.max(0, math.ceil(nextAt - now)))
		local ratio = (mult - Economy.DEPOSIT_MIN) / (Economy.DEPOSIT_MAX - Economy.DEPOSIT_MIN)
		marker.Position = UDim2.fromScale(math.clamp(ratio, 0, 1), 0.5)

		local active, left = Economy.surgeState(now)
		surgeTime.Text = Format.time(left)
		surgeTitle.Text = if active
			then string.upper(W.Surge) .. " x" .. Economy.SURGE_MULTIPLIER .. "!"
			else "NEXT " .. string.upper(W.Surge)
		surgeTitle.TextColor3 = if active then C.Good else Kit.lighten(C.Secondary, 0.25)
		surgeStroke.Color = if active then C.Good:Lerp(C.Stroke, 0.5 + 0.5 * math.sin(pulse * 6)) else C.Stroke
		surgeChip.Visible = active
		surgeChip.Text = I.Surge .. " SURGE x" .. Economy.SURGE_MULTIPLIER

		tankStroke.Color = if tankFull then C.Bad:Lerp(C.Stroke, 0.5 + 0.5 * math.sin(pulse * 7)) else C.Stroke

		-- Free reward countdown on its menu button.
		local data = State.data
		if data then
			local freeLeft = math.max(0, data.freeIn - State.age())
			local ready = freeLeft <= 0
			local text = if ready then "FREE!" else Format.time(freeLeft)
			if text ~= freeText then
				freeText = text
				Kit.setButton(freeButton, text)
				Kit.setBadge(freeButton, if ready then "!" else nil)
				Kit.setGlow(freeButton, ready, C.Primary)
			end
		end
	end)

	refresh()
end

return Hud
