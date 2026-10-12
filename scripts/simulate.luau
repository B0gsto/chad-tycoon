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
	  --first       the first minutes instead: a new player who follows the tutorial and then
	                walks the loop between the real pads (Simulate.firstMinutes), in seconds
	                from the end of the intro
	  --minutes N   length of the --first run (default 10)
	The first 2 hours run at 1 s steps, then 10 s up to 24 h, then 60 s.
	The same loops are used by tests/run.luau through Simulate.run and Simulate.firstMinutes.
]]

local Economy = require("../src/shared/Economy")
local Format = require("../src/shared/Format")
local Layout = require("../src/server/PlotLayout")
local Timeline = require("../src/client/Intro/Timeline")

local Simulate = {}

-- Values that live outside Economy: the smallest cash pack
-- (Theme.Monetization.MoneyPacks[1]), which the parkour finish reward pays.
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
	processLevel: number,
	production: number,
}

function Simulate.run(options: Options): Result
	local units = table.create(Economy.MAX_TIER, 0)
	units[1] = 1
	local money = Economy.START_CASH
	local queue = 0
	local boughtUnits = 0
	local processLevel = Economy.START_PROCESS_LEVEL
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
				if bottlenecked and money >= Economy.processUpgradeCost(processLevel) then
					money -= Economy.processUpgradeCost(processLevel)
					processLevel += 1
				elseif not bottlenecked and money >= Economy.bulkPrice(boughtUnits, 1) then
					local amount = 1
					for _, a in { 100, 25, 5 } do
						if money >= Economy.bulkPrice(boughtUnits, a) then
							amount = a
							break
						end
					end
					local accepted = addUnits(1, amount, t)
					if accepted == 0 then
						break
					end
					money -= Economy.bulkPrice(boughtUnits, accepted)
					boughtUnits += accepted
				else
					break
				end
			end
		end
	end
	return {
		reached = reached,
		money = money,
		processLevel = processLevel,
		production = Economy.productionPerSecond(units),
	}
end

-- First minutes --------------------------------------------------------------------------

-- Humanoid walk speed (studs per second) and how much longer a real path is than the
-- straight legs below (stairs, turning, overshooting a pad).
Simulate.WALK_SPEED = 16
Simulate.PATH_SLACK = 1.15
-- Seconds a new player needs to look around when control starts, to read each tutorial
-- step, and to step off a buy pad and on again for one more purchase.
Simulate.FIRST_LOOK = 4
Simulate.STEP_READ = 2
Simulate.REBUY = 1

export type FirstOptions = {
	minutes: number?,
	-- Seconds the starter unit has been dropping orbs before the player gets control
	-- (default: the whole intro).
	introSeconds: number?,
}

export type FirstEvent = { t: number, what: string }

export type FirstResult = {
	reached: { [number]: number },
	tutorialDone: number?,
	-- Longest wait between two purchases from the first one to `gapUntil` seconds, and when
	-- that wait started.
	longestGap: number,
	gapAt: number,
	gapUntil: number,
	-- When each purchase (units, converter) was made.
	purchases: { number },
	events: { FirstEvent },
	money: number,
	processLevel: number,
}

local function distance(a: { x: number, z: number }, b: { x: number, z: number }): number
	return math.sqrt((a.x - b.x) ^ 2 + (a.z - b.z) ^ 2)
end

