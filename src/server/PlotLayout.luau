--!strict
--[[
	PlotLayout: the plot-local geometry shared by WorldBuilder (which builds it)
	and Tycoon (orb landing, crate spawning, pool detection).

	Pure data with no Roblox dependencies so tests/run.luau can check that pads,
	the pool, its ramps and the crate areas never overlap.

	Plot-local axes: Z = toward the back wall, Y = up, and (Roblox being
	right-handed) +X is on your LEFT when you walk in from the hub facing +Z.
	The plot floor's top surface is y = 0; the entrance is at z = -55.

	Top-down as seen walking in (hub at the bottom, +X on the left):

	                  back wall (z = 55)
	  +-------------------------------------------------+
	  | decor     [ display bleachers, 3 rows ]   decor |
	  | TIER  |~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~|  proc+ |
	  |       |ramp>    ORB POOL (sunken)  <ramp|  proc+ |
	  |       |~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~|        |
	  | UNLOCK1   B1   B5   B25   B100   AM      DEPOSIT |
	  | UNLOCK2                                          |
	  |  odds    crates    (MERGE)    crates    COLLECT  |
	  |  FREE                                            |
	  | decor          [ entrance arch ]          decor |
	  +-------------------------------------------------+
	 x = +55                                      x = -55
]]

export type Rect = { minX: number, maxX: number, minZ: number, maxZ: number }
export type PadSpot = { x: number, z: number, sizeX: number, sizeZ: number, round: boolean? }

local Layout = {}

Layout.PLOT_HALF = 55
-- Inner faces of the wall pillars: nothing should be built past this.
Layout.INNER_HALF = 52.5

-- The sunken orb pool, directly in front of the display bleachers.
Layout.POOL = { minX = -29, maxX = 29, minZ = 3, maxZ = 29 } :: Rect
Layout.POOL_DEPTH = 4
-- Local Y of the pool floor's walkable surface (orbs rest on it).
Layout.POOL_FLOOR_Y = -Layout.POOL_DEPTH

-- Two walkable ramps inside the pool, one at each end, descending toward the
-- centre (x = 0). They share the pool's centre line on Z.
Layout.RAMP_LENGTH = 11
Layout.RAMP_WIDTH = 10
local poolCenterZ = (Layout.POOL.minZ + Layout.POOL.maxZ) / 2
Layout.POOL_CENTER_Z = poolCenterZ
Layout.RAMPS = {
	{
		side = -1,
		rect = {
			minX = Layout.POOL.minX,
			maxX = Layout.POOL.minX + Layout.RAMP_LENGTH,
			minZ = poolCenterZ - Layout.RAMP_WIDTH / 2,
			maxZ = poolCenterZ + Layout.RAMP_WIDTH / 2,
		} :: Rect,
	},
	{
		side = 1,
		rect = {
			minX = Layout.POOL.maxX - Layout.RAMP_LENGTH,
			maxX = Layout.POOL.maxX,
			minZ = poolCenterZ - Layout.RAMP_WIDTH / 2,
			maxZ = poolCenterZ + Layout.RAMP_WIDTH / 2,
		} :: Rect,
	},
}

-- Where dropped orbs land: the flat pool floor between the ramps.
Layout.ORB_AREA = {
	minX = Layout.POOL.minX + Layout.RAMP_LENGTH + 1.5,
	maxX = Layout.POOL.maxX - Layout.RAMP_LENGTH - 1.5,
	minZ = Layout.POOL.minZ + 2,
	maxZ = Layout.POOL.maxZ - 2,
} :: Rect

-- Floor crates spawn on the main floor either side of the merge pad.
Layout.CHEST_AREAS = {
	{ minX = -28, maxX = -12, minZ = -40, maxZ = -16 } :: Rect,
	{ minX = 12, maxX = 28, minZ = -40, maxZ = -16 } :: Rect,
}

-- Display bleachers: three stepped rows of ten slots behind the pool.
Layout.SHELF = {
	width = 74,
	rows = 3,
	cols = 10,
	spacing = 7,
	firstZ = 34,
	rowDepth = 6.5,
	firstTop = 1.5,
	rowRise = 5,
}

Layout.SPAWN = { x = 0, z = -44 }

-- A pad's base + bevel reach this far past its glowing top on every side.
Layout.PAD_RIM = 1.5

