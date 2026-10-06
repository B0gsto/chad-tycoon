--[[
	Decor: the sunny gym dressing around a plot (one accent group per free area: a weights
	corner, a cardio corner, a water break, a boxing bag, palms and speakers at the entrance),
	the cream entrance path with its chevrons, and the two fan zones beside the display ledge.
	Part of the world generator; see Server.WorldBuilder for the overview and plot axes.

	Gym props are Models named Prop_<Kind> with attribute Mesh = "<Kind>" (and Scale) whose
	PrimaryPart ("PropRoot", invisible) sits at the prop's base centre with the prop's front
	along its -Z. World.Props swaps the chunky part-built body for the uploaded Blender mesh at the
	same size (attribute MeshScale) and keeps it as the fallback when the mesh is missing. Props
	stand only in the free areas PlotLayout leaves (corners and along the fences); every
	placement is checked against the layout and warns if it touches a pad, the pen, a machine,
	a crate area, a fan zone or the walkway.

	Fan zones: each plot folder gets a "FanSpots" folder with one invisible "FanSpot" part per
	Layout.fanSpots() entry (attribute Order, 1 = filled first) at ground level, its
	LookVector facing the display, and attribute Entrance (world Vector3) at the back of its
	zone column, where Fx.Fans runs that spot's fan in from. The zones are dressed with a small bleacher, a "FAN ZONE"
	card on two posts and heart / star cut-outs; the spots themselves stay clear.
]]

local Layout = require(script.Parent.Parent.PlotLayout)
local Common = require(script.Parent.Common)

type Builder = Common.Builder
type Rect = Layout.Rect

local theme = Common.theme
local UPRIGHT = Common.UPRIGHT
local ALONG_Z = Common.ALONG_Z
local WHITE = Common.WHITE

local Decor = {}

local function color(key: string): Color3
	local palette = theme.World
	return if palette and palette[key] then palette[key] else WHITE
end

-- Parts are added to a kit: a parent (a prop Model or a dressing folder), a plot-local base
-- frame, a uniform scale and whether its parts block the player.
type Kit = {
	B: Builder,
	parent: Instance,
	base: CFrame,
	scale: number,
	solid: boolean,
}

local function add(k: Kit, className: string, props: { [string]: any }, at: CFrame): BasePart
	local s = k.scale
	if s ~= 1 then
		at = CFrame.new(at.Position * s) * (CFrame.new(-at.Position) * at)
		props.Size = props.Size * s
	end
	props.CFrame = k.base * at
	props.Parent = k.parent
	if props.CanCollide == nil then
		props.CanCollide = k.solid
	end
	return if className == "WedgePart" then k.B.W(props) else k.B.P(props)
end

local function block(k: Kit, name: string, size: Vector3, at: CFrame, tint: Color3, material: Enum.Material?): BasePart
	return add(k, "Part", { Name = name, Size = size, Color = tint, Material = material }, at)
end

local function ball(k: Kit, name: string, d: number, at: CFrame, tint: Color3, material: Enum.Material?): BasePart
	return add(k, "Part", {
		Name = name,
		Shape = Enum.PartType.Ball,
		Size = Vector3.new(d, d, d),
		Color = tint,
		Material = material,
	}, at)
end

-- A cylinder `length` long along the X axis of `at` (use UPRIGHT / ALONG_Z to turn it).
local function cyl(k: Kit, name: string, length: number, d: number, at: CFrame, tint: Color3, material: Enum.Material?): BasePart
	return add(k, "Part", {
		Name = name,
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(length, d, d),
		Color = tint,
		Material = material,
	}, at)
end

local function wedge(k: Kit, name: string, size: Vector3, at: CFrame, tint: Color3): BasePart
	return add(k, "WedgePart", { Name = name, Size = size, Color = tint }, at)
end

-- Frame for a cylinder running from a to b (its X axis along a -> b).
local function between(a: Vector3, b: Vector3): CFrame
	local x = (b - a).Unit
	local up = if math.abs(x.Z) < 0.9 then Vector3.new(0, 0, 1) else Vector3.new(1, 0, 0)
	local y = up:Cross(x).Unit
	return CFrame.fromMatrix((a + b) / 2, x, y, x:Cross(y))
end

local function at(x: number, y: number, z: number): CFrame
	return CFrame.new(x, y, z)
