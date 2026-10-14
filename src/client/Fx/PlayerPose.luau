--!strict
--[[
	Fx.PlayerPose: makes a real R15 avatar (the local player's own, or a duel opponent's)
	strike the game's poses (Poses, the same library the units and rivals use) and play short
	full-body moves, by overriding its joint transforms (the Motor6Ds, or the
	AnimationConstraints an avatar with upgraded joints has instead) every frame after Roblox's
	animations have run. Local only: each client poses the characters it sees itself.

	  PlayerPose.attach(character, layered?)
	                                a Poser holding the joints, standing HandsOnHips, or nil
	                                for a missing or R6 avatar (an R15 one still loading is
	                                held anyway and posed once its joints turn up); a layered
	                                one only poses the upper body while its player walks or
	                                is in the air (see Layered)
	  poser:strike(pose, hop?)      snap into `pose` (any Poses name) with an eased blend,
	                                plus an optional hop (studs)
	  poser:play(keys, release?)    a move: the keys (see Key) one after another, then the
	                                last one held; with `release` the avatar is handed back
	                                once the move is over, or as soon as its player walks
	  poser:stop()                  hand the joints back to the avatar's animations (also
	                                done on its own when the character leaves the world)
	  PlayerPose.nextPose(pool?)    the next pose from a shuffled bag of `pool` (default: the
	                                Chad rotation)

	Root motion: a key's `root` moves the whole body at the hips (the LowerTorso joint) in the
	character's own frame (+X its right, +Y up, it faces -Z; studs at scale 1), so a move can
	step in, recoil, lean or twist without moving the humanoid. The legs take the root's
	rotation back out, so a lean bends at the waist over feet that stay put. A key's `legs`
	pose drives the legs and hips under the main pose's upper body (a flex on a lunge). Blends
	may overshoot (Back easing goes past the key and settles), joints and root alike.

	Layered: while the avatar walks or is in the air the hips and legs ease back (LAYER_BLEND)
	to its own animations (walk, run, jump), so a carry or a catch moves the arms and torso
	over walking legs; the root's turn then bends the waist instead, and a hop still lifts
	the whole body. Standing still, the move gets the whole body again (knee dips, stances).

	A pose transform is a rotation at the joint in the parent limb's frame; a joint Transform
	is the same rotation turned into the joint's C0 frame.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Poses = require(ReplicatedStorage.Shared:WaitForChild("Poses")) :: any

local PlayerPose = {}

local SET = "Chad"
local BLEND = 0.22 -- seconds to snap into a new pose
local HOP_TIME = 0.32
local RECOLLECT = 1 -- seconds between looks for the joints of an avatar still loading
local WALK_OFF = 0.1 -- MoveDirection magnitude that ends a released move
local LAYER_BLEND = 0.18 -- seconds a layered poser takes to hand the legs over (or back)

-- The limbs a key's `legs` pose drives (the hips carry the crouch's root drop).
local LEGS = {
	LowerTorso = true,
	LeftUpperLeg = true,
	LeftLowerLeg = true,
	LeftFoot = true,
	RightUpperLeg = true,
	RightLowerLeg = true,
	RightFoot = true,
}
local THIGHS = { LeftUpperLeg = true, RightUpperLeg = true }

-- One step of a move.
export type Key = {
	pose: string, -- any Poses name
	legs: string?, -- a pose for the legs and hips instead of `pose`'s own
	blend: number?, -- seconds into the key (default BLEND)
	hold: number?, -- seconds held after the blend before the next key (default 0)
	ease: Enum.EasingStyle?, -- default Quint
	dir: Enum.EasingDirection?, -- default Out
	root: CFrame?, -- whole-body offset at the hips (default none: back to the spot)
	hop: number?, -- studs: a jump arc starting with the key
	hopTime: number?, -- seconds of that arc (default HOP_TIME)
	cue: (() -> ())?, -- called once the blend lands (an impact: camera punch, sound)
}

export type Poser = {
	strike: (self: Poser, pose: string, hop: number?) -> (),
	play: (self: Poser, keys: { Key }, release: boolean?) -> (),
	stop: (self: Poser) -> (),
}

-- A limb's joint to its parent limb: the Motor6D, or on an avatar with upgraded joints the
-- AnimationConstraint between two rig attachments that stands in for it (its C0 is
-- Attachment0). Both are animated, and posed, through their Transform.
type Joint = { motor: Motor6D | AnimationConstraint, rot: CFrame, rotInv: CFrame }

