--!strict
--[[
	CardioChase: the CHASER CHADS of the CARDIO keyboard runner (stages 3, 6 and 9). Pure and
	deterministic (no Roblox APIs; unit-tested in tests/cardio_chase.luau); Modes.Cardio calls
	`serve(...)` once and feeds it every running player's position each tick.

	A chase stage's SECTION is its bridge room's path (CardioLayout platforms of stage n: west
	sill, run-up, jump platforms, end platform, east sill). Walking TRIGGER studs onto the
	run-up (its first "run" piece starts at `x0`; within TRIGGER_WINDOW studs past that, so
	respawning at a mid-stage checkpoint does not start one) begins a chase: a big Chad of
	TUNING[n].tier, scaled TUNING[n].scale, appears in the west doorway (`startX`) and, after
	`headStart` seconds, runs along the path's CENTRE LINE `line` (vertices { s, x, z, half }:
	every surface's centre from x0 to x1, joined straight over gaps and the run-up's jog; s =
	distance along it, half = the surface's half width across Z):
	  s(t)  = min(stopS, startS + speed * max(0, t - startAt))
	  x, pz, half = the line at s (linear between vertices)
	  z(t)  = clamp(pz + clamp(playerZ - pz, -half, half) * min(1, run / LANE_EASE), zMin, zMax)
	with speed = SPEED_FACTOR * walkSpeed(need_n) and zMin / zMax the room's side walls minus
	WALL_MARGIN. It hovers / hops over gaps (the client draws a jump arc from `path`) and stops
	STOP_SHORT studs before the end platform (stopS). A runner at walkSpeed(need_n) along the
	same line stays ahead with >= MIN_SLACK seconds to spare; anyone slower
	(walkSpeed(need_n-1) can't clear the stage's longest gap) gets caught.
	  caught    chaser x >= player x - catchRadius  -> back to safe zone n-1 (Modes.Cardio)
	  escaped   player x >= endX (ESCAPE_IN studs onto the end platform, before the timed exit
	            door; not chased again this run)
	  retreat   player x < x0 - 1 (back in the west doorway; re-entering restarts it)
	The client (Fx.CardioChase) gets the whole chase in the "chase" notify and places the Chad
	with the same formula every frame from workspace:GetServerTimeNow().
]]

local Rules = require(script.Parent.CardioRules)
local Layout = require(script.Parent.CardioLayout)

local CardioChase = {}

CardioChase.STAGES = { 3, 6, 9 }
-- Chaser speed as a share of walkSpeed(need_n).
CardioChase.SPEED_FACTOR = 0.9
-- Studs onto the run-up that start a chase, and how far past that a chase may still start.
CardioChase.TRIGGER = 6
CardioChase.TRIGGER_WINDOW = 40
-- Seconds for the chaser to swing from the path's centre toward the player's z.
CardioChase.LANE_EASE = 1
-- The chaser stops this far short of the end platform (hovering over the last gap).
CardioChase.STOP_SHORT = 3
-- Studs onto the end platform that count as an escape.
CardioChase.ESCAPE_IN = 2
-- Keep the chaser this far inside the bridge room's side walls.
CardioChase.WALL_MARGIN = 6
-- Seconds a runner at exactly walkSpeed(need_n) may lose (blinking keys, a late jump) and
-- still escape (checked in tests/cardio_chase.luau).
CardioChase.MIN_SLACK = 1

export type Tuning = { tier: number, scale: number, headStart: number, catchRadius: number, speed: number }

-- Per chase stage: Theme.Tiers index of the chaser's look, model scale, seconds of head
-- start, catch radius (studs along X). speed (studs/s) is set below from SPEED_FACTOR.
CardioChase.TUNING = {
	[3] = { tier = 10, scale = 2.0, headStart = 1.2, catchRadius = 4, speed = 0 },
	[6] = { tier = 17, scale = 2.2, headStart = 1.2, catchRadius = 4.5, speed = 0 },
	[9] = { tier = 24, scale = 2.4, headStart = 1.2, catchRadius = 5, speed = 0 },
} :: { [number]: Tuning }

for n, tune in CardioChase.TUNING do
	tune.speed = math.floor(CardioChase.SPEED_FACTOR * Rules.walkSpeed(Rules.STAGES[n].need) * 10 + 0.5) / 10
end

-- A walking surface along the section: [x0, x1] at height top, across [z0, z1].
export type Surface = { x0: number, x1: number, top: number, z0: number, z1: number }
-- A vertex of the path's centre line: distance s along it, position (x, z), half width.
export type Vertex = { s: number, x: number, z: number, half: number }

export type Section = {
	stage: number,
	-- Start of the run-up (first "run" piece), the escape line and the chaser's stop.
	x0: number,
	endX: number,
	stopX: number,
	-- The bridge path's surfaces in order along +X and their centre line.
	path: { Surface },
	line: { Vertex },
	startX: number,
	startS: number,
	stopS: number,
	zMin: number,
	zMax: number,
}

