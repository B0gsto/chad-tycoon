--!strict
--[[
	TutorialSteps: the onboarding checklist as pure data + functions.

	No Roblox dependencies, so it is unit-tested with Lune (tests/run.luau) and
	shared by the server (progression) and the client (what to point at).

	Steps advance only in order. Each step completes on a real gameplay event
	reported by the server (see Tycoon.listeners) or, as a safety net, when the
	profile already shows the step was done (e.g. a game pass did it for you).

	  1 buy      Buy a unit on the Buy 1 pad               event "Buy"
	  2 orbs     Walk over the orbs your units drop        event "Pickup"
	  3 deposit  Deposit the tank at the converter         event "Deposit"
	  4 collect  Collect the converted cash                event "Cash"
	  5 merge    Merge two units of the same tier          event "Merge"
	  6          finished (reward granted once)
]]

local TutorialSteps = {}

export type Step = {
	id: string,
	event: string,
	target: string,
}

TutorialSteps.STEPS = {
	{ id = "buy", event = "Buy", target = "Buy1" },
	{ id = "orbs", event = "Pickup", target = "Orbs" },
	{ id = "deposit", event = "Deposit", target = "Deposit" },
	{ id = "collect", event = "Cash", target = "Collect" },
	{ id = "merge", event = "Merge", target = "Merge" },
} :: { Step }

TutorialSteps.COUNT = #TutorialSteps.STEPS
TutorialSteps.DONE = TutorialSteps.COUNT + 1

-- Minimal view of the saved profile the checks need.
export type ProfileView = {
	carried: number?,
	units: { number }?,
	discovered: { number }?,
}

-- Clamps any stored value (old saves, bad data) into 1..DONE.
function TutorialSteps.clamp(step: any): number
	if type(step) ~= "number" or step ~= step then
		return 1
	end
	return math.clamp(math.floor(step), 1, TutorialSteps.DONE)
end

function TutorialSteps.get(step: number): Step?
	return TutorialSteps.STEPS[step]
end

-- The step after `step` if `event` completes it, otherwise `step` unchanged.
function TutorialSteps.onEvent(step: number, event: string): number
	local current = TutorialSteps.STEPS[step]
	if current and current.event == event then
		return step + 1
	end
	return step
end

-- True when the profile shows the current step is already accomplished.
function TutorialSteps.satisfied(step: number, profile: ProfileView): boolean
	local current = TutorialSteps.STEPS[step]
	if not current then
		return false
	end
	if current.id == "orbs" then
		return (profile.carried or 0) > 0
	elseif current.id == "merge" then
		local discovered = profile.discovered or {}
		for tier = 2, #discovered do
			if (discovered[tier] or 0) > 0 then
				return true
			end
		end
	end
	return false
end

-- Advances through every step the profile already satisfies.
function TutorialSteps.catchUp(step: number, profile: ProfileView): number
	while step <= TutorialSteps.COUNT and TutorialSteps.satisfied(step, profile) do
		step += 1
	end
	return step
end

-- True for the deposit that completes the "deposit" step: the server turns it into cash
-- at once instead of queueing it in the converter, so the "collect" step has cash waiting
-- when a new player gets to the pad.
function TutorialSteps.instantDeposit(step: number, done: boolean?): boolean
	local current = TutorialSteps.STEPS[step]
	return not done and current ~= nil and current.id == "deposit"
end

-- True when some tier has at least two units (a merge is possible).
function TutorialSteps.hasPair(units: { number }?): boolean
	if not units then
		return false
	end
	for _, count in units do
		if count >= 2 then
			return true
		end
	end
	return false
end

-- What the guide should point at for `step`: a pad name (without "Pad_"),
-- "Orbs", or nil when finished. The merge step points at the Buy 1 pad until
-- the player owns a pair.
function TutorialSteps.target(step: number, units: { number }?): string?
	local current = TutorialSteps.STEPS[step]
	if not current then
		return nil
	end
	if current.id == "merge" and not TutorialSteps.hasPair(units) then
		return "Buy1"
	end
	return current.target
end

return TutorialSteps
