--!strict
--[[
	NextGoal: picks the one concrete target the HUD's "Next:" line names (pure,
	unit-tested with Lune; Client.UI.Hud draws it once the tutorial is done).

	In order:
	  rebirth  the run has every tier, or a rebirth is on offer and the next tier is further
	           off than Economy.REBIRTH_GOAL_SECONDS of income: start the run again for stars
	  merge    the next tier the run has not reached: merge two units of its best tier
	  rack     every tier is discovered: stack units of the top tier (only for a caller that
	           does not send the run's tiers; with them that goal is the rebirth)

	The other option rides along as `second`: the rebirth under a merge goal from
	Economy.REBIRTH_MIN_TIER up, and the next tier under a rebirth goal.
]]

local Economy = require(script.Parent.Economy)

local NextGoal = {}

export type Goal = {
	kind: "merge" | "rack" | "rebirth",
	-- merge: the tier to reach; rack: the top tier; rebirth: the run's best tier.
	tier: number,
	-- merge: the tier to merge two of; rack: the top tier; rebirth: the run's best tier.
	from: number,
	-- Units counted toward the goal and how many it takes (rebirth: 1 of 1).
	have: number,
	need: number,
	-- 0..1 for a progress bar; `ready` = the pair of `from` is on the rack (rebirth: always).
	progress: number,
	ready: boolean,
	-- One step on the merge pad finishes it: the units owned, merged all the way up, reach
	-- `tier` (the pair of `from` need not be there yet). Rebirth: always; rack: never.
	mergeReady: boolean,
	-- The progress as a whole percent: 100 only when `mergeReady` (or the rack is full),
	-- never rounded up to it.
	percent: number,
	-- merge: first-tier units still to buy (0 when `mergeReady`); else 0.
	missing: number,
	-- merge: seconds of income until those units are paid for (0 = affordable now, nil = the
	-- input had no income to go by); else 0.
	seconds: number?,
	-- Stars a rebirth pays right now (0 = not on offer, or the input has no run tiers).
	stars: number,
	-- The other thing worth doing, when there is one (it has no `second` of its own).
	second: Goal?,
}

-- The fields of the State snapshot (or a saved profile) the pick reads.
export type Input = {
	discovered: { number },
	units: { number },
	-- The tiers of the current run (the snapshot's `runDiscovered`). Without it the pick
	-- goes by `discovered` and never names a rebirth.
	runDiscovered: { number }?,
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
		stars = 0,
	}
end

local function rebirthGoal(best: number, stars: number): Goal
	return {
		kind = "rebirth",
		tier = best,
		from = best,
		have = 1,
		need = 1,
		progress = 1,
		ready = true,
		mergeReady = true,
		percent = 100,
		missing = 0,
		seconds = 0,
		stars = stars,
	}
end

function NextGoal.pick(input: Input): Goal
	local run = input.runDiscovered
	local best = Economy.highestTier(if type(run) == "table" then run else input.discovered)
	local stars = if type(run) == "table" then Economy.rebirthStars(best) else 0
	if best < Economy.MAX_TIER then
		local merge = mergeGoal(input, best)
		merge.stars = stars
		if stars <= 0 then
			return merge
		end
		local rebirth = rebirthGoal(best, stars)
		-- A tier one merge away always comes first.
		if not merge.mergeReady and Economy.rebirthIsGoal(best, merge.seconds) then
			rebirth.second = merge
			return rebirth
		end
		merge.second = rebirth
		return merge
	end
	if stars > 0 then
		return rebirthGoal(best, stars)
	end
	local top = count(input.units, Economy.MAX_TIER)
	local progress = math.clamp(top / Economy.UNIT_CAP, 0, 1)
	return {
		kind = "rack",
		tier = Economy.MAX_TIER,
		from = Economy.MAX_TIER,
		have = math.min(top, Economy.UNIT_CAP),
		need = Economy.UNIT_CAP,
		progress = progress,
		ready = false,
		mergeReady = false,
		percent = if top >= Economy.UNIT_CAP then 100 else math.clamp(math.floor(progress * 100), 0, 99),
		missing = 0,
		seconds = 0,
		stars = 0,
	}
end

--[[
	The goal in words: (title, hint, count, percent), e.g. ("Protein Bro", "merge 2x Gym
	Rookie", "1/2", "50%"). `nameOf(tier)` names a unit tier. A rebirth reads ("Rebirth",
	"+3 stars", "+3", "100%").
	The HUD shows "Next: <title> (<hint>) <percent>" and drops the hint when short of room.
]]
function NextGoal.text(goal: Goal, nameOf: (number) -> string): (string, string, string, string)
	local percent = string.format("%d%%", goal.percent)
	if goal.kind == "merge" then
		local hint = string.format("merge %dx %s", goal.need, nameOf(goal.from))
		return nameOf(goal.tier), hint, string.format("%d/%d", goal.have, goal.need), percent
	elseif goal.kind == "rebirth" then
		local stars = string.format("+%d", goal.stars)
		return "Rebirth", stars .. (if goal.stars == 1 then " star" else " stars"), stars, percent
	end
	return nameOf(goal.tier), "fill your rack", string.format("%d/%d", goal.have, goal.need), percent
end

return NextGoal
