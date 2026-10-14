--[[
	Unit tests for the retention and economy analytics: the late funnel steps
	(src/shared/Funnel.luau), the labels, ledger and rate caps (src/shared/Telemetry.luau)
	and the server module (src/server/Analytics.luau, run against stub AnalyticsService,
	Tycoon and GameModes tables), the streak saver, Index claims and the away card
	included.
	Loaded by tests/run.luau with its harness: { test, check, eq }. Run alone with
	`lune run tests/analytics` it uses the small harness at the end of this file.
]]

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local process = require("@lune/process")
local serde = require("@lune/serde")
local task = require("@lune/task")

local Economy = require("../src/shared/Economy")
local Funnel = require("../src/shared/Funnel")
local Telemetry = require("../src/shared/Telemetry")
local TutorialSteps = require("../src/shared/TutorialSteps")

local DAY = 86400
local TODAY = 20000

-- The one function Analytics uses of Shared.DailyReward (which needs `script` to load).
local DailyReward = {
	dayNumber = function(now: number): number
		return math.floor(now / DAY)
	end,
}

local function enum(names: { string }): { [string]: any }
	local items = {}
	for _, name in names do
		items[name] = { Name = name }
	end
	return items
end

-- Analytics.luau against stubs. `world.calls` lists every AnalyticsService call as
-- { method, ...arguments after the player }.
local function loadAnalytics()
	local world = {
		calls = {},
		prints = 0,
		clock = 1000,
		time = TODAY * DAY + 3600,
		attributes = {} :: { [string]: any },
		sessions = {} :: { [any]: any },
		dirty = 0,
		rewardedBefore = 0,
	}
	local analyticsService = setmetatable({}, {
		__index = function(_, method)
			return function(_, _player, ...)
				table.insert(world.calls, { method, ... } :: { any })
			end
		end,
	})
	local removing
	local services = {
		AnalyticsService = analyticsService,
		HttpService = {
			GenerateGUID = function()
				return "guid"
			end,
		},
		Players = {
			PlayerRemoving = {
				Connect = function(_, fn)
					removing = fn
				end,
			},
		},
		ReplicatedStorage = {
			Shared = {
				DailyReward = DailyReward,
				Economy = Economy,
				Funnel = Funnel,
				Telemetry = Telemetry,
				TutorialSteps = TutorialSteps,
			},
		},
		Workspace = {
			GetAttribute = function(_, name)
				return world.attributes[name]
			end,
		},
	}
	local Tycoon = {
		listeners = {},
		actions = {},
		markDirty = function()
			world.dirty += 1
		end,
		getSession = function(player)
			return world.sessions[player]
		end,
		allSessions = function()
			return world.sessions
		end,
		income = function(session)
			return session.income
		end,
	}
	Tycoon.addAction = function(name, fn)
		Tycoon.actions[name] = fn
	end
	local GameModes = {
		hooks = {
			rewarded = function()
				world.rewardedBefore += 1
			end,
		},
	}
	local loop: (() -> ())?
	local env = setmetatable({
		game = {
			GetService = function(_, name)
				return services[name]
			end,
		},
		script = { Parent = { Tycoon = Tycoon, GameModes = GameModes } },
		require = function(module)
			return module
		end,
		Enum = {
			AnalyticsCustomFieldKeys = enum({ "CustomField01", "CustomField02", "CustomField03" }),
			AnalyticsEconomyFlowType = enum({ "Source", "Sink" }),
		},
		os = {
			time = function()
				return world.time
			end,
			clock = function()
				return world.clock
			end,
		},
		task = {
			spawn = function(fn)
				loop = fn
			end,
			wait = function()
				coroutine.yield()
			end,
		},
		print = function()
			world.prints += 1
		end,
		warn = function(...)
			error("warned: " .. table.concat({ ... }, " "))
		end,
	}, { __index = _G })
	local path = "src/server/Analytics.luau"
	local Analytics = luau.load(fs.readFile(path), { debugName = path, environment = env })()
	Analytics.init()

	-- A session whose best tier is `tier`, the way Main starts one.
	function world.join(tier: number, profile: { [string]: any }?): any
		local discovered = table.create(Economy.MAX_TIER, 0)
		for t = 1, tier do
			discovered[t] = 1
		end
		local player = {
			Name = "SecretName",
			UserId = 987654321,
			GetAttribute = function()
				return true
			end,
		}
		local p = {
			discovered = discovered,
			units = table.create(Economy.MAX_TIER, 0),
			carried = 0,
			queue = 0,
			pending = 0,
			processLevel = Economy.START_PROCESS_LEVEL,
			onboarding = Funnel.LAST,
			lastOnline = 0,
			money = 500,
			bought = 10,
			daily = { firstDay = TODAY },
		}
		for key, value in profile or {} do
			p[key] = value
		end
		local session = { alive = true, player = player, passes = {}, income = 4, profile = p }
		world.sessions[player] = session
		return session
	end
	function world.discover(session: any, tier: number)
		session.profile.discovered[tier] = 1
		world.emit(session, "Discover", { tier = tier })
	end
	function world.emit(session: any, name: string, data: { [string]: any })
		for _, listener in Tycoon.listeners do
			listener(session, name, data)
		end
	end
	function world.leave(session: any)
		removing(session.player)
		session.alive = false
		world.sessions[session.player] = nil
	end
	-- The calls of `method` (and of the custom event or SKU `name`) so far.
	function world.sent(method: string, name: string?): { { any } }
		local found = {}
		for _, call in world.calls do
			local label = if method == "LogEconomyEvent" then call[7] else call[2]
			if call[1] == method and (name == nil or label == name) then
				table.insert(found, call)
			end
		end
		return found
	end
	world.minute = coroutine.wrap(loop :: any)
	world.minute()
	return Analytics, world, Tycoon, GameModes
