--!strict
--[[
	Fx.Modes: the client side of the GAME MODES plaza and the Parkour course.

	  Movers       every "ModeMover" root (and its descendant parts) is posed each frame
	               from its attributes and workspace:GetServerTimeNow(), so all clients
	               agree (contract in Server.World.Modes). Only movers near the local
	               player animate; nothing runs while the player is far from the course.
	  Carry        while the character stands on a moving part (short downward raycast
	               against mover parts), the part's frame-to-frame motion (delta CFrame,
	               rotation included) is applied to the character's root before physics.
	  Spinners     "SpinnerBar" (Hazard = "bump"): a gentle push away plus a small hop.
	  Blink pads   tag "BlinkPad": solid when ((t + BlinkPhase) % BlinkPeriod) < BlinkOn
	               (server clock). Near the player, CanCollide and the look are set locally
	               (character physics is client-owned): faded when off, with a few quick
	               flashes in the last BLINK_WARN seconds before switching off.
	  Bounce pads  tag "BouncePad": once per contact, launch upward at the pad's Bounce
	               speed (double jump still works in the air), squash the pad, Puff sprite.
	  Effects      ModeCheckpoint (flag cap pop + star), ModeSplash (splash sprites and
	               a short camera dip), ModeFinish (stars and confetti).
	  Levels       a parkour run's start payload carries its level; hints and flags look in
	               Map.GameModes.Parkour.Level<level>. Mode notifications of other modes
	               (Mog Test) are ignored.
	  Hint         standing still for 4 s during a run: a short dotted trail of soft dots
	               toward the next checkpoint (or the finish).
	  Gate arrow   each open gate's "GateArrow" (tag "ModeHintArrow", attribute HintBob)
	               bobs gently while the player is near the plaza and not on a run; it
	               eases in and out and settles back at its rest pose.
	  Next flag    during a run, the next checkpoint's "FlagCap" (attribute Checkpoint)
	               gives a soft pulse with a sunny ring every couple of seconds.
	  Budget       on "low" devices (Fx.Budget) movers farther than LOW_FAR studs from
	               the player pose every 2nd frame; celebration confetti / splash dots
	               scale with Budget.count. Hints, pads and nearby movers never thin out.
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Net = require(ReplicatedStorage.Shared.Net)
local Sprites = require(script.Parent.Sprites)
local Budget = require(script.Parent.Budget)

local ModesFx = {}

local player = Players.LocalPlayer
local W = (require(ReplicatedStorage:WaitForChild("Theme")) :: any).World

-- Movers further than this from the player stay put; nothing runs beyond FAR of every mover.
local NEAR = 220
local LOW_FAR = 80 -- studs: on a "low" device movers past this pose every 2nd frame
local stepFrame = 0
local TAU = 2 * math.pi
local BUMP_COOLDOWN = 0.7
local STILL_FOR = 4
local HINT_EVERY = 8
-- Gate arrow: bobs within ARROW_NEAR studs, ARROW_SPEED rad/s, fading in/out over ARROW_FADE s.
local ARROW_NEAR = 90
local ARROW_SPEED = 2.6
local ARROW_FADE = 0.4
-- Next checkpoint flag: one soft pulse every PULSE_EVERY seconds during a run.
local PULSE_EVERY = 2.2
-- Blink pads: seconds of warning flashes before switching off, and flashes per second.
local BLINK_WARN = 0.5
local BLINK_FLASH_HZ = 6
local BLINK_OFF_TOP = 0.75
local BLINK_OFF_PART = 0.85

type Mover = {
	root: BasePart,
	rest: CFrame,
	parts: { BasePart },
	offsets: { CFrame }, -- each part relative to the root at rest
	kind: string,
	axis: Vector3,
	distance: number,
	period: number,
	speed: number,
	phase: number,
	current: CFrame,
	live: boolean, -- posed last frame (its delta is safe to carry)
	hazard: boolean,
	length: number,
}

local movers: { Mover } = {}
local byPart: { [BasePart]: Mover } = {}
local floorParts: { Instance } = {}
local pads: { BasePart } = {}
local padRest: { [BasePart]: CFrame } = {}
local padContact: { [BasePart]: boolean } = {}
local bounds: { min: Vector3, max: Vector3 }? = nil

type Blink = {
	root: BasePart,
	centre: Vector3,
	on: number,
	period: number,
	phase: number,
	solid: { BasePart }, -- parts that collide while the pad is on
	looks: { BasePart }, -- every visible part, with its built transparency
	rest: { number },
	glow: { BasePart },
	state: string, -- "on" | "dim" (warning flash) | "off" | "" (not applied yet)
}
local blinks: { Blink } = {}
local blinkByPart: { [BasePart]: boolean } = {}

type Arrow = {
	root: BasePart,
	parts: { BasePart },
	rest: { CFrame },
	bob: number,
	fade: number, -- 0..1, eased into the bob amplitude
}
local arrows: { Arrow } = {}
-- Rest sizes of flag caps (pulses and pops always tween back to these).
local capRest: { [BasePart]: Vector3 } = {}

local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Include

local function num(value: any, default: number): number
	return if type(value) == "number" then value else default
end

local function grow(point: Vector3)
	local b = bounds
	if b then
		b.min = b.min:Min(point)
		b.max = b.max:Max(point)
	else
		bounds = { min = point, max = point }
	end
end

local function poseAt(m: Mover, t: number): CFrame
	if m.kind == "spin" then
		-- Wrapped in double precision first: CFrame.Angles works in float32, and t is ~1.7e9.
		local angle = (m.speed * t + m.phase) % TAU
		return CFrame.new(m.rest.Position) * CFrame.Angles(0, angle, 0) * m.rest.Rotation
	end
	return m.rest + m.axis * (m.distance * math.sin(TAU * t / m.period + m.phase))
end

local function addMover(root: Instance)
	if not root:IsA("BasePart") or byPart[root] then
		return
	end
	local axis = root:GetAttribute("MoveAxis")
	local m: Mover = {
		root = root,
		rest = root.CFrame,
		parts = { root },
		offsets = { CFrame.identity },
		kind = tostring(root:GetAttribute("Mover") or "slide"),
		axis = if typeof(axis) == "Vector3" and axis.Magnitude > 0 then axis.Unit else Vector3.yAxis,
		distance = num(root:GetAttribute("MoveDistance"), 0),
		period = math.max(num(root:GetAttribute("MovePeriod"), 4), 0.2),
		speed = num(root:GetAttribute("MoveSpeed"), 0),
		phase = num(root:GetAttribute("MovePhase"), 0),
		current = root.CFrame,
		live = false,
		hazard = root:GetAttribute("Hazard") == "bump",
		length = root.Size.X,
	}
	for _, d in root:GetDescendants() do
		if d:IsA("BasePart") then
			table.insert(m.parts, d)
			table.insert(m.offsets, m.rest:ToObjectSpace(d.CFrame))
		end
	end
	for _, part in m.parts do
		byPart[part] = m
		if part.CanCollide and part.CanQuery then
			table.insert(floorParts, part)
		end
	end
	rayParams.FilterDescendantsInstances = floorParts
	table.insert(movers, m)
	grow(m.rest.Position)
end

local function addPad(pad: Instance)
	if pad:IsA("BasePart") and not padRest[pad] then
		padRest[pad] = pad.CFrame
		table.insert(pads, pad)
		grow(pad.Position)
	end
end

local function addBlink(root: Instance)
	if not root:IsA("BasePart") or blinkByPart[root] then
		return
	end
	blinkByPart[root] = true
	local b: Blink = {
		root = root,
		centre = root.Position,
		on = num(root:GetAttribute("BlinkOn"), 2),
		period = math.max(num(root:GetAttribute("BlinkPeriod"), 3), 0.2),
		phase = num(root:GetAttribute("BlinkPhase"), 0),
		solid = {},
		looks = {},
		rest = {},
		glow = {},
		state = "",
	}
	local all = root:GetDescendants()
	table.insert(all, root)
	for _, d in all do
		if d:IsA("BasePart") then
			if d.CanCollide then
				table.insert(b.solid, d)
			end
			if d.Name == "BlinkGlow" then
				table.insert(b.glow, d)
			elseif d.Transparency < 1 then
				table.insert(b.looks, d)
				table.insert(b.rest, d.Transparency)
			end
		end
	end
	table.insert(blinks, b)
	grow(root.Position)
end

-- Applies a blink pad's state: "on" (solid, full colour), "dim" (solid, warning flash
-- frame) or "off" (non-collidable and faded, glow dim).
local function setBlink(b: Blink, state: string)
	if b.state == state then
		return
	end
	b.state = state
	local collide = state ~= "off"
	for _, part in b.solid do
		part.CanCollide = collide
	end
	for i, part in b.looks do
		part.Transparency = if state == "off"
			then (if part == b.root then BLINK_OFF_TOP else BLINK_OFF_PART)
			elseif state == "dim" then math.max(b.rest[i], 0.4)
			else b.rest[i]
	end
	for _, glow in b.glow do
		glow.Transparency = if state == "on" then 0 elseif state == "dim" then 0.6 else 0.85
	end
