--[[
	Fx.Shelf: client-side juice for the player's own unit rack.

	- Arrival: unit models that appear in Plot.Units with a fresh "Spawned"
	  attribute pop out of a sparkle puff just in front of their shelf and hop
	  back onto their spot (the arc stays under the board above), growing from
	  tiny with a back-eased scale, bounce (uniform squash), then hit a power
	  pose. Units with nothing above them fall in from above instead. Soft dust
	  ring, sparkles and a "BuyPop" (a few per batch) on landing. Units bound
	  for a shelf that is still unfolding wait until its board is in place.
	- Rack rows (every plot near the camera): a shelf the server reveals (a
	  "RackRow" model arriving in the plot folder) unfolds: its posts and back
	  panel grow up from the shelf below, the board, band and rim slide in from
	  the front with a soft bounce, then a few stars. A shelf that is no longer
	  needed folds away (a local copy plays it backwards), and the roof + sign
	  ("RackTopper") glides to its new height instead of jumping. Shelves
	  already shown when the player joins just exist.
	- Overflow ("Merge" effect with overflow = true, the rack was full): the
	  consumed units' spots pulse, their aura flies together into one light
	  fusion and a short "FULL! AUTO-MERGED xN" float rises there (at most one
	  float per second; merges in between add to the next one).
	- Merge ("Merge" effect): aura soul orbs rise from every consumed unit
	  and snap into the target (0.1 s, "MergeCharge"; auto merges 0.5 s), then a soft
	  tier-tinted puff, an eased ring, a particle burst, "MergeBoom" and a
	  gentle camera punch. Auto merges get a lighter, quieter version. A unit
	  spawning at the merge target lands exactly on the impact.
	- Batched merges ("count"/"summary"): an escalating cascade of soft pops
	  rising in pitch, then a wide ring, palette confetti and an "xN MERGES!"
	  float. Chained step merges show the running total when the chain ends.
	- Shelf glow: every unit stands on a soft tier-coloured disc (sized to fit
	  the shelf; positions refreshed round-robin, not every frame); the best
	  (highest tier) unit gets a hero treatment: a slowly turning ring of
	  tiles, a faint colour haze, rising sparkles and a proud idle
	  (Animator.setHero). The own plot is handed to Animator.setOwnPlot so its
	  units get the bigger posing budget.
	- Rarity and standing (rules and numbers in Fx.PlotRank): every disc sits in
	  a ring of its rarity band's colour, fainter for Common and solid neon for
	  Legendary and Mythic (the champion has its pedestal's glow instead), and
	  front-shelf units from Epic up breathe a few sparkles. Units of the two
	  best tiers are drawn up to 1.3x where the board above leaves room and
	  never bigger than the champion; low tiers behind the front shelf shrink
	  to 0.85x. A few units are resized per frame (Animator.hold / release).
	- Champion: the unit in slot 1 is shown on Fx.PlotRank's stage in front of
	  its shelf pedestal (PlotRank.championPivot), 1.4x big (1.55x at tier 25),
	  where no board is above it; it lands there when it arrives.
	- Merge impact (the MERGE table): at the result unit, gold rings that face
	  the camera, a gold spark burst and flash, the unit pops in with an
	  overshoot, a "+TIER n" chip floats over it and the camera punches (with a
	  short white screen pulse). Lighter for auto merges; bigger, with "NEW
	  BEST!", a gold column and confetti, when the merge makes a new best tier.

	Effects are painted, not glowing: SmoothPlastic parts in tier or palette
	colours with eased fades, low particle light emission and no lights. Only
	the soul orbs (aura) and the top bands' rarity rings use Neon.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Economy = require(Shared:WaitForChild("Economy"))
local Net = require(Shared:WaitForChild("Net"))
local Theme = require(ReplicatedStorage:WaitForChild("Theme"))

local Client = script.Parent.Parent
local Animator = require(Client.Animator)
local Sounds = require(Client.Sounds)
local State = require(Client.State)
local Budget = require(script.Parent.Budget)
local Sprites = require(script.Parent.Sprites)
local Camera = require(script.Parent.Camera)
local Orbs = require(script.Parent.Orbs)
local PlotRank = require(script.Parent.PlotRank)

local Shelf = {}

local SPARKLE = "rbxasset://textures/particles/sparkles_main.dds"
-- The merge's sparks: the Blender sparkle sprite, the built-in one without it.
local SPARK_SPRITE = Sprites.image("Sparkle") or SPARKLE
local SMOKE = "rbxasset://textures/particles/smoke_main.dds"
local WHITE = Color3.new(1, 1, 1)

local function worldColor(key: string, fallback: Color3): Color3
	local palette = (Theme :: any).World
	return if palette and palette[key] then palette[key] else fallback
end

local DUST = worldColor("Cream", Color3.fromRGB(255, 247, 232))
local DUST_SHADE = worldColor("SandDark", Color3.fromRGB(232, 204, 150))
local CONFETTI = {
	worldColor("Sunny", WHITE),
	worldColor("Pink", WHITE),
	worldColor("Blue", WHITE),
	worldColor("Mint", WHITE),
	worldColor("Coral", WHITE),
}
-- Particle light emission: sparkles read on a bright day without blooming.
local SPARKLE_EMISSION = 0.25

local FRESH = 2 -- seconds: a unit spawned this recently gets the drop-in
local DECIDE_DELAY = 0.08 -- wait for a matching Merge effect before dropping
local DROP_HEIGHT = 7 -- fall height for a unit with nothing above it
local FALL = 0.34
local HOP = 0.42 -- hop from the front onto a shelf
local HOP_FORWARD = 3.2 -- studs in front of the spot the hop starts
local HOP_PEAK = 1.4 -- highest hop arc (less when the board above is close)
local SETTLE = 0.45
local STAGGER = 0.04
local START_SCALE = 0.05
local POP_LIMIT = 4 -- BuyPop sounds per POP_WINDOW
local POP_WINDOW = 0.4
local CHARGE = 0.1 -- merge orb flight: a snap, so the impact is on screen 0.1 s after the merge
local CHARGE_AUTO = 0.5
local MERGE_STAGGER = 0.2 -- chained merge steps play one after another
local CHEST_HEIGHT = 3 -- impact point above the target's feet
local NEAR_PLOT = 120 -- camera punch only if the player is this close
local PUNCH_SCALE = 0.6 -- keeps camera punches and shakes gentle

-- Merge impact at the result unit: every size, colour, duration and count of it. Three kinds:
-- "auto" (the Auto Merge pass and a full rack's forced merges), "manual" (the Merge pad) and
-- "best" (the merge made a new best tier).
--   ring      a gold ring that always faces the camera: from / to size in studs
--   rings     how many, RingGap seconds apart, each RingGrow times wider than the last
--   sparks    gold spark burst: count (through Fx.Budget), particle size
--   flash     diameter a neon gold ball swells to at the unit's chest
--   pop       how far the result unit overshoots its size as it pops in (0.4 = 40 %)
--   chip      the "+TIER n" chip over the unit: size in studs, seconds it stays
--   punch     Camera.punch intensity (FOV kick of 5 degrees per 1.0, plus a small shake)
--   pulse     transparency of the white screen pulse (1 = none)
local MERGE = {
	Gold = Color3.fromRGB(255, 200, 48),
	GoldLight = Color3.fromRGB(255, 240, 170),
	Ink = Color3.fromRGB(34, 22, 64),
	Kinds = {
		auto = {
			ring = { 3, 10 },
			ringTime = 0.5,
			rings = 1,
			sparks = 12,
			sparkSize = 3.6,
			flash = 3.5,
			pop = 0.22,
			chip = Vector2.new(8, 2.3),
			chipLife = 1.1,
			punch = 0,
			pulse = 1,
		},
		-- A plain merge: lands 0.1 s after the effect and stays big until about 0.9 s, so any
		-- frame from 0.12 to 0.48 s catches the ring, the sparks and (first) the white pulse.
		manual = {
			ring = { 6, 22 },
			ringTime = 0.9,
			rings = 2,
			sparks = 40,
			sparkSize = 9,
			flash = 7,
			pop = 0.42,
			chip = Vector2.new(13, 3.6),
			chipLife = 1.6,
			punch = 0.8,
			pulse = 0.86,
		},
		best = {
			ring = { 5, 30 },
			ringTime = 0.9,
			rings = 3,
			sparks = 60,
			sparkSize = 10,
			flash = 8,
			pop = 0.6,
			chip = Vector2.new(17, 6.2),
			chipLife = 2.2,
			punch = 1.5,
			pulse = 0.88,
		},
	},
	-- The ring's line in pixels: at first, as it fades (r4: 12 -> 3 read as a thin outline),
	-- and its soft gold fill's transparency as it starts (it fades out with the line).
	RingStroke = { 20, 8 },
	RingFill = 0.82,
	-- The rings are drawn in the world (not on top), this many studs towards the camera from
	-- the unit, so the "+TIER n" chip (always on top) is never under a ring: measured in Studio
	-- (r5), both on top, the 22-stud ring crossed the chip although it stood 1 stud further.
	RingForward = 3,
	RingGap = 0.13,
	RingGrow = 1.25,
	SparkSpeed = NumberRange.new(12, 26),
	SparkLife = NumberRange.new(0.6, 1.1),
	-- Sparks: the Blender sparkle sprite (the built-in sparkles_main is a faint thin cross:
	-- measured 53-62 px across at 3.2 studs and still unseen in r4), lit, 3x the r4 size.
	SparkEmission = 0.7,
	-- The neon ball and the white screen pulse are kept light: at 0.1 and 0.6 (a 40% white
	-- sheet held 2 frames) they lifted the whole frame's mean by 10 levels and hid the sparks.
	FlashTime = 0.3,
	FlashAlpha = 0.5, -- the neon ball's transparency as it starts
	PopTime = 0.6, -- seconds of the result unit's overshoot
	ChipAbove = 7.4, -- studs over the unit's feet the chip appears when the unit is not found ...
	ChipRise = 2.2, -- ... and how far it floats up
	ChipGap = 0.8, -- studs between the unit's top and the chip's bottom edge
	ChipClearPx = 10, -- on screen too: the chip's bottom edge this many px over the unit's head
	ChipSide = 1.5, -- studs aside (camera right) when the top HUD pushes the chip down
	ChipFade = 0.35,
	-- A chip that would cover one still on screen (a double merge: measured in Studio, the
	-- "+TIER 2" and "+TIER 4" chips of a 3+3 / 1+1 merge overlapped by 175 x 31 px) stacks
	-- above it with this gap, and pops this much later per chip under it.
	-- Under the top HUD (no room above) it stacks below the other chip instead (r5: it stepped
	-- 354 px aside, away from its own unit).
	ChipStackPx = 10,
	ChipStagger = 0.2,
	AutoChipGap = 0.6, -- seconds between the chips of auto merges
	PulseHold = 0, -- seconds the white pulse holds at full strength (0: one frame) ...
	PulseTime = 0.08, -- ... and fades over
	-- A new best tier: a gold column of light over the unit for a moment.
	BestBeam = { Height = 70, Width = 8, Time = 1.4 },
	BestDelay = 4, -- seconds a new best tier takes to stop being news
}

local fxFolder: Folder? = nil
local started = false

-- Helpers --------------------------------------------------------------------------

local function folder(): Folder
	if fxFolder and fxFolder.Parent then
		return fxFolder
	end
	local f = Instance.new("Folder")
	f.Name = "ShelfFx"
	f.Parent = Workspace
	fxFolder = f
	return f
end

local function fxPart(shape: Enum.PartType, size: Vector3, cf: CFrame, color: Color3, transparency: number?, material: Enum.Material?): Part
	local p = Instance.new("Part")
	p.Shape = shape
	p.Size = size
	p.CFrame = cf
	p.Color = color
	p.Material = material or Enum.Material.SmoothPlastic
	p.Transparency = transparency or 0
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Parent = folder()
	return p
end

local function tween(inst: Instance, time: number, props: { [string]: any }, style: Enum.EasingStyle?, dir: Enum.EasingDirection?)
	local t = TweenService:Create(inst, TweenInfo.new(time, style or Enum.EasingStyle.Quad, dir or Enum.EasingDirection.Out), props)
	t:Play()
	return t
end

local function cleanup(inst: Instance, after: number)
	task.delay(after, function()
		inst:Destroy()
	end)
end

local function tierColor(tier: number): Color3
	local entry = Theme.Tiers[math.clamp(tier, 1, #Theme.Tiers)]
	local rarity = Theme.Colors.Rarity[Economy.tierBand(tier)] or WHITE
	local aura = entry and entry.Look.aura
	if aura then
		return aura:Lerp(rarity, 0.35)
	end
	return rarity
end

-- One-shot particle burst at `pos`; returns after scheduling cleanup.
local function burst(
	pos: Vector3,
	color: Color3,
	count: number,
	opts: {
		texture: string?,
		speed: NumberRange?,
		size: number?,
		life: NumberRange?,
		spread: number?,
		gravity: number?,
		drag: number?,
		emission: number?,
	}?
)
	local o = opts or {}
	local holder = fxPart(Enum.PartType.Block, Vector3.one * 0.2, CFrame.new(pos), color, 1)
	local emitter = Instance.new("ParticleEmitter")
	emitter.Texture = o.texture or SPARKLE
	emitter.Color = ColorSequence.new(WHITE, color)
	emitter.LightEmission = o.emission or (if o.texture == SMOKE then 0 else SPARKLE_EMISSION)
	local size = o.size or 0.8
	emitter.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, size),
		NumberSequenceKeypoint.new(1, 0),
	})
	emitter.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, if o.texture == SMOKE then 0.45 else 0),
		NumberSequenceKeypoint.new(1, 1),
	})
	emitter.Lifetime = o.life or NumberRange.new(0.4, 0.8)
	emitter.Speed = o.speed or NumberRange.new(8, 16)
	local spread = o.spread or 180
	emitter.SpreadAngle = Vector2.new(spread, spread)
	emitter.Acceleration = Vector3.new(0, -(o.gravity or 10), 0)
	emitter.Drag = o.drag or 3
	emitter.RotSpeed = NumberRange.new(-180, 180)
	emitter.Rotation = NumberRange.new(0, 360)
	emitter.Rate = 0
	emitter.Parent = holder
	emitter:Emit(count)
	cleanup(holder, 2)
