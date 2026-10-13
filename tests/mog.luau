--[[
	Unit tests for the Mog Test rules (src/server/Modes/MogRules.luau), the stage layout
	(src/server/Modes/MogLayout.luau), the TOP MOGGERS board (src/server/Modes/MogBoard.luau,
	against a fake OrderedDataStore) and the pay of a pass / PvP win (src/server/Modes/Mog.luau
	over stub GameModes / Tycoon tables): inside the reward cooldown only a real run pays.
	Loaded by tests/run.luau with its harness: { test, check, eq, near, seeded }.
]]

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local roblox = require("@lune/roblox")

local Economy = require("../src/shared/Economy")

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

	test("Mog: a pass is paid once per run and takes real time", function()
		local run = MogRules.newRun(0)
		check(not MogRules.claimPass(run), "nothing to claim before the pass")
		-- Two rivals mogged and out of lives: no pass, no pay.
		for _ = 1, 4 do
			MogRules.apply(run, "perfect")
		end
		eq(run.rivals, 2, "two rivals mogged")
		check(not MogRules.claimPass(run), "two rivals are not a pass")
		for _ = 1, 3 do
			MogRules.apply(run, "perfect")
		end
		check(run.passed and run.rivals == MogRules.PASS_RIVALS, "the third rival passes the test")
		check(MogRules.claimPass(run), "the pass is claimed")
		check(not MogRules.claimPass(run), "once")
		for _ = 1, 30 do
			MogRules.apply(run, "perfect")
		end
		check(run.rivals > MogRules.PASS_RIVALS and not MogRules.claimPass(run), "more rivals in the same run pay nothing more")
		-- A forged `passed` flag without the rivals is not a pass.
		local fake = MogRules.newRun(0)
		fake.passed = true
		check(not MogRules.claimPass(fake), "no pass without the rivals")

		-- A pass cannot be looped in seconds: 7 checks at the very least, 15 s of them.
		eq(MogRules.minPassChecks(), 7, "3 + 4 + 5 HP at 2 per perfect")
		local quick = MogRules.newRun(0)
		for n = 1, MogRules.minPassChecks() do
			check(not quick.passed, "no pass before check " .. n)
			MogRules.apply(quick, "perfect")
		end
		check(quick.passed, "all perfects pass in minPassChecks")
		check(MogRules.minPassSeconds() >= 15, "a pass takes 15 s at the least (" .. MogRules.minPassSeconds() .. ")")
		-- No real check is quicker than the bound's: lead + travel to the zone + delay.
		local rand = seeded(11)
		local seconds = 0
		for n = 1, MogRules.minPassChecks() do
			local c = MogRules.check(n, rand)
			seconds += c.lead + c.zoneStart / c.speed + (if n < MogRules.minPassChecks() then c.delay else 0)
		end
		check(seconds >= MogRules.minPassSeconds() - 1e-9, "the bound holds for real checks")

		eq(MogRules.payKind(true, true, true), "first", "the first pass")
		eq(MogRules.payKind(false, true, false), "full", "the cooldown is over")
		eq(MogRules.payKind(false, false, true), "repeat", "an earned repeat")
		eq(MogRules.payKind(false, false, false), "none", "a repeat that was not earned")
	end)

	test("Mog: only a duel really fought earns the repeat share", function()
		eq(MogRules.PVP_REPEAT_PRESSES, 3, "the loser pressed on three checks")
		-- Plays rounds of { A's answer, B's answer } (nil = no press: a timeout).
		local function play(rounds: { { string? } }): any
			local duel = MogRules.newDuel()
			for _, r in rounds do
				for side = 1, 2 do
					if r[side] then
						MogRules.duelPress(duel, side, r[side] :: string)
					end
				end
				MogRules.duelRound(duel)
			end
			return duel
		end
		check(not MogRules.duelFought(MogRules.newDuel()), "a duel that is not over")
		-- A KO against a loser who pressed every round: fought (3 rounds is the quickest KO).
		local ko = play({ { "perfect", "miss" }, { "perfect", "miss" }, { "perfect", "miss" } })
		check(ko.finished and ko.winner == 1 and ko.reason == "ko", "KO in three rounds")
		eq(ko.sides[2].presses, 3, "the loser pressed three times")
		check(MogRules.duelFought(ko), "fought")
		-- The loser pressed, but not often enough: a KO over 4 rounds with two timeouts.
		local lazy = play({ { "perfect", "miss" }, { "perfect", nil }, { "perfect", "hit" }, { "perfect", nil } })
		check(lazy.finished and lazy.winner == 1 and lazy.reason == "ko", "KO")
		eq(lazy.sides[2].presses, 2, "timeouts are not presses")
		check(not MogRules.duelFought(lazy), "two presses are not a fight")
		-- An opponent who never presses: the idle forfeit, never fought.
		local afk = play({ { "hit", nil }, { "hit", nil }, { "hit", nil } })
		check(afk.finished and afk.winner == 1 and afk.reason == "afk", "idle forfeit")
		eq(afk.sides[2].presses, 0, "no presses")
		check(not MogRules.duelFought(afk), "an idle forfeit is not fought")
		-- Pressing first and then walking away: still the idle forfeit.
		local left = play({ { "hit", "hit" }, { "hit", "hit" }, { "hit", "hit" }, { "miss", nil }, { "miss", nil }, { "miss", nil } })
		check(left.finished and left.reason == "afk" and left.sides[2].presses == 3, "pressed, then idle")
		check(not MogRules.duelFought(left), "an idle forfeit never counts, whatever came before")
		-- Both idle: a draw.
		local draw = play({ {}, {}, {} })
		check(draw.finished and draw.winner == nil, "draw")
		check(not MogRules.duelFought(draw), "a draw is not a win")
		-- The round cap with both sides pressing: fought.
		local rounds = {}
		for i = 1, MogRules.PVP_MAX_ROUNDS do
			rounds[i] = if i == 1 then { "perfect", "hit" } else { "hit", "hit" }
		end
		local capped = play(rounds)
		if not capped.finished then
			check(false, "the round cap ends the duel")
		elseif capped.reason == "rounds" then
			check(MogRules.duelFought(capped), "a duel to the round cap is fought")
		else
			eq(capped.reason, "ko", "or it ended by KO")
			check(MogRules.duelFought(capped), "fought either way")
		end
		-- A duel one side left (never finished by the rules) is for the caller to refuse.
		local quit = play({ { "perfect", "miss" }, { "perfect", "miss" } })
		check(not quit.finished and not MogRules.duelFought(quit), "an unfinished duel is not fought")
	end)

	-- Loads a Modes module against `siblings` (script.Parent) and `services`.
	local function loadMode(name: string, siblings: { [string]: any }, services: { [string]: any }, extra: { [string]: any }?): any
		local env = setmetatable({
			script = { Parent = siblings },
			require = function(module)
				return module
			end,
			game = {
				GetService = function(_, service)
					return services[service]
				end,
			},
			warn = function() end,
		}, { __index = _G })
		for key, value in extra or {} do
			(env :: any)[key] = value
		end
		local path = MODES_DIR .. name .. ".luau"
		return luau.load(fs.readFile(path), { debugName = path, environment = env })()
	end

	-- A fake OrderedDataStore: `data` by key, `down` makes every call fail, `sets` counts writes.
	local function fakeStore(): any
		local store: any = { data = {}, down = false, sets = 0, gets = 0 }
		function store.SetAsync(self, key: string, value: number)
			if self.down then
				error("DataStore down")
			end
			self.sets += 1
			self.data[key] = value
		end
		function store.GetSortedAsync(self, ascending: boolean, size: number)
			if self.down then
				error("DataStore down")
			end
			self.gets += 1
			local items = {}
			for key, value in self.data do
				table.insert(items, { key = key, value = value })
			end
			table.sort(items, function(a, b)
				if a.value ~= b.value then
					return if ascending then a.value < b.value else a.value > b.value
				end
				return a.key < b.key
			end)
			local page = {}
			for i = 1, math.min(size, #items) do
				page[i] = items[i]
			end
			return {
				GetCurrentPage = function()
					return page
				end,
			}
		end
		return store
	end

	local function loadBoard(open: (() -> any)?): any
		return loadMode("MogBoard", { MogRules = MogRules }, {
			DataStoreService = {
				GetOrderedDataStore = open or function()
					error("no DataStore in tests")
				end,
			},
			Players = {},
		})
	end

	test("Mog: TOP MOGGERS is an all-time board, or this server's without DataStores", function()
		local MogBoard = loadBoard()
		eq(MogBoard.open(), nil, "no store when DataStores cannot be reached")
		eq(MogBoard.REFRESH_SECONDS, 90, "refreshed as slowly as the Ranking boards")
		local function name(userId: number): string
			return "User" .. userId
		end
		local function always(): boolean
			return true
		end

		-- No store: this server's run scores, as before.
		local plain = MogBoard.new(3, nil, name, always)
		local rank, globalRank = MogBoard.record(plain, 1, "A", 10, 2, 40)
		check(rank == 1 and globalRank == nil, "a rank on this server only")
		eq(select(1, MogBoard.record(plain, 2, "B", 20, 3, 20)), 1, "a better run goes first")
		eq(select(1, MogBoard.record(plain, 3, "C", 0, 0, 5)), nil, "a run without a hit is not on the list")
		local shown, isGlobal = MogBoard.entries(plain)
		check(not isGlobal and #shown == 2 and shown[1].userId == 2 and shown[1].score == 20, "the server list is shown")
		eq(shown[2].score, 10, "run scores, not the saved best")
		MogBoard.refresh(plain, { { userId = 1, name = "A", score = 40, rivals = 2 } })
		check(not select(2, MogBoard.entries(plain)), "still this server's list after a refresh")
		eq(next(plain.pending), nil, "nothing is queued without a store")

		-- A store with scores from other servers.
		local store = fakeStore()
		store.data = { ["11"] = 90, ["12"] = 70, ["13"] = 50, ["14"] = 30, ["15"] = 0 }
		local board = MogBoard.new(3, store, name, always)
		rank, globalRank = MogBoard.record(board, 1, "A", 10, 2, 60)
		check(rank == 1 and globalRank == nil, "before the first read there is no all-time rank")
		check(not select(2, MogBoard.entries(board)), "and the server list is shown")
		eq(store.sets, 0, "a run never writes to the store itself")
		eq(board.pending[1], 60, "the saved best is queued, not the run's score")
		MogBoard.refresh(board, {})
		eq(store.data["1"], 60, "the refresh wrote the best")
		eq(store.sets, 1, "one write")
		shown, isGlobal = MogBoard.entries(board)
		check(isGlobal and #shown == 3, "the all-time list is shown, three long")
		check(shown[1].userId == 11 and shown[1].name == "User11" and shown[1].score == 90, "#1 from another server")
		check(shown[2].userId == 12 and shown[3].userId == 1 and shown[3].name == "A", "the player is #3 all-time")
		-- Nothing changed: the next refresh writes nothing.
		MogBoard.refresh(board, { { userId = 1, name = "A", score = 60, rivals = 2 } })
		eq(store.sets, 1, "an unchanged best is not written again")
		eq(store.gets, 2, "one read per refresh")
		-- A new best shows at once and is written by the next refresh.
		rank, globalRank = MogBoard.record(board, 1, "A", 80, 5, 80)
		check(rank == 1 and globalRank == 2, "the new best is #2 all-time right away")
		eq(store.data["1"], 60, "not written yet")
		-- A lower run changes nothing.
		rank, globalRank = MogBoard.record(board, 1, "A", 5, 1, 80)
		check(rank == 1 and globalRank == 2, "a weaker run keeps both ranks")
		MogBoard.refresh(board, {})
		check(store.data["1"] == 80 and store.sets == 2, "written once by the refresh")
		-- A player who joins with an old best is seeded by the refresh.
		MogBoard.refresh(board, { { userId = 2, name = "B", score = 95, rivals = 9 }, { userId = 3, name = "C", score = 0, rivals = 0 } })
		eq(store.data["2"], 95, "a saved best from before the board is written")
		eq(store.data["3"], nil, "no best, no entry")
		shown = MogBoard.entries(board)
		check(shown[1].userId == 2 and shown[2].userId == 11 and shown[3].userId == 1, "and tops the list")
		-- A stored value never goes down.
		MogBoard.seed(board, 2, "B", 40, 1)
		MogBoard.refresh(board, {})
		eq(store.data["2"], 95, "a lower score is never written")

		-- The store goes down: the last list stays, new bests still show, writes wait.
		store.down = true
		local _, g = MogBoard.record(board, 4, "D", 99, 9, 99)
		eq(g, 1, "a new best during an outage is on the board here")
		MogBoard.refresh(board, {})
		shown, isGlobal = MogBoard.entries(board)
		check(isGlobal and shown[1].userId == 4 and shown[2].userId == 2, "the last all-time list is kept, with the new best")
		eq(board.pending[4], 99, "the failed write stays queued")
		store.down = false
		MogBoard.refresh(board, {})
		check(store.data["4"] == 99 and board.pending[4] == nil, "and is sent once the store is back")

		-- A store that never answers (Studio without API access): the server list.
		local dead = fakeStore()
		dead.down = true
		local offline = MogBoard.new(3, dead, name, always)
		MogBoard.record(offline, 1, "A", 12, 2, 12)
		MogBoard.refresh(offline, { { userId = 1, name = "A", score = 12, rivals = 2 } })
		shown, isGlobal = MogBoard.entries(offline)
		check(not isGlobal and #shown == 1 and shown[1].score == 12, "falls back to this server's list")

		-- No request budget: nothing is called, everything waits.
		local budgetless = MogBoard.new(3, fakeStore(), name, function()
			return false
		end)
		MogBoard.record(budgetless, 1, "A", 12, 2, 12)
		MogBoard.refresh(budgetless, {})
		check(budgetless.store.sets == 0 and budgetless.store.gets == 0, "no call without budget")
		eq(budgetless.pending[1], 12, "the write waits for budget")

		-- Junk in the store is skipped.
		local junk = fakeStore()
		junk.data = { ["7"] = 0 / 0, ["8"] = -5, ["9"] = 12.9 }
		local cleaned = MogBoard.new(3, junk, name, always)
		MogBoard.refresh(cleaned, {})
		shown = MogBoard.entries(cleaned)
		check(#shown == 1 and shown[1].userId == 9 and shown[1].score == 12, "only whole positive scores are listed")
	end)

	-- The Mog mode over stub GameModes / Tycoon tables and a manual clock: `w.add(userId)`
	-- makes a player (profile with a fresh mog record), `w.advance(seconds)` runs the timers.
	local function world(): any
		local w: any = { clock = 1000, timers = {}, notes = {}, sessions = {}, roots = {}, actions = {}, effects = {} }
		local MogBoard = loadBoard()
		local Course = luau.load(fs.readFile(MODES_DIR .. "Course.luau"), { debugName = "Course" })()
		local GameModes = {
			session = function(player)
				return w.sessions[player]
			end,
			root = function(player)
				return w.roots[player]
			end,
			notify = function(player, event, _, data)
				local note = table.clone(data or {})
				note.event = event
				table.insert(w.notes[player], note)
			end,
			effect = function(player, kind, data)
				table.insert(w.effects, { player = player, kind = kind, data = data })
			end,
			refresh = function() end,
			teleport = function() end,
			returnLater = function() end,
			start = function() end,
			hooks = {
				reward = function(_, _, reward)
					return reward
				end,
				rewarded = function() end,
			},
		}
		local Tycoon = {
			income = function()
				return 0
			end,
			markDirty = function() end,
			addAction = function(name, fn)
				w.actions[name] = fn
			end,
			allSessions = function()
				return w.sessions
			end,
		}
		local Mog = loadMode("Mog", { Course = Course, MogBoard = MogBoard, MogLayout = MogLayout, MogRules = MogRules }, {
			Players = { PlayerRemoving = { Connect = function() end } },
			ReplicatedStorage = { Shared = { Economy = Economy } },
		}, {
			workspace = {
				GetServerTimeNow = function()
					return w.clock
				end,
			},
			task = {
				delay = function(seconds, fn)
					table.insert(w.timers, { at = w.clock + seconds, fn = fn })
				end,
				spawn = function() end,
			},
			Random = {
				new = function()
					return {
						NextNumber = function()
							return 0.5
						end,
					}
				end,
			},
			Vector3 = roblox.Vector3,
		})
		local theme = { Modes = { Reward = { Seconds = 300, Min = 750 } }, Tiers = {} }
		for i = 1, 25 do
			theme.Tiers[i] = { Name = "Tier" .. i }
		end
		w.def = Mog.create(GameModes, { built = nil, theme = theme, Tycoon = Tycoon, world = nil })
		function w.add(userId: number): any
			local player = { UserId = userId, DisplayName = "P" .. userId, Parent = {} }
			w.notes[player] = {}
			w.roots[player] = { Position = roblox.Vector3.new(0, 500, 0), Anchored = false }
			w.sessions[player] = {
				player = player,
				profile = {
					money = 0,
					totalEarned = 0,
					discovered = {},
					processLevel = 0,
					modes = { mog = { best = 0, rivals = 0, clears = 0, lastRewardAt = 0, pvpWins = 0, pvpPlayed = 0 } },
				},
			}
			return player
		end
		-- Lets `seconds` pass, running every timer that comes due, in order.
		function w.advance(seconds: number)
			local to = w.clock + seconds
			while true do
				local at, index = math.huge, nil
				for i, timer in w.timers do
					if timer.at <= to + 1e-9 and timer.at < at then
						at, index = timer.at, i
					end
				end
				if not index then
					break
				end
				local timer = table.remove(w.timers, index)
				w.clock = math.max(w.clock, timer.at)
				timer.fn()
			end
			w.clock = to
		end
		function w.last(player: any, event: string): any
			local notes = w.notes[player]
			for i = #notes, 1, -1 do
				if notes[i].event == event then
					return notes[i]
				end
			end
			return nil
		end
		-- Presses the current check as `how`: "perfect" (in the zone's perfect part), "hit" (in
		-- the rest of the zone) or "miss" (too early, but later than a reaction takes). `zone`:
		-- the check's zone payload.
		function w.press(player: any, how: string, zone: any?)
			local c = w.last(player, "check")
			local z = zone or c
			local travel = if how == "perfect"
				then z.zoneStart + 0.5
				elseif how == "hit" then z.zoneStart + (z.perfectSize + z.zoneSize) / 2
				else c.speed * (MogRules.MIN_REACTION + 0.05)
			w.clock = c.appearAt + travel / c.speed
			w.actions.MogPress(w.sessions[player], { id = c.id, at = w.clock })
		end
		-- A whole PvE run: `perfects` perfect presses, then misses until the lives are gone.
		-- Returns the finish payload.
		function w.run(player: any, perfects: number): any
			check(w.def.start(player, true, { vs = "rivals" }), "the run starts")
			w.advance(2.1)
			local finishes = 0
			for _, note in w.notes[player] do
				if note.event == "finish" then
					finishes += 1
				end
			end
			for i = 1, perfects + MogRules.LIVES do
				w.press(player, if i <= perfects then "perfect" else "miss")
				w.advance(1.5)
			end
			local finish = w.last(player, "finish")
			local now = 0
			for _, note in w.notes[player] do
				if note.event == "finish" then
					now += 1
				end
			end
			eq(now, finishes + 1, "the run finished")
			check(not w.def.running(player), "and is over")
			return finish
		end
		-- One duel round: each side's press ("perfect" | "miss" | nil = no press).
		function w.round(a: any, b: any, pressA: string?, pressB: string?)
			local c = w.last(a, "check")
			-- The zone is sent when the needle starts.
			w.advance(math.max(0, c.appearAt - w.clock))
			local zone = w.last(a, "zone")
			eq(zone.id, c.id, "the zone of this check was sent")
			if pressA then
				w.press(a, pressA, zone)
			end
			if pressB then
				w.press(b, pressB, zone)
			end
			if not (pressA and pressB) then
				-- The lap runs out: the server settles the round on its next tick.
				w.clock = c.appearAt + c.duration + 0.5
				w.def.tick(a, w.roots[a], w.clock)
			end
			w.advance(1.5)
		end
		-- Queues both for a duel and waits for the first check.
		function w.duel(a: any, b: any)
			check(w.def.start(a, true, { vs = "pvp" }), "A queues")
			check(w.def.start(b, true, { vs = "pvp" }), "B queues")
			check(w.last(a, "start") ~= nil and w.last(a, "start").vs == "pvp", "the duel starts")
			w.advance(2.1)
		end
		return w
	end

	test("Mog: a pass inside the cooldown pays the run again bonus, once per real run", function()
		local w = world()
		local player = w.add(1)
		local profile = w.sessions[player].profile
		local rec = profile.modes.mog
		local share = Economy.MODE_REPEAT_SHARE
		local perfects = MogRules.minPassChecks()

		-- The first pass ever: the whole pack.
		local t0 = w.clock
		local first = w.run(player, perfects)
		local pass = w.last(player, "rival")
		check(pass.passed == true and pass.pay == "first" and pass.cash == 750, "the pass pays the pack at once")
		check(first.passed == true and first.pay == "first" and first.cash == 750 and first.full == true, "the finish says so")
		check(first.packCash == 750 and first.repeatCash == math.floor(750 * share) and first.repeatShare == share, "prices for the card")
		check(first.newBest == true and first.prevBest == 0 and first.best == 2 * perfects, "a new best score")
		check(first.rank == 1 and first.globalRank == nil and first.board == "server", "on this server's board (no DataStore)")
		eq(profile.money, 750, "paid")
		eq(rec.clears, 1, "one pass")
		check(w.clock - t0 >= MogRules.minPassSeconds(), "even all-perfect, the run took its time")
		local lastRewardAt = rec.lastRewardAt
		check(lastRewardAt > 0, "the cooldown runs")

		-- The Modes window's preview: a pass would pay the share now.
		local preview = w.def.rewardPreview(player)
		local bonus = math.floor(750 * share)
		check(
			preview.full == false and preview.cash == bonus and preview.repeatCash == bonus and preview.packCash == 750,
			"preview: the share"
		)
		eq(preview.repeatShare, share, "preview: the share's size")

		-- A run that does not pass pays nothing: no lives left before the third rival.
		local failed = w.run(player, perfects - 1)
		check(failed.passed == false and failed.pay == "none" and failed.cash == 0, "no pass, no bonus")
		check(failed.newBest == false and failed.best == first.best and failed.prevBest == first.best, "the best stays")
		local none = w.run(player, 0)
		check(none.pay == "none" and none.cash == 0 and none.rank == nil, "three misses pay nothing")
		eq(profile.money, 750, "nothing paid for failed runs")

		-- A real pass inside the cooldown: the run again bonus, once.
		local again = w.run(player, perfects + 4)
		pass = nil
		for _, note in w.notes[player] do
			if note.event == "rival" and note.passed then
				pass = note
			end
		end
		check(pass.pay == "repeat" and pass.cash == bonus and pass.full == false, "the pass banner gets the bonus")
		check(again.pay == "repeat" and again.cash == bonus and again.full == false, "the finish card too")
		check(again.repeatCash == bonus and again.packCash == 750 and again.repeatShare == share, "with both prices")
		check(again.newBest == true and again.prevBest == first.best and again.best == 2 * (perfects + 4), "and a new best")
		eq(profile.money, 750 + bonus, "one bonus for the run, however many rivals")
		eq(profile.totalEarned, 750 + bonus, "counted as earned")
		eq(rec.lastRewardAt, lastRewardAt, "the bonus does not restart the cooldown")
		eq(rec.clears, 2, "the pass counts")
		local cashEffects = 0
		for _, effect in w.effects do
			if effect.kind == "Cash" then
				cashEffects += 1
			end
		end
		eq(cashEffects, 2, "two cash effects: the pack and one bonus")

		-- Every bonus needs its own whole run.
		local money = profile.money
		t0 = w.clock
		for i = 1, 3 do
			check(w.run(player, perfects).pay == "repeat", "pass " .. i .. " pays the bonus")
		end
		eq(profile.money, money + 3 * bonus, "three passes, three bonuses")
		check(w.clock - t0 >= 3 * MogRules.minPassSeconds(), "each took a real run")

		-- After the cooldown a pass pays the pack again.
		rec.lastRewardAt = os.time() - Economy.MODE_REWARD_COOLDOWN - 1
		local full = w.run(player, perfects)
		check(full.pay == "full" and full.cash == 750 and full.full == true, "the full reward after the cooldown")
	end)

	test("Mog: a PvP win inside the cooldown pays only for a duel really fought", function()
		local w = world()
		local a, b = w.add(1), w.add(2)
		local profile = w.sessions[a].profile
		local rec = profile.modes.mog
		local bonus = math.floor(750 * Economy.MODE_REPEAT_SHARE)
		-- A passed before and is inside the cooldown.
		rec.clears, rec.rivals, rec.lastRewardAt = 1, MogRules.PASS_RIVALS, os.time()

		-- B presses (and misses) every round: a KO in three rounds, really fought.
		w.duel(a, b)
		for _ = 1, 3 do
			w.round(a, b, "perfect", "miss")
		end
		local won = w.last(a, "finish")
		check(won ~= nil and won.vs == "pvp" and won.won == true and won.reason == "ko", "A wins by KO")
		check(won.pay == "repeat" and won.cash == bonus and won.full == false, "and gets the run again bonus")
		check(won.repeatCash == bonus and won.packCash == 750, "with both prices for the card")
		local lost = w.last(b, "finish")
		check(lost.won == false and lost.pay == "none" and lost.cash == 0, "the loser is paid nothing")
		eq(profile.money, bonus, "the bonus is paid")
		eq(w.sessions[b].profile.money, 0, "B has nothing")
		eq(w.def.snapshot(a).pvpWins, 1, "the win counts")
		w.advance(10)

		-- B never presses and is knocked out by A's perfects: a KO, but not a fight.
		w.duel(a, b)
		for _ = 1, 3 do
			w.round(a, b, "perfect", nil)
		end
		local walkover = w.last(a, "finish")
		check(walkover.won == true and walkover.reason == "ko" and walkover.afk == nil, "A knocks out an opponent who never pressed")
		check(walkover.pay == "none" and walkover.cash == 0, "which pays nothing inside the cooldown")
		eq(profile.money, bonus, "nothing farmed from a silent opponent")
		w.advance(10)

		-- B never presses and A only hits: the idle forfeit pays no bonus either.
		w.duel(a, b)
		for _ = 1, MogRules.PVP_IDLE_FORFEIT do
			w.round(a, b, "hit", nil)
		end
		local afk = w.last(a, "finish")
		check(afk.won == true and afk.afk == true and afk.reason == "forfeit", "A wins by the idle forfeit")
		check(afk.pay == "none" and afk.cash == 0, "which pays nothing inside the cooldown")
		eq(profile.money, bonus, "nothing farmed from an idle opponent")
		eq(w.def.snapshot(a).pvpWins, 3, "the wins still count")
		w.advance(10)

		-- B leaves after two rounds: a forfeit pays no bonus either.
		w.duel(a, b)
		w.round(a, b, "perfect", "miss")
		w.round(a, b, "perfect", "miss")
		w.def.stop(b, "quit")
		local forfeit = w.last(a, "finish")
		check(forfeit.won == true and forfeit.reason == "forfeit" and forfeit.afk == nil, "A wins by forfeit")
		check(forfeit.pay == "none" and forfeit.cash == 0, "no bonus for a forfeit")
		eq(profile.money, bonus, "nothing farmed by quitting")
		w.advance(10)

		-- Outside the cooldown the full reward keeps its old rule: a forfeit after two rounds pays.
		rec.lastRewardAt = os.time() - Economy.MODE_REWARD_COOLDOWN - 1
		w.duel(a, b)
		w.round(a, b, "perfect", "miss")
		w.round(a, b, "perfect", "miss")
		w.def.stop(b, "quit")
		local paid = w.last(a, "finish")
		check(paid.pay == "full" and paid.cash == 750 and paid.full == true, "the full reward after the cooldown")
		eq(profile.money, bonus + 750, "paid in full")
		eq(rec.clears, 1, "a PvP win is never a clear")
	end)
end
