--[[
	Unit tests for the Parkour server (src/server/Modes/Parkour.luau, run against stub
	GameModes / Tycoon tables): a paid Skip Map only unlocks (no reward, no clear, no stage),
	it ends at the gates with the map picker, and nobody is left on the sky course without a
	run (stranded rescue, the timed return after a finish).
	Loaded by tests/run.luau with its harness: { test, check, eq }. Run alone with
	`lune run tests/parkour_bugs` it uses the small harness at the end of this file.
]]

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local process = require("@lune/process")
local roblox = require("@lune/roblox")
local serde = require("@lune/serde")
local task = require("@lune/task")

local Economy = require("../src/shared/Economy")
local Format = require("../src/shared/Format")

local Vector3 = roblox.Vector3

local MODES_DIR = "src/server/Modes/"
-- Feet are this far below the HumanoidRootPart's centre (Parkour's FEET_BELOW_ROOT).
local FEET = 3
local TICK = 0.1

local function identity(module: any): any
	return module
end

local function loadDataService(): any
	local services = {
		DataStoreService = {
			GetDataStore = function()
				error("no DataStore in tests")
			end,
		},
		HttpService = {
			GenerateGUID = function()
				return "test"
			end,
		},
		RunService = {
			IsStudio = function()
				return true
			end,
		},
		ReplicatedStorage = {
			Shared = {
				Economy = Economy,
				Funnel = require("../src/shared/Funnel"),
				SessionLock = require("../src/shared/SessionLock"),
				TutorialSteps = require("../src/shared/TutorialSteps"),
			},
		},
	}
	local env = setmetatable({
		game = {
			JobId = "",
			GetService = function(_, name)
				return services[name]
			end,
		},
		require = identity,
		warn = function() end,
	}, { __index = _G })
	local path = "src/server/DataService.luau"
	return luau.load(fs.readFile(path), { debugName = path, environment = env })()
end

local ran = false

