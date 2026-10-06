--[[
	Pen: the walled orb pen in front of the display ledge, its two side stairs, the gutter
	along the foot of the ledge and the chute that feeds the pen. All geometry comes from
	PlotLayout (PEN, POOL, PEN_STAIRS, GUTTER, CHUTE).

	Look: a light aqua floor (so orbs and crates pop) inside teal padded walls with cream caps,
	chunky teal corner posts topped by sunny round caps, a butter lip along the front, teal step
	blocks with cream edges, and a gutter and chute in one solid sunny yellow (butter round rail
	tops) so the slope reads against the teal and sand.
	Part of the world generator; see Server.WorldBuilder for the overview and plot axes.
]]

local Layout = require(script.Parent.Parent.PlotLayout)
local Common = require(script.Parent.Common)

type Builder = Common.Builder

local theme = Common.theme
local WHITE = Common.WHITE
local UPRIGHT = Common.UPRIGHT

local Pen = {}

local function worldColor(key: string, fallback: Color3): Color3
	local palette = theme.World
	return if palette and palette[key] then palette[key] else fallback
end

-- Purely decorative: never blocks the player, orbs or the camera.
local function decorative(p: BasePart): BasePart
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	return p
end

-- The frame of a slope whose top surface runs from `from` to `to` along one horizontal axis
-- (X when the z's match, otherwise Z), centred on that surface line. Returns the frame and
-- whether the run is along X.
local function slopeFrame(B: Builder, from: Vector3, to: Vector3): (CFrame, boolean, number)
	local mid = (from + to) / 2
	local delta = to - from
	local alongX = math.abs(delta.X) >= math.abs(delta.Z)
	local tilt = if alongX
		-- Angles(0, 0, a) turns the part's X axis to (cos a, sin a, 0).
		then CFrame.Angles(0, 0, math.atan2(delta.Y, delta.X))
		-- Angles(a, 0, 0) turns the part's Z axis to (0, -sin a, cos a).
		else CFrame.Angles(-math.atan2(delta.Y, delta.Z), 0, 0)
	return B.L(mid.X, mid.Y, mid.Z) * tilt, alongX, delta.Magnitude
end

-- A slab whose top surface runs from `from` to `to`, `width` across it and `thick` deep.
local function slope(B: Builder, name: string, from: Vector3, to: Vector3, width: number, thick: number, color: Color3): BasePart
	local frame, alongX, length = slopeFrame(B, from, to)
	return B.P({
		Name = name,
		Size = if alongX then Vector3.new(length, thick, width) else Vector3.new(width, thick, length),
		CFrame = frame * CFrame.new(0, -thick / 2, 0),
		Color = color,
	})
end

-- A round rod whose axis runs from `from` to `to`.
local function rod(B: Builder, name: string, from: Vector3, to: Vector3, diameter: number, color: Color3): BasePart
	local frame, alongX, length = slopeFrame(B, from, to)
	-- A cylinder's axis is its X axis; along Z, turn it a quarter about Y.
	return B.P({
		Name = name,
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(length, diameter, diameter),
		CFrame = if alongX then frame else frame * CFrame.Angles(0, math.pi / 2, 0),
		Color = color,
	})
end

local function buildWallsAndFloor(B: Builder): BasePart
	local L, P = B.L, B.P
	local pen = Layout.PEN
	local inner = pen.interior
	local outer = Layout.POOL
	local h, t = pen.wallHeight, pen.wallThick
	local cx = (inner.minX + inner.maxX) / 2
	local cz = (inner.minZ + inner.maxZ) / 2
	local w = inner.maxX - inner.minX
	local d = inner.maxZ - inner.minZ
	local wallColor = worldColor("Teal", B.c.WallTrim)
	local capColor = worldColor("Cream", WHITE)
	local topColor = worldColor("Sunny", B.c.Primary)
	local capH = 0.38

	local field = P({
		Name = "Field",
		Size = Vector3.new(w, 0.5, d),
		CFrame = L(cx, pen.floorY - 0.25, cz),
		Color = worldColor("Pool", B.c.Floor),
	})

	-- Padded walls: front and back span the full outer width; the sides fit between them.
	-- Each wall gets a cap slab a little wider than the wall (the front one is the butter lip).
	local frontZ, backZ = outer.minZ + t / 2, outer.maxZ - t / 2
	local leftX, rightX = outer.maxX - t / 2, outer.minX + t / 2
	for _, z in { frontZ, backZ } do
		P({
			Name = "PenWall",
			Size = Vector3.new(outer.maxX - outer.minX, h, t),
			CFrame = L(cx, h / 2, z),
			Color = wallColor,
		})
		if z == backZ then
			P({
				Name = "PenCap",
				Size = Vector3.new(outer.maxX - outer.minX, capH, t + 0.2),
				CFrame = L(cx, h - capH / 2 + 0.02, z),
				Color = capColor,
			})
		end
	end
	for _, x in { leftX, rightX } do
		P({
			Name = "PenWall",
			Size = Vector3.new(t, h, d),
			CFrame = L(x, h / 2, cz),
			Color = wallColor,
		})
		P({
			Name = "PenCap",
			Size = Vector3.new(t + 0.2, capH, d),
			CFrame = L(x, h - capH / 2 + 0.02, cz),
			Color = capColor,
		})
	end

	local ps = pen.postSize

	-- Chunky square corner posts, a little taller than the walls, each with a round sunny cap.
	for _, x in { leftX, rightX } do
		for _, z in { frontZ, backZ } do
			P({
				Name = "PenPost",
				Size = Vector3.new(ps, pen.postHeight, ps),
				CFrame = L(x, pen.postHeight / 2, z),
				Color = wallColor,
			})
			-- Collar just under the top, flush with the post's teal.
			P({
				Name = "PenPostBand",
				Size = Vector3.new(ps + 0.12, capH, ps + 0.12),
				CFrame = L(x, pen.postHeight - capH / 2 - 0.12, z),
				Color = wallColor,
			})
			P({
				Name = "PenPostCap",
				Shape = Enum.PartType.Cylinder,
				Size = Vector3.new(0.42, ps + 0.2, ps + 0.2),
				CFrame = L(x, pen.postHeight + 0.21, z) * UPRIGHT,
				Color = topColor,
			})
			decorative(P({
				Name = "PenPostKnob",
				Shape = Enum.PartType.Ball,
				Size = Vector3.new(1.3, 1.3, 1.3),
				CFrame = L(x, pen.postHeight + 0.42 + 0.5, z),
				Color = topColor,
			}))
		end
	end

	-- One warm butter lip capping the front wall between the posts.
	local lipStart = rightX + ps / 2
	local lipEnd = leftX - ps / 2
	decorative(P({
		Name = "PenLip",
		Size = Vector3.new(lipEnd - lipStart, capH, t + 0.2),
		CFrame = L((lipStart + lipEnd) / 2, h - capH / 2 + 0.02, frontZ),
		Color = worldColor("Butter", B.c.Secondary),
	}))
	return field
end

-- Walkable stairs over both side walls: three teal step blocks outside, one inside, each with
-- a cream edge strip along its open edge.
local function buildStairs(B: Builder)
	local stepColor = worldColor("Teal", B.c.WallTrim)
	local edgeColor = worldColor("Cream", WHITE)
	local wallInner = Layout.PEN.interior.maxX
	for _, stair in Layout.PEN_STAIRS do
		local side = stair.side
		for _, step in stair.steps do
			local r = step.rect
			local depth = r.maxZ - r.minZ
			B.P({
				Name = "PenStep",
				Size = Vector3.new(r.maxX - r.minX, step.top, depth),
				CFrame = B.L((r.minX + r.maxX) / 2, step.top / 2, (r.minZ + r.maxZ) / 2),
				Color = stepColor,
			})
			-- The open edge: away from the wall for outside steps, toward the pen for the inside one.
			local inside = math.abs((r.minX + r.maxX) / 2) < wallInner
			local edgeX = if inside
				then (if side > 0 then r.minX + 0.18 else r.maxX - 0.18)
				else (if side > 0 then r.maxX - 0.18 else r.minX + 0.18)
			decorative(B.P({
				Name = "PenStepEdge",
				Size = Vector3.new(0.36, 0.14, depth + 0.04),
				CFrame = B.L(edgeX, step.top - 0.05, (r.minZ + r.maxZ) / 2),
				Color = edgeColor,
			}))
		end
	end
end

-- The gutter at the foot of the ledge (draining to x = 0) and the slide-like chute into the pen.
local function buildGutterAndChute(B: Builder)
	local L, P = B.L, B.P
	local g = Layout.GUTTER
	local ch = Layout.CHUTE
	local r = g.rect
	local depth = r.maxZ - r.minZ
	-- One solid sunny yellow for the whole run so the slope reads; butter round rail tops.
	local slideColor = worldColor("Sunny", B.c.Primary)
	local rodColor = worldColor("Butter", B.c.Primary)

	-- Solid base up to the lowest point of the rolling surface.
	local baseTop = g.centerY - 0.3
	P({
		Name = "GutterBase",
		Size = Vector3.new(r.maxX - r.minX, baseTop, depth),
		CFrame = L((r.minX + r.maxX) / 2, baseTop / 2, g.z),
		Color = slideColor,
	})
	-- Sloped bed: each half falls from endY at its end to centerY at x = 0, with a wedge
	-- filling the gap below it.
	for _, side in { -1, 1 } do
		local endX = if side > 0 then r.maxX else r.minX
		slope(B, "GutterBed", Vector3.new(endX, g.endY, g.z), Vector3.new(0, g.centerY, g.z), depth, 0.3, slideColor)
		local fill = g.endY - g.centerY
		B.W({
			Name = "GutterFill",
			Size = Vector3.new(depth, fill, math.abs(endX)),
			-- A wedge's high end is its +Z face: turn it to face the gutter's end.
			CFrame = L(endX / 2, baseTop + fill / 2, g.z) * CFrame.Angles(0, side * math.pi / 2, 0),
			Color = slideColor,
		})
	end
	-- Front lip (with a round butter rail on top), open where the chute leaves.
	local lipTop = g.endY + g.lipHeight
	local lipBottom = baseTop - 0.3
	local gap = ch.width / 2
	for _, side in { -1, 1 } do
		local endX = if side > 0 then r.maxX else r.minX
		local len = math.abs(endX) - gap
		P({
			Name = "GutterLip",
			Size = Vector3.new(len, lipTop - lipBottom, 0.4),
			CFrame = L(side * (gap + len / 2), (lipTop + lipBottom) / 2, r.minZ + 0.2),
			Color = slideColor,
		})
		rod(B, "GutterRail", Vector3.new(side * gap, lipTop, r.minZ + 0.2), Vector3.new(endX, lipTop, r.minZ + 0.2), 0.55, rodColor)
	end
	-- End caps with a round knob.
	for _, side in { -1, 1 } do
		local x = side * (r.maxX - 0.3)
		P({
			Name = "GutterLip",
			Size = Vector3.new(0.6, lipTop, depth),
			CFrame = L(x, lipTop / 2, g.z),
			Color = slideColor,
		})
		decorative(P({
			Name = "GutterKnob",
			Shape = Enum.PartType.Ball,
			Size = Vector3.new(1, 1, 1),
			CFrame = L(x, lipTop + 0.35, r.minZ + 0.3),
			Color = rodColor,
		}))
	end

	-- Chute: a smooth sunny slide bed with raised sunny side walls and butter round rails,
	-- resting on the pen's back wall.
	local top = Vector3.new(ch.x, ch.topY, ch.topZ)
	local bottom = Vector3.new(ch.x, ch.bottomY, ch.bottomZ)
	slope(B, "Chute", top, bottom, ch.width, 0.4, slideColor)
	-- The side walls start at the gutter's front edge so orbs turning into the chute stay clear.
	local railRise = 0.6
	local railStart = bottom:Lerp(top, (r.minZ - ch.bottomZ) / (ch.topZ - ch.bottomZ))
	for _, side in { -1, 1 } do
		local offset = Vector3.new(side * (ch.width / 2 + 0.2), railRise, 0)
		slope(B, "ChuteRail", railStart + offset, bottom + offset, 0.4, railRise + 0.4, slideColor)
		rod(B, "ChuteRailTop", railStart + offset, bottom + offset, 0.5, rodColor)
	end
	-- Support under the chute between the gutter and the pen wall.
	local wallZ = Layout.POOL.maxZ
	local supportDepth = r.minZ - wallZ
	if supportDepth > 0.2 then
		local supportTop = ch.bottomY + (ch.topY - ch.bottomY) * (((wallZ + r.minZ) / 2 - ch.bottomZ) / (ch.topZ - ch.bottomZ)) - 0.5
		P({
			Name = "ChuteSupport",
			Size = Vector3.new(ch.width - 0.6, supportTop, supportDepth),
			CFrame = L(ch.x, supportTop / 2, (wallZ + r.minZ) / 2),
			Color = worldColor("Teal", B.c.WallTrim),
		})
	end
end

-- Builds the pen, its stairs, the gutter and the chute. Returns the pen floor ("Field").
function Pen.build(B: Builder): BasePart
	local field = buildWallsAndFloor(B)
	buildStairs(B)
	buildGutterAndChute(B)
	return field
end

return Pen
