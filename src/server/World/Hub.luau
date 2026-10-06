--[[
	Hub: lighting, the island world around the map and the central hub plaza.

	Everything stands on one big sand island in an ocean that runs to the horizon, with a few
	low-poly palm islands out at sea. The round plaza in the middle holds a golden Chad statue on
	a trophy podium, the two ranking scoreboards, benches and planters; a pale plank boardwalk
	ring runs between the plaza and the two plot rows and spurs into every plot entrance.
	Hub colours follow the plots: teal posts and frames, sunny caps and rings, and cream sign
	cards with red-orange header bands.

	Every decorative prop is a Model named Prop_<Kind> (attribute Mesh = "<Kind>") whose
	PrimaryPart sits at the prop's base centre and whose front faces -Z; World.Props swaps in the
	uploaded Blender mesh where there is one (the part-built version is the fallback). Sky clouds
	are "Cloud" models so Client.Fx.Ambient can drift them.
	Part of the world generator; see Server.WorldBuilder for the overview and plot axes.
]]

local Lighting = game:GetService("Lighting")
local Workspace = game:GetService("Workspace")

local Common = require(script.Parent.Common)
local Props = require(script.Parent.Props)
local ModesCourse = require(script.Parent.Parent.Modes.Course)

local theme = Common.theme
local mapFolder = Common.mapFolder
local PLOT_HALF = Common.PLOT_HALF
local HUB_RADIUS = Common.HUB_RADIUS
local PLOT_SPACING_X = Common.PLOT_SPACING_X
local PLOT_ROW_Z = Common.PLOT_ROW_Z
local CROSS_Z = Common.CROSS_Z
local ENTRANCE_Z = Common.ENTRANCE_Z
local UPRIGHT = Common.UPRIGHT
local ALONG_Z = Common.ALONG_Z
local make = Common.make
local part = Common.part

local W = theme.World
local CYLINDER = Enum.PartType.Cylinder
local BALL = Enum.PartType.Ball

-- Sand island: reaches past the far corners of the outer plots with a wide beach.
local ISLAND_RADIUS = math.ceil(math.sqrt((PLOT_SPACING_X + PLOT_HALF) ^ 2 + (PLOT_ROW_Z + PLOT_HALF) ^ 2)) + 22
local SAND_TOP = -0.1
local OCEAN_TOP = -1.2
local OCEAN_TILE = 2048

-- Plaza surface heights (thin stacked discs, each a hair above the one below).
local PLAZA_RIM_TOP = 0.35
local PLAZA_TOP = 0.38
local PLAZA_RING_TOP = 0.41
local PLAZA_INNER_TOP = 0.44
local PLAZA_INNER_RADIUS = 18

-- Boardwalk ring: rows along |z| = CROSS_Z, sides along |x| = RING_X, spurs into every plot
-- entrance and a wide connector from the plaza to each row.
local DECK_TOP = 0.3
local WALK_HALF = 5
local CONNECTOR_HALF = 6
local RING_X = PLOT_SPACING_X + 19
local RING_OUT = RING_X + WALK_HALF

-- Scoreboards stand on the x axis inside the plaza.
local SCOREBOARD_X = 19.5
local ARCH_Z = HUB_RADIUS + 3

local Hub = {}

-- Lighting ------------------------------------------------------------------------------

local function setupLighting()
	local l = theme.Lighting
	Lighting.ClockTime = l.ClockTime
	Lighting.GeographicLatitude = l.GeographicLatitude
	Lighting.Ambient = l.Ambient
	Lighting.OutdoorAmbient = l.OutdoorAmbient
	Lighting.Brightness = l.Brightness
	Lighting.ExposureCompensation = l.Exposure
	Lighting.EnvironmentDiffuseScale = l.EnvironmentDiffuseScale
	Lighting.EnvironmentSpecularScale = l.EnvironmentSpecularScale
	Lighting.GlobalShadows = true
	-- Short, crisp afternoon shadows with a warm tint on sunlit faces.
	Lighting.ShadowSoftness = l.ShadowSoftness
	Lighting.ColorShift_Top = l.ColorShiftTop
	Lighting.ColorShift_Bottom = l.ColorShiftBottom
	Lighting.FogColor = l.FogColor
	Lighting.FogStart = l.FogStart
	Lighting.FogEnd = l.FogEnd

	-- A light pale-azure haze low on the sky with a low offset, so the blue skybox pales toward
	-- a crisp horizon line over the turquoise sea; density stays low so distant plots stay crisp.
	local atmosphere = Lighting:FindFirstChildOfClass("Atmosphere") or Instance.new("Atmosphere")
	atmosphere.Color = l.AtmosphereColor
	atmosphere.Decay = l.AtmosphereDecay
	atmosphere.Density = l.AtmosphereDensity
	atmosphere.Haze = l.AtmosphereHaze
	atmosphere.Glare = l.AtmosphereGlare
	atmosphere.Offset = l.AtmosphereOffset
	atmosphere.Parent = Lighting

	local s = l.Sky
	local sky = Lighting:FindFirstChildOfClass("Sky") or Instance.new("Sky")
	sky.SkyboxBk = s.Back
	sky.SkyboxFt = s.Front
	sky.SkyboxLf = s.Left
	sky.SkyboxRt = s.Right
	sky.SkyboxDn = s.Down
	sky.SkyboxUp = s.Up
	sky.SunTextureId = s.Sun
	sky.MoonTextureId = s.Moon
	sky.SunAngularSize = s.SunAngularSize
	sky.StarCount = s.StarCount
	sky.CelestialBodiesShown = true
	sky.Parent = Lighting

	-- Almost no bloom: colour comes from paint, not glow.
	local bloom = Lighting:FindFirstChildOfClass("BloomEffect") or Instance.new("BloomEffect")
	bloom.Intensity = l.BloomIntensity
	bloom.Threshold = l.BloomThreshold
	bloom.Size = l.BloomSize
	bloom.Parent = Lighting

	local cc = Lighting:FindFirstChildOfClass("ColorCorrectionEffect") or Instance.new("ColorCorrectionEffect")
	cc.TintColor = l.ColorTint
	cc.Saturation = l.Saturation
	cc.Contrast = l.Contrast
	cc.Brightness = l.ColorBrightness
	cc.Parent = Lighting

	local rays = Lighting:FindFirstChildOfClass("SunRaysEffect") or Instance.new("SunRaysEffect")
	rays.Intensity = l.SunRaysIntensity
	rays.Spread = l.SunRaysSpread
	rays.Parent = Lighting

	local terrain = Workspace:FindFirstChildOfClass("Terrain")
	if terrain then
		local clouds = terrain:FindFirstChildOfClass("Clouds") or Instance.new("Clouds")
		clouds.Cover = l.Clouds.Cover
		clouds.Density = l.Clouds.Density
		clouds.Color = l.Clouds.Color
		clouds.Parent = terrain
	end