export type Chase = {
	stage: number,
	tier: number,
	scale: number,
	speed: number,
	headStart: number,
	catchRadius: number,
	startX: number,
	startZ: number,
	startS: number,
	stopS: number,
	startAt: number,
	endX: number,
	zMin: number,
	zMax: number,
	path: { Surface },
	line: { Vertex },
}

local LAYOUT = Layout.LAYOUT
local SECTIONS: { [number]: Section } = {}

local function round1(v: number): number
	return math.floor(v * 10 + 0.5) / 10
end

-- The centre line at distance s: x, z, half width (clamped to the line's ends).
function CardioChase.lineAt(line: { Vertex }, s: number): (number, number, number)
	local first = line[1]
	if s <= first.s then
		return first.x, first.z, first.half
	end
	for i = 2, #line do
		local b = line[i]
		if s <= b.s then
			local a = line[i - 1]
			local u = if b.s > a.s then (s - a.s) / (b.s - a.s) else 1
			return a.x + (b.x - a.x) * u, a.z + (b.z - a.z) * u, a.half + (b.half - a.half) * u
		end
	end
	local last = line[#line]
	return last.x, last.z, last.half
end

-- Distance along the line where it first reaches x.
function CardioChase.arcAt(line: { Vertex }, x: number): number
	if x <= line[1].x then
		return line[1].s
	end
	for i = 2, #line do
		local a, b = line[i - 1], line[i]
		if x <= b.x then
			local u = if b.x > a.x then (x - a.x) / (b.x - a.x) else 1
			return a.s + (b.s - a.s) * u
		end
	end
	return line[#line].s
end

for n in CardioChase.TUNING do
	local room = Layout.room(n)
	assert(room, `CardioChase: no bridge room for stage {n}`)
	local plats = {}
	for _, p in LAYOUT.platforms do
		if p.stage == n then
			table.insert(plats, p)
		end
	end
	table.sort(plats, function(a, b)
		return a.x0 < b.x0
	end)
	local path: { Surface } = {}
	local line: { Vertex } = {}
	local x0, endPlat: Layout.Platform? = nil, nil
	for _, p in plats do
		if p.kind == "run" and not x0 then
			x0 = p.x0
		elseif p.kind == "end" then
			endPlat = p
		end
		local s: Surface = { x0 = round1(p.x0), x1 = round1(p.x1), top = round1(p.top), z0 = round1(p.z0), z1 = round1(p.z1) }
		table.insert(path, s)
		local zc, half = (s.z0 + s.z1) / 2, (s.z1 - s.z0) / 2
		for _, vx in { s.x0, s.x1 } do
			local prev = line[#line]
			local d = if prev then math.sqrt((vx - prev.x) ^ 2 + (zc - prev.z) ^ 2) else 0
			table.insert(line, { s = if prev then round1(prev.s + d) else 0, x = vx, z = zc, half = half })
		end
	end
	assert(x0 and endPlat, `CardioChase: stage {n} has no run-up / end platform`)
	local startX = x0 - Layout.DOOR_WALL / 2
	local stopX = endPlat.x0 - CardioChase.STOP_SHORT
	SECTIONS[n] = {
		stage = n,
		x0 = x0,
		endX = endPlat.x0 + CardioChase.ESCAPE_IN,
		stopX = stopX,
		path = path,
		line = line,
		startX = startX,
		startS = CardioChase.arcAt(line, startX),
		stopS = CardioChase.arcAt(line, stopX),
		zMin = room.z0 + CardioChase.WALL_MARGIN,
		zMax = room.z1 - CardioChase.WALL_MARGIN,
	}
end

function CardioChase.isChaseStage(n: number): boolean
	return CardioChase.TUNING[n] ~= nil
end

function CardioChase.section(n: number): Section?
	return SECTIONS[n]
end

-- Is a runner at x (in stage n's bridge room) where a chase starts?
function CardioChase.triggers(n: number, x: number): boolean
	local sec = SECTIONS[n]
	if not sec then
		return false
	end
	local from = sec.x0 + CardioChase.TRIGGER
	return x >= from and x <= from + CardioChase.TRIGGER_WINDOW
end

function CardioChase.begin(n: number, _z: number, now: number): Chase?
	local sec, tune = SECTIONS[n], CardioChase.TUNING[n]
	if not sec or not tune then
		return nil
	end
	local _, startZ = CardioChase.lineAt(sec.line, sec.startS)
	return {
		stage = n,
		tier = tune.tier,
		scale = tune.scale,
		speed = tune.speed,
		headStart = tune.headStart,
		catchRadius = tune.catchRadius,
		startX = sec.startX,
		startZ = math.clamp(startZ, sec.zMin, sec.zMax),
		startS = sec.startS,
		stopS = sec.stopS,
		startAt = now + tune.headStart,
		endX = sec.endX,
		zMin = sec.zMin,
		zMax = sec.zMax,
		path = sec.path,
		line = sec.line,
	}
end

-- Chaser feet (x, z) at server time t, on the path's centre line eased toward the player's z.
function CardioChase.position(chase: Chase, t: number, playerZ: number): (number, number)
	local run = math.max(0, t - chase.startAt)
	local s = math.min(chase.stopS, chase.startS + chase.speed * run)
	local x, pz, half = CardioChase.lineAt(chase.line, s)
	local pull = math.clamp(playerZ - pz, -half, half) * math.min(1, run / CardioChase.LANE_EASE)
	return x, math.clamp(pz + pull, chase.zMin, chase.zMax)
end

-- Feet height along a path at x: the surface top, or a jump arc over gaps.
function CardioChase.groundY(path: { Surface }, x: number, hop: number?): number
	local prev: Surface? = nil
	for _, s in path do
		if x < s.x0 then
			if not prev then
				return s.top
			end
			local u = (x - prev.x1) / math.max(0.01, s.x0 - prev.x1)
			local h = hop or 4
			return prev.top + (s.top - prev.top) * u + 4 * h * u * (1 - u)
		elseif x <= s.x1 then
			return s.top
		end
		prev = s
	end
	return if prev then prev.top else 0
end

-- "caught" | "escaped" | "retreat" | nil (still on) for a runner at (x, z) at time t.
function CardioChase.update(chase: Chase, x: number, z: number, t: number): string?
	if x >= chase.endX then
		return "escaped"
	end
	if x < chase.startX + Layout.DOOR_WALL / 2 - 1 then
		return "retreat"
	end
	local cx = CardioChase.position(chase, t, z)
	if t >= chase.startAt and cx >= x - chase.catchRadius then
		return "caught"
	end
	return nil
end

-- The "chase" notify payload (everything the client needs to replay the chaser).
function CardioChase.payload(chase: Chase): { [string]: any }
	local path, line = {}, {}
	for _, s in chase.path do
		table.insert(path, { s.x0, s.x1, s.top, s.z0, s.z1 })
	end
	for _, v in chase.line do
		table.insert(line, { v.s, v.x, v.z, v.half })
	end
	local stopX = CardioChase.lineAt(chase.line, chase.stopS)
	return {
		stage = chase.stage,
		tier = chase.tier,
		scale = chase.scale,
		speed = chase.speed,
		startX = chase.startX,
		startZ = chase.startZ,
		startS = chase.startS,
		stopS = chase.stopS,
		startAt = chase.startAt,
		endX = stopX,
		zMin = chase.zMin,
		zMax = chase.zMax,
		laneEase = CardioChase.LANE_EASE,
		path = path,
		line = line,
	}
end

export type Server = {
	-- Feed a running player's feet each tick; returns the safe zone to send them back to when
	-- the chaser caught them this tick.
	tick: (player: any, x: number, z: number, t: number) -> number?,
	-- Ends the player's chase (if any) with `reason`; "chaseEnd" unless silent.
	stop: (player: any, reason: string, silent: boolean?) -> (),
	-- The run ended: also forget which chases were escaped.
	forget: (player: any) -> (),
	active: (player: any) -> Chase?,
}

-- Per-player chase state for Modes.Cardio. notify(player, event, payload) sends a cardio
-- Notify ("chase" | "caught" | "chaseEnd").
function CardioChase.serve(notify: (any, string, { [string]: any }) -> ()): Server
	local chases: { [any]: Chase } = {}
	local escaped: { [any]: { [number]: boolean } } = {}
	local server = {} :: Server

	function server.tick(player: any, x: number, z: number, t: number): number?
		local c = chases[player]
		if c then
			local result = CardioChase.update(c, x, z, t)
			if result == "caught" then
				chases[player] = nil
				notify(player, "caught", { stage = c.stage })
				return c.stage - 1
			elseif result then
				chases[player] = nil
				if result == "escaped" then
					escaped[player] = escaped[player] or {}
					escaped[player][c.stage] = true
				end
				notify(player, "chaseEnd", { stage = c.stage, reason = result })
			end
			return nil
		end
		local n = Layout.stageAt(x)
		local done = escaped[player]
		if CardioChase.triggers(n, x) and not (done and done[n]) then
			local chase = CardioChase.begin(n, z, t)
			if chase then
				chases[player] = chase
				notify(player, "chase", CardioChase.payload(chase))
			end
		end
		return nil
	end

	function server.stop(player: any, reason: string, silent: boolean?)
		local c = chases[player]
		if c then
			chases[player] = nil
			if not silent then
				notify(player, "chaseEnd", { stage = c.stage, reason = reason })
			end
		end
	end

	function server.forget(player: any)
		chases[player] = nil
		escaped[player] = nil
	end

	function server.active(player: any): Chase?
		return chases[player]
	end

	return server
end

return CardioChase
