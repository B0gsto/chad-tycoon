--[[
	Unit tests for the pure shared modules and both themes.
	Run with:  lune run tests/run
]]

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local process = require("@lune/process")

local Economy = require("../src/shared/Economy")
local Format = require("../src/shared/Format")
local SessionLock = require("../src/shared/SessionLock")
local TutorialSteps = require("../src/shared/TutorialSteps")

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
		check(Economy.buyTierRequirement(buyTier) >= 150, "requirement")
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
			local tier = Economy.rollChest(rarity, 10, rng)
			check(tier >= 8 and tier <= 14, "roll near highest tier")
		end
		check(Economy.chestMoneyPrice(rarity, 10) > 0, "money price")
		check(Economy.unlockSeconds(rarity, true) < Economy.unlockSeconds(rarity, false), "premium is faster")
	end
	check(not Economy.isRarity("Bogus"), "unknown rarity rejected")
	local common = Economy.chestOdds("Common", 6)
	eq(common[1].tier, 4)
	eq(common[1].chance, 75)
	eq(common[3].tier, 6)
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

test("tier bands", function()
	eq(Economy.tierBand(1), "Common")
	eq(Economy.tierBand(6), "Uncommon")
	eq(Economy.tierBand(15), "Rare")
	eq(Economy.tierBand(20), "Epic")
	eq(Economy.tierBand(24), "Legendary")
	eq(Economy.tierBand(25), "Mythic")
	eq(Economy.moneyPackAmount(10, 300, 1000), 3000)
	eq(Economy.moneyPackAmount(0, 300, 1000), 1000)
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
	"Panel",
	"PanelLight",
	"PanelDark",
	"Stroke",
	"Orb",
	"OrbBig",
	"Floor",
	"Wall",
	"Neon",
	"NeonAlt",
	"Pad",
	"PadDisabled",
	"Hub",
}
local ACCESSORIES = {
	Cap = true,
	Headband = true,
	Shades = true,
	Visor = true,
	Chain = true,
	Crown = true,
	Halo = true,
	Horns = true,
	Antenna = true,
	Cape = true,
	Wings = true,
	Backpack = true,
	Shoulders = true,
}

for _, variant in { "chad", "bot" } do
	test("theme " .. variant, function()
		local theme = loadTheme("src/themes/" .. variant .. "/Theme.luau")
		eq(theme.Id, variant, "id")
		eq(#theme.Tiers, Economy.MAX_TIER, "tier count")
		local names = {}
		for tier, entry in theme.Tiers do
			check(type(entry.Name) == "string" and #entry.Name > 0, "tier " .. tier .. " has a name")
			check(not names[entry.Name], "tier name unique: " .. tostring(entry.Name))
			names[entry.Name] = true
			local look = entry.Look
			check(look and look.skin and look.shirt and look.pants, "tier " .. tier .. " has colours")
			for _, acc in look.acc or {} do
				check(ACCESSORIES[acc] == true, "known accessory " .. acc)
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
		eq(#theme.Monetization.MoneyPacks, 6, "money packs")
		eq(#theme.Monetization.GemPacks, 3, "gem packs")
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
	end)
end

print(string.format("\n%d passed, %d failed", passed, failed))
if failed > 0 then
	process.exit(1)
end
