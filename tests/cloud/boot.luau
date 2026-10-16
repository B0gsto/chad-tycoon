--!nocheck
-- The published place boots on a real Roblox server. Place scripts do not run inside a Luau Execution session, so
-- this test runs Server.Boot.start() itself (the exact start-up Main.server.luau runs), then checks the remotes
-- (src/shared/Net.luau), the map with its 6 plots, and that the server log has no errors.
local LogService = game:GetService("LogService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace = game:GetService("Workspace")

local PLOT_COUNT = 6 -- src/server/World/Common.luau

T.test("server scripts are in the place", function()
	local server = T.ok(ServerScriptService:FindFirstChild("Server"), "ServerScriptService.Server is missing")
	local main = T.ok(server:FindFirstChild("Main"), "ServerScriptService.Server.Main is missing")
	T.ok(main:IsA("Script"), "Server.Main is a " .. main.ClassName .. ", not a Script")
	T.ok(main.Enabled, "Server.Main is disabled")
end)

T.test("Boot.start() runs without errors", function()
	local Boot = require(ServerScriptService.Server.Boot)
	local world = Boot.start()
	T.ok(world ~= nil, "Boot.start() returned no world")
end)

T.test("remotes exist", function()
	local remotes = T.waitFor(function()
		return ReplicatedStorage:FindFirstChild("Remotes")
	end, 30)
	T.ok(remotes, "ReplicatedStorage.Remotes never appeared in 30 s: Main.server.luau not created by Boot.start()")
	for _, name in { "State", "Notify", "Effect", "Action" } do
		local r = remotes:FindFirstChild(name)
		T.ok(r and r:IsA("RemoteEvent"), "Remotes." .. name .. " is missing or not a RemoteEvent")
	end
	local q = remotes:FindFirstChild("Query")
	T.ok(q and q:IsA("RemoteFunction"), "Remotes.Query is missing or not a RemoteFunction")
end)

T.test("world built: Workspace.Map with " .. PLOT_COUNT .. " plots", function()
	local map = T.waitFor(function()
		return Workspace:FindFirstChild("Map")
	end, 30)
	T.ok(map, "Workspace.Map never appeared: WorldBuilder.build did not run in Boot.start()")
	local plots = T.waitFor(function()
		for i = 1, PLOT_COUNT do
			if not map:FindFirstChild("Plot" .. i) then
				return nil
			end
		end
		return true
	end, 30)
	T.ok(plots, "not every Plot1..Plot" .. PLOT_COUNT .. " exists in Workspace.Map")
	T.ok(map:FindFirstChild("Plot" .. (PLOT_COUNT + 1)) == nil, "more plots than " .. PLOT_COUNT)
	for i = 1, PLOT_COUNT do
		local n = #map["Plot" .. i]:GetDescendants()
		T.ok(n >= 50, "Plot" .. i .. " has only " .. n .. " descendants")
	end
end)

T.test("no errors in the server log", function()
	task.wait(2) -- let the boot finish its first frames
	local errors = {}
	for _, entry in LogService:GetLogHistory() do
		if entry.messageType == Enum.MessageType.MessageError then
			table.insert(errors, entry.message)
		end
	end
	if #errors > 0 then
		error(#errors .. " error(s) in the server log:\n  " .. table.concat(errors, "\n  "), 0)
	end
end)
