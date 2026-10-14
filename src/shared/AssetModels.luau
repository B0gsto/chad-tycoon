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
-- dark-red cape, crown, shades and a grin on a mini plinth. Authored 4.71 x 6.01 x 2.43 studs, front -Z.
AssetModels.ABSOLUTE_CHAD = "props/AbsoluteChad"

local ABSOLUTE = {
	Height = 6.01, -- authored height (studs), plinth bottom to crown tip
	-- The plinth centre relative to the mesh's bounding-box centre (the MeshPart origin), authored studs.
	PlinthOffset = Vector3.new(0.184, 0, -0.026),
	Source = 0.88, -- the fallback's block layout is in source studs, shipped at this scale (as the mesh is)
}

local function statueColor(r: number, g: number, b: number): Color3
	return Color3.fromRGB(r, g, b)
end

-- Fallback blocks (source studs, plinth bottom centre at the origin, front -Z): size, centre, colour, shape.
local FALLBACK: { { size: Vector3, at: Vector3, color: Color3, cylinder: boolean? } } = {
	{ size = Vector3.new(3.9, 0.5, 2.7), at = Vector3.new(0, 0.25, 0), color = statueColor(44, 170, 170) },
	{ size = Vector3.new(3.82, 0.16, 2.62), at = Vector3.new(0, 0.58, 0), color = statueColor(255, 247, 232) },
	{ size = Vector3.new(1.12, 0.4, 1.4), at = Vector3.new(0.56, 0.86, -0.16), color = statueColor(150, 26, 40) },
	{ size = Vector3.new(1.12, 0.4, 1.4), at = Vector3.new(-0.56, 0.86, -0.16), color = statueColor(150, 26, 40) },
	{ size = Vector3.new(1.1, 0.7, 1.1), at = Vector3.new(0.56, 1.36, 0), color = statueColor(255, 204, 48) },
	{ size = Vector3.new(1.1, 0.7, 1.1), at = Vector3.new(-0.56, 1.36, 0), color = statueColor(255, 204, 48) },
	{ size = Vector3.new(2.2, 0.95, 1.1), at = Vector3.new(0, 2.2, 0), color = statueColor(44, 120, 216) },
	{ size = Vector3.new(2.22, 0.38, 1.12), at = Vector3.new(0, 2.77, 0), color = statueColor(255, 204, 48) },
	{ size = Vector3.new(2.2, 0.66, 1.05), at = Vector3.new(0, 3.28, 0), color = statueColor(246, 190, 146) },
	{ size = Vector3.new(2.5, 1.08, 1.24), at = Vector3.new(0, 4.17, 0), color = statueColor(255, 204, 48) },
	{ size = Vector3.new(3.6, 0.7, 1.3), at = Vector3.new(0, 4.5, 0), color = statueColor(240, 162, 36) },
	{ size = Vector3.new(3.2, 3.6, 0.1), at = Vector3.new(0, 2.85, 0.95), color = statueColor(150, 26, 40) },
	{ size = Vector3.new(1.0, 0.9, 0.9), at = Vector3.new(-2.1, 4.35, 0), color = statueColor(246, 190, 146) },
	{ size = Vector3.new(0.9, 1.1, 0.9), at = Vector3.new(-2.4, 5.1, -0.1), color = statueColor(246, 190, 146) },
	{ size = Vector3.new(0.9, 1.4, 0.9), at = Vector3.new(1.6, 3.5, 0.1), color = statueColor(246, 190, 146) },
	{ size = Vector3.new(1.28, 1.32, 1.32), at = Vector3.new(0, 5.44, 0), color = statueColor(246, 190, 146), cylinder = true },
	{ size = Vector3.new(1.0, 0.3, 0.1), at = Vector3.new(0, 5.48, -0.66), color = statueColor(24, 28, 46) },
	{ size = Vector3.new(1.42, 0.22, 1.42), at = Vector3.new(0, 6.15, 0), color = statueColor(112, 66, 36), cylinder = true },
	{ size = Vector3.new(0.88, 0.45, 0.88), at = Vector3.new(0.1, 6.45, 0.07), color = statueColor(255, 204, 48) },
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

-- A fresh, unparented Model of the Absolute Chad statue, `height` studs tall (default the authored 6.01),
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
	model.WorldPivot = CFrame.identity
	return model
end

return AssetModels
