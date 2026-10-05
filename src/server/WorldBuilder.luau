--[[
	WorldBuilder: generates the whole map from parts when the server starts.

	Layout (top-down, one plot; the entrance faces the central hub):

	        back wall
	  +-------------------------------+
	  |  [ display shelves x3 rows ]  |
	  | proc+  B1 B5 B25 B100 AM  tier|
	  | proc       ( orb field )      |
	  |  DEPOSIT     (MERGE)   UNLOCK |
	  |                        UNLOCK |
	  |  COLLECT                 FREE |
	  +----------[ entrance ]---------+

	All plot-local positions use X = right, Z = toward the back wall.
]]

local Lighting = game:GetService("Lighting")
local Workspace = game:GetService("Workspace")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Economy = require(ReplicatedStorage.Shared.Economy)

local WorldBuilder = {}

local PLOT_COUNT = 6
local PLOT_HALF = 55
-- Wall boards sit in front of the wall pillars (pillar faces are at PLOT_HALF - 2.5).
local BOARD_X = PLOT_HALF - 3.4

export type Pad = {
	name: string,
	center: Vector3,
	half: Vector2,
	part: BasePart,
	title: TextLabel,
	sub: TextLabel,
}

export type Plot = {
	index: number,
	cframe: CFrame,
	folder: Folder,
	unitFolder: Folder,
	orbFolder: Folder,
	chestFolder: Folder,
	spawn: CFrame,
	slots: { CFrame },
	orbArea: { minX: number, maxX: number, minZ: number, maxZ: number },
	pads: { Pad },
	padByName: { [string]: Pad },
	labels: { [string]: TextLabel },
	ownerImage: ImageLabel,
	unlockerScreens: { { frame: Frame, title: TextLabel, status: TextLabel, timer: TextLabel } },
}

export type World = {
	plots: { Plot },
	ranking: { TextLabel },
}

local theme: any
local mapFolder: Folder

local function part(props: { [string]: any }): Part
	local p = Instance.new("Part")
	p.Anchored = true
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Material = Enum.Material.SmoothPlastic
	for key, value in props do
		if key ~= "Parent" then
			(p :: any)[key] = value
		end
	end
	p.Parent = props.Parent or mapFolder
	return p
end

local function stroke(parent: Instance, thickness: number?)
	local s = Instance.new("UIStroke")
	s.Thickness = thickness or 2
	s.Color = theme.Colors.Stroke
	s.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
	s.Parent = parent
end

local function label(parent: Instance, props: { [string]: any }): TextLabel
	local l = Instance.new("TextLabel")
	l.BackgroundTransparency = 1
	l.TextScaled = true
	l.Font = theme.Fonts.Title
	l.TextColor3 = theme.Colors.Text
	l.Size = UDim2.fromScale(1, 0.3)
	for key, value in props do
		(l :: any)[key] = value
	end
	stroke(l, props.StrokeThickness)
	l.Parent = parent
	return l
end

-- A flat sign whose front (-Z) face carries a SurfaceGui.
local function board(cframe: CFrame, size: Vector2, parent: Instance, accent: Color3?): (SurfaceGui, Frame)
	local frameColor = accent or theme.Colors.Neon
	local back = part({
		Name = "Board",
		Size = Vector3.new(size.X + 0.6, size.Y + 0.6, 0.6),
		CFrame = cframe * CFrame.new(0, 0, 0.35),
		Color = frameColor,
		Material = Enum.Material.Neon,
		Parent = parent,
	})
	back.CanCollide = false
	local screen = part({
		Name = "Screen",
		Size = Vector3.new(size.X, size.Y, 0.4),
		CFrame = cframe,
		Color = theme.Colors.PanelDark,
		Parent = parent,
	})
	screen.CanCollide = false
	local gui = Instance.new("SurfaceGui")
	gui.Face = Enum.NormalId.Front
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 30
	gui.LightInfluence = 0
	gui.Parent = screen
	local frame = Instance.new("Frame")
	frame.Size = UDim2.fromScale(1, 1)
	frame.BackgroundColor3 = theme.Colors.PanelDark
	frame.BorderSizePixel = 0
	frame.Parent = gui
	local gradient = Instance.new("UIGradient")
	gradient.Color = ColorSequence.new(theme.Colors.Panel, theme.Colors.PanelDark)
	gradient.Rotation = 90
	gradient.Parent = frame
	return gui, frame
