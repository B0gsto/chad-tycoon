--[[
	Analytics: funnels for the Creator Dashboard (AnalyticsService), so ad traffic can be
	judged by where new players stop and how often the shop turns into a purchase.

	Onboarding funnel (Dashboard > Analytics > Funnels > Onboarding), once per player.
	The highest step logged is saved in profile.onboarding; saves from before this
	module start at ONBOARDING_LEGACY and never log.
	  1 Joined            first session starts
	  2 Intro Done        the cutscene finished or was skipped (Player attribute IntroSeen)
	  3..7                each tutorial step reached / finished (Buy, Orbs, Deposit, Collect, Merge)
	A skipped tutorial logs the custom event "TutorialSkipped" and stops the funnel.

	Shop funnel (recurring "Shop"): 1 Opened, 2 Prompted, 3 Purchased. One funnel session
	per shop visit; a prompt from outside the shop (pads, crate panel) starts a new one.
]]

local AnalyticsService = game:GetService("AnalyticsService")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local TutorialSteps = require(ReplicatedStorage.Shared.TutorialSteps)

local Tycoon = require(script.Parent.Tycoon)

local Analytics = {}

Analytics.ONBOARDING_LEGACY = 99

local ONBOARDING_NAMES = { "Joined", "Intro Done" }
for i, step in TutorialSteps.STEPS do
	ONBOARDING_NAMES[2 + i] = "Tutorial " .. i .. " " .. step.id
end

-- Player -> current shop funnel session id and its last step.
local shopFunnel: { [Player]: { id: string, step: number } } = {}

local function safely(fn: (...any) -> (), ...: any)
	local ok, err = pcall(fn, ...)
	if not ok then
		warn("[Analytics]", err)
	end
end

-- Logs onboarding steps up to `step` that this player has not logged yet.
function Analytics.onboard(session: Tycoon.Session, step: number)
	local p = session.profile
	if not session.alive or step <= p.onboarding or p.onboarding >= Analytics.ONBOARDING_LEGACY then
		return
	end
	for s = p.onboarding + 1, math.min(step, #ONBOARDING_NAMES) do
		safely(AnalyticsService.LogOnboardingFunnelStepEvent, AnalyticsService, session.player, s, ONBOARDING_NAMES[s])
	end
	p.onboarding = step
	Tycoon.markDirty(session)
end

-- Tutorial progress: `step` is the step now current (DONE = finished); skipped = true when skipped.
function Analytics.tutorial(session: Tycoon.Session, step: number, skipped: boolean?)
	if skipped then
		safely(AnalyticsService.LogCustomEvent, AnalyticsService, session.player, "TutorialSkipped", step)
		return
	end
	-- Step n current means steps 1..n-1 are done: funnel step 2 + (n - 1).
	Analytics.onboard(session, 1 + step)
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
	Analytics.onboard(session, 1)
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
	Players.PlayerRemoving:Connect(function(player)
		shopFunnel[player] = nil
	end)
end

return Analytics
