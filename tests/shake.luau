--[[
	Unit tests for the Shake rules (src/server/Modes/ShakeRules.luau; docs/minigames.md).
	TODO(shake builder): test the rules here (this file is the shake builder's own).
	Loaded by tests/run.luau with its harness: { test, check, eq, near, seeded }.
]]

local fs = require("@lune/fs")
local luau = require("@lune/luau")

return function(h: { [string]: any })
	local test, check = h.test, h.check
	local ShakeRules = luau.load(fs.readFile("src/server/Modes/ShakeRules.luau"), { debugName = "ShakeRules" })()

	test("Shake: the rules module loads", function()
		local a = ShakeRules.ARENA
		check(type(a) == "table" and a.sizeX > 0 and a.sizeZ > 0, "ARENA has a size")
		check(ShakeRules.FALL_BELOW > 0, "FALL_BELOW is positive")
	end)
end
