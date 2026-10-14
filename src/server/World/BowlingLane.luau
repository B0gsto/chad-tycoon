--!strict
--[[
	BowlingLane: the DUMBBELL BOWL arena out at sea (teleport-only; Modes.Bowling brings players here).
	Numbers live in Modes.BowlingRules (ARENA, LANE, PIN_SPOTS, PIN, BALL); the shell (floor,
	spawn pad, exit arch) comes from World.Arena.

	The dressing, parts only: a glossy honey-wood lane with board lines, aiming dots and red
	chevron arrows, a pale pin deck, steel gutters and capped dividers, a dark pit behind the
	pins with a glowing blue backstop and a bright pin deck, a navy back wall with three neon
	strips, side kickbacks, a lit "DUMBBELL BOWL" header over the pins, a giant pin statue by
	the approach and a raised ball-return track ending in a rack of three giant dumbbells.
	Around it (dress): a confetti carpet, a lounge with benches and a shoe rack, a roped-off
	"PRO LANE" with a giant decor dumbbell on its foul line, a scoreboard and lamp posts.

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
local PIN_SCALE = 1.45

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

-- A dumbbell lying across X with its centre at `centre` (plates `radius` studs), `scale`
-- times the rules' size (bigger ones are decor: "GiantDumbbell").
local function makeDumbbell(parent: Instance, centre: Vector3, plate: Color3, roller: boolean, scale: number?): Model
	local model = Instance.new("Model")
	local k = scale or 1
	model.Name = if roller then "BowlDumbbell" elseif k > 1 then "GiantDumbbell" else "RackDumbbell"
	local r = BowlingRules.BALL
	local b = { radius = r.radius * k, halfLength = r.halfLength * k }
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
			Size = Vector3.new(b.halfLength * 2 + 0.3 * k, 0.55 * k, 0.55 * k),
			CFrame = cf,
			Color = W.Chrome,
			Reflectance = 0.25,
		})
	)
	for _, side in { -1, 1 } do
		local x = side * (b.halfLength - 0.35 * k)
		make(
			"Part",
			props({
				Name = "Plate",
				Shape = Enum.PartType.Cylinder,
				Size = Vector3.new(0.7 * k, b.radius * 2, b.radius * 2),
				CFrame = cf * CFrame.new(x, 0, 0),
				Color = plate,
			})
		)
		make(
			"Part",
			props({
				Name = "Hub",
				Shape = Enum.PartType.Cylinder,
				Size = Vector3.new(0.8 * k, b.radius * 1.1, b.radius * 1.1),
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

-- The dressing beside the lane: a closed "PRO LANE" on the left (dim, roped off, a giant
-- dumbbell on its foul line), a confetti carpet, a lounge (benches, shoe rack) and a
-- scoreboard on the right and lamp posts down both edges.
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

	-- Neighbouring "PRO LANE" (left): narrower and dimmer (dark wood, no glow), its pins
	-- standing behind a velvet rope with a CLOSED sign, a giant dumbbell resting on its foul line.
	local nW, nG = 10, 1.5
	local nx = -(outer + 1 + nG + nW / 2)
	local nOuter = nx - nW / 2 - nG
	part({
		Name = "SideLane",
		Size = Vector3.new(nW, 0.2, laneL),
		CFrame = CFrame.new(at(nx, laneL / 2, 0.1)),
		Color = W.WoodDark,
		Material = Enum.Material.Wood,
		Reflectance = 0.06,
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
			Color = W.Slate,
			Material = Enum.Material.Metal,
		})
	end
	part({ Name = "SideDivider", Size = Vector3.new(1, 0.7, laneL), CFrame = CFrame.new(at(nOuter - 0.5, laneL / 2, 0.35)), Color = W.Teal })
	part({ Name = "SideKickback", Size = Vector3.new(1, 6, 22), CFrame = CFrame.new(at(nOuter - 0.5, laneL - 7, 3.7)), Color = W.Slate })
	part({
		Name = "SidePit",
		Size = Vector3.new(nW + nG * 2, 0.1, BowlingRules.PIT + 1),
		CFrame = CFrame.new(at(nx, laneL + BowlingRules.PIT / 2 + 0.5, -0.3)),
		Color = W.Basalt,
	})
	local decoPins = Instance.new("Folder")
	decoPins.Name = "SidePins"
	decoPins.Parent = folder
	local k = 0.75
	for i, spot in BowlingRules.PIN_SPOTS do
		local d = 70 + (spot.d - BowlingRules.PIN_SPOTS[1].d) * k
		makePin(decoPins, "SidePin" .. i, CFrame.new(at(nx + spot.x * k, d, 0.2)), PIN_SCALE * 0.7)
	end
	-- The giant dumbbell resting just past the pro lane's foul line (decor; the client rolls
	-- its own on the main lane).
	makeDumbbell(folder, at(nx, 3.2, 0.2 + BowlingRules.BALL.radius * 1.8), W.HotPink, false, 1.8)
	-- Velvet rope across the pro lane's approach: chrome stanchions, a red rope, a CLOSED sign.
	local ropeD, postX = -1.2, nW / 2 + 0.8
	for _, side in { -1, 1 } do
		part({
			Name = "RopePost",
			Shape = Enum.PartType.Cylinder,
			Size = Vector3.new(3.2, 0.45, 0.45),
			CFrame = CFrame.new(at(nx + side * postX, ropeD, 1.6)) * UPRIGHT,
			Color = W.Gold,
			Reflectance = 0.3,
		})
		ellipsoid({
			Name = "RopeKnob",
			Size = Vector3.new(0.75, 0.75, 0.75),
			CFrame = CFrame.new(at(nx + side * postX, ropeD, 3.3)),
			Color = W.Gold,
			Reflectance = 0.3,
			CanCollide = false,
			CanQuery = false,
			Parent = folder,
		})
	end
	deco({
		Name = "Rope",
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(postX * 2, 0.3, 0.3),
		CFrame = CFrame.new(at(nx, ropeD, 2.8)),
		Color = PIN_RED,
	})
	local closed = deco({
		Name = "ClosedSign",
		Size = Vector3.new(6.4, 2.2, 0.2),
		CFrame = CFrame.new(at(nx, ropeD - 0.15, 1.75)),
		Color = W.HotPink,
	})
	local closedGui = Instance.new("SurfaceGui")
	closedGui.Face = Enum.NormalId.Back
	closedGui.PixelsPerStud = 32
	closedGui.LightInfluence = 0
	closedGui.Parent = closed
	Common.label(closedGui, {
		Text = "PRO LANE",
		Font = Common.theme.Fonts.Display,
		TextColor3 = W.Sunny,
		Size = UDim2.fromScale(0.9, 0.4),
		Position = UDim2.fromScale(0.05, 0.06),
	})
	Common.label(closedGui, {
		Text = "CLOSED",
		Font = Common.theme.Fonts.Display,
		TextColor3 = W.White,
		Size = UDim2.fromScale(0.9, 0.48),
		Position = UDim2.fromScale(0.05, 0.47),
	})

	-- Confetti carpet (navy with bright scraps) over every bit of floor beside the lanes.
	local CARPET = Color3.fromRGB(34, 40, 92)
	local backD = laneL + BowlingRules.PIT + 1
	local frontD = -(L.foulFromEdge - 0.5)
	local carpets = {
		{ -half + 0.5, half - 0.5, frontD, 0 }, -- across the front, under the approaches
		{ outer + 1, half - 0.5, 0, backD }, -- right of the lane (lounge, ball return)
		{ -half + 0.5, nOuter - 1, 0, backD }, -- the left strip
	}
	for _, c in carpets do
		deco({
			Name = "Carpet",
			Size = Vector3.new(c[2] - c[1], 0.04, c[4] - c[3]),
			CFrame = CFrame.new(at((c[1] + c[2]) / 2, (c[3] + c[4]) / 2, 0.02)),
			Color = CARPET,
			Material = Enum.Material.Fabric,
		})
	end
	-- Scraps where nothing covers them: right lounge, the front corners, behind the approach.
	local zones = {
		{ outer + 5, half - 0.8, -12.5, 70, 46 },
		{ -half + 0.8, -outer - 1.2, frontD + 0.5, -0.6, 18 },
		{ -outer, outer, frontD + 0.5, -10.4, 8 },
		{ outer + 1.2, outer + 5, -12.5, -0.6, 4 },
		{ -half + 0.8, nOuter - 1.2, 1, 80, 8 },
	}
	local CONFETTI = { W.Sunny, W.HotPink, W.Mint, W.SkyBlue, W.Orange, W.White }
	local seed = 20261014
	local function rand(): number
		seed = (seed * 1103515245 + 12345) % 2147483648
		return seed / 2147483648
	end
	local n = 0
	for _, z in zones do
		for _ = 1, z[5] do
			n += 1
			local x = z[1] + rand() * (z[2] - z[1])
			local d = z[3] + rand() * (z[4] - z[3])
			local color = CONFETTI[n % #CONFETTI + 1]
			local cf = CFrame.new(at(x, d, 0.05)) * CFrame.Angles(0, rand() * math.pi, 0)
			if n % 3 == 0 then
				deco({
					Name = "Confetti",
					Shape = Enum.PartType.Cylinder,
					Size = Vector3.new(0.02, 0.8, 0.8),
					CFrame = cf * UPRIGHT,
					Color = color,
				})
			elseif n % 3 == 1 then
				deco({ Name = "Confetti", Size = Vector3.new(0.3, 0.02, 1.3), CFrame = cf, Color = color })
			else
				deco({ Name = "Confetti", Size = Vector3.new(0.65, 0.02, 0.65), CFrame = cf, Color = color })
			end
		end
	end

	-- Lounge (right): three bright benches facing the lane, a shoe rack with a marquee sign.
	local BENCH = { W.HotPink, W.Sunny, W.SkyBlue }
	local benchX, benchL = outer + 9, 8
	for i, color in BENCH do
		local d = 16 + (i - 1) * 12
		part({ Name = "BenchSeat", Size = Vector3.new(2.4, 0.5, benchL), CFrame = CFrame.new(at(benchX, d, 1.35)), Color = color })
		part({ Name = "BenchBack", Size = Vector3.new(0.5, 2.2, benchL), CFrame = CFrame.new(at(benchX + 1.2, d, 2.5)), Color = color })
		for _, e in { -1, 1 } do
			part({
				Name = "BenchLeg",
				Size = Vector3.new(2, 1.1, 0.4),
				CFrame = CFrame.new(at(benchX + 0.1, d + e * (benchL / 2 - 0.6), 0.55)),
				Color = W.Chrome,
				Material = Enum.Material.Metal,
			})
		end
	end
	local shoeX, shoeD = half - 1.6, 4
	part({ Name = "ShoeRack", Size = Vector3.new(0.5, 5, 7), CFrame = CFrame.new(at(shoeX + 0.9, shoeD, 2.5)), Color = W.Coral })
	local SHOES = { W.RedOrange, W.Blue, W.Mint }
	for s = 1, 3 do
		local y = 0.6 + (s - 1) * 1.6
		part({ Name = "ShoeShelf", Size = Vector3.new(2, 0.25, 7), CFrame = CFrame.new(at(shoeX, shoeD, y)), Color = W.Wood })
		for j = -1, 1 do
			deco({
				Name = "ShoePair",
				Size = Vector3.new(1.2, 0.55, 1.1),
				CFrame = CFrame.new(at(shoeX - 0.1, shoeD + j * 2.1, y + 0.4)),
				Color = SHOES[(s + j + 1) % #SHOES + 1],
			})
		end
	end
	local shoeSign = part({
		Name = "ShoeSign",
		Size = Vector3.new(0.4, 1.6, 6),
		CFrame = CFrame.new(at(shoeX + 0.7, shoeD, 5.9)),
		Color = W.Navy,
	})
	local shoeGui = Instance.new("SurfaceGui")
	shoeGui.Face = Enum.NormalId.Left
	shoeGui.PixelsPerStud = 32
	shoeGui.LightInfluence = 0
	shoeGui.Parent = shoeSign
	Common.label(shoeGui, {
		Text = "SHOES",
		Font = Common.theme.Fonts.Display,
		TextColor3 = W.Sunny,
		Size = UDim2.fromScale(0.9, 0.8),
		Position = UDim2.fromScale(0.05, 0.1),
	})
	for j = -2, 2 do
		ellipsoid({
			Name = "MarqueeBulb",
			Size = Vector3.new(0.5, 0.5, 0.5),
			CFrame = CFrame.new(at(shoeX + 0.4, shoeD + j * 1.4, 6.95)),
			Color = W.Sunny,
			Material = Enum.Material.Neon,
			CanCollide = false,
			CanQuery = false,
			Parent = folder,
		})
	end
	local bx0 = outer + 7

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
	local lamps = { { -1, 8 }, { -1, 40 }, { -1, 72 }, { 1, 10 }, { 1, 84 } }
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
		Color = W.Butter,
		Material = Enum.Material.SmoothPlastic,
		Reflectance = 0.15,
		CanCollide = false,
		CanQuery = false,
		Parent = folder,
	})
	-- Coral pin spots under the triangle (the pins stand on them).
	for _, spot in BowlingRules.PIN_SPOTS do
		make("Part", {
			Name = "PinSpot",
			Shape = Enum.PartType.Cylinder,
			Size = Vector3.new(0.02, 2.1, 2.1),
			CFrame = CFrame.new(at(spot.x, spot.d, laneTop + 0.03)) * UPRIGHT,
			Color = W.Coral,
			CanCollide = false,
			CanQuery = false,
			Parent = folder,
		})
	end

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
	-- The glowing backstop behind the pins: a blue light panel edged in sunny neon (the white
	-- pins pop against it), lighting the pin deck.
	local backstop = make("Part", {
		Name = "PinBackstop",
		Size = Vector3.new(outer * 2, 3.4, 0.3),
		CFrame = CFrame.new(at(0, wallD - 0.65, 1.7)),
		Color = W.SkyBlue,
		Material = Enum.Material.Neon,
		CanCollide = false,
		CanQuery = false,
		Parent = folder,
	})
	local deckLight = Instance.new("SurfaceLight")
	deckLight.Face = Enum.NormalId.Back
	deckLight.Range = 18
	deckLight.Angle = 70
	deckLight.Brightness = 2
	deckLight.Color = Color3.fromRGB(220, 240, 255)
	deckLight.Parent = backstop
	make("Part", {
		Name = "BackstopNeon",
		Size = Vector3.new(outer * 2 + 2, 0.45, 0.4),
		CFrame = CFrame.new(at(0, wallD - 0.75, 3.6)),
		Color = W.Sunny,
		Material = Enum.Material.Neon,
		CanCollide = false,
		CanQuery = false,
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
	light.Range = 26
	light.Brightness = 3.5
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

	-- Ball return: a teal rack with two chrome rails and three giant dumbbells on the right
	-- (just down the lane, clear of the exit pad in the +X, +Z corner), fed by a raised
	-- track that runs back from a coral hood by the pit.
	local rackX = outer + 3.5
	local rackD = 6
	local RACK_LEN = 10.5
	make("Part", {
		Name = "BallRack",
		Size = Vector3.new(3.6, 1.8, RACK_LEN),
		CFrame = CFrame.new(at(rackX, rackD, 0.9)),
		Color = W.Teal,
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
	local trackFrom, hoodD = rackD + RACK_LEN / 2, laneL - 5
	local trackL = hoodD - trackFrom
	make("Part", {
		Name = "ReturnTrack",
		Size = Vector3.new(3.2, 1.6, trackL),
		CFrame = CFrame.new(at(rackX, trackFrom + trackL / 2, 0.8)),
		Color = W.Teal,
		Parent = folder,
	})
	for _, side in { -1, 1 } do
		make("Part", {
			Name = "ReturnRail",
			Shape = Enum.PartType.Cylinder,
			Size = Vector3.new(trackL, 0.4, 0.4),
			CFrame = CFrame.new(at(rackX + side * railX, trackFrom + trackL / 2, 2)) * CFrame.Angles(0, math.pi / 2, 0),
			Color = W.Chrome,
			Material = Enum.Material.Metal,
			Reflectance = 0.3,
			Parent = folder,
		})
		make("Part", {
			Name = "ReturnNeon",
			Size = Vector3.new(0.15, 0.3, trackL),
			CFrame = CFrame.new(at(rackX + side * 1.65, trackFrom + trackL / 2, 1.1)),
			Color = W.Mint,
			Material = Enum.Material.Neon,
			CanCollide = false,
			CanQuery = false,
			Parent = folder,
		})
	end
	make("Part", {
		Name = "ReturnHood",
		Size = Vector3.new(4.4, 3.2, 6),
		CFrame = CFrame.new(at(rackX, hoodD + 2, 1.6)),
		Color = W.Coral,
		Parent = folder,
	})
	make("Part", {
		Name = "ReturnHoodTop",
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(6, 4.4, 4.4),
		CFrame = CFrame.new(at(rackX, hoodD + 2, 3.2)) * CFrame.Angles(0, math.pi / 2, 0),
		Color = W.Coral,
		Parent = folder,
	})
	make("Part", {
		Name = "ReturnHoodMouth",
		Size = Vector3.new(3, 2.4, 0.1),
		CFrame = CFrame.new(at(rackX, hoodD - 1.02, 1.6)),
		Color = W.Ink,
		CanCollide = false,
		CanQuery = false,
		Parent = folder,
	})
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
