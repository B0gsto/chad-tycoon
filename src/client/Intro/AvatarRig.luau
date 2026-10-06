--!strict
--[[
	Intro.AvatarRig: the maths that lets the game's pose system (Poses /
	RigPose) drive a real R15 avatar. Pure CFrame maths, no services or
	instances, so it also runs under Lune.

	describe() takes a joint graph read from an avatar model: parts (by index,
	body parts tagged with their R15 limb name, plus the HumanoidRootPart),
	rigid edges between them (motors, welds, weld / rigid constraints, each
	"b = a * rel") and the limb joints (Motor6D Part0 + C0 per limb). It walks
	the graph from the root part to get every part's REST CFrame (no
	animation), so the joint pivots and part offsets do not depend on what the
	live character was doing when it was cloned.

	Model space matches Poses: origin on the ground under the root part, +Y up,
	facing -Z (the root part's own axes).
]]

local AvatarRig = {}

export type PartSpec = {
	size: Vector3,
	limb: string?, -- R15 limb name for body parts
}

export type Edge = {
	a: number,
	b: number,
	rel: CFrame, -- b = a * rel
	motor: boolean?, -- a body joint (only these build the body chain)
}

export type Spec = {
	parts: { PartSpec },
	root: number,
	edges: { Edge },
	joints: { [string]: { part0: number, c0: CFrame } },
}

export type Description = {
	rest: { [number]: CFrame }, -- model-space rest CFrame per part index
	owner: { [number]: string }, -- limb that carries each part
	pivots: { [string]: Vector3 },
	height: number, -- top of the head
	hipY: number,
	feet: CFrame, -- the model-space origin in root-part space
}

-- Lowest and highest Y of a box of `size` at `cf`.
local function yRange(cf: CFrame, size: Vector3): (number, number)
	local r = cf.RightVector * size.X
	local u = cf.UpVector * size.Y
	local b = cf.LookVector * size.Z
	local half = (math.abs(r.Y) + math.abs(u.Y) + math.abs(b.Y)) * 0.5
	return cf.Position.Y - half, cf.Position.Y + half
end
AvatarRig.yRange = yRange

-- Walks `edges` breadth-first from the parts already in `rest`, filling in the
-- rest CFrame and owner limb of every part reached.
local function spread(
	rest: { [number]: CFrame },
	owner: { [number]: string },
	edges: { Edge },
	queue: { number },
	accept: (Edge) -> boolean
)
	local adjacent: { [number]: { Edge } } = {}
	for _, e in edges do
		if accept(e) then
			adjacent[e.a] = adjacent[e.a] or {}
			table.insert(adjacent[e.a], e)
			adjacent[e.b] = adjacent[e.b] or {}
			table.insert(adjacent[e.b], e)
		end
	end
	local head = 1
	while head <= #queue do
		local i = queue[head]
		head += 1
		local list = adjacent[i]
		if not list then
			continue
		end
		for _, e in list do
			local j = if e.a == i then e.b else e.a
			if not rest[j] then
				rest[j] = if e.a == i then rest[i] * e.rel else rest[i] * e.rel:Inverse()
				owner[j] = owner[j] or owner[i]
				table.insert(queue, j)
			end
		end
	end
end

-- Rest pose, pivots and size of an avatar, or nil and a reason when it cannot
-- be driven by Poses (missing limbs or joints).
function AvatarRig.describe(spec: Spec, limbs: { string }): (Description?, string?)
	local parts = spec.parts
	local rest: { [number]: CFrame } = { [spec.root] = CFrame.new() }
	local owner: { [number]: string } = { [spec.root] = "LowerTorso" }
	for i, p in parts do
		if p.limb then
			owner[i] = p.limb
		end
	end

	-- 1. The body chain, through its motors only.
	spread(rest, owner, spec.edges, { spec.root }, function(e)
		return e.motor == true
	end)
	local limbIndex: { [string]: number } = {}
	for i, p in parts do
		if p.limb and rest[i] then
			limbIndex[p.limb] = i
		end
	end
	for _, limb in limbs do
		if not limbIndex[limb] then
			return nil, "limb not connected: " .. limb
		end
		if not spec.joints[limb] then
			return nil, "no joint for " .. limb
		end
	end

	-- 2. Everything attached to the body (accessories, tools, layered clothing).
	local queue = {}
	for i in rest do
		table.insert(queue, i)
	end
	table.sort(queue)
	spread(rest, owner, spec.edges, queue, function()
		return true
	end)

	-- The ground is under the lowest body part, straight below the root part.
	local ground = math.huge
	for _, limb in limbs do
		local i = limbIndex[limb]
		local low = yRange(rest[i], parts[i].size)
		ground = math.min(ground, low)
	end
	local feet = CFrame.new(0, ground, 0)
	local toModel = feet:Inverse()
	for i, cf in rest do
		rest[i] = toModel * cf
	end

	local pivots: { [string]: Vector3 } = {}
	for _, limb in limbs do
		local joint = spec.joints[limb]
		local base = rest[joint.part0]
		if not base then
			return nil, "joint parent missing for " .. limb
		end
		pivots[limb] = (base * joint.c0).Position
	end

	-- Head top; hair and hats may add a little, never a tall hat's full height.
	local headIndex = limbIndex.Head
	local _, headTop = yRange(rest[headIndex], parts[headIndex].size)
	local height = headTop
	for i, cf in rest do
		if owner[i] == "Head" and not parts[i].limb then
			local _, top = yRange(cf, parts[i].size)
			height = math.max(height, math.min(top, headTop + 0.6))
		end
	end

	local hipY = 0
	if pivots.LeftUpperLeg and pivots.RightUpperLeg then
		hipY = (pivots.LeftUpperLeg.Y + pivots.RightUpperLeg.Y) * 0.5
	end
	if hipY <= 0.1 or height <= hipY then
		return nil, "implausible proportions"
	end
	return {
		rest = rest,
		owner = owner,
		pivots = pivots,
		height = height,
		hipY = hipY,
		feet = feet,
	}, nil
end

-- A RigPose.Rig-shaped table for the described avatar: `instances[i]` is the
-- part for spec index i (nil entries are skipped), `root` the part whose
-- CFrame is the model-space origin. RigPose.computeFrom poses it.
function AvatarRig.rig(desc: Description, instances: { [number]: any }, root: any, model: any, scale: number, seed: number): any
	local parts, limbList, offsets = {}, {}, {}
	local indices = {}
	for i in desc.rest do
		if instances[i] then
			table.insert(indices, i)
		end
	end
	table.sort(indices)
	for _, i in indices do
		local limb = desc.owner[i]
		local pivot = desc.pivots[limb]
		if pivot then
			table.insert(parts, instances[i])
			table.insert(limbList, limb)
			table.insert(offsets, CFrame.new(pivot):Inverse() * desc.rest[i])
		end
	end
	return {
		model = model,
		root = root,
		animSet = "Chad",
		seed = seed,
		scale = scale,
		pivots = desc.pivots,
		parts = parts,
		limbs = limbList,
		offsets = offsets,
		cframes = {},
		transforms = {},
		frames = {},
	}
end

return AvatarRig
