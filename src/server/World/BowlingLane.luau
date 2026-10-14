--!strict
--[[
	BowlingLane: the DUMBBELL BOWL arena out at sea (teleport-only; Modes.Bowling brings players here).
	Numbers live in Modes.BowlingRules (ARENA, LANE, PIN_SPOTS, PIN, BALL); the shell (floor,
	spawn pad, exit arch) comes from World.Arena.

	The dressing, parts only: a glossy honey-wood lane with board lines, aiming dots and red
	chevron arrows, a pale pin deck, steel gutters and capped dividers, a dark pit behind the
	pins, a navy back wall with three neon strips, side kickbacks, a lit "DUMBBELL BOWL"
	header over the pins, a giant pin statue by the approach and a ball-return rack holding
	three giant dumbbells.

	The ten pins (white with two red neck stripes; Models "Pin1".."Pin10" with attribute
	Index, pivot at the base centre) stand in `pins` for everyone to see. During a run
	Fx.Bowling hides them on that client and animates its own clones, so several players can
	bowl here at once without sharing pins. The rack's first dumbbell (attribute Roller) is
	the one Fx.Bowling clones to roll.

	build() -> Built: everything World.Arena.Base has ({ folder, floor, spawn, exit,
	exitRadius, center, top }) plus
	lane       the lane slab ("BowlingLane", runs -Z from the foul line)
	rollStart  feet CFrame 3 studs behind the foul line, looking down the lane (-Z)
	pinSpots   10 CFrames (pin base centres) in the classic triangle at the far end, head pin first
	pins       Folder "Pins" with the ten pin Models
]]

local Common = require(script.Parent.Common)
local Arena = require(script.Parent.Arena)
local BowlingRules = require(script.Parent.Parent.Modes.BowlingRules)

local W = Common.theme.World
local make = Common.make
local UPRIGHT = Common.UPRIGHT

local BowlingLane = {}

export type Built = Arena.Base & {
	lane: BasePart,
	rollStart: CFrame,
	pinSpots: { CFrame },
	pins: Folder,
}

-- Pin colours (cartoony: bright white body, red neck stripes).
local PIN_WHITE = Color3.fromRGB(252, 250, 246)
local PIN_RED = Color3.fromRGB(226, 46, 58)
-- The dumbbells on the rack: plate colours (the first is the one that rolls).
local PLATE_COLORS = { W.RedOrange, W.Blue, W.Grape }
-- The back wall's neon strips, bottom to top.
local NEON_STRIPS = { W.HotPink, W.Sunny, W.Mint }

local function ellipsoid(props: { [string]: any }): BasePart
	local p = make("Part", props)
	local mesh = Instance.new("SpecialMesh")
	mesh.MeshType = Enum.MeshType.Sphere
	mesh.Parent = p
	return p
end

-- A pin Model standing on `base` (its base centre), `scale` times the rules' size.
local function makePin(parent: Instance, name: string, base: CFrame, scale: number): Model
	local model = Instance.new("Model")
	model.Name = name
	local s = scale * BowlingRules.PIN.height / 3.2
	local function at(y: number): CFrame
		return base * CFrame.new(0, y * s, 0)
	end
	local quiet = { CanCollide = false, CanQuery = false, CanTouch = false, Parent = model }
	local function props(extra: { [string]: any }): { [string]: any }
		local t = table.clone(quiet)
		for k, v in extra do
			t[k] = v
		end
		return t
	end
	ellipsoid(props({ Name = "Belly", Size = Vector3.new(1.2, 2.2, 1.2) * s, CFrame = at(1.1), Color = PIN_WHITE }))
	make(
		"Part",
		props({
			Name = "Neck",
			Shape = Enum.PartType.Cylinder,
			Size = Vector3.new(0.75, 0.64, 0.64) * s,
			CFrame = at(2.2) * UPRIGHT,
			Color = PIN_WHITE,
		})
	)
	ellipsoid(props({ Name = "Head", Size = Vector3.new(0.84, 0.95, 0.84) * s, CFrame = at(2.72), Color = PIN_WHITE }))
	for i, y in { 1.98, 2.24 } do
		make(
			"Part",
			props({
				Name = "Stripe" .. i,
				Shape = Enum.PartType.Cylinder,
				Size = Vector3.new(0.13, 0.74, 0.74) * s,
				CFrame = at(y) * UPRIGHT,
				Color = PIN_RED,
			})
		)
	end
	model.WorldPivot = base
	model.Parent = parent
	return model
