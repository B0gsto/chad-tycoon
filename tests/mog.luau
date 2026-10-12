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
		near(MogRules.window(1), 0.37, "window(1)")
		eq(MogRules.speed(1), 220, "speed(1)")
		near(MogRules.lead(1), 1.4, "lead(1)")
		local rand = seeded(7)
		local floor = MogRules.ZONE_MIN / MogRules.SPEED_MAX
		local prevWindow, prevSpeed, prevLead, prevZone = math.huge, 0, math.huge, math.huge
		for n = 1, 120 do
			local c = MogRules.check(n, rand)
			check(c.window <= prevWindow + 1e-12, "window non-increasing at " .. n)
			check(c.window >= floor - 1e-12, "window floor at " .. n)
			near(c.window, c.zoneSize / c.speed, "window is the zone's needle time at " .. n)
			check(c.speed >= prevSpeed and c.speed <= 540, "speed non-decreasing, capped at " .. n)
			check(c.lead <= prevLead and c.lead >= 0.6, "lead shrinks to 0.6 at " .. n)
			check(c.zoneSize >= MogRules.ZONE_MIN, "zone floor at " .. n)
			check(c.zoneSize <= prevZone + 1e-9, "the zone never grows at " .. n)
			check(c.perfectSize <= c.zoneSize, "perfect inside the zone at " .. n)
			check(c.perfectSize >= MogRules.PERFECT_SHARE * c.zoneSize - 1e-9, "perfect share at " .. n)
			check(c.perfectSize / c.speed >= MogRules.PERFECT_MIN_TIME - 1e-9, "perfect >= 40 ms of travel at " .. n)
			prevZone = c.zoneSize
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
		near(MogRules.window(200), floor, "window floor")
		eq(MogRules.speed(200), 540, "speed cap")
		eq(MogRules.lead(200), 0.6, "lead floor")
	end)

	test("Mog: the zone and perfect floors really apply", function()
		eq(MogRules.ZONE_MIN, 40, "zone floor, degrees")
		near(MogRules.PERFECT_MIN_TIME, 0.04, "perfect floor, seconds")
		-- The zone shrinks all the way to its floor and then stays there for good.
		check(MogRules.zoneSize(1) > 2 * MogRules.ZONE_MIN, "the first zone is roomy")
		local reached = nil
		for n = 1, 200 do
			if MogRules.zoneSize(n) == MogRules.ZONE_MIN then
				reached = reached or n
			else
				check(reached == nil, "no zone above the floor after it was reached, at " .. n)
			end
		end
		check(reached ~= nil and reached > 20 and reached <= 40, "the zone floor is reached mid-run")
		-- The perfect floor takes over from the share while the zone is still shrinking.
		local shareOnly = MogRules.PERFECT_SHARE * MogRules.zoneSize(reached :: number)
		check(MogRules.perfectSize(reached :: number) > shareOnly + 1, "the perfect floor binds at the zone floor")
		near(MogRules.perfectSize(200), 0.04 * 540, "perfect slice at top speed")
		near(MogRules.perfectSize(1), MogRules.PERFECT_SHARE * MogRules.zoneSize(1), "the share rules early on")
		-- The first three rivals (about 12 checks) stay wide: 370 ms down to just under 200 ms.
		for n = 1, 12 do
			check(MogRules.window(n) >= 0.19, "a wide window for the first rivals at " .. n)
		end
	end)

	test("Mog: hidden (PvP) checks leave time to see the zone", function()
		local rand = seeded(5)
		for n = 1, 80 do
			local c = MogRules.check(n, rand, true)
			local open = MogRules.check(n, rand)
			eq(c.zoneSize, open.zoneSize, "same zone size as an open check at " .. n)
			eq(c.perfectSize, open.perfectSize, "same perfect size at " .. n)
			check(c.zoneStart + c.zoneSize <= 330 + 1e-9, "zone ends by 330 at " .. n)
			local wait = c.zoneStart / c.speed
			check(wait >= 0.5, "half a second from the reveal to the zone at " .. n)
			check(wait >= MogRules.MIN_REACTION + 0.3, "no hit possible inside the reaction floor at " .. n)
			if MogRules.REVEAL_TIME * c.speed <= 330 - c.zoneSize then
				check(wait >= MogRules.REVEAL_TIME - 1e-9, "REVEAL_TIME of travel first at " .. n)
			end
		end
		-- The lowest roll starts exactly REVEAL_TIME of travel in.
		local low = MogRules.check(5, function()
			return 0
		end, true)
		near(low.zoneStart, MogRules.REVEAL_TIME * low.speed, "earliest hidden zone")
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

	test("Mog: a PvP win leaves the PvE first clear", function()
		local rec = { clears = 0, rivals = 0 }
		check(MogRules.firstPass(rec), "a new record's pass is a first clear")
		MogRules.countClear(rec, "pvp")
		MogRules.countClear(rec, "pvp")
		eq(rec.clears, 0, "PvP wins are not clears")
		eq(rec.rivals, 0, "nor rivals")
		check(MogRules.firstPass(rec), "the first clear is still there after PvP wins")
		MogRules.countClear(rec, "rivals")
		eq(rec.clears, 1, "the pass is a clear")
		eq(rec.rivals, MogRules.PASS_RIVALS, "and records its rivals at once")
		check(not MogRules.firstPass(rec), "the pass used the first clear up")
		MogRules.countClear(rec, "pvp")
		check(not MogRules.firstPass(rec), "and a later PvP win does not bring it back")
		MogRules.countClear(rec, "rivals")
		eq(rec.clears, 2, "passes keep counting")
		-- A longer run's record is not lowered.
		rec = { clears = 3, rivals = 7 }
		MogRules.countClear(rec, "rivals")
		eq(rec.rivals, 7, "rivals record kept")
		-- Old saves: a clear spent by a PvP win (no run ever mogged PASS_RIVALS rivals) is back.
		check(MogRules.firstPass({ clears = 2, rivals = 1 }), "a PvP-only save still has its first clear")
		check(not MogRules.firstPass({ clears = 1, rivals = 3 }), "a save that passed does not")
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

	test("Mog: PvP duel damage", function()
		local duel = MogRules.newDuel()
		eq(duel.sides[1].hp, 8, "A starts at PVP_HP")
		eq(duel.sides[2].maxHp, 8, "B max HP")
		check(MogRules.duelPress(duel, 1, "perfect"), "A answers")
		check(not MogRules.duelPress(duel, 1, "hit"), "one answer per check")
		check(not MogRules.duelAnswered(duel), "B has not answered")
		eq(duel.sides[1].hp, 8, "no HP change before the round ends")
		eq(duel.sides[1].score, 2, "perfect scores 2")
		check(MogRules.duelPress(duel, 2, "hit"), "B answers")
		check(MogRules.duelAnswered(duel), "both answered")
		local round = MogRules.duelRound(duel)
		eq(round.results[1], "perfect", "A's result")
		eq(round.results[2], "hit", "B's result")
		eq(duel.sides[1].hp, 7, "B's hit deals 1")
		eq(duel.sides[2].hp, 6, "A's perfect deals 2")
		check(not round.finished and not round.suddenDeath, "duel goes on")
		check(duel.sides[1].result == nil and duel.sides[2].result == nil, "answers cleared")
		MogRules.duelPress(duel, 1, "miss")
		MogRules.duelPress(duel, 2, "hit")
		MogRules.duelRound(duel)
		eq(duel.sides[1].hp, 5, "own miss plus B's hit")
		eq(duel.sides[1].combo, 0, "a miss resets the combo")
		eq(duel.sides[2].combo, 2, "B's combo")
		eq(duel.sides[2].score, 2, "hit scores 1 each")
	end)

	test("Mog: PvP timeouts and KO", function()
		local duel = MogRules.newDuel()
		MogRules.duelPress(duel, 1, "hit")
		local round = MogRules.duelRound(duel)
		eq(round.results[2], "miss", "an unanswered side misses")
		eq(duel.sides[2].hp, 6, "timeout miss plus A's hit")
		eq(duel.sides[1].hp, 8, "A untouched")
		round = MogRules.duelRound(duel)
		eq(duel.sides[1].hp, 7, "both time out: A hurts itself")
		eq(duel.sides[2].hp, 5, "both time out: B hurts itself")
		duel.sides[2].hp = 2
		MogRules.duelPress(duel, 1, "perfect")
		MogRules.duelPress(duel, 2, "hit")
		round = MogRules.duelRound(duel)
		check(round.finished and duel.finished, "KO ends the duel")
		eq(round.winner, 1, "A wins")
		eq(duel.sides[2].hp, 0, "loser at 0")
		check(not MogRules.duelPress(duel, 1, "hit"), "no presses after the end")
		check(not MogRules.duelRound(duel).finished, "no rounds after the end")
	end)

	test("Mog: PvP double KO and sudden death", function()
		local duel = MogRules.newDuel()
		duel.sides[1].hp, duel.sides[2].hp = 2, 1
		MogRules.duelPress(duel, 1, "perfect")
		MogRules.duelPress(duel, 2, "perfect")
		local round = MogRules.duelRound(duel)
		check(round.finished, "both KO: decided")
		eq(round.winner, 1, "higher HP (0 vs -1) wins")
		duel = MogRules.newDuel()
		duel.sides[1].hp, duel.sides[2].hp = 1, 1
		MogRules.duelPress(duel, 1, "hit")
		MogRules.duelPress(duel, 2, "hit")
		round = MogRules.duelRound(duel)
		check(not round.finished and round.suddenDeath and duel.suddenDeath, "tie: sudden death")
		eq(duel.sides[1].hp, 1, "A back to 1")
		eq(duel.sides[2].hp, 1, "B back to 1")
		MogRules.duelPress(duel, 1, "miss")
		round = MogRules.duelRound(duel)
		check(round.suddenDeath, "both miss at 1: sudden death again")
		MogRules.duelPress(duel, 1, "hit")
		MogRules.duelPress(duel, 2, "miss")
		round = MogRules.duelRound(duel)
		eq(round.winner, 1, "sudden death decided")
	end)

	test("Mog: a close duel is a small HP margin or sudden death", function()
		eq(MogRules.PVP_CLOSE_MARGIN, 2, "two HP ahead or less is close")
		-- KO with the winner `left` HP ahead.
		local function ko(left: number): any
			local duel = MogRules.newDuel()
			duel.sides[1].hp, duel.sides[2].hp = left, 1
			MogRules.duelPress(duel, 1, "hit")
			MogRules.duelPress(duel, 2, "miss")
			check(MogRules.duelRound(duel).finished, "KO")
			return duel
		end
		check(not MogRules.duelClose(MogRules.newDuel()), "an open duel is not close")
		check(MogRules.duelClose(ko(1)), "won with 1 HP left: close")
		check(MogRules.duelClose(ko(2)), "won with 2 HP left: close")
		check(not MogRules.duelClose(ko(3)), "won with 3 HP left: not close")
		check(not MogRules.duelClose(ko(MogRules.PVP_HP)), "a clean sweep is not close")
		-- Sudden death is always close.
		local duel = MogRules.newDuel()
		duel.sides[1].hp, duel.sides[2].hp = 1, 1
		MogRules.duelPress(duel, 1, "hit")
		MogRules.duelPress(duel, 2, "hit")
		MogRules.duelRound(duel)
		check(not MogRules.duelClose(duel), "not decided yet")
		MogRules.duelPress(duel, 1, "hit")
		MogRules.duelPress(duel, 2, "miss")
		MogRules.duelRound(duel)
		check(duel.finished and MogRules.duelClose(duel), "decided in sudden death: close")
		-- A draw has no loser to console.
		duel = MogRules.newDuel()
		for _ = 1, MogRules.PVP_IDLE_FORFEIT do
			MogRules.duelRound(duel)
		end
		check(duel.finished and duel.winner == nil, "both idle: a draw")
		check(not MogRules.duelClose(duel), "a draw is not close")
	end)

	test("Mog: PvP idle forfeit", function()
		eq(MogRules.PVP_IDLE_FORFEIT, 3, "three timeouts in a row")
		-- B walked away: A wins on B's third timeout, long before a KO.
		local duel = MogRules.newDuel()
		local round
		for i = 1, 3 do
			check(not duel.finished, "still on before timeout " .. i)
			MogRules.duelPress(duel, 1, "miss")
			round = MogRules.duelRound(duel)
			eq(duel.sides[2].idle, i, "B's idle streak")
			eq(duel.sides[1].idle, 0, "a pressed miss is not idle")
		end
		check(round.finished and duel.finished, "the duel ends")
		eq(round.winner, 1, "the side still playing wins")
		eq(round.reason, "afk", "by idle forfeit")
		check(duel.sides[2].hp > 0, "no KO needed")

		-- Both walked away: over after three rounds, nobody wins (it used to loop forever).
		duel = MogRules.newDuel()
		for _ = 1, 3 do
			round = MogRules.duelRound(duel)
		end
		check(round.finished and duel.finished, "two idle sides end the duel")
		eq(round.winner, nil, "a draw")
		eq(duel.winner, nil, "no winner on the duel")
		eq(round.reason, "afk", "idle on both sides")
		eq(duel.rounds, 3, "after three rounds")
		check(not MogRules.duelRound(duel).finished, "no rounds after the end")

		-- Any press, even a miss, breaks the streak: only timeouts in a row count.
		duel = MogRules.newDuel()
		MogRules.duelPress(duel, 1, "hit")
		MogRules.duelRound(duel)
		MogRules.duelPress(duel, 1, "hit")
		MogRules.duelRound(duel)
		eq(duel.sides[2].idle, 2, "two timeouts")
		MogRules.duelPress(duel, 1, "miss")
		MogRules.duelPress(duel, 2, "miss")
		round = MogRules.duelRound(duel)
		eq(duel.sides[2].idle, 0, "a press resets the streak")
		check(not round.finished, "the duel goes on")
		MogRules.duelPress(duel, 1, "miss")
		round = MogRules.duelRound(duel)
		eq(duel.sides[2].idle, 1, "a new streak starts at 1")
		check(not round.finished, "one timeout is not a forfeit")

		-- A KO in the same round wins as a KO.
		duel = MogRules.newDuel()
		duel.sides[2].hp, duel.sides[2].idle = 1, 2
		MogRules.duelPress(duel, 1, "hit")
		round = MogRules.duelRound(duel)
		eq(round.winner, 1, "A wins")
		eq(round.reason, "ko", "the KO comes first")

		-- Sudden death with one idle side: the forfeit decides instead of another round.
		duel = MogRules.newDuel()
		duel.sides[1].hp, duel.sides[2].hp, duel.sides[2].idle = 1, 1, 2
		MogRules.duelPress(duel, 1, "miss")
		round = MogRules.duelRound(duel)
		check(round.finished and not round.suddenDeath, "no sudden death against an idle side")
		eq(round.winner, 1, "the side that pressed wins")
		eq(round.reason, "afk", "by forfeit")
	end)

	test("Mog: PvP round cap", function()
		-- Two sides trading presses that never decide it: the cap ends the duel.
		local function play(press: (duel: any, round: number) -> ()): (any, any)
			local duel = MogRules.newDuel()
			local round
			for i = 1, MogRules.PVP_MAX_ROUNDS + 5 do
				if duel.finished then
					break
				end
				press(duel, i)
				round = MogRules.duelRound(duel)
			end
			return duel, round
		end
		-- Both keep missing by pressing: 8 rounds to a double KO, then sudden death for ever.
		local duel, round = play(function(d)
			MogRules.duelPress(d, 1, "miss")
			MogRules.duelPress(d, 2, "miss")
		end)
		check(duel.finished, "the cap ends an endless duel")
		eq(duel.rounds, MogRules.PVP_MAX_ROUNDS, "at the round cap")
		eq(round.reason, "rounds", "by the cap")
		eq(round.winner, nil, "level on HP and score: a draw")
		-- Level on HP, ahead on score: the score decides.
		duel, round = play(function(d, i)
			if i == 1 then
				MogRules.duelPress(d, 1, "hit")
				MogRules.duelPress(d, 2, "perfect")
				d.sides[1].hp += 1
			else
				MogRules.duelPress(d, 1, "miss")
				MogRules.duelPress(d, 2, "miss")
			end
		end)
		eq(round.reason, "rounds", "capped again")
		eq(round.winner, 2, "the higher score wins a level duel")
		-- Ahead on HP at the cap: HP decides.
		duel = MogRules.newDuel()
		duel.rounds = MogRules.PVP_MAX_ROUNDS - 1
		MogRules.duelPress(duel, 1, "hit")
		MogRules.duelPress(duel, 2, "miss")
		round = MogRules.duelRound(duel)
		eq(round.reason, "rounds", "the last round")
		eq(round.winner, 1, "the higher HP wins")
		check(MogRules.PVP_MAX_ROUNDS >= 30, "the cap is far above a normal duel (8-12 rounds)")
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
