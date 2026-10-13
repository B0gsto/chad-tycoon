--[[
	Unit tests for the Index milestones (src/shared/IndexRewards.luau), the saved
	`indexClaimed` profile field (DataService) and the way the server and the Index window
	use them (src/server/Tycoon.luau, src/client/UI/Windows.luau, read as source).
	Loaded by tests/run.luau with its harness: { test, check, eq, near, loadShared, loadDataService }.
]]

local fs = require("@lune/fs")

return function(h: { [string]: any })
	local test, check, eq, near = h.test, h.check, h.eq, h.near
	local Economy = h.loadShared("Economy")
	local IndexRewards = h.loadShared("IndexRewards")

	-- An Index (or a run) with its first `count` tiers found.
	local function foundTo(count: number): { number }
		local list = table.create(Economy.MAX_TIER, 0)
		for tier = 1, count do
			list[tier] = 1700000000 + tier
		end
		return list
	end

	-- A profile whose Index and run have the first `count` tiers.
	local function played(count: number): any
		local p = h.loadDataService().defaultProfile()
		p.discovered = foundTo(count)
		p.runDiscovered = foundTo(count)
		p.processLevel = math.max(p.processLevel, Economy.minProcessLevel(count))
		return p
	end

	-- An income far over the progression floor of any tier, so a claim pays seconds x income.
	local RICH = 1e15

	test("Index rewards: the five milestones", function()
		local expected = {
			{ found = 5, minutes = 10 },
			{ found = 10, minutes = 20, crate = "Rare" },
			{ found = 15, minutes = 30, crate = "Epic" },
			{ found = 20, minutes = 45, crate = "Legendary" },
			{ found = 25, minutes = 60, champion = true },
		}
		eq(#IndexRewards.MILESTONES, #expected, "milestone count")
		for i, want in expected do
			local milestone = IndexRewards.MILESTONES[i]
			local label = "milestone " .. want.found
			eq(milestone.found, want.found, label .. " tiers")
			eq(milestone.seconds, want.minutes * 60, label .. " seconds of income")
			eq(milestone.crate, want.crate, label .. " crate")
			eq(milestone.champion == true, want.champion == true, label .. " champion")
			if milestone.crate then
				check(Economy.isRarity(milestone.crate), label .. " crate is a rarity")
			end
			eq(IndexRewards.milestone(want.found), milestone, label .. " is found by its count")
		end
		eq(IndexRewards.MILESTONES[#IndexRewards.MILESTONES].found, Economy.MAX_TIER, "the last milestone is the whole Index")
		eq(IndexRewards.milestone(7), nil, "no milestone at 7")
		eq(IndexRewards.milestone("5"), nil, "a string is not a milestone")
		eq(IndexRewards.milestone(nil), nil, "nil is not a milestone")
		eq(IndexRewards.milestone({}), nil, "a table is not a milestone")
	end)

	test("Index rewards: counting the Index", function()
		eq(IndexRewards.found(foundTo(0)), 0, "empty")
		eq(IndexRewards.found(foundTo(12)), 12, "twelve")
		eq(IndexRewards.found(foundTo(25)), 25, "all")
		local gaps = foundTo(0)
		gaps[1], gaps[4], gaps[9] = 5, 6, 7
		eq(IndexRewards.found(gaps), 3, "tiers are counted, not the best one")
		eq(IndexRewards.found({ 1, "x", -4 } :: any), 1, "junk is not a tier")
	end)

	for _, milestone in IndexRewards.MILESTONES do
		test("Index rewards: claiming " .. milestone.found, function()
			-- One tier short: nothing to claim.
			local short = played(milestone.found - 1)
			eq(IndexRewards.claim(short, milestone.found, RICH), nil, "not reached yet")
			eq(#short.indexClaimed, 0, "nothing marked")
			eq(short.cosmetics.champion, false, "no Champion yet")

			local p = played(milestone.found)
			local money, units = p.money, table.clone(p.units)
			check(table.find(IndexRewards.ready(p.discovered, p.indexClaimed), milestone.found) ~= nil, "ready to claim")
			local grant = IndexRewards.claim(p, milestone.found, RICH)
			check(grant ~= nil, "claimed")
			eq(grant.found, milestone.found, "the milestone")
			near(grant.cash, milestone.seconds * RICH, "seconds of income")
			eq(grant.crate, milestone.crate, "the crate")
			eq(grant.champion, milestone.champion == true, "the Champion reward")
			eq(p.cosmetics.champion, milestone.champion == true, "the Champion flag in the profile")
			check(IndexRewards.isClaimed(p.indexClaimed, milestone.found), "marked as claimed")
			-- The rules only mark: the server grants (and nothing in the profile is taken).
			eq(p.money, money, "cash is untouched by the rules")
			for tier = 1, Economy.MAX_TIER do
				eq(p.units[tier], units[tier], "units of tier " .. tier)
			end
			eq(IndexRewards.found(p.discovered), milestone.found, "the Index is untouched")

			-- A double tap, or two remotes in a row: the second pays nothing.
			local claimedCount = #p.indexClaimed
			eq(IndexRewards.claim(p, milestone.found, RICH), nil, "second claim pays nothing")
			eq(IndexRewards.claim(p, milestone.found, RICH), nil, "nor does a third")
			eq(#p.indexClaimed, claimedCount, "and marks nothing")
			check(table.find(IndexRewards.ready(p.discovered, p.indexClaimed), milestone.found) == nil, "no longer ready")
		end)
	end

	test("Index rewards: junk from a client claims nothing", function()
		local p = played(25)
		for _, junk in { 0, -5, 7, 5.5, 26, 0 / 0, math.huge, "5", true, {} } :: { any } do
			eq(IndexRewards.claim(p, junk, RICH), nil, "junk " .. tostring(junk))
		end
		eq(IndexRewards.claim(p, nil, RICH), nil, "nil")
		eq(#p.indexClaimed, 0, "nothing was marked")
	end)

	test("Index rewards: cash follows the run's income at the claim", function()
		local milestone = IndexRewards.MILESTONES[1]
		local progression = Economy.progression(5, Economy.minProcessLevel(5))
		local floor = Economy.progressionIncome(progression)
		-- Income over the floor: exactly seconds x income.
		eq(IndexRewards.cash(milestone, floor * 10, progression), math.floor(floor * 10 * milestone.seconds), "income x seconds")
		-- A run that earns less than its own progression floor is paid the floor, as with packs.
		eq(IndexRewards.cash(milestone, 0, progression), Economy.moneyPackAmount(0, milestone.seconds, 0, progression), "the floor")
		-- Broken incomes pay the floor, never NaN.
		for _, bad in { 0 / 0, -5, math.huge } do
			local cash = IndexRewards.cash(milestone, bad, progression)
			check(cash == cash and cash > 0 and cash ~= math.huge, "a usable amount for " .. tostring(bad))
		end
		-- The very start of a run: the minimum.
		local start = Economy.progression(1, 0)
		check(IndexRewards.cash(milestone, 0, start) >= milestone.seconds * IndexRewards.MIN_INCOME, "never under MIN_INCOME per second")

		-- Stars: they are part of the income (Tycoon.moneyMultiplier), so they count once.
		local production, rate = 5000, 4000
		local plain = Economy.incomePerSecond(production, rate, 1)
		local starred = Economy.incomePerSecond(production, rate, 1 + Economy.starBonus(5))
		local big = Economy.progression(1, 0)
		near(
			IndexRewards.cash(milestone, starred, big) / IndexRewards.cash(milestone, plain, big),
			Economy.starMultiplier(5),
			"five stars: x1.5, once"
		)

		-- The same milestone claimed in a richer run pays more.
		local early, late = played(5), played(5)
		local a = IndexRewards.claim(early, 5, 1e6)
		local b = IndexRewards.claim(late, 5, 3e6)
		near(b.cash / a.cash, 3, "three times the income, three times the cash")
	end)

	test("Index rewards: a crate that does not fit is paid as cash", function()
		for _, milestone in IndexRewards.MILESTONES do
			local cash = IndexRewards.crateCash(milestone, 12)
			if milestone.crate then
				eq(cash, math.floor(Economy.chestExpectedValue(milestone.crate, 12)), milestone.crate .. " crate's worth")
				check(cash > 0, "worth something")
			else
				eq(cash, 0, "no crate at " .. milestone.found)
			end
		end
	end)

	test("Index rewards: existing players claim every milestone they passed", function()
		local DataService = h.loadDataService()
		-- A save from before the milestones, 18 tiers found.
		local old = DataService.reconcile({
			version = 4,
			money = 4321,
			bought = 700,
			processLevel = 90,
			stars = 2,
			rebirths = 1,
			discovered = foundTo(18),
			runDiscovered = foundTo(6),
			cosmetics = { trail = "Gold", toggles = { AuraGlow = false } },
		})
		eq(type(old.indexClaimed), "table", "the field exists")
		eq(#old.indexClaimed, 0, "nothing claimed yet")
		eq(old.cosmetics.champion, false, "no Champion yet")
		-- Nothing is lost.
		eq(old.money, 4321, "cash is kept")
		eq(old.stars, 2, "stars are kept")
		eq(old.rebirths, 1, "rebirths are kept")
		eq(old.cosmetics.trail, "Gold", "the trail is kept")
		eq(old.cosmetics.toggles.AuraGlow, false, "the switches are kept")
		eq(IndexRewards.found(old.discovered), 18, "the Index is kept")
		eq(Economy.highestTier(old.runDiscovered), 6, "the run is kept")

		local ready = IndexRewards.ready(old.discovered, old.indexClaimed)
		eq(#ready, 3, "three milestones are waiting")
		eq(ready[1], 5, "5")
		eq(ready[2], 10, "10")
		eq(ready[3], 15, "15")
		local state = IndexRewards.state(old, 1000)
		eq(state.found, 18, "state: found")
		eq(state.claimable, 3, "state: claimable (the HUD badge)")
		eq(state.champion, false, "state: no Champion")
		for i, milestone in IndexRewards.MILESTONES do
			local entry = state.milestones[i]
			eq(entry.found, milestone.found, "state entry " .. i)
			eq(entry.reached, milestone.found <= 18, "state reached " .. milestone.found)
			eq(entry.claimed, false, "state claimed " .. milestone.found)
			eq(entry.crate, milestone.crate, "state crate " .. milestone.found)
			eq(entry.cash, IndexRewards.cash(milestone, 1000, Economy.progression(6, old.processLevel)), "state cash " .. milestone.found)
		end

		-- Claimed in any order, each once; the ones not reached stay shut.
		check(IndexRewards.claim(old, 15, 1000) ~= nil, "15 first")
		check(IndexRewards.claim(old, 5, 1000) ~= nil, "then 5")
		eq(IndexRewards.claim(old, 20, 1000), nil, "20 is not reached")
		eq(IndexRewards.claim(old, 25, 1000), nil, "25 is not reached")
		check(IndexRewards.claim(old, 10, 1000) ~= nil, "then 10")
		eq(#IndexRewards.ready(old.discovered, old.indexClaimed), 0, "nothing left")
		local after = IndexRewards.state(old, 1000)
		eq(after.claimable, 0, "state: nothing claimable")
		eq(after.milestones[1].claimed, true, "state: 5 claimed")
		eq(after.milestones[1].cash, 0, "state: a claimed milestone pays nothing more")
		eq(after.milestones[4].claimed, false, "state: 20 not claimed")

		-- The claims survive a save and a load, in order.
		local loaded = DataService.reconcile(old)
		eq(#loaded.indexClaimed, 3, "three claims saved")
		eq(loaded.indexClaimed[1], 15, "order kept: 15")
		eq(loaded.indexClaimed[2], 5, "order kept: 5")
		eq(loaded.indexClaimed[3], 10, "order kept: 10")
		eq(#IndexRewards.ready(loaded.discovered, loaded.indexClaimed), 0, "nothing to claim again after a load")
	end)

	test("Index rewards: a rebirth neither takes a milestone back nor offers it again", function()
		local p = played(20)
		check(IndexRewards.claim(p, 5, RICH) ~= nil, "5 claimed before the rebirth")
		check(IndexRewards.claim(p, 10, RICH) ~= nil, "10 claimed before the rebirth")
		check(Economy.rebirth(p, 1800000000) > 0, "the run starts again")
		eq(Economy.highestTier(p.runDiscovered), 1, "the run is back at tier 1")
		eq(IndexRewards.found(p.discovered), 20, "the Index still has 20")
		eq(#p.indexClaimed, 2, "the claims stay")
		eq(IndexRewards.claim(p, 5, RICH), nil, "5 is not offered again")
		eq(IndexRewards.claim(p, 10, RICH), nil, "nor is 10")
		-- The ones never claimed are still there, sized by the new run.
		local ready = IndexRewards.ready(p.discovered, p.indexClaimed)
		eq(#ready, 2, "15 and 20 still wait")
		local fresh = IndexRewards.claim(p, 15, 2)
		check(fresh ~= nil, "15 claimed after the rebirth")
		eq(
			fresh.cash,
			IndexRewards.cash(IndexRewards.MILESTONES[3], 2, Economy.progression(1, p.processLevel)),
			"sized by the new run, not the old one"
		)
		check(fresh.cash < 1800 * 1000, "a tier-1 run is paid a tier-1 amount")
		-- Finding the tiers again in the new run pays nothing new.
		p.runDiscovered = foundTo(20)
		eq(IndexRewards.claim(p, 15, RICH), nil, "the new run does not offer 15 again")
		check(IndexRewards.claim(p, 20, RICH) ~= nil, "20 was never claimed: still there")
		eq(#IndexRewards.ready(p.discovered, p.indexClaimed), 0, "all four claimed, for good")
	end)

	test("Index rewards: the saved field and its migration", function()
		local DataService = h.loadDataService()
		local fresh = DataService.defaultProfile()
		eq(type(fresh.indexClaimed), "table", "a new profile has the field")
		eq(#fresh.indexClaimed, 0, "and has claimed nothing")
		eq(fresh.cosmetics.champion, false, "a new profile has no Champion")
		check(DataService.defaultProfile().indexClaimed ~= fresh.indexClaimed, "each profile has its own list")
		eq(#DataService.reconcile(nil).indexClaimed, 0, "a blank save has claimed nothing")
		eq(#DataService.reconcile({ money = 10 }).indexClaimed, 0, "an old save has claimed nothing")
		eq(#DataService.reconcile({ money = 10, indexClaimed = "x" }).indexClaimed, 0, "a broken field resets")
		eq(DataService.reconcile({ money = 10 }).cosmetics.champion, false, "an old save has no Champion")
		eq(
			DataService.reconcile({ money = 10, cosmetics = { trail = "", toggles = {}, champion = "x" } }).cosmetics.champion,
			false,
			"a broken flag resets"
		)

		-- Junk is dropped, a milestone is kept once, the order stays.
		local odd = DataService.reconcile({
			money = 10,
			discovered = foundTo(25),
			indexClaimed = { 10, "5", 5, 10, 0 / 0, -5, 5.5, 99, 0, 15 },
		})
		eq(#odd.indexClaimed, 3, "three real claims")
		eq(odd.indexClaimed[1], 10, "first")
		eq(odd.indexClaimed[2], 5, "second")
		eq(odd.indexClaimed[3], 15, "third")
		eq(#IndexRewards.ready(odd.discovered, odd.indexClaimed), 2, "20 and 25 are left")

		-- The whole Index claimed: the Champion flag is owned, and stays owned.
		local champion = DataService.reconcile({ money = 10, discovered = foundTo(25), indexClaimed = { 5, 10, 15, 20, 25 } })
		eq(champion.cosmetics.champion, true, "claimed 25: Champion owned, whatever the flag said")
		eq(DataService.reconcile(champion).cosmetics.champion, true, "and after another load")
		eq(#DataService.reconcile(champion).indexClaimed, 5, "five claims kept")
		local kept = DataService.reconcile({ money = 10, cosmetics = { trail = "", toggles = {}, champion = true } })
		eq(kept.cosmetics.champion, true, "a saved flag is never taken back")

		-- Claiming 25 sets the flag; the state says so (the gold Index frame).
		local p = played(25)
		for _, milestone in IndexRewards.MILESTONES do
			check(IndexRewards.claim(p, milestone.found, RICH) ~= nil, "claim " .. milestone.found)
		end
		eq(p.cosmetics.champion, true, "Champion owned")
		local state = IndexRewards.state(p, RICH)
		eq(state.champion, true, "state: Champion")
		eq(state.claimable, 0, "state: nothing left")
		eq(DataService.reconcile(p).cosmetics.champion, true, "kept on load")
	end)

	test("Index rewards: the server claims with the rules, the window asks the server", function()
		local server = fs.readFile("src/server/Tycoon.luau")
		local function has(source: string, text: string, message: string)
			check(string.find(source, text, 1, true) ~= nil, message)
		end
		has(server, "actionHandlers.ClaimIndex = function(session, data)", "the ClaimIndex action exists")
		-- Sized by the surge-free reward income (stars are inside Tycoon.moneyMultiplier, once).
		has(server, "IndexRewards.claim(p, data.found, Tycoon.income(session))", "the claim is sized by Tycoon.income")
		has(server, "Economy.starBonus(session.profile.stars)", "the stars are part of the money multiplier")
		check(string.find(server, "IndexRewards.claim(p, data.found, Tycoon.incomeNow", 1, true) == nil, "not by the surge income")
		has(server, 'Tycoon.grantMoney(session, cash, "Index")', "the cash is granted as Index cash")
		has(server, "Tycoon.grantCrate(session, crate, tier)", "the crate is opened on the spot")
		has(server, "IndexRewards.crateCash(milestone, highestTier(session))", "a full rack is paid in cash")
		has(server, 'emit(session, "IndexClaim"', "the claim is announced to listeners")
		has(server, "index = index,", "the snapshot carries the milestones")
		has(server, "indexClaimable = index.claimable,", "and the HUD's count")
		-- The mark comes before any grant: the claim is the first thing the handler does.
		local handler = string.sub(server, (string.find(server, "actionHandlers.ClaimIndex = function", 1, true)))
		local claimAt = string.find(handler, "IndexRewards.claim(", 1, true)
		local grantAt = string.find(handler, "Tycoon.grantMoney(", 1, true)
		local rollAt = string.find(handler, "Tycoon.rollCrate(", 1, true)
		check(claimAt ~= nil and grantAt ~= nil and rollAt ~= nil, "claim, roll and grant are in the handler")
		check(claimAt < rollAt and claimAt < grantAt, "the milestone is marked before anything is granted")

		local client = fs.readFile("src/client/UI/Windows.luau")
		has(client, 'action:FireServer({ action = "ClaimIndex", found = entry.found })', "the window sends ClaimIndex")
		has(client, "IndexRewards.MILESTONES", "the track has a cell per milestone")
		check(string.find(client, "indexClaimed", 1, true) == nil, "the window reads the server's `index`, not the save")
	end)
end
