--[[
	Tutorial (client): the onboarding card, the guide target and the
	completion celebration. Progress itself is server-side (see
	ServerScriptService.Server.Tutorial); this only reads the State snapshot
	(tutorialStep, tutorialDone) and the "Tutorial" Notify payloads.

	The card sits at the bottom centre, just above the tank, so the world ahead
	of the player (where the guide arrow points) stays visible. It never blocks
	input except for its Skip button.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Net = require(ReplicatedStorage.Shared.Net)
local TutorialSteps = require(ReplicatedStorage.Shared.TutorialSteps)

local Kit = require(script.Parent.Kit)
local State = require(script.Parent.Parent.State)

local Theme = Kit.Theme
local C = Kit.C
local T = Kit.TEXT
local W = Theme.Words
local I = Theme.Icons
local Words = Theme.Tutorial

local Tutorial = {}

export type Deps = {
	popups: any,
	sounds: any,
	guide: any?,
	-- Glows a HUD menu button (e.g. the Index after the first merge).
	highlight: ((string, boolean) -> ())?,
}

local CARD_HEIGHT = 112

local screen: ScreenGui
local deps: Deps
local card: Frame
local cardScale: UIScale
local cardStroke: UIStroke
local iconLabel: TextLabel
local stepLabel: TextLabel
local titleLabel: TextLabel
local textLabel: TextLabel
local statusPill: TextLabel
local dots: { Frame } = {}
local shownStep = 0
local visible = false

local function guideText(target: string?): string
	if target == "Orbs" then
		return "GRAB " .. string.upper(W.Orb) .. "!"
	end
	return "STEP HERE"
end

local function setVisible(on: boolean)
	if on == visible then
		return
	end
	visible = on
	if on then
		card.Visible = true
		cardScale.Scale = 0.7
		Kit.tween(cardScale, 0.3, { Scale = 1 }, Enum.EasingStyle.Back)
	else
		Kit.tween(cardScale, 0.18, { Scale = 0 }, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
		task.delay(0.2, function()
			if not visible then
				card.Visible = false
			end
		end)
	end
end

local function render(data: { [string]: any })
	local step = TutorialSteps.clamp(data.tutorialStep)
	local active = data.tutorialDone ~= true and step <= TutorialSteps.COUNT
	setVisible(active)
	if not active then
		if deps.guide then
			deps.guide.setTutorialTarget(nil)
		end
		return
	end
	local words = Words.Steps[step]
	local target = TutorialSteps.target(step, data.units)
	local needsPair = TutorialSteps.STEPS[step].id == "merge" and target ~= "Merge"

	if step ~= shownStep then
		local advanced = shownStep > 0 and step > shownStep
		shownStep = step
		if advanced then
			cardScale.Scale = 1.08
			Kit.tween(cardScale, 0.35, { Scale = 1 }, Enum.EasingStyle.Back)
			cardStroke.Color = C.Good
			Kit.tween(cardStroke, 0.8, { Color = C.Primary })
		end
	end
	iconLabel.Text = words.Icon
	stepLabel.Text = string.format('%s  <font color="%s">STEP %d/%d</font>', Words.Title, Kit.hex(C.TextDim), step, TutorialSteps.COUNT)
	titleLabel.Text = words.Title
	textLabel.Text = if needsPair and words.Hint then words.Hint else words.Text
	for i, dot in dots do
		local done = i < step
		local current = i == step
		dot.BackgroundColor3 = if done then C.Good elseif current then C.Primary else C.PanelDark
		dot.Size = if current then UDim2.fromOffset(26, 12) else UDim2.fromOffset(12, 12)
	end

	-- Live status for the steps that depend on numbers.
	local status: string? = nil
	if step == 3 then
		status = I.Orb .. " " .. State.num(data.carried) .. " in tank"
	elseif step == 4 then
		status = if data.pending >= 1 then "💵 " .. State.money(data.pending) .. " ready" else "converting..."
	end
	statusPill.Visible = status ~= nil
	statusPill.Text = status or ""

	if deps.guide then
		deps.guide.setTutorialTarget(target, guideText(target))
	end
end

local function confetti(parent: Instance)
	local colors = { C.Primary, C.Secondary, C.Good, C.Accent, C.Orb }
	for i = 1, 26 do
		local piece = Kit.new("Frame", {
			Name = "Confetti",
			BackgroundColor3 = colors[(i % #colors) + 1],
			Size = UDim2.fromOffset(math.random(8, 14), math.random(14, 22)),
			Position = UDim2.new(math.random(), 0, 0, math.random(-60, 40)),
			Rotation = math.random(0, 360),
			ZIndex = 44,
			Parent = parent,
		})
		Kit.corner(piece, 3)
		local fall = math.random(220, 420)
		Kit.tween(piece, 1.6 + math.random() * 0.8, {
			Position = piece.Position + UDim2.fromOffset(math.random(-60, 60), fall),
			Rotation = piece.Rotation + math.random(-240, 240),
			BackgroundTransparency = 1,
		}, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
	end
end

-- "Training complete" popup with the reward.
function Tutorial.celebrate(gems: number, cash: number)
	local existing = screen:FindFirstChild("TutorialDone")
	if existing then
		existing:Destroy()
	end
	local holder = Kit.new("Frame", {
		Name = "TutorialDone",
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(470, 360),
		Position = UDim2.fromScale(0.5, 0.48),
		AnchorPoint = Vector2.new(0.5, 0.5),
		ZIndex = 40,
		Parent = screen,
	})
	deps.popups.rays(holder, C.Primary, 600, UDim2.new(0.5, 0, 0, 40), 40)
	local box = Kit.panel(holder, {
		Name = "Card",
		Size = UDim2.new(1, 0, 1, -40),
		Position = UDim2.fromOffset(0, 40),
		Color = C.Panel,
		StrokeColor = C.Primary,
		StrokeThickness = 5,
		Radius = Kit.RADIUS.XL,
		ZIndex = 41,
	})
	local scale = Kit.new("UIScale", { Scale = 0.3, Parent = holder })
	Kit.tween(scale, 0.45, { Scale = 1 }, Enum.EasingStyle.Back)

	local medal = Kit.new("Frame", {
		Name = "Medal",
		BackgroundColor3 = Color3.new(1, 1, 1),
		Size = UDim2.fromOffset(96, 96),
		Position = UDim2.new(0.5, 0, 0, 40),
		AnchorPoint = Vector2.new(0.5, 0.5),
		ZIndex = 42,
		Parent = holder,
	})
	Kit.round(medal)
	Kit.stroke(medal, 4)
	Kit.gradient(medal, Kit.lighten(C.Primary, 0.45), Kit.darken(C.Primary, 0.1))
	Kit.text(medal, { Text = "🏆", TextSize = 54, Size = UDim2.fromScale(1, 1), StrokeThickness = 0 })

	Kit.title(box, {
		Text = Words.DoneTitle,
		TextSize = T.H1,
		TextScaled = true,
		MaxTextSize = T.H1,
		Size = UDim2.new(1, -30, 0, 40),
		Position = UDim2.fromOffset(15, 58),
		TextColor3 = C.Primary,
		StrokeThickness = 3,
	})
	Kit.text(box, {
		Text = Words.DoneText,
		TextSize = T.Body,
		Size = UDim2.new(1, -40, 0, 48),
		Position = UDim2.fromOffset(20, 100),
	})
	local rewards = Kit.new("Frame", {
		Name = "Rewards",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, -40, 0, 46),
		Position = UDim2.fromOffset(20, 154),
		Parent = box,
	})
	Kit.list(rewards, 14, true, Enum.HorizontalAlignment.Center)
	Kit.pill(rewards, {
		Text = string.format("+%d %s %s", gems, W.Gem, I.Gem),
		Color = Kit.darken(C.Secondary, 0.25),
		TextSize = T.H3,
		Size = UDim2.fromOffset(0, 42),
		AutomaticSize = Enum.AutomaticSize.X,
		LayoutOrder = 1,
	})
	Kit.pill(rewards, {
		Text = "+" .. State.money(cash),
		Color = Kit.darken(C.Good, 0.35),
		TextSize = T.H3,
		Size = UDim2.fromOffset(0, 42),
		AutomaticSize = Enum.AutomaticSize.X,
		LayoutOrder = 2,
	})

	local function close()
		if not holder.Parent then
			return
		end
		Kit.tween(scale, 0.18, { Scale = 0 }, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
		task.delay(0.2, function()
			holder:Destroy()
		end)
	end
	Kit.button(box, {
		Name = "Go",
		Text = "Let's go!",
		Color = C.Good,
		Size = UDim2.new(1, -60, 0, 62),
		Position = UDim2.new(0, 30, 1, -80),
		TextSize = 28,
		ZIndex = 42,
	}, close)
	confetti(holder)
	deps.sounds.play("Celebrate")
	task.delay(9, close)
end

function Tutorial.onNotify(payload: { [string]: any })
	if payload.event == "step" then
		deps.sounds.play("Step")
	elseif payload.event == "done" then
		setVisible(false)
		Tutorial.celebrate(payload.gems or 0, payload.cash or 0)
		-- The merge just discovered a new tier: point at the Index.
		if deps.highlight then
			deps.highlight("Index", true)
		end
	elseif payload.event == "skipped" then
		setVisible(false)
	end
end

function Tutorial.build(screenGui: ScreenGui, dependencies: Deps)
	screen = screenGui
	deps = dependencies
	local action = Net.event("Action")

	card = Kit.panel(screen, {
		Name = "TutorialCard",
		Size = UDim2.fromOffset(480, CARD_HEIGHT),
		Position = UDim2.new(0.5, 0, 1, -118),
		AnchorPoint = Vector2.new(0.5, 1),
		Color = C.Panel,
		StrokeColor = C.Primary,
		StrokeThickness = 4,
		Radius = Kit.RADIUS.XL,
		Visible = false,
		ZIndex = 6,
	})
	cardStroke = card:FindFirstChildOfClass("UIStroke") :: UIStroke
	cardScale = Kit.new("UIScale", { Parent = card })

	local medal = Kit.new("Frame", {
		Name = "Medal",
		BackgroundColor3 = Color3.new(1, 1, 1),
		Size = UDim2.fromOffset(70, 70),
		Position = UDim2.new(0, 14, 0.5, -4),
		AnchorPoint = Vector2.new(0, 0.5),
		Parent = card,
	})
	Kit.round(medal)
	Kit.stroke(medal, 3)
	Kit.gradient(medal, Kit.lighten(C.Primary, 0.45), Kit.darken(C.Primary, 0.1))
	iconLabel = Kit.text(medal, { Name = "Icon", Text = "", TextSize = 36, Size = UDim2.fromScale(1, 1), StrokeThickness = 0 })

	stepLabel = Kit.title(card, {
		Name = "Step",
		Text = "",
		RichText = true,
		TextSize = T.Tiny,
		TextWrapped = false,
		Size = UDim2.new(1, -200, 0, 18),
		Position = UDim2.fromOffset(98, 10),
		TextXAlignment = Enum.TextXAlignment.Left,
		TextColor3 = C.Primary,
		StrokeThickness = 1.5,
	})
	titleLabel = Kit.title(card, {
		Name = "Title",
		Text = "",
		TextSize = T.H3 + 1,
		TextWrapped = false,
		Size = UDim2.new(1, -120, 0, 26),
		Position = UDim2.fromOffset(98, 28),
		TextXAlignment = Enum.TextXAlignment.Left,
		StrokeThickness = 2,
	})
	textLabel = Kit.text(card, {
		Name = "Text",
		Text = "",
		TextSize = T.Small,
		Size = UDim2.new(1, -116, 0, 38),
		Position = UDim2.fromOffset(98, 56),
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
		TextColor3 = C.TextDim,
		StrokeThickness = 1,
	})

	local dotRow = Kit.new("Frame", {
		Name = "Dots",
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(160, 12),
		Position = UDim2.fromOffset(98, CARD_HEIGHT - 20),
		Parent = card,
	})
	Kit.list(dotRow, 6, true)
	for i = 1, TutorialSteps.COUNT do
		local dot = Kit.new("Frame", {
			Name = "Dot" .. i,
			BackgroundColor3 = C.PanelDark,
			Size = UDim2.fromOffset(12, 12),
			LayoutOrder = i,
			Parent = dotRow,
		})
		Kit.round(dot)
		Kit.stroke(dot, 2)
		dots[i] = dot
	end

	statusPill = Kit.pill(card, {
		Name = "Status",
		Text = "",
		Color = C.PanelDark,
		TextColor = C.Good,
		TextSize = T.Tiny,
		Size = UDim2.fromOffset(0, 22),
		AutomaticSize = Enum.AutomaticSize.X,
		Position = UDim2.new(1, -14, 1, -12),
		AnchorPoint = Vector2.new(1, 1),
		Visible = false,
	})

	Kit.button(card, {
		Name = "Skip",
		Text = Words.Skip,
		Color = C.PanelLight,
		Size = UDim2.fromOffset(70, 34),
		Position = UDim2.new(1, -10, 0, 8),
		AnchorPoint = Vector2.new(1, 0),
		TextSize = T.Small,
		Depth = 4,
	}, function()
		deps.popups.confirm(Words.SkipConfirm, function()
			action:FireServer({ action = "SkipTutorial" })
		end, { title = "SKIP " .. Words.Title .. "?", icon = "⏭", yes = Words.Skip, no = "Keep going" })
	end)

	State.changed.Event:Connect(render)
	if State.data then
		render(State.data)
	end
end

return Tutorial
