--[[
	Decor: everything painted on a plot's floor (the courts under each group of pads, the cream
	path from the entrance to the merge court and on to both side courts), the
	sunny gym dressing in the areas the courts leave free (a palm each side of the entrance, a
	palm by each side fence), the interactive props along the front fence and the two fan
	zones beside the display ledge. The plot is kept calm: few props, open floor.
	Part of the world generator; see Server.WorldBuilder for the overview and plot axes.

	Gym props are Models named Prop_<Kind> with attribute Mesh = "<Kind>" (and Scale) whose
	PrimaryPart ("PropRoot", invisible) sits at the prop's base centre with the prop's front
	along its -Z. World.Props swaps the chunky part-built body for the uploaded Blender mesh at the
	same size (attribute MeshScale) and keeps it as the fallback when the mesh is missing. Props
	stand only in the free areas PlotLayout leaves (along the fences, between the machines); every
	placement is checked against the layout and warns if it touches a pad, the pen, a machine,
	a crate area, a fan zone or the walkway.

	Interactive props are Models named Interactive_<Kind> with attribute Interactive = "<kind>"
	(trampoline, punchbag, bench, podium) standing on a mat at Layout.INTERACTIVE. Client.Fx.Interactive
	plays them (the bounce, the punches, the reps) and finds its way by the invisible marker
	parts built here, which stand beside the Prop_ models so World.Props never swaps them out:
	  Interactive_Trampoline  "BounceAnchor" at the bounce pad's top centre (attribute Radius)
	  Interactive_PunchBag    "BagPivot" where the bag hangs from the stand's arm; "HitZone", a
	                          walk-through box round the bag (attribute Reach: studs round it
	                          from which jump punches) holding the "PunchPrompt"
	  Interactive_Bench       "BenchSeat", a marker at the frame a lifter's root lies in (flat on
	                          the pad, up axis toward the rack, front facing the sky);
	                          "LiftAnchor" over the pad holding the "LiftPrompt"; "StandSpot" on
	                          the floor beside the bench, facing it, where the lifter gets up
	The only server behaviour is the bench, and there is no Seat in it: the server anchors a
	lifter's root on BenchSeat and owns the lift on the model's attributes, Lifter (the lifter's
	UserId, nil while the bench is free) and Reps (counted from the lifter's BenchRep actions,
	at most one per InteractiveRules.REP_GAP). The prompt starts a lift on a free bench and
	stops the lifter's own; Decor.releaseLifter stands a lifter up on StandSpot and un-anchors
	them, and runs as well when they move (BenchStop), die, respawn, leave or are teleported
	(Home, the game modes). One lifter per bench, one bench per lifter. The podium is still
	only a prop.

	Fan zones: each plot folder gets a "FanSpots" folder with one invisible "FanSpot" part per
	Layout.fanSpots() entry (attribute Order, 1 = filled first) at ground level, its
	LookVector facing the display, and attribute Entrance (world Vector3) at the back of its
	zone column, where Fx.Fans runs that spot's fan in from. The zones are dressed with a small bleacher, a "FAN ZONE"
	card on two posts and heart / star cut-outs; the spots themselves stay clear.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Rules = require(ReplicatedStorage.Shared.InteractiveRules)
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

-- Floor paint -------------------------------------------------------------------------------

-- Everything painted on the floor is a thin walk-through part. Each layer has its own height
-- (its top surface above the floor, at most 0.12) so overlapping layers never z-fight; the
-- fence band (World.Shell "FloorBorder") lies at 0.04, between the kerbs and the paths.
local PAINT_THICK = 0.04
local KERB_TOP = 0.02
local PATH_TOP = 0.06
local LINE_TOP = 0.08
local COURT_TOP = 0.1
local MARK_TOP = 0.12

local function paintPart(B: Builder, parent: Instance, props: { [string]: any }): BasePart
	props.Parent = parent
	props.CanCollide = false
	local p = B.P(props)
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	return p
end

-- A flat strip covering plot-local rect `r` with its top at `top`.
local function paintRect(B: Builder, parent: Instance, name: string, r: Rect, top: number, tint: Color3): BasePart
	return paintPart(B, parent, {
		Name = name,
		Size = Vector3.new(r.maxX - r.minX, PAINT_THICK, r.maxZ - r.minZ),
		CFrame = B.L((r.minX + r.maxX) / 2, top - PAINT_THICK / 2, (r.minZ + r.maxZ) / 2),
		Color = tint,
	})
