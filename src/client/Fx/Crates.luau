--[[
	Fx.Crates: client-side juice for the crates on the local player's plot
	(workspace.Map.PlotN.Chests, server-built anchored models).

	- Arrival: a Chad on the display ledge drops the crate. The server places it
	  on its landing spot in the pen and stores the route as world-space
	  attributes Path1..PathN + PathCount + PathKinds (crate-pivot waypoints:
	  unit feet, drop point in front of the rack, gutter, chute top, chute
	  bottom, landing; read by Orbs.readRoute) and Origin (the unit's feet).
	  The crate pops out in front of the Chad with a puff, hops low off its
	  shelf to the drop point, falls into the gutter (turned along it) with a
	  bounce, slides along it and down the chute with a wobble and quarter-turn tumbles
	  (shrunk to fit the trough), bounces twice into the pen growing back to
	  full size, then squashes and settles. Its sparkles stay hidden until it lands.
	- Idle: gentle bob, slow spin and a slight sway over a soft rarity-coloured
	  ground disc whose size scales with rarity.
	- Pickup is automatic (the server's fast tick, CratePickup rules): walking up to a
	  landed crate picks it up. While the player already holds a crate and stands in
	  pickup range, the crate gives a small "can't" wiggle at most every WIGGLE_GAP s.
	- Rarity label: the rarity word ("Common", ...) floats over every landed crate as
	  bold rarity-coloured text with an Ink outline, visible within CHIP_RANGE studs of
	  the camera and hidden while the held-crate panel is open (TycoonUI CratePanelOpen).
	- Pickup (model removed): a sparkle puff where it stood.
	- Rarity look (LOOKS, one row per rarity; the server's model is the same for all of
	  them): a rarity-coloured wash over the whole crate (a Highlight fill, as
	  World.Props.overlay washes the smashers), from Rare up a piping line round each
	  strap and a gem over the lid, for Epic and Legendary an outline and a light beam
	  with rising sparkles and a soft light. The crate in the player's hands gets the wash.
	- Crate Smasher: a ring of segments on the court round each Smasher pad fills in the
	  crate's rarity colour as its timer runs (snapshot `unlockers`), the next segment
	  blinking faster toward the end; the whole ring breathes once the crate is ready.
	  The Smasher's own crate (Fx.Machines' CrackerCrate, which does the rattling) gets
	  the pen crate's whole rarity look (SMASH.look): the wash, from Rare up the piping
	  and a turning gem, for Epic and Legendary the outline and the light beam, and for
	  every rarity a glow disc on the plinth, a light and the floating rarity word.
	- Opening ritual (SMASH.ritual): when a slot's crate opens, the crate shakes harder
	  and harder for `shake` seconds under a rain of sparks while the camera leans in,
	  (the booth's pastel wash lifts and the crate is drawn as a rarity silhouette over it),
	  then bursts: a rarity-coloured flash, shock rings, a short light beam, the lid and
	  shards flying off, a camera punch. A crate opened on the spot (no Smasher slot
	  changed: a daily reward, a Crate Master's held crate) gets a stand-in crate on the
	  nearest empty plinth, else in front of the character, and the same ritual.
	  For the cards (the unit card belongs after the burst):
	    Players.LocalPlayer attributes "CrateBurstAt" (os.clock() of the burst of the
	    open in progress; in the past or nil = nothing to wait for) and
	    "CrateBurstRarity", both set on the "ChestOpen" effect, in the same frame;
	    Crates.burstAt() returns the same time, and Crates.awaitBurst(maxWait) yields
	    until it has passed (at most maxWait seconds, default 1.5) and returns the rarity.
	  Nobody has to listen: without a listener the card just shows over the ritual.

	Crates that already exist when the plot is bound just appear in place.
	All movement is local (BulkMoveTo on the server's anchored parts) and a pure
	function of time since the crate appeared, so it is frame-rate independent.
	On "low" devices (Fx.Budget) idle crates past their intro move every 2nd frame
	and only within 110 studs; dust puffs scale with Budget.count; the beam's sparkles follow
	Budget.scale and its light is left out.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Economy = require(Shared:WaitForChild("Economy"))
local CratePickup = require(Shared:WaitForChild("CratePickup"))
local Net = require(Shared:WaitForChild("Net"))
local Theme = require(ReplicatedStorage:WaitForChild("Theme"))

local Client = script.Parent.Parent
local Animator = require(Client.Animator)
local Sounds = require(Client.Sounds)
local State = require(Client.State)
local Camera = require(script.Parent.Camera)
local Orbs = require(script.Parent.Orbs)
local Sprites = require(script.Parent.Sprites)
local Budget = require(script.Parent.Budget)
local Highlights = require(script.Parent.Highlights)

local Crates = {}

local WHITE = Color3.new(1, 1, 1)
local HIDDEN = CFrame.new(0, -10000, 0)
local UPRIGHT = CFrame.Angles(0, 0, math.pi / 2)
local UP = Vector3.yAxis
local PUFF = Sprites.image("Puff") -- the Blender dust cloud; the built-in smoke without it
local SMOKE = PUFF or "rbxasset://textures/particles/smoke_main.dds"

local TRAVEL_SCALE = 0.72 -- crates shrink to fit the gutter and chute
local POP = 0.2 -- pop-in behind the Chad
local POP_FORWARD, POP_UP = 1.2, 0.3 -- pop-in spot: just in front of the Chad's feet
local HOP_MIN, HOP_MAX, HOP_APEX = 0.35, 0.6, 1 -- low hop: the shelf above is overhead
local FALL_G, FALL_MAX = 70, 0.75 -- fall into the gutter (the top shelf's fall is capped)
local GUTTER_V0, GUTTER_ACCEL, GUTTER_VMAX = 4, 11, 13
local CHUTE_ACCEL, CHUTE_VMAX = 14, 13
local BOUNCE1, BOUNCE1_APEX, BOUNCE1_SHARE = 0.44, 1.9, 0.72
local BOUNCE2, BOUNCE2_APEX = 0.26, 0.6
local SQUASH = 0.6
local FALLBACK_DROP = 7 -- no route: drop from this high above the landing spot
local CULL = 170 -- studs from the camera: beyond this crates stay still
local LOW_CULL = 110 -- the same on a "low" budget device
local idleFrame = 0
local MAX_CRATES = 8
local CHIP_RANGE = 70 -- camera distance cap of the rarity labels (BillboardGui.MaxDistance)
local CHIP_HEIGHT = 1.6 -- studs
-- Share of the chip's stud size that scales with distance; fixed pixels per letter and in
-- height keep it readable far away without it covering the pile up close.
local CHIP_SCALE = 0.55
local CHIP_PX_PER_LETTER = 6
local CHIP_PX_HEIGHT = 8
local CHIP_SCAN = 0.15 -- seconds between chip range checks
-- Labels that would overlap on screen: only the one nearest the camera shows (measured in
-- Studio at the tier 25 spawn view: three pen crates' labels drew on top of each other over
-- the pool). Two labels overlap when their centres are closer than this share of their
-- sizes (1 = the boxes just touch).
local CHIP_OVERLAP = 1.05
local WIGGLE = 0.45 -- seconds of one "can't" wiggle
local WORLD = (Theme :: any).World or {}
local INK: Color3 = WORLD.Ink or Color3.fromRGB(58, 48, 96)
local CREAM: Color3 = WORLD.Cream or Color3.fromRGB(255, 247, 232)
local GOLD: Color3 = WORLD.Gold or Color3.fromRGB(255, 196, 40)

-- Rarity look ---------------------------------------------------------------------------
-- What a crate of each rarity wears over the server's model. Written without a look at the
-- game: every number from here to the Smasher block is a first guess for the Studio pass.
type Look = {
	wash: number, -- Highlight fill transparency over the whole crate; 1 = no wash
	rim: number, -- Highlight outline transparency; 1 = no outline
	piping: Color3?, -- a line round the middle of each rarity strap
	gem: number, -- size (studs) of the gem over the lid; 0 = none
	beam: number, -- height (studs) of the light beam; 0 = none
	beamWidth: number, -- studs across at the ground (its widest layer)
	motes: number, -- sparkles per second rising through the beam (before Fx.Budget)
	light: number, -- PointLight range in studs; 0 = none
}
-- By rarity rank: 0 Common, 1 Uncommon, 2 Rare, 3 Epic, 4 Legendary (and anything above).
local LOOKS: { [number]: Look } = {
	[0] = { wash = 0.72, rim = 1, gem = 0, beam = 0, beamWidth = 0, motes = 0, light = 0 },
	[1] = { wash = 0.6, rim = 1, gem = 0, beam = 0, beamWidth = 0, motes = 0, light = 0 },
	[2] = { wash = 0.52, rim = 1, piping = CREAM, gem = 0.55, beam = 0, beamWidth = 0, motes = 0, light = 0 },
	[3] = { wash = 0.46, rim = 0.3, piping = GOLD, gem = 0.7, beam = 28, beamWidth = 2.6, motes = 4, light = 9 },
	[4] = { wash = 0.36, rim = 0, piping = CREAM, gem = 0.9, beam = 42, beamWidth = 3.6, motes = 7, light = 12 },
}
local TOP_RANK = 4 -- the last row of LOOKS
local RIM_WHITEN = 0.3 -- the outline is the rarity colour mixed this far to white
local PIPING_WIDTH = 0.14 -- studs
local PIPING_PROUD = 0.05 -- studs the piping stands off the strap
local GEM_GAP = 0.35 -- studs between the lid and the gem's lowest corner
local GEM_WHITEN = 0.25
-- A cube stood on one corner reads as a cut gem.
local GEM_TILT = CFrame.Angles(-math.atan(1 / math.sqrt(2)), 0, math.pi / 4)
-- Beam layers, widest first: `width` is a share of the look's beamWidth, `base` the
-- transparency at the ground (each fades to nothing at the top).
local BEAM_LAYERS = { { width = 1, base = 0.7 }, { width = 0.4, base = 0.35 } }
local BEAM_TAPER = 0.6 -- width at the top as a share of the width at the ground
local BEAM_EMISSION = 0.6
local BEAM_WHITEN = 0.25 -- the foot of the beam is the rarity colour mixed this far to white
local BEAM_OPEN = 0.5 -- seconds the beam takes to open after the landing
local BEAM_BREATH, BEAM_BREATH_RATE = 0.08, 1.3 -- share of the width, radians per second
local BEAM_FOOT = Vector3.new(2.6, 0.2, 2.2) -- the sparkles rise from this patch under the crate
local MOTE_SIZE = 0.5 -- studs
local LIGHT_BRIGHTNESS = 0.9
-- Everything this module adds inside a model it does not own carries this name, so a crate
-- tracked again (the plot rebinds) starts clean.
local DECOR = "RarityDecor"

-- Crate Smasher ---------------------------------------------------------------------------
local RING_SEGMENTS = 24
local RING_RADIUS = 4.05 -- studs: clear of the pad's rim corners (3.9 from its centre)
local RING_WIDTH, RING_HEIGHT = 0.42, 0.12 -- studs across the ring, and standing off the court
local RING_FILL = 0.8 -- share of its arc a segment covers (the rest is the gap)
-- The court's surface under the pad's top: the pad stands 0.5 over the ground (World.Pads),
-- the court paint 0.1 (World.Decor).
local RING_BELOW_PAD = 0.4
local RING_UNLIT, RING_LIT = 0.7, 0.05 -- transparency of a waiting (Ink) and a filled segment
local RING_BLINK_SLOW, RING_BLINK_FAST = 3, 14 -- radians per second at the start and the end
local RING_READY_DIP, RING_READY_RATE = 0.35, 4 -- ready: transparency swing, radians per second
local RELOAD_JUMP = 5 -- seconds a slot's end must move back for it to count as a new crate
local SMASHER_REACH = 14 -- studs from a pad to its plinth (the HoloCrate ghost)
local SMASHER_CRATE_REACH = 3 -- studs from the plinth within which Fx.Machines' crate stands
local WASH_WINDOW, WASH_SCAN = 5, 0.1 -- seconds that crate is looked for, and between looks

-- The Smasher's crate and its opening ritual: every size, colour, duration and count. One
-- table, not a local each: a chunk holds 200 locals at most. Written without a look at the
-- game and sized to be seen from the pad at 1280x720 (the camera 25 to 50 studs away).
local SMASH = {
	-- What Fx.Machines' crate on the plinth wears on top of its rarity's row of LOOKS.
	look = {
		wash = 0.42, -- the sunny crate needs at least this strong a wash
		rim = 0, -- and a rarity outline at every rarity (the pen's starts at Epic)
		gem = 1.4, -- gem size / the pen crate's
		gemSpin = 1.6, -- radians per second
		gemBob = 0.14, -- studs
		beam = 0.75, -- beam height / the pen crate's (the booth's sign is overhead)
		-- The Smasher's beam is brighter than the pen's: the transparency at the ground of its
		-- wide layer and its core (the pen's are 0.7 and 0.35), full light emission, wider.
		beamBase = { 0.35, 0.05 },
		beamEmission = 1,
		beamWide = 1.4, -- width / the pen crate's
		-- Uncommon and Rare get a beam on the Smasher too (the pen's starts at Epic), so every
		-- rarity above Common reads from the pad: height and width in studs, sparkles a second.
		lowBeams = {
			[1] = { beam = 16, beamWidth = 2.2, motes = 2 },
			[2] = { beam = 22, beamWidth = 2.6, motes = 3 },
		} :: { [number]: { beam: number, beamWidth: number, motes: number } },
		foot = 0.95, -- studs from the plinth point down to the plinth's top
		disc = 2.5, -- glow disc radius in studs (+ discPerRank per rank)
		discPerRank = 0.3,
		discTransparency = 0.3, -- at its brightest (+ discPulse at its dimmest)
		discPulse = 0.3,
		discRate = 2.4, -- radians per second (+ 0.4 per rank)
		light = 9, -- PointLight range in studs (+ 1.5 per rank); none on "low" devices
		lightBrightness = 1.1,
		chip = 2.1, -- studs from the crate's centre up to the rarity word (clear of the gem)
		-- The rarity word over the Smasher's crate: drawn on top (the awning and a player on the
		-- pad stand in front of it), mostly a fixed pixel size so it reads from the pad and from
		-- the spawn view (54 studs) at 1280x720. Height = px + studs (scaled by distance), width
		-- per letter likewise.
		word = {
			px = 26, -- pixels of height at any distance ...
			studs = 0.9, -- ... plus this many studs
			letterPx = 17, -- width per letter: pixels ...
			letterStuds = 0.55, -- ... plus studs
			gap = 0.7, -- studs from the crate's top (or its gem) up to the word's middle
			range = 120, -- camera distance cap (the spawn view is 54 studs away)
			-- Share of its width it sits right of the crate on screen: the spawn view has the
			-- Smasher at the screen's left edge (crate centre at x 43 of 1280), where a centred
			-- word lost its first letters.
			lean = 0.38,
		},
		-- The pad's "CRATE SMASHER" name goes away while a crate is on the plinth (the rarity
		-- word over the crate fell on its letters at Common, Epic and Legendary) and comes
		-- back when the crate is gone.
		hideSign = true,
	},
	ritual = {
		shake = 0.85, -- seconds from the open to the burst
		link = 0.6, -- seconds within which a "ChestOpen" effect and a slot's change are one open
		-- Build-up: Crates.ritualShake, sparks, the camera leaning in.
		amp = { 0.05, 0.32 }, -- tilt in radians at the start and at the end
		rate = { 22, 46 }, -- radians per second of the rattle
		hop = 0.55, -- studs the crate has lifted off the plinth by the end
		sparkEvery = { 0.2, 0.07 }, -- seconds between spark puffs
		sparks = 3, -- sparkles per puff (+1 per rank)
		sparkSize = 1.2, -- studs
		zoom = 5, -- degrees of FOV the camera leans in by (only near the crate)
		near = 60, -- studs from the character within which the camera reacts
		lightFrom = 0.6, -- the build-up light's brightness at the start ...
		lightTo = 1.8, -- ... and at the burst (brighter washes the booth out to a pale ghost)
		lightRange = 10,
		-- While it shakes, the booth's pastel wash (World.Props' "PastelOverlay" Highlight)
		-- lifts so the machine shows its own solid colours, and the crate's wash turns into a
		-- bright rarity-coloured silhouette drawn over the booth.
		boothWash = 1, -- the booth's overlay fill transparency during the shake (1 = none)
		boothFade = 0.15, -- seconds to lift it, and to put it back after the burst ...
		boothBack = 0.6, -- ... that long after the burst
		boothReach = 12, -- studs from the plinth to the booth mesh
		crateFill = 0.25, -- the crate's own wash during the shake (drawn on top) ...
		crateRim = 0, -- ... and its outline
		-- Burst.
		flash = 7, -- studs across at the end of the flash (+ flashPerRank per rank)
		flashPerRank = 1.5,
		flashTime = 0.4,
		flashStart = 0.1, -- starting transparency
		flashWhiten = 0.55,
		glint = 7, -- the big 4-point glint sprite: studs across (+ glintPerRank)
		glintPerRank = 1.3,
		glintLife = 0.7,
		shock = 6, -- shock ring radius in studs (+ shockPerRank)
		shockPerRank = 1,
		burstSparks = 18, -- sparkles thrown (+ burstSparksPerRank)
		burstSparksPerRank = 5,
		burstSparkSize = 1.7, -- studs
		burstSparkSpeed = { 14, 26 }, -- studs per second
		beam = 26, -- height in studs of the short beam (+ beamPerRank)
		beamPerRank = 7,
		beamWidth = 2.6, -- studs (+ beamWidthPerRank)
		beamWidthPerRank = 0.7,
		beamIn = 0.12, -- seconds to open, to hold and to close
		beamHold = 0.3,
		beamOut = 0.5,
		beamCore = 0.35, -- the white core's width / the beam's
		lid = Vector3.new(3.05, 0.47, 3.6),
		lidTime = 1.25, -- seconds in the air
		lidSpeed = 25, -- studs per second up
		lidGravity = 40, -- studs per second squared down
		lidDrift = 4, -- studs per second away from the booth
		lidSpin = 10, -- radians per second
		lidStart = 0.9, -- studs above the crate's centre
		shards = 8, -- crate chunks thrown around (none on "low" devices)
		shardSize = 0.75, -- studs
		shardSpeed = { 9, 17 }, -- studs per second outward
		shardUp = { 12, 22 }, -- studs per second up
		shardTime = 1,
		punch = 0.35, -- Camera.punch intensity (+ punchPerRank)
		punchPerRank = 0.12,
		-- Existing sounds ("" = none).
		shakeSound = "CrateShake",
		burstSound = "MergeBoom",
		-- A crate opened on the spot.
		reach = 45, -- studs from the character to an empty plinth that takes the stand-in crate
		ahead = 6, -- else: studs in front of the character
		crate = Vector3.new(3.57, 3.15, 4.41), -- the stand-in crate (Fx.Machines' crate size)
		crateColor = (WORLD.Sunny or GOLD) :: Color3, -- its body, and every other shard
		strap = 0.34, -- studs across its two rarity straps
	},
}
Crates.SMASH = SMASH

-- One leg of the arrival. kind: "pop" | "hop" | "fall" | "slide" | "arc".
type Leg = {
	kind: string,
	from: Vector3,
	to: Vector3,
	t0: number,
	dur: number,
	apex: number,
	v0: number,
	accel: number,
	vmax: number,
	tumbles: number, -- quarter turns during this leg
	turned: number, -- quarter turns completed before it
	face: CFrame, -- facing during the leg (long side along the travel direction)
	faceFrom: CFrame, -- the previous leg's facing, turned from over the leg's start
}

-- The light beam of an Epic or Legendary crate, with its sparkles and light.
type Aura = {
	anchor: Part,
	beams: { Beam },
	widths: { number }, -- full width at the ground, per beam
	emitter: ParticleEmitter?,
	light: PointLight?,
}

type Crate = {
	model: Model,
	base: CFrame,
	parts: { BasePart },
	offsets: { CFrame },
	sizes: { Vector3 },
	bottom: number, -- lowest point relative to the pivot (negative)
	half: Vector3, -- half extents of the crate's box
	mid: number, -- height of the box's middle above the pivot
	rarity: string,
	rank: number,
	color: Color3,
	born: number, -- os.clock() of the arrival start (or long ago for no arrival)
	land: number, -- seconds from born to touchdown
	legs: { Leg },
	bounced: boolean,
	source: Model?,
	wiggleAt: number, -- os.clock() of the last "can't" wiggle start
	phase: number,
	wash: Highlight?,
	gem: Part?, -- one of `parts`, hidden until the landing
	aura: Aura?,
	disc: Part,
	chip: BillboardGui,
	chipOn: boolean,
	chipToken: number,
	shown: boolean,
	landed: boolean,
	restored: boolean,
	broken: boolean,
}

local crates: { [Model]: Crate } = {}
local crateCount = 0
local moveParts: { BasePart } = {}
local moveCFrames: { CFrame } = {}
local started = false

-- Helpers -------------------------------------------------------------------------------

local function fxPart(shape: Enum.PartType, name: string, color: Color3): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Shape = shape
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Material = Enum.Material.SmoothPlastic
	p.Color = color
	p.Size = Vector3.one
	p.CFrame = HIDDEN
	p.Parent = Orbs.getFolder()
	return p
end

local function rarityOf(model: Model): string
	local attr = model:GetAttribute("Rarity")
	if type(attr) == "string" and attr ~= "" then
		return attr
	end
	for _, name in Economy.CHEST_RARITIES do
		if string.find(model.Name, name, 1, true) == 1 then
			return name
		end
	end
	return "Common"
end

local function rankOf(rarity: string): number
	local index = table.find(Economy.CHEST_RARITIES, rarity)
	if index then
		return index - 1
	end
	return if rarity == "Mythic" then 5 else 1
end

local function backOut(x: number): number
	local c1 = 1.9
	local c3 = c1 + 1
	local y = x - 1
	return 1 + c3 * y * y * y + c1 * y * y
end

local function smooth(x: number): number
	local c = math.clamp(x, 0, 1)
	return c * c * (3 - 2 * c)
end

local function nearCamera(pos: Vector3, range: number): boolean
	local camera = Workspace.CurrentCamera
	return camera ~= nil and (camera.CFrame.Position - pos).Magnitude <= range
end

local function localRoot(): BasePart?
	local character = Players.LocalPlayer.Character
	return character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
end

local function playerNear(pos: Vector3, range: number): boolean
	local root = localRoot()
	return root ~= nil and (root.Position - pos).Magnitude <= range
end

local function holdingCrate(): boolean
	local held = State.data and State.data.heldChest
	return type(held) == "string" and held ~= ""
end

-- Body visibility, and the label / sparkles (only live once landed).
local function setShown(crate: Crate, body: boolean, extras: boolean)
	for _, part in crate.parts do
		part.LocalTransparencyModifier = if body then 0 else 1
	end
	for _, d in crate.model:GetDescendants() do
		if d:IsA("BillboardGui") or d:IsA("Sparkles") then
			d.Enabled = extras
		end
	end
	if crate.wash then
		Highlights.want(crate.wash, body)
	end
	if crate.gem then
		crate.gem.LocalTransparencyModifier = if extras then 0 else 1
	end
end

local function rarityColor(rarity: string): Color3
	return (Theme.Colors.Rarity and Theme.Colors.Rarity[rarity]) or WHITE
end

-- Rarity look ---------------------------------------------------------------------------

local function lookOf(rank: number): Look
	return LOOKS[math.clamp(rank, 0, TOP_RANK)]
end

-- Washes `adornee` toward `color` (a part Color would only darken the mesh's baked vertex
-- colours): an occluded Highlight fill, with an outline when `rim` is under 1. `priority` is its
-- class in Fx.Highlights' shared budget (Roblox draws at most 31 Highlights).
local function washOver(parent: Instance, adornee: Instance, color: Color3, fill: number, rim: number, priority: number): Highlight?
	if fill >= 1 and rim >= 1 then
		return nil
	end
	local h = Instance.new("Highlight")
	h.Name = DECOR
	h.DepthMode = Enum.HighlightDepthMode.Occluded
	h.FillColor = color
	h.FillTransparency = fill
	h.OutlineColor = color:Lerp(WHITE, RIM_WHITEN)
	h.OutlineTransparency = rim
	h.Adornee = adornee
	h.Parent = parent
	return Highlights.claim(h, priority)
end

local function clearDecor(model: Instance)
	for _, d in model:GetDescendants() do
		if d.Name == DECOR then
			d:Destroy()
		end
	end
end

local function decorPart(model: Model, color: Color3, size: Vector3, cf: CFrame, material: Enum.Material): Part
	local p = Instance.new("Part")
	p.Name = DECOR
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Material = material
	p.Color = color
	p.Size = size
	p.CFrame = cf
	p.Parent = model
	return p
end

-- The parts a rarity adds to the server's crate (they join the crate's `parts`, so they
-- tumble, squash and bob with it): piping round each strap ("Band") and a gem over the lid,
-- `top` studs above the pivot. Returns them, and the gem.
local function dress(model: Model, base: CFrame, look: Look, color: Color3, top: number): ({ Part }, Part?)
	local added: { Part } = {}
	local piping = look.piping
	if piping then
		for _, child in model:GetChildren() do
			if child:IsA("BasePart") and child.Name == "Band" then
				local size = Vector3.new(PIPING_WIDTH, child.Size.Y + PIPING_PROUD * 2, child.Size.Z + PIPING_PROUD * 2)
				table.insert(added, decorPart(model, piping, size, child.CFrame, Enum.Material.SmoothPlastic))
			end
		end
	end
	local gem: Part? = nil
	if look.gem > 0 then
		-- Half the cube's diagonal above the gap.
		local at = base * CFrame.new(0, top + GEM_GAP + look.gem * 0.87, 0) * GEM_TILT
		local made = decorPart(model, color:Lerp(WHITE, GEM_WHITEN), Vector3.one * look.gem, at, Enum.Material.Neon)
		table.insert(added, made)
		gem = made
	end
	return added, gem
end

-- The beam of an Epic or Legendary crate (nil below that): built dark, lit by lightAura.
local function makeAura(look: Look, color: Color3): Aura?
	if look.beam <= 0 then
		return nil
	end
	local anchor = fxPart(Enum.PartType.Block, "CrateBeam", color)
	anchor.Transparency = 1
	anchor.Size = BEAM_FOOT
	local foot = Instance.new("Attachment")
	foot.Parent = anchor
	local head = Instance.new("Attachment")
	head.Position = Vector3.new(0, look.beam, 0)
	head.Parent = anchor
	local beams: { Beam } = {}
	local widths: { number } = {}
	for i, layer in BEAM_LAYERS do
		local beam = Instance.new("Beam")
		beam.Name = "RarityBeam" .. i
		beam.Attachment0 = foot
		beam.Attachment1 = head
		beam.FaceCamera = true
		beam.Segments = 8
		beam.LightEmission = BEAM_EMISSION
		beam.LightInfluence = 0
		beam.Color = ColorSequence.new(color:Lerp(WHITE, BEAM_WHITEN), color)
		beam.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, layer.base),
			NumberSequenceKeypoint.new(0.55, layer.base + (1 - layer.base) * 0.4),
			NumberSequenceKeypoint.new(1, 1),
		})
		beam.Width0 = 0
		beam.Width1 = 0
		beam.Enabled = false
		beam.Parent = anchor
		beams[i] = beam
		widths[i] = look.beamWidth * layer.width
	end
	local emitter: ParticleEmitter? = nil
	if look.motes > 0 then
		emitter = Sprites.emitter(anchor, "Sparkle", {
			Color = ColorSequence.new(color:Lerp(WHITE, 0.45)),
			Rate = look.motes,
			Lifetime = NumberRange.new(1.8, 2.8),
			Speed = NumberRange.new(2.5, 4.5),
			SpreadAngle = Vector2.new(5, 5),
			EmissionDirection = Enum.NormalId.Top,
			Drag = 0,
			Acceleration = Vector3.new(0, 1.2, 0),
			Size = NumberSequence.new({
				NumberSequenceKeypoint.new(0, 0),
				NumberSequenceKeypoint.new(0.2, MOTE_SIZE),
				NumberSequenceKeypoint.new(1, 0),
			}),
			Enabled = false,
		})
	end
	local light: PointLight? = nil
	if look.light > 0 and not Budget.low() then
		local made = Instance.new("PointLight")
		made.Color = color
		made.Range = look.light
		made.Brightness = LIGHT_BRIGHTNESS
		made.Shadows = false
		made.Enabled = false
		made.Parent = anchor
		light = made
	end
	return { anchor = anchor, beams = beams, widths = widths, emitter = emitter, light = light }
end

-- Stands the beam on `floor` and switches it on (stepCrate opens its width).
local function lightAura(aura: Aura, floor: Vector3)
	aura.anchor.CFrame = CFrame.new(floor + UP * (BEAM_FOOT.Y / 2))
	for _, beam in aura.beams do
		beam.Enabled = true
	end
	if aura.emitter then
		aura.emitter.Enabled = true
	end
	if aura.light then
		aura.light.Enabled = true
	end
end

local function smokePuff(pos: Vector3, count: number, speed: number)
	local holder = fxPart(Enum.PartType.Block, "CrateDust", WHITE)
	holder.Size = Vector3.one * 0.2
	holder.Transparency = 1
	holder.CFrame = CFrame.new(pos)
	local emitter = Instance.new("ParticleEmitter")
	emitter.Texture = SMOKE
	emitter.Color = ColorSequence.new(Color3.fromRGB(225, 215, 200))
	emitter.LightEmission = 0
	emitter.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1.2),
		NumberSequenceKeypoint.new(1, 2.6),
	})
	emitter.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.4),
		NumberSequenceKeypoint.new(1, 1),
	})
	emitter.Lifetime = NumberRange.new(0.4, 0.7)
	emitter.Speed = NumberRange.new(speed * 0.6, speed)
	emitter.SpreadAngle = Vector2.new(85, 85)
	emitter.EmissionDirection = Enum.NormalId.Top
	emitter.Drag = 6
	if PUFF then
		emitter.Rotation = NumberRange.new(-180, 180)
		emitter.RotSpeed = NumberRange.new(-30, 30)
	end
	emitter.Rate = 0
	emitter.Parent = holder
	emitter:Emit(Budget.count(count))
	task.delay(1.2, function()
		holder:Destroy()
	end)
