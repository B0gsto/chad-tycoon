--!nocheck
-- DataService saves and loads a profile through the test universe's real DataStore (TycoonProfiles_v1), with the
-- session lock, for a fake negative user id that no real player can have. The key is removed afterwards.
-- Only on the test experience: the live game's DataStore holds real players' saves.
local DataStoreService = game:GetService("DataStoreService")
local ServerScriptService = game:GetService("ServerScriptService")

T.test("profile save + load round trip in the real DataStore", function()
	if T.meta.target ~= "test" then
		T.skip("writes a DataStore key: runs on the test experience only")
	end
	local DataService = require(ServerScriptService.Server.DataService)
	local userId = -(1000000000 + math.random(1, 899999999))
	local fake = { UserId = userId, Name = "CloudTest" .. -userId, Parent = game }
	local key = "u_" .. userId
	local store = DataStoreService:GetDataStore("TycoonProfiles_v1")
	local ok, err = pcall(function()
		local profile, canSave = DataService.load(fake)
		T.ok(profile, "DataService.load returned no profile (DataStore unavailable?)")
		T.ok(canSave, "DataService.load says the profile cannot be saved")
		T.eq(profile.totalObtained, 1, "a new profile starts with one Chad")
		profile.money = 123456
		profile.bought = 7
		local saved, lost = DataService.save(fake, profile, true)
		T.ok(saved, "DataService.save failed")
		T.ok(not lost, "DataService.save says another server owns the save")
		local again = DataService.load(fake)
		T.ok(again, "second load returned no profile")
		T.eq(again.money, 123456, "money after the round trip")
		T.eq(again.bought, 7, "bought after the round trip")
		local raw = store:GetAsync(key)
		T.ok(type(raw) == "table" and raw._lock ~= nil, "the stored save has no session lock after load")
	end)
	pcall(function()
		store:RemoveAsync(key)
	end)
	if not ok then
		error(err, 0)
	end
end)
