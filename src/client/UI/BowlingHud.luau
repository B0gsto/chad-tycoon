--!strict
--[[
	BowlingHud: the screen side of DUMBBELL BOWL (Modes.Bowling; docs/minigames.md). Fx.Bowling
	does the 3D side; this module drives its aim guide (Fx.Bowling.setAim) every frame of a turn,
	its ball colour (setBall) and its phase (setMode).

	A run goes lobby -> countdown -> play -> results -> lobby (the "phase" of the snapshot's
	modes.bowling and of the Notify events; docs "Lobby first, then the game"):

	  Lobby       bottom centre, a compact card: DUMBBELL BOWL, the goal ("Score 50 of 150 in 5
	              frames"), the best score, the reward status (full pack ready, or the time to
	              the next one and the run-again share), a four-swatch dumbbell picker
	              ("BowlingBall" { choice }; Fx glows the matching BallChoiceN rack dumbbell),
	              a big PLAY ("BowlingBegin": tap, Enter, gamepad X) and LEAVE ("ModeQuit";
	              gamepad B twice). Space and gamepad A stay the jump so the player can hop
	              around; LB / RB cycle the dumbbell. The arena's BestBoard (TextLabels Best,
	              Clears "CLEARS: n", Reward) is filled from the snapshot.
	  Countdown   a big 3, 2, 1, GO! in the middle; the scorecard comes up empty.
	  Scorecard   top centre, under the HUD's unit-count capsule: five frame boxes (two mark
	              cells, "X" / "/" / "-" / digits, and the running total once known), the
	              TOTAL box, a gold "TARGET n" chip (it turns mint once the total passes it)
	              and the quiet quit "X" (first tap arms "QUIT?", the second fires ModeQuit;
	              gamepad Y / B press it).
	  Controls    bottom centre, one big tap target (the whole panel; also Space, Enter and
	              gamepad X or A; the bowler stands still, so nothing jumps). On "ready" an
	              arrow sweeps the lane strip (a constant-speed back-and-forth from a random
	              side, gutters red at both ends, the pocket gold in the middle): the first
	              press locks the aim; then the power bar fills and empties: SOFT (mint), the
	              gold SWEET spot (the start payload's power.sweetLo..sweetHi; the best ball)
	              and the red TOO HARD top (the dumbbell goes wild and hooks): the second press
	              sends "BowlingRoll" { aim, power }. The panel fades while the avatar bowls
	              and the ball rolls (the roll's path times start `windup` seconds in).
	  Callouts    centre: "STRIKE!" / "SPARE!" (gold / mint, confetti), "GUTTER!" or the pin
	              count pop in when the last pin falls; the card updates at the same moment.
	  Results     a centre card: "YOU PASSED!" with the pay or "SO CLOSE!" with the points
	              still missing, the score (counting up), the best ("NEW BEST!" flashes),
	              PLAY AGAIN ("BowlingBegin"; Enter, gamepad X) and LOBBY ("BowlingLobby";
	              gamepad B; it leaves for the lobby at once). It hides itself when the phase
	              is back to "lobby" (the server does that after about 6 s).

	Wired from Main.client.luau (nothing else needs editing):
	  init(screen)        once, builds the HUD (hidden)
	  onNotify(payload)   every Notify with kind = "Mode" and mode = "bowling"
	  onState(data)       every State snapshot (phase sync, stats, safety net: hides when
	                      modes.bowling is not running)
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
local State = require(Client.State) :: any
local BowlingFx = require(Client.Fx.Bowling) :: any

local BowlingHud = {}

local C = Kit.C
local F = Kit.F

local FRAMES = 5
local BALLS = 4
-- Scorecard: frame box size, the TOTAL box, the gap to the unit-count capsule.
local CARD = { BoxW = 56, BoxH = 58, TotalW = 74, Pad = 8, MinY = 120, Clear = 12 }
-- The controls panel (bottom centre) and its two strips.
local SENT_TIMEOUT = 4
local CONTROLS = { W = 440, H = 168, Bottom = 28, StripW = 384, AimH = 34, PowerH = 26 }
-- Seconds for the aim arrow to cross the lane one way, and the power bar to fill once.
local SWEEP = { Aim = 1.25, Power = 1.0 }
-- A press this soon after the turn opens or the aim locks is ignored (a double tap, a held key).
local PRESS_GUARD = 0.18
-- |aim| under POCKET hits the head pin square ("PERFECT AIM!"). Power is a choice
-- (BowlingRules.POWER, sent as the start payload's `power`): under sweetLo the dumbbell is
-- soft, sweetLo..sweetHi is the SWEET spot, over sweetHi it goes wild.
local POCKET = 0.12
local SWEET = { Lo = 0.72, Hi = 0.9 }
-- Seconds from a "roll" to the release (the avatar's run-up; the start payload's `windup`).
local windup = 0.9
-- Callout word: pop scale, hold and fade.
local CALLOUT = { TextSize = 84, Hold = 1.1, Rise = 40 }
-- The lobby card (bottom centre) and its parts.
local LOBBY = { W = 476, H = 206, Swatch = 48, SwatchGap = 8, PlayW = 172, PlayH = 74 }
-- Seconds the server keeps the results card up before the lobby (docs: about 6 s).
local RESULTS_BACK = 6
-- A snapshot's phase only overrides the HUD's once the HUD's own has stood this long (a
-- snapshot sent just before a Notify must not undo it).
local PHASE_TRUST = 1.5
-- A dumbbell pick is sent this long after the last change (cycling with LB / RB sends once).
local PICK_SEND = 0.3
-- PLAY / PLAY AGAIN ignore a second press this soon (the server answers with "countdown").
local BEGIN_GAP = 0.8
local ACTION = "BowlingPress"
local QUIT_ACTION = "BowlingQuit"
local LOBBY_ACTION = "BowlingPlay"
local CYCLE_ACTION = "BowlingCycle"
local RESULT_ACTION = "BowlingResults"
local PRIORITY = 3000
-- HUD chrome that steps aside during a run (the gift corner and the crate panel).
local CLUTTER = { "FreeCorner", "ChestPanel" }

local action = Net.event("Action")

local screen: ScreenGui? = nil
local root: Frame
local cardPanel: GuiObject
local frameBoxes: { { marks: { TextLabel }, total: TextLabel, box: Frame } } = {}
local totalLabel: TextLabel
local targetChip: TextLabel
local quitButton: TextButton
local controlsHolder: Frame
local controlsScale: UIScale
local controls: GuiObject
local promptLabel: TextLabel
local frameLabel: TextLabel
local flashLabel: TextLabel
local aimStrip: Frame
local aimArrow: TextLabel
local aimLock: Frame
local powerStrip: Frame
local powerFill: Frame
local sweetBand: Frame
local wildBand: Frame
local againKey: TextLabel
local callout: TextLabel
local countLabel: TextLabel
local countSub: TextLabel
local finishCard: Frame
local finishTitle: TextLabel
local finishScore: TextLabel
local finishSub: TextLabel
local finishCash: TextLabel
local finishBest: TextLabel
local finishBestLine: TextLabel
local finishBack: TextLabel
local againButton: TextButton
local lobbyButton: TextButton
local lobbyHolder: Frame
local lobbyScale: UIScale
local lobbyCard: GuiObject
local goalLabel: TextLabel
local rewardLabel: TextLabel
local bestPill: TextLabel
local pickCaption: TextLabel
local playButton: TextButton
local playKey: TextLabel
local leaveButton: TextButton
local swatches: { { button: TextButton, ring: UIStroke, face: Frame } } = {}

local running = false
-- The run's phase: "off", "lobby", "countdown", "play" or "results".
local mode = "off"
local modeAt = 0
-- The turn inside "play": "wait" (not your turn), "aim" (arrow sweeping), "power", "sent".
local phase = "wait"
local phaseAt = 0
-- Where the aim sweep starts (seconds into the bounce), so the first frame is not the centre.
local aimFrom = 0
local aim, power = 0, 0
local target, maxScore, frames = 50, 150, FRAMES
local stats: { [string]: any } = { best = 0, clears = 0, preview = nil, cooldownEnds = 0, repeatEnds = 0 }
local choice = 1
local pendingPick: number? = nil
local pickToken = 0
local pickedAt = -math.huge
local quitArmed = false
local leaveArmed = false
local beganAt = -math.huge
local resultsAt = 0
local stepConn: RBXScriptConnection? = nil
local calloutToken = 0
local rollToken = 0
local countToken = 0
local flashToken = 0
local textsAt = 0
local board: Instance? = nil

local function num(value: any, default: number): number
	return if type(value) == "number" and value == value then value else default
end

local function reducedMotion(): boolean
	local data = State.data
	return type(data) == "table" and type(data.settings) == "table" and data.settings.reducedMotion == true
end

-- 0 -> 1 -> 0 at constant speed, `period` seconds each way.
local function bounce(t: number, period: number): number
	local u = (t / period) % 2
	return if u > 1 then 2 - u else u
end

-- Scorecard ---------------------------------------------------------------------------------

local function paintCard(card: any, total: any)
	for i, box in frameBoxes do
		local f = type(card) == "table" and card[i]
		local marks = type(f) == "table" and type(f.marks) == "table" and f.marks or {}
		for b, cell in box.marks do
			local m = marks[b]
			cell.Text = if type(m) == "string" then m else ""
			cell.TextColor3 = if m == "X" then C.Gold elseif m == "/" then C.Good else C.Text
		end
		local t = type(f) == "table" and f.total
		box.total.Text = if type(t) == "number" then tostring(t) else ""
	end
	local n = num(total, 0)
	totalLabel.Text = tostring(n)
	local passed = n >= target
	targetChip.Text = if passed then "PASSED!" else "TARGET " .. target
	targetChip.BackgroundColor3 = if passed then C.Good else C.Gold
end

local function highlightFrame(frame: number)
	for i, box in frameBoxes do
		box.box.BackgroundTransparency = if i == frame then 0.15 else 0.6
	end
end

local function capsuleBottom(): number
	local gui = screen
	local units = gui and gui:FindFirstChild("Units")
	if not gui or not units or not units:IsA("GuiObject") or not units.Visible then
		return 0
	end
	return (units.AbsolutePosition.Y + units.AbsoluteSize.Y - gui.AbsolutePosition.Y) / Kit.pixelScale(gui)
end

-- Lobby texts and the arena board -----------------------------------------------------------

-- The reward status line: full pack ready, or the wait for it and the run-again share.
local function rewardText(): (string, Color3)
	local p = stats.preview
	if type(p) ~= "table" then
		return "Pass to earn a cash pack!", C.TextDim
	end
	local now = State.now()
	local fullWait = num(stats.cooldownEnds, 0) - now
	if p.full == true or fullWait <= 0 then
		local cash = num(p.cash, num(p.packCash, 0))
		return if cash > 0 then "Full pack ready: +" .. Format.money(cash) else "Full pack ready!", C.MoneyText
	end
	local text = "Full pack in " .. Format.time(fullWait)
	local share = num(p.repeatCash, 0)
	if share > 0 then
		return text .. "  •  pass now: +" .. Format.money(share), C.MoneyText
	end
	local shareWait = num(stats.repeatEnds, 0) - now
	if shareWait > 0 then
		return text .. "  •  bonus in " .. Format.time(shareWait), C.TextDim
	end
	return text, C.TextDim
end

local function findBoard(): Instance?
	if board and board:IsDescendantOf(Workspace) then
		return board
	end
	local arena = BowlingFx.arena()
	board = arena and arena:FindFirstChild("BestBoard", true)
	return board
end

local function setBoardText(gui: Instance, name: string, text: string)
	local label = gui:FindFirstChild(name, true)
	if label and (label:IsA("TextLabel") or label:IsA("TextButton")) then
		(label :: any).Text = text
	end
end

local function paintLobby()
	goalLabel.Text = "Score " .. target .. " of " .. maxScore .. " in " .. frames .. " frames"
	local best = num(stats.best, 0)
	bestPill.Text = if best > 0 then "BEST " .. best else "NO BEST YET"
	local text, color = rewardText()
	rewardLabel.Text = text
	rewardLabel.TextColor3 = color
	local gui = findBoard()
	if gui then
		-- The board's own captions: "CLEARS: n" and an upper-case reward line.
		setBoardText(gui, "Best", tostring(best))
		setBoardText(gui, "Clears", "CLEARS: " .. num(stats.clears, 0))
		setBoardText(gui, "Reward", string.upper(text))
	end
end

local function paintSwatches()
	for i, s in swatches do
		local on = i == choice
		s.ring.Color = if on then C.Gold else C.Edge
		s.ring.Thickness = if on then 4 else 2
		s.face.BackgroundColor3 = if on then C.SurfaceHiTop else C.Well
		for _, plate in s.face:GetChildren() do
			if plate:IsA("Frame") and plate.Name == "Plate" then
				plate.BackgroundColor3 = BowlingFx.ballColor(i)
			end
		end
	end
end

local function sendPick()
	local i = pendingPick
	if i and running then
		pendingPick = nil
		pickToken += 1
		action:FireServer({ action = "BowlingBall", choice = i })
	end
end

-- Picks dumbbell `i` (wraps 1..BALLS); `quiet` = from the server, nothing to send.
local function pick(i: number, quiet: boolean?)
	i = ((math.floor(i) - 1) % BALLS) + 1
	local changed = i ~= choice
	choice = i
	paintSwatches()
	BowlingFx.setBall(i)
	if quiet or not changed then
		return
	end
	pickedAt = os.clock()
	Kit.sound("Toggle")
	Kit.pop(swatches[i].button, 1.4)
	pendingPick = i
	pickToken += 1
	local mine = pickToken
	task.delay(PICK_SEND, function()
		if pickToken == mine then
			sendPick()
		end
	end)
end

-- Callouts, countdown and results -------------------------------------------------------------

local function showCallout(text: string, color: Color3, celebrate: boolean)
	calloutToken += 1
	local mine = calloutToken
	callout.Text = text
	callout.TextColor3 = color
	callout.Position = UDim2.fromScale(0.5, 0.38)
	callout.Visible = true
	Kit.appear(callout, { from = 0.4, time = 0.3 })
	if celebrate and not reducedMotion() then
		Kit.confetti(root, { Origin = UDim2.fromScale(0.5, 0.38), Count = 36, ZIndex = 31, Power = 1.3 })
	end
	Kit.tween(callout, CALLOUT.Hold + 0.3, { Position = UDim2.new(0.5, 0, 0.38, -CALLOUT.Rise) }, Enum.EasingStyle.Quad)
	task.delay(CALLOUT.Hold, function()
		if calloutToken == mine then
			Kit.disappear(callout)
		end
	end)
end

-- A short word over the controls ("PERFECT AIM!", "MAX POWER!").
local function flash(text: string, color: Color3)
	flashToken += 1
	local mine = flashToken
	flashLabel.Text = text
	flashLabel.TextColor3 = color
	Kit.appear(flashLabel, { from = 0.5, time = 0.2 })
	task.delay(0.75, function()
		if flashToken == mine then
			Kit.disappear(flashLabel)
		end
	end)
end

local function showCount(text: string, color: Color3)
	countLabel.Text = text
	countLabel.TextColor3 = color
	Kit.appear(countLabel, { from = if reducedMotion() then 1.15 else 1.9, time = 0.3 })
end

local function hideCount()
	countToken += 1
	if countLabel.Visible then
		Kit.disappear(countLabel)
	end
	if countSub.Visible then
		Kit.disappear(countSub)
	end
end

local function showFinish(p: any, won: boolean)
	local score = num(p.score, 0)
	local best = num(p.best, score)
	finishTitle.Text = if won then "YOU PASSED!" else "SO CLOSE!"
	finishTitle.TextColor3 = if won then C.Gold else C.Text
	Kit.countTo(finishScore, 0, score, nil, 0.6)
	finishBestLine.Text = "BEST " .. best
	finishBestLine.TextColor3 = if p.newBest == true then C.Gold else C.TextDim
	if won then
		finishSub.Text = "Target " .. num(p.target, target) .. " smashed!"
		local cash = num(p.cash, 0)
		finishCash.Visible = true
		if cash > 0 then
			finishCash.Text = (if p.pay == "repeat" then "Run again bonus +" else "+") .. Format.money(cash)
			finishCash.TextColor3 = C.MoneyText
			finishCash.TextSize = 30
		else
			-- Inside the cooldown with the run-again share used: say when pay comes back.
			local now = State.now()
			local waits = { num(p.cooldownEnds, 0) - now }
			if num(p.repeatEnds, 0) > 0 then
				table.insert(waits, num(p.repeatEnds, 0) - now)
			end
			local wait = math.max(0, math.min(table.unpack(waits)))
			finishCash.Text = "Next cash bonus in " .. Format.time(wait)
			finishCash.TextColor3 = C.TextDim
			finishCash.TextSize = 18
		end
	else
		finishSub.Text = (num(p.target, target) - score) .. " more points to pass. Try again!"
		finishCash.Visible = false
	end
	finishBest.Visible = false
	finishBack.Text = ""
	finishCard.Visible = true
	Kit.appear(finishCard, { from = 0.6, time = 0.35 })
	Kit.selectable(againButton)
	Kit.selectable(lobbyButton)
	Kit.focus(finishCard, againButton)
	if p.newBest == true then
		-- The NEW BEST stamp slams on once the score has counted up.
		task.delay(0.6, function()
			if mode == "results" and finishCard.Visible then
				finishBest.Visible = true
				Kit.appear(finishBest, { from = if reducedMotion() then 1.1 else 2.4, time = 0.35 })
				Kit.pop(finishBestLine, 1.3)
				Sounds.play("Upgrade")
			end
		end)
	end
	if won then
		Sounds.play("Celebrate")
		if not reducedMotion() then
			Kit.confetti(finishCard, { Origin = UDim2.fromScale(0.5, 0.2), Count = 40, ZIndex = 41, Power = 1.4 })
		end
	end
end

-- Turn and input ----------------------------------------------------------------------------

local function paintPrompt()
	-- Gamepad X bowls (A stays the jump button everywhere else in the game).
	local hint = if Kit.gamepad then "X" else Kit.keyHint("confirm")
	if phase == "aim" then
		promptLabel.Text = if Kit.touch then "TAP TO AIM" else hint .. "  TO AIM"
		promptLabel.TextColor3 = C.Text
	elseif phase == "power" then
		promptLabel.Text = if Kit.touch then "TAP TO ROLL!" else hint .. "  TO ROLL!"
		promptLabel.TextColor3 = C.Gold
	end
end

local function setPhase(next: string)
	phase = next
	phaseAt = os.clock()
	if next == "aim" then
		aimLock.Visible = false
		powerFill.Size = UDim2.fromScale(0, 1)
		-- Start the sweep near one edge, heading in (a press on the first frame must not
		-- be a free centre shot).
		local u = math.random() * 0.3
		aimFrom = (if math.random() < 0.5 then u else 1 + u) * SWEEP.Aim
	end
	paintPrompt()
end

local function press()
	if not running or mode ~= "play" or os.clock() - phaseAt < PRESS_GUARD then
		return
	end
	if phase == "aim" then
		aimLock.Position = UDim2.fromScale((aim + 1) / 2, 0.5)
		aimLock.Visible = true
		Kit.pop(aimStrip, 1.04)
		if math.abs(aim) <= POCKET then
			Sounds.play("Coin")
			flash("PERFECT AIM!", C.Gold)
		else
			Kit.sound("Click")
		end
		setPhase("power")
	elseif phase == "power" then
		setPhase("sent")
		if power >= SWEET.Lo and power <= SWEET.Hi then
			Kit.pop(powerStrip, 1.5)
			Sounds.play("Coin", 0, 1.25)
			flash("SWEET SPOT!", C.Gold)
		elseif power > SWEET.Hi then
			Kit.pop(powerStrip, 1.1)
			Kit.sound("Click")
			flash("TOO HARD!", C.Bad)
		else
			Kit.pop(powerStrip, 1.06)
			Kit.sound("Click")
			flash("A BIT SOFT", C.TextDim)
		end
		BowlingFx.setAim(aim, power, "off")
		action:FireServer({ action = "BowlingRoll", aim = aim, power = power })
		Kit.disappear(controls)
		-- The server may drop the roll (action budget); with no "roll" or "ready" back in
		-- SENT_TIMEOUT seconds the aim controls come back so the turn never stalls.
		rollToken += 1
		local mine = rollToken
		task.delay(SENT_TIMEOUT, function()
			if running and mode == "play" and rollToken == mine and (phase :: string) == "sent" then
				Kit.appear(controls, { from = 0.85, time = 0.2 })
				setPhase("aim")
			end
		end)
	end
end

local function step()
	if not running then
		return
	end
	local now = os.clock()
	if mode == "play" then
		local t = now - phaseAt
		if phase == "aim" then
			aim = bounce(t + aimFrom, SWEEP.Aim) * 2 - 1
			aimArrow.Position = UDim2.fromScale((aim + 1) / 2, 0)
			BowlingFx.setAim(aim, 0, "aim")
		elseif phase == "power" then
			power = bounce(t, SWEEP.Power)
			powerFill.Size = UDim2.fromScale(power, 1)
			-- Mint while soft, gold in the sweet spot, red once it is too hard.
			powerFill.BackgroundColor3 = if power > SWEET.Hi then C.Bad elseif power >= SWEET.Lo then C.Gold else C.Good
			BowlingFx.setAim(aim, power, "power")
		end
	end
	-- The texts that tick (reward waits, the results card's lobby countdown), twice a second.
	if now - textsAt >= 0.5 then
		textsAt = now
		if mode == "lobby" then
			paintLobby()
		elseif mode == "results" then
			local left = math.ceil(RESULTS_BACK - (now - resultsAt))
			finishBack.Text = if left > 0 then "Back to the lobby in " .. left else ""
		end
	end
end

local function quitPress()
	if quitArmed then
		quitArmed = false
		action:FireServer({ action = "ModeQuit" })
		return
	end
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

local function resetQuit()
	quitArmed = false
	Kit.setButton(quitButton, if Kit.gamepad then "Y" else "X", C.SurfaceHi)
	quitButton.Size = UDim2.fromOffset(30, 28)
end

-- LEAVE in the lobby: a tap or click leaves at once; gamepad B asks first ("LEAVE?").
local function leavePress(confirmFirst: boolean)
	if confirmFirst and not leaveArmed then
		leaveArmed = true
		Kit.setButton(leaveButton, "LEAVE?", C.Bad)
		Kit.pop(leaveButton, 1.2)
		task.delay(3, function()
			if leaveArmed then
				leaveArmed = false
				Kit.setButton(leaveButton, "LEAVE", C.SurfaceHi)
			end
		end)
		return
	end
	leaveArmed = false
	action:FireServer({ action = "ModeQuit" })
end

-- PLAY in the lobby, PLAY AGAIN on the results card.
local function begin()
	if not running or (mode ~= "lobby" and mode ~= "results") or os.clock() - beganAt < BEGIN_GAP then
		return
	end
	beganAt = os.clock()
	sendPick()
	action:FireServer({ action = "BowlingBegin" })
	Kit.pop(if mode == "lobby" then playButton else againButton, 1.2)
end

local applyMode: (next: string) -> ()
local placeZones: () -> ()

local function toLobby()
	if mode ~= "results" then
		return
	end
	-- The server brings the player over by itself after RESULTS_BACK; this asks for it now.
	action:FireServer({ action = "BowlingLobby" })
	applyMode("lobby")
end

local function bindAt(name: string, fn: (string, Enum.UserInputState, InputObject) -> Enum.ContextActionResult?, ...: Enum.KeyCode)
	ContextActionService:BindActionAtPriority(name, fn, false, PRIORITY, ...)
end

local function onPlayKey(_name: string, state: Enum.UserInputState, _input: InputObject): Enum.ContextActionResult
	if state == Enum.UserInputState.Begin then
		press()
	end
	return Enum.ContextActionResult.Sink
end

local function onLobbyKey(_name: string, state: Enum.UserInputState, _input: InputObject): Enum.ContextActionResult
	if state == Enum.UserInputState.Begin then
		begin()
	end
	return Enum.ContextActionResult.Sink
end

local function unbindKeys()
	for _, name in { ACTION, QUIT_ACTION, LOBBY_ACTION, CYCLE_ACTION, RESULT_ACTION } do
		ContextActionService:UnbindAction(name)
	end
end

-- The keys each phase listens to (Space stays the jump key in the lobby).
local function bindKeys()
	unbindKeys()
	if not running then
		return
	end
	if mode == "lobby" then
		-- Gamepad A stays the jump; X is PLAY.
		bindAt(LOBBY_ACTION, onLobbyKey, Enum.KeyCode.Return, Enum.KeyCode.KeypadEnter, Enum.KeyCode.ButtonX)
		bindAt(QUIT_ACTION, function(_, state)
			if state == Enum.UserInputState.Begin then
				leavePress(true)
			end
			return Enum.ContextActionResult.Sink
		end, Enum.KeyCode.ButtonB)
		bindAt(CYCLE_ACTION, function(_, state, input)
			if state == Enum.UserInputState.Begin then
				pick(choice + (if input.KeyCode == Enum.KeyCode.ButtonL1 then -1 else 1))
			end
			return Enum.ContextActionResult.Sink
		end, Enum.KeyCode.ButtonL1, Enum.KeyCode.ButtonR1)
	elseif mode == "countdown" or mode == "play" then
		-- The bowler stands still on its spot (Fx.Bowling), so Space and A may bowl too.
		bindAt(ACTION, onPlayKey, Enum.KeyCode.Space, Enum.KeyCode.Return, Enum.KeyCode.ButtonX, Enum.KeyCode.ButtonA)
		bindAt(QUIT_ACTION, function(_, state)
			if state == Enum.UserInputState.Begin then
				quitPress()
			end
			return Enum.ContextActionResult.Sink
		end, Enum.KeyCode.ButtonY, Enum.KeyCode.ButtonB)
	elseif mode == "results" then
		-- Gamepad X (or Enter) is PLAY AGAIN, B is LOBBY; A presses the selected card button.
		bindAt(RESULT_ACTION, function(_, state, input)
			if state == Enum.UserInputState.Begin then
				if input.KeyCode == Enum.KeyCode.ButtonB then
					toLobby()
				else
					begin()
				end
			end
			return Enum.ContextActionResult.Sink
		end, Enum.KeyCode.Return, Enum.KeyCode.KeypadEnter, Enum.KeyCode.ButtonX, Enum.KeyCode.ButtonB)
	end
end

local stashed: { [GuiObject]: boolean } = {}
local function setChrome(on: boolean)
	Kit.hidePlayerList("bowling", on)
	local gui = screen
	if not gui then
		return
	end
	gui:SetAttribute("RunActive", on)
	if on then
		for _, name in CLUTTER do
			local block = gui:FindFirstChild(name)
			if block and block:IsA("GuiObject") and stashed[block] == nil then
				stashed[block] = block.Visible
				block.Visible = false
			end
		end
	else
		for block, was in stashed do
			block.Visible = was
		end
		table.clear(stashed)
	end
end

local function showPanel(gui: GuiObject, on: boolean)
	if on and not gui.Visible then
		Kit.appear(gui, { from = 0.85, time = 0.25 })
	elseif not on and gui.Visible then
		Kit.disappear(gui)
	end
end

-- Moves the HUD to phase `next`: which panels show, which keys listen, what Fx does.
applyMode = function(next: string)
	if mode == next then
		return
	end
	mode = next
	modeAt = os.clock()
	resetQuit()
	leaveArmed = false
	Kit.setButton(leaveButton, "LEAVE", C.SurfaceHi)
	if next == "lobby" then
		paintLobby()
		paintSwatches()
		Kit.setEnabled(playButton, true)
	end
	showPanel(lobbyCard, next == "lobby")
	if next ~= "lobby" and Kit.selectedIn(lobbyCard) then
		Kit.focus(nil)
	end
	if next ~= "lobby" and not cardPanel.Visible then
		cardPanel.Position = UDim2.new(0.5, 0, 0, math.max(CARD.MinY, capsuleBottom() + CARD.Clear))
	end
	showPanel(cardPanel, next ~= "lobby")
	if next ~= "play" then
		rollToken += 1
		setPhase("wait")
		showPanel(controls, false)
		BowlingFx.setAim(0, 0, "off")
	end
	if next ~= "results" then
		if Kit.selectedIn(finishCard) then
			Kit.focus(nil)
		end
		showPanel(finishCard, false)
	else
		resultsAt = os.clock()
	end
	if next == "lobby" or next == "countdown" then
		calloutToken += 1
		callout.Visible = false
		paintCard(nil, 0)
		highlightFrame(1)
	end
	if next ~= "countdown" and next ~= "play" then
		hideCount()
	end
	bindKeys()
	BowlingFx.setMode(next)
end

-- Events ------------------------------------------------------------------------------------

local function onCountdown(p: any)
	applyMode("countdown")
	local seconds = math.clamp(math.floor(num(p.seconds, 3)), 1, 9)
	countToken += 1
	local mine = countToken
	countSub.Text = "GET READY!"
	Kit.appear(countSub, { from = 0.8, time = 0.25 })
	for i = 0, seconds do
		task.delay(i, function()
			if countToken ~= mine or (mode ~= "countdown" and mode ~= "play") then
				return
			end
			local left = seconds - i
			if left > 0 then
				showCount(tostring(left), C.Gold)
				Sounds.play("Tick", 0, 1 + (seconds - left) * 0.08)
			else
				showCount("GO!", C.Good)
				Sounds.play("Ready")
				Kit.disappear(countSub)
				task.delay(0.7, function()
					if countToken == mine then
						Kit.disappear(countLabel)
					end
				end)
			end
		end)
	end
end

local function onReady(p: any)
	applyMode("play")
	rollToken += 1
	paintCard(p.card, p.total)
	local frame = num(p.frame, 1)
	highlightFrame(frame)
	-- `shot` is the ball of the frame (`ball` is the picked dumbbell).
	frameLabel.Text = "FRAME " .. frame .. "/" .. frames .. "  •  BALL " .. num(p.shot, 1)
	Kit.appear(controls, { from = 0.85, time = 0.2 })
	setPhase("aim")
end

local function onRoll(p: any)
	applyMode("play")
	rollToken += 1
	local mine = rollToken
	setPhase("sent")
	-- A late "roll" after the timeout brought the controls back: hide them again.
	if controls.Visible then
		Kit.disappear(controls)
	end
	local lastT = 0
	local paths = type(p.path) == "table" and p.path or {}
	local endT = num(paths[#paths] and paths[#paths].t, 1.5)
	if type(p.falls) == "table" then
		for _, f in p.falls do
			lastT = math.max(lastT, num(f.t, 0))
		end
	end
	-- The callout lands as the last pin goes down (or as a gutter ball reaches the pit); the
	-- path's times start at the release, after the avatar's run-up.
	local at = num(p.windup, windup) + (if num(p.knocked, 0) > 0 then lastT + 0.3 else endT)
	task.delay(at, function()
		if rollToken ~= mine or not running then
			return
		end
		paintCard(p.card, p.total)
		Kit.pop(totalLabel, 1.2)
		local mark = p.mark
		if mark == "strike" then
			showCallout("STRIKE!", C.Gold, true)
		elseif mark == "spare" then
			showCallout("SPARE!", C.Good, true)
		elseif mark == "gutter" then
			showCallout(if p.gutter then "GUTTER!" else "MISS!", C.TextDim, false)
		else
			showCallout(num(p.knocked, 0) .. (if p.knocked == 1 then " PIN!" else " PINS!"), C.Text, false)
		end
	end)
end

local function onFinish(p: any, won: boolean)
	if type(p.best) == "number" then
		stats.best = p.best
	end
	applyMode("results")
	showFinish(p, won)
end

function BowlingHud.start(payload: { [string]: any }?)
	local p: any = payload or {}
	running = true
	target = num(p.target, target)
	maxScore = num(p.maxScore, maxScore)
	frames = num(p.frames, frames)
	stats.best = num(p.best, stats.best)
	stats.clears = num(p.clears, stats.clears)
	if type(p.rewardPreview) == "table" then
		stats.preview = p.rewardPreview
	end
	if type(p.power) == "table" then
		SWEET.Lo = math.clamp(num(p.power.sweetLo, SWEET.Lo), 0.05, 0.95)
		SWEET.Hi = math.clamp(num(p.power.sweetHi, SWEET.Hi), SWEET.Lo, 1)
		placeZones()
	end
	windup = math.max(num(p.windup, windup), 0)
	if type(p.choice) == "number" then
		pick(p.choice, true)
	end
	board = nil
	pendingPick = nil
	mode = "off"
	finishCard.Visible = false
	controls.Visible = false
	callout.Visible = false
	countLabel.Visible = false
	countSub.Visible = false
	flashLabel.Visible = false
	lobbyCard.Visible = false
	cardPanel.Visible = false
	setChrome(true)
	root.Visible = true
	if not stepConn then
		stepConn = RunService.RenderStepped:Connect(step)
	end
	BowlingFx.setBall(choice)
	-- A server without the lobby (no phase) starts the game straight away.
	local first = if type(p.phase) == "string" then p.phase else (if type(p.lane) == "table" then "play" else "lobby")
	applyMode(if first == "countdown" or first == "play" or first == "results" then first else "lobby")
end

function BowlingHud.stop(_payload: { [string]: any }?)
	if not running then
		return
	end
	running = false
	mode = "off"
	rollToken += 1
	calloutToken += 1
	countToken += 1
	pickToken += 1
	pendingPick = nil
	unbindKeys()
	if stepConn then
		stepConn:Disconnect()
		stepConn = nil
	end
	if Kit.selectedIn(root) then
		Kit.focus(nil)
	end
	setChrome(false)
	BowlingFx.setAim(0, 0, "off")
	-- Safety net (onState, or a missed "stop" notify): Fx puts the pins and camera back.
	BowlingFx.stop(nil)
	root.Visible = false
	finishCard.Visible = false
end

function BowlingHud.onNotify(payload: { [string]: any })
	local event = payload.event
	if event == "start" then
		BowlingHud.start(payload)
	elseif event == "stop" then
		BowlingHud.stop(payload)
	elseif not running then
		return
	elseif event == "lobby" then
		stats.best = num(payload.best, stats.best)
		stats.clears = num(payload.clears, stats.clears)
		if type(payload.rewardPreview) == "table" then
			stats.preview = payload.rewardPreview
		end
		if type(payload.choice) == "number" and pendingPick == nil then
			pick(payload.choice, true)
		end
		applyMode("lobby")
		paintLobby()
	elseif event == "ball" then
		-- The server took a pick: keep it unless the player has already moved on.
		if type(payload.choice) == "number" and pendingPick == nil and os.clock() - pickedAt > PICK_SEND + 0.5 then
			pick(payload.choice, true)
		end
	elseif event == "countdown" then
		onCountdown(payload)
	elseif event == "ready" then
		onReady(payload)
	elseif event == "roll" then
		onRoll(payload)
	elseif event == "win" or event == "lose" then
		onFinish(payload, event == "win")
	elseif event == "again" then
		-- The old flow (no lobby): a new game straight after the last.
		applyMode("play")
		paintCard(nil, 0)
		highlightFrame(1)
	end
end

function BowlingHud.onState(data: any)
	local info = type(data) == "table" and type(data.modes) == "table" and data.modes.bowling
	if not (type(info) == "table" and info.running == true) then
		if running then
			BowlingHud.stop(nil)
		end
		return
	end
	if not running then
		return
	end
	stats.best = num(info.best, stats.best)
	stats.clears = num(info.clears, stats.clears)
	stats.cooldownEnds = num(info.cooldownEnds, stats.cooldownEnds)
	stats.repeatEnds = num(info.repeatEnds, stats.repeatEnds)
	if type(info.rewardPreview) == "table" then
		stats.preview = info.rewardPreview
	end
	target = num(info.target, target)
	-- The server's pick (a rejoin, or one it refused) wins unless the player just picked.
	local theirs = info.choice
	if type(theirs) == "number" and theirs >= 1 and theirs <= BALLS and pendingPick == nil and os.clock() - pickedAt > 2 then
		pick(theirs, true)
	end
	-- Back to the lobby (the results card times out, or the game was called off).
	if info.phase == "lobby" and mode ~= "lobby" and os.clock() - modeAt > PHASE_TRUST then
		applyMode("lobby")
	end
	paintLobby()
end

-- Build -------------------------------------------------------------------------------------

-- Lays the power meter's SWEET and TOO HARD zones out from SWEET.
placeZones = function()
	if sweetBand then
		sweetBand.Position = UDim2.fromScale(SWEET.Lo, 0)
		sweetBand.Size = UDim2.fromScale(SWEET.Hi - SWEET.Lo, 1)
	end
	if wildBand then
		wildBand.Size = UDim2.fromScale(1 - SWEET.Hi, 1)
	end
end

local function buildCard()
	local boxesW = FRAMES * (CARD.BoxW + 4) + CARD.TotalW + CARD.Pad * 2 + 44
	cardPanel = Kit.hudGlass(root, {
		Name = "Scorecard",
		Size = UDim2.fromOffset(boxesW, CARD.BoxH + 34),
		Position = UDim2.new(0.5, 0, 0, CARD.MinY),
		AnchorPoint = Vector2.new(0.5, 0),
		Radius = 18,
	})
	targetChip = Kit.text(cardPanel, {
		Name = "Target",
		Text = "TARGET 50",
		Font = F.Display,
		TextSize = 15,
		TextWrapped = false,
		TextColor3 = C.GoldInk,
		BackgroundColor3 = C.Gold,
		BackgroundTransparency = 0,
		Size = UDim2.fromOffset(112, 22),
		Position = UDim2.new(0.5, 0, 0, 6),
		AnchorPoint = Vector2.new(0.5, 0),
		StrokeThickness = 0,
		ZIndex = 3,
	})
	Kit.round(targetChip)
	for i = 1, FRAMES + 1 do
		local isTotal = i > FRAMES
		local w = if isTotal then CARD.TotalW else CARD.BoxW
		local x = CARD.Pad + (i - 1) * (CARD.BoxW + 4)
		local box = Kit.new("Frame", {
			Name = if isTotal then "Total" else "Frame" .. i,
			BackgroundColor3 = if isTotal then C.Gold else C.Surface,
			BackgroundTransparency = if isTotal then 0.1 else 0.6,
			Size = UDim2.fromOffset(w, CARD.BoxH),
			Position = UDim2.fromOffset(x, 32),
			ZIndex = 2,
			Parent = cardPanel,
		})
		Kit.round(box)
		if isTotal then
			Kit.text(box, {
				Name = "Caption",
				Text = "TOTAL",
				Font = F.Display,
				TextSize = 12,
				TextColor3 = C.GoldInk,
				StrokeThickness = 0,
				Size = UDim2.new(1, 0, 0, 18),
				ZIndex = 3,
			})
			totalLabel = Kit.hudText(box, {
				Name = "Value",
				Text = "0",
				Font = F.Number,
				TextSize = 28,
				Size = UDim2.new(1, 0, 1, -18),
				Position = UDim2.fromOffset(0, 16),
				ZIndex = 3,
			})
		else
			local marks = {}
			for b = 1, 3 do
				-- The third cell only shows in the last frame (its bonus ball).
				local cellW = if i == FRAMES then w / 3 else w / 2
				marks[b] = Kit.hudText(box, {
					Name = "Mark" .. b,
					Text = "",
					Font = F.Display,
					TextSize = 18,
					StrokeThickness = 1.5,
					Size = UDim2.fromOffset(cellW, 24),
					Position = UDim2.fromOffset((b - 1) * cellW, 2),
					Visible = b < 3 or i == FRAMES,
					ZIndex = 3,
				})
			end
			local total = Kit.hudText(box, {
				Name = "Running",
				Text = "",
				Font = F.Number,
				TextSize = 22,
				Size = UDim2.new(1, 0, 0, 28),
				Position = UDim2.fromOffset(0, 28),
				ZIndex = 3,
			})
			frameBoxes[i] = { marks = marks, total = total, box = box }
		end
	end
	quitButton = Kit.button(cardPanel, {
		Name = "Quit",
		Text = "X",
		Color = C.SurfaceHi,
		TextSize = 14,
		Size = UDim2.fromOffset(30, 28),
		Position = UDim2.new(1, -8, 0, 46),
		AnchorPoint = Vector2.new(1, 0),
		Radius = 14,
		Depth = 2,
		ZIndex = 4,
	}, quitPress)
	Kit.selectable(quitButton)
	local quitHit = Kit.hitArea(quitButton, 48, function()
		Kit.sound("Click")
		quitPress()
	end)
	quitHit.Visible = Kit.touch
	Kit.onInput(function()
		quitHit.Visible = Kit.touch
		if not quitArmed then
			Kit.setButton(quitButton, if Kit.gamepad then "Y" else "X", C.SurfaceHi)
		end
		if running and (phase == "aim" or phase == "power") then
			paintPrompt()
		end
	end)
end

-- On touch screens the bottom panels keep clear of the thumbstick (bottom left) and the jump
-- button (bottom right): they sit between them, shrunk to fit on narrow phones. The scale is
-- on a holder frame, so Kit.appear's own scale on the panel inside never undoes it.
local TOUCH_CLEAR = { Left = 210, Right = 170, MinScale = 0.68 }

local function layoutBottom(holder: Frame, scale: UIScale, w: number, minScale: number)
	if not holder or not screen then
		return
	end
	local width = (screen :: ScreenGui).AbsoluteSize.X / Kit.pixelScale(root)
	if Kit.touch and width > 0 then
		local room = width - TOUCH_CLEAR.Left - TOUCH_CLEAR.Right
		scale.Scale = math.clamp(room / w, minScale, 1)
		local centre = TOUCH_CLEAR.Left + room / 2
		-- Still too narrow: centre it and lift it over the thumbstick ring instead.
		local lift = if room < w * minScale then 70 else 0
		if lift > 0 then
			centre = width / 2
		end
		holder.Position = UDim2.new(0, centre, 1, -CONTROLS.Bottom - lift)
	else
		scale.Scale = 1
		holder.Position = UDim2.new(0.5, 0, 1, -CONTROLS.Bottom)
	end
end

local function bottomHolder(name: string, w: number, h: number): (Frame, UIScale)
	local holder = Kit.new("Frame", {
		Name = name,
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(w, h),
		Position = UDim2.new(0.5, 0, 1, -CONTROLS.Bottom),
		AnchorPoint = Vector2.new(0.5, 1),
		Parent = root,
	})
	local scale = Instance.new("UIScale")
	scale.Parent = holder
	return holder, scale
end

local function buildControls()
	controlsHolder, controlsScale = bottomHolder("ControlsHolder", CONTROLS.W, CONTROLS.H)
	controls = Kit.hudGlass(controlsHolder, {
		Name = "Controls",
		Size = UDim2.fromScale(1, 1),
		Radius = 22,
		Visible = false,
	})
	flashLabel = Kit.hudText(controlsHolder, {
		Name = "Flash",
		Text = "",
		TextSize = 30,
		StrokeThickness = 3,
		Size = UDim2.new(1, 0, 0, 36),
		Position = UDim2.new(0.5, 0, 0, -8),
		AnchorPoint = Vector2.new(0.5, 1),
		Visible = false,
		ZIndex = 12,
	})
	frameLabel = Kit.hudText(controls, {
		Name = "Frame",
		Text = "FRAME 1/5",
		TextSize = 16,
		TextColor3 = C.TextDim,
		Size = UDim2.new(1, 0, 0, 20),
		Position = UDim2.fromOffset(0, 8),
		ZIndex = 3,
	})
	-- The lane strip: honey wood with red gutters at both ends, the gold pocket and a centre mark.
	aimStrip = Kit.new("Frame", {
		Name = "AimStrip",
		BackgroundColor3 = Color3.fromRGB(224, 186, 124),
		Size = UDim2.fromOffset(CONTROLS.StripW, CONTROLS.AimH),
		Position = UDim2.new(0.5, 0, 0, 52),
		AnchorPoint = Vector2.new(0.5, 0),
		ZIndex = 3,
		Parent = controls,
	})
	Kit.round(aimStrip)
	Kit.stroke(aimStrip, 2, C.Ink)
	for _, side in { 0, 1 } do
		local gutter = Kit.new("Frame", {
			Name = "Gutter",
			BackgroundColor3 = C.Bad,
			BackgroundTransparency = 0.25,
			-- |aim| past about 0.73 is a gutter ball (BowlingRules.GUTTER_X and AIM_SPREAD).
			Size = UDim2.fromScale(0.135, 1),
			Position = UDim2.fromScale(side, 0),
			AnchorPoint = Vector2.new(side, 0),
			ZIndex = 4,
			Parent = aimStrip,
		})
		Kit.round(gutter)
	end
	local pocket = Kit.new("Frame", {
		Name = "Pocket",
		BackgroundColor3 = C.Gold,
		BackgroundTransparency = 0.35,
		Size = UDim2.new(POCKET, 0, 1, -6),
		Position = UDim2.fromScale(0.5, 0.5),
		AnchorPoint = Vector2.new(0.5, 0.5),
		ZIndex = 4,
		Parent = aimStrip,
	})
	Kit.round(pocket)
	Kit.new("Frame", {
		Name = "Centre",
		BackgroundColor3 = C.Ink,
		BackgroundTransparency = 0.4,
		Size = UDim2.new(0, 3, 1, -8),
		Position = UDim2.fromScale(0.5, 0.5),
		AnchorPoint = Vector2.new(0.5, 0.5),
		ZIndex = 5,
		Parent = aimStrip,
	})
	aimLock = Kit.new("Frame", {
		Name = "Lock",
		BackgroundColor3 = C.Gold,
		Size = UDim2.new(0, 8, 1, 6),
		AnchorPoint = Vector2.new(0.5, 0.5),
		Visible = false,
		ZIndex = 6,
		Parent = aimStrip,
	})
	Kit.round(aimLock)
	Kit.stroke(aimLock, 1.5, C.Ink)
	aimArrow = Kit.hudText(aimStrip, {
		Name = "Arrow",
		Text = "▼",
		TextSize = 30,
		TextColor3 = C.Gold,
		Size = UDim2.fromOffset(36, 30),
		Position = UDim2.fromScale(0.5, 0),
		AnchorPoint = Vector2.new(0.5, 0.75),
		ZIndex = 7,
	})
	powerStrip = Kit.new("Frame", {
		Name = "PowerStrip",
		BackgroundColor3 = C.Well,
		Size = UDim2.fromOffset(CONTROLS.StripW, CONTROLS.PowerH),
		Position = UDim2.new(0.5, 0, 0, 96),
		AnchorPoint = Vector2.new(0.5, 0),
		ClipsDescendants = true,
		ZIndex = 3,
		Parent = controls,
	})
	Kit.round(powerStrip)
	Kit.stroke(powerStrip, 2, C.Ink)
	powerFill = Kit.new("Frame", {
		Name = "Fill",
		BackgroundColor3 = C.Good,
		Size = UDim2.fromScale(0, 1),
		ZIndex = 4,
		Parent = powerStrip,
	})
	Kit.round(powerFill)
	-- The meter's zones (placed by placeZones): the gold SWEET spot to stop the fill in, and
	-- the red TOO HARD top where the dumbbell goes wild.
	sweetBand = Kit.new("Frame", {
		Name = "SweetZone",
		BackgroundColor3 = C.GoldLight,
		BackgroundTransparency = 0.45,
		ZIndex = 5,
		Parent = powerStrip,
	})
	Kit.stroke(sweetBand, 2, C.Gold)
	Kit.hudText(sweetBand, {
		Name = "Caption",
		Text = "SWEET",
		TextSize = 13,
		TextColor3 = C.Gold,
		Size = UDim2.fromScale(1, 1),
		ZIndex = 6,
	})
	wildBand = Kit.new("Frame", {
		Name = "WildZone",
		BackgroundColor3 = C.Bad,
		BackgroundTransparency = 0.55,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.fromScale(1, 0),
		ZIndex = 5,
		Parent = powerStrip,
	})
	Kit.hudText(wildBand, {
		Name = "Caption",
		Text = "!",
		TextSize = 14,
		TextColor3 = C.Bad,
		Size = UDim2.fromScale(1, 1),
		ZIndex = 6,
	})
	placeZones()
	Kit.hudText(powerStrip, {
		Name = "Caption",
		Text = "POWER",
		TextSize = 14,
		Size = UDim2.new(SWEET.Lo, 0, 1, 0),
		ZIndex = 6,
	})
	promptLabel = Kit.hudText(controls, {
		Name = "Prompt",
		Text = "",
		TextSize = 22,
		Size = UDim2.new(1, 0, 0, 30),
		Position = UDim2.new(0, 0, 1, -38),
		ZIndex = 3,
	})
	-- The whole panel is the tap target (mouse and touch).
	local tap = Kit.new("TextButton", {
		Name = "Tap",
		Text = "",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 24, 1, 24),
		Position = UDim2.fromScale(0.5, 0.5),
		AnchorPoint = Vector2.new(0.5, 0.5),
		ZIndex = 10,
		-- Gamepad A is bound through ContextActionService; a selectable button would fire twice.
		Selectable = false,
		Parent = controls,
	})
	tap.Activated:Connect(press)
end

-- A swatch: a dark disc with a little dumbbell (two plates in the pick's colour on a bar).
local function buildSwatch(parent: Instance, i: number, x: number, y: number)
	local size = LOBBY.Swatch
	local button = Kit.new("TextButton", {
		Name = "Ball" .. i,
		Text = "",
		AutoButtonColor = false,
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(size, size),
		Position = UDim2.fromOffset(x, y),
		ZIndex = 4,
		Parent = parent,
	})
	local face = Kit.new("Frame", {
		Name = "Face",
		BackgroundColor3 = C.Well,
		Size = UDim2.fromScale(1, 1),
		ZIndex = 4,
		Parent = button,
	})
	Kit.round(face)
	local ring = Kit.stroke(face, 2, C.Edge)
	ring.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	Kit.new("Frame", {
		Name = "Bar",
		BackgroundColor3 = Color3.fromRGB(214, 220, 236),
		Size = UDim2.fromOffset(30, 6),
		Position = UDim2.fromScale(0.5, 0.5),
		AnchorPoint = Vector2.new(0.5, 0.5),
		ZIndex = 5,
		Parent = face,
	})
	for _, side in { -1, 1 } do
		local plate = Kit.new("Frame", {
			Name = "Plate",
			BackgroundColor3 = BowlingFx.ballColor(i),
			Size = UDim2.fromOffset(11, 28),
			Position = UDim2.new(0.5, side * 10, 0.5, 0),
			AnchorPoint = Vector2.new(0.5, 0.5),
			ZIndex = 6,
			Parent = face,
		})
		Kit.corner(plate, 4)
		Kit.stroke(plate, 1.5, C.Ink)
	end
	Kit.selectable(button)
	button.Activated:Connect(function()
		pick(i)
	end)
	swatches[i] = { button = button, ring = ring, face = face }
end

local function buildLobby()
	lobbyHolder, lobbyScale = bottomHolder("LobbyHolder", LOBBY.W, LOBBY.H)
	lobbyCard = Kit.hudGlass(lobbyHolder, {
		Name = "Lobby",
		Size = UDim2.fromScale(1, 1),
		Radius = 26,
		Visible = false,
	})
	local pad = 18
	Kit.hudText(lobbyCard, {
		Name = "Title",
		Text = "DUMBBELL BOWL",
		TextSize = 28,
		TextColor3 = C.Gold,
		TextXAlignment = Enum.TextXAlignment.Left,
		Size = UDim2.fromOffset(300, 34),
		Position = UDim2.fromOffset(pad, 12),
		ZIndex = 3,
	})
	leaveButton = Kit.button(lobbyCard, {
		Name = "Leave",
		Text = "LEAVE",
		Color = C.SurfaceHi,
		TextSize = 16,
		Size = UDim2.fromOffset(100, 44),
		Position = UDim2.new(1, -14, 0, 12),
		AnchorPoint = Vector2.new(1, 0),
		ZIndex = 4,
	}, function()
		leavePress(false)
	end)
	Kit.selectable(leaveButton)
	goalLabel = Kit.hudText(lobbyCard, {
		Name = "Goal",
		Text = "",
		TextSize = 18,
		TextXAlignment = Enum.TextXAlignment.Left,
		Size = UDim2.new(1, -pad * 2 - 120, 0, 22),
		Position = UDim2.fromOffset(pad, 50),
		ZIndex = 3,
	})
	bestPill = Kit.pill(lobbyCard, {
		Name = "Best",
		Text = "NO BEST YET",
		Color = C.Gold,
		Solid = true,
		Font = F.Display,
		TextSize = 14,
		Size = UDim2.fromOffset(112, 26),
		Position = UDim2.new(1, -14, 0, 64),
		AnchorPoint = Vector2.new(1, 0),
		ZIndex = 4,
	})
	rewardLabel = Kit.hudText(lobbyCard, {
		Name = "Reward",
		Text = "",
		TextSize = 15,
		StrokeThickness = 2,
		TextXAlignment = Enum.TextXAlignment.Left,
		Size = UDim2.new(1, -pad * 2 - 120, 0, 20),
		Position = UDim2.fromOffset(pad, 74),
		ZIndex = 3,
	})
	rewardLabel.TextTruncate = Enum.TextTruncate.AtEnd
	pickCaption = Kit.hudText(lobbyCard, {
		Name = "PickCaption",
		Text = "PICK YOUR DUMBBELL",
		TextSize = 13,
		TextColor3 = C.TextDim,
		StrokeThickness = 1.5,
		TextXAlignment = Enum.TextXAlignment.Left,
		Size = UDim2.fromOffset(240, 18),
		Position = UDim2.fromOffset(pad, 108),
		ZIndex = 3,
	})
	for i = 1, BALLS do
		buildSwatch(lobbyCard, i, pad + (i - 1) * (LOBBY.Swatch + LOBBY.SwatchGap), 132)
	end
	playButton = Kit.button(lobbyCard, {
		Name = "Play",
		Text = "PLAY",
		Color = C.Gold,
		Font = F.Display,
		TextSize = 30,
		Size = UDim2.fromOffset(LOBBY.PlayW, LOBBY.PlayH),
		Position = UDim2.new(1, -14, 1, -14),
		AnchorPoint = Vector2.new(1, 1),
		ZIndex = 4,
	}, begin)
	Kit.selectable(playButton)
	playButton:SetAttribute("FocusFirst", true)
	playKey = Kit.pill(playButton, {
		Name = "Key",
		Text = "ENTER",
		Color = C.Ink,
		Solid = true,
		Font = F.Display,
		TextSize = 12,
		Size = UDim2.fromOffset(52, 20),
		Position = UDim2.new(1, 6, 0, -8),
		AnchorPoint = Vector2.new(1, 0),
		ZIndex = 8,
	})
	Kit.breathe(playButton, 0.04)
	Kit.onInput(function()
		playKey.Visible = not Kit.touch
		playKey.Text = if Kit.gamepad then "X" else "ENTER"
		playKey.Size = UDim2.fromOffset(if Kit.gamepad then 26 else 52, 20)
		-- The results card's PLAY AGAIN shows the same key (built after the lobby card).
		local key = againKey :: TextLabel?
		if key then
			key.Visible = playKey.Visible
			key.Text = playKey.Text
			key.Size = playKey.Size
		end
		pickCaption.Text = if Kit.gamepad then "PICK YOUR DUMBBELL  (LB / RB)" else "PICK YOUR DUMBBELL"
	end)
end

local function buildCountdown()
	countLabel = Kit.hudText(root, {
		Name = "Countdown",
		Text = "",
		Font = F.Number,
		TextSize = 150,
		StrokeThickness = 7,
		Size = UDim2.fromOffset(420, 170),
		Position = UDim2.fromScale(0.5, 0.42),
		AnchorPoint = Vector2.new(0.5, 0.5),
		Visible = false,
		ZIndex = 35,
	})
	countSub = Kit.hudText(root, {
		Name = "CountdownSub",
		Text = "GET READY!",
		TextSize = 28,
		StrokeThickness = 3,
		Size = UDim2.fromOffset(420, 36),
		Position = UDim2.new(0.5, 0, 0.42, 96),
		AnchorPoint = Vector2.new(0.5, 0.5),
		Visible = false,
		ZIndex = 35,
	})
end

local function buildFinish()
	finishCard = Kit.panel(root, {
		Name = "Finish",
		Size = UDim2.fromOffset(400, 340),
		Position = UDim2.fromScale(0.5, 0.5),
		AnchorPoint = Vector2.new(0.5, 0.5),
		Visible = false,
		ZIndex = 40,
	})
	finishTitle = Kit.hudText(finishCard, {
		Name = "Title",
		Text = "",
		TextSize = 38,
		Size = UDim2.new(1, 0, 0, 46),
		Position = UDim2.fromOffset(0, 14),
		ZIndex = 41,
	})
	finishScore = Kit.hudText(finishCard, {
		Name = "Score",
		Text = "0",
		Font = F.Number,
		TextSize = 64,
		Size = UDim2.new(1, 0, 0, 70),
		Position = UDim2.fromOffset(0, 58),
		ZIndex = 41,
	})
	finishBest = Kit.text(finishCard, {
		Name = "NewBest",
		Text = "NEW BEST!",
		Font = F.Display,
		TextSize = 15,
		TextWrapped = false,
		TextColor3 = C.GoldInk,
		BackgroundColor3 = C.Gold,
		BackgroundTransparency = 0,
		Size = UDim2.fromOffset(110, 26),
		Position = UDim2.new(1, -16, 0, 70),
		AnchorPoint = Vector2.new(1, 0),
		StrokeThickness = 0,
		Rotation = 8,
		Visible = false,
		ZIndex = 42,
	})
	Kit.round(finishBest)
	Kit.stroke(finishBest, 2, C.GoldDeep)
	finishBestLine = Kit.hudText(finishCard, {
		Name = "Best",
		Text = "",
		TextSize = 17,
		TextColor3 = C.TextDim,
		Size = UDim2.new(1, -24, 0, 22),
		Position = UDim2.fromOffset(12, 128),
		ZIndex = 41,
	})
	finishSub = Kit.hudText(finishCard, {
		Name = "Sub",
		Text = "",
		TextSize = 17,
		TextColor3 = C.TextDim,
		Size = UDim2.new(1, -24, 0, 22),
		Position = UDim2.fromOffset(12, 152),
		ZIndex = 41,
	})
	finishCash = Kit.hudText(finishCard, {
		Name = "Cash",
		Text = "",
		Font = F.Number,
		TextSize = 30,
		TextColor3 = C.MoneyText,
		Size = UDim2.new(1, 0, 0, 36),
		Position = UDim2.fromOffset(0, 178),
		Visible = false,
		ZIndex = 41,
	})
	finishBack = Kit.hudText(finishCard, {
		Name = "Back",
		Text = "",
		TextSize = 14,
		TextColor3 = C.TextDim,
		StrokeThickness = 1.5,
		Size = UDim2.new(1, 0, 0, 18),
		Position = UDim2.new(0, 0, 1, -94),
		ZIndex = 41,
	})
	againButton = Kit.button(finishCard, {
		Name = "Again",
		Text = "PLAY AGAIN",
		Color = C.Good,
		TextSize = 20,
		Size = UDim2.fromOffset(180, 56),
		Position = UDim2.new(0.5, -6, 1, -18),
		AnchorPoint = Vector2.new(1, 1),
		ZIndex = 42,
	}, begin)
	againButton:SetAttribute("FocusFirst", true)
	againKey = Kit.pill(againButton, {
		Name = "Key",
		Text = if Kit.gamepad then "X" else "ENTER",
		Color = C.Ink,
		Solid = true,
		Font = F.Display,
		TextSize = 12,
		Size = UDim2.fromOffset(if Kit.gamepad then 26 else 52, 20),
		Position = UDim2.new(1, 6, 0, -8),
		AnchorPoint = Vector2.new(1, 0),
		ZIndex = 44,
	})
	againKey.Visible = not Kit.touch
	lobbyButton = Kit.button(finishCard, {
		Name = "Lobby",
		Text = "LOBBY",
		Color = C.SurfaceHi,
		TextSize = 20,
		Size = UDim2.fromOffset(150, 56),
		Position = UDim2.new(0.5, 6, 1, -18),
		AnchorPoint = Vector2.new(0, 1),
		ZIndex = 42,
	}, toLobby)
end

local function layoutAll()
	layoutBottom(controlsHolder, controlsScale, CONTROLS.W, TOUCH_CLEAR.MinScale)
	-- The lobby card keeps its swatches and buttons at a thumb's size: it shrinks less.
	layoutBottom(lobbyHolder, lobbyScale, LOBBY.W, 0.85)
end

function BowlingHud.init(screenGui: ScreenGui)
	screen = screenGui
	root = Kit.new("Frame", {
		Name = "BowlingHud",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		Visible = false,
		ZIndex = 20,
		Parent = screenGui,
	})
	buildCard()
	buildControls()
	buildLobby()
	callout = Kit.hudText(root, {
		Name = "Callout",
		Text = "",
		TextSize = CALLOUT.TextSize,
		StrokeThickness = 5,
		Size = UDim2.fromOffset(600, 100),
		Position = UDim2.fromScale(0.5, 0.38),
		AnchorPoint = Vector2.new(0.5, 0.5),
		Visible = false,
		ZIndex = 30,
	})
	buildCountdown()
	buildFinish()
	layoutAll()
	screenGui:GetPropertyChangedSignal("AbsoluteSize"):Connect(layoutAll)
	Kit.onInput(layoutAll)
end

return BowlingHud
