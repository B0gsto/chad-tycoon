-- Sound effects using sounds bundled with the Roblox client (no uploads needed),
-- plus optional theme music.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")

local Theme = require(ReplicatedStorage:WaitForChild("Theme"))
local State = require(script.Parent.State)

local Sounds = {}

local DEFS: { [string]: { id: string, volume: number, pitch: number } } = {
	Click = { id = "rbxasset://sounds/electronicpingshort.wav", volume = 0.35, pitch = 1.6 },
	Collect = { id = "rbxasset://sounds/electronicpingshort.wav", volume = 0.25, pitch = 2.2 },
	Cash = { id = "rbxasset://sounds/electronicpingshort.wav", volume = 0.5, pitch = 1.2 },
	Deposit = { id = "rbxasset://sounds/swoosh.wav", volume = 0.5, pitch = 0.9 },
	Buy = { id = "rbxasset://sounds/clickfast.wav", volume = 0.6, pitch = 1 },
	Merge = { id = "rbxasset://sounds/swoosh.wav", volume = 0.6, pitch = 1.4 },
	Reward = { id = "rbxasset://sounds/electronicpingshort.wav", volume = 0.7, pitch = 0.8 },
	Error = { id = "rbxasset://sounds/clickfast.wav", volume = 0.5, pitch = 0.6 },
}

local cache: { [string]: Sound } = {}

local function sfxEnabled(): boolean
	local data = State.data
	return not data or not data.settings or data.settings.sfx ~= false
end

function Sounds.play(name: string, pitchJitter: number?)
	if not sfxEnabled() then
		return
	end
	local def = DEFS[name]
	if not def then
		return
	end
	local sound = cache[name]
	if not sound then
		sound = Instance.new("Sound")
		sound.Name = "Sfx_" .. name
		sound.SoundId = def.id
		sound.Volume = def.volume
		sound.Parent = SoundService
		cache[name] = sound
	end
	sound.PlaybackSpeed = def.pitch + (if pitchJitter then (math.random() - 0.5) * pitchJitter else 0)
	SoundService:PlayLocalSound(sound)
end

local music: Sound? = nil

function Sounds.updateMusic()
	if Theme.MusicId == "" then
		return
	end
	if not music then
		local sound = Instance.new("Sound")
		sound.Name = "Music"
		sound.SoundId = Theme.MusicId
		sound.Looped = true
		sound.Volume = 0.3
		sound.Parent = SoundService
		music = sound
	end
	local data = State.data
	local enabled = not data or data.settings.music ~= false
	local m = music :: Sound
	if enabled and not m.IsPlaying then
		m:Play()
	elseif not enabled and m.IsPlaying then
		m:Stop()
	end
end

return Sounds
