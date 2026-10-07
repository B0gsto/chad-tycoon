--[[
	Theme: CHAD AURA TYCOON

	Everything the player sees that is specific to this variant: names, words,
	colours, fonts, lighting, the 25 unit tiers and the Roblox monetization IDs.
	Gameplay numbers live in ReplicatedStorage.Shared.Economy and are shared by
	both variants.

	To sell passes/products: create them on the Creator Dashboard and paste the
	IDs below. While an ID is 0, buying it in Studio grants it for free (test
	mode) and in a live server shows "coming soon".
]]

local rgb = Color3.fromRGB

local GOLD = rgb(255, 200, 45)
local PURPLE = rgb(165, 80, 255)

local Theme = {}

Theme.Id = "chad"
Theme.GameName = "Chad Aura Tycoon"
Theme.Tagline = "Farm aura. Merge Chads. Mog the server."

Theme.Words = {
	Unit = "Chad",
	Units = "Chads",
	Orb = "Aura",
	Gem = "Rizz",
	Chest = "Crate",
	Deposit = "AURA CONVERTER",
	Process = "Converting aura",
	Collect = "COLLECT CASH",
	Merge = "MOG MERGE",
	Unlocker = "CRATE SMASHER",
	PremiumUnlocker = "VIP CRATE SMASHER",
	Free = "DAILY GAINS",
	Surge = "AURA SURGE",
	Multiplier = "Aura Multiplier",
	BuyTier = "UPGRADE BUY TIER",
}

-- Onboarding tutorial (one entry per step in Shared.TutorialSteps) and the
-- loading screen. The quest pill shows Short; ShortHint is an optional small
-- second line shown for the first seconds of a step.
Theme.Tutorial = {
	Title = "CHAD TRAINING",
	Steps = {
		{
			Title = "Recruit your first Chad",
			Short = "Step on the BUY 1 pad",
			Text = "Step on the glowing BUY 1 pad.",
			Icon = "🛒",
		},
		{
			Title = "Farm some aura",
			Short = "Walk over the aura orbs",
			Text = "Your Chads drop aura orbs. Walk over them to fill up on aura.",
			Icon = "✨",
		},
		{
			Title = "Convert your aura",
			Short = "Step on the DEPOSIT pad",
			Text = "Step on the AURA CONVERTER pad to cash in the aura on your dumbbell.",
			Icon = "⚗️",
		},
		{
			Title = "Secure the bag",
			Short = "Step on COLLECT CASH",
			Text = "Step on COLLECT CASH to bank what the converter made.",
			Icon = "💵",
		},
		{
			Title = "Mog merge!",
			Short = "Merge two Chads on MOG MERGE",
			Text = "Two Chads of the same tier merge into a stronger one. Step on the MOG MERGE pad.",
			Hint = "You need two of the same tier: buy one more on BUY 1 first.",
			ShortHint = "Buy one more Chad first",
			Icon = "🔀",
		},
	},
	DoneTitle = "TRAINING COMPLETE!",
	DoneText = "You know the grind. Now go mog the whole server.",
	Skip = "Skip",
	SkipConfirm = "Skip the training? You'll miss the completion reward.",
	Follow = "Follow the arrow",
}

Theme.Loading = {
	Status = "Warming up the gym...",
	Tips = {
		"Tip: two Chads of the same tier merge into the next tier.",
		"Tip: deposit when the Aura Multiplier is high for more cash.",
		"Tip: during an Aura Surge every Chad drops double aura.",
		"Tip: walk into a crate to pick it up, then carry it to the Crate Smasher to open it free.",
	},
}

Theme.Icons = {
	Unit = "🗿",
	Orb = "✨",
	Gem = "💎",
	Money = "$",
	Home = "🏠",
	Ranking = "🏆",
	Index = "📖",
	Shop = "🛒",
	Invite = "🤝",
	Settings = "⚙️",
	Surge = "⚡",
	Premium = "⭐",
	Friends = "👥",
	Chest = "📦",
	Free = "🎁",
}

-- UI type roles (all faces ship with the Roblox client):
--   Display  hero titles only (window titles, reward cards, surge banner)
--   UI       buttons, tabs, labels, pills (uppercase)
--   Body     descriptions and copy, sentence case
--   Number   every number: money, gems, counters, prices, timers
Theme.Fonts = {
	Display = Enum.Font.LuckiestGuy,
	UI = Enum.Font.BuilderSansExtraBold,
	Bold = Enum.Font.BuilderSansBold,
	Body = Enum.Font.BuilderSansMedium,
	Number = Enum.Font.GothamBlack,
	-- Alias of Display used by world signs.
	Title = Enum.Font.LuckiestGuy,
}

Theme.Colors = {
	Primary = rgb(255, 212, 64),
	Secondary = rgb(170, 132, 255),
	Accent = rgb(255, 138, 190),
	Good = rgb(98, 224, 160),
	Bad = rgb(255, 112, 100),
	Text = rgb(255, 255, 255),
	TextDim = rgb(212, 224, 255),
	TextMute = rgb(160, 180, 232),
	-- UI surfaces: "bright toy". Royal-blue moulded plastic panels (lighter at
	-- the top, a darker blue lip below), deeper blue wells, a soft navy shadow.
	-- PanelDark is an alias of Well.
	-- Ink is the soft navy for shadows, halos and the backdrop dim (never darker
	-- than Theme.World.Ink).
	Ink = rgb(42, 54, 114),
	Surface = rgb(60, 82, 160),
	SurfaceHi = rgb(78, 102, 186),
	SurfaceHiTop = rgb(94, 120, 206),
	Well = rgb(46, 62, 136),
	-- Edge is the darker blue lip/outline of panels and dividers.
	Edge = rgb(38, 54, 124),
	PanelDark = rgb(46, 62, 136),
	-- Stroke is the outline used by world billboards (Theme.World.Ink); UI uses Edge.
	Stroke = rgb(58, 48, 96),
	-- Accents: sunny yellow is the one CTA colour (orange lip, Ink text), grape
	-- is secondary, mint is money, sky blue is gems, orange is the surge, coral
	-- is close/danger.
	Gold = rgb(255, 212, 64),
	GoldDeep = rgb(244, 150, 44),
	GoldLight = rgb(255, 236, 150),
	GoldInk = rgb(58, 48, 96),
	Violet = rgb(170, 132, 255),
	VioletDeep = rgb(122, 88, 214),
	Cash = rgb(98, 224, 160),
	CashDeep = rgb(36, 166, 108),
	MoneyText = rgb(150, 255, 196),
	Rizz = rgb(92, 204, 255),
	RizzDeep = rgb(36, 138, 218),
	Amber = rgb(255, 162, 72),
	Danger = rgb(255, 112, 100),
	Orb = rgb(200, 150, 255),
	OrbBig = GOLD,

	-- World surfaces (copies of Theme.World colours, read as world-code fallbacks, by the
	-- loading screen and by the preview stage). Neon/NeonAlt only name the preview stage's two
	-- trim colours: the world never uses the Neon material outside the aura orbs.
	Floor = rgb(224, 186, 124), -- World.Honey
	WallTrim = rgb(44, 170, 170), -- World.Teal
	Neon = rgb(255, 204, 48), -- World.Sunny
	NeonAlt = rgb(112, 210, 200), -- World.TealLight
	-- A disabled pad's soft grey face.
	PadDisabled = rgb(196, 192, 182),
	Sky = rgb(111, 180, 240), -- World.Sky
	-- Silver medal on the ranking board.
	Chrome = rgb(226, 232, 242),

	-- One header accent per window (the band behind the title).
	Window = {
		Shop = rgb(255, 212, 64),
		Index = rgb(170, 132, 255),
		Ranking = rgb(255, 162, 72),
		Settings = rgb(84, 204, 196),
	},

	Rarity = {
		Common = rgb(196, 204, 222),
		Uncommon = rgb(110, 226, 130),
		Rare = rgb(84, 178, 255),
		Epic = rgb(186, 120, 255),
		Legendary = rgb(255, 200, 56),
		Mythic = rgb(255, 104, 164),
	},
}

