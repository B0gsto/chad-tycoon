--!strict
--[[
	BowlingHud: the screen side of DUMBBELL BOWL (Modes.Bowling; docs/minigames.md). Fx.Bowling
	does the 3D side; this module drives its aim guide (Fx.Bowling.setAim) every frame of a turn.

	  Scorecard   top centre, under the HUD's unit-count capsule: five frame boxes (two mark
	              cells, "X" / "/" / "-" / digits, and the running total once known), the
	              TOTAL box, a gold "TARGET n" chip (it turns mint once the total passes it)
	              and the quiet quit "X" (first tap arms "QUIT?", the second fires ModeQuit;
	              gamepad Y / B press it).
	  Controls    bottom centre, one big tap target (the whole panel; also Space, Enter and
	              gamepad A, sunk so Space does not jump). On "ready" an arrow sweeps the lane
	              strip (a constant-speed back-and-forth, gutters red at both ends): the first
	              press locks the aim; then the power bar fills and empties: the second press
	              sends "BowlingRoll" { aim, power }. The panel fades while the ball rolls.
	  Callouts    centre: "STRIKE!" / "SPARE!" (gold / mint, confetti), "GUTTER!" or the pin
	              count pop in when the last pin falls; the card updates at the same moment.
	  Finish      a centre card: "YOU PASSED!" with the cash ("Run again bonus" when the pay
	              is the repeat share) or "SO CLOSE!" with the points still missing, the score,
	              "NEW BEST!" and PLAY AGAIN ("BowlingAgain") / LEAVE ("ModeQuit").

	Wired from Main.client.luau (nothing else needs editing):
	  init(screen)        once, builds the HUD (hidden)
	  onNotify(payload)   every Notify with kind = "Mode" and mode = "bowling"
	  onState(data)       every State snapshot (safety net: hides when modes.bowling is not running)
	  start(payload) / stop(payload)
]]

