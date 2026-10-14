--[[
	MapDress: each Parkour map's own look ON and BESIDE its path (docs/parkour-maps.md, "Map
	identity"), so the ten maps stop reading as one rainbow course. World.Modes asks it for:

	  MapDress.top(theme, i)  the path top colour of the i-th path element (walking order):
	                          the map's TOPS cycle. Course data keeps its rainbow `color`
	                          (tests check it); only the built parts change.
	  MapDress.edge(theme)    the Neon edge colour of the map's path tops (lava orange on the
	                          volcano, volt yellow in the storm ...).
	  MapDress.build(level, parent)
	                          a row of signature props beside the path (palms for Coconut Cove,
	                          shark fins, lava rocks, rising bubbles, storm clouds, coral ...):
	                          one by every EVERY-th path element, alternating sides, each on a
	                          small floating islet a little below the path top. A spot is used
	                          only when its footprint keeps Course.PROP_CLEARANCE + CLEAR_EXTRA
	                          studs (horizontally) from every element at every phase, from the
	                          bridges into and out of the map, from level.PROPS and from the
	                          other dress props. Jump geometry is untouched: every part is
	                          decor (no collide, query or touch).

	Tags the client animates (Client.Fx.Modes): MapBob (buoys, fish, fins: the whole prop is
	parented to its root), MapBubble (bubbles rise with Rise / Top), MapGlow (lava cracks,
	storm bolts, lamp and gem lights breathe; on the volcano they also drop embers). No
	flashing anywhere.

	Every size, colour and count is in DRESS below.
]]

local Common = require(script.Parent.Common)
local Course = require(script.Parent.Parent.Modes.Course)

local make = Common.make
local UPRIGHT = Common.UPRIGHT

local CYLINDER = Enum.PartType.Cylinder
local BALL = Enum.PartType.Ball
local NEON = Enum.Material.Neon
local SMOOTH = Enum.Material.SmoothPlastic

local function rgb(r: number, g: number, b: number): Color3
	return Color3.fromRGB(r, g, b)
end

