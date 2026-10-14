--!strict
--[[
	Economy: every balance number and pure formula in the game.

	This module has no Roblox dependencies so it can be unit-tested with Lune
	(see tests/). Both variants share it; only names, colours and looks differ
	per theme.

	Core loop:
	  buy units -> units drop orbs -> walk over orbs to carry them
	  -> deposit at the converter: the aura carried is queued and processed into cash,
	     and the random deposit multiplier's bonus part is paid as cash at once
	  -> collect cash -> buy more / upgrade.
	Two units of the same tier merge into one unit of the next tier. The converter never
	falls behind a new tier: discovering one lifts its level for free (minProcessLevel),
	and paid levels only add speed on top.
]]

local Economy = {}

Economy.VERSION = "2.0.0"

Economy.MAX_TIER = 25
Economy.MERGE_RATIO = 2
-- A player owns at most UNIT_CAP units, each shown as its own model on the display rack
-- (DISPLAY_ROWS shelves, DISPLAY_COLS units per shelf on average). See addUnitsCapped.
Economy.UNIT_CAP = 100
Economy.DISPLAY_ROWS = 10
Economy.DISPLAY_COLS = 10
Economy.DISPLAY_SLOTS = Economy.DISPLAY_ROWS * Economy.DISPLAY_COLS

-- Production ------------------------------------------------------------------

-- Each tier up to FAST_TIERS produces TIER_RATE_GROWTH times more than the previous one,
-- each tier up to MID_TIERS MID_TIER_RATE_GROWTH times more and every tier after that
-- LATE_TIER_RATE_GROWTH times more: the first minutes stay quick and the late tiers take
-- days. All must be greater than MERGE_RATIO so merging is always an upgrade.
Economy.TIER_RATE_GROWTH = 3.0
Economy.MID_TIER_RATE_GROWTH = 2.7
Economy.LATE_TIER_RATE_GROWTH = 2.4
Economy.FAST_TIERS = 8
Economy.MID_TIERS = 16

function Economy.unitRate(tier: number): number
	local fast = math.min(tier, Economy.FAST_TIERS) - 1
	local mid = math.clamp(tier, Economy.FAST_TIERS, Economy.MID_TIERS) - Economy.FAST_TIERS
	local late = math.max(tier - Economy.MID_TIERS, 0)
	return Economy.TIER_RATE_GROWTH ^ fast * Economy.MID_TIER_RATE_GROWTH ^ mid * Economy.LATE_TIER_RATE_GROWTH ^ late
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
Economy.BUY_AMOUNTS = { 1, 5, 25, 100 }
-- Purchases that raise the price by one base price.
Economy.BUY_RAMP_UNITS = 1
-- A new player's first units are cheap: the first BUY_EASY_UNITS bought raise the price by
-- only 1 / BUY_EASY_REQ of the base each (the normal rate comes back after them). Together
-- with the starter unit they are worth one tier-6 unit and most of a tier-7 one: a fixed
-- head start, after which every price is what it always was.
Economy.BUY_EASY_UNITS = 60
Economy.BUY_EASY_REQ = 10

-- Sum of `n` consecutive purchase counts starting at `from`.
local function span(from: number, n: number): number
	return n * from + n * (n - 1) / 2
end

-- Exact price of `amount` consecutive purchases, the first made with `bought` units already
-- bought. Each purchase costs the base price times 1 + its growth: every earlier purchase
-- adds 1 / BUY_RAMP_UNITS, or 1 / BUY_EASY_REQ while it is an easy one.
local function price(bought: number, amount: number): number
	-- Purchases of this batch whose price still counts only easy units, then the rest.
	local easy = math.clamp(Economy.BUY_EASY_UNITS - bought, 0, amount)
	local rest = amount - easy
	local growth = span(bought, easy) / Economy.BUY_EASY_REQ
	if rest > 0 then
		local start = bought + easy
		local easyBefore = math.min(start, Economy.BUY_EASY_UNITS)
		growth += rest * easyBefore / Economy.BUY_EASY_REQ + span(start - easyBefore, rest) / Economy.BUY_RAMP_UNITS
	end
	return Economy.BUY_BASE_PRICE * (amount + growth)
end

-- Price of the next single unit (always the first tier). Grows linearly with the units
-- bought so far: 2x after BUY_RAMP_UNITS of them, the easy ones aside.
function Economy.unitPrice(bought: number): number
	return price(bought, 1)
end

