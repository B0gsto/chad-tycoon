--[[
	MogStage: the MOG TEST stage, a round "toy" boxing ring floating out at sea on pontoons
	(teleport-only; Modes.Mog brings players here). Numbers live in Modes.MogLayout.

	- A thick Teal disc with a ring-canvas blue top (DRESS.FloorColor), a ring of Sunny/Coral bumpers on the rim and a Grape
	  skirt underneath, on six pontoon floats with foam at sea level.
	- Posts with glowing caps (dim PointLights) and two rows of ropes, like a boxing ring.
	- SPOT_COUNT duel spots: a Sunny pad for the player and a Grape pad for the rival, each on
	  a glowing Neon ring.
	- A central tower with a 4-sided "MOG TEST" sign (2-line card faces like the plaza gates)
	  and a "TOP MOGGERS" board near the rim (its list label is returned as bestList, its subtitle as bestTitle).
	- Arena dressing (DRESS, all of it decoration without collision, outside the rope ring so it
	  never stands between a camera and the players): a floating grandstand behind every duel
	  spot with three rows of cheering fans (each row hops in a wave while somebody is on the
	  stage) and a word band sized to its text, a light tower between every two stands with one beam on the MOG TEST sign and one
	  sweeping the sky, a garland of pennants from tower to tower, and a painted duel lane with a
	  ring round both pads of every spot, its capsule filled with a Grape-to-Sunny glow.
]]

local TextService = game:GetService("TextService")

local Common = require(script.Parent.Common)
local MogLayout = require(script.Parent.Parent.Modes.MogLayout)

local theme = Common.theme
local make = Common.make
local UPRIGHT = Common.UPRIGHT
local W = theme.World
local CYLINDER = Enum.PartType.Cylinder
local BALL = Enum.PartType.Ball

local MogStage = {}

export type Built = {
	folder: Model,
	bestList: TextLabel,
	-- The board's subtitle: "SERVER HIGH SCORES" until Modes.Mog says "ALL-TIME BEST".
	bestTitle: TextLabel,
}

-- Arena dressing: every size (studs), colour (Theme.World key), count and speed of what stands
-- round the stage. Heights are above the stage top unless they say otherwise.
local DRESS = {
	-- Grandstands: one raft per duel spot, centred on the spot's radial line, so the duel camera
	-- (Fx.Mog: over the player's shoulder, looking at the rival and across the stage) shows a
	-- full stand behind the rival. StandRing is the front edge's distance from the centre (the
	-- rim is at MogLayout.RADIUS = 46, the follow camera reaches about 48).
	StandRing = 54,
	StandWidth = 40,
	StandRows = 3,
	RowDepth = 4,
	RowRise = 3.2,
	FirstRow = 1.2,
	-- The back wall rises this far above the last row's deck; its top WallBand is a cream band
	-- with one of WallWords.
	WallHeight = 16,
	WallBand = 4.4,
	-- The word band is sized to its measured text (TextService, WordText px at WordPixels per
	-- stud, WordPad studs either side) and sits WordInset studs in from the wall's end on the
	-- stage's left as you face the stand: the end that faces the middle of a duel shot, so a
	-- stand at the frame's right edge still shows its whole word.
	WordPixels = 20,
	WordText = 64,
	WordPad = 1.4,
	WordInset = 1.2,
	WallWords = { "MOG OR GET MOGGED!", "W AURA ONLY", "TEAM CHAD", "GO GO GO!", "AURA +1000!", "MOG! MOG! MOG!" },
	RowColors = { "Coral", "Sunny", "Grape" },
	FlagHeight = 6,
	FlagSize = Vector2.new(4.4, 2.8),
	-- Fans: FansPerRow toy figures per row, FanScale times a 4.6-stud figure, arms up. Every
	-- third one holds a card overhead, the next one pom-poms.
	FansPerRow = 7,
	FanScale = 1.5,
	FanShirts = { "Coral", "Sunny", "Mint", "Pink", "Blue", "White", "RedOrange", "Grape" },
	FanSkins = { Color3.fromRGB(255, 214, 170), Color3.fromRGB(226, 168, 118), Color3.fromRGB(150, 100, 70) },
	FanCards = { "White", "Sunny", "Pink" },
	FanPoms = { "Pink", "Sunny", "Mint" },
	ArmSpread = 18,
	-- The wave: every row hops HopHeight, one hop per HopPeriod seconds, each row HopStagger of
	-- a hop behind the row in front and each stand StandStagger behind its neighbour.
	HopHeight = 2.4,
	HopPeriod = 0.9,
	HopStagger = 0.3,
	StandStagger = 0.17,
	-- Light towers, between the stands: a mast on a float with a lamp head on top.
	TowerRing = 53,
	TowerHeight = 31,
	MastThick = 1.6,
	FloatSize = 7,
	LampSize = Vector3.new(4.6, 2.8, 3.4),
	LensSize = 2.4,
	-- The fixed beam every lamp throws on the MOG TEST sign (width at the lamp / at the sign,
	-- transparency at the lamp; it fades out at the sign).
	SignBeam = { Width0 = 1.4, Width1 = 10, Transparency = 0.5 },
	-- The sky beam: tilted SkyTilt degrees off straight up toward the centre, swinging SkySwing
	-- degrees either way round the mast once per SkyPeriod seconds, and nodding SkyNod degrees.
	SkyBeam = { Width0 = 2, Width1 = 18, Transparency = 0.35, Length = 85 },
	SkyColors = { "Sunny", "Pink", "Mint" },
	SkyTilt = 38,
	SkySwing = 26,
	SkyNod = 9,
	SkyPeriod = 5,
	-- The garland: GarlandCount pennants from each tower top to the next, GarlandDrop under the
	-- top and sagging GarlandSag in the middle.
	GarlandDrop = 2,
	GarlandSag = 5,
	GarlandCount = 20,
	PennantSize = Vector2.new(2.5, 3.4),
	PennantColors = { "Coral", "Sunny", "White", "Pink", "Mint", "Grape" },
	-- Duel lanes painted on the floor: a white capsule round both pads of a spot with a ring
	-- round each pad (RingRadius, RingLine studs wide) and "VS" between them.
	RingRadius = 4.9,
	RingLine = 0.55,
	LaneLine = 0.3,
	LaneMargin = 0.6,
	LanePixels = 20,
	-- Colour on the floor: the stage top is a ring-canvas blue (FloorColor; the Sunny inlay
	-- and the Cream core stay), and every lane's capsule is filled with a glow from the
	-- rival's Grape end to the player's Sunny end at LaneFill transparency.
	FloorColor = Color3.fromRGB(96, 156, 255),
	LaneFill = 0.45,
	-- The crowd and the lamps move TickRate times a second, and only while a player is within
	-- ActiveRange of the centre (checked every ScanEvery seconds).
	TickRate = 20,
	ScanEvery = 1,
	ActiveRange = 150,
}