local ContextActionService = game:GetService("ContextActionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

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
-- Scorecard: frame box size, the TOTAL box, the gap to the unit-count capsule.
local CARD = { BoxW = 56, BoxH = 58, TotalW = 74, Pad = 8, MinY = 120, Clear = 12 }
-- The controls panel (bottom centre) and its two strips.
local CONTROLS = { W = 440, H = 168, Bottom = 28, StripW = 384, AimH = 34, PowerH = 26 }
-- Seconds for the aim arrow to cross the lane one way, and the power bar to fill once.
local SWEEP = { Aim = 1.25, Power = 0.85 }
-- Callout word: pop scale, hold and fade.
local CALLOUT = { TextSize = 84, Hold = 1.1, Rise = 40 }
local ACTION = "BowlingPress"
local QUIT_ACTION = "BowlingQuit"
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
local controls: GuiObject
local promptLabel: TextLabel
local frameLabel: TextLabel
local aimStrip: Frame
local aimArrow: TextLabel
local aimLock: Frame
local powerStrip: Frame
local powerFill: Frame
local callout: TextLabel
local finishCard: Frame
local finishTitle: TextLabel
local finishScore: TextLabel
local finishSub: TextLabel
local finishCash: TextLabel
local finishBest: TextLabel
local againButton: TextButton

local running = false
-- "wait" (not your turn), "aim" (arrow sweeping), "power" (bar filling), "sent".
local phase = "wait"
local phaseAt = 0
local aim, power = 0, 0
local target = 50
local quitArmed = false
local stepConn: RBXScriptConnection? = nil
local calloutToken = 0
local rollToken = 0

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

-- Callouts and finish ---------------------------------------------------------------------

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

local function showFinish(p: any, won: boolean)
	local score = num(p.score, 0)
	finishTitle.Text = if won then "YOU PASSED!" else "SO CLOSE!"
	finishTitle.TextColor3 = if won then C.Gold else C.Text
	finishScore.Text = tostring(score)
	if won then
		finishSub.Text = "Target " .. num(p.target, target) .. " smashed!"
		local cash = num(p.cash, 0)
		finishCash.Visible = cash > 0
		finishCash.Text = (if p.pay == "repeat" then "Run again bonus +" else "+") .. Format.money(cash)
	else
		finishSub.Text = (num(p.target, target) - score) .. " more points to pass. Try again!"
		finishCash.Visible = false
	end
	finishBest.Visible = p.newBest == true
	finishCard.Visible = true
	Kit.appear(finishCard, { from = 0.6, time = 0.35 })
	Kit.selectable(againButton)
	if won then
		Sounds.play("Celebrate")
		if not reducedMotion() then
			Kit.confetti(finishCard, { Origin = UDim2.fromScale(0.5, 0.2), Count = 40, ZIndex = 41, Power = 1.4 })
		end
	end
end

-- Turn and input ----------------------------------------------------------------------------

local function setPhase(next: string)
	phase = next
	phaseAt = os.clock()
	local hint = Kit.keyHint("confirm")
	if next == "aim" then
		promptLabel.Text = if Kit.touch then "TAP TO AIM" else hint .. "  TO AIM"
		promptLabel.TextColor3 = C.Text
		aimLock.Visible = false
		powerFill.Size = UDim2.fromScale(0, 1)
	elseif next == "power" then
		promptLabel.Text = if Kit.touch then "TAP TO ROLL!" else hint .. "  TO ROLL!"
		promptLabel.TextColor3 = C.Gold
	end
end

local function press()
	if not running then
		return
	end
	if phase == "aim" then
		aimLock.Position = UDim2.fromScale((aim + 1) / 2, 0.5)
		aimLock.Visible = true
		Kit.pop(aimStrip, 1.04)
		Kit.sound("Click")
		setPhase("power")
	elseif phase == "power" then
		setPhase("sent")
		Kit.pop(powerStrip, 1.06)
		BowlingFx.setAim(aim, power, "off")
		action:FireServer({ action = "BowlingRoll", aim = aim, power = power })
		Kit.disappear(controls)
	end
end

local function step()
	if not running then
		return
	end
	local t = os.clock() - phaseAt
	if phase == "aim" then
		aim = bounce(t + SWEEP.Aim / 2, SWEEP.Aim) * 2 - 1
		aimArrow.Position = UDim2.fromScale((aim + 1) / 2, 0)
		BowlingFx.setAim(aim, 0, "aim")
	elseif phase == "power" then
		power = bounce(t, SWEEP.Power)
		powerFill.Size = UDim2.fromScale(power, 1)
		powerFill.BackgroundColor3 = C.Good:Lerp(C.Gold, math.min(power * 2, 1)):Lerp(C.Bad, math.max(power * 2 - 1, 0) * 0.6)
		BowlingFx.setAim(aim, power, "power")
	end
end

local function onAction(_name: string, state: Enum.UserInputState, _input: InputObject): Enum.ContextActionResult
	if state == Enum.UserInputState.Begin and finishCard.Visible == false then
		press()
	end
	return Enum.ContextActionResult.Sink
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

local function bind()
	ContextActionService:BindActionAtPriority(
		ACTION,
		onAction,
		false,
		PRIORITY,
		Enum.KeyCode.Space,
		Enum.KeyCode.Return,
		Enum.KeyCode.ButtonA
	)
	ContextActionService:BindActionAtPriority(QUIT_ACTION, function(_, state)
		if state == Enum.UserInputState.Begin then
			quitPress()
		end
		return Enum.ContextActionResult.Sink
	end, false, PRIORITY, Enum.KeyCode.ButtonY, Enum.KeyCode.ButtonB)
	if not stepConn then
		stepConn = RunService.RenderStepped:Connect(step)
	end
end

local function unbind()
	ContextActionService:UnbindAction(ACTION)
	ContextActionService:UnbindAction(QUIT_ACTION)
	if stepConn then
		stepConn:Disconnect()
		stepConn = nil
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

-- Events ------------------------------------------------------------------------------------

local function onReady(p: any)
	rollToken += 1
	paintCard(p.card, p.total)
	local frame = num(p.frame, 1)
	highlightFrame(frame)
	frameLabel.Text = "FRAME " .. frame .. "/" .. FRAMES .. "  •  BALL " .. num(p.ball, 1)
	controls.Visible = true
	Kit.appear(controls, { from = 0.85, time = 0.2 })
	setPhase("aim")
end

local function onRoll(p: any)
	rollToken += 1
	local mine = rollToken
	setPhase("sent")
	local lastT = 0
	local paths = type(p.path) == "table" and p.path or {}
	local endT = num(paths[#paths] and paths[#paths].t, 1.5)
	if type(p.falls) == "table" then
		for _, f in p.falls do
			lastT = math.max(lastT, num(f.t, 0))
		end
	end
	-- The callout lands as the last pin goes down (or as a gutter ball reaches the pit).
	local at = if num(p.knocked, 0) > 0 then lastT + 0.3 else endT
	task.delay(at, function()
		if rollToken ~= mine or not running then
			return
		end
		paintCard(p.card, p.total)
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

function BowlingHud.start(payload: { [string]: any }?)
	local p: any = payload or {}
	running = true
	quitArmed = false
	target = num(p.target, target)
	paintCard(nil, 0)
	highlightFrame(1)
	finishCard.Visible = false
	controls.Visible = false
	callout.Visible = false
	Kit.setButton(quitButton, if Kit.gamepad then "Y" else "X", C.SurfaceHi)
	quitButton.Size = UDim2.fromOffset(30, 28)
	setChrome(true)
	cardPanel.Position = UDim2.new(0.5, 0, 0, math.max(CARD.MinY, capsuleBottom() + CARD.Clear))
	root.Visible = true
	Kit.appear(cardPanel, { from = 0.8, time = 0.25 })
	setPhase("wait")
	bind()
end

function BowlingHud.stop(_payload: { [string]: any }?)
	if not running then
		return
	end
	running = false
	rollToken += 1
	calloutToken += 1
	unbind()
	setChrome(false)
	BowlingFx.setAim(0, 0, "off")
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
	elseif event == "ready" then
		onReady(payload)
	elseif event == "roll" then
		onRoll(payload)
	elseif event == "win" or event == "lose" then
		controls.Visible = false
		setPhase("wait")
		showFinish(payload, event == "win")
	elseif event == "again" then
		finishCard.Visible = false
		paintCard(nil, 0)
		highlightFrame(1)
	end
end

function BowlingHud.onState(data: any)
	local info = type(data) == "table" and type(data.modes) == "table" and data.modes.bowling
	if running and not (type(info) == "table" and info.running == true) then
		BowlingHud.stop(nil)
	end
end

-- Build -------------------------------------------------------------------------------------

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
		if running and (phase == "aim" or phase == "power") then
			setPhase(phase)
		end
	end)
end

local function buildControls()
	controls = Kit.hudGlass(root, {
		Name = "Controls",
		Size = UDim2.fromOffset(CONTROLS.W, CONTROLS.H),
		Position = UDim2.new(0.5, 0, 1, -CONTROLS.Bottom),
		AnchorPoint = Vector2.new(0.5, 1),
		Radius = 22,
		Visible = false,
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
	-- The lane strip: honey wood with red gutters at both ends and a centre mark.
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
	Kit.new("Frame", {
		Name = "Centre",
		BackgroundColor3 = C.Ink,
		BackgroundTransparency = 0.4,
		Size = UDim2.new(0, 3, 1, -8),
		Position = UDim2.fromScale(0.5, 0.5),
		AnchorPoint = Vector2.new(0.5, 0.5),
		ZIndex = 4,
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
	Kit.hudText(powerStrip, {
		Name = "Caption",
		Text = "POWER",
		TextSize = 14,
		Size = UDim2.fromScale(1, 1),
		ZIndex = 5,
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
		Parent = controls,
	})
	tap.Activated:Connect(press)
end

local function buildFinish()
	finishCard = Kit.panel(root, {
		Name = "Finish",
		Size = UDim2.fromOffset(380, 300),
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
		Position = UDim2.fromOffset(0, 16),
		ZIndex = 41,
	})
	finishScore = Kit.hudText(finishCard, {
		Name = "Score",
		Text = "0",
		Font = F.Number,
		TextSize = 64,
		Size = UDim2.new(1, 0, 0, 70),
		Position = UDim2.fromOffset(0, 62),
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
		Size = UDim2.fromOffset(110, 24),
		Position = UDim2.new(1, -16, 0, 74),
		AnchorPoint = Vector2.new(1, 0),
		StrokeThickness = 0,
		Rotation = 8,
		Visible = false,
		ZIndex = 42,
	})
	Kit.round(finishBest)
	finishSub = Kit.hudText(finishCard, {
		Name = "Sub",
		Text = "",
		TextSize = 17,
		TextColor3 = C.TextDim,
		Size = UDim2.new(1, -24, 0, 22),
		Position = UDim2.fromOffset(12, 136),
		ZIndex = 41,
	})
	finishCash = Kit.hudText(finishCard, {
		Name = "Cash",
		Text = "",
		Font = F.Number,
		TextSize = 30,
		TextColor3 = C.MoneyText,
		Size = UDim2.new(1, 0, 0, 36),
		Position = UDim2.fromOffset(0, 164),
		Visible = false,
		ZIndex = 41,
	})
	againButton = Kit.button(finishCard, {
		Name = "Again",
		Text = "PLAY AGAIN",
		Color = C.Good,
		TextSize = 20,
		Size = UDim2.fromOffset(170, 52),
		Position = UDim2.new(0.5, -6, 1, -18),
		AnchorPoint = Vector2.new(1, 1),
		ZIndex = 42,
	}, function()
		action:FireServer({ action = "BowlingAgain" })
	end)
	Kit.button(finishCard, {
		Name = "Leave",
		Text = "LEAVE",
		Color = C.SurfaceHi,
		TextSize = 20,
		Size = UDim2.fromOffset(150, 52),
		Position = UDim2.new(0.5, 6, 1, -18),
		AnchorPoint = Vector2.new(0, 1),
		ZIndex = 42,
	}, function()
		action:FireServer({ action = "ModeQuit" })
	end)
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
	buildFinish()
end

return BowlingHud
