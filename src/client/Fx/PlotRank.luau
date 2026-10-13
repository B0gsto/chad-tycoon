--[[
	Fx.PlotRank: a plot shows how far its owner has got (client-side only, built from parts).

	Plot rank: one step for every entry of CFG.RankTiers the owner's best tier has reached
	(PlotRank.rankTier: the best tier ever found, the plot folder's "BestTier" attribute, so a
	rebirth never strips it; never less than the best "Tier" among Plot.Units. Fx.Fans counts
	its crowd from the same value). Each step adds one
	piece of dressing to the display rack, kept for every later step:
	  1 (tier 5)   Pennants   a sagging line of pennants between two masts on the rack's roof
	  2 (tier 10)  GoldTrim   a gold fascia with studs round the roof, gold collars on the
	                          front posts, a few glints
	  3 (tier 15)  Trophies   two trophy shelves on the roof, either side of the marquee
	  4 (tier 20)  NeonSign   a neon "GIGA GYM" board above the marquee
	  5 (tier 25)  CrownBeam  a big gold crown turning over the sign in a shaft of light
	An unclaimed plot (no units) has rank 0 and stays bare. Everything on the roof stands on
	the server's RackTopper.RackRoof and follows it as the rack grows or folds; nothing is built
	on the floor, the shelf lips (Fx.Plates) or the fan zones.

	Champion (slot 1, every plot near the camera): the pedestal glows in the best unit's
	rarity colour (a neon band round the drum, a halo on the board, a soft light). A tier 25
	champion stands in a crowned pedestal (gold points with jewels round its rim) and wears a
	cape. Other players' front-row units get a rarity ring under their feet; the own rack's
	rings, sizes and aura are Fx.Shelf's.

	Rules other modules use (pure, covered by tests/plot_rank.luau):
	  PlotRank.rank(bestTier)                          0 .. #CFG.RankTiers
	  PlotRank.features(bestTier)                      names of the dressing shown
	  PlotRank.ownFans(bestTier, base, perTier, cap)   fans on the owner's own plot (Fx.Fans)
	  PlotRank.rankTier(plot)                          the tier the rank goes by (all-time best)
	  PlotRank.extraSpots(spots, need)                 standing spots between the server's
	  PlotRank.bandIndex(tier) / bandColor(tier)       rarity band 1 .. 6 and its colour
	  PlotRank.ringLook(tier)                          transparency and material of a rarity ring
	  PlotRank.topTiers(tiers)                         best and second-best tier on a rack
	  PlotRank.wantScale(tier, slot, best, second)     size a unit should have (Fx.Shelf)
	  PlotRank.fitScale(want, height, room, cap)       ... limited to the room under the board
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
local Theme = require(ReplicatedStorage:WaitForChild("Theme"))

local State = require(script.Parent.Parent.State)
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
	CrownPoints = 8, -- gold points round a tier 25 champion's pedestal
	CrownPoint = 0.46,
	Cape = { Strips = 5, Top = 3.3, Bottom = 0.25, TopZ = 0.5, BottomZ = 1.2, TopStep = 0.4, BottomStep = 0.64, Width = 0.6 },

	Gold = uiColor("GoldDeep", Color3.fromRGB(244, 150, 44)):Lerp(uiColor("Gold", Color3.fromRGB(255, 212, 64)), 0.45),
	GoldLight = uiColor("GoldLight", Color3.fromRGB(255, 236, 150)),

	Pennants = {
		Count = 19,
		CountLow = 11,
		MastInset = 3.4, -- from the roof's ends: clear of its white corner knobs
		FrontInset = 0.5, -- behind the roof's front edge
		MastHeight = 4.6,
		MastWidth = 0.45,
		Drop = 0.25,
		Sag = 2.4,
		Width = 1.5,
		Height = 1.7,
		Thick = 0.12,
		Line = 0.09,
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
		Y = 20.2, -- crown band centre above the roof
		Z = 0.2, -- over the roof: at ten shelves the crown still clears the back fence
		Diameter = 6,
		Band = 1.4,
		Points = 6,
		PointWidth = 1.9,
		PointHeight = 2.1,
		Spin = 0.35, -- radians per second
		Bob = 0.45,
		BobSpeed = 0.9,
		BeamHeight = 140,
		BeamWidth = { 4.5, 11 },
		Sparkles = 8,
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

-- The tier a plot's rank goes by: the best tier its owner ever found (the folder's "BestTier"
-- attribute, set by the server; a rebirth empties the rack but never lowers it), and never
-- less than what stands on the rack.
function PlotRank.rankTier(plot: Instance): number
	local index = plot:GetAttribute("BestTier")
	return math.max(PlotRank.bestTier(plot), if type(index) == "number" then math.floor(index) else 0)
end

-- Parts -------------------------------------------------------------------------------

type Kit = {
	top: CFrame, -- the roof's top centre: X along the rack, Y up, -Z toward the entrance
	hw: number, -- half the roof's width (X)
	hd: number, -- half the roof's depth (Z)
	low: boolean,
	parent: Instance,
	posts: { BasePart }, -- the front shelf's side posts (they stand on the floor)
}

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
	return { roof = model, ground = ground }
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
	end
	return { roof = model }
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
	local a0 = Instance.new("Attachment")
	a0.Parent = shaft
	local a1 = Instance.new("Attachment")
	a1.Position = Vector3.new(0, c.BeamHeight, 0)
	a1.Parent = shaft
	local beam = Instance.new("Beam")
	beam.Name = "CrownLight"
	beam.Attachment0 = a0
	beam.Attachment1 = a1
	beam.FaceCamera = true
	beam.Segments = 4
	beam.Width0 = c.BeamWidth[1]
	beam.Width1 = c.BeamWidth[2]
	beam.LightEmission = 0.6
	beam.LightInfluence = 0
	beam.Color = ColorSequence.new(CFG.GoldLight, WHITE)
	beam.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.5),
		NumberSequenceKeypoint.new(0.4, 0.8),
		NumberSequenceKeypoint.new(1, 1),
	})
	beam.Parent = shaft
	if not k.low then
		local rising = sparkles(shaft, CFG.GoldLight, Budget.count(c.Sparkles), 1.1)
		rising.EmissionDirection = Enum.NormalId.Top
		rising.Speed = NumberRange.new(3, 7)
		rising.Lifetime = NumberRange.new(1.6, 2.6)
		rising.SpreadAngle = Vector2.new(14, 14)
	end

	local crown = group("Crown", k.top * at, model)
	local r = c.Diameter / 2
	local band = Vector3.new(c.Band, c.Diameter, c.Diameter)
	metal(piece(crown, "CrownBand", band, k.top * at * UPRIGHT, CFG.Gold, Enum.PartType.Cylinder))
	for _, side in { -1, 1 } do
		local rim = Vector3.new(0.26, c.Diameter + 0.3, c.Diameter + 0.3)
		local cf = k.top * at * CFrame.new(0, side * c.Band / 2, 0) * UPRIGHT
		metal(piece(crown, "CrownRim", rim, cf, CFG.GoldLight, Enum.PartType.Cylinder))
	end
	local jewels = { PlotRank.bandColor(Economy.MAX_TIER), PAL.Blue }
	for i = 1, c.Points do
		local turn = CFrame.Angles(0, (i - 1) * 2 * math.pi / c.Points, 0)
		-- One point: two triangles standing on the band, with a jewel on the tip and the band.
		local frame = k.top * at * turn
		local foot = Vector3.new(0, c.Band / 2, -r + 0.25)
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
					0.5,
					CFG.Gold
				)
			)
		end
		local tip = frame * CFrame.new(0, c.Band / 2 + c.PointHeight, -r + 0.25)
		neon(piece(crown, "CrownJewel", Vector3.one * 0.6, tip, jewels[1], Enum.PartType.Ball))
		local gem = frame * CFrame.Angles(0, math.pi / c.Points, 0) * CFrame.new(0, 0, -r)
		neon(piece(crown, "CrownGem", Vector3.one * 0.7, gem, jewels[i % 2 + 1], Enum.PartType.Ball))
	end
	return { roof = model, spin = crown, spinAt = at }
