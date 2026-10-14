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
-- The pins stand this much bigger than BowlingRules.PIN (chunkier, cartoony, easy to read).
local PIN_SCALE = 1.25

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

-- The dressing beside the lane: a neighbouring lane on the left (pins standing, nobody bowls
-- there), bleachers and a scoreboard on the right and lamp posts down both edges.
type At = (x: number, d: number, y: number) -> Vector3
local function dress(folder: Instance, at: At, a: { [string]: number }, outer: number)
	local L = BowlingRules.LANE
	local laneL = L.length
	local half = a.sizeX / 2
	local quiet: { [string]: any } = { CanCollide = false, CanQuery = false, CanTouch = false }
	local function part(props: { [string]: any }): BasePart
		props.Parent = props.Parent or folder
		return make("Part", props)
	end
	local function deco(props: { [string]: any }): BasePart
		for k, v in quiet do
			props[k] = v
		end
		return part(props)
	end

	-- Neighbouring lane (left): narrower, its own gutters, arrows, deck and a full rack.
	local nW, nG = 10, 1.5
	local nx = -(outer + 1 + nG + nW / 2)
	local nOuter = nx - nW / 2 - nG
	part({
		Name = "SideLane",
		Size = Vector3.new(nW, 0.2, laneL),
		CFrame = CFrame.new(at(nx, laneL / 2, 0.1)),
		Color = W.Honey,
		Material = Enum.Material.Wood,
		Reflectance = 0.28,
	})
	deco({
		Name = "SideDeck",
		Size = Vector3.new(nW, 0.03, laneL - 68),
		CFrame = CFrame.new(at(nx, (68 + laneL) / 2, 0.205)),
		Color = W.Wood,
		Material = Enum.Material.Wood,
	})
	for _, side in { -1, 1 } do
		part({
			Name = "SideGutter",
			Size = Vector3.new(nG, 0.1, laneL),
			CFrame = CFrame.new(at(nx + side * (nW / 2 + nG / 2), laneL / 2, -0.05)),
			Color = W.Steel,
			Material = Enum.Material.Metal,
			Reflectance = 0.2,
		})
	end
	part({ Name = "SideDivider", Size = Vector3.new(1, 0.7, laneL), CFrame = CFrame.new(at(nOuter - 0.5, laneL / 2, 0.35)), Color = W.Teal })
	part({ Name = "SideKickback", Size = Vector3.new(1, 6, 22), CFrame = CFrame.new(at(nOuter - 0.5, laneL - 7, 3.7)), Color = W.Coral })
	deco({
		Name = "SideKickbackGlow",
		Size = Vector3.new(1.1, 0.35, 22),
		CFrame = CFrame.new(at(nOuter - 0.5, laneL - 7, 6.6)),
		Color = W.Sunny,
		Material = Enum.Material.Neon,
	})
	part({
		Name = "SidePit",
		Size = Vector3.new(nW + nG * 2, 0.1, BowlingRules.PIT + 1),
		CFrame = CFrame.new(at(nx, laneL + BowlingRules.PIT / 2 + 0.5, -0.3)),
		Color = W.Basalt,
	})
	for i = -2, 2 do
		local tipD = 14 + (2 - math.abs(i)) * 1.6
		for _, side in { -1, 1 } do
			deco({
				Name = "SideArrow",
				Size = Vector3.new(0.4, 0.03, 1.8),
				CFrame = CFrame.new(at(nx + i * 1.6 + side * 0.42, tipD - 0.8, 0.215)) * CFrame.Angles(0, side * math.rad(28), 0),
				Color = W.Blue,
			})
		end
	end
	local decoPins = Instance.new("Folder")
	decoPins.Name = "SidePins"
	decoPins.Parent = folder
	local k = 0.75
	for i, spot in BowlingRules.PIN_SPOTS do
		local d = 70 + (spot.d - BowlingRules.PIN_SPOTS[1].d) * k
		makePin(decoPins, "SidePin" .. i, CFrame.new(at(nx + spot.x * k, d, 0.2)), PIN_SCALE * 0.85)
	end

	-- Bleachers (right): four stepped tiers with coloured bench fronts, facing the lane.
	local BENCH = { W.Sunny, W.HotPink, W.Teal, W.Blue }
	local bx0, tierW = outer + 7, (half - outer - 7) / 4
	local bFrom, bTo = 16, 66
	for t = 1, 4 do
		local h = 1.3 * t
		local x = bx0 + (t - 0.5) * tierW
		part({
			Name = "Bleacher",
			Size = Vector3.new(tierW, h, bTo - bFrom),
			CFrame = CFrame.new(at(x, (bFrom + bTo) / 2, h / 2)),
			Color = W.White,
		})
		deco({
			Name = "BleacherBench",
			Size = Vector3.new(tierW * 0.55, 0.45, bTo - bFrom),
			CFrame = CFrame.new(at(x + tierW * 0.1, (bFrom + bTo) / 2, h + 0.22)),
			Color = BENCH[t],
		})
	end
	part({
		Name = "BleacherEnd",
		Size = Vector3.new(half - bx0, 6, 0.8),
		CFrame = CFrame.new(at((bx0 + half) / 2, bFrom - 0.4, 3)),
		Color = W.RedOrange,
	})
	part({
		Name = "BleacherEnd",
		Size = Vector3.new(half - bx0, 6, 0.8),
		CFrame = CFrame.new(at((bx0 + half) / 2, bTo + 0.4, 3)),
		Color = W.RedOrange,
	})

	-- Scoreboard (right, past the bleachers): a big screen on two posts facing the bowler.
	local sx, sd, sy = (bx0 + half) / 2 - 1, 76, 12
	local screen = part({ Name = "Scoreboard", Size = Vector3.new(13, 7, 0.8), CFrame = CFrame.new(at(sx, sd, sy)), Color = W.Ink })
	for _, side in { -1, 1 } do
		part({
			Name = "ScoreboardPost",
			Size = Vector3.new(0.8, sy, 0.8),
			CFrame = CFrame.new(at(sx + side * 5, sd + 0.2, sy / 2 - 3.5)),
			Color = W.Teal,
		})
		deco({
			Name = "ScoreboardNeon",
			Size = Vector3.new(13.6, 0.4, 0.3),
			CFrame = CFrame.new(at(sx, sd - 0.45, sy + side * 3.7)),
			Color = W.Mint,
			Material = Enum.Material.Neon,
		})
	end
	local board = Instance.new("SurfaceGui")
	board.Face = Enum.NormalId.Back
	board.PixelsPerStud = 24
	board.LightInfluence = 0
	board.Brightness = 1.6
	board.Parent = screen
	Common.label(board, {
		Text = "STRIKE!",
		Font = Common.theme.Fonts.Display,
		TextColor3 = W.Sunny,
		Size = UDim2.fromScale(0.9, 0.5),
		Position = UDim2.fromScale(0.05, 0.06),
	})
	Common.label(board, {
		Text = "SCORE " .. BowlingRules.PASS_SCORE .. " TO WIN",
		Font = Common.theme.Fonts.Display,
		TextColor3 = W.Mint,
		Size = UDim2.fromScale(0.86, 0.3),
		Position = UDim2.fromScale(0.07, 0.62),
	})

	-- Lamp posts down both edges: a teal pole with a glowing sunny globe.
	local lamps = { { -1, 8 }, { -1, 40 }, { -1, 72 }, { 1, 8 }, { 1, 84 } }
	for _, lamp in lamps do
		local x = lamp[1] * (half - 1.2)
		part({
			Name = "LampPost",
			Shape = Enum.PartType.Cylinder,
			Size = Vector3.new(14, 0.7, 0.7),
			CFrame = CFrame.new(at(x, lamp[2], 7)) * UPRIGHT,
			Color = W.Teal,
		})
		local globe = ellipsoid({
			Name = "LampGlobe",
			Size = Vector3.new(2, 2, 2),
			CFrame = CFrame.new(at(x, lamp[2], 14.6)),
			Color = W.Sunny,
			Material = Enum.Material.Neon,
			CanCollide = false,
			CanQuery = false,
			Parent = folder,
		})
		local glowLight = Instance.new("PointLight")
		glowLight.Range = 16
		glowLight.Brightness = 1.2
		glowLight.Color = Color3.fromRGB(255, 236, 190)
		glowLight.Parent = globe
	end
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
		Reflectance = 0.28,
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
	local ARM, TILT = 2.2, math.rad(28)
	for i = -3, 3 do
		local x = i * 1.75
		local tipD = 14 + (3 - math.abs(i)) * 1.8
		for _, side in { -1, 1 } do
			local mid = at(x + side * math.sin(TILT) * ARM / 2, tipD - math.cos(TILT) * ARM / 2, laneTop + 0.015)
			make("Part", {
				Name = "LaneArrow",
				Size = Vector3.new(0.45, 0.03, ARM),
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

	-- Pit behind the lane and the back wall (the whole arena's width) with its neon strips.
	local pitD = laneL + BowlingRules.PIT / 2 + 0.5
	make("Part", {
		Name = "Pit",
		Size = Vector3.new(outer * 2, 0.1, BowlingRules.PIT + 1),
		CFrame = CFrame.new(at(0, pitD, -0.3)),
		Color = W.Basalt,
		Parent = folder,
	})
	local wallD = laneL + BowlingRules.PIT + 1.5
	local wallW = a.sizeX
	make("Part", {
		Name = "BackWall",
		Size = Vector3.new(wallW, 12, 1),
		CFrame = CFrame.new(at(0, wallD, 6)),
		Color = W.Navy,
		Parent = folder,
	})
	for i, color in NEON_STRIPS do
		make("Part", {
			Name = "BackNeon",
			Size = Vector3.new(wallW, 0.4, 0.2),
			CFrame = CFrame.new(at(0, wallD - 0.55, 6.2 + i * 1.3)),
			Color = color,
			Material = Enum.Material.Neon,
			CanCollide = false,
			CanQuery = false,
			Parent = folder,
		})
	end
	-- The big glowing sign over the pin deck: a navy board on the back wall's top with a
	-- neon frame, "DUMBBELL BOWL" in white with a hot-pink glow and a sunny tagline.
	local SIGN_W, SIGN_H, SIGN_Y = 34, 7, 16.5
	local sign = make("Part", {
		Name = "BowlingSign",
		Size = Vector3.new(SIGN_W, SIGN_H, 0.8),
		CFrame = CFrame.new(at(0, wallD - 0.2, SIGN_Y)),
		Color = W.Navy,
		Parent = folder,
	})
	local gui = Instance.new("SurfaceGui")
	gui.Face = Enum.NormalId.Back
	gui.PixelsPerStud = 24
	gui.LightInfluence = 0
	gui.Brightness = 2
	gui.Parent = sign
	local title = Common.label(gui, {
		Text = "DUMBBELL BOWL",
		Font = Common.theme.Fonts.Display,
		TextColor3 = W.White,
		Size = UDim2.fromScale(0.94, 0.64),
		Position = UDim2.fromScale(0.03, 0.04),
	})
	local glow = title:FindFirstChildOfClass("UIStroke") or Instance.new("UIStroke")
	glow.Color = W.HotPink
	glow.Thickness = 6
	glow.Parent = title
	Common.label(gui, {
		Text = "KNOCK 'EM ALL DOWN!",
		Font = Common.theme.Fonts.Display,
		TextColor3 = W.Sunny,
		Size = UDim2.fromScale(0.64, 0.26),
		Position = UDim2.fromScale(0.18, 0.68),
	})
	local signFront = wallD - 0.75
	for _, edge in { { 0, SIGN_H / 2 + 0.3, SIGN_W + 1, 0.5 }, { 0, -SIGN_H / 2 - 0.3, SIGN_W + 1, 0.5 } } do
		make("Part", {
			Name = "SignNeon",
			Size = Vector3.new(edge[3], edge[4], 0.4),
			CFrame = CFrame.new(at(edge[1], signFront, SIGN_Y + edge[2])),
			Color = W.HotPink,
			Material = Enum.Material.Neon,
			CanCollide = false,
			CanQuery = false,
			Parent = folder,
		})
	end
	for _, side in { -1, 1 } do
		make("Part", {
			Name = "SignNeon",
			Size = Vector3.new(0.5, SIGN_H + 1.1, 0.4),
			CFrame = CFrame.new(at(side * (SIGN_W / 2 + 0.25), signFront, SIGN_Y)),
			Color = W.HotPink,
			Material = Enum.Material.Neon,
			CanCollide = false,
			CanQuery = false,
			Parent = folder,
		})
		-- Starburst bulbs at the sign's ends.
		ellipsoid({
			Name = "SignBulb",
			Size = Vector3.new(2.2, 2.2, 2.2),
			CFrame = CFrame.new(at(side * (SIGN_W / 2 + 2), signFront, SIGN_Y)),
			Color = W.Sunny,
			Material = Enum.Material.Neon,
			CanCollide = false,
			CanQuery = false,
			Parent = folder,
		})
	end
	-- A light truss over the pin deck (sunny beam on teal posts) lighting the pins.
	local header = make("Part", {
		Name = "BowlingHeader",
		Size = Vector3.new(outer * 2 + 2, 1, 1),
		CFrame = CFrame.new(at(0, deckFrom - 1, 10)),
		Color = W.Sunny,
		Parent = folder,
	})
	make("Part", {
		Name = "HeaderNeon",
		Size = Vector3.new(outer * 2 + 2, 0.3, 0.3),
		CFrame = CFrame.new(at(0, deckFrom - 1.6, 9.6)),
		Color = W.Mint,
		Material = Enum.Material.Neon,
		CanCollide = false,
		CanQuery = false,
		Parent = folder,
	})
	local light = Instance.new("SpotLight")
	light.Face = Enum.NormalId.Bottom
	light.Angle = 80
	light.Range = 20
	light.Brightness = 2.2
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
		local pin = makePin(pins, "Pin" .. i, cf, PIN_SCALE)
		pin:SetAttribute("Index", i)
	end
	-- A giant pin statue on the approach's back-left corner, on a sunny plinth.
	local statueAt = at(-(a.sizeX / 2 - 3.5), -8, 0)
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

	dress(folder, at, a, outer)
	local built: any = base
	built.lane = lane
	built.rollStart = CFrame.lookAt(at(0, -3, 0), at(0, laneL, 0))
	built.pinSpots = pinSpots
	built.pins = pins
	return built :: Built
end

return BowlingLane