local C = MogLayout.CENTER
local TOP = C.y
local FOAM_Y = MogLayout.SEA_Y + 0.4
local LAMP = Color3.fromRGB(255, 236, 205)

local function decor(p: BasePart): BasePart
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	return p
end

local function add(parent: Instance, props: { [string]: any }): BasePart
	props.Parent = parent
	return make("Part", props)
end

-- An upright cylinder (disc) of diameter `d` and height `h` whose centre is at `pos`.
local function disc(parent: Instance, name: string, pos: Vector3, d: number, h: number, colour: Color3): BasePart
	return add(parent, {
		Name = name,
		Shape = CYLINDER,
		Size = Vector3.new(h, d, d),
		CFrame = CFrame.new(pos) * UPRIGHT,
		Color = colour,
	})
end

local function vec(p: MogLayout.Point): Vector3
	return Vector3.new(p.x, p.y, p.z)
end

local function light(p: BasePart, brightness: number, range: number, colour: Color3?)
	local l = Instance.new("PointLight")
	l.Brightness = brightness
	l.Range = range
	l.Color = colour or LAMP
	l.Shadows = false
	l.Parent = p
end

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

local function panel(parent: Instance, fill: Color3, position: UDim2, size: UDim2, corner: number?): Frame
	local f = Instance.new("Frame")
	f.BackgroundColor3 = fill
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

-- A 2-line sign card: a coloured header band with `header` and a big Ink `title` below.
local function cardFace(p: BasePart, face: Enum.NormalId, pps: number, band: Color3, header: string, title: string)
	local root = surface(p, face, pps)
	local card = panel(root, W.Cream, UDim2.fromScale(0.02, 0.04), UDim2.fromScale(0.96, 0.92), 0.1)
	local head = panel(card, band, UDim2.fromScale(0.04, 0.06), UDim2.fromScale(0.92, 0.3), 0.5)
	text(head, { Text = header, TextColor3 = W.White, Size = UDim2.fromScale(0.92, 0.76), Position = UDim2.fromScale(0.04, 0.12) })
	text(card, { Text = title, Size = UDim2.fromScale(0.92, 0.54), Position = UDim2.fromScale(0.04, 0.4) })
end

