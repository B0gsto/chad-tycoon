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

Economy.VERSION = "1.2.0"

Economy.MAX_TIER = 25
Economy.MAX_BUY_TIER = 15
Economy.MERGE_RATIO = 2
-- A player owns at most UNIT_CAP units, each shown as its own model on the display rack
-- (DISPLAY_ROWS shelves, DISPLAY_COLS units per shelf on average). See addUnitsCapped.
Economy.UNIT_CAP = 100
Economy.DISPLAY_ROWS = 10
Economy.DISPLAY_COLS = 10
Economy.DISPLAY_SLOTS = Economy.DISPLAY_ROWS * Economy.DISPLAY_COLS

-- Production ------------------------------------------------------------------

-- Each tier produces this many times more than the previous one. Must be greater
-- than MERGE_RATIO so merging is always an upgrade.
Economy.TIER_RATE_GROWTH = 2.2

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
-- Returns how many merges happened, the highest tier that received a unit and
-- the merge steps in order (one per tier: `made` units of `tier` + 1 created).
export type MergeStep = { tier: number, made: number }

function Economy.mergeAll(units: { number }): (number, number, { MergeStep })
	local merges = 0
	local topCreated = 0
	local steps: { MergeStep } = {}
	for tier = 1, Economy.MAX_TIER - 1 do
		local count = units[tier] or 0
		local made = math.floor(count / Economy.MERGE_RATIO)
		if made > 0 then
			units[tier] = count - made * Economy.MERGE_RATIO
			units[tier + 1] = (units[tier + 1] or 0) + made
			merges += made
			topCreated = tier + 1
			table.insert(steps, { tier = tier, made = made })
		end
	end
	return merges, topCreated, steps
end

export type CapResult = {
	-- The new per-tier counts (1..MAX_TIER); the input table is left untouched.
	units: { number },
	-- How many of the incoming units were taken (charge only for these).
	accepted: number,
	-- Overflow merges in the order they happened; consecutive merges of the same tier are
	-- combined into one step (`made` units of `tier` + 1 created).
	steps: { MergeStep },
}

-- Lowest tier below MAX_TIER that holds a mergeable pair, or nil.
local function lowestPair(units: { number }): number?
	for tier = 1, Economy.MAX_TIER - 1 do
		if units[tier] >= Economy.MERGE_RATIO then
			return tier
		end
	end
	return nil
end

