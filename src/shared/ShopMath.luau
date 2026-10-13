--!strict
--[[
	ShopMath: amounts the Shop shows that are not a pack size in Economy (no Roblox
	dependencies, unit-tested with Lune: tests/shop.luau). The server grants and the Shop
	cards show with the same functions, so a card is exactly what the player gets.
]]

local Economy = require(script.Parent.Economy)

local ShopMath = {}

-- Aura pack: its `aura` (Economy.auraPackAmount) goes through the blender at once. Every
-- point is CASH_PER_POINT cash times the buyer's money multiplier (2X Cash, friends,
-- Premium: Tycoon.moneyMultiplier, the snapshot's `moneyMult`), in whole dollars. No
-- Deposit Bonus roll and no converter queue: the amount does not depend on luck or on the
-- blender's level.
function ShopMath.auraPackCash(aura: number, moneyMult: number): number
	return math.floor(math.max(0, aura) * Economy.CASH_PER_POINT * math.max(1, moneyMult))
end

-- The free gift's cash for a surge-free `income` (Tycoon's Free pad pays the same).
function ShopMath.freeGiftCash(income: number): number
	return math.max(Economy.FREE_REWARD_MIN, income * Economy.FREE_REWARD_SECONDS)
end

return ShopMath
