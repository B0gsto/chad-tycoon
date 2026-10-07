--[[
	Badges: awards the Roblox badges listed in Theme.Badges (ids from the universe,
	created with tools/badges.py). A badge with Id 0 is skipped.

	Each badge is awarded once: profile.badges[key] is set when BadgeService confirms it,
	and a failed award is retried on the next check (every CHECK_SECONDS, plus right after
	the tutorial finishes). Conditions read only the saved profile:
	  Welcome        joined the game
	  GymGraduate    finished the tutorial (Badges.graduate, not on a skip)
	  CertifiedChad  discovered tier 10
	  AbsoluteChad   discovered the top tier
	  ParkourMaster  cleared the last parkour level
]]

local BadgeService = game:GetService("BadgeService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Economy = require(ReplicatedStorage.Shared.Economy)

local Tycoon = require(script.Parent.Tycoon)

local Badges = {}

local CHECK_SECONDS = 5

local theme: any
-- Awards in flight per session, so a slow AwardBadgeAsync is never sent twice.
local busy: { [any]: { [string]: boolean } } = setmetatable({}, { __mode = "k" }) :: any

local conditions: { [string]: (profile: any) -> boolean } = {
	Welcome = function()
		return true
	end,
	GymGraduate = function(p)
		return p.badges.GymGraduate == false
	end,
	CertifiedChad = function(p)
		return Economy.highestTier(p.discovered) >= 10
	end,
	AbsoluteChad = function(p)
		return Economy.highestTier(p.discovered) >= Economy.MAX_TIER
	end,
	ParkourMaster = function(p)
		return (p.parkour.clears[#p.parkour.clears] or 0) > 0
	end,
}

-- Awards one badge if its condition holds. profile.badges[key]: true = awarded,
-- false = earned but not yet confirmed by BadgeService (retried), nil = not earned.
local function check(session: Tycoon.Session, key: string)
	local badge = theme.Badges[key]
	local p = session.profile
	if not badge or badge.Id == 0 or p.badges[key] == true or not conditions[key](p) then
		return
	end
	local inFlight = busy[session] or {}
	busy[session] = inFlight
	if inFlight[key] then
		return
	end
	inFlight[key] = true
	local ok, result = pcall(BadgeService.AwardBadgeAsync, BadgeService, session.player.UserId, badge.Id)
	inFlight[key] = nil
	if not session.alive then
		return
	end
	if ok and result then
		p.badges[key] = true
		Tycoon.markDirty(session)
	elseif not ok then
		warn("[Badges]", key, result)
	end
end

local function checkAll(session: Tycoon.Session)
	for key in theme.Badges do
		if session.alive then
			check(session, key)
		end
	end
end

-- The tutorial was finished (not skipped).
function Badges.graduate(session: Tycoon.Session)
	if session.profile.badges.GymGraduate == nil then
		session.profile.badges.GymGraduate = false
	end
	task.spawn(check, session, "GymGraduate")
end

function Badges.onSessionStart(session: Tycoon.Session)
	task.spawn(checkAll, session)
end

function Badges.init(themeModule: any)
	theme = themeModule
	task.spawn(function()
		while true do
			task.wait(CHECK_SECONDS)
			for _, session in Tycoon.allSessions() do
				task.spawn(checkAll, session)
			end
		end
	end)
end

return Badges