end

local function blinkState(b: Blink, t: number): string
	local into = (t + b.phase) % b.period
	if into >= b.on then
		return "off"
	end
	local left = b.on - into
	if left < BLINK_WARN and math.floor(left * BLINK_FLASH_HZ * 2) % 2 == 0 then
		return "dim"
	end
	return "on"
end

local function addArrow(root: Instance)
	if not root:IsA("BasePart") then
		return
	end
	for _, a in arrows do
		if a.root == root then
			return
		end
	end
	local arrow: Arrow = { root = root, parts = { root }, rest = { root.CFrame }, bob = num(root:GetAttribute("HintBob"), 0.8), fade = 0 }
	for _, d in root:GetDescendants() do
		if d:IsA("BasePart") then
			table.insert(arrow.parts, d)
			table.insert(arrow.rest, d.CFrame)
		end
	end
	table.insert(arrows, arrow)
end

local function restSize(cap: BasePart): Vector3
	local size = capRest[cap]
	if not size then
		size = cap.Size
		capRest[cap] = size
	end
	return size
end

-- A throwaway invisible anchor for world sprites.
local function anchorAt(position: Vector3, life: number): BasePart
	local part = Instance.new("Part")
	part.Name = "ModesFxAnchor"
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Transparency = 1
	part.Size = Vector3.one * 0.2
	part.CFrame = CFrame.new(position)
	part.Parent = Workspace
	task.delay(life, function()
		part:Destroy()
	end)
	return part
end

local function character(): (Humanoid?, BasePart?)
	local char = player.Character
	if not char then
		return nil, nil
	end
	local humanoid = char:FindFirstChildOfClass("Humanoid")
	local root = char:FindFirstChild("HumanoidRootPart")
	if humanoid and humanoid.Health > 0 and root and root:IsA("BasePart") then
		return humanoid, root
	end
	return nil, nil
end

local function feetY(humanoid: Humanoid, root: BasePart): number
	return root.Position.Y - root.Size.Y / 2 - humanoid.HipHeight
end

-- Spinner bump: away from the bar, along its sweep, and a small hop. Never a fling.
local lastBump = 0
local function bump(m: Mover, humanoid: Humanoid, root: BasePart, closest: Vector3)
	local now = os.clock()
	if now - lastBump < BUMP_COOLDOWN then
		return
	end
	lastBump = now
	local away = root.Position - closest
	away = Vector3.new(away.X, 0, away.Z)
	local radial = Vector3.new(closest.X - m.rest.Position.X, 0, closest.Z - m.rest.Position.Z)
	local sweep = if radial.Magnitude > 0.01 then Vector3.yAxis:Cross(radial).Unit * math.sign(m.speed) else Vector3.zero
	local push = (if away.Magnitude > 0.01 then away.Unit else sweep) + sweep * 0.6
	push = if push.Magnitude > 0.01 then push.Unit else Vector3.xAxis
	humanoid:ChangeState(Enum.HumanoidStateType.Jumping)
	root.AssemblyLinearVelocity = push * 26 + Vector3.new(0, 24, 0)
	Sprites.billboard(anchorAt(closest, 2), "Puff", { position = closest, size = 2.2, life = 0.6, rise = Vector3.new(0, 1, 0) })
end

