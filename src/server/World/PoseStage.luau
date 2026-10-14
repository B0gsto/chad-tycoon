--!strict
--[[
	PoseStage: the POSE COPY arena out at sea (teleport-only; Modes.Pose brings players here).
	Numbers live in Modes.PoseRules.ARENA; the shell (floor, spawn pad, exit arch) comes from
	World.Arena. The deck is 104 studs wide: the 56-stud show in the middle, the green-room
	lobby on the +X wing (the shell's EXIT arch lands in its +Z corner) and a TV-crew corner on
	the -X wing. A sunny edge band and a chunky pink-and-white railing run round the deck, with
	a foam ring on the water round it. Its own sea surrounds it (World.Hub's ocean ends ~3000
	studs from the hub): ocean tiles, a lagoon with bobbing buoys, three big palm islets close
	in (placed to read from the stage and lobby views), far islands, sandbars and clouds.

	A sunny posing show at the deck's -Z end: a raised stage with a sky-blue back wall and a
	"POSE COPY" banner, two podiums side by side (the rival's "CHAD" on the left, the
	player's "YOU" on the right as the audience sees them), both chads facing the audience
	(+Z, toward the spawn). Over them a D-pad of four "FlexLamp<i>" tiles in the flexes'
	colours (PoseRules.FLEXES; Fx.Pose lights the one being shown), "PodiumGlow" rings that
	Fx.Pose tints, two spotlight towers, a pink runway from the spawn to the stage steps and
	a judges' table on the left (three seated judges holding "10" paddles). The backdrop is an
	opaque LED wall (blue under a navy top band, a few neon stars, a light bar of coloured cans)
	framed by red curtains; confetti cannons sit in drums on the deck's front corners. The
	audience area is a blue checker carpet behind a low barrier with pink "FAN ZONE" plates, a
	start mark round the spawn
	pad and two cushioned bleachers of blocky fans waving foam fingers. Every sign faces the
	audience (+Z: SurfaceGui Face Back).

	The green room (lobby, mint carpet in a hot-pink border, a low candy kerb along the fan
	zone): at its -Z end, flat-on to the lobby spawn, the YOUR BEST board (SurfaceGui
	"BestBoard" with TextLabels Title, Best, Clears, Reward for the client to fill) on top of a
	HOW TO PLAY board (three illustrated steps), both kept right of the stage view's edge; on
	its +X side a Hollywood dressing mirror ("RehearsalMirror" glass, "PRACTICE" sign) with the
	"RehearsalSpot" pad on a checker dance floor in front. A pink path of glowing chevrons
	leads from the spawn star to the big "StartPad" in front of the lit STAGE door at the
	lobby's inner edge (a glowing star disc in pink and navy rings, with a "StartGlow" column,
	a PointLight and a "StartLabel" billboard; Fx may hide them in play); past the door a pink
	path runs on to the stage steps.

	build() -> Built: everything World.Arena.Base has ({ folder, floor, spawn, exit,
	exitRadius, center, top }; spawn is the audience start mark, the fall-back respawn) plus
	playerSpot feet CFrame on the player's podium, facing the audience (lane 1)
	playerSpots every player podium's feet CFrame (lane 1 first): runs at the same time each
	           take their own lane; the rival is local to each client, so all share rivalSpot
	rivalSpot  feet CFrame on the rival's podium, facing the audience
	rival      empty Model "Rival" (the rival rig is built on each client by Fx.Pose, so
	           every player sees their own rival's show)
	lobbySpawn feet CFrame on the green room's star mark, facing the HOW TO PLAY board (-Z)
	startPad   the "StartPad" disc at the stage steps; startRadius: feet within it = Begin
	board      the YOUR BEST SurfaceGui ("BestBoard")
	mirrorSpot feet CFrame on the "RehearsalSpot", facing the mirror (+X)
]]

local Common = require(script.Parent.Common)
local Arena = require(script.Parent.Arena)
local PoseRules = require(script.Parent.Parent.Modes.PoseRules)

local W = Common.theme.World
local make = Common.make
local UPRIGHT = Common.UPRIGHT
local CYLINDER = Enum.PartType.Cylinder

-- Stage layout (studs, from the arena centre): deck depth span and height, podium spread.
local STAGE = {
	Front = -4, -- deck front edge, z offset from the centre
	Back = -22, -- deck back edge
	HalfW = 22,
	Height = 1.2,
	PodiumX = 7, -- each podium's x offset
	PodiumZ = -12,
	PodiumD = 7,
	PodiumH = 1.4,
	WallH = 19,
	LaneX = 16, -- the extra player podiums (lanes 2 and 3) at -LaneX and +LaneX
}

-- Width of the show (stage, fan zone and bleachers) in the middle of the deck; the wings
-- either side are the green room (+X) and the TV-crew corner (-X).
local SHOW_W = 56

-- Green room layout (x / z offsets from the arena centre; the spawn, mirror and inner edge
-- come from PoseRules.LOBBY, which Modes.Pose and the tests read too).
local LOBBY = {
	X0 = PoseRules.LOBBY.x0, -- inner edge (the velvet rope runs just inside it, at X0 - 0.3)
	X = PoseRules.LOBBY.spawnX, -- centre line
	SpawnZ = PoseRules.LOBBY.spawnZ,
	MirrorZ = PoseRules.LOBBY.mirrorZ,
	SpotX = PoseRules.LOBBY.spotX, -- the RehearsalSpot, in front of the mirror at the +X edge
	BoardZ = -16, -- front face of the HOW TO PLAY board (YOUR BEST sits on top of it)
	BoardX0 = 33.6, -- the boards' -X edge: clear of the stage view's right edge
	BoardX1 = 51.2,
	PathZ = -1.2, -- centre line of the STAGE door and the path on to the stage steps
	StartIn = 5.9, -- the START pad's x past X0 (in front of the STAGE door)
	StartZ = 1.5, -- the START pad's z: a step toward the spawn, clear of the boards in view
}
local START_RADIUS = 3.5

-- The arena's own sea (as World.Hub's): ocean tiles to the fog, a lagoon under the deck.
local OCEAN_TOP = -1.2
local OCEAN_TILE = 2048
local LAGOON_RADIUS = 96

-- SurfaceGui faces: Back is the part's +Z face, toward the audience and the spawn.
local AUDIENCE = Enum.NormalId.Back
-- Left is a part's -X face: the green room's +X-side boards face into the lobby.
local WEST = Enum.NormalId.Left

local PoseStage = {}

export type Built = Arena.Base & {
	playerSpot: CFrame,
	rivalSpot: CFrame,
	playerSpots: { CFrame },
	rival: Model,
	lobbySpawn: CFrame,
	startPad: BasePart,
	startRadius: number,
	board: SurfaceGui,
	mirrorSpot: CFrame,
}

-- `outline` swaps the soft ink stroke for a bold opaque one in that colour.
local function sign(part: BasePart, face: Enum.NormalId, text: string, color: Color3, ppu: number?, outline: Color3?)
	local gui = Instance.new("SurfaceGui")
	gui.Face = face
	gui.PixelsPerStud = ppu or 40
	gui.LightInfluence = 0
	gui.Parent = part
	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromScale(1, 1)
	label.Text = text
	label.TextScaled = true
	label.Font = Common.theme.Fonts.Display
	label.TextColor3 = color
	label.Parent = gui
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = if outline then 4 else 3
	stroke.Color = outline or W.Ink
	stroke.Transparency = if outline then 0 else 0.35
	stroke.Parent = label
	local pad = Instance.new("UIPadding")
	pad.PaddingTop = UDim.new(0.06, 0)
	pad.PaddingBottom = UDim.new(0.06, 0)
	pad.Parent = label
end

-- GUI pieces for the lobby boards ---------------------------------------------------------

local function surface(part: BasePart, face: Enum.NormalId, ppu: number, name: string?): SurfaceGui
	local gui = Instance.new("SurfaceGui")
	gui.Name = name or "SurfaceGui"
	gui.Face = face
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = ppu
	gui.LightInfluence = 0
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Parent = part
	return gui
end

-- A frame at scale position/size (x, y, w, h); `corner` rounds it (scale of the short side),
-- `outline` draws a cartoon ink stroke round it.
local function shape(parent: Instance, name: string, color: Color3, rect: { number }, corner: number?, outline: number?): Frame
	local f = Instance.new("Frame")
	f.Name = name
	f.BackgroundColor3 = color
	f.BorderSizePixel = 0
	f.Position = UDim2.fromScale(rect[1], rect[2])
	f.Size = UDim2.fromScale(rect[3], rect[4])
	f.Parent = parent
	if corner then
		local c = Instance.new("UICorner")
		c.CornerRadius = UDim.new(corner, 0)
		c.Parent = f
	end
	if outline then
		local st = Instance.new("UIStroke")
		st.Thickness = outline
		st.Color = W.Ink
		st.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
		st.Parent = f
	end
	return f
end

local function caption(
	parent: Instance,
	name: string,
	text: string,
	color: Color3,
	rect: { number },
	outline: Color3?,
	thickness: number?
): TextLabel
	local l = Instance.new("TextLabel")
	l.Name = name
	l.BackgroundTransparency = 1
	l.Position = UDim2.fromScale(rect[1], rect[2])
	l.Size = UDim2.fromScale(rect[3], rect[4])
	l.Text = text
	l.TextScaled = true
	l.TextWrapped = true
	l.Font = Common.theme.Fonts.Display
	l.TextColor3 = color
	l.ZIndex = 2
	l.Parent = parent
	if outline then
		local st = Instance.new("UIStroke")
		st.Thickness = thickness or 3
		st.Color = outline
		st.Parent = l
	end
	return l
end

local function flexColor(i: number): Color3
	local rgb = PoseRules.FLEXES[(i - 1) % #PoseRules.FLEXES + 1].rgb
	return Color3.fromRGB(rgb[1], rgb[2], rgb[3])
end

-- The HOW TO PLAY board: a navy face, a sunny heading and three white step cards, each with
-- a numbered badge, a drawing and a caption. 1: the rival chad hitting a double biceps.
-- 2: the four flex buttons as a D-pad in their colours. 3: stacks growing one flex a round
-- up to a gold "8" (copy 8 to pass).
local function howToPlay(gui: SurfaceGui)
	local back = shape(gui, "Back", W.Navy, { 0, 0, 1, 1 })
	caption(back, "Heading", "HOW TO PLAY", W.Sunny, { 0.05, 0.01, 0.9, 0.21 }, W.Ink, 5)
	-- One or two short words each, so the letters come out big from the spawn.
	local steps = {
		{ color = W.Grape, text = "WATCH!" },
		{ color = W.HotPink, text = "COPY!" },
		{ color = W.Gold, text = "8 TO PASS!" },
	}
	local arts: { Frame } = {}
	for i, step in steps do
		local card = shape(back, "Step" .. i, W.White, { 0.035 + (i - 1) * 0.3225, 0.235, 0.3, 0.735 }, 0.08)
		local edge = Instance.new("UIStroke")
		edge.Thickness = 8
		edge.Color = step.color
		edge.Parent = card
		local badge = shape(card, "Badge", step.color, { -0.06, -0.06, 0.24, 0.24 }, 0.5, 3)
		badge.SizeConstraint = Enum.SizeConstraint.RelativeXX
		badge.ZIndex = 3
		local num = caption(badge, "Number", tostring(i), W.White, { 0.12, 0.1, 0.76, 0.8 }, W.Navy)
		num.ZIndex = 4
		-- The drawing: a square canvas centred in the card's top part.
		local area = shape(card, "ArtArea", W.White, { 0.1, 0.05, 0.8, 0.5 })
		area.BackgroundTransparency = 1
		local art = shape(area, "Art", W.White, { 0, 0, 1, 1 })
		art.BackgroundTransparency = 1
		art.AnchorPoint = Vector2.new(0.5, 0.5)
		art.Position = UDim2.fromScale(0.5, 0.5)
		local square = Instance.new("UIAspectRatioConstraint")
		square.AspectRatio = 1
		square.Parent = art
		arts[i] = art
		caption(card, "Caption", step.text, step.color, { 0.05, 0.58, 0.9, 0.38 }, W.Navy, 4)
	end

	-- 1: the rival (purple vest, Roblox-yellow skin) hitting a double biceps.
	local chad = arts[1]
	local skin = W.Sunny
	for _, side in { -1, 1 } do
		local x = 0.5 + side * 0.31
		-- ZIndex = draw order: limbs, then the muscles over them, the body, the head.
		shape(chad, "Forearm", skin, { x - 0.045, 0.1, 0.09, 0.28 }, 0.4, 2).ZIndex = 1
		shape(chad, "UpperArm", skin, { if side < 0 then 0.17 else 0.61, 0.32, 0.22, 0.1 }, 0.4, 2).ZIndex = 1
		shape(chad, "Leg", skin, { 0.5 + side * 0.07 - 0.045, 0.72, 0.09, 0.22 }, 0.3, 2).ZIndex = 1
		shape(chad, "Fist", skin, { x - 0.055, 0.04, 0.11, 0.11 }, 0.5, 2).ZIndex = 2
		shape(chad, "Bicep", skin, { x - side * 0.06 - 0.07, 0.24, 0.14, 0.12 }, 0.5, 2).ZIndex = 2
	end
	shape(chad, "Torso", W.Grape, { 0.35, 0.31, 0.3, 0.34 }, 0.2, 2).ZIndex = 3
	shape(chad, "Shorts", W.Navy, { 0.37, 0.62, 0.26, 0.13 }, 0.2, 2).ZIndex = 4
	shape(chad, "Head", skin, { 0.4, 0.08, 0.2, 0.2 }, 0.5, 2).ZIndex = 5
	for _, ex in { 0.455, 0.515 } do
		shape(chad, "Eye", W.Ink, { ex, 0.15, 0.03, 0.03 }, 0.5).ZIndex = 6
	end
	shape(chad, "Smile", W.Ink, { 0.465, 0.215, 0.07, 0.018 }, 0.5).ZIndex = 6
	for k, spark in { { 0.03, 0.5 }, { 0.88, 0.5 }, { 0.06, 0.66 }, { 0.85, 0.66 } } do
		local star = shape(chad, "Spark", if k % 2 == 0 then W.HotPink else W.Gold, { spark[1], spark[2], 0.08, 0.08 })
		star.Rotation = 45
	end

	-- 2: the four buttons as a D-pad (up, left, right, down), each with a white glint.
	local pad = arts[2]
	local where: { [string]: { number } } = { Up = { 0.35, 0.03 }, Left = { 0.03, 0.35 }, Right = { 0.67, 0.35 }, Down = { 0.35, 0.67 } }
	shape(pad, "PadCentre", W.Navy, { 0.36, 0.36, 0.28, 0.28 }, 0.2, 2)
	for i, flex in PoseRules.FLEXES do
		local at = where[flex.dir] or { 0.35, 0.35 }
		local button = shape(pad, "Button" .. i, flexColor(i), { at[1], at[2], 0.3, 0.3 }, 0.25, 3)
		shape(button, "Glint", W.White, { 0.3, 0.3, 0.4, 0.4 }, 0.5)
	end

	-- 3: stacks of 1, 2, 3, 4 flexes, then a gold "8" badge: copy 8 to pass.
	local grow = arts[3]
	local n = 0
	for col = 1, 4 do
		for row = 1, col do
			n += 1
			shape(grow, "Flex", flexColor(n), { 0.02 + (col - 1) * 0.15, 0.86 - row * 0.16, 0.12, 0.12 }, 0.25, 2)
		end
	end
	local eight = shape(grow, "PassBadge", W.Gold, { 0.63, 0.12, 0.35, 0.35 }, 0.5, 3)
	caption(eight, "Eight", "8", W.Navy, { 0.1, 0.08, 0.8, 0.84 }, W.White)
	caption(grow, "Pass", "PASS!", W.HotPink, { 0.6, 0.5, 0.4, 0.2 }, W.Navy)
end

-- The YOUR BEST board's face, a wide strip: a sunny title block on the left and three
-- big lines on the right. TextLabels Title, Best, Clears, Reward right under the SurfaceGui
-- (the client finds them by name and fills them).
local function bestBoard(gui: SurfaceGui)
	shape(gui, "Back", W.Navy, { 0, 0, 1, 1 })
	shape(gui, "TitleBlock", W.Sunny, { 0, 0, 0.34, 1 })
	shape(gui, "TitleEdge", W.HotPink, { 0.34, 0, 0.012, 1 })
	caption(gui, "Title", "YOUR BEST", W.Navy, { 0.02, 0.06, 0.3, 0.88 }, W.White, 4)
	caption(gui, "Best", "BEST: --", W.White, { 0.38, 0.05, 0.59, 0.29 }, W.Ink, 4)
	caption(gui, "Clears", "CLEARS: --", W.White, { 0.38, 0.355, 0.59, 0.29 }, W.Ink, 4)
	caption(gui, "Reward", "REWARD: --", W.Sunny, { 0.38, 0.66, 0.59, 0.29 }, W.Ink, 4)
end

-- Props ------------------------------------------------------------------------------------

-- A prop model like World.Hub's: Model `name` (attribute Mesh = kind) on an invisible
-- "PropRoot", so Props.apply swaps in the Blender mesh when it is uploaded. `add` places a
-- part in the prop's frame.
local function newProp(parent: Instance, kind: string, base: CFrame, name: string?): (Model, (props: { [string]: any }) -> BasePart)
	local model = Instance.new("Model")
	model.Name = name or ("Prop_" .. kind)
	model:SetAttribute("Mesh", kind)
	local root = make("Part", {
		Name = "PropRoot",
		Size = Vector3.new(1, 0.2, 1),
		CFrame = base,
		Transparency = 1,
		CanCollide = false,
		CanQuery = false,
		CanTouch = false,
		CastShadow = false,
		Parent = model,
	})
	model.PrimaryPart = root
	model.Parent = parent
	local function add(props: { [string]: any }): BasePart
		props.CFrame = base * (props.CFrame or CFrame.new())
		props.Parent = model
		return make("Part", props)
	end
	return model, add
end

-- A palm (the hub's PalmTree mesh when uploaded; Fx.Ambient sways it): a curved ringed
-- trunk, a crown and six fronds.
local function palm(parent: Instance, base: CFrame, height: number, lean: number)
	local model, add = newProp(parent, "PalmTree", base)
	model:SetAttribute("Height", height)
	model:SetAttribute("MeshScale", height / 16)
	local s = height / 16
	local seg = height / 3
	local frame = CFrame.new()
	for i = 1, 3 do
		frame = frame * CFrame.Angles(lean / 3, 0, 0)
		local d = (1.9 - 0.3 * (i - 1)) * s
		add({
			Name = "Trunk",
			Shape = CYLINDER,
			Size = Vector3.new(seg + 0.3 * s, d, d),
			CFrame = frame * CFrame.new(0, seg / 2, 0) * UPRIGHT,
			Color = if i % 2 == 0 then W.WoodDark else W.Wood,
		})
		frame = frame * CFrame.new(0, seg, 0)
	end
	local crown = CFrame.new(frame.Position)
	add({ Name = "Crown", Shape = Enum.PartType.Ball, Size = Vector3.one * 2.2 * s, CFrame = crown, Color = W.GrassDark })
	for i = 1, 6 do
		local length = 6.2 * s
		add({
			Name = "Frond",
			Size = Vector3.new(2 * s, 0.35 * s, length),
			CFrame = crown * CFrame.Angles(0, (i + 0.3) * math.pi / 3, 0) * CFrame.Angles(-0.3, 0, 0) * CFrame.new(0, 0, -length / 2),
			Color = if i % 2 == 0 then W.Grass else W.GrassDark,
			CanCollide = false,
		})
	end
end

-- A puffy cloud (Fx.Ambient drifts models named "Cloud").
local function cloud(parent: Instance, pos: Vector3, scale: number)
	local model, add = newProp(parent, "Cloud", CFrame.new(pos), "Cloud")
	local puffs =
		{ { 0, 0, 0, 1 }, { -0.75, -0.15, 0.1, 0.72 }, { 0.8, -0.2, -0.1, 0.68 }, { 0.3, 0.35, 0.15, 0.62 }, { -0.35, 0.28, -0.2, 0.55 } }
	for _, p in puffs do
		add({
			Name = "CloudPuff",
			Shape = Enum.PartType.Ball,
			Size = Vector3.one * 40 * scale * p[4],
			CFrame = CFrame.new(p[1] * 40 * scale, p[2] * 40 * scale, p[3] * 40 * scale),
			Color = W.White,
			CanCollide = false,
			CanQuery = false,
			CanTouch = false,
			CastShadow = false,
		})
	end
	model:SetAttribute("Height", pos.Y)
end

-- The arena's own sea in a "PoseSea" model: ocean tiles out past the fog, a light lagoon
-- under the deck ringed by bobbing buoys, palm islands and sandbars on the horizon and a few
-- clouds. The water never collides: a player who jumps off falls through and Modes.Pose
-- puts them back (FALL_BELOW).
local function buildSea(parent: Instance, cx: number, cz: number)
	local sea = Instance.new("Model")
	sea.Name = "PoseSea"
	sea.Parent = parent
	local function flat(name: string, radius: number, topY: number, thickness: number, color: Color3, x: number, z: number): BasePart
		return make("Part", {
			Name = name,
			Shape = CYLINDER,
			Size = Vector3.new(thickness, radius * 2, radius * 2),
			CFrame = CFrame.new(x, topY - thickness / 2, z) * UPRIGHT,
			Color = color,
			CastShadow = false,
			Parent = sea,
		})
	end
	for ix = -1, 1 do
		for iz = -1, 1 do
			make("Part", {
				Name = "Ocean",
				Size = Vector3.new(OCEAN_TILE, 2, OCEAN_TILE),
				CFrame = CFrame.new(cx + ix * OCEAN_TILE, OCEAN_TOP - 1, cz + iz * OCEAN_TILE),
				Color = W.Ocean,
				Reflectance = 0.05,
				CastShadow = false,
				CanCollide = false,
				CanQuery = false,
				CanTouch = false,
				Parent = sea,
			})
		end
	end
	local lagoon = flat("Lagoon", LAGOON_RADIUS, OCEAN_TOP + 0.2, 0.2, W.Shallows, cx, cz)
	lagoon.CanCollide = false
	lagoon.CanQuery = false
	lagoon.CanTouch = false
	-- Buoys round the lagoon, pink and white, bobbing (Fx.Ambient: attribute Bob).
	local buoys = 14
	for i = 1, buoys do
		local angle = (i - 0.5) * 2 * math.pi / buoys
		local buoy = make("Part", {
			Name = "Buoy",
			Shape = Enum.PartType.Ball,
			Size = Vector3.one * 2.2,
			CFrame = CFrame.new(cx + math.cos(angle) * 78, OCEAN_TOP + 0.5, cz + math.sin(angle) * 64),
			Color = if i % 2 == 0 then W.White else W.HotPink,
			CanCollide = false,
			Parent = sea,
		})
		buoy:SetAttribute("Bob", 0.3)
	end

	-- Palm islands all round the horizon: { dx, dz, radius, palms }.
	local islands = {
		{ -170, -640, 54, 3 },
		{ 560, -420, 40, 2 },
		{ 740, 240, 58, 3 },
		{ -640, 420, 46, 3 },
		{ -780, -260, 36, 2 },
		{ 120, 760, 44, 2 },
	}
	for n, isle in islands do
		local x, z, r = cx + isle[1], cz + isle[2], isle[3]
		flat("FarShallows", r + 16, OCEAN_TOP + 0.15, 0.2, W.Shallows, x, z)
		flat("FarIsland", r, 1.4, 5, W.Sand, x, z)
		flat("FarHill", r * 0.6, 3.4, 3, W.Grass, x, z)
		flat("FarHillTop", r * 0.3, 5.4, 3, W.GrassDark, x, z)
		local spots = { { 0.8, 0.4, 1.4 }, { 0.45, 2.6, 3.4 }, { 0.15, 4.4, 5.4 } }
		for i = 1, isle[4] do
			local spot = spots[i]
			local a = n * 1.3 + spot[2]
			palm(
				sea,
				CFrame.new(x + math.cos(a) * r * spot[1], spot[3], z + math.sin(a) * r * spot[1]) * CFrame.Angles(0, a + i, 0),
				24 + (i % 3) * 4,
				0.25 + 0.08 * i
			)
		end
	end
	-- Low sandbars nearer in, one with a lone palm: { dx, dz, radius }.
	for i, bar in { { 230, -260, 24 }, { -280, 210, 18 }, { 150, 320, 14 } } do
		local x, z, r = cx + bar[1], cz + bar[2], bar[3]
		flat("SandbarShallows", r + 10, OCEAN_TOP + 0.12, 0.2, W.Shallows, x, z)
		flat("Sandbar", r, OCEAN_TOP + 0.7, 2, W.Sand, x, z)
		if i == 1 then
			palm(sea, CFrame.new(x - r * 0.3, OCEAN_TOP + 0.7, z), 18, 0.35)
		end
	end

	-- Foam round the deck at the waterline: a bright ring hugging the hull and a softer one
	-- out past it (wide enough to show past the deck's lip from the lobby view).
	local hx, hz = PoseRules.ARENA.sizeX / 2, PoseRules.ARENA.sizeZ / 2
	local function foamRing(name: string, inner: number, outer: number, y: number, transparency: number)
		local w = outer - inner
		for _, side in { -1, 1 } do
			for _, along in { "x", "z" } do
				local size = if along == "x" then Vector3.new(2 * (hx + outer), 0.2, w) else Vector3.new(w, 0.2, 2 * (hz + inner))
				local offset = if along == "x"
					then Vector3.new(0, 0, side * (hz + inner + w / 2))
					else Vector3.new(side * (hx + inner + w / 2), 0, 0)
				make("Part", {
					Name = name,
					Size = size,
					CFrame = CFrame.new(cx + offset.X, y, cz + offset.Z),
					Color = W.White,
					Transparency = transparency,
					CanCollide = false,
					CanQuery = false,
					CanTouch = false,
					CastShadow = false,
					Parent = sea,
				})
			end
		end
	end
	foamRing("DeckFoam", 0.5, 5, OCEAN_TOP + 0.35, 0.15)
	foamRing("DeckFoamOuter", 5, 16, OCEAN_TOP + 0.3, 0.6)

	-- Three big palm islets close in, each in a gap the views see the sea through: east of
	-- the lobby (the lobby view, past the railing), and either side of the LED wall (the
	-- stage view). Sand on a foam ring and shallows, a grass knoll, palms and a beach
	-- umbrella. `turn` spins the layout so the three don't look stamped.
	local function knoll(name: string, diameter: number, top: number, x: number, z: number, color: Color3)
		make("Part", {
			Name = name,
			Shape = Enum.PartType.Ball,
			Size = Vector3.one * diameter,
			CFrame = CFrame.new(x, OCEAN_TOP + top - diameter / 2, z),
			Color = color,
			CanCollide = false,
			CanQuery = false,
			CanTouch = false,
			Parent = sea,
		})
	end
	local islets: { { dx: number, dz: number, r: number, color: Color3, turn: number } } = {
		{ dx = 82, dz = -44, r = 17, color = W.HotPink, turn = 0.4 },
		{ dx = -70, dz = -80, r = 18, color = W.Sunny, turn = 2.2 },
		{ dx = 72, dz = -84, r = 15, color = W.RainbowBlue, turn = 4.1 },
	}
	for i, isle in islets do
		local x, z, r, turn = cx + isle.dx, cz + isle.dz, isle.r, isle.turn
		flat("IsletShallows", r + 12, OCEAN_TOP + 0.15, 0.2, W.Shallows, x, z)
		local foam = flat("IsletFoam", r + 3, OCEAN_TOP + 0.3, 0.2, W.White, x, z)
		foam.Transparency = 0.2
		foam.CanCollide = false
		flat("Islet", r, 1.2, 4, W.Sand, x, z)
		knoll("IsletKnoll", r * 1.3, 9, x - math.cos(turn) * r * 0.25, z - math.sin(turn) * r * 0.25, W.Grass)
		for k, spot in { { 0.55, 0.3, 26 }, { 0.6, 1.5, 21 } } do
			local a = turn + spot[2]
			palm(
				sea,
				CFrame.new(x + math.cos(a) * r * spot[1], 1.2, z + math.sin(a) * r * spot[1]) * CFrame.Angles(0, a + k, 0),
				spot[3],
				0.3 + 0.1 * k
			)
		end
		-- A beach umbrella on the sand toward the deck: a white pole and a two-tone canopy.
		local ux, uz = x - math.sign(isle.dx) * r * 0.55, z + r * 0.35
		local pole = flat("UmbrellaPole", 0.3, 9.6, 8.4, W.White, ux, uz)
		pole.CanCollide = false
		flat("UmbrellaCanopy", 5, 9.9, 0.8, isle.color, ux, uz).CanCollide = false
		flat("UmbrellaTop", 2.2, 10.4, 0.6, W.White, ux, uz).CanCollide = false
		if i == 1 then
			-- A beach ball beside the umbrella on the lobby's islet.
			knoll("IsletBall", 3, 4.4, ux + 3.5, uz - 1, W.Sunny)
		end
	end

	for _, c in
		{
			{ -320, 190, -560, 1.4 },
			{ 420, 230, -720, 1.2 },
			{ 640, 200, 140, 1.3 },
			{ -580, 240, 320, 1.5 },
			{ 80, 260, 660, 1.1 },
			-- Low clouds in the stage and lobby views' sky.
			{ 300, 90, -424, 1.0 },
			{ 341, 80, -308, 0.8 },
			{ -386, 100, -372, 1.2 },
		}
	do
		cloud(sea, Vector3.new(cx + c[1], c[2], cz + c[3]), c[4])
	end
end

function PoseStage.build(): Built
	local a = PoseRules.ARENA
	local base = Arena.base("pose", "PoseStage", a, { floor = "Cream", trim = "Blue" })
	local folder = base.folder
	local top = base.top
	local cx, cz = a.x, a.z
	local deckTop = top + STAGE.Height
	local depth = STAGE.Front - STAGE.Back
	local midZ = cz + (STAGE.Front + STAGE.Back) / 2

	local function box(name: string, size: Vector3, cf: CFrame, color: Color3, material: Enum.Material?): BasePart
		return make("Part", {
			Name = name,
			Size = size,
			CFrame = cf,
			Color = color,
			Material = material or Enum.Material.SmoothPlastic,
			Parent = folder,
		})
	end
	local function disc(name: string, diameter: number, height: number, pos: Vector3, color: Color3, material: Enum.Material?): BasePart
		return make("Part", {
			Name = name,
			Shape = CYLINDER,
			Size = Vector3.new(height, diameter, diameter),
			CFrame = CFrame.new(pos) * UPRIGHT,
			Color = color,
			Material = material or Enum.Material.SmoothPlastic,
			Parent = folder,
		})
	end

	-- Stage deck: white body, a blue top, a glowing front strip and three steps to the runway.
	box("StageDeck", Vector3.new(STAGE.HalfW * 2, STAGE.Height, depth), CFrame.new(cx, top + STAGE.Height / 2, midZ), W.White)
	box("StageTop", Vector3.new(STAGE.HalfW * 2 - 1, 0.1, depth - 1), CFrame.new(cx, deckTop + 0.05, midZ - 0.5), W.SkyBlue)
	box(
		"StageEdge",
		Vector3.new(STAGE.HalfW * 2, 0.3, 0.3),
		CFrame.new(cx, deckTop - 0.25, cz + STAGE.Front + 0.05),
		W.Sunny,
		Enum.Material.Neon
	)
	for i = 1, 2 do
		local h = STAGE.Height * i / 3
		box("StageStep", Vector3.new(8, h, 1.4), CFrame.new(cx, top + h / 2, cz + STAGE.Front + 1.4 * (3 - i) - 0.7), W.Cream)
	end
	-- Runway from the spawn to the steps.
	local runFrom, runTo = cz + STAGE.Front + 2.8, cz + a.sizeZ / 2 - 10
	box("Runway", Vector3.new(6, 0.12, runTo - runFrom), CFrame.new(cx, top + 0.06, (runFrom + runTo) / 2), W.HotPink)
	for _, side in { -1, 1 } do
		box("RunwayEdge", Vector3.new(0.3, 0.16, runTo - runFrom), CFrame.new(cx + side * 3.15, top + 0.08, (runFrom + runTo) / 2), W.White)
	end

	-- Back wall with a framed banner on top.
	local wallZ = cz + STAGE.Back + 0.6
	box("StageWall", Vector3.new(STAGE.HalfW * 2, STAGE.WallH, 1), CFrame.new(cx, deckTop + STAGE.WallH / 2, wallZ), W.Navy)
	box("StageWallFrame", Vector3.new(STAGE.HalfW * 2 + 1.2, 1.2, 1.4), CFrame.new(cx, deckTop + STAGE.WallH, wallZ), W.Blue)
	for _, side in { -1, 1 } do
		box(
			"StageWallFrame",
			Vector3.new(1.2, STAGE.WallH, 1.4),
			CFrame.new(cx + side * (STAGE.HalfW + 0.1), deckTop + STAGE.WallH / 2, wallZ),
			W.Blue
		)
	end
	-- Dark letters on a sunny board with a white border: reads from the back of the crowd.
	local bannerY = deckTop + STAGE.WallH - 2.9
	box("PoseBannerBorder", Vector3.new(28.8, 5.8, 0.4), CFrame.new(cx, bannerY, wallZ + 0.7), W.White)
	local banner = box("PoseBanner", Vector3.new(28, 5, 0.6), CFrame.new(cx, bannerY, wallZ + 0.8), W.Sunny)
	sign(banner, AUDIENCE, "POSE COPY", W.Navy, 40, W.White)
	box("PoseBannerTrim", Vector3.new(28.8, 0.4, 0.7), CFrame.new(cx, bannerY - 2.9, wallZ + 0.85), W.HotPink, Enum.Material.Neon)

	-- The LED backdrop: one calm blue screen (the chads and the podiums pop against it) under
	-- a navy band behind the banner, a few neon stars, red curtains at the sides, a valance
	-- and a light bar of coloured cans on top. All opaque: the wall reads as a screen.
	local face = wallZ + 0.55
	local lowH = STAGE.WallH * 0.66
	box("BackdropBand", Vector3.new(STAGE.HalfW * 2 - 2, lowH, 0.1), CFrame.new(cx, deckTop + lowH / 2, face), W.Blue)
	box(
		"BackdropBand",
		Vector3.new(STAGE.HalfW * 2 - 2, STAGE.WallH - lowH, 0.1),
		CFrame.new(cx, deckTop + (STAGE.WallH + lowH) / 2, face),
		W.Navy
	)
	box(
		"BackdropStripe",
		Vector3.new(STAGE.HalfW * 2 - 2, 0.35, 0.12),
		CFrame.new(cx, deckTop + lowH, face + 0.02),
		W.Sunny,
		Enum.Material.Neon
	)
	local stars = {
		{ x = -14, y = 9.5, color = W.Sunny, size = 1.6 },
		{ x = 14, y = 9, color = W.Sunny, size = 1.6 },
		{ x = -16, y = 4.5, color = W.White, size = 1.0 },
		{ x = 16, y = 5, color = W.White, size = 1.0 },
	}
	for _, star in stars do
		local pos = CFrame.new(cx + star.x, deckTop + star.y, face + 0.13)
		for _, turn in { 0, 45 } do
			local ray = box(
				"BackdropStar",
				Vector3.new(star.size, star.size, 0.12),
				pos * CFrame.Angles(0, 0, math.rad(turn)),
				star.color,
				Enum.Material.Neon
			)
			ray.CanCollide = false
		end
	end
	for _, side in { -1, 1 } do
		for f = 0, 2 do
			disc(
				"Curtain",
				1.7,
				STAGE.WallH + 1,
				Vector3.new(cx + side * (STAGE.HalfW - 0.7 - f * 1.3), deckTop + (STAGE.WallH + 1) / 2, wallZ + 1.3 + (f % 2) * 0.35),
				W.RainbowRed,
				Enum.Material.Fabric
			)
		end
	end
	box(
		"Valance",
		Vector3.new(STAGE.HalfW * 2 + 1.6, 2, 1.2),
		CFrame.new(cx, deckTop + STAGE.WallH + 1.2, wallZ + 1.4),
		W.RainbowRed,
		Enum.Material.Fabric
	)
	box(
		"ValanceTrim",
		Vector3.new(STAGE.HalfW * 2 + 1.6, 0.35, 1.3),
		CFrame.new(cx, deckTop + STAGE.WallH + 0.2, wallZ + 1.45),
		W.Sunny,
		Enum.Material.Neon
	)
	box("LightBar", Vector3.new(STAGE.HalfW * 2 - 4, 0.5, 0.5), CFrame.new(cx, deckTop + STAGE.WallH + 2.6, wallZ + 2), W.Steel)
	local canColors = { W.Sunny, W.HotPink, W.RainbowBlue, W.White, W.Mint, W.HotPink, W.Sunny }
	for i, color in canColors do
		local x = cx + (i - 4) * 6
		local canPos = Vector3.new(x, deckTop + STAGE.WallH + 3.4, wallZ + 2)
		local aim = Vector3.new(x * 0.4 + cx * 0.6, deckTop + 2, cz + STAGE.PodiumZ + 2)
		make("Part", {
			Name = "StageCan",
			Shape = CYLINDER,
			Size = Vector3.new(1.6, 1.3, 1.3),
			CFrame = CFrame.lookAt(canPos, aim) * CFrame.Angles(0, math.rad(90), 0),
			Color = W.Navy,
			CanCollide = false,
			Parent = folder,
		})
		local lens = make("Part", {
			Name = "StageCanLens",
			Shape = CYLINDER,
			Size = Vector3.new(0.15, 1.1, 1.1),
			CFrame = CFrame.lookAt(canPos + (aim - canPos).Unit * 0.82, aim) * CFrame.Angles(0, math.rad(90), 0),
			Color = color,
			Material = Enum.Material.Neon,
			CanCollide = false,
			Parent = folder,
		})
		if i % 2 == 0 then
			local light = Instance.new("SpotLight")
			light.Face = Enum.NormalId.Right
			light.Angle = 50
			light.Range = 34
			light.Brightness = 2
			light.Color = color
			light.Parent = lens
		end
	end
	-- Gold side stars flanking the title.
	for _, side in { -1, 1 } do
		local pos = CFrame.new(cx + side * 15.6, deckTop + STAGE.WallH - 2.9, wallZ + 0.9)
		for _, turn in { 0, 45 } do
			box("TitleStar", Vector3.new(1.8, 1.8, 0.3), pos * CFrame.Angles(0, 0, math.rad(turn)), W.Sunny, Enum.Material.Neon)
		end
	end

	-- The flex lamps: a D-pad of four tiles between the chads (up, left, right, down).
	local padY = deckTop + 9.4
	local padZ = wallZ + 1.2
	local offsets: { [string]: Vector2 } = {
		Up = Vector2.new(0, 1),
		Left = Vector2.new(-1, 0),
		Right = Vector2.new(1, 0),
		Down = Vector2.new(0, -1),
	}
	box("FlexPadRim", Vector3.new(11, 11, 0.2), CFrame.new(cx, padY, padZ - 0.5) * CFrame.Angles(0, 0, math.rad(45)), W.White)
	box("FlexPadBack", Vector3.new(9.6, 9.6, 0.3), CFrame.new(cx, padY, padZ - 0.35) * CFrame.Angles(0, 0, math.rad(45)), W.Navy)
	for i, flex in PoseRules.FLEXES do
		local o = offsets[flex.dir] or Vector2.zero
		local lamp = box(
			"FlexLamp" .. i,
			Vector3.new(2.6, 2.6, 0.5),
			CFrame.new(cx + o.X * 2.7, padY + o.Y * 2.7, padZ) * CFrame.Angles(0, 0, math.rad(45)),
			Color3.fromRGB(flex.rgb[1], flex.rgb[2], flex.rgb[3])
		)
		lamp:SetAttribute("Flex", i)
		lamp.Transparency = 0.15
	end

	-- Podiums: rival on the audience's left (-X), the player on the right (+X).
	local facing = Vector3.new(0, 0, 1)
	local podiumZ = cz + STAGE.PodiumZ
	local feetY = deckTop + STAGE.PodiumH
	local rivalPos = Vector3.new(cx - STAGE.PodiumX, feetY, podiumZ)
	local playerPos = Vector3.new(cx + STAGE.PodiumX, feetY, podiumZ)
	local lanePos = {
		playerPos,
		Vector3.new(cx - STAGE.LaneX, feetY, podiumZ),
		Vector3.new(cx + STAGE.LaneX, feetY, podiumZ),
	}
	local podiums = {
		{ pos = rivalPos, color = W.Grape, name = "RivalPad", text = "CHAD" },
		{ pos = lanePos[1], color = W.Sunny, name = "PlayerPad", text = "YOU" },
		{ pos = lanePos[2], color = W.Sunny, name = "PlayerPad", text = "YOU" },
		{ pos = lanePos[3], color = W.Sunny, name = "PlayerPad", text = "YOU" },
	}
	for _, pod in podiums do
		local p = pod.pos
		-- A navy plinth under each podium and a navy band round its middle: dark outlines so
		-- the sunny and purple discs stand off the sky-blue deck.
		disc("PodiumPlinth", STAGE.PodiumD + 3, 0.3, Vector3.new(p.X, deckTop + 0.15, p.Z), W.Navy)
		disc(pod.name, STAGE.PodiumD, STAGE.PodiumH, Vector3.new(p.X, deckTop + STAGE.PodiumH / 2, p.Z), pod.color)
		local band = disc("PodiumBand", STAGE.PodiumD + 0.3, 0.35, Vector3.new(p.X, deckTop + 0.55, p.Z), W.Navy)
		band.CanCollide = false
		-- A bright outline: a fat white neon lip just under the podium's top edge (Fx.Pose
		-- tints it) and a sunny neon ring on the navy plinth round its foot.
		local glow =
			disc("PodiumGlow", STAGE.PodiumD + 1.2, 0.5, Vector3.new(p.X, deckTop + STAGE.PodiumH - 0.32, p.Z), W.White, Enum.Material.Neon)
		glow:SetAttribute("Side", if pod.name == "RivalPad" then "rival" else "player")
		local foot = disc("PodiumFootGlow", STAGE.PodiumD + 1.8, 0.12, Vector3.new(p.X, deckTop + 0.33, p.Z), W.Sunny, Enum.Material.Neon)
		foot.CanCollide = false
		local plate = box("PodiumPlate", Vector3.new(4, 1, 0.2), CFrame.new(p.X, deckTop + 0.85, p.Z + STAGE.PodiumD / 2 + 0.2), W.White)
		plate.CanCollide = false
		sign(plate, AUDIENCE, pod.text, pod.color)
	end

	-- Spotlight towers at the stage's front corners, aimed at the podiums.
	for _, side in { -1, 1 } do
		local x = cx + side * (STAGE.HalfW + 2.5)
		local z = cz + STAGE.Front - 1
		local h = 15
		disc("SpotBase", 3, 0.6, Vector3.new(x, top + 0.3, z), W.Navy)
		box("SpotTower", Vector3.new(0.8, h, 0.8), CFrame.new(x, top + h / 2, z), W.Steel)
		local target = (if side < 0 then rivalPos else playerPos) + Vector3.new(0, 3, 0)
		local headPos = Vector3.new(x, top + h + 0.6, z)
		make("Part", {
			Name = "SpotHead",
			Shape = CYLINDER,
			Size = Vector3.new(2.2, 2, 2),
			-- A cylinder's axis is its X: point it from the head at the podium.
			CFrame = CFrame.lookAt(headPos, target) * CFrame.Angles(0, math.rad(90), 0),
			Color = W.Navy,
			Parent = folder,
		})
		local lens = make("Part", {
			Name = "SpotLens",
			Shape = CYLINDER,
			Size = Vector3.new(0.2, 1.7, 1.7),
			CFrame = CFrame.lookAt(headPos + (target - headPos).Unit * 1.15, target) * CFrame.Angles(0, math.rad(90), 0),
			Color = Color3.fromRGB(255, 244, 200),
			Material = Enum.Material.Neon,
			CanCollide = false,
			Parent = folder,
		})
		local light = Instance.new("SpotLight")
		light.Face = Enum.NormalId.Right
		light.Angle = 40
		light.Range = 30
		light.Brightness = 2.5
		light.Color = Color3.fromRGB(255, 240, 210)
		light.Parent = lens
	end

	-- Blocky Roblox-style figures (fans and judges): torso and yellow head on a seat, facing
	-- the stage. `cf` is the seat top, looking at the stage.
	local SKIN = W.Sunny
	local function figure(cf: CFrame, shirt: Color3)
		local torso = box("FanBody", Vector3.new(1.4, 1.6, 0.8), cf * CFrame.new(0, 0.8, 0), shirt)
		torso.CanCollide = false
		make("Part", {
			Name = "FanHead",
			Shape = Enum.PartType.Ball,
			Size = Vector3.one * 1.1,
			CFrame = cf * CFrame.new(0, 2.15, 0),
			Color = SKIN,
			Material = Enum.Material.SmoothPlastic,
			CanCollide = false,
			Parent = folder,
		})
	end
	-- A raised arm at the figure's right holding `color` up (a foam finger or a score paddle).
	local function raisedArm(cf: CFrame): CFrame
		local arm = box("FanArm", Vector3.new(0.4, 1.5, 0.4), cf * CFrame.new(0.95, 2.05, 0), SKIN)
		arm.CanCollide = false
		return cf * CFrame.new(0.95, 2.8, 0)
	end
	local function foamFinger(cf: CFrame, color: Color3)
		local hand = raisedArm(cf)
		local palm = box("FoamFinger", Vector3.new(1.1, 1.1, 0.45), hand * CFrame.new(0, 0.5, 0), color)
		local finger = box("FoamFinger", Vector3.new(0.4, 1.2, 0.4), hand * CFrame.new(0.25, 1.6, 0), color)
		palm.CanCollide = false
		finger.CanCollide = false
	end

	-- Judges' table on the audience's left, angled at the stage: three judges in navy seated on
	-- coral chairs facing the stage, each holding up a "10" paddle.
	local judge = CFrame.new(cx - 14, top, cz + 6.4) * CFrame.Angles(0, math.rad(-12), 0)
	box("JudgeTable", Vector3.new(14, 0.5, 3.4), judge * CFrame.new(0, 3.25, 0), W.White)
	box("JudgeTableTrim", Vector3.new(14.2, 0.25, 3.6), judge * CFrame.new(0, 2.9, 0), W.HotPink)
	box("JudgeSkirt", Vector3.new(14, 2.8, 0.3), judge * CFrame.new(0, 1.4, -1.55), W.Blue)
	for _, dx in { -6.6, 6.6 } do
		box("JudgeLeg", Vector3.new(0.4, 2.8, 3), judge * CFrame.new(dx, 1.4, 0), W.Blue)
	end
	local judgeSign = box("JudgeSign", Vector3.new(8, 1.8, 0.2), judge * CFrame.new(0, 1.6, -1.75), W.Sunny)
	sign(judgeSign, Enum.NormalId.Front, "JUDGES", W.Navy, 40, W.White)
	for i = -1, 1 do
		local seat = judge * CFrame.new(i * 4.4, 0, 3.1)
		box("JudgeChair", Vector3.new(2.6, 0.4, 2.4), seat * CFrame.new(0, 2, 0), W.Coral)
		box("JudgeChairBack", Vector3.new(2.6, 2.6, 0.3), seat * CFrame.new(0, 3.3, 1.1), W.Coral)
		box("JudgeChairLeg", Vector3.new(0.5, 1.8, 0.5), seat * CFrame.new(0, 0.9, 0), W.Steel)
		box("JudgeChairFoot", Vector3.new(1.8, 0.2, 1.8), seat * CFrame.new(0, 0.1, 0), W.Steel)
		local sit = seat * CFrame.new(0, 2.2, -0.1)
		figure(sit, W.Navy)
		local hand = raisedArm(sit)
		local handle = box("PaddleHandle", Vector3.new(0.22, 0.9, 0.22), hand * CFrame.new(0, 0.45, 0), W.Steel)
		handle.CanCollide = false
		local paddle = box("ScorePaddle", Vector3.new(2, 1.7, 0.15), hand * CFrame.new(0, 1.75, 0), W.White)
		paddle.CanCollide = false
		sign(paddle, Enum.NormalId.Front, "10", W.HotPink, 40, W.Navy)
		sign(paddle, Enum.NormalId.Back, "10", W.HotPink, 40, W.Navy)
	end

	-- Confetti cannons on the deck's front corners: a navy drum with a pink collar holding a
	-- gold barrel tilted in over the podiums, and confetti already scattered on the deck and
	-- the audience floor.
	for _, side in { -1, 1 } do
		local basePos = Vector3.new(cx + side * 20, deckTop, cz + STAGE.Front - 2)
		disc("CannonBase", 2.8, 1.2, basePos + Vector3.new(0, 0.6, 0), W.Navy)
		disc("CannonCollar", 3.1, 0.3, basePos + Vector3.new(0, 1.25, 0), W.HotPink)
		local from = basePos + Vector3.new(0, 0.5, 0)
		local mouth = basePos + Vector3.new(-side * 1.1, 4.2, -0.7)
		local len = (mouth - from).Magnitude
		local barrel = CFrame.lookAt((from + mouth) / 2, mouth) * CFrame.Angles(0, math.rad(90), 0)
		make("Part", {
			Name = "ConfettiCannon",
			Shape = CYLINDER,
			Size = Vector3.new(len, 1.4, 1.4),
			CFrame = barrel,
			Color = W.Gold,
			Material = Enum.Material.SmoothPlastic,
			Parent = folder,
		})
		for _, along in { 0.2, len / 2 - 0.2 } do
			make("Part", {
				Name = "CannonRing",
				Shape = CYLINDER,
				Size = Vector3.new(0.35, 1.65, 1.65),
				CFrame = barrel * CFrame.new(along, 0, 0),
				Color = W.HotPink,
				CanCollide = false,
				Parent = folder,
			})
		end
	end
	local confettiColors = { W.HotPink, W.Sunny, W.RainbowBlue, W.Mint, W.Grape, W.Orange }
	local seed = 7
	local function rand(): number
		seed = (seed * 1103515245 + 12345) % 2147483648
		return seed / 2147483648
	end
	for i = 1, 18 do
		local x = cx + (rand() * 2 - 1) * (STAGE.HalfW - 2)
		local z = cz + STAGE.Front - 1 - rand() * 6
		local y = deckTop + 0.13
		local bit = box(
			"Confetti",
			Vector3.new(0.6, 0.05, 0.35),
			CFrame.new(x, y, z) * CFrame.Angles(0, rand() * math.pi, 0),
			confettiColors[(i - 1) % #confettiColors + 1]
		)
		bit.CanCollide = false
	end

	-- The fan zone: a blue checker carpet from the barrier to the deck's +Z edge, a dressed
	-- start mark round the spawn pad at the runway's end, a low barrier in front of the stage
	-- (a gap for the runway) and two bleachers of cushioned seats with cheering fans.
	local carpetZ0, carpetZ1 = cz + 2.3, cz + a.sizeZ / 2 - 0.2
	local carpetW, carpetD = SHOW_W - 0.4, carpetZ1 - carpetZ0
	box("AudienceCarpet", Vector3.new(carpetW, 0.04, carpetD), CFrame.new(cx, top + 0.02, (carpetZ0 + carpetZ1) / 2), W.RainbowBlue)
	local cols, rows = 8, 3
	local tileW, tileD = carpetW / cols, carpetD / rows
	for r = 0, rows - 1 do
		for c = 0, cols - 1 do
			if (r + c) % 2 == 0 then
				box(
					"CarpetTile",
					Vector3.new(tileW, 0.03, tileD),
					CFrame.new(cx - carpetW / 2 + tileW * (c + 0.5), top + 0.055, carpetZ0 + tileD * (r + 0.5)),
					W.SkyBlue
				)
			end
		end
	end
	local spawnPos = base.spawn.Position
	disc("StartMarkRim", 9.6, 0.1, Vector3.new(spawnPos.X, top + 0.06, spawnPos.Z), W.HotPink)
	disc("StartMark", 8.4, 0.12, Vector3.new(spawnPos.X, top + 0.08, spawnPos.Z), W.White)

	local barrierZ = cz + 2
	for _, side in { -1, 1 } do
		local x0, x1 = cx + side * 4.5, cx + side * 21
		local midX, len = (x0 + x1) / 2, math.abs(x1 - x0)
		-- A solid panel on a navy plinth (no posts), with a short hot-pink "FAN ZONE" plate on
		-- its upper half near the runway, where the stage view keeps it whole.
		box("FanBarrierBase", Vector3.new(len, 0.5, 1), CFrame.new(midX, top + 0.25, barrierZ), W.Navy)
		local panel = box("FanBarrier", Vector3.new(len, 2.6, 0.4), CFrame.new(midX, top + 1.8, barrierZ), W.White)
		sign(panel, Enum.NormalId.Front, "GO CHAD GO!", W.Blue, 30)
		local plateX = cx + side * 8.6
		box("FanZoneEdge", Vector3.new(7.6, 2.2, 0.15), CFrame.new(plateX, top + 2.05, barrierZ + 0.27), W.Navy)
		local plate = box("FanZonePlate", Vector3.new(7.2, 1.8, 0.15), CFrame.new(plateX, top + 2.05, barrierZ + 0.38), W.HotPink)
		plate.CanCollide = false
		sign(plate, AUDIENCE, "FAN ZONE", W.White, 40, W.Navy)
		box("FanBarrierRail", Vector3.new(len + 0.4, 0.4, 0.6), CFrame.new(midX, top + 3.3, barrierZ), W.HotPink)
	end

	-- Bleachers: three navy risers stepping up away from the stage, a white stripe on each
	-- step's face and four coloured seat cushions per row. `fans` = { row, seat, shirt, finger? }.
	local ROW_D, ROW_H, SEAT_W = 2.2, 0.9, 2.75
	local cushions = { W.HotPink, W.Sunny, W.Mint }
	local function bleacher(x: number, z0: number, fans: { { any } }, backSign: string?)
		for i = 1, 3 do
			local h = ROW_H * i
			local zc = z0 + ROW_D * (i - 0.5)
			box("Bleacher", Vector3.new(11.6, h, ROW_D), CFrame.new(x, top + h / 2, zc), W.Navy)
			box("BleacherStripe", Vector3.new(11.6, 0.25, 0.1), CFrame.new(x, top + h - 0.2, z0 + ROW_D * (i - 1) - 0.04), W.White)
			for s = 1, 4 do
				box(
					"BleacherSeat",
					Vector3.new(SEAT_W - 0.35, 0.3, 1.3),
					CFrame.new(x + (s - 2.5) * SEAT_W, top + h + 0.15, zc - 0.3),
					cushions[i]
				)
			end
		end
		for _, fan in fans do
			local row, seat = fan[1] :: number, fan[2] :: number
			local cf = CFrame.lookAt(
				Vector3.new(x + (seat - 2.5) * SEAT_W, top + ROW_H * row + 0.3, z0 + ROW_D * (row - 0.5) - 0.2),
				Vector3.new(cx, top + ROW_H * row + 0.3, cz + STAGE.PodiumZ)
			)
			figure(cf, fan[3] :: Color3)
			if fan[4] then
				foamFinger(cf, fan[4] :: Color3)
			end
		end
		if backSign then
			local back = box("BleacherBack", Vector3.new(11.6, 2.2, 0.2), CFrame.new(x, top + 1.3, z0 + ROW_D * 3 + 0.1), W.HotPink)
			sign(back, AUDIENCE, backSign, W.White, 30, W.Navy)
		end
	end
	bleacher(cx + 19, cz + 6.4, {
		{ 1, 1, W.HotPink, W.Sunny },
		{ 1, 3, W.Blue },
		{ 2, 2, W.Grape, W.HotPink },
		{ 3, 4, W.Coral, W.Mint },
		{ 3, 1, W.RainbowBlue },
	}, "GO CHAD GO!")
	bleacher(cx - 15, cz + 12.8, {
		{ 1, 4, W.Mint, W.HotPink },
		{ 2, 1, W.HotPink },
		{ 3, 3, W.Blue, W.Sunny },
	}, "FAN CLUB")

	-- A few beach balls around the deck for colour.
	local props = {
		{ Vector3.new(cx - 24.5, top, cz + 21.5), W.Pink },
		{ Vector3.new(cx + 25.5, top, cz - 13), W.Mint },
		{ Vector3.new(cx - 22, top, cz - 1), W.Sunny },
	}
	for _, prop in props do
		local p, color = prop[1], prop[2]
		make("Part", {
			Name = "BeachBall",
			Shape = Enum.PartType.Ball,
			Size = Vector3.one * 2.4,
			CFrame = CFrame.new(p + Vector3.new(0, 1.2, 0)),
			Color = color,
			Parent = folder,
		})
	end

	local function ball(name: string, diameter: number, pos: Vector3, color: Color3, material: Enum.Material?): BasePart
		return make("Part", {
			Name = name,
			Shape = Enum.PartType.Ball,
			Size = Vector3.one * diameter,
			CFrame = CFrame.new(pos),
			Color = color,
			Material = material or Enum.Material.SmoothPlastic,
			CanCollide = false,
			Parent = folder,
		})
	end
	-- A flat two-square star (eight points) at `cf`, in the cf's XY plane.
	local function star(name: string, size: number, cf: CFrame, color: Color3)
		for _, turn in { 0, 45 } do
			local ray = box(name, Vector3.new(size, size, 0.2), cf * CFrame.Angles(0, 0, math.rad(turn)), color, Enum.Material.Neon)
			ray.CanCollide = false
		end
	end
	local BULB = Color3.fromRGB(255, 236, 170)

	-- The green room (lobby) on the +X wing ------------------------------------------------
	local LX = cx + LOBBY.X
	local gx0, gx1 = cx + LOBBY.X0, cx + a.sizeX / 2 - 0.4
	local gw, gd = gx1 - gx0, a.sizeZ - 0.4
	local gmx = (gx0 + gx1) / 2
	box("GreenRoomCarpet", Vector3.new(gw, 0.04, gd), CFrame.new(gmx, top + 0.02, cz), W.Mint)
	-- A bold hot-pink border with a white pinstripe inside it, so the mint reads as a rug.
	local BORDER = 1.6
	for _, side in { -1, 1 } do
		box("GreenRoomBorder", Vector3.new(gw, 0.03, BORDER), CFrame.new(gmx, top + 0.055, cz + side * (gd - BORDER) / 2), W.HotPink)
		box("GreenRoomBorder", Vector3.new(BORDER, 0.03, gd), CFrame.new(gmx + side * (gw - BORDER) / 2, top + 0.055, cz), W.HotPink)
		local inset = BORDER + 0.5
		box("GreenRoomStripe", Vector3.new(gw - 2 * inset, 0.03, 0.3), CFrame.new(gmx, top + 0.055, cz + side * (gd / 2 - inset)), W.White)
		box("GreenRoomStripe", Vector3.new(0.3, 0.03, gd - 2 * inset), CFrame.new(gmx + side * (gw / 2 - inset), top + 0.055, cz), W.White)
	end

	-- A low candy kerb between the fan zone and the green room (open at the STAGE door): a
	-- hot-pink block with a white cap, knee high so it never blocks the view.
	local ropeX = gx0 - 0.3
	for _, span in { { 3.4, a.sizeZ / 2 - 0.4 }, { -(a.sizeZ / 2 - 0.4), -5.8 } } do
		local z0, z1 = cz + span[1], cz + span[2]
		box("LobbyKerb", Vector3.new(0.8, 0.7, z1 - z0), CFrame.new(ropeX, top + 0.35, (z0 + z1) / 2), W.HotPink)
		box("LobbyKerbCap", Vector3.new(1, 0.2, z1 - z0), CFrame.new(ropeX, top + 0.8, (z0 + z1) / 2), W.White)
	end

	-- The boards at the -Z end, flat-on to the lobby spawn: the YOUR BEST strip on top of the
	-- HOW TO PLAY board, both in white frames on two navy posts, with a gold star on top.
	-- They start at BoardX0, so the stage view's right edge stays clear of them.
	local boardZ = cz + LOBBY.BoardZ
	local bx0, bx1 = cx + LOBBY.BoardX0, cx + LOBBY.BoardX1
	local BX, BW = (bx0 + bx1) / 2, bx1 - bx0
	local howY, howH = top + 7.2, 11.2
	local bestY, bestH = top + 16.2, 5.4
	for _, side in { -1, 1 } do
		box(
			"HowToPost",
			Vector3.new(0.9, bestY + bestH / 2 - top, 0.9),
			CFrame.new(BX + side * (BW / 2 - 1.2), (top + bestY + bestH / 2) / 2, boardZ - 0.9),
			W.Navy
		)
	end
	box("HowToFrame", Vector3.new(BW, howH, 0.5), CFrame.new(BX, howY, boardZ - 0.45), W.White)
	local howTo = box("HowToBoard", Vector3.new(BW - 0.6, howH - 0.6, 0.4), CFrame.new(BX, howY, boardZ - 0.2), W.Navy)
	howToPlay(surface(howTo, AUDIENCE, 32, "HowToPlay"))
	box("HowToTrim", Vector3.new(BW, 0.35, 0.6), CFrame.new(BX, howY - howH / 2 - 0.1, boardZ - 0.4), W.HotPink, Enum.Material.Neon)
	box("BestFrame", Vector3.new(BW, bestH, 0.5), CFrame.new(BX, bestY, boardZ - 0.45), W.HotPink)
	local bestFace = box("BestBoardFace", Vector3.new(BW - 0.6, bestH - 0.6, 0.4), CFrame.new(BX, bestY, boardZ - 0.2), W.Navy)
	local board = surface(bestFace, AUDIENCE, 30, "BestBoard")
	bestBoard(board)
	star("BestStar", 2.6, CFrame.new(BX, bestY + bestH / 2 + 1.1, boardZ - 0.45), W.Sunny)

	-- The rehearsal mirror on the +X edge, facing into the lobby: a pink Hollywood frame with
	-- warm bulbs on a navy plinth (four swatches in the flex colours: the buttons work here),
	-- a "PRACTICE" sign on top and the RehearsalSpot pad with two footprints in front.
	local mz = cz + LOBBY.MirrorZ
	local mx = gx1 - 1.2
	box("MirrorPlinth", Vector3.new(2.2, 1, 9.2), CFrame.new(mx, top + 0.5, mz), W.Navy)
	for i = 1, 4 do
		local swatch = box("MirrorSwatch", Vector3.new(0.1, 0.6, 1.2), CFrame.new(mx - 1.12, top + 0.5, mz + (i - 2.5) * 1.8), flexColor(i))
		swatch.CanCollide = false
	end
	box("MirrorFrame", Vector3.new(0.6, 10.2, 8.8), CFrame.new(mx, top + 6.1, mz), W.HotPink)
	local glass = box("RehearsalMirror", Vector3.new(0.2, 9, 7.6), CFrame.new(mx - 0.35, top + 6.1, mz), Color3.fromRGB(206, 232, 255))
	glass.Reflectance = 0.4
	for _, shine in { { 1.6, -1.2, 0.5, 5 }, { 2.7, -0.2, 0.25, 3 } } do
		local streak = box(
			"MirrorShine",
			Vector3.new(0.05, shine[3], shine[4]),
			CFrame.new(mx - 0.48, top + 6.1 + shine[1], mz + shine[2]) * CFrame.Angles(math.rad(40), 0, 0),
			W.White
		)
		streak.Transparency = 0.45
		streak.CanCollide = false
	end
	for k = 0, 4 do
		for _, side in { -1, 1 } do
			ball("MirrorBulb", 0.5, Vector3.new(mx - 0.35, top + 2 + k * 2.05, mz + side * 4.1), BULB, Enum.Material.Neon)
		end
		ball("MirrorBulb", 0.5, Vector3.new(mx - 0.35, top + 10.9, mz - 3.4 + k * 1.7), BULB, Enum.Material.Neon)
	end
	local practice = box("PracticeSign", Vector3.new(0.4, 1.6, 6), CFrame.new(mx, top + 12, mz), W.Sunny)
	sign(practice, WEST, "PRACTICE", W.Navy, 40, W.White)
	local spotPos = Vector3.new(cx + LOBBY.SpotX, top, mz)
	disc("RehearsalRim", 5.4, 0.1, spotPos + Vector3.new(0, 0.07, 0), W.HotPink)
	local rehearsal = disc("RehearsalSpot", 4.6, 0.12, spotPos + Vector3.new(0, 0.09, 0), W.White)
	rehearsal.CanCollide = false
	for _, dz in { -0.6, 0.6 } do
		local foot = box(
			"FootMark",
			Vector3.new(1.4, 0.04, 0.6),
			CFrame.new(spotPos.X + (if dz < 0 then 0.5 else 0), top + 0.17, mz + dz),
			W.HotPink
		)
		foot.CanCollide = false
	end

	-- The rehearsal dance floor under the RehearsalSpot: a white square with pink checker
	-- tiles (corners and centre).
	local floorY = top + 0.05
	box("DanceFloorBorder", Vector3.new(10.8, 0.05, 10.8), CFrame.new(spotPos.X, floorY - 0.005, mz), W.Blue)
	box("DanceFloor", Vector3.new(9.4, 0.06, 9.4), CFrame.new(spotPos.X, floorY, mz), W.White)
	for _, t in { { -1, -1 }, { 1, -1 }, { 0, 0 }, { -1, 1 }, { 1, 1 } } do
		local tile = box("DanceTile", Vector3.new(3, 0.04, 3), CFrame.new(spotPos.X + t[1] * 3.1, floorY + 0.04, mz + t[2] * 3.1), W.Pink)
		tile.CanCollide = false
	end

	-- The lobby spawn: a sunny star mark facing the HOW TO PLAY board.
	local lobbyPos = Vector3.new(LX, top, cz + LOBBY.SpawnZ)
	disc("LobbyMarkRing", 8.8, 0.08, lobbyPos + Vector3.new(0, 0.05, 0), W.HotPink)
	disc("LobbyMarkRim", 7.4, 0.1, lobbyPos + Vector3.new(0, 0.06, 0), W.White)
	disc("LobbyMark", 6.4, 0.12, lobbyPos + Vector3.new(0, 0.08, 0), W.Sunny)
	for _, turn in { 0, 45 } do
		local ray = box(
			"LobbyStar",
			Vector3.new(3, 0.04, 3),
			CFrame.new(lobbyPos + Vector3.new(0, 0.16, 0)) * CFrame.Angles(0, math.rad(turn), 0),
			W.White
		)
		ray.CanCollide = false
	end

	-- A pink path with white edges and glowing "^" chevrons from `from` to `to` (on the floor,
	-- `width` wide); chevrons at the given distances from `from`.
	local function pinkPath(name: string, from: Vector3, to: Vector3, width: number, chevrons: { number })
		local length = (to - from).Magnitude
		local frame = CFrame.lookAt((from + to) / 2, to)
		box(name, Vector3.new(width, 0.1, length), frame + Vector3.new(0, 0.05, 0), W.HotPink)
		for _, side in { -1, 1 } do
			box(name .. "Edge", Vector3.new(0.3, 0.14, length), frame * CFrame.new(side * (width / 2 + 0.15), 0.07, 0), W.White)
		end
		local back = CFrame.lookAt(from, to)
		for _, at in chevrons do
			for _, side in { -1, 1 } do
				local bar = box(
					"PathChevron",
					Vector3.new(0.5, 0.06, 2),
					back * CFrame.new(side * 0.7, 0.13, -at + 0.7) * CFrame.Angles(0, math.rad(side * 45), 0),
					W.Sunny,
					Enum.Material.Neon
				)
				bar.CanCollide = false
			end
		end
	end

	-- The START pad in front of the STAGE door: a big glowing sunny disc with a white star, in
	-- a white rim, a hot-pink glow ring and a navy outline ring that stands it off the mint.
	-- Fx.Pose hides its column, light and label in play.
	local pathZ = cz + LOBBY.PathZ
	local startPos = Vector3.new(cx + LOBBY.X0 + LOBBY.StartIn, top, cz + LOBBY.StartZ)
	-- From the spawn star's pink ring to the START pad's outline ring.
	local toStart = (startPos - lobbyPos).Unit
	local pathLength = (startPos - lobbyPos).Magnitude - 4.4 - 5.6
	pinkPath("LobbyPath", lobbyPos + toStart * 4.4, startPos - toStart * 5.6, 3.6, { pathLength / 2 + 0.3 })
	-- White stepping stones from the spawn star to the dance floor.
	local toSpot = Vector3.new(spotPos.X, top, mz) - lobbyPos
	for _, at in { 6, 9, 12 } do
		local stone = box(
			"SteppingStone",
			Vector3.new(2.2, 0.08, 2.2),
			CFrame.new(lobbyPos + toSpot.Unit * at + Vector3.new(0, 0.06, 0)) * CFrame.Angles(0, math.rad(45), 0),
			W.White
		)
		stone.CanCollide = false
	end
	local startOutline = disc("StartOutline", 11.4, 0.08, startPos + Vector3.new(0, 0.05, 0), W.Navy)
	startOutline.CanCollide = false
	local startRing = disc("StartRing", 10.4, 0.1, startPos + Vector3.new(0, 0.08, 0), W.HotPink, Enum.Material.Neon)
	startRing.CanCollide = false
	local startRim = disc("StartPadRim", 9.2, 0.16, startPos + Vector3.new(0, 0.14, 0), W.White)
	startRim.CanCollide = false
	local startPad = disc("StartPad", 8, 0.2, startPos + Vector3.new(0, 0.2, 0), W.Sunny, Enum.Material.Neon)
	startPad.CanCollide = false
	for _, turn in { 0, 45 } do
		local ray = box(
			"StartStar",
			Vector3.new(4.2, 0.04, 4.2),
			CFrame.new(startPos + Vector3.new(0, 0.32, 0)) * CFrame.Angles(0, math.rad(turn), 0),
			W.White
		)
		ray.CanCollide = false
	end
	local column = disc("StartGlow", 7.6, 4.4, startPos + Vector3.new(0, 2.5, 0), W.Sunny, Enum.Material.Neon)
	column.Transparency = 0.78
	column.CanCollide = false
	column.CanQuery = false
	column.CanTouch = false
	column.CastShadow = false
	local startLight = Instance.new("PointLight")
	startLight.Color = W.Sunny
	startLight.Brightness = 2
	startLight.Range = 16
	startLight.Parent = startPad
	local startLabel = Instance.new("BillboardGui")
	startLabel.Name = "StartLabel"
	startLabel.Size = UDim2.fromScale(8.5, 2.8)
	startLabel.StudsOffset = Vector3.new(0, 5.6, 0)
	startLabel.LightInfluence = 0
	startLabel.MaxDistance = 140
	startLabel.Adornee = startPad
	startLabel.Parent = startPad
	caption(startLabel, "Text", "START", W.Sunny, { 0, 0, 1, 1 }, W.Navy, 4)

	-- The STAGE door at the lobby's inner edge, behind the START pad: navy posts lined with
	-- warm bulbs, a sunny header ("STAGE" toward the lobby, "GREEN ROOM" toward the show) in
	-- a pink border and a gold star on top. Through it a pink path of chevrons runs between
	-- the fan barrier and the stage to the stage steps.
	for _, side in { -1, 1 } do
		local z = pathZ + side * 3.6
		box("StageDoorPost", Vector3.new(1.4, 10.4, 1.4), CFrame.new(ropeX, top + 5.2, z), W.Navy)
		for k = 0, 3 do
			ball("StageDoorBulb", 0.55, Vector3.new(ropeX + 0.75, top + 1.8 + k * 2.4, z), BULB, Enum.Material.Neon)
		end
	end
	box("StageDoorBorder", Vector3.new(0.9, 3.4, 9.6), CFrame.new(ropeX, top + 11.9, pathZ), W.HotPink)
	local doorSign = box("StageDoorSign", Vector3.new(1, 2.8, 9), CFrame.new(ropeX, top + 11.9, pathZ), W.Sunny)
	sign(doorSign, Enum.NormalId.Right, "STAGE", W.Navy, 40, W.White)
	sign(doorSign, WEST, "GREEN ROOM", W.Navy, 40, W.White)
	star("StageDoorStar", 3, CFrame.new(ropeX, top + 14.9, pathZ) * Common.ALONG_Z, W.Sunny)
	local pathX0, pathX1 = cx + 3.3, gx0 + 0.4
	box("StagePath", Vector3.new(pathX1 - pathX0, 0.1, 4), CFrame.new((pathX0 + pathX1) / 2, top + 0.05, pathZ), W.HotPink)
	for _, side in { -1, 1 } do
		box(
			"StagePathEdge",
			Vector3.new(pathX1 - pathX0, 0.14, 0.3),
			CFrame.new((pathX0 + pathX1) / 2, top + 0.07, pathZ + side * 2.15),
			W.White
		)
	end
	for _, x in { 8.5, 14, 19.5, 25 } do
		-- A "<" pointing at the stage (-X): two neon bars meeting at the tip.
		for _, side in { -1, 1 } do
			local bar = box(
				"PathChevron",
				Vector3.new(0.5, 0.06, 2),
				CFrame.new(cx + x + 0.7, top + 0.13, pathZ + side * 0.7) * CFrame.Angles(0, math.rad(90 - side * 45), 0),
				W.Sunny,
				Enum.Material.Neon
			)
			bar.CanCollide = false
		end
	end

	-- The TV-crew corner on the -X wing ----------------------------------------------------
	-- A plank deck with a camera crane aimed at the podiums, an "ON AIR" light, two loungers
	-- under a parasol and a pair of palms.
	local tx0, tx1 = cx - a.sizeX / 2 + 0.4, cx - LOBBY.X0
	box("CrewDeck", Vector3.new(tx1 - tx0, 0.04, gd), CFrame.new((tx0 + tx1) / 2, top + 0.02, cz), W.Wood, Enum.Material.WoodPlanks)
	local dolly = Vector3.new(cx - 40, top, cz + 4)
	box("CraneDolly", Vector3.new(4, 0.8, 4), CFrame.new(dolly + Vector3.new(0, 0.9, 0)), W.Navy)
	for _, wx in { -1.6, 1.6 } do
		for _, wz in { -1.6, 1.6 } do
			ball("CraneWheel", 1.1, dolly + Vector3.new(wx, 0.55, wz), W.Ink)
		end
	end
	disc("CraneColumn", 0.9, 6, dolly + Vector3.new(0, 4.3, 0), W.Steel)
	local pivot = dolly + Vector3.new(0, 7.5, 0)
	ball("CranePivot", 1.5, pivot, W.Navy)
	local aimAt = Vector3.new(cx, deckTop + 5, cz + STAGE.PodiumZ)
	local dir = (aimAt - pivot).Unit
	box("CraneBoom", Vector3.new(0.6, 0.6, 14.5), CFrame.lookAt(pivot + dir * 2.75, pivot + dir * 10), W.Steel)
	box("CraneWeight", Vector3.new(1.6, 1.6, 1.6), CFrame.lookAt(pivot - dir * 4.5, pivot), W.Steel)
	local camPos = pivot + dir * 9.6
	box("TVCamera", Vector3.new(1.8, 1.8, 3), CFrame.lookAt(camPos, camPos + dir), W.Ink)
	local lensPos = camPos + dir * 1.9
	make("Part", {
		Name = "TVCameraLens",
		Shape = CYLINDER,
		Size = Vector3.new(0.9, 1.3, 1.3),
		CFrame = CFrame.lookAt(lensPos, lensPos + dir) * CFrame.Angles(0, math.rad(90), 0),
		Color = W.Navy,
		Parent = folder,
	})
	make("Part", {
		Name = "TVCameraGlass",
		Shape = CYLINDER,
		Size = Vector3.new(0.1, 1, 1),
		CFrame = CFrame.lookAt(lensPos + dir * 0.46, lensPos + dir) * CFrame.Angles(0, math.rad(90), 0),
		Color = W.RainbowBlue,
		Material = Enum.Material.Neon,
		CanCollide = false,
		Parent = folder,
	})
	ball("TVTally", 0.5, camPos + Vector3.new(0, 1.1, 0), W.RainbowRed, Enum.Material.Neon)
	local airPos = Vector3.new(tx0 + 2.6, top, cz - 4)
	box("OnAirPost", Vector3.new(0.4, 6, 0.4), CFrame.new(airPos + Vector3.new(0, 3, 0)), W.Steel)
	box("OnAirBox", Vector3.new(0.7, 2, 5.4), CFrame.new(airPos + Vector3.new(0, 6.6, 0)), W.Ink)
	local onAir =
		box("OnAirSign", Vector3.new(0.3, 1.6, 5), CFrame.new(airPos + Vector3.new(0.4, 6.6, 0)), W.RainbowRed, Enum.Material.Neon)
	sign(onAir, Enum.NormalId.Right, "ON AIR", W.White, 40, W.Ink)
	for i, dz in { 9.5, 15 } do
		local lounger = CFrame.new(cx - 44, top, cz + dz)
		box("Lounger", Vector3.new(5, 0.4, 2.2), lounger * CFrame.new(0.6, 1.1, 0), W.White)
		for _, lx in { -1.5, 2.6 } do
			box("LoungerLeg", Vector3.new(0.4, 0.9, 2), lounger * CFrame.new(lx, 0.45, 0), W.Steel)
		end
		box("LoungerBack", Vector3.new(2.4, 0.4, 2.2), lounger * CFrame.new(-2.3, 1.9, 0) * CFrame.Angles(0, 0, math.rad(-50)), W.White)
		local towel =
			box("LoungerTowel", Vector3.new(4.4, 0.06, 1.6), lounger * CFrame.new(0.8, 1.33, 0), if i == 1 then W.HotPink else W.Sunny)
		towel.CanCollide = false
	end
	local parasol = Vector3.new(cx - 48.5, top, cz + 12.25)
	disc("ParasolPole", 0.35, 7.4, parasol + Vector3.new(0, 3.7, 0), W.White)
	disc("ParasolCanopy", 7.5, 0.4, parasol + Vector3.new(0, 7.4, 0), W.Coral)
	disc("ParasolCanopyTop", 3.6, 0.5, parasol + Vector3.new(0, 7.75, 0), W.White)
	for _, spot in { { tx0 + 2.5, cz - 19 }, { tx0 + 2, cz + 21.5 } } do
		palm(folder, CFrame.new(spot[1], top, spot[2]) * CFrame.Angles(0, spot[2] * 0.1, 0), 14, 0.3)
	end

	-- The deck's edge: a sunny band round the floor, a hot-pink fascia round the hull and a
	-- chunky railing on the rim outside it (fat white posts, a hot-pink top rail and a sunny
	-- mid rail), so the deck reads against the sea from inside and out.
	local hx, hz = a.sizeX / 2, a.sizeZ / 2
	for _, side in { -1, 1 } do
		box("DeckEdge", Vector3.new(a.sizeX, 0.1, 1), CFrame.new(cx, top + 0.05, cz + side * (hz - 0.5)), W.Sunny)
		box("DeckEdge", Vector3.new(1, 0.1, a.sizeZ - 2), CFrame.new(cx + side * (hx - 0.5), top + 0.05, cz), W.Sunny)
		box("DeckFascia", Vector3.new(a.sizeX + 2.6, 1.6, 0.3), CFrame.new(cx, top - 1.5, cz + side * (hz + 1.15)), W.HotPink)
		box("DeckFascia", Vector3.new(0.3, 1.6, a.sizeZ + 2), CFrame.new(cx + side * (hx + 1.15), top - 1.5, cz), W.HotPink)
	end
	local rx, rz = hx + 0.5, hz + 0.5
	local function rail(name: string, length: number, diameter: number, y: number, cf: CFrame, color: Color3)
		make("Part", {
			Name = name,
			Shape = CYLINDER,
			Size = Vector3.new(length, diameter, diameter),
			CFrame = cf + Vector3.new(0, y, 0),
			Color = color,
			Parent = folder,
		})
	end
	for _, side in { -1, 1 } do
		for k = 0, 16 do
			disc("RailPost", 1.2, 4.5, Vector3.new(cx - rx + 2 * rx * k / 16, top + 1.35, cz + side * rz), W.White)
		end
		for k = 1, 7 do
			disc("RailPost", 1.2, 4.5, Vector3.new(cx + side * rx, top + 1.35, cz - rz + 2 * rz * k / 8), W.White)
		end
		local alongX = CFrame.new(cx, 0, cz + side * rz)
		local alongZ = CFrame.new(cx + side * rx, 0, cz) * Common.ALONG_Z
		rail("RailTop", 2 * rx + 1.2, 1.2, top + 3.4, alongX, W.HotPink)
		rail("RailTop", 2 * rz + 1.2, 1.2, top + 3.4, alongZ, W.HotPink)
		rail("RailMid", 2 * rx, 0.6, top + 1.8, alongX, W.Sunny)
		rail("RailMid", 2 * rz, 0.6, top + 1.8, alongZ, W.Sunny)
	end

	buildSea(folder, cx, cz)

	local rival = Instance.new("Model")
	rival.Name = "Rival"
	rival.Parent = folder
	local built: any = base
	built.lobbySpawn = CFrame.new(lobbyPos) -- identity rotation: looks -Z, at the board
	built.startPad = startPad
	built.startRadius = START_RADIUS
	built.board = board
	-- Rotated a quarter turn about Y: LookVector (1, 0, 0), into the mirror.
	built.mirrorSpot = CFrame.new(spotPos) * CFrame.Angles(0, -math.pi / 2, 0)
	built.playerSpot = CFrame.lookAt(playerPos, playerPos + facing)
	built.rivalSpot = CFrame.lookAt(rivalPos, rivalPos + facing)
	built.playerSpots = {}
	for _, pos in lanePos do
		table.insert(built.playerSpots, CFrame.lookAt(pos, pos + facing))
	end
	built.rival = rival
	return built :: Built
end

return PoseStage