end

-- Layout checks -----------------------------------------------------------------------

type Area = { name: string, rect: Rect }

local blockedCache: { Area }? = nil
local function blockedAreas(): { Area }
	if blockedCache then
		return blockedCache
	end
	local list: { Area } = {
		{ name = "walkway", rect = Layout.WALKWAY },
		{ name = "pen", rect = Layout.POOL },
		{ name = "gutter", rect = Layout.GUTTER.rect },
		{ name = "chute", rect = Layout.CHUTE.rect },
	}
	for name, spot in Layout.PADS do
		table.insert(list, { name = "pad " .. name, rect = Layout.padRect(spot, Layout.PAD_RIM) })
	end
	for _, stair in Layout.PEN_STAIRS do
		table.insert(list, { name = "pen stairs", rect = stair.rect })
	end
	for name, r in Layout.MACHINES do
		table.insert(list, { name = "machine " .. name, rect = r })
	end
	for _, r in Layout.CHEST_AREAS do
		table.insert(list, { name = "crate area", rect = r })
	end
	for i, zone in Layout.FAN_ZONES do
		table.insert(list, { name = "fan zone " .. i, rect = zone.rect })
	end
	blockedCache = list
	return list
end

-- Warns when a plot-local footprint is outside the fences or touches a reserved area.
local function checkClear(label: string, r: Rect, allowFanZones: boolean?)
	local inner = Layout.INNER_HALF
	if r.minX < -inner or r.maxX > inner or r.minZ < -inner or r.maxZ > inner then
		warn(string.format("[Decor] %s at (%.1f, %.1f) pokes past the fences", label, (r.minX + r.maxX) / 2, (r.minZ + r.maxZ) / 2))
	end
	for _, area in blockedAreas() do
		if not (allowFanZones and string.sub(area.name, 1, 8) == "fan zone") and Layout.overlaps(r, area.rect) then
			warn(
				string.format("[Decor] %s at (%.1f, %.1f) overlaps the %s", label, (r.minX + r.maxX) / 2, (r.minZ + r.maxZ) / 2, area.name)
			)
		end
	end
end

-- Props ---------------------------------------------------------------------------------

-- Entrance props keep at least this far off the plot's centre line (x = 0).
local ENTRANCE_CLEAR = 15

-- Half extents (prop-local X, Z) of each prop's floor footprint, at scale 1.
local FOOTPRINT: { [string]: Vector2 } = {
	DumbbellRack = Vector2.new(3.6, 1.3),
	Barbell = Vector2.new(3.5, 1.1),
	Bench = Vector2.new(1.9, 2.9),
	Treadmill = Vector2.new(1.4, 2.7),
	PunchBag = Vector2.new(2.1, 1.2),
	WaterCooler = Vector2.new(0.8, 1.2),
	PalmPlanter = Vector2.new(1.6, 1.6),
	Speaker = Vector2.new(1.0, 0.9),
}

local function dumbbellParts(k: Kit, frame: CFrame, tint: Color3, d: number)
	local length = d * 1.5
	cyl(k, "DumbbellBar", length, d * 0.32, frame, color("Chrome"))
	for _, side in { -1, 1 } do
		cyl(k, "DumbbellHead", d * 0.45, d, frame * CFrame.new(side * length * 0.36, 0, 0), tint)
	end
end

local PROP_BUILDERS: { [string]: (k: Kit, tint: Color3) -> () } = {}

-- Two-tier rack holding six candy dumbbells, front along -Z.
PROP_BUILDERS.DumbbellRack = function(k, tint)
	for _, side in { -1, 1 } do
		block(k, "RackEnd", Vector3.new(0.6, 2.4, 2.4), at(side * 3.2, 1.2, 0), tint)
	end
	block(k, "RackTray", Vector3.new(6, 0.35, 1.15), at(0, 0.9, -0.55), color("White"))
	block(k, "RackTray", Vector3.new(6, 0.35, 1.15), at(0, 1.85, 0.55), color("White"))
	local lower = { color("Pink"), color("Sunny"), color("Mint") }
	local upper = { color("Blue"), color("Grape"), color("Coral") }
	for i, x in { -1.9, 0, 1.9 } do
		dumbbellParts(k, at(x, 1.075 + 0.4, -0.55) * ALONG_Z, lower[i], 0.8)
		dumbbellParts(k, at(x, 2.025 + 0.4, 0.55) * ALONG_Z, upper[i], 0.8)
	end
