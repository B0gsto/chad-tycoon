--!strict
--[[
	PlotLayout: the plot-local geometry shared by WorldBuilder (which builds it)
	and Tycoon (orb and crate routes, pen detection).

	Pure data with no Roblox dependencies so tests/run.luau can check that pads,
	the pen, its stairs, the gutter/chute, machines and fan zones never overlap,
	that crates land in the front of the pen and that the walkway from the entrance stays clear.

	Plot-local axes: Z = toward the back fence, Y = up, and (Roblox being
	right-handed) +X is on your LEFT when you walk in from the hub facing +Z.
	The plot floor's top surface is y = 0; the entrance is at z = -42.

	Units stand on a tall display rack along the back: up to 10 shelves stacked
	upward, each a little behind the one below, one model per unit (100 slots;
	only the shelves the owner's units need are shown). Their orbs drop off the
	front of the rack into a gutter at its foot (it drains to x = 0), roll down a
	short chute over the pen's back wall and pile up in the walled PEN. Crates
	take the same route: a Chad drops one, it slides down the gutter and chute
	and lands in the front half of the pen. The pen floor is at ground level;
	stairs climb over its side walls.

	Side view of the rack (+Z to the right, entrance on the left):

	        y ~ 65 |   [roof + sign]       shelf n+1 would sit here
	               |   ||=====|  shelf 3   (each shelf: board, rim, band,
	               |  ||=====|   shelf 2    back panel, side posts)
	   y = 3.8   ~~|=====| (*)   shelf 1, (*) = champion pedestal at x = 0
	   gutter    \_/   z = 24 ->  1.1 studs further back per shelf, 6 up

	Top-down as seen walking in (hub at the bottom, +X on the left). Every group of pads stands on
	its own painted court (COURTS): the buy row on one long court across the back, either side of
	the pen; the crate stations down the +X court; the aura -> cash stations down the -X court, each
	machine right behind its own pad(s). A cream path runs from the entrance to the round merge
	court and branches along the pen's front (PLAZA) to both side courts; the main loop is
	pen -> merge -> deposit -> collect. The front fence holds the gym dressing and the interactive
	props (INTERACTIVE), each on its own round mat:

	                       back fence (z = 42)
	  +---------------------------------------------------------+
	  | fans  [ display rack: 10 shelves, 100 slots ]     fans  |
	  | fans  [~~~~~~~~~~ gutter -> (x = 0) <- ~~~~~~~~~] fans  |
	  |,--------------------- chute ---------------------------.|
	  |: TIER  B1   B5   #===== PEN =====#   B25  B100  AUTO    :|  buy court
	  |`-----------------#               #---------------------'|
	  | ,--------------. #               # ,------------------. |
	  | :crk> UNLOCK1  :_|# (orbs pile) #|_:  PROC^10  <proc  : |
	  | :              : #   [crates]    # :  PROC^1   <proc  : |
	  | :palm          : #===============# :            palm  : |
	  | :              :=====( MERGE )=====: [ DEPOSIT ] <conv: |  plaza
	  | :crk> UNLOCK2  :      |walk|       :                  : |
	  | :water         :      |way |       :           water  : |
	  | :gift  FREE    :      |    |       :  COLLECT  <vault : |
	  | `--------------'      |    |       `------------------' |
	  | (tramp)  (bag)  palm  |    |  palm  [bench]  (podium)   |
	  |                  [ entrance arch ]                      |
	  +---------------------------------------------------------+
	 x = +42                                                x = -42
]]

export type Rect = { minX: number, maxX: number, minZ: number, maxZ: number }
export type PadSpot = { x: number, z: number, sizeX: number, sizeZ: number, round: boolean? }
export type Point = { x: number, y: number, z: number }
export type Step = { rect: Rect, top: number }
export type Stair = { side: number, rect: Rect, steps: { Step } }
export type FanZone = { rect: Rect, side: number }
export type FanSpot = { x: number, z: number, faceX: number, faceZ: number }

local Layout = {}

local function rect(minX: number, maxX: number, minZ: number, maxZ: number): Rect
	return { minX = minX, maxX = maxX, minZ = minZ, maxZ = maxZ }
end

Layout.PLOT_HALF = 42
-- Inner faces of the fences: nothing should be built past this.
Layout.INNER_HALF = 40

-- Radius of the orbs Tycoon places (ORB_SIZE / 2); orb paths are orb-centre positions.
Layout.ORB_RADIUS = 0.8

-- The walled orb pen, at ground level, directly in front of the display ledge.
-- `interior` is the open floor inside the walls; the walls sit around it.
local PEN_INTERIOR = rect(-10, 10, 2, 18)
local PEN_WALL_THICK = 1.6
Layout.PEN = {
	interior = PEN_INTERIOR,
	wallHeight = 1.6,
	wallThick = PEN_WALL_THICK,
	-- Square corner posts, a little taller than the walls.
	postSize = 2.4,
	postHeight = 2.2,
	-- Top of the pen floor part ("Field"); it sits just above the plot floor.
	floorY = 0.15,
}

-- The pen's footprint, walls included ("pool" in Tycoon and Plot).
Layout.POOL = rect(
	PEN_INTERIOR.minX - PEN_WALL_THICK,
	PEN_INTERIOR.maxX + PEN_WALL_THICK,
	PEN_INTERIOR.minZ - PEN_WALL_THICK,
	PEN_INTERIOR.maxZ + PEN_WALL_THICK
)
-- Local Y of the pen floor's walkable surface (orbs rest on it).
Layout.POOL_FLOOR_Y = Layout.PEN.floorY
Layout.POOL_CENTER_Z = (PEN_INTERIOR.minZ + PEN_INTERIOR.maxZ) / 2

-- Stairs over the pen's side walls, one on each side (+X = left when walking in), at the
-- front half of the wall. Each has three outer steps (the last one level with the wall top)
-- and one inner step down to the pen floor. `rect` covers the outer steps only.
Layout.STAIR_RUN = 1.2
Layout.STAIR_WIDTH = 4
local STAIR_Z = 5.5
Layout.PEN_STAIRS = {} :: { Stair }
for _, side in { 1, -1 } do
	local wallOuter = side * Layout.POOL.maxX
	local wallInner = side * PEN_INTERIOR.maxX
	local z0, z1 = STAIR_Z - Layout.STAIR_WIDTH / 2, STAIR_Z + Layout.STAIR_WIDTH / 2
	local steps: { Step } = {}
	for i = 1, 3 do
		-- Step i is the i-th from the outside; step 3 touches the wall.
		local far = wallOuter + side * (4 - i) * Layout.STAIR_RUN
		local near = wallOuter + side * (3 - i) * Layout.STAIR_RUN
		table.insert(steps, {
			rect = rect(math.min(far, near), math.max(far, near), z0, z1),
			top = Layout.PEN.wallHeight * i / 3,
		})
	end
	local innerEdge = wallInner - side * Layout.STAIR_RUN
	table.insert(steps, {
		rect = rect(math.min(wallInner, innerEdge), math.max(wallInner, innerEdge), z0, z1),
		top = Layout.PEN.wallHeight / 2,
	})
	local outerEdge = wallOuter + side * 3 * Layout.STAIR_RUN
	table.insert(Layout.PEN_STAIRS, {
		side = side,
		rect = rect(math.min(wallOuter, outerEdge), math.max(wallOuter, outerEdge), z0, z1),
		steps = steps,
	})
end

-- Where dropped orbs land: the pen floor, clear of the walls and the inner stair steps.
Layout.ORB_AREA = rect(
	PEN_INTERIOR.minX + Layout.STAIR_RUN + 0.6,
	PEN_INTERIOR.maxX - Layout.STAIR_RUN - 0.6,
	PEN_INTERIOR.minZ + 1,
	PEN_INTERIOR.maxZ - 1
)

-- Display rack: Economy.DISPLAY_ROWS shelves stacked up the back of the ledge, 100 slots.
-- Odd shelves hold 11 units and even ones 9 (10 on average) so every shelf is centred on
-- x = 0 and the front shelf's centre slot is the raised "best unit" pedestal (slot 1).
-- Each shelf stands stepBack further back and rowRise higher than the one below, like steep
-- bleachers. Shelf models are display-scaled to at most unitMaxHeight tall (displayScale)
-- so every unit fits under the shelf above: rowRise = standY + unitMaxHeight + headroom +
-- boardThick (the front shelf gets championRise extra for the pedestal).
Layout.SHELF = {
	-- Between the side posts' inner faces; the posts stand postWidth outside it.
	width = 58,
	postWidth = 1.6,
	rows = 10,
	rowCols = { 11, 9, 11, 9, 11, 9, 11, 9, 11, 9 },
	-- Centre-to-centre distance of neighbouring units on a shelf (all shelves share the grid).
	spacing = 5.3,
	-- Front edge of the front shelf (the gutter's back edge) and every shelf board's depth.
	frontZ = 24,
	depth = 4,
	stepBack = 1.1,
	-- Centre Z of the front shelf (where its units stand).
	firstZ = 26,
	-- Deck top of the front shelf; each shelf above is rowRise higher (see rowTop).
	firstTop = 3.8,
	rowRise = 6,
	boardThick = 0.7,
	headroom = 0.3,
	-- Standing height above a shelf's deck top.
	standY = 0,
	-- Extra height of the best-unit pedestal (slot 1).
	championRise = 1.3,
	-- Tallest a unit is shown on the rack (studs); taller tiers are scaled down to this.
	unitMaxHeight = 5,
	-- How far a shelf's rim and front band stick out past its front edge.
	frontReach = 0.3,
}
local SHELF_FRONT_Z = Layout.SHELF.frontZ

-- Deck top (y) of shelf `row`; row = rows + 1 is the rack's roof.
function Layout.rowTop(row: number): number
	local s = Layout.SHELF
	return s.firstTop + (row - 1) * s.rowRise + (if row > 1 then s.championRise else 0)
end

-- Front edge (z) of shelf `row`; the shelf is SHELF.depth deep behind it.
function Layout.rowFrontZ(row: number): number
	local s = Layout.SHELF
	return s.frontZ + (row - 1) * s.stepBack
end

-- Shelves needed to show `unitCount` units (at least one, at most SHELF.rows).
function Layout.rackRows(unitCount: number): number
	local s = Layout.SHELF
	local room = 0
	for row = 1, s.rows do
		room += s.rowCols[row]
		if unitCount <= room then
			return row
		end
	end
	return s.rows
end

-- Scale applied to a shelf model whose true height is `height` so it fits its shelf (the
-- Index and reward viewports keep true sizes; Tycoon applies this when it builds shelf models).
function Layout.displayScale(height: number): number
	return math.min(1, Layout.SHELF.unitMaxHeight / height)
end

-- The gutter along the foot of the ledge. Its rolling surface (trough bottom) is at endY at
-- both ends and drains to centerY at x = 0; the lips stand lipHeight above the surface.
Layout.GUTTER = {
	rect = rect(-29, 29, SHELF_FRONT_Z - 2.5, SHELF_FRONT_Z),
	-- Centre line of the trough.
	z = SHELF_FRONT_Z - 1.25,
	width = 2.5,
	endY = 3.2,
	centerY = 2.6,
	lipHeight = 0.5,
}

-- The chute from the gutter's centre down over the pen's back wall into the pen. Heights are
-- the rolling surface at each end; the bottom end hangs just inside the back wall.
Layout.CHUTE = {
	x = 0,
	width = 2.4,
	topZ = Layout.GUTTER.z,
	topY = Layout.GUTTER.centerY,
	bottomZ = PEN_INTERIOR.maxZ - 0.8,
	bottomY = 1.9,
	rect = rect(-1.2, 1.2, PEN_INTERIOR.maxZ - 0.8, Layout.GUTTER.z),
}

-- Height of a crate's pivot (the centre of its body) above the surface it rests on.
Layout.CRATE_LIFT = 1.1
-- Clearance from a crate's centre to anything it must not overlap, at any yaw (half the
-- diagonal of its 3.6 x 2.6 lid, rounded up).
Layout.CRATE_RADIUS = 2.3

-- Where dropped crates land (crate centres): the front half of the pen, a crate radius clear
-- of the walls and the inner stair steps, and far from the chute mouth at the back.
Layout.CHEST_AREAS = {
	rect(
		PEN_INTERIOR.minX + Layout.STAIR_RUN + Layout.CRATE_RADIUS,
		PEN_INTERIOR.maxX - Layout.STAIR_RUN - Layout.CRATE_RADIUS,
		PEN_INTERIOR.minZ + Layout.CRATE_RADIUS,
		Layout.POOL_CENTER_Z
	),
}

-- The entrance walkway: kept clear of pads, crates and machines from the entrance to the
-- merge pad, which ends it in front of the pen (Layout.PADS.Merge: 7 + 2 * PAD_RIM wide).
Layout.WALKWAY = rect(-4, 4, -Layout.INNER_HALF, -10.6)

export type ShelfSlot = { x: number, y: number, z: number, row: number, best: boolean }

-- Every display slot in fill order: the bottom shelf first, each shelf centre-out, so the
-- highest tiers (the display fills best-first) stand at eye level and slot 1 is the
-- front-centre champion pedestal. y = the unit's standing height.
function Layout.shelfSlots(): { ShelfSlot }
	local s = Layout.SHELF
	local out: { ShelfSlot } = {}
	for row = 1, s.rows do
		local cols = s.rowCols[row]
		local spacing = s.spacing
		local top = Layout.rowTop(row)
		local z = Layout.rowFrontZ(row) + s.depth / 2
		-- Column indices (1-based, left to right in -X..+X) ordered centre-out.
		local order: { number } = {}
		local mid = (cols + 1) / 2
		if cols % 2 == 1 then
			table.insert(order, mid)
			for k = 1, (cols - 1) / 2 do
				table.insert(order, mid - k)
				table.insert(order, mid + k)
			end
		else
			for k = 0, cols / 2 - 1 do
				table.insert(order, math.floor(mid) - k)
				table.insert(order, math.ceil(mid) + k)
			end
		end
		for _, col in order do
			local best = #out == 0
			table.insert(out, {
				x = -(cols - 1) * spacing / 2 + (col - 1) * spacing,
				y = top + s.standY + (if best then s.championRise else 0),
				z = z,
				row = row,
				best = best,
			})
		end
	end
	return out
end

-- On the walkway, facing the pen: far enough in that the spawn camera (Fx.Camera, about 15
-- studs behind and above) stays inside the entrance arch.
Layout.SPAWN = { x = 0, z = -23 }

-- A pad's thin base reaches this far past its coloured top on every side.
Layout.PAD_RIM = 0.5

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
-- Small pads (4 x 4.2 tops, at least 4 studs on the short side so a walking character fits) with
-- at least 3 studs of open floor between neighbouring bases and 6 between a pad and the pen.
local BUY_Z = 16.5
-- The side courts hold three stations each, mirrored left and right: beside the pen, level with
-- the plaza in front of it, and by the front fence.
local ROW_BACK, ROW_MID, ROW_FRONT = 3.5, -12.5, -26.5
-- The pad column of each side court (the machines stand behind it, toward the fence).
local PAD_X = 26
Layout.PADS = {
	-- One row at the foot of the unit rack, level with the back of the pen, reading BuyTier,
	-- Buy 1, Buy 5, [pen], Buy 25, Buy 100, Auto Merge from the player's left (+X) to right.
	BuyTier = { x = 36.1, z = BUY_Z, sizeX = 4, sizeZ = 4.2 },
	Buy1 = { x = 28.1, z = BUY_Z, sizeX = 4, sizeZ = 4.2 },
	Buy5 = { x = 20.1, z = BUY_Z, sizeX = 4, sizeZ = 4.2 },
	Buy25 = { x = -20.1, z = BUY_Z, sizeX = 4, sizeZ = 4.2 },
	Buy100 = { x = -28.1, z = BUY_Z, sizeX = 4, sizeZ = 4.2 },
	AutoMerge = { x = -36.1, z = BUY_Z, sizeX = 4, sizeZ = 4.2 },
	-- The merge pad closes the walkway, centred a few studs in front of the pen's front wall.
	Merge = { x = 0, z = -6.6, sizeX = 7, sizeZ = 7 },
	-- -X court (right when walking in), back to front: the two process upgrades in front of the
	-- processor, the big deposit pad in front of the converter (first stop after merging) and
	-- collect in front of the vault.
	ProcUp10 = { x = -PAD_X, z = ROW_BACK + 4.4, sizeX = 4, sizeZ = 4.2 },
	ProcUp1 = { x = -PAD_X, z = ROW_BACK - 3.9, sizeX = 4, sizeZ = 4.2 },
	Deposit = { x = -21, z = ROW_MID, sizeX = 13, sizeZ = 9 },
	Collect = { x = -PAD_X, z = ROW_FRONT, sizeX = 4.5, sizeZ = 4.5 },
	-- +X court (left when walking in): a crate cracker pad per station, then the free reward.
	Unlock1 = { x = PAD_X, z = ROW_BACK, sizeX = 4.5, sizeZ = 4.5 },
	Unlock2 = { x = PAD_X, z = ROW_MID, sizeX = 4.5, sizeZ = 4.5 },
	Free = { x = PAD_X, z = ROW_FRONT, sizeX = 4.5, sizeZ = 4.5 },
} :: { [string]: PadSpot }

-- Open floor kept between pads: between neighbouring bases, and from any pad to the pen's
-- walls and stairs (the merge pad, which ends the walkway, sits MERGE_PEN_GAP in front).
Layout.PAD_GAP = 3
Layout.PAD_PEN_GAP = 6
Layout.MERGE_PEN_GAP = 3

-- Floor footprints of the big machines (pads, crates and fans must stay clear). Each stands on
-- its side court right behind its own pad(s), its front toward the plot's centre line; the
-- backs line up MACHINE_BACK from the centre, clear of the fence.
local MACHINE_BACK = 36.5
Layout.MACHINES = {
	Converter = rect(-MACHINE_BACK, -MACHINE_BACK + 7, ROW_MID - 3.5, ROW_MID + 3.5),
	-- The juice bar is a thin counter: it stands half a stud in so its sign board fits behind it.
	Processor = rect(-MACHINE_BACK + 0.5, -MACHINE_BACK + 5, ROW_BACK - 7, ROW_BACK + 7),
	Vault = rect(-MACHINE_BACK, -MACHINE_BACK + 5, ROW_FRONT - 3, ROW_FRONT + 3),
	Unlocker1 = rect(MACHINE_BACK - 6, MACHINE_BACK, ROW_BACK - 4.5, ROW_BACK + 4.5),
	Unlocker2 = rect(MACHINE_BACK - 6, MACHINE_BACK, ROW_MID - 4.5, ROW_MID + 4.5),
	-- The display rack, side posts included.
	Shelves = rect(-Layout.SHELF.width / 2 - Layout.SHELF.postWidth, Layout.SHELF.width / 2 + Layout.SHELF.postWidth, SHELF_FRONT_Z, 39),
}

-- Painted courts (flat floor paint, see World.Decor): one rounded mat per group of pads, in the
-- group's pad colour family with a white border line. The buy court runs across the whole back
-- (the pen stands on its middle); the side courts flank the pen, COURT_INNER off its walls, so
-- the pen stairs land on them. Sand joints separate the courts from each other and the fences.
local COURT_INNER = Layout.POOL.maxX + 1.2
local COURT_OUTER = MACHINE_BACK + 1.1
Layout.COURTS = {
	Buy = rect(-39.4, 39.4, 13.1, 20.9),
	Cash = rect(-COURT_OUTER, -COURT_INNER, -30.9, 11.3),
	Crates = rect(COURT_INNER, COURT_OUTER, -30.9, 11.3),
} :: { [string]: Rect }
-- The pads and machines standing on each court.
Layout.COURT_MEMBERS = {
	Buy = { pads = { "BuyTier", "Buy1", "Buy5", "Buy25", "Buy100", "AutoMerge" }, machines = {} },
	Cash = { pads = { "ProcUp1", "ProcUp10", "Deposit", "Collect" }, machines = { "Processor", "Converter", "Vault" } },
	Crates = { pads = { "Unlock1", "Unlock2", "Free" }, machines = { "Unlocker1", "Unlocker2" } },
} :: { [string]: { pads: { string }, machines: { string } } }
-- The round court under the merge pad (it covers the pad's whole base).
Layout.MERGE_COURT = { x = Layout.PADS.Merge.x, z = Layout.PADS.Merge.z, radius = 6.2 }
-- The cream plaza across the front of the pen: the walkway's crossbar, joining both side courts.
Layout.PLAZA = rect(-COURT_INNER, COURT_INNER, -8.5, Layout.POOL.minZ - 0.9)

-- Interactive props along the front fence, each on its own round mat of `radius` (World.Decor
-- builds them as Interactive_<Kind> models). They keep off the courts and the spawn view.
Layout.INTERACTIVE = {
	Trampoline = { x = 34.4, z = -35.4, radius = 4 },
	PunchBag = { x = 25, z = -35.6, radius = 3.5 },
	FlexPodium = { x = -34.4, z = -35.4, radius = 4 },
} :: { [string]: { x: number, z: number, radius: number } }

-- Where cheering fans stand: the back corners beside the display rack, off every walkway and
-- behind the buy court. `side` is +1 for the +X zone and -1 for the -X zone.
Layout.FAN_ZONES = {
	{ rect = rect(31.5, 39.5, 25, 39), side = 1 },
	{ rect = rect(-39.5, -31.5, 25, 39), side = -1 },
} :: { FanZone }

-- The point fans face: the middle of the display rack's footprint.
Layout.FAN_FOCUS = { x = 0, z = SHELF_FRONT_Z + 7.5 }

-- Fan standing spots in fill order: alternating sides, front-of-ledge and nearest-the-centre
-- first, each with a unit facing direction (faceX, faceZ) toward the display.
function Layout.fanSpots(): { FanSpot }
	local spacing = 3
	local perSide: { { FanSpot } } = {}
	for _, zone in Layout.FAN_ZONES do
		local r = zone.rect
		local list: { FanSpot } = {}
		local cols = math.max(1, math.floor((r.maxX - r.minX) / spacing))
		local rows = math.max(1, math.floor((r.maxZ - r.minZ) / spacing))
		local colGap = (r.maxX - r.minX) / cols
		local rowGap = (r.maxZ - r.minZ) / rows
		-- Columns nearest the centre line first, then rows front to back.
		for ci = 0, cols - 1 do
			local x = if zone.side > 0 then r.minX + colGap * (ci + 0.5) else r.maxX - colGap * (ci + 0.5)
			for ri = 0, rows - 1 do
				local z = r.minZ + rowGap * (ri + 0.5)
				local dx, dz = Layout.FAN_FOCUS.x - x, Layout.FAN_FOCUS.z - z
				local len = math.sqrt(dx * dx + dz * dz)
				table.insert(list, { x = x, z = z, faceX = dx / len, faceZ = dz / len })
			end
		end
		table.insert(perSide, list)
	end
	local out: { FanSpot } = {}
	local i = 1
	while true do
		local added = false
		for _, list in perSide do
			if list[i] then
				table.insert(out, list[i])
				added = true
			end
		end
		if not added then
			break
		end
		i += 1
	end
	return out
end

-- Helpers -----------------------------------------------------------------------

Layout.rect = rect

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

-- Is a plot-local point (x, z) over the pen (walls included)?
-- Tycoon.fastTick does the same test against Plot.pool.
function Layout.inPool(x: number, z: number): boolean
	return Layout.contains(Layout.POOL, x, z)
end

-- Height of the gutter's rolling surface at plot-local x (clamped to the gutter's length).
function Layout.gutterY(x: number): number
	local g = Layout.GUTTER
	local half = (g.rect.maxX - g.rect.minX) / 2
	local t = math.clamp(math.abs(x) / half, 0, 1)
	return g.centerY + (g.endY - g.centerY) * t
end

local slotCache: { ShelfSlot }? = nil

-- Standing height of the display slot nearest to (x, z).
local function feetY(x: number, z: number): number
	local best, bestDist = Layout.SHELF.firstTop + Layout.SHELF.standY, math.huge
	if not slotCache then
		slotCache = Layout.shelfSlots()
	end
	for _, slot in slotCache :: { ShelfSlot } do
		local d = (slot.x - x) ^ 2 + (slot.z - z) ^ 2
		if d < bestDist then
			best, bestDist = slot.y, d
		end
	end
	return best
end

-- Half the length of a crate's lid: how far its body reaches in front of its pivot.
local CRATE_HALF_LENGTH = 1.8

-- Rack -> gutter -> chute -> pen waypoints for something whose centre rides `r` above each
-- surface and reaches `reach` in front of its centre (see orbPath and cratePath). It first
-- moves straight out at its own shelf's height (above every shelf below, whose units stand
-- under that shelf) to a drop point in front of the rack, then falls into the gutter.
local function routeVia(r: number, reach: number, fromX: number, fromZ: number, toX: number, toZ: number, toY: number?): { Point }
	local g = Layout.GUTTER
	local c = Layout.CHUTE
	local gx = math.clamp(fromX, g.rect.minX + g.width / 2, g.rect.maxX - g.width / 2)
	local feet = feetY(fromX, fromZ) + r
	local dropZ = math.min(g.z, SHELF_FRONT_Z - Layout.SHELF.frontReach - reach)
	return {
		{ x = fromX, y = feet, z = fromZ },
		{ x = fromX, y = feet, z = dropZ },
		{ x = gx, y = Layout.gutterY(gx) + r, z = g.z },
		{ x = c.x, y = c.topY + r, z = c.topZ },
		{ x = c.x, y = c.bottomY + r, z = c.bottomZ },
		{ x = toX, y = toY or (Layout.PEN.floorY + r), z = toZ },
	}
end

-- The route an orb takes from a unit's feet to its landing spot in the pen, as orb-centre
-- waypoints (plot-local): unit feet -> drop point in front of the rack at the same height ->
-- gutter below the unit -> chute top -> chute bottom -> landing. Always 6 points; a segment
-- can be zero length (a unit standing over the chute). `toY` is the landing centre height
-- (default: resting on the pen floor).
function Layout.orbPath(fromX: number, fromZ: number, toX: number, toZ: number, toY: number?): { Point }
	return routeVia(Layout.ORB_RADIUS, Layout.ORB_RADIUS, fromX, fromZ, toX, toZ, toY)
end

-- The same route for a crate dropped by the unit at (fromX, fromZ): crate-pivot waypoints
-- (CRATE_LIFT above each surface), unit feet -> drop point -> gutter -> chute top -> chute
-- bottom -> landing (6 points).
function Layout.cratePath(fromX: number, fromZ: number, toX: number, toZ: number, toY: number?): { Point }
	return routeVia(Layout.CRATE_LIFT, CRATE_HALF_LENGTH, fromX, fromZ, toX, toZ, toY)
end

return Layout
