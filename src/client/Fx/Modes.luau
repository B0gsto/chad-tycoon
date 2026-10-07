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

local function step(dt: number)
	local humanoid, root = character()
	if not humanoid or not root then
		return
	end
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
	local parts: { BasePart } = {}
	local frames: { CFrame } = {}
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
		elseif event == "checkpoint" then
			nextIndex = num(payload.index, nextIndex) + 1
		elseif event == "finish" or event == "invalid" or event == "stop" then
			running = false
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
