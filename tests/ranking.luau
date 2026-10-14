--[[
	Unit tests for the Ranking window's own row (src/server/Ranking.luau, run against a stub
	Tycoon with no DataStore): the stored board with this server's live scores folded in
	(Ranking.merge), a player's place and the nearest player to pass (Ranking.standing), the
	answer to Query "Ranking", and that the window (src/client/UI/Windows.luau) reads it.
	Loaded by tests/run.luau with its harness: { test, check, eq }. Run alone with
	`lune run tests/ranking` it uses the small harness at the end of this file.
]]

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local process = require("@lune/process")
local task = require("@lune/task")

local Format = require("../src/shared/Format")

-- Ranking.luau against a stub Tycoon. `sessions` maps a player ({ UserId, Name }) to
-- { profile }, as Tycoon.allSessions() does.
local function loadRanking(sessions: { [any]: any }): any
	local services = {
		DataStoreService = {
			GetOrderedDataStore = function()
				error("no DataStore in tests")
			end,
		},
		Players = {},
		ReplicatedStorage = { Shared = { Format = Format, Net = {} } },
	}
	local tycoon = {
		allSessions = function()
			return sessions
		end,
	}
	local env = setmetatable({
		game = {
			GetService = function(_, name)
				return services[name]
			end,
		},
		script = { Parent = { Tycoon = tycoon } },
		require = function(module)
			return module
		end,
		warn = function() end,
	}, { __index = _G })
	local path = "src/server/Ranking.luau"
	return luau.load(fs.readFile(path), { debugName = path, environment = env })()
end

local function unit(userId: number, name: string, value: number): any
	return { rank = 0, userId = userId, name = name, value = value }
end

local function session(userId: number, name: string, total: number, stage: number?, clears: { number }?): (any, any)
	local parkour = if stage then { stage = stage, clears = clears or {} } else nil
	return { UserId = userId, Name = name }, { profile = { totalObtained = total, parkour = parkour } }
end

local ran = false