local function launch(pad: BasePart, humanoid: Humanoid, root: BasePart)
	local speed = num(pad:GetAttribute("Bounce"), 78)
	humanoid:ChangeState(Enum.HumanoidStateType.Jumping)
	local v = root.AssemblyLinearVelocity
	root.AssemblyLinearVelocity = Vector3.new(v.X, speed, v.Z)
	local rest = padRest[pad]
	pad.CFrame = rest - Vector3.new(0, 0.35, 0)
	TweenService:Create(pad, TweenInfo.new(0.3, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { CFrame = rest }):Play()
	local top = rest.Position + Vector3.new(0, 0.6, 0)
	Sprites.billboard(anchorAt(top, 2), "Puff", { position = top, size = 3.5, life = 0.7, rise = Vector3.new(0, 0.6, 0) })
	Sprites.billboard(anchorAt(top, 2), "Ring", { position = top, size = 4, life = 0.5, rise = Vector3.zero, color = W.Sunny })
end

-- Run state (from the "Mode" notifies) for the still-player hint.
local running = false
local nextIndex = 1
local stillSince = os.clock()
local stillAt = Vector3.zero
local lastHint = 0
local currentLevel = 1

-- The current (or last) run's level folder, Map.GameModes.Parkour.Level<currentLevel>.
local function courseFolder(): Instance?
	local map = Workspace:FindFirstChild("Map")
	local modes = map and map:FindFirstChild("GameModes")
	local parkour = modes and modes:FindFirstChild("Parkour")
	return parkour and parkour:FindFirstChild("Level" .. currentLevel)
end

local function checkpointPart(index: number): BasePart?
	local folder = courseFolder()
	if not folder then
		return nil
	end
	for _, d in folder:GetDescendants() do
		if
			d.Name == "Checkpoint"
			and d:IsA("BasePart")
			and d:GetAttribute("Index") == index
			and d:GetAttribute("Level") == currentLevel
		then
			return d
		end
	end
	for _, d in folder:GetDescendants() do
		if d.Name == "ParkourFinish" and d:IsA("BasePart") and d:GetAttribute("Level") == currentLevel then
			return d
		end
	end
	return nil
end

local function showHint(root: BasePart)
	local target = checkpointPart(nextIndex)
	if not target then
		return
	end
	local from = root.Position - Vector3.new(0, 1.5, 0)
	local to = target.Position + Vector3.new(0, 1.5, 0)
	local offset = to - from
	local steps = 7
	local reach = math.min(offset.Magnitude, 18)
	if reach < 3 then
		return
	end
	local anchor = anchorAt(from, 4)
	for i = 1, steps do
		local point = from + offset.Unit * (reach * i / steps)
		Sprites.billboard(anchor, "SoftDot", {
			position = point,
			size = 0.9,
			life = 1.6,
			delay = i * 0.09,
			rise = Vector3.new(0, 0.4, 0),
			color = W.Sunny,
		})
	end
end

-- The open gate's arrow bobs near the plaza while no run is on; it eases to rest otherwise.
local function bobArrows(pos: Vector3, dt: number)
	local t = os.clock()
	local parts: { BasePart } = {}
	local frames: { CFrame } = {}
	for i = #arrows, 1, -1 do
		local a = arrows[i]
		if not a.root:IsDescendantOf(Workspace) then
			table.remove(arrows, i)
			continue
		end
		local want = not running and (a.rest[1].Position - pos).Magnitude < ARROW_NEAR
		local before = a.fade
		a.fade = math.clamp(a.fade + (if want then dt else -dt) / ARROW_FADE, 0, 1)
		if a.fade > 0 or before > 0 then
			local eased = a.fade * a.fade * (3 - 2 * a.fade)
			local lift = Vector3.new(0, a.bob * eased * math.sin(t * ARROW_SPEED), 0)
			for k, part in a.parts do
				table.insert(parts, part)
				table.insert(frames, a.rest[k] + lift)
			end
		end
	end
	if #parts > 0 then
		Workspace:BulkMoveTo(parts, frames, Enum.BulkMoveMode.FireCFrameChanged)
	end
end

-- Next-checkpoint flag pulse during a run.
local pulseIndex = 0
local pulseCap: BasePart? = nil
local lastPulse = 0
local function pulseNextFlag()
	local now = os.clock()
	if not running or now - lastPulse < PULSE_EVERY then
		return
	end
	lastPulse = now
	local cap = pulseCap
	if pulseIndex ~= nextIndex or not cap or not cap:IsDescendantOf(Workspace) then
		cap = nil
		local folder = courseFolder()
		if folder then
			for _, d in folder:GetDescendants() do
				if d.Name == "FlagCap" and d:IsA("BasePart") and d:GetAttribute("Checkpoint") == nextIndex then
					cap = d
					break
				end
			end
		end
		pulseIndex, pulseCap = nextIndex, cap
	end
	if not cap then
		return
	end
	local size = restSize(cap)
	cap.Size = size
	TweenService:Create(cap, TweenInfo.new(0.4, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, 0, true), { Size = size * 1.3 }):Play()
	local at = cap.Position
	Sprites.billboard(
		anchorAt(at, 2),
		"Ring",
		{ position = at, size = 3.6, life = 0.9, rise = Vector3.zero, color = W.Sunny, maxDistance = 160 }
	)
end

-- Map scenery and themed ambience -------------------------------------------------------
--
-- Scenery tags from the world builder (docs/parkour-maps.md), animated locally with
-- os.clock() (pure decoration, so clients need not agree) and only within MAP_NEAR studs:
--   MapBubble     rises at its Rise studs/s with a soft sway, fades out near Top and back in
--                 at its rest y.
--   MapBob        a buoy root: bobs BOB_HEIGHT studs and tilts a few degrees; every
--                 descendant part moves rigidly with it (BulkMoveTo, like the movers).
--   MapLightning  a neon bolt: hidden (Transparency 1), flashing in 2-3 pulse bursts every
--                 4-9 s (own random timer per bolt).
--   MapGlow       a neon part whose colour slowly breathes between dimmer and brighter.
-- Which items are near is refreshed MAP_REFRESH times a second into reused lists; items
-- that drift out of range go back to their rest look. Nothing runs when none are near.
--
-- Ambience: on a run's start the Level folder's Theme attribute picks a look, eased in over
-- AMBIENCE_FADE s and out again on finish / invalid / stop, on respawn, and after OUT_GRACE s
-- outside the level's bounds. A start while a look is up cross-fades to the new one.
--   beach / cove / bay / reef / bubble / coral / shark  a light ParkourGrade tint plus a
--            touch of Ambient, fog and Atmosphere colour (sunny warm, teal-green, dusk,
--            aqua-purple, pale mint, sunset peach, steel blue).
--   storm    ParkourGrade (ColorCorrectionEffect): cool, darker, desaturated; darker
--            Ambient / OutdoorAmbient, nearer greyer fog, denser greyer Atmosphere; the
--            grade flashes brighter while a bolt near the player is lit.
--   volcano  ParkourGrade warm tint, a warm Atmosphere touch, ember emitters (ParkourEmbers,
--            made lazily) on the level's MapGlow parts, enabled only during the run.
--   giga     soft gold sparkles around the player's root (attachment ParkourSparkles).
-- ParkourGrade is our own instance: Fx.Surge's SurgeGrade is separate and the two stack.
-- Every Lighting / Atmosphere value is saved when a look starts and written back exactly.

local Lighting = game:GetService("Lighting")

local MAP_NEAR = 250
local MAP_REFRESH = 0.25
local BOB_HEIGHT = 0.6
local BOB_TILT = math.rad(4)
local BUBBLE_SWAY = 0.5
local BUBBLE_FADE = 1.5 -- studs at each end of the climb over which a bubble fades
local GLOW_STEP = 1 / 15 -- glow colour updates per second cap
local BOLT_PULSE = 0.16 -- seconds per flash pulse (lit for the first BOLT_LIT of it)
local BOLT_LIT = 0.07
local AMBIENCE_FADE = 1
local OUT_GRACE = 3
local EMBER_RATE = 4
local SPARKLE_RATE = 6
local WHITE = Color3.new(1, 1, 1)

type Bubble = {
	part: BasePart,
	rest: Vector3,
	rot: CFrame,
	alpha: number, -- built transparency
	rise: number,
	span: number,
	phase: number, -- studs into the climb at t = 0
	live: boolean,
}
type Bob = {
	part: BasePart,
	rest: CFrame,
	parts: { BasePart }?, -- root first, gathered the first time it comes near
	offsets: { CFrame },
	phase: number,
	speed: number,
	live: boolean,
}
type Bolt = { part: BasePart, nextAt: number, start: number, pulses: number, lit: boolean, live: boolean }
type Glow = { part: BasePart, base: Color3, dim: Color3, bright: Color3, phase: number, speed: number, live: boolean }

local bubbles: { Bubble } = {}
local bobs: { Bob } = {}
local bolts: { Bolt } = {}
local glows: { Glow } = {}
local nearBubbles: { Bubble } = {}
local nearBobs: { Bob } = {}
local nearBolts: { Bolt } = {}
local nearGlows: { Glow } = {}
local mapTracked: { [Instance]: boolean } = {}
local moveParts: { BasePart } = {}
local moveFrames: { CFrame } = {}
local nextRefresh = 0
local nextGlow = 0
local boltLit = false -- some bolt near the player is lit this frame

local function addBubble(part: Instance)
	if not part:IsA("BasePart") or mapTracked[part] then
		return
	end
	local rise = num(part:GetAttribute("Rise"), 2)
	local span = num(part:GetAttribute("Top"), part.Position.Y + 12) - part.Position.Y
	if rise <= 0 or span < 1 then
		return
	end
	mapTracked[part] = true
	table.insert(bubbles, {
		part = part,
		rest = part.Position,
		rot = part.CFrame.Rotation,
		alpha = part.Transparency,
		rise = rise,
		span = span,
		phase = math.random() * span,
		live = false,
	})
end

local function addBob(part: Instance)
	if not part:IsA("BasePart") or mapTracked[part] then
		return
	end
	mapTracked[part] = true
	table.insert(bobs, {
		part = part,
		rest = part.CFrame,
		parts = nil,
		offsets = {},
		phase = math.random() * TAU,
		speed = 1.1 + math.random() * 0.5,
		live = false,
	})
end

local function addBolt(part: Instance)
	if not part:IsA("BasePart") or mapTracked[part] then
		return
	end
	mapTracked[part] = true
	part.Transparency = 1
	table.insert(bolts, { part = part, nextAt = os.clock() + math.random() * 9, start = -1, pulses = 0, lit = false, live = false })
end

local function addGlow(part: Instance)
	if not part:IsA("BasePart") or mapTracked[part] then
		return
	end
	mapTracked[part] = true
	local base = part.Color
	local h, s, v = base:ToHSV()
	table.insert(glows, {
		part = part,
		base = base,
		dim = Color3.fromHSV(h, s, v * 0.62),
		bright = Color3.fromHSV(h, s * 0.8, math.min(1, v * 1.15)),
		phase = math.random() * TAU,
		speed = TAU / (2.6 + math.random() * 1.6),
		live = false,
	})
end

-- Drops a removed (or streamed-out) instance from a scenery list and its near list.
local function dropFrom(list: { any }, near: { any }, inst: Instance)
	if not mapTracked[inst] then
		return
	end
	for i = #list, 1, -1 do
		if list[i].part == inst then
			table.remove(list, i)
		end
	end
	for i = #near, 1, -1 do
		if near[i].part == inst then
			table.remove(near, i)
		end
	end
	mapTracked[inst] = nil
end

-- Back to the built look when an item leaves the player's range.
local function restBubble(b: Bubble)
	b.part.CFrame = CFrame.new(b.rest) * b.rot
	b.part.Transparency = b.alpha
end

local function restBob(b: Bob)
	local parts = b.parts
	if parts then
		for i, part in parts do
			table.insert(moveParts, part)
			table.insert(moveFrames, b.rest * b.offsets[i])
		end
	end
end

local function restBolt(b: Bolt)
	b.part.Transparency = 1
	b.lit = false
	b.start = -1
end

local function refreshNear(pos: Vector3)
	table.clear(nearBubbles)
	table.clear(nearBobs)
	table.clear(nearBolts)
	table.clear(nearGlows)
	for _, b in bubbles do
		local near = (b.rest - pos).Magnitude <= MAP_NEAR
		if near then
			table.insert(nearBubbles, b)
		elseif b.live then
			restBubble(b)
		end
		b.live = near
	end
	for _, b in bobs do
		local near = (b.rest.Position - pos).Magnitude <= MAP_NEAR
		if near then
			if not b.parts then
				local parts = { b.part }
				b.offsets = { CFrame.identity }
				for _, d in b.part:GetDescendants() do
					if d:IsA("BasePart") then
						table.insert(parts, d)
						table.insert(b.offsets, b.rest:ToObjectSpace(d.CFrame))
					end
				end
				b.parts = parts
			end
			table.insert(nearBobs, b)
		elseif b.live then
			restBob(b)
		end
		b.live = near
	end
	for _, b in bolts do
		local near = (b.part.Position - pos).Magnitude <= MAP_NEAR
		if near then
			table.insert(nearBolts, b)
		elseif b.live then
			restBolt(b)
		end
		b.live = near
	end
	for _, g in glows do
		local near = (g.part.Position - pos).Magnitude <= MAP_NEAR
		if near then
			table.insert(nearGlows, g)
		elseif g.live then
			g.part.Color = g.base
		end
		g.live = near
	end
end

local function stepScenery(pos: Vector3)
	local now = os.clock()
	if now >= nextRefresh then
		nextRefresh = now + MAP_REFRESH
		refreshNear(pos)
	end
	boltLit = false
	for _, b in nearBubbles do
		local travel = (now * b.rise + b.phase) % b.span
		local sway = now * 1.3 + b.phase
		b.part.Transparency = 1 - (1 - b.alpha) * math.clamp(math.min(travel, b.span - travel) / BUBBLE_FADE, 0, 1)
		table.insert(moveParts, b.part)
		table.insert(
			moveFrames,
			CFrame.new(b.rest.X + BUBBLE_SWAY * math.sin(sway), b.rest.Y + travel, b.rest.Z + BUBBLE_SWAY * math.cos(sway * 0.8)) * b.rot
		)
	end
	for _, b in nearBobs do
		local parts = b.parts
		if parts then
			local a = now * b.speed + b.phase
			local p = b.rest.Position
			local pose = CFrame.new(p.X, p.Y + BOB_HEIGHT * math.sin(a), p.Z)
				* CFrame.Angles(BOB_TILT * math.sin(a * 0.8 + 1), 0, BOB_TILT * math.cos(a * 0.7))
				* b.rest.Rotation
			for i, part in parts do
				table.insert(moveParts, part)
				table.insert(moveFrames, pose * b.offsets[i])
			end
		end
	end
	if #moveParts > 0 then
		Workspace:BulkMoveTo(moveParts, moveFrames, Enum.BulkMoveMode.FireCFrameChanged)
		table.clear(moveParts)
		table.clear(moveFrames)
	end
	for _, b in nearBolts do
		local lit = false
		if b.start < 0 and now >= b.nextAt then
			b.start, b.pulses = now, math.random(2, 3)
		end
		if b.start >= 0 then
			local into = (now - b.start) / BOLT_PULSE
			local pulse = math.floor(into)
			if pulse >= b.pulses then
				b.start = -1
				b.nextAt = now + 4 + math.random() * 5
			else
				lit = (into - pulse) * BOLT_PULSE < BOLT_LIT
			end
		end
		if lit ~= b.lit then
			b.lit = lit
			b.part.Transparency = if lit then 0 else 1
		end
		boltLit = boltLit or lit
	end
	if #nearGlows > 0 and now >= nextGlow then
		nextGlow = now + GLOW_STEP
		for _, g in nearGlows do
			g.part.Color = g.dim:Lerp(g.bright, 0.5 + 0.5 * math.sin(now * g.speed + g.phase))
		end
	end
end

type Look = {
	tint: Color3,
	brightness: number,
	contrast: number,
	saturation: number,
	ambient: Color3,
	ambientMix: number,
	fog: Color3,
	fogMix: number,
	fogEnd: number, -- fog never ends further than this while the look is up
	atmosphere: Color3,
	atmosphereMix: number,
	density: number, -- added to the Atmosphere's density
	haze: number, -- added to its haze
	flash: number, -- grade brightness added while a near bolt is lit
}

-- Every look is mild except storm / volcano: tints stay within ~0.85-1 per channel,
-- saturation within +-0.15 and brightness within +-0.05 so the pastel art never muddies.
local LOOKS: { [string]: Look } = {
	beach = { -- warm, sunny
		tint = Color3.fromRGB(255, 247, 230),
		brightness = 0.03,
		contrast = 0.03,
		saturation = 0.12,
		ambient = Color3.fromRGB(255, 232, 200),
		ambientMix = 0.1,
		fog = Color3.fromRGB(255, 240, 215),
		fogMix = 0.15,
		fogEnd = 100000,
		atmosphere = Color3.fromRGB(255, 236, 205),
		atmosphereMix = 0.15,
		density = 0,
		haze = 0,
		flash = 0,
	},
	cove = { -- teal-green
		tint = Color3.fromRGB(230, 255, 245),
		brightness = 0.01,
		contrast = 0.02,
		saturation = 0.05,
		ambient = Color3.fromRGB(165, 230, 210),
		ambientMix = 0.1,
		fog = Color3.fromRGB(190, 235, 222),
		fogMix = 0.2,
		fogEnd = 100000,
		atmosphere = Color3.fromRGB(190, 235, 222),
		atmosphereMix = 0.2,
		density = 0.01,
		haze = 0.2,
		flash = 0,
	},
	bay = { -- dusk warmth
		tint = Color3.fromRGB(255, 236, 220),
		brightness = -0.04,
		contrast = 0.04,
		saturation = 0.05,
		ambient = Color3.fromRGB(230, 160, 120),
		ambientMix = 0.12,
		fog = Color3.fromRGB(240, 182, 150),
		fogMix = 0.25,
		fogEnd = 100000,
		atmosphere = Color3.fromRGB(250, 192, 160),
		atmosphereMix = 0.25,
		density = 0.02,
		haze = 0.4,
		flash = 0,
	},
	reef = { -- aqua-purple
		tint = Color3.fromRGB(234, 240, 255),
		brightness = 0,
		contrast = 0.03,
		saturation = 0.1,
		ambient = Color3.fromRGB(170, 185, 240),
		ambientMix = 0.1,
		fog = Color3.fromRGB(195, 205, 248),
		fogMix = 0.2,
		fogEnd = 100000,
		atmosphere = Color3.fromRGB(205, 200, 250),
		atmosphereMix = 0.2,
		density = 0.01,
		haze = 0.2,
		flash = 0,
	},
	bubble = { -- pale mint, bright
		tint = Color3.fromRGB(240, 255, 247),
		brightness = 0.04,
		contrast = -0.02,
		saturation = 0.02,
		ambient = Color3.fromRGB(220, 255, 235),
		ambientMix = 0.1,
		fog = Color3.fromRGB(225, 250, 236),
		fogMix = 0.2,
		fogEnd = 100000,
		atmosphere = Color3.fromRGB(225, 250, 236),
		atmosphereMix = 0.2,
		density = 0,
		haze = 0,
		flash = 0,
	},
	coral = { -- sunset peach
		tint = Color3.fromRGB(255, 238, 226),
		brightness = 0.02,
		contrast = 0.03,
		saturation = 0.08,
		ambient = Color3.fromRGB(255, 190, 170),
		ambientMix = 0.1,
		fog = Color3.fromRGB(255, 206, 186),
		fogMix = 0.2,
		fogEnd = 100000,
		atmosphere = Color3.fromRGB(255, 210, 190),
		atmosphereMix = 0.2,
		density = 0.01,
		haze = 0.3,
		flash = 0,
	},
	shark = { -- steel-blue, cool
		tint = Color3.fromRGB(224, 235, 255),
		brightness = -0.02,
		contrast = 0.05,
		saturation = -0.12,
		ambient = Color3.fromRGB(120, 145, 185),
		ambientMix = 0.15,
		fog = Color3.fromRGB(160, 180, 205),
		fogMix = 0.25,
		fogEnd = 100000,
		atmosphere = Color3.fromRGB(170, 186, 210),
		atmosphereMix = 0.25,
		density = 0.02,
		haze = 0.3,
		flash = 0,
	},
	storm = {
		tint = Color3.fromRGB(200, 215, 255),
		brightness = -0.06,
		contrast = 0.08,
		saturation = -0.2,
		ambient = Color3.fromRGB(45, 55, 80),
		ambientMix = 0.55,
		fog = Color3.fromRGB(95, 105, 125),
		fogMix = 0.8,
		fogEnd = 900,
		atmosphere = Color3.fromRGB(140, 150, 170),
		atmosphereMix = 0.7,
		density = 0.12,
		haze = 1.2,
		flash = 0.14,
	},
	volcano = {
		tint = Color3.fromRGB(255, 220, 190),
		brightness = 0.01,
		contrast = 0.05,
		saturation = 0.1,
		ambient = Color3.fromRGB(150, 80, 50),
		ambientMix = 0.2,
		fog = Color3.fromRGB(200, 120, 90),
		fogMix = 0.3,
		fogEnd = 100000,
		atmosphere = Color3.fromRGB(255, 180, 140),
		atmosphereMix = 0.3,
		density = 0.03,
		haze = 0.4,
		flash = 0,
	},
}

-- Absolute Lighting / Atmosphere / grade values; what is on screen is a blend of two.
type Grade = {
	tint: Color3,
	brightness: number,
	contrast: number,
	saturation: number,
	ambient: Color3,
	outdoor: Color3,
	fogColor: Color3,
	fogEnd: number,
	atmoColor: Color3,
	density: number,
	haze: number,
}

-- Ambience state. ambTheme is set from a run's start until the look has faded out again.
-- The screen shows ambFrom blended toward ambTo by the eased ambWeight. ambFrom is the
-- untouched scene (`saved`, ambFromBase true) except during a cross-fade between maps,
-- when it is a snapshot of what was on screen; it returns to the scene once that ends.
local ambTheme: string? = nil
local ambLevel = 0
local ambFolder: Instance? = nil
local ambTarget = 0
local ambWeight = 0
local ambExtra = 0 -- separate ramp for the embers / sparkles (restarts on a cross-fade)
local ambFlash = 0
local ambOutSince: number? = nil
local ambFrom: Grade? = nil
local ambTo: Grade? = nil
local ambFromBase = true
local grade: ColorCorrectionEffect? = nil
local atmosphere: Atmosphere? = nil
local sparkles: ParticleEmitter? = nil
local embers: { [BasePart]: ParticleEmitter } = {}
local liveEmbers: { ParticleEmitter } = {}
local saved: Grade = {
	tint = WHITE,
	brightness = 0,
	contrast = 0,
	saturation = 0,
	ambient = Color3.new(),
	outdoor = Color3.new(),
	fogColor = Color3.new(),
	fogEnd = 0,
	atmoColor = Color3.new(),
	density = 0,
	haze = 0,
}
local levelBounds: { [Instance]: { min: Vector3, max: Vector3 } } = {}

local function levelFolder(level: number): Instance?
	local map = Workspace:FindFirstChild("Map")
	local modes = map and map:FindFirstChild("GameModes")
	local parkour = modes and modes:FindFirstChild("Parkour")
	return parkour and parkour:FindFirstChild("Level" .. level)
end

-- The level folder's extents (from its parts, cached), padded for jumps and falls.
local function boundsOf(folder: Instance): { min: Vector3, max: Vector3 }?
	local cached = levelBounds[folder]
	if cached then
		return cached
	end
	local lo, hi = nil :: Vector3?, nil :: Vector3?
	for _, d in folder:GetDescendants() do
		if d:IsA("BasePart") then
			local half = d.Size.Magnitude / 2
			local a, b = d.Position - Vector3.one * half, d.Position + Vector3.one * half
			lo = if lo then lo:Min(a) else a
			hi = if hi then hi:Max(b) else b
		end
	end
	if not lo or not hi then
		return nil
	end
	local box = { min = lo - Vector3.new(40, 80, 40), max = hi + Vector3.new(40, 80, 40) }
	levelBounds[folder] = box
	return box
end

-- A ParticleEmitter with sprite `name`, or a plain one when the sprite is missing.
local function emitter(parent: Instance, name: string, props: { [string]: any }): ParticleEmitter
	local made = Sprites.emitter(parent, name, props)
	if made then
		return made
	end
	local plain = Instance.new("ParticleEmitter")
	for key, value in props do
		(plain :: any)[key] = value
	end
	plain.Parent = parent
	return plain
end

local function emberFor(part: BasePart): ParticleEmitter
	local cached = embers[part]
	if cached and cached.Parent then
		return cached
	end
	local orange = ColorSequence.new(Color3.fromRGB(255, 190, 90), Color3.fromRGB(255, 90, 40))
	local e = emitter(part, "SoftDot", {
		Rate = 0,
		Color = orange,
		LightEmission = 1,
		Lifetime = NumberRange.new(1.6, 2.8),
		Speed = NumberRange.new(3, 7),
		Drag = 0.6,
		Acceleration = Vector3.new(0, 1.5, 0),
		EmissionDirection = Enum.NormalId.Top,
		SpreadAngle = Vector2.new(25, 25),
		Size = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.15),
			NumberSequenceKeypoint.new(0.3, 0.4),
			NumberSequenceKeypoint.new(1, 0),
		}),
		Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.2),
			NumberSequenceKeypoint.new(0.7, 0.3),
			NumberSequenceKeypoint.new(1, 1),
		}),
	})
	e.Name = "ParkourEmbers"
	embers[part] = e
	return e
