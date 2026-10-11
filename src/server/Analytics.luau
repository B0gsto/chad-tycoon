--[[
	Analytics: funnels for the Creator Dashboard (AnalyticsService), so ad traffic can be
	judged by where new players stop and how often the shop turns into a purchase.

	Onboarding funnel (Dashboard > Analytics > Funnels > Onboarding), once per player.
	Shared.Funnel has the step numbers and rules; progress is saved in
	profile.onboarding, and saves from before this module start at ONBOARDING_LEGACY
	and never log.
	  1 Joined            first session starts
	  2 Intro Done        the cutscene finished or was skipped (Player attribute IntroSeen)
	  3..7                each tutorial step reached / finished (Buy, Orbs, Deposit, Collect, Merge)
	  8..11               highest tier discovered: Tier 3, Tier 5, Tier 7, Tier 10
	A skipped tutorial logs the custom event "TutorialSkipped" and stops the funnel, so
	it never shows tutorial steps the player did not do. Their tier milestones are
	logged as one-time custom events instead: "SkipperTier3", "SkipperTier5",
	"SkipperTier7", "SkipperTier10". Everyone who reached a tier = its funnel step + its
	Skipper event.

	Intro: the first-run cutscene logs one custom event when it ends, "IntroSkipped" or
	"IntroWatched", with the story seconds played as its value.

	Shop funnel (recurring "Shop"): 1 Opened, 2 Prompted, 3 Purchased. One funnel session
	per shop visit; a prompt from outside the shop (pads, crate panel) starts a new one.
]]

local AnalyticsService = game:GetService("AnalyticsService")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Economy = require(ReplicatedStorage.Shared.Economy)
local Funnel = require(ReplicatedStorage.Shared.Funnel)
local TutorialSteps = require(ReplicatedStorage.Shared.TutorialSteps)

local Tycoon = require(script.Parent.Tycoon)

local Analytics = {}

Analytics.ONBOARDING_LEGACY = Funnel.LEGACY

local ONBOARDING_NAMES = { "Joined", "Intro Done" }
for i, step in TutorialSteps.STEPS do
	ONBOARDING_NAMES[2 + i] = "Tutorial " .. i .. " " .. step.id
end
for i in Funnel.MILESTONES do
	ONBOARDING_NAMES[Funnel.TUTORIAL_END + i] = Funnel.milestoneName(i)
end

-- Player -> current shop funnel session id and its last step.
local shopFunnel: { [Player]: { id: string, step: number } } = {}

local function safely(fn: (...any) -> (), ...: any)
	local ok, err = pcall(fn, ...)
	if not ok then
		warn("[Analytics]", err)
	end
end

local function logStep(session: Tycoon.Session, step: number)
	safely(AnalyticsService.LogOnboardingFunnelStepEvent, AnalyticsService, session.player, step, ONBOARDING_NAMES[step])
end

-- Logs onboarding steps up to `step` that this player has not logged yet. A profile that
-- skipped the tutorial (Funnel.SKIPPED and up) or predates the funnel is past every step.
function Analytics.onboard(session: Tycoon.Session, step: number)
	local p = session.profile
	if not session.alive or step <= p.onboarding then
		return
	end
	for s = p.onboarding + 1, math.min(step, #ONBOARDING_NAMES) do
		logStep(session, s)
	end
	p.onboarding = step
	Tycoon.markDirty(session)
end

-- Tier milestones the player's best tier has reached and not logged yet (Funnel.tiers):
-- funnel steps after a finished tutorial, "SkipperTier<n>" custom events after a skipped one.
function Analytics.tiers(session: Tycoon.Session)
	local p = session.profile
	if not session.alive then
		return
	end
	local plan = Funnel.tiers(p.onboarding, Economy.highestTier(p.discovered))
	if plan.onboarding == p.onboarding then
		return
	end
	for _, step in plan.steps do
		logStep(session, step)
	end
	for _, name in plan.events do
		safely(AnalyticsService.LogCustomEvent, AnalyticsService, session.player, name)
	end
	p.onboarding = plan.onboarding
	Tycoon.markDirty(session)
end

-- Tutorial progress: `step` is the step now current (DONE = finished); skipped = true when skipped.
function Analytics.tutorial(session: Tycoon.Session, step: number, skipped: boolean?)
	if skipped then
		safely(AnalyticsService.LogCustomEvent, AnalyticsService, session.player, "TutorialSkipped", step)
		session.profile.onboarding = Funnel.skip(session.profile.onboarding)
		Tycoon.markDirty(session)
	else
		-- Step n current means steps 1..n-1 are done: funnel step 2 + (n - 1).
		Analytics.onboard(session, 1 + step)
	end
	-- Tiers discovered during the tutorial count from the moment it ends.
	Analytics.tiers(session)
end

-- The first-run cutscene ended after `seconds` of its story.
function Analytics.intro(session: Tycoon.Session, skipped: boolean, seconds: number)
	local name = if skipped then "IntroSkipped" else "IntroWatched"
	safely(AnalyticsService.LogCustomEvent, AnalyticsService, session.player, name, seconds)
end

function Analytics.shop(player: Player, step: number, name: string)
	local funnel = shopFunnel[player]
	if step == 1 or not funnel or step <= funnel.step then
		funnel = { id = HttpService:GenerateGUID(false), step = 0 }
		shopFunnel[player] = funnel
	end
	funnel.step = step
	safely(AnalyticsService.LogFunnelStepEvent, AnalyticsService, player, "Shop", funnel.id, step, name)
end

function Analytics.onSessionStart(session: Tycoon.Session)
	local player = session.player
	local p = session.profile
	-- A tutorial skipped before skips were marked in profile.onboarding.
	if p.tutorialDone and Funnel.skip(p.onboarding) ~= p.onboarding then
		p.onboarding = Funnel.skip(p.onboarding)
		Tycoon.markDirty(session)
	end
	Analytics.onboard(session, 1)
	Analytics.tiers(session)
	if player:GetAttribute("IntroSeen") == true then
		Analytics.onboard(session, 2)
	else
		local conn
		conn = player:GetAttributeChangedSignal("IntroSeen"):Connect(function()
			if player:GetAttribute("IntroSeen") == true then
				conn:Disconnect()
				Analytics.onboard(session, 2)
			end
		end)
	end
end

function Analytics.init()
	-- The shop window reports each time it opens (Client.UI.Windows).
	Tycoon.addAction("ShopOpened", function(session)
		Analytics.shop(session.player, 1, "Opened")
	end)
	table.insert(Tycoon.listeners, function(session, name)
		if name == "Discover" then
			Analytics.tiers(session)
		end
	end)
	Players.PlayerRemoving:Connect(function(player)
		shopFunnel[player] = nil
	end)
end

return Analytics
