--[[
	Unit tests for the Bowling rules (src/server/Modes/BowlingRules.luau; docs/minigames.md):
	the pin triangle, the seeded roll (path, gutter, knockdown, determinism, the power sweet
	spot and the over-powered hook), the bowler's timing, the frames
	and bonus balls, the scorecard, the pass mark and the lobby phases (what each allows,
	the START pad, ball picks).
	Loaded by tests/run.luau with its harness: { test, check, eq, near, seeded }.
]]

local fs = require("@lune/fs")
local luau = require("@lune/luau")

return function(h: { [string]: any })
	local test, check, eq, near = h.test, h.check, h.eq, h.near
	local BowlingRules = luau.load(fs.readFile("src/server/Modes/BowlingRules.luau"), { debugName = "BowlingRules" })()

	-- Plays `rolls` (pin counts) into a fresh game, knocking down the first standing pins.
	local function play(rolls: { number }): any
		local game = BowlingRules.newGame()
		for _, n in rolls do
			local fallen = {}
			for i, up in game.standing do
				if up and #fallen < n then
					table.insert(fallen, i)
				end
			end
			BowlingRules.applyRoll(game, fallen)
		end
		return game
	end

	test("Bowling: the rules module loads", function()
		local a = BowlingRules.ARENA
		check(type(a) == "table" and a.sizeX > 0 and a.sizeZ > 0, "ARENA has a size")
		check(BowlingRules.FALL_BELOW > 0, "FALL_BELOW is positive")
	end)

	test("Bowling: ten pins in a triangle that fits the lane", function()
		local spots = BowlingRules.PIN_SPOTS
		eq(#spots, 10, "ten pins")
		eq(spots[1].x, 0, "head pin centred")
		eq(spots[1].d, BowlingRules.LANE.headD, "head pin first")
		for _, s in spots do
			check(math.abs(s.x) + BowlingRules.PIN.radius < BowlingRules.LANE.width / 2, "pin on the lane")
			check(s.d < BowlingRules.LANE.length, "pin before the lane's end")
		end
		local a = BowlingRules.ARENA
		check(BowlingRules.LANE.length + BowlingRules.LANE.foulFromEdge < a.sizeZ, "lane fits the arena")
	end)

	test("Bowling: a roll is deterministic for a seed and clamps its input", function()
		local a = BowlingRules.roll(BowlingRules.allStanding(), 0.05, 0.8, 1234)
		local b = BowlingRules.roll(BowlingRules.allStanding(), 0.05, 0.8, 1234)
		eq(a.knocked, b.knocked, "same knockdown")
		for i, f in a.falls do
			eq(f.pin, b.falls[i].pin, "same pin order")
			near(f.t, b.falls[i].t, "same timing")
		end
		local wild = BowlingRules.roll(BowlingRules.allStanding(), 99, -5, 7)
		eq(wild.aim, 1, "aim clamped")
		eq(wild.power, 0, "power clamped")
		local nan = BowlingRules.roll(BowlingRules.allStanding(), 0 / 0, 0 / 0, 7)
		eq(nan.aim, 0, "NaN aim defaults to centre")
	end)

	test("Bowling: a centre roll hits the head pin; a wide one is a gutter ball", function()
		local centre = BowlingRules.roll(BowlingRules.allStanding(), 0, 0.8, 42)
		local headDown = false
		for _, f in centre.falls do
			if f.pin == 1 then
				headDown = f.struck
			end
			near(f.dx * f.dx + f.dd * f.dd, 1, "fall direction is a unit vector")
			check(f.dd > 0, "pins fall away from the bowler")
		end
		check(headDown, "head pin struck")
		check(centre.knocked >= 6, "centre roll knocks at least the pins on its line")
		check(not centre.gutter, "no gutter")
		local wide = BowlingRules.roll(BowlingRules.allStanding(), -1, 0.8, 42)
		check(wide.gutter, "full aim is a gutter ball")
		eq(wide.knocked, 0, "gutter knocks nothing")
		local path = wide.path
		check(path[#path].x < -BowlingRules.LANE.width / 2, "path ends in the left gutter")
		for i = 2, #path do
			check(path[i].t > path[i - 1].t and path[i].d > path[i - 1].d, "path runs forward in time")
		end
	end)

	test("Bowling: only standing pins can fall", function()
		local standing = BowlingRules.allStanding()
		for i = 1, 6 do
			standing[i] = false
		end
		for seed = 1, 50 do
			local r = BowlingRules.roll(standing, 0, 1, seed)
			for _, f in r.falls do
				check(f.pin > 6, "fallen pin was standing")
			end
		end
	end)

	test("Bowling: power is a choice: the sweet spot beats soft and wild", function()
		local function mean(power: number): number
			local sum = 0
			for seed = 1, 400 do
				sum += BowlingRules.roll(BowlingRules.allStanding(), 0.06, power, seed).knocked
			end
			return sum / 400
		end
		local P = BowlingRules.POWER
		check(P.sweetLo >= 0.7 and P.sweetHi <= 0.92 and P.sweetLo < P.sweetHi, "sweet spot around 75-90 %")
		local soft, sweet, wild = mean(0.3), mean((P.sweetLo + P.sweetHi) / 2), mean(1)
		check(sweet > soft + 0.5, "sweet beats soft (" .. sweet .. " vs " .. soft .. ")")
		check(sweet > wild + 1.5, "sweet beats full power (" .. sweet .. " vs " .. wild .. ")")
		eq(BowlingRules.powerZone(0.3), "soft", "soft zone")
		eq(BowlingRules.powerZone(P.sweetLo), "sweet", "sweet zone starts")
		eq(BowlingRules.powerZone(P.sweetHi), "sweet", "sweet zone ends")
		eq(BowlingRules.powerZone(1), "wild", "wild zone")
		eq(BowlingRules.wildness(P.sweetHi), 0, "no wobble in the sweet spot")
		eq(BowlingRules.wildness(1), 1, "full wobble at full power")
	end)

	test("Bowling: an over-powered ball hooks off its line; a sweet one runs true", function()
		local hooked = 0
		for seed = 1, 60 do
			local calm = BowlingRules.roll(BowlingRules.allStanding(), 0.2, 0.8, seed)
			eq(calm.hook, 0, "sweet power: no hook")
			eq(#calm.path, 2, "sweet power: a straight line")
			local wild = BowlingRules.roll(BowlingRules.allStanding(), 0, 1, seed)
			check(wild.hook ~= 0, "full power hooks")
			local path = wild.path
			for i = 2, #path do
				check(path[i].t > path[i - 1].t and path[i].d > path[i - 1].d, "hook path runs forward in time")
			end
			if math.abs(wild.hook) >= BowlingRules.HOOK * 0.6 - 1e-9 then
				hooked += 1
			end
		end
		eq(hooked, 60, "a full-power hook is at least 60 % of HOOK")
	end)

	test("Bowling: the bowler's wind-up and reaction times", function()
		local R = BowlingRules
		check(R.WINDUP > 0.5 and R.WINDUP < 1.5, "a short run-up")
		check(R.settle("strike") >= R.settle("spare") and R.settle("spare") >= R.settle(nil), "a strike celebrates longest")
		check(R.settle("gutter") > 0 and R.settle(nil) > 0, "every ball settles")
		check(R.settle(nil) <= 1.7 and R.settle("strike") <= 2.5, "settles kept short for pacing")
		check(R.SKIP_AFTER >= 0 and R.SKIP_AFTER < R.settle(nil), "a skip comes inside the settle")
		-- The reaction lands after the last pin and before the next turn.
		for seed = 1, 60 do
			local roll = R.roll(R.allStanding(), (seed % 7 - 3) / 3, (seed % 10) / 10, seed)
			local fallen = {}
			for _, f in roll.falls do
				table.insert(fallen, f.pin)
			end
			local mark = R.applyRoll(R.newGame(), fallen)
			local react = R.reactAt(roll, mark)
			for _, f in roll.falls do
				check(react >= f.t, "reaction after every pin falls")
			end
			check(react <= roll.duration + 1, "reaction soon after the ball")
			check(react < roll.duration + R.settle(mark), "reaction before the next turn")
		end
	end)

	test("Bowling: star tiers and their capped bonus", function()
		local R = BowlingRules
		eq(#R.STAR_TIERS, 3, "three stars")
		eq(R.STAR_TIERS[1], R.PASS_SCORE, "the first star is the pass")
		eq(R.stars(0), 0, "no stars")
		eq(R.stars(49), 0, "under the pass")
		eq(R.stars(50), 1, "one star at 50")
		eq(R.stars(89), 1, "still one")
		eq(R.stars(90), 2, "two at 90")
		eq(R.stars(130), 3, "three at 130")
		eq(R.stars(R.MAX_SCORE), 3, "a perfect game")
		eq(R.stars(0 / 0), 0, "NaN: none")
		check(R.STAR_TIERS[3] <= R.MAX_SCORE, "every star is reachable")
		near(R.starShare(0), 0, "no share")
		check(R.starShare(1) > 0 and R.starShare(1) < R.starShare(2) and R.starShare(2) < R.starShare(3), "more stars pay more")
		check(R.starShare(3) <= R.BONUS_CAP + 1e-9, "three stars fit one window")
		eq(R.bonusCash(1000, 0.25), 250, "a share of the repeat cash")
		eq(R.bonusCash(1000, 0), 0, "nothing")
		-- However many three-star games in five minutes: at most BONUS_CAP repeat shares.
		local at, used, total = 0, 0, 0
		for i = 0, 40 do
			local paid
			paid, at, used = R.bonusTake(at, used, 1000 + i * 7, R.starShare(3))
			check(paid >= 0, "never negative")
			total += paid
		end
		check(total <= R.BONUS_CAP * 2 + 1e-9, "two windows at most in 280 s (" .. total .. ")")
		local paid1, at1, used1 = R.bonusTake(0, 0, 5000, R.starShare(3))
		near(paid1, R.starShare(3), "a fresh window pays it all")
		local paid2 = R.bonusTake(at1, used1, 5000 + R.REPEAT_GAP - 1, R.starShare(3))
		near(paid2, math.max(0, R.BONUS_CAP - used1), "the window's rest only")
		local paid3 = R.bonusTake(at1, used1, 5000 + R.REPEAT_GAP, R.starShare(3))
		near(paid3, R.starShare(3), "a new window")
		local paid4 = R.bonusTake(at1 + 999, 1, 5000, 0.5)
		near(paid4, 0.5, "a window from the future starts afresh")
	end)

	test("Bowling: roll input, the ready gap, skips and AFK", function()
		local R = BowlingRules
		local a, p = R.rollInput(0.3, 0.8)
		eq(a, 0.3, "aim kept")
		eq(p, 0.8, "power kept")
		a, p = R.rollInput(5, -2)
		eq(a, 1, "aim clamped")
		eq(p, 0, "power clamped")
		for _, bad in { { nil, 0.5 }, { 0, nil }, { "0", 0.5 }, { 0, {} }, { 0 / 0, 0.5 }, { 0, 0 / 0 }, { true, 1 } } do
			local x, y = R.rollInput(bad[1], bad[2])
			check(x == nil and y == nil, "invalid input is no roll")
		end
		check(R.tooEarly(10.5, 10), "half a second after ready: refused")
		check(not R.tooEarly(10 + R.READY_GAP, 10), "after the gap: fine")
		check(R.READY_GAP >= 0.6 and R.READY_GAP <= 1, "a short gap")
		check(not R.canSkip(4.9, 5), "before the pins are down")
		check(R.canSkip(5, 5), "once they are")
		check(not R.canSkip(1e9, math.huge), "no ball settling: nothing to skip")
		check(R.AFK_SECONDS >= 30 and R.AFK_SECONDS <= 90, "AFK after a while")
		check(R.AFK_POWER < R.POWER.sweetLo, "the AFK ball is weak")
		eq(R.AFK_AIM, 0, "down the middle")
	end)

	test("Bowling: frames, strikes, spares and the last frame's bonus balls", function()
		local game = BowlingRules.newGame()
		local all = {}
		for i = 1, 10 do
			all[i] = i
		end
		local mark, reset = BowlingRules.applyRoll(game, all)
		eq(mark, "strike", "strike")
		check(reset, "rack reset after a strike")
		eq(game.frame, 2, "strike ends the frame")
		mark, reset = BowlingRules.applyRoll(game, { 1, 2, 3 })
		check(mark == nil and not reset and game.frame == 2, "first ball leaves pins up")
		mark, reset = BowlingRules.applyRoll(game, { 4, 5, 6, 7, 8, 9, 10 })
		eq(mark, "spare", "spare")
		check(reset and game.frame == 3, "spare ends the frame")
		mark = BowlingRules.applyRoll(game, {})
		eq(mark, "gutter", "nothing down")

		local open = play({ 3, 4, 3, 4, 3, 4, 3, 4, 3, 4 })
		check(open.over, "five open frames end the game")
		eq(BowlingRules.score(open.frames), 35, "open frames add up")
		local spareLast = play({ 0, 0, 0, 0, 0, 0, 0, 0, 5, 5, 7 })
		check(spareLast.over, "spare in the last frame gives one bonus ball")
		eq(BowlingRules.score(spareLast.frames), 17, "last frame spare + bonus")
		local notOver = play({ 0, 0, 0, 0, 0, 0, 0, 0, 10, 3 })
		check(not notOver.over, "strike in the last frame gives two bonus balls")
		local perfect = play({ 10, 10, 10, 10, 10, 10, 10 })
		check(perfect.over, "a perfect game is seven balls")
		eq(BowlingRules.score(perfect.frames), BowlingRules.MAX_SCORE, "a perfect game scores the max")
	end)

	test("Bowling: the scorecard shows marks and waits for bonus balls", function()
		local game = play({ 10, 7, 3 })
		local card, total = BowlingRules.card(game.frames)
		eq(card[1].marks[1], "X", "strike mark")
		eq(card[1].total, 20, "strike + 7 + 3")
		eq(card[2].marks[2], "/", "spare mark")
		eq(card[2].total, nil, "spare waits for its bonus ball")
		eq(total, 20, "running total is the last known")
		game = play({ 10, 7, 3, 4, 0 })
		card, total = BowlingRules.card(game.frames)
		eq(card[2].total, 34, "spare + 4")
		eq(card[3].marks[2], "-", "miss mark")
		eq(card[3].total, 38, "open frame")
		eq(total, 38, "total")
		local last = play({ 0, 0, 0, 0, 0, 0, 0, 0, 10, 10, 4 })
		card = BowlingRules.card(last.frames)
		eq(table.concat(card[5].marks, ","), "X,X,4", "last frame marks")
		eq(card[5].total, 24, "last frame total")
		local lastSpare = play({ 0, 0, 0, 0, 0, 0, 0, 0, 0, 10, 10 })
		card = BowlingRules.card(lastSpare.frames)
		eq(table.concat(card[5].marks, ","), "-,/,X", "last frame 0 then 10 is a spare")
		local strikeSpare = play({ 0, 0, 0, 0, 0, 0, 0, 0, 10, 0, 10 })
		card = BowlingRules.card(strikeSpare.frames)
		eq(table.concat(card[5].marks, ","), "X,-,/", "last frame strike, 0, 10 is a spare")
	end)

	test("Bowling: the repeat share pays at most once per REPEAT_GAP", function()
		local gap = BowlingRules.REPEAT_GAP
		check(gap >= 120, "repeat gap is minutes long")
		check(BowlingRules.repeatDue(1000000, 0), "never paid: due")
		check(BowlingRules.repeatDue(1000000, nil), "missing stamp: due")
		check(not BowlingRules.repeatDue(1000000, 1000000 - gap + 1), "inside the gap: not due")
		check(BowlingRules.repeatDue(1000000, 1000000 - gap), "gap over: due")
		check(BowlingRules.repeatDue(1000000, 2000000), "stamp from the future: due")
	end)

	test("Bowling: a decent bowler mostly passes; sloppy or full-power bowlers less", function()
		local rand = h.seeded(99)
		local function gauss(): number
			return math.sqrt(-2 * math.log(1 - rand() * 0.999)) * math.cos(2 * math.pi * rand())
		end
		local P = BowlingRules.POWER
		local mid = (P.sweetLo + P.sweetHi) / 2
		local function passRate(spread: number, power: () -> number): number
			local passes = 0
			for g = 1, 300 do
				local game = BowlingRules.newGame()
				local ball = 0
				while not game.over do
					ball += 1
					local r = BowlingRules.roll(game.standing, gauss() * spread, power(), g * 100 + ball)
					local fallen = {}
					for _, f in r.falls do
						table.insert(fallen, f.pin)
					end
					BowlingRules.applyRoll(game, fallen)
				end
				if BowlingRules.passed(BowlingRules.score(game.frames)) then
					passes += 1
				end
			end
			return passes / 300
		end
		-- A decent bowler stops the meter near the sweet spot; a sloppy one anywhere.
		local function decent(): number
			return math.clamp(mid + gauss() * 0.08, 0, 1)
		end
		local function anywhere(): number
			return 0.35 + rand() * 0.65
		end
		local function full(): number
			return 1
		end
		local good = passRate(0.15, decent)
		local sloppy = passRate(0.45, anywhere)
		local basher = passRate(0.15, full)
		check(good > 0.75 and good < 0.99, "decent pass rate " .. good)
		check(sloppy > 0.25 and sloppy < 0.75, "sloppy pass rate " .. sloppy)
		check(basher < good - 0.2, "full power every ball passes less (" .. basher .. ")")
		check(BowlingRules.PASS_SCORE < BowlingRules.MAX_SCORE, "pass mark under the max")
	end)

	test("Bowling: what each phase allows (lobby -> countdown -> play -> results)", function()
		local R = BowlingRules
		eq(table.concat(R.PHASES, ","), "lobby,countdown,play,results", "phase order")
		check(R.isPhase("lobby") and R.isPhase("results") and not R.isPhase("done"), "isPhase")
		local allow = {
			-- phase: begin, pick a ball, roll, exit, fall back to
			lobby = { true, true, false, true, "lobby" },
			countdown = { false, false, false, false, "play" },
			play = { false, false, true, false, "play" },
			results = { true, true, false, true, "play" },
		}
		for phase, a in allow do
			eq(R.canBegin(phase), a[1], phase .. " begin")
			eq(R.canPickBall(phase), a[2], phase .. " ball pick")
			eq(R.canRoll(phase), a[3], phase .. " roll")
			eq(R.canExit(phase), a[4], phase .. " exit")
			eq(R.fallTo(phase), a[5], phase .. " fall")
		end
		check(R.COUNTDOWN == 3, "a 3, 2, 1 countdown")
		check(R.RESULTS_SECONDS >= 4 and R.RESULTS_SECONDS <= 8, "results card for about 6 s")
		check(R.REARM > 0 and R.REARM < R.RESULTS_SECONDS, "short START pad re-arm")
	end)

	test("Bowling: ball picks are whole numbers 1..BALL_CHOICES", function()
		local R = BowlingRules
		eq(R.BALL_CHOICES, 4, "four dumbbells on the rack")
		for i = 1, R.BALL_CHOICES do
			eq(R.ballChoice(i), i, "choice " .. i)
		end
		for _, bad in { 0, 5, -1, 1.5, 0 / 0, math.huge, "2", true, {} } :: { any } do
			eq(R.ballChoice(bad), nil, "rejects " .. tostring(bad))
		end
	end)

	test("Bowling: the START pad needs feet on it, the lobby and the re-arm over", function()
		local R = BowlingRules
		check(R.onPad(0, 0, 0, 4), "centre")
		check(R.onPad(3, 1, 2, 4), "inside the radius")
		check(not R.onPad(3, 0, 3, 4), "outside the radius")
		check(not R.onPad(0, R.PAD_HEIGHT + 1, 0, 4), "jumping high over it")
		check(not R.onPad(0, -R.PAD_HEIGHT - 1, 0, 4), "under it")
		check(R.padStarts("lobby", true, 10, 10), "re-arm over: starts")
		check(not R.padStarts("lobby", true, 9.9, 10), "just back in the lobby: waits")
		check(not R.padStarts("lobby", false, 20, 10), "off the pad")
		for _, phase in { "countdown", "play", "results" } do
			check(not R.padStarts(phase, true, 20, 10), "pad does nothing in " .. phase)
		end
	end)

	test("Bowling: neighbouring seeds give unrelated rolls", function()
		local firsts = {}
		local low = 0
		for seed = 1, 200 do
			local v = BowlingRules.rng(seed)()
			check(v >= 0 and v < 1, "in [0, 1)")
			firsts[seed] = v
			if v < 0.1 then
				low += 1
			end
		end
		check(low > 5 and low < 40, "first draws spread out (" .. low .. " under 0.1)")
		local close = 0
		for seed = 2, 200 do
			if math.abs(firsts[seed] - firsts[seed - 1]) < 0.05 then
				close += 1
			end
		end
		check(close < 30, "neighbouring seeds differ (" .. close .. " close pairs)")
		local seq = BowlingRules.rng(0)
		check(seq() ~= seq(), "seed 0 still runs")
	end)
end
