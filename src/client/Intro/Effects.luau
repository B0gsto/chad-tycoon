--!strict
--[[
	Intro.Effects: the 3D effects and story props of the intro (dust puffs,
	thump rings, the poof a fan appears in, the rival's golden halo, the
	sparkling aura trail, the hero's rain cloud, the lightbulb, sweat drops,
	dizzy stars, confetti, a tumbleweed, the plot marker and the candy
	dumbbell).

	Everything lives under the stage model and dies with it. Effects.new()
	returns an object; Cutscene calls fx:update(dt) every frame. Story props
	are "live props": parts placed every frame relative to an anchor function
	(usually an actor's head or chest), popping in with a Back ease and
	shrinking away when stopped, so they follow their actor and never snap.
]]

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Effects = {}
Effects.__index = Effects

local SPARKLE = "rbxasset://textures/particles/sparkles_main.dds"
local SMOOTH = Enum.Material.SmoothPlastic

-- Dumbbell sizes (studs): oversized so it reads from the camera.
local BAR = 1.85
local BAR_R = 0.3
local PLATE = 0.95
local PLATE_W = 0.34

-- Live props pop in over POP_IN seconds and shrink away over POP_OUT.
local POP_IN = 0.3
local POP_OUT = 0.25

export type PropItem = {
	size: Vector3,
	color: Color3,
	offset: CFrame,
	shape: Enum.PartType?,
	wedge: boolean?,
	material: Enum.Material?,
	transparency: number?,
}

export type Handle = {
	stop: (instant: boolean?) -> (),
	parts: { BasePart },
	last: CFrame?,
}

type DumbbellState = "held" | "drop" | "rest" | "roll"

export type Effects = typeof(setmetatable(
	{} :: {
		theme: any,
		folder: Folder,
		stage: CFrame,
		clock: number,
		emitter: BasePart,
		sparkles: ParticleEmitter,
		trail: { { part: BasePart, base: Vector3, phase: number } },
		live: { (now: number, dt: number) -> boolean },
		handles: { [string]: Handle },
		dumbbell: Model,
		dbState: DumbbellState,
		dbFrom: CFrame,
		dbTo: CFrame,
		dbStart: number,
		dbDur: number,
		dbRattleUntil: number,
		dbAxis: Vector3,
	},
	Effects
))

local function tween(inst: Instance, t: number, props: { [string]: any }, style: Enum.EasingStyle?, dir: Enum.EasingDirection?)
	local tw = TweenService:Create(inst, TweenInfo.new(t, style or Enum.EasingStyle.Quad, dir or Enum.EasingDirection.Out), props)
	tw:Play()
	return tw
end

local function part(parent: Instance, props: { [string]: any }): BasePart
	local p = Instance.new("Part")
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Material = SMOOTH
	for key, value in props do
		(p :: any)[key] = value
	end
	p.Parent = parent
	return p
end

local function later(seconds: number, fn: () -> ())
	task.delay(seconds, function()
		pcall(fn)
	end)
end

local function bounceOut(u: number): number
	-- Two small bounces after the first landing.
	if u < 0.6 then
		local k = u / 0.6
		return k * k
	elseif u < 0.85 then
		local k = (u - 0.725) / 0.125
		return 1 - 0.12 * (1 - k * k)
	end
	local k = (u - 0.925) / 0.075
	return 1 - 0.03 * (1 - k * k)
end

local function backOut(u: number): number
	local s = 1.9
	local k = u - 1
	return 1 + (s + 1) * k * k * k + s * k * k
end

function Effects.new(parent: Instance, stage: CFrame, theme: any): Effects
	local W = theme.World
	local folder = Instance.new("Folder")
	folder.Name = "IntroFx"
	folder.Parent = parent

	-- One hidden emitter part, moved to each burst point and Emit()ted.
	local emitter = part(folder, { Name = "Burst", Size = Vector3.one * 0.2, Transparency = 1, CFrame = stage })
	local sparkles = Instance.new("ParticleEmitter")
	sparkles.Texture = SPARKLE
	sparkles.Enabled = false
	sparkles.LightEmission = 0.6
	sparkles.Lifetime = NumberRange.new(0.6, 1.1)
	sparkles.Speed = NumberRange.new(6, 12)
	sparkles.SpreadAngle = Vector2.new(180, 180)
	sparkles.Drag = 3
	sparkles.Acceleration = Vector3.new(0, 4, 0)
	sparkles.RotSpeed = NumberRange.new(-180, 180)
	sparkles.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.7),
		NumberSequenceKeypoint.new(1, 0),
	})
	sparkles.Color = ColorSequence.new(W.Sunny)
	sparkles.Parent = emitter

	-- The candy dumbbell: chrome bar, pink plates with mint collars and white
	-- caps (bar along its X axis).
	local dumbbell = Instance.new("Model")
	dumbbell.Name = "Dumbbell"
	local bar = part(dumbbell, {
		Name = "Bar",
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(BAR, BAR_R, BAR_R),
		Color = W.Chrome,
	})
	for _, side in { -1, 1 } do
		part(dumbbell, {
			Shape = Enum.PartType.Cylinder,
			Size = Vector3.new(PLATE_W, PLATE, PLATE),
			CFrame = CFrame.new(side * (BAR / 2 - 0.26), 0, 0),
			Color = W.Pink,
		})
		part(dumbbell, {
			Shape = Enum.PartType.Cylinder,
			Size = Vector3.new(0.14, PLATE * 0.62, PLATE * 0.62),
			CFrame = CFrame.new(side * (BAR / 2 - 0.5), 0, 0),
			Color = W.Mint,
		})
		part(dumbbell, {
			Shape = Enum.PartType.Cylinder,
			Size = Vector3.new(0.1, PLATE * 0.55, PLATE * 0.55),
			CFrame = CFrame.new(side * (BAR / 2 - 0.05), 0, 0),
			Color = W.White,
		})
	end
	dumbbell.PrimaryPart = bar
	dumbbell.Parent = folder

	local self = setmetatable({
		theme = theme,
		folder = folder,
		stage = stage,
		clock = 0,
		emitter = emitter,
		sparkles = sparkles,
		trail = {},
		live = {},
		handles = {},
		dumbbell = dumbbell,
		dbState = "held" :: DumbbellState,
		dbFrom = CFrame.new(),
		dbTo = CFrame.new(),
		dbStart = 0,
		dbDur = 0,
		dbRattleUntil = 0,
		dbAxis = Vector3.zAxis,
	}, Effects)
	return self
