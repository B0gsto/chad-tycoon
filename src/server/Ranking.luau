--[[
	Ranking: global leaderboard of total units obtained (OrderedDataStore).
	Falls back to the players in this server when DataStores are unavailable.
]]

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Format = require(ReplicatedStorage.Shared.Format)
local Net = require(ReplicatedStorage.Shared.Net)
local Tycoon = require(script.Parent.Tycoon)

local Ranking = {}

local TOP_COUNT = 50
local REFRESH_SECONDS = 90
local MAX_SCORE = 2 ^ 53

type Entry = { rank: number, userId: number, name: string, value: number }

local ordered: OrderedDataStore? = nil
local top: { Entry } = {}
local updatedAt = 0
local nameCache: { [number]: string } = {}

local ok, err = pcall(function()
	ordered = DataStoreService:GetOrderedDataStore("TotalUnits_v1")
end)
if not ok then
	warn("[Ranking] OrderedDataStore unavailable:", err)
end

local function nameFor(userId: number): string
	if nameCache[userId] then
		return nameCache[userId]
	end
	local player = Players:GetPlayerByUserId(userId)
	if player then
		nameCache[userId] = player.Name
		return player.Name
	end
	local success, name = pcall(Players.GetNameFromUserIdAsync, Players, userId)
	local result = if success and name then name else ("User " .. userId)
	nameCache[userId] = result
	return result
end

local function writeScores()
	if not ordered then
		return
	end
	local store = ordered :: OrderedDataStore
	for player, session in Tycoon.allSessions() do
		local score = math.floor(math.min(session.profile.totalObtained, MAX_SCORE))
		pcall(store.SetAsync, store, tostring(player.UserId), score)
	end
end

local function localFallback(): { Entry }
	local list: { Entry } = {}
	for player, session in Tycoon.allSessions() do
		table.insert(list, { rank = 0, userId = player.UserId, name = player.Name, value = session.profile.totalObtained })
	end
	table.sort(list, function(a, b)
		return a.value > b.value
	end)
	for i, entry in list do
		entry.rank = i
	end
	return list
end

local function readTop(): { Entry }?
	if not ordered then
		return nil
	end
	local store = ordered :: OrderedDataStore
	local success, pages = pcall(store.GetSortedAsync, store, false, TOP_COUNT)
	if not success or not pages then
		return nil
	end
	local list: { Entry } = {}
	for i, item in (pages :: DataStorePages):GetCurrentPage() do
		local userId = tonumber(item.key) or 0
		table.insert(list, { rank = i, userId = userId, name = nameFor(userId), value = item.value })
	end
	return list
end

local function updateBoards(labels: { TextLabel }, themeModule: any)
	local lines = {}
	for i = 1, math.min(10, #top) do
		local entry = top[i]
		local color = if i == 1 then "#FFD23C" elseif i == 2 then "#D8D8E6" elseif i == 3 then "#E08A4A" else "#FFFFFF"
		table.insert(
			lines,
			string.format(
				'<font color="%s">#%d</font>  %s  <font color="#9CF0A0">%s</font>',
				color,
				i,
				entry.name,
				Format.short(entry.value)
			)
		)
	end
	if #lines == 0 then
		table.insert(lines, "Be the first " .. themeModule.Words.Unit .. " collector!")
	end
	local text = table.concat(lines, "\n")
	for _, label in labels do
		label.Text = text
	end
end

local function refresh(labels: { TextLabel }, themeModule: any)
	writeScores()
	top = readTop() or localFallback()
	updatedAt = os.time()
	updateBoards(labels, themeModule)
end

function Ranking.init(themeModule: any, labels: { TextLabel })
	Net.func("Query").OnServerInvoke = function(_player, kind)
		if kind == "Ranking" then
			if #top == 0 then
				top = localFallback()
			end
			return { entries = top, updatedAt = updatedAt }
		end
		return nil
	end

	task.spawn(function()
		task.wait(5)
		while true do
			local success, problem = pcall(refresh, labels, themeModule)
			if not success then
				warn("[Ranking] refresh failed:", problem)
			end
			task.wait(REFRESH_SECONDS)
		end
	end)
end

Ranking.writeScores = writeScores

return Ranking
