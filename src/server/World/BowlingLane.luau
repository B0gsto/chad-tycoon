--!strict
--[[
	BowlingLane: the DUMBBELL BOWL arena out at sea (teleport-only; Modes.Bowling brings players here).
	Numbers live in Modes.BowlingRules (ARENA, LANE, PIN_SPOTS, PIN, BALL); the shell (floor,
	spawn pad, exit arch) comes from World.Arena.

	The deck has two parts: the alley (the lane and its dressing) and, behind the lane's
	approach at the deck's +Z end (LOBBY_D studs), the lobby lounge where every run starts
	(docs/minigames.md, "Lobby first, then the game").

	The dressing, parts only: a glossy honey-wood lane with board lines, aiming dots and red
	chevron arrows, a pale pin deck, steel gutters and capped dividers, a dark pit behind the
	pins with a glowing blue backstop and a bright pin deck, a navy back wall with three neon
	strips, side kickbacks, a lit "DUMBBELL BOWL" header over the pins, a giant pin statue by
	the approach and a raised ball-return track ending in a rack of three giant dumbbells.
	Around it (dress): a confetti carpet, a lounge with benches and a shoe rack, a roped-off
	"PRO LANE" with a giant decor dumbbell on its foul line, a scoreboard and lamp posts.

	The lobby (lobby): a coral knee wall between it and the alley with a gap under a lit
	"DUMBBELL BOWL" arch, the glowing START pad ("StartPad") in that gap at the head of the
	approach, a red runner from the spawn pad (World.Arena's "ArenaSpawn", now the lobby
	spawn) to it, a HOW TO PLAY board (aim, power, knock pins) on the left, the YOUR BEST
	board (SurfaceGui "BestBoard" with TextLabels Best, Clears and Reward the client fills)
	on the right, a two-tier gym rack of four dumbbells to choose from (Models "BallChoice1"
	.."BallChoice4", attributes Choice = 1..4, Color and Label, each with a neon "Glow" strip
	the client can light), sofas round a table, a bench, plants, lamps, a railing and the
	EXIT arch in the back right corner.

	Around the deck (sea): its own ocean (the hub's ends ~3000 studs out), shallows and foam
	under the deck, buoys, two sandbars and palm islands on the horizon.

	The ten pins (white with two red neck stripes; Models "Pin1".."Pin10" with attribute
	Index, pivot at the base centre) stand in `pins` for everyone to see. During a run
	Fx.Bowling hides them on that client and animates its own clones, so several players can
	bowl here at once without sharing pins. The return rack's first dumbbell (attribute
	Roller) is the one Fx.Bowling clones to roll.

	build() -> Built: everything World.Arena.Base has ({ folder, floor, spawn, exit,
	exitRadius, center, top }; `spawn` is the play spot, the same as rollStart) plus
	lane        the lane slab ("BowlingLane", runs -Z from the foul line)
	rollStart   feet CFrame 3 studs behind the foul line, looking down the lane (-Z)
	pinSpots    10 CFrames (pin base centres) in the classic triangle at the far end, head pin first
	pins        Folder "Pins" with the ten pin Models
	lobbySpawn  feet CFrame on the lobby's spawn pad, looking down the runner and the lane
	startPad    the "StartPad" disc; feet within startRadius of it in phase lobby = Begin
	startRadius the pad's radius
	board       the "BestBoard" SurfaceGui (TextLabels Best, Clears, Reward; Frame RewardPill)
	ballRack    the four "BallChoice" Models, in Choice order
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
	lobbySpawn: CFrame,
	startPad: BasePart,
	startRadius: number,
	board: SurfaceGui,
	ballRack: { Model },
}

-- The lobby's depth at the deck's +Z end (BowlingRules.ARENA.sizeZ includes it); the foul
-- line sits LANE.foulFromEdge in front of it.
local LOBBY_D = 40
-- The START pad's radius (feet within it begin a game).
local START_RADIUS = 3.5
-- The dumbbells on the lobby rack: plate colour and the name the HUD can show.
local CHOICES: { { color: Color3, label: string } } = {
	{ color = W.RedOrange, label = "RED" },
	{ color = W.Blue, label = "BLUE" },
	{ color = W.Mint, label = "MINT" },
	{ color = W.HotPink, label = "PINK" },
}
-- The navy confetti carpet (alley and lobby).
local CARPET = Color3.fromRGB(34, 40, 92)
local CONFETTI = { W.Sunny, W.HotPink, W.Mint, W.SkyBlue, W.Orange, W.White }
local OCEAN_TOP = -1.2
local OCEAN_TILE = 2048
local CYLINDER = Enum.PartType.Cylinder
local BALL_SHAPE = Enum.PartType.Ball

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

-- SurfaceGui drawing (pixel coordinates; boards use PixelsPerStud so a pixel is fixed) -------

local function surfaceGui(p: BasePart, face: Enum.NormalId, pixelsPerStud: number): SurfaceGui
	local gui = Instance.new("SurfaceGui")
	gui.Face = face
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = pixelsPerStud
	gui.LightInfluence = 0
	gui.Brightness = 1.4
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Parent = p
	return gui
end

local function outline(obj: GuiObject, color: Color3, thickness: number)
	local s = Instance.new("UIStroke")
	s.Color = color
	s.Thickness = thickness
	s.Parent = obj
end

local function rounded(obj: GuiObject, radius: number)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(radius, 0)
	c.Parent = obj
end

-- A filled box at (x, y) px, `w` x `h`; `corner` rounds it (0.5 = pill or circle).
local function rect(parent: Instance, color: Color3, x: number, y: number, w: number, h: number, corner: number?): Frame
	local f = Instance.new("Frame")
	f.BorderSizePixel = 0
	f.BackgroundColor3 = color
	f.Position = UDim2.fromOffset(x, y)
	f.Size = UDim2.fromOffset(w, h)
	if corner then
		rounded(f, corner)
	end
	f.Parent = parent
	return f
end

-- A round-capped stroke from (x1, y1) to (x2, y2).
local function stick(parent: Instance, x1: number, y1: number, x2: number, y2: number, thick: number, color: Color3): Frame
	local dx, dy = x2 - x1, y2 - y1
	local f = Instance.new("Frame")
	f.BorderSizePixel = 0
	f.BackgroundColor3 = color
	f.AnchorPoint = Vector2.new(0.5, 0.5)
	f.Position = UDim2.fromOffset((x1 + x2) / 2, (y1 + y2) / 2)
	f.Size = UDim2.fromOffset(thick, math.sqrt(dx * dx + dy * dy) + thick * 0.6)
	f.Rotation = math.deg(math.atan2(dx, -dy))
	rounded(f, 0.5)
	f.Parent = parent
	return f
end

local function arrow(parent: Instance, x1: number, y1: number, x2: number, y2: number, thick: number, color: Color3, head: number)
	stick(parent, x1, y1, x2, y2, thick, color)
	local back = math.atan2(y1 - y2, x1 - x2)
	for _, side in { -1, 1 } do
		local a = back + side * 0.6
		stick(parent, x2, y2, x2 + math.cos(a) * head, y2 + math.sin(a) * head, thick, color)
	end
end

local function words(
	parent: Instance,
	text: string,
	x: number,
	y: number,
	w: number,
	h: number,
	color: Color3,
	strokeColor: Color3?,
	strokeThick: number?
): TextLabel
	local l = Instance.new("TextLabel")
	l.BackgroundTransparency = 1
	l.TextScaled = true
	l.Font = Common.theme.Fonts.Display
	l.TextColor3 = color
	l.Text = text
	l.Position = UDim2.fromOffset(x, y)
	l.Size = UDim2.fromOffset(w, h)
	l.ZIndex = 3
	if strokeColor then
		outline(l, strokeColor, strokeThick or 2)
	end
	l.Parent = parent
	return l
end

-- A little bowling pin (white pill, red neck stripe) centred at (x, y), tipped `rotation` degrees.
local function pinIcon(parent: Instance, x: number, y: number, rotation: number)
	local pin = rect(parent, W.White, x - 8, y - 20, 16, 40, 0.5)
	pin.Rotation = rotation
	outline(pin, W.Ink, 2)
	rect(pin, PIN_RED, 0, 11, 16, 4)
end

-- The three HOW TO PLAY steps' pictures, each drawn in a 156 x 120 px panel.
local function drawAim(p: Frame)
	rect(p, W.Steel, 45, 6, 66, 108, 0.06)
	rect(p, W.Honey, 53, 6, 50, 108)
	for _, spot in { { 78, 26 }, { 70, 15 }, { 86, 15 } } do
		local dot = rect(p, W.White, spot[1] - 5, spot[2] - 5, 10, 10, 0.5)
		outline(dot, W.Ink, 1.5)
	end
	local target = rect(p, W.White, 58, 2, 40, 36, 0.5)
	target.BackgroundTransparency = 1
	outline(target, W.RedOrange, 3)
	arrow(p, 72, 92, 82, 44, 6, W.RedOrange, 14)
	-- The dumbbell at the foul line and "slide" arrows either side.
	rect(p, W.Chrome, 62, 99, 26, 5)
	rect(p, W.RedOrange, 56, 93, 9, 17, 0.3)
	rect(p, W.RedOrange, 85, 93, 9, 17, 0.3)
	arrow(p, 34, 101, 12, 101, 5, W.Ink, 9)
	arrow(p, 122, 101, 144, 101, 5, W.Ink, 9)
end

local function drawPower(p: Frame)
	local meter = rect(p, W.Ink, 22, 6, 36, 108, 0.3)
	local fill = rect(meter, W.White, 6, 6, 24, 96, 0.3)
	local g = Instance.new("UIGradient")
	g.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, W.Mint),
		ColorSequenceKeypoint.new(0.5, W.Sunny),
		ColorSequenceKeypoint.new(1, W.RedOrange),
	})
	g.Rotation = -90
	g.Parent = fill
	local marker = rect(p, W.White, 14, 24, 52, 7, 0.5)
	outline(marker, W.Ink, 2)
	arrow(p, 94, 28, 72, 28, 5, W.Ink, 10)
	-- A lightning bolt.
	local bolt = { { 132, 8 }, { 106, 60 }, { 132, 58 }, { 108, 112 } }
	for i = 1, #bolt - 1 do
		stick(p, bolt[i][1], bolt[i][2], bolt[i + 1][1], bolt[i + 1][2], 11, W.Ink)
	end
	for i = 1, #bolt - 1 do
		stick(p, bolt[i][1], bolt[i][2], bolt[i + 1][1], bolt[i + 1][2], 6, W.Sunny)
	end
