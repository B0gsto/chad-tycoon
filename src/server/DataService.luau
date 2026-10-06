--[[
	DataService: loads and saves player profiles in a DataStore.

	- Retries with backoff on load/save.
	- If a profile cannot be loaded on a live server the player is kicked
	  instead of being given a blank profile that would overwrite their save.
	- In Studio without API access it falls back to an in-memory profile and
	  never saves, so the game is still playable for testing.
]]

local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")
local RunService = game:GetService("RunService")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Economy = require(ReplicatedStorage.Shared.Economy)
local SessionLock = require(ReplicatedStorage.Shared.SessionLock)
local TutorialSteps = require(ReplicatedStorage.Shared.TutorialSteps)

local DataService = {}

local STORE_NAME = "TycoonProfiles_v1"
local MAX_RETRIES = 4

export type Unlocker = { rarity: string, endsAt: number }

export type Profile = {
	version: number,
	money: number,
	gems: number,
	carried: number,
	queue: number,
	pending: number,
	units: { number },
	discovered: { number },
	totalObtained: number,
	buyTier: number,
	boughtAtTier: number,
	processLevel: number,
	heldChest: string,
	-- Rarity of the crate the player was last prompted to open with Robux ("" = none);
	-- the receipt opens this one if the crate is no longer held.
	pendingCrate: string,
	unlockers: { Unlocker },
	autoMergeOwned: boolean,
	autoMerge: boolean,
	lastOnline: number,
	lastFreeReward: number,
	settings: { music: boolean, sfx: boolean, fullNumbers: boolean },
	receipts: { string },
	totalEarned: number,
	tutorialStep: number,
	tutorialDone: boolean,
	introSeen: boolean,
	-- Equipped trail ("" = none) and on/off switches of the toggle cosmetics (missing = on).
	cosmetics: { trail: string, toggles: { [string]: boolean } },
	-- The Starter pack's one-time cash, Rizz and trail have been given.
	starterGranted: boolean,
	-- Game mode records: personal best seconds (0 = never finished), finishes, and os.time()
	-- of the last full cash reward (Economy.modeReward cooldown).
	-- Mog Test: best = highest score, rivals = most rivals mogged in one run, clears = tests
	-- passed.
	-- Parkour per level (dense, PARKOUR_LEVELS long, 0 = never): best seconds and finishes.
	-- modes.parkour keeps the shared reward cooldown and mirrors level 1 for the old UI.
	parkour: { best: { number }, clears: { number } },
	modes: {
		parkour: { best: number, clears: number, lastRewardAt: number },
		mog: { best: number, rivals: number, clears: number, lastRewardAt: number },
	},
}

-- Must equal Modes.Course.LEVEL_COUNT (checked by the unit tests).
local PARKOUR_LEVELS = 10
DataService.PARKOUR_LEVELS = PARKOUR_LEVELS

local function zeros(n: number): { number }
	local t = table.create(n, 0)
	return t
end

function DataService.defaultProfile(): Profile
	local units = zeros(Economy.MAX_TIER)
	units[1] = 1
	local discovered = zeros(Economy.MAX_TIER)
	discovered[1] = os.time()
	return {
		version = 1,
		money = 50,
		gems = 10,
		carried = 0,
		queue = 0,
		pending = 0,
		units = units,
		discovered = discovered,
		totalObtained = 1,
		buyTier = 1,
		boughtAtTier = 0,
		processLevel = 0,
		heldChest = "",
		pendingCrate = "",
		unlockers = {
			{ rarity = "", endsAt = 0 },
			{ rarity = "", endsAt = 0 },
		},
		autoMergeOwned = false,
		autoMerge = false,
		lastOnline = 0,
		lastFreeReward = 0,
		settings = { music = true, sfx = true, fullNumbers = false },
		receipts = {},
		totalEarned = 0,
		tutorialStep = 1,
		tutorialDone = false,
		introSeen = false,
		cosmetics = { trail = "", toggles = {} },
		starterGranted = false,
		parkour = { best = zeros(PARKOUR_LEVELS), clears = zeros(PARKOUR_LEVELS) },
		modes = {
			parkour = { best = 0, clears = 0, lastRewardAt = 0 },
			mog = { best = 0, rivals = 0, clears = 0, lastRewardAt = 0 },
		},
	}
