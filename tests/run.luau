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
local ParkourMoves = require("../src/shared/ParkourMoves")

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
	check(Economy.MID_TIER_RATE_GROWTH > Economy.MERGE_RATIO, "merging mid tiers must increase production too")
	check(Economy.LATE_TIER_RATE_GROWTH > Economy.MERGE_RATIO, "and late tiers")
	near(Economy.unitRate(3), Economy.TIER_RATE_GROWTH ^ 2, "tier 3 rate")
	near(Economy.unitRate(Economy.FAST_TIERS), Economy.TIER_RATE_GROWTH ^ (Economy.FAST_TIERS - 1), "the fast tiers grow 3x")
	near(
		Economy.unitRate(Economy.MID_TIERS),
		Economy.unitRate(Economy.FAST_TIERS) * Economy.MID_TIER_RATE_GROWTH ^ (Economy.MID_TIERS - Economy.FAST_TIERS),
		"the mid tiers grow 2.7x"
	)
	near(
		Economy.unitRate(Economy.MID_TIERS + 2),
		Economy.unitRate(Economy.MID_TIERS) * Economy.LATE_TIER_RATE_GROWTH ^ 2,
		"the late tiers grow 2.4x"
	)

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
	for _, start in { 0, 3, 77, 5000 } do
		for _, amount in Economy.BUY_AMOUNTS do
			local sum = 0
			for k = 0, amount - 1 do
				sum += Economy.unitPrice(start + k)
			end
			near(Economy.bulkPrice(start, amount), sum, string.format("bulk start %d x%d", start, amount))
		end
		check(Economy.unitPrice(start + 1) > Economy.unitPrice(start), "price grows from " .. start)
	end
end)

test("buy pricing: a new player's easy units", function()
	local easy, req, base = Economy.BUY_EASY_UNITS, Economy.BUY_EASY_REQ, Economy.BUY_BASE_PRICE
	near(Economy.unitPrice(0), base, "the first unit costs the base price")
	near(Economy.unitPrice(req), 2 * base, "an easy unit adds 1 / BUY_EASY_REQ of the base")
	local last = Economy.unitPrice(easy)
	near(last, base * (1 + easy / req), "price once the easy units are bought")
	-- After them every purchase adds the whole base price again, as before the easy units.
	near(Economy.unitPrice(easy + 1) - last, base, "normal growth after the easy units")
	near(Economy.unitPrice(easy + 7) - last, 7 * base, "normal growth keeps going")
	-- Every batch equals its single purchases, across the boundary too.
	for _, start in { 0, easy - 3, easy - 1, easy, easy + 4 } do
		for _, amount in Economy.BUY_AMOUNTS do
			local sum = 0
			for k = 0, amount - 1 do
				local n = start + k
				sum += base * (1 + math.min(n, easy) / req + math.max(0, n - easy))
			end
			near(Economy.bulkPrice(start, amount), sum, string.format("easy bulk start %d x%d", start, amount))
		end
	end
	-- All of them together are an early-game sum.
	local all = Economy.bulkPrice(0, easy)
	near(all, base * (easy + easy * (easy - 1) / 2 / req), "price of every easy unit")
	check(all < Economy.unitValue(9), "the easy units are an early-game sum")
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
	-- Every level is 25% faster and always costs 50 seconds of the converter's own output.
	for _, level in { 0, 8, 39, 112, 150 } do
		near(Economy.processRate(level + 1) / Economy.processRate(level), 1.25, "+25% speed at level " .. level)
		near(Economy.processUpgradeCost(level) / Economy.processRate(level), 50, "50 s of output at level " .. level)
	end
	eq(Economy.CONVERTER_HEADROOM, 4, "upgrades stop at 4x the production")
end)

test("converter floor: a new tier never outruns the converter", function()
	eq(Economy.minProcessLevel(1), 0, "no floor below the base rate")
	eq(Economy.minProcessLevel(2), 0, "tier 2 is covered by the base rate")
	eq(Economy.minProcessLevel(10), 38, "floor of tier 10")
	eq(Economy.minProcessLevel(0), 0, "tiers are clamped (low)")
	eq(Economy.minProcessLevel(99), Economy.minProcessLevel(Economy.MAX_TIER), "tiers are clamped (high)")
	local rack = table.create(Economy.MAX_TIER, 0)
	for tier = 1, Economy.MAX_TIER do
		local floor = Economy.minProcessLevel(tier)
		check(floor >= 0 and floor == math.floor(floor), "floor is a whole level at tier " .. tier)
		check(Economy.processRate(floor) >= Economy.unitRate(tier), "floor covers one unit of tier " .. tier)
		if floor > 0 then
			check(Economy.processRate(floor - 1) < Economy.unitRate(tier), "floor is the lowest such level at tier " .. tier)
		end
		if tier > 3 then
			local step = floor - Economy.minProcessLevel(tier - 1)
			check(step == 4 or step == 5, "about 5 free levels per tier at " .. tier)
		end
		-- The most a merged rack makes (one unit of every tier up to the best) is under 2x
		-- the floor's rate, so an un-upgraded converter passes at least half of it.
		rack[tier] = 1
		local production = Economy.productionPerSecond(rack)
		check(production <= 2 * Economy.processRate(floor), "never short by more than 2x at tier " .. tier)
		check(Economy.incomePerSecond(production, Economy.processRate(floor), 1) >= production / 2, "half the income at tier " .. tier)
	end
	-- A profile's level is lifted to the floor of its best tier and never lowered.
	eq(math.max(16, Economy.minProcessLevel(10)), 38, "level lifted to the floor of the best tier")
	eq(math.max(150, Economy.minProcessLevel(Economy.MAX_TIER)), 150, "a level above every floor is kept")
	-- The start level covers the first three tiers; the floor takes over from tier 4.
	check(Economy.START_PROCESS_LEVEL >= Economy.minProcessLevel(3), "start level covers tier 3")
	check(Economy.START_PROCESS_LEVEL < Economy.minProcessLevel(4), "tier 4 brings the first free levels")
end)

