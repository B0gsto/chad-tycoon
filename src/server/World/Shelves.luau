--[[
	Shelves: the Chads' display rack on the back ledge, one model per unit (Layout.SHELF,
	Layout.shelfSlots). Up to ten shelves stack upward, each a little behind the one below:
	a cream board with a round white rim and a front band alternating sunny and butter, a pale
	sky back panel (World.RackBack) every Chad reads against as a clear silhouette, skinned on
	its rear with teal so the unit seen from behind is a tidy stepped teal panel trimmed by the
	cream board edges, chunky teal side posts with white knobs at every step and a little
	numbered cream tag on the left post. The rim and band are the shelf lip
	the client's name plates hang from (Fx.Plates), so nothing else is built there. Slot 1, at
	the front shelf's centre, is a raised champion pedestal with gold rims and a gold star
	plaque whose ring and top disc follow the best unit's tier colour. A sunny roof board
	tops the highest shelf and holds the small "YOUR CHADS" marquee (cream card, red-orange
	header) on two posts, high enough to stay out of the pen view.
	Two soft warm lights (one wash over the lower shelves, one spot on the champion) keep the
	units the best-lit thing on the plot.

	Shelves appear as the owner's units need them (Shelves.setRows, called by Tycoon):
	  * Shelf 1 is always built into the plot folder.
	  * Shelves 2..10 are Models named "RackRow" with attribute Row = n. A shown shelf is
	    parented to the plot folder; a hidden one is parented to nil (kept here), so clients
	    see a revealed shelf arrive with ChildAdded and can animate it in.
	  * The roof + sign is the Model "RackTopper"; the server pivots it onto the highest shown
	    shelf.
	  * The plot folder's attribute "Rows" is the number of shelves shown (1 for an empty plot).
	Part of the world generator; see Server.WorldBuilder for the overview and plot axes.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Economy = require(ReplicatedStorage.Shared.Economy)
local Layout = require(script.Parent.Parent.PlotLayout)
local Common = require(script.Parent.Common)

type Builder = Common.Builder

local theme = Common.theme
local UPRIGHT = Common.UPRIGHT
local WHITE = Common.WHITE
local SHELF_LIGHT = Common.SHELF_LIGHT
local tierBandColor = Common.tierBandColor

local Shelves = {}

local function worldColor(key: string, fallback: Color3): Color3
	local palette = theme.World
	return if palette and palette[key] then palette[key] else fallback
end

local INK = worldColor("Ink", Color3.fromRGB(58, 48, 96))
local SIGN = Common.SIGN

-- Front band colours, alternating shelf by shelf from the bottom up.
local BAND_KEYS = { "Sunny", "Butter" }

-- Back panels stand this thick behind each shelf board: a pale face (BACK_FACE thick) in
-- front of a teal rear skin.
local BACK_THICK = 0.4
local BACK_FACE = 0.25
-- Diameter of the white knobs on the side posts.
local KNOB = 1.9

-- Purely decorative: never blocks the player or pulls the camera in.
local function decorative(p: BasePart): BasePart
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	return p
end

local function text(parent: Instance, props: { [string]: any }): TextLabel
	local l = Instance.new("TextLabel")
	l.BackgroundTransparency = 1
	l.TextScaled = true
	l.Font = theme.Fonts.Display or theme.Fonts.Title
	l.TextColor3 = INK
	for key, value in props do
		(l :: any)[key] = value
	end
	l.Parent = parent
	return l
end

-- The thin teal border round a sign card.
local function border(frame: Frame)
	local stroke = Instance.new("UIStroke")
	stroke.Color = SIGN.Border
	stroke.Thickness = 4
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Parent = frame
end

-- A SurfaceGui on the part's front (-Z) face.
local function surface(p: BasePart): SurfaceGui
	local gui = Instance.new("SurfaceGui")
	gui.Face = Enum.NormalId.Front
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 30
	gui.LightInfluence = 0.3
	gui.Parent = p
	return gui
end

-- The raised "best unit" pedestal at slot 1: a gold-rimmed cream drum with a tier-coloured band
-- and top disc, a gold star plaque on its front and a soft warm spotlight. It stays within the
-- front shelf's depth so it never overhangs the gutter. Returns the parts that follow the best
-- tier's colour.
local function buildChampionPedestal(B: Builder, x: number, deckTop: number, z: number, standY: number): { Instance }
	local L, P = B.L, B.P
	local tinted: { Instance } = {}
	local start = B.c.Primary
	local gold = worldColor("Sunny", start)
	local footH, rimH = 0.25, 0.3
	local bodyR = 1.5
	P({
		Name = "ChampionFoot",
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(footH, 3.6, 3.6),
		CFrame = L(x, deckTop + footH / 2, z) * UPRIGHT,
		Color = gold,
	})
	local bodyBottom, bodyTop = deckTop + footH, standY - rimH
	P({
		Name = "ChampionPedestal",
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(bodyTop - bodyBottom, bodyR * 2, bodyR * 2),
		CFrame = L(x, (bodyBottom + bodyTop) / 2, z) * UPRIGHT,
		Color = worldColor("Cream", WHITE),
	})
	P({
		Name = "ChampionTop",
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(rimH, 3.4, 3.4),
		CFrame = L(x, standY - rimH / 2, z) * UPRIGHT,
		Color = gold,
	})
	local ring = decorative(P({
		Name = "ChampionRing",
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(0.22, bodyR * 2 + 0.16, bodyR * 2 + 0.16),
		CFrame = L(x, bodyBottom + 0.18, z) * UPRIGHT,
		Color = start,
	}))
	table.insert(tinted, ring)
	local disc = decorative(P({
		Name = "ChampionDisc",
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(0.06, 2.7, 2.7),
		CFrame = L(x, standY - 0.02, z) * UPRIGHT,
		Color = start,
	}))
	disc.CastShadow = false
	table.insert(tinted, disc)

	-- Gold star plaque on the drum's front (-Z) face.
	local plaqueW, plaqueH = 1.3, (bodyTop - bodyBottom) - 0.3
	local plaque = decorative(P({
		Name = "ChampionPlaque",
		Size = Vector3.new(plaqueW, plaqueH, 0.4),
		CFrame = L(x, (bodyBottom + bodyTop) / 2 + 0.08, z - bodyR + 0.06),
		Color = gold,
	}))
	text(surface(plaque), {
		Text = "★",
		Size = UDim2.fromScale(1, 1),
		TextColor3 = WHITE,
		Font = Enum.Font.GothamBlack,
	})

	-- Soft warm spot in front of and above the pedestal, aimed down and back at it.
	local rig = decorative(P({
		Name = "ChampionSpot",
		Size = Vector3.new(1, 0.2, 1),
		CFrame = L(x, standY + 12, z - 6) * CFrame.Angles(math.rad(-26), 0, 0),
		Transparency = 1,
	}))
	rig.CastShadow = false
	local spot = Instance.new("SpotLight")
	spot.Face = Enum.NormalId.Bottom
	spot.Angle = 38
	spot.Range = 20
	spot.Brightness = 1.4
	spot.Color = SHELF_LIGHT
	spot.Shadows = false
	spot.Parent = rig
	return tinted
end

-- Recolours the champion pedestal's ring and disc to the highest tier standing on the shelf.
local function watchChampion(unitFolder: Folder, tinted: { Instance })
	local current: Color3? = nil
	local function refresh()
		local best = 0
		for _, child in unitFolder:GetChildren() do
			local tier = child:GetAttribute("Tier")
			if type(tier) == "number" and tier > best then
				best = tier
			end
		end
		local color = if best > 0 then tierBandColor(best) else theme.Colors.Primary
		if current == color then
			return
		end
		current = color
		for _, inst in tinted do
			(inst :: any).Color = color
		end
	end
	refresh()
	-- pcall: the offline preview (Lune) has no instance signals.
	pcall(function()
		unitFolder.ChildAdded:Connect(function(child)
			refresh()
			child:GetAttributeChangedSignal("Tier"):Connect(refresh)
		end)
		unitFolder.ChildRemoved:Connect(refresh)
	end)
end

-- A dumbbell drawn in UI frames, filling `parent` (a square frame): a teal bar with a coral
-- and a sunny plate at each end.
local function dumbbellIcon(parent: GuiObject)
	local function piece(color: Color3, x: number, w: number, h: number)
		local f = Instance.new("Frame")
		f.AnchorPoint = Vector2.new(0.5, 0.5)
		f.Position = UDim2.fromScale(x, 0.5)
		f.Size = UDim2.fromScale(w, h)
		f.BackgroundColor3 = color
		f.BorderSizePixel = 0
		f.Parent = parent
		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0.35, 0)
		corner.Parent = f
	end
	piece(worldColor("Teal", WHITE), 0.5, 0.7, 0.1)
	for _, side in { -1, 1 } do
		piece(worldColor("Coral", WHITE), 0.5 + side * 0.24, 0.12, 0.52)
		piece(worldColor("Sunny", WHITE), 0.5 + side * 0.35, 0.09, 0.36)
	end
