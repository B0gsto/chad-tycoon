--!strict
-- Pure helpers for the aura orb look, the pen fill rule and the Auto Aura timing, shared by
-- the client orb visuals (Fx/Orbs), the server (Tycoon) and the unit tests.
--
--   * Every orb is the same size. Its paint comes from the unit tier that produced it:
--     tierIndex(tier, n) picks one of the n Theme.OrbColors, cycling so neighbouring tiers differ.
--   * feedTarget(balls, tier, cap, roll): the pen fill rule. Below the cap every produced orb is
--     a new ball; at the cap it joins an existing ball (same tier first, then the lowest count).
--   * tagRGB(r, g, b): text colour of a ball's "xN" tag (a lightened ball colour, white if pale).
--   * travelTime(length, queue): a conservative upper bound of how long the client's roll-in
--     animation takes for a route of `length` studs (hop + fall + gutter/chute roll that
--     accelerates from 6 to 18 studs/s + floor bounces), plus the chute queue wait.

local OrbLook = {}

OrbLook.CAP = 64 -- balls a pen holds before new orbs count up existing balls
OrbLook.SETTLE = 1.2 -- seconds an orb rests in the pen before Auto Aura collects it

-- Palette slot (1..n) for orbs produced by a unit of `tier` (tier 1 = slot 1).
function OrbLook.tierIndex(tier: number?, n: number): number
	local t = math.max(1, math.floor(tier or 1))
	return (t - 1) % math.max(1, n) + 1
end

function OrbLook.tierColor<T>(tier: number?, palette: { T }): T
	return palette[OrbLook.tierIndex(tier, #palette)]
end

export type Ball = { tier: number, count: number }

-- Where a newly produced orb of `tier` goes when the pen holds `balls`: nil means it lands as a
-- new ball (the pen is below `cap`); otherwise the index of the ball it joins. Balls of the same
-- tier are preferred, then the lowest count; `roll` (0..1, optional) breaks ties so the counts
-- spread over the pen instead of piling onto one ball.
function OrbLook.feedTarget(balls: { Ball }, tier: number?, cap: number, roll: number?): number?
	if #balls < cap or #balls == 0 then
		return nil
	end
	local t = tier or 1
	local sameTier = false
	for _, ball in balls do
		if ball.tier == t then
			sameTier = true
			break
		end
	end
	local lowest = math.huge
	for _, ball in balls do
		if (not sameTier or ball.tier == t) and ball.count < lowest then
			lowest = ball.count
		end
	end
	local ties = {}
	for i, ball in balls do
		if (not sameTier or ball.tier == t) and ball.count == lowest then
			table.insert(ties, i)
		end
	end
	local k = math.clamp(math.floor((roll or 0) * #ties) + 1, 1, #ties)
	return ties[k]
end

-- sRGB 0-255 of the "xN" tag text for a ball painted (r, g, b): the colour lifted halfway to
-- white so it reads on the ball, or plain white when the ball is already pale.
function OrbLook.tagRGB(r: number, g: number, b: number): (number, number, number)
	local luma = (0.299 * r + 0.587 * g + 0.114 * b) / 255
	if luma > 0.78 then
		return 255, 255, 255
	end
	local function lift(c: number): number
		return math.floor(c + (255 - c) * 0.5 + 0.5)
	end
	return lift(r), lift(g), lift(b)
end

-- Slowest roll the client uses: starts at 6 studs/s, accelerates at 14 up to 18.
local V0, ACCEL, VMAX = 6, 14, 18
local HOP_FALL = 0.45 + 0.7
local LANDING = 0.26 + 0.16 + 1.2 -- two bounces + the longest floor glide

function OrbLook.travelTime(length: number, queue: number?): number
	local reachT = (VMAX - V0) / ACCEL
	local reachD = V0 * reachT + 0.5 * ACCEL * reachT * reachT
	local roll
	if length <= reachD then
		roll = (-V0 + math.sqrt(V0 * V0 + 2 * ACCEL * math.max(0, length))) / ACCEL
	else
		roll = reachT + (length - reachD) / VMAX
	end
	return HOP_FALL + roll + LANDING + math.clamp(queue or 0, 0, 2.5)
end

-- Seconds from spawn until Auto Aura collects the orb: lands, rests SETTLE, capped at 12 s.
function OrbLook.autoCollectDelay(length: number, queue: number?): number
	return math.min(OrbLook.travelTime(length, queue) + OrbLook.SETTLE, 12)
end

-- Tank credit for a set of collected orb values. Walking over orbs and Auto Aura both credit
-- through this, so the same orbs are worth exactly the same either way.
function OrbLook.credit(values: { number }): number
	local sum = 0
	for _, v in values do
		sum += v
	end
	return sum
end

return OrbLook