end

-- Barbell along X; its base centre is under the plates.
PROP_BUILDERS.Barbell = function(k, tint)
	cyl(k, "BarbellBar", 7, 0.3, at(0, 1.1, 0), color("Chrome"))
	for _, side in { -1, 1 } do
		cyl(k, "Plate", 0.45, 2.2, at(side * 2.75, 1.1, 0), tint)
		cyl(k, "Plate", 0.35, 1.6, at(side * 2.35, 1.1, 0), tint:Lerp(WHITE, 0.35))
		cyl(k, "Collar", 0.3, 0.55, at(side * 3.15, 1.1, 0), color("Chrome"))
	end
end

-- Flat bench with a padded top and a barbell rack at its +Z end.
PROP_BUILDERS.Bench = function(k, tint)
	block(k, "BenchPad", Vector3.new(1.6, 0.55, 4.4), at(0, 1.55, -0.3), tint, Enum.Material.Fabric)
	block(k, "BenchLeg", Vector3.new(1.4, 1.3, 0.5), at(0, 0.65, -2), color("White"))
	block(k, "BenchLeg", Vector3.new(1.4, 1.3, 0.5), at(0, 0.65, 1.4), color("White"))
	block(k, "RackBase", Vector3.new(3.8, 0.35, 0.8), at(0, 0.175, 2.4), color("White"))
	for _, side in { -1, 1 } do
		block(k, "RackPost", Vector3.new(0.45, 4, 0.45), at(side * 1.6, 2, 2.4), color("Blue"))
		block(k, "RackHook", Vector3.new(0.45, 0.3, 0.7), at(side * 1.6, 3.4, 2.05), color("Sunny"))
	end
end

-- Treadmill with its console at the -Z end (the runner faces -Z).
PROP_BUILDERS.Treadmill = function(k, tint)
	block(k, "TreadmillDeck", Vector3.new(2.6, 0.5, 5), at(0, 0.25, 0.2), color("White"))
	block(k, "TreadmillBelt", Vector3.new(2, 0.1, 4.2), at(0, 0.55, 0.5), color("Ink"))
	cyl(k, "TreadmillHood", 2.6, 0.9, at(0, 0.45, -2.15), tint)
	for _, side in { -1, 1 } do
		block(k, "TreadmillPost", Vector3.new(0.3, 3, 0.3), at(side * 1.15, 1.9, -2.2), color("White"))
		block(k, "TreadmillRail", Vector3.new(0.3, 0.3, 1.6), at(side * 1.15, 3.1, -1.5), color("White"))
	end
	block(k, "TreadmillConsole", Vector3.new(2.6, 0.9, 0.6), at(0, 3.55, -2.25) * CFrame.Angles(math.rad(-30), 0, 0), tint)
end

-- Free-standing punching bag: the bag hangs at -X, its stand post at +X.
PROP_BUILDERS.PunchBag = function(k, tint)
	cyl(k, "BagStandBase", 0.4, 2.4, at(0.9, 0.2, 0) * UPRIGHT, color("White"))
	block(k, "BagStandPost", Vector3.new(0.5, 6.8, 0.5), at(0.9, 3.6, 0), color("White"))
	block(k, "BagStandArm", Vector3.new(2.3, 0.45, 0.45), at(-0.05, 6.75, 0), color("White"))
	cyl(k, "BagChain", 0.6, 0.2, at(-0.9, 6.25, 0) * UPRIGHT, color("Chrome"))
	ball(k, "BagTop", 2.2, at(-0.9, 4.9, 0), tint, Enum.Material.Fabric)
	cyl(k, "Bag", 2.8, 2.2, at(-0.9, 3.5, 0) * UPRIGHT, tint, Enum.Material.Fabric)
	ball(k, "BagBottom", 2.2, at(-0.9, 2.1, 0), tint, Enum.Material.Fabric)
	cyl(k, "BagBand", 0.5, 2.3, at(-0.9, 4.3, 0) * UPRIGHT, color("Sunny"))
end