end

-- Flat expanding ring (shockwave / dust ring), eased out as it fades.
local function ring(pos: Vector3, color: Color3, fromSize: number, toSize: number, time: number, transparency: number)
	local cf = CFrame.new(pos) * CFrame.Angles(0, 0, math.pi / 2)
	local part = fxPart(Enum.PartType.Cylinder, Vector3.new(0.12, fromSize, fromSize), cf, color, transparency)
	tween(part, time, { Size = Vector3.new(0.05, toSize, toSize), Transparency = 1 }, Enum.EasingStyle.Quad)
	cleanup(part, time + 0.05)
end

-- Soft painted puff: a translucent ball that swells and fades (no light, no glow).
local function puff(pos: Vector3, color: Color3, fromSize: number, toSize: number, time: number, transparency: number)
	local part = fxPart(Enum.PartType.Ball, Vector3.one * fromSize, CFrame.new(pos), color, transparency)
	tween(part, time, { Size = Vector3.one * toSize, Transparency = 1 }, Enum.EasingStyle.Quad)
	cleanup(part, time + 0.05)
end

-- Back-eased 0..1 with an overshoot of `overshoot` (default 1.9, ~10 % past the end).
local function backOut(x: number, overshoot: number?): number
	local c1 = overshoot or 1.9
	local c3 = c1 + 1
	local y = x - 1
	return 1 + c3 * y * y * y + c1 * y * y
end

local function easeInOut(x: number): number
	return if x < 0.5 then 4 * x * x * x else 1 - (-2 * x + 2) ^ 3 / 2
end

local function ownPlot(): Instance?
	local data = State.data
	local map = Workspace:FindFirstChild("Map")
	if not data or not map or not data.plotIndex then
		return nil
	end
	return map:FindFirstChild("Plot" .. data.plotIndex)
end

local function playerNear(pos: Vector3, range: number): boolean
	local character = Players.LocalPlayer.Character
	local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	return root ~= nil and (root.Position - pos).Magnitude <= range
end

-- Frame loop for the custom animations (one connection for everything) --------------

type Job = (now: number) -> boolean -- returns true when finished
local jobs: { Job } = {}

local function addJob(job: Job)
	table.insert(jobs, job)
end

local function runJobs()
	if #jobs == 0 then
		return
	end
	local now = os.clock()
	local i = 1
	while i <= #jobs do
		local ok, done = pcall(jobs[i], now)
		if not ok or done then
			table.remove(jobs, i)
		else
			i += 1
		end
	end
end

-- Rack rows: shelves unfold / fold away, the roof glides -----------------------------

local ROW_FRESH = 1.2 -- a RackRow arriving this soon after "Rows" changed is a reveal
local ROW_NEAR = 260 -- only racks this close to the camera animate
local ROW_READY = 0.62 -- seconds into a reveal when the board has landed
local BOARD_SLIDE = 4 -- studs in front of its place a revealed board starts
local TOPPER_TIME = 0.5

type PartAnim = {
	part: BasePart,
	cf: CFrame, -- final (server) CFrame
	size: Vector3,
	transparency: number,
	kind: string, -- "grow" (up from its bottom), "slide" (in from the front) or "pop"
	delay: number,
	time: number,
}

type Rack = {
	folder: Instance,
	conns: { RBXScriptConnection },
	rows: number,
	rowsChangedAt: number,
	shownPivot: CFrame?, -- where the roof is drawn right now
	glide: number, -- token of the running roof glide
}

local racks: { [Instance]: Rack } = {}
-- The own plot folder whose units this module animates (set by watchPlot).
local watched: Instance? = nil
-- What the player's rack looks like on joining just exists: no shelf unfolds and no unit
-- hops in until this long after the own plot is first known.
local JOIN_SETTLE = 3
local settledAt = math.huge

local function settled(): boolean
	return os.clock() >= settledAt
end
-- Final CFrames of parts that are mid-animation (board look-ups use these).
local finals: { [BasePart]: CFrame } = setmetatable({}, { __mode = "k" }) :: any
-- Shelves still unfolding: units bound for them wait for the board.
type Reveal = { plot: Instance, minY: number, maxY: number, readyAt: number }
local reveals: { Reveal } = {}

local function cameraNear(pos: Vector3, range: number): boolean
	local camera = Workspace.CurrentCamera
	return camera ~= nil and (camera.CFrame.Position - pos).Magnitude <= range
end

-- How a rack part animates: posts and back panel grow, board pieces slide, the rest pops.
local function partAnim(part: BasePart, reveal: boolean): PartAnim
	local name = part.Name
	local kind, delay, time
	if name == "RackPost" then
		kind, delay, time = "grow", 0, 0.38
	elseif name == "ShelfBack" or name == "ShelfBackRear" then
		kind, delay, time = "grow", 0.12, 0.38
	elseif name == "ShelfBoard" or name == "ShelfBand" or name == "ShelfRim" then
		kind, delay, time = "slide", 0.22, 0.42
	elseif name == "RackKnob" then
		kind, delay, time = "pop", 0.02, 0.3
	else
		kind, delay, time = "pop", 0.5, 0.3
	end
	if not reveal then
		-- Folding plays the same moves backwards, top pieces first.
		if kind == "slide" then
			delay, time = 0, 0.28
		elseif name == "ShelfBack" or name == "ShelfBackRear" then
			delay, time = 0.1, 0.3
		elseif kind == "grow" then
			delay, time = 0.16, 0.32
		else
			delay, time = 0, 0.2
		end
	end
	return {
		part = part,
		cf = part.CFrame,
		size = part.Size,
		transparency = part.Transparency,
		kind = kind,
		delay = delay,
		time = time,
	}
end

-- Places one animated part at progress `e` (0 = folded away, 1 = in place; may overshoot).
local function placePart(a: PartAnim, e: number, front: Vector3)
	local part = a.part
	if a.kind == "grow" then
		local h = math.max(a.size.Y * math.clamp(e, 0, 1), 0.05)
		part.Size = Vector3.new(a.size.X, h, a.size.Z)
		part.CFrame = a.cf * CFrame.new(0, (h - a.size.Y) / 2, 0)
	elseif a.kind == "slide" then
		part.CFrame = a.cf + front * (BOARD_SLIDE * (1 - e))
		part.Transparency = a.transparency + (1 - a.transparency) * (1 - math.clamp(e * 3, 0, 1))
	else
		local s = math.max(e, 0.02)
		part.Size = a.size * s
		part.CFrame = a.cf
	end
end

-- The direction out of the rack's front (toward the entrance) for a row model.
local function rowFront(model: Instance): Vector3
	local board = model:FindFirstChild("ShelfBoard")
	if board and board:IsA("BasePart") then
		return board.CFrame.LookVector
	end
	return Vector3.new(0, 0, -1)
end

local function collectParts(model: Instance, reveal: boolean): { PartAnim }
	local anims: { PartAnim } = {}
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then
			table.insert(anims, partAnim(d, reveal))
		end
	end
	return anims
end

local function revealRow(model: Model, plot: Instance)
	local anims = collectParts(model, true)
	if #anims == 0 then
		return
	end
	local front = rowFront(model)
	local boardTop = -math.huge
	for _, a in anims do
		finals[a.part] = a.cf
		placePart(a, 0, front)
		if a.part.Name == "ShelfBoard" then
			boardTop = a.cf.Position.Y + a.size.Y / 2
		end
	end
	local start = os.clock()
	local reveal: Reveal? = nil
	if boardTop > -math.huge then
		reveal = { plot = plot, minY = boardTop - 0.6, maxY = boardTop + 2, readyAt = start + ROW_READY }
		table.insert(reveals, reveal :: Reveal)
	end
	local starsDone = false
	addJob(function(now: number): boolean
		local t = now - start
		local finished = true
		for _, a in anims do
			if not a.part.Parent then
				continue
			end
			local p = math.clamp((t - a.delay) / a.time, 0, 1)
			local e = if a.kind == "slide" then backOut(p, 1.6) elseif a.kind == "pop" then backOut(p) else 1 - (1 - p) ^ 2
			placePart(a, e, front)
			if p < 1 then
				finished = false
			end
		end
		if not starsDone and t >= ROW_READY - 0.05 then
			starsDone = true
			for _, a in anims do
				if a.part.Name == "ShelfBoard" then
					local half = a.size.X * 0.32
					for k = -1, 1 do
						local pos = (a.cf * CFrame.new(k * half, a.size.Y / 2 + 0.6, 0)).Position
						burst(pos, CONFETTI[(k + 2) % #CONFETTI + 1], 6, {
							speed = NumberRange.new(3, 7),
							size = 0.7,
							life = NumberRange.new(0.5, 0.9),
							gravity = 4,
						})
					end
					ring(a.cf.Position + Vector3.new(0, a.size.Y / 2 + 0.1, 0), WHITE, 2, 9, 0.4, 0.5)
				end
			end
			if plot == ownPlot() then
				Sounds.play("BuyPop", 0.05, 0.75)
			end
		end
		if finished then
			for _, a in anims do
				finals[a.part] = nil
			end
			if reveal then
				local index = table.find(reveals, reveal)
				if index then
					table.remove(reveals, index)
				end
			end
		end
		return finished
	end)