end

-- Fills in any fields missing from older saves and sanitises bad values.
local function reconcile(data: any): Profile
	local default = DataService.defaultProfile()
	if type(data) ~= "table" then
		return default
	end
	-- Saves from before Parkour levels: the old single record becomes level 1's.
	if type(data.parkour) ~= "table" then
		local old = type(data.modes) == "table" and data.modes.parkour
		local migrated = { best = zeros(PARKOUR_LEVELS), clears = zeros(PARKOUR_LEVELS) }
		if type(old) == "table" then
			migrated.best[1] = old.best
			migrated.clears[1] = old.clears
		end
		data.parkour = migrated
	end
	-- Saves from before the tutorial existed belong to players who already
	-- know the game: don't send them through onboarding.
	if data.tutorialDone == nil then
		data.tutorialDone = type(data.totalObtained) == "number" and data.totalObtained > 1
	end
	-- Saves from before the intro cutscene existed: those players already know
	-- the story, so it never plays for them.
	if data.introSeen == nil then
		data.introSeen = true
	end
	for key, value in default :: any do
		if data[key] == nil or type(data[key]) ~= type(value) then
			data[key] = value
		end
	end
	for _, key in { "units", "discovered" } do
		local list = data[key]
		for tier = 1, Economy.MAX_TIER do
			if type(list[tier]) ~= "number" or list[tier] ~= list[tier] then
				list[tier] = 0
			end
		end
	end
	for i = 1, 2 do
		local slot = data.unlockers[i]
		if type(slot) ~= "table" or type(slot.rarity) ~= "string" or type(slot.endsAt) ~= "number" then
			data.unlockers[i] = { rarity = "", endsAt = 0 }
		end
	end
	for key, value in default.settings :: any do
		if type(data.settings[key]) ~= type(value) then
			data.settings[key] = value
		end
	end
	if type(data.cosmetics.trail) ~= "string" then
		data.cosmetics.trail = ""
	end
	if type(data.cosmetics.toggles) ~= "table" then
		data.cosmetics.toggles = {}
	end
	for key, value in data.cosmetics.toggles do
		if type(key) ~= "string" or type(value) ~= "boolean" then
			data.cosmetics.toggles[key] = nil
		end
	end
	data.buyTier = math.clamp(math.floor(data.buyTier), 1, Economy.MAX_BUY_TIER)
	-- Purchases past the upgrade requirement only count once (Economy.unitPrice grows with
	-- them); a save made under a larger requirement would otherwise price units out of reach.
	data.boughtAtTier = math.clamp(math.floor(data.boughtAtTier), 0, Economy.buyTierRequirement(data.buyTier))
	data.tutorialStep = TutorialSteps.clamp(data.tutorialStep)
	if data.heldChest ~= "" and not Economy.isRarity(data.heldChest) then
		data.heldChest = ""
	end
	for id, defaults in default.modes :: any do
		local record = data.modes[id]
		if type(record) ~= "table" then
			data.modes[id] = defaults
		else
			for key, value in defaults do
				local v = record[key]
				if type(v) ~= "number" or v ~= v or v < 0 or v == math.huge then
					record[key] = value
				end
			end
		end
	end
	for _, key in { "best", "clears" } do
		local list = data.parkour[key]
		local fixed = zeros(PARKOUR_LEVELS)
		if type(list) == "table" then
			for i = 1, PARKOUR_LEVELS do
				local v = list[i]
				if type(v) == "number" and v == v and v >= 0 and v ~= math.huge then
					fixed[i] = if key == "clears" then math.floor(v) else v
				end
			end
		end
		data.parkour[key] = fixed
	end
	if data.pendingCrate ~= "" and not Economy.isRarity(data.pendingCrate) then
		data.pendingCrate = ""
	end
	return data :: Profile
