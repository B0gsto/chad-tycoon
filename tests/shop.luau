--[[
	Unit tests for the fair shop: an aura pack is blended into cash at once
	(src/shared/ShopMath.luau), the receipt handler pays that cash for the aura product ids
	already on sale (src/server/Monetization.luau, run against stub Tycoon / DataService
	tables), and the Shop cards show what the server grants (src/client/UI/Windows.luau).
	Loaded by tests/run.luau with its harness: { test, check, eq }. Run alone with
	`lune run tests/shop` it uses the small harness at the end of this file.
]]

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local process = require("@lune/process")
local task = require("@lune/task")

local Economy = require("../src/shared/Economy")
local Format = require("../src/shared/Format")

local function identity(module: any): any
	return module
end

local function loadShopMath(): any
	local path = "src/shared/ShopMath.luau"
	local env = setmetatable({ script = { Parent = { Economy = Economy } }, require = identity }, { __index = _G })
	return luau.load(fs.readFile(path), { debugName = path, environment = env })()
end

-- The aura packs on sale since the shop opened: a receipt for any of them must keep paying.
local SOLD_AURA_PACKS = {
	{ Id = 3716954009, Price = 49, Seconds = 900, Min = 2500 },
	{ Id = 3716954016, Price = 199, Seconds = 3600, Min = 10000 },
	{ Id = 3716954024, Price = 499, Seconds = 18000, Min = 50000 },
	{ Id = 3716954037, Price = 1000, Seconds = 86400, Min = 250000 },
}
local MONEY_PACKS = {
	{ Id = 3716878815, Price = 49, Seconds = 900, Min = 2500 },
	{ Id = 3716953998, Price = 199, Seconds = 3600, Min = 10000 },
	{ Id = 3716878844, Price = 499, Seconds = 18000, Min = 50000 },
	{ Id = 3716954002, Price = 1000, Seconds = 86400, Min = 250000 },
}

local GRANTED, RETRY = "PurchaseGranted", "NotProcessedYet"

local ran = false

