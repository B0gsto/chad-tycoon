--[[
	Daily: server side of the daily reward (rules: Shared.DailyReward; client:
	Client.UI.DailyWindow and the HUD's Daily button).

	The saved profile field `daily` holds the UTC day of the last claim and the
	streak at that claim. The State snapshot's `daily` field tells the client
	what today looks like: { claimable, day (today's card 1..7), claimed (cards
	ticked), streak, nextIn (seconds to the next UTC day) }. The "ClaimDaily"
	action pays today's card: cash sized by the player's income right now (the
	amounts the window shows) and, on days 3 and 7, a crate opened on the spot.

	Notify payloads (client shows them):
	  { kind = "Daily", event = "claimed", day = n, cash = c, crate = rarity?, streak = s }

	First day: once a player has finished the tutorial, has claimed and has been
	playing for a few minutes, one toast names tomorrow's reward.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local DailyReward = require(Shared.DailyReward)
local Economy = require(Shared.Economy)
local Format = require(Shared.Format)

local Tycoon = require(script.Parent.Tycoon)

local Daily = {}

local CHECK_SECONDS = 5
-- The first-day toast waits for this much play time, and this long after the claim.
local HINT_AFTER_JOIN = 180
local HINT_AFTER_CLAIM = 30

local theme: any
-- os.clock() of the session's start and of its claim (sessions are weak keys).
local startedAt: { [any]: number } = setmetatable({}, { __mode = "k" }) :: any
local claimedAt: { [any]: number } = setmetatable({}, { __mode = "k" }) :: any

local function today(): number
	return DailyReward.dayNumber(os.time())
end

-- Cash of card `day` for this player right now (the same formula the window shows).
local function cashFor(session: Tycoon.Session, day: number): number
	local p = session.profile
	local progression = Economy.progression(Economy.highestTier(p.discovered), p.processLevel)
	return DailyReward.cash(day, Tycoon.income(session), progression)
end

local function snapshot(session: Tycoon.Session): { [string]: any }
	local d = session.profile.daily
	local now = os.time()
	local status = DailyReward.status(d.day, d.streak, DailyReward.dayNumber(now))
	return {
		claimable = status.claimable,
		day = status.day,
		claimed = status.claimed,
		streak = status.streak,
		nextIn = DailyReward.secondsLeft(now),
	}
end

function Daily.claim(session: Tycoon.Session)
	if not session.alive then
		return
	end
	local d = session.profile.daily
	local streak, day = DailyReward.claim(d.day, d.streak, today())
	if not streak or not day then
		Tycoon.toast(session, "Next daily reward in " .. Format.time(DailyReward.secondsLeft(os.time())), "info")
		return
	end
	-- Sized before anything is granted, so the crate's unit does not change the cash.
	local cash = cashFor(session, day)
	local crate = DailyReward.REWARDS[day].crate
	d.day = today()
	d.streak = streak
	claimedAt[session] = os.clock()
	Tycoon.notify(session, { kind = "Daily", event = "claimed", day = day, cash = cash, crate = crate, streak = streak })
	Tycoon.grantMoney(session, cash, "Daily")
	if crate then
		Tycoon.grantCrate(session, crate)
	end
end

-- The first-day "come back tomorrow" toast (once per player, saved).
local function hint(session: Tycoon.Session, now: number)
	local p = session.profile
	local d = p.daily
	if d.hinted or not p.tutorialDone or d.firstDay ~= now or d.day ~= now then
		return
	end
	local clock = os.clock()
	if clock - (startedAt[session] or clock) < HINT_AFTER_JOIN or clock - (claimedAt[session] or 0) < HINT_AFTER_CLAIM then
		return
	end
	d.hinted = true
	local nextDay = DailyReward.card(d.streak + 1)
	local reward = DailyReward.describe(nextDay, Format.money(cashFor(session, nextDay)), theme.Words.Chest)
	Tycoon.toast(session, string.format("Come back tomorrow for Day %d: %s", nextDay, reward), "good")
	Tycoon.markDirty(session)
end

-- Call right after Tycoon.addPlayer: starts the play-time clock and stamps the first day.
function Daily.onSessionStart(session: Tycoon.Session)
	startedAt[session] = os.clock()
	local d = session.profile.daily
	if d.firstDay == 0 then
		d.firstDay = today()
		Tycoon.markDirty(session)
	end
end

function Daily.init(themeModule: any)
	theme = themeModule
	Tycoon.hooks.daily = snapshot
	Tycoon.addAction("ClaimDaily", function(session)
		Daily.claim(session)
	end)

	task.spawn(function()
		local lastDay = today()
		while true do
			task.wait(CHECK_SECONDS)
			local now = today()
			for _, session in Tycoon.allSessions() do
				if session.alive then
					if now ~= lastDay then
						-- A new UTC day: the snapshot's `claimable` changes for everyone online.
						Tycoon.markDirty(session)
					end
					hint(session, now)
				end
			end
			lastDay = now
		end
	end)
end

return Daily
