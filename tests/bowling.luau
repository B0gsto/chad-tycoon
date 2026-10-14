--[[
	Unit tests for the Bowling rules (src/server/Modes/BowlingRules.luau; docs/minigames.md).
	TODO(bowling builder): test the rules here (this file is the bowling builder's own).
	Loaded by tests/run.luau with its harness: { test, check, eq, near, seeded }.
]]

local fs = require("@lune/fs")
local luau = require("@lune/luau")

return function(h: { [string]: any })
	local test, check = h.test, h.check
	local BowlingRules = luau.load(fs.readFile("src/server/Modes/BowlingRules.luau"), { debugName = "BowlingRules" })()

	test("Bowling: the rules module loads", function()
		local a = BowlingRules.ARENA
		check(type(a) == "table" and a.sizeX > 0 and a.sizeZ > 0, "ARENA has a size")
		check(BowlingRules.FALL_BELOW > 0, "FALL_BELOW is positive")
	end)
end
