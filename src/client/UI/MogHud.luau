--!strict
--[[
	MogHud: the screen side of the MOG TEST, a skill-check duel either against rival chads
	(vs = "rivals", solo) or against a real player (vs = "pvp", 1v1).

	  Picker       Notify "choose" (the player walked through the mog gate) and the Modes
	               window's PLAY open Popups.mogChoose: VS RIVALS or 1v1 DUEL, which fire
	               ModeStart with vs = "rivals" | "pvp".
	  Queue        "queue" { since, timeout }: a compact "FINDING OPPONENT…" panel on the
	               right (spinner, dots, elapsed seconds, Cancel = MogCancel); the player
	               walks around meanwhile. "stop" "noOpponent" toasts and reopens the picker.
	               While queued choose() opens no picker and pops the queue panel instead.
	  Ring         centre-right, 180 px, drawn by UI.MogRing: setCheck draws the zone with
	               its swell-in cue, warn() runs every frame until the needle starts, then
	               setNeedle(travel, dir) poses the needle from the server clock (travel =
	               speed * (now - appearAt)), flash() on each result, idle() between checks.
	               The result word ("PERFECT!", "HIT", "MISS" / "TOO EARLY" / "TOO SLOW"
	               in red) pops in on the ring's top edge and rises as it fades.
	  Input        Space, Enter and gamepad A (ContextActionService, high priority, sunk
	               so Space does not jump) and a big invisible button over the ring for
	               mouse / touch. One MogPress per check, sent with the server time of the
	               press; presses before the needle starts only give a small "wait..."
	               wobble. The needle freezes where it was pressed until the result.
	  Status       score (bouncy count) and the combo chip above the ring and a quiet "X"
	               that asks "QUIT?" before firing ModeQuit. Vs rivals: hearts (maxLives)
	               under them and the rival's name and HP bar under the ring. In a duel the
	               hearts become your own HP bar ("YOU", green, gold flash on perfect) and
	               the bottom panel is the opponent's name and red HP bar, both moved by
	               "round" only ("result" is just your own press); the opponent's result
	               shows small under it ("Opponent: PERFECT").
	  Banners      "MOG TEST!" / "1v1 DUEL!" (vs <name>) at the start, "MOGGED!" per rival,
	               "MOG TEST PASSED!" with the cash the first time the run passes,
	               "SUDDEN DEATH!" in a duel.

	MogHud.onNotify(payload) takes every Notify with kind "Mode" and mode "mog" (Main
	routes them); Fx.Mog does the 3D side from the same payloads. MogHud.choose() opens
	the picker (Windows.onMogPlay points here).
]]

