--!strict
--[[
	Fx.PlayerPose: makes a real R15 avatar (the local player's own, or a duel opponent's)
	strike the game's poses (Poses, the same library the units and rivals use) by
	overriding its Motor6D transforms every frame after Roblox's animations have run.
	Local only: each client poses the characters it sees itself.

	  PlayerPose.attach(character)  a Poser holding the joints, standing HandsOnHips, or nil
	                                for an R6 / missing avatar
	  poser:strike(pose, hop?)      snap into `pose` (any Poses name) with an eased blend,
	                                plus an optional hop (studs)
	  poser:stop()                  hand the joints back to the avatar's animations
	  PlayerPose.nextPose()         the next pose from a shuffled bag of the Chad rotation

	A pose transform is a rotation at the joint in the parent limb's frame; a Motor6D
	Transform is the same rotation turned into the joint's C0 frame.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Poses = require(ReplicatedStorage.Shared:WaitForChild("Poses")) :: any

local PlayerPose = {}

local SET = "Chad"
local BLEND = 0.22 -- seconds to snap into a new pose
local HOP_TIME = 0.32

type Joint = { motor: Motor6D, rot: CFrame, rotInv: CFrame }

export type Poser = {
	strike: (self: Poser, pose: string, hop: number?) -> (),
	stop: (self: Poser) -> (),
}

local function collect(character: Model): { [string]: Joint }?
	local joints: { [string]: Joint } = {}
	for _, d in character:GetDescendants() do
		if d:IsA("Motor6D") and d.Part1 then
			local limb = d.Part1.Name
			if not joints[limb] and table.find(Poses.LIMBS, limb) then
				local rot = d.C0.Rotation
				joints[limb] = { motor = d, rot = rot, rotInv = rot:Inverse() }
			end
		end
	end
	return if joints.LowerTorso and joints.UpperTorso then joints else nil
end

function PlayerPose.attach(character: Model?): Poser?
	local joints = if character then collect(character) else nil
	if not character or not joints then
		return nil
	end
	local scale = character:GetScale()
	local seed = math.random() * 100 -- so two avatars never breathe in step
	local current = "HandsOnHips"
	local changedAt = os.clock() - BLEND
	local from: { [string]: CFrame } = {}
	local target: { [string]: CFrame } = {}
	local applied: { [string]: CFrame } = {}
	local hopAt, hopHeight = -math.huge, 0

	local conn = RunService.PreSimulation:Connect(function()
		local now = os.clock()
		local alpha = math.clamp((now - changedAt) / BLEND, 0, 1)
		local w = TweenService:GetValue(alpha, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)
		Poses.samplePoseInto(target, SET, current, now + seed, 0)
		local breath = math.rad(math.sin((now + seed) * 1.75) * 1.6)
		local hopT = now - hopAt
		local lift = if hopT < HOP_TIME then math.sin(hopT / HOP_TIME * math.pi) * hopHeight else 0
		for _, limb in Poses.LIMBS do
			local goal = target[limb]
			local start = from[limb]
			local cf = if start and w < 1 then start:Lerp(goal, w) else goal
			applied[limb] = cf
			local joint = joints[limb]
			if not joint or not joint.motor.Parent then
				continue
			end
			local rotation = cf.Rotation
			if limb == "UpperTorso" then
				rotation *= CFrame.Angles(breath, 0, 0)
			end
			local transform = joint.rotInv * rotation * joint.rot
			if limb == "LowerTorso" then
				transform = CFrame.new(joint.rotInv * Vector3.new(0, (cf.Y + lift) * scale, 0)) * transform
			end
			joint.motor.Transform = transform
		end
	end)

	local poser = {} :: Poser
	local stopped = false

	function poser.strike(_self: Poser, pose: string, hop: number?)
		if stopped then
			return
		end
		from = table.clone(applied)
		current = pose
		changedAt = os.clock()
		if hop and hop > 0 then
			hopAt, hopHeight = changedAt, hop
		end
	end

	function poser.stop(_self: Poser)
		if stopped then
			return
		end
		stopped = true
		conn:Disconnect()
		for _, joint in joints do
			if joint.motor.Parent then
				joint.motor.Transform = CFrame.identity
			end
		end
	end

	return poser
end

local bag: { string } = {}
local last: string? = nil

function PlayerPose.nextPose(): string
	if #bag == 0 then
		local names = Poses.poseNames(SET)
		table.remove(names, 1) -- the rest pose
		for i = #names, 2, -1 do
			local j = math.random(1, i)
			names[i], names[j] = names[j], names[i]
		end
		-- The bag is drawn from the end: never repeat the previous bag's last pose.
		if #names > 1 and names[#names] == last then
			names[1], names[#names] = names[#names], names[1]
		end
		bag = names
	end
	local pose = table.remove(bag) :: string
	last = pose
	return pose
end

return PlayerPose