local function collect(character: Model): { [string]: Joint }?
	local joints: { [string]: Joint } = {}
	local function add(motor: Motor6D | AnimationConstraint, limb: string, c0: CFrame)
		if not joints[limb] and table.find(Poses.LIMBS, limb) then
			local rot = c0.Rotation
			joints[limb] = { motor = motor, rot = rot, rotInv = rot:Inverse() }
		end
	end
	for _, d in character:GetDescendants() do
		if d:IsA("Motor6D") then
			if d.Part1 then
				add(d, d.Part1.Name, d.C0)
			end
		elseif d:IsA("AnimationConstraint") then
			local a0, a1 = d.Attachment0, d.Attachment1
			local limb = a1 and a1.Parent
			if a0 and limb and limb:IsA("BasePart") then
				add(d, limb.Name, a0.CFrame)
			end
		end
	end
	return if joints.LowerTorso and joints.UpperTorso then joints else nil
end

-- `a` part way to `b` by `w`, which may run past 1 (an overshoot): the rotation turns about
-- one axis, the position moves in a straight line.
local function mix(a: CFrame, b: CFrame, w: number): CFrame
	if w == 1 then
		return b
	end
	local axis, angle = (a.Rotation:Inverse() * b.Rotation):ToAxisAngle()
	local turn = if math.abs(angle) > 1e-5 then CFrame.fromAxisAngle(axis, angle * w) else CFrame.identity
	return CFrame.new(a.Position + (b.Position - a.Position) * w) * a.Rotation * turn
end

local function isR6(character: Model): boolean
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	return humanoid ~= nil and humanoid.RigType == Enum.HumanoidRigType.R6
end

