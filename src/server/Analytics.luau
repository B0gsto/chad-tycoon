--[[
	Analytics: funnels and events for the Creator Dashboard (AnalyticsService), so ad
	traffic can be judged by where new players stop, how often the shop turns into a
	purchase, and what players who stay (or leave) did before.

	Onboarding funnel (Dashboard > Analytics > Funnels > Onboarding), once per player.
	Shared.Funnel has the step numbers and rules; progress is saved in
	profile.onboarding, and saves from before this module start at ONBOARDING_LEGACY
	and never log.
	  1 Joined            first session starts
	  2 Intro Done        the cutscene finished or was skipped (Player attribute IntroSeen)
	  3..7                each tutorial step reached / finished (Buy, Orbs, Deposit, Collect, Merge)
	  8..11               highest tier discovered: Tier 3, Tier 5, Tier 7, Tier 10
	  12..15              the late tiers: Tier 12, Tier 15, Tier 20, Tier 25 (Funnel.late)
	A skipped tutorial logs the custom event "TutorialSkipped" and stops the funnel, so
	it never shows tutorial steps the player did not do. Their tier milestones are
	logged as one-time custom events instead: "SkipperTier3", "SkipperTier5",
	"SkipperTier7", "SkipperTier10". Everyone who reached a tier = its funnel step + its
	Skipper event. Profiles from before the milestones whose tutorial was already over
	log none of them (Funnel.returning): the tiers they reached long ago are not news.

	Intro: the first-run cutscene logs one custom event when it ends, "IntroSkipped" or
	"IntroWatched", with the story seconds played as its value.

	Shop funnel (recurring "Shop"): 1 Opened, 2 Prompted, 3 Purchased. One funnel session
	per shop visit; a prompt from outside the shop (pads, crate panel) starts a new one.

	Custom events (value; custom fields 1, 2, 3). Shared.Telemetry has the labels:
	  TierReached   tier; "Tier 12", player age        a best tier from 11 up, when discovered
	  SessionEnd    seconds played; length bucket, best tier, player age
	  ReturnGap     hours since the last session; gap bucket, tier band
	  AwayCard      hours since the last session; gap bucket, what the card listed
	                ("Cash+Crate+Daily", ..., "None"), tier band      once a session
	  DailyClaim    streak; "Day 3", streak week, Cash / Crate / CrateAsCash
	  StreakSaved   streak; streak week, "Day 3"       that claim used the streak saver
	  StreakLost    the streak that ended; its streak week      that claim started again at 1
	  IndexClaim    milestone (tiers found); "Index 10", player age
	  Crate         1; Smasher / Pass / PaidSmasher / PaidHeld / Discard, rarity
	  ModeStart     1; mode, map / stage / duel kind
	  ModeFinish    1; mode, map / stage, why it paid: First / Full / RunAgain (the run again
	                bonus) / Assisted / Resting / None. Until the pay kinds this field was
	                First / Repeat, "Repeat" being any finish after the first
	  ModeSkip      1; mode, map
	  ModeStop      1; mode, reason                    every end of a run, finishes included

	Economy events (currency "Cash"; custom field 1 = tier band), summed per player in a
	Telemetry.Ledger and sent once a minute and when the session ends, one event per source
	or sink that moved, with the wallet at that moment as the ending balance:
	  sources  Collect, Offline, Free, Daily, Index, ModeParkour / ModeMog / ModeCardio, Pack,
	           Tutorial
	  sinks    Units, Converter, Treadmill (Cardio), Skip (Parkour's Skip Map)

	Where they come from: Tycoon's listener events "Discover", "Cash", "Buy" { amount,
	cost? }, "Earn" { source, amount }, "Spend" { sink, amount }, "Crate" { path, rarity },
	"IndexClaim" { milestone } and "Notify" (each Notify payload: the daily claim, the
	offline return and every mode event), plus GameModes.hooks.rewarded and the client
	action "AwayShown" { cash, crate, daily }. Other modules can call Analytics.earn / spend /
	daily / crate / mode / offline / index / away directly instead.

	Every call goes through `send`, which keeps each player inside Telemetry's per-minute
	caps. With the Workspace attribute "AnalyticsDebug" = true every call is printed too
	(Studio sends nothing, so this is how to see them there). No event carries anything
	personal: the labels are tiers, buckets and fixed words.
]]

