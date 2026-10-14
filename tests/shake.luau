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

	test("Shake: no drop lands near the exit pad", function()
		local court = { x0 = a.x - 23, x1 = a.x + 23, z0 = a.z - 23, z1 = a.z + 23 }
		local exit = ShakeRules.EXIT
		check(exit.x > a.x and exit.z > a.z, "the exit sits in the +X / +Z corner")
		for seed = 1, 60 do
			for _, box in { area, court } do
				for _, d in ShakeRules.schedule(seed, box) do
					local dist = math.sqrt((d.x - exit.x) ^ 2 + (d.z - exit.z) ^ 2)
					check(dist >= ShakeRules.EXIT_CLEAR, "seed " .. seed .. " drop " .. d.id .. " is " .. dist .. " from the exit")
					check(d.x >= box.x0 and d.x <= box.x1 and d.z >= box.z0 and d.z <= box.z1, "drop stays in the area")
				end
			end
		end
		check(ShakeRules.EXIT_CLEAR >= 9, "the exit keeps a wide clear circle")
		local x, z = ShakeRules.keepClear(exit.x, exit.z, court, exit, ShakeRules.EXIT_CLEAR)
		check(math.sqrt((x - exit.x) ^ 2 + (z - exit.z) ^ 2) >= ShakeRules.EXIT_CLEAR, "a drop right on the exit is moved out")
	end)

	test("Shake: lag compensation", function()
		eq(ShakeRules.lagOf(0), 1 / 30, "no ping: one frame")
		check(math.abs(ShakeRules.lagOf(0.2) - (0.1 + 1 / 30)) < 1e-9, "half the round trip")
		eq(ShakeRules.lagOf(5), ShakeRules.LAG_MAX, "capped")
		eq(ShakeRules.lagOf(0 / 0), 0, "nan ping: none")
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

	test("Shake: drops spread over the court and keep fair spacing", function()
		local court = { x0 = a.x - 23, x1 = a.x + 23, z0 = a.z - 23, z1 = a.z + 23 }
		local edge, total = 0, 0
		for seed = 1, 80 do
			local drops = ShakeRules.schedule(seed, court)
			for i, d in drops do
				total += 1
				if d.x == court.x0 or d.x == court.x1 or d.z == court.z0 or d.z == court.z1 then
					edge += 1
				end
				for j = i + 1, #drops do
					local e = drops[j]
					local dt = e.landAt - d.landAt
					if dt > ShakeRules.FAIR.time then
						break
					end
					if dt < 1e-6 or ShakeRules.isJunk(d.kind) ~= ShakeRules.isJunk(e.kind) then
						local dist = math.sqrt((d.x - e.x) ^ 2 + (d.z - e.z) ^ 2)
						check(
							dist >= ShakeRules.FAIR.gap,
							"seed " .. seed .. ": drops " .. d.id .. " and " .. e.id .. " only " .. dist .. " apart"
						)
					end
				end
			end
		end
		check(edge / total < 0.05, "drops do not pile up on the court edge (" .. edge .. " of " .. total .. ")")
		check(ShakeRules.FAIR.gap > ShakeRules.CATCH.radius + ShakeRules.JUNK.radius, "a good item can always be caught clear of junk")
		eq(ShakeRules.reflect(-3, 0, 10), 3, "bounces off the low edge")
		eq(ShakeRules.reflect(12, 0, 10), 8, "bounces off the high edge")
		eq(ShakeRules.reflect(5, 0, 10), 5, "inside stays")
		eq(ShakeRules.reflect(-50, 0, 10), 10, "far out is clamped")
	end)

	test("Shake: a decent player passes, a camper does not", function()
		local court = { x0 = a.x - 23, x1 = a.x + 23, z0 = a.z - 23, z1 = a.z + 23 }
		-- Walks (below WalkSpeed, aiming well inside the catch radius) to every good item it
		-- can still reach in land order and ignores junk.
		local function walker(drops: { any }, speed: number, aim: number): number
			local px, pz, t, score = a.x, a.z, 0, 0
			for _, d in drops do
				if not ShakeRules.isJunk(d.kind) then
					local dx, dz = d.x - px, d.z - pz
					local dist = math.sqrt(dx * dx + dz * dz)
					local need = math.max(0, dist - ShakeRules.CATCH.radius * aim)
					if need <= speed * math.max(d.landAt - t, 0) then
						if dist > 0 then
							px, pz = px + dx * need / dist, pz + dz * need / dist
						end
						t = d.landAt
						score += ShakeRules.points(d.kind)
					end
				end
			end
			return score
		end
		for seed = 1, 60 do
			local drops = ShakeRules.schedule(seed, court)
			local score = walker(drops, ShakeRules.BASE_WALK * 0.75, 0.6)
			check(score >= ShakeRules.TARGET, "seed " .. seed .. ": a 12 stud/s walker scores " .. score)
			check(score < ShakeRules.maxScore(drops), "seed " .. seed .. ": but not everything")
			local camp = 0
			for _, d in drops do
				if not ShakeRules.isJunk(d.kind) and math.sqrt((d.x - a.x) ^ 2 + (d.z - a.z) ^ 2) <= ShakeRules.CATCH.radius then
					camp += ShakeRules.points(d.kind)
				end
			end
			check(camp < ShakeRules.TARGET / 2, "seed " .. seed .. ": standing in the middle scores only " .. camp)
		end
	end)

	test("Shake: lobby phases", function()
		check(ShakeRules.canBegin("lobby") and ShakeRules.canBegin("results"), "begin from the lobby or the results")
		check(not ShakeRules.canBegin("countdown") and not ShakeRules.canBegin("play") and not ShakeRules.canBegin(nil), "not mid-run")
		eq(ShakeRules.fallTo("lobby"), "lobby", "a lobby fall")
		eq(ShakeRules.fallTo("results"), "lobby", "a results fall")
		eq(ShakeRules.fallTo("play"), "court", "a play fall")
		eq(ShakeRules.fallTo("countdown"), "court", "a countdown fall")
		eq(ShakeRules.READY_SECONDS, 3, "a 3 s countdown")
		check(ShakeRules.RESULTS_SECONDS >= 4 and ShakeRules.RESULTS_SECONDS <= 8, "about 6 s of results")
	end)

	test("Shake: the START pad", function()
		local pad = { x = 10, y = 6, z = 10 }
		check(ShakeRules.onPad(10, 6, 10, pad, 4), "on the centre")
		check(ShakeRules.onPad(13, 7, 10, pad, 4), "near the rim")
		check(not ShakeRules.onPad(15, 6, 10, pad, 4), "beside it")
		check(not ShakeRules.onPad(10, 6 + ShakeRules.PAD_HEIGHT + 1, 10, pad, 4), "jumping high over it")
		local R = ShakeRules.PAD_REARM
		-- Arriving in the lobby (offSince nil) standing on the pad: nothing until stepping off.
		local go, off = ShakeRules.padStep(true, nil, 0)
		check(not go and off == nil, "landing on it does not start")
		go, off = ShakeRules.padStep(false, off, 1)
		check(not go and off == 1, "stepped off at 1")
		go, off = ShakeRules.padStep(true, off, 1 + R / 2)
		check(not go and off == nil, "straight back on is too soon")
		go, off = ShakeRules.padStep(false, off, 2)
		go, off = ShakeRules.padStep(false, off, 2 + R / 2)
		eq(off, 2, "offSince keeps the first step off")
		go, off = ShakeRules.padStep(true, off, 2 + R)
		check(go and off == nil, "after the re-arm it starts and disarms")
	end)

	test("Shake: the speed check", function()
		local walk = ShakeRules.BASE_WALK
		check(ShakeRules.plausible(walk * 0.5, 0.5, walk), "walking")
		check(ShakeRules.plausible(walk * 1.3 * 0.5, 0.5, walk * 1.3), "Speedy Sneakers")
		check(ShakeRules.plausible(1, 0, walk), "jitter in place")
		check(not ShakeRules.plausible(30, 0.5, walk), "a teleport")
		check(not ShakeRules.plausible(walk * 2.5, 1, walk), "a speed hack")
		check(ShakeRules.plausible(walk * 0.5, 0.5, 4), "a slowed humanoid still gets the base allowance")
		check(not ShakeRules.plausible(0 / 0, 0.5, walk), "nan")
		check(ShakeRules.REANCHOR > ShakeRules.ANCHOR_EVERY, "re-anchoring is slower than anchoring")
	end)
end