end

local function makeSparkles(root: BasePart): ParticleEmitter
	local attachment = Instance.new("Attachment")
	attachment.Name = "ParkourSparkles"
	attachment.Parent = root
	return emitter(attachment, "Sparkle", {
		Rate = 0,
		Color = ColorSequence.new(Color3.fromRGB(255, 214, 120), Color3.fromRGB(255, 240, 205)),
		LightEmission = 0.5,
		Lifetime = NumberRange.new(0.9, 1.5),
		Speed = NumberRange.new(1.5, 3),
		Drag = 1.5,
		Acceleration = Vector3.new(0, 1, 0),
		SpreadAngle = Vector2.new(180, 180),
		Size = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0),
			NumberSequenceKeypoint.new(0.2, 0.55),
			NumberSequenceKeypoint.new(1, 0),
		}),
	})
end

-- The scene's values with `theme`'s look fully applied (giga has no grade: the scene).
local function gradeFor(theme: string): Grade
	local look = LOOKS[theme]
	if not look then
		return table.clone(saved)
	end
	return {
		tint = look.tint,
		brightness = look.brightness,
		contrast = look.contrast,
		saturation = look.saturation,
		ambient = saved.ambient:Lerp(look.ambient, look.ambientMix),
		outdoor = saved.outdoor:Lerp(look.ambient, look.ambientMix),
		fogColor = saved.fogColor:Lerp(look.fog, look.fogMix),
		fogEnd = math.min(saved.fogEnd, look.fogEnd),
		atmoColor = saved.atmoColor:Lerp(look.atmosphere, look.atmosphereMix),
		density = math.clamp(saved.density + look.density, 0, 1),
		haze = math.clamp(saved.haze + look.haze, 0, 10),
	}
