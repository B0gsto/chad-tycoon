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
--   * Jump presses: UserInputService.JumpRequest fires every frame while jump is held, so a
--     request is a new press only when none came in the PRESS_GAP seconds before it (newPress).
--   * Bench press: one jump press is one rep. A rep takes REP_TIME seconds, the bar going down
--     to the chest and back up to arms' length, where it rests until the next one (press). A
--     press during a rep waits behind it (up to REP_QUEUE of them) and reps with presses
--     waiting play faster, down to REP_FAST seconds (repTime), so mashing loses no press
--     (repStep). The server counts a rep at most every REP_GAP seconds, with one rep of slack
--     (repAllowed).

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

-- Jump presses ----------------------------------------------------------------------------

Rules.PRESS_GAP = 0.12 -- seconds without a JumpRequest before the next one is a new press

-- True when a JumpRequest at `now` is a new press; `last` is when the previous request came.
function Rules.newPress(last: number?, now: number): boolean
	return last == nil or now - last > Rules.PRESS_GAP
end

-- Bench press ------------------------------------------------------------------------------

Rules.REP_TIME = 0.45
Rules.REP_FAST = 0.16 -- seconds a rep takes at the least, with presses waiting behind it
Rules.REP_QUEUE = 6 -- presses that wait behind the rep being played, at the most
Rules.REP_GAP = Rules.REP_FAST * 0.8 -- seconds between two reps the server counts
local REP_DOWN = 0.45 -- share of a rep spent lowering the bar

-- Seconds a rep takes with `queued` presses waiting behind it: mashing speeds the reps up.
function Rules.repTime(queued: number): number
	return math.max(Rules.REP_FAST, Rules.REP_TIME / (1 + math.max(0, queued)))
end

-- How far the bar is pushed out `t` seconds into a rep of `length` seconds (REP_TIME when
-- left out): 1 = arms straight, 0 = on the chest. Before and after the rep it rests at arms'
-- length.
function Rules.press(t: number, length: number?): number
	local u = t / (length or Rules.REP_TIME)
	if u <= 0 or u >= 1 then
		return 1
	elseif u < REP_DOWN then
		return 1 - smooth(u / REP_DOWN)
	end
	return smooth((u - REP_DOWN) / (1 - REP_DOWN))
end

-- One step of a lifter's rep queue. `at` is when the rep being played started (nil while the
-- bar rests), `length` how long that rep takes, `queued` how many presses wait behind it and
-- `pressed` whether a press came at `now`. Returns the new `at`, `length` and `queued`, and
-- whether a rep started on this step. A waiting press starts its rep the moment the one
-- before it ends, so spamming keeps the rhythm; a press beyond REP_QUEUE is dropped.
function Rules.repStep(at: number?, length: number, queued: number, now: number, pressed: boolean): (number?, number, number, boolean)
	if pressed then
		queued = math.min(queued + 1, Rules.REP_QUEUE)
	end
	local from: number? = nil
	if at == nil then
		from = now
	elseif now - at >= length then
		-- Back to back, unless a stalled frame left the queue more than a rep behind.
		from = if now - at >= 2 * length then now else at + length
		at = nil
	end
	if from and queued > 0 then
		queued -= 1
		return from, Rules.repTime(queued), queued, true
	end
	return at, length, queued, false
end

-- The server's limit on counted reps: `nextAt` is when the lifter's next rep may come (nil
-- before the first). Returns whether a rep at `now` counts and the new `nextAt`. One rep
-- every REP_GAP seconds, with one rep of slack so network jitter never eats a fair rep.
function Rules.repAllowed(nextAt: number?, now: number): (boolean, number?)
	if nextAt and now < nextAt then
		return false, nextAt
	end
	return true, math.max(nextAt or -math.huge, now - Rules.REP_GAP) + Rules.REP_GAP
end

return Rules
