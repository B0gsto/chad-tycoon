--[[
	Shell: a plot's ground, boundary and entrance, plus the cream sign cards its boards use.
	The orb pen is built by World.Pen. Part of the world generator; see Server.WorldBuilder for
	the overview and plot axes.

	- Ground: a warm honey-sand floor with teal rubber mats under the work areas (the cream
	  path from the entrance to the pen is built by World.Decor).
	- Boundary: low fences of cream panels on teal kick rails and posts under sunny caps, with
	  chunky teal corner posts. Behind the unit display stands a low stage wall in the calm
	  Backdrop teal between two teal towers; the rack above it stands free against the sky.
	  Neighbouring plots stay in view.
	- Entrance: a teal arch with a sunny beam and awning carrying the owner card.

	Sign cards (`card`, `standingCard`) share Common.SIGN: a cream card with a thin teal border on
	a teal edge, a red-orange header band with a white title, and Ink body text. They fade out
	beyond Common.SIGN_FADE_CARD studs.

	Everything above knee height is decorative and camera-safe (no collision, CanQuery = false),
	so the camera never pops in against it. Only the low fence panels and the floor collide.
]]

local Layout = require(script.Parent.Parent.PlotLayout)
local Common = require(script.Parent.Common)

type Builder = Common.Builder
type Rect = Common.Rect

local theme = Common.theme
local World = theme.World
local SIGN = Common.SIGN
local PLOT_HALF = Common.PLOT_HALF
local UPRIGHT = Common.UPRIGHT
local ALONG_Z = Common.ALONG_Z

local Shell = {}

-- Centre line of the fences, between the inner faces (Layout.INNER_HALF) and the plot edge.
local FENCE_LINE = PLOT_HALF - 0.8
-- Target length of one fence panel between posts.
local FENCE_SEGMENT = 10
-- Arch pillars stand either side of the walkway at this |x|.
local ARCH_X = 8.2

-- Decorative part: never collides and never pulls the camera in (Poppercam ignores
-- CanQuery = false parts).
local function soft(p: BasePart): BasePart
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	return p
end

-- Sign cards ------------------------------------------------------------------------

local CARD_PPS = 32

-- A sign label: heavy Ink text, scaled to fit, unstroked. `Outline = true` adds an Ink outline
-- for the few labels whose colour Server.Tycoon sets live (rarity, cash green, white), so they
-- stay readable on the cream card.
local function text(parent: Instance, props: { [string]: any }): TextLabel
	local l = Instance.new("TextLabel")
	l.BackgroundTransparency = 1
	l.TextScaled = true
	l.Font = theme.Fonts.UI
	l.TextColor3 = SIGN.Text
	l.Size = UDim2.fromScale(1, 0.3)
	for key, value in props do
		if key ~= "Outline" then
			(l :: any)[key] = value
		end
	end
	if props.Outline then
		local s = Instance.new("UIStroke")
		s.Color = World.Ink
		s.Thickness = 2.5
		s.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
		s.Parent = l
	end
	l.Parent = parent
	return l
end

local function corner(parent: Instance, px: number)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, px)
	c.Parent = parent
end

-- A sign card at `cframe` (its front, -Z, carries the sign): a teal slab holding a rounded
-- cream card with a thin teal border and a rounded red-orange header band carrying `title` in
-- white. `headerFrac` is the header's share of the height. Returns the card part, the body
-- frame below the header (lay labels out in its scale space) and the header's title label.
local function card(B: Builder, cframe: CFrame, size: Vector2, title: string, headerFrac: number?): (BasePart, Frame, TextLabel)
	local part = soft(B.P({
		Name = "SignCard",
		Size = Vector3.new(size.X, size.Y, 0.4),
		CFrame = cframe,
		Color = SIGN.Border,
	}))
	local gui = Instance.new("SurfaceGui")
	gui.Face = Enum.NormalId.Front
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = CARD_PPS
	gui.LightInfluence = 0.5
	gui.MaxDistance = Common.SIGN_FADE_CARD
	gui.Parent = part
	local inset = math.floor(CARD_PPS * 0.25)
	local face = Instance.new("Frame")
	face.Name = "Card"
	face.Position = UDim2.fromOffset(inset, inset)
	face.Size = UDim2.new(1, -inset * 2, 1, -inset * 2)
	face.BackgroundColor3 = SIGN.Card
	face.BorderSizePixel = 0
	face.Parent = gui
	corner(face, math.floor(CARD_PPS * 0.6))
	local border = Instance.new("UIStroke")
	border.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	border.Color = SIGN.Border
	border.Thickness = 4
	border.Parent = face
	local frac = headerFrac or 0.24
	local pad = inset
	local header = Instance.new("Frame")
	header.Name = "Header"
	header.Position = UDim2.fromOffset(pad, pad)
	header.Size = UDim2.new(1, -pad * 2, frac, -pad)
	header.BackgroundColor3 = SIGN.Header
	header.BorderSizePixel = 0
	header.Parent = face
	corner(header, math.floor(CARD_PPS * 0.45))
	local titleLabel = text(header, {
		Name = "Title",
		Text = title,
		Font = theme.Fonts.Display,
		TextColor3 = SIGN.Title,
		Size = UDim2.fromScale(0.92, 0.78),
		Position = UDim2.fromScale(0.04, 0.12),
	})
	local body = Instance.new("Frame")
	body.Name = "Body"
	body.BackgroundTransparency = 1
	body.Position = UDim2.new(0, pad, frac, pad)
	body.Size = UDim2.new(1, -pad * 2, 1 - frac, -pad * 2)
	body.Parent = face
	return part, body, titleLabel
