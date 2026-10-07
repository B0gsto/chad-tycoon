--[[
	Unit tests for the CARDIO rules (src/server/Modes/CardioRules.luau) and the keyboard runway
	layout (src/server/Modes/CardioLayout.luau).
	Loaded by tests/run.luau with its harness: { test, check, eq, near, seeded }.
]]

local fs = require("@lune/fs")
local luau = require("@lune/luau")

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
			speed += 0.5 * steps * Rules.stepMultiplier(best, level) + 0.5 * Rules.treadmillRate(best, level)
			while best < Rules.STAGE_COUNT and speed >= Rules.STAGES[best + 1].need do
				best += 1
				at[best] = t / 60
			end
		end
		check(at[2] <= 3, "stage 2 in the first few minutes (" .. at[2] .. ")")
		check(at[3] <= 8, "stage 3 soon after (" .. at[3] .. ")")
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
		check(#keys <= 9000, "key budget (" .. #keys .. " keys)")
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
			near(z.z1 - z.z0, Layout.CORRIDOR.width, "deck " .. z.stage .. " is full width")
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
		for _, z in L.zones do
			check(#z.treadmills >= 2, "treadmills in zone " .. z.stage)
			for _, tm in z.treadmills do
				check(tm.x - T.length / 2 >= z.x0 and tm.x + T.length / 2 <= z.x1, "treadmill on its deck (x)")
				check(tm.z - T.width / 2 >= z.z0 and tm.z + T.width / 2 <= z.z1, "treadmill on its deck (z)")
				check(math.abs(tm.z - O.z) >= 8 + T.width / 2, "treadmills leave the running lane free")
			end
			if z.winPad then
				check(z.winPad.x - z.winPad.size / 2 >= z.x0 and z.winPad.x + z.winPad.size / 2 <= z.x1, "win pad on its deck")
			end
			check(z.checkpoint.x > z.x0 and z.checkpoint.x < z.x1, "checkpoint on its deck")
		end
		check(L.zones[1].upgradePad ~= nil and #L.zones[1].treadmills >= 2, "lobby has treadmills and the upgrade pad")
		check(L.zones[1].winPad == nil, "no win pad in the lobby")
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
		local cp = Layout.checkpoint(0)
		check(cp ~= nil and cp.x == lobby.checkpoint.x, "lobby checkpoint")
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
		local c = Layout.checkpointAt(cp.x, cp.z, O.y)
		check(c ~= nil and c.stage == 0 and c.index == 0, "checkpointAt lobby")
		for i, ch in L.checkpoints do
			eq(ch.order, i, "checkpoint order")
			if i > 1 then
				check(ch.x > L.checkpoints[i - 1].x, "checkpoints go along the course")
			end
		end
		local mid = {}
		for _, ch in L.checkpoints do
			if ch.index > 0 then
				mid[ch.stage] = (mid[ch.stage] or 0) + 1
			end
		end
		check((mid[1] or 0) >= (mid[5] or 0) and (mid[10] or 0) == 0, "fewer checkpoints later")
		check(L.finish.x > L.zones[#L.zones].x0, "finish on the last deck")
		eq(Layout.killYAt(-5000), Layout.KILL_Y, "killYAt outside the rooms")
		local r3 = Layout.room(3)
		check(r3 ~= nil and Layout.roomAt((r3.x0 + r3.x1) / 2) == r3 and r3.stage == 3, "roomAt")
		eq(Layout.stageAt(r3.x0 + 1), 3, "stageAt in bridge room 3")
	end)
end
