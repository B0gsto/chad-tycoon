--[[
	MogBoard: the TOP MOGGERS board of the MOG TEST (Modes.Mog). All-time best PvE scores in
	an OrderedDataStore (key = userId, value = the saved best score, profile.modes.mog.best),
	kept the way Server.Ranking keeps the global boards: every DataStore call is pcall'd and
	made from one slow refresh (REFRESH_SECONDS apart, never from a run), and when DataStores
	are unavailable (Studio, errors) the board is this server's own list. PvP is never on it.

	A board holds two lists of MogRules.BestEntry, highest first, `size` long:
	  server   this server's run scores (in memory, as before): the fallback board
	  global   the all-time list as last read from the store (nil until a read worked), with
	           the bests of the players seen on this server merged in, so a new best shows
	           at once and a write that failed is still on the board here
	Writes are queued (record / seed) and sent by refresh, one SetAsync per changed score and
	only while the request budget has room; a score that could not be written stays queued.
	A saved best only ever goes up, so the stored value does too.

	MogBoard.new(size, store, nameFor, budget) takes the store (MogBoard.open(), or nil), the
	name of a user who is not in this server and a "write" | "read" budget check, so the unit
	tests (tests/mog.luau) run it against a fake store.
]]

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")

local MogRules = require(script.Parent.MogRules)

local MogBoard = {}

MogBoard.STORE = "MogBest_v1"
MogBoard.REFRESH_SECONDS = 90
local MAX_SCORE = 2 ^ 53

export type Entry = MogRules.BestEntry

export type Board = {
	size: number,
	store: any?,
	nameFor: (userId: number) -> string,
	budget: (kind: string) -> boolean,
	server: { Entry },
	global: { Entry }?,
	-- The best of every player seen on this server (by userId), merged into each read.
	known: { [number]: Entry },
	-- Scores waiting for a write, and what the store was last sent, by userId.
	pending: { [number]: number },
	written: { [number]: number },
}

local nameCache: { [number]: string } = {}

-- The store, or nil (with a warning) when DataStores cannot be reached at all.
function MogBoard.open(): OrderedDataStore?
	local store: OrderedDataStore? = nil
	local ok, err = pcall(function()
		store = DataStoreService:GetOrderedDataStore(MogBoard.STORE)
	end)
	if not ok then
		warn("[MogBoard] OrderedDataStore unavailable:", err)
	end
	return store
end

-- Display name of a player in this server, else the user name (looked up once; yields).
function MogBoard.nameFor(userId: number): string
	local player = Players:GetPlayerByUserId(userId)
	if player then
		return player.DisplayName
	end
	if nameCache[userId] then
		return nameCache[userId]
	end
	local success, name = pcall(Players.GetNameFromUserIdAsync, Players, userId)
	local result = if success and name then name else ("User " .. userId)
	nameCache[userId] = result
	return result
end

-- Is there request budget left for a "write" (SetAsync) or a "read" (GetSortedAsync)?
function MogBoard.budget(kind: string): boolean
	local request = if kind == "write" then Enum.DataStoreRequestType.SetIncrementSortedAsync else Enum.DataStoreRequestType.GetSortedAsync
	local ok, left = pcall(DataStoreService.GetRequestBudgetForRequestType, DataStoreService, request)
	return not ok or left > 0
end

function MogBoard.new(size: number, store: any?, nameFor: ((userId: number) -> string)?, budget: ((kind: string) -> boolean)?): Board
	return {
		size = size,
		store = store,
		nameFor = nameFor or MogBoard.nameFor,
		budget = budget or MogBoard.budget,
		server = {},
		global = nil,
		known = {},
		pending = {},
		written = {},
	}
end

-- A saved best as the store keeps it: a whole number, 0 for junk.
local function whole(score: number): number
	if type(score) ~= "number" or score ~= score then
		return 0
	end
	return math.floor(math.clamp(score, 0, MAX_SCORE))
end

-- Notes a player's all-time best: queued for the store when it beats what was sent, and put
-- on the all-time list if there is one. Returns their rank on that list, or nil.
function MogBoard.seed(board: Board, userId: number, name: string, best: number, rivals: number): number?
	local score = whole(best)
	if score <= 0 then
		return nil
	end
	local known = board.known[userId]
	if not known or known.score < score then
		board.known[userId] = { userId = userId, name = name, score = score, rivals = rivals }
	end
	if board.store and score > (board.written[userId] or 0) then
		board.pending[userId] = math.max(board.pending[userId] or 0, score)
	end
	local global = board.global
	if not global then
		return nil
	end
	return MogRules.recordBest(global, userId, name, score, rivals, board.size)
end

-- A finished PvE run: its `score` goes on this server's list and the player's all-time
-- `best` on the all-time list. Returns the rank on each (nil = not on it, or no such list).
function MogBoard.record(board: Board, userId: number, name: string, score: number, rivals: number, best: number): (number?, number?)
	local serverRank = nil
	if score > 0 then
		serverRank = MogRules.recordBest(board.server, userId, name, score, rivals, board.size)
	end
	return serverRank, MogBoard.seed(board, userId, name, best, rivals)
end

-- Sends the queued scores, one SetAsync each, while the budget lasts. What fails stays queued.
function MogBoard.write(board: Board)
	local store = board.store
	if not store then
		return
	end
	-- SetAsync yields and a run may queue more meanwhile: send a copy of the queue.
	for userId, score in table.clone(board.pending) do
		if not board.budget("write") then
			return
		end
		if pcall(store.SetAsync, store, tostring(userId), score) then
			board.written[userId] = math.max(board.written[userId] or 0, score)
			if board.pending[userId] == score then
				board.pending[userId] = nil
			end
		end
	end
end

-- Reads the all-time list (yields). False, with the last list kept, when the store cannot be
-- read; the bests known on this server are merged in either way.
function MogBoard.read(board: Board): boolean
	local store = board.store
	local list: { Entry }? = nil
	if store and board.budget("read") then
		local success, pages = pcall(store.GetSortedAsync, store, false, board.size)
		if success and pages then
			local read: { Entry } = {}
			for _, item in (pages :: any):GetCurrentPage() do
				local userId = tonumber(item.key) or 0
				local score = whole(item.value)
				if score > 0 then
					-- A player seen on this server keeps the name they were seen with.
					local known = board.known[userId]
					local name = if known then known.name else board.nameFor(userId)
					table.insert(read, { userId = userId, name = name, score = score, rivals = 0 })
				end
			end
			list = read
		end
	end
	local global = list or board.global
	if global then
		for userId, entry in board.known do
			MogRules.recordBest(global, userId, entry.name, entry.score, entry.rivals, board.size)
		end
	end
	board.global = global
	return list ~= nil
end

-- One round of the slow loop: note the bests of the players in this server (`live`, as
-- entries), send what is queued, then read the list back.
function MogBoard.refresh(board: Board, live: { Entry })
	for _, entry in live do
		MogBoard.seed(board, entry.userId, entry.name, entry.score, entry.rivals)
	end
	MogBoard.write(board)
	MogBoard.read(board)
end

-- The list to show and whether it is the all-time one (false: this server's scores).
function MogBoard.entries(board: Board): ({ Entry }, boolean)
	local global = board.global
	if global then
		return global, true
	end
	return board.server, false
end

return MogBoard
