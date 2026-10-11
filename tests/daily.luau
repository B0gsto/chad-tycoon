--[[
	Unit tests for the daily reward rules (src/shared/DailyReward.luau), the HUD's next-goal
	pick (src/shared/NextGoal.luau) and the saved `daily` profile field (DataService).
	Loaded by tests/run.luau with its harness: { test, check, eq, near, loadShared, loadDataService }.
]]

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

	-- Next goal -------------------------------------------------------------------------

	local function profile(best: number, units: { number }, buyTier: number?, boughtAtTier: number?, money: number?)
		local discovered = table.create(Economy.MAX_TIER, 0)
		for tier = 1, best do
			discovered[tier] = 1
		end
		local owned = table.create(Economy.MAX_TIER, 0)
		for tier, n in units do
			owned[tier] = n
		end
		return { discovered = discovered, units = owned, buyTier = buyTier or 1, boughtAtTier = boughtAtTier or 0, money = money or 0 }
	end
	local function nameOf(tier: number): string
		return "T" .. tier
	end
	local function money(n: number): string
		return "$" .. n
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
		local title, hint, count = NextGoal.text(goal, nameOf, money)
		eq(title, "T2", "title names the target")
		eq(hint, "merge 2x T1", "hint says what to merge")
		eq(count, "1/2", "count")

		goal = NextGoal.pick(profile(1, { 2 }))
		check(goal.ready, "ready with a pair")
		near(goal.progress, 1, "full bar with a pair")
		eq(select(3, NextGoal.text(goal, nameOf, money)), "2/2", "count with a pair")

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

		-- The merge goal comes first even when a buy tier upgrade is ready.
		local cost = Economy.buyTierUpgradeCost(1)
		eq(NextGoal.pick(profile(5, { 1 }, 1, Economy.buyTierRequirement(1), cost * 10)).kind, "merge", "merge goal first")
		eq(NextGoal.pick(profile(24, { 1 })).tier, 25, "the last tier is a goal too")

		-- Broken unit counts are ignored.
		local broken = profile(2, {})
		broken.units[1] = -4
		broken.units[2] = 0 / 0
		goal = NextGoal.pick(broken)
		eq(goal.have, 0, "bad counts read as zero")
		near(goal.progress, 0, "no progress from bad counts")
	end)

	test("NextGoal: buy tier and full rack fallbacks", function()
		local all = Economy.MAX_TIER
		local need = Economy.buyTierRequirement(3)
		local cost = Economy.buyTierUpgradeCost(3)
		local goal = NextGoal.pick(profile(all, { 1 }, 3, 0, 0))
		eq(goal.kind, "buyTier", "every tier found: unlock the next buy tier")
		eq(goal.tier, 4, "next buy tier")
		eq(goal.from, 3, "units bought at the current buy tier")
		eq(goal.need, need, "the upgrade requirement")
		eq(goal.have, 0, "none bought yet")
		eq(goal.cost, cost, "upgrade cost")
		near(goal.progress, 0, "empty bar")
		local title, hint, count = NextGoal.text(goal, nameOf, money)
		eq(title, "Buy Tier 4", "buy tier title")
		eq(hint, string.format("buy %d more T3", need), "buy tier hint")
		eq(count, "0/" .. need, "buy tier count")

		goal = NextGoal.pick(profile(all, { 1 }, 3, need, cost / 2))
		eq(goal.have, need, "requirement met")
		near(goal.progress, 0.75, "half the cash is three quarters of the bar")
		check(not goal.ready, "not ready without the cash")
		title, hint, count = NextGoal.text(goal, nameOf, money)
		eq(hint, "save $" .. cost, "saving hint")
		eq(count, "50%", "saving count")

		goal = NextGoal.pick(profile(all, { 1 }, 3, need + 50, cost))
		check(goal.ready, "ready with the units and the cash")
		eq(goal.have, need, "purchases past the requirement are capped")
		near(goal.progress, 1, "full bar")
		eq(select(3, NextGoal.text(goal, nameOf, money)), "READY", "ready count")

		local units = table.create(all, 0)
		units[all] = 37
		goal = NextGoal.pick(profile(all, units, Economy.MAX_BUY_TIER, 0, 0))
		eq(goal.kind, "rack", "nothing left to unlock: stack the top tier")
		eq(goal.tier, all, "top tier")
		eq(goal.have, 37, "top-tier units owned")
		eq(goal.need, Economy.UNIT_CAP, "the rack's size")
		near(goal.progress, 37 / Economy.UNIT_CAP, "rack bar")
		title, hint, count = NextGoal.text(goal, nameOf, money)
		eq(title, "T" .. all, "rack title")
		eq(count, "37/" .. Economy.UNIT_CAP, "rack count")
	end)
end
