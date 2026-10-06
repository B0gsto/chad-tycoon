--[[
	MogStage: the MOG TEST stage, a round "toy" boxing ring floating out at sea on pontoons
	(teleport-only; Modes.Mog brings players here). Numbers live in Modes.MogLayout.

	- A thick Teal disc with a Cream top, a ring of Sunny/Coral bumpers on the rim and a Grape
	  skirt underneath, on six pontoon floats with foam at sea level.
	- Posts with glowing caps (dim PointLights) and two rows of ropes, like a boxing ring.
	- SPOT_COUNT duel spots: a Sunny pad for the player and a Grape pad for the rival, each on
	  a glowing Neon ring.
	- A central tower with a 4-sided "MOG TEST" sign (2-line card faces like the plaza gates)
	  and a "TOP MOGGERS" board near the rim (its list label is returned as bestList).
]]

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
	disc(parent, "StageTop", Vector3.new(C.x, TOP - 0.5, C.z), r * 2 - 4, 1, W.Cream)
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

-- The TOP MOGGERS board near the rim, facing the centre. Returns its list label.
local function buildBoard(parent: Instance): TextLabel
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
	text(card, {
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
	return list
end

function MogStage.build(): Built
	local folder = Instance.new("Model")
	folder.Name = "MogStage"
	folder.Parent = Common.mapFolder
	buildDisc(folder)
	buildRopes(folder)
	buildPads(folder)
	buildTower(folder)
	local list = buildBoard(folder)
	return { folder = folder, bestList = list }
end

return MogStage