end

-- Rarity label ------------------------------------------------------------------------

-- The rarity word ("Common", ...) as floating bold text in the rarity colour with a dark Ink
-- outline, parented to the client-only ground disc and adorned to the crate's primary part so
-- it follows the bob.
local function makeChip(rarity: string, color: Color3, adornee: BasePart, above: number, parent: Instance): BillboardGui
	local word = string.upper(string.sub(rarity, 1, 1)) .. string.lower(string.sub(rarity, 2))
	local gui = Instance.new("BillboardGui")
	gui.Name = "RarityChip"
	gui.Adornee = adornee
	gui.AlwaysOnTop = false
	gui.LightInfluence = 0
	gui.MaxDistance = CHIP_RANGE
	gui.Size = UDim2.new((0.6 + #word * 0.82) * CHIP_SCALE, #word * CHIP_PX_PER_LETTER, CHIP_HEIGHT * CHIP_SCALE, CHIP_PX_HEIGHT)
	gui.StudsOffset = Vector3.new(0, above + 0.3, 0)
	gui.Enabled = false
	gui.Parent = parent
	local pill = Instance.new("Frame")
	pill.Name = "Pill"
	pill.AnchorPoint = Vector2.new(0.5, 0.5)
	pill.Position = UDim2.fromScale(0.5, 0.5)
	pill.Size = UDim2.fromScale(1, 1)
	pill.BackgroundTransparency = 1
	pill.BorderSizePixel = 0
	pill.Parent = gui
	local scale = Instance.new("UIScale")
	scale.Scale = 0.7
	scale.Parent = pill
	local text = Instance.new("TextLabel")
	text.Name = "Word"
	text.BackgroundTransparency = 1
	text.AnchorPoint = Vector2.new(0.5, 0.5)
	text.Position = UDim2.fromScale(0.5, 0.5)
	text.Size = UDim2.fromScale(1, 1)
	text.Font = Theme.Fonts.Title
	text.TextScaled = true
	text.Text = word
	text.TextColor3 = color
	text.TextTransparency = 1
	text.Parent = pill
	local outline = Instance.new("UIStroke")
	outline.Color = INK
	outline.Thickness = 2.5
	outline.LineJoinMode = Enum.LineJoinMode.Round
	outline.Transparency = 1
	outline.Parent = text
	return gui
end

-- Fades the crate's label in (small grow) or out (then disables it).
local function fadeChip(crate: Crate, on: boolean)
	if crate.chipOn == on then
		return
	end
	crate.chipOn = on
	crate.chipToken += 1
	local token = crate.chipToken
	local gui = crate.chip
	local pill = gui:FindFirstChild("Pill") :: Frame?
	local text = pill and pill:FindFirstChild("Word") :: TextLabel?
	if not pill or not text then
		return
	end
	local outline = text:FindFirstChildOfClass("UIStroke") :: UIStroke
	local scale = pill:FindFirstChildOfClass("UIScale") :: UIScale
	local info = if on
		then TweenInfo.new(0.22, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
		else TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
	if on then
		gui.Enabled = true
	end
	TweenService:Create(outline, info, { Transparency = if on then 0 else 1 }):Play()
	local grow = if on then TweenInfo.new(0.26, Enum.EasingStyle.Back, Enum.EasingDirection.Out) else info
	TweenService:Create(scale, grow, { Scale = if on then 1 else 0.7 }):Play()
	local fade = TweenService:Create(text, info, { TextTransparency = if on then 0 else 1 })
	if not on then
		fade.Completed:Once(function()
			if crate.chipToken == token then
				gui.Enabled = false
			end
		end)
	end
	fade:Play()
end

-- True while the held-crate panel is open (PlayerGui.TycoonUI's CratePanelOpen attribute).
local function cratePanelOpen(): boolean
	local playerGui = Players.LocalPlayer:FindFirstChildOfClass("PlayerGui")
	local ui = playerGui and playerGui:FindFirstChild("TycoonUI")
	return ui ~= nil and ui:GetAttribute("CratePanelOpen") == true
end

local lastChipScan = 0

-- Labels show over every landed crate (BillboardGui.MaxDistance limits the range), except
-- while the held-crate panel is open.
local function scanChips(now: number)
	if now - lastChipScan < CHIP_SCAN then
		return
	end
	lastChipScan = now
	local hidden = cratePanelOpen()
	local camera = Workspace.CurrentCamera
	-- Candidates nearest first; each one shows unless a nearer shown label covers its spot.
	local wanted: { { crate: Crate, dist: number, at: Vector2, size: Vector2 } } = {}
	for model, crate in crates do
		local want = crate.landed and model.Parent ~= nil and not hidden
		if want and camera then
			local gui = crate.chip
			local adornee = gui.Adornee :: BasePart?
			local world = if adornee then adornee.Position + gui.StudsOffset else nil
			local dist = if world then (world - camera.CFrame.Position).Magnitude else math.huge
			if world and dist <= gui.MaxDistance then
				local v, onScreen = camera:WorldToViewportPoint(world)
				if onScreen then
					-- The chip's size at this distance: its stud part shrinks, its pixel part stays.
					local perStud = camera.ViewportSize.Y / (2 * dist * math.tan(math.rad(camera.FieldOfView / 2)))
					local size = Vector2.new(gui.Size.X.Scale * perStud + gui.Size.X.Offset, gui.Size.Y.Scale * perStud + gui.Size.Y.Offset)
					table.insert(wanted, { crate = crate, dist = dist, at = Vector2.new(v.X, v.Y), size = size })
					continue
				end
			end
		end
		fadeChip(crate, want)
	end
	table.sort(wanted, function(a, b)
		return a.dist < b.dist
	end)
	local shown = {}
	for _, w in wanted do
		local free = true
		for _, o in shown do
			local reach = (w.size + o.size) / 2 * CHIP_OVERLAP
			local gap = w.at - o.at
			if math.abs(gap.X) < reach.X and math.abs(gap.Y) < reach.Y then
				free = false
				break
			end
		end
		if free then
			table.insert(shown, w)
		end
		fadeChip(w.crate, free)
	end
end

-- Places every part: `cf` is the animated pivot; (sx, sy) scale around the crate bottom.
local function place(crate: Crate, cf: CFrame, sx: number, sy: number)
	local scaled = sx ~= 1 or sy ~= 1
	local scale = Vector3.new(sx, sy, sx)
	local bottom = Vector3.new(0, crate.bottom, 0)
	for i, part in crate.parts do
		local offset = crate.offsets[i]
		if scaled then
			local p = (offset.Position - bottom) * scale + bottom
			offset = CFrame.new(p) * offset.Rotation
			part.Size = crate.sizes[i] * scale
		elseif not crate.restored then
			part.Size = crate.sizes[i]
		end
		table.insert(moveParts, part)
		table.insert(moveCFrames, cf * offset)
	end
	crate.restored = not scaled
end

-- Arrival route ---------------------------------------------------------------------------

-- Distance covered after t seconds starting at v0, accelerating at `a` up to vmax.
local function accelDist(t: number, v0: number, a: number, vmax: number): number
	local tCap = math.max((vmax - v0) / a, 0)
	if t <= tCap then
		return v0 * t + 0.5 * a * t * t
	end
	return v0 * tCap + 0.5 * a * tCap * tCap + vmax * (t - tCap)
end

-- Time to cover `len`, and the speed at the end.
local function accelTime(len: number, v0: number, a: number, vmax: number): (number, number)
	local tCap = math.max((vmax - v0) / a, 0)
	local dCap = v0 * tCap + 0.5 * a * tCap * tCap
	if len <= dCap then
		local t = (-v0 + math.sqrt(v0 * v0 + 2 * a * len)) / a
		return t, v0 + a * t
	end
	return tCap + (len - dCap) / vmax, vmax
end

local function readRoute(model: Model): Orbs.Route?
	return Orbs.readRoute(model, "Path")
end

local function flatDir(v: Vector3): Vector3?
	local f = Vector3.new(v.X, 0, v.Z)
	return if f.Magnitude > 1e-3 then f.Unit else nil
end

-- Builds the arrival legs; returns them and the touchdown time.
local function buildLegs(route: Orbs.Route?, landing: Vector3): ({ Leg }, number)
	local legs: { Leg } = {}
	local t, turned = 0, 0
	local function add(kind: string, from: Vector3, to: Vector3, dur: number, tumbles: number, apex: number?)
		table.insert(legs, {
			kind = kind,
			from = from,
			to = to,
			t0 = t,
			dur = dur,
			apex = apex or 0,
			v0 = 0,
			accel = 0,
			vmax = 0,
			tumbles = tumbles,
			turned = turned,
			face = CFrame.identity,
			faceFrom = CFrame.identity,
		})
		t += dur
		turned += tumbles
		return legs[#legs]
	end
	local chuteEnd: Vector3
	-- Facing for the fall: along the gutter, so the crate's long side never points into the rack.
	local fallFace: Vector3? = nil
	if route then
		local feet, drop, gutter, top, bottom = route.feet, route.drop, route.gutter, route.chuteTop, route.chuteBottom
		-- Pops out just in front of the Chad, hops low (under the shelf above) to the drop point.
		local out = flatDir(drop - feet) or flatDir(gutter - feet) or Vector3.new(0, 0, -1)
		local start = feet + out * POP_FORWARD + UP * POP_UP
		add("pop", start, start, POP, 0)
		local hopLen = Vector3.new(drop.X - start.X, 0, drop.Z - start.Z).Magnitude
		add("hop", start, drop, math.clamp(0.3 + hopLen * 0.025, HOP_MIN, HOP_MAX), 1, HOP_APEX)
		-- Falls with gravity-like easing (capped so the top shelf stays snappy) and bounces.
		local fall = drop.Y - gutter.Y
		if fall > 0.05 or (drop - gutter).Magnitude > 0.05 then
			local dur = math.clamp(math.sqrt(2 * math.max(fall, 0) / FALL_G), 0.12, FALL_MAX)
			add("fall", drop, gutter, dur, if fall > 12 then 1 else 0)
			fallFace = flatDir(top - gutter) or Vector3.xAxis
		end
		local gDir = flatDir(top - gutter)
		local gLen = (top - gutter).Magnitude
		local bounce = math.clamp(fall * 0.03, 0.25, 0.9)
		local hop = if gDir then math.min(gLen * 0.3, 1.2) else 0
		local landed = gutter + (if gDir then gDir * hop else Vector3.zero)
		add("arc", gutter, landed, 0.12 + bounce * 0.2, 0, bounce)
		local sLen = (top - landed).Magnitude
		local vEnd = GUTTER_V0
		if sLen > 0.05 then
			local dur, v = accelTime(sLen, GUTTER_V0, GUTTER_ACCEL, GUTTER_VMAX)
			local leg = add("slide", landed, top, dur, if sLen > 6 then 1 else 0)
			leg.v0, leg.accel, leg.vmax = GUTTER_V0, GUTTER_ACCEL, GUTTER_VMAX
			vEnd = v
		end
		local cLen = (bottom - top).Magnitude
		if cLen > 0.05 then
			local v0 = math.clamp(vEnd * 0.8, 3, CHUTE_VMAX)
			local dur = accelTime(cLen, v0, CHUTE_ACCEL, CHUTE_VMAX)
			local leg = add("slide", top, bottom, dur, 1)
			leg.v0, leg.accel, leg.vmax = v0, CHUTE_ACCEL, CHUTE_VMAX
		end
		chuteEnd = bottom
	else
		chuteEnd = landing + UP * FALLBACK_DROP
		add("pop", chuteEnd, chuteEnd, POP, 0)
	end
	local mid = chuteEnd:Lerp(landing, BOUNCE1_SHARE)
	mid = Vector3.new(mid.X, landing.Y, mid.Z)
	add("arc", chuteEnd, mid, BOUNCE1, 1, BOUNCE1_APEX)
	add("arc", mid, landing, BOUNCE2, 0, BOUNCE2_APEX)

	-- Facing per leg (long side along the travel direction), turning smoothly from the
	-- previous leg's. Legs without horizontal travel keep the facing they inherit.
	local dirs: { Vector3? } = {}
	for i, leg in legs do
		dirs[i] = if leg.kind == "fall" then fallFace else flatDir(leg.to - leg.from)
	end
	local prev: Vector3? = nil
	for i = 1, #legs do
		prev = dirs[i] or prev
		if not prev then
			for j = i + 1, #legs do
				prev = prev or dirs[j]
			end
		end
		dirs[i] = prev
	end
	local last = CFrame.identity
	for i, leg in legs do
		local d = dirs[i]
		leg.face = if d then CFrame.fromMatrix(Vector3.zero, d, UP) else CFrame.identity
		leg.faceFrom = if i == 1 then leg.face else last
		last = leg.face
	end
	return legs, t
end

-- Pivot CFrame and uniform scale at `t` seconds into the arrival (t < crate.land).
local function sampleArrival(crate: Crate, t: number): (CFrame, number)
	local legs = crate.legs
	local leg = legs[#legs]
	for _, l in legs do
		if t < l.t0 + l.dur then
			leg = l
			break
		end
	end
	local u = math.clamp((t - leg.t0) / math.max(leg.dur, 1e-3), 0, 1)
	local pos: Vector3
	if leg.kind == "slide" then
		local len = (leg.to - leg.from).Magnitude
		local s = math.min(accelDist(t - leg.t0, leg.v0, leg.accel, leg.vmax), len)
		pos = leg.from:Lerp(leg.to, if len > 0 then s / len else 1)
	elseif leg.kind == "pop" then
		pos = leg.from
	elseif leg.kind == "fall" then
		pos = leg.from:Lerp(leg.to, u * u)
	else
		pos = leg.from:Lerp(leg.to, u) + UP * (leg.apex * 4 * u * (1 - u))
	end

	-- Facing: the long side along the direction of travel, turning in over the leg's start.
	local facing = leg.faceFrom:Lerp(leg.face, smooth(u / 0.35))

	-- Quarter-turn tumbles, centred in the leg, rising onto an edge mid-turn.
	local spin = leg.turned
	if leg.tumbles > 0 then
		spin += leg.tumbles * smooth((u - 0.3) / 0.4)
	end
	local wobble = 0
	if leg.kind == "slide" then
		wobble = 1
	end
	local wob = CFrame.Angles(math.sin(t * 13) * 0.12 * wobble, math.sin(t * 7.5) * 0.08 * wobble, 0)
	local rot = facing * wob * CFrame.Angles(0, 0, -spin * math.pi / 2)

	-- Grow back to full size and turn to the resting angle over the two bounces.
	local scale = TRAVEL_SCALE
	if leg.kind == "pop" then
		scale = TRAVEL_SCALE * backOut(u)
	end
	local bounceStart = legs[#legs - 1].t0
	if t >= bounceStart then
		local g = smooth((t - bounceStart) / (crate.land - bounceStart))
		scale = TRAVEL_SCALE + (1 - TRAVEL_SCALE) * g
		rot = rot:Lerp(crate.base.Rotation, smooth((t - bounceStart) / (crate.land - bounceStart) * 1.3 - 0.3))
	end
	scale = math.max(scale, 0.02)

	-- Turn about the (scaled) box's middle and rest it on the surface below the path point,
	-- so it rises onto an edge mid-tumble and lies flat on any face.
	local half = crate.half
	local upLocal = rot:VectorToObjectSpace(UP)
	local support = scale * (math.abs(upLocal.X) * half.X + math.abs(upLocal.Y) * half.Y + math.abs(upLocal.Z) * half.Z)
	local surfaceY = pos.Y + crate.bottom
	local midLocal = (crate.mid - crate.bottom) * scale + crate.bottom
	local centre = Vector3.new(pos.X, surfaceY + support, pos.Z)
	return CFrame.new(centre) * rot * CFrame.new(0, -midLocal, 0), scale
end

-- The Chad standing at the crate's Origin, if it is one of this plot's units.
local function sourceUnit(model: Model): Model?
	local origin = model:GetAttribute("Origin")
	local plot = model.Parent and model.Parent.Parent
	local units = plot and plot:FindFirstChild("Units")
	if typeof(origin) ~= "Vector3" or not units then
		return nil
	end
	local best, bestDist = nil, 2
	for _, unit in units:GetChildren() do
		if unit:IsA("Model") then
			local d = (unit:GetPivot().Position - origin).Magnitude
			if d < bestDist then
				best, bestDist = unit, d
			end
		end
	end
	return best
end

-- Spawn / idle --------------------------------------------------------------------------

local function thud(crate: Crate, floor: Vector3, k: number)
	local size = (1 + crate.rank * 0.25) * k
	Orbs.ring(floor + Vector3.new(0, 0.12, 0), Color3.fromRGB(235, 225, 210), 4.5 * size, 0.45, 0.3)
	Orbs.ring(floor + Vector3.new(0, 0.18, 0), crate.color, 3 * size, 0.5, 0.1)
	smokePuff(floor + Vector3.new(0, 0.3, 0), math.floor((8 + crate.rank * 2) * k), 9 * k)
	if k >= 1 then
		Orbs.sparkle(floor + Vector3.new(0, 1.5, 0), crate.color, 10 + crate.rank * 3, 0.9 + crate.rank * 0.1)
		if crate.rank >= 2 then
			if playerNear(floor, 70) then
				Camera.shake(0.04 + crate.rank * 0.04, 0.2)
			end
		end
	end
end

local function stepCrate(crate: Crate, now: number)
	local base = crate.base
	local t = now - crate.born
	local floor = base.Position + Vector3.new(0, crate.bottom, 0)
	local rank = crate.rank

	if t < crate.land then
		if not crate.shown then
			crate.shown = true
			setShown(crate, true, false)
			local start = crate.legs[1].from
			smokePuff(start, 6, 6)
			Sounds.play("Tick", 0.1, 0.6 + rank * 0.1)
			if crate.source then
				Animator.show(crate.source, nil, 0.8, 0.6)
			end
		end
		local last = crate.legs[#crate.legs]
		if not crate.bounced and t >= last.t0 then
			crate.bounced = true
			thud(crate, last.from + Vector3.new(0, crate.bottom, 0), 0.5)
		end
		local cf, s = sampleArrival(crate, t)
		place(crate, cf, s, s)
		return
	end
	if not crate.landed then
		crate.landed = true
		setShown(crate, true, true)
		thud(crate, floor, 1)
		if crate.aura then
			lightAura(crate.aura, floor)
		end
	end
	local q = t - crate.land
	local idleT = now + crate.phase
	-- Idle motion fades in after the landing so the two blend.
	local blend = smooth((q - SQUASH * 0.5) / 0.6)
	local amp = 0.15 + rank * 0.07
	local lift = amp * (0.5 - 0.5 * math.cos(idleT * 2.2)) * blend
	local yaw = (idleT * (0.3 + rank * 0.08)) % (math.pi * 2)
	local sway = math.sin(idleT * 1.6) * (0.03 + rank * 0.01) * blend
	-- "Can't" wiggle: the player stands in pickup range but already holds a crate.
	if q > SQUASH and now - crate.wiggleAt >= CratePickup.WIGGLE_GAP and holdingCrate() then
		local root = localRoot()
		local offset = root and base.Position - root.Position
		if offset and CratePickup.inRange(offset.X, offset.Y, offset.Z) then
			crate.wiggleAt = now
			Sounds.play("Tick", 0.06, 0.45)
		end
	end
	local w = now - crate.wiggleAt
	local wiggle = if w < WIGGLE then math.sin(w / WIGGLE * math.pi * 4) * 0.14 * (1 - w / WIGGLE) else 0
	local cf = base * CFrame.new(0, lift, 0) * CFrame.Angles(0, yaw * blend, 0) * CFrame.Angles(sway, 0, sway * 0.6 + wiggle)
	if q < SQUASH then
		-- Damped spring: squash flat on impact, overshoot tall, settle.
		local sy = 1 - 0.34 * math.exp(-6 * q) * math.cos(q * 16)
		place(crate, cf, 1 / math.sqrt(sy), sy)
	else
		place(crate, cf, 1, 1)
	end

	-- Soft ground disc, gently pulsing, sized by rarity.
	local pulse = 0.5 + 0.5 * math.sin(now * (1.6 + rank * 0.35) + crate.phase)
	local landIn = math.clamp(q / 0.3, 0, 1)
	local radius = (2.2 + rank * 0.35) * (1 + 0.08 * pulse - lift * 0.15) * backOut(landIn)
	crate.disc.Size = Vector3.new(0.05, math.max(radius * 2, 0.05), math.max(radius * 2, 0.05))
	crate.disc.CFrame = CFrame.new(floor + Vector3.new(0, 0.07, 0)) * UPRIGHT
	local quiet = if rank == 0 then 0.82 else 0.7 - rank * 0.06
	crate.disc.Transparency = math.clamp(quiet - 0.12 * pulse, 0.35, 0.95)

	-- The beam opens after the landing, then breathes.
	local aura = crate.aura
	if aura then
		local open = smooth(q / BEAM_OPEN) * (1 + BEAM_BREATH * math.sin(now * BEAM_BREATH_RATE + crate.phase))
		for i, beam in aura.beams do
			local width = aura.widths[i] * open
			beam.Width0 = width
			beam.Width1 = width * BEAM_TAPER
		end
	end
end

-- Crate Smasher ---------------------------------------------------------------------------

type Smasher = {
	centre: Vector3, -- ring centre, on the court under the pad
	plinth: Vector3, -- where the Smasher's crate stands
	out: Vector3, -- flat unit vector from the plinth toward the pad
	segments: { Part }, -- clockwise seen from above, starting on the booth's side
	rarity: string, -- "" = empty slot
	color: Color3,
	total: number, -- seconds of the whole timer
	endsAt: number, -- os.clock() at which it ends
	seen: boolean, -- a snapshot was read since the bind (changes after it happen live)
	lit: number, -- segments painted in the rarity colour; -1 = repaint them all
	blink: number, -- phase of the next segment's blink
	washUntil: number, -- os.clock() until which Fx.Machines' crate is looked for
	nextWash: number,
	-- The rarity look on Fx.Machines' crate (dressSmasherCrate); nothing without one.
	body: BasePart?, -- that crate's body: the added parts follow it
	decor: { BasePart }, -- piping, inside the crate's model
	decorOffsets: { CFrame }, -- relative to the body
	gem: Part?,
	gemRest: CFrame, -- the gem's spot over the lid, relative to the body
	aura: Aura?,
	glow: Part?, -- the disc on the plinth; carries the light and the rarity word
	dressedAt: number,
	-- The pad's floating "CRATE SMASHER" name (World.Pads' "PadLabel"): hidden while a crate
	-- is dressed, as the rarity word over the crate lands on it (SMASH.look.hideSign).
	sign: BillboardGui?,
	pad: BasePart,
}

-- Something a burst throws (the lid, crate shards): ballistic, spinning, fading at the end.
type Lid = { part: Part, from: Vector3, vel: Vector3, yaw: number, spin: number, t0: number, life: number }

-- One opening in progress: the build-up until `burstAt`.
type Ritual = {
	rarity: string,
	color: Color3,
	rank: number,
	pos: Vector3, -- the crate's centre
	out: Vector3, -- the lid drifts this way
	t0: number,
	burstAt: number,
	nextSpark: number,
	flip: boolean,
	smasher: Smasher?, -- its court ring flickers
	claimed: boolean, -- the "ChestOpen" effect of this open was seen
	near: boolean, -- the character is close: the camera leans in and punches
	parts: { BasePart }?, -- the stand-in crate of an open on the spot
	base: CFrame,
	holder: Part?, -- carries the build-up light
	light: PointLight?,
	booth: Highlight?, -- the Smasher booth's pastel wash, lifted while it shakes ...
	boothFill: number, -- ... and its fill transparency to put back
}

local smashers: { [number]: Smasher } = {}
local smasherPlot: Instance? = nil

-- The pastel wash ("PastelOverlay", World.Props.overlay) of the booth mesh nearest to `plinth`.
local function boothWash(plinth: Vector3): Highlight?
	local plot = smasherPlot
	if not plot then
		return nil
	end
	local best: Highlight?, bestDist = nil, SMASH.ritual.boothReach
	for _, d in plot:GetDescendants() do
		local mesh = d.Parent
		if d:IsA("Highlight") and d.Name == "PastelOverlay" and mesh and mesh:IsA("BasePart") then
			local flat = Vector3.new(mesh.Position.X - plinth.X, 0, mesh.Position.Z - plinth.Z).Magnitude
			if flat < bestDist then
				best, bestDist = d, flat
			end
		end
	end
	return best
end
local lids: { Lid } = {}
local rituals: { Ritual } = {}
-- The burst the cards wait for: its os.clock() time and rarity, when the "ChestOpen" effect
-- behind it came, and that effect's token while it still waits for its slot's change.
local burst = { at = 0, rarity = "", effectAt = -math.huge, pending = 0, token = 0 }

local function paintRing(s: Smasher, lit: number)
	s.lit = lit
	for k, seg in s.segments do
		if s.rarity == "" then
			seg.Transparency = 1
		elseif k <= lit then
			seg.Color = s.color
			seg.Material = Enum.Material.Neon
			seg.Transparency = RING_LIT
		else
			seg.Color = INK
			seg.Material = Enum.Material.SmoothPlastic
			seg.Transparency = RING_UNLIT
		end
	end
end

-- Takes the rarity look off a slot (its crate is gone, or another one is being dressed).
local function clearSmasherDress(s: Smasher)
	if s.aura then
		s.aura.anchor:Destroy()
		s.aura = nil
	end
	if s.glow then
		s.glow:Destroy()
		s.glow = nil
	end
	-- The piping and the gem live in the crate's model: gone with it, or taken off here.
	for _, part in s.decor do
		part:Destroy()
	end
	if s.gem then
		s.gem:Destroy()
	end
	table.clear(s.decor)
	table.clear(s.decorOffsets)
	s.body, s.gem = nil, nil
	if s.sign then
		s.sign.Enabled = true
	end
end

-- Builds the ring of every Smasher pad of `plot` that has replicated (called again until
-- both have); another plot drops the old rings first.
local function bindSmashers(plot: Instance)
	if plot ~= smasherPlot then
		smasherPlot = plot
		for _, s in smashers do
			for _, seg in s.segments do
				seg:Destroy()
			end
			clearSmasherDress(s)
		end
		table.clear(smashers)
		-- This plot's booth washes outrank the other plots' in the Highlight budget.
		for _, d in plot:GetDescendants() do
			if d:IsA("Highlight") and d.Name == "PastelOverlay" then
				Highlights.claim(d, Highlights.PRIORITY.Booth)
			end
		end
	end
	for i = 1, 2 do
		local pad = if smashers[i] then nil else plot:FindFirstChild("Pad_Unlock" .. i, true)
		if not pad or not pad:IsA("BasePart") then
			continue
		end
		-- The pad's plinth: the nearest HoloCrate ghost (as Fx.Machines matches them).
		local holo: BasePart?, holoDist = nil, SMASHER_REACH
		for _, d in plot:GetDescendants() do
			if d.Name == "HoloCrate" and d:IsA("BasePart") then
				local dist = (d.Position - pad.Position).Magnitude
				if dist < holoDist then
					holo, holoDist = d, dist
				end
			end
		end
		local centre = pad.Position + UP * (pad.Size.Y / 2 - RING_BELOW_PAD + RING_HEIGHT / 2)
		local plinth = if holo then holo.Position else centre + UP * 2.5
		local out = flatDir(centre - plinth) or Vector3.xAxis
		-- Twelve o'clock is the booth; clockwise seen from above.
		local forward = -out
		local right = forward:Cross(UP)
		local arc = 2 * math.pi * RING_RADIUS / RING_SEGMENTS
		local segments: { Part } = {}
		for k = 1, RING_SEGMENTS do
			local angle = (k - 0.5) / RING_SEGMENTS * 2 * math.pi
			local dir = forward * math.cos(angle) + right * math.sin(angle)
			local seg = fxPart(Enum.PartType.Block, "SmasherRing", INK)
			seg.Size = Vector3.new(arc * RING_FILL, RING_HEIGHT, RING_WIDTH)
			seg.Transparency = 1
			-- Long side along the circle.
			seg.CFrame = CFrame.lookAt(centre + dir * RING_RADIUS, centre + dir * (RING_RADIUS + 1))
			segments[k] = seg
		end
		smashers[i] = {
			centre = centre,
			plinth = plinth,
			out = out,
			segments = segments,
			rarity = "",
			color = WHITE,
			total = 1,
			endsAt = 0,
			seen = false,
			lit = -1,
			blink = 0,
			washUntil = 0,
			nextWash = 0,
			decor = {},
			decorOffsets = {},
			gemRest = CFrame.identity,
			dressedAt = 0,
			pad = pad,
		}
	end
end

-- Opening ritual ----------------------------------------------------------------------------

-- Tells the cards when the burst of the open in progress happens (see the header).
local function publish(at: number, rarity: string)
	burst.at, burst.rarity = at, rarity
	pcall(function()
		local player = Players.LocalPlayer
		player:SetAttribute("CrateBurstAt", at)
		player:SetAttribute("CrateBurstRarity", rarity)
	end)
end

-- How a crate `u` (0..1) of the way through its build-up shakes: a tilt and a rattle that
-- grow, and a slow lift off the plinth. Fx.Machines plays it on its Smasher crate.
function Crates.ritualShake(u: number, now: number): CFrame
	local R = SMASH.ritual
	local e = u * u
	local amp = R.amp[1] + (R.amp[2] - R.amp[1]) * e
	local rate = R.rate[1] + (R.rate[2] - R.rate[1]) * u
	return CFrame.new(0, R.hop * e + math.abs(math.sin(now * rate)) * amp, 0)
		* CFrame.Angles(math.sin(now * rate * 1.3) * amp, math.sin(now * rate * 0.7) * amp * 0.6, math.sin(now * rate) * amp)
end

-- 0..1 through the build-up of the ritual at `pos` (a Smasher plinth), nil when none runs.
function Crates.ritualAt(pos: Vector3): number?
	local now = os.clock()
	for _, r in rituals do
		if (r.pos - pos).Magnitude < SMASHER_CRATE_REACH then
			return math.clamp((now - r.t0) / math.max(r.burstAt - r.t0, 0.05), 0, 1)
		end
	end
	return nil
end

-- os.clock() of the burst of the open in progress (in the past: nothing to wait for).
function Crates.burstAt(): number
	return burst.at
end

-- Yields until the burst of the open in progress has happened, at most `maxWait` seconds
-- (default 1.5), and returns its rarity. Call it on the "ChestOpen" effect; one frame of
-- grace covers this module handling that effect after the caller.
function Crates.awaitBurst(maxWait: number?): string?
	local limit = os.clock() + (maxWait or 1.5)
	task.wait()
	while os.clock() < burst.at and os.clock() < limit do
		task.wait()
	end
	return if burst.rarity ~= "" then burst.rarity else nil
end

-- A one-off throw of big sparkles from its own emitter (Orbs.sparkle's shared budget is
-- spent by the build-up).
local function sparkBurst(pos: Vector3, color: Color3, count: number, size: number, speed: { number })
	local holder = fxPart(Enum.PartType.Block, "CrateSparks", color)
	holder.Size = Vector3.one * 0.2
	holder.Transparency = 1
	holder.CFrame = CFrame.new(pos)
	local emitter = Sprites.emitter(holder, "Sparkle", {
		Color = ColorSequence.new(color:Lerp(WHITE, 0.6), color),
		Lifetime = NumberRange.new(0.5, 0.95),
		Speed = NumberRange.new(speed[1], speed[2]),
		SpreadAngle = Vector2.new(180, 180),
		Drag = 3,
		Acceleration = Vector3.new(0, -14, 0),
		Size = NumberSequence.new({
			NumberSequenceKeypoint.new(0, size * 0.4),
			NumberSequenceKeypoint.new(0.2, size),
			NumberSequenceKeypoint.new(1, 0),
		}),
	})
	if not emitter then
		holder:Destroy()
		Orbs.sparkle(pos, color, count, 1.6, size)
		return
	end
	emitter:Emit(Budget.count(count))
	task.delay(1.2, function()
		holder:Destroy()
	end)
end

-- The short beam of a burst: a rarity-coloured column with a white core that snaps open
-- from `foot`, holds and closes.
local function burstBeam(foot: Vector3, color: Color3, height: number, width: number)
	local R = SMASH.ritual
	local anchor = fxPart(Enum.PartType.Block, "CrateBurstBeam", color)
	anchor.Size = Vector3.one * 0.2
	anchor.Transparency = 1
	anchor.CFrame = CFrame.new(foot)
	local a0 = Instance.new("Attachment")
	a0.Parent = anchor
	local a1 = Instance.new("Attachment")
	a1.Position = Vector3.new(0, height, 0)
	a1.Parent = anchor
	for i = 1, 2 do
		local core = i == 2
		local beam = Instance.new("Beam")
		beam.Name = "BurstBeam" .. i
		beam.Attachment0 = a0
		beam.Attachment1 = a1
		beam.FaceCamera = true
		beam.Segments = 6
		beam.LightEmission = if core then 1 else BEAM_EMISSION
		beam.LightInfluence = 0
		beam.Color = ColorSequence.new(if core then WHITE else color:Lerp(WHITE, BEAM_WHITEN), color)
		beam.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, if core then 0.1 else 0.3),
			NumberSequenceKeypoint.new(0.7, 0.6),
			NumberSequenceKeypoint.new(1, 1),
		})
		beam.Width0 = 0
		beam.Width1 = 0
		beam.Parent = anchor
		local wide = width * (if core then R.beamCore else 1)
		TweenService:Create(
			beam,
			TweenInfo.new(R.beamIn, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
			{ Width0 = wide, Width1 = wide * BEAM_TAPER }
		):Play()
		task.delay(R.beamIn + R.beamHold, function()
			TweenService:Create(beam, TweenInfo.new(R.beamOut, Enum.EasingStyle.Quad, Enum.EasingDirection.In), { Width0 = 0, Width1 = 0 })
				:Play()
		end)
	end
	task.delay(R.beamIn + R.beamHold + R.beamOut + 0.1, function()
		anchor:Destroy()
	end)
end

-- The burst that ends a ritual at `pos`: flash, glint, shock rings, sparkles and the short
-- beam in the rarity colour, the lid flying off along `out` and shards all around.
local function burstOpen(pos: Vector3, out: Vector3, rarity: string, color: Color3, near: boolean)
	if not nearCamera(pos, CULL) then
		return
	end
	local R = SMASH.ritual
	local rank = math.clamp(rankOf(rarity), 0, TOP_RANK + 1)
	local flash = fxPart(Enum.PartType.Ball, "CrateFlash", color:Lerp(WHITE, R.flashWhiten))
	flash.Material = Enum.Material.Neon
	flash.Transparency = R.flashStart
	flash.CFrame = CFrame.new(pos)
	TweenService:Create(flash, TweenInfo.new(R.flashTime, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Size = Vector3.one * (R.flash + rank * R.flashPerRank),
		Transparency = 1,
	}):Play()
	task.delay(R.flashTime + 0.1, function()
		flash:Destroy()
	end)
	Orbs.sprite("Sparkle", {
		position = pos + UP * 0.6,
		size = R.glint + rank * R.glintPerRank,
		rise = UP * 1.2,
		life = R.glintLife,
		color = color:Lerp(WHITE, 0.45),
		spin = 90,
		maxDistance = 220,
	})
	Orbs.shock(pos - UP * 0.8, color, R.shock + rank * R.shockPerRank)
	sparkBurst(pos + UP * 0.5, color, R.burstSparks + rank * R.burstSparksPerRank, R.burstSparkSize, R.burstSparkSpeed)
	burstBeam(pos - UP * 0.8, color, R.beam + rank * R.beamPerRank, R.beamWidth + rank * R.beamWidthPerRank)
	if near then
		Camera.punch(R.punch + rank * R.punchPerRank)
	end
	if R.burstSound ~= "" then
		(Sounds.play :: any)(R.burstSound, 0.05, 1)
	end
	if Budget.low() and #lids >= 1 then
		return
	end
	local now = os.clock()
	local lid = fxPart(Enum.PartType.Block, "CrateLid", color)
	lid.Size = R.lid
	table.insert(lids, {
		part = lid,
		from = pos + UP * R.lidStart,
		vel = UP * R.lidSpeed + out * R.lidDrift,
		yaw = math.atan2(-out.X, -out.Z),
		spin = R.lidSpin,
		t0 = now,
		life = R.lidTime,
	})
	if Budget.low() then
		return
	end
	local n = Budget.count(R.shards)
	for i = 1, n do
		local a = (i / n) * math.pi * 2 + math.random() * 0.6
		local dir = Vector3.new(math.cos(a), 0, math.sin(a))
		local shard = fxPart(Enum.PartType.Block, "CrateShard", if i % 2 == 0 then color else R.crateColor)
		shard.Size = Vector3.one * R.shardSize * (0.7 + math.random() * 0.6)
		table.insert(lids, {
			part = shard,
			from = pos,
			vel = dir * (R.shardSpeed[1] + math.random() * (R.shardSpeed[2] - R.shardSpeed[1]))
				+ UP * (R.shardUp[1] + math.random() * (R.shardUp[2] - R.shardUp[1])),
			yaw = a,
			spin = R.lidSpin * 1.4,
			t0 = now,
			life = R.shardTime * (0.8 + math.random() * 0.4),
		})
	end
end

-- Starts the ritual of a `rarity` crate at `pos`: Smasher `s`'s own crate (Fx.Machines keeps
-- it there and shakes it), or with `standIn` a crate built here for an open on the spot.
local function startRitual(s: Smasher?, rarity: string, color: Color3, pos: Vector3, out: Vector3, standIn: boolean)
	local R = SMASH.ritual
	local now = os.clock()
	-- The "ChestOpen" effect of this open may have named the burst time already.
	local adopted = burst.at > now and now - burst.effectAt < R.link
	burst.pending = 0
	if not nearCamera(pos, CULL) then
		-- Too far away to see: nothing for the cards to wait for.
		publish(now, rarity)
		return
	end
	local at = if adopted then burst.at else now + R.shake
	publish(at, rarity)
	local ritual: Ritual = {
		rarity = rarity,
		color = color,
		rank = math.clamp(rankOf(rarity), 0, TOP_RANK + 1),
		pos = pos,
		out = out,
		t0 = now,
		burstAt = at,
		nextSpark = now,
		flip = false,
		smasher = s,
		claimed = adopted,
		near = playerNear(pos, R.near),
		base = CFrame.new(pos) * CFrame.Angles(0, math.rad(20), 0),
		boothFill = 1,
	}
	if s then
		-- The machine keeps its solid colours while it shakes (no pale wash on a lit booth) ...
		local wash = boothWash(s.plinth)
		if wash then
			-- Its own fill, kept on it: a second open before the first put it back reads 1.
			local fill = wash:GetAttribute("RitualBaseFill")
			if type(fill) ~= "number" then
				fill = wash.FillTransparency
				wash:SetAttribute("RitualBaseFill", fill)
			end
			ritual.booth, ritual.boothFill = wash, fill :: number
			TweenService:Create(wash, TweenInfo.new(R.boothFade), { FillTransparency = math.max(wash.FillTransparency, R.boothWash) })
				:Play()
		end
		-- ... and its crate is a bright rarity-coloured silhouette drawn over everything.
		local model = s.body and s.body.Parent
		if model then
			local h: Highlight? = nil
			for _, child in model:GetChildren() do
				if child.Name == DECOR and child:IsA("Highlight") then
					h = child
				end
			end
			h = h or washOver(model, s.body :: BasePart, color, R.crateFill, R.crateRim, Highlights.PRIORITY.Ritual)
			if h then
				Highlights.claim(h, Highlights.PRIORITY.Ritual, true)
				h.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
				h.FillColor = color
				h.OutlineColor = color:Lerp(WHITE, RIM_WHITEN)
				h.FillTransparency = R.crateFill
				h.OutlineTransparency = R.crateRim
			end
		end
	end
	if standIn then
		local size = R.crate
		local sizes = {
			size,
			Vector3.new(size.X + 0.07, R.strap, size.Z + 0.07),
			Vector3.new(size.X + 0.07, size.Y + 0.07, R.strap),
		}
		local parts: { BasePart } = {}
		for i, partSize in sizes do
			local part = fxPart(Enum.PartType.Block, "StandInCrate", if i == 1 then R.crateColor else color)
			part.Size = partSize
			part.CFrame = ritual.base
			parts[i] = part
		end
		ritual.parts = parts
		smokePuff(pos - UP * (size.Y / 2), 8, 6)
	end
	if not Budget.low() then
		local holder = fxPart(Enum.PartType.Block, "RitualLight", color)
		holder.Size = Vector3.one * 0.2
		holder.Transparency = 1
		holder.CFrame = CFrame.new(pos + UP * 1.2)
		local light = Instance.new("PointLight")
		light.Color = color
		light.Range = R.lightRange
		light.Brightness = R.lightFrom
		light.Shadows = false
		light.Parent = holder
		ritual.holder, ritual.light = holder, light
	end
	if ritual.near then
		Camera.setFov("CrateRitual", -R.zoom)
	end
	if R.shakeSound ~= "" then
		(Sounds.play :: any)(R.shakeSound, 0.05, 1)
	end
	table.insert(rituals, ritual)
end

-- The build-up of every running ritual, and its burst when the time comes.
local function stepRituals(now: number)
	local R = SMASH.ritual
	for i = #rituals, 1, -1 do
		local r = rituals[i]
		local s = r.smasher
		if now >= r.burstAt then
			table.remove(rituals, i)
			if r.parts then
				for _, part in r.parts do
					part:Destroy()
				end
			end
			if r.holder then
				r.holder:Destroy()
			end
			if s then
				paintRing(s, -1)
			end
			local wash = r.booth
			if wash then
				local fill = r.boothFill
				task.delay(R.boothBack, function()
					if wash.Parent then
						TweenService:Create(wash, TweenInfo.new(R.boothFade), { FillTransparency = fill }):Play()
					end
				end)
			end
			if r.near then
				local held = false
				for _, other in rituals do
					held = held or other.near
				end
				if not held then
					Camera.setFov("CrateRitual", 0)
				end
			end
			burstOpen(r.pos, r.out, r.rarity, r.color, r.near)
			continue
		end
		local u = math.clamp((now - r.t0) / math.max(r.burstAt - r.t0, 0.05), 0, 1)
		if now >= r.nextSpark then
			r.nextSpark = now + R.sparkEvery[1] + (R.sparkEvery[2] - R.sparkEvery[1]) * u
			r.flip = not r.flip
			local tint = if r.flip then r.color else r.color:Lerp(WHITE, 0.6)
			Orbs.sparkle(r.pos + UP * 0.4, tint, R.sparks + r.rank, 0.8 + u, R.sparkSize)
		end
		if r.light then
			r.light.Brightness = R.lightFrom + (R.lightTo - R.lightFrom) * u * u
		end
		if r.parts then
			local cf = r.base * Crates.ritualShake(u, now)
			for _, part in r.parts do
				part.CFrame = cf
			end
		end
		if s then
			-- The court ring flickers between the rarity colour and white, faster and faster.
			local k = 0.5 + 0.5 * math.sin(now * (R.rate[1] + (R.rate[2] - R.rate[1]) * u))
			local tint = r.color:Lerp(WHITE, k * 0.7)
			for _, seg in s.segments do
				seg.Color = tint
				seg.Material = Enum.Material.Neon
				seg.Transparency = RING_LIT
			end
		end
	end
end

-- The "ChestOpen" effect: names the burst time for the cards at once; the ritual itself
-- starts with the slot's change in the snapshot, or here for a crate opened on the spot.
local function onChestOpen(data: any)
	local R = SMASH.ritual
	local rarity = if type(data) == "table" and type(data.rarity) == "string" then data.rarity else "Common"
	local now = os.clock()
	-- The slot's change came first and started the ritual: its burst time stands.
	for _, r in rituals do
		if r.smasher and not r.claimed and now - r.t0 < R.link then
			r.claimed = true
			publish(r.burstAt, r.rarity)
			return
		end
	end
	burst.token += 1
	local token = burst.token
	burst.effectAt = now
	burst.pending = token
	publish(now + R.shake, rarity)
	local function onTheSpot()
		if burst.pending ~= token then
			return
		end
		local root = localRoot()
		if not root then
			burst.pending = 0
			publish(os.clock(), rarity)
			return
		end
		-- The nearest empty plinth takes the stand-in crate, else the ground ahead.
		local best: Smasher?, bestDist = nil, R.reach
		for _, s in smashers do
			local busy = s.rarity ~= "" or s.body ~= nil
			for _, r in rituals do
				busy = busy or r.smasher == s
			end
			local dist = (s.plinth - root.Position).Magnitude
			if not busy and dist < bestDist then
				best, bestDist = s, dist
			end
		end
		local color = rarityColor(rarity)
		if best then
			startRitual(best, rarity, color, best.plinth, best.out, true)
		else
			local ahead = flatDir(root.CFrame.LookVector) or Vector3.zAxis
			-- The root part is 3 studs over the ground.
			local pos = root.Position + ahead * R.ahead + UP * (R.crate.Y / 2 - 2.9)
			startRitual(nil, rarity, color, pos, root.CFrame.RightVector, true)
		end
	end
	-- A slot that holds this rarity shows its change in the next snapshot; none does when
	-- the crate was opened on the spot.
	local slot = false
	for _, s in smashers do
		slot = slot or s.rarity == rarity
	end
	if slot then
		task.delay(R.link * 0.4, onTheSpot)
	else
		onTheSpot()
	end
end

-- Reads the slots from the snapshot: what each holds, when it ends and how long it takes.
local function syncSmashers()
	local data = State.data
	local slots = data and data.unlockers
	if type(slots) ~= "table" then
		return
	end
	local now = os.clock()
	for i, s in smashers do
		local slot = slots[i]
		local rarity = if type(slot) == "table" and type(slot.rarity) == "string" then slot.rarity else ""
		local left = if type(slot) == "table" then tonumber(slot.secondsLeft) or 0 else 0
		local endsAt = now + left
		-- A live change of crate, or the same rarity ending later: the old crate opened.
		local swapped = rarity ~= s.rarity
		local reloaded = not swapped and rarity ~= "" and endsAt > s.endsAt + RELOAD_JUMP
		if swapped or reloaded then
			if s.seen and s.rarity ~= "" then
				startRitual(s, s.rarity, s.color, s.plinth, s.out, false)
			end
			-- The slot's whole timer comes with the snapshot (`totalSeconds`), so a crate
			-- already ticking when the plot was bound shows its real share. Without it: a
			-- load seen live starts at its full time, any other has its rarity's.
			local sent = if type(slot) == "table" then tonumber(slot.totalSeconds) or 0 else 0
			local known = if sent > 0
				then sent
				elseif not s.seen and Economy.isRarity(rarity) then Economy.unlockSeconds(rarity, i == 2)
				else 0
			s.rarity = rarity
			s.color = rarityColor(rarity)
			s.total = math.max(left, known, 1)
			s.endsAt = endsAt
			s.blink = 0
			s.washUntil = if rarity ~= "" then now + WASH_WINDOW else 0
			paintRing(s, -1)
		elseif left <= 0 then
			s.endsAt = math.min(s.endsAt, now)
		elseif math.abs(endsAt - s.endsAt) > 1.5 then
			-- Whole-second snapshots jitter: only a real change moves the end.
			s.endsAt = endsAt
		end
		s.seen = true
	end
end

-- Gives Fx.Machines' crate on this slot's plinth its rarity's look: the wash and, as on the
-- pen floor (LOOKS), piping, gem, outline and beam, plus what SMASH.look adds for every
-- rarity (glow disc, light, the rarity word). False until that crate stands there.
local function dressSmasherCrate(s: Smasher): boolean
	local L = SMASH.look
	for _, child in Orbs.getFolder():GetChildren() do
		if child.Name ~= "CrackerCrate" or not child:IsA("Model") or child:FindFirstChild(DECOR) then
			continue
		end
		local body = child:FindFirstChild("Body")
		if not (body and body:IsA("BasePart")) or (body.Position - s.plinth).Magnitude > SMASHER_CRATE_REACH then
			continue
		end
		clearSmasherDress(s)
		local rank = rankOf(s.rarity)
		local look = lookOf(rank)
		local color = s.color
		washOver(child, body, color, math.min(look.wash, L.wash), math.min(look.rim, L.rim), Highlights.PRIORITY.SmasherCrate)
		-- Piping round the middle of each strap: the strap's thinnest side is its width.
		local piping = look.piping
		if piping then
			for _, band in child:GetChildren() do
				if band:IsA("BasePart") and band.Name == "Band" then
					local size = band.Size
					local thin = math.min(size.X, size.Y, size.Z)
					local function side(v: number): number
						return if v == thin then PIPING_WIDTH else v + PIPING_PROUD * 2
					end
					local pipe = decorPart(
						child,
						piping,
						Vector3.new(side(size.X), side(size.Y), side(size.Z)),
						band.CFrame,
						Enum.Material.SmoothPlastic
					)
					table.insert(s.decor, pipe)
					table.insert(s.decorOffsets, body.CFrame:ToObjectSpace(band.CFrame))
				end
			end
		end
		local top = body.Size.Y / 2
		if look.gem > 0 then
			local side = look.gem * L.gem
			s.gemRest = CFrame.new(0, top + GEM_GAP + side * 0.87, 0)
			s.gem =
				decorPart(child, color:Lerp(WHITE, GEM_WHITEN), Vector3.one * side, body.CFrame * s.gemRest * GEM_TILT, Enum.Material.Neon)
			top += GEM_GAP + side * 1.74
		end
		local floor = s.plinth - UP * L.foot
		local glow = fxPart(Enum.PartType.Cylinder, "SmasherGlow", color)
		glow.Material = Enum.Material.Neon
		glow.Transparency = 1
		glow.CFrame = CFrame.new(floor + UP * 0.06) * UPRIGHT
		if not Budget.low() then
			local light = Instance.new("PointLight")
			light.Color = color
			light.Range = L.light + rank * 1.5
			light.Brightness = L.lightBrightness
			light.Shadows = false
			light.Parent = glow
		end
		-- The rarity word, lit at once (the pen's chips fade in by camera distance).
		local chip = makeChip(s.rarity, color, body, math.max(top, L.chip), glow)
		local W = L.word
		local letters = utf8.len(s.rarity) or #s.rarity
		chip.Size = UDim2.new(W.letterStuds * (letters + 1), W.letterPx * (letters + 1), W.studs, W.px)
		chip.StudsOffset = Vector3.new(0, top + W.gap, 0)
		chip.SizeOffset = Vector2.new(W.lean, 0)
		chip.AlwaysOnTop = true
		chip.MaxDistance = W.range
		chip.Enabled = true
		local sign = s.pad:FindFirstChild("PadLabel")
		if L.hideSign and sign and sign:IsA("BillboardGui") then
			s.sign = sign
			sign.Enabled = false
		end
		for _, d in chip:GetDescendants() do
			if d:IsA("TextLabel") then
				d.TextTransparency = 0
			elseif d:IsA("UIStroke") then
				d.Transparency = 0
			elseif d:IsA("UIScale") then
				d.Scale = 1
			end
		end
		local low = L.lowBeams[rank]
		if look.beam > 0 or low then
			local shown = table.clone(look)
			if look.beam <= 0 and low then
				shown.beam, shown.beamWidth, shown.motes = low.beam, low.beamWidth, low.motes
			end
			shown.beam *= L.beam
			shown.beamWidth *= L.beamWide
			shown.light = 0
			local aura = makeAura(shown, color)
			if aura then
				-- Brighter than the pen's beam: denser layers at full light emission.
				for i, beam in aura.beams do
					local base = L.beamBase[i] or BEAM_LAYERS[i].base
					beam.LightEmission = L.beamEmission
					beam.Transparency = NumberSequence.new({
						NumberSequenceKeypoint.new(0, base),
						NumberSequenceKeypoint.new(0.55, base + (1 - base) * 0.4),
						NumberSequenceKeypoint.new(1, 1),
					})
				end
				lightAura(aura, floor)
				s.aura = aura
			end
		end
		s.body = body
		s.glow = glow
		s.dressedAt = os.clock()
		return true
	end
	return false
end

-- Keeps a dressed crate's piping and gem on the rattling body, turns the gem, pulses the
-- glow disc and opens the beam; drops the look once the crate is gone.
local function stepSmasherDress(s: Smasher, now: number)
	local body = s.body
	if not body then
		return
	end
	if not body.Parent then
		clearSmasherDress(s)
		return
	end
	local L = SMASH.look
	local cf = body.CFrame
	for i, part in s.decor do
		part.CFrame = cf * s.decorOffsets[i]
	end
	if s.gem then
		s.gem.CFrame = cf * s.gemRest * CFrame.new(0, math.sin(now * 2.2) * L.gemBob, 0) * CFrame.Angles(0, now * L.gemSpin, 0) * GEM_TILT
	end
	local age = now - s.dressedAt
	local rank = rankOf(s.rarity)
	local glow = s.glow
	if glow then
		local pulse = 0.5 + 0.5 * math.sin(now * (L.discRate + rank * 0.4))
		local d = math.max(0.05, (L.disc + rank * L.discPerRank) * 2 * backOut(math.clamp(age / 0.3, 0, 1)) * (1 + 0.06 * pulse))
		glow.Size = Vector3.new(0.05, d, d)
		glow.Transparency = L.discTransparency + L.discPulse * (1 - pulse)
	end
	local aura = s.aura
	if aura then
		local open = smooth(age / BEAM_OPEN) * (1 + BEAM_BREATH * math.sin(now * BEAM_BREATH_RATE))
		for i, beam in aura.beams do
			local width = aura.widths[i] * open
			beam.Width0 = width
			beam.Width1 = width * BEAM_TAPER
		end
	end
end

local function stepSmashers(now: number, dt: number)
	for _, s in smashers do
		stepSmasherDress(s, now)
		if s.rarity == "" then
			continue
		end
		if now < s.washUntil and now >= s.nextWash then
			s.nextWash = now + WASH_SCAN
			if dressSmasherCrate(s) then
				s.washUntil = 0
			end
		end
		local left = s.endsAt - now
		local share = math.clamp(1 - left / s.total, 0, 1)
		local ready = left <= 0
		local lit = if ready then RING_SEGMENTS else math.min(math.floor(share * RING_SEGMENTS), RING_SEGMENTS - 1)
		if lit ~= s.lit then
			paintRing(s, lit)
		end
		if not nearCamera(s.centre, CULL) then
			continue
		end
		if ready then
			-- Ready: the whole ring breathes.
			local transparency = RING_LIT + RING_READY_DIP * (0.5 + 0.5 * math.sin(now * RING_READY_RATE))
			for _, seg in s.segments do
				seg.Transparency = transparency
			end
		else
			-- The next segment blinks in, faster as the timer runs down.
			s.blink += dt * (RING_BLINK_SLOW + (RING_BLINK_FAST - RING_BLINK_SLOW) * share)
			local k = 0.5 + 0.5 * math.sin(s.blink)
			local head = s.segments[lit + 1]
			head.Color = INK:Lerp(s.color, k)
			head.Transparency = RING_UNLIT + (RING_LIT - RING_UNLIT) * k
		end
	end
end

-- Lids and shards fly on a ballistic arc, spinning, and fade over the last 40%.
local function stepLids(now: number)
	local gravity = SMASH.ritual.lidGravity
	for i = #lids, 1, -1 do
		local lid = lids[i]
		local t = now - lid.t0
		if t >= lid.life then
			lid.part:Destroy()
			table.remove(lids, i)
			continue
		end
		local pos = lid.from + lid.vel * t - UP * (0.5 * gravity * t * t)
		lid.part.CFrame = CFrame.new(pos) * CFrame.Angles(0, lid.yaw, 0) * CFrame.Angles(t * lid.spin, 0, t * lid.spin * 0.6)
		lid.part.Transparency = smooth((t / lid.life - 0.6) / 0.4)
	end
end

local function step(dt: number)
	local now = os.clock()
	stepSmashers(now, dt)
	stepRituals(now)
	stepLids(now)
	if crateCount == 0 then
		return
	end
	table.clear(moveParts)
	table.clear(moveCFrames)
	idleFrame += 1
	local low = Budget.low()
	local cull = if low then LOW_CULL else CULL
	local skipIdle = low and idleFrame % 2 == 0
	for model, crate in crates do
		if not model.Parent or crate.broken then
			continue
		end
		local intro = now - crate.born < crate.land + SQUASH + 0.6
		if not intro and (skipIdle or not nearCamera(crate.base.Position, cull)) then
			continue
		end
		local ok, err = pcall(stepCrate, crate, now)
		if not ok then
			warn("[Fx.Crates] " .. tostring(err))
			crate.broken = true
			-- Leave it in place: back on its spot, full size, label live.
			table.clear(moveParts)
			table.clear(moveCFrames)
			crate.restored = false
			place(crate, crate.base, 1, 1)
			setShown(crate, true, true)
		end
	end
	if #moveParts > 0 then
		Workspace:BulkMoveTo(moveParts, moveCFrames, Enum.BulkMoveMode.FireCFrameChanged)
	end
	scanChips(now)
end

-- Tracking ------------------------------------------------------------------------------

local function track(model: Instance, intro: boolean)
	if not model:IsA("Model") or crates[model] or crateCount >= MAX_CRATES then
		return
	end
	local primary = model.PrimaryPart or model:FindFirstChildWhichIsA("BasePart")
	if not primary then
		return
	end
	clearDecor(model)
	local base = model:GetPivot()
	local parts: { BasePart } = {}
	local offsets: { CFrame } = {}
	local sizes: { Vector3 } = {}
	local bottom = 0
	local hx, hz, top = 0, 0, 0
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then
			table.insert(parts, d)
			local offset = base:ToObjectSpace(d.CFrame)
			table.insert(offsets, offset)
			table.insert(sizes, d.Size)
			bottom = math.min(bottom, offset.Y - d.Size.Y / 2)
			top = math.max(top, offset.Y + d.Size.Y / 2)
			hx = math.max(hx, math.abs(offset.X) + d.Size.X / 2)
			hz = math.max(hz, math.abs(offset.Z) + d.Size.Z / 2)
		end
	end
	if #parts == 0 then
		return
	end
	local rarity = rarityOf(model)
	local rank = rankOf(rarity)
	local color = rarityColor(rarity)
	-- The rarity's own parts ride along but stay out of the box the arrival tumbles on.
	local look = lookOf(rank)
	local added, gem = dress(model, base, look, color, top)
	for _, part in added do
		table.insert(parts, part)
		table.insert(offsets, base:ToObjectSpace(part.CFrame))
		table.insert(sizes, part.Size)
	end
	-- The label clears the gem (a cube on its corner: 1.74 of its side tall).
	local chipTop = if gem then top + GEM_GAP + look.gem * 1.74 else top
	local wash = washOver(
		model,
		model:FindFirstChildWhichIsA("MeshPart") or model,
		color,
		look.wash,
		look.rim,
		Highlights.PRIORITY.PenCrate + rank / 10
	)
	local aura = makeAura(look, color)
	local disc = fxPart(Enum.PartType.Cylinder, "CrateGlow", color)
	disc.Transparency = 1
	local primaryY = base:ToObjectSpace(primary.CFrame).Y
	local chip = makeChip(rarity, color, primary, chipTop - primaryY + 0.75, disc)
	local legs, land = buildLegs(readRoute(model), base.Position)
	local crate: Crate = {
		model = model,
		base = base,
		parts = parts,
		offsets = offsets,
		sizes = sizes,
		bottom = bottom,
		half = Vector3.new(hx, (top - bottom) / 2, hz),
		mid = (top + bottom) / 2,
		rarity = rarity,
		rank = rank,
		color = color,
		born = if intro then os.clock() else os.clock() - land - 10,
		land = land,
		legs = legs,
		bounced = not intro,
		source = if intro then sourceUnit(model) else nil,
		wiggleAt = -math.huge,
		phase = math.random() * 10,
		wash = wash,
		gem = gem,
		aura = aura,
		disc = disc,
		chip = chip,
		chipOn = false,
		chipToken = 0,
		shown = not intro,
		landed = not intro,
		restored = true,
		broken = false,
	}
	if intro then
		setShown(crate, false, false)
	elseif aura then
		lightAura(aura, base.Position + Vector3.new(0, bottom, 0))
	end
	crates[model] = crate
	crateCount += 1
end

local function untrack(model: Instance)
	local crate = crates[model :: Model]
	if not crate then
		return
	end
	crates[model :: Model] = nil
	crateCount -= 1
	local floor = crate.base.Position + Vector3.new(0, crate.bottom, 0)
	fadeChip(crate, false)
	-- Pickup puff where it stood; the disc shrinks away.
	Orbs.sparkle(floor + Vector3.new(0, 1.5, 0), crate.color, 14, 0.8)
	Orbs.ring(floor + Vector3.new(0, 0.15, 0), crate.color, 3, 0.35, 0.2)
	local disc = crate.disc
	TweenService:Create(disc, TweenInfo.new(0.25, Enum.EasingStyle.Back, Enum.EasingDirection.In), {
		Size = Vector3.new(0.05, 0.05, 0.05),
		Transparency = 1,
	}):Play()
	task.delay(0.3, function()
		disc:Destroy()
	end)
	if crate.aura then
		crate.aura.anchor:Destroy()
	end
end

local boundFolder: Instance? = nil
local folderConns: { RBXScriptConnection } = {}

local function bindFolder(f: Instance)
	if f == boundFolder then
		return
	end
	boundFolder = f
	for _, conn in folderConns do
		conn:Disconnect()
	end
	table.clear(folderConns)
	for model in crates do
		untrack(model)
	end
	for _, child in f:GetChildren() do
		track(child, false)
	end
	table.insert(
		folderConns,
		f.ChildAdded:Connect(function(child)
			-- Let the whole model replicate before capturing its parts.
			task.defer(track, child, true)
		end)
	)
	table.insert(folderConns, f.ChildRemoved:Connect(untrack))
end

local function refresh()
	local data = State.data
	local map = Workspace:FindFirstChild("Map")
	if not data or not map or not data.plotIndex then
		return
	end
	local plot = map:FindFirstChild("Plot" .. tostring(data.plotIndex))
	if not plot then
		return
	end
	local f = plot:FindFirstChild("Chests")
	if f then
		bindFolder(f)
	end
	bindSmashers(plot)
	syncSmashers()
end

-- The crate in the player's hands (the server's "<Rarity>Crate" model in the character)
-- gets its rarity's wash.
local function washHeld(child: Instance)
	if not child:IsA("Model") or child:FindFirstChild(DECOR) then
		return
	end
	for _, rarity in Economy.CHEST_RARITIES do
		if child.Name == rarity .. "Crate" then
			local look = lookOf(rankOf(rarity))
			washOver(
				child,
				child:FindFirstChildWhichIsA("MeshPart") or child,
				rarityColor(rarity),
				look.wash,
				look.rim,
				Highlights.PRIORITY.Held
			)
			return
		end
	end
end

local heldConn: RBXScriptConnection? = nil

local function bindCharacter(character: Model)
	if heldConn then
		heldConn:Disconnect()
	end
	heldConn = character.ChildAdded:Connect(function(child)
		-- Let the whole model replicate before picking its mesh.
		task.defer(washHeld, child)
	end)
	for _, child in character:GetChildren() do
		washHeld(child)
	end
end

function Crates.init()
	if started then
		return
	end
	started = true
	RunService.Heartbeat:Connect(step)
	State.changed.Event:Connect(refresh)
	refresh()
	Net.event("Effect").OnClientEvent:Connect(function(kind: string, data: any)
		if kind == "ChestOpen" then
			onChestOpen(data)
		end
	end)
	local player = Players.LocalPlayer
	player.CharacterAdded:Connect(bindCharacter)
	if player.Character then
		bindCharacter(player.Character)
	end
end

return Crates