test("deposit multiplier", function()
	local rng = seeded(42)
	local seen = {}
	local sum, rolls = 0, 10000
	for _ = 1, rolls do
		local m = Economy.rollDepositMultiplier(rng)
		check(m >= Economy.DEPOSIT_MIN and m <= Economy.DEPOSIT_MAX, "multiplier in range " .. m)
		check(m >= 1, "a deposit never loses aura " .. m)
		seen[m] = true
		sum += m
	end
	eq(Economy.DEPOSIT_MIN, 1, "the lowest multiplier is x1")
	check(seen[1.0] == true and seen[3.0] == true, "covers the neutral and the top value")
	check(sum / rolls >= 1.10 and sum / rolls <= 1.20, "mean multiplier about 1.15 (" .. sum / rolls .. ")")
	local lowest, highest = math.huge, 0
	for _, entry in Economy.DEPOSIT_MULTIPLIERS do
		lowest, highest = math.min(lowest, entry.value), math.max(highest, entry.value)
	end
	eq(lowest, Economy.DEPOSIT_MIN, "DEPOSIT_MIN matches the table")
	eq(highest, Economy.DEPOSIT_MAX, "DEPOSIT_MAX matches the table")
	eq(
		Economy.rollDepositMultiplier(function()
			return 0
		end),
		1.0,
		"roll 0 gives first entry"
	)
	eq(
		Economy.rollDepositMultiplier(function()
			return 0.999999
		end),
		3.0,
		"roll ~1 gives last entry"
	)
	-- The aura carried is queued whole; only the part above x1 is the bonus (paid as cash).
	local queued, bonus = Economy.depositSplit(100, 1)
	eq(queued, 100, "x1 queues everything")
	eq(bonus, 0, "x1 has no bonus")
	queued, bonus = Economy.depositSplit(100, 1.5)
	eq(queued, 100, "x1.5 queues the aura carried")
	near(bonus, 50, "x1.5 pays half as a bonus")
	queued, bonus = Economy.depositSplit(100, 3)
	near(queued + bonus, 300, "queue and bonus add up to the multiplied deposit")
	queued, bonus = Economy.depositSplit(100, 0.5)
	eq(queued, 100, "a multiplier below 1 takes nothing away")
	eq(bonus, 0, "a multiplier below 1 pays no bonus")
	queued, bonus = Economy.depositSplit(0, 3)
	eq(queued + bonus, 0, "nothing carried, nothing paid")
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
			-- Highest 10 anchors crates at tier 7.
			local tier = Economy.rollChest(rarity, 10, rng)
			check(tier >= 5 and tier <= 10, "roll near the crate anchor")
		end
		check(Economy.unlockSeconds(rarity, true) < Economy.unlockSeconds(rarity, false), "premium is faster")
	end
	-- One to five minutes in the free Smasher; a profile's very first crate is faster still.
	for index, seconds in { 60, 120, 180, 240, 300 } do
		eq(Economy.unlockSeconds(Economy.CHEST_RARITIES[index], false), seconds, Economy.CHEST_RARITIES[index] .. " timer")
	end
	eq(Economy.FIRST_CRATE_SECONDS, 10, "first crate timer")
	check(Economy.FIRST_CRATE_SECONDS < Economy.unlockSeconds("Common", true), "the first crate beats every timer")
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
	eq(Economy.chestAnchor(3), 3)
	eq(Economy.chestAnchor(5), 4)
	eq(Economy.chestAnchor(10), 7)
	eq(Economy.chestAnchor(17), 12)
	eq(Economy.chestAnchor(25), 17)
	for highest = 2, 25 do
		check(Economy.chestAnchor(highest) <= highest, "anchor at or below highest at " .. highest)
		check(Economy.chestAnchor(highest) >= Economy.chestAnchor(highest - 1), "anchor never drops at " .. highest)
	end
	-- Rarer crates give visibly better units: Common and Uncommon stay anchored below the
	-- highest tier, Rare one tier up, Epic and Legendary follow the highest tier itself.
	-- No crate gives more than one tier past the highest (a merge of two of the best).
	local function lowest(rarity: string, highest: number): number
		return Economy.chestOdds(rarity, highest)[1].tier
	end
	local function top(rarity: string, highest: number): number
		local odds = Economy.chestOdds(rarity, highest)
		return odds[#odds].tier
	end
	local function main(rarity: string, highest: number): number
		local best = Economy.chestOdds(rarity, highest)[1]
		for _, entry in Economy.chestOdds(rarity, highest) do
			if entry.chance > best.chance then
				best = entry
			end
		end
		return best.tier
	end
	eq(Economy.chestCap(1), 2)
	eq(Economy.chestCap(10), 11)
	eq(Economy.chestCap(25), 25, "never past the last tier")
	for highest = 1, 25 do
		local cap = Economy.chestCap(highest)
		for _, rarity in Economy.CHEST_RARITIES do
			local total = 0
			for _, entry in Economy.chestOdds(rarity, highest) do
				total += entry.chance
				check(entry.tier >= 1 and entry.tier <= cap, rarity .. " never skips past the next tier at " .. highest)
			end
			eq(total, 100, rarity .. " odds sum at highest " .. highest)
		end
		check(top("Common", highest) <= highest, "common never above highest at " .. highest)
		local anchor = math.max(Economy.chestAnchor(highest), 2)
		check(main("Rare", highest) == math.min(anchor + 1, cap), "rare is mostly the anchor's next tier at " .. highest)
		check(top("Rare", highest) <= anchor + 2, "rare stays near the anchor at " .. highest)
		-- Each rarity's window starts at or above the one below, and is worth at least as much.
		local prevValue, prevLowest = 0, 0
		for _, rarity in Economy.CHEST_RARITIES do
			local value = Economy.chestExpectedValue(rarity, highest)
			check(value >= prevValue, rarity .. " worth at least the rarity below at " .. highest)
			check(lowest(rarity, highest) >= prevLowest, rarity .. " starts no lower than the rarity below at " .. highest)
			prevValue, prevLowest = value, lowest(rarity, highest)
		end
		-- A Legendary is a real payoff: at least 3 tiers above a Common crate's main tier
		-- (as far as the cap allows) and close to the player's best at every stage.
		local lead = math.min(main("Common", highest) + 3, cap)
		check(lowest("Legendary", highest) >= lead, "legendary well above a common at " .. highest)
		check(lowest("Legendary", highest) >= highest - 3, "legendary near the best tier at " .. highest)
		check(lowest("Epic", highest) >= highest - 4, "epic near the best tier at " .. highest)
		check(lowest("Legendary", highest) > top("Rare", highest) - 1, "legendary above the rare window at " .. highest)
		if highest <= 10 then
			check(top("Legendary", highest) >= highest, "early legendary reaches the best tier at " .. highest)
		end
	end
	-- The report's case: highest 4 used to open a Legendary on tier 3 or 4; now it is the next tier.
	eq(#Economy.chestOdds("Legendary", 4), 1)
	eq(lowest("Legendary", 4), 5, "highest 4: a Legendary brings tier 5")
	eq(lowest("Legendary", 10), 9)
	eq(top("Legendary", 10), 10, "highest 10: Legendary 9..10")
	eq(lowest("Epic", 10), 8)
	eq(top("Epic", 10), 9, "highest 10: Epic 8..9")
	eq(lowest("Rare", 10), 7)
	eq(top("Rare", 10), 9, "highest 10: Rare 7..9")
	-- The last tiers are days apart at half an hour a day: there crates lag further behind.
	eq(lowest("Legendary", 15), 13)
	eq(top("Legendary", 15), 14, "highest 15: Legendary 13..14")
	eq(lowest("Legendary", 25), 22)
	eq(top("Legendary", 25), 23, "highest 25: Legendary 22..23")
	eq(lowest("Epic", 25), 21)
	eq(top("Epic", 25), 22, "highest 25: Epic 21..22")
	-- Rarer is always better: the unit value a Smasher makes per second of its timer rises
	-- with the rarity, so a rare crate is never a worse use of the slot than a common one
	-- (from highest 4: below it the cap folds Epic and Legendary onto the next tier).
	for highest = 4, 25 do
		for _, premium in { false, true } do
			local prevPerSecond = 0
			for _, rarity in Economy.CHEST_RARITIES do
				local perSecond = Economy.chestExpectedValue(rarity, highest) / Economy.unlockSeconds(rarity, premium)
				check(perSecond > prevPerSecond, rarity .. " beats the rarity below per Smasher second at " .. highest)
				prevPerSecond = perSecond
			end
		end
	end
	-- Early game stays fair: a common crate is a tier 1, a rare one at most tier 2.
	local early = Economy.chestOdds("Common", 1)
	eq(#early, 1)
	eq(early[1].tier, 1)
	eq(early[1].chance, 100)
	local earlyRare = Economy.chestOdds("Rare", 1)
	eq(earlyRare[1].tier, 2)
	eq(earlyRare[#earlyRare].tier, 2)

	local common = Economy.chestOdds("Common", 6)
	eq(common[1].tier, 3)
	eq(common[1].chance, 75)
	eq(common[3].tier, 5)
	eq(common[3].chance, 5)

	local rng = seeded(99)
	local counts = {}
	for _ = 1, 20000 do
		local r = Economy.rollChestRarity(rng)
		counts[r] = (counts[r] or 0) + 1
	end
	check((counts.Common or 0) > (counts.Uncommon or 0), "common most frequent")
	check((counts.Legendary or 0) < (counts.Epic or 0), "legendary rarest")
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
	local lastFloor = 0
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
	end
	-- The shop and the receipt handler size packs with the same shared functions.
	for _, path in { "src/server/Monetization.luau", "src/client/UI/Windows.luau" } do
		local src = fs.readFile(path)
		for _, fn in { "Economy.progression(", "Economy.moneyPackAmount(", "Economy.auraPackAmount(" } do
			check(string.find(src, fn, 1, true) ~= nil, path .. " uses " .. fn)
		end
		check(string.find(src, "pack.Amount", 1, true) == nil, path .. " has no fixed pack amount")
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

test("tutorial: the deposit step is converted at once", function()
	for step = 1, TutorialSteps.DONE do
		local current = TutorialSteps.get(step)
		eq(TutorialSteps.instantDeposit(step, false), current ~= nil and current.id == "deposit", "step " .. step)
		eq(TutorialSteps.instantDeposit(step, true), false, "never after the tutorial, step " .. step)
	end
	-- The deposit itself moves the tutorial on, so only one deposit is ever instant.
	local deposit = 0
	for index, step in TutorialSteps.STEPS do
		if step.id == "deposit" then
			deposit = index
		end
	end
	eq(TutorialSteps.instantDeposit(TutorialSteps.onEvent(deposit, "Deposit"), false), false, "the next deposit queues")
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
		eq(theme.Monetization.GemPacks, nil, "no Rizz packs")
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
		for _, list in { "MoneyPacks", "AuraPacks", "LegacyMoneyPacks" } do
			for index, pack in theme.Monetization[list] do
				check(pack.Id ~= 0 and not seen[pack.Id], list .. " id unique " .. index)
				seen[pack.Id] = true
			end
		end
		check(not seen[theme.Monetization.CrateOpen.Id], "crate product id unique")
		check(type(theme.Modes.Reward.Seconds) == "number" and theme.Modes.Reward.Min > 0, "mode reward")
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
	-- cash cannot open crates and there is no Rizz any more.
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
		check((Economy :: any).finishGemCost == nil, "smashers cannot be finished with Rizz")
		check(theme.Words.Gem == nil and theme.Icons.Gem == nil, "no Rizz currency")
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

test("plot layout: plot size and pen", function()
	-- A roomy plot: about a quarter wider and deeper than the first, compact one (half 42).
	check(Layout.PLOT_HALF >= 50 and Layout.PLOT_HALF <= 54, "roomy plot")
	check(Layout.INNER_HALF >= Layout.PLOT_HALF - 3, "thin fences")
	-- The rack still stands against the back fence, the gutter and pen right in front of it.
	check(Layout.INNER_HALF - Layout.MACHINES.Shelves.maxZ <= 2, "rack against the back fence")
	near(Layout.GUTTER.rect.maxZ, Layout.SHELF.frontZ, "gutter at the foot of the rack")
	near(Layout.SHELF.frontZ - Layout.PEN.interior.maxZ, 6, "pen keeps its place in front of the rack")
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
	for _, name in { "AutoMerge", "Merge", "Deposit", "ProcUp1", "ProcUp10", "Collect", "Unlock1", "Unlock2", "Free" } do
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
	for _, name in { "Unlock1", "Unlock2", "Free" } do
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

test("plot layout: courts, plaza and interactive props", function()
	local P = Layout.PADS
	local line = Layout.COURT_LINE
	local onCourt: { [string]: string } = {}
	local courtNames = {}
	for name, court in Layout.COURTS do
		table.insert(courtNames, name)
		check(insidePlot(court), name .. " court inside the walls")
		check(court.maxX - court.minX >= 6 and court.maxZ - court.minZ >= 6, name .. " court is a real area")
		local members = Layout.COURT_MEMBERS[name]
		check(members ~= nil, name .. " court lists its members")
		-- Every pad base and machine stands inside its court's border line.
		local inner = Layout.rect(court.minX + line, court.maxX - line, court.minZ + line, court.maxZ - line)
		for _, padName in members.pads do
			check(onCourt[padName] == nil, padName .. " stands on one court")
			onCourt[padName] = name
			local rim = Layout.padRect(P[padName], Layout.PAD_RIM)
			check(
				rim.minX >= inner.minX and rim.maxX <= inner.maxX and rim.minZ >= inner.minZ and rim.maxZ <= inner.maxZ,
				padName .. " inside the " .. name .. " court"
			)
		end
		for _, machine in members.machines do
			local r = Layout.MACHINES[machine]
			check(r ~= nil, "court machine exists: " .. machine)
			check(
				r.minX >= inner.minX and r.maxX <= inner.maxX and r.minZ >= inner.minZ and r.maxZ <= inner.maxZ,
				machine .. " inside the " .. name .. " court"
			)
		end
	end
	-- Every pad but Merge has a court; Merge has its own round one.
	for _, name in Layout.PAD_ORDER do
		check((onCourt[name] ~= nil) == (name ~= "Merge"), name .. " has its court")
	end
	for name in Layout.MACHINES do
		if name ~= "Shelves" then
			local found = false
			for _, members in Layout.COURT_MEMBERS do
				found = found or table.find(members.machines, name) ~= nil
			end
			check(found, name .. " stands on a court")
		end
	end
	-- Courts keep a sand joint between them and never run under the pen walls sideways or the rack.
	for i, a in courtNames do
		for j = i + 1, #courtNames do
			check(not Layout.overlaps(Layout.COURTS[a], Layout.COURTS[courtNames[j]], 1), a .. " and " .. courtNames[j] .. " courts apart")
		end
	end
	for _, name in { "Cash", "Crates" } do
		local court = Layout.COURTS[name]
		check(not Layout.overlaps(court, Layout.POOL), name .. " court beside the pen")
		check(not Layout.overlaps(court, Layout.WALKWAY), name .. " court off the walkway")
		for _, zone in Layout.FAN_ZONES do
			check(not Layout.overlaps(court, zone.rect), name .. " court clear of the fan zones")
		end
	end
	near(Layout.COURTS.Cash.minX, -Layout.COURTS.Crates.maxX, "side courts mirror each other")
	near(Layout.COURTS.Cash.maxX, -Layout.COURTS.Crates.minX, "side courts mirror each other")
	near(Layout.COURTS.Cash.minZ, Layout.COURTS.Crates.minZ, "side courts mirror each other")
	near(Layout.COURTS.Cash.maxZ, Layout.COURTS.Crates.maxZ, "side courts mirror each other")
	check(not Layout.overlaps(Layout.COURTS.Buy, Layout.GUTTER.rect), "buy court in front of the gutter")
	for _, zone in Layout.FAN_ZONES do
		check(not Layout.overlaps(Layout.COURTS.Buy, zone.rect), "buy court clear of the fan zones")
	end

	-- The round merge court covers the merge pad's base and stays in front of the pen.
	local merge = Layout.MERGE_COURT
	local rim = Layout.padRect(P.Merge, Layout.PAD_RIM)
	local corner = math.sqrt((rim.maxX - merge.x) ^ 2 + (rim.maxZ - merge.z) ^ 2)
	check(merge.x == P.Merge.x and merge.z == P.Merge.z, "merge court centred on the merge pad")
	check(merge.radius - line >= corner, "merge court covers the pad base")
	check(merge.z + merge.radius < Layout.POOL.minZ, "merge court in front of the pen")
	check(merge.radius < Layout.COURTS.Crates.minX, "merge court clear of the side courts")

	-- The plaza joins both side courts in front of the pen; only the merge pad stands on it.
	local plaza = Layout.PLAZA
	near(plaza.minX, Layout.COURTS.Cash.maxX, "plaza reaches the -X court")
	near(plaza.maxX, Layout.COURTS.Crates.minX, "plaza reaches the +X court")
	check(plaza.maxZ < Layout.POOL.minZ and plaza.minZ >= Layout.WALKWAY.maxZ - 4, "plaza along the pen's front")
	check(Layout.contains(plaza, P.Merge.x, P.Merge.z), "merge pad on the plaza")
	for _, name in Layout.PAD_ORDER do
		if name ~= "Merge" then
			check(not Layout.overlaps(plaza, Layout.padRect(P[name], Layout.PAD_RIM)), name .. " off the plaza")
		end
	end
	for name, rect in layoutObstacles() do
		check(not Layout.overlaps(plaza, rect), "plaza clear of " .. name)
	end

	-- Interactive props: four of them, each mat on free floor off the courts and the spawn view.
	local obstacles = layoutObstacles()
	local kinds = {}
	for kind, spot in Layout.INTERACTIVE do
		table.insert(kinds, kind)
		local r = Layout.rect(spot.x - spot.radius, spot.x + spot.radius, spot.z - spot.radius, spot.z + spot.radius)
		check(spot.radius >= 3, kind .. " mat is big enough to stand on")
		check(insidePlot(r), kind .. " inside the walls")
		check(math.abs(spot.x) - spot.radius >= 15, kind .. " off the spawn view")
		check(not Layout.overlaps(r, Layout.WALKWAY), kind .. " off the walkway")
		check(not Layout.overlaps(r, plaza), kind .. " off the plaza")
		for name, court in Layout.COURTS do
			check(not Layout.overlaps(r, court), kind .. " off the " .. name .. " court")
		end
		for name, rect in obstacles do
			check(not Layout.overlaps(r, rect), kind .. " clear of " .. name)
		end
		for _, name in Layout.PAD_ORDER do
			check(not Layout.overlaps(r, Layout.padRect(P[name], Layout.PAD_RIM)), kind .. " clear of " .. name)
		end
		for _, zone in Layout.FAN_ZONES do
			check(not Layout.overlaps(r, zone.rect), kind .. " clear of the fan zones")
		end
	end
	check(#kinds == 4, "four interactive props")
	-- The bench press mirrors the punch bag across the entrance path.
	eq(Layout.INTERACTIVE.Bench.x, -Layout.INTERACTIVE.PunchBag.x, "bench mirrors the punch bag")
	eq(Layout.INTERACTIVE.Bench.z, Layout.INTERACTIVE.PunchBag.z, "bench in the punch bag's row")
	for i, a in kinds do
		for j = i + 1, #kinds do
			local sa, sb = Layout.INTERACTIVE[a], Layout.INTERACTIVE[kinds[j]]
			local d = math.sqrt((sa.x - sb.x) ^ 2 + (sa.z - sb.z) ^ 2)
			check(d >= sa.radius + sb.radius + 1, a .. " and " .. kinds[j] .. " mats apart")
		end
	end

	-- Each machine stands right behind its own pad(s): at most 4 studs of floor between them.
	local function gap(a: Layout.Rect, b: Layout.Rect): number
		local dx = math.max(0, a.minX - b.maxX, b.minX - a.maxX)
		local dz = math.max(0, a.minZ - b.maxZ, b.minZ - a.maxZ)
		return math.sqrt(dx * dx + dz * dz)
	end
	local stations = {
		Converter = { "Deposit" },
		Processor = { "ProcUp1", "ProcUp10" },
		Vault = { "Collect" },
		Unlocker1 = { "Unlock1" },
		Unlocker2 = { "Unlock2" },
	}
	for machine, padNames in stations do
		for _, padName in padNames do
			local g = gap(Layout.MACHINES[machine], Layout.padRect(P[padName], Layout.PAD_RIM))
			check(g <= 4, padName .. " right in front of the " .. machine)
		end
	end
	-- The stations mirror each other across the centre line, row by row.
	near(P.Unlock1.x, -P.ProcUp1.x, "back stations mirror")
	near(P.Unlock1.z, P.Deposit.z, "back stations level")
	near(P.Unlock2.z, (P.ProcUp1.z + P.ProcUp10.z) / 2, "middle stations level")
	-- The deposit pad, the first stop after merging, is level with the plaza.
	check(P.Deposit.z > plaza.minZ and P.Deposit.z < plaza.maxZ, "deposit pad level with the plaza")
	-- Open floor round the pen: the side courts stand well clear of its walls and stairs.
	for _, stair in Layout.PEN_STAIRS do
		for _, name in { "Cash", "Crates" } do
			check(not Layout.overlaps(Layout.COURTS[name], stair.rect, 6), name .. " court well clear of the pen stairs")
		end
	end
	near(P.Free.z, P.Collect.z, "front stations level")
	near(P.Free.x, -P.Collect.x, "front stations mirror")
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
		ReplicatedStorage = {
			Shared = {
				Economy = Economy,
				Funnel = require("../src/shared/Funnel"),
				SessionLock = SessionLock,
				TutorialSteps = TutorialSteps,
			},
		},
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
end)

test("new player start: cash, converter and tutorial reward", function()
	local DataService = loadDataService()
	local fresh = DataService.defaultProfile()
	eq(fresh.money, Economy.START_CASH, "starting cash")
	eq(fresh.processLevel, Economy.START_PROCESS_LEVEL, "starting converter level")
	-- The first Buy 1 leaves cash for a second unit, and the tutorial reward buys a few more.
	check(Economy.START_CASH >= Economy.bulkPrice(0, 2) - Economy.unitPrice(1), "cash for the first unit")
	check(Economy.START_CASH - Economy.unitPrice(0) > 0, "cash left after the first unit")
	check(Economy.TUTORIAL_REWARD_CASH >= Economy.bulkPrice(1, 3), "the reward buys three more units")
	eq(Economy.START_PROCESS_LEVEL, 8, "start level")
	-- The converter covers one unit of every tier at that tier's free floor.
	for tier = 1, Economy.MAX_TIER do
		check(Economy.processRate(Economy.minProcessLevel(tier)) >= Economy.unitRate(tier), "converter floor covers tier " .. tier)
	end
	-- Old saves are lifted to the starting level; higher levels are kept.
	eq(DataService.reconcile({ money = 10, processLevel = 3 }).processLevel, Economy.START_PROCESS_LEVEL, "low level lifted")
	eq(DataService.reconcile({ money = 10, processLevel = 40 }).processLevel, 40, "high level kept")
end)

test("Economy 2.0 migration: a save only gains", function()
	local DataService = loadDataService()
	eq(DataService.VERSION, 3, "profile version")
	local function discoveredTo(best: number): { number }
		local discovered = table.create(Economy.MAX_TIER, 0)
		for tier = 1, best do
			discovered[tier] = 1700000000 + tier
		end
		return discovered
	end
	-- The converter level is lifted to the free floor of the best discovered tier, never lowered.
	local lifted = DataService.reconcile({ money = 10, bought = 5, processLevel = 16, discovered = discoveredTo(10) })
	eq(lifted.processLevel, 38, "level 16 with best tier 10 becomes 38")
	eq(lifted.processLevel, Economy.minProcessLevel(10), "which is the floor of tier 10")
	local high = DataService.reconcile({ money = 10, bought = 5, processLevel = 150, discovered = discoveredTo(10) })
	eq(high.processLevel, 150, "level 150 stays 150")
	eq(DataService.reconcile({ money = 10, processLevel = 150, discovered = discoveredTo(25) }).processLevel, 150, "even at the last tier")
	eq(
		DataService.reconcile({ money = 10, processLevel = 16, discovered = discoveredTo(3) }).processLevel,
		16,
		"a level above the floor is kept"
	)
	eq(DataService.reconcile(lifted).processLevel, 38, "migrating twice changes nothing")

	-- A version-2 save keeps everything it has.
	local units = table.create(Economy.MAX_TIER, 0)
	units[3] = 4
	units[9] = 2
	units[10] = 1
	local saved = {
		version = 2,
		money = 123456,
		carried = 77,
		queue = 8900,
		pending = 120,
		units = table.clone(units),
		discovered = discoveredTo(10),
		totalObtained = 612,
		bought = 550,
		processLevel = 46,
		heldChest = "Rare",
		unlockers = { { rarity = "Epic", endsAt = 1900000000 }, { rarity = "Common", endsAt = 1900000500 } },
		autoMergeOwned = true,
		autoMerge = true,
		totalEarned = 987654,
		tutorialDone = true,
		introSeen = true,
		onboarding = 99,
		parkour = { best = { 31.5, 40 }, clears = { 2, 1 }, stage = 3, stageMaps = true, gear = "jump" },
		modes = { parkour = { best = 31.5, clears = 3, lastRewardAt = 1700000000 } },
	}
	local kept = DataService.reconcile(saved)
	eq(kept.version, DataService.VERSION, "the save is now the current version")
	for _, key in { "money", "carried", "queue", "pending", "totalObtained", "bought", "processLevel", "heldChest", "totalEarned" } do
		eq(kept[key], saved[key], key .. " is kept")
	end
	eq(kept.autoMergeOwned, true, "the cash-bought Auto Merge is kept")
	eq(kept.autoMerge, true, "and stays switched on")
	for tier = 1, Economy.MAX_TIER do
		eq(kept.units[tier], units[tier], "units of tier " .. tier)
		eq(kept.discovered[tier], if tier <= 10 then 1700000000 + tier else 0, "discovery of tier " .. tier)
	end
	eq(kept.unlockers[1].rarity, "Epic", "Smasher slot 1 keeps its crate")
	eq(kept.unlockers[1].endsAt, 1900000000, "and its end time")
	eq(kept.unlockers[2].rarity, "Common", "Smasher slot 2 keeps its crate")
	eq(kept.unlockers[2].endsAt, 1900000500, "and its end time")
	eq(kept.parkour.best[1], 31.5, "parkour records are kept")
	eq(kept.parkour.clears[2], 1, "parkour clears are kept")
	eq(kept.parkour.stage, 3, "the sky obby stage is kept")
	eq(kept.modes.parkour.lastRewardAt, 1700000000, "the reward cooldown is kept")
	eq(kept.firstCrateDone, true, "an existing player waits the normal time for crates")
	local production = Economy.productionPerSecond(kept.units)
	check(Economy.processRate(kept.processLevel) >= Economy.unitRate(10), "the kept level covers the best unit")
	check(production > 0, "the rack still produces")

	-- The first-crate head start is for brand-new profiles only.
	eq(DataService.defaultProfile().firstCrateDone, false, "a new profile has not opened a crate")
	eq(DataService.reconcile(nil).firstCrateDone, false, "nor has a blank save")
	eq(DataService.reconcile({ money = 10, bought = 3 }).firstCrateDone, true, "a save that bought units is not new")
	eq(DataService.reconcile({ money = 10, totalObtained = 4 }).firstCrateDone, true, "nor is one that owned units")
	eq(DataService.reconcile({ money = 10, bought = 3, firstCrateDone = false }).firstCrateDone, false, "a saved flag is kept")
	eq(DataService.reconcile({ money = 10, firstCrateDone = "x" }).firstCrateDone, false, "a broken flag on an unplayed save resets")
	-- The Smasher path shows by itself for a profile's first crates only.
	eq(DataService.defaultProfile().cratesHeld, 0, "a new profile has held no crate")
	eq(DataService.reconcile({ money = 10, bought = 3 }).cratesHeld, Economy.CRATE_GUIDE_HOLDS, "an existing player knows the way")
	eq(DataService.reconcile({ money = 10, bought = 3, cratesHeld = 1 }).cratesHeld, 1, "a saved count is kept")

	-- Parkour: a skipped map is saved next to best / clears (dense, 0 or 1).
	local fresh = DataService.defaultProfile()
	eq(#fresh.parkour.skipped, DataService.PARKOUR_LEVELS, "one skipped entry per map")
	eq(#kept.parkour.skipped, DataService.PARKOUR_LEVELS, "old saves get the list")
	for level = 1, DataService.PARKOUR_LEVELS do
		eq(fresh.parkour.skipped[level], 0, "nothing skipped on a new profile")
		eq(kept.parkour.skipped[level], 0, "nothing skipped on an old save")
	end
	local skips =
		DataService.reconcile({ money = 1, parkour = { best = {}, clears = {}, skipped = { 1, 0, "x", 5, -1, 0 / 0 }, stageMaps = true } })
	eq(skips.parkour.skipped[1], 1, "a skip is kept")
	eq(skips.parkour.skipped[2], 0, "an unskipped map stays unskipped")
	eq(skips.parkour.skipped[3], 0, "junk is dropped")
	eq(skips.parkour.skipped[4], 1, "a skip is 0 or 1")
	eq(skips.parkour.skipped[5], 0, "negative is dropped")
	eq(skips.parkour.skipped[6], 0, "NaN is dropped")
	eq(DataService.reconcile(skips).parkour.skipped[1], 1, "and survives another load")
end)

test("Tycoon pads: no Robux prompt from walking, upgrade pads need a stop", function()
	local source = fs.readFile("src/server/Tycoon.luau")
	local function has(text: string): boolean
		return string.find(source, text, 1, true) ~= nil
	end
	-- Pass prompts come from the client's buttons (PromptPass, the Settings switch) only.
	check(not has('promptPass(session.player, "PremiumUnlocker")'), "the VIP Smasher pad opens no pass prompt")
	local _, autoMergePrompts = string.gsub(source, 'promptPass%(session%.player, "AutoMerge"%)', "")
	eq(autoMergePrompts, 1, "Auto Merge is prompted from the Settings switch only")
	check(has("PAD_DWELL = { ProcUp1 = 0.6, ProcUp10 = 0.6 }"), "the upgrade pads fire after a 0.6 s stop")
	check(has("Economy.CONVERTER_HEADROOM * Economy.productionPerSecond(p.units)"), "upgrades are refused past the headroom")
	check(has("Economy.depositSplit(p.carried, mult)"), "the deposit bonus is split off as cash")
	check(has("Economy.minProcessLevel(newest)"), "a new tier lifts the converter for free")
	check(has("return Economy.highestTier(session.profile.discovered)"), "crates and goals follow the best tier found")
	check(has("return mult * (1 + bonus)"), "the cash multiplier is the passes, friends and Premium")
end)

-- One notion of "best tier": the highest one discovered. Every reward sized by progression
-- reads it, like the amounts the client shows (the snapshot's highestTier).
test("rewards and the goal strip read the best tier found", function()
	local sized = {
		"src/server/Monetization.luau",
		"src/server/Cosmetics.luau",
		"src/server/Daily.luau",
		"src/server/Modes/Parkour.luau",
		"src/server/Modes/Mog.luau",
		"src/server/Modes/Cardio.luau",
		-- GameModes.modeReward prices the solo mini-games.
		"src/server/GameModes.luau",
	}
	for _, path in sized do
		local src = fs.readFile(path)
		check(string.find(src, "Economy.progression(Economy.highestTier(p", 1, true) ~= nil, path .. " sizes a reward by tier")
		check(string.find(src, "discovered), p", 1, true) ~= nil, path .. " sizes it by the best tier found")
	end
	-- The plot's rank, its champion and its crowd go by the best unit on the rack.
	local rank = fs.readFile("src/client/Fx/PlotRank.luau")
	check(string.find(rank, "local best = PlotRank.bestTier(rec.folder)", 1, true) ~= nil, "PlotRank reads the rack")
	check(string.find(rank, "syncDressing(rec, best)", 1, true) ~= nil, "the dressing goes by it")
	check(string.find(rank, "syncChampion(rec, best)", 1, true) ~= nil, "and so does the pedestal")
	check(string.find(fs.readFile("src/client/Fx/Fans.luau"), "PlotRank.bestTier(rec.folder)", 1, true) ~= nil, "fans go by the same tier")
	-- The goal strip lets NextGoal do the sums.
	local hud = fs.readFile("src/client/UI/Hud.luau")
	check(string.find(hud, "indexClaimed = claimed", 1, true) ~= nil, "the goal strip sends the claimed Index milestones")
	check(string.find(hud, 'picked.kind == "index"', 1, true) ~= nil, "the goal strip has a line for an Index reward")
	check(string.find(hud, 'goalTrack.Visible = picked.kind ~= "done"', 1, true) ~= nil, "and no bar once nothing is left")
	check(string.find(hud, "fill your rack", 1, true) == nil, "it never asks for a full rack")
	check(
		string.find(hud, "picked.mergeReady", 1, true) ~= nil and string.find(hud, "picked.percent", 1, true) ~= nil,
		"it uses NextGoal's sums"
	)
end)

test("Smasher slots: a saved crate gets its whole timer on load", function()
	local DataService = loadDataService()
	-- Smasher slots saved before the whole timer was kept get one on load, so the progress
	-- ring fills steadily to the saved end time (which is never changed).
	local now = os.time()
	local slots = DataService.reconcile({
		money = 1,
		unlockers = { { rarity = "Legendary", endsAt = now + 4000 }, { rarity = "Common", endsAt = now + 5 } },
	}).unlockers
	eq(slots[1].endsAt, now + 4000, "the end time is kept")
	check(slots[1].seconds >= 3999 and slots[1].seconds <= 4000, "a long old timer: the time left is the whole ring")
	eq(slots[2].seconds, Economy.unlockSeconds("Common", true), "a short one: the rarity's timer")
	eq(
		DataService.reconcile({ money = 1, unlockers = { { rarity = "Rare", endsAt = now + 50, seconds = 60 } } }).unlockers[1].seconds,
		60,
		"a saved timer is kept"
	)
	eq(DataService.reconcile({ money = 1 }).unlockers[1].seconds, nil, "an empty slot has none")
	local again = DataService.reconcile({ money = 1, unlockers = { { rarity = "Legendary", endsAt = now + 4000, seconds = 4000 } } })
	eq(again.unlockers[1].seconds, 4000, "and it does not shrink on the next load")
end)

test("NextGoal: one merge step, the real percent and what is left at the top tier", function()
	local NextGoal = loadShared("NextGoal")
	local function input(best: number, units: { number }, claimed: { number }?): any
		local discovered = table.create(Economy.MAX_TIER, 0)
		for tier = 1, Economy.MAX_TIER do
			discovered[tier] = if tier <= best then 1 else 0
		end
		local owned = table.create(Economy.MAX_TIER, 0)
		for tier, n in units do
			owned[tier] = n
		end
		return { discovered = discovered, units = owned, indexClaimed = claimed }
	end
	local function nameOf(tier: number): string
		return "T" .. tier
	end

	-- mergeReady: one step on the merge pad reaches the tier, pair or no pair.
	local goal = NextGoal.pick(input(3, { 2, 1, 1 }))
	check(goal.mergeReady, "2 x T1 + T2 + T3 merge up to a T4")
	check(not goal.ready, "though the T3 pair is not on the rack")
	eq(goal.percent, 100, "100% when one step does it")
	eq(goal.missing, 0, "nothing left to buy")
	eq(goal.seconds, 0, "and no wait")
	eq(select(4, NextGoal.text(goal, nameOf)), "100%", "the text carries the percent")
	-- The server agrees: a full merge makes the tier.
	local units = input(3, { 2, 1, 1 }).units
	Economy.mergeAll(units)
	eq(units[4], 1, "mergeAll makes the T4")
	goal = NextGoal.pick(input(3, { 1, 1, 1 }))
	check(not goal.mergeReady, "one T1 short")
	eq(goal.missing, 1, "one more T1")
	eq(goal.percent, 87, "7/8 of the way is 87%, not rounded up")
	eq(select(4, NextGoal.text(goal, nameOf)), "87%", "percent text")
	eq(NextGoal.pick(input(12, { [12] = 1, [11] = 1, [1] = 1023 })).percent, 99, "never 100% while a unit is missing")
	check(NextGoal.pick(input(1, { 2 })).mergeReady, "a plain pair is ready too")
	eq(NextGoal.pick(input(1, { 1 })).percent, 50, "half way")
	-- Every rack agrees with the server's count and with a real merge.
	local rng = seeded(7)
	for _ = 1, 300 do
		local best = 1 + math.floor(rng() * 12)
		local rack: { number } = {}
		for tier = 1, best do
			rack[tier] = math.floor(rng() * 3)
		end
		local picked = NextGoal.pick(input(best, rack))
		local owned = input(best, rack).units
		eq(picked.missing, Economy.unitsToNextTier(owned, best), "missing matches the snapshot's nextTierUnits")
		Economy.mergeAll(owned)
		eq(picked.mergeReady, owned[best + 1] > 0, "mergeReady matches a real merge")
		check(picked.percent < 100 or picked.mergeReady, "100% only when ready")
	end

	-- The time estimate (the snapshot's bought, money, pending, rewardIncome).
	local timed = input(10, { [10] = 1 })
	timed.bought, timed.money, timed.pending, timed.income = 600, 1000, 500, 250
	goal = NextGoal.pick(timed)
	eq(goal.missing, 512, "half a pair of T10 is 512 T1")
	near(goal.seconds :: number, (Economy.bulkPrice(600, 512) - 1500) / 250, "cash still missing over the income")
	timed.money = 1e12
	eq(NextGoal.pick(timed).seconds, 0, "affordable now")
	eq(NextGoal.pick(input(10, { [10] = 1 })).seconds, nil, "no income, no estimate")

	-- Below the top tier the goal is always the next tier, whatever the Index has to claim.
	goal = NextGoal.pick(input(24, { [24] = 1 }))
	eq(goal.kind, "merge", "tier 24: the last tier")
	eq(goal.tier, 25, "target")

	-- Every tier found: the first Index milestone not claimed yet, lowest first.
	goal = NextGoal.pick(input(25, { [25] = 3 }))
	eq(goal.kind, "index", "the top tier with nothing claimed: an Index reward")
	eq(goal.need, 5, "the first milestone")
	eq(goal.have, 5, "counted up to the milestone")
	check(goal.ready and goal.percent == 100 and goal.progress == 1, "it waits to be claimed")
	check(not goal.mergeReady, "no merge makes it")
	eq(goal.seconds, 0, "and no wait")
	local title, hint, count, percent = NextGoal.text(goal, nameOf, "Chads")
	eq(title, "Index reward", "index title")
	eq(hint, "claim it in the Index", "index hint")
	eq(count, "5/5", "index count")
	eq(percent, "100%", "index percent")
	goal = NextGoal.pick(input(25, { [25] = 3 }, { 5, 10, 15 }))
	eq(goal.kind, "index", "milestones left")
	eq(goal.need, 20, "the next one not claimed")
	goal = NextGoal.pick(input(25, { [25] = 3 }, { 25, 5, 15, 10 }))
	eq(goal.need, 20, "in any order of claims")
	-- An Index with holes (tiers a crate skipped): the milestone is counted, not claimable.
	local holes = input(25, { [25] = 1 }, { 5, 10, 15, 20 })
	holes.discovered[7], holes.discovered[8] = 0, 0
	goal = NextGoal.pick(holes)
	eq(goal.kind, "index", "the whole Index is still the goal")
	eq(goal.have, 23, "23 tiers found")
	eq(goal.need, 25, "of 25")
	check(not goal.ready and goal.percent == 92, "not ready, 92%")
	eq(select(2, NextGoal.text(goal, nameOf, "Chads")), "find 25 Chads", "what it takes, in words")
	eq(select(3, NextGoal.text(goal, nameOf, "Chads")), "23/25", "and the count")

	-- Everything claimed: nothing is left to reach. No "fill your rack", no bar to fill:
	-- only the units of the top tier as a count.
	local all = { 5, 10, 15, 20, 25 }
	goal = NextGoal.pick(input(25, { [25] = 3 }, all))
	eq(goal.kind, "done", "every tier found and every milestone claimed")
	eq(goal.tier, Economy.MAX_TIER, "it shows the top tier")
	eq(goal.have, 3, "three units of it")
	eq(goal.need, 0, "with no target")
	check(goal.progress == 1 and goal.percent == 100, "nothing left to fill")
	check(not goal.ready and not goal.mergeReady, "and nothing to step on")
	title, hint, count, percent = NextGoal.text(goal, nameOf, "Chads")
	eq(title, "All 25 Chads found!", "done title")
	eq(hint, "3x T25", "the top tier's units")
	eq(count, "3", "as a plain count")
	eq(percent, "100%", "done percent")
	eq(select(1, NextGoal.text(goal, nameOf)), "All 25 units found!", "a plain word without the theme's")
	eq(NextGoal.pick(input(25, {}, all)).have, 0, "none on the rack: 0")
	eq(NextGoal.pick(input(25, { [25] = 500 }, all)).have, Economy.UNIT_CAP, "never more than a rack holds")
	-- Junk in the claimed list is not a claim.
	eq(NextGoal.pick(input(25, { [25] = 1 }, { "x", 7, 5 } :: any)).need, 10, "only real milestones count as claimed")
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

test("onboarding funnel: tier milestones", function()
	local Funnel = require("../src/shared/Funnel")
	local DataService = loadDataService()
	eq(Funnel.TUTORIAL_END, 2 + TutorialSteps.COUNT, "the tutorial ends on step 7")
	eq(Funnel.LAST, 11, "four milestones after the tutorial")
	eq(DataService.reconcile({ money = 10 }).onboarding, Funnel.LEGACY, "DataService's legacy value")
	check(Funnel.LAST < Funnel.SKIPPED and Funnel.SKIPPED + #Funnel.MILESTONES < Funnel.LEGACY, "the ranges stay apart")
	eq(Funnel.milestoneName(1), "Tier 3")
	eq(Funnel.milestoneName(4), "Tier 10")
	for tier, count in { [1] = 0, [2] = 0, [3] = 1, [4] = 1, [5] = 2, [6] = 2, [7] = 3, [9] = 3, [10] = 4, [25] = 4 } do
		eq(Funnel.reached(tier), count, "milestones reached at tier " .. tier)
	end

	-- Tutorial still running: nothing yet, whatever the tier.
	for onboarding = 0, Funnel.TUTORIAL_END - 1 do
		local plan = Funnel.tiers(onboarding, 10)
		eq(plan.onboarding, onboarding, "waits for the tutorial at " .. onboarding)
		eq(#plan.steps + #plan.events, 0, "logs nothing at " .. onboarding)
	end
	-- Finished: funnel steps 8..11, each once and in order.
	local plan = Funnel.tiers(7, 2)
	eq(#plan.steps, 0, "tier 2 is no milestone")
	plan = Funnel.tiers(7, 3)
	eq(table.concat(plan.steps, ","), "8", "tier 3 logs step 8")
	eq(plan.onboarding, 8)
	plan = Funnel.tiers(8, 7)
	eq(table.concat(plan.steps, ","), "9,10", "a jump logs every step it passed")
	eq(plan.onboarding, 10)
	eq(#Funnel.tiers(10, 9).steps, 0, "no step twice")
	plan = Funnel.tiers(7, 25)
	eq(table.concat(plan.steps, ","), "8,9,10,11", "all four")
	eq(#plan.events, 0, "finishers log no custom events")
	eq(#Funnel.tiers(11, 25).steps, 0, "nothing past the last step")

	-- Skipped: the funnel stops; milestones become one-time custom events.
	for onboarding = 0, Funnel.TUTORIAL_END - 1 do
		eq(Funnel.skip(onboarding), Funnel.SKIPPED, "skipping at " .. onboarding)
	end
	eq(Funnel.skip(7), 7, "a finished tutorial cannot be skipped")
	eq(Funnel.skip(9), 9)
	eq(Funnel.skip(Funnel.SKIPPED + 2), Funnel.SKIPPED + 2, "skipping twice changes nothing")
	eq(Funnel.skip(Funnel.LEGACY), Funnel.LEGACY, "legacy saves stay legacy")
	plan = Funnel.tiers(Funnel.SKIPPED, 5)
	eq(#plan.steps, 0, "skippers log no funnel steps")
	eq(table.concat(plan.events, ","), "SkipperTier3,SkipperTier5")
	eq(plan.onboarding, Funnel.SKIPPED + 2)
	plan = Funnel.tiers(Funnel.SKIPPED + 2, 12)
	eq(table.concat(plan.events, ","), "SkipperTier7,SkipperTier10", "only the new ones")
	eq(plan.onboarding, Funnel.SKIPPED + 4)
	eq(#Funnel.tiers(Funnel.SKIPPED + 4, 25).events, 0, "each event once")

	-- Saves from before the funnel never log.
	plan = Funnel.tiers(Funnel.LEGACY, 25)
	eq(#plan.steps + #plan.events, 0, "legacy logs nothing")
	eq(plan.onboarding, Funnel.LEGACY)
	-- Whatever is saved survives a reload.
	for _, value in { 9, Funnel.SKIPPED, Funnel.SKIPPED + 3 } do
		local saved = { money = 10, version = DataService.VERSION, onboarding = value }
		eq(DataService.reconcile(saved).onboarding, value, "kept " .. value)
	end
end)

test("onboarding funnel: returning players log no tier milestones", function()
	local Funnel = require("../src/shared/Funnel")
	local DataService = loadDataService()
	local done = Funnel.SKIPPED + #Funnel.MILESTONES
	-- A tutorial finished before the milestones existed: all four count as logged.
	eq(Funnel.returning(Funnel.TUTORIAL_END, true), Funnel.LAST, "finished tutorial")
	-- A skipped one, marked or not (skips were not marked at first).
	eq(Funnel.returning(Funnel.SKIPPED, true), done, "marked skip")
	for onboarding = 0, Funnel.TUTORIAL_END - 1 do
		eq(Funnel.returning(onboarding, true), done, "unmarked skip at " .. onboarding)
		eq(Funnel.returning(onboarding, false), onboarding, "a running tutorial goes on at " .. onboarding)
	end
	eq(Funnel.returning(Funnel.LEGACY, true), Funnel.LEGACY, "legacy stays legacy")
	-- Whatever tier such a profile is on, now or later, nothing is sent.
	for _, onboarding in { Funnel.returning(Funnel.TUTORIAL_END, true), Funnel.returning(3, true) } do
		for _, tier in { 1, 3, 10, 25 } do
			local plan = Funnel.tiers(onboarding, tier)
			eq(#plan.steps + #plan.events, 0, "nothing logged at tier " .. tier)
			eq(plan.onboarding, onboarding, "unchanged at tier " .. tier)
		end
	end
	-- DataService migrates a save from before the milestones once, on load.
	eq(DataService.defaultProfile().version, DataService.VERSION, "new profiles carry the current version")
	eq(DataService.reconcile(nil).onboarding, 0, "a new profile starts the funnel")
	local finished = DataService.reconcile({ money = 10, version = 1, tutorialDone = true, onboarding = Funnel.TUTORIAL_END })
	eq(finished.onboarding, Funnel.LAST, "returning player past every milestone")
	eq(finished.version, DataService.VERSION, "migrated saves carry the current version")
	eq(DataService.reconcile({ money = 10, tutorialDone = true, onboarding = 4 }).onboarding, done, "returning skipper")
	eq(DataService.reconcile({ money = 10, tutorialDone = false, onboarding = 4 }).onboarding, 4, "mid-tutorial save goes on")
	-- A profile created after the change keeps logging: its tiers are new.
	local fresh =
		DataService.reconcile({ money = 10, version = DataService.VERSION, tutorialDone = true, onboarding = Funnel.TUTORIAL_END })
	eq(fresh.onboarding, Funnel.TUTORIAL_END, "a new profile's progress is kept")
	eq(#Funnel.tiers(fresh.onboarding, 5).steps, 2, "and its milestones are logged")
	eq(DataService.reconcile(finished).onboarding, Funnel.LAST, "migrating twice changes nothing")
end)

test("buy tiers removed: old saves keep buying the first tier", function()
	local DataService = loadDataService()
	local easy = Economy.BUY_EASY_UNITS
	local function migrated(save: { [string]: any }): { [string]: any }
		save.money = 10
		return DataService.reconcile(save) :: any
	end
	eq(DataService.defaultProfile().bought, 0, "a new profile has bought nothing")
	-- A save that had upgraded its buy tier starts just past the easy units.
	local upgraded = migrated({ buyTier = 6, boughtAtTier = 3 })
	eq(upgraded.bought, easy, "an upgraded save has used its easy units")
	eq(upgraded.buyTier, nil, "the buy tier is dropped")
	eq(upgraded.boughtAtTier, nil, "the old count is dropped")
	-- One still on the first buy tier keeps its count, capped as it was on every load.
	eq(migrated({ buyTier = 1, boughtAtTier = 7 }).bought, 7, "purchases are kept")
	eq(migrated({ buyTier = 1, boughtAtTier = 500 }).bought, easy, "never above the easy units")
	eq(migrated({ buyTier = 1, boughtAtTier = 0 / 0 }).bought, 0, "a broken count reads as zero")
	eq(migrated({}).bought, 0, "a save without either starts at zero")
	-- Once migrated the count is the save's own and is not capped again.
	eq(migrated({ bought = 4321 }).bought, 4321, "the new count is kept")
	eq(migrated({ bought = 4321, buyTier = 9, boughtAtTier = 2 }).bought, 4321, "old fields do not override it")
	eq(migrated({ bought = -3 }).bought, 0, "never negative")
	eq(migrated({ bought = 0 / 0 }).bought, 0, "a broken new count reads as zero")
end)

test("tutorial: no 'nothing to merge' toast before the merge step", function()
	for step, info in TutorialSteps.STEPS do
		eq(TutorialSteps.mergeToast(step, false), info.id == "merge", "step " .. info.id)
	end
	eq(TutorialSteps.mergeToast(1, false), false, "a new player walking onto the Merge pad")
	eq(TutorialSteps.mergeToast(TutorialSteps.DONE, false), true, "past the last step")
	eq(TutorialSteps.mergeToast(1, true), true, "tutorial finished or skipped")
	eq(TutorialSteps.mergeToast(TutorialSteps.DONE, true), true, "finished")
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

	-- Who may use a switch: its owner and, for the Chad Aura, a Champion without the pass.
	check(Cosmetics.canSwitch(theme, profile, passes, "Crown"), "an owner switches")
	check(not Cosmetics.canSwitch(theme, profile, passes, "AuraGlow"), "no pass, no Champion: no aura switch")
	check(not Cosmetics.canSwitch(theme, profile, passes, "TrailStar"), "a trail is not a switch")
	check(not Cosmetics.canSwitch(theme, profile, passes, "Nope"), "nor is an unknown item")
	check(state.canSwitch.Crown == true and state.canSwitch.AuraGlow == nil, "state: the switches the player may use")
	profile.cosmetics.champion = true
	check(Cosmetics.canSwitch(theme, profile, passes, "AuraGlow"), "a Champion switches the aura without the pass")
	check(not Cosmetics.canSwitch(theme, profile, passes, "SpeedBoost"), "but nothing else it does not own")
	check(not Cosmetics.owns(theme, passes, "AuraGlow"), "and still does not own the Chad Aura")
	local champion = Cosmetics.state(theme, profile, passes)
	eq(champion.canSwitch.AuraGlow, true, "state: the Champion's aura switch")
	eq(champion.owned.AuraGlow, nil, "state: not owned")
	eq(champion.toggles.AuraGlow, true, "state: the aura starts on")
	profile.cosmetics.toggles.AuraGlow = false
	eq(Cosmetics.state(theme, profile, passes).toggles.AuraGlow, false, "state: and can be off")
	local source = fs.readFile("src/server/Cosmetics.luau")
	check(
		string.find(source, 'if champion and Cosmetics.toggleOn(profile, "AuraGlow") then', 1, true) ~= nil,
		"the Champion aura follows the switch, pass or not"
	)
	check(
		string.find(source, "if not Cosmetics.canSwitch(theme, session.profile, session.passes, name) then", 1, true) ~= nil,
		"ToggleCosmetic lets a Champion through"
	)
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
	eq(Cosmetics.starterCash(theme, 0, early), starter.CashMin, "new player gets the cash minimum")
	local late = Economy.progression(20, 10)
	local lateCash = Cosmetics.starterCash(theme, 1e6, late)
	eq(lateCash, Economy.moneyPackAmount(1e6, starter.CashSeconds, starter.CashMin, late), "an hour of income")
	check(lateCash >= 1e6 * 3600, "late amounts scale up")
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
	check(total >= 12 and total <= 15, "about 12-15 seconds (" .. total .. ")")
	-- One line per beat at most, and each line stays up long enough to read.
	local lines = 0
	for i, beat in Timeline.BEATS do
		local shown = 0
		for _, caption in beat.captions do
			if caption.key then
				shown += 1
				lines += 1
				local untilNext = beat.duration - caption.t
				local nextBeat = Timeline.BEATS[i + 1]
				if nextBeat and nextBeat.captions[1] then
					untilNext += nextBeat.captions[1].t
				end
				check(untilNext >= 1.5, beat.name .. " line stays up 1.5 s (" .. untilNext .. ")")
				local words = select(2, string.gsub(intro.Lines[caption.key], "%S+", ""))
				check(words <= 8, beat.name .. " line is short (" .. words .. " words)")
			end
		end
		check(shown <= 1, beat.name .. " has one line")
	end
	eq(lines, #Timeline.BEATS, "every beat has its line")
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
		local stub = {
			Name = name,
			WaitForChild = function(_, child: string)
				return stubChild(child)
			end,
		}
		-- `script.Parent.Fx.Budget` and similar dotted paths resolve to more stubs.
		return setmetatable(stub, {
			__index = function(_, child: string)
				return stubChild(child)
			end,
		})
	end
	-- Fx.Budget is a client module (it needs Kit); the Animator only asks it for a tier.
	local budgetStub = {
		tier = function()
			return "high"
		end,
		scale = function()
			return 1
		end,
		count = function(n: number)
			return n
		end,
		low = function()
			return false
		end,
		onChange = function()
			return function() end
		end,
	}
	local env = robloxEnv()
	env.game = {
		GetService = function(_, name: string)
			return stubChild(name)
		end,
	}
	env.require = function(target: any)
		if target.Name == "Budget" then
			return budgetStub
		end
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
	check(low > 0.04 and high < 0.22, "saturation pulses gently around +0.12")
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
		Vector3 = roblox.Vector3,
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
				return { cash = 0 }
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

test("Game modes: toGates / toPlaza pick the nearer plaza", function()
	local GameModes = loadGameModes()
	local C = ModesCourse :: any
	local savedQuit, savedArrival = C.nearestQuit, C.nearestArrival
	local quit2 = { x = -C.QUIT.x, y = C.QUIT.y, z = C.QUIT.z }
	local arrival2 = { x = -C.ARRIVAL.x, y = C.ARRIVAL.y, z = C.ARRIVAL.z }
	C.nearestQuit = function(x)
		return if x > 0 then quit2 else C.QUIT
	end
	C.nearestArrival = function(x)
		return if x > 0 then arrival2 else C.ARRIVAL
	end
	local at = roblox.Vector3.new(0, 0, 0)
	local moved: any, look: any = nil, nil
	GameModes.root = function()
		return { Position = at }
	end
	GameModes.teleport = function(_, feet, face)
		moved, look = feet, face
	end
	local ok, err = pcall(function()
		at = roblox.Vector3.new(150, 3, 0)
		GameModes.toGates({})
		eq(moved.X, quit2.x, "east of the hub: the mirrored plaza's quit spot")
		eq(look.X, -1, "facing back toward the hub (west)")
		GameModes.toPlaza({})
		eq(moved.X, arrival2.x, "east of the hub: the mirrored arrival")
		eq(look.X, 1, "arrival faces the mirrored gates (east)")
		at = roblox.Vector3.new(-150, 3, 0)
		GameModes.toGates({})
		eq(moved.X, C.QUIT.x, "west of the hub: the original quit spot")
		eq(look.X, 1, "facing the hub (east)")
		C.nearestQuit = nil
		at = roblox.Vector3.new(150, 3, 0)
		GameModes.toGates({})
		eq(moved.X, C.QUIT.x, "without nearestQuit: always the original spot")
	end)
	C.nearestQuit, C.nearestArrival = savedQuit, savedArrival
	if not ok then
		error(err, 0)
	end
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
	local early = Economy.modeReward(0, progression, pack.Seconds, pack.Min, false, now - cooldown + 1, now)
	check(not early.full and early.cash == 0 and early.packCash > 0, "inside the cooldown a finish pays no cash")
	local later = Economy.modeReward(0, progression, pack.Seconds, pack.Min, false, now - cooldown, now)
	check(later.full and later.cash == later.packCash, "full pack again after the cooldown")
	-- What a clean finish inside the cooldown is worth: a fifth of the pack, whole dollars.
	eq(Economy.MODE_REPEAT_SHARE, 0.2, "repeat share")
	eq(early.repeatCash, math.floor(early.packCash * 0.2), "repeat cash is 20% of the pack")
	eq(later.repeatCash, early.repeatCash, "repeat cash does not depend on the cooldown")
	check(early.repeatCash > 0 and early.repeatCash < early.packCash, "repeat cash is a part of the pack")
end)

test("Game modes: no checkpoints, one plausible start-to-finish time per level", function()
	eq(ModesCourse.LEVEL_COUNT, 10, "ten parkour levels")
	eq(#ModesCourse.LEVELS, ModesCourse.LEVEL_COUNT, "every level is built")
	for i, level in ModesCourse.LEVELS do
		local any = level :: any
		eq(any.CHECKPOINTS, nil, "level " .. i .. ": no checkpoint list")
		eq(any.CHECKPOINT_COUNT, nil, "level " .. i .. ": no checkpoint count")
		local rests = 0
		for _, e in level.ELEMENTS do
			check(e.kind ~= "checkpoint", "level " .. i .. ": no checkpoint elements")
			if e.name == "RestDeck" then
				rests += 1
				check(e.kind == "pad" and e.shape == "box" and e.index == nil, "level " .. i .. ": rest decks are plain pads")
			end
		end
		check(rests >= 3 and rests <= 8, "level " .. i .. ": 3-8 rest decks where the checkpoints stood")
		check(level.PATH_LENGTH > 50, "level " .. i .. " has a path length")
		check(
			math.abs(level.MIN_SECONDS - level.PATH_LENGTH / ModesCourse.MAX_PLAUSIBLE_SPEED) < 1e-9 and level.MIN_SECONDS > 0,
			"level " .. i .. ": the minimum time is the path at MAX_PLAUSIBLE_SPEED"
		)
		local fast = ModesRules.newRun(0, level)
		local ok, reason = ModesRules.finish(fast, level.MIN_SECONDS - 0.05)
		check(not ok and reason == "fast", "level " .. i .. ": impossibly fast runs earn nothing")
		local fair = ModesRules.newRun(0, level)
		local okFair, time = ModesRules.finish(fair, 300)
		check(okFair and time == 300, "level " .. i .. ": a normal run finishes")
	end
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

test("Game modes: cardio first clears have a default and old saves keep theirs", function()
	local DataService = loadDataService()
	eq(DataService.defaultProfile().cardio.firsts, 0, "a new profile has taken no first clear")
	eq(DataService.reconcile({ money = 1 }).cardio.firsts, 0, "a save without cardio has taken none")
	local old = DataService.reconcile({ money = 1, cardio = { speed = 50, bestStage = 3, treadmill = 1, clears = 4, speedCap = 0 } })
	eq(old.cardio.firsts, 7, "a save from before the set took every plate up to bestStage")
	local kept = DataService.reconcile({ money = 1, cardio = { speed = 50, bestStage = 9, firsts = 5 } })
	eq(kept.cardio.firsts, 5, "a saved set wins over bestStage")
	eq(DataService.reconcile({ money = 1, cardio = { bestStage = 2, firsts = 5.7 } }).cardio.firsts, 5, "whole numbers only")
	eq(DataService.reconcile({ money = 1, cardio = { bestStage = 2, firsts = 1e9 } }).cardio.firsts, 1023, "never more than the ten plates")
	eq(DataService.reconcile({ money = 1, cardio = { bestStage = 2, firsts = -4 } }).cardio.firsts, 3, "junk falls back to bestStage")
	eq(DataService.reconcile({ money = 1, cardio = { bestStage = 99, firsts = "x" } }).cardio.firsts, 1023, "clamped to the ten plates")
end)

-- Sky obby server (docs/sky-obby.md): stages, gear, skip, stage board ------------------

-- A minimal Instance stand-in for the Parkour tests (children by name, attributes).
local function fakeInstance(className: string, props: { [string]: any }?): any
	local data = {
		ClassName = className,
		Name = className,
		children = {},
		attrs = {},
		parentRef = nil,
		destroyed = false,
	}
	local obj: any
	obj = setmetatable(data, {
		__index = function(_, key)
			if key == "Parent" then
				return rawget(data, "parentRef")
			end
			return nil
		end,
		__newindex = function(_, key, value)
			if key == "Parent" then
				local old = rawget(data, "parentRef")
				if old then
					old.children[obj] = nil
				end
				rawset(data, "parentRef", value)
				if value then
					value.children[obj] = true
				end
			else
				rawset(data, key, value)
			end
		end,
	})
	function obj:FindFirstChild(name: string): any
		for child in self.children do
			if child.Name == name then
				return child
			end
		end
		return nil
	end
	function obj:FindFirstChildOfClass(class: string): any
		for child in self.children do
			if child.ClassName == class then
				return child
			end
		end
		return nil
	end
	function obj:GetAttribute(name: string): any
		return self.attrs[name]
	end
	function obj:SetAttribute(name: string, value: any)
		self.attrs[name] = value
	end
	function obj:Destroy()
		self.Parent = nil
		self.destroyed = true
	end
	for key, value in props or {} do
		obj[key] = value
	end
	return obj
end

-- Loads Modes.Parkour against stub GameModes / Tycoon. Returns the mode def and a rig.
local function loadParkour(): (any, any)
	local DataService = loadDataService()
	local theme = loadRobloxTheme("src/themes/chad/Theme.luau")
	local clock = { t = 1000 }
	local rig: any = { notes = {}, toasts = {}, actions = {}, effects = {}, teleports = 0, clock = clock }
	local character = fakeInstance("Model")
	local humanoid = fakeInstance("Humanoid", { WalkSpeed = 16, JumpHeight = 7.2, JumpPower = 50, UseJumpPower = false })
	humanoid.Parent = character
	local root = fakeInstance("Part", { Name = "HumanoidRootPart", AssemblyMass = 20, Position = roblox.Vector3.new(0, 0, 0) })
	root.Parent = character
	local player = fakeInstance("Player", { UserId = 7, DisplayName = "Tester", Character = character })
	local session = { player = player, profile = DataService.defaultProfile() }
	rig.player, rig.humanoid, rig.root, rig.session = player, humanoid, root, session
	local GameModes
	GameModes = {
		hooks = {
			reward = function(_, _, reward)
				return reward
			end,
			rewarded = function() end,
		},
		session = function()
			return session
		end,
		notify = function(_, event, _, data)
			local note = table.clone(data or {})
			note.event = event
			table.insert(rig.notes, note)
		end,
		effect = function(_, kind, data)
			table.insert(rig.effects, { kind = kind, data = data })
		end,
		refresh = function() end,
		root = function()
			return root
		end,
		teleport = function(_, feet)
			rig.teleports += 1
			rig.teleportedTo = feet
		end,
		returnLater = function() end,
		toGates = function() end,
	}
	local Tycoon = {
		income = function()
			return 0
		end,
		markDirty = function() end,
		toast = function(_, text)
			table.insert(rig.toasts, text)
		end,
		addAction = function(name, fn)
			rig.actions[name] = fn
		end,
	}
	local services = {
		ReplicatedStorage = { Shared = { Economy = Economy, Format = Format } },
		Players = { PlayerRemoving = { Connect = function() end } },
	}
	local env = setmetatable({
		game = {
			GetService = function(_, name)
				return services[name]
			end,
		},
		script = { Parent = { Course = ModesCourse, Rules = ModesRules } },
		require = function(module)
			return module
		end,
		workspace = {
			Gravity = 196.2,
			GetServerTimeNow = function()
				return clock.t
			end,
		},
		Vector3 = roblox.Vector3,
		Enum = roblox.Enum,
		Instance = { new = fakeInstance },
	}, { __index = _G })
	local path = MODES_DIR .. "Parkour.luau"
	local Parkour = luau.load(fs.readFile(path), { debugName = path, environment = env })()
	rig.GameModes = GameModes
	local def = Parkour.create(GameModes, { built = nil, theme = theme, Tycoon = Tycoon })
	function rig.last(event: string): any
		for i = #rig.notes, 1, -1 do
			if rig.notes[i].event == event then
				return rig.notes[i]
			end
		end
		return nil
	end
	return def, rig
end

test("Sky obby: speed-scaled anti-cheat", function()
	local level = ModesCourse.LEVELS[1]
	-- A run exactly as quick as the speed coil allows: too fast unscaled, fine at 28/16.
	local run = ModesRules.newRun(0, level)
	local finishAt = level.MIN_SECONDS * 16 / 28 + 0.01
	local plain = ModesRules.finish(run, finishAt)
	eq(plain, false, "coil-fast runs fail at walking speed")
	eq((ModesRules.finish(run, finishAt, 28 / 16)), true, "the speed coil scales the minimum")
	-- A paid Skip Map is no finish: runs carry no skip flag and nothing waives the minimum.
	eq((ModesRules :: any).skip, nil, "no Rules.skip")
	eq((ModesRules.newRun(0, level) :: any).skipped, nil, "runs carry no skip flag")
	eq((ModesRules.finish(ModesRules.newRun(0, level), 0.02)), false, "an instant finish is always 'fast'")
end)

test("Sky obby: stages, gear and the assisted flag", function()
	local def, rig = loadParkour()
	local player, humanoid, root, profile = rig.player, rig.humanoid, rig.root, rig.session.profile
	eq(def.snapshot(player).gear, "none", "no gear by default")
	eq(player:GetAttribute("ParkourStage"), 0, "snapshot sets the stage attribute on join")
	eq(player:GetAttribute("ParkourBestStage"), 0, "and the best stage")
	check(def.start(player, true, { level = 1 }), "level 1 starts")
	local start = rig.last("start")
	eq(start.stage, 1, "map 1's start deck is stage 1")
	check(type(start.stageCount) == "number" and start.stageCount > ModesCourse.LEVEL_COUNT, "stage count is sent")
	eq(start.assisted, false, "a plain run is not assisted")
	eq(player:GetAttribute("ParkourStage"), 1, "running on stage 1")
	eq(profile.parkour.stage, 1, "stage 1 reached and saved")
	eq(humanoid.WalkSpeed, 16, "no gear, normal speed")

	rig.actions.ParkourGear(rig.session, { gear = "bogus" })
	eq(profile.parkour.gear, "none", "unknown gear refused")
	rig.actions.ParkourGear(rig.session, { gear = "speed" })
	eq(profile.parkour.gear, "speed", "gear choice saved")
	eq(humanoid.WalkSpeed, 28, "speed coil worn during the run")
	eq(def.snapshot(player).assisted, true, "wearing gear makes the run assisted")
	rig.actions.ParkourGear(rig.session, { gear = "jump" })
	eq(humanoid.WalkSpeed, 16, "switching coils restores the speed")
	eq(humanoid.JumpHeight, 14, "jump coil")
	rig.actions.ParkourGear(rig.session, { gear = "gravity" })
	eq(humanoid.JumpHeight, 7.2, "jump restored")
	local coil = root:FindFirstChild("GravityCoil")
	check(coil ~= nil and coil.ClassName == "VectorForce", "gravity coil on the root")
	check(math.abs(coil.Force.Y - 0.55 * 20 * 196.2) < 0.01, "cancels 55% of the weight")
	def.stop(player, "quit")
	eq(root:FindFirstChild("GravityCoil"), nil, "stopping takes the coil off")
	eq(root:FindFirstChild("GravityCoilAttachment"), nil, "and its attachment")
	eq(player:GetAttribute("ParkourStage"), 0, "not running: stage 0")
	eq(def.snapshot(player).gear, "gravity", "snapshot carries the gear")

	rig.actions.ParkourGear(rig.session, { gear = "speed" })
	eq(humanoid.WalkSpeed, 16, "gear is not worn outside a run")
	humanoid.UseJumpPower = true
	rig.actions.ParkourGear(rig.session, { gear = "jump" })
	def.start(player, true, { level = 1 })
	eq(humanoid.JumpPower, 70, "chosen gear goes on at the start (JumpPower rigs)")
	eq(rig.last("start").assisted, true, "a geared start is assisted")
	def.stop(player, "respawn")
	eq(humanoid.JumpPower, 50, "removed on respawn")
end)

test("Sky obby: falls and kill bricks send the runner back to the map's start deck", function()
	local def, rig = loadParkour()
	local player = rig.player
	local level = ModesCourse.LEVELS[2]
	rig.session.profile.parkour.clears[1] = 1
	local C = ModesCourse :: any
	local saved = C.inKill
	-- Far along the course (where a checkpoint used to be): a rest deck.
	local rest = nil
	for _, e in level.PATH do
		if e.name == "RestDeck" then
			rest = e
		end
	end
	assert(rest, "map 2 has a rest deck")
	C.inKill = function(lv, x, _, z)
		return lv == level and math.abs(x - rest.x) < 0.01 and math.abs(z - rest.z) < 0.01
	end
	local ok, err = pcall(function()
		check(def.start(player, true, { level = 2 }), "map 2 starts")
		local at = ModesCourse.respawn(level)
		local startAt = roblox.Vector3.new(at[1], at[2], at[3])
		check(math.abs(at[1] - level.START.x) < 1e-9 and math.abs(at[3] - level.START.z) < 1e-9, "the respawn spot is the start deck")
		-- Standing on the old checkpoint spot does nothing (no checkpoint).
		rig.root.Position = roblox.Vector3.new(rest.x + 3, rest.y + 3, rest.z)
		rig.clock.t += 2
		def.tick(player, rig.root, rig.clock.t)
		eq(rig.last("checkpoint"), nil, "no checkpoint notify")
		eq(def.snapshot(player).checkpoint, 0, "no checkpoint reached")
		eq(player:GetAttribute("ParkourStage"), level.STAGE_FIRST, "the stage is the map")
		-- Lava on the rest deck: back to the START of map 2.
		local before = rig.teleports
		rig.root.Position = roblox.Vector3.new(rest.x, rest.y + 3, rest.z)
		rig.clock.t += 2
		def.tick(player, rig.root, rig.clock.t)
		local note = rig.last("respawn")
		check(note ~= nil, "a respawn notify")
		eq(note and note.reason, "kill", "reason kill")
		eq(note and note.index, 0, "back to the start deck")
		eq(note and note.stage, level.STAGE_FIRST, "the map's stage")
		eq(rig.teleports, before + 1, "teleported once")
		check(rig.teleportedTo ~= nil and (rig.teleportedTo - startAt).Magnitude < 0.01, "moved to the start deck")
		local fx = rig.effects[#rig.effects]
		eq(fx and fx.kind, "ModeKill", "ModeKill effect")
		-- Grace: an immediate second tick does nothing.
		def.tick(player, rig.root, rig.clock.t + 0.1)
		eq(rig.teleports, before + 1, "grace after the respawn")
		-- A fall through the cloud floor near the end: back to the start deck too.
		C.inKill = saved
		rig.root.Position = roblox.Vector3.new(rest.x, ModesCourse.FLOOR_Y - 2 + 3, rest.z)
		rig.clock.t += 2
		def.tick(player, rig.root, rig.clock.t)
		eq(rig.teleports, before + 2, "a fall teleports")
		check(rig.teleportedTo ~= nil and (rig.teleportedTo - startAt).Magnitude < 0.01, "a fall goes to the start deck")
		local fell = rig.last("respawn")
		check(fell ~= nil and fell.reason == nil and fell.index == 0, "fall respawn at the start")
		check(def.running(player), "the run goes on")
	end)
	C.inKill = saved
	if not ok then
		error(err, 0)
	end
end)

test("Sky obby: Skip Map only unlocks the next map", function()
	local def, rig = loadParkour()
	local player, profile = rig.player, rig.session.profile
	local rec = profile.parkour
	local cost = Economy.parkourSkipCost(0)
	eq(cost, Economy.PARKOUR_SKIP_MIN, "with no income a skip costs the minimum")
	eq(Economy.parkourSkipCost(1), 250, "two minutes of $1/s is under the minimum")
	eq(Economy.parkourSkipCost(10), 1200, "two minutes of income")
	eq(def.snapshot(player).skipCost, cost, "the snapshot carries the cash cost")
	local gates = 0
	rig.GameModes.toGates = function()
		gates += 1
	end
	def.start(player, true, { level = 1 })
	profile.money = cost - 1
	rig.actions.ParkourSkip(rig.session, {})
	eq(#rig.toasts, 1, "short of cash: a toast")
	check(string.find(rig.toasts[1], "Not enough cash", 1, true) ~= nil, "toast says Not enough cash")
	eq(profile.money, cost - 1, "nothing taken")
	eq(rig.last("skip"), nil, "no skip")
	check(def.running(player), "the run goes on")

	profile.money = cost + 5
	local earned = profile.totalEarned
	rig.actions.ParkourSkip(rig.session, {})
	local skip = rig.last("skip")
	check(skip ~= nil and skip.level == 1 and skip.nextLevel == 2 and skip.unlocked == 2, "skip notify: map 1 skipped, map 2 unlocked")
	eq(skip and skip.paid, 0, "the skip pays nothing")
	eq(rig.last("finish"), nil, "a skip is no finish: no finish card")
	eq(profile.money, 5, "the skip costs its price and pays no cash")
	eq(profile.totalEarned, earned, "nothing earned")
	eq(rec.clears[1], 0, "no clear")
	eq(rec.best[1], 0, "no best time")
	eq(rec.skipped[1], 1, "the skip is saved")
	eq(#rec.skipped, ModesCourse.LEVEL_COUNT, "one skipped slot per level")
	eq(profile.modes.parkour.lastRewardAt, 0, "no reward cooldown started")
	eq(rec.stage, 1, "the saved stage does not rise")
	eq(player:GetAttribute("ParkourBestStage"), 1, "nor the best stage attribute")
	-- The run stops and the player is back at the gates with the picker on the next map.
	check(not def.running(player), "the run stops")
	eq(player:GetAttribute("ParkourStage"), 0, "no stage on the HUD")
	eq(gates, 1, "taken back to the gates")
	local stop, pick, start = rig.last("stop"), rig.last("pick"), rig.last("start")
	eq(stop and stop.reason, "skip", "the HUD run ends with reason skip")
	eq(pick and pick.level, 2, "the picker opens on the next map")
	eq(start and start.level, 1, "the next map does not start by itself")
	eq(rig.notes[#rig.notes], pick, "the picker is the last notify")
	local snap = def.snapshot(player)
	check(snap.unlocked == 2 and snap.level == 2, "map 2 is unlocked and the default pick")
	-- No skips outside a run.
	profile.money = cost
	rig.actions.ParkourSkip(rig.session, {})
	eq(profile.money, cost, "no skips outside a run")

	-- A later real first clear of the skipped map still pays in full.
	local level = ModesCourse.LEVELS[1]
	local preview = def.rewardPreview(player, 1)
	check(preview.full and preview.cash > 0, "map 1's first clear still pays")
	check(def.start(player, true, { level = 1 }), "the skipped map can be run")
	rig.clock.t += level.MIN_SECONDS + 30
	local last = level.PATH[#level.PATH]
	rig.root.Position = roblox.Vector3.new(last.x, last.y + 3, last.z)
	def.tick(player, rig.root, rig.clock.t)
	local finish = rig.last("finish")
	check(finish ~= nil and finish.first == true, "a real finish, counted as the first clear")
	check(finish ~= nil and finish.full and finish.cash == preview.cash, "paid in full")
	eq(finish and finish.gems, nil, "no Rizz in the finish")
	eq(profile.money, cost + (finish and finish.cash or 0), "the cash arrives")
	eq(rec.clears[1], 1, "one clear")
	check(rec.best[1] > 0, "and a best time")
	eq(rec.stage, 2, "finishing map 1 reaches stage 2")

	-- Nothing to unlock: refused and not charged (next map already open, or the last map).
	for i = 2, ModesCourse.LEVEL_COUNT - 1 do
		rec.clears[i] = 1
	end
	local toasts = #rig.toasts
	def.start(player, true, { level = 1 })
	rig.actions.ParkourSkip(rig.session, {})
	def.start(player, true, { level = ModesCourse.LEVEL_COUNT })
	rig.actions.ParkourSkip(rig.session, {})
	eq(profile.money, cost + (finish and finish.cash or 0), "not charged with nothing to unlock")
	eq(#rig.toasts, toasts + 2, "each refusal says why")
	eq(rec.clears[ModesCourse.LEVEL_COUNT], 0, "the last map is not cleared by a skip")
	check(def.running(player), "the run on the last map goes on")
end)

test("Sky obby: profile fields and the stage board", function()
	local DataService = loadDataService()
	local fresh = DataService.defaultProfile()
	eq(fresh.parkour.stage, 0, "new profiles have reached no stage")
	eq(fresh.parkour.gear, "none", "and wear no gear")
	eq(fresh.parkour.stageMaps, true, "new profiles count stages in maps")
	local old = DataService.reconcile({ money = 1, parkour = { best = { 30 }, clears = { 1 } } })
	eq(old.parkour.stage, 2, "old saves get a stage from their clears (map 1 cleared: map 2)")
	eq(old.parkour.gear, "none", "and no gear")
	-- Checkpoint-era saves: `stage` counted checkpoints; rebuilt in maps from the clears.
	local checkpointEra =
		DataService.reconcile({ money = 1, parkour = { best = {}, clears = { 2, 1, 1, 0, 1 }, stage = 37, gear = "jump" } })
	check(checkpointEra.parkour.stage == 4 and checkpointEra.parkour.stageMaps, "checkpoint-era stage 37 becomes map 4")
	local started = DataService.reconcile({ money = 1, parkour = { best = {}, clears = {}, stage = 5 } })
	eq(started.parkour.stage, 1, "a checkpoint-era runner with no clears is on map 1")
	local allDone = DataService.reconcile({ money = 1, parkour = { best = {}, clears = { 1, 1, 1, 1, 1, 1, 1, 1, 1, 1 }, stage = 80 } })
	eq(allDone.parkour.stage, 11, "all ten cleared: the last stage")
	local migrated = DataService.reconcile({ money = 1, modes = { parkour = { best = 4, clears = 1, lastRewardAt = 0 } } })
	check(migrated.parkour.stage == 2 and migrated.parkour.gear == "none", "migrated saves get the new fields")
	local bad = DataService.reconcile({ money = 1, parkour = { best = {}, clears = {}, stage = 0 / 0, gear = "rocket", stageMaps = true } })
	check(bad.parkour.stage == 0 and bad.parkour.gear == "none", "bad values reset")
	local good = DataService.reconcile({ money = 1, parkour = { best = {}, clears = {}, stage = 7.7, gear = "gravity", stageMaps = true } })
	check(good.parkour.stage == 7 and good.parkour.gear == "gravity", "good values stay (whole stages)")
	local high = DataService.reconcile({ money = 1, parkour = { best = {}, clears = {}, stage = 40, stageMaps = true } })
	eq(high.parkour.stage, 11, "map stages are capped at the last stage")

	local services = {
		DataStoreService = {
			GetOrderedDataStore = function()
				error("no DataStore in tests")
			end,
		},
		Players = {},
		ReplicatedStorage = { Shared = { Format = Format, Net = {} } },
	}
	local env = setmetatable({
		game = {
			GetService = function(_, name)
				return services[name]
			end,
		},
		script = { Parent = { Tycoon = {} } },
		require = function(module)
			return module
		end,
		warn = function() end,
	}, { __index = _G })
	local path = "src/server/Ranking.luau"
	local Ranking = luau.load(fs.readFile(path), { debugName = path, environment = env })()
	local stage, clears = Ranking.unpackStage(Ranking.packStage(42, 17))
	check(stage == 42 and clears == 17, "stage and clears round-trip")
	check(Ranking.packStage(5, 0) > Ranking.packStage(4, 9999999), "a higher stage always ranks first")
	check(Ranking.packStage(5, 3) > Ranking.packStage(5, 2), "clears break ties")
	local s, c = Ranking.stageOf({ parkour = { stage = 9, clears = { 2, 3, 0 } } })
	check(s == 9 and c == 5, "clears are summed over the maps")
end)

-- Edge-to-edge horizontal distance between two path elements (box, disc, or a point).
-- Rings measure like boxes, hexes like discs of their corner radius or, with `inner`, of
-- their flat-side radius (the reach a jump onto or off one needs).
local function shapeGap(a: any, ax: number, az: number, b: any, bx: number, bz: number, inner: boolean?): number
	local function half(e: any): (number, number, number)
		if e.shape == "box" or e.shape == "ring" then
			return e.sx / 2, e.sz / 2, 0
		end
		local r = e.r or 0
		return 0, 0, if inner and e.shape == "hex" then r * math.sqrt(3) / 2 else r
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

test("Game modes: every level's jumps are fair with the default jump, walked-on bounces too", function()
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
		local pads = {}
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
						pads[i] = e
						bounces += 1
					end
				end
			elseif e.kind == "blink" then
				check(e.on >= 1.2 and e.on < e.period and e.path, "level " .. li .. ": blink pads stay solid long enough")
			end
		end
		check(bounces >= 1, "level " .. li .. ": the bounce pad sits on a path deck")
		-- A WALKED-ON bounce is fair too. The pad launches on the first touch, PAD_REACH past
		-- its rim, so a runner who walks onto it and just keeps walking is launched at the
		-- rim's side away from the landing, feet on the deck: flown out step by step (no
		-- formula of Course's), they come down on the landing. One launched from the rim's
		-- near side, feet on the pad's top, does not fly over it.
		for i, deck in path do
			local pad = pads[i]
			if pad then
				local landing = path[i + 1]
				local label = string.format("level %d bounce %d -> %d", li, i, i + 1)
				check(landing.kind == "pad" and landing.shape ~= "ring", label .. ": the landing is a still, whole pad")
				check(math.abs(pad.x - deck.x) < 0.01 and math.abs(pad.z - deck.z) < 0.01, label .. ": the pad is centred on its deck")
				local dx, dz = landing.x - pad.x, landing.z - pad.z
				local ux, uz = 0, 0
				if math.abs(dx) >= math.abs(dz) then
					ux = if dx >= 0 then 1 else -1
				else
					uz = if dz >= 0 then 1 else -1
				end
				-- Studs inside the landing's footprint where a launch from `along` (studs from
				-- the pad's centre toward the landing) at feet height `y` comes back down to
				-- its top, holding forward at walking speed; nil when it never gets that high.
				local function comesDown(along: number, y: number): number?
					local dt = 1 / 240
					local vy, reached = pad.power, false
					for _ = 1, 240 * 4 do
						y += vy * dt
						vy -= gravity * dt
						along += ModesCourse.WALK_SPEED * dt
						reached = reached or y >= landing.y
						if reached and vy < 0 and y <= landing.y then
							local x, z = pad.x + ux * along, pad.z + uz * along
							if landing.sx then
								return math.min(landing.sx / 2 - math.abs(x - landing.x), landing.sz / 2 - math.abs(z - landing.z))
							end
							local r = landing.r * (if landing.shape == "hex" then math.sqrt(3) / 2 else 1)
							return r - math.sqrt((x - landing.x) ^ 2 + (z - landing.z) ^ 2)
						end
					end
					return nil
				end
				local touch = pad.r + ParkourMoves.PAD_REACH
				local walked = comesDown(-touch, deck.y)
				check(
					walked ~= nil and walked >= ModesCourse.SAFETY - 0.1,
					string.format("%s: walked on, the runner lands on the next element (%s inside)", label, tostring(walked))
				)
				local long = comesDown(touch, deck.y + ModesCourse.PAD_LIP)
				check(
					long ~= nil and long >= 0.9,
					string.format("%s: from the far rim they do not fly over it (%s inside)", label, tostring(long))
				)
				local okFair, why = ModesCourse.bounceFair(pad, landing)
				check(okFair, label .. ": Course.bounceFair agrees (" .. tostring(why) .. ")")
			end
		end
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
						local far = shapeGap(a, pa[1], pa[3], b, pb[1], pb[3], true)
						local up = pb[2] - pa[2]
						local reach = ModesCourse.maxGap(up, jump)
						local maxUp = bounceOn[i] or ModesCourse.MAX_STEP_UP
						if up <= maxUp and far <= reach then
							best = math.min(best, far)
						end
						worst = math.max(worst, far - reach)
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
		do
			local at, look = ModesCourse.respawn(level)
			check(math.abs(look[1] * look[1] + look[2] * look[2] - 1) < 1e-6, "level " .. li .. " respawn faces along the course")
			check(not ModesCourse.inWater(at[1], at[2], at[3]), "level " .. li .. " respawn is dry")
			check(ModesCourse.inBounds(level, at[1], at[2], at[3]), "level " .. li .. " respawn is inside the bounds")
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

test("Game modes: ten themed parkour maps with their own recipes and sky scenery", function()
	local kinds = {
		island = true,
		lighthouse = true,
		windmill = true,
		tree = true,
		balloon = true,
		cloud = true,
		star = true,
		rainbowarch = true,
		landmark = true,
		loop = true,
		spiral = true,
	}
	-- Props that stand on an island (inside its radius, on its grass top).
	local riders = { landmark = true, windmill = true, tree = true, lighthouse = true }
	-- Horizontal distance from (px, pz) to an element's footprint at its nearest phase.
	local function footDistance(e: any, px: number, pz: number): number
		if e.kind == "slide" then
			local a, b = e.from, e.to
			local dx, dz = b[1] - a[1], b[3] - a[3]
			local t = math.clamp(((px - a[1]) * dx + (pz - a[3]) * dz) / (dx * dx + dz * dz), 0, 1)
			return math.sqrt((px - a[1] - dx * t) ^ 2 + (pz - a[3] - dz * t) ^ 2) - e.width / 2
		end
		local best = math.huge
		local steps = if e.kind == "mover" then 16 else 0
		for s = 0, steps do
			local d = if e.kind == "mover" then e.distance * (2 * s / steps - 1) else 0
			local x, z = e.x + (if e.axis then e.axis[1] * d else 0), e.z + (if e.axis then e.axis[3] * d else 0)
			if e.sx then
				local ox = math.max(0, math.abs(px - x) - e.sx / 2)
				local oz = math.max(0, math.abs(pz - z) - e.sz / 2)
				best = math.min(best, math.sqrt(ox * ox + oz * oz))
			else
				best = math.min(best, math.sqrt((px - x) ^ 2 + (pz - z) ^ 2) - (e.r or (e.length or 0) / 2))
			end
		end
		return best
	end
	-- Colours: every palette key and card accent is a Theme.World colour, and no two maps
	-- share a path-top colour or a card accent.
	local world = loadRobloxTheme("src/themes/chad/Theme.luau").World
	local mains, accents = {}, {}
	for i, pal in ModesCourse.PALETTES do
		for key, value in pal do
			check(typeof(world[value]) == "Color3", string.format("map %d palette %s = %s is a Theme.World colour", i, key, value))
		end
		check(not mains[pal.main], "map " .. i .. " has its own path-top colour")
		mains[pal.main] = true
		local accent = ModesCourse.MAPS[i].accent
		check(typeof(world[accent]) == "Color3", "map " .. i .. " accent is a Theme.World colour")
		check(not accents[accent], "map " .. i .. " has its own accent")
		accents[accent] = true
	end
	local themes = {}
	local blinks, meanGap = {}, {}
	for i, level in ModesCourse.LEVELS do
		local map = ModesCourse.MAPS[i]
		local label = "map " .. i
		check(map ~= nil and map.name == ModesCourse.NAMES[i], label .. " has a MAPS entry named like the level")
		for _, key in { "theme", "blurb", "icon", "accent" } do
			check(type(level[key]) == "string" and #level[key] > 0 and level[key] == map[key], label .. " has its " .. key)
		end
		check(not themes[level.theme], label .. " has its own theme")
		themes[level.theme] = true
		check(i == 1 or map.recipe ~= nil, label .. " has a recipe")
		-- Sky scenery: known kinds inside the bounds (the giant arch over the bridge aside);
		-- 2-4 big islands beside the course, never within PROP_CLEARANCE of the path (every
		-- phase) nor overlapping each other; riders (landmark, windmill, trees, lighthouse) on
		-- an island; the anchor set piece clear of the path; clouds CLOUD_CLEAR under the path
		-- or CLOUD_BESIDE off it; balloons 25-40 above it; the map's extras.
		local props, b = level.PROPS, level.BOUNDS
		check(#props >= 8 and #props <= 30, label .. " has 8-30 props (" .. #props .. ")")
		local first, last = level.PATH[1], level.PATH[#level.PATH]
		local lo, hi = math.huge, -math.huge
		for _, e in level.PATH do
			for _, pose in ModesCourse.poses(e) do
				lo, hi = math.min(lo, pose[2]), math.max(hi, pose[2])
			end
			for _, pt in { e.from, e.to } do
				if pt then
					lo, hi = math.min(lo, pt[2]), math.max(hi, pt[2])
				end
			end
		end
		local islands, counts = {}, {}
		for _, p in props do
			counts[p.kind] = (counts[p.kind] or 0) + 1
			if p.kind == "island" then
				table.insert(islands, p)
			end
		end
		check(#islands >= 2 and #islands <= 4, label .. " has 2-4 islands (" .. #islands .. ")")
		check(ModesCourse.PROP_CLEARANCE >= 4, "props keep 4 studs off the path")
		for _, p in props do
			local what = label .. " " .. p.kind .. string.format(" at (%.1f, %.1f)", p.x, p.z)
			check(kinds[p.kind] == true, what .. ": known kind")
			if p.kind ~= "rainbowarch" then
				check(p.x >= b.x0 and p.x <= b.x1 and p.z >= b.z0 and p.z <= b.z1, what .. ": inside the bounds")
			end
			check(p.y > ModesCourse.FLOOR_Y - 40 and p.y < b.y1, what .. ": in the sky, under the bounds' top")
			local height = ModesCourse.PROP_HEIGHT[p.kind]
			if height then
				check(p.y + height * (p.scale or 1) < b.y1, what .. ": its top under the bounds' top")
			end
			if p.kind == "island" then
				check(p.r >= 28 and p.r <= 48, what .. ": radius 28-48")
				check(p.y < lo, what .. ": floats below the path")
				local foot = p.r
				for _, q in props do
					if q.kind == "landmark" and q.x == p.x and q.z == p.z then
						foot = math.max(foot, ModesCourse.propFoot(q))
					end
				end
				local need = ModesCourse.PROP_CLEARANCE + foot
				for _, e in level.ELEMENTS do
					local d = footDistance(e, p.x, p.z)
					check(d >= need - 1e-6, string.format("%s: %.2f clear of %s (needs %.2f)", what, d, e.name or e.kind, need))
				end
			elseif riders[p.kind] then
				local on = false
				for _, q in islands do
					local d = math.sqrt((p.x - q.x) ^ 2 + (p.z - q.z) ^ 2)
					local inside = if p.kind == "landmark" then d < 0.01 else d + ModesCourse.propFoot(p) <= q.r + 1e-6
					on = on or (inside and math.abs(p.y - q.y) < 1e-6)
				end
				check(on, what .. ": stands on an island")
			elseif p.kind == "cloud" then
				local foot = ModesCourse.propFoot(p)
				local top = p.y + ModesCourse.PROP_HEIGHT.cloud * (p.scale or 1)
				local off = math.huge
				for _, e in level.PATH do
					off = math.min(off, footDistance(e, p.x, p.z))
				end
				check(
					top <= lo - ModesCourse.CLOUD_CLEAR + 1e-6 or off >= ModesCourse.CLOUD_BESIDE + foot - 1e-6,
					string.format("%s: %.1f under the path or %.1f off it", what, lo - top, off - foot)
				)
				check(p.y <= lo, what .. ": no higher than the path")
			elseif p.kind == "balloon" then
				check(p.y >= hi + 25 - 1e-6 and p.y <= hi + 40 + 1e-6, what .. ": 25-40 studs above the course")
				check((p.scale or 1) >= 2, what .. ": a big balloon")
			elseif p.kind == "rainbowarch" then
				-- Giant, across the walking line: over the bridge into the map (map 1: over its
				-- first lane); its feet clear of every map's course and bridges, and whatever
				-- passes under its span stays inside the opening with headroom.
				local s = level.START
				local along = (p.x - s.x) * -s.faceX + (p.z - s.z) * -s.faceZ
				local across = (p.x - s.x) * -s.faceZ + (p.z - s.z) * s.faceX
				if i == 1 then
					check(along < 0 and math.abs(across) <= 16, what .. ": straddles the first lane")
				else
					check(math.abs(across) < 0.01 and along >= first.sx / 2 + 14, what .. ": over the bridge, on the walking line")
				end
				check(
					math.abs(p.y - first.y) < 0.01 and p.scale == ModesCourse.ARCH_SCALE,
					what .. ": giant, its feet at the deck's height"
				)
				local face = { s.faceX, s.faceZ }
				local everything = {}
				for _, other in ModesCourse.LEVELS do
					for _, e in other.ELEMENTS do
						table.insert(everything, e)
					end
				end
				for _, bridge in ModesCourse.BRIDGES do
					for _, e in bridge do
						table.insert(everything, e)
					end
				end
				check(ModesCourse.archFits(everything, p.x, p.y, p.z, face, p.scale), what .. ": feet and span clear of every course")
				local spread = ModesCourse.ARCH_FEET[1] * p.scale
				local feetR = ModesCourse.ARCH_FEET[2] * p.scale
				for _, sign in { -1, 1 } do
					local fx, fz = p.x - s.faceZ * spread * sign, p.z + s.faceX * spread * sign
					for _, e in everything do
						check(
							footDistance(e, fx, fz) >= feetR + ModesCourse.PROP_CLEARANCE - 1e-6,
							string.format("%s: foot clear of %s", what, e.name or e.kind)
						)
					end
				end
			elseif p.kind == "loop" or p.kind == "spiral" then
				local need = ModesCourse.PROP_CLEARANCE + ModesCourse.propFoot(p)
				for _, e in level.ELEMENTS do
					local d = footDistance(e, p.x, p.z)
					check(d >= need - 1e-6, string.format("%s: %.2f clear of %s (needs %.2f)", what, d, e.name or e.kind, need))
				end
				check(p.y <= lo, what .. ": stands beside the course, no higher than the path")
				for _, q in islands do
					local d = math.sqrt((p.x - q.x) ^ 2 + (p.z - q.z) ^ 2)
					check(d >= q.r + ModesCourse.propFoot(p), what .. ": off the islands")
				end
			end
		end
		for x = 1, #islands do
			for y = x + 1, #islands do
				local p, q = islands[x], islands[y]
				local d = math.sqrt((p.x - q.x) ^ 2 + (p.z - q.z) ^ 2)
				check(d >= p.r + q.r, string.format("%s islands %d and %d do not overlap (%.1f)", label, x, y, d))
			end
		end
		check(counts.landmark == 1, label .. " has exactly one landmark")
		check((counts.cloud or 0) >= 4 and (counts.cloud or 0) <= 8, label .. " has 4-8 clouds")
		check((counts.balloon or 0) >= 1 and (counts.balloon or 0) <= 2, label .. " has 1-2 balloons")
		eq(counts.windmill or 0, if level.theme == "storm" then 0 else 1, label .. " windmill (none in the storm)")
		eq(counts.rainbowarch or 0, if i % 3 == 1 then 1 else 0, label .. " giant rainbow arch on maps 1, 4, 7, 10")
		eq(counts.loop or 0, if i % 3 == 2 then 1 else 0, label .. " rainbow loop on maps 2, 5, 8")
		eq(counts.spiral or 0, if i % 3 == 0 then 1 else 0, label .. " spiral stair on maps 3, 6, 9")
		if level.theme == "bay" then
			eq(counts.lighthouse, 1, "the bay has a lighthouse")
		elseif level.theme == "beach" or level.theme == "cove" then
			check((counts.tree or 0) >= 3, label .. " has trees")
		elseif level.theme == "giga" then
			check((counts.star or 0) >= 3, "giga has stars")
		end
		for _, p in props do
			if p.kind == "landmark" then
				check(ModesCourse.propFoot(p) >= 16 * 2.2 and (p.scale or 1) >= 2.2, label .. " landmark is big (scale 2.2+)")
				local foot = ModesCourse.propFoot(p)
				check(
					p.x - foot >= b.x0 and p.x + foot <= b.x1 and p.z - foot >= b.z0 and p.z + foot <= b.z1,
					label .. " landmark footprint inside the bounds (never cropped)"
				)
			end
		end
		check(level.BASE == nil and ModesCourse.BASE_TOP == nil and ModesCourse.BASE_TOPS == nil, label .. " has no sea base")
		-- Recipe signatures.
		blinks[i] = 0
		local bounces = 0
		for _, e in level.ELEMENTS do
			if e.kind == "blink" then
				blinks[i] += 1
			elseif e.kind == "bounce" then
				bounces += 1
			end
		end
		local total, n = 0, 0
		for k = 1, #level.PATH - 1 do
			local a, c = level.PATH[k], level.PATH[k + 1]
			if a.kind ~= "slide" and c.kind ~= "slide" then
				total += shapeGap(a, a.x, a.z, c, c.x, c.z)
				n += 1
			end
		end
		meanGap[i] = total / n
		if i == 5 then
			check(bounces >= 2, "Bubble Bounce has two or more bounce pads")
		elseif i == 6 then
			check(last.y - first.y >= 20, "Coral Climb ends 20+ studs above its start")
		end
		check(b.x1 - b.x0 <= 600 and b.z1 - b.z0 <= 600, label .. " fits its region size")
		for j = i + 1, ModesCourse.LEVEL_COUNT do
			local o = ModesCourse.REGIONS[j]
			check(b.x1 < o.x0 or o.x1 < b.x0 or b.z1 < o.z0 or o.z1 < b.z0, string.format("regions %d and %d do not overlap", i, j))
		end
	end
	for i = 1, ModesCourse.LEVEL_COUNT do
		if i ~= 4 then
			check(blinks[4] > blinks[i], "Blink Reef has the most blink pads (vs map " .. i .. ")")
		end
		if i ~= 7 then
			check(
				meanGap[7] > meanGap[i],
				string.format("Shark Fin Sprint has the widest gaps (%.2f vs map %d %.2f)", meanGap[7], i, meanGap[i])
			)
		end
	end
	local slides = 0
	for _, e in ModesCourse.LEVELS[2].PATH do
		if e.kind == "slide" then
			slides += 1
		end
	end
	check(slides >= 1, "Coconut Cove has slides")
	local a, c = ModesCourse.generate(9), ModesCourse.generate(9)
	check(#a.PROPS == #c.PROPS, "same scenery on every call")
	for k, p in a.PROPS do
		check(p.kind == c.PROPS[k].kind and p.x == c.PROPS[k].x and p.z == c.PROPS[k].z, "prop " .. k .. " is deterministic")
	end
end)

test("Sky obby: big clear tiles, ring and hex pads, clouds far under the path", function()
	local C = ModesCourse
	-- Every path element and bridge step of the whole obby.
	local path = {}
	for _, level in C.LEVELS do
		for _, e in level.PATH do
			table.insert(path, e)
		end
	end
	for _, bridge in C.BRIDGES do
		for _, e in bridge do
			table.insert(path, e)
		end
	end
	local function under(e: any, x: number, z: number, r: number): boolean
		-- Does a puff of radius r at (x, z) reach under element e's footprint?
		local px, pz = e.x, e.z
		if e.from then
			px, pz = (e.from[1] + e.to[1]) / 2, (e.from[3] + e.to[3]) / 2
		end
		local reach = r + (if e.sx then math.max(e.sx, e.sz) / 2 elseif e.from then 40 else (e.r or 0)) + (e.distance or 0)
		return math.sqrt((px - x) ^ 2 + (pz - z) ^ 2) < reach
	end
	local shapes = { ring = 0, hex = 0 }
	for li, level in C.LEVELS do
		local label = "map " .. li
		local lo = math.huge
		for _, e in level.PATH do
			for _, pose in C.poses(e) do
				lo = math.min(lo, pose[2])
			end
			if e.from then
				lo = math.min(lo, e.from[2], e.to[2])
			end
			-- Tiles: nothing under 9 studs across (beams and slides are runways).
			if e.kind ~= "slide" and e.name ~= "Beam" then
				local across = if e.sx then math.min(e.sx, e.sz) elseif e.shape == "hex" then e.r * math.sqrt(3) else 2 * e.r
				check(across >= 9 - 1e-6, string.format("%s %s %s is 9+ studs across (%.2f)", label, e.kind, tostring(e.shape), across))
			end
			if e.shape == "ring" then
				shapes.ring += 1
				check(
					e.kind == "pad" and e.sx >= 12 and e.sx <= 14 and e.sz == e.sx and e.width == 3,
					label .. " ring is 12-14 square, frame 3"
				)
			elseif e.shape == "hex" then
				shapes.hex += 1
				check(e.kind == "pad" and e.r >= 6 and e.r <= 7, label .. " hex has radius 6-7")
			end
		end
		-- Ring / hex jumps: never touching, within reach from the flat side.
		for k = 1, #level.PATH - 1 do
			local a, b = level.PATH[k], level.PATH[k + 1]
			if
				(a.shape == "ring" or a.shape == "hex" or b.shape == "ring" or b.shape == "hex")
				and a.kind ~= "slide"
				and b.kind ~= "slide"
			then
				local near = C.edgeGap(a, a.x, a.z, b, b.x, b.z)
				local far = C.edgeGap(a, a.x, a.z, b, b.x, b.z, true)
				check(
					near >= 0.6 and far <= C.maxGap(b.y - a.y),
					string.format("%s %s -> %s jump is fair (%.2f..%.2f)", label, a.shape, b.shape, near, far)
				)
				check(
					math.abs(far - shapeGap(a, a.x, a.z, b, b.x, b.z, true)) < 1e-6,
					label .. " ring/hex gaps measure the same in Course and the tests"
				)
			end
		end
		-- The cloud floor: 40-80 thin, wide puffs far under the path, spread past the bounds,
		-- with open sky between them.
		local puffs = C.cloudLayer(level)
		check(#puffs >= 40 and #puffs <= 80, string.format("%s cloud floor has 40-80 puffs (%d)", label, #puffs))
		local b = level.BOUNDS
		local x0, x1, z0, z1 = math.huge, -math.huge, math.huge, -math.huge
		for _, puff in puffs do
			check(puff.h >= 6 and puff.h <= 10 and puff.d >= 40 and puff.d <= 120, label .. " cloud puff is thin and wide")
			check(
				puff.y + puff.h / 2 <= lo - C.CLOUD_FLOOR_DEPTH[1] + 1e-6 and puff.y - puff.h / 2 >= lo - C.CLOUD_FLOOR_DEPTH[2] - 1e-6,
				label .. " cloud puff floats 150-220 studs under the path"
			)
			x0, x1 = math.min(x0, puff.x - puff.d / 2), math.max(x1, puff.x + puff.d / 2)
			z0, z1 = math.min(z0, puff.z - puff.d / 2), math.max(z1, puff.z + puff.d / 2)
			for _, e in path do
				if under(e, puff.x, puff.z, puff.d / 2) then
					check(e.y - (puff.y + puff.h / 2) >= 30, label .. " cloud puff stays 30+ studs under every path element")
				end
			end
		end
		check(x0 < b.x0 - 40 and x1 > b.x1 + 40 and z0 < b.z0 - 40 and z1 > b.z1 + 40, label .. " cloud floor spreads well past the course")
		local open = 0
		for gx = 0, 9 do
			for gz = 0, 9 do
				local x, z = b.x0 + (b.x1 - b.x0) * gx / 9, b.z0 + (b.z1 - b.z0) * gz / 9
				local covered = false
				for _, puff in puffs do
					covered = covered or (puff.x - x) ^ 2 + (puff.z - z) ^ 2 <= (puff.d / 2) ^ 2
				end
				open += if covered then 0 else 1
			end
		end
		check(open >= 5, label .. " blue sky shows between the floor clouds (" .. open .. " open of 100)")
		eq(#C.cloudLayer(level), #puffs, label .. " cloud floor is deterministic")
		-- Cloud props: never within 30 studs under any path element of the obby.
		for _, p in level.PROPS do
			if p.kind == "cloud" then
				local foot = C.propFoot(p)
				local top = p.y + C.PROP_HEIGHT.cloud * (p.scale or 1)
				for _, e in path do
					if under(e, p.x, p.z, foot) then
						check(
							e.y - top >= 30,
							string.format("%s cloud at (%.0f, %.0f) is 30+ studs under %s", label, p.x, p.z, e.name or e.kind)
						)
					end
				end
			end
		end
	end
	check(shapes.ring >= 5 and shapes.hex >= 5, string.format("ring and hex pads along the path (%d, %d)", shapes.ring, shapes.hex))
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

test("Game modes: parkour regions stay apart, high above the hub", function()
	for i = 1, ModesCourse.LEVEL_COUNT do
		local r = ModesCourse.REGIONS[i]
		check(r == ModesCourse.LEVELS[i].BOUNDS, "region " .. i .. " is the level's bounds")
		for _, v in { r.x0, r.x1, r.z0, r.z1 } do
			check(math.abs(v) <= ModesCourse.CHAIN_LIMIT, "region " .. i .. " is within x, z +-1400")
		end
		check(r.y0 > 200 and r.y0 < ModesCourse.FLOOR_Y, "region " .. i .. " is high in the sky and holds the cloud floor")
		local c = ModesCourse.CENTRES[i]
		check(math.abs(c[1] - (r.x0 + r.x1) / 2) < 0.01 and math.abs(c[2] - (r.z0 + r.z1) / 2) < 0.01, "centre " .. i .. " is the region's")
		for j = i + 1, ModesCourse.LEVEL_COUNT do
			local o = ModesCourse.REGIONS[j]
			check(r.x1 < o.x0 or o.x1 < r.x0 or r.z1 < o.z0 or o.z1 < r.z0, string.format("regions %d and %d do not overlap", i, j))
		end
		for _, e in ModesCourse.LEVELS[i].ELEMENTS do
			check(ModesCourse.inBounds(ModesCourse.LEVELS[i], e.x, e.y, e.z), "level " .. i .. " elements inside its bounds")
		end
	end
end)

test("Sky obby: one chain of maps with rainbow bridges and global stages", function()
	local C = ModesCourse
	check(C.SKY_Y == 320 and C.FLOOR_Y == C.SKY_Y - 24, "sky and cloud floor heights")
	eq(C.STAGE_COUNT, C.LEVEL_COUNT + 1, "one stage per map, plus map 10's finish")
	eq(#C.RAINBOW, 8, "eight rainbow colours")
	eq(#C.BRIDGES, C.LEVEL_COUNT - 1, "a bridge between every two maps")
	local slot = 0
	local function colour(level: any, e: any, label: string)
		if e.kind == "pad" or e.kind == "slide" then
			eq(e.color, C.RAINBOW[slot % 8 + 1], label .. ": rainbow in walking order")
		elseif e.kind == "mover" then
			eq(e.color, level.palette.mover, label .. ": movers keep the map colour")
		elseif e.kind == "blink" then
			eq(e.color, level.palette.blink, label .. ": blink pads keep the map colour")
		end
		slot += 1
	end
	for i, level in C.LEVELS do
		local label = "map " .. i
		-- Stages run on from map to map.
		eq(level.STAGE_FIRST, if i == 1 then 1 else C.LEVELS[i - 1].STAGE_LAST, label .. " starts where the last map ended")
		eq(level.STAGE_FIRST, i, label .. " is stage " .. i)
		eq(level.STAGE_LAST, level.STAGE_FIRST + 1, label .. " finish stage")
		check(C.levelOfStage(level.STAGE_FIRST) == level, label .. " levelOfStage finds the map")
		-- High in the sky: every path top at or above SKY_Y, a fall is feet under FLOOR_Y.
		for k, e in level.PATH do
			local tops = if e.kind == "slide" then { e.from[2], e.to[2] } else { e.y }
			for _, y in tops do
				check(y >= C.SKY_Y - 1e-6, string.format("%s path %d top %.1f is in the sky", label, k, y))
			end
			check(not C.inWater(e.x, e.y, e.z), label .. " path " .. k .. " top is not a fall")
			colour(level, e, label .. " path " .. k)
		end
		check(C.inWater(level.START.x, C.FLOOR_Y - 1, level.START.z), label .. ": under the cloud floor is a fall")
		local w = level.WATER_BOX
		check(w.y1 == C.FLOOR_Y and w.y0 == C.FLOOR_Y - 20, label .. " cloud catch volume under the floor")
		-- The rainbow stair to the next map: six steps, each a fair little hop up.
		if i < C.LEVEL_COUNT then
			local bridge = C.BRIDGES[i]
			eq(#bridge, 6, label .. " bridge has six steps")
			local finish, start = level.PATH[#level.PATH], C.LEVELS[i + 1].PATH[1]
			eq(start.name, "StartDeck", label .. " bridge leads to the next start deck")
			local deckGap = shapeGap(finish, finish.x, finish.z, start, start.x, start.z)
			check(math.abs(deckGap - C.BRIDGE_GAP) < 0.02, string.format("%s next start deck 26 studs on (%.2f)", label, deckGap))
			local walk = { finish }
			for k, step in bridge do
				check(
					step.kind == "pad" and step.shape == "box" and step.name == "Bridge" and step.path,
					label .. " bridge step " .. k .. " is a pad"
				)
				colour(level, step, label .. " bridge step " .. k)
				table.insert(walk, step)
			end
			table.insert(walk, start)
			for k = 1, #walk - 1 do
				local a, c = walk[k], walk[k + 1]
				local gap = shapeGap(a, a.x, a.z, c, c.x, c.z)
				check(gap > 0.5 and gap <= 2, string.format("%s bridge hop %d gap %.2f", label, k, gap))
				check(c.y - a.y > 0 and c.y - a.y <= 1.5, string.format("%s bridge hop %d rise %.2f", label, k, c.y - a.y))
			end
			for j, r in C.REGIONS do
				for _, step in bridge do
					local inside = step.x >= r.x0 and step.x <= r.x1 and step.z >= r.z0 and step.z <= r.z1
					check(not inside or j == i or j == i + 1, label .. " bridge crosses no other map")
				end
			end
		end
	end
	local last = C.LEVELS[C.LEVEL_COUNT]
	eq(last.STAGE_LAST, C.STAGE_COUNT, "the last finish deck is the last stage")
	check(C.levelOfStage(C.STAGE_COUNT) == last, "levelOfStage(STAGE_COUNT) is the last map")
	local g1, g2 = C.generate(3), C.LEVELS[3]
	check(
		#g1.PATH == #g2.PATH and g1.PATH[5].x == g2.PATH[5].x and g1.PATH[5].color == g2.PATH[5].color,
		"generate matches the chained level"
	)
end)

-- Solo mini-games: gates, arenas and catalog (tests/minigames.luau), then each mode's own
-- rules (tests/shake.luau, tests/pose.luau, tests/bowling.luau; each builder owns its file).
require("./minigames")({ test = test, check = check, eq = eq })
require("./shake")({ test = test, check = check, eq = eq, near = near, seeded = seeded })
require("./pose")({ test = test, check = check, eq = eq, near = near, seeded = seeded })
require("./bowling")({ test = test, check = check, eq = eq, near = near, seeded = seeded })
-- Mog Test rules (tests/mog.luau).
require("./mog")({ test = test, check = check, eq = eq, near = near, seeded = seeded })
-- Cardio keyboard runner rules and layout (tests/cardio.luau).
require("./cardio")({ test = test, check = check, eq = eq, near = near, seeded = seeded })
-- Cardio chaser Chads (tests/cardio_chase.luau).
require("./cardio_chase")({ test = test, check = check, eq = eq, near = near, seeded = seeded })
-- Daily reward rules, the HUD's next goal and the saved daily field (tests/daily.luau).
require("./daily")({ test = test, check = check, eq = eq, near = near, loadShared = loadShared, loadDataService = loadDataService })
-- Interactive gym props: bounce, combo, swing and rep rules, and the gym poses (tests/interactive.luau).
require("./interactive")({ test = test, check = check, eq = eq, near = near, loadShared = loadShared })
-- Parkour server: Skip Map, stranded rescue and the timed return (tests/parkour_bugs.luau).
require("./parkour_bugs")({ test = test, check = check, eq = eq })
-- Buy Max, the Aura Surge announcements and the events Tycoon sends (tests/buymax.luau).
require("./buymax")({ test = test, check = check, eq = eq })
-- Aura packs paid as cash, and the shop's free gift (tests/shop.luau).
require("./shop")({ test = test, check = check, eq = eq })
-- Analytics: funnel steps, the economy ledger and custom events (tests/analytics.luau).
require("./analytics")({ test = test, check = check, eq = eq })
-- The Ranking window's own row: place, and the nearest player to pass (tests/ranking.luau).
require("./ranking")({ test = test, check = check, eq = eq })
-- Plot rank: dressing per five best tiers, rarity bands, champion sizes, fans (tests/plot_rank.luau).
require("./plot_rank")({ test = test, check = check, eq = eq })
-- Index milestones: rules, claims and the saved field (tests/index_rewards.luau).
require("./index_rewards")({ test = test, check = check, eq = eq, near = near, loadShared = loadShared, loadDataService = loadDataService })
-- Comeback hooks: the "While you were away" rows and the "Before you go" line (tests/comeback.luau).
require("./comeback")({ test = test, check = check, eq = eq, loadShared = loadShared })
-- What to buy next: the affordable pads, Buy Max, the best pick (tests/buy_next.luau).
require("./buy_next")({ test = test, check = check, eq = eq, loadShared = loadShared })
-- Every script compiles the way Studio compiles it: 200 locals per chunk (tests/fx_juice.luau).
require("./fx_juice")({ test = test, check = check })

test("Sky obby: lava kill strips and sliding bars on wide decks", function()
	for li, level in ModesCourse.LEVELS do
		local label = "level " .. li
		local kills = {}
		for _, e in level.ELEMENTS do
			if e.kind == "kill" then
				table.insert(kills, e)
				check(not e.path, label .. ": kill elements are not path elements")
			end
		end
		if li >= 2 then
			check(#kills >= 1 and #kills <= 1 + li // 3, label .. " kill count is 1 .. 1 + difficulty // 3")
		else
			eq(#kills, 0, label .. " has no kill elements")
		end
		eq(#level.KILLS, #kills, label .. " KILLS lists them")
		check(#kills <= ModesCourse.killCount(li), label .. " killCount is the cap")
		local perDeck = {}
		for ki, k in kills do
			local what = string.format("%s kill %d", label, ki)
			check(k.color == "Lava" and math.abs(k.h - 0.6) < 1e-6, what .. ": lava, 0.6 tall")
			-- The deck it stands on: a box path pad whose top is the kill's y.
			local deck, di
			for i, p in level.PATH do
				if
					p.shape == "box"
					and math.abs(p.y - k.y) < 0.01
					and math.abs(k.x - p.x) <= p.sx / 2 + 1e-6
					and math.abs(k.z - p.z) <= p.sz / 2 + 1e-6
				then
					deck, di = p, i
				end
			end
			check(deck ~= nil, what .. ": sits on a path pad's top")
			if not deck then
				continue
			end
			perDeck[deck] = perDeck[deck] or {}
			table.insert(perDeck[deck], k)
			check(#perDeck[deck] <= 2, what .. ": at most 2 per deck")
			for _, o in perDeck[deck] do
				if o ~= k then
					local gap = math.max(math.abs(o.x - k.x), math.abs(o.z - k.z)) - 1.6
					check(o.motion == nil and k.motion == nil and gap >= 6 - 1e-6, what .. ": 6 studs from the deck's other strip")
				end
			end
			local spun = false
			for _, o in level.ELEMENTS do
				if o.kind == "spinner" and math.abs(o.x - deck.x) <= deck.sx / 2 and math.abs(o.z - deck.z) <= deck.sz / 2 then
					spun = true
				end
			end
			if spun then
				-- Only when the map has no other eligible deck: no kill on a spinner-free deck.
				for _, o in kills do
					local free = true
					for _, sp in level.ELEMENTS do
						if
							sp.kind == "spinner"
							and math.abs(sp.y - o.y) < 0.01
							and math.abs(sp.x - o.x) < 20
							and math.abs(sp.z - o.z) < 20
						then
							free = false
						end
					end
					check(not free, what .. ": spinner decks only when nothing else is eligible")
				end
			end
			check(
				deck.kind == "pad"
					and deck.name ~= "StartDeck"
					and deck.name ~= "FinishDeck"
					and deck.name ~= "Bridge"
					and deck.name ~= "RestDeck",
				what .. ": not on the start/finish deck, a rest deck, mover or blink pad"
			)
			local from = level.PATH[di - 1]
			local alongX = math.abs(deck.x - from.x) >= math.abs(deck.z - from.z)
			local length = if alongX then deck.sx else deck.sz
			local across = if alongX then deck.sz else deck.sx
			check(length >= 16, what .. ": deck is at least 16 long")
			check(math.abs((if alongX then k.sx else k.sz) - 1.6) < 1e-6, what .. ": 1.6 across the walking axis")
			check(math.abs((if alongX then k.sz else k.sx) - across) < 1e-6, what .. ": full deck width")
			-- Along-axis span of the kill at a given offset, and the deck's.
			local deckC = if alongX then deck.x else deck.z
			local function spanAt(t: number): (number, number)
				local c = if alongX then k.x else k.z
				if k.motion == "slide" then
					local a = if alongX then k.axis[1] else k.axis[3]
					check(math.abs(math.abs(a) - 1) < 1e-6, what .. ": slides along the walking axis")
					c += a * k.distance * math.sin(2 * math.pi * t / k.period + k.phase)
				end
				return c - 0.8, c + 0.8
			end
			if k.motion == "slide" then
				check(length >= 20, what .. ": sliding bars on decks 20+ long")
				check(math.abs(k.distance - (length / 2 - 4)) < 0.01, what .. ": slides extent/2 - 4")
				check(k.period >= 4 and k.period <= 6, what .. ": period 4-6")
				for step = 0, 40 do
					local lo, hi = spanAt(step * k.period / 40)
					check(lo >= deckC - length / 2 - 1e-6 and hi <= deckC + length / 2 + 1e-6, what .. ": bar stays on its deck")
				end
			else
				local lo, hi = spanAt(0)
				check(lo - (deckC - length / 2) >= 4 - 1e-6, what .. ": 4 studs clear before it")
				check(deckC + length / 2 - hi >= 4 - 1e-6, what .. ": 4 studs clear after it")
			end
			-- Never within 2 studs of a wall or bounce pad on the deck (at any phase).
			for _, o in level.ELEMENTS do
				if (o.kind == "wall" or o.kind == "bounce") and math.abs(o.y - deck.y) < 0.01 then
					local oc = if alongX then o.x else o.z
					local half = if o.kind == "bounce" then o.r else (if alongX then o.sx else o.sz) / 2
					local onDeck = math.abs(o.x - deck.x) <= deck.sx / 2 and math.abs(o.z - deck.z) <= deck.sz / 2
					if onDeck then
						for step = 0, 20 do
							local lo, hi = spanAt(step * (k.period or 1) / 20)
							local gap = math.max(lo - (oc + half), (oc - half) - hi)
							check(gap >= 2 - 1e-6, what .. ": 2 studs from " .. o.kind)
						end
					end
				end
			end
			-- inKill: on the strip yes, 3 studs beside it (along the walk) no.
			for _, t in { 0, 0.7, 1.9, 3.3 } do
				local lo, hi = spanAt(t)
				local c = (lo + hi) / 2
				local function at(off: number): (number, number)
					if alongX then
						return c + off, k.z
					end
					return k.x, c + off
				end
				local x, z = at(0)
				check(ModesCourse.inKill(level, x, k.y + 0.1, z, t), what .. ": inKill on it")
				check(ModesCourse.inKill(level, x, k.y + 2.5, z, t), what .. ": inKill when hopping low over it")
				check(not ModesCourse.inKill(level, x, k.y + 4, z, t), what .. ": not when jumping high over it")
				for _, side in { -3, 3 } do
					local bx, bz = at(side)
					local hit = ModesCourse.inKill(level, bx, k.y + 0.1, bz, t)
					-- (unless another strip lies there)
					local other = false
					for _, o in kills do
						if o ~= k and o.motion == nil and math.abs(bx - o.x) <= o.sx / 2 and math.abs(bz - o.z) <= o.sz / 2 then
							other = true
						end
					end
					check(other or not hit, what .. ": not 3 studs beside it")
				end
			end
		end
		-- Start, finish and rest decks are always safe.
		local spots = { { level.START.x, level.START.y, level.START.z } }
		for _, e in level.PATH do
			if e.name == "RestDeck" then
				table.insert(spots, { e.x, e.y, e.z })
			end
		end
		local fin = level.PATH[#level.PATH]
		table.insert(spots, { fin.x, fin.y, fin.z })
		for _, s in spots do
			for step = 0, 24 do
				check(not ModesCourse.inKill(level, s[1], s[2] + 0.1, s[3], step * 0.25), label .. ": start/rest decks/finish are safe")
			end
		end
	end
	local a, b = ModesCourse.generate(9), ModesCourse.generate(9)
	check(#a.KILLS == #b.KILLS and a.KILLS[1].x == b.KILLS[1].x and a.KILLS[#a.KILLS].z == b.KILLS[#b.KILLS].z, "kills are deterministic")
end)

test("Game modes: a second plaza mirrored on the hub's +X side", function()
	local C = ModesCourse
	local p, q = C.PLAZA, C.PLAZA2
	eq(q.x0, -p.x1, "plaza2 x0")
	eq(q.x1, -p.x0, "plaza2 x1")
	check(q.z0 == p.z0 and q.z1 == p.z1 and q.top == p.top, "plaza2 z and top")
	check(C.SPUR2.x0 == -C.SPUR.x1 and C.SPUR2.x1 == -C.SPUR.x0 and C.SPUR2.half == C.SPUR.half, "spur2 mirrored")
	eq(C.GATE2_X, -C.GATE_X, "gate2 x")
	eq(C.START_LINE2_X, -C.START_LINE_X, "start line 2")
	for slot, g in C.GATES do
		eq(C.GATES2[slot].z, g.z, "gate2 " .. slot .. " z")
	end
	check(C.ARRIVAL2.x == -C.ARRIVAL.x and C.QUIT2.x == -C.QUIT.x, "arrival/quit mirrored")
	check(C.QUIT.faceX == 1 and C.QUIT2.faceX == -1, "quit spots face the hub")
	check(C.QUIT.x - C.GATE_X >= 18, "quit spot stands clear of the gates (the camera is behind the player)")
	check(C.QUIT.x < C.ARRIVAL.x and C.QUIT.x > C.PLAZA.x0 and C.QUIT.x < C.PLAZA.x1, "and on the plaza")
	check(C.ARRIVAL.faceX == -1 and C.ARRIVAL2.faceX == 1, "arrival spots face the gates")
	-- Portals: west through gate 1 at -X, east through the mirrored gate 1 at +X.
	local L1, L2 = C.START_LINE_X, C.START_LINE2_X
	check(C.crossedStart(L1 + 1, L1 - 1, 0), "west through gate 1 starts")
	check(not C.crossedStart(L1 - 1, L1 + 1, 0), "walking back out at -X does not")
	check(C.crossedStart(L2 - 1, L2 + 1, 0), "east through the mirrored gate 1 starts")
	check(not C.crossedStart(L2 + 1, L2 - 1, 0), "walking back out at +X does not")
	check(not C.crossedStart(L2 - 1, L2 + 1, C.GATES2[2].z), "the mirrored gate 2 is not the portal")
	check(not C.crossedStart(L1 + 1, L1 - 1, C.GATES[3].z), "gate 3 is not the portal")
	check(not C.crossedStart(0, 1, 0) and not C.crossedStart(-1, 1, 0), "walking about the hub does not")
	-- Nearest spots.
	check(C.nearestQuit(-150, 5) == C.QUIT and C.nearestQuit(150, -5) == C.QUIT2, "nearest quit")
	check(C.nearestArrival(-30, 0) == C.ARRIVAL and C.nearestArrival(30, 0) == C.ARRIVAL2, "nearest arrival")
	check(C.nearestQuit(-1, 80) == C.QUIT and C.nearestQuit(1, -80) == C.QUIT2, "the player's x decides")
	-- CLEAR covers both plazas (and mirrors itself).
	for _, r in { p, q } do
		for _, x in { r.x0, (r.x0 + r.x1) / 2, r.x1 } do
			for _, z in { r.z0, 0, r.z1 } do
				check(not C.isClear(x, z), string.format("CLEAR covers (%g, %g)", x, z))
			end
		end
	end
	check(not C.isClear(C.BIG_SIGN2.x, C.BIG_SIGN2.z), "CLEAR covers the second big sign")
	for _, r in C.CLEAR do
		local mirrored = false
		for _, o in C.CLEAR do
			mirrored = mirrored or (o.x0 == -r.x1 and o.x1 == -r.x0 and o.z0 == r.z0 and o.z1 == r.z1)
		end
		check(mirrored, "every CLEAR rectangle has its mirror")
	end
	-- The second plaza (and its spur) overlap no plot (World.Common: plots of half PLOT_HALF at
	-- (col * PLOT_SPACING_X, row * PLOT_ROW_Z)) and stay outside the hub ring.
	local half = Layout.PLOT_HALF
	local spacing, rowZ = half * 2 + 10, 32 + 12 + 10 + half
	for index = 1, 6 do
		local row = if index <= 3 then 1 else -1
		local px, pz = (((index - 1) % 3) - 1) * spacing, row * rowZ
		for _, r in { q, { x0 = C.SPUR2.x0, x1 = C.SPUR2.x1, z0 = -C.SPUR2.half, z1 = C.SPUR2.half } } do
			check(r.x1 < px - half or r.x0 > px + half or r.z1 < pz - half or r.z0 > pz + half, "plaza 2 clear of plot " .. index)
		end
	end
	near(C.SPUR2.x0, spacing + 19 + 5, "spur 2 starts at the hub ring's outer edge")
	-- World.Hub ISLAND_RADIUS: past the far corners of the outer plots, plus the beach.
	local island = math.ceil(math.sqrt((spacing + half) ^ 2 + (rowZ + half) ^ 2)) + 22
	check(math.sqrt(q.x1 ^ 2 + q.z1 ^ 2) + 20 < island, "plaza 2 stays on the island")
	check(math.abs(C.BIG_SIGN2.x) + 20 < island, "big sign 2 stays on the island")
	check(C.WATER_RADIUS >= island and C.WATER_RADIUS <= island + 8, "the sea line follows the island's shore")
end)

test("progression curve keeps its shape (scripts/simulate, no passes, coarse)", function()
	(_G :: any).SIMULATE_AS_LIBRARY = true
	local Simulate = require("../scripts/simulate")
	local theme = loadRobloxTheme("src/themes/chad/Theme.luau")
	local pack = theme.Modes.Reward
	eq(Simulate.SMALL_PACK_SECONDS, pack.Seconds, "simulated parkour reward uses the mode reward's seconds")
	eq(Simulate.SMALL_PACK_MIN, pack.Min, "simulated parkour reward uses the mode reward's minimum")

	-- The first tiers come fast (see the first-minutes test); after them each tier takes
	-- longer than the one before (every unit is bought at the first tier, and a tier makes
	-- three times the aura of the one below, less past Economy.FAST_TIERS).
	local stock = Simulate.run({ hours = 5, step = 5 })
	local reached = stock.reached
	local function by(tier: number, seconds: number): boolean
		return reached[tier] ~= nil and reached[tier] <= seconds
	end
	check(by(2, 60), "tier 2 within the first minute")
	check(by(6, 10 * 60), "tier 6 by 10 minutes")
	check(by(7, 15 * 60), "tier 7 by 15 minutes")
	check(by(8, 25 * 60), "tier 8 by 25 minutes")
	check(by(10, 60 * 60) and reached[10] >= 25 * 60, "tier 10 between 25 and 60 minutes")
	check(by(12, 2 * 3600), "tier 12 by 2 hours")
	check(by(15, 5 * 3600), "tier 15 by 5 hours")
	check(stock.converterShare >= 0.5, "the converter passes at least half the production (" .. stock.converterShare .. ")")

	-- With the periodic extras (free gift, mode reward, surge, crates).
	local extras = Simulate.run({ hours = 2, step = 5, extras = true })
	reached = extras.reached
	check(by(10, 30 * 60), "extras: tier 10 by 30 minutes")
	check(by(15, 2 * 3600), "extras: tier 15 by 2 hours")
	check(extras.converterShare >= 0.5, "extras: the converter passes at least half the production")
	near(Simulate.depositBonus(), 0.154, "average deposit bonus")
end)

test("daily sessions (scripts/simulate): offline cash and the longest wait", function()
	(_G :: any).SIMULATE_AS_LIBRARY = true
	local Simulate = require("../scripts/simulate")
	-- One long session and half an hour a day, the same hours of play: the cash made while
	-- away brings every late tier sooner in play time.
	local session = Simulate.run({ hours = 30, step = 30, extras = true })
	local daily = Simulate.run({ hours = 30, step = 30, extras = true, minutesPerDay = 30 })
	local top = Economy.MAX_TIER
	check(session.reached[top] ~= nil and daily.reached[top] ~= nil, "both find every tier")
	check(daily.reached[15] < session.reached[15], "offline cash: tier 15 in less play time")
	check(daily.reached[top] < session.reached[top], "and the top tier too")
	local days = daily.reached[top] / 1800
	check(days >= 25 and days <= 40, string.format("half an hour a day finds every tier in about a month (%.0f days)", days))
	-- The longest wait is counted on the calendar, and nothing is waited for after the top tier.
	check(
		daily.longestWait >= 3 * 86400 and daily.longestWait <= 10 * 86400,
		string.format("the longest wait for a tier is days, under ten (%.1f)", daily.longestWait / 86400)
	)
	eq(daily.waitAt, top - 1, "and it is the wait for the last tier")
	check(session.longestWait <= 8 * 3600, "one session: the wait is play time")
	-- A run that ends short of the top tier counts the wait still running.
	local short = Simulate.run({ hours = 2, step = 30 })
	check(short.reached[top] == nil, "two hours do not reach the top")
	check(short.longestWait > 0 and short.waitAt >= 10, "the wait at the end is counted (tier " .. short.waitAt .. ")")
end)

test("first minutes: a new player merges early and always has something to buy", function()
	(_G :: any).SIMULATE_AS_LIBRARY = true
	local Simulate = require("../scripts/simulate")
	local result = Simulate.firstMinutes({ minutes = 12 })
	local reached = result.reached
	check(result.tutorialDone ~= nil and result.tutorialDone <= 45, "tutorial and first merge within 45 s")
	check(reached[2] ~= nil and reached[2] <= 45, "tier 2 by 45 s")
	check(reached[3] ~= nil and reached[3] <= 90, "tier 3 by 90 s")
	check(reached[4] ~= nil and reached[4] <= 150, "tier 4 by 2.5 min")
	check(reached[5] ~= nil and reached[5] <= 200, "tier 5 soon after 3 min")
	check(reached[6] ~= nil and reached[6] <= 300, "tier 6 by 5 min")
	check(reached[7] ~= nil and reached[7] < 480, "tier 7 before minute 8")
	check(reached[8] ~= nil and reached[8] >= 300 and reached[8] <= 600, "tier 8 between minute 5 and 10")
	check(result.longestGap <= 25, "never over 25 s without a purchase in the first 6 minutes (" .. result.longestGap .. ")")
	check(result.converterShare >= 0.5, "the converter passes at least half the production (" .. result.converterShare .. ")")

	-- A player who never steps on an upgrade pad is carried by the free converter floor.
	local idle = Simulate.firstMinutes({ minutes = 12, noUpgrades = true })
	check(idle.reached[8] ~= nil and idle.reached[8] <= 600, "no converter upgrades: still tier 8 by minute 10")
	check(idle.converterShare >= 0.5, "no converter upgrades: still at least half the production")
	eq(idle.processLevel, Economy.minProcessLevel(Economy.highestTier(idle.reached)), "the floor of the best tier")

	-- A slower player (longer paths, more reading) still gets there.
	local speed, read = Simulate.PATH_SLACK, Simulate.STEP_READ
	Simulate.PATH_SLACK, Simulate.STEP_READ = 1.6, 4
	local slow = Simulate.firstMinutes({ minutes = 8, introSeconds = 2 })
	Simulate.PATH_SLACK, Simulate.STEP_READ = speed, read
	check(slow.reached[2] ~= nil and slow.reached[2] <= 45, "slow player: tier 2 by 45 s")
	check(slow.reached[3] ~= nil and slow.reached[3] <= 90, "slow player: tier 3 by 90 s")
	check(slow.reached[5] ~= nil and slow.reached[5] <= 240, "slow player: tier 5 by 4 min")
	check(slow.reached[6] ~= nil and slow.reached[6] <= 420, "slow player: tier 6 by 7 min")
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
	eq(Brand.LogoShine, Assets.Images["brand/LogoShine"], "Brand.LogoShine")
	eq(Brand.SoftDot, Assets.Images["vfx/SoftDot"], "Brand.SoftDot")
	eq(Brand.Sparkle, Assets.Images["vfx/Sparkle"], "Brand.Sparkle")
	for _, key in { "image", "x", "y", "w", "h" } do
		eq(Brand.Orb[key], Assets.Icons.Orb[key], "Brand.Orb." .. key)
	end
end)

test("PadLabelSize: pad labels keep their world size far away and are capped up close", function()
	local PadLabelSize = require("../src/shared/PadLabelSize")
	local vy, fov = 1000, 70
	-- A buy-row label (7.5 studs x 0.8 wide, LABEL_PX 32) seen from the spawn, ~60 studs away.
	local w, h, capped = PadLabelSize.size(6, 32, 6 * 0.62, 32 * 0.62, 60, vy, fov)
	check(not capped, "from the spawn the label is not capped")
	check(math.abs(w - (6 * PadLabelSize.pixelsPerStud(60, vy, fov) + 32)) < 1e-6, "natural width = studs x px/stud + px")
	check(math.abs(h / w - 0.62) < 1e-6, "natural shape kept")
	-- Standing on the pad: ~15 studs from the camera.
	local cw, ch, near = PadLabelSize.size(6, 32, 6 * 0.62, 32 * 0.62, 15, vy, fov)
	check(near, "up close the label is capped")
	eq(cw, PadLabelSize.MAX_SHARE * vy, "capped width = MAX_SHARE of the viewport height")
	check(math.abs(ch / cw - 0.62) < 1e-6, "capped label keeps its shape")
	check(cw <= 2.2 * w, "up close it is at most about twice its spawn size")
	-- The neighbouring pad's centre is 10.25 studs away: two capped labels never meet.
	check(10.25 * PadLabelSize.pixelsPerStud(17, vy, fov) > cw, "neighbouring capped labels stay apart")
	local _, _, behind = PadLabelSize.size(6, 32, 3.72, 19.84, -5, vy, fov)
	check(behind, "a label at or behind the camera counts as close")
	local ww = PadLabelSize.size(6, 32, 3.72, 19.84, 60, 2 * vy, fov)
	check(ww > w, "a taller viewport draws it bigger")
	local pads = fs.readFile("src/server/World/Pads.luau")
	check(string.find(pads, 'AddTag(gui, "PadLabel")', 1, true) ~= nil, "World.Pads tags its labels for Fx.PadLabels")
	check(string.find(pads, 'SetAttribute("BaseSize"', 1, true) ~= nil, "and stores their own size")
	check(string.find(fs.readFile("src/client/Main.client.luau"), '"PadLabels"', 1, true) ~= nil, "Main starts Fx.PadLabels")
end)

test("PadLabelSize: far labels stacked behind nearer ones fade, with hysteresis", function()
	local PadLabelSize = require("../src/shared/PadLabelSize")
	local function r(x: number, y: number, w: number, h: number)
		return { x = x, y = y, w = w, h = h }
	end
	eq(PadLabelSize.overlapShare(r(0, 0, 10, 10), r(20, 0, 10, 10)), 0, "apart: no overlap")
	eq(PadLabelSize.overlapShare(r(0, 0, 10, 10), r(10, 0, 10, 10)), 0, "touching edges: no overlap")
	check(math.abs(PadLabelSize.overlapShare(r(0, 0, 10, 10), r(5, 0, 10, 10)) - 0.5) < 1e-9, "half over: 0.5")
	eq(PadLabelSize.overlapShare(r(0, 0, 40, 40), r(0, 0, 10, 10)), 1, "share of the smaller rect")
	eq(PadLabelSize.overlapShare(r(0, 0, 0, 10), r(0, 0, 10, 10)), 0, "an empty rect overlaps nothing")
	-- The spawn view: the row's labels side by side, none faded.
	local spawn = { r(100, 300, 80, 50), r(200, 300, 80, 50), r(300, 300, 80, 50), r(400, 300, 80, 50) }
	local out = PadLabelSize.declutter(spawn, {})
	for i = 1, #spawn do
		check(not out[i], "spawn view: every label shown")
	end
	-- Looking along the row from Buy 1: the far labels stack (nearest first).
	local along = { r(300, 300, 200, 120), r(700, 280, 60, 36), r(712, 280, 50, 30), r(720, 281, 44, 26) }
	out = PadLabelSize.declutter(along, {})
	check(not out[1] and not out[2], "the nearest labels stay shown")
	check(out[3] and out[4], "labels stacked behind them fade")
	-- Only nearer labels left shown count: a faded one hides nothing.
	out = PadLabelSize.declutter({ r(0, 0, 10, 10), r(5, 0, 10, 10), r(12, 0, 10, 10) }, {})
	check(out[2] and not out[3], "the third label is checked against the shown first, not the faded second")
	-- Hysteresis: between FADE_IN_SHARE and FADE_OUT_SHARE a label keeps its state.
	check(PadLabelSize.FADE_IN_SHARE < PadLabelSize.FADE_OUT_SHARE, "fade-in sits under fade-out")
	local a, b = r(0, 0, 10, 10), r(8.8, 0, 10, 10) -- 12% overlap
	check(not PadLabelSize.declutter({ a, b }, { false, false })[2], "12% overlap: a shown label stays shown")
	check(PadLabelSize.declutter({ a, b }, { false, true })[2], "12% overlap: a faded label stays faded")
	check(not PadLabelSize.declutter({ a, r(9.6, 0, 10, 10) }, { false, true })[2], "4%: it comes back")
	check(PadLabelSize.declutter({ a, r(8, 0, 10, 10) }, { false, false })[2], "20%: it fades")
	-- Seen on the server: Buy 25 over a fifth of Buy 100's sign hid its price; that fades now.
	check(PadLabelSize.declutter({ r(0, 0, 118, 72), r(90, 0, 111, 68) }, { false, false })[2], "a 22% cover fades")
	-- The spawn view's worst overlap on the server (Buy 5 over Buy 1, up to 7%) stays shown, and
	-- a sign faded on the way there comes back.
	local brush = { r(0, 0, 118, 73), r(-107, 0, 111, 68) }
	check(PadLabelSize.overlapShare(brush[1], brush[2]) > 0.06, "the spawn brush is over 6%")
	check(not PadLabelSize.declutter(brush, { false, false })[2], "a 7% brush stays shown")
	check(not PadLabelSize.declutter(brush, { false, true })[2], "and a faded sign comes back there")
	check(not PadLabelSize.declutter({ r(0, 0, 10, 10), r(9.17, 0, 10, 10) }, { false, true })[2], "an 8.3% brush (narrow window) brings a faded sign back")
	-- The label the player stands at is never faded.
	out = PadLabelSize.declutter({ r(0, 0, 10, 10), r(0, 0, 10, 10) }, { false, true }, { false, true })
	check(not out[2], "a kept label stays shown")
	local labels = fs.readFile("src/client/Fx/PadLabels.luau")
	check(string.find(labels, "PadLabelSize.declutter", 1, true) ~= nil, "Fx.PadLabels declutters the plot's labels")
	-- The plot's other floating signs join in: a nearer sign hides a farther one, whatever its kind.
	check(
		string.find(fs.readFile("src/server/WorldBuilder.luau"), 'AddTag(gui, "PlotSign")', 1, true) ~= nil,
		"the READY! pill is a PlotSign"
	)
	check(string.find(labels, 'SIGN_TAG = "PlotSign"', 1, true) ~= nil, "Fx.PadLabels declutters the PlotSign signs too")
	-- A BillboardGui ignores GroupTransparency: a faded label's group must be hidden outright.
	check(string.find(labels, "f.group.Visible = false", 1, true) ~= nil, "a faded label's group is hidden once out")
	check(string.find(labels, "f.group.Visible = true", 1, true) ~= nil, "and shown again as it fades back in")
	-- Diagnostics: each label's worst overlap and the shown label giving it.
	local _, shares, covers = PadLabelSize.declutter({ r(0, 0, 10, 10), r(7, 0, 10, 10), r(40, 0, 10, 10) }, {})
	check(math.abs(shares[2] - 0.3) < 1e-6 and covers[2] == 1, "declutter reports the overlap and its cover")
	check(shares[3] == 0 and covers[3] == 0 and covers[1] == 0, "and none for a clear label")
	check(
		string.find(fs.readFile("src/server/TestBridge.luau"), "COMMANDS.labels", 1, true) ~= nil,
		"the TEST bridge has the labels diagnostic"
	)
	check(string.find(fs.readFile("src/client/Guide.luau"), "Declutter", 1, true) == nil, "Client.Guide is left alone")
end)

test("PadLabelSize: a label glides from its near to its far placement with the camera's distance", function()
	local PadLabelSize = require("../src/shared/PadLabelSize")
	local nearD, farD = PadLabelSize.NEAR_DISTANCE, PadLabelSize.FAR_DISTANCE
	eq(nearD, 22, "near placement within 22 studs")
	eq(farD, 36, "far placement from 36 studs")
	eq(PadLabelSize.blend(0), 0, "on the pad: near")
	eq(PadLabelSize.blend(nearD), 0, "at NEAR_DISTANCE: still near")
	eq(PadLabelSize.blend(farD), 1, "at FAR_DISTANCE: far")
	eq(PadLabelSize.blend(200), 1, "past it: far")
	check(math.abs(PadLabelSize.blend((nearD + farD) / 2) - 0.5) < 1e-9, "halfway between: halfway")
	local last = 0
	for d = nearD, farD, 0.25 do
		local t = PadLabelSize.blend(d)
		check(t >= last, "the glide never turns back")
		check(t - last < 0.04, "and never jumps")
		last = t
	end
	check(PadLabelSize.blend(nearD + 0.1) < 0.001, "it eases out of the near placement")
	check(1 - PadLabelSize.blend(farD - 0.1) < 0.001, "and into the far one")
	local near, far = Vector3.new(-1.5, 7.6, 4), Vector3.new(-3, 10, 7)
	local function same(a: Vector3, b: Vector3): boolean
		return (a - b).Magnitude < 1e-6
	end
	check(same(PadLabelSize.placement(near, far, 5), near), "up close it sits at its near placement")
	check(same(PadLabelSize.placement(near, far, 50), far), "from afar at its far one")
	check(same(PadLabelSize.placement(near, far, 29), Vector3.new(-2.25, 8.8, 5.5)), "between them on the line")
	check(same(PadLabelSize.placement(far, far, 18), far), "a label with one placement stays put")
	local pads = fs.readFile("src/server/World/Pads.luau")
	check(string.find(pads, 'SetAttribute("NearOffset"', 1, true) ~= nil, "World.Pads stores the near placement")
	check(string.find(pads, 'SetAttribute("FarOffset"', 1, true) ~= nil, "and the far one")
	check(string.find(pads, "Buy1 = { lift = 6.4, shift = Vector2.new(-1.5, 1) }", 1, true) ~= nil, "Buy 1 sits over its pad up close")
	check(string.find(pads, "Buy1 = Vector2.new(-3, 7)", 1, true) ~= nil, "and high and back from afar")
	check(string.find(pads, "Buy1 = 10,", 1, true) ~= nil, "clear of the BUY 5 tag")
	check(string.find(fs.readFile("src/client/Fx/PadLabels.luau"), "PadLabelSize.blend", 1, true) ~= nil, "Fx.PadLabels glides by it")
	check(string.find(fs.readFile("src/client/Guide.luau"), '"NearOffset", "FarOffset"', 1, true) ~= nil, "Guide clears both placements")
end)

test("TestBridge: setcash and pending go through Tycoon and are documented", function()
	local bridge = fs.readFile("src/server/TestBridge.luau")
	local tycoon = fs.readFile("src/server/Tycoon.luau")
	local doc = fs.readFile("docs/agent-playtest.md")
	check(string.find(bridge, "COMMANDS.setcash", 1, true) ~= nil, "setcash command")
	check(string.find(bridge, "Tycoon.setMoney(session", 1, true) ~= nil, "setcash uses Tycoon.setMoney")
	check(string.find(bridge, "COMMANDS.pending", 1, true) ~= nil, "pending command")
	check(string.find(bridge, "Tycoon.setPending(session", 1, true) ~= nil, "pending uses Tycoon.setPending")
	check(string.find(tycoon, "function Tycoon.setMoney(", 1, true) ~= nil, "Tycoon.setMoney exists")
	check(string.find(tycoon, "session.profile.pending = math.max(0, amount)", 1, true) ~= nil, "setPending sets profile.pending")
	check(string.find(doc, "| `setcash` | `{amount}` |", 1, true) ~= nil, "setcash documented")
	check(string.find(doc, "| `pending` | `{amount}` |", 1, true) ~= nil, "pending documented")
end)

print(string.format("\n%d passed, %d failed", passed, failed))
if failed > 0 then
	process.exit(1)
end
