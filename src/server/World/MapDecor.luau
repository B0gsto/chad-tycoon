--[[
	MapDecor: the sky scenery of a Parkour map, drawn from `level.PROPS` (Server.Modes.Course;
	contracts in docs/sky-obby.md and docs/parkour-maps.md). Every prop is a handful of chunky
	candy parts standing with its base at (x, y, z), front (-Z) turned `yaw` radians about Y,
	uniformly scaled by `scale` (islands use `r` instead). Kinds: `island` (floating grass disc,
	grass top at y), `lighthouse`, `windmill`, `tree` (standing on an island top), `balloon`
	(basket at y), `cloud` and `star` (centred at y), `rainbowarch` (feet at y), the anchor set
	pieces `loop` (a vertical rainbow ring on cloud puffs at y) and `spiral` (a rainbow stair
	round a pole, its cloud at y), and `landmark`
	(the map's one big themed set piece, 110-145 studs tall at Course.LANDMARK_SCALE[theme],
	drawn by LANDMARKS[theme] on top of its island). Decor never collides, queries or touches.

	Tags / attributes the client animates (Client.Fx.Modes):
	  MapBob        a hot-air balloon's envelope (root; the rest of the balloon is parented to it)
	  MapLightning  Neon bolt segments of the storm landmark (built hidden, Transparency 1)
	  MapGlow       Neon lava of the volcano landmark and the lighthouse lamp
	  ModeMover     invisible spin roots with Mover = "spin", MoveSpeed, MovePhase (see
	                World.Modes): the shark landmark's fins stand `r` studs out along the root's
	                RightVector; a windmill's hub also has SpinAxis = "Z" (it turns about its
	                look vector, the axle) with the blades along its right/up vectors
	  Spin          (Model attribute, Client.Fx.Ambient) the gold stars turn slowly
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

-- Warn when a map's scenery grows past this many parts.
local PART_BUDGET = 700

local ROCK = W.Steel:Lerp(W.WoodDark, 0.35)
-- One hue family per map (Server.Modes.Course PALETTES): volcano basalt + lava, storm slate +
-- volt yellow, shark deep teal, giga real gold.
local DARK_ROCK = W.Basalt:Lerp(W.Steel, 0.18)
local STORM_ROCK = W.Slate:Lerp(W.Ink, 0.2)
-- The storm cloud: light grey puffs (a dark one reads as a blob against the sky).
local STORM = W.StormCloud
local LAVA = W.Lava
local LAVA_HOT = W.Sunny:Lerp(W.Lava, 0.35)
local GOLD = W.Gold
local BOLT = W.Volt:Lerp(W.White, 0.35)
local FIN = W.TealDeep:Lerp(W.Ink, 0.35)
-- Sky islands: bright candy grass, a dark-sand rim, brown trunks and wood.
local GRASS = W.Grass:Lerp(W.RainbowGreen, 0.45)
local RIM_SAND = W.SandDark:Lerp(W.WoodDark, 0.5):Lerp(W.Terracotta, 0.15)
local TRUNK = W.Terracotta:Lerp(W.Ink, 0.45)

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

local function rockColor(theme: string): Color3
	return if theme == "volcano" then DARK_ROCK elseif theme == "storm" then STORM_ROCK else ROCK
end

-- Prop builders -------------------------------------------------------------------------

local BUILDERS: { [string]: (k: Kit, p: Prop) -> () } = {}
-- Pieces the landmarks reuse (never drawn straight from level.PROPS).
local PIECES: { [string]: (k: Kit, p: Prop) -> () } = {}

-- A tall palm leaning toward its front-right with drooping fronds and coconuts (11 parts).
PIECES.palm = function(k, _p)
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

-- A shark fin circling the prop's spot (4 parts): an invisible ModeMover spin root at the
-- centre, the fin `r` studs out along the root's RightVector and its shadow and wake.
PIECES.fin = function(k, p)
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

-- The gold Giga statue on a cream pedestal: the uploaded mesh when it is available, else a
-- clear chunky figure cheering with both arms up: gold torso and head, deeper gold limbs,
-- belt and hair, ink eyes and smile (2 or 21 parts).
local GOLD_DEEP = W.GoldDeep
PIECES.statue = function(k, _p)
	local pedestal = 2.4
	k.block("StatuePedestal", Vector3.new(8, pedestal, 8), at(0, pedestal / 2, 0), W.Cream)
	local gold = { Reflectance = 0.12, Material = Enum.Material.SmoothPlastic }
	if Props.has("GigaStatue") and Props.mesh("GigaStatue", k.base * CFrame.new(0, pedestal * k.s, 0), k.s, k.parent) then
		return
	end
	local y = pedestal
	for _, sx in { -1, 1 } do
		k.block("StatueFoot", Vector3.new(2.4, 1, 3.2), at(sx * 1.5, y + 0.5, -0.3), GOLD_DEEP, gold)
		k.block("StatueLeg", Vector3.new(2.2, 5.4, 2.4), at(sx * 1.5, y + 3.6, 0), GOLD_DEEP, gold)
	end
	k.block("StatueBelt", Vector3.new(6, 1.2, 3.2), at(0, y + 6.8, 0), GOLD_DEEP, gold)
	k.block("StatueTorso", Vector3.new(5.6, 4.6, 3), at(0, y + 9.6, 0), GOLD, gold)
	k.block("StatueChest", Vector3.new(7, 2.4, 3.2), at(0, y + 11.6, 0), GOLD, gold)
	k.block("StatueNeck", Vector3.new(1.6, 0.8, 1.6), at(0, y + 13.2, 0), GOLD_DEEP, gold)
	local head = y + 15.2
	k.block("StatueHead", Vector3.new(3.8, 3.6, 3.6), at(0, head, 0), GOLD, gold)
	k.block("StatueHair", Vector3.new(4, 1, 3.8), at(0, head + 2.1, 0.1), GOLD_DEEP, gold)
	for _, sx in { -1, 1 } do
		k.block("StatueEye", Vector3.new(0.6, 0.9, 0.2), at(sx * 0.8, head + 0.4, -1.85), W.Ink)
	end
	k.block("StatueSmile", Vector3.new(1.6, 0.3, 0.2), at(0, head - 0.8, -1.85), W.Ink)
	-- Arms up in a V: shoulder -> elbow -> fist.
	for _, sx in { -1, 1 } do
		local shoulder = Vector3.new(sx * 3.7, y + 12, 0)
		local elbow = Vector3.new(sx * 5.6, y + 15.4, 0)
		local fist = Vector3.new(sx * 6.4, y + 19, 0)
		k.block(
			"StatueUpperArm",
			Vector3.new(1.9, (elbow - shoulder).Magnitude + 1, 1.9),
			CFrame.lookAt((shoulder + elbow) / 2, elbow, Vector3.zAxis) * CFrame.Angles(math.pi / 2, 0, 0),
			GOLD_DEEP,
			gold
		)
		k.block(
			"StatueForearm",
			Vector3.new(1.8, (fist - elbow).Magnitude + 0.8, 1.8),
			CFrame.lookAt((elbow + fist) / 2, fist, Vector3.zAxis) * CFrame.Angles(math.pi / 2, 0, 0),
			GOLD_DEEP,
			gold
		)
		k.ball("StatueFist", 2.4, CFrame.new(fist), GOLD, gold)
	end
end

-- Bunting: two posts with a sagging rope of pennants (11 parts). `r` = half the span.
PIECES.flagline = function(k, p)
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

-- Sky props ---------------------------------------------------------------------------------

-- A floating green island, `r` = radius, grass top at the prop's y: a grass disc, a dark-sand
-- rim band, a tapering rock cone hanging below and bushes on the edge (8-10 parts).
BUILDERS.island = function(k, p)
	local r = p.r or 12
	k.cyl("IslandGrass", 1.2, r * 2, up(0, -0.6, 0), GRASS)
	k.cyl("IslandRim", 1.8, r * 2 + 0.8, up(0, -1.9, 0), RIM_SAND)
	local y = -2.8
	for i, f in { 0.92, 0.7, 0.46, 0.22 } do
		local h = r * (0.32 - i * 0.03)
		k.cyl("IslandRock", h + 0.2, r * 2 * f, up(0, y - h / 2, 0), if i % 2 == 0 then ROCK else ROCK:Lerp(RIM_SAND, 0.25))
		y -= h
	end
	local rand = rng(p)
	for i = 1, if r >= 30 then 4 else 2 do
		local a = rand:NextNumber(0, 2 * math.pi)
		local d = math.min(r * 0.12 + 2, 7)
		k.ball(
			"IslandBush",
			d,
			at(math.cos(a) * (r - d * 0.6), d * 0.2, math.sin(a) * (r - d * 0.6)),
			if i == 1 then W.GrassDark else GRASS:Lerp(W.GrassDark, 0.4)
		)
	end
end

-- A round cartoon tree: brown trunk and three green canopy balls (4 parts).
BUILDERS.tree = function(k, _p)
	k.cyl("TreeTrunk", 6, 1.3, up(0, 3, 0), TRUNK)
	k.ball("TreeCanopy", 7.5, at(0, 8, 0), GRASS)
	k.ball("TreeCanopy", 5, at(-2.4, 6.6, 0.8), GRASS:Lerp(W.GrassDark, 0.35))
	k.ball("TreeCanopy", 4.6, at(2.2, 7, -0.9), GRASS:Lerp(W.White, 0.15))
end

-- A white windmill with a red cap and three sail blades on an invisible ModeMover spin root
-- (Mover = "spin", SpinAxis = "Z": the client turns it about its look vector, the axle).
-- Blades lie along the root's right/up vectors (13 parts).
BUILDERS.windmill = function(k, p)
	local y, d = 0, 6
	for i = 1, 3 do
		local h = 4.5
		k.cyl("WindmillTower", h, d, up(0, y + h / 2, 0), if i == 2 then W.Cream else W.White)
		y += h
		d -= 0.9
	end
	k.cyl("WindmillCap", 1.6, d + 1.2, up(0, y + 0.8, 0), W.RainbowRed)
	k.ball("WindmillCap", d + 0.6, at(0, y + 1.6, 0), W.RainbowRed)
	k.block("WindmillDoor", Vector3.new(1.8, 2.8, 0.4), at(0, 1.4, -2.95), TRUNK)
	local hub = at(0, y - 0.6, -(d / 2 + 1.2))
	local root = k.block("WindmillHub", Vector3.new(1, 1, 1), hub, W.White, { Transparency = 1, CastShadow = false })
	root:SetAttribute("Mover", "spin")
	root:SetAttribute("MoveSpeed", p.speed or 0.9)
	root:SetAttribute("MovePhase", 0)
	root:SetAttribute("SpinAxis", "Z")
	root:AddTag("ModeMover")
	k.cyl("WindmillAxle", 1.6, 0.7, hub * at(0, 0, 0.8) * CFrame.Angles(0, math.pi / 2, 0), TRUNK).Parent = root
	k.ball("WindmillBoss", 1.6, hub, W.RainbowYellow).Parent = root
	for i = 0, 2 do
		local blade = hub * CFrame.Angles(0, 0, math.pi / 2 + i * 2 * math.pi / 3)
		k.block("WindmillSpar", Vector3.new(8.5, 0.5, 0.4), blade * at(4.6, 0, 0), TRUNK).Parent = root
		k.block("WindmillSail", Vector3.new(6.5, 2.2, 0.2), blade * at(5.2, 1.2, 0.1), if i == 0 then W.RainbowRed else W.White).Parent =
			root
	end
end

-- A hot-air balloon with its basket at the prop's y: a red envelope ball wrapped in rainbow
-- bands, a pink skirt, four ropes and a wicker basket. The envelope is the MapBob root and
-- everything else rides on it (13 parts).
BUILDERS.balloon = function(k, _p)
	local cy, rr = 15, 6.5
	local root = k.ball("BalloonEnvelope", rr * 2, at(0, cy, 0), W.RainbowRed)
	root:AddTag("MapBob")
	local bands = { W.RainbowOrange, W.RainbowYellow, W.RainbowGreen, W.RainbowBlue, W.RainbowPurple }
	for i, col in bands do
		local h = (i - 3) * 2.3
		local d = 2 * math.sqrt(rr * rr - h * h) + 0.15
		k.cyl("BalloonBand", 1.1, d, up(0, cy + h, 0), col).Parent = root
	end
	k.cyl("BalloonSkirt", 2.4, 4.6, up(0, cy - rr - 0.2, 0), W.RainbowPink).Parent = root
	k.block("BalloonBasket", Vector3.new(3, 2.2, 3), at(0, 1.1, 0), TRUNK, { Material = Enum.Material.WoodPlanks }).Parent = root
	k.block("BalloonBasketRim", Vector3.new(3.3, 0.4, 3.3), at(0, 2.3, 0), W.Cream).Parent = root
	for _, v in { { -1, -1 }, { 1, -1 }, { -1, 1 }, { 1, 1 } } do
		local a = Vector3.new(v[1] * 1.4, 2.4, v[2] * 1.4)
		local b = Vector3.new(v[1] * 1.8, cy - rr - 1.2, v[2] * 1.8)
		k.cyl("BalloonRope", (b - a).Magnitude, 0.18, between(a, b), W.WoodDark).Parent = root
	end
end

-- A soft white cloud of 3-5 overlapping balls centred on the prop's y.
BUILDERS.cloud = function(k, p)
	local puffs = {
		{ 0, 0, 0, 11 },
		{ -6.5, -1.2, 0.6, 8 },
		{ 6.8, -1.4, -0.4, 8.4 },
		{ -2.6, 2.8, -0.6, 7.2 },
		{ 3.2, 2.4, 0.8, 6.6 },
	}
	local n = rng(p):NextInteger(3, 5)
	for i = 1, n do
		local v = puffs[i]
		k.ball("CloudPuff", v[4], at(v[1], v[2], v[3]), W.Cloud, {
			Material = Enum.Material.SmoothPlastic,
			Transparency = 0.05,
			CastShadow = false,
		})
	end
end

-- A gold 5-point star standing upright, centred on the prop's y: a hub disc and five diamond
-- blocks whose outer halves form the points, in a Model that slowly spins (6 parts).
BUILDERS.star = function(k, _p)
	local model = Instance.new("Model")
	model.Name = "Star"
	model:SetAttribute("Spin", 0.6)
	local sk = kit(k.base, k.s, model, k.theme)
	local gold = { Material = Enum.Material.SmoothPlastic, Reflectance = 0.15 }
	model.PrimaryPart = sk.cyl("StarHub", 1, 4.2, CFrame.Angles(0, math.pi / 2, 0), GOLD, gold)
	for i = 0, 4 do
		local a = math.pi / 2 + i * 2 * math.pi / 5
		sk.block(
			"StarPoint",
			Vector3.new(2.7, 2.7, 0.8),
			CFrame.Angles(0, 0, a) * at(2.3, 0, 0) * CFrame.Angles(0, 0, math.pi / 4),
			GOLD,
			gold
		)
	end
	model.Parent = k.parent
end

-- A rainbow arch standing on its feet at the prop's y: seven concentric half-circle bands
-- (red outside to purple inside) of four segments each (six when scaled up big), and a cloud
-- puff on each foot (30-44 parts). Course.ARCH_FEET mirrors the feet.
local ARCH_COLORS = { "RainbowRed", "RainbowOrange", "RainbowYellow", "RainbowGreen", "RainbowCyan", "RainbowBlue", "RainbowPurple" }
BUILDERS.rainbowarch = function(k, _p)
	local outer, band, segments = 20, 1.6, if k.s > 1.5 then 6 else 4
	for i, key in ARCH_COLORS do
		local r = outer - (i - 1) * band
		local chord = 2 * r * math.sin(math.pi / (2 * segments)) + 0.5
		for j = 0, segments - 1 do
			local m = math.pi * (j + 0.5) / segments
			k.block(
				"RainbowBand",
				Vector3.new(chord, band + 0.05, 1.4),
				at(r * math.cos(m), r * math.sin(m), 0) * CFrame.Angles(0, 0, m + math.pi / 2),
				W[key]
			)
		end
	end
	for _, sx in { -1, 1 } do
		k.ball("RainbowCloud", 9, at(sx * (outer - 3 * band), 1.5, 0), W.Cloud, { Transparency = 0.05, CastShadow = false })
	end
end

-- A vertical rainbow loop standing on two cloud puffs at the prop's y, facing its front: seven
-- concentric full rings (red outside to purple inside, outer radius 20) of eight segments
-- each (58 parts).
BUILDERS.loop = function(k, _p)
	local outer, band, segments = 20, 1.6, 8
	local cy = outer + 1
	for i, key in ARCH_COLORS do
		local r = outer - (i - 1) * band
		local chord = 2 * r * math.sin(math.pi / segments) + 0.5
		for j = 0, segments - 1 do
			local m = 2 * math.pi * (j + 0.5) / segments
			k.block(
				"RainbowLoop",
				Vector3.new(chord, band + 0.05, 1.6),
				at(r * math.cos(m), cy + r * math.sin(m), 0) * CFrame.Angles(0, 0, m + math.pi / 2),
				W[key]
			)
		end
	end
	for _, sx in { -1, 1 } do
		k.ball("LoopCloud", 9, at(sx * 4, 1.5, 0), W.Cloud, { Transparency = 0.05, CastShadow = false })
	end
end

-- A spiral rainbow stair: 24 thin candy steps climbing 30 units in two turns around a white
-- pole on a cloud puff, a gold ball on top (28 parts).
local SPIRAL_COLORS =
	{ "RainbowRed", "RainbowOrange", "RainbowYellow", "RainbowGreen", "RainbowCyan", "RainbowBlue", "RainbowPurple", "RainbowPink" }
BUILDERS.spiral = function(k, _p)
	local steps, rise = 24, 30
	k.ball("SpiralCloud", 12, at(0, 0, 0), W.Cloud, { Transparency = 0.05, CastShadow = false })
	k.cyl("SpiralPole", rise + 4, 1.6, up(0, (rise + 4) / 2 + 1, 0), W.White)
	for i = 1, steps do
		local a = (i - 1) * 4 * math.pi / steps
		local y = 2 + (i - 1) * rise / (steps - 1)
		k.block(
			"SpiralStep",
			Vector3.new(8, 0.6, 2.8),
			CFrame.Angles(0, a, 0) * at(4.6, y, 0) * CFrame.Angles(0, math.rad(-8), 0),
			W[SPIRAL_COLORS[(i - 1) % #SPIRAL_COLORS + 1]]
		)
	end
	k.ball("SpiralTop", 3, at(0, rise + 6, 0), GOLD, { Reflectance = 0.12 })
end

-- Landmarks ------------------------------------------------------------------------------
-- Sizes below are prop units at scale 1; Course.LANDMARK_SCALE[theme] scales each to 110-145 studs.

-- A kit for a sub-prop standing at `cf` (prop units) in `k`'s frame, scaled by `scale`.
local function sub(k: Kit, cf: CFrame, scale: number): Kit
	return kit(k.base * CFrame.new(cf.Position * k.s) * cf.Rotation, k.s * scale, k.parent, k.theme)
end

-- Prop units the landmark's foundation sinks into the island it stands on.
local function sink(_k: Kit): number
	return 1.5
end

-- An upright disc sunk a little into the island up to `top` (prop units), `d` wide.
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
	PIECES.palm(sub(k, at(-6, 35, 0) * CFrame.Angles(0, 0.6, 0), 1.35), p)
	PIECES.palm(sub(k, at(6.5, 35, 0.5) * CFrame.Angles(0, 3.4, 0), 1.2), p)
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
		PIECES.fin(fin, { kind = "fin", x = p.x, y = p.y, z = p.z, r = 10.5, speed = 0.45 })
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
		local col = if i % 3 == 0 then STORM:Lerp(W.Steel, 0.18) elseif i % 2 == 0 then STORM else STORM:Lerp(W.White, 0.3)
		k.ball("GiantStormPuff", v[4], at(v[1], v[2], v[3]), col, { Material = Enum.Material.SmoothPlastic })
	end
	k.block("GiantStormBase", Vector3.new(26, 2, 9), at(0, 31.5, 0), STORM:Lerp(W.Steel, 0.25), { Material = Enum.Material.SmoothPlastic })
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

-- A stepped cream plinth with a gold trim and a giant gold Giga (the uploaded mesh scaled to ~34
-- studs when available, else the part-built figure doubled) and bunting front and back (26-36 parts).
LANDMARKS.giga = function(k, p)
	local bottom = -sink(k)
	k.block("GigaPlinth", Vector3.new(26, 3 - bottom, 26), at(0, (3 + bottom) / 2, 0), W.Cream:Lerp(W.Butter, 0.25))
	k.block("GigaPlinth", Vector3.new(21, 3, 21), at(0, 4.5, 0), W.Cream)
	k.block("GigaPlinth", Vector3.new(16, 2, 16), at(0, 7, 0), W.Cream:Lerp(W.White, 0.4))
	k.block("GigaPlinthTrim", Vector3.new(21.4, 0.5, 21.4), at(0, 6.1, 0), GOLD, { Reflectance = 0.12 })
	local size = if Props.has("GigaStatue") then Props.size("GigaStatue") else nil
	local mesh = size and Props.mesh("GigaStatue", k.base * CFrame.new(0, 8 * k.s, 0), k.s * 34 / size.Y, k.parent)
	if not mesh then
		PIECES.statue(sub(k, at(0, 8, 0), 2), p)
	end
	for _, z in { -10, 10 } do
		PIECES.flagline(
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

-- Build -----------------------------------------------------------------------------------

-- Kinds sized by `r` (never scaled).
local BY_RADIUS = { island = true }
local warned: { [string]: boolean } = {}

-- Draws every `level.PROPS` entry into a "Scenery" folder under `folder`.
function MapDecor.build(level: Course.Level, folder: Instance)
	local props: { Prop } = (level :: any).PROPS or {}
	if #props == 0 then
		return
	end
	local theme: string = (level :: any).theme or "beach"
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
		local base = CFrame.new(p.x, p.y, p.z) * CFrame.Angles(0, p.yaw or 0, 0)
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
