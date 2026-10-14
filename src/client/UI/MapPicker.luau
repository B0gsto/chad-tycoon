--[[
	MapPicker: the "Maps" window (docs/parkour-maps.md, "Picker + server").

	Header "PICK A MAP". Left: a 2-column grid of the ten Parkour map cards, stretched so all
	ten fit without scrolling (accent band with the map's icon, "MAP n", the best time and a
	check when cleared or a lock badge when locked; the name and "Difficulty n/10" with its
	pips below). The
	selected card carries a thick gold rim, a lighter body and a gold chevron; every card's band
	is its map's theme colour (HEADERS) with a faint wash of it over the body; a locked one has
	a darker, greyer band of that colour (text kept bright) with what its first clear pays ("+$1.2K") beside the lock,
	"Clear <previous map> first" in place of its pips, and shakes with a "Clear <previous map>
	first!" bubble when tapped.
	Right, top to bottom: the selected map in a slowly orbiting ViewportFrame preview (panel
	width, about 45% of its height) with a "MAP n" chip, name, pips labelled "Difficulty
	n/10", best/clears, blurb, the reward line (inside the reward cooldown: "Run again: +$X
	· full in m:ss", what a clean run pays on every finish, from rewardPreview's
	repeatShare; "Bonus is resting, back in m:ss" while that map's bonus rests, from
	levels[i].repeatRest, like the finish card; "Gear on: no reward" with a coil chosen) and a gold PLAY (RESTART while that map is running) that fires ModeStart and
	closes every window. One word for a map everywhere: MAP. When the screen or window is narrow (viewport < 700 or window < 750
	wide) the side panel stacks under the grid in one scrolling column.

	The preview is a lazy clone of workspace.Map.GameModes.Parkour.Level<n> without its
	invisible volumes (Transparency 1, ParkourFinish, ParkourWater, Trigger), cached per map,
	over a flat sky-blue plane (the course floats above the clouds), framed so the whole level
	bounding box (path, cloud floor and floating islands with their props) fits the viewport
	from a high 3/4 angle. It orbits on RenderStepped only while the window is open.

	Windows.luau owns the window list: it calls MapPicker.build with its register/closeAll
	helpers and the shared reward/pip helpers, and exposes Windows.open("Maps") and
	Windows.openMaps(level?). Reads State.data.modes.parkour (levels[i] = { name,
	difficulty, best, clears, bonus, repeatRest?, theme?, blurb?, icon?, accent? }, unlocked, level,
	running, gear, cooldownEnds, rewardPreview = { packCash, repeatShare? }).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Format = require(ReplicatedStorage.Shared.Format)
local Net = require(ReplicatedStorage.Shared.Net)

local Kit = require(script.Parent.Kit)
local State = require(script.Parent.Parent.State)

local Theme = Kit.Theme
local C = Kit.C
local T = Kit.TEXT
local F = Kit.F

local MapPicker = {}

export type Deps = {
	register: (string, Kit.Window) -> (),
	closeAll: () -> (),
	-- Paints `label` with what finishing parkour level `level` pays (Windows' setRewardLine
	-- with the level bonus rescale).
	parkourReward: (label: TextLabel, info: { [string]: any }, level: number) -> (),
	-- Builds a difficulty pip row; returns its setter.
	pips: (parent: Instance, props: { [string]: any }) -> (number) -> (),
	runTime: (number) -> string,
	plural: (number, string, string?) -> string,
	ripple: ({ GuiObject }) -> (),
}

export type Picker = {
	window: Kit.Window,
	-- Runs before the window opens: refresh, selection resync, card ripple.
	beforeOpen: () -> (),
	-- Selects `level` the next time the window opens (nil: the player's unlocked level).
	preselect: (number?) -> (),
	-- Selects an unlocked level now (clamped).
	select: (number) -> (),
}

local MAP_COUNT = 10
local SIDE_W = 300
-- Card height: fills the grid column so all ten cards show without scrolling, within these
-- bounds (CARD_MIN is also the height in the stacked layout and on a phone's short window,
-- where the grid scrolls: the band plus a body that holds the name and pip rows unclipped).
local CARD_MIN = 72
local CARD_MAX = 84
local CARD_GAP = 8
local BAND_H = 28
local GRID_PAD = 6
local STACK_W = 700
-- Below this window width the cards get too narrow for their pip row: stack instead. (A row
-- that is still too narrow keeps its "Difficulty n/10" and hides the pips: deps.pips.)
local SIDE_BY_SIDE_MIN_W = 750
local SIDE_STACK_H = 440
-- Side panel: fixed rows measured up from the bottom (offsets of each row's bottom edge).
local PLAY_H = 50
local PLAY_BOTTOM = 12
local REWARD_BOTTOM = PLAY_BOTTOM + PLAY_H + 8
local BLURB_H = 44
local BLURB_BOTTOM = REWARD_BOTTOM + 18 + 4
local STATS_H = 22
local STATS_BOTTOM = BLURB_BOTTOM + BLURB_H + 4
local PIPS_BOTTOM = STATS_BOTTOM + STATS_H + 4
local NAME_H = 24
local NAME_BOTTOM = PIPS_BOTTOM + 16 + 4
-- The preview spans the side panel's width (less a thin inset) at the top and takes about
-- 45% of its height, never so much that it would run into the name row below.
local PREVIEW_INSET = 6
local PREVIEW_SHARE = 0.45
local PREVIEW_BOTTOM = NAME_BOTTOM + NAME_H + 8
-- Lock badge on locked bands: a dark disc behind a 20 px lock.
local LOCK_SIZE = 20
local LOCK_DISC = 26
local LOCKED_SLATE = Color3.fromRGB(104, 112, 138)
-- Accent fallbacks (Theme.World keys) for maps whose data has no accent yet.
local ACCENTS = { "Sunny", "Teal", "Blue", "Coral", "Mint", "Pink", "Grape", "Blue", "Orange", "Sunny" }
local ICONS = { "🏖️", "🌴", "⚓", "🐠", "🫧", "🪸", "🦈", "⛈️", "🌋", "👑" }
-- Card look per map theme (tunables): the band colour, matching the map's own path colours
-- (World.MapDress), and the faint wash of it over the card body. Locked cards keep the hue,
-- darker and a little greyer, so every map shows its colour before it is unlocked.
local HEADERS: { [string]: Color3 } = {
	beach = Color3.fromRGB(255, 214, 72),
	cove = Color3.fromRGB(90, 214, 150),
	bay = Color3.fromRGB(96, 136, 245),
	reef = Color3.fromRGB(255, 96, 176),
	bubble = Color3.fromRGB(120, 196, 255),
	coral = Color3.fromRGB(255, 140, 80),
	shark = Color3.fromRGB(40, 176, 186),
	storm = Color3.fromRGB(132, 144, 182),
	volcano = Color3.fromRGB(255, 104, 18),
	giga = Color3.fromRGB(255, 196, 40),
}
local THEMES = { "beach", "cove", "bay", "reef", "bubble", "coral", "shark", "storm", "volcano", "giga" }
local BODY_WASH = 0.8 -- body background transparency over the card (1 = no wash)
local LOCKED_DARK = 0.38 -- locked band: share pulled toward LOCKED_SLATE
local LOCKED_GREY = 0.3 -- ... and toward its own grey
local ICON_PX = 24
-- Emoji the Roblox font cannot draw (Emoji 14 bubbles and coral print the placeholder logo):
-- big text (the preview fallback) swaps them for these, and the card band draws the map's
-- code-built emblem (EMBLEMS) instead. EMBLEM tunables: box px, colours, stroke px.
local GLYPH_SWAP: { [string]: string } = { ["🫧"] = "🔵", ["🪸"] = "🐚" }
local EMBLEM = {
	BOX = 26,
	STROKE = 1.5,
	BUBBLE_FILL = Color3.fromRGB(206, 246, 255),
	BUBBLE_EDGE = Color3.fromRGB(28, 86, 170),
	BUBBLE_ALPHA = 0.1,
	-- Bubbles: { centre x, centre y (box scale), diameter px }.
	BUBBLES = { { 0.4, 0.6, 16 }, { 0.76, 0.3, 10 }, { 0.2, 0.2, 7 } },
	SHINE = Color3.new(1, 1, 1),
	CORAL = Color3.fromRGB(240, 56, 96),
	CORAL_EDGE = Color3.new(1, 1, 1),
	CORAL_TIP = Color3.fromRGB(255, 232, 214),
	-- Coral branches: { foot x, foot y (box scale), length px, width px, tilt degrees }.
	BRANCHES = { { 0.5, 0.95, 20, 5, 0 }, { 0.42, 0.62, 11, 4, -38 }, { 0.58, 0.55, 11, 4, 40 } },
}
-- Every caption on the cards and side panel is held at least this many px on the glass.
local MIN_TEXT_PX = 15
local STRIP = { ParkourFinish = true, ParkourWater = true, Trigger = true }
-- The sky under the cloud floor (preview plane and well).
local SEA = Color3.fromRGB(120, 190, 245)
local PREVIEW_FOV = 40
-- Camera pitch (degrees below the horizon) for the 3/4 overhead view, and the breathing
-- room left round the course in the frame.
local PREVIEW_PITCH = 40
local PREVIEW_MARGIN = 1.12
local ORBIT_SPEED = 0.12

-- Captions and map names stay readable: held on the glass at the caption size plus `extra`,
-- rounded up and never under 13 px (a phone's 12 px captions included), whatever the screen
-- and the window's own scale (the same floor as Windows.luau's captions).
local function readable(label: TextLabel, extra: number?): TextLabel
	-- Kit.WINDOW's caption size on the glass (Kit.text holds every label in a window at it
	-- anyway): `extra` px over it for the labels that lead their card.
	local floor = if Kit.touch then Kit.WINDOW.TextPxTouch else Kit.WINDOW.TextPx
	Kit.holdText(label, math.max(Kit.captionPx(), floor, MIN_TEXT_PX) + (extra or 0), nil, true)
	return label
end

local function parkourInfo(): { [string]: any }?
	local data = State.data
	local info = data and data.modes and data.modes.parkour
	return if type(info) == "table" then info else nil
end

local function levelList(info: { [string]: any }?): { any }
	return if info and type(info.levels) == "table" then info.levels else {}
end

local function themeOf(lv: any, i: number): string?
	return if type(lv) == "table" and type(lv.theme) == "string" then lv.theme else THEMES[i]
end

local function accentOf(lv: any, i: number): Color3
	local theme = themeOf(lv, i)
	local header = theme and HEADERS[theme]
	if header then
		return header
	end
	local key = if type(lv) == "table" and type(lv.accent) == "string" then lv.accent else ACCENTS[i] or "Sunny"
	local color = (Theme.World :: any)[key]
	if typeof(color) ~= "Color3" then
		color = (Theme.World :: any)[ACCENTS[i] or "Sunny"]
	end
	return if typeof(color) == "Color3" then color else C.Gold
end

local function iconOf(lv: any, i: number): string
	local icon = if type(lv) == "table" and type(lv.icon) == "string" and lv.icon ~= "" then lv.icon else ICONS[i] or "🏁"
	return GLYPH_SWAP[icon] or icon
end

-- Code-built band emblems for the maps whose emoji does not render (EMBLEM above).
local function emblemDisc(parent: Instance, name: string, x: number, y: number, d: number, color: Color3, alpha: number, z: number): Frame
	local disc = Kit.new("Frame", {
		Name = name,
		BackgroundColor3 = color,
		BackgroundTransparency = alpha,
		BorderSizePixel = 0,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(x, y),
		Size = UDim2.fromOffset(d, d),
		ZIndex = z,
		Parent = parent,
	})
	Kit.round(disc)
	return disc
end

local EMBLEMS: { [string]: (Frame) -> () } = {}

EMBLEMS.bubble = function(box)
	for n, b in EMBLEM.BUBBLES do
		local disc = emblemDisc(box, "Bubble" .. n, b[1], b[2], b[3], EMBLEM.BUBBLE_FILL, EMBLEM.BUBBLE_ALPHA, 4)
		Kit.new("UIStroke", { Thickness = EMBLEM.STROKE, Color = EMBLEM.BUBBLE_EDGE, Parent = disc })
		emblemDisc(disc, "Shine", 0.32, 0.3, math.max(2, math.floor(b[3] * 0.28)), EMBLEM.SHINE, 0, 5)
	end
end

EMBLEMS.coral = function(box)
	for n, b in EMBLEM.BRANCHES do
		local rad = math.rad(b[5])
		-- A rounded bar standing on its foot, tilted about it: the centre moves half a length
		-- along the tilt.
		local cx = b[1] + math.sin(rad) * b[3] / 2 / EMBLEM.BOX
		local cy = b[2] - math.cos(rad) * b[3] / 2 / EMBLEM.BOX
		local bar = Kit.new("Frame", {
			Name = "Branch" .. n,
			BackgroundColor3 = EMBLEM.CORAL,
			BorderSizePixel = 0,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(cx, cy),
			Size = UDim2.fromOffset(b[4], b[3]),
			Rotation = b[5],
			ZIndex = 4,
			Parent = box,
		})
		Kit.round(bar)
		Kit.new("UIStroke", { Thickness = EMBLEM.STROKE, Color = EMBLEM.CORAL_EDGE, Parent = bar })
		local tx = b[1] + math.sin(rad) * b[3] / EMBLEM.BOX
		local ty = b[2] - math.cos(rad) * b[3] / EMBLEM.BOX
		emblemDisc(box, "Tip" .. n, tx, ty, b[4] + 2, EMBLEM.CORAL_TIP, 0, 5)
	end
end

-- Shows the map's emblem on its band icon label (built once per label), or the emoji.
local function paintIcon(label: TextLabel, lv: any, i: number)
	local theme = themeOf(lv, i)
	local draw = theme and EMBLEMS[theme]
	local box = label:FindFirstChild("Emblem")
	if draw and not box then
		local made = Kit.new("Frame", {
			Name = "Emblem",
			BackgroundTransparency = 1,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromOffset(EMBLEM.BOX, EMBLEM.BOX),
			ZIndex = 4,
			Parent = label,
		})
		draw(made)
		box = made
	end
	if box and box:IsA("GuiObject") then
		box.Visible = draw ~= nil
	end
	label.Text = if draw then "" else iconOf(lv, i)
end

local function nameOf(lv: any, i: number): string
	return if type(lv) == "table" and type(lv.name) == "string" then lv.name else "Map " .. i
end

-- The full reward of map `level` (its first clear, or a finish after the cooldown): the
-- snapshot's rewardPreview is priced for info.level, so it is rescaled to `level`'s bonus
-- (like Windows' parkourReward). nil without a snapshot.
local function packCash(info: { [string]: any }?, level: number): number?
	local list = levelList(info)
	local lv = list[level]
	local preview = if info then info.rewardPreview else nil
	if not info or type(preview) ~= "table" or type(lv) ~= "table" then
		return nil
	end
	local current = list[tonumber(info.level) or 1]
	local currentBonus = if type(current) == "table" then tonumber(current.bonus) or 1 else 1
	return math.floor((tonumber(preview.packCash) or 0) / math.max(currentBonus, 0.01) * (tonumber(lv.bonus) or 1) + 0.5)
end

-- Preview -------------------------------------------------------------------------------

type Preview = { model: Model, center: Vector3, span: Vector3 }

-- Clones Level<n> without its invisible volumes into a Model over a sky plane, or nil when
-- the level is not in the workspace (yet).
local function buildPreview(n: number): Preview?
	local map = workspace:FindFirstChild("Map")
	local modes = map and map:FindFirstChild("GameModes")
	local parkour = modes and modes:FindFirstChild("Parkour")
	local source = parkour and parkour:FindFirstChild("Level" .. n)
	if not source then
		return nil
	end
	local ok, clone = pcall(function()
		return source:Clone()
	end)
	if not ok or not clone then
		return nil
	end
	local model = Instance.new("Model")
	model.Name = "MapPreview" .. n
	local strip: { Instance } = {}
	for _, item in clone:GetDescendants() do
		if item:IsA("BasePart") then
			if item.Transparency >= 1 or STRIP[item.Name] then
				table.insert(strip, item)
			end
		elseif item:IsA("Sound") or item:IsA("Script") or item:IsA("LocalScript") then
			table.insert(strip, item)
		end
	end
	for _, item in strip do
		item:Destroy()
	end
	-- Bounding box of what is left (rotated parts by their world-axis extents).
	local lo = Vector3.new(math.huge, math.huge, math.huge)
	local hi = -lo
	local count = 0
	for _, part in clone:GetDescendants() do
		if part:IsA("BasePart") then
			count += 1
			local cf, size = part.CFrame, part.Size * 0.5
			local r, u, l = cf.RightVector, cf.UpVector, cf.LookVector
			local ext = Vector3.new(
				math.abs(r.X) * size.X + math.abs(u.X) * size.Y + math.abs(l.X) * size.Z,
				math.abs(r.Y) * size.X + math.abs(u.Y) * size.Y + math.abs(l.Y) * size.Z,
				math.abs(r.Z) * size.X + math.abs(u.Z) * size.Y + math.abs(l.Z) * size.Z
			)
			lo = lo:Min(cf.Position - ext)
			hi = hi:Max(cf.Position + ext)
		end
	end
	if count < 4 then
		-- Not streamed in yet (or empty): try again next time.
		clone:Destroy()
		model:Destroy()
		return nil
	end
	for _, child in clone:GetChildren() do
		child.Parent = model
	end
	clone:Destroy()
	local center = (lo + hi) * 0.5
	local span = hi - lo
	local sea = Instance.new("Part")
	sea.Name = "Sea"
	sea.Anchored = true
	sea.Material = Enum.Material.SmoothPlastic
	sea.Color = SEA
	sea.Size = Vector3.new(span.X * 1.6 + 120, 1, span.Z * 1.6 + 120)
	sea.CFrame = CFrame.new(center.X, lo.Y - 0.5, center.Z)
	sea.Parent = model
	return { model = model, center = center, span = span }
end

-- Camera distance that fits the whole course box in a viewport of `aspect` (width/height)
-- from PREVIEW_PITCH above the horizon. The ground footprint is fitted by the larger of
-- width and depth, widened to the footprint diagonal so no orbit angle crops a corner;
-- vertically by that footprint foreshortened by the pitch plus the course's height.
local function fitDistance(span: Vector3, aspect: number): number
	local footprint = math.max(math.max(span.X, span.Z), math.sqrt(span.X * span.X + span.Z * span.Z), 20)
	local pitch = math.rad(PREVIEW_PITCH)
	local tanV = math.tan(math.rad(PREVIEW_FOV * 0.5))
	local tanH = tanV * math.max(aspect, 0.2)
	local wide = footprint * 0.5 / tanH
	local tall = (footprint * math.sin(pitch) + span.Y * math.cos(pitch)) * 0.5 / tanV
	-- Half the footprint sits nearer the camera than the centre (and looks bigger).
	return math.max(wide, tall) * PREVIEW_MARGIN + footprint * 0.5 * math.cos(pitch) * 0.35
end

-- Window --------------------------------------------------------------------------------

type Card = {
	frame: Frame,
	band: Frame,
	icon: TextLabel,
	levelLabel: TextLabel,
	levelInk: UIStroke,
	name: TextLabel,
	stats: TextLabel,
	check: Frame,
	lock: Frame,
	body: CanvasGroup,
	chevron: TextLabel,
	stroke: UIStroke?,
	setPips: (number) -> (),
	pipRow: GuiObject?,
	-- "Clear <previous map> first" on a locked card (where the pips are).
	lockedLine: TextLabel,
}

-- A locked band: the accent kept recognisable, a little greyer and pulled toward a cool slate.
local function desaturate(color: Color3): Color3
	local y = color.R * 0.3 + color.G * 0.59 + color.B * 0.11
	return color:Lerp(Color3.new(y, y, y), LOCKED_GREY):Lerp(LOCKED_SLATE, LOCKED_DARK)
end

function MapPicker.build(screen: ScreenGui, deps: Deps): Picker
	local accent = Theme.World.Mint
	-- Minimum 400 tall: a phone gets that window at x1.25 (side by side, the grid scrolling
	-- its last row); the side panel's fixed rows and a slim preview still fit.
	local window = Kit.window(screen, "Maps", "Pick a Map", "🗺️", accent, Vector2.new(880, 560), Vector2.new(420, 400))
	deps.register("Maps", window)
	local action = Net.event("Action")

	local selected = 1
	local pending: number? = nil
	local stacked = false
	local laidOut = false

	-- One scroll for the grid; in stacked mode the side panel joins it below the grid.
	local scroll = Kit.scrolling(window.content, { Name = "Scroll" })
	-- Only scrolls in the stacked layout; keep the bar easy to spot there.
	scroll.ScrollBarThickness = 8
	scroll.ScrollBarImageColor3 = C.Text
	scroll.ScrollBarImageTransparency = 0.35
	Kit.list(scroll, 10)
	-- Stacked, the map's details are under the fold: a shade and a bouncing arrow say so.
	Kit.scrollCue(scroll)
	local grid = Kit.new("Frame", {
		Name = "Grid",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		LayoutOrder = 1,
		Parent = scroll,
	})
	local gridLayout = Kit.new("UIGridLayout", {
		CellSize = UDim2.new(0.5, -CARD_GAP / 2, 0, CARD_MIN),
		CellPadding = UDim2.fromOffset(CARD_GAP, CARD_GAP),
		SortOrder = Enum.SortOrder.LayoutOrder,
		Parent = grid,
	}) :: UIGridLayout
	-- Room for the card lips and shadows at the bottom of the grid.
	Kit.padding(grid, 0).PaddingBottom = UDim.new(0, GRID_PAD)

	local side = Kit.panel(window.content, {
		Name = "Side",
		Glass = true,
		Size = UDim2.new(0, SIDE_W, 1, 0),
		Position = UDim2.fromScale(1, 0),
		AnchorPoint = Vector2.new(1, 0),
		LayoutOrder = 2,
		Radius = Kit.RADIUS.M + 2,
	})

	-- Preview well with the viewport, a fallback icon and a "MAP n" chip.
	local previewWell = Kit.well(side, {
		Name = "Preview",
		Color = SEA,
		Size = UDim2.new(1, -PREVIEW_INSET * 2, PREVIEW_SHARE, 0),
		Position = UDim2.fromOffset(PREVIEW_INSET, PREVIEW_INSET),
		Radius = Kit.RADIUS.M,
	})
	previewWell.ClipsDescendants = true
	local viewport = Kit.new("ViewportFrame", {
		Name = "View",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		Ambient = Color3.fromRGB(190, 196, 210),
		LightColor = Color3.new(1, 1, 1),
		LightDirection = Vector3.new(-0.4, -1, 0.5),
		ZIndex = 2,
		Parent = previewWell,
	}) :: ViewportFrame
	Kit.corner(viewport, Kit.RADIUS.M)
	local camera = Instance.new("Camera")
	camera.FieldOfView = PREVIEW_FOV
	camera.Parent = viewport
	viewport.CurrentCamera = camera
	local fallback = Kit.text(previewWell, {
		Name = "Fallback",
		Text = "",
		TextSize = 72,
		Size = UDim2.fromScale(1, 1),
		StrokeThickness = 0,
		ZIndex = 3,
	})
	local levelChip = Kit.pill(side, {
		Name = "LevelChip",
		Text = "",
		Font = Theme.Fonts.Display,
		TextSize = T.Small,
		Color = C.Gold,
		Solid = true,
		Size = UDim2.fromOffset(90, 26),
		Position = UDim2.fromOffset(PREVIEW_INSET + 8, PREVIEW_INSET + 8),
		ZIndex = 4,
	})
	readable(levelChip)

	-- About 45% of the side panel's height, capped so the rows below always fit.
	local function sizePreview()
		-- (pcall: the Lune preview export's GUI stand-ins have no AbsoluteSize.)
		local ok, size = pcall(function()
			return side.AbsoluteSize
		end)
		local h = if ok and typeof(size) == "Vector2" then size.Y else 0
		if h <= 0 then
			return
		end
		local room = h - PREVIEW_BOTTOM - PREVIEW_INSET
		local height = math.max(math.min(math.floor(h * PREVIEW_SHARE), room), 60)
		previewWell.Size = UDim2.new(1, -PREVIEW_INSET * 2, 0, height)
	end
	side:GetPropertyChangedSignal("AbsoluteSize"):Connect(sizePreview)

	local sideName = Kit.title(side, {
		Name = "MapName",
		Text = "",
		TextSize = T.H3,
		TextWrapped = false,
		TextTruncate = Enum.TextTruncate.AtEnd,
		TextXAlignment = Enum.TextXAlignment.Left,
		Size = UDim2.new(1, -24, 0, NAME_H),
		Position = UDim2.new(0, 12, 1, -NAME_BOTTOM),
		AnchorPoint = Vector2.new(0, 1),
		TextColor3 = C.Text,
	})
	local setSidePips = deps.pips(side, {
		Name = "Difficulty",
		Size = UDim2.new(1, -24, 0, 16),
		Position = UDim2.new(0, 12, 1, -(PIPS_BOTTOM + 16)),
	})
	local sideStats = readable(Kit.text(side, {
		Name = "Stats",
		Text = "",
		Font = F.UI,
		TextSize = T.Body,
		TextWrapped = false,
		TextTruncate = Enum.TextTruncate.AtEnd,
		TextXAlignment = Enum.TextXAlignment.Left,
		Size = UDim2.new(1, -24, 0, STATS_H),
		Position = UDim2.new(0, 12, 1, -STATS_BOTTOM),
		AnchorPoint = Vector2.new(0, 1),
		TextColor3 = C.Text,
	}))
	local blurb = readable(Kit.text(side, {
		Name = "Blurb",
		Text = "",
		TextSize = T.Body,
		TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Size = UDim2.new(1, -24, 0, BLURB_H),
		Position = UDim2.new(0, 12, 1, -BLURB_BOTTOM),
		AnchorPoint = Vector2.new(0, 1),
		TextColor3 = C.TextDim,
		StrokeThickness = 0,
	}))
	local reward = readable(Kit.text(side, {
		Name = "Reward",
		Text = "",
		Font = F.UI,
		TextSize = T.Small,
		TextWrapped = false,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Size = UDim2.new(1, -24, 0, 18),
		Position = UDim2.new(0, 12, 1, -REWARD_BOTTOM),
		AnchorPoint = Vector2.new(0, 1),
		TextColor3 = C.MoneyText,
	}))
	local play = Kit.button(side, {
		Name = "Play",
		Text = "PLAY",
		Font = Theme.Fonts.Display,
		Color = C.Gold,
		Breathe = true,
		Size = UDim2.new(1, -24, 0, PLAY_H),
		Position = UDim2.new(0.5, 0, 1, -PLAY_BOTTOM),
		AnchorPoint = Vector2.new(0.5, 1),
	}, function()
		action:FireServer({ action = "ModeStart", mode = "parkour", level = selected })
		deps.closeAll()
	end)
	-- Gamepad starts on PLAY.
	play:SetAttribute("FocusFirst", true)

	-- "Clear <map> first!" bubble over the grid (the toast for locked taps).
	local hint = Kit.pill(window.frame, {
		Name = "Hint",
		Text = "",
		Font = Theme.Fonts.Display,
		TextSize = T.Small,
		Color = C.Bad,
		Solid = true,
		AutomaticSize = Enum.AutomaticSize.X,
		Size = UDim2.fromOffset(0, 28),
		Position = UDim2.new(0.5, 0, 0, 78),
		AnchorPoint = Vector2.new(0.5, 0),
		Visible = false,
		ZIndex = 20,
	})
	readable(hint)
	local hintToken = 0
	local function showHint(text: string)
		hintToken += 1
		local mine = hintToken
		hint.Text = text
		hint.Visible = true
		Kit.pop(hint, 1.2)
		task.delay(1.8, function()
			if hintToken == mine then
				hint.Visible = false
			end
		end)
	end

	-- Preview cache and orbit ------------------------------------------------------------
	local previews: { [number]: Preview } = {}
	local shown: Preview? = nil
	local angle = math.rad(35)
	local function placeCamera()
		local p = shown
		if not p then
			return
		end
		local px = viewport.AbsoluteSize
		local aspect = if px.Y > 0 then px.X / px.Y else 1.4
		local d = fitDistance(p.span, aspect)
		-- High 3/4 view: PREVIEW_PITCH degrees down onto the course.
		local pitch = math.rad(PREVIEW_PITCH)
		local flat = d * math.cos(pitch)
		local offset = Vector3.new(math.cos(angle) * flat, d * math.sin(pitch), math.sin(angle) * flat)
		camera.CFrame = CFrame.lookAt(p.center + offset, p.center)
	end
	local function showPreview(n: number)
		local p = previews[n]
		if not p then
			local ok, built = pcall(buildPreview, n)
			if ok and built then
				previews[n] = built
				p = built
			end
		end
		if shown and shown ~= p then
			shown.model.Parent = nil
		end
		shown = p
		if p then
			p.model.Parent = viewport
			fallback.Visible = false
			placeCamera()
		else
			local list = levelList(parkourInfo())
			fallback.Text = iconOf(list[n], n)
			fallback.Visible = true
		end
	end
	local orbit: RBXScriptConnection? = nil
	window.onOpen.Event:Connect(function()
		if orbit then
			return
		end
		pcall(function()
			orbit = RunService.RenderStepped:Connect(function(dt: number)
				if shown then
					angle += dt * ORBIT_SPEED
					placeCamera()
				end
			end)
		end)
	end)
	window.onClose.Event:Connect(function()
		if orbit then
			orbit:Disconnect()
			orbit = nil
		end
	end)

	-- Cards --------------------------------------------------------------------------------
	local cards: { Card } = {}
	local refresh: () -> ()

	local function wobble(gui: GuiObject)
		Kit.tween(gui, 0.06, { Rotation = -5 })
		task.delay(0.06, function()
			Kit.tween(gui, 0.08, { Rotation = 4 })
			task.delay(0.08, function()
				Kit.tween(gui, 0.2, { Rotation = 0 }, Enum.EasingStyle.Back)
			end)
		end)
	end

	for i = 1, MAP_COUNT do
		local frame = Kit.panel(grid, {
			Name = "Map" .. i,
			Glass = true,
			Size = UDim2.fromScale(1, 1),
			LayoutOrder = i,
			Radius = Kit.RADIUS.M,
		})
		local band = Kit.new("Frame", {
			Name = "Band",
			BackgroundColor3 = C.Gold,
			BorderSizePixel = 0,
			Size = UDim2.new(1, 0, 0, BAND_H),
			ZIndex = 2,
			Parent = frame,
		})
		Kit.corner(band, Kit.RADIUS.M)
		-- Square off the bottom of the band.
		local cover = Kit.new("Frame", {
			Name = "Cover",
			BackgroundColor3 = Color3.new(1, 1, 1),
			BorderSizePixel = 0,
			Size = UDim2.new(1, 0, 0, 12),
			Position = UDim2.new(0, 0, 1, -12),
			ZIndex = 2,
			Parent = band,
		})
		-- Moulded look: a touch darker toward the bottom (the cover carries on the same ramp).
		Kit.gradient(band, Color3.new(1, 1, 1), Color3.new(0.86, 0.86, 0.9))
		Kit.gradient(cover, Color3.new(0.92, 0.92, 0.94), Color3.new(0.86, 0.86, 0.9))
		local icon = Kit.text(band, {
			Name = "Icon",
			Text = "",
			TextSize = ICON_PX,
			Size = UDim2.fromOffset(26, BAND_H),
			Position = UDim2.fromOffset(6, 0),
			StrokeThickness = 0,
			ZIndex = 3,
		})
		local levelLabel = readable(Kit.title(band, {
			Name = "Level",
			Text = "MAP " .. i,
			TextSize = T.Small,
			TextWrapped = false,
			TextXAlignment = Enum.TextXAlignment.Left,
			Size = UDim2.new(0, 72, 1, 0),
			Position = UDim2.fromOffset(34, 0),
			StrokeThickness = 0,
			ZIndex = 3,
		}))
		-- White on a locked (grey) band wears the dark outline of text on glass; ink text on
		-- an accent band has none.
		local levelInk = Kit.textStroke(levelLabel, Theme.Glass.TextStroke, Theme.Glass.TextStrokeFade)
		levelInk.Color = Theme.Glass.TextInk
		levelInk.Enabled = false
		-- Best time on the right of the band, then the cleared check or the lock.
		local stats = readable(Kit.text(band, {
			Name = "Stats",
			Text = "",
			Font = F.UI,
			TextSize = T.Small,
			TextWrapped = false,
			TextTruncate = Enum.TextTruncate.AtEnd,
			TextXAlignment = Enum.TextXAlignment.Right,
			Size = UDim2.new(1, -136, 1, 0),
			Position = UDim2.new(1, -30, 0, 0),
			AnchorPoint = Vector2.new(1, 0),
			StrokeThickness = 0,
			ZIndex = 3,
		}))
		local check = Kit.icon(band, "Check", 16, C.Good, {
			Position = UDim2.new(1, -8, 0.5, 0),
			AnchorPoint = Vector2.new(1, 0.5),
			ZIndex = 3,
		})
		-- Lock badge: a 20 px lock on a dark disc so it reads on any band colour.
		local lock = Kit.new("Frame", {
			Name = "Lock",
			BackgroundColor3 = C.Ink,
			BackgroundTransparency = 0.15,
			BorderSizePixel = 0,
			Size = UDim2.fromOffset(LOCK_DISC, LOCK_DISC),
			Position = UDim2.new(1, -4, 0.5, 0),
			AnchorPoint = Vector2.new(1, 0.5),
			ZIndex = 3,
			Parent = band,
		})
		Kit.corner(lock, LOCK_DISC)
		Kit.icon(lock, "Lock", LOCK_SIZE, C.Text, {
			Position = UDim2.fromScale(0.5, 0.5),
			AnchorPoint = Vector2.new(0.5, 0.5),
			ZIndex = 4,
		})
		-- Name and pips, centred under the band.
		local body = Kit.new("CanvasGroup", {
			Name = "Body",
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			Size = UDim2.new(1, 0, 1, -BAND_H),
			Position = UDim2.fromOffset(0, BAND_H),
			ZIndex = 2,
			Parent = frame,
		}) :: CanvasGroup
		Kit.corner(body, Kit.RADIUS.M)
		Kit.list(body, 2).VerticalAlignment = Enum.VerticalAlignment.Center
		Kit.padding(body, 0, 10)
		-- Map names are the biggest text on a card: two px over the captions.
		local name = readable(
			Kit.title(body, {
				Name = "MapName",
				Text = "",
				TextSize = T.Body,
				TextWrapped = false,
				TextTruncate = Enum.TextTruncate.AtEnd,
				TextXAlignment = Enum.TextXAlignment.Left,
				-- Leaves room on the right for the selected card's chevron.
				Size = UDim2.new(1, -14, 0, 22),
				LayoutOrder = 1,
				TextColor3 = C.Text,
				ZIndex = 2,
			}),
			2
		)
		local setPips = deps.pips(body, {
			Name = "Difficulty",
			Pip = 8,
			Size = UDim2.new(1, 0, 0, 14),
		})
		local pipRow = body:FindFirstChild("Difficulty")
		if pipRow and pipRow:IsA("GuiObject") then
			pipRow.LayoutOrder = 2
		end
		local lockedLine = readable(Kit.text(body, {
			Name = "Locked",
			Text = "",
			Font = F.UI,
			TextSize = T.Small,
			TextWrapped = false,
			TextTruncate = Enum.TextTruncate.AtEnd,
			TextXAlignment = Enum.TextXAlignment.Left,
			Size = UDim2.new(1, 0, 0, 20),
			LayoutOrder = 2,
			TextColor3 = C.TextDim,
			StrokeThickness = 0,
			Visible = false,
			ZIndex = 2,
		}))
		-- Small gold chevron on the right of the selected card's body.
		local chevron = Kit.text(frame, {
			Name = "Chevron",
			Text = "▶",
			TextSize = T.Small,
			TextColor3 = C.Gold,
			Size = UDim2.fromOffset(14, 18),
			Position = UDim2.new(1, -8, 0.5, BAND_H / 2),
			AnchorPoint = Vector2.new(1, 0.5),
			StrokeThickness = 0,
			Visible = false,
			ZIndex = 3,
		})
		local hit = Kit.new("TextButton", {
			Name = "Hit",
			Text = "",
			AutoButtonColor = false,
			BackgroundTransparency = 1,
			Size = UDim2.fromScale(1, 1),
			ZIndex = 7,
			Parent = frame,
		})
		local card: Card = {
			frame = frame,
			band = band,
			icon = icon,
			levelLabel = levelLabel,
			levelInk = levelInk,
			name = name,
			stats = stats,
			check = check,
			lock = lock,
			body = body,
			chevron = chevron,
			stroke = frame:FindFirstChildOfClass("UIStroke"),
			setPips = setPips,
			pipRow = if pipRow and pipRow:IsA("GuiObject") then pipRow else nil,
			lockedLine = lockedLine,
		}
		cards[i] = card
		hit.Activated:Connect(function()
			local info = parkourInfo()
			local unlocked = if info then tonumber(info.unlocked) or 1 else 1
			if i > unlocked then
				Kit.sound("Error")
				wobble(frame)
				local list = levelList(info)
				showHint(string.format("Clear %s first!", nameOf(list[i - 1], i - 1)))
				return
			end
			Kit.sound("Click")
			Kit.pop(frame, 0.5)
			if selected ~= i then
				selected = i
				refresh()
			end
		end)
	end

	local function paintCard(card: Card, i: number, lv: any, unlocked: number, info: { [string]: any }?, before: any)
		local color = accentOf(lv, i)
		local locked = i > unlocked
		local clears = if type(lv) == "table" then tonumber(lv.clears) or 0 else 0
		local best = if type(lv) == "table" then tonumber(lv.best) or 0 else 0
		-- Locked: a darker, greyer band of the map's colour with a lock badge; text stays at
		-- full brightness. The body wears a faint wash of the band colour.
		local bandColor = if locked then desaturate(color) else color
		card.body.BackgroundColor3 = bandColor
		card.body.BackgroundTransparency = BODY_WASH
		card.band.BackgroundColor3 = bandColor
		local cover = card.band:FindFirstChild("Cover")
		if cover and cover:IsA("Frame") then
			cover.BackgroundColor3 = bandColor
		end
		local ink = if locked then C.Text else Kit.inkOn(color)
		card.levelLabel.TextColor3 = ink
		card.levelLabel.TextTransparency = 0
		card.levelInk.Enabled = locked
		card.stats.TextColor3 = ink
		paintIcon(card.icon, lv, i)
		card.icon.TextTransparency = 0
		card.name.Text = nameOf(lv, i)
		card.setPips(if type(lv) == "table" then tonumber(lv.difficulty) or i else i)
		card.check.Visible = clears > 0 and not locked
		card.lock.Visible = locked
		card.body.GroupTransparency = 0
		-- Locked: what to do ("Clear Sunny Steps first") where the pips are, and what the map's
		-- first clear pays beside the lock.
		if card.pipRow then
			card.pipRow.Visible = not locked
		end
		card.lockedLine.Visible = locked
		card.lockedLine.Text = if locked then string.format("Clear %s first", nameOf(before, i - 1)) else ""
		local pays = if locked then packCash(info, i) else nil
		if locked then
			card.stats.Text = if pays and pays > 0 then "+" .. Format.money(pays) else ""
		elseif clears <= 0 then
			card.stats.Text = ""
		else
			card.stats.Text = if best > 0 then "Best " .. deps.runTime(best) else deps.plural(clears, "clear")
		end
		-- Selected: a gold rim, the raised card fill and a gold chevron.
		local isSelected = i == selected
		local stroke = card.stroke
		local pane = stroke and stroke.Parent
		if stroke and pane and pane:IsA("GuiObject") then
			Kit.paintGlass(pane, nil, if isSelected then Theme.Glass.SurfaceHi else nil, if isSelected then C.Gold else nil)
			stroke.Thickness = if isSelected then 3 else 1
		end
		card.chevron.Visible = isSelected
	end

	-- The reward line of the selected map. Inside the reward cooldown a cleared map still
	-- pays on every clean run (the repeat share of its pack; nothing with gear on): say so
	-- instead of only counting the cooldown down.
	local function paintReward(info: { [string]: any }?, list: { any })
		local lv = list[selected]
		if not info or type(lv) ~= "table" then
			reward.Text = ""
			return
		end
		local preview = info.rewardPreview
		local share = if type(preview) == "table" then tonumber(preview.repeatShare) or 0 else 0
		local left = (tonumber(info.cooldownEnds) or 0) - os.time()
		local pack = packCash(info, selected)
		if share <= 0 or left <= 0 or (tonumber(lv.clears) or 0) == 0 or not pack then
			deps.parkourReward(reward, info, selected)
			return
		end
		local geared = info.gear ~= nil and info.gear ~= "none"
		-- The run again bonus rests after it was paid: this map for two minutes, every map
		-- for one. The server says how long for each map (levels[i].repeatRest, counted down
		-- by the snapshot's age); an older server priced only info.level.
		local rest = 0
		if type(lv.repeatRest) == "number" then
			rest = math.max(0, math.ceil(lv.repeatRest - State.age()))
		elseif type(preview) == "table" and preview.full == false and selected == (tonumber(info.level) or 1) then
			rest = math.max(0, math.ceil((tonumber(preview.repeatRest) or 0) - State.age()))
		end
		reward.TextColor3 = if geared or rest > 0 then C.TextDim else C.MoneyText
		reward.Text = if geared
			then string.format("Gear on: no reward · full in %s", Format.time(left))
			elseif rest > 0 then "Bonus is resting, back in " .. Format.time(rest)
			else string.format("Run again: +%s · full in %s", Format.money(math.floor(pack * share)), Format.time(left))
	end

	local function paintSide(info: { [string]: any }?, list: { any })
		local lv = list[selected]
		levelChip.Text = "MAP " .. selected
		levelChip.BackgroundColor3 = accentOf(lv, selected)
		levelChip.TextColor3 = Kit.inkOn(levelChip.BackgroundColor3)
		sideName.Text = nameOf(lv, selected)
		local clears = if type(lv) == "table" then tonumber(lv.clears) or 0 else 0
		local best = if type(lv) == "table" then tonumber(lv.best) or 0 else 0
		setSidePips(if type(lv) == "table" then tonumber(lv.difficulty) or selected else selected)
		sideStats.Text = string.format("Best %s  ·  %s", if best > 0 then deps.runTime(best) else "--", deps.plural(clears, "clear"))
		blurb.Text = if type(lv) == "table" and type(lv.blurb) == "string" then lv.blurb else "Jump, bounce and slide across the sky!"
		paintReward(info, list)
		local runningHere = info ~= nil and info.running == true and tonumber(info.level) == selected
		Kit.setButton(play, if runningHere then "RESTART" else "PLAY")
		if window.isOpen() then
			showPreview(selected)
		end
	end

	refresh = function()
		local info = parkourInfo()
		local list = levelList(info)
		local count = math.max(#list, 1)
		local unlocked = math.clamp(if info then tonumber(info.unlocked) or 1 else 1, 1, math.max(count, 1))
		selected = math.clamp(selected, 1, unlocked)
		for i, card in cards do
			card.frame.Visible = #list == 0 or list[i] ~= nil
			paintCard(card, i, list[i], unlocked, info, list[i - 1])
		end
		paintSide(info, list)
	end

	-- Layout: side panel beside the grid, or stacked under it on narrow screens. Beside the
	-- grid the cards stretch to fill the column so all ten show without scrolling.
	local function layout()
		local viewportW = math.huge
		pcall(function()
			local cam = workspace.CurrentCamera
			if cam then
				viewportW = cam.ViewportSize.X
			end
		end)
		local size = window.size()
		local narrow = viewportW < STACK_W or size.X < SIDE_BY_SIDE_MIN_W
		local cardH = CARD_MIN
		if not narrow then
			-- Window content well: 84 px of header and margins, 10 px padding each side.
			local rows = math.ceil(MAP_COUNT / 2)
			local available = size.Y - 84 - 20 - GRID_PAD - CARD_GAP * (rows - 1)
			cardH = math.clamp(math.floor(available / rows), CARD_MIN, CARD_MAX)
		end
		gridLayout.CellSize = UDim2.new(0.5, -CARD_GAP / 2, 0, cardH)
		if laidOut and narrow == stacked then
			return
		end
		laidOut = true
		stacked = narrow
		if stacked then
			scroll.Size = UDim2.fromScale(1, 1)
			side.Parent = scroll
			side.AnchorPoint = Vector2.zero
			side.Position = UDim2.new()
			side.Size = UDim2.new(1, 0, 0, SIDE_STACK_H)
		else
			side.Parent = window.content
			scroll.Size = UDim2.new(1, -(SIDE_W + 12), 1, 0)
			side.AnchorPoint = Vector2.new(1, 0)
			side.Position = UDim2.fromScale(1, 0)
			side.Size = UDim2.new(0, SIDE_W, 1, 0)
		end
	end
	layout()
	window.onResize.Event:Connect(layout)
	sizePreview()

	State.changed.Event:Connect(function()
		if window.isOpen() then
			refresh()
		end
	end)
	local tickId = 0
	window.onOpen.Event:Connect(function()
		showPreview(selected)
		-- The cooldown line counts down while the window is open (one loop per open: a
		-- reopen within the second retires the previous loop).
		tickId += 1
		local myId = tickId
		task.spawn(function()
			while window.isOpen() and tickId == myId do
				task.wait(1)
				if window.isOpen() and tickId == myId then
					local info = parkourInfo()
					paintReward(info, levelList(info))
				end
			end
		end)
	end)

	local function beforeOpen()
		layout()
		local info = parkourInfo()
		selected = if pending then pending elseif info then tonumber(info.unlocked) or 1 else 1
		pending = nil
		scroll.CanvasPosition = Vector2.zero
		refresh()
		local list: { GuiObject } = {}
		for _, card in cards do
			table.insert(list, card.frame)
		end
		table.insert(list, side)
		deps.ripple(list)
	end

	refresh()
	return {
		window = window,
		beforeOpen = beforeOpen,
		preselect = function(level: number?)
			pending = if type(level) == "number" and level == level then math.floor(level) else nil
		end,
		select = function(level: number)
			if level == level then
				selected = math.floor(level)
				refresh()
			end
		end,
	}
end

return MapPicker
