-- Server entry point: builds the map, wires services and handles join/leave/saving.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Theme = require(ReplicatedStorage:WaitForChild("Theme"))
local Net = require(ReplicatedStorage.Shared.Net)

local Server = script.Parent
local DataService = require(Server.DataService)
local WorldBuilder = require(Server.WorldBuilder)
local Tycoon = require(Server.Tycoon)
local Monetization = require(Server.Monetization)
local Ranking = require(Server.Ranking)
local Tutorial = require(Server.Tutorial)

local AUTOSAVE_SECONDS = 90

-- Create remotes before anything else so clients never wait long.
Net.event("State")

local world = WorldBuilder.build(Theme)
Tycoon.init(world, Theme)
Tutorial.init()
Monetization.init(Theme)
Ranking.init(Theme, world.ranking)

local saving: { [Player]: boolean } = {}

local function saveSession(session: Tycoon.Session)
	if session.canSave then
		DataService.save(session.player, session.profile)
	end
end

local function onPlayerAdded(player: Player)
	local profile, canSave = DataService.load(player)
	if not player.Parent then
		return
	end
	if not profile then
		player:Kick("We couldn't load your save right now. Please rejoin in a moment - your progress is safe.")
		return
	end
	local passes = Monetization.ownedPasses(player)
	if not player.Parent then
		return
	end
	Tycoon.addPlayer(player, profile, canSave, passes)
end

local function onPlayerRemoving(player: Player)
	local session = Tycoon.removePlayer(player)
	if session and not saving[player] then
		saving[player] = true
		saveSession(session)
		saving[player] = nil
	end
end

Players.PlayerAdded:Connect(onPlayerAdded)
Players.PlayerRemoving:Connect(onPlayerRemoving)
for _, player in Players:GetPlayers() do
	task.spawn(onPlayerAdded, player)
end

task.spawn(function()
	while true do
		task.wait(AUTOSAVE_SECONDS)
		for player, session in Tycoon.allSessions() do
			if not saving[player] then
				task.spawn(saveSession, session)
			end
		end
	end
end)

game:BindToClose(function()
	local pending = 0
	for player, session in Tycoon.allSessions() do
		pending += 1
		saving[player] = true
		task.spawn(function()
			saveSession(session)
			pending -= 1
		end)
	end
	Ranking.writeScores()
	local deadline = os.clock() + 25
	while pending > 0 and os.clock() < deadline do
		task.wait(0.1)
	end
end)