local AnalyticsService = game:GetService("AnalyticsService")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local DailyReward = require(ReplicatedStorage.Shared.DailyReward)
local Economy = require(ReplicatedStorage.Shared.Economy)
local Funnel = require(ReplicatedStorage.Shared.Funnel)
local Telemetry = require(ReplicatedStorage.Shared.Telemetry)
local TutorialSteps = require(ReplicatedStorage.Shared.TutorialSteps)

local GameModes = require(script.Parent.GameModes)
local Tycoon = require(script.Parent.Tycoon)

local Analytics = {}

Analytics.ONBOARDING_LEGACY = Funnel.LEGACY

local DEBUG_ATTRIBUTE = "AnalyticsDebug"
local CURRENCY = "Cash"
-- The ledger is sent this often, at most this many sources and sinks at a time (the
-- rest wait a minute), and up to FINAL_ENTRIES when the session ends.
local FLUSH_SECONDS = 60
local ECONOMY_PER_FLUSH = 6
local FINAL_ENTRIES = 10
-- Tiers up to 10 are funnel steps (and Skipper events); from here each one is an event.
local TIER_EVENTS_FROM = 11

local FIELD_KEYS = {
	Enum.AnalyticsCustomFieldKeys.CustomField01.Name,
	Enum.AnalyticsCustomFieldKeys.CustomField02.Name,
	Enum.AnalyticsCustomFieldKeys.CustomField03.Name,
}
local FLOWS = {
	Source = Enum.AnalyticsEconomyFlowType.Source,
	Sink = Enum.AnalyticsEconomyFlowType.Sink,
}
-- Mode Notify events that are custom events.
local MODE_EVENTS = {
	start = "ModeStart",
	finish = "ModeFinish",
	win = "ModeFinish",
	skip = "ModeSkip",
	stop = "ModeStop",
}

local ONBOARDING_NAMES = { "Joined", "Intro Done" }
for i, step in TutorialSteps.STEPS do
	ONBOARDING_NAMES[2 + i] = "Tutorial " .. i .. " " .. step.id
end
for i in Funnel.MILESTONES do
	ONBOARDING_NAMES[Funnel.TUTORIAL_END + i] = Funnel.milestoneName(i)
end
for i in Funnel.LATE do
	ONBOARDING_NAMES[Funnel.LAST + i] = Funnel.lateName(i)
end

-- Player -> current shop funnel session id and its last step.
local shopFunnel: { [Player]: { id: string, step: number } } = {}

-- What this module keeps for a session, from its first event to SessionEnd.
type State = {
	startedAt: number,
	-- Best tier already counted by "TierReached".
	bestTier: number,
	ledger: Telemetry.Ledger,
	window: Telemetry.Window,
	-- A crate receipt is being paid out: the crate that opens next is the paid one.
	paidCrate: boolean,
	-- Hours since the last session when this one started (nil = a first session), and
	-- whether "AwayCard" has been sent.
	away: number?,
	awayLogged: boolean,
	-- The daily streak at the last claim.
	streak: number,
	ended: boolean,
}
local states: { [Tycoon.Session]: State } = setmetatable({}, { __mode = "k" }) :: any
local sessionOf: { [Player]: Tycoon.Session } = {}

-- Made on the session's first event (the offline return comes before onSessionStart);
-- nil once the session has ended.
local function stateOf(session: Tycoon.Session): State?
	local state = states[session]
	if not state then
		if not session.alive then
			return nil
		end
		local now = os.clock()
		local p = session.profile
		state = {
			startedAt = now,
			bestTier = Economy.highestTier(p.discovered),
			ledger = Telemetry.newLedger(),
			window = Telemetry.newWindow(now),
			paidCrate = false,
			-- Read now: a save during the session moves lastOnline.
			away = if p.lastOnline > 0 then math.max(0, os.time() - p.lastOnline) / 3600 else nil,
			awayLogged = false,
			streak = p.daily.streak or 0,
			ended = false,
		}
		states[session] = state
		sessionOf[session.player] = session
	end
	return if state.ended then nil else state
end

-- Every AnalyticsService call. `kind` is its rate class in the player's minute
-- (Telemetry.CAPS); false when it did not fit and was not made. `state` is nil only for a
-- player without a session.
local function send(state: State?, kind: string, method: string, player: Player, ...: any): boolean
	if state and not Telemetry.take(state.window, os.clock(), kind) then
		return false
	end
	if Workspace:GetAttribute(DEBUG_ATTRIBUTE) == true then
		print("[Analytics]", method, ...)
	end
	local ok, err = pcall((AnalyticsService :: any)[method], AnalyticsService, player, ...)
	if not ok then
		warn("[Analytics]", err)
	end
	return true
end

