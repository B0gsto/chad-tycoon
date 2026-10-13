--[[
	Unit tests for the comeback hooks (src/shared/Comeback.luau): the rows of the "While
	you were away" card and the "Before you go" line, and that the client shows them
	(src/client/UI/AwayWindow.luau, DailyWindow.luau, Main.client.luau).
	Loaded by tests/run.luau with its harness: { test, check, eq, loadShared }. Run alone with
	`lune run tests/comeback` it uses the small harness at the end of this file.
]]

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local process = require("@lune/process")
local task = require("@lune/task")

-- src/shared modules with `require(script.Parent.X)` resolved (as tests/run.luau's loadShared).
local sharedCache: { [string]: any } = {}
local function loadShared(name: string): any
	if sharedCache[name] == nil then
		local env: { [string]: any } = setmetatable({}, { __index = _G }) :: any
		env.script = {
			Parent = setmetatable({}, {
				__index = function(_, child)
					return child
				end,
			}),
		}
		env.require = loadShared
		local path = "src/shared/" .. name .. ".luau"
		sharedCache[name] = luau.load(fs.readFile(path), { debugName = path, environment = env })()
	end
	return sharedCache[name]
end

local ran = false

local function suite(h: { [string]: any })
	ran = true
	local test, check, eq = h.test, h.check, h.eq
	local load = h.loadShared or loadShared
	local Comeback = load("Comeback")
	local DailyReward = load("DailyReward")
	local Economy = load("Economy")

	local CAP = Economy.OFFLINE_CAP_SECONDS
	local options = {
		money = function(n: number): string
			return "$" .. math.floor(n)
		end,
		words = { Units = "Chads", Chest = "Crate" },
		age = 0,
	}
	-- A snapshot with nothing going on: no crate, today's card claimed, the free gift cooling.
	local function snapshot(): { [string]: any }
		return {
			unlockers = { { rarity = "", secondsLeft = 0, totalSeconds = 0 }, { rarity = "", secondsLeft = 0, totalSeconds = 0 } },
			passes = {},
			highestTier = 4,
			processLevel = Economy.START_PROCESS_LEVEL,
			rewardIncome = 18,
			rewardProduction = 9,
			bought = 8,
			freeIn = 300,
			daily = { claimable = false, day = 3, claimed = 3, streak = 3, nextIn = 5 * 3600, saves = false, saver = true, lapsed = 0 },
		}
	end
	local function kinds(rows: { any }): string
		local names = {}
		for _, row in rows do
			table.insert(names, row.kind)
		end
		return table.concat(names, ",")
	end
	local function find(rows: { any }, kind: string): any
		for _, row in rows do
			if row.kind == kind then
				return row
			end
		end
		return nil
	end
	local function has(text: string, part: string): boolean
		return string.find(text, part, 1, true) ~= nil
	end

	test("Comeback: durations are rounded to the minute", function()
		eq(Comeback.span(0), "1 min", "never less than a minute")
		eq(Comeback.span(45), "1 min", "under a minute")
		eq(Comeback.span(61), "2 min", "a timer rounds up")
		eq(Comeback.span(61, true), "1 min", "time passed rounds down")
		eq(Comeback.span(754), "13 min", "minutes")
		eq(Comeback.span(3 * 3600 + 12 * 60), "3h 12m", "hours and minutes")
		eq(Comeback.span(CAP), CAP // 3600 .. "h", "whole hours drop the minutes")
	end)

	test("Comeback away: the cash row names the time away and the cap", function()
		local data = snapshot()
		data.daily.streak = 0
		local rows = Comeback.away(data, { seconds = 3 * 3600 + 750, cash = 12400 }, options)
		eq(kinds(rows), "cash", "only the cash is news")
		eq(rows[1].cash, 12400, "the amount paid")
		check(has(rows[1].title, "Chads"), "the title names the units")
		check(has(rows[1].detail, "3h 12m away"), "the time away, rounded down")
		check(has(rows[1].detail, Comeback.span(CAP)), "the cap is named")
		rows = Comeback.away(data, { seconds = CAP, cash = 500 }, options)
		check(has(rows[1].detail, "was full"), "a capped absence says the cash was full")
		check(not has(rows[1].detail, "away."), "and does not claim a time away it does not know")
		eq(#Comeback.away(data, { seconds = 600, cash = 0 }, options), 0, "no cash and nothing else: no card")
		eq(#Comeback.away(data, nil, options), 0, "no offline notify: no cash row")
		eq(Comeback.cashNote(data), "Your cash is waiting on the Collect pad.", "the cash is on the pad")
		data.passes.AutoCash = true
		check(has(Comeback.cashNote(data), "wallet"), "Auto Cash already collected it")
	end)

	test("Comeback away: the crate the Smasher finished, or the one still in it", function()
		local data = snapshot()
		data.daily.streak = 0
		data.unlockers[1] = { rarity = "Rare", secondsLeft = 0, totalSeconds = 1800 }
		local rows = Comeback.away(data, { seconds = 600, cash = 50 }, options)
		eq(kinds(rows), "cash,crate", "cash first, then the crate")
		eq(rows[2].title, "Rare Crate ready", "ready: true whenever it finished")
		eq(rows[2].rarity, "Rare", "the row wears its rarity")
		rows = Comeback.away(data, { seconds = 600, cash = 50, crates = { "Rare" } }, options)
		eq(rows[2].title, "Rare Crate finished", "finished, once the server says it did while away")
		data.unlockers[2] = { rarity = "Epic", secondsLeft = 0, totalSeconds = 3600 }
		rows = Comeback.away(data, nil, options)
		eq(rows[1].title, "2 Crates ready", "two crates in one row")
		check(has(rows[1].detail, "Open them"), "plural")
		-- Still running: the time to go, rounded up, after the snapshot's age.
		data.unlockers[1] = { rarity = "Rare", secondsLeft = 780, totalSeconds = 1800 }
		data.unlockers[2] = { rarity = "Epic", secondsLeft = 3000, totalSeconds = 3600 }
		local aged = table.clone(options)
		aged.age = 60
		rows = Comeback.away(data, nil, aged)
		eq(rows[1].title, "Rare Crate: 12 min to go", "the crate that finishes first")
		aged.age = 800
		eq(Comeback.away(data, nil, aged)[1].title, "Rare Crate ready", "ready once its timer has run out")
		-- The Crate Key pass opens a crate at once.
		data.passes.CrateKey = true
		eq(Comeback.away(data, nil, options)[1].title, "2 Crates ready", "Crate Key: no timer to wait for")
	end)

	test("Comeback away: the daily card and the streak", function()
		local progression = Economy.progression(4, Economy.START_PROCESS_LEVEL)
		local data = snapshot()
		-- Claimed today: the streak, and when the next card comes.
		local rows = Comeback.away(data, nil, options)
		eq(kinds(rows), "streak", "claimed today: only the streak")
		eq(rows[1].title, "3 day streak", "the streak")
		check(has(rows[1].detail, "Next one in 5h"), "the next card, to the minute")
		-- Today's card waits and the streak goes on.
		data.daily = { claimable = true, day = 4, claimed = 3, streak = 3, nextIn = 3600, saves = false, saver = true, lapsed = 0 }
		rows = Comeback.away(data, nil, options)
		eq(kinds(rows), "daily,streak", "the card, then the streak")
		eq(rows[1].detail, "Day 4: $" .. math.floor(DailyReward.cash(4, 18, progression)), "what today's card pays, as the window shows")
		eq(rows[2].detail, "Today's reward makes it 4.", "what the claim does to the streak")
		-- A crate day names its crate.
		data.daily.day, data.daily.streak = 3, 2
		check(has(Comeback.away(data, nil, options)[1].detail, "Rare Crate + $"), "day 3 comes with its crate")
		-- The streak saver stepped in.
		data.daily.day, data.daily.streak, data.daily.saves = 4, 3, true
		rows = Comeback.away(data, nil, options)
		eq(rows[2].title, "Streak saved", "the saver is said out loud")
		check(has(rows[2].detail, "3 day streak goes on"), "with the streak it kept")
		-- The streak ended: said once, plainly.
		data.daily = { claimable = true, day = 1, claimed = 0, streak = 0, nextIn = 3600, saves = false, saver = true, lapsed = 5 }
		rows = Comeback.away(data, nil, options)
		eq(rows[2].title, "New streak", "a new streak")
		check(has(rows[2].detail, "5 day streak ended"), "names the streak that ended")
		-- Never claimed (or a single day lost): the card alone.
		data.daily.lapsed = 1
		eq(kinds(Comeback.away(data, nil, options)), "daily", "nothing to say about a streak of one")
		-- The first day's card is capped (as Server.Daily pays it).
		data.daily.firstDay = true
		eq(
			Comeback.away(data, nil, options)[1].detail,
			"Day 1: $" .. math.floor(DailyReward.cash(1, 18, progression, DailyReward.firstDayCap(1, 8))),
			"the first-day cap"
		)
	end)

	test("Comeback away: the free gift, and the order of the rows", function()
		local data = snapshot()
		data.freeIn = 0
		data.unlockers[1] = { rarity = "Rare", secondsLeft = 0, totalSeconds = 1800 }
		data.daily = { claimable = true, day = 4, claimed = 3, streak = 3, nextIn = 3600, saves = false, saver = true, lapsed = 0 }
		local rows = Comeback.away(data, { seconds = 900, cash = 80 }, options)
		eq(kinds(rows), "cash,crate,daily,streak,free", "every row, in order")
		eq(find(rows, "free").title, "Free gift ready", "the free gift")
		data.freeIn = 30
		check(find(Comeback.away(data, nil, options), "free") == nil, "not while it cools down")
		local aged = table.clone(options)
		aged.age = 31
		check(find(Comeback.away(data, nil, aged), "free") ~= nil, "ready once the cooldown has run out")
		data.freeIn = nil
		check(find(Comeback.away(data, nil, options), "free") == nil, "an unknown timer promises nothing")
		-- A snapshot with none of the fields: no rows, no error.
		eq(#Comeback.away({}, nil, options), 0, "an empty snapshot says nothing")
	end)

	test("Comeback leave: plain facts, no countdown", function()
		local data = snapshot()
		local full = Comeback.span(CAP)
		eq(
			Comeback.leaveLine(data, options),
			"Before you go: away cash fills up in " .. full .. "  |  next daily reward in 5h",
			"away cash and the next card"
		)
		eq(
			Comeback.leaveLine(data, options, false),
			"Before you go: away cash fills up in " .. full,
			"the Daily window leaves the card out"
		)
		data.unlockers[1] = { rarity = "Rare", secondsLeft = 700, totalSeconds = 1800 }
		local parts = Comeback.leave(data, options)
		eq(#parts, 3, "crate, away cash, daily")
		eq(parts[1], "Rare Crate ready in 12 min", "the crate comes first")
		data.unlockers[1].secondsLeft = 0
		eq(Comeback.leave(data, options)[1], "Rare Crate ready to open", "a finished crate")
		data.daily.claimable = true
		eq(Comeback.leave(data, options)[3], "daily reward ready", "today's card waits")
		-- A player whose units earn nothing is not promised away cash.
		local new = snapshot()
		new.rewardProduction = 0
		eq(Comeback.leaveLine(new, options, false), "", "nothing to say: no line")
		for _, part in Comeback.leave(data, options) do
			check(string.find(part, "%d:%d%d") == nil, "no ticking clock in: " .. part)
			check(string.find(string.lower(part), "hurry") == nil and string.find(part, "!") == nil, "no urgency in: " .. part)
		end
	end)

	test("Comeback client: one card on return, never stacked on the Daily window", function()
		local main = fs.readFile("src/client/Main.client.luau")
		local away = fs.readFile("src/client/UI/AwayWindow.luau")
		local daily = fs.readFile("src/client/UI/DailyWindow.luau")
		check(has(main, "AwayWindow.show(payload)"), "Main routes the Offline notify to the card")
		check(not has(main, "Popups.offline(payload)"), "and not to a second popup")
		check(has(main, "fallback = Popups.offline"), "the plain popup stays as the tutorial fallback")
		check(has(daily, "AwayWindow.build(screen"), "the Daily window builds the card under its own gate")
		check(has(daily, "not AwayWindow.holding()"), "the Daily window waits for the card")
		check(has(daily, "Comeback.leaveLine("), "the Daily window's footer has the Before you go line")
		check(has(away, "Comeback.away("), "the card shows the shared rules' rows")
		check(has(away, "d.free()"), "the card waits for a calm screen")
		check(has(away, "data.tutorialDone ~= true"), "the tutorial is never covered")
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
