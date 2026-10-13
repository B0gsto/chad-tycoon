--[[
	Ranking: global leaderboards (OrderedDataStore), falling back to the players in this
	server when DataStores are unavailable.

	- Units: total units obtained (TOP_COUNT entries, also on the plaza boards).
	- Stage: the sky obby's highest global stage reached (profile.parkour.stage), top
	  STAGE_TOP_COUNT, ties broken by total parkour clears. The ordered value packs both:
	  stage * STAGE_PACK + min(clears, STAGE_PACK - 1).

	Query "Ranking" returns { entries = { { rank, userId, name, value } }, updatedAt,
	stage = { { rank, userId, name, stage, clears } }, you = { units = Standing?, stage =
	Standing? }, global }. Both lists are the stored board with this server's live scores
	folded in (Ranking.merge), so a player's own row is never older than the HUD.

	Standing (Ranking.standing) is the asking player's place on a board and the nearest
	players to pass and to stay ahead of: { rank (nil under the listed top), cap, above,
	below, aboveHere, serverRank, serverCount, unranked, count, edge }. `count` is how many
	rows the board has (the window fills a young board with the player's own goal instead of
	made-up names) and `edge` its last listed row once it is full: the score that gets a
	player under it into the top `cap`. `global` is false while the
	lists only hold this server's players (no DataStore, or before the first read).
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
type Standing = {
	rank: number?,
	cap: number,
	above: any?,
	below: any?,
	aboveHere: boolean,
	serverRank: number,
	serverCount: number,
	unranked: boolean,
	count: number,
	edge: any?,
}

local ordered: OrderedDataStore? = nil
local stageOrdered: OrderedDataStore? = nil
local top: { Entry } = {}
local stageTop: { StageEntry } = {}
local updatedAt = 0
-- Whether `top` was read from the store (else it is this server's players).
local global = false
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

-- Every player in this server with a sky obby stage, best first.
local function liveStages(): { StageEntry }
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
	for i, entry in list do
		entry.rank = i
	end
	return list
end

local function localStageFallback(): { StageEntry }
	local list = liveStages()
	while #list > STAGE_TOP_COUNT do
		table.remove(list)
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

local function unitScore(entry: any): number
	return tonumber(entry.value) or 0
end

local function stageScore(entry: any): number
	return packStage(tonumber(entry.stage) or 0, tonumber(entry.clears) or 0)
end

-- The stored board with this server's live rows folded in: a player who is here moves to
-- their current score (the store is up to REFRESH_SECONDS old) and joins the list when the
-- store does not hold them yet. Best first, ranks renumbered; equal scores keep the lower
-- user id first, so the order never flickers. Copies the rows: `stored` is left alone.
local function merge(stored: { any }, live: { any }, scoreOf: (any) -> number): { any }
	local list: { any } = {}
	local here: { [number]: boolean } = {}
	for _, entry in live do
		if not here[entry.userId] then
			here[entry.userId] = true
			table.insert(list, table.clone(entry))
		end
	end
	for _, entry in stored do
		if not here[entry.userId] then
			table.insert(list, table.clone(entry))
		end
	end
	table.sort(list, function(a, b)
		local scoreA, scoreB = scoreOf(a), scoreOf(b)
		if scoreA ~= scoreB then
			return scoreA > scoreB
		end
		return a.userId < b.userId
	end)
	for i, entry in list do
		entry.rank = i
	end
	return list
end

--[[
	A player's place on a merged board, with a target they can reach: `above` is the nearest
	known player ahead (the row to pass) and `below` the nearest behind. `rank` is nil under
	the `cap` rows the store keeps (the rest of the world is not listed there, so the place is
	unknown) and `unranked` marks a player with no row at all (no stage yet): their target
	is then the last row of the board. `here` holds the user ids in this server:
	serverRank / serverCount place the player among them (count 0: not among them).
	`count` is the number of rows on the board and `edge` row `cap` (nil while the board
	has fewer): the one to beat to get into the listed top.
]]
local function standing(list: { any }, userId: number, cap: number, here: { [number]: boolean }): Standing
	local index: number? = nil
	local serverRank, serverCount = 0, 0
	for i, entry in list do
		if here[entry.userId] then
			serverCount += 1
			if not index then
				serverRank += 1
			end
		end
		if entry.userId == userId then
			index = i
		end
	end
	if not index then
		local last = list[#list]
		return {
			rank = nil,
			cap = cap,
			above = last,
			below = nil,
			aboveHere = last ~= nil and here[last.userId] == true,
			serverRank = 0,
			serverCount = serverCount,
			unranked = true,
			count = #list,
			edge = list[cap],
		}
	end
	local above = list[index - 1]
	return {
		rank = if index <= cap then index else nil,
		cap = cap,
		above = above,
		below = list[index + 1],
		aboveHere = above ~= nil and here[above.userId] == true,
		serverRank = serverRank,
		serverCount = serverCount,
		unranked = false,
		count = #list,
		edge = list[cap],
	}
end

local function firstRows(list: { any }, count: number): { any }
	return table.move(list, 1, math.min(count, #list), 1, {})
end

-- What Query "Ranking" answers `userId` with (see the header).
local function answer(userId: number): { [string]: any }
	local live = localFallback()
	local here: { [number]: boolean } = {}
	for _, entry in live do
		here[entry.userId] = true
	end
	local units = merge(top, live, unitScore)
	local stages = merge(stageTop, liveStages(), stageScore)
	return {
		entries = firstRows(units, TOP_COUNT),
		updatedAt = updatedAt,
		stage = firstRows(stages, STAGE_TOP_COUNT),
		you = {
			units = standing(units, userId, TOP_COUNT, here),
			stage = standing(stages, userId, STAGE_TOP_COUNT, here),
		},
		global = global,
	}
end

local function refresh(labels: { TextLabel }, themeModule: any)
	writeScores()
	local stored = readTop()
	global = stored ~= nil
	top = stored or localFallback()
	stageTop = readStageTop() or localStageFallback()
	updatedAt = os.time()
	updateBoards(labels, themeModule)
end

function Ranking.init(themeModule: any, labels: { TextLabel })
	Net.func("Query").OnServerInvoke = function(player, kind)
		if kind == "Ranking" then
			return answer(player.UserId)
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
Ranking.merge = merge
Ranking.standing = standing
Ranking.unitScore = unitScore
Ranking.stageScore = stageScore
Ranking.answer = answer

return Ranking
