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
	A drop is caught when the player's tray (judgePoint) stood within the catch radius of its
	landing spot at some moment of the window around the land time (caught; the window covers the
	server's view of a moving player arriving a little late). Junk uses a smaller radius and
	a tighter window, so near misses never cost a heart.
	The run is passed with TARGET points: when the clock runs out, or when the hearts run out
	after the target was already reached (outcome). Out of hearts below the target: "lose".

	A visit goes lobby -> countdown (READY_SECONDS) -> play -> results (RESULTS_SECONDS) ->
	lobby (docs/minigames.md "Lobby first"): canBegin, onPad and padStep decide the START pad
	and the "ShakeBegin" action. Root samples are only trusted at a walkable speed (plausible,
	trust), so a teleporting or speed-hacked character cannot sweep the court; catches are
	judged at the tray in front of the root (judgePoint). A pass earns 1 to 3 stars (STARS);
	new star tiers pay a small bonus (starBonus).

	ARENA is where World.ShakeArena builds the arena (floor top centre of the 64 x 64 catch
	court and the size in studs of everything walkable round it: the court, the lobby deck past
	its +Z edge, the bleachers past +X and the Smoothie Bar past -Z), out over the sea away
	from the Parkour maps, the Mog stage and the Cardio track; tests/minigames.luau keeps every
	arena clear of the others.
]]

local ShakeRules = {}

ShakeRules.ARENA = { x = 7000, y = 6, z = -7000, sizeX = 96, sizeZ = 164 }
-- Feet more than this far under the floor top: the player fell off and goes back to the spawn.
ShakeRules.FALL_BELOW = 20

ShakeRules.RUN_SECONDS = 60
ShakeRules.HEARTS = 3
ShakeRules.TARGET = 25
-- The countdown: seconds between "ShakeBegin" and the first wave (the HUD counts 3, 2, 1).
ShakeRules.READY_SECONDS = 3
-- A pass inside the reward cooldown pays the repeat share at most this often (seconds).
ShakeRules.REPEAT_GAP = 120

