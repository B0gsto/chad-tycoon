--!strict
--[[
	IndexRewards: pure rules of the Index milestones (no Roblox dependencies, unit-tested
	with Lune: tests/index_rewards.luau; Server.Tycoon applies them, the Index window shows
	them).

	Finding 5 / 10 / 15 / 20 / 25 tiers pays 10 / 20 / 30 / 45 / 60 minutes of income, a crate
	from 10 on and, for the whole Index, the Champion aura colour and the gold Index frame.
	A milestone counts the Index (profile.discovered: every tier found) and is claimed by
	hand, once per save (profile.indexClaimed). A save from before the milestones has claimed
	none, so every one it has already passed is waiting for it.
]]

local Economy = require(script.Parent.Economy)

local IndexRewards = {}

-- `found`: tiers in the Index the milestone asks for. `seconds`: the cash, in seconds of the
-- claimer's income. `crate`: a crate of that rarity on top, opened on the spot. `champion`:
-- the Champion aura colour and the gold Index frame.
export type Milestone = { found: number, seconds: number, crate: string?, champion: boolean? }

IndexRewards.MILESTONES = {
	{ found = 5, seconds = 10 * 60 },
	{ found = 10, seconds = 20 * 60, crate = "Rare" },
	{ found = 15, seconds = 30 * 60, crate = "Epic" },
	{ found = 20, seconds = 45 * 60, crate = "Legendary" },
	{ found = 25, seconds = 60 * 60, champion = true },
} :: { Milestone }

-- The least a milestone pays, in cash per second of its `seconds` (only matters to a save
-- whose best tier earns next to nothing).
IndexRewards.MIN_INCOME = 1

-- The fields of a saved profile the milestones read and write.
export type Profile = {
	discovered: { number },
	processLevel: number,
	-- `found` of every milestone claimed, in the order they were claimed.
	indexClaimed: { number },
	-- `champion`: the Champion aura colour is owned (Server.Cosmetics shows it).
	cosmetics: { champion: boolean, [string]: any },
}

-- What a claim pays: the caller grants it (Tycoon's ClaimIndex action).
export type Grant = { found: number, cash: number, crate: string?, champion: boolean }

-- Tiers in the Index.
function IndexRewards.found(discovered: { number }): number
	local count = 0
	for tier = 1, Economy.MAX_TIER do
		local at = discovered[tier]
		if type(at) == "number" and at > 0 then
			count += 1
		end
	end
	return count
end

-- The milestone that asks for exactly `found` tiers (nil = there is none; a client may send
-- anything).
function IndexRewards.milestone(found: any): Milestone?
	for _, milestone in IndexRewards.MILESTONES do
		if milestone.found == found then
			return milestone
		end
	end
	return nil
end

function IndexRewards.isClaimed(claimed: { number }, found: number): boolean
	return table.find(claimed, found) ~= nil
end

-- `found` of every milestone the Index has reached and the save has not claimed, lowest first.
function IndexRewards.ready(discovered: { number }, claimed: { number }): { number }
	local have = IndexRewards.found(discovered)
	local list: { number } = {}
	for _, milestone in IndexRewards.MILESTONES do
		if have >= milestone.found and not IndexRewards.isClaimed(claimed, milestone.found) then
			table.insert(list, milestone.found)
		end
	end
	return list
end

-- The cash of `milestone` for a player who earns `income` cash per second at `progression`
-- (Tycoon.income: no Aura Surge; passes, friends and Premium are in it once, as in every
-- other reward). Sized like a cash pack: never under the progression floor.
function IndexRewards.cash(milestone: Milestone, income: number, progression: Economy.Progression): number
	local perSecond = if income == income and income > 0 and income ~= math.huge then income else 0
	return Economy.moneyPackAmount(perSecond, milestone.seconds, milestone.seconds * IndexRewards.MIN_INCOME, progression)
end

-- What `milestone` pays on top of its cash when the rack has no room for its crate's unit:
-- the cash that unit is worth on average (0 without a crate), so the crate is never lost.
function IndexRewards.crateCash(milestone: Milestone, highestTier: number): number
	local crate = milestone.crate
	return if crate then math.floor(Economy.chestExpectedValue(crate, highestTier)) else 0
end

local function progressionOf(profile: Profile): Economy.Progression
	return Economy.progression(Economy.highestTier(profile.discovered), profile.processLevel)
end

-- Claims the milestone of `found` tiers, in place, for a player who earns `income` cash per
-- second right now (the same IndexRewards.cash the State snapshot shows on the CLAIM
-- button). Returns what to grant, or nil when there is nothing to claim: no such
-- milestone, the Index is not there yet, or it is claimed already. The milestone is marked
-- before this returns, so a second call (a double tap, two remotes in a row) pays nothing.
function IndexRewards.claim(profile: Profile, found: any, income: number): Grant?
	local milestone = IndexRewards.milestone(found)
	if not milestone or IndexRewards.isClaimed(profile.indexClaimed, milestone.found) then
		return nil
	end
	if IndexRewards.found(profile.discovered) < milestone.found then
		return nil
	end
	table.insert(profile.indexClaimed, milestone.found)
	if milestone.champion then
		profile.cosmetics.champion = true
	end
	return {
		found = milestone.found,
		cash = IndexRewards.cash(milestone, income, progressionOf(profile)),
		crate = milestone.crate,
		champion = milestone.champion == true,
	}
end

-- One milestone of the State snapshot: `cash` is what a claim would pay right now (0 once
-- claimed), `reached` = the Index has that many tiers.
export type Entry = { found: number, cash: number, crate: string?, champion: boolean, reached: boolean, claimed: boolean }

-- The State snapshot's `index` field: tiers in the Index, milestones waiting to be claimed
-- (the HUD's badge), whether the Champion reward is owned, and every milestone in order.
function IndexRewards.state(
	profile: Profile,
	income: number
): { found: number, claimable: number, champion: boolean, milestones: { Entry } }
	local have = IndexRewards.found(profile.discovered)
	local progression = progressionOf(profile)
	local claimable = 0
	local milestones: { Entry } = {}
	for i, milestone in IndexRewards.MILESTONES do
		local claimed = IndexRewards.isClaimed(profile.indexClaimed, milestone.found)
		local reached = have >= milestone.found
		if reached and not claimed then
			claimable += 1
		end
		milestones[i] = {
			found = milestone.found,
			cash = if claimed then 0 else IndexRewards.cash(milestone, income, progression),
			crate = milestone.crate,
			champion = milestone.champion == true,
			reached = reached,
			claimed = claimed,
		}
	end
	return { found = have, claimable = claimable, champion = profile.cosmetics.champion == true, milestones = milestones }
end

return IndexRewards