local function suite(h: { [string]: any })
	ran = true
	local test, check, eq = h.test, h.check, h.eq

	local Course = luau.load(fs.readFile(MODES_DIR .. "Course.luau"), { debugName = "Course" })()
	local Rules = luau.load(fs.readFile(MODES_DIR .. "Rules.luau"), {
		debugName = "Rules",
		environment = setmetatable({ script = { Parent = { Course = Course } }, require = identity }, { __index = _G }),
	})()
	local DataService = loadDataService()
	local SKIP_COST = Economy.parkourSkipCost(1)

	-- One player on a fresh server: the Parkour mode over stub GameModes / Tycoon tables that
	-- record what it sent. `w.root.Position` is where the player stands.
	local function newWorld(): any
		local w = { clock = 1000, notes = {}, toasts = {}, returns = {}, actions = {}, gates = 0, dirty = 0 }
		local attributes = {}
		w.attributes = attributes
		w.player = {
			UserId = 1,
			DisplayName = "Tester",
			GetAttribute = function(_, name)
				return attributes[name]
			end,
			SetAttribute = function(_, name, value)
				attributes[name] = value
			end,
		}
		w.root = { Position = Vector3.new(0, FEET, 0) }
		w.session = { player = w.player, profile = DataService.defaultProfile() }
		w.rec = w.session.profile.parkour
		local GameModes = {
			hooks = {
				reward = function(_, _, reward)
					return reward
				end,
				rewarded = function() end,
			},
			session = function()
				return w.session
			end,
			notify = function(_, event, _, data)
				local note = { event = event }
				for key, value in data or {} do
					note[key] = value
				end
				table.insert(w.notes, note)
			end,
			effect = function() end,
			refresh = function() end,
			root = function()
				return w.root
			end,
			teleport = function(_, feet)
				w.root.Position = feet + Vector3.new(0, FEET, 0)
			end,
			toGates = function()
				w.gates += 1
				w.root.Position = Vector3.new(Course.QUIT.x, Course.QUIT.y + FEET, Course.QUIT.z)
			end,
			returnLater = function(_, seconds, stillThere)
				table.insert(w.returns, { seconds = seconds, stillThere = stillThere })
			end,
		}
		local Tycoon = {
			addAction = function(name, handler)
				w.actions[name] = handler
			end,
			income = function()
				return 1
			end,
			markDirty = function()
				w.dirty += 1
			end,
			toast = function(_, text)
				table.insert(w.toasts, text)
			end,
		}
		local services = {
			ReplicatedStorage = { Shared = { Economy = Economy, Format = Format } },
			Players = { PlayerRemoving = { Connect = function() end } },
		}
		local env = setmetatable({
			game = {
				GetService = function(_, name)
					return services[name]
				end,
			},
			script = { Parent = { Course = Course, Rules = Rules } },
			require = identity,
			workspace = {
				GetServerTimeNow = function()
					return w.clock
				end,
			},
			Vector3 = Vector3,
		}, { __index = _G })
		local path = MODES_DIR .. "Parkour.luau"
		local Parkour = luau.load(fs.readFile(path), { debugName = path, environment = env })()
		w.def = Parkour.create(GameModes, {
			built = nil,
			theme = { Modes = { Reward = { Seconds = 300, Min = 750 } } },
			Tycoon = Tycoon,
		})

		-- Feet at (x, y, z).
		function w.stand(x: number, y: number, z: number)
			w.root.Position = Vector3.new(x, y + FEET, z)
		end
		function w.onElement(e: any)
			w.stand(e.x, e.y, e.z)
		end
		-- Lets `seconds` pass, ticking the mode like GameModes does.
		function w.wait(seconds: number)
			for _ = 1, math.floor(seconds / TICK + 0.5) do
				w.clock += TICK
				w.def.tick(w.player, w.root, w.clock)
			end
		end
		function w.start(level: number): boolean
			return w.def.start(w.player, true, { level = level })
		end
		function w.skip()
			w.actions.ParkourSkip(w.session, {})
		end
		-- A real run of `level`: start, then stand on the finish deck after a fair time.
		function w.clear(level: number)
			check(w.start(level), "map " .. level .. " starts")
			local l = Course.level(level)
			w.clock += l.MIN_SECONDS + 5
			w.onElement(l.PATH[#l.PATH])
			w.wait(TICK)
		end
		-- The latest note of `event` (and how many there are).
		function w.note(event: string): (any, number)
			local found, count = nil, 0
			for _, note in w.notes do
				if note.event == event then
					found = note
					count += 1
				end
			end
			return found, count
		end
		function w.atGates(): boolean
			return math.abs(w.root.Position.X - Course.QUIT.x) < 1 and w.root.Position.Y < 20
		end
		return w
	end

	local function sum(list: { number }): number
		local total = 0
		for _, n in list do
			total += n
		end
		return total
	end

	test("Parkour skip: pays nothing and only unlocks the next map", function()
		local w = newWorld()
		local p = w.session.profile
		p.money = 1000
		check(w.start(1), "map 1 starts")
		eq(w.rec.stage, 1, "starting map 1 reaches stage 1")
		local preview = w.def.rewardPreview(w.player, 1)
		check(preview.full and preview.cash > 0, "map 1's first clear pays")
		w.skip()
		eq(p.money, 1000 - SKIP_COST, "the skip costs its price and pays nothing back")
		eq(p.totalEarned, 0, "nothing earned")
		eq(w.rec.clears[1], 0, "no clear counted")
		eq(w.rec.best[1], 0, "no best time")
		eq(w.rec.stage, 1, "the saved stage does not rise")
		eq(p.modes.parkour.lastRewardAt, 0, "the reward cooldown is untouched")
		eq(p.modes.parkour.clears, 0, "level 1's mirror is untouched")
		eq(w.rec.skipped[1], 1, "the skip is saved")
		eq(#w.rec.skipped, Course.LEVEL_COUNT, "one slot per level")
		eq(select(2, w.note("finish")), 0, "no finish card")
		local note = w.note("skip")
		check(note ~= nil, "a skip notify")
		eq(note.paid, 0, "skip notify: paid 0")
		eq(note.level, 1, "skip notify: the skipped map")
		eq(note.nextLevel, 2, "skip notify: the next map")
		eq(note.unlocked, 2, "skip notify: maps unlocked")
		local snap = w.def.snapshot(w.player)
		eq(snap.unlocked, 2, "map 2 is unlocked")
		eq(snap.level, 2, "the picker's default is the next map")
		eq(snap.bestStage, 1, "best stage unchanged")
		eq(snap.levels[1].clears, 0, "map 1 still shows no clear")
		local after = w.def.rewardPreview(w.player, 1)
		eq(after.cash, preview.cash, "map 1's first clear still pays in full")
	end)

	test("Parkour skip: ends at the gates with the picker, no run on the next map", function()
		local w = newWorld()
		w.session.profile.money = 1000
		w.start(1)
		w.skip()
		eq(w.def.running(w.player), false, "no run after a skip")
		eq(select(2, w.note("start")), 1, "the next map does not start by itself")
		eq(w.gates, 1, "taken to the gates")
		check(w.atGates(), "standing in front of the gates")
		eq(w.attributes.ParkourStage, 0, "no stage on the HUD")
		local order = {}
		for _, note in w.notes do
			table.insert(order, note.event)
		end
		eq(table.concat(order, ","), "start,skip,stop,pick", "notifies in order")
		eq(w.note("stop").reason, "skip", "the HUD run ends")
		eq(w.note("pick").level, 2, "the picker opens on the next map")
		-- Standing at the gates the rescue leaves them alone.
		w.wait(5)
		eq(w.gates, 1, "no second teleport")
	end)

	test("Parkour skip: the real first clear of a skipped map still pays", function()
		local w = newWorld()
		local p = w.session.profile
		p.money = 1000
		w.start(1)
		w.skip()
		local money = p.money
		w.clear(1)
		local note = w.note("finish")
		check(note ~= nil, "a finish card")
		eq(note.first, true, "counted as the first clear")
		check(note.full and note.cash > 0, "paid in full")
		eq(p.money, money + note.cash, "cash received")
		eq(w.rec.clears[1], 1, "one clear")
		eq(w.rec.stage, 2, "finishing map 1 reaches stage 2")
		eq(note.unlockedNew, false, "map 2 was already unlocked by the skip")
	end)

	test("Parkour skip: refused, and free, with nothing to unlock or too little cash", function()
		local w = newWorld()
		local p = w.session.profile
		-- Too little cash.
		p.money = SKIP_COST - 1
		w.start(1)
		w.skip()
		eq(p.money, SKIP_COST - 1, "not charged without the cash")
		eq(w.def.running(w.player), true, "the run goes on")
		eq(w.def.snapshot(w.player).unlocked, 1, "nothing unlocked")
		-- The next map is already unlocked.
		p.money = 5000
		w.rec.clears[1] = 1
		w.skip()
		eq(p.money, 5000, "not charged when the next map is already unlocked")
		eq(w.def.running(w.player), true, "the run goes on")
		eq(w.note("skip"), nil, "no skip notify")
		-- The last map has no next map.
		for i = 1, Course.LEVEL_COUNT - 1 do
			w.rec.clears[i] = 1
		end
		w.start(Course.LEVEL_COUNT)
		w.skip()
		eq(p.money, 5000, "not charged on the last map")
		eq(w.rec.clears[Course.LEVEL_COUNT], 0, "the last map is not cleared by a skip")
		eq(w.def.running(w.player), true, "the run goes on")
		eq(#w.toasts, 3, "each refusal says why")
	end)

	test("Parkour stage: skipped maps never count on the STAGE board", function()
		local w = newWorld()
		local p = w.session.profile
		p.money = 1e6
		for level = 1, Course.LEVEL_COUNT - 1 do
			check(w.start(level), "map " .. level .. " starts")
			w.skip()
		end
		eq(p.money, 1e6 - SKIP_COST * (Course.LEVEL_COUNT - 1), "nine skips cost nine prices")
		eq(p.totalEarned, 0, "and pay nothing")
		eq(sum(w.rec.clears), 0, "no clears")
		eq(w.def.snapshot(w.player).unlocked, Course.LEVEL_COUNT, "every map unlocked")
		eq(w.rec.stage, 1, "still on stage 1")
		-- Starting a map behind skipped ones shows its number on the HUD but saves nothing.
		check(w.start(Course.LEVEL_COUNT), "the last map starts")
		eq(w.attributes.ParkourStage, Course.LEVEL_COUNT, "HUD: the map being run")
		eq(w.attributes.ParkourBestStage, 1, "best stage attribute")
		eq(w.rec.stage, 1, "saved stage")
		-- Real clears count again, in a row from map 1.
		w.clear(Course.LEVEL_COUNT)
		eq(w.rec.stage, 1, "a clear behind skipped maps does not count yet")
		w.clear(1)
		eq(w.rec.stage, 2, "map 1 cleared: stage 2")
		for level = 2, Course.LEVEL_COUNT - 1 do
			w.clear(level)
			local expected = if level == Course.LEVEL_COUNT - 1 then Course.STAGE_COUNT else level + 1
			eq(w.rec.stage, expected, "stage after really clearing map " .. level)
		end
		eq(w.def.snapshot(w.player).bestStage, Course.STAGE_COUNT, "the whole obby")
	end)

	test("Parkour stage: unchanged without skips, and a saved stage never drops", function()
		local w = newWorld()
		for level = 1, 3 do
			check(w.start(level), "map " .. level .. " starts")
			eq(w.rec.stage, level, "starting map " .. level)
			w.clear(level)
			eq(w.rec.stage, level + 1, "finishing map " .. level)
		end
		eq(w.def.snapshot(w.player).unlocked, 4, "three clears unlock map 4")
		-- A player who skipped maps before this rule keeps what the save holds.
		local old = newWorld()
		old.rec.clears = { 1, 1, 1, 1, 0, 0, 0, 0, 0, 0 }
		old.rec.stage = 9
		-- (A record read before DataService.reconcile padded it: no `skipped` list at all.)
		old.rec.skipped = nil
		eq(old.def.snapshot(old.player).unlocked, 5, "unlocks follow the saved clears")
		check(old.start(5), "map 5 starts")
		eq(old.rec.stage, 9, "the saved stage stays")
		eq(old.rec.skipped, nil, "no skipped list is needed to read an old record")
	end)

	test("Parkour skip: the saved flag survives a save and reconcile", function()
		local w = newWorld()
		w.session.profile.money = 1000
		w.start(1)
		w.skip()
		local saved = serde.decode("json", serde.encode("json", w.session.profile))
		local loaded = DataService.reconcile(saved)
		eq(type(loaded.parkour.skipped), "table", "reconcile keeps the list")
		eq(loaded.parkour.skipped[1], 1, "map 1 skipped")
		eq(loaded.parkour.skipped[2], 0, "map 2 not skipped")
		local again = newWorld()
		again.session.profile = loaded
		eq(again.def.snapshot(again.player).unlocked, 2, "map 2 is still unlocked after a rejoin")
		eq(again.def.snapshot(again.player).level, 2, "and still the default")
		-- A broken list unlocks nothing and breaks nothing.
		loaded.parkour.skipped = { "x", -1, 0 / 0 }
		eq(again.def.snapshot(again.player).unlocked, 1, "junk in the list is ignored")
	end)

	test("Parkour rescue: a player with no run is not left on the sky course", function()
		local w = newWorld()
		local map2, map3 = Course.level(2), Course.level(3)
		local bridge = Course.BRIDGES[2]
		-- On a deck: left alone.
		w.onElement(map3.PATH[1])
		w.wait(6)
		eq(w.gates, 0, "standing on a start deck is fine")
		w.onElement(map2.PATH[#map2.PATH])
		w.wait(6)
		eq(w.gates, 0, "standing on a finish deck is fine")
		w.stand(map3.START.x, map3.START.y + 8, map3.START.z)
		w.wait(1)
		eq(w.gates, 0, "a jump on a deck is fine")
		-- On the bridge: 2 seconds.
		w.onElement(bridge[3])
		w.wait(1.5)
		eq(w.gates, 0, "crossing the bridge takes less than the limit")
		w.onElement(map3.PATH[1])
		w.wait(0.5)
		w.onElement(bridge[3])
		w.wait(1.5)
		eq(w.gates, 0, "a deck in between restarts the count")
		w.wait(1)
		eq(w.gates, 1, "waiting on the bridge: back to the gates")
		check(w.atGates(), "at the gates")
		eq(w.toasts[#w.toasts], "Back to the gates", "with a toast")
		-- Out on a map's path with no run.
		w.onElement(map3.PATH[4])
		w.wait(1.9)
		eq(w.gates, 1, "not yet")
		w.wait(0.3)
		eq(w.gates, 2, "a map's path with no run: back to the gates")
		-- Stepped off the start deck: below the cloud floor, at once.
		w.onElement(map3.PATH[1])
		w.wait(1)
		w.stand(map3.START.x + 14, Course.FLOOR_Y - 5, map3.START.z)
		w.wait(TICK)
		eq(w.gates, 3, "below the cloud floor: back to the gates at once")
		eq(#w.toasts, 3, "a toast each time")
		-- Falling well outside the map's rectangle, deep under the floor.
		w.wait(1)
		w.stand(map3.BOUNDS.x1 + 40, Course.FLOOR_Y - 120, map3.START.z)
		w.wait(TICK)
		eq(w.gates, 4, "a drifting fall is still caught")
	end)

	test("Parkour rescue: runners and players on the ground are left alone", function()
		local w = newWorld()
		-- The hub, the plazas and the sea lie under some maps: nobody down there is touched.
		for n, region in Course.REGIONS do
			local centre = Course.CENTRES[n]
			for _, y in { -1, 0, 30, 100 } do
				w.stand(centre[1], y, centre[2])
				w.wait(3)
				w.stand(region.x0, y, region.z0)
				w.wait(3)
			end
		end
		eq(w.gates, 0, "ground level under the course")
		eq(#w.toasts, 0, "no toast")
		-- A runner out on the path keeps the run.
		local map1 = Course.level(1)
		check(w.start(1), "map 1 starts")
		w.onElement(map1.PATH[2])
		w.wait(6)
		eq(w.gates, 0, "a runner is not rescued")
		eq(w.def.running(w.player), true, "the run goes on")
		-- A runner's fall goes back to the start deck, not to the gates.
		w.stand(map1.START.x, Course.FLOOR_Y - 5, map1.START.z)
		w.wait(TICK)
		eq(w.gates, 0, "a runner's fall is a respawn")
		eq(w.note("respawn") ~= nil, true, "respawn notify")
		-- Quitting right after: the old position may linger for a moment, no second trip.
		w.def.stop(w.player, "quit")
		w.stand(map1.START.x, Course.FLOOR_Y - 5, map1.START.z)
		w.wait(0.3)
		eq(w.gates, 0, "positions are not trusted right after a run ends")
	end)

	test("Parkour return: the timed return after a finish fires anywhere on the course", function()
		local w = newWorld()
		w.rec.clears[1] = 1
		local map2, map3 = Course.level(2), Course.level(3)
		w.clear(2)
		eq(#w.returns, 1, "one timed return")
		local first = w.returns[1]
		eq(first.seconds, 15, "after 15 seconds")
		eq(first.stillThere(w.root), true, "on the finish deck")
		w.onElement(Course.BRIDGES[2][2])
		eq(first.stillThere(w.root), true, "on the bridge")
		w.onElement(map3.PATH[1])
		eq(first.stillThere(w.root), true, "on the next map's start deck")
		w.stand(map3.START.x, Course.FLOOR_Y - 60, map3.START.z)
		eq(first.stillThere(w.root), true, "falling under it")
		w.stand(Course.QUIT.x, Course.QUIT.y, Course.QUIT.z)
		eq(first.stillThere(w.root), false, "not from the gates")
		w.stand(0, 0, 0)
		eq(first.stillThere(w.root), false, "not from the hub")
		-- A later finish takes over: the older return no longer fires.
		w.clear(2)
		eq(#w.returns, 2, "a second timed return")
		w.onElement(map2.PATH[#map2.PATH])
		eq(first.stillThere(w.root), false, "the older return is dropped")
		eq(w.returns[2].stillThere(w.root), true, "the newer one holds")
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
