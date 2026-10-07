--[[
	Modes: the GAME MODES plaza on the hub's -X side and the Parkour levels out over the sea.

	Everything is placed from Server.Modes.Course (layout numbers) and Server.Modes.Catalog
	(one gate per mode slot). The server builds every part at its rest pose and never moves
	it; moving obstacles only carry attributes and Client code animates them:

	  Moving parts (tag "ModeMover"), anchored, attributes on the root part:
	    Mover        "slide" | "bob" | "spin"
	    MoveAxis     Vector3, unit world axis (slide/bob; bob is always 0, 1, 0)
	    MoveDistance studs: slide/bob travel +-MoveDistance from the rest position
	    MovePeriod   seconds per full back-and-forth cycle (slide/bob)
	    MoveSpeed    rad/s about the world up axis through the rest position (spin)
	    MovePhase    radians
	  With t = workspace:GetServerTimeNow() and rest = the part's CFrame as built:
	    slide/bob: CFrame = rest + MoveAxis * MoveDistance * sin(2*pi*t / MovePeriod + MovePhase)
	    spin:      CFrame = CFrame.new(rest.Position) * CFrame.Angles(0, MoveSpeed*t + MovePhase, 0) * rest.Rotation
	  Every BasePart descendant of the root moves rigidly with it. Spinner bars are
	  "SpinnerBar" roots with CanCollide = false and attribute Hazard = "bump": touching one
	  should give the local player a gentle push away and a small hop.
	  Bounce pads: parts named "BouncePad" (tag "BouncePad"), attribute Bounce = upward launch
	  speed in studs/s for the local player.

	  Blink pads: "BlinkPad" box tops (tag "BlinkPad"; rim, underside, chevron and a Neon
	  "BlinkGlow" band are its descendants), attributes BlinkOn, BlinkPeriod, BlinkPhase
	  (seconds): solid when ((t + BlinkPhase) % BlinkPeriod) < BlinkOn. The server never
	  toggles them; Client.Fx.Modes sets CanCollide and the look locally.

	Every level of Server.Modes.Course is built into Parkour/Level<i> (attributes Mode,
	Level, Checkpoints, Title). Named parts the game looks up: "ParkourStart" (trigger in
	gate 1's opening; other open gates hold "ModeStart"), per level "ParkourFinish" (trigger
	over the finish deck) and "ParkourWater" (catch volume over the sea), both with attribute
	Level, and "Checkpoint" discs with attributes Index (1..n), Level and Mode = "parkour".
	Every level is reached by teleport through gate 1's portal and gets a LEVEL <i> start
	arch on its start deck; nothing of the course stands next to the plaza.
	Client hints (Client.Fx.Modes): each open gate's "GateArrow" root (tag "ModeHintArrow",
	attribute HintBob = bob height in studs, children move with it) and each checkpoint's
	"FlagCap" (attribute Checkpoint = its index).

	Sign text is TextScaled; every sign face's PixelsPerStud is picked so its biggest label
	lands near 100 px tall (TextScaled's ceiling), which keeps it crisp without wasting texture.
	Part of the world generator; see Server.WorldBuilder for the overview.
]]

local Common = require(script.Parent.Common)
local Course = require(script.Parent.Parent.Modes.Course)
local Catalog = require(script.Parent.Parent.Modes.Catalog)

local theme = Common.theme
local mapFolder = Common.mapFolder
local make = Common.make
local UPRIGHT = Common.UPRIGHT
local ALONG_Z = Common.ALONG_Z

local W = theme.World
local CYLINDER = Enum.PartType.Cylinder
local BALL = Enum.PartType.Ball
-- Yaw that turns a frame's front (-Z) toward +X (the hub).
local FACE_HUB = -math.pi / 2

local FLAG_COLORS = { W.Coral, W.Sunny, W.Mint, W.Blue, W.Pink, W.Grape }
-- Locked gates: desaturated blue-grey, and the mid grey card behind their white text.
local LOCKED = W.Steel
local LOCKED_CARD = W.Steel:Lerp(W.Ink, 0.3)
-- Half the bar-filled opening of a locked gate (the open gate uses Course.GATE_HALF).
local LOCKED_HALF = 4
-- Sea foam sits just above the shallows / ocean surface.
local FOAM_Y = -0.8

export type Built = {
	folder: Folder,
	-- Rich-text list on the best-times board (Server.GameModes fills it).
	bestList: TextLabel,
}

local Modes = {}

-- Helpers -------------------------------------------------------------------------------

local function cube(d: number): Vector3
	return Vector3.new(d, d, d)
end

local function color(key: string?): Color3
	return (key and W[key]) or W.White
end

local function decor(p: BasePart): BasePart
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	return p
end

-- An invisible trigger volume (touch only).
local function trigger(name: string, cframe: CFrame, size: Vector3, parent: Instance): BasePart
	local p = make("Part", {
		Name = name,
		Size = size,
		CFrame = cframe,
		Transparency = 1,
		CanCollide = false,
		CanQuery = false,
		CastShadow = false,
		Parent = parent,
	})
	p.CanTouch = true
	return p
end

local function surface(p: BasePart, face: Enum.NormalId, pixelsPerStud: number): Frame
	local gui = Instance.new("SurfaceGui")
	gui.Face = face
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = pixelsPerStud
	gui.LightInfluence = 0
	gui.Parent = p
	local root = Instance.new("Frame")
	root.Size = UDim2.fromScale(1, 1)
	root.BackgroundTransparency = 1
	root.BorderSizePixel = 0
	root.Parent = gui
	return root
end

local function panel(parent: Instance, fill: Color3, position: UDim2, size: UDim2, corner: number?): Frame
	local f = Instance.new("Frame")
	f.BackgroundColor3 = fill
	f.BorderSizePixel = 0
	f.Position = position
	f.Size = size
	f.Parent = parent
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(corner or 0.08, 0)
	c.Parent = f
	return f
end

local function text(parent: Instance, props: { [string]: any }): TextLabel
	local l = Instance.new("TextLabel")
	l.BackgroundTransparency = 1
	l.TextScaled = true
	l.Font = theme.Fonts.Display
	l.TextColor3 = W.Ink
	l.Size = UDim2.fromScale(1, 1)
	for key, value in props do
		(l :: any)[key] = value
	end
	l.Parent = parent
	return l
end

-- A sign card face: cream/white card, coloured header band with `header` text and a big
-- Ink `title` below.
local function cardFace(
	p: BasePart,
	face: Enum.NormalId,
	pps: number,
	fill: Color3,
	band: Color3,
	header: string,
	title: string,
	faded: boolean?
)
	local root = surface(p, face, pps)
	local card = panel(root, fill, UDim2.fromScale(0.02, 0.04), UDim2.fromScale(0.96, 0.92), 0.1)
	local head = panel(card, band, UDim2.fromScale(0.04, 0.06), UDim2.fromScale(0.92, 0.3), 0.5)
	text(head, { Text = header, TextColor3 = W.White, Size = UDim2.fromScale(0.92, 0.76), Position = UDim2.fromScale(0.04, 0.12) })
	text(card, {
		Text = title,
		TextTransparency = if faded then 0.35 else 0,
		Size = UDim2.fromScale(0.92, 0.54),
		Position = UDim2.fromScale(0.04, 0.4),
	})
end

