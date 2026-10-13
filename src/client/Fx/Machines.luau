-- Client-side machine juice for the local player's own plot, painted from Theme.World (no glow
-- except the converter's level bands):
--   * Deposit: aura orbs stream into the blender's lid, which hops on a soft spring; the
--     multiplier's cash pops up as "+$X BONUS" and its coins hop to the Collect pad.
--   * Jar meter: a grape fill rises up the cup with the queue (TUNE.jar.fullSeconds of work fills
--     it) and the cup wears a glowing band per TUNE.ring.levels converter levels.
--   * Blender blades spin up while the queue has orbs; the smoothie swirls and coins hop from
--     the blender to the Collect pad. The processor's cups ride the belt and its dots fill up.
--   * A coin stack on the Collect pad grows with pending cash; collecting hops the coins into
--     the piggy bank, which bounces and throws a coin fountain that flies to the wallet.
--   * Pads you can use right now (affordable / ready) breathe slowly brighter and back.
--   * A successful pad step (buy, deposit, collect, upgrade) presses the pad's top into its rim
--     and springs it back, with a ring; a refused one wobbles it.
--   * Upgrade / buy / deny feedback: dust puffs, confetti, stars, coins; a buy's price is a
--     small red line over the wallet; a converter upgrade sends orbs from the pad to the jar.
--   * Crate Smasher: a local crate rattles as its timer runs out; when ready the striker puck
--     rides up its track, the bell rings and a READY! card pops up.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Theme = require(ReplicatedStorage:WaitForChild("Theme"))
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared:WaitForChild("Net"))
local Format = require(Shared:WaitForChild("Format"))
local Economy = require(Shared:WaitForChild("Economy"))

local Client = script.Parent.Parent
local State = require(Client.State)
local Sounds = require(Client.Sounds)
local Orbs = require(script.Parent.Orbs)
local Camera = require(script.Parent.Camera)
local Budget = require(script.Parent.Budget)

local player = Players.LocalPlayer
local C = Theme.Colors
local WORLD = (Theme :: any).World or {}
local WHITE = Color3.new(1, 1, 1)
local FAR = CFrame.new(0, -10000, 0)
local UPRIGHT = CFrame.Angles(0, 0, math.pi / 2)
local UP = Vector3.yAxis

local function worldColor(key: string, fallback: Color3): Color3
	return WORLD[key] or fallback
end

-- Palette: teal/blue dominant, sunny the accent, coral the sparing pop; grape is the aura
-- colour (orbs going into the converter).
local INK = worldColor("Ink", Color3.fromRGB(58, 48, 96))
local CREAM = worldColor("Cream", WHITE)
local SUNNY = worldColor("Sunny", C.Primary)
local TEAL = worldColor("Teal", C.Good)
local TEAL_LIGHT = worldColor("TealLight", C.Good)
local CORAL = worldColor("Coral", C.Bad)
local BLUE = worldColor("Blue", C.Secondary)
local GRAPE = worldColor("Grape", C.Orb)
local CONFETTI_COLORS = { SUNNY, TEAL_LIGHT, BLUE, SUNNY, WHITE, CORAL }

-- Tunables of the buy / deposit / collect / upgrade feedback and the jar meter. One table, not
-- a local each: a chunk holds 200 locals at most.
local TUNE = {
	-- Pad press: a successful step squashes the pad's top into its rim and springs it back.
	press = {
		depth = 0.6, -- share of the top's thickness lost at full squash
		wide = 0.05, -- footprint growth at full squash (it narrows on the rebound)
		lift = 0.25, -- studs the top lifts per unit of rebound (the stretch)
		stiffness = 420,
		damping = 15,
		time = 0.8, -- seconds until the pad is put back exactly
		ring = 1.15, -- pulse ring radius / the pad's half width
		ringTime = 0.45,
	},
	-- Jar meter: the grape sleeve that rises up the cup with the queue.
	jar = {
		fullSeconds = 120, -- queue time that fills the cup to the lid
		radius = 2.68, -- sleeve radius (the cup is 2.42 to 2.62 studs outside)
		height = 5.4, -- sleeve height when full (it stops under the lid rim)
		min = 0.15, -- sliver shown while anything is queued
		follow = 3, -- how fast the level follows the queue (per second)
		transparency = 0.15,
		foam = 0.16, -- height of the light line on top of the fill
		hold = 0.45, -- seconds a deposit's rise waits for its first orb to land
		gulp = 0.6, -- studs the level jumps per stud of lid hop
	},
	-- Level bands around the cup.
	ring = {
		levels = 5, -- converter levels per band
		max = 6,
		radius = 2.86,
		thick = 0.2,
		first = 0.75, -- first band above the cup floor
		step = 0.85, -- between bands
		transparency = 0.1,
		pulse = 0.6, -- how much thicker a band gets as the working pulse passes it
		kick = 0.2, -- radius growth per unit of the upgrade bounce
		kickSpeed = 6, -- bounce an upgrade gives the bands
		popTime = 0.35,
		-- Past `max` bands the set is earned again in the next colour.
		colors = { SUNNY, CORAL, WHITE },
	},
	upgrade = {
		orbs = 5, -- orbs that fly from the pad into the cup
		textScale = 0.8, -- "LEVEL N" over the lid
	},
	deposit = {
		stream = 0.8, -- seconds over which the orbs leave the player
		flight = 0.5, -- seconds each orb flies
		orb = 0.9, -- orb size leaving the player (half of it on arrival)
		bonusTextScale = 0.9,
		bonusCoins = 5, -- coins that hop from the lid to the Collect pad with a bonus
	},
	collect = {
		coins = 10, -- fountain coins (a few more for big amounts, at most 16)
		coinSize = 1.2, -- studs
		coinSpeed = 17, -- launch speed
		coinLife = 0.8, -- seconds; the coins turn for the wallet at 60 % of it
		textScale = 0.9,
	},
	buy = {
		coins = 6, -- coins from the pad (one more per digit of the price, at most 12)
		coinSpeed = 15, -- launch speed (up to 1.5x for big prices)
		stars = 3,
	},
}

local Machines = {}

local fxFolder: Instance = nil :: any

local function newPart(shape: Enum.PartType, name: string, color: Color3, size: Vector3): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Shape = shape
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Material = Enum.Material.SmoothPlastic
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Color = color
	p.Size = size
	p.CFrame = FAR
	p.Parent = fxFolder
	return p
end

local function play(name: string, jitter: number?, mult: number?)
	(Sounds.play :: any)(name, jitter, mult)
end

-- Easing and springs ----------------------------------------------------------------------------

local function easeOutQuad(t: number): number
	return 1 - (1 - t) * (1 - t)
end

local function easeOutBack(t: number): number
	local c1 = 1.70158
	local u = t - 1
	return 1 + (c1 + 1) * u * u * u + c1 * u * u
end

type Spring = { x: number, v: number }

-- Damped spring toward 0, sub-stepped so a long frame cannot blow it up.
local function stepSpring(s: Spring, dt: number, stiffness: number, damping: number)
	local steps = math.clamp(math.ceil(dt * 120), 1, 8)
	local h = dt / steps
	for _ = 1, steps do
		s.v += (-stiffness * s.x - damping * s.v) * h
		s.x += s.v * h
	end
end

-- Particles: confetti, hopping coins, stars and dust puffs ------------------------------------

type Confetto = {
	part: Part,
	pos: Vector3,
	vel: Vector3,
	rot: CFrame,
	spin: Vector3,
	t0: number,
	life: number,
}

local MAX_CONFETTI = 90
local confetti: { Confetto } = {}
local confettiPool: { Part } = {}