-- Water cooler with its taps on the -Z face.
PROP_BUILDERS.WaterCooler = function(k, tint)
	block(k, "CoolerBody", Vector3.new(1.5, 2.6, 1.5), at(0, 1.3, 0), color("White"))
	block(k, "CoolerBand", Vector3.new(1.56, 0.35, 1.56), at(0, 2.35, 0), tint)
	cyl(k, "CoolerTop", 0.2, 1.4, at(0, 2.7, 0) * UPRIGHT, color("White"))
	local bottle = cyl(k, "CoolerBottle", 1.5, 1.3, at(0, 3.55, 0) * UPRIGHT, color("Pool"))
	local dome = ball(k, "CoolerBottle", 1.3, at(0, 4.3, 0), color("Pool"))
	bottle.Transparency = 0.1
	dome.Transparency = 0.1
	block(k, "CoolerTap", Vector3.new(0.3, 0.3, 0.4), at(-0.35, 1.9, -0.85), color("Coral"))
	block(k, "CoolerTap", Vector3.new(0.3, 0.3, 0.4), at(0.35, 1.9, -0.85), color("Blue"))
	block(k, "CoolerTray", Vector3.new(1, 0.15, 0.5), at(0, 1.15, -0.95), color("Steel"))
end

-- Potted palm with a gently curving trunk; only the pot blocks the player.
PROP_BUILDERS.PalmPlanter = function(k, tint)
	cyl(k, "PalmPot", 2, 2.8, at(0, 1, 0) * UPRIGHT, tint)
	cyl(k, "PalmPotRim", 0.5, 3.2, at(0, 2.1, 0) * UPRIGHT, color("White"))
	cyl(k, "PalmSoil", 0.2, 2.6, at(0, 2.3, 0) * UPRIGHT, color("WoodDark"))
	local trunk = {
		Vector3.new(0, 2.2, 0),
		Vector3.new(0.15, 4.1, 0),
		Vector3.new(0.45, 5.9, 0),
		Vector3.new(0.95, 7.6, 0),
	}
	for i = 1, 3 do
		local a, b = trunk[i], trunk[i + 1]
		local d = 0.95 - i * 0.1
		local frame = between(a, b)
		cyl(k, "PalmTrunk", (b - a).Magnitude + 0.25, d, frame, color("Wood")).CanCollide = false
	end
	local top = trunk[4]
	ball(k, "PalmCrown", 1.3, CFrame.new(top), color("GrassDark")).CanCollide = false
	for _, offset in { Vector3.new(0.4, -0.5, -0.35), Vector3.new(-0.35, -0.55, -0.3) } do
		ball(k, "Coconut", 0.65, CFrame.new(top + offset), color("WoodDark")).CanCollide = false
	end
	for i = 1, 7 do
		local yaw = math.rad(i * 360 / 7 + 10)
		local droop = math.rad(if i % 2 == 0 then 34 else 24)
		local frame = CFrame.new(top) * CFrame.Angles(0, yaw, 0) * CFrame.Angles(-droop, 0, 0) * CFrame.new(0, 0, -2)
		block(k, "PalmFrond", Vector3.new(1.4, 0.3, 4.4), frame, color(if i % 2 == 0 then "Grass" else "GrassDark")).CanCollide = false
	end
end

-- Party speaker on a low stand, cones on the -Z face.
PROP_BUILDERS.Speaker = function(k, tint)
	block(k, "SpeakerStand", Vector3.new(2, 0.3, 1.7), at(0, 0.15, 0), color("White"))
	block(k, "SpeakerBox", Vector3.new(1.8, 3.2, 1.5), at(0, 1.9, 0), tint)
	cyl(k, "SpeakerRim", 0.2, 1.4, at(0, 1.35, -0.76) * ALONG_Z, color("White"))
	cyl(k, "SpeakerCone", 0.22, 1, at(0, 1.35, -0.78) * ALONG_Z, color("Steel"))
	cyl(k, "SpeakerCap", 0.24, 0.4, at(0, 1.35, -0.8) * ALONG_Z, color("Sunny"))
	cyl(k, "SpeakerRim", 0.2, 0.8, at(0, 2.8, -0.76) * ALONG_Z, color("White"))
	cyl(k, "SpeakerTweeter", 0.22, 0.45, at(0, 2.8, -0.78) * ALONG_Z, color("Sunny"))
end

