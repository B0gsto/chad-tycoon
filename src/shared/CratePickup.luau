--!strict
-- Pure rules for the automatic crate pickup, shared by the server (Tycoon fast tick), the
-- client crate visuals (Fx/Crates: the "can't" wiggle) and the unit tests.
--
--   * A crate is picked up by walking to it: the plot owner's root within RADIUS studs
--     (horizontal, REACH_Y vertical) of a crate that has landed, while holding no crate.
--   * landTime(length): a conservative upper bound of the client's arrival animation for a
--     route of `length` studs, so a crate is never grabbed in mid-air.
--   * Re-arm: for REARM seconds after a held crate is released (opened, discarded, dropped
--     on a Crate Smasher) nothing is picked up, and crates in range at that moment stay
--     blocked until the player has left their range once.

local CratePickup = {}

CratePickup.RADIUS = 4.5 -- studs, horizontal distance from the crate's centre
CratePickup.REACH_Y = 8 -- studs, vertical tolerance (jumping still picks up)
CratePickup.REARM = 1.5 -- seconds after a release with no automatic pickup
CratePickup.WIGGLE_GAP = 2 -- seconds between "can't" wiggles of one crate (client)

-- Upper bounds of the client's arrival legs (Fx/Crates): pop + hop + fall + gutter bounce,
-- the slide (from 3 studs/s, accelerating at 11 up to 13) and the two pen bounces, plus
-- replication slack.
local FIXED = 0.2 + 0.6 + 0.75 + 0.3 + 0.44 + 0.26 + 0.4
local V0, ACCEL, VMAX = 3, 11, 13

function CratePickup.landTime(length: number): number
	local len = math.max(0, length)
	local reachT = (VMAX - V0) / ACCEL
	local reachD = V0 * reachT + 0.5 * ACCEL * reachT * reachT
	local slide
	if len <= reachD then
		slide = (-V0 + math.sqrt(V0 * V0 + 2 * ACCEL * len)) / ACCEL
	else
		slide = reachT + (len - reachD) / VMAX
	end
	return math.min(FIXED + slide, 10)
end

-- Horizontal + vertical range test for an offset (crate centre minus player root).
function CratePickup.inRange(dx: number, dy: number, dz: number): boolean
	return dx * dx + dz * dz <= CratePickup.RADIUS * CratePickup.RADIUS and math.abs(dy) < CratePickup.REACH_Y
end

export type Check = {
	now: number,
	landsAt: number, -- when the crate has landed (same clock as now)
	inRange: boolean,
	holding: boolean, -- the player already carries a crate
	rearmUntil: number, -- no pickup before this (0 when never released)
	blocked: boolean, -- was in range at the last release and the player has not left it since
}

-- May this crate be picked up automatically right now?
function CratePickup.mayPick(c: Check): boolean
	return c.inRange and not c.holding and not c.blocked and c.now >= c.landsAt and c.now >= c.rearmUntil
end

-- Updated `blocked` flag for one crate this tick: leaving its range clears the block.
function CratePickup.stillBlocked(blocked: boolean, inRange: boolean): boolean
	return blocked and inRange
end

return CratePickup