end

local function billboard(adornee: BasePart, offsetY: number, width: number, height: number): BillboardGui
	local gui = Instance.new("BillboardGui")
	gui.Size = UDim2.fromScale(width, height)
	gui.StudsOffset = Vector3.new(0, offsetY, 0)
	gui.LightInfluence = 0
	gui.MaxDistance = 140
	gui.Adornee = adornee
	gui.Parent = adornee
	return gui
end

local function setupLighting()
	local l = theme.Lighting
	Lighting.ClockTime = l.ClockTime
	Lighting.Ambient = l.Ambient
	Lighting.OutdoorAmbient = l.OutdoorAmbient
	Lighting.Brightness = l.Brightness
	Lighting.FogColor = l.FogColor
	Lighting.FogEnd = l.FogEnd
	Lighting.GlobalShadows = true

	local atmosphere = Lighting:FindFirstChildOfClass("Atmosphere") or Instance.new("Atmosphere")
	atmosphere.Color = l.AtmosphereColor
	atmosphere.Decay = l.AtmosphereDecay
	atmosphere.Density = 0.3
	atmosphere.Glare = 0.2
	atmosphere.Haze = 1.5
	atmosphere.Parent = Lighting

	local bloom = Lighting:FindFirstChildOfClass("BloomEffect") or Instance.new("BloomEffect")
	bloom.Intensity = l.BloomIntensity
	bloom.Size = 30
	bloom.Threshold = 0.9
	bloom.Parent = Lighting

	local cc = Lighting:FindFirstChildOfClass("ColorCorrectionEffect") or Instance.new("ColorCorrectionEffect")
	cc.TintColor = l.ColorTint
	cc.Saturation = 0.15
	cc.Contrast = 0.08
	cc.Parent = Lighting
end

