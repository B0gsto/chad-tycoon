--[[
	Unit tests for the Pose rules (src/server/Modes/PoseRules.luau; docs/minigames.md).
	TODO(pose builder): test the rules here (this file is the pose builder's own).
	Loaded by tests/run.luau with its harness: { test, check, eq, near, seeded }.
]]

local fs = require("@lune/fs")
local luau = require("@lune/luau")

return function(h: { [string]: any })
	local test, check = h.test, h.check
	local PoseRules = luau.load(fs.readFile("src/server/Modes/PoseRules.luau"), { debugName = "PoseRules" })()

	test("Pose: the rules module loads", function()
		local a = PoseRules.ARENA
		check(type(a) == "table" and a.sizeX > 0 and a.sizeZ > 0, "ARENA has a size")
		check(PoseRules.FALL_BELOW > 0, "FALL_BELOW is positive")
	end)
end
