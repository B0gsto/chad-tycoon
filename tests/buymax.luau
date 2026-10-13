--[[
	Unit tests for Buy Max (Economy.maxAffordable / planBuyMax), the numbers the State
	snapshot and the Reward notify are built from (unitsToNextTier, unitRates), the Aura
	Surge announcements (surgePhase / surgeNotice), the greedy simulation's use of Buy Max
	and the Tycoon wiring of all of them (source checks: Tycoon needs a live server).
	Loaded by tests/run.luau with its harness: { test, check, eq }. Run alone with
	`lune run tests/buymax` it uses the small harness at the end of this file.
]]

local fs = require("@lune/fs")
local process = require("@lune/process")
local task = require("@lune/task")

local Economy = require("../src/shared/Economy")

local TOP = Economy.MAX_TIER
-- First-tier units one top-tier unit is merged from (16.7M).
local TOP_UNITS = Economy.MERGE_RATIO ^ (TOP - 1)

local function rack(counts: { [number]: number }?): { number }
	local units = table.create(TOP, 0)
	for tier, count in counts or {} do
		units[tier] = count
	end
	return units
end

-- What the rack is worth in first-tier units.
local function worth(units: { number }): number
	local total = 0
	for tier = 1, TOP do
		total += (units[tier] or 0) * Economy.MERGE_RATIO ^ (tier - 1)
	end
	return total
end

-- A wallet just short of `price`: a dollar, or more where a dollar is below what a number
-- that large can tell apart (always far less than one more unit costs).
local function short(price: number): number
	return price - math.max(1, price * 1e-9)
end

local ran = false