end

-- A freestanding sign card on two teal legs, standing on the floor at (x, z), its face turned
-- by `yaw` (0 faces the entrance, -Z) with its bottom edge at `bottomY`. `feet` adds round
-- sunny feet (leave them off where the legs stand against a machine).
local function standingCard(
	B: Builder,
	x: number,
	z: number,
	yaw: number,
	size: Vector2,
	bottomY: number,
	title: string,
	feet: boolean?
): (Frame, TextLabel)
	local base = B.L(x, 0, z) * CFrame.Angles(0, yaw, 0)
	local centerY = bottomY + size.Y / 2
	local _, body, titleLabel = card(B, base * CFrame.new(0, centerY, 0), size, title)
	for _, dx in { -1, 1 } do
		local lx = dx * (size.X / 2 - 0.8)
		soft(B.P({
			Name = "SignLeg",
			Shape = Enum.PartType.Cylinder,
			Size = Vector3.new(centerY, 0.7, 0.7),
			CFrame = base * CFrame.new(lx, centerY / 2, 0.45) * UPRIGHT,
			Color = World.Teal,
		}))
		if feet ~= false then
			soft(B.P({
				Name = "SignFoot",
				Shape = Enum.PartType.Cylinder,
				Size = Vector3.new(0.4, 1.5, 1.5),
				CFrame = base * CFrame.new(lx, 0.2, 0.45) * UPRIGHT,
				Color = World.Sunny,
			}))
		end
	end
	return body, titleLabel
end

-- Ground ------------------------------------------------------------------------

-- A flat floor decal (mat, border) whose top surface is at `top`.
local function floorPiece(B: Builder, name: string, r: Rect, top: number, thick: number, color: Color3): BasePart
	local p = soft(B.P({
		Name = name,
		Size = Vector3.new(r.maxX - r.minX, thick, r.maxZ - r.minZ),
		CFrame = B.L((r.minX + r.maxX) / 2, top - thick / 2, (r.minZ + r.maxZ) / 2),
		Color = color,
	}))
	p.CastShadow = false
	return p
end

-- Floor slab and the path-stone border band. The courts, paths and mats painted on it are
-- World.Decor's (each paint layer has its own height above this band).
local function buildFloor(B: Builder)
	B.P({
		Name = "Floor",
		Size = Vector3.new(PLOT_HALF * 2, 1, PLOT_HALF * 2),
		CFrame = B.L(0, -0.5, 0),
		Color = World.Honey,
	})

	-- A light path-stone band along the fences.
	local inner = Layout.INNER_HALF
	local band = 1.6
	floorPiece(B, "FloorBorder", Layout.rect(-PLOT_HALF, PLOT_HALF, inner - band, PLOT_HALF), 0.04, 0.04, World.Path)
	floorPiece(B, "FloorBorder", Layout.rect(-PLOT_HALF, PLOT_HALF, -PLOT_HALF, -inner + band), 0.04, 0.04, World.Path)
	for _, side in { -1, 1 } do
		local x0, x1 = side * (inner - band), side * PLOT_HALF
		floorPiece(B, "FloorBorder", Layout.rect(math.min(x0, x1), math.max(x0, x1), -inner + band, inner - band), 0.04, 0.04, World.Path)
	end
end