end

-- A giant dumbbell lying across X with its centre at `centre` (plates `radius` studs).
local function makeDumbbell(parent: Instance, centre: Vector3, plate: Color3, roller: boolean): Model
	local model = Instance.new("Model")
	model.Name = if roller then "BowlDumbbell" else "RackDumbbell"
	local b = BowlingRules.BALL
	local quiet = { CanQuery = false, CanTouch = false, Parent = model }
	local function props(extra: { [string]: any }): { [string]: any }
		local t = table.clone(quiet)
		for k, v in extra do
			t[k] = v
		end
		return t
	end
	local cf = CFrame.new(centre)
	make(
		"Part",
		props({
			Name = "Bar",
			Shape = Enum.PartType.Cylinder,
			Size = Vector3.new(b.halfLength * 2 + 0.3, 0.55, 0.55),
			CFrame = cf,
			Color = W.Chrome,
			Reflectance = 0.25,
		})
	)
	for _, side in { -1, 1 } do
		local x = side * (b.halfLength - 0.35)
		make(
			"Part",
			props({
				Name = "Plate",
				Shape = Enum.PartType.Cylinder,
				Size = Vector3.new(0.7, b.radius * 2, b.radius * 2),
				CFrame = cf * CFrame.new(x, 0, 0),
				Color = plate,
			})
		)
		make(
			"Part",
			props({
				Name = "Hub",
				Shape = Enum.PartType.Cylinder,
				Size = Vector3.new(0.8, b.radius * 1.1, b.radius * 1.1),
				CFrame = cf * CFrame.new(x, 0, 0),
				Color = W.Sunny,
			})
		)
	end
	model.WorldPivot = cf
	if roller then
		model:SetAttribute("Roller", true)
	end
	model.Parent = parent
	return model
end