end

-- Helpers -------------------------------------------------------------------------------

type Adder = (props: { [string]: any }, className: string?) -> BasePart

-- Yaw (about +Y) that turns a frame's front (-Z) from (fromX, fromZ) toward (toX, toZ).
local function yawToward(fromX: number, fromZ: number, toX: number, toZ: number): number
	return math.atan2(-(toX - fromX), -(toZ - fromZ))
end

-- A uniform size (balls must be uniform).
local function cube(d: number): Vector3
	return Vector3.new(d, d, d)
end

local function ground(x: number, z: number, yaw: number?): CFrame
	return CFrame.new(x, 0, z) * CFrame.Angles(0, yaw or 0, 0)
end

-- A Prop_<kind> model rooted at `base` (its base centre). The returned adder builds parts in
-- the prop's own space (props.CFrame is relative to `base`).
local function newProp(kind: string, base: CFrame, name: string?): (Model, Adder)
	local model = Instance.new("Model")
	model.Name = name or ("Prop_" .. kind)
	model:SetAttribute("Mesh", kind)
	local root = part({
		Name = "PropRoot",
		Size = Vector3.new(1, 0.2, 1),
		CFrame = base,
		Transparency = 1,
		CanCollide = false,
		CanQuery = false,
		CanTouch = false,
		CastShadow = false,
		Parent = model,
	})
	model.PrimaryPart = root
	model.Parent = mapFolder
	local function add(props: { [string]: any }, className: string?): BasePart
		props.CFrame = base * (props.CFrame or CFrame.new())
		props.Parent = model
		return make(className or "Part", props)
	end
	return model, add
end

-- A flat world disc whose top face sits at `top`.
local function disc(
	name: string,
	radius: number,
	top: number,
	thickness: number,
	color: Color3,
	x: number?,
	z: number?,
	material: Enum.Material?
)
	return part({
		Name = name,
		Shape = CYLINDER,
		Size = Vector3.new(thickness, radius * 2, radius * 2),
		CFrame = CFrame.new(x or 0, top - thickness / 2, z or 0) * UPRIGHT,
		Color = color,
		Material = material,
	})
end

-- A SurfaceGui on one face of `p`, returning a transparent full-size root frame.
local function surface(p: BasePart, face: Enum.NormalId, pixelsPerStud: number): Frame
	local gui = Instance.new("SurfaceGui")
	gui.Face = face
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = pixelsPerStud
	gui.LightInfluence = 0
	gui.Parent = p
	local root = Instance.new("Frame")
	root.Size = UDim2.fromScale(1, 1)
	root.BackgroundTransparency = 1
	root.BorderSizePixel = 0
	root.Parent = gui
	return root
end

local function panel(parent: Instance, color: Color3, position: UDim2, size: UDim2, corner: number?): Frame
	local f = Instance.new("Frame")
	f.BackgroundColor3 = color
	f.BorderSizePixel = 0
	f.Position = position
	f.Size = size
	f.Parent = parent
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(corner or 0.08, 0)
	c.Parent = f
	return f
end

local function text(parent: Instance, props: { [string]: any }): TextLabel
	local l = Instance.new("TextLabel")
	l.BackgroundTransparency = 1
	l.TextScaled = true
	l.Font = theme.Fonts.Display
	l.TextColor3 = W.Ink
	l.Size = UDim2.fromScale(1, 1)
	for key, value in props do
		(l :: any)[key] = value
	end
	l.Parent = parent
	return l
end

-- Props ---------------------------------------------------------------------------------

-- Chunky palm: stacked ring segments that curve gently, a crown of fronds and coconuts.
-- `detailed` adds a drooping tip to every frond (used near the plaza).
local function palmTree(base: CFrame, height: number, lean: number, detailed: boolean)
	local model, add = newProp("PalmTree", base)
	model:SetAttribute("Height", height)
	-- The palm mesh is authored for Height 16.
	model:SetAttribute("MeshScale", height / 16)
	local s = height / 16
	local segments = 4
	local segLength = height / segments
	local frame = CFrame.new()
	for i = 1, segments do
		frame = frame * CFrame.Angles(lean / segments, 0, 0)
		local d = (1.9 - 0.55 * (i - 1) / (segments - 1)) * s
		add({
			Name = "Trunk",
			Shape = CYLINDER,
			Size = Vector3.new(segLength + 0.3 * s, d, d),
			CFrame = frame * CFrame.new(0, segLength / 2, 0) * UPRIGHT,
			Color = if i % 2 == 0 then W.WoodDark else W.Wood,
		})
		frame = frame * CFrame.new(0, segLength, 0)
	end
	local top = CFrame.new(frame.Position)
	add({ Name = "Crown", Shape = BALL, Size = cube(2.2 * s), CFrame = top, Color = W.GrassDark })
	for k = 1, 3 do
		add({
			Name = "Coconut",
			Shape = BALL,
			Size = cube(1.1 * s),
			CFrame = top * CFrame.Angles(0, k * 2.1, 0) * CFrame.new(0, -0.8 * s, -0.75 * s),
			Color = W.WoodDark,
			CanCollide = false,
		})
	end
	local fronds = 7
	for i = 1, fronds do
		local yaw = (i + 0.3) * 2 * math.pi / fronds
		local length = 6.2 * s
		local color = if i % 2 == 0 then W.Grass else W.GrassDark
		local f = top * CFrame.Angles(0, yaw, 0) * CFrame.Angles(if detailed then 0.12 else -0.3, 0, 0)
		add({
			Name = "Frond",
			Size = Vector3.new(2 * s, 0.35 * s, length),
			CFrame = f * CFrame.new(0, 0, -length / 2),
			Color = color,
			CanCollide = false,
		})
		if detailed then
			local tip = 3.8 * s
			add({
				Name = "Frond",
				Size = Vector3.new(1.4 * s, 0.3 * s, tip),
				CFrame = f * CFrame.new(0, 0, -length + 0.2 * s) * CFrame.Angles(-0.75, 0, 0) * CFrame.new(0, 0, -tip / 2),
				Color = color,
				CanCollide = false,
			})
		end
	end
end