-- The floating disc: Teal body, Cream top, rim bumpers, Grape skirt, pontoons and foam.
local function buildDisc(parent: Instance)
	local r, t = MogLayout.RADIUS, MogLayout.THICKNESS
	disc(parent, "StageBody", Vector3.new(C.x, TOP - 0.2 - t / 2, C.z), r * 2, t, W.Teal)
	disc(parent, "StageTop", Vector3.new(C.x, TOP - 0.5, C.z), r * 2 - 4, 1, DRESS.FloorColor)
	disc(parent, "StageInlay", Vector3.new(C.x, TOP - 0.45, C.z), 30, 1, W.Sunny)
	disc(parent, "StageCore", Vector3.new(C.x, TOP - 0.4, C.z), 24, 1, W.Cream)
	disc(parent, "StageSkirt", Vector3.new(C.x, TOP - t - 1.2, C.z), r * 2 - 6, 2, W.Grape)
	-- Rim bumpers: alternating Sunny / Coral blocks around the edge.
	local bumpers = 24
	local seg = 2 * math.pi * r / bumpers
	for i = 1, bumpers do
		local a = (i - 0.5) * 2 * math.pi / bumpers
		local p = MogLayout.at(a, r - 0.6, TOP - 0.1)
		decor(add(parent, {
			Name = "RimBumper",
			Size = Vector3.new(seg * 0.82, 1.4, 1.6),
			CFrame = CFrame.lookAt(vec(p), Vector3.new(C.x, p.y, C.z)),
			Color = if i % 2 == 0 then W.Sunny else W.Coral,
		}))
	end
	-- Pontoon floats from below sea level up to the skirt, with foam rings.
	local skirtBottom = TOP - t - 2.2
	local floatBottom = MogLayout.SEA_Y - 2.5
	local h = skirtBottom - floatBottom
	for i = 1, 6 do
		local a = (i - 0.5) * math.pi / 3
		local p = MogLayout.at(a, r - 14, floatBottom + h / 2)
		local float = decor(disc(parent, "PontoonFloat", vec(p), 9, h, if i % 2 == 0 then W.Coral else W.White))
		float.CanCollide = true
		decor(disc(parent, "PontoonBand", Vector3.new(p.x, MogLayout.SEA_Y + 1.2, p.z), 9.4, 0.8, W.Sunny))
		local foam = decor(disc(parent, "PontoonFoam", Vector3.new(p.x, FOAM_Y, p.z), 13, 0.1, W.White))
		foam.Transparency = 0.35
		foam.CastShadow = false
	end
	local ring = decor(disc(parent, "StageFoam", Vector3.new(C.x, FOAM_Y - 0.05, C.z), r * 2 - 10, 0.1, W.White))
	ring.Transparency = 0.6
	ring.CastShadow = false
end

-- Ring posts with glowing caps and two rows of ropes between them.
local function buildRopes(parent: Instance)
	local posts = 8
	local postH = 6.5
	local points = {}
	for i = 1, posts do
		local a = (i - 0.5) * 2 * math.pi / posts
		local p = MogLayout.at(a, MogLayout.POST_RING, TOP)
		table.insert(points, p)
		add(parent, {
			Name = "RingPost",
			Shape = CYLINDER,
			Size = Vector3.new(postH, 1.4, 1.4),
			CFrame = CFrame.new(p.x, TOP + postH / 2, p.z) * UPRIGHT,
			Color = W.White,
		})
		local cap = decor(add(parent, {
			Name = "PostLamp",
			Shape = BALL,
			Size = Vector3.new(2.2, 2.2, 2.2),
			CFrame = CFrame.new(p.x, TOP + postH + 0.7, p.z),
			Color = if i % 2 == 0 then W.Sunny else W.Grape,
			Material = Enum.Material.Neon,
		}))
		light(cap, 0.6, 18)
	end
	for i = 1, posts do
		local a, b = points[i], points[i % posts + 1]
		for row, y in { 2.6, 4.8 } do
			local pa = Vector3.new(a.x, TOP + y, a.z)
			local pb = Vector3.new(b.x, TOP + y, b.z)
			local len = (pb - pa).Magnitude
			add(parent, {
				Name = "Rope",
				Shape = CYLINDER,
				Size = Vector3.new(len, 0.5, 0.5),
				CFrame = CFrame.lookAt((pa + pb) / 2, pb) * CFrame.Angles(0, math.rad(90), 0),
				Color = if row == 1 then W.Coral else W.Teal,
			})
		end
	end
end

-- Duel pads: a Sunny pad (player) and a Grape pad (rival) per spot, each on a glowing ring.
local function buildPads(parent: Instance)
	local h = MogLayout.PAD_HEIGHT
	local d = MogLayout.PAD_RADIUS * 2
	for _, spot in MogLayout.SPOTS do
		for _, which in { "player", "rival" } do
			local p = (spot :: any)[which] :: MogLayout.Point
			local colour = if which == "player" then W.Sunny else W.Grape
			local glow = decor(disc(parent, "DuelGlow", Vector3.new(p.x, TOP + h / 2 - 0.05, p.z), d + 1.6, h - 0.1, colour))
			glow.Material = Enum.Material.Neon
			glow.Transparency = 0.2
			local pad = disc(parent, "DuelPad", Vector3.new(p.x, TOP + h / 2, p.z), d, h, colour:Lerp(W.White, 0.15))
			pad:SetAttribute("Spot", spot.index)
			pad:SetAttribute("Side", which)
			light(pad, 0.5, 10, colour)
		end
	end
end