-- A locked gate's card face: `title` in white on the mid grey card, with a soft Ink outline
-- so it stays clear from across the plaza.
local function lockedFace(p: BasePart, face: Enum.NormalId, pps: number, title: string)
	local root = surface(p, face, pps)
	local card = panel(root, LOCKED_CARD, UDim2.fromScale(0.02, 0.04), UDim2.fromScale(0.96, 0.92), 0.14)
	local label = text(card, {
		Text = title,
		TextColor3 = W.White,
		Size = UDim2.fromScale(0.88, 0.8),
		Position = UDim2.fromScale(0.06, 0.1),
	})
	local outline = Instance.new("UIStroke")
	outline.Color = W.Ink
	outline.Thickness = 2
	outline.Transparency = 0.45
	outline.Parent = label
end

-- An invisible flat carrier part for a crisp text layer laid over a sign card.
local function carrier(add: (props: { [string]: any }) -> BasePart, name: string, cframe: CFrame, size: Vector3): BasePart
	return decor(add({ Name = name, Size = size, CFrame = cframe, Transparency = 1, CastShadow = false }))
end

-- Builder for parts in a local frame: props.CFrame is relative to `base`.
local function adder(base: CFrame, parent: Instance): (props: { [string]: any }, className: string?) -> BasePart
	return function(props: { [string]: any }, className: string?): BasePart
		props.CFrame = base * (props.CFrame or CFrame.new())
		props.Parent = props.Parent or parent
		return make(className or "Part", props)
	end
end

-- A flag pole with a "Flag" card (swayed by Client.Fx.Ambient) showing `label`. `big` makes
-- the chunky checkpoint flag (larger cloth, number readable from the next platform).
local function flagPole(
	x: number,
	y: number,
	z: number,
	height: number,
	flagColor: Color3,
	label: string?,
	along: number,
	parent: Instance,
	big: boolean?
): BasePart
	local scale = if big then 1.55 else 1
	make("Part", {
		Name = "FlagPole",
		Shape = CYLINDER,
		Size = Vector3.new(height, 0.7 * scale, 0.7 * scale),
		CFrame = CFrame.new(x, y + height / 2, z) * UPRIGHT,
		Color = W.White,
		Parent = parent,
	})
	local cap = decor(make("Part", {
		Name = "FlagCap",
		Shape = BALL,
		Size = cube(1.3 * scale),
		CFrame = CFrame.new(x, y + height + 0.3 * scale, z),
		Color = W.Sunny,
		Parent = parent,
	}))
	local clothSize = Vector3.new(3.8, 2.8, 0.25) * Vector3.new(scale, scale, 1)
	local hingeCF = CFrame.new(x, y + height - 0.4 * scale, z) * CFrame.Angles(0, along, 0)
	local flag = Instance.new("Model")
	flag.Name = "Flag"
	local hinge = make("Part", {
		Name = "FlagHinge",
		Size = cube(0.2),
		CFrame = hingeCF,
		Transparency = 1,
		CastShadow = false,
		Parent = flag,
	})
	decor(hinge)
	flag.PrimaryPart = hinge
	local card = decor(make("Part", {
		Name = "FlagCloth",
		Size = clothSize,
		CFrame = hingeCF * CFrame.new(clothSize.X / 2 + 0.3 * scale, -clothSize.Y / 2, 0),
		Color = flagColor,
		CastShadow = false,
		Parent = flag,
	}))
	if label then
		-- A white disc filling most of the cloth with a big Ink number (label ~100 px tall).
		local pps = if big then 32 else 40
		local dotW = clothSize.Y * 0.88 / clothSize.X
		for _, face in { Enum.NormalId.Front, Enum.NormalId.Back } do
			local root = surface(card, face, pps)
			local dot = panel(root, W.White, UDim2.fromScale((1 - dotW) / 2, 0.06), UDim2.fromScale(dotW, 0.88), 0.5)
			text(dot, { Text = label, Size = UDim2.fromScale(0.8, 0.8), Position = UDim2.fromScale(0.1, 0.12) })
		end
	end
	flag.Parent = parent
	return cap
end

-- Platforms -----------------------------------------------------------------------------

-- A warm candy-top platform: the coloured top, a white rim band just below it and a deeper
-- teal underside that grounds it over the sea. Returns the top part (named `name`); rim and
-- underside are parented to it when `rimInTop` (movers carry them).
local UNDERSIDE = 2.4
local function platform(e: Course.Element, name: string, parent: Instance, rimInTop: boolean): BasePart
	local fill = color(e.color)
	local material = if e.color == "Wood" then Enum.Material.WoodPlanks else Enum.Material.SmoothPlastic
	local rimY, underY = e.y - 0.95, e.y - 1.3 - UNDERSIDE / 2 + 0.1
	local top: BasePart
	if e.shape == "disc" then
		local r = e.r :: number
		top = make("Part", {
			Name = name,
			Shape = CYLINDER,
			Size = Vector3.new(1.2, r * 2, r * 2),
			CFrame = CFrame.new(e.x, e.y - 0.6, e.z) * UPRIGHT,
			Color = fill,
			Material = material,
			Parent = parent,
		})
		make("Part", {
			Name = "PlatformRim",
			Shape = CYLINDER,
			Size = Vector3.new(0.7, r * 2 + 1.2, r * 2 + 1.2),
			CFrame = CFrame.new(e.x, rimY, e.z) * UPRIGHT,
			Color = W.White,
			Parent = if rimInTop then top else parent,
		})
		decor(make("Part", {
			Name = "PlatformBase",
			Shape = CYLINDER,
			Size = Vector3.new(UNDERSIDE, r * 2 - 0.8, r * 2 - 0.8),
			CFrame = CFrame.new(e.x, underY, e.z) * UPRIGHT,
			Color = W.TealDeep,
			Parent = if rimInTop then top else parent,
		}))
	else
		local sx, sz = e.sx :: number, e.sz :: number
		top = make("Part", {
			Name = name,
			Size = Vector3.new(sx, 1.2, sz),
			CFrame = CFrame.new(e.x, e.y - 0.6, e.z),
			Color = fill,
			Material = material,
			Parent = parent,
		})
		make("Part", {
			Name = "PlatformRim",
			Size = Vector3.new(sx + 1.2, 0.7, sz + 1.2),
			CFrame = CFrame.new(e.x, rimY, e.z),
			Color = W.White,
			Parent = if rimInTop then top else parent,
		})
		decor(make("Part", {
			Name = "PlatformBase",
			Size = Vector3.new(math.max(sx - 0.8, 1), UNDERSIDE, math.max(sz - 0.8, 1)),
			CFrame = CFrame.new(e.x, underY, e.z),
			Color = W.TealDeep,
			Parent = if rimInTop then top else parent,
		}))
	end
	return top
end

-- A soft white foam patch on the water under a platform out at sea (its rest footprint).
local function foam(e: Course.Element, parent: Instance)
	if e.x * e.x + e.z * e.z <= Course.WATER_RADIUS * Course.WATER_RADIUS then
		return
	end
	local props: { [string]: any } = {
		Name = "PlatformFoam",
		Color = W.White,
		Transparency = 0.35,
		CastShadow = false,
		Parent = parent,
	}
	if e.shape == "disc" then
		local d = (e.r :: number) * 2 + 4
		props.Shape = CYLINDER
		props.Size = Vector3.new(0.1, d, d)
		props.CFrame = CFrame.new(e.x, FOAM_Y, e.z) * UPRIGHT
	else
		props.Size = Vector3.new((e.sx :: number) + 3, 0.1, (e.sz :: number) + 3)
		props.CFrame = CFrame.new(e.x, FOAM_Y, e.z)
	end
	decor(make("Part", props))
end