-- Low teal post with a sunny ball cap (boardwalk corners and spur mouths).
local function bollard(x: number, z: number)
	local _, add = newProp("Bollard", ground(x, z))
	add({ Name = "BollardPost", Shape = CYLINDER, Size = Vector3.new(2, 1.1, 1.1), CFrame = CFrame.new(0, 1, 0) * UPRIGHT, Color = W.Teal })
	add({ Name = "BollardCap", Shape = BALL, Size = cube(1.5), CFrame = CFrame.new(0, 2.2, 0), Color = W.Sunny })
end

local function bench(base: CFrame)
	local _, add = newProp("HubBench", base)
	add({ Name = "BenchSeat", Size = Vector3.new(5.2, 0.5, 1.8), CFrame = CFrame.new(0, 1.75, 0), Color = W.Wood })
	add({
		Name = "BenchBack",
		Size = Vector3.new(5.2, 1.4, 0.4),
		CFrame = CFrame.new(0, 2.9, 0.85) * CFrame.Angles(0.2, 0, 0),
		Color = W.Wood,
	})
	for _, sx in { -1, 1 } do
		add({ Name = "BenchLeg", Size = Vector3.new(0.6, 1.6, 1.8), CFrame = CFrame.new(sx * 2, 0.8, 0), Color = W.White })
	end
end

local function planter(base: CFrame)
	local _, add = newProp("Planter", base)
	add({ Name = "PlanterBox", Size = Vector3.new(4.6, 1.4, 2.6), CFrame = CFrame.new(0, 0.7, 0), Color = W.Teal })
	for _, sz in { -1, 1 } do
		add({ Name = "PlanterRim", Size = Vector3.new(5, 0.35, 0.4), CFrame = CFrame.new(0, 1.5, sz * 1.3), Color = W.White })
	end
	for _, sx in { -1, 1 } do
		add({ Name = "PlanterRim", Size = Vector3.new(0.4, 0.35, 2.9), CFrame = CFrame.new(sx * 2.3, 1.5, 0), Color = W.White })
	end
	for i, x in { -1.3, 0, 1.3 } do
		add({
			Name = "Bush",
			Shape = BALL,
			Size = cube(if i == 2 then 1.9 else 1.6),
			CFrame = CFrame.new(x, 1.9, 0),
			Color = W.GrassDark,
			CanCollide = false,
		})
	end
	local flowers =
		{ { -1.6, 0.4, W.Pink }, { -0.7, -0.5, W.Sunny }, { 0.3, 0.45, W.Coral }, { 1.1, -0.4, W.Grape }, { 1.7, 0.35, W.Pink } }
	for _, f in flowers do
		add({
			Name = "Flower",
			Shape = BALL,
			Size = cube(0.85),
			CFrame = CFrame.new(f[1], 2.6, f[2]),
			Color = f[3],
			CanCollide = false,
		})
	end
end

-- White ball with three crossing colour bands.
local function beachBall(x: number, z: number, spin: number)
	local model, add = newProp("BeachBall", ground(x, z, spin))
	model:SetAttribute("MeshScale", 1)
	local d = 2.6
	local center = CFrame.new(0, d / 2, 0) * CFrame.Angles(0.3, 0, 0.2)
	add({ Name = "BeachBall", Shape = BALL, Size = cube(d), CFrame = center, Color = W.White })
	local bands = { { CFrame.new(), W.Coral }, { ALONG_Z, W.Sunny }, { UPRIGHT, W.Blue } }
	for _, b in bands do
		add({
			Name = "BeachBallBand",
			Shape = CYLINDER,
			Size = Vector3.new(0.7, d + 0.05, d + 0.05),
			CFrame = center * b[1],
			Color = b[2],
			CanCollide = false,
		})
	end
end

local function cloud(x: number, y: number, z: number, scale: number)
	local model, add = newProp("Cloud", CFrame.new(x, y, z), "Cloud")
	local puffs =
		{ { 0, 0, 0, 1 }, { -0.75, -0.15, 0.1, 0.72 }, { 0.8, -0.2, -0.1, 0.68 }, { 0.3, 0.35, 0.15, 0.62 }, { -0.35, 0.28, -0.2, 0.55 } }
	for _, p in puffs do
		local d = 40 * scale * p[4]
		add({
			Name = "CloudPuff",
			Shape = BALL,
			Size = cube(d),
			CFrame = CFrame.new(p[1] * 40 * scale, p[2] * 40 * scale, p[3] * 40 * scale),
			Color = W.White,
			CanCollide = false,
			CanQuery = false,
			CanTouch = false,
			CastShadow = false,
		})
	end
	model:SetAttribute("Height", y)
end

-- Beach umbrella: a white pole under a round canopy in two rings (`color` outside, white
-- inside), so it reads as a striped parasol from above.
local function umbrella(x: number, z: number, color: Color3)
	local model = Instance.new("Model")
	model.Name = "BeachUmbrella"
	model.Parent = mapFolder
	local poleTop = 7.2
	part({
		Name = "UmbrellaPole",
		Shape = CYLINDER,
		Size = Vector3.new(poleTop - SAND_TOP, 0.45, 0.45),
		CFrame = CFrame.new(x, (SAND_TOP + poleTop) / 2, z) * UPRIGHT,
		Color = W.White,
		Parent = model,
	})
	part({
		Name = "UmbrellaCanopy",
		Shape = CYLINDER,
		Size = Vector3.new(0.7, 9, 9),
		CFrame = CFrame.new(x, poleTop, z) * UPRIGHT,
		Color = color,
		CanCollide = false,
		Parent = model,
	})
	part({
		Name = "UmbrellaCanopy",
		Shape = CYLINDER,
		Size = Vector3.new(0.7, 4.6, 4.6),
		CFrame = CFrame.new(x, poleTop + 0.35, z) * UPRIGHT,
		Color = W.White,
		CanCollide = false,
		Parent = model,
	})
end

-- Beach towel lying on the sand: a colour strip, with a white band across it when `banded`.
local function towel(x: number, z: number, yaw: number, color: Color3, banded: boolean)
	local base = CFrame.new(x, SAND_TOP, z) * CFrame.Angles(0, yaw, 0)
	part({
		Name = "BeachTowel",
		Size = Vector3.new(3.2, 0.16, 6),
		CFrame = base * CFrame.new(0, 0.08, 0),
		Color = color,
		CanCollide = false,
		CanQuery = false,
		CastShadow = false,
	})
	if not banded then
		return
	end
	part({
		Name = "BeachTowelBand",
		Size = Vector3.new(3.2, 0.24, 0.9),
		CFrame = base * CFrame.new(0, 0.12, -1.6),
		Color = W.White,
		CanCollide = false,
		CanQuery = false,
		CastShadow = false,
	})
end

