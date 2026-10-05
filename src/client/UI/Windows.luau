--[[
	Windows: Shop, Index, Ranking and Settings.

	Only one is open at a time. A dimmed backdrop sits behind the open window;
	clicking it, the X button, Escape or the gamepad B button closes it.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

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

local Windows = {}

local windows: { [string]: Kit.Window } = {}
local backdrop: TextButton
Windows.changed = Instance.new("BindableEvent")

local function anyOpen(): boolean
	for _, window in windows do
		if window.isOpen() then
			return true
		end
	end
	return false
end
Windows.isAnyOpen = anyOpen

function Windows.open(name: string)
	for key, window in windows do
		window.setOpen(key == name and not window.isOpen())
	end
	Kit.fadeBackdrop(backdrop, anyOpen())
	Windows.changed:Fire()
end

function Windows.closeAll()
	for _, window in windows do
		window.setOpen(false)
	end
	if backdrop then
		Kit.fadeBackdrop(backdrop, false)
	end
	Windows.changed:Fire()
end

local function register(name: string, window: Kit.Window)
	windows[name] = window
	window.onClose.Event:Connect(function()
		Kit.fadeBackdrop(backdrop, anyOpen())
		Windows.changed:Fire()
	end)
end

local function clearChildren(parent: Instance, className: string?)
	for _, child in parent:GetChildren() do
		if child:IsA(className or "GuiObject") then
			child:Destroy()
		end
	end
end

-- Shop ------------------------------------------------------------------------------

local PASS_ICONS = {
	AutoLoot = "🧲",
	AutoCash = "🏦",
	DoubleAura = I.Orb,
	DoubleMoney = "💰",
	PremiumUnlocker = "🔓",
}

local function ribbon(parent: Instance, text: string, color: Color3)
	return Kit.pill(parent, {
		Name = "Ribbon",
		Text = text,
		Color = color,
		TextSize = T.Tiny,
		Size = UDim2.fromOffset(0, 24),
		AutomaticSize = Enum.AutomaticSize.X,
		Position = UDim2.new(1, 8, 0, -10),
		AnchorPoint = Vector2.new(1, 0),
		Rotation = 6,
		ZIndex = 4,
	})
end

local function buildShop(screen: ScreenGui)
	local window = Kit.window(screen, "Shop", "Shop", I.Shop, C.Window.Shop, Vector2.new(860, 540))
	register("Shop", window)
	local action = Net.event("Action")

	-- Tabs.
	local tabBar = Kit.new("Frame", {
		Name = "Tabs",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 50),
		Parent = window.content,
	})
	Kit.list(tabBar, 10, true)
	local pages: { [string]: ScrollingFrame } = {}
	local tabButtons: { [string]: TextButton } = {}
	local TABS = {
		{ key = "Passes", text = "Passes", icon = I.Premium },
		{ key = "Cash", text = "Cash", icon = "💵" },
		{ key = "Gems", text = W.Gem, icon = I.Gem },
	}
	local selected = "Passes"
	local function selectTab(key: string)
		selected = key
		for name, page in pages do
			page.Visible = name == key
		end
		for name, button in tabButtons do
			Kit.setButton(button, nil, if name == key then C.Window.Shop else C.PanelLight)
		end
	end
	for order, tab in TABS do
		tabButtons[tab.key] = Kit.button(tabBar, {
			Name = tab.key,
			Icon = tab.icon,
			Text = tab.text,
			Color = C.PanelLight,
			Size = UDim2.fromOffset(170, 46),
			LayoutOrder = order,
			TextSize = 22,
			Depth = 5,
		}, function()
			selectTab(tab.key)
		end)
	end

	local function page(key: string): ScrollingFrame
		local scroll = Kit.scrolling(window.content, { Name = key, Size = UDim2.new(1, 0, 1, -62), Position = UDim2.fromOffset(0, 62) })
		Kit.new("UIPadding", {
			PaddingTop = UDim.new(0, 12),
			PaddingLeft = UDim.new(0, 6),
			PaddingRight = UDim.new(0, 14),
			PaddingBottom = UDim.new(0, 10),
			Parent = scroll,
		})
		pages[key] = scroll
		return scroll
	end

	-- Passes: 3-wide cards.
	local passPage = page("Passes")
	Kit.new("UIGridLayout", {
		CellSize = UDim2.new(1 / 3, -10, 0, 214),
		CellPadding = UDim2.fromOffset(14, 16),
		SortOrder = Enum.SortOrder.LayoutOrder,
		Parent = passPage,
	})
	local passCards: { [string]: { button: TextButton, tag: TextLabel? } } = {}
	for order, name in Theme.Monetization.PassOrder do
		local pass = Theme.Monetization.Passes[name]
		local card = Kit.panel(passPage, { Name = name, Color = Kit.darken(pass.Color, 0.55), LayoutOrder = order, Radius = Kit.RADIUS.L })
		local band = Kit.new("Frame", {
			Name = "Band",
			BackgroundColor3 = Color3.new(1, 1, 1),
			Size = UDim2.new(1, -12, 0, 44),
			Position = UDim2.fromOffset(6, 6),
			Parent = card,
		})
		Kit.corner(band, Kit.RADIUS.M)
		Kit.gradient(band, Kit.lighten(pass.Color, 0.15), Kit.darken(pass.Color, 0.1))
		Kit.title(
			band,
			{ Text = pass.Title, TextSize = T.H2, TextWrapped = false, Size = UDim2.fromScale(1, 1), Position = UDim2.fromOffset(0, 1) }
		)
		Kit.text(card, {
			Name = "Icon",
			Text = PASS_ICONS[name] or I.Premium,
			TextSize = 42,
			Size = UDim2.fromOffset(60, 70),
			Position = UDim2.fromOffset(8, 58),
			StrokeThickness = 0,
		})
		Kit.text(card, {
			Name = "Desc",
			Text = pass.Desc,
			TextSize = T.Body,
			Size = UDim2.new(1, -80, 0, 74),
			Position = UDim2.fromOffset(70, 56),
			TextXAlignment = Enum.TextXAlignment.Left,
			TextColor3 = Kit.lighten(pass.Color, 0.7),
		})
		local button = Kit.button(card, {
			Name = "Buy",
			Text = "R$ " .. pass.Price,
			Color = C.Good,
			Size = UDim2.new(1, -24, 0, 56),
			Position = UDim2.new(0, 12, 1, -66),
			TextSize = 26,
		}, function()
			action:FireServer({ action = "PromptPass", name = name })
		end)
		local tag = if name == "DoubleMoney" then ribbon(card, "🔥 POPULAR", C.Accent) else nil
		passCards[name] = { button = button, tag = tag }
	end

	-- Cash packs: two columns of rows.
	local cashPage = page("Cash")
	Kit.new("UIGridLayout", {
		CellSize = UDim2.new(0.5, -8, 0, 100),
		CellPadding = UDim2.fromOffset(14, 16),
		SortOrder = Enum.SortOrder.LayoutOrder,
		Parent = cashPage,
	})
	local moneyLabels: { TextLabel } = {}
	local packCount = #Theme.Monetization.MoneyPacks
	for index, pack in Theme.Monetization.MoneyPacks do
		local row = Kit.panel(cashPage, { Name = "Pack" .. index, Color = C.PanelLight, LayoutOrder = index, Radius = Kit.RADIUS.L })
		local stackIcon = string.rep("💵", math.clamp(math.ceil(index / 2), 1, 3))
		Kit.text(row, {
			Text = stackIcon,
			TextSize = 26,
			TextWrapped = false,
			Size = UDim2.fromOffset(110, 30),
			Position = UDim2.fromOffset(14, 10),
			TextXAlignment = Enum.TextXAlignment.Left,
			StrokeThickness = 0,
		})
		moneyLabels[index] = Kit.title(row, {
			Name = "Amount",
			Text = "$0",
			TextSize = 30,
			TextWrapped = false,
			Size = UDim2.new(0.6, -14, 0, 34),
			Position = UDim2.fromOffset(14, 40),
			TextXAlignment = Enum.TextXAlignment.Left,
			TextColor3 = C.Good,
		})
		Kit.text(row, {
			Text = string.format("about %s of income", Format.time(pack.Seconds)),
			TextSize = T.Tiny,
			TextWrapped = false,
			Size = UDim2.new(0.6, -14, 0, 16),
			Position = UDim2.fromOffset(15, 74),
			TextXAlignment = Enum.TextXAlignment.Left,
			TextColor3 = C.TextDim,
			StrokeThickness = 1,
		})
		Kit.button(row, {
			Name = "Buy",
			Text = "R$ " .. pack.Price,
			Color = C.Good,
			Size = UDim2.new(0.4, -12, 0, 60),
			Position = UDim2.new(1, -12, 0.5, 0),
			AnchorPoint = Vector2.new(1, 0.5),
			TextSize = 24,
		}, function()
			action:FireServer({ action = "PromptProduct", kind = "Money", index = index })
		end)
		if index == packCount then
			ribbon(row, "★ BEST VALUE", C.Primary)
		end
	end

	-- Premium currency packs: three cards.
	local gemPage = page("Gems")
	Kit.list(gemPage, 18)
	local gemGrid = Kit.new("Frame", {
		Name = "Cards",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 230),
		LayoutOrder = 1,
		Parent = gemPage,
	})
	Kit.new("UIGridLayout", {
		CellSize = UDim2.new(1 / 3, -10, 0, 230),
		CellPadding = UDim2.fromOffset(14, 16),
		SortOrder = Enum.SortOrder.LayoutOrder,
		Parent = gemGrid,
	})
	local gemCount = #Theme.Monetization.GemPacks
	for index, pack in Theme.Monetization.GemPacks do
		local card = Kit.panel(
			gemGrid,
			{ Name = "Gems" .. index, Color = Kit.darken(C.Secondary, 0.45), LayoutOrder = index, Radius = Kit.RADIUS.L }
		)
		local glow = Kit.new("Frame", {
			Name = "Glow",
			BackgroundColor3 = C.Secondary,
			BackgroundTransparency = 0.6,
			Size = UDim2.fromOffset(96, 96),
			Position = UDim2.new(0.5, 0, 0, 62),
			AnchorPoint = Vector2.new(0.5, 0.5),
			Parent = card,
		})
		Kit.round(glow)
		Kit.text(card, {
			Text = string.rep(I.Gem, index),
			TextSize = 38 - index * 4,
			TextWrapped = false,
			Size = UDim2.new(1, 0, 0, 70),
			Position = UDim2.fromOffset(0, 26),
			StrokeThickness = 0,
		})
		Kit.title(card, {
			Text = "+" .. Format.commas(pack.Amount),
			TextSize = 34,
			TextWrapped = false,
			Size = UDim2.new(1, -16, 0, 38),
			Position = UDim2.fromOffset(8, 100),
			TextColor3 = Kit.lighten(C.Secondary, 0.35),
		})
		Kit.title(card, {
			Text = string.upper(W.Gem),
			TextSize = T.Small,
			TextWrapped = false,
			Size = UDim2.new(1, -16, 0, 18),
			Position = UDim2.fromOffset(8, 136),
			TextColor3 = C.TextDim,
			StrokeThickness = 1.5,
		})
		Kit.button(card, {
			Name = "Buy",
			Text = "R$ " .. pack.Price,
			Color = C.Good,
			Size = UDim2.new(1, -24, 0, 56),
			Position = UDim2.new(0, 12, 1, -66),
			TextSize = 26,
		}, function()
			action:FireServer({ action = "PromptProduct", kind = "Gems", index = index })
		end)
		if index == gemCount then
			ribbon(card, "★ BEST VALUE", C.Primary)
		elseif index == 2 then
			ribbon(card, "🔥 POPULAR", C.Accent)
		end
	end
	local gemInfo = Kit.well(gemPage, { Name = "Info", Size = UDim2.new(1, 0, 0, 56), LayoutOrder = 99 })
	Kit.text(gemInfo, {
		Text = string.format(
			"%s %s unlock %ss instantly and finish %s timers early. You also earn them from new discoveries and free rewards.",
			I.Gem,
			W.Gem,
			string.lower(W.Chest),
			W.Unlocker
		),
		TextSize = T.Small,
		Size = UDim2.new(1, -24, 1, 0),
		Position = UDim2.fromOffset(12, 0),
		TextColor3 = C.TextDim,
		StrokeThickness = 1,
	})

	selectTab(selected)

	local function refresh()
		local data = State.data
		if not data then
			return
		end
		for index, pack in Theme.Monetization.MoneyPacks do
			moneyLabels[index].Text = State.money(Economy.moneyPackAmount(data.income, pack.Seconds, pack.Min))
		end
		for name, card in passCards do
			local owned = data.passes[name] == true
			if card.tag then
				card.tag.Visible = not owned
			end
			Kit.setEnabled(card.button, not owned)
			Kit.setButton(card.button, if owned then "✔ OWNED" else "R$ " .. Theme.Monetization.Passes[name].Price)
		end
	end
	State.changed.Event:Connect(refresh)
	window.onOpen.Event:Connect(refresh)

	Windows.selectShopTab = selectTab
