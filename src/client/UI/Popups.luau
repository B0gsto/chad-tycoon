--[[
	Popups: toasts, reward reveals, the held-crate panel, confirm dialogs,
	offline earnings and floating "+X" text.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Economy = require(ReplicatedStorage.Shared.Economy)
local Format = require(ReplicatedStorage.Shared.Format)
local Net = require(ReplicatedStorage.Shared.Net)

local Kit = require(script.Parent.Kit)
local State = require(script.Parent.Parent.State)

local Theme = Kit.Theme
local C = Kit.C
local W = Theme.Words
local I = Theme.Icons

local Popups = {}

local screen: ScreenGui
local toastHolder: Frame
local sounds: any

-- Toasts ------------------------------------------------------------------------

local TONE_COLORS = {
	good = C.Good,
	bad = C.Bad,
	info = C.Text,
}

function Popups.toast(text: string, tone: string?)
	local label = Kit.title(toastHolder, {
		Text = text,
		Size = UDim2.new(1, 0, 0, 34),
		TextColor3 = TONE_COLORS[tone or "info"] or C.Text,
		TextTransparency = 1,
	})
	local labelStroke = label:FindFirstChildOfClass("UIStroke") :: UIStroke
	labelStroke.Transparency = 1
	Kit.tween(label, 0.2, { TextTransparency = 0 })
	Kit.tween(labelStroke, 0.2, { Transparency = 0 })
	if tone == "bad" then
		sounds.play("Error")
	end
	task.delay(2.6, function()
		Kit.tween(label, 0.4, { TextTransparency = 1 })
		Kit.tween(labelStroke, 0.4, { Transparency = 1 })
		task.wait(0.45)
		label:Destroy()
	end)
	-- Keep the stack short.
	local items = {}
	for _, child in toastHolder:GetChildren() do
		if child:IsA("TextLabel") then
			table.insert(items, child)
		end
	end
	if #items > 4 then
		items[1]:Destroy()
	end
end

-- Floating text -------------------------------------------------------------------

function Popups.float(text: string, color: Color3, anchor: UDim2)
	local label = Kit.title(screen, {
		Text = text,
		Size = UDim2.fromOffset(260, 44),
		Position = anchor,
		AnchorPoint = Vector2.new(0.5, 0.5),
		TextColor3 = color,
		ZIndex = 20,
	})
	local labelStroke = label:FindFirstChildOfClass("UIStroke") :: UIStroke
	Kit.tween(label, 1.1, { Position = anchor - UDim2.fromOffset(0, 70), TextTransparency = 1 })
	Kit.tween(labelStroke, 1.1, { Transparency = 1 })
	task.delay(1.2, function()
		label:Destroy()
	end)
end

-- Reward reveal queue ----------------------------------------------------------------

local rewardQueue: { { [string]: any } } = {}
local showingReward = false

local function showNextReward()
	if showingReward or #rewardQueue == 0 then
		return
	end
	showingReward = true
	local reward = table.remove(rewardQueue, 1) :: { [string]: any }
	local tier = reward.tier
	local band = Economy.tierBand(tier)
	local color = C.Rarity[band]

	local card = Kit.panel(screen, {
		Name = "Reward",
		Size = UDim2.fromOffset(360, 420),
		Position = UDim2.fromScale(0.5, 0.48),
		AnchorPoint = Vector2.new(0.5, 0.5),
		Color = C.Panel,
		StrokeThickness = 5,
	})
	card.ZIndex = 30;
	(card:FindFirstChildOfClass("UIStroke") :: UIStroke).Color = color
	local scale = Kit.new("UIScale", { Scale = 0.3, Parent = card })
	Kit.tween(scale, 0.35, { Scale = 1 }, Enum.EasingStyle.Back)

	Kit.title(card, {
		Text = if reward.new then "NEW " .. string.upper(W.Unit) .. "!" else "YOU GOT",
		Size = UDim2.new(1, -20, 0, 44),
		Position = UDim2.fromOffset(10, 10),
		TextColor3 = if reward.new then C.Primary else C.Text,
	})
	local viewport = Kit.unitViewport(card, tier, { Size = UDim2.new(1, -40, 0, 230), Position = UDim2.fromOffset(20, 56) })
	Kit.title(
		card,
		{ Text = Theme.Tiers[tier].Name, Size = UDim2.new(1, -20, 0, 40), Position = UDim2.fromOffset(10, 290), TextColor3 = color }
	)
	Kit.text(card, {
		Text = string.format("Tier %d  •  %s", tier, band),
		Size = UDim2.new(1, -20, 0, 28),
		Position = UDim2.fromOffset(10, 332),
		TextColor3 = C.TextDim,
	})
	if reward.gems and reward.gems > 0 then
		Kit.title(card, {
			Text = string.format("+%d %s %s", reward.gems, W.Gem, I.Gem),
			Size = UDim2.new(1, -20, 0, 30),
			Position = UDim2.fromOffset(10, 366),
			TextColor3 = C.Secondary,
		})
	end
	sounds.play("Reward")

	local model = viewport:FindFirstChildOfClass("Model")
	local spin = RunService.RenderStepped:Connect(function(dt)
		if model then
			model:PivotTo(model:GetPivot() * CFrame.Angles(0, dt * 1.2, 0))
		end
	end)

	local closed = false
	local function close()
		if closed then
			return
		end
		closed = true
		spin:Disconnect()
		Kit.tween(scale, 0.18, { Scale = 0 })
		task.delay(0.2, function()
			card:Destroy()
			showingReward = false
			showNextReward()
		end)
	end
	local catcher =
		Kit.new("TextButton", { BackgroundTransparency = 1, Text = "", Size = UDim2.fromScale(1, 1), ZIndex = 40, Parent = card })
	catcher.Activated:Connect(close)
	task.delay(3.2, close)
end

function Popups.reward(data: { [string]: any })
	-- Ignore anything beyond a handful queued (e.g. huge cascades).
	if #rewardQueue < 4 then
		table.insert(rewardQueue, data)
	end
	showNextReward()
end

-- Confirm dialog ---------------------------------------------------------------------------

function Popups.confirm(text: string, onYes: () -> ())
	local existing = screen:FindFirstChild("Confirm")
	if existing then
		existing:Destroy()
	end
	local box = Kit.panel(screen, {
		Name = "Confirm",
		Size = UDim2.fromOffset(420, 200),
		Position = UDim2.fromScale(0.5, 0.5),
		AnchorPoint = Vector2.new(0.5, 0.5),
		Color = C.Panel,
		StrokeThickness = 4,
	})
	box.ZIndex = 50
	Kit.title(box, { Text = text, Size = UDim2.new(1, -30, 0, 90), Position = UDim2.fromOffset(15, 12) })
	Kit.button(box, { Text = "Yes", Color = C.Good, Size = UDim2.new(0.5, -22, 0, 60), Position = UDim2.new(0, 15, 1, -74) }, function()
		box:Destroy()
		onYes()
	end)
	Kit.button(box, { Text = "No", Color = C.Bad, Size = UDim2.new(0.5, -22, 0, 60), Position = UDim2.new(0.5, 7, 1, -74) }, function()
		box:Destroy()
	end)
end

-- Offline earnings ---------------------------------------------------------------------------

function Popups.offline(data: { [string]: any })
	local box = Kit.panel(screen, {
		Name = "Offline",
		Size = UDim2.fromOffset(460, 260),
		Position = UDim2.fromScale(0.5, 0.5),
		AnchorPoint = Vector2.new(0.5, 0.5),
		Color = C.Panel,
		StrokeThickness = 4,
	})
	box.ZIndex = 45
	Kit.title(box, { Text = "WELCOME BACK!", Size = UDim2.new(1, -20, 0, 46), Position = UDim2.fromOffset(10, 10), TextColor3 = C.Primary })
	Kit.text(box, {
		Text = string.format("Your %s kept grinding for %s.", W.Units, Format.time(data.seconds)),
		Size = UDim2.new(1, -30, 0, 30),
		Position = UDim2.fromOffset(15, 62),
	})
	Kit.title(box, {
		Text = string.format("%s %s  →  %s", I.Orb, Format.short(data.orbs), Format.money(data.cash)),
		Size = UDim2.new(1, -30, 0, 44),
		Position = UDim2.fromOffset(15, 100),
		TextColor3 = C.Good,
	})
	Kit.text(box, {
		Text = "Cash is waiting on your Collect pad. Unprocessed " .. W.Orb .. " stays in the converter.",
		Size = UDim2.new(1, -30, 0, 26),
		Position = UDim2.fromOffset(15, 148),
		TextColor3 = C.TextDim,
	})
	Kit.button(box, { Text = "Let's go!", Color = C.Good, Size = UDim2.new(1, -30, 0, 56), Position = UDim2.new(0, 15, 1, -68) }, function()
		box:Destroy()
	end)
end

-- Held crate panel -----------------------------------------------------------------------------

local function buildChestPanel()
	local action = Net.event("Action")
	local panel = Kit.panel(screen, {
		Name = "ChestPanel",
		Size = UDim2.fromOffset(330, 430),
		Position = UDim2.new(1, -14, 0.5, 20),
		AnchorPoint = Vector2.new(1, 0.5),
		Color = C.Panel,
		Visible = false,
		StrokeThickness = 4,
	})
	local title = Kit.title(panel, { Text = "", Size = UDim2.new(1, -20, 0, 44), Position = UDim2.fromOffset(10, 8) })
	local icon = Kit.text(panel, { Text = I.Chest, Size = UDim2.new(1, 0, 0, 90), Position = UDim2.fromOffset(0, 52) })
	local odds = Kit.new(
		"Frame",
		{ BackgroundTransparency = 1, Size = UDim2.new(1, -24, 0, 110), Position = UDim2.fromOffset(12, 146), Parent = panel }
	)
	Kit.new("UIListLayout", { Padding = UDim.new(0, 2), SortOrder = Enum.SortOrder.LayoutOrder, Parent = odds })
	local priceRow = Kit.panel(
		panel,
		{ Color = C.PanelLight, Size = UDim2.new(1, -24, 0, 44), Position = UDim2.fromOffset(12, 262), Radius = 10, StrokeThickness = 2 }
	)
	Kit.title(priceRow, {
		Text = "Unlock Price",
		Size = UDim2.new(0.55, -8, 1, -10),
		Position = UDim2.fromOffset(8, 5),
		TextXAlignment = Enum.TextXAlignment.Left,
	})
	local priceLabel = Kit.title(priceRow, {
		Text = "",
		Size = UDim2.new(0.45, -8, 1, -10),
		Position = UDim2.new(0.55, 0, 0, 5),
		TextXAlignment = Enum.TextXAlignment.Right,
		TextColor3 = C.Good,
	})

	local method = "money"
	local unlockButton = Kit.button(
		panel,
		{ Text = "Unlock!", Color = C.Good, Size = UDim2.new(1, -24, 0, 54), Position = UDim2.fromOffset(12, 314) },
		function()
			action:FireServer({ action = "UnlockChest", method = method })
		end
	)
	Kit.button(
		panel,
		{ Text = "🗑 Discard", Color = C.Bad, Size = UDim2.new(0.5, -18, 0, 44), Position = UDim2.fromOffset(12, 374) },
		function()
			action:FireServer({ action = "DiscardChest" })
		end
	)
	Kit.text(panel, {
		Text = "or carry it to a " .. W.Unlocker .. " to open it free",
		Size = UDim2.new(0.5, -12, 0, 44),
		Position = UDim2.new(0.5, 0, 0, 374),
		TextColor3 = C.TextDim,
	})

	local shownFor = ""
	State.changed.Event:Connect(function(data)
		local rarity = data.heldChest
		panel.Visible = rarity ~= ""
		if rarity == "" then
			shownFor = ""
			return
		end
		local color = C.Rarity[rarity]
		local key = rarity .. ":" .. data.highestTier
		if key ~= shownFor then
			shownFor = key
			title.Text = rarity .. " " .. W.Chest
			title.TextColor3 = color
			icon.TextColor3 = color;
			(panel:FindFirstChildOfClass("UIStroke") :: UIStroke).Color = color
			for _, child in odds:GetChildren() do
				if child:IsA("Frame") then
					child:Destroy()
				end
			end
			for order, entry in Economy.chestOdds(rarity, data.highestTier) do
				local row =
					Kit.new("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 34), LayoutOrder = order, Parent = odds })
				local band = Economy.tierBand(entry.tier)
				Kit.title(row, { Text = "T" .. entry.tier, Size = UDim2.new(0.18, 0, 1, 0), TextXAlignment = Enum.TextXAlignment.Left })
				Kit.title(row, {
					Text = Theme.Tiers[entry.tier].Name,
					Size = UDim2.new(0.58, 0, 1, 0),
					Position = UDim2.fromScale(0.18, 0),
					TextXAlignment = Enum.TextXAlignment.Left,
					TextColor3 = C.Rarity[band],
				})
				Kit.title(row, {
					Text = entry.chance .. "%",
					Size = UDim2.new(0.24, 0, 1, 0),
					Position = UDim2.fromScale(0.76, 0),
					TextXAlignment = Enum.TextXAlignment.Right,
				})
			end
		end
		local moneyPrice = Economy.chestMoneyPrice(rarity, data.highestTier)
		local gemPrice = Economy.CHEST_INFO[rarity].gemPrice
		if data.money >= moneyPrice then
			method = "money"
			priceLabel.Text = State.money(moneyPrice)
			priceLabel.TextColor3 = C.Good
			Kit.setButton(unlockButton, "🔓 Unlock!", C.Good)
		else
			method = "gems"
			priceLabel.Text = State.money(moneyPrice)
			priceLabel.TextColor3 = C.Bad
			Kit.setButton(
				unlockButton,
				string.format("🔓 Unlock  %s %d", I.Gem, gemPrice),
				if data.gems >= gemPrice then C.Secondary else C.PadDisabled
			)
		end
	end)
end

function Popups.build(screenGui: ScreenGui, soundModule: any)
	screen = screenGui
	sounds = soundModule
	toastHolder = Kit.new("Frame", {
		Name = "Toasts",
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(640, 200),
		Position = UDim2.new(0.5, 0, 0, 140),
		AnchorPoint = Vector2.new(0.5, 0),
		Parent = screen,
	})
	Kit.new("UIListLayout", {
		Padding = UDim.new(0, 2),
		HorizontalAlignment = Enum.HorizontalAlignment.Center,
		SortOrder = Enum.SortOrder.LayoutOrder,
		Parent = toastHolder,
	})
	buildChestPanel()
end

return Popups
