--!strict
--[[
	BuyNext: which of the plot's priced pads the player can pay for right now (pure,
	unit-tested with Lune). Client.Fx.BuyArrows hangs a "BUY!" arrow over each one that has
	just become affordable and points the screen edge at the best one; Client.UI.Hud names
	the best one on the goal strip ("You can afford Buy 25!").

	  affordable  the Buy pads (Buy1 .. Buy100; Buy100 as a Buy Max once Economy.planBuyMax
	              applies, which is always affordable) while the rack can take a unit, and
	              the blender upgrades (ProcUp1, ProcUp10) while the server would sell them:
	              not once the converter is CONVERTER_HEADROOM times faster than the units
	              produce (Server.Tycoon's upgradeNotNeeded refuses them then)
	  best        the biggest affordable Buy pad, else ProcUp1 (nil when neither)
]]

local Economy = require(script.Parent.Economy)

local BuyNext = {}

-- The fields of the State snapshot (or a saved profile) the pick reads.
export type Input = {
	money: number?,
	bought: number?,
	units: { number }?,
	processLevel: number?,
}

-- Every pad the pick looks at, in this order (the order `affordable` lists them in).
BuyNext.PADS = { "Buy1", "Buy5", "Buy25", "Buy100", "ProcUp1", "ProcUp10" }
local UPGRADES = { ProcUp1 = 1, ProcUp10 = Economy.PROCESS_BULK }

local function numbers(data: Input): (number, number, { number }, number)
	local money = tonumber(data.money) or 0
	if money ~= money then
		money = 0
	end
	return money, tonumber(data.bought) or 0, data.units or {}, tonumber(data.processLevel) or 0
end

-- The upgrade pads refuse: the converter already outruns the units (upgradeNotNeeded).
function BuyNext.upgradeNotNeeded(units: { number }, processLevel: number): boolean
	return Economy.processRate(processLevel) >= Economy.CONVERTER_HEADROOM * Economy.productionPerSecond(units)
end

-- The Buy 100 pad sells everything the cash allows (Economy.planBuyMax).
function BuyNext.isBuyMax(data: Input): boolean
	local money, bought, units = numbers(data)
	return Economy.planBuyMax(units, bought, money) ~= nil
end

-- The pads in BuyNext.PADS the cash pays for now, in that order.
function BuyNext.affordable(data: Input): { string }
	local money, bought, units, level = numbers(data)
	local out: { string } = {}
	-- A rack of top-tier units at the cap takes nothing more (the server refuses the pad).
	if Economy.addUnitsCapped(units, 1, 1).accepted > 0 then
		local buyMax = Economy.planBuyMax(units, bought, money) ~= nil
		for _, amount in Economy.BUY_AMOUNTS do
			local name = "Buy" .. amount
			if (name == "Buy100" and buyMax) or Economy.bulkPrice(bought, amount) <= money then
				table.insert(out, name)
			end
		end
	end
	if not BuyNext.upgradeNotNeeded(units, level) then
		for _, name in { "ProcUp1", "ProcUp10" } do
			if Economy.processBulkCost(level, UPGRADES[name]) <= money then
				table.insert(out, name)
			end
		end
	end
	return out
end

-- The one pad worth pointing at: the biggest affordable Buy, else the blender's next level.
function BuyNext.best(data: Input): string?
	local list = BuyNext.affordable(data)
	local pick: string? = nil
	for _, name in list do
		-- The Buy pads come first, small to big: the last one wins, ProcUp1 only without one.
		if string.sub(name, 1, 3) == "Buy" or (name == "ProcUp1" and not pick) then
			pick = name
		end
	end
	return pick
end

-- What a pad is called in a sentence: "Buy 25", "Buy Max", "a faster Blender".
function BuyNext.title(name: string, data: Input): string
	if name == "Buy100" and BuyNext.isBuyMax(data) then
		return "Buy Max"
	elseif string.sub(name, 1, 3) == "Buy" then
		return "Buy " .. string.sub(name, 4)
	end
	return "a faster Blender"
end

return BuyNext