local function suite(h: { [string]: any })
	ran = true
	local test, check, eq = h.test, h.check, h.eq

	test("Buy Max: maxAffordable is the exact largest amount", function()
		eq(Economy.maxAffordable(0, 0), 0, "no cash, no units")
		eq(Economy.maxAffordable(0, Economy.unitPrice(0) - 1), 0, "a dollar short of one unit")
		eq(Economy.maxAffordable(0, Economy.unitPrice(0)), 1, "exactly one unit")
		eq(Economy.maxAffordable(700, -5), 0, "negative cash")
		eq(Economy.maxAffordable(700, 0 / 0), 0, "NaN cash")
		eq(Economy.maxAffordable(700, math.huge), Economy.BUY_MAX_UNITS, "endless cash stops at a full top-tier rack")
		for _, bought in { 0, 7, 59, 60, 61, 500, 1234, 98765, 4e6 } do
			for _, amount in { 1, 2, 5, 99, 100, 199, 200, 1240, 65536, TOP_UNITS } do
				local price = Economy.bulkPrice(bought, amount)
				local what = string.format("bought %d, amount %d", bought, amount)
				eq(Economy.maxAffordable(bought, price), amount, what .. ": its exact price")
				eq(Economy.maxAffordable(bought, short(price)), amount - 1, what .. ": a dollar short")
				local n = Economy.maxAffordable(bought, price * 1.37)
				check(Economy.bulkPrice(bought, n) <= price * 1.37, what .. ": the answer is affordable")
				check(Economy.bulkPrice(bought, n + 1) > price * 1.37, what .. ": one more is not")
			end
		end
	end)

	test("Buy Max: only from BUY_MAX_FROM units bought and BUY_MAX_MIN affordable", function()
		eq(Economy.BUY_MAX_FROM, 500, "Buy Max starts at 500 units bought")
		eq(Economy.BUY_MAX_MIN, 200, "and needs 200 affordable units")
		local rich = Economy.bulkPrice(0, 5000)
		eq(Economy.planBuyMax(rack({ 3 }), Economy.BUY_MAX_FROM - 1, rich), nil, "499 bought: still Buy 100")
		check(Economy.planBuyMax(rack({ 3 }), Economy.BUY_MAX_FROM, Economy.bulkPrice(500, 5000)) ~= nil, "500 bought: Buy Max")
		for _, bought in { 500, 3000, 2e6 } do
			local what = "bought " .. bought
			local under = Economy.bulkPrice(bought, Economy.BUY_MAX_MIN) - 1
			eq(Economy.planBuyMax(rack(), bought, under), nil, what .. ": 199 affordable is a Buy 100")
			local plan = Economy.planBuyMax(rack(), bought, under + 1)
			eq(plan and plan.amount, Economy.BUY_MAX_MIN, what .. ": 200 affordable is a Buy Max")
			-- Nothing is ever bought under 100: below that the pad's Buy 100 cannot be paid either.
			local poor = Economy.bulkPrice(bought, 100) - 1
			eq(Economy.planBuyMax(rack(), bought, poor), nil, what .. ": no plan under 100 units")
			eq(Economy.maxAffordable(bought, poor), 99, what .. ": 99 affordable")
			eq(Economy.planBuyMax(rack(), bought, 0), nil, what .. ": no cash, no plan")
		end
	end)

	test("Buy Max: price exact, value conserved, whole rack merged", function()
		local cases = {
			{ units = rack(), bought = 500, money = 1e7 },
			{ units = rack({ 1 }), bought = 500, money = 2.5e7 },
			{ units = rack({ 70, 16 }), bought = 2400, money = 3.5e11 },
			{ units = rack({ 0, 0, 80 }), bought = 9000, money = 9e12 },
			{ units = rack({ 3, 1, 0, 1, 1, 0, 0, 2, 1, 0, 5 }), bought = 65000, money = 4.4e15 },
			{ units = rack({ [20] = 1, [21] = 1, [22] = 1 }), bought = 7e6, money = 3e18 },
		}
		for i, case in cases do
			local what = "case " .. i
			local before = table.clone(case.units)
			local plan = Economy.planBuyMax(case.units, case.bought, case.money)
			check(plan ~= nil, what .. ": a plan")
			if not plan then
				continue
			end
			for tier = 1, TOP do
				eq(case.units[tier], before[tier], what .. ": the input rack is untouched, tier " .. tier)
			end
			eq(plan.amount, Economy.maxAffordable(case.bought, case.money), what .. ": everything affordable")
			check(plan.amount >= Economy.BUY_MAX_MIN, what .. ": at least 200 units")
			eq(plan.cost, Economy.bulkPrice(case.bought, plan.amount), what .. ": the exact bulk price")
			check(plan.cost <= case.money, what .. ": never more than the wallet")
			check(Economy.bulkPrice(case.bought, plan.amount + 1) > case.money, what .. ": one more unit is too much")
			eq(worth(plan.units), worth(before) + plan.amount, what .. ": value conserved")
			local merges = 0
			for _, step in plan.steps do
				merges += step.made
			end
			eq(plan.merges, merges, what .. ": merges match the steps")
			eq(Economy.totalUnits(plan.units), Economy.totalUnits(before) + plan.amount - merges, what .. ": every merge removes one unit")
			for tier = 1, TOP - 1 do
				check(plan.units[tier] < Economy.MERGE_RATIO, what .. ": no pair left at tier " .. tier)
			end
			check(Economy.totalUnits(plan.units) <= Economy.UNIT_CAP, what .. ": inside the rack cap")
		end
	end)

	test("Buy Max: 16.7M units in one step, in under 50 ms", function()
		eq(TOP_UNITS, 16777216, "a top-tier unit is 16.7M first-tier units")
		local bought = 9e6
		local money = Economy.bulkPrice(bought, TOP_UNITS)
		local started = os.clock()
		local plan = Economy.planBuyMax(rack(), bought, money)
		local took = os.clock() - started
		check(took < 0.05, string.format("planned in %.2f ms", took * 1000))
		check(plan ~= nil, "a plan")
		if plan then
			eq(plan.amount, TOP_UNITS, "16.7M units bought")
			eq(plan.cost, money, "for the whole wallet")
			eq(plan.units[TOP], 1, "one top-tier unit")
			eq(Economy.totalUnits(plan.units), 1, "and nothing else")
			eq(plan.merges, TOP_UNITS - 1, "16.7M - 1 merges")
			eq(#plan.steps, TOP - 1, "one merge step per tier")
		end
		-- One unit short of it: every tier below the top holds exactly one unit.
		plan = Economy.planBuyMax(rack(), bought, short(money))
		eq(plan and plan.amount, TOP_UNITS - 1, "a little less buys one unit less")
		eq(plan and Economy.totalUnits(plan.units), TOP - 1, "one unit of each tier below the top")
	end)

	test("Buy Max: the rack cap cuts the purchase to whole top-tier units", function()
		local bought = 1e9
		local endless = math.huge
		local full = rack({ [TOP] = Economy.UNIT_CAP })
		eq(Economy.planBuyMax(full, bought, endless), nil, "a rack full of the top tier buys nothing")
		-- 99 top units and a few below: only what completes the 100th top unit is bought.
		local units = rack({ 1, 1, 0, 1, [TOP] = Economy.UNIT_CAP - 1 })
		local plan = Economy.planBuyMax(units, bought, endless)
		check(plan ~= nil, "a plan at 99 top-tier units")
		if plan then
			eq(plan.amount, TOP_UNITS - 11, "the units missing for one more top-tier unit")
			eq(plan.cost, Economy.bulkPrice(bought, plan.amount), "priced exactly")
			eq(plan.units[TOP], Economy.UNIT_CAP, "the rack ends full of the top tier")
			eq(Economy.totalUnits(plan.units), Economy.UNIT_CAP, "and at the cap")
			eq(worth(plan.units), worth(units) + plan.amount, "value conserved")
		end
		-- The wallet covers a little more than the rack has room for.
		units = rack({ [TOP] = Economy.UNIT_CAP - 30 })
		plan = Economy.planBuyMax(units, 0 + Economy.BUY_MAX_FROM, Economy.bulkPrice(Economy.BUY_MAX_FROM, 30 * TOP_UNITS + 4e6))
		eq(plan and plan.amount, 30 * TOP_UNITS, "cut to the 30 top-tier units that fit")
		eq(plan and Economy.totalUnits(plan.units), Economy.UNIT_CAP, "the rack is full")
		-- A small cap leaves room for the usual one unit per tier.
		plan = Economy.planBuyMax(rack(), 500, Economy.bulkPrice(500, 1023), 10)
		eq(plan and plan.amount, 1023, "10 units fit a cap of 10")
		eq(Economy.planBuyMax(rack({ [TOP] = 10 }), 500, Economy.bulkPrice(500, 1023), 10), nil, "nothing fits a full rack of 10")
	end)

	test("Snapshot numbers: units to the next tier, unit rates", function()
		eq(Economy.unitsToNextTier(rack({ 1 }), 1), 1, "one more for the first merge")
		eq(Economy.unitsToNextTier(rack({ 2 }), 1), 0, "a pair is enough")
		eq(Economy.unitsToNextTier(rack({ 1, 1 }), 2), 1, "tier 3 needs 4: 3 owned")
		eq(Economy.unitsToNextTier(rack({ 0, 0, 1 }), 3), 4, "tier 4 needs 8: 4 owned")
		eq(Economy.unitsToNextTier(rack(), 9), 512, "an empty rack needs all 512 for tier 10")
		eq(Economy.unitsToNextTier(rack({ 0, 0, 80 }), 9), 192, "80 tier-3 units are worth 320")
		eq(Economy.unitsToNextTier(rack({ 100 }), 3), 0, "never negative")
		eq(Economy.unitsToNextTier(rack({ [TOP - 1] = 1 }), TOP - 1), TOP_UNITS / 2, "half of the top tier still to buy")
		eq(Economy.unitsToNextTier(rack({ [TOP] = 1 }), TOP), 0, "nothing after the top tier")
		-- Buying exactly that many and merging makes the tier.
		local units = rack({ 3, 0, 1, 1 })
		local missing = Economy.unitsToNextTier(units, 5)
		units[1] += missing
		local _, top = Economy.mergeAll(units)
		eq(top, 6, "the missing units make the next tier")
		units = rack({ 3, 0, 1, 1 })
		units[1] += missing - 1
		_, top = Economy.mergeAll(units)
		check(top < 6, "one unit fewer does not")

		local rates = Economy.unitRates(6)
		eq(#rates, 6, "a dense list up to the tier")
		for tier = 1, 6 do
			eq(rates[tier], Economy.unitRate(tier), "rate of tier " .. tier)
		end
		eq(#Economy.unitRates(99), TOP, "clamped to the top tier")
		eq(#Economy.unitRates(0), 1, "and to the first")
	end)

	test("Aura Surge announcements: soon 30 s before, start, end", function()
		eq(Economy.SURGE_WARN_SECONDS, 30, "players are told 30 s ahead")
		local start = Economy.SURGE_CYCLE - Economy.SURGE_DURATION
		local phase, left = Economy.surgePhase(0)
		eq(phase, "idle", "idle at the start of a cycle")
		eq(left, start - Economy.SURGE_WARN_SECONDS, "until the warning")
		phase, left = Economy.surgePhase(start - Economy.SURGE_WARN_SECONDS)
		eq(phase, "soon", "the warning phase")
		eq(left, Economy.SURGE_WARN_SECONDS, "30 s before the surge")
		phase, left = Economy.surgePhase(start)
		eq(phase, "active", "the surge")
		eq(left, Economy.SURGE_DURATION, "for its whole length")

		eq(Economy.surgeNotice("idle", "idle"), nil, "no change, no notice")
		eq(Economy.surgeNotice("idle", "soon"), "soon", "idle to soon")
		eq(Economy.surgeNotice("soon", "active"), "start", "soon to active")
		eq(Economy.surgeNotice("idle", "active"), "start", "a late tick still announces the start")
		eq(Economy.surgeNotice("active", "idle"), "end", "active to idle")
		eq(Economy.surgeNotice("soon", "idle"), nil, "no end without a surge")

		-- The server's loop, one tick a second (a little off the second) over three cycles
		-- from the middle of a surge: nothing for the surge it joined in, then every notice once.
		local at = 3 * Economy.SURGE_CYCLE + start + 40.3
		local previous = Economy.surgePhase(at)
		local seen: { string } = {}
		for _ = 1, 3 * Economy.SURGE_CYCLE do
			at += 1
			local now, seconds = Economy.surgePhase(at)
			local notice = Economy.surgeNotice(previous, now)
			previous = now
			if notice then
				local t = at % Economy.SURGE_CYCLE
				table.insert(seen, notice)
				if notice == "soon" then
					check(t >= start - 30 and t < start - 29, "soon in the first second of the warning")
					check(seconds > 29 and seconds <= 30, "soon: about 30 s left")
				elseif notice == "start" then
					check(t >= start and t < start + 1, "start in the surge's first second")
					check(seconds > Economy.SURGE_DURATION - 1, "start: the whole surge left")
				else
					check(t < 1, "end in the first second after the surge")
				end
			end
		end
		eq(table.concat(seen, " "), "end soon start end soon start end soon start", "the notices of three cycles, in order")
	end)

	test("Simulation: the greedy model uses Buy Max and reaches the top tier", function()
		(_G :: any).SIMULATE_AS_LIBRARY = true
		local Simulate = require("../scripts/simulate")
		local source = fs.readFile("scripts/simulate.luau")
		check(string.find(source, "Economy.planBuyMax(units, boughtUnits, money)", 1, true) ~= nil, "Simulate.run plans a Buy Max")
		local result = Simulate.run({ hours = 100, step = 10 })
		check(result.reached[Economy.MAX_TIER] ~= nil, "tier 25 within 100 hours")
		for tier = 2, Economy.MAX_TIER do
			check(result.reached[tier] ~= nil and result.reached[tier] >= result.reached[tier - 1], "tiers in order: " .. tier)
		end
		check(result.converterShare >= 0.5, "the converter still passes at least half the production")
	end)

	test("Tycoon wiring: Buy Max pad, payloads, snapshot, first crate (source)", function()
		local source = fs.readFile("src/server/Tycoon.luau")
		local function has(text: string): boolean
			return string.find(source, text, 1, true) ~= nil
		end
		local function body(name: string): string
			local from = string.find(source, "\nlocal function " .. name .. "(", 1, true)
			check(from ~= nil, name .. " exists")
			local to = string.find(source, "\nend\n", from or 1, true)
			return string.sub(source, from or 1, to or #source)
		end

		-- Buy Max: the Buy 100 pad tries it first and falls back to 100; one Buy effect.
		check(has('local BUY_MAX_PAD = "Buy100"'), "Buy Max lives on the Buy 100 pad")
		check(has("if not buyMax(session) then\n\t\tbuy(session, 100)"), "not a Buy Max: Buy 100 as before")
		local buyMax = body("buyMax")
		check(string.find(buyMax, "Economy.planBuyMax(p.units, p.bought, p.money)", 1, true) ~= nil, "the pad follows the plan")
		check(string.find(buyMax, "spend(session, plan.cost, BUY_MAX_PAD)", 1, true) ~= nil, "charged the plan's exact cost")
		check(string.find(buyMax, "p.bought += plan.amount", 1, true) ~= nil, "the price ramp counts every unit")
		check(string.find(buyMax, "amount = plan.amount", 1, true) ~= nil, "the Buy effect carries the amount")
		check(string.find(buyMax, "max = true", 1, true) ~= nil, "and says it was a Buy Max")
		local _, buyEffects = string.gsub(buyMax, 'effect%(session, "Buy"', "")
		eq(buyEffects, 1, "one Buy effect per Buy Max")
		check(has('string.format("BUY MAX x%s %s", count, tierName(1))'), "the pad title names the amount")

		-- Reward notify: per-tier rates and the earning before and after.
		for _, field in { "rates = rates", "productionBefore =", "productionAfter =", "incomeBefore =", "incomeAfter =" } do
			check(string.find(body("discoverAll"), field, 1, true) ~= nil, "Reward notify has " .. field)
		end
		check(has("Economy.unitRates(newest)"), "rates are a dense list up to the newest tier")
		-- Merges: no toast, every "Merge" effect carries the aura gained by the whole action.
		check(not has('"Merged %s!'), "a merge sends no toast")
		local mergeEffects = body("sendMergeEffects")
		local _, pairsSent = string.gsub(mergeEffects, "productionBefore = productionBefore,\n%s*productionAfter = productionAfter,", "")
		eq(pairsSent, 2, "both kinds of Merge effect carry the production before and after")
		local _, withBefore = string.gsub(source, "sendMergeEffects%(session, [%w%.]+, %a+, diff, %a+%)", "")
		eq(withBefore, 4, "every merging action passes its earning from before")
		check(
			string.find(body("doMerge"), "sendMergeEffects(session, steps, auto, diff, earningBefore)", 1, true) ~= nil,
			"the Merge pad too"
		)

		-- Surge and gift notifies.
		check(has('kind = "Surge", phase = notice, seconds = seconds'), "the surge is announced")
		check(has('if session.profile.tutorialDone then\n\t\t\t\t\t\tnotify(session, { kind = "Surge"'), "but not during the tutorial")
		check(has("Economy.surgeNotice(surgePhase, phase)"), "on a phase change only")
		check(has('kind = "Gift", cash = cash'), "the free gift sends a Gift notify")
		check(not has('"Free reward: +"'), "and no toast")

		-- Snapshot.
		local snapshot = body("snapshot")
		for _, field in { "queueSeconds =", "upgradeGain = upgradeGain(session, 1)", "nextTierUnits = Economy.unitsToNextTier(" } do
			check(string.find(snapshot, field, 1, true) ~= nil, "snapshot has " .. field)
		end

		-- Only the first crate ever loaded gets the short timer, and the crate panel is told
		-- the same time (the snapshot's heldSeconds), not the rarity's.
		local seconds = body("unlockerSeconds")
		check(string.find(seconds, "Economy.FIRST_CRATE_SECONDS", 1, true) ~= nil, "the first crate's time is worked out in one place")
		local load = body("loadUnlocker")
		local short = string.find(load, "unlockerSeconds(session, slotIndex)", 1, true)
		local done = string.find(load, "p.firstCrateDone = true", 1, true)
		check(short ~= nil and done ~= nil and done > short, "loading a crate ends the first-crate timer for the next one")
		check(string.find(snapshot, 'heldSeconds = if p.heldChest ~= ""', 1, true) ~= nil, "snapshot has the held crate's real time")
		check(string.find(snapshot, "unlockerSeconds(session, 1)", 1, true) ~= nil, "from the same function the Smasher uses")
		check(
			string.find(snapshot, 'crateGuide = p.heldChest ~= "" and p.cratesHeld <= Economy.CRATE_GUIDE_HOLDS', 1, true) ~= nil,
			"snapshot says when the Smasher path shows by itself"
		)
		local popups = fs.readFile("src/client/UI/Popups.luau")
		check(string.find(popups, "tonumber(data.heldSeconds)", 1, true) ~= nil, "the crate panel shows the server's time")
		check(string.find(popups, "Format.time(Economy.unlockSeconds(rarity", 1, true) == nil, "and never one worked out from the rarity")
		check(
			string.find(popups, "if data.crateGuide == true then\n\t\t\t\tGuide.navigate(SMASHER_PAD", 1, true) ~= nil,
			"the path shows by itself"
		)

		-- The Aura Surge starts for a session when its tutorial is done.
		check(not has("Economy.surgeState("), "Tycoon never reads the bare surge clock")
		local _, gated = string.gsub(source, "Economy%.surgeFor%(serverNow%(%), session%.profile%.tutorialDone%)", "")
		eq(gated, 2, "orbs and the converter both skip the surge during the tutorial")
		for _, path in { "src/client/UI/Hud.luau", "src/client/Fx/Surge.luau" } do
			local client = fs.readFile(path)
			check(string.find(client, "Economy.surgeFor(now, ", 1, true) ~= nil, path .. " shows no surge during the tutorial")
			check(string.find(client, "Economy.surgeState(", 1, true) == nil, path .. " never reads the bare clock")
		end

		-- Crate arrivals: every one is told, a Common one at most every 30 s.
		check(has("local CRATE_TOAST_GAP = 30"), "Common crate toasts are 30 s apart")
		check(has("elseif os.clock() - session.crateToastAt >= CRATE_TOAST_GAP then"), "a Common crate is told too")
		check(has("rolled into your pen!"), "in plain words")

		-- Smasher: the crate opens by itself under a waiting owner; the Robux smash is a button.
		check(has("if visit.fired and unlockerDue(session, name) then\n\t\t\t\tpadHandlers[name](session)"), "auto-open at zero on the pad")
		check(not has("SMASH_OFFER_DWELL") and not has("visit.linger"), "standing still never offers Robux")
		check(has("actionHandlers.OfferSmash = function(session, data)"), "the Smash now button asks first")
		local machines = fs.readFile("src/client/Fx/Machines.luau")
		check(string.find(machines, 'action = "OfferSmash", slot = slotIndex', 1, true) ~= nil, "the button is on the Smasher's crate")
		check(string.find(machines, '"READY!"', 1, true) == nil, "no second READY! card behind the sign")

		-- Upgrade pads: own titles.
		check(has("Economy.upgradeShowsCash(amount, gain, singleGain)"), "each upgrade pad shows its own gain")
	end)

	test("Aura Surge: none for a player still in the tutorial", function()
		local at = Economy.SURGE_CYCLE - Economy.SURGE_DURATION + 15
		local active, left = Economy.surgeState(at)
		eq(active, true, "the clock says surge")
		local mine, mineLeft = Economy.surgeFor(at, false)
		eq(mine, false, "not for a tutorial player")
		eq(mineLeft, left, "the clock's own seconds")
		eq(Economy.surgeFor(at, nil), false, "nor before the first snapshot")
		eq(Economy.surgeFor(at, true), true, "on once the tutorial is done or skipped")
		eq(Economy.surgeFor(0, true), false, "and off outside the surge")
	end)

	test("upgrade pads: each title shows its own gain", function()
		-- Far behind the units: both pads add different cash.
		eq(Economy.upgradeShowsCash(1, 50, 50), true, "x1 shows cash")
		eq(Economy.upgradeShowsCash(Economy.PROCESS_BULK, 400, 50), true, "x10 shows its bigger cash")
		-- One level catches up: the x10 pad would read the same cash, so it shows its speed.
		eq(Economy.upgradeShowsCash(1, 164, 164), true, "x1 still shows cash")
		eq(Economy.upgradeShowsCash(Economy.PROCESS_BULK, 164, 164), false, "x10 shows speed, not the same cash")
		-- Nothing to gain: both show speed.
		eq(Economy.upgradeShowsCash(1, 0, 0), false, "no cash to show")
		eq(Economy.upgradeShowsCash(Economy.PROCESS_BULK, 0, 0), false, "none on x10 either")
		eq(Economy.CRATE_GUIDE_HOLDS, 3, "the first three crates get the Smasher path")
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