end

-- Bursts -----------------------------------------------------------------------------

function Effects.burst(self: Effects, pos: Vector3, count: number, color: Color3?, speed: number?)
	self.emitter.CFrame = CFrame.new(pos)
	self.sparkles.Color = ColorSequence.new(color or self.theme.World.Sunny)
	local s = speed or 9
	self.sparkles.Speed = NumberRange.new(s * 0.6, s * 1.2)
	self.sparkles:Emit(count)
end

-- Soft dust balls that swell, drift up and fade.
function Effects.dust(self: Effects, pos: Vector3, count: number, spread: number)
	local W = self.theme.World
	for i = 1, count do
		local a = (i / count) * math.pi * 2 + math.random() * 0.6
		local r = spread * (0.5 + math.random() * 0.5)
		local start = pos + Vector3.new(math.cos(a) * r * 0.4, 0.3, math.sin(a) * r * 0.4)
		local puff = part(self.folder, {
			Shape = Enum.PartType.Ball,
			Size = Vector3.one * 0.9,
			CFrame = CFrame.new(start),
			Color = if i % 2 == 0 then W.Cream else W.Sand,
			Transparency = 0.15,
		})
		local size = 2 + math.random() * 1.5
		tween(puff, 0.7, {
			Size = Vector3.one * size,
			CFrame = CFrame.new(pos + Vector3.new(math.cos(a) * r, 0.7 + math.random() * 0.6, math.sin(a) * r)),
			Transparency = 1,
		}, Enum.EasingStyle.Quad)
		later(0.75, function()
			puff:Destroy()
		end)
	end
end

-- A flat ring that spreads out over the ground.
function Effects.ring(self: Effects, pos: Vector3, radius: number, color: Color3?)
	local ring = part(self.folder, {
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(0.12, 1, 1),
		CFrame = CFrame.new(pos + Vector3.new(0, 0.08, 0)) * CFrame.Angles(0, 0, math.rad(90)),
		Color = color or self.theme.World.Cream,
		Transparency = 0.2,
	})
	tween(ring, 0.5, { Size = Vector3.new(0.12, radius * 2, radius * 2), Transparency = 1 }, Enum.EasingStyle.Quad)
	later(0.55, function()
		ring:Destroy()
	end)