local function confettiBurst(pos: Vector3, count: number, power: number?, colors: { Color3 }?)
	local palette = colors or CONFETTI_COLORS
	local k = power or 1
	local now = os.clock()
	local cap = Budget.count(MAX_CONFETTI) -- fewer on phones (Fx.Budget)
	for i = 1, Budget.count(count) do
		if #confetti >= cap then
			break
		end
		local part = table.remove(confettiPool) or newPart(Enum.PartType.Block, "Confetti", WHITE, Vector3.new(0.34, 0.07, 0.24))
		part.Color = palette[(i - 1) % #palette + 1]
		part.Transparency = 0
		local a = math.random() * math.pi * 2
		local out = Vector3.new(math.cos(a), 0, math.sin(a))
		table.insert(confetti, {
			part = part,
			pos = pos,
			vel = out * (2.5 + math.random() * 4.5) * k + UP * (8 + math.random() * 6) * k,
			rot = CFrame.Angles(math.random() * 6, math.random() * 6, math.random() * 6),
			spin = Vector3.new(math.random() - 0.5, math.random() - 0.5, math.random() - 0.5) * 14,
			t0 = now,
			life = 1.1 + math.random() * 0.6,
		})
	end
end

local function stepConfetti(dt: number, now: number)
	if #confetti == 0 then
		return
	end
	local parts, cframes = {}, {}
	local drag = math.exp(-dt * 2.4)
	for i = #confetti, 1, -1 do
		local c = confetti[i]
		local age = now - c.t0
		if age >= c.life then
			c.part.CFrame = FAR
			table.insert(confettiPool, c.part)
			table.remove(confetti, i)
			continue
		end
		-- Drag, gravity and a capped, swaying fall so pieces flutter down.
		local vy = math.max(c.vel.Y * drag - 24 * dt, -4.5)
		c.vel = Vector3.new(c.vel.X * drag, vy, c.vel.Z * drag)
		c.pos += c.vel * dt + Vector3.new(math.sin(now * 5 + i) * 0.8 * dt, 0, 0)
		c.rot *= CFrame.Angles(c.spin.X * dt, c.spin.Y * dt, c.spin.Z * dt)
		c.part.Transparency = math.clamp((age - c.life * 0.65) / (c.life * 0.35), 0, 1)
		table.insert(parts, c.part)
		table.insert(cframes, CFrame.new(c.pos) * c.rot)
	end
	if #parts > 0 then
		Workspace:BulkMoveTo(parts, cframes, Enum.BulkMoveMode.FireCFrameChanged)
	end
end

type Hop = {
	part: Part,
	from: Vector3,
	ctrl: Vector3,
	to: Vector3,
	t0: number,
	dur: number,
	s0: number,
	s1: number,
	turn: number,
	onDone: (() -> ())?,
}

type HopOptions = {
	from: Vector3,
	to: Vector3,
	delay: number?,
	duration: number?,
	arc: number?,
	size: number?,
	endSize: number?,
	color: Color3?,
	onDone: (() -> ())?,
}

local MAX_HOPS = 40
local hops: { Hop } = {}
local hopPool: { Part } = {}

-- A small coin that hops along an arc (spinning on its edge) and calls onDone on landing.
local function hop(opts: HopOptions)
	if #hops >= MAX_HOPS then
		if opts.onDone then
			opts.onDone()
		end
		return
	end
	local part = table.remove(hopPool) or newPart(Enum.PartType.Cylinder, "CoinHop", SUNNY, Vector3.new(0.18, 1, 1))
	part.Color = opts.color or SUNNY
	part.Transparency = 0
	local mid = opts.from:Lerp(opts.to, 0.5)
	table.insert(hops, {
		part = part,
		from = opts.from,
		ctrl = Vector3.new(mid.X, math.max(opts.from.Y, opts.to.Y) + (opts.arc or 3), mid.Z),
		to = opts.to,
		t0 = os.clock() + (opts.delay or 0),
		dur = opts.duration or 0.6,
		s0 = opts.size or 0.9,
		s1 = opts.endSize or opts.size or 0.9,
		turn = (math.random() * 2 - 1) * 4 + 8,
		onDone = opts.onDone,
	})
end

local function stepHops(now: number)
	for i = #hops, 1, -1 do
		local h = hops[i]
		local t = (now - h.t0) / h.dur
		if t < 0 then
			continue
		end
		if t >= 1 then
			h.part.CFrame = FAR
			table.insert(hopPool, h.part)
			table.remove(hops, i)
			if h.onDone then
				task.spawn(h.onDone)
			end
			continue
		end
		local u = 1 - t
		local pos = h.from * (u * u) + h.ctrl * (2 * u * t) + h.to * (t * t)
		local s = h.s0 + (h.s1 - h.s0) * t
		h.part.Size = Vector3.new(0.18, s, s)
		h.part.CFrame = CFrame.new(pos) * CFrame.Angles(0, (now - h.t0) * h.turn, 0)
	end
end

type Star = {
	anchor: Part,
	gui: BillboardGui,
	label: TextLabel,
	stroke: UIStroke,
	from: Vector3,
	drift: Vector3,
	t0: number,
	life: number,
	size: number,
	turn: number,
}

local MAX_STARS = 14
local stars: { Star } = {}
local starPool: { Star } = {}

local function newStar(): Star
	local anchor = newPart(Enum.PartType.Block, "StarAnchor", WHITE, Vector3.new(0.1, 0.1, 0.1))
	anchor.Transparency = 1
	local gui = Instance.new("BillboardGui")
	gui.Name = "Star"
	gui.LightInfluence = 0
	gui.MaxDistance = 45
	gui.Size = UDim2.fromScale(1, 1)
	gui.Enabled = false
	gui.Adornee = anchor
	gui.Parent = anchor
	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromScale(1, 1)
	label.AnchorPoint = Vector2.new(0.5, 0.5)
	label.Position = UDim2.fromScale(0.5, 0.5)
	label.Font = Theme.Fonts.UI
	label.TextScaled = true
	label.Text = "★"
	label.Parent = gui
	local stroke = Instance.new("UIStroke")
	stroke.Color = WHITE
	stroke.Thickness = 2
	stroke.Parent = label
	return {
		anchor = anchor,
		gui = gui,
		label = label,
		stroke = stroke,
		from = Vector3.zero,
		drift = Vector3.zero,
		t0 = 0,
		life = 1,
		size = 1,
		turn = 0,
	}
end

-- A few stars pop out (Back ease), float up and fade.
local function starBurst(pos: Vector3, count: number, color: Color3?)
	local now = os.clock()
	local cap = Budget.count(MAX_STARS)
	for i = 1, Budget.count(count) do
		if #stars >= cap then
			break
		end
		local star = table.remove(starPool) or newStar()
		local a = math.random() * math.pi * 2
		local out = Vector3.new(math.cos(a), 0, math.sin(a))
		star.from = pos + out * 0.4
		star.drift = out * (1.2 + math.random() * 1.5) + UP * (2.2 + math.random() * 1.6)
		star.t0 = now + (i - 1) * 0.06
		star.life = 0.85 + math.random() * 0.3
		star.size = 0.9 + math.random() * 0.5
		star.turn = (math.random() * 2 - 1) * 90
		star.label.TextColor3 = color or CONFETTI_COLORS[(i - 1) % 3 + 1]
		star.anchor.CFrame = CFrame.new(star.from)
		table.insert(stars, star)
	end
end

local function stepStars(now: number)
	for i = #stars, 1, -1 do
		local star = stars[i]
		local age = now - star.t0
		if age < 0 then
			continue
		end
		local t = age / star.life
		if t >= 1 then
			star.gui.Enabled = false
			star.anchor.CFrame = FAR
			table.insert(starPool, star)
			table.remove(stars, i)
			continue
		end
		local grow = easeOutBack(math.min(1, t / 0.25))
		local fade = math.clamp((t - 0.6) / 0.4, 0, 1)
		local s = star.size * grow
		star.gui.Enabled = true
		star.gui.Size = UDim2.fromScale(s, s)
		star.anchor.CFrame = CFrame.new(star.from + star.drift * easeOutQuad(t))
		star.label.Rotation = star.turn * t
		star.label.TextTransparency = fade
		star.stroke.Transparency = fade
	end
end

local puffPool: { Part } = {}

-- A soft ring of cartoon dust balls that spread out, grow and fade.
local function puff(pos: Vector3, color: Color3?, radius: number?, count: number?)
	local n = count or 10
	local r = radius or 3
	local tint = (color or CREAM):Lerp(WHITE, 0.4)
	local size = math.clamp(r * 0.22, 0.5, 1.4)
	for i = 1, n do
		local ball = table.remove(puffPool) or newPart(Enum.PartType.Ball, "Puff", WHITE, Vector3.one)
		local a = (i / n) * math.pi * 2 + math.random() * 0.3
		local dir = Vector3.new(math.cos(a), 0, math.sin(a))
		local s = size * (0.8 + math.random() * 0.4)
		ball.Color = tint
		ball.Transparency = 0.15
		ball.Size = Vector3.one * s * 0.4
		ball.CFrame = CFrame.new(pos + dir * r * 0.2)
		local tween = TweenService:Create(
			ball,
			TweenInfo.new(0.4 + math.random() * 0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ CFrame = CFrame.new(pos + dir * r + UP * (0.3 + math.random() * 0.4)), Size = Vector3.one * s, Transparency = 1 }
		)
		tween.Completed:Once(function()
			ball.CFrame = FAR
			table.insert(puffPool, ball)
		end)
		tween:Play()
	end
end

-- Plot parts --------------------------------------------------------------------------------

local plot: Instance? = nil
local collectPad: BasePart? = nil
local pads: { BasePart } = {}
local holos: { [number]: BasePart } = {}

local function padTop(pad: BasePart): Vector3
	local thickness = if (pad :: Part).Shape == Enum.PartType.Cylinder then pad.Size.X else pad.Size.Y
	return pad.Position + Vector3.new(0, thickness / 2, 0)
end

-- The own pad an effect is about: by `name`, else the nearest within 6 studs of `padPos`.
local function findPad(data: any): BasePart?
	local p = plot
	if not p then
		return nil
	end
	if type(data.name) == "string" then
		local named = p:FindFirstChild("Pad_" .. data.name) or p:FindFirstChild(data.name)
		if named and named:IsA("BasePart") then
			return named
		end
	end
	if typeof(data.padPos) == "Vector3" then
		local best, bestDist = nil, 6
		for _, pad in pads do
			local d = (pad.Position - data.padPos).Magnitude
			if d < bestDist then
				best, bestDist = pad, d
			end
		end
		return best
	end
	return nil
end

-- Pad press: a successful step squashes the pad's top into its rim and springs it back -----------

type Squash = { cf: CFrame, size: Vector3, spring: Spring, t0: number }

local squashes: { [BasePart]: Squash } = {}
local denyToken: { [BasePart]: number } = {} -- pads in a deny wobble (it owns their CFrame)

local function endSquash(pad: BasePart)
	local s = squashes[pad]
	if not s then
		return
	end
	squashes[pad] = nil
	if pad.Parent then
		pad.Size = s.size
		pad.CFrame = s.cf
	end
end

-- Presses `pad` (from its resting size, also when it is still springing) and rings it.
local function squashPad(pad: BasePart, color: Color3?)
	if denyToken[pad] then
		return
	end
	local s = squashes[pad]
	if s then
		s.spring.x, s.spring.v, s.t0 = 1, 0, os.clock()
	else
		local fresh: Squash = { cf = pad.CFrame, size = pad.Size, spring = { x = 1, v = 0 }, t0 = os.clock() }
		squashes[pad] = fresh
		s = fresh
	end
	local round = (pad :: Part).Shape == Enum.PartType.Cylinder
	local thick = if round then s.size.X else s.size.Y
	local half = if round then s.size.Y / 2 else math.max(s.size.X, s.size.Z) / 2
	Orbs.ring(s.cf.Position + UP * (thick / 2 + 0.05), color or WHITE, half * TUNE.press.ring, TUNE.press.ringTime)
end

local function stepSquash(dt: number, now: number)
	for pad, s in squashes do
		local spring = s.spring
		stepSpring(spring, dt, TUNE.press.stiffness, TUNE.press.damping)
		local still = math.abs(spring.x) < 0.003 and math.abs(spring.v) < 0.05
		if still or not pad.Parent or denyToken[pad] or now - s.t0 > TUNE.press.time then
			endSquash(pad)
			continue
		end
		local x = math.clamp(spring.x, -0.6, 1)
		local round = (pad :: Part).Shape == Enum.PartType.Cylinder
		local thick = if round then s.size.X else s.size.Y
		local t = thick * (1 - TUNE.press.depth * x)
		local wide = 1 + TUNE.press.wide * x
		pad.Size = if round then Vector3.new(t, s.size.Y * wide, s.size.Z * wide) else Vector3.new(s.size.X * wide, t, s.size.Z * wide)
		-- The bottom stays on the rim; the rebound lifts the whole top a little.
		pad.CFrame = s.cf + UP * ((t - thick) / 2 + math.max(0, -x) * TUNE.press.lift)
	end
end

local function childrenNamed(p: Instance, name: string): { BasePart }
	local out = {}
	for _, child in p:GetChildren() do
		if child:IsA("BasePart") and child.Name == name then
			table.insert(out, child)
		end
	end
	return out
end

local function modelParts(model: Instance): ({ BasePart }, { CFrame })
	local parts, bases = {}, {}
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then
			table.insert(parts, d)
			table.insert(bases, d.CFrame)
		end
	end
	return parts, bases
end

local function converterActive(): boolean
	local data = State.data
	return data ~= nil and (tonumber(data.queue) or 0) > 0
end

-- Converter (blender) -------------------------------------------------------------------------

local core: BasePart? = nil
local spinParts: { BasePart } = {}
local spinBase: { CFrame } = {}
local spinAxis = Vector3.zero
local lidParts: { BasePart } = {}
local lidBase: { CFrame } = {}
local juice: BasePart? = nil
local juiceCF = CFrame.identity
local juiceSize = Vector3.one
local intake: BasePart? = nil

local spin = 0
local spinSpeed = 0.4
local glow = 0
local lid: Spring = { x = 0, v = 0 }
local nextCoinHop = 0

local function bindConverter(p: Instance)
	table.clear(spinParts)
	table.clear(spinBase)
	table.clear(lidParts)
	table.clear(lidBase)
	local c = p:FindFirstChild("ConverterCore") :: BasePart?
	core = c
	if c then
		spinAxis = c.CFrame.Position
		table.insert(spinParts, c)
		for _, blade in childrenNamed(p, "ConverterBlade") do
			table.insert(spinParts, blade)
		end
		for i, part in spinParts do
			spinBase[i] = part.CFrame
		end
	end
	for _, name in { "ConverterLid", "ConverterLidRim", "ConverterIntake", "ConverterIntakeTop" } do
		for _, part in childrenNamed(p, name) do
			table.insert(lidParts, part)
			table.insert(lidBase, part.CFrame)
		end
	end
	intake = p:FindFirstChild("ConverterIntake") :: BasePart?
	juice = p:FindFirstChild("ConverterJuice") :: BasePart?
	if juice then
		juiceCF = juice.CFrame
		juiceSize = juice.Size
	end
end

local function stepConverter(dt: number, now: number)
	local c = core
	if not c or not c.Parent then
		return
	end
	local active = converterActive()
	spinSpeed += ((if active then 10 else 0.4) - spinSpeed) * math.min(1, dt * 2)
	spin = (spin + spinSpeed * dt) % (math.pi * 2)
	glow += ((if active then 1 else 0) - glow) * math.min(1, dt * 3)
	stepSpring(lid, dt, 260, 14)

	local parts, cframes = {}, {}
	local rot = CFrame.new(spinAxis) * CFrame.Angles(0, spin, 0) * CFrame.new(-spinAxis)
	for i, part in spinParts do
		table.insert(parts, part)
		table.insert(cframes, rot * spinBase[i])
	end
	-- The lid rattles softly while blending and hops on the spring after deposits.
	local lift = lid.x + glow * 0.035 * math.sin(now * 23)
	for i, part in lidParts do
		table.insert(parts, part)
		table.insert(cframes, lidBase[i] + UP * lift)
	end
	Workspace:BulkMoveTo(parts, cframes, Enum.BulkMoveMode.FireCFrameChanged)

	-- The smoothie rises and swirls while blending.
	local j = juice
	if j and j.Parent then
		local h = juiceSize.X * (1 + glow * (0.14 + math.sin(now * 3.2) * 0.04) + math.max(0, lid.x) * 0.3)
		j.Size = Vector3.new(h, juiceSize.Y, juiceSize.Z)
		j.CFrame = juiceCF + UP * ((h - juiceSize.X) / 2)
	end

	-- Fresh coins hop from the blender to the Collect pad while it works.
	if active and collectPad and now >= nextCoinHop then
		nextCoinHop = now + 1.3
		hop({
			from = spinAxis + UP * 2,
			to = padTop(collectPad) + UP * 0.6,
			duration = 1,
			arc = 5,
			size = 0.9,
			endSize = 0.6,
		})
	end
end

-- Jar meter: the cup fills with the queue and wears a glow band per 5 converter levels ----------
-- The mesh cup is solid, so the smoothie inside it cannot be seen: a grape sleeve just outside
-- the cup rises from its floor with the queue's seconds, and the level bands ring the cup.

type Jar = {
	floor: CFrame?, -- the cup floor on the cup's axis (an upright cylinder's frame)
	fill: Part?,
	foam: Part?,
	level: number, -- shown fill, 0..1
	shown: number, -- sleeve height last written
	holdUntil: number,
	rings: { Part },
	ringColor: { number }, -- TUNE.ring.colors index each band wears (0 = hidden)
	ringBusy: { number }, -- os.clock() until which a band's pop tween owns it
	ringLevel: number,
	kick: Spring,
	rest: boolean,
}

