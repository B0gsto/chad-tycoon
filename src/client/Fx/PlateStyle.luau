--!strict
--[[
	Fx.PlateStyle: how a unit's name plate on the rack looks and glows (pure data + maths,
	no services).

	One row per rarity band (Economy.TIER_BANDS names) sets the look; a small ramp inside
	each band (tier position from the band's first to last tier) nudges halo, size and
	brightness up, never past the next band's base, so the glow grows with every tier and
	steps up at each band change. The champion (slot 1) always gets the top band's effects.

	Readability: the low bands (Common, Uncommon, Rare) are cream sign plates with Ink text
	and a rarity-coloured edge; the high bands (Epic and up) are Ink plates with bright
	rarity-coloured (gradient) text, so the best Chads read as glowing jewels on the rack.
	Far away a plate collapses to a small rarity-coloured gem (`gem`), which glows only for
	the top bands and the champion (`gemGlow`).

	Plates.luau reads the result: plate fill, text colours (several = a gradient), stroke,
	halo, pulse, shimmer sweep, colour cycling, sparkles, a small light pool, plate scale and
	the GUI brightness (SurfaceGui.Brightness with LightInfluence 0; Plates divides the plate
	fill and Ink text by it, so only the coloured glow gets brighter).
]]

local PlateStyle = {}

local function rgb(r: number, g: number, b: number): Color3
	return Color3.fromRGB(r, g, b)
end

-- Theme.World.Cream / Theme.World.Ink (this module stays free of requires for the tests).
local CREAM = rgb(255, 247, 232)
local INK = rgb(58, 48, 96)

export type BandLook = {
	plate: Color3, -- plate fill
	dark: boolean, -- Ink plate with bright text (else cream plate with Ink text)
	text: { Color3 }, -- one colour = flat text, more = gradient across the name
	gem: Color3, -- the far-away gem's colour
	gemGlow: boolean, -- the far-away gem keeps a soft halo
	glow: Color3, -- stroke and halo colour
	strokeTransparency: number,
	strokeThickness: number,
	halo: number, -- 0 = no halo, 1 = strongest
	pulseSpeed: number, -- pulses per second (0 = steady)
	pulseAmp: number, -- how much the halo brightens at the pulse peak (0..1)
	shimmer: boolean, -- a light sweep crosses the plate every few seconds
	cycle: boolean, -- gradient text slowly sways through its colours
	sparkles: boolean,
	light: boolean, -- a small warm PointLight pools on the shelf below
	scale: number, -- plate size multiplier
	brightness: number, -- SurfaceGui.Brightness
	plateTransparency: number,
}

