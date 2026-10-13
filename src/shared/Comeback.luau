--!strict
--[[
	Comeback: what a returning player is told and what a leaving one can read (pure
	rules, no Roblox dependencies, unit-tested with Lune; Client.UI.AwayWindow shows
	the first, the Daily window's footer the second).

	"While you were away" (Comeback.away): one row per thing that is true right now, in
	this order: the cash the units earned while away (the Offline notify of
	Server.Tycoon) with its cap, the crate the Smasher has finished (or the one still in
	it), today's daily card, the streak (kept, saved by the streak saver, or ended) and
	the free gift. Nothing to say = no rows = no card.

	"Before you go" (Comeback.leave): the crate timer, how long away cash keeps filling
	and the next daily card, as plain facts. Times are rounded to the minute on purpose:
	a line to read, not a countdown.

	Both read the State snapshot only (unlockers, daily, freeIn, passes and the income
	fields), so they never promise what the server does not know.
]]

local DailyReward = require(script.Parent.DailyReward)
local Economy = require(script.Parent.Economy)

local Comeback = {}

export type Words = { Units: string, Chest: string }

export type Options = {
	-- Formats cash ("$12.4K"; the client's honours the full-numbers setting).
	money: (number) -> string,
	words: Words,
	-- Seconds since the snapshot arrived (its timers have run that long).
	age: number?,
}

export type Row = {
	-- "cash" | "crate" | "daily" | "streak" | "free"
	kind: string,
	title: string,
	detail: string,
	-- Cash row: the amount (shown big). Crate row: its rarity (the art).
	cash: number?,
	rarity: string?,
}

-- A relaxed duration, to the minute: 45 -> "1 min", 754 -> "13 min", 11520 -> "3h 12m",
-- 28800 -> "8h". Rounded up (a timer never promises less than is left); `down` rounds
-- down instead, for time that has passed.
function Comeback.span(seconds: number, down: boolean?): string
	local exact = math.max(0, seconds) / 60
	local minutes = math.max(1, if down then math.floor(exact) else math.ceil(exact))
	if minutes < 60 then
		return minutes .. " min"
	end
	local hours, rest = minutes // 60, minutes % 60
	return if rest == 0 then hours .. "h" else string.format("%dh %dm", hours, rest)
end

type Crates = {
	-- Rarities of the crates that can be opened now.
	ready: { string },
	-- The crate that finishes first, and the seconds it still needs.
	nextRarity: string?,
	nextIn: number,
}

-- The Smasher slots of the snapshot, `age` seconds after it arrived. With the Crate Key
-- pass a crate opens at once, timer or not.
local function crates(data: { [string]: any }, age: number): Crates
	local found: Crates = { ready = {}, nextRarity = nil, nextIn = math.huge }
	local slots = data.unlockers
	if type(slots) ~= "table" then
		return found
	end
	local keyed = type(data.passes) == "table" and data.passes.CrateKey == true
	for _, slot in slots do
		if type(slot) == "table" and type(slot.rarity) == "string" and slot.rarity ~= "" then
			local left = (tonumber(slot.secondsLeft) or 0) - age
			if left <= 0 or keyed then
				table.insert(found.ready, slot.rarity)
			elseif left < found.nextIn then
				found.nextRarity, found.nextIn = slot.rarity, left
			end
		end
	end
	return found
end

local function dailyOf(data: { [string]: any }): { [string]: any }?
	local daily = data.daily
	return if type(daily) == "table" then daily else nil
end

-- Seconds until the next daily card, `age` seconds after the snapshot arrived.
local function nextDaily(daily: { [string]: any }, age: number): number
	return math.max(0, (tonumber(daily.nextIn) or 0) - age)
end

-- What today's card pays this player right now (the amounts the Daily window shows).
local function dailyReward(data: { [string]: any }, daily: { [string]: any }, options: Options): (number, string)
	local day = math.clamp(math.floor(tonumber(daily.day) or 1), 1, DailyReward.DAYS)
	local progression = Economy.progression(tonumber(data.highestTier) or 1, tonumber(data.processLevel) or 0)
	local income = tonumber(data.rewardIncome) or tonumber(data.income) or 0
	local cap = if daily.firstDay == true then DailyReward.firstDayCap(day, tonumber(data.bought) or 0) else nil
	local cash = options.money(DailyReward.cash(day, income, progression, cap))
	return day, DailyReward.describe(day, cash, options.words.Chest)
end

-- "3 day streak" / "1 day streak".
local function streakText(streak: number): string
	return string.format("%d day streak", streak)
end

--[[
	The rows of the "While you were away" card. `offline` = the Offline notify
	({ seconds, cash }: `seconds` is already capped at Economy.OFFLINE_CAP_SECONDS), or nil
	when there is none. `offline.crates` (rarities of the crates that finished during the
	absence) is optional: without it a finished crate is "ready", which is true whenever
	it finished.
]]
function Comeback.away(data: { [string]: any }, offline: { [string]: any }?, options: Options): { Row }
	local rows: { Row } = {}
	local age = options.age or 0
	local words = options.words
	local cap = Economy.OFFLINE_CAP_SECONDS

	local cash = if offline then tonumber(offline.cash) or 0 else 0
	if offline and cash >= 1 then
		local seconds = tonumber(offline.seconds) or 0
		table.insert(rows, {
			kind = "cash",
			title = string.format("Your %s kept earning", words.Units),
			detail = if seconds >= cap
				then string.format("Away cash was full: it fills up in %s.", Comeback.span(cap))
				else string.format("%s away. Away cash fills up in %s.", Comeback.span(seconds, true), Comeback.span(cap)),
			cash = cash,
		})
	end

	local smasher = crates(data, age)
	if #smasher.ready > 0 then
		local finished = offline ~= nil and type(offline.crates) == "table" and #offline.crates > 0
		local what = if #smasher.ready == 1
			then smasher.ready[1] .. " " .. words.Chest
			else string.format("%d %ss", #smasher.ready, words.Chest)
		table.insert(rows, {
			kind = "crate",
			title = what .. (if finished then " finished" else " ready"),
			detail = (if #smasher.ready == 1 then "Open it" else "Open them") .. " at the Smasher.",
			rarity = smasher.ready[1],
		})
	elseif smasher.nextRarity then
		table.insert(rows, {
			kind = "crate",
			title = string.format("%s %s: %s to go", smasher.nextRarity, words.Chest, Comeback.span(smasher.nextIn)),
			detail = "Still in the Smasher.",
			rarity = smasher.nextRarity,
		})
	end

	local daily = dailyOf(data)
	if daily then
		local streak = math.max(0, math.floor(tonumber(daily.streak) or 0))
		local lapsed = math.max(0, math.floor(tonumber(daily.lapsed) or 0))
		if daily.claimable == true then
			local day, reward = dailyReward(data, daily, options)
			table.insert(rows, {
				kind = "daily",
				title = "Daily reward ready",
				detail = string.format("Day %d: %s", day, reward),
			})
			if daily.saves == true then
				table.insert(rows, {
					kind = "streak",
					title = "Streak saved",
					detail = string.format("You missed a day, but your %s goes on.", streakText(streak)),
				})
			elseif streak >= 1 then
				table.insert(rows, {
					kind = "streak",
					title = streakText(streak),
					detail = string.format("Today's reward makes it %d.", streak + 1),
				})
			elseif lapsed >= 2 then
				table.insert(rows, {
					kind = "streak",
					title = "New streak",
					detail = string.format("Your %s ended. A new one starts today.", streakText(lapsed)),
				})
			end
		elseif streak >= 1 then
			table.insert(rows, {
				kind = "streak",
				title = streakText(streak),
				detail = string.format("Today's reward is claimed. Next one in %s.", Comeback.span(nextDaily(daily, age))),
			})
		end
	end

	if data.freeIn ~= nil and (tonumber(data.freeIn) or 0) - age <= 0 then
		table.insert(rows, { kind = "free", title = "Free gift ready", detail = "It is waiting for you." })
	end
	return rows
end

-- Where the away cash is: on the Collect pad, or (Auto Cash) already in the wallet.
function Comeback.cashNote(data: { [string]: any }): string
	local auto = type(data.passes) == "table" and data.passes.AutoCash == true
	return if auto then "Auto Cash put it in your wallet." else "Your cash is waiting on the Collect pad."
end

--[[
	The "Before you go" facts, most useful first: the crate in the Smasher, how long away
	cash keeps filling (only for a player whose units earn something) and the daily card.
	`withDaily = false` leaves the daily card out (the Daily window says it itself).
]]
function Comeback.leave(data: { [string]: any }, options: Options, withDaily: boolean?): { string }
	local parts: { string } = {}
	local age = options.age or 0
	local words = options.words

	local smasher = crates(data, age)
	if #smasher.ready > 0 then
		table.insert(parts, string.format("%s %s ready to open", smasher.ready[1], words.Chest))
	elseif smasher.nextRarity then
		table.insert(parts, string.format("%s %s ready in %s", smasher.nextRarity, words.Chest, Comeback.span(smasher.nextIn)))
	end

	if (tonumber(data.rewardProduction) or tonumber(data.production) or 0) > 0 then
		table.insert(parts, string.format("away cash fills up in %s", Comeback.span(Economy.OFFLINE_CAP_SECONDS)))
	end

	local daily = dailyOf(data)
	if daily and withDaily ~= false then
		if daily.claimable == true then
			table.insert(parts, "daily reward ready")
		else
			table.insert(parts, string.format("next daily reward in %s", Comeback.span(nextDaily(daily, age))))
		end
	end
	return parts
end

-- The facts as one line ("Before you go: Rare Crate ready in 12 min  |  ..."), "" when
-- there is nothing to say.
function Comeback.leaveLine(data: { [string]: any }, options: Options, withDaily: boolean?): string
	local parts = Comeback.leave(data, options, withDaily)
	if #parts == 0 then
		return ""
	end
	return "Before you go: " .. table.concat(parts, "  |  ")
end

return Comeback
