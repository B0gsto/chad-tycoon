--!strict
--[[
	Telemetry: the rules behind Server.Analytics' retention and economy events, as pure
	data + functions (no Roblox dependencies; unit-tested with Lune, tests/analytics.luau).

	Limits of AnalyticsService this module keeps the game inside:
	  - 120 + 20 per player calls a minute for the whole server, every kind of event
	    together. Telemetry.take gives each player their own minute of at most
	    CAPS.Economy calls (under their 20), so the shared 120 stays spare. Cash moves are
	    summed in a Ledger and sent at most once a minute per source or sink.
	  - 100 custom event names (22 are used), 3 custom fields per event, 8,000 custom field
	    values in all: every label below comes from a short fixed list (tiers, bands, buckets).
	  - 10 currencies (one is used: "Cash"), 20 transaction types (the six of
	    Enum.AnalyticsEconomyTransactionType), 100 item SKUs (SOURCES + SINKS).
	Nothing personal is ever a label: no names, ids or text typed by a player.
]]

local Telemetry = {}

-- Labels ----------------------------------------------------------------------------

function Telemetry.tierLabel(tier: number): string
	return "Tier " .. math.clamp(math.floor(tier), 0, 99)
end

-- Five tiers to a band ("Tier 11-15"), for charts that do not need each tier.
function Telemetry.tierBand(tier: number): string
	local first = math.floor((math.clamp(math.floor(tier), 1, 95) - 1) / 5) * 5 + 1
	return string.format("Tier %d-%d", first, first + 4)
end

