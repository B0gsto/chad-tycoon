--!strict
--[[
	Fx.Plates: a name plate for every unit on every rack, glowing more the higher its tier.

	- Where: each plate hangs from the top front edge of the shelf lip under its unit's feet
	  (the server tags display models with "Slot" and "PlateAt", see Tycoon.markSlot), on a
	  client-only, invisible, non-colliding part with a SurfaceGui facing the pen. It shows
	  the tier's name (Theme.Tiers[tier].Name, shrunk to fit) over a "Tier N" line.
	- Look: Fx.PlateStyle (one table per rarity band plus a small in-band ramp): cream sign
	  plates with Ink text and a rarity-coloured edge for the low bands, Ink plates with
	  bright rarity text from Epic, a soft halo from Uncommon, a pulse and a shimmer sweep
	  from Epic, gold / rainbow gradient text, sparkles and a small light pool for the top
	  band and the champion (slot 1).
	- Distance: within FULL_IN studs of the camera a plate is the full card; beyond FULL_OUT
	  it collapses to a small rarity-coloured gem on the shelf lip (a soft halo for the top
	  bands); past FAR studs the SurfaceGui stops drawing. The champion is always the full card.
	- Motion: a plate pops in once its unit has landed (Fx.Shelf holds arriving units in
	  Animator until they settle), flips to the new name when the unit in its slot changes,
	  shrinks into its gem / grows back out of it with distance and shrinks away when the
	  slot empties (a hidden shelf takes its units with it).
	- Cost: plates are pooled per slot and rebuilt only when the slot's tier changes. A scan
	  every SCAN seconds picks full card or gem per plate (a tween only when that changes),
	  starts the looping glow tweens (TweenService, nothing per frame in Lua) only for full
	  animated plates on the own rack in view, and keeps a few lights on the own rack.
	  Neighbours' plates are built only when the camera comes within NEAR_RACK studs.
	  On "mid" / "low" devices (Fx.Budget) fewer plates animate and carry lights
	  (Budget.count), and on low neighbours' plates wait until 100 studs.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Economy = require(Shared:WaitForChild("Economy"))
local Theme = require(ReplicatedStorage:WaitForChild("Theme"))

local Client = script.Parent.Parent
local Animator = require(Client.Animator)
local Budget = require(script.Parent.Budget)
local State = require(Client.State)
local PlateStyle = require(script.Parent.PlateStyle)

local Plates = {}

local PLATE_W = 3.5 -- studs at scale 1
local PLATE_H = 0.8
local PAD_X = 0.25 -- halo room around the plate
local PAD_Y = 0.14
local DROP = 0.04 -- gap under the lip's top edge
local OUT = 0.06 -- in front of the rim
local PPS = 64 -- SurfaceGui pixels per stud
local SCAN = 0.25
local FULL_IN = 38 -- a gem grows back into the full plate inside this camera distance...
local FULL_OUT = 42 -- ...and the full plate collapses to its gem beyond this one
local FAR = 120 -- SurfaceGui.MaxDistance
local GEM = 0.42 -- gem diameter in studs at scale 1
local GEM_HALO = 1.9 -- halo diameter / gem diameter (top bands)
local EDGE = 3 -- plate edge pixels per PlateStyle stroke unit
local NEAR_RACK = 150 -- neighbours' plates are built once the camera is this close
local ANIM_MAX = 28 -- animated plates at once
local LIGHTS_MAX = 3 -- light pools on the own rack
local LAND_MIN = 0.35 -- earliest a new unit's plate appears
local LAND_MAX = 8 -- give up waiting for a landing after this long
local FRESH = 4 -- a unit spawned this recently (server time) is still arriving

local WHITE = Color3.new(1, 1, 1)
local INK = (Theme.World and Theme.World.Ink) or Color3.fromRGB(52, 58, 84)
local NAME_FONT = Theme.Fonts.Display
local TIER_FONT = Theme.Fonts.UI

type Plate = {
	part: Part,
	gui: SurfaceGui,
	root: Frame,
	pop: UIScale,
	plate: Frame,
	stroke: UIStroke,
	halos: { Frame },
	name: TextLabel,
	nameStroke: UIStroke,
	nameGradient: UIGradient,
	tierText: TextLabel,
	gemRoot: Frame,
	gemScale: UIScale,
	gem: Frame,
	gemHalo: Frame,
	shimmer: Frame,
	sparkles: { Frame },
	light: PointLight?,
	tweens: { Tween },
	style: PlateStyle.Style?,
	tier: number,
	slot: number,
	shown: boolean,
	mode: string, -- "full" | "gem"
	animating: boolean,
	lit: boolean,
	token: number,
	at: CFrame,
}

type Rack = {
	plot: Instance,
	units: Instance,
	own: boolean,
	near: boolean,
	plates: { [number]: Plate },
	owners: { [number]: Model }, -- slot -> model standing there
	slotOf: { [Model]: number },
	waiting: { [Model]: number }, -- model -> os.clock() it appeared (not landed yet)
	conns: { RBXScriptConnection },
	modelConns: { [Model]: RBXScriptConnection },
}

local racks: { [Instance]: Rack } = {}
local styles: { [number]: PlateStyle.Style } = {}
local championStyles: { [number]: PlateStyle.Style } = {}
local holder: Folder? = nil
local started = false

local function styleFor(tier: number, champion: boolean): PlateStyle.Style
	local cache = if champion then championStyles else styles
	local cached: PlateStyle.Style? = cache[tier]
	if cached then
		return cached
	end
	local style = PlateStyle.compute(tier, Economy.TIER_BANDS, champion)
	cache[tier] = style
	return style
end

local function tierName(tier: number): string
	local info = Theme.Tiers[tier]
	return if info and info.Name then info.Name else ("Tier " .. tier)
end

local function folder(): Folder
	if holder and holder.Parent then
		return holder
	end
	local f = Instance.new("Folder")
	f.Name = "NamePlates"
	f.Parent = Workspace
	holder = f
	return f
end

local function corner(parent: Instance, radius: UDim)
	local c = Instance.new("UICorner")
	c.CornerRadius = radius
	c.Parent = parent
end

local function frame(parent: Instance, name: string, color: Color3, transparency: number): Frame
	local f = Instance.new("Frame")
	f.Name = name
	f.AnchorPoint = Vector2.new(0.5, 0.5)
	f.Position = UDim2.fromScale(0.5, 0.5)
	f.BackgroundColor3 = color
	f.BackgroundTransparency = transparency
	f.BorderSizePixel = 0
	f.Parent = parent
	return f
end

local function label(parent: Frame, name: string, font: Enum.Font, y: number, h: number, maxSize: number): TextLabel
	local t = Instance.new("TextLabel")
	t.Name = name
	t.AnchorPoint = Vector2.new(0.5, 0)
	t.Position = UDim2.fromScale(0.5, y)
	t.Size = UDim2.fromScale(0.9, h)
	t.BackgroundTransparency = 1
	t.Font = font
	t.TextScaled = true
	t.TextColor3 = WHITE
	t.Parent = parent
	local limit = Instance.new("UITextSizeConstraint")
	limit.MaxTextSize = maxSize
	limit.MinTextSize = 6
	limit.Parent = t
	return t
end

local function newPlate(slot: number): Plate
	local part = Instance.new("Part")
	part.Name = "NamePlate" .. slot
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Transparency = 1
	part.Size = Vector3.new(1, 1, 0.05)

	local gui = Instance.new("SurfaceGui")
	gui.Face = Enum.NormalId.Front
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = PPS
	gui.LightInfluence = 0
	gui.MaxDistance = FAR
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Enabled = false
	gui.Parent = part

	local root = frame(gui, "Root", WHITE, 1)
	root.Size = UDim2.fromScale(1, 1)
	local pop = Instance.new("UIScale")
	pop.Scale = 0
	pop.Parent = root

	-- Soft halo: two rounded layers behind the plate; the outer one fills the padding.
	local outer = frame(root, "HaloOuter", WHITE, 1)
	outer.Size = UDim2.fromScale(1, 1)
	outer.ZIndex = 1
	local soft = Instance.new("UIGradient")
	soft.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.85),
		NumberSequenceKeypoint.new(0.2, 0.2),
		NumberSequenceKeypoint.new(0.8, 0.2),
		NumberSequenceKeypoint.new(1, 0.85),
	})
	soft.Parent = outer
	corner(outer, UDim.new(0.5, 0))
	local inner = frame(root, "HaloInner", WHITE, 1)
	inner.Size = UDim2.new(1, -PAD_X * PPS, 1, -PAD_Y * PPS)
	inner.ZIndex = 2
	corner(inner, UDim.new(0.45, 0))
	local halos = { inner, outer }

	local plate = frame(root, "Plate", INK, 0.4)
	plate.Size = UDim2.new(1, -PAD_X * PPS * 2, 1, -PAD_Y * PPS * 2)
	plate.ZIndex = 3
	plate.ClipsDescendants = true
	corner(plate, UDim.new(0.3, 0))
	local stroke = Instance.new("UIStroke")
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Parent = plate

	local shimmer = frame(plate, "Shimmer", WHITE, 0.55)
	shimmer.Size = UDim2.fromScale(0.22, 1.6)
	shimmer.Rotation = 18
	shimmer.ZIndex = 4
	shimmer.Visible = false
	local sweep = Instance.new("UIGradient")
	sweep.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(0.5, 0.2),
		NumberSequenceKeypoint.new(1, 1),
	})
	sweep.Parent = shimmer

	-- The tier line is about two thirds of the name's height.
	local name = label(plate, "Name", NAME_FONT, 0.05, 0.52, 44)
	name.ZIndex = 5
	local nameStroke = Instance.new("UIStroke")
	nameStroke.Parent = name
	local nameGradient = Instance.new("UIGradient")
	nameGradient.Parent = name
	local tierText = label(plate, "Tier", TIER_FONT, 0.58, 0.36, 30)
	tierText.ZIndex = 5

	-- The far-away look: a round rarity gem with a white rim (and a soft halo for the top
	-- bands), outside the plate's pop scale so the two can cross-fade.
	local gemRoot = frame(gui, "GemRoot", WHITE, 1)
	local gemScale = Instance.new("UIScale")
	gemScale.Scale = 0
	gemScale.Parent = gemRoot
	local gemHalo = frame(gemRoot, "GemHalo", WHITE, 0.55)
	gemHalo.Size = UDim2.fromScale(GEM_HALO, GEM_HALO)
	gemHalo.ZIndex = 1
	corner(gemHalo, UDim.new(0.5, 0))
	local gem = frame(gemRoot, "Gem", WHITE, 0)
	gem.Size = UDim2.fromScale(1, 1)
	gem.ZIndex = 2
	corner(gem, UDim.new(0.5, 0))
	local rim = Instance.new("UIStroke")
	rim.Color = WHITE
	rim.Thickness = 3
	rim.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	rim.Parent = gem

	return {
		part = part,
		gui = gui,
		root = root,
		pop = pop,
		plate = plate,
		stroke = stroke,
		halos = halos,
		name = name,
		nameStroke = nameStroke,
		nameGradient = nameGradient,
		tierText = tierText,
		gemRoot = gemRoot,
		gemScale = gemScale,
		gem = gem,
		gemHalo = gemHalo,
		shimmer = shimmer,
		sparkles = {},
		light = nil,
		tweens = {},
		style = nil,
		tier = 0,
		slot = slot,
		shown = false,
		mode = "full",
		animating = false,
		lit = false,
		token = 0,
		at = CFrame.identity,
	}