-- A flat teal chevron painted on a platform top near its exit edge, pointing at the next path
-- element, so the route reads as one continuous line. Parented to `parent` (the mover's top
-- for moving platforms, so it rides along).
local CHEVRON_ARM = 1.4
local function chevron(e: Course.Element, nextE: Course.Element, parent: Instance)
	local dx, dz = nextE.x - e.x, nextE.z - e.z
	local length = math.sqrt(dx * dx + dz * dz)
	if length < 1e-3 then
		return
	end
	dx, dz = dx / length, dz / length
	local edge: number
	if e.shape == "disc" then
		edge = e.r :: number
	else
		local hx, hz = (e.sx :: number) / 2, (e.sz :: number) / 2
		edge = math.min(if dx ~= 0 then hx / math.abs(dx) else math.huge, if dz ~= 0 then hz / math.abs(dz) else math.huge)
	end
	local reach = math.max(edge - 1.6, 0)
	local at = Vector3.new(e.x + dx * reach, e.y + 0.06, e.z + dz * reach)
	local frame = CFrame.lookAt(at, at + Vector3.new(dx, 0, dz))
	local a = CHEVRON_ARM
	local arm = a * math.sqrt(2) + 0.35
	-- Apex forward (-Z), arms trailing back to either side.
	for _, side in { -1, 1 } do
		decor(make("Part", {
			Name = "Chevron",
			Size = Vector3.new(arm, 0.12, 0.7),
			CFrame = frame * CFrame.new(side * a / 2, 0, -0.8 + a / 2) * CFrame.Angles(0, -side * math.pi / 4, 0),
			Color = W.Teal,
			CastShadow = false,
			Parent = parent,
		}))
	end
end

