--[[
	Fx.Crates: client-side juice for the crates on the local player's plot
	(workspace.Map.PlotN.Chests, server-built anchored models).

	- Arrival: a Chad on the display ledge drops the crate. The server places it
	  on its landing spot in the pen and stores the route as world-space
	  attributes Path1..PathN + PathCount + PathKinds (crate-pivot waypoints:
	  unit feet, drop point in front of the rack, gutter, chute top, chute
	  bottom, landing; read by Orbs.readRoute) and Origin (the unit's feet).
	  The crate pops out in front of the Chad with a puff, hops low off its
	  shelf to the drop point, falls into the gutter (turned along it) with a
	  bounce, slides along it and down the chute with a wobble and quarter-turn tumbles
	  (shrunk to fit the trough), bounces twice into the pen growing back to
	  full size, then squashes and settles. Its sparkles stay hidden until it lands.
	- Idle: gentle bob, slow spin and a slight sway over a soft rarity-coloured
	  ground disc whose size scales with rarity.
	- Pickup is automatic (the server's fast tick, CratePickup rules): walking up to a
	  landed crate picks it up. While the player already holds a crate and stands in
	  pickup range, the crate gives a small "can't" wiggle at most every WIGGLE_GAP s.
	- Rarity label: the rarity word ("Common", ...) floats over every landed crate as
	  bold rarity-coloured text with an Ink outline, visible within CHIP_RANGE studs of
	  the camera and hidden while the held-crate panel is open (TycoonUI CratePanelOpen).
	- Pickup (model removed): a sparkle puff where it stood.

	Crates that already exist when the plot is bound just appear in place.
	All movement is local (BulkMoveTo on the server's anchored parts) and a pure
	function of time since the crate appeared, so it is frame-rate independent.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Economy = require(Shared:WaitForChild("Economy"))
local CratePickup = require(Shared:WaitForChild("CratePickup"))
local Theme = require(ReplicatedStorage:WaitForChild("Theme"))

local Client = script.Parent.Parent
local Animator = require(Client.Animator)
local Sounds = require(Client.Sounds)
local State = require(Client.State)
local Camera = require(script.Parent.Camera)
local Orbs = require(script.Parent.Orbs)
local Sprites = require(script.Parent.Sprites)

local Crates = {}

local WHITE = Color3.new(1, 1, 1)
local HIDDEN = CFrame.new(0, -10000, 0)
local UPRIGHT = CFrame.Angles(0, 0, math.pi / 2)
local UP = Vector3.yAxis
local PUFF = Sprites.image("Puff") -- the Blender dust cloud; the built-in smoke without it
local SMOKE = PUFF or "rbxasset://textures/particles/smoke_main.dds"

local TRAVEL_SCALE = 0.72 -- crates shrink to fit the gutter and chute
local POP = 0.2 -- pop-in behind the Chad
local POP_FORWARD, POP_UP = 1.2, 0.3 -- pop-in spot: just in front of the Chad's feet
local HOP_MIN, HOP_MAX, HOP_APEX = 0.35, 0.6, 1 -- low hop: the shelf above is overhead
local FALL_G, FALL_MAX = 70, 0.75 -- fall into the gutter (the top shelf's fall is capped)
local GUTTER_V0, GUTTER_ACCEL, GUTTER_VMAX = 4, 11, 13
local CHUTE_ACCEL, CHUTE_VMAX = 14, 13
local BOUNCE1, BOUNCE1_APEX, BOUNCE1_SHARE = 0.44, 1.9, 0.72
local BOUNCE2, BOUNCE2_APEX = 0.26, 0.6
local SQUASH = 0.6
local FALLBACK_DROP = 7 -- no route: drop from this high above the landing spot
local CULL = 170 -- studs from the camera: beyond this crates stay still
local MAX_CRATES = 8
local CHIP_RANGE = 70 -- camera distance cap of the rarity labels (BillboardGui.MaxDistance)
local CHIP_HEIGHT = 1.6 -- studs
-- Share of the chip's stud size that scales with distance; fixed pixels per letter and in
-- height keep it readable far away without it covering the pile up close.
local CHIP_SCALE = 0.55
local CHIP_PX_PER_LETTER = 6
local CHIP_PX_HEIGHT = 8
local CHIP_SCAN = 0.15 -- seconds between chip range checks
local WIGGLE = 0.45 -- seconds of one "can't" wiggle
local INK = (Theme :: any).World and (Theme :: any).World.Ink or Color3.fromRGB(58, 48, 96)

-- One leg of the arrival. kind: "pop" | "hop" | "fall" | "slide" | "arc".
type Leg = {
	kind: string,
	from: Vector3,
	to: Vector3,
	t0: number,
	dur: number,
	apex: number,
	v0: number,
	accel: number,
	vmax: number,
	tumbles: number, -- quarter turns during this leg
	turned: number, -- quarter turns completed before it
	face: CFrame, -- facing during the leg (long side along the travel direction)
	faceFrom: CFrame, -- the previous leg's facing, turned from over the leg's start
}

type Crate = {
	model: Model,
	base: CFrame,
	parts: { BasePart },
	offsets: { CFrame },
	sizes: { Vector3 },
	bottom: number, -- lowest point relative to the pivot (negative)
	half: Vector3, -- half extents of the crate's box
	mid: number, -- height of the box's middle above the pivot
	rarity: string,
	rank: number,
	color: Color3,
	born: number, -- os.clock() of the arrival start (or long ago for no arrival)
	land: number, -- seconds from born to touchdown
	legs: { Leg },
	bounced: boolean,
	source: Model?,
	wiggleAt: number, -- os.clock() of the last "can't" wiggle start
	phase: number,
	disc: Part,
	chip: BillboardGui,
	chipOn: boolean,
	chipToken: number,
	shown: boolean,
	landed: boolean,
	restored: boolean,
	broken: boolean,
}

local crates: { [Model]: Crate } = {}
local crateCount = 0
local moveParts: { BasePart } = {}
local moveCFrames: { CFrame } = {}
local started = false

-- Helpers -------------------------------------------------------------------------------

local function fxPart(shape: Enum.PartType, name: string, color: Color3): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Shape = shape
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Material = Enum.Material.SmoothPlastic
	p.Color = color
	p.Size = Vector3.one
	p.CFrame = HIDDEN
	p.Parent = Orbs.getFolder()
	return p
end

local function rarityOf(model: Model): string
	local attr = model:GetAttribute("Rarity")
	if type(attr) == "string" and attr ~= "" then
		return attr
	end
	for _, name in Economy.CHEST_RARITIES do
		if string.find(model.Name, name, 1, true) == 1 then
			return name
		end
	end
	return "Common"
end

local function rankOf(rarity: string): number
	local index = table.find(Economy.CHEST_RARITIES, rarity)
	if index then
		return index - 1
	end
	return if rarity == "Mythic" then 5 else 1
end

local function backOut(x: number): number
	local c1 = 1.9
	local c3 = c1 + 1
	local y = x - 1
	return 1 + c3 * y * y * y + c1 * y * y
end

local function smooth(x: number): number
	local c = math.clamp(x, 0, 1)
	return c * c * (3 - 2 * c)
end

local function nearCamera(pos: Vector3, range: number): boolean
	local camera = Workspace.CurrentCamera
	return camera ~= nil and (camera.CFrame.Position - pos).Magnitude <= range
end

local function localRoot(): BasePart?
	local character = Players.LocalPlayer.Character
	return character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
end

local function playerNear(pos: Vector3, range: number): boolean
	local root = localRoot()
	return root ~= nil and (root.Position - pos).Magnitude <= range
end

local function holdingCrate(): boolean
	local held = State.data and State.data.heldChest
	return type(held) == "string" and held ~= ""
end

-- Body visibility, and the label / sparkles (only live once landed).
local function setShown(crate: Crate, body: boolean, extras: boolean)
	for _, part in crate.parts do
		part.LocalTransparencyModifier = if body then 0 else 1
	end
	for _, d in crate.model:GetDescendants() do
		if d:IsA("BillboardGui") or d:IsA("Sparkles") then
			d.Enabled = extras
		end
	end
end

local function smokePuff(pos: Vector3, count: number, speed: number)
	local holder = fxPart(Enum.PartType.Block, "CrateDust", WHITE)
	holder.Size = Vector3.one * 0.2
	holder.Transparency = 1
	holder.CFrame = CFrame.new(pos)
	local emitter = Instance.new("ParticleEmitter")
	emitter.Texture = SMOKE
	emitter.Color = ColorSequence.new(Color3.fromRGB(225, 215, 200))
	emitter.LightEmission = 0
	emitter.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1.2),
		NumberSequenceKeypoint.new(1, 2.6),
	})
	emitter.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.4),
		NumberSequenceKeypoint.new(1, 1),
	})
	emitter.Lifetime = NumberRange.new(0.4, 0.7)
	emitter.Speed = NumberRange.new(speed * 0.6, speed)
	emitter.SpreadAngle = Vector2.new(85, 85)
	emitter.EmissionDirection = Enum.NormalId.Top
	emitter.Drag = 6
	if PUFF then
		emitter.Rotation = NumberRange.new(-180, 180)
		emitter.RotSpeed = NumberRange.new(-30, 30)
	end
	emitter.Rate = 0
	emitter.Parent = holder
	emitter:Emit(count)
	task.delay(1.2, function()
		holder:Destroy()
	end)
