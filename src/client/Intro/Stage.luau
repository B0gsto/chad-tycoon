--!strict
--[[
	Intro.Stage: the sunny little gym yard the intro is filmed in.

	Built on the client from plain parts, far from the map (see ORIGIN), and
	destroyed when the intro ends. Stage-local coordinates (Intro.Timeline):
	the mat's top is y = 0, the backdrop (fence, cabana, palms) is toward +Z and
	the camera films from -Z.
]]

local Workspace = game:GetService("Workspace")

local Timeline = require(script.Parent.Timeline)

local Stage = {}

-- Far from the map (beyond the fog) and well above the ground.
Stage.ORIGIN = CFrame.new(2600, 320, 2600)

export type Stage = {
	model: Model,
	cframe: CFrame,
	-- World position of a stage-local point.
	toWorld: (x: number, y: number, z: number) -> Vector3,
	destroy: () -> (),
}

local SMOOTH = Enum.Material.SmoothPlastic

local function part(parent: Instance, props: { [string]: any }): BasePart
	local p = Instance.new("Part")
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.Material = SMOOTH
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	for key, value in props do
		(p :: any)[key] = value
	end
	if p.Size.Magnitude < 1.2 then
		p.CastShadow = false
	end
	p.Parent = parent
	return p
end

function Stage.build(theme: any, origin: CFrame?): Stage
	local W = theme.World
	local base = origin or Stage.ORIGIN
	local model = Instance.new("Model")
	model.Name = "IntroStage"

	-- Stage-local placement helpers.
	local function at(x: number, y: number, z: number, ry: number?): CFrame
		return base * CFrame.new(x, y, z) * CFrame.Angles(0, math.rad(ry or 0), 0)
	end
	local function box(size: Vector3, cf: CFrame, color: Color3, material: Enum.Material?): BasePart
		return part(model, { Size = size, CFrame = cf, Color = color, Material = material or SMOOTH })
	end
	local function ball(d: number, cf: CFrame, color: Color3, material: Enum.Material?): BasePart
		return part(model, {
			Shape = Enum.PartType.Ball,
			Size = Vector3.one * d,
			CFrame = cf,
			Color = color,
			Material = material or SMOOTH,
		})
	end
	-- Upright cylinder (Roblox cylinders run along X, so turn them onto Y).
	local function post(d: number, h: number, cf: CFrame, color: Color3, material: Enum.Material?): BasePart
		return part(model, {
			Shape = Enum.PartType.Cylinder,
			Size = Vector3.new(h, d, d),
			CFrame = cf * CFrame.Angles(0, 0, math.rad(90)),
			Color = color,
			Material = material or SMOOTH,
		})
	end
	local function disc(d: number, h: number, cf: CFrame, color: Color3, material: Enum.Material?): BasePart
		return post(d, h, cf, color, material)
	end

	-- Sea to the horizon, a sand island and the grass yard.
	box(Vector3.new(2048, 2, 2048), at(0, -7, 0), W.Ocean)
	disc(230, 6.75, at(0, -3.625, 6), W.Sand, Enum.Material.Sand)
	disc(236, 0.6, at(0, -6.2, 6), W.SandDark, Enum.Material.Sand)
	box(Vector3.new(70, 0.5, 44), at(-6, -0.3, 4), W.Grass, Enum.Material.Grass)
	box(Vector3.new(71, 0.42, 45), at(-6, -0.36, 4), W.GrassDark, Enum.Material.Grass)

	-- The rubber training mat with a thick white rim and soft stripes.
	box(Vector3.new(32, 0.3, 17), at(-4, -0.15, 1.5), W.Mat)
	for i = -3, 3 do
		box(Vector3.new(2, 0.31, 17), at(-4 + i * 4.5, -0.15, 1.5), W.MatAlt)
	end
	box(Vector3.new(34, 0.34, 1), at(-4, -0.13, 10.5), W.White)
	box(Vector3.new(34, 0.34, 1), at(-4, -0.13, -7.5), W.White)
	box(Vector3.new(1, 0.34, 17), at(-21, -0.13, 1.5), W.White)
	box(Vector3.new(1, 0.34, 17), at(13, -0.13, 1.5), W.White)

	-- A low picket fence with candy post caps along the back.
	local caps = { W.Pink, W.Sunny, W.Mint, W.Blue, W.Coral, W.Grape }
	local n = 0
	for x = -30, 22, 3.25 do
		n += 1
		post(0.55, 3.2, at(x, 1.6, 13.5), W.White)
		ball(0.8, at(x, 3.3, 13.5), caps[(n - 1) % #caps + 1])
	end
	box(Vector3.new(53, 0.42, 0.3), at(-4, 2.3, 13.5), W.Cream)
	box(Vector3.new(53, 0.42, 0.3), at(-4, 1.1, 13.5), W.Cream)
	for x = -28, 20, 4 do
		ball(2.6 + (x % 3) * 0.4, at(x + 1.3, 0.9, 15.2), if x % 8 == 0 then W.Grass else W.GrassDark, Enum.Material.Grass)
	end

	-- Bunting flags strung between two tall striped poles.
	local flagColors = { W.Pink, W.Sunny, W.Mint, W.Blue, W.Orange }
	local poleL, poleR = Vector3.new(-24, 0, 12), Vector3.new(16, 0, 12)
	for _, p in { poleL, poleR } do
		post(0.7, 9, at(p.X, 4.5, p.Z), W.White)
		ball(1.1, at(p.X, 9.2, p.Z), W.Coral)
	end
	local flags = 22
	for i = 0, flags do
		local u = i / flags
		local x = poleL.X + (poleR.X - poleL.X) * u
		local y = 8.4 - math.sin(u * math.pi) * 2
		part(model, {
			Shape = Enum.PartType.Wedge,
			Size = Vector3.new(0.12, 1.1, 0.9),
			CFrame = at(x, y - 0.55, 12) * CFrame.Angles(math.rad(180), math.rad(90), 0),
			Color = flagColors[i % #flagColors + 1],
			CastShadow = false,
		})
	end

	-- The gym cabana: cream walls, a striped awning and a white sign card.
	local cab = Vector3.new(Timeline.SET.Cabana.at[1], 0, Timeline.SET.Cabana.at[2])
	box(Vector3.new(12, 6, 6), at(cab.X, 3, cab.Z), W.Cream)
	box(Vector3.new(12.6, 0.6, 6.6), at(cab.X, 6.3, cab.Z), W.White)
	box(Vector3.new(3, 4.2, 0.4), at(cab.X - 2.5, 2.1, cab.Z - 3.1), W.Wood, Enum.Material.WoodPlanks)
	for i = 0, 7 do
		box(
			Vector3.new(1.6, 0.35, 3.6),
			at(cab.X - 5.6 + i * 1.6, 5.9, cab.Z - 4.4) * CFrame.Angles(math.rad(-22), 0, 0),
			if i % 2 == 0 then W.Coral else W.White
		)
	end
	for i = 0, 7 do
		ball(0.62, at(cab.X - 5.6 + i * 1.6, 5.1, cab.Z - 6.05), if i % 2 == 0 then W.Coral else W.White)
	end
	-- The sign hangs low on the wall right of the door (stage x 11..16), so
	-- nothing sits high on the backdrop behind the hero's and fan's name tags.
	local card = box(Vector3.new(4.8, 1.8, 0.4), at(cab.X + 2.6, 3.6, cab.Z - 3.15), W.White)
	box(Vector3.new(4.9, 0.45, 0.46), at(cab.X + 2.6, 4.3, cab.Z - 3.15), W.Sunny)
	local gui = Instance.new("SurfaceGui")
	gui.Face = Enum.NormalId.Front
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 40
	gui.LightInfluence = 0.4
	gui.Parent = card
	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromScale(0.92, 0.72)
	label.Position = UDim2.fromScale(0.04, 0.26)
	label.Font = theme.Fonts.Display
	label.TextScaled = true
	label.TextColor3 = W.Ink
	label.Text = "SUNNY GYM"
	label.Parent = gui

	-- Candy-coloured weights: a plate rack, a bench and kettlebells.
	local rack = Vector3.new(Timeline.SET.Rack.at[1], 0, Timeline.SET.Rack.at[2])
	for _, dx in { -2.4, 2.4 } do
		post(0.45, 4, at(rack.X + dx, 2, rack.Z), W.Steel)
	end
	part(model, {
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(6.2, 0.4, 0.4),
		CFrame = at(rack.X, 3.6, rack.Z),
		Color = W.Chrome,
	})
	local plates = { { -2.9, W.Pink, 2.4 }, { -3.3, W.Sunny, 1.9 }, { 2.9, W.Pink, 2.4 }, { 3.3, W.Sunny, 1.9 } }
	for _, plate in plates do
		part(model, {
			Shape = Enum.PartType.Cylinder,
			Size = Vector3.new(0.38, plate[3], plate[3]),
			CFrame = at(rack.X + plate[1], 3.6, rack.Z),
			Color = plate[2],
		})
	end
	for i, color in { W.Mint, W.Blue, W.Grape, W.Orange } do
		local x = rack.X - 5.5 + i * 2.2
		part(model, {
			Shape = Enum.PartType.Cylinder,
			Size = Vector3.new(0.5, 1.6, 1.6),
			CFrame = at(x, 0.8, rack.Z + 1.5) * CFrame.Angles(0, math.rad(90), 0),
			Color = color,
		})
	end

	local bench = Vector3.new(Timeline.SET.Bench.at[1], 0, Timeline.SET.Bench.at[2])
	box(Vector3.new(1.6, 0.6, 5), at(bench.X, 1.7, bench.Z, 20), W.Coral)
	box(Vector3.new(1.7, 0.2, 5.1), at(bench.X, 1.35, bench.Z, 20), W.White)
	for _, dz in { -1.8, 1.8 } do
		local legAt = at(bench.X, 0, bench.Z, 20) * CFrame.new(0, 0.65, dz)
		box(Vector3.new(0.5, 1.3, 0.5), legAt, W.Steel)
	end
	for i, color in { W.Grape, W.Orange } do
		local kb = at(bench.X + 2.6 + i * 1.5, 0, bench.Z - 2.2 + i * 0.6)
		ball(1.3, kb * CFrame.new(0, 0.62, 0), color)
		part(model, {
			Shape = Enum.PartType.Cylinder,
			Size = Vector3.new(0.3, 0.9, 0.9),
			CFrame = kb * CFrame.new(0, 1.35, 0) * CFrame.Angles(0, math.rad(90), 0),
			Color = W.Chrome,
		})
	end

	-- Palm trees: a curved trunk of stacked rings and a crown of chunky leaves.
	local function palm(x: number, z: number, lean: number, height: number)
		local segs = 7
		local top = at(x, 0, z)
		for i = 0, segs - 1 do
			local u = i / segs
			local cf = at(x + math.sin(u * 1.4) * lean, (i + 0.5) * height / segs, z)
			post(1.25 - u * 0.35, height / segs + 0.12, cf, if i % 2 == 0 then W.Wood else W.WoodDark)
			top = at(x + math.sin(1.4) * lean, height, z)
		end
		for k = 0, 6 do
			local yaw = k * (360 / 7) + x * 7
			box(
				Vector3.new(1.3, 0.35, 5.4),
				top * CFrame.Angles(0, math.rad(yaw), 0) * CFrame.Angles(math.rad(-22), 0, 0) * CFrame.new(0, -0.3, -2.4),
				if k % 2 == 0 then W.Grass else W.GrassDark
			)
		end
		for k = 0, 2 do
			ball(0.85, top * CFrame.Angles(0, math.rad(k * 120), 0) * CFrame.new(0, -0.7, -0.6), W.WoodDark)
		end
	end
	palm(-19, 17, 2.2, 13)
	palm(20, 12, -1.8, 11)
	palm(-34, 9, 2.6, 12)
	palm(30, 20, -2.4, 14)
	palm(-44, 22, 1.5, 15)

	-- A beach umbrella and a cooler on the sand, off the right edge of the mat.
	local umb = at(-28, 0, -2)
	post(0.3, 6, umb * CFrame.new(0, 3, 0), W.White)
	for k = 0, 7 do
		box(
			Vector3.new(2.6, 0.25, 4),
			umb
				* CFrame.new(0, 6, 0)
				* CFrame.Angles(0, math.rad(k * 45), 0)
				* CFrame.Angles(math.rad(14), 0, 0)
				* CFrame.new(0, -0.4, -1.9),
			if k % 2 == 0 then W.Sunny else W.White
		)
	end
	box(Vector3.new(2.4, 1.6, 1.6), at(-25.5, 0.8, -3.5, 15), W.Blue)
	box(Vector3.new(2.5, 0.35, 1.7), at(-25.5, 1.75, -3.5, 15), W.White)

	model.Parent = Workspace

	local stage: Stage = {
		model = model,
		cframe = base,
		toWorld = function(x: number, y: number, z: number): Vector3
			return base * Vector3.new(x, y, z)
		end,
		destroy = function()
			model:Destroy()
		end,
	}
	return stage
end

return Stage
