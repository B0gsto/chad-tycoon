--[[
	Unit tests for the Parkour server (src/server/Modes/Parkour.luau, run against stub
	GameModes / Tycoon tables): a paid Skip Map only unlocks (no reward, no clear, no stage),
	it ends at the gates with the map picker, a clean finish inside the reward cooldown pays
	the repeat share (an assisted one nothing), falls and path progress reach the HUD, map 1's
	safer sweeper / bounce decks, and nobody is left on the sky course without a run (stranded
	rescue, the timed return after a finish). Also what the course does to a runner's body
	(src/shared/ParkourMoves.luau, applied by src/client/Fx/Modes.luau): a bounce pad launches
	everyone who touches it, walking or jumping, at full power, and map 1's sweepers only
	shove along the deck.
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
local Moves = require("../src/shared/ParkourMoves")

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

	test("Parkour repeat pay: a clean finish inside the cooldown pays the repeat share", function()
		local w = newWorld()
		local p = w.session.profile
		w.clear(1)
		local first = w.note("finish")
		check(first.full and first.first, "the first clear pays in full")
		eq(first.pay, "first", "finish payload: pay = first")
		eq(first.cash, first.packCash, "the whole pack")
		eq(first.repeatShare, Economy.MODE_REPEAT_SHARE, "the share is sent for the card")
		local pack = first.packCash
		local share = math.floor(pack * Economy.MODE_REPEAT_SHARE)
		check(share > 0 and share < pack, "the repeat share is a part of the pack")
		eq(first.repeatCash, share, "finish payload: repeatCash")
		local stamp = p.modes.parkour.lastRewardAt
		check(stamp > 0, "the full reward starts the cooldown")
		local preview = w.def.rewardPreview(w.player, 1)
		eq(preview.full, false, "inside the cooldown")
		eq(preview.cash, share, "the preview shows the repeat share")
		eq(preview.repeatCash, share, "preview: repeatCash")
		eq(preview.packCash, pack, "preview: packCash")
		-- Every clean run inside the cooldown pays the share, and never moves the cooldown.
		for run = 2, 3 do
			local before = p.money
			-- (Past the map's rest: see "the run again bonus rests" below.)
			w.clock += 120
			w.clear(1)
			local again = w.note("finish")
			eq(again.full, false, "run " .. run .. ": not a full reward")
			eq(again.pay, "repeat", "run " .. run .. ": pay = repeat")
			eq(again.cash, share, "run " .. run .. ": pays the repeat share")
			eq(p.money, before + share, "run " .. run .. ": the wallet got it")
			eq(p.modes.parkour.lastRewardAt, stamp, "run " .. run .. ": the cooldown is untouched")
		end
		eq(w.rec.clears[1], 3, "every finish counts a clear")
		-- Another map's first clear inside the cooldown still pays in full, with its bonus.
		w.clear(2)
		local second = w.note("finish")
		eq(second.pay, "first", "map 2's first clear")
		eq(second.cash, math.floor(pack * Economy.parkourLevelBonus(2) + 0.5), "pays map 2's whole pack")
		eq(second.repeatCash, math.floor(second.packCash * Economy.MODE_REPEAT_SHARE), "map 2's repeat share follows its pack")
		-- The 30 minute full reward stays.
		p.modes.parkour.lastRewardAt = os.time() - Economy.MODE_REWARD_COOLDOWN - 1
		w.clear(1)
		local full = w.note("finish")
		check(full.full and not full.first, "the cooldown is over: a full reward")
		eq(full.pay, "full", "pay = full")
		eq(full.cash, pack, "the whole pack again")
	end)

	test("Parkour repeat pay: an assisted finish inside the cooldown pays nothing", function()
		local w = newWorld()
		local p = w.session.profile
		-- A character whose humanoid can wear the jump coil.
		local humanoid = {
			UseJumpPower = false,
			JumpHeight = 7.2,
			GetAttribute = function()
				return nil
			end,
		}
		w.player.Character = {
			FindFirstChildOfClass = function()
				return humanoid
			end,
		}
		w.actions.ParkourGear(w.session, { gear = "jump" })
		eq(w.def.rewardPreview(w.player, 1).full, true, "the first clear pays whatever is worn")
		w.clear(1)
		local first = w.note("finish")
		check(first.assisted and first.pay == "first" and first.cash == first.packCash, "an assisted first clear pays in full")
		eq(w.def.rewardPreview(w.player, 1).cash, 0, "preview with a coil chosen: nothing inside the cooldown")
		local before = p.money
		w.clear(1)
		local again = w.note("finish")
		check(again.assisted, "the second run wore the coil too")
		eq(again.pay, "assisted", "pay = assisted")
		eq(again.cash, 0, "assisted inside the cooldown pays 0")
		eq(p.money, before, "nothing paid")
		check(again.repeatCash > 0, "the card still knows what a clean run pays")
		eq(w.rec.clears[1], 2, "the clear still counts")
		-- Coil off: the next run is clean and pays the share.
		w.actions.ParkourGear(w.session, { gear = "none" })
		eq(w.def.rewardPreview(w.player, 1).cash, again.repeatCash, "preview without gear: the repeat share")
		w.clear(1)
		local clean = w.note("finish")
		check(not clean.assisted and clean.pay == "repeat" and clean.cash == again.repeatCash, "a clean run pays the share")
		-- Putting a coil on in the middle of a run makes it assisted: no share.
		check(w.start(1), "map 1 starts")
		w.actions.ParkourGear(w.session, { gear = "jump" })
		local l = Course.level(1)
		w.clock += l.MIN_SECONDS + 5
		w.onElement(l.PATH[#l.PATH])
		w.wait(TICK)
		eq(w.note("finish").cash, 0, "gear worn mid-run: nothing inside the cooldown")
	end)

	test("Parkour HUD data: falls are counted and progress follows the path", function()
		-- Course.progress: 0 at the start deck, 1 at the finish deck, never backwards along
		-- the path line (every map).
		for n, level in Course.LEVELS do
			local path = level.PATH
			eq(Course.progress(level, path[1].x, path[1].z), 0, "map " .. n .. ": 0 on the start deck")
			eq(Course.progress(level, path[#path].x, path[#path].z), 1, "map " .. n .. ": 1 on the finish deck")
			local last, monotone = 0, true
			for i = 1, #path - 1 do
				local a, b = path[i], path[i + 1]
				for step = 0, 8 do
					local t = step / 8
					local at = Course.progress(level, a.x + (b.x - a.x) * t, a.z + (b.z - a.z) * t)
					monotone = monotone and at >= last - 1e-9 and at >= 0 and at <= 1
					last = at
				end
			end
			check(monotone, "map " .. n .. ": progress is monotone along the path")
			-- Standing beside the line (a wide deck) reads like standing on it.
			local mid = path[#path // 2]
			check(
				math.abs(Course.progress(level, mid.x + 1, mid.z + 1) - Course.progress(level, mid.x, mid.z)) < 0.02,
				"map " .. n .. ": a step off the line barely moves it"
			)
		end
		-- The server publishes it (hundredths) and counts the falls of a run.
		local w = newWorld()
		local level = Course.level(1)
		local path = level.PATH
		check(w.start(1), "map 1 starts")
		eq(w.attributes.ParkourProgress, 0, "a run starts at 0")
		eq(w.def.snapshot(w.player).falls, 0, "and with no falls")
		local seen = 0
		for i = 2, #path - 1 do
			local e = path[i]
			if e.kind == "pad" then
				w.onElement(e)
				w.wait(1)
				local at = w.attributes.ParkourProgress
				check(at >= seen and at > 0 and at < 1, "the attribute rises along the path (element " .. i .. ")")
				eq(at, math.floor(Course.progress(level, e.x, e.z) * 100 + 0.5) / 100, "in hundredths of Course.progress")
				seen = at
			end
		end
		eq(w.def.snapshot(w.player).progress, seen, "the snapshot carries it")
		-- A fall: back to the start, progress 0, one fall counted; lava counts too.
		w.stand(path[4].x, Course.FLOOR_Y - 5, path[4].z)
		w.wait(TICK)
		local fell = w.note("respawn")
		check(fell ~= nil and fell.falls == 1, "the respawn notify counts the fall")
		eq(w.attributes.ParkourProgress, 0, "back at 0")
		w.wait(1)
		w.stand(path[6].x, Course.FLOOR_Y - 5, path[6].z)
		w.wait(TICK)
		eq(w.note("respawn").falls, 2, "the second fall")
		eq(w.def.snapshot(w.player).falls, 2, "the snapshot carries the falls")
		check(w.def.running(w.player), "the run goes on (no checkpoints, no reset)")
		w.clock += level.MIN_SECONDS + 5
		w.onElement(path[#path])
		w.wait(TICK)
		eq(w.note("finish").falls, 2, "the finish payload carries the falls")
		eq(w.attributes.ParkourProgress, 0, "no run: progress 0")
		-- A new run starts its own count.
		check(w.start(1), "map 1 starts again")
		eq(w.def.snapshot(w.player).falls, 0, "falls start at 0 again")
		w.def.stop(w.player, "quit")
		eq(w.attributes.ParkourProgress, 0, "quit: progress 0")
	end)

	-- Map 1's decks: `named` path element, and the elements of `kind` standing on a deck.
	local function map1(): (any, (string) -> any, (any, string) -> { any })
		local level = Course.level(1)
		local function named(name: string): any
			for _, e in level.PATH do
				if e.name == name then
					return e
				end
			end
			error("map 1 has no " .. name)
		end
		local function on(deck: any, kind: string): { any }
			local found = {}
			for _, e in level.ELEMENTS do
				if
					e.kind == kind
					and math.abs(e.y - deck.y) < 0.01
					and math.abs(e.x - deck.x) <= deck.sx / 2
					and math.abs(e.z - deck.z) <= deck.sz / 2
				then
					table.insert(found, e)
				end
			end
			return found
		end
		return level, named, on
	end

	test("Parkour map 1: a wide centred bounce pad, side rails and a slower first sweeper", function()
		local level, named, on = map1()
		local sweeperDeck, bounceDeck = named("SweeperDeck"), named("BounceDeck")
		-- The path runs along Z over both decks: "wide" is X.
		local bounces = on(bounceDeck, "bounce")
		eq(#bounces, 1, "one bounce pad")
		local pad = bounces[1]
		eq(pad.r * 2, 9, "the pad is 9 studs wide")
		check(math.abs(pad.x - bounceDeck.x) < 0.01 and math.abs(pad.z - bounceDeck.z) < 0.01, "centred on the path line")
		eq(sweeperDeck.x, bounceDeck.x, "the two decks are in line")
		local inners = {}
		for _, deck in { sweeperDeck, bounceDeck } do
			local rails = on(deck, "wall")
			eq(#rails, 2, deck.name .. ": two side rails")
			local sides = 0
			for _, rail in rails do
				eq(rail.name, "Rail", deck.name .. ": a rail, not a hop wall")
				-- A Humanoid steps up onto anything lower than its hips (about 2 studs: the
				-- 1.5-stud rails were walked along and off the deck). Hop walls are 2.4.
				check(rail.h >= 2.4, deck.name .. ": rails are too tall to step onto (" .. rail.h .. ")")
				eq(rail.sz, deck.sz, deck.name .. ": the rail runs the deck's length")
				local edge = math.abs(rail.x - deck.x) + rail.sx / 2
				check(edge <= deck.sx / 2 + 1e-6 and edge >= deck.sx / 2 - 0.5, deck.name .. ": the rail stands on the deck's side edge")
				sides += if rail.x > deck.x then 1 else -1
			end
			eq(sides, 0, deck.name .. ": one rail on each side")
			local inner = math.abs(rails[1].x - deck.x) - rails[1].sx / 2
			table.insert(inners, inner)
			if deck == bounceDeck then
				check(pad.r + 0.5 <= inner, "the pad and its ring fit between the rails")
				check(inner - pad.r <= 1, "no room to walk past the pad between the rails")
				-- A body is at least half a stud deep: nobody between the rails stands
				-- outside the pad's touch zone (Moves.onPad, from the deck up).
				check(inner - 0.5 < pad.r + Moves.PAD_REACH, "everyone between the rails touches the pad")
			else
				for _, bar in on(deck, "spinner") do
					-- A bar's end caps are balls 1.7 across (World.Modes spinner).
					check(bar.length / 2 + 0.85 <= inner, "sweeper bars turn inside the rails")
				end
			end
		end
		-- The sweeper deck's rails stand outside the width of the rest deck before it (no rail
		-- end in the way of the hop onto it), and the bounce deck's narrower lane starts inside
		-- them: a rail end there stops a runner, it no longer lifts them (too tall to step on).
		local rest = level.PATH[table.find(level.PATH, sweeperDeck) - 1]
		check(inners[1] >= rest.sx / 2, "the sweeper deck's rails stand outside the rest deck's width")
		check(inners[2] <= inners[1], "the bounce deck's lane is inside the sweeper deck's")
		local sweepers = on(sweeperDeck, "spinner")
		eq(#sweepers, 2, "two sweepers")
		-- The first one met (nearest the deck before) turns 30% slower than it did (1.2 rad/s).
		local before = level.PATH[table.find(level.PATH, sweeperDeck) - 1]
		table.sort(sweepers, function(a, b)
			return math.abs(a.z - before.z) < math.abs(b.z - before.z)
		end)
		check(math.abs(math.abs(sweepers[1].speed) - 1.2 * 0.7) < 1e-9, "the first sweeper is 30% slower")
		check(math.abs(sweepers[1].speed) < math.abs(sweepers[2].speed), "and slower than the second")
		-- The bounce works for a runner who just walks on: the pad launches on the first touch
		-- (0.4 studs before its rim, feet still on the deck), and at walking speed they come
		-- down on the landing deck; launched from the far rim (feet on the pad's top, 0.7 over
		-- the deck) they are above the lane before that deck's edge and do not overshoot it.
		eq(Course.PAD_REACH, Moves.PAD_REACH, "Course and the client agree on the pad's touch zone")
		local landing = level.PATH[table.find(level.PATH, bounceDeck) + 1]
		local g, v = Course.GRAVITY, pad.power
		eq(v, 94, "power 94")
		local dir = if landing.z > bounceDeck.z then 1 else -1
		local nearEdge = (landing.z - pad.z) * dir - landing.sz / 2
		local farEdge = nearEdge + landing.sz
		local touch = pad.r + Moves.PAD_REACH
		local function air(rise: number): (number, number)
			local root = math.sqrt(v * v - 2 * g * rise)
			return Course.WALK_SPEED * (v - root) / g, Course.WALK_SPEED * (v + root) / g
		end
		local _, walked = air(landing.y - bounceDeck.y)
		local climb, long = air(landing.y - bounceDeck.y - Course.PAD_LIP)
		check(v * v / (2 * g) > landing.y - bounceDeck.y + 5, "the bounce clears the landing deck by far")
		check(walked - touch >= nearEdge + Course.SAFETY, "walked on at the pad's near rim, the runner lands on the landing deck")
		check(touch + long <= farEdge - 1, "a launch from its far rim does not overshoot it")
		check(nearEdge - touch - 1 >= climb, "a launch from its far rim is above the lane before the deck's edge")
		check(math.abs(landing.x - pad.x) + touch <= landing.sx / 2, "the landing deck is as wide as the pad's reach")
		check(Course.bounceFair(pad, landing), "Course.bounceFair agrees")
	end)

	test("Parkour bounce: a pad launches everyone who touches it, walking or jumping", function()
		local level, named, on = map1()
		local deck = named("BounceDeck")
		local pad = on(deck, "bounce")[1]
		local lip = Course.PAD_LIP
		local landing = level.PATH[table.find(level.PATH, deck) + 1]
		local dir = if landing.z > deck.z then 1 else -1
		local dt = 1 / 60
		-- One pass over the pad in the client's frames (Fx.Modes.step): `feet(z)` is the feet
		-- height over the DECK at each spot. Returns where the launches fired.
		local function pass(x: number, fromZ: number, toZ: number, speed: number, feet: (number) -> number): { number }
			local held, fired = false, {}
			local z = fromZ
			while (toZ - z) * dir > 0 do
				local flat = math.sqrt((x - pad.x) ^ 2 + (z - pad.z) ^ 2)
				local fire, now = Moves.padStep(held, Moves.onPad(flat, feet(z) - lip, pad.r, lip))
				held = now
				if fire then
					table.insert(fired, z)
				end
				z += dir * speed * dt
			end
			return fired
		end
		local near = pad.z - dir * (deck.sz / 2 + 1.3)
		local far = pad.z + dir * (deck.sz / 2 + 2)
		-- Walking on (W held from 1.3 studs before the deck, as the tester did): centre, both
		-- edges and right beside each rail. The feet step up the 0.7-stud lip over the pad.
		local railInner = deck.sx / 2 - 0.8
		for _, offset in { 0, -4, 4, -(railInner - 0.5), railInner - 0.5 } do
			local x = pad.x + offset
			local fired = pass(x, near, far, Course.WALK_SPEED, function(z: number): number
				return if math.sqrt((x - pad.x) ^ 2 + (z - pad.z) ^ 2) < pad.r then lip else 0
			end)
			eq(#fired, 1, string.format("walked on %.1f off the centre: one launch per contact", offset))
			-- ...on the first touch, before the deck's middle.
			check(
				#fired == 1 and (pad.z - fired[1]) * dir > 0,
				string.format("walked on %.1f off the centre: launched on the way in", offset)
			)
		end
		-- Jumping on, and dropping onto it from a sweeper's bump: one launch each.
		eq(#pass(pad.x, near, far, Course.WALK_SPEED, function(z: number): number
			return math.max(lip, 4 - 4 * math.abs(z - near) / 6)
		end), 1, "jumped on: one launch")
		-- The launch has no condition but the touch: the old code refused a runner who was
		-- rising (stepping up the lip gives 7 to 11 studs/s) and then held the contact, so a
		-- walk across the pad never launched.
		local fire, held = Moves.padStep(false, true)
		check(fire and held, "the first frame of a contact launches")
		fire, held = Moves.padStep(held, true)
		check(not fire and held, "the same contact does not launch twice")
		fire, held = Moves.padStep(held, false)
		check(not fire and not held, "leaving the pad arms it again")
		fire = Moves.padStep(held, true)
		check(fire, "the next contact launches again")
		-- The zone: the pad's top, its rim and the deck right beside it; not the air above.
		check(Moves.onPad(0, 0, pad.r, lip), "standing on the middle")
		check(Moves.onPad(pad.r + 0.3, -lip, pad.r, lip), "on the deck at its rim")
		check(not Moves.onPad(pad.r + 0.5, -lip, pad.r, lip), "not half a stud off its rim")
		check(not Moves.onPad(0, 1.5, pad.r, lip), "not a stud and a half above it")
		-- Full power, every time: the Humanoid answers a launch from the ground with its own
		-- jump one frame later (50 studs/s, what the tester measured: 51-52 instead of 94). The
		-- hold puts the runner back on the pad's arc.
		local g = Course.GRAVITY
		for _, fps in { 60, 30, 20 } do
			local step = 1 / fps
			local y, vy, t, apex, peak = 0, pad.power, 0, 0, 0
			local jumped = false
			while vy > 0 or t < Moves.HOLD_SECONDS do
				-- (Fx.Modes.stepHold, before physics.)
				vy = Moves.heldSpeed(vy, pad.power, t, g) or vy
				peak = if t > 0 then math.max(peak, vy) else peak
				-- Physics, and the Humanoid's jump on the first step after the launch.
				if not jumped then
					vy, jumped = 50, true
				end
				y += vy * step
				vy -= g * step
				t += step
				apex = math.max(apex, y)
			end
			check(peak >= pad.power - g * step - 1e-6, string.format("%d fps: back at the pad's speed a frame later (%.1f)", fps, peak))
			check(apex >= landing.y - deck.y + 5, string.format("%d fps: the apex clears the upper lane (%.1f up)", fps, apex))
		end
		eq(Moves.holdSpeed(94, Moves.HOLD_SECONDS + 0.01, g), nil, "after the hold the arc is the runner's own")
		eq(Moves.heldSpeed(94, 94, 0.05, g), nil, "a runner on the arc is left alone")
		-- Every pad on every map goes through the same code.
		local fx = fs.readFile("src/client/Fx/Modes.luau")
		check(
			string.find(fx, "Moves.padStep(padContact[pad] == true, Moves.onPad(", 1, true) ~= nil,
			"Fx.Modes launches through Moves.padStep"
		)
		check(string.find(fx, "AssemblyLinearVelocity.Y < 5", 1, true) == nil, "no speed condition on a launch")
		check(string.find(fx, "Moves.heldSpeed(", 1, true) ~= nil, "and holds the launch on its arc")
	end)

	test("Parkour map 1: a sweeper's hit is a low shove that stays between the rails", function()
		local level, named, on = map1()
		local deck = named("SweeperDeck")
		local sweepers = on(deck, "spinner")
		local rails = on(deck, "wall")
		local railInner = math.abs(rails[1].x - deck.x) - rails[1].sx / 2
		eq(Course.SHOVE_INSET, 3, "a shove stops 3 studs inside the deck's edges")
		local bounceDeck = named("BounceDeck")
		local bounceRails = on(bounceDeck, "wall")
		local laneInner = math.abs(bounceRails[1].x - bounceDeck.x) - bounceRails[1].sx / 2
		local pad = on(bounceDeck, "bounce")[1]
		for _, bar in sweepers do
			eq(bar.shove, 3, "a hit slides the runner 3 studs")
			local keep = Course.shoveKeep(level.ELEMENTS, bar)
			check(keep ~= nil, "the sweeper has a keep box")
			-- A body is a stud to each side of its centre: the keep box holds it off the rails
			-- and on the deck (3-stud gap before it, 1-stud gap after it).
			check(keep.x0 >= deck.x - railInner + 1 and keep.x1 <= deck.x + railInner - 1, "the keep box is clear of the rails")
			check(keep.z0 >= deck.z - deck.sz / 2 + 1 and keep.z1 <= deck.z + deck.sz / 2 - 1, "and of the deck's ends")
			-- A shoved runner who then walks straight on passes between the bounce deck's rail
			-- ends (a stud of body each side) and onto the pad.
			check(
				keep.x1 - deck.x + 1 <= laneInner and deck.x - keep.x0 + 1 <= laneInner,
				"a shoved runner still fits the bounce deck's lane"
			)
			check(keep.x1 - pad.x < pad.r and pad.x - keep.x0 < pad.r, "and walks onto the pad")
			-- Every spot a bar reaches, every direction, at 60 and at 15 frames a second.
			for _, fps in { 60, 15 } do
				for ox = -4, 4, 2 do
					for oz = -5, 5, 2.5 do
						for angle = 0, 2 * math.pi - 0.01, math.pi / 6 do
							local x0, z0 = bar.x + ox, bar.z + oz
							x0, z0 = math.clamp(x0, keep.x0, keep.x1), math.clamp(z0, keep.z0, keep.z1)
							local x, z, done, t = x0, z0, 0, 0
							repeat
								t += 1 / fps
								local target = bar.shove * Moves.shoveShare(t)
								x, z = Moves.shoveTo(x, z, math.cos(angle) * (target - done), math.sin(angle) * (target - done), keep)
								done = target
							until t >= Moves.SHOVE_SECONDS
							local moved = math.sqrt((x - x0) ^ 2 + (z - z0) ^ 2)
							check(moved <= bar.shove + 1e-6, "a shove moves the runner 3 studs at the most")
							check(x >= keep.x0 - 1e-6 and x <= keep.x1 + 1e-6, "and never toward a rail past the keep box")
							check(z >= keep.z0 - 1e-6 and z <= keep.z1 + 1e-6, "nor off the deck's ends")
						end
					end
				end
			end
		end
		eq(Moves.shoveShare(Moves.SHOVE_SECONDS), 1, "the whole shove is done in SHOVE_SECONDS")
		-- A runner already outside the box (walking beside a rail) is not pulled in or pushed out.
		local keep = Course.shoveKeep(level.ELEMENTS, sweepers[1])
		local x = Moves.shoveTo(keep.x1 + 0.7, deck.z, 3, 0, keep)
		eq(x, keep.x1 + 0.7, "outside the box: not pushed further out")
		x = Moves.shoveTo(keep.x1 + 0.7, deck.z, -3, 0, keep)
		check(math.abs(x - (keep.x1 - 2.3)) < 1e-9, "but free to be shoved back in")
		-- No upward speed at all: the client's shove branch never jumps or sets a velocity.
		local fx = fs.readFile("src/client/Fx/Modes.luau")
		local from = string.find(fx, "if m.shove > 0 then", 1, true)
		local to = from and string.find(fx, "else", from, true)
		check(from ~= nil and to ~= nil, "Fx.Modes has the shove branch")
		if from and to then
			local branch = string.sub(fx, from, to)
			check(string.find(branch, "ChangeState", 1, true) == nil, "a shove is no jump")
			check(string.find(branch, "AssemblyLinearVelocity", 1, true) == nil, "and sets no speed")
		end
		local world = fs.readFile("src/server/World/Modes.luau")
		check(string.find(world, 'SetAttribute("BumpShove", e.shove)', 1, true) ~= nil, "World.Modes hands the shove to the client")
		-- Later maps keep their difficulty: their sweepers still bump.
		for n = 2, Course.LEVEL_COUNT do
			for _, e in Course.level(n).ELEMENTS do
				if e.kind == "spinner" then
					check(
						e.shove == nil and Course.shoveKeep(Course.level(n).ELEMENTS, e) == nil,
						"map " .. n .. ": sweepers bump as before"
					)
				end
			end
		end
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

	test("Parkour return: the timed return leaves a player who walked on", function()
		local w = newWorld()
		w.rec.clears[1] = 1
		local map2, map3 = Course.level(2), Course.level(3)
		w.clear(2)
		eq(#w.returns, 1, "one timed return")
		local first = w.returns[1]
		eq(first.seconds, 15, "after 15 seconds")
		eq(first.stillThere(w.root), true, "on the finish deck")
		w.stand(map2.PATH[#map2.PATH].x, map2.PATH[#map2.PATH].y + 6, map2.PATH[#map2.PATH].z)
		eq(first.stillThere(w.root), true, "hopping on the finish deck")
		-- They walked the bridge on purpose: a bridge and a start deck are not "outside".
		for k, step in Course.BRIDGES[2] do
			w.onElement(step)
			eq(first.stillThere(w.root), false, "not from bridge step " .. k)
		end
		w.onElement(map3.PATH[1])
		eq(first.stillThere(w.root), false, "not from the next map's start deck")
		w.stand(map3.START.x, map3.START.y + 6, map3.START.z)
		eq(first.stillThere(w.root), false, "nor from a hop on it")
		for n = 1, Course.LEVEL_COUNT do
			w.onElement(Course.level(n).PATH[1])
			eq(first.stillThere(w.root), false, "not from map " .. n .. "'s start deck")
		end
		-- Off the decks or below the cloud floor it still fires (as the 2 second rule says).
		w.onElement(map3.PATH[4])
		eq(first.stillThere(w.root), true, "out on a map's path")
		w.stand(map3.START.x, Course.FLOOR_Y - 60, map3.START.z)
		eq(first.stillThere(w.root), true, "falling under it")
		-- The player on the next start deck is then left alone by both rules.
		w.onElement(map3.PATH[1])
		w.wait(20)
		eq(w.gates, 0, "standing on the next map's start deck: not moved")
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

	test("Parkour repeat pay: the run again bonus rests for two minutes per map", function()
		local w = newWorld()
		local p = w.session.profile
		w.clear(1)
		w.clear(2)
		local share = w.def.rewardPreview(w.player, 1).repeatCash
		eq(w.def.rewardPreview(w.player, 1).repeatRest, 0, "nothing rests before a bonus was paid")
		w.clear(1)
		local paid = w.note("finish")
		eq(paid.pay, "repeat", "the first run again pays the bonus")
		eq(paid.cash, share, "the share")
		eq(paid.repeatRest, 120, "and the card knows the bonus now rests")
		local paidAt = w.clock
		-- Straight away again: the run finishes as usual, the bonus rests.
		local before, clears = p.money, w.rec.clears[1]
		local preview = w.def.rewardPreview(w.player, 1)
		eq(preview.cash, 0, "the preview pays nothing while it rests")
		check(preview.repeatRest > 0 and preview.repeatRest <= 120, "the preview says for how long")
		w.clear(1)
		local rested = w.note("finish")
		eq(rested.pay, "resting", "pay = resting")
		eq(rested.cash, 0, "nothing paid")
		eq(p.money, before, "the wallet is untouched")
		eq(w.rec.clears[1], clears + 1, "the clear still counts")
		check(rested.time > 0 and rested.best > 0, "the run finished normally")
		check(rested.repeatRest > 0 and rested.repeatRest < 120, "the rest was not started again")
		eq(rested.repeatCash, share, "the card still knows the bonus")
		-- Another map has its own two minutes, but any bonus rests every map for a minute.
		local other = w.def.rewardPreview(w.player, 2)
		check(w.clock < paidAt + 60, "still inside the minute")
		eq(other.cash, 0, "map 2 pays nothing inside the minute")
		check(other.repeatRest > 0 and other.repeatRest <= 60, "and rests for the rest of the minute, not two")
		w.clock = paidAt + 60
		eq(w.def.rewardPreview(w.player, 2).repeatRest, 0, "a minute later map 2 is awake")
		check(w.def.rewardPreview(w.player, 1).repeatRest > 0, "map 1 still rests")
		w.clear(2)
		eq(w.note("finish").pay, "repeat", "map 2's bonus is paid")
		eq(w.def.rewardPreview(w.player, 2).repeatRest, 120, "and rests for its own two minutes")
		-- Two minutes after the bonus was paid it is back.
		w.clock += 120
		eq(w.def.rewardPreview(w.player, 1).repeatRest, 0, "awake again")
		w.clear(1)
		local back = w.note("finish")
		eq(back.pay, "repeat", "pay = repeat again")
		eq(back.cash, share, "the share again")
		-- A full reward never rests.
		p.modes.parkour.lastRewardAt = os.time() - Economy.MODE_REWARD_COOLDOWN - 1
		w.clear(1)
		check(w.note("finish").pay == "full" and w.note("finish").cash == back.packCash, "the full reward is paid in the rest")
	end)

	test("Parkour repeat pay: the snapshot says how long every map's bonus rests", function()
		local w = newWorld()
		local p = w.session.profile
		for level = 1, 3 do
			w.rec.clears[level] = 1
		end
		p.modes.parkour.lastRewardAt = os.time()
		local function rests(): { number }
			local out = {}
			for i, lv in w.def.snapshot(w.player).levels do
				out[i] = lv.repeatRest
			end
			return out
		end
		local before = rests()
		eq(#before, Course.LEVEL_COUNT, "one entry per map")
		eq(sum(before), 0, "nothing rests before a bonus was paid")
		-- Map 1 pays its bonus: it rests two minutes, every other cleared map one.
		w.clear(1)
		eq(w.note("finish").pay, "repeat", "the bonus is paid")
		local after = rests()
		eq(after[1], 120, "map 1 rests for two minutes")
		eq(after[2], 60, "map 2 for one (the picker must not promise its bonus)")
		eq(after[3], 60, "map 3 too")
		eq(after[4], 0, "an uncleared map pays its first clear in full: no rest to show")
		-- What the picker shows is what a finish pays.
		for level = 1, 3 do
			eq(w.def.rewardPreview(w.player, level).cash, 0, "map " .. level .. ": a finish now pays nothing")
		end
		w.clock += 60
		after = rests()
		eq(after[1], 60, "a minute later map 1 has a minute left")
		eq(after[2], 0, "and map 2 is awake")
		check(w.def.rewardPreview(w.player, 2).cash > 0, "map 2 pays again")
		-- Once the full reward is back nothing rests.
		w.clear(2)
		check(rests()[2] > 0, "map 2 rests after its bonus")
		p.modes.parkour.lastRewardAt = os.time() - Economy.MODE_REWARD_COOLDOWN - 1
		eq(sum(rests()), 0, "the full reward never rests")
		-- The picker and the Modes row read it, with the card's words.
		local picker = fs.readFile("src/client/UI/MapPicker.luau")
		check(string.find(picker, "lv.repeatRest - State.age()", 1, true) ~= nil, "the picker counts the selected map's rest down")
		check(string.find(picker, '"Bonus is resting, back in " .. Format.time(rest)', 1, true) ~= nil, "and says so like the card")
		local windows = fs.readFile("src/client/UI/Windows.luau")
		check(string.find(windows, "rest = previewRest(lv)", 1, true) ~= nil, "the Modes row reads the map's rest")
		check(string.find(windows, '"Bonus is resting, back in " .. Format.time(rest)', 1, true) ~= nil, "with the same words")
	end)

	test("Parkour naming: MAP n and Difficulty n/10, no skip offered with nothing to unlock", function()
		local windows = fs.readFile("src/client/UI/Windows.luau")
		check(string.find(windows, '"MAP %d  ·  %s%s"', 1, true) ~= nil, "the Modes row says MAP n")
		check(string.find(windows, '"Level %d', 1, true) == nil, "no Level n left in the windows")
		check(string.find(windows, 'levelName.Text = "Level', 1, true) == nil, "nor before the first snapshot")
		check(string.find(windows, '"Difficulty %d/%d"', 1, true) ~= nil, "every difficulty row says Difficulty n/10")
		check(string.find(windows, 'string.format("%d/%d", difficulty', 1, true) == nil, "no bare n/10")
		local picker = fs.readFile("src/client/UI/MapPicker.luau")
		check(string.find(picker, '"Level ', 1, true) == nil, "no Level n in the picker")
		check(string.find(picker, '"MAP " .. ', 1, true) ~= nil, "the picker says MAP n")
		-- SKIP MAP: hidden on the last map and where the next map is open (the server refuses).
		local hud = fs.readFile("src/client/UI/ObbyHud.luau")
		check(
			string.find(hud, "local useful = not (maps > 0 and map >= maps) and unlocked <= map", 1, true) ~= nil,
			"the HUD knows when a skip is useless"
		)
		check(string.find(hud, "skip.Visible = useful", 1, true) ~= nil, "and hides the button then")
		local w = newWorld()
		for level = 1, Course.LEVEL_COUNT - 1 do
			w.rec.clears[level] = 1
		end
		eq(w.def.snapshot(w.player).levelCount, Course.LEVEL_COUNT, "the snapshot carries the map count")
		eq(w.def.snapshot(w.player).unlocked, Course.LEVEL_COUNT, "and what is unlocked")
		w.session.profile.money = 1e6
		check(w.start(Course.LEVEL_COUNT), "the last map starts")
		w.skip()
		eq(w.session.profile.money, 1e6, "the server refuses a skip on the last map, free")
	end)

	test("Parkour repeat pay: cycling the maps pays one bonus a minute at the most", function()
		local w = newWorld()
		local p = w.session.profile
		for level = 1, 3 do
			w.rec.clears[level] = 1
		end
		p.modes.parkour.lastRewardAt = os.time()
		local share = w.def.rewardPreview(w.player, 1).repeatCash
		check(share > 0, "a bonus to farm")
		local from, money, paid, rested = w.clock, p.money, 0, 0
		while w.clock - from < 600 do
			for level = 1, 3 do
				w.clear(level)
				local pay = w.note("finish").pay
				check(pay == "repeat" or pay == "resting", "inside the cooldown a clean run is a repeat or rests")
				paid += if pay == "repeat" then 1 else 0
				rested += if pay == "resting" then 1 else 0
			end
		end
		check(paid >= 2 and rested >= 1, "some paid, some rested")
		check(paid <= (w.clock - from) // 60 + 1, "one bonus a minute at the most, whatever the map")
		check(p.money - money <= paid * w.def.rewardPreview(w.player, 3).repeatCash, "and no more cash than that")
	end)

	test("Parkour return: the finish card holds the return, for 20 seconds at the most", function()
		local w = newWorld()
		w.rec.clears[1] = 1
		check(w.actions.ModeCard ~= nil, "the ModeCard action is handled")
		w.clear(2)
		eq(#w.returns, 1, "one timed return")
		-- The card is up when the 15 seconds are over: the return asks again a second later.
		w.actions.ModeCard(w.session, { mode = "parkour", open = true })
		w.clock += 15
		eq(w.returns[1].stillThere(w.root), false, "held while the card is up")
		eq(#w.returns, 2, "it looks again")
		eq(w.returns[2].seconds, 1, "a second later")
		-- Another mode's card holds nothing.
		w.actions.ModeCard(w.session, { mode = "parkour", open = false })
		w.actions.ModeCard(w.session, { mode = "mog", open = true })
		w.clock += 1
		eq(w.returns[2].stillThere(w.root), true, "the card closed: back to the gates")
		eq(#w.returns, 2, "and nothing more is scheduled")
		-- A client that never closes the card: 20 more seconds, then the return fires anyway.
		w.clear(2)
		local n = #w.returns
		w.actions.ModeCard(w.session, { mode = "parkour", open = true })
		w.clock += 15
		local polls = 0
		while not w.returns[#w.returns].stillThere(w.root) do
			polls += 1
			w.clock += 1
			check(polls <= 25, "the hold ends")
			if polls > 25 then
				break
			end
		end
		eq(polls, 20, "held for 20 seconds, no longer")
		eq(#w.returns, n + 20, "one look a second")
		-- A new finish starts with no card up, whatever the client last said.
		w.clear(2)
		w.clock += 15
		eq(w.returns[#w.returns].stillThere(w.root), true, "the old card does not hold the next return")
		-- A held return is still dropped when the player has left the sky.
		w.clear(2)
		w.actions.ModeCard(w.session, { mode = "parkour", open = true })
		w.clock += 15
		w.stand(0, 0, 0)
		local count = #w.returns
		eq(w.returns[count].stillThere(w.root), false, "not from the hub")
		eq(#w.returns, count, "and it does not look again")
	end)

	test("Parkour finish: SKY OBBY COMPLETE is the run that makes all ten maps clean", function()
		local w = newWorld()
		-- Nine maps cleared clean, map 10 first cleared with gear: not complete.
		for i = 1, Course.LEVEL_COUNT - 1 do
			w.rec.clears[i] = 1
			w.rec.best[i] = 60
		end
		local humanoid = {
			UseJumpPower = false,
			JumpHeight = 7.2,
			GetAttribute = function()
				return nil
			end,
		}
		w.player.Character = {
			FindFirstChildOfClass = function()
				return humanoid
			end,
		}
		w.actions.ParkourGear(w.session, { gear = "jump" })
		w.clear(Course.LEVEL_COUNT)
		local assisted = w.note("finish")
		check(assisted.first and assisted.assisted, "map 10's first clear wore gear")
		eq(assisted.complete, false, "an assisted clear does not complete the obby")
		-- The clean clear later does, though it is not the map's first.
		w.actions.ParkourGear(w.session, { gear = "none" })
		w.clear(Course.LEVEL_COUNT)
		local clean = w.note("finish")
		check(not clean.first and not clean.assisted, "a clean second clear")
		eq(clean.complete, true, "it completes the obby")
		-- Only once.
		w.clock += 120
		w.clear(Course.LEVEL_COUNT)
		eq(w.note("finish").complete, false, "the next clear is an ordinary one")
		-- A plain first clear of an early map is not it either.
		local fresh = newWorld()
		fresh.clear(1)
		eq(fresh.note("finish").complete, false, "map 1 of a new player")
	end)

	test("Parkour board: the best list says MAP n", function()
		local src = fs.readFile(MODES_DIR .. "Parkour.luau")
		check(string.find(src, '"MAP %d  %s  <b>%.2fs</b>"', 1, true) ~= nil, "a best time line")
		check(string.find(src, '"MAP %d  —"', 1, true) ~= nil, "an empty line")
		check(string.find(src, '"L%d', 1, true) == nil, "no L1 .. L10 left")
		local popups = fs.readFile("src/client/UI/Popups.luau")
		check(string.find(popups, "data.complete == true", 1, true) ~= nil, "the finish card goes by the server's complete flag")
		check(string.find(popups, 'data.pay == "resting"', 1, true) ~= nil, "and says when the bonus rests")
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
