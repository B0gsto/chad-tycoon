--!strict
--[[
	DailyReward: pure rules of the 7-day daily reward (no Roblox dependencies,
	unit-tested with Lune; Server.Daily applies them, the Daily window shows them).

	One claim per UTC day. Claiming on the day after the last claim continues the
	streak. One missed day is forgiven: the streak goes on as if it had not been
	missed, once per run of seven cards (the streak saver, free and automatic;
	nothing repairs a streak for Robux). A second miss in the same run, or a
	longer break, starts again at day 1. After day 7 the cards loop while the
	streak keeps counting. Every day pays cash sized like a shop cash pack
	(Economy.moneyPackAmount: seconds of the player's income, never below the
	day's minimum), so a reward matters at every stage. Days 3 and 7 also open a
	crate on the spot.

	A player's first day is the exception: minutes of income would jump a brand-new
	player over the tuned first tiers, so that day pays no more than the next
	FIRST_DAY_UNITS units cost (firstDayCap).
]]

local Economy = require(script.Parent.Economy)

local DailyReward = {}

DailyReward.DAY_SECONDS = 86400

-- `seconds` of income, at least `min` cash; `crate` = rarity of the crate opened with it.
export type Reward = { seconds: number, min: number, crate: string? }

DailyReward.REWARDS = {
	{ seconds = 5 * 60, min = 250 },
	{ seconds = 10 * 60, min = 500 },
	{ seconds = 15 * 60, min = 1000, crate = "Rare" },
	{ seconds = 20 * 60, min = 2000 },
	{ seconds = 30 * 60, min = 4000 },
	{ seconds = 45 * 60, min = 8000 },
	{ seconds = 60 * 60, min = 15000, crate = "Legendary" },
} :: { Reward }

DailyReward.DAYS = #DailyReward.REWARDS

-- UTC day number of a unix time (days since 1970-01-01).
function DailyReward.dayNumber(now: number): number
	return math.floor(now / DailyReward.DAY_SECONDS)
end

-- Seconds until the next UTC day starts (1..DAY_SECONDS).
function DailyReward.secondsLeft(now: number): number
	return DailyReward.DAY_SECONDS - math.floor(now) % DailyReward.DAY_SECONDS
end

-- The card (1..DAYS) a streak of `streak` claims ends on.
function DailyReward.card(streak: number): number
	return (math.max(streak, 1) - 1) % DailyReward.DAYS + 1
end

-- The run of seven cards (0 = the first week) that claim number `streak` belongs to.
local function run(streak: number): number
	return (math.max(streak, 1) - 1) // DailyReward.DAYS
end

-- The streak saver: `saverUsedAt` is the streak value of the claim that last used it (0 =
-- never in this streak). True when the claim after a streak of `streak` may use it: it was
-- not used in that claim's run of seven. A value ahead of the streak (a broken save) reads
-- as never used.
function DailyReward.saverReady(streak: number, saverUsedAt: number?): boolean
	local usedAt = saverUsedAt or 0
	if usedAt < 1 or usedAt > streak then
		return true
	end
	return run(usedAt) ~= run(streak + 1)
end

-- The card (1..DAYS) wearing the saver's shield in the run of seven that a streak of
-- `streak` claims is on, 0 when the saver was not used in that run.
local function savedCard(streak: number, usedAt: number): number
	if usedAt < 1 or usedAt > streak or run(usedAt) ~= run(streak) then
		return 0
	end
	return DailyReward.card(usedAt)
end

export type Status = {
	-- A reward can be claimed today.
	claimable: boolean,
	-- Today's card: the one to claim now, or the one already claimed today.
	day: number,
	-- Cards ticked in the current run of seven (0..DAYS).
	claimed: number,
	-- Days claimed in a row so far (0 after a streak was lost).
	streak: number,
	-- Today's claim uses the streak saver: one day was missed and the streak goes on.
	saves: boolean,
	-- The card of this run of seven that used the saver (today's when `saves`), 0 = none.
	savedCard: number,
	-- The saver is still there for the next missed day (once today's card is claimed).
	saver: boolean,
}

-- `lastDay` = day number of the last claim (0 = never), `streak` = days in a row at that
-- claim, `today` = today's day number, `saverUsedAt` = streak value of the claim that used
-- the streak saver (0 or nil = not used). A last claim "in the future" (a server clock
-- ahead of this one) counts as claimed today, so a reward is never paid twice for one day.
function DailyReward.status(lastDay: number, streak: number, today: number, saverUsedAt: number?): Status
	local usedAt = saverUsedAt or 0
	if lastDay >= today and streak >= 1 then
		local day = DailyReward.card(streak)
		return {
			claimable = false,
			day = day,
			claimed = day,
			streak = streak,
			saves = false,
			savedCard = savedCard(streak, usedAt),
			saver = DailyReward.saverReady(streak, usedAt),
		}
	end
	-- The day after the last claim, or the day after that with the saver still unused.
	local missed = lastDay == today - 2
	if streak >= 1 and (lastDay == today - 1 or (missed and DailyReward.saverReady(streak, usedAt))) then
		local day = DailyReward.card(streak + 1)
		local after = if missed then streak + 1 else usedAt
		return {
			claimable = true,
			day = day,
			claimed = day - 1,
			streak = streak,
			saves = missed,
			savedCard = savedCard(streak + 1, after),
			saver = DailyReward.saverReady(streak + 1, after),
		}
	end
	return { claimable = true, day = 1, claimed = 0, streak = 0, saves = false, savedCard = 0, saver = true }
end

-- Claims today's reward: returns the new streak, the card it pays, the `saverUsedAt` to
-- save with it (the new streak when this claim used the saver, 0 when the streak started
-- again) and whether the saver was used; nil when today's reward was already claimed.
function DailyReward.claim(lastDay: number, streak: number, today: number, saverUsedAt: number?): (number?, number?, number?, boolean?)
	local status = DailyReward.status(lastDay, streak, today, saverUsedAt)
	if not status.claimable then
		return nil, nil, nil, nil
	end
	local newStreak = status.streak + 1
	local usedAt = saverUsedAt or 0
	if status.saves then
		usedAt = newStreak
	elseif status.streak == 0 or usedAt > status.streak then
		-- A new streak starts with its saver unused.
		usedAt = 0
	end
	return newStreak, status.day, usedAt, status.saves
end

-- Units whose price is the most a player's first day pays.
DailyReward.FIRST_DAY_UNITS = 4

-- The most card `day` pays on a player's first day: what their next FIRST_DAY_UNITS units
-- cost (a few hundred cash in the first minutes), never below the day's minimum. A boost,
-- not a tier skip.
function DailyReward.firstDayCap(day: number, bought: number): number
	local reward = DailyReward.REWARDS[DailyReward.card(day)]
	return math.max(reward.min, math.floor(Economy.bulkPrice(bought, DailyReward.FIRST_DAY_UNITS)))
end

-- Cash of card `day` for a player earning `income` cash/s at `progression`, at most `cap`
-- (firstDayCap on a player's first day, nil after it).
function DailyReward.cash(day: number, income: number, progression: Economy.Progression, cap: number?): number
	local reward = DailyReward.REWARDS[DailyReward.card(day)]
	local amount = Economy.moneyPackAmount(income, reward.seconds, reward.min, progression)
	return if cap then math.min(amount, cap) else amount
end

-- What card `day` pays on top of its cash when the rack has no room for the crate's unit:
-- the cash that unit is worth on average (0 on a day without a crate), so the crate is
-- never lost.
function DailyReward.crateCash(day: number, highestTier: number): number
	local crate = DailyReward.REWARDS[DailyReward.card(day)].crate
	return if crate then math.floor(Economy.chestExpectedValue(crate, highestTier)) else 0
end

-- One line naming card `day`'s reward: "$1.20K" or "Rare Crate + $1.20K" (`cashText` is the
-- formatted cash, `chestWord` the theme's word for a crate).
function DailyReward.describe(day: number, cashText: string, chestWord: string): string
	local reward = DailyReward.REWARDS[DailyReward.card(day)]
	if reward.crate then
		return string.format("%s %s + %s", reward.crate, chestWord, cashText)
	end
	return cashText
end

-- Opening by itself (Client.UI.DailyWindow) ------------------------------------------

-- The Daily window opens by itself after some calm seconds. A held crate (its panel is up)
-- is not calm, so the window waits for it to be dealt with; but a crate can be carried for
-- minutes, so once the crate alone has kept the window back for CRATE_PATIENCE seconds it
-- stops counting.
DailyReward.CRATE_PATIENCE = 10

-- Seconds of calm so far, and seconds spent waiting for nothing but the held crate.
export type AutoOpen = { calm: number, crate: number }

function DailyReward.autoOpen(): AutoOpen
	return { calm = 0, crate = 0 }
end

-- One tick of `step` seconds; true when the window should open now. `blocked` = something
-- the window must never cover (the intro, the tutorial, a window, a popup, a mode run):
-- the calm starts over. `crate` = the held-crate panel is up. `needed` = calm seconds asked.
function DailyReward.autoOpenTick(state: AutoOpen, step: number, blocked: boolean, crate: boolean, needed: number): boolean
	if blocked then
		state.calm = 0
		return false
	end
	if crate and state.crate < DailyReward.CRATE_PATIENCE then
		state.crate += step
		state.calm = 0
		return false
	end
	state.calm += step
	return state.calm >= needed
end

return DailyReward
