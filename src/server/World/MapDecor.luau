--[[
	MapDecor: the scenery of a Parkour map, drawn from `level.PROPS` (Server.Modes.Course;
	contract in docs/parkour-maps.md). Every prop is a handful of chunky pastel parts standing
	with its base at (x, y, z), front (-Z) turned `yaw` radians about Y (as Course generates it), uniformly scaled by
	`scale` (islets and lava pools use `r` instead). Props placed at Course.WATER_Y are out at
	sea: floating kinds (buoy, fin, lavapool, bubblefield, beachball) sit on the ocean surface
	and the rest stand planted just under it; islets rise from the sea to Course.ISLET_TOP,
	where their crew props stand. Props over the map's base slab (level.BASE, drawn by
	MapDecor.base into Level<i>/Base) stand or float on its top instead. Decor never collides,
	queries or touches; only islets and the base are walkable. The `landmark` kind is the map's
	one big set piece (60-80 studs tall at Course.LANDMARK_SCALE[theme]), drawn by LANDMARKS[theme].

	Tags / attributes the client animates (Client.Fx.Modes):
	  MapBubble     translucent balls of a bubblefield, attributes Rise (studs/s) and Top (world
	                y where a bubble pops and restarts at its rest y)
	  MapBob        a buoy's float (root; the rest of the buoy is parented to it)
	  MapLightning  Neon bolt segments under a storm cloud (built hidden, Transparency 1)
	  MapGlow       Neon lava (crater, drips, pools) and the lighthouse lamp
	  ModeMover     a shark fin's invisible root with Mover = "spin", MoveSpeed, MovePhase; the
	                fin stands `r` studs out along the root's RightVector (see World.Modes)
	Part of the world generator; see Server.WorldBuilder for the overview.
]]

local Common = require(script.Parent.Common)
local Props = require(script.Parent.Props)
local Course = require(script.Parent.Parent.Modes.Course)

local make = Common.make
local UPRIGHT = Common.UPRIGHT
local W = Common.theme.World

local CYLINDER = Enum.PartType.Cylinder
local BALL = Enum.PartType.Ball
local NEON = Enum.Material.Neon

-- The ocean's top surface (World.Hub OCEAN_TOP) where floating props sit.
local SEA_Y = -1.2
-- Warn when a map's scenery grows past this many parts.
local PART_BUDGET = 300

local ROCK = W.Steel:Lerp(W.WoodDark, 0.35)
-- One hue family per map (Server.Modes.Course PALETTES): volcano basalt + lava, storm slate +
-- volt yellow, shark deep teal, giga real gold.
local DARK_ROCK = W.Basalt:Lerp(W.Steel, 0.18)
local STORM_ROCK = W.Slate:Lerp(W.Ink, 0.2)
local STORM = W.Slate:Lerp(W.Steel, 0.2)
local LAVA = W.Lava
local LAVA_HOT = W.Sunny:Lerp(W.Lava, 0.35)
local GOLD = W.Gold
local BOLT = W.Volt:Lerp(W.White, 0.35)
local FIN = W.TealDeep:Lerp(W.Ink, 0.35)

type Prop = { kind: string, x: number, y: number, z: number, yaw: number?, scale: number?, r: number?, speed: number? }

-- A part maker in a prop's frame: positions in `cf` and sizes are in unscaled prop units.
type Kit = {
	base: CFrame,
	s: number,
	parent: Instance,
	theme: string,
	block: (name: string, size: Vector3, cf: CFrame, col: Color3, extra: { [string]: any }?) -> BasePart,
	cyl: (name: string, length: number, diameter: number, cf: CFrame, col: Color3, extra: { [string]: any }?) -> BasePart,
	ball: (name: string, d: number, cf: CFrame, col: Color3, extra: { [string]: any }?) -> BasePart,
	wedge: (name: string, size: Vector3, cf: CFrame, col: Color3, extra: { [string]: any }?) -> BasePart,
}

local MapDecor = {}

-- Helpers -------------------------------------------------------------------------------

local function at(x: number, y: number, z: number): CFrame
	return CFrame.new(x, y, z)
end

local function up(x: number, y: number, z: number): CFrame
	return CFrame.new(x, y, z) * UPRIGHT
end

