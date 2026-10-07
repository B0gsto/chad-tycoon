--[[
	Unit tests for the pure shared modules and the theme.
	Run with:  lune run tests/run
]]

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local process = require("@lune/process")
local roblox = require("@lune/roblox")

local Economy = require("../src/shared/Economy")
local Format = require("../src/shared/Format")
local SessionLock = require("../src/shared/SessionLock")
local TutorialSteps = require("../src/shared/TutorialSteps")
local CratePickup = require("../src/shared/CratePickup")

local passed, failed = 0, 0
local currentTest = ""

local function check(condition: boolean, message: string)
	if condition then
		passed += 1
	else
		failed += 1
		print(string.format("  FAIL [%s] %s", currentTest, message))
	end
end

local function eq(actual: any, expected: any, message: string?)
	check(actual == expected, string.format("%s: expected %s, got %s", message or "value", tostring(expected), tostring(actual)))
end

local function near(actual: number, expected: number, message: string?)
	local tolerance = math.max(1e-9, math.abs(expected) * 1e-9)
	check(
		math.abs(actual - expected) <= tolerance,
		string.format("%s: expected ~%s, got %s", message or "value", tostring(expected), tostring(actual))
	)
end

local function test(name: string, fn: () -> ())
	currentTest = name
	local ok, err = pcall(fn)
	if not ok then
		failed += 1
		print(string.format("  ERROR [%s] %s", name, tostring(err)))
	end
end

local function seeded(seed: number): () -> number
	local state = seed
	return function()
		state = (state * 1103515245 + 12345) % 2147483648
		return state / 2147483648
	end
end

-- Format ------------------------------------------------------------------------

test("Format.short", function()
	eq(Format.short(0), "0")
	eq(Format.short(999), "999")
	eq(Format.short(999.9), "999")
	eq(Format.short(1000), "1.00K")
	eq(Format.short(1234), "1.23K")
	eq(Format.short(1799), "1.79K")
	eq(Format.short(999999), "999.99K")
	eq(Format.short(1e6), "1.00M")
	eq(Format.short(24.88e6), "24.88M")
	eq(Format.short(1e12), "1.00T")
	eq(Format.short(-1500), "-1.50K")
	eq(Format.short(0 / 0), "0")
	check(Format.short(1e80):find("e") ~= nil, "huge numbers use scientific notation")
end)

test("Format.commas", function()
	eq(Format.commas(0), "0")
	eq(Format.commas(100), "100")
	eq(Format.commas(1000), "1,000")
	eq(Format.commas(123456), "123,456")
	eq(Format.commas(1234567), "1,234,567")
	eq(Format.commas(-9876543), "-9,876,543")
	eq(Format.commas(2e15), Format.short(2e15), "very large falls back to short")
end)

test("Format.time/clock", function()
	eq(Format.time(0), "0:00")
	eq(Format.time(75), "1:15")
	eq(Format.time(3725), "1:02:05")
	eq(Format.clock(0), "00:00:00")
	eq(Format.clock(86399), "23:59:59")
	eq(Format.multiplier(1.25), "1.2x")
end)

-- Economy -------------------------------------------------------------------------

