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
	Unlocker = "CRATE CRACKER",
	PremiumUnlocker = "VIP CRATE CRACKER",
	Free = "DAILY GAINS",
	Surge = "AURA SURGE",
	Multiplier = "Aura Multiplier",
	BuyTier = "UPGRADE BUY TIER",
}

-- Onboarding tutorial (one entry per step in Shared.TutorialSteps) and the
-- loading screen. Hint is an optional second line shown under the text.
Theme.Tutorial = {
	Title = "CHAD TRAINING",
	Steps = {
		{
			Title = "Recruit your first Chad",
			Text = "Step on the glowing BUY 1 pad.",
			Icon = "🛒",
		},
		{
			Title = "Farm some aura",
			Text = "Your Chads drop aura orbs. Walk over them to fill your tank.",
			Icon = "✨",
		},
		{
			Title = "Convert your aura",
			Text = "Step on the AURA CONVERTER pad to send your tank in.",
			Icon = "⚗️",
		},
		{
			Title = "Secure the bag",
			Text = "Step on COLLECT CASH to bank what the converter made.",
			Icon = "💵",
		},
		{
			Title = "Mog merge!",
			Text = "Two Chads of the same tier merge into a stronger one. Step on the MOG MERGE pad.",
			Hint = "You need two of the same tier: buy one more on BUY 1 first.",
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
		"Tip: carry crates to the Crate Cracker to open them for free.",
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

Theme.Fonts = {
	Title = Enum.Font.LuckiestGuy,
	Body = Enum.Font.FredokaOne,
	Mono = Enum.Font.GothamBlack,
}

Theme.Colors = {
	Primary = GOLD,
	Secondary = PURPLE,
	Accent = rgb(255, 90, 160),
	Good = rgb(80, 220, 100),
	Bad = rgb(235, 80, 60),
	Text = rgb(255, 255, 255),
	TextDim = rgb(190, 185, 210),
	Panel = rgb(28, 24, 40),
	PanelLight = rgb(48, 42, 68),
	PanelDark = rgb(16, 14, 24),
	Stroke = rgb(8, 6, 14),
	Orb = rgb(200, 140, 255),
	OrbBig = GOLD,

	Floor = rgb(36, 34, 48),
	FloorAlt = rgb(46, 42, 60),
	Wall = rgb(52, 46, 72),
	WallTrim = rgb(30, 26, 42),
	Neon = GOLD,
	NeonAlt = PURPLE,
	Pad = rgb(255, 205, 60),
	PadDisabled = rgb(120, 115, 130),
	Hub = rgb(28, 26, 38),
	Sky = rgb(25, 18, 45),

	-- Plot decor (Theme.Decor = "gym").
	Rubber = rgb(30, 28, 36),
	Chrome = rgb(150, 155, 172),
	Iron = rgb(48, 46, 56),
	Leather = rgb(95, 40, 150),

	Window = {
		Shop = rgb(255, 190, 40),
		Index = rgb(150, 70, 255),
		Ranking = rgb(255, 120, 60),
		Settings = rgb(110, 110, 140),
	},

	Rarity = {
		Common = rgb(170, 170, 180),
		Uncommon = rgb(90, 220, 110),
		Rare = rgb(70, 160, 255),
		Epic = rgb(185, 90, 255),
		Legendary = rgb(255, 190, 40),
		Mythic = rgb(255, 70, 140),
	},
}

Theme.Lighting = {
	ClockTime = 20.5,
	Ambient = rgb(90, 80, 120),
	OutdoorAmbient = rgb(110, 95, 150),
	Brightness = 2,
	FogColor = rgb(40, 25, 70),
	FogEnd = 900,
	AtmosphereColor = rgb(140, 100, 220),
	AtmosphereDecay = rgb(70, 40, 120),
	BloomIntensity = 0.6,
	ColorTint = rgb(255, 245, 255),
}

-- Leave empty for no music, or paste a Roblox audio asset id ("rbxassetid://...").
Theme.MusicId = ""

-- Unit animation set (see ReplicatedStorage.Shared.Poses): gym poses.
Theme.AnimSet = "Chad"

-- Plot decoration style built by WorldBuilder: "gym" or "factory" (nil = none).
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
			skin = SKIN_TAN,
			shirt = rgb(205, 52, 52),
			pants = rgb(32, 32, 38),
			bottoms = "Shorts",
			hair = HAIR_BLACK,
			hairStyle = "Buzz",
			expr = "Happy",
			acc = { "Headband" },
			accColor = WHITE,
			buff = 0.12,
		},
	},
	{
		Name = "Protein Bro",
		Look = {
			skin = SKIN_LIGHT,
			shirt = WHITE,
			top = "Tank",
			pants = rgb(78, 80, 92),
			bottoms = "Joggers",
			hair = HAIR_BLOND,
			expr = "Determined",
			jaw = 0.4,
			acc = { "CapBack", "Dumbbell" },
			accColor = rgb(35, 95, 210),
			buff = 0.22,
		},
	},
	{
		Name = "Mewing Disciple",
		Look = {
			skin = SKIN_DARK,
			shirt = rgb(96, 62, 170),
			pants = rgb(36, 30, 52),
			bottoms = "Joggers",
			hair = HAIR_BLACK,
			hairStyle = "Buzz",
			beard = "Stubble",
			expr = "Stoic",
			jaw = true,
			acc = { "Headband" },
			accColor = rgb(170, 110, 255),
			buff = 0.28,
		},
	},
	{
		Name = "Jawline Jr.",
		Look = {
			skin = SKIN,
			shirt = INK,
			pants = rgb(72, 72, 84),
			hair = HAIR_BROWN,
			hairStyle = "Slick",
			expr = "Smirk",
			jaw = true,
			acc = { "Shades" },
			buff = 0.32,
		},
	},
	{
		Name = "Looksmaxxer",
		Look = {
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
		},
	},
	{
		Name = "Sigma Grinder",
		Look = {
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
			acc = { "Headphones" },
			accColor = rgb(220, 50, 50),
			buff = 0.42,
		},
	},
	{
		Name = "Rizz Apprentice",
		Look = {
			skin = SKIN_DARK,
			shirt = rgb(255, 140, 0),
			top = "Jacket",
			trim = WHITE,
			pants = rgb(40, 40, 52),
			hair = HAIR_BLACK,
			expr = "Smirk",
			jaw = true,
			acc = { "Cap", "Chain" },
			accColor = rgb(255, 140, 0),
			buff = 0.48,
		},
	},
	{
		Name = "Alpha Lifter",
		Look = {
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
			acc = { "Headband", "Wristbands", "Dumbbell" },
			accColor = WHITE,
			buff = 0.62,
			scale = 1.05,
		},
	},
	{
		Name = "Mogger",
		Look = {
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
			scale = 1.1,
			sparkles = true,
			aura = rgb(255, 255, 255),
		},
	},
	{
		Name = "Gigabrain Bro",
		Look = {
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
			scale = 1.1,
			glow = rgb(0, 200, 255),
		},
	},
	{
		Name = "Aura Farmer",
		Look = {
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
			scale = 1.1,
			aura = PURPLE,
		},
	},
	{
		Name = "Rizzlord",
		Look = {
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
			scale = 1.12,
			aura = rgb(255, 80, 170),
		},
	},
	{
		Name = "Sigma Supreme",
		Look = {
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
			scale = 1.15,
			aura = rgb(240, 240, 255),
		},
	},
	{
		Name = "Golden Jaw",
		Look = {
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
			scale = 1.15,
			aura = GOLD,
		},
	},
	{
		Name = "Diamond Chad",
		Look = {
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
			scale = 1.2,
			sparkles = true,
			aura = rgb(150, 230, 255),
		},
	},
	{
		Name = "Thunder Chad",
		Look = {
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
			scale = 1.2,
			aura = rgb(255, 240, 80),
			glow = rgb(255, 255, 120),
		},
	},
	{
		Name = "Cosmic Mogger",
		Look = {
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
			scale = 1.25,
			aura = PURPLE,
		},
	},
	{
		Name = "Aura Titan",
		Look = {
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
			scale = 1.3,
			aura = rgb(255, 255, 255),
			sparkles = true,
		},
	},
	{
		Name = "Mythic Rizzler",
		Look = {
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
			scale = 1.3,
			aura = rgb(255, 80, 170),
			fire = rgb(255, 60, 160),
		},
	},
	{
		Name = "Infinite Sigma",
		Look = {
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
			scale = 1.35,
			aura = rgb(255, 40, 40),
		},
	},
	{
		Name = "Celestial Chad",
		Look = {
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
			scale = 1.4,
			aura = rgb(150, 230, 255),
			sparkles = true,
		},
	},
	{
		Name = "Aura Overlord",
		Look = {
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
			scale = 1.45,
			aura = GOLD,
			fire = GOLD,
		},
	},
	{
		Name = "Omega Chad",
		Look = {
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
			scale = 1.5,
			aura = rgb(255, 30, 30),
			fire = rgb(255, 40, 0),
		},
	},
	{
		Name = "Absolute Chad",
		Look = {
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
			scale = 1.6,
			aura = GOLD,
			sparkles = true,
			fire = rgb(255, 220, 90),
		},
	},
}