end

-- Exposed for the unit tests.
DataService.reconcile = reconcile

local store: DataStore? = nil
local storeOk, storeErr = pcall(function()
	store = DataStoreService:GetDataStore(STORE_NAME)
end)
if not storeOk then
	warn("[DataService] DataStore unavailable:", storeErr)
end

local function keyFor(player: Player): string
	return "u_" .. player.UserId
end

local function retry<T>(label: string, fn: () -> T): (boolean, T?)
	local lastErr
	for attempt = 1, MAX_RETRIES do
		local ok, result = pcall(fn)
		if ok then
			return true, result
		end
		lastErr = result
		task.wait(attempt * 1.5)
	end
	warn("[DataService]", label, "failed:", lastErr)
	return false, nil
end

-- This server's identity for session locks (JobId is empty in Studio).
local JOB_ID = if game.JobId ~= "" then game.JobId else ("studio-" .. HttpService:GenerateGUID(false))
-- How long a joining player waits for another server to release their save.
local LOCK_WAIT_SECONDS = 20

local function stripMeta(data: any): any
	if type(data) == "table" then
		data._lock = nil
	end
	return data
end

-- Returns (profile, canSave). profile is nil when the player should be kicked.
-- Acquires a session lock so two servers never write the same save.
function DataService.load(player: Player): (Profile?, boolean)
	if not store then
		if RunService:IsStudio() then
			warn("[DataService] Studio without DataStore access: progress will not be saved.")
			return reconcile(nil), false
		end
		return nil, false
	end
	local activeStore = store :: DataStore
	local started = os.clock()
	while player.Parent do
		local decision: SessionLock.Decision = "acquire"
		local loaded: any = nil
		local ok = retry("load " .. player.Name, function()
			activeStore:UpdateAsync(keyFor(player), function(current)
				local existing = if type(current) == "table" then current._lock else nil
				decision = SessionLock.decide(existing, JOB_ID, os.time(), os.clock() - started, LOCK_WAIT_SECONDS)
				if decision == "wait" then
					return nil -- leave the save untouched
				end
				local data = if type(current) == "table" then current else {}
				data._lock = { jobId = JOB_ID, at = os.time() }
				loaded = table.clone(data)
				return data
			end)
			return true
		end)
		if not ok then
			if RunService:IsStudio() then
				warn("[DataService] Enable 'Studio Access to API Services' to test saving. Using a temporary profile.")
				return reconcile(nil), false
			end
			return nil, false
		end
		if decision ~= "wait" then
			if decision == "steal" then
				warn("[DataService] Took over a save still locked by another server for", player.Name)
			end
			local isNew = loaded == nil or next(stripMeta(loaded)) == nil
			return reconcile(if isNew then nil else loaded), true
		end
		task.wait(3)
	end
	return nil, false
end

-- Saves the profile if this server still owns the session lock.
-- `release` clears the lock (player left / server shutting down).
-- Returns (saved, lostOwnership). lostOwnership is true when another server has
-- taken over this save; the caller should stop playing this session.
function DataService.save(player: Player, profile: Profile, release: boolean?): (boolean, boolean)
	if not store then
		return false, false
	end
	local activeStore = store :: DataStore
	profile.lastOnline = os.time()
	local stillOwner = true
	local ok = retry("save " .. player.Name, function()
		activeStore:UpdateAsync(keyFor(player), function(current)
			local existing = if type(current) == "table" then current._lock else nil
			if existing ~= nil and not SessionLock.owns(existing, JOB_ID) then
				stillOwner = false
				return nil -- another server owns this save now; never overwrite it
			end
			local data = table.clone(profile) :: any
			data._lock = if release then nil else { jobId = JOB_ID, at = os.time() }
			return data
		end)
		return true
	end)
	if not stillOwner then
		warn("[DataService] Save for", player.Name, "is owned by another server; not overwriting.")
	end
	return ok and stillOwner, not stillOwner
end

return DataService