end

local function drawKnock(p: Frame)
	-- A burst behind the pins.
	for _, r in { 0, 45 } do
		local star = rect(p, W.Sunny, 120 - 26, 62 - 26, 52, 52, 0.12)
		star.Rotation = r
	end
	pinIcon(p, 106, 66, -32)
	pinIcon(p, 128, 48, 28)
	pinIcon(p, 136, 92, 74)
	-- The dumbbell flying in, with speed lines.
	rect(p, W.Chrome, 34, 82, 30, 8)
	rect(p, W.RedOrange, 24, 68, 13, 36, 0.3)
	rect(p, W.RedOrange, 61, 68, 13, 36, 0.3)
	for i, y in { 72, 86, 100 } do
		stick(p, 4 + (i % 2) * 4, y, 18, y, 4, W.Ink)
	end
end

-- The sea -------------------------------------------------------------------------------------

local function quietPart(parent: Instance, props: { [string]: any }): BasePart
	props.CanCollide = false
	props.CanQuery = false
	props.CanTouch = false
	props.Parent = parent
	return make("Part", props)
end

local function disc(parent: Instance, name: string, radius: number, topY: number, thick: number, color: Color3, x: number, z: number)
	quietPart(parent, {
		Name = name,
		Shape = CYLINDER,
		Size = Vector3.new(thick, radius * 2, radius * 2),
		CFrame = CFrame.new(x, topY - thick / 2, z) * UPRIGHT,
		Color = color,
		CastShadow = false,
	})