-- The label of the first bucket whose upper edge `value` is under; the last label otherwise.
local function bucket(value: number, edges: { number }, labels: { string }): string
	for index, edge in edges do
		if value < edge then
			return labels[index]
		end
	end
	return labels[#labels]
end

function Telemetry.sessionBucket(seconds: number): string
	return bucket(seconds, { 120, 300, 900, 1800, 3600 }, { "0-2 min", "2-5 min", "5-15 min", "15-30 min", "30-60 min", "60+ min" })
end

function Telemetry.gapBucket(hours: number): string
	return bucket(hours, { 1 / 6, 1, 6, 24, 48, 168 }, { "0-10 min", "10-60 min", "1-6 h", "6-24 h", "1-2 days", "2-7 days", "7+ days" })
end

-- Days since the player's first day (0 = still their first day).
function Telemetry.ageBucket(days: number): string
	return bucket(days, { 1, 2, 7, 30 }, { "Day 0", "Day 1", "Day 2-6", "Day 7-29", "Day 30+" })
end

-- A daily streak as the week it is in.
function Telemetry.weekBucket(streak: number): string
	return bucket(streak, { 8, 15, 29 }, { "Week 1", "Week 2", "Week 3-4", "Week 5+" })
end

-- An Index milestone (tiers found: 5, 10, ...).
function Telemetry.indexLabel(milestone: number): string
	return "Index " .. math.clamp(math.floor(milestone), 0, 99)
end

-- A short server-side word (a mode id, a stop reason, a rarity) as a label; anything
-- else (not a string, too long, not just letters) is "Other".
function Telemetry.word(value: any): string
	if type(value) == "string" and #value <= 16 and string.match(value, "^%a+$") then
		return string.upper(string.sub(value, 1, 1)) .. string.sub(value, 2)
	end
	return "Other"
end

-- A Robux item as a label: a pass's name ("DoubleAura"), or a product list and its place
-- in it ("Money 2", "Aura 4"); "Crate" for the instant crate open.
function Telemetry.itemLabel(name: any, index: any): string
	local label = Telemetry.word(name)
	if type(index) == "number" and index == index then
		label ..= " " .. math.clamp(math.floor(index), 0, 99)
	end
	return label
end

-- Which part of a mode a Notify payload is about: Parkour's map, Cardio's stage, Mog's
-- kind of duel.
function Telemetry.modeDetail(data: { [string]: any }?): string
	if not data then
		return "None"
	elseif type(data.level) == "number" then
		return "Map " .. math.clamp(math.floor(data.level), 0, 99)
	elseif type(data.stage) == "number" then
		return "Stage " .. math.clamp(math.floor(data.stage), 0, 99)
	elseif data.vs ~= nil then
		return Telemetry.word(data.vs)
	end
	return "None"
end

-- Why a mode's finish paid what it did, from its Notify payload's `pay`. "RunAgain" is the
-- run again bonus (pay = "repeat"): a clean run inside the cooldown. A payload without `pay`
-- says First / Repeat from `first` as every finish did before the pay kinds, where "Repeat"
-- was any finish after the first; nil when it says neither.
local PAY: { [string]: string } = {
	first = "First",
	full = "Full",
	["repeat"] = "RunAgain",
	assisted = "Assisted",
	resting = "Resting",
	none = "None",
}

function Telemetry.payLabel(data: { [string]: any }?): string?
	if not data then
		return nil
	elseif data.pay ~= nil then
		return PAY[data.pay] or "Other"
	elseif data.first ~= nil then
		return if data.first then "First" else "Repeat"
	end
	return nil
end

-- Whether a "while you were away" card had this line: true, a number above 0 or a word (a
-- crate's rarity).
local function listed(value: any): boolean
	return value == true or (type(value) == "number" and value > 0) or (type(value) == "string" and value ~= "")
end

-- What a "while you were away" card listed, in a fixed order: "Cash+Crate+Daily", ..., "None".
function Telemetry.awayLabel(cash: any, crate: any, daily: any): string
	local parts = {}
	if listed(cash) then
		table.insert(parts, "Cash")
	end
	if listed(crate) then
		table.insert(parts, "Crate")
	end
	if listed(daily) then
		table.insert(parts, "Daily")
	end
	return if #parts > 0 then table.concat(parts, "+") else "None"
end

-- What became of a crate. `path` is Tycoon's: "unlocker" (opened in a Smasher slot),
-- "unlock" (a held crate opened on the spot) or "discard". `paid` = a Robux receipt opened
-- it, `pass` = the player owns Crate Master (opens every crate free, at once).
function Telemetry.cratePath(path: string, paid: boolean, pass: boolean): string
	if path == "discard" then
		return "Discard"
	elseif path == "unlocker" then
		return if paid then "PaidSmasher" elseif pass then "Pass" else "Smasher"
	elseif path == "unlock" then
		-- Only a pass or a receipt opens a held crate.
		return if pass and not paid then "Pass" else "PaidHeld"
	end
	return "Other"
end

-- Ledger ----------------------------------------------------------------------------

-- Where cash comes from and goes: name (the item SKU) -> transaction type
-- (Enum.AnalyticsEconomyTransactionType names).
Telemetry.SOURCES = {
	Collect = "Gameplay",
	Offline = "TimedReward",
	Free = "TimedReward",
	Daily = "TimedReward",
	Index = "Gameplay",
	ModeParkour = "Gameplay",
	ModeMog = "Gameplay",
	ModeCardio = "Gameplay",
	Mode = "Gameplay",
	Pack = "IAP",
	Tutorial = "Onboarding",
	Other = "Gameplay",
}
Telemetry.SINKS = {
	Units = "Shop",
	Converter = "Shop",
	Treadmill = "Shop",
	Skip = "ContextualPurchase",
	Other = "Shop",
}
-- Names other modules use for the same thing (Tycoon.grantMoney's default source).
local ALIASES: { [string]: string } = { Purchase = "Pack" }
-- The order entries are sent in: sinks, then sources.
local ORDER: { [string]: { string } } = {
	Sink = { "Units", "Converter", "Treadmill", "Skip", "Other" },
	Source = { "Collect", "Offline", "Free", "Daily", "Index", "ModeParkour", "ModeMog", "ModeCardio", "Mode", "Pack", "Tutorial", "Other" },
}

export type Entry = {
	-- An Enum.AnalyticsEconomyFlowType name: "Source" or "Sink".
	flow: string,
	sku: string,
	transaction: string,
	amount: number,
}

export type Ledger = {
	Source: { [string]: number },
	Sink: { [string]: number },
	-- Cash waiting at the Collect pad that was earned while away.
	offline: number,
}

function Telemetry.newLedger(): Ledger
	return { Source = {}, Sink = {}, offline = 0 }
end

-- The source name of a mode's reward.
function Telemetry.modeSource(modeId: any): string
	local name = "Mode" .. Telemetry.word(modeId)
	return if Telemetry.SOURCES[name] then name else "Mode"
end

local function usable(amount: any): boolean
	return type(amount) == "number" and amount > 0 and amount < math.huge
end

local function add(sums: { [string]: number }, known: { [string]: string }, name: any, amount: any)
	if not usable(amount) then
		return
	end
	name = if type(name) == "string" then ALIASES[name] or name else "Other"
	if not known[name] then
		name = "Other"
	end
	sums[name] = (sums[name] or 0) + amount
end

function Telemetry.earn(ledger: Ledger, source: any, amount: any)
	add(ledger.Source, Telemetry.SOURCES, source, amount)
end

function Telemetry.spend(ledger: Ledger, sink: any, amount: any)
	add(ledger.Sink, Telemetry.SINKS, sink, amount)
end

-- Offline earnings land on the Collect pad, not in the wallet: they are counted when
-- collected (Telemetry.collect), as "Offline".
function Telemetry.offline(ledger: Ledger, cash: any)
	if usable(cash) then
		ledger.offline += cash
	end
end

-- Cash collected from the pad: what was earned away first, the rest is "Collect".
function Telemetry.collect(ledger: Ledger, amount: any)
	if not usable(amount) then
		return
	end
	local away = math.min(ledger.offline, amount)
	ledger.offline -= away
	Telemetry.earn(ledger, "Offline", away)
	Telemetry.earn(ledger, "Collect", amount - away)
end

local function take(entries: { Entry }, max: number, flow: string, sums: { [string]: number }, known: { [string]: string })
	for _, name in ORDER[flow] do
		local amount = sums[name]
		if amount and #entries < max then
			sums[name] = nil
			table.insert(entries, { flow = flow, sku = name, transaction = known[name], amount = amount })
		end
	end
end

-- Takes up to `max` sums out of the ledger, one entry per source or sink that moved.
function Telemetry.drain(ledger: Ledger, max: number): { Entry }
	local entries: { Entry } = {}
	take(entries, max, "Sink", ledger.Sink, Telemetry.SINKS)
	take(entries, max, "Source", ledger.Source, Telemetry.SOURCES)
	return entries
end

-- Rate ------------------------------------------------------------------------------

-- One player's calls in the current minute.
export type Window = { start: number, used: number }

Telemetry.WINDOW_SECONDS = 60
-- Calls a player may have made this minute for one more of a kind to go out. "Event" =
-- custom events and the shop funnel (a player can cause these at will), "Economy" = the
-- ledger, which so always has room left. Kinds without a cap always go out; they are rare:
-- "Step" (onboarding steps, a purchase), "Rare" (what the server lets a player do a few
-- times a day at most: an Index claim, the streak saver) and "Final" (the session's end).
Telemetry.CAPS = { Event = 12, Economy = 18 } :: { [string]: number }

function Telemetry.newWindow(now: number): Window
	return { start = now, used = 0 }
end

-- How many more calls of `kind` fit in this player's minute.
function Telemetry.room(window: Window, now: number, kind: string): number
	if now - window.start >= Telemetry.WINDOW_SECONDS then
		window.start = now
		window.used = 0
	end
	local cap = Telemetry.CAPS[kind]
	return if cap then math.max(0, cap - window.used) else math.huge
end

-- Counts one call of `kind`; false when it does not fit and must not be made.
function Telemetry.take(window: Window, now: number, kind: string): boolean
	if Telemetry.room(window, now, kind) < 1 then
		return false
	end
	window.used += 1
	return true
end

return Telemetry