-- The 3D world's palette: a sunny "Muscle Beach" gym in clear afternoon light. Teal and blue
-- dominate (mats, walls, fences, machines, display), sunny yellow is the accent (awnings, chute,
-- buy pads, crates) and red-orange is the sparing pop (sign headers, special pads, Chad shirts).
-- Pink, Grape and Mint only go on small props and the fan zone. Nothing in the world uses the
-- Neon material except the aura orbs, and nothing is darker than Ink. World code reads these,
-- never the UI colours above.
local TEAL = rgb(44, 170, 170)
local TEAL_LIGHT = rgb(112, 210, 200)
local TEAL_DEEP = rgb(24, 118, 128)
local TEAL_INK = rgb(14, 78, 90)
local BUTTER = rgb(255, 230, 110)
local SUNNY = rgb(255, 204, 48)
local RED_ORANGE = rgb(240, 92, 52)
local CORAL = rgb(255, 112, 96)
local ORANGE = rgb(255, 162, 72)
local BLUE = rgb(92, 178, 255)
local PURE_WHITE = rgb(255, 255, 255)

-- Aura orb paint, one per producing unit tier (OrbLook.tierColor cycles through the list, so
-- neighbouring tiers always differ): aura violet, hot pink, sunny yellow, mint green, sky blue,
-- orange, coral red, cream.
Theme.OrbColors = {
	rgb(150, 76, 242),
	rgb(255, 92, 170),
	rgb(255, 208, 64),
	rgb(72, 214, 150),
	rgb(80, 170, 255),
	rgb(255, 150, 50),
	rgb(255, 96, 88),
	rgb(255, 236, 200),
}

Theme.World = {
	Sky = rgb(111, 180, 240),
	-- Turquoise-teal sea (greener and deeper than the blue sky, so the horizon line reads) and
	-- the light aqua lagoon round the island.
	Ocean = rgb(26, 150, 180),
	Shallows = rgb(118, 222, 210),
	-- Island beach and its wet shore line.
	Sand = rgb(238, 212, 164),
	SandDark = rgb(220, 190, 140),
	-- Plot floor: mid-tone warm honey sand, a step darker than the beach.
	Honey = rgb(224, 186, 124),
	Grass = rgb(92, 176, 96),
	GrassDark = rgb(64, 146, 80),
	-- Light path stone: the plaza's thin rim, plot floor border and the entrance runner (the one
	-- light surface on a plot). PathEdge dots the runner. Plaza is the hub plaza's paving, a
	-- warm honey sand a step deeper than the beach so it never blows out to white.
	Path = rgb(244, 234, 210),
	PathEdge = rgb(214, 188, 146),
	Plaza = rgb(232, 198, 140),
	-- Bleached boardwalk planks.
	Wood = rgb(222, 208, 182),
	WoodDark = rgb(186, 172, 148),
	-- Sign card faces, pen wall caps.
	Cream = rgb(255, 247, 232),
	White = PURE_WHITE,
	-- Darkest tone allowed in the world: sign text, outlines, tyres.
	Ink = rgb(58, 48, 96),
	-- Dark print on light pad faces.
	TealInk = TEAL_INK,
	-- Scoreboard face (white or Sunny text on top).
	Board = TEAL_DEEP,
	-- Teal family, the dominant hue. Teal: mats, walls, fences, posts, trims, machine bodies.
	-- TealLight: fence caps, light utility pads. TealDeep: scoreboard and deep accents only.
	Teal = TEAL,
	TealLight = TEAL_LIGHT,
	TealDeep = TEAL_DEEP,
	-- Gym floor mats (one teal, no alternating stripes: MatAlt is the lighter cap tone).
	Mat = TEAL,
	MatAlt = TEAL_LIGHT,
	-- Low stage wall behind the Chad rack.
	Backdrop = rgb(30, 112, 128),
	-- Pale powder-blue shelf back panels right behind the Chads (clearly darker than white in
	-- full sun), so every unit, dark or light clothed, reads as a clear silhouette and the
	-- white name plates stand out against them.
	RackBack = rgb(188, 214, 236),
	-- Pad base rim round every pad face.
	PadRim = rgb(30, 98, 124),
	-- Orb pen floor (light aqua, so orbs and crates pop) and its seams and gutter lining.
	Pool = rgb(156, 226, 230),
	PoolDeep = rgb(104, 196, 210),
	-- Accent yellows: Butter is the buy-pad face, Sunny awnings, chute, crates and bands.
	Butter = BUTTER,
	Sunny = SUNNY,
	-- The sparing warm pop: sign header bands, special pads, Chad shirts.
	RedOrange = RED_ORANGE,
	Coral = CORAL,
	Orange = ORANGE,
	-- Small props and the fan zone only.
	Pink = rgb(255, 138, 190),
	Mint = rgb(98, 224, 160),
	Grape = rgb(170, 132, 255),
	Blue = BLUE,
	Chrome = rgb(226, 232, 242),
	Steel = rgb(150, 164, 196),
	-- Parkour map hues (one family per map, Server.Modes.Course PALETTES / World.MapDecor).
	MintPale = rgb(184, 242, 206),
	Navy = rgb(36, 62, 138),
	HotPink = rgb(255, 64, 158),
	SkyBlue = rgb(166, 216, 255),
	Apricot = rgb(255, 196, 148),
	Terracotta = rgb(214, 102, 56),
	Slate = rgb(66, 76, 100),
	Volt = rgb(240, 255, 56),
	Basalt = rgb(40, 36, 46),
	Lava = rgb(255, 104, 18),
	Gold = rgb(255, 196, 40),
	-- One colour per pad job, so a pad's colour tells you what it does: yellows buy and
	-- upgrade, teal/blue move aura and cash, warm pops are the special pads.
	Pads = {
		Buy = BUTTER,
		BuyTier = SUNNY,
		Process = SUNNY,
		Deposit = BLUE,
		Collect = TEAL_LIGHT,
		Merge = RED_ORANGE,
		AutoMerge = RED_ORANGE,
		Unlock = CORAL,
		UnlockVip = ORANGE,
		Free = CORAL,
	},
	-- Icon print colour on each pad's face (same keys as Pads).
	PadPrint = {
		Buy = TEAL_INK,
		BuyTier = TEAL_INK,
		Process = TEAL_INK,
		Deposit = TEAL_INK,
		Collect = TEAL_INK,
		Merge = PURE_WHITE,
		AutoMerge = PURE_WHITE,
		Unlock = PURE_WHITE,
		UnlockVip = TEAL_INK,
		Free = PURE_WHITE,
	},
}