-- Props that block the player; the rest are small and walk-through.
local SOLID = {
	DumbbellRack = true,
	Bench = true,
	Treadmill = true,
	PunchBag = true,
	WaterCooler = true,
	PalmPlanter = true,
	Speaker = true,
}

export type PropOptions = { y: number?, scale: number?, tint: Color3? }

-- Builds Prop_<kind> standing at plot-local (x, y, z) whose front (-Z) is turned by `yaw`
-- degrees: 0 faces the entrance (-Z), 180 the back fence, 90 faces -X and -90 faces +X.
local function placeProp(B: Builder, parent: Instance, kind: string, x: number, z: number, yaw: number, options: PropOptions?): Model
	local opts: PropOptions = options or {}
	local scale = opts.scale or 1
	local y = opts.y or 0
	local foot = FOOTPRINT[kind] * scale
	local r = math.rad(yaw)
	local ex = math.abs(math.cos(r)) * foot.X + math.abs(math.sin(r)) * foot.Y
	local ez = math.abs(math.sin(r)) * foot.X + math.abs(math.cos(r)) * foot.Y
	checkClear("Prop_" .. kind, Layout.rect(x - ex, x + ex, z - ez, z + ez))

	local model = Instance.new("Model")
	model.Name = "Prop_" .. kind
	model:SetAttribute("Mesh", kind)
	model:SetAttribute("Scale", scale)
	-- The gym meshes are authored at the part-built size (World.Props).
	model:SetAttribute("MeshScale", scale)
	local base = CFrame.new(x, y, z) * CFrame.Angles(0, r, 0)
	local root = B.P({
		Name = "PropRoot",
		Size = Vector3.new(0.2, 0.2, 0.2),
		CFrame = B.L(x, y, z) * CFrame.Angles(0, r, 0),
		Transparency = 1,
		CanCollide = false,
		Parent = model,
	})
	root.CanQuery = false
	root.CanTouch = false
	root.CastShadow = false
	model.PrimaryPart = root
	local kit: Kit = {
		B = B,
		parent = model,
		base = B.cf * base,
		scale = scale,
		solid = SOLID[kind] == true,
	}
	PROP_BUILDERS[kind](kit, opts.tint or color("Pink"))
	model.Parent = parent
	return model
end

-- Gym corners -----------------------------------------------------------------------------

-- A soft teal floor mat (walk-over, plot-local centre and size).
local function floorMat(B: Builder, parent: Instance, x: number, z: number, sx: number, sz: number, tint: Color3)
	checkClear("GymMat", Layout.rect(x - sx / 2, x + sx / 2, z - sz / 2, z + sz / 2))
	B.P({
		Name = "GymMat",
		Size = Vector3.new(sx, 0.14, sz),
		CFrame = B.L(x, 0.07, z),
		Color = tint,
		CanCollide = false,
		Parent = parent,
	})
end

-- One accent group per free area; the Blender meshes (World.Props) carry their own colours,
-- the tints paint the part-built fallbacks.
local function buildGymProps(B: Builder, parent: Instance)
	-- -X front corner (right of the entrance): a dumbbell rack and a bench press on a teal mat.
	floorMat(B, parent, -27.3, -35.3, 12.6, 8.6, color("Mat"))
	placeProp(B, parent, "DumbbellRack", -29, -38.4, 180, { tint = color("Teal") })
	placeProp(B, parent, "Bench", -23.4, -34.6, 0, { tint = color("Coral") })
	placeProp(B, parent, "Barbell", -23.4, -32.4, 0, { y = 2.6, tint = color("Sunny") })

	-- -X fence between the converter and the vault: a treadmill.
	placeProp(B, parent, "Treadmill", -37.2, -18.25, 90, { tint = color("TealLight") })

	-- +X fence between the crate unlocker and the buy-tier pad: water cooler.
	placeProp(B, parent, "WaterCooler", 38.4, 4.1, 90, { tint = color("Blue") })

	-- +X front corner (left of the entrance): boxing bag.
	placeProp(B, parent, "PunchBag", 37, -24.6, -90, { tint = color("RedOrange") })

	-- Front fence: a palm and a speaker each side of the entrance, all at least ENTRANCE_CLEAR
	-- studs off the centre line so the spawn camera (Fx.Camera) sees the pen past them.
	for _, side in { 1, -1 } do
		placeProp(B, parent, "PalmPlanter", side * (ENTRANCE_CLEAR + 1.6), -37.6, side * 20, { tint = color("Sunny") })
		placeProp(B, parent, "Speaker", side * (ENTRANCE_CLEAR + 4.8), -38.8, 180 - side * 15, { tint = color("Teal") })
	end