-- Straight-line legs between the stops of the loop, from the real plot layout. The pen is
-- crossed from the +X stairs (by the buy pads) to the -X stairs (by the converter); a walk
-- from the entrance side of the plot to the buy pads goes around the pen's front corner.
local function legs(): { [string]: number }
	local pads = Layout.PADS
	local stairOut = Layout.POOL.maxX + 3 * Layout.STAIR_RUN
	local stairZ = (Layout.PEN_STAIRS[1].rect.minZ + Layout.PEN_STAIRS[1].rect.maxZ) / 2
	local left = { x = stairOut, z = stairZ }
	local right = { x = -stairOut, z = stairZ }
	local corner = { x = stairOut, z = Layout.POOL.minZ - 2 }
	local cross = distance(left, right) + 4 -- a small weave to reach orbs along both walls
	return {
		SpawnBuy = distance(Layout.SPAWN, corner) + distance(corner, pads.Buy1),
		BuyPen = distance(pads.Buy1, left) + cross,
		BuyMerge = distance(pads.Buy1, corner) + distance(corner, pads.Merge),
		MergePen = distance(pads.Merge, left) + cross,
		PenDeposit = distance(right, pads.Deposit) - pads.Deposit.sizeZ / 2,
		PenProcUp = distance(right, pads.ProcUp1),
		ProcUpDeposit = distance(pads.ProcUp1, pads.Deposit) - pads.Deposit.sizeX / 2,
		DepositCollect = distance(pads.Deposit, pads.Collect) - pads.Deposit.sizeZ / 2,
		CollectMerge = distance(pads.Collect, pads.Merge),
		CollectBuy = distance(pads.Collect, corner) + distance(corner, pads.Buy1),
		-- No cash for a unit yet: back into the pen by the near stairs and out again.
		CollectPen = distance(pads.Collect, right) + cross,
		BuyPad = distance(pads.Buy1, pads.Buy5),
	}
end

