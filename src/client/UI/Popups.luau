--[[
	Popups: toasts, reward reveals, the held-crate panel, confirm dialogs,
	offline earnings and floating "+X" text.

	Z order (ScreenGui uses Sibling ZIndex):
	  floats 20, toasts 25, reward 30-31, offline 44-45, confirm 49-50
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
local T = Kit.TEXT
local W = Theme.Words
local I = Theme.Icons

local Popups = {}

local screen: ScreenGui
local toastHolder: Frame
local sounds: any

local TOAST_Y = 146

-- Toasts ------------------------------------------------------------------------

local TONES = {
	good = { color = C.Good, icon = "✔" },
	bad = { color = C.Bad, icon = "!" },
	info = { color = C.Primary, icon = "i" },
}

local toastCount = 0

function Popups.toast(text: string, tone: string?)
	local style = TONES[tone or "info"] or TONES.info
	toastCount += 1
	local group = Kit.new("CanvasGroup", {
		Name = "Toast",
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(500, 48),
		LayoutOrder = -toastCount,
		GroupTransparency = 1,
		Parent = toastHolder,
	})
	local card = Kit.panel(group, {
		Name = "Card",
		Color = C.Panel,
		StrokeColor = style.color,
		Size = UDim2.new(1, -8, 1, -8),
		Position = UDim2.fromOffset(4, 4),
		Radius = 25,
	})
	local chip = Kit.new("Frame", {
		Name = "Icon",
		BackgroundColor3 = style.color,
		Size = UDim2.fromOffset(32, 32),
		Position = UDim2.new(0, 6, 0.5, 0),
		AnchorPoint = Vector2.new(0, 0.5),
		Parent = card,
	})
	Kit.round(chip)
	Kit.stroke(chip, 2)
	Kit.title(
		chip,
		{ Text = style.icon, TextSize = 20, Size = UDim2.fromScale(1, 1), Position = UDim2.fromOffset(0, 1), StrokeThickness = 1.5 }
	)
	Kit.text(card, {
		Name = "Text",
		Text = text,
		Font = Theme.Fonts.Title,
		TextScaled = true,
		MaxTextSize = 18,
		Size = UDim2.new(1, -60, 1, -8),
		Position = UDim2.fromOffset(46, 4),
		TextXAlignment = Enum.TextXAlignment.Left,
		StrokeThickness = 1.5,
	})
	local scale = Kit.new("UIScale", { Scale = 0.85, Parent = group })
	Kit.tween(group, 0.2, { GroupTransparency = 0 })
	Kit.tween(scale, 0.25, { Scale = 1 }, Enum.EasingStyle.Back)
	if tone == "bad" then
		sounds.play("Error")
	else
		sounds.play("Toast")
	end
	task.delay(3, function()
		Kit.tween(group, 0.35, { GroupTransparency = 1 })
		Kit.tween(scale, 0.35, { Scale = 0.9 })
		task.wait(0.4)
		group:Destroy()
	end)
	-- Keep the stack short (newest on top).
	local items = {}
	for _, child in toastHolder:GetChildren() do
		if child:IsA("CanvasGroup") then
			table.insert(items, child)
		end
	end
	table.sort(items, function(a, b)
		return a.LayoutOrder > b.LayoutOrder
	end)
	while #items > 4 do
		(table.remove(items, 1) :: Instance):Destroy()
	end
end

-- Floating text -------------------------------------------------------------------

function Popups.float(text: string, color: Color3, anchor: UDim2)
	local label = Kit.title(screen, {
		Name = "Float",
		Text = text,
		TextSize = 30,
		TextWrapped = false,
		Size = UDim2.fromOffset(300, 40),
		Position = anchor,
		AnchorPoint = Vector2.new(0.5, 0.5),
		TextColor3 = color,
		ZIndex = 20,
		StrokeThickness = 3,
	})
	local labelStroke = label:FindFirstChildOfClass("UIStroke") :: UIStroke
	local pop = Kit.new("UIScale", { Scale = 0.5, Parent = label })
	Kit.tween(pop, 0.25, { Scale = 1 }, Enum.EasingStyle.Back)
	local drift = UDim2.fromOffset(math.random(-30, 30), -80)
	Kit.tween(label, 1.2, { Position = anchor + drift, TextTransparency = 1 }, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
	Kit.tween(labelStroke, 1.2, { Transparency = 1 }, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
	task.delay(1.25, function()
		label:Destroy()
	end)
end

-- Shared modal pieces ------------------------------------------------------------------

local function modal(name: string, size: Vector2, zindex: number, accent: Color3?, onBackdrop: (() -> ())?): (Frame, () -> ())
	local dim = Kit.backdrop(screen, zindex - 1)
	dim.Name = name .. "Backdrop"
	Kit.fadeBackdrop(dim, true, 0.5)
	local box = Kit.panel(screen, {
		Name = name,
		Size = UDim2.fromOffset(size.X, size.Y),
		Position = UDim2.fromScale(0.5, 0.5),
		AnchorPoint = Vector2.new(0.5, 0.5),
		Color = C.Panel,
		StrokeColor = accent,
		StrokeThickness = 4,
		Radius = Kit.RADIUS.XL,
		ZIndex = zindex,
	})
	local scale = Kit.new("UIScale", { Scale = 0.8, Parent = box })
	Kit.tween(scale, 0.25, { Scale = 1 }, Enum.EasingStyle.Back)
	local closed = false
	local function close()
		if closed then
			return
		end
		closed = true
		Kit.fadeBackdrop(dim, false)
		Kit.tween(scale, 0.12, { Scale = 0.85 }, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
		task.delay(0.12, function()
			box:Destroy()
		end)
		task.delay(0.3, function()
			dim:Destroy()
		end)
	end
	dim.Activated:Connect(function()
		if onBackdrop then
			onBackdrop()
		end
		close()
	end)
	return box, close
end

local function medallion(parent: Instance, icon: string, color: Color3, size: number, position: UDim2)
	local medal = Kit.new("Frame", {
		Name = "Medal",
		BackgroundColor3 = Color3.new(1, 1, 1),
		Size = UDim2.fromOffset(size, size),
		Position = position,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Parent = parent,
	})
	Kit.round(medal)
	Kit.stroke(medal, 4)
	Kit.gradient(medal, Kit.lighten(color, 0.45), Kit.darken(color, 0.1))
	Kit.text(medal, { Text = icon, TextSize = math.floor(size * 0.55), Size = UDim2.fromScale(1, 1), StrokeThickness = 0 })
	return medal
end

-- Light rays: thin rotated bars behind something celebratory.
function Popups.rays(parent: Instance, color: Color3, size: number, position: UDim2, zindex: number?): Frame
	local holder = Kit.new("Frame", {
		Name = "Rays",
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(size, size),
		Position = position,
		AnchorPoint = Vector2.new(0.5, 0.5),
		ZIndex = zindex or 1,
		Parent = parent,
	})
	for i = 0, 5 do
		local ray = Kit.new("Frame", {
			Name = "Ray",
			BackgroundColor3 = color,
			BackgroundTransparency = 0.86,
			Size = UDim2.new(0, 30, 1, 0),
			Position = UDim2.fromScale(0.5, 0.5),
			AnchorPoint = Vector2.new(0.5, 0.5),
			Rotation = i * 30,
			ZIndex = zindex or 1,
			Parent = holder,
		})
		Kit.round(ray)
	end
	local spin: RBXScriptConnection
	spin = RunService.RenderStepped:Connect(function(dt)
		if not holder.Parent then
			spin:Disconnect()
			return
		end
		holder.Rotation = (holder.Rotation + dt * 25) % 360
	end)
	return holder
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

	local holder = Kit.new("Frame", {
		Name = "Reward",
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(380, 470),
		Position = UDim2.fromScale(0.5, 0.5),
		AnchorPoint = Vector2.new(0.5, 0.5),
		ZIndex = 30,
		Parent = screen,
	})
	Popups.rays(holder, color, 640, UDim2.new(0.5, 0, 0, 190), 30)
	local card = Kit.panel(holder, {
		Name = "Card",
		Size = UDim2.new(1, 0, 1, -24),
		Position = UDim2.fromOffset(0, 24),
		Color = Kit.darken(color, 0.72),
		StrokeColor = color,
		StrokeThickness = 5,
		Radius = Kit.RADIUS.XL,
		ZIndex = 31,
	})
	local scale = Kit.new("UIScale", { Scale = 0.3, Parent = holder })
	Kit.tween(scale, 0.4, { Scale = 1 }, Enum.EasingStyle.Back)

	local banner = Kit.pill(holder, {
		Name = "Banner",
		Text = if reward.new then "NEW " .. string.upper(W.Unit) .. "!" else "YOU GOT",
		Color = if reward.new then C.Primary else C.PanelLight,
		TextColor = C.Text,
		TextSize = 28,
		Size = UDim2.fromOffset(250, 48),
		Position = UDim2.new(0.5, 0, 0, 0),
		AnchorPoint = Vector2.new(0.5, 0),
		ZIndex = 33,
	})
	banner.Rotation = -2
	local viewport = Kit.unitViewport(card, tier, { Size = UDim2.new(1, -40, 0, 230), Position = UDim2.fromOffset(20, 34) })
	Kit.title(card, {
		Text = Theme.Tiers[tier].Name,
		TextSize = 34,
		TextScaled = true,
		MaxTextSize = 34,
		Size = UDim2.new(1, -24, 0, 42),
		Position = UDim2.fromOffset(12, 268),
		TextColor3 = Kit.lighten(color, 0.15),
		StrokeThickness = 3,
	})
	Kit.pill(card, {
		Text = string.format("TIER %d  •  %s", tier, string.upper(band)),
		Color = Kit.darken(color, 0.35),
		TextSize = T.Small,
		Size = UDim2.fromOffset(200, 28),
		Position = UDim2.new(0.5, 0, 0, 316),
		AnchorPoint = Vector2.new(0.5, 0),
	})
	if reward.gems and reward.gems > 0 then
		Kit.title(card, {
			Text = string.format("+%d %s %s", reward.gems, W.Gem, I.Gem),
			TextSize = T.H3,
			TextWrapped = false,
			Size = UDim2.new(1, -20, 0, 28),
			Position = UDim2.fromOffset(10, 354),
			TextColor3 = Kit.lighten(C.Secondary, 0.3),
		})
	end
	Kit.text(card, {
		Text = "tap to continue",
		TextSize = T.Tiny,
		TextWrapped = false,
		Size = UDim2.new(1, 0, 0, 18),
		Position = UDim2.new(0, 0, 1, -26),
		TextColor3 = C.TextDim,
		StrokeThickness = 1,
	})
	sounds.play(if reward.new then "Celebrate" else "Reward")

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
		Kit.tween(scale, 0.18, { Scale = 0 }, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
		task.delay(0.2, function()
			holder:Destroy()
			showingReward = false
			showNextReward()
		end)
	end
	local catcher =
		Kit.new("TextButton", { BackgroundTransparency = 1, Text = "", Size = UDim2.fromScale(1, 1), ZIndex = 40, Parent = holder })
	catcher.Activated:Connect(close)
	task.delay(3.4, close)
end

function Popups.reward(data: { [string]: any })
	-- Ignore anything beyond a handful queued (e.g. huge cascades).
	if #rewardQueue < 4 then
		table.insert(rewardQueue, data)
	end
	showNextReward()
end

-- Confirm dialog ---------------------------------------------------------------------------

function Popups.confirm(text: string, onYes: () -> (), options: { [string]: any }?)
	local opts = options or {}
	for _, name in { "Confirm", "ConfirmBackdrop" } do
		local existing = screen:FindFirstChild(name)
		if existing then
			existing:Destroy()
		end
	end
	local box, close = modal("Confirm", Vector2.new(460, 250), 50, C.Primary)
	medallion(box, opts.icon or "❓", C.Primary, 70, UDim2.new(0.5, 0, 0, 0))
	Kit.title(box, {
		Text = opts.title or "ARE YOU SURE?",
		TextSize = T.H2,
		TextWrapped = false,
		Size = UDim2.new(1, -30, 0, 32),
		Position = UDim2.fromOffset(15, 40),
		TextColor3 = C.Primary,
	})
	Kit.text(box, {
		Name = "Text",
		Text = text,
		TextSize = T.Body,
		Size = UDim2.new(1, -40, 0, 70),
		Position = UDim2.fromOffset(20, 76),
	})
	Kit.button(
		box,
		{ Text = opts.yes or "Yes", Color = C.Good, Size = UDim2.new(0.5, -24, 0, 60), Position = UDim2.new(0, 16, 1, -76) },
		function()
			close()
			onYes()
		end
	)
	Kit.button(
		box,
		{ Text = opts.no or "No", Color = C.Bad, Size = UDim2.new(0.5, -24, 0, 60), Position = UDim2.new(0.5, 8, 1, -76), Sound = "Close" },
		close
	)
end

-- Offline earnings ---------------------------------------------------------------------------

function Popups.offline(data: { [string]: any })
	local box, close = modal("Offline", Vector2.new(500, 320), 45, C.Primary)
	medallion(box, "💤", C.Secondary, 80, UDim2.new(0.5, 0, 0, 0))
	Kit.title(box, {
		Text = "WELCOME BACK!",
		TextSize = T.H1,
		TextWrapped = false,
		Size = UDim2.new(1, -20, 0, 36),
		Position = UDim2.fromOffset(10, 44),
		TextColor3 = C.Primary,
	})
	Kit.text(box, {
		Text = string.format("Your %s kept grinding for %s.", W.Units, Format.time(data.seconds)),
		TextSize = T.Body,
		Size = UDim2.new(1, -30, 0, 26),
		Position = UDim2.fromOffset(15, 82),
	})
	local well = Kit.well(box, { Size = UDim2.new(1, -40, 0, 64), Position = UDim2.fromOffset(20, 114) })
	Kit.title(well, {
		Text = string.format("%s %s", I.Orb, Format.short(data.orbs)),
		TextSize = 28,
		TextWrapped = false,
		Size = UDim2.new(0.42, 0, 1, 0),
		TextColor3 = Kit.lighten(C.Orb, 0.2),
	})
	Kit.title(well, {
		Text = "→",
		TextSize = 28,
		TextWrapped = false,
		Size = UDim2.new(0.16, 0, 1, 0),
		Position = UDim2.fromScale(0.42, 0),
		TextColor3 = C.TextDim,
	})
	Kit.title(well, {
		Text = Format.money(data.cash),
		TextSize = 32,
		TextWrapped = false,
		Size = UDim2.new(0.42, 0, 1, 0),
		Position = UDim2.fromScale(0.58, 0),
		TextColor3 = C.Good,
	})
	Kit.text(box, {
		Text = "Your cash is waiting on the Collect pad. Unprocessed " .. W.Orb .. " stays in the converter.",
		TextSize = T.Tiny,
		Size = UDim2.new(1, -40, 0, 36),
		Position = UDim2.fromOffset(20, 184),
		TextColor3 = C.TextDim,
		StrokeThickness = 1,
	})
	Kit.button(box, { Text = "Let's go!", Color = C.Good, Size = UDim2.new(1, -40, 0, 62), Position = UDim2.new(0, 20, 1, -78) }, close)
	sounds.play("Reward")
end

-- Held crate panel -----------------------------------------------------------------------------

local function buildChestPanel()
	local action = Net.event("Action")
	local panel = Kit.panel(screen, {
		Name = "ChestPanel",
		Size = UDim2.fromOffset(320, 440),
		Position = UDim2.new(1, -12, 0.5, 30),
		AnchorPoint = Vector2.new(1, 0.5),
		Color = C.Panel,
		Visible = false,
		StrokeThickness = 4,
		Radius = Kit.RADIUS.XL,
	})
	local panelScale = Kit.new("UIScale", { Parent = panel })
	local panelStroke = panel:FindFirstChildOfClass("UIStroke") :: UIStroke
	local band = Kit.new("Frame", {
		Name = "Band",
		BackgroundColor3 = Color3.new(1, 1, 1),
		Size = UDim2.new(1, -16, 0, 46),
		Position = UDim2.fromOffset(8, 8),
		Parent = panel,
	})
	Kit.corner(band, Kit.RADIUS.L)
	Kit.stroke(band, 3)
	local bandGradient = Kit.gradient(band, C.Primary, C.Primary)
	local title = Kit.title(
		band,
		{ Text = "", TextSize = T.H2, TextWrapped = false, Size = UDim2.fromScale(1, 1), Position = UDim2.fromOffset(0, 1) }
	)

	local iconGlow = Kit.new("Frame", {
		Name = "IconGlow",
		BackgroundColor3 = C.Primary,
		BackgroundTransparency = 0.6,
		Size = UDim2.fromOffset(84, 84),
		Position = UDim2.new(0.5, 0, 0, 104),
		AnchorPoint = Vector2.new(0.5, 0.5),
		Parent = panel,
	})
	Kit.round(iconGlow)
	Kit.text(
		panel,
		{ Text = I.Chest, TextSize = 58, Size = UDim2.fromOffset(100, 80), Position = UDim2.new(0.5, -50, 0, 64), StrokeThickness = 0 }
	)

	Kit.title(panel, {
		Text = "POSSIBLE " .. string.upper(W.Units),
		TextSize = T.Tiny,
		TextWrapped = false,
		Size = UDim2.new(1, -24, 0, 16),
		Position = UDim2.fromOffset(12, 148),
		TextXAlignment = Enum.TextXAlignment.Left,
		TextColor3 = C.TextDim,
		StrokeThickness = 1,
	})
	local odds = Kit.well(panel, { Name = "Odds", Size = UDim2.new(1, -24, 0, 112), Position = UDim2.fromOffset(12, 166) })
	Kit.padding(odds, 6, 8)
	Kit.list(odds, 4)

	local priceRow = Kit.new("Frame", {
		Name = "Price",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, -24, 0, 30),
		Position = UDim2.fromOffset(12, 284),
		Parent = panel,
	})
	Kit.title(priceRow, {
		Text = "UNLOCK PRICE",
		TextSize = T.Small,
		TextWrapped = false,
		Size = UDim2.new(0.5, 0, 1, 0),
		TextXAlignment = Enum.TextXAlignment.Left,
		TextColor3 = C.TextDim,
		StrokeThickness = 1.5,
	})
	local priceLabel = Kit.title(priceRow, {
		Text = "",
		TextSize = T.H3,
		TextWrapped = false,
		Size = UDim2.new(0.5, 0, 1, 0),
		Position = UDim2.fromScale(0.5, 0),
		TextXAlignment = Enum.TextXAlignment.Right,
		TextColor3 = C.Good,
	})

	local method = "money"
	local unlockButton = Kit.button(panel, {
		Name = "Unlock",
		Text = "Unlock!",
		Color = C.Good,
		Size = UDim2.new(1, -24, 0, 58),
		Position = UDim2.fromOffset(12, 318),
		TextSize = 24,
	}, function()
		action:FireServer({ action = "UnlockChest", method = method })
	end)
	Kit.button(panel, {
		Name = "Discard",
		Text = "Discard",
		Icon = "🗑",
		Color = C.Bad,
		Size = UDim2.new(0.42, -12, 0, 46),
		Position = UDim2.fromOffset(12, 382),
		TextSize = 18,
		Sound = "Close",
	}, function()
		action:FireServer({ action = "DiscardChest" })
	end)
	Kit.text(panel, {
		Text = "or carry it to a " .. W.Unlocker .. " to open it free",
		TextSize = T.Tiny,
		Size = UDim2.new(0.58, -16, 0, 42),
		Position = UDim2.new(0.42, 6, 0, 380),
		TextXAlignment = Enum.TextXAlignment.Left,
		TextColor3 = C.TextDim,
		StrokeThickness = 1,
	})

	local function fullScale(): number
		return if screen:GetAttribute("Compact") == true then 0.8 else 1
	end
	screen:GetAttributeChangedSignal("Compact"):Connect(function()
		panelScale.Scale = fullScale()
	end)
	panelScale.Scale = fullScale()

	local shownFor = ""
	State.changed.Event:Connect(function(data)
		local rarity = data.heldChest
		local wasVisible = panel.Visible
		panel.Visible = rarity ~= ""
		if rarity == "" then
			shownFor = ""
			return
		end
		if not wasVisible then
			local target = fullScale()
			panelScale.Scale = target * 0.6
			Kit.tween(panelScale, 0.25, { Scale = target }, Enum.EasingStyle.Back)
		end
		local color = C.Rarity[rarity]
		local key = rarity .. ":" .. data.highestTier
		if key ~= shownFor then
			shownFor = key
			title.Text = string.upper(rarity .. " " .. W.Chest)
			bandGradient.Color = ColorSequence.new(Kit.lighten(color, 0.2), Kit.darken(color, 0.15))
			iconGlow.BackgroundColor3 = color
			panelStroke.Color = color
			for _, child in odds:GetChildren() do
				if child:IsA("Frame") then
					child:Destroy()
				end
			end
			for order, entry in Economy.chestOdds(rarity, data.highestTier) do
				local row =
					Kit.new("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 30), LayoutOrder = order, Parent = odds })
				local tierBand = Economy.tierBand(entry.tier)
				local barBack = Kit.new("Frame", {
					BackgroundColor3 = C.Rarity[tierBand],
					BackgroundTransparency = 0.82,
					Size = UDim2.fromScale(entry.chance / 100, 1),
					Parent = row,
				})
				Kit.corner(barBack, 6)
				Kit.title(row, {
					Text = "#" .. entry.tier,
					TextSize = T.Small,
					TextWrapped = false,
					Size = UDim2.new(0, 40, 1, 0),
					Position = UDim2.fromOffset(4, 0),
					TextXAlignment = Enum.TextXAlignment.Left,
					StrokeThickness = 1.5,
				})
				Kit.title(row, {
					Text = Theme.Tiers[entry.tier].Name,
					TextSize = T.Small,
					TextWrapped = false,
					Size = UDim2.new(1, -100, 1, 0),
					Position = UDim2.fromOffset(42, 0),
					TextXAlignment = Enum.TextXAlignment.Left,
					TextColor3 = C.Rarity[tierBand],
					StrokeThickness = 1.5,
				})
				Kit.title(row, {
					Text = entry.chance .. "%",
					TextSize = T.Small,
					TextWrapped = false,
					Size = UDim2.new(0, 54, 1, 0),
					Position = UDim2.new(1, -4, 0, 0),
					AnchorPoint = Vector2.new(1, 0),
					TextXAlignment = Enum.TextXAlignment.Right,
					StrokeThickness = 1.5,
				})
			end
		end
		local moneyPrice = Economy.chestMoneyPrice(rarity, data.highestTier)
		local gemPrice = Economy.CHEST_INFO[rarity].gemPrice
		priceLabel.Text = State.money(moneyPrice)
		if data.money >= moneyPrice then
			method = "money"
			priceLabel.TextColor3 = C.Good
			Kit.setEnabled(unlockButton, true)
			Kit.setButton(unlockButton, "🔓 Unlock!", C.Good)
		else
			method = "gems"
			priceLabel.TextColor3 = C.Bad
			Kit.setEnabled(unlockButton, data.gems >= gemPrice)
			Kit.setButton(unlockButton, string.format("🔓 Unlock  %s %d", I.Gem, gemPrice), C.Secondary)
		end
	end)
end

function Popups.build(screenGui: ScreenGui, soundModule: any)
	screen = screenGui
	sounds = soundModule
	toastHolder = Kit.new("Frame", {
		Name = "Toasts",
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(560, 230),
		Position = UDim2.new(0.5, 0, 0, TOAST_Y),
		AnchorPoint = Vector2.new(0.5, 0),
		ZIndex = 25,
		Parent = screen,
	})
	Kit.list(toastHolder, 2, false, Enum.HorizontalAlignment.Center)
	buildChestPanel()
end

return Popups