function BowlingLane.build(): Built
	local a = BowlingRules.ARENA
	local L = BowlingRules.LANE
	local base = Arena.base("bowling", "BowlingLane", a, { floor = "Cream", trim = "RedOrange" })
	local folder = base.folder
	local top = base.top
	local laneW, laneL = L.width, L.length
	local foulZ = a.z + a.sizeZ / 2 - L.foulFromEdge
	local x0 = a.x
	-- World point of lane space (x across, d down the lane) at height `y` over the floor top.
	local function at(x: number, d: number, y: number): Vector3
		return Vector3.new(x0 + x, top + y, foulZ - d)
	end
	local laneTop = 0.2

	-- Lane: glossy honey wood with dark board lines, from the foul line to the pit.
	local lane = make("Part", {
		Name = "BowlingLane",
		Size = Vector3.new(laneW, 0.2, laneL),
		CFrame = CFrame.new(at(0, laneL / 2, 0.1)),
		Color = W.Honey,
		Material = Enum.Material.Wood,
		Reflectance = 0.12,
		Parent = folder,
	})
	for _, x in { -5.25, -3.5, -1.75, 1.75, 3.5, 5.25 } do
		make("Part", {
			Name = "LaneBoard",
			Size = Vector3.new(0.08, 0.02, laneL),
			CFrame = CFrame.new(at(x, laneL / 2, laneTop + 0.01)),
			Color = W.SandDark,
			CanCollide = false,
			CanQuery = false,
			Parent = folder,
		})
	end
	-- The approach behind the foul line (pale wood, under the spawn pad) and the foul line.
	make("Part", {
		Name = "Approach",
		Size = Vector3.new(laneW + 6, 0.1, 10),
		CFrame = CFrame.new(at(0, -5, 0.05)),
		Color = W.Wood,
		Material = Enum.Material.Wood,
		Reflectance = 0.08,
		Parent = folder,
	})
	make("Part", {
		Name = "FoulLine",
		Size = Vector3.new(laneW + 4, 0.25, 0.5),
		CFrame = CFrame.new(at(0, 0, 0.13)),
		Color = W.Coral,
		Parent = folder,
	})
	-- Aiming dots (d 7) and the chevron arrows (centre one farthest), like a real lane.
	for _, x in { -4.5, -3, -1.5, 1.5, 3, 4.5 } do
		make("Part", {
			Name = "LaneDot",
			Shape = Enum.PartType.Cylinder,
			Size = Vector3.new(0.04, 0.45, 0.45),
			CFrame = CFrame.new(at(x, 7, laneTop + 0.01)) * UPRIGHT,
			Color = W.Ink,
			CanCollide = false,
			CanQuery = false,
			Parent = folder,
		})
	end
	local ARM, TILT = 1.4, math.rad(28)
	for i = -3, 3 do
		local x = i * 1.5
		local tipD = 14 + (3 - math.abs(i)) * 1.3
		for _, side in { -1, 1 } do
			local mid = at(x + side * math.sin(TILT) * ARM / 2, tipD - math.cos(TILT) * ARM / 2, laneTop + 0.015)
			make("Part", {
				Name = "LaneArrow",
				Size = Vector3.new(0.32, 0.03, ARM),
				CFrame = CFrame.new(mid) * CFrame.Angles(0, side * TILT, 0),
				Color = W.RedOrange,
				CanCollide = false,
				CanQuery = false,
				Parent = folder,
			})
		end
	end
	-- Pin deck: paler wood under the triangle.
	local deckFrom = L.headD - 3
	make("Part", {
		Name = "PinDeck",
		Size = Vector3.new(laneW, 0.03, laneL - deckFrom),
		CFrame = CFrame.new(at(0, (deckFrom + laneL) / 2, laneTop + 0.005)),
		Color = W.Wood,
		Material = Enum.Material.Wood,
		Reflectance = 0.1,
		CanCollide = false,
		CanQuery = false,
		Parent = folder,
	})

	-- Gutters (steel channels a little under the lane) and capped dividers outside them.
	local outer = laneW / 2 + L.gutter
	for _, side in { -1, 1 } do
		make("Part", {
			Name = "BowlingGutter",
			Size = Vector3.new(L.gutter, 0.1, laneL),
			CFrame = CFrame.new(at(side * (laneW / 2 + L.gutter / 2), laneL / 2, -0.05)),
			Color = W.Steel,
			Material = Enum.Material.Metal,
			Reflectance = 0.2,
			Parent = folder,
		})
		make("Part", {
			Name = "LaneDivider",
			Size = Vector3.new(1, 0.7, laneL),
			CFrame = CFrame.new(at(side * (outer + 0.5), laneL / 2, 0.35)),
			Color = W.Teal,
			Parent = folder,
		})
		-- Kickbacks: tall side walls by the pins, coral with a neon edge.
		local kickL = laneL + 4 - deckFrom + 3
		local kickD = deckFrom - 3 + kickL / 2
		make("Part", {
			Name = "Kickback",
			Size = Vector3.new(1, 6, kickL),
			CFrame = CFrame.new(at(side * (outer + 0.5), kickD, 3.7)),
			Color = W.Coral,
			Parent = folder,
		})
		make("Part", {
			Name = "KickbackGlow",
			Size = Vector3.new(1.1, 0.35, kickL),
			CFrame = CFrame.new(at(side * (outer + 0.5), kickD, 6.6)),
			Color = W.Sunny,
			Material = Enum.Material.Neon,
			CanCollide = false,
			CanQuery = false,
			Parent = folder,
		})
	end

	-- Pit behind the lane and the back wall with its neon strips.
	local pitD = laneL + BowlingRules.PIT / 2 + 0.5
	make("Part", {
		Name = "Pit",
		Size = Vector3.new(outer * 2, 0.1, BowlingRules.PIT + 1),
		CFrame = CFrame.new(at(0, pitD, -0.3)),
		Color = W.Basalt,
		Parent = folder,
	})
	local wallD = laneL + BowlingRules.PIT + 1.5
	make("Part", {
		Name = "BackWall",
		Size = Vector3.new(outer * 2 + 2, 10, 1),
		CFrame = CFrame.new(at(0, wallD, 5)),
		Color = W.Navy,
		Parent = folder,
	})
	for i, color in NEON_STRIPS do
		make("Part", {
			Name = "BackNeon",
			Size = Vector3.new(outer * 2 + 2, 0.4, 0.2),
			CFrame = CFrame.new(at(0, wallD - 0.55, 1.2 + i * 1.1)),
			Color = color,
			Material = Enum.Material.Neon,
			CanCollide = false,
			CanQuery = false,
			Parent = folder,
		})
	end

	-- The header over the pins: a sign facing the bowler with a light on the pin deck.
	local header = make("Part", {
		Name = "BowlingHeader",
		Size = Vector3.new(outer * 2 + 2, 3.4, 1),
		CFrame = CFrame.new(at(0, deckFrom - 1, 10)),
		Color = W.RedOrange,
		Parent = folder,
	})
	local gui = Instance.new("SurfaceGui")
	gui.Face = Enum.NormalId.Back
	gui.PixelsPerStud = 30
	gui.LightInfluence = 0
	gui.Parent = header
	Common.label(gui, {
		Text = "DUMBBELL BOWL",
		Font = Common.theme.Fonts.Display,
		TextColor3 = W.White,
		Size = UDim2.fromScale(0.94, 0.62),
		Position = UDim2.fromScale(0.03, 0.06),
	})
	Common.label(gui, {
		Text = "KNOCK 'EM ALL DOWN!",
		Font = Common.theme.Fonts.Display,
		TextColor3 = W.Sunny,
		Size = UDim2.fromScale(0.7, 0.26),
		Position = UDim2.fromScale(0.15, 0.68),
	})
	local light = Instance.new("SpotLight")
	light.Face = Enum.NormalId.Bottom
	light.Angle = 70
	light.Range = 18
	light.Brightness = 1.6
	light.Color = Color3.fromRGB(255, 244, 224)
	light.Parent = header
	for _, side in { -1, 1 } do
		make("Part", {
			Name = "HeaderPost",
			Size = Vector3.new(0.8, 10, 0.8),
			CFrame = CFrame.new(at(side * (outer + 0.5), deckFrom - 1, 5)),
			Color = W.Teal,
			Parent = folder,
		})
	end

	-- Pins: the classic triangle (head pin first).
	local pins = Instance.new("Folder")
	pins.Name = "Pins"
	pins.Parent = folder
	local pinSpots = {}
	for i, spot in BowlingRules.PIN_SPOTS do
		local cf = CFrame.new(at(spot.x, spot.d, laneTop))
		pinSpots[i] = cf
		local pin = makePin(pins, "Pin" .. i, cf, 1)
		pin:SetAttribute("Index", i)
	end
	-- A giant pin statue on the approach's left, on a sunny plinth.
	local statueAt = at(-(outer + 3.5), 3, 0)
	make("Part", {
		Name = "StatuePlinth",
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(0.8, 4, 4),
		CFrame = CFrame.new(statueAt + Vector3.new(0, 0.4, 0)) * UPRIGHT,
		Color = W.Sunny,
		Parent = folder,
	})
	makePin(folder, "PinStatue", CFrame.new(statueAt + Vector3.new(0, 0.8, 0)) * CFrame.Angles(0, math.rad(20), 0), 2.2)

	-- Ball return: a coral rack with two steel rails and three giant dumbbells on the right
	-- (just down the lane, clear of the exit pad in the +X, +Z corner).
	local rackX = outer + 3.5
	local rackD = 6
	local RACK_LEN = 10.5
	make("Part", {
		Name = "BallRack",
		Size = Vector3.new(3.6, 1.8, RACK_LEN),
		CFrame = CFrame.new(at(rackX, rackD, 0.9)),
		Color = W.Coral,
		Parent = folder,
	})
	local b = BowlingRules.BALL
	local railX = b.halfLength - 0.35
	for _, side in { -1, 1 } do
		make("Part", {
			Name = "BallRackRail",
			Size = Vector3.new(0.4, 0.4, RACK_LEN + 0.4),
			CFrame = CFrame.new(at(rackX + side * railX, rackD, 2)),
			Color = W.Chrome,
			Material = Enum.Material.Metal,
			Parent = folder,
		})
	end
	for i, color in PLATE_COLORS do
		local d = rackD + (i - 2) * (b.radius * 2 + 0.3)
		makeDumbbell(folder, at(rackX, d, 2.2 + b.radius), color, i == 1)
	end

	local built: any = base
	built.lane = lane
	built.rollStart = CFrame.lookAt(at(0, -3, 0), at(0, laneL, 0))
	built.pinSpots = pinSpots
	built.pins = pins
	return built :: Built
end

return BowlingLane
