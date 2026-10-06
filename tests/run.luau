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
		check(theme.Decor == nil or theme.Decor == "gym" or theme.Decor == "factory", "decor style")
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

test("plot layout: pool and ramps", function()
	local pool = Layout.POOL
	local width = pool.maxX - pool.minX
	local depth = pool.maxZ - pool.minZ
	check(width >= 50 and width <= 62, "pool roughly 56 wide")
	check(depth >= 22 and depth <= 30, "pool roughly 26 deep")
	check(Layout.POOL_FLOOR_Y <= -3 and Layout.POOL_FLOOR_Y >= -5, "pool ~4 studs deep")
	eq(#Layout.RAMPS, 2, "two ramps")
	for _, ramp in Layout.RAMPS do
		local r = ramp.rect
		check(r.minX >= pool.minX and r.maxX <= pool.maxX and r.minZ >= pool.minZ and r.maxZ <= pool.maxZ, "ramp inside pool")
		-- A ramp's high end touches the pool edge on its own side.
		check(if ramp.side > 0 then r.maxX == pool.maxX else r.minX == pool.minX, "ramp meets the floor edge")
		local slope = math.deg(math.atan(-Layout.POOL_FLOOR_Y / (r.maxX - r.minX)))
		check(slope < 30, "ramp is walkable")
		check(not Layout.overlaps(r, Layout.ORB_AREA), "orbs never land on a ramp")
	end
	local o = Layout.ORB_AREA
	check(o.minX >= pool.minX and o.maxX <= pool.maxX and o.minZ >= pool.minZ and o.maxZ <= pool.maxZ, "orb area inside pool")
	check(o.maxX - o.minX > 20 and o.maxZ - o.minZ > 15, "orb area is roomy")
	-- The pool sits directly in front of the bleachers.
	local shelves = Layout.MACHINES.Shelves
	check(shelves.minZ >= pool.maxZ and shelves.minZ - pool.maxZ < 3, "pool right in front of the bleachers")
	check(Layout.inPool(0, (pool.minZ + pool.maxZ) / 2), "pool centre is in the pool")
	check(not Layout.inPool(0, pool.minZ - 2), "floor in front of the pool is not")
end)

test("plot layout: pads", function()
	local inner = Layout.INNER_HALF
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

	for i, nameA in Layout.PAD_ORDER do
		local spot = Layout.PADS[nameA]
		local rim = Layout.padRect(spot, Layout.PAD_RIM)
		check(rim.minX >= -inner and rim.maxX <= inner and rim.minZ >= -inner and rim.maxZ <= inner, nameA .. " inside the walls")
		check(not Layout.overlaps(rim, Layout.POOL, 1.5), nameA .. " clear of the pool")
		for _, ramp in Layout.RAMPS do
			check(not Layout.overlaps(rim, ramp.rect, 1.5), nameA .. " clear of the ramps")
		end
		for machine, rect in Layout.MACHINES do
			check(not Layout.overlaps(rim, rect), nameA .. " clear of " .. machine)
		end
		for j = i + 1, #Layout.PAD_ORDER do
			local nameB = Layout.PAD_ORDER[j]
			check(not Layout.overlaps(rim, Layout.padRect(Layout.PADS[nameB], Layout.PAD_RIM)), nameA .. " vs " .. nameB)
		end
		-- The spawn point must not start on a pad.
		check(not Layout.contains(Layout.padRect(spot, 2), Layout.SPAWN.x, Layout.SPAWN.z), nameA .. " clear of spawn")
	end
end)

test("plot layout: crate areas", function()
	check(#Layout.CHEST_AREAS >= 1, "has crate areas")
	for _, area in Layout.CHEST_AREAS do
		-- Crates are ~3.4 studs wide and picked up within 5 studs: keep them off pads and out of the pool.
		check(not Layout.overlaps(area, Layout.POOL, 6), "crate area away from the pool")
		for _, name in Layout.PAD_ORDER do
			check(not Layout.overlaps(area, Layout.padRect(Layout.PADS[name], Layout.PAD_RIM), 2), "crate area clear of " .. name)
		end
		for machine, rect in Layout.MACHINES do
			check(not Layout.overlaps(area, rect, 2), "crate area clear of " .. machine)
		end
	end
end)

print(string.format("\n%d passed, %d failed", passed, failed))
if failed > 0 then
	process.exit(1)
end