end

local function blend(a: Grade, b: Grade, t: number): Grade
	return {
		tint = a.tint:Lerp(b.tint, t),
		brightness = a.brightness + (b.brightness - a.brightness) * t,
		contrast = a.contrast + (b.contrast - a.contrast) * t,
		saturation = a.saturation + (b.saturation - a.saturation) * t,
		ambient = a.ambient:Lerp(b.ambient, t),
		outdoor = a.outdoor:Lerp(b.outdoor, t),
		fogColor = a.fogColor:Lerp(b.fogColor, t),
		fogEnd = a.fogEnd + (b.fogEnd - a.fogEnd) * t,
		atmoColor = a.atmoColor:Lerp(b.atmoColor, t),
		density = a.density + (b.density - a.density) * t,
		haze = a.haze + (b.haze - a.haze) * t,
	}
end

local function ease(w: number): number
	return w * w * (3 - 2 * w)
end

-- What is on screen right now (without the lightning flash).
local function shownGrade(): Grade
	local from, to = ambFrom or saved, ambTo or saved
	return blend(from, to, ease(ambWeight))
end

-- Writes the current blend plus a lightning flash (0..1).
local function applyLook(flash: number)
	local g = shownGrade()
	local look = if ambTheme then LOOKS[ambTheme] else nil
	local cc = grade
	if not cc then
		local made = Instance.new("ColorCorrectionEffect")
		made.Name = "ParkourGrade"
		made.Parent = Lighting
		cc = made
		grade = made
	end
	if cc then
		cc.TintColor = g.tint
		cc.Brightness = g.brightness + (if look then look.flash * flash else 0)
		cc.Contrast = g.contrast
		cc.Saturation = g.saturation
	end
	Lighting.Ambient = g.ambient
	Lighting.OutdoorAmbient = g.outdoor
	Lighting.FogColor = g.fogColor
	Lighting.FogEnd = g.fogEnd
	local atmo = atmosphere
	if atmo then
		atmo.Color = g.atmoColor
		atmo.Density = g.density
		atmo.Haze = g.haze
	end
	local x = ease(ambExtra)
	for _, e in liveEmbers do
		e.Rate = EMBER_RATE * x
	end
	local s = sparkles
	if s then
		s.Rate = SPARKLE_RATE * x
	end