end

-- Rarity label ------------------------------------------------------------------------

-- The rarity word ("Common", ...) as floating bold text in the rarity colour with a dark Ink
-- outline, parented to the client-only ground disc and adorned to the crate's primary part so
-- it follows the bob.
local function makeChip(rarity: string, color: Color3, adornee: BasePart, above: number, parent: Instance): BillboardGui
	local word = string.upper(string.sub(rarity, 1, 1)) .. string.lower(string.sub(rarity, 2))
	local gui = Instance.new("BillboardGui")
	gui.Name = "RarityChip"
	gui.Adornee = adornee
	gui.AlwaysOnTop = false
	gui.LightInfluence = 0
	gui.MaxDistance = CHIP_RANGE
	gui.Size = UDim2.new((0.6 + #word * 0.82) * CHIP_SCALE, #word * CHIP_PX_PER_LETTER, CHIP_HEIGHT * CHIP_SCALE, CHIP_PX_HEIGHT)
	gui.StudsOffset = Vector3.new(0, above + 0.3, 0)
	gui.Enabled = false
	gui.Parent = parent
	local pill = Instance.new("Frame")
	pill.Name = "Pill"
	pill.AnchorPoint = Vector2.new(0.5, 0.5)
	pill.Position = UDim2.fromScale(0.5, 0.5)
	pill.Size = UDim2.fromScale(1, 1)
	pill.BackgroundTransparency = 1
	pill.BorderSizePixel = 0
	pill.Parent = gui
	local scale = Instance.new("UIScale")
	scale.Scale = 0.7
	scale.Parent = pill
	local text = Instance.new("TextLabel")
	text.Name = "Word"
	text.BackgroundTransparency = 1
	text.AnchorPoint = Vector2.new(0.5, 0.5)
	text.Position = UDim2.fromScale(0.5, 0.5)
	text.Size = UDim2.fromScale(1, 1)
	text.Font = Theme.Fonts.Title
	text.TextScaled = true
	text.Text = word
	text.TextColor3 = color
	text.TextTransparency = 1
	text.Parent = pill
	local outline = Instance.new("UIStroke")
	outline.Color = INK
	outline.Thickness = 2.5
	outline.LineJoinMode = Enum.LineJoinMode.Round
	outline.Transparency = 1
	outline.Parent = text
	return gui
end

-- Fades the crate's label in (small grow) or out (then disables it).
local function fadeChip(crate: Crate, on: boolean)
	if crate.chipOn == on then
		return
	end
	crate.chipOn = on
	crate.chipToken += 1
	local token = crate.chipToken
	local gui = crate.chip
	local pill = gui:FindFirstChild("Pill") :: Frame?
	local text = pill and pill:FindFirstChild("Word") :: TextLabel?
	if not pill or not text then
		return
	end
	local outline = text:FindFirstChildOfClass("UIStroke") :: UIStroke
	local scale = pill:FindFirstChildOfClass("UIScale") :: UIScale
	local info = if on
		then TweenInfo.new(0.22, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
		else TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
	if on then
		gui.Enabled = true
	end
	TweenService:Create(outline, info, { Transparency = if on then 0 else 1 }):Play()
	local grow = if on then TweenInfo.new(0.26, Enum.EasingStyle.Back, Enum.EasingDirection.Out) else info
	TweenService:Create(scale, grow, { Scale = if on then 1 else 0.7 }):Play()
	local fade = TweenService:Create(text, info, { TextTransparency = if on then 0 else 1 })
	if not on then
		fade.Completed:Once(function()
			if crate.chipToken == token then
				gui.Enabled = false
			end
		end)
	end
	fade:Play()
end

-- True while the held-crate panel is open (PlayerGui.TycoonUI's CratePanelOpen attribute).
local function cratePanelOpen(): boolean
	local playerGui = Players.LocalPlayer:FindFirstChildOfClass("PlayerGui")
	local ui = playerGui and playerGui:FindFirstChild("TycoonUI")
	return ui ~= nil and ui:GetAttribute("CratePanelOpen") == true
end

local lastChipScan = 0

-- Labels show over every landed crate (BillboardGui.MaxDistance limits the range), except
-- while the held-crate panel is open.
local function scanChips(now: number)
	if now - lastChipScan < CHIP_SCAN then
		return
	end
	lastChipScan = now
	local hidden = cratePanelOpen()
	for model, crate in crates do
		local want = crate.landed and model.Parent ~= nil and not hidden
		fadeChip(crate, want)
	end
end

-- Places every part: `cf` is the animated pivot; (sx, sy) scale around the crate bottom.
local function place(crate: Crate, cf: CFrame, sx: number, sy: number)
	local scaled = sx ~= 1 or sy ~= 1
	local scale = Vector3.new(sx, sy, sx)
	local bottom = Vector3.new(0, crate.bottom, 0)
	for i, part in crate.parts do
		local offset = crate.offsets[i]
		if scaled then
			local p = (offset.Position - bottom) * scale + bottom
			offset = CFrame.new(p) * offset.Rotation
			part.Size = crate.sizes[i] * scale
		elseif not crate.restored then
			part.Size = crate.sizes[i]
		end
		table.insert(moveParts, part)
		table.insert(moveCFrames, cf * offset)
	end
	crate.restored = not scaled
end

-- Arrival route ---------------------------------------------------------------------------

-- Distance covered after t seconds starting at v0, accelerating at `a` up to vmax.
local function accelDist(t: number, v0: number, a: number, vmax: number): number
	local tCap = math.max((vmax - v0) / a, 0)
	if t <= tCap then
		return v0 * t + 0.5 * a * t * t
	end
	return v0 * tCap + 0.5 * a * tCap * tCap + vmax * (t - tCap)
end

-- Time to cover `len`, and the speed at the end.
local function accelTime(len: number, v0: number, a: number, vmax: number): (number, number)
	local tCap = math.max((vmax - v0) / a, 0)
	local dCap = v0 * tCap + 0.5 * a * tCap * tCap
	if len <= dCap then
		local t = (-v0 + math.sqrt(v0 * v0 + 2 * a * len)) / a
		return t, v0 + a * t
	end
	return tCap + (len - dCap) / vmax, vmax
end

local function readRoute(model: Model): Orbs.Route?
	return Orbs.readRoute(model, "Path")
end

local function flatDir(v: Vector3): Vector3?
	local f = Vector3.new(v.X, 0, v.Z)
	return if f.Magnitude > 1e-3 then f.Unit else nil
end

-- Builds the arrival legs; returns them and the touchdown time.
local function buildLegs(route: Orbs.Route?, landing: Vector3): ({ Leg }, number)
	local legs: { Leg } = {}
	local t, turned = 0, 0
	local function add(kind: string, from: Vector3, to: Vector3, dur: number, tumbles: number, apex: number?)
		table.insert(legs, {
			kind = kind,
			from = from,
			to = to,
			t0 = t,
			dur = dur,
			apex = apex or 0,
			v0 = 0,
			accel = 0,
			vmax = 0,
			tumbles = tumbles,
			turned = turned,
			face = CFrame.identity,
			faceFrom = CFrame.identity,
		})
		t += dur
		turned += tumbles
		return legs[#legs]
	end
	local chuteEnd: Vector3
	-- Facing for the fall: along the gutter, so the crate's long side never points into the rack.
	local fallFace: Vector3? = nil
	if route then
		local feet, drop, gutter, top, bottom = route.feet, route.drop, route.gutter, route.chuteTop, route.chuteBottom
		-- Pops out just in front of the Chad, hops low (under the shelf above) to the drop point.
		local out = flatDir(drop - feet) or flatDir(gutter - feet) or Vector3.new(0, 0, -1)
		local start = feet + out * POP_FORWARD + UP * POP_UP
		add("pop", start, start, POP, 0)
		local hopLen = Vector3.new(drop.X - start.X, 0, drop.Z - start.Z).Magnitude
		add("hop", start, drop, math.clamp(0.3 + hopLen * 0.025, HOP_MIN, HOP_MAX), 1, HOP_APEX)
		-- Falls with gravity-like easing (capped so the top shelf stays snappy) and bounces.
		local fall = drop.Y - gutter.Y
		if fall > 0.05 or (drop - gutter).Magnitude > 0.05 then
			local dur = math.clamp(math.sqrt(2 * math.max(fall, 0) / FALL_G), 0.12, FALL_MAX)
			add("fall", drop, gutter, dur, if fall > 12 then 1 else 0)
			fallFace = flatDir(top - gutter) or Vector3.xAxis
		end
		local gDir = flatDir(top - gutter)
		local gLen = (top - gutter).Magnitude
		local bounce = math.clamp(fall * 0.03, 0.25, 0.9)
		local hop = if gDir then math.min(gLen * 0.3, 1.2) else 0
		local landed = gutter + (if gDir then gDir * hop else Vector3.zero)
		add("arc", gutter, landed, 0.12 + bounce * 0.2, 0, bounce)
		local sLen = (top - landed).Magnitude
		local vEnd = GUTTER_V0
		if sLen > 0.05 then
			local dur, v = accelTime(sLen, GUTTER_V0, GUTTER_ACCEL, GUTTER_VMAX)
			local leg = add("slide", landed, top, dur, if sLen > 6 then 1 else 0)
			leg.v0, leg.accel, leg.vmax = GUTTER_V0, GUTTER_ACCEL, GUTTER_VMAX
			vEnd = v
		end
		local cLen = (bottom - top).Magnitude
		if cLen > 0.05 then
			local v0 = math.clamp(vEnd * 0.8, 3, CHUTE_VMAX)
			local dur = accelTime(cLen, v0, CHUTE_ACCEL, CHUTE_VMAX)
			local leg = add("slide", top, bottom, dur, 1)
			leg.v0, leg.accel, leg.vmax = v0, CHUTE_ACCEL, CHUTE_VMAX
		end
		chuteEnd = bottom
	else
		chuteEnd = landing + UP * FALLBACK_DROP
		add("pop", chuteEnd, chuteEnd, POP, 0)
	end
	local mid = chuteEnd:Lerp(landing, BOUNCE1_SHARE)
	mid = Vector3.new(mid.X, landing.Y, mid.Z)
	add("arc", chuteEnd, mid, BOUNCE1, 1, BOUNCE1_APEX)
	add("arc", mid, landing, BOUNCE2, 0, BOUNCE2_APEX)

	-- Facing per leg (long side along the travel direction), turning smoothly from the
	-- previous leg's. Legs without horizontal travel keep the facing they inherit.
	local dirs: { Vector3? } = {}
	for i, leg in legs do
		dirs[i] = if leg.kind == "fall" then fallFace else flatDir(leg.to - leg.from)
	end
	local prev: Vector3? = nil
	for i = 1, #legs do
		prev = dirs[i] or prev
		if not prev then
			for j = i + 1, #legs do
				prev = prev or dirs[j]
			end
		end
		dirs[i] = prev
	end
	local last = CFrame.identity
	for i, leg in legs do
		local d = dirs[i]
		leg.face = if d then CFrame.fromMatrix(Vector3.zero, d, UP) else CFrame.identity
		leg.faceFrom = if i == 1 then leg.face else last
		last = leg.face
	end
	return legs, t
end

-- Pivot CFrame and uniform scale at `t` seconds into the arrival (t < crate.land).
local function sampleArrival(crate: Crate, t: number): (CFrame, number)
	local legs = crate.legs
	local leg = legs[#legs]
	for _, l in legs do
		if t < l.t0 + l.dur then
			leg = l
			break
		end
	end
	local u = math.clamp((t - leg.t0) / math.max(leg.dur, 1e-3), 0, 1)
	local pos: Vector3
	if leg.kind == "slide" then
		local len = (leg.to - leg.from).Magnitude
		local s = math.min(accelDist(t - leg.t0, leg.v0, leg.accel, leg.vmax), len)
		pos = leg.from:Lerp(leg.to, if len > 0 then s / len else 1)
	elseif leg.kind == "pop" then
		pos = leg.from
	elseif leg.kind == "fall" then
		pos = leg.from:Lerp(leg.to, u * u)
	else
		pos = leg.from:Lerp(leg.to, u) + UP * (leg.apex * 4 * u * (1 - u))
	end

	-- Facing: the long side along the direction of travel, turning in over the leg's start.
	local facing = leg.faceFrom:Lerp(leg.face, smooth(u / 0.35))

	-- Quarter-turn tumbles, centred in the leg, rising onto an edge mid-turn.
	local spin = leg.turned
	if leg.tumbles > 0 then
		spin += leg.tumbles * smooth((u - 0.3) / 0.4)
	end
	local wobble = 0
	if leg.kind == "slide" then
		wobble = 1
	end
	local wob = CFrame.Angles(math.sin(t * 13) * 0.12 * wobble, math.sin(t * 7.5) * 0.08 * wobble, 0)
	local rot = facing * wob * CFrame.Angles(0, 0, -spin * math.pi / 2)

	-- Grow back to full size and turn to the resting angle over the two bounces.
	local scale = TRAVEL_SCALE
	if leg.kind == "pop" then
		scale = TRAVEL_SCALE * backOut(u)
	end
	local bounceStart = legs[#legs - 1].t0
	if t >= bounceStart then
		local g = smooth((t - bounceStart) / (crate.land - bounceStart))
		scale = TRAVEL_SCALE + (1 - TRAVEL_SCALE) * g
		rot = rot:Lerp(crate.base.Rotation, smooth((t - bounceStart) / (crate.land - bounceStart) * 1.3 - 0.3))
	end
	scale = math.max(scale, 0.02)

	-- Turn about the (scaled) box's middle and rest it on the surface below the path point,
	-- so it rises onto an edge mid-tumble and lies flat on any face.
	local half = crate.half
	local upLocal = rot:VectorToObjectSpace(UP)
	local support = scale * (math.abs(upLocal.X) * half.X + math.abs(upLocal.Y) * half.Y + math.abs(upLocal.Z) * half.Z)
	local surfaceY = pos.Y + crate.bottom
	local midLocal = (crate.mid - crate.bottom) * scale + crate.bottom
	local centre = Vector3.new(pos.X, surfaceY + support, pos.Z)
	return CFrame.new(centre) * rot * CFrame.new(0, -midLocal, 0), scale
end

-- The Chad standing at the crate's Origin, if it is one of this plot's units.
local function sourceUnit(model: Model): Model?
	local origin = model:GetAttribute("Origin")
	local plot = model.Parent and model.Parent.Parent
	local units = plot and plot:FindFirstChild("Units")
	if typeof(origin) ~= "Vector3" or not units then
		return nil
	end
	local best, bestDist = nil, 2
	for _, unit in units:GetChildren() do
		if unit:IsA("Model") then
			local d = (unit:GetPivot().Position - origin).Magnitude
			if d < bestDist then
				best, bestDist = unit, d
			end
		end
	end
	return best
end

-- Spawn / idle --------------------------------------------------------------------------

local function thud(crate: Crate, floor: Vector3, k: number)
	local size = (1 + crate.rank * 0.25) * k
	Orbs.ring(floor + Vector3.new(0, 0.12, 0), Color3.fromRGB(235, 225, 210), 4.5 * size, 0.45, 0.3)
	Orbs.ring(floor + Vector3.new(0, 0.18, 0), crate.color, 3 * size, 0.5, 0.1)
	smokePuff(floor + Vector3.new(0, 0.3, 0), math.floor((8 + crate.rank * 2) * k), 9 * k)
	Sounds.play("CrateShake", 0.08, 0.7 - crate.rank * 0.03)
	if k >= 1 then
		Orbs.sparkle(floor + Vector3.new(0, 1.5, 0), crate.color, 10 + crate.rank * 3, 0.9 + crate.rank * 0.1)
		if crate.rank >= 2 then
			Sounds.play("OrbLand", 0.05, 0.5)
			if playerNear(floor, 70) then
				Camera.shake(0.04 + crate.rank * 0.04, 0.2)
			end
		end
	end
end

local function stepCrate(crate: Crate, now: number)
	local base = crate.base
	local t = now - crate.born
	local floor = base.Position + Vector3.new(0, crate.bottom, 0)
	local rank = crate.rank

	if t < crate.land then
		if not crate.shown then
			crate.shown = true
			setShown(crate, true, false)
			local start = crate.legs[1].from
			smokePuff(start, 6, 6)
			Sounds.play("Tick", 0.1, 0.6 + rank * 0.1)
			if crate.source then
				Animator.show(crate.source, nil, 0.8, 0.6)
			end
		end
		local last = crate.legs[#crate.legs]
		if not crate.bounced and t >= last.t0 then
			crate.bounced = true
			thud(crate, last.from + Vector3.new(0, crate.bottom, 0), 0.5)
		end
		local cf, s = sampleArrival(crate, t)
		place(crate, cf, s, s)
		return
	end
	if not crate.landed then
		crate.landed = true
		setShown(crate, true, true)
		thud(crate, floor, 1)
	end
	local q = t - crate.land
	local idleT = now + crate.phase
	-- Idle motion fades in after the landing so the two blend.
	local blend = smooth((q - SQUASH * 0.5) / 0.6)
	local amp = 0.15 + rank * 0.07
	local lift = amp * (0.5 - 0.5 * math.cos(idleT * 2.2)) * blend
	local yaw = (idleT * (0.3 + rank * 0.08)) % (math.pi * 2)
	local sway = math.sin(idleT * 1.6) * (0.03 + rank * 0.01) * blend
	-- "Can't" wiggle: the player stands in pickup range but already holds a crate.
	if q > SQUASH and now - crate.wiggleAt >= CratePickup.WIGGLE_GAP and holdingCrate() then
		local root = localRoot()
		local offset = root and base.Position - root.Position
		if offset and CratePickup.inRange(offset.X, offset.Y, offset.Z) then
			crate.wiggleAt = now
			Sounds.play("Tick", 0.06, 0.45)
		end
	end
	local w = now - crate.wiggleAt
	local wiggle = if w < WIGGLE then math.sin(w / WIGGLE * math.pi * 4) * 0.14 * (1 - w / WIGGLE) else 0
	local cf = base * CFrame.new(0, lift, 0) * CFrame.Angles(0, yaw * blend, 0) * CFrame.Angles(sway, 0, sway * 0.6 + wiggle)
	if q < SQUASH then
		-- Damped spring: squash flat on impact, overshoot tall, settle.
		local sy = 1 - 0.34 * math.exp(-6 * q) * math.cos(q * 16)
		place(crate, cf, 1 / math.sqrt(sy), sy)
	else
		place(crate, cf, 1, 1)
	end

	-- Soft ground disc, gently pulsing, sized by rarity.
	local pulse = 0.5 + 0.5 * math.sin(now * (1.6 + rank * 0.35) + crate.phase)
	local landIn = math.clamp(q / 0.3, 0, 1)
	local radius = (2.2 + rank * 0.35) * (1 + 0.08 * pulse - lift * 0.15) * backOut(landIn)
	crate.disc.Size = Vector3.new(0.05, math.max(radius * 2, 0.05), math.max(radius * 2, 0.05))
	crate.disc.CFrame = CFrame.new(floor + Vector3.new(0, 0.07, 0)) * UPRIGHT
	local quiet = if rank == 0 then 0.82 else 0.7 - rank * 0.06
	crate.disc.Transparency = math.clamp(quiet - 0.12 * pulse, 0.35, 0.95)
end

local function step()
	if crateCount == 0 then
		return
	end
	local now = os.clock()
	table.clear(moveParts)
	table.clear(moveCFrames)
	for model, crate in crates do
		if not model.Parent or crate.broken then
			continue
		end
		local intro = now - crate.born < crate.land + SQUASH + 0.6
		if not intro and not nearCamera(crate.base.Position, CULL) then
			continue
		end
		local ok, err = pcall(stepCrate, crate, now)
		if not ok then
			warn("[Fx.Crates] " .. tostring(err))
			crate.broken = true
			-- Leave it in place: back on its spot, full size, label live.
			table.clear(moveParts)
			table.clear(moveCFrames)
			crate.restored = false
			place(crate, crate.base, 1, 1)
			setShown(crate, true, true)
		end
	end
	if #moveParts > 0 then
		Workspace:BulkMoveTo(moveParts, moveCFrames, Enum.BulkMoveMode.FireCFrameChanged)
	end
	scanChips(now)
end

-- Tracking ------------------------------------------------------------------------------

local function track(model: Instance, intro: boolean)
	if not model:IsA("Model") or crates[model] or crateCount >= MAX_CRATES then
		return
	end
	local primary = model.PrimaryPart or model:FindFirstChildWhichIsA("BasePart")
	if not primary then
		return
	end
	local base = model:GetPivot()
	local parts: { BasePart } = {}
	local offsets: { CFrame } = {}
	local sizes: { Vector3 } = {}
	local bottom = 0
	local hx, hz, top = 0, 0, 0
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then
			table.insert(parts, d)
			local offset = base:ToObjectSpace(d.CFrame)
			table.insert(offsets, offset)
			table.insert(sizes, d.Size)
			bottom = math.min(bottom, offset.Y - d.Size.Y / 2)
			top = math.max(top, offset.Y + d.Size.Y / 2)
			hx = math.max(hx, math.abs(offset.X) + d.Size.X / 2)
			hz = math.max(hz, math.abs(offset.Z) + d.Size.Z / 2)
		end
	end
	if #parts == 0 then
		return
	end
	local rarity = rarityOf(model)
	local rank = rankOf(rarity)
	local color = (Theme.Colors.Rarity and Theme.Colors.Rarity[rarity]) or WHITE
	local disc = fxPart(Enum.PartType.Cylinder, "CrateGlow", color)
	disc.Transparency = 1
	local primaryY = base:ToObjectSpace(primary.CFrame).Y
	local chip = makeChip(rarity, color, primary, top - primaryY + 0.75, disc)
	local legs, land = buildLegs(readRoute(model), base.Position)
	local crate: Crate = {
		model = model,
		base = base,
		parts = parts,
		offsets = offsets,
		sizes = sizes,
		bottom = bottom,
		half = Vector3.new(hx, (top - bottom) / 2, hz),
		mid = (top + bottom) / 2,
		rarity = rarity,
		rank = rank,
		color = color,
		born = if intro then os.clock() else os.clock() - land - 10,
		land = land,
		legs = legs,
		bounced = not intro,
		source = if intro then sourceUnit(model) else nil,
		wiggleAt = -math.huge,
		phase = math.random() * 10,
		disc = disc,
		chip = chip,
		chipOn = false,
		chipToken = 0,
		shown = not intro,
		landed = not intro,
		restored = true,
		broken = false,
	}
	if intro then
		setShown(crate, false, false)
	end
	crates[model] = crate
	crateCount += 1
end

local function untrack(model: Instance)
	local crate = crates[model :: Model]
	if not crate then
		return
	end
	crates[model :: Model] = nil
	crateCount -= 1
	local floor = crate.base.Position + Vector3.new(0, crate.bottom, 0)
	fadeChip(crate, false)
	-- Pickup puff where it stood; the disc shrinks away.
	Orbs.sparkle(floor + Vector3.new(0, 1.5, 0), crate.color, 14, 0.8)
	Orbs.ring(floor + Vector3.new(0, 0.15, 0), crate.color, 3, 0.35, 0.2)
	local disc = crate.disc
	TweenService:Create(disc, TweenInfo.new(0.25, Enum.EasingStyle.Back, Enum.EasingDirection.In), {
		Size = Vector3.new(0.05, 0.05, 0.05),
		Transparency = 1,
	}):Play()
	task.delay(0.3, function()
		disc:Destroy()
	end)
end

local boundFolder: Instance? = nil
local folderConns: { RBXScriptConnection } = {}

local function bindFolder(f: Instance)
	if f == boundFolder then
		return
	end
	boundFolder = f
	for _, conn in folderConns do
		conn:Disconnect()
	end
	table.clear(folderConns)
	for model in crates do
		untrack(model)
	end
	for _, child in f:GetChildren() do
		track(child, false)
	end
	table.insert(
		folderConns,
		f.ChildAdded:Connect(function(child)
			-- Let the whole model replicate before capturing its parts.
			task.defer(track, child, true)
		end)
	)
	table.insert(folderConns, f.ChildRemoved:Connect(untrack))
end

local function refresh()
	local data = State.data
	local map = Workspace:FindFirstChild("Map")
	if not data or not map or not data.plotIndex then
		return
	end
	local plot = map:FindFirstChild("Plot" .. tostring(data.plotIndex))
	if not plot then
		return
	end
	local f = plot:FindFirstChild("Chests")
	if f then
		bindFolder(f)
	end
end

function Crates.init()
	if started then
		return
	end
	started = true
	RunService.Heartbeat:Connect(step)
	State.changed.Event:Connect(refresh)
	refresh()
end

return Crates
