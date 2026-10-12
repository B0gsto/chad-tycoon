--[[
	Unit tests for the daily reward rules (src/shared/DailyReward.luau), its server
	(src/server/Daily.luau, run against a stub Tycoon), the HUD's next-goal pick
	(src/shared/NextGoal.luau) and the saved `daily` profile field (DataService).
	Loaded by tests/run.luau with its harness: { test, check, eq, near, loadShared, loadDataService }.
]]

local fs = require("@lune/fs")
local luau = require("@lune/luau")

return function(h: { [string]: any })
	local test, check, eq, near = h.test, h.check, h.eq, h.near
	local Economy = h.loadShared("Economy")
	local DailyReward = h.loadShared("DailyReward")
	local NextGoal = h.loadShared("NextGoal")

	local DAY = 86400
	local TODAY = 20000

	test("Daily: UTC days and the countdown", function()
		eq(DailyReward.dayNumber(0), 0, "day 0")
		eq(DailyReward.dayNumber(DAY - 1), 0, "last second of day 0")
		eq(DailyReward.dayNumber(DAY), 1, "first second of day 1")
		eq(DailyReward.dayNumber(TODAY * DAY + 4321.5), TODAY, "fractional time")
		eq(DailyReward.secondsLeft(0), DAY, "a whole day left at midnight")
		eq(DailyReward.secondsLeft(DAY - 1), 1, "one second left")
		eq(DailyReward.secondsLeft(TODAY * DAY + 10), DAY - 10, "countdown")
		eq(DailyReward.card(0), 1, "card of no streak")
		eq(DailyReward.card(7), 7, "card 7")
		eq(DailyReward.card(8), 1, "card loops after 7")
		eq(DailyReward.card(14), 7, "second week ends on card 7")
	end)

	test("Daily: one claim per day", function()
		local status = DailyReward.status(0, 0, TODAY)
		check(status.claimable, "a new player can claim")
		eq(status.day, 1, "new player starts on day 1")
		eq(status.claimed, 0, "nothing ticked yet")
		eq(status.streak, 0, "no streak yet")
		local streak, day = DailyReward.claim(0, 0, TODAY)
		eq(streak, 1, "first claim starts the streak")
		eq(day, 1, "first claim pays card 1")
		status = DailyReward.status(TODAY, 1, TODAY)
		check(not status.claimable, "claimed today")
		eq(status.day, 1, "today's card is the claimed one")
		eq(status.claimed, 1, "card 1 ticked")
		eq(DailyReward.claim(TODAY, 1, TODAY), nil, "a second claim the same day pays nothing")
		check(not DailyReward.status(TODAY + 1, 3, TODAY).claimable, "a claim dated ahead of this clock counts as today")
		check(DailyReward.status(TODAY, 0, TODAY).claimable, "a save with no streak can always claim")
	end)

	test("Daily: streak advances, loops after day 7 and resets on a missed day", function()
		local lastDay, streak = 0, 0
		for n = 1, 16 do
			local today = TODAY + n
			local before = DailyReward.status(lastDay, streak, today)
			local card = (n - 1) % 7 + 1
			check(before.claimable, "claimable on consecutive day " .. n)
			eq(before.day, card, "card on day " .. n)
			eq(before.claimed, card - 1, "ticks before the claim on day " .. n)
			local newStreak, paid = DailyReward.claim(lastDay, streak, today)
			eq(newStreak, n, "streak on day " .. n)
			eq(paid, card, "card paid on day " .. n)
			lastDay, streak = today, newStreak :: number
			local after = DailyReward.status(lastDay, streak, today)
			check(not after.claimable, "claimed on day " .. n)
			eq(after.claimed, card, "ticks after the claim on day " .. n)
		end
		-- One day skipped: back to day 1.
		local missed = DailyReward.status(TODAY, 5, TODAY + 2)
		check(missed.claimable, "claimable after a missed day")
		eq(missed.day, 1, "a missed day restarts at day 1")
		eq(missed.claimed, 0, "ticks cleared after a missed day")
		eq(missed.streak, 0, "streak cleared after a missed day")
		local newStreak, paid = DailyReward.claim(TODAY, 5, TODAY + 2)
		eq(newStreak, 1, "streak restarts at 1")
		eq(paid, 1, "restart pays card 1")
		eq(select(2, DailyReward.claim(TODAY, 5, TODAY + 30)), 1, "a long break restarts too")
	end)

	test("Daily: rewards grow each day and scale with income", function()
		eq(DailyReward.DAYS, 7, "seven cards")
		eq(#DailyReward.REWARDS, 7, "seven rewards")
		for day = 1, 7 do
			local reward = DailyReward.REWARDS[day]
			if day > 1 then
				local previous = DailyReward.REWARDS[day - 1]
				check(reward.seconds > previous.seconds, "seconds grow on day " .. day)
				check(reward.min > previous.min, "minimum grows on day " .. day)
			end
			if day == 3 or day == 7 then
				check(reward.crate ~= nil and Economy.isRarity(reward.crate), "a real crate on day " .. day)
			else
				eq(reward.crate, nil, "no crate on day " .. day)
			end
		end
		check(
			Economy.CHEST_INFO[DailyReward.REWARDS[7].crate].weight < Economy.CHEST_INFO[DailyReward.REWARDS[3].crate].weight,
			"day 7's crate is the rarer one"
		)
		for _, income in { 0, 2, 1500, 4e9 } do
			for _, tier in { 1, 6, 25 } do
				local progression = Economy.progression(tier, 0)
				local last = 0
				for day = 1, 7 do
					local reward = DailyReward.REWARDS[day]
					local cash = DailyReward.cash(day, income, progression)
					check(cash > last, string.format("cash grows on day %d at income %d", day, income))
					check(cash >= reward.min, "never below the day's minimum")
					eq(cash, Economy.moneyPackAmount(income, reward.seconds, reward.min, progression), "sized like a cash pack")
					last = cash
				end
			end
		end
		near(DailyReward.cash(1, 1e6, Economy.progression(1, 0)), 1e6 * 300, "day 1 is five minutes of income")
		near(DailyReward.cash(7, 1e6, Economy.progression(1, 0)), 1e6 * 3600, "day 7 is an hour of income")
		eq(DailyReward.cash(8, 10, Economy.progression(1, 0)), DailyReward.cash(1, 10, Economy.progression(1, 0)), "day 8 is card 1")
		eq(DailyReward.describe(2, "$500", "Crate"), "$500", "cash day in words")
		eq(DailyReward.describe(3, "$1.00K", "Crate"), "Rare Crate + $1.00K", "crate day in words")
		eq(DailyReward.describe(7, "$15.00K", "Crate"), "Legendary Crate + $15.00K", "day 7 in words")
	end)

	test("Daily: saved profile field and old saves", function()
		local DataService = h.loadDataService()
		local fresh = DataService.reconcile(nil).daily
		eq(fresh.day, 0, "new players have never claimed")
		eq(fresh.streak, 0, "new players have no streak")
		eq(fresh.firstDay, 0, "new players' first day is stamped by the server")
		eq(fresh.hinted, false, "new players have not seen the come-back toast")
		local legacy = DataService.reconcile({ money = 10, totalObtained = 3 }).daily
		eq(legacy.day, 0, "old saves can claim day 1")
		eq(legacy.streak, 0, "old saves have no streak")
		eq(legacy.firstDay, 1, "old saves are not on their first day")
		eq(legacy.hinted, true, "old saves never get the first-day toast")
		local kept = DataService.reconcile({ money = 10, daily = { day = TODAY, streak = 4, firstDay = TODAY - 9, hinted = true } }).daily
		eq(kept.day, TODAY, "claim day kept")
		eq(kept.streak, 4, "streak kept")
		eq(kept.firstDay, TODAY - 9, "first day kept")
		eq(kept.hinted, true, "hint flag kept")
		local broken = DataService.reconcile({ money = 10, daily = { day = -5, streak = 0 / 0, firstDay = "x", hinted = 1 } }).daily
		eq(broken.day, 0, "negative day reset")
		eq(broken.streak, 0, "NaN streak reset")
		eq(broken.firstDay, 0, "non-number first day reset")
		eq(broken.hinted, false, "non-boolean hint flag reset")
		eq(DataService.reconcile({ money = 10, daily = { day = TODAY + 0.7, streak = 2.9 } }).daily.day, TODAY, "day floored")
		eq(DataService.reconcile({ money = 10, daily = "x" }).daily.streak, 0, "a broken daily field resets")
		local status = DailyReward.status(legacy.day, legacy.streak, TODAY)
		check(status.claimable and status.day == 1, "an old save starts on day 1")
	end)

	test("Daily: a first day pays a boost, not a tier skip", function()
		-- The playtest's new player: tier 4 a minute in, a dozen units bought, $18/s.
		local progression = Economy.progression(4, Economy.START_PROCESS_LEVEL)
		local open = DailyReward.cash(1, 18, progression)
		for bought = 0, 20 do
			local cap = DailyReward.firstDayCap(1, bought)
			local cash = DailyReward.cash(1, 18, progression, cap)
			check(cash >= DailyReward.REWARDS[1].min, "never below day 1's minimum at " .. bought)
			check(cash <= 1000, "a few hundred cash at " .. bought)
			check(cash < open / 4, "far below the income-sized reward at " .. bought)
			-- Three to five of the units the player is buying.
			check(cash >= Economy.bulkPrice(bought, 3) or cash == DailyReward.REWARDS[1].min, "buys three units at " .. bought)
			check(cash <= math.max(DailyReward.REWARDS[1].min, Economy.bulkPrice(bought, 5)), "not six units at " .. bought)
		end
		eq(DailyReward.firstDayCap(1, 5), math.floor(Economy.bulkPrice(5, DailyReward.FIRST_DAY_UNITS)), "the next units' price")
		eq(DailyReward.firstDayCap(1, 0), DailyReward.REWARDS[1].min, "the minimum when units cost less")
		-- The cap only ever lowers the reward, and a later day has none.
		eq(
			DailyReward.cash(1, 0, Economy.progression(1, 0), 1e9),
			DailyReward.cash(1, 0, Economy.progression(1, 0)),
			"cap above the reward"
		)
		eq(DailyReward.cash(1, 18, progression, nil), open, "no cap after the first day")
	end)

	test("Daily: a crate that does not fit is paid as cash", function()
		eq(DailyReward.crateCash(1, 10), 0, "no crate on day 1")
		for _, day in { 3, 7, 10 } do
			local crate = DailyReward.REWARDS[DailyReward.card(day)].crate
			for _, tier in { 1, 8, 25 } do
				local cash = DailyReward.crateCash(day, tier)
				check(cash > 0, "worth something on day " .. day)
				eq(cash, math.floor(Economy.chestExpectedValue(crate, tier)), "the crate's average unit on day " .. day)
			end
		end
		check(DailyReward.crateCash(7, 12) > DailyReward.crateCash(3, 12), "the Legendary crate is worth more")
	end)

	test("Daily: the window waits for a held crate, then opens anyway", function()
		local function run(needed: number, at: (number) -> (boolean, boolean)): number?
			local state = DailyReward.autoOpen()
			for tick = 1, 400 do
				local blocked, crate = at(tick * 0.5)
				if DailyReward.autoOpenTick(state, 0.5, blocked, crate, needed) then
					return tick * 0.5
				end
			end
			return nil
		end
		eq(
			run(2, function()
				return false, false
			end),
			2,
			"opens after the calm"
		)
		eq(
			run(2, function()
				return true, false
			end),
			nil,
			"never while blocked"
		)
		-- A crate held from the start and dealt with at 6 s: the calm starts there.
		eq(
			run(2, function(t)
				return false, t <= 6
			end),
			8,
			"opens once the crate is gone"
		)
		-- A crate never dealt with: the window gives it CRATE_PATIENCE, then opens over it.
		eq(
			run(2, function()
				return false, true
			end),
			DailyReward.CRATE_PATIENCE + 2,
			"stops waiting for the crate"
		)
		-- The tutorial blocks for 30 s with a crate in hand the whole time: only the time
		-- after it counts, and it never opens during it.
		eq(
			run(8, function(t)
				return t <= 30, true
			end),
			30 + DailyReward.CRATE_PATIENCE + 8,
			"the tutorial comes first"
		)
		-- A popup during the calm starts it over.
		eq(
			run(2, function(t)
				return t == 1.5, false
			end),
			3.5,
			"an interruption restarts the calm"
		)
	end)

	-- Server.Daily against a stub Tycoon ------------------------------------------------

	local function loadDaily(now: { time: number, clock: number })
		local Format = h.loadShared("Format")
		local shared = { DailyReward = DailyReward, Economy = Economy, Format = Format }
		local log = { notifies = {}, toasts = {}, money = 0, crates = {}, dirty = {}, warns = 0, room = true }
		local sessions = {}
		local Tycoon = {
			hooks = {},
			actions = {},
			income = function(session)
				return session.income
			end,
			toast = function(_, text)
				table.insert(log.toasts, text)
			end,
			notify = function(_, payload)
				table.insert(log.notifies, payload)
			end,
			grantMoney = function(_, amount)
				log.money += amount
			end,
			rollCrate = function()
				return if log.room then 5 else nil
			end,
			grantCrate = function(_, rarity, tier)
				table.insert(log.crates, rarity .. tier)
			end,
			markDirty = function(session)
				log.dirty[session] = (log.dirty[session] or 0) + 1
			end,
			allSessions = function()
				return sessions
			end,
		}
		Tycoon.addAction = function(name, fn)
			Tycoon.actions[name] = fn
		end
		local loop: (() -> ())?
		local env = setmetatable({
			game = {
				GetService = function()
					return {
						WaitForChild = function()
							return shared
						end,
					}
				end,
			},
			script = { Parent = { Tycoon = Tycoon } },
			require = function(module)
				return module
			end,
			os = {
				time = function()
					return now.time
				end,
				clock = function()
					return now.clock
				end,
			},
			task = {
				spawn = function(fn)
					loop = fn
				end,
				wait = function()
					coroutine.yield()
				end,
			},
			warn = function()
				log.warns += 1
			end,
		}, { __index = _G })
		local path = "src/server/Daily.luau"
		local Daily = luau.load(fs.readFile(path), { debugName = path, environment = env })()
		Daily.init({ Words = { Chest = "Crate" } })
		return Daily, Tycoon, log, sessions, coroutine.wrap(loop :: any)
	end
	local function session(firstDay: number, streak: number, lastDay: number): { [string]: any }
		local discovered = table.create(Economy.MAX_TIER, 0)
		for tier = 1, 4 do
			discovered[tier] = 1
		end
		return {
			alive = true,
			income = 18,
			profile = {
				discovered = discovered,
				processLevel = Economy.START_PROCESS_LEVEL,
				bought = 8,
				tutorialDone = true,
				daily = { day = lastDay, streak = streak, firstDay = firstDay, hinted = true },
			},
		}
	end

	test("Daily server: a first-day claim is capped, a later one is not", function()
		local now = { time = TODAY * DAY + 60, clock = 0 }
		local Daily, Tycoon, log = loadDaily(now)
		local progression = Economy.progression(4, Economy.START_PROCESS_LEVEL)
		local new = session(TODAY, 0, 0)
		eq(Tycoon.hooks.daily(new).firstDay, true, "the snapshot says it is the first day")
		Daily.claim(new)
		eq(log.money, DailyReward.firstDayCap(1, 8), "paid the next units' price")
		check(log.money < DailyReward.cash(1, 18, progression) / 4, "not the income-sized reward")
		eq(log.notifies[1].cash, log.money, "the notify names what was paid")
		eq(new.profile.daily.streak, 1, "the claim counts")
		Daily.claim(new)
		eq(#log.notifies, 1, "one claim a day")

		log.money = 0
		local old = session(1, 0, 0)
		eq(Tycoon.hooks.daily(old).firstDay, false, "an old save is not on its first day")
		Daily.claim(old)
		eq(log.money, DailyReward.cash(1, 18, progression), "established players get the income-sized reward")
	end)

	test("Daily server: a full rack turns the crate into cash", function()
		local now = { time = TODAY * DAY + 60, clock = 0 }
		local Daily, _, log = loadDaily(now)
		local progression = Economy.progression(4, Economy.START_PROCESS_LEVEL)
		-- Day 3 with room: cash and the crate.
		local player = session(TODAY - 2, 2, TODAY - 1)
		Daily.claim(player)
		eq(log.money, DailyReward.cash(3, 18, progression), "day 3's cash")
		eq(log.crates[1], "Rare5", "the crate is opened")
		eq(log.notifies[1].crate, "Rare", "the notify names the crate")
		eq(log.notifies[1].crateCash, nil, "nothing swapped")
		eq(#log.toasts, 0, "no toast")
		-- Day 3 with no room: the claim is used and the crate's worth is paid on top.
		log.room, log.money = false, 0
		local full = session(TODAY - 2, 2, TODAY - 1)
		Daily.claim(full)
		local extra = DailyReward.crateCash(3, 4)
		check(extra > 0, "the crate is worth something")
		eq(log.money, DailyReward.cash(3, 18, progression) + extra, "cash plus the crate's worth")
		eq(#log.crates, 1, "no crate is opened")
		eq(log.notifies[2].crate, nil, "the notify shows no crate")
		eq(log.notifies[2].crateCash, extra, "the notify names the swap")
		eq(log.notifies[2].cash, log.money, "the notify's cash is what was paid")
		eq(#log.toasts, 1, "the player is told")
		check(string.find(log.toasts[1], "Rare Crate", 1, true) ~= nil, "the toast names the crate")
		eq(full.profile.daily.streak, 3, "the claim counts")
	end)

	test("Daily server: one session's error does not stop the loop", function()
		local now = { time = TODAY * DAY + 60, clock = 0 }
		local _, _, log, sessions, step = loadDaily(now)
		-- A session torn down mid-check: reading its profile throws.
		local broken = setmetatable({ alive = true }, {
			__index = function()
				error("session is gone")
			end,
		})
		local healthy = session(TODAY, 1, TODAY)
		sessions[1], sessions[2] = broken, healthy
		step()
		step()
		eq(log.warns, 1, "the error is reported")
		eq(log.dirty[healthy], nil, "nothing to refresh on the same day")
		-- The next UTC day: the loop is still running and refreshes the healthy session.
		now.time += DAY
		step()
		eq(log.warns, 2, "still checking the broken session")
		eq(log.dirty[healthy], 1, "the healthy session is refreshed at the day change")
		step()
		eq(log.dirty[healthy], 1, "once per day change")
	end)

	-- Next goal -------------------------------------------------------------------------

	local function profile(best: number, units: { number })
		local discovered = table.create(Economy.MAX_TIER, 0)
		for tier = 1, best do
			discovered[tier] = 1
		end
		local owned = table.create(Economy.MAX_TIER, 0)
		for tier, n in units do
			owned[tier] = n
		end
		return { discovered = discovered, units = owned }
	end
	local function nameOf(tier: number): string
		return "T" .. tier
	end

	test("NextGoal: the next undiscovered tier", function()
		local goal = NextGoal.pick(profile(1, { 1 }))
		eq(goal.kind, "merge", "a new player aims at a merge")
		eq(goal.tier, 2, "target tier")
		eq(goal.from, 1, "merge the best tier found")
		eq(goal.have, 1, "one unit so far")
		eq(goal.need, Economy.MERGE_RATIO, "two units merge")
		near(goal.progress, 0.5, "half way")
		check(not goal.ready, "not ready with one unit")
		local title, hint, count = NextGoal.text(goal, nameOf)
		eq(title, "T2", "title names the target")
		eq(hint, "merge 2x T1", "hint says what to merge")
		eq(count, "1/2", "count")

		goal = NextGoal.pick(profile(1, { 2 }))
		check(goal.ready, "ready with a pair")
		near(goal.progress, 1, "full bar with a pair")
		eq(select(3, NextGoal.text(goal, nameOf)), "2/2", "count with a pair")

		-- Lower tiers count toward the bar: 2 x T1 + 1 x T2 + 1 x T3 are two merges from a T3 pair.
		goal = NextGoal.pick(profile(3, { 2, 1, 1 }))
		eq(goal.tier, 4, "target above the best tier")
		eq(goal.from, 3, "merge the best tier")
		eq(goal.have, 1, "one of the best tier")
		near(goal.progress, 1, "enough lower units for the pair")
		check(not goal.ready, "the pair itself is not there yet")
		near(NextGoal.pick(profile(3, { 0, 1, 0 })).progress, 0.25, "one T2 is a quarter of a T3 pair")
		eq(NextGoal.pick(profile(3, { 0, 0, 9 })).have, 2, "have is capped at the pair")
		near(NextGoal.pick(profile(4, { 400 })).progress, 1, "progress is capped at 1")

		eq(NextGoal.pick(profile(24, { 1 })).tier, 25, "the last tier is a goal too")

		-- Broken unit counts are ignored.
		local broken = profile(2, {})
		broken.units[1] = -4
		broken.units[2] = 0 / 0
		goal = NextGoal.pick(broken)
		eq(goal.have, 0, "bad counts read as zero")
		near(goal.progress, 0, "no progress from bad counts")
	end)

	test("NextGoal: full rack fallback", function()
		local all = Economy.MAX_TIER
		local units = table.create(all, 0)
		units[all] = 37
		local goal = NextGoal.pick(profile(all, units))
		eq(goal.kind, "rack", "every tier found: stack the top tier")
		eq(goal.tier, all, "top tier")
		eq(goal.have, 37, "top-tier units owned")
		eq(goal.need, Economy.UNIT_CAP, "the rack's size")
		near(goal.progress, 37 / Economy.UNIT_CAP, "rack bar")
		local title, _, count = NextGoal.text(goal, nameOf)
		eq(title, "T" .. all, "rack title")
		eq(count, "37/" .. Economy.UNIT_CAP, "rack count")
	end)
end