-- The central tower with the 4-sided MOG TEST sign above everyone's heads.
local function buildTower(parent: Instance)
	local r = MogLayout.TOWER_RADIUS
	disc(parent, "TowerFoot", Vector3.new(C.x, TOP + 0.5, C.z), r * 2 + 2, 1, W.Teal)
	local colH = 14
	disc(parent, "TowerColumn", Vector3.new(C.x, TOP + 1 + colH / 2, C.z), 3, colH, W.White)
	local size = 13
	local signY = TOP + 1 + colH + 3.5
	local box = add(parent, {
		Name = "MogSign",
		Size = Vector3.new(size, 7, size),
		CFrame = CFrame.new(C.x, signY, C.z),
		Color = W.Grape,
	})
	local faces = {
		{ Enum.NormalId.Front, W.Coral, "MOG TEST" },
		{ Enum.NormalId.Back, W.Coral, "MOG TEST" },
		{ Enum.NormalId.Left, W.Teal, "MOG TEST" },
		{ Enum.NormalId.Right, W.Teal, "MOG TEST" },
	}
	for _, f in faces do
		cardFace(box, f[1], 24, f[2], f[3], "MOG 3 RIVALS!")
	end
	for _, y in { signY - 3.9, signY + 3.9 } do
		decor(add(parent, {
			Name = "SignTrim",
			Size = Vector3.new(size + 0.8, 0.8, size + 0.8),
			CFrame = CFrame.new(C.x, y, C.z),
			Color = W.Sunny,
		}))
	end
	local crown = decor(add(parent, {
		Name = "SignCrown",
		Shape = BALL,
		Size = Vector3.new(3.4, 3.4, 3.4),
		CFrame = CFrame.new(C.x, signY + 6, C.z),
		Color = W.Sunny,
		Material = Enum.Material.Neon,
	}))
	light(crown, 0.8, 30)
end

-- The TOP MOGGERS board near the rim, facing the centre. Returns its list label and its
-- subtitle label.
local function buildBoard(parent: Instance): (TextLabel, TextLabel)
	local p = MogLayout.at(MogLayout.BOARD_ANGLE, MogLayout.BOARD_RING, TOP)
	local base = CFrame.lookAt(Vector3.new(p.x, TOP, p.z), Vector3.new(C.x, TOP, C.z))
	local w, h, bottom = 11, 12, 2.5
	for _, sx in { -1, 1 } do
		local x = sx * (w / 2 + 0.6)
		add(parent, {
			Name = "BoardPost",
			Shape = CYLINDER,
			Size = Vector3.new(bottom + h + 0.4, 1.3, 1.3),
			CFrame = base * CFrame.new(x, (bottom + h + 0.4) / 2, 0) * UPRIGHT,
			Color = W.Teal,
		})
		decor(add(parent, {
			Name = "BoardCap",
			Shape = BALL,
			Size = Vector3.new(2, 2, 2),
			CFrame = base * CFrame.new(x, bottom + h + 0.8, 0),
			Color = W.Sunny,
		}))
	end
	local slab = decor(add(parent, {
		Name = "MogBestBoard",
		Size = Vector3.new(w, h, 0.8),
		CFrame = base * CFrame.new(0, bottom + h / 2, 0),
		Color = W.White,
	}))
	local root = surface(slab, Enum.NormalId.Front, 30)
	local card = panel(root, W.Cream, UDim2.fromScale(0.03, 0.025), UDim2.fromScale(0.94, 0.95), 0.06)
	local pill = panel(card, W.Grape, UDim2.fromScale(0.06, 0.03), UDim2.fromScale(0.88, 0.13), 0.5)
	text(pill, { Text = "TOP MOGGERS", TextColor3 = W.White, Size = UDim2.fromScale(0.9, 0.74), Position = UDim2.fromScale(0.05, 0.13) })
	local title = text(card, {
		Text = "SERVER HIGH SCORES",
		Font = theme.Fonts.Bold,
		Size = UDim2.fromScale(0.8, 0.06),
		Position = UDim2.fromScale(0.1, 0.17),
	})
	local list = text(card, {
		Text = "Be the first to pass!",
		Font = theme.Fonts.Bold,
		TextScaled = false,
		TextSize = 26,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
		TextWrapped = true,
		RichText = true,
		Size = UDim2.fromScale(0.86, 0.72),
		Position = UDim2.fromScale(0.07, 0.25),
	})
	local back = surface(slab, Enum.NormalId.Back, 30)
	local backCard = panel(back, W.Cream, UDim2.fromScale(0.03, 0.025), UDim2.fromScale(0.94, 0.95), 0.06)
	text(backCard, { Text = "MOG TEST", Size = UDim2.fromScale(0.86, 0.3), Position = UDim2.fromScale(0.07, 0.35) })
	return list, title
end

-- Arena dressing (DRESS) -------------------------------------------------------------------

