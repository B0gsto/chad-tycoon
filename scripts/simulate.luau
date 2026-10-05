--[[
	Rough progression simulation of a greedy player (no passes, average
	deposit multiplier, ignores crates). Prints when each tier is first reached.
	Run with:  lune run scripts/simulate
]]

local Economy = require("../src/shared/Economy")
local Format = require("../src/shared/Format")

local units = table.create(Economy.MAX_TIER, 0)
units[1] = 1
local money = 50
local queue = 0
local buyTier = 1
local boughtAtTier = 0
local processLevel = 0
local reached = { [1] = 0 }
local HOURS = 60
local efficiency = 0.85 -- the player is not always on the pads

for t = 1, HOURS * 3600 do
	local production = Economy.productionPerSecond(units) * efficiency
	queue += production
	local processed = math.min(queue, Economy.processRate(processLevel))
	queue -= processed
	money += processed

	-- Decide once every 5 seconds.
	if t % 5 == 0 then
		for _ = 1, 50 do
			local rate = Economy.processRate(processLevel)
			local bottlenecked = production > rate * 0.9
			local req = Economy.buyTierRequirement(buyTier)
			if buyTier < Economy.MAX_BUY_TIER and boughtAtTier >= req and money >= Economy.buyTierUpgradeCost(buyTier) then
				money -= Economy.buyTierUpgradeCost(buyTier)
				buyTier += 1
				boughtAtTier = 0
			elseif bottlenecked and money >= Economy.processUpgradeCost(processLevel) then
				money -= Economy.processUpgradeCost(processLevel)
				processLevel += 1
			elseif not bottlenecked and money >= Economy.bulkPrice(buyTier, boughtAtTier, 1) then
				local amount = 1
				for _, a in { 100, 25, 5 } do
					if money >= Economy.bulkPrice(buyTier, boughtAtTier, a) then
						amount = a
						break
					end
				end
				money -= Economy.bulkPrice(buyTier, boughtAtTier, amount)
				units[buyTier] += amount
				boughtAtTier += amount
				Economy.mergeAll(units)
			else
				break
			end
		end
		for tier = 1, Economy.MAX_TIER do
			if units[tier] > 0 and not reached[tier] then
				reached[tier] = t
			end
		end
	end
end

for tier = 1, Economy.MAX_TIER do
	local at = reached[tier]
	print(string.format("Tier %2d  %s", tier, if at then string.format("%6.1f min", at / 60) else "not reached"))
end
print(
	string.format(
		"After %dh: money %s, buy tier %d, process lv %d, production %s/s",
		HOURS,
		Format.short(money),
		buyTier,
		processLevel,
		Format.short(Economy.productionPerSecond(units))
	)
)