local function suite(h: { [string]: any })
	ran = true
	local test, check, eq = h.test, h.check, h.eq

	test("Ranking: live scores fold into the stored board", function()
		local Ranking = loadRanking({})
		local stored = { unit(1, "Ann", 900), unit(2, "Bob", 500), unit(3, "Cy", 100) }
		stored[1].rank, stored[2].rank, stored[3].rank = 1, 2, 3
		-- Bob is here and has collected more since the last write; Dee is new.
		local live = { unit(2, "Bob", 950), unit(4, "Dee", 300) }
		local list = Ranking.merge(stored, live, Ranking.unitScore)
		eq(#list, 4, "every player once")
		eq(list[1].name, "Bob", "the live score moves Bob to the top")
		eq(list[1].value, 950, "Bob's row carries the live score")
		eq(list[2].name, "Ann", "Ann is second now")
		eq(list[3].name, "Dee", "a player the store does not hold yet joins the list")
		eq(list[4].name, "Cy", "Cy is last")
		for i, entry in list do
			eq(entry.rank, i, "ranks are renumbered")
		end
		eq(stored[2].value, 500, "the stored rows are left alone")
		eq(stored[1].rank, 1, "the stored ranks are left alone")
		-- Equal scores keep a fixed order.
		local tied = Ranking.merge({ unit(9, "Zed", 10), unit(5, "Eve", 10) }, {}, Ranking.unitScore)
		eq(tied[1].name, "Eve", "a tie puts the lower user id first")
		-- The stage board sorts by stage, then clears.
		local stages = Ranking.merge(
			{ { rank = 1, userId = 1, name = "Ann", stage = 4, clears = 30 } },
			{ { rank = 0, userId = 2, name = "Bob", stage = 5, clears = 1 }, { rank = 0, userId = 3, name = "Cy", stage = 4, clears = 31 } },
			Ranking.stageScore
		)
		eq(stages[1].name, "Bob", "a higher stage ranks first")
		eq(stages[2].name, "Cy", "clears break a tie on the stage")
	end)

	test("Ranking: a player's place names the next player to pass", function()
		local Ranking = loadRanking({})
		local list = Ranking.merge(
			{ unit(1, "Ann", 900), unit(2, "Bob", 500), unit(3, "Cy", 100), unit(4, "Dee", 50) },
			{},
			Ranking.unitScore
		)
		local here = { [2] = true, [3] = true, [4] = true }
		local cy = Ranking.standing(list, 3, 50, here)
		eq(cy.rank, 3, "rank")
		eq(cy.above.name, "Bob", "the player right above is the one to pass")
		eq(cy.above.value, 500, "with the score to beat")
		eq(cy.below.name, "Dee", "the player right below")
		check(cy.aboveHere, "Bob is in this server")
		eq(cy.serverRank, 2, "second of the players here")
		eq(cy.serverCount, 3, "three players here")
		check(not cy.unranked, "Cy has a row")

		local bob = Ranking.standing(list, 2, 50, here)
		eq(bob.above.name, "Ann", "Bob chases Ann")
		check(not bob.aboveHere, "Ann is not in this server")
		eq(bob.serverRank, 1, "Bob leads this server")

		local ann = Ranking.standing(list, 1, 50, {})
		eq(ann.rank, 1, "the leader is #1")
		eq(ann.above, nil, "nobody to pass at the top")
		eq(ann.below.name, "Bob", "the leader sees who is behind")

		-- A full board: under its last listed row the place is unknown, the target is not.
		local dee = Ranking.standing(list, 4, 3, here)
		eq(dee.rank, nil, "no rank under the listed top")
		eq(dee.cap, 3, "the cap is sent, for '3+'")
		eq(dee.above.name, "Cy", "the nearest player above is still the target")
		eq(dee.edge.name, "Cy", "the last listed row is the one to beat for the top 3")
		eq(dee.count, 4, "the board's size is sent")
		-- A young board (fewer rows than it lists): everybody is in the top, there is no edge.
		eq(cy.edge, nil, "no edge while the board is not full")
		eq(cy.count, 4, "four rows on the board")

		-- No row at all (no stage cleared yet): the last row is the one to reach.
		local none = Ranking.standing(list, 77, 50, here)
		check(none.unranked, "no row: unranked")
		eq(none.rank, nil, "no rank without a row")
		eq(none.above.name, "Dee", "the last row is the target")
		eq(none.serverRank, 0, "not placed among the players here")
		local empty = Ranking.standing({}, 77, 50, {})
		check(empty.unranked and empty.above == nil, "an empty board has no target")
		eq(empty.count, 0, "an empty board counts no rows")
	end)

	test("Ranking: Query answers with the list and the asker's standing", function()
		local sessions = {}
		local function join(userId: number, name: string, total: number, stage: number?, clears: { number }?)
			local player, state = session(userId, name, total, stage, clears)
			sessions[player] = state
		end
		join(11, "Ann", 40, 3, { 2, 1, 1 })
		join(12, "Bob", 21)
		join(13, "Cy", 7, 1, { 1 })
		local Ranking = loadRanking(sessions)
		local result = Ranking.answer(12)
		check(not result.global, "no DataStore: the board is this server's")
		eq(#result.entries, 3, "every player in the server is listed")
		eq(result.entries[1].name, "Ann", "best first")
		eq(result.entries[2].value, 21, "live scores")
		local you = result.you.units
		eq(you.rank, 2, "Bob is second")
		eq(you.above.name, "Ann", "Bob's target is Ann")
		eq(you.above.value - result.entries[2].value + 1, 20, "20 more to pass Ann")
		eq(you.below.name, "Cy", "Cy is behind Bob")
		eq(you.serverRank, 2, "second in this server")
		eq(you.serverCount, 3, "of three")
		-- Bob has not cleared a stage: he is not on the stage board, and is told whom to reach.
		eq(#result.stage, 2, "only players with a stage are on the stage board")
		check(result.you.stage.unranked, "Bob has no stage row")
		eq(result.you.stage.above.name, "Cy", "the last stage row is his target")
		eq(result.you.stage.above.stage, 1, "at stage 1")
		-- The leader has nobody above.
		local ann = Ranking.answer(11)
		eq(ann.you.units.rank, 1, "Ann leads")
		eq(ann.you.units.above, nil, "nobody above the leader")
		eq(ann.you.stage.rank, 1, "Ann leads the stage board too")
		eq(ann.you.stage.below.name, "Cy", "Cy is behind her there")
		-- Collecting more moves a player up at once (no wait for the next store read).
		for player, state in sessions do
			if player.UserId == 12 then
				state.profile.totalObtained = 41
			end
		end
		eq(Ranking.answer(12).you.units.rank, 1, "Bob passed Ann")
		eq(Ranking.answer(11).you.units.above.name, "Bob", "and is Ann's target now")
	end)

	test("Ranking: the window shows the target, not an empty board", function()
		local client = fs.readFile("src/client/UI/Windows.luau")
		check(string.find(client, "result.you", 1, true) ~= nil, "the window reads the standing the server sends")
		check(string.find(client, "more to pass %s", 1, true) ~= nil, "the own row says how many more to pass the next player")
		check(string.find(client, '"Most " .. W.Units .. " collected"', 1, true) ~= nil, "the board is titled by what it counts")
		check(string.find(client, "wide open", 1, true) == nil, "no empty-board line without a goal")
		-- A young board is shown as it is (no made-up players): the room under it goes to the
		-- player's own goal and numbers.
		check(string.find(client, "more %s to reach the top %d", 1, true) ~= nil, "under the listed top the goal is the top N")
		check(string.find(client, "YOU'RE #1!", 1, true) ~= nil, "leading the board has its own state")
		check(string.find(client, "you.edge", 1, true) ~= nil, "the window reads the edge of the board")
		check(string.find(client, "you.count", 1, true) ~= nil, "and how many rows it has")
	end)
end

-- Run alone: tests/run.luau calls the returned function at once; when nobody has by the time
-- this file is done, run it here.
task.defer(function()
	if ran then
		return
	end
	local passed, failed = 0, 0
	local current = ""
	local function check(condition: boolean, message: string)
		if condition then
			passed += 1
		else
			failed += 1
			print(string.format("  FAIL [%s] %s", current, message))
		end
	end
	suite({
		check = check,
		eq = function(actual: any, expected: any, message: string?)
			check(actual == expected, string.format("%s: expected %s, got %s", message or "value", tostring(expected), tostring(actual)))
		end,
		test = function(name: string, fn: () -> ())
			current = name
			local ok, err = pcall(fn)
			if not ok then
				failed += 1
				print(string.format("  ERROR [%s] %s", name, tostring(err)))
			end
		end,
	})
	print(string.format("\n%d passed, %d failed", passed, failed))
	if failed > 0 then
		process.exit(1)
	end
end)

return suite