-- A frame at radius `r` along `angle`, `y` above the stage top: +X runs along the rim, +Z
-- points away from the centre (so a part's Front face looks at the centre).
local function rimFrame(angle: number, r: number, y: number): CFrame
	local sin, cos = math.sin(angle), math.cos(angle)
	return CFrame.fromMatrix(
		Vector3.new(C.x + sin * r, TOP + y, C.z + cos * r),
		Vector3.new(cos, 0, -sin),
		Vector3.yAxis,
		Vector3.new(sin, 0, cos)
	)
end

-- A moving piece: its anchored root, where it rests and how far into its cycle it starts.
type Mover = { root: BasePart, base: CFrame, phase: number }

-- An invisible anchored root that the parts welded to it follow.
local function moverRoot(parent: Instance, name: string, cframe: CFrame): BasePart
	local root = decor(add(parent, { Name = name, Size = Vector3.new(1, 1, 1), CFrame = cframe, Transparency = 1 }))
	root.CastShadow = false
	return root
end

-- Welds `p` (already in place) to `root`, so moving the root moves it.
local function ride(root: BasePart, p: BasePart): BasePart
	local weld = Instance.new("WeldConstraint")
	weld.Part0 = root
	weld.Part1 = p
	weld.Parent = p
	p.Anchored = false
	p.Massless = true
	return p
end

-- One cheering fan standing at `feet` (facing its -Z), welded to `root`: a shirt-coloured
-- body, a head and two raised arms; fan `n` of the row picks the colours and the hand prop.
local function buildFan(parent: Instance, root: BasePart, feet: CFrame, n: number)
	local s = DRESS.FanScale
	local shirt = W[DRESS.FanShirts[n % #DRESS.FanShirts + 1]]
	local skin = DRESS.FanSkins[(n * 7) % #DRESS.FanSkins + 1]
	local function piece(name: string, size: Vector3, at: CFrame, colour: Color3, shape: Enum.PartType?): BasePart
		return ride(root, decor(add(parent, { Name = name, Shape = shape, Size = size * s, CFrame = feet * at, Color = colour })))
	end
	piece("FanBody", Vector3.new(1.8, 3.4, 1), CFrame.new(0, 1.7 * s, 0), shirt)
	piece("FanHead", Vector3.new(1.2, 1.2, 1.2), CFrame.new(0, 4 * s, 0), skin)
	local hands: { CFrame } = {}
	for _, side in { -1, 1 } do
		-- The arm swings out from the shoulder; its hand is the far end.
		local shoulder = CFrame.new(side * 1.15 * s, 3.2 * s, 0) * CFrame.Angles(0, 0, -side * math.rad(DRESS.ArmSpread))
		piece("FanArm", Vector3.new(0.5, 1.9, 0.5), shoulder * CFrame.new(0, 0.95 * s, 0), skin)
		table.insert(hands, shoulder * CFrame.new(0, 2 * s, 0))
	end
	local prop = n % 3
	if prop == 0 then
		piece("FanCard", Vector3.new(2.8, 1.5, 0.15), CFrame.new(0, 5.6 * s, 0), W[DRESS.FanCards[n % #DRESS.FanCards + 1]])
	elseif prop == 1 then
		for _, hand in hands do
			piece("FanPom", Vector3.new(0.95, 0.95, 0.95), CFrame.new(hand.Position), W[DRESS.FanPoms[n % #DRESS.FanPoms + 1]], BALL)
		end
	end
end

-- The grandstand behind duel spot `index`: a floating hull, three stepped rows with coloured
-- front edges, a tall back wall with a cream word band and two flags, and the fans. Adds one
-- mover per row to `rows`.
local function buildStand(parent: Instance, index: number, rows: { Mover })
	local d = DRESS
	local frame = rimFrame(MogLayout.angle(index), d.StandRing, 0)
	local width = d.StandWidth
	local depth = d.StandRows * d.RowDepth
	local function block(name: string, size: Vector3, at: CFrame, colour: Color3): BasePart
		return decor(add(parent, { Name = name, Size = size, CFrame = frame * at, Color = colour }))
	end

	-- Hull from under the sea up to the first row's foot, with foam round it.
	local hullTop = d.FirstRow - 1
	local hullBottom = MogLayout.SEA_Y - 2.5 - TOP
	block(
		"StandHull",
		Vector3.new(width + 2, hullTop - hullBottom, depth + 3),
		CFrame.new(0, (hullTop + hullBottom) / 2, depth / 2 + 0.5),
		W.Teal
	)
	local foam = block("StandFoam", Vector3.new(width + 7, 0.1, depth + 8), CFrame.new(0, FOAM_Y - TOP, depth / 2 + 0.5), W.White)
	foam.Transparency = 0.4
	foam.CastShadow = false

	local deckTop = d.FirstRow
	for row = 1, d.StandRows do
		deckTop = d.FirstRow + (row - 1) * d.RowRise
		local z = (row - 0.5) * d.RowDepth
		block("StandStep", Vector3.new(width, deckTop - hullTop - 0.4, d.RowDepth), CFrame.new(0, (deckTop - 0.4 + hullTop) / 2, z), W.Teal)
		block("StandDeck", Vector3.new(width, 0.4, d.RowDepth), CFrame.new(0, deckTop - 0.2, z), W.Cream)
		block(
			"StandEdge",
			Vector3.new(width + 0.4, 1, 0.4),
			CFrame.new(0, deckTop - 0.5, z - d.RowDepth / 2 - 0.2),
			W[d.RowColors[(row - 1) % #d.RowColors + 1]]
		)

		-- The row's fans ride one root, so the whole row hops with one moved part.
		local base = frame * CFrame.new(0, deckTop, z)
		local root = moverRoot(parent, "FanRow", base)
		table.insert(rows, { root = root, base = base, phase = (row - 1) * d.HopStagger + (index - 1) * d.StandStagger })
		local pitch = width / d.FansPerRow
		for i = 1, d.FansPerRow do
			-- Every other row stands half a place over, so heads show between the heads in front.
			local x = -width / 2 + pitch * (i - 0.5) + (if row % 2 == 0 then pitch * 0.15 else -pitch * 0.15)
			buildFan(parent, root, base * CFrame.new(x, 0, 0.3), index * 5 + row * 3 + i)
		end
	end

	-- Back wall with the word band across its top, facing the stage.
	local wallTop = deckTop + d.WallHeight
	block("StandWall", Vector3.new(width + 2, wallTop - hullTop, 1), CFrame.new(0, (wallTop + hullTop) / 2, depth + 0.5), W.Grape)
	local word = d.WallWords[(index - 1) % #d.WallWords + 1]
	local font = theme.Fonts.Display
	local bounds = TextService:GetTextSize(word, d.WordText, font, Vector2.new(4000, 400))
	local bandW = math.min(width, bounds.X / d.WordPixels + d.WordPad * 2)
	-- +X is the stage's left as you face the stand (its front faces the centre, -Z).
	local bandX = width / 2 - d.WordInset - bandW / 2
	local band = block(
		"StandBand",
		Vector3.new(bandW, d.WallBand, 0.3),
		CFrame.new(math.max(bandX, 0), wallTop - d.WallBand / 2 - 0.5, depth - 0.1),
		W.Cream
	)
	text(surface(band, Enum.NormalId.Front, d.WordPixels), {
		Text = word,
		-- A word too long for the wall shrinks to fit instead of running off the band.
		TextScaled = bounds.X / d.WordPixels > width - d.WordPad * 2,
		TextSize = d.WordText,
		TextWrapped = false,
		Font = font,
		Size = UDim2.new(1, -d.WordPad * d.WordPixels * 2, 1, 0),
		Position = UDim2.fromOffset(d.WordPad * d.WordPixels, 0),
	})
	block("StandCap", Vector3.new(width + 2.6, 0.8, 1.6), CFrame.new(0, wallTop + 0.4, depth + 0.5), W.Sunny)
	for i, side in { -1, 1 } do
		local x = side * (width / 2 - 1)
		decor(add(parent, {
			Name = "StandFlagPole",
			Shape = CYLINDER,
			Size = Vector3.new(d.FlagHeight, 0.4, 0.4),
			CFrame = frame * CFrame.new(x, wallTop + 0.8 + d.FlagHeight / 2, depth + 0.5) * UPRIGHT,
			Color = W.White,
		}))
		block(
			"StandFlag",
			Vector3.new(d.FlagSize.X, d.FlagSize.Y, 0.15),
			CFrame.new(x - side * (0.2 + d.FlagSize.X / 2), wallTop + 0.8 + d.FlagHeight - d.FlagSize.Y / 2, depth + 0.5),
			if (index + i) % 2 == 0 then W.Coral else W.Sunny
		)
	end
end

-- A light shaft from `from` to `to` (points in `holder`'s own space) that widens and fades
-- along the way and always faces the camera.
local function lightBeam(holder: BasePart, from: Vector3, to: Vector3, look: any, colour: Color3)
	local a0 = Instance.new("Attachment")
	a0.Position = from
	a0.Parent = holder
	local a1 = Instance.new("Attachment")
	a1.Position = to
	a1.Parent = holder
	local beam = Instance.new("Beam")
	beam.Name = "LightBeam"
	beam.Attachment0 = a0
	beam.Attachment1 = a1
	beam.Width0 = look.Width0
	beam.Width1 = look.Width1
	beam.FaceCamera = true
	beam.Segments = 1
	beam.LightEmission = 1
	beam.LightInfluence = 0
	beam.Color = ColorSequence.new(colour)
	beam.Transparency = NumberSequence.new(look.Transparency, 1)
	beam.Parent = holder
end

-- Light tower `index` (between stands `index` and `index + 1`): a float, a banded mast and a
-- lamp head whose lens throws a fixed beam on the MOG TEST sign; on top, an invisible swivel
-- carries the sky beam. Adds the swivel to `lamps` and returns the top of the mast.
local function buildLightTower(parent: Instance, index: number, lamps: { Mover }): Vector3
	local d = DRESS
	local angle = MogLayout.angle(index) + math.pi / MogLayout.SPOT_COUNT
	local frame = rimFrame(angle, d.TowerRing, 0)
	local seaY = MogLayout.SEA_Y - TOP
	local function cyl(name: string, length: number, across: number, y: number, colour: Color3): BasePart
		return decor(add(parent, {
			Name = name,
			Shape = CYLINDER,
			Size = Vector3.new(length, across, across),
			CFrame = frame * CFrame.new(0, y, 0) * UPRIGHT,
			Color = colour,
		}))
	end
	cyl("TowerFloat", 4.5, d.FloatSize, seaY - 0.25, if index % 2 == 0 then W.Coral else W.White)
	local foam = cyl("TowerFoam", 0.1, d.FloatSize + 4, FOAM_Y - TOP, W.White)
	foam.Transparency = 0.35
	foam.CastShadow = false
	local mastBottom = seaY + 2
	cyl("TowerMast", d.TowerHeight - mastBottom, d.MastThick, (d.TowerHeight + mastBottom) / 2, W.Teal)
	for _, share in { 0.3, 0.55, 0.8 } do
		cyl("TowerBand", 0.9, d.MastThick + 0.5, mastBottom + (d.TowerHeight - mastBottom) * share, W.Sunny)
	end

	-- The lamp head looks from the mast top down at the sign.
	local top = (frame * CFrame.new(0, d.TowerHeight, 0)).Position
	local signAt = Vector3.new(C.x, TOP + 18.5, C.z)
	local head = decor(add(parent, {
		Name = "TowerLamp",
		Size = d.LampSize,
		CFrame = CFrame.lookAt(top + Vector3.new(0, d.LampSize.Y / 2, 0), signAt),
		Color = W.Grape,
	}))
	local lens = decor(add(parent, {
		Name = "TowerLens",
		Shape = CYLINDER,
		Size = Vector3.new(0.3, d.LensSize, d.LensSize),
		CFrame = head.CFrame * CFrame.new(0, 0, -d.LampSize.Z / 2 - 0.1) * CFrame.Angles(0, math.rad(90), 0),
		Color = LAMP,
		Material = Enum.Material.Neon,
	}))
	light(lens, 0.8, 24)
	local swivelBase = frame * CFrame.new(0, d.TowerHeight + d.LampSize.Y + 0.6, 0)
	local swivel = moverRoot(parent, "TowerSwivel", swivelBase)
	decor(add(parent, {
		Name = "TowerSkyLamp",
		Shape = BALL,
		Size = Vector3.new(2.2, 2.2, 2.2),
		CFrame = swivelBase,
		Color = W[d.SkyColors[(index - 1) % #d.SkyColors + 1]],
		Material = Enum.Material.Neon,
	}))
	-- pcall: the offline preview (Lune) may lack Beam or its sequence types; the towers stand
	-- without their shafts there.
	local ok, problem = pcall(function()
		local reach = (signAt - head.CFrame.Position).Magnitude
		lightBeam(head, Vector3.new(0, 0, -d.LampSize.Z / 2), Vector3.new(0, 0, -reach), d.SignBeam, LAMP)
		-- The swivel's -Z is "toward the centre"; the beam leaves it SkyTilt off straight up.
		local tilt = math.rad(d.SkyTilt)
		local aim = Vector3.new(0, math.cos(tilt), -math.sin(tilt)) * d.SkyBeam.Length
		lightBeam(swivel, Vector3.zero, aim, d.SkyBeam, W[d.SkyColors[(index - 1) % #d.SkyColors + 1]])
	end)
	if not ok then
		warn("[MogStage] light beams skipped: " .. tostring(problem))
	end
	table.insert(lamps, { root = swivel, base = swivelBase, phase = (index - 1) / MogLayout.SPOT_COUNT })
	return top
end

-- Pennants from `from` to `to` (world points), hanging point down from a sagging line.
local function buildGarland(parent: Instance, from: Vector3, to: Vector3, first: number)
	local d = DRESS
	local flat = Vector3.new(to.X - from.X, 0, to.Z - from.Z)
	if flat.Magnitude < 1 then
		return
	end
	local along = flat.Unit
	local down = -Vector3.yAxis
	local w, h = d.PennantSize.X, d.PennantSize.Y
	for n = 1, d.GarlandCount do
		local t = (n - 0.5) / d.GarlandCount
		local at = from:Lerp(to, t) - Vector3.new(0, d.GarlandDrop + d.GarlandSag * 4 * t * (1 - t) + h / 2, 0)
		-- Turned over, a wedge is a right triangle with its long edge up along the line.
		local pennant = decor(make("WedgePart", {
			Name = "GarlandPennant",
			Size = Vector3.new(0.15, h, w),
			CFrame = CFrame.fromMatrix(at, down:Cross(along), down, along),
			Color = W[d.PennantColors[(first + n) % #d.PennantColors + 1]],
			Parent = parent,
		}))
		pennant.CastShadow = false
	end
end

-- The duel lane of every spot, painted on the floor: one invisible plate just above the stage
-- top whose face draws a white capsule round both pads, a ring round each pad in its own colour
-- and "VS" between them (read upright by the player, who looks at the centre).
local function buildLanes(parent: Instance)
	local d = DRESS
	local across = (d.RingRadius + d.LaneMargin) * 2
	local length = MogLayout.DUEL + across
	local pps = d.LanePixels
	for _, spot in MogLayout.SPOTS do
		local plate = decor(add(parent, {
			Name = "DuelLane",
			Size = Vector3.new(across, 0.05, length),
			-- Above the centre inlays (0.1 up), below the pads' glow discs (0.3 up).
			CFrame = rimFrame(spot.angle, MogLayout.PLAYER_RING - MogLayout.DUEL / 2, 0.16 - 0.025),
			Transparency = 1,
		}))
		plate.CastShadow = false
		local root = surface(plate, Enum.NormalId.Top, pps)
		local function outlined(position: UDim2, size: UDim2, colour: Color3, line: number, transparency: number)
			local f = Instance.new("Frame")
			f.AnchorPoint = Vector2.new(0.5, 0.5)
			f.Position = position
			f.Size = size
			f.BackgroundTransparency = 1
			f.BorderSizePixel = 0
			f.Parent = root
			local round = Instance.new("UICorner")
			round.CornerRadius = UDim.new(0.5, 0)
			round.Parent = f
			local stroke = Instance.new("UIStroke")
			stroke.Color = colour
			stroke.Thickness = line * pps
			stroke.Transparency = transparency
			stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
			stroke.Parent = f
		end
		local inset = d.LaneLine * pps
		-- The lane's glow: a capsule fill, Grape at the rival's end (the face's top) to Sunny.
		local fill = Instance.new("Frame")
		fill.AnchorPoint = Vector2.new(0.5, 0.5)
		fill.Position = UDim2.fromScale(0.5, 0.5)
		fill.Size = UDim2.new(1, -inset * 2, 1, -inset * 2)
		fill.BackgroundColor3 = W.White
		fill.BackgroundTransparency = d.LaneFill
		fill.BorderSizePixel = 0
		fill.Parent = root
		local fillRound = Instance.new("UICorner")
		fillRound.CornerRadius = UDim.new(0.5, 0)
		fillRound.Parent = fill
		local glow = Instance.new("UIGradient")
		glow.Color = ColorSequence.new(W.Grape, W.Sunny)
		glow.Rotation = 90
		glow.Parent = fill
		outlined(UDim2.fromScale(0.5, 0.5), UDim2.new(1, -inset * 2, 1, -inset * 2), W.White, d.LaneLine, 0.15)
		-- The plate's -Z edge (the face's top) is the rival's end, toward the centre.
		local ring = d.RingRadius * 2 * pps
		local fromEnd = across / 2 * pps
		outlined(UDim2.new(0.5, 0, 0, fromEnd), UDim2.fromOffset(ring, ring), W.Grape, d.RingLine, 0)
		outlined(UDim2.new(0.5, 0, 1, -fromEnd), UDim2.fromOffset(ring, ring), W.Sunny, d.RingLine, 0)
		text(root, {
			Text = "VS",
			TextColor3 = W.White,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromScale(0.5, 0.1),
		})
	end
end

-- Moves the fan rows and the sky beams while a player is near the stage (the server moves one
-- anchored root per row and per lamp; what is welded to it follows on every client).
local function animate(rows: { Mover }, lamps: { Mover })
	-- pcall: the offline preview (Lune) has no Heartbeat.
	pcall(function()
		local Players = game:GetService("Players")
		local RunService = game:GetService("RunService")
		local d = DRESS
		local centre = Vector3.new(C.x, TOP, C.z)
		local clock, sinceTick, sinceScan = 0, 0, math.huge
		local active, resting = false, true
		RunService.Heartbeat:Connect(function(dt: number)
			sinceScan += dt
			if sinceScan >= d.ScanEvery then
				sinceScan = 0
				active = false
				for _, player in Players:GetPlayers() do
					local character = player.Character
					local root = character and character.PrimaryPart
					if root and (root.CFrame.Position - centre).Magnitude <= d.ActiveRange then
						active = true
						break
					end
				end
			end
			if not active then
				if not resting then
					resting = true
					for _, row in rows do
						row.root.CFrame = row.base
					end
				end
				return
			end
			resting = false
			clock += dt
			sinceTick += dt
			if sinceTick < 1 / d.TickRate then
				return
			end
			sinceTick = 0
			for _, row in rows do
				local hop = math.abs(math.sin(math.pi * (clock / d.HopPeriod - row.phase)))
				row.root.CFrame = row.base * CFrame.new(0, d.HopHeight * hop, 0)
			end
			for _, lamp in lamps do
				local turn = 2 * math.pi * (clock / d.SkyPeriod + lamp.phase)
				lamp.root.CFrame = lamp.base
					* CFrame.Angles(0, math.rad(d.SkySwing) * math.sin(turn), 0)
					* CFrame.Angles(math.rad(d.SkyNod) * math.sin(turn * 0.63), 0, 0)
			end
		end)
	end)
end

local function buildArena(parent: Instance)
	local rows: { Mover } = {}
	local lamps: { Mover } = {}
	local tops: { Vector3 } = {}
	for index = 1, MogLayout.SPOT_COUNT do
		buildStand(parent, index, rows)
		table.insert(tops, buildLightTower(parent, index, lamps))
	end
	for index, top in tops do
		buildGarland(parent, top, tops[index % #tops + 1], index)
	end
	buildLanes(parent)
	animate(rows, lamps)
end

function MogStage.build(): Built
	local folder = Instance.new("Model")
	folder.Name = "MogStage"
	folder.Parent = Common.mapFolder
	buildDisc(folder)
	buildRopes(folder)
	buildPads(folder)
	buildTower(folder)
	local list, title = buildBoard(folder)
	buildArena(folder)
	return { folder = folder, bestList = list, bestTitle = title }
end

return MogStage