-- Two smooth beach rocks (blue-grey and sandstone) half sunk in the sand.
local function rocks(x: number, z: number, spin: number)
	local base = CFrame.new(x, SAND_TOP, z) * CFrame.Angles(0, spin, 0)
	part({ Name = "BeachRock", Shape = BALL, Size = cube(3.6), CFrame = base * CFrame.new(0, 0.9, 0), Color = W.Steel })
	part({ Name = "BeachRock", Shape = BALL, Size = cube(2.2), CFrame = base * CFrame.new(2.4, 0.5, 1), Color = W.PathEdge })
end

-- A sparse ring of beach spots (parasol and towels, rocks, a palm) in the open sand between
-- the plot rows and the shore, so the island does not read as empty from above. Each spot is
-- skipped where it would land on the GAME MODES course.
local function buildBeachSpots()
	local spots = {
		-- { x, z, canopy colour, towel colour, rocks, palm height (0 = none) }
		{ -22, 180, W.Coral, W.Sunny, true, 0 },
		{ 64, 170, W.Sunny, W.Blue, false, 17 },
		{ 18, -182, W.Blue, W.Coral, true, 0 },
		{ -70, -168, W.Pink, W.Mint, false, 16 },
		{ 182, -20, W.Coral, W.Pink, true, 0 },
		{ 170, 70, W.Mint, W.Sunny, false, 0 },
		{ -162, -82, W.Sunny, W.Coral, true, 0 },
	}
	for i, spot in spots do
		local x, z = spot[1], spot[2]
		if not ModesCourse.isClear(x, z) or not ModesCourse.isClear(x + 8, z + 8) or not ModesCourse.isClear(x - 8, z - 8) then
			continue
		end
		-- Face the spot toward the plaza; towels lie in front of the parasol.
		local yaw = yawToward(x, z, 0, 0)
		local frame = CFrame.new(x, 0, z) * CFrame.Angles(0, yaw, 0)
		umbrella(x, z, spot[3])
		for k, side in { -1, 1 } do
			local p = frame * CFrame.new(side * 2.2, 0, -4.5)
			towel(p.X, p.Z, yaw + side * 0.12, if k == 1 then spot[4] else spot[3], k == 1)
		end
		if spot[5] then
			local r = frame * CFrame.new(7, 0, 3)
			rocks(r.X, r.Z, i)
		end
		local height = spot[6] :: number
		if height > 0 then
			local p = frame * CFrame.new(-7, 0, 4)
			palmTree(ground(p.X, p.Z, i * 1.9), height, 0.3 + (i % 3) * 0.08, false)
		end
	end
end

-- Distant island: a sand disc in shallow water with a terraced grassy hill and big palms.
local function farIsland(angle: number, distance: number, radius: number)
	local x, z = math.cos(angle) * distance, math.sin(angle) * distance
	disc("FarShallows", radius + 16, OCEAN_TOP + 0.15, 0.2, W.Shallows, x, z)
	disc("FarIsland", radius, 1.4, 5, W.Sand, x, z)
	disc("FarHill", radius * 0.6, 3.4, 3, W.Grass, x, z)
	disc("FarHillTop", radius * 0.3, 5.4, 3, W.GrassDark, x, z)
	local spots = { { 0.82, 0.4, 1.4 }, { 0.78, 2.5, 1.4 }, { 0.45, 4.3, 3.4 }, { 0.15, 1.2, 5.4 } }
	for i, spot in spots do
		local r = radius * spot[1]
		local a = angle + spot[2]
		palmTree(
			CFrame.new(x + math.cos(a) * r, spot[3], z + math.sin(a) * r) * CFrame.Angles(0, a + i, 0),
			24 + (i % 3) * 4,
			0.25 + 0.08 * i,
			false
		)
	end
end

-- Centre piece ---------------------------------------------------------------------------

-- Three-tier trophy podium; returns the height of its top tier. The mesh version (World.Props)
-- keeps its authored size, 6.9 studs tall, and the plaque card sits on its coral middle tier.
local function trophyPodium(base: CFrame): number
	local model, add = newProp("TrophyPodium", base)
	local meshSize = if Props.has("TrophyPodium") then Props.size("TrophyPodium") else nil
	local function tier(name: string, diameter: number, bottom: number, height: number, color: Color3)
		add({
			Name = name,
			Shape = CYLINDER,
			Size = Vector3.new(height, diameter, diameter),
			CFrame = CFrame.new(0, bottom + height / 2, 0) * UPRIGHT,
			Color = color,
		})
	end
	tier("PodiumLip", 18.8, 0, 0.45, W.White)
	tier("PodiumTier1", 18, 0, 1.2, W.Cream)
	tier("PodiumTier2", 13.4, 1.2, 1.2, W.Coral)
	tier("PodiumTier3", 9, 2.4, 1.2, W.White)
	tier("PodiumBand", 9.4, 2.85, 0.35, W.Sunny)
	local plaque = if meshSize
		then add({ Name = "PodiumPlaque", Size = Vector3.new(4.6, 1.2, 0.9), CFrame = CFrame.new(0, 3.45, -6.5), Color = W.White })
		else add({ Name = "PodiumPlaque", Size = Vector3.new(4.6, 0.9, 0.3), CFrame = CFrame.new(0, 1.8, -6.75), Color = W.White })
	local root = surface(plaque, Enum.NormalId.Front, 40)
	text(root, { Text = "GIGA CHAD", Size = UDim2.fromScale(0.9, 0.8), Position = UDim2.fromScale(0.05, 0.1) })
	if meshSize then
		model:SetAttribute("MeshScale", 1)
		plaque:SetAttribute("MeshKeep", true)
		return meshSize.Y
	end
	return 3.6
end

