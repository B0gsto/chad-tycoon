--!strict
--[[
	Intro.Avatar: turns the local player's real avatar into a cutscene actor.

	fetch() clones the player's character (after a short wait for it and its
	appearance), or builds one from the user id when there is no character in
	time. build() strips the clone down to something that only renders
	(no scripts, sounds, animator, joints, physics or name tag; the Humanoid
	stays so clothing and body colours keep rendering), reads its R15 joint
	graph into AvatarRig, anchors every part and returns a RigPose-shaped rig
	that Actors drives exactly like a CharacterFactory model: the root part
	"IntroRoot" stands on the ground and every part is written each frame with
	BulkMoveTo. When that model is not a full R15 rig (an R6 avatar, or a clone
	that fails the R15 checks), build() makes an R15 model of the same avatar
	from its HumanoidDescription and runs that through the same steps; only if
	that fails too does it return nil (the caller keeps the part-built hero).
	The whole build stays within the fetch wait budget. Studio-only: the
	LocalPlayer attribute IntroForceR15Build skips the clone and goes straight
	to the description build.

	attachFace() / setFace() act out the cutscene's emotions on the clone's
	face only (body, clothes, hair and accessories stay the player's own):
	dynamic heads ease their FaceControls into a pose, classic face decals
	swap to the Blender-made "faces/<Emotion>" image, and decal-less heads of a
	classic shape get that image as their own decal. Other heads, missing
	images and any error keep the avatar's own face.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Assets = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Assets"))
local Poses = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Poses"))
local AvatarRig = require(script.Parent:WaitForChild("AvatarRig"))

local Avatar = {}

local CHARACTER_WAIT = 2
local APPEARANCE_WAIT = 2
local CREATE_WAIT = 3

export type Built = {
	model: Model,
	rig: any,
	scale: number,
	height: number,
}

-- Waits up to `seconds` for `ready()`; returns its final value.
local function waitFor(seconds: number, ready: () -> boolean): boolean
	local deadline = os.clock() + seconds
	while not ready() do
		if os.clock() >= deadline then
			return false
		end
		task.wait(0.1)
	end
	return true
end

local function cloneCharacter(player: Player): Model?
	waitFor(CHARACTER_WAIT, function()
		return player.Character ~= nil
	end)
	local character = player.Character
	if not character then
		return nil
	end
	waitFor(APPEARANCE_WAIT, function()
		return player:HasAppearanceLoaded()
	end)
	local was = character.Archivable
	character.Archivable = true
	local ok, copy = pcall(character.Clone, character)
	character.Archivable = was
	if ok and copy then
		return copy :: Model
	end
	return nil
end

-- Runs `make` on a background thread, abandoned (and the late model cleaned
-- up) if it takes longer than `seconds`.
local function createModel(seconds: number, make: () -> Model?): Model?
	local result: Model? = nil
	local done = false
	local abandoned = false
	task.spawn(function()
		local ok, model = pcall(make)
		done = true
		if ok and model then
			if abandoned then
				model:Destroy()
			else
				result = model
			end
		end
	end)
	waitFor(seconds, function()
		return done
	end)
	abandoned = true
	return result
end

-- Players:CreateHumanoidModelFromUserId (the avatar's own rig type), or nil.
local function modelFromUserId(userId: number): Model?
	if userId <= 0 then
		return nil
	end
	return createModel(CREATE_WAIT, function()
		return Players:CreateHumanoidModelFromUserId(userId)
	end)
end

-- An R15 model of the player's avatar built from its HumanoidDescription (the
-- character's applied one, else the one on the website), or nil.
local function r15FromDescription(player: Player, seconds: number): Model?
	if seconds <= 0 then
		return nil
	end
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	return createModel(seconds, function()
		local desc: HumanoidDescription? = nil
		if humanoid then
			local ok, applied = pcall(humanoid.GetAppliedDescription, humanoid)
			if ok then
				desc = applied
			end
		end
		if not desc and player.UserId > 0 then
			desc = Players:GetHumanoidDescriptionFromUserId(player.UserId)
		end
		if not desc then
			return nil
		end
		return Players:CreateHumanoidModelFromDescription(desc, Enum.HumanoidRigType.R15)
	end)
end

-- A clone of the player's avatar, or nil.
function Avatar.fetch(player: Player): Model?
	return cloneCharacter(player) or modelFromUserId(player.UserId)
end

local DROP = { "BaseScript", "ModuleScript", "Sound", "ForceField", "Animator", "AnimationController", "BodyMover", "Constraint" }

-- Things the game adds to a character that are not part of the avatar: a held
-- crate (a Model welded to the root), tools, and cosmetic trails and aura (the
-- crown, "CosCrown", stays). Effects that only exist while playing go too.
local NOT_AVATAR = { "Tool", "Trail", "Beam", "ParticleEmitter", "BillboardGui", "Highlight", "Light" }

local function isAvatarPiece(d: Instance, model: Model): boolean
	if d.Parent == model and d:IsA("Model") then
		return d.Name == "CosCrown"
	end
	for _, class in NOT_AVATAR do
		if d:IsA(class) then
			return false
		end
	end
	if d:GetAttribute("Cosmetic") == true then
		local name = d.Name
		return name == "CosCrown" or d:FindFirstAncestor("CosCrown") ~= nil
	end
	return true
end

-- Removes everything that runs, sounds or simulates and everything that is not
-- the avatar itself; keeps the looks.
local function strip(model: Model)
	for _, d in model:GetDescendants() do
		if d.Parent ~= nil and not isAvatarPiece(d, model) then
			d:Destroy()
		end
	end
	for _, d in model:GetDescendants() do
		if d.Parent == nil then
			continue
		end
		for _, class in DROP do
			-- Rigid / weld constraints are read as joints first; see build().
			if d:IsA(class) and not (d:IsA("WeldConstraint") or d:IsA("RigidConstraint") or d:IsA("AnimationConstraint")) then
				d:Destroy()
				break
			end
		end
	end
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
		humanoid.HealthDisplayType = Enum.HumanoidHealthDisplayType.AlwaysOff
		humanoid.NameDisplayDistance = 0
		humanoid.HealthDisplayDistance = 0
		humanoid.RequiresNeck = false
		humanoid.BreakJointsOnDeath = false
		humanoid.EvaluateStateMachine = false
		humanoid.AutomaticScalingEnabled = false
	end
end

-- Reads the joint graph of a stripped R15 model into an AvatarRig spec.
local function readSpec(model: Model): (any?, { BasePart })
	local list: { BasePart } = {}
	local index: { [BasePart]: number } = {}
	local parts = {}
	local root = model:FindFirstChild("HumanoidRootPart")
	if not (root and root:IsA("BasePart")) then
		return nil, list
	end
	local isLimb = {}
	for _, limb in Poses.LIMBS do
		isLimb[limb] = true
	end
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then
			table.insert(list, d)
			index[d] = #list
			local limb = if d.Parent == model and isLimb[d.Name] then d.Name else nil
			table.insert(parts, { size = d.Size, limb = limb })
		end
	end
	local edges: { AvatarRig.Edge } = {}
	local joints = {}
	for _, d in model:GetDescendants() do
		if d:IsA("JointInstance") then
			local j = d :: JointInstance
			local a, b = j.Part0 and index[j.Part0], j.Part1 and index[j.Part1]
			if a and b then
				local motor = j:IsA("Motor6D") and parts[b].limb ~= nil and (parts[a].limb ~= nil or a == index[root])
				table.insert(edges, { a = a, b = b, rel = j.C0 * j.C1:Inverse(), motor = motor })
				if motor then
					joints[parts[b].limb] = { part0 = a, c0 = j.C0 }
				end
			end
		elseif d:IsA("WeldConstraint") then
			local w = d :: WeldConstraint
			local a, b = w.Part0 and index[w.Part0], w.Part1 and index[w.Part1]
			if a and b then
				table.insert(edges, { a = a, b = b, rel = (w.Part0 :: BasePart).CFrame:ToObjectSpace((w.Part1 :: BasePart).CFrame) })
			end
		elseif d:IsA("AnimationConstraint") then
			-- Upgraded avatar joints: an AnimationConstraint between two rig
			-- attachments stands in for the Motor6D (C0 = Attachment0, C1 = Attachment1).
			local c = d :: AnimationConstraint
			local a0, a1 = c.Attachment0, c.Attachment1
			local p0 = a0 and a0.Parent
			local p1 = a1 and a1.Parent
			if a0 and a1 and p0 and p1 and p0:IsA("BasePart") and p1:IsA("BasePart") and index[p0] and index[p1] then
				local a, b = index[p0], index[p1]
				local motor = parts[b].limb ~= nil and (parts[a].limb ~= nil or a == index[root])
				table.insert(edges, { a = a, b = b, rel = a0.CFrame * a1.CFrame:Inverse(), motor = motor })
				if motor then
					joints[parts[b].limb] = { part0 = a, c0 = a0.CFrame }
				end
			end
		elseif d:IsA("RigidConstraint") then
			local r = d :: RigidConstraint
			local a0, a1 = r.Attachment0, r.Attachment1
			local p0 = a0 and a0.Parent
			local p1 = a1 and a1.Parent
			if a0 and a1 and p0 and p1 and p0:IsA("BasePart") and p1:IsA("BasePart") and index[p0] and index[p1] then
				table.insert(edges, { a = index[p0], b = index[p1], rel = a0.CFrame * a1.CFrame:Inverse() })
			end
		end
	end
	return { parts = parts, root = index[root], edges = edges, joints = joints }, list
end

-- Builds the avatar actor model. `refHipY` is the part-built hero's hip
-- height (so gaits keep the feet planted at the avatar's own scale).
-- Strips `model` and rigs it as an intro actor; nil (model destroyed) when it is
-- not a usable R15 rig.
local function prepare(model: Model, name: string, refHipY: number, seed: number, animSet: string): Built?
	local ok, built = pcall(function(): Built?
		local humanoid = model:FindFirstChildOfClass("Humanoid")
		if not humanoid or humanoid.RigType ~= Enum.HumanoidRigType.R15 then
			return nil
		end
		strip(model)
		local spec, list = readSpec(model)
		if not spec then
			return nil
		end
		local desc, why = AvatarRig.describe(spec, Poses.LIMBS)
		if not desc then
			warn("[Intro] avatar hero unavailable: " .. tostring(why))
			return nil
		end

		-- Joints go (BulkMoveTo places every part itself); parts nothing reached go too.
		for _, d in model:GetDescendants() do
			if d:IsA("JointInstance") or d:IsA("WeldConstraint") or d:IsA("RigidConstraint") or d:IsA("AnimationConstraint") then
				d:Destroy()
			end
		end
		local instances: { [number]: BasePart } = {}
		for i, part in list do
			if desc.rest[i] then
				instances[i] = part
				part.Anchored = true
				part.CanCollide = false
				part.CanTouch = false
				part.CanQuery = false
				part.Massless = true
			else
				part:Destroy()
			end
		end

		local root = Instance.new("Part")
		root.Name = "IntroRoot"
		root.Size = Vector3.new(0.2, 0.2, 0.2)
		root.Transparency = 1
		root.Anchored = true
		root.CanCollide = false
		root.CanTouch = false
		root.CanQuery = false
		root.CastShadow = false
		root.Parent = model
		model.PrimaryPart = root
		model.Name = name

		local scale = math.clamp(desc.hipY / math.max(refHipY, 0.1), 0.4, 3)
		local rig = AvatarRig.rig(desc, instances, root, model, scale, seed)
		rig.animSet = animSet
		model:SetAttribute("Height", desc.height)
		model:SetAttribute("RigScale", scale)
		return { model = model, rig = rig, scale = scale, height = desc.height }
	end)
	if ok and built then
		return built
	end
	if not ok then
		warn("[Intro] avatar hero failed: " .. tostring(built))
	end
	model:Destroy()
	return nil
end

function Avatar.build(player: Player, name: string, refHipY: number, seed: number, animSet: string): Built?
	local deadline = os.clock() + CHARACTER_WAIT + APPEARANCE_WAIT + CREATE_WAIT
	local forceR15 = RunService:IsStudio() and player:GetAttribute("IntroForceR15Build") == true
	local model = if forceR15 then nil else Avatar.fetch(player)
	if model then
		local built = prepare(model, name, refHipY, seed, animSet)
		if built then
			return built
		end
	end
	-- R6 avatars (and clones that fail the R15 checks): the same avatar rebuilt as R15.
	local rebuilt = r15FromDescription(player, math.min(CREATE_WAIT, deadline - os.clock()))
	if rebuilt then
		return prepare(rebuilt, name, refHipY, seed, animSet)
	end
	return nil
end

-- Faces ----------------------------------------------------------------------

-- Every emotion the hero acts out; each has an image "faces/<Emotion>".
Avatar.EMOTIONS = { "Happy", "Proud", "Shock", "Awe", "Sad", "Idea", "Fury", "Smirk" }

-- The nearest expression of the part-built hero (Happy, Sad, Shock, Determined).
Avatar.FALLBACK = {
	Happy = "Happy",
	Proud = "Happy",
	Shock = "Shock",
	Awe = "Shock",
	Sad = "Sad",
	Idea = "Happy",
	Fury = "Determined",
	Smirk = "Happy",
} :: { [string]: string }

-- FaceControls poses (0..1) for dynamic heads. Every property in CONTROLS that a
-- pose leaves out eases back to 0.
local CONTROLS = {
	"LeftLipCornerPuller",
	"RightLipCornerPuller",
	"LeftLipCornerDown",
	"RightLipCornerDown",
	"LeftCheekRaiser",
	"RightCheekRaiser",
	"LeftDimpler",
	"RightDimpler",
	"JawDrop",
	"Funneler",
	"LeftUpperLipRaiser",
	"RightUpperLipRaiser",
	"LeftLowerLipDepressor",
	"RightLowerLipDepressor",
	"LeftLipStretcher",
	"RightLipStretcher",
	"ChinRaiser",
	"LeftInnerBrowRaiser",
	"RightInnerBrowRaiser",
	"LeftOuterBrowRaiser",
	"RightOuterBrowRaiser",
	"LeftBrowLowerer",
	"RightBrowLowerer",
	"LeftUpperLidRaiser",
	"RightUpperLidRaiser",
	"LeftEyeClosed",
	"RightEyeClosed",
	"EyesLookUp",
	"EyesLookDown",
}
Avatar.FACE_CONTROLS = CONTROLS

local function both(pose: { [string]: number }, name: string, value: number)
	pose["Left" .. name] = value
	pose["Right" .. name] = value
end

local function pose(build: ({ [string]: number }) -> ()): { [string]: number }
	local p = {}
	build(p)
	return p
end

Avatar.FACE_POSES = {
	Happy = pose(function(p)
		both(p, "LipCornerPuller", 0.9)
		both(p, "CheekRaiser", 0.5)
		both(p, "InnerBrowRaiser", 0.25)
		p.JawDrop = 0.25
	end),
	Proud = pose(function(p)
		p.LeftLipCornerPuller = 0.6
		p.RightLipCornerPuller = 0.95
		p.RightOuterBrowRaiser = 0.6
		both(p, "CheekRaiser", 0.35)
		both(p, "Dimpler", 0.3)
	end),
	Shock = pose(function(p)
		p.JawDrop = 0.8
		p.Funneler = 0.3
		both(p, "UpperLidRaiser", 1)
		both(p, "InnerBrowRaiser", 1)
		both(p, "OuterBrowRaiser", 0.9)
	end),
	Awe = pose(function(p)
		p.EyesLookUp = 0.7
		p.JawDrop = 0.35
		p.Funneler = 0.5
		both(p, "UpperLidRaiser", 0.6)
		both(p, "InnerBrowRaiser", 0.7)
		both(p, "OuterBrowRaiser", 0.5)
	end),
	Sad = pose(function(p)
		both(p, "LipCornerDown", 0.85)
		both(p, "InnerBrowRaiser", 0.9)
		p.EyesLookDown = 0.4
		p.ChinRaiser = 0.4
	end),
	Idea = pose(function(p)
		both(p, "LipCornerPuller", 0.8)
		both(p, "UpperLidRaiser", 0.7)
		both(p, "InnerBrowRaiser", 0.8)
		both(p, "OuterBrowRaiser", 0.8)
		p.JawDrop = 0.4
	end),
	Fury = pose(function(p)
		both(p, "BrowLowerer", 1)
		both(p, "LipCornerPuller", 0.55)
		both(p, "LipStretcher", 0.6)
		both(p, "UpperLipRaiser", 0.5)
		both(p, "LowerLipDepressor", 0.4)
		both(p, "EyeClosed", 0.15)
	end),
	Smirk = pose(function(p)
		p.RightLipCornerPuller = 0.85
		p.LeftLipCornerPuller = 0.15
		p.RightDimpler = 0.5
		p.RightOuterBrowRaiser = 0.6
		p.LeftEyeClosed = 0.2
	end),
} :: { [string]: { [string]: number } }

-- What attachFace reads off a head.
export type HeadInfo = {
	faceControls: boolean,
	faceDecal: boolean,
}

-- How a head shows emotions: "Controls" (dynamic head: pose its FaceControls),
-- "Swap" (classic "face" decal: swap its image) or "None" (no face decal: the
-- face is painted into the head's texture, so a decal would draw a second face
-- on top of it; keep the face as it is).
function Avatar.faceStrategy(info: HeadInfo): string
	if info.faceControls then
		return "Controls"
	end
	if info.faceDecal then
		return "Swap"
	end
	return "None"
end

export type Face = {
	strategy: string,
	head: BasePart,
	decal: Decal?, -- the face image (the avatar's own decal for "Swap")
	top: Decal?, -- the next image, faded in over `decal`
	controls: FaceControls?,
	tweens: { Tween },
	current: string?,
}

-- Reads the clone's head; nil keeps the avatar's own face for the whole cutscene.
function Avatar.attachFace(model: Model): Face?
	local ok, face = pcall(function(): Face?
		local head = model:FindFirstChild("Head")
		if not head or not head:IsA("BasePart") then
			return nil
		end
		local found = head:FindFirstChild("face")
		local decal = if found and found:IsA("Decal") then found else nil
		local controls = head:FindFirstChildOfClass("FaceControls")
		local strategy = Avatar.faceStrategy({
			faceControls = controls ~= nil,
			faceDecal = decal ~= nil,
		})
		if strategy == "None" then
			return nil
		end
		return {
			strategy = strategy,
			head = head,
			decal = decal,
			top = nil,
			controls = controls,
			tweens = {},
			current = nil,
		}
	end)
	if ok then
		return face
	end
	warn("[Intro] hero face unavailable: " .. tostring(face))
	return nil
end

local function faceDecal(head: BasePart, name: string, z: number): Decal
	local decal = Instance.new("Decal")
	decal.Name = name
	decal.Face = Enum.NormalId.Front
	decal.ZIndex = z
	decal.Transparency = 1
	decal.Parent = head
	return decal
end

local function play(face: Face, target: Instance, seconds: number, goal: { [string]: any })
	local tween = TweenService:Create(target, TweenInfo.new(seconds, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), goal)
	table.insert(face.tweens, tween)
	tween:Play()
	return tween
end

-- Shows `emotion` on the face: FaceControls ease over 0.15 s, decal images
-- cross-fade over 0.1 s. Unknown emotions, missing images and errors leave the
-- face as it is. Returns false when something errored.
function Avatar.setFace(face: Face, emotion: string): boolean
	if face.current == emotion then
		return true
	end
	local ok, err = pcall(function(): nil
		for _, tween in face.tweens do
			tween:Cancel()
		end
		table.clear(face.tweens)

		if face.strategy == "Controls" then
			local target = Avatar.FACE_POSES[emotion]
			local controls = face.controls
			if not target or not controls then
				return nil
			end
			local goal = {}
			for _, prop in CONTROLS do
				if pcall(function()
					return (controls :: any)[prop]
				end) then
					goal[prop] = target[prop] or 0
				end
			end
			play(face, controls, 0.15, goal)
			face.current = emotion
			return nil
		end

		local image = Assets.image("faces/" .. emotion)
		if not image then
			return nil
		end
		local base = face.decal or faceDecal(face.head, "IntroFace", 1)
		face.decal = base
		local top = face.top or faceDecal(face.head, "IntroFaceNext", base.ZIndex + 1)
		face.top = top
		if top.Transparency < 1 then
			-- a fade was cut short: settle on the image it was fading to
			base.Texture = top.Texture
			top.Transparency = 1
		end
		base.Face = Enum.NormalId.Front
		base.Color3 = Color3.new(1, 1, 1)
		top.Color3 = Color3.new(1, 1, 1)
		if face.current == nil then
			base.Texture = image
			base.Transparency = 0
		else
			top.Texture = image
			base.Transparency = 0
			play(face, base, 0.1, { Transparency = 1 })
			play(face, top, 0.1, { Transparency = 0 }).Completed:Connect(function(state)
				if state == Enum.PlaybackState.Completed then
					base.Texture = image
					base.Transparency = 0
					top.Transparency = 1
				end
			end)
		end
		face.current = emotion
		return nil
	end)
	if not ok then
		warn("[Intro] hero face change failed: " .. tostring(err))
	end
	return ok
end

return Avatar