local jar: Jar = {
	floor = nil,
	fill = nil,
	foam = nil,
	level = 0,
	shown = -1,
	holdUntil = 0,
	rings = {},
	ringColor = {},
	ringBusy = {},
	ringLevel = -1,
	kick = { x = 0, v = 0 },
	rest = true,
}

local function bindJar()
	jar.floor = if juice then juiceCF - UP * (juiceSize.X / 2) elseif core then spinBase[1] - UP * 0.55 else nil
	jar.shown = -1
	jar.ringLevel = -1
	if jar.fill then
		jar.fill.CFrame = FAR
	end
	if jar.foam then
		jar.foam.CFrame = FAR
	end
	for k, ring in jar.rings do
		ring.CFrame = FAR
		jar.ringColor[k] = 0
	end
end

-- Seconds of work left in the queue: the snapshot's `queueSeconds` when the server sends it,
-- else queue / rate; counted down between snapshots.
local function queueSeconds(): number
	local data = State.data
	if not data then
		return 0
	end
	local seconds = tonumber(data.queueSeconds)
	if not seconds then
		local rate = tonumber(data.processRate) or 0
		seconds = if rate > 0 then (tonumber(data.queue) or 0) / rate else 0
	end
	if seconds ~= seconds or seconds <= 0 then
		return 0
	end
	return math.max(0, math.min(seconds, 1e6) - State.age())
