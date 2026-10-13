-- Client-side aura orb visuals for the local player's own plot.
--
--   * Orbs the server spawns (anchored at their landing spot, route in Path1..N) roll in
--     from their unit: a hop off its shelf, a gravity fall into the gutter with a squash
--     and a bounce, a roll along it with real spin (angle = distance / radius), faster
--     down the chute, a little air off the lip, two damped bounces across the pen floor
--     and a settle wobble. Orbs queue down the
--     chute (CHUTE_GAP apart); past MAX_ROLLS or a long queue they just pop in place.
--   * Orbs are same-size glossy candy balls painted by the unit tier that produced them
--     (Tier attribute -> Shared.OrbLook.tierColor over Theme.OrbColors): a white Blender ball
--     (props/OrbBall) tinted through MeshPart.Color plus an untinted highlight (props/OrbShine).
--   * Resting orbs sit still and cost nothing per frame.
--   * "Feed" attribute bumps (the pen is full and a new orb joined this ball): a small ball
--     rolls down the same route (FeedPath1..N) and vanishes into the ball with a soft
--     silent pop; the ball's "xN" tag ticks up.
--   * Every ball with Count >= 2 wears a floating "xN" tag (lightened ball colour, Ink
--     outline) visible within LABEL_MAX_DISTANCE.
--   * "OrbsPicked" effects: ghost orbs magnet into the character with a single soft pop.
--   * Auto Aura: the server removes the orb once it has landed and rested; it just vanishes
--     (no effect is sent for it).
--   * Dumbbells (Kind = "Dumbbell", a rare prize worth OrbLook.DUMBBELL_VALUE pieces): built
--     from parts (steel bar, tier-tinted grip and plates with glowing neon rims, end caps) and
--     lit by a soft tier light. It rolls in on its plates at orb size, pumps up to full size
--     when it hits the pen floor, then rests with a slow sway and twinkles; picking it up
--     throws a bigger burst and an "x10" pop.
--   * Look: each orb is drawn as clones of props/OrbBall (Color = tier colour) and
--     props/OrbShine (white) via AssetModels, and the server's ball is hidden locally. Without
--     the uploaded models the server's ball shows in the tier colour.
--
-- Also exports small shared VFX helpers (fly / ring / sparkle / puff) used by Machines and
-- Crates. They draw the Blender sprites (Fx.Sprites: Sparkle, Ring, Puff) when uploaded and
-- fall back to the built-in sparkle texture and a flat neon disc otherwise. Orbs.coins can
-- send its coins to the HUD's cash amount (bottom left), and Orbs.walletText floats a small
-- line of text just above it.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Theme = require(ReplicatedStorage:WaitForChild("Theme"))
local Net = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Net"))
local AssetModels = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("AssetModels"))
local OrbLook = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("OrbLook"))

local Client = script.Parent.Parent
local State = require(Client.State)
local Sounds = require(Client.Sounds)
local Sprites = require(script.Parent.Sprites)
local Budget = require(script.Parent.Budget)

local player = Players.LocalPlayer
local C = Theme.Colors

local Orbs = {}

local FAR = CFrame.new(0, -10000, 0)
local ROLL_WINDOW = 1.5 -- seconds after Spawned during which an orb still rolls in
local SOUND_GAP = 1 / 12
local LABEL_MAX_DISTANCE = 70 -- camera distance cap of the "xN" tags (BillboardGui.MaxDistance)
local LABEL_HEIGHT = 1.15 -- studs
local WHITE = Color3.new(1, 1, 1)

local folder: Folder = nil :: any
local fxFolder: () -> Instance
Orbs.folder = nil :: Folder?

-- Helpers -------------------------------------------------------------------------------

local function bezier(a: Vector3, b: Vector3, c: Vector3, t: number): Vector3
	local u = 1 - t
	return a * (u * u) + b * (2 * u * t) + c * (t * t)
end

local function arcControl(from: Vector3, to: Vector3, lift: number): Vector3
	local mid = from:Lerp(to, 0.5)
	return Vector3.new(mid.X, math.max(from.Y, to.Y) + lift, mid.Z)
end

local function basePart(shape: Enum.PartType, name: string): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Shape = shape
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Material = Enum.Material.Neon
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.CFrame = FAR
	return p
end

local function sphereMesh(parent: Instance): SpecialMesh
	local mesh = Instance.new("SpecialMesh")
	mesh.MeshType = Enum.MeshType.Sphere
	mesh.Parent = parent
	return mesh
end

-- Sparkle emitters (one per colour, moved to the burst point then Emit()) ----------------

local SPARKLE_SPRITE = Sprites.image("Sparkle")
local SPARKLE_WINDOW = 0.3 -- seconds: sparkle bursts inside one window share ...
local SPARKLE_BUDGET = 28 -- ... at most this many particles (a big pickup stays calm)
local sparkleWindow, sparkleSpent = 0, 0

local emitters: { [string]: { part: BasePart, emitter: ParticleEmitter } } = {}

local function emitterFor(color: Color3)
	local key = color:ToHex()
	local entry = emitters[key]
	if entry then
		return entry
	end
	local part = basePart(Enum.PartType.Block, "Sparkles")
	part.Size = Vector3.new(0.2, 0.2, 0.2)
	part.Transparency = 1
	part.Parent = fxFolder()
	local emitter = Instance.new("ParticleEmitter")
	emitter.Texture = SPARKLE_SPRITE or "rbxasset://textures/particles/sparkles_main.dds"
	emitter.Color = ColorSequence.new(color:Lerp(Color3.new(1, 1, 1), 0.35), color)
	emitter.LightEmission = if SPARKLE_SPRITE then 0 else 1
	emitter.LightInfluence = 0
	emitter.Rate = 0
	emitter.Lifetime = NumberRange.new(0.35, 0.7)
	emitter.Speed = NumberRange.new(6, 14)
	emitter.SpreadAngle = Vector2.new(180, 180)
	emitter.Drag = 4
	emitter.Acceleration = Vector3.new(0, -8, 0)
	emitter.RotSpeed = NumberRange.new(-180, 180)
	if SPARKLE_SPRITE then
		-- The 4-point sprite fills its frame: smaller, pops up then shrinks away.
		emitter.Size = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.15),
			NumberSequenceKeypoint.new(0.2, 0.42),
			NumberSequenceKeypoint.new(1, 0),
		})
		emitter.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0),
			NumberSequenceKeypoint.new(0.7, 0.1),
			NumberSequenceKeypoint.new(1, 0.8),
		})
		emitter.RotSpeed = NumberRange.new(-90, 90)
	else
		emitter.Size = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.5),
			NumberSequenceKeypoint.new(1, 0),
		})
		emitter.Transparency = NumberSequence.new(0, 0.6)
	end
	emitter.Parent = part
	entry = { part = part, emitter = emitter }
	emitters[key] = entry
	return entry
end

function Orbs.sparkle(pos: Vector3, color: Color3?, count: number?, speed: number?)
	local now = os.clock()
	if now - sparkleWindow > SPARKLE_WINDOW then
		sparkleWindow, sparkleSpent = now, 0
	end
	local n = math.min(Budget.count(count or 8), Budget.count(SPARKLE_BUDGET) - sparkleSpent)
	if n <= 0 then
		return
	end
	sparkleSpent += n
	local entry = emitterFor(color or C.Orb)
	entry.part.CFrame = CFrame.new(pos)
	local s = speed or 1
	entry.emitter.Speed = NumberRange.new(6 * s, 14 * s)
	entry.emitter:Emit(n)
end

-- Dust puffs (one shared emitter): a few soft clouds spreading low from `pos`. ------------
-- Returns false (and does nothing) when the Puff sprite is missing.

local PUFF_SPRITE = Sprites.image("Puff")
local puffEntry: { part: BasePart, emitter: ParticleEmitter }? = nil

function Orbs.puff(pos: Vector3, count: number?): boolean
	if not PUFF_SPRITE then
		return false
	end
	local entry = puffEntry
	if not entry or not entry.part.Parent then
		local part = basePart(Enum.PartType.Block, "Puffs")
		part.Size = Vector3.new(0.2, 0.2, 0.2)
		part.Transparency = 1
		part.Parent = fxFolder()
		local emitter = Sprites.emitter(part, "Puff", {
			Color = ColorSequence.new(Color3.fromRGB(244, 238, 228)),
			Lifetime = NumberRange.new(0.45, 0.7),
			Speed = NumberRange.new(2.5, 4.5),
			SpreadAngle = Vector2.new(75, 75),
			EmissionDirection = Enum.NormalId.Top,
			Drag = 6,
			RotSpeed = NumberRange.new(-30, 30),
			Size = NumberSequence.new({
				NumberSequenceKeypoint.new(0, 0.5),
				NumberSequenceKeypoint.new(1, 1.4),
			}),
			Transparency = NumberSequence.new({
				NumberSequenceKeypoint.new(0, 0.3),
				NumberSequenceKeypoint.new(1, 1),
			}),
		})
		if not emitter then
			part:Destroy()
			return false
		end
		entry = { part = part, emitter = emitter :: ParticleEmitter }
		puffEntry = entry
	end
	local e = entry :: { part: BasePart, emitter: ParticleEmitter }
	e.part.CFrame = CFrame.new(pos)
	e.emitter:Emit(Budget.count(math.min(count or 3, 12)))
	return true
end

-- Expanding flat rings (pooled) -----------------------------------------------------------
-- With the Ring sprite: an invisible flat part wearing the sprite as a top decal. Else a
-- flat neon disc.

local RING_SPRITE = Sprites.image("Ring")
local ringPool: { Part } = {}
local spriteRingPool: { { part: Part, decal: Decal } } = {}