end

-- Entrance path ---------------------------------------------------------------------------

-- A flat walk-over strip covering plot-local rect `r` with its top at `top`.
local function pathPiece(B: Builder, parent: Instance, name: string, r: Rect, top: number, tint: Color3): BasePart
	local thick = 0.04
	local p = B.P({
		Name = name,
		Size = Vector3.new(r.maxX - r.minX, thick, r.maxZ - r.minZ),
		CFrame = B.L((r.minX + r.maxX) / 2, top - thick / 2, (r.minZ + r.maxZ) / 2),
		Color = tint,
		CanCollide = false,
		Parent = parent,
	})
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	return p
end

-- One flat chevron pointing +Z (toward the pen), its tip at plot-local (0, tipZ).
local function chevron(B: Builder, parent: Instance, tipZ: number, top: number, tint: Color3)
	local spread, depth, thick = 1.7, 1.3, 0.03
	local tip = Vector3.new(0, top - thick / 2, tipZ)
	for _, side in { -1, 1 } do
		local tail = Vector3.new(side * spread, top - thick / 2, tipZ - depth)
		local length = (tip - tail).Magnitude + 0.3
		local arm = B.P({
			Name = "PathChevron",
			Size = Vector3.new(0.6, thick, length),
			CFrame = B.cf * CFrame.lookAt((tip + tail) / 2, tip),
			Color = tint,
			CanCollide = false,
			Parent = parent,
		})
		arm.CanQuery = false
		arm.CanTouch = false
		arm.CastShadow = false
	end
end

-- A cream path from the entrance up to the merge pad (it ends the walkway), then a bar along
-- the pen's front wall behind the pad out to the foot of both pen stairs, with two soft
-- chevrons between the spawn point and the merge pad.
local function buildPath(B: Builder, parent: Instance)
	local half = Layout.WALKWAY.maxX - 0.4
	local frontZ = Layout.POOL.minZ - 0.9
	local merge = Layout.padRect(Layout.PADS.Merge, Layout.PAD_RIM)
	local barZ0 = math.min(merge.maxZ + 0.6, frontZ - 1.2)
	local top = 0.15
	local cream = color("Cream")
	pathPiece(B, parent, "PathStrip", Layout.rect(-half, half, -Layout.PLOT_HALF, merge.minZ + 0.6), top, cream)
	-- Along the pen's front wall, out to the stairs on both sides.
	local stairs = Layout.PEN_STAIRS[1].rect
	local stairOuter = math.max(math.abs(stairs.minX), math.abs(stairs.maxX))
	pathPiece(B, parent, "PathStrip", Layout.rect(-stairOuter, stairOuter, barZ0, frontZ), top, cream)
	for _, stair in Layout.PEN_STAIRS do
		local r = stair.rect
		local inner = Layout.POOL.maxX + 0.2
		local x0, x1 = stair.side * inner, stair.side * stairOuter
		pathPiece(B, parent, "PathStrip", Layout.rect(math.min(x0, x1), math.max(x0, x1), frontZ, r.minZ - 0.1), top, cream)
	end
	for _, tipZ in { -19, -14.5 } do
		chevron(B, parent, tipZ, top + 0.02, color("PathEdge"))
	end
end

-- Fan zones -------------------------------------------------------------------------------

local function buildFanSpots(B: Builder)
	local folder = Instance.new("Folder")
	folder.Name = "FanSpots"
	for i, spot in Layout.fanSpots() do
		-- The fan runs in from the back of its own zone column (and walks off there), so it
		-- never crosses the rack and joins the crowd from behind the fans already standing.
		local backZ = spot.z
		for _, zone in Layout.FAN_ZONES do
			if Layout.contains(zone.rect, spot.x, spot.z) then
				backZ = math.min(zone.rect.maxZ + 0.5, Layout.INNER_HALF - 0.5)
			end
		end
		local yaw = math.atan2(-spot.faceX, -spot.faceZ)
		local p = B.P({
			Name = "FanSpot",
			Size = Vector3.new(1, 1, 1),
			CFrame = B.L(spot.x, 0, spot.z) * CFrame.Angles(0, yaw, 0),
			Transparency = 1,
			CanCollide = false,
			Parent = folder,
		})
		p.CanQuery = false
		p.CanTouch = false
		p.CastShadow = false
		p:SetAttribute("Order", i)
		p:SetAttribute("Entrance", B.L(spot.x, 0, backZ).Position)
	end
	folder.Parent = B.folder
