--[[
	MapPicker: the "Maps" window (docs/parkour-maps.md, "Picker + server").

	Header "PICK A MAP". Left: a 2-column grid of the ten Parkour map cards, stretched so all
	ten fit without scrolling (accent band with the map's icon, "Level n", the best time and a
	check when cleared or a lock badge when locked; the name and difficulty pips below). The
	selected card carries a thick gold rim, a lighter body and a gold chevron; a locked one has
	a grey band (text kept bright) and wobbles with "Clear <previous map> first!" when tapped.
	Right, top to bottom: the selected map in a slowly orbiting ViewportFrame preview (panel
	width, about 45% of its height) with a "Level n" chip, name, pips, best/clears, blurb, the
	reward line and a gold PLAY (RESTART while that map is running) that fires ModeStart and
	closes every window. When the screen or window is narrow (viewport < 700 or window < 750
	wide) the side panel stacks under the grid in one scrolling column.

	The preview is a lazy clone of workspace.Map.GameModes.Parkour.Level<n> without its
	invisible volumes (Transparency 1, ParkourFinish, ParkourWater, Trigger), cached per map,
	over a flat sea plane, framed so the whole course bounding box fits the viewport from a high
	3/4 angle. It orbits on RenderStepped only while the window is open.

	Windows.luau owns the window list: it calls MapPicker.build with its register/closeAll
	helpers and the shared reward/pip helpers, and exposes Windows.open("Maps") and
	Windows.openMaps(level?). Reads State.data.modes.parkour (levels[i] = { name,
	difficulty, best, clears, bonus, theme?, blurb?, icon?, accent? }, unlocked, level,
	running).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

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
-- bounds (CARD_MIN is also the height in the stacked phone layout).
local CARD_MIN = 60
local CARD_MAX = 84
local CARD_GAP = 8
local BAND_H = 28
local GRID_PAD = 6
local STACK_W = 700
-- Below this window width the cards get too narrow for their pip row: stack instead.
local SIDE_BY_SIDE_MIN_W = 750
local SIDE_STACK_H = 440
-- Side panel: fixed rows measured up from the bottom (offsets of each row's bottom edge).
local PLAY_H = 50
local PLAY_BOTTOM = 12
local REWARD_BOTTOM = PLAY_BOTTOM + PLAY_H + 8
local BLURB_H = 40
local BLURB_BOTTOM = REWARD_BOTTOM + 18 + 4
local STATS_H = 20
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
local STRIP = { ParkourFinish = true, ParkourWater = true, Trigger = true }
local SEA = Color3.fromRGB(70, 175, 205)
local PREVIEW_FOV = 40
-- Camera pitch (degrees below the horizon) for the 3/4 overhead view, and the breathing
-- room left round the course in the frame.
local PREVIEW_PITCH = 40
local PREVIEW_MARGIN = 1.12
local ORBIT_SPEED = 0.12

local function parkourInfo(): { [string]: any }?
	local data = State.data
	local info = data and data.modes and data.modes.parkour
	return if type(info) == "table" then info else nil
end

local function levelList(info: { [string]: any }?): { any }
	return if info and type(info.levels) == "table" then info.levels else {}
end

local function accentOf(lv: any, i: number): Color3
	local key = if type(lv) == "table" and type(lv.accent) == "string" then lv.accent else ACCENTS[i] or "Sunny"
	local color = (Theme.World :: any)[key]
	if typeof(color) ~= "Color3" then
		color = (Theme.World :: any)[ACCENTS[i] or "Sunny"]
	end
	return if typeof(color) == "Color3" then color else C.Gold
end

local function iconOf(lv: any, i: number): string
	return if type(lv) == "table" and type(lv.icon) == "string" and lv.icon ~= "" then lv.icon else ICONS[i] or "🏁"
end

local function nameOf(lv: any, i: number): string
	return if type(lv) == "table" and type(lv.name) == "string" then lv.name else "Level " .. i
end

-- Preview -------------------------------------------------------------------------------

type Preview = { model: Model, center: Vector3, span: Vector3 }

-- Clones Level<n> without its invisible volumes into a Model over a sea plane, or nil when
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
	name: TextLabel,
	stats: TextLabel,
	check: Frame,
	lock: Frame,
	body: CanvasGroup,
	chevron: TextLabel,
	stroke: UIStroke?,
	fill: UIGradient?,
	setPips: (number) -> (),
}

-- Card body fills: the panel's own ramp, and a lighter one for the selected card.
local CARD_FILL = ColorSequence.new(Kit.lighten(C.SurfaceHi, 0.1), C.SurfaceHi:Lerp(Kit.lip(C.SurfaceHi), 0.12))
local CARD_FILL_SELECTED = ColorSequence.new(Kit.lighten(C.SurfaceHi, 0.26), Kit.lighten(C.SurfaceHi, 0.12))

-- Grey version of an accent for locked bands: its luminance, pulled toward a cool slate.
local function desaturate(color: Color3): Color3
	local y = color.R * 0.3 + color.G * 0.59 + color.B * 0.11
	return Color3.new(y, y, y):Lerp(LOCKED_SLATE, 0.6)
end

function MapPicker.build(screen: ScreenGui, deps: Deps): Picker
	local accent = Theme.World.Mint
	local window = Kit.window(screen, "Maps", "Pick a Map", "🗺️", accent, Vector2.new(880, 560), Vector2.new(420, 480))
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
		Elevated = true,
		Size = UDim2.new(0, SIDE_W, 1, 0),
		Position = UDim2.fromScale(1, 0),
		AnchorPoint = Vector2.new(1, 0),
		LayoutOrder = 2,
		Radius = Kit.RADIUS.M + 2,
	})

	-- Preview well with the viewport, a fallback icon and a "Level n" chip.
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
	local sideStats = Kit.text(side, {
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
		StrokeThickness = 0,
	})
	local blurb = Kit.text(side, {
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
	})
	local reward = Kit.text(side, {
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
		StrokeThickness = 0,
	})
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
			Elevated = true,
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
			TextSize = 18,
			Size = UDim2.fromOffset(26, BAND_H),
			Position = UDim2.fromOffset(6, 0),
			StrokeThickness = 0,
			ZIndex = 3,
		})
		local levelLabel = Kit.title(band, {
			Name = "Level",
			Text = "Level " .. i,
			TextSize = T.Small,
			TextWrapped = false,
			TextXAlignment = Enum.TextXAlignment.Left,
			Size = UDim2.new(0, 72, 1, 0),
			Position = UDim2.fromOffset(34, 0),
			StrokeThickness = 0,
			ZIndex = 3,
		})
		-- Best time on the right of the band, then the cleared check or the lock.
		local stats = Kit.text(band, {
			Name = "Stats",
			Text = "",
			Font = F.UI,
			TextSize = T.Tiny,
			TextWrapped = false,
			TextTruncate = Enum.TextTruncate.AtEnd,
			TextXAlignment = Enum.TextXAlignment.Right,
			Size = UDim2.new(1, -136, 1, 0),
			Position = UDim2.new(1, -30, 0, 0),
			AnchorPoint = Vector2.new(1, 0),
			StrokeThickness = 0,
			ZIndex = 3,
		})
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
		Kit.list(body, 4).VerticalAlignment = Enum.VerticalAlignment.Center
		Kit.padding(body, 0, 10)
		local name = Kit.title(body, {
			Name = "MapName",
			Text = "",
			TextSize = T.Body,
			TextWrapped = false,
			TextTruncate = Enum.TextTruncate.AtEnd,
			TextXAlignment = Enum.TextXAlignment.Left,
			-- Leaves room on the right for the selected card's chevron.
			Size = UDim2.new(1, -14, 0, 18),
			LayoutOrder = 1,
			TextColor3 = C.Text,
			ZIndex = 2,
		})
		local setPips = deps.pips(body, {
			Name = "Difficulty",
			Pip = 8,
			Size = UDim2.new(1, 0, 0, 14),
		})
		local pipRow = body:FindFirstChild("Difficulty")
		if pipRow and pipRow:IsA("GuiObject") then
			pipRow.LayoutOrder = 2
		end
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
			name = name,
			stats = stats,
			check = check,
			lock = lock,
			body = body,
			chevron = chevron,
			stroke = frame:FindFirstChildOfClass("UIStroke"),
			fill = frame:FindFirstChildOfClass("UIGradient"),
			setPips = setPips,
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

	local function paintCard(card: Card, i: number, lv: any, unlocked: number)
		local color = accentOf(lv, i)
		local locked = i > unlocked
		local clears = if type(lv) == "table" then tonumber(lv.clears) or 0 else 0
		local best = if type(lv) == "table" then tonumber(lv.best) or 0 else 0
		-- Locked: a grey (desaturated) band with a lock badge; text stays at full brightness.
		local bandColor = if locked then desaturate(color) else color
		card.band.BackgroundColor3 = bandColor
		local cover = card.band:FindFirstChild("Cover")
		if cover and cover:IsA("Frame") then
			cover.BackgroundColor3 = bandColor
		end
		local ink = if locked then C.Text else Kit.inkOn(color)
		card.levelLabel.TextColor3 = ink
		card.levelLabel.TextTransparency = 0
		card.stats.TextColor3 = ink
		card.icon.Text = iconOf(lv, i)
		card.icon.TextTransparency = 0
		card.name.Text = nameOf(lv, i)
		card.setPips(if type(lv) == "table" then tonumber(lv.difficulty) or i else i)
		card.check.Visible = clears > 0 and not locked
		card.lock.Visible = locked
		card.body.GroupTransparency = 0
		if locked or clears <= 0 then
			card.stats.Text = ""
		else
			card.stats.Text = if best > 0 then "Best " .. deps.runTime(best) else deps.plural(clears, "clear")
		end
		-- Selected: thick gold rim, a lighter body and a gold chevron.
		local isSelected = i == selected
		local stroke = card.stroke
		if stroke then
			stroke.Color = if isSelected then C.Gold else Kit.lip(C.SurfaceHi)
			stroke.Thickness = if isSelected then 4 else 1.5
		end
		if card.fill then
			card.fill.Color = if isSelected then CARD_FILL_SELECTED else CARD_FILL
		end
		card.chevron.Visible = isSelected
	end

	local function paintSide(info: { [string]: any }?, list: { any })
		local lv = list[selected]
		levelChip.Text = "Level " .. selected
		levelChip.BackgroundColor3 = accentOf(lv, selected)
		levelChip.TextColor3 = Kit.inkOn(levelChip.BackgroundColor3)
		sideName.Text = nameOf(lv, selected)
		local clears = if type(lv) == "table" then tonumber(lv.clears) or 0 else 0
		local best = if type(lv) == "table" then tonumber(lv.best) or 0 else 0
		setSidePips(if type(lv) == "table" then tonumber(lv.difficulty) or selected else selected)
		sideStats.Text = string.format("Best %s  ·  %s", if best > 0 then deps.runTime(best) else "--", deps.plural(clears, "clear"))
		blurb.Text = if type(lv) == "table" and type(lv.blurb) == "string" then lv.blurb else "Jump, bounce and slide over the sea!"
		if info and type(lv) == "table" then
			deps.parkourReward(reward, info, selected)
		else
			reward.Text = ""
		end
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
			paintCard(card, i, list[i], unlocked)
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
					local list = levelList(info)
					if info and type(list[selected]) == "table" then
						deps.parkourReward(reward, info, selected)
					end
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