-- Chunky golden Chad hitting a double-biceps pose, facing -Z.
local function gigaStatue(base: CFrame)
	local model, add = newProp("GigaStatue", base)
	model:SetAttribute("MeshScale", 1)
	local gold = W.Sunny
	local deep = W.Sunny:Lerp(W.Orange, 0.5)
	local function g(props: { [string]: any }, className: string?): BasePart
		props.Color = props.Color or gold
		props.Reflectance = 0.12
		return add(props, className)
	end
	local function ball(name: string, d: number, x: number, y: number, z: number, color: Color3?)
		g({ Name = name, Shape = BALL, Size = cube(d), CFrame = CFrame.new(x, y, z), Color = color })
	end
	local function column(name: string, length: number, d: number, x: number, y: number, z: number)
		g({ Name = name, Shape = CYLINDER, Size = Vector3.new(length, d, d), CFrame = CFrame.new(x, y, z) * UPRIGHT })
	end

	for _, sx in { -1, 1 } do
		g({ Name = "StatueFoot", Size = Vector3.new(2.4, 1, 3.4), CFrame = CFrame.new(sx * 1.6, 0.5, -0.3), Color = deep })
		g({ Name = "StatueLeg", Size = Vector3.new(2.2, 5.4, 2.4), CFrame = CFrame.new(sx * 1.6, 3.6, 0) })
		ball("StatueCalf", 2.5, sx * 1.6, 2.8, 0.35)
		-- Arms: shoulder, upper arm out to the side, biceps peak, forearm up, fist.
		ball("StatueShoulder", 3.4, sx * 4.5, 13.4, 0)
		g({
			Name = "StatueUpperArm",
			Shape = CYLINDER,
			Size = Vector3.new(3.6, 2.4, 2.4),
			CFrame = CFrame.new(sx * 6.8, 13.6, 0),
		})
		ball("StatueBiceps", 3, sx * 6.6, 14.6, 0)
		ball("StatueElbow", 2.4, sx * 8.6, 13.6, 0)
		column("StatueForearm", 4, 2.2, sx * 8.6, 15.6, 0)
		ball("StatueFist", 2.8, sx * 8.6, 18, 0)
		g({ Name = "StatuePec", Size = Vector3.new(3.7, 2, 0.7), CFrame = CFrame.new(sx * 1.95, 12.4, -1.85) })
		g({ Name = "StatueEar", Size = Vector3.new(0.5, 1, 0.8), CFrame = CFrame.new(sx * 1.95, 16.8, 0) })
		for row = 0, 1 do
			g({ Name = "StatueAbs", Size = Vector3.new(1.4, 0.8, 0.4), CFrame = CFrame.new(sx * 0.8, 8.9 + row * 0.95, -1.6) })
		end
	end
	g({ Name = "StatueShorts", Size = Vector3.new(5.8, 2.6, 3.2), CFrame = CFrame.new(0, 7.2, 0), Color = deep })
	g({ Name = "StatueWaist", Size = Vector3.new(5.2, 1.7, 3), CFrame = CFrame.new(0, 9.25, 0) })
	g({ Name = "StatueChest", Size = Vector3.new(8.4, 3.8, 3.6), CFrame = CFrame.new(0, 11.8, 0) })
	column("StatueNeck", 1.6, 2.6, 0, 14.3, 0)
	g({ Name = "StatueHead", Size = Vector3.new(3.6, 3.6, 3.4), CFrame = CFrame.new(0, 16.7, 0) })
	g({ Name = "StatueJaw", Size = Vector3.new(4, 1.5, 3.6), CFrame = CFrame.new(0, 15.4, -0.1) })
	g({ Name = "StatueHair", Size = Vector3.new(3.8, 1.2, 3.6), CFrame = CFrame.new(0, 18.9, 0.1), Color = deep })
	g({ Name = "StatueQuiff", Size = Vector3.new(3.8, 1, 1.8), CFrame = CFrame.new(0, 19.9, -0.8), Color = deep }, "WedgePart")
	g({ Name = "StatueSmile", Size = Vector3.new(1.6, 0.3, 0.2), CFrame = CFrame.new(0, 15.55, -1.95), Color = deep })
	add({ Name = "StatueShades", Size = Vector3.new(3.8, 0.8, 0.4), CFrame = CFrame.new(0, 17.2, -1.75), Color = W.Ink })
end

-- A thin teal border round a sign card frame.
local function border(frame: Frame, thickness: number)
	local b = Instance.new("UIStroke")
	b.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	b.Color = W.Teal
	b.Thickness = thickness
	b.Parent = frame
end

-- Freestanding ranking card on two teal posts, front facing -Z. The front is a deep teal board
-- under a sunny header pill with the list (returned for Server.Ranking to fill); the back is
-- a cream welcome card with a red-orange header band and the game name.
local function scoreboard(base: CFrame): TextLabel
	local _, add = newProp("Scoreboard", base)
	local w, h, bottom = 16, 17, 3.4
	local top = bottom + h
	local slab = add({ Name = "ScoreCard", Size = Vector3.new(w, h, 1), CFrame = CFrame.new(0, bottom + h / 2, 0), Color = W.Board })
	for _, sx in { -1, 1 } do
		local x = sx * (w / 2 + 0.6)
		add({
			Name = "ScoreFoot",
			Shape = CYLINDER,
			Size = Vector3.new(0.6, 2.6, 2.6),
			CFrame = CFrame.new(x, 0.3, 0) * UPRIGHT,
			Color = W.Cream,
		})
		add({
			Name = "ScorePost",
			Shape = CYLINDER,
			Size = Vector3.new(top + 0.4, 1.4, 1.4),
			CFrame = CFrame.new(x, (top + 0.4) / 2, 0) * UPRIGHT,
			Color = W.Teal,
		})
		add({ Name = "ScorePostCap", Shape = BALL, Size = cube(2.1), CFrame = CFrame.new(x, top + 0.8, 0), Color = W.Sunny })
	end

	local front = surface(slab, Enum.NormalId.Front, 30)
	local card = panel(front, W.Board, UDim2.fromScale(0.035, 0.03), UDim2.fromScale(0.93, 0.94), 0.06)
	border(card, 6)
	local pill = panel(card, W.Sunny, UDim2.fromScale(0.08, 0.035), UDim2.fromScale(0.84, 0.12), 0.5)
	text(pill, {
		Text = "TOP " .. string.upper(theme.Words.Units),
		Size = UDim2.fromScale(0.9, 0.76),
		Position = UDim2.fromScale(0.05, 0.12),
	})
	local list = text(card, {
		Text = "Loading...",
		Font = theme.Fonts.UI,
		TextScaled = false,
		TextSize = 24,
		TextColor3 = W.White,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
		RichText = true,
		Size = UDim2.fromScale(0.86, 0.77),
		Position = UDim2.fromScale(0.07, 0.19),
	})

	local back = surface(slab, Enum.NormalId.Back, 30)
	local backCard = panel(back, W.Cream, UDim2.fromScale(0.035, 0.03), UDim2.fromScale(0.93, 0.94), 0.06)
	border(backCard, 6)
	local welcome = panel(backCard, W.RedOrange, UDim2.fromScale(0.2, 0.08), UDim2.fromScale(0.6, 0.11), 0.5)
	text(welcome, { Text = "WELCOME!", TextColor3 = W.White, Size = UDim2.fromScale(0.9, 0.76), Position = UDim2.fromScale(0.05, 0.12) })
	text(backCard, { Text = theme.GameName, Size = UDim2.fromScale(0.86, 0.42), Position = UDim2.fromScale(0.07, 0.24) })
	text(backCard, {
		Text = theme.Tagline,
		Font = theme.Fonts.UI,
		Size = UDim2.fromScale(0.8, 0.2),
		Position = UDim2.fromScale(0.1, 0.7),
	})
	return list