end

-- The gym emblem on the back of the rack sign, crowning the rack seen from behind the plot:
-- a cream card with a sunny border, a dumbbell between two coral stars and the gym's name.
local function signBack(board: BasePart)
	local gui = Instance.new("SurfaceGui")
	gui.Name = "RackEmblem"
	gui.Face = Enum.NormalId.Back
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 30
	gui.LightInfluence = 1
	gui.Parent = board
	local card = Instance.new("Frame")
	card.AnchorPoint = Vector2.new(0.5, 0.5)
	card.Position = UDim2.fromScale(0.5, 0.5)
	card.Size = UDim2.fromScale(0.96, 0.9)
	card.BackgroundColor3 = worldColor("Cream", WHITE)
	card.BorderSizePixel = 0
	card.Parent = gui
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0.25, 0)
	corner.Parent = card
	local stroke = Instance.new("UIStroke")
	stroke.Color = worldColor("Sunny", WHITE)
	stroke.Thickness = 8
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Parent = card
	local icon = Instance.new("Frame")
	icon.BackgroundTransparency = 1
	icon.AnchorPoint = Vector2.new(0.5, 0)
	icon.Position = UDim2.fromScale(0.5, 0.04)
	icon.Size = UDim2.fromScale(0.58, 0.58)
	icon.SizeConstraint = Enum.SizeConstraint.RelativeYY
	icon.Parent = card
	dumbbellIcon(icon)
	for _, x in { 0.3, 0.7 } do
		text(card, {
			Text = "★",
			AnchorPoint = Vector2.new(0.5, 0),
			Position = UDim2.fromScale(x, 0.08),
			Size = UDim2.fromScale(0.5, 0.5),
			SizeConstraint = Enum.SizeConstraint.RelativeYY,
			TextColor3 = worldColor("Coral", WHITE),
		})
	end
	text(card, {
		Text = string.upper(theme.Words.Unit) .. " GYM",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.fromScale(0.5, 0.62),
		Size = UDim2.fromScale(0.8, 0.32),
		TextColor3 = INK,
	})
