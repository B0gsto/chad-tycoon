--!strict
--[[
	ShakeRules: the pure rules of SHAKE CATCH (Modes.Shake; docs/minigames.md). No Roblox
	services: tests/shake.luau loads it with Lune.

	TODO(shake builder): spawn waves (shakes vs junk food), catching and dodging, score and the pass mark, the difficulty curve.

	ARENA is where World.ShakeArena builds the arena (floor top centre and size in studs,
	out over the sea away from the Parkour maps, the Mog stage and the Cardio track; tests/
	minigames.luau keeps every arena clear of the others).
]]

local ShakeRules = {}

ShakeRules.ARENA = { x = 380, y = 6, z = -380, sizeX = 64, sizeZ = 64 }
-- Feet more than this far under the floor top: the player fell off and goes back to the spawn.
ShakeRules.FALL_BELOW = 20

return ShakeRules