end

-- Resting transparencies of the plate's pieces (the glow tweens animate from these).
local function applyLook(p: Plate)
	local style = p.style
	if not style then
		return
	end
	p.plate.BackgroundTransparency = style.plateTransparency
	p.stroke.Transparency = style.strokeTransparency
	p.stroke.Thickness = style.strokeThickness * EDGE
	p.name.TextTransparency = 0
	p.tierText.TextTransparency = if style.dark then 0.1 else 0
	-- Bright text on the Ink plates gets a soft glow outline; Ink text on cream needs none.
	p.nameStroke.Transparency = if style.dark then 0.25 else 1
	p.halos[1].BackgroundTransparency = 1 - style.halo * 0.55
	p.halos[2].BackgroundTransparency = 1 - style.halo * 0.3
	p.shimmer.BackgroundTransparency = 0.55
	for _, s in p.sparkles do
		s.BackgroundTransparency = 1
	end
end

local function stopTweens(p: Plate)
	for _, tw in p.tweens do
		tw:Cancel()
	end
	table.clear(p.tweens)
	p.nameGradient.Offset = Vector2.zero
	p.shimmer.Visible = false
end

-- Builds the plate for its current style: colours, size, gem, sparkles and light.
local function restyle(p: Plate)
	local style = p.style :: PlateStyle.Style
	stopTweens(p)
	p.animating = false
	local w = PLATE_W * style.scale
	local h = PLATE_H * math.sqrt(style.scale)
	p.part.Size = Vector3.new(w + PAD_X * 2, h + PAD_Y * 2, 0.05)
	p.part.CFrame = p.at * CFrame.new(0, -DROP - h / 2, -OUT)
	-- SurfaceGui.Brightness multiplies every colour: the plate fill, the Ink text and the
	-- quiet gems are divided by it so they keep their true colour and only the glow brightens.
	local bright = style.brightness
	local function flat(c: Color3): Color3
		return Color3.new(c.R / bright, c.G / bright, c.B / bright)
	end
	p.gui.Brightness = bright
	p.plate.BackgroundColor3 = flat(style.plate)
	p.stroke.Color = style.glow
	p.nameStroke.Color = style.glow
	p.nameStroke.Thickness = 2
	p.halos[1].BackgroundColor3 = style.glow
	p.halos[2].BackgroundColor3 = style.glow
	local gemPx = GEM * math.sqrt(style.scale) * PPS
	p.gemRoot.Size = UDim2.fromOffset(gemPx, gemPx)
	p.gem.BackgroundColor3 = if style.gemGlow then style.gem else flat(style.gem)
	p.gemHalo.BackgroundColor3 = style.glow
	p.gemHalo.Visible = style.gemGlow
	local colors = style.text
	if not style.dark then
		p.nameGradient.Color = ColorSequence.new(flat(colors[1]))
	elseif #colors == 1 then
		p.nameGradient.Color = ColorSequence.new(colors[1])
	else
		local keys = {}
		for i, c in colors do
			keys[i] = ColorSequenceKeypoint.new((i - 1) / (#colors - 1), c)
		end
		p.nameGradient.Color = ColorSequence.new(keys)
	end
	p.tierText.TextColor3 = if style.dark then style.glow:Lerp(WHITE, 0.55) else flat(style.glow:Lerp(INK, 0.6))
	p.name.Text = tierName(p.tier)
	p.tierText.Text = "Tier " .. p.tier

	if style.sparkles and #p.sparkles == 0 then
		for i, spot in { Vector2.new(0.06, 0.2), Vector2.new(0.95, 0.3), Vector2.new(0.5, 0.05) } do
			local s = frame(p.root, "Sparkle" .. i, WHITE, 1)
			s.Size = UDim2.fromOffset(9, 9)
			s.Position = UDim2.fromScale(spot.X, spot.Y)
			s.Rotation = 45
			s.ZIndex = 6
			p.sparkles[i] = s
		end
	end
	for _, s in p.sparkles do
		s.Visible = style.sparkles
	end
	if style.light and not p.light then
		local light = Instance.new("PointLight")
		light.Range = 5
		light.Brightness = 0.7
		light.Shadows = false
		light.Enabled = false
		light.Parent = p.part
		p.light = light
	end
	if p.light then
		p.light.Color = style.glow:Lerp(WHITE, 0.35)
		p.light.Enabled = false
		p.lit = false
	end
	applyLook(p)
end

-- Looping glow tweens (created on demand, cancelled when the plate stops animating).
local function startTweens(p: Plate)
	local style = p.style :: PlateStyle.Style
	local function loop(inst: Instance, time: number, props: { [string]: any }, reverses: boolean, delay: number?)
		local info = TweenInfo.new(time, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, reverses, delay or 0)
		local tw = TweenService:Create(inst, info, props)
		tw:Play()
		table.insert(p.tweens, tw)
	end
	if style.pulseSpeed > 0 then
		local half = 0.5 / style.pulseSpeed
		loop(p.halos[1], half, { BackgroundTransparency = math.max(0, 1 - style.halo * 0.55 - style.pulseAmp) }, true)
		loop(p.halos[2], half, { BackgroundTransparency = math.max(0, 1 - style.halo * 0.3 - style.pulseAmp * 0.6) }, true)
		loop(p.stroke, half, { Thickness = (style.strokeThickness + 1.5) * EDGE }, true)
	end
	if style.shimmer then
		p.shimmer.Visible = true
		p.shimmer.Position = UDim2.fromScale(-0.2, 0.5)
		loop(p.shimmer, 1.1, { Position = UDim2.fromScale(1.2, 0.5) }, false, 2.4 - style.scale)
	end
	if style.cycle then
		p.nameGradient.Offset = Vector2.new(-0.35, 0)
		loop(p.nameGradient, 3.2, { Offset = Vector2.new(0.35, 0) }, true)
	end
	if style.sparkles then
		for i, s in p.sparkles do
			s.BackgroundTransparency = 1
			loop(s, 0.6, { BackgroundTransparency = 0.1, Rotation = 135 }, true, 0.4 + i * 0.45)
		end
	end
end

local function tween(inst: Instance, time: number, props: { [string]: any }, style: Enum.EasingStyle, dir: Enum.EasingDirection): Tween
	local tw = TweenService:Create(inst, TweenInfo.new(time, style, dir), props)
	tw:Play()
	return tw
end

local function plateFor(rack: Rack, slot: number): Plate
	local existing = rack.plates[slot]
	if existing then
		return existing
	end
	local p = newPlate(slot)
	p.part.Parent = folder()
	rack.plates[slot] = p
	return p
end

-- Full card or gem for a plate `dist` studs from the camera (with hysteresis).
local function modeFor(p: Plate, style: PlateStyle.Style, dist: number): string
	if style.champion then
		return "full"
	elseif p.mode == "full" then
		return if dist > FULL_OUT then "gem" else "full"
	end
	return if dist < FULL_IN then "full" else "gem"
end

-- Collapses a shown plate into its gem or grows it back out.
local function setMode(p: Plate, mode: string)
	if p.mode == mode then
		return
	end
	p.mode = mode
	if not p.shown then
		return
	end
	if mode == "full" then
		tween(p.gemScale, 0.15, { Scale = 0 }, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
		tween(p.pop, 0.3, { Scale = 1 }, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
	else
		tween(p.pop, 0.2, { Scale = 0 }, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
		tween(p.gemScale, 0.28, { Scale = 1 }, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
	end
end

-- Shows `tier` on the slot's plate: pops it in, flips it to a new name, or just restyles.
local function showPlate(rack: Rack, slot: number, tier: number, at: CFrame)
	local p = plateFor(rack, slot)
	local style = styleFor(tier, slot == 1)
	if p.shown and p.tier == tier and p.style == style and p.at == at then
		return
	end
	p.token += 1
	local token = p.token
	local flip = p.shown and p.tier ~= tier
	p.tier, p.style, p.at = tier, style, at
	if flip and p.mode == "gem" and not style.champion then
		-- Far away: the gem takes the new colour with a small punch.
		restyle(p)
		p.gemScale.Scale = 1.4
		tween(p.gemScale, 0.25, { Scale = 1 }, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
		return
	end
	if flip and p.mode == "gem" then
		setMode(p, "full")
	end
	if flip then
		local squash = tween(p.root, 0.12, { Size = UDim2.fromScale(1, 0) }, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
		squash.Completed:Once(function()
			if p.token ~= token then
				return
			end
			restyle(p)
			tween(p.root, 0.16, { Size = UDim2.fromScale(1, 1) }, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
		end)
		return
	end
	restyle(p)
	p.root.Size = UDim2.fromScale(1, 1)
	if not p.shown then
		p.shown = true
		p.gui.Enabled = true
		local camera = Workspace.CurrentCamera
		local dist = if camera then (p.part.Position - camera.CFrame.Position).Magnitude else 0
		p.mode = if style.champion or dist < FULL_OUT then "full" else "gem"
		p.pop.Scale = 0
		p.gemScale.Scale = 0
		local grow = if p.mode == "full" then p.pop else p.gemScale
		tween(grow, 0.3, { Scale = 1 }, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
	elseif style.champion then
		setMode(p, "full")
	end
end

local function hidePlate(rack: Rack, slot: number)
	local p = rack.plates[slot]
	if not p or not p.shown then
		return
	end
	p.shown = false
	p.token += 1
	local token = p.token
	stopTweens(p)
	p.animating = false
	if p.light then
		p.light.Enabled = false
		p.lit = false
	end
	tween(p.gemScale, 0.2, { Scale = 0 }, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
	tween(p.pop, 0.2, { Scale = 0 }, Enum.EasingStyle.Quad, Enum.EasingDirection.In).Completed:Once(function()
		if p.token == token then
			p.gui.Enabled = false
		end
	end)
end

-- Units ------------------------------------------------------------------------------

local function readModel(model: Model): (number?, number?, CFrame?)
	local slot, tier, at = model:GetAttribute("Slot"), model:GetAttribute("Tier"), model:GetAttribute("PlateAt")
	if type(slot) == "number" and type(tier) == "number" and typeof(at) == "CFrame" then
		return slot, tier, at :: CFrame
	end
	return nil, nil, nil
end

-- Shows the model's plate now (it has landed) if it still owns its slot.
local function present(rack: Rack, model: Model)
	local slot, tier, at = readModel(model)
	if slot and tier and at and rack.owners[slot] == model and rack.near then
		showPlate(rack, slot, tier, at)
	end
end

local function release(rack: Rack, model: Model)
	local slot = rack.slotOf[model]
	rack.slotOf[model] = nil
	rack.waiting[model] = nil
	if slot and rack.owners[slot] == model then
		rack.owners[slot] = nil
		-- A replacement may arrive in the same batch: hide only if the slot stays empty.
		task.delay(0.1, function()
			if not rack.owners[slot] then
				hidePlate(rack, slot)
			end
		end)
	end
end

local function claim(rack: Rack, model: Model, fresh: boolean)
	local slot = readModel(model)
	local old = rack.slotOf[model]
	if old and old ~= slot then
		release(rack, model)
	end
	if not slot then
		return
	end
	rack.slotOf[model] = slot
	rack.owners[slot] = model
	if fresh then
		rack.waiting[model] = os.clock()
	else
		present(rack, model)
	end
end

local function onUnitAdded(rack: Rack, model: Instance)
	if not model:IsA("Model") then
		return
	end
	rack.modelConns[model] = model.AttributeChanged:Connect(function(attr: string)
		if attr == "Slot" or attr == "Tier" or attr == "PlateAt" then
			claim(rack, model, false)
		end
	end)
	local spawned = model:GetAttribute("Spawned")
	claim(rack, model, type(spawned) == "number" and Workspace:GetServerTimeNow() - spawned < FRESH)
end

local function onUnitRemoved(rack: Rack, model: Instance)
	if not model:IsA("Model") then
		return
	end
	local conn = rack.modelConns[model]
	if conn then
		conn:Disconnect()
		rack.modelConns[model] = nil
	end
	release(rack, model)
end

local function bindPlot(plot: Instance)
	if racks[plot] then
		return
	end
	local units = plot:FindFirstChild("Units")
	if not units then
		return
	end
	local rack: Rack = {
		plot = plot,
		units = units,
		own = false,
		near = false,
		plates = {},
		owners = {},
		slotOf = {},
		waiting = {},
		conns = {},
		modelConns = {},
	}
	racks[plot] = rack
	table.insert(
		rack.conns,
		units.ChildAdded:Connect(function(child)
			onUnitAdded(rack, child)
		end)
	)
	table.insert(
		rack.conns,
		units.ChildRemoved:Connect(function(child)
			onUnitRemoved(rack, child)
		end)
	)
	for _, child in units:GetChildren() do
		onUnitAdded(rack, child)
	end
	-- Units already standing when the rack is first seen just appear (no landing to wait for).
	for model in rack.waiting do
		rack.waiting[model] = os.clock() - LAND_MAX
	end
end

local function unbindPlot(plot: Instance)
	local rack = racks[plot]
	if not rack then
		return
	end
	racks[plot] = nil
	for _, c in rack.conns do
		c:Disconnect()
	end
	for _, c in rack.modelConns do
		c:Disconnect()
	end
	for _, p in rack.plates do
		stopTweens(p)
		p.part:Destroy()
	end
end

-- Scan: landings, full card or gem, glow animation budget, lights ---------------------

local animCount = 0
local lightCount = 0

-- Where the rack stands: the plate anchor of any unit on it (nil = empty rack).
local function rackCentre(rack: Rack): Vector3?
	local _, model = next(rack.owners)
	local at = model and model:GetAttribute("PlateAt")
	return if typeof(at) == "CFrame" then at.Position else nil
end

local function scanRack(rack: Rack, camPos: Vector3, look: Vector3, right: Vector3, up: Vector3, tanX: number, tanY: number)
	local centre = rackCentre(rack)
	local wasNear = rack.near
	local nearRack = if Budget.low() then math.min(NEAR_RACK, 100) else NEAR_RACK
	rack.near = rack.own or (centre ~= nil and (centre - camPos).Magnitude < nearRack)
	local now = os.clock()
	for model, since in rack.waiting do
		local age = now - since
		if not model.Parent then
			rack.waiting[model] = nil
		elseif age >= LAND_MIN and (age >= LAND_MAX or not Animator.isHeld(model)) then
			rack.waiting[model] = nil
			present(rack, model)
		end
	end
	if rack.near and not wasNear then
		for _, model in rack.owners do
			if not rack.waiting[model] then
				present(rack, model)
			end
		end
	end
	for _, p in rack.plates do
		if not p.shown or not p.style then
			continue
		end
		local style = p.style :: PlateStyle.Style
		local rel = p.part.Position - camPos
		local dist = rel.Magnitude
		setMode(p, modeFor(p, style, dist))
		local animate = rack.own
			and p.mode == "full"
			and dist < FAR
			and animCount < Budget.count(ANIM_MAX)
			and (style.pulseSpeed > 0 or style.shimmer or style.cycle or style.sparkles)
			and Animator.inView(rel, 3, look, right, up, tanX, tanY)
		if animate then
			animCount += 1
		end
		if animate ~= p.animating then
			p.animating = animate
			if animate then
				applyLook(p)
				startTweens(p)
			else
				stopTweens(p)
				applyLook(p)
			end
		end
		if p.light then
			local lit = rack.own and style.light and lightCount < Budget.count(LIGHTS_MAX) and dist < FAR
			if lit then
				lightCount += 1
			end
			if lit ~= p.lit then
				p.lit = lit
				p.light.Enabled = lit
			end
		end
	end
end

local function scan()
	local camera = Workspace.CurrentCamera
	if not camera then
		return
	end
	local map = Workspace:FindFirstChild("Map")
	if map then
		for _, plot in map:GetChildren() do
			if not racks[plot] and plot.Name:match("^Plot%d+$") and plot:FindFirstChild("Units") then
				bindPlot(plot)
			end
		end
	end
	local data = State.data
	local ownName = if data and data.plotIndex then "Plot" .. data.plotIndex else nil
	local cf = camera.CFrame
	local tanY = math.tan(math.rad(camera.FieldOfView) / 2)
	local viewport = camera.ViewportSize
	local tanX = tanY * (if viewport.Y > 0 then viewport.X / viewport.Y else 16 / 9)
	animCount, lightCount = 0, 0
	for plot, rack in racks do
		if not plot.Parent then
			unbindPlot(plot)
			continue
		end
		rack.own = plot.Name == ownName
		scanRack(rack, cf.Position, cf.LookVector, cf.RightVector, cf.UpVector, tanX, tanY)
	end
end

function Plates.init()
	if started then
		return
	end
	started = true
	-- Plot folders appear late on join; the scan binds them as they show up.
	task.spawn(function()
		local warned = false
		while true do
			local ok, err = pcall(scan :: any)
			if not ok and not warned then
				warned = true
				warn("[Fx.Plates] " .. tostring(err))
			end
			task.wait(SCAN)
		end
	end)
end

return Plates