Theme.Lighting = {
	-- A clear early afternoon: a strong warm sun at about 55 degrees with short crisp shadows,
	-- cool blue fill that keeps shadowed faces mid-tone, a blue skybox under a light sky-blue
	-- haze that lifts the upper sky and fades to a pale horizon band, and almost no bloom.
	-- Exposure sits below zero so light paint stays off the clip; the haze density stays low so
	-- objects across the map are not fogged.
	ClockTime = 14.3,
	GeographicLatitude = 32,
	Ambient = rgb(97, 104, 133),
	OutdoorAmbient = rgb(113, 124, 161),
	Brightness = 2.6,
	Exposure = -0.45,
	EnvironmentDiffuseScale = 0.4,
	EnvironmentSpecularScale = 0.2,
	ShadowSoftness = 0.1,
	-- Warm tint on sunlit faces.
	ColorShiftTop = rgb(255, 240, 214),
	ColorShiftBottom = rgb(0, 0, 0),
	FogColor = rgb(200, 226, 246),
	FogStart = 1200,
	FogEnd = 4000,
	-- Haze paints the sky (Color near the horizon and sun, Decay away from the sun) over the
	-- skybox; Density alone decides how much it veils objects.
	AtmosphereColor = rgb(214, 234, 250),
	AtmosphereDecay = rgb(138, 190, 240),
	AtmosphereDensity = 0.025,
	AtmosphereOffset = 0.12,
	AtmosphereHaze = 1.3,
	AtmosphereGlare = 0,
	BloomIntensity = 0.02,
	BloomThreshold = 3,
	BloomSize = 6,
	ColorTint = rgb(255, 253, 250),
	ColorBrightness = -0.02,
	Saturation = 0.12,
	Contrast = 0.16,
	SunRaysIntensity = 0.015,
	SunRaysSpread = 0.3,
	-- Roblox's Baseplate-template skybox (Roblox-owned public assets): a cobalt zenith fading to
	-- a pale azure horizon; the haze above lightens it.
	Sky = {
		Back = "rbxassetid://6444884337",
		Front = "rbxassetid://6444884337",
		Left = "rbxassetid://6444884337",
		Right = "rbxassetid://6444884337",
		Down = "rbxassetid://6444884785",
		Up = "rbxassetid://6412503613",
		Sun = "rbxassetid://6196665106",
		Moon = "rbxassetid://6444320592",
		SunAngularSize = 14,
		StarCount = 0,
	},
	Clouds = { Cover = 0.3, Density = 0.35, Color = rgb(255, 255, 255) },
}

