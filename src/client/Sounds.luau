-- Sound effects plus background music.
--
-- Every name has a list of candidate sound ids (primary first). All ids below
-- were verified to load in the client (IsLoaded, TimeLength > 0). Each candidate
-- is still preloaded once at runtime; one that fails to load (moderation,
-- missing asset, timeout) is skipped in favour of the next. Until any candidate
-- is confirmed, the first one not known to have failed plays (it streams in).
--
-- Sources: Roblox-made UI sounds (creator "Roblox"), the licensed APM / Pro
-- Sound Effects libraries, this game's own uploads, and free public Creator
-- Store audio. The only bundled client file used is volume_slider.ogg (a soft
-- tick, shipped with every client) as a last resort for UI clicks.
--
-- Sounds.play(name, pitchJitter?, pitchMult?): unknown names are a no-op.
-- Sounds.updateMusic(): starts/stops the looping music per settings.music.
-- Sounds.setMood("surge" | nil): during an Aura Surge the music cross-fades (1 s)
-- to the surge track (Theme.SurgeMusicId, else the other built-in track, a bit
-- faster and louder) and back, resuming the normal track where it paused. With
-- no second track loaded the normal track just speeds up for the surge. Music
-- off stays off; the mood waits while the intro cutscene plays.

local ContentProvider = game:GetService("ContentProvider")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")

local Theme = require(ReplicatedStorage:WaitForChild("Theme"))
local State = require(script.Parent.State)

local Sounds = {}

local function lib(id: number): string
	return "rbxassetid://" .. id
end

-- Bundled with the client (content/sounds); always available.
local BUNDLED_TICK = "rbxasset://sounds/volume_slider.ogg"

-- Roblox-made UI sounds.
local UI_SMALL_CLICK = lib(15675032796) -- Roblox_UI_Small_Click
local UI_BRIGHT_CLICK = lib(15675059323) -- Roblox_UI_Bright_Click
local UI_CUTE_POP = lib(15675055424) -- Roblox_UI_Cute_Pop
local UI_TONAL_STINGER = lib(15675043410) -- Roblox_UI_Tonal_Stinger
local UI_WHOOSH_01 = lib(15675024286) -- Roblox_UI_Whoosh_01
local UI_WHOOSH_03 = lib(15674975792) -- Roblox_UI_Whoosh_03
local UI_DELETE = lib(15675075163) -- Roblox_UI_Delete
local GUI_SELECT = lib(17208396156) -- Roblox GUI - Select
local GUI_NOTIFY_HIGH = lib(17208361335) -- Roblox GUI - Notification High
local GUI_BUBBLE = lib(17208204604) -- Roblox GUI - Bubble
local GUI_BACK = lib(17208186900) -- Roblox GUI - Back
local GUI_ACCEPT = lib(17208209318) -- Roblox GUI - Call Accept
local GUI_DECLINE = lib(17208214688) -- Roblox GUI - Call Decline
local GUI_PURCHASE = lib(17208380755) -- Roblox GUI - Purchase

-- Pro Sound Effects library.
local WHOOSH_AIRY = lib(9125646252) -- Magic Whooshes Airy
local WHOOSH_ZOOM = lib(9125648149) -- Magic Zoom Up Sharp Tubular Whoosh

-- Free public Creator Store audio.
local KACHING = lib(134208887292061) -- cash-register-kaching
local COIN_COLLECT = lib(135483737426662) -- Coin Collect
local ERROR_BUZZ = lib(91501650514390) -- Error Buzz

-- This game's own uploads.
local POP_PLUCK = lib(110564740926229)
local POP_MARIMBA = lib(82880781602391)
local POP_BELL = lib(108513451493306)
local TICK_A = lib(95444478167276)
local TICK_B = lib(104556737710683)
local TICK_C = lib(111480305904301)
local CRACKLE_A = lib(130988843893972)
local CRACKLE_B = lib(109769434232691)
local HIT_A = lib(132346841133984)
local HIT_B = lib(83739861834001)
local HIT_C = lib(112084716984188)
local LEVELUP = lib(139915238370208)
local FRENZY_START = lib(87726512735006)
local RING_A = lib(131720940448187)
local RING_B = lib(102704930703884)
local UNLOCK_STINGER = lib(121068318613723)
local CEREMONY_COMMON = lib(75797999851350)
local CEREMONY_EPIC = lib(100965222685530)
local CEREMONY_LEGENDARY = lib(85196226744574)