-- Adds `amount` units of `tier` without letting the total pass `cap` (default UNIT_CAP).
-- Whenever a unit would arrive beyond the cap, the lowest tier holding a pair merges once
-- first (the arriving unit counts, so it can complete that pair); the unit made by a merge
-- may pair up again later. The top tier never merges, so once nothing can merge the rest of
-- the batch is refused. A count already above the cap (an old save; pass amount 0) is merged
-- down first, and while it stays above the cap nothing new is accepted.
-- Every merge conserves unitValue exactly, so the result is worth the old units plus
-- `accepted` units of `tier`.
function Economy.addUnitsCapped(units: { number }, tier: number, amount: number, cap: number?): CapResult
	local limit = cap or Economy.UNIT_CAP
	local out: { number } = table.create(Economy.MAX_TIER, 0)
	local total = 0
	for t = 1, Economy.MAX_TIER do
		out[t] = units[t] or 0
		total += out[t]
	end
	local steps: { MergeStep } = {}
	local function mergeOnce(): boolean
		local t = lowestPair(out)
		if not t then
			return false
		end
		out[t] -= Economy.MERGE_RATIO
		out[t + 1] += 1
		total -= Economy.MERGE_RATIO - 1
		local last = steps[#steps]
		if last and last.tier == t then
			last.made += 1
		else
			table.insert(steps, { tier = t, made = 1 })
		end
		return true
	end

	while total > limit do
		if not mergeOnce() then
			break
		end
	end

	local remaining = math.max(0, math.floor(amount))
	local accepted = 0
	if total <= limit then
		-- Everything that fits without merging.
		local direct = math.min(remaining, limit - total)
		out[tier] += direct
		total += direct
		accepted += direct
		remaining -= direct
		-- The rest one at a time: an arrival past the cap is paid for by one merge (a merge
		-- removes at least one unit).
		while remaining > 0 do
			out[tier] += 1
			total += 1
			if total > limit and not mergeOnce() then
				out[tier] -= 1
				total -= 1
				break
			end
			accepted += 1
			remaining -= 1
		end
	end
	return { units = out, accepted = accepted, steps = steps }
end

-- Buying ----------------------------------------------------------------------

Economy.BUY_BASE_PRICE = 50
Economy.BUY_PRICE_GROWTH = 4
Economy.BUY_AMOUNTS = { 1, 5, 25, 100 }
-- Units to buy at buy tier 1 before upgrading, growing by BUY_REQ_GROWTH per buy tier.
Economy.BUY_REQ_BASE = 1
Economy.BUY_REQ_GROWTH = 1.5
-- A buy tier upgrade costs this share of buying the requirement at the next tier's base price.
Economy.BUY_TIER_UPGRADE_SHARE = 0.5

function Economy.basePrice(buyTier: number): number
	return Economy.BUY_BASE_PRICE * Economy.BUY_PRICE_GROWTH ^ (buyTier - 1)
end

-- Units that must be bought at the current buy tier before it can be upgraded.
function Economy.buyTierRequirement(buyTier: number): number
	return math.floor(Economy.BUY_REQ_BASE * Economy.BUY_REQ_GROWTH ^ (buyTier - 1))
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
	return Economy.basePrice(buyTier + 1) * Economy.buyTierRequirement(buyTier) * Economy.BUY_TIER_UPGRADE_SHARE
end

Economy.AUTO_MERGE_COST = 5000

-- Processing (the converter that turns deposited orbs into cash) ---------------

Economy.PROCESS_BASE = 4
Economy.PROCESS_GROWTH = 1.12
Economy.PROCESS_COST_BASE = 200
Economy.PROCESS_COST_GROWTH = 1.18
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

-- `offsets` = { tier offset from the crate anchor (see chestAnchor), % chance }.
-- `minAnchor` = the lowest tier the offsets are applied to: at very low highest
-- tiers Rare+ crates shift their window up instead of piling the clamped
-- chances onto tier 1, so they still feel better than a Common crate.
export type ChestInfo = {
	weight: number,
	unlockSeconds: number,
	minAnchor: number?,
	offsets: { { number } },
}

Economy.CHEST_INFO = {
	Common = { weight = 82, unlockSeconds = 180, offsets = { { -2, 75 }, { -1, 20 }, { 0, 5 } } },
	Uncommon = { weight = 12, unlockSeconds = 480, offsets = { { -1, 60 }, { 0, 32 }, { 1, 8 } } },
	Rare = { weight = 4.5, unlockSeconds = 1200, minAnchor = 2, offsets = { { -1, 20 }, { 0, 50 }, { 1, 30 } } },
	Epic = { weight = 1.2, unlockSeconds = 2700, minAnchor = 2, offsets = { { 0, 30 }, { 1, 50 }, { 2, 20 } } },
	Legendary = {
		weight = 0.3,
		unlockSeconds = 5400,
		minAnchor = 2,
		offsets = { { 0, 15 }, { 1, 45 }, { 2, 30 }, { 3, 10 } },
	},
} :: { [string]: ChestInfo }

Economy.CHEST_SPAWN_INTERVAL = 40
Economy.CHEST_SPAWN_CHANCE = 0.45
Economy.MAX_FLOOR_CHESTS = 3
Economy.PREMIUM_UNLOCK_SPEED = 3

-- Crates are anchored this share of the way from the player's highest tier down to tier 1
-- (rounded towards the highest tier). Late tiers take hours to reach while crates keep
-- arriving every few minutes, so the gap grows with the tier to keep crates a bonus
-- rather than a shortcut: highest 3 -> anchor 2, 6 -> 4, 10 -> 6, 20 -> 11, 25 -> 13.
Economy.CHEST_TIER_LAG = 0.5

function Economy.chestAnchor(highestTier: number): number
	return highestTier - math.floor((highestTier - 1) * Economy.CHEST_TIER_LAG)
end

function Economy.isRarity(rarity: string): boolean
	return Economy.CHEST_INFO[rarity] ~= nil
end

function Economy.rollChestRarity(rng: () -> number): string
	return pickWeighted(Economy.CHEST_RARITIES, function(r)
		return Economy.CHEST_INFO[r].weight
	end, rng())
end

export type Odds = { tier: number, chance: number }

-- Possible tiers and their % chance, relative to the crate anchor of the player's highest tier.
-- Offsets that clamp onto the same tier are combined (see `minAnchor`).
function Economy.chestOdds(rarity: string, highestTier: number): { Odds }
	local info = Economy.CHEST_INFO[rarity]
	local anchor = math.max(Economy.chestAnchor(highestTier), info.minAnchor or 1)
	local byTier: { [number]: number } = {}
	for _, pair in info.offsets do
		local tier = math.clamp(anchor + pair[1], 1, Economy.MAX_TIER)
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

-- What a unit of `tier` costs to make by buying tier-1 units and merging them up
-- (the cheapest way to get one, since higher buy tiers cost more per tier-1 unit).
function Economy.unitValue(tier: number): number
	return Economy.BUY_BASE_PRICE * Economy.MERGE_RATIO ^ (math.max(tier, 1) - 1)
end

-- Expected unit value of what a crate of this rarity contains.
function Economy.chestExpectedValue(rarity: string, highestTier: number): number
	local total = 0
	for _, entry in Economy.chestOdds(rarity, highestTier) do
		total += Economy.unitValue(entry.tier) * entry.chance / 100
	end
	return total
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

-- One-time reward for finishing the onboarding tutorial.
Economy.TUTORIAL_REWARD_GEMS = 25
Economy.TUTORIAL_REWARD_CASH = 25

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

-- Progression (what Robux packs scale with) ---------------------------------------

-- Durable progress only: the highest tier ever discovered and the converter level. Neither
-- can go down, so selling, merging or a bad multiplier moment never makes a pack worse.
-- Buy tier is left out: a player can only buy tiers they have already discovered, so it
-- never says more than `tier` does.
export type Progression = { tier: number, processLevel: number }

function Economy.progression(highestTier: number, processLevel: number): Progression
	return {
		tier = math.clamp(math.floor(highestTier), 1, Economy.MAX_TIER),
		processLevel = math.max(0, math.floor(processLevel)),
	}
end

-- Cash per second a player at this progression earns at the very least: the output of ONE
-- unit of their highest tier, run through their own converter, with no boosts. Anyone who
-- discovered that tier made such a unit (and a real rack holds many more units below it),
-- and the converter cap is the same one Tycoon.income applies, so the floor stays at or
-- below what a real player at that stage earns.
function Economy.progressionIncome(progression: Progression): number
	return Economy.incomePerSecond(Economy.unitRate(progression.tier), Economy.processRate(progression.processLevel), 1)
end

-- Cash packs: `seconds` of income at the better of the live income and the progression
-- floor, never below the pack's fixed `minimum` (which only matters for brand-new players).
function Economy.moneyPackAmount(income: number, seconds: number, minimum: number, progression: Progression): number
	local perSecond = math.max(income, Economy.progressionIncome(progression))
	return math.max(minimum, math.floor(perSecond * seconds))
end

-- Rizz packs multiply their base amount by this: x1 at tier 1 rising smoothly to x4 at
-- the top tier. Crate timers (and so finishGemCost) do not grow with tier, so a
-- late-game Rizz buys the same skips as an early one; x4 keeps the biggest pack at about
-- 15 hours of skipping every crate that spawns instead of days.
Economy.GEM_PACK_MAX_FACTOR = 4
Economy.GEM_PACK_CURVE = 1.25

function Economy.gemPackFactor(progression: Progression): number
	local t = (progression.tier - 1) / (Economy.MAX_TIER - 1)
	return 1 + (Economy.GEM_PACK_MAX_FACTOR - 1) * t ^ Economy.GEM_PACK_CURVE
end

-- Rounds to friendly shop numbers: nearest 5 below 500, nearest 50 from there.
local function friendly(amount: number): number
	local step = if amount < 500 then 5 else 50
	return math.max(step, math.floor(amount / step + 0.5) * step)
end

function Economy.gemPackAmount(base: number, progression: Progression): number
	return math.max(base, friendly(base * Economy.gemPackFactor(progression)))
end

-- Game modes (Parkour) ------------------------------------------------------------

-- Finishing a mode pays exactly what the smallest cash pack would give the player right now
-- (moneyPackAmount with that pack's seconds and minimum): on the first finish ever and then
-- at most once per MODE_REWARD_COOLDOWN. Players may run again straight away, but finishes
-- inside the cooldown pay no cash. The first finish ever also pays Rizz.
Economy.MODE_REWARD_COOLDOWN = 1800
Economy.MODE_FIRST_CLEAR_GEMS = 25

export type ModeReward = {
	-- Cash this finish pays (packCash when `full`, else 0).
	cash: number,
	gems: number,
	full: boolean,
	packCash: number,
}

function Economy.modeReward(
	income: number,
	progression: Progression,
	packSeconds: number,
	packMinimum: number,
	firstClear: boolean,
	lastFullAt: number,
	now: number
): ModeReward
	local packCash = Economy.moneyPackAmount(income, packSeconds, packMinimum, progression)
	local full = firstClear or now >= lastFullAt + Economy.MODE_REWARD_COOLDOWN
	return {
		cash = if full then packCash else 0,
		gems = if firstClear then Economy.MODE_FIRST_CLEAR_GEMS else 0,
		full = full,
		packCash = packCash,
	}
end

-- Parkour level multiplier on the finish cash: +20% per level above the first (level 10
-- pays 2.8x the pack).
function Economy.parkourLevelBonus(level: number): number
	return 1 + 0.2 * (math.max(1, math.floor(level)) - 1)
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