end

-- The rack sign in the shared sign style (Common.SIGN): a cream card with a teal border and a
-- red-orange header band, framed by a teal board on two teal posts, standing on the roof at
-- plot-local (0, base, z). It is a small marquee held SIGN_CLEAR above the roof: from the pen
-- (default camera, 15 studs behind the character and looking 20 degrees down) a sign sitting
-- on the roof filled the top-centre of the screen, right behind the HUD's rows; this high it is
-- past the top edge there, and from the walkway it is a small plate above the rack.
local SIGN_W, SIGN_H = 16, 3.4
local SIGN_CLEAR = 6.4
local function buildSign(B: Builder, parent: Instance, z: number, base: number)
	local L, P = B.L, B.P
	local w, h = SIGN_W, SIGN_H
	local cy = base + SIGN_CLEAR + (h + 0.5) / 2
	for _, side in { -1, 1 } do
		decorative(P({
			Name = "SignPost",
			Shape = Enum.PartType.Cylinder,
			Size = Vector3.new(cy - base, 0.8, 0.8),
			CFrame = L(side * (w / 2 - 1.5), (base + cy) / 2, z + 0.5) * UPRIGHT,
			Color = SIGN.Border,
			Parent = parent,
		}))
	end
	-- Rounded teal frame: a slab with round ends.
	local board = decorative(P({
		Name = "Board",
		Size = Vector3.new(w - h, h + 0.5, 0.4),
		CFrame = L(0, cy, z + 0.2),
		Color = SIGN.Border,
		Parent = parent,
	}))
	signBack(board)
	for _, side in { -1, 1 } do
		decorative(P({
			Name = "Board",
			Shape = Enum.PartType.Cylinder,
			Size = Vector3.new(0.4, h + 0.5, h + 0.5),
			CFrame = L(side * (w - h) / 2, cy, z + 0.2) * CFrame.Angles(0, math.pi / 2, 0),
			Color = SIGN.Border,
			Parent = parent,
		}))
	end
	local card = decorative(P({
		Name = "Screen",
		Size = Vector3.new(w - 0.6, h - 0.3, 0.2),
		CFrame = L(0, cy, z),
		Color = SIGN.Card,
		Parent = parent,
	}))
	local gui = surface(card)
	gui.MaxDistance = Common.SIGN_FADE_CARD
	local frame = Instance.new("Frame")
	frame.Size = UDim2.fromScale(1, 1)
	frame.BackgroundColor3 = SIGN.Card
	frame.BorderSizePixel = 0
	frame.Parent = gui
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0.2, 0)
	corner.Parent = frame
	border(frame)
	local band = Instance.new("Frame")
	band.Size = UDim2.fromScale(1, 0.58)
	band.BackgroundColor3 = SIGN.Header
	band.BorderSizePixel = 0
	band.Parent = frame
	local bandCorner = Instance.new("UICorner")
	bandCorner.CornerRadius = UDim.new(0.3, 0)
	bandCorner.Parent = band
	text(band, {
		Text = "YOUR " .. string.upper(theme.Words.Units) .. "  ★",
		Size = UDim2.fromScale(0.9, 0.78),
		Position = UDim2.fromScale(0.05, 0.12),
		TextColor3 = SIGN.Title,
	})
	text(frame, {
		Text = "Every " .. theme.Words.Unit .. " drops " .. theme.Words.Orb .. " into the pen",
		Font = theme.Fonts.UI or theme.Fonts.Bold or theme.Fonts.Body,
		Size = UDim2.fromScale(0.86, 0.3),
		Position = UDim2.fromScale(0.07, 0.64),
		TextColor3 = SIGN.Text,
	})