end

-- White puff balls plus sparkles (a fan pops into the scene).
function Effects.poof(self: Effects, pos: Vector3, height: number)
	local W = self.theme.World
	for i = 1, 8 do
		local a = i / 8 * math.pi * 2
		local p0 = pos + Vector3.new(math.cos(a) * 0.6, height * (0.25 + (i % 3) * 0.22), math.sin(a) * 0.6)
		local puff = part(self.folder, {
			Shape = Enum.PartType.Ball,
			Size = Vector3.one * 1.4,
			CFrame = CFrame.new(p0),
			Color = if i % 3 == 0 then W.Cream else W.White,
			Transparency = 0,
		})
		tween(puff, 0.5, {
			Size = Vector3.one * 2.8,
			CFrame = CFrame.new(p0 + Vector3.new(math.cos(a) * 1.4, 0.6, math.sin(a) * 1.4)),
			Transparency = 1,
		}, Enum.EasingStyle.Quad)
		later(0.55, function()
			puff:Destroy()
		end)
	end
	self:burst(pos + Vector3.new(0, height * 0.6, 0), 14, W.Sunny, 8)
end

-- Gold aura burst around a model's chest, with a spreading gold ring.
function Effects.aura(self: Effects, chest: Vector3, ground: Vector3, size: number)
	local W = self.theme.World
	self:burst(chest, 40, W.Sunny, 14 * size)
	self:burst(chest, 16, W.White, 10 * size)
	self:ring(ground, 9 * size, W.Sunny)
end

-- Aura trail ------------------------------------------------------------------------

-- Drops one lingering aura sparkle on the ground.
function Effects.trailDrop(self: Effects, ground: Vector3)
	local W = self.theme.World
	local base = ground + Vector3.new((math.random() - 0.5) * 0.8, 0.35, (math.random() - 0.5) * 0.8)
	local orb = part(self.folder, {
		Name = "AuraSparkle",
		Shape = Enum.PartType.Ball,
		Size = Vector3.one * 0.05,
		CFrame = CFrame.new(base),
		Color = W.Sunny,
		-- Aura orbs are the one thing allowed to glow.
		Material = Enum.Material.Neon,
	})
	tween(orb, 0.35, { Size = Vector3.one * (0.3 + math.random() * 0.15) }, Enum.EasingStyle.Back)
	local twinkle = Instance.new("ParticleEmitter")
	twinkle.Texture = SPARKLE
	twinkle.Rate = 2.5
	twinkle.Lifetime = NumberRange.new(0.5, 0.9)
	twinkle.Speed = NumberRange.new(0.5, 1.2)
	twinkle.SpreadAngle = Vector2.new(30, 30)
	twinkle.LightEmission = 0.6
	twinkle.Color = ColorSequence.new(W.Sunny)
	twinkle.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0),
		NumberSequenceKeypoint.new(0.3, 0.45),
		NumberSequenceKeypoint.new(1, 0),
	})
	twinkle.Parent = orb
	table.insert(self.trail, { part = orb, base = base, phase = math.random() * 6 })
end

-- Live props ---------------------------------------------------------------------------

local function propPart(parent: Instance, item: PropItem): BasePart
	local p: BasePart = if item.wedge then Instance.new("WedgePart") else Instance.new("Part")
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Material = item.material or SMOOTH
	p.Color = item.color
	p.Transparency = item.transparency or 0
	if item.shape and p:IsA("Part") then
		p.Shape = item.shape
	end
	p.Size = item.size * 0.05
	p.Parent = parent
	return p
end

-- A camera-facing frame at `pos` (upright; -Z looks at the camera).
local function facing(pos: Vector3): CFrame
	local cam = Workspace.CurrentCamera
	if cam then
		local d = cam.CFrame.Position - pos
		local flat = Vector3.new(d.X, 0, d.Z)
		if flat.Magnitude > 1e-3 then
			local back = -flat.Unit
			return CFrame.fromMatrix(pos, Vector3.yAxis:Cross(back), Vector3.yAxis, back)
		end
	end
	return CFrame.new(pos)
end