-- Exact sum of unitPrice for `amount` consecutive purchases.
function Economy.bulkPrice(bought: number, amount: number): number
	return price(bought, amount)
end

-- Buy Max: once a profile has bought BUY_MAX_FROM units, the Buy 100 pad buys everything the
-- cash allows (at least BUY_MAX_MIN units, else it stays a plain Buy 100) and merges the whole
-- rack. Late tiers need millions of first-tier units, which no pad could sell 100 at a time.
Economy.BUY_MAX_FROM = 500
Economy.BUY_MAX_MIN = 200
-- The most units one purchase can be: a full rack of the top tier.
Economy.BUY_MAX_UNITS = Economy.UNIT_CAP * Economy.MERGE_RATIO ^ (Economy.MAX_TIER - 1)

-- The largest amount with bulkPrice(bought, amount) <= money (0 when not even one unit).
function Economy.maxAffordable(bought: number, money: number): number
	if money ~= money or price(bought, 1) > money then
		return 0
	end
	local low, high = 1, 2
	while high < Economy.BUY_MAX_UNITS and price(bought, high) <= money do
		low, high = high, high * 2
	end
	if high >= Economy.BUY_MAX_UNITS then
		high = Economy.BUY_MAX_UNITS
		if price(bought, high) <= money then
			return high
		end
	end
	-- price(low) <= money < price(high)
	while high - low > 1 do
		local mid = math.floor((low + high) / 2)
		if price(bought, mid) <= money then
			low = mid
		else
			high = mid
		end
	end
	return low
end

export type MaxPlan = {
	-- Units bought (all of the first tier) and their exact price.
	amount: number,
	cost: number,
	-- The rack after the purchase with every pair merged (1..MAX_TIER); the input is untouched.
	units: { number },
	merges: number,
	steps: { MergeStep },
}

-- What a Buy Max step does for a profile with `units`, `bought` units bought so far and
-- `money` cash, or nil when it is not a Buy Max (the pad then sells 100 as before). The
-- merge conserves unitValue exactly: the result is worth the old units plus `amount` of the
-- first tier. The top tier cannot merge, so when the merged rack would pass the cap the
-- purchase is cut down to whole top-tier units.
function Economy.planBuyMax(units: { number }, bought: number, money: number, cap: number?): MaxPlan?
	if bought < Economy.BUY_MAX_FROM then
		return nil
	end
	local amount = Economy.maxAffordable(bought, money)
	local limit = cap or Economy.UNIT_CAP
	for _ = 1, 2 do
		if amount < Economy.BUY_MAX_MIN then
			return nil
		end
		local out: { number } = table.create(Economy.MAX_TIER, 0)
		for tier = 1, Economy.MAX_TIER do
			out[tier] = units[tier] or 0
		end
		out[1] += amount
		local merges, _, steps = Economy.mergeAll(out)
		if Economy.totalUnits(out) <= limit then
			return { amount = amount, cost = price(bought, amount), units = out, merges = merges, steps = steps }
		end
		-- Over the cap: buy just enough to turn everything below the top tier into whole
		-- top-tier units, as many as the rack still has room for.
		local top = Economy.MERGE_RATIO ^ (Economy.MAX_TIER - 1)
		local below = 0
		for tier = 1, Economy.MAX_TIER - 1 do
			below += (units[tier] or 0) * Economy.MERGE_RATIO ^ (tier - 1)
		end
		local room = limit - (units[Economy.MAX_TIER] or 0)
		local made = math.min(math.floor((below + amount) / top), room)
		amount = made * top - below
	end
	return nil
end

-- First-tier units still missing before the rack, with every pair merged, holds a unit of
-- the tier after `highestTier` (0 at the top tier, or when the rack already holds enough).
function Economy.unitsToNextTier(units: { number }, highestTier: number): number
	if highestTier >= Economy.MAX_TIER then
		return 0
	end
	local owned = 0
	for tier = 1, Economy.MAX_TIER do
		owned += (units[tier] or 0) * Economy.MERGE_RATIO ^ (tier - 1)
	end
	return math.max(0, Economy.MERGE_RATIO ^ math.max(highestTier, 1) - owned)
end

-- Aura per second of one unit of each tier, 1..`upTo` (a dense list: it crosses a remote as is).
function Economy.unitRates(upTo: number): { number }
	local rates: { number } = {}
	for tier = 1, math.clamp(math.floor(upTo), 1, Economy.MAX_TIER) do
		rates[tier] = Economy.unitRate(tier)
	end
	return rates
