--[[
	Progression simulation of a greedy active player (average deposit multiplier).
	Prints when each tier is first reached, one line per tier.
	Run with:  lune run scripts/simulate [flags]
	  --aura        owns the 2x aura pass
	  --cash        owns the 2x cash pass
	  --extras      a real player's periodic extras: the free reward every 10 minutes,
	                the parkour finish reward once per MODE_REWARD_COOLDOWN, the Aura
	                Surge (2 of every 10 minutes) and the crates from the free unlocker
	  --hours N     simulated hours (default 600)
	The first 2 hours run at 1 s steps, then 10 s up to 24 h, then 60 s.
	The same loop is used by tests/run.luau through Simulate.run.
]]

local Economy = require("../src/shared/Economy")
local Format = require("../src/shared/Format")

local Simulate = {}

-- Values that live outside Economy: a new profile's cash (DataService) and the smallest
-- cash pack (Theme.Monetization.MoneyPacks[1]), which the parkour finish reward pays.
Simulate.START_CASH = 50
Simulate.SMALL_PACK_SECONDS = 300
Simulate.SMALL_PACK_MIN = 750

-- Average seconds one crate takes in the free unlocker (the unlocker is always kept busy).
local function averageUnlockSeconds(): number
	local weights, seconds = 0, 0
	for _, info in Economy.CHEST_INFO do
		weights += info.weight
		seconds += info.weight * info.unlockSeconds
	end
	return seconds / weights
end

export type Options = {
	aura: boolean?,
	cash: boolean?,
	extras: boolean?,
	hours: number?,
	-- Fixed step in seconds for every phase (tests use a coarse one); default is phased.
	step: number?,
}

export type Result = {
	reached: { [number]: number },
	money: number,
	buyTier: number,
	processLevel: number,
	production: number,
}

function Simulate.run(options: Options): Result
	local units = table.create(Economy.MAX_TIER, 0)
	units[1] = 1
	local money = Simulate.START_CASH
	local queue = 0
	local buyTier = 1
	local boughtAtTier = 0
	local processLevel = 0
	local reached: { [number]: number } = { [1] = 0 }
	local highest = 1
	local horizon = (options.hours or 600) * 3600
	local efficiency = 0.85 -- the player is not always on the pads
	local orbMult = if options.aura then 2 else 1
	local cashMult = if options.cash then 2 else 1
	local extras = options.extras == true
	local nextFree = 0
	local nextParkour = 0
	local unlockSeconds = averageUnlockSeconds()
	local nextCrate = unlockSeconds
	local seed = 12345
	local function rng(): number
		seed = (seed * 1103515245 + 12345) % 2147483648
		return seed / 2147483648
	end
	local tutorialPaid = false

	local function record(t: number)
		for tier = 1, Economy.MAX_TIER do
			if units[tier] > 0 and not reached[tier] then
				reached[tier] = t
			end
			if units[tier] > 0 and tier > highest then
				highest = tier
			end
		end
	end
	local function addUnits(tier: number, amount: number, t: number): number
		local result = Economy.addUnitsCapped(units, tier, amount)
		units = result.units
		-- The player merges every pair (by hand or with Auto Merge). A cascade can pass
		-- straight through a tier, so record every tier a merge created.
		local _, _, steps = Economy.mergeAll(units)
		for _, step in result.steps do
			table.insert(steps, step)
		end
		for _, step in steps do
			if not reached[step.tier + 1] then
				reached[step.tier + 1] = t
			end
			highest = math.max(highest, step.tier + 1)
		end
		record(t)
		return result.accepted
	end

	local t = 0
	while t < horizon do
		local dt = options.step or (if t < 2 * 3600 then 1 elseif t < 24 * 3600 then 10 else 60)
		t += dt
		local surge = extras and Economy.surgeState(t)
		local production = Economy.productionPerSecond(units) * efficiency * orbMult * (if surge then Economy.SURGE_MULTIPLIER else 1)
		local rate = Economy.processRate(processLevel)
		queue += production * dt
		local processed = math.min(queue, rate * dt)
		queue -= processed
		money += processed * Economy.CASH_PER_POINT * cashMult
		local income = Economy.incomePerSecond(Economy.productionPerSecond(units) * orbMult, rate, cashMult)

		-- The tutorial (buy, deposit, collect, merge) pays its reward after the first merge.
		if not tutorialPaid and reached[2] then
			tutorialPaid = true
			money += Economy.TUTORIAL_REWARD_CASH
		end
		if extras then
			local progression = Economy.progression(highest, processLevel)
			if t >= nextFree then
				nextFree = t + Economy.FREE_REWARD_COOLDOWN
				money += math.max(Economy.FREE_REWARD_MIN, income * Economy.FREE_REWARD_SECONDS)
			end
			if t >= nextParkour then
				nextParkour = t + Economy.MODE_REWARD_COOLDOWN
				money += Economy.moneyPackAmount(income, Simulate.SMALL_PACK_SECONDS, Simulate.SMALL_PACK_MIN, progression)
			end
			if t >= nextCrate then
				nextCrate = t + unlockSeconds
				local rarity = Economy.rollChestRarity(rng)
				addUnits(Economy.rollChest(rarity, highest, rng), 1, t)
			end
		end

		-- Decide once every 5 seconds (every step when steps are coarser).
		if t % 5 == 0 or dt > 5 then
			for _ = 1, 50 do
				rate = Economy.processRate(processLevel)
				local bottlenecked = Economy.productionPerSecond(units) * efficiency * orbMult > rate * 0.9
				local req = Economy.buyTierRequirement(buyTier)
				local upgradeCost = Economy.buyTierUpgradeCost(buyTier)
				if buyTier < Economy.MAX_BUY_TIER and boughtAtTier >= req and reached[buyTier + 1] and money >= upgradeCost then
					money -= upgradeCost
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
					local accepted = addUnits(buyTier, amount, t)
					if accepted == 0 then
						break
					end
					money -= Economy.bulkPrice(buyTier, boughtAtTier, accepted)
					boughtAtTier += accepted
				else
					break
				end
			end
		end
	end
	return {
		reached = reached,
		money = money,
		buyTier = buyTier,
		processLevel = processLevel,
		production = Economy.productionPerSecond(units),
	}
end

local function main(args: { string })
	local options: Options = {}
	local i = 1
	while i <= #args do
		local a = args[i]
		if a == "--aura" then
			options.aura = true
		elseif a == "--cash" then
			options.cash = true
		elseif a == "--extras" then
			options.extras = true
		elseif a == "--hours" then
			i += 1
			options.hours = tonumber(args[i])
		end
		i += 1
	end
	local result = Simulate.run(options)
	print(
		string.format(
			"aura %s, cash %s, extras %s, %d h",
			if options.aura then "2x" else "1x",
			if options.cash then "2x" else "1x",
			if options.extras then "on" else "off",
			options.hours or 600
		)
	)
	for tier = 1, Economy.MAX_TIER do
		local at = result.reached[tier]
		local text = "not reached"
		if at then
			text = if at < 3600 then string.format("%6.1f min", at / 60) else string.format("%6.1f h", at / 3600)
		end
		print(string.format("Tier %2d  %s", tier, text))
	end
	print(
		string.format(
			"End: money %s, buy tier %d, process lv %d, production %s/s",
			Format.short(result.money),
			result.buyTier,
			result.processLevel,
			Format.short(result.production)
		)
	)
end

-- tests/run.luau sets SIMULATE_AS_LIBRARY before requiring this file to get Simulate.run
-- without the printed run.
if not (_G :: any).SIMULATE_AS_LIBRARY then
	main(require("@lune/process").args)
end

return Simulate