end

-- Stops the theme's extras: embers off, sparkles left to die out then removed.
local function dropExtras()
	for _, e in liveEmbers do
		e.Rate = 0
		e.Enabled = false
	end
	table.clear(liveEmbers)
	local s = sparkles
	if s then
		local attachment = s.Parent
		s.Rate = 0
		task.delay(2, function()
			if attachment then
				attachment:Destroy()
			end
		end)
	end
	sparkles = nil
end

-- Starts `theme`'s extras for the level `folder` (their rate follows ambExtra).
local function startExtras(theme: string, folder: Instance)
	if theme == "volcano" then
		for _, g in glows do
			if g.part:IsDescendantOf(folder) then
				local e = emberFor(g.part)
				e.Enabled = true
				table.insert(liveEmbers, e)
			end
		end
	elseif theme == "giga" then
		local _, root = character()
		if root then
			sparkles = makeSparkles(root)
		end
	end
end

-- Puts every Lighting value back exactly and removes (or disables) what the look added.
local function clearAmbience()
	if ambTheme then
		Lighting.Ambient = saved.ambient
		Lighting.OutdoorAmbient = saved.outdoor
		Lighting.FogColor = saved.fogColor
		Lighting.FogEnd = saved.fogEnd
		local atmo = atmosphere
		if atmo and atmo.Parent then
			atmo.Color = saved.atmoColor
			atmo.Density = saved.density
			atmo.Haze = saved.haze
		end
	end
	if grade then
		grade:Destroy()
	end
	dropExtras()
	grade, atmosphere, ambFolder, ambFrom, ambTo, ambFromBase = nil, nil, nil, nil, nil, true
	ambTheme, ambTarget, ambWeight, ambExtra, ambFlash, ambOutSince = nil, 0, 0, 0, 0, nil
