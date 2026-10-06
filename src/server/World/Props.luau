--!strict
--[[
	Props: puts the Blender-made meshes (ReplicatedStorage.AssetModels, see docs/assets.md) where
	the world has a part-built prop with an uploaded counterpart. When a model is missing
	(moderation, loading) nothing changes and the part-built version stays.

	Mesh frame: every uploaded model holds one MeshPart whose bounding box has its base centre
	at the model origin, front along -Z (Blender -Y), Y up, 1 stud per Blender unit. A MeshPart's
	CFrame is its bounding-box centre, so a mesh stands on a frame `base` at
	base * (0, Size.Y / 2, 0). ANCHOR lists the meshes whose contact point (pot, trunk, bench
	frame) is not under the bounding-box centre.

	Props.apply(root) swaps every Model under `root` with attribute Mesh = "<Kind>" (the
	Prop_<Kind> models of World.Decor and World.Hub):
	  * the mesh stands on the model's PrimaryPart ("PropRoot", base centre, front -Z);
	  * uniform scale: attribute MeshScale when set, else the part-built version's height;
	  * the part-built parts are removed, except PropRoot and parts with attribute
	    MeshKeep = true (signs the mesh leaves to the game);
	  * the mesh never collides, queries or touches (the camera does not pop on decor); when
	    the part-built version blocked the player, invisible "PropCollider" parts do (COLLIDERS,
	    or one box round the mesh);
	  * the model keeps its name (Client.Fx.Ambient finds Prop_PalmTree by name); the mesh is
	    named "<Kind>Mesh", tagged MESH_TAG and carries attribute MeshKey.
	World.Machines and Tycoon's crate builder place their meshes directly with Props.mesh;
Props.overlay gives a mesh a pastel colour wash (the crate smashers).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local AssetModels = require(ReplicatedStorage.Shared.AssetModels)

local Props = {}

Props.MESH_TAG = "PropMeshPart"

local KEY_PREFIX = "props/"
local UPRIGHT = CFrame.Angles(0, 0, math.pi / 2)
local WHITE = Color3.new(1, 1, 1)

-- Point (mesh units, from the bounding-box base centre) that stands on the prop's root.
local ANCHOR: { [string]: Vector3 } = {
	-- The bounding box includes the barbell rack at the bench's +Z end.
	Bench = Vector3.new(0, 0, -0.575),
	-- The crown leans away from the pot / trunk base.
	PalmPlanter = Vector3.new(0.7, 0, 0),
	PalmTree = Vector3.new(0, 0, -1.4),
}

-- Invisible colliders (mesh units, centres from the bounding-box base centre) for meshes whose
-- bounding box would block far more than the part-built version did. Other solid props get
-- one box round the mesh.
type Collider = { size: Vector3, center: Vector3, cylinder: boolean? }
local COLLIDERS: { [string]: { Collider } } = {
	PalmTree = { { size = Vector3.new(2, 10, 2), center = Vector3.new(0, 5, -1) } },
	PalmPlanter = { { size = Vector3.new(3, 2.6, 3), center = Vector3.new(0.7, 1.3, 0) } },
	JuiceBar = {
		{ size = Vector3.new(11, 0.65, 8.6), center = Vector3.new(0, 0.33, 0.2) },
		{ size = Vector3.new(9.8, 3.2, 2), center = Vector3.new(0, 1.6, -2.25) },
		{ size = Vector3.new(9.6, 4.6, 0.8), center = Vector3.new(0, 3, 4.58) },
	},
	-- Tiers: size = (height, diameter, diameter) of an upright cylinder.
	TrophyPodium = {
		{ size = Vector3.new(2.3, 18.2, 18.2), center = Vector3.new(0, 1.15, 0), cylinder = true },
		{ size = Vector3.new(2.3, 13.4, 13.4), center = Vector3.new(0, 3.45, 0), cylinder = true },
		{ size = Vector3.new(2.3, 9, 9), center = Vector3.new(0, 5.75, 0), cylinder = true },
	},
	-- Body and legs only: the flexed arms reach far past the pedestal.
	GigaStatue = { { size = Vector3.new(8.3, 21, 8.3), center = Vector3.new(0, 10.5, 0) } },
}

local function keyOf(kind: string): string
	return KEY_PREFIX .. kind
end

-- True when the mesh for `kind` is in the place.
function Props.has(kind: string): boolean
	return AssetModels.has(keyOf(kind))
end

-- A fresh MeshPart for `kind` (unscaled, unparented), or nil when the model is missing.
local function cloneMesh(kind: string): MeshPart?
	local clone = AssetModels.clone(keyOf(kind))
	if clone == nil then
		return nil
	end
	local found = if clone:IsA("MeshPart") then clone else clone:FindFirstChildWhichIsA("MeshPart", true)
	if found == nil then
		clone:Destroy()
		return nil
	end
	local mesh = found :: MeshPart
	if mesh ~= clone then
		mesh.Parent = nil
		clone:Destroy()
	end
	return mesh
end

-- Authored size (studs) of the mesh for `kind`, or nil when the model is missing.
function Props.size(kind: string): Vector3?
	local mesh = cloneMesh(kind)
	if mesh == nil then
		return nil
	end
	local size = mesh.Size
	mesh:Destroy()
	return size
end

-- Mesh-frame contact point of `kind` (see ANCHOR), in mesh units.
function Props.anchor(kind: string): Vector3
	return ANCHOR[kind] or Vector3.zero
end

-- Stands `mesh` with its bounding-box base centre on `base` (front along base's -Z), scaled
-- uniformly by `scale`: anchored, white (vertex colours), SmoothPlastic, never colliding or queried.
local function dress(mesh: MeshPart, kind: string, base: CFrame, scale: number, parent: Instance?): MeshPart
	local size = mesh.Size * scale
	mesh.Name = kind .. "Mesh"
	mesh.Size = size
	mesh.CFrame = base * CFrame.new(0, size.Y / 2, 0)
	mesh.Anchored = true
	mesh.CanCollide = false
	mesh.CanQuery = false
	mesh.CanTouch = false
	mesh.Color = WHITE
	mesh.Material = Enum.Material.SmoothPlastic
	mesh:SetAttribute("MeshKey", keyOf(kind))
	mesh:AddTag(Props.MESH_TAG)
	mesh.Parent = parent
	return mesh
end

-- The mesh for `kind` standing on `base` (see dress) and parented to `parent`, or nil when the
-- model is missing.
function Props.mesh(kind: string, base: CFrame, scale: number?, parent: Instance?): MeshPart?
	local mesh = cloneMesh(kind)
	if mesh == nil then
		return nil
	end
	return dress(mesh, kind, base, scale or 1, parent)
end

-- Washes `mesh`'s baked vertex colours toward `color` (a part Color would only darken them):
-- an occluded Highlight fill with no outline, `transparency` 0 = solid colour, 1 = none.
function Props.overlay(mesh: MeshPart, color: Color3, transparency: number): Highlight
	local h = Instance.new("Highlight")
	h.Name = "PastelOverlay"
	h.DepthMode = Enum.HighlightDepthMode.Occluded
	h.FillColor = color
	h.FillTransparency = transparency
	h.OutlineTransparency = 1
	h.Adornee = mesh
	h.Parent = mesh
	return h
end

-- An invisible collider: a box, or an upright cylinder (size = height, diameter, diameter).
function Props.collider(parent: Instance, cframe: CFrame, size: Vector3, cylinder: boolean?): BasePart
	local p = Instance.new("Part")
	p.Name = "PropCollider"
	if cylinder then
		p.Shape = Enum.PartType.Cylinder
		cframe *= UPRIGHT
	end
	p.Size = size
	p.CFrame = cframe
	p.Transparency = 1
	p.Anchored = true
	p.CanCollide = true
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Parent = parent
	return p
end

-- Lowest and highest point of `part` along the up axis of `frame` (balls and cylinders by
-- their round shape, everything else by its box).
local function verticalSpan(frame: CFrame, part: BasePart): (number, number)
	local cf = frame:ToObjectSpace(part.CFrame)
	local up = cf:VectorToObjectSpace(Vector3.yAxis)
	local half = part.Size / 2
	local shape = if part:IsA("Part") then (part :: Part).Shape else nil
	local reach
	if shape == Enum.PartType.Ball then
		reach = half.X
	elseif shape == Enum.PartType.Cylinder then
		local radius = math.min(half.Y, half.Z)
		reach = math.abs(up.X) * half.X + math.sqrt(math.max(0, 1 - up.X * up.X)) * radius
	else
		reach = math.abs(up.X) * half.X + math.abs(up.Y) * half.Y + math.abs(up.Z) * half.Z
	end
	return cf.Position.Y - reach, cf.Position.Y + reach
end

-- Swaps one Prop_<Kind> model; returns true when its mesh went in.
local function applyModel(model: Model): boolean
	local kind = model:GetAttribute("Mesh")
	if type(kind) ~= "string" or model:GetAttribute("MeshApplied") or not Props.has(kind) then
		return false
	end
	local root = model.PrimaryPart or model:FindFirstChild("PropRoot")
	if root == nil or not root:IsA("BasePart") then
		return false
	end
	local frame = root.CFrame

	-- The part-built version: its parts, its height and whether it blocked the player.
	local fallback: { BasePart } = {}
	local bottom, top = math.huge, -math.huge
	local solid = false
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") and d ~= root and d:GetAttribute("MeshKeep") ~= true then
			table.insert(fallback, d)
			if d.Transparency < 1 then
				local low, high = verticalSpan(frame, d)
				bottom = math.min(bottom, low)
				top = math.max(top, high)
			end
			solid = solid or d.CanCollide
		end
	end

	local mesh = cloneMesh(kind)
	if mesh == nil then
		return false
	end
	local scale = model:GetAttribute("MeshScale")
	if type(scale) ~= "number" then
		scale = if top > bottom then (top - bottom) / mesh.Size.Y else 1
	end
	local s = math.clamp(scale :: number, 0.2, 5)
	local base = frame * CFrame.new(-Props.anchor(kind) * s)
	dress(mesh, kind, base, s, model)
	for _, p in fallback do
		p:Destroy()
	end
	if solid then
		local list = COLLIDERS[kind]
		if list then
			for _, c in list do
				Props.collider(model, base * CFrame.new(c.center * s), c.size * s, c.cylinder)
			end
		else
			local size = mesh.Size
			Props.collider(model, base * CFrame.new(0, size.Y / 2, 0), size)
		end
	end
	model:SetAttribute("MeshApplied", true)
	return true
end

-- Swaps every Prop_<Kind> model under `root` that has an uploaded mesh; returns how many.
function Props.apply(root: Instance): number
	local count = 0
	for _, d in root:GetDescendants() do
		if d:IsA("Model") and d:GetAttribute("Mesh") ~= nil and applyModel(d) then
			count += 1
		end
	end
	return count
end

return Props
