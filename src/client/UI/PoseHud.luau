--!strict
--[[
	PoseHud: the screen side of POSE COPY (Modes.Pose; docs/minigames.md). Fx.Pose does
	the 3D side; this HUD runs the show's beats (it calls Fx.Pose.rivalFlex on every flex
	the rival shows and Fx.Pose.playerFlex on every press) so both stay on one clock.

	  Top pill     "ROUND n" with the goal ("PASS AT 8", then "BEST n"), the hearts and the
	               quiet quit button (X; first tap arms "QUIT?", the second fires ModeQuit;
	               Y / B on a controller).
	  Banner       "WATCH!" while the rival shows the round, "YOUR TURN!" when the player
	               copies it, "GREAT!" / "OOPS!" / "TOO SLOW!" / "TEST PASSED!" between.
	  Dots         one per flex of the round: the shown flex flashes its colour, a copied
	               one fills; a thin bar under them counts down the time left for the
	               next flex (PoseRules.INPUT_TIMEOUT, from "start").
	  Flex pad     four big buttons in a D-pad (up DOUBLE BICEPS, left SIDE CHEST, right LAT
	               SPREAD, down MOST MUSCULAR) in the flexes' colours, sized for thumbs; the
	               arrow keys, WASD and the D-pad press them. Shaded while the rival shows,
	               each lights up as its flex is shown.
	  Card         after "win" / "lose": the longest sequence, the best (NEW BEST!), the cash
	               the pass paid, and AGAIN / LEAVE.
	The player list and the touch thumbstick are hidden during a run.

	Wired from Main.client.luau (nothing else needs editing):
	  init(screen)        once, builds the HUD (hidden)
	  onNotify(payload)   every Notify with kind = "Mode" and mode = "pose"
	  onState(data)       every State snapshot (safety net: hides when modes.pose is not running)
	  start(payload) / stop(payload)
]]