local ContextActionService = game:GetService("ContextActionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Theme = require(ReplicatedStorage:WaitForChild("Theme")) :: any
local Format = require(ReplicatedStorage.Shared.Format) :: any
local Net = require(ReplicatedStorage.Shared.Net)

local Client = script.Parent.Parent
local Kit = require(script.Parent.Kit) :: any
local MogRing = require(script.Parent.MogRing) :: any
local Popups = require(script.Parent.Popups) :: any
local Sounds = require(Client.Sounds) :: any

local MogHud = {}

local C = Kit.C
local F = Kit.F
local W = Theme.World

local RING = 180 -- ring diameter (px, design space)
local ACTION = "MogPress"
local PRIORITY = 3000
local RESULT_WORDS = { perfect = "PERFECT", hit = "HIT", miss = "MISS" }

local action = Net.event("Action")

type Check = {
	id: any,
	n: number,
	appearAt: number,
	speed: number,
	dir: number,
	zoneStart: number,
	zoneSize: number,
	perfectSize: number,
}

local screen: ScreenGui? = nil
local root: Frame
local ring: any -- MogRing
local tapHint: TextLabel
local resultLabel: TextLabel
local scoreLabel: TextLabel
local comboChip: TextLabel
local heartsRow: Frame
local youPanel: Frame
local youFill: Frame
local youHpText: TextLabel
local rivalName: TextLabel
local rivalFill: Frame
local rivalHpText: TextLabel
local oppResult: TextLabel
local banner: Frame
local bannerTitle: TextLabel
local bannerSub: TextLabel
local quitButton: TextButton
local queuePanel: Frame
local queueTitle: TextLabel
local queueTime: TextLabel
local queueSpinner: Frame

local active = false
local pvp = false -- this run is a 1v1 duel
local check: Check? = nil
local pressed = false -- this check's press is sent (input locked until the result)
local frozenTravel: number? = nil
local shownScore = 0
local lives, maxLives = 3, 3
local passedShown = false
local quitArmed = false
local warned = false
local bannerToken = 0
local stepConn: RBXScriptConnection? = nil
local queueToken = 0
local choosing = false -- the picker is open (or queued)
local queued = false -- waiting for a duel opponent (the queue panel is up)

local function num(value: any, default: number): number
	return if type(value) == "number" and value == value then value else default
end

-- Hearts ----------------------------------------------------------------------------------

-- A heart from two discs and a 45-degree square.
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

local function paintHeart(holder: Instance, full: boolean)
	for _, f in holder:GetChildren() do
		if f:IsA("Frame") then
			Kit.tween(f, 0.25, { BackgroundColor3 = if full then C.Bad else C.Well })
		end
	end
end

local function setHearts(newLives: number, newMax: number, animate: boolean)
	if newMax ~= maxLives or #heartsRow:GetChildren() <= 1 then
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
			paintHeart(holder, full)
			local pop = holder:FindFirstChild("Pop") :: UIScale?
			if animate and pop and was ~= full then
				-- A lost heart squashes and drops back; a regained one bounces in.
				pop.Scale = if full then 0.4 else 1.5
				Kit.tween(pop, 0.45, { Scale = 1 }, Enum.EasingStyle.Back)
			end
		end
	end
	lives, maxLives = newLives, newMax
end

-- Ring --------------------------------------------------------------------------------------

local function travelNow(c: Check): number
	return math.clamp(c.speed * (Workspace:GetServerTimeNow() - c.appearAt), 0, 360)
end

local showBanner: (title: string, sub: string?, color: Color3, hold: number) -> ()

-- The result word pops in on the ring's top edge (clear of the "#n" centre label) and
-- rises toward the hearts / HP row while it fades.
local RESULT_FROM = UDim2.new(0.5, 0, 0, 6)
local RESULT_TO = UDim2.new(0.5, 0, 0, -16)

local function popResult(text: string, color: Color3)
	resultLabel.Text = text
	resultLabel.TextColor3 = color
	resultLabel.TextTransparency = 0
	resultLabel.Position = RESULT_FROM
	local scale = resultLabel:FindFirstChildOfClass("UIScale") :: UIScale
	scale.Scale = 0.3
	Kit.tween(scale, 0.35, { Scale = 1 }, Enum.EasingStyle.Back)
	Kit.tween(resultLabel, 0.9, { Position = RESULT_TO }, Enum.EasingStyle.Quad)
	task.delay(0.65, function()
		if resultLabel.Text == text then
			Kit.tween(resultLabel, 0.3, { TextTransparency = 1 })
		end
	end)
end

local function setIdle()
	-- Between checks the ring rests small and dim with the needle hidden.
	check, pressed, frozenTravel = nil, false, nil
	ring:idle()
	ring:setNeedle(nil, 1)
	ring:setCentre(if Kit.touch then "TAP" else "SPACE", C.TextDim)
end

local function wobble()
	-- "Wait..." : a little side-to-side shake of the ring, no camera shake.
	ring:setCentre("wait…", C.TextDim)
	local frame: Frame = ring.frame
	local base = UDim2.fromScale(0.5, 0.5)
	task.spawn(function()
		for _, dx in { 6, -6, 4, -3, 0 } do
			frame.Position = base + UDim2.fromOffset(dx, 0)
			task.wait(0.04)
		end
		frame.Position = base
	end)
end

local function press()
	local c = check
	if not active or not c or pressed then
		return
	end
	local now = Workspace:GetServerTimeNow()
	if now < c.appearAt then
		wobble()
		return
	end
	pressed = true
	frozenTravel = travelNow(c)
	Kit.pop(ring.frame, 1.06)
	action:FireServer({ action = "MogPress", id = c.id, at = now })
end

local function onAction(_name: string, state: Enum.UserInputState, _input: InputObject): Enum.ContextActionResult
	if state == Enum.UserInputState.Begin then
		press()
	end
	return Enum.ContextActionResult.Sink
end

local function step()
	local c = check
	if not c then
		return
	end
	local now = Workspace:GetServerTimeNow()
	if now < c.appearAt then
		-- Warning: MogRing breathes its cue until the needle starts.
		ring:warn(now)
		return
	end
	if not warned then
		warned = true
		ring:setCentre("#" .. tostring(c.n), C.Text)
	end
	ring:setNeedle(frozenTravel or travelNow(c), c.dir)
end

local function onCheck(p: any)
	local c: Check = {
		id = p.id,
		n = num(p.n, 1),
		appearAt = num(p.appearAt, Workspace:GetServerTimeNow() + 1),
		speed = math.max(num(p.speed, 180), 1),
		dir = if p.dir == -1 then -1 else 1,
		zoneStart = num(p.zoneStart, 180),
		zoneSize = num(p.zoneSize, 40),
		perfectSize = num(p.perfectSize, 10),
	}
	check, pressed, frozenTravel, warned = c, false, nil, false
	-- The DBD-style warning: tick, and MogRing swells the ring in with the new zone.
	ring:setCheck({ zoneStart = c.zoneStart, zoneSize = c.zoneSize, perfectSize = c.perfectSize, dir = c.dir, n = c.n })
	ring:setNeedle(nil, c.dir)
	ring:setCentre(if Kit.touch then "TAP!" else "SPACE", C.Gold)
	Sounds.play("Tick")
end

-- An HP bar fill and its "hp/max" label; `flash` briefly tints the fill (a hit taken).
local function setBar(fill: Frame, label: TextLabel, hp: number, hpMax: number, flash: Color3?)
	hpMax = math.max(hpMax, 1)
	Kit.tween(fill, 0.35, { Size = UDim2.fromScale(math.clamp(hp / hpMax, 0, 1), 1) }, Enum.EasingStyle.Quart)
	label.Text = string.format("%d/%d", math.max(hp, 0), hpMax)
	if flash then
		local base = fill.BackgroundColor3
		fill.BackgroundColor3 = flash
		Kit.tween(fill, 0.5, { BackgroundColor3 = base })
		Kit.pop(label, 1.25)
	end
end

local function setScore(score: number, combo: number)
	-- Score rolls up with a bounce; the combo chip shows from x2.
	if score ~= shownScore then
		Kit.countTo(scoreLabel, shownScore, score, Format.short, 0.4)
		Kit.pop(scoreLabel, 1.25)
		shownScore = score
	end
	if combo >= 2 then
		comboChip.Text = "x" .. tostring(combo) .. " COMBO"
		if not comboChip.Visible then
			comboChip.Visible = true
			Kit.appear(comboChip, { from = 0.5 })
		else
			Kit.pop(comboChip, 1.2)
		end
	elseif comboChip.Visible then
		comboChip.Visible = false
	end
end

local function onResult(p: any)
	local c = check
	if c and p.id ~= nil and p.id ~= c.id then
		return
	end
	if c then
		local travel = num(p.travel, frozenTravel or travelNow(c))
		frozenTravel = travel
		ring:setNeedle(travel, c.dir)
	end
	local result = p.result
	if result == "perfect" then
		ring:flash("perfect")
		popResult("PERFECT!", C.Gold)
		Sounds.play("Coin", 0.05, 1.15)
	elseif result == "hit" then
		ring:flash("hit")
		popResult("HIT", W.Cream)
		Sounds.play("Pickup", 0.08)
	else
		ring:flash("miss")
		popResult(if p.reason == "early" then "TOO EARLY" elseif p.reason == "timeout" then "TOO SLOW" else "MISS", C.Bad)
		Sounds.play("Error")
	end
	setScore(num(p.score, shownScore), num(p.combo, 0))
	if not pvp then
		-- Vs rivals the result carries the damage; a duel waits for "round".
		setHearts(num(p.lives, lives), maxLives, true)
		setBar(rivalFill, rivalHpText, num(p.rivalHp, 1), num(p.rivalMax, 1))
	end
	task.delay(0.7, function()
		if active and check == c then
			setIdle()
		end
	end)
end

-- A duel round: both presses are judged, both HP bars move.
local function onRound(p: any)
	local you = if type(p.you) == "table" then p.you else {}
	local opp = if type(p.opp) == "table" then p.opp else {}
	local hurt = opp.result == "hit" or opp.result == "perfect" or you.result == "miss"
	local landed = you.result == "hit" or you.result == "perfect" or opp.result == "miss"
	setBar(youFill, youHpText, num(you.hp, 0), num(you.maxHp, 1), if hurt then C.Bad else nil)
	setBar(rivalFill, rivalHpText, num(opp.hp, 0), num(opp.maxHp, 1), if landed then Color3.new(1, 1, 1) else nil)
	if you.score ~= nil then
		setScore(num(you.score, shownScore), num(you.combo, 0))
	end
	local word = RESULT_WORDS[opp.result] or "MISS"
	oppResult.Text = "Opponent: " .. word
	oppResult.TextColor3 = if opp.result == "perfect" then C.Gold elseif opp.result == "hit" then W.Cream else C.Bad
	oppResult.TextTransparency = 0
	Kit.pop(oppResult, 1.2)
	if p.suddenDeath == true then
		showBanner("SUDDEN DEATH!", "Next hit wins!", C.Bad, 1.6)
		Sounds.play("Ready")
	end
end

local function setRival(info: any)
	if type(info) ~= "table" then
		return
	end
	rivalName.Text = tostring(info.name or "Rival")
	local hpMax = math.max(num(info.maxHp, 1), 1)
	local hp = num(info.hp, hpMax)
	rivalFill.Size = UDim2.fromScale(math.clamp(hp / hpMax, 0, 1), 1)
	rivalHpText.Text = string.format("%d/%d", hp, hpMax)
end

function showBanner(title: string, sub: string?, color: Color3, hold: number)
	bannerToken += 1
	local mine = bannerToken
	bannerTitle.Text = title
	bannerTitle.TextColor3 = color
	bannerSub.Text = sub or ""
	bannerSub.Visible = sub ~= nil
	banner.Visible = true
	Kit.appear(banner, { from = 0.4, time = 0.3 })
	task.delay(hold, function()
		if bannerToken == mine then
			Kit.disappear(banner)
		end
	end)
end

-- Picker and queue ---------------------------------------------------------------------------

local function hideQueue()
	queueToken += 1
	queued = false
	if queuePanel.Visible then
		Kit.disappear(queuePanel)
	end
end

-- "FINDING OPPONENT…": the spinner turns, the dots count and the seconds tick (from the
-- server's `since`, a workspace:GetServerTimeNow() stamp) until the queue ends.
local function showQueue(p: any)
	queueToken += 1
	queued = true
	local mine = queueToken
	local now = Workspace:GetServerTimeNow()
	local since = num(p.since, now)
	if since > now + 5 or since < now - 600 then
		since = now -- not a server-clock stamp: count from now
	end
	local timeout = num(p.timeout, 0)
	queuePanel.Visible = true
	Kit.appear(queuePanel, { from = 0.7, time = 0.25 })
	task.spawn(function()
		while queueToken == mine do
			local t = Workspace:GetServerTimeNow()
			local elapsed = math.max(0, math.floor(t - since))
			queueTitle.Text = "FINDING OPPONENT" .. string.rep(".", 1 + math.floor(t * 2) % 3)
			queueTime.Text = if timeout > 0
				then string.format("%ds  ·  up to %ds", elapsed, math.ceil(timeout))
				else string.format("%ds", elapsed)
			queueSpinner.Rotation = (t * 360) % 360
			task.wait()
		end
	end)
end

function MogHud.choose()
	if queued then
		-- Already waiting for a duel: point at the queue panel instead of a second picker.
		Kit.pop(queuePanel, 1.15)
		return
	end
	if choosing or active then
		return
	end
	choosing = true
	Popups.mogChoose(function()
		action:FireServer({ action = "ModeStart", mode = "mog", vs = "rivals" })
	end, function()
		action:FireServer({ action = "ModeStart", mode = "mog", vs = "pvp" })
	end, function()
		choosing = false
	end)
end

-- Show / hide -------------------------------------------------------------------------------

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
	if not stepConn then
		stepConn = RunService.RenderStepped:Connect(step)
	end
end

local function unbind()
	ContextActionService:UnbindAction(ACTION)
	if stepConn then
		stepConn:Disconnect()
		stepConn = nil
	end
end

local function hide()
	active = false
	unbind()
	check = nil
	hideQueue()
	if screen then
		screen:SetAttribute("RunActive", false)
	end
	if root.Visible then
		Kit.disappear(root)
	end
	banner.Visible = false
end

local function onStart(p: any)
	hideQueue()
	active, passedShown, quitArmed = true, false, false
	pvp = p.vs == "pvp"
	shownScore = num(p.score, 0)
	scoreLabel.Text = Format.short(shownScore)
	comboChip.Visible = false
	Kit.setButton(quitButton, "X", C.SurfaceHi)
	quitButton.Size = UDim2.fromOffset(30, 28)
	heartsRow.Visible = not pvp
	youPanel.Visible = pvp
	oppResult.TextTransparency = 1
	if pvp then
		setBar(youFill, youHpText, num(p.hp, 8), num(p.maxHp, 8))
		setRival(p.opponent)
	else
		lives = num(p.lives, 3)
		setHearts(lives, num(p.maxLives, lives), false)
		setRival(p.rival)
	end
	setIdle()
	root.Visible = true
	Kit.appear(root, { from = 0.6, time = 0.3 })
	tapHint.Visible = Kit.touch
	if screen then
		-- Tells Tutorial to step aside, like a Parkour run.
		screen:SetAttribute("RunActive", true)
	end
	bind()
	Sounds.play("Ready")
	if pvp then
		local foe = type(p.opponent) == "table" and p.opponent.name
		showBanner("1v1 DUEL!", "vs " .. tostring(foe or "Opponent"), C.Gold, 2)
	else
		local best = num(p.best, 0)
		showBanner("MOG TEST!", if best > 0 then "Best " .. Format.short(best) else "Hit the zone to mog!", C.Gold, 1.8)
	end
end

function MogHud.onNotify(p: any)
	if not screen or type(p) ~= "table" then
		return
	end
	local event: string = tostring(p.event)
	local ending = event == "finish" or event == "stop"
	if event == "choose" then
		MogHud.choose()
		return
	elseif event == "queue" then
		showQueue(p)
		return
	elseif event == "start" then
		onStart(p)
	elseif not active and not ending then
		return
	elseif event == "check" then
		onCheck(p)
	elseif event == "result" then
		onResult(p)
	elseif event == "round" then
		onRound(p)
	elseif event == "rival" then
		local passedNow = p.passed == true and not passedShown
		if passedNow then
			passedShown = true
			local cash = num(p.cash, 0)
			showBanner("MOG TEST PASSED!", if cash > 0 then "+" .. Format.money(cash) else "Keep mogging!", C.Gold, 2.4)
		else
			local mogged = type(p.mogged) == "table" and p.mogged.name
			showBanner("MOGGED!", if mogged then tostring(mogged) .. " is out!" else nil, W.Cream, 1.5)
		end
		task.delay(0.9, function()
			if active then
				setRival(p.rival)
				Kit.pop(rivalName, 1.2)
			end
		end)
	elseif event == "finish" then
		local wasActive = active
		local duel = p.vs == "pvp"
		hide()
		if wasActive or p.score ~= nil then
			Popups.mogFinish(p, function()
				action:FireServer({ action = "ModeStart", mode = "mog", vs = if duel then "pvp" else "rivals" })
			end, function()
				action:FireServer({ action = "Home" })
			end)
		end
	elseif event == "stop" then
		local wasActive = active
		hide()
		if p.reason == "noOpponent" then
			Popups.toast("No one to duel right now — try VS RIVALS!", "info")
			MogHud.choose()
		elseif wasActive and p.reason == "quit" then
			Popups.toast("Mog test ended", "info")
		end
	end
end

-- Build -------------------------------------------------------------------------------------

function MogHud.build(screenGui: ScreenGui)
	screen = screenGui
	root = Kit.new("Frame", {
		Name = "MogHud",
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(300, 410),
		Position = UDim2.new(1, -36, 0.5, 6),
		AnchorPoint = Vector2.new(1, 0.5),
		Visible = false,
		ZIndex = 20,
		Parent = screenGui,
	})

	-- Score panel with the quiet quit button on its right end.
	local scorePanel = Kit.panel(root, {
		Name = "Score",
		Size = UDim2.fromOffset(200, 44),
		Position = UDim2.new(0.5, 0, 0, 0),
		AnchorPoint = Vector2.new(0.5, 0),
		Radius = 22,
	})
	Kit.icon(scorePanel, "Star", 26, C.Gold, { Position = UDim2.new(0, 10, 0.5, 0), AnchorPoint = Vector2.new(0, 0.5), ZIndex = 3 })
	scoreLabel = Kit.number(scorePanel, {
		Name = "Value",
		Text = "0",
		TextSize = 26,
		TextXAlignment = Enum.TextXAlignment.Left,
		Size = UDim2.new(1, -84, 1, 0),
		Position = UDim2.fromOffset(42, 0),
		ZIndex = 3,
	})
	quitButton = Kit.button(scorePanel, {
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
				Kit.setButton(quitButton, "X", C.SurfaceHi)
				Kit.tween(quitButton, 0.2, { Size = UDim2.fromOffset(30, 28) })
			end
		end)
	end)
	comboChip = Kit.text(root, {
		Name = "Combo",
		Text = "x2 COMBO",
		Font = F.Display,
		TextSize = 16,
		TextWrapped = false,
		TextColor3 = C.GoldInk,
		BackgroundColor3 = C.Gold,
		BackgroundTransparency = 0,
		Size = UDim2.fromOffset(110, 26),
		Position = UDim2.new(0.5, 0, 0, 50),
		AnchorPoint = Vector2.new(0.5, 0),
		StrokeThickness = 0,
		Visible = false,
		ZIndex = 3,
	})
	Kit.round(comboChip)

	heartsRow = Kit.new("Frame", {
		Name = "Hearts",
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(240, 28),
		Position = UDim2.new(0.5, 0, 0, 82),
		AnchorPoint = Vector2.new(0.5, 0),
		Parent = root,
	})
	Kit.list(heartsRow, 6, true, Enum.HorizontalAlignment.Center)

	-- In a duel the hearts give way to your own HP bar: "YOU", a green bar, "hp/max".
	youPanel = Kit.new("Frame", {
		Name = "You",
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(240, 28),
		Position = UDim2.new(0.5, 0, 0, 82),
		AnchorPoint = Vector2.new(0.5, 0),
		Visible = false,
		Parent = root,
	})
	Kit.text(youPanel, {
		Name = "Label",
		Text = "YOU",
		Font = F.Display,
		TextSize = 18,
		TextWrapped = false,
		TextColor3 = C.Gold,
		TextXAlignment = Enum.TextXAlignment.Left,
		Size = UDim2.new(0, 44, 1, 0),
		ZIndex = 3,
	})
	local youTrack = Kit.new("Frame", {
		Name = "Bar",
		BackgroundColor3 = C.Well,
		Size = UDim2.new(1, -104, 0, 18),
		Position = UDim2.new(0, 46, 0.5, 0),
		AnchorPoint = Vector2.new(0, 0.5),
		ZIndex = 3,
		Parent = youPanel,
	})
	Kit.round(youTrack)
	Kit.stroke(youTrack, 2, C.Gold)
	youFill = Kit.new("Frame", {
		Name = "Fill",
		BackgroundColor3 = C.Good,
		Size = UDim2.fromScale(1, 1),
		ZIndex = 4,
		Parent = youTrack,
	})
	Kit.round(youFill)
	Kit.gradient(youFill, Color3.new(1, 1, 1), Kit.darken(Color3.new(1, 1, 1), 0.15), 90)
	youHpText = Kit.number(youPanel, {
		Name = "Hp",
		Text = "8/8",
		TextSize = 16,
		TextXAlignment = Enum.TextXAlignment.Right,
		Size = UDim2.fromOffset(52, 28),
		Position = UDim2.new(1, 0, 0, 0),
		AnchorPoint = Vector2.new(1, 0),
		ZIndex = 3,
	})

	-- The ring (UI.MogRing draws it; the holder keeps the tap target and result label).
	local ringHolder = Kit.new("Frame", {
		Name = "RingHolder",
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(RING, RING),
		Position = UDim2.new(0.5, 0, 0, 120),
		AnchorPoint = Vector2.new(0.5, 0),
		Parent = root,
	})
	ring = MogRing.new(ringHolder, RING)

	-- The tap target over the whole ring (mouse and touch).
	local hit = Kit.new("TextButton", {
		Name = "Tap",
		Text = "",
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(RING + 40, RING + 40),
		Position = UDim2.fromScale(0.5, 0.5),
		AnchorPoint = Vector2.new(0.5, 0.5),
		ZIndex = 12,
		Parent = ringHolder,
	})
	hit.Activated:Connect(press)
	tapHint = Kit.text(ringHolder, {
		Name = "TapHint",
		Text = "TAP!",
		Font = F.Display,
		TextSize = 18,
		TextColor3 = C.Gold,
		Size = UDim2.fromOffset(80, 22),
		Position = UDim2.new(0, -10, 1, -6),
		AnchorPoint = Vector2.new(0, 1),
		Rotation = -12,
		Visible = false,
		ZIndex = 11,
	})
	resultLabel = Kit.number(ringHolder, {
		Name = "Result",
		Text = "",
		TextSize = 34,
		TextWrapped = false,
		Size = UDim2.fromOffset(260, 40),
		Position = RESULT_FROM,
		AnchorPoint = Vector2.new(0.5, 0.5),
		TextTransparency = 1,
		ZIndex = 14,
	})
	Kit.new("UIScale", { Parent = resultLabel })

	-- The rival: name and HP bar under the ring.
	local rivalPanel = Kit.panel(root, {
		Name = "Rival",
		Size = UDim2.fromOffset(240, 58),
		Position = UDim2.new(0.5, 0, 0, 316),
		AnchorPoint = Vector2.new(0.5, 0),
		Radius = 16,
	})
	rivalName = Kit.text(rivalPanel, {
		Name = "Name",
		Text = "Rival",
		Font = F.Display,
		TextSize = 17,
		TextWrapped = false,
		TextXAlignment = Enum.TextXAlignment.Left,
		Size = UDim2.new(1, -90, 0, 22),
		Position = UDim2.fromOffset(14, 5),
		ZIndex = 3,
	})
	rivalHpText = Kit.number(rivalPanel, {
		Name = "Hp",
		Text = "0/0",
		TextSize = 15,
		TextXAlignment = Enum.TextXAlignment.Right,
		Size = UDim2.fromOffset(70, 22),
		Position = UDim2.new(1, -14, 0, 5),
		AnchorPoint = Vector2.new(1, 0),
		TextColor3 = C.TextDim,
		StrokeThickness = 0,
		ZIndex = 3,
	})
	local barTrack = Kit.new("Frame", {
		Name = "Bar",
		BackgroundColor3 = C.Well,
		Size = UDim2.new(1, -28, 0, 16),
		Position = UDim2.fromOffset(14, 32),
		ZIndex = 3,
		Parent = rivalPanel,
	})
	Kit.round(barTrack)
	rivalFill = Kit.new("Frame", {
		Name = "Fill",
		BackgroundColor3 = C.Bad,
		Size = UDim2.fromScale(1, 1),
		ZIndex = 4,
		Parent = barTrack,
	})
	Kit.round(rivalFill)
	Kit.gradient(rivalFill, Kit.lighten(C.Bad, 0.25), C.Bad, 90)

	-- The opponent's last result in a duel, small under their bar.
	oppResult = Kit.text(root, {
		Name = "OppResult",
		Text = "",
		Font = F.Display,
		TextSize = 16,
		TextWrapped = false,
		Size = UDim2.fromOffset(240, 22),
		Position = UDim2.new(0.5, 0, 0, 382),
		AnchorPoint = Vector2.new(0.5, 0),
		TextTransparency = 1,
		ZIndex = 3,
	})
	Kit.new("UIScale", { Parent = oppResult })

	-- "FINDING OPPONENT…" (right side, outside the run HUD: shown while root is hidden).
	queuePanel = Kit.panel(screenGui, {
		Name = "MogQueue",
		Size = UDim2.fromOffset(276, 124),
		Position = UDim2.new(1, -36, 0.5, 0),
		AnchorPoint = Vector2.new(1, 0.5),
		Radius = 18,
		Visible = false,
		ZIndex = 20,
	})
	queueSpinner = Kit.new("Frame", {
		Name = "Spinner",
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(48, 48),
		Position = UDim2.fromOffset(14, 10),
		ZIndex = 21,
		Parent = queuePanel,
	})
	-- A faint well disc behind the dots so the spinner reads as one badge.
	local spinnerWell = Kit.new("Frame", {
		Name = "Well",
		BackgroundColor3 = C.Well,
		Size = UDim2.fromScale(1, 1),
		ZIndex = 21,
		Parent = queueSpinner,
	})
	Kit.round(spinnerWell)
	for i = 1, 10 do
		-- Ten dots round a circle, growing and brightening toward the head.
		local angle = i / 10 * math.pi * 2
		local size = 5 + math.floor(i / 2)
		local dot = Kit.new("Frame", {
			BackgroundColor3 = C.Gold,
			BackgroundTransparency = (10 - i) / 12,
			Size = UDim2.fromOffset(size, size),
			Position = UDim2.new(0.5, math.sin(angle) * 16, 0.5, -math.cos(angle) * 16),
			AnchorPoint = Vector2.new(0.5, 0.5),
			ZIndex = 22,
			Parent = queueSpinner,
		})
		Kit.round(dot)
	end
	queueTitle = Kit.text(queuePanel, {
		Name = "Title",
		Text = "FINDING OPPONENT...",
		Font = F.Display,
		TextSize = 17,
		TextWrapped = false,
		TextColor3 = C.Gold,
		TextXAlignment = Enum.TextXAlignment.Left,
		Size = UDim2.new(1, -84, 0, 22),
		Position = UDim2.fromOffset(72, 12),
		ZIndex = 21,
	})
	queueTime = Kit.text(queuePanel, {
		Name = "Time",
		Text = "0s",
		TextSize = 15,
		TextWrapped = false,
		TextColor3 = C.TextDim,
		TextXAlignment = Enum.TextXAlignment.Left,
		Size = UDim2.new(1, -84, 0, 20),
		Position = UDim2.fromOffset(72, 36),
		StrokeThickness = 0,
		ZIndex = 21,
	})
	-- The same slim secondary button as Popups' "Back to my gym".
	Kit.button(queuePanel, {
		Name = "Cancel",
		Text = "Cancel",
		Color = C.SurfaceHi,
		TextSize = Kit.TEXT.Body,
		Size = UDim2.new(1, -28, 0, 42),
		Position = UDim2.new(0.5, 0, 1, -12),
		AnchorPoint = Vector2.new(0.5, 1),
		ZIndex = 22,
	}, function()
		action:FireServer({ action = "MogCancel" })
		hideQueue()
	end)

	-- Banner (top centre, under the unit count).
	banner = Kit.new("Frame", {
		Name = "MogBanner",
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(560, 90),
		Position = UDim2.new(0.5, 0, 0, 96),
		AnchorPoint = Vector2.new(0.5, 0),
		Visible = false,
		ZIndex = 30,
		Parent = screenGui,
	})
	bannerTitle = Kit.title(banner, {
		Text = "MOGGED!",
		TextSize = 48,
		TextWrapped = false,
		Size = UDim2.new(1, 0, 0, 56),
		ZIndex = 31,
	})
	bannerSub = Kit.text(banner, {
		Text = "",
		Font = F.Display,
		TextSize = 22,
		TextColor3 = C.MoneyText,
		Size = UDim2.new(1, 0, 0, 28),
		Position = UDim2.fromOffset(0, 58),
		ZIndex = 31,
	})
end

return MogHud