end

local function setRing(k: number, colorIndex: number, floor: CFrame, pop: boolean)
	local existing = jar.rings[k]
	if colorIndex == 0 then
		if existing then
			existing.CFrame = FAR
		end
		return
	end
	local d = TUNE.ring.radius * 2
	local ring = existing or newPart(Enum.PartType.Cylinder, "JarRing", WHITE, Vector3.new(TUNE.ring.thick, d, d))
	jar.rings[k] = ring
	ring.Material = Enum.Material.Neon
	ring.Color = TUNE.ring.colors[colorIndex]
	ring.CFrame = floor + UP * (TUNE.ring.first + (k - 1) * TUNE.ring.step)
	if not pop then
		ring.Size = Vector3.new(TUNE.ring.thick, d, d)
		ring.Transparency = TUNE.ring.transparency
		return
	end
	-- A new band shrinks onto the cup out of a wider, fading one.
	jar.ringBusy[k] = os.clock() + TUNE.ring.popTime + 0.05
	ring.Size = Vector3.new(TUNE.ring.thick, d * 1.3, d * 1.3)
	ring.Transparency = 1
	TweenService:Create(
		ring,
		TweenInfo.new(TUNE.ring.popTime, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
		{ Size = Vector3.new(TUNE.ring.thick, d, d), Transparency = TUNE.ring.transparency }
	):Play()
	Orbs.sparkle(ring.Position, ring.Color, 8)
end

local function syncRings(level: number, floor: CFrame, pop: boolean)
	local bands = math.floor(level / TUNE.ring.levels)
	local lap = math.min(math.floor(bands / TUNE.ring.max), #TUNE.ring.colors - 1)
	local inLap = math.min(bands - lap * TUNE.ring.max, TUNE.ring.max)
	for k = 1, TUNE.ring.max do
		local want = if k <= inLap then lap + 1 else lap
		if want ~= (jar.ringColor[k] or 0) then
			jar.ringColor[k] = want
			setRing(k, want, floor, pop)
		end
	end
end

local function stepJar(dt: number, now: number)
	local floor = jar.floor
	if not floor then
		return
	end
	-- Fill: follows the queue's seconds; a deposit's rise waits for its first orb.
	local target = math.clamp(queueSeconds() / TUNE.jar.fullSeconds, 0, 1)
	if now < jar.holdUntil then
		target = math.min(target, jar.level)
	end
	jar.level += (target - jar.level) * math.min(1, dt * TUNE.jar.follow)
	if math.abs(target - jar.level) < 0.001 then
		jar.level = target
	end
	local h = 0
	if jar.level > 0 then
		local slosh = glow * math.sin(now * 3.2) * 0.03 + math.max(0, lid.x) * TUNE.jar.gulp
		h = math.min(math.max(TUNE.jar.min, jar.level * TUNE.jar.height) + slosh, TUNE.jar.height + 0.1)
	end
	if math.abs(h - jar.shown) > 0.004 then
		jar.shown = h
		local d = TUNE.jar.radius * 2
		local fill = jar.fill or newPart(Enum.PartType.Cylinder, "JarFill", GRAPE:Lerp(WHITE, 0.1), Vector3.new(1, d, d))
		local foam = jar.foam
			or newPart(Enum.PartType.Cylinder, "JarFoam", GRAPE:Lerp(WHITE, 0.6), Vector3.new(TUNE.jar.foam, d + 0.1, d + 0.1))
		jar.fill, jar.foam = fill, foam
		if h <= 0 then
			fill.CFrame = FAR
			foam.CFrame = FAR
		else
			fill.Transparency = TUNE.jar.transparency
			fill.Size = Vector3.new(h, d, d)
			fill.CFrame = floor + UP * (h / 2)
			foam.CFrame = floor + UP * (h + TUNE.jar.foam / 2 - 0.02)
		end
	end

	-- Level bands: synced when the level changes; a new band pops in.
	local data = State.data
	local level = if data then math.floor(tonumber(data.processLevel) or 0) else 0
	if level ~= jar.ringLevel then
		syncRings(level, floor, jar.ringLevel >= 0 and level > jar.ringLevel)
		jar.ringLevel = level
	end
	-- A pulse climbs the bands while the converter works; upgrades bounce them outward.
	stepSpring(jar.kick, dt, 220, 12)
	local moving = glow > 0.02 or math.abs(jar.kick.x) > 0.002 or math.abs(jar.kick.v) > 0.02
	if moving or not jar.rest then
		jar.rest = not moving
		for k, ring in jar.rings do
			if (jar.ringColor[k] or 0) == 0 or now < (jar.ringBusy[k] or 0) then
				continue
			end
			local wave = if moving then glow * (0.5 + 0.5 * math.sin(now * 4 - k * 0.9)) else 0
			local d = TUNE.ring.radius * 2 * (1 + (if moving then jar.kick.x * TUNE.ring.kick else 0))
			ring.Size = Vector3.new(TUNE.ring.thick * (1 + TUNE.ring.pulse * wave), d, d)
		end
	end
end

-- A converter upgrade: orbs fly from the pad into the cup, the bands bounce and the new level
-- pops up over the lid.

local function upgradeJar(from: Vector3, level: number?)
	local floor = jar.floor
	if not floor then
		return
	end
	local base = floor.Position
	local n = Budget.count(TUNE.upgrade.orbs)
	for i = 1, n do
		local jitter = Vector3.new(math.random() - 0.5, 0, math.random() - 0.5) * 1.5
		Orbs.fly({
			from = from + jitter,
			to = base + UP * 2.7,
			color = TEAL_LIGHT,
			size = 0.6,
			endSize = 0.3,
			duration = 0.45,
			delay = (i - 1) * 0.06,
			arc = 4,
			trail = true,
			onDone = if i == n
				then function()
					jar.kick.v += TUNE.ring.kickSpeed
					Orbs.sparkle(base + UP * 6.6, SUNNY, 10)
					if level then
						local text = "LEVEL " .. math.floor(level)
						Orbs.text(base + UP * 9.4, text, TEAL_LIGHT, { scale = TUNE.upgrade.textScale, rise = 1.8, life = 1.1 })
					end
				end
				else nil,
		})
	end
end

local function onDeposit(data: any)
	local to: Vector3? = if typeof(data.to) == "Vector3"
		then data.to
		elseif intake then intake.Position
		elseif core then core.Position
		else nil
	if not to then
		return
	end
	local pad = findPad({ name = "Deposit" })
	if pad then
		squashPad(pad, GRAPE)
	end
	jar.holdUntil = os.clock() + TUNE.jar.hold
	local from: Vector3 = if typeof(data.from) == "Vector3" then data.from else to + Vector3.new(0, 6, 6)
	local amount = tonumber(data.amount) or 0
	local count = Budget.count(math.clamp(8 + math.floor(math.log10(math.max(1, amount)) * 2), 8, 16))
	local first = true
	for i = 1, count do
		local jitter = Vector3.new(math.random() - 0.5, math.random() - 0.5, math.random() - 0.5) * 1.2
		Orbs.fly({
			from = from + jitter,
			to = to,
			color = if i % 4 == 0 then C.OrbBig else C.Orb,
			size = TUNE.deposit.orb,
			endSize = TUNE.deposit.orb / 2,
			duration = TUNE.deposit.flight,
			delay = (i - 1) * (TUNE.deposit.stream / count),
			arc = 3 + math.random() * 2,
			trail = true,
			onDone = function()
				lid.v = math.min(lid.v + 1.6, 6)
				if first then
					first = false
					puff(to, GRAPE, 1.6, 6)
				end
			end,
		})
	end
	task.delay(TUNE.deposit.stream + TUNE.deposit.flight - 0.1, function()
		lid.v += 4
		confettiBurst(to + UP * 0.5, 10, 0.8, { GRAPE, SUNNY, WHITE })
		starBurst(to + UP, 2, GRAPE)
		-- The multiplier's part is cash in the vault at once: name it and send its coins there.
		local bonus = tonumber(data.bonus) or 0
		if bonus < 1 then
			return
		end
		local text = "+" .. Format.money(bonus) .. " BONUS"
		Orbs.text(to + UP * 2.2, text, SUNNY, { scale = TUNE.deposit.bonusTextScale, rise = 2.2, life = 1.3 })
		local target = collectPad
		if target and target.Parent then
			for i = 1, Budget.count(TUNE.deposit.bonusCoins) do
				hop({
					from = to,
					to = padTop(target) + UP * 0.6,
					delay = (i - 1) * 0.07,
					duration = 0.8,
					arc = 5,
					size = 1,
					endSize = 0.7,
				})
			end
		end
	end)
end

-- Processor (juice-bar conveyor) ----------------------------------------------------------------

type Cup = { parts: { BasePart }, base: { CFrame }, z0: number }

local belt: BasePart? = nil
local cups: { Cup } = {}
local cupStart = 0
local cupCycle = 1
local beltEnd = 0
local lights: { BasePart } = {}
local lightBase: { Color3 } = {}
local beltOffset = 0
local beltSpeed = 0
local cupHop: Spring = { x = 0, v = 0 }
local lightFlash = 0

local function bindProcessor(p: Instance)
	table.clear(cups)
	table.clear(lights)
	table.clear(lightBase)
	local b = p:FindFirstChild("ProcessorBelt") :: BasePart?
	belt = b
	if not b then
		return
	end
	for _, child in p:GetChildren() do
		if child.Name == "ProcessorCup" then
			local parts, bases = modelParts(child)
			if #parts > 0 then
				table.insert(cups, { parts = parts, base = bases, z0 = b.CFrame:PointToObjectSpace(bases[1].Position).Z })
			end
		end
	end
	table.sort(cups, function(a, c)
		return a.z0 < c.z0
	end)
	if #cups >= 2 then
		cupStart = cups[1].z0
		cupCycle = (cups[#cups].z0 - cupStart) / (#cups - 1) * #cups
	end
	beltEnd = b.Size.Z / 2 - 0.5
	lights = childrenNamed(p, "ProcessorLight")
	table.sort(lights, function(a, c)
		return b.CFrame:PointToObjectSpace(a.Position).Z < b.CFrame:PointToObjectSpace(c.Position).Z
	end)
	for i, light in lights do
		lightBase[i] = light.Color
	end
end

local function stepProcessor(dt: number, now: number)
	local b = belt
	if not b or not b.Parent then
		return
	end
	local active = converterActive()
	beltSpeed += ((if active then 1.6 else 0) - beltSpeed) * math.min(1, dt * 2.5)
	beltOffset = (beltOffset + beltSpeed * dt) % cupCycle
	stepSpring(cupHop, dt, 240, 12)
	lightFlash = math.max(0, lightFlash - dt)

	if #cups >= 2 then
		local parts, cframes = {}, {}
		local along = b.CFrame:VectorToWorldSpace(Vector3.zAxis)
		for i, cup in cups do
			local z = cupStart + (cup.z0 - cupStart + beltOffset) % cupCycle
			-- Cups fade in under the jug and fade out at the end of the belt.
			local vis = math.clamp(math.min((z - cupStart) / 0.6, (beltEnd - z) / 0.6), 0, 1)
			local wobble = math.sin(now * 9 + i) * 0.03 * (beltSpeed / 1.6)
			local offset = along * (z - cup.z0) + UP * (cupHop.x + wobble)
			for k, part in cup.parts do
				part.LocalTransparencyModifier = 1 - vis
				table.insert(parts, part)
				table.insert(cframes, cup.base[k] + offset)
			end
		end
		Workspace:BulkMoveTo(parts, cframes, Enum.BulkMoveMode.FireCFrameChanged)
	end

	-- Progress dots fill up one by one while processing.
	local n = #lights
	local lit = if active then math.floor(((now * 0.9) % 1) * (n + 1)) else 0
	for i, light in lights do
		local on = lightFlash > 0 or i <= lit
		local target = if on then TEAL else lightBase[i]
		light.Color = light.Color:Lerp(target, math.min(1, dt * 10))
	end
end

-- Vault (piggy bank) ------------------------------------------------------------------------------

local pigParts: { BasePart } = {}
local pigBase: { CFrame } = {}
local vaultCoins: { BasePart } = {}
local vaultCoinBase: { CFrame } = {}
local slotPos: Vector3? = nil
local pigHop: Spring = { x = 0, v = 0 }
local coinDip: Spring = { x = 0, v = 0 }

local function bindVault(p: Instance)
	table.clear(pigParts)
	table.clear(pigBase)
	table.clear(vaultCoins)
	table.clear(vaultCoinBase)
	slotPos = nil
	for _, child in p:GetChildren() do
		if child:IsA("BasePart") and string.sub(child.Name, 1, 5) == "Piggy" then
			table.insert(pigParts, child)
			table.insert(pigBase, child.CFrame)
			if child.Name == "PiggySlot" then
				slotPos = child.Position
			end
		end
	end
	for _, name in { "Coin", "CoinRim" } do
		local part = p:FindFirstChild(name)
		if part and part:IsA("BasePart") then
			table.insert(vaultCoins, part)
			table.insert(vaultCoinBase, part.CFrame)
		end
	end
end

local function stepVault(dt: number, now: number)
	if #pigParts == 0 then
		return
	end
	stepSpring(pigHop, dt, 200, 11)
	stepSpring(coinDip, dt, 260, 13)
	local parts, cframes = {}, {}
	-- The pig breathes gently and bounces when it gets coins.
	local lift = math.sin(now * 1.7) * 0.04 + pigHop.x
	for i, part in pigParts do
		table.insert(parts, part)
		table.insert(cframes, pigBase[i] + UP * lift)
	end
	local sway = math.sin(now * 0.9) * 0.12
	for i, part in vaultCoins do
		local base = vaultCoinBase[i]
		local pos = base.Position + UP * (lift + coinDip.x + math.sin(now * 1.2) * 0.08)
		table.insert(parts, part)
		table.insert(cframes, CFrame.new(pos) * CFrame.Angles(0, sway, 0) * base.Rotation)
	end
	Workspace:BulkMoveTo(parts, cframes, Enum.BulkMoveMode.FireCFrameChanged)
end

-- Collect pad coin stack ----------------------------------------------------------------------

local MAX_COINS = 24
local coins: { Part } = {}
local coinHomes: { CFrame } = {}
local shownCoins = 0
local burstAt = 0

local function coinTarget(): number
	local data = State.data
	local pending = if data then tonumber(data.pending) or 0 else 0
	if pending < 1 or os.clock() - burstAt < 1 then
		return 0
	end
	return math.clamp(math.floor(math.log10(pending) * 5) + 1, 1, MAX_COINS)
end

local function coinHome(i: number, pad: BasePart): CFrame
	local col = (i - 1) % 3
	local layer = math.floor((i - 1) / 3)
	local offsets = { Vector3.new(-0.6, 0, -0.35), Vector3.new(0.6, 0, -0.35), Vector3.new(0, 0, 0.6) }
	local base = padTop(pad) + offsets[col + 1] + Vector3.new(0, 0.14 + layer * 0.26, 0)
	return CFrame.new(base) * CFrame.Angles(0, math.rad((i * 47) % 360), 0) * UPRIGHT
end

local function syncCoins()
	local pad = collectPad
	if not pad then
		return
	end
	local target = coinTarget()
	if target == shownCoins then
		return
	end
	if #coins == 0 then
		for i = 1, MAX_COINS do
			coins[i] = newPart(Enum.PartType.Cylinder, "Coin", SUNNY, Vector3.new(0.22, 1.05, 1.05))
			coinHomes[i] = FAR
		end
	end
	if target > shownCoins then
		for i = shownCoins + 1, target do
			local home = coinHome(i, pad)
			coinHomes[i] = home
			local coin = coins[i]
			coin.CFrame = home + Vector3.new(0, 1.6, 0)
			coin.Transparency = 1
			TweenService:Create(
				coin,
				TweenInfo.new(0.3, Enum.EasingStyle.Back, Enum.EasingDirection.Out, 0, false, (i - shownCoins - 1) * 0.04),
				{ CFrame = home, Transparency = 0 }
			):Play()
		end
	else
		for i = target + 1, shownCoins do
			coins[i].CFrame = FAR
			coinHomes[i] = FAR
		end
	end
	shownCoins = target
end

local lastShower = 0

-- Coin shower around the player: big for a purchased cash pack, modest otherwise.
local function cashShower(amount: number, big: boolean)
	local now = os.clock()
	if not big and now - lastShower < 2 then
		return
	end
	lastShower = now
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not root then
		return
	end
	local pos = root.Position
	local floor = pos.Y - 2.8
	local magnitude = math.log10(math.max(amount, 1))
	local feet = Vector3.new(pos.X, floor + 0.3, pos.Z)
	if big then
		puff(feet, SUNNY, 5, 14)
		starBurst(pos + UP * 2, 5, SUNNY)
		Camera.punch(0.5)
		play("CelebrateLegendary")
		Orbs.text(pos + Vector3.new(0, 5, 0), "+" .. Format.money(amount), SUNNY, { scale = 2.2, rise = 4, life = 1.8 })
		for wave = 0, 3 do
			task.delay(wave * 0.25, function()
				Orbs.coins(pos, {
					count = 10,
					speed = 6,
					spread = 8,
					height = 12 + wave * 2,
					floor = floor,
					life = 1.7,
					toWallet = true,
					stagger = 0.03,
				})
				play("Coin", 0.05, 1 + wave * 0.12)
			end)
		end
		-- Bills and confetti fluttering down from above.
		confettiBurst(pos + UP * 9, 30, 0.6, { TEAL_LIGHT, SUNNY, BLUE, SUNNY })
	else
		Orbs.coins(pos + Vector3.new(0, 1, 0), {
			count = math.clamp(4 + math.floor(magnitude * 1.5), 4, 12),
			speed = 18,
			spread = 1,
			floor = floor,
			life = 1.1,
			toWallet = true,
		})
		puff(feet, SUNNY, 2.5, 8)
	end
end

-- Coins burst up out of `from`, bounce on `floorY` and fly to the wallet; "+$amount" over it.
local function cashFountain(from: Vector3, floorY: number, amount: number)
	local magnitude = math.log10(math.max(amount, 1))
	Orbs.coins(from + UP * 0.6, {
		count = math.clamp(TUNE.collect.coins + math.floor(magnitude), TUNE.collect.coins, 16),
		speed = TUNE.collect.coinSpeed,
		spread = 0.5,
		floor = floorY,
		life = TUNE.collect.coinLife,
		toWallet = true,
		stagger = 0.03,
		size = TUNE.collect.coinSize,
	})
	if amount >= 1 then
		local text = "+" .. Format.money(amount)
		Orbs.text(from + UP * 2.6, text, C.Good, { scale = TUNE.collect.textScale, rise = 2, life = 1.1 })
	end
end

local function onCash(data: any)
	-- Auto Cash payouts are silent: no coin shower around the player.
	if data.source == "Auto" then
		return
	end
	local amount = tonumber(data.amount) or 0
	if data.source == "Purchase" or typeof(data.padPos) ~= "Vector3" then
		cashShower(amount, data.source == "Purchase")
		return
	end
	local pos: Vector3 = data.padPos
	local pad = findPad({ padPos = pos })
	if pad then
		squashPad(pad, SUNNY)
	end
	local n = math.min(math.max(shownCoins, 6), 12)
	local target = slotPos
	if not target then
		cashFountain(pos + UP * 0.5, pos.Y, amount)
	end
	for i = 1, n do
		local from = if i <= shownCoins then coinHomes[i].Position else pos + UP * 0.5
		if target then
			-- Coins hop off the stack into the piggy bank's slot.
			hop({
				from = from,
				to = target + UP * 0.4,
				delay = (i - 1) * 0.05,
				duration = 0.55,
				arc = 4,
				size = 1,
				endSize = 0.6,
				onDone = function()
					pigHop.v = math.min(pigHop.v + (if i == 1 then 5 else 1.2), 9)
					coinDip.v -= 1.5
					if i == 1 then
						-- The first coin in sets the piggy bank off: its fountain flies to the wallet.
						cashFountain(target, pos.Y, amount)
					end
					if i == n then
						confettiBurst(target + UP * 1.5, 14, 0.8, { SUNNY, TEAL_LIGHT, BLUE })
						starBurst(target + UP * 1.5, 3, SUNNY)
					end
				end,
			})
		else
			local dir = Vector3.new(math.random() - 0.5, 0, math.random() - 0.5).Unit * (1.5 + math.random() * 2)
			hop({ from = from, to = pos + dir + UP * 0.3, delay = i * 0.03, duration = 0.5, arc = 3 })
		end
	end
	for i = 1, shownCoins do
		coins[i].CFrame = FAR
	end
	shownCoins = 0
	burstAt = os.clock()
	puff(pos + UP * 0.4, TEAL_LIGHT, 3, 10)
end

-- Buy: the price as a small red line over the wallet, a coin burst and a press at the pad -------

local function onBuy(data: any)
	local cost = tonumber(data.cost)
	if cost and cost > 0 then
		Orbs.walletText("-" .. Format.money(cost), CORAL)
	end
	if typeof(data.padPos) ~= "Vector3" then
		return
	end
	local pad = findPad({ padPos = data.padPos })
	if pad then
		squashPad(pad, SUNNY)
	end
	local pos: Vector3 = data.padPos + Vector3.new(0, 0.5, 0)
	local magnitude = if cost then math.log10(math.max(cost, 1)) else 1
	local k = math.clamp(0.9 + magnitude * 0.08, 0.9, 1.5)
	Orbs.coins(pos, {
		count = math.clamp(TUNE.buy.coins + math.floor(magnitude), TUNE.buy.coins, 12),
		speed = TUNE.buy.coinSpeed * k,
		spread = 0.8,
		life = 0.9,
	})
	puff(pos, SUNNY, 2.4 * k, 8)
	starBurst(pos + UP * 1.2, TUNE.buy.stars, SUNNY)
	if data.max == true then
		-- Buy Max spends the whole wallet: a little extra.
		confettiBurst(pos + UP * 0.6, 16, 1)
	end
end

-- Pad deny: soft coral tint and a damped wobble ------------------------------------------------

local denyBase: { [BasePart]: CFrame } = {}
local denyFlash: { [BasePart]: Part } = {}
local hudModule: any = nil

local function shakeWallet()
	if hudModule == nil then
		local ok, mod = pcall(function()
			return require(Client:WaitForChild("UI"):WaitForChild("Hud") :: ModuleScript) :: any
		end)
		hudModule = if ok then mod else false
	end
	if hudModule and type(hudModule.shakeWallet) == "function" then
		pcall(hudModule.shakeWallet)
	end
end

local function onPadDeny(data: any)
	if data.ok ~= false then
		return
	end
	play("Error")
	if data.reason == "money" then
		shakeWallet()
	end
	local pad = findPad(data)
	local top = if pad then padTop(pad) elseif typeof(data.padPos) == "Vector3" then data.padPos else nil
	if top then
		local word = if data.reason == "money" then "NEED CASH!" elseif data.reason == "locked" then "LOCKED" else "NOPE"
		Orbs.text(top + Vector3.new(0, 3, 0), word, CORAL, { scale = 0.85, rise = 1.8, life = 0.9 })
	end
	if not pad then
		return
	end
	endSquash(pad) -- the wobble starts from the pad's resting place
	local base = denyBase[pad] or pad.CFrame
	denyBase[pad] = base
	-- Coral overlay that fades out while the pad wobbles side to side.
	local flash = denyFlash[pad]
	if not flash then
		local f = newPart((pad :: Part).Shape, "DenyFlash", CORAL, pad.Size + Vector3.new(0.06, 0.06, 0.06))
		denyFlash[pad] = f
		flash = f
	end
	local slab = flash :: Part
	slab.Transparency = 0.35
	local start = os.clock()
	denyToken[pad] = start
	local length = 0.42
	local right = base.RightVector
	local conn: RBXScriptConnection
	conn = RunService.RenderStepped:Connect(function()
		if denyToken[pad] ~= start then
			conn:Disconnect() -- a newer deny took over this pad
			return
		end
		local t = (os.clock() - start) / length
		if t >= 1 or not pad.Parent then
			conn:Disconnect()
			if pad.Parent then
				pad.CFrame = base
			end
			denyBase[pad] = nil
			denyToken[pad] = nil
			slab.CFrame = FAR
			return
		end
		local offset = right * math.sin(t * math.pi * 5) * 0.28 * (1 - t) ^ 2
		pad.CFrame = base + offset
		slab.CFrame = base + offset + Vector3.new(0, 0.03, 0)
		slab.Transparency = 0.35 + 0.65 * easeOutQuad(t)
	end)
end

-- Idle breathing on pads the player can use right now --------------------------------------------

local padBase: { [BasePart]: Color3 } = {}
local padGlow: { [BasePart]: number } = {}
local padReady: { [string]: boolean } = {}
local nextReadyCheck = 0

local function computeReady(data: any): { [string]: boolean }
	local out: { [string]: boolean } = {}
	local money = tonumber(data.money) or 0
	local bought = tonumber(data.bought) or 0
	for _, amount in Economy.BUY_AMOUNTS do
		out["Buy" .. amount] = money >= Economy.bulkPrice(bought, amount) - 1e-6
	end
	-- Auto Merge is a game pass: the pad invites a tap until it is owned.
	out.AutoMerge = not data.autoMergeOwned
	local level = tonumber(data.processLevel)
	if level then
		out.ProcUp1 = money >= Economy.processUpgradeCost(level)
		out.ProcUp10 = money >= Economy.processBulkCost(level, Economy.PROCESS_BULK)
	end
	out.Collect = (tonumber(data.pending) or 0) >= 1
	out.Deposit = (tonumber(data.carried) or 0) > 0
	out.Free = (tonumber(data.freeIn) or 1) - State.age() <= 0
	local slots = data.unlockers
	local held = type(data.heldChest) == "string" and data.heldChest ~= ""
	for i = 1, 2 do
		local slot = if type(slots) == "table" then slots[i] else nil
		local locked = i == 2 and not (type(data.passes) == "table" and data.passes.PremiumUnlocker)
		if not locked and type(slot) == "table" then
			if slot.rarity == "" then
				out["Unlock" .. i] = held
			else
				out["Unlock" .. i] = (tonumber(slot.secondsLeft) or 0) - State.age() <= 0
			end
		end
	end
	return out
end

local function stepPads(dt: number, now: number)
	if now >= nextReadyCheck then
		nextReadyCheck = now + 0.3
		local data = State.data
		local ok, result = pcall(computeReady, data or {})
		padReady = if ok and data then result else {}
	end
	for i, pad in pads do
		local base = padBase[pad]
		if not base or not pad.Parent then
			continue
		end
		local name = string.sub(pad.Name, 5)
		local g = padGlow[pad] or 0
		local target = if padReady[name] then 1 else 0
		if g == target and g == 0 then
			continue
		end
		g += (target - g) * math.min(1, dt * 3)
		if math.abs(g - target) < 0.002 then
			g = target
		end
		padGlow[pad] = g
		-- A very slow (about 4 s) brighten-and-back, 1.5-3% toward white.
		local breath = 0.5 + 0.5 * math.sin(now * 1.6 + i * 0.7)
		pad.Color = base:Lerp(WHITE, g * (0.015 + 0.015 * breath))
	end
end

-- Upgrade burst -------------------------------------------------------------------------------

local function onUpgrade(data: any)
	if typeof(data.padPos) ~= "Vector3" then
		return
	end
	local pos: Vector3 = data.padPos + Vector3.new(0, 0.5, 0)
	local pad = findPad({ name = data.pad, padPos = data.padPos })
	if pad then
		squashPad(pad, TEAL_LIGHT)
	end
	puff(pos, TEAL_LIGHT, 4.5, 12)
	task.delay(0.1, function()
		confettiBurst(pos + UP * 0.6, 18, 1)
		starBurst(pos + UP * 1.5, 4)
	end)
	if type(data.pad) == "string" and string.find(data.pad, "ProcUp") then
		lid.v += 5
		cupHop.v += 5
		lightFlash = 0.6
		upgradeJar(pos, tonumber(data.level))
	end
end

-- Crate Smasher -----------------------------------------------------------------------------

type Bell = {
	parts: { BasePart },
	base: { CFrame },
	pivot: Vector3,
	swing: Spring,
	nextRing: number,
	-- The striker puck: it rides up the track, the bell swings when it arrives, then it drops.
	puck: BasePart?,
	puckBase: CFrame,
	puckRise: number,
	puckT0: number,
	pendingSwing: number,
}

local PUCK_UP = 0.3
local PUCK_HOLD = 0.12
local PUCK_DOWN = 0.45

type Cracker = {
	model: Model?,
	body: Part?,
	parts: { Part },
	offsets: { CFrame },
	gui: BillboardGui?,
	card: Frame?,
	rarity: string,
	ready: boolean,
	shakeUntil: number,
	nextShake: number,
}

local crackers: { [number]: Cracker } = {}
local bells: { [number]: Bell } = {}

local function rarityColor(rarity: string): Color3
	return (C.Rarity and C.Rarity[rarity]) or SUNNY
end

local function bindCrackers(p: Instance)
	table.clear(holos)
	table.clear(bells)
	-- Match each HoloCrate and striker bell to the nearest Crate Smasher pad.
	local crates = childrenNamed(p, "HoloCrate")
	for i = 1, 2 do
		local pad = p:FindFirstChild("Pad_Unlock" .. i) :: BasePart?
		local best, bestDist = nil, math.huge
		for _, holo in crates do
			local d = if pad then (holo.Position - pad.Position).Magnitude else 0
			if d < bestDist and not table.find(holos, holo) then
				best, bestDist = holo, d
			end
		end
		if best then
			holos[i] = best
		end
	end
	local used: { [Instance]: boolean } = {}
	for i, holo in holos do
		local best: Bell?, bestDist = nil, math.huge
		local bestModel: Instance? = nil
		for _, child in p:GetChildren() do
			if child.Name ~= "StrikerBell" or used[child] then
				continue
			end
			local parts, bases = modelParts(child)
			if #parts == 0 then
				continue
			end
			local top = parts[1].Position
			for _, part in parts do
				if part.Position.Y > top.Y then
					top = part.Position
				end
			end
			local flat = Vector3.new(top.X - holo.Position.X, 0, top.Z - holo.Position.Z)
			if flat.Magnitude < bestDist then
				bestDist = flat.Magnitude
				best = {
					parts = parts,
					base = bases,
					pivot = top,
					swing = { x = 0, v = 0 },
					nextRing = 0,
					puckBase = CFrame.identity,
					puckRise = 0,
					puckT0 = -math.huge,
					pendingSwing = 0,
				}
				bestModel = child
			end
		end
		if best and bestModel then
			used[bestModel] = true
			bells[i] = best
		end
	end
	-- Each bell gets the striker puck nearest to it.
	local pucks = childrenNamed(p, "StrikerPuck")
	for _, bell in bells do
		local nearest: BasePart?, nearestDist = nil, math.huge
		for _, puck in pucks do
			local d = Vector3.new(puck.Position.X - bell.pivot.X, 0, puck.Position.Z - bell.pivot.Z).Magnitude
			if d < nearestDist then
				nearest, nearestDist = puck, d
			end
		end
		if nearest then
			bell.puck = nearest
			bell.puckBase = nearest.CFrame
			bell.puckRise = tonumber(nearest:GetAttribute("Rise")) or 3.5
		end
	end
end

local function swingBell(bell: Bell, strength: number)
	bell.swing.v += strength
	starBurst(bell.pivot + UP * 0.3, 2, SUNNY)
end

-- Sends the puck up the track; the bell swings when it gets there (straight away if there is
-- no puck).
local function ringBell(i: number, strength: number)
	local bell = bells[i]
	if not bell then
		return
	end
	if bell.puck and bell.puck.Parent then
		bell.puckT0 = os.clock()
		bell.pendingSwing = strength
	else
		swingBell(bell, strength)
	end
end

-- Puck height above its rest spot at time t since launch: eased up, a short hold, then a
-- drop with one small bounce at the bottom.
local function puckLift(t: number, rise: number): number
	if t < 0 then
		return 0
	elseif t < PUCK_UP then
		return rise * easeOutQuad(t / PUCK_UP)
	elseif t < PUCK_UP + PUCK_HOLD then
		return rise
	end
	local u = (t - PUCK_UP - PUCK_HOLD) / PUCK_DOWN
	if u >= 1 then
		return 0
	elseif u < 0.75 then
		local f = u / 0.75
		return rise * (1 - f * f)
	end
	local b = (u - 0.75) / 0.25
	return rise * 0.06 * math.sin(b * math.pi)
end

local function destroyCrate(cr: Cracker, burst: boolean)
	if burst and cr.body then
		local pos = cr.body.Position
		local color = rarityColor(cr.rarity)
		puff(pos - UP * 0.6, color, 3, 10)
		confettiBurst(pos, 20, 1, { color, SUNNY, WHITE, TEAL_LIGHT })
		starBurst(pos + UP, 4, color)
	end
	if cr.model then
		cr.model:Destroy()
	end
	cr.model, cr.body, cr.gui, cr.card = nil, nil, nil, nil
	table.clear(cr.parts)
	table.clear(cr.offsets)
	cr.rarity = ""
	cr.ready = false
end

local function buildCrate(cr: Cracker, rarity: string)
	local color = rarityColor(rarity)
	local model = Instance.new("Model")
	model.Name = "CrackerCrate"
	-- Sunny crate (like the pen's chests) strapped in the rarity colour.
	local body = newPart(Enum.PartType.Block, "Body", SUNNY, Vector3.new(1.7, 1.5, 2.1))
	body.Parent = model
	local bandA = newPart(Enum.PartType.Block, "Band", color, Vector3.new(1.76, 0.28, 2.16))
	bandA.Parent = model
	local bandB = newPart(Enum.PartType.Block, "Band", color, Vector3.new(1.76, 1.56, 0.28))
	bandB.Parent = model

	-- READY! card: cream pill with a rarity-coloured outline and Ink text.
	local gui = Instance.new("BillboardGui")
	gui.Name = "Ready"
	gui.LightInfluence = 0
	gui.MaxDistance = 45
	gui.Size = UDim2.fromOffset(120, 44)
	gui.StudsOffset = Vector3.new(0, 2.6, 0)
	gui.Enabled = false
	gui.Parent = body
	local card = Instance.new("Frame")
	card.AnchorPoint = Vector2.new(0.5, 0.5)
	card.Position = UDim2.fromScale(0.5, 0.5)
	card.Size = UDim2.fromScale(1, 1)
	card.BackgroundColor3 = CREAM
	card.Parent = gui
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0.5, 0)
	corner.Parent = card
	local outline = Instance.new("UIStroke")
	outline.Thickness = 3
	outline.Color = color
	outline.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	outline.Parent = card
	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.AnchorPoint = Vector2.new(0.5, 0.5)
	label.Position = UDim2.fromScale(0.5, 0.5)
	label.Size = UDim2.fromScale(0.86, 0.72)
	label.Font = Theme.Fonts.Title
	label.TextScaled = true
	label.Text = "READY!"
	label.TextColor3 = INK
	label.Parent = card

	model.Parent = fxFolder
	cr.model = model
	cr.body = body
	cr.parts = { body, bandA, bandB }
	cr.offsets = { CFrame.identity, CFrame.identity, CFrame.identity }
	cr.gui = gui
	cr.card = card
	cr.rarity = rarity
	cr.ready = false
	cr.shakeUntil = 0
	cr.nextShake = 0
end

local function syncCrackers(fromSnapshot: boolean)
	local data = State.data
	local slots = data and data.unlockers
	for i = 1, 2 do
		local cr = crackers[i]
		if not cr then
			cr = {
				parts = {},
				offsets = {},
				rarity = "",
				ready = false,
				shakeUntil = 0,
				nextShake = 0,
			}
			crackers[i] = cr
		end
		local slot = slots and slots[i]
		local rarity = if type(slot) == "table" and type(slot.rarity) == "string" then slot.rarity else ""
		if rarity ~= cr.rarity then
			destroyCrate(cr, fromSnapshot and cr.rarity ~= "" and rarity == "")
			if rarity ~= "" and holos[i] then
				buildCrate(cr, rarity)
			end
		end
		local holo = holos[i]
		if holo then
			holo.LocalTransparencyModifier = if cr.model then 1 else 0
		end
	end
end

local function stepBells(dt: number, now: number)
	local parts, cframes = {}, {}
	for i, bell in bells do
		local cr = crackers[i]
		if cr and cr.ready and now >= bell.nextRing then
			bell.nextRing = now + 2.6
			ringBell(i, 2.2)
		end
		local puck = bell.puck
		if puck and puck.Parent then
			local t = now - bell.puckT0
			if bell.pendingSwing > 0 and t >= PUCK_UP then
				swingBell(bell, bell.pendingSwing)
				bell.pendingSwing = 0
			end
			table.insert(parts, puck)
			table.insert(cframes, bell.puckBase + UP * puckLift(t, bell.puckRise))
		end
		stepSpring(bell.swing, dt, 70, 3.5)
		local angle = math.clamp(bell.swing.x, -0.5, 0.5)
		local rot = CFrame.new(bell.pivot) * CFrame.fromAxisAngle(Vector3.xAxis, angle) * CFrame.new(-bell.pivot)
		for k, part in bell.parts do
			table.insert(parts, part)
			table.insert(cframes, rot * bell.base[k])
		end
	end
	if #parts > 0 then
		Workspace:BulkMoveTo(parts, cframes, Enum.BulkMoveMode.FireCFrameChanged)
	end
end

local function stepCrackers(now: number)
	local data = State.data
	local slots = data and data.unlockers
	for i, cr in crackers do
		local holo = holos[i]
		if not cr.model or not holo then
			continue
		end
		local slot = slots and slots[i]
		local left = if type(slot) == "table" then tonumber(slot.secondsLeft) or 0 else 0
		left = math.max(0, left - State.age())
		local ready = left <= 0
		if ready ~= cr.ready then
			cr.ready = ready
			local gui, card = cr.gui, cr.card
			if gui then
				gui.Enabled = ready
			end
			if ready and card then
				card.Size = UDim2.fromScale(0.2, 0.2)
				TweenService
					:Create(card, TweenInfo.new(0.3, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Size = UDim2.fromScale(1, 1) })
					:Play()
			end
			if ready then
				local color = rarityColor(cr.rarity)
				confettiBurst(holo.Position + UP, 16, 0.9, { color, SUNNY, WHITE })
				ringBell(i, 4)
				if bells[i] then
					bells[i].nextRing = now + 2.6
				end
				play("Ready")
			end
		end

		-- Rattles harder over the last part of the crate's own timer (10 s to 5 min), not
		-- of a fixed 5 minutes.
		local total = if type(slot) == "table" then tonumber(slot.totalSeconds) or 0 else 0
		local urgency = 1 - math.clamp(left / math.max(total, left, 1), 0, 1)
		local base = CFrame.new(holo.Position + Vector3.new(0, -0.2, 0)) * CFrame.Angles(0, math.rad(20), 0)
		local shake = CFrame.identity
		if ready then
			-- Calm happy hop and a slow turn.
			local hopY = math.abs(math.sin(now * 3)) * 0.3
			shake = CFrame.new(0, hopY, 0) * CFrame.Angles(0, now * 0.8, math.sin(now * 6) * 0.05)
			if cr.gui then
				cr.gui.StudsOffset = Vector3.new(0, 2.6 + math.sin(now * 2.5) * 0.15, 0)
			end
		else
			if now >= cr.nextShake then
				cr.shakeUntil = now + 0.25 + urgency * 0.2
				cr.nextShake = now + 0.4 + (1 - urgency) * 2.1
			end
			if now < cr.shakeUntil then
				local amp = 0.03 + urgency * 0.08
				shake = CFrame.new(0, math.abs(math.sin(now * 30)) * amp, 0)
					* CFrame.Angles(math.sin(now * 37) * amp, math.sin(now * 23) * amp * 0.5, math.sin(now * 41) * amp)
			end
		end
		local cf = base * shake
		local cframes = {}
		for j in cr.parts do
			cframes[j] = cf * cr.offsets[j]
		end
		Workspace:BulkMoveTo(cr.parts, cframes, Enum.BulkMoveMode.FireCFrameChanged)
	end
end

-- Wiring --------------------------------------------------------------------------------------

local function bindPlot(p: Instance)
	for pad in squashes do
		endSquash(pad)
	end
	plot = p
	table.clear(pads)
	table.clear(padBase)
	table.clear(padGlow)
	for _, child in p:GetChildren() do
		if child:IsA("BasePart") and string.sub(child.Name, 1, 4) == "Pad_" then
			table.insert(pads, child)
			padBase[child] = child.Color
		end
	end
	collectPad = p:FindFirstChild("Pad_Collect") :: BasePart?
	bindConverter(p)
	bindJar()
	bindProcessor(p)
	bindVault(p)
	bindCrackers(p)
end

local started = false

function Machines.init()
	if started then
		return
	end
	started = true
	fxFolder = Orbs.getFolder()

	local function refresh(fromSnapshot: boolean)
		local data = State.data
		if not data or not data.plotIndex then
			return
		end
		local map = Workspace:FindFirstChild("Map")
		local p = map and map:FindFirstChild("Plot" .. tostring(data.plotIndex))
		if p and p ~= plot then
			bindPlot(p)
		end
		if plot then
			syncCrackers(fromSnapshot)
			syncCoins()
		end
	end
	State.changed.Event:Connect(function()
		refresh(true)
	end)
	refresh(false)

	RunService.Heartbeat:Connect(function(dt)
		local now = os.clock()
		stepConfetti(dt, now)
		stepHops(now)
		stepStars(now)
		if not plot then
			return
		end
		stepConverter(dt, now)
		stepJar(dt, now)
		stepSquash(dt, now)
		stepProcessor(dt, now)
		stepVault(dt, now)
		stepPads(dt, now)
		stepCrackers(now)
		stepBells(dt, now)
		if shownCoins ~= coinTarget() then
			syncCoins()
		end
	end)

	Net.event("Effect").OnClientEvent:Connect(function(kind, data)
		if not plot or type(data) ~= "table" then
			return
		end
		if kind == "Deposit" then
			onDeposit(data)
		elseif kind == "Cash" then
			onCash(data)
		elseif kind == "Upgrade" then
			onUpgrade(data)
		elseif kind == "Buy" then
			onBuy(data)
		elseif kind == "Pad" then
			onPadDeny(data)
		end
	end)
end

return Machines