end

-- A teal post carrying one end of the "FAN ZONE" card, with a sunny knob on top.
local function cardPost(k: Kit, x: number, z: number, height: number)
	cyl(k, "FanCardPost", height, 0.6, at(x, height / 2, z) * UPRIGHT, color("Teal"))
	ball(k, "FanCardKnob", 0.85, at(x, height + 0.15, z), color("Sunny"))
end

local function heartCutout(k: Kit, frame: CFrame, size: number, thick: number, tint: Color3)
	block(k, "Heart", Vector3.new(size, size, thick), frame * CFrame.Angles(0, 0, math.rad(45)), tint)
	local o = size / (2 * math.sqrt(2))
	for _, side in { -1, 1 } do
		cyl(k, "Heart", thick, size, frame * CFrame.new(side * o, o, 0) * ALONG_Z, tint)
	end
end

-- Five-pointed star in the frame's XY plane (tip up): a core disc plus two wedges per point.
local function starCutout(k: Kit, frame: CFrame, outer: number, inner: number, thick: number, tint: Color3)
	cyl(k, "Star", thick, inner * 2, frame * ALONG_Z, tint)
	local c36, s36 = math.cos(math.rad(36)), math.sin(math.rad(36))
	local h, d = outer - inner * c36, inner * s36
	for i = 0, 4 do
		local a = math.rad(90 + i * 72)
		local u = Vector3.new(math.cos(a), math.sin(a), 0)
		local mid = u * inner * c36
		for _, side in { -1, 1 } do
			local p = Vector3.new(-u.Y, u.X, 0) * side
			local zAxis = -p
			wedge(
				k,
				"Star",
				Vector3.new(thick, h, d),
				frame * CFrame.fromMatrix(mid + u * (h / 2) + p * (d / 2), u:Cross(zAxis), u, zAxis),
				tint
			)
		end
	end
end

-- A heart or star cut-out on a stick standing at plot-local (x, baseY, z), facing `yaw`.
local function cutoutSign(B: Builder, parent: Instance, kind: string, x: number, baseY: number, z: number, yaw: number)
	local k: Kit = {
		B = B,
		parent = parent,
		base = B.L(x, baseY, z) * CFrame.Angles(0, yaw, 0),
		scale = 1,
		solid = false,
	}
	local stick = 1.1
	block(k, "SignStick", Vector3.new(0.25, stick + 0.4, 0.25), at(0, (stick + 0.4) / 2, 0), color("White"))
	if kind == "Heart" then
		local size = 1.3
		heartCutout(k, at(0, stick + size / math.sqrt(2), 0), size, 0.3, color("Pink"))
	else
		local outer = 1
		starCutout(k, at(0, stick + outer * 0.81, 0), outer, 0.42, 0.3, color("Sunny"))
	end
end

local function fanCard(B: Builder, parent: Instance, x: number, y: number, z: number, width: number)
	local card = B.P({
		Name = "FanZoneCard",
		Size = Vector3.new(width, 1.9, 0.3),
		CFrame = B.L(x, y, z),
		Color = color("Teal"),
		CanCollide = false,
		Parent = parent,
	})
	local gui = Instance.new("SurfaceGui")
	gui.Face = Enum.NormalId.Front
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 40
	gui.LightInfluence = 1
	gui.MaxDistance = Common.SIGN_FADE_CARD
	gui.Parent = card
	local face = Instance.new("Frame")
	face.AnchorPoint = Vector2.new(0.5, 0.5)
	face.Position = UDim2.fromScale(0.5, 0.5)
	face.Size = UDim2.new(1, -12, 1, -12)
	face.BackgroundColor3 = color("Cream")
	face.BorderSizePixel = 0
	face.Parent = gui
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 18)
	corner.Parent = face
	local border = Instance.new("UIStroke")
	border.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	border.Color = color("Teal")
	border.Thickness = 4
	border.Parent = face
	local band = Instance.new("Frame")
	band.Size = UDim2.new(1, 0, 0.2, 0)
	band.BackgroundColor3 = color("Sunny")
	band.BorderSizePixel = 0
	band.Parent = face
	local bandCorner = Instance.new("UICorner")
	bandCorner.CornerRadius = UDim.new(0, 18)
	bandCorner.Parent = band
	local text = Instance.new("TextLabel")
	text.BackgroundTransparency = 1
	text.AnchorPoint = Vector2.new(0.5, 0)
	text.Position = UDim2.fromScale(0.5, 0.24)
	text.Size = UDim2.fromScale(0.9, 0.68)
	text.Font = theme.Fonts.Display
	text.TextScaled = true
	text.TextColor3 = color("Ink")
	text.Text = "FAN ZONE"
	text.Parent = face
