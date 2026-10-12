--[[
	MogLayout: pure layout numbers of the MOG STAGE (no Roblox APIs), shared by
	World.MogStage (builds it) and Modes.Mog (teleports, spots, "still on the stage" checks).

	The stage is a round floating disc out at sea, north (+Z) of the island (the island's
	shallows end ~286 studs from the origin; the ocean top is at y = -1.2), reached only by teleport.
	CENTER is the middle of the stage's top surface. SPOTS duel spots sit evenly around it on
	radial lines: the player's pad near the rim faces inward to the rival's pad DUEL studs
	closer to the centre. A central tower carries the MOG TEST sign above everyone's heads.
]]

local MogLayout = {}

MogLayout.CENTER = { x = 0, y = 6, z = 400 }
MogLayout.RADIUS = 46
-- Stage disc thickness (the top is CENTER.y) and the pad height above the stage top.
MogLayout.THICKNESS = 3
MogLayout.PAD_HEIGHT = 0.4
MogLayout.PAD_RADIUS = 3.2
MogLayout.SPOT_COUNT = 6
-- Radius of the player pads and the player-to-rival distance.
MogLayout.PLAYER_RING = 33
MogLayout.DUEL = 14
-- The rope ring's posts sit on this radius; the central tower is this wide.
MogLayout.POST_RING = 43.5
MogLayout.TOWER_RADIUS = 5
-- Sea level (the ocean top) for the pontoon floats and foam.
MogLayout.SEA_Y = -1.2
-- The TOP MOGGERS board sits at this angle (between spots 1 and 2), facing the centre.
MogLayout.BOARD_ANGLE = math.pi / MogLayout.SPOT_COUNT
MogLayout.BOARD_RING = 40

export type Point = { x: number, y: number, z: number }
export type Spot = { index: number, angle: number, player: Point, rival: Point, faceX: number, faceZ: number }

-- Angle of spot `index` around the centre (0 = +Z, counter-clockwise seen from above).
function MogLayout.angle(index: number): number
	return (index - 1) * 2 * math.pi / MogLayout.SPOT_COUNT
end

-- A point at radius `r` along `angle`, at height `y`.
function MogLayout.at(angle: number, r: number, y: number): Point
	local c = MogLayout.CENTER
	return { x = c.x + math.sin(angle) * r, y = y, z = c.z + math.cos(angle) * r }
end

local spots: { Spot } = {}
for i = 1, MogLayout.SPOT_COUNT do
	local a = MogLayout.angle(i)
	local feetY = MogLayout.CENTER.y + MogLayout.PAD_HEIGHT
	table.insert(spots, {
		index = i,
		angle = a,
		player = MogLayout.at(a, MogLayout.PLAYER_RING, feetY),
		rival = MogLayout.at(a, MogLayout.PLAYER_RING - MogLayout.DUEL, feetY),
		-- Player faces the rival (inward).
		faceX = -math.sin(a),
		faceZ = -math.cos(a),
	})
end
MogLayout.SPOTS = spots

-- Is (x, z) over the stage (with a little slack past the rim)?
function MogLayout.onStage(x: number, z: number): boolean
	local c = MogLayout.CENTER
	local dx, dz = x - c.x, z - c.z
	local r = MogLayout.RADIUS + 4
	return dx * dx + dz * dz <= r * r
end

return MogLayout