-- Catch radius and window (seconds before / after the land time) for good items and junk.
ShakeRules.CATCH = { radius = 4.5, early = 0.3, late = 0.3 }
-- Junk is judged a touch late (the server sees a dodging player where they were a moment ago).
ShakeRules.JUNK = { radius = 3, early = 0, late = 0.2 }
-- The exit pad (World.ShakeArena: under the EXIT arch on the lobby deck's +X side, past the
-- court's +Z edge) and how far from it no drop may land, so chasing a drop never walks the
-- player out of a run.
ShakeRules.EXIT = { x = ShakeRules.ARENA.x + 26, z = ShakeRules.ARENA.z + 61 }
ShakeRules.EXIT_CLEAR = 10
-- The server sees a player's position this late: about half the round trip plus a frame of
-- replication (lagOf). Samples are stamped back by it so dodges count when they happened.
ShakeRules.LAG_MAX = 0.4
-- A drop is judged this long after it lands (the longest `late`), once every sample is in.
ShakeRules.SETTLE = 0.3

-- Results card time before the player is put back in the lobby (seconds).
ShakeRules.RESULTS_SECONDS = 6
-- The START pad only fires after the feet were off it this long (seconds), so a player
-- landing on or walking back onto it is never restarted at once.
ShakeRules.PAD_REARM = 1
-- Feet this far (studs, up or down) from the pad's top still count as standing on it.
ShakeRules.PAD_HEIGHT = 4

-- Speed check for root samples: a sample is trusted when it lies within
-- MAX_WALK * SPEED_SLACK * dt + SPEED_PAD studs (flat) of the trust anchor, which moves to a
-- trusted sample at most every ANCHOR_EVERY seconds (trust). MAX_WALK is a server constant (the
-- base WalkSpeed with Speedy Sneakers), never the live Humanoid.WalkSpeed. An implausible
-- sample is dropped (it catches nothing) and the anchor stays put: as `dt` grows the allowed
-- circle grows with it, so a fling or a lag spike is trusted again once the new spot could
-- have been walked to from the last trusted one, and a teleport never re-anchors at once.
ShakeRules.BASE_WALK = 16
ShakeRules.MAX_WALK = 21
ShakeRules.SPEED_SLACK = 1.5
ShakeRules.SPEED_PAD = 2
ShakeRules.ANCHOR_EVERY = 0.5

-- Catches are judged at the tray, not the root: TRAY_AHEAD studs in front of the root along
-- its flat look direction (judgePoint). Fx.Shake draws the reach ring there and predicts
-- catches from the same point.
ShakeRules.TRAY_AHEAD = 2

-- Star tiers: STARS[i] points earn star i (STARS[1] is the TARGET, the pass). Each tier past
-- the first pays STAR_SHARE[i] of the repeat cash (Economy.MODE_REPEAT_SHARE of the pack) the
-- first time it is reached in STAR_COOLDOWN seconds (starBonus), on top of the pass pay, so
-- the star bonus adds at most sum(STAR_SHARE) x repeatCash per STAR_COOLDOWN (well within
-- 2 x repeatCash in any 5 minutes).
ShakeRules.STARS = { ShakeRules.TARGET, 40, 55 }
ShakeRules.STAR_SHARE = { 0, 0.5, 1 }
ShakeRules.STAR_COOLDOWN = 1800

-- Fair drops: two items landing within FAIR.time seconds of each other, one good and one
-- junk (or any two at the same moment), land at least FAIR.gap studs apart, so catching a
-- good item never forces a heart and a double is a real choice.
ShakeRules.FAIR = { time = 0.8, gap = ShakeRules.CATCH.radius + ShakeRules.JUNK.radius + 1.5 }

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

-- `v` folded back inside [lo, hi] (a point past an edge bounces back in instead of piling
-- up on the edge).
function ShakeRules.reflect(v: number, lo: number, hi: number): number
	if v < lo then
		v = lo + (lo - v)
	elseif v > hi then
		v = hi - (v - hi)
	end
	return math.clamp(v, lo, hi)
end

-- True when a drop of `kind` landing at (x, z) at `landAt` keeps FAIR spacing from `drops`
-- (in land order; only the last FAIR.time seconds are looked at).
function ShakeRules.fair(drops: { Drop }, kind: Kind, x: number, z: number, landAt: number): boolean
	local junk = ShakeRules.isJunk(kind)
	local gap2 = ShakeRules.FAIR.gap * ShakeRules.FAIR.gap
	for i = #drops, 1, -1 do
		local o = drops[i]
		local dt = math.abs(landAt - o.landAt)
		if dt > ShakeRules.FAIR.time then
			break
		end
		if dt < 1e-6 or ShakeRules.isJunk(o.kind) ~= junk then
			local dx, dz = x - o.x, z - o.z
			if dx * dx + dz * dz < gap2 then
				return false
			end
		end
	end
	return true
end

-- Every drop of a run, in land order, from its seed. Landing spots stay inside `area`, at
-- least EXIT_CLEAR studs from `avoid` (default EXIT) and FAIR from each other; the action
-- wanders round the court (each drop within a wave's `reach` of the last, leaning back to
-- the middle); the last items land by RUN_SECONDS.
function ShakeRules.schedule(seed: number, area: Area, avoid: { x: number, z: number }?): { Drop }
	local rand = ShakeRules.rng(seed)
	local exit = avoid or ShakeRules.EXIT
	local drops: { Drop } = {}
	local mx, mz = (area.x0 + area.x1) / 2, (area.z0 + area.z1) / 2
	local cx, cz = mx, mz
	local function place(reach: number, kind: Kind, landAt: number): (number?, number?)
		-- Lean a quarter of the way back to the middle so the action never hugs a wall.
		local ox, oz = cx + (mx - cx) * 0.25, cz + (mz - cz) * 0.25
		for _ = 1, 8 do
			local angle = rand() * math.pi * 2
			local dist = reach * (0.35 + 0.65 * rand())
			local x = ShakeRules.reflect(ox + math.cos(angle) * dist, area.x0, area.x1)
			local z = ShakeRules.reflect(oz + math.sin(angle) * dist, area.z0, area.z1)
			x, z = ShakeRules.keepClear(x, z, area, exit, ShakeRules.EXIT_CLEAR)
			if ShakeRules.fair(drops, kind, x, z, landAt) then
				return x, z
			end
		end
		-- No fair spot: this drop is skipped.
		return nil, nil
	end
	for index, wave in ShakeRules.WAVES do
		local nextWave = ShakeRules.WAVES[index + 1]
		local stop = if nextWave then nextWave.from else ShakeRules.RUN_SECONDS
		local t = wave.from + (if index == 1 then 0.4 else 0)
		while t + wave.fall <= stop do
			local count = if rand() < wave.double then 2 else 1
			for n = 1, count do
				local kind = ShakeRules.pick(wave, rand(), rand())
				local landAt = t + wave.fall
				local x, z = place(wave.reach, kind, landAt)
				if x and z then
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
						landAt = landAt,
					})
				end
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