end

-- Dressing for the fan zone on `side` (+1 = +X, -1 = -X): the "FAN ZONE" card on two teal
-- posts across its front edge, a 2-step bleacher in front of it and two cut-out signs on the
-- bleacher. The display side stays open.
local function dressFanZone(B: Builder, parent: Instance, side: number)
	local zone: Rect? = nil
	for _, fanZone in Layout.FAN_ZONES do
		if fanZone.side == side then
			zone = fanZone.rect
		end
	end
	if not zone then
		return
	end
	local innerX = if side > 0 then zone.minX else zone.maxX
	local frontZ = zone.minZ - 0.1
	local k: Kit = { B = B, parent = parent, base = B.cf, scale = 1, solid = true }

	-- "FAN ZONE" card between a post just off the display side and one by the fence.
	-- The card spans the full corner width, past the narrow -X zone's outer edge.
	local cardHeight = 6.9
	local cardInnerX = innerX - side * 0.35
	local cardOuterX = side * (Layout.INNER_HALF - 0.75)
	for _, px in { cardInnerX, cardOuterX } do
		cardPost(k, px, frontZ, cardHeight)
	end
	checkClear("FanCardPost", Layout.rect(cardInnerX - 0.45, cardInnerX + 0.45, frontZ - 0.45, frontZ + 0.45), true)
	fanCard(B, parent, (cardInnerX + cardOuterX) / 2, 5.95, frontZ, math.abs(cardOuterX - cardInnerX) - 0.6)

	-- Bleacher in front of the zone, rising away from the display.
	local z0, z1 = frontZ - 3.6, frontZ - 0.4
	local stepWidth = 2
	for step = 1, 2 do
		local x0 = innerX + side * (0.3 + (step - 1) * stepWidth)
		local cx = x0 + side * stepWidth / 2
		local top = 0.9 * step
		block(k, "BleacherRiser", Vector3.new(stepWidth, top - 0.15, z1 - z0), at(cx, (top - 0.15) / 2, (z0 + z1) / 2), color("Teal"))
		block(k, "BleacherSeat", Vector3.new(stepWidth + 0.1, 0.15, z1 - z0 + 0.2), at(cx, top - 0.075, (z0 + z1) / 2), color("Sunny"))
	end
	local bx0 = innerX + side * 0.3
	local bx1 = bx0 + side * stepWidth * 2
	checkClear("FanBleacher", Layout.rect(math.min(bx0, bx1), math.max(bx0, bx1), z0, z1))

	-- Cut-out signs planted on the bleacher, turned toward the middle of the plot.
	local function facePlotCentre(x: number, z: number): number
		return math.atan2(x, z + 10)
	end
	local heartX = innerX + side * 1.1
	local starX = innerX + side * 3.4
	local signZ = z0 + 0.5
	cutoutSign(B, parent, "Heart", heartX, 0.9, signZ, facePlotCentre(heartX, signZ))
	cutoutSign(B, parent, "Star", starX, 1.8, signZ, facePlotCentre(starX, signZ))
end

local function buildGymDecor(B: Builder)
	local parent = Instance.new("Folder")
	parent.Name = "Decor"
	parent.Parent = B.folder
	buildGymProps(B, parent)
	buildPath(B, parent)
	for _, side in { 1, -1 } do
		dressFanZone(B, parent, side)
	end
	buildFanSpots(B)
end

Decor.buildGymDecor = buildGymDecor

return Decor
