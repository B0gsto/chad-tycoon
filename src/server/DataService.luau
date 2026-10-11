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
	-- Smasher slot (1 or 2) that Robux prompt was for (0 = the held crate): the receipt
	-- opens the crate still in that slot.
	pendingUnlocker: number,
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
	-- The Starter pack's one-time cash and trail have been given.
	starterGranted: boolean,
	-- Highest onboarding funnel step logged (Analytics; ONBOARDING_LEGACY = saves from before it).
	onboarding: number,
	-- Roblox badges: true = awarded, false = earned and waiting to be awarded (Badges).
	badges: { [string]: boolean },
	-- Game mode records: personal best seconds (0 = never finished), finishes, and os.time()
	-- of the last full cash reward (Economy.modeReward cooldown).
	-- Mog Test: best = highest score, rivals = most rivals mogged in one run, clears = tests
	-- passed (and PvP wins paid), pvpWins / pvpPlayed = PvP duels won / fought.
	-- Parkour per level (dense, PARKOUR_LEVELS long, 0 = never): best seconds and finishes.
	-- modes.parkour keeps the shared reward cooldown and mirrors level 1 for the old UI.
	-- stage = highest sky-obby stage reached (0 = never ran; one stage per map since the
	-- checkpoints went: map n is stage n, finishing map 10 is 11); stageMaps = the stage is
	-- in those units (older saves counted checkpoints and are rebuilt on load); gear = the
	-- chosen coil ("none" | "speed" | "jump" | "gravity", worn only during runs).
	parkour: { best: { number }, clears: { number }, stage: number, stageMaps: boolean, gear: string },
	-- Cardio (keyboard runner): Speed earned (permanent, never goes down), highest safe zone
	-- reached (0..CARDIO_STAGES), treadmill level (0..CARDIO_TREADMILL_MAX), safe-zone arrivals
	-- and the player's own max WalkSpeed (0 = none, else 16..CARDIO_WALK_CAP).
	cardio: { speed: number, bestStage: number, treadmill: number, clears: number, speedCap: number },
	modes: {
		parkour: { best: number, clears: number, lastRewardAt: number },
		mog: {
			best: number,
			rivals: number,
			clears: number,
			lastRewardAt: number,
			pvpWins: number,
			pvpPlayed: number,
		},
		-- best mirrors cardio.bestStage, clears cardio.clears; lastRewardAt is the cooldown.
		cardio: { best: number, clears: number, lastRewardAt: number },
	},
}

-- Must equal Modes.Course.LEVEL_COUNT (checked by the unit tests).
local PARKOUR_LEVELS = 10
DataService.PARKOUR_LEVELS = PARKOUR_LEVELS
-- Must equal Modes.CardioRules.STAGE_COUNT / TREADMILL_MAX.
local CARDIO_STAGES = 10
local CARDIO_TREADMILL_MAX = 10
-- Must equal Modes.CardioRules.BASE_WALK / WALK_CAP.
local CARDIO_WALK_MIN = 16
local CARDIO_WALK_CAP = 120

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
		money = Economy.START_CASH,
		carried = 0,
		queue = 0,
		pending = 0,
		units = units,
		discovered = discovered,
		totalObtained = 1,
		buyTier = 1,
		boughtAtTier = 0,
		processLevel = Economy.START_PROCESS_LEVEL,
		heldChest = "",
		pendingCrate = "",
		pendingUnlocker = 0,
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
		onboarding = 0,
		badges = {},
		parkour = { best = zeros(PARKOUR_LEVELS), clears = zeros(PARKOUR_LEVELS), stage = 0, stageMaps = true, gear = "none" },
		cardio = { speed = 0, bestStage = 0, treadmill = 0, clears = 0, speedCap = 0 },
		modes = {
			parkour = { best = 0, clears = 0, lastRewardAt = 0 },
			mog = { best = 0, rivals = 0, clears = 0, lastRewardAt = 0, pvpWins = 0, pvpPlayed = 0 },
			cardio = { best = 0, clears = 0, lastRewardAt = 0 },
		},
	}
end

-- Parkour gear names a save may hold (Modes.Parkour).
local PARKOUR_GEARS = { none = true, speed = true, jump = true, gravity = true }

-- Fills in any fields missing from older saves and sanitises bad values.
local function reconcile(data: any): Profile
	local default = DataService.defaultProfile()
	if type(data) ~= "table" then
		return default
	end
	-- Saves from before Parkour levels: the old single record becomes level 1's.
	if type(data.parkour) ~= "table" then
		local old = type(data.modes) == "table" and data.modes.parkour
		local migrated = { best = zeros(PARKOUR_LEVELS), clears = zeros(PARKOUR_LEVELS), stage = 0, gear = "none" }
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
	-- Rizz (gems) was removed from the game: old balances are dropped.
	data.gems = nil
	-- Saves from before the onboarding funnel: those players are not new, so they never log it.
	if data.onboarding == nil then
		data.onboarding = 99
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
	-- The converter starts at START_PROCESS_LEVEL; saves from before that are lifted to it.
	data.processLevel = math.max(math.floor(data.processLevel), Economy.START_PROCESS_LEVEL)
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
	local stage = data.parkour.stage
	stage = if type(stage) == "number" and stage == stage and stage >= 0 and stage ~= math.huge then math.floor(stage) else 0
	if data.parkour.stageMaps ~= true then
		-- Saves from the checkpoint days: `stage` counted checkpoints along the chain. Rebuild
		-- it in map units from the maps cleared in a row from map 1 (the start of the next
		-- map is reached; all ten cleared is the last finish, PARKOUR_LEVELS + 1).
		local cleared = 0
		while cleared < PARKOUR_LEVELS and data.parkour.clears[cleared + 1] > 0 do
			cleared += 1
		end
		stage = if cleared > 0 then cleared + 1 elseif stage > 0 then 1 else 0
		data.parkour.stageMaps = true
	end
	data.parkour.stage = math.min(stage, PARKOUR_LEVELS + 1)
	if not PARKOUR_GEARS[data.parkour.gear] then
		data.parkour.gear = "none"
	end
	for key, value in default.cardio :: any do
		local v = data.cardio[key]
		if type(v) ~= "number" or v ~= v or v < 0 or v == math.huge then
			data.cardio[key] = value
		end
	end
	data.cardio.bestStage = math.clamp(math.floor(data.cardio.bestStage), 0, CARDIO_STAGES)
	data.cardio.treadmill = math.clamp(math.floor(data.cardio.treadmill), 0, CARDIO_TREADMILL_MAX)
	data.cardio.clears = math.floor(data.cardio.clears)
	local cap = math.floor(data.cardio.speedCap + 0.5)
	data.cardio.speedCap = if cap < CARDIO_WALK_MIN then 0 else math.min(cap, CARDIO_WALK_CAP)
	for key, value in data.badges do
		if type(key) ~= "string" or type(value) ~= "boolean" then
			data.badges[key] = nil
		end
	end
	if data.pendingCrate ~= "" and not Economy.isRarity(data.pendingCrate) then
		data.pendingCrate = ""
	end
	if data.pendingUnlocker ~= 1 and data.pendingUnlocker ~= 2 then
		data.pendingUnlocker = 0
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
