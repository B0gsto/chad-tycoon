--[[
	RigPose: applies Poses to a unit model built by CharacterFactory.

	capture() records, while the model is still in its rest pose, every part's
	offset from its limb's rest frame (Root * pivot). After that a pose is just
	  part.CFrame = Root.CFrame * limbFrame * offset
	for every part. Used by the client Animator (which writes the results with
	BulkMoveTo) and by the preview exporter (which writes them directly).

	Only reads instance properties/attributes; no services, so it also runs
	under Lune.
]]

local Poses = require(script.Parent.Poses)

local RigPose = {}

export type Rig = {
	model: Model,
	root: BasePart,
	animSet: string,
	seed: number,
	scale: number,
	pivots: { [string]: Vector3 },
	parts: { BasePart },
	limbs: { string },
	offsets: { CFrame },
	cframes: { CFrame },
	transforms: { [string]: CFrame },
	frames: { [string]: CFrame },
}

-- Joint pivots of a model (scaled), or nil if it is not an animatable unit.
local function readPivots(model: Model): ({ [string]: Vector3 }?, number)
	local scaleValue = model:GetAttribute(Poses.SCALE_ATTRIBUTE)
	local scale = if type(scaleValue) == "number" then scaleValue else 1
	local pivots: { [string]: Vector3 } = {}
	for _, limb in Poses.LIMBS do
		local pivot = model:GetAttribute(Poses.PIVOT_PREFIX .. limb)
		if typeof(pivot) ~= "Vector3" then
			return nil, scale
		end
		pivots[limb] = pivot * scale
	end
	return pivots, scale
end

-- Adds one part (which must be at its rest CFrame) to a captured rig.
function RigPose.addPart(rig: Rig, part: BasePart)
	if part == rig.root or table.find(rig.parts, part) then
		return
	end
	local limb = part:GetAttribute(Poses.LIMB_ATTRIBUTE)
	if type(limb) ~= "string" or not rig.pivots[limb] then
		return
	end
	local rest = rig.root.CFrame * CFrame.new(rig.pivots[limb])
	table.insert(rig.parts, part)
	table.insert(rig.limbs, limb)
	table.insert(rig.offsets, rest:ToObjectSpace(part.CFrame))
end

-- Drops a part from a rig (e.g. it streamed out or was destroyed).
function RigPose.removePart(rig: Rig, part: BasePart)
	local index = table.find(rig.parts, part)
	if index then
		table.remove(rig.parts, index)
		table.remove(rig.limbs, index)
		table.remove(rig.offsets, index)
		rig.cframes[#rig.cframes] = nil
	end
end

-- Records the rest pose of a unit model. Call before the model is first posed.
function RigPose.capture(model: Model, seed: number?): Rig?
	local root = model.PrimaryPart
	if not root then
		return nil
	end
	local pivots, scale = readPivots(model)
	if not pivots then
		return nil
	end
	local setValue = model:GetAttribute(Poses.SET_ATTRIBUTE)
	local rig: Rig = {
		model = model,
		root = root,
		animSet = if type(setValue) == "string" then setValue else "Chad",
		seed = seed or 0,
		scale = scale,
		pivots = pivots,
		parts = {},
		limbs = {},
		offsets = {},
		cframes = {},
		transforms = {},
		frames = {},
	}
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then
			RigPose.addPart(rig, d)
		end
	end
	return rig
end

-- Computes the world CFrame of every rig part at `time`. Returns the rig's
-- parts and CFrame lists (reused between calls).
function RigPose.compute(rig: Rig, time: number): ({ BasePart }, { CFrame })
	local transforms = Poses.sampleInto(rig.transforms, rig.animSet, time, rig.seed)
	return RigPose.computeFrom(rig, transforms)
end

-- Same as compute, from explicit joint transforms.
function RigPose.computeFrom(rig: Rig, transforms: { [string]: CFrame }): ({ BasePart }, { CFrame })
	local frames = Poses.solve(rig.pivots, transforms, rig.scale, rig.frames)
	local rootCFrame = rig.root.CFrame
	local cframes = rig.cframes
	local limbs, offsets = rig.limbs, rig.offsets
	for i = 1, #rig.parts do
		cframes[i] = rootCFrame * frames[limbs[i]] * offsets[i]
	end
	return rig.parts, cframes
end

-- World CFrames for one named pose at `time` (see Poses.samplePoseInto), or a
-- blend from `fromPose` (alpha 0..1). For models that code moves and poses
-- itself (cutscenes): move the Root first, then pose. The pose is looked up in
-- the rig's AnimSet, then the Story / Fan / Chad / Bot sets.
function RigPose.computePose(rig: Rig, pose: string, time: number, fromPose: string?, alpha: number?): ({ BasePart }, { CFrame })
	local transforms = if fromPose
			and alpha
			and alpha < 1
		then Poses.blendInto(rig.transforms, rig.animSet, fromPose, pose, alpha, time, rig.seed)
		else Poses.samplePoseInto(rig.transforms, rig.animSet, pose, time, rig.seed)
	return RigPose.computeFrom(rig, transforms)
end

-- Same as computePose, writing the part CFrames directly.
function RigPose.applyPose(rig: Rig, pose: string, time: number, fromPose: string?, alpha: number?)
	local parts, cframes = RigPose.computePose(rig, pose, time, fromPose, alpha)
	for i, part in parts do
		part.CFrame = cframes[i]
	end
end

-- Poses a model in place by setting part CFrames directly (no BulkMoveTo).
function RigPose.apply(rig: Rig, time: number)
	local parts, cframes = RigPose.compute(rig, time)
	for i, part in parts do
		part.CFrame = cframes[i]
	end
end

-- Puts every part back in its rest pose.
function RigPose.reset(rig: Rig)
	local rootCFrame = rig.root.CFrame
	for i, part in rig.parts do
		part.CFrame = rootCFrame * CFrame.new(rig.pivots[rig.limbs[i]]) * rig.offsets[i]
	end
end

return RigPose