-- `midZ` splits the level's lanes: flags hang on the side away from it (the outer edge).
local function checkpoint(e: Course.Element, parent: Instance, levelIndex: number, midZ: number): BasePart
	local index = e.index :: number
	local top = platform(e, "Checkpoint", parent, false)
	top:SetAttribute("Index", index)
	top:SetAttribute("Level", levelIndex)
	top:SetAttribute("Mode", "parkour")
	-- Big number painted on the disc (an upright cylinder's top is its +X face).
	local root = surface(top, Enum.NormalId.Right, 24)
	local dot = panel(root, W.Sunny, UDim2.fromScale(0.28, 0.28), UDim2.fromScale(0.44, 0.44), 0.5)
	text(dot, { Text = tostring(index), Size = UDim2.fromScale(0.7, 0.7), Position = UDim2.fromScale(0.15, 0.17) })
	-- Big numbered flag on the lane's outer edge, hanging along the course.
	local side = if e.z > midZ then 1 else -1
	local cap = flagPole(
		e.x,
		e.y,
		e.z + side * ((e.r :: number) - 1.4),
		12,
		FLAG_COLORS[(index - 1) % #FLAG_COLORS + 1],
		tostring(index),
		0,
		parent,
		true
	)
	cap:SetAttribute("Checkpoint", index)
	cap:SetAttribute("Level", levelIndex)
	return top
end

-- A pad that is solid only part of the time (Client.Fx.Modes toggles it locally): a normal
-- platform in the palette's blink colour with its rim and underside parented to the top,
-- plus a thin glowing Neon band round its edge so it reads as "this one blinks".
local function blink(e: Course.Element, parent: Instance): BasePart
	local top = platform(e, "BlinkPad", parent, true)
	local sx, sz = e.sx :: number, e.sz :: number
	decor(make("Part", {
		Name = "BlinkGlow",
		Size = Vector3.new(sx + 0.5, 0.3, sz + 0.5),
		CFrame = CFrame.new(e.x, e.y - 0.3, e.z),
		Color = color(e.color):Lerp(W.White, 0.35),
		Material = Enum.Material.Neon,
		CastShadow = false,
		Parent = top,
	}))
	top:SetAttribute("BlinkOn", e.on)
	top:SetAttribute("BlinkPeriod", e.period)
	top:SetAttribute("BlinkPhase", e.phase or 0)
	top:AddTag("BlinkPad")
	return top
end

local function mover(e: Course.Element, parent: Instance): BasePart
	local top = platform(e, "MovingPlatform", parent, true)
	local axis = e.axis :: { number }
	top:SetAttribute("Mover", e.motion)
	top:SetAttribute("MoveAxis", Vector3.new(axis[1], axis[2], axis[3]))
	top:SetAttribute("MoveDistance", e.distance)
	top:SetAttribute("MovePeriod", e.period)
	top:SetAttribute("MovePhase", e.phase or 0)
	top:AddTag("ModeMover")
	-- Arrow stripes on top hint the direction of travel.
	local along = if axis[3] ~= 0 then ALONG_Z else CFrame.new()
	if e.motion == "bob" then
		make("Part", {
			Name = "MoverStripe",
			Shape = CYLINDER,
			Size = Vector3.new(0.1, 4, 4),
			CFrame = CFrame.new(e.x, e.y + 0.02, e.z) * UPRIGHT,
			Color = W.White,
			Parent = top,
		})
	else
		make("Part", {
			Name = "MoverStripe",
			Size = Vector3.new((e.sx :: number) - 1.6, 0.1, 1.2),
			CFrame = CFrame.new(e.x, e.y + 0.02, e.z) * along,
			Color = W.White,
			Parent = top,
		})
	end
	return top
end

local function spinner(e: Course.Element, parent: Instance)
	local length = e.length :: number
	make("Part", {
		Name = "SpinnerPost",
		Shape = CYLINDER,
		Size = Vector3.new(1.2, 1.6, 1.6),
		CFrame = CFrame.new(e.x, e.y + 0.6, e.z) * UPRIGHT,
		Color = W.White,
		Parent = parent,
	})
	local bar = make("Part", {
		Name = "SpinnerBar",
		Shape = CYLINDER,
		Size = Vector3.new(length, 1.1, 1.1),
		CFrame = CFrame.new(e.x, e.y + 1.75, e.z),
		Color = W.Coral,
		CanCollide = false,
		Parent = parent,
	})
	bar.CanQuery = false
	bar:SetAttribute("Mover", "spin")
	bar:SetAttribute("MoveSpeed", e.speed)
	bar:SetAttribute("MovePhase", e.phase or 0)
	bar:SetAttribute("Hazard", "bump")
	bar:AddTag("ModeMover")
	decor(
		make(
			"Part",
			{ Name = "SpinnerHub", Shape = BALL, Size = cube(2), CFrame = CFrame.new(e.x, e.y + 1.75, e.z), Color = W.Sunny, Parent = bar }
		)
	)
	for _, sx in { -1, 1 } do
		decor(make("Part", {
			Name = "SpinnerEnd",
			Shape = BALL,
			Size = cube(1.7),
			CFrame = CFrame.new(e.x + sx * length / 2, e.y + 1.75, e.z),
			Color = W.White,
			Parent = bar,
		}))
	end
end

local function bounce(e: Course.Element, parent: Instance)
	local r = e.r :: number
	make("Part", {
		Name = "BounceRing",
		Shape = CYLINDER,
		Size = Vector3.new(0.5, r * 2 + 1, r * 2 + 1),
		CFrame = CFrame.new(e.x, e.y + 0.2, e.z) * UPRIGHT,
		Color = W.White,
		Parent = parent,
	})
	local pad = make("Part", {
		Name = "BouncePad",
		Shape = CYLINDER,
		Size = Vector3.new(0.7, r * 2, r * 2),
		CFrame = CFrame.new(e.x, e.y + 0.35, e.z) * UPRIGHT,
		Color = W.Coral,
		Parent = parent,
	})
	pad:SetAttribute("Bounce", e.power)
	pad:AddTag("BouncePad")
end

local function wall(e: Course.Element, parent: Instance)
	local h, sx, sz = e.h :: number, e.sx :: number, e.sz :: number
	make("Part", {
		Name = "HopWall",
		Size = Vector3.new(sx, h - sx / 2, sz),
		CFrame = CFrame.new(e.x, e.y + (h - sx / 2) / 2, e.z),
		Color = color(e.color),
		Parent = parent,
	})
	-- Rounded white cap.
	make("Part", {
		Name = "HopWallCap",
		Shape = CYLINDER,
		Size = Vector3.new(sz, sx + 0.3, sx + 0.3),
		CFrame = CFrame.new(e.x, e.y + h - sx / 2, e.z) * ALONG_Z,
		Color = W.White,
		Parent = parent,
	})
end

-- The finish slide: a ramp between two top-surface points with low guard rails and legs.
local function slide(e: Course.Element, parent: Instance)
	local from, to = e.from :: { number }, e.to :: { number }
	local a = Vector3.new(from[1], from[2], from[3])
	local b = Vector3.new(to[1], to[2], to[3])
	local d = b - a
	local flat = math.sqrt(d.X * d.X + d.Z * d.Z)
	local yaw = math.atan2(-d.Z, d.X)
	local pitch = math.atan2(d.Y, flat)
	local frame = CFrame.new((a + b) / 2) * CFrame.Angles(0, yaw, 0) * CFrame.Angles(0, 0, pitch)
	local width = e.width :: number
	local ramp = make("Part", {
		Name = "Slide",
		Size = Vector3.new(d.Magnitude, 1, width),
		CFrame = frame * CFrame.new(0, -0.5, 0),
		Color = color(e.color),
		Parent = parent,
	})
	ramp:SetAttribute("Slide", true)
	for _, sz in { -1, 1 } do
		make("Part", {
			Name = "SlideRail",
			Shape = CYLINDER,
			Size = Vector3.new(d.Magnitude, 1.4, 1.4),
			CFrame = frame * CFrame.new(0, 0.9, sz * (width / 2 + 0.5)),
			Color = W.White,
			Parent = parent,
		})
	end
	for _, t in { 0.3, 0.7 } do
		local p = a:Lerp(b, t)
		local height = p.Y - 1 + 1.2
		make("Part", {
			Name = "SlideLeg",
			Shape = CYLINDER,
			Size = Vector3.new(height, 1.6, 1.6),
			CFrame = CFrame.new(p.X, -1.2 + height / 2, p.Z) * UPRIGHT,
			Color = W.Teal,
			Parent = parent,
		})
	end
end

-- Gates and signs -------------------------------------------------------------------------

-- The open gate's hint arrow: a chunky coral arrow pointing down into the opening. The shaft
-- is the root (tag "ModeHintArrow", HintBob = bob height); Client.Fx.Modes bobs it, with the
-- arms and tip parented to it, while the player is near the plaza and not on a run.
local function gateArrow(add: (props: { [string]: any }) -> BasePart, tipY: number, tint: Color3)
	local a, thick = 1.9, 1.3
	local root = decor(add({
		Name = "GateArrow",
		Size = Vector3.new(thick, 4.2, 1),
		CFrame = CFrame.new(0, tipY + 2.5, 0),
		Color = tint,
	}))
	root:SetAttribute("HintBob", 0.8)
	root:AddTag("ModeHintArrow")
	for _, side in { -1, 1 } do
		decor(add({
			Name = "GateArrowArm",
			Size = Vector3.new(a * math.sqrt(2) + 0.5, thick, 1),
			CFrame = CFrame.new(side * a / 2, tipY + a / 2, 0) * CFrame.Angles(0, 0, side * math.pi / 4),
			Color = tint,
			Parent = root,
		}))
	end
	decor(add({
		Name = "GateArrowTip",
		Shape = BALL,
		Size = cube(thick * 1.1),
		CFrame = CFrame.new(0, tipY + 0.2, 0),
		Color = tint,
		Parent = root,
	}))
end

-- Portal colours per open mode (ring colour, alternate segment colour).
local PORTAL_COLORS: { [string]: { Color3 } } = {
	parkour = { W.Coral, W.Sunny },
	mog = { W.Grape, W.Pink },
}

-- A swirling portal standing upright in an open gate's opening (gate frame `base`, front
-- facing -Z): a faint Neon disc and three concentric rings of Neon segments, each ring its
-- own model spinning about the gate's through-axis (Client.Fx.Ambient turns models with a
-- Spin attribute about their pivot's up axis, which here points through the opening).
local PORTAL_RINGS = {
	{ r = 5.2, n = 10, spin = 1.2, transparency = 0.3 },
	{ r = 3.9, n = 8, spin = -1.8, transparency = 0.45 },
	{ r = 2.6, n = 6, spin = 2.6, transparency = 0.6 },
}
local function portal(base: CFrame, centreY: number, colors: { Color3 }, parent: Instance)
	local axisFrame = base * CFrame.new(0, centreY, 0.9) * CFrame.Angles(math.pi / 2, 0, 0)
	decor(make("Part", {
		Name = "PortalVeil",
		Shape = CYLINDER,
		Size = Vector3.new(0.2, 11, 11),
		CFrame = base * CFrame.new(0, centreY, 1.1) * CFrame.Angles(0, math.pi / 2, 0),
		Color = colors[1]:Lerp(W.White, 0.5),
		Material = Enum.Material.Neon,
		Transparency = 0.82,
		CastShadow = false,
		Parent = parent,
	}))
	for i, ring in PORTAL_RINGS do
		local model = Instance.new("Model")
		model.Name = "PortalRing"
		model:SetAttribute("Spin", ring.spin)
		local hub = decor(make("Part", {
			Name = "PortalHub",
			Size = cube(0.2),
			CFrame = axisFrame,
			Transparency = 1,
			CastShadow = false,
			Parent = model,
		}))
		model.PrimaryPart = hub
		local arc = 2 * ring.r * math.sin(math.pi / ring.n) * 0.72
		for k = 0, ring.n - 1 do
			local a = 2 * math.pi * k / ring.n + i * 0.4
			decor(make("Part", {
				Name = "PortalSegment",
				Size = Vector3.new(0.55, 0.3, arc),
				CFrame = axisFrame * CFrame.new(ring.r * math.cos(a), 0, ring.r * math.sin(a)) * CFrame.Angles(0, -a, 0),
				Color = colors[(k + i) % 2 + 1],
				Material = Enum.Material.Neon,
				Transparency = ring.transparency,
				CastShadow = false,
				Parent = model,
			}))
		end
		model.Parent = parent
	end
end

-- A gate on the plaza's west edge, front facing the hub. Every enabled entry is a big open
-- gate in its catalog colour (gate 1 PARKOUR stays sunny) holding its start trigger, the
-- hint arrow and a swirling portal (walking through teleports; the server handles it); locked gates are
-- smaller, blue-grey, closed with bars and a friendly padlock under a COMING SOON card.
local function gate(entry: Catalog.Entry, parent: Instance)
	local spot = Course.GATES[entry.slot]
	local folder = Instance.new("Model")
	folder.Name = "Gate" .. entry.slot
	folder:SetAttribute("Mode", entry.id)
	folder:SetAttribute("Enabled", entry.enabled)
	folder.Parent = parent
	local base = CFrame.new(Course.GATE_X, Course.PLAZA.top, spot.z) * CFrame.Angles(0, FACE_HUB, 0)
	local add = adder(base, folder)
	local open = entry.enabled
	local tint = color(entry.color)
	local body = if not open then LOCKED elseif entry.id == "parkour" then W.Sunny else tint:Lerp(W.White, 0.2)
	local trim = if open then W.White else W.Chrome
	-- Gate 1 is the biggest; other open gates are a little smaller so the signs of
	-- neighbouring open gates never touch.
	local main = entry.slot == 1
	local height = if not open then 13 elseif main then 16 else 15
	local thick = if open then 3.6 else 3
	local half = (if open then Course.GATE_HALF else LOCKED_HALF) + thick / 2
	for _, sx in { -1, 1 } do
		local x = sx * half
		add({
			Name = "GateFoot",
			Shape = CYLINDER,
			Size = Vector3.new(1.2, thick + 1.2, thick + 1.2),
			CFrame = CFrame.new(x, 0.6, 0) * UPRIGHT,
			Color = trim,
		})
		add({
			Name = "GatePillar",
			Shape = CYLINDER,
			Size = Vector3.new(height, thick, thick),
			CFrame = CFrame.new(x, height / 2, 0) * UPRIGHT,
			Color = body,
		})
		for _, y in { height * 0.28, height * 0.6 } do
			add({
				Name = "GateRing",
				Shape = CYLINDER,
				Size = Vector3.new(0.9, thick + 0.6, thick + 0.6),
				CFrame = CFrame.new(x, y, 0) * UPRIGHT,
				Color = trim,
			})
		end
	end
	local beamH = if open then 2.4 else 2
	add({
		Name = "GateBeam",
		Size = Vector3.new(half * 2 + thick, beamH, thick - 0.6),
		CFrame = CFrame.new(0, height - beamH / 2, 0),
		Color = body,
	})
	-- The name card sits on the beam, framed by a trim-coloured backing.
	local sw, sh = if not open then 12 elseif main then 20 else 15, if not open then 6.5 elseif main then 8.5 else 7.5
	local sy = height + 0.3 + sh / 2
	decor(add({ Name = "GateSignBack", Size = Vector3.new(sw + 1.4, sh + 1.4, 0.8), CFrame = CFrame.new(0, sy, 0.5), Color = trim }))
	local card = decor(add({
		Name = "GateSign",
		Size = Vector3.new(sw, sh, 0.8),
		CFrame = CFrame.new(0, sy, 0),
		Color = if open then W.Cream else LOCKED_CARD,
	}))
	if open then
		cardFace(card, Enum.NormalId.Front, 30, W.Cream, tint, "OPEN!", entry.title)
		cardFace(card, Enum.NormalId.Back, 30, W.Cream, tint, "GOOD LUCK!", entry.title)
		add({ Name = "StartLine", Size = Vector3.new(Course.GATE_HALF * 2, 0.12, 1.6), CFrame = CFrame.new(0, 0.06, 0), Color = W.Sunny })
		gateArrow(add, 8.6, tint)
		portal(base, 6.2, PORTAL_COLORS[entry.id] or { tint, W.White }, folder)
		trigger(
			entry.id == "parkour" and "ParkourStart" or "ModeStart",
			base * CFrame.new(0, 5, 0),
			Vector3.new(Course.GATE_HALF * 2, 10, 1),
			folder
		)
		return
	end
	local title = string.gsub(entry.title, " ", "\n")
	lockedFace(card, Enum.NormalId.Front, 40, title)
	lockedFace(card, Enum.NormalId.Back, 40, title)
	-- Closed bars with a friendly padlock in the middle.
	local barTop = height - beamH
	for i = -2, 2 do
		add({
			Name = "GateBar",
			Shape = CYLINDER,
			Size = Vector3.new(barTop - 0.2, 0.8, 0.8),
			CFrame = CFrame.new(i * 1.6, 0.2 + (barTop - 0.2) / 2, 0) * UPRIGHT,
			Color = W.Chrome,
		})
	end
	for _, y in { 2.2, barTop - 1.8 } do
		add({
			Name = "GateRail",
			Shape = CYLINDER,
			Size = Vector3.new(half * 2 - 1, 0.9, 0.9),
			CFrame = CFrame.new(0, y, 0),
			Color = W.Chrome,
		})
	end
	add({ Name = "Padlock", Size = Vector3.new(3.8, 3.2, 1.4), CFrame = CFrame.new(0, 5.2, -1), Color = W.Sunny })
	for _, sx in { -1, 1 } do
		-- Rounded padlock sides, little eyes and the shackle.
		decor(add({
			Name = "PadlockSide",
			Shape = CYLINDER,
			Size = Vector3.new(1.4, 3.2, 3.2),
			CFrame = CFrame.new(sx * 1.9, 5.2, -1) * ALONG_Z,
			Color = W.Sunny,
		}))
		decor(add({ Name = "PadlockEye", Shape = BALL, Size = cube(0.6), CFrame = CFrame.new(sx * 0.85, 6, -1.7), Color = W.Ink }))
		add({
			Name = "PadlockShackle",
			Shape = CYLINDER,
			Size = Vector3.new(1.8, 0.8, 0.8),
			CFrame = CFrame.new(sx * 1.2, 7.6, -1) * UPRIGHT,
			Color = W.Chrome,
		})
		decor(add({ Name = "PadlockShackle", Shape = BALL, Size = cube(0.8), CFrame = CFrame.new(sx * 1.2, 8.5, -1), Color = W.Chrome }))
	end
	add({
		Name = "PadlockShackle",
		Shape = CYLINDER,
		Size = Vector3.new(2.4, 0.8, 0.8),
		CFrame = CFrame.new(0, 8.5, -1),
		Color = W.Chrome,
	})
	decor(add({
		Name = "PadlockHole",
		Shape = CYLINDER,
		Size = Vector3.new(0.2, 0.9, 0.9),
		CFrame = CFrame.new(0, 4.9, -1.75) * ALONG_Z,
		Color = W.Ink,
	}))
	decor(add({ Name = "PadlockHole", Size = Vector3.new(0.4, 0.9, 0.2), CFrame = CFrame.new(0, 4.35, -1.75), Color = W.Ink }))
end

-- The big GAME MODES landmark high behind the gates: a cream card in a chunky sunny frame of
-- rounded rails, on two teal posts. The coral header and the Ink title are separate text
-- layers, each with its own resolution, so both stay crisp from the hub centre.
local function bigSign(parent: Instance)
	local s = Course.BIG_SIGN
	local base = CFrame.new(s.x, 0, s.z) * CFrame.Angles(0, FACE_HUB, 0)
	local add = adder(base, parent)
	local w, h = s.width, s.height
	local cy = s.bottom + h / 2
	local railX, railY = w / 2 + 1.6, h / 2 + 1.6
	local postX = railX + 3.3
	local top = s.bottom + h + 3.2
	for _, sx in { -1, 1 } do
		add({
			Name = "BigSignFoot",
			Shape = CYLINDER,
			Size = Vector3.new(1.2, 5, 5),
			CFrame = CFrame.new(sx * postX, 0.3, 0) * UPRIGHT,
			Color = W.White,
		})
		add({
			Name = "BigSignPost",
			Shape = CYLINDER,
			Size = Vector3.new(top, 3.2, 3.2),
			CFrame = CFrame.new(sx * postX, top / 2, 0) * UPRIGHT,
			Color = W.Teal,
		})
		for _, y in { 6, 14, 22 } do
			decor(add({
				Name = "BigSignRing",
				Shape = CYLINDER,
				Size = Vector3.new(0.9, 3.8, 3.8),
				CFrame = CFrame.new(sx * postX, y, 0) * UPRIGHT,
				Color = W.White,
			}))
		end
		decor(add({ Name = "BigSignCap", Shape = BALL, Size = cube(4.4), CFrame = CFrame.new(sx * postX, top + 1.6, 0), Color = W.Sunny }))
		for _, dy in { -4.5, 4.5 } do
			decor(add({
				Name = "BigSignBracket",
				Shape = CYLINDER,
				Size = Vector3.new(3, 1.4, 1.4),
				CFrame = CFrame.new(sx * (railX + 1.6), cy + dy, 0.2),
				Color = W.Sunny,
			}))
		end
		-- Side rails and corner balls of the frame.
		decor(add({
			Name = "BigSignRail",
			Shape = CYLINDER,
			Size = Vector3.new(h + 3.2, 2.6, 2.6),
			CFrame = CFrame.new(sx * railX, cy, 0.2) * UPRIGHT,
			Color = W.Sunny,
		}))
		for _, sy in { -1, 1 } do
			decor(add({
				Name = "BigSignCorner",
				Shape = BALL,
				Size = cube(3.4),
				CFrame = CFrame.new(sx * railX, cy + sy * railY, 0.2),
				Color = W.Sunny,
			}))
			if sx == 1 then
				decor(add({
					Name = "BigSignRail",
					Shape = CYLINDER,
					Size = Vector3.new(w + 3.2, 2.6, 2.6),
					CFrame = CFrame.new(0, cy + sy * railY, 0.2),
					Color = W.Sunny,
				}))
			end
		end
	end
	-- Sunny backing (its back carries the sign for the course side) and the cream card.
	local frame = decor(add({
		Name = "BigSignFrame",
		Size = Vector3.new(w + 3.2, h + 3.2, 1.2),
		CFrame = CFrame.new(0, cy, 0.7),
		Color = W.Sunny,
	}))
	decor(add({ Name = "BigSign", Size = Vector3.new(w, h, 0.8), CFrame = CFrame.new(0, cy, 0), Color = W.Cream }))
	cardFace(frame, Enum.NormalId.Back, 12, W.Cream, W.Coral, "PARKOUR", "GAME MODES")
	-- Coral header pill (white text ~95 px) and the Ink title (~95 px, width-limited).
	local headH = 3.8
	local head = carrier(add, "BigSignHeader", CFrame.new(0, cy + h / 2 - 0.5 - headH / 2, -0.45), Vector3.new(w - 3, headH, 0.05))
	local pill = panel(surface(head, Enum.NormalId.Front, 34), W.Coral, UDim2.fromScale(0, 0), UDim2.fromScale(1, 1), 0.5)
	text(
		pill,
		{ Text = "PARKOUR OPEN NOW!", TextColor3 = W.White, Size = UDim2.fromScale(0.9, 0.74), Position = UDim2.fromScale(0.05, 0.14) }
	)
	local titleH = h - headH - 1.4
	local title = carrier(add, "BigSignTitle", CFrame.new(0, s.bottom + 0.5 + titleH / 2, -0.45), Vector3.new(w - 2, titleH, 0.05))
	text(
		surface(title, Enum.NormalId.Front, 14),
		{ Text = "GAME MODES", Size = UDim2.fromScale(0.98, 0.96), Position = UDim2.fromScale(0.01, 0.02) }
	)
end

-- Freestanding best-times card; returns the list label.
local function bestBoard(parent: Instance): TextLabel
	local b = Course.BOARD
	local yaw = math.atan2(-(b.faceX - b.x), -(b.faceZ - b.z))
	local base = CFrame.new(b.x, Course.PLAZA.top, b.z) * CFrame.Angles(0, yaw, 0)
	local add = adder(base, parent)
	-- Tall enough for one line per level (Modes.Parkour writes LEVEL_COUNT lines).
	local w, h, bottom = 15, 16, 2.5
	for _, sx in { -1, 1 } do
		local x = sx * (w / 2 + 0.6)
		add({
			Name = "BoardFoot",
			Shape = CYLINDER,
			Size = Vector3.new(0.6, 2.4, 2.4),
			CFrame = CFrame.new(x, 0.3, 0) * UPRIGHT,
			Color = W.Cream,
		})
		add({
			Name = "BoardPost",
			Shape = CYLINDER,
			Size = Vector3.new(bottom + h + 0.4, 1.3, 1.3),
			CFrame = CFrame.new(x, (bottom + h + 0.4) / 2, 0) * UPRIGHT,
			Color = W.Mint,
		})
		decor(add({ Name = "BoardCap", Shape = BALL, Size = cube(2), CFrame = CFrame.new(x, bottom + h + 0.8, 0), Color = W.Sunny }))
	end
	local slab =
		decor(add({ Name = "BestBoard", Size = Vector3.new(w, h, 0.8), CFrame = CFrame.new(0, bottom + h / 2, 0), Color = W.White }))
	local root = surface(slab, Enum.NormalId.Front, 30)
	local card = panel(root, W.Cream, UDim2.fromScale(0.03, 0.025), UDim2.fromScale(0.94, 0.95), 0.06)
	local pill = panel(card, W.Coral, UDim2.fromScale(0.1, 0.025), UDim2.fromScale(0.8, 0.1), 0.5)
	text(pill, { Text = "PARKOUR BEST", TextColor3 = W.White, Size = UDim2.fromScale(0.9, 0.74), Position = UDim2.fromScale(0.05, 0.13) })
	text(card, {
		Text = "SERVER TOP TIMES",
		Font = theme.Fonts.Bold,
		Size = UDim2.fromScale(0.8, 0.05),
		Position = UDim2.fromScale(0.1, 0.135),
	})
	local list = text(card, {
		Text = "Be the first to finish!",
		Font = theme.Fonts.Bold,
		TextScaled = false,
		TextSize = 25,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
		TextWrapped = true,
		RichText = true,
		Size = UDim2.fromScale(0.9, 0.78),
		Position = UDim2.fromScale(0.05, 0.2),
	})
	local back = surface(slab, Enum.NormalId.Back, 30)
	local backCard = panel(back, W.Cream, UDim2.fromScale(0.03, 0.025), UDim2.fromScale(0.94, 0.95), 0.06)
	text(backCard, { Text = "GAME MODES", Size = UDim2.fromScale(0.86, 0.3), Position = UDim2.fromScale(0.07, 0.35) })
	return list
end

-- A small arch over the spur where it leaves the hub ring.
local function spurArch(parent: Instance)
	local x = Course.SPUR.x1 - 5
	local base = CFrame.new(x, Course.SPUR.top, 0) * CFrame.Angles(0, FACE_HUB, 0)
	local add = adder(base, parent)
	local half = Course.SPUR.half + 1.4
	for _, sx in { -1, 1 } do
		add({
			Name = "ArchFoot",
			Shape = CYLINDER,
			Size = Vector3.new(1, 3, 3),
			CFrame = CFrame.new(sx * half, 0.5, 0) * UPRIGHT,
			Color = W.Grape,
		})
		add({
			Name = "ArchPillar",
			Shape = CYLINDER,
			Size = Vector3.new(10.4, 2, 2),
			CFrame = CFrame.new(sx * half, 5.2, 0) * UPRIGHT,
			Color = W.White,
		})
		add({ Name = "ArchCap", Shape = BALL, Size = cube(2.8), CFrame = CFrame.new(sx * half, 11.4, 0), Color = W.Sunny })
	end
	local sign =
		decor(add({ Name = "ArchSign", Size = Vector3.new(half * 2 - 1.5, 3.8, 0.9), CFrame = CFrame.new(0, 9.6, 0), Color = W.White }))
	cardFace(sign, Enum.NormalId.Front, 30, W.Cream, W.Grape, "THIS WAY!", "GAME MODES")
	cardFace(sign, Enum.NormalId.Back, 30, W.Cream, W.Grape, "BACK TO", "THE GYMS")
end

-- Plaza ---------------------------------------------------------------------------------

local function buildPlaza(parent: Instance)
	local p, s = Course.PLAZA, Course.SPUR
	local cx, cz = (p.x0 + p.x1) / 2, (p.z0 + p.z1) / 2
	local sx, sz = p.x1 - p.x0, p.z1 - p.z0
	make("Part", {
		Name = "ModesPlaza",
		Size = Vector3.new(sx, 0.8, sz),
		CFrame = CFrame.new(cx, p.top - 0.4, cz),
		Color = W.Wood,
		Material = Enum.Material.WoodPlanks,
		Parent = parent,
	})
	make("Part", {
		Name = "ModesPlazaRim",
		Size = Vector3.new(sx + 1.4, 0.8, sz + 1.4),
		CFrame = CFrame.new(cx, p.top - 0.5, cz),
		Color = W.White,
		Parent = parent,
	})
	for i, ring in { { 13, W.Coral }, { 11.6, W.Cream }, { 4, W.Sunny } } do
		make("Part", {
			Name = "PlazaInlay",
			Shape = CYLINDER,
			Size = Vector3.new(0.2, ring[1] * 2, ring[1] * 2),
			CFrame = CFrame.new(cx, p.top + 0.02 * i, cz) * UPRIGHT,
			Color = ring[2],
			Parent = parent,
		})
	end
	-- Spur from the hub ring.
	local length = s.x1 - s.x0
	make("Part", {
		Name = "Boardwalk",
		Size = Vector3.new(length, 0.6, s.half * 2),
		CFrame = CFrame.new((s.x0 + s.x1) / 2, s.top - 0.3, 0),
		Color = W.Wood,
		Material = Enum.Material.WoodPlanks,
		Parent = parent,
	})
	for _, side in { -1, 1 } do
		make("Part", {
			Name = "BoardwalkEdge",
			Size = Vector3.new(length, 0.7, 0.7),
			CFrame = CFrame.new((s.x0 + s.x1) / 2, s.top - 0.25, side * (s.half - 0.35)),
			Color = W.WoodDark,
			Parent = parent,
		})
		for k, x in { s.x0 + 1, s.x1 - 1 } do
			local z = side * (s.half + 1)
			make("Part", {
				Name = "BollardPost",
				Shape = CYLINDER,
				Size = Vector3.new(2, 1.1, 1.1),
				CFrame = CFrame.new(x, 1, z) * UPRIGHT,
				Color = W.Wood,
				Parent = parent,
			})
			make("Part", {
				Name = "BollardCap",
				Shape = BALL,
				Size = cube(1.5),
				CFrame = CFrame.new(x, 2.2, z),
				Color = FLAG_COLORS[k + side + 2],
				Parent = parent,
			})
		end
	end
	spurArch(parent)
	-- Flag posts on the plaza corners.
	for i, corner in { { p.x1 - 2, p.z0 + 2 }, { p.x1 - 2, p.z1 - 2 }, { p.x0 + 2, p.z0 + 2 }, { p.x0 + 2, p.z1 - 2 } } do
		flagPole(corner[1], p.top, corner[2], 10, FLAG_COLORS[i], nil, if corner[2] < 0 then 0 else math.pi, parent)
	end
end

-- Course --------------------------------------------------------------------------------

local ARCH_SPRING = 10
local ARCH_SEGMENTS = 7

-- Two candy pillars and a rounded half-circle of `body`-coloured segments, built through
-- `add` (frame: front facing -Z, x across the deck, y up from the deck top).
local function archFrame(add: (props: { [string]: any }) -> BasePart, half: number, body: Color3)
	local spring = ARCH_SPRING
	for _, sx in { -1, 1 } do
		add({
			Name = "FinishFoot",
			Shape = CYLINDER,
			Size = Vector3.new(1, 4.2, 4.2),
			CFrame = CFrame.new(sx * half, 0.5, 0) * UPRIGHT,
			Color = W.White,
		})
		add({
			Name = "FinishPillar",
			Shape = CYLINDER,
			Size = Vector3.new(spring, 3, 3),
			CFrame = CFrame.new(sx * half, spring / 2, 0) * UPRIGHT,
			Color = body,
		})
		for _, y in { 2.5, 5.5 } do
			add({
				Name = "FinishRing",
				Shape = CYLINDER,
				Size = Vector3.new(0.8, 3.5, 3.5),
				CFrame = CFrame.new(sx * half, y, 0) * UPRIGHT,
				Color = W.White,
			})
		end
	end
	local segments = ARCH_SEGMENTS
	for i = 0, segments do
		local a = math.pi * i / segments
		decor(add({
			Name = "FinishArchJoint",
			Shape = BALL,
			Size = cube(3.4),
			CFrame = CFrame.new(half * math.cos(a), spring + half * math.sin(a), 0),
			Color = W.White,
		}))
		if i < segments then
			local m = math.pi * (i + 0.5) / segments
			decor(add({
				Name = "FinishArch",
				Shape = CYLINDER,
				Size = Vector3.new(2 * half * math.sin(math.pi / (2 * segments)) + 0.4, 3, 3),
				CFrame = CFrame.new(half * math.cos(m), spring + half * math.sin(m), 0) * CFrame.Angles(0, 0, m + math.pi / 2),
				Color = body,
			}))
		end
	end
end

-- Frame at (x, y, z) whose front (-Z) faces the horizontal direction (faceX, faceZ).
local function facing(x: number, y: number, z: number, faceX: number, faceZ: number): CFrame
	return CFrame.new(x, y, z) * CFrame.Angles(0, math.atan2(-faceX, -faceZ), 0)
end

-- Half the arch span across a deck box (x0..x1, z0..z1) for an arch facing along X or Z.
local function spanHalf(b: Course.Box, faceX: number): number
	return (if faceX ~= 0 then b.z1 - b.z0 else b.x1 - b.x0) / 2 + 0.6
end

-- A level's entrance: an arch over the start deck behind the spawn spot, its card
-- facing along the course ("LEVEL <i>" / name) so a player who just arrived reads it, and
-- five small flag poles in the level's palette along the deck's sides.
local function startArch(level: Course.Level, deck: Course.Element, parent: Instance)
	local s = level.START
	local pal = level.palette
	local sx, sz = deck.sx :: number, deck.sz :: number
	local box = { x0 = deck.x - sx / 2, x1 = deck.x + sx / 2, z0 = deck.z - sz / 2, z1 = deck.z + sz / 2, y0 = 0, y1 = 0 }
	local half = spanHalf(box, s.faceX)
	-- Behind the spawn: half a deck back from the spawn spot, against the course direction.
	local back = (if s.faceX ~= 0 then sx else sz) / 2 - 1.6
	local base = facing(deck.x - s.faceX * back, deck.y, deck.z - s.faceZ * back, s.faceX, s.faceZ)
	local add = adder(base, parent)
	archFrame(add, half, color(pal.main))
	local sign =
		decor(add({ Name = "StartSign", Size = Vector3.new(half * 2 + 3.4, 4.2, 1), CFrame = CFrame.new(0, 9, 0), Color = W.Cream }))
	-- The card's Front face (-Z) looks along the course.
	cardFace(sign, Enum.NormalId.Front, 44, W.Cream, color(pal.accent), "LEVEL " .. level.index, string.upper(level.name))
	cardFace(sign, Enum.NormalId.Back, 44, W.Cream, W.Coral, "LEVEL " .. level.index, "GO GO GO!")
	local keys = { pal.main, pal.alt, pal.checkpoint, pal.mover, pal.blink }
	for i, key in keys do
		-- Spread along the deck's two side edges (parallel to the course direction).
		local t = -0.5 + 1.5 * (i - 1) / (#keys - 1) -- clear of the arch pillars behind
		local side = if i % 2 == 0 then 1 else -1
		local along, across = t * ((if s.faceX ~= 0 then sx else sz) / 2 - 1.2), side * ((if s.faceX ~= 0 then sz else sx) / 2 - 0.8)
		local px = deck.x + (if s.faceX ~= 0 then along else across)
		local pz = deck.z + (if s.faceX ~= 0 then across else along)
		flagPole(px, deck.y, pz, 7, color(key), nil, math.atan2(-s.faceX, -s.faceZ) + math.pi / 2, parent)
	end
end

-- Level `level`'s parts into `parent`.
local function buildCourse(level: Course.Level, parent: Instance)
	local midZ = (level.BOUNDS.z0 + level.BOUNDS.z1) / 2
	local tops: { [Course.Element]: BasePart } = {}
	for _, e in level.ELEMENTS do
		if e.kind == "pad" then
			platform(e, e.name or "Platform", parent, false)
		elseif e.kind == "checkpoint" then
			checkpoint(e, parent, level.index, midZ)
		elseif e.kind == "mover" then
			tops[e] = mover(e, parent)
		elseif e.kind == "blink" then
			tops[e] = blink(e, parent)
		elseif e.kind == "spinner" then
			spinner(e, parent)
		elseif e.kind == "bounce" then
			bounce(e, parent)
		elseif e.kind == "wall" then
			wall(e, parent)
		elseif e.kind == "slide" then
			slide(e, parent)
		end
	end
	-- Foam under every platform out at sea, and a chevron on each top toward the next one
	-- (none on the bounce deck: its pad is the hint).
	for i, e in level.PATH do
		if e.kind ~= "slide" then
			foam(e, parent)
			local nextE = level.PATH[i + 1]
			if nextE and e.name ~= "BounceDeck" then
				chevron(e, nextE, tops[e] or parent)
			end
		end
	end
	if level.PATH[1] then
		startArch(level, level.PATH[1], parent)
	end

	-- Finish: a sunny trophy arch over the finish deck, front facing the incoming runner: two
	-- pillars, a rounded half-circle of candy segments, a FINISH banner between the pillars
	-- and the spinning trophy standing on the banner inside the arch.
	local f = level.FINISH
	local fa = level.FINISH_ARCH
	local base = facing(fa.x, fa.y, fa.z, fa.faceX, fa.faceZ)
	local add = adder(base, parent)
	local half = spanHalf(f, fa.faceX)
	archFrame(add, half, W.Sunny)
	local bannerY = 9
	local sign =
		decor(add({ Name = "FinishSign", Size = Vector3.new(half * 2 + 3.4, 4.2, 1), CFrame = CFrame.new(0, bannerY, 0), Color = W.Cream }))
	cardFace(sign, Enum.NormalId.Front, 44, W.Cream, W.Teal, "YOU DID IT!", "FINISH")
	cardFace(sign, Enum.NormalId.Back, 44, W.Cream, W.Coral, "WELL DONE!", "LEVEL " .. level.index .. " CLEAR")
	-- Chequered finish line on the deck.
	local line = add({ Name = "FinishLine", Size = Vector3.new(half * 2 - 1, 0.12, 2.4), CFrame = CFrame.new(0, 0.06, 0), Color = W.White })
	local cols = 12
	local grid = surface(line, Enum.NormalId.Top, 10)
	for row = 0, 1 do
		for col = 0, cols - 1 do
			if (row + col) % 2 == 0 then
				local cell = Instance.new("Frame")
				cell.BackgroundColor3 = W.Ink
				cell.BorderSizePixel = 0
				cell.Position = UDim2.fromScale(col / cols, row / 2)
				cell.Size = UDim2.fromScale(1 / cols, 0.5)
				cell.Parent = grid
			end
		end
	end
	-- Spinning gold trophy (Client.Fx.Ambient turns models with a Spin attribute).
	local trophy = Instance.new("Model")
	trophy.Name = "Trophy"
	trophy:SetAttribute("Spin", 0.8)
	local tBase = base * CFrame.new(0, bannerY + 2.1, 0)
	local root = decor(make("Part", {
		Name = "TrophyBase",
		Size = Vector3.new(2.6, 0.9, 2.6),
		CFrame = tBase * CFrame.new(0, 0.45, 0),
		Color = W.Cream,
		Parent = trophy,
	}))
	trophy.PrimaryPart = root
	decor(make("Part", {
		Name = "TrophyStem",
		Shape = CYLINDER,
		Size = Vector3.new(1.4, 0.8, 0.8),
		CFrame = tBase * CFrame.new(0, 1.6, 0) * UPRIGHT,
		Color = W.Sunny,
		Parent = trophy,
	}))
	decor(make("Part", {
		Name = "TrophyCup",
		Shape = CYLINDER,
		Size = Vector3.new(2.4, 3, 3),
		CFrame = tBase * CFrame.new(0, 3.3, 0) * UPRIGHT,
		Color = W.Sunny,
		Parent = trophy,
	}))
	decor(
		make(
			"Part",
			{ Name = "TrophyBowl", Shape = BALL, Size = cube(3), CFrame = tBase * CFrame.new(0, 2.4, 0), Color = W.Sunny, Parent = trophy }
		)
	)
	for _, sx in { -1, 1 } do
		decor(make("Part", {
			Name = "TrophyHandle",
			Shape = BALL,
			Size = cube(1.2),
			CFrame = tBase * CFrame.new(sx * 1.8, 3.3, 0),
			Color = W.Orange,
			Parent = trophy,
		}))
	end
	trophy.Parent = parent

	local finish = trigger(
		"ParkourFinish",
		CFrame.new((f.x0 + f.x1) / 2, (f.y0 + f.y1) / 2, (f.z0 + f.z1) / 2),
		Vector3.new(f.x1 - f.x0, f.y1 - f.y0, f.z1 - f.z0),
		parent
	)
	finish:SetAttribute("Level", level.index)
	local w = level.WATER_BOX
	local water = trigger(
		"ParkourWater",
		CFrame.new((w.x0 + w.x1) / 2, (w.y0 + w.y1) / 2, (w.z0 + w.z1) / 2),
		Vector3.new(w.x1 - w.x0, w.y1 - w.y0, w.z1 - w.z0),
		parent
	)
	water:SetAttribute("Level", level.index)
end

function Modes.build(): Built
	local folder = Instance.new("Folder")
	folder.Name = "GameModes"
	folder.Parent = mapFolder
	local plaza = Instance.new("Folder")
	plaza.Name = "Plaza"
	plaza.Parent = folder
	local parkour = Instance.new("Folder")
	parkour.Name = "Parkour"
	parkour:SetAttribute("Mode", "parkour")
	parkour:SetAttribute("Levels", Course.LEVEL_COUNT)
	parkour.Parent = folder

	buildPlaza(plaza)
	for _, entry in Catalog do
		gate(entry, plaza)
	end
	bigSign(plaza)
	local list = bestBoard(plaza)
	for i, level in Course.LEVELS do
		local levelFolder = Instance.new("Folder")
		levelFolder.Name = "Level" .. i
		levelFolder:SetAttribute("Mode", "parkour")
		levelFolder:SetAttribute("Level", i)
		levelFolder:SetAttribute("Checkpoints", level.CHECKPOINT_COUNT)
		levelFolder:SetAttribute("Title", level.name)
		levelFolder:SetAttribute("LevelName", level.name)
		buildCourse(level, levelFolder)
		levelFolder.Parent = parkour
	end
	return { folder = folder, bestList = list }
end

return Modes
