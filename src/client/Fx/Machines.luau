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
--   * Upgrade / buy / deny feedback: dust puffs, confetti, stars, coins. A buy's price pops
--     big over the wallet and the pad throws a burst of orbs at the unit that just landed on the
--     rack. A converter upgrade squashes and stretches the whole blender on a spring, runs a
--     shock ring out from its foot and pops "+25% SPEED" and a blinking "LEVEL N" badge over it.
--   * Collect: "+$X" rises big from the pad (stepping aside of the character on screen) and coin
--     sprites arc across the screen from the piggy bank to the cash amount (Orbs.coinArc).
--   * Crate Smasher: a local crate rattles as its timer runs out; when ready the striker puck
--     rides up its track and the bell rings (the station sign shows READY!). While the timer
--     runs a small "Smash now" button sits on the crate (Robux; asks before it prompts). When
--     the slot's crate opens, the crate stays for Fx.Crates' ritual (it shakes harder and
--     harder, Crates.ritualShake) and bursts with it.

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
local Crates = require(script.Parent.Crates)
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
local ROBUX = utf8.char(0xE002)
local INK = worldColor("Ink", Color3.fromRGB(58, 48, 96))
local CREAM = worldColor("Cream", WHITE)
local SUNNY = worldColor("Sunny", C.Primary)
local TEAL = worldColor("Teal", C.Good)
local TEAL_LIGHT = worldColor("TealLight", C.Good)
local CORAL = worldColor("Coral", C.Bad)
local BLUE = worldColor("Blue", C.Secondary)
local GRAPE = worldColor("Grape", C.Orb)
local CONFETTI_COLORS = { SUNNY, TEAL_LIGHT, BLUE, SUNNY, WHITE, CORAL }

