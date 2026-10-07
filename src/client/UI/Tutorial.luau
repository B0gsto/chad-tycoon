--[[
	Tutorial (client): the onboarding quest pill, the guide target and the
	completion banner. Progress itself is server-side (see
	ServerScriptService.Server.Tutorial); this only reads the State snapshot
	(tutorialStep, tutorialDone) and the "Tutorial" Notify payloads.

	The quest pill is one slim line (step chip "2/5", the short instruction,
	a quiet "x" to skip) docked top-centre under the multiplier gauge, or
	bottom-centre above the dumbbell meter on compact screens, so it never covers the
	play area. Theme.Tutorial.Steps[i].ShortHint, when present, shows as a
	small second line for the first few seconds of a step. Docked at the top
	it sets the ScreenGui attribute "TopCardHeight" so toasts sit below it.

	A new step slides/fades in with one soft pulse; a finished step ticks a
	check mark on the chip, slides out, then the next one slides in. The pill
	(and the 3D guide, see Guide) stays hidden while the intro cutscene plays
	(Players.LocalPlayer attribute "IntroPlaying").

	The completion reward is a toast-sized banner shown through the popup
	queue once the wallet has finished counting up the first collect.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TextService = game:GetService("TextService")

local Net = require(ReplicatedStorage.Shared.Net)
local TutorialSteps = require(ReplicatedStorage.Shared.TutorialSteps)

local Kit = require(script.Parent.Kit)
local State = require(script.Parent.Parent.State)

local Theme = Kit.Theme
local C = Kit.C
local F = Kit.F
local T = Kit.TEXT
local Words = Theme.Tutorial

local Tutorial = {}

export type Deps = {
	popups: any,
	sounds: any,
	guide: any?,
	-- Glows a HUD menu button (e.g. the Index after the first merge).
	highlight: ((string, boolean) -> ())?,
	-- True once the wallet count-up from the latest cash is over.
	walletIdle: (() -> boolean)?,
}

-- Pill geometry (design pixels). The HUD's deposit strip spans y 54..84 at the top
-- centre; the compact dumbbell's top edge sits about 94 px above the bottom.
local PILL_HEIGHT = 44
local PILL_MIN_WIDTH = 220
local PILL_MAX_WIDTH = 360
local TOP_Y = 92
local BOTTOM_GAP = 102
-- The pill lives in a CanvasGroup (for the fade) padded so its shadow is not clipped.
local PAD_X = 6
local PAD_TOP = 4
local PAD_BOTTOM = 14
local SLIDE = 12
local CHIP_WIDTH = 38
local TEXT_X = 54
local CLOSE_WIDTH = 38
local TEXT_SIZE = 16
local HINT_SIZE = 14
local HINT_SECONDS = 4
local TICK_HOLD = 0.45

local screen: ScreenGui
local deps: Deps
local group: CanvasGroup
local pulseScale: UIScale
local chip: Frame
local chipLabel: TextLabel
local chipCheck: Frame
local checkScale: UIScale
local mainLabel: TextLabel
local hintLabel: TextLabel

-- Step the pill currently displays (0 = none), and whether it is on screen.
local shownStep = 0
local shownHint: string? = nil
local onScreen = false
-- True while a finished step ticks and slides out (its text must not change).
local leaving = false
-- Bumped by every show/hide/transition so stale delayed steps bail out.
local token = 0
local hintSerial = 0
local lastData: { [string]: any }? = nil

local function compact(): boolean
	return screen:GetAttribute("Compact") == true
end

local function introPlaying(): boolean
	local player = Players.LocalPlayer
	return player ~= nil and player:GetAttribute("IntroPlaying") == true
end

-- A game-mode run timer (Hud, ScreenGui attribute "RunActive") takes the pill's slot.
local function slotTaken(): boolean
	return introPlaying() or screen:GetAttribute("RunActive") == true
end

local function restPosition(): UDim2
	if compact() then
		return UDim2.new(0.5, 0, 1, -BOTTOM_GAP + PAD_BOTTOM)
	end
	return UDim2.new(0.5, 0, 0, TOP_Y - PAD_TOP)
end

-- Where the pill slides from/to: above its spot at the top, below it at the bottom.
local function awayPosition(): UDim2
	return restPosition() + UDim2.fromOffset(0, if compact() then SLIDE else -SLIDE)
end

local function publishHeight()
	local height = if onScreen and not compact() then PILL_HEIGHT + 8 else 0
	screen:SetAttribute("TopCardHeight", height)
end

local function textWidth(text: string, size: number, font: Enum.Font): number
	local ok, bounds = pcall(function()
		return TextService:GetTextSize(text, size, font, Vector2.new(1000, 100))
	end)
	if ok and typeof(bounds) == "Vector2" then
		return bounds.X
	end
	return #text * size * 0.55
end

local function stepWords(step: number, data: { [string]: any }): (string, string?)
	local words = Words.Steps[step]
	local target = TutorialSteps.target(step, data.units)
	local isMerge = TutorialSteps.STEPS[step].id == "merge"
	local needsPair = isMerge and target ~= "Merge"
	-- The merge step's hint only applies while the player still lacks a pair.
	local hint: string? = if isMerge and not needsPair then nil else words.ShortHint
	return words.Short or words.Title, hint
end

-- Shows the small second line for a few seconds, then eases the main line back to centre.
local function showHint(hint: string?)
	shownHint = hint
	hintSerial += 1
	local mine = hintSerial
	if not hint then
		Kit.tween(hintLabel, 0.25, { TextTransparency = 1 })
		Kit.tween(mainLabel, 0.25, { Position = UDim2.new(0, TEXT_X, 0.5, 0) })
		return
	end
	hintLabel.Text = hint
	hintLabel.TextTransparency = 1
	mainLabel.Position = UDim2.new(0, TEXT_X, 0.5, -8)
	Kit.tween(hintLabel, 0.3, { TextTransparency = 0.15 })
	task.delay(HINT_SECONDS, function()
		if hintSerial == mine then
			Kit.tween(hintLabel, 0.35, { TextTransparency = 1 })
			Kit.tween(mainLabel, 0.35, { Position = UDim2.new(0, TEXT_X, 0.5, 0) })
		end
	end)
end

-- Fills the pill for `step` (while it is off screen or about to slide in).
local function setContent(step: number, data: { [string]: any })
	local text, hint = stepWords(step, data)
	shownStep = step
	chipLabel.Text = string.format("%d/%d", step, TutorialSteps.COUNT)
	chipLabel.TextTransparency = 0
	chip.BackgroundColor3 = C.Gold
	checkScale.Scale = 0
	mainLabel.Text = text
	local width = math.max(textWidth(text, TEXT_SIZE, F.Bold), if hint then textWidth(hint, HINT_SIZE, F.Body) else 0)
	local pillWidth = math.clamp(math.ceil(width) + TEXT_X + CLOSE_WIDTH + 8, PILL_MIN_WIDTH, PILL_MAX_WIDTH)
	group.Size = UDim2.fromOffset(pillWidth + PAD_X * 2, PILL_HEIGHT + PAD_TOP + PAD_BOTTOM)
	hintLabel.TextTransparency = 1
	mainLabel.Position = UDim2.new(0, TEXT_X, 0.5, 0)
	showHint(hint)
end

local function slideIn()
	token += 1
	local mine = token
	onScreen = true
	leaving = false
	publishHeight()
	group.Visible = true
	group.AnchorPoint = Vector2.new(0.5, if compact() then 1 else 0)
	group.GroupTransparency = 1
	group.Position = awayPosition()
	pulseScale.Scale = 1
	Kit.tween(group, 0.3, { GroupTransparency = 0, Position = restPosition() }, Enum.EasingStyle.Quad)
	-- One soft pulse once it has landed.
	task.delay(0.3, function()
		if token ~= mine then
			return
		end
		Kit.tween(pulseScale, 0.14, { Scale = 1.04 }, Enum.EasingStyle.Quad)
		task.delay(0.14, function()
			Kit.tween(pulseScale, 0.26, { Scale = 1 }, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut)
		end)
	end)
end

local function slideOut(after: (() -> ())?)
	token += 1
	local mine = token
	onScreen = false
	leaving = false
	publishHeight()
	Kit.tween(group, 0.22, { GroupTransparency = 1, Position = awayPosition() }, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
	task.delay(0.24, function()
		if token ~= mine then
			return
		end
		group.Visible = false
		if after then
			after()
		end
	end)
end

-- Turns the step chip into a green check mark.
local function tick()
	Kit.tween(chip, 0.2, { BackgroundColor3 = C.Cash })
	Kit.tween(chipLabel, 0.12, { TextTransparency = 1 })
	Kit.tween(checkScale, 0.3, { Scale = 1 }, Enum.EasingStyle.Back)
end

-- Ticks the current step, then slides the pill out (and runs `after`).
local function completeAndLeave(after: (() -> ())?)
	token += 1
	local mine = token
	leaving = true
	tick()
	task.delay(TICK_HOLD, function()
		if token == mine then
			slideOut(after)
		end
	end)
end

local function render(data: { [string]: any })
	lastData = data
	local step = TutorialSteps.clamp(data.tutorialStep)
	local active = data.tutorialDone ~= true and step <= TutorialSteps.COUNT
	if not active then
		if deps.guide then
			deps.guide.setTutorialTarget(nil)
		end
		if onScreen and not leaving then
			-- Finished (not skipped): tick the last step on the way out.
			if data.tutorialDone == true and step > TutorialSteps.COUNT then
				completeAndLeave()
			else
				slideOut()
			end
		end
		shownStep = 0
		return
	end

	if deps.guide then
		deps.guide.setTutorialTarget(TutorialSteps.target(step, data.units))
	end

	if slotTaken() then
		if onScreen then
			slideOut()
		end
		-- Re-shown fresh (with its hint) when the intro or the run ends.
		shownStep = 0
		return
	end

	if step ~= shownStep then
		if onScreen and shownStep > 0 and step > shownStep then
			completeAndLeave(function()
				local latest = lastData
				if latest and not slotTaken() then
					setContent(TutorialSteps.clamp(latest.tutorialStep), latest)
					slideIn()
				end
			end)
			shownStep = step
		else
			setContent(step, data)
			slideIn()
		end
	elseif onScreen and not leaving then
		-- Same step: the merge step's text can change once the player owns a pair.
		local text, hint = stepWords(step, data)
		if mainLabel.Text ~= text then
			mainLabel.Text = text
		end
		if hint ~= shownHint then
			showHint(hint)
		end
	end
end

-- "Training complete": a toast-sized banner where the pill sat, queued with
-- the other popups. Not modal: tap or wait to dismiss.
local function showCelebrate(cash: number, done: () -> ())
	local existing = screen:FindFirstChild("TutorialDone")
	if existing then
		existing:Destroy()
	end
	local atBottom = compact()
	local rest = if atBottom then UDim2.new(0.5, 0, 1, -BOTTOM_GAP + PAD_BOTTOM) else UDim2.new(0.5, 0, 0, TOP_Y - PAD_TOP)
	local away = rest + UDim2.fromOffset(0, if atBottom then SLIDE else -SLIDE)
	local holder = Kit.new("Frame", {
		Name = "TutorialDone",
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(392, 60 + PAD_TOP + PAD_BOTTOM),
		Position = away,
		AnchorPoint = Vector2.new(0.5, if atBottom then 1 else 0),
		ZIndex = 20,
		Parent = screen,
	})
	local fade = Kit.new("CanvasGroup", {
		Name = "Fade",
		BackgroundTransparency = 1,
		GroupTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		ZIndex = 21,
		Parent = holder,
	})
	local card = Kit.panel(fade, {
		Name = "Card",
		Size = UDim2.new(1, -PAD_X * 2, 0, 60),
		Position = UDim2.fromOffset(PAD_X, PAD_TOP),
		StrokeColor = C.Gold,
		Radius = 30,
		ZIndex = 21,
	})
	local medal = Kit.new("Frame", {
		Name = "Medal",
		BackgroundColor3 = Color3.new(1, 1, 1),
		Size = UDim2.fromOffset(40, 40),
		Position = UDim2.new(0, 8, 0.5, 0),
		AnchorPoint = Vector2.new(0, 0.5),
		ZIndex = 22,
		Parent = card,
	})
	Kit.round(medal)
	Kit.gradient(medal, Kit.lighten(C.Gold, 0.35), C.Gold)
	Kit.icon(medal, "Ranking", 24, C.GoldInk, { Position = UDim2.fromScale(0.5, 0.5), AnchorPoint = Vector2.new(0.5, 0.5), ZIndex = 23 })
	local medalScale = Kit.new("UIScale", { Scale = 0.4, Parent = medal })

	Kit.title(card, {
		Name = "Title",
		Text = Words.DoneTitle,
		TextSize = T.H3,
		TextWrapped = false,
		Size = UDim2.new(1, -64, 0, 22),
		Position = UDim2.fromOffset(56, 6),
		TextXAlignment = Enum.TextXAlignment.Left,
		TextColor3 = C.Primary,
		StrokeThickness = 1.5,
		ZIndex = 22,
	})
	local rewards = Kit.new("Frame", {
		Name = "Rewards",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, -64, 0, 22),
		Position = UDim2.fromOffset(56, 31),
		ZIndex = 22,
		Parent = card,
	})
	Kit.list(rewards, 6, true)
	local pills = {
		{ text = "+" .. State.money(cash), color = C.Cash },
	}
	for i, info in pills do
		Kit.pill(rewards, {
			Text = info.text,
			Color = info.color,
			TextSize = T.Small,
			Size = UDim2.fromOffset(0, 22),
			AutomaticSize = Enum.AutomaticSize.X,
			LayoutOrder = i,
			ZIndex = 22,
		})
		task.delay(0.25 + i * 0.14, function()
			deps.sounds.play("Tick", 0.03, 1 + i * 0.12)
		end)
	end

	Kit.tween(fade, 0.3, { GroupTransparency = 0 }, Enum.EasingStyle.Quad)
	Kit.tween(holder, 0.3, { Position = rest }, Enum.EasingStyle.Quad)
	Kit.tween(medalScale, 0.4, { Scale = 1 }, Enum.EasingStyle.Back)
	Kit.confetti(holder, {
		Origin = UDim2.new(0, PAD_X + 28, 0, PAD_TOP + 28),
		Count = 12,
		Power = 0.45,
		ZIndex = 24,
	})
	deps.sounds.play("Celebrate")

	local closed = false
	local function close()
		if closed then
			return
		end
		closed = true
		Kit.tween(fade, 0.22, { GroupTransparency = 1 }, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
		Kit.tween(holder, 0.22, { Position = away }, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
		task.delay(0.25, function()
			holder:Destroy()
			done()
		end)
	end
	local catcher = Kit.new("TextButton", {
		Name = "Dismiss",
		BackgroundTransparency = 1,
		Selectable = false,
		Text = "",
		Size = UDim2.fromScale(1, 1),
		ZIndex = 25,
		Parent = holder,
	})
	catcher.Activated:Connect(close)
	task.delay(4.5, close)
end

-- Waits for the first-collect cash to finish rolling into the wallet (the
-- "done" notify can arrive before or after the Cash effect), then queues the banner.
function Tutorial.celebrate(cash: number)
	task.spawn(function()
		task.wait(0.5)
		local waited = 0.5
		local idle = deps.walletIdle
		while idle and not idle() and waited < 5 do
			task.wait(0.1)
			waited += 0.1
		end
		deps.popups.enqueue("Tutorial", deps.popups.PRIORITY.Tutorial, function(done)
			showCelebrate(cash, done)
		end)
	end)
end

function Tutorial.onNotify(payload: { [string]: any })
	if payload.event == "step" then
		deps.sounds.play("Step")
	elseif payload.event == "done" then
		if onScreen and not leaving then
			completeAndLeave()
			shownStep = 0
		end
		Tutorial.celebrate(payload.cash or 0)
		-- The merge just discovered a new tier: point at the Index.
		if deps.highlight then
			deps.highlight("Index", true)
		end
	elseif payload.event == "skipped" then
		if onScreen then
			slideOut()
			shownStep = 0
		end
	end
end

function Tutorial.build(screenGui: ScreenGui, dependencies: Deps)
	screen = screenGui
	deps = dependencies
	local action = Net.event("Action")

	group = Kit.new("CanvasGroup", {
		Name = "TutorialPill",
		BackgroundTransparency = 1,
		GroupTransparency = 1,
		Size = UDim2.fromOffset(PILL_MIN_WIDTH + PAD_X * 2, PILL_HEIGHT + PAD_TOP + PAD_BOTTOM),
		Position = restPosition(),
		AnchorPoint = Vector2.new(0.5, 0),
		Visible = false,
		ZIndex = 6,
		Parent = screen,
	})
	pulseScale = Kit.new("UIScale", { Parent = group })
	local pill = Kit.panel(group, {
		Name = "Pill",
		Size = UDim2.new(1, -PAD_X * 2, 0, PILL_HEIGHT),
		Position = UDim2.fromOffset(PAD_X, PAD_TOP),
		Transparency = 0.08,
		Radius = PILL_HEIGHT // 2,
		ZIndex = 6,
	})

	chip = Kit.new("Frame", {
		Name = "Chip",
		BackgroundColor3 = C.Gold,
		Size = UDim2.fromOffset(CHIP_WIDTH, 24),
		Position = UDim2.new(0, 7, 0.5, 0),
		AnchorPoint = Vector2.new(0, 0.5),
		ZIndex = 7,
		Parent = pill,
	})
	Kit.round(chip)
	chipLabel = Kit.number(chip, {
		Name = "Step",
		Text = "",
		TextSize = T.Small,
		TextColor3 = C.GoldInk,
		StrokeThickness = 0,
		ZIndex = 8,
	})
	chipCheck = Kit.icon(chip, "Check", 16, C.Text, {
		Name = "Check",
		Position = UDim2.fromScale(0.5, 0.5),
		AnchorPoint = Vector2.new(0.5, 0.5),
		ZIndex = 8,
	})
	checkScale = Kit.new("UIScale", { Scale = 0, Parent = chipCheck })

	mainLabel = Kit.text(pill, {
		Name = "Text",
		Text = "",
		Font = F.Bold,
		TextSize = TEXT_SIZE,
		TextWrapped = false,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Size = UDim2.new(1, -(TEXT_X + CLOSE_WIDTH), 0, 20),
		Position = UDim2.new(0, TEXT_X, 0.5, 0),
		AnchorPoint = Vector2.new(0, 0.5),
		TextXAlignment = Enum.TextXAlignment.Left,
		ZIndex = 7,
	})
	hintLabel = Kit.text(pill, {
		Name = "Hint",
		Text = "",
		TextSize = HINT_SIZE,
		TextWrapped = false,
		TextTruncate = Enum.TextTruncate.AtEnd,
		TextTransparency = 1,
		Size = UDim2.new(1, -(TEXT_X + CLOSE_WIDTH), 0, 17),
		Position = UDim2.new(0, TEXT_X, 0.5, 10),
		AnchorPoint = Vector2.new(0, 0.5),
		TextXAlignment = Enum.TextXAlignment.Left,
		TextColor3 = C.TextDim,
		ZIndex = 7,
	})

	-- Quiet skip: a small "x" (44 px hit area, centred where the 36 px one was) that asks
	-- before skipping.
	local skip = Kit.new("TextButton", {
		Name = "Skip",
		BackgroundTransparency = 1,
		Text = "",
		AutoButtonColor = false,
		Size = UDim2.fromOffset(44, 44),
		Position = UDim2.new(1, 2, 0.5, 0),
		AnchorPoint = Vector2.new(1, 0.5),
		ZIndex = 8,
		Parent = pill,
	})
	local cross = Kit.icon(skip, "Close", 12, C.TextMute, {
		Name = "Cross",
		Position = UDim2.fromScale(0.5, 0.5),
		AnchorPoint = Vector2.new(0.5, 0.5),
		ZIndex = 9,
	})
	Kit.bouncy(skip, 1.12)
	Kit.selectable(skip)
	local function lit(on: boolean)
		for _, part in cross:GetChildren() do
			if part:IsA("Frame") then
				Kit.tween(part, 0.12, { BackgroundColor3 = if on then C.TextDim else C.TextMute })
			end
		end
	end
	skip.MouseEnter:Connect(function()
		lit(true)
	end)
	skip.MouseLeave:Connect(function()
		lit(false)
	end)
	skip.SelectionGained:Connect(function()
		lit(true)
	end)
	skip.SelectionLost:Connect(function()
		lit(false)
	end)
	skip.Activated:Connect(function()
		Kit.sound("Click")
		deps.popups.confirm(Words.SkipConfirm, function()
			action:FireServer({ action = "SkipTutorial" })
		end, { title = "SKIP " .. Words.Title .. "?", icon = "⏭", yes = Words.Skip, no = "Keep going" })
	end)

	screen:GetAttributeChangedSignal("Compact"):Connect(function()
		group.AnchorPoint = Vector2.new(0.5, if compact() then 1 else 0)
		if onScreen then
			Kit.tween(group, 0.25, { Position = restPosition() }, Enum.EasingStyle.Quad)
		end
		publishHeight()
	end)
	publishHeight()

	-- The intro cutscene hides the pill; it slides back in when the intro ends.
	local player = Players.LocalPlayer
	if player then
		player:GetAttributeChangedSignal("IntroPlaying"):Connect(function()
			if State.data then
				render(State.data)
			end
		end)
	end

	screen:GetAttributeChangedSignal("RunActive"):Connect(function()
		if State.data then
			render(State.data)
		end
	end)

	State.changed.Event:Connect(render)
	if State.data then
		render(State.data)
	end
end

return Tutorial
