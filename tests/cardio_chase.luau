--[[
	Unit tests for the CARDIO chaser Chads (src/server/Modes/CardioChase.luau).
	Loaded by tests/run.luau with its harness: { test, check, eq, near, seeded }.
]]

local fs = require("@lune/fs")
local luau = require("@lune/luau")

local MODES_DIR = "src/server/Modes/"

return function(h: { [string]: any })
	local test, check, eq = h.test, h.check, h.eq
	local function load(name: string, parent: { [string]: any })
		return luau.load(fs.readFile(MODES_DIR .. name .. ".luau"), {
			debugName = name,
			environment = setmetatable({
				script = { Parent = parent },
				require = function(module)
					return module
				end,
			}, { __index = _G }),
		})()
	end
	local Rules = load("CardioRules", {})
	local Layout = load("CardioLayout", { CardioRules = Rules })
	local Chase = load("CardioChase", { CardioRules = Rules, CardioLayout = Layout })

	local DT = 1 / 30

	-- Runs a runner at `walk` along stage n's path centre line from the trigger point, `delay`
	-- seconds late; it stops at the edge of any gap it can't clear. Returns the chase result
	-- and time.
	local function simulate(n: number, walk: number, delay: number): (string?, number)
		local sec = Chase.section(n)
		local path, line = sec.path, sec.line
		local s = Chase.arcAt(line, sec.x0 + Chase.TRIGGER)
		-- Edge of the first gap the runner can't clear.
		local block = math.huge
		for i = 1, #path - 1 do
			local a, b = path[i], path[i + 1]
			if b.x0 - a.x1 > Rules.reach(walk, b.top - a.top) then
				block = Chase.arcAt(line, a.x1)
				break
			end
		end
		local x, z = Chase.lineAt(line, s)
		local chase = Chase.begin(n, z, 0)
		local t = 0
		while t < 60 do
			t += DT
			if t > delay then
				s = math.min(block, s + walk * DT)
				x, z = Chase.lineAt(line, s)
			end
			local result = Chase.update(chase, x, z, t)
			if result then
				return result, t
			end
		end
		return nil, t
	end

	test("Cardio chase: stages 3, 6, 9 with rising tiers, sizes and speeds", function()
		eq(#Chase.STAGES, 3, "three chase stages")
		local prevTier, prevSpeed = 0, 0
		for _, n in Chase.STAGES do
			local tune = Chase.TUNING[n]
			check(tune ~= nil, "tuning for stage " .. n)
			check(tune.tier > prevTier, "tier rises")
			check(tune.scale >= 2 and tune.scale <= 2.5, "big Chad")
			check(tune.speed > prevSpeed, "speed rises")
			local walk = Rules.walkSpeed(Rules.STAGES[n].need)
			local prevWalk = Rules.walkSpeed(Rules.STAGES[n - 1].need)
			check(tune.speed < walk, `stage {n}: slower than walkSpeed(need) ({tune.speed} vs {walk})`)
			check(tune.speed > prevWalk, `stage {n}: faster than the previous need ({tune.speed} vs {prevWalk})`)
			prevTier, prevSpeed = tune.tier, tune.speed
			check(Chase.section(n) ~= nil, "section")
			check(not Chase.isChaseStage(n + 1), "only every third stage")
		end
	end)

	test("Cardio chase: a runner at the stage's need escapes, with slack", function()
		for _, n in Chase.STAGES do
			local walk = Rules.walkSpeed(Rules.STAGES[n].need)
			local result = simulate(n, walk, 0)
			eq(result, "escaped", `stage {n} on time`)
			result = simulate(n, walk, Chase.MIN_SLACK)
			eq(result, "escaped", `stage {n} with {Chase.MIN_SLACK}s lost`)
		end
	end)

	test("Cardio chase: the first chaser (stage 3) is the gentlest", function()
		local first = Chase.TUNING[3]
		local walk = Rules.walkSpeed(Rules.STAGES[3].need)
		check(Chase.FIRST_SLACK >= 2 * Chase.MIN_SLACK, "twice the slack of the later chases")
		eq(simulate(3, walk, Chase.FIRST_SLACK), "escaped", `stage 3 with {Chase.FIRST_SLACK}s lost`)
		eq(simulate(3, walk, Chase.FIRST_SLACK + 1), "caught", "but standing around still gets you caught")
		check(first.speed <= 0.86 * walk, `stage 3's Chad runs at 0.85 of the walk speed ({first.speed} vs {walk})`)
		for _, n in { 6, 9 } do
			local tune = Chase.TUNING[n]
			check(first.headStart > tune.headStart, `a longer head start than stage {n}`)
			local share = tune.speed / Rules.walkSpeed(Rules.STAGES[n].need)
			check(first.speed / walk < share, `a slower Chad for its stage than stage {n}`)
		end
	end)

	test("Cardio chase: a runner at the previous stage's need is caught", function()
		for _, n in Chase.STAGES do
			local walk = Rules.walkSpeed(Rules.STAGES[n - 1].need)
			local result = simulate(n, walk, 0)
			eq(result, "caught", `stage {n}`)
		end
	end)

	test("Cardio chase: position, ground and server flow", function()
		local chase = Chase.begin(3, Layout.ORIGIN.z, 100)
		local x0, z0 = Chase.position(chase, 100, Layout.ORIGIN.z + 30)
		eq(x0, chase.startX, "waits during the head start")
		eq(z0, chase.startZ, "start lane")
		local sec = Chase.section(3)
		local room = Layout.room(3)
		local x1, z1 = Chase.position(chase, chase.startAt + 1, Layout.ORIGIN.z + 999)
		check(x1 > chase.startX and x1 <= chase.startX + chase.speed + 1e-6, "runs at speed along the path")
		local _, pz, half = Chase.lineAt(sec.line, chase.startS + chase.speed)
		check(math.abs(z1 - math.min(pz + half, chase.zMax)) < 1e-6, "eases to the player's side of the path")
		check(z1 <= room.z1 - Chase.WALL_MARGIN, "inside the room")
		local xEnd = Chase.position(chase, chase.startAt + 1000, Layout.ORIGIN.z)
		check(xEnd < chase.endX, "stops before the end platform")
		check(math.abs(xEnd - sec.stopX) < 0.2, "stops at stopX")
		check(sec.x0 > room.x0 and sec.endX < room.x1, "section inside the bridge room")
		for i = 2, #sec.line do
			check(sec.line[i].s >= sec.line[i - 1].s and sec.line[i].x >= sec.line[i - 1].x, "line runs forward")
		end
		-- On every surface the centre line stays on that surface.
		for _, surf in sec.path do
			local _, lz = Chase.lineAt(sec.line, Chase.arcAt(sec.line, (surf.x0 + surf.x1) / 2))
			check(lz >= surf.z0 and lz <= surf.z1, "line on the surface")
		end
		for _, s in sec.path do
			eq(Chase.groundY(sec.path, (s.x0 + s.x1) / 2), s.top, "on a surface")
		end
		for i = 1, #sec.path - 1 do
			local a, b = sec.path[i], sec.path[i + 1]
			if b.x0 > a.x1 then
				check(Chase.groundY(sec.path, (a.x1 + b.x0) / 2) > math.min(a.top, b.top), "arc over a gap")
			end
		end

		local sent = {}
		local server = Chase.serve(function(_, event, payload)
			table.insert(sent, { event = event, payload = payload })
		end)
		local p = {}
		local z = Layout.ORIGIN.z
		eq(server.tick(p, sec.x0 - 10, z, 0), false, "nothing in the safe zone")
		eq(#sent, 0, "no chase yet")
		server.tick(p, sec.x0 + Chase.TRIGGER + 1, z, 0)
		eq(sent[1] and sent[1].event, "chase", "chase begins")
		eq(sent[1].payload.stage, 3, "chase stage")
		check(type(sent[1].payload.path) == "table", "path sent")
		eq(server.tick(p, sec.x0 + Chase.TRIGGER + 1, z, 10), true, "standing still gets caught")
		eq(sent[2].event, "caught", "caught notify")
		server.tick(p, sec.x0 + Chase.TRIGGER + 1, z, 20)
		eq(sent[3].event, "chase", "restarts")
		server.tick(p, sec.endX + 1, z, 20.5)
		eq(sent[4].event, "chaseEnd", "escaped")
		eq(sent[4].payload.reason, "escaped", "reason")
		server.tick(p, sec.x0 + Chase.TRIGGER + 1, z, 30)
		eq(#sent, 4, "an escaped stage is not chased again this run")
		server.forget(p)
		server.tick(p, sec.x0 + Chase.TRIGGER + 1, z, 40)
		eq(sent[5].event, "chase", "new run chases again")
		server.stop(p, "fall")
		eq(sent[6].event, "chaseEnd", "stop ends it")
		eq(server.active(p), nil, "no chase left")
	end)
end