--[[
	Spawns a live prop: `items` are placed every frame at anchor(age) * motion(age)
	* item.offset, scaled by the pop-in / shrink-out factor. `life` ends it after
	that many seconds; `name` replaces any live prop with the same name;
	`extra(age, frame)` runs every frame while it lives (rain, sweat, sparkles).
]]
function Effects.prop(
	self: Effects,
	name: string?,
	items: { PropItem },
	anchor: (age: number) -> CFrame?,
	motion: ((age: number) -> CFrame)?,
	life: number?,
	instant: boolean?,
	extra: ((age: number, frame: CFrame) -> ())?
): Handle
	if name and self.handles[name] then
		self.handles[name].stop(instant)
	end
	local parts = {}
	for _, item in items do
		table.insert(parts, propPart(self.folder, item))
	end
	local born = if instant then self.clock - POP_IN else self.clock
	local dying: number? = nil
	local dead = false
	local handle: Handle
	local function kill()
		dead = true
		for _, p in parts do
			p:Destroy()
		end
		if name and self.handles[name] == handle then
			self.handles[name] = nil
		end
	end
	handle = {
		parts = parts,
		last = nil,
		stop = function(now: boolean?)
			if dead then
				return
			end
			if now then
				kill()
			elseif not dying then
				dying = self.clock
			end
		end,
	}
	if name then
		self.handles[name] = handle
	end
	table.insert(self.live, function(clock: number, _dt: number): boolean
		if dead then
			return false
		end
		local age = clock - born
		if life and not dying and age >= life then
			dying = clock
		end
		local k = backOut(math.clamp(age / POP_IN, 0, 1))
		if dying then
			local out = math.clamp((clock - dying) / POP_OUT, 0, 1)
			if out >= 1 then
				kill()
				return false
			end
			k *= 1 - out * out
		end
		local frame = anchor(age) or handle.last
		if not frame then
			return true
		end
		handle.last = frame
		if motion then
			frame *= motion(age)
		end
		k = math.max(k, 0.02)
		local cframes = table.create(#parts)
		for i, item in items do
			parts[i].Size = item.size * k
			cframes[i] = frame * CFrame.new(item.offset.Position * k) * item.offset.Rotation
		end
		if #parts > 0 then
			Workspace:BulkMoveTo(parts, cframes, Enum.BulkMoveMode.FireCFrameChanged)
		end
		if extra and not dying then
			extra(age, frame)
		end
		return true
	end)
	return handle
end

-- Stops a named live prop (shrinks away, or at once when instant).
function Effects.stopProp(self: Effects, name: string, instant: boolean?)
	local handle = self.handles[name]
	if handle then
		handle.stop(instant)
	end
end

-- A falling drop part: flies to `peak` then falls `fall` studs while fading.
function Effects.drop(self: Effects, from: Vector3, peak: Vector3, fall: number, color: Color3, size: Vector3)
	local d = part(self.folder, {
		Name = "Drop",
		Shape = Enum.PartType.Ball,
		Size = size * 0.4,
		CFrame = CFrame.new(from),
		Color = color,
	})
	local up = (peak - from).Magnitude > 0.05
	if up then
		tween(d, 0.18, { CFrame = CFrame.new(peak), Size = size })
	else
		d.Size = size
	end
	later(if up then 0.18 else 0, function()
		if d.Parent then
			tween(
				d,
				0.38,
				{ CFrame = CFrame.new(peak - Vector3.new(0, fall, 0)), Transparency = 1 },
				Enum.EasingStyle.Quad,
				Enum.EasingDirection.In
			)
		end
	end)
	later(0.62, function()
		d:Destroy()
	end)
end

-- The hero's rain cloud --------------------------------------------------------------

-- `center` returns the cloud's world centre each frame (it follows the hero).
function Effects.cloudForm(self: Effects, center: () -> Vector3, instant: boolean?)
	if self.handles.cloud then
		return
	end
	local W = self.theme.World
	local layout: { { any } } = {
		{ Vector3.new(0, 0.25, 0), 2.7, W.Steel },
		{ Vector3.new(-1.45, -0.1, 0.15), 2.1, W.Steel },
		{ Vector3.new(1.5, -0.1, -0.1), 2.15, W.Steel },
		{ Vector3.new(-0.65, 0.8, 0.3), 1.9, W.Chrome },
		{ Vector3.new(0.7, 0.75, 0.35), 1.85, W.Chrome },
		{ Vector3.new(0, -0.4, -0.45), 2.2, W.Steel },
	}
	local items: { PropItem } = {}
	for _, item in layout do
		local d = item[2] :: number
		table.insert(items, {
			size = Vector3.new(d * 1.15, d * 0.85, d),
			color = item[3],
			offset = CFrame.new(item[1] :: Vector3),
			shape = Enum.PartType.Ball,
		})
	end
	local nextDrop = 0.45
	self:prop(
		"cloud",
		items,
		function()
			return CFrame.new(center())
		end,
		function(age)
			return CFrame.new(0, math.sin(age * 2) * 0.12, 0) * CFrame.Angles(0, math.sin(age * 0.8) * 0.08, 0)
		end,
		nil,
		instant,
		function(age, frame)
			-- Big blue drops fall from the cloud's belly onto the hero.
			while age >= nextDrop do
				nextDrop += 0.07
				local x, z = (math.random() - 0.5) * 3.2, (math.random() - 0.5) * 1.4
				local from = (frame * CFrame.new(x, -0.9, z)).Position
				self:drop(from, from, 3.4, W.Blue, Vector3.new(0.26, 0.5, 0.26))
			end
		end
	)
end

function Effects.cloudBurst(self: Effects, instant: boolean?)
	local cloud = self.handles.cloud
	if not cloud then
		return
	end
	cloud.stop(instant)
	if not instant and cloud.last then
		local pos = cloud.last.Position
		self:burst(pos, 34, self.theme.World.Sunny, 10)
		self:burst(pos, 14, self.theme.World.White, 7)
	end
end

-- The lightbulb ---------------------------------------------------------------------

-- `center` returns the bulb's world centre each frame; it lives ~2.6 s.
function Effects.bulb(self: Effects, center: () -> Vector3, instant: boolean?)
	local W = self.theme.World
	local items: { PropItem } = {
		{ size = Vector3.one * 2.3, color = W.Sunny, offset = CFrame.new(), shape = Enum.PartType.Ball },
		{ size = Vector3.one * 0.85, color = W.White, offset = CFrame.new(-0.45, 0.4, -0.75), shape = Enum.PartType.Ball },
		{
			size = Vector3.new(0.75, 1.05, 1.05),
			color = W.Chrome,
			offset = CFrame.new(0, -1.3, 0) * CFrame.Angles(0, 0, math.rad(90)),
			shape = Enum.PartType.Cylinder,
		},
		{
			size = Vector3.new(0.22, 0.7, 0.7),
			color = W.Steel,
			offset = CFrame.new(0, -1.75, 0) * CFrame.Angles(0, 0, math.rad(90)),
			shape = Enum.PartType.Cylinder,
		},
	}
	for k = 0, 6 do
		local a = math.rad(-180 + k * 30)
		local dir = Vector3.new(math.cos(a), -math.sin(a), 0)
		table.insert(items, {
			size = Vector3.new(0.32, 0.95, 0.25),
			color = if k % 2 == 0 then W.Sunny else W.Orange,
			offset = CFrame.new(dir * 2.05) * CFrame.Angles(0, 0, -a - math.rad(90)),
		})
	end
	self:prop("bulb", items, function()
		return facing(center())
	end, function(age)
		return CFrame.new(0, math.sin(age * 3) * 0.15, 0) * CFrame.Angles(0, 0, math.sin(age * 2.2) * 0.08)
	end, 2.6, instant)
	if not instant then
		self:burst(center(), 24, W.Sunny, 9)
	end
end

-- The rival's golden halo -----------------------------------------------------------

--[[
	A big golden sun-halo behind an actor while he poses: a soft cream disc,
	a ring of glowing aura beads and spinning paint rays, with sparkles. It sits
	on the far side of the actor from the camera. `chest` returns the actor's
	world chest point each frame; `radius` is the ring radius in studs.
]]
function Effects.halo(self: Effects, key: string, chest: () -> Vector3, radius: number, life: number?, instant: boolean?)
	local W = self.theme.World
	local items: { PropItem } = {
		{
			size = Vector3.new(0.12, radius * 1.7, radius * 1.7),
			color = W.Cream,
			offset = CFrame.Angles(0, math.rad(90), 0),
			shape = Enum.PartType.Cylinder,
			transparency = 0.45,
		},
	}
	for k = 0, 11 do
		local a = k / 12 * math.pi * 2
		table.insert(items, {
			size = Vector3.new(0.55, radius * 0.5, 0.2),
			color = if k % 2 == 0 then W.Sunny else W.Orange,
			offset = CFrame.Angles(0, 0, a) * CFrame.new(0, radius * 1.12, 0.1),
		})
	end
	for k = 0, 17 do
		local a = k / 18 * math.pi * 2
		table.insert(items, {
			size = Vector3.one * 0.5,
			color = W.Sunny,
			offset = CFrame.new(math.cos(a) * radius * 0.85, math.sin(a) * radius * 0.85, -0.05),
			shape = Enum.PartType.Ball,
			-- Aura glow is the one thing allowed to use Neon.
			material = Enum.Material.Neon,
		})
	end
	local handle = self:prop(key, items, function()
		local c = chest()
		local front = facing(c)
		-- Behind the actor as seen from the camera, slightly raised.
		return front * CFrame.new(0, radius * 0.15, 1.4)
	end, function(age)
		return CFrame.Angles(0, 0, -age * 0.5)
	end, life, instant)
	local glitter = Instance.new("ParticleEmitter")
	glitter.Texture = SPARKLE
	glitter.Rate = 16
	glitter.Lifetime = NumberRange.new(0.6, 1.1)
	glitter.Speed = NumberRange.new(1, 3)
	glitter.SpreadAngle = Vector2.new(180, 180)
	glitter.LightEmission = 0.5
	glitter.Color = ColorSequence.new(W.Sunny)
	glitter.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0),
		NumberSequenceKeypoint.new(0.3, 0.8),
		NumberSequenceKeypoint.new(1, 0),
	})
	glitter.Parent = handle.parts[1]
