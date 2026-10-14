--!strict
--[[
	PoseHud: the screen side of POSE COPY (Modes.Pose; docs/minigames.md). Fx.Pose does
	the 3D side; this HUD runs the show's beats (it calls Fx.Pose.rivalFlex on every flex
	the rival shows and Fx.Pose.playerFlex on every press) so both stay on one clock.

	A stay goes lobby -> countdown -> play -> results -> lobby (snapshot modes.pose.phase):
	  Lobby card   right side (top right on touch): POSE COPY, the goal ("Copy 8 flexes to
	               pass"), how to play ("Watch the Chad, then copy his flexes" over chips
	               for the current input: ARROWS / WASD, D-PAD or TAP THE BUTTONS), BEST
	               and CLEARS, the reward status (full pack ready, or the time
	               to the next one and what a pass pays now), a big PLAY button (tap, Enter,
	               gamepad X: A stays jump; sends "PoseBegin") and LEAVE ("ModeQuit"; B arms
	               it on a controller, a second B confirms).
	  Rehearsal    standing at the arena's "RehearsalSpot" in the lobby shows the flex pad
	               with a floating "Practise your flexes" hint and the mirror's reflection
	               (Fx.Pose.mirror); the pad, the arrow keys and the D-pad strike the flex on
	               the avatar (Fx.Pose.rehearse). Nothing is sent; WASD still walk (and do
	               not flex there), so stepping off ends it.
	  Countdown    a big 3, 2, 1, GO! before the first show; the game HUD comes up.
	  Play         Top pill: "ROUND n" with the goal ("PASS AT 8", then "BEST n"), the
	               hearts and the quiet quit button (X; first tap arms "QUIT?", the second
	               fires ModeQuit; Y / B on a controller).
	               Banner: "WATCH!" while the rival shows the round (each flex's name flashes
	               under it in its colour), "YOUR TURN!" when the player copies it,
	               "GREAT!" / "OOPS!" / "TOO SLOW!" / "TEST PASSED!" between.
	               Dots: one per flex of the round (past DOT_PAGE flexes a page of them at
	               a time, "25+" in front); a thin bar under them counts down the time left
	               for the next flex (ticks when it runs low). "BONUS!" at every replay
	               milestone (12, 16, 20... flexes) with its cash.
	               Flex pad: four big buttons in a D-pad (up DOUBLE BICEPS, left SIDE CHEST,
	               right LAT SPREAD, down MOST MUSCULAR) in the flexes' colours, sized for
	               thumbs (bottom right on phones so the chads stay in view); the arrow keys,
	               WASD and the D-pad press them. Shaded while the rival shows, each lights
	               up as its flex is shown; a wrong press flashes red and lights the right one.
	               A press before every flex was shown (the round's `open`) is only a nudge;
	               after it, it starts the turn early (the server's rule too).
	  Results      after "win" / "lose" (CARD_DELAY s later, docked right like the lobby
	               card so the avatar's finale in the middle stays in view): flexes copied,
	               the run's title (BRONZE / SILVER / GOLD POSER, else the first to reach),
	               the best (NEW BEST! pulses), the pay and any milestone bonus, PLAY AGAIN
	               (Enter / X; "PoseBegin") and LOBBY (B; "PoseLobby"). It goes on the
	               server's "lobby" after the payload's resultsTime (or the snapshot's phase
	               back to "lobby").
	  Lobby again  "lobby" { reason } puts the lobby card back; "bumped" (another player
	               needed the podium) and "full" (every podium busy) say so in a toast.
	The arena's "BestBoard" SurfaceGui gets its "Best", "Clears" and "Reward" TextLabels
	filled from the snapshot, each with its caption ("BEST: 5 FLEXES"; a missing piece is
	skipped). The player list is hidden for the whole stay, the touch thumbstick during
	countdown and play.

	Wired from Main.client.luau (nothing else needs editing):
	  init(screen)        once, builds the HUD (hidden)
	  onNotify(payload)   every Notify with kind = "Mode" and mode = "pose"
	  onState(data)       every State snapshot (phase changes, board, safety net)
	  start(payload) / stop(payload)
]]

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
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
local BACK_ACTION = "PoseBack"
local CONFIRM_ACTION = "PoseConfirm"
local PRIORITY = 3000
local BUTTON = 112 -- flex button size (design px)
local GAP = 10
local DESIGN_H = 760 -- screen height the HUD is laid out for (UIScale beyond it)
-- Feet within this many studs (flat) of the "RehearsalSpot" part warm up at the mirror.
local REHEARSE_RADIUS = 9
-- The results card's own way back if the snapshot's "lobby" never comes: this long past
-- resultsTime (s).
local RESULTS_FALLBACK = 3
-- The server's own return to the lobby: the "win" / "lose" payload's resultsTime.
local resultsTime = 8
-- The results card waits this long after "win" / "lose": the finale's first beat is seen whole.
local CARD_DELAY = 1.2
-- Past this many flexes in a round the dots row shows one page of them at a time.
local DOT_PAGE = 24

-- Which flex each key strikes (arrows, WASD, D-pad). At the mirror WASD only walk.
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
local WALK_KEYS = { [Enum.KeyCode.W] = true, [Enum.KeyCode.A] = true, [Enum.KeyCode.S] = true, [Enum.KeyCode.D] = true }
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
local localPlayer = Players.LocalPlayer

local screen: ScreenGui? = nil
local root: Frame = nil :: any
local top: Frame = nil :: any
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
local rehearseHint: TextLabel = nil :: any
local countLabel: TextLabel = nil :: any
local countScale: UIScale = nil :: any
local card: Frame = nil :: any
local cardTitle: TextLabel = nil :: any
local cardLines: TextLabel = nil :: any
local cardCash: TextLabel = nil :: any
local cardBest: TextLabel = nil :: any
local cardTimer: TextLabel = nil :: any
local cardTrophy: TextLabel = nil :: any
local lobby: Frame = nil :: any
local lobbyGoal: TextLabel = nil :: any
local lobbyBest: TextLabel = nil :: any
local lobbyClears: TextLabel = nil :: any
local lobbyReward: TextLabel = nil :: any
local playButton: TextButton = nil :: any
local leaveButton: TextButton = nil :: any
local buttons: { TextButton } = {}
local shades: { Frame } = {}
local pops: { UIScale } = {}

-- "off" | "lobby" | "countdown" | "play" | "results": where this player's stay is.
local stage = "off"
-- A game is on screen (countdown or play): the pad's presses count.
local running = false
-- Inside play: "intro" | "watch" | "turn" | "wait"; only "turn" takes presses. A press in
-- "watch" once every flex has been shown (openAt: the round's `open`, PoseRules.pressOpen,
-- the server's own rule) starts the turn early; before that it is only a nudge.
local phase = "intro"
local beat = 0 -- bumps on every round / stop, so stale show timers do nothing
local openAt = math.huge
local seq: { number } = {}
local done = 0
local lives, maxLives = 3, 3
local passRound = 8
local best = 0
local clears = 0
local timeout = 6
local turnAt = 0
local lowTicked = false
local quitArmed = false
local quitPress: () -> () = function() end
local leaveArmed = false
local leavePress: () -> () = function() end
local timerConn: RBXScriptConnection? = nil
local rehearsing = false
local bobStop: (() -> ())? = nil
local bestStop: (() -> ())? = nil
local beginAt = -math.huge -- last "PoseBegin" sent (one per press burst)
local playAt = -math.huge -- the countdown arrived (a stale "lobby" snapshot is ignored)
local resultsAt = 0
local cardToken = 0
-- The round's dots: how many, and the page (0-based, DOT_PAGE dots each) on screen.
local dotCount, dotPage = 0, -1
local lobbyConn: RBXScriptConnection? = nil
-- The snapshot's reward status (modes.pose): rewardPreview and cooldownEnds.
local reward: { [string]: any } = {}
local cooldownEnds = 0

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
	subBanner.TextColor3 = C.Text
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

-- The dots of page `page` (0-based): up to 14 at full size, past that the gap and the dots
-- shrink; a round longer than DOT_PAGE shows one page at a time ("25+" in front), so even
-- MAX_ROUND (99) fits inside the pill.
local function showDotPage(page: number)
	dotPage = page
	for _, child in dotsRow:GetChildren() do
		if child:IsA("GuiObject") then
			child:Destroy()
		end
	end
	local first = page * DOT_PAGE + 1
	local last = math.min(dotCount, first + DOT_PAGE - 1)
	local shown = math.max(0, last - first + 1)
	local width = DOTS_WIDTH
	if page > 0 then
		local tag = first .. "+"
		Kit.text(dotsRow, {
			Name = "Page",
			Text = tag,
			Font = F.Display,
			TextSize = 16,
			Size = UDim2.fromOffset(12 + #tag * 9, 20),
			LayoutOrder = 0,
		})
		width -= 12 + #tag * 9 + 3
	end
	local gap = if dotCount > 14 then 3 else 6
	local size = math.clamp(math.floor((width - (shown - 1) * gap) / math.max(shown, 1)), 8, 20)
	dotsList.Padding = UDim.new(0, gap)
	for i = first, last do
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

local function buildDots(count: number)
	dotCount = count
	showDotPage(0)
end

local function paintDot(i: number, color: Color3?, flash: boolean?)
	local page = math.floor((i - 1) / DOT_PAGE)
	if color and page ~= dotPage and i >= 1 and i <= dotCount then
		-- The show or the turn moved on to another page's flexes (clearing a dot never
		-- turns the page).
		showDotPage(page)
	end
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
	lowTicked = false
	timerBack.Visible = true
	timerConn = RunService.RenderStepped:Connect(function()
		local left = math.clamp(1 - (os.clock() - turnAt) / timeout, 0, 1)
		timerFill.Size = UDim2.fromScale(left, 1)
		timerFill.BackgroundColor3 = if left < 0.3 then C.Bad else C.Good
		-- Running low: one tick and a pop of the bar, so the player hears the hurry.
		if left < 0.3 and not lowTicked then
			lowTicked = true
			Sounds.play("Tick", 0.02, 1.35)
			Kit.pop(timerBack, 1.6)
		elseif left >= 0.3 then
			lowTicked = false
		end
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

-- A wrong press: the button flashes red and gives a shake of a squash.
local function flashWrong(i: number)
	local button = buttons[i]
	if not button then
		return
	end
	local mine = (lightTokens[i] or 0) + 1
	lightTokens[i] = mine
	Kit.setGlow(button, true, C.Bad)
	pops[i].Scale = 0.84
	Kit.tween(pops[i], 0.35, { Scale = 1 }, Enum.EasingStyle.Back)
	task.delay(0.45, function()
		if lightTokens[i] == mine then
			Kit.setGlow(button, false)
		end
	end)
end

-- After a miss the right flex's button glows a moment, so the player sees what it was.
local function showExpected(expected: number?)
	if not expected or not FLEXES[expected] then
		return
	end
	local mine = beat
	task.delay(0.4, function()
		if beat == mine and running then
			lightButton(expected, 1.1)
		end
	end)
end

-- Layout -----------------------------------------------------------------------------------

-- The pad: bottom centre, or bottom right on phones during a game (the chads stay in view;
-- Fx.Pose frames them left of it). Shown in a game and at the rehearsal mirror.
local function layoutPad()
	local aside = running and PoseFx.compact()
	pad.AnchorPoint = if aside then Vector2.new(1, 1) else Vector2.new(0.5, 1)
	pad.Position = if aside then UDim2.new(1, -18, 1, -14) else UDim2.new(0.5, 0, 1, -16)
	pad.Visible = running or rehearsing
end

-- Presses ----------------------------------------------------------------------------------

local hintToken = 0

-- The mirror's floating hint (keyboard: only the arrows flex there, WASD walk).
local function practiseText(): string
	return Kit.hint("Practise your flexes", "Practise: arrow keys", "Practise: D-pad")
end

local function rehearse(i: number)
	PoseFx.rehearse(i)
	lightButton(i, 0.35)
	Sounds.play("Pickup", 0.04, 0.9 + (i - 1) * 0.1)
	hintToken += 1
	local mine = hintToken
	rehearseHint.Text = FLEXES[i].label .. "!"
	rehearseHint.TextColor3 = FLEXES[i].color
	Kit.pop(rehearseHint, 1.2)
	task.delay(1.2, function()
		if hintToken == mine then
			rehearseHint.Text = practiseText()
			rehearseHint.TextColor3 = C.Text
		end
	end)
end

local startTurn: () -> () = function() end

local function press(i: number)
	if not FLEXES[i] then
		return
	end
	if rehearsing and not running then
		rehearse(i)
		return
	end
	if not running then
		return
	end
	if phase == "watch" then
		if os.clock() < openAt then
			-- Too early (flexes still to come): never sent, never a heart. A nudge.
			subBanner.Text = "Watch them all, then copy!"
			subBanner.TextColor3 = C.Gold
			subBanner.Visible = true
			Kit.pop(subBanner, 1.1)
			return
		end
		-- Every flex is shown: the turn starts now (the server takes it from here too).
		startTurn()
	end
	if phase ~= "turn" then
		return
	end
	local step = done + 1
	local ok = seq[step] == i
	action:FireServer({ action = "PoseInput", flex = i, step = step })
	PoseFx.playerFlex(i, ok)
	if ok then
		lightButton(i, 0.3)
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
		flashWrong(i)
		paintDot(step, C.Bad, true)
		Sounds.play("Error")
		showBanner("OOPS!", "It was " .. FLEXES[seq[step]].label, C.Bad)
		showExpected(seq[step])
	end
end

-- Bindings ---------------------------------------------------------------------------------

local begin: () -> () = function() end
local toLobby: () -> () = function() end
local leaveResults: () -> () = function() end

local function onAction(_name: string, state: Enum.UserInputState, input: InputObject): Enum.ContextActionResult
	-- In a game the player is held on the podium and every key only flexes. At the mirror
	-- WASD keep walking (and do not flex: the avatar would turn and step), so stepping off
	-- is always possible; the arrows and the D-pad flex there.
	if not running and WALK_KEYS[input.KeyCode] then
		return Enum.ContextActionResult.Pass
	end
	if state == Enum.UserInputState.Begin then
		local i = KEYS[input.KeyCode]
		if i then
			press(i)
		end
	end
	return Enum.ContextActionResult.Sink
end

local function onBack(_name: string, state: Enum.UserInputState): Enum.ContextActionResult
	if state == Enum.UserInputState.Begin then
		if running then
			quitPress()
		elseif stage == "lobby" then
			leavePress()
		elseif stage == "results" then
			leaveResults()
		end
	end
	return Enum.ContextActionResult.Sink
end

local function onConfirm(_name: string, state: Enum.UserInputState): Enum.ContextActionResult
	if state == Enum.UserInputState.Begin and (stage == "lobby" or stage == "results") then
		begin()
	end
	return Enum.ContextActionResult.Sink
end

-- Binds what the current stage needs: the flex keys in a game and at the mirror, Enter / X
-- for PLAY in the lobby and results (gamepad A stays jump), B / Y for quit, leave or lobby.
local function rebind()
	ContextActionService:UnbindAction(ACTION)
	ContextActionService:UnbindAction(BACK_ACTION)
	ContextActionService:UnbindAction(CONFIRM_ACTION)
	if stage == "off" then
		return
	end
	if running or rehearsing then
		local keys = {}
		for key in KEYS do
			table.insert(keys, key)
		end
		ContextActionService:BindActionAtPriority(ACTION, onAction, false, PRIORITY, table.unpack(keys))
	end
	ContextActionService:BindActionAtPriority(BACK_ACTION, onBack, false, PRIORITY, Enum.KeyCode.ButtonY, Enum.KeyCode.ButtonB)
	if stage == "lobby" or stage == "results" then
		ContextActionService:BindActionAtPriority(
			CONFIRM_ACTION,
			onConfirm,
			false,
			PRIORITY,
			Enum.KeyCode.Return,
			Enum.KeyCode.KeypadEnter,
			Enum.KeyCode.ButtonX
		)
	end
end

-- Show -------------------------------------------------------------------------------------

-- The player's turn: the pad goes live (at the show's end, or on an early press once every
-- flex was shown).
startTurn = function()
	phase = "turn"
	-- Every dot blank again, from the first page.
	showDotPage(0)
	shadePad(false)
	-- Every button bumps once: the pad is live.
	for _, scale in pops do
		scale.Scale = 1.08
		Kit.tween(scale, 0.3, { Scale = 1 }, Enum.EasingStyle.Back)
	end
	showBanner(
		"YOUR TURN!",
		if Kit.touch then "Tap the " .. #seq .. (if #seq == 1 then " flex" else " flexes") else Kit.hint("", "Arrow keys or WASD", "D-pad"),
		C.Good
	)
	Sounds.play("Ready")
	startTimer()
end

local function onRound(p: any)
	beat += 1
	local mine = beat
	-- The server sends only the flex each round adds (round n plays the first n): the run's
	-- sequence is kept here. Round 1 starts it; a replay keeps it.
	local round = math.max(1, math.floor(num(p.round, #seq + 1)))
	if round == 1 then
		seq = {}
	end
	for i = #seq, round + 1, -1 do
		seq[i] = nil
	end
	if #seq == round - 1 and type(p.add) == "number" then
		seq[round] = math.clamp(math.floor(p.add), 1, #FLEXES)
	end
	done = 0
	phase = "watch"
	stopTimer()
	shadePad(true)
	setRound(round)
	setHearts(num(p.hearts, lives), maxLives, false)
	buildDots(#seq)
	showBanner("WATCH!", if p.replay then "Watch again..." else "Copy the Chad's flexes", C.Gold)
	local step = num(p.step, 0.9)
	local lead = num(p.lead, 1.2)
	openAt = os.clock() + num(p.open, lead + (#seq - 0.5) * step)
	for i, flex in seq do
		task.delay(lead + (i - 1) * step, function()
			if beat ~= mine or not running then
				return
			end
			PoseFx.rivalFlex(flex, step * 0.75)
			lightButton(flex, step * 0.7)
			paintDot(i, FLEXES[flex].color, true)
			-- The flex's name under WATCH!, in its colour: the show reads without sound too.
			subBanner.Text = FLEXES[flex].label
			subBanner.TextColor3 = FLEXES[flex].color
			subBanner.Visible = true
			Kit.pop(subBanner, 1.15)
			Sounds.play("Tick", 0.04, 0.9 + (flex - 1) * 0.12)
			task.delay(step * 0.75, function()
				if beat == mine and phase == "watch" then
					paintDot(i, nil)
				end
			end)
		end)
	end
	task.delay(num(p.length, lead + #seq * step + 0.35), function()
		-- Not if a press already started the turn early.
		if beat ~= mine or not running or phase ~= "watch" then
			return
		end
		startTurn()
	end)
end

-- Countdown --------------------------------------------------------------------------------

local countToken = 0

local function showCountdown(seconds: number)
	countToken += 1
	local mine = countToken
	local n = math.clamp(math.floor(seconds + 0.5), 1, 9)
	for k = 0, n do
		task.delay(k, function()
			if countToken ~= mine then
				return
			end
			local go = k == n
			countLabel.Text = if go then "GO!" else tostring(n - k)
			countLabel.TextColor3 = if go then C.Good else FLEXES[((n - k - 1) % #FLEXES) + 1].color
			countLabel.Visible = true
			countScale.Scale = 1.9
			Kit.tween(countScale, 0.35, { Scale = 1 }, Enum.EasingStyle.Back)
			if go then
				Sounds.play("Ready")
				task.delay(0.6, function()
					if countToken == mine then
						Kit.tween(countScale, 0.2, { Scale = 0.2 })
						task.delay(0.2, function()
							if countToken == mine then
								countLabel.Visible = false
							end
						end)
					end
				end)
			else
				Sounds.play("Tick", 0.02, 0.9 + k * 0.1)
			end
		end)
	end
end

local function hideCountdown()
	countToken += 1
	countLabel.Visible = false
end

-- Reward status, lobby card, best board -----------------------------------------------------

local function cooldownLeft(): number
	return math.max(0, math.ceil(cooldownEnds - os.time()))
end

-- The lobby card's reward lines: the full pack ready, or when it is and what a pass pays now.
local function rewardStatus(): (string, Color3)
	local cash = num(reward.cash, 0)
	local pack = math.max(num(reward.packCash, 0), cash)
	if reward.full == true then
		local head = if clears == 0 then "First clear pays the full pack" else "Full pack ready"
		return head .. ": +" .. Format.money(pack), C.Good
	end
	local left = cooldownLeft()
	local line = if left > 0 then "Next full pack in " .. Format.time(left) else "Full pack ready soon"
	local repeatCash = num(reward.repeatCash, 0)
	local now = if repeatCash > 0 then "A pass now pays +" .. Format.money(repeatCash) else "Pass cash refills soon. Go for a trophy!"
	return line .. "\n" .. now, C.TextDim
end

-- The board's reward line (captioned: the board's label is the whole line).
local function boardReward(): string
	if reward.full == true then
		return "REWARD READY: +" .. Format.money(math.max(num(reward.packCash, 0), num(reward.cash, 0)))
	end
	local left = cooldownLeft()
	return if left > 0 then "NEXT REWARD IN " .. Format.time(left) else "REWARD READY SOON"
end

local function refreshLobby()
	lobbyGoal.Text = "Copy " .. passRound .. " flexes to pass"
	lobbyBest.Text = tostring(best)
	lobbyClears.Text = tostring(clears)
	local text, color = rewardStatus()
	lobbyReward.Text = text
	lobbyReward.TextColor3 = color
end

local boardCache: Instance? = nil
local boardMissAt = -math.huge

-- The arena's "BestBoard" (a SurfaceGui, or the part carrying it); nil while absent.
local function board(): Instance?
	if boardCache and boardCache.Parent then
		return boardCache
	end
	boardCache = nil
	if os.clock() - boardMissAt < 2 then
		return nil
	end
	boardCache = PoseFx.find("BestBoard")
	if not boardCache then
		boardMissAt = os.clock()
	end
	return boardCache
end

local function setBoardLabel(holder: Instance, name: string, text: string)
	local found = holder:FindFirstChild(name, true)
	if found and found:IsA("TextLabel") and found.Text ~= text then
		found.Text = text
	end
end

local function fillBoard()
	local b = board()
	if b then
		setBoardLabel(b, "Title", "YOUR BEST")
		setBoardLabel(b, "Best", "BEST: " .. best .. (if best == 1 then " FLEX" else " FLEXES"))
		setBoardLabel(b, "Clears", "CLEARS: " .. clears)
		setBoardLabel(b, "Reward", boardReward())
	end
end

-- Rehearsal mirror ---------------------------------------------------------------------------

local spotCache: BasePart? = nil
local spotMissAt = -math.huge

local function rehearsalSpot(): BasePart?
	if spotCache and spotCache.Parent then
		return spotCache
	end
	spotCache = nil
	if os.clock() - spotMissAt < 2 then
		return nil
	end
	local found = PoseFx.find("RehearsalSpot")
	if found and found:IsA("BasePart") then
		spotCache = found
	else
		spotMissAt = os.clock()
	end
	return spotCache
end

local function nearMirror(): boolean
	local spot = rehearsalSpot()
	local character = localPlayer.Character
	local rootPart = character and character:FindFirstChild("HumanoidRootPart")
	if not spot or not rootPart or not rootPart:IsA("BasePart") then
		return false
	end
	local d = rootPart.Position - spot.Position
	return Vector3.new(d.X, 0, d.Z).Magnitude <= REHEARSE_RADIUS and math.abs(d.Y) < 10
end

local function setRehearse(on: boolean)
	if rehearsing == on then
		return
	end
	rehearsing = on
	if bobStop then
		bobStop()
		bobStop = nil
	end
	PoseFx.mirror(on)
	if on then
		shadePad(false)
		rehearseHint.Text = practiseText()
		rehearseHint.TextColor3 = C.Text
		rehearseHint.Visible = true
		bobStop = Kit.bob(rehearseHint, 6, 1.3)
		Sounds.play("Pickup", 0.02, 1.2)
	else
		rehearseHint.Visible = false
		for i, button in buttons do
			Kit.setGlow(button, false)
			pops[i].Scale = 1
		end
	end
	layoutPad()
	rebind()
end

-- Results card -----------------------------------------------------------------------------

local function hideCard()
	cardToken += 1
	if bestStop then
		bestStop()
		bestStop = nil
	end
	if card.Visible then
		Kit.disappear(card)
	end
end

-- Each title's colour on the card and the milestone banner.
local TROPHY_COLORS = {
	["BRONZE POSER"] = Color3.fromRGB(232, 146, 74),
	["SILVER POSER"] = Color3.fromRGB(206, 222, 240),
	["GOLD POSER"] = Color3.fromRGB(255, 208, 60),
}

local function trophyColor(name: string): Color3
	return TROPHY_COLORS[name] or C.Gold
end

local function showCard(p: any, won: boolean)
	local cleared = math.floor(num(p.cleared, 0))
	best = math.floor(num(p.best, best))
	cardTitle.Text = if won then "TEST PASSED!" else "NICE TRY!"
	cardTitle.TextColor3 = if won then C.Gold else C.Text
	cardLines.Text = "Flexes copied: " .. cleared
	local trophy = if type(p.trophy) == "string" then p.trophy else nil
	local nextTrophy = if type(p.nextTrophy) == "string" then p.nextTrophy else nil
	local nextAt = math.floor(num(p.nextTrophyAt, 0))
	if trophy then
		cardTrophy.Text = trophy .. "!"
		cardTrophy.TextColor3 = trophyColor(trophy)
	elseif nextTrophy and nextAt > 0 then
		cardTrophy.Text = "Copy " .. nextAt .. " for " .. nextTrophy
		cardTrophy.TextColor3 = C.TextDim
	else
		cardTrophy.Text = ""
	end
	cardBest.Text = if p.newBest then "NEW BEST: " .. best .. "!" else "Best " .. best
	cardBest.TextColor3 = if p.newBest then C.Gold else C.TextDim
	local cash = num(p.cash, 0)
	cardCash.Text = if cash > 0 and p.pay == "first"
		then "First clear! +" .. Format.money(cash)
		elseif cash > 0 and p.pay == "repeat" then "Run again bonus +" .. Format.money(cash)
		elseif cash > 0 then "Full pack! +" .. Format.money(cash)
		elseif won then "Great posing! Pass cash refills soon"
		else "Copy " .. passRound .. " flexes to pass!"
	cardCash.TextColor3 = if cash > 0 then C.Good else C.TextDim
	local bonus = num(p.bonus, 0)
	if bonus > 0 then
		cardCash.Text ..= "\nMilestone bonus +" .. Format.money(bonus)
		cardCash.TextColor3 = C.Good
	end
	cardTimer.Text = ""
	-- The finale plays first (the card is docked aside anyway).
	cardToken += 1
	local mine = cardToken
	task.delay(CARD_DELAY, function()
		if cardToken ~= mine or stage ~= "results" then
			return
		end
		card.Visible = true
		Kit.appear(card)
		if won then
			Kit.confetti(card, { Origin = UDim2.fromScale(0.5, 0.2), Count = 40, ZIndex = 41, Power = 1.1 })
			Sounds.play("Celebrate")
		end
		if trophy then
			Kit.pop(cardTrophy, 1.4)
		end
		if p.newBest then
			-- NEW BEST flashes: three pops and a twinkle while the card is up.
			bestStop = Kit.twinkle(cardBest, { ZIndex = 46 })
			for k = 0, 2 do
				task.delay(0.25 + k * 0.45, function()
					if card.Visible then
						Kit.pop(cardBest, 1.5)
					end
				end)
			end
			if not won then
				Sounds.play("Step")
			end
		end
	end)
end

-- Stages -----------------------------------------------------------------------------------

-- The game's screen goes (the show, the timer, the pad, the countdown); the stay goes on.
local function stopShow()
	running = false
	phase = "intro"
	beat += 1
	quitArmed = false
	stopTimer()
	hideCountdown()
	Kit.hideTouchControls("pose", false)
	top.Visible = false
	banner.Visible = false
	subBanner.Visible = false
	for i, button in buttons do
		Kit.setGlow(button, false)
		pops[i].Scale = 1
	end
	layoutPad()
end

local function restorePlay()
	beginAt = -math.huge
	Kit.setButton(playButton, "PLAY", C.Good)
end

local lobbyAcc, slowAcc = 0, 0
local function onBeat(dt: number)
	lobbyAcc += dt
	slowAcc += dt
	if lobbyAcc >= 0.2 then
		lobbyAcc = 0
		if stage == "lobby" then
			setRehearse(nearMirror())
		end
	end
	if slowAcc >= 1 then
		slowAcc = 0
		fillBoard()
		if stage == "lobby" then
			refreshLobby()
		elseif stage == "results" then
			local since = os.clock() - resultsAt
			local left = math.ceil(resultsTime - since)
			cardTimer.Text = if left > 0 then "Back to the lobby in " .. left else ""
			if since > resultsTime + RESULTS_FALLBACK then
				toLobby()
			end
		end
	end
end

local function setStage(new: string)
	local old = stage
	stage = new
	root.Visible = new ~= "off"
	Kit.hidePlayerList("pose", new ~= "off")
	if screen then
		screen:SetAttribute("RunActive", new ~= "off")
	end
	if new == "lobby" then
		refreshLobby()
		if old ~= "lobby" then
			restorePlay()
			leaveArmed = false
			Kit.setButton(leaveButton, "LEAVE", C.SurfaceHi)
			lobby.Visible = true
			Kit.appear(lobby)
		end
	elseif lobby.Visible then
		Kit.disappear(lobby)
	end
	if new ~= "results" then
		hideCard()
	end
	if new ~= "lobby" then
		setRehearse(false)
	end
	if new == "off" then
		if lobbyConn then
			lobbyConn:Disconnect()
			lobbyConn = nil
		end
	elseif not lobbyConn then
		lobbyConn = RunService.Heartbeat:Connect(onBeat)
	end
	rebind()
end

-- Reads what a payload says about the stay (missing fields keep what is known).
local function readRun(p: any)
	passRound = math.floor(num(p.passRound, passRound))
	best = math.floor(num(p.best, best))
	clears = math.floor(num(p.clears, clears))
	timeout = num(p.timeout, timeout)
	cooldownEnds = num(p.cooldownEnds, cooldownEnds)
	if type(p.rewardPreview) == "table" then
		reward = p.rewardPreview
	end
end

-- A game starts on screen: the "countdown" (seconds until the first show).
local function beginGame(p: any, countdown: number)
	readRun(p)
	running = true
	setStage("countdown")
	restorePlay()
	phase = "intro"
	beat += 1
	playAt = os.clock()
	local newMax = math.max(1, math.floor(num(p.maxHearts, maxLives)))
	setHearts(math.floor(num(p.hearts, newMax)), newMax, false)
	setGoal()
	roundLabel.Text = "ROUND 1"
	buildDots(0)
	shadePad(true)
	quitArmed = false
	Kit.setButton(quitButton, if Kit.gamepad then "Y" else "X", C.SurfaceHi)
	quitButton.Size = UDim2.fromOffset(30, 28)
	Kit.hideTouchControls("pose", true)
	top.Visible = true
	layoutPad()
	showBanner("GET READY!", "Watch the Chad, then copy his flexes", C.Gold)
	showCountdown(countdown)
	rebind()
end

toLobby = function()
	stopShow()
	setStage("lobby")
end

-- LOBBY on the results card: the server moves the player back now ("PoseLobby"); its
-- "lobby" notify follows, the card goes at once.
leaveResults = function()
	if stage == "results" then
		action:FireServer({ action = "PoseLobby" })
	end
	toLobby()
end

begin = function()
	if (stage ~= "lobby" and stage ~= "results") or os.clock() - beginAt < 2.5 then
		return
	end
	beginAt = os.clock()
	action:FireServer({ action = "PoseBegin" })
	if stage == "lobby" then
		Kit.setButton(playButton, "GET READY...", C.SurfaceHi)
		task.delay(2.5, function()
			if stage == "lobby" and os.clock() - beginAt >= 2.4 then
				restorePlay()
			end
		end)
	end
end

local function hideAll()
	stopShow()
	setStage("off")
end

-- "start" (entered the mode) and "lobby" (back from a game): the lobby card.
function PoseHud.start(payload: { [string]: any }?)
	local p: any = payload or {}
	readRun(p)
	stopShow()
	setStage("lobby")
end

function PoseHud.stop(_payload: { [string]: any }?)
	hideAll()
end

function PoseHud.onNotify(payload: { [string]: any })
	local p: any = payload
	local event = p.event
	if event == "start" then
		PoseHud.start(p)
	elseif event == "stop" then
		PoseHud.stop(p)
	elseif event == "lobby" then
		PoseHud.start(p)
		if p.reason == "bumped" then
			Popups.toast("Another chad needed your podium. Back to the lobby!", "info")
		end
	elseif event == "full" then
		Popups.toast(if type(p.text) == "string" then p.text else "The posing stage is full, wait a moment!", "info")
		if stage == "lobby" then
			restorePlay()
		end
	elseif event == "countdown" then
		beginGame(p, num(p.seconds, 3))
	elseif not running then
		return
	elseif event == "round" then
		if stage == "countdown" then
			hideCountdown()
			stage = "play"
		end
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
	elseif event == "bonus" then
		local cash = num(p.cash, 0)
		local round = math.floor(num(p.round, 0))
		local trophy = if type(p.trophy) == "string" then p.trophy else nil
		local head = if trophy then trophy .. "!" else "BONUS!"
		showBanner(
			head,
			if cash > 0 then round .. " flexes: +" .. Format.money(cash) else round .. " flexes! You're on fire, keep going!",
			if trophy then trophyColor(trophy) else C.Gold
		)
		Kit.confetti(banner, { Origin = UDim2.fromScale(0.5, 0.4), Count = 30, ZIndex = 31, Power = 1 })
		if cash > 0 then
			Sounds.play("Coin", 0.05, 1.4)
		else
			Sounds.play("Celebrate")
		end
	elseif event == "miss" then
		local wasTurn = phase == "turn"
		phase = "wait"
		beat += 1
		stopTimer()
		shadePad(true)
		setHearts(math.floor(num(p.hearts, lives - 1)), maxLives, true)
		local expectedIndex = math.floor(num(p.expected, 0))
		local expected = FLEXES[expectedIndex]
		local sub = if expected then "It was " .. expected.label else nil
		if p.reason == "slow" then
			Sounds.play("Error")
			showBanner("TOO SLOW!", sub, C.Bad)
			showExpected(expectedIndex)
		elseif wasTurn then
			-- A wrong flex the client had not judged (out of step): the server's word.
			showBanner("OOPS!", sub, C.Bad)
			showExpected(expectedIndex)
		end
	elseif event == "win" or event == "lose" then
		stopShow()
		setStage("results")
		resultsAt = os.clock()
		resultsTime = math.clamp(num(p.resultsTime, 8), 2, 30)
		showCard(p, event == "win")
	end
end

function PoseHud.onState(data: any)
	local info = type(data) == "table" and type(data.modes) == "table" and data.modes.pose
	if type(info) ~= "table" then
		return
	end
	best = math.floor(num(info.best, best))
	clears = math.floor(num(info.clears, clears))
	cooldownEnds = num(info.cooldownEnds, cooldownEnds)
	if type(info.rewardPreview) == "table" then
		reward = info.rewardPreview
	end
	fillBoard()
	local inArena = info.running == true
	local snapPhase = if type(info.phase) == "string" then info.phase else nil
	PoseFx.sync(inArena, snapPhase)
	if not inArena then
		if stage ~= "off" then
			hideAll()
		end
		return
	end
	if snapPhase == "lobby" then
		-- Results go after their moment; a game whose end never arrived goes too.
		local ended = stage == "results" and os.clock() - resultsAt > 1.5
		local lost = (stage == "countdown" or stage == "play") and os.clock() - playAt > 2
		if ended or lost then
			toLobby()
		elseif stage == "off" then
			-- The "start" never arrived.
			setStage("lobby")
		end
	end
	if stage == "lobby" then
		refreshLobby()
	end
end

-- Build ------------------------------------------------------------------------------------

-- Scales a holder to the screen. `touchMin`: the smallest scale on touch screens (cards keep
-- their buttons at least 44 px there).
local function fitScale(scale: UIScale, touchMin: number?)
	local function fit()
		local camera = Workspace.CurrentCamera
		local view = if camera then camera.ViewportSize else Vector2.new(1280, DESIGN_H)
		local low = if Kit.touch and touchMin then touchMin else 0.6
		scale.Scale = math.clamp(math.min(view.Y / DESIGN_H, view.X / 900), low, 1.25)
	end
	fit()
	local camera = Workspace.CurrentCamera
	if camera then
		camera:GetPropertyChangedSignal("ViewportSize"):Connect(fit)
	end
	if touchMin then
		Kit.onInput(fit)
	end
end

-- A small key chip on a button's top-right corner (hidden on touch, or when the current
-- input has no key for it).
local function keyChip(button: TextButton, keyboard: string, gamepad: string)
	local chip = Kit.text(button, {
		Name = "KeyChip",
		Text = "",
		Font = F.Display,
		TextSize = 13,
		TextWrapped = false,
		TextColor3 = C.Ink,
		BackgroundColor3 = C.Text,
		BackgroundTransparency = 0.05,
		StrokeThickness = 0,
		Size = UDim2.fromOffset(28, 20),
		Position = UDim2.new(1, 6, 0, -8),
		AnchorPoint = Vector2.new(1, 0),
		ZIndex = button.ZIndex + 8,
	})
	Kit.round(chip)
	Kit.onInput(function()
		local text = if Kit.gamepad then gamepad else keyboard
		chip.Text = text
		chip.Visible = not Kit.touch and text ~= ""
		chip.Size = UDim2.fromOffset(math.max(28, 12 + #text * 9), 20)
	end)
end

local function buildPad()
	local span = BUTTON * 3 + GAP * 2
	pad = Kit.new("Frame", {
		Name = "FlexPad",
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(span, span),
		Position = UDim2.new(0.5, 0, 1, -16),
		AnchorPoint = Vector2.new(0.5, 1),
		Visible = false,
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
	-- Over the pad at the rehearsal mirror: "Practise your flexes" (bobs; the flex's name
	-- flashes in its colour on every press).
	rehearseHint = Kit.hudText(pad, {
		Name = "RehearseHint",
		Text = "Practise your flexes",
		Font = F.Display,
		TextSize = 26,
		StrokeThickness = 3,
		Size = UDim2.new(1, 160, 0, 34),
		Position = UDim2.new(0.5, 0, 0, -12),
		AnchorPoint = Vector2.new(0.5, 1),
		Visible = false,
		ZIndex = 30,
	})
end

-- A transparent holder scaled to the screen (the card inside it pops in with its own scale).
local function scaledHolder(parent: Instance, name: string, size: Vector2, touchMin: number?): Frame
	local holder = Kit.new("Frame", {
		Name = name,
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(size.X, size.Y),
		ZIndex = 40,
		Parent = parent,
	})
	fitScale(Kit.new("UIScale", { Parent = holder }), touchMin)
	return holder
end

local function buildCard(screenGui: ScreenGui)
	local holder = scaledHolder(screenGui, "PoseCardHolder", Vector2.new(380, 350), 0.75)
	-- Docked where the lobby card sits (right; top right on touch, clear of the jump
	-- button): the avatar's finale in the middle of the screen stays in view.
	local function place()
		holder.AnchorPoint = if Kit.touch then Vector2.new(1, 0) else Vector2.new(1, 0.5)
		holder.Position = if Kit.touch then UDim2.new(1, -12, 0, 48) else UDim2.new(1, -24, 0.5, 0)
	end
	Kit.onInput(place)
	card = Kit.panel(holder, {
		Name = "PoseCard",
		Size = UDim2.fromScale(1, 1),
		Visible = false,
		ZIndex = 40,
	})
	cardTitle = Kit.title(card, {
		Text = "TEST PASSED!",
		TextSize = 34,
		Size = UDim2.new(1, -40, 0, 44),
		Position = UDim2.new(0.5, 0, 0, 20),
		AnchorPoint = Vector2.new(0.5, 0),
		ZIndex = 42,
	})
	-- The run's title (BRONZE / SILVER / GOLD POSER), or the first one to reach.
	cardTrophy = Kit.text(card, {
		Text = "",
		Font = F.Display,
		TextSize = 24,
		Size = UDim2.new(1, -40, 0, 28),
		Position = UDim2.new(0.5, 0, 0, 68),
		AnchorPoint = Vector2.new(0.5, 0),
		ZIndex = 42,
	})
	cardLines = Kit.text(card, {
		Text = "",
		TextSize = 20,
		Size = UDim2.new(1, -40, 0, 26),
		Position = UDim2.new(0.5, 0, 0, 100),
		AnchorPoint = Vector2.new(0.5, 0),
		ZIndex = 42,
	})
	cardBest = Kit.text(card, {
		Text = "",
		Font = F.Display,
		TextSize = 24,
		Size = UDim2.new(1, -40, 0, 30),
		Position = UDim2.new(0.5, 0, 0, 132),
		AnchorPoint = Vector2.new(0.5, 0),
		ZIndex = 42,
	})
	cardCash = Kit.text(card, {
		Text = "",
		Font = F.Display,
		TextSize = 22,
		TextWrapped = true,
		TextYAlignment = Enum.TextYAlignment.Top,
		-- Two lines: the pay and a milestone bonus.
		Size = UDim2.new(1, -40, 0, 52),
		Position = UDim2.new(0.5, 0, 0, 170),
		AnchorPoint = Vector2.new(0.5, 0),
		ZIndex = 42,
	})
	cardTimer = Kit.text(card, {
		Text = "",
		TextSize = 14,
		TextColor3 = C.TextDim,
		Size = UDim2.new(1, -40, 0, 18),
		Position = UDim2.new(0.5, 0, 0, 226),
		AnchorPoint = Vector2.new(0.5, 0),
		ZIndex = 42,
	})
	local again = Kit.button(card, {
		Name = "Again",
		Text = "PLAY AGAIN",
		Color = C.Good,
		Size = UDim2.fromOffset(178, 60),
		Position = UDim2.new(0.5, -6, 1, -22),
		AnchorPoint = Vector2.new(1, 1),
		ZIndex = 42,
	}, function()
		begin()
	end)
	keyChip(again, "ENTER", "X")
	local back = Kit.button(card, {
		Name = "Lobby",
		Text = "LOBBY",
		Color = C.SurfaceHi,
		Size = UDim2.fromOffset(150, 60),
		Position = UDim2.new(0.5, 6, 1, -22),
		AnchorPoint = Vector2.new(0, 1),
		ZIndex = 42,
	}, function()
		leaveResults()
	end)
	keyChip(back, "", "B")
end

-- The lobby card: what the test is, the player's record, the reward and PLAY.
local function buildLobby(screenGui: ScreenGui)
	local holder = scaledHolder(screenGui, "PoseLobbyHolder", Vector2.new(300, 382), 0.75)
	local function place()
		-- Touch: top right (clear of the thumbstick and the jump button); else right middle.
		holder.AnchorPoint = if Kit.touch then Vector2.new(1, 0) else Vector2.new(1, 0.5)
		holder.Position = if Kit.touch then UDim2.new(1, -12, 0, 48) else UDim2.new(1, -24, 0.5, 0)
	end
	Kit.onInput(place)
	lobby = Kit.panel(holder, {
		Name = "PoseLobby",
		Size = UDim2.fromScale(1, 1),
		Visible = false,
		ZIndex = 40,
	})
	Kit.title(lobby, {
		Text = "POSE COPY",
		TextSize = 32,
		TextColor3 = C.Gold,
		Size = UDim2.new(1, -32, 0, 38),
		Position = UDim2.new(0.5, 0, 0, 12),
		AnchorPoint = Vector2.new(0.5, 0),
		ZIndex = 42,
	})
	lobbyGoal = Kit.text(lobby, {
		Text = "Copy 8 flexes to pass",
		TextSize = 16,
		Size = UDim2.new(1, -32, 0, 20),
		Position = UDim2.new(0.5, 0, 0, 50),
		AnchorPoint = Vector2.new(0.5, 0),
		ZIndex = 42,
	})
	-- How to play, over chips for the current input (they follow a switch of input).
	Kit.text(lobby, {
		Name = "HowTo",
		Text = "Watch the Chad, then copy his flexes",
		TextSize = 14,
		TextColor3 = C.TextDim,
		Size = UDim2.new(1, -24, 0, 18),
		Position = UDim2.new(0.5, 0, 0, 74),
		AnchorPoint = Vector2.new(0.5, 0),
		ZIndex = 42,
	})
	local lobbyKeys = Kit.new("Frame", {
		Name = "Keys",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, -24, 0, 26),
		Position = UDim2.new(0.5, 0, 0, 98),
		AnchorPoint = Vector2.new(0.5, 0),
		ZIndex = 42,
		Parent = lobby,
	})
	Kit.list(lobbyKeys, 6, true, Enum.HorizontalAlignment.Center)
	local function keyChips()
		for _, child in lobbyKeys:GetChildren() do
			if child:IsA("GuiObject") then
				child:Destroy()
			end
		end
		local chips: { string } = if Kit.touch
			then { "TAP THE FLEX BUTTONS" }
			elseif Kit.gamepad then { "D-PAD" }
			else { "ARROW KEYS", "or", "WASD" }
		for order, text in chips do
			local word = text == "or"
			local chip = Kit.text(lobbyKeys, {
				Name = "Chip" .. order,
				Text = text,
				Font = F.Display,
				TextSize = 13,
				TextWrapped = false,
				TextColor3 = if word then C.TextDim else C.Ink,
				BackgroundColor3 = C.Text,
				BackgroundTransparency = if word then 1 else 0.05,
				Size = UDim2.fromOffset(if word then 18 else 16 + #text * 9, 24),
				LayoutOrder = order,
				ZIndex = 43,
			})
			if not word then
				Kit.round(chip)
			end
		end
	end
	Kit.onInput(keyChips)
	local function stat(x: number, caption: string): TextLabel
		local well = Kit.well(lobby, {
			Size = UDim2.fromOffset(128, 52),
			Position = UDim2.new(0.5, x, 0, 132),
			AnchorPoint = Vector2.new(0.5, 0),
			ZIndex = 41,
		})
		Kit.corner(well, 12)
		Kit.text(well, {
			Text = caption,
			TextSize = 12,
			TextColor3 = C.TextDim,
			Size = UDim2.new(1, 0, 0, 16),
			Position = UDim2.fromOffset(0, 5),
			ZIndex = 42,
		})
		return Kit.text(well, {
			Text = "0",
			Font = F.Display,
			TextSize = 24,
			Size = UDim2.new(1, 0, 0, 28),
			Position = UDim2.fromOffset(0, 20),
			ZIndex = 42,
		})
	end
	lobbyBest = stat(-68, "BEST")
	lobbyClears = stat(68, "CLEARS")
	lobbyReward = Kit.text(lobby, {
		Text = "",
		TextSize = 15,
		TextWrapped = true,
		Size = UDim2.new(1, -28, 0, 40),
		Position = UDim2.new(0.5, 0, 0, 190),
		AnchorPoint = Vector2.new(0.5, 0),
		ZIndex = 42,
	})
	playButton = Kit.button(lobby, {
		Name = "Play",
		Text = "PLAY",
		Color = C.Good,
		Size = UDim2.fromOffset(250, 64),
		Position = UDim2.new(0.5, 0, 0, 238),
		AnchorPoint = Vector2.new(0.5, 0),
		ZIndex = 42,
		Shimmer = true,
	}, function()
		begin()
	end)
	keyChip(playButton, "ENTER", "X")
	Kit.text(lobby, {
		Text = "or step on the glowing START pad",
		TextSize = 13,
		TextColor3 = C.TextDim,
		Size = UDim2.new(1, -28, 0, 16),
		Position = UDim2.new(0.5, 0, 0, 306),
		AnchorPoint = Vector2.new(0.5, 0),
		ZIndex = 42,
	})
	leaveButton = Kit.button(lobby, {
		Name = "Leave",
		Text = "LEAVE",
		Color = C.SurfaceHi,
		Size = UDim2.fromOffset(130, 48),
		Position = UDim2.new(0.5, 0, 1, -14),
		AnchorPoint = Vector2.new(0.5, 1),
		ZIndex = 42,
	}, function()
		action:FireServer({ action = "ModeQuit" })
	end)
	keyChip(leaveButton, "", "B")
	-- B on a controller arms LEAVE ("LEAVE?"), a second B within 3 s leaves.
	leavePress = function()
		if leaveArmed then
			leaveArmed = false
			action:FireServer({ action = "ModeQuit" })
			return
		end
		leaveArmed = true
		Kit.setButton(leaveButton, "LEAVE?", C.Bad)
		Kit.pop(leaveButton, 1.2)
		task.delay(3, function()
			if leaveArmed then
				leaveArmed = false
				Kit.setButton(leaveButton, "LEAVE", C.SurfaceHi)
			end
		end)
	end
end

-- The big 3, 2, 1, GO! in the middle of the screen.
local function buildCountdown()
	local holder = Kit.new("Frame", {
		Name = "Countdown",
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(320, 180),
		Position = UDim2.fromScale(0.5, 0.42),
		AnchorPoint = Vector2.new(0.5, 0.5),
		ZIndex = 35,
		Parent = root,
	})
	fitScale(Kit.new("UIScale", { Parent = holder }))
	countLabel = Kit.hudText(holder, {
		Name = "Count",
		Text = "",
		Font = F.Display,
		TextSize = 150,
		StrokeThickness = 5,
		Size = UDim2.fromScale(1, 1),
		Visible = false,
		ZIndex = 36,
	})
	countScale = Kit.new("UIScale", { Parent = countLabel })
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
	top = Kit.new("Frame", {
		Name = "Top",
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(420, 170),
		Position = UDim2.new(0.5, 0, 0, 58),
		AnchorPoint = Vector2.new(0.5, 0),
		Visible = false,
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
	-- 76 design px: at the phone scale (0.6) still a 45 px thumb target.
	local quitHit = Kit.hitArea(quitButton, 76, function()
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
		TextSize = 20,
		StrokeThickness = 2,
		Size = UDim2.new(1, 0, 0, 24),
		Position = UDim2.new(0.5, 0, 0, 104),
		AnchorPoint = Vector2.new(0.5, 0),
		ZIndex = 30,
	})
	dotsRow = Kit.new("Frame", {
		Name = "Dots",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 22),
		Position = UDim2.new(0.5, 0, 0, 134),
		AnchorPoint = Vector2.new(0.5, 0),
		Parent = top,
	})
	dotsList = Kit.list(dotsRow, 6, true, Enum.HorizontalAlignment.Center)
	timerBack = Kit.new("Frame", {
		Name = "Timer",
		BackgroundColor3 = C.Well,
		BorderSizePixel = 0,
		Size = UDim2.fromOffset(260, 10),
		Position = UDim2.new(0.5, 0, 0, 162),
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
	buildCountdown()
	buildLobby(screenGui)
	buildCard(screenGui)
	-- Phones turning or resizing: the pad follows (aside on short screens in a game).
	local camera = Workspace.CurrentCamera
	if camera then
		camera:GetPropertyChangedSignal("ViewportSize"):Connect(function()
			if pad.Visible then
				layoutPad()
			end
		end)
	end
end

return PoseHud
