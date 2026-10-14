--[[
	Fx.PlotRank: a plot shows how far its owner has got (client-side only, built from parts).

	Plot rank: one step for every entry of CFG.RankTiers the owner's best tier has reached (the
	best "Tier" among Plot.Units, the value Fx.Fans counts its crowd from). Each step adds one
	piece of dressing to the display rack, kept for every later step:
	  1 (tier 5)   Pennants   a sagging line of pennants between two masts on the rack's roof
	  2 (tier 10)  GoldTrim   a gold fascia with studs round the roof, gold collars on the
	                          front posts, a few glints, a neon gold strip along the top of
	                          every fence round the plot and a lit gold bead on every fence
	                          post (the plot's outline, seen from the hub)
	  3 (tier 15)  Trophies   two trophy shelves on the roof, either side of the marquee, a big
	                          gold cup on each end of the roof and a 6-stud one on each
	                          entrance pillar, on a lit neon ring
	  4 (tier 20)  NeonSign   a neon "GIGA GYM" board above the marquee
	  5 (tier 25)  CrownBeam  a huge gold crown turning over the sign in a wide gold shaft of
	                          light, with sheets of light that turn with it, sparkles drifting
	                          up the shaft and a firework bursting over it every few seconds
	An unclaimed plot (no units) has rank 0 and stays bare. Everything on the roof stands on
	the server's RackTopper.RackRoof and follows it as the rack grows or folds; the fence tubes
	and the pillar cups stand on the server's FenceCap / ArchPillarKnob parts.

	Home shot: PlotRank.homeShot gives Fx.Camera the pitch and distance that put the whole
	rack and its roof dressing (PlotRank.dressTop) in the spawn frame: the camera tilts up and
	pulls back as shelves and dressing are added (CFG.Shot), and from tier 20 looks a few
	degrees further up (PlotRank.homeTilt).

	Champion (slot 1, every plot near the camera): the best unit stands CFG.Champion.Out in
	front of its shelf pedestal on a gold stage over the gutter, where nothing is above it,
	drawn CFG.Champion.Scale big (Fx.Shelf places the own plot's, this module the others'). A
	dark panel with a gold frame and a gold back light stands behind it, a ring of gold tiles
	turns over its head and a plaque over the ring names it. From Epic the stage
	sparkles, from Legendary a beam rises to the sky; a tier 25 champion is bigger still, on
	a wider crowned stage, in a dark-red cape, in front of a turning sunburst and under a wider
	beam with turning sheets of light, with gold sparkles rising round it. A tier 25 champion
	is not its code figure but the Absolute Chad statue (AssetModels.absoluteChad, Blender-made,
	CFG.Champion.StatueHeight tall, with its own cape): one per plot, built with the stage and
	gone with it, while the slot 1 unit itself is hidden on this client (PlotRank.statueFor).
	The pedestal keeps its glow in the rarity colour. Other
	players' front-row units get a rarity ring under their feet; the own rack's rings, sizes
	and aura are Fx.Shelf's.

	Rules other modules use (pure, covered by tests/plot_rank.luau):
	  PlotRank.rank(bestTier)                          0 .. #CFG.RankTiers
	  PlotRank.features(bestTier)                      names of the dressing shown
	  PlotRank.ownFans(bestTier, base, perTier, cap)   fans on the owner's own plot (Fx.Fans)
	  PlotRank.extraSpots(spots, need)                 standing spots between the server's
	  PlotRank.bandIndex(tier) / bandColor(tier)       rarity band 1 .. 6 and its colour
	  PlotRank.ringLook(tier)                          transparency and material of a rarity ring
	  PlotRank.topTiers(tiers)                         best and second-best tier on a rack
	  PlotRank.wantScale(tier, slot, best, second)     size a unit should have (Fx.Shelf)
	  PlotRank.fitScale(want, height, room, cap)       ... limited to the room under the board
	  PlotRank.dressTop(bestTier)                      height of the dressing above the roof
	  PlotRank.homeShot(rise, run, fov)                the spawn camera's pitch and distance
	  PlotRank.homeTilt(pitch, distance, bestTier)     ... looking further up from tier 20
	  PlotRank.championScale(tier) / championPivot(rim) / championHome(rim)
	  PlotRank.statueFor(tier)                         the stage shows the statue, not the unit
	PlotRank.dress(rank, roofTop, roofSize, parent) builds the dressing without starting it
	(the tests count its parts with it).

	Budget (Fx.Budget): plots further than CFG.Range from the camera are not dressed (the own
	plot always is); "low" devices get fewer pennants, studs and trophies and no particles.
	No Highlight instances (Fx.Crates uses most of the 31 Roblox draws). Every number to tune
	in Studio is in CFG.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Economy = require(Shared:WaitForChild("Economy"))
-- The Absolute Chad statue on a tier 25 stage (absent in some unit tests: the figure stays).
local AssetModels = require(Shared:WaitForChild("AssetModels")) :: any
local Theme = require(ReplicatedStorage:WaitForChild("Theme"))

local State = require(script.Parent.Parent.State)
-- Only used to freeze a unit while it is resized (absent in the unit tests).
local Animator = require(script.Parent.Parent.Animator) :: any
local Budget = require(script.Parent.Budget)

local PlotRank = {}

local WHITE = Color3.new(1, 1, 1)
local UPRIGHT = CFrame.Angles(0, 0, math.pi / 2)
local FLAT = Vector3.new(1, 0, 1)
local SPARKLE = "rbxasset://textures/particles/sparkles_main.dds"

local function worldColor(key: string, fallback: Color3): Color3
	local palette = (Theme :: any).World
	return if palette and palette[key] then palette[key] else fallback
end

local function uiColor(key: string, fallback: Color3): Color3
	local palette = (Theme :: any).Colors
	return if palette and palette[key] then palette[key] else fallback
end

-- Every tunable of this module (and the rack rules Fx.Shelf and Fx.Fans read).
local CFG = {
	-- Plot rank: best tier needed for each step, and the dressing that step adds.
	RankTiers = { 5, 10, 15, 20, 25 },
	Features = { "Pennants", "GoldTrim", "Trophies", "NeonSign", "CrownBeam" },
	Range = 320, -- studs from the camera inside which another plot is dressed ...
	RangeOut = 360, -- ... and outside which it is cleared again
	Poll = 0.5, -- seconds between plot scans

	-- Fans (Fx.Fans): the own plot's crowd.
	OwnFansMax = 20,
	FansPerRank = 1, -- extra fans per plot rank, on top of Theme.Fans.Base + PerTier
	CrowdGap = 2.5, -- studs a derived standing spot keeps from every other spot
	CellMin = 4.5, -- two server spots this far apart (a diagonal of their grid) ...
	CellMax = 6, -- ... have a free standing spot half way between them

	-- Rack units (Fx.Shelf).
	FrontSlots = 11, -- slots on the front shelf (PlotLayout.SHELF.rowCols[1])
	StarScale = 1.3, -- units of the two best tiers, where the board above leaves room
	LowScale = 0.85, -- low tiers behind the front shelf
	LowGap = 5, -- "low" = at least this many tiers under the best
	HeadGap = 0.3, -- studs kept under the board above a unit's head (its idle float needs them)
	ChampionGuard = true, -- no unit is drawn bigger than the champion
	RescalesPerFrame = 2,
	RingWidth = 0.18, -- studs the rarity ring shows round a unit's tier disc
	-- Rarity ring by band (Common .. Mythic): transparency, and from which band it is neon.
	RingAlpha = { 0.72, 0.5, 0.36, 0.22, 0.08, 0 },
	RingNeonBand = 5,
	FrontRing = 3, -- diameter of the rings under other players' front-row units
	AuraBand = 4, -- front-shelf units from this band up (Epic) breathe sparkles
	AuraRate = 3,

	-- Champion pedestal.
	GlowBand = 0.4, -- share of the drum's height the neon band covers
	GlowPulse = 1.4, -- seconds of one half of the glow's breath
	GlowLight = { Range = 10, Brightness = 0.7 },
	HaloMax = 3.96, -- the halo stays on the 4-stud-deep board
	CrownPoints = 12, -- gold points round a tier 25 champion's stage
	CrownPoint = 0.7,
	-- The cape, per unit of the champion's scale (its foot stays in front of the back panel).
	-- Strips overlap into one solid dark-red cloth, a darker red at its edges.
	Cape = {
		Strips = 5,
		Top = 3.3,
		Bottom = 0.25,
		TopZ = 0.5,
		BottomZ = 1.0,
		TopStep = 0.4,
		BottomStep = 0.64,
		Width = 0.78,
		Color = Color3.fromRGB(128, 18, 30),
		Edge = Color3.fromRGB(92, 10, 22),
	},

	-- Champion stage: where the best unit is shown, and everything round it.
	Champion = {
		Scale = 1.4, -- the champion's drawn size ...
		MythicScale = 1.55, -- ... and a tier 25 champion's
		-- A tier 25 champion is the Absolute Chad statue instead: 15% over its authored 6.625
		-- studs, about the 7.75 studs the 1.55x figure took (plinth bottom to crown tip).
		Statue = true,
		StatueHeight = 6.625 * 1.15,
		UnitHeight = 5, -- a rack unit's height at scale 1 (PlotLayout.SHELF.unitMaxHeight)
		Out = 4.3, -- studs in front of the shelf pedestal: over the gutter, clear of the roof's front edge
		Rise = 1.2, -- studs above the pedestal's top
		Stage = 4.6, -- stage disc diameter ...
		MythicStage = 5.8, -- ... and a tier 25 champion's
		StageThick = 0.5,
		Neck = 2.2, -- width of the gold step from the pedestal to the stage
		-- The dark panel behind the champion (a pale unit reads against it, not the white shelf).
		Panel = {
			Width = 7.4,
			Back = 1.7, -- studs behind the champion: in front of the roof's front band
			Thick = 0.25,
			Head = 0.6, -- studs it stands above the champion's head
			Foot = 0.5, -- studs it hangs below the stage's top
			Frame = 0.3, -- gold neon frame bars
			Color = Color3.fromRGB(34, 22, 64),
		},
		RimDisc = 3.6, -- gold back light disc on the panel, diameter per unit of scale
		RimAlpha = 0.1,
		MythicRimAlpha = 0.4, -- a tier 25 champion's back light: half the bloom (it is gold metal now)
		RimPulse = 1.1,
		RimLight = { Range = 14, Brightness = 2.2 },
		MythicRimLight = 1.1,
		-- Ring of gold tiles turning over the champion's head: deep gold, thick and nearly
		-- closed, so it reads as a ring and not as a white glow.
		Halo = {
			Tiles = 16,
			Radius = 1.5,
			Above = 0.9,
			Tilt = 18,
			Thick = 0.42,
			Wide = 0.62,
			Fill = 0.88, -- share of the circle the tiles cover
			Spin = 1.2,
			Color = Color3.fromRGB(255, 184, 28),
		},
		-- Name plaque: a board over the champion's head, above its ring, on two gold rods from
		-- the panel's top (under the stage the pen's crate labels covered it from the spawn).
		Plaque = { Width = 8.4, Height = 2.2, Thick = 0.3, Gap = 0.35, Trim = 0.18, Rod = 0.3, RodInset = 0.7 },
		SparkleBand = 4, -- from this rarity band (Epic) the stage sparkles
		Sparkles = 10,
		MythicSparkles = 30,
		MythicSparkleSize = 2.2, -- gold sparkles rising off a tier 25 stage ...
		BodySparkles = 18, -- ... and a column of them rising round the champion's body
		BodySparkleSize = 1.3,
		MythicSunAlpha = 0.45, -- the sunburst behind a tier 25 champion: less glare round it
		BeamBand = 5, -- from this band (Legendary) a beam rises to the sky
		BeamHeight = 90,
		BeamWidth = { 4, 8 },
		MythicBeamWidth = { 8, 17 },
		BeamAlpha = 0.5,
		Rays = 2, -- sheets of light turning in a tier 25 champion's beam
		RaySpin = 0.8,
		SunRays = 12, -- bars of the sunburst turning behind a tier 25 champion
		SunRay = 3.1,
		SunSpin = 0.5,
	},

	-- Home shot (Fx.Camera's spawn shot on the own plot): from Pitch / Distance over a bare
	-- one-shelf rack the camera tilts to level while it pulls back to LevelDistance, then
	-- looks up to UpPitch, until the top of the dressing is Margin under the screen's top.
	Shot = {
		Pitch = 20, -- degrees it looks down to start with (Fx.Camera's own FRAME_PITCH)
		Distance = 15, -- studs behind the head to start with (Fx.Camera's FRAME_DISTANCE)
		LevelDistance = 34, -- studs behind the head once level: still inside the entrance
		UpPitch = 6, -- degrees it may look up for the tallest racks ...
		UpDistance = 28, -- ... from this far, so the eye stays above the floor
		Margin = 2.5, -- degrees between the dressing's top and the screen's top edge
		-- From rank HighRank (tier 20: the neon sign) the shot looks HighTilt further up, so the
		-- sign and the crown are in frame (the model above left them cropped in Studio) ...
		HighRank = 4,
		HighTilt = 5,
		EyeRoom = 3.3, -- ... coming closer when needed, so the eye stays this far under the head (above the floor)
		Fov = 70,
		Steps = 40,
		Marquee = 11, -- top of the server's marquee above the roof (there at every rank)
	},

	Gold = uiColor("GoldDeep", Color3.fromRGB(244, 150, 44)):Lerp(uiColor("Gold", Color3.fromRGB(255, 212, 64)), 0.45),
	GoldLight = uiColor("GoldLight", Color3.fromRGB(255, 236, 150)),

	Pennants = {
		Count = 17,
		CountLow = 9,
		MastInset = 5.6, -- from the roof's ends: clear of its corner knobs and the big cups
		FrontInset = 0.5, -- behind the roof's front edge
		MastHeight = 6.2,
		MastWidth = 0.5,
		Drop = 0.25,
		Sag = 2.6,
		Width = 2.2,
		Height = 2.6,
		Thick = 0.12,
		Line = 0.1,
	},
	GoldTrim = {
		Height = 0.5,
		Thick = 0.22,
		Reach = 0.3, -- in front of the roof board (its own band sticks out 0.16)
		Studs = 15,
		Stud = 0.42,
		Collar = 0.45,
		CollarInset = 1.6, -- from a front post's ends: under the white knob of the shelf above
		Glints = 4,
		-- A neon gold strip along the top of every fence cap (the plot's outline from the hub),
		-- in a deeper gold than the sunny caps it lies on, and a bead with a light on every post.
		Rail = 0.62, -- strip thickness
		RailWide = 1.1, -- strip width (the cap is 1.3 across)
		RailColor = Color3.fromRGB(255, 170, 20),
		RailPulse = 1.3, -- seconds of one half of its breath ...
		RailBright = Color3.fromRGB(255, 232, 130), -- ... to this colour (it never fades out)
		Bead = 1.2, -- neon gold ball on every fence post's knob
		PostLight = { Range = 10, Brightness = 1.6 },
		PostLights = 24, -- most post lights on one plot (spread evenly over the posts)
	},
	Trophies = {
		X = 17, -- shelf centre, either side of the marquee
		Z = 1.4,
		ShelfY = 2.6,
		ShelfWidth = 10,
		ShelfDepth = 2.2,
		Step = 3.4,
		Sizes = { 1, 1.3, 1 },
		Metals = { Color3.fromRGB(208, 214, 226), Color3.fromRGB(255, 196, 48), Color3.fromRGB(214, 138, 82) },
		Big = 3, -- size of the gold cup on each end of the roof (a cup is 2.1 studs tall at size 1)
		BigInset = 1.6, -- from the roof's ends
		BigZ = 0.8, -- behind the roof's white corner knobs
		Pillar = 2.9, -- size of the gold cup on each entrance pillar (about 6 studs tall)
		PillarRing = 4.4, -- neon gold ring under each of those cups ...
		PillarLight = { Range = 18, Brightness = 2 }, -- ... a light ...
		PillarGlints = 6, -- ... and glints round it, so they read from the hub
		PillarGold = Color3.fromRGB(255, 176, 30), -- deeper than the sunny knobs they stand on
	},
	NeonSign = {
		Text = "GIGA GYM",
		Y = 13.6, -- board centre above the roof (the marquee's top is 10.6 up)
		Z = 1.2,
		Width = 24,
		Height = 5,
		Thick = 0.5,
		Tube = 0.32,
		PostX = 10.4,
		Post = 0.7,
		Brightness = { 1.5, 2.6 },
		Pulse = 1.1,
		Light = { Range = 20, Brightness = 0.6 },
	},
	CrownBeam = {
		Y = 19.6, -- crown band centre above the roof: just over the neon sign
		Z = 0.2, -- over the roof's middle
		Diameter = 18,
		Band = 4.2,
		Rim = 0.7,
		Points = 8,
		PointWidth = 5.2,
		PointHeight = 6.3,
		PointThick = 1.2,
		Jewel = 1.8, -- ball on every point's tip ...
		Gem = 2.1, -- ... and on the band between two points
		Spin = 0.6, -- radians per second
		Bob = 0.6,
		BobSpeed = 0.9,
		BeamHeight = 170,
		BeamWidth = { 15, 34 }, -- the gold shaft that always faces the camera
		BeamAlpha = 0.3, -- its transparency at the crown
		Rays = 3, -- sheets of light that turn with the crown ...
		RayWidth = { 12, 30 },
		RayAlpha = 0.5,
		Sparkles = 16,
		SparkleSize = 2.6,
		-- Gold sparkles drifting up the shaft over the crown, seen from the plaza.
		ShaftSparkles = 36,
		ShaftSparkleSize = 2.4,
		ShaftColumn = { Width = 11, Height = 80, Above = 12 }, -- studs; Above = its foot over the crown
		-- A firework over the crown every few seconds: a rocket climbs, then bursts.
		Firework = {
			Every = 4.5, -- seconds between two
			Jitter = 1.5, -- give or take
			Height = { 22, 38 }, -- studs over the crown where it bursts
			Spread = 10, -- studs off the shaft's axis
			Climb = 0.55, -- seconds the rocket climbs
			Rocket = 1.1, -- the rocket's ball
			Sparks = 48,
			SparkSize = 2.6,
			Speed = { 20, 30 },
			Drag = 2.4,
			Fall = 9, -- studs/s^2 the sparks sink
			Life = { 1.3, 1.9 },
			Flash = { Range = 40, Brightness = 4, Time = 0.6 },
			Colors = {
				Color3.fromRGB(255, 200, 40),
				Color3.fromRGB(255, 110, 170),
				Color3.fromRGB(90, 190, 255),
				Color3.fromRGB(130, 240, 170),
			},
		},
	},
}
PlotRank.CFG = CFG

local PAL = {
	Teal = worldColor("Teal", Color3.fromRGB(40, 170, 170)),
	Cream = worldColor("Cream", Color3.fromRGB(255, 247, 232)),
	Ink = worldColor("Ink", Color3.fromRGB(58, 48, 96)),
	Sunny = worldColor("Sunny", Color3.fromRGB(255, 204, 48)),
	Pink = worldColor("Pink", Color3.fromRGB(255, 120, 170)),
	Blue = worldColor("Blue", Color3.fromRGB(84, 178, 255)),
	White = worldColor("White", WHITE),
}
local PENNANT_COLORS = {
	PAL.Pink,
	PAL.Sunny,
	PAL.Blue,
	worldColor("Mint", Color3.fromRGB(120, 230, 180)),
	worldColor("Coral", Color3.fromRGB(255, 130, 110)),
}

-- Rules -------------------------------------------------------------------------------

function PlotRank.rank(bestTier: number): number
	local rank = 0
	for i, tier in CFG.RankTiers do
		if bestTier >= tier then
			rank = i
		end
	end
	return rank
end

function PlotRank.features(bestTier: number): { string }
	local out: { string } = {}
	for i = 1, PlotRank.rank(bestTier) do
		out[i] = CFG.Features[i]
	end
	return out
end

-- Fans on the owner's own plot: Theme.Fans' count plus one per plot rank, up to `cap`.
function PlotRank.ownFans(bestTier: number, base: number, perTier: number, cap: number): number
	if bestTier <= 0 then
		return 0
	end
	return math.clamp(base + math.floor(bestTier * perTier) + PlotRank.rank(bestTier) * CFG.FansPerRank, 1, cap)
end

export type Spot = { pos: Vector3, look: Vector3, entrance: Vector3?, order: number }

-- Up to `need` extra standing spots for a crowd bigger than the server's FanSpots: the middle
-- of every cell of their grid (half way along a diagonal), CFG.CrowdGap clear of every other
-- spot, front and centre first. They face the way their neighbours do and share their back
-- entrance, so a fan still joins from behind.
function PlotRank.extraSpots(spots: { Spot }, need: number): { Spot }
	local out: { Spot } = {}
	if need <= 0 then
		return out
	end
	local found: { Spot } = {}
	for i = 1, #spots do
		for j = i + 1, #spots do
			local a, b = spots[i], spots[j]
			local gap = ((a.pos - b.pos) * FLAT).Magnitude
			if gap > CFG.CellMin and gap < CFG.CellMax then
				local pos = (a.pos + b.pos) / 2
				local clear = true
				for _, other in spots do
					if ((other.pos - pos) * FLAT).Magnitude < CFG.CrowdGap then
						clear = false
						break
					end
				end
				for _, other in found do
					if ((other.pos - pos) * FLAT).Magnitude < CFG.CrowdGap then
						clear = false
						break
					end
				end
				if clear then
					local look = a.look + b.look
					local entrance: Vector3? = a.entrance or b.entrance
					if a.entrance and b.entrance then
						entrance = (a.entrance + b.entrance) / 2
					end
					table.insert(found, {
						pos = pos,
						look = if look.Magnitude > 1e-3 then look.Unit else a.look,
						entrance = entrance,
						order = a.order + b.order,
					})
				end
			end
		end
	end
	table.sort(found, function(x: Spot, y: Spot): boolean
		if x.order ~= y.order then
			return x.order < y.order
		elseif x.pos.X ~= y.pos.X then
			return x.pos.X < y.pos.X
		end
		return x.pos.Z < y.pos.Z
	end)
	for i = 1, math.min(need, #found) do
		local spot = found[i]
		spot.order = #spots + i
		out[i] = spot
	end
	return out
end

-- Rarity band of a tier: 1 (Common) .. #Economy.TIER_BANDS (Mythic).
function PlotRank.bandIndex(tier: number): number
	for i, band in Economy.TIER_BANDS do
		if tier <= band.upTo then
			return i
		end
	end
	return #Economy.TIER_BANDS
end

function PlotRank.bandColor(tier: number): Color3
	local rarity = (Theme :: any).Colors.Rarity
	return (rarity and rarity[Economy.tierBand(tier)]) or WHITE
end

-- How a tier's rarity ring is drawn: fainter for common units, solid neon for the top bands.
function PlotRank.ringLook(tier: number): (number, Enum.Material)
	local band = PlotRank.bandIndex(tier)
	local alpha = CFG.RingAlpha[math.min(band, #CFG.RingAlpha)]
	return alpha, if band >= CFG.RingNeonBand then Enum.Material.Neon else Enum.Material.SmoothPlastic
end

-- The best tier in `tiers` and the next one under it (the best again when there is no other).
function PlotRank.topTiers(tiers: { number }): (number, number)
	local best, second = 0, 0
	for _, tier in tiers do
		if tier > best then
			best, second = tier, best
		elseif tier < best and tier > second then
			second = tier
		end
	end
	return best, if second > 0 then second else best
end

-- The size a rack unit should be drawn at: the two best tiers big, low tiers behind the
-- front shelf small, everything else as built.
function PlotRank.wantScale(tier: number, slot: number, best: number, second: number): number
	if best > 0 and tier >= second then
		return CFG.StarScale
	elseif slot > CFG.FrontSlots and tier <= best - CFG.LowGap then
		return CFG.LowScale
	end
	return 1
end

-- `want` limited to what fits: `room` is the height between the unit's feet and the board
-- above it (nil = open sky), `cap` the champion's own scale (CFG.ChampionGuard: a unit is
-- never drawn bigger than the best one). A unit never shrinks to fit: it fits as built.
function PlotRank.fitScale(want: number, height: number, room: number?, cap: number?): number
	if want <= 1 then
		return want
	end
	local scale = want
	if room and height > 0 then
		scale = math.min(scale, (room - CFG.HeadGap) / height)
	end
	if cap and CFG.ChampionGuard then
		scale = math.min(scale, cap)
	end
	return math.max(1, math.floor(scale * 100 + 0.5) / 100)
end

-- How far the roof dressing of a rack whose best tier is `bestTier` reaches above the roof's
-- top: the server's marquee, then the neon sign, then the crown's tips at the top of its bob.
function PlotRank.dressTop(bestTier: number): number
	local rank = PlotRank.rank(bestTier)
	local top = CFG.Shot.Marquee
	if rank >= 4 then
		top = math.max(top, CFG.NeonSign.Y + CFG.NeonSign.Height / 2 + 0.4)
	end
	if rank >= 5 then
		local c = CFG.CrownBeam
		top = math.max(top, c.Y + c.Band / 2 + c.PointHeight + c.Jewel / 2 + c.Bob)
	end
	return top
end

-- The spawn camera's shot of a rack: how far it looks down (radians; negative = up) and how
-- far behind the head it stands so that a point `rise` above the head and `run` studs in
-- front of it (the top of the roof dressing) is CFG.Shot.Margin under the screen's top edge.
-- The third result is false when even the widest shot crops it (a very tall rack).
function PlotRank.homeShot(rise: number, run: number, fov: number?): (number, number, boolean)
	local c = CFG.Shot
	local limit = math.rad((fov or c.Fov) / 2 - c.Margin)
	local pitch, distance = math.rad(c.Pitch), c.Distance
	for i = 0, c.Steps do
		local t = 2 * i / c.Steps
		if t <= 1 then
			pitch = math.rad(c.Pitch * (1 - t))
			distance = c.Distance + (c.LevelDistance - c.Distance) * t
		else
			pitch = -math.rad(c.UpPitch * (t - 1))
			distance = c.LevelDistance + (c.UpDistance - c.LevelDistance) * (t - 1)
		end
		-- Angle of the top above the camera's axis: the screen's top edge is half the FOV up.
		local above = math.atan2(rise - distance * math.sin(pitch), run + distance * math.cos(pitch)) + pitch
		if above <= limit then
			return pitch, distance, true
		end
	end
	return pitch, distance, false
end

-- The home shot of a rack whose best tier is `bestTier`: from CFG.Shot.HighRank the pitch from
-- PlotRank.homeShot looks CFG.Shot.HighTilt degrees further up, and the camera comes closer
-- if that would put the eye more than CFG.Shot.EyeRoom under the head (never nearer than
-- CFG.Shot.Distance).
function PlotRank.homeTilt(pitch: number, distance: number, bestTier: number): (number, number)
	local c = CFG.Shot
	if PlotRank.rank(bestTier) < c.HighRank then
		return pitch, distance
	end
	local tilted = pitch - math.rad(c.HighTilt)
	local drop = -math.sin(tilted)
	if drop > 1e-3 then
		distance = math.max(c.Distance, math.min(distance, c.EyeRoom / drop))
	end
	return tilted, distance
end

-- The size the champion (slot 1) is drawn at.
function PlotRank.championScale(tier: number): number
	return if tier >= Economy.MAX_TIER then CFG.Champion.MythicScale else CFG.Champion.Scale
end

-- Whether a `tier` champion's stage shows the Absolute Chad statue instead of the unit.
function PlotRank.statueFor(tier: number): boolean
	return CFG.Champion.Statue and tier >= Economy.MAX_TIER and AssetModels ~= nil
end

-- Where the server stands the champion: the middle of the pedestal rim's top (`rim` is the
-- plot's ChampionTop, a cylinder lying along its X axis), Y up, facing -Z like every unit.
function PlotRank.championHome(rim: BasePart): CFrame
	return rim.CFrame * CFrame.Angles(0, 0, -math.pi / 2) * CFrame.new(0, rim.Size.X / 2, 0)
end

-- Where the champion is shown: on the stage in front of and above its pedestal.
function PlotRank.championPivot(rim: BasePart): CFrame
	return PlotRank.championHome(rim) * CFrame.new(0, CFG.Champion.Rise, -CFG.Champion.Out)
end

function PlotRank.tierName(tier: number): string
	local tiers = (Theme :: any).Tiers
	local entry = tiers and tiers[math.clamp(tier, 1, #tiers)]
	return if entry and type(entry.Name) == "string" then entry.Name else "Tier " .. tier
end

-- The best tier standing on a plot's rack (0 for a plot without units).
function PlotRank.bestTier(plot: Instance): number
	local units = plot:FindFirstChild("Units")
	local best = 0
	if units then
		for _, unit in units:GetChildren() do
			local tier = unit:GetAttribute("Tier")
			if type(tier) == "number" and tier > best then
				best = tier
			end
		end
	end
	return best
end

-- Parts -------------------------------------------------------------------------------

type Kit = {
	top: CFrame, -- the roof's top centre: X along the rack, Y up, -Z toward the entrance
	hw: number, -- half the roof's width (X)
	hd: number, -- half the roof's depth (Z)
	low: boolean,
	parent: Instance,
	posts: { BasePart }, -- the front shelf's side posts (they stand on the floor)
	rails: { BasePart }, -- the caps along the top of the plot's fences
	pillars: { BasePart }, -- the knobs on top of the entrance arch's pillars
	knobs: { BasePart }, -- the knobs on top of the fence posts
}

-- A model that turns for ever about `axis` of `at` (world), `speed` radians per second.
export type Spin = { model: Model, at: CFrame, axis: Vector3, speed: number }

-- A piece of dressing: `roof` follows the rack's roof, `ground` stays put, `spin` turns
-- about `spinAt` (relative to the roof's top) and `start` sets its tweens going.
export type Feature = {
	roof: Model?,
	ground: Model?,
	spin: Model?,
	spinAt: CFrame?,
	start: (() -> ())?,
}

local function dress(part: BasePart, name: string, cf: CFrame, color: Color3, parent: Instance): BasePart
	part.Name = name
	part.CFrame = cf
	part.Color = color
	part.Material = Enum.Material.SmoothPlastic
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Parent = parent
	return part
end

local function piece(parent: Instance, name: string, size: Vector3, cf: CFrame, color: Color3, shape: Enum.PartType?): Part
	local part = Instance.new("Part")
	part.Shape = shape or Enum.PartType.Block
	part.Size = size
	dress(part, name, cf, color, parent)
	return part
end

local function metal(part: BasePart): BasePart
	part.Material = Enum.Material.Metal
	part.Reflectance = 0.25
	return part
end

local function neon(part: BasePart, transparency: number?): BasePart
	part.Material = Enum.Material.Neon
	part.Transparency = transparency or 0
	return part
end

-- A flat right triangle: its right angle at `corner`, one leg `h` long along `u` and the
-- other `d` long along `p` (unit vectors), `thick` across. Two of them make a pennant.
local function triangle(
	parent: Instance,
	name: string,
	frame: CFrame,
	corner: Vector3,
	u: Vector3,
	p: Vector3,
	h: number,
	d: number,
	thick: number,
	color: Color3
): BasePart
	local wedge = Instance.new("WedgePart")
	wedge.Size = Vector3.new(thick, h, d)
	local at = CFrame.fromMatrix(corner + u * (h / 2) + p * (d / 2), u:Cross(-p), u, -p)
	return dress(wedge, name, frame * at, color, parent)
end

-- A model with an invisible primary part at `cf`, so PivotTo moves it by that point.
local function group(name: string, cf: CFrame, parent: Instance): Model
	local model = Instance.new("Model")
	model.Name = name
	local anchor = piece(model, "Anchor", Vector3.one * 0.2, cf, WHITE)
	anchor.Transparency = 1
	model.PrimaryPart = anchor
	model.Parent = parent
	return model
end

local function sparkles(parent: Instance, color: Color3, rate: number, size: number): ParticleEmitter
	local emitter = Instance.new("ParticleEmitter")
	emitter.Texture = SPARKLE
	emitter.Color = ColorSequence.new(WHITE, color)
	emitter.LightEmission = 0.3
	emitter.Rate = rate
	emitter.Lifetime = NumberRange.new(0.9, 1.6)
	emitter.Speed = NumberRange.new(0.6, 1.8)
	emitter.SpreadAngle = Vector2.new(40, 40)
	emitter.RotSpeed = NumberRange.new(-90, 90)
	emitter.Rotation = NumberRange.new(0, 360)
	emitter.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0),
		NumberSequenceKeypoint.new(0.25, size),
		NumberSequenceKeypoint.new(1, 0),
	})
	emitter.Transparency = NumberSequence.new(0, 1)
	emitter.Parent = parent
	return emitter
end

-- A beam of light between two attachments on `part` (CFrames relative to it). Facing the
-- camera it is a shaft seen from anywhere; otherwise it is a flat sheet, standing in the
-- plane of the attachments' X axis (which points along the beam here) and one of the others.
local function lightBeam(
	part: BasePart,
	name: string,
	from: CFrame,
	to: CFrame,
	widths: { number },
	color: ColorSequence,
	alpha: number,
	faceCamera: boolean
): Beam
	local a0 = Instance.new("Attachment")
	a0.Name = name .. "0"
	a0.CFrame = from
	a0.Parent = part
	local a1 = Instance.new("Attachment")
	a1.Name = name .. "1"
	a1.CFrame = to
	a1.Parent = part
	local beam = Instance.new("Beam")
	beam.Name = name
	beam.Attachment0 = a0
	beam.Attachment1 = a1
	beam.FaceCamera = faceCamera
	beam.Segments = 4
	beam.Width0 = widths[1]
	beam.Width1 = widths[2]
	beam.LightEmission = 0.7
	beam.LightInfluence = 0
	beam.Color = color
	beam.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, alpha),
		NumberSequenceKeypoint.new(0.45, alpha + (1 - alpha) * 0.55),
		NumberSequenceKeypoint.new(1, 1),
	})
	beam.Parent = part
	return beam
end

-- A tween that breathes one property back and forth for ever.
local function breathe(inst: Instance, seconds: number, props: { [string]: any })
	local info = TweenInfo.new(seconds, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true)
	TweenService:Create(inst, info, props):Play()
end

-- Rank dressing -------------------------------------------------------------------------

local BUILDERS: { [string]: (Kit) -> Feature } = {}

function BUILDERS.Pennants(k: Kit): Feature
	local c = CFG.Pennants
	local model = group("Pennants", k.top, k.parent)
	local x0 = k.hw - c.MastInset
	local z = -k.hd + c.FrontInset
	for _, side in { -1, 1 } do
		local foot = k.top * CFrame.new(side * x0, c.MastHeight / 2, z)
		piece(model, "PennantMast", Vector3.new(c.MastHeight, c.MastWidth, c.MastWidth), foot * UPRIGHT, PAL.Teal, Enum.PartType.Cylinder)
		local knob = k.top * CFrame.new(side * x0, c.MastHeight + c.MastWidth * 0.6, z)
		piece(model, "PennantKnob", Vector3.one * c.MastWidth * 2, knob, PAL.Sunny, Enum.PartType.Ball)
	end
	local count = if k.low then c.CountLow else c.Count
	local function point(t: number): Vector3
		return Vector3.new(-x0 + 2 * x0 * t, c.MastHeight - c.Drop - c.Sag * 4 * t * (1 - t), z)
	end
	local down = -Vector3.yAxis
	local previous = point(0)
	for i = 1, count + 1 do
		local here = point(i / (count + 1))
		local mid = (previous + here) / 2
		piece(model, "PennantLine", Vector3.new(c.Line, c.Line, (here - previous).Magnitude), k.top * CFrame.lookAt(mid, here), PAL.White)
		if i <= count then
			local tint = PENNANT_COLORS[(i - 1) % #PENNANT_COLORS + 1]
			for _, side in { -1, 1 } do
				triangle(model, "Pennant", k.top, here, down, Vector3.new(side, 0, 0), c.Height, c.Width / 2, c.Thick, tint)
			end
		end
		previous = here
	end
	return { roof = model }
end

function BUILDERS.GoldTrim(k: Kit): Feature
	local c = CFG.GoldTrim
	local model = group("GoldTrim", k.top, k.parent)
	-- The roof board hangs under its top: the fascia wraps its front and both ends.
	local y = -c.Height / 2 + 0.06
	local front = -k.hd - c.Reach
	local fascia =
		piece(model, "GoldFascia", Vector3.new(k.hw * 2 + c.Thick * 2, c.Height, c.Thick), k.top * CFrame.new(0, y, front), CFG.Gold)
	metal(fascia)
	for _, side in { -1, 1 } do
		local depth = k.hd * 2 + c.Reach
		local cf = k.top * CFrame.new(side * (k.hw + c.Thick / 2), y, -c.Reach / 2)
		metal(piece(model, "GoldFascia", Vector3.new(c.Thick, c.Height, depth), cf, CFG.Gold))
	end
	piece(
		model,
		"GoldPinstripe",
		Vector3.new(k.hw * 2, 0.1, c.Thick * 0.6),
		k.top * CFrame.new(0, y - c.Height / 2 - 0.05, front),
		PAL.White
	)
	local studs = if k.low then 0 else c.Studs
	for i = 1, studs do
		local x = -k.hw + (i - 0.5) * (2 * k.hw / studs)
		local stud =
			piece(model, "GoldStud", Vector3.one * c.Stud, k.top * CFrame.new(x, y, front - c.Thick / 2), CFG.GoldLight, Enum.PartType.Ball)
		metal(stud)
	end
	if not k.low then
		local glints = sparkles(fascia, CFG.GoldLight, Budget.count(c.Glints), 0.7)
		glints.Name = "Glints"
	end
	-- Gold collars near both ends of the front shelf's posts; these stand on the floor.
	local ground = group("GoldCollars", k.top, k.parent)
	for _, post in k.posts do
		local size = post.Size
		for _, dir in { -1, 1 } do
			local cf = post.CFrame * CFrame.new(0, dir * (size.Y / 2 - c.CollarInset), 0)
			metal(piece(ground, "GoldCollar", Vector3.new(size.X + 0.24, c.Collar, size.Z + 0.24), cf, CFG.Gold))
		end
	end
	-- A neon gold strip along the top of every fence: the plot's outline, seen from the hub.
	-- The cap is a cylinder lying along its X axis: the strip lies flat on its top.
	local rails: { BasePart } = {}
	for _, cap in k.rails do
		local cf = cap.CFrame * CFrame.new(0, cap.Size.Y / 2 + c.Rail / 2 - 0.05, 0)
		local rail = piece(ground, "GoldRail", Vector3.new(cap.Size.X + 0.5, c.Rail, c.RailWide), cf, c.RailColor)
		table.insert(rails, neon(rail))
	end
	-- A neon gold bead on every fence post, a light in some of them (spread over the posts).
	local lights = if k.low then 0 else math.min(#k.knobs, Budget.count(c.PostLights))
	local every = if lights > 0 then #k.knobs / lights else math.huge
	local nextLight = 1
	for i, knob in k.knobs do
		local cf = knob.CFrame * CFrame.new(0, knob.Size.Y / 2 + c.Bead * 0.3, 0)
		local bead = neon(piece(ground, "RailBead", Vector3.one * c.Bead, cf, c.RailColor, Enum.PartType.Ball))
		table.insert(rails, bead)
		if i >= nextLight then
			nextLight += every
			local light = Instance.new("PointLight")
			light.Name = "PostLight"
			light.Color = c.RailColor
			light.Range = c.PostLight.Range
			light.Brightness = c.PostLight.Brightness
			light.Shadows = false
			light.Parent = bead
		end
	end
	return {
		roof = model,
		ground = ground,
		start = function()
			if not k.low then
				for _, rail in rails do
					breathe(rail, c.RailPulse, { Color = c.RailBright })
				end
			end
		end,
	}
end

-- A cup on a stem and a dark base, `s` times the standard size, standing on `base`.
local function trophy(model: Model, base: CFrame, s: number, tint: Color3)
	piece(model, "TrophyBase", Vector3.new(1, 0.3, 1) * s, base * CFrame.new(0, 0.15 * s, 0), PAL.Ink)
	local stem = Vector3.new(0.6 * s, 0.28 * s, 0.28 * s)
	metal(piece(model, "TrophyStem", stem, base * CFrame.new(0, 0.6 * s, 0) * UPRIGHT, tint, Enum.PartType.Cylinder))
	metal(piece(model, "TrophyBowl", Vector3.one * s, base * CFrame.new(0, 1.2 * s, 0), tint, Enum.PartType.Ball))
	local cup = Vector3.new(0.8 * s, s, s)
	metal(piece(model, "TrophyCup", cup, base * CFrame.new(0, 1.6 * s, 0) * UPRIGHT, tint, Enum.PartType.Cylinder))
	for _, side in { -1, 1 } do
		metal(
			piece(model, "TrophyHandle", Vector3.one * 0.42 * s, base * CFrame.new(side * 0.6 * s, 1.55 * s, 0), tint, Enum.PartType.Ball)
		)
	end
end

function BUILDERS.Trophies(k: Kit): Feature
	local c = CFG.Trophies
	local model = group("Trophies", k.top, k.parent)
	for _, side in { -1, 1 } do
		local shelf = k.top * CFrame.new(side * c.X, c.ShelfY, c.Z)
		piece(model, "TrophyShelf", Vector3.new(c.ShelfWidth, 0.3, c.ShelfDepth), shelf * CFrame.new(0, -0.15, 0), PAL.Cream)
		for _, leg in { -1, 1 } do
			local cf = shelf * CFrame.new(leg * (c.ShelfWidth / 2 - 0.8), -c.ShelfY / 2 - 0.15, 0)
			piece(model, "TrophyShelfLeg", Vector3.new(0.6, c.ShelfY - 0.3, 0.6), cf, PAL.Teal)
		end
		for i, size in c.Sizes do
			-- A "low" device keeps the gold cup only.
			if not k.low or i == 2 then
				trophy(model, shelf * CFrame.new((i - 2) * c.Step, 0, 0), size, c.Metals[i])
			end
		end
		-- A big gold cup on each end of the roof, over the rack's side posts.
		trophy(model, k.top * CFrame.new(side * (k.hw - c.BigInset), 0, c.BigZ), c.Big, c.Metals[2])
	end
	-- And a big one on each pillar of the entrance arch, for the hub side: deeper gold than the
	-- sunny knob it stands on, on a neon ring, lit and glinting.
	local ground = group("PillarTrophies", k.top, k.parent)
	for _, knob in k.pillars do
		local base = knob.CFrame * CFrame.new(0, knob.Size.Y / 2 - 0.25, 0)
		trophy(ground, base, c.Pillar, c.PillarGold)
		local ring = Vector3.new(0.3, c.PillarRing, c.PillarRing)
		local glow = neon(piece(ground, "PillarRing", ring, base * CFrame.new(0, 0.05, 0) * UPRIGHT, CFG.GoldLight, Enum.PartType.Cylinder))
		if not k.low then
			local light = Instance.new("PointLight")
			light.Color = CFG.GoldLight
			light.Range = c.PillarLight.Range
			light.Brightness = c.PillarLight.Brightness
			light.Shadows = false
			light.Parent = glow
			local glints = sparkles(glow, CFG.GoldLight, Budget.count(c.PillarGlints), 1.2)
			glints.Name = "PillarGlints"
			glints.EmissionDirection = Enum.NormalId.Top
			glints.Speed = NumberRange.new(1.5, 3.5)
		end
	end
	return { roof = model, ground = ground }
end

function BUILDERS.NeonSign(k: Kit): Feature
	local c = CFG.NeonSign
	local model = group("NeonSign", k.top, k.parent)
	local centre = k.top * CFrame.new(0, c.Y, c.Z)
	local bottom = c.Y - c.Height / 2
	for _, side in { -1, 1 } do
		local cf = k.top * CFrame.new(side * c.PostX, bottom / 2, c.Z + c.Thick / 2 + c.Post / 2)
		piece(model, "NeonPost", Vector3.new(bottom, c.Post, c.Post), cf * UPRIGHT, PAL.Teal, Enum.PartType.Cylinder)
	end
	local board = piece(model, "NeonBoard", Vector3.new(c.Width, c.Height, c.Thick), centre, PAL.Ink)
	-- A tube of neon round the board's face.
	local face = -c.Thick / 2 - c.Tube / 2 + 0.05
	for _, side in { -1, 1 } do
		local across = Vector3.new(c.Width, c.Tube, c.Tube)
		neon(piece(model, "NeonTube", across, centre * CFrame.new(0, side * (c.Height / 2 - c.Tube / 2), face), PAL.Pink))
		local upright = Vector3.new(c.Tube, c.Height, c.Tube)
		neon(piece(model, "NeonTube", upright, centre * CFrame.new(side * (c.Width / 2 - c.Tube / 2), 0, face), PAL.Pink))
	end
	local gui = Instance.new("SurfaceGui")
	gui.Name = "NeonText"
	gui.Face = Enum.NormalId.Front
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 30
	gui.LightInfluence = 0
	gui.Brightness = c.Brightness[1]
	gui.Parent = board
	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.AnchorPoint = Vector2.new(0.5, 0.5)
	label.Position = UDim2.fromScale(0.5, 0.52)
	label.Size = UDim2.fromScale(0.88, 0.7)
	label.Font = (Theme :: any).Fonts.Display
	label.TextScaled = true
	label.TextColor3 = PAL.Sunny
	label.Text = c.Text
	label.Parent = gui
	local stroke = Instance.new("UIStroke")
	stroke.Color = PAL.Pink
	stroke.Thickness = 3
	stroke.Parent = label
	local light = Instance.new("PointLight")
	light.Color = PAL.Pink
	light.Range = c.Light.Range
	light.Brightness = c.Light.Brightness
	light.Shadows = false
	light.Parent = board
	return {
		roof = model,
		start = function()
			breathe(gui, c.Pulse, { Brightness = c.Brightness[2] })
		end,
	}
end

function BUILDERS.CrownBeam(k: Kit): Feature
	local c = CFG.CrownBeam
	local model = group("CrownBeam", k.top, k.parent)
	local at = CFrame.new(0, c.Y, c.Z)
	-- The shaft of light and its sparkles stay put; the crown turns inside them.
	local shaft = piece(model, "CrownShaft", Vector3.new(c.Diameter, 0.2, c.Diameter), k.top * at, WHITE)
	shaft.Transparency = 1
	local gold = ColorSequence.new(CFG.Gold:Lerp(CFG.GoldLight, 0.5), CFG.GoldLight)
	local up = CFrame.new(0, c.BeamHeight, 0)
	lightBeam(shaft, "CrownLight", CFrame.new(0, -c.Band, 0), up, c.BeamWidth, gold, c.BeamAlpha, true)
	if not k.low then
		local rising = sparkles(shaft, CFG.GoldLight, Budget.count(c.Sparkles), c.SparkleSize)
		rising.EmissionDirection = Enum.NormalId.Top
		rising.Speed = NumberRange.new(5, 11)
		rising.Lifetime = NumberRange.new(2, 3.4)
		rising.SpreadAngle = Vector2.new(16, 16)
		-- Sparkles drifting up a tall column of the shaft over the crown.
		local col = c.ShaftColumn
		local columnAt = at * CFrame.new(0, col.Above + col.Height / 2, 0)
		local column = piece(model, "ShaftColumn", Vector3.new(col.Width, col.Height, col.Width), k.top * columnAt, WHITE)
		column.Transparency = 1
		local drift = sparkles(column, CFG.GoldLight, Budget.count(c.ShaftSparkles), c.ShaftSparkleSize)
		drift.Name = "ShaftSparkles"
		drift.EmissionDirection = Enum.NormalId.Top
		drift.LightEmission = 0.8
		drift.Speed = NumberRange.new(2, 5)
		drift.Lifetime = NumberRange.new(1.8, 3)
		drift.SpreadAngle = Vector2.new(25, 25)
	end

	local crown = group("Crown", k.top * at, model)
	local r = c.Diameter / 2
	local band = Vector3.new(c.Band, c.Diameter, c.Diameter)
	metal(piece(crown, "CrownBand", band, k.top * at * UPRIGHT, CFG.Gold, Enum.PartType.Cylinder))
	for _, side in { -1, 1 } do
		local rim = Vector3.new(c.Rim, c.Diameter + 0.8, c.Diameter + 0.8)
		local cf = k.top * at * CFrame.new(0, side * c.Band / 2, 0) * UPRIGHT
		metal(piece(crown, "CrownRim", rim, cf, CFG.GoldLight, Enum.PartType.Cylinder))
	end
	local jewels = { PlotRank.bandColor(Economy.MAX_TIER), PAL.Blue }
	for i = 1, c.Points do
		local turn = CFrame.Angles(0, (i - 1) * 2 * math.pi / c.Points, 0)
		-- One point: two triangles standing on the band, with a jewel on the tip and the band.
		local frame = k.top * at * turn
		local foot = Vector3.new(0, c.Band / 2, -r + c.PointThick / 2)
		for _, side in { -1, 1 } do
			metal(
				triangle(
					crown,
					"CrownPoint",
					frame,
					foot,
					Vector3.yAxis,
					Vector3.new(side, 0, 0),
					c.PointHeight,
					c.PointWidth / 2,
					c.PointThick,
					CFG.Gold
				)
			)
		end
		local tip = frame * CFrame.new(0, c.Band / 2 + c.PointHeight, -r + c.PointThick / 2)
		neon(piece(crown, "CrownJewel", Vector3.one * c.Jewel, tip, jewels[1], Enum.PartType.Ball))
		local gem = frame * CFrame.Angles(0, math.pi / c.Points, 0) * CFrame.new(0, 0, -r)
		neon(piece(crown, "CrownGem", Vector3.one * c.Gem, gem, jewels[i % 2 + 1], Enum.PartType.Ball))
	end
	-- Sheets of gold light standing in the shaft: they turn with the crown, so the beam is
	-- seen to rotate from the hub.
	local anchor = crown.PrimaryPart
	if anchor and not k.low then
		for i = 1, c.Rays do
			local turn = CFrame.Angles(0, (i - 1) * math.pi / c.Rays, 0) * UPRIGHT
			local top = CFrame.new(0, c.BeamHeight * 0.75, 0) * turn
			lightBeam(anchor, "CrownRay", CFrame.new(0, c.Band, 0) * turn, top, c.RayWidth, gold, c.RayAlpha, false)
		end
	end
	-- Fireworks over the crown: a rocket climbs from the crown's top and bursts.
	local f = c.Firework
	local launch: (() -> ())? = nil
	if not k.low then
		local rocket = piece(model, "FireworkRocket", Vector3.one * f.Rocket, k.top * at, WHITE, Enum.PartType.Ball)
		neon(rocket, 1)
		local burst = Instance.new("ParticleEmitter")
		burst.Name = "FireworkBurst"
		burst.Texture = SPARKLE
		burst.Rate = 0
		burst.LightEmission = 1
		burst.Speed = NumberRange.new(f.Speed[1], f.Speed[2])
		burst.Drag = f.Drag
		burst.Acceleration = Vector3.new(0, -f.Fall, 0)
		burst.Lifetime = NumberRange.new(f.Life[1], f.Life[2])
		burst.SpreadAngle = Vector2.new(180, 180)
		burst.RotSpeed = NumberRange.new(-120, 120)
		burst.Size = NumberSequence.new({
			NumberSequenceKeypoint.new(0, f.SparkSize),
			NumberSequenceKeypoint.new(0.6, f.SparkSize * 0.7),
			NumberSequenceKeypoint.new(1, 0),
		})
		burst.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0),
			NumberSequenceKeypoint.new(0.7, 0.2),
			NumberSequenceKeypoint.new(1, 1),
		})
		burst.Parent = rocket
		local flash = Instance.new("PointLight")
		flash.Range = f.Flash.Range
		flash.Brightness = 0
		flash.Shadows = false
		flash.Parent = rocket
		local tipTop = c.Band / 2 + c.PointHeight
		local shot = 0
		launch = function()
			shot += 1
			local color = f.Colors[(shot - 1) % #f.Colors + 1]
			-- The crown's top, wherever the roof stands now (the rocket is part of its model).
			local base = (model.PrimaryPart :: BasePart).CFrame * at
			local angle = math.random() * 2 * math.pi
			local off = math.random() * f.Spread
			local high = f.Height[1] + math.random() * (f.Height[2] - f.Height[1])
			rocket.CFrame = base * CFrame.new(0, tipTop, 0)
			rocket.Color = color
			rocket.Transparency = 0
			local goal = base * CFrame.new(math.cos(angle) * off, high, math.sin(angle) * off)
			local climb =
				TweenService:Create(rocket, TweenInfo.new(f.Climb, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { CFrame = goal })
			climb.Completed:Once(function()
				if not rocket.Parent then
					return
				end
				rocket.Transparency = 1
				burst.Color = ColorSequence.new(WHITE, color)
				burst:Emit(Budget.count(f.Sparks))
				flash.Color = color
				flash.Brightness = f.Flash.Brightness
				TweenService:Create(flash, TweenInfo.new(f.Flash.Time), { Brightness = 0 }):Play()
			end)
			climb:Play()
		end
	end
	return {
		roof = model,
		spin = crown,
		spinAt = at,
		start = function()
			local fire = launch
			if not fire then
				return
			end
			task.spawn(function()
				while model.Parent do
					task.wait(f.Every + (math.random() * 2 - 1) * f.Jitter)
					if model.Parent then
						fire()
					end
				end
			end)
		end,
	}
end

-- Builds the dressing of plot rank `rank` on a rack roof (`roofTop` = its top centre, `roofSize`
-- = the roof board's size) into `parent`, by feature name. Nothing is animated until a
-- feature's `start` runs. `posts` are the front shelf's side posts, for the gold collars;
-- `rails` the plot's fence caps and `knobs` its fence posts' knobs, for the gold outline;
-- `pillars` the entrance arch's pillar knobs, for the big cups.
function PlotRank.dress(
	rank: number,
	roofTop: CFrame,
	roofSize: Vector3,
	parent: Instance,
	low: boolean?,
	posts: { BasePart }?,
	rails: { BasePart }?,
	pillars: { BasePart }?,
	knobs: { BasePart }?
): { [string]: Feature }
	local kit: Kit = {
		top = roofTop,
		hw = roofSize.X / 2,
		hd = roofSize.Z / 2,
		low = low == true,
		parent = parent,
		posts = posts or {},
		rails = rails or {},
		pillars = pillars or {},
		knobs = knobs or {},
	}
	local out: { [string]: Feature } = {}
	for i = 1, math.min(rank, #CFG.Features) do
		local name = CFG.Features[i]
		out[name] = BUILDERS[name](kit)
	end
	return out
end

-- Champion pedestal ---------------------------------------------------------------------

-- The champion's stage on a plot: `drum`, `rim` and `foot` are the server's ChampionPedestal /
-- Top / Foot parts. The pedestal keeps its glow; in front of it stand the stage the champion
-- is shown on (PlotRank.championPivot), the dark panel and gold back light behind it, the
-- ring of tiles over its head, the name plaque and, by rarity, sparkles, a sky beam and a
-- tier 25 champion's crown, cape, sunburst and sheets of light. Returns the model, the
-- function that starts its tweens and the models that turn (PlotRank's frame step turns them).
function PlotRank.showcase(parent: Instance, drum: BasePart, rim: BasePart, foot: BasePart, tier: number): (Model, () -> (), { Spin })
	local c = CFG.Champion
	local color = PlotRank.bandColor(tier)
	local band = PlotRank.bandIndex(tier)
	local mythic = tier >= Economy.MAX_TIER
	local low = Budget.low()
	local scale = PlotRank.championScale(tier)
	local statue = PlotRank.statueFor(tier)
	local tall = if statue then c.StatueHeight else c.UnitHeight * scale
	-- `stand`: where the server stands the champion; `stage`: where it is shown. Both have Y
	-- up and -Z toward the plot's entrance.
	local stand = PlotRank.championHome(rim)
	local stage = PlotRank.championPivot(rim)
	local model = group("Champion", stage, parent)
	local spins: { Spin } = {}

	-- The pedestal's glow.
	local height = math.max(0.18, drum.Size.X * CFG.GlowBand)
	local glow =
		piece(model, "GlowBand", Vector3.new(height, drum.Size.Y + 0.16, drum.Size.Y + 0.16), drum.CFrame, color, Enum.PartType.Cylinder)
	neon(glow)
	local wide = math.min(foot.Size.Y + 0.36, CFG.HaloMax)
	local under = foot.CFrame * CFrame.new(-foot.Size.X / 2 + 0.05, 0, 0)
	neon(piece(model, "GlowHalo", Vector3.new(0.06, wide, wide), under, color, Enum.PartType.Cylinder), 0.25)
	local light = Instance.new("PointLight")
	light.Color = color
	light.Range = CFG.GlowLight.Range
	light.Brightness = CFG.GlowLight.Brightness
	light.Shadows = false
	light.Parent = glow

	-- The stage: a gold step off the pedestal and a gold disc over the gutter, on a glowing rim.
	local diameter = if mythic then c.MythicStage else c.Stage
	local r = diameter / 2
	local reach = c.Out - r + 0.4
	metal(
		piece(
			model,
			"StageNeck",
			Vector3.new(c.Neck, c.Rise - 0.04, reach),
			stand * CFrame.new(0, (c.Rise - 0.04) / 2, -reach / 2),
			CFG.Gold
		)
	)
	local disc = Vector3.new(c.StageThick, diameter, diameter)
	metal(piece(model, "StageDisc", disc, stage * CFrame.new(0, -c.StageThick / 2, 0) * UPRIGHT, CFG.Gold, Enum.PartType.Cylinder))
	local rimGlow = Vector3.new(0.16, diameter + 0.6, diameter + 0.6)
	neon(piece(model, "StageGlow", rimGlow, stage * CFrame.new(0, -c.StageThick - 0.04, 0) * UPRIGHT, color, Enum.PartType.Cylinder), 0.1)
	-- A tier 25 champion: the statue on the stage, facing the walkway (its pivot is the bottom
	-- centre of its plinth, front -Z, like a unit's).
	if statue then
		local figure = AssetModels.absoluteChad(c.StatueHeight) :: Model
		figure.Name = "ChampionStatue"
		-- PivotTo by hand (its pivot is the origin): the same in the unit tests' Lune.
		for _, part in figure:GetDescendants() do
			if part:IsA("BasePart") then
				part.CFrame = stage * part.CFrame
			end
		end
		figure.WorldPivot = stage
		figure.Parent = model
		model:SetAttribute("Statue", true)
	end

	-- The dark panel behind the champion, in a gold frame, with a gold disc of back light.
	local p = c.Panel
	local top = tall + p.Head
	local back = stage * CFrame.new(0, 0, p.Back)
	piece(model, "SpotPanel", Vector3.new(p.Width, top + p.Foot, p.Thick), back * CFrame.new(0, (top - p.Foot) / 2, 0), p.Color)
	for _, side in { -1, 1 } do
		local bar = Vector3.new(p.Frame, top + p.Foot, p.Thick + 0.1)
		neon(piece(model, "PanelFrame", bar, back * CFrame.new(side * (p.Width / 2 + p.Frame / 2), (top - p.Foot) / 2, 0), CFG.GoldLight))
	end
	local lintel = Vector3.new(p.Width + p.Frame * 2, p.Frame, p.Thick + 0.1)
	neon(piece(model, "PanelFrame", lintel, back * CFrame.new(0, top + p.Frame / 2, 0), CFG.GoldLight))
	local face = -p.Thick / 2 - 0.05
	local chest = tall * 0.6
	-- A cylinder lies along its X axis: turned to face the entrance.
	local facing = CFrame.Angles(0, math.pi / 2, 0)
	local discSize = math.min(c.RimDisc * scale, p.Width - 0.4)
	local rimDisc = piece(
		model,
		"RimGlow",
		Vector3.new(0.06, discSize, discSize),
		back * CFrame.new(0, chest, face) * facing,
		CFG.GoldLight,
		Enum.PartType.Cylinder
	)
	local rimAlpha = if mythic then c.MythicRimAlpha else c.RimAlpha
	neon(rimDisc, rimAlpha)
	local rimLight = Instance.new("PointLight")
	rimLight.Name = "RimLight"
	rimLight.Color = CFG.GoldLight
	rimLight.Range = c.RimLight.Range
	rimLight.Brightness = if mythic then c.MythicRimLight else c.RimLight.Brightness
	rimLight.Shadows = false
	rimLight.Parent = rimDisc

	-- A ring of gold tiles turning over the champion's head.
	local h = c.Halo
	local haloAt = stage * CFrame.new(0, tall + h.Above, 0) * CFrame.Angles(math.rad(h.Tilt), 0, 0)
	local halo = group("HaloRing", haloAt, model)
	local haloRadius = h.Radius * scale
	local tiles = if low then h.Tiles / 2 else h.Tiles
	local arc = 2 * math.pi * haloRadius / tiles * h.Fill
	for i = 1, tiles do
		local spoke = haloAt * CFrame.Angles(0, i * 2 * math.pi / tiles, 0) * CFrame.new(0, 0, -haloRadius)
		neon(piece(halo, "HaloTile", Vector3.new(arc, h.Thick, h.Wide), spoke, h.Color))
	end
	table.insert(spins, { model = halo, at = haloAt, axis = Vector3.yAxis, speed = h.Spin })

	-- The name plaque: over the champion's head, clear of its ring, in the panel's plane, on
	-- two gold rods from the panel's top. Read from the walkway above the pen's crate labels.
	local q = c.Plaque
	local ringTop = tall + h.Above + haloRadius * math.sin(math.rad(h.Tilt)) + h.Thick
	local plaqueY = math.max(ringTop, top + q.Trim) + q.Gap + q.Height / 2
	local plaqueAt = back * CFrame.new(0, plaqueY, 0)
	local plaque = piece(model, "NamePlaque", Vector3.new(q.Width, q.Height, q.Thick), plaqueAt, p.Color)
	for _, side in { -1, 1 } do
		local trim = Vector3.new(q.Width + 0.3, q.Trim, q.Thick + 0.1)
		neon(piece(model, "PlaqueTrim", trim, plaqueAt * CFrame.new(0, side * (q.Height / 2 + q.Trim / 2), 0), CFG.GoldLight))
		local rodFoot = top + p.Frame
		local rodTop = plaqueY - q.Height / 2
		if rodTop > rodFoot then
			local rod = Vector3.new(rodTop - rodFoot, q.Rod, q.Rod)
			local rodAt = back * CFrame.new(side * (q.Width / 2 - q.RodInset), (rodFoot + rodTop) / 2, 0) * UPRIGHT
			metal(piece(model, "PlaqueRod", rod, rodAt, CFG.Gold, Enum.PartType.Cylinder))
		end
	end
	local gui = Instance.new("SurfaceGui")
	gui.Name = "NameText"
	gui.Face = Enum.NormalId.Front
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 40
	gui.LightInfluence = 0
	gui.Brightness = 1.4
	gui.Parent = plaque
	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.AnchorPoint = Vector2.new(0.5, 0.5)
	label.Position = UDim2.fromScale(0.5, 0.5)
	label.Size = UDim2.fromScale(0.94, 0.9)
	label.Font = (Theme :: any).Fonts.Display
	label.TextScaled = true
	label.TextWrapped = true
	label.TextColor3 = if mythic then WHITE else CFG.GoldLight
	label.Text = string.upper(PlotRank.tierName(tier))
	label.Parent = gui
	local stroke = Instance.new("UIStroke")
	stroke.Color = if mythic then color else CFG.Gold
	stroke.Thickness = 2
	stroke.Parent = label

	-- From Epic the stage sparkles; from Legendary a beam rises to the sky.
	local emit = piece(model, "StageLight", Vector3.new(diameter, 0.1, diameter), stage * CFrame.new(0, 0.2, 0), WHITE)
	emit.Transparency = 1
	if band >= c.SparkleBand and not low then
		local rate = Budget.count(if mythic then c.MythicSparkles else c.Sparkles)
		local rising = sparkles(emit, if mythic then CFG.GoldLight else color, rate, if mythic then c.MythicSparkleSize else 0.9)
		rising.Name = "StageSparkles"
		rising.EmissionDirection = Enum.NormalId.Top
		rising.Speed = NumberRange.new(2, if mythic then 7 else 5)
		rising.Lifetime = NumberRange.new(1.4, if mythic then 3 else 2.4)
		rising.SpreadAngle = Vector2.new(12, 12)
		if mythic then
			rising.LightEmission = 0.8
			-- And a column of gold sparkles rising round the champion's body.
			local body = piece(model, "BodySparkleAt", Vector3.new(diameter * 0.8, tall, 1.6), stage * CFrame.new(0, tall / 2, 0), WHITE)
			body.Transparency = 1
			local rise = sparkles(body, CFG.GoldLight, Budget.count(c.BodySparkles), c.BodySparkleSize)
			rise.Name = "BodySparkles"
			rise.EmissionDirection = Enum.NormalId.Top
			rise.LightEmission = 0.8
			rise.Speed = NumberRange.new(1.5, 3.5)
			rise.Lifetime = NumberRange.new(1.2, 2)
			rise.SpreadAngle = Vector2.new(10, 10)
		end
	end
	if band >= c.BeamBand then
		local widths = if mythic then c.MythicBeamWidth else c.BeamWidth
		local shine = ColorSequence.new(if mythic then CFG.GoldLight else color, WHITE)
		lightBeam(emit, "ChampionBeam", CFrame.new(), CFrame.new(0, c.BeamHeight, 0), widths, shine, c.BeamAlpha, true)
	end

	if mythic then
		-- A sunburst turning on the panel behind the champion.
		local sunAt = back * CFrame.new(0, chest, face - 0.06)
		local sun = group("Sunburst", sunAt, model)
		for i = 1, c.SunRays do
			local ray = sunAt * CFrame.Angles(0, 0, i * 2 * math.pi / c.SunRays) * CFrame.new(0, c.SunRay / 2 + 0.5, 0)
			neon(piece(sun, "SunRay", Vector3.new(0.34, c.SunRay, 0.06), ray, CFG.GoldLight), c.MythicSunAlpha)
		end
		table.insert(spins, { model = sun, at = sunAt, axis = Vector3.zAxis, speed = c.SunSpin })
		-- Sheets of light turning in the beam, over the champion's head.
		if not low then
			local raysAt = stage * CFrame.new(0, tall + h.Above + 1, 0)
			local rays = group("BeamRays", raysAt, model)
			local anchor = rays.PrimaryPart :: BasePart
			local shine = ColorSequence.new(CFG.GoldLight, WHITE)
			for i = 1, c.Rays do
				local turn = CFrame.Angles(0, (i - 1) * math.pi / c.Rays, 0) * UPRIGHT
				lightBeam(anchor, "ChampionRay", turn, CFrame.new(0, c.BeamHeight * 0.7, 0) * turn, c.MythicBeamWidth, shine, 0.55, false)
			end
			table.insert(spins, { model = rays, at = raysAt, axis = Vector3.yAxis, speed = c.RaySpin })
		end
		-- A crown round the champion's feet: points half sunk into the stage's rim.
		local radius = r - 0.1
		local tipY = CFG.CrownPoint * math.sqrt(2) / 2
		for i = 1, CFG.CrownPoints do
			local spoke = stage * CFrame.Angles(0, (i - 0.5) * 2 * math.pi / CFG.CrownPoints, 0) * CFrame.new(0, 0.03, -radius)
			local point = Vector3.new(CFG.CrownPoint, CFG.CrownPoint, 0.14)
			metal(piece(model, "CrownPoint", point, spoke * CFrame.Angles(0, 0, math.pi / 4), CFG.Gold))
			neon(piece(model, "CrownJewel", Vector3.one * 0.3, spoke * CFrame.new(0, tipY, 0), color, Enum.PartType.Ball))
		end
		-- The cape: strips fanning out from the shoulders to the stage, behind the unit (the
		-- statue wears its own).
		if not statue then
			local cape = CFG.Cape
			local half = (cape.Strips - 1) / 2
			local cloth = cape.Color
			local footZ = math.min(cape.BottomZ * scale, p.Back - p.Thick / 2 - 0.15)
			for i = 0, cape.Strips - 1 do
				local n = i - half
				local upper = Vector3.new(n * cape.TopStep * scale, cape.Top * scale, cape.TopZ * scale)
				local lower = Vector3.new(n * cape.BottomStep * scale, cape.Bottom, footZ)
				local up = (upper - lower).Unit
				local across = up:Cross(Vector3.zAxis).Unit
				local cf = stage * CFrame.fromMatrix((upper + lower) / 2, across, up)
				local edge = i == 0 or i == cape.Strips - 1
				local strip = Vector3.new(cape.Width * scale, (upper - lower).Magnitude, 0.08)
				piece(model, "CapeStrip", strip, cf, if edge then cape.Edge else cloth).Material = Enum.Material.Fabric
			end
			local collar = Vector3.new((cape.TopStep * (cape.Strips - 1) + cape.Width) * scale, 0.3, 0.3)
			metal(piece(model, "CapeCollar", collar, stage * CFrame.new(0, cape.Top * scale, cape.TopZ * scale), CFG.Gold))
		end
	end
	return model,
		function()
			breathe(glow, CFG.GlowPulse, { Transparency = 0.4 })
			breathe(light, CFG.GlowPulse, { Brightness = CFG.GlowLight.Brightness * 0.5 })
			breathe(rimDisc, c.RimPulse, { Transparency = math.min(rimAlpha + 0.35, 0.9) })
		end,
		spins
end

-- Plot scan -----------------------------------------------------------------------------

type Rec = {
	index: number,
	folder: Instance,
	group: Folder,
	features: { [string]: Feature },
	roof: BasePart?,
	top: CFrame?, -- the roof top the roof models stand on now
	champion: Model?,
	championKey: string,
	spins: { Spin }, -- the champion stage's turning models
	staged: Model?, -- another player's champion this module moved onto its stage
	hidden: Model?, -- the slot 1 unit hidden behind a tier 25 stage's statue ...
	hiddenBits: { Instance }, -- ... the parts, lights, particles and guis it hid
	watch: RBXScriptConnection?, -- the plot's Units, while a statue stands: a new champion hides at once
	rings: { Part },
	near: boolean,
	rank: number?, -- the rank last dressed while in range (nil = not dressed): a higher one is news
	dirty: boolean, -- rebuild everything (the effects budget changed)
}

local plots: { [number]: Rec } = {}
local root: Folder? = nil
local started = false
local warned = false
local frameCount = 0

local function folder(): Folder
	local existing = root
	if existing and existing.Parent then
		return existing
	end
	local made = Instance.new("Folder")
	made.Name = "PlotRankFx"
	made.Parent = Workspace
	root = made
	return made
end

local function destroy(feature: Feature)
	if feature.roof then
		feature.roof:Destroy()
	end
	if feature.ground then
		feature.ground:Destroy()
	end
end

local function clear(rec: Rec)
	for name, feature in rec.features do
		destroy(feature)
		rec.features[name] = nil
	end
	if rec.champion then
		rec.champion:Destroy()
		rec.champion = nil
	end
	table.clear(rec.spins)
	rec.championKey = ""
	rec.top = nil
end

-- A burst of sparkles where a new piece of dressing just appeared.
local function celebrate(at: CFrame, color: Color3)
	local holder = piece(folder(), "RankBurst", Vector3.new(24, 1, 2), at, WHITE)
	holder.Transparency = 1
	local emitter = sparkles(holder, color, 0, 1.4)
	emitter.Speed = NumberRange.new(5, 12)
	emitter.SpreadAngle = Vector2.new(180, 180)
	emitter:Emit(Budget.count(36))
	task.delay(2.5, function()
		holder:Destroy()
	end)
end

local function findPart(parent: Instance, name: string): BasePart?
	local found = parent:FindFirstChild(name)
	return if found and found:IsA("BasePart") then found else nil
end

-- The front shelf's side posts: the RackPost parts built straight into the plot folder.
local function frontPosts(plot: Instance): { BasePart }
	local posts: { BasePart } = {}
	for _, child in plot:GetChildren() do
		if child.Name == "RackPost" and child:IsA("BasePart") then
			table.insert(posts, child)
		end
	end
	return posts
end

-- The plot's parts called `name`, wherever the server put them in its folder.
local function plotParts(plot: Instance, name: string): { BasePart }
	local found: { BasePart } = {}
	for _, d in plot:GetDescendants() do
		if d.Name == name and d:IsA("BasePart") then
			table.insert(found, d)
		end
	end
	return found
end

-- The knobs on the plot's fence posts and corner posts (World.Shell's FenceKnob / CornerPostKnob).
local function fenceKnobs(plot: Instance): { BasePart }
	local found = plotParts(plot, "FenceKnob")
	for _, knob in plotParts(plot, "CornerPostKnob") do
		table.insert(found, knob)
	end
	return found
end

local function syncDressing(rec: Rec, best: number)
	local roof = rec.roof
	local rank = if rec.near and roof then PlotRank.rank(best) else 0
	local before = rec.rank
	rec.rank = if rec.near and roof then rank else nil
	local wanted: { [string]: boolean } = {}
	for i = 1, rank do
		wanted[CFG.Features[i]] = true
	end
	for name, feature in rec.features do
		if not wanted[name] then
			destroy(feature)
			rec.features[name] = nil
		end
	end
	if not roof or rank == 0 then
		return
	end
	local top = roof.CFrame * CFrame.new(0, roof.Size.Y / 2, 0)
	local kit: Kit? = nil
	for i = 1, rank do
		local name = CFG.Features[i]
		if not rec.features[name] then
			-- The plot is only searched when there is something to build.
			local made: Kit = kit
				or {
					top = top,
					hw = roof.Size.X / 2,
					hd = roof.Size.Z / 2,
					low = Budget.low(),
					parent = rec.group,
					posts = frontPosts(rec.folder),
					rails = plotParts(rec.folder, "FenceCap"),
					pillars = plotParts(rec.folder, "ArchPillarKnob"),
					knobs = fenceKnobs(rec.folder),
				}
			kit = made
			-- A piece that fails to build is kept as an empty one, so it is not tried again
			-- on every scan.
			local ok, built = pcall(BUILDERS[name], made)
			local feature: Feature = if ok then built else {}
			rec.features[name] = feature
			if not ok and not warned then
				warned = true
				warn("[PlotRank] " .. name .. ": " .. tostring(built))
			end
			if feature.start then
				feature.start()
			end
			if before and i > before and not Budget.low() then
				celebrate(top * CFrame.new(0, 3, 0), CFG.GoldLight)
			end
		end
	end
	rec.top = rec.top or top
end

local function syncChampion(rec: Rec, best: number)
	local plot = rec.folder
	local drum, rim, foot = findPart(plot, "ChampionPedestal"), findPart(plot, "ChampionTop"), findPart(plot, "ChampionFoot")
	-- The plaque names the tier: every new best tier builds the stage again.
	local key = ""
	if rec.near and best > 0 and drum and rim and foot then
		key = tostring(best)
	end
	if key == rec.championKey then
		return
	end
	rec.championKey = key
	if rec.champion then
		rec.champion:Destroy()
		rec.champion = nil
	end
	table.clear(rec.spins)
	if key ~= "" and drum and rim and foot then
		local model, start, spins = PlotRank.showcase(rec.group, drum, rim, foot, best)
		rec.champion = model
		rec.spins = spins
		start()
	end
end

-- Draws `model` at `scale`, frozen while it is resized (Fx.Shelf does the same on the own rack).
local function resize(model: Model, scale: number)
	if Animator then
		Animator.hold(model)
	end
	pcall(model.ScaleTo, model, scale)
	if Animator then
		Animator.release(model)
	end
end

-- Another player's champion (the unit in slot 1) is moved onto its stage and drawn big; the
-- one that stood there before goes back to its size. The own plot's is Fx.Shelf's (it also
-- animates its arrival).
local function stageChampion(rec: Rec, own: boolean)
	local rim = findPart(rec.folder, "ChampionTop")
	local units = rec.folder:FindFirstChild("Units")
	local unit: Model? = nil
	if not own and rec.champion and rim and units then
		for _, child in units:GetChildren() do
			if child:IsA("Model") and child:GetAttribute("Slot") == 1 then
				unit = child
				break
			end
		end
	end
	local old = rec.staged
	if old and old ~= unit then
		rec.staged = nil
		if old.Parent then
			if rim and old:GetAttribute("Slot") == 1 then
				-- Its stage is gone (the plot is out of range): back onto the pedestal.
				old:PivotTo(PlotRank.championHome(rim))
			end
			resize(old, 1)
		end
	end
	if unit and rim then
		local want = PlotRank.championPivot(rim)
		if (unit:GetPivot().Position - want.Position).Magnitude > 0.05 then
			unit:PivotTo(want)
			local tier = unit:GetAttribute("Tier")
			resize(unit, PlotRank.championScale(if type(tier) == "number" then tier else 1))
		end
		rec.staged = unit
	end
end

-- The unit in slot 1 of a plot (the champion), if it is there.
local function slotOne(plot: Instance): Model?
	local units = plot:FindFirstChild("Units")
	if units then
		for _, child in units:GetChildren() do
			if child:IsA("Model") and child:GetAttribute("Slot") == 1 then
				return child
			end
		end
	end
	return nil
end

-- Hides a unit on this client (its parts see-through, its lights, particles and guis off) and
-- returns what it changed, for showUnit.
local function hideUnit(unit: Model): { Instance }
	local bits: { Instance } = {}
	for _, d in unit:GetDescendants() do
		if d:IsA("BasePart") or d:IsA("Decal") then
			(d :: any).LocalTransparencyModifier = 1
			table.insert(bits, d)
		elseif
			(d:IsA("ParticleEmitter") or d:IsA("Light") or d:IsA("LayerCollector") or d:IsA("Fire") or d:IsA("Sparkles"))
			and (d :: any).Enabled
		then
			(d :: any).Enabled = false
			table.insert(bits, d)
		end
	end
	return bits
end

local function showUnit(bits: { Instance })
	for _, d in bits do
		if d:IsA("BasePart") or d:IsA("Decal") then
			(d :: any).LocalTransparencyModifier = 0
		else
			(d :: any).Enabled = true
		end
	end
end

-- A stage with the statue (PlotRank.statueFor) hides the champion's own unit, own plot or not;
-- it shows again when the champion changes, the stage goes or the plot is released.
local function hideChampion(rec: Rec)
	local statue = rec.champion ~= nil and rec.champion:GetAttribute("Statue") == true
	local unit = if statue then slotOne(rec.folder) else nil
	local tier = if unit then unit:GetAttribute("Tier") else nil
	if type(tier) ~= "number" or not PlotRank.statueFor(tier) then
		unit = nil
	end
	if rec.hidden ~= unit then
		showUnit(rec.hiddenBits)
		rec.hidden = unit
		rec.hiddenBits = if unit then hideUnit(unit) else {}
	end
	local units = if statue then rec.folder:FindFirstChild("Units") else nil
	if units and not rec.watch then
		rec.watch = units.ChildAdded:Connect(function()
			task.defer(function()
				if rec.watch then
					pcall(hideChampion, rec)
				end
			end)
		end)
	elseif not units and rec.watch then
		rec.watch:Disconnect()
		rec.watch = nil
	end
end

-- Rarity rings under the front-row units of another player's plot (the own rack's are
-- Fx.Shelf's): a small pool of discs, placed again on every scan.
local function syncRings(rec: Rec, show: boolean)
	local used = 0
	local units = if show then rec.folder:FindFirstChild("Units") else nil
	if units then
		for _, unit in units:GetChildren() do
			local slot, tier = unit:GetAttribute("Slot"), unit:GetAttribute("Tier")
			if unit:IsA("Model") and type(slot) == "number" and slot <= CFG.FrontSlots and type(tier) == "number" then
				used += 1
				local ring = rec.rings[used]
				if not ring then
					ring = piece(
						rec.group,
						"RarityRing",
						Vector3.new(0.05, CFG.FrontRing, CFG.FrontRing),
						CFrame.new(),
						WHITE,
						Enum.PartType.Cylinder
					)
					rec.rings[used] = ring
				end
				local alpha, material = PlotRank.ringLook(tier)
				ring.Color = PlotRank.bandColor(tier)
				ring.Transparency = alpha
				ring.Material = material
				ring.CFrame = CFrame.new(unit:GetPivot().Position + Vector3.new(0, 0.06, 0)) * UPRIGHT
			end
		end
	end
	for i = #rec.rings, used + 1, -1 do
		rec.rings[i]:Destroy()
		rec.rings[i] = nil
	end
end

local function syncPlot(rec: Rec, own: boolean, camPos: Vector3)
	if rec.dirty then
		rec.dirty = false
		rec.rank = nil
		clear(rec)
	end
	local topper = rec.folder:FindFirstChild("RackTopper")
	rec.roof = if topper then findPart(topper, "RackRoof") else nil
	local roof = rec.roof
	if own then
		rec.near = true
	elseif roof then
		local range = if rec.near then CFG.RangeOut else CFG.Range
		rec.near = (roof.Position - camPos).Magnitude <= range
	else
		rec.near = false
	end
	local best = PlotRank.bestTier(rec.folder)
	syncDressing(rec, best)
	syncChampion(rec, best)
	stageChampion(rec, own)
	hideChampion(rec)
	syncRings(rec, rec.near and not own)
end

local function dropPlot(rec: Rec)
	if rec.watch then
		rec.watch:Disconnect()
		rec.watch = nil
	end
	showUnit(rec.hiddenBits)
	rec.hidden = nil
	rec.hiddenBits = {}
	rec.group:Destroy()
end

local function poll()
	local map = Workspace:FindFirstChild("Map")
	local data = State.data
	local ownIndex = if data then data.plotIndex else nil
	local camera = Workspace.CurrentCamera
	local camPos = if camera then camera.CFrame.Position else Vector3.zero
	if map then
		for _, child in map:GetChildren() do
			local index = tonumber(string.match(child.Name, "^Plot(%d+)$"))
			if index then
				local rec = plots[index]
				if rec and rec.folder ~= child then
					dropPlot(rec)
					rec = nil
				end
				if not rec then
					local made = Instance.new("Folder")
					made.Name = "Plot" .. index
					made.Parent = folder()
					rec = {
						index = index,
						folder = child,
						group = made,
						features = {},
						roof = nil,
						top = nil,
						champion = nil,
						championKey = "",
						spins = {},
						staged = nil,
						hidden = nil,
						hiddenBits = {},
						watch = nil,
						rings = {},
						near = false,
						rank = nil,
						dirty = false,
					}
					plots[index] = rec
				end
				syncPlot(rec :: Rec, index == ownIndex, camPos)
			end
		end
	end
	for index, rec in plots do
		if not map or rec.folder.Parent ~= map then
			dropPlot(rec)
			plots[index] = nil
		end
	end
end

-- Every frame: the dressing rides the roof as the rack grows or folds (Fx.Shelf glides it),
-- and the crowns turn.
local function step()
	frameCount += 1
	local now = os.clock()
	local c = CFG.CrownBeam
	local skip = Budget.low() and frameCount % 2 == 0
	for _, rec in plots do
		if not skip then
			for _, spin in rec.spins do
				spin.model:PivotTo(spin.at * CFrame.fromAxisAngle(spin.axis, now * spin.speed))
			end
		end
		local roof = rec.roof
		if roof and roof.Parent and next(rec.features) then
			local top = roof.CFrame * CFrame.new(0, roof.Size.Y / 2, 0)
			if top ~= rec.top then
				rec.top = top
				for _, feature in rec.features do
					if feature.roof then
						feature.roof:PivotTo(top)
					end
				end
			end
			local crown = rec.features.CrownBeam
			if crown and crown.spin and crown.spinAt and not skip then
				local bob = CFrame.new(0, math.sin(now * c.BobSpeed) * c.Bob, 0)
				crown.spin:PivotTo(top * crown.spinAt * bob * CFrame.Angles(0, now * c.Spin, 0))
			end
		end
	end
end

function PlotRank.init()
	if started then
		return
	end
	started = true
	local startedAt = os.clock()
	task.spawn(function()
		while true do
			-- Wait for the first snapshot (it names our plot), like Fx.Fans.
			if State.data or os.clock() - startedAt > 8 then
				local ok, err = pcall(poll)
				if not ok and not warned then
					warned = true
					warn("[PlotRank] " .. tostring(err))
				end
			end
			task.wait(CFG.Poll)
		end
	end)
	RunService.RenderStepped:Connect(function()
		local ok, err = pcall(step)
		if not ok and not warned then
			warned = true
			warn("[PlotRank] " .. tostring(err))
		end
	end)
	-- Counts and particles depend on the device's budget: build again when it changes.
	Budget.onChange(function()
		for _, rec in plots do
			rec.dirty = true
		end
	end)
end

return PlotRank
