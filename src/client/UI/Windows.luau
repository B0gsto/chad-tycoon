--[[
	Windows: Shop, Index, Ranking and Settings. Only one is open at a time.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Economy = require(ReplicatedStorage.Shared.Economy)
local Format = require(ReplicatedStorage.Shared.Format)
local Net = require(ReplicatedStorage.Shared.Net)

local Kit = require(script.Parent.Kit)
local State = require(script.Parent.Parent.State)

local Theme = Kit.Theme
local C = Kit.C
local W = Theme.Words
local I = Theme.Icons

local Windows = {}

local windows: { [string]: Kit.Window } = {}

function Windows.open(name: string)
	for key, window in windows do
		window.setOpen(key == name and not window.isOpen())
	end
end

function Windows.closeAll()
	for _, window in windows do
		window.setOpen(false)
	end
end

local function sectionTitle(parent: Instance, text: string, order: number)
	local holder = Kit.new("Frame", {
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 44),
		LayoutOrder = order,
		Parent = parent,
	})
	Kit.title(
		holder,
		{ Text = text, Size = UDim2.new(1, -10, 1, -6), Position = UDim2.fromOffset(6, 3), TextXAlignment = Enum.TextXAlignment.Left }
	)
end

-- Shop ------------------------------------------------------------------------------

local function buildShop(screen: ScreenGui)
	local window = Kit.window(screen, "Shop", "Shop", I.Shop, C.Window.Shop, Vector2.new(820, 520))
	windows.Shop = window
	local action = Net.event("Action")

	local scroll = Kit.scrolling(window.content)
	Kit.new("UIListLayout", { Padding = UDim.new(0, 10), SortOrder = Enum.SortOrder.LayoutOrder, Parent = scroll })
	Kit.padding(scroll, 6)

	sectionTitle(scroll, "Game Passes  " .. I.Premium, 1)
	local passGrid = Kit.new("Frame", {
		BackgroundTransparency = 1,
		Size = UDim2.new(1, -16, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		LayoutOrder = 2,
		Parent = scroll,
	})
	Kit.new("UIGridLayout", {
		CellSize = UDim2.new(0.33, -8, 0, 200),
		CellPadding = UDim2.fromOffset(10, 10),
		SortOrder = Enum.SortOrder.LayoutOrder,
		Parent = passGrid,
	})

	local passButtons: { [string]: TextButton } = {}
	for order, name in Theme.Monetization.PassOrder do
		local pass = Theme.Monetization.Passes[name]
		local card = Kit.panel(passGrid, { Color = pass.Color, LayoutOrder = order, Radius = 14 })
		Kit.title(card, { Text = pass.Title, Size = UDim2.new(1, -16, 0, 40), Position = UDim2.fromOffset(8, 8) })
		local descBox = Kit.panel(card, {
			Color = Kit.darken(pass.Color, 0.45),
			Size = UDim2.new(1, -24, 0, 76),
			Position = UDim2.fromOffset(12, 52),
			Radius = 10,
			StrokeThickness = 2,
		})
		Kit.text(descBox, { Text = pass.Desc, Size = UDim2.new(1, -16, 1, -12), Position = UDim2.fromOffset(8, 6), TextColor3 = C.Primary })
		passButtons[name] = Kit.button(card, {
			Text = pass.Price .. " R$",
			Color = C.Good,
			Size = UDim2.new(1, -24, 0, 52),
			Position = UDim2.new(0, 12, 1, -62),
		}, function()
			action:FireServer({ action = "PromptPass", name = name })
		end)
	end

	sectionTitle(scroll, "$ Cash Packs", 3)
	local moneyGrid = Kit.new("Frame", {
		BackgroundTransparency = 1,
		Size = UDim2.new(1, -16, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		LayoutOrder = 4,
		Parent = scroll,
	})
	Kit.new("UIGridLayout", {
		CellSize = UDim2.new(0.5, -6, 0, 70),
		CellPadding = UDim2.fromOffset(10, 10),
		SortOrder = Enum.SortOrder.LayoutOrder,
		Parent = moneyGrid,
	})
	local moneyLabels: { TextLabel } = {}
	for index, pack in Theme.Monetization.MoneyPacks do
		local row = Kit.panel(moneyGrid, { Color = C.PanelLight, LayoutOrder = index, Radius = 12 })
		moneyLabels[index] = Kit.title(row, {
			Text = "$0",
			Size = UDim2.new(0.58, -10, 1, -16),
			Position = UDim2.fromOffset(12, 8),
			TextXAlignment = Enum.TextXAlignment.Left,
			TextColor3 = C.Good,
		})
		Kit.button(row, {
			Text = pack.Price .. " R$",
			Color = C.Good,
			Size = UDim2.new(0.4, -10, 1, -16),
			Position = UDim2.new(0.6, 0, 0, 8),
		}, function()
			action:FireServer({ action = "PromptProduct", kind = "Money", index = index })
		end)
	end

	sectionTitle(scroll, I.Gem .. " " .. W.Gem .. " Packs", 5)
	local gemGrid = Kit.new("Frame", {
		BackgroundTransparency = 1,
		Size = UDim2.new(1, -16, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		LayoutOrder = 6,
		Parent = scroll,
	})
	Kit.new("UIGridLayout", {
		CellSize = UDim2.new(0.33, -8, 0, 130),
		CellPadding = UDim2.fromOffset(10, 10),
		SortOrder = Enum.SortOrder.LayoutOrder,
		Parent = gemGrid,
	})
	for index, pack in Theme.Monetization.GemPacks do
		local card = Kit.panel(gemGrid, { Color = Kit.darken(C.Secondary, 0.35), LayoutOrder = index, Radius = 12 })
		Kit.title(card, {
			Text = I.Gem .. " " .. pack.Amount,
			Size = UDim2.new(1, -16, 0, 50),
			Position = UDim2.fromOffset(8, 8),
			TextColor3 = C.Primary,
		})
		Kit.button(card, {
			Text = pack.Price .. " R$",
			Color = C.Good,
			Size = UDim2.new(1, -24, 0, 50),
			Position = UDim2.new(0, 12, 1, -60),
		}, function()
			action:FireServer({ action = "PromptProduct", kind = "Gems", index = index })
		end)
	end

	local function refresh()
		local data = State.data
		if not data then
			return
		end
		for index, pack in Theme.Monetization.MoneyPacks do
			moneyLabels[index].Text = State.money(Economy.moneyPackAmount(data.income, pack.Seconds, pack.Min))
		end
		for name, button in passButtons do
			if data.passes[name] then
				Kit.setButton(button, "OWNED", C.PadDisabled)
			end
		end
	end
	State.changed.Event:Connect(refresh)
	window.onOpen.Event:Connect(refresh)
end

-- Index -----------------------------------------------------------------------------

local function buildIndex(screen: ScreenGui)
	local window = Kit.window(screen, "Index", "Index", I.Index, C.Window.Index, Vector2.new(820, 540))
	windows.Index = window

	local progress = Kit.title(window.content, {
		Text = "",
		Size = UDim2.new(1, 0, 0, 30),
		TextXAlignment = Enum.TextXAlignment.Right,
		TextColor3 = C.Primary,
	})
	local scroll = Kit.scrolling(window.content, { Size = UDim2.new(1, 0, 1, -36), Position = UDim2.fromOffset(0, 36) })
	Kit.padding(scroll, 6)
	Kit.new("UIGridLayout", {
		CellSize = UDim2.new(0.25, -12, 0, 230),
		CellPadding = UDim2.fromOffset(12, 12),
		SortOrder = Enum.SortOrder.LayoutOrder,
		Parent = scroll,
	})

	local cards: { { frame: Frame, shown: string } } = {}
	for tier = 1, Economy.MAX_TIER do
		local card = Kit.panel(scroll, { Color = C.PanelDark, LayoutOrder = tier, Radius = 12 })
		card:FindFirstChildOfClass("UIStroke").Color = C.Rarity[Economy.tierBand(tier)]
		cards[tier] = { frame = card, shown = "" }
	end

	local function fillCard(tier: number, discoveredAt: number)
		local entry = cards[tier]
		local key = if discoveredAt > 0 then "known" else "unknown"
		if entry.shown == key then
			return
		end
		entry.shown = key
		for _, child in entry.frame:GetChildren() do
			if child:IsA("GuiObject") then
				child:Destroy()
			end
		end
		local band = Economy.tierBand(tier)
		local known = discoveredAt > 0
		Kit.title(entry.frame, {
			Text = if known then Theme.Tiers[tier].Name else "???",
			Size = UDim2.new(0.68, -8, 0, 28),
			Position = UDim2.fromOffset(8, 6),
			TextXAlignment = Enum.TextXAlignment.Left,
			TextColor3 = if known then C.Rarity[band] else C.TextDim,
		})
		Kit.title(entry.frame, {
			Text = "Tier " .. tier,
			Size = UDim2.new(0.32, -8, 0, 22),
			Position = UDim2.new(0.68, 0, 0, 9),
			TextXAlignment = Enum.TextXAlignment.Right,
			TextColor3 = C.TextDim,
		})
		Kit.unitViewport(entry.frame, tier, { Size = UDim2.new(1, -16, 1, -76), Position = UDim2.fromOffset(8, 36) }, not known)
		Kit.text(entry.frame, {
			Text = if known then "Obtained: " .. Format.date(discoveredAt) else band,
			Size = UDim2.new(1, -16, 0, 26),
			Position = UDim2.new(0, 8, 1, -34),
			TextColor3 = if known then C.Primary else C.Rarity[band],
		})
	end

	local function refresh()
		local data = State.data
		if not data or not window.isOpen() then
			return
		end
		local found = 0
		for tier = 1, Economy.MAX_TIER do
			local at = data.discovered[tier] or 0
			if at > 0 then
				found += 1
			end
			fillCard(tier, at)
		end
		progress.Text = string.format("%s Discovered %d / %d", I.Unit, found, Economy.MAX_TIER)
	end
	State.changed.Event:Connect(refresh)
	window.onOpen.Event:Connect(refresh)
end

-- Ranking -----------------------------------------------------------------------------

local function buildRanking(screen: ScreenGui)
	local window = Kit.window(screen, "Ranking", "Ranking", I.Ranking, C.Window.Ranking, Vector2.new(820, 540))
	windows.Ranking = window
	local query = Net.func("Query")
	local action = Net.event("Action")

	local formatButton = Kit.button(window.frame, {
		Text = "Format (Short)",
		Color = C.Secondary,
		Size = UDim2.fromOffset(200, 42),
		Position = UDim2.new(1, -290, 0, 18),
	})

	local header = Kit.panel(window.content, { Color = C.PanelLight, Size = UDim2.new(1, 0, 0, 44), Radius = 8 })
	local function columns(parent: Instance, rank: string, name: string, value: string, color: Color3?)
		Kit.title(
			parent,
			{ Text = rank, Size = UDim2.new(0.18, 0, 1, -10), Position = UDim2.fromOffset(0, 5), TextColor3 = color or C.Text }
		)
		Kit.title(
			parent,
			{ Text = name, Size = UDim2.new(0.42, 0, 1, -10), Position = UDim2.new(0.18, 0, 0, 5), TextColor3 = color or C.Text }
		)
		Kit.title(
			parent,
			{ Text = value, Size = UDim2.new(0.38, 0, 1, -10), Position = UDim2.new(0.6, 0, 0, 5), TextColor3 = color or C.Text }
		)
	end
	columns(header, "Rank", "Username", "Total " .. W.Units)

	local list = Kit.scrolling(window.content, { Size = UDim2.new(1, 0, 1, -110), Position = UDim2.fromOffset(0, 52) })
	Kit.new("UIListLayout", { Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder, Parent = list })

	local mine =
		Kit.panel(window.content, { Color = C.Good, Size = UDim2.new(1, 0, 0, 48), Position = UDim2.new(0, 0, 1, -50), Radius = 8 })

	local entries: { any } = {}
	local function render()
		for _, child in list:GetChildren() do
			if child:IsA("GuiObject") then
				child:Destroy()
			end
		end
		for _, child in mine:GetChildren() do
			if child:IsA("TextLabel") then
				child:Destroy()
			end
		end
		local data = State.data
		local full = data and data.settings.fullNumbers
		local function fmt(n: number): string
			return if full then Format.commas(n) else Format.short(n)
		end
		local myRank = "Unranked"
		local me = Players.LocalPlayer
		for i, entry in entries do
			local row = Kit.panel(list, {
				Color = if i % 2 == 0 then C.Panel else C.PanelLight,
				Size = UDim2.new(1, -12, 0, 42),
				LayoutOrder = i,
				Radius = 8,
				StrokeThickness = 2,
			})
			local color = if i == 1
				then Color3.fromRGB(255, 210, 60)
				elseif i == 2 then Color3.fromRGB(215, 215, 230)
				elseif i == 3 then Color3.fromRGB(225, 140, 75)
				else nil
			columns(row, "#" .. entry.rank, entry.name, fmt(entry.value), color)
			if entry.userId == me.UserId then
				myRank = "#" .. entry.rank
			end
		end
		if #entries == 0 then
			Kit.text(list, { Text = "Loading...", Size = UDim2.new(1, 0, 0, 40) })
		end
		columns(mine, myRank, me.Name, fmt(data and data.totalObtained or 0))
		Kit.setButton(formatButton, if full then "Format (Full)" else "Format (Short)")
	end

	formatButton.Activated:Connect(function()
		local data = State.data
		if data then
			action:FireServer({ action = "SetSetting", key = "fullNumbers", value = not data.settings.fullNumbers })
		end
	end)

	window.onOpen.Event:Connect(function()
		render()
		task.spawn(function()
			local ok, result = pcall(query.InvokeServer, query, "Ranking")
			if ok and type(result) == "table" then
				entries = result.entries or {}
				render()
			end
		end)
	end)
	State.changed.Event:Connect(function()
		if window.isOpen() then
			render()
		end
	end)
end

-- Settings ------------------------------------------------------------------------------

local function buildSettings(screen: ScreenGui)
	local window = Kit.window(screen, "Settings", "Settings", I.Settings, C.Window.Settings, Vector2.new(520, 420))
	windows.Settings = window
	local action = Net.event("Action")

	Kit.new("UIListLayout", { Padding = UDim.new(0, 10), SortOrder = Enum.SortOrder.LayoutOrder, Parent = window.content })

	local toggles: { { key: string, button: TextButton } } = {}
	local function toggle(order: number, text: string, key: string)
		local row = Kit.panel(window.content, { Color = C.PanelLight, Size = UDim2.new(1, 0, 0, 62), LayoutOrder = order, Radius = 10 })
		Kit.title(row, {
			Text = text,
			Size = UDim2.new(0.62, -10, 1, -16),
			Position = UDim2.fromOffset(12, 8),
			TextXAlignment = Enum.TextXAlignment.Left,
		})
		local button = Kit.button(
			row,
			{ Text = "ON", Color = C.Good, Size = UDim2.new(0.32, 0, 1, -16), Position = UDim2.new(0.66, 0, 0, 8) },
			function()
				local data = State.data
				if not data then
					return
				end
				local current = if key == "autoMerge" then data.autoMerge else data.settings[key]
				action:FireServer({ action = "SetSetting", key = key, value = not current })
			end
		)
		table.insert(toggles, { key = key, button = button })
	end
	toggle(1, "Music", "music")
	toggle(2, "Sound Effects", "sfx")
	toggle(3, "Full Numbers", "fullNumbers")
	toggle(4, "Auto Merge", "autoMerge")

	local function refresh()
		local data = State.data
		if not data then
			return
		end
		for _, t in toggles do
			local value
			if t.key == "autoMerge" then
				value = data.autoMerge
				if not data.autoMergeOwned then
					Kit.setButton(t.button, "LOCKED", C.PadDisabled)
					continue
				end
			else
				value = data.settings[t.key]
			end
			Kit.setButton(t.button, if value then "ON" else "OFF", if value then C.Good else C.Bad)
		end
	end
	State.changed.Event:Connect(refresh)
	window.onOpen.Event:Connect(refresh)
end

function Windows.build(screen: ScreenGui)
	buildShop(screen)
	buildIndex(screen)
	buildRanking(screen)
	buildSettings(screen)
end

return Windows
