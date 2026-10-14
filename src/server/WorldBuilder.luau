--[[
	WorldBuilder: generates the whole map from parts when the server starts.

	Six plots sit around a central hub plaza with a ranking tower. Every plot
	uses the plot-local geometry in PlotLayout (see the diagram there): a stepped
	display ledge at the back, a gutter and chute feeding a walled orb pen right in
	front of it, buy pads either side of the pen and the stations on a painted court down each
	side, every machine right behind its own pad(s).
	World.Shell builds the ground, the low fences, the low stage wall behind the rack and the
	entrance arch; the boards are freestanding cream sign cards (Shell.standingCard) with one
	main line each. Labels Server.Tycoon still writes but the cards no longer show are kept
	hidden (hiddenLabel). The arch wears flags and pennants (ARCH_DRESS), and a plot nobody owns
	a "FREE PLOT" pill, sign and balloons (FREE_DRESS).

	Plot-local axes: Z = toward the back fence, Y = up, and +X is on the left of
	a player walking in from the hub (Roblox is right-handed).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Economy = require(ReplicatedStorage.Shared.Economy)
local Layout = require(script.Parent.PlotLayout)

local World = script.Parent.World
local Common = require(World.Common)
local Hub = require(World.Hub)
local Shell = require(World.Shell)
local Shelves = require(World.Shelves)
local Machines = require(World.Machines)
local Decor = require(World.Decor)
local Pads = require(World.Pads)
local Pen = require(World.Pen)
local Props = require(World.Props)
local Modes = require(World.Modes)
local MogStage = require(World.MogStage)
local CardioTrack = require(World.CardioTrack)

local WorldBuilder = {}

export type Rect = Common.Rect
export type Pad = Common.Pad
type Builder = Common.Builder

export type Plot = {
	index: number,
	cframe: CFrame,
	folder: Folder,
	unitFolder: Folder,
	orbFolder: Folder,
	chestFolder: Folder,
	spawn: CFrame,
	slots: { CFrame },
	-- Plot-local rectangle on the pen floor where dropped orbs land.
	orbArea: Rect,
	-- Plot-local Y of the pen floor's walkable surface (orbs rest on it).
	orbFloorY: number,
	-- Plot-local footprint of the orb pen, walls included.
	pool: Rect,
	-- Plot-local rectangles (front half of the pen) where dropped crates land.
	chestAreas: { Rect },
	pads: { Pad },
	padByName: { [string]: Pad },
	labels: { [string]: TextLabel },
	ownerImage: ImageLabel,
	unlockerScreens: { { frame: Frame, title: TextLabel, status: TextLabel, timer: TextLabel } },
}

export type World = {
	plots: { Plot },
	ranking: { TextLabel },
	-- The GAME MODES plaza and Parkour course (World.Modes).
	modes: Modes.Built,
	-- The MOG TEST stage out at sea (World.MogStage).
	mog: MogStage.Built,
	-- The CARDIO keyboard runway out at sea (World.CardioTrack).
	cardio: CardioTrack.Built,
}

local theme = Common.theme
local Paint = theme.World
local mapFolder = Common.mapFolder
local make = Common.make
local plotCFrame = Common.plotCFrame
local soft = Shell.soft
local text = Shell.text
local standingCard = Shell.standingCard
local buildFloor = Shell.buildFloor
local buildWalls = Shell.buildWalls
local buildEntrance = Shell.buildEntrance
local watchChampion = Shelves.watchChampion
local buildShelves = Shelves.buildShelves
local buildConverter = Machines.buildConverter
local buildProcessor = Machines.buildProcessor
local buildVault = Machines.buildVault
local buildUnlocker = Machines.buildUnlocker
local buildGymDecor = Decor.buildGymDecor
local buildPad = Pads.buildPad
local setPadClaimed = Pads.setClaimed

local PLOT_COUNT = Common.PLOT_COUNT

-- Purely decorative parts (rails, trim, posts, signs, lights) that must never block the player
-- or pull the camera in: Roblox's Poppercam ignores CanQuery = false parts. Shell marks its own
-- decor this way as it builds it; this list covers the other world modules. Floors, the low
-- fence panels, pen walls/stairs, the gutter and chute, and pad tops/bases stay solid.
local CAMERA_SAFE = {
	PenLip = true,
	ShelfLightBar = true,
	ChampionSpot = true,
	ChampionRing = true,
	ChampionDisc = true,
	Board = true,
	Screen = true,
}

local function makeCameraSafe(root: Instance)
	for _, inst in root:GetDescendants() do
		if inst:IsA("BasePart") and CAMERA_SAFE[inst.Name] then
			inst.CanCollide = false
			inst.CanQuery = false
			inst.CanTouch = false
		end
	end
end

-- Faces for freestanding sign cards (yaw 0 faces the entrance, -Z).
local FACE_MINUS_X = math.pi / 2
local FACE_PLUS_X = -math.pi / 2
-- Bottom edge of the processor's board: above the smoothie cups riding its belt.
local BOARD_BOTTOM = 7.2
-- Bottom edge of the cards at the +X stations (crate crackers, free gift): above the crate
-- plinth and the gift box in front of them.
local STATION_SIGN_BOTTOM = 4

-- The crate crackers' cards: smaller than the other station cards, as they stand right behind
-- their pad (2.4 studs from its base) and a full-size card fills the view from there.
local CRACKER_SIGN = Vector2.new(4.4, 3.2)
-- What Server.Tycoon writes into a cracker's timer once its crate can be opened.
local READY_TEXT = "READY!"
-- The upright "READY!" pill: its size in studs (plus a fixed pixel part, so it stays readable
-- across the plot) and the gap between the card's top and its bottom edge.
local READY_SIZE = Vector2.new(3, 1)
local READY_PX = Vector2.new(24, 10)
local READY_GAP = 0.3

-- The owner card's text on a plot nobody owns.
local FREE_PLOT = "FREE PLOT"

-- Entrance dressing added to Shell's arch on every plot (studs, plot-local; the arch stands on
-- the front fence line with its pillars at |x| = ArchX, as Shell.buildEntrance builds it): a
-- flag on a pole over each pillar and a string of pennants from each pole top down to the fence.
local ARCH_DRESS = {
	ArchZ = -(Layout.PLOT_HALF - 0.8),
	ArchX = 8.2,
	-- Top of the pillars' sunny knobs: the poles stand on them.
	PoleBase = 13.6,
	PoleTop = 20,
	PoleThick = 0.4,
	KnobSize = 1,
	FlagSize = Vector2.new(4.2, 2.8),
	FlagColors = { "Coral", "Sunny" },
	-- Pennants: from each pole (PennantDrop under its flag) out to a short pole on the fence at
	-- |x| = PennantEndX, PennantEndY up (so the last pennant hangs clear of the 3.6-stud fence),
	-- sagging PennantSag in the middle.
	PennantDrop = 0.6,
	PennantEndX = 31,
	PennantEndY = 8.6,
	PennantSag = 2.2,
	PennantCount = 11,
	PennantSize = Vector2.new(1.9, 2.4),
	PennantColors = { "Coral", "Sunny", "White", "Pink", "Mint" },
}

-- What a plot nobody owns wears so the street never shows an empty lot (FreePlotDressing, taken
-- out of the world while the plot has an owner): a green pill floating over the arch, readable
-- from the hub and from any side, balloons tied to the arch and to the pen's front posts, and a
-- big sign card on the walkway facing the entrance. Plots are handed out as players join
-- (Server.Tycoon), so the words promise nothing a visitor could do.
local FREE_DRESS = {
	Title = FREE_PLOT,
	Line = "Waiting for a new " .. theme.Words.Unit .. "!",
	-- The pill: centre height, size in studs plus fixed pixels, and how far it shows.
	PillY = 23.5,
	PillSize = Vector2.new(20, 6.4),
	PillPx = Vector2.new(60, 20),
	PillDistance = 170,
	-- The walkway card: its z, size and bottom edge.
	CardZ = -30,
	CardSize = Vector2.new(15, 7),
	CardBottom = 3.2,
	-- Balloons: diameter, string thickness and the three balloons of a bunch as (away from the
	-- centre line, up, along z) from where the bunch is tied.
	Balloon = 2.6,
	String = 0.1,
	Bunch = { Vector3.new(1.8, 6.4, -0.8), Vector3.new(3.6, 7.4, 0.4), Vector3.new(2.4, 8.8, 0.9) },
	BalloonColors = { "Coral", "Sunny", "Mint", "Pink", "Blue", "Grape" },
	-- Where the arch bunches are tied: beside each pillar and ArchTieFront toward the hub, clear
	-- of the awning (it reaches |x| = 9.9) and in front of the arch's pennants.
	ArchTieOut = 1.8,
	ArchTieFront = 2.6,
	ArchTieY = 4.5,
}

-- A label Server.Tycoon still writes to that its card no longer shows.
local function hiddenLabel(parent: Instance): TextLabel
	return text(parent, { Text = "", Visible = false })
end

-- The "READY!" pill floating over a crate cracker's card (`body` is the card's body frame): a
-- BillboardGui, so it stands upright and faces the camera from anywhere on the court, in the
-- pads' green "ready" plate. It shows while `timer` says READY_TEXT; the card then drops its
-- timer line and shows the crate's name (`status`) alone.
local function buildReadyFlag(body: Frame, cardHeight: number, status: TextLabel, timer: TextLabel)
	local card = body:FindFirstAncestorWhichIsA("BasePart") :: BasePart
	local gui = Instance.new("BillboardGui")
	gui.Name = "ReadyFlag"
	gui.Adornee = card
	gui.Size = UDim2.new(READY_SIZE.X, READY_PX.X, READY_SIZE.Y, READY_PX.Y)
	gui.StudsOffsetWorldSpace = Vector3.new(0, cardHeight / 2 + READY_GAP + READY_SIZE.Y / 2, 0)
	gui.MaxDistance = Common.SIGN_FADE_CARD
	gui.LightInfluence = 0
	gui.Enabled = false
	gui.Parent = card
	local pill = Instance.new("Frame")
	pill.Size = UDim2.fromScale(1, 1)
	pill.BackgroundColor3 = (Paint.PadPlate and Paint.PadPlate.Good) or theme.Colors.Good
	pill.BorderSizePixel = 0
	pill.Parent = gui
	local round = Instance.new("UICorner")
	round.CornerRadius = UDim.new(0.5, 0)
	round.Parent = pill
	local rim = Instance.new("UIStroke")
	rim.Color = Paint.Ink
	rim.Thickness = 1.5
	rim.Parent = pill
	text(pill, {
		Text = READY_TEXT,
		Font = theme.Fonts.Display,
		Size = UDim2.fromScale(0.86, 0.8),
		Position = UDim2.fromScale(0.07, 0.1),
		TextColor3 = Paint.White,
		Outline = true,
	})

	local statusSize, statusPosition = status.Size, status.Position
	local function show()
		local ready = timer.Text == READY_TEXT
		gui.Enabled = ready
		timer.Visible = not ready
		status.Size = if ready then UDim2.fromScale(statusSize.X.Scale, 0.8) else statusSize
		status.Position = if ready then UDim2.fromScale(statusPosition.X.Scale, 0.1) else statusPosition
	end
	timer:GetPropertyChangedSignal("Text"):Connect(show)
	show()