end

-- Plays the fold on a local copy of a shelf the server just took away.
local function foldRow(copy: Model)
	copy.Parent = folder()
	local anims = collectParts(copy, false)
	local front = rowFront(copy)
	for _, a in anims do
		a.part.Anchored = true
		a.part.CanCollide = false
		a.part.CanQuery = false
		a.part.CanTouch = false
	end
	local start = os.clock()
	addJob(function(now: number): boolean
		if not copy.Parent then
			return true
		end
		local t = now - start
		local finished = true
		for _, a in anims do
			local p = math.clamp((t - a.delay) / a.time, 0, 1)
			placePart(a, 1 - p * p, front)
			if p < 1 then
				finished = false
			end
		end
		if finished then
			copy:Destroy()
		end
		return finished
	end)
end

-- Glides the roof + sign from where it is drawn to where the server just put it.
local function glideTopper(rack: Rack)
	local topper = rack.folder:FindFirstChild("RackTopper")
	if not topper or not topper:IsA("Model") then
		return
	end
	rack.glide += 1
	local token = rack.glide
	local target = topper:GetPivot()
	local from = rack.shownPivot
	rack.shownPivot = target
	if not from or not settled() or (from.Position - target.Position).Magnitude < 0.05 or not cameraNear(target.Position, ROW_NEAR) then
		return
	end
	local parts: { BasePart } = {}
	local offsets: { CFrame } = {}
	local cframes: { CFrame } = {}
	for _, d in topper:GetDescendants() do
		if d:IsA("BasePart") then
			table.insert(parts, d)
			table.insert(offsets, target:ToObjectSpace(d.CFrame))
		end
	end
	local rising = target.Position.Y > from.Position.Y
	local start = os.clock()
	local function placeAt(pivot: CFrame)
		for i, offset in offsets do
			cframes[i] = pivot * offset
		end
		Workspace:BulkMoveTo(parts, cframes, Enum.BulkMoveMode.FireCFrameChanged)
	end
	placeAt(from)
	addJob(function(now: number): boolean
		if rack.glide ~= token then
			return true
		end
		local p = math.clamp((now - start) / TOPPER_TIME, 0, 1)
		local e = if rising then backOut(p, 1.2) else 1 - (1 - p) ^ 2
		local pivot = from:Lerp(target, e)
		rack.shownPivot = pivot
		placeAt(pivot)
		if p >= 1 then
			rack.shownPivot = target
			return true
		end
		return false
	end)
end

local function bindRack(plot: Instance)
	if racks[plot] then
		return
	end
	local topper = plot:FindFirstChild("RackTopper")
	local rowsValue = plot:GetAttribute("Rows")
	local rack: Rack = {
		folder = plot,
		conns = {},
		rows = if type(rowsValue) == "number" then rowsValue else 1,
		rowsChangedAt = -math.huge,
		shownPivot = if topper and topper:IsA("Model") then topper:GetPivot() else nil,
		glide = 0,
	}
	racks[plot] = rack
	table.insert(
		rack.conns,
		plot:GetAttributeChangedSignal("Rows"):Connect(function()
			local value = plot:GetAttribute("Rows")
			rack.rows = if type(value) == "number" then value else rack.rows
			rack.rowsChangedAt = os.clock()
			glideTopper(rack)
		end)
	)
	table.insert(
		rack.conns,
		plot.ChildAdded:Connect(function(child)
			if child.Name == "RackTopper" and child:IsA("Model") then
				rack.shownPivot = child:GetPivot()
				return
			end
			if child.Name ~= "RackRow" or not child:IsA("Model") then
				return
			end
			local row = child:GetAttribute("Row")
			local value = plot:GetAttribute("Rows")
			local rows = if type(value) == "number" then value else 1
			-- New if "Rows" has not caught up yet or just changed (a row streaming back in
			-- with no change to "Rows" just appears).
			local fresh = (type(row) == "number" and row > rows) or os.clock() - rack.rowsChangedAt < ROW_FRESH
			if fresh and settled() and cameraNear(child:GetPivot().Position, ROW_NEAR) then
				revealRow(child, plot)
			end
		end)
	)
	table.insert(
		rack.conns,
		plot.ChildRemoved:Connect(function(child)
			if child.Name ~= "RackRow" or not child:IsA("Model") then
				return
			end
			local row = child:GetAttribute("Row")
			if type(row) ~= "number" or not settled() or not cameraNear(child:GetPivot().Position, ROW_NEAR) then
				return
			end
			-- Copy it now, while its parts are still here; play the fold if the rack shrank.
			child.Archivable = true
			local ok, copy = pcall(child.Clone, child)
			if not ok or not copy then
				return
			end
			task.defer(function()
				local value = plot:GetAttribute("Rows")
				local rows = if type(value) == "number" then value else 1
				if row > rows or os.clock() - rack.rowsChangedAt < ROW_FRESH then
					foldRow(copy :: Model)
				else
					copy:Destroy()
				end
			end)
		end)
	)
end

local function bindRacks()
	local map = Workspace:FindFirstChild("Map")
	if not map then
		return
	end
	for _, child in map:GetChildren() do
		if child.Name:match("^Plot%d+$") then
			bindRack(child)
		end
	end
	map.ChildAdded:Connect(function(child)
		if child.Name:match("^Plot%d+$") then
			bindRack(child)
		end
	end)
end

-- When a unit standing at `feet` on a shelf of `plot` may land: after its shelf unfolds.
local function rowReadyAt(plot: Instance?, feet: Vector3): number
	local ready = 0
	for _, reveal in reveals do
		if reveal.plot == plot and feet.Y >= reveal.minY and feet.Y <= reveal.maxY then
			ready = math.max(ready, reveal.readyAt)
		end
	end
	return ready
end

-- The plot's shelf boards and roof, cached briefly (a batch of arrivals shares one scan).
local boardCache: { plot: Instance?, at: number, parts: { BasePart } } = { plot = nil, at = -math.huge, parts = {} }

local function rackBoards(plot: Instance): { BasePart }
	local now = os.clock()
	if boardCache.plot == plot and now - boardCache.at < 0.1 then
		return boardCache.parts
	end
	local parts: { BasePart } = {}
	for _, child in plot:GetChildren() do
		local name = child.Name
		local part: Instance? = nil
		if name == "ShelfBoard" then
			part = child
		elseif name == "RackRow" then
			part = child:FindFirstChild("ShelfBoard")
		elseif name == "RackTopper" then
			part = child:FindFirstChild("RackRoof")
		end
		if part and part:IsA("BasePart") then
			table.insert(parts, part)
		end
	end
	boardCache.plot, boardCache.at, boardCache.parts = plot, now, parts
	return parts
end

-- Bottom (y) of the lowest shelf board or roof above `feet` that covers it, if any.
local function boardAbove(plot: Instance?, feet: Vector3): number?
	if not plot then
		return nil
	end
	local best: number? = nil
	for _, part in rackBoards(plot) do
		local cf = finals[part] or part.CFrame
		local size = part.Size
		local lp = cf:PointToObjectSpace(feet)
		if math.abs(lp.X) <= size.X / 2 and math.abs(lp.Z) <= size.Z / 2 + 0.5 then
			local bottom = cf.Position.Y - size.Y / 2
			if bottom > feet.Y + 0.5 and (best == nil or bottom < best :: number) then
				best = bottom
			end
		end
	end
	return best
end

-- Champion stage ------------------------------------------------------------------------
-- The best unit (slot 1) is shown on Fx.PlotRank's stage in front of its shelf pedestal, not
-- where the server stands it.

local function championRim(): BasePart?
	local plot = watched
	local rim = plot and plot:FindFirstChild("ChampionTop")
	return if rim and rim:IsA("BasePart") then rim else nil
end

-- Where a unit the server stands at `pos` is drawn: the stage for the champion's pedestal.
local function shownAt(pos: Vector3): Vector3
	local rim = championRim()
	if rim and (PlotRank.championHome(rim).Position - pos).Magnitude < 1 then
		return PlotRank.championPivot(rim).Position
	end
	return pos
end

-- Arrival -----------------------------------------------------------------------------

local popTimes: { number } = {}
local lastDropStart = 0

-- Pending merge impacts: a unit spawning here lands on the impact (and pops in with `pop`
-- overshoot). `pos` is where the server stands it.
type Pending = { pos: Vector3, impact: number, pop: number }
local pendingMerges: { Pending } = {}

-- 1 at both ends, swelling by `amount` on the way: the result unit's pop.
local function overshoot(q: number, amount: number): number
	return 1 + amount * math.exp(-4 * q) * math.sin(q * 9)
end