end

-- A rounded-end strip (a stadium) of water `width` across, its straight part `length` long on Z.
local function stadium(parent: Instance, name: string, cx: number, cz: number, width: number, length: number, topY: number, color: Color3)
	quietPart(parent, {
		Name = name,
		Size = Vector3.new(width, 0.2, length),
		CFrame = CFrame.new(cx, topY - 0.1, cz),
		Color = color,
		CastShadow = false,
	})
	for _, side in { -1, 1 } do
		disc(parent, name, width / 2, topY, 0.2, color, cx, cz + side * length / 2)
	end
end

-- A low-part palm (three trunk rings, a crown, five fronds, two coconuts).
local function palm(parent: Instance, base: CFrame, height: number, lean: number)
	local s = height / 16
	local seg = height / 3
	local frame = base
	for i = 1, 3 do
		frame = frame * CFrame.Angles(lean / 3, 0, 0)
		local d = (1.9 - 0.45 * (i - 1)) * s
		quietPart(parent, {
			Name = "PalmTrunk",
			Shape = CYLINDER,
			Size = Vector3.new(seg + 0.3 * s, d, d),
			CFrame = frame * CFrame.new(0, seg / 2, 0) * UPRIGHT,
			Color = if i % 2 == 0 then W.WoodDark else W.Wood,
		})
		frame = frame * CFrame.new(0, seg, 0)
	end
	local crown = CFrame.new(frame.Position)
	quietPart(parent, { Name = "PalmCrown", Shape = BALL_SHAPE, Size = Vector3.one * 2.2 * s, CFrame = crown, Color = W.GrassDark })
	for k = 1, 2 do
		quietPart(parent, {
			Name = "Coconut",
			Shape = BALL_SHAPE,
			Size = Vector3.one * 1.1 * s,
			CFrame = crown * CFrame.Angles(0, k * 2.6, 0) * CFrame.new(0, -0.8 * s, -0.75 * s),
			Color = W.WoodDark,
		})
	end
	for i = 1, 5 do
		local length = 6.4 * s
		local f = crown * CFrame.Angles(0, (i + 0.3) * 2 * math.pi / 5, 0) * CFrame.Angles(-0.32, 0, 0)
		quietPart(parent, {
			Name = "PalmFrond",
			Size = Vector3.new(2.1 * s, 0.35 * s, length),
			CFrame = f * CFrame.new(0, 0, -length / 2),
			Color = if i % 2 == 0 then W.Grass else W.GrassDark,
		})
	end
end

