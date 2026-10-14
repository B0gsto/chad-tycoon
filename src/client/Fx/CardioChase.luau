--!strict
--[[
	Fx.CardioChase: the CHASER CHADS of CARDIO (stages 3, 6, 9; server side in
	Modes.CardioChase). Listens to Notify (kind "Mode", mode "cardio") on its own:
	  chase     { stage, tier, scale, speed, startX, startZ, startS, stopS, startAt, endX,
	              zMin, zMax, laneEase, path = { { x0, x1, top, z0, z1 } },
	              line = { { s, x, z, half } } }  (the bridge path's centre line)
	  caught    { stage }            "MOGGED!" splash, the chaser flexes over you and leaves
	  chaseEnd  { stage, reason }    "escaped": it stops, roars / flexes and gives up
	  stop                           run ended: everything goes

	Chad      built locally (only this client sees its own chaser) with CharacterFactory from
	          Theme.Tiers[tier].Look at `scale`, angry face, a bright red always-on-top outline
	          (Highlight). It is NOT tagged for the Animator: this module poses it itself
	          (RigPose "Run" with gaitTime from the distance run, so the feet stay planted).
	Position  the same deterministic formula as the server (Modes.CardioChase.position):
	            s = min(stopS, startS + speed * run), run = max(0, t - startAt),
	            t = GetServerTimeNow(); x, pz, half = the centre line at s;
	            z = clamp(pz + clamp(playerZ - pz, -half, half) * min(1, run / laneEase), zMin, zMax)
	          feet on the path surfaces, with a jump arc over gaps.
	Warning   a red "!" over its head, an alarm sting, a "CHAD IS COMING!" banner; then a
	          distance meter and a red screen-edge vignette that grow as it closes in.
	Dust      a puff at its feet on every footfall (Sprites budget permitting).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Net = require(ReplicatedStorage.Shared.Net)
local CharacterFactory = require(ReplicatedStorage.Shared:WaitForChild("CharacterFactory")) :: any
local Poses = require(ReplicatedStorage.Shared:WaitForChild("Poses")) :: any
local RigPose = require(ReplicatedStorage.Shared:WaitForChild("RigPose")) :: any
local Theme = require(ReplicatedStorage:WaitForChild("Theme")) :: any
local Client = script.Parent.Parent
local Sounds = require(Client.Sounds) :: any
local Sprites = require(script.Parent.Sprites)
local Highlights = require(script.Parent.Highlights)

local ChaseFx = {}

local player = Players.LocalPlayer
local RED = Color3.fromRGB(255, 40, 40)
-- The chaser reads tiny next to the wide track, so it is drawn 1.5x the server's scale
-- (CharacterFactory takes any scale; the server's catch maths doesn't use the size).
local SIZE_BOOST = 1.5
-- One reusable red outline (Roblox renders at most 31 Highlights at once).
local outline: Highlight? = nil
local DANGER = 45 -- studs: the meter and vignette start reacting inside this
local BIND = "FxCardioChase"

type Surface = { number }
-- Centre line vertex { s, x, z, half }.
type Vertex = { number }
type Chase = {
	stage: number,
	speed: number,
	startX: number,
	startZ: number,
	startAt: number,
	endX: number,
	zMin: number,
	zMax: number,
	laneEase: number,
	path: { Surface },
	line: { Vertex },
	startS: number,
	stopS: number,
	scale: number,
	-- Set when it gave up: it stays at (x, z).
	frozen: { number }?,
}

local folder: Folder? = nil
local chad: Model? = nil
local rig: any = nil
local rootOffset = CFrame.identity
local chase: Chase? = nil
-- "chase" (running after you) | "flex" (gave up / caught you: posing in place) | nil
local mode: string? = nil
local flexPose = "MostMuscular"
local flexStart = 0
local lastStep = 0
local gui: ScreenGui? = nil
local meter: TextLabel? = nil
local edges: { Frame } = {}
local token = 0

local function num(value: any, default: number): number
	return if type(value) == "number" and value == value then value else default
end

local function now(): number
	return Workspace:GetServerTimeNow()
end

local function playerRoot(): BasePart?
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	return if root and root:IsA("BasePart") then root else nil
end

-- Feet height along the path at x (surface top, or a jump arc over a gap).
local function groundY(path: { Surface }, x: number, hop: number): number
	local prev: Surface? = nil
	for _, s in path do
		if x < s[1] then
			if not prev then
				return s[3]
			end
			local u = (x - prev[2]) / math.max(0.01, s[1] - prev[2])
			return prev[3] + (s[3] - prev[3]) * u + 4 * hop * u * (1 - u)
		elseif x <= s[2] then
			return s[3]
		end
		prev = s
	end
	return if prev then prev[3] else 0
end

-- The centre line at distance s: x, z, half width (Modes.CardioChase.lineAt).
local function lineAt(line: { Vertex }, s: number): (number, number, number)
	local first = line[1]
	if not first then
		return 0, 0, 0
	end
	if s <= first[1] then
		return first[2], first[3], first[4]
	end
	for i = 2, #line do
		local b = line[i]
		if s <= b[1] then
			local a = line[i - 1]
			local u = if b[1] > a[1] then (s - a[1]) / (b[1] - a[1]) else 1
			return a[2] + (b[2] - a[2]) * u, a[3] + (b[3] - a[3]) * u, a[4] + (b[4] - a[4]) * u
		end
	end
	local last = line[#line]
	return last[2], last[3], last[4]
end

-- Same formula as Modes.CardioChase.position (plus run time).
local function position(c: Chase, t: number, playerZ: number): (number, number, number)
	local run = math.max(0, t - c.startAt)
	local frozen = c.frozen
	if frozen then
		return frozen[1], frozen[2], run
	end
	if #c.line == 0 then
		return c.startX, c.startZ, run
	end
	local s = math.min(c.stopS, c.startS + c.speed * run)
	local x, pz, half = lineAt(c.line, s)
	local pull = math.clamp(playerZ - pz, -half, half) * math.min(1, run / math.max(0.01, c.laneEase))
	return x, math.clamp(pz + pull, c.zMin, c.zMax), run
end

-- Screen ------------------------------------------------------------------------------------

local function ensureGui(): ScreenGui
	if gui then
		return gui
	end
	local g = Instance.new("ScreenGui")
	g.Name = "CardioChase"
	g.ResetOnSpawn = false
	g.IgnoreGuiInset = true
	g.DisplayOrder = 6
	g.Parent = player:WaitForChild("PlayerGui")
	-- Red vignette: four edge bands fading inward.
	edges = {}
	local specs: { { size: UDim2, pos: UDim2, rot: number } } = {
		{ size = UDim2.new(1, 0, 0.22, 0), pos = UDim2.new(0, 0, 0, 0), rot = 90 },
		{ size = UDim2.new(1, 0, 0.22, 0), pos = UDim2.new(0, 0, 0.78, 0), rot = -90 },
		{ size = UDim2.new(0.16, 0, 1, 0), pos = UDim2.new(0, 0, 0, 0), rot = 0 },
		{ size = UDim2.new(0.16, 0, 1, 0), pos = UDim2.new(0.84, 0, 0, 0), rot = 180 },
	}
	for i, spec in specs do
		local f = Instance.new("Frame")
		f.Name = "Edge" .. i
		f.BorderSizePixel = 0
		f.BackgroundColor3 = RED
		f.BackgroundTransparency = 1
		f.Size = spec.size
		f.Position = spec.pos
		local grad = Instance.new("UIGradient")
		grad.Rotation = spec.rot
		grad.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0),
			NumberSequenceKeypoint.new(1, 1),
		})
		grad.Parent = f
		f.Parent = g
		table.insert(edges, f)
	end
	local m = Instance.new("TextLabel")
	m.Name = "Meter"
	m.AnchorPoint = Vector2.new(0.5, 0)
	m.Position = UDim2.new(0.5, 0, 0.13, 0)
	m.Size = UDim2.new(0, 420, 0, 44)
	m.BackgroundTransparency = 1
	m.Font = Theme.Fonts.Display
	m.TextScaled = true
	m.TextColor3 = Color3.new(1, 1, 1)
	m.Text = ""
	m.Visible = false
	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(120, 0, 0)
	stroke.Thickness = 3
	stroke.Parent = m
	m.Parent = g
	meter = m
	gui = g
	return g
end

local function setDanger(alpha: number)
	for _, f in edges do
		f.BackgroundTransparency = 1 - 0.55 * alpha
	end
end

-- A big popping word in the middle of the screen.
local function splash(text: string, color: Color3, life: number)
	local g = ensureGui()
	local label = Instance.new("TextLabel")
	label.Name = "Splash"
	label.AnchorPoint = Vector2.new(0.5, 0.5)
	label.Position = UDim2.new(0.5, 0, 0.36, 0)
	label.Size = UDim2.new(0.7, 0, 0.16, 0)
	label.BackgroundTransparency = 1
	label.Font = Theme.Fonts.Display
	label.TextScaled = true
	label.Text = text
	label.TextColor3 = color
	label.Rotation = -6
	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(40, 0, 0)
	stroke.Thickness = 5
	stroke.Parent = label
	local scale = Instance.new("UIScale")
	scale.Scale = 0.2
	scale.Parent = label
	label.Parent = g
	TweenService:Create(scale, TweenInfo.new(0.35, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 }):Play()
	TweenService:Create(label, TweenInfo.new(0.35, Enum.EasingStyle.Back), { Rotation = 0 }):Play()
	task.delay(life, function()
		local fade = TweenInfo.new(0.35)
		TweenService:Create(label, fade, { TextTransparency = 1 }):Play()
		TweenService:Create(stroke, fade, { Transparency = 1 }):Play()
		TweenService:Create(scale, fade, { Scale = 1.3 }):Play()
		task.delay(0.4, function()
			label:Destroy()
		end)
	end)
end

-- Chad --------------------------------------------------------------------------------------

local function tierLook(tier: number): any
	local tiers = Theme.Tiers
	local entry = tiers[math.clamp(math.floor(tier), 1, #tiers)]
	return entry and entry.Look
end

local function anchorAt(position: Vector3, life: number): BasePart
	local part = Instance.new("Part")
	part.Name = "ChaseFxAnchor"
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Transparency = 1
	part.Size = Vector3.one * 0.2
	part.CFrame = CFrame.new(position)
	part.Parent = folder or Workspace
	task.delay(life, function()
		part:Destroy()
	end)
	return part
end

local function sprite(name: string, position: Vector3, opts: { [string]: any })
	if not Sprites.room() then
		return
	end
	local o = table.clone(opts) :: any
	o.position = position
	Sprites.billboard(anchorAt(position, 2.2), name, o)
end

local function removeChad()
	token += 1
	if chad then
		chad:Destroy()
	end
	chad, rig = nil, nil
	if outline then
		Highlights.want(outline, false)
		outline.Adornee = nil
	end
end

local function clear()
	removeChad()
	chase = nil
	mode = nil
	RunService:UnbindFromRenderStep(BIND)
	if meter then
		meter.Visible = false
	end
	setDanger(0)
end

-- The run itself is over: the big words ("RUN!", "MOGGED!") go with the chase.
local function stop()
	clear()
	if gui then
		for _, child in gui:GetChildren() do
			if child.Name == "Splash" then
				child:Destroy()
			end
		end
	end
end

local function warnMark(model: Model, height: number)
	local head = model.PrimaryPart
	if not head then
		return
	end
	local bb = Instance.new("BillboardGui")
	bb.Name = "ChaseWarn"
	bb.AlwaysOnTop = true
	bb.Size = UDim2.new(0, 90, 0, 90)
	bb.StudsOffsetWorldSpace = Vector3.new(0, height - rootOffset.Y + 2.5, 0)
	bb.MaxDistance = 400
	bb.Adornee = head
	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromScale(1, 1)
	label.Font = Theme.Fonts.Display
	label.TextScaled = true
	label.Text = "!"
	label.TextColor3 = RED
	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.new(1, 1, 1)
	stroke.Thickness = 4
	stroke.Parent = label
	label.Parent = bb
	bb.Parent = model
	local scale = Instance.new("UIScale")
	scale.Parent = label
	local pulse = TweenInfo.new(0.22, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, 5, true)
	scale.Scale = 0.6
	TweenService:Create(scale, pulse, { Scale = 1.25 }):Play()
	task.delay(2.6, function()
		bb:Destroy()
	end)
end

local function outlineOf(): Highlight
	local h = outline
	if h and h.Parent then
		return h
	end
	local made = Instance.new("Highlight")
	made.Name = "CardioChaseOutline"
	made.OutlineColor = Color3.new(1, 0.1, 0.1)
	made.OutlineTransparency = 0
	made.FillColor = Color3.new(1, 0.1, 0.1)
	made.FillTransparency = 0.85
	made.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
	made.Enabled = false
	made.Parent = Workspace
	Highlights.claim(made, Highlights.PRIORITY.Chase, false)
	outline = made
	return made
end

local function buildChad(p: any, scale: number): Model?
	local base = tierLook(num(p.tier, 10))
	if not base or not folder then
		return nil
	end
	local look = table.clone(base)
	look.scale = scale
	look.exprs = { "Angry", "Smug", "Determined" }
	look.expr = "Angry"
	local ok, model = pcall(CharacterFactory.build, look, "ChaserChad")
	if not ok or not model then
		warn("[Fx.CardioChase] build failed: " .. tostring(model))
		return nil
	end
	local m = model :: Model
	-- Posed here, not by the Animator.
	m:RemoveTag(Poses.TAG)
	for _, d in m:GetDescendants() do
		if d:IsA("BasePart") then
			d.Anchored = true
			d.CanCollide = false
			d.CanQuery = false
			d.CanTouch = false
			d.CastShadow = true
		end
	end
	CharacterFactory.setExpression(m, "Angry")
	local root = m.PrimaryPart
	if root then
		rootOffset = m:GetPivot():ToObjectSpace(root.CFrame)
	end
	rig = RigPose.capture(m, 7)
	m.Parent = folder
	local h = outlineOf()
	h.Adornee = m
	Highlights.want(h, true)
	return m
end

-- Puts the Chad's feet at `feet` facing +X and poses it.
local function place(feet: Vector3, pose: string, time: number, fromPose: string?, alpha: number?)
	local m = chad
	if not m then
		return
	end
	local pivot = CFrame.lookAt(feet, feet + Vector3.new(1, 0, 0))
	local root = m.PrimaryPart
	if rig and root then
		root.CFrame = pivot * rootOffset
		local parts, cframes = RigPose.computePose(rig, pose, time, fromPose, alpha)
		Workspace:BulkMoveTo(parts, cframes, Enum.BulkMoveMode.FireCFrameChanged)
	else
		m:PivotTo(pivot)
	end
end

local function step()
	local c = chase
	if not c or not chad then
		return
	end
	local t = now()
	local root = playerRoot()
	local pz = if root then root.Position.Z else c.startZ
	local x, z, run = position(c, t, pz)
	local hop = 2.5 * c.scale
	local feet = Vector3.new(x, groundY(c.path, x, hop), z)
	local height = num(chad:GetAttribute("Height"), 5.6 * c.scale)
	if mode == "flex" then
		local k = os.clock() - flexStart
		place(feet, flexPose, k, "Run", math.min(1, k / 0.25))
		return
	end
	if t < c.startAt then
		-- Head start: a roaring flex at the starting line.
		place(feet, "MostMuscular", t, nil, nil)
	else
		-- Distance run along the path (the jog's sideways stretch included).
		local dist = math.max(0, math.min(c.stopS, c.startS + c.speed * run) - c.startS)
		local cadence = Poses.gaitTime("Run", dist, c.scale)
		place(feet, "Run", cadence, "MostMuscular", math.min(1, run / 0.3))
		-- A dust puff on every footfall (two per Run cycle).
		local period = Poses.GAIT.Run and Poses.GAIT.Run.period or 0.64
		local footfall = math.floor(cadence / (period / 2))
		if footfall ~= lastStep then
			lastStep = footfall
			if x < c.endX and math.abs(feet.Y - groundY(c.path, x + 0.01, 0)) < 0.2 then
				sprite("Puff", feet + Vector3.new(-1, 0.5, 0), {
					size = 2.2 * c.scale,
					life = 0.6,
					rise = Vector3.new(-2, 1.5, 0),
					color = Color3.fromRGB(235, 225, 210),
				})
			end
		end
	end
	-- Distance meter and vignette.
	if root and meter then
		local gap = math.max(0, root.Position.X - x - height * 0.1)
		local close = math.clamp(1 - gap / DANGER, 0, 1)
		meter.Visible = true
		meter.Text = if t < c.startAt then "CHAD IS COMING!" else string.format("CHAD %d STUDS BEHIND!", math.floor(gap))
		meter.TextColor3 = Color3.new(1, 1, 1):Lerp(RED, close)
		local pulse = if close > 0 then 0.75 + 0.25 * math.sin(os.clock() * (8 + 10 * close)) else 1
		setDanger(close * pulse)
	end
end

-- Stop chasing, flex / roar where it stands, then shrink away with a puff.
local function giveUp(pose: string, hold: number)
	local m = chad
	if not m or not chase then
		clear()
		return
	end
	-- Freeze it where it is (the formula would keep it running).
	local c0 = chase :: Chase
	local fx, fz = position(c0, now(), c0.startZ)
	local root = playerRoot()
	if root then
		fx, fz = position(c0, now(), root.Position.Z)
	end
	c0.frozen = { fx, fz }
	c0.startX, c0.endX = fx, fx
	mode = "flex"
	flexPose = pose
	flexStart = os.clock()
	if meter then
		meter.Visible = false
	end
	setDanger(0)
	local mine = token
	task.delay(hold, function()
		if token ~= mine or not chad then
			return
		end
		local pivot = m:GetPivot()
		sprite("Puff", pivot.Position + Vector3.new(0, 2, 0), { size = 8, life = 0.8, rise = Vector3.new(0, 3, 0) })
		clear()
	end)
end

local function onChase(p: any)
	clear()
	ensureGui()
	folder = folder or Instance.new("Folder")
	local f = folder :: Folder
	f.Name = "CardioChaseFx"
	f.Parent = Workspace
	local path: { Surface } = {}
	if type(p.path) == "table" then
		for _, s in p.path do
			if type(s) == "table" and #s >= 3 then
				table.insert(path, { num(s[1], 0), num(s[2], 0), num(s[3], 0) })
			end
		end
	end
	local line: { Vertex } = {}
	if type(p.line) == "table" then
		for _, v in p.line do
			if type(v) == "table" and #v >= 4 then
				table.insert(line, { num(v[1], 0), num(v[2], 0), num(v[3], 0), num(v[4], 0) })
			end
		end
	end
	local c: Chase = {
		stage = num(p.stage, 0),
		speed = num(p.speed, 0),
		startX = num(p.startX, 0),
		startZ = num(p.startZ, 0),
		startAt = num(p.startAt, now()),
		endX = num(p.endX, 0),
		zMin = num(p.zMin, -math.huge),
		zMax = num(p.zMax, math.huge),
		laneEase = num(p.laneEase, 1),
		path = path,
		line = line,
		startS = num(p.startS, 0),
		stopS = num(p.stopS, 0),
		scale = num(p.scale, 2) * SIZE_BOOST,
	}
	local m = buildChad(p, c.scale)
	if not m then
		return
	end
	chad = m
	chase = c
	mode = "chase"
	lastStep = 0
	RunService:BindToRenderStep(BIND, Enum.RenderPriority.Camera.Value + 2, step)
	step()
	local height = num(m:GetAttribute("Height"), 5.6 * c.scale)
	warnMark(m, height)
	local x = c.startX
	sprite("Puff", Vector3.new(x, groundY(c.path, x, 0) + 1, c.startZ), { size = 10, life = 0.8, rise = Vector3.new(0, 3, 0) })
	-- Alarm sting.
	Sounds.play("SurgeStart", 0, 0.7)
	Sounds.play("Error", 0, 0.8)
	task.delay(0.25, function()
		if chase == c then
			Sounds.play("Error", 0, 0.8)
		end
	end)
	splash("RUN!", RED, 0.9)
end

local function onCaught()
	if not chase then
		return
	end
	splash("MOGGED!", RED, 1.3)
	Sounds.play("Error", 0, 0.6)
	local root = playerRoot()
	if root then
		sprite("Puff", root.Position, { size = 7, life = 0.8, rise = Vector3.new(0, 3, 0), color = RED })
	end
	if chad then
		CharacterFactory.setExpression(chad, "Smug")
	end
	giveUp("DoubleBiceps", 1.2)
end

local function onEnd(p: any)
	if not chase then
		return
	end
	if p.reason == "escaped" then
		splash("ESCAPED!", Theme.Colors.Gold or Color3.fromRGB(255, 212, 64), 1.1)
		Sounds.play("Celebrate")
		if chad then
			CharacterFactory.setExpression(chad, "Angry")
		end
		-- The defeated roar: a flex at the edge of the safe zone.
		giveUp("MostMuscular", 1.6)
	elseif p.reason == "retreat" then
		giveUp("HandsOnHips", 1.0)
	else
		clear()
	end
end

function ChaseFx.onNotify(p: any)
	if type(p) ~= "table" then
		return
	end
	local event = p.event
	if event == "chase" then
		onChase(p)
	elseif event == "caught" then
		onCaught()
	elseif event == "chaseEnd" then
		onEnd(p)
	elseif event == "stop" then
		stop()
	end
end

-- Fx.Cardio calls this on every way out of a run (its own "stop" and the snapshot's
-- `running` going false), so the chaser, the meter and the red vignette never outlive it.
ChaseFx.stop = stop

function ChaseFx.init()
	Net.event("Notify").OnClientEvent:Connect(function(payload)
		if type(payload) == "table" and payload.kind == "Mode" and payload.mode == "cardio" then
			ChaseFx.onNotify(payload)
		end
	end)
	player.CharacterRemoving:Connect(stop)
end

return ChaseFx
