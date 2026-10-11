--!strict
--[[
	NextGoal: picks the one concrete target the HUD's "Next:" line names (pure,
	unit-tested with Lune; Client.UI.Hud draws it once the tutorial is done).

	In order:
	  merge    the next undiscovered tier: merge two units of the best tier found
	  buyTier  every tier is discovered: unlock the next buy tier (buy the
	           required units, then save up for the upgrade)
	  rack     nothing is left to unlock: stack units of the top tier
]]

local Economy = require(script.Parent.Economy)

local NextGoal = {}

export type Goal = {
	kind: "merge" | "buyTier" | "rack",
	-- merge: the tier to discover; buyTier: the buy tier to unlock; rack: the top tier.
	tier: number,
	-- merge: the tier to merge two of; buyTier: the tier bought right now; rack: the top tier.
	from: number,
	-- Units counted toward the goal and how many it takes.
	have: number,
	need: number,
	-- buyTier: cash the upgrade costs once the units are bought (0 for the other kinds).
	cost: number,
	-- 0..1 for a progress bar; `ready` = one step on a pad finishes it.
	progress: number,
	ready: boolean,
}

-- The fields of the State snapshot (or a saved profile) the pick reads.
export type Input = {
	discovered: { number },
	units: { number },
	buyTier: number,
	boughtAtTier: number,
	money: number,
}

local function count(units: { number }, tier: number): number
	local n = units[tier]
	return if type(n) == "number" and n == n and n > 0 then math.floor(n) else 0
end

function NextGoal.pick(input: Input): Goal
	local best = Economy.highestTier(input.discovered)
	if best < Economy.MAX_TIER then
		-- Everything owned up to `best`, counted in units of `best` (two of a tier make one
		-- of the next), so buying and merging lower tiers moves the bar too.
		local worth = 0
		for tier = 1, best do
			worth += count(input.units, tier) / Economy.MERGE_RATIO ^ (best - tier)
		end
		local have = count(input.units, best)
		return {
			kind = "merge",
			tier = best + 1,
			from = best,
			have = math.min(have, Economy.MERGE_RATIO),
			need = Economy.MERGE_RATIO,
			cost = 0,
			progress = math.clamp(worth / Economy.MERGE_RATIO, 0, 1),
			ready = have >= Economy.MERGE_RATIO,
		}
	end
	local buyTier = math.clamp(math.floor(input.buyTier), 1, Economy.MAX_BUY_TIER)
	if buyTier < Economy.MAX_BUY_TIER then
		local need = Economy.buyTierRequirement(buyTier)
		local have = math.clamp(math.floor(input.boughtAtTier), 0, need)
		local cost = Economy.buyTierUpgradeCost(buyTier)
		local bought = have >= need
		-- Half the bar for the units, half for the cash.
		local progress = if bought then 0.5 + 0.5 * math.clamp(input.money / cost, 0, 1) else 0.5 * have / need
		return {
			kind = "buyTier",
			tier = buyTier + 1,
			from = buyTier,
			have = have,
			need = need,
			cost = cost,
			progress = progress,
			ready = bought and input.money >= cost,
		}
	end
	local top = count(input.units, Economy.MAX_TIER)
	return {
		kind = "rack",
		tier = Economy.MAX_TIER,
		from = Economy.MAX_TIER,
		have = math.min(top, Economy.UNIT_CAP),
		need = Economy.UNIT_CAP,
		cost = 0,
		progress = math.clamp(top / Economy.UNIT_CAP, 0, 1),
		ready = false,
	}
end

--[[
	The goal in words: (title, hint, count), e.g. ("Protein Bro", "merge 2x Gym
	Rookie", "1/2"). `nameOf(tier)` names a unit tier, `money(n)` formats cash.
	The HUD shows "Next: <title> (<hint>) <count>" and drops the hint when short of room.
]]
function NextGoal.text(goal: Goal, nameOf: (number) -> string, money: (number) -> string): (string, string, string)
	if goal.kind == "merge" then
		local hint = string.format("merge %dx %s", goal.need, nameOf(goal.from))
		return nameOf(goal.tier), hint, string.format("%d/%d", goal.have, goal.need)
	elseif goal.kind == "buyTier" then
		local title = "Buy Tier " .. goal.tier
		if goal.have < goal.need then
			local hint = string.format("buy %d more %s", goal.need - goal.have, nameOf(goal.from))
			return title, hint, string.format("%d/%d", goal.have, goal.need)
		elseif goal.ready then
			return title, "step on the BUY TIER pad", "READY"
		end
		return title, "save " .. money(goal.cost), string.format("%d%%", math.floor((goal.progress - 0.5) * 200))
	end
	return nameOf(goal.tier), "fill your rack", string.format("%d/%d", goal.have, goal.need)
end

return NextGoal