end

-- Processing (the converter that turns deposited orbs into cash) ---------------

-- Each level is 25% faster and costs 25% more than the one before, so a level always costs
-- the same 50 seconds of the converter's own output.
Economy.PROCESS_BASE = 4
Economy.PROCESS_GROWTH = 1.25
Economy.PROCESS_COST_BASE = 200
Economy.PROCESS_COST_GROWTH = 1.25
Economy.PROCESS_BULK = 10
-- An upgrade is refused (no charge) once the converter is this many times faster than the
-- units produce: more speed would buy nothing.
Economy.CONVERTER_HEADROOM = 4

function Economy.processRate(level: number): number
	return Economy.PROCESS_BASE * Economy.PROCESS_GROWTH ^ level
end

function Economy.processUpgradeCost(level: number): number
	return Economy.PROCESS_COST_BASE * Economy.PROCESS_COST_GROWTH ^ level
end

-- The free converter floor: the lowest level whose rate covers one unit of `tier`. A profile's
-- level is never below the floor of its best tier (about 5 free levels per new tier). A rack
-- with every pair merged produces 1x to 2x unitRate(best), so a converter nobody upgraded is
-- never short by more than 2x.
function Economy.minProcessLevel(tier: number): number
	local needed = Economy.unitRate(math.clamp(tier, 1, Economy.MAX_TIER)) / Economy.PROCESS_BASE
	return math.max(0, math.ceil(math.log(needed) / math.log(Economy.PROCESS_GROWTH)))
end

-- Cost of buying `amount` levels starting from `level` (geometric series).
function Economy.processBulkCost(level: number, amount: number): number
	local g = Economy.PROCESS_COST_GROWTH
	return Economy.processUpgradeCost(level) * (g ^ amount - 1) / (g - 1)
end

-- Cash value of one orb point before multipliers.
Economy.CASH_PER_POINT = 1

-- Deposit multiplier (global, rerolled on a timer) ------------------------------

-- Never below x1 (a deposit is never a loss); the mean is about x1.15.
Economy.DEPOSIT_REROLL_SECONDS = 20
Economy.DEPOSIT_MULTIPLIERS = {
	{ value = 1.0, weight = 50 },
	{ value = 1.1, weight = 18 },
	{ value = 1.2, weight = 12 },
	{ value = 1.3, weight = 8 },
	{ value = 1.5, weight = 6 },
	{ value = 1.8, weight = 3.5 },
	{ value = 2.0, weight = 2 },
	{ value = 3.0, weight = 0.5 },
}
Economy.DEPOSIT_MIN = 1.0
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

-- What a deposit of `carried` aura at multiplier `mult` gives: the aura queued in the
-- converter (always all of it) and the bonus aura, which is paid as cash at once.
function Economy.depositSplit(carried: number, mult: number): (number, number)
	return carried, carried * (math.max(mult, 1) - 1)
end

-- Whether a converter pad's title shows cash per second (else its speed step). `gain` is the
-- cash per second `amount` levels would add now, `singleGain` the same for one level. The
-- cash gain stops at what the units produce, so once one level catches up the bulk pad would
-- read the same as the single pad at many times the price: it shows its own speed instead.
function Economy.upgradeShowsCash(amount: number, gain: number, singleGain: number): boolean
	if gain <= 0 then
		return false
	end
	return amount == 1 or gain > singleGain * 1.005
end

-- Global "surge" event: double orbs for the last part of every cycle. ----------
-- The converter runs at double speed too, so the cash earned really doubles. Rewards are
-- sized with the income outside the surge.

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

-- The surge as one player lives it: none until the tutorial is done or skipped (no doubled
-- aura or cash on the server, no strip, chip, screen grade or music on the client). Inactive
-- with the clock's own seconds until then.
function Economy.surgeFor(now: number, tutorialDone: boolean?): (boolean, number)
	local active, left = Economy.surgeState(now)
	return active and tutorialDone == true, left
end

-- Players are told this many seconds before a surge starts.
Economy.SURGE_WARN_SECONDS = 30

-- The surge cycle as the server announces it: "idle", "soon" (the last SURGE_WARN_SECONDS
-- before a surge) or "active", and the seconds until that phase ends.
function Economy.surgePhase(now: number): (string, number)
	local active, left = Economy.surgeState(now)
	if active then
		return "active", left
	elseif left <= Economy.SURGE_WARN_SECONDS then
		return "soon", left
	end
	return "idle", left - Economy.SURGE_WARN_SECONDS
