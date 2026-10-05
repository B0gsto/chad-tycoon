--!strict
--[[
	Economy: every balance number and pure formula in the game.

	This module has no Roblox dependencies so it can be unit-tested with Lune
	(see tests/). Both variants share it; only names, colours and looks differ
	per theme.

	Core loop:
	  buy units -> units drop orbs -> walk over orbs to carry them
	  -> deposit at the converter (x random multiplier) -> processed into cash
	  -> collect cash -> buy more / upgrade.
	Two units of the same tier merge into one unit of the next tier.
]]

local Economy = {}

Economy.VERSION = "1.0.0"

Economy.MAX_TIER = 25
Economy.MAX_BUY_TIER = 15
Economy.MERGE_RATIO = 2
Economy.DISPLAY_SLOTS = 30

-- Production ------------------------------------------------------------------

-- Each tier produces this many times more than the previous one. Must be greater
-- than MERGE_RATIO so merging is always an upgrade.
Economy.TIER_RATE_GROWTH = 2.6

function Economy.unitRate(tier: number): number
	return Economy.TIER_RATE_GROWTH ^ (tier - 1)
end

function Economy.productionPerSecond(units: { number }): number
	local total = 0
	for tier = 1, Economy.MAX_TIER do
		local count = units[tier] or 0
		if count > 0 then
			total += count * Economy.unitRate(tier)
		end
	end
	return total
end

function Economy.totalUnits(units: { number }): number
	local total = 0
	for tier = 1, Economy.MAX_TIER do
		total += units[tier] or 0
	end
	return total
end

function Economy.highestTier(discovered: { number }): number
	for tier = Economy.MAX_TIER, 1, -1 do
		if (discovered[tier] or 0) > 0 then
			return tier
		end
	end
	return 1
end

-- Merges every pair it can, cascading upward. Mutates `units` in place.
-- Returns how many merges happened and the highest tier that received a unit.
function Economy.mergeAll(units: { number }): (number, number)
	local merges = 0
	local topCreated = 0
	for tier = 1, Economy.MAX_TIER - 1 do
		local count = units[tier] or 0
		local made = math.floor(count / Economy.MERGE_RATIO)
		if made > 0 then
			units[tier] = count - made * Economy.MERGE_RATIO
			units[tier + 1] = (units[tier + 1] or 0) + made
			merges += made
			topCreated = tier + 1
		end
	end
	return merges, topCreated
end

-- Buying ----------------------------------------------------------------------

Economy.BUY_BASE_PRICE = 20
Economy.BUY_PRICE_GROWTH = 2.3
Economy.BUY_AMOUNTS = { 1, 5, 25, 100 }

function Economy.basePrice(buyTier: number): number
	return Economy.BUY_BASE_PRICE * Economy.BUY_PRICE_GROWTH ^ (buyTier - 1)
end

-- Units that must be bought at the current buy tier before it can be upgraded.
function Economy.buyTierRequirement(buyTier: number): number
	return math.floor(150 * 1.6 ^ (buyTier - 1))
end

-- Price of the next single unit. Grows linearly with purchases made at this
-- tier (2x once the upgrade requirement is reached) to push tier upgrades.
function Economy.unitPrice(buyTier: number, boughtAtTier: number): number
	return Economy.basePrice(buyTier) * (1 + boughtAtTier / Economy.buyTierRequirement(buyTier))
end

-- Exact sum of unitPrice for `amount` consecutive purchases.
function Economy.bulkPrice(buyTier: number, boughtAtTier: number, amount: number): number
	local req = Economy.buyTierRequirement(buyTier)
	local linear = amount * boughtAtTier + amount * (amount - 1) / 2
	return Economy.basePrice(buyTier) * (amount + linear / req)
end

function Economy.buyTierUpgradeCost(buyTier: number): number
	return Economy.basePrice(buyTier + 1) * Economy.buyTierRequirement(buyTier) * 0.5
end

Economy.AUTO_MERGE_COST = 25000

-- Processing (the converter that turns deposited orbs into cash) ---------------