local function custom(state: State, kind: string, player: Player, name: string, value: number?, labels: { string }?)
	local fields: { [string]: string } = {}
	if labels then
		for i, label in labels do
			fields[FIELD_KEYS[i]] = label
		end
	end
	send(state, kind, "LogCustomEvent", player, name, value, if labels then fields else nil)
end

-- A custom event with up to three labels (custom fields 1..3). `kind` is its rate class:
-- "Event" unless the server already keeps it rare (Telemetry.CAPS).
local function event(session: Tycoon.Session, name: string, value: number?, labels: { string }?, kind: string?)
	local state = stateOf(session)
	if state then
		custom(state, kind or "Event", session.player, name, value, labels)
	end
end

local function bestTier(session: Tycoon.Session): number
	return Economy.highestTier(session.profile.discovered)
end

local function tenths(value: number): number
	return math.floor(value * 10 + 0.5) / 10
end

-- How long the player has had the game, in days, as a label.
local function age(session: Tycoon.Session): string
	local first = session.profile.daily.firstDay
	return Telemetry.ageBucket(if first > 0 then DailyReward.dayNumber(os.time()) - first else 0)
end

local function logStep(session: Tycoon.Session, step: number)
	send(stateOf(session), "Step", "LogOnboardingFunnelStepEvent", session.player, step, ONBOARDING_NAMES[step])
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
-- Then the late steps (Funnel.late); `old` = the session is starting, so a late tier the
-- profile already has is not news.
function Analytics.tiers(session: Tycoon.Session, old: boolean?)
	local p = session.profile
	if not session.alive then
		return
	end
	local highest = bestTier(session)
	local plan = Funnel.tiers(p.onboarding, highest)
	local late = Funnel.late(plan.onboarding, highest, not old)
	if late.onboarding == p.onboarding then
		return
	end
	for _, step in plan.steps do
		logStep(session, step)
	end
	for _, step in late.steps do
		logStep(session, step)
	end
	for _, name in plan.events do
		event(session, name)
	end
	p.onboarding = late.onboarding
	Tycoon.markDirty(session)
end

-- "TierReached" for each tier from TIER_EVENTS_FROM up that became the best tier just now.
local function reached(session: Tycoon.Session)
	local state = stateOf(session)
	if not state then
		return
	end
	local highest = bestTier(session)
	for tier = math.max(state.bestTier + 1, TIER_EVENTS_FROM), highest do
		event(session, "TierReached", tier, { Telemetry.tierLabel(tier), age(session) })
	end
	state.bestTier = math.max(state.bestTier, highest)
end

-- Tutorial progress: `step` is the step now current (DONE = finished); skipped = true when skipped.
function Analytics.tutorial(session: Tycoon.Session, step: number, skipped: boolean?)
	if skipped then
		event(session, "TutorialSkipped", step)
		session.profile.onboarding = Funnel.skip(session.profile.onboarding)
		Tycoon.markDirty(session)
	else
		-- Step n current means steps 1..n-1 are done: funnel step 2 + (n - 1).
		Analytics.onboard(session, 1 + step)
		if step >= TutorialSteps.DONE then
			-- Tutorial pays its reward right after reporting the last step.
			Analytics.earn(session, "Tutorial", Economy.TUTORIAL_REWARD_CASH)
		end
	end
	-- Tiers discovered during the tutorial count from the moment it ends.
	Analytics.tiers(session)
end

-- The first-run cutscene ended after `seconds` of its story.
function Analytics.intro(session: Tycoon.Session, skipped: boolean, seconds: number)
	local name = if skipped then "IntroSkipped" else "IntroWatched"
	event(session, name, seconds)
end

function Analytics.shop(player: Player, step: number, name: string)
	local funnel = shopFunnel[player]
	if step == 1 or not funnel or step <= funnel.step then
		funnel = { id = HttpService:GenerateGUID(false), step = 0 }
		shopFunnel[player] = funnel
	end
	funnel.step = step
	local session = Tycoon.getSession(player)
	-- Opening the shop over and over is capped; a purchase always counts.
	local kind = if step >= 3 then "Step" else "Event"
	send(session and stateOf(session), kind, "LogFunnelStepEvent", player, "Shop", funnel.id, step, name)
end

-- Cash into the wallet from `source` (a Telemetry.SOURCES name; "Purchase" = "Pack").
function Analytics.earn(session: Tycoon.Session, source: string, amount: number)
	local state = stateOf(session)
	if state then
		Telemetry.earn(state.ledger, source, amount)
	end
end

