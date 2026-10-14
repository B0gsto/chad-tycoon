--!strict
--[[
	PoseStage: the POSE COPY arena out at sea (teleport-only; Modes.Pose brings players here).
	Numbers live in Modes.PoseRules.ARENA; the shell (floor, spawn pad, exit arch) comes from
	World.Arena. TODO(pose builder): dress it (props, signs, fans) and add the game's parts.

	build() -> Built: everything World.Arena.Base has ({ folder, floor, spawn, exit,
	exitRadius, center, top }) plus
	playerSpot feet CFrame where the player stands, facing the rival
	rivalSpot  feet CFrame where the rival poser stands, facing the player
	rival      empty Model "Rival" for the rival rig (Modes.Pose fills it)
]]

local Common = require(script.Parent.Common)
local Arena = require(script.Parent.Arena)
local PoseRules = require(script.Parent.Parent.Modes.PoseRules)

local W = Common.theme.World
local make = Common.make

local PoseStage = {}

export type Built = Arena.Base & {
	playerSpot: CFrame,
	rivalSpot: CFrame,
	rival: Model,
}

function PoseStage.build(): Built
	local a = PoseRules.ARENA
	local base = Arena.base("pose", "PoseStage", a, { floor = "Cream", trim = "Blue" })
	local top = base.top
	local playerPos = Vector3.new(a.x, top, a.z + 6)
	local rivalPos = Vector3.new(a.x, top, a.z - 10)
	local pads: { { pos: Vector3, color: Color3, name: string } } = {
		{ pos = playerPos, color = W.Sunny, name = "PlayerPad" },
		{ pos = rivalPos, color = W.Grape, name = "RivalPad" },
	}
	for _, pad in pads do
		make("Part", {
			Name = pad.name,
			Shape = Enum.PartType.Cylinder,
			Size = Vector3.new(0.4, 8, 8),
			CFrame = CFrame.new(pad.pos + Vector3.new(0, 0.2, 0)) * Common.UPRIGHT,
			Color = pad.color,
			Parent = base.folder,
		})
	end
	local rival = Instance.new("Model")
	rival.Name = "Rival"
	rival.Parent = base.folder
	local built: any = base
	built.playerSpot = CFrame.lookAt(playerPos, rivalPos)
	built.rivalSpot = CFrame.lookAt(rivalPos, playerPos)
	built.rival = rival
	return built :: Built
end

return PoseStage
