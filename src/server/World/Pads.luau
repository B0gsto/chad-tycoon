--[[
	Pads: the step-on pads and their floating labels.
	Part of the world generator; see Server.WorldBuilder for the overview and plot axes.

	Every pad is a small flat button with a coloured top (one colour per job, Theme.World.Pads:
	orange buys, sunny-yellow upgrades, cyan automation, blue deposit, warm special pads). The
	small pads (Layout.PADS `round`) are gym weight plates: a disc on a slightly taller dark
	rubber plate (Theme.World.PlateRubber) that shows as a lip round it, with a raised ring in
	a darker job colour and four grip slots printed on the disc. The big ones (deposit, merge)
	are rounded tiles on a thin, low base in Theme.World.PadRim reaching Layout.PAD_RIM past
	them. Every top carries a printed icon ("+5", "$", a gift) in Theme.World.PadPrint.

	Above each pad floats its label (a BillboardGui), a chunky three-line sign: the name
	(`title`) in white, what the pad does (`effect`, "+5 Chad") in cyan Theme.World.PadEffect,
	and the price or status Tycoon writes into `sub` in big Theme.World.PadPrice yellow, all
	with a thick Ink outline so they read on every pad colour. A price the player can't afford
	yet turns grey (PadPriceOff) and dims the effect line; a plain status stays white; a pad that
	needs a game pass shows its price as Ink print on a gold chip. With no effect the label
	closes up to two lines. The labels float above the head of a character standing on the pad;
	along the buy row they climb outward (LABEL_LIFTS) so no tag covers its neighbour. Merge
	shows only its name in sunny yellow, as a low tag standing at the pad's far left corner
	(LABEL_SHIFT), under the pen's crate labels in the spawn view. On a plot nobody owns the
	names and effects are dimmed (setClaimed). A disabled pad turns soft grey
	(Theme.Colors.PadDisabled).
]]

local Layout = require(script.Parent.Parent.PlotLayout)
local Common = require(script.Parent.Common)

type Builder = Common.Builder
type Pad = Common.Pad

local UPRIGHT = Common.UPRIGHT
local theme = Common.theme
local World = theme.World
local RIM = World.PadRim or World.Teal
local RUBBER = World.PlateRubber or World.Ink

local Pads = {}