-- The fan club: cheering fans gather around a plot as its best Chad gets stronger.
-- Fans on a plot = clamp(Base + floor(bestTier * PerTier), 1, Max). Purely cosmetic.
Theme.Fans = {
	Max = 12,
	MaxOther = 4,
	Base = 3,
	PerTier = 0.5,
	Cheers = {
		"W CHAD!",
		"SO STRONG!",
		"AURA +1000!",
		"GO GO GO!",
		"MOGGED!",
		"LEGEND!",
		"NO WAY!!",
		"HE'S HIM!",
		"BEST GYM EVER!",
		"SIGN MY SHIRT!",
	},
	Signs = { "#1 FAN", "W AURA", "GO CHADS!", "TEAM CHAD", "MOG!" },
	-- CharacterFactory looks for the fans (anim "Fan": 6 girls, 2 boys). `prop` is the
	-- fan's default hand prop ("FanSign" | "PomPoms" | "FoamFinger"); a FanSign shows
	-- `signText` (model attribute "SignText"; change it with CharacterFactory.setSignText).
	Looks = {
		{
			anim = "Fan",
			scale = 0.88,
			skin = rgb(246, 206, 172),
			hair = rgb(240, 200, 120),
			hairStyle = "Ponytail",
			lashes = true,
			expr = "Cheer",
			top = "Tee",
			shirt = Theme.World.Pink,
			emblem = "Heart",
			trim = Theme.World.White,
			bottoms = "Skirt",
			skirt = Theme.World.Blue,
			pants = Theme.World.Cream,
			shoes = Theme.World.White,
			sole = Theme.World.Pink,
			acc = { "Bow" },
			accColor = Theme.World.Sunny,
			prop = "FanSign",
			signText = "#1 FAN",
		},
		{
			anim = "Fan",
			scale = 0.86,
			skin = rgb(234, 184, 146),
			hair = rgb(120, 78, 50),
			hairStyle = "Pigtails",
			lashes = true,
			expr = "Starry",
			top = "Hoodie",
			shirt = Theme.World.Mint,
			emblem = "Star",
			trim = Theme.World.Sunny,
			bottoms = "Joggers",
			pants = Theme.World.Blue,
			shoes = Theme.World.White,
			sole = Theme.World.Coral,
			accColor = Theme.World.Coral,
			prop = "PomPoms",
		},
		{
			anim = "Fan",
			scale = 0.9,
			skin = rgb(196, 140, 100),
			hair = rgb(70, 50, 40),
			hairStyle = "Bob",
			lashes = true,
			expr = "Cheer",
			top = "Tee",
			shirt = Theme.World.Sunny,
			emblem = "Disc",
			trim = Theme.World.Coral,
			bottoms = "Skirt",
			skirt = Theme.World.Coral,
			pants = Theme.World.Blue,
			shoes = Theme.World.White,
			sole = Theme.World.Mint,
			acc = { "Headband" },
			accColor = Theme.World.Mint,
			prop = "FanSign",
			signText = "GO CHADS!",
		},
		{
			anim = "Fan",
			scale = 0.9,
			skin = rgb(128, 86, 60),
			hair = rgb(70, 50, 40),
			hairStyle = "LongHair",
			lashes = true,
			expr = "Cheer",
			top = "Hoodie",
			shirt = Theme.World.Grape,
			emblem = "Heart",
			trim = Theme.World.White,
			bottoms = "Skirt",
			skirt = Theme.World.Pink,
			pants = Theme.World.Cream,
			shoes = Theme.World.White,
			sole = Theme.World.Grape,
			acc = { "Bow" },
			accColor = Theme.World.Sunny,
			prop = "FoamFinger",
		},
		{
			anim = "Fan",
			scale = 0.87,
			skin = rgb(246, 206, 172),
			hair = rgb(196, 98, 56),
			hairStyle = "Bun",
			lashes = true,
			expr = "Starry",
			top = "Tee",
			shirt = Theme.World.Mint,
			emblem = "Star",
			trim = Theme.World.White,
			bottoms = "Joggers",
			pants = Theme.World.Grape,
			shoes = Theme.World.White,
			sole = Theme.World.Sunny,
			acc = { "Headband" },
			accColor = Theme.World.Pink,
			prop = "PomPoms",
		},
		{
			anim = "Fan",
			scale = 0.88,
			skin = rgb(100, 66, 48),
			hair = rgb(70, 50, 40),
			hairStyle = "Ponytail",
			lashes = true,
			expr = "Cheer",
			top = "Tee",
			shirt = Theme.World.Orange,
			emblem = "Disc",
			trim = Theme.World.Sunny,
			bottoms = "Skirt",
			skirt = Theme.World.Blue,
			pants = Theme.World.Cream,
			shoes = Theme.World.White,
			sole = Theme.World.Blue,
			accColor = Theme.World.Mint,
			prop = "FanSign",
			signText = "W AURA",
		},
		{
			anim = "Fan",
			scale = 0.9,
			skin = rgb(234, 184, 146),
			hair = rgb(120, 78, 50),
			hairStyle = "Spiky",
			expr = "Cheer",
			top = "Hoodie",
			shirt = Theme.World.Blue,
			emblem = "Star",
			trim = Theme.World.Sunny,
			bottoms = "Joggers",
			pants = Theme.World.Steel,
			shoes = Theme.World.Sunny,
			sole = Theme.World.White,
			accColor = Theme.World.Orange,
			prop = "FoamFinger",
		},
		{
			anim = "Fan",
			scale = 0.9,
			skin = rgb(196, 140, 100),
			hair = rgb(70, 50, 40),
			hairStyle = "Buzz",
			expr = "Starry",
			top = "Tee",
			shirt = Theme.World.Coral,
			emblem = "Disc",
			trim = Theme.World.White,
			bottoms = "Joggers",
			pants = Theme.World.Blue,
			shoes = Theme.World.White,
			sole = Theme.World.Coral,
			acc = { "CapBack" },
			accColor = Theme.World.Sunny,
			prop = "FanSign",
			signText = "TEAM CHAD",
		},
	},
	-- The intro cutscene cast (built with manual = true: code poses them with
	-- RigPose.applyPose). Hero switches faces with CharacterFactory.setExpression.
	Cast = {
		Hero = {
			anim = "Chad",
			manual = true,
			skin = rgb(234, 184, 146),
			hair = rgb(120, 78, 50),
			hairStyle = "Quiff",
			buff = 0.1,
			expr = "Happy",
			exprs = { "Happy", "Sad", "Shock", "Determined" },
			top = "Tee",
			shirt = Theme.World.Blue,
			trim = Theme.World.White,
			bottoms = "Joggers",
			pants = Theme.World.Steel,
			shoes = Theme.World.White,
			sole = Theme.World.Blue,
		},
		Rival = {
			anim = "Chad",
			manual = true,
			scale = 1.35,
			skin = rgb(222, 166, 124),
			hair = rgb(240, 200, 120),
			hairStyle = "Slick",
			buff = 1,
			jaw = true,
			expr = "Smug",
			top = "Tank",
			shirt = Theme.World.White,
			bottoms = "Shorts",
			pants = Theme.World.Grape,
			shoes = Theme.World.Sunny,
			sole = Theme.World.White,
			acc = { "Shades", "Chain" },
			accColor = Theme.World.Sunny,
		},
		Fan = {
			anim = "Fan",
			manual = true,
			scale = 0.88,
			skin = rgb(246, 206, 172),
			hair = rgb(240, 200, 120),
			hairStyle = "Ponytail",
			lashes = true,
			expr = "Cheer",
			exprs = { "Cheer", "Starry", "Sad" },
			top = "Tee",
			shirt = Theme.World.Pink,
			emblem = "Heart",
			trim = Theme.World.White,
			bottoms = "Skirt",
			skirt = Theme.World.Blue,
			pants = Theme.World.Cream,
			shoes = Theme.World.White,
			sole = Theme.World.Pink,
			acc = { "Bow" },
			accColor = Theme.World.Sunny,
			prop = "FanSign",
			signText = "#1 FAN",
		},
	},
}

-- The opening story, played once for new players (see Client.Intro; the beats and
-- their timing are in Client.Intro.Timeline). A fan-club story: no romance.
Theme.Intro = {
	Skip = "Skip",
	HeroName = "YOU",
	FanName = "YOUR #1 FAN",
	RivalName = "MAX GIGA CHAD",
	RivalStat = "AURA: 999,999,999",
	-- The hero's floating tag: Stat with his aura, which counts down from HeroAura to 0.
	Stat = "AURA: %d",
	HeroAura = 12,
	SignBefore = "#1 FAN",
	SignAfter = "TEAM GIGA",
	-- Speech and thought bubbles (stars and sparkles, never hearts).
	Bubbles = {
		Wow = "WOW!! ★",
		Giga = "GIGA!!",
		Cool = "SO COOL! ★",
		Stars = "★ ★ ★",
		Dots = "...",
		Huh = "?!",
	},
	Lines = {
		Meet = "This is you. And this is your #1 fan!",
		Good = "Life at the gym was pretty good...",
		Arrive = "...until HE showed up.",
		Wow = "WOW! Look at all that AURA!",
		Leave = "And just like that, she joined HIS fan club.",
		Sad = "Aura: zero. Even the dumbbell is leaving!",
		Idea1 = "Wait a second...",
		Idea2 = "Chads make aura. And aura makes CASH!",
		Plan = "Time to open your OWN gym, full of Chads!",
		Go = "Get Chads. Farm aura. Get rich. Win your fan back!",
	},
}