-- A teal round post with a sunny ball knob on top.
local function roundPost(B: Builder, name: string, x: number, z: number, height: number, diameter: number)
	soft(B.P({
		Name = name,
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(height, diameter, diameter),
		CFrame = B.L(x, height / 2, z) * UPRIGHT,
		Color = World.Teal,
	}))
	local knob = diameter + 0.2
	soft(B.P({
		Name = name .. "Knob",
		Shape = Enum.PartType.Ball,
		Size = Vector3.new(knob, knob, knob),
		CFrame = B.L(x, height + knob * 0.3, z),
		Color = World.Sunny,
	}))
end

-- One straight run of fence from (x0, z0) to (x1, z1) along X or Z: a teal kick rail, cream
-- panels (the only colliding parts, 3.1 high) under rounded sunny caps, and small teal round
-- posts between panels.
local function fenceRun(B: Builder, x0: number, z0: number, x1: number, z1: number)
	local alongZ = math.abs(z1 - z0) > math.abs(x1 - x0)
	local length = if alongZ then math.abs(z1 - z0) else math.abs(x1 - x0)
	-- Run-local frame: X runs along the fence.
	local base = B.L((x0 + x1) / 2, 0, (z0 + z1) / 2) * (if alongZ then CFrame.Angles(0, math.pi / 2, 0) else CFrame.identity)
	local segments = math.max(1, math.floor(length / FENCE_SEGMENT + 0.5))
	local seg = length / segments
	soft(B.P({
		Name = "FenceBase",
		Size = Vector3.new(length, 0.5, 1.6),
		CFrame = base * CFrame.new(0, 0.25, 0),
		Color = World.Teal,
	}))
	for i = 0, segments - 1 do
		local cx = -length / 2 + seg * (i + 0.5)
		B.P({
			Name = "FencePanel",
			Size = Vector3.new(seg, 2.6, 1),
			CFrame = base * CFrame.new(cx, 1.8, 0),
			Color = World.Cream,
		})
		soft(B.P({
			Name = "FenceCap",
			Shape = Enum.PartType.Cylinder,
			Size = Vector3.new(seg - 0.6, 1.3, 1.3),
			CFrame = base * CFrame.new(cx, 3.35, 0),
			Color = World.Sunny,
		}))
		if i > 0 then
			local p = base * CFrame.new(-length / 2 + seg * i, 0, 0)
			soft(B.P({
				Name = "FencePost",
				Shape = Enum.PartType.Cylinder,
				Size = Vector3.new(3.8, 1.6, 1.6),
				CFrame = p * CFrame.new(0, 1.9, 0) * UPRIGHT,
				Color = World.Teal,
			}))
			soft(B.P({
				Name = "FenceKnob",
				Shape = Enum.PartType.Ball,
				Size = Vector3.new(1.5, 1.5, 1.5),
				CFrame = p * CFrame.new(0, 4.1, 0),
				Color = World.Sunny,
			}))
		end
	end
end

-- Behind the display rack: a low stage wall in the calm Backdrop teal, about as tall as the
-- first two shelves, under a round cream cap and between two teal towers. The rack above it
-- stands free against the sky, so from outside the plot it reads as an object, not a
-- billboard; its own topper sign names the display. Returns the towers' |x|.
local function buildStage(B: Builder): number
	local L, P = B.L, B.P
	local shelves = Layout.MACHINES.Shelves
	local half = shelves.maxX + 1.8
	local z = Layout.INNER_HALF + 0.1
	local height = math.floor(Layout.rowTop(3))
	-- No shadow: it would fall across the lower shelves.
	local backdrop = soft(P({
		Name = "Backdrop",
		Size = Vector3.new(half * 2, height, 0.6),
		CFrame = L(0, height / 2, z),
		Color = World.Backdrop,
	}))
	backdrop.CastShadow = false
	local cap = 1.6
	soft(P({
		Name = "BackdropCap",
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(half * 2, cap, cap),
		CFrame = L(0, height + cap * 0.3, z),
		Color = World.Cream,
	})).CastShadow =
		false
	-- Towers either side, a little taller than the wall.
	local towerX = half + 1.8
	for _, side in { -1, 1 } do
		roundPost(B, "StageTower", side * towerX, z + 0.3, height + 3, 3.6)
	end
	-- Invisible low collider closing the back between the towers (the backdrop lets the camera
	-- through).
	local back = P({
		Name = "StageFence",
		Size = Vector3.new(towerX * 2, 3.1, 1),
		CFrame = L(0, 1.55, FENCE_LINE),
		Transparency = 1,
	})
	back.CastShadow = false
	return towerX
end