end

-- Head props: sweat and dizzy stars ---------------------------------------------------

-- Sweat drops flick off both sides of the head while on (`head` = world point).
function Effects.sweat(self: Effects, key: string, head: () -> Vector3, on: boolean)
	if not on then
		self:stopProp(key)
		return
	end
	local W = self.theme.World
	local nextDrop = 0
	local side = 1
	-- An invisible anchor prop: its per-frame hook spawns the drops.
	self:prop(
		key,
		{},
		function()
			return facing(head())
		end,
		nil,
		nil,
		false,
		function(age, frame)
			while age >= nextDrop do
				nextDrop += 0.24
				side = -side
				local from = (frame * CFrame.new(side * 0.55, -0.35, -0.2)).Position
				local peak = (frame * CFrame.new(side * 1.5, 0.45, -0.3)).Position
				self:drop(from, peak, 2.2, if side > 0 then W.Blue else W.Pool, Vector3.new(0.34, 0.48, 0.34))
			end
		end
	)
end

-- Big cartoon stars orbiting the head for `dur` seconds.
function Effects.stars(self: Effects, key: string, head: () -> Vector3, dur: number, instant: boolean?)
	local W = self.theme.World
	local items: { PropItem } = {}
	local colors = { W.Sunny, W.Orange, W.Sunny, W.Pink, W.Sunny }
	for s = 1, 5 do
		local a = s / 5 * math.pi * 2
		local at = CFrame.new(math.cos(a) * 1.5, 0.35 + (s % 2) * 0.25, math.sin(a) * 1.5) * CFrame.Angles(0, -a + math.rad(90), 0)
		table.insert(items, { size = Vector3.one * 0.5, color = W.White, offset = at, shape = Enum.PartType.Ball })
		for j = 0, 4 do
			table.insert(items, {
				size = Vector3.new(0.34, 0.6, 0.22),
				color = colors[s],
				offset = at * CFrame.Angles(0, 0, math.rad(72 * j)) * CFrame.new(0, 0.38, 0),
			})
		end
	end
	self:prop(key, items, function()
		return CFrame.new(head())
	end, function(age)
		return CFrame.Angles(0, age * 3.2, 0) * CFrame.Angles(math.sin(age * 2) * 0.12, 0, 0)
	end, dur, instant)
