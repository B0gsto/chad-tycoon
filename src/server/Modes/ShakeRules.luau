--!strict
--[[
	ShakeRules: the pure rules of SHAKE CATCH (Modes.Shake; docs/minigames.md). No Roblox
	services: tests/shake.luau loads it with Lune.

	A run is RUN_SECONDS long, split into WAVES that drop faster and denser. Every drop is
	worked out up front from the run's seed (schedule), so the server and the client agree on
	where and when each item lands: the server sends a wave's drops before it starts and
	Fx.Shake animates them locally against the server clock.
	  Good items: protein shake (+1), golden dumbbell (+3, rare), aura orb (+1).
	  Junk food: burger, donut, soda. Catching one costs a heart (HEARTS per run).
	A drop is caught when the player's root stood within the catch radius of its landing
	spot at some moment of the window around the land time (caught; the window covers the
	server's view of a moving player arriving a little late). Junk uses a smaller radius and
	a tighter window, so near misses never cost a heart.
	The run is passed with TARGET points: when the clock runs out, or when the hearts run out
	after the target was already reached (outcome). Out of hearts below the target: "lose".

	ARENA is where World.ShakeArena builds the arena (floor top centre and size in studs,
	out over the sea away from the Parkour maps, the Mog stage and the Cardio track; tests/
	minigames.luau keeps every arena clear of the others).
]]

local ShakeRules = {}

ShakeRules.ARENA = { x = 380, y = 6, z = -380, sizeX = 64, sizeZ = 64 }
-- Feet more than this far under the floor top: the player fell off and goes back to the spawn.
ShakeRules.FALL_BELOW = 20

ShakeRules.RUN_SECONDS = 60
ShakeRules.HEARTS = 3
ShakeRules.TARGET = 25
-- Seconds between "start" and the first wave (the HUD counts 3, 2, 1).
ShakeRules.READY_SECONDS = 3
-- A pass inside the reward cooldown pays the repeat share at most this often (seconds).
ShakeRules.REPEAT_GAP = 120

-- Catch radius and window (seconds before / after the land time) for good items and junk.
ShakeRules.CATCH = { radius = 4.5, early = 0.3, late = 0.3 }
-- Junk is judged a touch late (the server sees a dodging player where they were a moment ago).
ShakeRules.JUNK = { radius = 3, early = 0, late = 0.2 }
-- The exit pad (World.Arena: +X / +Z corner, 5 studs in from both edges) and how far from it
-- no drop may land, so chasing a corner drop never walks the player out of a run (the exit
-- arch's posts stand inside this circle too).
ShakeRules.EXIT = { x = ShakeRules.ARENA.x + ShakeRules.ARENA.sizeX / 2 - 5, z = ShakeRules.ARENA.z + ShakeRules.ARENA.sizeZ / 2 - 5 }
ShakeRules.EXIT_CLEAR = 10
-- The server sees a player's position this late: about half the round trip plus a frame of
-- replication (lagOf). Samples are stamped back by it so dodges count when they happened.
ShakeRules.LAG_MAX = 0.4
-- A sample further than this (studs) from the last tick's position is a teleport: dropped.
ShakeRules.MAX_STEP = 40
-- A drop is judged this long after it lands (the longest `late`), once every sample is in.
ShakeRules.SETTLE = 0.3

-- "shake" | "gold" | "orb" (good) or "burger" | "donut" | "soda" (junk).
export type Kind = string

-- Points per kind (0: junk food, catching it costs a heart instead).
ShakeRules.POINTS = { shake = 1, gold = 3, orb = 1, burger = 0, donut = 0, soda = 0 } :: { [string]: number }
ShakeRules.JUNK_KINDS = { "burger", "donut", "soda" } :: { Kind }

-- The waves: `from` seconds into the run, a drop every `gap` seconds (a `double` share of
-- them drop a second item too), each falling for `fall` seconds; `junk`, `gold` and `orb`
-- are the chances of each kind (the rest are shakes); `reach` is how far (studs) a drop may
-- land from the one before, so the action wanders round the court instead of jumping across.
export type Wave = {
	from: number,
	gap: number,
	fall: number,
	double: number,
	junk: number,
	gold: number,
	orb: number,
	reach: number,
}
ShakeRules.WAVES = {
	{ from = 0, gap = 1.1, fall = 2.4, double = 0, junk = 0.15, gold = 0.08, orb = 0.15, reach = 14 },
	{ from = 15, gap = 0.9, fall = 2.0, double = 0.1, junk = 0.22, gold = 0.08, orb = 0.15, reach = 16 },
	{ from = 30, gap = 0.75, fall = 1.75, double = 0.2, junk = 0.28, gold = 0.09, orb = 0.15, reach = 18 },
	{ from = 45, gap = 0.6, fall = 1.5, double = 0.3, junk = 0.32, gold = 0.1, orb = 0.15, reach = 20 },
} :: { Wave }

export type Area = { x0: number, x1: number, z0: number, z1: number }
export type Drop = {
	id: number,
	wave: number,
	kind: Kind,
	x: number,
	z: number,
	-- Seconds after the first wave starts (run time) the item appears and lands.
	spawnAt: number,
	landAt: number,
}
export type Sample = { t: number, x: number, z: number }

-- A tiny deterministic generator (the same LCG as tests/run.luau's `seeded`): values in [0, 1).
function ShakeRules.rng(seed: number): () -> number
	local state = math.floor(math.abs(seed)) % 2147483648
	return function()
		state = (state * 1103515245 + 12345) % 2147483648
		return state / 2147483648
	end
end

-- The wave running `t` seconds into the run (1 before the first starts, the last one past the end).
function ShakeRules.waveAt(t: number): number
	local index = 1
	for i, wave in ShakeRules.WAVES do
		if t >= wave.from then
			index = i
		end
	end
	return index
end

-- The kind of a drop for roll `r` in [0, 1) in `wave` (`r2` picks which junk food).
function ShakeRules.pick(wave: Wave, r: number, r2: number): Kind
	if r < wave.junk then
		local list = ShakeRules.JUNK_KINDS
		return list[math.clamp(math.floor(r2 * #list) + 1, 1, #list)]
	elseif r < wave.junk + wave.gold then
		return "gold"
	elseif r < wave.junk + wave.gold + wave.orb then
		return "orb"
	end
	return "shake"
end

function ShakeRules.isJunk(kind: string): boolean
	return (ShakeRules.POINTS[kind] or 0) <= 0
end

function ShakeRules.points(kind: string): number
	return ShakeRules.POINTS[kind] or 0
end

-- The lag (seconds) to take off a sample's time for a player whose network ping (round trip,
-- Player:GetNetworkPing seconds) is `ping`.
function ShakeRules.lagOf(ping: number): number
	if ping ~= ping then
		return 0
	end
	return math.clamp(ping / 2 + 1 / 30, 0, ShakeRules.LAG_MAX)
end

-- (x, z) moved out of the `clear`-stud circle round `avoid`: straight away from it, or (when
-- that runs off the area, as past a corner exit) toward the area's centre; clamped to `area`.
function ShakeRules.keepClear(x: number, z: number, area: Area, avoid: { x: number, z: number }, clear: number): (number, number)
	local function inside(px: number, pz: number): boolean
		local dx, dz = px - avoid.x, pz - avoid.z
		return dx * dx + dz * dz < clear * clear
	end
	if not inside(x, z) then
		return x, z
	end
	local dx, dz = x - avoid.x, z - avoid.z
	local dist = math.sqrt(dx * dx + dz * dz)
	if dist >= 0.5 then
		local nx = math.clamp(avoid.x + dx / dist * (clear + 0.5), area.x0, area.x1)
		local nz = math.clamp(avoid.z + dz / dist * (clear + 0.5), area.z0, area.z1)
		if not inside(nx, nz) then
			return nx, nz
		end
	end
	local cx, cz = (area.x0 + area.x1) / 2 - avoid.x, (area.z0 + area.z1) / 2 - avoid.z
	local len = math.max(math.sqrt(cx * cx + cz * cz), 1e-6)
	return math.clamp(avoid.x + cx / len * (clear + 0.5), area.x0, area.x1),
		math.clamp(avoid.z + cz / len * (clear + 0.5), area.z0, area.z1)
end

-- Every drop of a run, in land order, from its seed. Landing spots stay inside `area` and
-- at least EXIT_CLEAR studs from `avoid` (default EXIT); the last items land by RUN_SECONDS.
function ShakeRules.schedule(seed: number, area: Area, avoid: { x: number, z: number }?): { Drop }
	local rand = ShakeRules.rng(seed)
	local exit = avoid or ShakeRules.EXIT
	local drops: { Drop } = {}
	local cx, cz = (area.x0 + area.x1) / 2, (area.z0 + area.z1) / 2
	local function place(reach: number): (number, number)
		local angle = rand() * math.pi * 2
		local dist = reach * (0.35 + 0.65 * rand())
		local x = math.clamp(cx + math.cos(angle) * dist, area.x0, area.x1)
		local z = math.clamp(cz + math.sin(angle) * dist, area.z0, area.z1)
		return ShakeRules.keepClear(x, z, area, exit, ShakeRules.EXIT_CLEAR)
	end
	for index, wave in ShakeRules.WAVES do
		local nextWave = ShakeRules.WAVES[index + 1]
		local stop = if nextWave then nextWave.from else ShakeRules.RUN_SECONDS
		local t = wave.from + (if index == 1 then 0.4 else 0)
		while t + wave.fall <= stop do
			local count = if rand() < wave.double then 2 else 1
			for n = 1, count do
				local kind = ShakeRules.pick(wave, rand(), rand())
				local x, z = place(wave.reach)
				if n == 1 then
					cx, cz = x, z
				end
				table.insert(drops, {
					id = #drops + 1,
					wave = index,
					kind = kind,
					x = x,
					z = z,
					spawnAt = t,
					landAt = t + wave.fall,
				})
			end
			t += wave.gap
		end
	end
	table.sort(drops, function(a, b)
		if a.landAt == b.landAt then
			return a.id < b.id
		end
		return a.landAt < b.landAt
	end)
	return drops
end

-- The most points a run's schedule holds (every good item caught).
function ShakeRules.maxScore(drops: { Drop }): number
	local total = 0
	for _, drop in drops do
		total += ShakeRules.points(drop.kind)
	end
	return total
end

-- True when one of `samples` (run time `t`, root x / z) taken within [landAt - early,
-- landAt + late] stood within the kind's catch radius of the drop's landing spot.
function ShakeRules.caught(samples: { Sample }, drop: Drop): boolean
	local rule = if ShakeRules.isJunk(drop.kind) then ShakeRules.JUNK else ShakeRules.CATCH
	local r2 = rule.radius * rule.radius
	for _, s in samples do
		if s.t >= drop.landAt - rule.early and s.t <= drop.landAt + rule.late then
			local dx, dz = s.x - drop.x, s.z - drop.z
			if dx * dx + dz * dz <= r2 then
				return true
			end
		end
	end
	return false
end

function ShakeRules.passed(score: number): boolean
	return score >= ShakeRules.TARGET
end

-- "win" / "lose" once the run is over at run time `t`, else nil.
function ShakeRules.outcome(score: number, hearts: number, t: number): string?
	if hearts <= 0 or t >= ShakeRules.RUN_SECONDS then
		return if ShakeRules.passed(score) then "win" else "lose"
	end
	return nil
end

return ShakeRules