end

-- Index -----------------------------------------------------------------------------

local function buildIndex(screen: ScreenGui)
	local window = Kit.window(screen, "Index", "Index", I.Index, C.Window.Index, Vector2.new(880, 560))
	register("Index", window)

	local _, setProgress, progressLabel = Kit.progress(window.content, {
		Name = "Found",
		Color = C.Window.Index,
		Size = UDim2.new(0.42, 0, 0, 30),
		TextSize = T.Body,
		MinFill = 0.08,
	})

	local legend = Kit.new("Frame", {
		Name = "Legend",
		BackgroundTransparency = 1,
		Size = UDim2.new(0.58, -12, 0, 30),
		Position = UDim2.new(1, 0, 0, 0),
		AnchorPoint = Vector2.new(1, 0),
		Parent = window.content,
	})
	Kit.list(legend, 6, true, Enum.HorizontalAlignment.Right)
	for order, band in Economy.TIER_BANDS do
		Kit.pill(legend, {
			Text = band.name,
			Color = Kit.darken(C.Rarity[band.name], 0.45),
			TextColor = Kit.lighten(C.Rarity[band.name], 0.3),
			TextSize = T.Tiny,
			Size = UDim2.fromOffset(0, 24),
			AutomaticSize = Enum.AutomaticSize.X,
			LayoutOrder = order,
		})
	end

	local scroll = Kit.scrolling(window.content, { Size = UDim2.new(1, 0, 1, -42), Position = UDim2.fromOffset(0, 42) })
	Kit.new("UIPadding", {
		PaddingTop = UDim.new(0, 8),
		PaddingLeft = UDim.new(0, 4),
		PaddingRight = UDim.new(0, 14),
		PaddingBottom = UDim.new(0, 8),
		Parent = scroll,
	})
	Kit.new("UIGridLayout", {
		CellSize = UDim2.new(0.2, -12, 0, 200),
		CellPadding = UDim2.fromOffset(14, 14),
		SortOrder = Enum.SortOrder.LayoutOrder,
		Parent = scroll,
	})

	local cards: { { frame: Frame, shown: string } } = {}
	for tier = 1, Economy.MAX_TIER do
		local card = Kit.panel(scroll, { Name = "Tier" .. tier, Color = C.PanelDark, LayoutOrder = tier, Radius = Kit.RADIUS.L })
		cards[tier] = { frame = card, shown = "" }
	end

	-- Tiers discovered this session that the player hasn't looked at yet.
	local seen: { [number]: boolean } = {}
	local sessionStart: number? = nil

	local function fillCard(tier: number, discoveredAt: number, isNew: boolean)
		local entry = cards[tier]
		local key = (if discoveredAt > 0 then "known" else "unknown") .. (if isNew then "+new" else "")
		if entry.shown == key then
			return
		end
		entry.shown = key
		clearChildren(entry.frame)
		local band = Economy.tierBand(tier)
		local rarity = C.Rarity[band]
		local known = discoveredAt > 0
		local frameStroke = entry.frame:FindFirstChildOfClass("UIStroke") :: UIStroke
		frameStroke.Color = if known then rarity else C.Stroke
		local gradient = entry.frame:FindFirstChildOfClass("UIGradient") :: UIGradient
		local base = if known then Kit.darken(rarity, 0.72) else C.PanelDark
		gradient.Color = ColorSequence.new(Kit.lighten(base, 0.08), Kit.darken(base, 0.2))

		local strip = Kit.new("Frame", {
			Name = "Strip",
			BackgroundColor3 = if known then rarity else C.PanelLight,
			BackgroundTransparency = if known then 0.15 else 0,
			Size = UDim2.new(1, -10, 0, 30),
			Position = UDim2.fromOffset(5, 5),
			Parent = entry.frame,
		})
		Kit.corner(strip, Kit.RADIUS.M)
		Kit.title(strip, {
			Text = "#" .. tier,
			TextSize = T.Small,
			TextWrapped = false,
			Size = UDim2.new(0, 34, 1, 0),
			Position = UDim2.fromOffset(6, 0),
			TextXAlignment = Enum.TextXAlignment.Left,
			StrokeThickness = 1.5,
		})
		Kit.title(strip, {
			Text = if known then Theme.Tiers[tier].Name else "???",
			TextSize = T.Small,
			MaxTextSize = T.Small,
			TextScaled = true,
			Size = UDim2.new(1, -44, 1, -6),
			Position = UDim2.fromOffset(38, 3),
			TextXAlignment = Enum.TextXAlignment.Left,
			StrokeThickness = 1.5,
		})
		Kit.unitViewport(entry.frame, tier, { Size = UDim2.new(1, -16, 1, -76), Position = UDim2.fromOffset(8, 38) }, not known)
		Kit.text(entry.frame, {
			Name = "Footer",
			Text = if known then Format.date(discoveredAt) else band,
			TextSize = T.Tiny,
			TextWrapped = false,
			Size = UDim2.new(1, -16, 0, 26),
			Position = UDim2.new(0, 8, 1, -32),
			TextColor3 = if known then C.TextDim else rarity,
			StrokeThickness = 1,
		})
		if isNew then
			Kit.pill(entry.frame, {
				Name = "New",
				Text = "NEW!",
				Color = C.Bad,
				TextSize = T.Tiny,
				Size = UDim2.fromOffset(52, 22),
				Position = UDim2.new(1, 6, 0, -8),
				AnchorPoint = Vector2.new(1, 0),
				Rotation = 8,
				ZIndex = 4,
			})
		end
	end

	local function refresh()
		local data = State.data
		if not data or not window.isOpen() then
			return
		end
		if not sessionStart then
			sessionStart = State.now() - 2
		end
		local found = 0
		for tier = 1, Economy.MAX_TIER do
			local at = data.discovered[tier] or 0
			if at > 0 then
				found += 1
			end
			local isNew = at > 0 and at >= (sessionStart :: number) and not seen[tier]
			fillCard(tier, at, isNew)
		end
		progressLabel.Text = string.format("%s  %d / %d DISCOVERED", I.Unit, found, Economy.MAX_TIER)
		setProgress(found / Economy.MAX_TIER)
	end
	State.changed.Event:Connect(refresh)
	window.onOpen.Event:Connect(refresh)
	window.onClose.Event:Connect(function()
		local data = State.data
		if data then
			for tier = 1, Economy.MAX_TIER do
				if (data.discovered[tier] or 0) > 0 then
					seen[tier] = true
				end
			end
		end
	end)
	State.changed.Event:Connect(function()
		if not sessionStart then
			sessionStart = State.now() - 2
		end
	end)
