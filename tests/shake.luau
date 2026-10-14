--[[
	Unit tests for the Shake rules (src/server/Modes/ShakeRules.luau; docs/minigames.md).
	Loaded by tests/run.luau with its harness: { test, check, eq, near, seeded }.
]]

local fs = require("@lune/fs")
local luau = require("@lune/luau")

return function(h: { [string]: any })
	local test, check, eq = h.test, h.check, h.eq
	local ShakeRules = luau.load(fs.readFile("src/server/Modes/ShakeRules.luau"), { debugName = "ShakeRules" })()
	local a = ShakeRules.ARENA
	local area = { x0 = a.x - 28, x1 = a.x + 28, z0 = a.z - 28, z1 = a.z + 28 }

	test("Shake: the rules module loads", function()
		check(type(a) == "table" and a.sizeX > 0 and a.sizeZ > 0, "ARENA has a size")
		check(ShakeRules.FALL_BELOW > 0, "FALL_BELOW is positive")
	end)

	test("Shake: the schedule is deterministic and stays in the court", function()
		local one = ShakeRules.schedule(1234, area)
		local two = ShakeRules.schedule(1234, area)
		local other = ShakeRules.schedule(99, area)
		eq(#one, #two, "same seed, same count")
		local differs = #one ~= #other
		for i, d in one do
			local e = two[i]
			check(d.kind == e.kind and d.x == e.x and d.z == e.z and d.landAt == e.landAt, "same seed, same drop " .. i)
			check(d.x >= area.x0 and d.x <= area.x1 and d.z >= area.z0 and d.z <= area.z1, "drop " .. i .. " lands in the area")
			check(d.landAt > d.spawnAt and d.landAt <= ShakeRules.RUN_SECONDS, "drop " .. i .. " lands within the run")
			if i > 1 then
				check(d.landAt >= one[i - 1].landAt, "drops are in land order")
			end
			local o = other[i]
			if not o or o.x ~= d.x or o.kind ~= d.kind then
				differs = true
			end
		end
		check(differs, "another seed gives another run")
		check(#one > 40, "a run drops plenty of items (" .. #one .. ")")
	end)

	test("Shake: later waves drop faster and denser", function()
		local waves = ShakeRules.WAVES
		for i = 2, #waves do
			check(waves[i].gap < waves[i - 1].gap, "wave " .. i .. " drops more often")
			check(waves[i].fall < waves[i - 1].fall, "wave " .. i .. " falls faster")
			check(waves[i].junk >= waves[i - 1].junk, "wave " .. i .. " has as much junk or more")
			check(waves[i].from > waves[i - 1].from, "waves are in order")
		end
		eq(ShakeRules.waveAt(-1), 1, "before the run")
		eq(ShakeRules.waveAt(16), 2, "16 s in")
		eq(ShakeRules.waveAt(999), #waves, "past the end")
	end)

	test("Shake: the target is reachable but not free", function()
		for _, seed in { 1, 2, 3, 77, 4242, 31337 } do
			local drops = ShakeRules.schedule(seed, area)
			local max = ShakeRules.maxScore(drops)
			check(max >= ShakeRules.TARGET * 2, "seed " .. seed .. " holds twice the target (" .. max .. ")")
			local junk = 0
			for _, d in drops do
				if ShakeRules.isJunk(d.kind) then
					junk += 1
				end
			end
			check(junk >= 5, "seed " .. seed .. " has junk to dodge")
		end
	end)

	test("Shake: picking kinds and points", function()
		local wave = ShakeRules.WAVES[1]
		check(ShakeRules.isJunk(ShakeRules.pick(wave, 0, 0.5)), "low rolls are junk")
		eq(ShakeRules.pick(wave, wave.junk + 0.001, 0), "gold", "then gold")
		eq(ShakeRules.pick(wave, wave.junk + wave.gold + 0.001, 0), "orb", "then the orb")
		eq(ShakeRules.pick(wave, 0.999, 0), "shake", "the rest are shakes")
		eq(ShakeRules.points("shake"), 1, "shake")
		eq(ShakeRules.points("gold"), 3, "gold dumbbell")
		eq(ShakeRules.points("orb"), 1, "aura orb")
		eq(ShakeRules.points("burger"), 0, "burger")
		check(ShakeRules.isJunk("donut") and ShakeRules.isJunk("soda"), "donut and soda are junk")
		check(not ShakeRules.isJunk("orb"), "the orb is good")
		local r = ShakeRules.rng(5)
		for _ = 1, 200 do
			local v = r()
			check(v >= 0 and v < 1, "rng in [0, 1)")
		end
	end)

	test("Shake: the catch test", function()
		local good = { id = 1, wave = 1, kind = "shake", x = 0, z = 0, spawnAt = 8, landAt = 10 }
		local junk = { id = 2, wave = 1, kind = "burger", x = 0, z = 0, spawnAt = 8, landAt = 10 }
		local under = { { t = 10, x = 1, z = 1 } }
		check(ShakeRules.caught(under, good), "standing under it catches it")
		check(ShakeRules.caught(under, junk), "and the junk too")
		local lateSample = { { t = 10.25, x = 3, z = 2 } }
		check(ShakeRules.caught(lateSample, good), "a slightly late sample still catches a shake")
		check(not ShakeRules.caught(lateSample, junk), "but never costs a heart")
		check(not ShakeRules.caught({ { t = 10, x = 6, z = 0 } }, good), "too far")
		check(not ShakeRules.caught({ { t = 9, x = 0, z = 0 } }, good), "too early")
		check(not ShakeRules.caught({ { t = 11, x = 0, z = 0 } }, good), "too late")
		check(not ShakeRules.caught({}, good), "no samples, no catch")
	end)

	test("Shake: outcome", function()
		local T, RUN = ShakeRules.TARGET, ShakeRules.RUN_SECONDS
		eq(ShakeRules.outcome(T, 3, RUN / 2), nil, "still running")
		eq(ShakeRules.outcome(T, 1, RUN), "win", "target by the end")
		eq(ShakeRules.outcome(T - 1, 3, RUN), "lose", "short of the target")
		eq(ShakeRules.outcome(T - 1, 0, 10), "lose", "out of hearts")
		eq(ShakeRules.outcome(T + 4, 0, 50), "win", "out of hearts after the target")
		check(ShakeRules.passed(T) and not ShakeRules.passed(T - 1), "the pass mark")
	end)
end
