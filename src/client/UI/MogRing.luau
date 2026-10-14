--!strict
--[[
	MogRing: the visuals of the MOG TEST skill-check ring (MogHud owns the logic and input).

	  local ring = MogRing.new(parent, 180)   -- diameter in px
	  ring.frame / ring.scale                  -- root Frame (centred in parent) and its UIScale
	  ring:setCheck(c)    c = { zoneStart, zoneSize, perfectSize, dir, n }: draws the zone, swells in, hides the needle
	  ring:cue(dir)       a hidden check (PvP): the same swell-in on an empty track
	  ring:setZone(c)     ...and its zone, popped in when the needle starts (the needle keeps running)
	  ring:warn(now)      every frame before the needle starts: soft breathing gold halo
	  ring:setNeedle(travel?, dir)   every frame while running (nil hides the needle)
	  ring:setCentre(text, color)
	  ring:flash("perfect" | "hit" | "miss")
	  ring:idle()         between checks: no zone, no needle, small and dim
	  ring:destroy()

	Textures (art/blender/ui/mog_ring.py -> hud/MogRing*): an anti-aliased base (shadow, thick gold rim, bright
	blue track with bold 30-degree ticks, centre plate), white tintable layers (halo, rim flash, zone band and
	its wider perfect slice, both with a baked dark outline that takes the tint's hue; glow, edge ticks, trail,
	burst) and a full-colour needle (gold hub at the plate edge, outlined red hand reaching past the rim).

	Arcs: MogRingArc is the zone band's RIGHT half only (0..180 deg clockwise from 12 o'clock). Rotating the
	ImageLabel by `a` puts that half at screen angles [a, a + 180]; a UIGradient (rotates with the image) with a
	hard transparency step at 0.5 and Rotation = span keeps only image angles [0, span] (it hides the half-plane
	on the gradient's far side, whose boundary is the radial line at image angle span). Travel [t0, t1] maps to
	screen angles dir * travel, so dir = 1 starts at a = t0 and dir = -1 at a = -t1; both cover exactly span
	degrees, so the zone stays exact to the degree. Spans over 180 use two pieces.

	Without the image ids (not uploaded yet) the ring falls back to the old frame drawing: UICorner discs and
	a zone made of thin rotated segments.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Theme = require(ReplicatedStorage:WaitForChild("Theme")) :: any
local Kit = require(script.Parent.Kit) :: any

local C = Kit.C
local W = Theme.World

local DESIGN = 180 -- design diameter: the geometry below is in px of a 180 px ring
local CANVAS = 1.2 -- most textures cover 1.2 x the ring
local HALO_CANVAS = 1.5
local TRACK_OUT = 79 -- fallback drawing: track, plate and zone radii (match art/blender/ui/mog_ring.py)
local PLATE = 49
local BAND_OUT, BAND_IN = 79.5, 49.5
local WIDE_OUT, WIDE_IN = 84.5, 45.5 -- the raised perfect slice
local TRAIL_SPAN = 28 -- degrees of motion trail behind the needle
local SEGMENT = 2 -- fallback zone segment (degrees)
local WHITE = Color3.new(1, 1, 1)
local PERFECT = Color3.fromRGB(255, 210, 31) -- fallback perfect slice (the texture one is full colour)
local GLOW = 0.2 -- perfect-slice glow transparency at rest (a perfect flash pops it to 0)
local DIM = Color3.fromRGB(226, 230, 240) -- base tint while idle (light: the gold rim stays gold)
local ZONE = Color3.fromRGB(56, 232, 120) -- saturated green zone band (its baked outline takes this hue)

local Assets = (function(): any
	local shared = ReplicatedStorage:FindFirstChild("Shared")
	local module = shared and shared:FindFirstChild("Assets")
	if module and module:IsA("ModuleScript") then
		local ok, result = pcall(require, module)
		if ok and type(result) == "table" then
			return result
		end
	end
	return nil
end)()

local KEYS = { "Base", "Halo", "Flash", "Arc", "ArcWide", "ArcGlow", "Edge", "Needle", "TrailL", "TrailR", "Burst" }
local ids: { [string]: string } = {}
local complete = true
do
	local images = if Assets and type(Assets.Images) == "table" then Assets.Images else {}
	for _, key in KEYS do
		local id = images["hud/MogRing" .. key]
		if type(id) == "string" and id ~= "" then
			ids[key] = id
		else
			complete = false
		end
	end
end

-- Transparency steps across the gradient's middle: opaque on the near side, clear on the far side.
local HARD = NumberSequence.new({
	NumberSequenceKeypoint.new(0, 0),
	NumberSequenceKeypoint.new(0.4995, 0),
	NumberSequenceKeypoint.new(0.5005, 1),
	NumberSequenceKeypoint.new(1, 1),
})
local SOFT = NumberSequence.new({
	NumberSequenceKeypoint.new(0, 0),
	NumberSequenceKeypoint.new(0.475, 0),
	NumberSequenceKeypoint.new(0.525, 1),
	NumberSequenceKeypoint.new(1, 1),
})

export type Check = { zoneStart: number, zoneSize: number, perfectSize: number, dir: number, n: number? }

local MogRing = {}
MogRing.__index = MogRing

export type MogRing = typeof(setmetatable(
	{} :: {
		frame: Frame,
		scale: UIScale,
		size: number,
		images: boolean,
		base: GuiObject,
		halo: GuiObject,
		flashLayer: GuiObject?,
		zone: Frame,
		perfect: { ImageLabel },
		needle: GuiObject,
		trails: { [number]: ImageLabel },
		trailCut: { [number]: UIGradient },
		centre: TextLabel,
		running: boolean,
		lastTravel: number?,
		trailFading: boolean,
		haloTween: Tween?,
	},
	MogRing
))

local function centred(props: { [string]: any }): { [string]: any }
	props.BackgroundTransparency = if props.BackgroundTransparency == nil then 1 else props.BackgroundTransparency
	props.BorderSizePixel = 0
	props.Position = props.Position or UDim2.fromScale(0.5, 0.5)
	props.AnchorPoint = Vector2.new(0.5, 0.5)
	return props
end

local function image(parent: Instance, key: string, scale: number, z: number, props: { [string]: any }?): ImageLabel
	local p = centred(props or {})
	p.Name = p.Name or key
	p.Image = ids[key]
	p.Size = UDim2.fromScale(scale, scale)
	p.ZIndex = z
	p.Parent = parent
	return Kit.new("ImageLabel", p)
end

-- Colour / transparency of either an ImageLabel (texture mode) or a Frame (fallback).
local function colourProp(obj: GuiObject): string
	return if obj:IsA("ImageLabel") then "ImageColor3" else "BackgroundColor3"
end
local function alphaProp(obj: GuiObject): string
	return if obj:IsA("ImageLabel") then "ImageTransparency" else "BackgroundTransparency"
end

-- Texture mode --------------------------------------------------------------------------------

-- One arc piece: the half band rotated to screen angle `a`, cut to `span` (0 < span <= 180) degrees.
local function arcPiece(
	parent: Instance,
	key: string,
	a: number,
	span: number,
	color: Color3,
	alpha: number,
	z: number,
	cut: NumberSequence
): ImageLabel
	local piece = image(parent, key, CANVAS, z, { Rotation = a, ImageColor3 = color, ImageTransparency = alpha })
	Kit.new("UIGradient", { Rotation = span, Transparency = cut, Parent = piece })
	return piece
end

-- Pieces covering travel [t0, t1] on the side `dir` points to.
local function arcImages(
	parent: Instance,
	key: string,
	t0: number,
	t1: number,
	dir: number,
	color: Color3,
	alpha: number,
	z: number,
	cut: NumberSequence
): { ImageLabel }
	local pieces = {}
	local span = t1 - t0
	local a = if dir == 1 then t0 else -t1
	while span > 1e-3 do
		local part = math.min(span, 180)
		table.insert(pieces, arcPiece(parent, key, a, part, color, alpha, z, cut))
		a += part
		span -= part
	end
	return pieces
end

-- Fallback mode -------------------------------------------------------------------------------

local function segment(parent: Instance, k: number, a: number, b: number, color: Color3, z: number, wide: boolean?)
	local mid = math.rad((a + b) / 2)
	local outer, inner = if wide then WIDE_OUT else BAND_OUT, if wide then WIDE_IN else BAND_IN
	local radius = k * (outer + inner) / 2
	local width = 2 * math.pi * radius * math.abs(b - a) / 360 + 1.2 -- slight overlap: no seams
	Kit.new("Frame", {
		BackgroundColor3 = color,
		BorderSizePixel = 0,
		Size = UDim2.fromOffset(width, k * (outer - inner)),
		Position = UDim2.new(0.5, math.sin(mid) * radius, 0.5, -math.cos(mid) * radius),
		AnchorPoint = Vector2.new(0.5, 0.5),
		Rotation = math.deg(mid),
		ZIndex = z,
		Parent = parent,
	})
end

local function arcFrames(parent: Instance, k: number, t0: number, t1: number, dir: number, color: Color3, z: number, wide: boolean?)
	if t1 <= t0 then
		return
	end
	local count = math.max(1, math.ceil((t1 - t0) / SEGMENT))
	local step = (t1 - t0) / count
	for i = 0, count - 1 do
		local a, b = t0 + i * step, t0 + (i + 1) * step
		segment(parent, k, dir * a, dir * b, color, z, wide)
	end
end

local function disc(parent: Instance, name: string, scale: number, color: Color3, z: number, alpha: number?): Frame
	local frame = Kit.new(
		"Frame",
		centred({
			Name = name,
			BackgroundColor3 = color,
			BackgroundTransparency = alpha or 0,
			Size = UDim2.fromScale(scale, scale),
			ZIndex = z,
			Parent = parent,
		})
	)
	Kit.round(frame)
	return frame
end

-- Build ---------------------------------------------------------------------------------------

function MogRing.new(parent: GuiObject, size: number): MogRing
	local k = size / DESIGN
	local frame = Kit.new(
		"Frame",
		centred({
			Name = "MogRing",
			Size = UDim2.fromOffset(size, size),
			Parent = parent,
		})
	)
	local scale = Kit.new("UIScale", { Parent = frame })
	local self = setmetatable({
		frame = frame,
		scale = scale,
		size = size,
		images = complete,
		perfect = {},
		trails = {},
		trailCut = {},
		running = false,
		lastTravel = nil,
		trailFading = false,
		haloTween = nil,
	}, MogRing) :: any

	if complete then
		self.halo = image(frame, "Halo", HALO_CANVAS, 1, { ImageColor3 = C.Gold, ImageTransparency = 1 })
		self.base = image(frame, "Base", CANVAS, 2)
		self.zone = Kit.new("Frame", centred({ Name = "Zone", Size = UDim2.fromScale(1, 1), ZIndex = 3, Parent = frame }))
		for _, dir in { 1, -1 } do
			local trail = image(frame, if dir == 1 then "TrailL" else "TrailR", CANVAS, 7, { Visible = false, ImageColor3 = C.GoldLight })
			self.trails[dir] = trail
			self.trailCut[dir] = Kit.new("UIGradient", { Transparency = HARD, Parent = trail })
		end
		self.flashLayer = image(frame, "Flash", CANVAS, 8, { ImageTransparency = 1 })
		self.needle = image(frame, "Needle", CANVAS, 9, { Visible = false })
	else
		self.halo = disc(frame, "Glow", (size + 28) / size, C.Gold, 1, 1)
		local rim = disc(frame, "Rim", 1, C.Gold, 2)
		Kit.stroke(rim, 2, Color3.fromRGB(150, 92, 18))
		Kit.shadow(rim, size // 2, 0.35, 4)
		self.base = rim
		disc(frame, "Track", (TRACK_OUT * 2 + 2) / DESIGN, Color3.fromRGB(86, 126, 230), 3)
		self.zone = Kit.new("Frame", centred({ Name = "Zone", Size = UDim2.fromScale(1, 1), ZIndex = 4, Parent = frame }))
		local plate = disc(frame, "Plate", (PLATE * 2 - 4) / DESIGN, C.Surface, 7)
		Kit.stroke(plate, 3, C.Edge)
		local needle =
			Kit.new("Frame", centred({ Name = "Needle", Size = UDim2.fromScale(1, 1), ZIndex = 9, Visible = false, Parent = frame }))
		local bar = Kit.new("Frame", {
			Name = "Bar",
			BackgroundColor3 = C.Bad,
			BorderSizePixel = 0,
			Size = UDim2.fromOffset(9 * k, (104 - PLATE + 7) * k),
			Position = UDim2.new(0.5, 0, 0.5, -(PLATE - 7) * k),
			AnchorPoint = Vector2.new(0.5, 1),
			ZIndex = 9,
			Parent = needle,
		})
		Kit.round(bar)
		Kit.stroke(bar, 2, Color3.fromRGB(24, 30, 72))
		self.needle = needle
	end

	self.centre = Kit.number(frame, {
		Name = "Centre",
		Text = if Kit.touch then "TAP" else "SPACE",
		TextSize = math.floor(26 * k + 0.5),
		TextWrapped = false,
		TextColor3 = C.TextDim,
		Size = UDim2.fromScale(0.56, 0.4),
		Position = UDim2.fromScale(0.5, 0.5),
		AnchorPoint = Vector2.new(0.5, 0.5),
		ZIndex = 10,
	})
	return self :: MogRing
end

-- Halo ----------------------------------------------------------------------------------------

local function haloTo(self: MogRing, color: Color3?, from: number?, to: number, time: number)
	if self.haloTween then
		self.haloTween:Cancel()
		self.haloTween = nil
	end
	local halo = self.halo
	if color then
		(halo :: any)[colourProp(halo)] = color
	end
	if from then
		(halo :: any)[alphaProp(halo)] = from
	end
	if time <= 0 then
		(halo :: any)[alphaProp(halo)] = to
	else
		self.haloTween = Kit.tween(halo, time, { [alphaProp(halo)] = to }, Enum.EasingStyle.Quad)
	end
end

-- Zone ----------------------------------------------------------------------------------------

local function clearZone(self: MogRing)
	self.zone:ClearAllChildren()
	table.clear(self.perfect)
end

-- Draws the zone band and its perfect slice (replacing the last one).
local function drawZone(self: MogRing, c: Check)
	clearZone(self)
	local dir = if c.dir == -1 then -1 else 1
	local zoneStart = math.clamp(c.zoneStart, 0, 360)
	local zoneEnd = math.min(zoneStart + math.max(c.zoneSize, 0), 360)
	local perfectEnd = math.min(zoneStart + math.max(c.perfectSize, 0), zoneEnd)
	if self.images then
		-- The green band covers the whole zone; the raised full-colour gold perfect slice lies on its start, with
		-- its glow underneath (it shows round the slice, not over the band) and a white divider at the hand-off.
		arcImages(self.zone, "Arc", zoneStart, zoneEnd, dir, ZONE, 0, 4, HARD)
		if perfectEnd > zoneStart then
			self.perfect = arcImages(self.zone, "ArcGlow", zoneStart, perfectEnd, dir, C.GoldLight, GLOW, 3, SOFT)
			arcImages(self.zone, "ArcWide", zoneStart, perfectEnd, dir, WHITE, 0, 5, HARD)
			image(self.zone, "Edge", CANVAS, 6, { Rotation = dir * perfectEnd, ImageColor3 = WHITE })
		end
		image(self.zone, "Edge", CANVAS, 6, { Rotation = dir * zoneStart, ImageColor3 = C.GoldLight })
		image(self.zone, "Edge", CANVAS, 6, { Rotation = dir * zoneEnd, ImageColor3 = WHITE })
		Kit.tween(self.base, 0.2, { ImageColor3 = WHITE })
	else
		local k = self.size / DESIGN
		arcFrames(self.zone, k, perfectEnd, zoneEnd, dir, ZONE, 4)
		arcFrames(self.zone, k, zoneStart, perfectEnd, dir, PERFECT, 5, true)
		for _, t in { zoneStart, zoneEnd } do
			segment(self.zone, k, dir * t - 0.6, dir * t + 0.6, C.GoldLight, 6)
		end
	end
end

-- The swell-in cue of a new check: needle hidden, the ring pops up to full size.
local function swell(self: MogRing, dir: number)
	self:setNeedle(nil, dir)
	haloTo(self, nil, nil, 1, 0)
	self.scale.Scale = 0.7
	Kit.tween(self.scale, 0.35, { Scale = 1 }, Enum.EasingStyle.Back)
	self:_burst(W.Cream)
end

function MogRing.setCheck(self: MogRing, c: Check)
	drawZone(self, c)
	swell(self, if c.dir == -1 then -1 else 1)
end

function MogRing.cue(self: MogRing, dir: number)
	clearZone(self)
	if self.images then
		Kit.tween(self.base, 0.2, { ImageColor3 = WHITE })
	end
	swell(self, if dir == -1 then -1 else 1)
end

function MogRing.setZone(self: MogRing, c: Check)
	drawZone(self, c)
	self:_burst(ZONE)
end

function MogRing.warn(self: MogRing, now: number)
	if self.haloTween then
		self.haloTween:Cancel()
		self.haloTween = nil
	end
	local halo = self.halo;
	(halo :: any)[colourProp(halo)] = C.Gold;
	(halo :: any)[alphaProp(halo)] = 0.3 + 0.25 * math.cos(now * 12)
end

-- Needle --------------------------------------------------------------------------------------

function MogRing.setNeedle(self: MogRing, travel: number?, dir: number)
	local d = if dir == -1 then -1 else 1
	if travel == nil then
		self.needle.Visible = false
		for _, trail in self.trails do
			trail.Visible = false
		end
		self.running, self.lastTravel, self.trailFading = false, nil, false
		return
	end
	if not self.running then
		self.running = true
		haloTo(self, nil, nil, 1, 0.15)
	end
	self.needle.Visible = true
	self.needle.Rotation = d * travel
	local trail = self.trails[d]
	if trail then
		local other = self.trails[-d]
		if other then
			other.Visible = false
		end
		local shown = math.clamp(travel, 0, TRAIL_SPAN)
		trail.Visible = shown > 0.5
		trail.Rotation = d * travel
		-- Hide the part of the trail that would reach back past 12 o'clock (the start of travel).
		self.trailCut[d].Rotation = if d == 1 then 180 - shown else shown
		local last = self.lastTravel
		if last ~= nil and math.abs(travel - last) < 1e-3 then
			-- Frozen (pressed or judged): the streak fades out once.
			if not self.trailFading then
				self.trailFading = true
				Kit.tween(trail, 0.2, { ImageTransparency = 1 })
			end
		elseif self.trailFading or last == nil then
			self.trailFading = false
			trail.ImageTransparency = 0.1
		end
	end
	self.lastTravel = travel
end

function MogRing.setCentre(self: MogRing, text: string, color: Color3)
	self.centre.Text = text
	self.centre.TextColor3 = color
end

-- Results -------------------------------------------------------------------------------------

function MogRing._burst(self: MogRing, color: Color3)
	if self.images then
		local wave = image(self.frame, "Burst", 1, 1, { Name = "Burst", ImageColor3 = color })
		Kit.tween(wave, 0.5, { Size = UDim2.fromScale(1.7, 1.7), ImageTransparency = 1 }, Enum.EasingStyle.Quart)
		task.delay(0.55, function()
			wave:Destroy()
		end)
		return
	end
	local wave = Kit.new("Frame", centred({ Name = "Burst", Size = UDim2.fromScale(1, 1), ZIndex = 1, Parent = self.frame }))
	Kit.round(wave)
	local stroke = Kit.stroke(wave, 10, color)
	Kit.tween(wave, 0.5, { Size = UDim2.fromScale(1.7, 1.7) }, Enum.EasingStyle.Quart)
	Kit.tween(stroke, 0.5, { Transparency = 1, Thickness = 2 }, Enum.EasingStyle.Quart)
	task.delay(0.55, function()
		wave:Destroy()
	end)
end

function MogRing.flash(self: MogRing, kind: string)
	local color = if kind == "perfect" then C.Gold elseif kind == "hit" then W.Cream else C.Bad
	local flashLayer = self.flashLayer
	if flashLayer then
		local layer = flashLayer :: ImageLabel
		layer.ImageColor3 = if kind == "hit" then WHITE elseif kind == "perfect" then C.GoldLight else color
		layer.ImageTransparency = 0
		Kit.tween(layer, 0.6, { ImageTransparency = 1 })
	else
		local rim = self.base :: Frame
		rim.BackgroundColor3 = if kind == "hit" then WHITE else color
		Kit.tween(rim, 0.6, { BackgroundColor3 = C.Gold })
	end
	haloTo(self, color, if kind == "miss" then 0.35 else 0.1, 1, 0.7)
	if kind == "perfect" then
		for _, glow in self.perfect do
			glow.ImageColor3 = WHITE
			glow.ImageTransparency = 0
			Kit.tween(glow, 0.45, { ImageColor3 = C.GoldLight, ImageTransparency = GLOW })
		end
	end
	self:_burst(color)
end

function MogRing.idle(self: MogRing)
	clearZone(self)
	self:setNeedle(nil, 1)
	Kit.tween(self.scale, 0.3, { Scale = 0.86 })
	haloTo(self, nil, nil, 1, 0.3)
	if self.images then
		Kit.tween(self.base, 0.3, { ImageColor3 = DIM })
	end
end

function MogRing.destroy(self: MogRing)
	if self.haloTween then
		self.haloTween:Cancel()
	end
	self.frame:Destroy()
end

return MogRing
