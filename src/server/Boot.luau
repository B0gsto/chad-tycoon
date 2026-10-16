-- Server start-up: creates the remotes, builds the map and initialises every service, in this order.
-- Main.server.luau calls it once; tests/cloud/boot.luau calls the same function, because place scripts do not
-- run inside an Open Cloud Luau Execution session.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Theme = require(ReplicatedStorage:WaitForChild("Theme"))
local Net = require(ReplicatedStorage.Shared.Net)

local Server = script.Parent
local WorldBuilder = require(Server.WorldBuilder)
local Tycoon = require(Server.Tycoon)
local Monetization = require(Server.Monetization)
local Ranking = require(Server.Ranking)
local Tutorial = require(Server.Tutorial)
local Intro = require(Server.Intro)
local GameModes = require(Server.GameModes)
local Cosmetics = require(Server.Cosmetics)
local Analytics = require(Server.Analytics)
local Badges = require(Server.Badges)
local Daily = require(Server.Daily)
local TestBridge = require(Server.TestBridge)

local Boot = {}

function Boot.start()
	-- Create remotes before anything else so clients never wait long.
	Net.event("State")

	local world = WorldBuilder.build(Theme)
	Tycoon.init(world, Theme)
	Tutorial.init()
	Intro.init()
	Monetization.init(Theme)
	GameModes.init(world.modes, Theme, Tycoon, world)
	Cosmetics.init(Theme)
	Ranking.init(Theme, world.ranking)
	Analytics.init()
	Badges.init(Theme)
	Daily.init(Theme)
	-- Agent playtest bridge: does nothing outside the TEST experience (Shared.TestEnv).
	TestBridge.init(world)
	return world
end

return Boot