local function spriteRing(pos: Vector3, color: Color3, radius: number, dur: number, startTransparency: number)
	local entry = table.remove(spriteRingPool)
	if not entry then
		local part = basePart(Enum.PartType.Block, "FxRing")
		part.Material = Enum.Material.SmoothPlastic
		part.Transparency = 1
		part.Parent = fxFolder()
		local decal = Instance.new("Decal")
		decal.Face = Enum.NormalId.Top
		decal.Texture = RING_SPRITE :: string
		decal.Parent = part
		entry = { part = part, decal = decal }
	end
	local e = entry :: { part: Part, decal: Decal }
	e.decal.Color3 = color:Lerp(WHITE, 0.15)
	e.decal.Transparency = startTransparency
	e.part.Size = Vector3.new(0.6, 0.05, 0.6)
	e.part.CFrame = CFrame.new(pos) * CFrame.Angles(0, math.random() * math.pi * 2, 0)
	local d = radius * 2
	local info = TweenInfo.new(dur, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	TweenService:Create(e.part, info, { Size = Vector3.new(d, 0.05, d) }):Play()
	local fade = TweenService:Create(e.decal, info, { Transparency = 1 })
	fade.Completed:Once(function()
		e.part.CFrame = FAR
		table.insert(spriteRingPool, e)
	end)
	fade:Play()
end

function Orbs.ring(pos: Vector3, color: Color3?, radius: number?, duration: number?, startTransparency: number?)
	if RING_SPRITE then
		-- The sprite is a thin outline, so it starts a little more opaque than the disc did.
		spriteRing(pos, color or C.Orb, radius or 3, duration or 0.45, (startTransparency or 0.25) * 0.6)
		return
	end
	local ring = table.remove(ringPool)
	if not ring then
		ring = basePart(Enum.PartType.Cylinder, "FxRing")
		ring.Parent = fxFolder()
	end
	local r = ring :: Part
	local dur = duration or 0.45
	r.Color = color or C.Orb
	r.Transparency = startTransparency or 0.25
	r.Size = Vector3.new(0.08, 0.6, 0.6)
	r.CFrame = CFrame.new(pos) * CFrame.Angles(0, 0, math.pi / 2)
	local d = (radius or 3) * 2
	local tween = TweenService:Create(
		r,
		TweenInfo.new(dur, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ Size = Vector3.new(0.05, d, d), Transparency = 1 }
	)
	tween.Completed:Once(function()
		r.CFrame = FAR
		table.insert(ringPool, r)
	end)
	tween:Play()
end

-- Shared FX folder (created on demand so helpers work before init) ------------------------

fxFolder = function(): Instance
	if folder and folder.Parent then
		return folder
	end
	local existing = Workspace:FindFirstChild("ClientFx")
	if existing and existing:IsA("Folder") then
		folder = existing
	else
		local f = Instance.new("Folder")
		f.Name = "ClientFx"
		f.Parent = Workspace
		folder = f
	end
	Orbs.folder = folder :: any
	return folder :: any
end

function Orbs.getFolder(): Instance
	return fxFolder()
end

-- World float text (pop in with overshoot, rise, fade). Capped. -------------------------------

local MAX_TEXTS = 10
local texts: { Part } = {}

export type TextOptions = {
	scale: number?, -- 1 = normal, 2 = big
	rise: number?, -- studs
	life: number?, -- seconds
	stroke: Color3?,
	-- An attribute set to the text on the "FloatText" part before it is parented, so other
	-- code can tell this text from the rest without reading its label.
	tag: string?,
}

function Orbs.text(pos: Vector3, text: string, color: Color3?, opts: TextOptions?)
	local o = opts or {}
	local k = math.clamp(o.scale or 1, 0.5, 3)
	local life = o.life or (0.9 + 0.25 * k)
	local rise = o.rise or (3 + k)
	while #texts >= MAX_TEXTS do
		local old = table.remove(texts, 1)
		if old then
			old:Destroy()
		end
	end
	local holder = basePart(Enum.PartType.Block, "FloatText")
	holder.Size = Vector3.new(0.2, 0.2, 0.2)
	holder.Transparency = 1
	holder.CFrame = CFrame.new(pos)
	if o.tag then
		holder:SetAttribute(o.tag, text)
	end
	holder.Parent = fxFolder()
	table.insert(texts, holder)

	local gui = Instance.new("BillboardGui")
	gui.AlwaysOnTop = true
	gui.LightInfluence = 0
	gui.MaxDistance = 220
	gui.Size = UDim2.new(4 * k + 2, 0, 1.4 * k + 0.4, 0)
	gui.Parent = holder
	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.AnchorPoint = Vector2.new(0.5, 0.5)
	label.Position = UDim2.fromScale(0.5, 0.5)
	label.Size = UDim2.fromScale(1, 1)
	label.Font = Theme.Fonts.Title
	label.TextScaled = true
	label.Text = text
	label.TextColor3 = color or C.Primary
	label.Rotation = (math.random() - 0.5) * 10
	label.Parent = gui
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 2 + k
	stroke.Color = o.stroke or C.Stroke or Color3.new(0, 0, 0)
	stroke.Parent = label
	local scale = Instance.new("UIScale")
	scale.Scale = 0.2
	scale.Parent = label

	-- Anticipation-free snap: overshoot pop, settle, rise and fade.
	TweenService:Create(scale, TweenInfo.new(0.16, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1.3 }):Play()
	task.delay(0.16, function()
		TweenService:Create(scale, TweenInfo.new(0.14, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Scale = 1 }):Play()
		TweenService:Create(label, TweenInfo.new(0.3, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Rotation = 0 }):Play()
	end)
	TweenService:Create(
		holder,
		TweenInfo.new(life, Enum.EasingStyle.Quart, Enum.EasingDirection.Out),
		{ CFrame = CFrame.new(pos + Vector3.new(0, rise, 0)) }
	):Play()
	local fadeAt = life * 0.6
	task.delay(fadeAt, function()
		local info = TweenInfo.new(life - fadeAt, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
		TweenService:Create(label, info, { TextTransparency = 1 }):Play()
		TweenService:Create(stroke, info, { Transparency = 1 }):Play()
		TweenService:Create(scale, info, { Scale = 0.7 }):Play()
	end)
	task.delay(life + 0.05, function()
		local i = table.find(texts, holder)
		if i then
			table.remove(texts, i)
		end
		holder:Destroy()
	end)
end

-- Wallet anchor: the HUD's cash amount (TycoonUI > Wallet > Money, bottom left) -------------
-- Found by name, so this module needs nothing from the UI. Until the HUD exists (or while it
-- hides the wallet) the anchor is a fixed point near the bottom-left corner.

-- One table, not a local each: a chunk holds 200 locals at most.
local WALLET = {
	fallback = Vector2.new(150, 110), -- px in from the left edge, up from the bottom
	depth = 7, -- studs in front of the camera that homing coins fly to
	textSize = 22, -- design px (the cash amount itself is 46)
	textLift = 12, -- design px between the cash amount's top and the text's centre
	textRise = 34, -- design px it climbs while it fades
	textLife = 0.9, -- seconds
	textDrift = 24, -- design px of random sideways start, so repeats do not stack
	maxTexts = 3,
}

local walletLabel: GuiObject? = nil
local walletLayer: Frame? = nil
local walletTexts: { TextLabel } = {}

-- A full-viewport layer with no insets or scale, so its pixels are viewport pixels.
local function walletFrame(): Frame?
	local layer = walletLayer
	if layer and layer.Parent then
		return layer
	end
	local playerGui = player:FindFirstChildOfClass("PlayerGui")
	if not playerGui then
		return nil
	end
	local gui = Instance.new("ScreenGui")
	gui.Name = "FxWallet"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 5
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	pcall(function()
		gui.ScreenInsets = Enum.ScreenInsets.None
	end)
	local frame = Instance.new("Frame")
	frame.Name = "Layer"
	frame.BackgroundTransparency = 1
	frame.Size = UDim2.fromScale(1, 1)
	frame.Parent = gui
	gui.Parent = playerGui
	walletLayer = frame
	return frame
end

-- The cash amount label and the HUD's pixel scale; nil while the HUD hides its wallet.
local function walletMoney(): (GuiObject?, number)
	local playerGui = player:FindFirstChildOfClass("PlayerGui")
	local screen = playerGui and playerGui:FindFirstChild("TycoonUI")
	if not screen then
		return nil, 1
	end
	local uiScale = screen:FindFirstChildOfClass("UIScale")
	local scale = if uiScale then uiScale.Scale else 1
	local label = walletLabel
	if not label or not label:IsDescendantOf(screen) then
		local wallet = screen:FindFirstChild("Wallet")
		local money = wallet and wallet:FindFirstChild("Money")
		label = if money and money:IsA("GuiObject") then money else nil
		walletLabel = label
	end
	local wallet = label and label.Parent
	if not label or not (wallet and wallet:IsA("GuiObject") and wallet.Visible) then
		return nil, scale
	end
	return label, scale
end

-- Viewport pixel at the middle of the cash amount (its top edge with `top`).
local function walletPixel(top: boolean?): (Vector2, number)
	local layer = walletFrame()
	local label, scale = walletMoney()
	if layer and label then
		local at = label.AbsolutePosition - layer.AbsolutePosition
		local size = label.AbsoluteSize
		return at + Vector2.new(size.X / 2, if top then 0 else size.Y / 2), scale
	end
	local camera = Workspace.CurrentCamera
	local height = if camera then camera.ViewportSize.Y else 720
	return Vector2.new(WALLET.fallback.X, height - WALLET.fallback.Y), scale
end

-- Small text over the wallet (what a pad just took): pops in, climbs a little and fades.
function Orbs.walletText(text: string, color: Color3?)
	local layer = walletFrame()
	if not layer then
		return
	end
	while #walletTexts >= WALLET.maxTexts do
		local old = table.remove(walletTexts, 1)
		if old then
			old:Destroy()
		end
	end
	local at, k = walletPixel(true)
	local x = at.X + (math.random() * 2 - 1) * WALLET.textDrift * k
	local y = at.Y - WALLET.textLift * k
	local label = Instance.new("TextLabel")
	label.Name = "WalletText"
	label.BackgroundTransparency = 1
	label.AnchorPoint = Vector2.new(0.5, 0.5)
	label.Position = UDim2.fromOffset(x, y)
	label.Size = UDim2.fromOffset(280 * k, WALLET.textSize * 1.4 * k)
	label.Font = (Theme.Fonts :: any).Number or Theme.Fonts.Title
	label.TextSize = math.max(10, math.floor(WALLET.textSize * k + 0.5))
	label.Text = text
	label.TextColor3 = color or C.Bad
	label.ZIndex = 20
	label.Parent = layer
	table.insert(walletTexts, label)
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = math.max(1.5, 2 * k)
	stroke.Color = C.Stroke or Color3.new(0, 0, 0)
	stroke.Parent = label
	local scale = Instance.new("UIScale")
	scale.Scale = 0.5
	scale.Parent = label

	local life = WALLET.textLife
	TweenService:Create(scale, TweenInfo.new(0.18, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 }):Play()
	TweenService:Create(
		label,
		TweenInfo.new(life, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ Position = UDim2.fromOffset(x, y - WALLET.textRise * k) }
	):Play()
	local fadeAt = life * 0.55
	task.delay(fadeAt, function()
		local info = TweenInfo.new(life - fadeAt, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
		TweenService:Create(label, info, { TextTransparency = 1 }):Play()
		TweenService:Create(stroke, info, { Transparency = 1 }):Play()
	end)
	task.delay(life + 0.05, function()
		local i = table.find(walletTexts, label)
		if i then
			table.remove(walletTexts, i)
		end
		label:Destroy()
	end)
end

-- 3D coins: ballistic spin, bounce, then fade or home to the wallet. Capped. ----------------

local MAX_COINS = 70
local COIN_GOLD = Color3.fromRGB(255, 205, 60)
local GRAVITY = Vector3.new(0, -70, 0)

type Coin = {
	part: Part,
	size: number,
	pos: Vector3,
	vel: Vector3,
	axis: Vector3,
	angle: number,
	spin: number,
	floor: number,
	born: number,
	life: number,
	homeAt: number?, -- time it starts flying to the wallet
	homeFrom: Vector3?,
	homeT: number,
}

local coinList: { Coin } = {}
local coinConn: RBXScriptConnection? = nil
local coinParts: { BasePart } = {}
local coinCFrames: { CFrame } = {}

-- World point just in front of the camera, over the HUD's cash amount.
local function walletPoint(): Vector3?
	local camera = Workspace.CurrentCamera
	if not camera then
		return nil
	end
	local at = walletPixel()
	local ray = camera:ViewportPointToRay(at.X, at.Y)
	return ray.Origin + ray.Direction * WALLET.depth
end

local function stepCoins(dt: number)
	local now = os.clock()
	local wallet = walletPoint()
	table.clear(coinParts)
	table.clear(coinCFrames)
	local i = 1
	while i <= #coinList do
		local c = coinList[i]
		local age = now - c.born
		local done = false
		if c.homeAt and now >= c.homeAt and wallet then
			if not c.homeFrom then
				c.homeFrom = c.pos
			end
			c.homeT += dt / 0.45
			local t = math.min(c.homeT, 1)
			local e = t * t * t -- ease-in: whoosh into the wallet
			local from = c.homeFrom :: Vector3
			c.pos = from:Lerp(wallet, e) + Vector3.new(0, math.sin(t * math.pi) * 2, 0)
			c.part.Size = Vector3.new(0.16, 1, 1) * (c.size * (1 - 0.6 * e))
			done = t >= 1
		else
			c.vel += GRAVITY * dt
			c.pos += c.vel * dt
			if c.pos.Y < c.floor and c.vel.Y < 0 then
				c.pos = Vector3.new(c.pos.X, c.floor, c.pos.Z)
				c.vel = Vector3.new(c.vel.X * 0.6, -c.vel.Y * 0.42, c.vel.Z * 0.6)
				c.spin *= 0.6
			end
			if not c.homeAt then
				local fade = math.clamp((age - c.life * 0.7) / (c.life * 0.3), 0, 1)
				c.part.Transparency = fade
				done = age >= c.life
			elseif age > 4 then
				done = true
			end
		end
		c.angle += c.spin * dt
		if done then
			c.part:Destroy()
			table.remove(coinList, i)
		else
			table.insert(coinParts, c.part)
			table.insert(coinCFrames, CFrame.new(c.pos) * CFrame.fromAxisAngle(c.axis, c.angle) * CFrame.Angles(0, 0, math.pi / 2))
			i += 1
		end
	end
	if #coinParts > 0 then
		Workspace:BulkMoveTo(coinParts, coinCFrames, Enum.BulkMoveMode.FireCFrameChanged)
	end
	if #coinList == 0 and coinConn then
		coinConn:Disconnect()
		coinConn = nil
	end
end

export type CoinOptions = {
	count: number?,
	speed: number?, -- launch speed
	spread: number?, -- horizontal start radius
	height: number?, -- start height above pos
	floor: number?, -- world Y they bounce on (default pos.Y)
	life: number?,
	toWallet: boolean?, -- fly to the wallet after bouncing
	stagger: number?, -- seconds between coins
	size: number?, -- coin diameter in studs (default 1)
}

-- Spawns gold coins at `pos` (a puff when speed is high, a shower when height is high).
function Orbs.coins(pos: Vector3, opts: CoinOptions?)
	local o = opts or {}
	local count = Budget.count(math.clamp(o.count or 6, 1, 40))
	local speed = o.speed or 18
	local spread = o.spread or 0.4
	local height = o.height or 0
	local life = o.life or 1.1
	local stagger = o.stagger or 0
	local size = math.clamp(o.size or 1, 0.5, 2)
	for i = 1, count do
		local function spawnCoin()
			if #coinList >= Budget.count(MAX_COINS) then
				local old = table.remove(coinList, 1)
				if old then
					old.part:Destroy()
				end
			end
			local part = basePart(Enum.PartType.Cylinder, "Coin")
			part.Material = Enum.Material.Metal
			part.Reflectance = 0.25
			part.Color = COIN_GOLD
			part.Size = Vector3.new(0.16, 1, 1) * size
			part.Parent = fxFolder()
			local angle = math.random() * math.pi * 2
			local r = math.sqrt(math.random()) * spread
			local start = pos + Vector3.new(math.cos(angle) * r, height + math.random() * height * 0.3, math.sin(angle) * r)
			local out = Vector3.new(math.cos(angle), 0, math.sin(angle))
			local vel = out * speed * (0.25 + math.random() * 0.25) + Vector3.new(0, speed * (0.7 + math.random() * 0.5), 0)
			local now = os.clock()
			local coinLife = life * (0.85 + math.random() * 0.3)
			table.insert(coinList, {
				part = part,
				size = size,
				pos = start,
				vel = vel,
				axis = Vector3.new(math.random() - 0.5, math.random() - 0.5, math.random() - 0.5).Unit,
				angle = math.random() * 6,
				spin = 8 + math.random() * 10,
				floor = (o.floor or pos.Y) + 0.1,
				born = now,
				life = coinLife,
				homeAt = if o.toWallet then now + coinLife * 0.6 + i * 0.025 else nil,
				homeT = 0,
			})
			if not coinConn then
				coinConn = RunService.Heartbeat:Connect(stepCoins)
			end
		end
		if stagger > 0 and i > 1 then
			task.delay((i - 1) * stagger, spawnCoin)
		else
			spawnCoin()
		end
	end
end

-- Orb balls ---------------------------------------------------------------------------------
-- Two Blender pieces per orb (art/blender/orbs/make_orbs.py): props/OrbBall, a near-white
-- glossy sphere tinted per orb through MeshPart.Color, and props/OrbShine, its white highlight
-- and sparkle, left untinted. Both are sized from the orb's diameter. nil when not uploaded.

local ballTemplates: { [string]: MeshPart | false } = {}
local BALL_REFLECTANCE = 0.08
local REST_YAW, REST_TILT = math.rad(30), math.rad(9) -- per-orb resting turn, so highlights do not line up
-- OrbShine's bounding box and its centre offset from the ball centre, in ball diameters.
local SHINE_SIZE = Vector3.new(0.6496, 0.2044, 0.1686)
local SHINE_OFFSET = Vector3.new(0.0081, 0.3454, -0.3162)
local ORB_PALETTE: { Color3 } = (Theme :: any).OrbColors or { Color3.fromRGB(150, 76, 242) }

-- Yaw that turns a ball's front (-Z, where OrbShine sits) toward the camera, so resting
-- balls show their highlight from where the player watches the pen.
local function faceCamera(pos: Vector3): CFrame
	local camera = Workspace.CurrentCamera
	if not camera then
		return CFrame.identity
	end
	local d = camera.CFrame.Position - pos
	local flat = Vector3.new(d.X, 0, d.Z)
	if flat.Magnitude < 0.01 then
		return CFrame.identity
	end
	return CFrame.lookAt(Vector3.zero, flat.Unit)
end

local function cloneBall(name: string, color: Color3?): MeshPart?
	local template = ballTemplates[name]
	if template == nil then
		template = false
		local model = AssetModels.clone("props/" .. name)
		local mesh = if model and model:IsA("MeshPart") then model else model and model:FindFirstChildWhichIsA("MeshPart", true)
		if mesh then
			local m = mesh :: MeshPart
			m.Name = name
			m.Anchored = true
			m.CanCollide = false
			m.CanQuery = false
			m.CanTouch = false
			-- Baked vertex colours multiply with Color, so it is always set explicitly: white
			-- here (the shine stays white), the tier colour per ball. No shadows, so piled balls
			-- do not darken each other.
			m.Color = WHITE
			m.Material = Enum.Material.SmoothPlastic
			m.Reflectance = if name == "OrbBall" then BALL_REFLECTANCE else 0
			m.CastShadow = false
			m.Parent = nil
			template = m
		end
		ballTemplates[name] = template
	end
	if not template then
		return nil
	end
	local ball = template:Clone()
	if color then
		ball.Color = color
	end
	ball.CFrame = FAR
	ball.Parent = folder
	return ball
end

-- Rolling trips ---------------------------------------------------------------------------
-- An orb's route from its unit to the pen, sampled by time (frame-rate independent). The
-- server stores it as waypoints <prefix>1..N with <prefix>Kinds naming each one (feet, drop,
-- gutter, chuteTop, chuteBottom, land; see readRoute). Phases:
--   1 hop:    out of the unit, low under the shelf above, to the drop point in front of
--             the rack (never below its own shelf's deck, so it clears the shelves below)
--   2 fall:   gravity drop into the gutter, sped up so the top shelf takes <= FALL_MAX
--   3 gutter: lands with a squash and a small bounce, rolls toward the chute
--   4 chute:  slows a little for the turn, then accelerates down the slide
--   5 air:    leaves the lip on a gravity arc, curving toward its spot
--   6 floor:  lands, two damped bounces, rolls to its spot easing to a stop (and climbs
--             onto the pile when its spot is on the top layer)
-- Waypoints are orb-centre positions for an orb of the server's size; smaller balls `sink`
-- by the radius difference so they still touch the surfaces.

local GRAVITY_Y = 60
local HOP_APEX = 0.3 -- kept low: the shelf above is just overhead
local HOP_MIN, HOP_MAX = 0.3, 0.45
local FALL_MAX = 0.7
local GUTTER_HOP_MIN, GUTTER_HOP_MAX = 0.08, 0.55 -- bounce height on landing in the gutter
local GUTTER_V0, GUTTER_ACCEL, GUTTER_VMAX = 6, 14, 18
local CHUTE_V0, CHUTE_ACCEL, CHUTE_VMAX = 10, 18, 18
local BOUNCE_1, BOUNCE_1_HEIGHT = 0.26, 0.45
local BOUNCE_2, BOUNCE_2_HEIGHT = 0.16, 0.13
local FLOOR_MIN, FLOOR_MAX = 0.5, 1.2
local CHUTE_GAP = 0.3 -- seconds between orbs entering the chute
local MAX_QUEUE = 2.5 -- an orb that would wait longer than this for the chute pops in instead
local MAX_ROLLS = 14 -- concurrent rolling orbs and feed balls; the rest pop in place
local APPEAR_TIME = 0.22
local DOWN = Vector3.new(0, 0, -1)
local PHASE_GUTTER, PHASE_FLOOR, PHASE_DONE = 3, 6, 7

-- Named waypoints of a rack -> pen route. `drop` equals `gutter` on routes without a drop.
export type Route = {
	feet: Vector3,
	drop: Vector3,
	gutter: Vector3,
	chuteTop: Vector3,
	chuteBottom: Vector3,
	land: Vector3,
}

type Roll = {
	t0: number, -- launch time (os.clock)
	dHop: number,
	dFall: number,
	dGutter: number,
	dChute: number,
	dAir: number,
	dFloor: number,
	total: number,
	p0: Vector3, -- start (the unit's chest)
	drop: Vector3,
	gutter: Vector3,
	top: Vector3,
	bottom: Vector3,
	l1: Vector3, -- first floor contact
	land: Vector3,
	hopDrop: number, -- p0.Y - drop.Y
	fallV0: number, -- downward speed leaving the hop
	fallG: number, -- fall gravity (raised for long falls)
	fallLen: number,
	gutterHop: number, -- bounce height and time on landing in the gutter
	dGutterHop: number,
	gutterImpact: number, -- 0..1, scales the landing squash
	gutterLen: number,
	chuteLen: number,
	chuteV0: number,
	airVd: number, -- downward speed leaving the lip
	airFix: number,
	airCtrl: Vector3, -- horizontal Bezier control point of the air arc
	floorY: number, -- centre height of a ball resting on the pen floor
	impact: number, -- 0.4..1, scales the bounces
	sink: number,
	radius: number,
	phase: number, -- 0 waiting, 1 hop, 2 fall, 3 gutter, 4 chute, 5 air, 6 floor, 7 done
	last: Vector3?,
	rot: CFrame,
}

local activeRolls = 0
local chuteFreeAt = 0

local function flat(v: Vector3): Vector3
	return Vector3.new(v.X, 0, v.Z)
end

local function smooth(x: number): number
	local t = math.clamp(x, 0, 1)
	return t * t * (3 - 2 * t)
end

-- Distance covered after `t` seconds starting at v0, accelerating at `a` up to `vmax`.
local function accelDist(t: number, v0: number, a: number, vmax: number): number
	local t1 = (vmax - v0) / a
	if t <= t1 then
		return v0 * t + 0.5 * a * t * t
	end
	return v0 * t1 + 0.5 * a * t1 * t1 + vmax * (t - t1)
end

-- (seconds to cover `len`, speed at the end) for the same motion.
local function accelTime(len: number, v0: number, a: number, vmax: number): (number, number)
	local s1 = (vmax * vmax - v0 * v0) / (2 * a)
	if len <= s1 then
		local v = math.sqrt(v0 * v0 + 2 * a * len)
		return (v - v0) / a, v
	end
	return (vmax - v0) / a + (len - s1) / vmax, vmax
end

local ROUTE_KINDS = { "feet", "drop", "gutter", "chuteTop", "chuteBottom", "land" }

-- Reads a route stored as <prefix>1..<prefix>N + <prefix>Count (see Tycoon.setRoute). Each
-- waypoint's role comes from <prefix>Kinds ("feet,drop,gutter,..."); without it (or if it
-- does not match) the roles are inferred: 1 = feet, the last four = gutter, chute top,
-- chute bottom, landing, and the point before the gutter (if any) = drop.
local function readRoute(inst: Instance, prefix: string): Route?
	local count = inst:GetAttribute(prefix .. "Count")
	if type(count) ~= "number" or count < 5 then
		return nil
	end
	local points: { Vector3 } = {}
	for i = 1, count do
		local point = inst:GetAttribute(prefix .. i)
		if typeof(point) ~= "Vector3" then
			return nil
		end
		points[i] = point
	end
	local at: { [string]: number } = {}
	local kinds = inst:GetAttribute(prefix .. "Kinds")
	if type(kinds) == "string" then
		local i = 0
		for name in string.gmatch(kinds, "[^,%s]+") do
			i += 1
			at[name] = i
		end
		if i ~= count then
			at = {}
		end
	end
	for _, name in ROUTE_KINDS do
		if name ~= "drop" and not at[name] then
			at = { feet = 1, gutter = count - 3, chuteTop = count - 2, chuteBottom = count - 1, land = count }
			if count >= 6 then
				at.drop = count - 4
			end
			break
		end
	end
	local gutter = points[at.gutter]
	return {
		feet = points[at.feet],
		drop = if at.drop then points[at.drop] else gutter,
		gutter = gutter,
		chuteTop = points[at.chuteTop],
		chuteBottom = points[at.chuteBottom],
		land = points[at.land],
	}
end

local function newRoll(route: Route, origin: Vector3?, floorY: number?, radius: number, sink: number): Roll
	local drop, gutter, top, bottom, land = route.drop, route.gutter, route.chuteTop, route.chuteBottom, route.land
	local p0 = origin or (route.feet + Vector3.new(0, 1.5, 0))

	-- Hop: front-loaded horizontally (out from under the shelf above first), easing down to
	-- the drop point's height with a small lift.
	local hopLen = flat(drop - p0).Magnitude
	local dHop = math.clamp(0.28 + hopLen * 0.02, HOP_MIN, HOP_MAX)
	local hopDrop = p0.Y - drop.Y
	local fallV0 = math.max((2 * hopDrop + 4 * HOP_APEX) / dHop, 0)

	-- Fall: real gravity, raised just enough that long falls end within FALL_MAX.
	local fallLen = math.max(drop.Y - gutter.Y, 0)
	local fallG = GRAVITY_Y
	local dFall = 0
	if fallLen > 1e-3 then
		dFall = (-fallV0 + math.sqrt(fallV0 * fallV0 + 2 * GRAVITY_Y * fallLen)) / GRAVITY_Y
		if dFall > FALL_MAX then
			dFall = FALL_MAX
			fallG = 2 * (fallLen - fallV0 * dFall) / (dFall * dFall)
		end
	end
	local vImpact = fallV0 + fallG * dFall
	local gutterHop = math.clamp(vImpact * 0.006, GUTTER_HOP_MIN, GUTTER_HOP_MAX)

	local gutterLen = (top - gutter).Magnitude
	local dGutter, vGutter = accelTime(gutterLen, GUTTER_V0, GUTTER_ACCEL, GUTTER_VMAX)
	local dGutterHop = 2 * math.sqrt(2 * gutterHop / GRAVITY_Y)
	dGutter = math.max(dGutter, dGutterHop)
	local chuteV0 = math.clamp(vGutter * 0.6, 3, CHUTE_V0)
	local chuteLen = (bottom - top).Magnitude
	local dChute, vChute = accelTime(chuteLen, chuteV0, CHUTE_ACCEL, CHUTE_VMAX)

	local fy = math.min(floorY or land.Y, land.Y)
	local chuteDir = if chuteLen > 1e-3 then (bottom - top) / chuteLen else DOWN
	local chuteFlat = flat(chuteDir)
	chuteFlat = if chuteFlat.Magnitude > 1e-3 then chuteFlat.Unit else DOWN
	local airVd = math.max(0, -chuteDir.Y * vChute)
	local airDrop = math.max(bottom.Y - fy, 0)
	local dAir = math.max((-airVd + math.sqrt(airVd * airVd + 2 * GRAVITY_Y * airDrop)) / GRAVITY_Y, 0.1)
	local airFix = fy - (bottom.Y - airVd * dAir - 0.5 * GRAVITY_Y * dAir * dAir)
	local toSpot = flat(land - bottom)
	local dist = toSpot.Magnitude
	local dirSpot = if dist > 1e-3 then toSpot / dist else chuteFlat
	local airLen = math.min(flat(chuteDir).Magnitude * vChute * dAir, dist * 0.7)
	local l1 = Vector3.new(bottom.X, fy, bottom.Z) + dirSpot * airLen

	local floorLen = dist - airLen
	local vLand = math.max(airLen / dAir, 5)
	local dFloor = math.clamp(2 * floorLen / vLand, FLOOR_MIN, FLOOR_MAX)

	return {
		t0 = 0,
		dHop = dHop,
		dFall = dFall,
		dGutter = dGutter,
		dChute = dChute,
		dAir = dAir,
		dFloor = dFloor,
		total = dHop + dFall + dGutter + dChute + dAir + dFloor,
		p0 = p0,
		drop = drop,
		gutter = gutter,
		top = top,
		bottom = bottom,
		l1 = l1,
		land = land,
		hopDrop = hopDrop,
		fallV0 = fallV0,
		fallG = fallG,
		fallLen = fallLen,
		gutterHop = gutterHop,
		dGutterHop = dGutterHop,
		gutterImpact = math.clamp(vImpact / 60, 0.3, 1),
		gutterLen = gutterLen,
		chuteLen = chuteLen,
		chuteV0 = chuteV0,
		airVd = airVd,
		airFix = airFix,
		airCtrl = flat(bottom) + chuteFlat * airLen * 0.5,
		floorY = fy,
		impact = math.clamp((airVd + GRAVITY_Y * dAir) / 10, 0.4, 1),
		sink = sink,
		radius = math.max(radius, 0.1),
		phase = 0,
		last = nil,
		rot = CFrame.Angles(0, math.random() * math.pi * 2, 0),
	}
end

-- Position on the route `t` seconds after launch, and the phase it is in.
local function sampleRoll(r: Roll, t: number): (Vector3, number)
	if t < 0 then
		return r.p0, 0
	end
	if t < r.dHop then
		local u = t / r.dHop
		local e = 1 - (1 - u) * (1 - u)
		local h = r.p0:Lerp(r.drop, e)
		local y = r.p0.Y - r.hopDrop * u * u + HOP_APEX * 4 * u * (1 - u)
		return Vector3.new(h.X, y - r.sink * u, h.Z), 1
	end
	t -= r.dHop
	local sinkDown = Vector3.new(0, r.sink, 0)
	if t < r.dFall then
		local fallen = math.min(r.fallV0 * t + 0.5 * r.fallG * t * t, r.fallLen)
		local h = r.drop:Lerp(r.gutter, fallen / r.fallLen)
		return Vector3.new(h.X, r.drop.Y - fallen, h.Z) - sinkDown, 2
	end
	t -= r.dFall
	if t < r.dGutter then
		local s = accelDist(t, GUTTER_V0, GUTTER_ACCEL, GUTTER_VMAX)
		local pos = r.gutter:Lerp(r.top, if r.gutterLen > 1e-3 then math.min(s / r.gutterLen, 1) else 1) - sinkDown
		if t < r.dGutterHop then
			local b = t / r.dGutterHop
			pos += Vector3.new(0, 4 * b * (1 - b) * r.gutterHop, 0)
		end
		return pos, 3
	end
	t -= r.dGutter
	if t < r.dChute then
		local s = accelDist(t, r.chuteV0, CHUTE_ACCEL, CHUTE_VMAX)
		return r.top:Lerp(r.bottom, if r.chuteLen > 1e-3 then math.min(s / r.chuteLen, 1) else 1) - sinkDown, 4
	end
	t -= r.dChute
	if t < r.dAir then
		local u = t / r.dAir
		local h = bezier(flat(r.bottom), r.airCtrl, flat(r.l1), u)
		local y = r.bottom.Y - r.airVd * t - 0.5 * GRAVITY_Y * t * t + r.airFix * u
		return Vector3.new(h.X, y - r.sink, h.Z), 5
	end
	t -= r.dAir
	if t < r.dFloor then
		local u = t / r.dFloor
		local e = 1 - (1 - u) * (1 - u) -- constant deceleration to a stop
		local h = flat(r.l1):Lerp(flat(r.land), e)
		local y = r.floorY + (r.land.Y - r.floorY) * smooth((u - 0.55) / 0.45)
		if t < BOUNCE_1 then
			local b = t / BOUNCE_1
			y += 4 * b * (1 - b) * BOUNCE_1_HEIGHT * r.impact
		elseif t < BOUNCE_1 + BOUNCE_2 then
			local b = (t - BOUNCE_1) / BOUNCE_2
			y += 4 * b * (1 - b) * BOUNCE_2_HEIGHT * r.impact
		end
		return Vector3.new(h.X, y - r.sink * (1 - smooth((u - 0.75) / 0.25)), h.Z), 6
	end
	return r.land, PHASE_DONE
end
-- End of the route maths (tests load the section above in Lune).

-- Crates read their routes the same way.
Orbs.readRoute = readRoute

-- Queues a roll behind the orbs already heading for the chute. False = the wait would be too
-- long (or too many rolls are running): show the orb without the trip.
local function scheduleRoll(r: Roll, now: number): boolean
	if activeRolls >= Budget.count(MAX_ROLLS) then
		return false
	end
	local reach = r.dHop + r.dFall + r.dGutter
	local launch = math.max(now, chuteFreeAt - reach)
	if launch - now > MAX_QUEUE then
		return false
	end
	r.t0 = launch
	chuteFreeAt = launch + reach + CHUTE_GAP
	activeRolls += 1
	return true
end

local function finishRoll()
	activeRolls = math.max(0, activeRolls - 1)
end

-- Rolling spin from the distance moved since last frame (angle = distance / radius).
local function spinRoll(r: Roll, pos: Vector3)
	local last = r.last
	r.last = pos
	if not last then
		return
	end
	local axis = Vector3.yAxis:Cross(pos - last)
	local m = axis.Magnitude
	if m > 1e-4 then
		r.rot = (CFrame.fromAxisAngle(axis / m, m / r.radius) * r.rot):Orthonormalize()
	end
end

local function backOut(t: number): number
	local c = 1.70158
	local u = t - 1
	return 1 + (c + 1) * u * u * u + c * u * u
end

-- Flying ghost orbs (pooled; one Heartbeat drives every flight) ---------------------------

type Ghost = {
	part: Part,
	mesh: SpecialMesh,
	trail: Trail,
	balls: { [string]: MeshPart }, -- Blender ball per colour step (lazily made)
	active: string?, -- step currently shown instead of the plain ball
}
type Flight = {
	ghost: Ghost,
	from: Vector3,
	ctrl: Vector3,
	to: Vector3,
	target: BasePart?,
	targetOffset: Vector3,
	t0: number,
	dur: number,
	accel: boolean,
	s0: number,
	s1: number,
	trail: boolean,
	variant: string?,
	started: boolean,
	roll: Roll?, -- follow a rolling route instead of the arc (t0/dur match the roll)
	onDone: (() -> ())?,
}

local ghostPool: { Ghost } = {}
local flights: { Flight } = {}

local function getGhost(): Ghost
	local g = table.remove(ghostPool)
	if g then
		return g
	end
	local part = basePart(Enum.PartType.Ball, "FxOrb")
	part.Size = Vector3.new(1, 1, 1)
	part.Transparency = 1
	local mesh = sphereMesh(part)
	local a0 = Instance.new("Attachment")
	a0.Position = Vector3.new(0, 0.18, 0)
	a0.Parent = part
	local a1 = Instance.new("Attachment")
	a1.Position = Vector3.new(0, -0.18, 0)
	a1.Parent = part
	local trail = Instance.new("Trail")
	trail.Attachment0 = a0
	trail.Attachment1 = a1
	trail.Lifetime = 0.22
	trail.LightEmission = 1
	trail.FaceCamera = true
	trail.Transparency = NumberSequence.new(0.2, 1)
	trail.WidthScale = NumberSequence.new(1, 0)
	trail.Enabled = false
	trail.Parent = part
	part.Parent = folder
	return { part = part, mesh = mesh, trail = trail, balls = {}, active = nil }
end

local function releaseGhost(g: Ghost)
	g.trail.Enabled = false
	g.part.Transparency = 1
	g.part.CFrame = FAR
	if g.active then
		g.balls[g.active].CFrame = FAR
		g.active = nil
	end
	table.insert(ghostPool, g)
end

export type FlyOptions = {
	from: Vector3,
	to: Vector3?,
	target: BasePart?, -- follow a moving part (e.g. HumanoidRootPart)
	targetOffset: Vector3?,
	color: Color3?,
	size: number?,
	endSize: number?,
	duration: number?,
	delay: number?,
	arc: number?, -- studs the curve rises above the higher end
	accel: boolean?, -- ease-in (magnet) instead of smooth in-out
	trail: boolean?,
	variant: string?, -- any value: draw the tinted Blender ball (props/OrbBall) if uploaded
	onDone: (() -> ())?,
}

function Orbs.fly(opts: FlyOptions): Flight
	local g = getGhost()
	local color = opts.color or C.Orb
	g.part.Color = color
	g.trail.Color = ColorSequence.new(color)
	local variant = if opts.variant then "Ball" else nil
	if variant and not g.balls[variant] then
		local ball = cloneBall("OrbBall")
		if ball then
			g.balls[variant] = ball
		end
	end
	if variant and g.balls[variant] then
		g.balls[variant].Color = color
	end
	local to = opts.to or (if opts.target then opts.target.Position else opts.from)
	local flight: Flight = {
		ghost = g,
		from = opts.from,
		ctrl = arcControl(opts.from, to, opts.arc or 3),
		to = to,
		target = opts.target,
		targetOffset = opts.targetOffset or Vector3.zero,
		t0 = os.clock() + (opts.delay or 0),
		dur = opts.duration or 0.6,
		accel = opts.accel == true,
		s0 = opts.size or 0.8,
		s1 = opts.endSize or opts.size or 0.8,
		trail = opts.trail == true,
		variant = if variant and g.balls[variant] then variant else nil,
		started = false,
		roll = nil,
		onDone = opts.onDone,
	}
	table.insert(flights, flight)
	return flight
end

-- Real orbs -------------------------------------------------------------------------------

type OrbFx = {
	part: BasePart,
	mesh: SpecialMesh,
	shell: Part,
	shellMesh: SpecialMesh,
	home: CFrame,
	phase: number,
	scale: number,
	pulse: number, -- extra scale that decays (feed / landing)
	squash: number, -- squash timer (seconds since impact, < 0 = none)
	squashAmp: number,
	roll: Roll?, -- rolling in from its unit (nil = resting)
	waiting: boolean, -- queued for the chute, not shown yet
	rot: CFrame, -- orientation left by the roll; eases back to restRot at rest
	restRot: CFrame, -- small random yaw and tilt of this orb at rest
	rest: number, -- 0..1, fades the idle bob in after settling
	appear: number, -- 0..1 pop-in for orbs shown without a roll
	big: boolean,
	color: Color3,
	flash: number, -- soft flash amount that decays (merge)
	count: number, -- merged count currently shown (catches up as feed balls land)
	feedSeen: number,
	label: BillboardGui?,
	labelPlate: Frame?,
	labelText: TextLabel?,
	labelScale: UIScale?,
	labelOn: boolean, -- picked to show (fading in or shown)
	labelToken: number,
	ball: MeshPart?, -- tinted Blender ball clone (nil = the server's plain ball)
	shine: MeshPart?, -- its untinted highlight
	labelLift: number, -- per-orb tag height jitter, so neighbouring tags do not line up
	still: boolean, -- resting and placed: skipped by the frame loop until something wakes it
	conns: { RBXScriptConnection },
	dumbbell: boolean, -- Kind = "Dumbbell": drawn from `pieces` instead of the ball
	pieces: { DumbbellPiece }?,
	light: PointLight?,
	grow: number, -- dumbbell pump-up on landing: < 0 = travel size, 0..1 growing, >= 1 full
	barAxis: Vector3, -- rolling dumbbell: world direction of its bar
	spin: number, -- rolling dumbbell: angle turned around its bar
	lastPos: Vector3?,
	twinkle: number, -- seconds until the resting dumbbell's next sparkle
}

local orbs: { [BasePart]: OrbFx } = {}
-- Recently removed orbs, so pickup ghosts can keep the colour of the orb they replace.
local recentGone: { { pos: Vector3, color: Color3, big: boolean, dumbbell: boolean, at: number } } = {}
local orbFolder: Instance? = nil
local folderConns: { RBXScriptConnection } = {}
local INK = (Theme :: any).World and (Theme :: any).World.Ink or Color3.fromRGB(58, 48, 96)

local function attrCount(part: BasePart): number
	local n = part:GetAttribute("Count")
	return if type(n) == "number" then math.max(1, math.floor(n)) else 1
end

-- Small bold "x3" count tag just above a ball with Count >= 2 (client-only, lives on the
-- invisible shell): text in the lightened ball colour with a dark Ink outline.
local function ensureLabel(fx: OrbFx): BillboardGui
	local existing = fx.label
	if existing then
		return existing
	end
	local gui = Instance.new("BillboardGui")
	gui.Name = "CountTag"
	gui.AlwaysOnTop = false
	gui.LightInfluence = 0
	gui.MaxDistance = LABEL_MAX_DISTANCE
	gui.Size = UDim2.fromScale(LABEL_HEIGHT * 2.2, LABEL_HEIGHT)
	gui.Enabled = false
	gui.Adornee = fx.shell
	gui.Parent = fx.shell
	local plate = Instance.new("Frame")
	plate.AnchorPoint = Vector2.new(0.5, 0.5)
	plate.Position = UDim2.fromScale(0.5, 0.5)
	plate.Size = UDim2.fromScale(1, 1)
	plate.BackgroundTransparency = 1
	plate.BorderSizePixel = 0
	plate.Parent = gui
	local uiScale = Instance.new("UIScale")
	uiScale.Parent = plate
	local text = Instance.new("TextLabel")
	text.BackgroundTransparency = 1
	text.AnchorPoint = Vector2.new(0.5, 0.5)
	text.Position = UDim2.fromScale(0.5, 0.5)
	text.Size = UDim2.fromScale(1, 1)
	text.Font = Theme.Fonts.Title
	text.TextScaled = true
	local r, g, b = OrbLook.tagRGB(fx.color.R * 255, fx.color.G * 255, fx.color.B * 255)
	text.TextColor3 = Color3.fromRGB(r, g, b)
	text.TextTransparency = 1
	text.Parent = plate
	local stroke = Instance.new("UIStroke")
	stroke.Color = INK
	stroke.Thickness = 2
	stroke.LineJoinMode = Enum.LineJoinMode.Round
	stroke.Parent = text
	fx.label, fx.labelPlate, fx.labelText, fx.labelScale = gui, plate, text, uiScale
	return gui
end

local function setLabelText(fx: OrbFx)
	local gui = fx.label
	if gui then
		gui.StudsOffset = Vector3.new(0, fx.part.Size.Y * 0.5 + LABEL_HEIGHT * 0.45 + fx.labelLift, 0);
		(fx.labelText :: TextLabel).Text = "x" .. tostring(fx.count)
	end
end

-- Fades the count tag in (small grow) or out (then disables it).
local function fadeLabel(fx: OrbFx, on: boolean)
	if fx.labelOn == on then
		return
	end
	fx.labelOn = on
	fx.labelToken += 1
	if not on and not fx.label then
		return
	end
	local gui = ensureLabel(fx)
	local text, uiScale = fx.labelText :: TextLabel, fx.labelScale :: UIScale
	if on then
		setLabelText(fx)
		gui.Enabled = true
		uiScale.Scale = 0.7
		local info = TweenInfo.new(0.22, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
		TweenService:Create(text, info, { TextTransparency = 0 }):Play()
		TweenService:Create(uiScale, TweenInfo.new(0.25, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 }):Play()
		return
	end
	local token = fx.labelToken
	local info = TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
	TweenService:Create(uiScale, info, { Scale = 0.7 }):Play()
	local fade = TweenService:Create(text, info, { TextTransparency = 1 })
	fade.Completed:Once(function()
		if fx.labelToken == token then
			gui.Enabled = false
		end
	end)
	fade:Play()
end

-- New count on a ball: show / retext its tag (with a tiny pop when it was already showing).
local function updateLabel(fx: OrbFx, punch: boolean)
	if fx.count < 2 or fx.waiting then
		fadeLabel(fx, false)
		return
	end
	setLabelText(fx)
	fadeLabel(fx, true)
	local uiScale = fx.labelScale
	if punch and fx.labelOn and uiScale then
		uiScale.Scale = 1.4
		TweenService:Create(uiScale, TweenInfo.new(0.28, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 }):Play()
	end
end

local function refreshVisibility(fx: OrbFx)
	-- The server ball only shows without the Blender ball, once launched. A dumbbell's server
	-- part is a plain stand-in for other players: always hidden here.
	fx.part.LocalTransparencyModifier = if fx.waiting or fx.ball or fx.dumbbell then 1 else 0
	if fx.pieces then
		for _, piece in fx.pieces do
			piece.part.LocalTransparencyModifier = if fx.waiting then 1 else 0
		end
	end
	if fx.ball then
		fx.ball.LocalTransparencyModifier = if fx.waiting then 1 else 0
	end
	if fx.shine then
		fx.shine.LocalTransparencyModifier = if fx.waiting then 1 else 0
	end
	if fx.waiting then
		fadeLabel(fx, false)
	end
end

local function clearBall(fx: OrbFx)
	if fx.ball then
		fx.ball:Destroy()
	end
	if fx.shine then
		fx.shine:Destroy()
	end
	fx.ball, fx.shine = nil, nil
	if fx.pieces then
		for _, piece in fx.pieces do
			piece.part:Destroy()
		end
	end
	fx.pieces, fx.light = nil, nil
end

-- Dumbbells ----------------------------------------------------------------------------------
-- Cylinders along the bar (local X). x = centre along the bar, len = length, dia = diameter, all
-- in dumbbell lengths; the big rims' radius is OrbLook.DUMBBELL_PLATE (its resting height).

type DumbbellPiece = { part: Part, x: number, len: number, dia: number }

local DUMBBELL_TRAVEL = 0.5 -- size while rolling in (fits the gutter and chute like an orb)
local DUMBBELL_GROW = 0.45 -- seconds to pump up to full size after hitting the pen floor
local STEEL = Color3.fromRGB(228, 234, 242)
-- { x, len, dia, paint }; pieces with x ~= 0 are mirrored to both ends.
local DUMBBELL_SHAPE: { { any } } = {
	{ 0, 0.96, 0.085, "steel" }, -- bar
	{ 0, 0.3, 0.105, "grip" },
	{ 0.2, 0.05, 0.16, "steel" }, -- collar
	{ 0.285, 0.12, 0.6, "plate" }, -- big plate
	{ 0.285, 0.07, 0.62, "rim" },
	{ 0.39, 0.085, 0.46, "plate" }, -- small plate
	{ 0.39, 0.05, 0.475, "rim" },
	{ 0.465, 0.04, 0.12, "steel" }, -- end cap
}

local function paintPiece(part: Part, paint: string, color: Color3)
	if paint == "steel" then
		part.Color, part.Material, part.Reflectance = STEEL, Enum.Material.SmoothPlastic, 0.3
	elseif paint == "grip" then
		part.Color, part.Material, part.Reflectance = color:Lerp(INK, 0.45), Enum.Material.SmoothPlastic, 0
	elseif paint == "plate" then
		part.Color, part.Material, part.Reflectance = color, Enum.Material.SmoothPlastic, 0.12
	else
		part.Color, part.Material, part.Reflectance = color:Lerp(WHITE, 0.45), Enum.Material.Neon, 0
	end
end

local function buildDumbbell(fx: OrbFx)
	local pieces: { DumbbellPiece } = {}
	for _, spec in DUMBBELL_SHAPE do
		local x, len, dia, paint = spec[1] :: number, spec[2] :: number, spec[3] :: number, spec[4] :: string
		local sides: { number } = if x == 0 then { 1 } else { -1, 1 }
		for _, side in sides do
			local part = basePart(Enum.PartType.Cylinder, "Dumbbell")
			paintPiece(part, paint, fx.color)
			part.Parent = folder
			table.insert(pieces, { part = part, x = x * side, len = len, dia = dia })
		end
	end
	local light = Instance.new("PointLight")
	light.Color = fx.color:Lerp(WHITE, 0.25)
	light.Range = 7
	light.Brightness = 1.2
	light.Shadows = false
	light.Parent = pieces[1].part
	fx.pieces, fx.light = pieces, light
end

-- Size multiplier of a dumbbell: travel size, then a springy pump-up to full size.
local function dumbbellScale(fx: OrbFx): number
	if fx.grow < 0 then
		return DUMBBELL_TRAVEL
	end
	return DUMBBELL_TRAVEL + (1 - DUMBBELL_TRAVEL) * backOut(math.min(fx.grow, 1))
end

-- Radius of a dumbbell's big plates at size multiplier `k`, and an orb's radius (its route's).
local function dumbbellRadii(fx: OrbFx, k: number): (number, number)
	local length = fx.part.Size.X
	return OrbLook.DUMBBELL_PLATE * length * k, length / OrbLook.DUMBBELL_SCALE / 2
end

-- Rotation of a dumbbell whose bar points along horizontal `axis`, turned `spin` around it.
local function barFrame(axis: Vector3, spin: number): CFrame
	return CFrame.fromMatrix(Vector3.zero, axis, Vector3.yAxis) * CFrame.Angles(spin, 0, 0)
end

-- Rolling dumbbell: the bar turns across the direction of travel and it rolls on its plates.
local function rollDumbbell(fx: OrbFx, pos: Vector3, radius: number, dt: number): CFrame
	local last = fx.lastPos
	fx.lastPos = pos
	if last then
		local axis = Vector3.yAxis:Cross(pos - last)
		local m = axis.Magnitude
		if m > 1e-4 then
			local want, sign = axis / m, 1
			if want:Dot(fx.barAxis) < 0 then
				want, sign = -want, -1
			end
			local blended = fx.barAxis:Lerp(want, math.min(1, dt * 12))
			fx.barAxis = if blended.Magnitude > 1e-3 then blended.Unit else want
			fx.spin += sign * m / math.max(radius, 0.1)
		end
	end
	return barFrame(fx.barAxis, fx.spin)
end

-- Paints the orb in its producing tier's colour and dresses it in the two Blender pieces
-- (the server's plain ball in that colour is the fallback).
local function styleOrb(fx: OrbFx)
	local tier = fx.part:GetAttribute("Tier")
	fx.color = OrbLook.tierColor(if type(tier) == "number" then tier else 1, ORB_PALETTE)
	fx.part.Color = fx.color
	fx.part.Material = Enum.Material.SmoothPlastic
	fx.part.Transparency = 0
	if fx.dumbbell then
		if not fx.pieces then
			buildDumbbell(fx)
		end
	elseif not fx.ball then
		fx.ball = cloneBall("OrbBall", fx.color)
		fx.shine = if fx.ball then cloneBall("OrbShine") else nil
	end
	refreshVisibility(fx)
end

local function untrack(part: BasePart)
	local fx = orbs[part]
	if not fx then
		return
	end
	orbs[part] = nil
	if fx.roll then
		fx.roll = nil
		finishRoll()
	end
	table.insert(recentGone, { pos = fx.home.Position, color = fx.color, big = fx.big, dumbbell = fx.dumbbell, at = os.clock() })
	if #recentGone > 24 then
		table.remove(recentGone, 1)
	end
	for _, conn in fx.conns do
		conn:Disconnect()
	end
	clearBall(fx)
	fx.shell:Destroy()
end

-- First touch of the pen floor: a dust puff (a soft ring without the sprite), a few
-- sparkles and a squash.
local function touchedFloor(fx: OrbFx, pos: Vector3, impact: number)
	fx.squash, fx.squashAmp = 0, 0.32 * impact
	if fx.dumbbell then
		-- A prize: it pumps up to full size with a bigger burst.
		fx.grow = 0
		local plate = dumbbellRadii(fx, DUMBBELL_TRAVEL)
		local floor = pos - Vector3.new(0, plate, 0)
		Orbs.puff(floor, 4)
		Orbs.ring(floor, fx.color, 2.8, 0.55, 0.3)
		Orbs.sparkle(pos, fx.color, 10, 0.8)
		Orbs.sparkle(pos, WHITE, 4, 0.6)
		return
	end
	local floor = pos - Vector3.new(0, fx.part.Size.Y * 0.45, 0)
	if not Orbs.puff(floor, if impact > 0.6 then 3 else 2) then
		Orbs.ring(floor, fx.color, 1.5 * fx.scale, 0.45, 0.35)
	end
	Orbs.sparkle(pos, fx.color, 3, 0.45)
end

-- Came to rest at its spot: small settle wobble, then the idle bob fades in.
local function settled(fx: OrbFx)
	fx.waiting = false
	fx.squash, fx.squashAmp = 0, 0.16
	fx.rest = 0
	refreshVisibility(fx)
	updateLabel(fx, false)
end

-- A feed ball reached its orb: squash, soft flash and a small silent pop; the tag ticks up.
local function mergePop(fx: OrbFx)
	if not orbs[fx.part] then
		return
	end
	local target = attrCount(fx.part)
	fx.count = math.min(fx.count + 1, target)
	fx.still = false
	fx.pulse = 0.18
	fx.squash, fx.squashAmp = 0, 0.3
	fx.flash = 0.7
	local pos = fx.home.Position
	Orbs.ring(pos - Vector3.new(0, fx.part.Size.Y * 0.4 * fx.scale, 0), fx.color, 1.3 * fx.scale, 0.35, 0.45)
	Orbs.sparkle(pos, fx.color, 4, 0.5)
	updateLabel(fx, true)
end

local function onFeed(fx: OrbFx)
	local feed = fx.part:GetAttribute("Feed")
	local total = if type(feed) == "number" then feed else fx.feedSeen + 1
	local delta = math.clamp(total - fx.feedSeen, 1, 3)
	fx.feedSeen = total
	local path = readRoute(fx.part, "FeedPath")
	local from = fx.part:GetAttribute("FeedFrom")
	local tint = fx.part:GetAttribute("FeedTint")
	local color = if typeof(tint) == "Color3" then tint else fx.color
	local orbSize = fx.part.Size.Y
	local size = orbSize * 0.6
	for n = 1, delta do
		local roll = if path
			then newRoll(path, if typeof(from) == "Vector3" then from else nil, nil, size / 2, (orbSize - size) / 2)
			else nil
		if roll and scheduleRoll(roll, os.clock() + (n - 1) * CHUTE_GAP) then
			local flight = Orbs.fly({
				from = roll.p0,
				to = fx.home.Position,
				color = color,
				variant = "Ball",
				size = size,
				trail = false,
				onDone = function()
					finishRoll()
					mergePop(fx)
				end,
			})
			flight.roll = roll
			flight.t0 = roll.t0
			flight.dur = roll.total
		else
			-- Too busy for another rolling ball: pop the count straight away.
			task.delay(0.08 + (n - 1) * 0.12, mergePop, fx)
		end
	end
end

local function track(part: Instance)
	if not part:IsA("BasePart") or orbs[part] then
		return
	end
	local p = part :: BasePart
	p.CastShadow = false -- locally: hidden server balls must not shade the pile
	local mesh = p:FindFirstChildOfClass("SpecialMesh") or sphereMesh(p)
	local shell = basePart(Enum.PartType.Ball, "OrbGlow")
	shell.Size = p.Size * 1.85
	shell.Transparency = 1 -- invisible anchor for the count tag
	local shellMesh = sphereMesh(shell)
	shell.CFrame = p.CFrame
	shell.Parent = folder
	-- Hide any legacy number label the server might still attach.
	for _, child in p:GetChildren() do
		if child:IsA("BillboardGui") then
			child.Enabled = false
		end
	end
	local fx: OrbFx = {
		part = p,
		mesh = mesh :: SpecialMesh,
		shell = shell,
		shellMesh = shellMesh,
		home = p.CFrame,
		phase = math.random() * math.pi * 2,
		scale = 1,
		pulse = 0,
		squash = -1,
		squashAmp = 0,
		roll = nil,
		waiting = false,
		rot = CFrame.identity,
		restRot = faceCamera(p.Position)
			* CFrame.Angles(0, (math.random() * 2 - 1) * REST_YAW, 0)
			* CFrame.Angles((math.random() * 2 - 1) * REST_TILT, 0, (math.random() * 2 - 1) * REST_TILT),
		rest = 1,
		appear = 1,
		big = false,
		color = p.Color,
		labelLift = (math.random() * 2 - 1) * 0.15,
		still = false,
		flash = 0,
		count = attrCount(p),
		feedSeen = (function()
			local feed = p:GetAttribute("Feed")
			return if type(feed) == "number" then feed else 0
		end)(),
		label = nil,
		labelPlate = nil,
		labelText = nil,
		labelScale = nil,
		labelOn = false,
		labelToken = 0,
		ball = nil,
		shine = nil,
		conns = {},
		dumbbell = p:GetAttribute("Kind") == "Dumbbell",
		pieces = nil,
		light = nil,
		grow = 1,
		barAxis = CFrame.Angles(0, math.random() * math.pi * 2, 0).XVector,
		spin = 0,
		lastPos = nil,
		twinkle = math.random(),
	}
	orbs[p] = fx
	if fx.dumbbell then
		-- Lies with its bar across the view (both plates show), turned a little.
		fx.restRot = faceCamera(p.Position) * CFrame.Angles(0, (math.random() * 2 - 1) * REST_YAW * 0.7, 0)
		fx.rot = fx.restRot
	end

	-- Roll in from the unit that produced it (queued behind earlier orbs), or pop in place.
	local spawned = p:GetAttribute("Spawned")
	local age = if type(spawned) == "number" then Workspace:GetServerTimeNow() - spawned else math.huge
	if age < ROLL_WINDOW then
		local path = readRoute(p, "Path")
		local origin = p:GetAttribute("Origin")
		local restY = p:GetAttribute("RestY")
		-- A dumbbell follows the orb route (radius = its travel-size plates) and is lifted
		-- onto its plates when drawn.
		local radius = if fx.dumbbell then (dumbbellRadii(fx, DUMBBELL_TRAVEL)) else p.Size.Y / 2
		local roll = if path
			then newRoll(
				path,
				if typeof(origin) == "Vector3" then origin else nil,
				if type(restY) == "number" then restY else nil,
				radius,
				0
			)
			else nil
		if roll and scheduleRoll(roll, os.clock()) then
			fx.roll = roll
			fx.waiting = true
			fx.rest = 0
			fx.grow = -1
		else
			fx.appear = 0
			fx.rest = 0
		end
	end

	styleOrb(fx)
	updateLabel(fx, false)

	table.insert(
		fx.conns,
		p.AttributeChanged:Connect(function(attr)
			if attr == "Tier" then
				clearBall(fx)
				styleOrb(fx)
			elseif attr == "Feed" then
				onFeed(fx)
			elseif attr == "Count" then
				-- Never show more than the server has; feed balls catch the count up.
				local n = attrCount(p)
				if n < fx.count then
					fx.count = n
					updateLabel(fx, false)
				end
			end
		end)
	)
	table.insert(
		fx.conns,
		p.AncestryChanged:Connect(function(_, parent)
			if parent == nil then
				untrack(p)
			end
		end)
	)
end

local function bindFolder(f: Instance?)
	if f == orbFolder then
		return
	end
	for _, conn in folderConns do
		conn:Disconnect()
	end
	table.clear(folderConns)
	for part in orbs do
		untrack(part)
	end
	orbFolder = f
	if not f then
		return
	end
	table.insert(folderConns, f.ChildAdded:Connect(track))
	for _, child in f:GetChildren() do
		track(child)
	end
end

-- Pickup magnet + pop ----------------------------------------------------------------------

local lastSound = 0

-- One soft pop per pickup: no combo pitch climb, no layered tick. Orbs landing in the
-- same instant share one pop.
local function pickupBlip(count: number)
	local now = os.clock()
	if now - lastSound < SOUND_GAP then
		return
	end
	lastSound = now
	-- Merged orbs and dumbbells: the same pop, a touch lower and fuller.
	local play: any = Sounds.play
	play("OrbPickup", 0.06, if count >= 2 then 0.9 else 1)
end

-- Extra celebration when the piece picked up at `pos` was a dumbbell.
local function dumbbellPicked(pos: Vector3, color: Color3)
	Orbs.sparkle(pos, color, 14, 1.1)
	Orbs.sparkle(pos, WHITE, 6, 0.9)
	Orbs.ring(pos - Vector3.new(0, 0.8, 0), color, 3.4, 0.5, 0.25)
	Orbs.text(pos + Vector3.new(0, 1.5, 0), "x" .. tostring(OrbLook.DUMBBELL_VALUE) .. "!", color:Lerp(WHITE, 0.3), { scale = 1.6 })
end

local function onPicked(data: any)
	if type(data) ~= "table" or type(data.positions) ~= "table" then
		return
	end
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	local counts = if type(data.counts) == "table" then data.counts else {}
	if not root then
		return
	end
	for i, pos in data.positions do
		if typeof(pos) ~= "Vector3" then
			continue
		end
		local count = if type(counts[i]) == "number" then math.max(1, counts[i]) else 1
		local grow = 1
		local color = ORB_PALETTE[1]
		local dumbbell = false
		-- Match the colour of the real orb that sat there, if we still know it.
		for _, fx in orbs do
			if (fx.home.Position - pos).Magnitude < 1.2 then
				color, dumbbell = fx.color, fx.dumbbell
				break
			end
		end
		for _, gone in recentGone do
			if (gone.pos - pos).Magnitude < 1.2 then
				color, dumbbell = gone.color, gone.dumbbell
				break
			end
		end
		if dumbbell then
			grow = 1.6
			count = math.max(count, 4) -- the fuller pickup sound
			dumbbellPicked(pos, color)
		end
		Orbs.fly({
			from = pos + Vector3.new(0, 0.25, 0),
			target = root,
			color = color,
			variant = "Ball",
			size = 1.3 * grow,
			endSize = 0.25 * grow,
			duration = 0.25 + math.random() * 0.15,
			delay = (i - 1) * 0.035,
			arc = 1.5,
			accel = true,
			trail = true,
			onDone = function()
				Orbs.sparkle(root.Position, color, if count >= 2 then 3 + math.min(count, 8) else 3, 0.5 + (grow - 1))
				if count >= 2 then
					Orbs.ring(root.Position - Vector3.new(0, 2.5, 0), color, 1.6 + grow, 0.35, 0.35)
				end
				pickupBlip(count)
			end,
		})
	end
end

-- Frame loop ----------------------------------------------------------------------------

local moveParts: { BasePart } = {}
local moveCFrames: { CFrame } = {}

-- Queues one orb's ball, glow shell and mesh pieces at `cf` with squash (sx, sy) and scale `s`.
-- `flashed`: the merge flash was active this frame (its last frame restores the colour).
local function drawOrb(fx: OrbFx, cf: CFrame, s: number, sx: number, sy: number, clock: number, flashed: boolean)
	local part = fx.part
	table.insert(moveParts, part)
	table.insert(moveCFrames, cf)
	table.insert(moveParts, fx.shell)
	table.insert(moveCFrames, cf)
	fx.mesh.Scale = Vector3.new(s * sx, s * sy, s * sx)
	local gs = s * (1 + math.sin(clock * 1.6 + fx.phase) * 0.08)
	fx.shellMesh.Scale = Vector3.new(gs * sx, gs * sy, gs * sx)

	local ball = fx.ball
	if flashed then
		local lit = fx.color:Lerp(WHITE, fx.flash * 0.6)
		part.Color = lit
		if ball then
			ball.Color = lit
		end
	end
	-- Blender ball and its highlight: same transform, sized from the orb's diameter.
	if ball then
		local d = part.Size.Y * s
		local size = Vector3.new(d * sx, d * sy, d * sx)
		if (ball.Size - size).Magnitude > 0.002 then
			ball.Size = size
		end
		table.insert(moveParts, ball)
		table.insert(moveCFrames, cf)
		local shine = fx.shine
		if shine then
			local scale = Vector3.new(d * sx, d * sy, d * sx)
			local shineSize = SHINE_SIZE * scale
			if (shine.Size - shineSize).Magnitude > 0.002 then
				shine.Size = shineSize
			end
			table.insert(moveParts, shine)
			table.insert(moveCFrames, cf * CFrame.new(SHINE_OFFSET * scale))
		end
	end
end

-- Queues a dumbbell's pieces at `cf` (its centre and rotation), scaled by `s`.
local function drawDumbbell(fx: OrbFx, cf: CFrame, s: number)
	table.insert(moveParts, fx.part)
	table.insert(moveCFrames, cf)
	table.insert(moveParts, fx.shell)
	table.insert(moveCFrames, cf)
	local pieces = fx.pieces
	if not pieces then
		return
	end
	local length = fx.part.Size.X * s
	for _, piece in pieces do
		local size = Vector3.new(piece.len * length, piece.dia * length, piece.dia * length)
		if (piece.part.Size - size).Magnitude > 0.002 then
			piece.part.Size = size
		end
		table.insert(moveParts, piece.part)
		table.insert(moveCFrames, cf * CFrame.new(piece.x * length, 0, 0))
	end
end

local function step(dt: number)
	local now = os.clock()
	table.clear(moveParts)
	table.clear(moveCFrames)

	-- Flights (ghost orbs: pickups, machine VFX and rolling feed balls).
	local i = 1
	while i <= #flights do
		local f = flights[i]
		if now < f.t0 then
			i += 1
			continue
		end
		local g = f.ghost
		if not f.started then
			f.started = true
			g.active = f.variant
			g.part.Transparency = if f.variant then 1 else 0
			g.trail.Enabled = f.trail
		end
		local t = math.clamp((now - f.t0) / f.dur, 0, 1)
		local pos: Vector3
		local rot = CFrame.identity
		local roll = f.roll
		if roll then
			local p, phase = sampleRoll(roll, now - roll.t0)
			spinRoll(roll, p)
			pos, rot = p, roll.rot
			if phase >= PHASE_DONE then
				t = 1
			end
		else
			local k = if f.accel then t * t * t else t * t * (3 - 2 * t)
			local to = f.to
			if f.target then
				if f.target.Parent then
					to = f.target.Position + f.targetOffset
					f.to = to
				end
				-- Bend the curve toward the moving target.
				f.ctrl = arcControl(f.from, to, 1.5)
			end
			pos = bezier(f.from, f.ctrl, to, k)
		end
		local s = f.s0 + (f.s1 - f.s0) * t
		if roll then
			-- Feed balls pop out of the unit, then hold their size.
			s *= backOut(math.clamp((now - roll.t0) / APPEAR_TIME, 0, 1))
		end
		g.mesh.Scale = Vector3.new(s, s, s)
		local cf = CFrame.new(pos) * rot
		table.insert(moveParts, g.part)
		table.insert(moveCFrames, cf)
		local active = g.active
		if active then
			local ball = g.balls[active]
			ball.Size = g.part.Size * s
			table.insert(moveParts, ball)
			table.insert(moveCFrames, cf)
		end
		if t >= 1 then
			flights[i] = flights[#flights]
			flights[#flights] = nil
			releaseGhost(g)
			if f.onDone then
				task.spawn(f.onDone)
			end
		else
			i += 1
		end
	end

	-- Real orbs: rolling in, or resting (bob, breathe, pulse, squash).
	local clock = now
	local upright = 1 - math.exp(-dt * 4)
	for _, fx in orbs do
		if fx.still then
			continue -- resting and placed: costs nothing until a pop, squash or flash wakes it
		end
		if fx.pulse > 0.001 then
			fx.pulse *= math.exp(-dt * 7)
		else
			fx.pulse = 0
		end
		local flashed = fx.flash > 0
		if flashed then
			fx.flash = math.max(0, fx.flash - dt * 4)
		end
		local sx, sy = 1, 1
		if fx.squash >= 0 then
			fx.squash += dt
			local q = fx.squash
			if q > 0.5 then
				fx.squash = -1
			else
				local wobble = math.sin(q * 26) * math.exp(-q * 8) * fx.squashAmp
				sx, sy = 1 + wobble, 1 - wobble
			end
		end

		local roll = fx.roll
		if roll then
			local t = now - roll.t0
			if t < 0 then
				continue -- still queued for the chute (hidden)
			end
			if fx.waiting then
				fx.waiting = false
				refreshVisibility(fx)
			end
			local pos, phase = sampleRoll(roll, t)
			if not fx.dumbbell then
				spinRoll(roll, pos)
			end
			if phase ~= roll.phase then
				if phase >= PHASE_GUTTER and roll.phase < PHASE_GUTTER then
					fx.squash, fx.squashAmp = 0, 0.1 + 0.15 * roll.gutterImpact -- lands in the gutter
				end
				if phase >= PHASE_FLOOR and roll.phase < PHASE_FLOOR then
					touchedFloor(fx, pos, roll.impact)
				end
				roll.phase = phase
			end
			if fx.dumbbell then
				if fx.grow >= 0 then
					fx.grow += dt / DUMBBELL_GROW
				end
				local k = dumbbellScale(fx)
				local plate, orbR = dumbbellRadii(fx, k)
				local lifted = pos + Vector3.new(0, plate - orbR, 0)
				local rot = rollDumbbell(fx, lifted, plate, dt)
				if phase < PHASE_DONE then
					local grow = backOut(math.clamp(t / APPEAR_TIME, 0, 1))
					drawDumbbell(fx, CFrame.new(lifted) * rot, fx.scale * grow * k * sx)
					continue
				end
				roll.rot = rot
			elseif phase < PHASE_DONE then
				local grow = backOut(math.clamp(t / APPEAR_TIME, 0, 1))
				drawOrb(fx, CFrame.new(pos) * roll.rot, fx.scale * grow, sx, sy, clock, flashed)
				continue
			end
			fx.rot = roll.rot
			fx.roll = nil
			finishRoll()
			settled(fx)
		end

		-- Resting: ease to its resting turn, then hold still at its pile spot.
		fx.rot = fx.rot:Lerp(fx.restRot, upright)
		if fx.rest < 1 then
			fx.rest = math.min(1, fx.rest + dt / 0.8)
			if fx.rest >= 1 then
				fx.rot = fx.restRot
			end
		end
		local appear = 1
		if fx.appear < 1 then
			fx.appear = math.min(1, fx.appear + dt / 0.3)
			appear = backOut(fx.appear)
		end
		local s = fx.scale * (1 + fx.pulse) * appear
		if fx.dumbbell then
			-- Resting prize: finishes pumping up, sways slowly, breathes, glows and twinkles.
			-- Never marked still (there are only ever a few).
			if fx.grow < 1 then
				fx.grow = math.min(1, fx.grow + dt / DUMBBELL_GROW)
			end
			local k = dumbbellScale(fx)
			local full = dumbbellRadii(fx, 1)
			local pos = fx.home.Position + Vector3.new(0, full * (k - 1), 0)
			local sway = CFrame.Angles(0, math.sin(clock * 0.9 + fx.phase) * 0.12, 0)
			local breathe = 1 + math.sin(clock * 2 + fx.phase) * 0.015
			drawDumbbell(fx, CFrame.new(pos) * sway * fx.rot, s * k * breathe * sx)
			if fx.light then
				fx.light.Brightness = 1.2 + 0.5 * math.sin(clock * 2.4 + fx.phase)
			end
			fx.twinkle -= dt
			if fx.twinkle <= 0 and appear >= 1 then
				fx.twinkle = 0.7 + math.random() * 0.6
				local along = (math.random() * 2 - 1) * full * 1.3
				local glint = pos + (sway * fx.rot).XVector * along + Vector3.new(0, full * 0.8, 0)
				Orbs.sparkle(glint, fx.color:Lerp(WHITE, 0.4), 1, 0.25)
			end
			continue
		end
		drawOrb(fx, CFrame.new(fx.home.Position) * fx.rot, s, sx, sy, clock, flashed)
		fx.still = fx.rest >= 1 and fx.appear >= 1 and fx.pulse == 0 and fx.squash < 0 and fx.flash <= 0
	end

	if #moveParts > 0 then
		Workspace:BulkMoveTo(moveParts, moveCFrames, Enum.BulkMoveMode.FireCFrameChanged)
	end
end

-- Plot discovery --------------------------------------------------------------------------

local function plotOrbFolder(): Instance?
	local data = State.data
	if not data or not data.plotIndex then
		return nil
	end
	local map = Workspace:FindFirstChild("Map")
	local plot = map and map:FindFirstChild("Plot" .. tostring(data.plotIndex))
	return plot and plot:FindFirstChild("Orbs")
end

local started = false

function Orbs.init()
	if started then
		return
	end
	started = true
	folder = Workspace:FindFirstChild("ClientFx") :: Folder?
		or (function()
			local f = Instance.new("Folder")
			f.Name = "ClientFx"
			f.Parent = Workspace
			return f
		end)()
	Orbs.folder = folder

	RunService.Heartbeat:Connect(step)

	local function refresh()
		local f = plotOrbFolder()
		if f then
			bindFolder(f)
		end
	end
	State.changed.Event:Connect(refresh)
	refresh()

	Net.event("Effect").OnClientEvent:Connect(function(kind, data)
		if kind == "OrbsPicked" then
			onPicked(data)
		end
	end)
end

return Orbs