-- Fences around the plot: the sides, the back either side of the stage, and the front either
-- side of the entrance arch, with chunky teal posts at the corners.
local function buildWalls(B: Builder)
	local towerX = buildStage(B)
	local f = FENCE_LINE
	for _, side in { 1, -1 } do
		fenceRun(B, side * f, -f, side * f, f)
		fenceRun(B, side * towerX, f, side * f, f)
		fenceRun(B, side * ARCH_X, -f, side * f, -f)
		for _, z in { -f, f } do
			roundPost(B, "CornerPost", side * f, z, 5.2, 3.2)
		end
	end
end

-- The entrance arch: teal pillars on teal plinths, a sunny beam and a sunny awning with a
-- scalloped edge, and the owner card on top. Returns the owner label and avatar image that
-- Tycoon updates.
local function buildEntrance(B: Builder, index: number): (TextLabel, ImageLabel)
	local L, P = B.L, B.P
	local z = FENCE_LINE
	local pillarH = 11
	for _, side in { -1, 1 } do
		soft(P({
			Name = "ArchPlinth",
			Shape = Enum.PartType.Cylinder,
			Size = Vector3.new(1, 4.4, 4.4),
			CFrame = L(side * ARCH_X, 0.5, -z) * UPRIGHT,
			Color = World.Teal,
		}))
		roundPost(B, "ArchPillar", side * ARCH_X, -z, pillarH, 3.2)
	end
	-- Beam between the pillar tops.
	soft(P({
		Name = "ArchBeam",
		Size = Vector3.new(ARCH_X * 2, 1.4, 1.8),
		CFrame = L(0, pillarH - 0.7, -z),
		Color = World.Sunny,
	}))
	-- Awning sloping down toward the hub, with half-disc scallops along its edge.
	local scallops = 9
	local awningHalf = ARCH_X + 1.7
	local w = awningHalf * 2 / scallops
	local backZ, backY = -z - 0.9, pillarH + 0.4
	local frontZ, frontY = -z - 4.2, pillarH - 1.2
	local dy, dz = backY - frontY, backZ - frontZ
	local length = math.sqrt(dy * dy + dz * dz)
	local tilt = CFrame.Angles(-math.atan2(dy, dz), 0, 0)
	soft(P({
		Name = "Awning",
		Size = Vector3.new(awningHalf * 2, 0.3, length),
		CFrame = L(0, (backY + frontY) / 2, (backZ + frontZ) / 2) * tilt,
		Color = World.Sunny,
	}))
	for i = 1, scallops do
		soft(P({
			Name = "AwningScallop",
			Shape = Enum.PartType.Cylinder,
			Size = Vector3.new(0.3, w, w),
			CFrame = L(-awningHalf + w * (i - 0.5), frontY, frontZ) * ALONG_Z,
			Color = World.Sunny,
		}))
	end

	-- Owner card above the awning: "PLOT n" header, avatar on the left, owner name on the right.
	local size = Vector2.new(12, 4.8)
	local ownerCard, body = card(B, L(0, pillarH + 0.2 + size.Y / 2, -z), size, "PLOT " .. index, 0.3)
	local ownerImage = Instance.new("ImageLabel")
	ownerImage.Name = "OwnerImage"
	ownerImage.BackgroundTransparency = 1
	ownerImage.Size = UDim2.fromScale(0.24, 0.94)
	ownerImage.Position = UDim2.fromScale(0.01, 0.03)
	ownerImage.ScaleType = Enum.ScaleType.Fit
	ownerImage.Image = ""
	ownerImage.Parent = body
	local ownerLabel = text(body, {
		Name = "Owner",
		Text = "EMPTY PLOT",
		Font = theme.Fonts.Display,
		Size = UDim2.fromScale(0.72, 0.8),
		Position = UDim2.fromScale(0.27, 0.1),
	})
	-- The card's teal back (seen from inside the plot) shows the plot number in white.
	local backGui = Instance.new("SurfaceGui")
	backGui.Face = Enum.NormalId.Back
	backGui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	backGui.PixelsPerStud = 24
	backGui.LightInfluence = 0.5
	backGui.MaxDistance = Common.SIGN_FADE_CARD
	backGui.Parent = ownerCard
	text(backGui, {
		Text = "PLOT " .. index,
		Font = theme.Fonts.Display,
		TextColor3 = World.White,
		Size = UDim2.fromScale(0.8, 0.6),
		Position = UDim2.fromScale(0.1, 0.2),
	})
	return ownerLabel, ownerImage
end

Shell.soft = soft
Shell.text = text
Shell.card = card
Shell.standingCard = standingCard
Shell.buildFloor = buildFloor
Shell.buildWalls = buildWalls
Shell.buildEntrance = buildEntrance

return Shell