Economy.PROCESS_BASE = 10
Economy.PROCESS_GROWTH = 1.12
Economy.PROCESS_COST_BASE = 75
Economy.PROCESS_COST_GROWTH = 1.155
Economy.PROCESS_BULK = 10

function Economy.processRate(level: number): number
	return Economy.PROCESS_BASE * Economy.PROCESS_GROWTH ^ level
end

function Economy.processUpgradeCost(level: number): number
	return Economy.PROCESS_COST_BASE * Economy.PROCESS_COST_GROWTH ^ level
end

-- Cost of buying `amount` levels starting from `level` (geometric series).
function Economy.processBulkCost(level: number, amount: number): number
	local g = Economy.PROCESS_COST_GROWTH
	return Economy.processUpgradeCost(level) * (g ^ amount - 1) / (g - 1)
end

-- Cash value of one orb point before multipliers.
Economy.CASH_PER_POINT = 1

-- Deposit multiplier (global, rerolled on a timer) ------------------------------

Economy.DEPOSIT_REROLL_SECONDS = 20
Economy.DEPOSIT_MULTIPLIERS = {
	{ value = 0.5, weight = 6 },
	{ value = 0.7, weight = 10 },
	{ value = 0.8, weight = 12 },
	{ value = 0.9, weight = 14 },
	{ value = 1.0, weight = 16 },
	{ value = 1.1, weight = 14 },
	{ value = 1.2, weight = 10 },
	{ value = 1.3, weight = 8 },
	{ value = 1.5, weight = 5 },
	{ value = 1.8, weight = 3 },
	{ value = 2.0, weight = 1.5 },
	{ value = 3.0, weight = 0.5 },
}
Economy.DEPOSIT_MIN = 0.5
Economy.DEPOSIT_MAX = 3.0