local function suite(h: { [string]: any })
	ran = true
	local test, check, eq = h.test, h.check, h.eq
	local ShopMath = loadShopMath()

	test("Shop: an aura pack's cash", function()
		eq(ShopMath.auraPackCash(3000, 1), 3000 * Economy.CASH_PER_POINT, "no boosts: every point is CASH_PER_POINT")
		eq(ShopMath.auraPackCash(3000, 2), 6000 * Economy.CASH_PER_POINT, "2X Cash doubles it")
		eq(
			ShopMath.auraPackCash(1000, 2 * (1 + 0.5 + Economy.PREMIUM_BONUS)),
			3200 * Economy.CASH_PER_POINT,
			"2X Cash, friends and Premium"
		)
		eq(ShopMath.auraPackCash(0, 3), 0, "nothing in, nothing out")
		eq(ShopMath.auraPackCash(-5, 3), 0, "never negative")
		eq(ShopMath.auraPackCash(3000, 0), 3000 * Economy.CASH_PER_POINT, "a missing multiplier counts as 1")
		eq(ShopMath.auraPackCash(3000, 0.5), 3000 * Economy.CASH_PER_POINT, "a multiplier is never under 1")
		for _, mult in { 1, 1.1, 1.3, 2, 2.2, 3.2 } do
			for _, aura in { 2500, 3333, 10000, 987654321, 2.5e14 } do
				local cash = ShopMath.auraPackCash(aura, mult)
				eq(cash, math.floor(cash), "whole dollars " .. aura .. " x" .. mult)
				check(cash >= aura * Economy.CASH_PER_POINT, "never under the unboosted aura " .. aura .. " x" .. mult)
				check(cash <= aura * Economy.CASH_PER_POINT * mult, "never over aura x multiplier " .. aura .. " x" .. mult)
				check(cash > aura * Economy.CASH_PER_POINT * mult - 1, "within a dollar of aura x multiplier " .. aura .. " x" .. mult)
			end
		end
	end)

	-- E8: the pack used to fill a tank the converter needed up to days to empty. As cash at
	-- once it is worth what that aura would have become, whatever the blender's level, and
	-- never less than the cash pack of the same price.
	test("Shop: an aura pack is never worth less than the same-price cash pack", function()
		for tier = 1, Economy.MAX_TIER do
			for _, level in { 0, 8, 30, 120 } do
				local progression = Economy.progression(tier, level)
				for _, mult in { 1, 2, 2.2 } do
					for _, units in { 0, 1, 40 } do
						local production = Economy.unitRate(tier) * units
						local income = Economy.incomePerSecond(production, Economy.processRate(level), mult)
						for index, pack in SOLD_AURA_PACKS do
							local aura = Economy.auraPackAmount(production, pack.Seconds, pack.Min, progression)
							local cash = ShopMath.auraPackCash(aura, mult)
							local where = string.format("tier %d level %d x%s units %d pack %d", tier, level, tostring(mult), units, index)
							check(cash >= aura * Economy.CASH_PER_POINT, "at least the aura's unboosted cash, " .. where)
							local money = MONEY_PACKS[index]
							local cashPack = Economy.moneyPackAmount(income, money.Seconds, money.Min, progression)
							-- Both round down, at different steps: allow that (under a dollar per
							-- multiplier, and the float grain of amounts past 2^53).
							check(cash >= cashPack * (1 - 1e-12) - 4, "at least the cash pack, " .. where)
						end
					end
				end
				-- The blender's level changes nothing: the same aura pays the same cash.
				local a = ShopMath.auraPackCash(Economy.auraPackAmount(Economy.unitRate(tier) * 7, 3600, 10000, progression), 2)
				local b =
					ShopMath.auraPackCash(Economy.auraPackAmount(Economy.unitRate(tier) * 7, 3600, 10000, Economy.progression(tier, 0)), 2)
				eq(a, b, "independent of the blender level at tier " .. tier)
			end
		end
	end)

	test("Shop: the free gift on its card is the Free pad's", function()
		eq(ShopMath.freeGiftCash(0), Economy.FREE_REWARD_MIN, "the minimum for a new player")
		eq(ShopMath.freeGiftCash(1000), 1000 * Economy.FREE_REWARD_SECONDS, "seconds of income")
		-- The Free pad (Tycoon.luau, not this stream's file) pays this expression: if it changes,
		-- ShopMath.freeGiftCash has to follow.
		local tycoon = fs.readFile("src/server/Tycoon.luau")
		check(
			string.find(tycoon, "math.max(Economy.FREE_REWARD_MIN, Tycoon.income(session) * Economy.FREE_REWARD_SECONDS)", 1, true) ~= nil,
			"Tycoon's Free pad still pays max(FREE_REWARD_MIN, income * FREE_REWARD_SECONDS)"
		)
	end)

	-- Server.Monetization against stub services -----------------------------------------

	local function loadMonetization()
		local log = { money = {}, aura = 0, toasts = {}, saves = 0, shop = {}, saveOk = true }
		local sessions: { [number]: any } = {}
		local Tycoon = {
			hooks = {},
			getSession = function(player)
				return sessions[player.UserId]
			end,
			getSessionByUserId = function(userId)
				return sessions[userId]
			end,
			steadyProduction = function(session)
				return session.production
			end,
			moneyMultiplier = function(session)
				return session.mult
			end,
			income = function(session)
				return Economy.incomePerSecond(session.production, Economy.processRate(session.profile.processLevel), session.mult)
			end,
			grantMoney = function(_, amount)
				table.insert(log.money, amount)
			end,
			grantAura = function()
				log.aura += 1
			end,
			toast = function(_, text)
				table.insert(log.toasts, text)
			end,
			openCrateProduct = function() end,
			refresh = function() end,
			setPass = function() end,
		}
		local signal = { Connect = function() end }
		local marketplace: { [string]: any } = { PromptGamePassPurchaseFinished = signal }
		local services: { [string]: any } = {
			MarketplaceService = marketplace,
			Players = {
				PlayerAdded = signal,
				PlayerRemoving = signal,
				GetPlayers = function()
					return {}
				end,
			},
			PolicyService = {},
			RunService = {
				IsStudio = function()
					return false
				end,
			},
			ReplicatedStorage = { Shared = { Economy = Economy, Format = Format, ShopMath = ShopMath } },
		}
		local env = setmetatable({
			game = {
				GetService = function(_, name)
					return services[name]
				end,
			},
			script = {
				Parent = {
					Analytics = {
						shop = function(_, step)
							table.insert(log.shop, step)
						end,
					},
					DataService = {
						save = function()
							log.saves += 1
							return log.saveOk
						end,
					},
					Tycoon = Tycoon,
				},
			},
			require = identity,
			Enum = { ProductPurchaseDecision = { PurchaseGranted = GRANTED, NotProcessedYet = RETRY } },
			warn = function() end,
		}, { __index = _G })
		local path = "src/server/Monetization.luau"
		local Monetization = luau.load(fs.readFile(path), { debugName = path, environment = env })()
		Monetization.init({
			Monetization = {
				Passes = {},
				MoneyPacks = MONEY_PACKS,
				AuraPacks = SOLD_AURA_PACKS,
				LegacyMoneyPacks = { { Id = 3716878799, Seconds = 300, Min = 750 } },
				CrateOpen = { Id = 3716878870, Price = 30 },
			},
		})
		return marketplace.ProcessReceipt, log, sessions
	end
	local function session(userId: number, tier: number, production: number, mult: number, canSave: boolean): { [string]: any }
		local discovered = table.create(Economy.MAX_TIER, 0)
		for t = 1, tier do
			discovered[t] = 1
		end
		return {
			player = { UserId = userId },
			profile = { discovered = discovered, runDiscovered = table.clone(discovered), processLevel = 12, receipts = {}, carried = 777 },
			production = production,
			mult = mult,
			canSave = canSave,
		}
	end

	test("Shop: an aura receipt pays cash at once, for every product id already sold", function()
		local theme = fs.readFile("src/themes/chad/Theme.luau")
		for index, pack in SOLD_AURA_PACKS do
			-- The product on sale is still the one in the theme, at its price and size.
			local line = string.format("{ Id = %d, Price = %d, Seconds = %d, Min = %d }", pack.Id, pack.Price, pack.Seconds, pack.Min)
			check(string.find(theme, line, 1, true) ~= nil, "the theme still sells aura pack " .. index .. " unchanged")

			local processReceipt, log, sessions = loadMonetization()
			local s = session(7, 9, 4321, 2.2, false)
			sessions[7] = s
			local progression = Economy.progression(9, 12)
			local expected = ShopMath.auraPackCash(Economy.auraPackAmount(4321, pack.Seconds, pack.Min, progression), 2.2)
			eq(processReceipt({ PlayerId = 7, ProductId = pack.Id, PurchaseId = "p" .. index }), GRANTED, "granted " .. index)
			eq(#log.money, 1, "one cash grant " .. index)
			eq(log.money[1], expected, "the cash the card showed " .. index)
			eq(log.aura, 0, "nothing goes into the tank " .. index)
			eq(s.profile.carried, 777, "the tank is untouched " .. index)
			eq(log.toasts[1], "Blended instantly! +" .. Format.money(expected), "toast " .. index)
			eq(s.profile.receipts[1], "p" .. index, "receipt recorded " .. index)
			-- Roblox may deliver the same receipt again: no second payout.
			eq(processReceipt({ PlayerId = 7, ProductId = pack.Id, PurchaseId = "p" .. index }), GRANTED, "repeat granted " .. index)
			eq(#log.money, 1, "paid once " .. index)
		end
	end)

	test("Shop: receipts wait for the player and for the save", function()
		local processReceipt, log, sessions = loadMonetization()
		local pack = SOLD_AURA_PACKS[2]
		eq(processReceipt({ PlayerId = 9, ProductId = pack.Id, PurchaseId = "a" }), RETRY, "no session yet: retried on rejoin")
		eq(#log.money, 0, "nothing paid without a session")
		local s = session(9, 1, 0, 1, true)
		sessions[9] = s
		eq(processReceipt({ PlayerId = 9, ProductId = 123, PurchaseId = "x" }), RETRY, "unknown product")
		eq(#log.money, 0, "an unknown product pays nothing")
		-- A brand-new player gets the pack's floor, as cash.
		log.saveOk = false
		eq(processReceipt({ PlayerId = 9, ProductId = pack.Id, PurchaseId = "a" }), RETRY, "a failed save asks Roblox to retry")
		eq(#log.money, 1, "paid on the first attempt")
		eq(
			log.money[1],
			ShopMath.auraPackCash(Economy.auraPackAmount(0, pack.Seconds, pack.Min, Economy.progression(1, 12)), 1),
			"the floor as cash"
		)
		check(log.money[1] >= pack.Min, "never under the pack's minimum")
		log.saveOk = true
		eq(processReceipt({ PlayerId = 9, ProductId = pack.Id, PurchaseId = "a" }), GRANTED, "the retry only saves")
		eq(#log.money, 1, "and does not pay again")
		-- Cash packs are untouched.
		local money = MONEY_PACKS[1]
		eq(processReceipt({ PlayerId = 9, ProductId = money.Id, PurchaseId = "m" }), GRANTED, "cash pack granted")
		eq(log.money[2], Economy.moneyPackAmount(0, money.Seconds, money.Min, Economy.progression(1, 12)), "cash pack amount unchanged")
		eq(#log.toasts, 1, "only the aura pack says it was blended")
	end)

	test("Shop: the cards show what the server grants", function()
		local server = fs.readFile("src/server/Monetization.luau")
		local client = fs.readFile("src/client/UI/Windows.luau")
		for path, src in { ["Monetization.luau"] = server, ["Windows.luau"] = client } do
			check(string.find(src, "ShopMath.auraPackCash(", 1, true) ~= nil, path .. " turns the pack's aura into cash with ShopMath")
		end
		check(string.find(server, "Tycoon.grantAura(", 1, true) == nil, "the receipt handler no longer fills the tank")
		check(string.find(server, "Tycoon.moneyMultiplier(session)", 1, true) ~= nil, "the server uses the buyer's money multiplier")
		check(string.find(client, "data.moneyMult", 1, true) ~= nil, "the card uses the snapshot's money multiplier")
		check(string.find(client, "data.rewardProduction", 1, true) ~= nil, "the card uses surge-free production")
		check(string.find(client, '"Blended into cash at once"', 1, true) ~= nil, "the Aura section says what a pack does")
		check(string.find(client, "Lands straight in your tank", 1, true) == nil, "no tank promise left in the shop")
		check(string.find(client, "ShopMath.freeGiftCash(", 1, true) ~= nil, "the free card shows the Free pad's amount")
		-- No pressure wording on any shop card.
		for _, word in { "LIMITED", "HURRY", "ONLY TODAY", "LAST CHANCE", "ENDS IN" } do
			check(string.find(client, '"' .. word, 1, true) == nil, "no '" .. word .. "' tag in the windows")
		end
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
