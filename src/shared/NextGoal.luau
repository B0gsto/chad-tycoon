--!strict
--[[
	NextGoal: picks the one concrete target the HUD's "Next:" line names (pure,
	unit-tested with Lune; Client.UI.Hud draws it once the tutorial is done).

	In order:
	  merge    the next undiscovered tier: merge two units of the best tier found
	  index    every tier is discovered: the first Index milestone not claimed yet
	           (Shared.IndexRewards)
	  done     every tier is discovered and every milestone claimed: nothing is left to
	           reach, so the goal only counts the units of the top tier
]]

local Economy = require(script.Parent.Economy)
local IndexRewards = require(script.Parent.IndexRewards)

local NextGoal = {}

export type Goal = {
	kind: "merge" | "index" | "done",
	-- merge: the tier to discover; index, done: the top tier.
	tier: number,
	-- merge: the tier to merge two of; index, done: the top tier.
	from: number,
	-- Counted toward the goal and how much it takes. merge: units of `from`, of the pair;
	-- index: tiers found, of the milestone's; done: units of the top tier, with no target
	-- (`need` is 0).
	have: number,
	need: number,
	-- 0..1 for a progress bar (done: 1, there is nothing to fill). `ready`: the pair of
	-- `from` is on the rack (merge), the milestone waits to be claimed (index).
	progress: number,
	ready: boolean,
	-- One step on the merge pad finishes it: the units owned, merged all the way up, reach
	-- `tier` (the pair of `from` need not be there yet). Only a merge goal.
	mergeReady: boolean,
	-- The progress as a whole percent: 100 only when `mergeReady` (index: `ready`; done:
	-- always), never rounded up to it.
	percent: number,
	-- merge: first-tier units still to buy (0 when `mergeReady`); else 0.
	missing: number,
	-- merge: seconds of income until those units are paid for (0 = affordable now, nil = the
	-- input had no income to go by); else 0.
	seconds: number?,
}

-- The fields of the State snapshot (or a saved profile) the pick reads.
export type Input = {
	discovered: { number },
	units: { number },
	-- `found` of every Index milestone claimed (the profile's `indexClaimed`; none when
	-- missing).
	indexClaimed: { number }?,
	-- For the time estimate (the snapshot's `bought`, `money`, `pending`, `rewardIncome`).
	bought: number?,
	money: number?,
	pending: number?,
	income: number?,
}

local function count(units: { number }, tier: number): number
	local n = units[tier]
	return if type(n) == "number" and n == n and n > 0 then math.floor(n) else 0
end

local function finite(n: number?): number
	return if type(n) == "number" and n == n and n ~= math.huge and n > 0 then n else 0
end

local function mergeGoal(input: Input, best: number): Goal
	-- Everything owned up to `best`, counted in units of `best` (two of a tier make one
	-- of the next), so buying and merging lower tiers moves the bar too.
	local worth = 0
	local clean: { number } = table.create(Economy.MAX_TIER, 0)
	for tier = 1, best do
		clean[tier] = count(input.units, tier)
		worth += clean[tier] / Economy.MERGE_RATIO ^ (best - tier)
	end
	local have = clean[best]
	local progress = math.clamp(worth / Economy.MERGE_RATIO, 0, 1)
	-- A merge carries like a binary sum, so the units reach the next tier exactly when
	-- nothing is missing.
	local missing = math.ceil(Economy.unitsToNextTier(clean, best))
	local mergeReady = missing <= 0
	return {
		kind = "merge",
		tier = best + 1,
		from = best,
		have = math.min(have, Economy.MERGE_RATIO),
		need = Economy.MERGE_RATIO,
		progress = progress,
		ready = have >= Economy.MERGE_RATIO,
		mergeReady = mergeReady,
		percent = if mergeReady then 100 else math.clamp(math.floor(progress * 100), 0, 99),
		missing = missing,
		seconds = Economy.secondsToUnits(
			math.floor(finite(input.bought)),
			missing,
			finite(input.money) + finite(input.pending),
			finite(input.income)
		),
	}
end

-- The first milestone of the Index the save has not claimed (nil = all of them are).
local function indexGoal(input: Input): Goal?
	local claimed = if type(input.indexClaimed) == "table" then input.indexClaimed else {}
	local found = IndexRewards.found(input.discovered)
	for _, milestone in IndexRewards.MILESTONES do
		if not IndexRewards.isClaimed(claimed, milestone.found) then
			local ready = found >= milestone.found
			local progress = math.clamp(found / milestone.found, 0, 1)
			return {
				kind = "index",
				tier = Economy.MAX_TIER,
				from = Economy.MAX_TIER,
				have = math.min(found, milestone.found),
				need = milestone.found,
				progress = progress,
				ready = ready,
				mergeReady = false,
				percent = if ready then 100 else math.clamp(math.floor(progress * 100), 0, 99),
				missing = 0,
				seconds = 0,
			}
		end
	end
	return nil
end

function NextGoal.pick(input: Input): Goal
	local best = Economy.highestTier(input.discovered)
	if best < Economy.MAX_TIER then
		return mergeGoal(input, best)
	end
	return indexGoal(input)
		or {
			kind = "done",
			tier = Economy.MAX_TIER,
			from = Economy.MAX_TIER,
			have = math.min(count(input.units, Economy.MAX_TIER), Economy.UNIT_CAP),
			need = 0,
			progress = 1,
			ready = false,
			mergeReady = false,
			percent = 100,
			missing = 0,
			seconds = 0,
		}
end

--[[
	The goal in words: (title, hint, count, percent), e.g. ("Protein Bro", "merge 2x Gym
	Rookie", "1/2", "50%"). `nameOf(tier)` names a unit tier and `units` is the word for many
	of them ("units" when missing). An Index milestone reads ("Index reward", "claim it in the
	Index", "25/25", "100%"); with nothing left the goal reads ("All 25 units found!", "3x
	Giga Chad", "3", "100%").
	The HUD shows "Next: <title> (<hint>) <percent>" and drops the hint when short of room.
]]
function NextGoal.text(goal: Goal, nameOf: (number) -> string, units: string?): (string, string, string, string)
	local percent = string.format("%d%%", goal.percent)
	local word = units or "units"
	if goal.kind == "merge" then
		local hint = string.format("merge %dx %s", goal.need, nameOf(goal.from))
		return nameOf(goal.tier), hint, string.format("%d/%d", goal.have, goal.need), percent
	elseif goal.kind == "index" then
		local hint = if goal.ready then "claim it in the Index" else string.format("find %d %s", goal.need, word)
		return "Index reward", hint, string.format("%d/%d", goal.have, goal.need), percent
	end
	local title = string.format("All %d %s found!", Economy.MAX_TIER, word)
	return title, string.format("%dx %s", goal.have, nameOf(goal.tier)), tostring(goal.have), percent
end

return NextGoal