end

-- Builds the dressing of plot rank `rank` on a rack roof (`roofTop` = its top centre, `roofSize`
-- = the roof board's size) into `parent`, by feature name. Nothing is animated until a
-- feature's `start` runs. `posts` are the front shelf's side posts, for the gold collars.
function PlotRank.dress(
	rank: number,
	roofTop: CFrame,
	roofSize: Vector3,
	parent: Instance,
	low: boolean?,
	posts: { BasePart }?
): { [string]: Feature }
	local kit: Kit = {
		top = roofTop,
		hw = roofSize.X / 2,
		hd = roofSize.Z / 2,
		low = low == true,
		parent = parent,
		posts = posts or {},
	}
	local out: { [string]: Feature } = {}
	for i = 1, math.min(rank, #CFG.Features) do
		local name = CFG.Features[i]
		out[name] = BUILDERS[name](kit)
	end
	return out
end

-- Champion pedestal ---------------------------------------------------------------------

-- The glow (and, for a tier 25 champion, the crown points and the cape) on a plot's champion
-- pedestal: `drum`, `rim` and `foot` are the server's ChampionPedestal / Top / Foot parts.
-- Returns the model and the function that starts its glow breathing.
function PlotRank.showcase(parent: Instance, drum: BasePart, rim: BasePart, foot: BasePart, tier: number): (Model, () -> ())
	local color = PlotRank.bandColor(tier)
	-- The pedestal's cylinders lie along their X axis: undo that for a frame with Y up, at
	-- the middle of the rim's top (where the champion stands, facing -Z).
	local stand = rim.CFrame * UPRIGHT:Inverse() * CFrame.new(0, rim.Size.X / 2, 0)
	local model = group("Champion", stand, parent)
	local height = math.max(0.18, drum.Size.X * CFG.GlowBand)
	local band =
		piece(model, "GlowBand", Vector3.new(height, drum.Size.Y + 0.16, drum.Size.Y + 0.16), drum.CFrame, color, Enum.PartType.Cylinder)
	neon(band)
	local wide = math.min(foot.Size.Y + 0.36, CFG.HaloMax)
	local under = foot.CFrame * CFrame.new(-foot.Size.X / 2 + 0.05, 0, 0)
	neon(piece(model, "GlowHalo", Vector3.new(0.06, wide, wide), under, color, Enum.PartType.Cylinder), 0.25)
	local light = Instance.new("PointLight")
	light.Color = color
	light.Range = CFG.GlowLight.Range
	light.Brightness = CFG.GlowLight.Brightness
	light.Shadows = false
	light.Parent = band

	if tier >= Economy.MAX_TIER then
		-- A crown round the champion's feet: points half sunk into the pedestal's gold rim.
		local radius = rim.Size.Y / 2 - 0.1
		local tipY = CFG.CrownPoint * math.sqrt(2) / 2
		for i = 1, CFG.CrownPoints do
			local spoke = stand * CFrame.Angles(0, (i - 0.5) * 2 * math.pi / CFG.CrownPoints, 0) * CFrame.new(0, 0.03, -radius)
			local point = Vector3.new(CFG.CrownPoint, CFG.CrownPoint, 0.1)
			metal(piece(model, "CrownPoint", point, spoke * CFrame.Angles(0, 0, math.pi / 4), CFG.Gold))
			neon(piece(model, "CrownJewel", Vector3.one * 0.2, spoke * CFrame.new(0, tipY, 0), color, Enum.PartType.Ball))
		end
		-- The cape: strips fanning out from the shoulders to the pedestal, behind the unit.
		local cape = CFG.Cape
		local half = (cape.Strips - 1) / 2
		local cloth = color:Lerp(PAL.Ink, 0.3)
		for i = 0, cape.Strips - 1 do
			local n = i - half
			local top = Vector3.new(n * cape.TopStep, cape.Top, cape.TopZ)
			local bottom = Vector3.new(n * cape.BottomStep, cape.Bottom, cape.BottomZ)
			local up = (top - bottom).Unit
			local across = up:Cross(Vector3.zAxis).Unit
			local cf = stand * CFrame.fromMatrix((top + bottom) / 2, across, up)
			local edge = i == 0 or i == cape.Strips - 1
			piece(model, "CapeStrip", Vector3.new(cape.Width, (top - bottom).Magnitude, 0.08), cf, if edge then CFG.Gold else cloth)
		end
		local collar = Vector3.new(cape.TopStep * (cape.Strips - 1) + cape.Width, 0.3, 0.3)
		metal(piece(model, "CapeCollar", collar, stand * CFrame.new(0, cape.Top, cape.TopZ), CFG.Gold))
	end
	return model,
		function()
			breathe(band, CFG.GlowPulse, { Transparency = 0.4 })
			breathe(light, CFG.GlowPulse, { Brightness = CFG.GlowLight.Brightness * 0.5 })
		end
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
	local kit: Kit = {
		top = top,
		hw = roof.Size.X / 2,
		hd = roof.Size.Z / 2,
		low = Budget.low(),
		parent = rec.group,
		posts = frontPosts(rec.folder),
	}
	for i = 1, rank do
		local name = CFG.Features[i]
		if not rec.features[name] then
			-- A piece that fails to build is kept as an empty one, so it is not tried again
			-- on every scan.
			local ok, built = pcall(BUILDERS[name], kit)
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
	local key = ""
	if rec.near and best > 0 and drum and rim and foot then
		key = PlotRank.bandIndex(best) .. (if best >= Economy.MAX_TIER then "+" else "")
	end
	if key == rec.championKey then
		return
	end
	rec.championKey = key
	if rec.champion then
		rec.champion:Destroy()
		rec.champion = nil
	end
	if key ~= "" and drum and rim and foot then
		local model, start = PlotRank.showcase(rec.group, drum, rim, foot, best)
		rec.champion = model
		start()
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
	-- The dressing is earned for good (the Index); the pedestal glows for the unit on it.
	syncDressing(rec, PlotRank.rankTier(rec.folder))
	syncChampion(rec, PlotRank.bestTier(rec.folder))
	syncRings(rec, rec.near and not own)
end

local function dropPlot(rec: Rec)
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