local function buildHub(): { TextLabel }
	local c = theme.Colors
	part({
		Name = "Ground",
		Size = Vector3.new(560, 1, 560),
		CFrame = CFrame.new(0, -0.6, 0),
		Color = c.Hub,
		Material = Enum.Material.Concrete,
	})

	local spawn = Instance.new("SpawnLocation")
	spawn.Name = "HubSpawn"
	spawn.Anchored = true
	spawn.Neutral = true
	spawn.Size = Vector3.new(14, 1, 14)
	spawn.CFrame = CFrame.new(0, 0, -24)
	spawn.Color = c.Neon
	spawn.Material = Enum.Material.Neon
	spawn.Duration = 0
	spawn.Parent = mapFolder
	local decal = spawn:FindFirstChildOfClass("Decal")
	if decal then
		decal:Destroy()
	end

	-- Central tower: title on the X faces, ranking boards on the Z faces.
	part({ Name = "Tower", Size = Vector3.new(18, 34, 18), CFrame = CFrame.new(0, 17, 0), Color = c.Wall, Material = Enum.Material.Metal })
	part({
		Name = "TowerCap",
		Size = Vector3.new(21, 1.5, 21),
		CFrame = CFrame.new(0, 34.5, 0),
		Color = c.Neon,
		Material = Enum.Material.Neon,
	})
	part({
		Name = "TowerBase",
		Size = Vector3.new(24, 1, 24),
		CFrame = CFrame.new(0, 0.2, 0),
		Color = c.NeonAlt,
		Material = Enum.Material.Neon,
	})

	for _, sideAngle in { math.pi / 2, -math.pi / 2 } do
		local cf = CFrame.new(0, 24, 0) * CFrame.Angles(0, sideAngle, 0) * CFrame.new(0, 0, -9.4)
		local _, frame = board(cf, Vector2.new(16, 10), mapFolder, c.NeonAlt)
		label(
			frame,
			{ Text = theme.GameName, Size = UDim2.fromScale(0.94, 0.5), Position = UDim2.fromScale(0.03, 0.08), TextColor3 = c.Primary }
		)
		label(
			frame,
			{ Text = theme.Tagline, Font = theme.Fonts.Body, Size = UDim2.fromScale(0.9, 0.25), Position = UDim2.fromScale(0.05, 0.62) }
		)
	end

	local rankingLabels: { TextLabel } = {}
	for _, sideAngle in { 0, math.pi } do
		local cf = CFrame.new(0, 18, 0) * CFrame.Angles(0, sideAngle, 0) * CFrame.new(0, 0, -9.4)
		local _, frame = board(cf, Vector2.new(16, 26), mapFolder, c.Primary)
		label(frame, {
			Text = "🏆 TOP " .. string.upper(theme.Words.Units),
			Size = UDim2.fromScale(0.94, 0.08),
			Position = UDim2.fromScale(0.03, 0.02),
			TextColor3 = c.Primary,
		})
		local list = label(frame, {
			Text = "Loading...",
			Font = theme.Fonts.Body,
			TextScaled = false,
			TextSize = 26,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextYAlignment = Enum.TextYAlignment.Top,
			Size = UDim2.fromScale(0.9, 0.86),
			Position = UDim2.fromScale(0.05, 0.12),
			RichText = true,
		})
		table.insert(rankingLabels, list)
	end

	-- Neon walkways from hub to each plot row.
	for _, z in { 1, -1 } do
		part({
			Name = "Walkway",
			Size = Vector3.new(340, 0.2, 3),
			CFrame = CFrame.new(0, -0.05, z * 70),
			Color = c.NeonAlt,
			Material = Enum.Material.Neon,
		})
	end
	for x = -1, 1 do
		part({
			Name = "Walkway",
			Size = Vector3.new(3, 0.2, 140),
			CFrame = CFrame.new(x * 130, -0.05, 0),
			Color = c.Neon,
			Material = Enum.Material.Neon,
		})
	end

	-- Decorative light posts.
	for i = 0, 7 do
		local angle = i * math.pi / 4
		local pos = Vector3.new(math.cos(angle) * 40, 0, math.sin(angle) * 40)
		part({
			Name = "Post",
			Size = Vector3.new(1.2, 12, 1.2),
			CFrame = CFrame.new(pos + Vector3.new(0, 6, 0)),
			Color = c.WallTrim,
			Material = Enum.Material.Metal,
		})
		local bulb = part({
			Name = "Bulb",
			Shape = Enum.PartType.Ball,
			Size = Vector3.new(2.4, 2.4, 2.4),
			CFrame = CFrame.new(pos + Vector3.new(0, 12.5, 0)),
			Color = if i % 2 == 0 then c.Neon else c.NeonAlt,
			Material = Enum.Material.Neon,
		})
		local light = Instance.new("PointLight")
		light.Color = bulb.Color
		light.Range = 30
		light.Brightness = 1.5
		light.Parent = bulb
	end
	return rankingLabels
end

local function plotCFrame(index: number): CFrame
	local row = if index <= 3 then 1 else -1
	local col = ((index - 1) % 3) - 1
	local center = Vector3.new(col * 130, 0, row * 150)
	return CFrame.lookAt(center, Vector3.new(center.X, 0, 0))
end

