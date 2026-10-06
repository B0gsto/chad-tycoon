--[[
	Pads: the step-on pads and their floating labels.
	Part of the world generator; see Server.WorldBuilder for the overview and plot axes.

	Every pad is a small flat button: a coloured top (one colour per job, Theme.World.Pads:
	butter buys, sunny-orange merge, blue deposit, warm special pads) on a thin, low rounded base
	in Theme.World.PadRim reaching Layout.PAD_RIM past it. The top carries a small printed icon
	("+5", "$", a gift) in Theme.World.PadPrint. Above each pad floats plain text (a
	BillboardGui, no card): the name (`title`) in white and the price or status Tycoon writes
	into `sub` in green, both with an Ink outline. Merge shows only "MERGE" in sunny yellow and
	Deposit a bigger label. A disabled pad turns soft grey (Theme.Colors.PadDisabled).
]]

local Layout = require(script.Parent.Parent.PlotLayout)
local Common = require(script.Parent.Common)

type Builder = Common.Builder
type Pad = Common.Pad

local UPRIGHT = Common.UPRIGHT
local theme = Common.theme
local World = theme.World
local RIM = World.PadRim or World.Teal

local Pads = {}

-- Rim (base) height; the painted top stands a hair proud of it.
local RIM_TOP = 0.35
-- The deposit pad's frame stands a little taller.
local RIM_TOP_BIG = 0.6
local TOP_THICK = 0.3
-- Height of the coloured top above the base.
local TOP_RISE = 0.15
-- The trigger reaches this far past the coloured top (still on the base), so a character whose
-- root is over the top's edge counts as standing on it.
local TRIGGER_GROW = 0.4
-- Floating label: height of its bottom above the pad top, width in studs (wider for big pads),
-- and the camera distance it stops drawing at.
local LABEL_LIFT = 2.6
local LABEL_W = 6
local LABEL_W_MAX = 8
local LABEL_MAX_DISTANCE = 90
-- Pads whose label sits at another height so it clears the labels of pads behind it in the
-- spawn view (the deposit label sits low on its big pad, the bulk speed upgrade's high).
local LABEL_LIFTS: { [string]: number } = { Deposit = 0.9, ProcUp10 = 4.2 }
-- Share of the stud width that scales with distance, and the fixed pixel part added to it.
local LABEL_SCALE = 0.8
local LABEL_PX = 24

-- Pads that show a fixed label (their action) instead of a name and a price.
local STATIC: { [string]: boolean } = { Merge = true }

-- Which Theme.World.Pads colour each pad wears.
local JOB_KEYS: { [string]: string } = { Unlock1 = "Unlock", Unlock2 = "UnlockVip" }
local function jobKey(name: string): string
	if string.sub(name, 1, 3) == "Buy" and name ~= "BuyTier" then
		return "Buy"
	elseif string.sub(name, 1, 6) == "ProcUp" then
		return "Process"
	end
	return JOB_KEYS[name] or name
end

-- The big printed mark on each pad's top.
local function iconText(name: string): string
	local icons = theme.Icons
	if string.sub(name, 1, 3) == "Buy" and name ~= "BuyTier" then
		return "+" .. string.sub(name, 4)
	end
	local fixed = {
		AutoMerge = "AUTO",
		Merge = icons.Unit .. "+" .. icons.Unit,
		BuyTier = "⬆️",
		Deposit = icons.Orb,
		ProcUp1 = "⬆️",
		ProcUp10 = "⬆️x10",
		Collect = "$",
		Unlock1 = icons.Chest,
		Unlock2 = icons.Premium,
		Free = icons.Free,
	}
	return fixed[name] or ""
end

-- Plot-local direction from the pad toward its far edge, i.e. away from where the player walks
-- up. The top icon reads upright that way.
local function farDir(name: string): Vector2
	if name == "Deposit" or name == "Collect" or string.sub(name, 1, 6) == "ProcUp" then
		return Vector2.new(-1, 0)
	elseif string.sub(name, 1, 6) == "Unlock" or name == "Free" then
		return Vector2.new(1, 0)
	end
	return Vector2.new(0, 1)
end

-- Each pad's job colour, print colour and top icon, so setEnabled can repaint them.
type Painted = { color: Color3, print: Color3, icon: TextLabel }
local painted: { [BasePart]: Painted } = setmetatable({}, { __mode = "k" }) :: any

local function corner(parent: Instance, scale: number)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(scale, 0)
	c.Parent = parent
end

local function outline(parent: Instance, color: Color3, thickness: number, transparency: number?)
	local s = Instance.new("UIStroke")
	s.Color = color
	s.Thickness = thickness
	s.Transparency = transparency or 0
	s.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
	s.Parent = parent
end

local function text(parent: Instance, props: { [string]: any }): TextLabel
	local l = Instance.new("TextLabel")
	l.BackgroundTransparency = 1
	l.TextScaled = true
	l.TextWrapped = true
	l.Font = theme.Fonts.Display
	l.TextColor3 = World.Ink
	for key, value in props do
		(l :: any)[key] = value
	end
	l.Parent = parent
	return l
end

-- Thin rounded base: two crossed slabs plus a cylinder in each corner, so the outline is a
-- rounded rectangle Layout.PAD_RIM wider than the top on every side, `height` tall.
local function buildRim(B: Builder, x: number, z: number, sx: number, sz: number, height: number)
	local L, P = B.L, B.P
	local r = Layout.PAD_RIM
	local y = height / 2
	P({ Name = "PadBase", Size = Vector3.new(sx + 2 * r, height, sz), CFrame = L(x, y, z), Color = RIM })
	P({ Name = "PadBase", Size = Vector3.new(sx, height, sz + 2 * r), CFrame = L(x, y, z), Color = RIM })
	for _, dx in { -1, 1 } do
		for _, dz in { -1, 1 } do
			P({
				Name = "PadBase",
				Shape = Enum.PartType.Cylinder,
				Size = Vector3.new(height, 2 * r, 2 * r),
				CFrame = L(x + dx * sx / 2, y, z + dz * sz / 2) * UPRIGHT,
				Color = RIM,
			})
		end
	end
end

-- The printed mark on the pad top: a rim-coloured inner border and a big unstroked icon in
-- `printColor`, drawn on `face`. Returns the icon.
local function buildTopPrint(padPart: BasePart, face: Enum.NormalId, round: boolean, name: string, printColor: Color3): TextLabel
	local gui = Instance.new("SurfaceGui")
	gui.Name = "PadPrint"
	gui.Face = face
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 40
	gui.LightInfluence = 1
	gui.Parent = padPart
	local border = Instance.new("Frame")
	border.Name = "Border"
	border.AnchorPoint = Vector2.new(0.5, 0.5)
	border.Position = UDim2.fromScale(0.5, 0.5)
	border.Size = UDim2.fromScale(0.86, 0.86)
	border.BackgroundTransparency = 1
	border.Parent = gui
	corner(border, if round then 0.5 else 0.18)
	local ring = Instance.new("UIStroke")
	ring.Color = RIM
	ring.Thickness = 4
	ring.Transparency = 0
	ring.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	ring.Parent = border
	local icon = text(gui, {
		Name = "PadIcon",
		Text = iconText(name),
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(if round then 0.5 else 0.6, if round then 0.36 else 0.46),
		TextColor3 = printColor,
	})
	return icon
end

-- The floating label above a pad: a BillboardGui on the pad top with the name on top and the
-- big line (price / status) under it, both in the display font with an Ink outline. `width`
-- is in studs; part of the size is fixed pixels, so the label shrinks less than the world with
-- distance and does not fill the screen when the camera is beside the pad. Returns (name, big line).
local function buildLabel(padPart: BasePart, lift: number, width: number): (TextLabel, TextLabel)
	local h = width * 0.34
	local gui = Instance.new("BillboardGui")
	gui.Name = "PadLabel"
	gui.Adornee = padPart
	gui.Size = UDim2.new(width * LABEL_SCALE, LABEL_PX, h * LABEL_SCALE, LABEL_PX * 0.34)
	gui.StudsOffsetWorldSpace = Vector3.new(0, lift + h / 2, 0)
	gui.MaxDistance = LABEL_MAX_DISTANCE
	gui.LightInfluence = 0
	gui.Parent = padPart
	local function line(name: string, y: number, height: number, color: Color3): TextLabel
		local l = text(gui, {
			Name = name,
			Text = "",
			AnchorPoint = Vector2.new(0.5, 0),
			Position = UDim2.fromScale(0.5, y),
			Size = UDim2.fromScale(1, height),
			TextColor3 = color,
		})
		outline(l, World.Ink, 2)
		return l
	end
	local title = line("Title", 0, 0.44, World.White or Color3.new(1, 1, 1))
	local main = line("Main", 0.44, 0.56, theme.Colors.MoneyText)
	main.Font = theme.Fonts.Number
	return title, main
end

local function buildPad(B: Builder, name: string, color: Color3, title: string, sub: string): Pad
	local L, P = B.L, B.P
	local spot = Layout.PADS[name]
	assert(spot, "no layout for pad " .. name)
	local x, z, sx, sz = spot.x, spot.z, spot.sizeX, spot.sizeZ
	local job = jobKey(name)
	color = World.Pads[job] or color
	local printColor = (World.PadPrint and World.PadPrint[job]) or World.TealInk or World.Ink
	local far = farDir(name)
	local r = Layout.PAD_RIM
	local base = if name == "Deposit" then RIM_TOP_BIG else RIM_TOP
	local topY = base + TOP_RISE
	local padPart: BasePart
	local icon: TextLabel
	if spot.round then
		P({
			Name = "PadBase",
			Shape = Enum.PartType.Cylinder,
			Size = Vector3.new(base, sx + 2 * r, sx + 2 * r),
			CFrame = L(x, base / 2, z) * UPRIGHT,
			Color = RIM,
		})
		-- The cylinder's top cap is its Right face, whose GUI "up" is the part's +Y; the yaw turns
		-- that toward the far edge.
		padPart = P({
			Name = "Pad_" .. name,
			Shape = Enum.PartType.Cylinder,
			Size = Vector3.new(TOP_THICK, sx, sz),
			CFrame = L(x, topY - TOP_THICK / 2, z) * CFrame.Angles(0, math.atan2(far.Y, -far.X), 0) * UPRIGHT,
			Color = color,
		})
		icon = buildTopPrint(padPart, Enum.NormalId.Right, true, name, printColor)
	else
		buildRim(B, x, z, sx, sz, base)
		-- A Top-face GUI reads upright toward the part's -Z, so the top is turned to point -Z at
		-- the far edge (swapping its size when that is sideways).
		local sideways = far.X ~= 0
		padPart = P({
			Name = "Pad_" .. name,
			Size = if sideways then Vector3.new(sz, TOP_THICK, sx) else Vector3.new(sx, TOP_THICK, sz),
			CFrame = L(x, topY - TOP_THICK / 2, z) * CFrame.Angles(0, math.atan2(-far.X, -far.Y), 0),
			Color = color,
		})
		icon = buildTopPrint(padPart, Enum.NormalId.Top, false, name, printColor)
	end

	local width = math.clamp(math.max(sx, sz) * 1.1, LABEL_W, LABEL_W_MAX)
	local titleLine, mainLine = buildLabel(padPart, LABEL_LIFTS[name] or LABEL_LIFT, width)
	painted[padPart] = { color = color, print = printColor, icon = icon }
	-- Server.Tycoon writes the pad's name into `title` and the price / status into `sub` (and
	-- recolours it). Pads it never prices (Merge) show their action as one big sunny line; the
	-- labels it may clear stay hidden so the label keeps its fixed text.
	local titleLabel, subLabel = titleLine, mainLine
	if STATIC[name] then
		mainLine.Visible = false
		titleLine.Size = UDim2.fromScale(1, 1)
		titleLine.Text = string.upper(title)
		titleLine.TextColor3 = World.Sunny or color
		titleLabel = text(titleLine, { Name = "Title", Text = title, Visible = false })
		subLabel = text(titleLine, { Name = "Sub", Text = sub, Visible = false })
	else
		titleLabel.Text = title
		subLabel.Text = sub
	end

	return {
		name = name,
		center = Vector3.new(x, 0, z),
		half = Vector2.new(sx / 2 + TRIGGER_GROW, sz / 2 + TRIGGER_GROW),
		part = padPart,
		title = titleLabel,
		sub = subLabel,
	}
end

-- Greys a pad out (soft Theme PadDisabled grey, never dark, with dark print) or restores its
-- job colour and print.
local function setEnabled(pad: Pad, enabled: boolean)
	local entry = painted[pad.part]
	if not entry then
		return
	end
	local fill = if enabled then entry.color else theme.Colors.PadDisabled
	local print = if enabled then entry.print else (World.TealInk or World.Ink)
	pad.part.Color = fill
	entry.icon.TextColor3 = print
end

Pads.buildPad = buildPad
Pads.setEnabled = setEnabled

return Pads