local ContextActionService = game:GetService("ContextActionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Format = require(ReplicatedStorage.Shared.Format) :: any
local Net = require(ReplicatedStorage.Shared.Net)

local Client = script.Parent.Parent
local Kit = require(script.Parent.Kit) :: any
local Sounds = require(Client.Sounds) :: any
local PoseFx = require(Client.Fx.Pose)
local Popups = require(script.Parent.Popups) :: any

local PoseHud = {}

local C = Kit.C
local F = Kit.F
local FLEXES = PoseFx.FLEXES

local ACTION = "PoseFlexPress"
local QUIT_ACTION = "PoseQuit"
local PRIORITY = 3000
local BUTTON = 112 -- flex button size (design px)
local GAP = 10
local DESIGN_H = 760 -- screen height the HUD is laid out for (UIScale beyond it)

-- Which flex each key strikes (arrows, WASD, D-pad).
local KEYS: { [Enum.KeyCode]: number } = {
	[Enum.KeyCode.Up] = 1,
	[Enum.KeyCode.W] = 1,
	[Enum.KeyCode.DPadUp] = 1,
	[Enum.KeyCode.Left] = 2,
	[Enum.KeyCode.A] = 2,
	[Enum.KeyCode.DPadLeft] = 2,
	[Enum.KeyCode.Right] = 3,
	[Enum.KeyCode.D] = 3,
	[Enum.KeyCode.DPadRight] = 3,
	[Enum.KeyCode.Down] = 4,
	[Enum.KeyCode.S] = 4,
	[Enum.KeyCode.DPadDown] = 4,
}
-- The key chip on each button: keyboard letter, controller direction.
local CHIPS = { { "W", "UP" }, { "A", "LEFT" }, { "D", "RIGHT" }, { "S", "DOWN" } }
-- Where each button sits in the D-pad (column, row from the centre).
local PLACE: { [string]: Vector2 } = {
	Up = Vector2.new(0, -1),
	Left = Vector2.new(-1, 0),
	Right = Vector2.new(1, 0),
	Down = Vector2.new(0, 1),
}

local action = Net.event("Action")

local screen: ScreenGui? = nil
local root: Frame = nil :: any
local roundLabel: TextLabel = nil :: any
local goalLabel: TextLabel = nil :: any
local heartsRow: Frame = nil :: any
local quitButton: TextButton = nil :: any
local banner: TextLabel = nil :: any
local subBanner: TextLabel = nil :: any
local dotsRow: Frame = nil :: any
local dotsList: UIListLayout = nil :: any
-- The dots row's usable width (the top pill is 420 wide): dots shrink to fit it.
local DOTS_WIDTH = 396
local timerBack: Frame = nil :: any
local timerFill: Frame = nil :: any
local pad: Frame = nil :: any
local card: Frame = nil :: any
local cardTitle: TextLabel = nil :: any
local cardLines: TextLabel = nil :: any
local cardCash: TextLabel = nil :: any
local cardBest: TextLabel = nil :: any
local buttons: { TextButton } = {}
local shades: { Frame } = {}
local pops: { UIScale } = {}

local running = false
-- "intro" | "watch" | "turn" | "wait": only "turn" takes presses.
local phase = "intro"
local beat = 0 -- bumps on every round / stop, so stale show timers do nothing
local seq: { number } = {}
local done = 0
local lives, maxLives = 3, 3
local passRound = 8
local best = 0
local timeout = 6
local turnAt = 0
local quitArmed = false
local quitPress: () -> () = function() end
local timerConn: RBXScriptConnection? = nil

local function num(value: any, default: number): number
	return if type(value) == "number" and value == value then value else default
end

-- Hearts ----------------------------------------------------------------------------------

-- A heart from two discs and a 45-degree square (as the Mog HUD's).
local function heart(parent: Instance, index: number): Frame
	local holder = Kit.new("Frame", {
		Name = "Heart" .. index,
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(30, 28),
		LayoutOrder = index,
		Parent = parent,
	})
	local scale = Kit.new("UIScale", { Parent = holder })
	scale.Name = "Pop"
	local function piece(name: string, size: number, x: number, y: number, rotation: number, round: boolean)
		local f = Kit.new("Frame", {
			Name = name,
			BackgroundColor3 = C.Bad,
			BorderSizePixel = 0,
			Size = UDim2.fromOffset(size, size),
			Position = UDim2.fromOffset(x, y),
			AnchorPoint = Vector2.new(0.5, 0.5),
			Rotation = rotation,
			Parent = holder,
		})
		if round then
			Kit.round(f)
		else
			Kit.corner(f, 3)
		end
	end
	piece("Left", 15, 10, 10, 0, true)
	piece("Right", 15, 20, 10, 0, true)
	piece("Point", 15, 15, 15.5, 45, false)
	return holder
end

local function setHearts(newLives: number, newMax: number, animate: boolean)
	if newMax ~= maxLives or not heartsRow:FindFirstChild("Heart1") then
		for _, child in heartsRow:GetChildren() do
			if child:IsA("Frame") then
				child:Destroy()
			end
		end
		for i = 1, newMax do
			heart(heartsRow, i)
		end
	end
	for i = 1, newMax do
		local holder = heartsRow:FindFirstChild("Heart" .. i)
		if holder then
			local full = i <= newLives
			local was = i <= lives
			for _, f in holder:GetChildren() do
				if f:IsA("Frame") then
					Kit.tween(f, 0.25, { BackgroundColor3 = if full then C.Bad else C.Well })
				end
			end
			local pop = holder:FindFirstChild("Pop") :: UIScale?
			if animate and pop and was ~= full then
				pop.Scale = if full then 0.4 else 1.6
				Kit.tween(pop, 0.45, { Scale = 1 }, Enum.EasingStyle.Back)
			end
		end
	end
	lives, maxLives = newLives, newMax
end

-- Banner, dots, timer -----------------------------------------------------------------------

local function showBanner(text: string, sub: string?, color: Color3?)
	banner.Text = text
	banner.TextColor3 = color or C.Text
	banner.Visible = true
	subBanner.Text = sub or ""
	subBanner.Visible = sub ~= nil
	Kit.pop(banner, 1.25)
end

local function setGoal()
	goalLabel.Text = if best >= passRound then "BEST " .. best else "PASS AT " .. passRound
end

local function setRound(round: number)
	roundLabel.Text = "ROUND " .. round
	Kit.pop(roundLabel, 1.1)
end

local function buildDots(count: number)
	for _, child in dotsRow:GetChildren() do
		if child:IsA("Frame") then
			child:Destroy()
		end
	end
	-- Up to 14 dots at full size; past that the gap and the dots shrink so even MAX_ROUND
	-- (30) fits inside the pill.
	local gap = if count > 14 then 3 else 6
	local size = math.clamp(math.floor((DOTS_WIDTH - (count - 1) * gap) / math.max(count, 1)), 8, 20)
	dotsList.Padding = UDim.new(0, gap)
	for i = 1, count do
		local dot = Kit.new("Frame", {
			Name = "Dot" .. i,
			BackgroundColor3 = C.Well,
			BackgroundTransparency = 0.15,
			Size = UDim2.fromOffset(size, size),
			LayoutOrder = i,
			Parent = dotsRow,
		})
		Kit.round(dot)
		Kit.stroke(dot, 2, C.Ink)
	end
end

local function paintDot(i: number, color: Color3?, flash: boolean?)
	local dot = dotsRow:FindFirstChild("Dot" .. i) :: Frame?
	if not dot then
		return
	end
	dot.BackgroundColor3 = color or C.Well
	if flash then
		Kit.pop(dot, 1.5)
	end
end

local function stopTimer()
	if timerConn then
		timerConn:Disconnect()
		timerConn = nil
	end
	timerBack.Visible = false
end

-- The bar under the dots: time left for the next flex (resets on every right press).
local function startTimer()
	stopTimer()
	turnAt = os.clock()
	timerBack.Visible = true
	timerConn = RunService.RenderStepped:Connect(function()
		local left = math.clamp(1 - (os.clock() - turnAt) / timeout, 0, 1)
		timerFill.Size = UDim2.fromScale(left, 1)
		timerFill.BackgroundColor3 = if left < 0.3 then C.Bad else C.Good
	end)
end

-- Flex pad ---------------------------------------------------------------------------------

local function shadePad(on: boolean)
	for _, shade in shades do
		Kit.tween(shade, 0.18, { BackgroundTransparency = if on then 0.5 else 1 })
	end
end

local lightTokens: { [number]: number } = {}
local function lightButton(i: number, hold: number)
	local button = buttons[i]
	local scale = pops[i]
	if not button or not scale then
		return
	end
	Kit.setGlow(button, true, FLEXES[i].color)
	scale.Scale = 1.14
	Kit.tween(scale, 0.25, { Scale = 1 }, Enum.EasingStyle.Back)
	local mine = (lightTokens[i] or 0) + 1
	lightTokens[i] = mine
	task.delay(hold, function()
		if lightTokens[i] == mine then
			Kit.setGlow(button, false)
		end
	end)
end

local function press(i: number)
	if not running or phase ~= "turn" or not FLEXES[i] then
		return
	end
	local step = done + 1
	local ok = seq[step] == i
	action:FireServer({ action = "PoseInput", flex = i, step = step })
	PoseFx.playerFlex(i, ok)
	lightButton(i, 0.3)
	if ok then
		done = step
		paintDot(step, FLEXES[i].color, true)
		Sounds.play("Pickup", 0.06, 1 + step * 0.04)
		if done >= #seq then
			-- The server's "clear" follows.
			phase = "wait"
			stopTimer()
			shadePad(true)
		else
			turnAt = os.clock()
		end
	else
		-- The server's "miss" follows (hearts there).
		phase = "wait"
		stopTimer()
		shadePad(true)
		Sounds.play("Error")
		showBanner("OOPS!", "It was " .. FLEXES[seq[step]].label, C.Bad)
	end
end

local function onAction(_name: string, state: Enum.UserInputState, input: InputObject): Enum.ContextActionResult
	if state == Enum.UserInputState.Begin then
		local i = KEYS[input.KeyCode]
		if i then
			press(i)
		end
	end
	-- Sunk either way: the player is held on the podium and the keys only flex.
	return Enum.ContextActionResult.Sink
end

local function bind()
	local keys = {}
	for key in KEYS do
		table.insert(keys, key)
	end
	ContextActionService:BindActionAtPriority(ACTION, onAction, false, PRIORITY, table.unpack(keys))
	ContextActionService:BindActionAtPriority(QUIT_ACTION, function(_, state)
		if state == Enum.UserInputState.Begin then
			quitPress()
		end
		return Enum.ContextActionResult.Sink
	end, false, PRIORITY, Enum.KeyCode.ButtonY, Enum.KeyCode.ButtonB)
end

local function unbind()
	ContextActionService:UnbindAction(ACTION)
	ContextActionService:UnbindAction(QUIT_ACTION)
end

-- Show -------------------------------------------------------------------------------------

local function onRound(p: any)
	beat += 1
	local mine = beat
	seq = {}
	if type(p.seq) == "table" then
		for i, flex in p.seq do
			seq[i] = math.clamp(math.floor(num(flex, 1)), 1, #FLEXES)
		end
	end
	done = 0
	phase = "watch"
	stopTimer()
	shadePad(true)
	setRound(math.max(1, #seq))
	setHearts(num(p.hearts, lives), maxLives, false)
	buildDots(#seq)
	showBanner("WATCH!", if p.replay then "Watch again..." else "Copy the Chad's flexes", C.Gold)
	local step = num(p.step, 0.9)
	local lead = num(p.lead, 1.2)
	for i, flex in seq do
		task.delay(lead + (i - 1) * step, function()
			if beat ~= mine or not running then
				return
			end
			PoseFx.rivalFlex(flex, step * 0.75)
			lightButton(flex, step * 0.7)
			paintDot(i, FLEXES[flex].color, true)
			Sounds.play("Tick", 0.04, 0.9 + (flex - 1) * 0.12)
			task.delay(step * 0.75, function()
				if beat == mine and phase == "watch" then
					paintDot(i, nil)
				end
			end)
		end)
	end
	task.delay(num(p.length, lead + #seq * step + 0.35), function()
		if beat ~= mine or not running then
			return
		end
		phase = "turn"
		for i = 1, #seq do
			paintDot(i, nil)
		end
		shadePad(false)
		showBanner("YOUR TURN!", if Kit.touch then "Tap the flexes" else Kit.hint("", "Arrow keys or WASD", "D-pad"), C.Good)
		Sounds.play("Ready")
		startTimer()
	end)
end

-- Finish card ------------------------------------------------------------------------------

local function hideCard()
	if card.Visible then
		Kit.disappear(card)
	end
end

local function showCard(p: any, won: boolean)
	local cleared = math.floor(num(p.cleared, 0))
	best = math.floor(num(p.best, best))
	cardTitle.Text = if won then "TEST PASSED!" else "NICE TRY!"
	cardTitle.TextColor3 = if won then C.Gold else C.Text
	cardLines.Text = "Longest copy: " .. cleared .. (if cleared == 1 then " flex" else " flexes")
	cardBest.Text = if p.newBest then "NEW BEST!" else "Best " .. best
	cardBest.TextColor3 = if p.newBest then C.Gold else C.TextDim
	local cash = num(p.cash, 0)
	cardCash.Text = if cash > 0 and p.pay == "first"
		then "First clear! +" .. Format.money(cash)
		elseif cash > 0 and p.pay == "repeat" then "Run again bonus +" .. Format.money(cash)
		elseif cash > 0 then "+" .. Format.money(cash)
		elseif won then "Pass bonus resting. Great posing!"
		else "Copy " .. passRound .. " flexes to pass!"
	cardCash.TextColor3 = if cash > 0 then C.Good else C.TextDim
	card.Visible = true
	Kit.appear(card)
	if won then
		Kit.confetti(card, { Origin = UDim2.fromScale(0.5, 0.2), Count = 40, ZIndex = 41, Power = 1.1 })
	end
end

-- Run --------------------------------------------------------------------------------------

local function hide()
	running = false
	phase = "intro"
	beat += 1
	quitArmed = false
	unbind()
	stopTimer()
	Kit.hidePlayerList("pose", false)
	Kit.hideTouchControls("pose", false)
	if screen then
		screen:SetAttribute("RunActive", false)
	end
	root.Visible = false
	for i, button in buttons do
		Kit.setGlow(button, false)
		pops[i].Scale = 1
	end
end

function PoseHud.start(payload: { [string]: any }?)
	local p: any = payload or {}
	hide()
	hideCard()
	running = true
	phase = "intro"
	passRound = math.floor(num(p.passRound, 8))
	best = math.floor(num(p.best, 0))
	timeout = num(p.timeout, 6)
	setHearts(math.floor(num(p.hearts, 3)), math.floor(num(p.maxHearts, 3)), false)
	setGoal()
	roundLabel.Text = "ROUND 1"
	buildDots(0)
	shadePad(true)
	Kit.setButton(quitButton, if Kit.gamepad then "Y" else "X", C.SurfaceHi)
	quitButton.Size = UDim2.fromOffset(30, 28)
	bind()
	Kit.hidePlayerList("pose", true)
	Kit.hideTouchControls("pose", true)
	if screen then
		screen:SetAttribute("RunActive", true)
	end
	root.Visible = true
	Kit.appear(root)
	showBanner("POSE COPY!", "Watch the Chad, then copy his flexes", C.Gold)
	Sounds.play("Ready")
end

function PoseHud.stop(_payload: { [string]: any }?)
	hide()
	hideCard()
end

function PoseHud.onNotify(payload: { [string]: any })
	local p: any = payload
	local event = p.event
	if event == "start" then
		PoseHud.start(p)
	elseif event == "stop" then
		PoseHud.stop(p)
	elseif event == "full" then
		Popups.toast(if type(p.text) == "string" then p.text else "The posing stage is full!", "info")
	elseif not running then
		return
	elseif event == "round" then
		onRound(p)
	elseif event == "clear" then
		phase = "wait"
		beat += 1
		stopTimer()
		shadePad(true)
		Sounds.play("Coin", 0.05, 1.2)
		local nextRound = math.floor(num(p.next, 1))
		showBanner("GREAT!", "Next: " .. nextRound .. " flexes", C.Good)
	elseif event == "pass" then
		best = math.max(best, math.floor(num(p.round, passRound)))
		local cash = num(p.cash, 0)
		local sub = if cash > 0 and p.pay == "repeat"
			then "Run again bonus +" .. Format.money(cash)
			elseif cash > 0 then "+" .. Format.money(cash) .. "  Keep going!"
			else "Keep going for a best!"
		showBanner("TEST PASSED!", sub, C.Gold)
		Kit.confetti(banner, { Origin = UDim2.fromScale(0.5, 0.4), Count = 50, ZIndex = 31, Power = 1.2 })
		goalLabel.Text = "BEST " .. best
	elseif event == "miss" then
		phase = "wait"
		beat += 1
		stopTimer()
		shadePad(true)
		setHearts(math.floor(num(p.hearts, lives - 1)), maxLives, true)
		local expected = FLEXES[math.floor(num(p.expected, 0))]
		local sub = if expected then "It was " .. expected.label else nil
		if p.reason == "slow" then
			Sounds.play("Error")
			showBanner("TOO SLOW!", sub, C.Bad)
		else
			showBanner("OOPS!", sub, C.Bad)
		end
	elseif event == "win" or event == "lose" then
		hide()
		showCard(p, event == "win")
	end
end

function PoseHud.onState(data: any)
	local info = type(data) == "table" and type(data.modes) == "table" and data.modes.pose
	if running and not (type(info) == "table" and info.running == true) then
		hide()
	end
end

-- Build ------------------------------------------------------------------------------------

local function fitScale(scale: UIScale)
	local function fit()
		local camera = Workspace.CurrentCamera
		local view = if camera then camera.ViewportSize else Vector2.new(1280, DESIGN_H)
		scale.Scale = math.clamp(math.min(view.Y / DESIGN_H, view.X / 900), 0.6, 1.25)
	end
	fit()
	local camera = Workspace.CurrentCamera
	if camera then
		camera:GetPropertyChangedSignal("ViewportSize"):Connect(fit)
	end
end

local function buildPad()
	local span = BUTTON * 3 + GAP * 2
	pad = Kit.new("Frame", {
		Name = "FlexPad",
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(span, span),
		Position = UDim2.new(0.5, 0, 1, -16),
		AnchorPoint = Vector2.new(0.5, 1),
		ZIndex = 20,
		Parent = root,
	})
	local scale = Kit.new("UIScale", { Parent = pad })
	fitScale(scale)
	for i, flex in FLEXES do
		local at = PLACE[flex.dir] or Vector2.zero
		local holder = Kit.new("Frame", {
			Name = "Flex" .. i,
			BackgroundTransparency = 1,
			Size = UDim2.fromOffset(BUTTON, BUTTON),
			Position = UDim2.new(0.5, at.X * (BUTTON + GAP), 0.5, at.Y * (BUTTON + GAP)),
			AnchorPoint = Vector2.new(0.5, 0.5),
			Parent = pad,
		})
		pops[i] = Kit.new("UIScale", { Parent = holder })
		local button = Kit.button(holder, {
			Name = "Button",
			Text = "",
			Color = flex.color,
			Size = UDim2.fromScale(1, 1),
			Radius = 22,
			Depth = 5,
			ZIndex = 21,
		}, function()
			press(i)
		end)
		buttons[i] = button
		-- The flex's name over the button's face, and the key chip at its top.
		Kit.text(button, {
			Name = "Flex",
			Text = (flex.label:gsub(" ", "\n", 1)),
			Font = F.Display,
			TextSize = 19,
			TextWrapped = true,
			TextColor3 = C.Text,
			StrokeThickness = 2,
			Size = UDim2.new(1, -10, 0.6, 0),
			Position = UDim2.new(0.5, 0, 0.62, 0),
			AnchorPoint = Vector2.new(0.5, 0.5),
			ZIndex = 24,
		})
		local chip = Kit.text(button, {
			Name = "Key",
			Text = CHIPS[i][1],
			Font = F.Display,
			TextSize = 15,
			TextWrapped = false,
			TextColor3 = C.Ink,
			BackgroundColor3 = C.Text,
			BackgroundTransparency = 0.05,
			StrokeThickness = 0,
			Size = UDim2.fromOffset(46, 22),
			Position = UDim2.new(0.5, 0, 0, 10),
			AnchorPoint = Vector2.new(0.5, 0),
			ZIndex = 24,
		})
		Kit.round(chip)
		local function paintChip()
			chip.Visible = not Kit.touch
			chip.Text = if Kit.gamepad then CHIPS[i][2] else CHIPS[i][1]
			chip.Size = UDim2.fromOffset(if Kit.gamepad then 62 else 30, 22)
		end
		paintChip()
		Kit.onInput(paintChip)
		local shade = Kit.new("Frame", {
			Name = "Shade",
			BackgroundColor3 = Color3.new(0, 0, 0),
			BackgroundTransparency = 0.5,
			BorderSizePixel = 0,
			Size = UDim2.fromScale(1, 1),
			Active = false,
			ZIndex = 26,
			Parent = holder,
		})
		Kit.corner(shade, 22)
		shades[i] = shade
	end
end

local function buildCard(screenGui: ScreenGui)
	card = Kit.panel(screenGui, {
		Name = "PoseCard",
		Size = UDim2.fromOffset(380, 300),
		Position = UDim2.fromScale(0.5, 0.45),
		AnchorPoint = Vector2.new(0.5, 0.5),
		Visible = false,
		ZIndex = 40,
	})
	fitScale(Kit.new("UIScale", { Parent = card }))
	cardTitle = Kit.title(card, {
		Text = "TEST PASSED!",
		TextSize = 34,
		Size = UDim2.new(1, -40, 0, 44),
		Position = UDim2.new(0.5, 0, 0, 22),
		AnchorPoint = Vector2.new(0.5, 0),
		ZIndex = 42,
	})
	cardLines = Kit.text(card, {
		Text = "",
		TextSize = 20,
		Size = UDim2.new(1, -40, 0, 26),
		Position = UDim2.new(0.5, 0, 0, 78),
		AnchorPoint = Vector2.new(0.5, 0),
		ZIndex = 42,
	})
	cardBest = Kit.text(card, {
		Text = "",
		Font = F.Display,
		TextSize = 22,
		Size = UDim2.new(1, -40, 0, 28),
		Position = UDim2.new(0.5, 0, 0, 110),
		AnchorPoint = Vector2.new(0.5, 0),
		ZIndex = 42,
	})
	cardCash = Kit.text(card, {
		Text = "",
		Font = F.Display,
		TextSize = 22,
		Size = UDim2.new(1, -40, 0, 30),
		Position = UDim2.new(0.5, 0, 0, 148),
		AnchorPoint = Vector2.new(0.5, 0),
		ZIndex = 42,
	})
	Kit.button(card, {
		Name = "Again",
		Text = "AGAIN",
		Color = C.Good,
		Size = UDim2.fromOffset(150, 52),
		Position = UDim2.new(0.5, -8, 1, -24),
		AnchorPoint = Vector2.new(1, 1),
		ZIndex = 42,
	}, function()
		hideCard()
		action:FireServer({ action = "ModeStart", mode = "pose" })
	end)
	Kit.button(card, {
		Name = "Leave",
		Text = "LEAVE",
		Color = C.SurfaceHi,
		Size = UDim2.fromOffset(150, 52),
		Position = UDim2.new(0.5, 8, 1, -24),
		AnchorPoint = Vector2.new(0, 1),
		ZIndex = 42,
	}, function()
		hideCard()
		action:FireServer({ action = "GoModes" })
	end)
	Kit.button(card, {
		Name = "Close",
		Text = "X",
		Color = C.SurfaceHi,
		TextSize = 14,
		Size = UDim2.fromOffset(30, 28),
		Position = UDim2.new(1, -10, 0, 10),
		AnchorPoint = Vector2.new(1, 0),
		Radius = 14,
		Depth = 2,
		ZIndex = 43,
	}, hideCard)
end

function PoseHud.init(screenGui: ScreenGui)
	screen = screenGui
	root = Kit.new("Frame", {
		Name = "PoseHud",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		Visible = false,
		ZIndex = 20,
		Parent = screenGui,
	})

	-- Top: a glass pill with the round, the goal, the hearts and the quit button.
	local top = Kit.new("Frame", {
		Name = "Top",
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(420, 150),
		Position = UDim2.new(0.5, 0, 0, 58),
		AnchorPoint = Vector2.new(0.5, 0),
		Parent = root,
	})
	fitScale(Kit.new("UIScale", { Parent = top }))
	local pill = Kit.hudGlass(top, {
		Name = "Round",
		Size = UDim2.fromOffset(380, 48),
		Position = UDim2.new(0.5, 0, 0, 0),
		AnchorPoint = Vector2.new(0.5, 0),
	})
	roundLabel = Kit.hudText(pill, {
		Name = "Round",
		Text = "ROUND 1",
		Font = F.Display,
		TextSize = 24,
		StrokeThickness = 2,
		TextXAlignment = Enum.TextXAlignment.Left,
		Size = UDim2.fromOffset(130, 48),
		Position = UDim2.fromOffset(16, 0),
		ZIndex = 3,
	})
	goalLabel = Kit.text(pill, {
		Name = "Goal",
		Text = "PASS AT 8",
		Font = F.Display,
		TextSize = 14,
		TextWrapped = false,
		TextColor3 = C.GoldInk,
		BackgroundColor3 = C.Gold,
		BackgroundTransparency = 0,
		StrokeThickness = 0,
		Size = UDim2.fromOffset(92, 24),
		Position = UDim2.fromOffset(146, 12),
		ZIndex = 3,
	})
	Kit.round(goalLabel)
	heartsRow = Kit.new("Frame", {
		Name = "Hearts",
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(100, 28),
		Position = UDim2.new(1, -46, 0.5, 0),
		AnchorPoint = Vector2.new(1, 0.5),
		ZIndex = 3,
		Parent = pill,
	})
	Kit.list(heartsRow, 2, true, Enum.HorizontalAlignment.Right)
	quitButton = Kit.button(pill, {
		Name = "Quit",
		Text = "X",
		Color = C.SurfaceHi,
		TextSize = 14,
		Size = UDim2.fromOffset(30, 28),
		Position = UDim2.new(1, -8, 0.5, 0),
		AnchorPoint = Vector2.new(1, 0.5),
		Radius = 14,
		Depth = 2,
		ZIndex = 4,
	}, function()
		quitPress()
	end)
	Kit.selectable(quitButton)
	local quitHit = Kit.hitArea(quitButton, 48, function()
		Kit.sound("Click")
		quitPress()
	end)
	quitHit.Visible = Kit.touch
	Kit.onInput(function()
		quitHit.Visible = Kit.touch
	end)
	quitPress = function()
		if quitArmed then
			quitArmed = false
			action:FireServer({ action = "ModeQuit" })
			return
		end
		-- First tap arms it: "QUIT?" for a few seconds.
		quitArmed = true
		Kit.setButton(quitButton, "QUIT?", C.Bad)
		Kit.tween(quitButton, 0.2, { Size = UDim2.fromOffset(64, 28) }, Enum.EasingStyle.Back)
		task.delay(3, function()
			if quitArmed then
				quitArmed = false
				Kit.setButton(quitButton, if Kit.gamepad then "Y" else "X", C.SurfaceHi)
				Kit.tween(quitButton, 0.2, { Size = UDim2.fromOffset(30, 28) })
			end
		end)
	end

	-- Banner, its sub line, the dots and the turn timer under the pill.
	banner = Kit.hudText(top, {
		Name = "Banner",
		Text = "",
		Font = F.Display,
		TextSize = 44,
		StrokeThickness = 3,
		Size = UDim2.new(1, 0, 0, 50),
		Position = UDim2.new(0.5, 0, 0, 56),
		AnchorPoint = Vector2.new(0.5, 0),
		ZIndex = 30,
	})
	subBanner = Kit.hudText(top, {
		Name = "Sub",
		Text = "",
		Font = F.Display,
		TextSize = 18,
		StrokeThickness = 2,
		Size = UDim2.new(1, 0, 0, 22),
		Position = UDim2.new(0.5, 0, 0, 104),
		AnchorPoint = Vector2.new(0.5, 0),
		ZIndex = 30,
	})
	dotsRow = Kit.new("Frame", {
		Name = "Dots",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 22),
		Position = UDim2.new(0.5, 0, 0, 132),
		AnchorPoint = Vector2.new(0.5, 0),
		Parent = top,
	})
	dotsList = Kit.list(dotsRow, 6, true, Enum.HorizontalAlignment.Center)
	timerBack = Kit.new("Frame", {
		Name = "Timer",
		BackgroundColor3 = C.Well,
		BorderSizePixel = 0,
		Size = UDim2.fromOffset(200, 8),
		Position = UDim2.new(0.5, 0, 0, 160),
		AnchorPoint = Vector2.new(0.5, 0),
		Visible = false,
		Parent = top,
	})
	Kit.round(timerBack)
	timerFill = Kit.new("Frame", {
		Name = "Fill",
		BackgroundColor3 = C.Good,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1),
		Parent = timerBack,
	})
	Kit.round(timerFill)

	buildPad()
	buildCard(screenGui)
end

return PoseHud