-- True when one of `samples` (run time `t`, judge point x / z) taken within [landAt - early,
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

-- Lobby phases. "ShakeBegin" (or the START pad) starts a run from the lobby or the results.
export type Phase = string -- "lobby" | "countdown" | "play" | "results"
function ShakeRules.canBegin(phase: Phase?): boolean
	return phase == "lobby" or phase == "results"
end

-- Where a fall puts the player back in `phase`: the lobby spawn in the lobby and on the
-- results card (which then ends), the court spawn during the countdown and play.
function ShakeRules.fallTo(phase: Phase?): string
	return if phase == "countdown" or phase == "play" then "court" else "lobby"
end

-- True when feet at (x, y, z) stand on a pad whose top centre is `pad` (within `radius`
-- studs flat and PAD_HEIGHT up or down).
function ShakeRules.onPad(x: number, y: number, z: number, pad: { x: number, y: number, z: number }, radius: number): boolean
	local dx, dz = x - pad.x, z - pad.z
	return dx * dx + dz * dz <= radius * radius and math.abs(y - pad.y) <= ShakeRules.PAD_HEIGHT
end

-- One START-pad tick at time `now`: `offSince` is when the feet were last seen stepping off
-- the pad (nil right after arriving in the lobby: they must step off first). Returns whether
-- the run begins and the new offSince.
function ShakeRules.padStep(onPad: boolean, offSince: number?, now: number): (boolean, number?)
	if not onPad then
		return false, offSince or now
	end
	if offSince and now - offSince >= ShakeRules.PAD_REARM then
		return true, nil
	end
	-- On the pad too early: the re-arm starts over once they step off.
	return false, nil
end

-- True when a root `dist` studs (flat) from the trust anchor `dt` seconds later could have
-- walked there (at MAX_WALK, with SPEED_SLACK and SPEED_PAD).
function ShakeRules.plausible(dist: number, dt: number): boolean
	if dist ~= dist or dt ~= dt then
		return false
	end
	return dist <= ShakeRules.MAX_WALK * ShakeRules.SPEED_SLACK * math.max(dt, 0) + ShakeRules.SPEED_PAD
end

export type Anchor = { at: number, x: number, z: number }

-- One root sample at (x, z), server time `now`, against the trust anchor (nil: none yet, the
-- first sample anchors). Returns whether the sample is trusted and the anchor to keep.
function ShakeRules.trust(anchor: Anchor?, x: number, z: number, now: number): (boolean, Anchor?)
	if x ~= x or z ~= z then
		return false, anchor
	end
	if not anchor then
		return true, { at = now, x = x, z = z }
	end
	local dx, dz = x - anchor.x, z - anchor.z
	local dt = now - anchor.at
	if not ShakeRules.plausible(math.sqrt(dx * dx + dz * dz), dt) then
		return false, anchor
	end
	if dt >= ShakeRules.ANCHOR_EVERY then
		return true, { at = now, x = x, z = z }
	end
	return true, anchor
end

-- The point catches are judged at for a root at (x, z) looking along (lookX, lookZ) (any
-- length; a vertical look judges at the root).
function ShakeRules.judgePoint(x: number, z: number, lookX: number, lookZ: number): (number, number)
	local len = math.sqrt(lookX * lookX + lookZ * lookZ)
	if len < 1e-3 or len ~= len then
		return x, z
	end
	return x + lookX / len * ShakeRules.TRAY_AHEAD, z + lookZ / len * ShakeRules.TRAY_AHEAD
end

-- Stars (0 to #STARS) a score earns.
function ShakeRules.stars(score: number): number
	local n = 0
	for i, need in ShakeRules.STARS do
		if score >= need then
			n = i
		end
	end
	return n
end

-- True when star tier `i` (last paid at os.time `paidAt`, nil: never) pays again at `now`.
function ShakeRules.starReady(paidAt: number?, now: number): boolean
	return type(paidAt) ~= "number" or paidAt > now or now - paidAt >= ShakeRules.STAR_COOLDOWN
end

-- The star bonus for a pass with `score`: the cash (each tier the score reached that pays and
-- is ready, STAR_SHARE of `repeatCash`) and the tiers it pays (the caller stamps them `now`).
-- `paidAt[i]`: when tier i last paid (os.time; nil: never).
function ShakeRules.starBonus(score: number, repeatCash: number, paidAt: { [number]: number? }, now: number): (number, { number })
	local cash, tiers = 0, {}
	if not ShakeRules.passed(score) or repeatCash ~= repeatCash or repeatCash <= 0 then
		return 0, tiers
	end
	for i = 1, ShakeRules.stars(score) do
		local bonus = math.floor(repeatCash * ShakeRules.STAR_SHARE[i])
		if bonus > 0 and ShakeRules.starReady(paidAt[i], now) then
			cash += bonus
			table.insert(tiers, i)
		end
	end
	return cash, tiers
end

-- "win" / "lose" once the run is over at run time `t`, else nil.
function ShakeRules.outcome(score: number, hearts: number, t: number): string?
	if hearts <= 0 or t >= ShakeRules.RUN_SECONDS then
		return if ShakeRules.passed(score) then "win" else "lose"
	end
	return nil
end

return ShakeRules