-- Tunables of the buy / deposit / collect / upgrade feedback, the jar meter and the Smasher's
-- crate: every size, colour, duration and count. One table, not a local each: a chunk holds 200
-- locals at most. Sized to be seen at 1280x720 with the camera 25 to 50 studs from the pads.
local TUNE = {
	-- Pad press: a successful step squashes the pad's top into its rim and springs it back.
	press = {
		depth = 0.6, -- share of the top's thickness lost at full squash
		wide = 0.08, -- footprint growth at full squash (it narrows on the rebound)
		lift = 0.3, -- studs the top lifts per unit of rebound (the stretch)
		stiffness = 420,
		damping = 15,
		time = 0.8, -- seconds until the pad is put back exactly
		ring = 1.6, -- pulse ring radius / the pad's half width
		ringTime = 0.55,
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
	-- Blender squash-and-stretch: a spring, 1 = fully squashed, below 0 = stretched tall.
	blend = {
		squash = 0.28, -- share of the blender's height lost at full squash
		wide = 0.15, -- footprint growth at full squash
		stiffness = 150,
		damping = 7.5,
		rest = 0.004, -- the spring is put to rest below this
		upgrade = 1, -- squash an upgrade starts from
		gulp = 0.45, -- squash a deposit's last orb starts from (the cup pulse)
		sip = 2, -- spring speed every deposited orb adds
	},
	upgrade = {
		orbs = 8, -- orbs that fly from the pad into the cup
		orbSize = 1.1, -- studs (half of it on arrival)
		speedScale = 1.4, -- "+25% SPEED" over the blender
		speedLift = 12.6, -- studs over the cup floor (both lines move down together when the
		-- top HUD would cover the first: Orbs.textHudOffset)
		speedLife = 2.2, -- seconds on screen
		speedRise = 2.4, -- studs it floats up
		badgeScale = 1.1, -- the blinking "LEVEL N" badge under it
		badgeLift = 9.6,
		badgeLife = 2.2,
		badge = TEAL,
		ring = 8, -- shock ring radius round the blender's foot, studs
		sparks = 16,
		sparkSize = 1.3, -- studs
		confetti = 26, -- from the pad
		stars = 6,
		puff = 5.5, -- dust ring radius at the pad, studs
	},
	deposit = {
		stream = 0.8, -- seconds over which the orbs leave the player
		flight = 0.5, -- seconds each orb flies
		orb = 1.4, -- orb size leaving the player (half of it on arrival)
		bonusTextScale = 1.3,
		bonusLift = 3, -- studs over the lid
		bonusCoins = 6, -- coins that hop from the lid to the Collect pad with a bonus
		bonusCoinSize = 1.3,
		splash = 4.5, -- shock ring radius at the lid as the last orb goes in, studs
		drops = 18, -- grape confetti thrown as the splash
		sparks = 14,
		sparkSize = 1.3, -- studs
		stars = 3,
		-- The orbs pour out of the HUD's Aura counter (TycoonUI.Dumbbell): they start on the
		-- camera ray through its middle, this share of the way to the blender (at most
		-- counterDepth studs from the eye), so the tank visibly empties into the blender (r4:
		-- they left the player and curved up to the right, away from the counter).
		counterShare = 0.35,
		counterDepth = 12,
		counterSize = 0.5,
	},
	collect = {
		coins = 10, -- fountain coins (a few more for big amounts, at most 16)
		coinSize = 1.5, -- studs
		coinSpeed = 17, -- launch speed
		coinLife = 0.9, -- seconds
		textScale = 1.3, -- "+$X" rising from the pad
		textLift = 3.2, -- studs over the pad
		arc = 13, -- coin sprites arcing across the screen to the cash amount (a few more for
		arcMax = 16, -- big amounts, at most this)
		arcSize = 34, -- design px across
		arcDelay = 0.04, -- seconds from the collect to the first coin (at once, not after the hop)
		hop = 0.4, -- seconds a coin of the stack takes into the piggy bank
		hopSize = 1.3, -- studs
		confetti = 20, -- over the piggy bank as the last coin goes in
		stars = 4,
		puff = 3.6, -- dust ring radius at the pad, studs
		tickEvery = 2.5, -- seconds between the small "+$X" ticks over the growing pile
		tickRange = 60, -- studs from the camera to the pad; farther, no tick
		tickScale = 0.8,
		tickSize = 0.6, -- the whole tick at 60%: up close it read too big over the pile
	},
	buy = {
		coins = 8, -- coins from the pad (one more per digit of the price, at most 14)
		coinSize = 1.3, -- studs
		coinSpeed = 15, -- launch speed (up to 1.5x for big prices)
		stars = 5,
		puff = 3, -- dust ring radius at the pad, studs
		throw = 6, -- orbs the pad throws at the unit(s) just bought
		throwSize = 1.2, -- studs
		throwTime = 0.42, -- seconds of flight
		throwArc = 6, -- studs the throw rises
		throwWait = 0.1, -- seconds the unit's model gets to replicate
		fresh = 3, -- seconds old at most (server time) for a unit to count as just bought
		land = 3.5, -- shock ring radius at the unit, studs
		landStar = 4.5, -- the star sprite popping at the unit: studs across
	},
	-- The small parts every burst is made of.
	bits = {
		confetti = Vector3.new(0.62, 0.1, 0.44), -- one piece, studs
		star = { 1.7, 0.9 }, -- star size in studs: least, random extra
		starRange = 140, -- studs from the camera
		puff = 1.5, -- dust ball size multiplier
		hop = 1.25, -- the blender's coin hopping to the Collect pad, studs
		denyText = 1.15, -- "NEED CASH!" scale
		breath = { 0.04, 0.05 }, -- usable pads: share toward white, least and swing
	},
	-- The Smasher's crate.
	crate = {
		scale = 2.1, -- against the 1.7 x 1.5 x 2.1 crate (Fx.Crates' SMASH.ritual.crate matches it)
		-- Studs it floats over its plinth: up in the booth's window under the awning (top 5.2
		-- studs up, the awning's scallops start at 5.4), so its top and sides clear the head of a
		-- player on the pad in the follow camera (measured in Studio: 1.35 on the plinth showed
		-- 0 of 81 sample points past the character, 2.1 lifted 0.8 shows 23).
		lift = 0.8,
		readyHop = 0.15, -- studs of its happy hop once ready (clear of the awning)
		-- Its rarity reads from the pad without Fx.Crates' wash: the body is the sunny crate
		-- mixed this far toward the rarity colour (by rank, Common first), and from `neonFrom`
		-- up the straps glow (Neon).
		bodyTint = { 0, 0.4, 0.6, 0.7, 0.75 },
		neonFrom = 2,
		ranks = { Common = 0, Uncommon = 1, Rare = 2, Epic = 3, Legendary = 4 } :: { [string]: number },
		readyConfetti = 24,
		burstConfetti = 30,
		burstStars = 6,
		burstPuff = 4, -- dust ring radius, studs
		hold = 0.3, -- seconds an opened crate waits for Fx.Crates' ritual before it just bursts
		smashBelow = 1.15, -- studs from the crate's bottom down to the middle of its "Smash now" button
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
		local part = table.remove(confettiPool) or newPart(Enum.PartType.Block, "Confetti", WHITE, TUNE.bits.confetti)
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
	gui.MaxDistance = TUNE.bits.starRange
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
		star.size = TUNE.bits.star[1] + math.random() * TUNE.bits.star[2]
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
	local size = math.clamp(r * 0.22, 0.5, 1.4) * TUNE.bits.puff
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

-- Squash-and-stretch (TUNE.blend): every "Converter..." part is scaled about the blender's foot
-- by the spring, `sy` up and `wide` across; stepConverter and stepJar apply it.
local blend = {
	spring = { x = 0, v = 0 } :: Spring,
	active = false,
	jar = false, -- stepJar still has the squash to write (one frame longer than `active`)
	foot = Vector3.zero, -- the point on the ground the blender is squashed toward
	parts = {} :: { BasePart }, -- the parts stepConverter does not move itself
	cf = {} :: { CFrame },
	size = {} :: { Vector3 },
	spinSize = {} :: { Vector3 },
	lidSize = {} :: { Vector3 },
	sy = 1,
	wide = 1,
}

-- The place and size of a part that rests at `cf` with `size`, under the current squash.
local function squashed(cf: CFrame, size: Vector3): (CFrame, Vector3)
	local sy, wide = blend.sy, blend.wide
	local rel = cf.Position - blend.foot
	local pos = blend.foot + Vector3.new(rel.X * wide, rel.Y * sy, rel.Z * wide)
	-- Each local axis takes the vertical factor by how upright it stands.
	local fx = wide + (sy - wide) * math.abs(cf.RightVector.Y)
	local fy = wide + (sy - wide) * math.abs(cf.UpVector.Y)
	local fz = wide + (sy - wide) * math.abs(cf.LookVector.Y)
	return cf.Rotation + pos, Vector3.new(size.X * fx, size.Y * fy, size.Z * fz)
end

-- Starts (or tops up) the squash: from at least `x`, with `v` more spring speed.
local function squashBlender(x: number, v: number)
	blend.active, blend.jar = true, true
	blend.spring.x = math.max(blend.spring.x, x)
	blend.spring.v += v
end

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
	-- Squash-and-stretch: resting sizes, the parts nothing else moves and the blender's foot.
	blend.active, blend.jar = false, false
	blend.spring.x, blend.spring.v = 0, 0
	blend.sy, blend.wide = 1, 1
	table.clear(blend.parts)
	table.clear(blend.cf)
	table.clear(blend.size)
	table.clear(blend.spinSize)
	table.clear(blend.lidSize)
	for i, part in spinParts do
		blend.spinSize[i] = part.Size
	end
	for i, part in lidParts do
		blend.lidSize[i] = part.Size
	end
	local low = math.huge
	for _, child in p:GetChildren() do
		if not child:IsA("BasePart") or string.sub(child.Name, 1, 9) ~= "Converter" then
			continue
		end
		local cf, size = child.CFrame, child.Size
		local tall = math.abs(cf.RightVector.Y) * size.X + math.abs(cf.UpVector.Y) * size.Y + math.abs(cf.LookVector.Y) * size.Z
		low = math.min(low, cf.Position.Y - tall / 2)
		if child ~= juice and not table.find(spinParts, child) and not table.find(lidParts, child) then
			table.insert(blend.parts, child)
			table.insert(blend.cf, cf)
			table.insert(blend.size, size)
		end
	end
	blend.foot = Vector3.new(spinAxis.X, if low < math.huge then low else spinAxis.Y, spinAxis.Z)
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
	-- Squash-and-stretch: the spring rings down from an upgrade's squash or a deposit's gulp;
	-- its last frame writes the resting sizes back.
	local squashing = blend.active
	if squashing then
		stepSpring(blend.spring, dt, TUNE.blend.stiffness, TUNE.blend.damping)
		local x = math.clamp(blend.spring.x, -1, 1)
		if math.abs(x) < TUNE.blend.rest and math.abs(blend.spring.v) < 0.05 then
			x = 0
			blend.spring.x, blend.spring.v = 0, 0
			blend.active = false
		end
		blend.sy = 1 - TUNE.blend.squash * x
		blend.wide = 1 + TUNE.blend.wide * x
	end

	local parts, cframes = {}, {}
	local rot = CFrame.new(spinAxis) * CFrame.Angles(0, spin, 0) * CFrame.new(-spinAxis)
	for i, part in spinParts do
		local cf = rot * spinBase[i]
		if squashing then
			local size: Vector3
			cf, size = squashed(cf, blend.spinSize[i])
			part.Size = size
		end
		table.insert(parts, part)
		table.insert(cframes, cf)
	end
	-- The lid rattles softly while blending and hops on the spring after deposits.
	local lift = lid.x + glow * 0.035 * math.sin(now * 23)
	for i, part in lidParts do
		local cf = lidBase[i] + UP * lift
		if squashing then
			local size: Vector3
			cf, size = squashed(cf, blend.lidSize[i])
			part.Size = size
		end
		table.insert(parts, part)
		table.insert(cframes, cf)
	end
	if squashing then
		for i, part in blend.parts do
			local cf, size = squashed(blend.cf[i], blend.size[i])
			part.Size = size
			table.insert(parts, part)
			table.insert(cframes, cf)
		end
	end
	Workspace:BulkMoveTo(parts, cframes, Enum.BulkMoveMode.FireCFrameChanged)

	-- The smoothie rises and swirls while blending.
	local j = juice
	if j and j.Parent then
		local h = juiceSize.X * (1 + glow * (0.14 + math.sin(now * 3.2) * 0.04) + math.max(0, lid.x) * 0.3)
		local cf, size = juiceCF + UP * ((h - juiceSize.X) / 2), Vector3.new(h, juiceSize.Y, juiceSize.Z)
		if squashing then
			cf, size = squashed(cf, size)
		end
		j.Size = size
		j.CFrame = cf
	end

	-- Fresh coins hop from the blender to the Collect pad while it works.
	if active and collectPad and now >= nextCoinHop then
		nextCoinHop = now + 1.3
		hop({
			from = spinAxis + UP * 2,
			to = padTop(collectPad) + UP * 0.6,
			duration = 1,
			arc = 5,
			size = TUNE.bits.hop,
			endSize = TUNE.bits.hop * 0.7,
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
	local rest = jar.floor
	if not rest then
		return
	end
	-- The blender's squash-and-stretch carries the sleeve and the bands with the cup.
	local floor = rest
	local squashing = blend.jar
	local sy, wide = 1, 1
	if squashing then
		sy, wide = blend.sy, blend.wide
		floor = rest + UP * ((rest.Position.Y - blend.foot.Y) * (sy - 1))
		jar.shown = -1 -- the sleeve is rewritten every frame of the squash
		jar.rest = false
		blend.jar = blend.active
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
			fill.Size = Vector3.new(h * sy, d * wide, d * wide)
			fill.CFrame = floor + UP * (h * sy / 2)
			foam.Size = Vector3.new(TUNE.jar.foam, (d + 0.1) * wide, (d + 0.1) * wide)
			foam.CFrame = floor + UP * ((h + TUNE.jar.foam / 2 - 0.02) * sy)
		end
	end

	-- Level bands: synced when the level changes; a new band pops in.
	local data = State.data
	local level = if data then math.floor(tonumber(data.processLevel) or 0) else 0
	if level ~= jar.ringLevel then
		syncRings(level, rest, jar.ringLevel >= 0 and level > jar.ringLevel)
		jar.ringLevel = level
	end
	-- A pulse climbs the bands while the converter works; upgrades bounce them outward.
	stepSpring(jar.kick, dt, 220, 12)
	local moving = squashing or glow > 0.02 or math.abs(jar.kick.x) > 0.002 or math.abs(jar.kick.v) > 0.02
	if moving or not jar.rest then
		jar.rest = not moving
		for k, ring in jar.rings do
			if (jar.ringColor[k] or 0) == 0 or now < (jar.ringBusy[k] or 0) then
				continue
			end
			local wave = if moving then glow * (0.5 + 0.5 * math.sin(now * 4 - k * 0.9)) else 0
			local d = TUNE.ring.radius * 2 * (1 + (if moving then jar.kick.x * TUNE.ring.kick else 0)) * wide
			ring.Size = Vector3.new(TUNE.ring.thick * (1 + TUNE.ring.pulse * wave), d, d)
			if squashing then
				ring.CFrame = floor + UP * ((TUNE.ring.first + (k - 1) * TUNE.ring.step) * sy)
			end
		end
	end
end

-- A converter upgrade. At once: the blender squashes down and springs up tall, a shock ring
-- runs out from its foot, and the gain ("+25% SPEED") and a blinking "LEVEL N" badge pop over
-- it. Then orbs fly from the pad into the cup and the bands bounce.

local function upgradeJar(from: Vector3, level: number?, gained: number?)
	local floor = jar.floor
	if not floor then
		return
	end
	local U = TUNE.upgrade
	local base = floor.Position
	squashBlender(TUNE.blend.upgrade, 0)
	Orbs.shock(Vector3.new(base.X, blend.foot.Y + 0.15, base.Z), TEAL_LIGHT, U.ring)
	Orbs.sparkle(base + UP * 6.6, SUNNY, U.sparks, 1.4, U.sparkSize)
	local speed = "SPEED UP!"
	if gained and gained > 0 then
		local factor = Economy.PROCESS_GROWTH ^ gained
		speed = if factor < 2
			then string.format("+%d%% SPEED", math.floor((factor - 1) * 100 + 0.5))
			else string.format("x%.1f SPEED", factor)
	end
	-- Both lines move down together, so "+25% SPEED" stays clear of the top HUD's capsules.
	local down = Orbs.textHudOffset(base + UP * U.speedLift, U.speedScale, U.speedRise)
	Orbs.text(base + UP * U.speedLift + down, speed, SUNNY, { scale = U.speedScale, rise = U.speedRise, life = U.speedLife, clear = true })
	if level then
		local text = "LEVEL " .. math.floor(level)
		Orbs.text(
			base + UP * U.badgeLift + down,
			text,
			WHITE,
			{ scale = U.badgeScale, rise = 1.2, life = U.badgeLife, plate = U.badge, flash = true, clear = true }
		)
	end
	local n = Budget.count(U.orbs)
	for i = 1, n do
		local jitter = Vector3.new(math.random() - 0.5, 0, math.random() - 0.5) * 1.5
		Orbs.fly({
			from = from + jitter,
			to = base + UP * 2.7,
			color = TEAL_LIGHT,
			size = U.orbSize,
			endSize = U.orbSize / 2,
			duration = 0.45,
			delay = (i - 1) * 0.05,
			arc = 4,
			trail = true,
			onDone = if i == n
				then function()
					jar.kick.v += TUNE.ring.kickSpeed
					squashBlender(0, TUNE.blend.sip * 2)
					Orbs.sparkle(base + UP * 6.6, TEAL_LIGHT, U.sparks, 1.2, U.sparkSize)
				end
				else nil,
		})
	end
end

-- A world point in front of the HUD's Aura counter on the way to `to` (nil while it is hidden).
local function auraCounterPoint(to: Vector3): Vector3?
	local camera = Workspace.CurrentCamera
	local playerGui = Players.LocalPlayer:FindFirstChildOfClass("PlayerGui")
	local screen = playerGui and playerGui:FindFirstChild("TycoonUI")
	local counter = screen and screen:FindFirstChild("Dumbbell")
	if not (camera and counter and counter:IsA("GuiObject") and counter.Visible and (screen :: ScreenGui).Enabled) then
		return nil
	end
	local mid = counter.AbsolutePosition + counter.AbsoluteSize / 2
	local ray = camera:ScreenPointToRay(mid.X, mid.Y)
	local depth = math.min(TUNE.deposit.counterDepth, (to - ray.Origin).Magnitude * TUNE.deposit.counterShare)
	return ray.Origin + ray.Direction * depth
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
	local counter = auraCounterPoint(to)
	local from: Vector3 = counter or (if typeof(data.from) == "Vector3" then data.from else to + Vector3.new(0, 6, 6))
	-- Near the eye an orb looks bigger: from the counter they start at counterSize of the size.
	local orbSize = if counter then TUNE.deposit.orb * TUNE.deposit.counterSize else TUNE.deposit.orb
	local amount = tonumber(data.amount) or 0
	local count = Budget.count(math.clamp(8 + math.floor(math.log10(math.max(1, amount)) * 2), 8, 16))
	local first = true
	for i = 1, count do
		local jitter = Vector3.new(math.random() - 0.5, math.random() - 0.5, math.random() - 0.5) * 1.2
		Orbs.fly({
			from = from + jitter,
			to = to,
			color = if i % 4 == 0 then C.OrbBig else C.Orb,
			size = orbSize,
			endSize = TUNE.deposit.orb / 2,
			duration = TUNE.deposit.flight,
			delay = (i - 1) * (TUNE.deposit.stream / count),
			arc = 3 + math.random() * 2,
			trail = true,
			onDone = function()
				-- Every orb in: the lid hops and the cup pulses.
				lid.v = math.min(lid.v + 1.6, 6)
				squashBlender(0, TUNE.blend.sip)
				if first then
					first = false
					puff(to, GRAPE, 2.4, 8)
				end
			end,
		})
	end
	task.delay(TUNE.deposit.stream + TUNE.deposit.flight - 0.1, function()
		-- The last orb: a gulp of the whole blender and a grape splash out of the lid.
		local D = TUNE.deposit
		lid.v += 4
		squashBlender(TUNE.blend.gulp, 0)
		Orbs.shock(to, GRAPE, D.splash)
		Orbs.sparkle(to + UP * 0.5, GRAPE:Lerp(WHITE, 0.3), D.sparks, 1.5, D.sparkSize)
		confettiBurst(to + UP * 0.5, D.drops, 1.1, { GRAPE, GRAPE:Lerp(WHITE, 0.4), SUNNY, WHITE })
		starBurst(to + UP, D.stars, GRAPE)
		-- The multiplier's part is cash in the vault at once: name it and send its coins there.
		local bonus = tonumber(data.bonus) or 0
		if bonus < 1 then
			return
		end
		local text = "+" .. Format.money(bonus) .. " BONUS"
		Orbs.text(to + UP * D.bonusLift, text, SUNNY, { scale = D.bonusTextScale, rise = 2.6, life = 1.5, clear = true })
		local target = collectPad
		if target and target.Parent then
			for i = 1, Budget.count(D.bonusCoins) do
				hop({
					from = to,
					to = padTop(target) + UP * 0.6,
					delay = (i - 1) * 0.07,
					duration = 0.8,
					arc = 5,
					size = D.bonusCoinSize,
					endSize = D.bonusCoinSize * 0.7,
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

local MAX_COINS = 40 -- 24 stack on the plate (8 layers of 3), the rest spill onto the floor
local coins: { Part } = {}
local coinHomes: { CFrame } = {}
-- Each coin's drop-in tween: staggered up to ~2 s for a big pile, so it must be cancelled
-- when the coin is put away, or it lands the coin back on its spot after the pile cleared.
local coinTweens: { [number]: Tween } = {}
local shownCoins = 0
local burstAt = 0

-- Puts coins first..last away (off the map), stopping any drop-in still on its way.
local function hideCoins(first: number, last: number)
	for i = first, last do
		local tween = coinTweens[i]
		if tween then
			tween:Cancel()
			coinTweens[i] = nil
		end
		local coin = coins[i]
		if coin then
			coin.CFrame = FAR
			coin.Transparency = 0
		end
		coinHomes[i] = FAR
	end
end

local function coinTarget(): number
	local data = State.data
	local pending = if data then tonumber(data.pending) or 0 else 0
	if pending < 1 or os.clock() - burstAt < 1 then
		return 0
	end
	return math.clamp(math.floor(math.log10(pending) * 6) + 1, 1, MAX_COINS)
end

local function coinHome(i: number, pad: BasePart): CFrame
	if i > 24 then
		-- Spill: coins slid off the full stack lie around the plate on the floor, tipped against
		-- each other. Seeded by index, so a coin keeps its spot while the pile grows.
		-- How far the pad's top stands over the plot floor, and how far its base reaches past the
		-- coloured top (Server.World.Pads: a weight plate's rubber is RIM_TOP 0.35 + PLATE_LIP
		-- 0.25 tall with the disc TOP_RISE 0.15 proud of it; a tile's base is 0.35 under the
		-- same rise; both PlotLayout.PAD_RIM 0.5 wider than the top).
		local round = (pad :: Part).Shape == Enum.PartType.Cylinder
		local stand = if round then 0.75 else 0.5
		local rim = 0.5
		-- The coin (Size below): its radius and half its thickness.
		local radius, half = 0.525, 0.11
		local rng = Random.new(i * 7919)
		local reach = (if round then pad.Size.Y else math.max(pad.Size.X, pad.Size.Z)) / 2 + rim
		local angle = (i - 24) * 2.4 + rng:NextNumber(-0.3, 0.3)
		local dist = reach + 0.4 + ((i - 24) % 3) * 0.45 + rng:NextNumber(0, 0.25)
		local tilt = math.rad(rng:NextNumber(8, 34))
		local floor = padTop(pad) + Vector3.new(math.cos(angle) * dist, -stand, math.sin(angle) * dist)
		-- A tipped disc rests on its lowest rim point.
		return CFrame.new(floor + Vector3.new(0, radius * math.sin(tilt) + half * math.cos(tilt), 0))
			* CFrame.Angles(0, rng:NextNumber(0, math.pi * 2), 0)
			* CFrame.Angles(tilt, 0, 0)
			* UPRIGHT
	end
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
			-- Stack coins drop onto the pile; spilled ones tumble off its top and bounce down.
			local spill = i > 24
			coin.CFrame = if spill then CFrame.new(padTop(pad) + UP * 2.2) * home.Rotation else home + UP * 1.6
			coin.Transparency = 1
			local old = coinTweens[i]
			if old then
				old:Cancel()
			end
			local tween = TweenService:Create(
				coin,
				TweenInfo.new(
					if spill then 0.45 else 0.3,
					if spill then Enum.EasingStyle.Bounce else Enum.EasingStyle.Back,
					Enum.EasingDirection.Out,
					0,
					false,
					(i - shownCoins - 1) * 0.04
				),
				{ CFrame = home, Transparency = 0 }
			)
			coinTweens[i] = tween
			tween.Completed:Once(function()
				if coinTweens[i] == tween then
					coinTweens[i] = nil
				end
			end)
			tween:Play()
		end
	else
		hideCoins(target + 1, shownCoins)
	end
	shownCoins = target
end

-- A small "+$X" ticks up over the pile now and then while uncollected cash grows: what came
-- in since the last tick. Only near the pad, so it reads as the pile filling, not as spam.
local coinTick = { at = 0, base = 0, seen = false }

local function tickCoins()
	local pad = collectPad
	local data = State.data
	if not pad or not data then
		return
	end
	local pending = tonumber(data.pending) or 0
	if not coinTick.seen or pending < coinTick.base then
		-- First look, or the cash was collected: count from here.
		coinTick.seen = true
		coinTick.base = pending
		return
	end
	local K = TUNE.collect
	local now = os.clock()
	local gain = pending - coinTick.base
	if gain < 1 or now - coinTick.at < K.tickEvery or now - burstAt < 1 then
		return
	end
	coinTick.at = now
	coinTick.base = pending
	local camera = Workspace.CurrentCamera
	if not camera or (camera.CFrame.Position - pad.Position).Magnitude > K.tickRange then
		return
	end
	local lift = 1.4 + math.ceil(math.min(shownCoins, 24) / 3) * 0.26
	Orbs.text(padTop(pad) + UP * lift, "+" .. Format.money(gain), C.Good, { scale = K.tickScale, size = K.tickSize, rise = 1.5, life = 1 })
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
			size = TUNE.collect.coinSize,
		})
		Orbs.coinArc(pos + UP * 1.5, { count = TUNE.collect.arc - 2, size = TUNE.collect.arcSize })
		puff(feet, SUNNY, 3.2, 10)
	end
end

-- Coin sprites arc across the screen from the first of `points` that is on screen (else the
-- first) to the cash amount, each one landing ticking a little higher.
local function cashArc(points: { Vector3 }, amount: number, delay: number?)
	local K = TUNE.collect
	local from = points[1]
	local camera = Workspace.CurrentCamera
	if camera then
		for _, point in points do
			local _, onScreen = camera:WorldToViewportPoint(point)
			if onScreen then
				from = point
				break
			end
		end
	end
	Orbs.coinArc(from, {
		count = math.clamp(K.arc + math.floor(math.log10(math.max(amount, 1))), K.arc, K.arcMax),
		size = K.arcSize,
		delay = delay,
		onArrive = function(index: number)
			play("Coin", 0.04, 1 + math.min(index, 14) * 0.035)
		end,
	})
end

-- Coins burst up out of `from` and bounce on `floorY`; with `arc`, coin sprites also arc
-- across the screen from it to the cash amount.
local function cashFountain(from: Vector3, floorY: number, amount: number, arc: boolean)
	local K = TUNE.collect
	local magnitude = math.log10(math.max(amount, 1))
	Orbs.coins(from + UP * 0.6, {
		count = math.clamp(K.coins + math.floor(magnitude), K.coins, 16),
		speed = K.coinSpeed,
		spread = 0.5,
		floor = floorY,
		life = K.coinLife,
		stagger = 0.03,
		size = K.coinSize,
	})
	if arc then
		cashArc({ from + UP * 1.2 }, amount)
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
	local K = TUNE.collect
	local pos: Vector3 = data.padPos
	local pad = findPad({ padPos = pos })
	if pad then
		squashPad(pad, SUNNY)
	end
	-- The amount rises from the pad at once (the free gift's is on its card).
	if amount >= 1 and data.source ~= "Free" then
		local text = "+" .. Format.money(amount)
		Orbs.text(pos + UP * K.textLift, text, C.Good, { scale = K.textScale, rise = 3, life = 1.4, clear = true })
	end
	local n = math.min(math.max(shownCoins, 6), 12)
	local target = slotPos
	if not target then
		cashFountain(pos + UP * 0.5, pos.Y, amount, true)
	else
		-- The coins to the wallet leave at once (from the piggy bank, or the pad when the bank
		-- is off screen), so they are in the air while the stack hops into the bank.
		cashArc({ target + UP * 1.5, pos + UP * 1.5 }, amount, K.arcDelay)
	end
	for i = 1, n do
		-- Off the top of the pile first (the spill, then the stack's upper layers).
		local from = if i <= shownCoins then coinHomes[shownCoins - i + 1].Position else pos + UP * 0.5
		if target then
			-- Coins hop off the stack into the piggy bank's slot.
			hop({
				from = from,
				to = target + UP * 0.4,
				delay = (i - 1) * 0.04,
				duration = K.hop,
				arc = 4,
				size = K.hopSize,
				endSize = K.hopSize * 0.6,
				onDone = function()
					pigHop.v = math.min(pigHop.v + (if i == 1 then 5 else 1.2), 9)
					coinDip.v -= 1.5
					if i == 1 then
						-- The first coin in sets the piggy bank off: its fountain.
						cashFountain(target, pos.Y, amount, false)
						Orbs.shock(target + UP * 0.3, SUNNY, 4)
					end
					if i == n then
						confettiBurst(target + UP * 1.5, K.confetti, 0.9, { SUNNY, TEAL_LIGHT, BLUE })
						starBurst(target + UP * 1.5, K.stars, SUNNY)
					end
				end,
			})
		else
			local dir = Vector3.new(math.random() - 0.5, 0, math.random() - 0.5).Unit * (1.5 + math.random() * 2)
			hop({ from = from, to = pos + dir + UP * 0.3, delay = i * 0.03, duration = 0.5, arc = 3, size = K.hopSize })
		end
	end
	hideCoins(1, MAX_COINS)
	shownCoins = 0
	burstAt = os.clock()
	puff(pos + UP * 0.4, TEAL_LIGHT, K.puff, 10)
end

-- Where the units bought last stand on the rack: the freshest "Spawned" stamps in Plot.Units
-- (none when the newest is older than TUNE.buy.fresh seconds), at most `max` of them.
local function newestUnits(max: number): { Vector3 }
	local out: { Vector3 } = {}
	local units = plot and plot:FindFirstChild("Units")
	if not units then
		return out
	end
	local newest = -math.huge
	local stamped: { { at: number, pos: Vector3 } } = {}
	for _, model in units:GetChildren() do
		local at = model:GetAttribute("Spawned")
		if type(at) == "number" and model:IsA("PVInstance") then
			newest = math.max(newest, at)
			table.insert(stamped, { at = at, pos = model:GetPivot().Position })
		end
	end
	if Workspace:GetServerTimeNow() - newest > TUNE.buy.fresh then
		return out
	end
	for _, unit in stamped do
		if unit.at >= newest - 0.25 and #out < max then
			table.insert(out, unit.pos)
		end
	end
	return out
end

-- Buy: the price pops big over the wallet, the pad presses and throws coins, and a burst of
-- orbs flies from the pad to the unit(s) that just dropped onto the rack ------------------------

local function onBuy(data: any)
	local B = TUNE.buy
	local cost = tonumber(data.cost)
	if cost and cost > 0 then
		Orbs.walletText("-" .. Format.money(cost), C.Bad)
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
		count = math.clamp(B.coins + math.floor(magnitude), B.coins, 14),
		speed = B.coinSpeed * k,
		spread = 0.8,
		life = 0.9,
		size = B.coinSize,
	})
	puff(pos, SUNNY, B.puff * k, 10)
	starBurst(pos + UP * 1.2, B.stars, SUNNY)
	if data.max == true then
		-- Buy Max spends the whole wallet: a little extra.
		confettiBurst(pos + UP * 0.6, 24, 1)
	end
	-- The throw: a moment later, so the new unit's model has replicated.
	task.delay(B.throwWait, function()
		local targets = newestUnits(3)
		if #targets == 0 then
			return
		end
		local n = math.max(Budget.count(B.throw), #targets)
		for i = 1, n do
			local to = targets[(i - 1) % #targets + 1]
			local jitter = Vector3.new(math.random() - 0.5, 0, math.random() - 0.5) * 1.2
			Orbs.fly({
				from = pos + UP * 0.6 + jitter,
				to = to + UP * 1.5,
				color = SUNNY,
				size = B.throwSize,
				endSize = B.throwSize * 0.6,
				duration = B.throwTime,
				delay = (i - 1) * 0.04,
				arc = B.throwArc,
				trail = true,
				-- The last orb to reach each unit lands with a ring and a star.
				onDone = if i > n - #targets
					then function()
						Orbs.shock(to + UP * 0.2, SUNNY, B.land)
						Orbs.sprite(
							"StarPop",
							{ position = to + UP * 2.4, size = B.landStar, rise = UP * 1.5, life = 0.7, maxDistance = 200 }
						)
						Orbs.sparkle(to + UP * 1.5, SUNNY, 8, 1.2, 1.1)
					end
					else nil,
			})
		end
	end)
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
		Orbs.text(top + Vector3.new(0, 3, 0), word, CORAL, { scale = TUNE.bits.denyText, rise = 1.8, life = 1, clear = true })
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
		-- A very slow (about 4 s) brighten-and-back toward white (TUNE.bits.breath).
		local breath = 0.5 + 0.5 * math.sin(now * 1.6 + i * 0.7)
		pad.Color = base:Lerp(WHITE, g * (TUNE.bits.breath[1] + TUNE.bits.breath[2] * breath))
	end
end

-- Upgrade burst -------------------------------------------------------------------------------

local function onUpgrade(data: any)
	-- The price leaves the wallet in red, as on a buy (free and pass upgrades send no cost).
	local cost = tonumber(data.cost)
	if cost and cost > 0 and not data.free then
		Orbs.walletText("-" .. Format.money(cost), C.Bad)
	end
	if typeof(data.padPos) ~= "Vector3" then
		return
	end
	local pos: Vector3 = data.padPos + Vector3.new(0, 0.5, 0)
	local pad = findPad({ name = data.pad, padPos = data.padPos })
	if pad then
		squashPad(pad, TEAL_LIGHT)
	end
	puff(pos, TEAL_LIGHT, TUNE.upgrade.puff, 12)
	task.delay(0.1, function()
		confettiBurst(pos + UP * 0.6, TUNE.upgrade.confetti, 1.1)
		starBurst(pos + UP * 1.5, TUNE.upgrade.stars)
	end)
	if type(data.pad) == "string" and string.find(data.pad, "ProcUp") then
		lid.v += 5
		cupHop.v += 5
		lightFlash = 0.6
		-- Levels this press added (the tutorial's free one may add several: no number then).
		local gained = if data.free then nil elseif data.pad == "ProcUp10" then Economy.PROCESS_BULK else 1
		upgradeJar(pos, tonumber(data.level), gained)
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
	-- The "Smash now" button (PlayerGui), while a crate is in the slot.
	gui: BillboardGui?,
	rarity: string,
	ready: boolean,
	shakeUntil: number,
	nextShake: number,
	-- The slot's crate has opened: os.clock() of it, while the crate stays for Fx.Crates'
	-- ritual; `ritual` once that ritual was seen running.
	opening: number?,
	ritual: boolean,
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
		puff(pos - UP * 0.6, color, TUNE.crate.burstPuff, 12)
		confettiBurst(pos, TUNE.crate.burstConfetti, 1.3, { color, SUNNY, WHITE, color:Lerp(WHITE, 0.4) })
		starBurst(pos + UP, TUNE.crate.burstStars, color)
	end
	cr.opening, cr.ritual = nil, false
	if cr.model then
		cr.model:Destroy()
	end
	if cr.gui then
		cr.gui:Destroy()
	end
	cr.model, cr.body, cr.gui = nil, nil, nil
	table.clear(cr.parts)
	table.clear(cr.offsets)
	cr.rarity = ""
	cr.ready = false
end

local function buildCrate(cr: Cracker, rarity: string, slotIndex: number)
	local color = rarityColor(rarity)
	local model = Instance.new("Model")
	model.Name = "CrackerCrate"
	-- Sunny crate (like the pen's chests) strapped in the rarity colour; Fx.Crates adds its
	-- rarity's wash, piping, gem and beam.
	local K = TUNE.crate
	local k = K.scale
	local rank = math.clamp(K.ranks[rarity] or 0, 0, #K.bodyTint - 1)
	local body = newPart(Enum.PartType.Block, "Body", SUNNY:Lerp(color, K.bodyTint[rank + 1]), Vector3.new(1.7, 1.5, 2.1) * k)
	body.Parent = model
	local bandA = newPart(Enum.PartType.Block, "Band", color, Vector3.new(1.76, 0.28, 2.16) * k)
	bandA.Parent = model
	local bandB = newPart(Enum.PartType.Block, "Band", color, Vector3.new(1.76, 1.56, 0.28) * k)
	bandB.Parent = model
	if rank >= K.neonFrom then
		bandA.Material = Enum.Material.Neon
		bandB.Material = Enum.Material.Neon
	end

	-- "Smash now" button over the crate while its timer runs (the station sign shows the
	-- timer and READY!): the only place the Robux smash is offered, and only on a tap. In
	-- PlayerGui so that it takes input; stepCrackers shows and hides it.
	local gui: BillboardGui? = nil
	local playerGui = Players.LocalPlayer:FindFirstChildOfClass("PlayerGui")
	if playerGui then
		local smash = Instance.new("BillboardGui")
		smash.Name = "SmashNow" .. slotIndex
		smash.Adornee = body
		smash.Active = true
		smash.AlwaysOnTop = true
		smash.ResetOnSpawn = false
		smash.LightInfluence = 0
		smash.MaxDistance = 28
		smash.Size = UDim2.fromOffset(156, 38)
		-- Under the crate, not on it: measured in Studio, a button on the crate's middle
		-- (offset 0.2) covered 38 of its 50 px and its whole width from 22 studs.
		smash.StudsOffsetWorldSpace = Vector3.new(0, -(body.Size.Y / 2 + K.smashBelow), 0)
		smash.Enabled = false
		local button = Instance.new("TextButton")
		button.Name = "Button"
		button.Size = UDim2.fromScale(1, 1)
		button.BackgroundColor3 = INK
		button.BackgroundTransparency = 0.15
		button.AutoButtonColor = true
		button.Font = Theme.Fonts.Title
		button.TextSize = 17
		button.TextColor3 = WHITE
		button.Text = string.format("Smash now  %s %d", ROBUX, Theme.Monetization.CrateOpen.Price)
		button.Parent = smash
		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0.5, 0)
		corner.Parent = button
		local outline = Instance.new("UIStroke")
		outline.Thickness = 2
		outline.Color = color
		outline.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
		outline.Parent = button
		button.Activated:Connect(function()
			-- The server answers with its "Smash it now for R$..?" confirm card.
			Net.event("Action"):FireServer({ action = "OfferSmash", slot = slotIndex })
		end)
		smash.Parent = playerGui
		gui = smash
	end

	model.Parent = fxFolder
	cr.model = model
	cr.body = body
	cr.parts = { body, bandA, bandB }
	cr.offsets = { CFrame.identity, CFrame.identity, CFrame.identity }
	cr.gui = gui
	cr.rarity = rarity
	cr.ready = false
	cr.shakeUntil = 0
	cr.nextShake = 0
	cr.opening, cr.ritual = nil, false
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
				ritual = false,
			}
			crackers[i] = cr
		end
		local slot = slots and slots[i]
		local rarity = if type(slot) == "table" and type(slot.rarity) == "string" then slot.rarity else ""
		-- An opened crate whose ritual runs is left alone: stepCrackers ends it.
		if not (cr.opening and rarity == "") then
			if fromSnapshot and cr.model and cr.rarity ~= "" and rarity == "" then
				-- The slot's crate opened: it stays for the ritual (Fx.Crates) and bursts with it.
				cr.opening, cr.ritual = os.clock(), false
				if cr.gui then
					cr.gui.Enabled = false
				end
			elseif rarity ~= cr.rarity or cr.opening then
				destroyCrate(cr, cr.opening ~= nil)
				if rarity ~= "" and holos[i] then
					buildCrate(cr, rarity, i)
				end
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

-- Where the crate rests on its plinth: turned like the ghost crate, standing on the same spot
-- whatever TUNE.crate.scale makes of its height, TUNE.crate.lift over it.
local function crateBase(holo: BasePart): CFrame
	local K = TUNE.crate
	return CFrame.new(holo.Position + Vector3.new(0, -0.95 + K.lift + 0.75 * K.scale, 0)) * CFrame.Angles(0, math.rad(20), 0)
end

local function stepCrackers(now: number)
	local data = State.data
	local slots = data and data.unlockers
	for i, cr in crackers do
		local holo = holos[i]
		if not cr.model or not holo then
			continue
		end
		-- Opened: the build-up of Fx.Crates' ritual shakes it harder and harder, then it bursts
		-- (at once when no ritual shows up, as far from the camera).
		local opening = cr.opening
		if opening then
			local u = Crates.ritualAt(holo.Position)
			if u then
				cr.ritual = true
				local cf = crateBase(holo) * Crates.ritualShake(u, now)
				local cframes = {}
				for j in cr.parts do
					cframes[j] = cf * cr.offsets[j]
				end
				Workspace:BulkMoveTo(cr.parts, cframes, Enum.BulkMoveMode.FireCFrameChanged)
			elseif cr.ritual or now - opening > TUNE.crate.hold then
				destroyCrate(cr, true)
			end
			continue
		end
		local slot = slots and slots[i]
		local left = if type(slot) == "table" then tonumber(slot.secondsLeft) or 0 else 0
		left = math.max(0, left - State.age())
		local ready = left <= 0
		-- The Robux smash: only while the timer runs, with empty hands, where Robux crate
		-- opens are allowed and not for a Crate Master (theirs opens free on the pad).
		local smash = cr.gui
		if smash then
			local passes = data and data.passes
			local offer = not ready
				and data ~= nil
				and data.crateRobux == true
				and (data.heldChest == nil or data.heldChest == "")
				and not (type(passes) == "table" and passes.CrateKey == true)
			if smash.Enabled ~= offer then
				smash.Enabled = offer
			end
		end
		if ready ~= cr.ready then
			cr.ready = ready
			if ready then
				local color = rarityColor(cr.rarity)
				confettiBurst(holo.Position + UP, TUNE.crate.readyConfetti, 1, { color, SUNNY, WHITE })
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
		local base = crateBase(holo)
		local shake = CFrame.identity
		if ready then
			-- Calm happy hop and a slow turn.
			local hopY = math.abs(math.sin(now * 3)) * TUNE.crate.readyHop
			shake = CFrame.new(0, hopY, 0) * CFrame.Angles(0, now * 0.8, math.sin(now * 6) * 0.05)
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
	-- A new plot: its pile is built afresh and its cash ticks count from its own pending.
	hideCoins(1, MAX_COINS)
	shownCoins = 0
	coinTick.seen = false
	coinTick.at = 0
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
			tickCoins()
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
