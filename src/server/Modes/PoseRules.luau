--!strict
--[[
	PoseRules: the pure rules of POSE COPY (Modes.Pose; docs/minigames.md). No Roblox
	services: tests/pose.luau loads it with Lune.

	TODO(pose builder): the flex list, the sequence that grows one flex every round, input timing and the pass mark.

	ARENA is where World.PoseStage builds the arena (floor top centre and size in studs,
	out over the sea away from the Parkour maps, the Mog stage and the Cardio track; tests/
	minigames.luau keeps every arena clear of the others).
]]

local PoseRules = {}

PoseRules.ARENA = { x = 560, y = 6, z = -380, sizeX = 56, sizeZ = 48 }
-- Feet more than this far under the floor top: the player fell off and goes back to the spawn.
PoseRules.FALL_BELOW = 20

return PoseRules