local function pickWeighted<T>(entries: { T }, weightOf: (T) -> number, roll: number): T
	local total = 0
	for _, entry in entries do
		total += weightOf(entry)
	end
	local target = roll * total
	for _, entry in entries do
		target -= weightOf(entry)
		if target < 0 then
			return entry
		end
	end
	return entries[#entries]
end

function Economy.rollDepositMultiplier(rng: () -> number): number
	local entry = pickWeighted(Economy.DEPOSIT_MULTIPLIERS, function(e)
		return e.weight
	end, rng())
	return entry.value
end

-- Global "surge" event: double orbs for the last part of every cycle. ----------

Economy.SURGE_CYCLE = 600
Economy.SURGE_DURATION = 120
Economy.SURGE_MULTIPLIER = 2

-- Returns whether a surge is active at `now` and seconds until it changes state.
function Economy.surgeState(now: number): (boolean, number)
	local t = now % Economy.SURGE_CYCLE
	local start = Economy.SURGE_CYCLE - Economy.SURGE_DURATION
	if t >= start then
		return true, Economy.SURGE_CYCLE - t
	end
	return false, start - t
end

-- Chests ----------------------------------------------------------------------

Economy.CHEST_RARITIES = { "Common", "Uncommon", "Rare", "Epic", "Legendary" }

Economy.CHEST_INFO = {
	Common = { weight = 82, unlockSeconds = 180, gemPrice = 5, priceMult = 1, offsets = { { -2, 75 }, { -1, 20 }, { 0, 5 } } },
	Uncommon = { weight = 12, unlockSeconds = 480, gemPrice = 12, priceMult = 2.5, offsets = { { -1, 70 }, { 0, 25 }, { 1, 5 } } },
	Rare = { weight = 4.5, unlockSeconds = 1200, gemPrice = 30, priceMult = 6, offsets = { { -1, 40 }, { 0, 45 }, { 1, 15 } } },
	Epic = { weight = 1.2, unlockSeconds = 2700, gemPrice = 60, priceMult = 15, offsets = { { 0, 60 }, { 1, 32 }, { 2, 8 } } },
	Legendary = { weight = 0.3, unlockSeconds = 5400, gemPrice = 120, priceMult = 40, offsets = { { 0, 30 }, { 1, 50 }, { 2, 20 } } },
}

Economy.CHEST_SPAWN_INTERVAL = 40
Economy.CHEST_SPAWN_CHANCE = 0.45
Economy.MAX_FLOOR_CHESTS = 3
Economy.PREMIUM_UNLOCK_SPEED = 3

function Economy.isRarity(rarity: string): boolean
	return Economy.CHEST_INFO[rarity] ~= nil
end

function Economy.rollChestRarity(rng: () -> number): string
	return pickWeighted(Economy.CHEST_RARITIES, function(r)
		return Economy.CHEST_INFO[r].weight
	end, rng())
end

export type Odds = { tier: number, chance: number }

-- Possible tiers and their % chance, relative to the player's highest tier.
-- Offsets that clamp onto the same tier are combined.
function Economy.chestOdds(rarity: string, highestTier: number): { Odds }
	local info = Economy.CHEST_INFO[rarity]
	local byTier: { [number]: number } = {}
	for _, pair in info.offsets do
		local tier = math.clamp(highestTier + pair[1], 1, Economy.MAX_TIER)
		byTier[tier] = (byTier[tier] or 0) + pair[2]
	end
	local list: { Odds } = {}
	for tier, chance in byTier do
		table.insert(list, { tier = tier, chance = chance })
	end
	table.sort(list, function(a, b)
		return a.tier < b.tier
	end)
	return list
end

function Economy.rollChest(rarity: string, highestTier: number, rng: () -> number): number
	local entry = pickWeighted(Economy.chestOdds(rarity, highestTier), function(o)
		return o.chance
	end, rng())
	return entry.tier
end

function Economy.chestMoneyPrice(rarity: string, highestTier: number): number
	local info = Economy.CHEST_INFO[rarity]
	return 40 * Economy.unitRate(math.max(highestTier - 1, 1)) * info.priceMult
end

function Economy.unlockSeconds(rarity: string, premium: boolean): number
	local seconds = Economy.CHEST_INFO[rarity].unlockSeconds
	if premium then
		seconds = math.ceil(seconds / Economy.PREMIUM_UNLOCK_SPEED)
	end
	return seconds
end

-- Gems to finish an unlocker immediately: one per started minute.
function Economy.finishGemCost(secondsLeft: number): number
	return math.max(1, math.ceil(secondsLeft / 60))
end

-- Rewards ---------------------------------------------------------------------

function Economy.discoveryGems(tier: number): number
	return tier
end

Economy.FREE_REWARD_COOLDOWN = 600
Economy.FREE_REWARD_GEMS = 3
Economy.FREE_REWARD_SECONDS = 120
Economy.FREE_REWARD_MIN = 100

Economy.OFFLINE_CAP_SECONDS = 8 * 3600
Economy.OFFLINE_EFFICIENCY = 0.25
Economy.OFFLINE_MIN_SECONDS = 60

Economy.FRIEND_BONUS = 0.1
Economy.MAX_FRIEND_BONUS = 0.5
Economy.PREMIUM_BONUS = 0.1

-- Cash per second the player is currently able to earn (bottlenecked by
-- whichever is slower: production or processing).
function Economy.incomePerSecond(production: number, processRate: number, moneyMult: number): number
	return math.min(production, processRate) * Economy.CASH_PER_POINT * moneyMult
end

-- Money developer products scale with income so they stay useful.
function Economy.moneyPackAmount(income: number, seconds: number, minimum: number): number
	return math.max(minimum, math.floor(income * seconds))
end

-- Tier rarity bands (used for label colours in the Index and on units).
Economy.TIER_BANDS = {
	{ upTo = 5, name = "Common" },
	{ upTo = 10, name = "Uncommon" },
	{ upTo = 15, name = "Rare" },
	{ upTo = 20, name = "Epic" },
	{ upTo = 24, name = "Legendary" },
	{ upTo = 25, name = "Mythic" },
}

function Economy.tierBand(tier: number): string
	for _, band in Economy.TIER_BANDS do
		if tier <= band.upTo then
			return band.name
		end
	end
	return "Mythic"
end

return Economy
