--[[
	Fx.Fans: the fan club around every plot (client-side only).

	World contract: workspace.Map.Plot<n>.FanSpots holds invisible parts named
	"FanSpot" (attribute Order, 1 = filled first; CFrame at ground level with
	LookVector toward the unit display; optional Vector3 attribute Entrance =
	the world point that spot's fan runs in from and walks off to: the back of
	its own zone column, so fans never cross the rack). Without it, an optional
	part "FanEntrance" in the same folder (ground level) is used, else a point
	behind the fan zone. The folder may be missing or arrive late: plots without
	it simply have no fans.

	- Count: clamp(Base + floor(bestTier * PerTier), 1, Max) fans on the local
	  player's plot, at most MaxOther on other plots within ~150 studs of the
	  camera; plots without units have none (Theme.Fans).
	- Looks are picked per plot + spot, so a plot's crowd never reshuffles.
	- New fans run in from the entrance, fade in, and settle with a little hop;
	  when the count drops the extra fans wave and walk off.
	- Idle: a slow mix of Idle / Clap / Wave / SignUp with random offsets.
	- The owner's Buy / Merge effects make the nearest fans Cheer or Jump with
	  hearts and stars floating up and, at most every BUBBLE_GAP seconds, one
	  speech bubble (Theme.Fans.Cheers). A new-tier reward makes the whole zone
	  cheer for 2 seconds.

	Fans are built with CharacterFactory (manual rigs, not the Animator) and
	posed here with RigPose: one RenderStepped loop, at most MAX_ANIMATED fans
	near the camera (the rest hold still, re-placed once per state change),
	everything written with one BulkMoveTo.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local CharacterFactory = require(Shared:WaitForChild("CharacterFactory"))
local Net = require(Shared:WaitForChild("Net"))
local Poses = require(Shared:WaitForChild("Poses"))
local RigPose = require(Shared:WaitForChild("RigPose"))
local Theme = require(ReplicatedStorage:WaitForChild("Theme"))

local State = require(script.Parent.Parent.State)
local Sprites = require(script.Parent.Sprites)

local Fans = {}

local W = Theme.World
local CFG = Theme.Fans

local MAX_ANIMATED = 16 -- fans posed per frame (the nearest to the camera)
local ANIM_RANGE = 160 -- studs: beyond this fans hold still
local NEAR = 60 -- studs: closer than this fans update every frame (else every 2nd)
local SHOW_OTHER = 150 -- studs: other plots' fans appear inside this range ...
local HIDE_OTHER = 170 -- ... and vanish outside this one
local POLL = 0.5 -- seconds between plot scans
local RANK_EVERY = 0.25 -- seconds between nearest-fan picks
local SPAWN_STAGGER = 0.35 -- seconds between fans of one plot starting their run
local ENTRANCE_BACK = 24 -- studs behind the fan zone when there is no FanEntrance
local LANE = 1.6 -- studs between the running lanes of neighbouring spots
local FADE = 0.35 -- seconds to fade in at the entrance / out at the exit
local SETTLE = 0.5 -- seconds of the arrival hop
local HOP = 0.6 -- arrival hop height (unscaled studs)
local TURN = 0.35 -- seconds to turn from waving to walking off
local LEAVE_WAVE = 1.1 -- seconds of goodbye wave before walking off
local POSE_BLEND = 0.4
local CHEER_GAP = 0.8 -- seconds between Buy / Merge cheers
local CHEER_LENGTH = 1.5
local REWARD_LENGTH = 2
local BUBBLE_GAP = 6
local BUBBLE_LIFE = 2.2
local MAX_PARTICLES = 24

local IDLE_POSES = { "Idle", "Idle", "Clap", "Wave", "SignUp" }
local CHEER_POSES = { "Cheer", "Jump", "Cheer" }
-- Text glyph, its colour, and the sprite drawn instead when uploaded.
local GLYPHS = {
	{ "♥", W.Pink, "Heart" },
	{ "♥", W.Coral, "Heart" },
	{ "★", W.Sunny, "StarPop" },
	{ "★", W.Orange, "StarPop" },
}
local RUN_SPEED = Poses.GAIT.Run.speed
local WALK_SPEED = Poses.GAIT.Walk.speed

type Spot = { order: number, cf: CFrame, entrance: Vector3? }

type PlotRec = {
	index: number,
	folder: Instance,
	group: Folder,
	spots: { Spot },
	fans: { [number]: Fan }, -- by spot index
	pending: { [number]: boolean },
	entrance: Vector3,
	center: Vector3,
	right: Vector3,
	want: number,
	shown: boolean,
	lastBubble: number,
}

-- state: "enter" (running to the spot) | "settle" (hop) | "idle" | "leave"
-- (goodbye wave) | "exit" (walking off) | "dead"
type Fan = {
	model: Model,
	rig: RigPose.Rig,
	plot: PlotRec,
	exit: Vector3, -- where it walks off to (its spot's entrance)
	slot: number,
	scale: number,
	height: number,
	random: Random,
	state: string,
	stateStart: number,
	from: Vector3,
	to: Vector3,
	length: number,
	moveYaw: number,
	spotYaw: number,
	clockBase: number, -- pose time = now - clockBase while standing
	gaitEnd: number,
	-- Current frame (written by advance, read by draw).
	pos: Vector3,
	yaw: number,
	lift: number,
	pose: string,
	prevPose: string?,
	poseStart: number,
	poseEnd: number,
	poseTime: number,
	alpha: number,
	fade: number,
	fadeShown: number,
	fadeParts: { BasePart },
	guis: { LayerCollector },
	dist: number,
	animated: boolean,
	drawnState: string, -- state of the last draw (fans that are not animated draw once per state)
}

local plots: { [number]: PlotRec } = {}
local allFans: { Fan } = {}
local ranked: { Fan } = {}
local spawnQueue: { { rec: PlotRec, spot: number, at: number } } = {}
local bulkParts: { BasePart } = {}
local bulkCFrames: { CFrame } = {}
local root: Folder? = nil
local fxAnchor: Part? = nil
local slotCounter = 0
local frameCount = 0
local nextRank = 0
local lastCheer = 0
local particles = 0
local started = false
local warned = false

local function smooth(x: number): number
	x = math.clamp(x, 0, 1)
	return x * x * (3 - 2 * x)
end

-- Yaw (about +Y) that turns a -Z-facing model to face `dir`.
local function yawOf(dir: Vector3): number
	return math.atan2(-dir.X, -dir.Z)
end

local function lerpAngle(a: number, b: number, t: number): number
	local d = (b - a + math.pi) % (2 * math.pi) - math.pi
	return a + d * t
end

local function cameraPos(): Vector3
	local camera = Workspace.CurrentCamera
	return if camera then camera.CFrame.Position else Vector3.zero
end

local function folder(): Folder
	local existing = root
	if existing and existing.Parent then
		return existing
	end
	local made = Instance.new("Folder")
	made.Name = "FanClub"
	made.Parent = Workspace
	root = made
	return made
end

-- Spots -------------------------------------------------------------------------------

-- Reads the plot's FanSpots (sorted by Order) and derives the entrance and zone frame.
local function readSpots(rec: PlotRec)
	local spotsFolder = rec.folder:FindFirstChild("FanSpots")
	local list: { BasePart } = {}
	local entrancePart: BasePart? = nil
	if spotsFolder then
		for _, child in spotsFolder:GetChildren() do
			if child:IsA("BasePart") then
				if child.Name == "FanSpot" then
					table.insert(list, child)
				elseif child.Name == "FanEntrance" then
					entrancePart = child
				end
			end
		end
	end
	local function orderOf(part: BasePart): number
		local value = part:GetAttribute("Order")
		return if type(value) == "number" then value else math.huge
	end
	table.sort(list, function(a, b)
		local oa, ob = orderOf(a), orderOf(b)
		if oa ~= ob then
			return oa < ob
		end
		return a.Name < b.Name
	end)
	local spots: { Spot } = {}
	local sum, look = Vector3.zero, Vector3.zero
	for i, part in list do
		local order = orderOf(part)
		local entrance = part:GetAttribute("Entrance")
		spots[i] = {
			order = if order == math.huge then i else order,
			cf = part.CFrame,
			entrance = if typeof(entrance) == "Vector3" then entrance else nil,
		}
		sum += part.CFrame.Position
		local flat = part.CFrame.LookVector * Vector3.new(1, 0, 1)
		if flat.Magnitude > 1e-3 then
			look += flat.Unit
		end
	end
	rec.spots = spots
	if #list == 0 then
		return
	end
	rec.center = sum / #list
	local forward = if look.Magnitude > 1e-3 then look.Unit else Vector3.new(0, 0, -1)
	rec.right = forward:Cross(Vector3.yAxis)
	if entrancePart then
		rec.entrance = entrancePart.CFrame.Position
	else
		rec.entrance = rec.center - forward * ENTRANCE_BACK
	end
end

local function bestTier(rec: PlotRec): number
	local units = rec.folder:FindFirstChild("Units")
	local best = 0
	if units then
		for _, unit in units:GetChildren() do
			local tier = unit:GetAttribute("Tier")
			if type(tier) == "number" and tier > best then
				best = tier
			end
		end
	end
	return best
end

-- Fans --------------------------------------------------------------------------------

local function setState(fan: Fan, state: string, now: number)
	fan.state = state
	fan.stateStart = now
end

-- Starts a run from where the fan stands now to `target` (used after a spot moves).
local function moveTo(fan: Fan, target: CFrame, now: number)
	fan.prevPose = fan.pose
	fan.from = fan.pos
	fan.to = target.Position
	fan.spotYaw = yawOf(target.LookVector)
	local delta = (fan.to - fan.from) * Vector3.new(1, 0, 1)
	fan.length = delta.Magnitude
	fan.moveYaw = if fan.length > 1e-3 then yawOf(delta) else fan.spotYaw
	setState(fan, "enter", now)
end

local function startLeave(fan: Fan, now: number)
	if fan.state == "leave" or fan.state == "exit" or fan.state == "dead" then
		return
	end
	if fan.state == "idle" or fan.state == "settle" then
		fan.prevPose = fan.pose
		fan.pose = "Wave"
		fan.poseStart = now
		setState(fan, "leave", now)
	else
		-- Still running in: turn round and walk straight off.
		fan.prevPose = "Run"
		fan.clockBase = now - fan.gaitEnd
		fan.from = fan.pos
		local delta = (fan.exit - fan.pos) * Vector3.new(1, 0, 1)
		fan.to = fan.pos + delta
		fan.length = delta.Magnitude
		fan.spotYaw = fan.yaw
		fan.moveYaw = if fan.length > 1e-3 then yawOf(delta) else fan.yaw
		setState(fan, "exit", now)
	end
end

local function nextIdlePose(fan: Fan, now: number)
	local previous = fan.pose
	local name = previous
	for _ = 1, 4 do
		name = IDLE_POSES[fan.random:NextInteger(1, #IDLE_POSES)]
		if name ~= previous then
			break
		end
	end
	fan.prevPose = previous
	fan.pose = name
	fan.poseStart = now
	local hold = if name == "Idle" then fan.random:NextNumber(2.4, 4.5) else fan.random:NextNumber(1.8, 3.2)
	fan.poseEnd = now + hold
end

local function spawnFan(rec: PlotRec, index: number, now: number)
	local spot = rec.spots[index]
	if not spot or rec.fans[index] then
		return
	end
	local looks = CFG.Looks
	local look = table.clone(looks[(rec.index * 3 + spot.order * 5) % #looks + 1])
	look.manual = true
	local signs = CFG.Signs
	if look.prop == "FanSign" and signs and #signs > 0 then
		look.signText = signs[(rec.index + spot.order * 3) % #signs + 1]
	end
	local ok, built = pcall(CharacterFactory.build, look, "Fan")
	if not ok then
		if not warned then
			warned = true
			warn("[Fans] could not build a fan: " .. tostring(built))
		end
		return
	end
	local model = built :: Model
	local seed = rec.index * 131 + spot.order * 17
	local rig = RigPose.capture(model, seed)
	if not rig then
		model:Destroy()
		return
	end
	slotCounter += 1
	-- The spot's own entrance, else the shared one with a lane per spot.
	local lane = ((spot.order % 5) - 2) * LANE
	local shared = rec.entrance + rec.right * lane
	local start: Vector3 = spot.entrance or Vector3.new(shared.X, rec.entrance.Y, shared.Z)
	local exit = start
	local target = spot.cf.Position
	local delta = (target - start) * Vector3.new(1, 0, 1)
	local spotYaw = yawOf(spot.cf.LookVector)
	local height = model:GetAttribute("Height")
	local fan: Fan = {
		model = model,
		rig = rig,
		plot = rec,
		exit = exit,
		slot = slotCounter,
		scale = rig.scale,
		height = if type(height) == "number" then height else 5,
		random = Random.new(seed + slotCounter),
		state = "enter",
		stateStart = now,
		from = start,
		to = target,
		length = delta.Magnitude,
		moveYaw = if delta.Magnitude > 1e-3 then yawOf(delta) else spotYaw,
		spotYaw = spotYaw,
		clockBase = now,
		gaitEnd = 0,
		pos = start,
		yaw = 0,
		lift = 0,
		pose = "Run",
		prevPose = nil,
		poseStart = now,
		poseEnd = now,
		poseTime = 0,
		alpha = 1,
		fade = 1,
		fadeShown = 1,
		fadeParts = {},
		guis = {},
		dist = 0,
		animated = false,
		drawnState = "",
	}
	fan.yaw = fan.moveYaw
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then
			if d ~= rig.root then
				d.LocalTransparencyModifier = 1
				table.insert(fan.fadeParts, d)
			end
		elseif d:IsA("LayerCollector") then
			d.Enabled = false
			table.insert(fan.guis, d)
		end
	end
	-- Place it at the entrance, mid-stride and invisible, before it enters the world.
	rig.root.CFrame = CFrame.new(start) * CFrame.Angles(0, fan.yaw, 0)
	local parts, cframes = RigPose.computePose(rig, "Run", 0)
	for i, part in parts do
		part.CFrame = cframes[i]
	end
	model.Parent = rec.group
	rec.fans[index] = fan
	table.insert(allFans, fan)
end

-- Works out where the fan is and which pose it shows this frame (cheap; runs for every fan).
-- Returns false once the fan has finished leaving.
local function advance(fan: Fan, now: number): boolean
	local state = fan.state
	local t = now - fan.stateStart
	fan.lift = 0
	fan.alpha = 1
	if state == "enter" then
		local speed = RUN_SPEED * fan.scale
		local d = math.min(t * speed, fan.length)
		fan.pos = if fan.length > 0 then fan.from:Lerp(fan.to, d / fan.length) else fan.to
		fan.yaw = fan.moveYaw
		fan.pose = "Run"
		fan.gaitEnd = Poses.gaitTime("Run", d, fan.scale)
		fan.poseTime = fan.gaitEnd
		if fan.prevPose then
			fan.alpha = smooth(t / 0.3)
			if fan.alpha >= 1 then
				fan.prevPose = nil
			end
		end
		if fan.fade > 0 then
			fan.fade = 1 - math.clamp(t / FADE, 0, 1)
		end
		if d >= fan.length then
			fan.clockBase = now - fan.gaitEnd
			fan.prevPose = "Run"
			fan.pose = "Idle"
			setState(fan, "settle", now)
		end
	elseif state == "settle" then
		local u = math.clamp(t / SETTLE, 0, 1)
		fan.pos = fan.to
		fan.yaw = lerpAngle(fan.moveYaw, fan.spotYaw, smooth(u))
		fan.lift = HOP * fan.scale * 4 * u * (1 - u)
		fan.alpha = u
		fan.poseTime = now - fan.clockBase
		fan.fade = 0
		if u >= 1 then
			fan.prevPose = nil
			fan.pose = "Idle"
			fan.poseStart = now
			fan.poseEnd = now + fan.random:NextNumber(0.5, 3.5)
			setState(fan, "idle", now)
		end
	elseif state == "idle" or state == "leave" then
		fan.pos = fan.to
		fan.yaw = fan.spotYaw
		fan.poseTime = now - fan.clockBase
		if state == "idle" and now >= fan.poseEnd then
			nextIdlePose(fan, now)
		end
		if fan.prevPose then
			fan.alpha = smooth((now - fan.poseStart) / POSE_BLEND)
		end
		if state == "leave" and t >= LEAVE_WAVE then
			fan.from = fan.to
			local delta = (fan.exit - fan.to) * Vector3.new(1, 0, 1)
			fan.to = fan.from + delta
			fan.length = delta.Magnitude
			fan.moveYaw = if fan.length > 1e-3 then yawOf(delta) else fan.spotYaw
			fan.prevPose = fan.pose
			fan.clockBase = now - fan.poseTime
			setState(fan, "exit", now)
		end
	elseif state == "exit" then
		local speed = WALK_SPEED * fan.scale
		local duration = fan.length / speed
		local d = math.min(t * speed, fan.length)
		fan.pos = if fan.length > 0 then fan.from:Lerp(fan.to, d / fan.length) else fan.to
		local turn = smooth(t / TURN)
		fan.yaw = lerpAngle(fan.spotYaw, fan.moveYaw, turn)
		fan.pose = "Walk"
		fan.poseTime = (now - t - fan.clockBase) + Poses.gaitTime("Walk", d, fan.scale)
		if fan.prevPose then
			fan.alpha = turn
		end
		fan.fade = math.clamp((t - (duration - FADE)) / FADE, 0, 1)
		if t >= duration + 0.05 then
			return false
		end
	else
		return false
	end
	return true
end

-- Poses one fan and queues its parts for the frame's BulkMoveTo.
local function draw(fan: Fan)
	fan.drawnState = fan.state
	local rig = fan.rig
	local pos = fan.pos
	rig.root.CFrame = CFrame.new(pos.X, pos.Y + fan.lift, pos.Z) * CFrame.Angles(0, fan.yaw, 0)
	local from = if fan.alpha < 1 then fan.prevPose else nil
	local parts, cframes = RigPose.computePose(rig, fan.pose, fan.poseTime, from, if from then fan.alpha else nil)
	local n = #bulkParts
	for i = 1, #parts do
		bulkParts[n + i] = parts[i]
		bulkCFrames[n + i] = cframes[i]
	end
	if fan.fade ~= fan.fadeShown then
		fan.fadeShown = fan.fade
		for _, part in fan.fadeParts do
			part.LocalTransparencyModifier = fan.fade
		end
		local visible = fan.fade < 0.5
		for _, gui in fan.guis do
			gui.Enabled = visible
		end
	end
end

local function removeFan(index: number)
	local fan = allFans[index]
	allFans[index] = allFans[#allFans]
	allFans[#allFans] = nil
	fan.state = "dead"
	local rec = fan.plot
	for spot, other in rec.fans do
		if other == fan then
			rec.fans[spot] = nil
		end
	end
	fan.model:Destroy()
end

local function closer(a: Fan, b: Fan): boolean
	return a.dist < b.dist
end

-- Picks the fans that get posed: the nearest MAX_ANIMATED in front of the camera.
local function rank()
	local camera = Workspace.CurrentCamera
	local camPos = cameraPos()
	local camLook = if camera then camera.CFrame.LookVector else Vector3.new(0, 0, -1)
	table.clear(ranked)
	for _, fan in allFans do
		fan.animated = false
		local offset = fan.pos - camPos
		fan.dist = offset.Magnitude
		if fan.dist <= ANIM_RANGE and offset:Dot(camLook) > -fan.height * 2 then
			table.insert(ranked, fan)
		end
	end
	if #ranked > MAX_ANIMATED then
		table.sort(ranked, closer)
	end
	for i = 1, math.min(#ranked, MAX_ANIMATED) do
		ranked[i].animated = true
	end
end

local function processQueue(now: number)
	local item = spawnQueue[1]
	if not item or item.at > now then
		return
	end
	table.remove(spawnQueue, 1)
	local rec = item.rec
	rec.pending[item.spot] = nil
	if plots[rec.index] == rec and item.spot <= rec.want and not rec.fans[item.spot] then
		spawnFan(rec, item.spot, now)
	end
end

local function step()
	frameCount += 1
	local now = os.clock()
	processQueue(now)
	if now >= nextRank then
		nextRank = now + RANK_EVERY
		rank()
	end
	table.clear(bulkParts)
	table.clear(bulkCFrames)
	local i = 1
	while i <= #allFans do
		local fan = allFans[i]
		if advance(fan, now) then
			if fan.animated then
				if fan.dist < NEAR or (frameCount + fan.slot) % 2 == 0 then
					draw(fan)
				end
			elseif fan.drawnState ~= fan.state then
				-- Beyond the animated few: still put it where its new state belongs, once.
				draw(fan)
			end
			i += 1
		else
			removeFan(i)
		end
	end
	if #bulkParts > 0 then
		Workspace:BulkMoveTo(bulkParts, bulkCFrames, Enum.BulkMoveMode.FireCFrameChanged)
	end
end

-- Cheering ----------------------------------------------------------------------------

local function burst(position: Vector3, count: number)
	local anchor = fxAnchor
	if not anchor or not anchor.Parent then
		local part = Instance.new("Part")
		part.Name = "FanFx"
		part.Anchored = true
		part.CanCollide = false
		part.CanQuery = false
		part.CanTouch = false
		part.CastShadow = false
		part.Transparency = 1
		part.Size = Vector3.one * 0.2
		part.CFrame = CFrame.new()
		part.Parent = folder()
		fxAnchor = part
		anchor = part
	end
	for _ = 1, count do
		if particles >= MAX_PARTICLES then
			return
		end
		particles += 1
		local glyph = GLYPHS[math.random(1, #GLYPHS)]
		local delay = math.random() * 0.3
		local start = position + Vector3.new((math.random() - 0.5) * 1.6, math.random() * 0.4, (math.random() - 0.5) * 1.6)
		local rise = 2.6 + math.random() * 1.4
		local drift = Vector3.new((math.random() - 0.5) * 1.2, rise, (math.random() - 0.5) * 1.2)
		local sprite = Sprites.billboard(anchor, glyph[3], {
			position = start,
			size = 0.9 + math.random() * 0.4,
			rise = drift,
			life = 1.5,
			delay = delay,
			spin = (math.random() - 0.5) * 40,
		})
		if sprite then
			task.delay(delay + 1.6, function()
				particles -= 1
			end)
			continue
		end
		local attachment = Instance.new("Attachment")
		attachment.Name = "FanSpark"
		attachment.Position = start
		local gui = Instance.new("BillboardGui")
		gui.Size = UDim2.fromScale(1.1, 1.1)
		gui.LightInfluence = 0
		gui.MaxDistance = 80
		gui.Adornee = attachment
		gui.Parent = attachment
		local scale = Instance.new("UIScale")
		scale.Scale = 0
		scale.Parent = gui
		local label = Instance.new("TextLabel")
		label.BackgroundTransparency = 1
		label.Size = UDim2.fromScale(1, 1)
		label.Font = Theme.Fonts.Number
		label.TextScaled = true
		label.Text = glyph[1]
		label.TextColor3 = glyph[2]
		label.TextStrokeColor3 = W.White
		label.TextStrokeTransparency = 0.15
		label.Parent = gui
		attachment.Parent = anchor
		TweenService:Create(scale, TweenInfo.new(0.28, Enum.EasingStyle.Back, Enum.EasingDirection.Out, 0, false, delay), { Scale = 1 })
			:Play()
		TweenService:Create(
			attachment,
			TweenInfo.new(1.5, Enum.EasingStyle.Quad, Enum.EasingDirection.Out, 0, false, delay),
			{ Position = start + drift }
		):Play()
		TweenService:Create(
			label,
			TweenInfo.new(0.6, Enum.EasingStyle.Quad, Enum.EasingDirection.In, 0, false, delay + 0.9),
			{ TextTransparency = 1, TextStrokeTransparency = 1 }
		):Play()
		task.delay(delay + 1.6, function()
			particles -= 1
			attachment:Destroy()
		end)
	end
end

local function showBubble(fan: Fan, now: number)
	local rec = fan.plot
	local cheers = CFG.Cheers
	if now - rec.lastBubble < BUBBLE_GAP or not cheers or #cheers == 0 or not fan.model.Parent then
		return
	end
	rec.lastBubble = now
	local text = cheers[math.random(1, #cheers)]
	local width = math.clamp(1.4 + #text * 0.34, 3.6, 7)
	local top = fan.height + 1.2

	local gui = Instance.new("BillboardGui")
	gui.Name = "FanBubble"
	gui.Size = UDim2.fromScale(width, 1.6)
	gui.StudsOffsetWorldSpace = Vector3.new(0, top - 0.4, 0)
	gui.LightInfluence = 0
	gui.MaxDistance = 45
	gui.Adornee = fan.rig.root
	local scale = Instance.new("UIScale")
	scale.Scale = 0.3
	scale.Parent = gui

	local function stroke(parent: GuiObject): UIStroke
		local s = Instance.new("UIStroke")
		s.Color = W.Ink
		s.Transparency = 0.7
		s.Thickness = 1.5
		s.Parent = parent
		return s
	end
	local tail = Instance.new("Frame")
	tail.Name = "Tail"
	tail.AnchorPoint = Vector2.new(0.5, 0.5)
	tail.Position = UDim2.fromScale(0.5, 0.74)
	tail.SizeConstraint = Enum.SizeConstraint.RelativeYY
	tail.Size = UDim2.fromScale(0.3, 0.3)
	tail.Rotation = 45
	tail.BackgroundColor3 = W.White
	tail.BorderSizePixel = 0
	tail.ZIndex = 1
	tail.Parent = gui
	local tailStroke = stroke(tail)
	local bubble = Instance.new("Frame")
	bubble.Name = "Bubble"
	bubble.Size = UDim2.fromScale(1, 0.78)
	bubble.BackgroundColor3 = W.White
	bubble.BorderSizePixel = 0
	bubble.ZIndex = 2
	bubble.Parent = gui
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0.5, 0)
	corner.Parent = bubble
	local bubbleStroke = stroke(bubble)
	local label = Instance.new("TextLabel")
	label.AnchorPoint = Vector2.new(0.5, 0.5)
	label.Position = UDim2.fromScale(0.5, 0.5)
	label.Size = UDim2.fromScale(0.84, 0.7)
	label.BackgroundTransparency = 1
	label.Font = Theme.Fonts.UI
	label.TextScaled = true
	label.TextColor3 = W.Ink
	label.Text = text
	label.ZIndex = 3
	label.Parent = bubble
	gui.Parent = fan.rig.root

	local popIn = TweenInfo.new(0.28, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
	TweenService:Create(scale, popIn, { Scale = 1 }):Play()
	TweenService:Create(gui, popIn, { StudsOffsetWorldSpace = Vector3.new(0, top, 0) }):Play()
	task.delay(BUBBLE_LIFE, function()
		if not gui.Parent then
			return
		end
		local out = TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
		TweenService:Create(scale, out, { Scale = 0.85 }):Play()
		TweenService:Create(bubble, out, { BackgroundTransparency = 1 }):Play()
		TweenService:Create(tail, out, { BackgroundTransparency = 1 }):Play()
		TweenService:Create(label, out, { TextTransparency = 1 }):Play()
		TweenService:Create(bubbleStroke, out, { Transparency = 1 }):Play()
		TweenService:Create(tailStroke, out, { Transparency = 1 }):Play()
		task.delay(0.32, function()
			gui:Destroy()
		end)
	end)
end

local function ownPlot(): PlotRec?
	local data = State.data
	local index = data and data.plotIndex
	return if type(index) == "number" then plots[index] else nil
end

-- Makes up to `count` standing fans of the local player's plot cheer (the nearest to
-- `near`, else the front rows) with hearts, stars and maybe a speech bubble.
local function cheer(count: number, duration: number, near: Vector3?)
	local rec = ownPlot()
	if not rec then
		return
	end
	local now = os.clock()
	local pick: { Fan } = {}
	for spot, fan in rec.fans do
		if fan.state == "idle" then
			fan.dist = if near then (fan.pos - near).Magnitude else spot
			table.insert(pick, fan)
		end
	end
	if #pick == 0 then
		return
	end
	table.sort(pick, closer)
	local n = math.min(count, #pick)
	for k = 1, n do
		local fan = pick[k]
		local start = now + (k - 1) * 0.07
		fan.prevPose = fan.pose
		fan.pose = CHEER_POSES[fan.random:NextInteger(1, #CHEER_POSES)]
		fan.poseStart = start
		fan.poseEnd = start + duration + fan.random:NextNumber(0, 0.3)
		if k <= 4 then
			burst(fan.pos + Vector3.new(0, fan.height + 0.3, 0), if n > 4 then 2 else 3)
		end
	end
	showBubble(pick[math.random(1, math.min(n, 3))], now)
end

-- Plot scan ---------------------------------------------------------------------------

local function dropPlot(rec: PlotRec)
	for _, fan in allFans do
		if fan.plot == rec then
			fan.state = "dead"
		end
	end
	table.clear(rec.fans)
	rec.group:Destroy()
end

local function newPlot(index: number, plotFolder: Instance): PlotRec
	local group = Instance.new("Folder")
	group.Name = "Plot" .. index
	group.Parent = folder()
	return {
		index = index,
		folder = plotFolder,
		group = group,
		spots = {},
		fans = {},
		pending = {},
		entrance = Vector3.zero,
		center = Vector3.zero,
		right = Vector3.xAxis,
		want = 0,
		shown = false,
		lastBubble = 0,
	}
end

local function syncPlot(rec: PlotRec, own: boolean, camPos: Vector3, now: number)
	local oldSpots = rec.spots
	readSpots(rec)
	local spots = rec.spots
	local want = 0
	local best = if #spots > 0 then bestTier(rec) else 0
	if best > 0 then
		want = math.clamp(CFG.Base + math.floor(best * CFG.PerTier), 1, CFG.Max)
		if not own then
			want = math.min(want, CFG.MaxOther)
			local range = if rec.shown then HIDE_OTHER else SHOW_OTHER
			rec.shown = (rec.center - camPos).Magnitude <= range
			if not rec.shown then
				want = 0
			end
		end
		want = math.min(want, #spots)
	end
	rec.want = want
	local far = not own and not rec.shown
	local queued = 0
	for i = 1, math.max(#spots, #oldSpots) do
		local fan = rec.fans[i]
		if i <= want then
			local spot = spots[i]
			if not fan then
				if not rec.pending[i] then
					rec.pending[i] = true
					table.insert(spawnQueue, { rec = rec, spot = i, at = now + queued * SPAWN_STAGGER })
					queued += 1
				end
			elseif fan.state ~= "dead" and (spot.cf.Position - fan.to).Magnitude > 0.5 then
				fan.exit = spot.entrance or fan.exit
				moveTo(fan, spot.cf, now)
			end
		elseif fan then
			rec.fans[i] = nil
			if far then
				-- Out of range: nobody is watching, just tidy up.
				fan.state = "dead"
			else
				startLeave(fan, now)
			end
		end
	end
end

local function poll()
	local map = Workspace:FindFirstChild("Map")
	local data = State.data
	local ownIndex = if data then data.plotIndex else nil
	local camPos = cameraPos()
	local now = os.clock()
	if map then
		for _, child in map:GetChildren() do
			local index = tonumber(string.match(child.Name, "^Plot(%d+)$"))
			if index then
				local rec = plots[index]
				if rec and rec.folder ~= child then
					dropPlot(rec)
					rec = nil
				end
				if not rec then
					rec = newPlot(index, child)
					plots[index] = rec
				end
				syncPlot(rec :: PlotRec, index == ownIndex, camPos, now)
			end
		end
	end
	for index, rec in plots do
		if not map or rec.folder.Parent ~= map then
			dropPlot(rec)
			plots[index] = nil
		end
	end
end

function Fans.init()
	if started then
		return
	end
	started = true
	local startedAt = os.clock()
	task.spawn(function()
		while true do
			-- Wait for the first snapshot (it names our plot) before filling crowds.
			if State.data or os.clock() - startedAt > 8 then
				local ok, err = pcall(poll)
				if not ok and not warned then
					warned = true
					warn("[Fans] " .. tostring(err))
				end
			end
			task.wait(POLL)
		end
	end)
	RunService.RenderStepped:Connect(step)

	Net.event("Effect").OnClientEvent:Connect(function(kind: string, data: any)
		if kind ~= "Buy" and kind ~= "Merge" then
			return
		end
		local now = os.clock()
		if now - lastCheer < CHEER_GAP then
			return
		end
		lastCheer = now
		local near: Vector3? = nil
		if type(data) == "table" then
			if typeof(data.to) == "Vector3" then
				near = data.to
			elseif typeof(data.padPos) == "Vector3" then
				near = data.padPos
			end
		end
		cheer(3, CHEER_LENGTH, near)
	end)
	Net.event("Notify").OnClientEvent:Connect(function(payload: any)
		if type(payload) == "table" and payload.kind == "Reward" and payload.new == true then
			lastCheer = os.clock()
			cheer(math.huge, REWARD_LENGTH, nil)
		end
	end)
end

return Fans