end

-- "a,b,c" of a custom event call's fields.
local function fields(call: { any }): string
	local custom = call[#call]
	if type(custom) ~= "table" then
		return ""
	end
	local list = {}
	for _, key in { "CustomField01", "CustomField02", "CustomField03" } do
		table.insert(list, custom[key])
	end
	return table.concat(list, ",")
end

-- "Name a,b,c" of every custom event call in `calls`, joined with "; ".
local function events(calls: { { any } }): string
	local list = {}
	for _, call in calls do
		table.insert(list, call[2] .. " " .. fields(call))
	end
	return table.concat(list, "; ")
end

-- Limits and privacy over `calls`: nothing of the player, at most three short custom
-- fields. Returns the custom event names seen.
local function inspect(calls: { { any } }, check: (any, string) -> ()): { [string]: boolean }
	local names = {}
	for _, call in calls do
		local text = serde.encode("json", call)
		check(not string.find(text, "SecretName", 1, true), "no player name in " .. text)
		check(not string.find(text, "987654321", 1, true), "no user id in " .. text)
		local custom = call[#call]
		if type(custom) == "table" then
			local keys = 0
			for key, value in custom do
				keys += 1
				check(string.match(key, "^CustomField0[123]$") ~= nil, "field key " .. tostring(key))
				check(type(value) == "string" and #value <= 20, "short label " .. tostring(value))
			end
			check(keys <= 3, "at most three custom fields")
		end
		if call[1] == "LogCustomEvent" then
			names[call[2]] = true
		end
	end
	return names
end

local ran = false

local function suite(h: { [string]: any })
	ran = true
	local test, check, eq = h.test, h.check, h.eq

	test("Analytics funnel: late tiers are appended as steps 12..15", function()
		eq(Funnel.LAST, 11, "the first eleven steps keep their numbers")
		eq(Funnel.LATE_LAST, 15, "four late steps")
		check(Funnel.LATE_LAST < Funnel.SKIPPED, "late steps stay under the skipped range")
		eq(Funnel.lateName(1), "Tier 12")
		eq(Funnel.lateName(4), "Tier 25")
		for _, tier in Funnel.LATE do
			check(tier > Funnel.MILESTONES[#Funnel.MILESTONES] and tier <= Economy.MAX_TIER, "late tier " .. tier .. " exists")
		end
		local plan = Funnel.late(11, 11, true)
		eq(#plan.steps, 0, "tier 11 is no late step")
		eq(plan.onboarding, 11)
		plan = Funnel.late(11, 12, true)
		eq(table.concat(plan.steps, ","), "12", "tier 12 logs step 12")
		eq(plan.onboarding, 12)
		plan = Funnel.late(12, 21, true)
		eq(table.concat(plan.steps, ","), "13,14", "a jump logs every step it passed")
		eq(plan.onboarding, 14)
		eq(table.concat(Funnel.late(11, 25, true).steps, ","), "12,13,14,15", "all four")
		eq(#Funnel.late(15, 25, true).steps, 0, "no step twice")
		eq(#Funnel.late(13, 14, true).steps, 0, "nor an earlier one again")
		-- Not before the tier 10 step, and never for skippers or legacy saves.
		for _, onboarding in { 0, 7, 10, Funnel.SKIPPED, Funnel.SKIPPED + 4, Funnel.LEGACY } do
			plan = Funnel.late(onboarding, 25, true)
			eq(#plan.steps + #plan.events, 0, "nothing at " .. onboarding)
			eq(plan.onboarding, onboarding, "unchanged at " .. onboarding)
		end
		-- A session's start: what the profile already has is marked, not sent.
		plan = Funnel.late(11, 16, false)
		eq(#plan.steps, 0, "old tiers are not news")
		eq(plan.onboarding, 13, "but count as logged")
		eq(table.concat(Funnel.late(plan.onboarding, 20, true).steps, ","), "14", "the next one is logged")
		-- The first funnel's rules do not move for a profile on a late step.
		for onboarding = Funnel.LAST + 1, Funnel.LATE_LAST do
			plan = Funnel.tiers(onboarding, 25)
			eq(#plan.steps + #plan.events, 0, "tiers() logs nothing at " .. onboarding)
			eq(plan.onboarding, onboarding)
			eq(Funnel.skip(onboarding), onboarding, "no skip at " .. onboarding)
			eq(Funnel.returning(onboarding, true), onboarding, "returning never lowers " .. onboarding)
		end
	end)

	test("Analytics labels: short fixed lists, nothing free-form", function()
		eq(Telemetry.tierLabel(12), "Tier 12")
		eq(Telemetry.tierBand(1), "Tier 1-5")
		eq(Telemetry.tierBand(5), "Tier 1-5")
		eq(Telemetry.tierBand(11), "Tier 11-15")
		eq(Telemetry.tierBand(25), "Tier 21-25")
		eq(Telemetry.tierBand(0), "Tier 1-5", "no tier yet")
		eq(Telemetry.sessionBucket(0), "0-2 min")
		eq(Telemetry.sessionBucket(120), "2-5 min")
		eq(Telemetry.sessionBucket(1700), "15-30 min")
		eq(Telemetry.sessionBucket(1e6), "60+ min")
		eq(Telemetry.gapBucket(0), "0-10 min")
		eq(Telemetry.gapBucket(0.5), "10-60 min")
		eq(Telemetry.gapBucket(5), "1-6 h")
		eq(Telemetry.gapBucket(23.9), "6-24 h")
		eq(Telemetry.gapBucket(30), "1-2 days")
		eq(Telemetry.gapBucket(100), "2-7 days")
		eq(Telemetry.gapBucket(5000), "7+ days")
		eq(Telemetry.ageBucket(0), "Day 0")
		eq(Telemetry.ageBucket(1), "Day 1")
		eq(Telemetry.ageBucket(6), "Day 2-6")
		eq(Telemetry.ageBucket(7), "Day 7-29")
		eq(Telemetry.ageBucket(19999), "Day 30+")
		eq(Telemetry.weekBucket(1), "Week 1")
		eq(Telemetry.weekBucket(7), "Week 1")
		eq(Telemetry.weekBucket(8), "Week 2")
		eq(Telemetry.weekBucket(28), "Week 3-4")
		eq(Telemetry.weekBucket(29), "Week 5+")
		eq(Telemetry.word("parkour"), "Parkour")
		eq(Telemetry.word("noOpponent"), "NoOpponent")
		eq(Telemetry.word("two words"), "Other", "not a single word")
		eq(Telemetry.word("Player_12345"), "Other", "nothing with digits")
		eq(Telemetry.word(string.rep("a", 17)), "Other", "too long")
		eq(Telemetry.word(nil), "Other")
		eq(Telemetry.word(12), "Other")
		eq(Telemetry.modeDetail({ level = 3, stage = 21 }), "Map 3", "Parkour's map")
		eq(Telemetry.modeDetail({ stage = 4 }), "Stage 4", "Cardio's stage")
		eq(Telemetry.modeDetail({ vs = "pvp" }), "Pvp", "Mog's duel")
		eq(Telemetry.modeDetail({ reason = "quit" }), "None")
		eq(Telemetry.modeDetail(nil), "None")
		eq(Telemetry.cratePath("unlocker", false, false), "Smasher", "waited for the timer")
		eq(Telemetry.cratePath("unlocker", false, true), "Pass", "Crate Master")
		eq(Telemetry.cratePath("unlocker", true, false), "PaidSmasher", "Robux on a slot")
		eq(Telemetry.cratePath("unlock", true, false), "PaidHeld", "Robux on the held crate")
		eq(Telemetry.cratePath("unlock", false, false), "PaidHeld", "a held crate opens no other way")
		eq(Telemetry.cratePath("unlock", false, true), "Pass")
		eq(Telemetry.cratePath("discard", false, false), "Discard")
		eq(Telemetry.cratePath("else", false, false), "Other")
		eq(Telemetry.indexLabel(10), "Index 10")
		eq(Telemetry.indexLabel(1e9), "Index 99")
		eq(Telemetry.payLabel({ pay = "first", first = true }), "First")
		eq(Telemetry.payLabel({ pay = "full", first = false }), "Full", "the cooldown was over")
		eq(Telemetry.payLabel({ pay = "repeat", first = false }), "RunAgain", "the run again bonus has its own word")
		eq(Telemetry.payLabel({ pay = "assisted" }), "Assisted")
		eq(Telemetry.payLabel({ pay = "resting" }), "Resting")
		eq(Telemetry.payLabel({ pay = "none" }), "None")
		eq(Telemetry.payLabel({ pay = "Player_12345" }), "Other", "nothing free-form")
		eq(Telemetry.payLabel({ pay = 3 }), "Other")
		eq(Telemetry.payLabel({ first = false }), "Repeat", "a payload from before the pay kinds")
		eq(Telemetry.payLabel({ first = true }), "First")
		eq(Telemetry.payLabel({ score = 12 }), nil)
		eq(Telemetry.payLabel(nil), nil)
		eq(Telemetry.awayLabel(120, "Rare", true), "Cash+Crate+Daily")
		eq(Telemetry.awayLabel(true, false, true), "Cash+Daily")
		eq(Telemetry.awayLabel(0, 2, nil), "Crate", "amounts and counts above 0")
		eq(Telemetry.awayLabel(0 / 0, "", false), "None")
		eq(Telemetry.awayLabel({}, nil, nil), "None", "nothing else counts")
	end)

	test("Analytics funnel: no rule lowers a profile's step, whatever tier it is given", function()
		local marks = { Funnel.LEGACY }
		for onboarding = 0, Funnel.LATE_LAST do
			table.insert(marks, onboarding)
		end
		for index = 0, #Funnel.MILESTONES do
			table.insert(marks, Funnel.SKIPPED + index)
		end
		for _, onboarding in marks do
			-- The first tier, were it ever passed by mistake.
			local plan = Funnel.tiers(onboarding, 1)
			local late = Funnel.late(plan.onboarding, 1, true)
			eq(#plan.steps + #plan.events + #late.steps, 0, "tier 1 logs nothing at " .. onboarding)
			for tier = 1, Economy.MAX_TIER do
				plan = Funnel.tiers(onboarding, tier)
				check(plan.onboarding >= onboarding, "tiers() never lowers " .. onboarding)
				for _, news in { true, false } do
					check(Funnel.late(plan.onboarding, tier, news).onboarding >= plan.onboarding, "late() never lowers " .. onboarding)
				end
			end
		end
	end)

	test("Analytics ledger: sums per source and sink, inside the dashboard's limits", function()
		local skus, types = 0, {}
		for _, known in { Telemetry.SOURCES, Telemetry.SINKS } do
			for _, transaction in known do
				skus += 1
				types[transaction] = true
			end
		end
		local typeCount = 0
		for _ in types do
			typeCount += 1
		end
		check(skus <= 100, "at most 100 item SKUs")
		check(typeCount <= 20, "at most 20 transaction types")
		for _, mode in { "parkour", "mog", "cardio" } do
			check(Telemetry.SOURCES[Telemetry.modeSource(mode)] ~= nil, mode .. " has its own source")
			check(Telemetry.modeSource(mode) ~= "Mode", mode .. " is told apart")
		end
		eq(Telemetry.modeSource("brandNew"), "Mode", "an unknown mode is still a mode")
		eq(Telemetry.modeSource(nil), "Mode")

		local ledger = Telemetry.newLedger()
		Telemetry.earn(ledger, "Free", 10)
		Telemetry.earn(ledger, "Free", 5)
		Telemetry.earn(ledger, "Purchase", 100)
		Telemetry.earn(ledger, "SomethingNew", 7)
		Telemetry.earn(ledger, nil, 1)
		Telemetry.spend(ledger, "Units", 40)
		Telemetry.spend(ledger, "Units", 2)
		Telemetry.spend(ledger, "Nope", 3)
		-- Nothing that is not a real amount.
		Telemetry.earn(ledger, "Daily", 0)
		Telemetry.earn(ledger, "Daily", -5)
		Telemetry.earn(ledger, "Daily", 0 / 0)
		Telemetry.earn(ledger, "Daily", math.huge)
		Telemetry.earn(ledger, "Daily", "12")
		Telemetry.spend(ledger, "Converter", nil)
		local entries = Telemetry.drain(ledger, 99)
		local seen = {}
		for _, entry in entries do
			table.insert(seen, string.format("%s %s %s %d", entry.flow, entry.sku, entry.transaction, entry.amount))
		end
		eq(
			table.concat(seen, "; "),
			"Sink Units Shop 42; Sink Other Shop 3; Source Free TimedReward 15; Source Pack IAP 100; Source Other Gameplay 8",
			"sinks, then sources"
		)
		eq(#Telemetry.drain(ledger, 99), 0, "drained once")

		-- Offline cash waits on the Collect pad and is counted when collected.
		Telemetry.offline(ledger, 100)
		eq(#Telemetry.drain(ledger, 99), 0, "not in the wallet yet")
		Telemetry.collect(ledger, 30)
		entries = Telemetry.drain(ledger, 99)
		eq(#entries, 1, "all of a small collect was earned away")
		eq(entries[1].sku, "Offline")
		eq(entries[1].amount, 30)
		Telemetry.collect(ledger, 200)
		entries = Telemetry.drain(ledger, 99)
		eq(entries[1].sku .. entries[1].amount, "Collect130", "the rest is played for")
		eq(entries[2].sku .. entries[2].amount, "Offline70", "what was left of the offline cash")
		Telemetry.collect(ledger, 50)
		entries = Telemetry.drain(ledger, 99)
		eq(#entries, 1, "offline cash is counted once")
		eq(entries[1].sku, "Collect")

		-- A capped drain keeps the rest for the next one.
		for name in Telemetry.SOURCES do
			Telemetry.earn(ledger, name, 1)
		end
		for name in Telemetry.SINKS do
			Telemetry.spend(ledger, name, 1)
		end
		local total = 0
		for _ = 1, 10 do
			local part = Telemetry.drain(ledger, 6)
			check(#part <= 6, "never more than asked")
			total += #part
		end
		eq(total, skus, "everything goes out in the end")
		eq(#Telemetry.drain(ledger, 0), 0, "no room, nothing taken")
	end)

	test("Analytics rate: each player stays under their 20 calls a minute", function()
		check(Telemetry.CAPS.Event < Telemetry.CAPS.Economy and Telemetry.CAPS.Economy < 20, "caps under Roblox's 20 per player")
		local window = Telemetry.newWindow(0)
		for i = 1, Telemetry.CAPS.Event do
			check(Telemetry.take(window, i, "Event"), "event " .. i .. " fits")
		end
		check(not Telemetry.take(window, 30, "Event"), "the next event does not")
		eq(Telemetry.room(window, 30, "Event"), 0)
		eq(Telemetry.room(window, 30, "Economy"), Telemetry.CAPS.Economy - Telemetry.CAPS.Event, "the ledger still has room")
		check(Telemetry.take(window, 30, "Step"), "funnel steps always go out")
		eq(Telemetry.room(window, 30, "Economy"), Telemetry.CAPS.Economy - Telemetry.CAPS.Event - 1, "and are counted")
		check(Telemetry.take(window, 59.9, "Economy"), "economy fits")
		check(Telemetry.take(window, 60, "Event"), "a new minute starts")
		eq(window.used, 1)
	end)

	test("Analytics server: return gap, late steps and TierReached", function()
		local Analytics, world = loadAnalytics()
		-- A brand-new player: joined + intro, no gap.
		local new = world.join(1, { onboarding = 0 })
		Analytics.onSessionStart(new)
		eq(#world.sent("LogCustomEvent", "ReturnGap"), 0, "no gap for a first session")
		eq(#world.sent("LogOnboardingFunnelStepEvent"), 2, "Joined and Intro Done")
		eq(new.profile.onboarding, 2)

		-- A returning player from before the late steps, already on tier 13.
		world.calls = {}
		local old = world.join(13, { lastOnline = world.time - 30 * 3600, daily = { firstDay = TODAY - 3 } })
		Analytics.onSessionStart(old)
		local gap = world.sent("LogCustomEvent", "ReturnGap")
		eq(#gap, 1, "one ReturnGap")
		eq(gap[1][3], 30, "hours away")
		eq(fields(gap[1]), "1-2 days,Tier 11-15")
		eq(#world.sent("LogOnboardingFunnelStepEvent"), 0, "tier 12 from long ago is not news")
		eq(old.profile.onboarding, 12, "but is marked")
		eq(#world.sent("LogCustomEvent", "TierReached"), 0, "nor are old tiers reached again")

		world.discover(old, 14)
		eq(#world.sent("LogOnboardingFunnelStepEvent"), 0, "tier 14 is no step")
		local reached = world.sent("LogCustomEvent", "TierReached")
		eq(#reached, 1, "tier 14 reached")
		eq(reached[1][3], 14, "the tier is the value")
		eq(fields(reached[1]), "Tier 14,Day 2-6")
		-- A jump over a tier counts both, and logs the step it passed.
		world.discover(old, 16)
		reached = world.sent("LogCustomEvent", "TierReached")
		eq(#reached, 3, "tiers 15 and 16")
		eq(reached[2][3] .. "," .. reached[3][3], "15,16")
		local steps = world.sent("LogOnboardingFunnelStepEvent")
		eq(#steps, 1, "one late step")
		eq(steps[1][2] .. " " .. steps[1][3], "13 Tier 15")
		eq(old.profile.onboarding, 13)
		world.discover(old, 16)
		eq(#world.sent("LogCustomEvent", "TierReached"), 3, "a tier is reached once")

		-- Tiers up to 10 stay funnel steps only; skippers get TierReached but no late step.
		world.calls = {}
		local young = world.join(9, { onboarding = 10, lastOnline = world.time - 60 })
		local skipper = world.join(11, { onboarding = Funnel.SKIPPED + 4 })
		Analytics.onSessionStart(young)
		Analytics.onSessionStart(skipper)
		eq(fields(world.sent("LogCustomEvent", "ReturnGap")[1]), "0-10 min,Tier 6-10")
		world.discover(young, 10)
		eq(#world.sent("LogCustomEvent", "TierReached"), 0, "tier 10 is a funnel step")
		eq(world.sent("LogOnboardingFunnelStepEvent")[1][2], 11)
		world.discover(skipper, 12)
		eq(#world.sent("LogCustomEvent", "TierReached"), 1, "a skipper's tier 12")
		eq(#world.sent("LogOnboardingFunnelStepEvent"), 1, "no late step for a skipper")
		eq(skipper.profile.onboarding, Funnel.SKIPPED + 4)
	end)

	test("Analytics server: cash sources and sinks, once a minute", function()
		local Analytics, world, _, GameModes = loadAnalytics()
		local session = world.join(12, { bought = 10, money = 900 })
		-- The offline return arrives before the session's start.
		world.emit(session, "Notify", { kind = "Offline", seconds = 600, orbs = 50, cash = 100 })
		Analytics.onSessionStart(session)
		world.emit(session, "Cash", { amount = 250 })
		world.emit(session, "Cash", { amount = 40 })
		world.emit(session, "Buy", { amount = 3 })
		world.emit(session, "Buy", { amount = 1, cost = 77 })
		world.emit(session, "Spend", { sink = "Converter", amount = 60 })
		world.emit(session, "Earn", { source = "Purchase", amount = 5000 })
		world.emit(session, "Earn", { source = "Free", amount = 20 })
		world.emit(session, "Earn", { source = "Daily", amount = 30 })
		world.emit(session, "Notify", { kind = "Toast", text = "hello" })
		world.emit(session, "Notify", { kind = "Mode", event = "skip", mode = "parkour", level = 2 })
		world.emit(session, "Notify", { kind = "Mode", event = "upgrade", mode = "cardio", cost = 15 })
		GameModes.hooks.rewarded(session, "parkour", { cash = 300, full = true })
		GameModes.hooks.rewarded(session, "mog", { cash = 0, full = false })
		eq(world.rewardedBefore, 2, "the hook that was there still runs")
		Analytics.tutorial(session, TutorialSteps.DONE)
		eq(#world.sent("LogEconomyEvent"), 0, "nothing until the minute is over")

		local expected = {
			Units = { "Sink", Economy.bulkPrice(7, 3) + 77, "Shop" },
			Converter = { "Sink", 60, "Shop" },
			Treadmill = { "Sink", 15, "Shop" },
			Skip = { "Sink", Economy.parkourSkipCost(4), "ContextualPurchase" },
			Collect = { "Source", 190, "Gameplay" },
			Offline = { "Source", 100, "TimedReward" },
			Free = { "Source", 20, "TimedReward" },
			Daily = { "Source", 30, "TimedReward" },
			ModeParkour = { "Source", 300, "Gameplay" },
			Pack = { "Source", 5000, "IAP" },
			Tutorial = { "Source", Economy.TUTORIAL_REWARD_CASH, "Onboarding" },
		}
		world.minute()
		eq(#world.sent("LogEconomyEvent"), 6, "six at a time")
		world.clock += 60
		world.minute()
		world.clock += 60
		world.minute()
		local count = 0
		for sku, want in expected do
			local calls = world.sent("LogEconomyEvent", sku)
			eq(#calls, 1, sku .. " is sent once")
			local call = calls[1] or {}
			count += 1
			eq(call[2] and call[2].Name, want[1], sku .. " flow")
			eq(call[3], "Cash", sku .. " currency")
			eq(call[4], want[2], sku .. " amount")
			eq(call[5], 900, sku .. " ending balance")
			eq(call[6], want[3], sku .. " transaction type")
			eq(fields(call), "Tier 11-15", sku .. " tier band")
		end
		eq(#world.sent("LogEconomyEvent"), count, "and nothing else")
		world.clock += 60
		world.minute()
		eq(#world.sent("LogEconomyEvent"), count, "an idle minute sends nothing")
	end)

	test("Analytics server: daily claims, crate paths and mode runs", function()
		local Analytics, world = loadAnalytics()
		local session = world.join(6)
		Analytics.onSessionStart(session)
		world.calls = {}

		world.emit(session, "Notify", { kind = "Daily", event = "claimed", day = 3, streak = 10, cash = 50, crate = "Rare" })
		world.emit(session, "Notify", { kind = "Daily", event = "claimed", day = 7, streak = 7, cash = 50, crateCash = 20 })
		world.emit(session, "Notify", { kind = "Daily", event = "hint" })
		Analytics.daily(session, 1, 1)
		local claims = world.sent("LogCustomEvent", "DailyClaim")
		eq(#claims, 3, "three claims")
		eq(claims[1][3], 10, "the streak is the value")
		eq(fields(claims[1]), "Day 3,Week 2,Crate")
		eq(fields(claims[2]), "Day 7,Week 1,CrateAsCash")
		eq(fields(claims[3]), "Day 1,Week 1,Cash")

		world.emit(session, "Crate", { path = "unlocker", rarity = "Common" })
		world.emit(session, "Crate", { path = "paid" })
		world.emit(session, "Crate", { path = "unlocker", rarity = "Epic" })
		world.emit(session, "Crate", { path = "unlocker", rarity = "Rare" })
		world.emit(session, "Crate", { path = "paid" })
		world.emit(session, "Crate", { path = "unlock", rarity = "Legendary" })
		world.emit(session, "Crate", { path = "discard", rarity = "Common" })
		session.passes.CrateKey = true
		world.emit(session, "Crate", { path = "unlock", rarity = "Rare" })
		local crates = {}
		for _, call in world.sent("LogCustomEvent", "Crate") do
			table.insert(crates, fields(call))
		end
		eq(
			table.concat(crates, "; "),
			"Smasher,Common; PaidSmasher,Epic; Smasher,Rare; PaidHeld,Legendary; Discard,Common; Pass,Rare",
			"a receipt marks only the crate it opens"
		)

		world.clock += 60
		world.calls = {}
		world.emit(session, "Notify", { kind = "Mode", event = "start", mode = "parkour", level = 3, stage = 21 })
		world.emit(session, "Notify", { kind = "Mode", event = "respawn", mode = "parkour", level = 3 })
		world.emit(session, "Notify", { kind = "Mode", event = "finish", mode = "parkour", level = 3, first = true, cash = 9 })
		world.emit(session, "Notify", { kind = "Mode", event = "stop", mode = "parkour", reason = "finish" })
		world.emit(session, "Notify", { kind = "Mode", event = "start", mode = "cardio", bestStage = 2 })
		world.emit(session, "Notify", { kind = "Mode", event = "win", mode = "cardio", stage = 2, first = false })
		world.emit(session, "Notify", { kind = "Mode", event = "start", mode = "mog", vs = "rivals" })
		world.emit(session, "Notify", { kind = "Mode", event = "finish", mode = "mog", score = 12 })
		world.emit(session, "Notify", { kind = "Mode", event = "skip", mode = "parkour", level = 4 })
		world.emit(session, "Notify", { kind = "Mode", event = "stop", mode = "parkour", reason = "skip" })
		local runs = {}
		for _, call in world.sent("LogCustomEvent") do
			table.insert(runs, call[2] .. " " .. fields(call))
		end
		eq(
			table.concat(runs, "; "),
			"ModeStart Parkour,Map 3; ModeFinish Parkour,Map 3,First; ModeStop Parkour,Finish; ModeStart Cardio,None; "
				.. "ModeFinish Cardio,Stage 2,Repeat; ModeStart Mog,Rivals; ModeFinish Mog,None; ModeSkip Parkour,Map 4; ModeStop Parkour,Skip",
			"starts, finishes, skips and stops"
		)
	end)

	test("Analytics server: streak saver, Index claims, the away card and why a mode paid", function()
		local Analytics, world, Tycoon = loadAnalytics()
		local session = world.join(6, { lastOnline = world.time - 30 * 3600, daily = { firstDay = TODAY - 20, streak = 12 } })
		Analytics.onSessionStart(session)
		world.calls = {}

		-- The saver forgave a missed day, then the streak ended, then a plain claim.
		world.emit(session, "Notify", { kind = "Daily", event = "claimed", day = 6, streak = 13, cash = 50, saved = true })
		world.emit(session, "Notify", { kind = "Daily", event = "claimed", day = 1, streak = 1, cash = 50 })
		world.emit(session, "Notify", { kind = "Daily", event = "claimed", day = 2, streak = 2, cash = 50 })
		eq(
			events(world.sent("LogCustomEvent")),
			"DailyClaim Day 6,Week 2,Cash; StreakSaved Week 2,Day 6; DailyClaim Day 1,Week 1,Cash; StreakLost Week 2; DailyClaim Day 2,Week 1,Cash",
			"saved, lost, kept"
		)
		eq(world.sent("LogCustomEvent", "StreakSaved")[1][3], 13, "the streak that was kept")
		eq(world.sent("LogCustomEvent", "StreakLost")[1][3], 13, "the streak that ended")
		-- A first claim ever ends no streak.
		local new = world.join(1)
		Analytics.onSessionStart(new)
		world.calls = {}
		world.emit(new, "Notify", { kind = "Daily", event = "claimed", day = 1, streak = 1, cash = 5 })
		eq(events(world.sent("LogCustomEvent")), "DailyClaim Day 1,Week 1,Cash")

		-- Index milestones: one event each, their cash under its own source.
		world.calls = {}
		world.emit(session, "IndexClaim", { milestone = 5 })
		world.emit(session, "IndexClaim", { milestone = 10 })
		world.emit(session, "IndexClaim", { milestone = "ten" })
		world.emit(session, "IndexClaim", {})
		eq(events(world.sent("LogCustomEvent")), "IndexClaim Index 5,Day 7-29; IndexClaim Index 10,Day 7-29")
		eq(world.sent("LogCustomEvent")[2][3], 10, "the milestone is the value")
		world.emit(session, "Earn", { source = "Index", amount = 640 })
		world.clock += 60
		world.minute()
		local paid = world.sent("LogEconomyEvent", "Index")
		eq(#paid, 1, "Index cash is its own source")
		eq(paid[1][4] .. " " .. paid[1][6], "640 Gameplay")

		-- The away card: once a session, with what it listed.
		world.calls = {}
		Tycoon.actions.AwayShown(session, { action = "AwayShown", cash = 120, crate = "Rare", daily = false, text = "SecretName" })
		Tycoon.actions.AwayShown(session, { action = "AwayShown", cash = 120, crate = "Rare", daily = true })
		Analytics.away(session, { cash = 1 })
		eq(events(world.sent("LogCustomEvent")), "AwayCard 1-2 days,Cash+Crate,Tier 6-10", "the first one counts")
		eq(world.sent("LogCustomEvent")[1][3], 30, "hours away")
		inspect(world.calls, check)
		world.calls = {}
		Analytics.away(new)
		eq(events(world.sent("LogCustomEvent")), "AwayCard 0-10 min,None,Tier 1-5", "a call that says nothing")
		eq(world.sent("LogCustomEvent")[1][3], 0)

		-- A mode finish says why it paid; the run again bonus is "RunAgain".
		world.clock += 60
		world.calls = {}
		world.emit(session, "Notify", { kind = "Mode", event = "finish", mode = "parkour", level = 2, first = true, pay = "first" })
		world.emit(session, "Notify", { kind = "Mode", event = "finish", mode = "parkour", level = 2, first = false, pay = "full" })
		world.emit(session, "Notify", { kind = "Mode", event = "finish", mode = "parkour", level = 2, first = false, pay = "repeat" })
		world.emit(session, "Notify", { kind = "Mode", event = "finish", mode = "parkour", level = 2, first = false, pay = "resting" })
		world.emit(session, "Notify", { kind = "Mode", event = "finish", mode = "parkour", level = 2, first = false, pay = "assisted" })
		world.emit(session, "Notify", { kind = "Mode", event = "win", mode = "cardio", stage = 4, first = false, pay = "repeat" })
		world.emit(session, "Notify", { kind = "Mode", event = "finish", mode = "mog", passed = false, pay = "none" })
		eq(
			events(world.sent("LogCustomEvent")),
			"ModeFinish Parkour,Map 2,First; ModeFinish Parkour,Map 2,Full; ModeFinish Parkour,Map 2,RunAgain; "
				.. "ModeFinish Parkour,Map 2,Resting; ModeFinish Parkour,Map 2,Assisted; ModeFinish Cardio,Stage 4,RunAgain; "
				.. "ModeFinish Mog,None,None",
			"the pay kind is the third field"
		)
		inspect(world.calls, check)

		-- An Index claim is never lost to the player's cap.
		for _ = 1, 40 do
			world.emit(session, "Notify", { kind = "Mode", event = "start", mode = "mog", vs = "rivals" })
		end
		world.calls = {}
		world.emit(session, "IndexClaim", { milestone = 15 })
		eq(events(world.sent("LogCustomEvent")), "IndexClaim Index 15,Day 7-29", "what the server keeps rare always goes out")
	end)

	test("Analytics server: a player's minute is capped, purchases and steps are not", function()
		local Analytics, world, Tycoon = loadAnalytics()
		local session = world.join(11)
		Analytics.onSessionStart(session)
		world.calls = {}
		for _ = 1, 40 do
			world.emit(session, "Notify", { kind = "Mode", event = "start", mode = "mog", vs = "rivals" })
			Tycoon.actions.ShopOpened(session)
		end
		eq(#world.calls, Telemetry.CAPS.Event, "spam stops at the cap")
		Analytics.shop(session.player, 2, "Prompted")
		eq(#world.sent("LogFunnelStepEvent"), Telemetry.CAPS.Event / 2, "a prompt is capped too")
		Analytics.shop(session.player, 3, "Purchased")
		eq(#world.sent("LogFunnelStepEvent"), Telemetry.CAPS.Event / 2 + 1, "a purchase always counts")
		world.discover(session, 12)
		eq(#world.sent("LogOnboardingFunnelStepEvent"), 1, "so does a funnel step")
		eq(session.profile.onboarding, 12)
		-- The ledger still gets through, inside what is left of the player's 18.
		for name in Telemetry.SOURCES do
			Analytics.earn(session, name, 5)
		end
		world.minute()
		eq(#world.sent("LogEconomyEvent"), Telemetry.CAPS.Economy - #world.calls + #world.sent("LogEconomyEvent"), "up to the cap")
		check(#world.sent("LogEconomyEvent") >= 1 and #world.calls <= Telemetry.CAPS.Economy, "never past it")
		check(#world.calls < 20, "under Roblox's 20 a minute per player")
		world.clock += 60
		world.minute()
		eq(#world.sent("LogEconomyEvent"), 4 + 6, "the rest follows a minute later")
	end)

	test("Analytics server: SessionEnd closes the session and nothing is personal", function()
		local Analytics, world = loadAnalytics()
		local session = world.join(9, { lastOnline = world.time - 7200, daily = { firstDay = TODAY - 1 }, money = 1234 })
		Analytics.onSessionStart(session)
		world.emit(session, "Cash", { amount = 75 })
		world.emit(session, "Buy", { amount = 2 })
		Analytics.intro(session, true, 4)
		Analytics.tutorial(session, 3, true)
		world.clock += 754
		world.leave(session)
		local ended = world.sent("LogCustomEvent", "SessionEnd")
		eq(#ended, 1, "one SessionEnd")
		eq(ended[1][3], 754, "seconds played")
		eq(fields(ended[1]), "5-15 min,Tier 9,Day 1")
		eq(#world.sent("LogEconomyEvent"), 2, "the ledger is sent with it")
		eq(world.sent("LogEconomyEvent", "Collect")[1][5], 1234, "with the final balance")
		local before = #world.calls
		world.emit(session, "Cash", { amount = 10 })
		Analytics.flush(session, true)
		Analytics.onSessionEnd(session.player)
		eq(#world.calls, before, "nothing after the end")

		-- A session that never reached onSessionStart (left while loading) has nothing to end.
		Analytics.onSessionEnd(world.join(3).player)
		eq(#world.calls, before, "no session, no SessionEnd")

		-- Limits and privacy over everything this test's session sent.
		local names = inspect(world.calls, check)
		check(names.ReturnGap and names.SessionEnd and names.IntroSkipped and names.TutorialSkipped, "the events were sent")
	end)

	test("Analytics server: the debug flag prints every call", function()
		local Analytics, world = loadAnalytics()
		local session = world.join(4, { lastOnline = world.time - 100 })
		Analytics.onSessionStart(session)
		eq(world.prints, 0, "quiet by default")
		world.attributes.AnalyticsDebug = true
		world.emit(session, "Crate", { path = "discard", rarity = "Common" })
		world.emit(session, "Cash", { amount = 5 })
		world.leave(session)
		eq(world.prints, 3, "the crate, the ledger and SessionEnd")
	end)
end

-- Run alone: tests/run.luau calls the returned function at once; when nobody has by the time
-- this file is done, run it here.
task.defer(function()
	if ran then
		return
	end
	local passed, failed = 0, 0
	local current = ""
	local function check(condition: any, message: string)
		if condition then
			passed += 1
		else
			failed += 1
			print(string.format("  FAIL [%s] %s", current, message))
		end
	end
	suite({
		check = check,
		eq = function(actual: any, expected: any, message: string?)
			check(actual == expected, string.format("%s: expected %s, got %s", message or "value", tostring(expected), tostring(actual)))
		end,
		test = function(name: string, fn: () -> ())
			current = name
			local ok, err = pcall(fn)
			if not ok then
				failed += 1
				print(string.format("  ERROR [%s] %s", name, tostring(err)))
			end
		end,
	})
	print(string.format("\n%d passed, %d failed", passed, failed))
	if failed > 0 then
		process.exit(1)
	end
end)

return suite