-- Pad tops (the trigger area). Order is the build order.
Layout.PAD_ORDER = {
	"Buy1",
	"Buy5",
	"Buy25",
	"Buy100",
	"AutoMerge",
	"Merge",
	"Deposit",
	"ProcUp1",
	"ProcUp10",
	"Collect",
	"BuyTier",
	"Unlock1",
	"Unlock2",
	"Free",
}
Layout.PADS = {
	-- Buy row in front of the pool, reading left to right for a player walking in.
	Buy1 = { x = 25, z = -6, sizeX = 8.5, sizeZ = 6.5 },
	Buy5 = { x = 12.5, z = -6, sizeX = 8.5, sizeZ = 6.5 },
	Buy25 = { x = 0, z = -6, sizeX = 8.5, sizeZ = 6.5 },
	Buy100 = { x = -12.5, z = -6, sizeX = 8.5, sizeZ = 6.5 },
	AutoMerge = { x = -25, z = -6, sizeX = 8.5, sizeZ = 6.5 },
	Merge = { x = 0, z = -20, sizeX = 12, sizeZ = 12, round = true },
	-- -X side (right when walking in): deposit -> process upgrades -> collect.
	Deposit = { x = -39, z = 0, sizeX = 9, sizeZ = 9 },
	ProcUp1 = { x = -41, z = 13, sizeX = 8, sizeZ = 6 },
	ProcUp10 = { x = -41, z = 23, sizeX = 8, sizeZ = 6 },
	Collect = { x = -40, z = -28, sizeX = 10, sizeZ = 10 },
	-- +X side (left when walking in): buy tier, crate unlockers, free reward.
	BuyTier = { x = 41, z = 18, sizeX = 8, sizeZ = 8 },
	Unlock1 = { x = 40, z = -1, sizeX = 8, sizeZ = 8 },
	Unlock2 = { x = 40, z = -15, sizeX = 8, sizeZ = 8 },
	Free = { x = 40, z = -38, sizeX = 9, sizeZ = 9 },
} :: { [string]: PadSpot }

-- Floor footprints of the big machines (pads and crates must stay clear).
Layout.MACHINES = {
	Converter = { minX = -52.5, maxX = -45.5, minZ = -3.5, maxZ = 3.5 } :: Rect,
	Processor = { minX = -52.5, maxX = -48, minZ = 11, maxZ = 25 } :: Rect,
	Vault = { minX = -52.5, maxX = -47.5, minZ = -31, maxZ = -25 } :: Rect,
	Unlocker1 = { minX = 46.5, maxX = 52.5, minZ = -5.5, maxZ = 3.5 } :: Rect,
	Unlocker2 = { minX = 46.5, maxX = 52.5, minZ = -19.5, maxZ = -10.5 } :: Rect,
	Shelves = { minX = -37, maxX = 37, minZ = 30.75, maxZ = 50.25 } :: Rect,
}

-- Helpers -----------------------------------------------------------------------

function Layout.rect(minX: number, maxX: number, minZ: number, maxZ: number): Rect
	return { minX = minX, maxX = maxX, minZ = minZ, maxZ = maxZ }
end

-- Footprint of a pad's top, grown by `extra` on every side.
function Layout.padRect(spot: PadSpot, extra: number?): Rect
	local e = extra or 0
	return {
		minX = spot.x - spot.sizeX / 2 - e,
		maxX = spot.x + spot.sizeX / 2 + e,
		minZ = spot.z - spot.sizeZ / 2 - e,
		maxZ = spot.z + spot.sizeZ / 2 + e,
	}
end

function Layout.contains(r: Rect, x: number, z: number, margin: number?): boolean
	local m = margin or 0
	return x >= r.minX - m and x <= r.maxX + m and z >= r.minZ - m and z <= r.maxZ + m
end

-- True when the rectangles overlap (touching edges do not count).
function Layout.overlaps(a: Rect, b: Rect, margin: number?): boolean
	local m = margin or 0
	return a.minX < b.maxX + m and b.minX < a.maxX + m and a.minZ < b.maxZ + m and b.minZ < a.maxZ + m
end

-- Is a plot-local point (x, z) over the sunken pool (ramps included)?
-- Tycoon.fastTick does the same test against Plot.pool.
function Layout.inPool(x: number, z: number): boolean
	return Layout.contains(Layout.POOL, x, z)
end

return Layout