-- Cash out of the wallet into `sink` (a Telemetry.SINKS name).
function Analytics.spend(session: Tycoon.Session, sink: string, amount: number)
	local state = stateOf(session)
	if state then
		Telemetry.spend(state.ledger, sink, amount)
	end
end

-- Cash earned while away was put on the Collect pad: collecting it counts as "Offline".
function Analytics.offline(session: Tycoon.Session, cash: number)
	local state = stateOf(session)
	if state then
		Telemetry.offline(state.ledger, cash)
	end
end

-- The daily reward of card `day` (1..7) was claimed, making the streak `streak`.
-- `reward`: "Cash", "Crate" or "CrateAsCash" (the rack had no room for the crate's unit).
-- `saved` = the streak saver forgave a missed day: "StreakSaved". A claim that starts again
-- at 1 after a longer streak is "StreakLost", with the streak that ended.
function Analytics.daily(session: Tycoon.Session, day: number, streak: number, reward: string?, saved: boolean?)
	local state = stateOf(session)
	if not state then
		return
	end
	local card = "Day " .. math.clamp(math.floor(day), 1, 7)
	event(session, "DailyClaim", streak, { card, Telemetry.weekBucket(streak), reward or "Cash" })
	if saved then
		event(session, "StreakSaved", streak, { Telemetry.weekBucket(streak), card }, "Rare")
	elseif streak <= 1 and state.streak > 1 then
		event(session, "StreakLost", state.streak, { Telemetry.weekBucket(state.streak) }, "Rare")
	end
	state.streak = streak
end

-- An Index milestone (`milestone` tiers found: 5, 10, ...) was claimed. Its cash is the
-- "Index" source (Tycoon.grantMoney(session, cash, "Index")).
function Analytics.index(session: Tycoon.Session, milestone: number)
	if type(milestone) == "number" and milestone == milestone then
		event(session, "IndexClaim", milestone, { Telemetry.indexLabel(milestone), age(session) }, "Rare")
	end
end

-- The "while you were away" card was shown. `info` says what it listed: cash (an amount or
-- true), crate (a crate finished: true, a count or its rarity) and daily (the daily reward
-- is ready). Once a session, so a client cannot repeat it.
function Analytics.away(session: Tycoon.Session, info: { [string]: any }?)
	local state = stateOf(session)
	if not state or state.awayLogged then
		return
	end
	state.awayLogged = true
	local card = info or {}
	local hours = state.away or 0
	local listed = Telemetry.awayLabel(card.cash, card.crate, card.daily)
	event(session, "AwayCard", tenths(hours), { Telemetry.gapBucket(hours), listed, Telemetry.tierBand(bestTier(session)) })
end

-- What became of a crate: `path` is "unlocker", "unlock" or "discard" (Telemetry.cratePath).
-- "paid" comes first when a Robux receipt opens the crate, and is no event of its own.
function Analytics.crate(session: Tycoon.Session, path: string, rarity: string?)
	local state = stateOf(session)
	if not state then
		return
	elseif path == "paid" then
		state.paidCrate = true
		return
	end
	local paid = state.paidCrate
	state.paidCrate = false
	local name = Telemetry.cratePath(path, paid, session.passes.CrateKey == true)
	event(session, "Crate", 1, { name, Telemetry.word(rarity) })
end

-- A mode's Notify event (GameModes.notify): runs started, finished, skipped and stopped,
-- and the cash a mode takes (Parkour's Skip Map, Cardio's treadmill).
function Analytics.mode(session: Tycoon.Session, modeId: string, what: string, data: { [string]: any }?)
	local info = data or {}
	if what == "skip" then
		Analytics.spend(session, "Skip", info.cost or Economy.parkourSkipCost(Tycoon.income(session)))
	elseif what == "upgrade" then
		Analytics.spend(session, "Treadmill", info.cost)
	end
	local name = MODE_EVENTS[what]
	if not name then
		return
	end
	local labels = { Telemetry.word(modeId), Telemetry.modeDetail(data) }
	if what == "stop" then
		labels[2] = Telemetry.word(info.reason)
	elseif name == "ModeFinish" then
		labels[3] = Telemetry.payLabel(data)
	end
	event(session, name, 1, labels)
end

-- Sends what moved in the session's ledger since the last time. `final` = the session
-- is over: the player's cap no longer matters.
function Analytics.flush(session: Tycoon.Session, final: boolean?)
	local state = states[session]
	if not state or state.ended then
		return
	end
	local kind = if final then "Final" else "Economy"
	local max = if final then FINAL_ENTRIES else math.min(ECONOMY_PER_FLUSH, Telemetry.room(state.window, os.clock(), kind))
	local entries = Telemetry.drain(state.ledger, max)
	if #entries == 0 then
		return
	end
	local balance = math.max(0, session.profile.money)
	local fields = { [FIELD_KEYS[1]] = Telemetry.tierBand(bestTier(session)) }
	for _, entry in entries do
		local flow = FLOWS[entry.flow]
		send(state, kind, "LogEconomyEvent", session.player, flow, CURRENCY, entry.amount, balance, entry.transaction, entry.sku, fields)
	end
end

function Analytics.onSessionStart(session: Tycoon.Session)
	local player = session.player
	-- The session's clock and best tier start here, whatever happens first.
	local state = stateOf(session)
	-- No gap for a new player: there is no last session.
	local hours = state and state.away
	if hours then
		local labels = { Telemetry.gapBucket(hours), Telemetry.tierBand(bestTier(session)) }
		event(session, "ReturnGap", tenths(hours), labels)
	end
	-- Returning players never log here: a save from before the tier milestones arrives with
	-- all of them marked as logged (DataService's migration, Funnel.returning), so these
	-- two calls only send what a new profile has not sent yet.
	Analytics.onboard(session, 1)
	Analytics.tiers(session, true)
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

-- The session is over: the rest of its ledger and "SessionEnd". Tycoon may or may not
-- have removed the session already (both listen to PlayerRemoving), so this uses its own
-- record of it.
function Analytics.onSessionEnd(player: Player)
	shopFunnel[player] = nil
	local session = sessionOf[player]
	sessionOf[player] = nil
	local state = session and states[session]
	if not session or not state or state.ended then
		return
	end
	Analytics.flush(session, true)
	local seconds = math.floor(os.clock() - state.startedAt)
	local labels = { Telemetry.sessionBucket(seconds), Telemetry.tierLabel(bestTier(session)), age(session) }
	custom(state, "Final", player, "SessionEnd", seconds, labels)
	state.ended = true
end

local function onNotify(session: Tycoon.Session, payload: { [string]: any })
	local kind = payload.kind
	if kind == "Mode" then
		Analytics.mode(session, payload.mode, payload.event, payload)
	elseif kind == "Daily" and payload.event == "claimed" then
		local reward = if payload.crateCash then "CrateAsCash" elseif payload.crate then "Crate" else "Cash"
		Analytics.daily(session, payload.day, payload.streak, reward, payload.saved == true)
	elseif kind == "Offline" then
		Analytics.offline(session, payload.cash)
	end
end

local function onEvent(session: Tycoon.Session, name: string, data: { [string]: any })
	if name == "Discover" then
		Analytics.tiers(session)
		reached(session)
	elseif name == "Cash" then
		-- The Collect pad (and Auto Collect) paid out.
		local state = stateOf(session)
		if state then
			Telemetry.collect(state.ledger, data.amount)
		end
	elseif name == "Buy" then
		-- `bought` already counts these units; the event carries the price only if Tycoon adds it.
		local before = session.profile.bought - data.amount
		Analytics.spend(session, "Units", data.cost or Economy.bulkPrice(before, data.amount))
	elseif name == "Earn" then
		Analytics.earn(session, data.source, data.amount)
	elseif name == "Spend" then
		Analytics.spend(session, data.sink, data.amount)
	elseif name == "Crate" then
		Analytics.crate(session, data.path, data.rarity)
	elseif name == "IndexClaim" then
		Analytics.index(session, data.milestone)
	elseif name == "Notify" then
		onNotify(session, data)
	end
end

function Analytics.init()
	-- The shop window reports each time it opens (Client.UI.Windows).
	Tycoon.addAction("ShopOpened", function(session)
		Analytics.shop(session.player, 1, "Opened")
	end)
	-- So does the "while you were away" card, with what it lists.
	Tycoon.addAction("AwayShown", Analytics.away)
	table.insert(Tycoon.listeners, onEvent)
	-- Mode rewards are paid by the modes themselves; GameModes tells after each one.
	local rewarded = GameModes.hooks.rewarded
	GameModes.hooks.rewarded = function(session, modeId, reward)
		rewarded(session, modeId, reward)
		Analytics.earn(session, Telemetry.modeSource(modeId), reward.cash)
	end
	Players.PlayerRemoving:Connect(Analytics.onSessionEnd)
	task.spawn(function()
		while true do
			task.wait(FLUSH_SECONDS)
			for _, session in Tycoon.allSessions() do
				Analytics.flush(session)
			end
		end
	end)
end

return Analytics
