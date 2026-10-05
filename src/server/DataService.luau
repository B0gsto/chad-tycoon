--[[
	DataService: loads and saves player profiles in a DataStore.

	- Retries with backoff on load/save.
	- If a profile cannot be loaded on a live server the player is kicked
	  instead of being given a blank profile that would overwrite their save.
	- In Studio without API access it falls back to an in-memory profile and
	  never saves, so the game is still playable for testing.
]]

local DataStoreService = game:GetService("DataStoreService")
local RunService = game:GetService("RunService")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Economy = require(ReplicatedStorage.Shared.Economy)
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
}

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
	}
end

-- Fills in any fields missing from older saves and sanitises bad values.
local function reconcile(data: any): Profile
	local default = DataService.defaultProfile()
	if type(data) ~= "table" then
		return default
	end
	-- Saves from before the tutorial existed belong to players who already
	-- know the game: don't send them through onboarding.
	if data.tutorialDone == nil then
		data.tutorialDone = type(data.totalObtained) == "number" and data.totalObtained > 1
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
	data.buyTier = math.clamp(math.floor(data.buyTier), 1, Economy.MAX_BUY_TIER)
	data.tutorialStep = TutorialSteps.clamp(data.tutorialStep)
	if data.heldChest ~= "" and not Economy.isRarity(data.heldChest) then
		data.heldChest = ""
	end
	return data :: Profile
end

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

-- Returns (profile, canSave). profile is nil when the player should be kicked.
function DataService.load(player: Player): (Profile?, boolean)
	if not store then
		if RunService:IsStudio() then
			warn("[DataService] Studio without DataStore access: progress will not be saved.")
			return reconcile(nil), false
		end
		return nil, false
	end
	local activeStore = store :: DataStore
	local ok, data = retry("load " .. player.Name, function()
		return activeStore:GetAsync(keyFor(player))
	end)
	if not ok then
		if RunService:IsStudio() then
			warn("[DataService] Enable 'Studio Access to API Services' to test saving. Using a temporary profile.")
			return reconcile(nil), false
		end
		return nil, false
	end
	return reconcile(data), true
end

function DataService.save(player: Player, profile: Profile): boolean
	if not store then
		return false
	end
	local activeStore = store :: DataStore
	profile.lastOnline = os.time()
	local ok = retry("save " .. player.Name, function()
		activeStore:UpdateAsync(keyFor(player), function()
			return profile
		end)
		return true
	end)
	return ok
end

return DataService
