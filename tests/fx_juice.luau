--[[
	Every game script still compiles the way Roblox Studio compiles it (debug level 2, where
	each local keeps its register). scripts/check.sh type-checks but never compiles, so a chunk
	with more than 200 locals ("Out of local registers") passes it and then fails to load in
	the game; the Fx modules (src/client/Fx/Machines.luau above all) sit close to that limit.
	Loaded by tests/run.luau with its harness: { test, check }.
]]

local fs = require("@lune/fs")
local luau = require("@lune/luau")

return function(h: { [string]: any })
	local test, check = h.test, h.check

	local function scripts(dir: string, out: { string }): { string }
		for _, name in fs.readDir(dir) do
			local path = dir .. "/" .. name
			if fs.isDir(path) then
				scripts(path, out)
			elseif string.sub(name, -5) == ".luau" then
				table.insert(out, path)
			end
		end
		return out
	end

	test("every script compiles with full debug info (200 locals per chunk)", function()
		local paths = scripts("src", {})
		check(#paths > 50, "found the game's scripts")
		for _, path in paths do
			local ok, err = pcall(luau.compile, fs.readFile(path), { optimizationLevel = 1, debugLevel = 2 })
			check(ok, path .. ": " .. string.sub(tostring(err), 1, 160))
		end
	end)
end