end

local function startAmbience(level: number)
	local folder = levelFolder(level)
	local theme = if folder then folder:GetAttribute("Theme") else nil
	if not folder or type(theme) ~= "string" or (not LOOKS[theme] and theme ~= "giga") then
		if ambTheme then
			clearAmbience()
		end
		return
	end
	if ambTheme then
		-- Already showing a look: cross-fade from what is on screen to this map's look
		-- (the scene's own values in `saved` stay as they were first captured).
		local same = ambTheme == theme and ambLevel == level and ambFolder == folder
		local target = gradeFor(theme)
		ambFrom, ambTo, ambFromBase = shownGrade(), target, false
		ambWeight = 0
		if not same then
			dropExtras()
			ambExtra = 0
			startExtras(theme, folder)
		end
		ambTheme, ambLevel, ambFolder, ambTarget, ambOutSince = theme, level, folder, 1, nil
		applyLook(ambFlash)
		return
	end
	ambTheme, ambLevel, ambFolder, ambTarget, ambWeight, ambExtra = theme, level, folder, 1, 0, 0
	saved.ambient = Lighting.Ambient
	saved.outdoor = Lighting.OutdoorAmbient
	saved.fogColor = Lighting.FogColor
	saved.fogEnd = Lighting.FogEnd
	local atmo = Lighting:FindFirstChildOfClass("Atmosphere")
	atmosphere = atmo
	if atmo then
		saved.atmoColor = atmo.Color
		saved.density = atmo.Density
		saved.haze = atmo.Haze
	end
	ambFrom, ambTo, ambFromBase = saved, gradeFor(theme), true
	startExtras(theme, folder)
	applyLook(0)
end

-- Eases the look out (it is cleared once fully faded). Mid cross-fade, what is on screen
-- becomes the look to fade from, so the fade ends on the untouched scene.
local function endAmbience()
	if ambTheme and not ambFromBase then
		ambFrom, ambTo, ambFromBase, ambWeight = saved, shownGrade(), true, 1
	end
	ambTarget, ambOutSince = 0, nil
end

local function stepAmbience(dt: number, pos: Vector3?)
	if not ambTheme then
		return
	end
	local folder = ambFolder
	if ambTarget > 0 and folder and pos then
		local box = if folder.Parent then boundsOf(folder) else nil
		local inside = box ~= nil and pos == pos:Max(box.min):Min(box.max)
		local now = os.clock()
		if inside then
			ambOutSince = nil
		elseif not ambOutSince then
			ambOutSince = now
		elseif now - (ambOutSince :: number) > OUT_GRACE then
			endAmbience()
		end
	end
	local before, beforeExtra = ambWeight, ambExtra
	local stepW = (if ambTarget > 0 then dt else -dt) / AMBIENCE_FADE
	ambWeight = math.clamp(ambWeight + stepW, 0, 1)
	ambExtra = math.clamp(ambExtra + stepW, 0, 1)
	if ambWeight == 1 and not ambFromBase then
		-- The cross-fade is done: the screen is ambTo, so fade later from the scene.
		ambFrom, ambFromBase = saved, true
	end
	local flash = if boltLit then 1 else 0
	if ambWeight ~= before or ambExtra ~= beforeExtra or flash ~= ambFlash then
		ambFlash = flash
		applyLook(flash)
	end
	if ambWeight == 0 and ambTarget == 0 then
		clearAmbience()
	end
end

local moverParts: { BasePart } = {}
local moverFrames: { CFrame } = {}

local function step(dt: number)
	local humanoid, root = character()
	if not humanoid or not root then
		stepAmbience(dt, nil)
		return
	end
	stepScenery(root.Position)
	stepAmbience(dt, root.Position)
	bobArrows(root.Position, dt)
	pulseNextFlag()
	local b = bounds
	if not b then
		return
	end
	local pos = root.Position
	local clamped = pos:Max(b.min):Min(b.max)
	if (pos - clamped).Magnitude > NEAR then
		return
	end

	-- Which mover is underfoot (before this frame's move)?
	local reach = root.Size.Y / 2 + humanoid.HipHeight + 1.6
	local hit = Workspace:Raycast(pos, Vector3.new(0, -reach, 0), rayParams)
	local under = if hit then byPart[hit.Instance :: BasePart] else nil

	local t = Workspace:GetServerTimeNow()
	for _, blinkPad in blinks do
		if (blinkPad.centre - pos).Magnitude <= NEAR then
			setBlink(blinkPad, blinkState(blinkPad, t))
		end
	end
	-- (Reused every frame: the mover lists are cleared after the BulkMoveTo.)
	local parts, frames = moverParts, moverFrames
	local carry: CFrame? = nil
	stepFrame += 1
	local thin = Budget.low() and stepFrame % 2 == 0
	for _, m in movers do
		local distance = (m.rest.Position - pos).Magnitude
		if distance <= NEAR then
			if thin and distance > LOW_FAR and m ~= under then
				continue
			end
			local pose = poseAt(m, t)
			if m == under and m.live then
				carry = pose * m.current:Inverse()
			end
			m.current = pose
			m.live = true
			for i, part in m.parts do
				table.insert(parts, part)
				table.insert(frames, pose * m.offsets[i])
			end
		else
			m.live = false
		end
	end
	if #parts > 0 then
		Workspace:BulkMoveTo(parts, frames, Enum.BulkMoveMode.FireCFrameChanged)
		table.clear(parts)
		table.clear(frames)
	end
	if carry then
		root.CFrame = carry * root.CFrame
		pos = root.Position
	end

	-- Spinner bars and bounce pads near the player.
	local feet = feetY(humanoid, root)
	for _, m in movers do
		if m.hazard and (m.rest.Position - pos).Magnitude < m.length / 2 + 4 then
			local cf = m.current
			local half = cf.RightVector * (m.length / 2)
			local a, segment = cf.Position - half, half * 2
			local along = math.clamp((pos - a):Dot(segment) / segment:Dot(segment), 0, 1)
			local closest = a + segment * along
			local flat = Vector3.new(pos.X - closest.X, 0, pos.Z - closest.Z).Magnitude
			if flat < 1.9 and closest.Y > feet - 0.4 and closest.Y < pos.Y + 1.2 then
				bump(m, humanoid, root, closest)
			end
		end
	end
	for _, pad in pads do
		local center = padRest[pad].Position
		local radius = pad.Size.Y / 2
		local flat = Vector3.new(pos.X - center.X, 0, pos.Z - center.Z).Magnitude
		local height = feet - (center.Y + pad.Size.X / 2)
		local touching = flat < radius + 0.4 and height > -0.6 and height < 1.4
		if touching and not padContact[pad] and root.AssemblyLinearVelocity.Y < 5 then
			launch(pad, humanoid, root)
		end
		padContact[pad] = touching
	end

	-- Still-player hint during a run.
	if running then
		local now = os.clock()
		if (pos - stillAt).Magnitude > 1 then
			stillAt = pos
			stillSince = now
		elseif now - stillSince > STILL_FOR and now - lastHint > HINT_EVERY then
			lastHint = now
			showHint(root)
		end
	end
end

-- Effects -------------------------------------------------------------------------------

local function checkpointPop(position: Vector3)
	local folder = courseFolder()
	local cap: BasePart? = nil
	local best = 14
	if folder then
		for _, d in folder:GetDescendants() do
			if d.Name == "FlagCap" and d:IsA("BasePart") then
				local flat = Vector3.new(d.Position.X - position.X, 0, d.Position.Z - position.Z).Magnitude
				if flat < best then
					best = flat
					cap = d
				end
			end
		end
	end
	local top = if cap then cap.Position else position + Vector3.new(0, 6, 0)
	local anchor = anchorAt(top, 3)
	Sprites.billboard(anchor, "StarPop", { position = top, size = 3, life = 0.9, rise = Vector3.new(0, 2, 0), spin = 40 })
	local pops = Budget.count(5)
	for i = 1, pops do
		if not Sprites.room() then
			break -- decorative: the device's sprite budget is full
		end
		local a = i / pops * TAU
		Sprites.billboard(anchor, "Confetti", {
			position = top,
			size = 0.8,
			life = 1.1,
			delay = 0.04 * i,
			rise = Vector3.new(math.cos(a) * 3, 2.5, math.sin(a) * 3),
			color = ({ W.Sunny, W.Pink, W.Mint, W.Blue, W.Coral })[i],
			spin = 180,
		})
	end
	if cap then
		local size = restSize(cap)
		cap.Size = size * 1.7
		TweenService:Create(cap, TweenInfo.new(0.45, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Size = size }):Play()
	end
end

local function splash(position: Vector3)
	local anchor = anchorAt(position, 3)
	Sprites.billboard(anchor, "Ring", { position = position, size = 6, life = 0.7, rise = Vector3.zero, color = W.Pool })
	Sprites.billboard(anchor, "Puff", { position = position, size = 4, life = 0.8, rise = Vector3.new(0, 3, 0) })
	local dots = Budget.count(6)
	for i = 1, dots do
		if not Sprites.room() then
			break
		end
		local a = i / dots * TAU
		Sprites.billboard(anchor, "SoftDot", {
			position = position,
			size = 0.7,
			life = 0.7,
			rise = Vector3.new(math.cos(a) * 2.5, 3.5, math.sin(a) * 2.5),
			color = W.Pool,
		})
	end
	local humanoid = character()
	if humanoid then
		humanoid.CameraOffset = Vector3.new(0, -1.2, 0)
		TweenService:Create(humanoid, TweenInfo.new(0.4, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { CameraOffset = Vector3.zero })
			:Play()
	end
end

local function finish(position: Vector3)
	local anchor = anchorAt(position, 3)
	local pops = Budget.count(8)
	for i = 1, pops do
		if not Sprites.room() then
			break -- decorative: the device's sprite budget is full
		end
		local a = i / pops * TAU
		Sprites.billboard(anchor, if i % 2 == 0 then "StarPop" else "Confetti", {
			position = position + Vector3.new(0, 2, 0),
			size = if i % 2 == 0 then 2 else 1,
			life = 1.4,
			delay = 0.03 * i,
			rise = Vector3.new(math.cos(a) * 5, 6, math.sin(a) * 5),
			color = if i % 2 == 0 then nil else ({ W.Sunny, W.Pink, W.Mint, W.Blue })[i // 2 + 1],
			spin = 200,
		})
	end
end

function ModesFx.init()
	for _, root in CollectionService:GetTagged("ModeMover") do
		addMover(root)
	end
	CollectionService:GetInstanceAddedSignal("ModeMover"):Connect(addMover)
	for _, pad in CollectionService:GetTagged("BouncePad") do
		addPad(pad)
	end
	CollectionService:GetInstanceAddedSignal("BouncePad"):Connect(addPad)
	for _, pad in CollectionService:GetTagged("BlinkPad") do
		addBlink(pad)
	end
	CollectionService:GetInstanceAddedSignal("BlinkPad"):Connect(addBlink)
	for _, arrow in CollectionService:GetTagged("ModeHintArrow") do
		addArrow(arrow)
	end
	CollectionService:GetInstanceAddedSignal("ModeHintArrow"):Connect(addArrow)
	for tag, add in { MapBubble = addBubble, MapBob = addBob, MapLightning = addBolt, MapGlow = addGlow } :: { [string]: (Instance) -> () } do
		for _, part in CollectionService:GetTagged(tag) do
			add(part)
		end
		CollectionService:GetInstanceAddedSignal(tag):Connect(add)
	end
	CollectionService:GetInstanceRemovedSignal("MapBubble"):Connect(function(inst)
		dropFrom(bubbles, nearBubbles, inst)
	end)
	CollectionService:GetInstanceRemovedSignal("MapBob"):Connect(function(inst)
		dropFrom(bobs, nearBobs, inst)
	end)
	CollectionService:GetInstanceRemovedSignal("MapLightning"):Connect(function(inst)
		dropFrom(bolts, nearBolts, inst)
	end)
	CollectionService:GetInstanceRemovedSignal("MapGlow"):Connect(function(inst)
		dropFrom(glows, nearGlows, inst)
		embers[inst :: BasePart] = nil
	end)
	-- A respawn ends the themed look (the old root's sparkles go with the old character).
	player.CharacterAdded:Connect(endAmbience)

	RunService.PreSimulation:Connect(step)

	Net.event("Notify").OnClientEvent:Connect(function(payload)
		if type(payload) ~= "table" or payload.kind ~= "Mode" or payload.mode ~= "parkour" then
			return
		end
		local event = payload.event
		if event == "start" then
			currentLevel = math.floor(num(payload.level, 1))
			pulseCap = nil
			running, nextIndex = true, 1
			stillSince, lastHint = os.clock(), os.clock()
			startAmbience(currentLevel)
		elseif event == "checkpoint" then
			nextIndex = num(payload.index, nextIndex) + 1
		elseif event == "finish" or event == "invalid" or event == "stop" then
			running = false
			endAmbience()
		end
	end)

	Net.event("Effect").OnClientEvent:Connect(function(kind, data)
		if type(data) ~= "table" or typeof(data.pos) ~= "Vector3" then
			return
		end
		if kind == "ModeCheckpoint" then
			checkpointPop(data.pos)
		elseif kind == "ModeSplash" then
			splash(data.pos)
		elseif kind == "ModeFinish" then
			finish(data.pos)
		end
	end)
end

return ModesFx
