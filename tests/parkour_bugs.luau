--[[
	Unit tests for the Parkour server (src/server/Modes/Parkour.luau, run against stub
	GameModes / Tycoon tables): a paid Skip Map only unlocks (no reward, no clear, no stage),
	it ends at the gates with the map picker, a clean finish inside the reward cooldown pays
	the repeat share (an assisted one nothing), falls and path progress reach the HUD, map 1's
	safer sweeper / bounce decks, and nobody is left on the sky course without a run (stranded
	rescue, the timed return after a finish).
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

	test("Parkour map 1: a wide centred bounce pad, side rails and a slower first sweeper", function()
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
		local sweeperDeck, bounceDeck = named("SweeperDeck"), named("BounceDeck")
		-- The path runs along Z over both decks: "wide" is X.
		local bounces = on(bounceDeck, "bounce")
		eq(#bounces, 1, "one bounce pad")
		local pad = bounces[1]
		eq(pad.r * 2, 9, "the pad is 9 studs wide")
		check(math.abs(pad.x - bounceDeck.x) < 0.01 and math.abs(pad.z - bounceDeck.z) < 0.01, "centred on the path line")
		for _, deck in { sweeperDeck, bounceDeck } do
			local rails = on(deck, "wall")
			eq(#rails, 2, deck.name .. ": two side rails")
			local sides = 0
			for _, rail in rails do
				eq(rail.name, "Rail", deck.name .. ": a rail, not a hop wall")
				eq(rail.h, 1.5, deck.name .. ": rails are 1.5 studs high")
				eq(rail.sz, deck.sz, deck.name .. ": the rail runs the deck's length")
				local edge = math.abs(rail.x - deck.x) + rail.sx / 2
				check(edge <= deck.sx / 2 + 1e-6 and edge >= deck.sx / 2 - 0.5, deck.name .. ": the rail stands on the deck's side edge")
				sides += if rail.x > deck.x then 1 else -1
			end
			eq(sides, 0, deck.name .. ": one rail on each side")
			local inner = math.abs(rails[1].x - deck.x) - rails[1].sx / 2
			if deck == bounceDeck then
				check(pad.r + 0.5 <= inner, "the pad and its ring fit between the rails")
				check(inner - pad.r <= 1, "no room to walk past the pad between the rails")
			else
				for _, bar in on(deck, "spinner") do
					-- A bar's end caps are balls 1.7 across (World.Modes spinner).
					check(bar.length / 2 + 0.85 <= inner, "sweeper bars turn inside the rails")
				end
			end
		end
		local sweepers = on(sweeperDeck, "spinner")
		eq(#sweepers, 2, "two sweepers")
		-- The first one met (nearest the deck before) turns 30% slower than it did (1.2 rad/s).
		local before = level.PATH[table.find(level.PATH, sweeperDeck) - 1]
		table.sort(sweepers, function(a, b)
			return math.abs(a.z - before.z) < math.abs(b.z - before.z)
		end)
		check(math.abs(math.abs(sweepers[1].speed) - 1.2 * 0.7) < 1e-9, "the first sweeper is 30% slower")
		check(math.abs(sweepers[1].speed) < math.abs(sweepers[2].speed), "and slower than the second")
		-- The bounce still works from anywhere on the wider pad at walking speed: launched at
		-- its near edge the runner comes down on the landing deck, launched at its far edge
		-- they are above the lane before reaching that deck (Fx.Modes: the pad is touched
		-- 0.4 studs past its rim; its top is 0.7 over the deck).
		local landing = level.PATH[table.find(level.PATH, bounceDeck) + 1]
		local g, v = Course.GRAVITY, pad.power
		local rise = landing.y - (bounceDeck.y + 0.7)
		local apex = v * v / (2 * g)
		check(apex > rise, "the bounce clears the landing deck")
		local air = v / g + math.sqrt(2 * (apex - rise) / g)
		local reach = Course.WALK_SPEED * air
		local climb = Course.WALK_SPEED * (v - math.sqrt(v * v - 2 * g * rise)) / g
		local dir = if landing.z > bounceDeck.z then 1 else -1
		local nearEdge = (landing.z - pad.z) * dir - landing.sz / 2
		local farEdge = nearEdge + landing.sz
		local touch = pad.r + 0.4
		check(nearEdge + touch + 0.3 <= reach, "a launch from the pad's near edge reaches the landing deck")
		check(touch + reach <= farEdge - 1, "a launch from its far edge does not overshoot it")
		check(nearEdge - touch - 1 >= climb, "a launch from its far edge is above the lane before the deck's edge")
		check(math.abs(landing.x - pad.x) + touch <= landing.sx / 2, "the landing deck is as wide as the pad's reach")
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