local function pop(tier: number)
	local now = os.clock()
	for i = #popTimes, 1, -1 do
		if now - popTimes[i] > POP_WINDOW then
			table.remove(popTimes, i)
		end
	end
	if #popTimes >= POP_LIMIT then
		return
	end
	table.insert(popTimes, now)
	Sounds.play("BuyPop", 0.1, 1 + #popTimes * 0.06 - math.min(tier, 25) * 0.008)
end

local function safeScale(model: Model, scale: number)
	pcall(model.ScaleTo, model, math.max(scale, 0.01))
end

local function land(target: CFrame, tier: number, quiet: boolean?)
	local feet = target.Position
	local color = tierColor(tier)
	ring(feet + Vector3.new(0, 0.15, 0), DUST, 1.5, 7, 0.4, 0.45)
	burst(feet + Vector3.new(0, 0.3, 0), DUST_SHADE, 8, {
		texture = SMOKE,
		speed = NumberRange.new(6, 9),
		size = 1.4,
		life = NumberRange.new(0.35, 0.6),
		spread = 80,
		gravity = 0,
		drag = 6,
	})
	burst(feet + Vector3.new(0, 2, 0), color, 10, { speed = NumberRange.new(4, 9), size = 0.6, gravity = 6 })
	if not quiet then
		pop(tier)
	end
end

-- Moves a unit in: `peak` = nil falls from DROP_HEIGHT above (nothing overhead); otherwise
-- it hops from HOP_FORWARD in front of its spot in an arc no higher than `peak`, so it never
-- passes through the board above. Then a squash (a merge's result pops with `popAmount`
-- overshoot instead), the landing puff and a power pose.
local function arrive(
	model: Model,
	target: CFrame,
	baseScale: number,
	startAt: number,
	tier: number,
	quiet: boolean,
	peak: number?,
	popAmount: number?
)
	local landed = false
	local puffed = false
	local flight = if peak then HOP else FALL
	local settle = if popAmount then MERGE.PopTime else SETTLE
	addJob(function(now: number): boolean
		if not model.Parent then
			Animator.release(model)
			return true
		end
		local t = now - startAt
		if t < 0 then
			return false
		end
		if t < flight then
			local p = t / flight
			if peak then
				if not puffed then
					puffed = true
					local from = (target * CFrame.new(0, 1.5, -HOP_FORWARD)).Position
					burst(from, tierColor(tier):Lerp(WHITE, 0.4), 8, { speed = NumberRange.new(2, 6), size = 0.7, gravity = 0 })
					puff(from, WHITE, 0.6, 3, 0.3, 0.4)
				end
				local ease = 1 - (1 - p) * (1 - p)
				local forward = HOP_FORWARD * (1 - ease)
				local height = 4 * peak * p * (1 - p)
				local spin = (1 - p) * math.pi * 1.2
				safeScale(model, baseScale * (START_SCALE + (1 - START_SCALE) * backOut(math.min(1, p * 1.5), 1.2)))
				model:PivotTo(target * CFrame.new(0, height, -forward) * CFrame.Angles(0, spin, 0))
			else
				local height = DROP_HEIGHT * (1 - p * p)
				local spin = (1 - p) * math.pi * 1.5
				safeScale(model, baseScale * (START_SCALE + (1 - START_SCALE) * backOut(p)))
				model:PivotTo(target * CFrame.new(0, height, 0) * CFrame.Angles(0, spin, 0))
			end
			return false
		end
		if not landed then
			landed = true
			land(target, tier, quiet)
		end
		local q = (t - flight) / settle
		if q < 1 then
			if popAmount then
				safeScale(model, baseScale * overshoot(q, popAmount))
			else
				-- Uniform squash: dip below full size, overshoot, settle.
				local wobble = -0.16 * math.exp(-5 * q) * math.cos(q * 15)
				safeScale(model, baseScale * (1 + math.min(wobble, 0.04)))
			end
			model:PivotTo(target)
			return false
		end
		safeScale(model, baseScale)
		model:PivotTo(target)
		Animator.release(model)
		Animator.show(model, if tier >= 10 then "MostMuscular" else "DoubleBiceps", 1.5, if peak then 0 else 0.5)
		return true
	end)
end

local function onUnitAdded(model: Instance)
	if not model:IsA("Model") then
		return
	end
	local spawned = model:GetAttribute("Spawned")
	if not settled() or type(spawned) ~= "number" or Workspace:GetServerTimeNow() - spawned > FRESH then
		return
	end
	if not model.PrimaryPart then
		return
	end
	local tierValue = model:GetAttribute("Tier")
	local tier = if type(tierValue) == "number" then tierValue else 1
	local target = model:GetPivot()
	-- Where the server stands it: merge impacts are matched by this spot.
	local home = target.Position
	local okScale, baseScale = pcall(model.GetScale, model)
	if not okScale or type(baseScale) ~= "number" then
		baseScale = 1
	end
	-- The champion lands on its stage, at its full size.
	local rim = championRim()
	if rim and model:GetAttribute("Slot") == 1 then
		target = PlotRank.championPivot(rim)
		baseScale = PlotRank.championScale(tier)
	end
	-- Room under the shelf board (or roof) above decides between a hop in and a drop.
	local plot = watched
	local heightValue = model:GetAttribute("Height")
	local height = if type(heightValue) == "number" then heightValue else 5
	local ceiling = boardAbove(plot, target.Position)
	local peak: number? = if ceiling then math.clamp(ceiling - (target.Position.Y + height) - 0.2, 0, HOP_PEAK) else nil
	-- Hide it right away (tiny, at the start of its move) while we decide the timing.
	Animator.hold(model)
	safeScale(model, baseScale * START_SCALE)
	model:PivotTo(if peak then target * CFrame.new(0, 0, -HOP_FORWARD) else target * CFrame.new(0, DROP_HEIGHT, 0))
	task.delay(DECIDE_DELAY, function()
		if not model.Parent then
			Animator.release(model)
			return
		end
		local now = os.clock()
		local startAt = math.max(now, lastDropStart + STAGGER, rowReadyAt(plot, target.Position))
		local quiet = false
		local popAmount: number? = nil
		local flight = if peak then HOP else FALL
		for _, pending in pendingMerges do
			if (pending.pos - home).Magnitude < 3 and pending.impact > now - 0.2 then
				startAt = math.max(now, pending.impact - flight)
				quiet = true -- the merge boom covers it
				popAmount = pending.pop
				break
			end
		end
		lastDropStart = math.max(lastDropStart, startAt)
		arrive(model, target, baseScale, startAt, tier, quiet, peak, popAmount)
	end)
end

-- Merge -------------------------------------------------------------------------------

local lastMergeAt = 0
local lastBoom = 0
local lastImpact = 0
local chainIndex = 0
local chainTotal = 0
-- The best tier the rack is known to hold (a merge past it is the "best" kind); a new best
-- unit only counts MERGE.BestDelay later, so the merge that made it is still news.
local knownBest = 0
local pendingBest = 0
local seenTop = 0 -- the highest tier any merge has made so far
local lastAutoChip = 0
-- The "+TIER n" chips on screen: where each started, when, for how long, half its size.
local liveChips: { { pos: Vector3, born: number, life: number, half: Vector2 } } = {}

-- A gold ring that always faces the camera, growing from `from` to `to` studs as it fades.
local function goldRing(pos: Vector3, from: number, to: number, time: number, delay: number)
	-- Pulled towards the camera (and shrunk to keep its screen size), drawn in the world.
	local camera = Workspace.CurrentCamera
	if camera then
		local eye = camera.CFrame.Position
		local away = (pos - eye).Magnitude
		if away > MERGE.RingForward * 2 then
			local k = (away - MERGE.RingForward) / away
			pos = eye + (pos - eye) * k
			from *= k
			to *= k
		end
	end
	local holder = fxPart(Enum.PartType.Block, Vector3.one * 0.2, CFrame.new(pos), WHITE, 1)
	holder.Name = "MergeRing"
	local gui = Instance.new("BillboardGui")
	gui.AlwaysOnTop = false
	gui.LightInfluence = 0
	gui.MaxDistance = 400
	gui.Size = UDim2.fromScale(from, from)
	gui.Enabled = delay <= 0
	gui.Parent = holder
	local circle = Instance.new("Frame")
	circle.BackgroundColor3 = MERGE.Gold
	circle.BackgroundTransparency = MERGE.RingFill
	circle.BorderSizePixel = 0
	circle.Size = UDim2.fromScale(1, 1)
	circle.Parent = gui
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0.5, 0)
	corner.Parent = circle
	local stroke = Instance.new("UIStroke")
	stroke.Color = MERGE.Gold
	stroke.Thickness = MERGE.RingStroke[1]
	stroke.Parent = circle
	task.delay(delay, function()
		gui.Enabled = true
		tween(gui, time, { Size = UDim2.fromScale(to, to) })
		tween(circle, time, { BackgroundTransparency = 1 }, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
		tween(stroke, time, { Transparency = 1, Thickness = MERGE.RingStroke[2] }, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
	end)
	cleanup(holder, delay + time + 0.05)
end

-- The "+TIER n" chip over the result unit: a dark pill in the tier's rarity outline that pops
-- in, floats up and fades. The "best" kind adds a "NEW BEST!" line.
local function tierChip(pos: Vector3, tier: number, kind: string)
	local k = MERGE.Kinds[kind]
	local rarity = PlotRank.bandColor(tier)
	local best = kind == "best"
	local holder = fxPart(Enum.PartType.Block, Vector3.one * 0.2, CFrame.new(pos), WHITE, 1)
	holder.Name = "TierChip"
	local gui = Instance.new("BillboardGui")
	gui.AlwaysOnTop = true
	gui.LightInfluence = 0
	gui.MaxDistance = 400
	gui.Size = UDim2.fromScale(k.chip.X, k.chip.Y)
	gui.Parent = holder
	local scale = Instance.new("UIScale")
	scale.Scale = 0.2
	scale.Parent = gui
	local pill = Instance.new("Frame")
	pill.Size = UDim2.fromScale(1, 1)
	pill.BackgroundColor3 = MERGE.Ink
	pill.BackgroundTransparency = 0.08
	pill.BorderSizePixel = 0
	pill.Parent = gui
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(if best then 0.3 else 0.5, 0)
	corner.Parent = pill
	local outline = Instance.new("UIStroke")
	outline.Color = rarity
	outline.Thickness = if best then 6 else 4
	outline.Parent = pill
	local labels: { TextLabel } = {}
	local function line(text: string, y: number, height: number, color: Color3)
		local label = Instance.new("TextLabel")
		label.BackgroundTransparency = 1
		label.AnchorPoint = Vector2.new(0.5, 0)
		label.Position = UDim2.fromScale(0.5, y)
		label.Size = UDim2.fromScale(0.9, height)
		label.Font = Theme.Fonts.Display
		label.TextScaled = true
		label.TextColor3 = color
		label.TextStrokeColor3 = MERGE.Ink
		label.TextStrokeTransparency = 0.2
		label.Text = text
		label.Parent = pill
		table.insert(labels, label)
	end
	if best then
		line("NEW BEST!", 0.07, 0.3, rarity:Lerp(WHITE, 0.35))
		line("+TIER " .. tier, 0.36, 0.58, MERGE.GoldLight)
	else
		line("+TIER " .. tier, 0.1, 0.8, WHITE)
	end
	tween(scale, 0.22, { Scale = 1 }, Enum.EasingStyle.Back)
	tween(holder, k.chipLife, { CFrame = CFrame.new(pos + Vector3.new(0, MERGE.ChipRise, 0)) })
	task.delay(k.chipLife - MERGE.ChipFade, function()
		local style, dir = Enum.EasingStyle.Quad, Enum.EasingDirection.In
		tween(pill, MERGE.ChipFade, { BackgroundTransparency = 1 }, style, dir)
		tween(outline, MERGE.ChipFade, { Transparency = 1 }, style, dir)
		for _, label in labels do
			tween(label, MERGE.ChipFade, { TextTransparency = 1, TextStrokeTransparency = 1 }, style, dir)
		end
	end)
	cleanup(holder, k.chipLife + 0.05)
end

-- A short white pulse over the whole screen (not with reduced motion).
local function screenPulse(transparency: number)
	local data = State.data
	if transparency >= 1 or Camera.reducedMotion or (data and data.settings and data.settings.reducedMotion == true) then
		return
	end
	pcall(function()
		local playerGui = Players.LocalPlayer:FindFirstChildOfClass("PlayerGui")
		if not playerGui then
			return
		end
		local gui = Instance.new("ScreenGui")
		gui.Name = "MergePulse"
		gui.IgnoreGuiInset = true
		gui.ResetOnSpawn = false
		gui.DisplayOrder = 40
		local sheet = Instance.new("Frame")
		sheet.Size = UDim2.fromScale(1, 1)
		sheet.BackgroundColor3 = WHITE
		sheet.BackgroundTransparency = transparency
		sheet.BorderSizePixel = 0
		sheet.Active = false
		sheet.Parent = gui
		gui.Parent = playerGui
		task.delay(MERGE.PulseHold, function()
			tween(sheet, MERGE.PulseTime, { BackgroundTransparency = 1 }, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
		end)
		cleanup(gui, MERGE.PulseHold + MERGE.PulseTime + 0.05)
	end)
end

-- The own rack's unit drawn at `pos`, if any.
local function unitAt(pos: Vector3): Model?
	local units = watched and watched:FindFirstChild("Units")
	if units then
		for _, child in units:GetChildren() do
			if child:IsA("Model") and (child:GetPivot().Position - pos).Magnitude < 1.2 then
				return child
			end
		end
	end
	return nil
end

-- A unit that already stood there pops like a fresh result (one that is arriving pops in
-- `arrive`).
local function popUnit(model: Model, amount: number)
	if Animator.isHeld(model) then
		return
	end
	local okScale, base = pcall(model.GetScale, model)
	if not okScale or type(base) ~= "number" then
		return
	end
	local startAt = os.clock()
	Animator.hold(model)
	addJob(function(now: number): boolean
		if not model.Parent then
			Animator.release(model)
			return true
		end
		local q = (now - startAt) / MERGE.PopTime
		if q >= 1 then
			safeScale(model, base)
			Animator.release(model)
			return true
		end
		safeScale(model, base * overshoot(q, amount))
		return false
	end)
end

-- Where the "+TIER n" chip of a `kind` merge at `feet` goes: over the unit's head, its bottom
-- edge clear of the head on screen too (a camera looking down would put a chip just over the
-- head on the unit's face), and under the top HUD (pushed down there, it steps aside so it
-- does not land on the unit).
local function chipSpot(feet: Vector3, kind: string): Vector3
	local chip = MERGE.Kinds[kind].chip
	local halfY, halfX = chip.Y / 2, chip.X / 2
	local top = feet.Y + MERGE.ChipAbove - halfY - MERGE.ChipGap
	local unit = unitAt(feet)
	if unit then
		local ok, box, size = pcall(unit.GetBoundingBox, unit)
		if ok then
			top = box.Position.Y + size.Y / 2
		end
	end
	local head = Vector3.new(feet.X, top, feet.Z)
	local pos = head + Vector3.new(0, MERGE.ChipGap + halfY, 0)
	local camera = Workspace.CurrentCamera
	if not camera then
		return pos
	end
	local headAt = camera:WorldToViewportPoint(head)
	local at = camera:WorldToViewportPoint(pos)
	if headAt.Z > 0.5 and at.Z > 0.5 then
		local pxPerStud = camera.ViewportSize.Y / (2 * math.tan(math.rad(camera.FieldOfView) / 2) * at.Z)
		local bottom = at.Y + halfY * pxPerStud
		local want = headAt.Y - MERGE.ChipClearPx
		if bottom > want then
			pos += camera.CFrame.UpVector * ((bottom - want) / pxPerStud)
		end
	end
	local down = Orbs.hudOffset(pos, 0, halfY, MERGE.ChipRise)
	if down.Magnitude > 0.01 then
		pos += down + camera.CFrame.RightVector * (halfX + MERGE.ChipSide)
	end
	return pos
end

-- The screen point of a chip at `pos`, and the pixels per stud there.
local function chipBox(camera: Camera, pos: Vector3): (Vector3?, number)
	local at = camera:WorldToViewportPoint(pos)
	if at.Z <= 0.5 then
		return nil, 0
	end
	local k = camera.ViewportSize.Y / (2 * math.tan(math.rad(camera.FieldOfView) / 2) * at.Z)
	return Vector3.new(at.X, at.Y, 0), k
end

-- `pos` moved up (camera up) until a chip there covers none of the chips on screen; how many
-- it stacked over.
local function clearOfChips(pos: Vector3, half: Vector2): (Vector3, number)
	local camera = Workspace.CurrentCamera
	local now = os.clock()
	for i = #liveChips, 1, -1 do
		if now - liveChips[i].born > liveChips[i].life then
			table.remove(liveChips, i)
		end
	end
	if not camera or #liveChips == 0 then
		return pos, 0
	end
	local stacked = 0
	for _ = 1, #liveChips do
		local mine, k = chipBox(camera, pos)
		if not mine then
			break
		end
		local push, below = 0, 0
		for _, c in liveChips do
			local rise = MERGE.ChipRise * math.clamp((now - c.born) / c.life, 0, 1)
			local other, ko = chipBox(camera, c.pos + Vector3.new(0, rise, 0))
			if other then
				local wide = math.abs(mine.X - other.X) < half.X * k + c.half.X * ko
				local high = math.abs(mine.Y - other.Y) < half.Y * k + c.half.Y * ko
				if wide and high then
					-- Up until this chip's bottom edge clears the other's top edge (or, under the
					-- top HUD, down until its top edge clears the other's bottom edge).
					push = math.max(push, (mine.Y + half.Y * k) - (other.Y - c.half.Y * ko) + MERGE.ChipStackPx)
					below = math.max(below, (other.Y + c.half.Y * ko) - (mine.Y - half.Y * k) + MERGE.ChipStackPx)
				end
			end
		end
		if push <= 0 then
			break
		end
		local up = camera.CFrame.UpVector * (push / k)
		if Orbs.hudOffset(pos + up, 0, half.Y, MERGE.ChipRise).Magnitude > 0.01 then
			pos -= camera.CFrame.UpVector * (below / k)
		else
			pos += up
		end
		stacked += 1
	end
	return pos, stacked
end

-- The merge's impact on the rack, at the result unit drawn with its feet at `feet`: gold
-- rings, a spark burst and a flash, the unit's pop, the "+TIER n" chip and a camera punch.
-- `kind` is a key of MERGE.Kinds. Returns the point just over the chip (texts go above it).
local function resultFx(feet: Vector3, tier: number, kind: string): Vector3
	local k = MERGE.Kinds[kind]
	local chipAt, stacked = clearOfChips(chipSpot(feet, kind), k.chip / 2)
	local chest = feet + Vector3.new(0, CHEST_HEIGHT, 0)
	local to = k.ring[2]
	for i = 1, k.rings do
		goldRing(chest, k.ring[1], to, k.ringTime, (i - 1) * MERGE.RingGap)
		to *= MERGE.RingGrow
	end
	local flash = fxPart(Enum.PartType.Ball, Vector3.one, CFrame.new(chest), MERGE.GoldLight, MERGE.FlashAlpha, Enum.Material.Neon)
	tween(flash, MERGE.FlashTime, { Size = Vector3.one * k.flash, Transparency = 1 })
	cleanup(flash, MERGE.FlashTime + 0.05)
	burst(chest, MERGE.Gold, Budget.count(k.sparks), {
		speed = MERGE.SparkSpeed,
		texture = SPARK_SPRITE,
		size = k.sparkSize,
		life = MERGE.SparkLife,
		gravity = 18,
		drag = 2,
		emission = MERGE.SparkEmission,
	})
	local unit = unitAt(feet)
	if unit then
		popUnit(unit, k.pop)
	end
	local now = os.clock()
	if kind ~= "auto" or now - lastAutoChip >= MERGE.AutoChipGap then
		if kind == "auto" then
			lastAutoChip = now
		end
		local delay = stacked * MERGE.ChipStagger
		table.insert(liveChips, { pos = chipAt, born = now + delay, life = k.chipLife, half = k.chip / 2 })
		if delay > 0 then
			task.delay(delay, tierChip, chipAt, tier, kind)
		else
			tierChip(chipAt, tier, kind)
		end
	end
	if kind == "best" then
		-- A gold column of light over the new best unit.
		local b = MERGE.BestBeam
		local holder = fxPart(Enum.PartType.Block, Vector3.one * 0.2, CFrame.new(feet), WHITE, 1)
		local a0 = Instance.new("Attachment")
		a0.Parent = holder
		local a1 = Instance.new("Attachment")
		a1.Position = Vector3.new(0, b.Height, 0)
		a1.Parent = holder
		local beam = Instance.new("Beam")
		beam.Attachment0 = a0
		beam.Attachment1 = a1
		beam.FaceCamera = true
		beam.Segments = 4
		beam.Width0 = b.Width
		beam.Width1 = b.Width * 1.6
		beam.LightEmission = 0.7
		beam.LightInfluence = 0
		beam.Color = ColorSequence.new(MERGE.GoldLight, WHITE)
		beam.Transparency = NumberSequence.new(0.25, 1)
		beam.Parent = holder
		tween(beam, b.Time, { Width0 = 0, Width1 = 0 }, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
		cleanup(holder, b.Time + 0.05)
		for i, confetti in CONFETTI do
			task.delay(0.04 * i, function()
				burst(chest + Vector3.new(0, 1, 0), confetti, Budget.count(10), {
					speed = NumberRange.new(12, 24),
					size = 1.1,
					life = NumberRange.new(0.9, 1.5),
					spread = 60,
					gravity = 18,
					drag = 2,
				})
			end)
		end
	end
	if playerNear(feet, NEAR_PLOT) then
		if k.punch > 0 then
			Camera.punch(k.punch)
		end
		screenPulse(k.pulse)
	end
	return chipAt + Vector3.new(0, k.chip.Y / 2 + MERGE.ChipRise, 0)
end

-- Which kind of impact a merge to `toTier` gets, asked at its impact (a new best tier then
-- stops being news). Of a chain of step merges only the last, highest step is the "best".
local function mergeKind(toTier: number, auto: boolean): string
	if knownBest > 0 and toTier > knownBest and toTier >= seenTop then
		knownBest = toTier
		return "best"
	end
	return if auto then "auto" else "manual"
end

-- A merge to `toTier` was announced: how far its result unit will overshoot as it pops in.
local function announce(toTier: number, auto: boolean): number
	seenTop = math.max(seenTop, toTier)
	local news = knownBest > 0 and toTier > knownBest
	return MERGE.Kinds[if news then "best" elseif auto then "auto" else "manual"].pop
end

local function impactFx(pos: Vector3, tier: number, auto: boolean, boost: number?, pitch: number?)
	local color = tierColor(tier)
	local k = (if auto then 0.55 else 1 + math.min(tier, 25) * 0.03) * (boost or 1)
	-- Soft tier-tinted puff.
	puff(pos, color:Lerp(WHITE, 0.45), 1.2, 5.5 * k, 0.35, 0.35)
	-- Floor ring.
	ring(pos - Vector3.new(0, CHEST_HEIGHT - 0.3, 0), color:Lerp(WHITE, 0.25), 2, 16 * k, 0.5, 0.3)
	if not auto then
		ring(pos, WHITE, 1.5, 10 * k, 0.35, 0.45)
	end
	burst(pos, color, if auto then 12 else 28, { speed = NumberRange.new(8, 18), size = 0.8, gravity = 14 })
	if not auto then
		burst(pos, WHITE, 10, { speed = NumberRange.new(4, 9), size = 1.2, life = NumberRange.new(0.3, 0.6), gravity = 0 })
	end
	local now = os.clock()
	if now - lastBoom > 0.12 then
		lastBoom = now
		if auto then
			Sounds.play("MergeBoom", 0.08, 1.35 * (pitch or 1))
		else
			Sounds.play("MergeBoom", 0.05, (1.1 - math.min(tier, 25) * 0.012) * (pitch or 1))
		end
	end
	-- The camera punch is resultFx's.
end

-- One quick fusion pop in a cascade: a soft bubble, ring, sparks, rising pitch.
local function cascadePop(pos: Vector3, tier: number, index: number, total: number, auto: boolean)
	local color = tierColor(tier)
	local grow = 0.6 + 0.8 * (index / total)
	local bubble = fxPart(Enum.PartType.Ball, Vector3.one * 0.6, CFrame.new(pos), color:Lerp(WHITE, 0.5), 0.3)
	tween(bubble, 0.15, { Size = Vector3.one * 2.6 * grow }, Enum.EasingStyle.Back)
	task.delay(0.15, function()
		tween(bubble, 0.2, { Size = Vector3.one * 0.6, Transparency = 1 }, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
	end)
	cleanup(bubble, 0.4)
	ring(pos, color:Lerp(WHITE, 0.25), 1, 6 * grow, 0.3, 0.35)
	burst(pos, color, if auto then 6 else 10, { speed = NumberRange.new(6, 12), size = 0.55 * grow, gravity = 6 })
	Sounds.play("BuyPop", 0.02, 0.9 + index * 0.11)
	if not auto and playerNear(pos, NEAR_PLOT) then
		Camera.shake((0.05 + 0.1 * grow) * PUNCH_SCALE, 0.15)
	end
end

-- The "xN MERGES!" world text. Its part carries the text in the attribute
-- Shelf.MERGES_ATTRIBUTE: UI.Popups hides the text while a discovery reveal is up and shows
-- the same line on the reveal, and finds it by that attribute.
local MERGES_ATTRIBUTE = "MergesText"
Shelf.MERGES_ATTRIBUTE = MERGES_ATTRIBUTE

local function mergesText(pos: Vector3, count: number, color: Color3, scale: number, life: number)
	Orbs.text(pos, "x" .. count .. " MERGES!", color, { scale = scale, rise = 4, life = life, tag = MERGES_ATTRIBUTE })
end

-- Big finish for a batch: a wide soft ring, palette confetti, "xN MERGES!".
local function cascadeFinale(chest: Vector3, tier: number, count: number, auto: boolean, kind: string)
	local size = math.clamp(math.log(math.max(count, 2), 2) / 3, 0.6, 1.6)
	impactFx(chest, tier, auto, 1 + size * 0.6, 0.9)
	local overChip = resultFx(chest - Vector3.new(0, CHEST_HEIGHT, 0), tier, kind)
	local color = tierColor(tier)
	local feet = chest - Vector3.new(0, CHEST_HEIGHT - 0.25, 0)
	task.delay(0.08, function()
		ring(feet, WHITE, 3, 26 * size, 0.6, 0.4)
	end)
	-- Confetti in the world palette, tossed up and drifting down.
	for i, confetti in CONFETTI do
		task.delay(0.03 * i, function()
			burst(chest + Vector3.new(0, 0.5, 0), confetti, if auto then 4 else 8, {
				speed = NumberRange.new(10, 20),
				size = 0.7,
				life = NumberRange.new(0.8, 1.3),
				spread = 50,
				gravity = 16,
				drag = 2,
			})
		end)
	end
	-- Over the "+TIER n" chip.
	mergesText(overChip + Vector3.new(0, 1.2, 0), count, color:Lerp(WHITE, 0.25), 1.4 + size * 0.6, 1.6)
end

local function soulOrbs(from: Vector3, to: Vector3, color: Color3, startAt: number, duration: number, auto: boolean)
	local count = if auto then 2 else 3
	local start = from + Vector3.new(0, 2.5, 0)
	-- Puff where the unit dissolved.
	task.delay(math.max(0, startAt - os.clock()), function()
		burst(start, color, if auto then 5 else 10, { speed = NumberRange.new(2, 5), size = 0.7, gravity = -4 })
	end)
	for i = 1, count do
		local delay = (i - 1) * math.min(0.06, duration * 0.3)
		local radius = 1.2 + math.random() * 0.8
		local angle0 = (i / count) * math.pi * 2 + math.random()
		local rise = 3.5 + math.random() * 1.5
		local size = (if auto then 0.5 else 0.75) * (1 - (i - 1) * 0.15)
		local orb: Part? = nil
		addJob(function(now: number): boolean
			local t = now - startAt - delay
			if t < 0 then
				return false
			end
			local length = math.max(duration - delay, 0.05)
			local p = math.clamp(t / length, 0, 1)
			if not orb then
				-- Soul orbs are aura, the one effect drawn in Neon.
				local part = fxPart(Enum.PartType.Ball, Vector3.one * size, CFrame.new(start), color, 0, Enum.Material.Neon)
				local a0 = Instance.new("Attachment")
				a0.Position = Vector3.new(0, size * 0.45, 0)
				a0.Parent = part
				local a1 = Instance.new("Attachment")
				a1.Position = Vector3.new(0, -size * 0.45, 0)
				a1.Parent = part
				local trail = Instance.new("Trail")
				trail.Attachment0 = a0
				trail.Attachment1 = a1
				trail.Color = ColorSequence.new(WHITE, color)
				trail.LightEmission = SPARKLE_EMISSION
				trail.Lifetime = 0.22
				trail.Transparency = NumberSequence.new(0.3, 1)
				trail.FaceCamera = true
				trail.Parent = part
				orb = part
			end
			local part = orb :: Part
			if p >= 1 then
				part:Destroy()
				return true
			end
			local e = easeInOut(p)
			local center = start:Lerp(to, e) + Vector3.new(0, math.sin(p * math.pi) * rise, 0)
			local angle = angle0 + p * math.pi * 5
			local r = radius * (1 - e) + 0.05
			local offset = Vector3.new(math.cos(angle) * r, 0, math.sin(angle) * r)
			part.CFrame = CFrame.new(center + offset)
			part.Size = Vector3.one * size * (1 + 0.6 * math.sin(p * math.pi))
			return false
		end)
	end
end

-- Overflow merges (the rack was full) --------------------------------------------------

local FULL_FLOAT_GAP = 1 -- seconds between "FULL! AUTO-MERGED" floats
local OVERFLOW_PULSE = 0.4 -- the consumed spots pulse this long before their aura flies
local lastFullFloat = -math.huge
local fullPending = 0 -- merges waiting for the next float
local fullFloatQueued = false

-- One short float per FULL_FLOAT_GAP; merges arriving in between are added to it.
local function fullFloat(pos: Vector3, count: number)
	fullPending += count
	if fullFloatQueued then
		return
	end
	fullFloatQueued = true
	task.delay(math.max(0, lastFullFloat + FULL_FLOAT_GAP - os.clock()), function()
		fullFloatQueued = false
		lastFullFloat = os.clock()
		local n = fullPending
		fullPending = 0
		local text = if n >= 2 then "FULL! AUTO-MERGED x" .. n else "FULL! AUTO-MERGED"
		Orbs.text(pos, text, worldColor("Sunny", WHITE), { scale = 1.25, rise = 3, life = 1.4 })
	end)
end

-- A soft double pulse at a consumed unit's spot (it swells twice, then shrinks away).
local function spotPulse(pos: Vector3, color: Color3, at: number)
	task.delay(math.max(0, at - os.clock()), function()
		local chest = pos + Vector3.new(0, CHEST_HEIGHT * 0.8, 0)
		local bubble = fxPart(Enum.PartType.Ball, Vector3.one * 0.8, CFrame.new(chest), color:Lerp(WHITE, 0.45), 0.4)
		tween(bubble, 0.12, { Size = Vector3.one * 2.4 }, Enum.EasingStyle.Back)
		task.delay(0.12, function()
			tween(bubble, 0.1, { Size = Vector3.one * 1.6 })
		end)
		task.delay(0.22, function()
			tween(bubble, 0.12, { Size = Vector3.one * 2.7 }, Enum.EasingStyle.Back)
		end)
		task.delay(0.34, function()
			tween(bubble, 0.16, { Size = Vector3.one * 0.4, Transparency = 1 }, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
		end)
		cleanup(bubble, 0.55)
	end)
end

-- The light "rack full" moment: spots pulse, their aura flies together, a soft fusion at
-- the new unit and a rate-limited float. Queues behind other merges like any merge.
local function onOverflow(data: { [string]: any }, target: Vector3, fromTier: number, toTier: number, count: number)
	local now = os.clock()
	local startAt = math.max(now, lastMergeAt + MERGE_STAGGER)
	local flyAt = startAt + OVERFLOW_PULSE
	local impact = flyAt + CHARGE_AUTO
	lastMergeAt = flyAt
	local pending = { pos = target, impact = impact, pop = announce(toTier, true) }
	table.insert(pendingMerges, pending)
	-- Everything from here on is drawn where the units are shown.
	target = shownAt(target)
	task.delay(impact - now + 0.5, function()
		local index = table.find(pendingMerges, pending)
		if index then
			table.remove(pendingMerges, index)
		end
	end)
	local chest = target + Vector3.new(0, CHEST_HEIGHT, 0)
	local color = tierColor(fromTier)
	if type(data.from) == "table" then
		for index, pos in data.from do
			if typeof(pos) == "Vector3" and index <= 4 then
				spotPulse(shownAt(pos), color, startAt)
				soulOrbs(shownAt(pos), chest, color, flyAt, CHARGE_AUTO, true)
			end
		end
	end
	task.delay(startAt - now, function()
		Sounds.play("BuyPop", 0.03, 0.7)
	end)
	task.delay(impact - now, function()
		impactFx(chest, toTier, true, 1.1, 1.1)
		local overChip = resultFx(target, toTier, mergeKind(toTier, true))
		ring(target + Vector3.new(0, 0.15, 0), worldColor("Sunny", WHITE), 1.5, 9, 0.45, 0.35)
		-- Over the "+TIER n" chip.
		fullFloat(overChip + Vector3.new(0, 0.8, 0), count)
	end)
end

local function onMerge(data: { [string]: any })
	local from = data.from
	local to = data.to
	local auto = data.auto == true
	local fromTier = tonumber(data.fromTier) or 1
	local toTier = tonumber(data.toTier) or (fromTier + 1)
	if typeof(to) ~= "Vector3" then
		if type(from) == "table" and #from > 0 then
			local sum = Vector3.zero
			for _, v in from do
				sum += v
			end
			to = sum / #from
		else
			-- Legacy effect without positions: nothing to show in 3D.
			Sounds.play("MergeBoom", 0.05, if auto then 1.35 else 1)
			return
		end
	end
	local target: Vector3 = to
	local count = math.max(1, math.floor(tonumber(data.count) or 1))
	if data.overflow == true then
		onOverflow(data, target, fromTier, toTier, count)
		return
	end
	local summary = data.summary == true
	local now = os.clock()
	local queued = lastMergeAt + MERGE_STAGGER > now
	local startAt = math.max(now, lastMergeAt + MERGE_STAGGER)
	local duration = if auto then CHARGE_AUTO else CHARGE
	local impactAt = startAt + duration
	-- Batched merges: cascade of pops before the final boom.
	local pops = if summary or count >= 4 then math.clamp(if summary then count else count - 1, 3, 8) else 0
	local gaps = 0
	for i = 1, pops do
		gaps += math.max(0.06, 0.14 - i * 0.012)
	end
	local impact = impactAt + gaps
	lastMergeAt = if pops > 0 then impact - duration else startAt
	if queued then
		chainIndex += 1
		chainTotal += count
	else
		chainIndex = 0
		chainTotal = count
	end
	local myChain = chainIndex
	local slotPos = target
	table.insert(pendingMerges, { pos = slotPos, impact = impact, pop = announce(toTier, auto) })
	task.delay(impact - now + 0.5, function()
		for i, pending in pendingMerges do
			if pending.impact == impact and pending.pos == slotPos then
				table.remove(pendingMerges, i)
				break
			end
		end
	end)
	-- Everything from here on is drawn where the units are shown.
	target = shownAt(target)

	local chest = target + Vector3.new(0, CHEST_HEIGHT, 0)
	local color = tierColor(fromTier)
	if type(from) == "table" then
		for index, pos in from do
			if typeof(pos) == "Vector3" and index <= 4 then
				soulOrbs(shownAt(pos), chest, color, startAt, duration, auto)
			end
		end
	end
	task.delay(startAt - now, function()
		if not auto then
			Sounds.play("MergeCharge", 0.05, 1 + math.min(toTier, 25) * 0.01)
		end
	end)
	if pops > 0 then
		local at = impactAt
		for i = 1, pops do
			local p = (i - 1) / math.max(1, pops - 1)
			local tierAt = math.floor(fromTier + (toTier - 1 - fromTier) * p + 0.5)
			local popPos = chest + Vector3.new(math.cos(i * 2.4) * 0.8, (i - 1) * 0.35, math.sin(i * 2.4) * 0.8)
			task.delay(at - now, function()
				cascadePop(popPos, tierAt, i, pops, auto)
			end)
			at += math.max(0.06, 0.14 - i * 0.012)
		end
		task.delay(impact - now, function()
			cascadeFinale(chest, toTier, count, auto, mergeKind(toTier, auto))
		end)
		lastImpact = impact
		chainTotal = 0
		return
	end
	local chainAt = chest + Vector3.new(0, 9, 0) -- over the chip, once it is placed
	task.delay(impact - now, function()
		impactFx(chest, toTier, auto, nil, 1 + math.min(myChain, 6) * 0.06)
		local overChip = resultFx(target, toTier, mergeKind(toTier, auto))
		chainAt = overChip + Vector3.new(0, 1.2, 0)
		if count >= 2 then
			-- Over the "+TIER n" chip.
			Orbs.text(overChip + Vector3.new(0, 0.8, 0), "x" .. count, tierColor(toTier), { scale = 0.9, rise = 2.5 })
		end
	end)
	lastImpact = impact
	-- When a chain of step merges ends, show its running total.
	task.delay(impact - now + 0.25, function()
		if lastImpact == impact and chainTotal >= 3 then
			mergesText(chainAt, chainTotal, tierColor(toTier):Lerp(WHITE, 0.25), 1.6, 1.5)
			chainTotal = 0
		end
	end)
end

-- Shelf glow: tier discs under every unit, hero treatment for the best one ------------------

local RUNES = 14
local MAX_DISCS = Economy.DISPLAY_SLOTS or 100
local DISC_REFRESH = 12 -- units whose disc position is re-read per frame (round-robin)
local DISC_GROW = 0.35 -- seconds a new disc takes to pop in
local DISC_ALPHA = 0.74 -- resting transparency of a non-hero disc
-- Disc radius range: a disc stays on its 4-stud-deep board and clear of its neighbours.
local DISC_RADIUS = NumberRange.new(1.2, 1.8)
local HERO_RING_MAX = 1.95 -- the hero's tile ring stays on the board too
local UPRIGHT = CFrame.Angles(0, 0, math.pi / 2)
local HIDDEN = CFrame.new(0, -10000, 0)

type Deco = {
	disc: Part,
	ring: Part, -- rarity band ring round the disc
	aura: ParticleEmitter?, -- sparkles of a front-shelf unit of a top band
	slot: number,
	scale: number, -- size the model is drawn at (1 = as the server built it)
	tier: number,
	color: Color3,
	radius: number,
	floorOffset: number, -- pivot Y minus the model's bottom
	pos: Vector3?, -- last known floor point under the unit
	shownAt: number,
	phase: number,
	measured: boolean,
	dirty: boolean, -- position or size changed since the disc was last placed
	index: number, -- position in decoOrder
}

local decos: { [Model]: Deco } = {}
local decoOrder: { Model } = {}
local decoCursor = 1
local decoCount = 0
local unitsFolder: Instance? = nil
local hero: Model? = nil
local heroSince = 0
local heroBurstDone = false
local glowWarned = false
local heroRunes: { Part } = {}
local heroBeam: Beam? = nil
local heroEmitPart: Part? = nil
local heroEmitter: ParticleEmitter? = nil
local heroColorSet: Color3? = nil -- colour last given to the hero's beam and sparkles
local glowParts: { BasePart } = {}
local glowCFrames: { CFrame } = {}
-- The rack's two best tiers, the champion's drawn size and this frame's resize count.
local standing = { best = 0, second = 0, champion = 1, resized = 0 }
local RING = PlotRank.CFG.RingWidth

local function modelTier(model: Model): number
	local value = model:GetAttribute("Tier")
	return if type(value) == "number" then value else 1
end

local function measure(model: Model, deco: Deco)
	local ok, cf, size = pcall(model.GetBoundingBox, model)
	if not ok then
		return
	end
	local pivot = model:GetPivot()
	deco.floorOffset = pivot.Position.Y - (cf.Position.Y - size.Y / 2)
	deco.radius = math.clamp(math.max(size.X, size.Z) * 0.55, DISC_RADIUS.Min, DISC_RADIUS.Max)
	deco.measured = true
	deco.dirty = true
end

local function removeDeco(model: Model)
	local deco = decos[model]
	if deco then
		deco.disc:Destroy()
		deco.ring:Destroy()
		decos[model] = nil
		decoCount -= 1
		local last = decoOrder[#decoOrder]
		decoOrder[deco.index] = last
		local lastDeco = decos[last]
		if lastDeco then
			lastDeco.index = deco.index
		end
		decoOrder[#decoOrder] = nil
	end
end

local function addDeco(model: Instance)
	if not model:IsA("Model") or decos[model] or decoCount >= MAX_DISCS then
		return
	end
	local tier = modelTier(model)
	local color = tierColor(tier)
	local disc = fxPart(Enum.PartType.Cylinder, Vector3.new(0.05, 0.1, 0.1), HIDDEN, color, DISC_ALPHA)
	disc.Name = "TierDisc"
	local ringAlpha, ringMaterial = PlotRank.ringLook(tier)
	local ring = fxPart(Enum.PartType.Cylinder, Vector3.new(0.05, 0.1, 0.1), HIDDEN, PlotRank.bandColor(tier), ringAlpha, ringMaterial)
	ring.Name = "RarityRing"
	local okScale, scale = pcall(model.GetScale, model)
	table.insert(decoOrder, model)
	decos[model] = {
		disc = disc,
		ring = ring,
		aura = nil,
		slot = MAX_DISCS,
		scale = if okScale and type(scale) == "number" then scale else 1,
		tier = tier,
		color = color,
		radius = 2,
		floorOffset = 0,
		pos = nil,
		shownAt = 0,
		phase = math.random() * 6,
		measured = false,
		dirty = false,
		index = #decoOrder,
	}
	decoCount += 1
	model:GetAttributeChangedSignal("Tier"):Connect(function()
		local deco = decos[model]
		if deco then
			deco.tier = modelTier(model)
			deco.color = tierColor(deco.tier)
			deco.disc.Color = deco.color
			deco.ring.Color = PlotRank.bandColor(deco.tier)
			deco.ring.Transparency, deco.ring.Material = PlotRank.ringLook(deco.tier)
			if deco.aura then
				deco.aura.Color = ColorSequence.new(WHITE, PlotRank.bandColor(deco.tier))
			end
			deco.measured = false
		end
	end)
end

local function ensureHeroParts()
	if #heroRunes > 0 and heroEmitPart and heroEmitPart.Parent then
		return
	end
	table.clear(heroRunes)
	for i = 1, RUNES do
		local rune = fxPart(Enum.PartType.Block, Vector3.new(0.2, 0.12, 0.6), HIDDEN, WHITE, 0.25)
		rune.Name = "HeroRune" .. i
		heroRunes[i] = rune
	end
	local emitPart = fxPart(Enum.PartType.Block, Vector3.new(3, 0.1, 3), HIDDEN, WHITE, 1)
	emitPart.Name = "HeroSparkles"
	-- Ground-up haze: a faint tier-coloured column, painted rather than glowing,
	-- that fades out well before head height so the hero model always reads clearly.
	local a0 = Instance.new("Attachment")
	a0.Parent = emitPart
	local a1 = Instance.new("Attachment")
	a1.Position = Vector3.new(0, 5.5, 0) -- below the shelf above
	a1.Parent = emitPart
	local beam = Instance.new("Beam")
	beam.Name = "HeroBeam"
	beam.Attachment0 = a0
	beam.Attachment1 = a1
	beam.FaceCamera = true
	beam.LightEmission = 0
	beam.LightInfluence = 0.6
	beam.Segments = 8
	beam.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.78),
		NumberSequenceKeypoint.new(0.35, 0.9),
		NumberSequenceKeypoint.new(1, 1),
	})
	beam.Parent = emitPart
	heroBeam = beam
	local emitter = Instance.new("ParticleEmitter")
	emitter.Texture = SPARKLE
	emitter.LightEmission = SPARKLE_EMISSION
	emitter.Rate = 6
	emitter.Lifetime = NumberRange.new(1.2, 2)
	emitter.Speed = NumberRange.new(1.5, 3.5)
	emitter.EmissionDirection = Enum.NormalId.Top
	emitter.SpreadAngle = Vector2.new(12, 12)
	emitter.Acceleration = Vector3.new(0, 1.5, 0)
	emitter.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0),
		NumberSequenceKeypoint.new(0.2, 0.45),
		NumberSequenceKeypoint.new(1, 0),
	})
	emitter.Transparency = NumberSequence.new(0, 1)
	emitter.RotSpeed = NumberRange.new(-90, 90)
	emitter.Parent = emitPart
	heroEmitPart, heroEmitter = emitPart, emitter
	heroColorSet = nil
end

local function hideHero()
	for _, rune in heroRunes do
		rune.CFrame = HIDDEN
	end
	if heroEmitPart then
		heroEmitPart.CFrame = HIDDEN
	end
	if heroEmitter then
		heroEmitter.Enabled = false
	end
end

local function pickHero()
	local best: Model? = nil
	local bestTier = -1
	local tiers: { number } = {}
	for model, deco in decos do
		if model.Parent and (deco.tier > bestTier or (deco.tier == bestTier and model == hero)) then
			best, bestTier = model, deco.tier
		end
		table.insert(tiers, deco.tier)
	end
	standing.best, standing.second = PlotRank.topTiers(tiers)
	-- A new best tier is known a moment later: the merge that made it gets the big impact.
	local top = standing.best
	if top > knownBest and top ~= pendingBest then
		pendingBest = top
		task.delay(MERGE.BestDelay, function()
			knownBest = math.max(knownBest, top)
		end)
	end
	if best ~= hero then
		local old = hero
		if old then
			Animator.setHero(old, false)
			local oldDeco = decos[old]
			if oldDeco then
				oldDeco.dirty = true
				oldDeco.disc.Transparency = DISC_ALPHA
			end
		end
		hero = best
		heroSince = os.clock()
		heroBurstDone = false
		if best then
			Animator.setHero(best, true)
			ensureHeroParts()
			-- The champion's pedestal glows instead (Fx.PlotRank): no ring under it.
			local bestDeco = decos[best]
			if bestDeco then
				bestDeco.ring.CFrame = HIDDEN
			end
		else
			hideHero()
		end
	end
end

-- Draws a unit at the size its standing on the rack earns (PlotRank.wantScale), as far as the
-- board above it leaves room, and switches its aura sparkles. A few units per frame.
local function applyStanding(model: Model, deco: Deco)
	local cfg = PlotRank.CFG
	local slotValue = model:GetAttribute("Slot")
	deco.slot = if type(slotValue) == "number" then slotValue else MAX_DISCS
	local champion = deco.slot == 1
	local glows = PlotRank.bandIndex(deco.tier) >= cfg.AuraBand and deco.slot <= cfg.FrontSlots and not champion and not Budget.low()
	local aura = deco.aura
	if glows and not aura then
		local made = Instance.new("ParticleEmitter")
		made.Name = "RarityAura"
		made.Texture = SPARKLE
		made.LightEmission = SPARKLE_EMISSION
		made.Lifetime = NumberRange.new(1, 1.6)
		made.Speed = NumberRange.new(1, 2.4)
		-- The ring lies on its side: its +X face looks up.
		made.EmissionDirection = Enum.NormalId.Right
		made.SpreadAngle = Vector2.new(10, 10)
		made.Size = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0),
			NumberSequenceKeypoint.new(0.2, 0.35),
			NumberSequenceKeypoint.new(1, 0),
		})
		made.Transparency = NumberSequence.new(0, 1)
		made.Color = ColorSequence.new(WHITE, PlotRank.bandColor(deco.tier))
		made.Rate = Budget.count(cfg.AuraRate)
		made.Parent = deco.ring
		deco.aura = made
		aura = made
	end
	if aura and aura.Enabled ~= glows then
		aura.Enabled = glows
		aura.Rate = Budget.count(cfg.AuraRate)
	end

	-- The champion stands on its stage in front of the pedestal (the server stands it on the
	-- pedestal, and puts it back there whenever it moves the unit).
	local rim = if champion then championRim() else nil
	if rim then
		local stage = PlotRank.championPivot(rim)
		if (model:GetPivot().Position - stage.Position).Magnitude > 0.05 then
			model:PivotTo(stage)
			deco.measured = false
		end
	end
	local feet = model:GetPivot().Position
	local heightValue = model:GetAttribute("Height")
	local height = if type(heightValue) == "number" then heightValue else 5
	local ceiling = boardAbove(watched, feet)
	local want = PlotRank.wantScale(deco.tier, deco.slot, standing.best, standing.second)
	local target = PlotRank.fitScale(want, height, if ceiling then ceiling - feet.Y else nil, if champion then nil else standing.champion)
	if rim then
		-- Nothing is above the stage: the champion gets its full size.
		target = PlotRank.championScale(deco.tier)
	end
	if champion then
		standing.champion = target
	end
	if math.abs(target - deco.scale) < 0.005 or standing.resized >= cfg.RescalesPerFrame then
		return
	end
	standing.resized += 1
	deco.scale = target
	Animator.hold(model)
	safeScale(model, target)
	Animator.release(model)
	deco.measured = false
