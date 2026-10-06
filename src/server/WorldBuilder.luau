--[[
	WorldBuilder: generates the whole map from parts when the server starts.

	Six plots sit around a central hub plaza with a ranking tower. Every plot
	uses the plot-local geometry in PlotLayout (see the diagram there): display
	bleachers at the back, a sunken orb pool with two ramps right in front of
	them, the buy row in front of the pool and the stations along the side walls.

	Plot-local axes: Z = toward the back wall, Y = up, and +X is on the left of
	a player walking in from the hub (Roblox is right-handed).
]]

local Lighting = game:GetService("Lighting")
local Workspace = game:GetService("Workspace")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Economy = require(ReplicatedStorage.Shared.Economy)
local Layout = require(script.Parent.PlotLayout)

local WorldBuilder = {}

local PLOT_COUNT = 6
local PLOT_HALF = Layout.PLOT_HALF
-- Wall boards sit in front of the wall pillars (pillar faces are at PLOT_HALF - 2.5).
local BOARD_X = PLOT_HALF - 3.4
local WALL_HEIGHT = 30

-- Rotations for cylinders (a Roblox cylinder's axis is its X axis).
local UPRIGHT = CFrame.Angles(0, 0, math.rad(90))
local ALONG_Z = CFrame.Angles(0, math.rad(90), 0)

local BLACK = Color3.new(0, 0, 0)
local WHITE = Color3.new(1, 1, 1)

export type Rect = Layout.Rect

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
	-- Plot-local rectangle on the pool floor where dropped orbs land.
	orbArea: Rect,
	-- Plot-local Y of the pool floor's walkable surface (orbs rest on it).
	orbFloorY: number,
	-- Plot-local footprint of the sunken pool, ramps included.
	pool: Rect,
	-- Plot-local floor rectangles where floor crates may spawn (never in the pool).
	chestAreas: { Rect },
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

-- Primitives ------------------------------------------------------------------------

local function make(className: string, props: { [string]: any }): BasePart
	local p = Instance.new(className) :: BasePart
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

local function part(props: { [string]: any }): BasePart
	return make("Part", props)
end

local function pointLight(parent: Instance, color: Color3, range: number, brightness: number?)
	local light = Instance.new("PointLight")
	light.Color = color
	light.Range = range
	light.Brightness = brightness or 1.5
	light.Parent = parent
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

local function decorColor(key: string, fallback: Color3): Color3
	return theme.Colors[key] or fallback
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

-- Hub ----------------------------------------------------------------------------------

local function plotCFrame(index: number): CFrame
	local row = if index <= 3 then 1 else -1
	local col = ((index - 1) % 3) - 1
	-- Face the hub: the plot's -Z (its entrance) points toward z = 0. Same result
	-- as CFrame.lookAt, but exact everywhere (Lune's lookAt, used by the preview,
	-- flips this case).
	return CFrame.new(col * 130, 0, row * 150) * CFrame.Angles(0, if row == 1 then 0 else math.pi, 0)
end

-- Splits the square [-half, half]^2 into rectangles that leave the given holes open
-- (band decomposition along Z; holes must not overlap each other).
local function rectsAround(half: number, holes: { Rect }): { Rect }
	local zs = { -half, half }
	for _, hole in holes do
		table.insert(zs, hole.minZ)
		table.insert(zs, hole.maxZ)
	end
	table.sort(zs)
	local out: { Rect } = {}
	for i = 1, #zs - 1 do
		local z0, z1 = zs[i], zs[i + 1]
		if z1 - z0 > 1e-3 then
			local cuts = {}
			for _, hole in holes do
				if hole.minZ < z1 and hole.maxZ > z0 then
					table.insert(cuts, hole)
				end
			end
			table.sort(cuts, function(a, b)
				return a.minX < b.minX
			end)
			local x = -half
			for _, cut in cuts do
				if cut.minX > x then
					table.insert(out, Layout.rect(x, cut.minX, z0, z1))
				end
				x = math.max(x, cut.maxX)
			end
			if x < half then
				table.insert(out, Layout.rect(x, half, z0, z1))
			end
		end
	end
	return out
end

local function buildHub(): { TextLabel }
	local c = theme.Colors
	-- The ground is cut open under every plot's sunken pool.
	local holes: { Rect } = {}
	for i = 1, PLOT_COUNT do
		local cf = plotCFrame(i)
		local pool = Layout.POOL
		local a = cf:PointToWorldSpace(Vector3.new(pool.minX, 0, pool.minZ))
		local b = cf:PointToWorldSpace(Vector3.new(pool.maxX, 0, pool.maxZ))
		table.insert(holes, Layout.rect(math.min(a.X, b.X), math.max(a.X, b.X), math.min(a.Z, b.Z), math.max(a.Z, b.Z)))
	end
	for _, r in rectsAround(280, holes) do
		part({
			Name = "Ground",
			Size = Vector3.new(r.maxX - r.minX, 1, r.maxZ - r.minZ),
			CFrame = CFrame.new((r.minX + r.maxX) / 2, -0.6, (r.minZ + r.maxZ) / 2),
			Color = c.Hub,
			Material = Enum.Material.Concrete,
		})
	end

	-- Plaza: concentric discs with neon rings.
	local function disc(name: string, diameter: number, top: number, color: Color3, material: Enum.Material)
		part({
			Name = name,
			Shape = Enum.PartType.Cylinder,
			Size = Vector3.new(0.2, diameter, diameter),
			CFrame = CFrame.new(0, top - 0.1, 0) * UPRIGHT,
			Color = color,
			Material = material,
		})
	end
	disc("PlazaRing", 96, 0.05, c.Neon, Enum.Material.Neon)
	disc("Plaza", 94, 0.15, c.Floor, Enum.Material.Slate)
	disc("PlazaInnerRing", 64, 0.25, c.NeonAlt, Enum.Material.Neon)
	disc("PlazaInner", 62, 0.35, c.FloorAlt, Enum.Material.Marble)

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

	-- Central tower: stepped plinth, glowing edges, crown with a big orb on top.
	part({
		Name = "TowerStep",
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(0.8, 34, 34),
		CFrame = CFrame.new(0, 0.4, 0) * UPRIGHT,
		Color = c.Wall,
		Material = Enum.Material.Concrete,
	})
	part({
		Name = "TowerPlinth",
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(1.6, 29, 29),
		CFrame = CFrame.new(0, 0.8, 0) * UPRIGHT,
		Color = c.WallTrim,
		Material = Enum.Material.Metal,
	})
	part({
		Name = "TowerPlinthNeon",
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(0.3, 29.6, 29.6),
		CFrame = CFrame.new(0, 1.45, 0) * UPRIGHT,
		Color = c.NeonAlt,
		Material = Enum.Material.Neon,
	})
	part({ Name = "Tower", Size = Vector3.new(18, 34, 18), CFrame = CFrame.new(0, 17, 0), Color = c.Wall, Material = Enum.Material.Metal })
	for _, sx in { -1, 1 } do
		for _, sz in { -1, 1 } do
			part({
				Name = "TowerEdge",
				Size = Vector3.new(0.8, 32, 0.8),
				CFrame = CFrame.new(sx * 9, 17.5, sz * 9),
				Color = c.Neon,
				Material = Enum.Material.Neon,
			})
			part({
				Name = "TowerFinial",
				Shape = Enum.PartType.Ball,
				Size = Vector3.new(1.8, 1.8, 1.8),
				CFrame = CFrame.new(sx * 6.4, 42.2, sz * 6.4),
				Color = c.NeonAlt,
				Material = Enum.Material.Neon,
			})
		end
	end
	part({
		Name = "TowerBand",
		Size = Vector3.new(19, 1, 19),
		CFrame = CFrame.new(0, 32.6, 0),
		Color = c.WallTrim,
		Material = Enum.Material.Metal,
	})
	part({
		Name = "TowerCap",
		Size = Vector3.new(21, 1.5, 21),
		CFrame = CFrame.new(0, 34.5, 0),
		Color = c.Neon,
		Material = Enum.Material.Neon,
	})
	part({
		Name = "TowerUpper",
		Size = Vector3.new(13, 6, 13),
		CFrame = CFrame.new(0, 38.25, 0),
		Color = c.WallTrim,
		Material = Enum.Material.Metal,
	})
	part({
		Name = "TowerUpperNeon",
		Size = Vector3.new(13.6, 0.6, 13.6),
		CFrame = CFrame.new(0, 41.3, 0),
		Color = c.NeonAlt,
		Material = Enum.Material.Neon,
	})
	part({
		Name = "TowerSpire",
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(8, 2.4, 2.4),
		CFrame = CFrame.new(0, 45.5, 0) * UPRIGHT,
		Color = c.WallTrim,
		Material = Enum.Material.Metal,
	})
	local crownOrb = part({
		Name = "TowerOrb",
		Shape = Enum.PartType.Ball,
		Size = Vector3.new(7, 7, 7),
		CFrame = CFrame.new(0, 52.5, 0),
		Color = c.Orb,
		Material = Enum.Material.Neon,
	})
	pointLight(crownOrb, c.Orb, 60, 2)
	part({
		Name = "TowerHalo",
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(0.3, 13, 13),
		CFrame = CFrame.new(0, 52.5, 0) * CFrame.Angles(0, 0, math.rad(70)),
		Color = c.Orb,
		Material = Enum.Material.ForceField,
		Transparency = 0.2,
		CanCollide = false,
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

	-- Paths: an avenue from the plaza to each plot row, a cross avenue along the
	-- row and a short spur into every plot entrance. Neon edges show the way.
	local pathColor = c.FloorAlt:Lerp(c.Floor, 0.3)
	local function strip(name: string, cx: number, cz: number, sx: number, sz: number, y: number, color: Color3, material: Enum.Material)
		part({
			Name = name,
			Size = Vector3.new(sx, 0.1, sz),
			CFrame = CFrame.new(cx, y, cz),
			Color = color,
			Material = material,
		})
	end
	for _, row in { 1, -1 } do
		local entranceZ = 150 - PLOT_HALF
		local crossZ = row * 80
		-- Main avenue (plaza edge -> cross avenue).
		strip("Path", 0, row * 62.5, 10, 29, 0, pathColor, Enum.Material.Concrete)
		for _, x in { -4.75, 4.75 } do
			strip("PathEdge", x, row * 62.5, 0.4, 29, 0.02, c.Neon, Enum.Material.Neon)
		end
		-- Cross avenue.
		strip("Path", 0, crossZ, 270, 10, 0, pathColor, Enum.Material.Concrete)
		for _, sx in { -1, 1 } do
			strip("PathEdge", sx * 70, crossZ - row * 4.75, 130, 0.4, 0.02, c.NeonAlt, Enum.Material.Neon)
			strip("PathEdge", sx * 65, crossZ + row * 4.75, 120, 0.4, 0.02, c.NeonAlt, Enum.Material.Neon)
		end
		-- Spurs into each plot.
		-- From the cross avenue's outer edge to just inside the plot's front edge.
		local spurStart = 85
		local spurLength = entranceZ + 0.5 - spurStart
		local spurZ = row * (spurStart + spurLength / 2)
		for col = -1, 1 do
			strip("Path", col * 130, spurZ, 10, spurLength, 0, pathColor, Enum.Material.Concrete)
			for _, x in { -4.75, 4.75 } do
				strip("PathEdge", col * 130 + x, spurZ, 0.4, spurLength, 0.02, c.Neon, Enum.Material.Neon)
			end
		end

		-- Direction sign at the plaza edge, facing the tower.
		local first = if row == 1 then 1 else 4
		local signCF = CFrame.new(0, 9.5, row * 50) * CFrame.Angles(0, if row == 1 then 0 else math.pi, 0)
		part({
			Name = "SignPost",
			Size = Vector3.new(0.8, 8, 0.8),
			CFrame = CFrame.new(-6.5, 4, row * 50.6),
			Color = c.WallTrim,
			Material = Enum.Material.Metal,
		})
		part({
			Name = "SignPost",
			Size = Vector3.new(0.8, 8, 0.8),
			CFrame = CFrame.new(6.5, 4, row * 50.6),
			Color = c.WallTrim,
			Material = Enum.Material.Metal,
		})
		local _, signFrame = board(signCF, Vector2.new(15, 4), mapFolder, c.Primary)
		label(signFrame, {
			Text = string.format("PLOTS %d · %d · %d", first, first + 1, first + 2),
			Size = UDim2.fromScale(0.94, 0.56),
			Position = UDim2.fromScale(0.03, 0.06),
			TextColor3 = c.Primary,
		})
		label(signFrame, {
			Text = "Your plot's arch shows your name",
			Font = theme.Fonts.Body,
			Size = UDim2.fromScale(0.9, 0.3),
			Position = UDim2.fromScale(0.05, 0.64),
		})

		-- Street lights along the avenues.
		local posts = {
			Vector3.new(-8, 0, row * 52),
			Vector3.new(8, 0, row * 52),
			Vector3.new(-8, 0, row * 68),
			Vector3.new(8, 0, row * 68),
		}
		for _, x in { -100, -65, -30, 30, 65, 100 } do
			table.insert(posts, Vector3.new(x, 0, crossZ - row * 7))
		end
		for i, pos in posts do
			part({
				Name = "StreetPost",
				Size = Vector3.new(0.7, 10, 0.7),
				CFrame = CFrame.new(pos + Vector3.new(0, 5, 0)),
				Color = c.WallTrim,
				Material = Enum.Material.Metal,
			})
			local bulb = part({
				Name = "StreetBulb",
				Shape = Enum.PartType.Ball,
				Size = Vector3.new(1.8, 1.8, 1.8),
				CFrame = CFrame.new(pos + Vector3.new(0, 10.6, 0)),
				Color = if i % 2 == 0 then c.Neon else c.NeonAlt,
				Material = Enum.Material.Neon,
			})
			if i > 4 then
				pointLight(bulb, bulb.Color, 26, 1.2)
			end
		end
	end

	-- Plaza light posts.
	for i = 0, 7 do
		local angle = (i + 0.5) * math.pi / 4
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
		pointLight(bulb, bulb.Color, 30, 1.5)
	end
	return rankingLabels
end

-- Plot ----------------------------------------------------------------------------------

type Builder = {
	cf: CFrame,
	folder: Folder,
	c: any,
	L: (x: number, y: number, z: number) -> CFrame,
	P: (props: { [string]: any }) -> BasePart,
	W: (props: { [string]: any }) -> BasePart,
}

-- Floor slabs around the pool hole, a tile grid and the entrance runner.
local function buildFloor(B: Builder)
	local c = B.c
	local pool = Layout.POOL
	local floorMaterial = if theme.Decor == "factory" then Enum.Material.DiamondPlate else Enum.Material.Slate
	local function slab(minX: number, maxX: number, minZ: number, maxZ: number)
		B.P({
			Name = "Floor",
			Size = Vector3.new(maxX - minX, 1, maxZ - minZ),
			CFrame = B.L((minX + maxX) / 2, -0.5, (minZ + maxZ) / 2),
			Color = c.Floor,
			Material = floorMaterial,
		})
	end
	slab(-PLOT_HALF, PLOT_HALF, -PLOT_HALF, pool.minZ)
	slab(-PLOT_HALF, PLOT_HALF, pool.maxZ, PLOT_HALF)
	slab(-PLOT_HALF, pool.minX, pool.minZ, pool.maxZ)
	slab(pool.maxX, PLOT_HALF, pool.minZ, pool.maxZ)

	-- Tile grid (grout lines every 8 studs; none over the pool or under the bleachers).
	local grout = c.Floor:Lerp(BLACK, 0.35)
	local function line(cx: number, cz: number, sx: number, sz: number)
		local p = B.P({
			Name = "Grout",
			Size = Vector3.new(sx, 0.04, sz),
			CFrame = B.L(cx, 0.02, cz),
			Color = grout,
		})
		p.CanCollide = false
	end
	for x = -48, 48, 8 do
		if math.abs(x) < pool.maxX then
			line(x, (-PLOT_HALF + pool.minZ) / 2, 0.3, pool.minZ + PLOT_HALF)
		else
			line(x, (-PLOT_HALF + 30) / 2, 0.3, 30 + PLOT_HALF)
		end
	end
	for z = -48, 24, 8 do
		if z < pool.minZ then
			line(0, z, PLOT_HALF * 2, 0.3)
		else
			for _, side in { -1, 1 } do
				line(side * (pool.maxX + PLOT_HALF) / 2, z, PLOT_HALF - pool.maxX, 0.3)
			end
		end
	end

	-- Entrance runner from the arch to the merge pad.
	local runnerEnd = Layout.PADS.Merge.z - Layout.PADS.Merge.sizeZ / 2 - 1
	local runnerLength = runnerEnd + PLOT_HALF
	local runnerZ = (-PLOT_HALF + runnerEnd) / 2
	local factory = theme.Decor == "factory"
	local runner = B.P({
		Name = "Runner",
		Size = Vector3.new(8, 0.06, runnerLength),
		CFrame = B.L(0, 0.03, runnerZ),
		Color = if factory then decorColor("Belt", c.WallTrim) else c.NeonAlt:Lerp(BLACK, 0.55),
		Material = if factory then Enum.Material.DiamondPlate else Enum.Material.Fabric,
	})
	runner.CanCollide = false
	for _, x in { -4.2, 4.2 } do
		local edge = B.P({
			Name = "RunnerEdge",
			Size = Vector3.new(0.5, 0.08, runnerLength),
			CFrame = B.L(x, 0.04, runnerZ),
			Color = if factory then decorColor("Hazard", c.Secondary) else c.Neon,
			Material = Enum.Material.Neon,
		})
		edge.CanCollide = false
	end
end

local function buildWalls(B: Builder)
	local c = B.c
	local L, P = B.L, B.P
	P({
		Name = "WallBack",
		Size = Vector3.new(PLOT_HALF * 2, WALL_HEIGHT, 1),
		CFrame = L(0, WALL_HEIGHT / 2, PLOT_HALF),
		Color = c.Wall,
		Material = Enum.Material.Brick,
	})
	P({
		Name = "BackTrim",
		Size = Vector3.new(PLOT_HALF * 2, 1, 1.4),
		CFrame = L(0, WALL_HEIGHT, PLOT_HALF),
		Color = c.WallTrim,
		Material = Enum.Material.Metal,
	})
	P({
		Name = "Wainscot",
		Size = Vector3.new(PLOT_HALF * 2 - 2, 5, 0.4),
		CFrame = L(0, 2.5, PLOT_HALF - 0.7),
		Color = c.WallTrim,
		Material = Enum.Material.Metal,
	})
	P({
		Name = "WainscotNeon",
		Size = Vector3.new(PLOT_HALF * 2 - 2, 0.35, 0.5),
		CFrame = L(0, 5.1, PLOT_HALF - 0.7),
		Color = c.NeonAlt,
		Material = Enum.Material.Neon,
	})
	for side = -1, 1, 2 do
		P({
			Name = "WallSide",
			Size = Vector3.new(1, WALL_HEIGHT, PLOT_HALF * 2),
			CFrame = L(side * PLOT_HALF, WALL_HEIGHT / 2, 0),
			Color = c.Wall,
			Material = Enum.Material.Brick,
		})
		P({
			Name = "WallTrim",
			Size = Vector3.new(1.4, 1, PLOT_HALF * 2),
			CFrame = L(side * PLOT_HALF, WALL_HEIGHT, 0),
			Color = c.WallTrim,
			Material = Enum.Material.Metal,
		})
		P({
			Name = "Wainscot",
			Size = Vector3.new(0.4, 5, PLOT_HALF * 2),
			CFrame = L(side * (PLOT_HALF - 0.7), 2.5, 0),
			Color = c.WallTrim,
			Material = Enum.Material.Metal,
		})
		P({
			Name = "WainscotNeon",
			Size = Vector3.new(0.5, 0.35, PLOT_HALF * 2),
			CFrame = L(side * (PLOT_HALF - 0.7), 5.1, 0),
			Color = c.NeonAlt,
			Material = Enum.Material.Neon,
		})
		for z = -44, 44, 22 do
			P({
				Name = "Pillar",
				Size = Vector3.new(3, WALL_HEIGHT, 3),
				CFrame = L(side * (PLOT_HALF - 1), WALL_HEIGHT / 2, z),
				Color = c.WallTrim,
				Material = Enum.Material.Metal,
			})
			P({
				Name = "PillarNeon",
				Size = Vector3.new(0.4, WALL_HEIGHT - 8, 0.6),
				CFrame = L(side * (PLOT_HALF - 2.6), WALL_HEIGHT / 2 + 1, z),
				Color = c.Neon,
				Material = Enum.Material.Neon,
			})
		end
		-- Back-wall pillars beside the bleachers.
		P({
			Name = "Pillar",
			Size = Vector3.new(3, WALL_HEIGHT, 3),
			CFrame = L(side * 46, WALL_HEIGHT / 2, PLOT_HALF - 1),
			Color = c.WallTrim,
			Material = Enum.Material.Metal,
		})
		P({
			Name = "PillarNeon",
			Size = Vector3.new(0.6, WALL_HEIGHT - 8, 0.4),
			CFrame = L(side * 46, WALL_HEIGHT / 2 + 1, PLOT_HALF - 2.6),
			Color = c.Neon,
			Material = Enum.Material.Neon,
		})
		-- Low front wall either side of the entrance arch.
		local frontLength = PLOT_HALF - 18
		local frontX = side * (18 + frontLength / 2)
		P({
			Name = "FrontWall",
			Size = Vector3.new(frontLength, 4, 1),
			CFrame = L(frontX, 2, -PLOT_HALF),
			Color = c.Wall,
			Material = Enum.Material.Brick,
		})
		P({
			Name = "FrontWallCap",
			Size = Vector3.new(frontLength + 0.4, 0.6, 1.6),
			CFrame = L(frontX, 4.3, -PLOT_HALF),
			Color = c.WallTrim,
			Material = Enum.Material.Metal,
		})
		P({
			Name = "FrontWallNeon",
			Size = Vector3.new(frontLength, 0.3, 0.2),
			CFrame = L(frontX, 3.3, -PLOT_HALF - 0.55),
			Color = c.NeonAlt,
			Material = Enum.Material.Neon,
		})
		P({
			Name = "CornerPost",
			Size = Vector3.new(3, 7, 3),
			CFrame = L(side * (PLOT_HALF - 1), 3.5, -PLOT_HALF),
			Color = c.WallTrim,
			Material = Enum.Material.Metal,
		})
		-- Wall lamps on the middle pillars and the back pillars.
		local lampSpots = {
			{ L(side * (PLOT_HALF - 4), 24, -22), Vector3.new(3, 0.6, 1) },
			{ L(side * (PLOT_HALF - 4), 24, 22), Vector3.new(3, 0.6, 1) },
			{ L(side * 46, 24, PLOT_HALF - 4), Vector3.new(1, 0.6, 3) },
		}
		for _, spot in lampSpots do
			P({ Name = "LampArm", Size = spot[2], CFrame = spot[1], Color = c.WallTrim, Material = Enum.Material.Metal })
			local lamp = P({
				Name = "Lamp",
				Size = Vector3.new(2.6, 0.7, 2.6),
				CFrame = spot[1] * CFrame.new(0, -0.5, 0),
				Color = WHITE:Lerp(c.Neon, 0.35),
				Material = Enum.Material.Neon,
			})
			lamp.CanCollide = false
			local light = Instance.new("SpotLight")
			light.Face = Enum.NormalId.Bottom
			light.Angle = 120
			light.Range = 40
			light.Brightness = 2
			light.Color = WHITE:Lerp(c.Neon, 0.25)
			light.Parent = lamp
		end
	end
end

-- Sunken pool with glowing floor, rim walls, coping, railings and two ramps.
local function buildPool(B: Builder): BasePart
	local c = B.c
	local L, P, W = B.L, B.P, B.W
	local pool = Layout.POOL
	local width = pool.maxX - pool.minX
	local depth = pool.maxZ - pool.minZ
	local cx = (pool.minX + pool.maxX) / 2
	local cz = (pool.minZ + pool.maxZ) / 2
	local floorY = Layout.POOL_FLOOR_Y

	-- Floor layers: dim neon glow under tinted glass, with a faint shimmer on top.
	P({
		Name = "PoolGlow",
		Size = Vector3.new(width, 0.4, depth),
		CFrame = L(cx, floorY - 0.6, cz),
		Color = c.Orb:Lerp(BLACK, 0.68),
		Material = Enum.Material.Neon,
	})
	for i = 1, 3 do
		local z = pool.minZ + depth * i / 4
		local p = P({
			Name = "PoolTileLine",
			Size = Vector3.new(width - 1, 0.06, 0.25),
			CFrame = L(cx, floorY - 0.37, z),
			Color = c.Orb,
			Material = Enum.Material.Neon,
		})
		p.CanCollide = false
	end
	for i = -2, 2 do
		local p = P({
			Name = "PoolTileLine",
			Size = Vector3.new(0.25, 0.06, depth - 1),
			CFrame = L(cx + i * width / 6, floorY - 0.37, cz),
			Color = c.Orb,
			Material = Enum.Material.Neon,
		})
		p.CanCollide = false
	end
	local glass = P({
		Name = "PoolFloor",
		Size = Vector3.new(width, 0.4, depth),
		CFrame = L(cx, floorY - 0.2, cz),
		Color = c.Orb:Lerp(c.PanelDark, 0.55),
		Material = Enum.Material.Glass,
		Transparency = 0.25,
		Reflectance = 0.05,
	})
	local sheen = P({
		Name = "PoolSheen",
		Size = Vector3.new(width - 0.4, 0.1, depth - 0.4),
		CFrame = L(cx, floorY + 0.06, cz),
		Color = c.Orb:Lerp(BLACK, 0.65),
		Material = Enum.Material.ForceField,
		Transparency = 0.6,
	})
	sheen.CanCollide = false
	sheen.CanQuery = false

	-- Rim walls (under the floor slabs) with a neon light line just below the edge.
	local wallTop = -1
	local wallBottom = floorY - 0.8
	local wallH = wallTop - wallBottom
	local wallY = (wallTop + wallBottom) / 2
	local wallColor = c.Wall:Lerp(c.Orb, 0.12)
	P({
		Name = "PoolWall",
		Size = Vector3.new(width + 2, wallH, 1),
		CFrame = L(cx, wallY, pool.minZ - 0.5),
		Color = wallColor,
		Material = Enum.Material.Marble,
	})
	P({
		Name = "PoolWall",
		Size = Vector3.new(width + 2, wallH, 1),
		CFrame = L(cx, wallY, pool.maxZ + 0.5),
		Color = wallColor,
		Material = Enum.Material.Marble,
	})
	for _, side in { -1, 1 } do
		P({
			Name = "PoolWall",
			Size = Vector3.new(1, wallH, depth),
			CFrame = L(side * (width / 2 + 0.5) + cx, wallY, cz),
			Color = wallColor,
			Material = Enum.Material.Marble,
		})
	end
	local function glowLine(x: number, z: number, sx: number, sz: number)
		local p = P({
			Name = "PoolRimLight",
			Size = Vector3.new(sx, 0.3, sz),
			CFrame = L(x, -1.4, z),
			Color = c.Neon,
			Material = Enum.Material.Neon,
		})
		p.CanCollide = false
	end
	glowLine(cx, pool.minZ + 0.05, width, 0.2)
	glowLine(cx, pool.maxZ - 0.05, width, 0.2)
	glowLine(pool.minX + 0.05, cz, 0.2, depth)
	glowLine(pool.maxX - 0.05, cz, 0.2, depth)

	-- Coping around the edge, open at the two ramp mouths.
	local copingColor = c.WallTrim:Lerp(WHITE, 0.12)
	local function coping(x: number, z: number, sx: number, sz: number)
		P({
			Name = "PoolCoping",
			Size = Vector3.new(sx, 0.45, sz),
			CFrame = L(x, 0.225, z),
			Color = copingColor,
			Material = Enum.Material.Metal,
		})
		local strip = P({
			Name = "PoolCopingNeon",
			Size = Vector3.new(if sx > sz then sx else 0.3, 0.08, if sx > sz then 0.3 else sz),
			CFrame = L(x, 0.48, z),
			Color = c.Orb,
			Material = Enum.Material.Neon,
		})
		strip.CanCollide = false
	end
	local rampA = Layout.RAMPS[1].rect
	coping(cx, pool.minZ - 0.5, width + 2.4, 1.4)
	coping(cx, pool.maxZ + 0.5, width + 2.4, 1.4)
	for _, side in { -1, 1 } do
		local x = side * (width / 2 + 0.5) + cx
		local frontLen = rampA.minZ - (pool.minZ - 1.2)
		local backLen = (pool.maxZ + 1.2) - rampA.maxZ
		coping(x, pool.minZ - 1.2 + frontLen / 2, 1.4, frontLen)
		coping(x, rampA.maxZ + backLen / 2, 1.4, backLen)
	end

	-- Low railings on the open edges (front, and the sides beside the ramps).
	local railColor = c.WallTrim
	local function post(x: number, z: number)
		P({
			Name = "RailPost",
			Size = Vector3.new(0.5, 2.4, 0.5),
			CFrame = L(x, 0.45 + 1.2, z),
			Color = railColor,
			Material = Enum.Material.Metal,
		})
	end
	local function rail(x: number, z: number, sx: number, sz: number)
		P({
			Name = "Rail",
			Size = Vector3.new(sx, 0.35, sz),
			CFrame = L(x, 2.85, z),
			Color = c.Neon,
			Material = Enum.Material.Neon,
		})
	end
	local frontZ = pool.minZ - 0.5
	local railHalf = width / 2 + 0.5
	for i = 0, 8 do
		post(cx - railHalf + i * (railHalf * 2) / 8, frontZ)
	end
	rail(cx, frontZ, railHalf * 2, 0.35)
	for _, side in { -1, 1 } do
		local x = cx + side * railHalf
		local mouthFront = rampA.minZ - 0.4
		local mouthBack = rampA.maxZ + 0.4
		local backZ = pool.maxZ + 0.5
		post(x, mouthFront)
		post(x, mouthBack)
		post(x, backZ)
		rail(x, (frontZ + mouthFront) / 2, 0.35, mouthFront - frontZ)
		rail(x, (mouthBack + backZ) / 2, 0.35, backZ - mouthBack)
	end

	-- Ramps: wedges whose high end meets the floor at the pool's side edges.
	local rampColor = c.WallTrim:Lerp(WHITE, 0.3)
	for _, ramp in Layout.RAMPS do
		local r = ramp.rect
		local side = ramp.side
		local length = r.maxX - r.minX
		local rampWidth = r.maxZ - r.minZ
		local rx = (r.minX + r.maxX) / 2
		local rz = (r.minZ + r.maxZ) / 2
		local height = -floorY
		W({
			Name = "PoolRamp",
			Size = Vector3.new(rampWidth, height, length),
			-- A wedge's high end is its +Z face: turn it to face the pool's outer edge.
			CFrame = L(rx, floorY + height / 2, rz) * CFrame.Angles(0, side * math.pi / 2, 0),
			Color = rampColor,
			Material = Enum.Material.DiamondPlate,
		})
		local top = Vector3.new(if side > 0 then r.maxX else r.minX, 0, 0)
		local bottom = Vector3.new(if side > 0 then r.minX else r.maxX, floorY, 0)
		local dir = (bottom - top).Unit
		local normal = Vector3.new(-dir.Y * (if side > 0 then -1 else 1), math.abs(dir.X), 0).Unit
		local slopeLength = (bottom - top).Magnitude
		-- Rotation that lays a part's X axis along the slope (plot-local).
		local tilt = CFrame.Angles(0, 0, math.atan2(dir.Y, dir.X))
		-- Neon edges along both sides of the slope.
		for _, ez in { r.minZ + 0.3, r.maxZ - 0.3 } do
			local mid = (top + bottom) / 2 + Vector3.new(0, 0, ez) + normal * 0.08
			local edge = P({
				Name = "RampEdge",
				Size = Vector3.new(slopeLength, 0.14, 0.4),
				CFrame = B.cf * CFrame.new(mid) * tilt,
				Color = c.Neon,
				Material = Enum.Material.Neon,
			})
			edge.CanCollide = false
		end
		-- Grip treads across the slope.
		for i = 1, 3 do
			local at = top + (bottom - top) * (i / 4) + Vector3.new(0, 0, rz) + normal * 0.06
			local tread = P({
				Name = "RampTread",
				Size = Vector3.new(0.35, 0.1, rampWidth - 1.6),
				CFrame = B.cf * CFrame.new(at) * tilt,
				Color = c.NeonAlt,
				Material = Enum.Material.Neon,
			})
			tread.CanCollide = false
		end
		-- Glowing entry mat on the floor at the ramp mouth.
		local mat = P({
			Name = "RampEntry",
			Size = Vector3.new(3.6, 0.06, rampWidth),
			CFrame = L(side * (pool.maxX + 1.2 + 1.8), 0.03, rz),
			Color = c.Orb:Lerp(BLACK, 0.25),
			Material = Enum.Material.Neon,
		})
		mat.CanCollide = false
		-- Sign at the ramp mouth, facing the entrance.
		local signX = side * (pool.maxX + 3.2)
		P({
			Name = "PoolSignPost",
			Size = Vector3.new(0.5, 6.6, 0.5),
			CFrame = L(signX, 3.3, rampA.minZ - 1.2),
			Color = c.WallTrim,
			Material = Enum.Material.Metal,
		})
		local _, frame = board(L(signX, 7.6, rampA.minZ - 1.2), Vector2.new(6, 2.2), B.folder, c.Orb)
		label(frame, {
			Text = "▼ " .. string.upper(theme.Words.Orb) .. " POOL",
			Size = UDim2.fromScale(0.94, 0.8),
			Position = UDim2.fromScale(0.03, 0.1),
			TextColor3 = c.Orb:Lerp(WHITE, 0.3),
		})
	end
	return glass
end

-- Display bleachers: three stepped rows of ten podiums. Returns the slots ordered
-- front row first, centre-out, so the best units are the most visible.
local function buildShelves(B: Builder): { CFrame }
	local c = B.c
	local L, P = B.L, B.P
	local s = Layout.SHELF
	local factory = theme.Decor == "factory"
	local slots: { CFrame } = {}
	for row = 0, s.rows - 1 do
		local top = s.firstTop + row * s.rowRise
		local z = s.firstZ + row * s.rowDepth
		P({
			Name = "Shelf",
			Size = Vector3.new(s.width, top, s.rowDepth),
			CFrame = L(0, top / 2, z),
			Color = c.WallTrim,
			Material = Enum.Material.Metal,
		})
		P({
			Name = "ShelfDeck",
			Size = Vector3.new(s.width - 0.4, 0.2, s.rowDepth - 0.3),
			CFrame = L(0, top + 0.1, z + 0.15),
			Color = if factory then c.FloorAlt else c.NeonAlt:Lerp(BLACK, 0.62),
			Material = if factory then Enum.Material.DiamondPlate else Enum.Material.Fabric,
		})
		P({
			Name = "ShelfNeon",
			Size = Vector3.new(s.width, 0.3, 0.4),
			CFrame = L(0, top - 0.15, z - s.rowDepth / 2 - 0.05),
			Color = if row % 2 == 0 then c.Neon else c.NeonAlt,
			Material = Enum.Material.Neon,
		})
		for col = 0, s.cols - 1 do
			local x = -(s.cols - 1) * s.spacing / 2 + col * s.spacing
			P({
				Name = "Podium",
				Shape = Enum.PartType.Cylinder,
				Size = Vector3.new(0.35, 4.4, 4.4),
				CFrame = L(x, top + 0.2 + 0.175, z) * UPRIGHT,
				Color = c.Wall:Lerp(WHITE, 0.12),
				Material = Enum.Material.Metal,
			})
			table.insert(slots, L(x, top + 0.55, z))
		end
	end
	-- Stepped end caps that follow the bleacher profile, each with a glowing top edge.
	for _, side in { -1, 1 } do
		local x = side * (s.width / 2 + 0.8)
		for row = 0, s.rows - 1 do
			local capH = s.firstTop + row * s.rowRise + 1.4
			local z = s.firstZ + row * s.rowDepth
			P({
				Name = "ShelfCap",
				Size = Vector3.new(1.6, capH, s.rowDepth),
				CFrame = L(x, capH / 2, z),
				Color = c.Wall,
				Material = Enum.Material.Metal,
			})
			P({
				Name = "ShelfCapNeon",
				Size = Vector3.new(1.8, 0.35, s.rowDepth + 0.1),
				CFrame = L(x, capH + 0.1, z),
				Color = if row % 2 == 0 then c.NeonAlt else c.Neon,
				Material = Enum.Material.Neon,
			})
		end
	end
	-- Banner on the back wall above the bleachers.
	local _, frame = board(L(0, 23, PLOT_HALF - 1.4), Vector2.new(30, 5), B.folder, c.NeonAlt)
	label(frame, {
		Text = theme.Icons.Unit .. "  YOUR " .. string.upper(theme.Words.Units) .. "  " .. theme.Icons.Unit,
		Size = UDim2.fromScale(0.94, 0.62),
		Position = UDim2.fromScale(0.03, 0.06),
		TextColor3 = c.Primary,
	})
	label(frame, {
		Text = "Every " .. theme.Words.Unit .. " drops " .. theme.Words.Orb .. " into the pool",
		Font = theme.Fonts.Body,
		Size = UDim2.fromScale(0.9, 0.26),
		Position = UDim2.fromScale(0.05, 0.7),
	})

	local ordered: { CFrame } = {}
	local order = { 5, 6, 4, 7, 3, 8, 2, 9, 1, 10 }
	for row = 0, s.rows - 1 do
		for _, col in order do
			table.insert(ordered, slots[row * s.cols + col])
		end
	end
	assert(#ordered == Economy.DISPLAY_SLOTS, "display slot count mismatch")
	return ordered
end

-- Machines ---------------------------------------------------------------------------------

local function buildConverter(B: Builder, x: number, z: number)
	local c = B.c
	local L, P = B.L, B.P
	P({ Name = "ConverterBase", Size = Vector3.new(7, 1.2, 7), CFrame = L(x, 0.6, z), Color = c.WallTrim, Material = Enum.Material.Metal })
	P({
		Name = "ConverterBaseNeon",
		Size = Vector3.new(7.2, 0.3, 7.2),
		CFrame = L(x, 1.05, z),
		Color = c.Secondary,
		Material = Enum.Material.Neon,
	})
	local tube = P({
		Name = "ConverterTube",
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(8, 5, 5),
		CFrame = L(x, 5.2, z) * UPRIGHT,
		Color = c.Orb,
		Material = Enum.Material.Glass,
		Transparency = 0.35,
	})
	tube.CanCollide = false
	local core = P({
		Name = "ConverterCore",
		Shape = Enum.PartType.Ball,
		Size = Vector3.new(3, 3, 3),
		CFrame = L(x, 5.2, z),
		Color = c.Orb,
		Material = Enum.Material.Neon,
	})
	core.CanCollide = false
	pointLight(core, c.Orb, 18)
	for _, y in { 2.2, 8.2 } do
		P({
			Name = "ConverterBand",
			Shape = Enum.PartType.Cylinder,
			Size = Vector3.new(0.4, 5.4, 5.4),
			CFrame = L(x, y, z) * UPRIGHT,
			Color = c.Secondary,
			Material = Enum.Material.Neon,
		})
	end
	P({
		Name = "ConverterCap",
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(1.2, 6, 6),
		CFrame = L(x, 9.8, z) * UPRIGHT,
		Color = c.WallTrim,
		Material = Enum.Material.Metal,
	})
	P({
		Name = "ConverterDome",
		Shape = Enum.PartType.Ball,
		Size = Vector3.new(4.2, 4.2, 4.2),
		CFrame = L(x, 10.4, z),
		Color = c.WallTrim:Lerp(WHITE, 0.15),
		Material = Enum.Material.Metal,
	})
	-- Intake slot facing the deposit pad.
	P({
		Name = "ConverterIntake",
		Size = Vector3.new(0.2, 0.7, 4),
		CFrame = L(x + 3.55, 0.6, z),
		Color = c.Orb,
		Material = Enum.Material.Neon,
	})
	-- Pipe to the processor behind it.
	local pipeColor = c.WallTrim:Lerp(WHITE, 0.25)
	local proc = Layout.MACHINES.Processor
	local pipeX = x - 1
	local pipeY = 11.6
	local endZ = (proc.minZ + proc.maxZ) / 2 - 4
	P({
		Name = "Pipe",
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(endZ - z, 1.1, 1.1),
		CFrame = L(pipeX, pipeY, (z + endZ) / 2) * ALONG_Z,
		Color = pipeColor,
		Material = Enum.Material.Metal,
	})
	P({
		Name = "PipeElbow",
		Shape = Enum.PartType.Ball,
		Size = Vector3.new(1.5, 1.5, 1.5),
		CFrame = L(pipeX, pipeY, endZ),
		Color = pipeColor,
		Material = Enum.Material.Metal,
	})
	P({
		Name = "Pipe",
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(pipeY - 6, 1.1, 1.1),
		CFrame = L(pipeX, (pipeY + 6) / 2, endZ) * UPRIGHT,
		Color = pipeColor,
		Material = Enum.Material.Metal,
	})
	P({
		Name = "PipeGlow",
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(0.5, 1.3, 1.3),
		CFrame = L(pipeX, pipeY, (z + endZ) / 2) * ALONG_Z,
		Color = c.Orb,
		Material = Enum.Material.Neon,
	})
end

local function buildProcessor(B: Builder)
	local c = B.c
	local L, P = B.L, B.P
	local r = Layout.MACHINES.Processor
	local x = (r.minX + r.maxX) / 2
	local z = (r.minZ + r.maxZ) / 2
	local w = r.maxX - r.minX
	local d = r.maxZ - r.minZ
	local front = r.maxX
	P({
		Name = "Processor",
		Size = Vector3.new(w, 6, d),
		CFrame = L(x, 3, z),
		Color = c.Wall:Lerp(BLACK, 0.2),
		Material = Enum.Material.Metal,
	})
	P({
		Name = "ProcessorPanel",
		Size = Vector3.new(0.3, 4.4, d - 1.6),
		CFrame = L(front + 0.1, 3.2, z),
		Color = c.PanelDark,
	})
	P({
		Name = "ProcessorTop",
		Size = Vector3.new(w + 0.3, 0.4, d + 0.3),
		CFrame = L(x, 6.2, z),
		Color = c.Primary,
		Material = Enum.Material.Neon,
	})
	for _, gz in { z - d / 2 + 3.4, z + d / 2 - 3.4 } do
		P({
			Name = "Gear",
			Shape = Enum.PartType.Cylinder,
			Size = Vector3.new(0.5, 3.6, 3.6),
			CFrame = L(front + 0.45, 3.2, gz),
			Color = c.WallTrim:Lerp(WHITE, 0.2),
			Material = Enum.Material.Metal,
		})
		P({
			Name = "GearHub",
			Shape = Enum.PartType.Cylinder,
			Size = Vector3.new(0.7, 1.4, 1.4),
			CFrame = L(front + 0.5, 3.2, gz),
			Color = c.Primary,
			Material = Enum.Material.Neon,
		})
	end
	for i = 0, 2 do
		local vent = P({
			Name = "ProcessorVent",
			Size = Vector3.new(0.2, 0.3, 3.6),
			CFrame = L(front + 0.3, 2.2 + i, z),
			Color = c.Orb,
			Material = Enum.Material.Neon,
		})
		vent.CanCollide = false
	end
end

local function buildVault(B: Builder)
	local c = B.c
	local L, P = B.L, B.P
	local r = Layout.MACHINES.Vault
	local x = (r.minX + r.maxX) / 2
	local z = (r.minZ + r.maxZ) / 2
	P({
		Name = "VaultBase",
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(2.4, 5, 5),
		CFrame = L(x, 1.2, z) * UPRIGHT,
		Color = c.WallTrim,
		Material = Enum.Material.Metal,
	})
	P({
		Name = "VaultRing",
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(0.3, 5.4, 5.4),
		CFrame = L(x, 2.3, z) * UPRIGHT,
		Color = c.Primary,
		Material = Enum.Material.Neon,
	})
	P({
		Name = "VaultArm",
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(3, 1, 1),
		CFrame = L(x, 3.8, z) * UPRIGHT,
		Color = c.WallTrim:Lerp(WHITE, 0.2),
		Material = Enum.Material.Metal,
	})
	-- The coin faces the plot centre and the entrance.
	local facing = CFrame.Angles(0, math.rad(60), 0)
	P({
		Name = "CoinRim",
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(1, 9, 9),
		CFrame = L(x, 9.3, z) * facing,
		Color = c.Primary:Lerp(BLACK, 0.3),
		Material = Enum.Material.Metal,
	})
	local coin = P({
		Name = "Coin",
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(1.3, 7.6, 7.6),
		CFrame = L(x, 9.3, z) * facing,
		Color = c.Primary,
		Material = Enum.Material.Neon,
	})
	coin.CanCollide = false
	pointLight(coin, c.Primary, 16, 1.2)
	for _, face in { Enum.NormalId.Right, Enum.NormalId.Left } do
		local gui = Instance.new("SurfaceGui")
		gui.Face = face
		gui.LightInfluence = 0
		gui.Parent = coin
		label(gui, { Text = "$", Size = UDim2.fromScale(1, 1), TextColor3 = c.PanelDark })
	end
	for i, spot in { Vector3.new(2.6, 0.9, -2.2), Vector3.new(2.2, 1.4, 2.6), Vector3.new(-1.2, 0.7, -3.2) } do
		P({
			Name = "CoinStack",
			Shape = Enum.PartType.Cylinder,
			Size = Vector3.new(spot.Y * 2, 1.7, 1.7),
			CFrame = L(x + spot.X, spot.Y, z + spot.Z) * UPRIGHT,
			Color = c.Primary:Lerp(BLACK, if i == 2 then 0.1 else 0.2),
			Material = Enum.Material.Metal,
		})
	end
end

local function buildUnlocker(B: Builder, rect: Rect, color: Color3)
	local c = B.c
	local L, P = B.L, B.P
	local z = (rect.minZ + rect.maxZ) / 2
	local depth = rect.maxZ - rect.minZ
	local bodyMinX = rect.minX + 2.5
	local bodyX = (bodyMinX + rect.maxX) / 2
	local bodyW = rect.maxX - bodyMinX
	local front = rect.minX
	P({
		Name = "Machine",
		Size = Vector3.new(bodyW, 13, depth),
		CFrame = L(bodyX, 6.5, z),
		Color = c.WallTrim,
		Material = Enum.Material.Metal,
	})
	for _, ez in { -1, 1 } do
		P({
			Name = "MachineEdge",
			Size = Vector3.new(0.3, 13, 0.3),
			CFrame = L(bodyMinX - 0.1, 6.5, z + ez * (depth / 2 - 0.15)),
			Color = color,
			Material = Enum.Material.Neon,
		})
		P({
			Name = "MachinePipe",
			Shape = Enum.PartType.Cylinder,
			Size = Vector3.new(12, 0.9, 0.9),
			CFrame = L(bodyX + 0.4, 6, z + ez * (depth / 2 + 0.45)) * UPRIGHT,
			Color = c.WallTrim:Lerp(WHITE, 0.25),
			Material = Enum.Material.Metal,
		})
		P({
			Name = "ChamberPost",
			Size = Vector3.new(2.5, 5, 0.6),
			CFrame = L(front + 1.25, 3.7, z + ez * (depth / 2 - 0.6)),
			Color = c.WallTrim,
			Material = Enum.Material.Metal,
		})
	end
	-- Display chamber in front of the body with a holographic crate inside.
	P({
		Name = "ChamberFloor",
		Size = Vector3.new(2.5, 1.2, depth - 0.6),
		CFrame = L(front + 1.25, 0.6, z),
		Color = c.WallTrim:Lerp(WHITE, 0.1),
		Material = Enum.Material.Metal,
	})
	P({
		Name = "ChamberRoof",
		Size = Vector3.new(2.7, 0.6, depth),
		CFrame = L(front + 1.25, 6.5, z),
		Color = color,
		Material = Enum.Material.Neon,
	})
	P({
		Name = "ChamberBack",
		Size = Vector3.new(0.2, 5, depth - 1.2),
		CFrame = L(bodyMinX - 0.05, 3.7, z),
		Color = c.PanelDark,
	})
	local glassPane = P({
		Name = "ChamberGlass",
		Size = Vector3.new(0.15, 5, depth - 1.2),
		CFrame = L(front + 0.1, 3.7, z),
		Color = color:Lerp(WHITE, 0.6),
		Material = Enum.Material.Glass,
		Transparency = 0.55,
	})
	glassPane.CanCollide = true
	local ring = P({
		Name = "HoloPad",
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(0.2, 2.8, 2.8),
		CFrame = L(front + 1.25, 1.3, z) * UPRIGHT,
		Color = color,
		Material = Enum.Material.Neon,
	})
	ring.CanCollide = false
	local holo = P({
		Name = "HoloCrate",
		Size = Vector3.new(1.8, 1.8, 2.4),
		CFrame = L(front + 1.25, 2.6, z) * CFrame.Angles(0, math.rad(20), 0),
		Color = color,
		Material = Enum.Material.ForceField,
		Transparency = 0.15,
	})
	holo.CanCollide = false
	-- Beacon.
	P({
		Name = "Beacon",
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(1.2, 2, 2),
		CFrame = L(bodyX, 13.6, z) * UPRIGHT,
		Color = c.WallTrim,
		Material = Enum.Material.Metal,
	})
	local bulb = P({
		Name = "BeaconLight",
		Shape = Enum.PartType.Ball,
		Size = Vector3.new(1.6, 1.6, 1.6),
		CFrame = L(bodyX, 14.6, z),
		Color = color,
		Material = Enum.Material.Neon,
	})
	pointLight(bulb, color, 16, 1.2)
end

-- Decor -----------------------------------------------------------------------------------

local function dumbbell(B: Builder, x: number, y: number, z: number, chrome: Color3, iron: Color3)
	B.P({
		Name = "DumbbellBar",
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(2.2, 0.35, 0.35),
		CFrame = B.L(x, y, z),
		Color = chrome,
		Material = Enum.Material.Metal,
	})
	for _, dx in { -0.9, 0.9 } do
		B.P({
			Name = "DumbbellHead",
			Shape = Enum.PartType.Cylinder,
			Size = Vector3.new(0.6, 1.1, 1.1),
			CFrame = B.L(x + dx, y, z),
			Color = iron,
			Material = Enum.Material.Metal,
		})
	end
end

local function barbell(B: Builder, x: number, y: number, z: number, length: number, chrome: Color3, plate: Color3)
	B.P({
		Name = "Barbell",
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(length, 0.3, 0.3),
		CFrame = B.L(x, y, z),
		Color = chrome,
		Material = Enum.Material.Metal,
	})
	for _, dx in { -1, 1 } do
		B.P({
			Name = "Plate",
			Shape = Enum.PartType.Cylinder,
			Size = Vector3.new(0.4, 2.6, 2.6),
			CFrame = B.L(x + dx * (length / 2 - 0.9), y, z),
			Color = plate,
			Material = Enum.Material.SmoothPlastic,
		})
		B.P({
			Name = "Plate",
			Shape = Enum.PartType.Cylinder,
			Size = Vector3.new(0.4, 1.9, 1.9),
			CFrame = B.L(x + dx * (length / 2 - 0.45), y, z),
			Color = plate:Lerp(WHITE, 0.15),
			Material = Enum.Material.SmoothPlastic,
		})
	end
end

local function mirror(B: Builder, side: number, z: number, width: number, chrome: Color3)
	local c = B.c
	B.P({
		Name = "MirrorFrame",
		Size = Vector3.new(0.3, 9.4, width + 0.6),
		CFrame = B.L(side * (PLOT_HALF - 1.05), 10, z),
		Color = c.NeonAlt,
		Material = Enum.Material.Neon,
	})
	B.P({
		Name = "Mirror",
		Size = Vector3.new(0.2, 8.8, width),
		CFrame = B.L(side * (PLOT_HALF - 1.25), 10, z),
		Color = chrome,
		Material = Enum.Material.Foil,
		Reflectance = 0.6,
	})
end

local function buildGymDecor(B: Builder)
	local c = B.c
	local L, P = B.L, B.P
	local chrome = decorColor("Chrome", Color3.fromRGB(200, 200, 210))
	local iron = decorColor("Iron", Color3.fromRGB(50, 50, 58))
	local rubber = decorColor("Rubber", Color3.fromRGB(28, 28, 32))
	local leather = decorColor("Leather", c.NeonAlt:Lerp(BLACK, 0.4))

	-- +X back corner: dumbbell rack, bench press, mirror.
	P({ Name = "GymMat", Size = Vector3.new(13, 0.1, 21), CFrame = L(45.5, 0.05, 42.5), Color = rubber, Material = Enum.Material.Rubber })
	P({ Name = "DumbbellRack", Size = Vector3.new(2.6, 2.2, 14), CFrame = L(50.8, 1.1, 42.5), Color = iron, Material = Enum.Material.Metal })
	P({
		Name = "DumbbellRackTrim",
		Size = Vector3.new(2.7, 0.2, 14.1),
		CFrame = L(50.8, 2.25, 42.5),
		Color = c.Neon,
		Material = Enum.Material.Neon,
	})
	for i = 0, 4 do
		dumbbell(B, 50.8, 2.9, 37 + i * 2.75, chrome, iron)
	end
	P({ Name = "BenchPad", Size = Vector3.new(2.2, 0.6, 6), CFrame = L(43, 1.7, 38.5), Color = leather, Material = Enum.Material.Fabric })
	for _, dz in { -2.4, 2.4 } do
		P({
			Name = "BenchLeg",
			Size = Vector3.new(1.8, 1.4, 0.4),
			CFrame = L(43, 0.7, 38.5 + dz),
			Color = iron,
			Material = Enum.Material.Metal,
		})
	end
	for _, dx in { -1.7, 1.7 } do
		P({
			Name = "BenchUpright",
			Size = Vector3.new(0.4, 4.4, 0.4),
			CFrame = L(43 + dx, 2.2, 41.4),
			Color = iron,
			Material = Enum.Material.Metal,
		})
	end
	barbell(B, 43, 4.1, 41.4, 8, chrome, c.Primary:Lerp(BLACK, 0.2))
	mirror(B, 1, 33.5, 13, chrome)

	-- -X back corner: squat rack, plate tree, kettlebells, mirror.
	P({ Name = "GymMat", Size = Vector3.new(13, 0.1, 21), CFrame = L(-45.5, 0.05, 42.5), Color = rubber, Material = Enum.Material.Rubber })
	for _, dx in { -2.6, 2.6 } do
		for _, dz in { -1.2, 1.2 } do
			P({
				Name = "RackPost",
				Size = Vector3.new(0.4, 8, 0.4),
				CFrame = L(-45 + dx, 4, 46 + dz),
				Color = iron,
				Material = Enum.Material.Metal,
			})
		end
		P({
			Name = "RackBeam",
			Size = Vector3.new(0.4, 0.4, 2.8),
			CFrame = L(-45 + dx, 8, 46),
			Color = c.NeonAlt,
			Material = Enum.Material.Neon,
		})
	end
	barbell(B, -45, 5.2, 45, 8.4, chrome, c.NeonAlt:Lerp(BLACK, 0.25))
	P({
		Name = "PlateTreeBase",
		Size = Vector3.new(2.6, 0.4, 2.6),
		CFrame = L(-50.5, 0.2, 36),
		Color = iron,
		Material = Enum.Material.Metal,
	})
	P({
		Name = "PlateTreePost",
		Size = Vector3.new(0.5, 5, 0.5),
		CFrame = L(-50.5, 2.7, 36),
		Color = chrome,
		Material = Enum.Material.Metal,
	})
	for i, y in { 1.6, 3, 4.4 } do
		P({
			Name = "Plate",
			Shape = Enum.PartType.Cylinder,
			Size = Vector3.new(0.4, 3.2 - i * 0.4, 3.2 - i * 0.4),
			CFrame = L(-50.5, y, 36.5) * ALONG_Z,
			Color = if i == 2 then c.Primary:Lerp(BLACK, 0.2) else iron,
			Material = Enum.Material.SmoothPlastic,
		})
	end
	for i = 0, 2 do
		local kx, kz = -40.6 - i * 2.4, 33.6
		P({
			Name = "Kettlebell",
			Shape = Enum.PartType.Ball,
			Size = Vector3.new(1.6, 1.6, 1.6),
			CFrame = L(kx, 0.85, kz),
			Color = if i == 1 then c.Primary:Lerp(BLACK, 0.2) else iron,
			Material = Enum.Material.Metal,
		})
		P({
			Name = "KettlebellHandle",
			Size = Vector3.new(1, 0.6, 0.25),
			CFrame = L(kx, 1.85, kz),
			Color = iron,
			Material = Enum.Material.Metal,
		})
	end
	mirror(B, -1, 33.5, 13, chrome)

	-- Front corners: punching bag and a stack of plates.
	P({ Name = "BagArm", Size = Vector3.new(4, 0.4, 0.4), CFrame = L(51.5, 9.6, -50), Color = iron, Material = Enum.Material.Metal })
	P({ Name = "BagChain", Size = Vector3.new(0.2, 2, 0.2), CFrame = L(50, 8.5, -50), Color = chrome, Material = Enum.Material.Metal })
	P({
		Name = "PunchingBag",
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(5, 2.4, 2.4),
		CFrame = L(50, 5, -50) * UPRIGHT,
		Color = leather,
		Material = Enum.Material.Fabric,
	})
	for i = 0, 3 do
		P({
			Name = "Plate",
			Shape = Enum.PartType.Cylinder,
			Size = Vector3.new(0.4, 3.4 - i * 0.3, 3.4 - i * 0.3),
			CFrame = L(-49.5, 0.2 + i * 0.4, -49.5) * UPRIGHT,
			Color = if i % 2 == 0 then iron else c.NeonAlt:Lerp(BLACK, 0.3),
			Material = Enum.Material.SmoothPlastic,
		})
	end
end

local function buildFactoryDecor(B: Builder)
	local c = B.c
	local L, P = B.L, B.P
	local hazard = decorColor("Hazard", c.Secondary)
	local belt = decorColor("Belt", c.PanelDark)
	local pipeColor = decorColor("Pipe", c.WallTrim:Lerp(WHITE, 0.25))

	local function crate(x: number, y: number, z: number, size: number, accent: Color3)
		P({
			Name = "Crate",
			Size = Vector3.new(size, size, size),
			CFrame = L(x, y + size / 2, z),
			Color = Color3.fromRGB(120, 92, 60),
			Material = Enum.Material.WoodPlanks,
		})
		P({
			Name = "CrateBand",
			Size = Vector3.new(size + 0.1, 0.3, size + 0.1),
			CFrame = L(x, y + size * 0.7, z),
			Color = accent,
			Material = Enum.Material.Neon,
		})
	end
	local function hazardPatch(x: number, z: number, sx: number, sz: number)
		P({
			Name = "HazardFloor",
			Size = Vector3.new(sx, 0.06, sz),
			CFrame = L(x, 0.03, z),
			Color = hazard,
			Material = Enum.Material.SmoothPlastic,
		})
		P({
			Name = "HazardFloorInner",
			Size = Vector3.new(sx - 1.2, 0.08, sz - 1.2),
			CFrame = L(x, 0.04, z),
			Color = belt,
			Material = Enum.Material.DiamondPlate,
		})
	end

	-- +X back corner: conveyor with parts on it, a robot arm and wall gears.
	P({
		Name = "ConveyorFrame",
		Size = Vector3.new(3.4, 2.2, 21),
		CFrame = L(50.3, 1.1, 42.5),
		Color = c.WallTrim,
		Material = Enum.Material.Metal,
	})
	P({
		Name = "ConveyorBelt",
		Size = Vector3.new(2.8, 0.15, 21.2),
		CFrame = L(50.3, 2.27, 42.5),
		Color = belt,
		Material = Enum.Material.Fabric,
	})
	for _, dx in { -1.6, 1.6 } do
		P({
			Name = "ConveyorRail",
			Size = Vector3.new(0.25, 0.35, 21),
			CFrame = L(50.3 + dx, 2.4, 42.5),
			Color = hazard,
			Material = Enum.Material.Neon,
		})
	end
	for i, accent in { c.Primary, c.Secondary, c.Accent } do
		crate(50.3, 2.35, 34 + i * 5, 1.6, accent)
	end
	hazardPatch(43.5, 41, 7, 7)
	P({
		Name = "ArmBase",
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(1, 3, 3),
		CFrame = L(44, 0.6, 41) * UPRIGHT,
		Color = c.WallTrim,
		Material = Enum.Material.Metal,
	})
	P({
		Name = "ArmLower",
		Size = Vector3.new(0.9, 4.6, 0.9),
		CFrame = L(44, 1.1, 41) * CFrame.Angles(0, 0, math.rad(-25)) * CFrame.new(0, 2.3, 0),
		Color = hazard,
		Material = Enum.Material.Metal,
	})
	local elbow = L(44, 1.1, 41) * CFrame.Angles(0, 0, math.rad(-25)) * CFrame.new(0, 4.6, 0)
	P({
		Name = "ArmJoint",
		Shape = Enum.PartType.Ball,
		Size = Vector3.new(1.4, 1.4, 1.4),
		CFrame = elbow,
		Color = c.WallTrim,
		Material = Enum.Material.Metal,
	})
	local upper = elbow * CFrame.Angles(0, 0, math.rad(-80))
	P({
		Name = "ArmUpper",
		Size = Vector3.new(0.8, 3.6, 0.8),
		CFrame = upper * CFrame.new(0, 1.8, 0),
		Color = hazard,
		Material = Enum.Material.Metal,
	})
	P({
		Name = "ArmClaw",
		Size = Vector3.new(1.4, 0.6, 1.4),
		CFrame = upper * CFrame.new(0, 3.8, 0),
		Color = c.Primary,
		Material = Enum.Material.Neon,
	})
	local function gear(gy: number, gz: number, diameter: number, teeth: number, accent: Color3)
		local center = L(PLOT_HALF - 1.4, gy, gz)
		P({
			Name = "Gear",
			Shape = Enum.PartType.Cylinder,
			Size = Vector3.new(0.6, diameter, diameter),
			CFrame = center,
			Color = c.WallTrim:Lerp(WHITE, 0.2),
			Material = Enum.Material.Metal,
		})
		P({
			Name = "GearHub",
			Shape = Enum.PartType.Cylinder,
			Size = Vector3.new(0.8, diameter * 0.35, diameter * 0.35),
			CFrame = center * CFrame.new(-0.1, 0, 0),
			Color = accent,
			Material = Enum.Material.Neon,
		})
		for i = 0, teeth - 1 do
			local a = i * 2 * math.pi / teeth
			P({
				Name = "GearTooth",
				Size = Vector3.new(0.6, 1.2, 1.2),
				CFrame = center * CFrame.Angles(a, 0, 0) * CFrame.new(0, diameter / 2 + 0.3, 0),
				Color = c.WallTrim:Lerp(WHITE, 0.2),
				Material = Enum.Material.Metal,
			})
		end
	end
	gear(11, 33, 8, 8, c.Secondary)
	gear(16.4, 38.2, 4.6, 6, c.Primary)

	-- -X back corner: tanks, pipe run and crate stacks.
	for i, tz in { 37, 47 } do
		P({
			Name = "Tank",
			Shape = Enum.PartType.Cylinder,
			Size = Vector3.new(8, 4.4, 4.4),
			CFrame = L(-49.6, 4, tz) * UPRIGHT,
			Color = pipeColor,
			Material = Enum.Material.Metal,
		})
		P({
			Name = "TankBand",
			Shape = Enum.PartType.Cylinder,
			Size = Vector3.new(0.5, 4.6, 4.6),
			CFrame = L(-49.6, if i == 1 then 2.5 else 5.5, tz) * UPRIGHT,
			Color = c.Primary,
			Material = Enum.Material.Neon,
		})
		P({
			Name = "TankDome",
			Shape = Enum.PartType.Ball,
			Size = Vector3.new(4.4, 4.4, 4.4),
			CFrame = L(-49.6, 8, tz),
			Color = pipeColor,
			Material = Enum.Material.Metal,
		})
	end
	for i, py in { 12, 13.6 } do
		P({
			Name = "Pipe",
			Shape = Enum.PartType.Cylinder,
			Size = Vector3.new(22, 1, 1),
			CFrame = L(-51.8, py, 42.5) * ALONG_Z,
			Color = if i == 1 then pipeColor else hazard,
			Material = Enum.Material.Metal,
		})
	end
	hazardPatch(-43, 42, 8, 14)
	crate(-43, 0.1, 38, 3, c.Primary)
	crate(-43, 0.1, 41.2, 3, c.Secondary)
	crate(-43, 3.1, 39.6, 2.6, c.Accent)

	-- Front corners: barrels and crates.
	for i, spot in { Vector3.new(50.5, 0, -50.5), Vector3.new(47.6, 0, -51.2), Vector3.new(50, 0, -47.6) } do
		P({
			Name = "Barrel",
			Shape = Enum.PartType.Cylinder,
			Size = Vector3.new(3, 2.2, 2.2),
			CFrame = L(spot.X, 1.5, spot.Z) * UPRIGHT,
			Color = if i == 2 then hazard else c.Secondary:Lerp(BLACK, 0.35),
			Material = Enum.Material.Metal,
		})
		P({
			Name = "BarrelBand",
			Shape = Enum.PartType.Cylinder,
			Size = Vector3.new(0.3, 2.3, 2.3),
			CFrame = L(spot.X, 2.2, spot.Z) * UPRIGHT,
			Color = c.Primary,
			Material = Enum.Material.Neon,
		})
	end
	crate(-50, 0, -50, 3.2, c.Primary)
	crate(-46.6, 0, -50.6, 2.4, c.Secondary)
end

-- Pads ------------------------------------------------------------------------------------

local function buildPad(B: Builder, name: string, color: Color3, title: string, sub: string): Pad
	local c = B.c
	local L, P, W = B.L, B.P, B.W
	local spot = Layout.PADS[name]
	assert(spot, "no layout for pad " .. name)
	local x, z, sx, sz = spot.x, spot.z, spot.sizeX, spot.sizeZ
	local rimColor = c.WallTrim:Lerp(WHITE, 0.08)
	local insetColor = color:Lerp(c.PanelDark, 0.62)
	local padPart: BasePart
	if spot.round then
		P({
			Name = "PadStep",
			Shape = Enum.PartType.Cylinder,
			Size = Vector3.new(0.25, sx + 3.2, sx + 3.2),
			CFrame = L(x, 0.125, z) * UPRIGHT,
			Color = rimColor:Lerp(BLACK, 0.2),
			Material = Enum.Material.Metal,
		})
		P({
			Name = "PadBase",
			Shape = Enum.PartType.Cylinder,
			Size = Vector3.new(0.5, sx + 1.6, sx + 1.6),
			CFrame = L(x, 0.25, z) * UPRIGHT,
			Color = rimColor,
			Material = Enum.Material.Metal,
		})
		padPart = P({
			Name = "Pad_" .. name,
			Shape = Enum.PartType.Cylinder,
			Size = Vector3.new(0.3, sx, sz),
			CFrame = L(x, 0.65, z) * UPRIGHT,
			Color = color,
			Material = Enum.Material.Neon,
		})
		local inset = P({
			Name = "PadInset",
			Shape = Enum.PartType.Cylinder,
			Size = Vector3.new(0.3, sx - 1.6, sz - 1.6),
			CFrame = L(x, 0.69, z) * UPRIGHT,
			Color = insetColor,
		})
		inset.CanCollide = false
		local center = P({
			Name = "PadCenter",
			Shape = Enum.PartType.Cylinder,
			Size = Vector3.new(0.3, sx * 0.34, sx * 0.34),
			CFrame = L(x, 0.73, z) * UPRIGHT,
			Color = color,
			Material = Enum.Material.Neon,
		})
		center.CanCollide = false
	else
		local baseX, baseZ = sx + 1.2, sz + 1.2
		P({
			Name = "PadBase",
			Size = Vector3.new(baseX, 0.5, baseZ),
			CFrame = L(x, 0.25, z),
			Color = rimColor,
			Material = Enum.Material.Metal,
		})
		-- Bevelled rim: wedges sloping down and outward on every side.
		for _, dir in { -1, 1 } do
			W({
				Name = "PadBevel",
				Size = Vector3.new(baseX + 1.8, 0.5, 0.9),
				CFrame = L(x, 0.25, z + dir * (baseZ / 2 + 0.45)) * CFrame.Angles(0, if dir < 0 then 0 else math.pi, 0),
				Color = rimColor:Lerp(BLACK, 0.15),
				Material = Enum.Material.Metal,
			})
			W({
				Name = "PadBevel",
				Size = Vector3.new(baseZ, 0.5, 0.9),
				CFrame = L(x + dir * (baseX / 2 + 0.45), 0.25, z) * CFrame.Angles(0, -dir * math.pi / 2, 0),
				Color = rimColor:Lerp(BLACK, 0.15),
				Material = Enum.Material.Metal,
			})
		end
		padPart = P({
			Name = "Pad_" .. name,
			Size = Vector3.new(sx, 0.3, sz),
			CFrame = L(x, 0.65, z),
			Color = color,
			Material = Enum.Material.Neon,
		})
		local inset = P({
			Name = "PadInset",
			Size = Vector3.new(sx - 1.4, 0.3, sz - 1.4),
			CFrame = L(x, 0.69, z),
			Color = insetColor,
		})
		inset.CanCollide = false
		local d = math.min(sx, sz) * 0.32
		local center = P({
			Name = "PadCenter",
			Size = Vector3.new(d, 0.3, d),
			CFrame = L(x, 0.73, z) * CFrame.Angles(0, math.rad(45), 0),
			Color = color,
			Material = Enum.Material.Neon,
		})
		center.CanCollide = false
	end

	local gui = billboard(padPart, 5, 10, 3.4)
	local plate = Instance.new("Frame")
	plate.Name = "Plate"
	plate.Size = UDim2.fromScale(1, 1)
	plate.BackgroundColor3 = c.PanelDark
	plate.BackgroundTransparency = 0.3
	plate.BorderSizePixel = 0
	plate.Parent = gui
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0.25, 0)
	corner.Parent = plate
	local border = Instance.new("UIStroke")
	border.Thickness = 3
	border.Color = color
	border.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	border.Parent = plate
	local titleLabel = label(plate, {
		Text = title,
		TextWrapped = true,
		Size = UDim2.fromScale(0.94, 0.54),
		Position = UDim2.fromScale(0.03, 0.04),
	})
	local subLabel = label(plate, {
		Text = sub,
		Size = UDim2.fromScale(0.9, 0.36),
		Position = UDim2.fromScale(0.05, 0.58),
		TextColor3 = c.Good,
	})
	return {
		name = name,
		center = Vector3.new(x, 0, z),
		half = Vector2.new(sx / 2, sz / 2),
		part = padPart,
		title = titleLabel,
		sub = subLabel,
	}
end

-- Plot assembly ---------------------------------------------------------------------------

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
	local function P(props: { [string]: any }): BasePart
		props.Parent = props.Parent or folder
		return make("Part", props)
	end
	local function W(props: { [string]: any }): BasePart
		props.Parent = props.Parent or folder
		return make("WedgePart", props)
	end
	local B: Builder = { cf = cf, folder = folder, c = c, L = L, P = P, W = W }

	buildFloor(B)
	buildWalls(B)
	buildPool(B)
	local slots = buildShelves(B)

	-- Entrance arch with the owner sign facing the hub.
	for side = -1, 1, 2 do
		P({
			Name = "ArchPlinth",
			Size = Vector3.new(5.4, 1.6, 5.4),
			CFrame = L(side * 16, 0.8, -PLOT_HALF),
			Color = c.WallTrim:Lerp(WHITE, 0.1),
			Material = Enum.Material.Metal,
		})
		P({
			Name = "ArchPillar",
			Size = Vector3.new(4, 22, 4),
			CFrame = L(side * 16, 11, -PLOT_HALF),
			Color = c.WallTrim,
			Material = Enum.Material.Metal,
		})
		P({
			Name = "ArchNeon",
			Size = Vector3.new(0.6, 18, 0.4),
			CFrame = L(side * 16, 11, -PLOT_HALF - 2.05),
			Color = c.Neon,
			Material = Enum.Material.Neon,
		})
		P({
			Name = "ArchNeonCap",
			Size = Vector3.new(4.4, 0.6, 4.4),
			CFrame = L(side * 16, 21, -PLOT_HALF),
			Color = c.Neon,
			Material = Enum.Material.Neon,
		})
	end
	P({ Name = "ArchBeam", Size = Vector3.new(36, 4, 4), CFrame = L(0, 23, -PLOT_HALF), Color = c.WallTrim, Material = Enum.Material.Metal })
	P({
		Name = "ArchBeamNeon",
		Size = Vector3.new(28, 0.3, 4.2),
		CFrame = L(0, 20.9, -PLOT_HALF),
		Color = c.NeonAlt,
		Material = Enum.Material.Neon,
	})
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
	local _, numberFrame = board(L(0, 27.6, -PLOT_HALF - 1.2), Vector2.new(8, 2.4), folder, c.NeonAlt)
	label(numberFrame, { Text = "PLOT " .. index, Size = UDim2.fromScale(0.9, 0.8), Position = UDim2.fromScale(0.05, 0.1) })

	local pads: { Pad } = {}
	local padByName: { [string]: Pad } = {}
	local labels: { [string]: TextLabel } = {}
	local function pad(name: string, color: Color3, title: string, sub: string): Pad
		local record = buildPad(B, name, color, title, sub)
		table.insert(pads, record)
		padByName[name] = record
		return record
	end

	-- Buy row in front of the pool.
	for _, amount in Economy.BUY_AMOUNTS do
		pad("Buy" .. amount, c.Pad, "Buy " .. amount .. " " .. w.Unit, "$0")
	end
	pad("AutoMerge", c.NeonAlt, "Auto Merge", "$0")

	-- Merge pad between the buy row and the entrance.
	pad("Merge", c.Primary, w.Merge, "Pairs merge into the next tier")

	-- Buy tier upgrade: pad + board on the +X wall, with an arrow totem below it.
	local tierSpot = Layout.PADS.BuyTier
	pad("BuyTier", c.NeonAlt, w.BuyTier, "")
	do
		local _, frame = board(L(BOARD_X, 9.5, tierSpot.z) * CFrame.Angles(0, math.pi / 2, 0), Vector2.new(14, 9), folder, c.NeonAlt)
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
		local tx = BOARD_X - 1.4
		P({
			Name = "TotemBase",
			Size = Vector3.new(2.6, 1, 4),
			CFrame = L(tx, 0.5, tierSpot.z),
			Color = c.WallTrim,
			Material = Enum.Material.Metal,
		})
		P({
			Name = "TotemShaft",
			Size = Vector3.new(0.6, 1.8, 1),
			CFrame = L(tx, 1.9, tierSpot.z),
			Color = c.NeonAlt,
			Material = Enum.Material.Neon,
		})
		for _, dz in { -1, 1 } do
			W({
				Name = "TotemHead",
				Size = Vector3.new(0.6, 1.3, 1.3),
				CFrame = L(tx, 3.45, tierSpot.z + dz * 0.65) * CFrame.Angles(0, if dz < 0 then 0 else math.pi, 0),
				Color = c.NeonAlt,
				Material = Enum.Material.Neon,
			})
		end
	end

	-- Deposit station: pad + converter machine, board on the -X wall above it.
	local depositSpot = Layout.PADS.Deposit
	pad("Deposit", c.Secondary, "DEPOSIT", w.Orb .. " x1.0")
	do
		local conv = Layout.MACHINES.Converter
		buildConverter(B, (conv.minX + conv.maxX) / 2, (conv.minZ + conv.maxZ) / 2)
		local _, frame = board(L(-BOARD_X, 17, depositSpot.z) * CFrame.Angles(0, -math.pi / 2, 0), Vector2.new(14, 7), folder, c.Secondary)
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

	-- Processing board + machine + upgrade pads (-X wall, beside the pool).
	do
		buildProcessor(B)
		local proc = Layout.MACHINES.Processor
		local _, frame =
			board(L(-BOARD_X, 11.5, (proc.minZ + proc.maxZ) / 2) * CFrame.Angles(0, -math.pi / 2, 0), Vector2.new(14, 8), folder, c.Primary)
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
	pad("ProcUp1", c.Good, "UPGRADE", "$0")
	pad("ProcUp10", c.Good, "UPGRADE x" .. Economy.PROCESS_BULK, "$0")

	-- Collect cash pad + coin vault.
	pad("Collect", c.Primary, w.Collect, "$0")
	buildVault(B)

	-- Crate unlockers (+X side).
	local unlockerScreens = {}
	for i = 1, 2 do
		local name = if i == 1 then w.Unlocker else w.PremiumUnlocker
		local color = if i == 1 then c.Secondary else c.Accent
		pad("Unlock" .. i, color, name, "")
		local rect = Layout.MACHINES["Unlocker" .. i]
		buildUnlocker(B, rect, color)
		local z = (rect.minZ + rect.maxZ) / 2
		local _, frame = board(L(rect.minX + 2.2, 10, z) * CFrame.Angles(0, math.pi / 2, 0), Vector2.new(8, 5.4), folder, color)
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

	-- Crate odds board (+X wall).
	do
		local _, frame = board(L(BOARD_X, 9, -27) * CFrame.Angles(0, math.pi / 2, 0), Vector2.new(10, 9), folder, c.Primary)
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

	-- Free reward pad + board + gift box.
	local freeSpot = Layout.PADS.Free
	pad("Free", c.Good, w.Free, "")
	do
		local _, frame = board(L(BOARD_X, 9.5, freeSpot.z - 2) * CFrame.Angles(0, math.pi / 2, 0), Vector2.new(10, 7), folder, c.Good)
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
		local gx, gz = BOARD_X - 1.6, freeSpot.z + 4.5
		P({ Name = "Gift", Size = Vector3.new(3, 3, 3), CFrame = L(gx, 1.5, gz), Color = c.Good:Lerp(BLACK, 0.2) })
		P({
			Name = "GiftRibbon",
			Size = Vector3.new(3.1, 3.1, 0.6),
			CFrame = L(gx, 1.5, gz),
			Color = c.Primary,
			Material = Enum.Material.Neon,
		})
		P({
			Name = "GiftRibbon",
			Size = Vector3.new(0.6, 3.1, 3.1),
			CFrame = L(gx, 1.5, gz),
			Color = c.Primary,
			Material = Enum.Material.Neon,
		})
		P({
			Name = "GiftBow",
			Shape = Enum.PartType.Ball,
			Size = Vector3.new(1.2, 1.2, 1.2),
			CFrame = L(gx, 3.2, gz),
			Color = c.Primary,
			Material = Enum.Material.Neon,
		})
	end

	if theme.Decor == "gym" then
		buildGymDecor(B)
	elseif theme.Decor == "factory" then
		buildFactoryDecor(B)
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

	local orbArea = Layout.ORB_AREA
	local poolRect = Layout.POOL
	local chestAreas: { Rect } = {}
	for _, area in Layout.CHEST_AREAS do
		table.insert(chestAreas, Layout.rect(area.minX, area.maxX, area.minZ, area.maxZ))
	end
	return {
		index = index,
		cframe = cf,
		folder = folder,
		unitFolder = unitFolder,
		orbFolder = orbFolder,
		chestFolder = chestFolder,
		spawn = L(Layout.SPAWN.x, 4, Layout.SPAWN.z) * CFrame.Angles(0, math.pi, 0),
		slots = slots,
		orbArea = Layout.rect(orbArea.minX, orbArea.maxX, orbArea.minZ, orbArea.maxZ),
		orbFloorY = Layout.POOL_FLOOR_Y,
		pool = Layout.rect(poolRect.minX, poolRect.maxX, poolRect.minZ, poolRect.maxZ),
		chestAreas = chestAreas,
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
