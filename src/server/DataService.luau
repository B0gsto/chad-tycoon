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
local Funnel = require(ReplicatedStorage.Shared.Funnel)
local SessionLock = require(ReplicatedStorage.Shared.SessionLock)
local TutorialSteps = require(ReplicatedStorage.Shared.TutorialSteps)

local DataService = {}

local STORE_NAME = "TycoonProfiles_v1"
local MAX_RETRIES = 4
-- Profile.version of a save written by this code. reconcile migrates older saves once:
--   2  the onboarding funnel counts tier milestones (Shared.Funnel)
--   3  Economy 2.0: the converter level is lifted to the free floor of the best tier
--      (Economy.minProcessLevel), firstCrateDone and the parkour `skipped` record exist.
--      Nothing saved is lowered or removed.
--   4  rebirth: `runDiscovered` starts as a copy of `discovered` (every save is in its first
--      run, with no stars) and the converter floor follows the run's best tier.
local VERSION = 4
DataService.VERSION = VERSION

-- `seconds`: the crate's whole timer (the Smasher's progress ring). A slot saved before it
-- was kept gets one when the save is loaded (reconcile).
export type Unlocker = { rarity: string, endsAt: number, seconds: number? }

export type Profile = {
	version: number,
	money: number,
	carried: number,
	queue: number,
	pending: number,
	units: { number },
	-- The Index: os.time() each tier was first found (0 = never). Never reset.
	discovered: { number },
	-- The same for the current run: a rebirth starts it again (Economy.rebirth). The crate
	-- anchor, the converter floor, the packs and the next goal read this one.
	runDiscovered: { number },
	-- Rebirths made and the stars they paid (Economy.STAR_BONUS cash each, for good).
	rebirths: number,
	stars: number,
	-- Index milestones claimed (Shared.IndexRewards): the `found` of each one. Never reset: a
	-- rebirth does not offer a milestone again. A save from before them has claimed none, so
	-- every milestone it has already passed is waiting in the Index window.
	indexClaimed: { number },
	totalObtained: number,
	-- Units bought on the buy pads so far (Economy.unitPrice grows with it).
	bought: number,
	processLevel: number,
	heldChest: string,
	-- The profile's first crate has been opened (until then a Smasher slot takes
	-- Economy.FIRST_CRATE_SECONDS).
	firstCrateDone: boolean,
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
	-- Equipped trail ("" = none), on/off switches of the toggle cosmetics (missing = on) and
	-- `champion`: the Champion aura colour is owned (the whole Index's milestone, claimed).
	cosmetics: { trail: string, toggles: { [string]: boolean }, champion: boolean },
	-- The Starter pack's one-time cash and trail have been given.
	starterGranted: boolean,
	-- Highest onboarding funnel step logged (Analytics; ONBOARDING_LEGACY = saves from before it).
	onboarding: number,
	-- Roblox badges: true = awarded, false = earned and waiting to be awarded (Badges).
	badges: { [string]: boolean },
	-- Daily reward (Server.Daily, Shared.DailyReward): UTC day number of the last claim
	-- (0 = never), days claimed in a row at that claim, UTC day number of the player's first
	-- day (0 = not started yet, 1 = saves from before the daily reward), whether the
	-- first-day "come back tomorrow" toast was shown, and the streak value of the claim that
	-- used the streak saver (0 = not used; saves from before it read 0).
	daily: { day: number, streak: number, firstDay: number, hinted: boolean, saverUsedAt: number },
	-- Game mode records: personal best seconds (0 = never finished), finishes, and os.time()
	-- of the last full cash reward (Economy.modeReward cooldown).
	-- Mog Test: best = highest score, rivals = most rivals mogged in one run, clears = tests
	-- passed (and PvP wins paid), pvpWins / pvpPlayed = PvP duels won / fought.
	-- Parkour per level (dense, PARKOUR_LEVELS long, 0 = never): best seconds, finishes and
	-- skipped (1 = the map was skipped for cash, which unlocks the next one).
	-- modes.parkour keeps the shared reward cooldown and mirrors level 1 for the old UI.
	-- stage = highest sky-obby stage reached (0 = never ran; one stage per map since the
	-- checkpoints went: map n is stage n, finishing map 10 is 11); stageMaps = the stage is
	-- in those units (older saves counted checkpoints and are rebuilt on load); gear = the
	-- chosen coil ("none" | "speed" | "jump" | "gravity", worn only during runs).
	parkour: { best: { number }, clears: { number }, skipped: { number }, stage: number, stageMaps: boolean, gear: string },
	-- Cardio (keyboard runner): Speed earned (permanent, never goes down), deepest WIN plate
	-- claimed (0..CARDIO_STAGES), treadmill level (0..CARDIO_TREADMILL_MAX), WIN plates claimed
	-- in total (clears), the player's own max WalkSpeed (0 = none, else 16..CARDIO_WALK_CAP)
	-- and the plates whose first-clear pay was taken (firsts: a bit set, bit n - 1 = plate n;
	-- Modes.CardioRules.firstsOf).
	cardio: { speed: number, bestStage: number, treadmill: number, clears: number, speedCap: number, firsts: number },
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
		version = VERSION,
		money = Economy.START_CASH,
		carried = 0,
		queue = 0,
		pending = 0,
		units = units,
		discovered = discovered,
		runDiscovered = table.clone(discovered),
		rebirths = 0,
		stars = 0,
		indexClaimed = {},
		totalObtained = 1,
		bought = 0,
		processLevel = Economy.START_PROCESS_LEVEL,
		heldChest = "",
		firstCrateDone = false,
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
		cosmetics = { trail = "", toggles = {}, champion = false },
		starterGranted = false,
		onboarding = 0,
		badges = {},
		daily = { day = 0, streak = 0, firstDay = 0, hinted = false, saverUsedAt = 0 },
		parkour = {
			best = zeros(PARKOUR_LEVELS),
			clears = zeros(PARKOUR_LEVELS),
			skipped = zeros(PARKOUR_LEVELS),
			stage = 0,
			stageMaps = true,
			gear = "none",
		},
		cardio = { speed = 0, bestStage = 0, treadmill = 0, clears = 0, speedCap = 0, firsts = 0 },
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
	-- Read before the defaults below fill a missing version in.
	local version = if type(data.version) == "number" then data.version else 1
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
	-- Buy tiers were removed: the pads sell the first tier only. A save that had upgraded
	-- starts just past the easy units; one that had not keeps its count, as capped as it was.
	if data.bought == nil then
		local old = if type(data.boughtAtTier) == "number" and data.boughtAtTier == data.boughtAtTier then data.boughtAtTier else 0
		local upgraded = type(data.buyTier) == "number" and data.buyTier > 1
		data.bought = if upgraded then Economy.BUY_EASY_UNITS else math.clamp(math.floor(old), 0, Economy.BUY_EASY_UNITS)
	end
	data.buyTier = nil
	data.boughtAtTier = nil
	-- Saves from before the onboarding funnel: those players are not new, so they never log it.
	if data.onboarding == nil then
		data.onboarding = 99
	end
	-- Saves from before the first-crate head start: anyone who has played already had their
	-- first crate (or waits the normal time for it); only a brand-new profile gets the short one.
	if type(data.firstCrateDone) ~= "boolean" then
		local played = (type(data.bought) == "number" and data.bought > 0)
			or (type(data.totalObtained) == "number" and data.totalObtained > 1)
			or data.tutorialDone == true
		data.firstCrateDone = played
	end
	-- Saves from before the daily reward: day 1 is waiting, but today is not a "first day".
	if data.daily == nil then
		data.daily = { day = 0, streak = 0, firstDay = 1, hinted = true, saverUsedAt = 0 }
	end
	-- Saves from before rebirth are in their first run: it has found what the Index has.
	if type(data.runDiscovered) ~= "table" and type(data.discovered) == "table" then
		data.runDiscovered = table.clone(data.discovered)
	end
	for key, value in default :: any do
		if data[key] == nil or type(data[key]) ~= type(value) then
			data[key] = value
		end
	end
	for _, key in { "units", "discovered", "runDiscovered" } do
		local list = data[key]
		for tier = 1, Economy.MAX_TIER do
			if type(list[tier]) ~= "number" or list[tier] ~= list[tier] then
				list[tier] = 0
			end
		end
	end
	-- The Index holds every tier a run has found.
	for tier = 1, Economy.MAX_TIER do
		if data.runDiscovered[tier] > 0 and data.discovered[tier] <= 0 then
			data.discovered[tier] = data.runDiscovered[tier]
		end
	end
	for _, key in { "rebirths", "stars" } do
		local v = data[key]
		data[key] = if v ~= v or v < 0 or v == math.huge then 0 else math.floor(v)
	end
	-- Claimed Index milestones: whole tier counts, each once, in the order they were claimed.
	-- Junk is dropped; a claim is never taken back.
	local claimed: { number } = {}
	for _, found in data.indexClaimed do
		if type(found) == "number" and found == math.floor(found) and found >= 1 and found <= Economy.MAX_TIER then
			if not table.find(claimed, found) then
				table.insert(claimed, found)
			end
		end
	end
	data.indexClaimed = claimed
	for i = 1, 2 do
		local slot = data.unlockers[i]
		if type(slot) ~= "table" or type(slot.rarity) ~= "string" or type(slot.endsAt) ~= "number" then
			data.unlockers[i] = { rarity = "", endsAt = 0 }
		elseif slot.seconds ~= nil and (type(slot.seconds) ~= "number" or slot.seconds ~= slot.seconds or slot.seconds <= 0) then
			slot.seconds = nil
		end
		slot = data.unlockers[i]
		-- A crate loaded before the slot kept its whole timer: the time still left now (or the
		-- rarity's timer, when that is longer) stands in for it from here on, so the Smasher's
		-- progress ring fills steadily to the saved end time. `endsAt` is not touched.
		if slot.seconds == nil and Economy.isRarity(slot.rarity) then
			slot.seconds = math.max(slot.endsAt - os.time(), Economy.unlockSeconds(slot.rarity, i == 2))
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
	-- The Champion aura colour comes with the whole Index's milestone: a save that claimed
	-- it owns it, whatever the flag says.
	local champion = table.find(data.indexClaimed, Economy.MAX_TIER) ~= nil
	if champion or type(data.cosmetics.champion) ~= "boolean" then
		data.cosmetics.champion = champion
	end
	for key, value in data.cosmetics.toggles do
		if type(key) ~= "string" or type(value) ~= "boolean" then
			data.cosmetics.toggles[key] = nil
		end
	end
	data.bought = if data.bought ~= data.bought or data.bought == math.huge then 0 else math.max(0, math.floor(data.bought))
	-- The converter starts at START_PROCESS_LEVEL; saves from before that are lifted to it.
	data.processLevel = math.max(math.floor(data.processLevel), Economy.START_PROCESS_LEVEL)
	-- ...and it is never below the free floor of the best tier of the current run (a rebirth
	-- takes the level back to the start, whatever the Index holds).
	data.processLevel = math.max(data.processLevel, Economy.minProcessLevel(Economy.highestTier(data.runDiscovered)))
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
	for _, key in { "best", "clears", "skipped" } do
		local list = data.parkour[key]
		local fixed = zeros(PARKOUR_LEVELS)
		if type(list) == "table" then
			for i = 1, PARKOUR_LEVELS do
				local v = list[i]
				if type(v) == "number" and v == v and v >= 0 and v ~= math.huge then
					fixed[i] = if key == "best" then v elseif key == "skipped" then math.min(math.floor(v), 1) else math.floor(v)
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
	-- (Read before the defaults go in: a save without `firsts` is not a save that took none.)
	local firsts = data.cardio.firsts
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
	-- Saves from before the per-plate set had one counter: every plate up to bestStage is taken
	-- (the same rule as Modes.CardioRules.firstsOf).
	data.cardio.firsts = if type(firsts) == "number"
			and firsts == firsts
			and firsts >= 0
		then math.min(math.floor(firsts), 2 ^ CARDIO_STAGES - 1)
		else 2 ^ data.cardio.bestStage - 1
	for key, value in data.badges do
		if type(key) ~= "string" or type(value) ~= "boolean" then
			data.badges[key] = nil
		end
	end
	if data.pendingCrate ~= "" and not Economy.isRarity(data.pendingCrate) then
		data.pendingCrate = ""
	end
	for key, value in default.daily :: any do
		local v = data.daily[key]
		if type(v) ~= type(value) or (type(v) == "number" and (v ~= v or v < 0 or v == math.huge)) then
			data.daily[key] = value
		elseif type(v) == "number" then
			data.daily[key] = math.floor(v)
		end
	end
	if data.pendingUnlocker ~= 1 and data.pendingUnlocker ~= 2 then
		data.pendingUnlocker = 0
	end
	if version < 2 then
		-- Returning players' tier milestones count as logged, with nothing sent.
		data.onboarding = Funnel.returning(data.onboarding, data.tutorialDone)
	end
	data.version = math.max(version, VERSION)
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
