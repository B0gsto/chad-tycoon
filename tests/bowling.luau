--[[
	Unit tests for the Bowling rules (src/server/Modes/BowlingRules.luau; docs/minigames.md):
	the pin triangle, the seeded roll (path, gutter, knockdown, determinism), the frames
	and bonus balls, the scorecard and the pass mark.
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
		local centre = BowlingRules.roll(BowlingRules.allStanding(), 0, 1, 42)
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
		local wide = BowlingRules.roll(BowlingRules.allStanding(), -1, 1, 42)
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

	test("Bowling: more power topples more pins on average", function()
		local soft, hard = 0, 0
		for seed = 1, 400 do
			soft += BowlingRules.roll(BowlingRules.allStanding(), 0.06, 0, seed).knocked
			hard += BowlingRules.roll(BowlingRules.allStanding(), 0.06, 1, seed).knocked
		end
		check(hard > soft, "power helps")
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

	test("Bowling: a sloppy bowler passes now and then, a careful one mostly", function()
		local rand = h.seeded(99)
		local function gauss(): number
			return math.sqrt(-2 * math.log(1 - rand() * 0.999)) * math.cos(2 * math.pi * rand())
		end
		local function passRate(spread: number): number
			local passes = 0
			for g = 1, 300 do
				local game = BowlingRules.newGame()
				local ball = 0
				while not game.over do
					ball += 1
					local r = BowlingRules.roll(game.standing, gauss() * spread, 0.35 + rand() * 0.65, g * 100 + ball)
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
		local sloppy, careful = passRate(0.45), passRate(0.15)
		check(sloppy > 0.25 and sloppy < 0.75, "sloppy pass rate " .. sloppy)
		check(careful > 0.5 and careful < 0.97, "careful pass rate " .. careful)
		check(BowlingRules.PASS_SCORE < BowlingRules.MAX_SCORE, "pass mark under the max")
	end)
end
