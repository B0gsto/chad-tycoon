--[[
	Tutorial (client): the onboarding quest pill, the guide target and the
	completion banner. Progress itself is server-side (see
	ServerScriptService.Server.Tutorial); this only reads the State snapshot
	(tutorialStep, tutorialDone) and the "Tutorial" Notify payloads.

	The quest pill is one slim glass line (Kit.hudGlass: step chip "2/5", the
	short instruction as outlined HUD text, a quiet "x" to skip) docked
	top-centre under the multiplier gauge, or
	bottom-centre above the dumbbell meter on compact screens, so it never covers the
	play area. Theme.Tutorial.Steps[i].ShortHint, when present, shows as a
	small second line for the first few seconds of a step. Docked at the top
	it sets the ScreenGui attribute "TopCardHeight" so toasts sit below it.

	The pill drops in 12 px with a fade and one soft pulse. A finished step
	ticks a check mark on the chip, then the next step's text cross-fades in
	place with another soft pulse (the pill is not rebuilt); only the last step
	slides it out. The pill (and the 3D guide, see Guide) stays hidden while the
	intro cutscene plays (Players.LocalPlayer attribute "IntroPlaying").

	The completion reward is a toast-sized banner shown through the popup
	queue once the wallet has finished counting up the first collect.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TextService = game:GetService("TextService")

local Net = require(ReplicatedStorage.Shared.Net)
local TutorialSteps = require(ReplicatedStorage.Shared.TutorialSteps)

local Kit = require(script.Parent.Kit)
local Sprites = require(script.Parent.Parent.Fx.Sprites)
local State = require(script.Parent.Parent.State)

local PREVIEW = typeof(TweenInfo.new(0)) ~= "TweenInfo"
local SPARKLE = Sprites.image("Sparkle")

local Theme = Kit.Theme
local G = Theme.Glass
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
-- The text sizes are held on the glass (Tutorial.build: a phone's UI scale would shrink
-- 18 / 14 design px to 12 / 9), and the pill's height and widest width follow them.
local PILL_HEIGHT = 44
local PILL_MIN_WIDTH = 220
local PILL_MAX_WIDTH = 440
local TOP_Y = 92
local BOTTOM_GAP = 102
-- The pill lives in a CanvasGroup (for the fade) padded so its shadow is not clipped.
local PAD_X = 6
local PAD_TOP = 4
local PAD_BOTTOM = 14
local SLIDE = 12
local CHIP_WIDTH = 38
local TEXT_X = 64
local CHIP_X = 18 -- past the gold accent bar
-- While a window is open the pill docks on the screen edge above it (and above its dim).
local EDGE_GAP = 4
local Z_REST = 6
local Z_OVER_WINDOWS = 12
local CLOSE_WIDTH = 38
local TEXT_SIZE = 18
local HINT_SIZE = 14
local HINT_FADED = 0.1
local HINT_SECONDS = 4
local IN_TIME = 0.18
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
-- True while a finished step ticks and its text swaps or slides out (the text must not change).
local leaving = false
-- Bumped by every show/hide/transition so stale delayed steps bail out.
local token = 0
local hintSerial = 0
local lastData: { [string]: any }? = nil
-- A window or modal is open (Kit.onWindowOpen): the HUD is hidden, the pill stays.
local windowUp = false

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
	if windowUp then
		-- Clear of the window: the very top (the hidden unit counter's row), or the very
		-- bottom on compact screens.
		return if compact() then UDim2.new(0.5, 0, 1, PAD_BOTTOM - EDGE_GAP) else UDim2.new(0.5, 0, 0, EDGE_GAP - PAD_TOP)
	end
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

-- Eases `props` over `time`, or sets them at once when `time` is 0.
local function ease(obj: Instance, time: number, props: { [string]: any })
	if time > 0 then
		Kit.tween(obj, time, props, Enum.EasingStyle.Quad)
		return
	end
	for key, value in props do
		(obj :: any)[key] = value
	end
end

-- Fades a HUD label together with its outline (a UIStroke ignores TextTransparency).
local function fadeText(label: TextLabel, time: number, transparency: number)
	ease(label, time, { TextTransparency = transparency })
	local outline = label:FindFirstChild("Outline")
	if outline then
		ease(outline, time, { Transparency = transparency })
	end
end

-- Shows the small second line for a few seconds, then eases the main line back to centre.
local function showHint(hint: string?)
	shownHint = hint
	hintSerial += 1
	local mine = hintSerial
	if not hint then
		fadeText(hintLabel, 0.25, 1)
		Kit.tween(mainLabel, 0.25, { Position = UDim2.new(0, TEXT_X, 0.5, 0) })
		return
	end
	hintLabel.Text = hint
	fadeText(hintLabel, 0, 1)
	mainLabel.Position = UDim2.new(0, TEXT_X, 0.5, -(HINT_SIZE // 2 + 1))
	fadeText(hintLabel, 0.3, HINT_FADED)
	task.delay(HINT_SECONDS, function()
		if hintSerial == mine then
			fadeText(hintLabel, 0.35, 1)
			Kit.tween(mainLabel, 0.35, { Position = UDim2.new(0, TEXT_X, 0.5, 0) })
		end
	end)
end

-- Fills the pill for `step`. `live` is a step change while it is on screen: the pill eases
-- to its new width and the chip back to gold instead of jumping (the caller fades the text).
local function setContent(step: number, data: { [string]: any }, live: boolean?)
	local text, hint = stepWords(step, data)
	local time = if live then 0.2 else 0
	shownStep = step
	chipLabel.Text = string.format("%d/%d", step, TutorialSteps.COUNT)
	ease(chipLabel, time, { TextTransparency = 0 })
	ease(chip, time, { BackgroundColor3 = C.Gold })
	ease(checkScale, time * 0.6, { Scale = 0 })
	mainLabel.Text = text
	local width = math.max(textWidth(text, TEXT_SIZE, F.Display), if hint then textWidth(hint, HINT_SIZE, F.UI) else 0)
	local pillWidth = math.clamp(math.ceil(width) + TEXT_X + CLOSE_WIDTH + 12, PILL_MIN_WIDTH, PILL_MAX_WIDTH)
	ease(group, time, { Size = UDim2.fromOffset(pillWidth + PAD_X * 2, PILL_HEIGHT + PAD_TOP + PAD_BOTTOM) })
	fadeText(hintLabel, 0, 1)
	mainLabel.Position = UDim2.new(0, TEXT_X, 0.5, 0)
	fadeText(mainLabel, time, 0)
	showHint(hint)
end

-- One soft pulse: the pill has landed, or shows a new step.
local function pulse(mine: number)
	Kit.tween(pulseScale, 0.14, { Scale = 1.04 }, Enum.EasingStyle.Quad)
	task.delay(0.14, function()
		if token == mine then
			Kit.tween(pulseScale, 0.26, { Scale = 1 }, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut)
		end
	end)
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
	pulseScale.Scale = 0.96
	Kit.tween(group, IN_TIME, { GroupTransparency = 0, Position = restPosition() }, Enum.EasingStyle.Quad)
	Kit.tween(pulseScale, IN_TIME, { Scale = 1 }, Enum.EasingStyle.Quad)
	task.delay(IN_TIME + 0.04, function()
		if token == mine then
			pulse(mine)
		end
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

-- A finished step with more to come: ticks the chip, then cross-fades the pill's text to
-- the latest step in place, with one soft pulse. Slides out instead if the tutorial ended
-- (or its slot was taken) meanwhile.
local function advance()
	token += 1
	local mine = token
	leaving = true
	tick()
	task.delay(TICK_HOLD, function()
		if token ~= mine then
			return
		end
		hintSerial += 1
		fadeText(mainLabel, 0.12, 1)
		fadeText(hintLabel, 0.12, 1)
		task.delay(0.12, function()
			if token ~= mine then
				return
			end
			local latest = lastData
			local step = if latest then TutorialSteps.clamp(latest.tutorialStep) else 0
			if not latest or latest.tutorialDone == true or step > TutorialSteps.COUNT or slotTaken() then
				slideOut()
				return
			end
			leaving = false
			setContent(step, latest, true)
			pulse(mine)
		end)
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
			advance()
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

-- A burst of sparkles from the middle of `holder`, flung out along a wide ellipse (the
-- Sparkle sprite; one tween each, nothing per frame). They clean themselves up.
local function sparkleBurst(holder: Frame, count: number, zindex: number)
	if not SPARKLE then
		return
	end
	for i = 1, count do
		local angle = (i + math.random() * 0.5) / count * math.pi * 2
		local size = math.random(20, 34)
		local star = Kit.new("ImageLabel", {
			Name = "Sparkle",
			BackgroundTransparency = 1,
			Image = SPARKLE,
			ImageColor3 = if i % 2 == 0 then C.GoldLight else Color3.new(1, 1, 1),
			ImageTransparency = 0.05,
			Size = UDim2.fromOffset(size * 0.4, size * 0.4),
			Position = UDim2.fromScale(0.5, 0.45),
			AnchorPoint = Vector2.new(0.5, 0.5),
			Rotation = math.random(-25, 25),
			ZIndex = zindex,
			Parent = holder,
		})
		local reach = 0.86 + math.random() * 0.3
		Kit.tween(star, 0.5, {
			Size = UDim2.fromOffset(size, size),
			Position = UDim2.new(0.5, math.cos(angle) * 250 * reach, 0.45, math.sin(angle) * 62 * reach),
			Rotation = star.Rotation + 60,
		}, Enum.EasingStyle.Quart)
		if not PREVIEW then
			task.delay(0.4, function()
				Kit.tween(star, 0.35, { ImageTransparency = 1, Size = UDim2.fromOffset(size * 0.5, size * 0.5) })
			end)
			task.delay(0.8, function()
				star:Destroy()
			end)
		end
	end
end

-- "Training complete": the top notification tier. A gold banner (bigger than a toast)
-- that bounces into the pill's slot with a sparkle burst, queued with the other popups.
-- Not modal: tap or wait to dismiss.
local BANNER_W, BANNER_H = 468, 96
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
		Size = UDim2.fromOffset(BANNER_W, BANNER_H + PAD_TOP + PAD_BOTTOM),
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
	-- Toasts queue under the banner while it holds the top slot.
	if not atBottom then
		screen:SetAttribute("TopCardHeight", BANNER_H + 8)
	end
	local bounce = Kit.new("UIScale", { Name = "Bounce", Scale = 0.6, Parent = holder })
	-- The one solid banner: the bright gold of a primary button (sunny yellow down to
	-- orange) on an orange lip, with a white highlight along the top inner edge.
	local card = Kit.new("Frame", {
		Name = "Card",
		BackgroundColor3 = Color3.new(1, 1, 1),
		BorderSizePixel = 0,
		Size = UDim2.new(1, -PAD_X * 2, 0, BANNER_H),
		Position = UDim2.fromOffset(PAD_X, PAD_TOP),
		ZIndex = 21,
		Parent = fade,
	})
	Kit.corner(card, Kit.RADIUS.L)
	Kit.new("UIGradient", {
		Rotation = 90,
		Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, C.GoldLight),
			ColorSequenceKeypoint.new(0.45, C.Gold),
			ColorSequenceKeypoint.new(1, C.GoldDeep),
		}),
		Parent = card,
	})
	Kit.stroke(card, 2.5, Kit.lip(C.GoldDeep))
	Kit.shadow(card, Kit.RADIUS.L, 1, 0)
	local shine = Kit.new("Frame", {
		Name = "Highlight",
		BackgroundColor3 = Color3.new(1, 1, 1),
		BackgroundTransparency = 0.25,
		BorderSizePixel = 0,
		Size = UDim2.new(1, -28, 0, 3),
		Position = UDim2.fromOffset(14, 4),
		ZIndex = 22,
		Parent = card,
	})
	Kit.round(shine)
	local medal = Kit.new("Frame", {
		Name = "Medal",
		BackgroundColor3 = Color3.new(1, 1, 1),
		Size = UDim2.fromOffset(64, 64),
		Position = UDim2.new(0, 16, 0.5, 0),
		AnchorPoint = Vector2.new(0, 0.5),
		ZIndex = 22,
		Parent = card,
	})
	Kit.round(medal)
	Kit.gradient(medal, Color3.new(1, 1, 1), C.GoldLight)
	Kit.stroke(medal, 2.5, Kit.lip(C.GoldDeep))
	Kit.icon(medal, "Ranking", 38, C.GoldInk, { Position = UDim2.fromScale(0.5, 0.5), AnchorPoint = Vector2.new(0.5, 0.5), ZIndex = 23 })
	local medalScale = Kit.new("UIScale", { Scale = 0.4, Parent = medal })

	-- White title with the dark outline, the size of a window title.
	Kit.hudText(card, {
		Name = "Title",
		Text = Words.DoneTitle,
		TextSize = 28,
		MinPx = 18,
		Size = UDim2.new(1, -106, 0, 36),
		Position = UDim2.fromOffset(94, 10),
		TextXAlignment = Enum.TextXAlignment.Left,
		TextColor3 = C.Text,
		StrokeColor = G.TextInk,
		StrokeThickness = 3,
		ZIndex = 22,
	})
	-- The reward: a coin and the amount, large, on a dark chip so the green holds on gold.
	local reward = Kit.new("Frame", {
		Name = "Reward",
		BackgroundColor3 = C.Ink,
		BackgroundTransparency = 0.12,
		Size = UDim2.fromOffset(0, 36),
		AutomaticSize = Enum.AutomaticSize.X,
		Position = UDim2.fromOffset(94, 50),
		ZIndex = 22,
		Parent = card,
	})
	Kit.round(reward)
	Kit.padding(reward, 0, 12)
	Kit.list(reward, 8, true)
	Kit.icon(reward, "Coin", 26, C.Gold, { Name = "Coin", LayoutOrder = 1, ZIndex = 23 })
	Kit.number(reward, {
		Name = "Amount",
		Text = "+" .. State.money(cash),
		TextSize = 26,
		MinPx = 18,
		TextColor3 = C.MoneyText,
		Size = UDim2.fromOffset(0, 36),
		AutomaticSize = Enum.AutomaticSize.X,
		LayoutOrder = 2,
		ZIndex = 23,
	})
	task.delay(0.39, function()
		deps.sounds.play("Tick", 0.03, 1.12)
	end)

	Kit.tween(fade, IN_TIME, { GroupTransparency = 0 }, Enum.EasingStyle.Quad)
	-- Bounce in: the banner drops into the slot and overshoots its size.
	Kit.tween(holder, 0.34, { Position = rest }, Enum.EasingStyle.Back)
	Kit.tween(bounce, 0.42, { Scale = 1 }, Enum.EasingStyle.Back)
	Kit.tween(medalScale, 0.5, { Scale = 1 }, Enum.EasingStyle.Back)
	sparkleBurst(holder, 12, 24)
	Kit.confetti(holder, {
		Origin = UDim2.new(0, PAD_X + 48, 0, PAD_TOP + BANNER_H // 2),
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
		publishHeight()
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
	-- The step (at least 16 px on the glass, 14 on a phone) and its hint (a caption).
	TEXT_SIZE = Kit.px(if Kit.touch then 14 else 16, 18, screen)
	HINT_SIZE = Kit.px(Kit.captionPx(), 14, screen)
	PILL_HEIGHT = math.max(44, TEXT_SIZE + HINT_SIZE + 12)
	PILL_MAX_WIDTH = math.ceil(440 * TEXT_SIZE / 18)

	group = Kit.new("CanvasGroup", {
		Name = "TutorialPill",
		BackgroundTransparency = 1,
		GroupTransparency = 1,
		Size = UDim2.fromOffset(PILL_MIN_WIDTH + PAD_X * 2, PILL_HEIGHT + PAD_TOP + PAD_BOTTOM),
		Position = restPosition(),
		AnchorPoint = Vector2.new(0.5, 0),
		Visible = false,
		ZIndex = Z_REST,
		Parent = screen,
	})
	pulseScale = Kit.new("UIScale", { Parent = group })
	-- Glass over the unblurred world, a notification tier above the HUD strips: a gold
	-- accent bar, the step chip carries the colour and the text is outlined.
	local pill = Kit.hudGlass(group, {
		Name = "Pill",
		Size = UDim2.new(1, -PAD_X * 2, 0, PILL_HEIGHT),
		Position = UDim2.fromOffset(PAD_X, PAD_TOP),
		Radius = Kit.RADIUS.M,
		Accent = C.Gold,
		ZIndex = 6,
	})

	chip = Kit.new("Frame", {
		Name = "Chip",
		BackgroundColor3 = C.Gold,
		Size = UDim2.fromOffset(CHIP_WIDTH, 24),
		Position = UDim2.new(0, CHIP_X, 0.5, 0),
		AnchorPoint = Vector2.new(0, 0.5),
		ZIndex = 7,
		Parent = pill,
	})
	Kit.round(chip)
	Kit.stroke(chip, 2, Kit.lip(C.Gold))
	chipLabel = Kit.number(chip, {
		Name = "Step",
		Text = "",
		TextSize = T.Small,
		MinPx = true,
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

	mainLabel = Kit.hudText(pill, {
		Name = "Text",
		Text = "",
		TextSize = TEXT_SIZE,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Size = UDim2.new(1, -(TEXT_X + CLOSE_WIDTH), 0, TEXT_SIZE + 4),
		Position = UDim2.new(0, TEXT_X, 0.5, 0),
		AnchorPoint = Vector2.new(0, 0.5),
		TextXAlignment = Enum.TextXAlignment.Left,
		StrokeThickness = 2,
		ZIndex = 7,
	})
	hintLabel = Kit.hudText(pill, {
		Name = "Hint",
		Text = "",
		Font = F.UI,
		TextSize = HINT_SIZE,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Size = UDim2.new(1, -(TEXT_X + CLOSE_WIDTH), 0, HINT_SIZE + 3),
		Position = UDim2.new(0, TEXT_X, 0.5, TEXT_SIZE // 2 + 2),
		AnchorPoint = Vector2.new(0, 0.5),
		TextXAlignment = Enum.TextXAlignment.Left,
		TextColor3 = C.TextDim,
		StrokeThickness = 2,
		ZIndex = 7,
	})
	fadeText(hintLabel, 0, 1)

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
	local cross = Kit.icon(skip, "Close", 12, C.TextDim, {
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
				Kit.tween(part, 0.12, { BackgroundColor3 = if on then C.Text else C.TextDim })
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

	-- A unit reveal owns the screen (ScreenGui attribute "RevealOpen", Popups): the pill
	-- would read through its veil, so it steps out for those two seconds.
	local function hideForReveal()
		pill.Visible = screen:GetAttribute("RevealOpen") ~= true
	end
	screen:GetAttributeChangedSignal("RevealOpen"):Connect(hideForReveal)
	hideForReveal()

	-- The tutorial may be telling the player to use the window that just opened: the pill
	-- stays, lifted over the window's dim and docked clear of the window.
	Kit.onWindowOpen(function(open: boolean)
		windowUp = open
		group.ZIndex = if open then Z_OVER_WINDOWS else Z_REST
		if onScreen then
			Kit.tween(group, 0.2, { Position = restPosition() }, Enum.EasingStyle.Quad)
		end
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