-- Leave empty for no music, or paste a Roblox audio asset id ("rbxassetid://...").
Theme.MusicId = ""
-- Music during an Aura Surge ("rbxassetid://..."). Empty: the other built-in track,
-- played a little faster (or the same track sped up when only one loads).
Theme.SurgeMusicId = ""

-- Unit animation set (see ReplicatedStorage.Shared.Poses): gym poses.
Theme.AnimSet = "Chad"

-- Plot decoration style built by WorldBuilder: "gym" (nil = none).
Theme.Decor = "gym"

local SKIN = rgb(234, 184, 146)
local SKIN_LIGHT = rgb(246, 206, 172)
local SKIN_TAN = rgb(196, 140, 100)
local SKIN_DARK = rgb(120, 80, 55)
local HAIR_BROWN = rgb(66, 44, 30)
local HAIR_BLACK = rgb(30, 26, 26)
local HAIR_BLOND = rgb(232, 192, 110)
local WHITE = rgb(245, 245, 248)
local INK = rgb(22, 22, 28)

-- 25 tiers, weakest to strongest. Each pair of tier N merges into tier N+1.
-- Looks are built by Shared.CharacterFactory (see its header for every field).
Theme.Tiers = {
	{
		Name = "Normie",
		Look = {
			skin = SKIN,
			shirt = rgb(140, 142, 152),
			pants = rgb(62, 84, 134),
			shoes = rgb(96, 96, 108),
			hair = HAIR_BROWN,
			hairStyle = "Flat",
			expr = "Neutral",
		},
	},
	{
		Name = "Gym Rookie",
		Look = {
			scale = 1.03,
			skin = SKIN_TAN,
			shirt = rgb(205, 52, 52),
			pants = rgb(32, 32, 38),
			bottoms = "Shorts",
			hair = HAIR_BLACK,
			hairStyle = "Buzz",
			expr = "Happy",
			acc = { "Headband", "Wristbands" },
			accColor = WHITE,
			buff = 0.12,
		},
	},
	{
		Name = "Protein Bro",
		Look = {
			scale = 1.06,
			skin = SKIN_LIGHT,
			shirt = WHITE,
			top = "Tank",
			pants = rgb(78, 80, 92),
			bottoms = "Joggers",
			hair = HAIR_BLOND,
			expr = "Determined",
			jaw = 0.4,
			acc = { "CapBack", "Dumbbell", "Towel" },
			accColor = rgb(35, 95, 210),
			buff = 0.22,
			aura = rgb(90, 160, 255),
			auraRate = 1.5,
		},
	},
	{
		Name = "Mewing Disciple",
		Look = {
			scale = 1.08,
			skin = SKIN_DARK,
			shirt = rgb(96, 62, 170),
			pants = rgb(36, 30, 52),
			bottoms = "Joggers",
			hair = HAIR_BLACK,
			hairStyle = "Buzz",
			beard = "Stubble",
			expr = "Stoic",
			jaw = true,
			acc = { "Headband", "Chain" },
			accColor = rgb(170, 110, 255),
			buff = 0.28,
			aura = rgb(170, 110, 255),
			auraRate = 2,
		},
	},
	{
		Name = "Jawline Jr.",
		Look = {
			scale = 1.1,
			skin = SKIN,
			shirt = INK,
			pants = rgb(72, 72, 84),
			hair = HAIR_BROWN,
			hairStyle = "Slick",
			expr = "Smirk",
			jaw = true,
			acc = { "Shades", "Wristbands" },
			accColor = rgb(80, 220, 160),
			buff = 0.32,
			aura = rgb(80, 220, 160),
			auraRate = 2.5,
		},
	},
	{
		Name = "Looksmaxxer",
		Look = {
			scale = 1.12,
			skin = SKIN_TAN,
			shirt = rgb(255, 110, 185),
			pants = WHITE,
			shoes = rgb(255, 110, 185),
			hair = HAIR_BLOND,
			hairStyle = "Quiff",
			expr = "Smug",
			jaw = true,
			acc = { "Shades", "Chain" },
			buff = 0.38,
			aura = rgb(255, 110, 185),
			auraRate = 3,
		},
	},
	{
		Name = "Sigma Grinder",
		Look = {
			scale = 1.14,
			skin = SKIN,
			shirt = rgb(30, 30, 40),
			top = "Hoodie",
			pants = rgb(30, 30, 40),
			bottoms = "Joggers",
			shoes = INK,
			sole = rgb(200, 40, 40),
			hair = HAIR_BLACK,
			hairStyle = "Slick",
			expr = "Stoic",
			jaw = true,
			acc = { "Headphones", "Shoulders" },
			accColor = rgb(220, 50, 50),
			buff = 0.42,
			aura = rgb(220, 50, 50),
			auraRate = 3.5,
		},
	},
	{
		Name = "Rizz Apprentice",
		Look = {
			scale = 1.15,
			skin = SKIN_DARK,
			shirt = rgb(255, 140, 0),
			top = "Jacket",
			trim = WHITE,
			pants = rgb(40, 40, 52),
			hair = HAIR_BLACK,
			expr = "Smirk",
			jaw = true,
			acc = { "Cap", "Chain", "Wristbands" },
			accColor = rgb(255, 140, 0),
			buff = 0.48,
			aura = rgb(255, 160, 40),
			auraRate = 4,
		},
	},
	{
		Name = "Alpha Lifter",
		Look = {
			scale = 1.16,
			skin = SKIN_TAN,
			shirt = rgb(185, 0, 0),
			top = "Tank",
			pants = rgb(22, 22, 28),
			bottoms = "Shorts",
			shoes = rgb(185, 0, 0),
			hair = HAIR_BROWN,
			hairStyle = "Spiky",
			expr = "Angry",
			jaw = true,
			acc = { "Headband", "Wristbands", "Dumbbell", "Chain" },
			accColor = WHITE,
			buff = 0.62,
			aura = rgb(255, 60, 60),
			auraRate = 5,
		},
	},
	{
		Name = "Mogger",
		Look = {
			scale = 1.17,
			skin = SKIN,
			shirt = rgb(14, 14, 16),
			top = "Tank",
			pants = rgb(14, 14, 16),
			shoes = INK,
			hair = HAIR_BLACK,
			hairStyle = "Slick",
			beard = "Stubble",
			expr = "Smug",
			jaw = true,
			acc = { "Shades", "Chain" },
			buff = 0.7,
			sparkles = true,
			aura = rgb(255, 255, 255),
		},
	},
	{
		Name = "Gigabrain Bro",
		Look = {
			scale = 1.18,
			skin = SKIN_DARK,
			shirt = rgb(0, 150, 255),
			pants = rgb(20, 30, 60),
			shoes = rgb(0, 150, 255),
			hair = HAIR_BLACK,
			hairStyle = "Flat",
			expr = "Determined",
			jaw = true,
			acc = { "Visor", "Headphones" },
			accColor = rgb(0, 220, 255),
			buff = 0.7,
			glow = rgb(0, 200, 255),
		},
	},
	{
		Name = "Aura Farmer",
		Look = {
			scale = 1.19,
			skin = SKIN,
			shirt = rgb(125, 60, 210),
			top = "Hoodie",
			pants = rgb(42, 26, 72),
			bottoms = "Joggers",
			hair = HAIR_BROWN,
			hairStyle = "Bun",
			beard = "Stubble",
			expr = "Smug",
			jaw = true,
			acc = { "Towel" },
			accColor = rgb(235, 225, 255),
			buff = 0.75,
			aura = PURPLE,
		},
	},
	{
		Name = "Rizzlord",
		Look = {
			scale = 1.2,
			skin = SKIN_TAN,
			shirt = rgb(205, 0, 95),
			top = "Jacket",
			trim = rgb(30, 10, 25),
			pants = rgb(30, 10, 25),
			shoes = rgb(30, 10, 25),
			hair = HAIR_BROWN,
			hairStyle = "Quiff",
			expr = "Smirk",
			jaw = true,
			acc = { "Cape", "Chain" },
			accColor = rgb(160, 0, 70),
			buff = 0.8,
			aura = rgb(255, 80, 170),
		},
	},
	{
		Name = "Sigma Supreme",
		Look = {
			scale = 1.21,
			skin = SKIN,
			shirt = rgb(12, 12, 14),
			top = "Tank",
			pants = rgb(12, 12, 14),
			shoes = rgb(12, 12, 14),
			hair = HAIR_BLACK,
			hairStyle = "Slick",
			beard = "Stubble",
			expr = "Stoic",
			jaw = true,
			acc = { "Cape", "Shades" },
			accColor = rgb(24, 24, 30),
			buff = 0.85,
			aura = rgb(240, 240, 255),
		},
	},
	{
		Name = "Golden Jaw",
		Look = {
			scale = 1.22,
			skin = GOLD,
			shirt = rgb(255, 215, 90),
			top = "Shirtless",
			pants = rgb(200, 150, 30),
			shoes = rgb(255, 225, 120),
			sole = rgb(200, 150, 30),
			material = "Metal",
			hair = rgb(255, 225, 120),
			hairStyle = "Slick",
			expr = "Smirk",
			jaw = true,
			acc = { "Shades", "Chain", "ChampBelt" },
			accColor = GOLD,
			buff = 0.9,
			aura = GOLD,
		},
	},
	{
		Name = "Diamond Chad",
		Look = {
			scale = 1.23,
			skin = rgb(175, 232, 255),
			shirt = rgb(120, 200, 255),
			top = "Shirtless",
			pants = rgb(90, 160, 230),
			shoes = rgb(210, 245, 255),
			material = "Glass",
			hair = rgb(130, 220, 255),
			hairStyle = "Spiky",
			expr = "Smug",
			jaw = true,
			acc = { "Crown" },
			accColor = rgb(130, 230, 255),
			buff = 0.9,
			sparkles = true,
			aura = rgb(150, 230, 255),
		},
	},
	{
		Name = "Thunder Chad",
		Look = {
			scale = 1.24,
			skin = SKIN_TAN,
			shirt = rgb(255, 225, 0),
			top = "Tank",
			pants = rgb(30, 30, 42),
			shoes = rgb(255, 225, 0),
			hair = HAIR_BLOND,
			hairStyle = "Spiky",
			expr = "Angry",
			eyeGlow = rgb(255, 250, 160),
			jaw = true,
			acc = { "Headband", "Cape", "Wristbands" },
			accColor = rgb(255, 235, 70),
			buff = 1,
			aura = rgb(255, 240, 80),
			glow = rgb(255, 255, 120),
		},
	},
	{
		Name = "Cosmic Mogger",
		Look = {
			scale = 1.25,
			skin = rgb(95, 45, 180),
			shirt = rgb(40, 10, 90),
			top = "Shirtless",
			pants = rgb(26, 8, 60),
			shoes = rgb(200, 150, 255),
			material = "ForceField",
			hair = rgb(210, 150, 255),
			hairStyle = "Slick",
			expr = "Stoic",
			eyeGlow = rgb(255, 255, 255),
			jaw = true,
			acc = { "Halo" },
			accColor = rgb(210, 140, 255),
			buff = 1,
			aura = PURPLE,
		},
	},
	{
		Name = "Aura Titan",
		Look = {
			scale = 1.26,
			skin = rgb(245, 240, 230),
			shirt = rgb(230, 225, 215),
			top = "Shirtless",
			pants = rgb(200, 195, 185),
			shoes = rgb(230, 225, 215),
			material = "Marble",
			hair = rgb(250, 248, 240),
			hairStyle = "Slick",
			beard = "Beard",
			expr = "Determined",
			jaw = true,
			acc = { "Crown", "Cape" },
			accColor = GOLD,
			buff = 1,
			aura = rgb(255, 255, 255),
			sparkles = true,
		},
	},
	{
		Name = "Mythic Rizzler",
		Look = {
			scale = 1.27,
			skin = SKIN,
			shirt = rgb(255, 0, 125),
			top = "Jacket",
			trim = WHITE,
			pants = rgb(80, 0, 40),
			shoes = WHITE,
			hair = rgb(255, 130, 205),
			hairStyle = "Quiff",
			expr = "Smirk",
			jaw = true,
			acc = { "Crown", "Wings" },
			accColor = rgb(255, 120, 200),
			buff = 1,
			aura = rgb(255, 80, 170),
			fire = rgb(255, 60, 160),
		},
	},
	{
		Name = "Infinite Sigma",
		Look = {
			scale = 1.28,
			skin = rgb(26, 26, 30),
			shirt = rgb(12, 12, 14),
			top = "Shirtless",
			pants = rgb(12, 12, 14),
			shoes = rgb(12, 12, 14),
			sole = rgb(255, 40, 40),
			material = "Slate",
			hairStyle = "Bald",
			expr = "Stoic",
			eyeGlow = rgb(255, 50, 50),
			jaw = true,
			acc = { "Halo", "Cape" },
			accColor = rgb(255, 40, 40),
			buff = 1,
			aura = rgb(255, 40, 40),
		},
	},
	{
		Name = "Celestial Chad",
		Look = {
			scale = 1.285,
			skin = rgb(240, 242, 255),
			shirt = rgb(220, 235, 255),
			top = "Shirtless",
			pants = rgb(190, 210, 255),
			shoes = WHITE,
			material = "Glass",
			hair = rgb(235, 245, 255),
			hairStyle = "Bun",
			expr = "Happy",
			eyeGlow = rgb(150, 230, 255),
			jaw = true,
			acc = { "Halo", "Wings" },
			accColor = rgb(150, 230, 255),
			buff = 1,
			aura = rgb(150, 230, 255),
			sparkles = true,
		},
	},
	{
		Name = "Aura Overlord",
		Look = {
			scale = 1.29,
			skin = GOLD,
			shirt = rgb(255, 225, 120),
			top = "Shirtless",
			pants = rgb(180, 130, 20),
			shoes = rgb(255, 225, 120),
			material = "Metal",
			hair = rgb(255, 225, 120),
			hairStyle = "Slick",
			beard = "Beard",
			expr = "Smug",
			jaw = true,
			acc = { "Crown", "Wings", "Cape" },
			accColor = GOLD,
			buff = 1,
			aura = GOLD,
			fire = GOLD,
		},
	},
	{
		Name = "Omega Chad",
		Look = {
			scale = 1.295,
			skin = rgb(60, 6, 6),
			shirt = rgb(150, 0, 20),
			top = "Shirtless",
			pants = rgb(26, 0, 0),
			shoes = rgb(26, 0, 0),
			sole = rgb(255, 40, 0),
			material = "ForceField",
			hair = rgb(255, 40, 20),
			hairStyle = "Spiky",
			expr = "Angry",
			eyeGlow = rgb(255, 60, 30),
			jaw = true,
			acc = { "Horns", "Wings", "Cape" },
			accColor = rgb(255, 30, 30),
			buff = 1,
			aura = rgb(255, 30, 30),
			fire = rgb(255, 40, 0),
		},
	},
	{
		Name = "Absolute Chad",
		Look = {
			scale = 1.3,
			skin = rgb(255, 215, 80),
			shirt = rgb(255, 235, 150),
			top = "Shirtless",
			pants = rgb(255, 200, 60),
			material = "Neon",
			hair = rgb(255, 245, 200),
			hairStyle = "Slick",
			expr = "Stoic",
			jaw = true,
			acc = { "Crown", "Halo", "Wings" },
			accColor = rgb(255, 255, 255),
			buff = 1,
			aura = GOLD,
			sparkles = true,
			fire = rgb(255, 220, 90),
		},
	},
}

