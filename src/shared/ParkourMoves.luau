--!strict
--[[
	ParkourMoves: what the Parkour course does to a runner's body, as plain arithmetic (no
	Roblox types), so Client.Fx.Modes applies it and tests/parkour_bugs.luau can run it.

	  Bounce pads  A pad launches on the FIRST frame of every contact, whatever the runner is
	               doing (walking on over its lip, landing on it, standing beside its rim):
	               nothing can refuse a launch, so a contact never passes without one. Contact
	               ends when the feet leave the pad's zone, and the next contact launches again.
	               A launch is then HELD for HOLD_SECONDS: the runner's upward speed is kept
	               at the launch's own arc (power - gravity * elapsed), because the Humanoid
	               answers a launch from the ground with its own jump (50 studs/s) one frame
	               later and that used to replace the pad's power.
	  Sweepers     A bar with a `shove` (map 1) does not bump the runner into the air: it
	               slides them SHOVE studs along the deck over SHOVE_SECONDS, never out of the
	               deck's keep box (Course.shoveKeep), with no upward speed at all.
]]

local Moves = {}

-- A pad is touched this far past its rim, down to PAD_UNDER below the deck it lies on (the
-- feet readout wobbles a little) and up to PAD_OVER above its top.
Moves.PAD_REACH = 0.4
Moves.PAD_UNDER = 0.3
Moves.PAD_OVER = 1.4
-- Seconds a launch's upward speed is held on its arc.
Moves.HOLD_SECONDS = 0.2
-- A held launch is put back on its arc when it is this far (studs/s) under it.
Moves.HOLD_SLACK = 1
-- Seconds a low shove takes.
Moves.SHOVE_SECONDS = 0.2

-- Are feet `flat` studs (horizontally) from a pad's centre and `height` studs above its top
-- touching it? `radius`: the pad's; `lip`: how far its top stands above its deck.
function Moves.onPad(flat: number, height: number, radius: number, lip: number): boolean
	return flat < radius + Moves.PAD_REACH and height > -(lip + Moves.PAD_UNDER) and height < Moves.PAD_OVER
end

-- One frame of a pad's contact. `held`: the runner was touching it last frame. Returns
-- (launch now, the new `held`): a launch on the first frame of every contact, no other
-- condition.
function Moves.padStep(held: boolean, touching: boolean): (boolean, boolean)
	return touching and not held, touching
end

-- The upward speed a runner launched at `power` must still have `elapsed` seconds later, or
-- nil once the hold is over (after HOLD_SECONDS the arc is the runner's own).
function Moves.holdSpeed(power: number, elapsed: number, gravity: number): number?
	if elapsed < 0 or elapsed > Moves.HOLD_SECONDS then
		return nil
	end
	return power - gravity * elapsed
end

-- The upward speed to set on a held launch this frame (nil: leave the runner alone).
-- `speed`: the runner's upward speed now.
function Moves.heldSpeed(speed: number, power: number, elapsed: number, gravity: number): number?
	local want = Moves.holdSpeed(power, elapsed, gravity)
	if want and speed < want - Moves.HOLD_SLACK then
		return want
	end
	return nil
end

export type Keep = { x0: number, x1: number, z0: number, z1: number }

-- The share of a shove done `elapsed` seconds in (0..1, fast first, easing out).
function Moves.shoveShare(elapsed: number): number
	local a = math.clamp(elapsed / Moves.SHOVE_SECONDS, 0, 1)
	return 1 - (1 - a) * (1 - a)
end

local function slide(p: number, d: number, lo: number, hi: number): number
	if d > 0 then
		return math.max(p, math.min(p + d, hi))
	elseif d < 0 then
		return math.min(p, math.max(p + d, lo))
	end
	return p
end

-- Moves the point (x, z) by (dx, dz), stopping at the sides of `keep` (a runner already
-- outside it is not pushed further out, nor pulled back in). Without `keep`: a plain move.
function Moves.shoveTo(x: number, z: number, dx: number, dz: number, keep: Keep?): (number, number)
	if not keep then
		return x + dx, z + dz
	end
	return slide(x, dx, keep.x0, keep.x1), slide(z, dz, keep.z0, keep.z1)
end

return Moves