local function buildPlot(index: number): Plot
	local c = theme.Colors
	local w = theme.Words
	local cf = plotCFrame(index)
	local folder = Instance.new("Folder")
	folder.Name = "Plot" .. index
	folder.Parent = mapFolder

	local function L(x: number, y: number, z: number): CFrame
		return cf * CFrame.new(x, y, z)
	end
	local function P(props: { [string]: any }): Part
		props.Parent = props.Parent or folder
		return part(props)
	end

	-- Floor, field and walls.
	P({
		Name = "Floor",
		Size = Vector3.new(PLOT_HALF * 2, 1, PLOT_HALF * 2),
		CFrame = L(0, -0.5, 0),
		Color = c.Floor,
		Material = Enum.Material.Slate,
	})
	P({
		Name = "Field",
		Size = Vector3.new(64, 0.1, 44),
		CFrame = L(0, 0.02, -1),
		Color = c.FloorAlt,
		Material = Enum.Material.DiamondPlate,
	})
	for _, x in { -32, 32 } do
		P({ Name = "FieldTrim", Size = Vector3.new(0.6, 0.15, 44), CFrame = L(x, 0.05, -1), Color = c.Neon, Material = Enum.Material.Neon })
	end
	for _, z in { -23, 21 } do
		P({ Name = "FieldTrim", Size = Vector3.new(64, 0.15, 0.6), CFrame = L(0, 0.05, z), Color = c.Neon, Material = Enum.Material.Neon })
	end

	local wallHeight = 30
	P({
		Name = "WallBack",
		Size = Vector3.new(PLOT_HALF * 2, wallHeight, 1),
		CFrame = L(0, wallHeight / 2, PLOT_HALF),
		Color = c.Wall,
		Material = Enum.Material.Brick,
	})
	for side = -1, 1, 2 do
		P({
			Name = "WallSide",
			Size = Vector3.new(1, wallHeight, PLOT_HALF * 2),
			CFrame = L(side * PLOT_HALF, wallHeight / 2, 0),
			Color = c.Wall,
			Material = Enum.Material.Brick,
		})
		P({
			Name = "WallTrim",
			Size = Vector3.new(1.4, 1, PLOT_HALF * 2),
			CFrame = L(side * PLOT_HALF, wallHeight, 0),
			Color = c.WallTrim,
			Material = Enum.Material.Metal,
		})
		P({
			Name = "WallNeon",
			Size = Vector3.new(1.2, 0.5, PLOT_HALF * 2),
			CFrame = L(side * PLOT_HALF, 2, 0),
			Color = c.NeonAlt,
			Material = Enum.Material.Neon,
		})
		for z = -44, 44, 22 do
			P({
				Name = "Pillar",
				Size = Vector3.new(3, wallHeight, 3),
				CFrame = L(side * (PLOT_HALF - 1), wallHeight / 2, z),
				Color = c.WallTrim,
				Material = Enum.Material.Metal,
			})
			P({
				Name = "PillarNeon",
				Size = Vector3.new(0.4, wallHeight - 6, 0.6),
				CFrame = L(side * (PLOT_HALF - 2.6), wallHeight / 2, z),
				Color = c.Neon,
				Material = Enum.Material.Neon,
			})
		end
	end
	P({
		Name = "BackTrim",
		Size = Vector3.new(PLOT_HALF * 2, 1, 1.4),
		CFrame = L(0, wallHeight, PLOT_HALF),
		Color = c.WallTrim,
		Material = Enum.Material.Metal,
	})

	-- Entrance arch with the owner sign facing the hub.
	for side = -1, 1, 2 do
		P({
			Name = "ArchPillar",
			Size = Vector3.new(4, 22, 4),
			CFrame = L(side * 16, 11, -PLOT_HALF),
			Color = c.WallTrim,
			Material = Enum.Material.Metal,
		})
		P({
			Name = "ArchNeon",
			Size = Vector3.new(4.4, 0.6, 4.4),
			CFrame = L(side * 16, 21, -PLOT_HALF),
			Color = c.Neon,
			Material = Enum.Material.Neon,
		})
	end
	P({ Name = "ArchBeam", Size = Vector3.new(36, 4, 4), CFrame = L(0, 23, -PLOT_HALF), Color = c.WallTrim, Material = Enum.Material.Metal })
	-- Boards face plot -Z, which is toward the hub, so no rotation is needed.
	local _, ownerFrame = board(L(0, 23, -PLOT_HALF - 2.3), Vector2.new(26, 6), folder, c.Primary)
	local ownerImage = Instance.new("ImageLabel")
	ownerImage.BackgroundTransparency = 1
	ownerImage.Size = UDim2.fromScale(0.22, 0.9)
	ownerImage.Position = UDim2.fromScale(0.02, 0.05)
	ownerImage.ScaleType = Enum.ScaleType.Fit
	ownerImage.Image = ""
	ownerImage.Parent = ownerFrame
	local ownerLabel = label(
		ownerFrame,
		{ Text = "EMPTY PLOT", Size = UDim2.fromScale(0.72, 0.7), Position = UDim2.fromScale(0.26, 0.15), TextColor3 = c.Primary }
	)

	-- Display shelves: three stepped rows of ten slots.
	local slots: { CFrame } = {}
	for row = 0, 2 do
		local top = 1.5 + row * 5
		local z = 34 + row * 6.5
		P({
			Name = "Shelf",
			Size = Vector3.new(74, top, 6.5),
			CFrame = L(0, top / 2, z),
			Color = c.WallTrim,
			Material = Enum.Material.Metal,
		})
		P({
			Name = "ShelfNeon",
			Size = Vector3.new(74, 0.3, 0.4),
			CFrame = L(0, top - 0.1, z - 3.3),
			Color = if row % 2 == 0 then c.Neon else c.NeonAlt,
			Material = Enum.Material.Neon,
		})
		for col = 0, 9 do
			table.insert(slots, L(-31.5 + col * 7, top, z))
		end
	end
	-- Order: front row first, centre-out, so the best units are most visible.
	local order = { 5, 6, 4, 7, 3, 8, 2, 9, 1, 10 }
	local ordered: { CFrame } = {}
	for row = 0, 2 do
		for _, col in order do
			table.insert(ordered, slots[row * 10 + col])
		end
	end
	assert(#ordered == Economy.DISPLAY_SLOTS, "display slot count mismatch")

	local pads: { Pad } = {}
	local padByName: { [string]: Pad } = {}
	local labels: { [string]: TextLabel } = {}

	local function pad(
		name: string,
		x: number,
		z: number,
		sizeX: number,
		sizeZ: number,
		color: Color3,
		title: string,
		sub: string,
		round: boolean?
	): Pad
		local padPart
		if round then
			padPart = P({
				Name = "Pad_" .. name,
				Shape = Enum.PartType.Cylinder,
				Size = Vector3.new(0.5, sizeX, sizeZ),
				CFrame = L(x, 0.25, z) * CFrame.Angles(0, 0, math.rad(90)),
				Color = color,
				Material = Enum.Material.Neon,
			})
		else
			padPart = P({
				Name = "Pad_" .. name,
				Size = Vector3.new(sizeX, 0.5, sizeZ),
				CFrame = L(x, 0.25, z),
				Color = color,
				Material = Enum.Material.Neon,
			})
			P({
				Name = "PadRim",
				Size = Vector3.new(sizeX + 1, 0.3, sizeZ + 1),
				CFrame = L(x, 0.15, z),
				Color = c.WallTrim,
				Material = Enum.Material.Metal,
			})
		end
		padPart.CanCollide = false
		local gui = billboard(padPart, 4.5, 12, 3.6)
		local titleLabel = label(gui, { Text = title, Size = UDim2.fromScale(1, 0.55) })
		local subLabel =
			label(gui, { Text = sub, Size = UDim2.fromScale(1, 0.42), Position = UDim2.fromScale(0, 0.58), TextColor3 = c.Good })
		local record: Pad = {
			name = name,
			center = Vector3.new(x, 0, z),
			half = Vector2.new(sizeX / 2, sizeZ / 2),
			part = padPart,
			title = titleLabel,
			sub = subLabel,
		}
		table.insert(pads, record)
		padByName[name] = record
		return record
	end

	-- Buy row.
	local buyX = { -36, -22, -8, 6 }
	for i, amount in Economy.BUY_AMOUNTS do
		pad("Buy" .. amount, buyX[i], 26, 9, 6, c.Pad, "Buy " .. amount .. " " .. w.Unit, "$0")
	end
	pad("AutoMerge", 19, 26, 8, 6, c.NeonAlt, "Auto Merge", "$0")

	-- Buy tier upgrade: pad + board on the right wall.
	pad("BuyTier", 46, 20, 8, 8, c.NeonAlt, w.BuyTier, "")
	do
		local _, frame = board(L(BOARD_X, 9, 20) * CFrame.Angles(0, math.pi / 2, 0), Vector2.new(14, 9), folder, c.NeonAlt)
		labels.BuyTierTitle = label(
			frame,
			{ Text = w.BuyTier, Size = UDim2.fromScale(0.94, 0.2), Position = UDim2.fromScale(0.03, 0.04), TextColor3 = c.Secondary }
		)
		labels.BuyTierFromTo =
			label(frame, { Text = "", Font = theme.Fonts.Body, Size = UDim2.fromScale(0.94, 0.22), Position = UDim2.fromScale(0.03, 0.28) })
		labels.BuyTierProgress = label(frame, {
			Text = "",
			Font = theme.Fonts.Body,
			Size = UDim2.fromScale(0.94, 0.2),
			Position = UDim2.fromScale(0.03, 0.54),
			TextColor3 = c.Primary,
		})
		labels.BuyTierCost = label(frame, {
			Text = "",
			Font = theme.Fonts.Body,
			Size = UDim2.fromScale(0.94, 0.18),
			Position = UDim2.fromScale(0.03, 0.78),
			TextColor3 = c.Good,
		})
	end

	-- Merge pad in the middle of the field.
	pad("Merge", 0, -2, 12, 12, c.Primary, w.Merge, "Pairs merge into the next tier", true)

	-- Deposit station (left).
	pad("Deposit", -42, -8, 10, 10, c.Secondary, "DEPOSIT", w.Orb .. " x1.0")
	do
		local base = P({
			Name = "Converter",
			Size = Vector3.new(6, 1.5, 6),
			CFrame = L(-50, 0.75, -8),
			Color = c.WallTrim,
			Material = Enum.Material.Metal,
		})
		base.CanCollide = true
		local tube = P({
			Name = "ConverterTube",
			Shape = Enum.PartType.Cylinder,
			Size = Vector3.new(9, 5, 5),
			CFrame = L(-50, 6, -8) * CFrame.Angles(0, 0, math.rad(90)),
			Color = c.Orb,
			Material = Enum.Material.Glass,
			Transparency = 0.35,
		})
		tube.CanCollide = false
		local core = P({
			Name = "ConverterCore",
			Shape = Enum.PartType.Ball,
			Size = Vector3.new(3, 3, 3),
			CFrame = L(-50, 6, -8),
			Color = c.Orb,
			Material = Enum.Material.Neon,
		})
		core.CanCollide = false
		local light = Instance.new("PointLight")
		light.Color = c.Orb
		light.Range = 18
		light.Parent = core
		P({
			Name = "ConverterTop",
			Size = Vector3.new(6, 1.2, 6),
			CFrame = L(-50, 11, -8),
			Color = c.WallTrim,
			Material = Enum.Material.Metal,
		})
		local _, frame = board(L(-BOARD_X, 17, -8) * CFrame.Angles(0, -math.pi / 2, 0), Vector2.new(14, 7), folder, c.Secondary)
		label(
			frame,
			{ Text = w.Deposit, Size = UDim2.fromScale(0.94, 0.25), Position = UDim2.fromScale(0.03, 0.05), TextColor3 = c.Secondary }
		)
		labels.DepositMult = label(
			frame,
			{ Text = "x1.0", Size = UDim2.fromScale(0.9, 0.42), Position = UDim2.fromScale(0.05, 0.32), TextColor3 = c.Primary }
		)
		labels.DepositNext =
			label(frame, { Text = "", Font = theme.Fonts.Body, Size = UDim2.fromScale(0.9, 0.18), Position = UDim2.fromScale(0.05, 0.78) })
	end

	-- Processing board + upgrade pads (left wall, further back).
	do
		local _, frame = board(L(-BOARD_X, 11, 17) * CFrame.Angles(0, -math.pi / 2, 0), Vector2.new(14, 8), folder, c.Primary)
		labels.ProcessTitle = label(frame, {
			Text = "⚡ " .. w.Process .. " ⚡",
			Size = UDim2.fromScale(0.94, 0.2),
			Position = UDim2.fromScale(0.03, 0.05),
			TextColor3 = c.Primary,
		})
		labels.ProcessQueue = label(frame, { Text = "0", Size = UDim2.fromScale(0.9, 0.36), Position = UDim2.fromScale(0.05, 0.28) })
		labels.ProcessRate = label(frame, {
			Text = "",
			Font = theme.Fonts.Body,
			Size = UDim2.fromScale(0.9, 0.18),
			Position = UDim2.fromScale(0.05, 0.66),
			TextColor3 = c.Good,
		})
		labels.ProcessSpeed = label(frame, {
			Text = "",
			Font = theme.Fonts.Body,
			Size = UDim2.fromScale(0.9, 0.14),
			Position = UDim2.fromScale(0.05, 0.84),
			TextColor3 = c.TextDim,
		})
	end
	pad("ProcUp1", -47, 11, 8, 6, c.Good, "UPGRADE", "$0")
	pad("ProcUp10", -47, 21, 8, 6, c.Good, "UPGRADE x" .. Economy.PROCESS_BULK, "$0")

	-- Collect cash pad + coin sign.
	pad("Collect", -40, -34, 11, 11, c.Primary, w.Collect, "$0")
	do
		local coin = P({
			Name = "Coin",
			Shape = Enum.PartType.Cylinder,
			Size = Vector3.new(1.2, 10, 10),
			CFrame = L(-50, 8, -34) * CFrame.Angles(0, math.rad(90), 0),
			Color = c.Primary,
			Material = Enum.Material.Neon,
		})
		coin.CanCollide = false
		local gui = Instance.new("SurfaceGui")
		gui.Face = Enum.NormalId.Right
		gui.LightInfluence = 0
		gui.Parent = coin
		label(gui, { Text = "$", Size = UDim2.fromScale(1, 1), TextColor3 = c.PanelDark })
		local gui2 = Instance.new("SurfaceGui")
		gui2.Face = Enum.NormalId.Left
		gui2.LightInfluence = 0
		gui2.Parent = coin
		label(gui2, { Text = "$", Size = UDim2.fromScale(1, 1), TextColor3 = c.PanelDark })
		P({ Name = "CoinStand", Size = Vector3.new(3, 3, 3), CFrame = L(-50, 1.5, -34), Color = c.WallTrim, Material = Enum.Material.Metal })
	end

	-- Crate unlockers (right).
	local unlockerScreens = {}
	for i, z in { -6, 8 } do
		local name = if i == 1 then w.Unlocker else w.PremiumUnlocker
		local color = if i == 1 then c.Secondary else c.Accent
		pad("Unlock" .. i, 42, z, 8, 8, color, name, "")
		P({ Name = "Machine", Size = Vector3.new(5, 12, 9), CFrame = L(51, 6, z), Color = c.WallTrim, Material = Enum.Material.Metal })
		P({ Name = "MachineNeon", Size = Vector3.new(5.2, 0.5, 9.2), CFrame = L(51, 12, z), Color = color, Material = Enum.Material.Neon })
		local _, frame = board(L(48.3, 7.5, z) * CFrame.Angles(0, math.pi / 2, 0), Vector2.new(8, 6), folder, color)
		local titleLabel =
			label(frame, { Text = name, Size = UDim2.fromScale(0.94, 0.22), Position = UDim2.fromScale(0.03, 0.04), TextColor3 = color })
		local statusLabel = label(
			frame,
			{ Text = "EMPTY", Font = theme.Fonts.Body, Size = UDim2.fromScale(0.94, 0.2), Position = UDim2.fromScale(0.03, 0.3) }
		)
		local timerLabel = label(frame, {
			Text = "--:--:--",
			Font = theme.Fonts.Mono,
			Size = UDim2.fromScale(0.9, 0.3),
			Position = UDim2.fromScale(0.05, 0.58),
			TextColor3 = c.Primary,
		})
		table.insert(unlockerScreens, { frame = frame, title = titleLabel, status = statusLabel, timer = timerLabel })
	end

	-- Chest odds board (right wall).
	do
		local _, frame = board(L(BOARD_X, 9, -20) * CFrame.Angles(0, math.pi / 2, 0), Vector2.new(10, 9), folder, c.Primary)
		label(frame, {
			Text = string.upper(w.Chest) .. " DROPS",
			Size = UDim2.fromScale(0.94, 0.16),
			Position = UDim2.fromScale(0.03, 0.03),
			TextColor3 = c.Primary,
		})
		local total = 0
		for _, rarity in Economy.CHEST_RARITIES do
			total += Economy.CHEST_INFO[rarity].weight
		end
		for i, rarity in Economy.CHEST_RARITIES do
			local chance = Economy.CHEST_INFO[rarity].weight / total * 100
			label(frame, {
				Text = string.format(
					"%s  %s%%",
					rarity,
					if chance < 1 then string.format("%.1f", chance) else tostring(math.floor(chance + 0.5))
				),
				Font = theme.Fonts.Body,
				Size = UDim2.fromScale(0.9, 0.13),
				Position = UDim2.fromScale(0.05, 0.08 + i * 0.15),
				TextColor3 = c.Rarity[rarity],
			})
		end
	end

	-- Free reward pad + board.
	pad("Free", 42, -34, 9, 9, c.Good, w.Free, "")
	do
		local _, frame = board(L(BOARD_X, 9, -38) * CFrame.Angles(0, math.pi / 2, 0), Vector2.new(10, 7), folder, c.Good)
		label(
			frame,
			{ Text = "🎁 " .. w.Free, Size = UDim2.fromScale(0.94, 0.24), Position = UDim2.fromScale(0.03, 0.05), TextColor3 = c.Good }
		)
		labels.FreeStatus = label(frame, { Text = "", Size = UDim2.fromScale(0.9, 0.34), Position = UDim2.fromScale(0.05, 0.33) })
		labels.FreeDesc = label(frame, {
			Text = "Cash + " .. Economy.FREE_REWARD_GEMS .. " " .. w.Gem,
			Font = theme.Fonts.Body,
			Size = UDim2.fromScale(0.9, 0.2),
			Position = UDim2.fromScale(0.05, 0.72),
			TextColor3 = c.TextDim,
		})
	end

	-- Plot lights.
	for _, pos in { Vector3.new(-25, 26, -20), Vector3.new(25, 26, -20), Vector3.new(-25, 26, 20), Vector3.new(25, 26, 20) } do
		local lamp = P({
			Name = "Lamp",
			Size = Vector3.new(4, 0.6, 4),
			CFrame = L(pos.X, pos.Y, pos.Z),
			Color = c.Neon,
			Material = Enum.Material.Neon,
		})
		lamp.CanCollide = false
		local light = Instance.new("SpotLight")
		light.Face = Enum.NormalId.Bottom
		light.Angle = 120
		light.Range = 40
		light.Brightness = 2
		light.Color = Color3.new(1, 1, 1):Lerp(c.Neon, 0.25)
		light.Parent = lamp
	end

	labels.Owner = ownerLabel

	local unitFolder = Instance.new("Folder")
	unitFolder.Name = "Units"
	unitFolder.Parent = folder
	local orbFolder = Instance.new("Folder")
	orbFolder.Name = "Orbs"
	orbFolder.Parent = folder
	local chestFolder = Instance.new("Folder")
	chestFolder.Name = "Chests"
	chestFolder.Parent = folder

	return {
		index = index,
		cframe = cf,
		folder = folder,
		unitFolder = unitFolder,
		orbFolder = orbFolder,
		chestFolder = chestFolder,
		spawn = L(0, 4, -44) * CFrame.Angles(0, math.pi, 0),
		slots = ordered,
		orbArea = { minX = -29, maxX = 29, minZ = -20, maxZ = 18 },
		pads = pads,
		padByName = padByName,
		labels = labels,
		ownerImage = ownerImage,
		unlockerScreens = unlockerScreens,
	}
end

function WorldBuilder.build(themeModule: any): World
	theme = themeModule
	mapFolder = Instance.new("Folder")
	mapFolder.Name = "Map"
	mapFolder.Parent = Workspace

	setupLighting()
	local ranking = buildHub()
	local plots = {}
	for i = 1, PLOT_COUNT do
		table.insert(plots, buildPlot(i))
	end
	return { plots = plots, ranking = ranking }
end

WorldBuilder.label = function(parent: Instance, props: { [string]: any }): TextLabel
	return label(parent, props)
end
WorldBuilder.billboard = billboard

return WorldBuilder