-- Roblox badges (Server.Badges). Ids come from tools/badges.py; 0 = not created yet (skipped).
Theme.Badges = {
	Welcome = { Id = 204493874675594, Name = "Welcome to the Gym", Desc = "You joined Chad Aura Tycoon. Time to get swole!" },
	GymGraduate = { Id = 3879673344738499, Name = "Gym Graduate", Desc = "Finished the gym tutorial." },
	CertifiedChad = { Id = 750945717242204, Name = "Certified Chad", Desc = "Discovered a tier 10 Chad." },
	AbsoluteChad = { Id = 3658346446208010, Name = "Absolute Chad", Desc = "Discovered the Absolute Chad, the top tier!" },
	ParkourMaster = { Id = 3548287220393826, Name = "Parkour Master", Desc = "Cleared parkour level 10." },
}

Theme.Monetization = {
	Passes = {
		AutoLoot = {
			Id = 2005869821,
			Price = 99,
			Title = "Auto Aura",
			Desc = "Aura flies to you by itself",
			Color = rgb(255, 170, 40),
		},
		AutoMerge = {
			Id = 2014838314,
			Price = 79,
			Title = "Auto Merge",
			Desc = "Pairs merge by themselves",
			Color = rgb(255, 120, 60),
		},
		AutoCash = {
			Id = 2006853781,
			Price = 49,
			Title = "Auto Cash",
			Desc = "Converted cash goes straight to your wallet",
			Color = rgb(70, 200, 90),
		},
		DoubleAura = { Id = 2004519839, Price = 299, Title = "Double Aura", Desc = "Every Chad radiates 2x aura", Color = PURPLE },
		DoubleMoney = {
			Id = 2006967746,
			Price = 199,
			Title = "2X Cash",
			Desc = "Permanent 2x cash from the converter",
			Color = rgb(60, 160, 255),
		},
		PremiumUnlocker = {
			Id = 2008988383,
			Price = 149,
			Title = "VIP Smasher",
			Desc = "Second crate smasher, 3x faster",
			Color = rgb(255, 80, 160),
		},
		-- Owners open any held crate instantly for free (instead of buying CrateOpen each time).
		CrateKey = {
			Id = 2007069852,
			Price = 100,
			Title = "Crate Master",
			Desc = "Open every crate instantly, forever",
			Color = rgb(255, 200, 40),
		},
		-- Cosmetics (Theme.Cosmetics): sold in their own shop section, not in PassOrder.
		SpeedBoost = { Id = 2005653801, Price = 79, Title = "Speedy Sneakers", Desc = "Run 30% faster", Color = rgb(92, 178, 255) },
		DoubleJump = { Id = 2008406399, Price = 79, Title = "Double Jump", Desc = "Jump again in mid-air", Color = rgb(170, 132, 255) },
		TrailRainbow = {
			Id = 2005173883,
			Price = 49,
			Title = "Rainbow Trail",
			Desc = "A rainbow ribbon follows you",
			Color = rgb(255, 138, 190),
		},
		TrailStar = { Id = 2008281806, Price = 49, Title = "Star Trail", Desc = "A sunny ribbon full of stars", Color = rgb(255, 212, 64) },
		AuraGlow = { Id = 2005683724, Price = 99, Title = "Chad Aura", Desc = "A sparkling aura all around you", Color = rgb(255, 162, 72) },
		Crown = { Id = 2008880411, Price = 129, Title = "Golden Crown", Desc = "A chunky golden crown", Color = rgb(255, 200, 45) },
		AllCosmetics = {
			Id = 2005539739,
			Price = 299,
			Title = "All Cosmetics Pack",
			Desc = "Every cosmetic, now and later",
			Color = rgb(255, 122, 110),
		},
		-- One per account: cash, Rizz and the Rookie Trail, granted once (Theme.Cosmetics.Starter).
		StarterPack = {
			Id = 2008886371,
			Price = 59,
			Title = "Starter Pack",
			Desc = "Cash, Rizz and the Rookie Trail",
			Color = rgb(98, 224, 160),
		},
	},
	PassOrder = { "AutoLoot", "AutoMerge", "AutoCash", "DoubleAura", "DoubleMoney", "PremiumUnlocker", "CrateKey" },
	-- Cash packs give `Seconds` of the buyer's income, never below their progression floor
	-- (Economy.moneyPackAmount); `Min` is the absolute floor for brand-new players. Packs are
	-- 15 min / 1 h / 5 h / 24 h of income.
	MoneyPacks = {
		{ Id = 3716878815, Price = 49, Seconds = 900, Min = 2500 },
		{ Id = 3716953998, Price = 199, Seconds = 3600, Min = 10000 },
		{ Id = 3716878844, Price = 499, Seconds = 18000, Min = 50000 },
		{ Id = 3716954002, Price = 1000, Seconds = 86400, Min = 250000 },
	},
	-- Aura packs put aura straight into the buyer's tank (profile.carried, ready for the
	-- converter): `Seconds` of the buyer's aura production, never below the progression floor
	-- (Economy.auraPackAmount); `Min` is the floor for brand-new players. Roblox names:
	-- "Aura Pack: 15 Minutes / 1 Hour / 5 Hours / 24 Hours".
	AuraPacks = {
		{ Id = 3716954009, Price = 49, Seconds = 900, Min = 2500 },
		{ Id = 3716954016, Price = 199, Seconds = 3600, Min = 10000 },
		{ Id = 3716954024, Price = 499, Seconds = 18000, Min = 50000 },
		{ Id = 3716954037, Price = 1000, Seconds = 86400, Min = 250000 },
	},
	-- Retired cash packs (5 min / 45 min / 2 h / 12 h). Never prompted or shown, but a
	-- receipt that was still pending when they left the shop is honoured at its old size.
	LegacyMoneyPacks = {
		{ Id = 3716878799, Seconds = 300, Min = 750 },
		{ Id = 3716878826, Seconds = 2700, Min = 7500 },
		{ Id = 3716878834, Seconds = 7200, Min = 20000 },
		{ Id = 3716878853, Seconds = 43200, Min = 125000 },
	},
	-- Rizz packs give `Base` Rizz at tier 1, growing with the buyer's highest tier
	-- (Economy.gemPackAmount). Roblox names: Small / Big / Mega Rizz Pack.
	GemPacks = {
		{ Id = 3716878857, Price = 49, Base = 50 },
		{ Id = 3716878861, Price = 249, Base = 300 },
		{ Id = 3716878866, Price = 599, Base = 800 },
	},
	-- Instant crate opening: one developer product, the same price for every crate rarity.
	CrateOpen = { Id = 3716878439, Price = 30 },
}

