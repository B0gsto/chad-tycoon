--!nocheck
-- Shared modules load on a live server and their numbers are sane; every game pass and developer product id in
-- Theme.Monetization exists on Roblox, is for sale and costs what the shop shows.
local MarketplaceService = game:GetService("MarketplaceService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Economy = require(ReplicatedStorage.Shared.Economy)
local Theme = require(ReplicatedStorage.Theme)

T.test("Economy rates and prices are finite and grow", function()
	local last = 0
	for tier = 1, Economy.MAX_TIER do
		local rate = Economy.unitRate(tier)
		T.ok(rate == rate and rate < math.huge and rate > last, "unitRate(" .. tier .. ") = " .. tostring(rate))
		last = rate
	end
	local lastPrice = 0
	for bought = 0, 500, 25 do
		local price = Economy.unitPrice(bought)
		T.ok(price == price and price >= lastPrice and price > 0, "unitPrice(" .. bought .. ") = " .. tostring(price))
		lastPrice = price
	end
	T.eq(Economy.bulkPrice(10, 1), Economy.unitPrice(10), "bulkPrice(10, 1)")
end)

local function info(id, infoType)
	local lastErr
	for attempt = 1, 3 do
		local ok, result = pcall(MarketplaceService.GetProductInfo, MarketplaceService, id, infoType)
		if ok then
			return result
		end
		lastErr = result
		task.wait(attempt)
	end
	error(lastErr, 0)
end

local function checkAll(items, infoType)
	local problems = {}
	for name, item in items do
		local ok, result = pcall(info, item.Id, infoType)
		if not ok then
			table.insert(problems, string.format("%s (%d): %s", tostring(name), item.Id, tostring(result)))
		elseif result.IsForSale == false then
			table.insert(problems, string.format("%s (%d): not for sale", tostring(name), item.Id))
		elseif item.Price and result.PriceInRobux ~= item.Price then
			table.insert(
				problems,
				string.format("%s (%d): Roblox price %s, shop shows %d", tostring(name), item.Id, tostring(result.PriceInRobux), item.Price)
			)
		end
	end
	if #problems > 0 then
		error(table.concat(problems, "\n  "), 0)
	end
end

T.test("game passes exist, are for sale, prices match", function()
	checkAll(Theme.Monetization.Passes, Enum.InfoType.GamePass)
end)

T.test("developer products exist, are for sale, prices match", function()
	local m = Theme.Monetization
	local items = { CrateOpen = m.CrateOpen }
	for i, p in m.MoneyPacks do
		items["MoneyPacks[" .. i .. "]"] = p
	end
	for i, p in m.AuraPacks do
		items["AuraPacks[" .. i .. "]"] = p
	end
	checkAll(items, Enum.InfoType.Product)
end)