end

-- A thin round string from `from` to `to` (world space).
local function stringRod(P: (props: { [string]: any }) -> BasePart, from: Vector3, to: Vector3, thick: number, color: Color3)
	soft(P({
		Name = "String",
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new((to - from).Magnitude, thick, thick),
		CFrame = CFrame.lookAt((from + to) / 2, to) * CFrame.Angles(0, math.rad(90), 0),
		Color = color,
	})).CastShadow =
		false
end

-- Flags and pennants on the entrance arch (ARCH_DRESS).
local function dressArch(B: Builder)
	local d = ARCH_DRESS
	local L, P = B.L, B.P
	local z = d.ArchZ
	for i, side in { -1, 1 } do
		local x = side * d.ArchX
		soft(P({
			Name = "ArchFlagPole",
			Shape = Enum.PartType.Cylinder,
			Size = Vector3.new(d.PoleTop - d.PoleBase, d.PoleThick, d.PoleThick),
			CFrame = L(x, (d.PoleBase + d.PoleTop) / 2, z) * Common.UPRIGHT,
			Color = Paint.White,
		}))
		soft(P({
			Name = "ArchFlagKnob",
			Shape = Enum.PartType.Ball,
			Size = Vector3.new(d.KnobSize, d.KnobSize, d.KnobSize),
			CFrame = L(x, d.PoleTop + d.KnobSize * 0.3, z),
			Color = Paint.Sunny,
		}))
		-- The flag flies outward from its pole, just under the knob.
		soft(P({
			Name = "ArchFlag",
			Size = Vector3.new(d.FlagSize.X, d.FlagSize.Y, 0.15),
			CFrame = L(x + side * (d.PoleThick / 2 + d.FlagSize.X / 2), d.PoleTop - d.FlagSize.Y / 2, z),
			Color = Paint[d.FlagColors[i]],
		}))
		-- Pennants: right triangles hanging point down from the sagging line, flat to the hub,
		-- out to a short pole standing on the fence.
		local topY = d.PoleTop - d.FlagSize.Y - d.PennantDrop
		local endX = side * (d.PennantEndX + d.PoleThick)
		soft(P({
			Name = "ArchPennantPole",
			Shape = Enum.PartType.Cylinder,
			Size = Vector3.new(d.PennantEndY + 0.4, d.PoleThick, d.PoleThick),
			CFrame = L(endX, (d.PennantEndY + 0.4) / 2, z) * Common.UPRIGHT,
			Color = Paint.White,
		}))
		soft(P({
			Name = "ArchFlagKnob",
			Shape = Enum.PartType.Ball,
			Size = Vector3.new(d.KnobSize, d.KnobSize, d.KnobSize),
			CFrame = L(endX, d.PennantEndY + 0.4 + d.KnobSize * 0.3, z),
			Color = Paint.Sunny,
		}))
		local w, h = d.PennantSize.X, d.PennantSize.Y
		for n = 1, d.PennantCount do
			local t = (n - 0.5) / d.PennantCount
			local px = x + side * (d.PoleThick + (d.PennantEndX - d.ArchX) * t)
			local py = topY + (d.PennantEndY - topY) * t - d.PennantSag * 4 * t * (1 - t)
			local along = Vector3.new(side, 0, 0)
			local down = Vector3.new(0, -1, 0)
			soft(B.W({
				Name = "ArchPennant",
				Size = Vector3.new(0.12, h, w),
				CFrame = B.cf * CFrame.fromMatrix(Vector3.new(px, py - h / 2, z), down:Cross(along), down, along),
				Color = Paint[d.PennantColors[(n - 1) % #d.PennantColors + 1]],
			})).CastShadow =
				false
		end
	end
end

-- The dressing of a plot nobody owns (FREE_DRESS), in one model the caller shows or hides.
local function buildFreeDressing(B: Builder, index: number): Model
	local d = FREE_DRESS
	local model = Instance.new("Model")
	model.Name = "FreePlotDressing"
	local function P(props: { [string]: any }): BasePart
		props.Parent = props.Parent or model
		return make("Part", props)
	end
	local FB: Builder = { cf = B.cf, folder = B.folder, c = B.c, L = B.L, P = P, W = B.W }
	local L = B.L
	local archZ = ARCH_DRESS.ArchZ

	-- The pill over the arch.
	local anchor = soft(P({
		Name = "FreePlotSign",
		Size = Vector3.new(1, 1, 1),
		CFrame = L(0, d.PillY, archZ),
		Transparency = 1,
	}))
	anchor.CastShadow = false
	local gui = Instance.new("BillboardGui")
	gui.Name = "FreePlotPill"
	gui.Adornee = anchor
	gui.Size = UDim2.new(d.PillSize.X, d.PillPx.X, d.PillSize.Y, d.PillPx.Y)
	gui.MaxDistance = d.PillDistance
	gui.LightInfluence = 0
	gui.Parent = anchor
	local pill = Instance.new("Frame")
	pill.Size = UDim2.fromScale(1, 1)
	pill.BackgroundColor3 = (Paint.PadPlate and Paint.PadPlate.Good) or theme.Colors.Good
	pill.BorderSizePixel = 0
	pill.Parent = gui
	local round = Instance.new("UICorner")
	round.CornerRadius = UDim.new(0.3, 0)
	round.Parent = pill
	local rim = Instance.new("UIStroke")
	rim.Color = Paint.White
	rim.Thickness = 3
	rim.Parent = pill
	text(pill, {
		Text = "★ " .. d.Title .. " ★",
		Font = theme.Fonts.Display,
		Size = UDim2.fromScale(0.9, 0.52),
		Position = UDim2.fromScale(0.05, 0.07),
		TextColor3 = Paint.Sunny,
		Outline = true,
	})
	text(pill, {
		Text = d.Line,
		Font = theme.Fonts.Display,
		Size = UDim2.fromScale(0.88, 0.3),
		Position = UDim2.fromScale(0.06, 0.62),
		TextColor3 = Paint.White,
		Outline = true,
	})

	-- The walkway card, with the same words in white on its teal back.
	local body = standingCard(FB, 0, d.CardZ, 0, d.CardSize, d.CardBottom, "★ " .. d.Title .. " ★")
	text(body, {
		Text = d.Line,
		Font = theme.Fonts.Display,
		Size = UDim2.fromScale(0.92, 0.8),
		Position = UDim2.fromScale(0.04, 0.1),
	})
	local cardPart = body:FindFirstAncestorWhichIsA("BasePart") :: BasePart
	local back = Instance.new("SurfaceGui")
	back.Face = Enum.NormalId.Back
	back.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	back.PixelsPerStud = 24
	back.LightInfluence = 0.5
	back.MaxDistance = Common.SIGN_FADE_CARD
	back.Parent = cardPart
	text(back, {
		Text = d.Title,
		Font = theme.Fonts.Display,
		TextColor3 = Paint.White,
		Size = UDim2.fromScale(0.8, 0.6),
		Position = UDim2.fromScale(0.1, 0.2),
	})

	-- Balloon bunches: on the hub side of each arch pillar and on the pen's front posts, each
	-- leaning away from the centre line.
	local pen = Layout.POOL
	local ties = {
		{ x = ARCH_DRESS.ArchX + d.ArchTieOut, y = d.ArchTieY, z = archZ - d.ArchTieFront },
		{ x = pen.maxX - Layout.PEN.wallThick / 2, y = Layout.PEN.postHeight + 1, z = pen.minZ + Layout.PEN.wallThick / 2 },
	}
	-- Start the colour cycle at the plot's number so neighbouring plots differ.
	local colorIndex = index
	for _, tie in ties do
		for _, side in { -1, 1 } do
			local from = L(side * tie.x, tie.y, tie.z).Position
			for _, offset in d.Bunch do
				colorIndex += 1
				local at = L(side * (tie.x + offset.X), tie.y + offset.Y, tie.z + offset.Z).Position
				stringRod(P, from, at, d.String, Paint.White)
				soft(P({
					Name = "Balloon",
					Shape = Enum.PartType.Ball,
					Size = Vector3.new(d.Balloon, d.Balloon, d.Balloon),
					CFrame = CFrame.new(at + Vector3.new(0, d.Balloon * 0.45, 0)),
					Color = Paint[d.BalloonColors[colorIndex % #d.BalloonColors + 1]],
					Reflectance = 0.08,
				}))
			end
		end
	end
	return model
end

local function buildPlot(index: number): Plot
	local c = theme.Colors
	local w = theme.Words
	local padColors = Paint.Pads
	local cf = plotCFrame(index)
	local folder = Instance.new("Folder")
	folder.Name = "Plot" .. index
	folder.Parent = mapFolder

	local function L(x: number, y: number, z: number): CFrame
		return cf * CFrame.new(x, y, z)
	end
	local function P(props: { [string]: any }): BasePart
		props.Parent = props.Parent or folder
		return make("Part", props)
	end
	local function W(props: { [string]: any }): BasePart
		props.Parent = props.Parent or folder
		return make("WedgePart", props)
	end
	local B: Builder = { cf = cf, folder = folder, c = c, L = L, P = P, W = W }

	buildFloor(B)
	buildWalls(B)
	Pen.build(B)
	local slots, championParts = buildShelves(B)
	local ownerLabel, ownerImage = buildEntrance(B, index)
	ownerLabel.Text = FREE_PLOT
	dressArch(B)
	local freeDressing = buildFreeDressing(B, index)

	local pads: { Pad } = {}
	local padByName: { [string]: Pad } = {}
	local labels: { [string]: TextLabel } = {}
	local function pad(name: string, color: Color3, title: string, sub: string): Pad
		local record = buildPad(B, name, color, title, sub)
		table.insert(pads, record)
		padByName[name] = record
		return record
	end

	-- Until a player owns the plot (Server.Tycoon then writes every price and status), the pads
	-- show their name only, with no price: a "$0" reads as a live offer.

	-- Buy pads either side of the pen, named after the unit they sell like on an owned plot.
	local firstTier = theme.Tiers[1]
	local unitName = if firstTier then firstTier.Name else w.Unit
	for _, amount in Economy.BUY_AMOUNTS do
		pad("Buy" .. amount, padColors.Buy, "Buy " .. amount .. " " .. unitName, "")
	end
	pad("AutoMerge", padColors.AutoMerge, "Auto Merge", "Game pass")

	-- Merge pad centred in front of the pen, at the end of the walkway.
	pad("Merge", padColors.Merge, w.Merge, "Pairs merge into the next tier")

	-- Deposit station (-X court, level with the plaza): pad + converter machine. The pad's floating label already shows the
	-- multiplier, so the multiplier labels Tycoon writes stay hidden on the pad.
	local depositPad = pad("Deposit", padColors.Deposit, "DEPOSIT", "")
	do
		local conv = Layout.MACHINES.Converter
		buildConverter(B, (conv.minX + conv.maxX) / 2, (conv.minZ + conv.maxZ) / 2)
		labels.DepositMult = hiddenLabel(depositPad.part)
		labels.DepositNext = hiddenLabel(depositPad.part)
	end

	-- Processing machine (-X court, middle station) with its upgrade pads in front of it. Its
	-- board stands behind the counter, above the belt, facing the pads and the path (+X).
	do
		buildProcessor(B)
		local proc = Layout.MACHINES.Processor
		local body, title = standingCard(
			B,
			proc.minX - 0.4,
			(proc.minZ + proc.maxZ) / 2,
			FACE_PLUS_X,
			Vector2.new(7, 5.6),
			BOARD_BOTTOM,
			"⚡ " .. w.Process .. " ⚡",
			false
		)
		labels.ProcessTitle = title
		-- Main line: the aura waiting to be converted.
		labels.ProcessQueue =
			text(body, { Text = "", Font = theme.Fonts.Display, Size = UDim2.fromScale(0.9, 0.8), Position = UDim2.fromScale(0.05, 0.1) })
		labels.ProcessRate = hiddenLabel(body)
		labels.ProcessSpeed = hiddenLabel(body)
	end
	pad("ProcUp1", padColors.Process, "UPGRADE", "")
	pad("ProcUp10", padColors.Process, "UPGRADE x" .. Economy.PROCESS_BULK, "")

	-- Collect cash pad + coin vault (-X court, front station).
	pad("Collect", padColors.Collect, w.Collect, "")
	buildVault(B)

	-- Crate unlockers (+X court), each with a small sign card standing at the machine's front,
	-- square to its pad and the walkway beyond it (-X).
	local unlockerScreens = {}
	for i = 1, 2 do
		local name = if i == 1 then w.Unlocker else w.PremiumUnlocker
		local color = if i == 1 then padColors.Unlock else padColors.UnlockVip
		pad("Unlock" .. i, color, name, "")
		local rect = Layout.MACHINES["Unlocker" .. i]
		buildUnlocker(B, rect, color)
		local body, titleLabel =
			standingCard(B, rect.minX - 0.4, (rect.minZ + rect.maxZ) / 2, FACE_MINUS_X, CRACKER_SIGN, STATION_SIGN_BOTTOM, name, false)
		-- Tycoon tints the status in the crate's rarity colour, so it keeps an Ink outline.
		local statusLabel = text(body, {
			Text = "",
			Size = UDim2.fromScale(0.96, 0.36),
			Position = UDim2.fromScale(0.02, 0.02),
			TextColor3 = Paint.White,
			Outline = true,
		})
		local timerLabel = text(body, {
			Text = "",
			Font = theme.Fonts.Number,
			Size = UDim2.fromScale(0.9, 0.5),
			Position = UDim2.fromScale(0.05, 0.46),
		})
		buildReadyFlag(body, CRACKER_SIGN.Y, statusLabel, timerLabel)
		table.insert(unlockerScreens, { frame = body, title = titleLabel, status = statusLabel, timer = timerLabel })
	end

	-- Free reward (+X court, front station): the pad, the gift box behind it and the sign card
	-- over the gift, facing the pad like the crackers' cards.
	local freeSpot = Layout.PADS.Free
	local gx, gz = freeSpot.x + freeSpot.sizeX / 2 + Layout.PAD_RIM + 2.65, freeSpot.z
	pad("Free", padColors.Free, w.Free, "")
	do
		local body = standingCard(B, gx + 2.2, gz, FACE_MINUS_X, Vector2.new(5.4, 4.6), STATION_SIGN_BOTTOM + 0.4, "🎁 " .. w.Free)
		-- Tycoon writes the countdown or "READY!" in white / green, so it keeps an Ink outline.
		labels.FreeStatus = text(body, {
			Text = "",
			Font = theme.Fonts.Display,
			Size = UDim2.fromScale(0.94, 0.8),
			Position = UDim2.fromScale(0.03, 0.1),
			Outline = true,
			TextColor3 = Paint.White,
		})
		-- Gift box between the pad and the card's legs.
		P({ Name = "Gift", Size = Vector3.new(2.8, 2.6, 2.8), CFrame = L(gx, 1.3, gz), Color = Paint.Coral })
		for _, size in { Vector3.new(2.9, 2.7, 0.6), Vector3.new(0.6, 2.7, 2.9) } do
			soft(P({ Name = "GiftRibbon", Size = size, CFrame = L(gx, 1.3, gz), Color = Paint.White }))
		end
		for _, dx in { -0.45, 0.45 } do
			soft(P({
				Name = "GiftBow",
				Shape = Enum.PartType.Ball,
				Size = Vector3.new(1.1, 1.1, 1.1),
				CFrame = L(gx + dx, 2.95, gz),
				Color = Paint.Sunny,
			}))
		end
	end

	if theme.Decor == "gym" then
		buildGymDecor(B)
	end

	labels.Owner = ownerLabel

	-- Server.Tycoon puts the owner's avatar on the entrance card and clears it when they leave:
	-- with no avatar the plot is free, so its pad names are dimmed and its card says so.
	local function showClaimed()
		local claimed = ownerImage.Image ~= ""
		for _, record in pads do
			setPadClaimed(record, claimed)
		end
		if not claimed then
			ownerLabel.Text = FREE_PLOT
		end
		-- Parented to nil while the plot has an owner, like a folded rack shelf (World.Shelves).
		local parent: Instance? = if claimed then nil else folder
		if freeDressing.Parent ~= parent then
			freeDressing.Parent = parent
		end
	end
	ownerImage:GetPropertyChangedSignal("Image"):Connect(showClaimed)
	showClaimed()

	makeCameraSafe(folder)

	local unitFolder = Instance.new("Folder")
	unitFolder.Name = "Units"
	watchChampion(unitFolder, championParts)
	unitFolder.Parent = folder
	local orbFolder = Instance.new("Folder")
	orbFolder.Name = "Orbs"
	orbFolder.Parent = folder
	local chestFolder = Instance.new("Folder")
	chestFolder.Name = "Chests"
	chestFolder.Parent = folder

	local orbArea = Layout.ORB_AREA
	local poolRect = Layout.POOL
	local chestAreas: { Rect } = {}
	for _, area in Layout.CHEST_AREAS do
		table.insert(chestAreas, Layout.rect(area.minX, area.maxX, area.minZ, area.maxZ))
	end
	return {
		index = index,
		cframe = cf,
		folder = folder,
		unitFolder = unitFolder,
		orbFolder = orbFolder,
		chestFolder = chestFolder,
		spawn = L(Layout.SPAWN.x, 4, Layout.SPAWN.z) * CFrame.Angles(0, math.pi, 0),
		slots = slots,
		orbArea = Layout.rect(orbArea.minX, orbArea.maxX, orbArea.minZ, orbArea.maxZ),
		orbFloorY = Layout.POOL_FLOOR_Y,
		pool = Layout.rect(poolRect.minX, poolRect.maxX, poolRect.minZ, poolRect.maxZ),
		chestAreas = chestAreas,
		pads = pads,
		padByName = padByName,
		labels = labels,
		ownerImage = ownerImage,
		unlockerScreens = unlockerScreens,
	}
end

function WorldBuilder.build(_themeModule: any): World
	mapFolder.Parent = Workspace

	Hub.setupLighting()
	local ranking = Hub.buildHub()
	local modes = Modes.build()
	local mog = MogStage.build()
	local cardio = CardioTrack.build()
	local plots = {}
	for i = 1, PLOT_COUNT do
		table.insert(plots, buildPlot(i))
	end
	-- Blender meshes replace the part-built props that have one (World.Props).
	Props.apply(mapFolder)
	return { plots = plots, ranking = ranking, modes = modes, mog = mog, cardio = cardio }
end

WorldBuilder.label = Common.label
WorldBuilder.billboard = Common.externalBillboard

return WorldBuilder