-- Rim (base) height; the painted top stands a hair proud of it.
local RIM_TOP = 0.35
-- The deposit pad's frame stands a little taller.
local RIM_TOP_BIG = 0.6
-- How much taller a weight plate's rubber is than a tile's base, so its lip reads round the disc.
local PLATE_LIP = 0.25
local TOP_THICK = 0.3
-- Height of the coloured top above the base.
local TOP_RISE = 0.15
-- The trigger reaches this far past the coloured top (still on the base), so a character whose
-- root is over the top's edge counts as standing on it.
local TRIGGER_GROW = 0.4
-- Weight-plate print: the raised ring's size (share of the disc) and stroke in pixels, how much
-- of the way to Ink its darker job colour goes, and the four grip slots' length, width and
-- distance from the disc's centre (shares of the disc).
local PLATE_RING = 0.9
local PLATE_RING_PX = 6
local PLATE_RING_DARK = 0.35
local GRIP_LONG = 0.2
local GRIP_SHORT = 0.07
local GRIP_REACH = 0.35
-- Floating label: height of its bottom above the pad top (over the head of a character standing
-- on the pad: lower, the head hid the name), width in studs (LABEL_W_PER per stud of the pad's
-- long side, between LABEL_W and LABEL_W_MAX), height as a share of the width, and the camera
-- distance it stops drawing at.
local LABEL_LIFT = 5.6
local LABEL_W = 7.5
local LABEL_W_MAX = 10
local LABEL_W_PER = 1.5
local LABEL_H = 0.62
local LABEL_MAX_DISTANCE = 90
-- Pads whose label sits at another height. The deposit label floats over the head of a player
-- standing on its big pad (lower, the character and its dumbbell hid half of it); the bulk
-- speed upgrade's clears the single upgrade's.
-- The buy row's tags climb outward from the pen (Buy 5 / Buy 25 at LABEL_LIFT, Buy 1 / Buy 100
-- two studs higher, Auto Merge two more): from a camera above the row the farther tag is drawn
-- higher on screen, so neighbours that climb outward never meet (Auto Merge used to hang low,
-- right behind the Buy 25 / Buy 100 tags seen from the pen's side). The outer tags also float
-- clear of the fan zones' cards and crowd behind them.
-- The merge tag stands just above its pad: see LABEL_SHIFT.
local LABEL_LIFTS: { [string]: number } = {
	Deposit = 6.4,
	Buy1 = 7.6,
	Buy100 = 7.6,
	AutoMerge = 9.6,
	ProcUp10 = 7.2,
	Merge = 0.4,
}
-- Pads whose label is wider or narrower than their size gives: the merge name a compact tag,
-- the deposit label the size of the small pads' so it fits in front of the converter's jar.
local LABEL_GROW: { [string]: number } = { Merge = 0.65, Deposit = 0.7 }
-- Pads whose label stands off the pad's centre, as plot-local (x, z) studs. The merge tag
-- stands at the pad's far left corner: floating over the far edge it covered the pen's crate
-- labels ("Common") and, hung lower there, the walking character's own head. At the corner it
-- is drawn over the pen's front wall, under every crate label and left of the character.
local LABEL_SHIFT: { [string]: Vector2 } = { Merge = Vector2.new(5.2, 3.5) }
-- Share of the stud width that scales with distance, and the fixed pixel part added to it.
local LABEL_SCALE = 0.8
local LABEL_PX = 32
-- A static (one-line) tag keeps the old compact shape: height share and fixed pixels.
local STATIC_H = 0.34
local STATIC_PX = 24
-- Label rows as shares of its height: name, effect, then the price filling the rest. With no
-- effect the name takes NAME_ALONE and the price the rest.
local NAME_H = 0.3
local EFFECT_H = 0.22
local NAME_ALONE = 0.4
-- Outline thickness (pixels) of the name, the effect and the price.
local NAME_STROKE = 3
local EFFECT_STROKE = 2.5
local PRICE_STROKE = 3.5
-- Transparency of the effect line while the price is out of reach.
local EFFECT_OFF = 0.45
-- Gold pass chip behind a price: its share of the price row's height, and its width as a share
-- of the label's: a fixed padding plus a part per character, so a short price gets a short chip.
local CHIP_H = 0.86
local CHIP_PAD = 0.14
local CHIP_CHAR = 0.09
local CHIP_MIN = 0.32
-- What Server.Tycoon and Server.WorldBuilder write (in any case) on a pad that needs a game pass.
local PASS_WORDS = "game pass"
-- Transparency of the name and effect (and their outlines) on a plot nobody owns.
local UNCLAIMED_DIM = 0.55

-- Pads that show a fixed label (their action) instead of a name and a price.
local STATIC: { [string]: boolean } = { Merge = true }

-- Which Theme.World.Pads colour each pad wears.
local JOB_KEYS: { [string]: string } = { Unlock1 = "Unlock", Unlock2 = "UnlockVip" }
local function jobKey(name: string): string
	if string.sub(name, 1, 3) == "Buy" then
		return "Buy"
	elseif string.sub(name, 1, 6) == "ProcUp" then
		return "Process"
	end
	return JOB_KEYS[name] or name
end

-- The big printed mark on each pad's top.
local function iconText(name: string): string
	local icons = theme.Icons
	if string.sub(name, 1, 3) == "Buy" then
		return "+" .. string.sub(name, 4)
	end
	local fixed = {
		AutoMerge = "AUTO",
		Merge = icons.Unit .. "+" .. icons.Unit,
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

-- Each pad's job colour, print colour and top icon, so setEnabled can repaint them, and
-- whether its plot has an owner with the label's redraw, so setClaimed can dim its name.
type Painted = { color: Color3, print: Color3, icon: TextLabel, claimed: boolean, redraw: () -> () }
local painted: { [BasePart]: Painted } = setmetatable({}, { __mode = "k" }) :: any

local function corner(parent: Instance, scale: number)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(scale, 0)
	c.Parent = parent
end

local function outline(parent: Instance, color: Color3, thickness: number, transparency: number?): UIStroke
	local s = Instance.new("UIStroke")
	s.Color = color
	s.Thickness = thickness
	s.Transparency = transparency or 0
	s.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
	s.Parent = parent
	return s
end

local function sameColor(a: Color3, b: Color3): boolean
	return math.abs(a.R - b.R) + math.abs(a.G - b.G) + math.abs(a.B - b.B) < 0.01
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

-- The printed mark on the pad top, drawn on `face`: a big unstroked icon in `printColor` inside
-- a thin rim-coloured border, or on a weight plate (`ringColor` given) inside a raised ring in
-- that colour with four dark grip slots just inside it. Returns the icon.
local function buildTopPrint(padPart: BasePart, face: Enum.NormalId, name: string, printColor: Color3, ringColor: Color3?): TextLabel
	local round = ringColor ~= nil
	local gui = Instance.new("SurfaceGui")
	gui.Name = "PadPrint"
	gui.Face = face
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 40
	gui.LightInfluence = 1
	gui.Parent = padPart
	local ringSize = if round then PLATE_RING else 0.86
	local border = Instance.new("Frame")
	border.Name = "Border"
	border.AnchorPoint = Vector2.new(0.5, 0.5)
	border.Position = UDim2.fromScale(0.5, 0.5)
	border.Size = UDim2.fromScale(ringSize, ringSize)
	border.BackgroundTransparency = 1
	border.Parent = gui
	corner(border, if round then 0.5 else 0.18)
	local ring = Instance.new("UIStroke")
	ring.Color = ringColor or RIM
	ring.Thickness = if round then PLATE_RING_PX else 4
	ring.Transparency = 0
	ring.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	ring.Parent = border
	if round then
		for _, dir in { Vector2.new(0, -1), Vector2.new(1, 0), Vector2.new(0, 1), Vector2.new(-1, 0) } do
			local slot = Instance.new("Frame")
			slot.Name = "Grip"
			slot.AnchorPoint = Vector2.new(0.5, 0.5)
			slot.Position = UDim2.fromScale(0.5 + dir.X * GRIP_REACH, 0.5 + dir.Y * GRIP_REACH)
			slot.Size = if dir.X == 0 then UDim2.fromScale(GRIP_LONG, GRIP_SHORT) else UDim2.fromScale(GRIP_SHORT, GRIP_LONG)
			slot.BackgroundColor3 = RUBBER
			slot.BorderSizePixel = 0
			slot.Parent = gui
			corner(slot, 0.5)
		end
	end
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

-- The floating label's parts (see buildLabel).
type Label = {
	gui: BillboardGui,
	title: TextLabel,
	titleStroke: UIStroke,
	effect: TextLabel,
	effectStroke: UIStroke,
	row: Frame,
	chip: Frame,
	price: TextLabel,
	priceStroke: UIStroke,
}

-- The floating label above a pad: a BillboardGui `offset` (world space) from the pad top,
-- `width` studs wide and `height` studs tall, plus `px` fixed pixels (scaled to its shape) so
-- it shrinks less than the world with distance and does not fill the screen when the camera is
-- beside the pad. Three rows, all with a thick Ink outline: the white name, the cyan effect and
-- the price row (the price over its gold pass chip). layoutRows places them.
local function buildLabel(padPart: BasePart, offset: Vector3, width: number, height: number, px: number): Label
	local white = World.White or Color3.new(1, 1, 1)
	local gui = Instance.new("BillboardGui")
	gui.Name = "PadLabel"
	gui.Adornee = padPart
	gui.Size = UDim2.new(width * LABEL_SCALE, px, height * LABEL_SCALE, px * height / width)
	gui.StudsOffsetWorldSpace = offset + Vector3.new(0, height / 2, 0)
	gui.MaxDistance = LABEL_MAX_DISTANCE
	gui.LightInfluence = 0
	gui.Parent = padPart
	local title = text(gui, {
		Name = "Title",
		Text = "",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.fromScale(0.5, 0),
		Size = UDim2.fromScale(1, NAME_H),
		TextColor3 = white,
	})
	local titleStroke = outline(title, World.Ink, NAME_STROKE)
	local effect = text(gui, {
		Name = "Effect",
		Text = "",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.fromScale(0.5, NAME_H),
		Size = UDim2.fromScale(1, EFFECT_H),
		TextColor3 = World.PadEffect or white,
	})
	local effectStroke = outline(effect, World.Ink, EFFECT_STROKE)
	local row = Instance.new("Frame")
	row.Name = "Main"
	row.AnchorPoint = Vector2.new(0.5, 1)
	row.Position = UDim2.fromScale(0.5, 1)
	row.Size = UDim2.fromScale(1, 1 - NAME_H - EFFECT_H)
	row.BackgroundTransparency = 1
	row.Parent = gui
	local chip = Instance.new("Frame")
	chip.Name = "Chip"
	chip.AnchorPoint = Vector2.new(0.5, 0.5)
	chip.Position = UDim2.fromScale(0.5, 0.5)
	chip.Size = UDim2.fromScale(CHIP_MIN, CHIP_H)
	chip.BackgroundColor3 = (World.PadPlate and World.PadPlate.Pass) or World.Sunny or white
	chip.BorderSizePixel = 0
	chip.Visible = false
	chip.Parent = row
	corner(chip, 0.35)
	outline(chip, World.Ink, 1.5)
	local price = text(row, {
		Name = "Price",
		Text = "",
		Font = theme.Fonts.Number,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(1, 1),
		TextColor3 = World.PadPrice or white,
		ZIndex = 2,
	})
	local priceStroke = outline(price, World.Ink, PRICE_STROKE)
	return {
		gui = gui,
		title = title,
		titleStroke = titleStroke,
		effect = effect,
		effectStroke = effectStroke,
		row = row,
		chip = chip,
		price = price,
		priceStroke = priceStroke,
	}
end

-- Shows what Server.Tycoon writes into the hidden `effect` and `sub` labels: the effect line
-- (the label closes up to name + price without one), and `sub`'s text as the price, coloured by
-- its tint: yellow when Good (affordable / ready), grey when Bad (with the effect dimmed),
-- white otherwise. A pad that asks for a game pass (PASS_WORDS in the text) shows it as Ink
-- print on the gold chip whatever the tint: grey reads as broken there. Returns the redraw
-- (Tycoon calls it through the Pad record after each write), which also dims the name and
-- effect while `entry` says nobody owns the plot.
local function bindLabel(label: Label, effect: TextLabel, sub: TextLabel, entry: Painted): () -> ()
	local white = World.White or Color3.new(1, 1, 1)
	local yellow = label.price.TextColor3
	local function redraw()
		local shown = sub.Text
		local tint = sub.TextColor3
		local pass = string.find(string.lower(shown), PASS_WORDS, 1, true) ~= nil
		local off = not pass and sameColor(tint, theme.Colors.Bad)
		local hasEffect = effect.Text ~= ""
		local nameH = if hasEffect then NAME_H else NAME_ALONE
		label.title.Size = UDim2.fromScale(1, nameH)
		label.effect.Text = effect.Text
		label.effect.Visible = hasEffect
		label.row.Size = UDim2.fromScale(1, 1 - nameH - (if hasEffect then EFFECT_H else 0))

		label.price.Text = shown
		label.chip.Visible = pass
		label.priceStroke.Transparency = if pass then 1 else 0
		if pass then
			local chipW = math.clamp(CHIP_PAD + CHIP_CHAR * (utf8.len(shown) or #shown), CHIP_MIN, 1)
			label.chip.Size = UDim2.fromScale(chipW, CHIP_H)
			label.price.Size = UDim2.fromScale(chipW * 0.88, CHIP_H * 0.8)
			label.price.TextColor3 = World.Ink
		else
			label.price.Size = UDim2.fromScale(1, 1)
			label.price.TextColor3 = if off then World.PadPriceOff or white elseif sameColor(tint, theme.Colors.Good) then yellow else white
		end

		local dim = if entry.claimed then 0 else UNCLAIMED_DIM
		label.title.TextTransparency = dim
		label.titleStroke.Transparency = dim
		local effectDim = math.max(dim, if off then EFFECT_OFF else 0)
		label.effect.TextTransparency = effectDim
		label.effectStroke.Transparency = effectDim
	end
	redraw()
	return redraw
end

local function buildPad(B: Builder, name: string, color: Color3, title: string, sub: string, effect: string?): Pad
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
	local padPart: BasePart
	local icon: TextLabel
	if spot.round then
		-- Weight plate: the rubber stands PLATE_LIP taller, the disc a hair proud of it.
		local plateH = base + PLATE_LIP
		P({
			Name = "PadBase",
			Shape = Enum.PartType.Cylinder,
			Size = Vector3.new(plateH, sx + 2 * r, sx + 2 * r),
			CFrame = L(x, plateH / 2, z) * UPRIGHT,
			Color = RUBBER,
		})
		-- The cylinder's top cap is its Right face, whose GUI "up" is the part's +Y; the yaw turns
		-- that toward the far edge.
		local topY = plateH + TOP_RISE
		padPart = P({
			Name = "Pad_" .. name,
			Shape = Enum.PartType.Cylinder,
			Size = Vector3.new(TOP_THICK, sx, sz),
			CFrame = L(x, topY - TOP_THICK / 2, z) * CFrame.Angles(0, math.atan2(far.Y, -far.X), 0) * UPRIGHT,
			Color = color,
		})
		icon = buildTopPrint(padPart, Enum.NormalId.Right, name, printColor, color:Lerp(World.Ink, PLATE_RING_DARK))
	else
		buildRim(B, x, z, sx, sz, base)
		-- A Top-face GUI reads upright toward the part's -Z, so the top is turned to point -Z at
		-- the far edge (swapping its size when that is sideways).
		local topY = base + TOP_RISE
		local sideways = far.X ~= 0
		padPart = P({
			Name = "Pad_" .. name,
			Size = if sideways then Vector3.new(sz, TOP_THICK, sx) else Vector3.new(sx, TOP_THICK, sz),
			CFrame = L(x, topY - TOP_THICK / 2, z) * CFrame.Angles(0, math.atan2(-far.X, -far.Y), 0),
			Color = color,
		})
		icon = buildTopPrint(padPart, Enum.NormalId.Top, name, printColor)
	end

	local static = STATIC[name] == true
	local width = math.clamp(math.max(sx, sz) * LABEL_W_PER, LABEL_W, LABEL_W_MAX) * (LABEL_GROW[name] or 1)
	local offset = Vector3.new(0, LABEL_LIFTS[name] or LABEL_LIFT, 0)
	local shift = LABEL_SHIFT[name]
	if shift then
		offset += B.cf:VectorToWorldSpace(Vector3.new(shift.X, 0, shift.Y))
	end
	local label = if static
		then buildLabel(padPart, offset, width, width * STATIC_H, STATIC_PX)
		else buildLabel(padPart, offset, width, width * LABEL_H, LABEL_PX)
	local entry: Painted = { color = color, print = printColor, icon = icon, claimed = true, redraw = function() end }
	painted[padPart] = entry
	-- Server.Tycoon writes the pad's name into `title`, what it does into `effect` and the
	-- price / status into `sub` (and tints it), then calls `redraw`; `effect` and `sub` stay
	-- hidden and the label's rows show them (bindLabel). Pads it never prices (Merge) show their action as one big
	-- sunny line; the labels it may clear stay hidden so the label keeps its fixed text.
	local titleLabel = label.title
	local subLabel = text(label.title, { Name = "Sub", Text = sub, Visible = false })
	local effectLabel = text(label.title, { Name = "EffectText", Text = effect or "", Visible = false })
	if static then
		label.title.Size = UDim2.fromScale(1, 1)
		label.title.Text = string.upper(title)
		label.title.TextColor3 = World.Sunny or color
		label.effect.Visible = false
		label.row.Visible = false
		titleLabel = text(label.title, { Name = "Title", Text = title, Visible = false })
		entry.redraw = function()
			local dim = if entry.claimed then 0 else UNCLAIMED_DIM
			label.title.TextTransparency = dim
			label.titleStroke.Transparency = dim
		end
	else
		titleLabel.Text = title
		entry.redraw = bindLabel(label, effectLabel, subLabel, entry)
	end

	return {
		name = name,
		center = Vector3.new(x, 0, z),
		half = Vector2.new(sx / 2 + TRIGGER_GROW, sz / 2 + TRIGGER_GROW),
		part = padPart,
		title = titleLabel,
		sub = subLabel,
		effect = effectLabel,
		redraw = function()
			entry.redraw()
		end,
		defaultTitle = titleLabel.Text,
		defaultEffect = effectLabel.Text,
		defaultSub = sub,
		defaultTint = subLabel.TextColor3,
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

-- Dims a pad's name and effect on a plot nobody owns, or shows them in full once the plot has
-- an owner.
local function setClaimed(pad: Pad, claimed: boolean)
	local entry = painted[pad.part]
	if not entry then
		return
	end
	entry.claimed = claimed
	entry.redraw()
end

Pads.buildPad = buildPad
Pads.setEnabled = setEnabled
Pads.setClaimed = setClaimed

return Pads
