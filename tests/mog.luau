--[[
	Unit tests for the Mog Test rules (src/server/Modes/MogRules.luau) and the stage layout
	(src/server/Modes/MogLayout.luau).
	Loaded by tests/run.luau with its harness: { test, check, eq, near, seeded }.
]]

local fs = require("@lune/fs")
local luau = require("@lune/luau")

local MODES_DIR = "src/server/Modes/"

return function(h: { [string]: any })
	local test, check, eq, near, seeded = h.test, h.check, h.eq, h.near, h.seeded
	local MogRules = luau.load(fs.readFile(MODES_DIR .. "MogRules.luau"), { debugName = "MogRules" })()
	local MogLayout = luau.load(fs.readFile(MODES_DIR .. "MogLayout.luau"), { debugName = "MogLayout" })()

	test("Mog: difficulty curve", function()
		near(MogRules.window(1), 0.30, "window(1)")
		eq(MogRules.speed(1), 220, "speed(1)")
		near(MogRules.lead(1), 1.4, "lead(1)")
		local rand = seeded(7)
		local prevWindow, prevSpeed, prevLead = math.huge, 0, math.huge
		for n = 1, 120 do
			local c = MogRules.check(n, rand)
			check(c.window <= prevWindow, "window non-increasing at " .. n)
			check(c.window >= 0.075, "window floor at " .. n)
			check(c.speed >= prevSpeed and c.speed <= 540, "speed non-decreasing, capped at " .. n)
			check(c.lead <= prevLead and c.lead >= 0.6, "lead shrinks to 0.6 at " .. n)
			check(c.zoneSize >= 16, "zone >= 16 at " .. n)
			check(c.perfectSize >= 6 and c.perfectSize <= c.zoneSize, "perfect size at " .. n)
			check(c.zoneStart >= (if n <= 11 then 120 else 70), "zone start floor at " .. n)
			check(c.zoneStart + c.zoneSize <= 330 + 1e-9, "zone ends by 330 at " .. n)
			check(c.zoneStart + c.zoneSize <= 360, "zone fits in the lap at " .. n)
			check(c.delay >= 0.5 and c.delay <= 1.4, "delay range at " .. n)
			check(c.dir == 1 or c.dir == -1, "dir is +-1 at " .. n)
			if n <= 7 then
				eq(c.dir, 1, "clockwise for the first checks")
			end
			near(c.duration, 360 / c.speed, "duration")
			prevWindow, prevSpeed, prevLead = c.window, c.speed, c.lead
		end
		eq(MogRules.window(200), 0.075, "window floor")
		eq(MogRules.speed(200), 540, "speed cap")
		eq(MogRules.lead(200), 0.6, "lead floor")
	end)

	test("Mog: checks are deterministic and later ones turn both ways", function()
		local a, b = MogRules.check(15, seeded(3)), MogRules.check(15, seeded(3))
		eq(a.zoneStart, b.zoneStart, "same seed, same zone")
		eq(a.dir, b.dir, "same seed, same direction")
		local dirs = {}
		local rand = seeded(11)
		for n = 8, 60 do
			dirs[MogRules.check(n, rand).dir] = true
		end
		check(dirs[1] and dirs[-1], "both directions after check 7")
		-- Extreme rand values stay inside the range.
		local low = MogRules.check(1, function()
			return 0
		end)
		eq(low.zoneStart, 120, "lowest zone start")
		eq(low.delay, 0.5, "shortest delay")
	end)

	test("Mog: judge boundaries", function()
		local c = { zoneStart = 200, zoneSize = 40, perfectSize = 10 }
		local r, why = MogRules.judge(c, 199.9)
		eq(r, "miss", "just early")
		eq(why, "early", "early reason")
		eq(MogRules.judge(c, 200), "perfect", "zone start")
		eq(MogRules.judge(c, 210), "perfect", "end of the perfect part")
		eq(MogRules.judge(c, 210.1), "hit", "after the perfect part")
		eq(MogRules.judge(c, 240), "hit", "zone end")
		r, why = MogRules.judge(c, 240.1)
		eq(r, "miss", "just late")
		eq(why, "late", "late reason")
		eq(MogRules.judge(c, -5), "miss", "before the needle starts")
	end)

	test("Mog: rivals get tougher", function()
		local hps = { 3, 4, 5, 6, 6, 6 }
		local names = {}
		for i = 1, 25 do
			names[i] = "Tier" .. i
		end
		local prevTier = 0
		for i, hp in hps do
			local r = MogRules.rival(i, names)
			eq(r.hp, hp, "hp of rival " .. i)
			eq(r.maxHp, hp, "maxHp of rival " .. i)
			eq(r.index, i, "index")
			check(r.tier > prevTier, "tier grows at " .. i)
			eq(r.name, names[r.tier] .. " #" .. i, "name")
			prevTier = r.tier
		end
		eq(MogRules.rival(100, names).tier, 25, "tier capped at the tier count")
		eq(MogRules.rival(1).name, "Rival #1", "fallback name")
	end)

	test("Mog: apply scoring, rivals, pass and finish", function()
		local run = MogRules.newRun(10)
		eq(run.lives, 3, "lives")
		eq(run.score, 0, "score")
		eq(run.rival.hp, 3, "first rival hp")
		local o = MogRules.apply(run, "hit")
		eq(run.score, 1, "hit +1")
		eq(run.rival.hp, 2, "hit does 1")
		check(o.moggedRival == nil, "not mogged yet")
		o = MogRules.apply(run, "perfect")
		eq(run.score, 3, "perfect +2")
		eq(run.combo, 2, "combo")
		check(o.moggedRival ~= nil and o.moggedRival.hp == 0, "rival 1 mogged")
		eq(o.passed, false, "not passed after 1")
		eq(run.rivals, 1, "one rival")
		eq(run.rival.index, 2, "next rival")
		eq(run.rival.hp, 4, "rival 2 hp")
		o = MogRules.apply(run, "miss")
		eq(run.lives, 2, "miss costs a life")
		eq(run.combo, 0, "miss resets combo")
		eq(run.bestCombo, 2, "best combo kept")
		check(not o.finished, "not finished at 2 lives")
		MogRules.apply(run, "perfect")
		o = MogRules.apply(run, "perfect")
		eq(run.rivals, 2, "two rivals")
		check(not o.passed and not run.passed, "not passed after 2")
		for _ = 1, 5 do
			o = MogRules.apply(run, "hit")
		end
		check(o.moggedRival ~= nil, "rival 3 mogged")
		eq(o.passed, true, "passed on the third rival")
		check(run.passed, "run passed")
		eq(run.score, 3 + 4 + 5, "score arithmetic")
		for _ = 1, 3 do
			o = MogRules.apply(run, "perfect")
		end
		check(o.passed ~= true and run.rivals == 4 and run.passed, "passed only once")
		MogRules.apply(run, "miss")
		o = MogRules.apply(run, "miss")
		eq(o.finished, true, "finished at 0 lives")
		eq(run.lives, 0, "no lives")
		local score = run.score
		o = MogRules.apply(run, "perfect")
		eq(run.score, score, "finished runs ignore results")
		check(o.finished == nil and o.moggedRival == nil, "empty outcome after finish")
	end)

	test("Mog: best list keeps the highest scores", function()
		local list = {}
		eq(MogRules.recordBest(list, 1, "A", 10, 2, 3), 1, "first entry")
		eq(MogRules.recordBest(list, 2, "B", 20, 3, 3), 1, "higher goes first")
		eq(MogRules.recordBest(list, 3, "C", 10, 2, 3), 3, "tie goes after the earlier one")
		eq(list[2].userId, 1, "earlier tie stays ahead")
		eq(MogRules.recordBest(list, 4, "D", 5, 1, 3), nil, "off the list")
		eq(#list, 3, "size cap")
		eq(MogRules.recordBest(list, 1, "A", 8, 1, 3), 2, "lower score keeps the old entry")
		eq(list[2].score, 10, "old score kept")
		eq(MogRules.recordBest(list, 3, "C", 30, 4, 3), 1, "improved score moves up")
		eq(#list, 3, "no duplicates")
		eq(list[1].userId, 3, "order 1")
		eq(list[2].userId, 2, "order 2")
		eq(list[3].userId, 1, "order 3")
		eq(MogRules.recordBest(list, 5, "E", 25, 3, 3), 2, "insert in the middle")
		eq(#list, 3, "pushes the last out")
		eq(list[3].userId, 2, "last after the push")
	end)

	test("Mog: stage layout", function()
		local c = MogLayout.CENTER
		eq(#MogLayout.SPOTS, 6, "six spots")
		check(math.sqrt(c.x * c.x + c.z * c.z) - MogLayout.RADIUS > 262 + 20, "stage clear of the island")
		check(c.y - MogLayout.THICKNESS > -1.2, "stage floats above the sea")
		for i, spot in MogLayout.SPOTS do
			local p, r = spot.player, spot.rival
			local dx, dz = r.x - p.x, r.z - p.z
			near(math.sqrt(dx * dx + dz * dz), 14, "duel distance " .. i)
			near(spot.faceX * dx + spot.faceZ * dz, 14, "player faces the rival " .. i)
			check(MogLayout.onStage(p.x, p.z) and MogLayout.onStage(r.x, r.z), "both on the stage " .. i)
			check(p.y >= c.y and r.y >= c.y, "feet on the stage top " .. i)
			for j, other in MogLayout.SPOTS do
				if j ~= i then
					local ox, oz = other.rival.x - r.x, other.rival.z - r.z
					check(ox * ox + oz * oz > 10 * 10, "rivals apart " .. i .. "/" .. j)
				end
			end
		end
		check(not MogLayout.onStage(c.x + MogLayout.RADIUS + 10, c.z), "off the stage")
	end)
end
