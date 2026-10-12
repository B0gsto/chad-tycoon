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
	hidden (hiddenLabel).

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

-- A label Server.Tycoon still writes to that its card no longer shows.
local function hiddenLabel(parent: Instance): TextLabel
	return text(parent, { Text = "", Visible = false })
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

	local pads: { Pad } = {}
	local padByName: { [string]: Pad } = {}
	local labels: { [string]: TextLabel } = {}
	local function pad(name: string, color: Color3, title: string, sub: string): Pad
		local record = buildPad(B, name, color, title, sub)
		table.insert(pads, record)
		padByName[name] = record
		return record
	end

	-- Buy pads either side of the pen.
	for _, amount in Economy.BUY_AMOUNTS do
		pad("Buy" .. amount, padColors.Buy, "Buy " .. amount .. " " .. w.Unit, "$0")
	end
	pad("AutoMerge", padColors.AutoMerge, "Auto Merge", "$0")

	-- Merge pad centred in front of the pen, at the end of the walkway.
	pad("Merge", padColors.Merge, w.Merge, "Pairs merge into the next tier")

	-- Deposit station (-X court, level with the plaza): pad + converter machine. The pad's floating label already shows the
	-- multiplier, so the multiplier labels Tycoon writes stay hidden on the pad.
	local depositPad = pad("Deposit", padColors.Deposit, "DEPOSIT", w.Orb .. " x1.0")
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
			text(body, { Text = "0", Font = theme.Fonts.Display, Size = UDim2.fromScale(0.9, 0.8), Position = UDim2.fromScale(0.05, 0.1) })
		labels.ProcessRate = hiddenLabel(body)
		labels.ProcessSpeed = hiddenLabel(body)
	end
	pad("ProcUp1", padColors.Process, "UPGRADE", "$0")
	pad("ProcUp10", padColors.Process, "UPGRADE x" .. Economy.PROCESS_BULK, "$0")

	-- Collect cash pad + coin vault (-X court, front station).
	pad("Collect", padColors.Collect, w.Collect, "$0")
	buildVault(B)

	-- Crate unlockers (+X court), each with a sign card standing at the machine's front.
	local unlockerScreens = {}
	for i = 1, 2 do
		local name = if i == 1 then w.Unlocker else w.PremiumUnlocker
		local color = if i == 1 then padColors.Unlock else padColors.UnlockVip
		pad("Unlock" .. i, color, name, "")
		local rect = Layout.MACHINES["Unlocker" .. i]
		buildUnlocker(B, rect, color)
		local body, titleLabel = standingCard(
			B,
			rect.minX - 0.4,
			(rect.minZ + rect.maxZ) / 2,
			FACE_MINUS_X,
			Vector2.new(6.2, 4.6),
			STATION_SIGN_BOTTOM,
			name,
			false
		)
		-- Tycoon tints the status in the crate's rarity colour, so it keeps an Ink outline.
		local statusLabel = text(body, {
			Text = "EMPTY",
			Size = UDim2.fromScale(0.96, 0.36),
			Position = UDim2.fromScale(0.02, 0.02),
			TextColor3 = Paint.White,
			Outline = true,
		})
		local timerLabel = text(body, {
			Text = "--:--:--",
			Font = theme.Fonts.Number,
			Size = UDim2.fromScale(0.9, 0.5),
			Position = UDim2.fromScale(0.05, 0.46),
		})
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