end

-- The shelf's number on a small round cream card with a teal border on the front of the +X
-- (left) post.
local function rowTag(B: Builder, parent: Instance, row: number, y: number, z: number)
	local s = Layout.SHELF
	local tag = decorative(B.P({
		Name = "RackTag",
		Size = Vector3.new(1.3, 1.3, 0.1),
		CFrame = B.L(s.width / 2 + s.postWidth / 2, y, z - 0.06),
		Transparency = 1,
		Parent = parent,
	}))
	tag.CastShadow = false
	local gui = surface(tag)
	gui.MaxDistance = Common.SIGN_FADE_TAG
	local card = Instance.new("Frame")
	card.Size = UDim2.fromScale(1, 1)
	card.BackgroundColor3 = SIGN.Card
	card.BorderSizePixel = 0
	card.Parent = gui
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0.5, 0)
	corner.Parent = card
	border(card)
	text(card, {
		Text = tostring(row),
		Size = UDim2.fromScale(0.7, 0.7),
		Position = UDim2.fromScale(0.15, 0.15),
		TextColor3 = SIGN.Text,
	})
end

-- Paint on a shelf's teal rear skin (seen from behind the plot): two cream trim bands across
-- the panel, a cream medallion in the middle (a dumbbell on odd shelves, a coral star on even
-- ones) and two small cream stars on the bands, so the stepped back of the rack reads as a
-- friendly gym banner rather than a blank slab. Drawn in a SurfaceGui: no extra parts.
local function rearArt(rear: BasePart, row: number)
	local cream = worldColor("Cream", WHITE)
	local gui = Instance.new("SurfaceGui")
	gui.Name = "RackRearArt"
	gui.Face = Enum.NormalId.Back
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 16
	-- Lit like the paint around it, never glowing.
	gui.LightInfluence = 1
	gui.Parent = rear
	for _, y in { 0.16, 0.84 } do
		local band = Instance.new("Frame")
		band.Name = "Trim"
		band.AnchorPoint = Vector2.new(0.5, 0.5)
		band.Position = UDim2.fromScale(0.5, y)
		band.Size = UDim2.fromScale(0.96, 0.07)
		band.BackgroundColor3 = cream
		band.BorderSizePixel = 0
		band.Parent = gui
		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0.5, 0)
		corner.Parent = band
	end
	for _, x in { 0.25, 0.75 } do
		text(gui, {
			Text = "★",
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(x, 0.5),
			Size = UDim2.fromScale(0.5, 0.5),
			SizeConstraint = Enum.SizeConstraint.RelativeYY,
			TextColor3 = cream,
		})
	end
	local medal = Instance.new("Frame")
	medal.Name = "Emblem"
	medal.AnchorPoint = Vector2.new(0.5, 0.5)
	medal.Position = UDim2.fromScale(0.5, 0.5)
	medal.Size = UDim2.fromScale(0.86, 0.86)
	medal.SizeConstraint = Enum.SizeConstraint.RelativeYY
	medal.BackgroundColor3 = cream
	medal.BorderSizePixel = 0
	medal.Parent = gui
	local round = Instance.new("UICorner")
	round.CornerRadius = UDim.new(0.5, 0)
	round.Parent = medal
	local ring = Instance.new("UIStroke")
	ring.Color = worldColor("Sunny", WHITE)
	ring.Thickness = 6
	ring.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	ring.Parent = medal
	if row % 2 == 1 then
		dumbbellIcon(medal)
	else
		text(medal, {
			Text = "★",
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.52),
			Size = UDim2.fromScale(0.78, 0.78),
			TextColor3 = worldColor("Coral", WHITE),
		})
	end