end

-- What to announce when the phase goes from `previous` to `phase`: "soon", "start", "end" or
-- nil (no change, or a surge that was never running ends).
function Economy.surgeNotice(previous: string, phase: string): string?
	if phase == previous then
		return nil
	elseif phase == "soon" then
		return "soon"
	elseif phase == "active" then
		return "start"
	end
	return if previous == "active" then "end" else nil
end

-- Chests ----------------------------------------------------------------------

Economy.CHEST_RARITIES = { "Common", "Uncommon", "Rare", "Epic", "Legendary" }

-- Each rarity rolls `offsets` = { tier offset, % chance } around a base tier:
--   base = max(crate anchor (see chestAnchor, at least `minAnchor`) + `lift`,
--              highest tier - `belowBest`)
-- so Common and Uncommon stay anchored below the highest tier, Rare sits one tier above
-- the anchor, and Epic and Legendary follow the highest tier itself (Epic highest-2 ..
-- highest-1, Legendary highest-1 .. highest). The `lift` keeps every rarity clear of the
-- one below while the anchor is still close to the highest tier: a Legendary's lowest tier
-- is at least 3 above a Common crate's main tier (4 once the cap no longer binds). No crate gives more
-- than one tier past the highest one (chestCap): that tier is a merge of two of the
-- player's best, so a crate can bring the next tier but never skip past it.
-- `minAnchor` = the lowest anchor Rare+ crates use: at very low highest tiers their window
-- shifts up instead of piling the clamped chances onto tier 1.
export type ChestInfo = {
	weight: number,
	unlockSeconds: number,
	minAnchor: number?,
	lift: number?,
	belowBest: number?,
	offsets: { { number } },
}

Economy.CHEST_INFO = {
	Common = { weight = 82, unlockSeconds = 60, offsets = { { -2, 75 }, { -1, 20 }, { 0, 5 } } },
	Uncommon = { weight = 12, unlockSeconds = 120, offsets = { { -1, 60 }, { 0, 32 }, { 1, 8 } } },
	Rare = {
		weight = 4.5,
		unlockSeconds = 180,
		minAnchor = 2,
		lift = 1,
		offsets = { { -1, 30 }, { 0, 50 }, { 1, 20 } },
	},
	Epic = {
		weight = 1.2,
		unlockSeconds = 240,
		minAnchor = 2,
		lift = 2,
		belowBest = 1,
		offsets = { { -1, 50 }, { 0, 50 } },
	},
	Legendary = {
		weight = 0.3,
		unlockSeconds = 300,
		minAnchor = 2,
		lift = 3,
		belowBest = 0,
		offsets = { { -1, 40 }, { 0, 60 } },
	},
} :: { [string]: ChestInfo }

Economy.CHEST_SPAWN_INTERVAL = 40
Economy.CHEST_SPAWN_CHANCE = 0.45
Economy.MAX_FLOOR_CHESTS = 3
Economy.PREMIUM_UNLOCK_SPEED = 3
-- The very first crate of a profile opens this fast, whatever its rarity.
Economy.FIRST_CRATE_SECONDS = 10
-- The guide shows the path to the Crate Smasher by itself for a profile's first crates.
Economy.CRATE_GUIDE_HOLDS = 3

-- Common and Uncommon crates (and the Rare window, one tier up) are anchored this share
-- of the way from the player's highest tier down to tier 1
-- (rounded towards the highest tier). Late tiers take hours to reach while crates keep
-- arriving every few minutes, so the gap grows with the tier to keep crates a bonus
-- rather than a shortcut: highest 3 -> anchor 3, 5 -> 4, 10 -> 7, 17 -> 12, 25 -> 17.
Economy.CHEST_TIER_LAG = 0.35

-- Epic and Legendary crates drop this share of a tier further below the highest tier for
-- every tier climbed, so the last tiers (days apart at half an hour a day) are still
-- earned by merging: highest 10 -> Legendary 9..10, 15 -> 13..14, 25 -> 22..23.
Economy.CHEST_BEST_LAG = 0.1

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

-- The highest tier a crate can give: one past the player's highest (two of their best
-- merged), never past MAX_TIER.
function Economy.chestCap(highestTier: number): number
	return math.min(math.max(highestTier, 1) + 1, Economy.MAX_TIER)
end