-- Frame at the midpoint of a..b with X (a cylinder's axis) along a -> b.
local function between(a: Vector3, b: Vector3): CFrame
	local x = (b - a).Unit
	local u = if math.abs(x.Z) < 0.9 then Vector3.new(0, 0, 1) else Vector3.new(1, 0, 0)
	local y = u:Cross(x).Unit
	return CFrame.fromMatrix((a + b) / 2, x, y, x:Cross(y))
end

local function kit(base: CFrame, s: number, parent: Instance, theme: string): Kit
	local function put(className: string, name: string, size: Vector3, cf: CFrame, col: Color3, extra: { [string]: any }?): BasePart
		local props: { [string]: any } = {
			Name = name,
			Size = size * s,
			CFrame = base * CFrame.new(cf.Position * s) * cf.Rotation,
			Color = col,
			CastShadow = true,
			Parent = parent,
		}
		if extra then
			for key, value in extra do
				props[key] = value
			end
		end
		local p = make(className, props)
		p.CanCollide = false
		p.CanQuery = false
		p.CanTouch = false
		return p
	end
	local function shaped(shape: Enum.PartType, extra: { [string]: any }?): { [string]: any }
		local props: { [string]: any } = { Shape = shape }
		if extra then
			for key, value in extra do
				props[key] = value
			end
		end
		return props
	end
	return {
		base = base,
		s = s,
		parent = parent,
		theme = theme,
		block = function(name, size, cf, col, extra)
			return put("Part", name, size, cf, col, extra)
		end,
		cyl = function(name, length, diameter, cf, col, extra)
			return put("Part", name, Vector3.new(length, diameter, diameter), cf, col, shaped(CYLINDER, extra))
		end,
		ball = function(name, d, cf, col, extra)
			return put("Part", name, Vector3.new(d, d, d), cf, col, shaped(BALL, extra))
		end,
		wedge = function(name, size, cf, col, extra)
			return put("WedgePart", name, size, cf, col, extra)
		end,
	}
end

-- Deterministic per-prop randomness (the same map always looks the same).
local function rng(p: Prop): Random
	return Random.new(math.floor(p.x * 7 + p.z * 13 + p.y * 3))
end

-- A non-colliding, unqueried decor part (base details).
local function decorPart(props: { [string]: any }): BasePart
	local part = make("Part", props)
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	return part
end

local function rockColor(theme: string): Color3
	return if theme == "volcano" then DARK_ROCK elseif theme == "storm" then STORM_ROCK else ROCK
end

-- Prop builders -------------------------------------------------------------------------

local BUILDERS: { [string]: (k: Kit, p: Prop) -> () } = {}

-- A sand (or dark rock) disc rising from the sea under a deck; walkable. `r` = radius.
BUILDERS.islet = function(k, p)
	local r = p.r or 8
	local volcanic = k.theme == "volcano"
	local topCol = if volcanic then DARK_ROCK:Lerp(W.Ink, 0.2) else W.Sand
	local sideCol = if volcanic then DARK_ROCK else W.SandDark
	-- World heights, converted into the prop frame (its base sits at p.y).
	local topY = ((Course :: any).ISLET_TOP or Course.WATER_Y + 1) - p.y
	local bottomY = SEA_Y - 2 - p.y
	local function solid(part: BasePart)
		part.CanCollide = true
		part.CanQuery = true
	end
	local rock = k.cyl("IsletRock", topY - 0.4 - bottomY, r * 2 + 2, up(0, (topY - 0.4 + bottomY) / 2, 0), rockColor(k.theme))
	solid(rock)
	solid(k.cyl("IsletSide", 1.4, r * 2 + 0.6, up(0, topY - 0.85, 0), sideCol))
	solid(k.cyl("IsletTop", 0.6, r * 2 - 0.4, up(0, topY - 0.3, 0), topCol))
	k.cyl("IsletFoam", 0.1, r * 2 + 5, up(0, SEA_Y + 0.15 - p.y, 0), W.White, { Transparency = 0.35, CastShadow = false })
	local rand = rng(p)
	for i = 1, 3 do
		local a = rand:NextNumber(0, 2 * math.pi)
		local d = rand:NextNumber(0.55, 0.85) * r
		local size = rand:NextNumber(1.2, 2.2)
		k.ball(
			"IsletPebble",
			size,
			at(math.cos(a) * d, topY + size * 0.15, math.sin(a) * d),
			if i == 2 then sideCol else rockColor(k.theme)
		)
	end
end

-- A tall palm leaning toward its front-right with drooping fronds and coconuts (11 parts).
BUILDERS.palm = function(k, _p)
	local trunk = {
		Vector3.new(0, -0.5, 0),
		Vector3.new(0.5, 4, 0),
		Vector3.new(1.5, 8, 0),
		Vector3.new(3, 11.5, 0),
	}
	for i = 1, 3 do
		local a, b = trunk[i], trunk[i + 1]
		k.cyl("PalmTrunk", (b - a).Magnitude + 0.4, 1.7 - i * 0.2, between(a, b), if i == 2 then W.WoodDark else W.Wood)
	end
	local top = trunk[4]
	k.ball("PalmCrown", 1.8, CFrame.new(top), W.GrassDark)
	for _, offset in { Vector3.new(0.6, -0.8, -0.5), Vector3.new(-0.5, -0.9, 0.4) } do
		k.ball("Coconut", 1, CFrame.new(top + offset), W.WoodDark)
	end
	for i = 1, 5 do
		local yaw = math.rad(i * 72 + 15)
		local droop = math.rad(if i % 2 == 0 then 36 else 24)
		local frame = CFrame.new(top) * CFrame.Angles(0, yaw, 0) * CFrame.Angles(-droop, 0, 0) * CFrame.new(0, 0, -3)
		k.block("PalmFrond", Vector3.new(2.2, 0.4, 6.6), frame, if i % 2 == 0 then W.Grass else W.GrassDark)
	end
end

-- A striped beach umbrella over a towel (8 parts).
BUILDERS.umbrella = function(k, _p)
	local tilt = CFrame.Angles(0, 0, math.rad(8))
	k.cyl("UmbrellaPole", 7.6, 0.4, tilt * up(0, 3.6, 0), W.White)
	k.cyl("UmbrellaCanopy", 0.5, 8.4, tilt * up(0, 7, 0), W.Coral)
	k.cyl("UmbrellaCanopy", 0.5, 6.2, tilt * up(0, 7.45, 0), W.White)
	k.cyl("UmbrellaCanopy", 0.5, 3.8, tilt * up(0, 7.9, 0), W.Coral)
	k.ball("UmbrellaTop", 0.9, tilt * at(0, 8.3, 0), W.Sunny)
	local towel = at(3.2, 0.06, 0.5) * CFrame.Angles(0, math.rad(12), 0)
	k.block("Towel", Vector3.new(3.4, 0.12, 6), towel, W.Blue)
	for _, z in { -1.6, 1.6 } do
		k.block("TowelStripe", Vector3.new(3.42, 0.14, 0.7), towel * at(0, 0, z), W.White)
	end
end

-- A striped beach ball (4 parts): meridian bands are thin discs through the centre.
BUILDERS.beachball = function(k, _p)
	local d = 3
	local centre = at(0, d * 0.42, 0)
	k.ball("BeachBall", d, centre, W.White)
	for i, col in { W.Coral, W.Sunny, W.Blue } do
		k.cyl("BeachBallBand", 0.75, d + 0.04, centre * CFrame.Angles(0, math.rad(i * 60), 0), col)
	end
end

-- A rock arch: two chunky pillars, a lintel, boulders and a tuft on top (9 parts).
BUILDERS.rockarch = function(k, _p)
	local col = rockColor(k.theme)
	local light = col:Lerp(W.Sand, 0.25)
	k.block("ArchPillar", Vector3.new(3.4, 10, 3.4), at(-4.6, 4.6, 0) * CFrame.Angles(0, 0, math.rad(-5)), col)
	k.block("ArchPillar", Vector3.new(3.2, 10, 3.6), at(4.6, 4.6, 0) * CFrame.Angles(0, 0, math.rad(4)), light)
	k.block("ArchLintel", Vector3.new(13.5, 2.8, 4), at(0, 10.2, 0) * CFrame.Angles(0, 0, math.rad(2)), col)
	k.ball("ArchBoulder", 4.2, at(-5.4, 1.2, 1.2), light)
	k.ball("ArchBoulder", 3.4, at(5.6, 1, -1.2), col)
	k.ball("ArchBoulder", 3.6, at(-3.4, 11.6, 0.2), light)
	k.ball("ArchBoulder", 2.8, at(3, 11.8, -0.4), col)
	k.block("ArchTuft", Vector3.new(3, 0.6, 2.2), at(0.4, 12, 0.3), W.Grass)
	k.block("ArchTuft", Vector3.new(1.6, 0.6, 1.6), at(-1.8, 12.4, -0.2), W.GrassDark)
end

-- A boulder cluster (4 parts), `scale`.
BUILDERS.rock = function(k, _p)
	local col = rockColor(k.theme)
	local light = col:Lerp(W.White, 0.12)
	k.ball("Boulder", 5, at(0, 1.6, 0), col)
	k.block("Boulder", Vector3.new(3.4, 3, 3), at(2.2, 1.2, 1) * CFrame.Angles(0.3, 0.6, 0.2), light)
	k.ball("Boulder", 2.6, at(-2.4, 0.8, 1.2), light)
	k.ball("Boulder", 1.6, at(1, 0.6, -2.6), col)
end

-- A little pile of coconuts with one cracked open (7 parts).
BUILDERS.coconut = function(k, _p)
	local d = 1.3
	for _, v in { { -0.7, 0 }, { 0.7, 0.1 }, { 0, 1.1 }, { 0.1, -1.1 } } do
		k.ball("Coconut", d, at(v[1], d / 2, v[2]), W.WoodDark)
	end
	k.ball("Coconut", d, at(0, d * 1.3, 0.2), W.WoodDark)
	k.ball("CoconutHalf", d, at(1.8, 0.35, 0.9), W.WoodDark)
	k.cyl("CoconutMeat", 0.1, d * 0.85, up(1.8, 0.62, 0.9), W.Cream)
end

-- A red-and-white striped lighthouse on a rock base with a glowing lamp (15 parts).
BUILDERS.lighthouse = function(k, _p)
	k.cyl("LighthouseRock", 3, 11, up(0, 0.5, 0), rockColor(k.theme))
	local y, d = 2, 6.4
	for i = 1, 5 do
		local h = 3.4
		k.cyl("LighthouseTower", h, d, up(0, y + h / 2, 0), if i % 2 == 1 then W.White else W.Coral)
		y += h
		d -= 0.45
	end
	k.block("LighthouseDoor", Vector3.new(1.8, 2.8, 0.4), at(0, 3.4, -3.05), W.TealDeep)
	k.cyl("LighthouseWindow", 0.3, 1.1, at(0, 9.2, -2.55) * CFrame.Angles(0, math.rad(90), 0), W.TealLight)
	k.cyl("LighthouseWindow", 0.3, 1.1, at(0, 15.6, -2.2) * CFrame.Angles(0, math.rad(90), 0), W.TealLight)
	k.cyl("LighthouseGallery", 0.7, d + 2.2, up(0, y + 0.35, 0), W.Steel)
	local lamp = k.cyl("LighthouseLamp", 3, d - 0.6, up(0, y + 2.2, 0), W.Butter, { Material = NEON })
	lamp:AddTag("MapGlow")
	k.cyl("LighthouseLampBand", 0.4, d - 0.3, up(0, y + 2.2, 0), W.Steel)
	k.cyl("LighthouseRoof", 1.2, d + 0.6, up(0, y + 4.2, 0), W.Coral)
	k.cyl("LighthouseRoof", 1, d - 1.2, up(0, y + 5.2, 0), W.Coral)
	k.ball("LighthouseTip", 1.2, at(0, y + 6.2, 0), W.Sunny)
end

-- A bobbing buoy: the float is the MapBob root, the rest rides on it (6 parts).
BUILDERS.buoy = function(k, _p)
	local root = k.cyl("BuoyFloat", 1.6, 3, up(0, 0.4, 0), W.Coral)
	root:AddTag("MapBob")
	local function child(part: BasePart)
		part.Parent = root
	end
	child(k.cyl("BuoyBand", 0.5, 3.1, up(0, 0.5, 0), W.White))
	for _, yaw in { 0, 90 } do
		child(k.block("BuoyCage", Vector3.new(0.3, 3.6, 2), at(0, 2.8, 0) * CFrame.Angles(0, math.rad(yaw), 0), W.Coral))
	end
	child(k.cyl("BuoyCap", 0.4, 1.6, up(0, 4.6, 0), W.White))
	child(k.ball("BuoyLight", 0.9, at(0, 5.1, 0), W.Sunny, { Material = NEON }))
end

-- A coral cluster: tubes with round tips and two fans on a rock (10 parts), `scale`.
BUILDERS.coral = function(k, _p)
	k.ball("CoralRock", 3.4, at(0, 0.4, 0), W.SandDark)
	local tubes = {
		{ -0.8, 0.2, 5, 0.9, W.Coral },
		{ 0.7, -0.5, 3.6, 0.8, W.Pink },
		{ 0.1, 0.9, 2.6, 0.7, W.Orange },
	}
	for _, t in tubes do
		local h = t[3]
		k.cyl("CoralTube", h, t[4], up(t[1], h / 2 + 0.6, t[2]) * CFrame.Angles(0.08, 0, 0), t[5])
		k.ball("CoralTip", t[4] + 0.3, at(t[1], h + 0.6, t[2]), t[5]:Lerp(W.White, 0.25))
	end
	k.cyl("CoralFan", 0.25, 3.6, at(1.6, 2.4, 0.6) * CFrame.Angles(0, math.rad(30), 0), W.Grape)
	k.cyl("CoralFan", 0.25, 2.6, at(-1.7, 1.9, -0.8) * CFrame.Angles(0, math.rad(-40), 0), W.Pink)
	k.cyl("CoralSprig", 2, 0.4, between(Vector3.new(-1.4, 0.8, 1.2), Vector3.new(-2.2, 2.6, 1.8)), W.Mint)
end

-- A spot of rising bubbles: ~8 translucent balls tagged MapBubble plus a foam ring (9 parts).
BUILDERS.bubblefield = function(k, p)
	k.cyl("BubbleFoam", 0.1, 9, up(0, 0.1, 0), W.White, { Transparency = 0.4, CastShadow = false })
	local rand = rng(p)
	local s = k.s
	for i = 1, 8 do
		local a = rand:NextNumber(0, 2 * math.pi)
		local d = rand:NextNumber(0, 3.6)
		local size = rand:NextNumber(0.8, 2.2)
		local y = 0.4 + rand:NextNumber(0, 12)
		local bubble = k.ball("Bubble", size, at(math.cos(a) * d, y, math.sin(a) * d), if i % 3 == 0 then W.Pink else W.TealLight, {
			Transparency = 0.45,
			Reflectance = 0.15,
			CastShadow = false,
		})
		bubble:SetAttribute("Rise", rand:NextNumber(2, 4.5))
		bubble:SetAttribute("Top", k.base.Y + (15 + rand:NextNumber(0, 6)) * s)
		bubble:AddTag("MapBubble")
	end
end

-- A shark fin circling the prop's spot (4 parts): an invisible ModeMover spin root at the
-- centre, the fin `r` studs out along the root's RightVector and its shadow and wake.
BUILDERS.fin = function(k, p)
	local r = p.r or 10
	local speed = p.speed or 0.6
	local root = make("Part", {
		Name = "SharkFinRoot",
		Size = Vector3.new(1, 1, 1),
		CFrame = k.base,
		Transparency = 1,
		CastShadow = false,
		Parent = k.parent,
	})
	root.CanCollide = false
	root.CanQuery = false
	root.CanTouch = false
	root:SetAttribute("Mover", "spin")
	root:SetAttribute("MoveSpeed", speed)
	root:SetAttribute("MovePhase", tonumber((p :: any).phase) or 0)
	root:AddTag("ModeMover")
	-- Positive spin carries +X toward -Z: the wedge's low front (-Z) leads.
	local heading = if speed < 0 then CFrame.Angles(0, math.pi, 0) else CFrame.identity
	local at0 = CFrame.new(r, 0, 0) * heading
	local s = k.s
	local function child(name: string, className: string, size: Vector3, cf: CFrame, col: Color3, extra: { [string]: any })
		local props: { [string]: any } = { Name = name, Size = size * s, CFrame = k.base * at0 * cf, Color = col, Parent = root }
		for key, value in extra do
			props[key] = value
		end
		local part = make(className, props)
		part.CanCollide = false
		part.CanQuery = false
		part.CanTouch = false
	end
	child("SharkFin", "WedgePart", Vector3.new(0.5, 3.4, 3.4), CFrame.new(0, 1.6 * s, 0.4 * s), FIN, {})
	child(
		"SharkShadow",
		"Part",
		Vector3.new(2.2, 0.1, 7.5),
		CFrame.new(0, 0.08, 1.2 * s),
		W.Ink,
		{ Transparency = 0.6, CastShadow = false }
	)
	child(
		"SharkWake",
		"Part",
		Vector3.new(1.4, 0.12, 4.5),
		CFrame.new(0, 0.12, 4 * s),
		W.White,
		{ Transparency = 0.35, CastShadow = false }
	)
end

-- A dark storm cloud (its base is the cloud's underside) with rain and a hidden Neon bolt
-- tagged MapLightning (15 parts).
BUILDERS.cloud = function(k, _p)
	local puffs = {
		{ 0, 3.4, 0, 9 },
		{ -5, 2.6, 0.6, 7.4 },
		{ 5.2, 2.6, -0.4, 7.6 },
		{ -2.4, 5.6, -0.8, 6.6 },
		{ 2.6, 5.4, 0.9, 6.2 },
		{ -8.6, 2, -0.6, 5 },
		{ 8.8, 2.1, 0.4, 5.2 },
	}
	for i, v in puffs do
		k.ball("StormPuff", v[4], at(v[1], v[2], v[3]), if i % 2 == 0 then STORM else STORM:Lerp(W.Steel, 0.35))
	end
	k.block("StormBase", Vector3.new(18, 1.6, 6.4), at(0, 1.2, 0), STORM:Lerp(W.Ink, 0.15))
	local zig = {
		Vector3.new(0.5, 0.5, 0),
		Vector3.new(-1.6, -4, 0),
		Vector3.new(1.2, -7.5, 0),
		Vector3.new(-0.8, -12.5, 0),
	}
	for i = 1, 3 do
		local a, b = zig[i], zig[i + 1]
		local bolt =
			k.block("StormBolt", Vector3.new(0.7, 0.7, (b - a).Magnitude + 0.5), CFrame.lookAt((a + b) / 2, b, Vector3.zAxis), BOLT, {
				Material = NEON,
				Transparency = 1,
				CastShadow = false,
			})
		bolt:AddTag("MapLightning")
	end
	for _, v in { { -5, 0.8 }, { 4, -0.6 }, { 6.5, 1.2 }, { -2.5, -1.4 } } do
		k.block("StormRain", Vector3.new(0.15, 9, 0.15), at(v[1], -4, v[2]) * CFrame.Angles(0, 0, math.rad(8)), W.TealLight, {
			Transparency = 0.6,
			CastShadow = false,
		})
	end
end

-- A stepped volcano cone with a glowing crater, lava drips, rim rocks and smoke (18 parts).
BUILDERS.volcano = function(k, _p)
	local tiers = { { 30, 4 }, { 25, 4 }, { 20, 4 }, { 15.5, 3.5 }, { 12, 3 } }
	local y = -1
	for i, t in tiers do
		k.cyl("VolcanoCone", t[2], t[1], up(0, y + t[2] / 2, 0), if i % 2 == 0 then DARK_ROCK:Lerp(W.WoodDark, 0.2) else DARK_ROCK)
		y += t[2]
	end
	local crater = k.cyl("VolcanoCrater", 0.6, 8.6, up(0, y + 0.1, 0), LAVA, { Material = NEON })
	crater:AddTag("MapGlow")
	for i = 0, 2 do
		local a = math.rad(i * 120 + 25)
		local dir = Vector3.new(math.cos(a), 0, math.sin(a))
		local from = dir * 5 + Vector3.new(0, y - 0.2, 0)
		local to = dir * 11 + Vector3.new(0, y - 9, 0)
		local drip = k.cyl("VolcanoDrip", (to - from).Magnitude, 1.4, between(from, to), LAVA_HOT, { Material = NEON })
		drip:AddTag("MapGlow")
	end
	for i = 0, 3 do
		local a = math.rad(i * 90 + 70)
		k.ball("VolcanoRimRock", 2.6, at(math.cos(a) * 5.4, y + 0.4, math.sin(a) * 5.4), DARK_ROCK:Lerp(W.Ink, 0.3))
	end
	for i, v in { { 0, 4, 0, 5 }, { 1.8, 7.5, -0.6, 4 }, { -0.6, 10.5, 0.8, 3.2 } } do
		k.ball("VolcanoSmoke", v[4], at(v[1], y + v[2], v[3]), W.Steel:Lerp(W.White, 0.2 * i), {
			Transparency = 0.25 + 0.15 * i,
			CastShadow = false,
		})
	end
end

-- A glowing lava pool at sea level, `r` = radius (6 parts).
BUILDERS.lavapool = function(k, p)
	local r = p.r or 5
	k.cyl("LavaRim", 0.8, r * 2 + 2.4, up(0, 0.1, 0), DARK_ROCK)
	local pool = k.cyl("LavaPool", 0.5, r * 2, up(0, 0.4, 0), LAVA, { Material = NEON })
	pool:AddTag("MapGlow")
	local core = k.cyl("LavaCore", 0.5, r, up(0, 0.45, 0), LAVA_HOT, { Material = NEON })
	core:AddTag("MapGlow")
	local rand = rng(p)
	for _ = 1, 3 do
		local a = rand:NextNumber(0, 2 * math.pi)
		k.ball("LavaRock", rand:NextNumber(1.4, 2.4), at(math.cos(a) * (r + 0.8), 0.5, math.sin(a) * (r + 0.8)), DARK_ROCK)
	end
end

-- The gold Giga statue on a grape pedestal: the uploaded mesh when it is available, else a
-- chunky flexing figure (2 or 11 parts).
BUILDERS.statue = function(k, _p)
	local pedestal = 2.4
	k.block("StatuePedestal", Vector3.new(8, pedestal, 8), at(0, pedestal / 2, 0), W.Grape)
	local gold = { Reflectance = 0.12 }
	if Props.has("GigaStatue") and Props.mesh("GigaStatue", k.base * CFrame.new(0, pedestal * k.s, 0), k.s, k.parent) then
		return
	end
	local y = pedestal
	for _, sx in { -1, 1 } do
		k.block("StatueLeg", Vector3.new(1.8, 6, 2), at(sx * 1.3, y + 3, 0), GOLD, gold)
	end
	k.block("StatueTorso", Vector3.new(6, 6.4, 3), at(0, y + 9, 0), GOLD, gold)
	k.ball("StatueHead", 3.4, at(0, y + 13.6, 0), GOLD, gold)
	for _, sx in { -1, 1 } do
		k.block("StatueUpperArm", Vector3.new(4, 1.9, 1.9), at(sx * 4.8, y + 11.2, 0), GOLD, gold)
		k.block("StatueForearm", Vector3.new(1.8, 4, 1.8), at(sx * 6.4, y + 13.6, 0), GOLD, gold)
		k.ball("StatueFist", 2.4, at(sx * 6.4, y + 15.8, 0), GOLD, gold)
	end
end

-- Bunting: two posts with a sagging rope of pennants (11 parts). `r` = half the span.
BUILDERS.flagline = function(k, p)
	local half = p.r or 7
	local postH = 8
	for _, sx in { -1, 1 } do
		k.cyl("BuntingPost", postH, 0.6, up(sx * half, postH / 2, 0), W.White)
		k.ball("BuntingCap", 1, at(sx * half, postH + 0.3, 0), W.Sunny)
	end
	local sag = postH - 1.2
	local left, mid, right = Vector3.new(-half, postH - 0.3, 0), Vector3.new(0, sag, 0), Vector3.new(half, postH - 0.3, 0)
	k.cyl("BuntingRope", (mid - left).Magnitude, 0.15, between(left, mid), W.White)
	k.cyl("BuntingRope", (right - mid).Magnitude, 0.15, between(mid, right), W.White)
	local colors = { W.Coral, W.Sunny, W.Mint, W.Blue, W.Pink }
	for i = 1, 5 do
		local x = -half + 2 * half * i / 6
		local ropeY = sag + (postH - 0.3 - sag) * math.abs(x) / half
		-- A wedge flipped upside down: horizontal top edge under the rope, point hanging.
		local frame = at(x, ropeY - 1, 0) * CFrame.Angles(0, math.pi / 2, 0) * CFrame.Angles(0, 0, math.pi)
		k.wedge("BuntingFlag", Vector3.new(0.12, 2, 1.6), frame, colors[i])
	end
end

-- Landmarks ------------------------------------------------------------------------------
-- Sizes below are prop units at scale 1; Course.LANDMARK_SCALE[theme] scales each to 60-80 studs.

-- A kit for a sub-prop standing at `cf` (prop units) in `k`'s frame, scaled by `scale`.
local function sub(k: Kit, cf: CFrame, scale: number): Kit
	return kit(k.base * CFrame.new(cf.Position * k.s) * cf.Rotation, k.s * scale, k.parent, k.theme)
end

-- Prop units from the landmark's base down to just under the ocean surface.
local function sink(k: Kit): number
	return math.max(1, (k.base.Y - SEA_Y) / k.s + 1.5)
end

-- An upright disc from under the sea up to `top` (prop units), `d` wide.
local function foundation(k: Kit, d: number, top: number, col: Color3, name: string?): BasePart
	local bottom = -sink(k)
	return k.cyl(name or "LandmarkFoot", top - bottom, d, up(0, (top + bottom) / 2, 0), col)
end

local function glow(part: BasePart): BasePart
	part:AddTag("MapGlow")
	return part
end

local LANDMARKS: { [string]: (k: Kit, p: Prop) -> () } = {}

-- A giant striped beach umbrella beside a tower of beach balls, a towel and a sandcastle (38 parts).
LANDMARKS.beach = function(k, _p)
	foundation(k, 30, 0.4, W.Sand)
	local pole = at(-1, 0, 1) * CFrame.Angles(math.rad(-2), 0, math.rad(2))
	k.cyl("GiantUmbrellaPole", 42, 1.4, pole * up(0, 21, 0), W.White)
	for i = 1, 3 do
		k.cyl("GiantUmbrellaPoleBand", 1.6, 1.6, pole * up(0, 6 + i * 7, 0), W.Coral)
	end
	for i, c in { { 26, W.Coral }, { 21, W.White }, { 15.5, W.Coral }, { 9.5, W.White } } do
		k.cyl("GiantUmbrellaCanopy", 1.3, c[1], pole * up(0, 36 + i * 1.1, 0), c[2] :: Color3)
	end
	k.ball("GiantUmbrellaTop", 3.2, pole * at(0, 42.4, 0), W.Sunny)
	for i = 0, 7 do
		local a = i * math.pi / 4
		k.ball("GiantUmbrellaFringe", 2.2, pole * at(math.cos(a) * 12.2, 36.3, math.sin(a) * 12.2), if i % 2 == 0 then W.Sunny else W.Coral)
	end
	local y = 0
	for i, d in { 11, 8.5, 6 } do
		local centre = at(7, y + d / 2, -6) * CFrame.Angles(0, math.rad(i * 25), 0)
		k.ball("BallTower", d, centre, W.White)
		for j, col in { W.Coral, W.Sunny, W.Blue } do
			k.cyl("BallTowerBand", d * 0.25, d + 0.05, centre * CFrame.Angles(0, math.rad(j * 60), 0), col)
		end
		y += d - 1
	end
	local towel = at(-8, 0.55, -7) * CFrame.Angles(0, math.rad(20), 0)
	k.block("GiantTowel", Vector3.new(5.5, 0.3, 10), towel, W.Blue)
	for _, z in { -2.8, 2.8 } do
		k.block("GiantTowelStripe", Vector3.new(5.52, 0.32, 1.2), towel * at(0, 0, z), W.White)
	end
	k.block("SandCastle", Vector3.new(6, 3, 6), at(8, 1.9, 8), W.SandDark)
	for _, v in { { 5.6, 5.6 }, { 10.4, 10.4 }, { 10.4, 5.6 } } do
		k.cyl("SandCastleTower", 5, 2.6, up(v[1], 2.9, v[2]), W.Sand)
	end
	k.wedge("SandCastleFlag", Vector3.new(0.2, 1.6, 2), at(10.4, 6.4, 10.4), W.Coral)
end

-- A tall rock arch of stacked blocks with two palms on its grassy top (38 parts).
LANDMARKS.cove = function(k, p)
	local col = rockColor(k.theme)
	local light = col:Lerp(W.Sand, 0.25)
	foundation(k, 30, 0.6, light)
	for _, sx in { -1, 1 } do
		local stack = { { 8, 10, 8, 5, -4 }, { 7, 9.5, 7.4, 14.5, 3 }, { 7.6, 9, 7, 23.5, -2 } }
		for i, b in stack do
			k.block(
				"GiantArchPillar",
				Vector3.new(b[1], b[2], b[3]),
				at(sx * (8 + (i % 2) * 0.4), b[4], (i - 2) * 0.3) * CFrame.Angles(0, 0, math.rad(b[5] * sx)),
				if (i + (sx + 1) / 2) % 2 == 0 then col else light
			)
		end
		k.ball("GiantArchBoulder", 5.6, at(sx * 12.5, 1.6, -4), light)
		k.ball("GiantArchBoulder", 4.4, at(sx * 12, 1.2, 5), col)
	end
	k.block("GiantArchLintel", Vector3.new(25, 6.5, 8.5), at(0, 30.5, 0) * CFrame.Angles(0, 0, math.rad(2)), col)
	k.block("GiantArchGrass", Vector3.new(21, 1.6, 7), at(0, 34.4, 0), W.Grass)
	for _, x in { -3, 4 } do
		k.block("GiantArchVine", Vector3.new(1.2, 7, 0.6), at(x, 25, -4.3), W.GrassDark)
	end
	BUILDERS.palm(sub(k, at(-6, 35, 0) * CFrame.Angles(0, 0.6, 0), 1.35), p)
	BUILDERS.palm(sub(k, at(6.5, 35, 0.5) * CFrame.Angles(0, 3.4, 0), 1.2), p)
end

-- A 46-unit navy-and-white lighthouse on a rock with a glowing lamp, its beam and a ring of
-- bobbing buoys (43 parts).
LANDMARKS.bay = function(k, _p)
	local rock = rockColor(k.theme)
	foundation(k, 22, 2, rock)
	for i = 0, 1 do
		local a = math.rad(i * 150 + 40)
		k.ball("LighthouseBoulder", 5, at(math.cos(a) * 9, 1.5, math.sin(a) * 9), rock:Lerp(W.Sand, 0.2))
	end
	local y, d = 2, 11
	for i = 1, 7 do
		k.cyl("GiantLighthouseTower", 5, d, up(0, y + 2.5, 0), if i % 2 == 1 then W.White else W.Navy)
		y += 5
		d -= 0.6
	end
	k.block("GiantLighthouseDoor", Vector3.new(3, 4.5, 0.6), at(0, 4.25, -5.5), W.Sunny)
	for i, wy in { 13, 22, 31 } do
		local r = (11 - 0.6 * (wy - 2) / 5) / 2
		k.cyl(
			"GiantLighthouseWindow",
			0.4,
			1.8,
			at(0, wy, -r + 0.1) * CFrame.Angles(0, math.rad(90), 0),
			if i == 2 then W.Sunny else W.TealLight
		)
	end
	k.cyl("GiantLighthouseGallery", 1, 11.5, up(0, y + 0.5, 0), W.Steel)
	glow(k.cyl("GiantLighthouseLamp", 4.5, 6.4, up(0, y + 3.25, 0), W.Butter, { Material = NEON }))
	for i = 0, 3 do
		local a = i * math.pi / 2 + math.pi / 4
		k.block("GiantLighthouseFrame", Vector3.new(0.5, 4.6, 0.5), at(math.cos(a) * 3.3, y + 3.25, math.sin(a) * 3.3), W.Steel)
	end
	k.block("GiantLighthouseBeam", Vector3.new(2.6, 2.6, 12), at(0, y + 3.25, -9), W.Butter, {
		Material = NEON,
		Transparency = 0.6,
		CastShadow = false,
	})
	for i, c in { { 1.4, 8.4 }, { 1.2, 5.6 }, { 1, 3 } } do
		k.cyl("GiantLighthouseRoof", c[1], c[2], up(0, y + 5.5 + i * 1.2, 0), W.Navy)
	end
	k.ball("GiantLighthouseTip", 1.6, at(0, y + 10, 0), W.Sunny)
	for i = 0, 5 do
		local a = i * math.pi / 3 + 0.3
		local root =
			k.cyl("LighthouseBuoy", 1.6, 3, up(math.cos(a) * 12.5, 0.8, math.sin(a) * 12.5), if i % 2 == 0 then W.Navy else W.Sunny)
		root:AddTag("MapBob")
		k.cyl("LighthouseBuoyBand", 0.5, 3.1, up(math.cos(a) * 12.5, 0.9, math.sin(a) * 12.5), W.White).Parent = root
		k.ball("LighthouseBuoyLight", 1, at(math.cos(a) * 12.5, 2.1, math.sin(a) * 12.5), W.Sunny, { Material = NEON }).Parent = root
	end
end

-- A hot-pink coral tower: stacked tubes with branching teal/pink arms, fans and anemones (30 parts).
LANDMARKS.reef = function(k, _p)
	foundation(k, 26, 0.6, W.Pink:Lerp(W.Sand, 0.6))
	for i = 0, 2 do
		local a = math.rad(i * 120 + 30)
		k.ball("CoralTowerRock", 7 - i, at(math.cos(a) * 7, 1.2, math.sin(a) * 7), W.SandDark:Lerp(W.Steel, 0.2))
	end
	local y = 0
	for i, t in { { 7, 12, W.HotPink, 0 }, { 6, 11, W.Pink, 0.6 }, { 5, 10, W.HotPink, -0.4 }, { 4, 9, W.Pink, 0.5 } } do
		k.cyl("CoralTowerTube", t[2] + 0.6, t[1], up(t[4], y + t[2] / 2, 0), t[3])
		y += t[2]
		if i == 4 then
			k.ball("CoralTowerTip", 5, at(t[4], y + 0.5, 0), W.HotPink:Lerp(W.White, 0.25))
		end
	end
	local arms = { W.Teal, W.HotPink, W.TealLight, W.Teal, W.Pink, W.TealLight }
	for i, col in arms do
		local a = math.rad(i * 137.5)
		local dir = Vector3.new(math.cos(a), 0, math.sin(a))
		local h = 3 + i * 5.5
		local from, to = dir * 2 + Vector3.new(0, h, 0), dir * 9 + Vector3.new(0, h + 6, 0)
		k.cyl("CoralTowerArm", (to - from).Magnitude, 2.4, between(from, to), col)
		k.ball("CoralTowerArmTip", 3.2, CFrame.new(to), col:Lerp(W.White, 0.3))
	end
	for i, f in { { 6, 11, W.Teal }, { 16, 10, W.Pink }, { 24, 9, W.TealLight }, { 30, 8, W.HotPink }, { 12, 9, W.TealLight } } do
		local a = math.rad(i * 72 + 15)
		k.cyl("CoralTowerFan", 0.4, f[2], at(math.cos(a) * 6.5, f[1], math.sin(a) * 6.5) * CFrame.Angles(0, -a, 0), f[3])
	end
	for i = 0, 3 do
		local a = math.rad(i * 90 + 60)
		k.cyl("CoralTowerAnemone", 2.5, 1.6, up(math.cos(a) * 10.5, 1.6, math.sin(a) * 10.5), if i % 2 == 0 then W.HotPink else W.Teal)
	end
end

-- A giant sky-blue open shell with a pearl, shooting a tall jet of MapBubble bubbles (34 parts).
LANDMARKS.bubble = function(k, p)
	foundation(k, 26, 0.5, W.SkyBlue:Lerp(W.White, 0.3))
	k.cyl("BubbleFountainFoam", 0.1, 24, up(0, 0.6, 0), W.White, { Transparency = 0.4, CastShadow = false })
	local shellCol = W.SkyBlue:Lerp(W.White, 0.2)
	k.cyl("GiantShell", 1.6, 18, up(0, 1.3, -1), shellCol)
	local hinge = at(0, 2, 7) * CFrame.Angles(math.rad(110), 0, 0)
	k.cyl("GiantShellLid", 1.2, 18, hinge * at(0, 0, -9) * UPRIGHT, shellCol)
	for i = -2, 2 do
		k.block("GiantShellRib", Vector3.new(0.9, 0.7, 9), hinge * CFrame.Angles(0, math.rad(i * 22), 0) * at(0, 0.8, -4.8), W.Blue)
	end
	k.ball("GiantPearl", 4, at(0, 3.8, -1), W.White, { Reflectance = 0.3 })
	k.cyl("BubbleJet", 38, 3.2, up(0, 24, -1), W.Blue, { Transparency = 0.55, CastShadow = false })
	for i = 0, 6 do
		local a = i * math.pi / 3
		local r = if i == 6 then 0 else 3
		k.ball("BubbleCrown", if i == 6 then 5 else 4, at(math.cos(a) * r, if i == 6 then 44 else 42, math.sin(a) * r - 1), W.White, {
			Transparency = 0.35,
			CastShadow = false,
		})
	end
	local rand = rng(p)
	for i = 1, 16 do
		local bubble = k.ball(
			"Bubble",
			rand:NextNumber(1.6, 3.6),
			at(rand:NextNumber(-1.8, 1.8), 3 + i * 2.4, rand:NextNumber(-1.8, 1.8) - 1),
			if i % 3 == 0 then W.Blue else if i % 3 == 1 then W.SkyBlue else W.White,
			{ Transparency = 0.45, Reflectance = 0.15, CastShadow = false }
		)
		bubble:SetAttribute("Rise", rand:NextNumber(4, 7))
		bubble:SetAttribute("Top", k.base.Y + (44 + rand:NextNumber(0, 4)) * k.s)
		bubble:AddTag("MapBubble")
	end
end

-- A tapering terracotta/orange coral spire with polyp bumps, staghorn branches and mint mounds (33 parts).
LANDMARKS.coral = function(k, _p)
	foundation(k, 28, 0.6, W.Terracotta:Lerp(W.Ink, 0.25))
	local y = 0
	local tierCols = { W.Terracotta, W.Orange, W.Apricot }
	for i, d in { 16, 13.5, 11.5, 9.5, 8, 6.5, 5, 3.6 } do
		k.cyl("CoralSpireTier", 6.4, d, up(0, y + 3, 0), tierCols[(i - 1) % 3 + 1])
		if i <= 8 then
			local a = math.rad(i * 100)
			k.ball(
				"CoralSpirePolyp",
				3,
				at(math.cos(a) * d / 2, y + 5.5, math.sin(a) * d / 2),
				({ W.Sunny, W.Mint, W.White })[(i - 1) % 3 + 1]
			)
		end
		y += 6
	end
	k.ball("CoralSpireTip", 3.2, at(0, y + 0.6, 0), W.Sunny)
	for i, h in { 10, 20, 30, 38 } do
		local a = math.rad(i * 90 + 45)
		local dir = Vector3.new(math.cos(a), 0, math.sin(a))
		local r0 = (16 - h * 0.27) / 2
		local col = ({ W.Mint, W.Apricot, W.Sunny, W.Mint })[i]
		local p0, p1 = dir * (r0 - 0.5) + Vector3.new(0, h, 0), dir * (r0 + 4) + Vector3.new(0, h + 3, 0)
		local p2 = p1 + Vector3.new(0, 4.5, 0) + dir * 0.6
		k.cyl("CoralSpireBranch", (p1 - p0).Magnitude + 0.6, 1.6, between(p0, p1), col)
		k.cyl("CoralSpireBranch", (p2 - p1).Magnitude + 0.6, 1.4, between(p1, p2), col)
		k.ball("CoralSpireBranchTip", 2, CFrame.new(p2), col:Lerp(W.White, 0.3))
	end
	for i = 0, 2 do
		local a = math.rad(i * 120 + 10)
		k.ball("CoralSpireMound", 4.5, at(math.cos(a) * 10.5, 0.6, math.sin(a) * 10.5), W.Mint)
	end
end

-- Two giant shark fins leaning together into an arch over a dark swirl, splashes at their
-- feet and three fins circling it (ModeMover spin roots) (34 parts).
LANDMARKS.shark = function(k, p)
	foundation(k, 30, 0.3, W.Ocean:Lerp(W.Ink, 0.4))
	k.cyl("FinArchFoam", 0.1, 26, up(0, 0.4, 0), W.White, { Transparency = 0.35, CastShadow = false })
	for _, sx in { -1, 1 } do
		local frame = at(sx * 8, 0, 0) * CFrame.Angles(0, 0, sx * math.rad(11.5))
		k.wedge("GiantFin", Vector3.new(2.6, 41, 14), frame * at(0, 20.5, -7), FIN)
		k.wedge("GiantFin", Vector3.new(2.6, 41, 7), frame * at(0, 20.5, 3.5) * CFrame.Angles(0, math.pi, 0), W.TealDeep)
		k.block("GiantFinBelly", Vector3.new(2.8, 3, 18), frame * at(0, 1.5, -2), W.White:Lerp(W.Steel, 0.2))
		for j = 0, 2 do
			k.ball("FinArchSplash", 3 + j, at(sx * (9 + j * 1.5), 0.8, -6 + j * 5), W.White, { Transparency = 0.3, CastShadow = false })
		end
	end
	for i = 0, 2 do
		local fin = sub(k, at(0, 0.4, 0) * CFrame.Angles(0, i * 2 * math.pi / 3, 0), 1.3)
		BUILDERS.fin(fin, { kind = "fin", x = p.x, y = p.y, z = p.z, r = 10.5, speed = 0.45 })
	end
end

-- A rock spire with a lightning rod under a huge stacked storm cloud, three hidden Neon bolts
-- (MapLightning), a volt-yellow rod and cloud trim, and rain (33 parts).
LANDMARKS.storm = function(k, _p)
	foundation(k, 24, 0.5, STORM_ROCK)
	k.cyl("StormPuddle", 0.2, 20, up(0, 0.6, 0), W.Slate:Lerp(W.Ink, 0.3), { Reflectance = 0.25 })
	for i, b in { { 8, 7, 8, 3.5 }, { 6, 6, 6, 10 }, { 4, 5, 4, 15.5 } } do
		k.block(
			"StormSpire",
			Vector3.new(b[1], b[2], b[3]),
			at(0, b[4], 0) * CFrame.Angles(0, math.rad(i * 20), math.rad((i - 2) * 4)),
			STORM_ROCK:Lerp(W.Steel, 0.1 * i),
			{
				Material = Enum.Material.Slate,
			}
		)
	end
	k.cyl("StormRod", 7, 0.7, up(0, 21, 0), W.Volt, { Material = NEON })
	local puffs = {
		{ 0, 34, 0, 14 },
		{ -8, 33.5, 1, 10 },
		{ 8, 33, -1, 10 },
		{ -12, 32.5, 0, 7 },
		{ 12, 32.5, 1, 7 },
		{ -4, 40, 0, 12 },
		{ 5, 40, 1, 11 },
		{ -10, 38.5, -1, 7 },
		{ 10, 38.5, 0, 7.5 },
		{ 0, 46, 0, 10 },
		{ -5, 45, 1, 7 },
		{ 5, 45.5, -1, 7 },
	}
	for i, v in puffs do
		local col = if i % 3 == 0 then W.Slate else if i % 2 == 0 then STORM else STORM:Lerp(W.Steel, 0.35)
		k.ball("GiantStormPuff", v[4], at(v[1], v[2], v[3]), col)
	end
	k.block("GiantStormBase", Vector3.new(26, 2, 9), at(0, 31.5, 0), STORM:Lerp(W.Ink, 0.15))
	k.block("GiantStormTrim", Vector3.new(26.4, 0.6, 9.4), at(0, 30.6, 0), W.Volt, { Material = NEON, CastShadow = false })
	local bolts = {
		{ Vector3.new(-6, 30.5, 0), Vector3.new(-3, 21, 1), Vector3.new(-6, 10, 0) },
		{ Vector3.new(0, 30.5, 0), Vector3.new(2, 27, 0), Vector3.new(0, 24.5, 0) },
		{ Vector3.new(7, 30.5, -1), Vector3.new(4, 20, 0), Vector3.new(8, 8, 1) },
	}
	for _, zig in bolts do
		for j = 1, 2 do
			local a, b = zig[j], zig[j + 1]
			local bolt =
				k.block("GiantStormBolt", Vector3.new(1, 1, (b - a).Magnitude + 0.6), CFrame.lookAt((a + b) / 2, b, Vector3.zAxis), BOLT, {
					Material = NEON,
					Transparency = 1,
					CastShadow = false,
				})
			bolt:AddTag("MapLightning")
		end
	end
	for i = 0, 5 do
		k.block(
			"GiantStormRain",
			Vector3.new(0.2, 20, 0.2),
			at(-10 + i * 4, 20, (i % 2) * 2 - 1) * CFrame.Angles(0, 0, math.rad(8)),
			W.Chrome,
			{
				Transparency = 0.6,
				CastShadow = false,
			}
		)
	end
end

-- A 40-unit stepped basalt volcano with a glowing crater, lava drips, rim rocks, smoke and a lava
-- moat (32 parts).
LANDMARKS.volcano = function(k, _p)
	local bottom = -sink(k)
	local tiers = { 30, 28, 24.5, 21, 18, 15.5, 13, 11 }
	for i, d in tiers do
		local y0 = if i == 1 then bottom else (i - 1) * 5
		local y1 = i * 5
		k.cyl("GiantVolcanoCone", y1 - y0, d, up(0, (y0 + y1) / 2, 0), if i % 2 == 0 then DARK_ROCK:Lerp(W.WoodDark, 0.2) else DARK_ROCK)
	end
	glow(k.cyl("GiantVolcanoMoat", 0.3, 31.5, up(0, 0.5, 0), LAVA, { Material = NEON }))
	glow(k.cyl("GiantVolcanoCrater", 0.6, 8.5, up(0, 40.1, 0), LAVA, { Material = NEON }))
	glow(k.cyl("GiantVolcanoCore", 0.6, 4.5, up(0, 40.25, 0), LAVA_HOT, { Material = NEON }))
	for i = 0, 4 do
		local a = math.rad(i * 72 + 20)
		k.ball("GiantVolcanoRim", 3, at(math.cos(a) * 5.2, 40.3, math.sin(a) * 5.2), DARK_ROCK:Lerp(W.Ink, 0.3))
	end
	for i = 0, 3 do
		local a = math.rad(i * 90 + 55)
		local dir = Vector3.new(math.cos(a), 0, math.sin(a))
		local p0, p1, p2 = dir * 5.6 + Vector3.new(0, 40, 0), dir * 8 + Vector3.new(0, 30, 0), dir * 12.6 + Vector3.new(0, 15, 0)
		glow(k.cyl("GiantVolcanoDrip", (p1 - p0).Magnitude + 0.8, 1.8, between(p0, p1), LAVA_HOT, { Material = NEON }))
		glow(k.cyl("GiantVolcanoDrip", (p2 - p1).Magnitude + 0.8, 1.6, between(p1, p2), LAVA, { Material = NEON }))
		glow(k.ball("GiantVolcanoBlob", 2.4, CFrame.new(p2), LAVA, { Material = NEON }))
	end
	for i, v in { { 0, 45, 0, 6 }, { 2, 50, -1, 5 }, { -1, 54.5, 1, 4 }, { 1.5, 58, 0, 3 } } do
		k.ball("GiantVolcanoSmoke", v[4], at(v[1], v[2], v[3]), W.Steel:Lerp(W.White, 0.15 * i), {
			Transparency = 0.2 + 0.15 * i,
			CastShadow = false,
		})
	end
end

-- A stepped grape/cream/gold plinth with a giant gold Giga (the uploaded mesh scaled to ~34
-- studs when available, else the part-built figure doubled) and bunting front and back (26-36 parts).
LANDMARKS.giga = function(k, p)
	local bottom = -sink(k)
	k.block("GigaPlinth", Vector3.new(26, 3 - bottom, 26), at(0, (3 + bottom) / 2, 0), W.Grape)
	k.block("GigaPlinth", Vector3.new(21, 3, 21), at(0, 4.5, 0), W.Cream)
	k.block("GigaPlinth", Vector3.new(16, 2, 16), at(0, 7, 0), GOLD, { Reflectance = 0.12 })
	local size = if Props.has("GigaStatue") then Props.size("GigaStatue") else nil
	local mesh = size and Props.mesh("GigaStatue", k.base * CFrame.new(0, 8 * k.s, 0), k.s * 34 / size.Y, k.parent)
	if not mesh then
		BUILDERS.statue(sub(k, at(0, 8, 0), 2), p)
	end
	for _, z in { -10, 10 } do
		BUILDERS.flagline(
			sub(k, at(0, 3, z) * CFrame.Angles(0, if z > 0 then math.pi else 0, 0), 1.1),
			{ kind = "flagline", x = p.x, y = p.y, z = p.z, r = 10 }
		)
	end
end

-- The map's big landmark, drawn by theme (beach when the theme has no builder).
BUILDERS.landmark = function(k, p)
	local build = LANDMARKS[k.theme] or LANDMARKS.beach
	build(k, p)
end

-- Base ------------------------------------------------------------------------------------

-- A base's look: `top` slab colour and material, the outer `rim` ring's (a contrasting second
-- colour/material: wet sand, foam, lava crust, gold trim), `reflect` for both, and the round
-- scenery `blob`s overhanging its edges (sand mounds, bushes, coral balls, boulders, cloud
-- puffs, gold orbs) with optional `blobAlpha` transparency and `blobMaterial`.
type BaseLook = {
	top: Color3,
	rim: Color3,
	material: Enum.Material?,
	rimMaterial: Enum.Material?,
	reflect: number?,
	blob: Color3,
	blob2: Color3?,
	blobAlpha: number?,
	blobMaterial: Enum.Material?,
	blobReflect: number?,
}
-- A theme's base-top colour from Course.BASE_TOPS.
local function baseTop(theme: string): Color3
	local mix = Course.BASE_TOPS[theme]
	local col: Color3 = W[mix[1]]
	return if mix[2] then col:Lerp(W[mix[2]], mix[3]) else col
end
local BASE_LOOK: { [string]: BaseLook } = {
	beach = {
		top = baseTop("beach"),
		rim = W.SandDark:Lerp(W.WoodDark, 0.4),
		rimMaterial = Enum.Material.Sand,
		blob = W.Sand:Lerp(W.SandDark, 0.35),
		blob2 = W.Sand,
		blobMaterial = Enum.Material.Sand,
	},
	cove = {
		top = baseTop("cove"),
		rim = W.SandDark:Lerp(W.GrassDark, 0.45),
		rimMaterial = Enum.Material.Sand,
		blob = W.Grass,
		blob2 = W.GrassDark,
	},
	bay = {
		top = baseTop("bay"),
		rim = W.Navy,
		rimMaterial = Enum.Material.WoodPlanks,
		blob = ROCK:Lerp(W.Navy, 0.3),
		blob2 = ROCK,
	},
	reef = { top = baseTop("reef"), rim = W.Teal, blob = W.HotPink, blob2 = W.TealLight },
	bubble = {
		top = baseTop("bubble"),
		rim = W.Blue:Lerp(W.Navy, 0.35),
		blob = W.White,
		blob2 = W.SkyBlue,
		blobAlpha = 0.15,
	},
	coral = {
		top = baseTop("coral"),
		rim = W.Terracotta,
		rimMaterial = Enum.Material.Sandstone,
		blob = W.Orange,
		blob2 = W.Terracotta,
	},
	shark = {
		top = baseTop("shark"),
		rim = W.TealLight,
		rimMaterial = Enum.Material.Slate,
		blob = ROCK:Lerp(W.TealDeep, 0.25),
		blob2 = ROCK,
	},
	storm = {
		top = baseTop("storm"),
		rim = W.Volt,
		material = Enum.Material.Slate,
		blob = STORM_ROCK,
		blob2 = STORM_ROCK:Lerp(W.Steel, 0.25),
		blobMaterial = Enum.Material.Slate,
	},
	volcano = {
		top = baseTop("volcano"),
		rim = W.Lava:Lerp(W.Basalt, 0.3),
		material = Enum.Material.Basalt,
		rimMaterial = Enum.Material.CrackedLava,
		blob = DARK_ROCK,
		blob2 = DARK_ROCK:Lerp(W.Ink, 0.3),
		blobMaterial = Enum.Material.Basalt,
	},
	giga = {
		top = baseTop("giga"),
		rim = GOLD:Lerp(W.Terracotta, 0.3),
		reflect = 0.1,
		blob = GOLD,
		blob2 = W.Grape,
		blobReflect = 0.2,
	},
}
-- Width of the outer rim ring round the top, how far its top sits under the base top, and
-- the corner radius of the base (the rim's outline; the top's corners are BASE_RIM tighter).
local BASE_RIM = 2.5
local BASE_RIM_DROP = 0.4
local BASE_CORNER = 9

type BaseBox = { x0: number, x1: number, z0: number, z1: number, top: number }

-- Is (x, z) on the base's rounded rectangle?
local function onBase(b: BaseBox?, x: number, z: number): boolean
	if b == nil or x < b.x0 or x > b.x1 or z < b.z0 or z > b.z1 then
		return false
	end
	local r = math.min(BASE_CORNER, (b.x1 - b.x0) / 2, (b.z1 - b.z0) / 2)
	local dx = math.max(0, math.abs(x - (b.x0 + b.x1) / 2) - ((b.x1 - b.x0) / 2 - r))
	local dz = math.max(0, math.abs(z - (b.z0 + b.z1) / 2) - ((b.z1 - b.z0) / 2 - r))
	return dx * dx + dz * dz <= r * r
end

-- The themed ground slab under the whole course (level.BASE): a rounded top (two overlapping
-- boxes + four corner cylinders) inside a slightly larger outer rim ring BASE_RIM_DROP lower,
-- in a contrasting colour/material; up to three flat theme details on the top and four round
-- blobs overhanging the edges (clear of the landmark) (23 parts at most). The slabs collide
-- (a fallen runner lands on them, below the water line, and respawns); details don't.
function MapDecor.base(level: Course.Level, folder: Instance)
	local b: BaseBox? = (level :: any).BASE
	if b == nil then
		return
	end
	local theme: string = (level :: any).theme or "beach"
	local look = BASE_LOOK[theme] or BASE_LOOK.beach
	local holder = Instance.new("Folder")
	holder.Name = "Base"
	local cx, cz = (b.x0 + b.x1) / 2, (b.z0 + b.z1) / 2
	local w, d = b.x1 - b.x0, b.z1 - b.z0
	local r = math.min(BASE_CORNER, w / 2, d / 2)
	local function slab(name: string, size: Vector3, cf: CFrame, col: Color3, material: Enum.Material?, cylinder: boolean?): BasePart
		local props: { [string]: any } = {
			Name = name,
			Size = size,
			CFrame = cf,
			Color = col,
			Material = material or Enum.Material.SmoothPlastic,
			Reflectance = look.reflect or 0,
			Parent = holder,
		}
		if cylinder then
			props.Shape = CYLINDER
		end
		local part = make("Part", props)
		part.CanCollide = true
		part.CanQuery = true
		part.CanTouch = false
		return part
	end
	-- A rounded rectangle (inset `m` from the base outline) from `bottom` up to `top`.
	local function rounded(name: string, m: number, top: number, bottom: number, col: Color3, material: Enum.Material?)
		local h, y = top - bottom, (top + bottom) / 2
		local rr = math.max(0.5, r - m)
		local ww, dd = w - 2 * m, d - 2 * m
		slab(name, Vector3.new(ww, h, dd - 2 * rr), CFrame.new(cx, y, cz), col, material)
		slab(name, Vector3.new(ww - 2 * rr, h, dd), CFrame.new(cx, y, cz), col, material)
		for _, sx in { -1, 1 } do
			for _, sz in { -1, 1 } do
				slab(
					name,
					Vector3.new(h, 2 * rr, 2 * rr),
					CFrame.new(cx + sx * (ww / 2 - rr), y, cz + sz * (dd / 2 - rr)) * UPRIGHT,
					col,
					material,
					true
				)
			end
		end
	end
	rounded("BaseRim", 0, b.top - BASE_RIM_DROP, SEA_Y - 3, look.rim, look.rimMaterial)
	rounded("BaseTop", BASE_RIM, b.top, b.top - 1.2, look.top, look.material)
	-- Theme details on the top (decor: no collision).
	local rand = Random.new(math.floor(cx * 3 + cz * 7))
	local function spot(margin: number): (number, number)
		return rand:NextNumber(b.x0 + margin, b.x1 - margin), rand:NextNumber(b.z0 + margin, b.z1 - margin)
	end
	local function detail(props: { [string]: any }): BasePart
		props.Parent = holder
		props.CastShadow = false
		return decorPart(props)
	end
	local margin = math.min(16, w / 2 - 1, d / 2 - 1)
	if theme == "reef" or theme == "coral" or theme == "cove" or theme == "bubble" then
		local col = if theme == "cove"
			then W.Mint
			else if theme == "bubble" then W.SkyBlue else if theme == "reef" then W.TealLight else W.Apricot:Lerp(W.White, 0.4)
		for _ = 1, 3 do
			local x, z = spot(margin)
			local size = rand:NextNumber(14, 26)
			detail({
				Name = "BasePatch",
				Shape = CYLINDER,
				Size = Vector3.new(0.12, size, size),
				CFrame = CFrame.new(x, b.top + 0.06, z) * UPRIGHT,
				Color = col,
			})
		end
	elseif theme == "shark" or theme == "volcano" or theme == "bay" or theme == "storm" then
		for _ = 1, 3 do
			local x, z = spot(margin)
			local yaw = rand:NextNumber(-0.5, 0.5)
			if theme == "volcano" then
				glow(detail({
					Name = "BaseCrack",
					Size = Vector3.new(rand:NextNumber(12, 24), 0.15, 0.9),
					CFrame = CFrame.new(x, b.top + 0.05, z) * CFrame.Angles(0, yaw * 3, 0),
					Color = LAVA,
					Material = NEON,
				}))
			elseif theme == "storm" then
				detail({
					Name = "BasePuddle",
					Shape = CYLINDER,
					Size = Vector3.new(0.12, rand:NextNumber(10, 18), rand:NextNumber(10, 18)),
					CFrame = CFrame.new(x, b.top + 0.06, z) * UPRIGHT,
					Color = W.Slate:Lerp(W.Ink, 0.35),
					Reflectance = 0.3,
				})
			else
				detail({
					Name = "BaseFoam",
					Size = Vector3.new(rand:NextNumber(18, 32), 0.12, 1.6),
					CFrame = CFrame.new(x, b.top + 0.06, z) * CFrame.Angles(0, yaw, 0),
					Color = W.White,
					Transparency = 0.35,
				})
			end
		end
	elseif theme == "giga" then
		-- A grape inlay band just inside the gold rim.
		for _, sz in { -1, 1 } do
			detail({
				Name = "BaseInlay",
				Size = Vector3.new(w - 2 * r - 6, 0.12, 1.4),
				CFrame = CFrame.new(cx, b.top + 0.06, cz + sz * (d / 2 - BASE_RIM - 3)),
				Color = W.Grape,
			})
		end
	end
	-- Round blobs half over the edge (one per side, slid along it), never under the landmark.
	local landmark: Prop? = nil
	for _, p in ((level :: any).PROPS or {}) :: { Prop } do
		if p.kind == "landmark" then
			landmark = p
		end
	end
	for i, edge in { { 0, -1 }, { 1, 0 }, { 0, 1 }, { -1, 0 } } do
		local size = rand:NextNumber(6, 10)
		local along = rand:NextNumber(-0.35, 0.35)
		local x = if edge[1] ~= 0 then cx + edge[1] * (w / 2 + 0.5) else cx + along * (w - 2 * r)
		local z = if edge[2] ~= 0 then cz + edge[2] * (d / 2 + 0.5) else cz + along * (d - 2 * r)
		if landmark then
			local foot = Course.propFoot(landmark)
			if math.sqrt((x - landmark.x) ^ 2 + (z - landmark.z) ^ 2) < foot + size / 2 then
				-- Slide it to the other half of that side.
				if edge[1] ~= 0 then
					z = cz - along * (d - 2 * r)
				else
					x = cx - along * (w - 2 * r)
				end
				if math.sqrt((x - landmark.x) ^ 2 + (z - landmark.z) ^ 2) < foot + size / 2 then
					continue
				end
			end
		end
		detail({
			Name = "BaseBlob",
			Shape = BALL,
			Size = Vector3.new(size, size, size),
			CFrame = CFrame.new(x, b.top - size * 0.15, z),
			Color = if i % 2 == 0 then look.blob2 or look.blob else look.blob,
			Material = look.blobMaterial or Enum.Material.SmoothPlastic,
			Transparency = look.blobAlpha or 0,
			Reflectance = look.blobReflect or 0,
		}).CastShadow =
			true
	end
	holder.Parent = folder
end

-- Build -----------------------------------------------------------------------------------

local FLOATING = { buoy = true, fin = true, lavapool = true, bubblefield = true, beachball = true }
-- Kinds sized by `r` (never scaled).
local BY_RADIUS = { islet = true, lavapool = true }
-- Non-floating props out at sea stand this far under the ocean surface.
local PLANT = 0.4
local warned: { [string]: boolean } = {}

-- Draws every `level.PROPS` entry into a "Scenery" folder under `folder`.
function MapDecor.build(level: Course.Level, folder: Instance)
	MapDecor.base(level, folder)
	local props: { Prop } = (level :: any).PROPS or {}
	if #props == 0 then
		return
	end
	local theme: string = (level :: any).theme or "beach"
	local base: BaseBox? = (level :: any).BASE
	local scenery = Instance.new("Folder")
	scenery.Name = "Scenery"
	for _, p in props do
		local build = BUILDERS[p.kind]
		if build == nil then
			if not warned[p.kind] then
				warned[p.kind] = true
				warn(`[MapDecor] unknown prop kind "{p.kind}" skipped`)
			end
			continue
		end
		local y = p.y
		if p.kind ~= "islet" and p.y <= Course.WATER_Y + 0.01 then
			-- Out at sea, or on the base slab when it stands over it.
			local ground = if onBase(base, p.x, p.z) then (base :: BaseBox).top else SEA_Y
			y = if FLOATING[p.kind] then ground else ground - PLANT
		end
		local base = CFrame.new(p.x, y, p.z) * CFrame.Angles(0, p.yaw or 0, 0)
		build(kit(base, if BY_RADIUS[p.kind] then 1 else p.scale or 1, scenery, theme), p)
	end
	local count = 0
	for _, d in scenery:GetDescendants() do
		if d:IsA("BasePart") then
			count += 1
		end
	end
	if count > PART_BUDGET then
		warn(`[MapDecor] level {level.index} scenery has {count} parts (budget {PART_BUDGET})`)
	end
	scenery.Parent = folder
end

return MapDecor