-- Game modes (Server.GameModes). A Parkour or Mog Test finish pays `Seconds` of the player's
-- income, never below their progression floor nor `Min` (Economy.modeReward, sized like a cash
-- pack: this was the retired 5-minute pack), with Economy.MODE_REWARD_COOLDOWN between full rewards.
Theme.Modes = {
	Reward = { Seconds = 300, Min = 750 },
}

-- Cosmetics: each item is unlocked by its own game pass (Theme.Monetization.Passes[Pass]) or
-- by the Bundle pass; a `Starter` item has no pass of its own and comes only with the
-- Starter pack (the bundle does not include it). Kind "trail": one equipped at a time (or
-- none). Kind "perk" / "wear": on/off toggles, on by default once owned. Colors run along a
-- trail from the player backwards. Icon = art/out/icons/<Icon>.png (the pass icon).
Theme.Cosmetics = {
	Order = { "SpeedBoost", "DoubleJump", "TrailRainbow", "TrailStar", "TrailRookie", "AuraGlow", "Crown" },
	Items = {
		SpeedBoost = {
			Pass = "SpeedBoost",
			Title = "Speedy Sneakers",
			Desc = "Run 30% faster, with little speed puffs",
			Kind = "perk",
			Icon = "CosSpeed",
			Color = Theme.World.Blue,
			SpeedMultiplier = 1.3,
		},
		DoubleJump = {
			Pass = "DoubleJump",
			Title = "Double Jump",
			Desc = "Jump again in mid-air with a star burst",
			Kind = "perk",
			Icon = "CosDoubleJump",
			Color = Theme.World.Grape,
		},
		TrailRainbow = {
			Pass = "TrailRainbow",
			Title = "Rainbow Trail",
			Desc = "A rainbow ribbon follows you everywhere",
			Kind = "trail",
			Icon = "CosTrailRainbow",
			Color = Theme.World.Pink,
			Colors = { Theme.World.Pink, Theme.World.Orange, Theme.World.Sunny, Theme.World.Mint, Theme.World.Blue, Theme.World.Grape },
		},
		TrailStar = {
			Pass = "TrailStar",
			Title = "Star Trail",
			Desc = "A sunny ribbon that sheds little stars",
			Kind = "trail",
			Icon = "CosTrailStar",
			Color = Theme.World.Sunny,
			Colors = { Theme.World.Sunny, Theme.World.Orange, Theme.World.Cream },
			Stars = true,
		},
		TrailRookie = {
			Starter = true,
			Title = "Rookie Trail",
			Desc = "A fresh mint ribbon, only in the Starter Pack",
			Kind = "trail",
			Icon = "CosTrailRookie",
			Color = Theme.World.Mint,
			Colors = { Theme.World.Mint, Theme.World.Mint, Theme.World.White },
		},
		AuraGlow = {
			Pass = "AuraGlow",
			Title = "Chad Aura",
			Desc = "A soft sparkling aura around you",
			Kind = "wear",
			Icon = "CosAura",
			Color = Theme.World.Sunny,
		},
		Crown = {
			Pass = "Crown",
			Title = "Golden Crown",
			Desc = "A chunky golden crown on your head",
			Kind = "wear",
			Icon = "CosCrown",
			Color = rgb(255, 200, 45),
			Model = "props/Crown",
		},
	},
	-- Owning this pass counts as owning every non-Starter item, including ones added later.
	Bundle = "AllCosmetics",
	BundleIcon = "CosAll",
	-- Granted once per account: `CashSeconds` of income (Economy.moneyPackAmount, at least
	-- `CashMin`), the Rizz of GemPacks[GemPack] (Economy.gemPackAmount) and `Item`.
	Starter = { Pass = "StarterPack", CashSeconds = 1800, CashMin = 5000, GemPack = 2, Item = "TrailRookie", Icon = "CosStarter" },
	-- Humanoid WalkSpeed before any boost.
	BaseWalkSpeed = 16,
}

return Theme
