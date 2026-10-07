--[[
	Tutorial: server side of the onboarding checklist.

	Progress lives in the saved profile (tutorialStep 1..6, tutorialDone) and
	is sent to the client in the State snapshot. Steps advance on real gameplay
	events reported by Tycoon.listeners; the order and rules are in
	Shared.TutorialSteps. Finishing grants a one-time reward; skipping does not.

	Notify payloads (client shows them):
	  { kind = "Tutorial", event = "step", step = n }
	  { kind = "Tutorial", event = "done", cash = c }
	  { kind = "Tutorial", event = "skipped" }
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Economy = require(Shared.Economy)
local Net = require(Shared.Net)
local TutorialSteps = require(Shared.TutorialSteps)

local Analytics = require(script.Parent.Analytics)
local Badges = require(script.Parent.Badges)
local Tycoon = require(script.Parent.Tycoon)

local Tutorial = {}

local NotifyRemote: RemoteEvent

local function notify(session: Tycoon.Session, payload: { [string]: any })
	payload.kind = "Tutorial"
	NotifyRemote:FireClient(session.player, payload)
end

local function finish(session: Tycoon.Session)
	local p = session.profile
	p.tutorialStep = TutorialSteps.DONE
	p.tutorialDone = true
	p.money += Economy.TUTORIAL_REWARD_CASH
	p.totalEarned += Economy.TUTORIAL_REWARD_CASH
	Badges.graduate(session)
	notify(session, { event = "done", cash = Economy.TUTORIAL_REWARD_CASH })
end

-- Moves to `step`, skipping anything the profile already shows as done.
local function advanceTo(session: Tycoon.Session, step: number)
	local p = session.profile
	step = TutorialSteps.catchUp(step, p)
	if step == p.tutorialStep then
		return
	end
	p.tutorialStep = step
	Analytics.tutorial(session, step)
	if step >= TutorialSteps.DONE then
		finish(session)
	else
		notify(session, { event = "step", step = step })
	end
	Tycoon.markDirty(session)
end

local function active(session: Tycoon.Session): boolean
	return session.alive and not session.profile.tutorialDone
end

function Tutorial.onEvent(session: Tycoon.Session, name: string, _data: { [string]: any })
	if not active(session) then
		return
	end
	local current = TutorialSteps.clamp(session.profile.tutorialStep)
	local nextStep = TutorialSteps.onEvent(current, name)
	if nextStep ~= current then
		advanceTo(session, nextStep)
	end
end

function Tutorial.skip(session: Tycoon.Session)
	if not active(session) then
		return
	end
	local p = session.profile
	p.tutorialDone = true
	Analytics.tutorial(session, p.tutorialStep, true)
	p.tutorialStep = TutorialSteps.DONE
	notify(session, { event = "skipped" })
	Tycoon.markDirty(session)
end

function Tutorial.init()
	NotifyRemote = Net.event("Notify")
	table.insert(Tycoon.listeners, Tutorial.onEvent)
	Tycoon.addAction("SkipTutorial", function(session)
		Tutorial.skip(session)
	end)

	-- Safety net: a step the profile already satisfies (e.g. a pass collected
	-- the orbs for you) completes on its own.
	task.spawn(function()
		while true do
			task.wait(1)
			for _, session in Tycoon.allSessions() do
				if active(session) then
					local current = TutorialSteps.clamp(session.profile.tutorialStep)
					advanceTo(session, current)
				end
			end
		end
	end)
end

return Tutorial