-- The arena's own sea: ocean tiles to the fog, shallows and foam under the deck (its pontoons
-- stand in them), three buoys, two sandbars and palm islands on the horizon.
local function sea(folder: Instance, a: { [string]: number })
	local root = Instance.new("Folder")
	root.Name = "Sea"
	root.Parent = folder
	for ix = -1, 1 do
		for iz = -1, 1 do
			quietPart(root, {
				Name = "Ocean",
				Size = Vector3.new(OCEAN_TILE, 2, OCEAN_TILE),
				CFrame = CFrame.new(a.x + ix * OCEAN_TILE, OCEAN_TOP - 1, a.z + iz * OCEAN_TILE),
				Color = W.Ocean,
				Reflectance = 0.05,
				CastShadow = false,
			})
		end
	end
	local width = a.sizeX + 44
	stadium(root, "Foam", a.x, a.z, width + 5, a.sizeZ, OCEAN_TOP + 0.08, W.White)
	stadium(root, "Shallows", a.x, a.z, width, a.sizeZ, OCEAN_TOP + 0.15, W.Shallows)

	for i, b in { { -46, -40 }, { 44, 30 }, { -40, 72 } } do
		local x, z = a.x + b[1], a.z + b[2]
		quietPart(root, {
			Name = "BuoyBody",
			Shape = CYLINDER,
			Size = Vector3.new(3.2, 2.2, 2.2),
			CFrame = CFrame.new(x, OCEAN_TOP + 1, z) * UPRIGHT,
			Color = if i % 2 == 0 then W.Sunny else W.Coral,
		})
		quietPart(root, {
			Name = "BuoyBand",
			Shape = CYLINDER,
			Size = Vector3.new(0.7, 2.35, 2.35),
			CFrame = CFrame.new(x, OCEAN_TOP + 1.6, z) * UPRIGHT,
			Color = W.White,
		})
		quietPart(root, {
			Name = "BuoyLight",
			Shape = BALL_SHAPE,
			Size = Vector3.one * 1.2,
			CFrame = CFrame.new(x, OCEAN_TOP + 3.1, z),
			Color = W.Sunny,
			Material = Enum.Material.Neon,
		})
	end

	-- Sandbars close by: { angle (deg, x = cos, z = sin), distance, radius }.
	for i, bar in { { 232, 175, 12 }, { 318, 215, 9 } } do
		local ang = math.rad(bar[1])
		local x, z = a.x + math.cos(ang) * bar[2], a.z + math.sin(ang) * bar[2]
		disc(root, "SandbarShallows", bar[3] + 9, OCEAN_TOP + 0.15, 0.2, W.Shallows, x, z)
		disc(root, "Sandbar", bar[3], 0.3, 1.5, W.Sand, x, z)
		palm(root, CFrame.new(x + 2, 0.3, z - 1) * CFrame.Angles(0, ang + i, 0), 13 + i * 2, 0.45)
	end

	-- Palm islands on the horizon (Hub's farIsland look, fewer parts).
	local islands = { { 250, 520, 48 }, { 292, 780, 60 }, { 205, 690, 40 }, { 338, 610, 36 }, { 110, 650, 52 }, { 32, 840, 44 } }
	for n, isle in islands do
		local ang = math.rad(isle[1])
		local r = isle[3]
		local x, z = a.x + math.cos(ang) * isle[2], a.z + math.sin(ang) * isle[2]
		disc(root, "IsleShallows", r + 18, OCEAN_TOP + 0.15, 0.2, W.Shallows, x, z)
		disc(root, "IsleSand", r, 1.4, 5, W.Sand, x, z)
		disc(root, "IsleHill", r * 0.6, 3.4, 3, W.Grass, x, z)
		disc(root, "IsleHillTop", r * 0.3, 5.4, 3, W.GrassDark, x, z)
		local spots = { { 0.8, 0.5, 1.4 }, { 0.45, 2.6, 3.4 }, { 0.15, 4.4, 5.4 } }
		for i = 1, if r >= 45 then 3 else 2 do
			local spot = spots[i]
			local s = ang + spot[2] + n
			palm(
				root,
				CFrame.new(x + math.cos(s) * r * spot[1], spot[3], z + math.sin(s) * r * spot[1]) * CFrame.Angles(0, s + i, 0),
				22 + ((n + i) % 3) * 4,
				0.22 + 0.08 * i
			)
		end
	end
end

-- The lobby ------------------------------------------------------------------------------------

type Lobby = { startPad: BasePart, board: SurfaceGui, ballRack: { Model } }

-- The lounge behind the approach (lane space: d from -LANE.foulFromEdge back to the +Z edge).
local function lobby(folder: Instance, at: At, a: { [string]: number }): Lobby
	local L = BowlingRules.LANE
	local half = a.sizeX / 2
	local railD = -L.foulFromEdge -- the knee wall between the lobby and the alley
	local edgeD = railD - LOBBY_D -- the deck's +Z edge
	local spawnD = edgeD + 6 -- World.Arena's spawn pad (6 in from the +Z edge)
	local padD = railD - 4
	local font = Common.theme.Fonts.Display
	local function part(props: { [string]: any }): BasePart
		props.Parent = props.Parent or folder
		return make("Part", props)
	end
	local function deco(props: { [string]: any }): BasePart
		props.CanCollide = false
		props.CanQuery = false
		props.CanTouch = false
		return part(props)
	end
	local function upright(x: number, d: number, y0: number, y1: number, dia: number, color: Color3, name: string): BasePart
		return part({
			Name = name,
			Shape = CYLINDER,
			Size = Vector3.new(y1 - y0, dia, dia),
			CFrame = CFrame.new(at(x, d, (y0 + y1) / 2)) * UPRIGHT,
			Color = color,
		})
	end
	local function globe(pos: Vector3, dia: number, color: Color3, name: string, neon: boolean?): BasePart
		return deco({
			Name = name,
			Shape = BALL_SHAPE,
			Size = Vector3.one * dia,
			CFrame = CFrame.new(pos),
			Color = color,
			Material = if neon then Enum.Material.Neon else Enum.Material.SmoothPlastic,
		})
	end

	-- Floor: the navy confetti carpet and a red runner from the spawn pad to the START pad,
	-- with sunny chevrons pointing the way.
	deco({
		Name = "LobbyCarpet",
		Size = Vector3.new(a.sizeX - 1, 0.04, LOBBY_D),
		CFrame = CFrame.new(at(0, (edgeD + 0.5 + railD + 0.5) / 2, 0.02)),
		Color = CARPET,
		Material = Enum.Material.Fabric,
	})
	local runFrom, runTo = spawnD + 3.5, padD - 4.5
	deco({
		Name = "Runner",
		Size = Vector3.new(6, 0.03, runTo - runFrom),
		CFrame = CFrame.new(at(0, (runFrom + runTo) / 2, 0.06)),
		Color = W.RedOrange,
		Material = Enum.Material.Fabric,
	})
	for _, side in { -1, 1 } do
		deco({
			Name = "RunnerEdge",
			Size = Vector3.new(0.45, 0.035, runTo - runFrom),
			CFrame = CFrame.new(at(side * 3.2, (runFrom + runTo) / 2, 0.065)),
			Color = W.Sunny,
		})
	end
	local ARM, TILT = 2.6, math.rad(42)
	for _, tipD in { runTo - 3.5, runTo - 7.5, runTo - 11.5 } do
		for _, side in { -1, 1 } do
			deco({
				Name = "RunnerArrow",
				Size = Vector3.new(0.7, 0.04, ARM),
				CFrame = CFrame.new(at(side * math.sin(TILT) * ARM / 2, tipD - math.cos(TILT) * ARM / 2, 0.09))
					* CFrame.Angles(0, side * TILT, 0),
				Color = W.Sunny,
			})
		end
	end
	-- Confetti scraps either side of the runner.
	local seed = 20261015
	local function rand(): number
		seed = (seed * 1103515245 + 12345) % 2147483648
		return seed / 2147483648
	end
	local n = 0
	for _, z in { { -half + 0.8, -4.2, edgeD + 1, railD - 1, 16 }, { 4.2, half - 0.8, edgeD + 1, railD - 1, 16 } } do
		for _ = 1, z[5] do
			n += 1
			local cf = CFrame.new(at(z[1] + rand() * (z[2] - z[1]), z[3] + rand() * (z[4] - z[3]), 0.05))
				* CFrame.Angles(0, rand() * math.pi, 0)
			local color = CONFETTI[n % #CONFETTI + 1]
			if n % 2 == 0 then
				deco({ Name = "Confetti", Size = Vector3.new(0.3, 0.02, 1.3), CFrame = cf, Color = color })
			else
				deco({ Name = "Confetti", Size = Vector3.new(0.65, 0.02, 0.65), CFrame = cf, Color = color })
			end
		end
	end

	-- The knee wall (coral, sunny cap like the kickbacks) with a gap at the START pad.
	local gap = 7
	local wallL = half - 0.4 - gap
	for _, side in { -1, 1 } do
		local cx = side * (gap + wallL / 2)
		part({ Name = "LobbyWall", Size = Vector3.new(wallL, 2.2, 0.8), CFrame = CFrame.new(at(cx, railD, 1.1)), Color = W.Coral })
		part({
			Name = "LobbyWallCap",
			Size = Vector3.new(wallL + 0.2, 0.35, 1.2),
			CFrame = CFrame.new(at(cx, railD, 2.375)),
			Color = W.Sunny,
		})
		upright(side * (gap + 0.3), railD, 0, 3, 0.9, W.Teal, "GapPost")
		globe(at(side * (gap + 0.3), railD, 3.3), 1.1, W.Sunny, "GapPostCap", true)
	end

	-- The title arch over the gap: teal pillars, a navy board with a hot-pink neon frame.
	local SIGN_W, SIGN_H, SIGN_Y = 30, 7, 17.5
	for _, side in { -1, 1 } do
		upright(side * 9, railD, 0, SIGN_Y - SIGN_H / 2, 1.8, W.Teal, "ArchPillar")
		upright(side * 9, railD, 0, 0.8, 2.8, W.Sunny, "ArchFoot")
	end
	local sign = part({
		Name = "LobbySign",
		Size = Vector3.new(SIGN_W, SIGN_H, 0.8),
		CFrame = CFrame.new(at(0, railD, SIGN_Y)),
		Color = W.Navy,
	})
	local signGui = Instance.new("SurfaceGui")
	signGui.Face = Enum.NormalId.Back
	signGui.PixelsPerStud = 24
	signGui.LightInfluence = 0
	signGui.Brightness = 2
	signGui.Parent = sign
	local title = Common.label(signGui, {
		Text = "DUMBBELL BOWL",
		Font = font,
		TextColor3 = W.White,
		Size = UDim2.fromScale(0.94, 0.62),
		Position = UDim2.fromScale(0.03, 0.05),
	})
	local glow = title:FindFirstChildOfClass("UIStroke") or Instance.new("UIStroke")
	glow.Color = W.HotPink
	glow.Thickness = 6
	glow.Parent = title
	Common.label(signGui, {
		Text = "STEP ON THE GLOWING PAD TO PLAY!",
		Font = font,
		TextColor3 = W.Sunny,
		Size = UDim2.fromScale(0.8, 0.24),
		Position = UDim2.fromScale(0.1, 0.7),
	})
	local signFront = railD - 0.45
	for _, edge in { { 0, SIGN_H / 2 + 0.3, SIGN_W + 1, 0.5 }, { 0, -SIGN_H / 2 - 0.3, SIGN_W + 1, 0.5 } } do
		deco({
			Name = "SignNeon",
			Size = Vector3.new(edge[3], edge[4], 0.4),
			CFrame = CFrame.new(at(edge[1], signFront, SIGN_Y + edge[2])),
			Color = W.HotPink,
			Material = Enum.Material.Neon,
		})
	end
	for _, side in { -1, 1 } do
		deco({
			Name = "SignNeon",
			Size = Vector3.new(0.5, SIGN_H + 1.1, 0.4),
			CFrame = CFrame.new(at(side * (SIGN_W / 2 + 0.25), signFront, SIGN_Y)),
			Color = W.HotPink,
			Material = Enum.Material.Neon,
		})
		globe(at(side * (SIGN_W / 2 + 2), signFront, SIGN_Y), 2.2, W.Sunny, "SignBulb", true)
	end

	-- The START pad: a mint glow disc on a sunny ring, lighting the gap.
	deco({
		Name = "StartPadRing",
		Shape = CYLINDER,
		Size = Vector3.new(0.2, START_RADIUS * 2 + 2, START_RADIUS * 2 + 2),
		CFrame = CFrame.new(at(0, padD, 0.1)) * UPRIGHT,
		Color = W.Sunny,
	})
	local startPad = make("Part", {
		Name = "StartPad",
		Shape = CYLINDER,
		Size = Vector3.new(0.3, START_RADIUS * 2, START_RADIUS * 2),
		CFrame = CFrame.new(at(0, padD, 0.15)) * UPRIGHT,
		Color = W.Mint,
		Material = Enum.Material.Neon,
		CanCollide = false,
		CanTouch = false,
		Parent = folder,
	})
	local padLight = Instance.new("PointLight")
	padLight.Color = W.Mint
	padLight.Range = 14
	padLight.Brightness = 1.6
	padLight.Parent = startPad

	-- A board on two teal posts at lane spot (x, d), turned to face a point behind the spawn
	-- (its Back face is the front): navy, `accent` trim and three bulbs on top.
	local function standBoard(name: string, x: number, d: number, w: number, h: number, accent: Color3): BasePart
		local cy = 2.6 + h / 2
		local p = at(x, d, cy)
		local cf = CFrame.lookAt(p, p + (p - at(0, edgeD - 8, cy)))
		local panel = part({ Name = name, Size = Vector3.new(w, h, 0.6), CFrame = cf, Color = W.Navy })
		for _, s in { -1, 1 } do
			deco({
				Name = "BoardTrim",
				Size = Vector3.new(w + 0.9, 0.45, 0.8),
				CFrame = cf * CFrame.new(0, s * (h / 2 + 0.22), 0),
				Color = accent,
			})
			deco({
				Name = "BoardTrim",
				Size = Vector3.new(0.45, h, 0.8),
				CFrame = cf * CFrame.new(s * (w / 2 + 0.22), 0, 0),
				Color = accent,
			})
			part({
				Name = "BoardPost",
				Shape = CYLINDER,
				Size = Vector3.new(cy, 0.8, 0.8),
				CFrame = cf * CFrame.new(s * (w / 2 - 2), -cy / 2, -0.7) * UPRIGHT,
				Color = W.Teal,
			})
		end
		for k = -1, 1 do
			globe((cf * CFrame.new(k * w / 3, h / 2 + 0.95, 0)).Position, 1, W.Sunny, "BoardBulb", true)
		end
		return panel
	end

	-- HOW TO PLAY (left): three illustrated steps.
	local howW, howH, PPS = 18, 10.5, 32
	local how = standBoard("HowToPlayBoard", -18, -38, howW, howH, W.Sunny)
	local howGui = surfaceGui(how, Enum.NormalId.Back, PPS)
	howGui.Name = "HowToPlay"
	words(howGui, "HOW TO PLAY", 0, 6, howW * PPS, 50, W.White, W.HotPink, 4)
	local steps: { { n: string, title: string, hint: string, color: Color3, draw: (Frame) -> () } } = {
		{ n = "1", title = "AIM", hint = "PICK YOUR LINE", color = W.Blue, draw = drawAim },
		{ n = "2", title = "POWER", hint = "SET YOUR SPEED", color = W.Orange, draw = drawPower },
		{ n = "3", title = "KNOCK PINS", hint = "STRIKE = BIG SCORE", color = W.HotPink, draw = drawKnock },
	}
	for i, step in steps do
		local card = rect(howGui, step.color, 15 + (i - 1) * 187, 62, 172, 222, 0.08)
		outline(card, W.White, 3)
		local badge = rect(card, W.White, 8, 7, 34, 34, 0.5)
		words(badge, step.n, 0, 2, 34, 30, step.color)
		words(card, step.title, 46, 7, 120, 34, W.White, W.Ink, 2.5)
		local pic = rect(card, W.Cream, 8, 46, 156, 120, 0.08)
		pic.ClipsDescendants = true
		step.draw(pic)
		words(card, step.hint, 8, 172, 156, 40, W.White, W.Ink, 2)
	end
	words(
		howGui,
		"SCORE " .. BowlingRules.PASS_SCORE .. "+ IN " .. BowlingRules.FRAMES .. " FRAMES TO WIN!",
		20,
		292,
		howW * PPS - 40,
		36,
		W.Sunny,
		W.Ink,
		2
	)

	-- YOUR BEST (right): the client fills Best, Clears and Reward (and may recolour RewardPill).
	local bestW, bestH = 14, 10
	local bestPanel = standBoard("BestBoardPanel", 18, -38, bestW, bestH, W.Mint)
	local board = surfaceGui(bestPanel, Enum.NormalId.Back, PPS)
	board.Name = "BestBoard"
	local bw = bestW * PPS
	words(board, "YOUR BEST", 0, 8, bw, 54, W.Sunny, W.Ink, 3)
	local screen = rect(board, W.Ink, 24, 68, bw - 48, 150, 0.1)
	outline(screen, W.Mint, 3)
	local best = words(board, "0", 24, 74, bw - 48, 108, W.White, W.HotPink, 4)
	best.Name = "Best"
	words(board, "POINTS", 24, 184, bw - 48, 28, W.Mint)
	local clears = words(board, "CLEARS: 0", 24, 226, bw - 48, 34, W.White, W.Ink, 2)
	clears.Name = "Clears"
	local pill = rect(board, W.RedOrange, 40, 268, bw - 80, 42, 0.5)
	pill.Name = "RewardPill"
	outline(pill, W.White, 2)
	local reward = words(board, "FIRST WIN PAYS BIG!", 54, 272, bw - 108, 34, W.White, W.Ink, 2)
	reward.Name = "Reward"

	-- The ball rack (right, by the gap): a two-tier gym rack (teal shelves, coral sides,
	-- chrome lips) with the four dumbbells to choose from and a sign on chrome posts.
	local RX, RD = 14, -22
	local tiers = { { d = RD + 1.5, top = 4.4 }, { d = RD - 1.5, top = 1.4 } } -- back high, front low
	for _, t in tiers do
		part({
			Name = "RackRiser",
			Size = Vector3.new(11.2, t.top - 0.5, 3),
			CFrame = CFrame.new(at(RX, t.d, (t.top - 0.5) / 2)),
			Color = W.TealDeep,
		})
		part({ Name = "RackShelf", Size = Vector3.new(11.2, 0.5, 3), CFrame = CFrame.new(at(RX, t.d, t.top - 0.25)), Color = W.Teal })
		part({
			Name = "RackLip",
			Shape = CYLINDER,
			Size = Vector3.new(11.6, 0.4, 0.4),
			CFrame = CFrame.new(at(RX, t.d - 1.4, t.top + 0.15)),
			Color = W.Chrome,
			Material = Enum.Material.Metal,
			Reflectance = 0.3,
		})
	end
	for _, side in { -1, 1 } do
		part({ Name = "RackSide", Size = Vector3.new(0.7, 5.6, 6.4), CFrame = CFrame.new(at(RX + side * 5.95, RD, 2.8)), Color = W.Coral })
		upright(RX + side * 5.95, RD + 1.6, 5.6, 9.4, 0.5, W.Chrome, "RackSignPost")
	end
	local rackSign =
		part({ Name = "RackSign", Size = Vector3.new(12.6, 2.4, 0.4), CFrame = CFrame.new(at(RX, RD + 1.6, 9.5)), Color = W.Navy })
	deco({
		Name = "RackSignNeon",
		Size = Vector3.new(12.6, 0.3, 0.3),
		CFrame = CFrame.new(at(RX, RD + 1.4, 8.15)),
		Color = W.Mint,
		Material = Enum.Material.Neon,
	})
	local rackGui = surfaceGui(rackSign, Enum.NormalId.Back, PPS)
	words(rackGui, "PICK YOUR DUMBBELL", 12, 6, 12.6 * PPS - 24, 2.4 * PPS - 12, W.Sunny, W.HotPink, 3)
	local ballRack: { Model } = {}
	local r = BowlingRules.BALL.radius
	for i, choice in CHOICES do
		local t = tiers[if i <= 2 then 1 else 2]
		local x = RX + (if i % 2 == 1 then -2.6 else 2.6)
		local model = makeDumbbell(folder, at(x, t.d, t.top + r), choice.color, false)
		model.Name = "BallChoice" .. i
		model.PrimaryPart = model:FindFirstChild("Bar") :: any
		model:SetAttribute("Choice", i)
		model:SetAttribute("Color", choice.color)
		model:SetAttribute("Label", choice.label)
		deco({
			Name = "Glow",
			Size = Vector3.new(3.4, 0.3, 0.12),
			CFrame = CFrame.new(at(x, t.d - 1.56, t.top - 0.25)),
			Color = choice.color,
			Material = Enum.Material.Neon,
			Parent = model,
		})
		ballRack[i] = model
	end

	-- Lounge seating: sofas round a table (left, by the wall) and a long bench at the back.
	local function sofa(cf: CFrame, len: number, color: Color3)
		part({ Name = "SofaBase", Size = Vector3.new(len, 1.3, 2.8), CFrame = cf * CFrame.new(0, 0.65, 0), Color = color })
		deco({ Name = "SofaCushion", Size = Vector3.new(len, 0.45, 2.1), CFrame = cf * CFrame.new(0, 1.5, -0.3), Color = W.Cream })
		part({ Name = "SofaBack", Size = Vector3.new(len, 3.4, 0.8), CFrame = cf * CFrame.new(0, 1.7, 1), Color = color })
		for _, side in { -1, 1 } do
			part({
				Name = "SofaArm",
				Size = Vector3.new(0.8, 2.2, 2.8),
				CFrame = cf * CFrame.new(side * (len / 2 + 0.4), 1.1, 0),
				Color = color,
			})
		end
	end
	local function seat(x: number, d: number, facing: Vector3): CFrame
		local p = at(x, d, 0)
		return CFrame.lookAt(p, p + facing)
	end
	sofa(seat(-15.5, railD - 3.6, Vector3.zAxis), 9, W.HotPink)
	sofa(seat(-23.4, railD - 10.5, Vector3.xAxis), 7, W.SkyBlue)
	sofa(seat(-15, edgeD + 2.8, -Vector3.zAxis), 10, W.Grape)
	local tableAt = Vector2.new(-16, railD - 10.5)
	upright(tableAt.X, tableAt.Y, 0, 2.1, 0.6, W.Chrome, "TableStem")
	upright(tableAt.X, tableAt.Y, 2, 2.3, 3.8, W.Sunny, "TableTop")
	makePin(folder, "TablePin", CFrame.new(at(tableAt.X, tableAt.Y, 2.3)), 0.55)

	-- Plants by the wall, a railing round the open edges and two lamp posts.
	for _, side in { -1, 1 } do
		local x, d = side * 24.3, railD - 3
		upright(x, d, 0, 2.2, 2.6, W.Terracotta, "PlantPot")
		globe(at(x, d, 3.2), 3.4, W.GrassDark, "PlantBush")
		globe(at(x + 0.6, d - 0.4, 4.6), 2, W.Grass, "PlantBush")
	end
	local railX, backD, frontD = half - 0.4, edgeD + 0.4, railD - 0.5
	local posts = {}
	for k = 0, 4 do
		local d = frontD + (backD - frontD) * k / 4
		table.insert(posts, { -railX, d })
		table.insert(posts, { railX, d })
	end
	for _, x in { -railX / 2, 0, railX / 2 } do
		table.insert(posts, { x, backD })
	end
	for _, post in posts do
		upright(post[1], post[2], 0, 2.7, 0.7, W.Teal, "RailPost")
		globe(at(post[1], post[2], 2.95), 0.9, W.Sunny, "RailCap")
	end
	for _, side in { -1, 1 } do
		part({
			Name = "Rail",
			Shape = CYLINDER,
			Size = Vector3.new(frontD - backD, 0.35, 0.35),
			CFrame = CFrame.new(at(side * railX, (frontD + backD) / 2, 2.45)) * CFrame.Angles(0, math.pi / 2, 0),
			Color = W.Chrome,
			Material = Enum.Material.Metal,
		})
	end
	part({
		Name = "Rail",
		Shape = CYLINDER,
		Size = Vector3.new(railX * 2, 0.35, 0.35),
		CFrame = CFrame.new(at(0, backD, 2.45)),
		Color = W.Chrome,
		Material = Enum.Material.Metal,
	})
	for _, lamp in { { -1, edgeD + 6 }, { 1, railD - 13 } } do
		local x = lamp[1] * (half - 1.4)
		upright(x, lamp[2], 0, 14, 0.7, W.Teal, "LampPost")
		local lampGlobe = globe(at(x, lamp[2], 14.6), 2, W.Sunny, "LampGlobe", true)
		local light = Instance.new("PointLight")
		light.Range = 16
		light.Brightness = 1.2
		light.Color = Color3.fromRGB(255, 236, 190)
		light.Parent = lampGlobe
	end

	return { startPad = startPad, board = board, ballRack = ballRack }
end

function BowlingLane.build(): Built
	local a = BowlingRules.ARENA
	local L = BowlingRules.LANE
	local base = Arena.base("bowling", "BowlingLane", a, { floor = "Cream", trim = "RedOrange" })
	local folder = base.folder
	local top = base.top
	local laneW, laneL = L.width, L.length
	local foulZ = a.z + a.sizeZ / 2 - LOBBY_D - L.foulFromEdge
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
	local lounge = lobby(folder, at, a)
	sea(folder, a)
	-- Pontoons: World.Arena's four corner floats reach down into the shallows, plus two pairs
	-- along the (long) deck's sides.
	local floatTop, floatBottom = top - 2, OCEAN_TOP - 0.6
	for _, z in { a.z - a.sizeZ / 6, a.z + a.sizeZ / 6 } do
		for _, side in { -1, 1 } do
			make("Part", {
				Name = "ArenaPontoon",
				Shape = CYLINDER,
				Size = Vector3.new(1, 6, 6),
				CFrame = CFrame.new(a.x + side * (a.sizeX / 2 - 4), 0, z),
				Color = W.RedOrange,
				Parent = folder,
			})
		end
	end
	for _, child in folder:GetChildren() do
		if child:IsA("BasePart") and child.Name == "ArenaPontoon" then
			local pos = child.CFrame.Position
			child.Size = Vector3.new(floatTop - floatBottom, child.Size.Y, child.Size.Z)
			child.CFrame = CFrame.new(pos.X, (floatTop + floatBottom) / 2, pos.Z) * UPRIGHT
		end
	end

	local built: any = base
	built.lane = lane
	built.rollStart = CFrame.lookAt(at(0, -3, 0), at(0, laneL, 0))
	-- The play spot is the bowler's spot; World.Arena's spawn pad is now the lobby's.
	built.lobbySpawn = base.spawn
	built.spawn = built.rollStart
	built.pinSpots = pinSpots
	built.pins = pins
	built.startPad = lounge.startPad
	built.startRadius = START_RADIUS
	built.board = lounge.board
	built.ballRack = lounge.ballRack
	return built :: Built
end

return BowlingLane
