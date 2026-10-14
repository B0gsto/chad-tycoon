--[[
	Unit tests for the solo mini-game foundation (docs/minigames.md): the catalog entries, the
	six plaza gates (Course.GATES / gateSpot / crossedGate) and where the three arenas float
	(Modes.ShakeRules / PoseRules / BowlingRules.ARENA). Each mode's own rules are tested in
	tests/shake.luau, tests/pose.luau and tests/bowling.luau.
	Loaded by tests/run.luau with its harness: { test, check, eq }.
]]

local fs = require("@lune/fs")
local luau = require("@lune/luau")

local MODES_DIR = "src/server/Modes/"

local function load(name: string): any
	return luau.load(fs.readFile(MODES_DIR .. name .. ".luau"), { debugName = name })()
end

return function(h: { [string]: any })
	local test, check, eq = h.test, h.check, h.eq
	local Course = load("Course")
	local Catalog = load("Catalog")
	local MogLayout = load("MogLayout")
	local ARENAS = {
		shake = load("ShakeRules").ARENA,
		pose = load("PoseRules").ARENA,
		bowling = load("BowlingRules").ARENA,
	}

	test("Mini-games: catalog entries on gates 4-6", function()
		local want = { shake = 4, pose = 5, bowling = 6 }
		local seen = 0
		for _, entry in Catalog do
			if want[entry.id] then
				eq(entry.slot, want[entry.id], entry.id .. " slot")
				check(entry.enabled, entry.id .. " is enabled")
				seen += 1
			end
		end
		eq(seen, 3, "all three mini-games are in the catalog")
		for _, id in { "Shake", "Pose", "Bowling" } do
			local src = fs.readFile(MODES_DIR .. id .. ".luau")
			for _, fn in { "def.start", "def.stop", "def.running", "def.tick", "def.snapshot", "def.rewardPreview" } do
				check(string.find(src, "function " .. fn, 1, true) ~= nil, id .. " implements " .. fn)
			end
			check(string.find(fs.readFile("src/server/GameModes.luau"), "Modes." .. id .. ",", 1, true) ~= nil, id .. " is in BUILTIN")
		end
	end)

	test("Mini-games: six gates walk in from the front only", function()
		for slot = 1, 6 do
			for plaza = 1, 2 do
				local x, z, fx, fz = Course.gateSpot(slot, plaza)
				check(x ~= nil and z ~= nil, string.format("gate %d on plaza %d", slot, plaza))
				local ox, oz = x + fx * 2, z + fz * 2
				local ix, iz = x - fx * 2, z - fz * 2
				eq(Course.crossedGate(slot, ox, oz, ix, iz), plaza, string.format("in through gate %d/%d", slot, plaza))
				eq(Course.crossedGate(slot, ix, iz, ox, oz), nil, string.format("out of gate %d/%d does not start", slot, plaza))
				-- Beside the opening does not count.
				local sx, sz = fz * (Course.GATE_HALF + 3), fx * (Course.GATE_HALF + 3)
				eq(Course.crossedGate(slot, ox + sx, oz + sz, ix + sx, iz + sz), nil, string.format("beside gate %d/%d", slot, plaza))
			end
		end
		-- Slot 1 agrees with Parkour's own start line.
		local L = Course.START_LINE_X
		check(Course.crossedStart(L + 1, L - 1, 0) and Course.crossedGate(1, L + 1, 0, L - 1, 0) == 1, "gate 1 matches crossedStart")
	end)

	test("Mini-games: gates stand apart, on the plaza, clear of the board", function()
		-- Footprint of a gate: its opening plus pillars and feet along the gate line (the
		-- 18-wide name card on top is narrower), 4.8 deep.
		local HALF_W, HALF_D = Course.GATE_HALF + 4.2, 2.4
		local boxes = {}
		for slot = 1, 6 do
			local x, z, fx, _fz = Course.gateSpot(slot, 1)
			local hx, hz = if fx ~= 0 then HALF_D else HALF_W, if fx ~= 0 then HALF_W else HALF_D
			boxes[slot] = { x0 = x - hx, x1 = x + hx, z0 = z - hz, z1 = z + hz }
			local p = Course.PLAZA
			check(x >= p.x0 and x <= p.x1 and z >= p.z0 and z <= p.z1, "gate " .. slot .. " on the plaza's edge")
			check(not Course.isClear(x, z), "gate " .. slot .. " inside CLEAR")
		end
		-- Every pair of the six gates keeps at least 2 studs of air between footprints.
		for a = 1, 6 do
			for b = a + 1, 6 do
				local A, B = boxes[a], boxes[b]
				local apart = A.x1 + 2 <= B.x0 or B.x1 + 2 <= A.x0 or A.z1 + 2 <= B.z0 or B.z1 + 2 <= A.z0
				check(apart, string.format("gates %d and %d do not overlap", a, b))
			end
		end
		-- The plaza stays clear of the plot rows (|z| >= PLOT_ROW_Z - PLOT_HALF = 54).
		check(Course.PLAZA.z0 > -50 and Course.PLAZA.z1 < 50, "plaza clear of the plot rows")
		local b = Course.BOARD
		for slot = 1, 6 do
			local B = boxes[slot]
			check(not (b.x > B.x0 - 9 and b.x < B.x1 + 9 and b.z > B.z0 - 3 and b.z < B.z1 + 3), "board clear of gate " .. slot)
		end
	end)

	test("Mini-games: arenas float at sea, clear of everything", function()
		local function gap(a: any, b: any): number
			local dx = math.max(0, math.abs(a.x - b.x) - (a.sizeX + b.sizeX) / 2)
			local dz = math.max(0, math.abs(a.z - b.z) - (a.sizeZ + b.sizeZ) / 2)
			return math.max(dx, dz)
		end
		local ids = { "shake", "pose", "bowling" }
		for i, id in ids do
			local a = ARENAS[id]
			check(a.y > Course.WATER_Y and a.y < 40, id .. " floats just over the sea")
			local near = math.sqrt(a.x * a.x + a.z * a.z) - math.max(a.sizeX, a.sizeZ) / 2
			check(near > Course.WATER_RADIUS + 40, id .. " is off the island")
			local mog = { x = MogLayout.CENTER.x, z = MogLayout.CENTER.z, sizeX = 160, sizeZ = 160 }
			check(gap(a, mog) > 60, id .. " clear of the Mog stage")
			for j = i + 1, #ids do
				check(gap(a, ARENAS[ids[j]]) >= 40, id .. " clear of " .. ids[j])
			end
			for n, level in Course.LEVELS do
				for _, e in level.ELEMENTS do
					local dx, dz = math.abs(e.x - a.x), math.abs(e.z - a.z)
					if dx < a.sizeX / 2 + 40 and dz < a.sizeZ / 2 + 40 then
						check(false, string.format("%s clear of Parkour map %d", id, n))
						break
					end
				end
			end
		end
	end)
end