test("tiers and merging", function()
	eq(Economy.MAX_TIER, 25, "max tier")
	check(Economy.TIER_RATE_GROWTH > Economy.MERGE_RATIO, "merging must increase production")
	eq(Economy.unitRate(1), 1, "tier 1 rate")
	near(Economy.unitRate(3), Economy.TIER_RATE_GROWTH ^ 2, "tier 3 rate")

	local units = table.create(25, 0)
	units[1] = 5
	local merges, top = Economy.mergeAll(units)
	eq(merges, 3, "merges")
	eq(top, 3, "top tier created")
	eq(units[1], 1, "tier 1 leftover")
	eq(units[2], 0, "tier 2 consumed")
	eq(units[3], 1, "tier 3 created")
	local stepUnits = table.create(25, 0)
	stepUnits[1] = 5
	local _, _, steps = Economy.mergeAll(stepUnits)
	eq(#steps, 2, "merge steps")
	eq(steps[1].tier, 1, "first step tier")
	eq(steps[1].made, 2, "first step made")
	eq(steps[2].tier, 2, "second step tier")
	eq(steps[2].made, 1, "second step made")

	local none = table.create(25, 0)
	none[4] = 1
	local m2 = Economy.mergeAll(none)
	eq(m2, 0, "nothing to merge")

	local capped = table.create(25, 0)
	capped[25] = 7
	Economy.mergeAll(capped)
	eq(capped[25], 7, "tier 25 never merges further")

	-- Merging never lowers production.
	local before = table.create(25, 0)
	before[1] = 1000
	local p0 = Economy.productionPerSecond(before)
	Economy.mergeAll(before)
	check(Economy.productionPerSecond(before) > p0, "production increases after merging")
	eq(Economy.totalUnits({ 1, 2, 3 }), 6, "totalUnits")
end)

-- Value of a unit collection as the merge rule defines it (a merge keeps it exactly).
local function unitsValue(units: { number }): number
	local total = 0
	for tier = 1, Economy.MAX_TIER do
		total += (units[tier] or 0) * Economy.unitValue(tier)
	end
	return total
end

test("unit cap: addUnitsCapped", function()
	eq(Economy.UNIT_CAP, 100, "cap")
	eq(Economy.DISPLAY_SLOTS, Economy.UNIT_CAP, "every unit has a display slot")
	eq(Economy.DISPLAY_ROWS * Economy.DISPLAY_COLS, Economy.DISPLAY_SLOTS, "10 x 10 rack")

	-- Room left: everything is taken, nothing merges, the input is untouched.
	local units = table.create(25, 0)
	units[3] = 40
	local r = Economy.addUnitsCapped(units, 1, 25)
	eq(r.accepted, 25, "fits without merging")
	eq(#r.steps, 0, "no merges below the cap")
	eq(r.units[1], 25, "added")
	eq(units[1], 0, "input untouched")

	-- At the cap the lowest pair merges first; the arriving unit can complete it.
	local full = table.create(25, 0)
	full[1] = 1
	full[3] = 2
	full[25] = 97
	r = Economy.addUnitsCapped(full, 1, 1)
	eq(r.accepted, 1, "accepted at the cap")
	eq(Economy.totalUnits(r.units), 100, "stays at the cap")
	eq(r.units[1], 0, "the arriving unit paired with the lone tier 1")
	eq(r.units[2], 1, "tier 2 made")
	eq(r.units[3], 2, "higher pair left alone")
	eq(#r.steps, 1, "one merge step")
	eq(r.steps[1].tier, 1, "merged tier 1")
	eq(r.steps[1].made, 1, "one merge")

	-- A higher arrival merges the lowest pair below it.
	r = Economy.addUnitsCapped(full, 10, 1)
	eq(r.units[3], 0, "tier 3 pair merged")
	eq(r.units[4], 1, "into tier 4")
	eq(r.units[10], 1, "arrival kept")

	-- Nothing can merge (top tier only): the rest is refused.
	local stuck = table.create(25, 0)
	stuck[25] = 99
	r = Economy.addUnitsCapped(stuck, 1, 3)
	-- The first fits, the second pairs with it (-> tier 2), the third finds no pair.
	eq(r.accepted, 2, "accepted until nothing can merge")
	eq(r.units[2], 1, "the pair merged")
	eq(Economy.totalUnits(r.units), 100, "never past the cap")
	stuck[25] = 100
	r = Economy.addUnitsCapped(stuck, 25, 5)
	eq(r.accepted, 0, "top tier at the cap refuses everything")

	-- Old saves above the cap merge down on load (amount 0).
	local old = table.create(25, 0)
	old[1] = 250
	r = Economy.addUnitsCapped(old, 1, 0)
	eq(Economy.totalUnits(r.units), 100, "old save merged down to the cap")
	near(unitsValue(r.units), unitsValue(old), "old save keeps its value")
	r = Economy.addUnitsCapped(stuck, 1, 0)
	eq(#r.steps, 0, "nothing to merge in a full top-tier save")

	-- Buy 100 into a full rack of tier 1s: each arrival merges the lowest pair.
	local ones = table.create(25, 0)
	ones[1] = 100
	r = Economy.addUnitsCapped(ones, 1, 100)
	eq(r.accepted, 100, "buy 100 at the cap")
	eq(Economy.totalUnits(r.units), 100, "still at the cap")
	local merged = 0
	for _, step in r.steps do
		merged += step.made
	end
	eq(merged, 100, "one merge per arrival")

	-- Property test: random collections and batches.
	local rng = seeded(4242)
	local function int(lo: number, hi: number): number
		return lo + math.floor(rng() * (hi - lo + 1))
	end
	local bad = { cap = 0, value = 0, steps = 0, refused = 0, accepted = 0 }
	for _ = 1, 400 do
		local start = table.create(25, 0)
		local fill = int(0, 100)
		local topBias = rng() < 0.3
		for _ = 1, fill do
			local tier = if topBias and rng() < 0.7 then 25 else int(1, 25)
			start[tier] += 1
		end
		local tier = int(1, 25)
		local amount = int(0, 120)
		local res = Economy.addUnitsCapped(start, tier, amount)
		if Economy.totalUnits(res.units) > Economy.UNIT_CAP then
			bad.cap += 1
		end
		if res.accepted < 0 or res.accepted > amount then
			bad.accepted += 1
		end
		if math.abs(unitsValue(res.units) - (unitsValue(start) + res.accepted * Economy.unitValue(tier))) > 1e-6 then
			bad.value += 1
		end
		-- Replaying the steps on start + accepted gives the result.
		local replay = table.clone(start)
		replay[tier] += res.accepted
		for _, step in res.steps do
			replay[step.tier] -= Economy.MERGE_RATIO * step.made
			replay[step.tier + 1] += step.made
			if step.tier >= Economy.MAX_TIER or step.made < 1 then
				bad.steps += 1
			end
		end
		for t = 1, 25 do
			if replay[t] ~= res.units[t] or res.units[t] < 0 then
				bad.steps += 1
			end
		end
		-- A refusal only happens at the cap with nothing left to merge.
		if res.accepted < amount then
			local pair = false
			for t = 1, Economy.MAX_TIER - 1 do
				pair = pair or res.units[t] >= Economy.MERGE_RATIO
			end
			if pair or Economy.totalUnits(res.units) ~= Economy.UNIT_CAP then
				bad.refused += 1
			end
		end
	end
	for key, count in bad do
		eq(count, 0, "property violations: " .. key)
	end
end)

test("highestTier", function()
	local d = table.create(25, 0)
	eq(Economy.highestTier(d), 1, "defaults to 1")
	d[7] = 123
	eq(Economy.highestTier(d), 7)
end)

test("buy pricing", function()
	for buyTier = 1, Economy.MAX_BUY_TIER do
		for _, start in { 0, 3, 77 } do
			for _, amount in Economy.BUY_AMOUNTS do
				local sum = 0
				for k = 0, amount - 1 do
					sum += Economy.unitPrice(buyTier, start + k)
				end
				near(Economy.bulkPrice(buyTier, start, amount), sum, string.format("bulk tier %d start %d x%d", buyTier, start, amount))
			end
		end
		check(Economy.buyTierUpgradeCost(buyTier) > 0, "upgrade cost positive")
		check(Economy.buyTierRequirement(buyTier) >= 1, "requirement")
		if buyTier > 1 then
			check(Economy.buyTierRequirement(buyTier) >= Economy.buyTierRequirement(buyTier - 1), "requirement grows")
			check(Economy.buyTierUpgradeCost(buyTier) > Economy.buyTierUpgradeCost(buyTier - 1), "upgrade cost grows")
		end
	end
	near(Economy.unitPrice(1, Economy.buyTierRequirement(1)), 2 * Economy.basePrice(1), "price doubles at requirement")
end)

test("processing", function()
	eq(Economy.processRate(0), Economy.PROCESS_BASE, "base rate")
	check(Economy.processRate(10) > Economy.processRate(9), "rate grows")
	local sum = 0
	for level = 5, 5 + 9 do
		sum += Economy.processUpgradeCost(level)
	end
	near(Economy.processBulkCost(5, 10), sum, "bulk process cost")
	eq(Economy.incomePerSecond(100, 40, 2), 80, "income bottlenecked by processing")
	eq(Economy.incomePerSecond(30, 40, 1), 30, "income bottlenecked by production")
end)

test("deposit multiplier", function()
	local rng = seeded(42)
	local seen = {}
	for _ = 1, 5000 do
		local m = Economy.rollDepositMultiplier(rng)
		check(m >= Economy.DEPOSIT_MIN and m <= Economy.DEPOSIT_MAX, "multiplier in range " .. m)
		seen[m] = true
	end
	check(seen[1.0] == true and seen[0.5] == true, "covers low and neutral values")
	eq(
		Economy.rollDepositMultiplier(function()
			return 0
		end),
		0.5,
		"roll 0 gives first entry"
	)
	eq(
		Economy.rollDepositMultiplier(function()
			return 0.999999
		end),
		3.0,
		"roll ~1 gives last entry"
	)
end)

test("surge", function()
	local active, left = Economy.surgeState(0)
	check(not active, "inactive at cycle start")
	eq(left, Economy.SURGE_CYCLE - Economy.SURGE_DURATION, "time until surge")
	active, left = Economy.surgeState(Economy.SURGE_CYCLE - 10)
	check(active, "active near end")
	eq(left, 10, "time left in surge")
end)

test("chests", function()
	for _, rarity in Economy.CHEST_RARITIES do
		check(Economy.isRarity(rarity), "rarity known")
		for _, highest in { 1, 2, 6, 24, 25 } do
			local odds = Economy.chestOdds(rarity, highest)
			local total = 0
			for _, entry in odds do
				total += entry.chance
				check(entry.tier >= 1 and entry.tier <= 25, "tier in range")
			end
			eq(total, 100, rarity .. " odds sum at highest " .. highest)
		end
		local rng = seeded(7)
		for _ = 1, 500 do
			-- Highest 10 anchors crates at tier 6.
			local tier = Economy.rollChest(rarity, 10, rng)
			check(tier >= 4 and tier <= 10, "roll near the crate anchor")
		end
		check(Economy.unlockSeconds(rarity, true) < Economy.unlockSeconds(rarity, false), "premium is faster")
	end
	check(not Economy.isRarity("Bogus"), "unknown rarity rejected")

	eq(Economy.unitValue(1), Economy.BUY_BASE_PRICE, "tier 1 unit value")
	eq(Economy.unitValue(3), Economy.BUY_BASE_PRICE * 4, "tier 3 unit value")
	for _, rarity in Economy.CHEST_RARITIES do
		for _, highest in { 1, 2, 6, 15, 25 } do
			check(Economy.chestExpectedValue(rarity, highest) > 0, rarity .. " worth something at " .. highest)
		end
	end
	-- Crates are anchored below the highest tier, further down the higher it is.
	eq(Economy.chestAnchor(1), 1)
	eq(Economy.chestAnchor(3), 2)
	eq(Economy.chestAnchor(10), 6)
	eq(Economy.chestAnchor(25), 13)
	for highest = 2, 25 do
		check(Economy.chestAnchor(highest) <= highest, "anchor at or below highest at " .. highest)
		check(Economy.chestAnchor(highest) >= Economy.chestAnchor(highest - 1), "anchor never drops at " .. highest)
	end
	-- Higher rarities feel better: Rare rarely gives its lowest tier, Epic and
	-- Legendary mostly give the anchor tier or above, at every stage.
	for highest = 1, 25 do
		local anchor = math.max(Economy.chestAnchor(highest), 2)
		local rare = Economy.chestOdds("Rare", highest)
		check(#rare >= 2, "rare offers a choice at " .. highest)
		check(rare[1].chance <= 25, "rare lowest tier at most 25% at " .. highest)
		check(rare[#rare].tier <= anchor + 1, "rare stays near the anchor at " .. highest)
		for _, entry in Economy.chestOdds("Common", highest) do
			check(entry.tier <= highest, "common never above highest at " .. highest)
		end
		for _, rarity in { "Epic", "Legendary" } do
			local above = 0
			for _, entry in Economy.chestOdds(rarity, highest) do
				check(entry.tier >= anchor, rarity .. " never below the anchor at " .. highest)
				check(entry.tier <= math.max(highest, 2) + 3, rarity .. " not absurdly high at " .. highest)
				if entry.tier > anchor then
					above += entry.chance
				end
			end
			check(above >= 70, rarity .. " mostly above the anchor at " .. highest)
		end
		local prevValue = 0
		for _, rarity in Economy.CHEST_RARITIES do
			local value = Economy.chestExpectedValue(rarity, highest)
			check(value >= prevValue, rarity .. " worth at least the rarity below at " .. highest)
			prevValue = value
		end
	end
	-- Early game stays fair: a common crate is a tier 1, a rare one at most tier 3.
	local early = Economy.chestOdds("Common", 1)
	eq(#early, 1)
	eq(early[1].tier, 1)
	eq(early[1].chance, 100)
	local earlyRare = Economy.chestOdds("Rare", 1)
	eq(earlyRare[1].tier, 1)
	eq(earlyRare[#earlyRare].tier, 3)

	local common = Economy.chestOdds("Common", 6)
	eq(common[1].tier, 2)
	eq(common[1].chance, 75)
	eq(common[3].tier, 4)
	eq(common[3].chance, 5)

	local rng = seeded(99)
	local counts = {}
	for _ = 1, 20000 do
		local r = Economy.rollChestRarity(rng)
		counts[r] = (counts[r] or 0) + 1
	end
	check((counts.Common or 0) > (counts.Uncommon or 0), "common most frequent")
	check((counts.Legendary or 0) < (counts.Epic or 0), "legendary rarest")
	eq(Economy.finishGemCost(1), 1)
	eq(Economy.finishGemCost(61), 2)
end)

-- Crates are picked up by walking to them (no prompt): in range, landed, not already
-- holding one, and re-armed after a release (REARM seconds, and crates that were in range
-- at the release wait until the player has left their range).
test("crate auto pickup", function()
	local r = CratePickup.RADIUS
	check(r >= 4 and r <= 5, "pickup radius about 4.5 studs")
	check(CratePickup.inRange(r - 0.1, 0, 0), "in range just inside")
	check(not CratePickup.inRange(r * 0.8, 0, r * 0.8), "out of range diagonally")
	check(CratePickup.inRange(0, 5, 1), "jumping still in range")
	check(not CratePickup.inRange(0, CratePickup.REACH_Y + 1, 0), "far above is out of range")
	local function may(over: { [string]: any }): boolean
		local c = { now = 10, landsAt = 5, inRange = true, holding = false, rearmUntil = 0, blocked = false }
		for k, v in over do
			(c :: any)[k] = v
		end
		return CratePickup.mayPick(c :: any)
	end
	check(may({}), "landed crate in range is picked up")
	check(not may({ inRange = false }), "out of range")
	check(not may({ landsAt = 10.5 }), "still in the air")
	check(not may({ holding = true }), "already holding a crate")
	check(not may({ rearmUntil = 10 + CratePickup.REARM * 0.5 }), "re-arm wait after a release")
	check(may({ rearmUntil = 9.9 }), "re-armed after the wait")
	check(not may({ blocked = true }), "in range at the release: blocked")
	-- Blocked crates unblock only once the player leaves their range.
	local blocked = true
	blocked = CratePickup.stillBlocked(blocked, true)
	check(blocked, "standing still keeps the block")
	blocked = CratePickup.stillBlocked(blocked, false)
	check(not blocked, "leaving the range clears the block")
	blocked = CratePickup.stillBlocked(blocked, true)
	check(not blocked and may({ blocked = blocked }), "walking back in picks it up")
	check(CratePickup.REARM >= 1 and CratePickup.REARM <= 2, "re-arm about 1.5 s")
	-- Landing time: longer routes take longer, always past the fixed arrival legs, capped.
	check(CratePickup.landTime(0) >= 2.5, "short route still waits for the hops and bounces")
	check(CratePickup.landTime(60) > CratePickup.landTime(20), "longer route lands later")
	check(CratePickup.landTime(1e6) <= 10, "landing time capped")
	-- The prompt is gone: the server never builds one.
	check(not string.find(fs.readFile("src/server/Tycoon.luau"), "ProximityPrompt", 1, true), "no crate ProximityPrompt")
end)

test("tier bands", function()
	eq(Economy.tierBand(1), "Common")
	eq(Economy.tierBand(6), "Uncommon")
	eq(Economy.tierBand(15), "Rare")
	eq(Economy.tierBand(20), "Epic")
	eq(Economy.tierBand(24), "Legendary")
	eq(Economy.tierBand(25), "Mythic")
end)

test("packs scale with progression", function()
	local fresh = Economy.progression(1, 0)
	eq(Economy.moneyPackAmount(10, 300, 1000, fresh), 3000)
	eq(Economy.moneyPackAmount(0, 300, 1000, fresh), 1000)
	-- Aura packs: seconds of production, never below the tier-1 unit floor or the minimum.
	eq(Economy.auraPackAmount(0, 900, 3000, fresh), 3000)
	eq(Economy.auraPackAmount(100, 900, 3000, fresh), 90000)
	check(Economy.auraPackAmount(0, 86400, 0, fresh) >= math.floor(Economy.unitRate(1) * 86400), "aura pack tier floor")
	-- Durable measure: clamped tier, never-negative converter level.
	eq(Economy.progression(99, -3).tier, Economy.MAX_TIER)
	eq(Economy.progression(0, -3).processLevel, 0)
	local seconds = { 300, 900, 3600, 18000, 86400 }
	local bases, prices = { 50, 300, 800 }, { 49, 249, 599 }
	local lastFloor = 0
	local lastGems = { 0, 0, 0 }
	for tier = 1, Economy.MAX_TIER do
		local prog = Economy.progression(tier, 120)
		local floor = Economy.progressionIncome(prog)
		check(floor >= lastFloor, "cash floor non-decreasing at tier " .. tier)
		-- Never above one top-tier unit through the player's own converter.
		check(floor <= Economy.unitRate(tier) and floor <= Economy.processRate(120), "floor conservative " .. tier)
		lastFloor = floor
		for _, s in seconds do
			for _, income in { 0, floor / 2, floor * 3 } do
				local amount = Economy.moneyPackAmount(income, s, 1000, prog)
				check(amount >= 1000 and amount >= math.floor(floor * s), "cash pack floor " .. tier)
				check(amount >= math.floor(income * s), "cash pack follows live income " .. tier)
			end
		end
		local lastAura = 0
		for _, s in seconds do
			local unitFloor = Economy.unitRate(tier)
			for _, production in { 0, unitFloor / 2, unitFloor * 3 } do
				local aura = Economy.auraPackAmount(production, s, 3000, prog)
				check(aura >= 3000 and aura >= math.floor(unitFloor * s), "aura pack floor " .. tier)
				check(aura >= math.floor(production * s), "aura pack follows live production " .. tier)
			end
			local aura = Economy.auraPackAmount(0, s, 3000, prog)
			check(aura >= lastAura, "aura pack monotonic in seconds at tier " .. tier)
			lastAura = aura
			if tier > 1 then
				check(aura >= Economy.auraPackAmount(0, s, 3000, Economy.progression(tier - 1, 120)), "aura pack grows with tier " .. tier)
			end
		end
		local perRobux = 0
		for i, base in bases do
			local gems = Economy.gemPackAmount(base, prog)
			check(gems >= base and gems >= lastGems[i], "rizz pack " .. i .. " non-decreasing at tier " .. tier)
			check(gems < 500 and gems % 5 == 0 or gems % 50 == 0, "friendly rizz amount " .. gems)
			check(gems / prices[i] > perRobux, "bigger rizz pack is better value at tier " .. tier)
			perRobux = gems / prices[i]
			lastGems[i] = gems
			check(Economy.gemPackAmount(base + 50, prog) >= gems, "rizz monotonic in base")
		end
	end
	eq(Economy.gemPackAmount(800, Economy.progression(1, 0)), 800)
	local top = Economy.gemPackFactor(Economy.progression(Economy.MAX_TIER, 0))
	check(top >= 3 and top <= 6, "late-game rizz factor stays proportionate")
	-- The shop and the receipt handler size packs with the same shared functions.
	for _, path in { "src/server/Monetization.luau", "src/client/UI/Windows.luau" } do
		local src = fs.readFile(path)
		for _, fn in { "Economy.progression(", "Economy.moneyPackAmount(", "Economy.gemPackAmount(", "Economy.auraPackAmount(" } do
			check(string.find(src, fn, 1, true) ~= nil, path .. " uses " .. fn)
		end
		check(string.find(src, "pack.Amount", 1, true) == nil, path .. " has no fixed rizz amount")
	end
end)

test("session lock", function()
	local now = 1000000
	eq(SessionLock.decide(nil, "a", now, 0, 20), "acquire", "free save")
	eq(SessionLock.decide({ jobId = "a", at = now - 10 }, "a", now, 0, 20), "acquire", "our own lock")
	eq(SessionLock.decide({ jobId = "b", at = now - 10 }, "a", now, 0, 20), "wait", "live lock elsewhere")
	eq(SessionLock.decide({ jobId = "b", at = now - 10 }, "a", now, 25, 20), "steal", "waited long enough")
	eq(SessionLock.decide({ jobId = "b", at = now - SessionLock.STALE_SECONDS }, "a", now, 0, 20), "acquire", "stale lock")
	eq(SessionLock.decide({ jobId = 5 } :: any, "a", now, 0, 20), "acquire", "malformed lock")
	check(SessionLock.owns({ jobId = "a", at = now }, "a"), "owner")
	check(not SessionLock.owns({ jobId = "b", at = now }, "a"), "not owner")
	check(not SessionLock.owns(nil, "a"), "no lock")
end)

-- Tutorial ------------------------------------------------------------------------

test("tutorial step progression", function()
	eq(TutorialSteps.COUNT, 5, "five steps")
	eq(TutorialSteps.DONE, 6, "done marker")
	-- Only the current step's event advances, strictly in order.
	local step = 1
	for _, event in { "Pickup", "Deposit", "Cash", "Merge" } do
		eq(TutorialSteps.onEvent(step, event), 1, "out-of-order " .. event .. " ignored")
	end
	local order = { "Buy", "Pickup", "Deposit", "Cash", "Merge" }
	for index, event in order do
		eq(TutorialSteps.onEvent(step, "Nope"), step, "unknown event ignored")
		step = TutorialSteps.onEvent(step, event)
		eq(step, index + 1, "advanced by " .. event)
	end
	eq(step, TutorialSteps.DONE, "finished")
	eq(TutorialSteps.onEvent(step, "Buy"), TutorialSteps.DONE, "finished stays finished")
	for index, entry in TutorialSteps.STEPS do
		eq(entry.event, order[index], "step " .. index .. " event")
	end
end)

test("tutorial clamp", function()
	eq(TutorialSteps.clamp(nil), 1, "nil")
	eq(TutorialSteps.clamp("3"), 1, "string")
	eq(TutorialSteps.clamp(0 / 0), 1, "nan")
	eq(TutorialSteps.clamp(-4), 1, "negative")
	eq(TutorialSteps.clamp(3.7), 3, "floored")
	eq(TutorialSteps.clamp(99), TutorialSteps.DONE, "capped")
end)

test("tutorial state safety net", function()
	local discovered = table.create(Economy.MAX_TIER, 0)
	discovered[1] = 1
	local fresh = { carried = 0, units = { 1 }, discovered = discovered }
	check(not TutorialSteps.satisfied(1, fresh), "buy needs the event")
	check(not TutorialSteps.satisfied(2, fresh), "empty tank")
	eq(TutorialSteps.catchUp(2, fresh), 2, "nothing to catch up")

	local carrying = { carried = 4, units = { 2 }, discovered = discovered }
	check(TutorialSteps.satisfied(2, carrying), "orbs in tank")
	eq(TutorialSteps.catchUp(2, carrying), 3, "orbs step skipped, deposit still needed")
	eq(TutorialSteps.catchUp(1, carrying), 1, "earlier steps never skip")

	local merged = table.clone(discovered)
	merged[2] = 1
	check(TutorialSteps.satisfied(5, { discovered = merged }), "tier 2 discovered = merged")
	check(not TutorialSteps.satisfied(5, { discovered = discovered }), "only tier 1")
	eq(TutorialSteps.catchUp(5, { discovered = merged }), TutorialSteps.DONE, "merge completes the tutorial")
	check(not TutorialSteps.satisfied(TutorialSteps.DONE, carrying), "done has no condition")
end)

test("tutorial guide targets", function()
	eq(TutorialSteps.target(1, { 1 }), "Buy1")
	eq(TutorialSteps.target(2, { 1 }), "Orbs")
	eq(TutorialSteps.target(3, { 1 }), "Deposit")
	eq(TutorialSteps.target(4, { 1 }), "Collect")
	eq(TutorialSteps.target(5, { 1, 1 }), "Buy1", "no pair yet: buy one more")
	eq(TutorialSteps.target(5, { 2 }), "Merge", "pair owned: merge")
	eq(TutorialSteps.target(5, { 0, 3 }), "Merge", "pair of a higher tier")
	eq(TutorialSteps.target(TutorialSteps.DONE, { 2 }), nil, "finished")
	check(TutorialSteps.hasPair({ 1, 0, 2 }), "hasPair")
	check(not TutorialSteps.hasPair(nil), "hasPair nil")
end)

-- Themes --------------------------------------------------------------------------
-- Theme modules use Roblox datatypes, so load them in a sandbox with stubs.

local function stubEnum(): any
	return setmetatable({}, {
		__index = function(_, enumName)
			return setmetatable({}, {
				__index = function(_, item)
					return { EnumType = enumName, Name = item }
				end,
			})
		end,
	})
end

local function loadTheme(path: string): any
	local source = fs.readFile(path)
	local env = setmetatable({
		Color3 = {
			fromRGB = function(r, g, b)
				assert(r >= 0 and r <= 255 and g >= 0 and g <= 255 and b >= 0 and b <= 255, "colour out of range")
				return { kind = "Color3", r = r, g = g, b = b }
			end,
		},
		Enum = stubEnum(),
	}, { __index = _G })
	local fn = luau.load(source, { debugName = path, environment = env })
	return fn()
end

local REQUIRED_WORDS = {
	"Unit",
	"Units",
	"Orb",
	"Gem",
	"Chest",
	"Deposit",
	"Process",
	"Collect",
	"Merge",
	"Unlocker",
	"PremiumUnlocker",
	"Free",
	"Surge",
	"Multiplier",
	"BuyTier",
}
local REQUIRED_COLORS = {
	"Primary",
	"Secondary",
	"Good",
	"Bad",
	"Text",
	"PanelDark",
	"Stroke",
	"Orb",
	"OrbBig",
	"Floor",
	"Neon",
	"NeonAlt",
	"PadDisabled",
}
-- Unit models and animation ----------------------------------------------------------
-- CharacterFactory / Poses / RigPose need real Roblox datatypes: load them with
-- @lune/roblox and a tiny require shim for `require(script.Parent.X)`.

local ROBLOX_ENV = {
	Instance = roblox.Instance,
	Vector3 = roblox.Vector3,
	Vector2 = roblox.Vector2,
	CFrame = roblox.CFrame,
	Color3 = roblox.Color3,
	Enum = roblox.Enum,
	ColorSequence = roblox.ColorSequence,
	NumberSequence = roblox.NumberSequence,
	NumberSequenceKeypoint = roblox.NumberSequenceKeypoint,
	NumberRange = roblox.NumberRange,
}
local function robloxEnv(): { [string]: any }
	local env: { [string]: any } = setmetatable({}, { __index = _G }) :: any
	for key, value in ROBLOX_ENV do
		env[key] = value
	end
	return env
end
local sharedCache: { [string]: any } = {}
local function loadShared(name: string): any
	if sharedCache[name] == nil then
		local env = robloxEnv()
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
local function loadRobloxTheme(path: string): any
	return luau.load(fs.readFile(path), { debugName = path, environment = robloxEnv() })()
end

local CharacterFactory = loadShared("CharacterFactory")
local Poses = loadShared("Poses")
local RigPose = loadShared("RigPose")
local CFrame = roblox.CFrame
local Vector3 = roblox.Vector3

local KNOWN = {
	anim = { Chad = true, Bot = true },
	expr = { Neutral = true, Smirk = true, Smug = true, Determined = true, Angry = true, Happy = true, Stoic = true },
	hairStyle = { Buzz = true, Flat = true, Slick = true, Quiff = true, Spiky = true, Bun = true, Bald = true },
	beard = { Stubble = true, Beard = true },
	top = { Tee = true, Tank = true, Shirtless = true, Jacket = true, Hoodie = true },
	bottoms = { Pants = true, Joggers = true, Shorts = true },
	eyes = { Dots = true, Visor = true, Mono = true, Angry = true, Happy = true, Bars = true },
	mouth = { Grille = true, Bar = true, None = true },
}
local MAX_PARTS = 60

local function isFinite(n: number): boolean
	return n == n and n ~= math.huge and n ~= -math.huge
end
local function cframeFinite(cf: any): boolean
	for _, v in { cf:GetComponents() } do
		if not isFinite(v) then
			return false
		end
	end
	return true
end
local function cframeNear(a: any, b: any, tolerance: number): boolean
	local ca, cb = { a:GetComponents() }, { b:GetComponents() }
	for i = 1, 12 do
		if math.abs(ca[i] - cb[i]) > tolerance then
			return false
		end
	end
	return true
end

for _, variant in { "chad" } do
	test("theme " .. variant, function()
		local theme = loadTheme("src/themes/" .. variant .. "/Theme.luau")
		eq(theme.Id, variant, "id")
		eq(#theme.Tiers, Economy.MAX_TIER, "tier count")
		check(KNOWN.anim[theme.AnimSet] == true, "theme AnimSet")
		local names = {}
		for tier, entry in theme.Tiers do
			check(type(entry.Name) == "string" and #entry.Name > 0, "tier " .. tier .. " has a name")
			check(not names[entry.Name], "tier name unique: " .. tostring(entry.Name))
			names[entry.Name] = true
			local look = entry.Look
			check(look and look.skin and look.shirt and look.pants, "tier " .. tier .. " has colours")
			for _, acc in look.acc or {} do
				check(CharacterFactory.ACCESSORIES[acc] ~= nil, "known accessory " .. acc)
			end
			for field, allowed in KNOWN do
				if look[field] ~= nil then
					check(allowed[look[field]] == true, string.format("tier %d: known %s %s", tier, field, tostring(look[field])))
				end
			end
			if look.scale then
				check(look.scale >= 1 and look.scale <= 2, "sane scale")
			end
		end
		for _, word in REQUIRED_WORDS do
			check(type(theme.Words[word]) == "string", "word " .. word)
		end
		for _, color in REQUIRED_COLORS do
			check(theme.Colors[color] ~= nil, "colour " .. color)
		end
		for _, rarity in Economy.CHEST_RARITIES do
			check(theme.Colors.Rarity[rarity] ~= nil, "rarity colour " .. rarity)
		end
		check(theme.Colors.Rarity.Mythic ~= nil, "mythic colour")
		for _, name in theme.Monetization.PassOrder do
			local pass = theme.Monetization.Passes[name]
			check(pass ~= nil and type(pass.Id) == "number" and pass.Price > 0, "pass " .. name)
		end
		for _, required in { "AutoLoot", "AutoCash", "DoubleAura", "DoubleMoney", "PremiumUnlocker" } do
			check(theme.Monetization.Passes[required] ~= nil, "pass defined " .. required)
		end
		eq(#theme.Monetization.MoneyPacks, 4, "money packs")
		eq(#theme.Monetization.GemPacks, 3, "gem packs")
		eq(#theme.Monetization.AuraPacks, 4, "aura packs")
		for _, list in { "MoneyPacks", "AuraPacks" } do
			local lastSeconds, lastMin = 0, 0
			for index, pack in theme.Monetization[list] do
				check(type(pack.Id) == "number" and pack.Price > 0, list .. " id and price " .. index)
				check(pack.Seconds > lastSeconds and pack.Min > lastMin, list .. " grow with price " .. index)
				lastSeconds, lastMin = pack.Seconds, pack.Min
			end
		end
		-- Every product id (live, retired and the crate) is unique, so a receipt maps to one grant.
		local seen = {}
		for _, list in { "MoneyPacks", "AuraPacks", "GemPacks", "LegacyMoneyPacks" } do
			for index, pack in theme.Monetization[list] do
				check(pack.Id ~= 0 and not seen[pack.Id], list .. " id unique " .. index)
				seen[pack.Id] = true
			end
		end
		check(not seen[theme.Monetization.CrateOpen.Id], "crate product id unique")
		check(type(theme.Modes.Reward.Seconds) == "number" and theme.Modes.Reward.Min > 0, "mode reward")
		for index, pack in theme.Monetization.GemPacks do
			check(type(pack.Base) == "number" and pack.Base > 0 and pack.Amount == nil, "rizz pack base " .. index)
		end
		eq(#theme.Tutorial.Steps, TutorialSteps.COUNT, "one tutorial text per step")
		for index, entry in theme.Tutorial.Steps do
			check(type(entry.Title) == "string" and #entry.Title > 0, "tutorial step " .. index .. " title")
			check(type(entry.Text) == "string" and #entry.Text > 0, "tutorial step " .. index .. " text")
			check(type(entry.Icon) == "string", "tutorial step " .. index .. " icon")
		end
		for _, key in { "Title", "DoneTitle", "DoneText", "Skip", "SkipConfirm", "Follow" } do
			check(type(theme.Tutorial[key]) == "string", "tutorial string " .. key)
		end
		check(type(theme.Loading.Status) == "string" and #theme.Loading.Tips > 0, "loading screen strings")
		check(theme.Decor == nil or theme.Decor == "gym", "decor style")
	end)

	-- Crate products: instant opening is ONE Robux developer product, the same price for
	-- every crate rarity, plus the Crate Master pass that opens every crate free;
	-- Rizz and cash cannot open crates any more.
	test("crate products " .. variant, function()
		local theme = loadTheme("src/themes/" .. variant .. "/Theme.luau")
		local monetization = theme.Monetization :: any
		check(monetization.CrateOpens == nil, "no per-rarity crate products")
		local product = monetization.CrateOpen
		check(type(product) == "table", "crate product defined")
		check(type(product.Id) == "number" and product.Id >= 0, "crate product id")
		check(type(product.Price) == "number" and product.Price > 0, "crate product price")
		local pass = monetization.Passes.CrateKey
		check(pass ~= nil, "Crate Master pass defined")
		check(type(pass.Id) == "number" and pass.Id >= 0, "Crate Master pass id")
		check(type(pass.Price) == "number" and pass.Price > 0, "Crate Master pass price")
		check(type(pass.Title) == "string" and type(pass.Desc) == "string", "Crate Master pass text")
		check(table.find(monetization.PassOrder, "CrateKey") ~= nil, "Crate Master pass in the shop")
		check((Economy :: any).chestMoneyPrice == nil, "no cash price for crates")
		for _, rarity in Economy.CHEST_RARITIES do
			check((Economy.CHEST_INFO[rarity] :: any).gemPrice == nil, rarity .. " has no Rizz price")
		end
	end)

	test("unit models " .. variant, function()
		local theme = loadRobloxTheme("src/themes/" .. variant .. "/Theme.luau")
		CharacterFactory.setDefaultAnim(theme.AnimSet)
		local limbSet = {}
		for _, limb in Poses.LIMBS do
			limbSet[limb] = true
		end
		local previousScale = 1
		for tier, entry in theme.Tiers do
			local model = CharacterFactory.build(entry.Look, entry.Name)
			local label = variant .. " tier " .. tier
			check(model:HasTag(Poses.TAG), label .. " tagged AnimatedUnit")
			eq(model:GetAttribute(Poses.SET_ATTRIBUTE), theme.AnimSet, label .. " AnimSet")
			local root = model.PrimaryPart
			check(root ~= nil and root.Name == "Root", label .. " Root primary part")
			check(root ~= nil and root.CFrame.Position.Magnitude < 1e-6, label .. " Root at the feet, at the origin")
			for _, limb in Poses.LIMBS do
				check(typeof(model:GetAttribute(Poses.PIVOT_PREFIX .. limb)) == "Vector3", label .. " pivot " .. limb)
			end
			local count, bad = 0, 0
			for _, d in model:GetDescendants() do
				if d:IsA("BasePart") then
					count += 1
					if not d.Anchored or d.CanCollide or d.CanTouch or d.CanQuery then
						bad += 1
					end
					if d ~= root and not limbSet[d:GetAttribute(Poses.LIMB_ATTRIBUTE)] then
						bad += 1
					end
				end
			end
			eq(bad, 0, label .. " parts anchored, non-colliding and on a limb")
			check(count <= MAX_PARTS, string.format("%s part budget (%d <= %d)", label, count, MAX_PARTS))
			local height = model:GetAttribute("Height")
			check(type(height) == "number" and height > 4, label .. " height")
			near(CharacterFactory.height(entry.Look), height, label .. " height() matches the model")
			local scale = entry.Look.scale or 1
			check(scale >= previousScale, label .. " is at least as big as the tier below")
			previousScale = scale

			-- Rest pose round trip: identity joint transforms leave every part in place.
			local rig = RigPose.capture(model, 1)
			check(rig ~= nil and #rig.parts == count - 1, label .. " rig captures every limb part")
			if rig then
				local identity = {}
				for _, limb in Poses.LIMBS do
					identity[limb] = CFrame.new()
				end
				local parts, cframes = RigPose.computeFrom(rig, identity)
				local moved = 0
				for i, part in parts do
					if not cframeNear(part.CFrame, cframes[i], 1e-3) then
						moved += 1
					end
				end
				eq(moved, 0, label .. " rest pose round trip")
				-- A real pose keeps every part finite and near the unit.
				RigPose.apply(rig, 12.3)
				local far = 0
				for _, part in parts do
					if not cframeFinite(part.CFrame) or part.CFrame.Position.Magnitude > 20 then
						far += 1
					end
				end
				eq(far, 0, label .. " posed parts stay finite and attached")
			end
			model:Destroy()
		end
	end)
end

test("silhouette", function()
	local theme = loadRobloxTheme("src/themes/chad/Theme.luau")
	CharacterFactory.setDefaultAnim(theme.AnimSet)
	local model = CharacterFactory.build(theme.Tiers[25].Look, "Top")
	CharacterFactory.silhouette(model)
	local coloured, effects = 0, 0
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") and d.Transparency < 1 then
			if d.Color ~= roblox.Color3.fromRGB(15, 15, 20) or d.Material ~= roblox.Enum.Material.SmoothPlastic then
				coloured += 1
			end
		elseif d:IsA("ParticleEmitter") or d:IsA("Sparkles") or d:IsA("Fire") or d:IsA("Light") then
			effects += 1
		end
	end
	eq(coloured, 0, "every visible part is black")
	eq(effects, 0, "effects removed")
end)

test("poses sample", function()
	for _, set in { "Chad", "Bot" } do
		local a = Poses.sample(set, 3.7, 42)
		local b = Poses.sample(set, 3.7, 42)
		local c = Poses.sample(set, 3.7, 4242)
		local differs = false
		for _, limb in Poses.LIMBS do
			check(a[limb] ~= nil, set .. " sample has " .. limb)
			check(cframeFinite(a[limb]), set .. " finite " .. limb)
			check(cframeNear(a[limb], b[limb], 0), set .. " deterministic " .. limb)
			if not cframeNear(a[limb], c[limb], 1e-4) then
				differs = true
			end
		end
		check(differs, set .. " different seeds are out of sync")
		-- Long sweep over many seeds: always finite, rotations stay orthonormal.
		local bad = 0
		for i = 0, 400 do
			local sample = Poses.sample(set, i * 0.173, i % 37)
			for _, limb in Poses.LIMBS do
				local cf = sample[limb]
				if not cframeFinite(cf) or math.abs(cf.LookVector.Magnitude - 1) > 1e-4 then
					bad += 1
				end
			end
		end
		eq(bad, 0, set .. " sweep finite")
		for _, name in Poses.poseNames(set) do
			local t = Poses.timeFor(set, 77, name)
			check(t ~= nil and t >= 0, set .. " timeFor " .. name)
			local pose = Poses.samplePose(set, name)
			check(pose.Head ~= nil and pose.RightHand ~= nil, set .. " samplePose " .. name)
		end
	end
	-- Unknown sets fall back to Chad instead of erroring.
	check(Poses.sample("Nope", 1, 1).Head ~= nil, "unknown set falls back")
end)

test("poses solve", function()
	local pivots = {}
	for i, limb in Poses.LIMBS do
		pivots[limb] = Vector3.new(i * 0.1, i * 0.2, -i * 0.05)
	end
	local identity = {}
	for _, limb in Poses.LIMBS do
		identity[limb] = CFrame.new()
	end
	local frames = Poses.solve(pivots, identity, 1)
	for _, limb in Poses.LIMBS do
		check(cframeNear(frames[limb], CFrame.new(pivots[limb]), 1e-5), "rest frame " .. limb)
	end
	-- Rotating the waist carries the head around the waist pivot.
	identity.UpperTorso = CFrame.Angles(0, 0, math.rad(90))
	frames = Poses.solve(pivots, identity, 1)
	local offset = pivots.Head - pivots.UpperTorso
	local expected = pivots.UpperTorso + Vector3.new(-offset.Y, offset.X, offset.Z)
	check((frames.Head.Position - expected).Magnitude < 1e-4, "child follows parent rotation")
	-- The hover offset scales with the rig.
	identity.UpperTorso = CFrame.new()
	identity.LowerTorso = CFrame.new(0, 0.5, 0)
	frames = Poses.solve(pivots, identity, 2)
	check((frames.LowerTorso.Position - (pivots.LowerTorso + Vector3.new(0, 1, 0))).Magnitude < 1e-5, "root offset scaled")
end)

-- Plot layout ----------------------------------------------------------------------

local Layout = require("../src/server/PlotLayout")

-- Everything solid on the floor that pads, crates and fans must stay clear of.
local function layoutObstacles(): { [string]: any }
	local out: { [string]: any } = {
		Pen = Layout.POOL,
		Gutter = Layout.GUTTER.rect,
		Chute = Layout.CHUTE.rect,
	}
	for i, stair in Layout.PEN_STAIRS do
		out["Stair" .. i] = stair.rect
	end
	for name, rect in Layout.MACHINES do
		out[name] = rect
	end
	return out
end

local function insidePlot(r: any): boolean
	local inner = Layout.INNER_HALF
	return r.minX >= -inner and r.maxX <= inner and r.minZ >= -inner and r.maxZ <= inner
end

test("plot layout: compact plot and pen", function()
	check(Layout.PLOT_HALF >= 38 and Layout.PLOT_HALF <= 42, "compact plot")
	check(Layout.INNER_HALF < Layout.PLOT_HALF, "fences inside the plot edge")
	local pen = Layout.PEN
	local inner = pen.interior
	local w, d = inner.maxX - inner.minX, inner.maxZ - inner.minZ
	check(w >= 18 and w <= 22 and d >= 14 and d <= 18, "pen interior about 20 x 16")
	check(pen.wallHeight >= 1.2 and pen.wallHeight <= 2, "knee-high walls")
	check(pen.postHeight > pen.wallHeight, "corner posts taller than the walls")
	near(Layout.POOL.minX, inner.minX - pen.wallThick, "pen footprint includes the walls")
	near(Layout.POOL.maxZ, inner.maxZ + pen.wallThick, "pen footprint includes the walls")
	check(math.abs(Layout.POOL.minX + Layout.POOL.maxX) < 1e-6, "pen centred on x = 0")
	check(Layout.POOL_FLOOR_Y >= 0 and Layout.POOL_FLOOR_Y < 0.5, "pen floor at ground level")
	check(insidePlot(Layout.POOL), "pen inside the plot")

	-- Orbs land inside the walls and off the inner stair steps.
	local o = Layout.ORB_AREA
	check(o.minX >= inner.minX and o.maxX <= inner.maxX and o.minZ >= inner.minZ and o.maxZ <= inner.maxZ, "orb area inside the pen")
	check(o.maxX - o.minX > 12 and o.maxZ - o.minZ > 10, "orb area is roomy")
	check(Layout.inPool(0, Layout.POOL_CENTER_Z), "pen centre is in the pen")
	check(not Layout.inPool(0, Layout.POOL.minZ - 2), "floor in front of the pen is not")

	-- One stair on each side wall; each step rises by at most a knee-high step and the last
	-- outer step is level with the wall top.
	eq(#Layout.PEN_STAIRS, 2, "two stairs")
	local sides = {}
	for _, stair in Layout.PEN_STAIRS do
		sides[stair.side] = true
		local r = stair.rect
		if stair.side > 0 then
			near(r.minX, Layout.POOL.maxX, "+X stair meets the wall")
		else
			near(r.maxX, Layout.POOL.minX, "-X stair meets the wall")
		end
		check(r.maxZ - r.minZ >= 3, "stair wide enough")
		local last = 0
		for i = 1, 3 do
			local step = stair.steps[i]
			check(step.top > last and step.top - last <= 0.8, "outer steps climb gently")
			check(not Layout.overlaps(step.rect, Layout.POOL), "outer steps outside the pen")
			last = step.top
		end
		near(last, pen.wallHeight, "top step level with the wall")
		local innerStep = stair.steps[4]
		check(not Layout.overlaps(innerStep.rect, o), "orbs never land on an inner step")
		check(innerStep.top < pen.wallHeight, "inner step below the wall top")
		check(insidePlot(r), "stair inside the plot")
	end
	check(sides[1] and sides[-1], "stairs on both sides")
end)

test("plot layout: display rack, gutter and chute", function()
	local slots = Layout.shelfSlots()
	local s = Layout.SHELF
	eq(#slots, Economy.DISPLAY_SLOTS, "display slot count")
	eq(s.rows, Economy.DISPLAY_ROWS, "rack rows")
	check(slots[1].best and slots[1].x == 0 and slots[1].row == 1, "slot 1 is the front-centre champion")
	local cols = 0
	for row = 1, s.rows do
		cols += s.rowCols[row]
		check(math.abs(s.rowCols[row] - Economy.DISPLAY_COLS) <= 1, "about 10 units per shelf")
	end
	eq(cols, Economy.DISPLAY_SLOTS, "shelves hold every slot")
	-- Units are at most ~4.8 studs wide once display-scaled (arms out).
	check(s.spacing >= 5.2, "units do not overlap badly")

	-- Bottom shelf first, each shelf centre-out, rows only rising.
	local lastRow, lastDist = 1, -1
	for i, slot in slots do
		check(slot.row >= lastRow, "slot " .. i .. " fills bottom-up")
		if slot.row ~= lastRow then
			lastRow, lastDist = slot.row, -1
		end
		check(math.abs(slot.x) >= lastDist - 1e-6, "slot " .. i .. " fills centre-out")
		lastDist = math.abs(slot.x)
		check(slot.best == (i == 1), "only slot 1 is the champion")
	end

	-- Every shelf model fits under the shelf above (champion included).
	near(s.rowRise, s.standY + s.unitMaxHeight + s.headroom + s.boardThick, "rise fits a display-scaled unit")
	for _, slot in slots do
		local head = slot.y + s.unitMaxHeight
		check(head <= Layout.rowTop(slot.row + 1) - s.boardThick - s.headroom + 1e-6, "unit fits under the next shelf")
		near(slot.z, Layout.rowFrontZ(slot.row) + s.depth / 2, "unit centred on its shelf")
	end
	check(Layout.displayScale(4) == 1, "small units keep their size")
	near(Layout.displayScale(8.44) * 8.44, s.unitMaxHeight, "tall units scale to the cap")
	check(Layout.rowFrontZ(2) - Layout.rowFrontZ(1) > 0 and s.stepBack <= 1.5, "each shelf steps back a little")

	-- Rows exist only as far as needed.
	eq(Layout.rackRows(0), 1, "an empty rack shows one shelf")
	eq(Layout.rackRows(1), 1, "1 unit: one shelf")
	eq(Layout.rackRows(10), 1, "10 units: one shelf")
	eq(Layout.rackRows(20), 2, "20 units: two shelves")
	eq(Layout.rackRows(21), 3, "21 units: three shelves")
	eq(Layout.rackRows(100), 10, "100 units: ten shelves")
	eq(Layout.rackRows(1000), 10, "never more than ten")
	for i, slot in slots do
		check(Layout.rackRows(i) >= slot.row, "slot " .. i .. " is on a shown shelf")
	end

	-- The whole rack (posts and back panels included) stays in the ledge footprint.
	local shelves = Layout.MACHINES.Shelves
	check(insidePlot(shelves), "rack inside the plot")
	near(shelves.maxX, s.width / 2 + s.postWidth, "posts inside the footprint")
	near(shelves.minZ, s.frontZ, "rack front at the footprint front")
	check(Layout.rowFrontZ(s.rows) + s.depth + 0.4 + 0.6 <= shelves.maxZ, "top shelf, back panel and roof inside")
	for _, slot in slots do
		check(math.abs(slot.x) + 2.4 <= s.width / 2, "slot between the posts")
		check(slot.z > shelves.minZ and slot.z < shelves.maxZ, "slot over the ledge")
	end

	local g = Layout.GUTTER
	near(g.rect.maxZ, shelves.minZ, "gutter at the foot of the ledge")
	check(g.rect.minZ > Layout.POOL.maxZ, "gutter behind the pen")
	check(g.endY > g.centerY, "gutter drains to the centre")
	check(g.endY + g.lipHeight < s.firstTop, "ledge stands above the gutter lip")
	near(Layout.gutterY(0), g.centerY, "gutter centre height")
	near(Layout.gutterY(g.rect.maxX), g.endY, "gutter end height")
	near(Layout.gutterY(-1000), g.endY, "gutter height clamps")

	local ch = Layout.CHUTE
	check(ch.topY > ch.bottomY, "chute runs downhill")
	near(ch.topY, g.centerY, "chute starts at the gutter centre")
	check(ch.bottomZ < Layout.PEN.interior.maxZ, "chute ends inside the pen")
	-- Where it crosses the back wall the chute bed clears the wall top.
	local wallZ = Layout.POOL.maxZ
	local yAtWall = ch.bottomY + (ch.topY - ch.bottomY) * (wallZ - ch.bottomZ) / (ch.topZ - ch.bottomZ)
	check(yAtWall > Layout.PEN.wallHeight, "chute clears the back wall")
end)

test("plot layout: orb path", function()
	local slots = Layout.shelfSlots()
	local r = Layout.ORB_RADIUS
	local o = Layout.ORB_AREA
	local s = Layout.SHELF
	-- Is a point (centre of a ball of radius r) inside any shelf board or a shelf's unit space?
	local function hitsRack(p: any, fromRow: number): boolean
		for row = 1, s.rows do
			local front = Layout.rowFrontZ(row)
			local top = Layout.rowTop(row)
			local inZ = p.z + r > front - s.frontReach and p.z - r < front + s.depth
			-- The board, and (for shelves other than the start) the space its units stand in.
			local ceiling = if row == fromRow then top else Layout.rowTop(row + 1) - s.boardThick
			if inZ and p.y - r < ceiling - 1e-6 and p.y + r > top - s.boardThick then
				return true
			end
		end
		return false
	end
	for _, slot in slots do
		local toX, toZ = (o.minX + o.maxX) / 2 + 1, (o.minZ + o.maxZ) / 2
		local path = Layout.orbPath(slot.x, slot.z, toX, toZ)
		eq(#path, 6, "six waypoints")
		near(path[1].x, slot.x, "starts at the unit")
		near(path[1].y, slot.y + r, "starts at the unit's feet")
		near(path[1].z, slot.z, "starts at the unit")
		near(path[2].y, path[1].y, "moves out at its own shelf's height")
		check(path[2].z + r <= s.frontZ - s.frontReach + 1e-6, "drop point in front of the rack")
		near(path[3].z, Layout.GUTTER.z, "drops into the gutter")
		near(path[3].y, Layout.gutterY(path[3].x) + r, "rolls on the gutter bed")
		near(path[4].x, Layout.CHUTE.x, "gutter drains to the chute")
		near(path[4].y, Layout.CHUTE.topY + r, "chute top")
		near(path[5].z, Layout.CHUTE.bottomZ, "chute bottom")
		near(path[6].x, toX, "lands on target")
		near(path[6].z, toZ, "lands on target")
		near(path[6].y, Layout.POOL_FLOOR_Y + r, "rests on the pen floor")
		-- Downhill all the way (the feet are above the gutter).
		for i = 2, 6 do
			check(path[i].y <= path[i - 1].y + 1e-6, "orb path runs downhill")
		end
		check(Layout.contains(Layout.PEN.interior, path[5].x, path[5].z), "chute bottom inside the pen")
		-- The legs off the rack never pass through a shelf or the units below.
		local clear = true
		for leg = 1, 2 do
			local a, b = path[leg], path[leg + 1]
			for k = 1, 20 do
				local t = k / 20
				local p = { x = a.x + (b.x - a.x) * t, y = a.y + (b.y - a.y) * t, z = a.z + (b.z - a.z) * t }
				if hitsRack(p, slot.row) then
					clear = false
				end
			end
		end
		check(clear, "slot " .. slot.row .. "/" .. slot.x .. " orb clears the rack")
	end
	-- A unit past the gutter's end still drops into the gutter; toY overrides the landing height.
	local far = Layout.orbPath(100, Layout.SHELF.firstZ, 0, 10, 3)
	check(far[3].x <= Layout.GUTTER.rect.maxX, "gutter point clamped")
	near(far[6].y, 3, "landing height override")
end)

test("orb roll animation: route roles and rack clearance", function()
	-- Fx.Orbs' route maths is pure: load that section with Roblox datatypes.
	local src = fs.readFile("src/client/Fx/Orbs.luau")
	local i = assert(string.find(src, "-- Rolling trips ---", 1, true))
	local j = assert(string.find(src, "-- End of the route maths", i, true))
	local env = robloxEnv()
	env.typeof = roblox.typeof or typeof
	local O = luau.load(
		"local function bezier(a, b, c, t) local u = 1 - t return a * (u * u) + b * (2 * u * t) + c * (t * t) end\n"
			.. string.sub(src, i, j - 1)
			.. "\nreturn { newRoll = newRoll, sampleRoll = sampleRoll, readRoute = readRoute }",
		{ debugName = "Orbs route maths", environment = env }
	)()
	local s, r = Layout.SHELF, Layout.ORB_RADIUS
	local function holder(path: { any }, kinds: string?): any
		local attrs: { [string]: any } = { PathCount = #path, PathKinds = kinds }
		for n, p in path do
			attrs["Path" .. n] = Vector3.new(p.x, p.y, p.z)
		end
		return {
			GetAttribute = function(_, key)
				return attrs[key]
			end,
		}
	end
	local sample = Layout.orbPath(5.3, s.firstZ, 0, 10)
	local labelled = O.readRoute(holder(sample, "feet,drop,gutter,chuteTop,chuteBottom,land"), "Path")
	local inferred = O.readRoute(holder(sample, nil), "Path")
	check(labelled.drop.Z == sample[2].z and labelled.gutter.Z == sample[3].z, "kinds name the waypoints")
	check(inferred.drop == labelled.drop and inferred.land == labelled.land, "roles inferred without kinds")
	local legacy = O.readRoute(holder({ sample[1], sample[3], sample[4], sample[5], sample[6] }, nil), "Path")
	check(legacy.drop == legacy.gutter, "a 5-point route has no drop point")
	check(O.readRoute(holder({ sample[1] }, nil), "Path") == nil, "too short a route is ignored")

	-- From every slot, until the orb reaches the gutter: it stays above its own shelf's deck
	-- (clear of the shelves below) unless it is in front of the whole rack, and under the
	-- shelf above while it is beneath it. The trip stays short from the top shelf.
	local frontMost = s.frontZ - s.frontReach
	local clear, slowest = true, 0
	for _, slot in Layout.shelfSlots() do
		local roll = O.newRoll(
			O.readRoute(holder(Layout.orbPath(slot.x, slot.z, 0, 10), nil), "Path"),
			Vector3.new(slot.x, slot.y + 4, slot.z),
			nil,
			r,
			0
		)
		slowest = math.max(slowest, roll.total)
		local t = 0
		while true do
			local p, phase = O.sampleRoll(roll, t)
			if phase >= 3 then
				break
			end
			local deck = Layout.rowTop(slot.row)
			if p.Z + r > frontMost and p.Y - r < deck - 1e-3 then
				clear = false
			end
			if
				slot.row < s.rows
				and p.Z - r < Layout.rowFrontZ(slot.row + 1) + s.depth
				and p.Z + r > Layout.rowFrontZ(slot.row + 1) - s.frontReach
			then
				if p.Y + r > Layout.rowTop(slot.row + 1) - s.boardThick then
					clear = false
				end
			end
			t += 1 / 120
		end
	end
	check(clear, "orbs never pass through the rack on the way to the gutter")
	check(slowest < 5, "orb trip from any shelf under 5 s (" .. slowest .. ")")
end)

test("plot layout: pads", function()
	local names = {}
	for _, name in Layout.PAD_ORDER do
		names[name] = true
		check(Layout.PADS[name] ~= nil, "pad has a spot: " .. name)
	end
	for name in Layout.PADS do
		check(names[name] == true, "pad is built: " .. name)
	end
	for _, amount in Economy.BUY_AMOUNTS do
		check(Layout.PADS["Buy" .. amount] ~= nil, "buy pad " .. amount)
	end
	for _, name in { "AutoMerge", "Merge", "Deposit", "ProcUp1", "ProcUp10", "Collect", "BuyTier", "Unlock1", "Unlock2", "Free" } do
		check(Layout.PADS[name] ~= nil, "pad " .. name)
	end

	-- Buy 1, Buy 5, [pen], Buy 25, Buy 100 from the player's left (+X) at the pen's depth.
	local P = Layout.PADS
	check(P.Buy1.x > P.Buy5.x and P.Buy5.x > Layout.POOL.maxX, "Buy1 and Buy5 on the +X side")
	check(P.Buy100.x < P.Buy25.x and P.Buy25.x < Layout.POOL.minX, "Buy25 and Buy100 on the -X side")
	for _, amount in Economy.BUY_AMOUNTS do
		local spot = P["Buy" .. amount]
		check(spot.z > Layout.POOL.minZ and spot.z < Layout.POOL.maxZ, "buy pad at the pen's depth")
	end
	check(P.Merge.x == 0 and P.Merge.z < Layout.POOL.minZ, "merge pad centred in front of the pen")
	check(P.AutoMerge.x < P.Buy100.x and P.AutoMerge.z == P.Buy100.z, "auto merge ends the buy row")
	check(P.Deposit.sizeX * P.Deposit.sizeZ > 2 * P.Merge.sizeX * P.Merge.sizeZ, "deposit is the big pad")
	-- Small pads with open floor between them.
	local function gap(a: Layout.Rect, b: Layout.Rect): number
		local dx = math.max(0, a.minX - b.maxX, b.minX - a.maxX)
		local dz = math.max(0, a.minZ - b.maxZ, b.minZ - a.maxZ)
		return math.sqrt(dx * dx + dz * dz)
	end
	local penParts = { Layout.POOL }
	for _, stair in Layout.PEN_STAIRS do
		table.insert(penParts, stair.rect)
	end
	for i, nameA in Layout.PAD_ORDER do
		local spot = P[nameA]
		check(math.min(spot.sizeX, spot.sizeZ) >= 4, nameA .. " short side at least 4 studs")
		if nameA ~= "Deposit" then
			check(math.max(spot.sizeX, spot.sizeZ) <= 7, nameA .. " is a small pad")
		end
		local rim = Layout.padRect(spot, Layout.PAD_RIM)
		local need = if nameA == "Merge" then Layout.MERGE_PEN_GAP else Layout.PAD_PEN_GAP
		for _, part in penParts do
			check(gap(rim, part) >= need - 1e-6, nameA .. " has open floor around the pen")
		end
		for j = i + 1, #Layout.PAD_ORDER do
			local nameB = Layout.PAD_ORDER[j]
			local g = gap(rim, Layout.padRect(P[nameB], Layout.PAD_RIM))
			check(g >= Layout.PAD_GAP - 1e-6, nameA .. " and " .. nameB .. " have open floor between them")
		end
	end
	-- The walkway ends at the merge pad.
	near(Layout.WALKWAY.maxZ, Layout.padRect(P.Merge, Layout.PAD_RIM).minZ, "walkway ends at the merge pad")
	check(Layout.padRect(P.Merge, Layout.PAD_RIM).minX <= Layout.WALKWAY.minX, "merge pad spans the walkway")
	for _, name in { "Deposit", "ProcUp1", "ProcUp10", "Collect" } do
		check(P[name].x < -20, name .. " on the -X side")
	end
	for _, name in { "BuyTier", "Unlock1", "Unlock2", "Free" } do
		check(P[name].x > 20, name .. " on the +X side")
	end

	local obstacles = layoutObstacles()
	for i, nameA in Layout.PAD_ORDER do
		local spot = Layout.PADS[nameA]
		local rim = Layout.padRect(spot, Layout.PAD_RIM)
		check(insidePlot(rim), nameA .. " inside the walls")
		check(not Layout.overlaps(rim, Layout.POOL, 0.4), nameA .. " clear of the pen")
		for obstacle, rect in obstacles do
			check(not Layout.overlaps(rim, rect), nameA .. " clear of " .. obstacle)
		end
		check(not Layout.overlaps(rim, Layout.WALKWAY), nameA .. " clear of the walkway")
		for j = i + 1, #Layout.PAD_ORDER do
			local nameB = Layout.PAD_ORDER[j]
			check(not Layout.overlaps(rim, Layout.padRect(Layout.PADS[nameB], Layout.PAD_RIM)), nameA .. " vs " .. nameB)
		end
		-- The spawn point must not start on a pad.
		check(not Layout.contains(Layout.padRect(spot, 2), Layout.SPAWN.x, Layout.SPAWN.z), nameA .. " clear of spawn")
		-- The ground around the spawn and under the spawn camera (Fx.Camera, ~14 studs behind)
		-- fills the first frame's lower edge: a pad there would be cut by it.
		local foreground = Layout.rect(-14, 14, Layout.SPAWN.z - 15, Layout.SPAWN.z + 1)
		check(not Layout.overlaps(rim, foreground), nameA .. " clear of the spawn view's foreground")
	end
	-- Machines never overlap each other or the pen.
	local machineNames = {}
	for name in Layout.MACHINES do
		table.insert(machineNames, name)
	end
	for i, a in machineNames do
		check(insidePlot(Layout.MACHINES[a]), a .. " inside the walls")
		check(not Layout.overlaps(Layout.MACHINES[a], Layout.POOL), a .. " clear of the pen")
		for j = i + 1, #machineNames do
			check(not Layout.overlaps(Layout.MACHINES[a], Layout.MACHINES[machineNames[j]]), a .. " vs " .. machineNames[j])
		end
	end
end)

test("plot layout: walkway", function()
	local w = Layout.WALKWAY
	check(w.maxX - w.minX >= 8, "walkway at least 8 studs wide")
	check(w.minZ <= -Layout.INNER_HALF + 1e-6, "walkway starts at the entrance")
	check(w.maxZ <= Layout.POOL.minZ and w.maxZ > Layout.SPAWN.z, "walkway runs from the entrance toward the pen")
	check(Layout.contains(w, Layout.SPAWN.x, Layout.SPAWN.z), "spawn on the walkway")
	for name, rect in layoutObstacles() do
		if name ~= "Pen" then
			check(not Layout.overlaps(w, rect), "walkway clear of " .. name)
		end
	end
end)

test("plot layout: crate areas", function()
	check(#Layout.CHEST_AREAS >= 1, "has crate areas")
	local pen = Layout.PEN.interior
	local cr = Layout.CRATE_RADIUS
	check(cr >= math.sqrt(3.6 ^ 2 + 2.6 ^ 2) / 2, "crate radius covers the lid at any yaw")
	for _, area in Layout.CHEST_AREAS do
		-- Crates land inside the pen (crate centres), a crate radius clear of its walls,
		-- in the front half so they never sit under the chute mouth.
		check(area.minX < area.maxX and area.minZ < area.maxZ, "crate area not empty")
		check(area.minX - cr >= pen.minX - 1e-6 and area.maxX + cr <= pen.maxX + 1e-6, "crates clear of the side walls")
		check(area.minZ - cr >= pen.minZ - 1e-6, "crates clear of the front wall")
		check(area.maxZ <= Layout.POOL_CENTER_Z + 1e-6, "crates land in the front half of the pen")
		check(area.maxZ + cr < Layout.CHUTE.bottomZ, "crates clear of the chute mouth")
		check(Layout.contains(Layout.ORB_AREA, area.minX, area.minZ), "crate area inside the orb area")
		check(Layout.contains(Layout.ORB_AREA, area.maxX, area.maxZ), "crate area inside the orb area")
		local grown = Layout.rect(area.minX - cr, area.maxX + cr, area.minZ - cr, area.maxZ + cr)
		for _, stair in Layout.PEN_STAIRS do
			check(not Layout.overlaps(grown, stair.steps[4].rect), "crates clear of the inner stair steps")
		end
		-- Three crates fit at the spawn spacing (6 studs apart).
		check(area.maxX - area.minX >= 12, "room for three crates side by side")
	end
	-- A crate's route: ledge -> gutter -> chute -> its landing spot, resting CRATE_LIFT above each surface.
	local area = Layout.CHEST_AREAS[1]
	local toX, toZ = (area.minX + area.maxX) / 2, (area.minZ + area.maxZ) / 2
	local slots = Layout.shelfSlots()
	for _, slot in { slots[1], slots[#slots] } do
		local path = Layout.cratePath(slot.x, slot.z, toX, toZ)
		check(#path == 6, "crate path has 6 waypoints")
		near(path[1].y, slot.y + Layout.CRATE_LIFT, "starts at the unit's feet")
		near(path[2].y, path[1].y, "moves out at its own shelf's height")
		check(path[2].z + 1.8 <= Layout.SHELF.frontZ - Layout.SHELF.frontReach + 1e-6, "crate drops clear of the rack front")
		near(path[3].z, Layout.GUTTER.z, "drops into the gutter")
		near(path[4].y, Layout.CHUTE.topY + Layout.CRATE_LIFT, "chute top")
		near(path[5].z, Layout.CHUTE.bottomZ, "chute bottom")
		near(path[6].x, toX, "lands on its spot")
		near(path[6].z, toZ, "lands on its spot")
		near(path[6].y, Layout.PEN.floorY + Layout.CRATE_LIFT, "rests on the pen floor")
	end
end)

test("plot layout: fan zones", function()
	check(#Layout.FAN_ZONES >= 2, "fan zones on both sides")
	local obstacles = layoutObstacles()
	for _, zone in Layout.FAN_ZONES do
		local r = zone.rect
		check(insidePlot(r), "fan zone inside the plot")
		check(not Layout.overlaps(r, Layout.WALKWAY), "fan zone off the walkway")
		for obstacle, rect in obstacles do
			check(not Layout.overlaps(r, rect), "fan zone clear of " .. obstacle)
		end
		for _, name in Layout.PAD_ORDER do
			check(not Layout.overlaps(r, Layout.padRect(Layout.PADS[name], Layout.PAD_RIM)), "fan zone clear of " .. name)
		end
	end
	local spots = Layout.fanSpots()
	check(#spots >= 14, "at least 14 fan spots")
	for i, spot in spots do
		local inZone = false
		for _, zone in Layout.FAN_ZONES do
			inZone = inZone or Layout.contains(zone.rect, spot.x, spot.z)
		end
		check(inZone, "fan spot in a fan zone")
		check(math.abs(spot.x) <= Layout.INNER_HALF and math.abs(spot.z) <= Layout.INNER_HALF, "fan spot inside the plot")
		near(spot.faceX * spot.faceX + spot.faceZ * spot.faceZ, 1, "fan facing is a unit vector")
		-- Facing the display: toward the ledge's middle.
		local dx, dz = Layout.FAN_FOCUS.x - spot.x, Layout.FAN_FOCUS.z - spot.z
		check(spot.faceX * dx + spot.faceZ * dz > 0, "fan faces the display")
		for j = i + 1, #spots do
			local other = spots[j]
			check((spot.x - other.x) ^ 2 + (spot.z - other.z) ^ 2 >= 2.5 ^ 2, "fan spots spaced apart")
		end
	end
	-- The first spots alternate sides.
	check(spots[1].x * spots[2].x < 0, "first two fans on opposite sides")
	check(spots[3].x * spots[4].x < 0, "next two fans on opposite sides")
end)

-- Orb look and Auto Aura (src/shared/OrbLook.luau) ------------------------------------------
do
	local OrbLook = require("../src/shared/OrbLook")
	-- Orb paint by producing tier: cycles through the palette, neighbouring tiers differ.
	local palette = { "violet", "pink", "yellow", "mint", "sky", "orange", "coral", "cream" }
	local neighboursDiffer = true
	for tier = 1, 40 do
		neighboursDiffer = neighboursDiffer and OrbLook.tierColor(tier, palette) ~= OrbLook.tierColor(tier + 1, palette)
	end
	check(OrbLook.tierColor(1, palette) == "violet" and OrbLook.tierColor(nil, palette) == "violet", "tier 1 orbs are violet")
	check(OrbLook.tierColor(9, palette) == "violet" and OrbLook.tierColor(2, palette) == "pink", "orb palette cycles")
	check(neighboursDiffer, "neighbouring tiers get different orb colours")
	local tr, tg, tb = OrbLook.tagRGB(150, 76, 242)
	check(tr > 150 and tg > 76 and tb >= 242 and tr < 255, "orb tag text is the lightened ball colour")
	check(select(1, OrbLook.tagRGB(255, 236, 200)) == 255, "pale orbs get white tags")
	-- Pen fill rule: new balls until the cap, then counts rise on existing balls.
	local CAP = 6
	local balls: { { tier: number, count: number, value: number } } = {}
	local produced, belowCapNew = 0, true
	for i = 1, 40 do
		local tier = if i % 3 == 0 then 2 else 1
		local before = #balls
		local target = OrbLook.feedTarget(balls, tier, CAP, (i * 0.37) % 1)
		if before < CAP then
			belowCapNew = belowCapNew and target == nil
		end
		if target then
			balls[target].count += 1
			balls[target].value += 5
		else
			table.insert(balls, { tier = tier, count = 1, value = 5 })
		end
		produced += 5
	end
	local total, countSum, maxCount, minCount = 0, 0, 0, math.huge
	for _, ball in balls do
		total += ball.value
		countSum += ball.count
		maxCount, minCount = math.max(maxCount, ball.count), math.min(minCount, ball.count)
	end
	check(belowCapNew, "below the cap every orb lands as a new ball")
	check(#balls == CAP and countSum == 40, "at the cap the ball count stays put and counts rise")
	check(total == produced, "orb value is conserved when counts rise")
	check(maxCount - minCount <= 6, "counts spread over the balls")
	local mixed = { { tier = 1, count = 1 }, { tier = 2, count = 5 }, { tier = 2, count = 3 } }
	check(OrbLook.feedTarget(mixed, 2, 3) == 3, "same tier first, then the lowest count")
	check(OrbLook.feedTarget(mixed, 7, 3) == 1, "no same tier ball: the lowest count")
	check(OrbLook.feedTarget(mixed, 1, 4) == nil, "below the cap: a new ball")
	-- Auto Aura never collects before the roll-in can have landed, and never waits forever.
	local short, long = OrbLook.autoCollectDelay(10, 0), OrbLook.autoCollectDelay(60, 2.5)
	check(short >= OrbLook.travelTime(10, 0) + OrbLook.SETTLE - 1e-6, "auto collect after landing")
	check(long >= short and long <= 12, "auto collect delay grows with the route, capped")
	-- Walking over orbs and Auto Aura credit the same orbs identically.
	local values = { 3, 12.5, 400, 1 }
	local manual = 0
	for _, v in values do
		manual += OrbLook.credit({ v })
	end
	check(OrbLook.credit(values) == manual and manual == 416.5, "auto collect credit equals manual pickup")
end

-- Fans -------------------------------------------------------------------------------
-- Fan looks (Theme.Fans.Looks), the cutscene cast and the Fan / Story animation sets.

local FAN_POSES = { "Idle", "Cheer", "Wave", "Clap", "Swoon", "SignUp", "Point", "Jump" }
local STORY_POSES = { "Stand", "Sad", "Shock", "Idea", "Flex", "Walk", "Run", "Strut" }
local FAN_PROPS = { FanSign = true, PomPoms = true, FoamFinger = true }

local function signLabels(model: any): { any }
	local labels = {}
	for _, d in model:GetDescendants() do
		if d:IsA("TextLabel") and d.Name == "SignText" then
			table.insert(labels, d)
		end
	end
	return labels
end

-- Every part finite and near the model after posing.
local function posedOk(parts: { any }, radius: number): boolean
	for _, part in parts do
		if not cframeFinite(part.CFrame) or part.CFrame.Position.Magnitude > radius then
			return false
		end
	end
	return true
end

test("fans: every look builds a 15-limb rig and plays every Fan pose", function()
	local theme = loadRobloxTheme("src/themes/chad/Theme.luau")
	local looks = theme.Fans.Looks
	eq(#looks, 8, "eight fan looks")
	local girls = 0
	for i, look in looks do
		local label = "fan " .. i
		eq(look.anim, "Fan", label .. " anim")
		check(FAN_PROPS[look.prop] == true, label .. " default prop " .. tostring(look.prop))
		check(type(look.scale) == "number" and look.scale >= 0.85 and look.scale <= 0.92, label .. " scale")
		if look.lashes then
			girls += 1
		end
		for _, acc in look.acc or {} do
			check(CharacterFactory.ACCESSORIES[acc] ~= nil, label .. " known accessory " .. acc)
		end
		check(CharacterFactory.EXPRESSIONS[look.expr] ~= nil, label .. " known expr")

		local model = CharacterFactory.build(look, "Fan" .. i)
		check(model:HasTag(Poses.TAG), label .. " tagged AnimatedUnit")
		eq(model:GetAttribute(Poses.SET_ATTRIBUTE), "Fan", label .. " AnimSet")
		local perLimb, count, bad = {}, 0, 0
		for _, d in model:GetDescendants() do
			if d:IsA("BasePart") then
				count += 1
				if not d.Anchored or d.CanCollide or d.CanTouch or d.CanQuery then
					bad += 1
				end
				local limb = d:GetAttribute(Poses.LIMB_ATTRIBUTE)
				if limb then
					perLimb[limb] = (perLimb[limb] or 0) + 1
				elseif d ~= model.PrimaryPart then
					bad += 1
				end
				if d.Material == roblox.Enum.Material.Neon then
					bad += 1
				end
			end
		end
		eq(bad, 0, label .. " parts anchored, non-colliding, matte and on a limb")
		check(count <= MAX_PARTS, string.format("%s part budget (%d <= %d)", label, count, MAX_PARTS))
		for _, limb in Poses.LIMBS do
			check(typeof(model:GetAttribute(Poses.PIVOT_PREFIX .. limb)) == "Vector3", label .. " pivot " .. limb)
			check((perLimb[limb] or 0) > 0, label .. " has a part on " .. limb)
		end
		local height = model:GetAttribute("Height")
		check(type(height) == "number" and height > 3.5 and height < 5.6, label .. " fan height " .. tostring(height))

		if look.prop == "FanSign" then
			local text = look.signText or "#1 FAN"
			eq(model:GetAttribute("SignText"), text, label .. " SignText attribute")
			local labels = signLabels(model)
			eq(#labels, 2, label .. " sign text on both faces")
			for _, l in labels do
				eq(l.Text, text, label .. " sign text")
			end
			CharacterFactory.setSignText(model, "GO!")
			eq(model:GetAttribute("SignText"), "GO!", label .. " setSignText attribute")
			for _, l in signLabels(model) do
				eq(l.Text, "GO!", label .. " setSignText label")
			end
		end

		local rig = RigPose.capture(model, i)
		check(rig ~= nil and #rig.parts == count - 1, label .. " rig captures every limb part")
		if rig then
			local identity = {}
			for _, limb in Poses.LIMBS do
				identity[limb] = CFrame.new()
			end
			local parts, cframes = RigPose.computeFrom(rig, identity)
			local moved = 0
			for k, part in parts do
				if not cframeNear(part.CFrame, cframes[k], 1e-3) then
					moved += 1
				end
			end
			eq(moved, 0, label .. " rest pose round trip")
			for _, pose in Poses.allPoseNames("Fan") do
				local ok = true
				for _, t in { 0, 0.41, 1.37, 2.9 } do
					local success = pcall(RigPose.applyPose, rig, pose, t)
					ok = ok and success and posedOk(parts, 12)
				end
				check(ok, label .. " plays " .. pose)
			end
			RigPose.apply(rig, 7.7)
			check(posedOk(parts, 12), label .. " rotation pose stays attached")
		end
		model:Destroy()
	end
	eq(girls, 6, "six girl looks (lashes), two boys")
end)

test("fans: Fan and Story pose sets", function()
	local fanNames = Poses.poseNames("Fan")
	for _, name in FAN_POSES do
		check(table.find(fanNames, name) ~= nil, "Fan pose " .. name)
	end
	local storyNames = Poses.allPoseNames("Story")
	for _, name in STORY_POSES do
		check(table.find(storyNames, name) ~= nil, "Story pose " .. name)
	end
	for _, set in { "Fan", "Story" } do
		local bad = 0
		for _, name in Poses.allPoseNames(set) do
			for i = 0, 40 do
				local pose = Poses.samplePose(set, name, i * 0.137, i)
				for _, limb in Poses.LIMBS do
					local cf = pose[limb]
					if cf == nil or not cframeFinite(cf) or math.abs(cf.LookVector.Magnitude - 1) > 1e-4 then
						bad += 1
					end
				end
			end
		end
		eq(bad, 0, set .. " poses finite over time")
		for _, name in Poses.poseNames(set) do
			local t = Poses.timeFor(set, 77, name)
			check(t ~= nil and t >= 0, set .. " timeFor " .. name)
		end
		local a, b = Poses.sample(set, 3.7, 42), Poses.sample(set, 3.7, 42)
		local sweep = 0
		for _, limb in Poses.LIMBS do
			check(cframeNear(a[limb], b[limb], 0), set .. " deterministic " .. limb)
		end
		for i = 0, 300 do
			local sample = Poses.sample(set, i * 0.173, i % 37)
			for _, limb in Poses.LIMBS do
				if not cframeFinite(sample[limb]) then
					sweep += 1
				end
			end
		end
		eq(sweep, 0, set .. " rotation sweep finite")
	end
	-- Any set can play the shared poses.
	check(Poses.samplePose("Chad", "Sad").Head ~= nil, "Chad rig plays Story Sad")
	check(Poses.samplePose("Fan", "Walk", 0.3).Head ~= nil, "Fan rig plays Story Walk")
	check(Poses.samplePose("Chad", "Cheer", 0.3).Head ~= nil, "Chad rig plays Fan Cheer")
	-- Gaits loop seamlessly and gaitTime converts distance to cycle time.
	for gait, g in Poses.GAIT do
		check(g.speed > 0 and g.period > 0, gait .. " gait numbers")
		local p0 = Poses.samplePose("Story", gait, 0.37)
		local p1 = Poses.samplePose("Story", gait, 0.37 + g.period)
		local same = true
		for _, limb in Poses.LIMBS do
			same = same and cframeNear(p0[limb], p1[limb], 1e-4)
		end
		check(same, gait .. " loops every period")
		check(math.abs(Poses.gaitTime(gait, g.speed * 1.5 * 4, 1.5) - 4) < 1e-9, gait .. " gaitTime")
	end
	-- blendInto: alpha 0 is the from pose, 1 the to pose.
	local from = Poses.samplePose("Fan", "Idle", 1.1, 3)
	local to = Poses.samplePose("Fan", "Cheer", 1.1, 3)
	local b0 = Poses.blendInto({}, "Fan", "Idle", "Cheer", 0, 1.1, 3)
	local b1 = Poses.blendInto({}, "Fan", "Idle", "Cheer", 1, 1.1, 3)
	local ok0, ok1 = true, true
	for _, limb in Poses.LIMBS do
		ok0 = ok0 and cframeNear(b0[limb], from[limb], 1e-5)
		ok1 = ok1 and cframeNear(b1[limb], to[limb], 1e-5)
	end
	check(ok0 and ok1, "blendInto endpoints")
end)

test("fans: cutscene cast", function()
	local theme = loadRobloxTheme("src/themes/chad/Theme.luau")
	local cast = theme.Fans.Cast
	for _, role in { "Hero", "Rival", "Fan" } do
		local look = cast[role]
		check(look ~= nil, "cast " .. role)
		local model = CharacterFactory.build(look, role)
		check(not model:HasTag(Poses.TAG), role .. " manual: not tagged for the Animator")
		local rig = RigPose.capture(model, 1)
		check(rig ~= nil, role .. " rig")
		if rig then
			-- Code moves the Root, then poses: parts follow the moved root.
			rig.root.CFrame = CFrame.new(10, 0, -20)
			for _, pose in { "Walk", "Run", "Sad", "Shock", "Idea" } do
				RigPose.applyPose(rig, pose, 0.8)
				local far = 0
				for _, part in rig.parts do
					if not cframeFinite(part.CFrame) or (part.CFrame.Position - Vector3.new(10, 3, -20)).Magnitude > 14 then
						far += 1
					end
				end
				eq(far, 0, role .. " " .. pose .. " follows the moved root")
			end
			RigPose.applyPose(rig, "Walk", 0.8, "Sad", 0.5)
			check(posedOk(rig.parts, 40), role .. " blend Sad -> Walk")
		end
		if look.exprs then
			local function visible(name: string): (number, number)
				local shown, hidden = 0, 0
				for _, d in model:GetDescendants() do
					if d:IsA("BasePart") and d:GetAttribute("Expr") == name then
						if d.Transparency == 0 then
							shown += 1
						else
							hidden += 1
						end
					end
				end
				return shown, hidden
			end
			local current = look.expr
			local target = look.exprs[#look.exprs]
			local shown, hidden = visible(current)
			check(shown > 0 and hidden == 0, role .. " current expression shown")
			check(CharacterFactory.setExpression(model, target), role .. " setExpression")
			shown, hidden = visible(target)
			check(shown > 0 and hidden == 0, role .. " new expression shown")
			shown = visible(current)
			eq(shown, 0, role .. " old expression hidden")
			eq(model:GetAttribute("Expression"), target, role .. " Expression attribute")
			check(not CharacterFactory.setExpression(model, "Nope"), role .. " unknown expression")
		end
		model:Destroy()
	end
end)

-- Intro ------------------------------------------------------------------------------
-- The opening cutscene: its saved flag (DataService) and its timeline data.

local function loadDataService(): any
	local services = {
		DataStoreService = {
			GetDataStore = function()
				error("no DataStore in tests")
			end,
		},
		HttpService = {
			GenerateGUID = function()
				return "test"
			end,
		},
		RunService = {
			IsStudio = function()
				return true
			end,
		},
		ReplicatedStorage = { Shared = { Economy = Economy, SessionLock = SessionLock, TutorialSteps = TutorialSteps } },
	}
	local env = setmetatable({
		game = {
			JobId = "",
			GetService = function(_, name)
				return services[name]
			end,
		},
		require = function(module)
			return module
		end,
		warn = function() end,
	}, { __index = _G })
	local path = "src/server/DataService.luau"
	return luau.load(fs.readFile(path), { debugName = path, environment = env })()
end

test("intro seen flag", function()
	local DataService = loadDataService()
	eq(DataService.defaultProfile().introSeen, false, "new profiles have not seen the intro")
	eq(DataService.reconcile(nil).introSeen, false, "a blank save starts with the intro")
	local legacy = DataService.reconcile({ money = 10, totalObtained = 3 })
	eq(legacy.introSeen, true, "saves from before the intro skip it")
	eq(DataService.reconcile({ money = 10, introSeen = false }).introSeen, false, "unwatched stays unwatched")
	eq(DataService.reconcile({ money = 10, introSeen = true }).introSeen, true, "watched stays watched")
	-- Purchase counts from a save made under a bigger upgrade requirement are capped to it.
	local capped = DataService.reconcile({ money = 10, buyTier = 3, boughtAtTier = 400 })
	eq(capped.boughtAtTier, Economy.buyTierRequirement(3), "purchases past the requirement are capped")
	eq(DataService.reconcile({ money = 10, buyTier = 3, boughtAtTier = 1 }).boughtAtTier, 1, "purchases under it are kept")
end)

test("onboarding funnel and badges fields", function()
	local DataService = loadDataService()
	eq(DataService.reconcile(nil).onboarding, 0, "new players start the onboarding funnel")
	eq(DataService.reconcile({ money = 10 }).onboarding, 99, "saves from before the funnel never log it")
	eq(DataService.reconcile({ money = 10, onboarding = 4 }).onboarding, 4, "funnel progress is kept")
	local badges = DataService.reconcile({ money = 10, badges = { Welcome = true, GymGraduate = false, [1] = true, Bad = 2 } }).badges
	eq(badges.Welcome, true, "awarded badges are kept")
	eq(badges.GymGraduate, false, "pending badges are kept")
	eq(badges[1], nil, "non-string keys are dropped")
	eq(badges.Bad, nil, "non-boolean values are dropped")
	eq(DataService.reconcile({ money = 10, badges = "x" }).badges.Welcome, nil, "a broken badges field resets")
end)

-- Cosmetics ----------------------------------------------------------------------------
-- Cosmetic passes, the bundle and the Starter pack (Theme.Cosmetics, Server.Cosmetics).

local function loadCosmetics(): any
	local shared = {
		Economy = Economy,
		AssetModels = {},
		FindFirstChild = function()
			return nil
		end,
	}
	local services = {
		Players = {},
		ReplicatedStorage = {
			WaitForChild = function()
				return shared
			end,
		},
	}
	local env = robloxEnv()
	env.game = {
		GetService = function(_, name)
			return services[name]
		end,
	}
	env.script = { Parent = { DataService = {}, Tycoon = {} } }
	env.require = function(module)
		return module
	end
	local path = "src/server/Cosmetics.luau"
	return luau.load(fs.readFile(path), { debugName = path, environment = env })()
end

test("cosmetics theme tables", function()
	local theme = loadRobloxTheme("src/themes/chad/Theme.luau")
	local c = theme.Cosmetics
	local passes = theme.Monetization.Passes
	check(type(c) == "table" and type(c.Items) == "table" and type(c.Order) == "table", "Theme.Cosmetics shape")
	local listed = {}
	for _, name in c.Order do
		check(c.Items[name] ~= nil, "ordered item exists " .. name)
		check(not listed[name], "listed once " .. name)
		listed[name] = true
	end
	local trails, toggles, starters = 0, 0, 0
	for name, item in c.Items do
		check(listed[name] == true, "item in Order " .. name)
		check(item.Kind == "perk" or item.Kind == "trail" or item.Kind == "wear", "kind of " .. name)
		check(type(item.Title) == "string" and type(item.Desc) == "string" and type(item.Icon) == "string", "text of " .. name)
		check(typeof(item.Color) == "Color3", "colour of " .. name)
		if item.Kind == "trail" then
			trails += 1
			check(type(item.Colors) == "table" and #item.Colors >= 1, "trail colours " .. name)
		else
			toggles += 1
		end
		if item.Starter then
			starters += 1
			check(item.Pass == nil, "starter item has no pass of its own " .. name)
		else
			local pass = passes[item.Pass]
			check(pass ~= nil and type(pass.Id) == "number" and pass.Price > 0, "pass of " .. name)
			check(table.find(theme.Monetization.PassOrder, item.Pass) == nil, "cosmetic pass not in PassOrder " .. name)
		end
	end
	eq(trails, 3, "trails")
	eq(toggles, 4, "toggle cosmetics")
	eq(starters, 1, "starter-only items")
	check(passes[c.Bundle] ~= nil and passes[c.Starter.Pass] ~= nil, "bundle and starter passes")
	check(table.find(theme.Monetization.PassOrder, c.Bundle) == nil, "bundle not in PassOrder")
	check(table.find(theme.Monetization.PassOrder, c.Starter.Pass) == nil, "starter not in PassOrder")
	check(c.Items[c.Starter.Item] ~= nil and c.Items[c.Starter.Item].Starter == true, "starter item")
	check(theme.Monetization.GemPacks[c.Starter.GemPack] ~= nil, "starter Rizz pack")
	check(c.Items.SpeedBoost.SpeedMultiplier > 1 and c.BaseWalkSpeed > 0, "speed boost numbers")
	local prices = {
		SpeedBoost = 79,
		DoubleJump = 79,
		TrailRainbow = 49,
		TrailStar = 49,
		AuraGlow = 99,
		Crown = 129,
		AllCosmetics = 299,
		StarterPack = 59,
	}
	for name, price in prices do
		eq(passes[name] and passes[name].Price, price, "price of " .. name)
	end
end)

test("cosmetics ownership", function()
	local theme = loadRobloxTheme("src/themes/chad/Theme.luau")
	local Cosmetics = loadCosmetics()
	local single = { SpeedBoost = true }
	check(Cosmetics.owns(theme, single, "SpeedBoost"), "own pass")
	check(not Cosmetics.owns(theme, single, "DoubleJump"), "not another pass")
	check(not Cosmetics.owns(theme, single, "TrailRookie"), "no starter trail")
	check(not Cosmetics.owns(theme, single, "Nope"), "unknown item")
	local bundle = { AllCosmetics = true }
	for name, item in theme.Cosmetics.Items do
		eq(Cosmetics.owns(theme, bundle, name), not item.Starter, "bundle owns " .. name)
	end
	local starter = { StarterPack = true }
	for name, item in theme.Cosmetics.Items do
		eq(Cosmetics.owns(theme, starter, name), item.Starter == true, "starter owns " .. name)
	end
	local owned = Cosmetics.ownedSet(theme, { AllCosmetics = true, StarterPack = true })
	for name in theme.Cosmetics.Items do
		check(owned[name] == true, "bundle + starter own " .. name)
	end
end)

test("cosmetics profile and state", function()
	local theme = loadRobloxTheme("src/themes/chad/Theme.luau")
	local DataService = loadDataService()
	local Cosmetics = loadCosmetics()
	local fresh = DataService.reconcile(nil)
	eq(fresh.cosmetics.trail, "", "no trail by default")
	check(next(fresh.cosmetics.toggles) == nil, "no toggles saved by default")
	eq(fresh.starterGranted, false, "starter not granted by default")
	local legacy = DataService.reconcile({ money = 10, totalObtained = 3 })
	eq(legacy.cosmetics.trail, "", "old saves get no trail")
	eq(legacy.starterGranted, false, "old saves get starterGranted")
	eq(DataService.reconcile({ cosmetics = "bad" }).cosmetics.trail, "", "bad cosmetics table replaced")
	local messy = DataService.reconcile({ cosmetics = { trail = 5, toggles = { Crown = false, Junk = "x" } } })
	eq(messy.cosmetics.trail, "", "bad trail reset")
	eq(messy.cosmetics.toggles.Crown, false, "toggle kept")
	eq(messy.cosmetics.toggles.Junk, nil, "bad toggle dropped")
	local kept = DataService.reconcile({ cosmetics = { trail = "TrailStar", toggles = {} }, starterGranted = true })
	eq(kept.cosmetics.trail, "TrailStar", "trail kept")
	eq(kept.starterGranted, true, "starter flag kept")

	local profile = DataService.reconcile(nil)
	local passes = { TrailStar = true, Crown = true }
	check(Cosmetics.active(theme, profile, passes, "Crown"), "owned toggles start on")
	check(not Cosmetics.active(theme, profile, passes, "AuraGlow"), "unowned toggle is off")
	profile.cosmetics.toggles.Crown = false
	check(not Cosmetics.active(theme, profile, passes, "Crown"), "switched-off toggle")
	profile.cosmetics.trail = "TrailRainbow"
	eq(Cosmetics.trail(theme, profile, passes), "", "unowned equipped trail is not shown")
	profile.cosmetics.trail = "TrailStar"
	eq(Cosmetics.trail(theme, profile, passes), "TrailStar", "owned equipped trail")
	local state = Cosmetics.state(theme, profile, passes)
	eq(state.trail, "TrailStar", "state trail")
	check(state.owned.Crown and state.owned.TrailStar and not state.owned.SpeedBoost, "state owned")
	eq(state.toggles.Crown, false, "state toggle off")
	eq(state.toggles.SpeedBoost, true, "state toggle default on")
	eq(state.toggles.TrailStar, nil, "trails are not toggles")
	eq(state.starterOwned, false, "state starter owned")
end)

test("starter pack grant", function()
	local theme = loadRobloxTheme("src/themes/chad/Theme.luau")
	local DataService = loadDataService()
	local Cosmetics = loadCosmetics()
	local profile = DataService.reconcile(nil)
	check(not Cosmetics.claimStarter(theme, profile, {}), "not owned: nothing granted")
	eq(profile.starterGranted, false, "not owned: not marked")
	local passes = { StarterPack = true }
	check(Cosmetics.claimStarter(theme, profile, passes), "first claim grants")
	eq(profile.starterGranted, true, "marked as granted")
	check(not Cosmetics.claimStarter(theme, profile, passes), "second claim does nothing")
	local saved = DataService.reconcile(table.clone(profile))
	check(not Cosmetics.claimStarter(theme, saved, passes), "still granted after a reload")

	local starter = theme.Cosmetics.Starter
	local early = Economy.progression(1, 0)
	local cash, gems = Cosmetics.starterAmounts(theme, 0, early)
	eq(cash, starter.CashMin, "new player gets the cash minimum")
	eq(gems, Economy.gemPackAmount(theme.Monetization.GemPacks[starter.GemPack].Base, early), "Big Rizz Pack amount")
	local late = Economy.progression(20, 10)
	local lateCash, lateGems = Cosmetics.starterAmounts(theme, 1e6, late)
	eq(lateCash, Economy.moneyPackAmount(1e6, starter.CashSeconds, starter.CashMin, late), "30 minutes of income")
	check(lateCash >= 1e6 * 1800 and lateGems >= gems, "late amounts scale up")
end)

test("intro timeline", function()
	local path = "src/client/Intro/Timeline.luau"
	local Timeline = luau.load(fs.readFile(path), { debugName = path })()
	local intro = loadRobloxTheme("src/themes/chad/Theme.luau").Intro
	check(type(intro) == "table" and type(intro.Lines) == "table", "Theme.Intro.Lines")
	local eases = {}
	for _, name in Timeline.EASES do
		eases[name] = true
	end
	local names = {}
	check(#Timeline.BEATS >= 6, "six beats")
	for i, beat in Timeline.BEATS do
		local label = "beat " .. i .. " " .. tostring(beat.name)
		check(type(beat.name) == "string" and not names[beat.name], label .. " unique name")
		names[beat.name] = true
		check(type(beat.duration) == "number" and beat.duration > 0, label .. " duration > 0")
		check(#beat.camera > 0 and beat.camera[1].t == 0, label .. " camera starts at 0")
		local last = -1
		for _, key in beat.camera do
			check(key.t >= last and key.t <= beat.duration, label .. " camera keys in order")
			last = key.t
			check(key.ease == nil or eases[key.ease], label .. " camera ease " .. tostring(key.ease))
			local space = key.space or "stage"
			check(space == "stage" or space == "plot" or space == "behind", label .. " camera space")
			if key.shot then
				check(space == "stage", label .. " shot keys are stage space")
				check(type(key.shot.subjects) == "table" and #key.shot.subjects > 0, label .. " shot subjects")
				for _, name in key.shot.subjects do
					check(Timeline.ACTORS[name] ~= nil, label .. " shot subject " .. tostring(name))
				end
			elseif space ~= "behind" then
				check(type(key.pos) == "table" and #key.pos == 3, label .. " camera pos")
				check(type(key.look) == "table" and #key.look == 3, label .. " camera look")
			end
		end
		for _, caption in beat.captions do
			check(caption.t >= 0 and caption.t <= beat.duration, label .. " caption time")
			check(caption.hide or intro.Lines[caption.key] ~= nil, label .. " caption " .. tostring(caption.key))
		end
		for _, a in beat.actions do
			local fields = Timeline.ACTIONS[a.act]
			check(fields ~= nil, label .. " known action " .. tostring(a.act))
			check(type(a.t) == "number" and a.t >= 0 and a.t <= beat.duration, label .. " action time")
			for _, field in fields or {} do
				check(a[field] ~= nil, label .. " " .. a.act .. " has " .. field)
			end
			if a.actor then
				check(Timeline.ACTORS[a.actor] ~= nil, label .. " actor " .. tostring(a.actor))
			end
			if a.dur then
				check(a.dur > 0, label .. " " .. a.act .. " dur > 0")
			end
			if a.act == "pose" or (a.act == "pop" and a.pose) then
				check(pcall(Poses.samplePose, "Chad", a.pose), label .. " pose " .. tostring(a.pose))
			end
			if a.act == "move" then
				check(Poses.GAIT[a.gait] ~= nil, label .. " gait " .. tostring(a.gait))
			end
			if a.act == "bubble" then
				check(intro.Bubbles[a.key] ~= nil, label .. " bubble " .. tostring(a.key))
			end
			if a.act == "sign" then
				check(type(intro[a.key]) == "string", label .. " sign " .. tostring(a.key))
			end
		end
	end
	local total = Timeline.total()
	check(total >= 24 and total <= 32, "about 25-30 seconds (" .. total .. ")")
	near(Timeline.startOf(#Timeline.BEATS) + Timeline.BEATS[#Timeline.BEATS].duration, total)
end)

-- Hero faces ---------------------------------------------------------------------------
-- src/client/Intro/Avatar.luau: the emotions the hero acts out on its face, their
-- part-built fallbacks, and which strategy each kind of head gets.

local function loadIntroAvatar(): any
	local stub = {}
	stub.WaitForChild = function()
		return stub
	end
	local env = setmetatable({
		game = {
			GetService = function()
				return stub
			end,
		},
		script = { Parent = stub },
		require = function()
			return {}
		end,
		warn = function() end,
	}, { __index = _G })
	local path = "src/client/Intro/Avatar.luau"
	return luau.load(fs.readFile(path), { debugName = path, environment = env })()
end

test("Hero faces", function()
	local Avatar = loadIntroAvatar()
	local Timeline = luau.load(fs.readFile("src/client/Intro/Timeline.luau"))()
	local emotions = {}
	for _, name in Avatar.EMOTIONS do
		emotions[name] = true
		check(fs.isFile("art/out/faces/" .. name .. ".png"), name .. " face image rendered")
		check(type(Avatar.FACE_POSES[name]) == "table", name .. " has a FaceControls pose")
	end
	local controls = {}
	for _, prop in Avatar.FACE_CONTROLS do
		controls[prop] = true
	end
	for name, pose in Avatar.FACE_POSES do
		for prop, value in pose do
			check(controls[prop] == true, name .. " pose uses a listed FaceControls property " .. prop)
			check(value >= 0 and value <= 1, name .. "." .. prop .. " in 0..1")
		end
	end

	-- the part-built hero's own faces (Actors: the hero look's exprs)
	local heroExprs = fs.readFile("src/client/Intro/Actors.luau"):match("look%.exprs = (%b{})")
	check(heroExprs ~= nil, "hero exprs found in Actors.luau")
	local used = 0
	for _, beat in Timeline.BEATS do
		local shown = false
		for _, a in beat.actions do
			if a.act == "expr" and a.actor == "Hero" then
				shown = true
				used += 1
				check(emotions[a.name] == true, beat.name .. ": hero emotion " .. tostring(a.name) .. " is a face")
				local fallback = Avatar.FALLBACK[a.name]
				check(type(fallback) == "string", beat.name .. ": " .. tostring(a.name) .. " has a fallback")
				check(
					heroExprs ~= nil and heroExprs:find('"' .. tostring(fallback) .. '"', 1, true) ~= nil,
					tostring(fallback) .. " is a part-built hero face"
				)
			end
		end
		check(shown, beat.name .. " shows a hero emotion")
	end
	check(used >= #Timeline.BEATS, "an emotion on every beat")

	eq(Avatar.faceStrategy({ faceControls = true, faceDecal = false }), "Controls", "dynamic head")
	eq(Avatar.faceStrategy({ faceControls = false, faceDecal = true }), "Swap", "classic face decal")
	eq(Avatar.faceStrategy({ faceControls = true, faceDecal = true }), "Controls", "dynamic head with a leftover decal")
	eq(Avatar.faceStrategy({ faceControls = false, faceDecal = false }), "None", "painted face keeps the player's own")
end)

-- Intro framing ------------------------------------------------------------------------
-- src/client/Intro/Framing.luau: every shot key keeps its subjects' heads and feet
-- inside the 5%-95% safe area, for several real avatar heights and aspect ratios.

test("Intro framing", function()
	local Timeline = luau.load(fs.readFile("src/client/Intro/Timeline.luau"))()
	local Framing = luau.load(fs.readFile("src/client/Intro/Framing.luau"))()
	local HEIGHTS = { Rival = 11, Fan = 5.2 }
	local ASPECTS = { ["16:9"] = 16 / 9, ["4:3"] = 4 / 3, ["21:9"] = 21 / 9, phone = 19.5 / 9 }

	-- Where every actor stands (and whether it is shown) at time t of beat `index`.
	local function castAt(index: number, t: number): { [string]: any }
		local state = {}
		for name, a in Timeline.ACTORS do
			state[name] = { x = a.at[1], z = a.at[2], visible = not a.hidden }
		end
		for b = 1, index do
			local limit = if b == index then t else math.huge
			for _, a in Timeline.BEATS[b].actions do
				local st = a.actor and state[a.actor]
				if st and a.t <= limit then
					if a.act == "show" then
						st.visible = true
					elseif a.act == "pop" then
						st.visible, st.x, st.z = true, a.at[1], a.at[2]
					elseif a.act == "move" then
						local u = math.clamp((limit - a.t) / a.dur, 0, 1)
						st.x += (a.to[1] - st.x) * u
						st.z += (a.to[2] - st.z) * u
						if a.vanish and u >= 1 then
							st.visible = false
						end
					end
				end
			end
		end
		return state
	end

	local function subjectsOf(shot: any, state: any, heroHeight: number): { any }
		local out = {}
		for _, name in shot.subjects do
			local st = state[name]
			if st.visible then
				local h = if name == "Hero" then heroHeight else HEIGHTS[name] or 5.2
				table.insert(out, { feet = { st.x, 0, st.z }, height = h, radius = 0.35 * h, name = name })
			end
		end
		return out
	end

	local function inSafe(eye: any, look: any, fov: number, aspect: number, p: any, label: string)
		local x, y, z = Framing.project(eye, look, fov, aspect, p)
		check(
			z > 0 and math.abs(x) <= Framing.SAFE + 1e-6 and math.abs(y) <= Framing.SAFE + 1e-6,
			string.format("%s at (%.2f, %.2f)", label, x, y)
		)
	end

	local function checkFrame(eye: any, look: any, fov: number, aspect: number, subjects: { any }, label: string)
		check(eye[2] >= Framing.MIN_EYE_Y - 1e-6, label .. " camera above the ground")
		for i, s in subjects do
			inSafe(eye, look, fov, aspect, s.feet, label .. " subject " .. i .. " feet")
			inSafe(eye, look, fov, aspect, { s.feet[1], s.height, s.feet[3] }, label .. " subject " .. i .. " head")
		end
	end

	-- The dropped dumbbell (on the ground by the hero from the drop until it rolls away).
	local function dumbbellAt(index: number, t: number): { number }?
		local spot = nil
		for b = 1, index do
			for _, a in Timeline.BEATS[b].actions do
				if a.act == "dumbbell" and (b < index or a.t <= t) then
					if a.state == "drop" then
						local hero = Timeline.ACTORS.Hero.at
						spot = { hero[1], 0.8, hero[2] }
					elseif a.state == "roll" then
						local to = a.to or { 0, 0 }
						spot = { to[1], 0.8, to[2] }
					end
				end
			end
		end
		return spot
	end

	-- Nothing that is not a subject (other actors, the dropped dumbbell) may sit in
	-- the line of sight within BLOCK_NEAR studs of the lens.
	local BLOCK_NEAR = 6
	local function checkClearLens(eye: any, subjects: { any }, state: any, prop: { number }?, heroHeight: number, label: string)
		local blockers = {}
		local listed = {}
		for _, sub in subjects do
			listed[sub.name] = true
		end
		for name, st in state do
			if st.visible and not listed[name] then
				local h = if name == "Hero" then heroHeight else HEIGHTS[name] or 5.2
				table.insert(blockers, { name = name, c = { st.x, h / 2, st.z }, r = 0.3 * h })
			end
		end
		if prop then
			table.insert(blockers, { name = "dumbbell", c = prop, r = 1.3 })
		end
		for name, piece in Timeline.SET do
			table.insert(blockers, { name = name, c = { piece.at[1], piece.height / 2, piece.at[2] }, r = piece.radius })
		end
		for _, b in blockers do
			local dx, dy, dz = b.c[1] - eye[1], b.c[2] - eye[2], b.c[3] - eye[3]
			local dist = math.sqrt(dx * dx + dy * dy + dz * dz)
			if dist < BLOCK_NEAR + b.r then
				for _, sub in subjects do
					local c = { sub.feet[1], sub.height / 2, sub.feet[3] }
					local v = { c[1] - eye[1], c[2] - eye[2], c[3] - eye[3] }
					local len2 = v[1] * v[1] + v[2] * v[2] + v[3] * v[3]
					local u = math.clamp((dx * v[1] + dy * v[2] + dz * v[3]) / math.max(len2, 1e-6), 0, 1)
					local ox, oy, oz = eye[1] + v[1] * u - b.c[1], eye[2] + v[2] * u - b.c[2], eye[3] + v[3] * u - b.c[3]
					check(
						math.sqrt(ox * ox + oy * oy + oz * oz) > b.r,
						string.format("%s: %s blocks the lens in front of %s", label, b.name, sub.name)
					)
				end
			end
		end
	end

	-- The actors each beat is about: every shot key of the beat lists them while
	-- they are shown (the rival from the moment the name card lands).
	local ABOUT = { Gym = { "Hero", "Fan" }, Arrive = { "Rival" }, Wow = { "Rival", "Fan" }, Sad = { "Hero" }, Idea = { "Hero" } }
	for _, beat in Timeline.BEATS do
		local about = ABOUT[beat.name]
		if about then
			local cardAt = math.huge
			for _, a in beat.actions do
				if a.act == "namecard" and a.on ~= false then
					cardAt = math.min(cardAt, a.t)
				end
			end
			local listed = {}
			for k, key in beat.camera do
				local live = key.t >= cardAt or (beat.camera[k + 1] and beat.camera[k + 1].t > cardAt)
				for _, name in (key.shot and key.shot.subjects or {}) do
					listed[name] = true
				end
				if live and key.shot then
					check(
						table.find(key.shot.subjects, "Rival") ~= nil,
						beat.name .. " key " .. k .. " shows the rival under his name card"
					)
				end
			end
			for _, name in about do
				check(listed[name] == true, beat.name .. " frames " .. name)
			end
		end
	end
	-- The lightbulb (about 4 studs over the hero's head) stays in every shot after it pops.
	for _, beat in Timeline.BEATS do
		for _, a in beat.actions do
			if a.act == "bulb" then
				for k, key in beat.camera do
					if key.shot and key.t >= a.t then
						check((key.shot.headroom or 0) >= 4, beat.name .. " key " .. k .. " has headroom for the bulb")
					end
				end
			end
		end
	end

	local shots = 0
	for index, beat in Timeline.BEATS do
		for k, key in beat.camera do
			if key.shot then
				local nextKey = beat.camera[k + 1]
				for _, heroHeight in { 4.2, 5.6, 7.5 } do
					for aspectName, aspect in ASPECTS do
						local label = string.format("%s key %d hero %.1f %s", beat.name, k, heroHeight, aspectName)
						local subjects = subjectsOf(key.shot, castAt(index, key.t), heroHeight)
						check(#subjects > 0, label .. " has a visible subject")
						local eye, look, fov = Framing.solve(subjects, key.shot, aspect)
						checkFrame(eye, look, fov, aspect, subjects, label)
						checkClearLens(eye, subjects, castAt(index, key.t), dumbbellAt(index, key.t), heroHeight, label)
						local place = Framing.PLACE[key.shot.place or "center"]
						if #subjects == 1 and place ~= 0 then
							local x = Framing.project(eye, look, fov, aspect, { subjects[1].feet[1], 0, subjects[1].feet[3] })
							check(x * place > 0, label .. " subject on its third")
						end
						shots += 1

						-- Halfway to the next key of the same subjects (both re-solved, then blended).
						if nextKey and nextKey.shot and not nextKey.cut and nextKey.shot.subjects == key.shot.subjects then
							local tm = (key.t + nextKey.t) / 2
							local state = castAt(index, tm)
							local s1 = subjectsOf(key.shot, state, heroHeight)
							local e1, l1, f1 = Framing.solve(s1, key.shot, aspect)
							local e2, l2, f2 = Framing.solve(s1, nextKey.shot, aspect)
							local function mid(a, b)
								return { (a[1] + b[1]) / 2, (a[2] + b[2]) / 2, (a[3] + b[3]) / 2 }
							end
							checkFrame(mid(e1, e2), mid(l1, l2), (f1 + f2) / 2, aspect, s1, label .. " midway")
						end
					end
				end
			end
		end
	end
	check(shots >= 15 * 12, "every beat frames its subjects (" .. shots .. " checks)")

	-- A caption is on screen within 0.3 s of every beat starting (a new line, or the
	-- previous beat's line still showing).
	local showing = false
	for _, beat in Timeline.BEATS do
		local first = beat.captions[1]
		check(showing or (first ~= nil and first.t <= 0.3 and first.key ~= nil), beat.name .. " caption within 0.3 s")
		for _, c in beat.captions do
			showing = c.key ~= nil
		end
	end

	-- Placement maths: a lone subject on the left third lands left of centre at 16:9.
	local eye, look, fov = Framing.solve({ { feet = { 0, 0, 0 }, height = 5 } }, { subjects = { "Hero" }, place = "left" }, 16 / 9)
	local x = Framing.project(eye, look, fov, 16 / 9, { 0, 2.5, 0 })
	near(x, -1 / 3, "left third")
end)

-- Hero avatar ------------------------------------------------------------------------
-- src/client/Intro/AvatarRig.luau: the pure maths that lets Poses drive the player's
-- real R15 avatar in the intro. A synthetic R15 joint table stands in for the avatar.

do
	local CF = roblox.CFrame
	local V3 = roblox.Vector3
	local avatarPath = "src/client/Intro/AvatarRig.luau"
	local AvatarRig = luau.load(fs.readFile(avatarPath), { debugName = avatarPath, environment = robloxEnv() })()
	local Poses = loadShared("Poses")
	local RigPose = loadShared("RigPose")
	-- Vector3 / CFrame are single precision.
	local function close(actual: number, expected: number, message: string?)
		check(
			math.abs(actual - expected) <= 1e-4,
			string.format("%s: expected ~%s, got %s", message or "value", tostring(expected), tostring(actual))
		)
	end

	-- name -> { centre in root-part space, size }; feet bottoms at y = -3.3.
	local BODY = {
		{ "HumanoidRootPart", V3.new(0, 0, 0), V3.new(2, 2, 1) },
		{ "LowerTorso", V3.new(0, -0.8, 0), V3.new(2, 0.4, 1) },
		{ "UpperTorso", V3.new(0, 0.2, 0), V3.new(2, 1.6, 1) },
		{ "Head", V3.new(0, 1.6, 0), V3.new(1.2, 1.2, 1.2) },
		{ "RightUpperArm", V3.new(1.5, 0.6, 0), V3.new(1, 1.2, 1) },
		{ "RightLowerArm", V3.new(1.5, -0.25, 0), V3.new(1, 0.8, 1) },
		{ "RightHand", V3.new(1.5, -0.85, 0), V3.new(1, 0.4, 1) },
		{ "LeftUpperArm", V3.new(-1.5, 0.6, 0), V3.new(1, 1.2, 1) },
		{ "LeftLowerArm", V3.new(-1.5, -0.25, 0), V3.new(1, 0.8, 1) },
		{ "LeftHand", V3.new(-1.5, -0.85, 0), V3.new(1, 0.4, 1) },
		{ "RightUpperLeg", V3.new(0.5, -1.6, 0), V3.new(1, 1.2, 1) },
		{ "RightLowerLeg", V3.new(0.5, -2.6, 0), V3.new(1, 0.8, 1) },
		{ "RightFoot", V3.new(0.5, -3.15, 0), V3.new(1, 0.3, 1) },
		{ "LeftUpperLeg", V3.new(-0.5, -1.6, 0), V3.new(1, 1.2, 1) },
		{ "LeftLowerLeg", V3.new(-0.5, -2.6, 0), V3.new(1, 0.8, 1) },
		{ "LeftFoot", V3.new(-0.5, -3.15, 0), V3.new(1, 0.3, 1) },
		{ "Handle", V3.new(0, 2.4, 0), V3.new(1.5, 0.6, 1.5) }, -- a hat
	}
	-- limb -> { parent part, joint position in root-part space }
	local JOINTS = {
		LowerTorso = { "HumanoidRootPart", V3.new(0, -0.6, 0) },
		UpperTorso = { "LowerTorso", V3.new(0, -0.6, 0) },
		Head = { "UpperTorso", V3.new(0, 1.0, 0) },
		RightUpperArm = { "UpperTorso", V3.new(1.5, 0.95, 0) },
		RightLowerArm = { "RightUpperArm", V3.new(1.5, 0, 0) },
		RightHand = { "RightLowerArm", V3.new(1.5, -0.65, 0) },
		LeftUpperArm = { "UpperTorso", V3.new(-1.5, 0.95, 0) },
		LeftLowerArm = { "LeftUpperArm", V3.new(-1.5, 0, 0) },
		LeftHand = { "LeftLowerArm", V3.new(-1.5, -0.65, 0) },
		RightUpperLeg = { "LowerTorso", V3.new(0.5, -1.0, 0) },
		RightLowerLeg = { "RightUpperLeg", V3.new(0.5, -2.2, 0) },
		RightFoot = { "RightLowerLeg", V3.new(0.5, -3.0, 0) },
		LeftUpperLeg = { "LowerTorso", V3.new(-0.5, -1.0, 0) },
		LeftLowerLeg = { "LeftUpperLeg", V3.new(-0.5, -2.2, 0) },
		LeftFoot = { "LeftLowerLeg", V3.new(-0.5, -3.0, 0) },
	}

	-- A spec like Avatar.readSpec builds: motors carry C0 / C1 (some rotated), the
	-- hat hangs off an AccessoryWeld-style weld whose Part0 is the hat.
	local function syntheticSpec(skip: string?): (any, { [string]: number }, { any })
		local parts, index, motors = {}, {}, {}
		local restOf = {}
		for i, row in BODY do
			local name = row[1]
			index[name] = i
			restOf[name] = CF.new(row[2])
			local limb = if JOINTS[name] then name else nil
			table.insert(parts, { size = row[3], limb = limb })
		end
		local edges, joints = {}, {}
		for limb, j in JOINTS do
			if limb ~= skip then
				local spin = if limb == "Head" then CF.Angles(0, math.rad(90), 0) else CF.new()
				local c0 = restOf[j[1]]:Inverse() * CF.new(j[2]) * spin
				local c1 = restOf[limb]:Inverse() * CF.new(j[2]) * spin
				table.insert(edges, { a = index[j[1]], b = index[limb], rel = c0 * c1:Inverse(), motor = true })
				joints[limb] = { part0 = index[j[1]], c0 = c0 }
				table.insert(motors, { part0 = index[j[1]], part1 = index[limb], c0 = c0, c1 = c1 })
			end
		end
		local hat, head = index.Handle, index.Head
		table.insert(edges, { a = hat, b = head, rel = restOf.Handle:Inverse() * restOf.Head })
		return { parts = parts, root = index.HumanoidRootPart, edges = edges, joints = joints }, index, motors
	end

	local function identityPose(): { [string]: any }
		local out = {}
		for _, limb in Poses.LIMBS do
			out[limb] = CF.new()
		end
		return out
	end

	-- Poses the synthetic avatar; returns world CFrames by spec index.
	local function posed(desc: any, rootCF: any, transforms: { [string]: any }): { [number]: any }
		local instances = {}
		for i in desc.rest do
			instances[i] = i
		end
		local rig = AvatarRig.rig(desc, instances, { CFrame = rootCF }, nil, 1, 0)
		local parts, cframes = RigPose.computeFrom(rig, transforms)
		local byIndex = {}
		for k, i in parts do
			byIndex[i] = cframes[k]
		end
		return byIndex
	end

	test("Hero avatar: rig description from an R15 joint table", function()
		local spec, index = syntheticSpec()
		local desc, why = AvatarRig.describe(spec, Poses.LIMBS)
		check(desc ~= nil, "describe failed: " .. tostring(why))
		local d = desc :: any
		close(d.hipY, 2.3)
		close(d.pivots.LowerTorso.Y, 2.7)
		close(d.pivots.RightUpperArm.X, 1.5)
		close(d.height, 6.0, "head top plus hat, capped")
		eq(d.owner[index.Handle], "Head", "hat follows the head")
		eq(d.owner[index.HumanoidRootPart], "LowerTorso")
		for _, limb in Poses.LIMBS do
			check(d.pivots[limb] ~= nil, "pivot " .. limb)
		end
		local broken = AvatarRig.describe((syntheticSpec("LeftLowerLeg")), Poses.LIMBS)
		check(broken == nil, "a missing joint is refused (part-built fallback)")
	end)

	test("Hero avatar: feet on the ground at rest, anywhere on the stage", function()
		local spec, index = syntheticSpec()
		local desc = AvatarRig.describe(spec, Poses.LIMBS) :: any
		local rootCF = CF.new(10, 5, -3) * CF.Angles(0, 1.1, 0)
		local world = posed(desc, rootCF, identityPose())
		for i, cf in desc.rest do
			local expect = rootCF * cf
			check((world[i].Position - expect.Position).Magnitude < 1e-4, "rest part " .. i .. " in place")
		end
		for _, foot in { "LeftFoot", "RightFoot" } do
			local low = AvatarRig.yRange(world[index[foot]], spec.parts[index[foot]].size)
			close(low, 5, foot .. " on the ground")
		end
	end)

	test("Hero avatar: limbs stay connected in every gait and story pose", function()
		local spec, index, motors = syntheticSpec()
		local desc = AvatarRig.describe(spec, Poses.LIMBS) :: any
		local rootCF = CF.new(0, 0, 0)
		for _, pose in { "Walk", "Run", "Strut", "Stand", "Flex", "Sad", "Shock" } do
			local ok, transforms = pcall(Poses.samplePose, "Chad", pose, 0.37, 3)
			check(ok, pose .. " is a pose")
			if ok then
				local world = posed(desc, rootCF, transforms)
				for _, m in motors do
					local a = (world[m.part0] * m.c0).Position
					local b = (world[m.part1] * m.c1).Position
					check((a - b).Magnitude < 1e-3, pose .. ": joint " .. m.part1 .. " stays attached")
				end
				local head, hat = index.Head, index.Handle
				local want = world[head] * (desc.rest[head]:Inverse() * desc.rest[hat])
				check((world[hat].Position - want.Position).Magnitude < 1e-3, pose .. ": hat stays on the head")
			end
		end
	end)
end

-- Client Animator budget helpers (loaded with stub services; only the pure helpers run) --

do
	local function stubChild(name: string): any
		return {
			Name = name,
			WaitForChild = function(_, child: string)
				return stubChild(child)
			end,
		}
	end
	local env = robloxEnv()
	env.game = {
		GetService = function(_, name: string)
			return stubChild(name)
		end,
	}
	env.require = function(target: any)
		return loadShared(target.Name)
	end
	env.script = stubChild("Animator")
	local okLoad, Animator = pcall(function()
		return luau.load(fs.readFile("src/client/Animator.luau"), { debugName = "Animator", environment = env })()
	end)

	test("Animator loads with stub services", function()
		check(okLoad, "loads: " .. tostring(Animator))
	end)

	if okLoad then
		test("Animator.insertNearest keeps the nearest few, sorted", function()
			local rand = seeded(7)
			for _, cap in { 1, 6, 24 } do
				local picks, keys, n = {}, {}, 0
				local all = {}
				for i = 1, 100 do
					local key = math.floor(rand() * 1000)
					table.insert(all, key)
					n = Animator.insertNearest(picks, keys, n, cap, i, key)
				end
				table.sort(all)
				eq(n, cap, "count capped")
				for k = 1, cap do
					eq(keys[k], all[k], "cap " .. cap .. " key " .. k)
					check(picks[k] ~= nil, "pick present")
				end
			end
			local picks, keys = {}, {}
			eq(Animator.insertNearest(picks, keys, 0, 0, "x", 1), 0, "zero budget takes nothing")
		end)

		test("Animator.inView culls behind, beside and keeps the view cone", function()
			local look, right, up = Vector3.new(0, 0, -1), Vector3.new(1, 0, 0), Vector3.new(0, 1, 0)
			local tanY = math.tan(math.rad(35))
			local tanX = tanY * 16 / 9
			local function seen(x: number, y: number, z: number, r: number?): boolean
				return Animator.inView(Vector3.new(x, y, z), r or 2, look, right, up, tanX, tanY)
			end
			check(seen(0, 0, -30), "straight ahead")
			check(not seen(0, 0, 30), "behind the camera")
			check(seen(0, 0, 1.5), "just behind but within its radius")
			check(not seen(200, 0, -30), "far to the right")
			check(not seen(0, -80, -30), "far below")
			check(seen(30 * tanX + 1, 0, -30), "edge of the view, inside its radius")
			check(not seen(30 * tanX + 4, 0, -30), "just past the edge")
			-- A full 100-unit rack seen from the front: every slot inside the cone.
			local inside = 0
			for row = 1, 10 do
				for col = 1, 10 do
					if seen((col - 5.5) * 5.3, 3.8 + (row - 1) * 6 - 20, -70, 2.5) then
						inside += 1
					end
				end
			end
			eq(inside, 100, "whole rack in view from 70 studs")
		end)
	end
end

-- Props: Blender meshes over part-built props --------------------------------------------
-- Server/World/Props loaded with a stub ReplicatedStorage holding the downloaded models.

do
	local function loadProps(withModels: boolean): any
		local storage = roblox.Instance.new("Folder")
		local shared = roblox.Instance.new("Folder")
		shared.Name = "Shared"
		shared.Parent = storage
		local module = roblox.Instance.new("ModuleScript")
		module.Name = "AssetModels"
		module.Parent = shared
		if withModels then
			local folder = roblox.Instance.new("Folder")
			folder.Name = "AssetModels"
			folder.Parent = storage
			for _, file in { "props__PalmPlanter", "props__Barbell" } do
				for _, inst in roblox.deserializeModel(fs.readFile("assets/models/" .. file .. ".rbxm")) do
					inst.Name = file
					inst.Parent = folder
				end
			end
		end
		local env = robloxEnv()
		env.game = {
			GetService = function()
				return storage
			end,
		}
		local assetModels = luau.load(fs.readFile("src/shared/AssetModels.luau"), { debugName = "AssetModels", environment = env })()
		env.require = function()
			return assetModels
		end
		return luau.load(fs.readFile("src/server/World/Props.luau"), { debugName = "Props", environment = env })()
	end

	-- A part-built Prop_<kind>: PropRoot at `root` plus one 2-stud-tall solid block.
	local function fallbackProp(kind: string, root: any): any
		local model = roblox.Instance.new("Model")
		model.Name = "Prop_" .. kind
		model:SetAttribute("Mesh", kind)
		local base = roblox.Instance.new("Part")
		base.Name = "PropRoot"
		base.CFrame = root
		base.Transparency = 1
		base.CanCollide = false
		base.Parent = model
		model.PrimaryPart = base
		local body = roblox.Instance.new("Part")
		body.Name = "Body"
		body.Size = Vector3.new(2, 2, 2)
		body.CFrame = root * CFrame.new(0, 1, 0)
		body.Parent = model
		return model
	end

	test("Props: mesh replaces the part-built prop", function()
		local Props = loadProps(true)
		local world = roblox.Instance.new("Folder")
		local root = CFrame.new(10, 3, -4) * CFrame.Angles(0, math.rad(90), 0)
		local planter = fallbackProp("PalmPlanter", root)
		planter.Parent = world
		local barbell = fallbackProp("Barbell", root)
		barbell:SetAttribute("MeshScale", 1)
		barbell.Body.CanCollide = false
		barbell.Parent = world
		eq(Props.apply(world), 2, "models swapped")

		local mesh = planter:FindFirstChild("PalmPlanterMesh")
		check(mesh ~= nil and mesh:IsA("MeshPart"), "planter mesh")
		check(planter:FindFirstChild("Body") == nil, "fallback parts removed")
		check(planter:FindFirstChild("PropRoot") ~= nil, "PropRoot kept")
		eq(planter.Name, "Prop_PalmPlanter", "model keeps its name")
		check(mesh.CanCollide == false and mesh.CanQuery == false, "mesh never collides or queries")
		check(planter:FindFirstChild("PropCollider") ~= nil, "solid fallback gets a collider")
		-- Height matches the part-built version (2 studs); the pot (ANCHOR) stands on the root.
		check(math.abs(mesh.Size.Y - 2) < 1e-3, "height matched")
		local pot = Props.anchor("PalmPlanter") * (mesh.Size.Y / Props.size("PalmPlanter").Y) - Vector3.new(0, mesh.Size.Y / 2, 0)
		check((mesh.CFrame:PointToObjectSpace(root.Position) - pot).Magnitude < 1e-4, "pot base on the root")
		check(cframeNear(mesh.CFrame.Rotation, root.Rotation, 1e-5), "same facing as the root")

		local bar = barbell:FindFirstChild("BarbellMesh")
		check(bar ~= nil, "barbell mesh")
		check(math.abs(bar.Size.Y - Props.size("Barbell").Y) < 1e-3, "MeshScale keeps the authored size")
		check(barbell:FindFirstChild("PropCollider") == nil, "walk-through fallback gets no collider")
		eq(Props.apply(world), 0, "applying twice changes nothing")
	end)

	test("Props: missing models keep the part-built prop", function()
		local Props = loadProps(false)
		local world = roblox.Instance.new("Folder")
		local planter = fallbackProp("PalmPlanter", CFrame.new())
		planter.Parent = world
		eq(Props.apply(world), 0, "nothing swapped")
		check(planter:FindFirstChild("Body") ~= nil, "fallback kept")
		check(Props.mesh("PalmPlanter", CFrame.new()) == nil, "no mesh")
		check(not Props.has("Crate"), "has() false")
	end)
end

test("Name plates: glow grows with tier and steps up at band changes", function()
	local path = "src/client/Fx/PlateStyle.luau"
	local PlateStyle = luau.load(fs.readFile(path), { debugName = path, environment = robloxEnv() })()
	local bands = Economy.TIER_BANDS
	local prev = PlateStyle.compute(1, bands)
	eq(prev.band, "Common")
	eq(prev.halo, 0, "Common has no halo")
	check(not prev.shimmer and not prev.light, "Common is quiet")
	local inBandStep, bandStep = 0, math.huge
	for tier = 2, Economy.MAX_TIER do
		local style = PlateStyle.compute(tier, bands)
		eq(style.band, Economy.tierBand(tier), "band of tier " .. tier)
		check(style.level > prev.level, "level rises at tier " .. tier)
		check(style.scale > prev.scale, "scale rises at tier " .. tier)
		check(style.brightness > prev.brightness, "brightness rises at tier " .. tier)
		check(style.halo >= prev.halo, "halo never drops at tier " .. tier)
		local step = style.brightness - prev.brightness
		if style.band ~= prev.band then
			bandStep = math.min(bandStep, step)
			check(style.halo > prev.halo, "halo steps up into " .. style.band)
		else
			inBandStep = math.max(inBandStep, step)
		end
		prev = style
	end
	check(bandStep > inBandStep, "band changes step up more than tiers inside a band")
	local top = PlateStyle.compute(Economy.MAX_TIER, bands)
	check(top.cycle and top.sparkles and top.light and top.shimmer, "top band has every effect")
	local champ = PlateStyle.compute(3, bands, true)
	check(champ.champion and champ.cycle and champ.sparkles and champ.light, "champion gets top effects")
	check(champ.halo >= top.halo and champ.scale >= top.scale, "champion is at least top-band strong")
	eq(champ.band, "Common", "champion keeps its own band name")
	-- Readability: cream plates with one Ink text colour for the low bands, Ink plates with
	-- bright text from Epic; the far gem glows only for the top bands and the champion.
	local common = PlateStyle.compute(1, bands)
	check(not common.dark and #common.text == 1, "Common is a cream plate with Ink text")
	check(PlateStyle.compute(16, bands).dark, "Epic is an Ink plate")
	check(not PlateStyle.compute(15, bands).gemGlow and top.gemGlow, "only the top bands' gems glow")
	check(champ.dark and champ.gemGlow, "champion wears the top band's plate and gem")
end)

test("Aura Surge mood: the grade follows the server clock, easing in and out", function()
	local path = "src/client/Fx/Surge.luau"
	local Surge = luau.load(fs.readFile(path), { debugName = path, environment = robloxEnv() })()
	local cycle, duration = Economy.SURGE_CYCLE, Economy.SURGE_DURATION
	local start = cycle - duration
	local function weightAt(now: number): number
		local active, left = Economy.surgeState(now)
		return Surge.weight(active, left, duration, cycle)
	end
	eq(weightAt(start - 30), 0, "no look long before the surge")
	eq(weightAt(start), 0, "the look starts from nothing")
	local half = weightAt(start + Surge.FADE_IN / 2)
	check(half > 0.2 and half < 0.8, "half way through the ease-in: " .. half)
	check(weightAt(start + Surge.FADE_IN * 0.25) < half, "the ease-in rises")
	eq(weightAt(start + Surge.FADE_IN), 1, "full look after the ease-in")
	eq(weightAt(start + duration / 2), 1, "a mid-surge join gets the full look at once")
	eq(weightAt(cycle * 3 + start + 40), 1, "in any cycle")
	check(weightAt(cycle - 0.01) == 1, "full look up to the last moment")
	local out = weightAt(cycle + Surge.FADE_OUT / 2)
	check(out > 0.2 and out < 0.8, "half way through the ease-out: " .. out)
	eq(weightAt(cycle + Surge.FADE_OUT), 0, "gone after the ease-out")
	eq(weightAt(cycle + 60), 0, "normal play is untouched")

	local none = Surge.grade(0, 1.3)
	for _, key in { "tint", "saturation", "contrast", "brightness", "bloom", "rays", "sparkles" } do
		eq(none[key], 0, "no " .. key .. " at weight 0")
	end
	local low, high = math.huge, -math.huge
	for k = 0, 200 do
		local g = Surge.grade(1, k * 0.05)
		low, high = math.min(low, g.saturation), math.max(high, g.saturation)
		eq(g.contrast, Surge.CONTRAST, "full contrast")
	end
	check(low > 0.15 and high < 0.35, "saturation pulses gently around +0.25")
	check(high - low > 0.05 and high - low <= 0.12, "the pulse is visible but small")
	check(Surge.PULSE_PERIOD >= 1.5, "the pulse is slow (no strobing)")
end)

-- Game modes ---------------------------------------------------------------------------
-- The plaza catalog, the GameModes registry, Parkour reward / run rules and the course
-- geometry (pure data in src/server/Modes).

local MODES_DIR = "src/server/Modes/"
local ModesCourse = luau.load(fs.readFile(MODES_DIR .. "Course.luau"), { debugName = "Course" })()
local ModesCatalog = luau.load(fs.readFile(MODES_DIR .. "Catalog.luau"), { debugName = "Catalog" })()
local ModesRules = luau.load(fs.readFile(MODES_DIR .. "Rules.luau"), {
	debugName = "Rules",
	environment = setmetatable({
		script = { Parent = { Course = ModesCourse } },
		require = function(module)
			return module
		end,
	}, { __index = _G }),
})()

local function loadGameModes(): any
	local services = {
		Players = {},
		Workspace = {},
		ReplicatedStorage = { Shared = { Net = {} } },
	}
	local env = setmetatable({
		game = {
			GetService = function(_, name)
				return services[name]
			end,
		},
		script = { Parent = { Modes = { Catalog = ModesCatalog, Course = ModesCourse, Parkour = {} } } },
		require = function(module)
			return module
		end,
	}, { __index = _G })
	local path = "src/server/GameModes.luau"
	return luau.load(fs.readFile(path), { debugName = path, environment = env })()
end

test("Game modes: catalog and registry shape", function()
	local theme = loadRobloxTheme("src/themes/chad/Theme.luau")
	local ids, slots, enabled = {}, {}, 0
	for _, entry in ModesCatalog do
		check(type(entry.id) == "string" and not ids[entry.id], "unique id " .. tostring(entry.id))
		ids[entry.id] = true
		check(ModesCourse.GATES[entry.slot] ~= nil and not slots[entry.slot], "free gate slot for " .. entry.id)
		slots[entry.slot] = true
		check(type(entry.title) == "string" and entry.title ~= "" and type(entry.blurb) == "string", entry.id .. " has text")
		check(theme.World[entry.color] ~= nil, entry.id .. " colour is a Theme.World key")
		if entry.enabled then
			enabled += 1
		end
	end
	check(enabled >= 1 and ids.parkour, "parkour is in the catalog")

	local GameModes = loadGameModes()
	local running = {}
	local function def(id: string): any
		return {
			id = id,
			start = function(player)
				running[player] = id
				return true
			end,
			stop = function(player)
				running[player] = nil
			end,
			running = function(player)
				return running[player] == id
			end,
			tick = function() end,
			snapshot = function()
				return { running = false }
			end,
			rewardPreview = function()
				return { cash = 0, gems = 0 }
			end,
		}
	end
	GameModes.register(def("parkour"))
	local parkour = GameModes.get("parkour")
	eq(parkour.title, "PARKOUR", "title comes from the catalog")
	eq(parkour.slot, 1, "slot comes from the catalog")
	eq(parkour.enabled, true, "enabled comes from the catalog")
	check(not pcall(GameModes.register, def("nope")), "unknown ids are refused")
	eq(#GameModes.list(), 1, "one registered mode")
	local player = {}
	eq(GameModes.start(player, "missing", true), false, "unknown mode refused")
	eq(GameModes.start(player, "parkour", true), true, "parkour starts")
	eq(GameModes.active(player), parkour, "active mode")
	eq(GameModes.snapshot(player).parkour.running, false, "snapshot keyed by id")
	GameModes.stop(player, "quit")
	eq(GameModes.active(player), nil, "stopped")
end)

test("Game modes: finish reward is sized like a cash pack, with a cooldown", function()
	local theme = loadRobloxTheme("src/themes/chad/Theme.luau")
	-- Its own constants (the retired 5-minute cash pack), not a shop pack.
	local pack = theme.Modes.Reward
	eq(pack.Seconds, 300, "mode reward seconds")
	eq(pack.Min, 750, "mode reward minimum")
	local cooldown = Economy.MODE_REWARD_COOLDOWN
	eq(cooldown, 1800, "30 minute cooldown")
	local prev = 0
	for tier = 1, Economy.MAX_TIER do
		local progression = Economy.progression(tier, tier * 3)
		local r = Economy.modeReward(0, progression, pack.Seconds, pack.Min, false, 0, 10 ^ 9)
		eq(r.cash, Economy.moneyPackAmount(0, pack.Seconds, pack.Min, progression), "same amount as the shop at tier " .. tier)
		check(r.full and r.cash >= prev, "reward never drops as progression grows (tier " .. tier .. ")")
		prev = r.cash
	end
	local progression = Economy.progression(8, 10)
	local live = Economy.modeReward(1e6, progression, pack.Seconds, pack.Min, false, 0, 10 ^ 9)
	eq(live.cash, Economy.moneyPackAmount(1e6, pack.Seconds, pack.Min, progression), "live income counts like in the shop")
	local now = 1e9
	local first = Economy.modeReward(0, progression, pack.Seconds, pack.Min, true, now - 5, now)
	check(first.full, "first finish always pays the full pack")
	eq(first.gems, Economy.MODE_FIRST_CLEAR_GEMS, "first finish pays Rizz")
	local early = Economy.modeReward(0, progression, pack.Seconds, pack.Min, false, now - cooldown + 1, now)
	check(not early.full and early.cash == 0 and early.packCash > 0, "inside the cooldown a finish pays no cash")
	eq(early.gems, 0, "Rizz only on the first finish")
	local later = Economy.modeReward(0, progression, pack.Seconds, pack.Min, false, now - cooldown, now)
	check(later.full and later.cash == later.packCash, "full pack again after the cooldown")
end)

test("Game modes: checkpoints in order and plausible times, per level", function()
	eq(ModesCourse.LEVEL_COUNT, 10, "ten parkour levels")
	eq(#ModesCourse.LEVELS, ModesCourse.LEVEL_COUNT, "every level is built")
	for i, level in ModesCourse.LEVELS do
		local count = level.CHECKPOINT_COUNT
		check(count >= 3 and count <= 8, "level " .. i .. ": 3-8 checkpoints")
		for k = 1, count + 1 do
			check(level.MIN_LEG_SECONDS[k] > 0, "level " .. i .. " leg " .. k .. " has a minimum time")
		end
		local fast = ModesRules.newRun(0, level)
		for k = 1, count do
			ModesRules.touchCheckpoint(fast, k, k * 0.1)
		end
		local ok, reason = ModesRules.finish(fast, count * 0.1 + 0.1)
		check(not ok and reason == "fast", "level " .. i .. ": impossibly fast runs earn nothing")
		local fair = ModesRules.newRun(0, level)
		for k = 1, count do
			ModesRules.touchCheckpoint(fair, k, k * 30)
		end
		local okFair, time = ModesRules.finish(fair, count * 30 + 30)
		check(okFair and time == count * 30 + 30, "level " .. i .. ": a normal run finishes")
	end
	local run = ModesRules.newRun(100, ModesCourse.LEVELS[2])
	eq(ModesRules.touchCheckpoint(run, 2, 101), "skip", "skipping ahead does nothing")
	eq(run.checkpoint, 0, "still at the start")
	eq(ModesRules.touchCheckpoint(run, 1, 110), "ok", "first checkpoint")
	eq(ModesRules.touchCheckpoint(run, 1, 111), "old", "same checkpoint again")
	local ok, reason = ModesRules.finish(run, 200)
	check(not ok and reason == "checkpoints", "finish needs every checkpoint")
	local list = {}
	eq(ModesRules.recordBest(list, 1, "A", 50, 3), 1, "first time ranks 1")
	eq(ModesRules.recordBest(list, 2, "B", 40, 3), 1, "faster ranks first")
	eq(ModesRules.recordBest(list, 1, "A", 60, 3), 2, "a slower repeat keeps the old time")
	eq(#list, 2, "one entry per player")
end)

test("Game modes: profile defaults and per-level parkour records", function()
	local DataService = loadDataService()
	eq(DataService.PARKOUR_LEVELS, ModesCourse.LEVEL_COUNT, "profile arrays match the level count")
	local profile = DataService.defaultProfile()
	local fresh = profile.modes.parkour
	check(fresh.best == 0 and fresh.clears == 0 and fresh.lastRewardAt == 0, "new profiles have no parkour record")
	eq(#profile.parkour.best, 10, "dense best array")
	eq(#profile.parkour.clears, 10, "dense clears array")
	eq(DataService.reconcile({ money = 1 }).modes.parkour.best, 0, "old saves get the record")
	local bad = DataService.reconcile({ money = 1, modes = { parkour = { best = "x", clears = -2, lastRewardAt = 5 } } })
	check(bad.modes.parkour.best == 0 and bad.modes.parkour.clears == 0, "bad values are reset")
	eq(bad.modes.parkour.lastRewardAt, 5, "good values stay")
	check(bad.parkour.best[1] == 0 and bad.parkour.clears[1] == 0, "bad old values do not migrate")
	local old = DataService.reconcile({ money = 1, modes = { parkour = { best = 42.5, clears = 3, lastRewardAt = 0 } } })
	eq(old.modes.parkour.best, 42.5)
	eq(old.parkour.best[1], 42.5, "old best migrates to level 1")
	eq(old.parkour.clears[1], 3, "old clears migrate to level 1")
	eq(old.parkour.best[2], 0, "other levels start empty")
	local holes = DataService.reconcile({ money = 1, parkour = { best = { 30, "x", -1, 0 / 0 }, clears = { 2, 1 } } })
	eq(#holes.parkour.best, 10, "short arrays are padded")
	check(
		holes.parkour.best[1] == 30 and holes.parkour.best[2] == 0 and holes.parkour.best[3] == 0 and holes.parkour.best[4] == 0,
		"bad entries reset"
	)
	eq(holes.parkour.clears[2], 1, "good entries stay")
	eq(#DataService.reconcile({ money = 1, parkour = "x" }).parkour.clears, 10, "a broken record is rebuilt")
	eq(Economy.parkourLevelBonus(1), 1, "level 1 pays the plain pack")
	check(math.abs(Economy.parkourLevelBonus(10) - 2.8) < 1e-9, "level 10 pays 2.8x")
	for n = 2, 10 do
		check(Economy.parkourLevelBonus(n) > Economy.parkourLevelBonus(n - 1), "harder levels pay more")
	end
end)

-- Edge-to-edge horizontal distance between two path elements (box, disc, or a point).
local function shapeGap(a: any, ax: number, az: number, b: any, bx: number, bz: number): number
	local function half(e: any): (number, number, number)
		if e.shape == "box" then
			return e.sx / 2, e.sz / 2, 0
		end
		return 0, 0, e.r or 0
	end
	local ahx, ahz, ar = half(a)
	local bhx, bhz, br = half(b)
	local dx = math.max(0, math.abs(ax - bx) - ahx - bhx)
	local dz = math.max(0, math.abs(az - bz) - ahz - bhz)
	return math.sqrt(dx * dx + dz * dz) - ar - br
end

test("Game modes: maxGap matches the default jump", function()
	local flat = ModesCourse.maxGap(0)
	check(flat > 7.7 and flat < 8, "flat reach about 8.6 minus the margin (" .. flat .. ")")
	check(ModesCourse.maxGap(5) < flat and ModesCourse.maxGap(5) > 5, "a 5 stud step shortens the reach")
	eq(ModesCourse.maxGap(-20), ModesCourse.MAX_GAP, "drops are capped")
	check(ModesCourse.maxGap(8) < 0, "8 studs up is out of reach")
end)

test("Game modes: every level's jumps are fair with the default jump", function()
	local gravity = 196.2
	local function poses(e: any, steps: number): { { number } }
		if e.kind ~= "mover" then
			return { { e.x, e.y, e.z } }
		end
		local out = {}
		for s = -1, 1, 2 / steps do
			local d = e.distance * s
			table.insert(out, { e.x + e.axis[1] * d, e.y + e.axis[2] * d, e.z + e.axis[3] * d })
		end
		return out
	end
	for li, level in ModesCourse.LEVELS do
		local path = level.PATH
		local bounceOn, bounces = {}, 0
		for _, e in level.ELEMENTS do
			if e.kind == "bounce" then
				for i, p in path do
					if
						p.shape == "box"
						and math.abs(e.x - p.x) <= p.sx / 2
						and math.abs(e.z - p.z) <= p.sz / 2
						and math.abs(p.y - e.y) < 0.01
					then
						bounceOn[i] = e.power * e.power / (2 * gravity) - 3
						bounces += 1
					end
				end
			elseif e.kind == "blink" then
				check(e.on >= 1.2 and e.on < e.period and e.path, "level " .. li .. ": blink pads stay solid long enough")
			end
		end
		check(bounces >= 1, "level " .. li .. ": the bounce pad sits on a path deck")
		for i = 1, #path - 1 do
			local a, b = path[i], path[i + 1]
			local label = string.format("level %d path %d -> %d", li, i, i + 1)
			check(not (a.kind == "blink" and b.kind == "blink"), label .. ": never two blink pads in a row")
			if a.kind == "slide" or b.kind == "slide" then
				local ramp = if a.kind == "slide" then a else b
				local other = if a.kind == "slide" then b else a
				local endPoint = if a.kind == "slide" then ramp.to else ramp.from
				local gap = shapeGap({ shape = "point" }, endPoint[1], endPoint[3], other, other.x, other.z)
				check(gap <= 1.5, label .. ": slide end meets its deck (" .. gap .. ")")
				check(math.abs(endPoint[2] - other.y) <= 0.5, label .. ": slide end is level with its deck")
			else
				-- After a bounce pad the jump apex is the launch apex (less 3 studs, as above).
				local jump = bounceOn[i]
				local best, worst, overlap = math.huge, -math.huge, false
				for _, pa in poses(a, 16) do
					for _, pb in poses(b, 16) do
						local gap = shapeGap(a, pa[1], pa[3], b, pb[1], pb[3])
						local up = pb[2] - pa[2]
						local reach = ModesCourse.maxGap(up, jump)
						local maxUp = bounceOn[i] or ModesCourse.MAX_STEP_UP
						if up <= maxUp and gap <= reach then
							best = math.min(best, gap)
						end
						worst = math.max(worst, gap - reach)
						if gap < 0.5 then
							overlap = true
						end
					end
				end
				check(best < math.huge, string.format("%s: jumpable at its best phase", label))
				if level.remote then
					check(worst <= 1e-6, string.format("%s: jumpable at every phase (%.2f over)", label, worst))
				end
				check(not overlap, label .. ": platforms never overlap or touch")
				if a.kind ~= "mover" and b.kind ~= "mover" then
					check(b.y - a.y <= (bounceOn[i] or ModesCourse.MAX_STEP_UP), label .. ": step up within reach")
				end
			end
			if a.kind ~= "slide" then
				check(not ModesCourse.inWater(a.x, a.y, a.z), label .. ": platform top is above the water line")
			end
		end
		local last = path[#path]
		check(
			last.name == "FinishDeck" and ModesCourse.inFinish(level, last.x, last.y, last.z),
			"level " .. li .. ": finish deck ends the path"
		)
		check(not ModesCourse.inWater(last.x, last.y, last.z), "level " .. li .. ": finish deck is dry")
		check(ModesCourse.inBounds(level, last.x, last.y, last.z), "level " .. li .. ": finish inside the bounds")
		local arch = level.FINISH_ARCH
		local prev = path[#path - 1]
		check((prev.x - arch.x) * arch.faceX + (prev.z - arch.z) * arch.faceZ > 0, "level " .. li .. ": the arch faces the runner")
		for k = 0, level.CHECKPOINT_COUNT do
			local at, look = ModesCourse.respawn(level, k)
			check(
				math.abs(look[1] * look[1] + look[2] * look[2] - 1) < 1e-6,
				"level " .. li .. " respawn " .. k .. " faces along the course"
			)
			check(not ModesCourse.inWater(at[1], at[2], at[3]), "level " .. li .. " respawn " .. k .. " is dry")
			check(ModesCourse.inBounds(level, at[1], at[2], at[3]), "level " .. li .. " respawn " .. k .. " is inside the bounds")
		end
		check(level.remote, "level " .. li .. " is reached by teleport")
		check(type(level.name) == "string" and #level.name > 0 and level.difficulty == li, "level " .. li .. " has a name and difficulty")
		for _, key in { "main", "alt", "checkpoint", "mover", "accent", "blink" } do
			check(type(level.palette[key]) == "string", "level " .. li .. " palette " .. key)
		end
	end
	local a1, b1 = ModesCourse.generate(5), ModesCourse.generate(5)
	check(#a1.ELEMENTS == #b1.ELEMENTS and a1.ELEMENTS[9].x == b1.ELEMENTS[9].x, "generation is deterministic")
	check(ModesCourse.crossedStart(ModesCourse.START_LINE_X + 1, ModesCourse.START_LINE_X - 1, 0), "walking west through gate 1 starts")
	check(not ModesCourse.crossedStart(ModesCourse.START_LINE_X - 1, ModesCourse.START_LINE_X + 1, 0), "walking back out does not")
end)

test("Game modes: each level is harder than the last", function()
	-- +1: bigger is harder; -1: smaller is harder.
	local knobs = {
		gap = 1,
		discR = -1,
		beamW = -1,
		padSize = -1,
		checkpointR = -1,
		moverTravel = 1,
		moverPeriod = -1,
		spinSpeed = 1,
		spinBars = 1,
		checkpointEvery = 1,
		pathLength = 1,
		rise = 1,
		blinkOn = -1,
	}
	for n = 3, ModesCourse.LEVEL_COUNT do
		local a, b = ModesCourse.LEVELS[n - 1].TUNING, ModesCourse.LEVELS[n].TUNING
		local tighter = 0
		for key, sign in knobs do
			local va = a[key] or (if sign < 0 then math.huge else 0)
			local vb = b[key] or (if sign < 0 then math.huge else 0)
			check(va == vb or (vb - va) * sign > 0, string.format("level %d does not loosen %s", n, key))
			if va ~= vb and (vb - va) * sign > 0 then
				tighter += 1
			end
		end
		check(tighter >= 1, "level " .. n .. " tightens something")
		check(#ModesCourse.LEVELS[n].PATH > #ModesCourse.LEVELS[n - 1].PATH, "level " .. n .. " is longer")
	end
	check(ModesCourse.LEVELS[4].TUNING.blinkOn ~= nil and ModesCourse.LEVELS[3].TUNING.blinkOn == nil, "blink pads from level 4")
end)

test("Game modes: parkour regions stay clear of the island, props and each other", function()
	local avoid = {
		{ 583, 212, 55 + 40 },
		{ 179, 841, 42 + 40 },
		{ -429, 360, 36 + 40 },
		{ -714, -260, 60 + 40 },
		{ -155, -580, 44 + 40 },
		{ 669, -602, 50 + 40 },
		{ 0, 400, 110 },
		{ 0, 0, 262 },
	}
	local function rectCircle(r: any, cx: number, cz: number): number
		local dx = math.max(r.x0 - cx, 0, cx - r.x1)
		local dz = math.max(r.z0 - cz, 0, cz - r.z1)
		return math.sqrt(dx * dx + dz * dz)
	end
	local function rectRect(a: any, b: any): number
		local dx = math.max(a.x0 - b.x1, 0, b.x0 - a.x1)
		local dz = math.max(a.z0 - b.z1, 0, b.z0 - a.z1)
		return math.sqrt(dx * dx + dz * dz)
	end
	-- The plaza and its gates: no level may come near them (the course is portal-only).
	local plazaBox = { x0 = -230, x1 = -118, z0 = -40, z1 = 40 }
	for i = 1, ModesCourse.LEVEL_COUNT do
		local r = ModesCourse.REGIONS[i]
		check(r == ModesCourse.LEVELS[i].BOUNDS, "region " .. i .. " is the level's bounds")
		for _, c in avoid do
			check(rectCircle(r, c[1], c[2]) >= c[3], string.format("region %d clears (%d, %d)", i, c[1], c[2]))
		end
		check(rectRect(r, plazaBox) >= 30, "region " .. i .. " clears the plaza")
		for _, x in { r.x0, r.x1 } do
			for _, z in { r.z0, r.z1 } do
				check(x * x + z * z <= 900 * 900, "region " .. i .. " is within 900 studs")
			end
		end
		for j = i + 1, ModesCourse.LEVEL_COUNT do
			check(rectRect(r, ModesCourse.REGIONS[j]) >= 30, string.format("regions %d and %d are 30 studs apart", i, j))
		end
		for _, e in ModesCourse.LEVELS[i].ELEMENTS do
			check(ModesCourse.inBounds(ModesCourse.LEVELS[i], e.x, e.y, e.z), "level " .. i .. " elements inside its bounds")
		end
	end
end)

-- Mog Test rules (tests/mog.luau).
require("./mog")({ test = test, check = check, eq = eq, near = near, seeded = seeded })

test("progression curve keeps its shape (scripts/simulate, no passes, coarse)", function()
	(_G :: any).SIMULATE_AS_LIBRARY = true
	local Simulate = require("../scripts/simulate")
	local theme = loadRobloxTheme("src/themes/chad/Theme.luau")
	local pack = theme.Modes.Reward
	eq(Simulate.SMALL_PACK_SECONDS, pack.Seconds, "simulated parkour reward uses the mode reward's seconds")
	eq(Simulate.SMALL_PACK_MIN, pack.Min, "simulated parkour reward uses the mode reward's minimum")

	local reached = Simulate.run({ hours = 3, step = 5 }).reached
	check(reached[2] ~= nil and reached[2] <= 60, "tier 2 within the first minute")
	check(reached[6] ~= nil and reached[6] >= 25 * 60 and reached[6] <= 60 * 60, "tier 6 after 25 to 60 minutes")
	check(reached[10] == nil, "tier 10 not before 3 hours")
end)

test("loading screen brand matches the theme and assets", function()
	local Brand = require("../src/loader/Brand")
	local theme = loadRobloxTheme("src/themes/chad/Theme.luau")
	local Assets = loadShared("Assets")
	eq(Brand.GameName, theme.GameName, "Brand.GameName")
	eq(Brand.Tagline, theme.Tagline, "Brand.Tagline")
	eq(Brand.Loading.Status, theme.Loading.Status, "Brand.Loading.Status")
	eq(Brand.KeyArt, Assets.Images["brand/KeyArt"], "Brand.KeyArt")
	eq(Brand.Logo, Assets.Images["brand/Logo"], "Brand.Logo")
end)

print(string.format("\n%d passed, %d failed", passed, failed))
if failed > 0 then
	process.exit(1)
end
