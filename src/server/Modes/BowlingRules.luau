--!strict
--[[
	BowlingRules: the pure rules of DUMBBELL BOWL (Modes.Bowling; docs/minigames.md). No Roblox
	services: tests/bowling.luau loads it with Lune.

	TODO(bowling builder): the roll (aim and power), pin physics or pin-fall rules, frames and score, the pass mark.

	ARENA is where World.BowlingLane builds the arena (floor top centre and size in studs,
	out over the sea away from the Parkour maps, the Mog stage and the Cardio track; tests/
	minigames.luau keeps every arena clear of the others).
]]

local BowlingRules = {}

BowlingRules.ARENA = { x = 740, y = 6, z = -380, sizeX = 30, sizeZ = 110 }
-- Feet more than this far under the floor top: the player fell off and goes back to the spawn.
BowlingRules.FALL_BELOW = 20

return BowlingRules
