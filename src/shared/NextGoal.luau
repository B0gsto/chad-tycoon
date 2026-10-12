--!strict
--[[
	NextGoal: picks the one concrete target the HUD's "Next:" line names (pure,
	unit-tested with Lune; Client.UI.Hud draws it once the tutorial is done).

	In order:
	  merge    the next undiscovered tier: merge two units of the best tier found
	  rack     every tier is discovered: stack units of the top tier
]]

local Economy = require(script.Parent.Economy)

local NextGoal = {}

export type Goal = {
	kind: "merge" | "rack",
	-- merge: the tier to discover; rack: the top tier.
	tier: number,
	-- merge: the tier to merge two of; rack: the top tier.
	from: number,
	-- Units counted toward the goal and how many it takes.
	have: number,
	need: number,
	-- 0..1 for a progress bar; `ready` = one step on a pad finishes it.
	progress: number,
	ready: boolean,
}

-- The fields of the State snapshot (or a saved profile) the pick reads.
export type Input = {
	discovered: { number },
	units: { number },
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
			progress = math.clamp(worth / Economy.MERGE_RATIO, 0, 1),
			ready = have >= Economy.MERGE_RATIO,
		}
	end
	local top = count(input.units, Economy.MAX_TIER)
	return {
		kind = "rack",
		tier = Economy.MAX_TIER,
		from = Economy.MAX_TIER,
		have = math.min(top, Economy.UNIT_CAP),
		need = Economy.UNIT_CAP,
		progress = math.clamp(top / Economy.UNIT_CAP, 0, 1),
		ready = false,
	}
end

--[[
	The goal in words: (title, hint, count), e.g. ("Protein Bro", "merge 2x Gym
	Rookie", "1/2"). `nameOf(tier)` names a unit tier.
	The HUD shows "Next: <title> (<hint>) <count>" and drops the hint when short of room.
]]
function NextGoal.text(goal: Goal, nameOf: (number) -> string): (string, string, string)
	if goal.kind == "merge" then
		local hint = string.format("merge %dx %s", goal.need, nameOf(goal.from))
		return nameOf(goal.tier), hint, string.format("%d/%d", goal.have, goal.need)
	end
	return nameOf(goal.tier), "fill your rack", string.format("%d/%d", goal.have, goal.need)
end

return NextGoal
