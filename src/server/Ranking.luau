--[[
	Ranking: global leaderboards (OrderedDataStore), falling back to the players in this
	server when DataStores are unavailable.

	- Units: total units obtained (TOP_COUNT entries, also on the plaza boards).
	- Stage: the sky obby's highest global stage reached (profile.parkour.stage), top
	  STAGE_TOP_COUNT, ties broken by total parkour clears. The ordered value packs both:
	  stage * STAGE_PACK + min(clears, STAGE_PACK - 1).

	Query "Ranking" returns { entries = { { rank, userId, name, value } }, updatedAt,
	stage = { { rank, userId, name, stage, clears } } }.
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

local STAGE_TOP_COUNT = 10
local STAGE_PACK = 10000

type Entry = { rank: number, userId: number, name: string, value: number }
type StageEntry = { rank: number, userId: number, name: string, stage: number, clears: number }

local ordered: OrderedDataStore? = nil
local stageOrdered: OrderedDataStore? = nil
local top: { Entry } = {}
local stageTop: { StageEntry } = {}
local updatedAt = 0
local nameCache: { [number]: string } = {}

local ok, err = pcall(function()
	ordered = DataStoreService:GetOrderedDataStore("TotalUnits_v1")
	stageOrdered = DataStoreService:GetOrderedDataStore("ObbyStage_v1")
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

-- (stage, clears) of a profile's sky obby record.
local function stageOf(profile: any): (number, number)
	local rec = profile.parkour
	if type(rec) ~= "table" then
		return 0, 0
	end
	local clears = 0
	if type(rec.clears) == "table" then
		for _, n in rec.clears do
			clears += n
		end
	end
	return if type(rec.stage) == "number" then rec.stage else 0, clears
end

local function packStage(stage: number, clears: number): number
	return math.floor(stage) * STAGE_PACK + math.min(math.floor(clears), STAGE_PACK - 1)
end

local function unpackStage(value: number): (number, number)
	return value // STAGE_PACK, value % STAGE_PACK
end

local function writeScores()
	if ordered then
		local store = ordered :: OrderedDataStore
		for player, session in Tycoon.allSessions() do
			local score = math.floor(math.min(session.profile.totalObtained, MAX_SCORE))
			pcall(store.SetAsync, store, tostring(player.UserId), score)
		end
	end
	if stageOrdered then
		local store = stageOrdered :: OrderedDataStore
		for player, session in Tycoon.allSessions() do
			local stage, clears = stageOf(session.profile)
			if stage > 0 then
				pcall(store.SetAsync, store, tostring(player.UserId), packStage(stage, clears))
			end
		end
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

local function localStageFallback(): { StageEntry }
	local list: { StageEntry } = {}
	for player, session in Tycoon.allSessions() do
		local stage, clears = stageOf(session.profile)
		if stage > 0 then
			table.insert(list, { rank = 0, userId = player.UserId, name = player.Name, stage = stage, clears = clears })
		end
	end
	table.sort(list, function(a, b)
		if a.stage ~= b.stage then
			return a.stage > b.stage
		end
		return a.clears > b.clears
	end)
	while #list > STAGE_TOP_COUNT do
		table.remove(list)
	end
	for i, entry in list do
		entry.rank = i
	end
	return list
end

local function readStageTop(): { StageEntry }?
	if not stageOrdered then
		return nil
	end
	local store = stageOrdered :: OrderedDataStore
	local success, pages = pcall(store.GetSortedAsync, store, false, STAGE_TOP_COUNT)
	if not success or not pages then
		return nil
	end
	local list: { StageEntry } = {}
	for i, item in (pages :: DataStorePages):GetCurrentPage() do
		local userId = tonumber(item.key) or 0
		local stage, clears = unpackStage(item.value)
		table.insert(list, { rank = i, userId = userId, name = nameFor(userId), stage = stage, clears = clears })
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
	stageTop = readStageTop() or localStageFallback()
	updatedAt = os.time()
	updateBoards(labels, themeModule)
end

function Ranking.init(themeModule: any, labels: { TextLabel })
	Net.func("Query").OnServerInvoke = function(_player, kind)
		if kind == "Ranking" then
			if #top == 0 then
				top = localFallback()
			end
			if #stageTop == 0 then
				stageTop = localStageFallback()
			end
			return { entries = top, updatedAt = updatedAt, stage = stageTop }
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
-- Exposed for the unit tests.
Ranking.packStage = packStage
Ranking.unpackStage = unpackStage
Ranking.stageOf = stageOf

return Ranking