end

-- A flat disc of `radius` centred on plot-local (x, z).
local function paintDisc(
	B: Builder,
	parent: Instance,
	name: string,
	x: number,
	z: number,
	radius: number,
	top: number,
	tint: Color3
): BasePart
	return paintPart(B, parent, {
		Name = name,
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(PAINT_THICK, radius * 2, radius * 2),
		CFrame = B.L(x, top - PAINT_THICK / 2, z) * UPRIGHT,
		Color = tint,
	})
end

-- A rounded rectangle: two crossed strips plus a disc in each corner (like a pad's base).
local function paintRounded(B: Builder, parent: Instance, name: string, r: Rect, radius: number, top: number, tint: Color3)
	paintRect(B, parent, name, Layout.rect(r.minX, r.maxX, r.minZ + radius, r.maxZ - radius), top, tint)
	paintRect(B, parent, name, Layout.rect(r.minX + radius, r.maxX - radius, r.minZ, r.maxZ), top, tint)
	for _, x in { r.minX + radius, r.maxX - radius } do
		for _, z in { r.minZ + radius, r.maxZ - radius } do
			paintDisc(B, parent, name, x, z, radius, top, tint)
		end
	end
end

-- Width of the white line round a court or mat, and a court's corner radius.
local COURT_LINE = Layout.COURT_LINE
local COURT_CORNER = 3

-- A painted court covering `r`: a rounded mat with a white border line.
local function paintCourt(B: Builder, parent: Instance, r: Rect, tint: Color3)
	local i = COURT_LINE
	paintRounded(B, parent, "CourtLine", r, COURT_CORNER, LINE_TOP, color("White"))
	paintRounded(B, parent, "Court", Layout.rect(r.minX + i, r.maxX - i, r.minZ + i, r.maxZ - i), COURT_CORNER - i, COURT_TOP, tint)
end

-- A round painted mat of `radius` with the same white border line.
local function paintRoundCourt(B: Builder, parent: Instance, name: string, x: number, z: number, radius: number, tint: Color3)
	paintDisc(B, parent, name .. "Line", x, z, radius, LINE_TOP, color("White"))
	paintDisc(B, parent, name, x, z, radius - COURT_LINE, COURT_TOP, tint)
end

-- One flat chevron with its tip at plot-local (tipX, tipZ), pointing along (dirX, dirZ) (a
-- unit vector), painted on top of everything else.
local function chevron(B: Builder, parent: Instance, tipX: number, tipZ: number, dirX: number, dirZ: number, tint: Color3)
	local spread, depth = 1.7, 1.3
	local y = MARK_TOP - PAINT_THICK / 2
	local tip = Vector3.new(tipX, y, tipZ)
	for _, side in { -1, 1 } do
		local tail = tip - Vector3.new(dirX, 0, dirZ) * depth + Vector3.new(-dirZ, 0, dirX) * side * spread
		local length = (tip - tail).Magnitude + 0.3
		paintPart(B, parent, {
			Name = "PathChevron",
			Size = Vector3.new(0.6, PAINT_THICK, length),
			CFrame = B.cf * CFrame.lookAt((tip + tail) / 2, tip),
			Color = tint,
		})
	end
end

-- A court's fill: a palette colour taken a little toward cream, so it stays clearly coloured
-- against the honey sand while the pads (in their own brighter colours, dark rims) still pop.
local function courtTint(key: string, mix: number): Color3
	return color(key):Lerp(color("Cream"), mix)
end

-- Plot-local Z of the two lines that split a side court into its three station bays: half-way
-- between the pad bases of neighbouring stations on the -X court (the +X stations mirror them).
local function bayLines(): (number, number)
	local pads = Layout.PADS
	local function rim(name: string): Rect
		return Layout.padRect(pads[name], Layout.PAD_RIM)
	end
	return (rim("Deposit").minZ + rim("ProcUp10").maxZ) / 2, (rim("ProcUp1").minZ + rim("Collect").maxZ) / 2
end

-- The painted courts (Layout.COURTS): sunny yellow under the buy row, coral under the crate
-- stations, teal under the aura -> cash stations and a round orange one under the merge pad.
-- White lines across the side courts split them into one bay per station.
local function buildCourts(B: Builder, parent: Instance)
	local courts = Layout.COURTS
	paintCourt(B, parent, courts.Buy, courtTint("Sunny", 0.12))
	paintCourt(B, parent, courts.Crates, courtTint("Coral", 0.3))
	paintCourt(B, parent, courts.Cash, courtTint("Teal", 0.22))
	local merge = Layout.MERGE_COURT
	paintRoundCourt(B, parent, "MergeCourt", merge.x, merge.z, merge.radius, courtTint("Orange", 0.15))

	local backBay, frontBay = bayLines()
	local inset = 2
	for _, r in { courts.Cash, courts.Crates } do
		for _, z in { backBay, frontBay } do
			paintRect(B, parent, "CourtBayLine", Layout.rect(r.minX + inset, r.maxX - inset, z - 0.25, z + 0.25), MARK_TOP, color("White"))
		end
	end
	-- The loop's last leg, down the court to the collect pad: two chevrons either side of the
	-- front bay line.
	for _, tipZ in { frontBay + 1.5, frontBay - 2.1 } do
		chevron(B, parent, Layout.PADS.Collect.x, tipZ, 0, -1, color("White"))
	end
end

-- Paths -------------------------------------------------------------------------------------

-- The cream path with a thin teal kerb: a wide stem from the entrance to the plaza along the
-- pen's front (Layout.PLAZA), which joins both side courts with the merge court on the
-- junction. It carries no painted arrows: the guide's floor path (Client.Guide) shows the way.
local function buildPath(B: Builder, parent: Instance)
	-- Wider than the walkway PlotLayout keeps clear: the floor either side of it is open too.
	local half = Layout.WALKWAY.maxX + 1.5
	local plaza = Layout.PLAZA
	local kerb = 0.45
	-- The plaza's ends run a little way under the side courts' border lines.
	local tuck = 0.3
	local cream, edge = color("Cream"), color("Teal")
	paintRect(B, parent, "PathKerb", Layout.rect(-half - kerb, half + kerb, -Layout.INNER_HALF, plaza.minZ - kerb), KERB_TOP, edge)
	paintRect(B, parent, "PathStrip", Layout.rect(-half, half, -Layout.PLOT_HALF, plaza.minZ), PATH_TOP, cream)
	paintRect(
		B,
		parent,
		"PathKerb",
		Layout.rect(plaza.minX - tuck, plaza.maxX + tuck, plaza.minZ - kerb, plaza.maxZ + kerb),
		KERB_TOP,
		edge
	)
	paintRect(B, parent, "PathStrip", Layout.rect(plaza.minX - tuck, plaza.maxX + tuck, plaza.minZ, plaza.maxZ), PATH_TOP, cream)
end

-- Gym dressing ------------------------------------------------------------------------------

-- A teal floor mat (walk-over, plot-local centre and size).
local function floorMat(B: Builder, parent: Instance, x: number, z: number, sx: number, sz: number, tint: Color3)
	local r = Layout.rect(x - sx / 2, x + sx / 2, z - sz / 2, z + sz / 2)
	checkClear("GymMat", r)
	paintRect(B, parent, "GymMat", r, COURT_TOP, tint)
end

-- A little symmetric dressing in the areas the courts leave free; the Blender meshes
-- (World.Props) carry their own colours, the tints paint the part-built fallbacks.
local function buildGymProps(B: Builder, parent: Instance)
	-- Front fence: a palm each side of the entrance, at least ENTRANCE_CLEAR studs off the
	-- centre line so the view up the path to the pen stays open.
	local fenceZ = -Layout.INNER_HALF + 2.4
	for _, side in { 1, -1 } do
		placeProp(B, parent, "PalmPlanter", side * (ENTRANCE_CLEAR + 3), fenceZ, side * 20, { tint = color("Sunny") })
	end

	-- By each side fence: one palm in the machine line, on the bay line between the back and
	-- middle stations, leaning in toward the pen.
	local backBay = bayLines()
	for _, side in { 1, -1 } do
		placeProp(B, parent, "PalmPlanter", side * 42.5, backBay, 90 + side * 90, { tint = color("Sunny") })
	end
end

-- Interactive props -----------------------------------------------------------------------

-- An invisible walk-through marker for Client.Fx.Interactive at world frame `cframe`.
local function marker(B: Builder, parent: Instance, name: string, cframe: CFrame, size: Vector3?): BasePart
	local p = B.P({
		Name = name,
		Size = size or Vector3.new(0.2, 0.2, 0.2),
		CFrame = cframe,
		Transparency = 1,
		CanCollide = false,
		Parent = parent,
	})
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	return p
end

-- Studs round the punch bag's HitZone from which a jump press punches.
local PUNCH_REACH = 2.5

-- Prompts reach about a mat's width (`range` studs): tap on touch, `key` on a keyboard, X on
-- a gamepad.
local PROMPT_RANGE = 8

local function prompt(parent: BasePart, name: string, action: string, object: string, key: Enum.KeyCode, range: number?): ProximityPrompt
	local p = Instance.new("ProximityPrompt")
	p.Name = name
	p.ActionText = action
	p.ObjectText = object
	p.MaxActivationDistance = range or PROMPT_RANGE
	p.HoldDuration = 0
	-- The markers sit inside the props' colliders.
	p.RequiresLineOfSight = false
	p.KeyboardKeyCode = key
	p.GamepadKeyCode = Enum.KeyCode.ButtonX
	p.Parent = parent
	return p
end

-- Round trampoline, about 7 studs wide: a teal frame on six short legs round a coral bounce pad.
local function buildTrampoline(k: Kit)
	for i = 1, 6 do
		local a = math.rad(i * 60)
		cyl(k, "TrampolineLeg", 0.8, 0.5, at(math.cos(a) * 3, 0.4, math.sin(a) * 3) * UPRIGHT, color("White"))
	end
	cyl(k, "TrampolineFrame", 0.5, 7, at(0, 1.05, 0) * UPRIGHT, color("Teal"))
	cyl(k, "TrampolineSprings", 0.5, 6, at(0, 1.07, 0) * UPRIGHT, color("Cream"))
	cyl(k, "TrampolinePad", 0.5, 5.2, at(0, 1.09, 0) * UPRIGHT, color("Coral"))
end

-- Winner's podium, front along -Z: three cream steps (1st in the middle, 2nd at -X, 3rd at +X)
-- with coloured tops and their place printed on the front.
local function buildFlexPodium(k: Kit)
	local steps = {
		{ place = "1", x = 0, height = 2.2, tint = color("Sunny") },
		{ place = "2", x = -2.4, height = 1.5, tint = color("TealLight") },
		{ place = "3", x = 2.4, height = 0.9, tint = color("Coral") },
	}
	for _, step in steps do
		local body =
			block(k, "PodiumStep", Vector3.new(2.4, step.height - 0.25, 2.6), at(step.x, (step.height - 0.25) / 2, 0), color("Cream"))
		block(k, "PodiumTop", Vector3.new(2.4, 0.25, 2.6), at(step.x, step.height - 0.125, 0), step.tint)
		local gui = Instance.new("SurfaceGui")
		gui.Face = Enum.NormalId.Front
		gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
		gui.PixelsPerStud = 40
		gui.LightInfluence = 1
		gui.MaxDistance = Common.SIGN_FADE_CARD
		gui.Parent = body
		local place = Instance.new("TextLabel")
		place.BackgroundTransparency = 1
		place.Size = UDim2.fromScale(1, 1)
		place.Font = theme.Fonts.Display
		place.TextScaled = true
		place.TextColor3 = color("TealInk")
		place.Text = step.place
		place.Parent = gui
	end
end

-- Starts Interactive_<kind> (attribute Interactive = `use`) at the spot Layout.INTERACTIVE gives
-- it, on a round sunny mat (or, with `mat`, a teal rectangle of that size); the caller adds the
-- prop and its markers. Client.Fx.Interactive brings it to life.
local function interactive(B: Builder, parent: Instance, kind: string, use: string, mat: Vector2?): (Model, number, number)
	local spot = Layout.INTERACTIVE[kind]
	local x, z, radius = spot.x, spot.z, spot.radius
	checkClear("Interactive_" .. kind, Layout.rect(x - radius, x + radius, z - radius, z + radius))
	local model = Instance.new("Model")
	model.Name = "Interactive_" .. kind
	model:SetAttribute("Interactive", use)
	if mat then
		floorMat(B, model, x, z, mat.X, mat.Y, color("Mat"))
	else
		paintRoundCourt(B, model, "InteractiveMat", x, z, radius, color("Sunny"))
	end
	model.Parent = parent
	return model, x, z
end

-- Where a lifter lies, in the bench prop's frame (base centre, rack at +Z): flat on the pad,
-- head toward the rack. This is the lifter's root frame: up axis along the bench, front facing
-- the sky.
local BENCH_LIE = CFrame.new(0, 2.4, -0.2) * CFrame.Angles(math.rad(90), 0, 0)

-- Bench press lifts: the server holds each lifter's root anchored on its bench.
type Bench = { model: Model, lie: CFrame, stand: CFrame, lifter: Player? }
type Lift = {
	bench: Bench,
	character: Model,
	root: BasePart,
	reps: number,
	nextRep: number?, -- when the next rep may count (Rules.repAllowed)
	conns: { RBXScriptConnection },
}

local lifts: { [Player]: Lift } = {}
local watchingPlayers = false

-- Lets `player` go from the bench they lift on, if any: upright on its StandSpot facing the
-- bench, un-anchored, the bench free again. Call before moving a character elsewhere.
function Decor.releaseLifter(player: Player)
	local lift = lifts[player]
	if not lift then
		return
	end
	lifts[player] = nil
	for _, conn in lift.conns do
		conn:Disconnect()
	end
	local bench = lift.bench
	bench.lifter = nil
	bench.model:SetAttribute("Lifter", nil)

	local root = lift.root
	if not root.Parent then
		return
	end
	local humanoid = lift.character:FindFirstChildOfClass("Humanoid")
	-- A dead lifter is only let go: the body falls where it lies.
	if humanoid and humanoid.Health > 0 then
		local hip = if humanoid.RigType == Enum.HumanoidRigType.R15 then humanoid.HipHeight else 2
		root.CFrame = bench.stand + Vector3.new(0, hip + root.Size.Y / 2 + 0.1, 0)
		root.AssemblyLinearVelocity = Vector3.zero
		root.AssemblyAngularVelocity = Vector3.zero
	end
	root.Anchored = false
end

-- Counts one rep for `player` (action BenchRep): only while they lift, at the pace of the reps.
function Decor.benchRep(player: Player)
	local lift = lifts[player]
	if not lift then
		return
	end
	local counts
	counts, lift.nextRep = Rules.repAllowed(lift.nextRep, os.clock())
	if counts then
		lift.reps += 1
		lift.bench.model:SetAttribute("Reps", lift.reps)
	end
end

-- Lies `player` down on `bench`: only a living character that is free to move, on a free bench.
local function startLift(bench: Bench, player: Player)
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not character or not humanoid or not root or not root:IsA("BasePart") then
		return
	end
	-- An anchored root is held by something else (a game mode): leave it alone.
	if bench.lifter or lifts[player] or humanoid.Health <= 0 or humanoid.SeatPart ~= nil or root.Anchored then
		return
	end
	if not watchingPlayers then
		watchingPlayers = true
		Players.PlayerRemoving:Connect(Decor.releaseLifter)
	end
	local function release()
		Decor.releaseLifter(player)
	end
	-- Nobody stays anchored: dying, respawning and losing the character all end the lift.
	lifts[player] = {
		bench = bench,
		character = character,
		root = root,
		reps = 0,
		nextRep = nil,
		conns = {
			humanoid.Died:Connect(release),
			player.CharacterRemoving:Connect(release),
			character.AncestryChanged:Connect(function()
				if not character:IsDescendantOf(game) then
					release()
				end
			end),
		},
	}
	bench.lifter = player
	root.Anchored = true
	root.CFrame = bench.lie
	root.AssemblyLinearVelocity = Vector3.zero
	root.AssemblyAngularVelocity = Vector3.zero
	bench.model:SetAttribute("Reps", 0)
	bench.model:SetAttribute("Lifter", player.UserId)
end

-- The bench press: one lifter at a time lies on BenchSeat (the client poses and animates them).
-- The prompt lies whoever triggers it down while the bench is free and lets its own lifter go.
local function buildBench(B: Builder, model: Model, x: number, z: number)
	-- The rack stands toward the fence, the barbell resting on its hooks.
	local prop = placeProp(B, model, "Bench", x, z + 0.5, 180, { tint = color("Coral") })
	placeProp(B, model, "Barbell", x, z - 1.7, 0, { y = 2.6, tint = color("Sunny") })
	local base = (prop.PrimaryPart :: BasePart).CFrame

	local lie = base * BENCH_LIE
	marker(B, model, "BenchSeat", lie, Vector3.new(1.6, 0.2, 0.6))
	local standAt = base * Vector3.new(3, 0.1, -0.3)
	local stand = CFrame.lookAt(standAt, Vector3.new(lie.X, standAt.Y, lie.Z))
	marker(B, model, "StandSpot", stand)
	local lift = prompt(marker(B, model, "LiftAnchor", base * CFrame.new(0, 2.6, -0.3)), "LiftPrompt", "Lift", "Bench", Enum.KeyCode.E)

	local bench: Bench = { model = model, lie = lie, stand = stand, lifter = nil }
	-- pcall: the offline preview (Lune) has no instance signals.
	pcall(function()
		lift.Triggered:Connect(function(player: Player)
			if bench.lifter == player then
				Decor.releaseLifter(player)
			else
				startLift(bench, player)
			end
		end)
	end)
end

-- The four props along the front fence: a trampoline in the +X corner with a punch bag beside
-- it, a bench press mirroring the bag at -X, and a flex podium in the -X corner turned toward
-- the display rack the fans cheer at.
local function buildInteractive(B: Builder, parent: Instance)
	local trampoline, tx, tz = interactive(B, parent, "Trampoline", "trampoline")
	buildTrampoline({ B = B, parent = trampoline, base = B.L(tx, 0, tz), scale = 1, solid = true })
	-- The bounce pad's top centre; standing a little onto the frame still bounces.
	marker(B, trampoline, "BounceAnchor", B.L(tx, 1.34, tz)):SetAttribute("Radius", 2.9)

	-- The bag hangs on the plot side of its post.
	local punchBag, bx, bz = interactive(B, parent, "PunchBag", "punchbag")
	local bag = placeProp(B, punchBag, "PunchBag", bx, bz - 0.6, 90, { tint = color("RedOrange") })
	local bagBase = (bag.PrimaryPart :: BasePart).CFrame
	marker(B, punchBag, "BagPivot", bagBase * CFrame.new(-0.9, 6.5, 0))
	-- A little wider than the bag's collider, so running into the bag reaches it.
	local hitZone = marker(B, punchBag, "HitZone", bagBase * CFrame.new(-0.9, 3.5, 0), Vector3.new(4.2, 5.4, 4.4))
	-- Jump punches from PUNCH_REACH studs round the zone, where the client also keeps the avatar
	-- from hopping. The prompt shows the same key (Space) and reaches no further than that, so
	-- wherever it shows, a press is a punch and never a jump.
	hitZone:SetAttribute("Reach", PUNCH_REACH)
	prompt(hitZone, "PunchPrompt", "Punch", "Punch bag", Enum.KeyCode.Space, math.min(hitZone.Size.X, hitZone.Size.Z) / 2 + PUNCH_REACH)

	local bench, benchX, benchZ = interactive(B, parent, "Bench", "bench", Vector2.new(8, 7.4))
	buildBench(B, bench, benchX, benchZ)

	local podium, px, pz = interactive(B, parent, "FlexPodium", "podium")
	local facing = math.atan2(px - Layout.FAN_FOCUS.x, pz - Layout.FAN_FOCUS.z)
	buildFlexPodium({ B = B, parent = podium, base = B.L(px, 0, pz) * CFrame.Angles(0, facing, 0), scale = 1, solid = true })
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

	-- "FAN ZONE" card across the zone's front, between a post just off each of its sides.
	local cardHeight = 6.9
	local cardInnerX = innerX - side * 0.35
	local cardOuterX = (if side > 0 then zone.maxX else zone.minX) + side * 0.35
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
	buildCourts(B, parent)
	buildPath(B, parent)
	buildGymProps(B, parent)
	buildInteractive(B, parent)
	for _, side in { 1, -1 } do
		dressFanZone(B, parent, side)
	end
	buildFanSpots(B)
end

Decor.buildGymDecor = buildGymDecor

return Decor
