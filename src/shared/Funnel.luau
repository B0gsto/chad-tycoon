--!strict
--[[
	Funnel: the onboarding funnel's steps and rules as pure data + functions.

	No Roblox dependencies, so it is unit-tested with Lune (tests/run.luau).
	Server.Analytics does the logging.

	Steps, logged once per new player. The Creator Dashboard keeps its history by
	step number, so steps are only ever appended:
	  1 Joined         first session starts
	  2 Intro Done     the cutscene finished or was skipped
	  3..7             each tutorial step finished (buy, orbs, deposit, collect, merge)
	  8..11            highest tier discovered: Tier 3, Tier 5, Tier 7, Tier 10

	profile.onboarding says where a player is:
	  0..11         the highest step logged
	  SKIPPED + n   the tutorial was skipped. The funnel stops there: logging the rest
	                of it would count tutorial steps the player never did. Their tier
	                milestones are logged as one-time custom events instead
	                ("SkipperTier3", ...); n counts the ones already logged
	  LEGACY        a save from before the funnel: not a new player, never logs
]]

local Funnel = {}

Funnel.LEGACY = 99
Funnel.SKIPPED = 50
-- The step that finishing the tutorial logs (2 + TutorialSteps.COUNT).
Funnel.TUTORIAL_END = 7
-- Tiers whose first discovery is a step, in order.
Funnel.MILESTONES = { 3, 5, 7, 10 }
Funnel.LAST = Funnel.TUTORIAL_END + #Funnel.MILESTONES

export type Plan = {
	-- The new profile.onboarding.
	onboarding: number,
	-- Funnel steps to log, in order.
	steps: { number },
	-- Custom events to log, in order.
	events: { string },
}

-- How many milestones a player whose best tier is `highestTier` has reached.
function Funnel.reached(highestTier: number): number
	local count = 0
	for _, tier in Funnel.MILESTONES do
		if highestTier >= tier then
			count += 1
		end
	end
	return count
end

function Funnel.milestoneName(index: number): string
	return "Tier " .. Funnel.MILESTONES[index]
end

-- profile.onboarding after the tutorial is skipped (unchanged when the tutorial was
-- finished, already skipped, or the save is a legacy one).
function Funnel.skip(onboarding: number): number
	return if onboarding < Funnel.TUTORIAL_END then Funnel.SKIPPED else onboarding
end

-- What a profile at `onboarding` logs now that its best tier is `highestTier`. Nothing
-- while the tutorial is still running: the milestones follow once it is finished or
-- skipped.
function Funnel.tiers(onboarding: number, highestTier: number): Plan
	local plan: Plan = { onboarding = onboarding, steps = {}, events = {} }
	local reached = Funnel.reached(highestTier)
	if onboarding >= Funnel.LEGACY then
		return plan
	elseif onboarding >= Funnel.SKIPPED then
		for index = onboarding - Funnel.SKIPPED + 1, reached do
			table.insert(plan.events, "SkipperTier" .. Funnel.MILESTONES[index])
			plan.onboarding = Funnel.SKIPPED + index
		end
	elseif onboarding >= Funnel.TUTORIAL_END then
		for step = onboarding + 1, Funnel.TUTORIAL_END + reached do
			table.insert(plan.steps, step)
			plan.onboarding = step
		end
	end
	return plan
end

return Funnel