-- The tier a rarity's offsets are applied to (see CHEST_INFO).
function Economy.chestBase(rarity: string, highestTier: number): number
	local info = Economy.CHEST_INFO[rarity]
	local base = math.max(Economy.chestAnchor(highestTier), info.minAnchor or 1) + (info.lift or 0)
	if info.belowBest then
		local gap = info.belowBest + math.floor((highestTier - 1) * Economy.CHEST_BEST_LAG)
		base = math.max(base, highestTier - gap)
	end
	return base
end

-- Possible tiers and their % chance for the player's highest tier, lowest tier first.
-- Offsets that clamp onto the same tier (at tier 1 or chestCap) are combined.
function Economy.chestOdds(rarity: string, highestTier: number): { Odds }
	local info = Economy.CHEST_INFO[rarity]
	local base = Economy.chestBase(rarity, highestTier)
	local cap = Economy.chestCap(highestTier)
	local byTier: { [number]: number } = {}
	for _, pair in info.offsets do
		local tier = math.clamp(base + pair[1], 1, cap)
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

-- What a unit of `tier` costs to make by buying tier-1 units and merging them up.
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

-- Rewards ---------------------------------------------------------------------

Economy.FREE_REWARD_COOLDOWN = 600
Economy.FREE_REWARD_SECONDS = 120
Economy.FREE_REWARD_MIN = 100

-- A new profile's cash and converter level (DataService.defaultProfile). The converter
-- starts a few levels up so it keeps pace with the first three tiers; from there the free
-- floor (minProcessLevel) lifts it with every new tier.
Economy.START_CASH = 100
Economy.START_PROCESS_LEVEL = 8

-- One-time reward for finishing the onboarding tutorial: enough for the next few units,
-- so the first merge is followed by a second one straight away.
Economy.TUTORIAL_REWARD_CASH = 200

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

-- Aura packs (the aura a pack is worth; the buyer is paid its cash at once,
-- ShopMath.auraPackCash): `seconds` of aura at the better of the live
-- production (orbs per second, Tycoon.production) and the progression floor (one unit of the
-- highest tier, the same floor progressionIncome uses), never below the pack's fixed
-- `minimum` (which only matters for brand-new players).
function Economy.auraPackAmount(production: number, seconds: number, minimum: number, progression: Progression): number
	local perSecond = math.max(production, Economy.unitRate(progression.tier))
	return math.max(minimum, math.floor(perSecond * seconds))
end

-- Seconds of income until `missing` more first-tier units are paid for by a player who has
-- bought `bought` units and holds `cash` (wallet plus vault): 0 = affordable now, nil = no
-- income to go by.
function Economy.secondsToUnits(bought: number, missing: number, cash: number, income: number): number?
	if missing <= 0 then
		return 0
	end
	local short = price(bought, missing) - cash
	if short <= 0 then
		return 0
	end
	return if income > 0 and short == short then short / income else nil
end

-- Game modes (Parkour) ------------------------------------------------------------

-- Finishing a mode pays a cash pack's worth sized like the shop's (moneyPackAmount with the
-- mode's own seconds and minimum, Theme.Modes): on the first finish ever and then
-- at most once per MODE_REWARD_COOLDOWN. Players may run again straight away; a finish
-- inside the cooldown is worth MODE_REPEAT_SHARE of the pack (`repeatCash`), which the mode
-- pays only for a clean, unassisted run.
Economy.MODE_REWARD_COOLDOWN = 1800
Economy.MODE_REPEAT_SHARE = 0.2
-- Cash price of a Parkour "Skip Stage" (teleport to the next checkpoint; the run becomes
-- assisted: it pays and unlocks but sets no best time): two minutes of income, at least $250.
Economy.PARKOUR_SKIP_MIN = 250
Economy.PARKOUR_SKIP_SECONDS = 120
function Economy.parkourSkipCost(income: number): number
	return math.max(Economy.PARKOUR_SKIP_MIN, math.floor(income * Economy.PARKOUR_SKIP_SECONDS + 0.5))
end

export type ModeReward = {
	-- Cash this finish pays (packCash when `full`, else 0).
	cash: number,
	full: boolean,
	packCash: number,
	-- What a clean finish inside the cooldown is worth (MODE_REPEAT_SHARE of the pack).
	repeatCash: number,
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
		full = full,
		packCash = packCash,
		repeatCash = math.floor(packCash * Economy.MODE_REPEAT_SHARE),
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
