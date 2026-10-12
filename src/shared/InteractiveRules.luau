--!strict
-- Pure rules for the plot's interactive gym props (Client.Fx.Interactive plays them; the props
-- themselves are built by World.Decor), shared with the unit tests. Cosmetic only: nothing
-- here touches the economy.
--
--   * Trampoline: a bounce is a jump of BOUNCE_BASE x the normal jump height from standing,
--     + BOUNCE_CHAIN for landing out of a full bounce, + BOUNCE_HOLD while jump is held: 3x to
--     4x in all. A bounce is mostly straight up: it keeps at most BOUNCE_DRIFT studs/s sideways.
--   * Punch bag: at most one hit every HIT_GAP seconds; a hit within COMBO_RESET seconds of
--     the last one grows the combo, else it starts again at 1; MILESTONES get the big text.
--     The bag is a damped pendulum: each hit kicks it (kick), swingStep moves it on.
--   * A punch lasts PUNCH_TIME seconds: punch(t) gives how far the fist is out and how much
--     of the pose shows over the avatar's own animation.
--   * Bench press: a rep takes REP_TIME seconds, from arms out, down to the chest and back up
--     (press); reps(t) counts the finished ones.

local Rules = {}

-- Trampoline -------------------------------------------------------------------------------

Rules.BOUNCE_BASE = 3 -- x the normal jump height, bouncing from a standstill
Rules.BOUNCE_CHAIN = 0.5 -- more for landing at a full bounce's speed
Rules.BOUNCE_HOLD = 0.5 -- more for holding jump
Rules.BOUNCE_GAP = 0.2 -- seconds between two bounces
Rules.BOUNCE_DRIFT = 6 -- studs/s of sideways speed a bounce keeps

-- Take-off speed of a jump that reaches `height` studs under `gravity`.
function Rules.jumpSpeed(gravity: number, height: number): number
	return math.sqrt(2 * math.max(0, gravity) * math.max(0, height))
end

-- How many normal jumps high a bounce goes: `jumpSpeed` is the avatar's normal take-off speed,
-- `landingSpeed` how fast it came down onto the pad (0 when it just stands there).
function Rules.bounceHeight(jumpSpeed: number, landingSpeed: number, holding: boolean): number
	local full = jumpSpeed * math.sqrt(Rules.BOUNCE_BASE)
	local chain = if full > 0 then math.clamp(landingSpeed / full, 0, 1) else 0
	return Rules.BOUNCE_BASE + Rules.BOUNCE_CHAIN * chain + (if holding then Rules.BOUNCE_HOLD else 0)
end

-- Upward speed of that bounce.
function Rules.bounceSpeed(jumpSpeed: number, landingSpeed: number, holding: boolean): number
	return jumpSpeed * math.sqrt(Rules.bounceHeight(jumpSpeed, landingSpeed, holding))
end

-- The sideways velocity (x, z) a bounce keeps.
function Rules.drift(x: number, z: number): (number, number)
	local speed = math.sqrt(x * x + z * z)
	if speed <= Rules.BOUNCE_DRIFT then
		return x, z
	end
	local k = Rules.BOUNCE_DRIFT / speed
	return x * k, z * k
end

-- Punch bag --------------------------------------------------------------------------------

Rules.HIT_GAP = 0.25 -- seconds between two hits (4 a second)
Rules.COMBO_RESET = 2 -- seconds without a hit before the combo starts over
Rules.MILESTONES = { 10, 25, 50 }

function Rules.canHit(lastHit: number?, now: number): boolean
	return lastHit == nil or now - lastHit >= Rules.HIT_GAP
end

-- True while a hit at `now` would still add to the combo.
function Rules.comboAlive(lastHit: number?, now: number): boolean
	return lastHit ~= nil and now - lastHit <= Rules.COMBO_RESET
end

-- The combo after a hit at `now`.
function Rules.combo(combo: number, lastHit: number?, now: number): number
	return if Rules.comboAlive(lastHit, now) then combo + 1 else 1
end

function Rules.milestone(combo: number): boolean
	return table.find(Rules.MILESTONES, combo) ~= nil
end

-- Size of the combo text: it grows a little with the combo and jumps on a milestone.
function Rules.comboScale(combo: number): number
	if Rules.milestone(combo) then
		return 1.8
	end
	return 1 + 0.35 * math.clamp((combo - 1) / 49, 0, 1)
end

-- The bag's swing: an angle (radians, + is away from the puncher) and its speed.
Rules.SWING_MAX = math.rad(34)
local SWING_RATE = 7 -- rad/s: a swing there and back takes about 0.9 s
local SWING_DAMPING = 0.14 -- of critical: settled about 4 s after the last hit
local SWING_STEP = 1 / 120

-- Angular speed one hit adds: a first hit swings the bag about 20 degrees, a long combo more.
function Rules.kick(combo: number): number
	return 2.9 + 1.1 * math.clamp((combo - 1) / 9, 0, 1)
end

-- Moves the swing on by `dt` seconds; the angle never passes SWING_MAX.
function Rules.swingStep(angle: number, speed: number, dt: number): (number, number)
	local left = math.clamp(dt, 0, 0.25)
	while left > 0 do
		local h = math.min(left, SWING_STEP)
		left -= h
		speed += (-SWING_RATE * SWING_RATE * angle - 2 * SWING_DAMPING * SWING_RATE * speed) * h
		angle += speed * h
		if math.abs(angle) > Rules.SWING_MAX then
			angle = math.sign(angle) * Rules.SWING_MAX
			speed = 0
		end
	end
	return angle, speed
end

-- True once a swing is too small to see.
function Rules.swingStill(angle: number, speed: number): boolean
	return math.abs(angle) < math.rad(0.15) and math.abs(speed) < math.rad(1.5)
end

local function smooth(a: number): number
	a = math.clamp(a, 0, 1)
	return a * a * (3 - 2 * a)
end

Rules.PUNCH_TIME = 0.36
local PUNCH_OUT = 0.1 -- seconds from the guard to the fist fully out
local PUNCH_IN = 0.05 -- seconds for the pose to take over
local PUNCH_FADE = 0.16 -- seconds for it to hand back at the end

-- A punch `t` seconds in: reach (0 = on guard, 1 = fist out) and weight (0 = the avatar's own
-- animation, 1 = the punch pose).
function Rules.punch(t: number): (number, number)
	if t < 0 or t >= Rules.PUNCH_TIME then
		return 0, 0
	end
	local reach = smooth(t / PUNCH_OUT)
	local weight = math.min(smooth(t / PUNCH_IN), smooth((Rules.PUNCH_TIME - t) / PUNCH_FADE))
	return reach, weight
end

-- Bench press ------------------------------------------------------------------------------

Rules.REP_TIME = 1.7
local REP_DOWN = 0.55 -- share of a rep spent lowering the bar

-- How far the bar is pushed out `t` seconds after lying down: 1 = arms straight, 0 = on the
-- chest. Every rep lowers it gently and pushes it back up faster.
function Rules.press(t: number): number
	local u = (math.max(0, t) / Rules.REP_TIME) % 1
	if u < REP_DOWN then
		return 1 - smooth(u / REP_DOWN)
	end
	return smooth((u - REP_DOWN) / (1 - REP_DOWN))
end

-- Reps finished `t` seconds after lying down.
function Rules.reps(t: number): number
	return math.floor(math.max(0, t) / Rules.REP_TIME)
end

return Rules