-- Tunables ------------------------------------------------------------------------------
local DRESS = {
	-- Path tops per theme, cycled in walking order, and the Neon edge colour.
	TOPS = {
		beach = { rgb(255, 214, 72), rgb(255, 238, 168), rgb(255, 166, 84) },
		cove = { rgb(104, 226, 160), rgb(244, 220, 168), rgb(56, 186, 126) },
		bay = { rgb(248, 250, 255), rgb(150, 168, 255), rgb(255, 112, 112) },
		reef = { rgb(255, 96, 176), rgb(80, 220, 210), rgb(255, 178, 214) },
		-- Saturated aqua and teal (not pale ice): the path stands well clear of the deep-blue sky.
		bubble = { rgb(0, 206, 196), rgb(40, 232, 222), rgb(0, 166, 190) },
		-- Coral and shark: no pale tops (they matched their pale sunset / sea skies).
		coral = { rgb(255, 146, 80), rgb(255, 92, 120), rgb(222, 104, 70) },
		shark = { rgb(255, 128, 112), rgb(32, 74, 128), rgb(46, 150, 160) },
		storm = { rgb(118, 130, 160), rgb(166, 178, 206), rgb(92, 104, 132) },
		volcano = { rgb(78, 66, 78), rgb(104, 86, 90), rgb(255, 120, 40) },
		giga = { rgb(255, 246, 228), rgb(255, 204, 64), rgb(176, 136, 255) },
	} :: { [string]: { Color3 } },
	EDGE = {
		beach = rgb(255, 250, 222),
		cove = rgb(196, 255, 222),
		bay = rgb(255, 92, 92),
		reef = rgb(120, 255, 240),
		bubble = rgb(246, 255, 255),
		coral = rgb(255, 226, 186),
		shark = rgb(84, 236, 236),
		storm = rgb(240, 255, 56),
		volcano = rgb(255, 98, 16),
		giga = rgb(255, 212, 72),
	} :: { [string]: Color3 },
	-- Which prop each theme lines its path with (a list: cycled along the path).
	PROP = {
		beach = { "palm", "umbrella", "buoy" },
		cove = "palm",
		bay = "buoy",
		reef = "fish",
		bubble = "bubbles",
		coral = "coral",
		shark = "fin",
		storm = "stormcloud",
		volcano = "lavarock",
		giga = "crownpillar",
	} :: { [string]: string | { string } },
	EVERY = 2, -- one prop by every 2nd path element
	FIRST = 2, -- path index of the first one (not by the start deck)
	MAX = 16, -- props per map at most
	OFFSETS = { 13, 17, 22, 28 }, -- studs out from the element's centre line, tried in order
	CLEAR_EXTRA = 2, -- studs on top of Course.PROP_CLEARANCE
	FOOT = 4.5, -- footprint radius of a prop and its islet (at SCALE)
	SCALE = 1.25, -- every prop's uniform scale
	DROP = 4, -- the islet's top sits this far under the path element's top
	ISLET_R = 4.2, -- islet radius (prop units)
	ISLET_H = 1.4,
	-- Islet colours per theme: top, rim.
	ISLET = {
		beach = { rgb(244, 220, 164), rgb(214, 180, 120) },
		cove = { rgb(244, 220, 164), rgb(92, 176, 96) },
		bay = { rgb(84, 170, 230), rgb(248, 250, 255) },
		reef = { rgb(244, 220, 164), rgb(80, 220, 210) },
		bubble = { rgb(0, 190, 200), rgb(248, 250, 255) },
		coral = { rgb(244, 214, 170), rgb(222, 104, 70) },
		shark = { rgb(46, 150, 180), rgb(248, 250, 255) },
		storm = { rgb(110, 120, 146), rgb(70, 78, 100) },
		volcano = { rgb(54, 46, 56), rgb(255, 98, 16) },
		giga = { rgb(255, 246, 228), rgb(255, 196, 40) },
	} :: { [string]: { Color3 } },
	ROCK_BELOW = rgb(150, 132, 120), -- the islet's rocky underside
	-- Prop colours.
	UMBRELLA = { rgb(255, 92, 92), rgb(255, 250, 240), rgb(70, 160, 255), rgb(255, 214, 72) },
	POLE = rgb(250, 246, 236),
	BALL = { rgb(255, 92, 92), rgb(255, 214, 72), rgb(70, 160, 255) },
	TRUNK = rgb(168, 112, 70),
	TRUNK_RING = rgb(132, 84, 52),
	LEAF = rgb(60, 190, 90),
	LEAF_DARK = rgb(40, 150, 76),
	COCONUT = rgb(110, 70, 40),
	BUOY = { rgb(255, 80, 80), rgb(250, 250, 255) },
	BUOY_LAMP = rgb(255, 230, 90),
	FISH = { rgb(255, 140, 40), rgb(255, 214, 72), rgb(255, 96, 176) },
	FISH_BAND = rgb(255, 255, 255),
	FISH_EYE = rgb(30, 30, 40),
	WEED = rgb(70, 200, 110),
	-- Soap-bubble tints (aqua, pink, lilac) that show against the blue sky, big and fairly solid.
	BUBBLE = { rgb(120, 236, 255), rgb(255, 150, 226), rgb(186, 160, 255) },
	BUBBLE_ALPHA = 0.25,
	BUBBLE_REFLECT = 0.3,
	BUBBLE_COUNT = 6, -- per prop
	BUBBLE_D = { 3, 5.4 }, -- diameter range (prop units)
	BUBBLE_STEP = 2.4, -- height between the bubbles of one prop
	BUBBLE_RISE = { 3, 5 }, -- studs/s
	BUBBLE_TOP = 18, -- studs above the islet the bubbles climb (prop units)
	CORAL = { rgb(255, 120, 110), rgb(255, 96, 176), rgb(255, 160, 70) },
	CORAL_TIP = rgb(255, 236, 200),
	FIN = rgb(64, 84, 104),
	FIN_BELLY = rgb(220, 232, 240),
	WAVE = rgb(240, 250, 255),
	STORM_PUFF = { rgb(150, 158, 178), rgb(176, 184, 202), rgb(128, 136, 158) },
	BOLT = rgb(240, 255, 56),
	BASALT = rgb(58, 50, 60),
	LAVA = rgb(255, 104, 18),
	GOLD = rgb(255, 196, 40),
	GOLD_DEEP = rgb(222, 150, 30),
	BANNER = rgb(150, 100, 240),
	GEM = rgb(255, 64, 158),
}