end

-- Welcome arch over a plaza connector, front facing the plaza (-Z): teal pillars with sunny
-- caps holding a cream sign card on both faces (game name, red-orange band).
local function welcomeArch(base: CFrame, plotsText: string)
	local _, add = newProp("WelcomeArch", base)
	for _, sx in { -1, 1 } do
		local x = sx * 7.6
		add({
			Name = "ArchFoot",
			Shape = CYLINDER,
			Size = Vector3.new(1, 3.2, 3.2),
			CFrame = CFrame.new(x, 0.5, 0) * UPRIGHT,
			Color = W.Teal,
		})
		add({
			Name = "ArchPillar",
			Shape = CYLINDER,
			Size = Vector3.new(10.6, 2.2, 2.2),
			CFrame = CFrame.new(x, 5.3, 0) * UPRIGHT,
			Color = W.Teal,
		})
		add({ Name = "ArchCap", Shape = BALL, Size = cube(3), CFrame = CFrame.new(x, 12.2, 0), Color = W.Sunny })
	end
	local sign = add({ Name = "ArchSign", Size = Vector3.new(14, 3.8, 1), CFrame = CFrame.new(0, 10.2, 0), Color = W.Board })
	for _, f in { { Enum.NormalId.Front, plotsText }, { Enum.NormalId.Back, "WELCOME!" } } do
		local root = surface(sign, f[1], 30)
		local card = panel(root, W.Cream, UDim2.fromScale(0.015, 0.06), UDim2.fromScale(0.97, 0.88), 0.2)
		border(card, 6)
		text(card, { Text = theme.GameName, Size = UDim2.fromScale(0.9, 0.5), Position = UDim2.fromScale(0.05, 0.06) })
		local band = panel(card, W.RedOrange, UDim2.fromScale(0.25, 0.62), UDim2.fromScale(0.5, 0.3), 0.5)
		text(band, { Text = f[2], TextColor3 = W.White, Size = UDim2.fromScale(0.9, 0.8), Position = UDim2.fromScale(0.05, 0.1) })
	end
end

-- Juice bar hut with a striped awning, front (counter) facing -Z.
local function juiceBar(base: CFrame)
	local _, add = newProp("JuiceBar", base)
	add({
		Name = "JuiceDeck",
		Size = Vector3.new(11, 0.5, 8.6),
		CFrame = CFrame.new(0, 0.25, 0.4),
		Color = W.Wood,
		Material = Enum.Material.WoodPlanks,
	})
	add({ Name = "JuiceCounter", Size = Vector3.new(9.6, 3.2, 1.6), CFrame = CFrame.new(0, 2.1, -2.4), Color = W.Pink })
	add({ Name = "JuiceKick", Size = Vector3.new(9.8, 0.6, 1.7), CFrame = CFrame.new(0, 0.8, -2.4), Color = W.White })
	add({ Name = "JuiceCounterTop", Size = Vector3.new(10.2, 0.45, 2.2), CFrame = CFrame.new(0, 3.9, -2.4), Color = W.Cream })
	add({ Name = "JuiceBack", Size = Vector3.new(10, 5, 0.6), CFrame = CFrame.new(0, 3, 4.2), Color = W.Mint })
	add({ Name = "JuiceShelf", Size = Vector3.new(8.6, 0.4, 1.2), CFrame = CFrame.new(0, 3.6, 3.4), Color = W.White })
	local fruit = { W.Orange, W.Sunny, W.Coral, W.Grass, W.Orange, W.Pink }
	for i, color in fruit do
		add({
			Name = "JuiceFruit",
			Shape = BALL,
			Size = cube(1.1),
			CFrame = CFrame.new(-3.6 + (i - 1) * 1.45, 4.35, 3.4),
			Color = color,
			CanCollide = false,
		})
	end
	-- Posts: the roof slopes down toward the counter.
	local frontY, backY = 7.4, 9.2
	for _, sx in { -1, 1 } do
		for _, p in { { -3.4, frontY }, { 4.2, backY } } do
			local length = p[2] - 0.5
			add({
				Name = "JuicePost",
				Shape = CYLINDER,
				Size = Vector3.new(length, 0.9, 0.9),
				CFrame = CFrame.new(sx * 4.9, 0.5 + length / 2, p[1]) * UPRIGHT,
				Color = W.Wood,
			})
		end
	end
	-- Striped awning (coral and white), with a row of round scallops along the front edge.
	local stripes = 6
	local stripeW = 11.4 / stripes
	local depth = 9.6
	local rise = backY - frontY
	local slope = math.atan2(rise, depth)
	for i = 1, stripes do
		local x = -5.7 + (i - 0.5) * stripeW
		local color = if i % 2 == 1 then W.Coral else W.White
		add({
			Name = "Awning",
			Size = Vector3.new(stripeW, 0.35, math.sqrt(depth * depth + rise * rise)),
			CFrame = CFrame.new(x, (frontY + backY) / 2 + 0.2, 0.2) * CFrame.Angles(-slope, 0, 0),
			Color = color,
		})
		add({
			Name = "AwningScallop",
			Shape = BALL,
			Size = cube(stripeW),
			CFrame = CFrame.new(x, frontY + 0.1, -4.6),
			Color = color,
			CanCollide = false,
		})
	end
	local sign = add({ Name = "JuiceSign", Size = Vector3.new(6.4, 1.8, 0.5), CFrame = CFrame.new(0, frontY + 1.6, -3.2), Color = W.Sunny })
	local root = surface(sign, Enum.NormalId.Front, 30)
	local card = panel(root, W.Cream, UDim2.fromScale(0.03, 0.08), UDim2.fromScale(0.94, 0.84), 0.35)
	text(card, { Text = "JUICE BAR", Size = UDim2.fromScale(0.9, 0.8), Position = UDim2.fromScale(0.05, 0.1) })
	-- Smoothie cups with straws on the counter, and stools in front.
	for i, color in { W.Mint, W.Sunny, W.Orange } do
		local x = -3 + (i - 1) * 2.2
		add({
			Name = "JuiceCup",
			Shape = CYLINDER,
			Size = Vector3.new(1.3, 0.95, 0.95),
			CFrame = CFrame.new(x, 4.77, -2.5) * UPRIGHT,
			Color = color,
			CanCollide = false,
		})
		add({
			Name = "JuiceStraw",
			Shape = CYLINDER,
			Size = Vector3.new(1.1, 0.25, 0.25),
			CFrame = CFrame.new(x + 0.15, 5.6, -2.5) * CFrame.Angles(0, 0, 0.25) * UPRIGHT,
			Color = W.White,
			CanCollide = false,
		})
	end
	for _, x in { -3, 0, 3 } do
		add({
			Name = "StoolPole",
			Shape = CYLINDER,
			Size = Vector3.new(2.2, 0.5, 0.5),
			CFrame = CFrame.new(x, 1.1, -4.6) * UPRIGHT,
			Color = W.White,
		})
		add({
			Name = "StoolSeat",
			Shape = CYLINDER,
			Size = Vector3.new(0.45, 1.8, 1.8),
			CFrame = CFrame.new(x, 2.4, -4.6) * UPRIGHT,
			Color = W.Coral,
		})
	end