end

-- Ranking -----------------------------------------------------------------------------

local MEDALS = { "🥇", "🥈", "🥉" }
local MEDAL_COLORS = {
	Color3.fromRGB(255, 205, 60),
	Color3.fromRGB(200, 210, 225),
	Color3.fromRGB(215, 135, 75),
}

local function buildRanking(screen: ScreenGui)
	local window = Kit.window(screen, "Ranking", "Ranking", I.Ranking, C.Window.Ranking, Vector2.new(780, 560))
	register("Ranking", window)
	local query = Net.func("Query")
	local action = Net.event("Action")

	-- Toolbar.
	local subtitle = Kit.text(window.content, {
		Name = "Subtitle",
		Text = "Top players by total " .. W.Units,
		TextSize = T.Small,
		TextWrapped = false,
		Size = UDim2.new(1, -340, 0, 44),
		TextXAlignment = Enum.TextXAlignment.Left,
		TextColor3 = C.TextDim,
		StrokeThickness = 1.5,
	})
	local formatButton = Kit.button(window.content, {
		Name = "Format",
		Text = "Full numbers",
		Color = C.Secondary,
		Size = UDim2.fromOffset(170, 44),
		Position = UDim2.new(1, -160, 0, 0),
		AnchorPoint = Vector2.new(1, 0),
		TextSize = 18,
		Depth = 5,
	})
	local refreshButton = Kit.button(window.content, {
		Name = "Refresh",
		Text = "↻ Refresh",
		Color = C.Window.Ranking,
		Size = UDim2.fromOffset(146, 44),
		Position = UDim2.new(1, 0, 0, 0),
		AnchorPoint = Vector2.new(1, 0),
		TextSize = 18,
		Depth = 5,
	})

	local header = Kit.new("Frame", {
		Name = "Columns",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, -14, 0, 24),
		Position = UDim2.fromOffset(0, 52),
		Parent = window.content,
	})
	local function headerText(text: string, x: number, w: number, align: Enum.TextXAlignment)
		Kit.title(header, {
			Text = text,
			TextSize = T.Small,
			TextWrapped = false,
			Size = UDim2.new(w, 0, 1, 0),
			Position = UDim2.fromScale(x, 0),
			TextXAlignment = align,
			TextColor3 = C.TextDim,
			StrokeThickness = 1.5,
		})
	end
	headerText("RANK", 0.02, 0.14, Enum.TextXAlignment.Left)
	headerText("PLAYER", 0.17, 0.5, Enum.TextXAlignment.Left)
	headerText(string.upper(W.Units), 0.62, 0.36, Enum.TextXAlignment.Right)

	local list = Kit.scrolling(window.content, { Size = UDim2.new(1, 0, 1, -150), Position = UDim2.fromOffset(0, 80) })
	Kit.new("UIPadding", { PaddingRight = UDim.new(0, 14), PaddingTop = UDim.new(0, 4), PaddingLeft = UDim.new(0, 2), Parent = list })
	Kit.list(list, 8)

	local mine = Kit.panel(window.content, {
		Name = "Mine",
		Color = Kit.darken(C.Good, 0.45),
		StrokeColor = C.Good,
		Size = UDim2.new(1, -14, 0, 54),
		Position = UDim2.new(0, 0, 1, -58),
		Radius = Kit.RADIUS.M,
	})

	local function row(parent: Instance, rank: number?, rankText: string, name: string, value: string, isMe: boolean)
		local medal = rank and MEDALS[rank]
		local color = rank and MEDAL_COLORS[rank]
		local rankChip = Kit.new("Frame", {
			Name = "Rank",
			BackgroundColor3 = color or C.PanelDark,
			Size = UDim2.fromOffset(46, 38),
			Position = UDim2.new(0.02, 0, 0.5, 0),
			AnchorPoint = Vector2.new(0, 0.5),
			Parent = parent,
		})
		Kit.corner(rankChip, Kit.RADIUS.M)
		Kit.stroke(rankChip, 2.5)
		Kit.text(rankChip, {
			Text = medal or rankText,
			Font = Theme.Fonts.Title,
			TextSize = if medal then 26 else T.Body,
			TextWrapped = false,
			Size = UDim2.fromScale(1, 1),
			StrokeThickness = if medal then 0 else 1.5,
		})
		Kit.title(parent, {
			Name = "Name",
			Text = name,
			TextSize = T.H3,
			TextWrapped = false,
			Size = UDim2.new(0.45, 0, 1, 0),
			Position = UDim2.fromScale(0.17, 0),
			TextXAlignment = Enum.TextXAlignment.Left,
			TextColor3 = if color then Kit.lighten(color, 0.2) else C.Text,
		})
		if isMe then
			Kit.pill(parent, {
				Text = "YOU",
				Color = C.Primary,
				TextColor = C.Stroke,
				TextSize = T.Tiny,
				Size = UDim2.fromOffset(46, 22),
				Position = UDim2.new(0.62, 0, 0.5, 0),
				AnchorPoint = Vector2.new(1, 0.5),
			})
		end
		Kit.title(parent, {
			Name = "Value",
			Text = value,
			TextSize = T.H3,
			TextWrapped = false,
			Size = UDim2.new(0.34, 0, 1, 0),
			Position = UDim2.new(0.98, 0, 0, 0),
			AnchorPoint = Vector2.new(1, 0),
			TextXAlignment = Enum.TextXAlignment.Right,
			TextColor3 = C.Good,
		})
	end

	local entries: { any } = {}
	local loaded = false
	local updatedAt = 0
	local function render()
		clearChildren(list)
		clearChildren(mine)
		local data = State.data
		local full = data and data.settings.fullNumbers
		local function fmt(n: number): string
			return if full then Format.commas(n) else Format.short(n)
		end
		local me = Players.LocalPlayer
		local myRank: number? = nil
		for i, entry in entries do
			local isMe = entry.userId == me.UserId
			local tint = MEDAL_COLORS[i]
			local frame = Kit.panel(list, {
				Name = "Row" .. i,
				Color = if tint then Kit.darken(tint, 0.68) elseif i % 2 == 0 then C.Panel else C.PanelLight,
				StrokeColor = if isMe then C.Primary else nil,
				Size = UDim2.new(1, 0, 0, 50),
				LayoutOrder = i,
				Radius = Kit.RADIUS.M,
				StrokeThickness = if isMe then 3 else 2.5,
			})
			row(frame, entry.rank, "#" .. entry.rank, entry.name, fmt(entry.value), isMe)
			if isMe then
				myRank = entry.rank
			end
		end
		if #entries == 0 then
			Kit.text(list, {
				Text = if loaded then "No rankings yet - be the first!" else "Loading...",
				TextSize = T.Body,
				Size = UDim2.new(1, 0, 0, 60),
				TextColor3 = C.TextDim,
			})
		end
		row(mine, nil, if myRank then "#" .. myRank else "--", me.Name, fmt(data and data.totalObtained or 0), false)
		Kit.setButton(formatButton, if full then "Short numbers" else "Full numbers")
		local updated = ""
		if loaded and updatedAt > 0 then
			local ago = math.max(0, State.now() - updatedAt)
			updated = if ago < 60
				then "  •  updated just now"
				elseif ago < 3600 then string.format("  •  updated %dm ago", ago // 60)
				else string.format("  •  updated %dh ago", ago // 3600)
		end
		subtitle.Text = "Top players by total " .. W.Units .. updated
	end

	formatButton.Activated:Connect(function()
		local data = State.data
		if data then
			action:FireServer({ action = "SetSetting", key = "fullNumbers", value = not data.settings.fullNumbers })
		end
	end)

	local fetching = false
	local lastFetch = -math.huge
	local function fetch()
		if fetching or os.clock() - lastFetch < 3 then
			return
		end
		fetching = true
		lastFetch = os.clock()
		Kit.setEnabled(refreshButton, false)
		task.spawn(function()
			local ok, result = pcall(query.InvokeServer, query, "Ranking")
			fetching = false
			Kit.setEnabled(refreshButton, true)
			if ok and type(result) == "table" then
				entries = result.entries or {}
				updatedAt = result.updatedAt or State.now()
				loaded = true
				if window.isOpen() then
					render()
				end
			end
		end)
	end
	refreshButton.Activated:Connect(fetch)

	window.onOpen.Event:Connect(function()
		render()
		fetch()
	end)
	State.changed.Event:Connect(function()
		if window.isOpen() then
			render()
		end
	end)
end

-- Settings ------------------------------------------------------------------------------

local function buildSettings(screen: ScreenGui)
	local window = Kit.window(screen, "Settings", "Settings", I.Settings, C.Window.Settings, Vector2.new(560, 446))
	register("Settings", window)
	local action = Net.event("Action")

	Kit.list(window.content, 10)

	local toggles: { { key: string, set: (boolean, boolean?) -> (), sub: TextLabel } } = {}
	local function toggle(order: number, icon: string, text: string, desc: string, key: string)
		local row = Kit.panel(window.content, {
			Name = key,
			Color = C.PanelLight,
			Size = UDim2.new(1, 0, 0, 78),
			LayoutOrder = order,
			Radius = Kit.RADIUS.L,
		})
		local medal = Kit.new("Frame", {
			BackgroundColor3 = C.PanelDark,
			Size = UDim2.fromOffset(52, 52),
			Position = UDim2.new(0, 12, 0.5, 0),
			AnchorPoint = Vector2.new(0, 0.5),
			Parent = row,
		})
		Kit.round(medal)
		Kit.text(medal, { Text = icon, TextSize = 28, Size = UDim2.fromScale(1, 1), StrokeThickness = 0 })
		Kit.title(row, {
			Text = text,
			TextSize = T.H3,
			TextWrapped = false,
			Size = UDim2.new(1, -190, 0, 28),
			Position = UDim2.fromOffset(76, 12),
			TextXAlignment = Enum.TextXAlignment.Left,
		})
		local sub = Kit.text(row, {
			Text = desc,
			TextSize = T.Tiny,
			Size = UDim2.new(1, -190, 0, 30),
			Position = UDim2.fromOffset(76, 40),
			TextXAlignment = Enum.TextXAlignment.Left,
			TextYAlignment = Enum.TextYAlignment.Top,
			TextColor3 = C.TextDim,
			StrokeThickness = 1,
		})
		local _, set = Kit.switch(row, {
			Name = "Switch",
			Position = UDim2.new(1, -16, 0.5, 0),
			AnchorPoint = Vector2.new(1, 0.5),
		}, function()
			local data = State.data
			if not data then
				return
			end
			local current = if key == "autoMerge" then data.autoMerge else data.settings[key]
			action:FireServer({ action = "SetSetting", key = key, value = not current })
		end)
		table.insert(toggles, { key = key, set = set, sub = sub })
	end
	toggle(1, "🎵", "Music", "Background music", "music")
	toggle(2, "🔊", "Sound Effects", "Clicks, pickups and rewards", "sfx")
	toggle(3, "🔢", "Full Numbers", "Show 1,234,567 instead of 1.23M", "fullNumbers")
	toggle(4, "🔀", "Auto Merge", "Merge pairs automatically", "autoMerge")

	local function refresh()
		local data = State.data
		if not data then
			return
		end
		for _, t in toggles do
			if t.key == "autoMerge" then
				if data.autoMergeOwned then
					t.set(data.autoMerge)
					t.sub.Text = "Merge pairs automatically"
				else
					t.set(false, true)
					t.sub.Text = "Unlock it on the Auto Merge pad (" .. Format.money(Economy.AUTO_MERGE_COST) .. ")"
				end
			else
				t.set(data.settings[t.key] == true)
			end
		end
	end
	State.changed.Event:Connect(refresh)
	window.onOpen.Event:Connect(refresh)
end

function Windows.build(screen: ScreenGui)
	backdrop = Kit.backdrop(screen, 9, function()
		Windows.closeAll()
	end)
	buildShop(screen)
	buildIndex(screen)
	buildRanking(screen)
	buildSettings(screen)

	UserInputService.InputBegan:Connect(function(input)
		if input.KeyCode == Enum.KeyCode.Escape or input.KeyCode == Enum.KeyCode.ButtonB then
			if anyOpen() then
				Kit.sound("Close")
				Windows.closeAll()
			end
		end
	end)
end

return Windows
