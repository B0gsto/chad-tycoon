--[[
	Unit tests for the Pose rules (src/server/Modes/PoseRules.luau; docs/minigames.md).
	Loaded by tests/run.luau with its harness: { test, check, eq, near, seeded }.
]]

local fs = require("@lune/fs")
local luau = require("@lune/luau")

return function(h: { [string]: any })
	local test, check, eq = h.test, h.check, h.eq
	local PoseRules = luau.load(fs.readFile("src/server/Modes/PoseRules.luau"), { debugName = "PoseRules" })()

	test("Pose: the rules module loads", function()
		local a = PoseRules.ARENA
		check(type(a) == "table" and a.sizeX > 0 and a.sizeZ > 0, "ARENA has a size")
		check(PoseRules.FALL_BELOW > 0, "FALL_BELOW is positive")
		eq(#PoseRules.FLEXES, 4, "four flexes")
		local dirs = {}
		for _, flex in PoseRules.FLEXES do
			check(type(flex.pose) == "string" and type(flex.label) == "string", "flex has a pose and label")
			check(not dirs[flex.dir], "flex directions are unique")
			dirs[flex.dir] = true
		end
	end)

	test("Pose: sequences are seeded, in range and never triple", function()
		local a = PoseRules.sequence(1234, PoseRules.MAX_ROUND)
		local b = PoseRules.sequence(1234, PoseRules.MAX_ROUND)
		eq(#a, PoseRules.MAX_ROUND, "full length")
		for i = 1, #a do
			eq(a[i], b[i], "same seed, same flex " .. i)
		end
		for seed = 1, 200 do
			local seq = PoseRules.sequence(seed * 7919, 40)
			for i, flex in seq do
				check(flex >= 1 and flex <= 4 and flex == math.floor(flex), "flex index in 1..4")
				if i >= 3 then
					check(not (seq[i - 1] == flex and seq[i - 2] == flex), "no flex three times in a row")
				end
			end
		end
		local c = PoseRules.sequence(99, 30)
		local differs = false
		for i = 1, 30 do
			differs = differs or c[i] ~= a[i]
		end
		check(differs, "another seed gives another sequence")
		local short = PoseRules.sequence(1234, 5)
		for i = 1, 5 do
			eq(short[i], a[i], "a shorter sequence is a prefix")
		end
		eq(#PoseRules.sequence(5, 0), 0, "zero length")
	end)

	test("Pose: a round is copied flex by flex", function()
		local seq = { 2, 4, 1, 3 }
		eq(PoseRules.press(seq, 1, 0, 2), "clear", "round 1: one right flex clears it")
		eq(PoseRules.press(seq, 1, 0, 3), "wrong", "round 1: a wrong flex")
		eq(PoseRules.press(seq, 3, 0, 2), "good", "round 3, first")
		eq(PoseRules.press(seq, 3, 1, 4), "good", "round 3, second")
		eq(PoseRules.press(seq, 3, 2, 1), "clear", "round 3, last")
		eq(PoseRules.press(seq, 3, 2, 3), "wrong", "round 3, wrong last")
		eq(PoseRules.press(seq, 3, 3, 3), "wrong", "nothing to press after the round is done")
		eq(PoseRules.press(seq, 6, 4, 1), "wrong", "past the sequence's end")
	end)

	test("Pose: pass mark, best and show timing", function()
		check(not PoseRules.passed(PoseRules.PASS_ROUND - 1), "one short of the pass")
		check(PoseRules.passed(PoseRules.PASS_ROUND), "the pass round passes")
		check(PoseRules.HEARTS >= 1 and PoseRules.MAX_ROUND > PoseRules.PASS_ROUND, "hearts and a cap")
		eq(PoseRules.newBest(5, 3), 5, "a shorter run keeps the best")
		eq(PoseRules.newBest(5, 9), 9, "a longer run sets it")
		eq(PoseRules.showStep(1), PoseRules.STEP_START, "round 1 is the slowest")
		local prev = math.huge
		for round = 1, PoseRules.MAX_ROUND do
			local step = PoseRules.showStep(round)
			check(step <= prev and step >= PoseRules.STEP_MIN, "the show speeds up, down to the floor")
			prev = step
			check(PoseRules.showLength(round) > round * step, "the show fits every flex")
		end
		eq(PoseRules.showStep(PoseRules.MAX_ROUND), PoseRules.STEP_MIN, "the fastest step is reached")
		check(PoseRules.INPUT_TIMEOUT >= 4, "the turn is generous")
	end)
end