end

-- World ---------------------------------------------------------------------------------

-- Sand island, beach, shallows and an ocean that reaches the horizon. The island and shore are
-- flat SmoothPlastic: the Sand material's large-scale texture variation reads as dark smudges
-- across a disc this big when seen from above.
local function buildSurroundings()
	disc("Island", ISLAND_RADIUS, SAND_TOP, 6, W.Sand, 0, 0)
	disc("Shore", ISLAND_RADIUS + 8, -0.55, 6, W.SandDark, 0, 0)
	disc("Foam", ISLAND_RADIUS + 11, -0.9, 0.3, W.White)
	disc("Shallows", ISLAND_RADIUS + 34, OCEAN_TOP + 0.2, 0.2, W.Shallows)
	for ix = -1, 1 do
		for iz = -1, 1 do
			part({
				Name = "Ocean",
				Size = Vector3.new(OCEAN_TILE, 2, OCEAN_TILE),
				CFrame = CFrame.new(ix * OCEAN_TILE, OCEAN_TOP - 1, iz * OCEAN_TILE),
				Color = W.Ocean,
				Reflectance = 0.05,
				CastShadow = false,
			})
		end
	end

	-- Palm islands out at sea, all around the horizon.
	local islands = {
		{ 20, 620, 55 },
		{ 78, 860, 42 },
		{ 140, 560, 36 },
		{ 200, 760, 60 },
		{ 255, 600, 44 },
		{ 318, 900, 50 },
	}
	for _, isle in islands do
		farIsland(math.rad(isle[1]), isle[2], isle[3])
	end

	-- A ring of palms along the beach, outside every plot.
	local beachPalms = 12
	for i = 1, beachPalms do
		local a = (i - 0.5) * 2 * math.pi / beachPalms
		local r = ISLAND_RADIUS - 14 + (i % 3) * 3
		-- None on the GAME MODES plaza or the Parkour finish deck (World.Modes).
		if ModesCourse.isClear(math.cos(a) * r, math.sin(a) * r) then
			palmTree(ground(math.cos(a) * r, math.sin(a) * r, a * 1.7), 15 + (i % 4) * 1.5, 0.3 + (i % 3) * 0.1, false)
		end
	end

	-- Beach spots in the open sand between the plots and the shore.
	buildBeachSpots()

	-- Puffy clouds high above the sea.
	local clouds = {
		{ -420, 190, 260, 1.4 },
		{ 360, 220, 420, 1.1 },
		{ 520, 170, -180, 1.3 },
		{ -260, 240, -520, 1.6 },
		{ 120, 260, -760, 1.2 },
		{ -700, 210, -60, 1.5 },
		{ 760, 250, 300, 1.2 },
		{ -80, 230, 820, 1.4 },
	}
	for _, c in clouds do
		cloud(c[1], c[2], c[3], c[4])
	end
end

-- Boardwalk ring between the plaza and the plot rows.
local function buildBoardwalk()
	local function deck(cx: number, cz: number, sx: number, sz: number)
		part({
			Name = "Boardwalk",
			Size = Vector3.new(sx, 0.6, sz),
			CFrame = CFrame.new(cx, DECK_TOP - 0.3, cz),
			Color = W.Wood,
			Material = Enum.Material.WoodPlanks,
		})
	end
	local function edge(cx: number, cz: number, sx: number, sz: number)
		if sx > 0.05 and sz > 0.05 then
			part({
				Name = "BoardwalkEdge",
				Size = Vector3.new(sx, 0.7, sz),
				CFrame = CFrame.new(cx, DECK_TOP + 0.1 - 0.35, cz),
				Color = W.WoodDark,
			})
		end
	end
	-- An edge beam along z = `z` from x0 to x1, open where the given spans cross it.
	local function edgeAlongX(z: number, x0: number, x1: number, gaps: { { number } })
		local x = x0
		for _, gap in gaps do
			edge((x + gap[1]) / 2, z, gap[1] - x, 0.7)
			x = gap[2]
		end
		edge((x + x1) / 2, z, x1 - x, 0.7)
	end

	local spurLength = ENTRANCE_Z - (CROSS_Z + WALK_HALF)
	local connectorStart = HUB_RADIUS - 1
	local connectorLength = CROSS_Z - WALK_HALF - connectorStart
	local spurGaps = {}
	for col = -1, 1 do
		local cx = col * PLOT_SPACING_X
		table.insert(spurGaps, { cx - WALK_HALF, cx + WALK_HALF })
	end
	local edgeIn = WALK_HALF - 0.35
	for _, row in { 1, -1 } do
		local z = row * CROSS_Z
		deck(0, z, RING_OUT * 2, WALK_HALF * 2)
		edgeAlongX(z - row * edgeIn, -(RING_X - WALK_HALF), RING_X - WALK_HALF, { { -CONNECTOR_HALF, CONNECTOR_HALF } })
		edgeAlongX(z + row * edgeIn, -RING_OUT, RING_OUT, spurGaps)
		-- Spurs into the plot entrances.
		local spurZ = row * (CROSS_Z + WALK_HALF + spurLength / 2)
		for col = -1, 1 do
			local cx = col * PLOT_SPACING_X
			deck(cx, spurZ, WALK_HALF * 2, spurLength)
			for _, sx in { -1, 1 } do
				edge(cx + sx * edgeIn, spurZ, 0.7, spurLength)
				bollard(cx + sx * (WALK_HALF + 0.9), row * (CROSS_Z + WALK_HALF + 0.9))
			end
		end
		-- Wide connector from the plaza.
		local connectorZ = row * (connectorStart + connectorLength / 2)
		deck(0, connectorZ, CONNECTOR_HALF * 2, connectorLength)
		for _, sx in { -1, 1 } do
			edge(sx * (CONNECTOR_HALF - 0.35), connectorZ, 0.7, connectorLength)
		end
	end
	for _, side in { 1, -1 } do
		local x = side * RING_X
		local length = (CROSS_Z - WALK_HALF) * 2
		deck(x, 0, WALK_HALF * 2, length)
		edge(x - side * edgeIn, 0, 0.7, length)
		if side == -1 then
			-- Open where the GAME MODES spur leaves the ring (World.Modes builds the spur).
			local outer = CROSS_Z + WALK_HALF
			local spur = ModesCourse.SPUR.half
			for _, sz in { -1, 1 } do
				edge(x + side * edgeIn, sz * (spur + outer) / 2, 0.7, outer - spur)
			end
		else
			edge(x + side * edgeIn, 0, 0.7, (CROSS_Z + WALK_HALF) * 2)
		end
		for _, row in { 1, -1 } do
			bollard(x + side * (WALK_HALF + 0.9), row * (CROSS_Z + WALK_HALF + 0.9))
		end
	end