end

-- Confetti and tumbleweed -------------------------------------------------------------

-- A short colourful burst of paper confetti at a world point.
function Effects.confetti(self: Effects, pos: Vector3)
	local W = self.theme.World
	local colors = { W.Coral, W.Pink, W.Sunny, W.Mint, W.Blue, W.Grape, W.Orange }
	local floor = self.stage.Position.Y + 0.15
	for i = 1, 36 do
		local a = math.random() * math.pi * 2
		local r = 1 + math.random() * 2.8
		local peak = pos + Vector3.new(math.cos(a) * r, 2.2 + math.random() * 2.4, math.sin(a) * r)
		local bit = part(self.folder, {
			Name = "Confetti",
			Size = Vector3.new(0.12, 0.04, 0.18),
			CFrame = CFrame.new(pos),
			Color = colors[i % #colors + 1],
		})
		local spin = CFrame.Angles(math.random() * 6, math.random() * 6, math.random() * 6)
		tween(bit, 0.4, { Size = Vector3.new(0.38, 0.08, 0.55), CFrame = CFrame.new(peak) * spin })
		later(0.4, function()
			if bit.Parent then
				local land = Vector3.new(peak.X + (math.random() - 0.5) * 1.5, math.max(floor, peak.Y - 3.5), peak.Z)
				tween(
					bit,
					1,
					{ CFrame = CFrame.new(land) * spin * CFrame.Angles(4, 2, 3), Transparency = 1 },
					Enum.EasingStyle.Quad,
					Enum.EasingDirection.In
				)
			end
		end)
		later(1.45, function()
			bit:Destroy()
		end)
	end
	self:burst(pos, 18, W.Sunny, 9)
end

-- A brown scribble ball that rolls and bounces from `from` to `to` (world ground points).
function Effects.tumbleweed(self: Effects, from: Vector3, to: Vector3, dur: number)
	local W = self.theme.World
	local items: { PropItem } = {
		{ size = Vector3.one * 1.9, color = W.Wood, offset = CFrame.new(), shape = Enum.PartType.Ball, transparency = 0.45 },
	}
	for k = 1, 8 do
		table.insert(items, {
			size = Vector3.new(2.3, 0.16, 0.16),
			color = if k % 2 == 0 then W.Wood else W.Sand,
			offset = CFrame.Angles(k * 1.7, k * 2.3, k * 0.9),
			shape = Enum.PartType.Cylinder,
		})
	end
	local delta = Vector3.new(to.X - from.X, 0, to.Z - from.Z)
	local axis = if delta.Magnitude > 0.01 then Vector3.yAxis:Cross(delta.Unit) else Vector3.xAxis
	local d = math.max(dur, 0.2)
	self:prop(nil, items, function(age)
		local u = math.clamp(age / d, 0, 1)
		local hop = math.abs(math.sin(u * math.pi * 5)) * 1.1 * (1 - u * 0.5)
		local pos = from:Lerp(to, u) + Vector3.new(0, 1 + hop, 0)
		return CFrame.new(pos) * CFrame.fromAxisAngle(axis, u * delta.Magnitude / 0.95)
	end, nil, d, false)
end

-- The plot marker ---------------------------------------------------------------------

-- A friendly bouncing arrow ~8 studs above the local character (their plot).
function Effects.marker(self: Effects, on: boolean)
	if not on then
		self:stopProp("marker")
		return
	end
	local W = self.theme.World
	local items: { PropItem } = {
		{ size = Vector3.new(1.1, 2, 1.1), color = W.Coral, offset = CFrame.new(0, 1.9, 0) },
		{ size = Vector3.new(1, 1.8, 1.5), color = W.Coral, offset = CFrame.new(0, 0, -0.75) * CFrame.Angles(0, 0, math.pi), wedge = true },
		{ size = Vector3.new(1, 1.8, 1.5), color = W.Coral, offset = CFrame.new(0, 0, 0.75) * CFrame.Angles(math.pi, 0, 0), wedge = true },
		{ size = Vector3.one * 1.1, color = W.Sunny, offset = CFrame.new(0, 3.3, 0), shape = Enum.PartType.Ball },
	}
	self:prop("marker", items, function()
		local player = Players.LocalPlayer
		local char = player and player.Character
		local root = char and char:FindFirstChild("HumanoidRootPart")
		if root and root:IsA("BasePart") then
			return CFrame.new(root.CFrame.Position + Vector3.new(0, 8, 0))
		end
		return nil
	end, function(age)
		return CFrame.new(0, math.abs(math.sin(age * 3)) * 0.8, 0) * CFrame.Angles(0, age * 1.4, 0)
	end, nil, false)
end

-- Dumbbell --------------------------------------------------------------------------

function Effects.dumbbellRattle(self: Effects, seconds: number)
	self.dbRattleUntil = self.clock + seconds
end

-- Where the dumbbell lies on the floor below `pos` (bar along the stage Z axis).
function Effects.restFrame(self: Effects, pos: Vector3): CFrame
	local local_ = self.stage:PointToObjectSpace(pos)
	return self.stage * CFrame.new(local_.X, PLATE / 2, local_.Z) * CFrame.Angles(0, math.rad(90), 0)
end

function Effects.dumbbellDrop(self: Effects, instant: boolean?)
	local current = self.dumbbell:GetPivot()
	local rest = self:restFrame(current.Position)
	if instant then
		self.dbState = "rest"
		self.dumbbell:PivotTo(rest)
		return
	end
	self.dbState = "drop"
	self.dbFrom = current
	self.dbTo = rest
	self.dbStart = self.clock
	self.dbDur = 0.6
end

-- Rolls along the floor to the stage-local ground point `to` (studs).
function Effects.dumbbellRoll(self: Effects, to: Vector3, seconds: number, instant: boolean?)
	if self.dbState == "held" or self.dbState == "drop" then
		self:dumbbellDrop(true)
	end
	local from = self.dumbbell:GetPivot()
	local target = self.stage * CFrame.new(to.X, PLATE / 2, to.Z)
	local delta = target.Position - from.Position
	local flat = Vector3.new(delta.X, 0, delta.Z)
	if flat.Magnitude < 0.01 then
		return
	end
	-- Bar across the direction of travel; it spins about up x direction.
	local dir = flat.Unit
	local rot = CFrame.lookAt(Vector3.zero, dir)
	self.dbAxis = Vector3.yAxis:Cross(dir).Unit
	self.dbFrom = CFrame.new(from.Position) * rot
	self.dbTo = CFrame.new(target.Position) * rot
	if instant then
		self.dbState = "rest"
		self.dumbbell:PivotTo(self.dbTo)
		return
	end
	self.dbState = "roll"
	self.dbStart = self.clock
	self.dbDur = seconds
end

-- Frame update -----------------------------------------------------------------------

-- `hand` is the hero's right-hand frame (the held dumbbell follows it).
function Effects.update(self: Effects, dt: number, hand: CFrame?)
	self.clock += dt
	local now = self.clock

	-- Dumbbell.
	if self.dbState == "held" then
		if hand then
			local cf = hand
			if now < self.dbRattleUntil then
				local k = (self.dbRattleUntil - now) * 2
				cf *= CFrame.Angles(
					math.rad(math.sin(now * 61) * 14 * math.min(k, 1)),
					0,
					math.rad(math.sin(now * 47) * 10 * math.min(k, 1))
				)
			end
			self.dumbbell:PivotTo(cf)
		end
	elseif self.dbState == "drop" then
		local u = math.clamp((now - self.dbStart) / self.dbDur, 0, 1)
		local from, to = self.dbFrom, self.dbTo
		local turn = from:Lerp(to, math.min(1, u * 1.6))
		local xz = from.Position:Lerp(to.Position, u)
		local y = from.Position.Y + (to.Position.Y - from.Position.Y) * bounceOut(u)
		self.dumbbell:PivotTo(turn.Rotation + Vector3.new(xz.X, y, xz.Z))
		if u >= 1 then
			self.dbState = "rest"
		end
	elseif self.dbState == "roll" then
		local u = math.clamp((now - self.dbStart) / self.dbDur, 0, 1)
		local eased = 1 - (1 - u) * (1 - u)
		local pos = self.dbFrom.Position:Lerp(self.dbTo.Position, eased)
		local dist = (pos - self.dbFrom.Position).Magnitude
		local spin = CFrame.fromAxisAngle(self.dbAxis, dist / (PLATE / 2))
		self.dumbbell:PivotTo(CFrame.new(pos) * spin * self.dbFrom.Rotation)
		if u >= 1 then
			self.dbState = "rest"
		end
	end

	-- Aura trail sparkles bob gently.
	for _, item in self.trail do
		item.part.CFrame = CFrame.new(item.base + Vector3.new(0, math.sin(now * 2.4 + item.phase) * 0.12, 0))
	end

	-- Live props (a failing anchor drops its prop instead of breaking the frame).
	for i = #self.live, 1, -1 do
		local ok, keep = pcall(self.live[i], now, dt)
		if not ok or not keep then
			table.remove(self.live, i)
		end
	end
end

function Effects.destroy(self: Effects)
	table.clear(self.live)
	table.clear(self.handles)
	self.folder:Destroy()
end

return Effects