local MapDress = {}

-- Path colours ---------------------------------------------------------------------------

function MapDress.top(theme: string?, i: number): Color3?
	local tops = theme and DRESS.TOPS[theme]
	return if tops then tops[(i - 1) % #tops + 1] else nil
end

function MapDress.edge(theme: string?): Color3?
	return if theme then DRESS.EDGE[theme] else nil
end

-- Parts -----------------------------------------------------------------------------------

type Kit = {
	base: CFrame,
	s: number,
	parent: Instance,
	block: (name: string, size: Vector3, cf: CFrame, col: Color3, extra: { [string]: any }?) -> BasePart,
	cyl: (name: string, length: number, d: number, cf: CFrame, col: Color3, extra: { [string]: any }?) -> BasePart,
	ball: (name: string, d: number, cf: CFrame, col: Color3, extra: { [string]: any }?) -> BasePart,
	wedge: (name: string, size: Vector3, cf: CFrame, col: Color3, extra: { [string]: any }?) -> BasePart,
}

-- Part makers in a prop's frame (`base`, unscaled prop units times `s`); every part is decor.
local function kit(base: CFrame, s: number, parent: Instance): Kit
	local function put(className: string, name: string, size: Vector3, cf: CFrame, col: Color3, extra: { [string]: any }?): BasePart
		local props: { [string]: any } = {
			Name = name,
			Size = size * s,
			CFrame = base * CFrame.new(cf.Position * s) * cf.Rotation,
			Color = col,
			Material = SMOOTH,
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
	return {
		base = base,
		s = s,
		parent = parent,
		block = function(name, size, cf, col, extra)
			return put("Part", name, size, cf, col, extra)
		end,
		cyl = function(name, length, d, cf, col, extra)
			local props = table.clone(extra or {})
			props.Shape = CYLINDER
			return put("Part", name, Vector3.new(length, d, d), cf, col, props)
		end,
		ball = function(name, d, cf, col, extra)
			local props = table.clone(extra or {})
			props.Shape = BALL
			return put("Part", name, Vector3.new(d, d, d), cf, col, props)
		end,
		wedge = function(name, size, cf, col, extra)
			return put("WedgePart", name, size, cf, col, extra)
		end,
	}
end

local function at(x: number, y: number, z: number): CFrame
	return CFrame.new(x, y, z)
end

local function up(x: number, y: number, z: number): CFrame
	return CFrame.new(x, y, z) * UPRIGHT
end

-- Floating islet (top at prop y = 0): a disc, a coloured rim and a rocky underside.
local function islet(k: Kit, theme: string)
	local cols = DRESS.ISLET[theme] or DRESS.ISLET.beach
	local r, h = DRESS.ISLET_R, DRESS.ISLET_H
	k.cyl("IsletTop", h, r * 2, up(0, -h / 2, 0), cols[1])
	k.cyl("IsletRim", h * 0.6, r * 2 + 0.6, up(0, -h - 0.2, 0), cols[2])
	k.cyl("IsletBase", 1.6, r * 1.5, up(0, -h - 1.3, 0), DRESS.ROCK_BELOW)
	k.ball("IsletRoot", r * 0.9, at(0, -h - 2.2, 0), DRESS.ROCK_BELOW)
end

-- Makes `root` (a visible part: the map preview drops invisible ones with their children) a
-- MapBob root and returns a kit whose parts hang under it, so they bob with it.
local function bobOn(k: Kit, root: BasePart): Kit
	root:AddTag("MapBob")
	return kit(k.base, k.s, root)
end

-- Props (base at the islet top, front -Z toward the path) -------------------------------

local PROPS: { [string]: (k: Kit, rand: Random) -> () } = {}

PROPS.umbrella = function(k, rand)
	k.cyl("UmbrellaPole", 9, 0.35, up(0, 4.5, 0), DRESS.POLE)
	-- A 6-panel canopy: alternating wedges round the pole, tilted down.
	local cols = DRESS.UMBRELLA
	local col = cols[rand:NextInteger(1, #cols)]
	if col == cols[2] then
		col = cols[1]
	end
	for i = 0, 5 do
		local a = i * math.pi / 3
		local panel = if i % 2 == 0 then col else cols[2]
		k.wedge(
			"Canopy",
			Vector3.new(3.4, 1.2, 4.2),
			CFrame.new(0, 8.6, 0) * CFrame.Angles(0, a, 0) * CFrame.new(0, 0, -2.1) * CFrame.Angles(math.rad(-14), 0, 0),
			panel
		)
	end
	k.ball("Finial", 0.7, at(0, 9.5, 0), col)
	k.block("Towel", Vector3.new(2.6, 0.12, 5), at(2.2, 0.06, 0.8), cols[3])
	k.ball("BeachBall", 2, at(-2.3, 1, 1.4), DRESS.BALL[rand:NextInteger(1, #DRESS.BALL)])
end

PROPS.palm = function(k, rand)
	-- A curved trunk of five tilting segments, a crown of drooping leaves and coconuts.
	local lean = rand:NextNumber(0.12, 0.2)
	local p = Vector3.new(0, 0, 0)
	local dir = 0
	for i = 1, 5 do
		dir += lean
		local seg = Vector3.new(math.sin(dir) * 2.4, math.cos(dir) * 2.4, 0)
		local mid = p + seg / 2
		k.cyl(
			"PalmTrunk",
			2.6,
			1.3 - i * 0.08,
			CFrame.new(mid) * CFrame.Angles(0, 0, -dir) * UPRIGHT,
			if i % 2 == 0 then DRESS.TRUNK_RING else DRESS.TRUNK
		)
		p += seg
	end
	for i = 0, 6 do
		local a = i * 2 * math.pi / 7
		k.block(
			"PalmLeaf",
			Vector3.new(1.3, 0.3, 6),
			CFrame.new(p) * CFrame.Angles(0, a, 0) * CFrame.new(0, -0.6, -2.8) * CFrame.Angles(math.rad(-28), 0, 0),
			if i % 2 == 0 then DRESS.LEAF else DRESS.LEAF_DARK
		)
	end
	for i = 0, 2 do
		local a = i * 2 * math.pi / 3 + 0.4
		k.ball("Coconut", 0.9, CFrame.new(p) * CFrame.new(math.cos(a) * 0.7, -0.7, math.sin(a) * 0.7), DRESS.COCONUT)
	end
end

PROPS.buoy = function(k, _rand)
	local b = bobOn(k, k.cyl("BuoyBand", 1.5, 3.4, up(0, 0.75, 0), DRESS.BUOY[1]))
	for i = 1, 3 do
		b.cyl("BuoyBand", 1.5, 3.4 - i * 0.3, up(0, 0.75 + i * 1.5, 0), DRESS.BUOY[i % 2 + 1])
	end
	b.cyl("BuoyMast", 2.4, 0.4, up(0, 7, 0), DRESS.POLE)
	b.ball("BuoyLamp", 1.4, at(0, 8.4, 0), DRESS.BUOY_LAMP, { Material = NEON }):AddTag("MapGlow")
	b.cyl("BuoyRing", 0.4, 4.4, up(0, 0.3, 0), DRESS.BUOY[2])
end

PROPS.fish = function(k, rand)
	-- Seaweed on the islet and a big clownfish bobbing above it.
	for i = 1, 3 do
		local x, z = (i - 2) * 1.6, rand:NextNumber(-1, 1)
		local h = rand:NextNumber(3.5, 6)
		k.block("Seaweed", Vector3.new(0.5, h, 0.5), at(x, h / 2, z) * CFrame.Angles(0, 0, rand:NextNumber(-0.2, 0.2)), DRESS.WEED)
	end
	local col = DRESS.FISH[rand:NextInteger(1, #DRESS.FISH)]
	local f = bobOn(k, k.cyl("FishBody", 4.2, 2.6, at(0, 6.5, 0), col))
	f.ball("FishHead", 2.6, at(-2.1, 6.5, 0), col)
	for _, x in { -0.6, 1 } do
		f.cyl("FishBand", 0.5, 2.75, at(x, 6.5, 0), DRESS.FISH_BAND)
	end
	f.wedge("FishTail", Vector3.new(0.4, 2.6, 1.8), at(2.9, 6.5, 0) * CFrame.Angles(0, math.pi / 2, 0), col)
	for _, z in { -1, 1 } do
		f.ball("FishEye", 0.6, at(-2.8, 6.9, z * 0.85), DRESS.FISH_EYE)
	end
	f.wedge("FishFin", Vector3.new(0.3, 1.2, 1.6), at(0.2, 8.1, 0) * CFrame.Angles(0, math.pi / 2, 0), col)
end

PROPS.bubbles = function(k, rand)
	local n = DRESS.BUBBLE_COUNT
	for i = 1, n do
		local a = i * 2 * math.pi / n
		local d = rand:NextNumber(DRESS.BUBBLE_D[1], DRESS.BUBBLE_D[2])
		local bubble = k.ball(
			"Bubble",
			d,
			at(math.cos(a) * 2.2, 1 + i * DRESS.BUBBLE_STEP, math.sin(a) * 2.2),
			DRESS.BUBBLE[i % #DRESS.BUBBLE + 1],
			{ Transparency = DRESS.BUBBLE_ALPHA, Reflectance = DRESS.BUBBLE_REFLECT, CastShadow = false }
		)
		bubble:SetAttribute("Rise", rand:NextNumber(DRESS.BUBBLE_RISE[1], DRESS.BUBBLE_RISE[2]))
		bubble:SetAttribute("Top", k.base.Y + DRESS.BUBBLE_TOP * k.s)
		bubble:AddTag("MapBubble")
	end
	k.ball("BeachBall", 2, at(0, 1, 0), DRESS.BALL[rand:NextInteger(1, #DRESS.BALL)])
end

PROPS.coral = function(k, rand)
	-- Staghorn coral: three branching stems with pale tips, and a round brain coral.
	for i = 1, 3 do
		local col = DRESS.CORAL[(i + rand:NextInteger(0, 2)) % #DRESS.CORAL + 1]
		local x = (i - 2) * 1.8
		local h = rand:NextNumber(5, 8)
		local tilt = (i - 2) * 0.22
		local stem = CFrame.new(x, 0, 0) * CFrame.Angles(0, 0, -tilt)
		k.cyl("CoralStem", h, 1, stem * CFrame.new(0, h / 2, 0) * UPRIGHT, col)
		k.ball("CoralTip", 1.3, stem * CFrame.new(0, h, 0), DRESS.CORAL_TIP)
		for _, side in { -1, 1 } do
			local by = h * 0.55
			local arm = stem * CFrame.new(0, by, 0) * CFrame.Angles(0, 0, side * 0.7)
			k.cyl("CoralArm", 2.6, 0.7, arm * CFrame.new(0, 1.3, 0) * UPRIGHT, col)
			k.ball("CoralTip", 0.9, arm * CFrame.new(0, 2.6, 0), DRESS.CORAL_TIP)
		end
	end
	k.ball("BrainCoral", 2.6, at(0, 0.6, 2), DRESS.CORAL[2])
end

PROPS.fin = function(k, _rand)
	-- A shark fin cutting through a ring of foam, bobbing.
	k.cyl("Foam", 0.3, 6, up(0, 0.15, 0), DRESS.WAVE)
	local f = bobOn(k, k.block("FinBase", Vector3.new(1, 0.6, 4.4), at(0, 0.5, 0.1), DRESS.FIN))
	f.wedge("SharkFin", Vector3.new(0.7, 5.5, 4.2), at(0, 3.1, 0), DRESS.FIN)
	f.wedge("FinTip", Vector3.new(0.72, 1, 0.9), at(0, 6.1, 1.65), DRESS.FIN_BELLY)
end

PROPS.stormcloud = function(k, rand)
	-- A grey puff cloud hovering over the islet with a still volt bolt (glows, never flashes).
	local cy = 10
	for i = 1, 6 do
		local a = i * 2 * math.pi / 6
		local d = rand:NextNumber(3, 4.6)
		k.ball("StormPuff", d, at(math.cos(a) * 2.6, cy + rand:NextNumber(-0.5, 0.8), math.sin(a) * 1.8), DRESS.STORM_PUFF[i % 3 + 1])
	end
	k.ball("StormPuff", 5, at(0, cy + 1, 0), DRESS.STORM_PUFF[2])
	local zig = { { 0.6, 8, 0.4 }, { -0.6, 5.6, -0.5 }, { 0.5, 3.2, 0.4 } }
	for i, z in zig do
		local bolt =
			k.block("StormBolt", Vector3.new(0.6, 2.8, 0.6), at(z[1], z[2], 0) * CFrame.Angles(0, 0, z[3]), DRESS.BOLT, { Material = NEON })
		if i == 2 then
			bolt:AddTag("MapGlow")
		end
	end
	k.cyl("StormRod", 3, 0.5, up(0, 1.5, 0), DRESS.POLE)
end

PROPS.lavarock = function(k, rand)
	-- A basalt boulder heap with a glowing lava crack and pool (MapGlow: embers on the volcano).
	for i = 1, 3 do
		local sz = rand:NextNumber(2.4, 3.6)
		k.block(
			"Basalt",
			Vector3.new(sz, sz * 0.9, sz),
			at((i - 2) * 1.8, sz * 0.4, rand:NextNumber(-0.6, 0.6))
				* CFrame.Angles(rand:NextNumber(-0.4, 0.4), rand:NextNumber(0, 3), rand:NextNumber(-0.4, 0.4)),
			DRESS.BASALT
		)
	end
	k.block("Basalt", Vector3.new(2.6, 4.6, 2.4), at(0.4, 2.6, -0.2) * CFrame.Angles(0.15, 0.6, -0.1), DRESS.BASALT)
	k.block("LavaCrack", Vector3.new(0.5, 4, 0.5), at(-0.3, 2.4, -1.3) * CFrame.Angles(0, 0, 0.3), DRESS.LAVA, { Material = NEON })
	k.cyl("LavaPool", 0.25, 5.4, up(0, 0.1, 0), DRESS.LAVA, { Material = NEON }):AddTag("MapGlow")
end

PROPS.crownpillar = function(k, rand)
	-- A gold column with a purple banner and a crown with a glowing gem on top.
	k.cyl("PillarBase", 1, 3.6, up(0, 0.5, 0), DRESS.GOLD_DEEP)
	k.cyl("Pillar", 8, 2.2, up(0, 5, 0), DRESS.GOLD)
	k.cyl("PillarCap", 0.8, 3.4, up(0, 9.4, 0), DRESS.GOLD_DEEP)
	k.block("Banner", Vector3.new(1.8, 4.2, 0.2), at(0, 6, -1.2), DRESS.BANNER)
	k.wedge("BannerTail", Vector3.new(1.8, 0.9, 0.2), at(0, 3.45, -1.2) * CFrame.Angles(0, 0, math.pi), DRESS.BANNER)
	k.cyl("CrownBand", 1, 3, up(0, 10.3, 0), DRESS.GOLD)
	for i = 0, 4 do
		local a = i * 2 * math.pi / 5 + rand:NextNumber(0, 0.1)
		k.wedge(
			"CrownPoint",
			Vector3.new(0.6, 1.4, 0.9),
			at(math.cos(a) * 1.3, 11.4, math.sin(a) * 1.3) * CFrame.Angles(0, -a, 0),
			DRESS.GOLD
		)
	end
	k.ball("CrownGem", 0.9, at(0, 11, -1.45), DRESS.GEM, { Material = NEON }):AddTag("MapGlow")
end

-- Placement -------------------------------------------------------------------------------

local function centre(e: Course.Element): (number, number, number)
	if e.kind == "slide" then
		local a, b = e.from :: { number }, e.to :: { number }
		return (a[1] + b[1]) / 2, math.min(a[2], b[2]), (a[3] + b[3]) / 2
	end
	return e.x, e.y, e.z
end

type Spot = { x: number, z: number, r: number }

-- The level's own props (islands, clouds ...) as footprints.
local function takenByProps(level: Course.Level): { Spot }
	local list: { Spot } = {}
	for _, p in level.PROPS do
		local foot = if p.kind == "island" then p.r or 0 else (Course.PROP_FOOT[p.kind] or 6) * (p.scale or 1)
		table.insert(list, { x = p.x, z = p.z, r = foot })
	end
	return list
end

local function clearOf(list: { Course.Element }, x: number, z: number): number
	local best = math.huge
	for _, e in list do
		best = math.min(best, Course.footDistance(e, x, z))
	end
	return best
end

function MapDress.build(level: Course.Level, parent: Instance)
	local theme = level.theme
	local kinds = DRESS.PROP[theme] or {}
	local list: { string } = if type(kinds) == "table" then kinds else { kinds }
	local path = level.PATH
	if not PROPS[list[1] or ""] or not path or #path < 3 then
		return
	end
	local folder = Instance.new("Folder")
	folder.Name = "MapDress"
	local bridges = (Course :: any).BRIDGES or {}
	local near: { Course.Element } = table.clone(level.ELEMENTS)
	for _, n in { level.index - 1, level.index } do
		for _, e in bridges[n] or {} do
			table.insert(near, e)
		end
	end
	local taken = takenByProps(level)
	local foot = DRESS.FOOT * DRESS.SCALE
	local need = foot + Course.PROP_CLEARANCE + DRESS.CLEAR_EXTRA
	local rand = Random.new(level.index * 4241 + 7)
	local side = 1
	local count = 0
	for i = DRESS.FIRST, #path - 1, DRESS.EVERY do
		if count >= DRESS.MAX then
			break
		end
		local e = path[i]
		local ex, ey, ez = centre(e)
		local nx, _, nz = centre(path[i + 1])
		local dx, dz = nx - ex, nz - ez
		local len = math.sqrt(dx * dx + dz * dz)
		if len > 1e-3 then
			dx, dz = dx / len, dz / len
			local px, pz = -dz, dx
			local done = false
			for _, d in DRESS.OFFSETS do
				for _, s in { side, -side } do
					local x, z = ex + px * s * d, ez + pz * s * d
					local free = clearOf(near, x, z) >= need
					for _, t in taken do
						if free and math.sqrt((x - t.x) ^ 2 + (z - t.z) ^ 2) < foot + t.r + 1 then
							free = false
						end
					end
					if free then
						-- Front (-Z) toward the path.
						local base = CFrame.lookAt(Vector3.new(x, ey - DRESS.DROP, z), Vector3.new(ex, ey - DRESS.DROP, ez))
						local k = kit(base, DRESS.SCALE, folder)
						islet(k, theme)
						PROPS[list[count % #list + 1]](k, rand)
						table.insert(taken, { x = x, z = z, r = foot })
						count += 1
						side = -s
						done = true
						break
					end
				end
				if done then
					break
				end
			end
		end
	end
	folder.Parent = parent
end

return MapDress