-- Upbeat, loopable APM library tracks (licensed for every experience). Used
-- when the theme leaves MusicId empty.
local DEFAULT_MUSIC = {
	lib(1842265339), -- APM "Get Dancing"
	lib(1843197585), -- APM "Remote Control"
}
local MUSIC_VOLUME = 0.18
-- Aura Surge music: cross-fade time, the surge track's speed and loudness, and the
-- speed of the normal track when it has to double as the surge track.
local MOOD_FADE = 1
local SURGE_TRACK_SPEED = 1.12
local SURGE_VOLUME = MUSIC_VOLUME * 1.15
local SURGE_SOLO_SPEED = 1.15

-- `rotate` names pick a random loaded candidate on each play.
type Def = {
	ids: { string },
	volume: number,
	pitch: number?,
	gap: number?,
	rotate: boolean?,
}

local DEFS: { [string]: Def } = {
	-- UI
	Click = { ids = { UI_SMALL_CLICK, GUI_SELECT, BUNDLED_TICK }, volume = 0.45 },
	Toggle = { ids = { UI_BRIGHT_CLICK, GUI_SELECT, BUNDLED_TICK }, volume = 0.45 },
	Toast = { ids = { GUI_NOTIFY_HIGH, GUI_BUBBLE }, volume = 0.25, gap = 0.05 },
	Error = { ids = { ERROR_BUZZ, GUI_DECLINE, UI_DELETE }, volume = 0.35 },
	Open = { ids = { WHOOSH_ZOOM, UI_WHOOSH_01 }, volume = 0.18 },
	Close = { ids = { GUI_BACK, WHOOSH_ZOOM }, volume = 0.3, pitch = 1.1 },
	Step = { ids = { GUI_ACCEPT, POP_BELL }, volume = 0.5 },
	Reward = { ids = { CEREMONY_COMMON, UI_TONAL_STINGER }, volume = 0.55 },
	Celebrate = { ids = { CEREMONY_EPIC, CEREMONY_COMMON }, volume = 0.6 },
	CelebrateLegendary = { ids = { CEREMONY_LEGENDARY, CEREMONY_EPIC }, volume = 0.7 },
	-- Economy
	Collect = { ids = { POP_MARIMBA, COIN_COLLECT }, volume = 0.3, gap = 0.05 },
	Cash = { ids = { KACHING, GUI_PURCHASE }, volume = 0.35, gap = 0.1 },
	Coin = { ids = { POP_MARIMBA, COIN_COLLECT }, volume = 0.28, gap = 0.045 },
	Deposit = { ids = { WHOOSH_AIRY, UI_WHOOSH_03 }, volume = 0.4 },
	DepositStream = { ids = { WHOOSH_AIRY, UI_WHOOSH_03 }, volume = 0.3, pitch = 1.15, gap = 0.25 },
	Buy = { ids = { GUI_PURCHASE, KACHING }, volume = 0.5 },
	BuyPop = { ids = { POP_BELL, UI_CUTE_POP }, volume = 0.45 },
	Upgrade = { ids = { LEVELUP, UNLOCK_STINGER }, volume = 0.45 },
	Pickup = { ids = { GUI_BUBBLE, UI_CUTE_POP }, volume = 0.45 },
	-- Orbs
	OrbPickup = { ids = { POP_PLUCK, POP_MARIMBA }, volume = 0.22, gap = 0.03 },
	-- Merges
	MergeCharge = { ids = { CRACKLE_A, CRACKLE_B }, volume = 0.4 },
	MergeBoom = { ids = { HIT_A, HIT_B, HIT_C }, volume = 0.55, rotate = true },
	-- Machines
	Ready = { ids = { RING_A, RING_B }, volume = 0.6 },
	Tick = { ids = { TICK_A, TICK_B, TICK_C, BUNDLED_TICK }, volume = 0.35, gap = 0.03, rotate = true },
	-- Events (SurgeStart is the intro cutscene's sting; the live surge itself is silent)
	SurgeStart = { ids = { FRENZY_START, UNLOCK_STINGER }, volume = 0.7 },
	CrateShake = { ids = { CRACKLE_B, CRACKLE_A }, volume = 0.55 },
	CrateBurst = { ids = { UNLOCK_STINGER, CEREMONY_COMMON }, volume = 0.6 },
}

local PRELOAD_TIMEOUT = 6

-- Load status per sound id: nil = unknown, "pending", "ok", "failed".
local status: { [string]: string } = {}
-- One Sound instance per name holding the currently chosen id.
local instances: { [string]: Sound } = {}
local lastPlayed: { [string]: number } = {}

local function probe(id: string)
	if status[id] ~= nil then
		return
	end
	status[id] = "pending"
	task.spawn(function()
		local probeSound = Instance.new("Sound")
		probeSound.SoundId = id
		probeSound.Volume = 0
		probeSound.Parent = SoundService
		local result = "failed"
		local done = false
		task.delay(PRELOAD_TIMEOUT, function()
			done = true
		end)
		task.spawn(function()
			local ok = pcall(function()
				ContentProvider:PreloadAsync({ probeSound }, function(_, fetch)
					if fetch == Enum.AssetFetchStatus.Success then
						result = "ok"
					end
				end)
			end)
			if not ok then
				result = "failed"
			end
			done = true
		end)
		while not done do
			task.wait(0.1)
		end
		if result == "ok" and not (probeSound.IsLoaded and probeSound.TimeLength > 0) then
			-- Preload succeeded but the Sound must also report a playable length.
			result = "failed"
		end
		status[id] = result
		probeSound:Destroy()
	end)
end

-- Best id right now: a confirmed candidate (random among them for `rotate`),
-- else the first candidate not known to have failed. Nil when all failed.
local function chooseId(ids: { string }, rotate: boolean?): string?
	for _, id in ids do
		probe(id)
	end
	if rotate then
		local ready = {}
		for _, id in ids do
			if status[id] == "ok" and string.sub(id, 1, 11) ~= "rbxasset://" then
				table.insert(ready, id)
			end
		end
		if #ready > 0 then
			return ready[math.random(1, #ready)]
		end
	end
	for _, id in ids do
		if status[id] == "ok" then
			return id
		end
	end
	for _, id in ids do
		if status[id] ~= "failed" then
			return id
		end
	end
	return nil
end

local function sfxEnabled(): boolean
	local data = State.data
	return not data or not data.settings or data.settings.sfx ~= false
end

local function playNow(name: string, pitchJitter: number?, pitchMult: number?)
	local entry = DEFS[name]
	if not entry or not sfxEnabled() then
		return
	end
	local now = os.clock()
	if entry.gap and now - (lastPlayed[name] or 0) < entry.gap then
		return
	end
	lastPlayed[name] = now
	local id = chooseId(entry.ids, entry.rotate)
	if not id then
		return
	end
	local sound = instances[name]
	if not sound then
		sound = Instance.new("Sound")
		sound.Name = "Sfx_" .. name
		sound.Parent = SoundService
		instances[name] = sound
	end
	if sound.SoundId ~= id then
		sound.SoundId = id
	end
	sound.Volume = entry.volume
	local pitch = (entry.pitch or 1) * (pitchMult or 1)
	if pitchJitter then
		pitch += (math.random() - 0.5) * pitchJitter
	end
	sound.PlaybackSpeed = math.max(0.1, pitch)
	SoundService:PlayLocalSound(sound)
end

-- While the intro cutscene plays (LocalPlayer attribute "IntroPlaying"), gameplay sounds
-- stay silent: the tycoon keeps running behind it and its merges and pickups would leak in.
local function introPlaying(): boolean
	return Players.LocalPlayer:GetAttribute("IntroPlaying") == true
end

function Sounds.play(name: string, pitchJitter: number?, pitchMult: number?)
	if introPlaying() then
		return
	end
	playNow(name, pitchJitter, pitchMult)
end

-- For the cutscene's own sounds, which are the only ones heard while it plays.
function Sounds.playCutscene(name: string, pitchJitter: number?, pitchMult: number?)
	playNow(name, pitchJitter, pitchMult)
end

local musicIds: { string } = if Theme.MusicId ~= "" then { Theme.MusicId } else DEFAULT_MUSIC
local surgeMusicId: string = (Theme :: any).SurgeMusicId or ""

-- Kick off loading of every candidate early.
task.defer(function()
	for _, entry in DEFS do
		for _, id in entry.ids do
			probe(id)
		end
	end
	for _, id in musicIds do
		probe(id)
	end
	for _, id in DEFAULT_MUSIC do
		probe(id)
	end
	if surgeMusicId ~= "" then
		probe(surgeMusicId)
	end
end)

local music: Sound? = nil

-- Music mood ("surge" or nil) and how the surge music is playing right now:
-- "track" = a second Sound (surgeMusic) with the normal track paused under it,
-- "speed" = the normal track itself sped up; nil = normal music.
local mood: string? = nil
local surgeMode: string? = nil
local surgeMusic: Sound? = nil

-- The running cross-fade per Sound (a new fade replaces it).
local fades: { [Sound]: Tween } = {}

local function fade(sound: Sound, props: { [string]: any }): Tween
	local old = fades[sound]
	if old then
		old:Cancel()
	end
	local tween = TweenService:Create(sound, TweenInfo.new(MOOD_FADE, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut), props)
	fades[sound] = tween
	tween:Play()
	return tween
end

local function cancelFades()
	for _, tween in fades do
		tween:Cancel()
	end
	table.clear(fades)
end

-- The surge track and its speed: the theme's SurgeMusicId, else a loaded built-in
-- track other than `currentId`; nil when there is none (the normal track speeds up).
local function surgeTrack(currentId: string): (string?, number)
	if surgeMusicId ~= "" and status[surgeMusicId] == "ok" then
		return surgeMusicId, 1
	end
	for _, id in DEFAULT_MUSIC do
		if id ~= currentId and status[id] == "ok" then
			return id, SURGE_TRACK_SPEED
		end
	end
	return nil, SURGE_SOLO_SPEED
end

local function enterSurge(m: Sound)
	local id, speed = surgeTrack(m.SoundId)
	if not id then
		surgeMode = "speed"
		fade(m, { PlaybackSpeed = speed, Volume = SURGE_VOLUME })
		return
	end
	surgeMode = "track"
	local s = surgeMusic
	if not s then
		local sound = Instance.new("Sound")
		sound.Name = "MusicSurge"
		sound.Looped = true
		sound.Parent = SoundService
		surgeMusic = sound
		s = sound
	end
	local surgeSound = s :: Sound
	if surgeSound.SoundId ~= id then
		surgeSound:Stop()
		surgeSound.SoundId = id
	end
	surgeSound.PlaybackSpeed = speed
	surgeSound.Volume = 0
	if not surgeSound.IsPlaying then
		surgeSound:Play()
	end
	fade(surgeSound, { Volume = SURGE_VOLUME })
	fade(m, { Volume = 0 }).Completed:Connect(function(state)
		if state == Enum.PlaybackState.Completed and surgeMode == "track" then
			m:Pause()
		end
	end)
end

local function leaveSurge(m: Sound)
	local wasTrack = surgeMode == "track"
	surgeMode = nil
	if not m.IsPlaying then
		m:Resume()
	end
	fade(m, { Volume = MUSIC_VOLUME, PlaybackSpeed = 1 })
	local s = surgeMusic
	if wasTrack and s then
		fade(s, { Volume = 0 }).Completed:Connect(function(state)
			if state == Enum.PlaybackState.Completed and surgeMode == nil then
				s:Stop()
			end
		end)
	end
end

-- Music off: everything stops at once and the next start is the normal track.
local function stopAll(m: Sound)
	surgeMode = nil
	cancelFades()
	if surgeMusic then
		surgeMusic:Stop()
	end
	m:Stop()
	m.Volume = MUSIC_VOLUME
	m.PlaybackSpeed = 1
end

-- Called on every state update: also swaps to the next music candidate if the
-- current one turned out not to load.
function Sounds.updateMusic()
	local data = State.data
	local enabled = not data or not data.settings or data.settings.music ~= false
	local id = chooseId(musicIds)
	if not music then
		if not enabled or not id then
			return
		end
		local sound = Instance.new("Sound")
		sound.Name = "Music"
		sound.Looped = true
		sound.Volume = MUSIC_VOLUME
		sound.Parent = SoundService
		music = sound
	end
	local m = music :: Sound
	if id and m.SoundId ~= id then
		m:Stop()
		m.SoundId = id
	end
	if not enabled or not id then
		if m.IsPlaying or surgeMode then
			stopAll(m)
		end
		return
	end
	local wantSurge = mood == "surge" and not introPlaying()
	if wantSurge and not surgeMode then
		if not m.IsPlaying then
			m:Play()
		end
		enterSurge(m)
	elseif not wantSurge and surgeMode then
		leaveSurge(m)
	elseif surgeMode ~= "track" and not m.IsPlaying then
		m:Play()
	end
end

function Sounds.setMood(name: string?)
	if name == mood then
		return
	end
	mood = name
	Sounds.updateMusic()
end

-- The surge mood waits for the intro to finish (and clears if the intro replays).
Players.LocalPlayer:GetAttributeChangedSignal("IntroPlaying"):Connect(function()
	if mood ~= nil or surgeMode ~= nil then
		Sounds.updateMusic()
	end
end)

return Sounds