-- Per rarity band, quietest first.
PlateStyle.BANDS = {
	Common = {
		plate = CREAM,
		dark = false,
		text = { INK },
		gem = rgb(196, 204, 222),
		gemGlow = false,
		glow = INK,
		strokeTransparency = 0.5,
		strokeThickness = 1.25,
		halo = 0,
		pulseSpeed = 0,
		pulseAmp = 0,
		shimmer = false,
		cycle = false,
		sparkles = false,
		light = false,
		scale = 1,
		brightness = 1,
		plateTransparency = 0.04,
	},
	Uncommon = {
		plate = CREAM,
		dark = false,
		text = { INK },
		gem = rgb(110, 226, 130),
		gemGlow = false,
		glow = rgb(110, 226, 130),
		strokeTransparency = 0.35,
		strokeThickness = 1.5,
		halo = 0.22,
		pulseSpeed = 0,
		pulseAmp = 0,
		shimmer = false,
		cycle = false,
		sparkles = false,
		light = false,
		scale = 1.05,
		brightness = 1.4,
		plateTransparency = 0.04,
	},
	Rare = {
		plate = CREAM,
		dark = false,
		text = { INK },
		gem = rgb(84, 178, 255),
		gemGlow = false,
		glow = rgb(84, 178, 255),
		strokeTransparency = 0.25,
		strokeThickness = 2,
		halo = 0.4,
		pulseSpeed = 0,
		pulseAmp = 0,
		shimmer = false,
		cycle = false,
		sparkles = false,
		light = false,
		scale = 1.1,
		brightness = 1.8,
		plateTransparency = 0.04,
	},
	Epic = {
		plate = INK,
		dark = true,
		text = { rgb(232, 206, 255), rgb(206, 156, 255) },
		gem = rgb(186, 120, 255),
		gemGlow = false,
		glow = rgb(186, 120, 255),
		strokeTransparency = 0.15,
		strokeThickness = 2,
		halo = 0.58,
		pulseSpeed = 0.5,
		pulseAmp = 0.18,
		shimmer = true,
		cycle = false,
		sparkles = false,
		light = false,
		scale = 1.16,
		brightness = 2.3,
		plateTransparency = 0.08,
	},
	Legendary = {
		plate = INK,
		dark = true,
		text = { rgb(255, 244, 190), rgb(255, 204, 64), rgb(255, 160, 40) },
		gem = rgb(255, 200, 56),
		gemGlow = true,
		glow = rgb(255, 200, 56),
		strokeTransparency = 0.05,
		strokeThickness = 2.5,
		halo = 0.75,
		pulseSpeed = 0.6,
		pulseAmp = 0.22,
		shimmer = true,
		cycle = true,
		sparkles = false,
		light = false,
		scale = 1.22,
		brightness = 2.8,
		plateTransparency = 0.08,
	},
	Mythic = {
		plate = INK,
		dark = true,
		text = {
			rgb(255, 214, 92),
			rgb(255, 128, 176),
			rgb(196, 140, 255),
			rgb(110, 200, 255),
			rgb(120, 232, 170),
			rgb(255, 214, 92),
		},
		gem = rgb(255, 104, 164),
		gemGlow = true,
		glow = rgb(255, 150, 196),
		strokeTransparency = 0,
		strokeThickness = 3,
		halo = 0.92,
		pulseSpeed = 0.7,
		pulseAmp = 0.25,
		shimmer = true,
		cycle = true,
		sparkles = true,
		light = true,
		scale = 1.28,
		brightness = 3.4,
		plateTransparency = 0.06,
	},
} :: { [string]: BandLook }

-- Within-band ramp at the band's last tier (each stays below the gap to the next band).
PlateStyle.RAMP = { halo = 0.08, scale = 0.035, brightness = 0.2 }

export type Style = BandLook & {
	band: string,
	level: number, -- continuous glow level: band index + position inside the band
	champion: boolean,
}

export type TierBand = { upTo: number, name: string }

-- Look for `tier` given the rarity bands (Economy.TIER_BANDS). `champion` = slot 1.
function PlateStyle.compute(tier: number, bands: { TierBand }, champion: boolean?): Style
	local index, low, high = #bands, 1, bands[#bands].upTo
	local from = 1
	for i, band in bands do
		if tier <= band.upTo then
			index, low, high = i, from, band.upTo
			break
		end
		from = band.upTo + 1
	end
	local frac = if high > low then math.clamp((tier - low) / (high - low), 0, 1) else 1
	local name = bands[index].name
	local look = PlateStyle.BANDS[name] or PlateStyle.BANDS.Common
	local top = PlateStyle.BANDS[bands[#bands].name] or look
	local ramp = PlateStyle.RAMP
	local style: Style = table.clone(look) :: any
	style.band = name
	style.level = index + frac * 0.9
	style.champion = champion == true
	style.halo = if look.halo > 0 then look.halo + ramp.halo * frac else 0
	style.scale = look.scale + ramp.scale * frac
	style.brightness = look.brightness + ramp.brightness * frac
	if champion then
		-- The champion wears the top band's effects at the top tier's full strength.
		style.plate = top.plate
		style.dark = top.dark
		style.text = top.text
		style.glow = top.glow
		style.gem = top.gem
		style.gemGlow = true
		style.cycle = true
		style.sparkles = true
		style.light = true
		style.shimmer = true
		style.strokeTransparency = math.min(style.strokeTransparency, top.strokeTransparency)
		style.strokeThickness = math.max(style.strokeThickness, top.strokeThickness)
		style.halo = math.max(style.halo, top.halo + ramp.halo)
		style.pulseSpeed = math.max(style.pulseSpeed, top.pulseSpeed)
		style.pulseAmp = math.max(style.pulseAmp, top.pulseAmp)
		style.scale = math.max(style.scale, top.scale + ramp.scale)
		style.brightness = math.max(style.brightness, top.brightness + ramp.brightness)
		style.plateTransparency = math.min(style.plateTransparency, top.plateTransparency)
	end
	return style
end

return PlateStyle
