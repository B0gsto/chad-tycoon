--!strict
--[[
	AssetModels: clones of the Blender-made models stored in ReplicatedStorage.AssetModels.

	Rojo maps assets/models/*.rbxm (downloaded back by pipeline/upload.py, MeshParts with collision data) into that
	folder. A model's key is its pin key ("props/dumbbell"); the instance is named after the .rbxm file, with "/"
	written as "__" ("props__dumbbell"). Every function returns nil / false when the folder or the model is missing,
	so game code keeps its part-built fallback.
]]
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local AssetModels = {}

-- Instance name of `key` inside the AssetModels folder.
function AssetModels.name(key: string): string
	return (string.gsub(key, "/", "__"))
end

local function find(key: string): Instance?
	local folder = ReplicatedStorage:FindFirstChild("AssetModels")
	if folder == nil then
		return nil
	end
	return folder:FindFirstChild(AssetModels.name(key))
end

-- True when the model for `key` is in the place.
function AssetModels.has(key: string): boolean
	return find(key) ~= nil
end

-- A fresh, unparented clone of the model for `key` (usually a Model holding MeshParts), or nil when missing.
function AssetModels.clone(key: string): Instance?
	local source = find(key)
	if source == nil then
		return nil
	end
	return source:Clone()
end

-- Absolute Chad ---------------------------------------------------------------------------------

-- The tier 25 champion statue (art/blender/props/absolute_chad.py): a blocky gold-armoured champion with a
-- dark-red gold-trimmed cape, crown, shades and a grin on a tall gold plinth. Authored 4.46 x 6.31 x 2.54 studs,
-- front -Z. In game a Neon aura disc glows under the plinth.
AssetModels.ABSOLUTE_CHAD = "props/AbsoluteChad"

local ABSOLUTE = {
	Height = 6.305, -- authored height (studs), plinth bottom to crown tip
	-- The plinth centre relative to the mesh's bounding-box centre (the MeshPart origin), authored studs, Roblox
	-- axes (Blender x -> -X, Blender y -> Z). The raised fist and the cape make the mesh lopsided.
	PlinthOffset = Vector3.new(-0.162, 0, -0.121),
	Source = 0.85, -- the fallback's block layout is in source studs, shipped at this scale (as the mesh is)
	-- Neon aura disc under the plinth (authored studs; absolute_chad.py AURA_* draws the same for the renders).
	AuraRadius = 2.15,
	AuraHeight = 0.08,
	AuraColor = Color3.fromRGB(255, 222, 110),
	AuraTransparency = 0.15,
	LightRange = 12, -- PointLight on the disc, studs at the authored size
	LightBrightness = 1.6,
}

local function statueColor(r: number, g: number, b: number): Color3
	return Color3.fromRGB(r, g, b)
end

local GOLD = statueColor(255, 204, 48)
local AMBER = statueColor(240, 162, 36)
local SKIN = statueColor(246, 190, 146)
local CAPE = statueColor(150, 26, 40)

-- Fallback blocks (source studs, plinth bottom centre at the origin, front -Z, the flexed fist at +X as on the
-- mesh): size, centre, colour, shape (cylinders stand upright, size.X is their height).
local FALLBACK: { { size: Vector3, at: Vector3, color: Color3, cylinder: boolean? } } = {
	{ size = Vector3.new(3.9, 0.6, 2.7), at = Vector3.new(0, 0.3, 0), color = statueColor(44, 170, 170) },
	{ size = Vector3.new(3.36, 0.4, 2.26), at = Vector3.new(0, 0.8, 0), color = GOLD },
	{ size = Vector3.new(3.5, 0.1, 2.4), at = Vector3.new(0, 1.01, 0), color = statueColor(255, 247, 232) },
	{ size = Vector3.new(1.0, 1.0, 0.14), at = Vector3.new(0, 0.56, -1.2), color = AMBER },
	{ size = Vector3.new(1.12, 0.4, 1.36), at = Vector3.new(0.56, 1.26, -0.14), color = CAPE },
	{ size = Vector3.new(1.12, 0.4, 1.36), at = Vector3.new(-0.56, 1.26, -0.14), color = CAPE },
	{ size = Vector3.new(1.1, 0.62, 1.1), at = Vector3.new(0.56, 1.73, 0), color = GOLD },
	{ size = Vector3.new(1.1, 0.62, 1.1), at = Vector3.new(-0.56, 1.73, 0), color = GOLD },
	{ size = Vector3.new(2.24, 1.0, 1.08), at = Vector3.new(0, 2.6, 0), color = statueColor(44, 120, 216) },
	{ size = Vector3.new(2.3, 0.38, 1.14), at = Vector3.new(0, 3.17, 0), color = GOLD },
	{ size = Vector3.new(2.2, 0.6, 1.04), at = Vector3.new(0, 3.66, 0), color = SKIN },
	{ size = Vector3.new(2.4, 1.16, 1.18), at = Vector3.new(0, 4.54, 0), color = GOLD },
	{ size = Vector3.new(3.4, 0.5, 1.2), at = Vector3.new(0, 5.0, 0), color = GOLD },
	{ size = Vector3.new(3.0, 4.0, 0.1), at = Vector3.new(0, 3.2, 0.95), color = CAPE },
	{ size = Vector3.new(3.1, 0.12, 0.14), at = Vector3.new(0, 1.26, 1.0), color = GOLD },
	{ size = Vector3.new(1.0, 0.94, 0.94), at = Vector3.new(1.85, 4.78, 0), color = SKIN },
	{ size = Vector3.new(0.9, 1.3, 0.9), at = Vector3.new(2.33, 5.4, -0.1), color = SKIN },
	{ size = Vector3.new(0.9, 1.5, 0.9), at = Vector3.new(-1.6, 3.9, 0.1), color = SKIN },
	{ size = Vector3.new(1.28, 1.32, 1.32), at = Vector3.new(0, 5.84, 0), color = SKIN, cylinder = true },
	{ size = Vector3.new(1.1, 0.34, 0.1), at = Vector3.new(0, 5.9, -0.67), color = statueColor(24, 28, 46) },
	{ size = Vector3.new(0.7, 0.2, 0.1), at = Vector3.new(0, 5.5, -0.67), color = statueColor(250, 246, 236) },
	{ size = Vector3.new(0.3, 1.42, 1.42), at = Vector3.new(0, 6.42, 0), color = statueColor(112, 66, 36), cylinder = true },
	{ size = Vector3.new(0.34, 1.24, 1.24), at = Vector3.new(0, 6.6, 0), color = GOLD, cylinder = true },
	{ size = Vector3.new(0.26, 0.5, 0.26), at = Vector3.new(0, 6.95, -0.55), color = GOLD },
	{ size = Vector3.new(0.26, 0.5, 0.26), at = Vector3.new(0.55, 6.95, 0), color = GOLD },
	{ size = Vector3.new(0.26, 0.5, 0.26), at = Vector3.new(-0.55, 6.95, 0), color = GOLD },
	{ size = Vector3.new(0.24, 0.24, 0.12), at = Vector3.new(0, 6.58, -0.64), color = statueColor(228, 36, 60) },
}

local function quiet(part: BasePart)
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = true
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
end

-- A fresh, unparented Model of the Absolute Chad statue, `height` studs tall (default the authored 6.305),
-- anchored and never colliding, touched or queried. Its pivot (Model.WorldPivot) is the bottom centre of the
-- plinth, facing -Z, so `model:PivotTo(CFrame.new(top) * CFrame.Angles(0, yaw, 0))` stands it on a surface whose
-- top is at `top`. Uses the Blender mesh when it is in the place; otherwise blocks in the same proportions and
-- colours (attribute "Fallback" = true).
function AssetModels.absoluteChad(height: number?): Model
	local k = (height or ABSOLUTE.Height) / ABSOLUTE.Height
	local model = Instance.new("Model")
	model.Name = "AbsoluteChad"
	local clone = AssetModels.clone(AssetModels.ABSOLUTE_CHAD)
	local found = if clone == nil then nil elseif clone:IsA("MeshPart") then clone else clone:FindFirstChildWhichIsA("MeshPart", true)
	if found ~= nil then
		local mesh = found :: MeshPart
		mesh.Parent = nil
		if clone ~= nil and clone ~= mesh then
			clone:Destroy()
		end
		local size = mesh.Size * k
		mesh.Name = "AbsoluteChadMesh"
		mesh.Size = size
		local offset = ABSOLUTE.PlinthOffset * k
		mesh.CFrame = CFrame.new(-offset.X, size.Y / 2, -offset.Z)
		mesh.Color = Color3.new(1, 1, 1)
		mesh.Material = Enum.Material.SmoothPlastic
		mesh:SetAttribute("MeshKey", AssetModels.ABSOLUTE_CHAD)
		quiet(mesh)
		mesh.Parent = model
		model.PrimaryPart = mesh
		model:SetAttribute("Fallback", false)
	else
		if clone ~= nil then
			clone:Destroy()
		end
		local s = ABSOLUTE.Source * k
		local first: BasePart? = nil
		for i, block in FALLBACK do
			local part = Instance.new("Part")
			part.Name = "Block" .. i
			part.Size = block.size * s
			part.Color = block.color
			part.Material = Enum.Material.SmoothPlastic
			if block.cylinder then
				-- Cylinders run along X: stand them up (size.X is the height).
				part.Shape = Enum.PartType.Cylinder
				part.CFrame = CFrame.new(block.at * s) * CFrame.Angles(0, 0, math.rad(90))
			else
				part.CFrame = CFrame.new(block.at * s)
			end
			quiet(part)
			part.Parent = model
			first = first or part
		end
		model.PrimaryPart = first
		model:SetAttribute("Fallback", true)
	end
	-- The glowing aura disc under the plinth (centred on it, so on the pivot).
	local aura = Instance.new("Part")
	aura.Name = "AuraRing"
	aura.Shape = Enum.PartType.Cylinder
	aura.Size = Vector3.new(ABSOLUTE.AuraHeight, ABSOLUTE.AuraRadius * 2, ABSOLUTE.AuraRadius * 2) * k
	aura.CFrame = CFrame.new(0, ABSOLUTE.AuraHeight * k / 2, 0) * CFrame.Angles(0, 0, math.rad(90))
	aura.Color = ABSOLUTE.AuraColor
	aura.Material = Enum.Material.Neon
	aura.Transparency = ABSOLUTE.AuraTransparency
	quiet(aura)
	aura.CastShadow = false
	local light = Instance.new("PointLight")
	light.Color = ABSOLUTE.AuraColor
	light.Range = ABSOLUTE.LightRange * k
	light.Brightness = ABSOLUTE.LightBrightness
	light.Parent = aura
	aura.Parent = model
	model.WorldPivot = CFrame.identity
	return model
end

return AssetModels