end

-- One shelf of the rack: board, rim, front band, back panel (pale face, teal rear skin), the
-- two post segments that carry it (up to the next shelf's board) and its number tag; shelves
-- above the first also get the post knobs where the posts step back. Shelf 1's board and
-- posts are solid (the ledge); everything above is decorative so players never climb the rack.
local function buildRow(B: Builder, parent: Instance, row: number)
	local L, P = B.L, B.P
	local s = Layout.SHELF
	local top = Layout.rowTop(row)
	local nextBottom = Layout.rowTop(row + 1) - s.boardThick
	local front = Layout.rowFrontZ(row)
	local back = front + s.depth
	local solid = row == 1
	local function part(props: { [string]: any }): BasePart
		props.Parent = parent
		local p = P(props)
		return if solid then p else decorative(p)
	end

	part({
		Name = "ShelfBoard",
		Size = Vector3.new(s.width, s.boardThick, s.depth),
		CFrame = L(0, top - s.boardThick / 2, front + s.depth / 2),
		Color = worldColor("Cream", WHITE),
	})
	decorative(P({
		Name = "ShelfBand",
		Size = Vector3.new(s.width, s.boardThick + 0.04, 0.16),
		CFrame = L(0, top - s.boardThick / 2, front - 0.08),
		Color = worldColor(BAND_KEYS[(row - 1) % #BAND_KEYS + 1], B.c.Primary),
		Parent = parent,
	}))
	decorative(P({
		Name = "ShelfRim",
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(s.width, 0.36, 0.36),
		CFrame = L(0, top - 0.06, front - s.frontReach + 0.18),
		Color = WHITE,
		Parent = parent,
	})).CastShadow =
		false
	-- Matte, so the sun and the display wash never put a white hot spot behind the units.
	part({
		Name = "ShelfBack",
		Size = Vector3.new(s.width, nextBottom - top, BACK_FACE),
		CFrame = L(0, (top + nextBottom) / 2, back + BACK_FACE / 2),
		Color = worldColor("RackBack", WHITE),
		Material = Enum.Material.SmoothPlastic,
		Reflectance = 0,
	})
	local rearThick = BACK_THICK - BACK_FACE
	local rear = part({
		Name = "ShelfBackRear",
		Size = Vector3.new(s.width, nextBottom - top, rearThick),
		CFrame = L(0, (top + nextBottom) / 2, back + BACK_FACE + rearThick / 2),
		Color = worldColor("Teal", B.c.WallTrim),
	})
	rearArt(rear, row)

	local postBottom = if row == 1 then 0 else top - s.boardThick
	local postDepth = s.depth + BACK_THICK
	for _, side in { -1, 1 } do
		local x = side * (s.width / 2 + s.postWidth / 2)
		part({
			Name = "RackPost",
			Size = Vector3.new(s.postWidth, nextBottom - postBottom, postDepth),
			CFrame = L(x, (postBottom + nextBottom) / 2, front + postDepth / 2),
			Color = worldColor("Teal", B.c.WallTrim),
		})
		if row > 1 then
			-- A knob on the step where this post segment sits back from the one below.
			decorative(P({
				Name = "RackKnob",
				Shape = Enum.PartType.Ball,
				Size = Vector3.new(KNOB, KNOB, KNOB),
				CFrame = L(x, postBottom, front - s.stepBack / 2),
				Color = WHITE,
				Parent = parent,
			}))
		end
	end
	rowTag(B, parent, row, (top + nextBottom) / 2, front)
end

-- The sunny roof board over the top shelf with its sign, built over shelf 1 (setRows
-- moves it up). Returns the model; its PrimaryPart is the roof board.
local function buildTopper(B: Builder): Model
	local L, P = B.L, B.P
	local s = Layout.SHELF
	local model = Instance.new("Model")
	model.Name = "RackTopper"
	local roofTop = Layout.rowTop(2)
	local front = Layout.rowFrontZ(1)
	local roofW = s.width + s.postWidth * 2 + 0.6
	local roofD = s.depth + BACK_THICK + 0.6
	local roof = decorative(P({
		Name = "RackRoof",
		Size = Vector3.new(roofW, s.boardThick, roofD),
		CFrame = L(0, roofTop - s.boardThick / 2, front - 0.3 + roofD / 2),
		Color = worldColor("Sunny", B.c.Primary),
		Parent = model,
	}))
	decorative(P({
		Name = "RackRoofBand",
		Size = Vector3.new(roofW, s.boardThick + 0.04, 0.16),
		CFrame = L(0, roofTop - s.boardThick / 2, front - 0.38),
		Color = worldColor("Sunny", B.c.Primary),
		Parent = model,
	}))
	local knobY = roofTop + KNOB / 2 - 0.2
	local knobX = s.width / 2 + s.postWidth / 2
	for _, side in { -1, 1 } do
		decorative(P({
			Name = "RackKnob",
			Shape = Enum.PartType.Ball,
			Size = Vector3.new(KNOB, KNOB, KNOB),
			CFrame = L(side * knobX, knobY, front + 0.6),
			Color = WHITE,
			Parent = model,
		}))
	end
	local signZ = front + s.depth - 1
	buildSign(B, model, signZ, roofTop)
	model.PrimaryPart = roof
	return model
end

type Rack = {
	folder: Instance,
	rows: { Model },
	topper: Model,
	topperBase: CFrame,
	cframe: CFrame,
	shown: number,
}

-- Racks by plot folder (plots live for the whole server, so this never needs cleaning).
local racks: { [Instance]: Rack } = {}

-- Shows shelves 1..rows of the rack in `folder` (a plot folder) and moves the roof onto the
-- highest one; see the header for the contract. Safe to call every refresh.
local function setRows(folder: Instance, rows: number)
	local rack = racks[folder]
	if not rack then
		return
	end
	local shown = math.clamp(math.floor(rows), 1, Layout.SHELF.rows)
	if rack.shown == shown then
		return
	end
	rack.shown = shown
	for _, model in rack.rows do
		local row = model:GetAttribute("Row") :: number
		local parent: Instance? = if row <= shown then folder else nil
		if model.Parent ~= parent then
			model.Parent = parent
		end
	end
	local lift = Layout.rowTop(shown + 1) - Layout.rowTop(2)
	local back = Layout.rowFrontZ(shown) - Layout.rowFrontZ(1)
	rack.topper:PivotTo(rack.topperBase + rack.cframe:VectorToWorldSpace(Vector3.new(0, lift, back)))
	folder:SetAttribute("Rows", shown)
end

-- Builds the rack (see the header). Returns the slots in fill order (bottom shelf first,
-- centre-out) so the best units are the most visible, plus the champion pedestal's tinted
-- parts. Only shelf 1 is shown until Shelves.setRows asks for more.
local function buildShelves(B: Builder): ({ CFrame }, { Instance })
	local L, P = B.L, B.P
	local s = Layout.SHELF

	-- Solid plinth under the front shelf (the ledge face behind the gutter).
	P({
		Name = "Shelf",
		Size = Vector3.new(s.width, Layout.rowTop(1) - s.boardThick, s.depth + BACK_THICK),
		CFrame = L(0, (Layout.rowTop(1) - s.boardThick) / 2, Layout.rowFrontZ(1) + (s.depth + BACK_THICK) / 2),
		Color = worldColor("Teal", B.c.WallTrim),
	})
	buildRow(B, B.folder, 1)
	local rowModels: { Model } = {}
	for row = 2, s.rows do
		local model = Instance.new("Model")
		model.Name = "RackRow"
		model:SetAttribute("Row", row)
		buildRow(B, model, row)
		model.Parent = B.folder
		table.insert(rowModels, model)
	end

	-- Slots, in fill order (slot 1 = front-centre champion pedestal).
	local slots: { CFrame } = {}
	local champion: { Instance } = {}
	for _, slot in Layout.shelfSlots() do
		if slot.best then
			champion = buildChampionPedestal(B, slot.x, Layout.rowTop(1), slot.z, slot.y)
		end
		table.insert(slots, L(slot.x, slot.y, slot.z))
	end
	assert(#slots == Economy.DISPLAY_SLOTS, "display slot count mismatch")

	-- Display lighting: one soft warm wash from an invisible bar above and in front of the
	-- rack, angled down and back over the lower shelves.
	local bar = decorative(P({
		Name = "ShelfLightBar",
		Size = Vector3.new(s.width - 8, 0.3, 1),
		CFrame = L(0, Layout.rowTop(2) + 6, s.frontZ - 9) * CFrame.Angles(math.rad(-38), 0, 0),
		Transparency = 1,
	}))
	bar.CastShadow = false
	local light = Instance.new("SurfaceLight")
	light.Face = Enum.NormalId.Bottom
	light.Angle = 85
	light.Range = 28
	light.Brightness = 1.6
	light.Color = SHELF_LIGHT
	light.Shadows = false
	light.Parent = bar

	local topper = buildTopper(B)
	topper.Parent = B.folder
	racks[B.folder] = {
		folder = B.folder,
		rows = rowModels,
		topper = topper,
		topperBase = topper:GetPivot(),
		cframe = B.cf,
		shown = s.rows,
	}
	setRows(B.folder, 1)

	return slots, champion
end

Shelves.watchChampion = watchChampion
Shelves.buildShelves = buildShelves
Shelves.setRows = setRows

return Shelves