Theme.Monetization = {
	Passes = {
		AutoLoot = { Id = 0, Price = 99, Title = "Auto Aura", Desc = "Aura flows straight into your tank", Color = rgb(255, 170, 40) },
		AutoCash = {
			Id = 0,
			Price = 49,
			Title = "Auto Cash",
			Desc = "Converted cash goes straight to your wallet",
			Color = rgb(70, 200, 90),
		},
		DoubleAura = { Id = 0, Price = 299, Title = "Double Aura", Desc = "Every Chad radiates 2x aura", Color = PURPLE },
		DoubleMoney = { Id = 0, Price = 199, Title = "2X Cash", Desc = "Permanent 2x cash from the converter", Color = rgb(60, 160, 255) },
		PremiumUnlocker = {
			Id = 0,
			Price = 149,
			Title = "VIP Cracker",
			Desc = "Second crate cracker, 3x faster",
			Color = rgb(255, 80, 160),
		},
	},
	PassOrder = { "AutoLoot", "AutoCash", "DoubleAura", "DoubleMoney", "PremiumUnlocker" },
	MoneyPacks = {
		{ Id = 0, Price = 19, Seconds = 300, Min = 1000 },
		{ Id = 0, Price = 49, Seconds = 900, Min = 3000 },
		{ Id = 0, Price = 99, Seconds = 2700, Min = 10000 },
		{ Id = 0, Price = 249, Seconds = 7200, Min = 30000 },
		{ Id = 0, Price = 499, Seconds = 18000, Min = 100000 },
		{ Id = 0, Price = 999, Seconds = 43200, Min = 300000 },
	},
	GemPacks = {
		{ Id = 0, Price = 49, Amount = 50 },
		{ Id = 0, Price = 249, Amount = 300 },
		{ Id = 0, Price = 599, Amount = 800 },
	},
}

return Theme
