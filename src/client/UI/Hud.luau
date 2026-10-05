--[[
	Hud: always-on screen elements.

	  top centre    unit counter + live deposit multiplier gauge
	  left          menu buttons (Home, Ranking, Index, Shop, Invite) + 2x promo
	  bottom left   bonus badges, cash multiplier, cash, gems, "+" button
	  bottom centre orb tank (what you are carrying)
	  bottom right  surge timer + version
	  top right     settings button
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
local W = Theme.Words
local I = Theme.Icons

local Hud = {}

export type Handlers = {
	openWindow: (string) -> (),
}

local function menuButton(parent: Instance, icon: string, text: string, order: number, color: Color3, onClick: () -> ()): TextButton
	local button = Kit.new("TextButton", {
		AutoButtonColor = false,
		BackgroundColor3 = Color3.new(1, 1, 1),
		Size = UDim2.fromOffset(78, 78),
		Text = "",
		LayoutOrder = order,
		Parent = parent,
	})
	Kit.corner(button, 16)
	Kit.stroke(button, 3)
	Kit.gradient(button, Kit.lighten(color, 0.1), Kit.darken(color, 0.25))
	Kit.text(button, { Text = icon, Size = UDim2.new(1, 0, 0.62, 0), Position = UDim2.fromScale(0, 0.04) })
	Kit.title(button, { Text = text, Size = UDim2.new(1, -6, 0.3, 0), Position = UDim2.new(0, 3, 0.66, 0) })
	Kit.bouncy(button)
	button.Activated:Connect(onClick)
	return button
end

local function badge(parent: Instance, icon: string, order: number): (Frame, TextLabel)
	local frame = Kit.new("Frame", {
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(64, 64),
		LayoutOrder = order,
		Parent = parent,
	})
	Kit.text(frame, { Text = icon, Size = UDim2.fromScale(1, 0.7) })
	local label = Kit.title(frame, { Text = "", Size = UDim2.fromScale(1, 0.36), Position = UDim2.fromScale(0, 0.66) })
	return frame, label
end

function Hud.build(screen: ScreenGui, handlers: Handlers, sounds: any)
	local action = Net.event("Action")

	-- Left menu ---------------------------------------------------------------
	local menu = Kit.new("Frame", {
		Name = "Menu",
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(260, 180),
		Position = UDim2.fromOffset(14, 110),
		Parent = screen,
	})
	Kit.new("UIGridLayout", {
		CellSize = UDim2.fromOffset(78, 78),
		CellPadding = UDim2.fromOffset(8, 8),
		SortOrder = Enum.SortOrder.LayoutOrder,
		Parent = menu,
	})
	menuButton(menu, I.Home, "Home", 1, C.Secondary, function()
		sounds.play("Click")
		action:FireServer({ action = "Home" })
	end)
	menuButton(menu, I.Ranking, "Ranking", 2, C.Window.Ranking, function()
		sounds.play("Click")
		handlers.openWindow("Ranking")
	end)
	menuButton(menu, I.Index, "Index", 3, C.Window.Index, function()
		sounds.play("Click")
		handlers.openWindow("Index")
	end)
	menuButton(menu, I.Shop, "Shop", 4, C.Window.Shop, function()
		sounds.play("Click")
		handlers.openWindow("Shop")
	end)
	menuButton(menu, I.Invite, "Invite", 5, C.Good, function()
		sounds.play("Click")
		pcall(function()
			SocialService:PromptGameInvite(Players.LocalPlayer)
		end)
	end)

	-- Permanent 2x cash promo.
	local promoPass = Theme.Monetization.Passes.DoubleMoney
	local promo = Kit.new("Frame", {
		Name = "Promo",
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(230, 96),
		Position = UDim2.fromOffset(14, 300),
		Parent = screen,
	})
	local promoTag = Kit.title(promo, {
		Text = "PERMANENT",
		Size = UDim2.fromOffset(130, 26),
		Position = UDim2.fromOffset(4, -8),
		TextColor3 = C.Secondary,
		Rotation = -4,
		ZIndex = 3,
	})
	promoTag.TextXAlignment = Enum.TextXAlignment.Left
	Kit.button(promo, {
		Text = promoPass.Title,
		Color = C.Primary,
		Size = UDim2.fromOffset(220, 58),
		Position = UDim2.fromOffset(0, 12),
	}, function()
		action:FireServer({ action = "PromptPass", name = "DoubleMoney" })
	end)
	Kit.title(promo, {
		Text = "Only " .. promoPass.Price .. " R$",
		Size = UDim2.fromOffset(220, 24),
		Position = UDim2.fromOffset(0, 72),
	})

	-- Bottom-left: badges + cash ------------------------------------------------
	local wallet = Kit.new("Frame", {
		Name = "Wallet",
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(420, 200),
		Position = UDim2.new(0, 14, 1, -14),
		AnchorPoint = Vector2.new(0, 1),
		Parent = screen,
	})
	local badges = Kit.new("Frame", {
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(300, 64),
		Parent = wallet,
	})
	Kit.new("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal,
		Padding = UDim.new(0, 8),
		SortOrder = Enum.SortOrder.LayoutOrder,
		Parent = badges,
	})
	local _, premiumLabel = badge(badges, I.Premium, 1)
	local _, friendsLabel = badge(badges, I.Friends, 2)
	local surgeBadge, surgeBadgeLabel = badge(badges, I.Surge, 3)

	local multLabel = Kit.title(wallet, {
		Text = "Cash [1.0x]",
		Size = UDim2.fromOffset(300, 36),
		Position = UDim2.fromOffset(0, 70),
		TextXAlignment = Enum.TextXAlignment.Left,
		RichText = true,
	})
	local moneyLabel = Kit.title(wallet, {
		Text = "$0",
		Size = UDim2.fromOffset(330, 58),
		Position = UDim2.fromOffset(0, 104),
		TextXAlignment = Enum.TextXAlignment.Left,
		TextColor3 = C.Good,
	})
	local gemsLabel = Kit.title(wallet, {
		Text = I.Gem .. " 0",
		Size = UDim2.fromOffset(200, 32),
		Position = UDim2.fromOffset(0, 164),
		TextXAlignment = Enum.TextXAlignment.Left,
		TextColor3 = C.Secondary,
	})
	Kit.button(wallet, {
		Text = "+",
		Color = C.Good,
		Size = UDim2.fromOffset(54, 54),
		Position = UDim2.fromOffset(340, 106),
	}, function()
		handlers.openWindow("Shop")
	end)

	-- Top centre: unit counter + multiplier gauge -------------------------------
	local counter = Kit.panel(screen, {
		Name = "Counter",
		Size = UDim2.fromOffset(170, 46),
		Position = UDim2.new(0.5, 0, 0, 8),
		AnchorPoint = Vector2.new(0.5, 0),
		Color = C.PanelLight,
		Radius = 12,
	})
	local counterLabel = Kit.title(counter, { Text = I.Unit .. " 0", Size = UDim2.new(1, -16, 1, -8), Position = UDim2.fromOffset(8, 4) })

	local gauge = Kit.new("Frame", {
		Name = "Gauge",
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(340, 74),
		Position = UDim2.new(0.5, 0, 0, 58),
		AnchorPoint = Vector2.new(0.5, 0),
		Parent = screen,
	})
	local gaugeTitle = Kit.title(gauge, { Text = W.Multiplier .. ": 1.0x", Size = UDim2.new(1, 0, 0, 26), RichText = true })
	local bar = Kit.new("Frame", {
		BackgroundColor3 = Color3.new(1, 1, 1),
		Size = UDim2.new(1, 0, 0, 16),
		Position = UDim2.fromOffset(0, 30),
		Parent = gauge,
	})
	Kit.corner(bar, 8)
	Kit.stroke(bar, 2)
	Kit.new("UIGradient", {
		Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, C.Bad),
			ColorSequenceKeypoint.new(0.3, Color3.fromRGB(255, 200, 40)),
			ColorSequenceKeypoint.new(1, C.Good),
		}),
		Parent = bar,
	})
	local marker = Kit.new("Frame", {
		BackgroundColor3 = Color3.new(1, 1, 1),
		Size = UDim2.fromOffset(6, 24),
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.2, 0.5),
		Parent = bar,
	})
	Kit.corner(marker, 3)
	Kit.stroke(marker, 2)
	local gaugeNext = Kit.text(gauge, { Text = "", Size = UDim2.new(1, 0, 0, 22), Position = UDim2.fromOffset(0, 50), RichText = true })

	-- Bottom centre: carried tank ------------------------------------------------
	local tank = Kit.panel(screen, {
		Name = "Tank",
		Size = UDim2.fromOffset(280, 112),
		Position = UDim2.new(0.5, 0, 1, -12),
		AnchorPoint = Vector2.new(0.5, 1),
		Color = C.PanelLight,
		Radius = 18,
		StrokeThickness = 4,
	})
	local display = Kit.panel(tank, {
		Size = UDim2.new(1, -40, 0, 52),
		Position = UDim2.fromOffset(20, 10),
		Color = C.PanelDark,
		Radius = 10,
	})
	Kit.title(
		display,
		{ Text = string.upper(W.Orb), Size = UDim2.new(1, 0, 0.36, 0), Position = UDim2.fromScale(0, 0.04), TextColor3 = C.Primary }
	)
	local carriedLabel = Kit.title(display, { Text = "0", Size = UDim2.new(1, -12, 0.6, 0), Position = UDim2.new(0, 6, 0.38, 0) })
	local tube = Kit.new("Frame", {
		BackgroundColor3 = C.PanelDark,
		Size = UDim2.new(1, -40, 0, 30),
		Position = UDim2.fromOffset(20, 70),
		ClipsDescendants = true,
		Parent = tank,
	})
	Kit.corner(tube, 15)
	Kit.stroke(tube, 3)
	local fill = Kit.new("Frame", {
		BackgroundColor3 = Color3.new(1, 1, 1),
		Size = UDim2.fromScale(0, 1),
		Parent = tube,
	})
	Kit.corner(fill, 15)
	Kit.gradient(fill, Kit.lighten(C.Orb, 0.35), C.Orb, 0)
	local tubeIcon = Kit.text(tube, { Text = I.Orb, Size = UDim2.fromScale(1, 1) })
	tubeIcon.ZIndex = 2

	-- Settings (top right) -------------------------------------------------------
	local gear = Kit.button(screen, {
		Text = I.Settings,
		Color = C.PanelLight,
		Font = Enum.Font.GothamBold,
		Size = UDim2.fromOffset(54, 54),
		Position = UDim2.new(1, -14, 0, 60),
		AnchorPoint = Vector2.new(1, 0),
	}, function()
		handlers.openWindow("Settings")
	end)
	gear.Name = "Settings"

	-- Bottom right: surge timer + version ---------------------------------------
	local surge = Kit.panel(screen, {
		Name = "Surge",
		Size = UDim2.fromOffset(150, 70),
		Position = UDim2.new(1, -14, 1, -40),
		AnchorPoint = Vector2.new(1, 1),
		Color = C.PanelLight,
	})
	local surgeTitle =
		Kit.title(surge, { Text = W.Surge, Size = UDim2.new(1, -10, 0.45, 0), Position = UDim2.fromOffset(5, 4), TextColor3 = C.Secondary })
	local surgeTime = Kit.title(surge, { Text = "0:00", Size = UDim2.new(1, -10, 0.45, 0), Position = UDim2.new(0, 5, 0.5, 0) })
	Kit.text(screen, {
		Text = "v" .. Economy.VERSION,
		Size = UDim2.fromOffset(100, 20),
		Position = UDim2.new(1, -14, 1, -12),
		AnchorPoint = Vector2.new(1, 1),
		TextXAlignment = Enum.TextXAlignment.Right,
	})

	-- Updates ------------------------------------------------------------------------
	local lastCarried = 0
	local function refresh()
		local data = State.data
		if not data then
			return
		end
		moneyLabel.Text = State.money(data.money)
		gemsLabel.Text = I.Gem .. " " .. State.num(data.gems) .. " " .. W.Gem
		multLabel.Text = string.format('Cash <font color="#FFD23C">[%.1fx]</font>', data.moneyMult)
		counterLabel.Text = I.Unit .. " " .. State.num(data.totalObtained)
		carriedLabel.Text = State.num(data.carried)
		premiumLabel.Text = if data.premium then "+10%" else "Off"
		premiumLabel.TextColor3 = if data.premium then C.Good else C.TextDim
		friendsLabel.Text = string.format("+%d%%", math.floor(data.friendBonus * 100 + 0.5))
		promo.Visible = not data.passes.DoubleMoney

		local capacity = math.max(data.production * 30, 1)
		Kit.tween(fill, 0.25, { Size = UDim2.fromScale(math.clamp(data.carried / capacity, 0.03, 1), 1) })
		if data.carried > lastCarried then
			local s = Kit.new("UIScale", { Scale = 1.12, Parent = carriedLabel })
			Kit.tween(s, 0.25, { Scale = 1 })
			task.delay(0.3, function()
				s:Destroy()
			end)
		end
		lastCarried = data.carried
	end
	State.changed.Event:Connect(refresh)

	RunService.Heartbeat:Connect(function()
		local now = Workspace:GetServerTimeNow()
		local mult = ReplicatedStorage:GetAttribute("DepositMult") or 1
		local nextAt = ReplicatedStorage:GetAttribute("DepositNextAt") or now
		local color = if mult >= 1.2 then "#5CDC64" elseif mult < 1 then "#EB503C" else "#FFD23C"
		gaugeTitle.Text = string.format('%s: <font color="%s">%.1fx</font>', W.Multiplier, color, mult)
		gaugeNext.Text = string.format('next change in <font color="#FFD23C">%ds</font>', math.max(0, math.ceil(nextAt - now)))
		local ratio = (mult - Economy.DEPOSIT_MIN) / (Economy.DEPOSIT_MAX - Economy.DEPOSIT_MIN)
		marker.Position = UDim2.fromScale(math.clamp(ratio, 0, 1), 0.5)

		local active, left = Economy.surgeState(now)
		surgeTime.Text = Format.time(left)
		surgeTitle.Text = if active then W.Surge .. " x" .. Economy.SURGE_MULTIPLIER else "Next " .. W.Surge
		surgeTitle.TextColor3 = if active then C.Good else C.Secondary
		surgeBadge.Visible = active
		surgeBadgeLabel.Text = "x" .. Economy.SURGE_MULTIPLIER
	end)

	refresh()
end

return Hud