end

-- Hub -----------------------------------------------------------------------------------

local function buildHub(): { TextLabel }
	buildSurroundings()
	buildBoardwalk()

	-- Plaza: a thin light path-stone rim, warm honey-sand paving, a sunny ring and a light teal
	-- centre round the podium.
	disc("PlazaRim", HUB_RADIUS, PLAZA_RIM_TOP, 0.6, W.Path)
	disc("Plaza", HUB_RADIUS - 1, PLAZA_TOP, 0.6, W.Plaza)
	disc("PlazaRing", PLAZA_INNER_RADIUS + 1, PLAZA_RING_TOP, 0.6, W.Sunny)
	disc("PlazaInner", PLAZA_INNER_RADIUS, PLAZA_INNER_TOP, 0.6, W.TealLight)

	-- Spawn mat in front of the statue, facing it.
	part({
		Name = "HubSpawnRim",
		Size = Vector3.new(9.4, 0.3, 9.4),
		CFrame = CFrame.new(0, PLAZA_INNER_TOP + 0.08 - 0.15, -24),
		Color = W.White,
	})
	local spawn = Instance.new("SpawnLocation")
	spawn.Name = "HubSpawn"
	spawn.Anchored = true
	spawn.Neutral = true
	spawn.Size = Vector3.new(8, 0.4, 8)
	spawn.CFrame = CFrame.new(0, PLAZA_INNER_TOP + 0.14 - 0.2, -24) * CFrame.Angles(0, math.pi, 0)
	spawn.Color = W.Mat
	spawn.Material = Enum.Material.SmoothPlastic
	spawn.TopSurface = Enum.SurfaceType.Smooth
	spawn.BottomSurface = Enum.SurfaceType.Smooth
	spawn.Duration = 0
	spawn.Parent = mapFolder
	local decal = spawn:FindFirstChildOfClass("Decal")
	if decal then
		decal:Destroy()
	end

	-- Centre piece: the golden statue on its trophy podium, facing the spawn.
	local podiumTop = trophyPodium(CFrame.new(0, PLAZA_INNER_TOP, 0))
	gigaStatue(CFrame.new(0, PLAZA_INNER_TOP + podiumTop, 0))

	-- Ranking scoreboards either side of the statue: one faces each plot row.
	local rankingLabels: { TextLabel } = {
		scoreboard(CFrame.new(-SCOREBOARD_X, PLAZA_INNER_TOP, 0)),
		scoreboard(CFrame.new(SCOREBOARD_X, PLAZA_INNER_TOP, 0) * CFrame.Angles(0, math.pi, 0)),
	}

	-- Benches round the podium, facing the statue; planters near the rim.
	for i = 0, 3 do
		local a = (i + 0.5) * math.pi / 2
		local x, z = math.cos(a) * 14, math.sin(a) * 14
		bench(CFrame.new(x, PLAZA_INNER_TOP, z) * CFrame.Angles(0, yawToward(x, z, 0, 0), 0))
		local px, pz = math.cos(a) * 26.5, math.sin(a) * 26.5
		planter(CFrame.new(px, PLAZA_TOP, pz) * CFrame.Angles(0, yawToward(px, pz, 0, 0), 0))
	end

	-- Welcome arches over the plaza connectors.
	for _, row in { 1, -1 } do
		local first = if row == 1 then 1 else 4
		welcomeArch(
			ground(0, row * ARCH_Z, if row == 1 then 0 else math.pi),
			string.format("PLOTS %d · %d · %d", first, first + 1, first + 2)
		)
	end

	-- Sand between the plaza and the plot rows: palms, grass islands, the juice bar and toys.
	for _, sx in { -1, 1 } do
		for _, sz in { -1, 1 } do
			palmTree(ground(sx * 12.5, sz * (ARCH_Z + 1.5), sx * sz), 17, 0.35, true)
			palmTree(ground(sx * 28, sz * 30, sx * sz * 2), 19, 0.45, true)
		end
	end
	juiceBar(ground(46, -20, yawToward(46, -20, 0, -8)))

	local islands = {
		{ 66, 16, 11, { { 61, 12, 18 }, { 70, 21, 15 } }, { 72, 9 } },
		{ -66, -16, 11, { { -61, -12, 18 }, { -70, -21, 15 } }, { -72, -9 } },
		{ -62, 21, 8, { { -62, 21, 16 } }, nil },
		{ 90, -16, 8, { { 90, -16, 17 } }, nil },
		{ 90, 22, 7, {}, { 90, 22 } },
		{ -92, -2, 9, { { -94, 0, 18 } }, { -89, -6 } },
	}
	for i, isle in islands do
		local x, z, r = isle[1], isle[2], isle[3]
		disc("GrassRim", r + 0.8, 0.12, 0.6, W.GrassDark, x, z)
		disc("GrassIsland", r, 0.22, 0.6, W.Grass, x, z)
		for j, p in isle[4] do
			palmTree(CFrame.new(p[1], 0.22, p[2]) * CFrame.Angles(0, i + j * 2, 0), p[3], 0.3 + 0.1 * j, true)
		end
		local spot = isle[5]
		if spot then
			planter(CFrame.new(spot[1], 0.22, spot[2]) * CFrame.Angles(0, yawToward(spot[1], spot[2], x, z) + math.pi, 0))
		end
	end

	local balls = { { 54, 3 }, { -50, 8 }, { 80, -30 }, { -36, -33 }, { -158, 42 }, { 168, 28 }, { 24, 166 }, { -30, -170 } }
	for i, b in balls do
		beachBall(b[1], b[2], i * 1.3)
	end

	return rankingLabels
end

Hub.setupLighting = setupLighting
Hub.buildHub = buildHub

return Hub