end

-- Re-reads where a unit stands; marks its disc dirty when it moved (or appeared).
local function refreshDeco(model: Model, deco: Deco, now: number)
	if not model.Parent or Animator.isHeld(model) then
		return
	end
	applyStanding(model, deco)
	if not deco.measured then
		measure(model, deco)
	end
	local pivot = model:GetPivot().Position
	local pos = Vector3.new(pivot.X, pivot.Y - deco.floorOffset + 0.08, pivot.Z)
	local old = deco.pos
	if not old then
		deco.shownAt = now
		deco.dirty = true
	elseif (old - pos).Magnitude > 0.02 then
		deco.dirty = true
	end
	deco.pos = pos
end

-- Discs are static: a few units are re-checked per frame and only discs that moved, are
-- popping in or belong to the hero are touched. The hero's ring and haze move every frame.
local function stepGlow()
	if decoCount == 0 then
		return
	end
	local now = os.clock()
	table.clear(glowParts)
	table.clear(glowCFrames)
	standing.resized = 0
	local heroModel = hero
	local count = #decoOrder
	for _ = 1, math.min(DISC_REFRESH, count) do
		if decoCursor > count then
			decoCursor = 1
		end
		local model = decoOrder[decoCursor]
		decoCursor += 1
		local deco = decos[model]
		if deco then
			refreshDeco(model, deco, now)
		end
	end
	local heroDeco = heroModel and decos[heroModel]
	if heroDeco and not heroDeco.pos then
		refreshDeco(heroModel :: Model, heroDeco, now)
	end
	for _, model in decoOrder do
		local deco = decos[model]
		local pos = deco and deco.pos
		if not deco or not pos then
			continue
		end
		local isHero = model == heroModel
		local growing = now - deco.shownAt < DISC_GROW + 0.05
		if not (deco.dirty or growing or isHero) then
			continue
		end
		deco.dirty = false
		-- Pop in with a back-eased scale the first time it appears.
		local grow = backOut(math.clamp((now - deco.shownAt) / DISC_GROW, 0, 1))
		local d = math.max(deco.radius * 2 * grow, 0.05)
		deco.disc.Size = Vector3.new(0.05, d, d)
		if isHero then
			deco.disc.Transparency = 0.35 + 0.12 * math.sin(now * 2.2 + deco.phase)
		end
		table.insert(glowParts, deco.disc)
		table.insert(glowCFrames, CFrame.new(pos) * UPRIGHT)
		if not isHero then
			-- The rarity ring: a wider disc just under the tier disc, so only its edge shows.
			local wide = d + RING * 2 * math.min(grow, 1)
			deco.ring.Size = Vector3.new(0.05, wide, wide)
			table.insert(glowParts, deco.ring)
			table.insert(glowCFrames, CFrame.new(pos - Vector3.new(0, 0.03, 0)) * UPRIGHT)
		end
	end
	local heroPos = heroDeco and heroDeco.pos
	if heroDeco and heroPos and heroBeam and heroEmitPart then
		local color = heroDeco.color
		local intro = math.clamp((now - heroSince) / 0.5, 0, 1)
		local r = math.min(heroDeco.radius * 1.35, HERO_RING_MAX) * backOut(intro)
		local spin = now * 0.4
		local seg = (2 * math.pi * r / RUNES) * 0.55
		for i, rune in heroRunes do
			local a = spin + (i - 1) * (2 * math.pi / RUNES)
			local wave = 0.5 + 0.5 * math.sin(now * 2 - i * 0.9)
			rune.Size = Vector3.new(0.22, 0.12 + 0.1 * wave, math.max(seg, 0.1))
			rune.Color = color:Lerp(WHITE, 0.2 + 0.35 * wave)
			rune.Transparency = 0.2 + 0.3 * (1 - wave)
			table.insert(glowParts, rune)
			table.insert(
				glowCFrames,
				CFrame.new(heroPos + Vector3.new(math.cos(a) * r, 0.1 + 0.08 * wave, math.sin(a) * r)) * CFrame.Angles(0, -a, 0)
			)
		end
		local breathe = 0.5 + 0.5 * math.sin(now * 1.3)
		local w = heroDeco.radius * (1.1 + 0.15 * breathe)
		-- The haze eases in with the ring, then breathes gently.
		local ease = 1 - (1 - intro) ^ 2
		if heroColorSet ~= color then
			heroColorSet = color
			heroBeam.Color = ColorSequence.new(color:Lerp(WHITE, 0.2))
			if heroEmitter then
				heroEmitter.Color = ColorSequence.new(WHITE, color)
			end
		end
		heroBeam.Width0 = w * (0.4 + 0.6 * ease)
		heroBeam.Width1 = w * 0.25 * ease
		heroBeam.Brightness = 1
		heroEmitPart.Size = Vector3.new(heroDeco.radius * 1.6, 0.1, heroDeco.radius * 1.6)
		table.insert(glowParts, heroEmitPart)
		table.insert(glowCFrames, CFrame.new(heroPos + Vector3.new(0, 0.3, 0)))
		if heroEmitter and not heroEmitter.Enabled then
			heroEmitter.Enabled = true
		end
		if not heroBurstDone then
			heroBurstDone = true
			burst(heroPos + Vector3.new(0, 2, 0), color, 12, { speed = NumberRange.new(4, 9), size = 0.6, gravity = -2 })
		end
	elseif heroModel then
		hideHero()
	end
	if #glowParts > 0 then
		Workspace:BulkMoveTo(glowParts, glowCFrames, Enum.BulkMoveMode.FireCFrameChanged)
	end