function PlayerPose.attach(character: Model?, layered: boolean?): Poser?
	if not character or not character.Parent or isR6(character) then
		return nil
	end
	local model = character :: Model
	local joints = collect(model)
	local collectedAt = os.clock()
	local scale = model:GetScale()
	local seed = math.random() * 100 -- so two avatars never breathe in step

	local keys: { Key } = { { pose = "HandsOnHips" } }
	local index = 1
	local keyAt = os.clock()
	local cued = false
	local release = false
	-- Where the last frame left every limb (pose space) and the root: the next key blends
	-- from there. The first blend starts from the avatar standing straight.
	local from: { [string]: CFrame } = {}
	for _, limb in Poses.LIMBS do
		from[limb] = CFrame.identity
	end
	local applied: { [string]: CFrame } = table.clone(from)
	local fromRoot, appliedRoot = CFrame.identity, CFrame.identity
	local target: { [string]: CFrame } = {}
	local legTarget: { [string]: CFrame } = {}
	local hopAt, hopHeight, hopTime = -math.huge, 0, HOP_TIME
	-- How much of the move the hips and legs take (layered: 0 while walking or in the air).
	local legWeight = if layered then 0 else 1

	local poser = {} :: Poser
	local stopped = false
	local conn: RBXScriptConnection

	local function length(key: Key): number
		return (key.blend or BLEND) + (key.hold or 0)
	end

	local function begin(i: number, now: number)
		from = table.clone(applied)
		fromRoot = appliedRoot
		index, keyAt, cued = i, now, false
		local key = keys[i]
		if key.hop and key.hop > 0 then
			hopAt, hopHeight, hopTime = now, key.hop, key.hopTime or HOP_TIME
		end
	end

	conn = RunService.PreSimulation:Connect(function(dt: number)
		if not model.Parent then
			poser:stop() -- respawned or left: nothing to hand back
			return
		end
		local now = os.clock()
		while keys[index + 1] and now - keyAt >= length(keys[index]) do
			begin(index + 1, now)
		end
		local key = keys[index]
		if release then
			local humanoid = model:FindFirstChildOfClass("Humanoid")
			local walking = humanoid and humanoid.MoveDirection.Magnitude > WALK_OFF
			if walking or (index == #keys and now - keyAt >= length(key)) then
				poser:stop()
				return
			end
		end
		if not joints or not joints.UpperTorso.motor.Parent then
			if now - collectedAt < RECOLLECT then
				return
			end
			joints = collect(model)
			collectedAt = now
			if not joints then
				return
			end
		end
		local live = joints :: { [string]: Joint }
		if layered then
			local humanoid = model:FindFirstChildOfClass("Humanoid")
			local busy = humanoid ~= nil and (humanoid.MoveDirection.Magnitude > WALK_OFF or humanoid.FloorMaterial == Enum.Material.Air)
			local step = math.max(dt, 1 / 240) / LAYER_BLEND
			legWeight = math.clamp(legWeight + (if busy then -step else step), 0, 1)
		end

		local blend = key.blend or BLEND
		local alpha = if blend > 0 then math.clamp((now - keyAt) / blend, 0, 1) else 1
		local w = TweenService:GetValue(alpha, key.ease or Enum.EasingStyle.Quint, key.dir or Enum.EasingDirection.Out)
		if alpha >= 1 then
			w = 1
			if not cued then
				cued = true
				if key.cue then
					task.spawn(key.cue)
				end
			end
		end
		Poses.samplePoseInto(target, SET, key.pose, now + seed, 0)
		if key.legs then
			Poses.samplePoseInto(legTarget, SET, key.legs, now + seed, 0)
		end
		appliedRoot = mix(fromRoot, key.root or CFrame.identity, w)
		local rootRot = appliedRoot.Rotation
		local breath = math.rad(math.sin((now + seed) * 1.75) * 1.6)
		local hopT = now - hopAt
		local lift = if hopT < hopTime then math.sin(hopT / hopTime * math.pi) * hopHeight else 0
		local counter = CFrame.identity
		for _, limb in Poses.LIMBS do
			local goal = if key.legs and LEGS[limb] then legTarget[limb] else target[limb]
			local cf = mix(from[limb], goal, w)
			applied[limb] = cf
			local rotation = cf.Rotation
			if limb == "LowerTorso" then
				-- The legs undo the root's turn, so it bends the body at the waist.
				counter = rotation:Inverse() * rootRot:Inverse() * rotation
				rotation = rootRot * rotation
			elseif THIGHS[limb] then
				rotation = counter * rotation
			elseif limb == "UpperTorso" then
				rotation *= CFrame.Angles(breath, 0, 0)
				if legWeight < 1 then
					-- Walking hips: the root's lean and twist bend the waist instead.
					rotation = mix(CFrame.identity, rootRot, 1 - legWeight) * rotation
				end
			end
			local joint = live[limb]
			if not joint or not joint.motor.Parent then
				continue
			end
			local transform = joint.rotInv * rotation * joint.rot
			if limb == "LowerTorso" then
				local offset = appliedRoot.Position + Vector3.new(0, cf.Y, 0)
				transform = CFrame.new(joint.rotInv * offset * scale) * transform
			end
			if legWeight < 1 and LEGS[limb] then
				-- Layered and walking: the avatar's own animation (written this frame) under it.
				local own = (joint.motor :: any).Transform :: CFrame
				transform = if legWeight <= 0 then own else own:Lerp(transform, legWeight)
			end
			if limb == "LowerTorso" and lift > 0 then
				transform = CFrame.new(joint.rotInv * Vector3.new(0, lift, 0) * scale) * transform
			end
			-- Both joint classes have Transform; the union hides it from the type checker.
			(joint.motor :: any).Transform = transform
		end
	end)

	function poser.play(_self: Poser, moveKeys: { Key }, releaseAfter: boolean?)
		if stopped or #moveKeys == 0 then
			return
		end
		keys = moveKeys
		release = releaseAfter == true
		begin(1, os.clock())
	end

	function poser.strike(self: Poser, pose: string, hop: number?)
		self:play({ { pose = pose, hop = hop } })
	end

	function poser.stop(_self: Poser)
		if stopped then
			return
		end
		stopped = true
		conn:Disconnect()
		if joints then
			for _, joint in joints do
				if joint.motor.Parent then
					(joint.motor :: any).Transform = CFrame.identity
				end
			end
		end
	end

	return poser
end

local bags: { [any]: { string } } = {}
local lasts: { [any]: string } = {}

function PlayerPose.nextPose(pool: { string }?): string
	local id = pool or SET
	local bag = bags[id]
	if not bag or #bag == 0 then
		local names: { string }
		if pool then
			names = table.clone(pool)
		else
			names = Poses.poseNames(SET)
			table.remove(names, 1) -- the rest pose
		end
		for i = #names, 2, -1 do
			local j = math.random(1, i)
			names[i], names[j] = names[j], names[i]
		end
		-- The bag is drawn from the end: never repeat the previous bag's last pose.
		if #names > 1 and names[#names] == lasts[id] then
			names[1], names[#names] = names[#names], names[1]
		end
		bag = names
		bags[id] = names
	end
	local pose = table.remove(bag) :: string
	lasts[id] = pose
	return pose
end

return PlayerPose
