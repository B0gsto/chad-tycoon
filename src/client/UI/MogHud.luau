--!strict
--[[
	MogHud: the screen side of the MOG TEST (a skill-check duel against rival chads).

	  Ring         centre-right, 180 px: Cream rim, dark well track, the zone as an arc
	               of thin rotated segment frames (exact to the degree; the first
	               perfectSize degrees are the gold "perfect" slice), a red needle posed
	               every frame from the server clock (travel = speed * (now - appearAt),
	               screen angle = dir * travel clockwise from 12 o'clock) and a centre
	               label ("SPACE" / "TAP" / the check number). A check arrives a moment
	               before its needle starts: Tick, the ring fades in with a pulse and a
	               soft glow breathes until the needle runs.
	  Input        Space, Enter and gamepad A (ContextActionService, high priority, sunk
	               so Space does not jump) and a big invisible button over the ring for
	               mouse / touch. One MogPress per check, sent with the server time of the
	               press; presses before the needle starts only give a small "wait..."
	               wobble. The needle freezes where it was pressed until the result.
	  Status       score (bouncy count) and the combo chip above the ring, hearts
	               (maxLives) under them, the rival's name and HP bar under the ring, a
	               quiet "X" that asks "QUIT?" before firing ModeQuit.
	  Banners      "MOG TEST!" at the start, "MOGGED!" per rival, "MOG TEST PASSED!"
	               with the cash the first time the run passes.

	MogHud.onNotify(payload) takes every Notify with kind "Mode" and mode "mog" (Main
	routes them); Fx.Mog does the 3D side from the same payloads.
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
local Popups = require(script.Parent.Popups) :: any
local Sounds = require(Client.Sounds) :: any

local MogHud = {}

local C = Kit.C
local F = Kit.F
local W = Theme.World

local RING = 180 -- ring diameter (px, design space)
local TRACK_OUT = 84 -- zone arc outer radius
local TRACK_IN = 60 -- zone arc inner radius
local SEGMENT = 2 -- largest zone segment (degrees)
local ACTION = "MogPress"
local PRIORITY = 3000

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
local ring: Frame
local ringScale: UIScale
local rim: Frame
local glow: Frame
local zone: Frame
local needle: Frame
local centre: TextLabel
local tapHint: TextLabel
local resultLabel: TextLabel
local scoreLabel: TextLabel
local comboChip: TextLabel
local heartsRow: Frame
local rivalName: TextLabel
local rivalFill: Frame
local rivalHpText: TextLabel
local banner: Frame
local bannerTitle: TextLabel
local bannerSub: TextLabel
local quitButton: TextButton

local active = false
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

-- One arc segment between screen angles a and b (degrees clockwise from 12 o'clock).
local function segment(parent: Instance, a: number, b: number, color: Color3, z: number)
	local mid = math.rad((a + b) / 2)
	local radius = (TRACK_OUT + TRACK_IN) / 2
	local width = 2 * math.pi * radius * math.abs(b - a) / 360 + 1.2 -- slight overlap: no seams
	Kit.new("Frame", {
		BackgroundColor3 = color,
		BorderSizePixel = 0,
		Size = UDim2.fromOffset(width, TRACK_OUT - TRACK_IN),
		Position = UDim2.new(0.5, math.sin(mid) * radius, 0.5, -math.cos(mid) * radius),
		AnchorPoint = Vector2.new(0.5, 0.5),
		Rotation = math.deg(mid),
		ZIndex = z,
		Parent = parent,
	})
end

-- An arc from travel t0 to t1 drawn on the screen side `dir` points to.
local function arc(parent: Instance, t0: number, t1: number, dir: number, color: Color3, z: number)
	if t1 <= t0 then
		return
	end
	local count = math.max(1, math.ceil((t1 - t0) / SEGMENT))
	local step = (t1 - t0) / count
	for i = 0, count - 1 do
		local a, b = t0 + i * step, t0 + (i + 1) * step
		segment(parent, dir * a, dir * b, color, z)
	end
end

local function buildZone(c: Check)
	zone:ClearAllChildren()
	local zoneEnd = math.min(c.zoneStart + c.zoneSize, 360)
	local perfectEnd = math.min(c.zoneStart + c.perfectSize, zoneEnd)
	arc(zone, perfectEnd, zoneEnd, c.dir, W.Cream, 4)
	arc(zone, c.zoneStart, perfectEnd, c.dir, C.Gold, 5)
	-- Thin bright edge lines at both ends so the bounds read crisply.
	for _, t in { c.zoneStart, zoneEnd } do
		segment(zone, c.dir * t - 0.6, c.dir * t + 0.6, C.GoldLight, 6)
	end
end

local function travelNow(c: Check): number
	return math.clamp(c.speed * (Workspace:GetServerTimeNow() - c.appearAt), 0, 360)
end

local function burst(color: Color3)
	local wave = Kit.new("Frame", {
		Name = "Burst",
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(RING, RING),
		Position = UDim2.fromScale(0.5, 0.5),
		AnchorPoint = Vector2.new(0.5, 0.5),
		ZIndex = 1,
		Parent = ring,
	})
	Kit.round(wave)
	local stroke = Kit.stroke(wave, 10, color)
	Kit.tween(wave, 0.5, { Size = UDim2.fromOffset(RING * 1.7, RING * 1.7) }, Enum.EasingStyle.Quart)
	Kit.tween(stroke, 0.5, { Transparency = 1, Thickness = 2 }, Enum.EasingStyle.Quart)
	task.delay(0.55, function()
		wave:Destroy()
	end)
end

local function flashRim(color: Color3)
	rim.BackgroundColor3 = color
	Kit.tween(rim, 0.6, { BackgroundColor3 = W.Cream })
end

local function popResult(text: string, color: Color3)
	resultLabel.Text = text
	resultLabel.TextColor3 = color
	resultLabel.TextTransparency = 0
	resultLabel.Position = UDim2.new(0.5, 0, 0.5, 0)
	local scale = resultLabel:FindFirstChildOfClass("UIScale") :: UIScale
	scale.Scale = 0.3
	Kit.tween(scale, 0.35, { Scale = 1 }, Enum.EasingStyle.Back)
	Kit.tween(resultLabel, 0.9, { Position = UDim2.new(0.5, 0, 0.5, -34) }, Enum.EasingStyle.Quad)
	task.delay(0.65, function()
		if resultLabel.Text == text then
			Kit.tween(resultLabel, 0.3, { TextTransparency = 1 })
		end
	end)
end

local function setIdle()
	-- Between checks the ring rests small and dim with the needle hidden.
	check, pressed, frozenTravel = nil, false, nil
	zone:ClearAllChildren()
	needle.Visible = false
	Kit.tween(ringScale, 0.3, { Scale = 0.86 })
	Kit.tween(glow, 0.3, { BackgroundTransparency = 1 })
	centre.Text = if Kit.touch then "TAP" else "SPACE"
	centre.TextColor3 = C.TextDim
end

local function wobble()
	-- "Wait..." : a little side-to-side shake of the ring, no camera shake.
	centre.Text = "wait…"
	local base = UDim2.fromScale(0.5, 0.5)
	task.spawn(function()
		for _, dx in { 6, -6, 4, -3, 0 } do
			ring.Position = base + UDim2.fromOffset(dx, 0)
			task.wait(0.04)
		end
		ring.Position = base
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
	Kit.pop(ring, 1.06)
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
		-- Warning: a soft glow breathes until the needle starts.
		glow.BackgroundTransparency = 0.55 + 0.25 * math.cos(now * 12)
		return
	end
	if not warned then
		warned = true
		glow.BackgroundTransparency = 1
		centre.Text = "#" .. tostring(c.n)
		centre.TextColor3 = C.Text
		needle.Visible = true
	end
	local travel = frozenTravel or travelNow(c)
	needle.Rotation = c.dir * travel
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
	buildZone(c)
	needle.Visible = false
	needle.Rotation = 0
	centre.Text = if Kit.touch then "TAP!" else "SPACE"
	centre.TextColor3 = C.Gold
	-- The DBD-style warning: tick, the ring swells in with a pulse.
	Sounds.play("Tick")
	ringScale.Scale = 0.7
	Kit.tween(ringScale, 0.35, { Scale = 1 }, Enum.EasingStyle.Back)
	burst(W.Cream)
end

local function onResult(p: any)
	local c = check
	if c and p.id ~= nil and p.id ~= c.id then
		return
	end
	if c then
		local travel = num(p.travel, frozenTravel or travelNow(c))
		frozenTravel = travel
		needle.Rotation = c.dir * travel
		needle.Visible = true
	end
	local result = p.result
	if result == "perfect" then
		flashRim(C.Gold)
		burst(C.Gold)
		popResult("PERFECT!", C.Gold)
		Sounds.play("Coin", 0.05, 1.15)
	elseif result == "hit" then
		flashRim(Color3.new(1, 1, 1))
		burst(W.Cream)
		popResult("HIT", W.Cream)
		Sounds.play("Pickup", 0.08)
	else
		flashRim(C.Bad)
		popResult(if p.reason == "early" then "TOO EARLY" elseif p.reason == "timeout" then "TOO SLOW" else "MISS", C.Bad)
		Sounds.play("Error")
	end
	-- Score rolls up with a bounce; the combo chip shows from x2.
	local score = num(p.score, shownScore)
	if score ~= shownScore then
		Kit.countTo(scoreLabel, shownScore, score, Format.short, 0.4)
		Kit.pop(scoreLabel, 1.25)
		shownScore = score
	end
	local combo = num(p.combo, 0)
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
	setHearts(num(p.lives, lives), maxLives, true)
	local hp, hpMax = num(p.rivalHp, 1), math.max(num(p.rivalMax, 1), 1)
	Kit.tween(rivalFill, 0.35, { Size = UDim2.fromScale(math.clamp(hp / hpMax, 0, 1), 1) }, Enum.EasingStyle.Quart)
	rivalHpText.Text = string.format("%d/%d", math.max(hp, 0), hpMax)
	task.delay(0.7, function()
		if active and check == c then
			setIdle()
		end
	end)
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

local function showBanner(title: string, sub: string?, color: Color3, hold: number)
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
	if screen then
		screen:SetAttribute("RunActive", false)
	end
	if root.Visible then
		Kit.disappear(root)
	end
	banner.Visible = false
end

local function onStart(p: any)
	active, passedShown, quitArmed = true, false, false
	shownScore = num(p.score, 0)
	scoreLabel.Text = Format.short(shownScore)
	comboChip.Visible = false
	Kit.setButton(quitButton, "X", C.SurfaceHi)
	quitButton.Size = UDim2.fromOffset(30, 28)
	lives = num(p.lives, 3)
	setHearts(lives, num(p.maxLives, lives), false)
	setRival(p.rival)
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
	local best = num(p.best, 0)
	showBanner("MOG TEST!", if best > 0 then "Best " .. Format.short(best) else "Hit the zone to mog!", C.Gold, 1.8)
end

function MogHud.onNotify(p: any)
	if not screen or type(p) ~= "table" then
		return
	end
	local event: string = tostring(p.event)
	local ending = event == "finish" or event == "stop"
	if event == "start" then
		onStart(p)
	elseif not active and not ending then
		return
	elseif event == "check" then
		onCheck(p)
	elseif event == "result" then
		onResult(p)
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
		hide()
		if wasActive or p.score ~= nil then
			Popups.mogFinish(p, function()
				action:FireServer({ action = "ModeStart", mode = "mog" })
			end, function()
				action:FireServer({ action = "Home" })
			end)
		end
	elseif event == "stop" then
		local wasActive = active
		hide()
		if wasActive and p.reason == "quit" then
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
		Size = UDim2.fromOffset(300, 390),
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

	-- The ring.
	ring = Kit.new("Frame", {
		Name = "Ring",
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(RING, RING),
		Position = UDim2.fromScale(0.5, 0.5),
		AnchorPoint = Vector2.new(0.5, 0.5),
	})
	local ringHolder = Kit.new("Frame", {
		Name = "RingHolder",
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(RING, RING),
		Position = UDim2.new(0.5, 0, 0, 120),
		AnchorPoint = Vector2.new(0.5, 0),
		Parent = root,
	})
	ring.Parent = ringHolder
	ringScale = Kit.new("UIScale", { Parent = ring })
	glow = Kit.new("Frame", {
		Name = "Glow",
		BackgroundColor3 = C.Gold,
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(RING + 28, RING + 28),
		Position = UDim2.fromScale(0.5, 0.5),
		AnchorPoint = Vector2.new(0.5, 0.5),
		ZIndex = 1,
		Parent = ring,
	})
	Kit.round(glow)
	rim = Kit.new("Frame", {
		Name = "Rim",
		BackgroundColor3 = W.Cream,
		Size = UDim2.fromScale(1, 1),
		ZIndex = 2,
		Parent = ring,
	})
	Kit.round(rim)
	Kit.shadow(rim, RING // 2, 0.35, 4)
	local track = Kit.new("Frame", {
		Name = "Track",
		BackgroundColor3 = C.Well,
		Size = UDim2.fromOffset(TRACK_OUT * 2 + 2, TRACK_OUT * 2 + 2),
		Position = UDim2.fromScale(0.5, 0.5),
		AnchorPoint = Vector2.new(0.5, 0.5),
		ZIndex = 3,
		Parent = ring,
	})
	Kit.round(track)
	zone = Kit.new("Frame", {
		Name = "Zone",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		ZIndex = 4,
		Parent = ring,
	})
	local plate = Kit.new("Frame", {
		Name = "Plate",
		BackgroundColor3 = C.Surface,
		Size = UDim2.fromOffset(TRACK_IN * 2 - 6, TRACK_IN * 2 - 6),
		Position = UDim2.fromScale(0.5, 0.5),
		AnchorPoint = Vector2.new(0.5, 0.5),
		ZIndex = 7,
		Parent = ring,
	})
	Kit.round(plate)
	Kit.stroke(plate, 3, C.Edge)
	centre = Kit.number(plate, {
		Name = "Centre",
		Text = "SPACE",
		TextSize = 24,
		TextWrapped = false,
		Size = UDim2.fromScale(1, 1),
		ZIndex = 8,
	})
	-- The needle: a pivot frame the size of the ring, turned each frame; the red bar
	-- runs across the track with a round cap at its tip.
	needle = Kit.new("Frame", {
		Name = "Needle",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		ZIndex = 9,
		Visible = false,
		Parent = ring,
	})
	local bar = Kit.new("Frame", {
		Name = "Bar",
		BackgroundColor3 = C.Bad,
		BorderSizePixel = 0,
		Size = UDim2.fromOffset(6, TRACK_OUT - TRACK_IN + 14),
		Position = UDim2.new(0.5, 0, 0.5, -TRACK_IN + 6),
		AnchorPoint = Vector2.new(0.5, 1),
		ZIndex = 9,
		Parent = needle,
	})
	Kit.round(bar)
	Kit.stroke(bar, 1.5, Color3.new(1, 1, 1))
	local cap = Kit.new("Frame", {
		Name = "Cap",
		BackgroundColor3 = C.Bad,
		Size = UDim2.fromOffset(14, 14),
		Position = UDim2.new(0.5, 0, 0, 0),
		AnchorPoint = Vector2.new(0.5, 0.5),
		ZIndex = 10,
		Parent = bar,
	})
	Kit.round(cap)
	Kit.stroke(cap, 2, Color3.new(1, 1, 1))

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
		Position = UDim2.new(0.5, 0, 0.5, 0),
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