end

local unitConns: { RBXScriptConnection } = {}

local function bindUnits(units: Instance)
	for _, conn in unitConns do
		conn:Disconnect()
	end
	table.clear(unitConns)
	for model in decos do
		removeDeco(model)
	end
	if hero then
		Animator.setHero(hero, false)
		hero = nil
	end
	hideHero()
	unitsFolder = units
	-- What already stands on the rack is not news.
	knownBest = PlotRank.bestTier(units.Parent or units)
	pendingBest = knownBest
	for _, child in units:GetChildren() do
		addDeco(child)
	end
	pickHero()
	table.insert(
		unitConns,
		units.ChildAdded:Connect(function(child)
			addDeco(child)
			pickHero()
		end)
	)
	table.insert(
		unitConns,
		units.ChildRemoved:Connect(function(child)
			if child:IsA("Model") then
				removeDeco(child)
				if child == hero then
					Animator.setHero(child, false)
					hero = nil
				end
				pickHero()
			end
		end)
	)
end

-- Wiring ------------------------------------------------------------------------------

local watchConn: RBXScriptConnection? = nil

local function watchPlot()
	local plot = ownPlot()
	if not plot or plot == watched then
		return
	end
	if watched == nil then
		settledAt = os.clock() + JOIN_SETTLE
	end
	watched = plot
	Animator.setOwnPlot(plot)
	if watchConn then
		watchConn:Disconnect()
		watchConn = nil
	end
	task.spawn(function()
		local units = plot:WaitForChild("Units", 30)
		if not units or watched ~= plot then
			return
		end
		watchConn = units.ChildAdded:Connect(onUnitAdded)
		bindUnits(units)
		-- Units added while we were waiting still get their landing.
		for _, child in units:GetChildren() do
			onUnitAdded(child)
		end
	end)
end

function Shelf.init()
	if started then
		return
	end
	started = true
	RunService.RenderStepped:Connect(runJobs)
	RunService.Heartbeat:Connect(function()
		local ok, err = pcall(stepGlow)
		if not ok and not glowWarned then
			glowWarned = true
			warn("[Fx.Shelf] glow: " .. tostring(err))
		end
	end)
	-- Tier changes on reused models can change the best unit.
	task.spawn(function()
		while true do
			task.wait(1)
			if unitsFolder and unitsFolder.Parent then
				pickHero()
			end
		end
	end)
	Net.event("Effect").OnClientEvent:Connect(function(kind: string, data: any)
		if kind == "Merge" and type(data) == "table" then
			onMerge(data)
		end
	end)
	State.changed.Event:Connect(watchPlot)
	watchPlot()
	task.spawn(function()
		if Workspace:WaitForChild("Map", 60) then
			bindRacks()
		end
	end)
end

return Shelf