-- A new player from the moment the intro ends: does the five tutorial steps in order, then
-- keeps walking the loop (buy what the cash allows, merge, pen, deposit, collect). No
-- passes, no free gift, no crates, the average deposit multiplier (x1). Orbs drop and the
-- converter works once a second, like Tycoon's slow tick.
function Simulate.firstMinutes(options: FirstOptions?): FirstResult
	local opts: FirstOptions = options or {}
	local horizon = (opts.minutes or 10) * 60
	local leg = legs()
	local speed = Simulate.WALK_SPEED / Simulate.PATH_SLACK

	local units = table.create(Economy.MAX_TIER, 0)
	units[1] = 1
	local money = Economy.START_CASH
	local pen = (opts.introSeconds or Timeline.total()) * Economy.unitRate(1)
	local carried, queue, pending = 0, 0, 0
	local boughtUnits = 0
	local processLevel = Economy.START_PROCESS_LEVEL
	local tutorialDone: number? = nil
	local reached: { [number]: number } = { [1] = 0 }
	local events: { FirstEvent } = {}
	local gapUntil = math.min(horizon, 360)
	local purchases: { number } = {}
	local lastBuy: number? = nil
	local longestGap, gapAt = 0, 0

	local t, nextTick = 0, 1
	local function wait(seconds: number)
		t += seconds
		while nextTick <= t do
			nextTick += 1
			pen += Economy.productionPerSecond(units)
			local processed = math.min(queue, Economy.processRate(processLevel))
			queue -= processed
			pending += processed * Economy.CASH_PER_POINT
		end
	end
	local function walk(name: string)
		wait(leg[name] / speed)
	end
	local function log(what: string)
		table.insert(events, { t = t, what = what })
	end
	local function bought()
		if lastBuy and lastBuy < gapUntil and t - lastBuy > longestGap then
			longestGap, gapAt = t - lastBuy, lastBuy
		end
		lastBuy = t
		table.insert(purchases, t)
	end

	local function pickup()
		carried += pen
		pen = 0
	end
	local function deposit()
		-- The tutorial's deposit becomes cash at once (TutorialSteps.instantDeposit).
		if not tutorialDone then
			pending += carried * Economy.CASH_PER_POINT
		else
			queue += carried
		end
		carried = 0
	end
	local function collect()
		money += pending
		pending = 0
	end
	local function merge()
		local _, _, steps = Economy.mergeAll(units)
		for _, step in steps do
			if not reached[step.tier + 1] then
				reached[step.tier + 1] = t
				log(string.format("tier %d", step.tier + 1))
			end
		end
	end
	local function buy(amount: number)
		money -= Economy.bulkPrice(boughtUnits, amount)
		units[1] += amount
		boughtUnits += amount
		bought()
	end
	local function affordable(): boolean
		return money >= Economy.bulkPrice(boughtUnits, 1)
	end
	-- Everything the cash allows at the buy pads: 5 at a time, then singles.
	local function shop()
		local visits = 0
		while true do
			if visits > 0 then
				wait(Simulate.REBUY)
			end
			if money >= Economy.bulkPrice(boughtUnits, 5) then
				walk("BuyPad")
				buy(5)
			elseif money >= Economy.bulkPrice(boughtUnits, 1) then
				buy(1)
			else
				break
			end
			visits += 1
		end
	end
	-- Pen, converter, vault: ends on the Collect pad.
	local function harvest()
		pickup()
		local rate = Economy.processRate(processLevel)
		if Economy.productionPerSecond(units) > rate and money >= Economy.processUpgradeCost(processLevel) then
			walk("PenProcUp")
			money -= Economy.processUpgradeCost(processLevel)
			processLevel += 1
			log(string.format("converter lv %d", processLevel))
			bought()
			walk("ProcUpDeposit")
		else
			walk("PenDeposit")
		end
		deposit()
		walk("DepositCollect")
		-- Nothing converted yet: the pad refuses, so the player waits for the next tick.
		while pending < 1 and queue > 0 do
			wait(nextTick - t)
		end
		collect()
	end

	-- The tutorial: buy, orbs, deposit, collect, merge.
	wait(Simulate.FIRST_LOOK)
	walk("SpawnBuy")
	buy(1)
	wait(Simulate.STEP_READ)
	walk("BuyPen")
	wait(Simulate.STEP_READ)
	harvest()
	wait(Simulate.STEP_READ)
	walk("CollectMerge")
	merge()
	tutorialDone = t
	money += Economy.TUTORIAL_REWARD_CASH
	log("tutorial done")

	local at = "Merge"
	while t < horizon do
		if affordable() then
			walk(if at == "Merge" then "BuyMerge" else "CollectBuy")
			shop()
			if Economy.mergeAll(table.clone(units)) > 0 then
				walk("BuyMerge")
				merge()
				walk("MergePen")
			else
				walk("BuyPen")
			end
		else
			walk(if at == "Merge" then "MergePen" else "CollectPen")
		end
		harvest()
		at = "Collect"
	end
	if lastBuy and lastBuy < gapUntil and gapUntil - lastBuy > longestGap then
		longestGap, gapAt = gapUntil - lastBuy, lastBuy
	end

	return {
		reached = reached,
		tutorialDone = tutorialDone,
		longestGap = longestGap,
		gapAt = gapAt,
		gapUntil = gapUntil,
		purchases = purchases,
		events = events,
		money = money,
		processLevel = processLevel,
	}
end

local function printFirst(minutes: number?)
	local result = Simulate.firstMinutes({ minutes = minutes })
	print(string.format("first %d minutes of a new player, seconds from the end of the intro", minutes or 10))
	for _, event in result.events do
		print(string.format("%5.0f s  %s", event.t, event.what))
	end
	print(
		string.format(
			"Longest wait between purchases in the first %d s: %.0f s (from %.0f s)",
			result.gapUntil,
			result.longestGap,
			result.gapAt
		)
	)
	print(string.format("End: money %s, converter lv %d", Format.short(result.money), result.processLevel))
end

local function main(args: { string })
	local options: Options = {}
	local first, minutes = false, nil
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
		elseif a == "--first" then
			first = true
		elseif a == "--minutes" then
			i += 1
			minutes = tonumber(args[i])
		end
		i += 1
	end
	if first then
		printFirst(minutes)
		return
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
			"End: money %s, process lv %d, production %s/s",
			Format.short(result.money),
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
