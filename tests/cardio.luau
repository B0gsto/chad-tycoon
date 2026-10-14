--[[
	Unit tests for the CARDIO rules (src/server/Modes/CardioRules.luau), the keyboard runway
	layout (src/server/Modes/CardioLayout.luau) and the run's rules (src/server/Modes/Cardio.luau):
	every run starts at stage 1, cash is paid only on a WIN plate, a fall or a catch goes back
	to stage 1, and inside the reward cooldown only a real run earns the run again bonus.
	Loaded by tests/run.luau with its harness: { test, check, eq, near, seeded }.
]]

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local roblox = require("@lune/roblox")

local Economy = require("../src/shared/Economy")

local MODES_DIR = "src/server/Modes/"

return function(h: { [string]: any })
	local test, check, eq, near = h.test, h.check, h.eq, h.near
	local Rules = luau.load(fs.readFile(MODES_DIR .. "CardioRules.luau"), { debugName = "CardioRules" })()
	local Layout = luau.load(fs.readFile(MODES_DIR .. "CardioLayout.luau"), {
		debugName = "CardioLayout",
		environment = setmetatable({
			script = { Parent = { CardioRules = Rules } },
			require = function(module)
				return module
			end,
		}, { __index = _G }),
	})()

	test("Cardio: walk speed curve is smooth, increasing and capped", function()
		eq(Rules.walkSpeed(0), 16, "16 at 0 Speed")
		near(Rules.walkSpeed(Rules.SPEED_AT_CAP), 120, "120 at the cap")
		eq(Rules.walkSpeed(Rules.SPEED_AT_CAP * 10), 120, "capped")
		eq(Rules.walkSpeed(-5), 16, "never below 16")
		local prev, prevStep = Rules.walkSpeed(0), math.huge
		for i = 1, 250 do
			local s = i * 500
			local w = Rules.walkSpeed(s)
			check(w > prev, "increasing at " .. s)
			check(w - prev <= prevStep + 1e-9, "diminishing returns at " .. s)
			prevStep = w - prev
			prev = w
		end
		near(Rules.walkSpeed(Rules.STAGES[Rules.STAGE_COUNT].need), Rules.WALK_CAP, "stage 10 needs the cap")
	end)

	test("Cardio: jump physics", function()
		near(Rules.airtime(0) :: number, 2 * math.sqrt(2 * 7.2 / 196.2), "flat airtime")
		check(Rules.airtime(7.3) == nil, "can't jump higher than the jump height")
		check((Rules.airtime(5) :: number) < (Rules.airtime(0) :: number), "step-ups land sooner")
		check((Rules.airtime(-5) :: number) > (Rules.airtime(0) :: number), "drops fly longer")
		near(Rules.maxGap(16), 16 * (Rules.airtime(0) :: number) - Rules.SAFETY, "maxGap(16)")
		check(Rules.maxGap(16) > 7 and Rules.maxGap(16) < 9, "default walk clears ~8 studs")
		check(Rules.reach(16) > Rules.maxGap(16), "reach includes the slack")
	end)

	test("Cardio: every stage needs its Speed (and not the previous one's)", function()
		eq(#Rules.STAGES, Rules.STAGE_COUNT, "stage count")
		eq(Rules.STAGES[1].need, 0, "stage 1 is free")
		local prevNeed, prevWalk = -1, 0
		for n, s in Rules.STAGES do
			check(s.need > prevNeed, "needs increase at " .. n)
			check(s.walk > prevWalk, "walks increase at " .. n)
			check(type(s.name) == "string" and #s.name > 0, "name at " .. n)
			check(s.rise <= Rules.MAX_STEP_UP, "rise <= 5 at " .. n)
			local K = Layout.KEY.size
			local function whole(v: number): boolean
				return math.abs(v / K - math.floor(v / K + 0.5)) < 1e-6
			end
			check(whole(s.width) and whole(s.plat), "platforms are whole keys at " .. n)
			check(s.width >= 4 * K - 1e-6 and s.width <= 9 * K + 1e-6, "bridges are 4-9 keys wide at " .. n)
			check((s.blinkOn ~= nil) == (n >= 4), "blinking keys from stage 4 at " .. n)
			check((s.movers ~= nil) == (n >= 6), "sliding keys from stage 6 at " .. n)
			local jumps = Rules.jumps(n)
			eq(#jumps, s.jumps, "jump count at " .. n)
			local longest, blocked = 0, false
			for k, j in jumps do
				check(j.rise <= Rules.MAX_STEP_UP, "step-up <= 5 at " .. n .. "." .. k)
				check(j.gap <= Rules.maxGap(s.walk, j.rise) + 1e-9, "clearable at need: " .. n .. "." .. k)
				check(j.gap > 2, "a real gap at " .. n .. "." .. k)
				longest = math.max(longest, j.gap)
				if n >= 2 and j.rise >= 0 and j.gap > Rules.reach(Rules.walkSpeed(Rules.STAGES[n - 1].need), j.rise) then
					blocked = true
				end
			end
			eq(longest, s.gap, "longest gap matches the table at " .. n)
			if n >= 2 then
				check(blocked, "the previous need can't clear stage " .. n)
				check(s.gap > Rules.maxGap(Rules.walkSpeed(Rules.STAGES[n - 1].need)), "gap above previous maxGap at " .. n)
			end
			prevNeed, prevWalk = s.need, s.walk
		end
		eq(Rules.stageFor(0), 1, "stageFor(0)")
		eq(Rules.stageFor(Rules.STAGES[5].need), 5, "stageFor(need 5)")
		eq(Rules.stageFor(1e9), 10, "stageFor(huge)")
	end)

	test("Cardio: multipliers, treadmills, costs, bonuses", function()
		eq(Rules.stepMultiplier(0, 0), 1, "base multiplier")
		check(Rules.stepMultiplier(3, 0) > Rules.stepMultiplier(2, 0), "clears raise the multiplier")
		check(Rules.stepMultiplier(3, 2) > Rules.stepMultiplier(3, 1), "levels raise the multiplier")
		eq(Rules.stepMultiplier(99, 99), Rules.stepMultiplier(10, 10), "clamped")
		for z = 0, 9 do
			check(Rules.treadmillRate(z + 1, 0) > Rules.treadmillRate(z, 0), "deeper treadmills are stronger at " .. z)
		end
		-- Treadmills grow with the runner's Speed on their own (never below the base rate).
		eq(Rules.treadmillRate(3, 2, 0), Rules.treadmillRate(3, 2), "speed 0 = base rate")
		eq(Rules.treadmillRate(3, 2, 100), Rules.treadmillRate(3, 2), "no shrink early on")
		local prevRate = 0
		for _, s in { 150, 1000, 8000, 45000, 125000 } do
			local r = Rules.treadmillRate(0, 0, s)
			check(r > prevRate, "faster runners train faster at " .. s)
			prevRate = r
		end
		check(Rules.treadmillRate(0, 0, 125000) >= 4 * Rules.treadmillRate(0, 0), "late treadmills stay useful")
		for l = 0, 9 do
			check(Rules.treadmillRate(0, l + 1) > Rules.treadmillRate(0, l), "levels speed the treadmill at " .. l)
			check(Rules.treadmillCost(l + 1, 0) > Rules.treadmillCost(l, 0), "minimum grows at " .. l)
			local income = 1000
			local c = Rules.treadmillCost(l, income)
			check(c >= 120 * income and c <= 360 * income, "2-6 minutes of income at " .. l)
		end
		eq(Rules.treadmillCost(0, 0), 150, "minimum cost")
		eq(Rules.treadmillCost(Rules.TREADMILL_MAX, 100), math.huge, "maxed")
		eq(Rules.stageBonus(1), 1, "stage 1 bonus")
		near(Rules.stageBonus(10), 3.25, "stage 10 bonus")
	end)

	test("Cardio: progression pace (coarse simulation)", function()
		-- Half the time running on keys (stepping 60% of it), half on the best treadmill
		-- reached; one treadmill level every 4 minutes.
		local speed, best, level, t = 0, 0, 0, 0
		local at: { number } = {}
		while best < Rules.STAGE_COUNT and t < 4 * 3600 do
			t += 1
			if t % 240 == 0 and level < Rules.TREADMILL_MAX then
				level += 1
			end
			local steps = Rules.walkSpeed(speed) / Rules.KEY_STEP * 0.6
			speed += 0.5 * steps * Rules.stepMultiplier(best, level) + 0.5 * Rules.treadmillRate(best, level, speed)
			while best < Rules.STAGE_COUNT and speed >= Rules.STAGES[best + 1].need do
				best += 1
				at[best] = t / 60
			end
		end
		check(at[2] <= 3, "stage 2 in the first few minutes (" .. at[2] .. ")")
		check(at[3] <= 6, "stage 3 soon after (" .. at[3] .. ")")
		check(at[10] >= 40 and at[10] <= 65, "stage 10 after ~45-60 min (" .. tostring(at[10]) .. ")")
	end)

	local L = Layout.generate()
	local O = Layout.ORIGIN
	local K = Layout.KEY.size
	local eps = 1e-6

	-- Calls fn(a, b) once for every pair of boxes whose cells (CELL studs, X/Z) touch.
	local function pairsNear(items: { any }, box: (any) -> (number, number, number, number), fn: (any, any) -> ())
		local CELL = 8
		local cells: { [number]: { number } } = {}
		local seen: { [number]: boolean } = {}
		for i, item in items do
			local x0, x1, z0, z1 = box(item)
			for cx = math.floor((x0 + eps) / CELL), math.floor((x1 - eps) / CELL) do
				for cz = math.floor((z0 + eps) / CELL), math.floor((z1 - eps) / CELL) do
					local id = cx * 65536 + cz
					local list = cells[id]
					if not list then
						list = {}
						cells[id] = list
					end
					for _, j in list do
						local pid = j * 100000 + i
						if not seen[pid] then
							seen[pid] = true
							fn(items[j], item)
						end
					end
					table.insert(list, i)
				end
			end
		end
	end

	local function keyBox(k: any): (number, number, number, number)
		local rz = k.sz / 2 + (k.travel or 0)
		return k.x - k.sx / 2, k.x + k.sx / 2, k.z - rz, k.z + rz
	end

	local function roomOf(stage: number): any
		for _, r in L.rooms do
			if r.kind == "bridge" and r.stage == stage then
				return r
			end
		end
		return nil
	end

	local function stagePlats(n: number): { any }
		local list = {}
		for _, p in L.platforms do
			if p.stage == n then
				table.insert(list, p)
			end
		end
		return list
	end

	-- Footprint (independent of Layout.footprint): surfaces with sweeps plus gap air boxes.
	local function footprint(n: number): { any }
		local out, prev = {}, nil
		for _, p in stagePlats(n) do
			local t = p.travel or 0
			local r = { x0 = p.x0, x1 = p.x1, z0 = p.z0 - t, z1 = p.z1 + t, top = p.top }
			table.insert(out, r)
			if prev and r.x0 > prev.x1 + eps then
				table.insert(out, {
					x0 = prev.x1,
					x1 = r.x0,
					z0 = math.min(prev.z0, r.z0),
					z1 = math.max(prev.z1, r.z1),
					top = math.max(prev.top, r.top),
				})
			end
			prev = r
		end
		return out
	end

	local function dist(a: any, c: any): number
		local dx = math.max(0, a.x0 - c.x1, c.x0 - a.x1)
		local dz = math.max(0, a.z0 - c.z1, c.z0 - a.z1)
		return math.sqrt(dx * dx + dz * dz)
	end

	test("Cardio: layout is deterministic", function()
		local again = Layout.generate()
		eq(#again.keys, #L.keys, "same key count")
		for i, k in L.keys do
			local o = again.keys[i]
			check(
				o.x == k.x
					and o.y == k.y
					and o.z == k.z
					and o.letter == k.letter
					and o.kind == k.kind
					and o.phase == k.phase
					and o.tint == k.tint,
				"same key " .. i
			)
		end
		for i, p in L.props do
			local o = again.props[i]
			check(o.x == p.x and o.z == p.z and o.kind == p.kind and o.scale == p.scale and o.yaw == p.yaw, "same prop " .. i)
		end
		for i, d in L.doors do
			eq(again.doors[i].phase, d.phase, "same door " .. i)
		end
		eq(#again.walls, #L.walls, "same walls")
		eq(#again.bases, #L.bases, "same bases")
		eq(#again.trusses, #L.trusses, "same trusses")
		eq(#again.zones, #L.zones, "same zones")
		eq(#L.zones, Rules.STAGE_COUNT + 1, "lobby + one safe zone per stage")
		eq(#L.signs, Rules.STAGE_COUNT, "one sign per stage")
	end)

	test("Cardio: key budget, bounds and key shapes", function()
		local keys = L.keys
		check(#keys <= 12500, "key budget (" .. #keys .. " keys)")
		check(#keys >= 3000, "a real course (" .. #keys .. " keys)")
		local b = L.bounds
		check(b.x0 >= -1300 and b.x1 <= 1300, "course inside x -1300..1300")
		check(b.x1 - b.x0 >= 2400, "the course uses the full length")
		check(b.z0 > 750, "clear of the parkour levels and the Mog stage")
		near((b.z0 + b.z1) / 2, 1150, "rooms centred on z = 1150")
		eq(O.z, 1150, "centre line")
		local valid = { key = true, blink = true, mover = true, deck = true, block = true }
		for i, k in keys do
			check(valid[k.kind], "kind of key " .. i)
			local x0, x1, z0, z1 = keyBox(k)
			check(x0 >= b.x0 and x1 <= b.x1 and z0 >= b.z0 and z1 <= b.z1, "key " .. i .. " inside bounds")
			local room = Layout.roomAt(k.x)
			check(room ~= nil and z0 >= room.z0 - eps and z1 <= room.z1 + eps, "key " .. i .. " inside its room (with its sweep)")
			check(k.y > Layout.KILL_Y + 5, "key " .. i .. " above the kill line")
			eq(k.sz, K, "keys are one key wide " .. i)
			eq(k.sx, K, "key length " .. i)
			check(#k.letter == 1 and string.find("ABCDEFGHIJKLMNOPQRSTUVWXYZ", k.letter, 1, true) ~= nil, "letter " .. i)
			check(k.group == 0 or L.platforms[k.group].id == k.group, "group points at its platform " .. i)
			check((k.kind == "block") == (k.block ~= nil and k.group == 0), "block keys point at their block " .. i)
		end
		for i, p in L.platforms do
			eq(p.id, i, "platform ids are list indexes")
		end
	end)

	test("Cardio: keys never overlap (spatial hash)", function()
		local H = Layout.KEY.height
		local overlaps = 0
		local function restBox(k: any): (number, number, number, number)
			return k.x - k.sx / 2, k.x + k.sx / 2, k.z - k.sz / 2, k.z + k.sz / 2
		end
		pairsNear(L.keys, keyBox, function(a, c)
			-- Keys of one section move together: compare them at rest, others over their sweeps.
			local box = if a.group > 0 and a.group == c.group then restBox else keyBox
			local ax0, ax1, az0, az1 = box(a)
			local cx0, cx1, cz0, cz1 = box(c)
			if
				ax0 < cx1 - eps
				and cx0 < ax1 - eps
				and az0 < cz1 - eps
				and cz0 < az1 - eps
				and a.y - H < c.y - eps
				and c.y - H < a.y - eps
			then
				overlaps += 1
			end
		end)
		eq(overlaps, 0, "overlapping keys")
	end)

	test("Cardio: every surface is a contiguous key carpet on a base", function()
		local area: { [string]: number } = {}
		for _, k in L.keys do
			local id = if k.block then "b" .. k.block elseif k.group == 0 then "z" .. k.stage else "p" .. k.group
			area[id] = (area[id] or 0) + k.sx * k.sz
		end
		for _, z in L.zones do
			near(area["z" .. z.stage], (z.x1 - z.x0) * (z.z1 - z.z0), "deck " .. z.stage .. " fully carpeted")
			local width = if z.stage == 0 then Layout.CORRIDOR.width else Layout.ROOM.width
			near(z.z1 - z.z0, width, "deck " .. z.stage .. " is full width")
		end
		for _, p in L.platforms do
			near(area["p" .. p.id], (p.x1 - p.x0) * (p.z1 - p.z0), "platform " .. p.id .. " fully carpeted")
		end
		for _, bl in L.blocks do
			near(area["b" .. bl.id], (bl.x1 - bl.x0) * (bl.z1 - bl.z0), "block " .. bl.id .. " fully carpeted")
		end
		local B = Layout.BASE
		local static = { run = true, key = true, sill = true, ["end"] = true }
		local pillars = 0
		for i, base in L.bases do
			local top = base.y + base.sy / 2
			local owner
			if base.block then
				pillars += 1
				owner = L.blocks[base.block]
				near(base.y - base.sy / 2, roomOf(owner.stage).floorY, "block pillar stands on the hazard floor " .. i)
			else
				owner = if base.group == 0 then L.zones[base.stage + 1] else L.platforms[base.group]
				check(base.group == 0 or static[owner.kind], "no base under blinking / sliding keys " .. i)
				near(base.sy, B.depth, "slab depth " .. i)
			end
			near(top, owner.top - Layout.KEY.height - B.drop, "base top sits under the key bottoms " .. i)
			near(base.sx, owner.x1 - owner.x0, "base spans its carpet (x) " .. i)
			near(base.sz, owner.z1 - owner.z0, "base spans its carpet (z) " .. i)
		end
		eq(pillars, #L.blocks, "one pillar per block")
		local nStatic = 0
		for _, p in L.platforms do
			if static[p.kind] then
				nStatic += 1
			end
		end
		eq(#L.bases, #L.zones + nStatic + #L.blocks, "one base per static surface")
	end)

	test("Cardio: themed rooms tile the course", function()
		local R = Layout.ROOM
		eq(L.rooms[1].kind, "lobby", "lobby first")
		near(L.rooms[1].x0, O.x, "lobby room at the origin")
		eq(#L.rooms, 2 * Rules.STAGE_COUNT + 1, "lobby + bridge room + safe zone per stage")
		for i, r in L.rooms do
			eq(r.id, i, "room ids")
			if i > 1 then
				near(r.x0, L.rooms[i - 1].x1, "room " .. i .. " continues the last")
			end
			check(Layout.THEMES[r.theme] ~= nil, "room " .. i .. " has a theme")
			eq(r.theme, Layout.STAGE_THEMES[r.stage], "room theme follows its stage " .. i)
			near(r.killY, r.floorY + Layout.KILL_ABOVE, "killY just above the hazard " .. i)
			check(r.killY <= Layout.KILL_Y + eps, "global KILL_Y covers room " .. i)
			check(r.floorY <= O.y - 8, "hazard floor far below the bridge " .. i)
			near((r.z0 + r.z1) / 2, O.z, "room centred " .. i)
			eq(Layout.killYAt((r.x0 + r.x1) / 2), r.killY, "killYAt " .. i)
			if r.kind == "bridge" then
				near(r.z1 - r.z0, R.width, "bridge room width " .. i)
				check(r.wallTop - O.y >= 40, "tall bridge room " .. i)
				eq(L.rooms[i - 1].stage, r.stage - 1, "bridge room after the previous zone " .. i)
				eq(L.rooms[i + 1].kind, "zone", "bridge room before its zone " .. i)
				eq(Layout.room(r.stage).x0, r.x0, "Layout.room " .. r.stage)
			else
				local z = L.zones[r.stage + 1]
				near(r.x0, z.x0, "zone room = deck (x0) " .. i)
				near(r.x1, z.x1, "zone room = deck (x1) " .. i)
			end
		end
		local seen = {}
		for n = 0, Rules.STAGE_COUNT do
			local th = Layout.themeOf(n)
			eq(#th.keys, 3, "three key tints " .. n)
			check(#th.props >= 5, "prop list " .. n)
			check(({ Neon = true, Glass = true, SmoothPlastic = true, Foil = true })[th.hazard.material], "hazard material " .. n)
			eq(type(th.hazard.liquid), "boolean", "liquid flag " .. n)
			if n > 0 then
				check(not seen[th.id], "each stage has its own theme " .. n)
				seen[th.id] = true
			end
		end
	end)

	test("Cardio: walls enclose every room and never touch keys", function()
		local H = Layout.KEY.height
		local cover: { [string]: number } = {}
		local ends = 0
		for i, w in L.walls do
			local room = L.rooms[w.room]
			if w.part ~= "under" then
				near(w.y + w.sy / 2, room.wallTop, "wall " .. i .. " reaches its room's top")
			end
			if w.part ~= "lintel" then
				check(w.y - w.sy / 2 < room.floorY, "wall " .. i .. " reaches below the hazard")
			end
			check(w.y + w.sy / 2 >= O.y + Rules.MAX_STEP_UP + Rules.JUMP_HEIGHT + 10 or w.part == "under", "wall " .. i .. " tall")
			if w.side == "north" or w.side == "south" then
				local key = w.room .. w.side
				cover[key] = (cover[key] or 0) + w.sx
				local inner = if w.side == "north" then w.z - w.sz / 2 else w.z + w.sz / 2
				near(inner, if w.side == "north" then room.z1 else room.z0, "side wall " .. i .. " on the room's face")
			else
				ends += 1
			end
		end
		for _, r in L.rooms do
			for _, side in { "north", "south" } do
				near(cover[r.id .. side] or 0, r.x1 - r.x0, "room " .. r.id .. " " .. side .. " wall spans the room")
			end
		end
		eq(ends, 2 + 4 * 2 * Rules.STAGE_COUNT, "two caps + four pieces per doorway")
		-- No wall box intersects a key (3D, with its sweep) or a base.
		local boxes: { any } = {}
		for _, k in L.keys do
			local x0, x1, z0, z1 = keyBox(k)
			table.insert(boxes, { x0 = x0, x1 = x1, z0 = z0, z1 = z1, y0 = k.y - H, y1 = k.y, wall = false })
		end
		for _, b in L.bases do
			table.insert(boxes, {
				x0 = b.x - b.sx / 2,
				x1 = b.x + b.sx / 2,
				z0 = b.z - b.sz / 2,
				z1 = b.z + b.sz / 2,
				y0 = b.y - b.sy / 2,
				y1 = b.y + b.sy / 2,
				wall = false,
			})
		end
		for _, w in L.walls do
			table.insert(boxes, {
				x0 = w.x - w.sx / 2,
				x1 = w.x + w.sx / 2,
				z0 = w.z - w.sz / 2,
				z1 = w.z + w.sz / 2,
				y0 = w.y - w.sy / 2,
				y1 = w.y + w.sy / 2,
				wall = true,
			})
		end
		local hits = 0
		pairsNear(boxes, function(b)
			return b.x0, b.x1, b.z0, b.z1
		end, function(a, c)
			if
				a.wall ~= c.wall
				and a.x0 < c.x1 - eps
				and c.x0 < a.x1 - eps
				and a.z0 < c.z1 - eps
				and c.z0 < a.z1 - eps
				and a.y0 < c.y1 - eps
				and c.y0 < a.y1 - eps
			then
				hits += 1
			end
		end)
		eq(hits, 0, "walls touching keys or bases")
		local b = L.bounds
		for i, w in L.walls do
			check(w.x - w.sx / 2 >= b.x0 and w.x + w.sx / 2 <= b.x1, "wall " .. i .. " inside bounds (x)")
			check(w.z - w.sz / 2 >= b.z0 and w.z + w.sz / 2 <= b.z1, "wall " .. i .. " inside bounds (z)")
		end
	end)

	test("Cardio: walking the course from the lobby to the finish", function()
		local specials = { blink = true, mover = true }
		for n = 1, Rules.STAGE_COUNT do
			local s = Rules.STAGES[n]
			local prevZone, zone = L.zones[n], L.zones[n + 1]
			eq(zone.stage, n, "zone order")
			eq(zone.top, O.y, "safe zones at deck height")
			local plats = stagePlats(n)
			local order = { "sill", "run", "run", "run" }
			for k, kind in order do
				eq(plats[k].kind, kind, "stage " .. n .. " opens with " .. kind)
			end
			eq(plats[#plats].kind, "sill", "stage " .. n .. " ends in its doorway")
			eq(plats[#plats - 1].kind, "end", "stage " .. n .. " end platform")
			eq(#plats, 4 + s.jumps - 1 + 2, "surface count of stage " .. n)
			local runLen = 0
			for k = 2, 4 do
				runLen += plats[k].x1 - plats[k].x0
			end
			check(runLen >= Layout.RUNUP_MIN, "long run-up at " .. n)
			near(plats[3].x1 - plats[3].x0, s.width, "the jog leg is one bridge width long " .. n)
			check(plats[3].z1 - plats[3].z0 >= s.width - eps, "the jog leg spans both runs " .. n)
			for k = 5, #plats - 2 do
				near(plats[k].z1 - plats[k].z0, s.width, "bridge width at " .. n .. "." .. (k - 4))
			end
			near(plats[2].z1 - plats[2].z0, s.width, "run-up width " .. n)
			check(s.width >= 4 * K - eps and s.width <= 9 * K + eps, "bridges are 4-9 keys wide " .. n)
			if n > 1 then
				check(s.width <= Rules.STAGES[n - 1].width, "bridges narrow with the stages " .. n)
			end
			local path: { any } = { prevZone }
			for _, p in plats do
				table.insert(path, p)
			end
			table.insert(path, zone)
			local jumps = Rules.jumps(n)
			local jumpIdx = 0
			for k = 1, #path - 1 do
				local a, c = path[k], path[k + 1]
				local gap, rise = c.x0 - a.x1, c.top - a.top
				local overlap = math.min(a.z1, c.z1) - math.max(a.z0, c.z0)
				check(overlap >= 2 * K - 1e-9, "lanes line up at " .. n .. "." .. k)
				check(gap >= -eps, "surfaces never overlap along X at " .. n .. "." .. k)
				if gap < eps then
					eq(rise, 0, "flush walk at " .. n .. "." .. k)
				else
					jumpIdx += 1
					local j = jumps[jumpIdx]
					near(gap, j.gap, "gap " .. n .. "." .. jumpIdx)
					near(rise, j.rise, "rise " .. n .. "." .. jumpIdx)
					check(rise <= Rules.MAX_STEP_UP, "step-up <= 5 at " .. n .. "." .. jumpIdx)
					check(gap <= Rules.maxGap(s.walk, rise) + 1e-9, "clearable at " .. n .. "." .. jumpIdx)
				end
				if specials[c.kind] then
					check(not specials[a.kind], "solid before special " .. n .. "." .. k)
				end
				if specials[a.kind] then
					check(not specials[c.kind], "solid after special " .. n .. "." .. k)
				end
			end
			eq(jumpIdx, #jumps, "every jump of stage " .. n .. " on the bridge")
			check(Layout.stageAt(zone.x0 + 1) == n, "stageAt in zone " .. n)
			check(Layout.stageAt(plats[2].x0 + 1) == n, "stageAt on the run-up " .. n)
			-- The bridge (and every sweep) keeps clear of the side walls.
			local room = roomOf(n)
			for _, f in footprint(n) do
				check(f.z0 >= room.z0 + 6 and f.z1 <= room.z1 - 6, "path clear of the side walls at " .. n)
				check(f.x0 >= room.x0 - eps and f.x1 <= room.x1 + eps, "path inside its room at " .. n)
			end
		end
		eq(Layout.stageAt(O.x + 1), 0, "stageAt in the lobby")
	end)

	test("Cardio: doorways and timed doors are fair", function()
		eq(#L.doors, 2 * Rules.STAGE_COUNT, "two doorways per bridge room")
		for _, p in L.platforms do
			if p.kind == "sill" then
				local d = L.doors[p.door]
				near(p.x0, d.x - Layout.DOOR_WALL / 2, "sill fills its doorway (x0)")
				near(p.x1, d.x + Layout.DOOR_WALL / 2, "sill fills its doorway (x1)")
				near(p.z0, d.z - d.width / 2, "sill spans the doorway (z0)")
				near(p.z1, d.z + d.width / 2, "sill spans the doorway (z1)")
				eq(d.y, p.top, "doorway floor = sill top")
				check(d.height >= 10, "doorway head room")
				eq(d.stage, p.stage, "door stage")
			end
		end
		for i, d in L.doors do
			local room = roomOf(d.stage)
			near(
				d.x,
				if d.side == "west" then room.x0 + Layout.DOOR_WALL / 2 else room.x1 - Layout.DOOR_WALL / 2,
				"door in its end wall " .. i
			)
			local zone = L.zones[if d.side == "west" then d.stage else d.stage + 1]
			check(d.z - d.width / 2 >= zone.z0 - eps and d.z + d.width / 2 <= zone.z1 + eps, "doorway opens onto the deck " .. i)
			-- Wide doorways (no pinch between rooms), all inside the safe zones' free lane.
			near(d.width, Layout.DOOR.keys * K, "doorway width " .. i)
			check(d.width >= 9 * K - eps, "doorway at least 9 keys wide " .. i)
			check(d.width >= Rules.STAGES[d.stage].width - eps, "doorway as wide as its bridge " .. i)
			check(math.abs(d.z - O.z) <= Layout.DOOR_REACH + eps, "doorway within DOOR_REACH " .. i)
			check(math.abs(d.z - O.z) + d.width / 2 <= Layout.LANE / 2 + eps, "doorway inside the lane " .. i)
			eq(d.timed, d.side == "east" and d.stage >= 3, "timed exit doors from stage 3 " .. i)
			if d.timed then
				check(d.open >= 2.5 and d.period <= 6, "door open >= 2.5 s of <= 6 s " .. i)
				check(d.phase >= 0 and d.phase <= d.period, "door phase " .. i)
				check(Layout.doorOpen(d, -d.phase + 0.1), "open at the cycle start " .. i)
				check(not Layout.doorOpen(d, -d.phase + d.open + 0.05), "closed after open " .. i)
			else
				for t = 0, 10, 0.37 do
					check(Layout.doorOpen(d, t), "untimed door always open " .. i)
				end
			end
		end
	end)

	test("Cardio: props, blocks and trusses stay clear of the path", function()
		local valid = {}
		for _, name in
			{
				"CandyStrawberry",
				"CandyDonut",
				"CandyCupcake",
				"CandyCookie",
				"CandySwirl",
				"CandyCone",
				"CandyBar",
				"CandyCane",
				"CandyLollipop",
				"CandyGummyBear",
				"CandyMacaron",
				"CandyTruffle",
				"CandyCottonCloud",
				"CandyIceCube",
			}
		do
			valid[name] = true
		end
		for _, th in Layout.THEMES do
			for _, name in th.props do
				check(valid[name], "theme prop " .. name)
			end
		end
		local count: { [number]: number } = {}
		for i, p in L.props do
			count[p.stage] = (count[p.stage] or 0) + 1
			local room = roomOf(p.stage)
			check(valid[p.kind], "prop kind " .. i)
			check(table.find(Layout.themeOf(p.stage).props, p.kind) ~= nil, "prop fits its theme " .. i)
			local r = p.scale / 2
			local box = { x0 = p.x - r, x1 = p.x + r, z0 = p.z - r, z1 = p.z + r }
			check(
				box.x0 >= room.x0 + Layout.DOOR_WALL - eps and box.x1 <= room.x1 - Layout.DOOR_WALL + eps,
				"prop inside its room (x) " .. i
			)
			if p.wall then
				check(p.z == room.z0 or p.z == room.z1, "wall prop on a side wall " .. i)
				check(p.normal ~= nil and p.normal.z == (if p.z == room.z0 then 1 else -1), "wall prop faces the room " .. i)
				check(p.y - r >= O.y and p.y + r <= room.wallTop, "wall prop on the wall " .. i)
			else
				check(box.z0 >= room.z0 - eps and box.z1 <= room.z1 + eps, "floor prop inside its room (z) " .. i)
				check(p.y <= room.floorY + eps and p.y > room.floorY - p.scale, "floor prop on the hazard " .. i)
				eq(p.float, Layout.themeOf(p.stage).hazard.liquid, "floats in liquids " .. i)
			end
			local need = if p.wall then 1 else Layout.PROP_CLEAR
			for _, f in footprint(p.stage) do
				check(dist(box, f) >= need - eps, "prop " .. i .. " clear of the path and its jumps")
			end
			for _, bl in L.blocks do
				if bl.stage == p.stage and not p.wall then
					check(dist(box, bl) >= 2 - eps, "prop " .. i .. " clear of the blocks")
				end
			end
		end
		for n = 1, Rules.STAGE_COUNT do
			check((count[n] or 0) >= 35 and count[n] <= 60, "35-60 props in room " .. n .. " (" .. tostring(count[n]) .. ")")
		end
		for i, bl in L.blocks do
			for _, f in footprint(bl.stage) do
				check(dist(bl, f) >= Layout.PROP_CLEAR - eps, "block " .. i .. " clear of the path")
			end
			check(bl.top - O.y >= 0 and bl.top - O.y <= Rules.MAX_STEP_UP, "block " .. i .. " raised to bridge height")
		end
		-- Trusses: on the room's inner faces, out of every run and jump (head room included).
		local perRoom: { [number]: number } = {}
		for i, beam in L.trusses do
			perRoom[beam.stage] = (perRoom[beam.stage] or 0) + 1
			local room = roomOf(beam.stage)
			local foot = footprint(beam.stage)
			local len = math.sqrt((beam.b.x - beam.a.x) ^ 2 + (beam.b.y - beam.a.y) ^ 2 + (beam.b.z - beam.a.z) ^ 2)
			check(len > 1, "beam " .. i .. " has length")
			local steps = math.ceil(len)
			local clear = true
			for st = 0, steps do
				local u = st / steps
				local x = beam.a.x + (beam.b.x - beam.a.x) * u
				local y = beam.a.y + (beam.b.y - beam.a.y) * u
				local z = beam.a.z + (beam.b.z - beam.a.z) * u
				check(x >= room.x0 and x <= room.x1 and z >= room.z0 and z <= room.z1, "beam " .. i .. " inside its room")
				check(y >= room.floorY - eps and y <= room.wallTop + eps, "beam " .. i .. " between floor and top")
				local pt = { x0 = x, x1 = x, z0 = z, z1 = z }
				for _, f in foot do
					if dist(pt, f) < beam.thick / 2 + 1 and y > f.top - 4 and y < f.top + 14 then
						clear = false
					end
				end
			end
			check(clear, "beam " .. i .. " clear of the path")
		end
		for n = 1, Rules.STAGE_COUNT do
			check((perRoom[n] or 0) >= 40, "X frames in room " .. n)
		end
	end)

	test("Cardio: zones, treadmills, pads and signs", function()
		local b = L.bounds
		local function inside(x: number, z: number, what: string)
			check(x >= b.x0 and x <= b.x1 and z >= b.z0 and z <= b.z1, what .. " inside bounds")
		end
		local T = Layout.TREADMILL
		local function tmBox(tm: any): any
			return { x0 = tm.x - T.length / 2, x1 = tm.x + T.length / 2, z0 = tm.z - T.width / 2, z1 = tm.z + T.width / 2 }
		end
		for _, z in L.zones do
			check(#z.treadmills >= 2, "treadmills in zone " .. z.stage)
			for i, tm in z.treadmills do
				local box = tmBox(tm)
				check(box.x0 >= z.x0 + 4 and box.x1 <= z.x1 - 4, "treadmill on its deck (x)")
				check(box.z0 >= z.z0 + 4 and box.z1 <= z.z1 - 4, "treadmill on its deck (z)")
				check(math.abs(tm.z - O.z) >= 8 + T.width / 2, "treadmills leave the running lane free")
				for j = i + 1, #z.treadmills do
					check(dist(box, tmBox(z.treadmills[j])) >= 1 - eps, "treadmills apart in zone " .. z.stage)
				end
				check(dist(box, { x0 = z.spawn.x, x1 = z.spawn.x, z0 = z.spawn.z, z1 = z.spawn.z }) >= 8, "spawn clear of the treadmills")
			end
			check(z.spawn.x > z.x0 and z.spawn.x < z.x1, "spawn on its deck")
			check(z.spawn.z > z.z0 and z.spawn.z < z.z1, "spawn on its deck (z)")
			check(Layout.isOverKey(z.spawn.x, z.top, z.spawn.z) ~= nil, "spawn on a key " .. z.stage)
			near(z.spawn.z, O.z, "spawn on the centre line " .. z.stage)
		end
		eq(L.zones[1].winPad, nil, "no WIN pad in the lobby")
		check(L.zones[1].upgradePad ~= nil and #L.zones[1].treadmills >= 2, "lobby has treadmills and the upgrade pad")

		-- Safe zones: about twice the old 11 x 29 key deck, as wide as the bridge rooms.
		local old = 11 * K * 29 * K
		for n = 1, Rules.STAGE_COUNT do
			local z = L.zones[n + 1]
			local size = if n == Rules.STAGE_COUNT then Layout.FINISH_KEYS else Layout.ZONE_KEYS
			near(z.x1 - z.x0, size.long * K, "zone " .. n .. " length")
			near(z.z1 - z.z0, size.wide * K, "zone " .. n .. " width")
			near(z.z1 - z.z0, Layout.ROOM.width, "zone " .. n .. " as wide as the bridge rooms")
			check(z.x1 - z.x0 >= 16 * K - eps, "zone " .. n .. " at least 16 keys long")
			check((z.x1 - z.x0) * (z.z1 - z.z0) >= 2 * old, "zone " .. n .. " has twice the old area")
			-- The lane between its two doorways runs the whole zone, clear of pad and treadmills.
			for _, tm in z.treadmills do
				check(tm.z + T.width / 2 <= O.z - Layout.LANE / 2 - 4, "treadmill south of the lane in zone " .. n)
			end
			check(#z.treadmills == 4, "four treadmills in zone " .. n)
		end

		-- WIN pads: one per safe zone, a whole-key square with clear deck around it.
		eq(Layout.WIN_PAD, 5 * K, "WIN pad is 5 keys square")
		for n = 1, Rules.STAGE_COUNT do
			local z = L.zones[n + 1]
			local pad = z.winPad
			check(pad ~= nil, "WIN pad in zone " .. n)
			eq(pad.size, Layout.WIN_PAD, "WIN pad size " .. n)
			local half = pad.size / 2
			local box = { x0 = pad.x - half, x1 = pad.x + half, z0 = pad.z - half, z1 = pad.z + half }
			inside(pad.x, pad.z, "WIN pad")
			check(box.x0 >= z.x0 + 2 * K - eps and box.x1 <= z.x1 - 2 * K + eps, "WIN pad clear of the end walls " .. n)
			check(box.z0 >= z.z0 + 2 * K - eps and box.z1 <= z.z1 - 2 * K + eps, "WIN pad clear of the side walls " .. n)
			local function onGrid(v: number): boolean
				return math.abs(v / K - math.floor(v / K + 0.5)) < 1e-6
			end
			check(onGrid(box.x0 - z.x0) and onGrid(box.z0 - z.z0), "WIN pad covers whole keys " .. n)
			for _, tm in z.treadmills do
				check(dist(box, tmBox(tm)) >= 20, "WIN pad far from the treadmills " .. n)
			end
			check(dist(box, { x0 = z.spawn.x, x1 = z.spawn.x, z0 = z.spawn.z, z1 = z.spawn.z }) >= 10, "spawn clear of the WIN pad " .. n)
			if n < Rules.STAGE_COUNT then
				-- Walking from door to door never crosses the pad: it sits outside the lane.
				check(box.z0 >= O.z + Layout.LANE / 2 + 2 * K - eps, "WIN pad north of the lane " .. n)
				for _, d in L.doors do
					if (d.side == "east" and d.stage == n) or (d.side == "west" and d.stage == n + 1) then
						check(box.z0 - (d.z + d.width / 2) >= 2 * K - eps, "WIN pad beside the doorways of zone " .. n)
					end
				end
			else
				-- The last pad is the finish: on the centre line, in front of the podium.
				near(pad.z, O.z, "final WIN pad on the centre line")
				check(box.x1 < L.finish.x - 7, "final WIN pad in front of the podium")
			end
			-- Standing on it (feet on the pressed keys or on the pad), not flying over it.
			eq(Layout.onWinPad(pad.x, z.top, pad.z), n, "onWinPad centre " .. n)
			eq(Layout.onWinPad(box.x0 + 0.1, z.top - Layout.PRESS, box.z1 - 0.1), n, "onWinPad corner " .. n)
			eq(Layout.onWinPad(box.x0 - 0.5, z.top, pad.z), nil, "off the pad (x) " .. n)
			eq(Layout.onWinPad(pad.x, z.top, box.z1 + 0.5), nil, "off the pad (z) " .. n)
			eq(Layout.onWinPad(pad.x, z.top + Layout.WIN_PAD_ABOVE + 1, pad.z), nil, "jumping over the pad " .. n)
			eq(Layout.onWinPad(z.spawn.x, z.top, z.spawn.z), nil, "the spawn is not on the pad " .. n)
		end
		eq(Layout.onWinPad(L.zones[1].spawn.x, O.y, L.zones[1].spawn.z), nil, "no WIN pad in the lobby")

		-- Rooms never overlap: they tile X in order, and no bridge surface reaches into a deck.
		for i = 2, #L.rooms do
			check(L.rooms[i].x0 >= L.rooms[i - 1].x1 - eps, "room " .. i .. " starts after room " .. (i - 1))
			check(L.rooms[i].x1 > L.rooms[i].x0, "room " .. i .. " has length")
		end
		for _, p in L.platforms do
			check(p.x0 >= L.zones[p.stage].x1 - eps and p.x1 <= L.zones[p.stage + 1].x0 + eps, "platform " .. p.id .. " between its zones")
		end
		for _, s in L.signs do
			inside(s.x, s.z, "sign")
			eq(s.need, Rules.STAGES[s.stage].need, "sign shows the need")
			local room = roomOf(s.stage)
			local door = L.doors[stagePlats(s.stage)[1].door]
			check(s.x > room.x0 and s.x < room.x0 + 8, "sign at the start of stage " .. s.stage .. "'s room")
			near(s.z, door.z, "sign over the entrance " .. s.stage)
			check(s.archSpan > door.width and s.archHeight > door.height, "frame around the doorway " .. s.stage)
			check(s.y - O.y >= Rules.JUMP_HEIGHT + 10, "banner hangs above the jumps")
		end
		inside(L.finish.x, L.finish.z, "finish")
	end)

	test("Cardio: blinking and sliding keys stay fair", function()
		local blinks, movers, special = 0, 0, {}
		for _, p in L.platforms do
			local s = Rules.STAGES[p.stage]
			if p.kind == "blink" then
				blinks += 1
				special[p.stage] = true
				check(p.stage >= 4, "no blinking before stage 4")
				local cross = (Rules.airtime(0) :: number) + (p.x1 - p.x0) / s.walk + 0.6
				check(p.blinkOn >= cross, "blink on-time is followable at stage " .. p.stage)
				check(p.blinkPeriod - p.blinkOn <= 1.2, "blink off-time is short at stage " .. p.stage)
				check(p.phase >= 0 and p.phase <= p.blinkPeriod, "blink phase range")
			elseif p.kind == "mover" then
				movers += 1
				special[p.stage] = true
				check(p.stage >= 6, "no sliding before stage 6")
				check(p.period <= 6 and p.travel <= 12, "slides are short and quick at stage " .. p.stage)
				local before = L.platforms[p.id - 1]
				near((p.z0 + p.z1) / 2, (before.z0 + before.z1) / 2, "mover rests in line with the platform before")
			end
		end
		for n = 4, Rules.STAGE_COUNT do
			check(special[n], "stage " .. n .. " has a blinking or sliding section")
		end
		check(blinks >= 4, "blinking sections exist")
		check(movers >= 3, "sliding sections exist")
		for _, k in L.keys do
			if k.group > 0 then
				local p = L.platforms[k.group]
				check(k.phase == p.phase and k.travel == p.travel and k.blinkOn == p.blinkOn, "section keys move together")
			end
		end
		local blinkKey, moverKey
		for _, k in L.keys do
			if k.kind == "blink" and not blinkKey then
				blinkKey = k
			elseif k.kind == "mover" and not moverKey then
				moverKey = k
			end
		end
		check(Layout.keyState(blinkKey, -blinkKey.phase), "blink on at the cycle start")
		check(not Layout.keyState(blinkKey, -blinkKey.phase + blinkKey.blinkOn + 0.05), "blink off after blinkOn")
		local t = -moverKey.phase + moverKey.period / 4
		local _, dz = Layout.keyState(moverKey, t)
		near(dz, moverKey.travel, "mover at full travel a quarter period in")
		local found = Layout.isOverKey(moverKey.x, moverKey.y, moverKey.z + dz, t)
		check(found ~= nil and found.group == moverKey.group, "isOverKey follows a slid key")
	end)

	test("Cardio: keyboard letters (no spacebars) and themed tints", function()
		local rows = { "QWERTYUIOP", "ASDFGHJKL", "ZXCVBNM" }
		local byPos: { [string]: any } = {}
		for _, k in L.keys do
			byPos[k.x .. ":" .. k.z] = k
		end
		local inRow, pairsSeen, sameTint, tintPairs = 0, 0, 0, 0
		for _, k in L.keys do
			local nb = byPos[k.x .. ":" .. (k.z + K)]
			if nb and nb.kind == k.kind and nb.group == k.group and nb.block == k.block then
				tintPairs += 1
				if nb.tint == k.tint then
					sameTint += 1
				end
				pairsSeen += 1
				for _, row in rows do
					local i = string.find(row, k.letter, 1, true)
					if i and string.sub(row, i % #row + 1, i % #row + 1) == nb.letter then
						inRow += 1
						break
					end
				end
			end
		end
		eq(inRow, pairsSeen, "letters run along keyboard rows")
		check(tintPairs > 1000, "neighbour pairs sampled")
		local ratio = sameTint / tintPairs
		check(ratio > 0.03 and ratio < 0.35, "tints mixed but not uniform (" .. ratio .. ")")
		for _, k in L.keys do
			check(k.tint == 1 or k.tint == 2 or k.tint == 3, "tint 1..3")
			check(k.kind ~= "space" and k.letter ~= "SPACE", "no spacebars")
		end
		eq(Layout.CORRIDOR.lanes * Layout.KEY.size, Layout.CORRIDOR.width, "corridor is whole keys wide")
		eq(#Layout.PALETTES, Rules.STAGE_COUNT + 1, "one palette per stage + lobby")
		for i, palette in Layout.PALETTES do
			eq(palette, Layout.themeOf(i - 1).keys, "palette from the theme " .. i)
			for _, c in palette do
				for _, v in { c.r, c.g, c.b } do
					check(v == math.floor(v) and v >= 0 and v <= 255, "0..255 integers in palette " .. i)
				end
			end
		end
		local k = L.keys[1]
		eq(Layout.tintOf(k), Layout.PALETTES[k.stage + 1][k.tint], "tintOf")
	end)

	test("Cardio: helpers", function()
		local lobby = L.zones[1]
		local cp = Layout.spawn(0)
		check(cp ~= nil and cp.x == lobby.spawn.x, "lobby spawn")
		local here = Layout.zoneAt(cp.x, cp.z, O.y)
		check(here ~= nil and here.stage == 0, "zoneAt lobby")
		check(Layout.zoneAt(cp.x, cp.z, O.y + 40) == nil, "zoneAt ignores high flyers")
		check(Layout.isOverKey(cp.x, O.y, cp.z) ~= nil, "standing on a lobby key")
		check(Layout.isOverKey(cp.x, O.y, O.z + 500) == nil, "no key out at sea")
		for i = 1, #L.keys, 37 do
			local k = L.keys[i]
			if k.kind ~= "blink" and k.kind ~= "mover" then
				local f = Layout.isOverKey(k.x + 0.3, k.y, k.z - 0.3)
				check(f ~= nil and f.x == k.x and f.z == k.z, "isOverKey finds key " .. i)
			end
		end
		local tm = lobby.treadmills[1]
		local zs, idx = Layout.onTreadmill(tm.x, tm.y, tm.z)
		eq(zs, 0, "onTreadmill zone")
		eq(idx, 1, "onTreadmill index")
		check(Layout.onTreadmill(cp.x, O.y, O.z) == nil, "not on a treadmill in the lane")
		local z5 = L.zones[6]
		local tm5 = z5.treadmills[2]
		eq((Layout.onTreadmill(tm5.x, tm5.y, tm5.z)), 5, "deeper treadmill zone")
		-- No checkpoints: a fall anywhere returns you to the lobby's spawn (Modes.Cardio);
		-- startStageAt is the last safe zone passed (the HUD runs stage + 1).
		check((L :: any).checkpoints == nil and (Layout :: any).checkpointAt == nil, "no checkpoints")
		for _, s in Rules.STAGES do
			check((s :: any).checkpointEvery == nil, "no checkpointEvery")
		end
		check((Layout.zoneAt(cp.x, cp.z, cp.y - 3) or {}).stage == 0, "the lobby spawn is on the lobby deck")
		for _, p in L.platforms do
			eq(Layout.startStageAt((p.x0 + p.x1) / 2), p.stage - 1, "platform " .. p.id .. " runs stage " .. p.stage)
			check(cp.x < p.x0, "the lobby spawn is behind stage " .. p.stage)
		end
		for _, z in L.zones do
			eq(Layout.startStageAt(z.spawn.x), z.stage, "zone " .. z.stage .. " is the last zone passed on its deck")
			local sp = Layout.spawn(z.stage)
			check(sp ~= nil and sp.x == z.spawn.x, "spawn of zone " .. z.stage)
		end
		check(L.finish.x > L.zones[#L.zones].x0, "finish on the last deck")
		eq(Layout.killYAt(-5000), Layout.KILL_Y, "killYAt outside the rooms")
		local r3 = Layout.room(3)
		check(r3 ~= nil and Layout.roomAt((r3.x0 + r3.x1) / 2) == r3 and r3.stage == 3, "roomAt")
		eq(Layout.stageAt(r3.x0 + 1), 3, "stageAt in bridge room 3")
	end)

	-- Loads Modes.Cardio against stub GameModes / Tycoon for a living player whose record is
	-- `bestStage` (real Economy rewards; rig.humanoid.Health = 0 kills them). Returns the mode
	-- def and a rig.
	local function loadCardio(bestStage: number): (any, any)
		local env = function(parent: { [string]: any })
			return setmetatable({
				script = { Parent = parent },
				require = function(module)
					return module
				end,
			}, { __index = _G })
		end
		local Chase = luau.load(fs.readFile(MODES_DIR .. "CardioChase.luau"), {
			debugName = "CardioChase",
			environment = env({ CardioRules = Rules, CardioLayout = Layout }),
		})()
		local Course = luau.load(fs.readFile(MODES_DIR .. "Course.luau"), { debugName = "Course" })()
		local clock = { t = 1000 }
		local rig: any = { notes = {}, teleports = 0, clock = clock }
		local attributes = {}
		local humanoid = {
			Health = 100,
			WalkSpeed = 16,
			SetAttribute = function(_, name, value)
				attributes[name] = value
			end,
			GetAttribute = function(_, name)
				return attributes[name]
			end,
		}
		local player = {
			Character = {
				FindFirstChildOfClass = function()
					return humanoid
				end,
			},
		}
		local root = { Position = roblox.Vector3.new(0, 0, 0) }
		local session = {
			player = player,
			profile = {
				money = 0,
				totalEarned = 0,
				discovered = {},
				processLevel = 0,
				cardio = { speed = 0, bestStage = bestStage, treadmill = 0, clears = 0, speedCap = 0 },
				modes = { cardio = { best = bestStage, clears = 0, lastRewardAt = 0 } },
			},
		}
		rig.humanoid = humanoid
		rig.player, rig.root, rig.session = player, root, session
		local GameModes = {
			session = function()
				return session
			end,
			notify = function(_, event, _, data)
				local note = table.clone(data or {})
				note.event = event
				table.insert(rig.notes, note)
			end,
			effect = function() end,
			refresh = function() end,
			teleport = function(_, feet)
				rig.teleports += 1
				rig.teleportedTo = feet
			end,
			hooks = {
				reward = function(_, _, reward)
					return reward
				end,
				rewarded = function() end,
			},
		}
		local Tycoon = {
			income = function()
				return 0
			end,
			markDirty = function() end,
			toast = function() end,
			addAction = function() end,
		}
		local services = {
			ReplicatedStorage = { Shared = { Economy = Economy } },
			Players = { PlayerRemoving = { Connect = function() end } },
		}
		local modes = { CardioLayout = Layout, CardioRules = Rules, CardioChase = Chase, Course = Course }
		local cardioEnv = env(modes)
		modes.Parent = { Cosmetics = { refresh = function() end } }
		cardioEnv.game = {
			GetService = function(_, name)
				return services[name]
			end,
		}
		cardioEnv.workspace = {
			GetServerTimeNow = function()
				return clock.t
			end,
		}
		cardioEnv.Vector3 = roblox.Vector3
		cardioEnv.Enum = roblox.Enum
		local path = MODES_DIR .. "Cardio.luau"
		local Cardio = luau.load(fs.readFile(path), { debugName = path, environment = cardioEnv })()
		local theme = { Modes = { Reward = { Seconds = 300, Min = 750 } }, Cosmetics = { BaseWalkSpeed = 16 } }
		local def = Cardio.create(GameModes, { built = nil, theme = theme, Tycoon = Tycoon })
		rig.chase = Chase
		function rig.last(event: string): any
			for i = #rig.notes, 1, -1 do
				if rig.notes[i].event == event then
					return rig.notes[i]
				end
			end
			return nil
		end
		function rig.count(event: string): number
			local n = 0
			for _, note in rig.notes do
				if note.event == event then
					n += 1
				end
			end
			return n
		end
		-- One server tick, a second later, with the feet at (x, y, z).
		function rig.feet(x: number, y: number, z: number)
			root.Position = roblox.Vector3.new(x, y + 3, z)
			clock.t += 1
			def.tick(player, root, clock.t)
		end
		-- Runs stages `from`..`to` in order: through each bridge room (its middle, past where a
		-- chase may start) onto the next safe zone's deck (its spawn).
		function rig.reach(from: number, to: number)
			for n = from, to do
				local room = Layout.room(n)
				rig.feet((room.x0 + room.x1) / 2, O.y, O.z)
				local sp = Layout.spawn(n)
				rig.feet(sp.x, O.y, sp.z)
			end
		end
		-- Steps on safe zone n's WIN plate.
		function rig.plate(n: number)
			local pad = L.zones[n + 1].winPad
			rig.feet(pad.x, O.y, pad.z)
		end
		-- Vector3 holds 32-bit floats: compare the teleport target loosely.
		function rig.inLobby(): boolean
			local at, sp = rig.teleportedTo, Layout.spawn(0)
			return at ~= nil and (at - roblox.Vector3.new(sp.x, sp.y, sp.z)).Magnitude < 0.01
		end
		return def, rig
	end

	test("Cardio: a run always starts at stage 1, whatever the client asks", function()
		local def, rig = loadCardio(5)
		local player = rig.player
		-- Vector3 holds 32-bit floats: compare the teleport target loosely.
		local function landedOn(spawn: { x: number, y: number, z: number }): boolean
			local at = rig.teleportedTo
			return at ~= nil and (at - roblox.Vector3.new(spawn.x, spawn.y, spawn.z)).Magnitude < 0.01
		end
		local lobby = Layout.spawn(0)
		-- `false` = no data at all (the gate), then the old "Start at" requests and junk.
		local asks: { any } = { false, {}, { stage = 0 }, { stage = 1 }, { stage = 5 }, { stage = 4.5 }, { stage = 9 } }
		table.insert(asks, { stage = -1 })
		table.insert(asks, { stage = 0 / 0 })
		table.insert(asks, { stage = math.huge })
		table.insert(asks, { stage = "5" })
		for i, ask in asks do
			rig.teleportedTo = nil
			table.clear(rig.notes)
			check(def.start(player, true, ask or nil), "request " .. i .. " starts a run")
			check(landedOn(lobby), "request " .. i .. " lands on the lobby spawn")
			eq(def.snapshot(player).stage, 0, "request " .. i .. " runs stage 1")
			check(rig.last("start") ~= nil and rig.last("start").stage == nil, "request " .. i .. ": a start notify with no stage")
		end
		eq(rig.session.profile.cardio.bestStage, 5, "bestStage stays as the record")
		eq(def.snapshot(player).bestStage, 5, "and stays in the snapshot")

		-- Starting again mid-run is a restart in the lobby with nothing reached.
		rig.reach(1, 2)
		eq(def.snapshot(player).reached, 2, "two safe zones reached")
		check(def.start(player, true, { stage = 2 }), "restart")
		eq(def.snapshot(player).stage, 0, "the restart is at stage 1")
		eq(def.snapshot(player).reached, 0, "the restart has reached nothing")
	end)

	test("Cardio: cash is paid only on a WIN plate, once per run", function()
		local def, rig = loadCardio(0)
		local player, profile = rig.player, rig.session.profile
		local rec = profile.cardio
		check(def.start(player, true), "start")
		eq(def.snapshot(player).reached, 0, "nothing reached at the start")

		-- Reaching a safe zone pays nothing and records nothing.
		rig.reach(1, 1)
		local zone = rig.last("zone")
		check(zone ~= nil and zone.stage == 1 and zone.first == true, "zone 1 reached")
		eq(profile.money, 0, "reaching zone 1 pays nothing")
		eq(rec.bestStage, 0, "reaching zone 1 is not a record yet")
		eq(rec.clears, 0, "no clear yet")
		eq(rig.count("win"), 0, "no win yet")
		check(rig.last("stage") == nil and rig.last("finish") == nil, "no automatic stage reward events")
		local snap = def.snapshot(player)
		eq(snap.reached, 1, "snapshot: zone 1 reached")
		check(zone.cash > 0 and snap.wins[1] == zone.cash, "the plate's pending win is announced")
		for n = 2, Rules.STAGE_COUNT do
			check(snap.wins[n] > snap.wins[n - 1], "deeper plates pay more at " .. n)
		end
		check(math.abs(snap.wins[10] / snap.wins[1] - Rules.stageBonus(10)) < 0.01, "plate 10 pays the stage 10 bonus")
		-- Standing still on the deck (off the plate) keeps paying nothing.
		rig.reach(1, 1)
		eq(rig.count("zone"), 1, "a zone is reached once per run")
		eq(profile.money, 0, "still nothing paid")

		-- Stepping on the plate pays that stage, records it and ends the run in the lobby.
		rig.teleportedTo = nil
		rig.plate(1)
		local win = rig.last("win")
		check(win ~= nil and win.stage == 1 and win.first == true and win.final == false, "win on plate 1")
		eq(win.cash, zone.cash, "the plate pays what it showed")
		eq(profile.money, zone.cash, "cash paid")
		eq(profile.totalEarned, zone.cash, "counted as earned")
		eq(rec.bestStage, 1, "bestStage recorded")
		eq(rec.clears, 1, "one clear")
		check(profile.modes.cardio.lastRewardAt > 0, "the reward cooldown starts")
		check(rig.inLobby(), "back in the lobby")
		check(def.running(player), "ready for the next run")
		eq(def.snapshot(player).reached, 0, "the next run has reached nothing")
		eq(def.snapshot(player).stage, 0, "the next run is at stage 1")

		-- The same plate again without running the stage (a late position report, a teleport).
		rig.plate(1)
		rig.plate(1)
		eq(rig.count("win"), 1, "one payout per run")
		eq(profile.money, zone.cash, "no second payout")

		-- Running stage 1 again right away, inside the cooldown: the run again bonus is not paid
		-- seconds after a paid plate, so the plate pays nothing (no farming).
		rig.reach(1, 1)
		local again = rig.last("zone")
		check(again.first == false and again.full == false and again.cash == 0, "plate 1 is cooling down")
		eq(again.pay, "resting", "and says the bonus rests")
		rig.plate(1)
		eq(rig.count("win"), 2, "the claim still ends the run")
		eq(rig.last("win").cash, 0, "no cash inside the cooldown")
		eq(rig.last("win").pay, "resting", "the win says the bonus rests")
		eq(profile.money, zone.cash, "nothing farmed")
		eq(rec.bestStage, 1, "the record stays")
		check(rig.inLobby(), "back in the lobby again")

		-- Walking past plate 1 keeps the run going; plate 2 is a first clear and pays more.
		rig.reach(1, 2)
		eq(profile.money, zone.cash, "walking past pays nothing")
		local z2 = rig.last("zone")
		check(z2.stage == 2 and z2.first == true and z2.cash > zone.cash, "plate 2 pays more")
		rig.plate(2)
		eq(rig.last("win").stage, 2, "win on plate 2")
		eq(profile.money, zone.cash + z2.cash, "plate 2 paid once")
		eq(rec.bestStage, 2, "bestStage 2")

		-- An earlier plate of this run can still be claimed (stage 1's reward, on the cooldown).
		rig.reach(1, 2)
		rig.plate(1)
		check(rig.last("win").stage == 1 and rig.last("win").cash == 0, "going back to plate 1 claims stage 1")
		eq(rig.last("win").repeatFrom, 2, "the run again bonus starts at the best plate")

		-- After the cooldown a repeat pays again, once.
		profile.modes.cardio.lastRewardAt = os.time() - Economy.MODE_REWARD_COOLDOWN - 1
		rig.reach(1, 1)
		local cooled = rig.last("zone")
		check(cooled.first == false and cooled.full == true and cooled.cash == zone.cash, "plate 1 pays again after the cooldown")
		rig.plate(1)
		eq(profile.money, 2 * zone.cash + z2.cash, "paid after the cooldown")
		rig.reach(1, 1)
		rig.plate(1)
		eq(profile.money, 2 * zone.cash + z2.cash, "and not twice")

		-- The last plate is the finish.
		rig.reach(1, Rules.STAGE_COUNT)
		rig.plate(Rules.STAGE_COUNT)
		local final = rig.last("win")
		check(final.stage == Rules.STAGE_COUNT and final.final == true and final.first == true, "plate 10 is the final win")
		eq(rec.bestStage, Rules.STAGE_COUNT, "all stages recorded")
		check(rig.inLobby(), "the finish also returns to the lobby")
	end)

	test("Cardio: the WIN plate is checked by the server", function()
		local def, rig = loadCardio(0)
		local player, profile = rig.player, rig.session.profile

		-- No run: nothing.
		rig.plate(1)
		eq(rig.count("win"), 0, "no run, no win")
		check(def.start(player, true), "start")

		-- A plate of a zone not reached this run (a teleport onto it or deeper) pays nothing.
		rig.plate(1)
		rig.plate(3)
		eq(def.snapshot(player).reached, 0, "a teleport onto a deck reaches nothing")
		rig.reach(1, 1)
		rig.plate(5)
		local sp3 = Layout.spawn(3)
		rig.feet(sp3.x, O.y, sp3.z)
		eq(def.snapshot(player).reached, 1, "zones are reached in order, through their bridge rooms")
		eq(rig.count("win"), 0, "no win on a plate that was not reached")
		eq(profile.money, 0, "nothing paid")

		-- Off the plate, over the plate, or dead on the plate: nothing.
		local z1 = L.zones[2]
		local pad = z1.winPad
		rig.feet(pad.x - pad.size / 2 - 1, O.y, pad.z)
		rig.feet(pad.x, O.y + Layout.WIN_PAD_ABOVE + 2, pad.z)
		rig.humanoid.Health = 0
		rig.plate(1)
		eq(rig.count("win"), 0, "beside, above or dead: no win")
		eq(profile.money, 0, "still nothing paid")

		-- Alive on the plate of the zone reached this run: paid.
		rig.humanoid.Health = 100
		rig.plate(1)
		eq(rig.count("win"), 1, "win")
		check(profile.money > 0, "paid")
	end)

	test("Cardio: a fall or a catch sends you back to stage 1", function()
		local def, rig = loadCardio(4)
		local player, profile = rig.player, rig.session.profile
		local rec = profile.cardio
		rec.treadmill = 3
		check(def.start(player, true), "start")
		rig.reach(1, 2)
		eq(def.snapshot(player).reached, 2, "two safe zones reached")
		local speed = rec.speed

		-- A fall in stage 3: the lobby, not safe zone 2.
		local r3 = Layout.room(3)
		local x = (r3.x0 + r3.x1) / 2
		rig.teleportedTo = nil
		rig.feet(x, Layout.killYAt(x) - 10, O.z)
		local fall = rig.last("fall")
		check(fall ~= nil and fall.stage == 0 and fall.from == 3 and fall.reason == "fall", "a fall in stage 3 goes back to stage 1")
		check(rig.inLobby(), "to the lobby spawn")
		check(def.running(player), "the run goes on from the lobby")
		local snap = def.snapshot(player)
		eq(snap.stage, 0, "running stage 1 again")
		eq(snap.reached, 0, "the run's progress is gone")
		-- What is permanent stays.
		check(rec.speed >= speed, "Speed kept")
		eq(rec.treadmill, 3, "treadmill level kept")
		eq(rec.bestStage, 4, "bestStage kept")
		eq(profile.money, 0, "a fall pays nothing")
		-- The plates reached before the fall no longer pay.
		rig.plate(2)
		eq(rig.count("win"), 0, "no win on an old zone's plate after a fall")

		-- Caught by the stage 3 chaser: the lobby too, and the chaser is ready again.
		local sec = rig.chase.section(3)
		local at = sec.x0 + rig.chase.TRIGGER + 1
		local _, lz = rig.chase.lineAt(sec.line, rig.chase.arcAt(sec.line, at))
		rig.reach(1, 2)
		rig.feet(at, O.y, lz)
		eq(rig.count("chase"), 1, "the chase starts")
		rig.teleportedTo = nil
		rig.clock.t += 20
		rig.feet(at, O.y, lz)
		eq(rig.count("caught"), 1, "caught standing still")
		fall = rig.last("fall")
		check(fall.stage == 0 and fall.from == 3 and fall.reason == "caught", "a catch goes back to stage 1")
		check(rig.inLobby(), "to the lobby spawn")
		eq(def.snapshot(player).reached, 0, "progress gone after a catch")
		eq(rec.bestStage, 4, "bestStage kept after a catch")
		rig.reach(1, 2)
		rig.feet(at, O.y, lz)
		eq(rig.count("chase"), 2, "the chaser hunts again on the next run")

		-- Escaping a chase is forgotten by a fall as well.
		rig.feet(sec.endX + 1, O.y, lz)
		eq(rig.last("chaseEnd").reason, "escaped", "escaped")
		rig.feet(x, Layout.killYAt(x) - 10, O.z)
		eq(rig.last("fall").reason, "fall", "then a fall")
		rig.reach(1, 2)
		rig.feet(at, O.y, lz)
		eq(rig.count("chase"), 3, "chased again after the fall")
	end)

	test("Cardio: stage 3 has room to spare and every stage a recommended Speed", function()
		local s3 = Rules.STAGES[3]
		-- Reach left over on the longest jump at exactly the need: well above SAFETY.
		local reserve = s3.walk * Rules.airtime(0) - s3.gap
		check(reserve >= 2.4, "stage 3 keeps 2.4 studs in reserve at its need (" .. reserve .. ")")
		check(reserve >= 3 * Rules.SAFETY, "three times the safety margin")
		for _, j in Rules.jumps(3) do
			check(s3.walk * Rules.airtime(j.rise) - j.gap >= reserve - 1e-9, "no stage 3 jump is tighter than its longest")
		end
		eq(Rules.RECOMMEND, 1.15, "recommended = 15% above the need")
		eq(Rules.recommended(1), 0, "stage 1 needs nothing")
		eq(Rules.recommended(3), 955, "stage 3: 830 x 1.15")
		eq(Rules.recommended(99), 0, "no such stage")
		for n = 2, Rules.STAGE_COUNT - 1 do
			local s = Rules.STAGES[n]
			local best = Rules.recommended(n)
			eq(best, math.ceil(s.need * 1.15), "recommended 15% above the need at " .. n)
			check(best < Rules.STAGES[n + 1].need, "below the next stage's need at " .. n)
			-- More Speed, more room on the longest jump.
			check(Rules.walkSpeed(best) * Rules.airtime(0) - s.gap > s.walk * Rules.airtime(0) - s.gap, "more reserve at " .. n)
		end
		-- The last stage's need is the Speed cap: nothing above it runs faster.
		eq(Rules.recommended(Rules.STAGE_COUNT), Rules.STAGES[Rules.STAGE_COUNT].need, "stage 10 recommends its need")
	end)

	test("Cardio: first clears are kept per plate", function()
		eq(Rules.firstsOf(nil, 0), 0, "a new save has taken none")
		eq(Rules.firstsOf(nil, 3), 7, "an old save took every plate up to bestStage")
		eq(Rules.firstsOf(nil, 99), 1023, "clamped to the ten plates")
		eq(Rules.firstsOf(5, 9), 5, "a saved set wins over bestStage")
		eq(Rules.firstsOf(5.7, 0), 5, "whole numbers only")
		eq(Rules.firstsOf(1e9, 0), 1023, "never more than the ten plates")
		eq(Rules.firstsOf(-4, 2), 3, "junk falls back to bestStage")
		eq(Rules.firstsOf(0 / 0, 2), 3, "NaN falls back to bestStage")
		local firsts = 0
		for n = 1, Rules.STAGE_COUNT do
			check(Rules.isFirst(firsts, n), "plate " .. n .. " starts as a first clear")
		end
		firsts = Rules.claimFirst(firsts, 5)
		check(not Rules.isFirst(firsts, 5), "plate 5 taken")
		for n = 1, Rules.STAGE_COUNT do
			if n ~= 5 then
				check(Rules.isFirst(firsts, n), "claiming plate 5 leaves plate " .. n)
			end
		end
		eq(Rules.claimFirst(firsts, 5), firsts, "claiming twice changes nothing")
		eq(Rules.claimFirst(firsts, 0), firsts, "no plate 0")
		eq(Rules.claimFirst(firsts, 11), firsts, "no plate 11")
		check(not Rules.isFirst(0, 0) and not Rules.isFirst(0, 11), "only plates 1..10 have a first clear")
		for n = 1, Rules.STAGE_COUNT do
			firsts = Rules.claimFirst(firsts, n)
		end
		eq(firsts, 1023, "all ten taken")
	end)

	test("Cardio: a skipped plate keeps its first clear", function()
		local def, rig = loadCardio(0)
		local player, profile = rig.player, rig.session.profile
		local rec = profile.cardio
		check(def.start(player, true), "start")
		-- Run past plates 1 and 2, cash out on plate 3.
		rig.reach(1, 3)
		local snap = def.snapshot(player)
		for n = 1, Rules.STAGE_COUNT do
			eq(snap.firsts[n], true, "every plate is a first clear at " .. n)
		end
		eq(snap.recommended[3], Rules.recommended(3), "recommended Speed in the snapshot")
		local pay1, pay2, pay3 = snap.wins[1], snap.wins[2], snap.wins[3]
		rig.plate(3)
		local win = rig.last("win")
		check(win.stage == 3 and win.first == true and win.cash == pay3, "plate 3 pays its first clear")
		eq(rec.bestStage, 3, "bestStage 3")
		eq(profile.money, pay3, "paid once")
		-- The reward cooldown is running, yet the skipped plates still pay: first clears.
		rig.reach(1, 1)
		local z1 = rig.last("zone")
		check(z1.stage == 1 and z1.first == true and z1.cash == pay1, "skipped plate 1 is still a first clear")
		snap = def.snapshot(player)
		check(snap.firsts[1] and snap.firsts[2] and not snap.firsts[3], "the snapshot marks what is left")
		eq(snap.wins[3], 0, "plate 3 is on the cooldown now")
		rig.plate(1)
		check(rig.last("win").first == true and rig.last("win").cash == pay1, "plate 1 pays its first clear later")
		eq(profile.money, pay3 + pay1, "plate 1 paid")
		eq(rec.bestStage, 3, "an earlier plate does not lower bestStage")
		rig.reach(1, 2)
		rig.plate(2)
		check(rig.last("win").first == true and rig.last("win").cash == pay2, "so does plate 2")
		eq(profile.money, pay3 + pay1 + pay2, "all three first clears paid, in any order")
		-- Each first clear only once.
		rig.reach(1, 2)
		check(rig.last("zone").first == false and rig.last("zone").cash == 0, "plate 2 is a repeat now")
		rig.plate(2)
		eq(profile.money, pay3 + pay1 + pay2, "no second first clear")
		eq(rec.firsts, 7, "plates 1-3 taken in the save")

		-- A save from before per-plate firsts (bestStage 5): plates 1-5 count as taken, as they
		-- did under the old rule; nothing is lost and 6+ are first clears.
		def, rig = loadCardio(5)
		check(def.start(rig.player, true), "start on an old save")
		snap = def.snapshot(rig.player)
		for n = 1, Rules.STAGE_COUNT do
			eq(snap.firsts[n], n > 5, "old save: first clears from plate 6, at " .. n)
		end
		eq(rig.session.profile.cardio.firsts, 31, "the set is filled in from bestStage")
		eq(rig.session.profile.cardio.bestStage, 5, "bestStage untouched")
	end)

	test("Cardio: run again bonus rules", function()
		eq(Rules.REPEAT_GAP, 30, "the bonus is paid at most every 30 s")
		eq(Rules.repeatFrom(0), 1, "no best yet: plate 1")
		eq(Rules.repeatFrom(4), 4, "the best plate")
		eq(Rules.repeatFrom(4.9), 4, "whole plates")
		eq(Rules.repeatFrom(99), Rules.STAGE_COUNT, "clamped to the last plate")
		for best = 0, Rules.STAGE_COUNT do
			for n = 1, Rules.STAGE_COUNT do
				local want = n >= math.max(best, 1)
				eq(Rules.repeatEarned(n, best, Rules.REPEAT_GAP), want, "plate " .. n .. " with best " .. best)
				eq(Rules.repeatEarned(n, best, math.huge), want, "long after the last pay, plate " .. n .. " with best " .. best)
				check(not Rules.repeatEarned(n, best, Rules.REPEAT_GAP - 0.01), "never inside the gap at " .. n .. "/" .. best)
				check(not Rules.repeatEarned(n, best, 0), "never right after a paid plate at " .. n .. "/" .. best)
			end
		end
		eq(Rules.payKind(true, true, false), "first", "a first clear")
		eq(Rules.payKind(true, true, true), "first", "a first clear is never a repeat")
		eq(Rules.payKind(false, true, true), "full", "the cooldown is over")
		eq(Rules.payKind(false, false, true), "repeat", "an earned repeat")
		eq(Rules.payKind(false, false, false), "none", "a repeat that was not earned")
		eq(Rules.payKind(false, false, false, true), "resting", "a repeat inside the gap rests")
		eq(Rules.payKind(false, false, true, true), "repeat", "an earned repeat is never resting")
		eq(Rules.payKind(false, true, false, true), "full", "the full reward never rests")
	end)

	test("Cardio: the run again bonus needs a real run", function()
		local def, rig = loadCardio(0)
		local player, profile = rig.player, rig.session.profile
		local rec = profile.cardio
		local share = Economy.MODE_REPEAT_SHARE
		check(def.start(player, true), "start")
		-- First clears of plates 1 and 2 (best plate 2); the reward cooldown is running.
		rig.reach(1, 1)
		rig.plate(1)
		local pack1 = rig.last("win").cash
		eq(rig.last("win").pay, "first", "plate 1: a first clear")
		check(rig.last("win").newBest == true and rig.last("win").prevBest == 0, "the first plate is a new best")
		rig.reach(1, 2)
		rig.plate(2)
		local first2 = rig.last("win")
		local pack2 = first2.cash
		check(first2.pay == "first" and first2.newBest == true and first2.prevBest == 1, "plate 2: a first clear and a new best")
		eq(first2.bestStage, 2, "best plate 2")
		local paid = pack1 + pack2
		eq(profile.money, paid, "two first clears paid")
		local lastRewardAt = profile.modes.cardio.lastRewardAt

		-- Looping in seconds pays nothing: quick runs to the best plate, 3 s apart.
		for _ = 1, 4 do
			rig.reach(1, 2)
			rig.plate(2)
			eq(rig.last("win").pay, "resting", "inside the gap: the bonus rests")
			eq(rig.last("win").cash, 0, "and pays nothing")
			check(rig.last("win").repeatReadyAt > 0, "the win says when the bonus is back")
		end
		eq(profile.money, paid, "nothing farmed in seconds")

		-- After the gap, a run to the best plate pays the share of that plate's pack, once.
		rig.clock.t += Rules.REPEAT_GAP
		rig.reach(1, 2)
		local zone = rig.last("zone")
		local bonus2 = math.floor(pack2 * share)
		check(zone.pay == "repeat" and zone.cash == bonus2 and zone.full == false, "the zone announces the bonus")
		check(zone.packCash == pack2 and zone.repeatCash == bonus2 and zone.repeatShare == share, "with the plate's prices")
		eq(zone.repeatFrom, 2, "from the best plate")
		local snap = def.snapshot(player)
		eq(snap.wins[2], bonus2, "snapshot: plate 2 pays the bonus now")
		eq(snap.wins[1], 0, "snapshot: plate 1 is before the best plate")
		eq(snap.repeats[1], 0, "no bonus on plate 1")
		eq(snap.repeats[2], bonus2, "the bonus on plate 2")
		check(snap.repeats[3] == 0 and snap.firsts[3] == true, "plate 3 is still a first clear, not a repeat")
		check(snap.repeatFrom == 2 and snap.repeatReadyAt == 0 and snap.repeatShare == share, "snapshot: the bonus is ready")
		rig.plate(2)
		local win = rig.last("win")
		check(win.pay == "repeat" and win.cash == bonus2 and win.full == false, "the run again bonus is paid")
		check(win.newBest == false and win.prevBest == 2, "a repeat is no new best")
		check(win.packCash == pack2 and win.repeatCash == bonus2 and win.repeatShare == share, "the card's fields")
		paid += bonus2
		eq(profile.money, paid, "paid once")
		eq(profile.totalEarned, paid, "and counted as earned")
		eq(profile.modes.cardio.lastRewardAt, lastRewardAt, "the bonus does not restart the cooldown")
		eq(rec.bestStage, 2, "nor change the best plate")
		check(rig.inLobby(), "the claim still ends the run")
		-- The same plate again without running to it, even after the gap: nothing reached.
		rig.clock.t += Rules.REPEAT_GAP
		rig.plate(2)
		rig.plate(2)
		eq(profile.money, paid, "a plate cannot be stepped on again without running to it")
		-- A real run after the gap is paid again...
		rig.reach(1, 2)
		rig.plate(2)
		paid += bonus2
		eq(profile.money, paid, "the next real run after the gap is paid")
		-- ...and right away again: inside the gap.
		rig.reach(1, 2)
		eq(rig.last("zone").pay, "resting", "seconds later the bonus rests")
		snap = def.snapshot(player)
		check(snap.wins[2] == 0 and snap.repeats[2] == bonus2 and snap.repeatReadyAt > 0, "the snapshot says the bonus is waiting")
		rig.plate(2)
		eq(profile.money, paid, "not twice in a row")

		-- A plate before the best one never pays the bonus, however long the wait.
		rig.clock.t += 10 * Rules.REPEAT_GAP
		rig.reach(1, 1)
		check(rig.last("zone").pay == "none" and rig.last("zone").cash == 0, "plate 1 is before the best plate")
		rig.plate(1)
		check(rig.last("win").pay == "none" and rig.last("win").cash == 0, "plate 1 pays nothing")
		eq(profile.money, paid, "no bonus for a shorter run")

		-- A plate beyond the best one whose first clear is gone pays the bonus too.
		rec.firsts = Rules.claimFirst(rec.firsts, 3)
		rig.reach(1, 3)
		check(rig.last("zone").pay == "repeat", "a plate beyond the best one earns the bonus")
		rig.plate(3)
		local deep = rig.last("win")
		check(deep.pay == "repeat" and deep.cash == deep.repeatCash and deep.cash > bonus2, "paid on its bigger pack")
		check(deep.newBest == true and deep.bestStage == 3, "and it is the new best plate")
		paid += deep.cash
		eq(profile.money, paid, "paid")

		-- Ten minutes of looping the best plate: at most one bonus per gap.
		local before, runs = profile.money, 0
		local t0 = rig.clock.t
		while rig.clock.t - t0 < 600 do
			rig.reach(1, 3)
			rig.plate(3)
			runs += 1
		end
		local bonus3 = deep.cash
		check(runs >= 80, "many quick runs (" .. runs .. ")")
		check(profile.money - before <= (600 / Rules.REPEAT_GAP) * bonus3, "ten minutes of looping pay at most 20 bonuses")
		check(profile.money - before >= 10 * bonus3, "and a steady runner does get them")

		-- After the cooldown the plate pays in full again (not the bonus).
		profile.modes.cardio.lastRewardAt = os.time() - Economy.MODE_REWARD_COOLDOWN - 1
		rig.clock.t += Rules.REPEAT_GAP
		rig.reach(1, 3)
		check(rig.last("zone").pay == "full" and rig.last("zone").cash == deep.packCash, "the full pack after the cooldown")
		eq(def.snapshot(player).repeats[3], 0, "no bonus to show while the plate pays in full")
		rig.plate(3)
		eq(rig.last("win").pay, "full", "paid in full")

		-- The Modes window's preview carries the bonus fields.
		local preview = def.rewardPreview(player)
		check(preview.repeatShare == share and preview.repeatCash == math.floor(preview.packCash * share), "preview fields")
	end)

	test("Cardio: a fall says whether the runner was too slow", function()
		local def, rig = loadCardio(0)
		local player, rec = rig.player, rig.session.profile.cardio
		local r3 = Layout.room(3)
		local x = (r3.x0 + r3.x1) / 2
		local function fallIn3(): any
			rig.reach(1, 2)
			rig.feet(x, Layout.killYAt(x) - 10, O.z)
			return rig.last("fall")
		end
		-- Below stage 3's need: too slow.
		rec.speed = 200
		check(def.start(player, true), "start")
		local fall = fallIn3()
		eq(fall.from, 3, "fell in stage 3")
		eq(fall.need, Rules.STAGES[3].need, "stage 3's need")
		check(fall.speed >= 200 and fall.speed < fall.need, "the runner's Speed")
		check(fall.slow == true and fall.capped == false, "too slow for the stage")
		-- Enough Speed: just a fall.
		rec.speed = Rules.STAGES[3].need + 500
		check(def.start(player, true), "restart with enough Speed")
		fall = fallIn3()
		check(fall.slow == false and fall.capped == false, "fast enough: a missed jump")
		-- Enough Speed, but the player's own cap holds the run back.
		rec.speedCap = 20
		check(def.start(player, true), "restart with a speed cap")
		fall = fallIn3()
		check(fall.slow == true and fall.capped == true, "slow only because of the custom speed cap")
		-- Stage 1 needs nothing: never "too slow".
		rec.speedCap = 0
		rec.speed = 0
		check(def.start(player, true), "restart at 0 Speed")
		local r1 = Layout.room(1)
		local x1 = (r1.x0 + r1.x1) / 2
		rig.feet(x1, Layout.killYAt(x1) - 10, O.z)
		fall = rig.last("fall")
		check(fall.from == 1 and fall.need == 0 and fall.slow == false, "a stage 1 fall is never about Speed")
		-- Off the side of safe zone 3's own deck: a plain fall, not stage 4's need.
		check(def.start(player, true), "restart for a zone fall")
		local z3 = Layout.zone(3)
		local zx = (z3.x0 + z3.x1) / 2
		rig.feet(zx, Layout.killYAt(zx) - 10, O.z)
		fall = rig.last("fall")
		check(fall.zone == 3 and fall.slow == false and fall.capped == false, "a fall off zone 3 says so")
		check(rig.last("fall").from == 4, "still counted from stage 4")
	end)
end
