--[[
	Unit tests for "what to buy next" (src/shared/BuyNext.luau): the pads the cash pays for,
	Buy Max on the Buy 100 pad, the blender upgrades the server would refuse, the best pick
	and its name; then (source checks: they need a live client) that the HUD's goal strip,
	the guide and the arrows use it.
	Loaded by tests/run.luau with its harness: { test, check, eq, loadShared }. Run alone with
	`lune run tests/buy_next` it uses the small harness at the end of this file.
]]

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local process = require("@lune/process")
local task = require("@lune/task")

-- src/shared modules with `require(script.Parent.X)` resolved (as tests/run.luau's loadShared).
local sharedCache: { [string]: any } = {}
local function loadShared(name: string): any
	if sharedCache[name] == nil then
		local env: { [string]: any } = setmetatable({}, { __index = _G }) :: any
		env.script = {
			Parent = setmetatable({}, {
				__index = function(_, child)
					return child
				end,
			}),
		}
		env.require = loadShared
		local path = "src/shared/" .. name .. ".luau"
		sharedCache[name] = luau.load(fs.readFile(path), { debugName = path, environment = env })()
	end
	return sharedCache[name]
end

local ran = false

local function suite(h: { [string]: any })
	ran = true
	local test, check, eq = h.test, h.check, h.eq
	local load = h.loadShared or loadShared
	local BuyNext = load("BuyNext")
	local Economy = load("Economy")

	local TOP = Economy.MAX_TIER
	local function rack(counts: { [number]: number }?): { number }
		local units = table.create(TOP, 0)
		for tier, count in counts or {} do
			units[tier] = count
		end
		return units
	end
	-- A fresh plot: a few tier-3 units, the starting blender level, `money` cash.
	local function snapshot(money: number, bought: number?, units: { number }?, level: number?): { [string]: any }
		return {
			money = money,
			bought = bought or 8,
			units = units or rack({ [3] = 2 }),
			processLevel = level or Economy.START_PROCESS_LEVEL,
		}
	end
	local function has(list: { string }, name: string): boolean
		return table.find(list, name) ~= nil
	end
	local function joined(list: { string }): string
		return table.concat(list, ",")
	end
	-- A blender level slower than the units: the upgrades are on sale.
	local function slowLevel(units: { number }): number
		local level = 0
		while not BuyNext.upgradeNotNeeded(units, level + 1) do
			level += 1
		end
		return math.max(0, level - 3)
	end

	test("BuyNext: affordable lists exactly the pads the cash pays for", function()
		local units = rack({ [6] = 3 })
		local level = slowLevel(units)
		check(not BuyNext.upgradeNotNeeded(units, level), "the test blender is slow enough to sell upgrades")
		eq(joined(BuyNext.affordable(snapshot(0, 8, units, level))), "", "no cash, nothing")
		for _, amount in Economy.BUY_AMOUNTS do
			local price = Economy.bulkPrice(8, amount)
			local list = BuyNext.affordable(snapshot(price, 8, units, level))
			check(has(list, "Buy" .. amount), "exactly the price of Buy " .. amount .. " pays for it")
			check(not has(BuyNext.affordable(snapshot(price - 1, 8, units, level)), "Buy" .. amount), "a dollar short of Buy " .. amount)
			for _, other in Economy.BUY_AMOUNTS do
				eq(has(list, "Buy" .. other), other <= amount, string.format("with Buy %d's price, Buy %d", amount, other))
			end
		end
		for name, amount in { ProcUp1 = 1, ProcUp10 = Economy.PROCESS_BULK } do
			local cost = Economy.processBulkCost(level, amount)
			check(has(BuyNext.affordable(snapshot(cost, 8, units, level)), name), name .. " at its exact cost")
			check(not has(BuyNext.affordable(snapshot(cost * 0.999, 8, units, level)), name), name .. " just short")
		end
		eq(
			joined(BuyNext.affordable(snapshot(1e30, 8, units, level))),
			"Buy1,Buy5,Buy25,Buy100,ProcUp1,ProcUp10",
			"everything, in pad order"
		)
		eq(#BuyNext.affordable({}), 0, "an empty snapshot: nothing")
		eq(#BuyNext.affordable(snapshot(0 / 0, 8, units, level)), 0, "NaN cash: nothing")
	end)

	test("BuyNext: Buy Max makes the Buy 100 pad affordable", function()
		local bought = Economy.BUY_MAX_FROM
		local units = rack({ [9] = 1 })
		local money = Economy.bulkPrice(bought, Economy.BUY_MAX_MIN)
		local data = snapshot(money, bought, units, slowLevel(units))
		check(BuyNext.isBuyMax(data), "planBuyMax applies")
		check(has(BuyNext.affordable(data), "Buy100"), "Buy 100 is the Buy Max and affordable")
		eq(BuyNext.best(data), "Buy100", "Buy Max is the best pick")
		eq(BuyNext.title("Buy100", data), "Buy Max", "named Buy Max")
		-- Before BUY_MAX_FROM units are bought the pad is a plain Buy 100 at its own price.
		local early = snapshot(Economy.bulkPrice(10, 100) - 1, 10, units, slowLevel(units))
		check(not BuyNext.isBuyMax(early), "no Buy Max early on")
		check(not has(BuyNext.affordable(early), "Buy100"), "a dollar short of a plain Buy 100")
		eq(BuyNext.title("Buy100", early), "Buy 100", "named Buy 100")
	end)

	test("BuyNext: upgrades the server would refuse are not affordable", function()
		local units = rack({ [2] = 1 })
		local level = 0
		while not BuyNext.upgradeNotNeeded(units, level) do
			level += 1
		end
		eq(
			BuyNext.upgradeNotNeeded(units, level),
			Economy.processRate(level) >= Economy.CONVERTER_HEADROOM * Economy.productionPerSecond(units),
			"mirrors the server's rule"
		)
		local list = BuyNext.affordable(snapshot(1e30, 8, units, level))
		check(not has(list, "ProcUp1") and not has(list, "ProcUp10"), "not needed: neither upgrade pad")
		check(has(list, "Buy1"), "the Buy pads still are")
		local slower = BuyNext.affordable(snapshot(1e30, 8, units, level - 1))
		check(has(slower, "ProcUp1"), "a level lower the upgrade is on sale again")
		-- No units at all: no production, so the blender never needs to be faster.
		check(not has(BuyNext.affordable(snapshot(1e30, 8, rack(), 0)), "ProcUp1"), "an empty rack needs no upgrade")
	end)

	test("BuyNext: a full rack of the top tier buys nothing", function()
		local full = rack({ [TOP] = Economy.UNIT_CAP })
		local list = BuyNext.affordable(snapshot(1e300, 1e9, full, 0))
		check(not has(list, "Buy1") and not has(list, "Buy100"), "no Buy pad on a full top-tier rack")
		local roomy = rack({ [TOP] = Economy.UNIT_CAP - 1 })
		check(has(BuyNext.affordable(snapshot(1e300, 1e9, roomy, 0)), "Buy1"), "one free slot takes a unit")
	end)

	test("BuyNext: best is the biggest Buy, else the next blender level", function()
		local units = rack({ [6] = 3 })
		local level = slowLevel(units)
		eq(BuyNext.best(snapshot(0, 8, units, level)), nil, "nothing affordable: no pick")
		eq(BuyNext.best(snapshot(Economy.bulkPrice(8, 5), 8, units, level)), "Buy5", "Buy 5's price: Buy 5")
		eq(BuyNext.best(snapshot(Economy.bulkPrice(8, 25), 8, units, level)), "Buy25", "Buy 25's price: Buy 25")
		eq(BuyNext.best(snapshot(1e30, 8, units, level)), "Buy100", "rich: Buy 100")
		-- A rack that takes nothing more and a slow blender: the upgrade.
		local full = rack({ [TOP] = Economy.UNIT_CAP })
		local fullLevel = slowLevel(full)
		eq(BuyNext.best(snapshot(1e300, 1e9, full, fullLevel)), "ProcUp1", "full rack: the blender")
		eq(BuyNext.title("Buy25", {}), "Buy 25", "Buy 25's name")
		eq(BuyNext.title("ProcUp1", {}), "a faster Blender", "the upgrade's name")
	end)

	test("BuyNext: the HUD, the guide and the arrows use it", function()
		local hud = fs.readFile("src/client/UI/Hud.luau")
		local guide = fs.readFile("src/client/Guide.luau")
		local arrows = fs.readFile("src/client/Fx/BuyArrows.luau")
		local main = fs.readFile("src/client/Main.client.luau")
		local function contains(source: string, text: string): boolean
			return string.find(source, text, 1, true) ~= nil
		end
		check(contains(hud, 'kind = "afford"'), "the goal strip has an afford nearer goal")
		check(contains(hud, "BuyNext.best("), "it names BuyNext's best pad")
		check(contains(guide, "function Guide.current()"), "the guide says what it marks")
		check(contains(guide, "PadLabel"), "the marker clears the pad's label")
		check(contains(arrows, "BuyNext.affordable("), "the arrows follow the affordable set")
		check(contains(arrows, "Guide.current()"), "and skip the pad the guide marks")
		check(contains(arrows, "tutorialDone ~= true"), "none during the tutorial")
		check(contains(main, '"BuyArrows"'), "Main starts the arrows")
	end)
end

-- Run alone: tests/run.luau calls the returned function at once; when nobody has by the time
-- this file is done, run it here.
task.defer(function()
	if ran then
		return
	end
	local passed, failed = 0, 0
	local current = ""
	local function check(condition: boolean, message: string)
		if condition then
			passed += 1
		else
			failed += 1
			print(string.format("  FAIL [%s] %s", current, message))
		end
	end
	suite({
		check = check,
		eq = function(actual: any, expected: any, message: string?)
			check(actual == expected, string.format("%s: expected %s, got %s", message or "value", tostring(expected), tostring(actual)))
		end,
		test = function(name: string, fn: () -> ())
			current = name
			local ok, err = pcall(fn)
			if not ok then
				failed += 1
				print(string.format("  ERROR [%s] %s", name, tostring(err)))
			end
		end,
	})
	print(string.format("\n%d passed, %d failed", passed, failed))
	if failed > 0 then
		process.exit(1)
	end
end)

return suite
