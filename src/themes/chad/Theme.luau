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

-- Plot decoration style built by WorldBuilder: "gym" or "factory" (nil = none).
Theme.Decor = "gym"

local SKIN = rgb(234, 184, 146)
local SKIN_TAN = rgb(196, 140, 100)
local SKIN_DARK = rgb(120, 80, 55)

-- 25 tiers, weakest to strongest. Each pair of tier N merges into tier N+1.
Theme.Tiers = {
	{ Name = "Normie", Look = { skin = SKIN, shirt = rgb(140, 140, 150), pants = rgb(60, 80, 130), face = "😐" } },
	{
		Name = "Gym Rookie",
		Look = {
			skin = SKIN_TAN,
			shirt = rgb(200, 50, 50),
			pants = rgb(30, 30, 35),
			face = "🙂",
			acc = { "Headband" },
			accColor = rgb(245, 245, 245),
			buff = 0.1,
		},
	},
	{
		Name = "Protein Bro",
		Look = {
			skin = SKIN,
			shirt = rgb(240, 240, 240),
			pants = rgb(40, 40, 45),
			face = "😤",
			acc = { "Cap" },
			accColor = rgb(30, 90, 200),
			buff = 0.2,
		},
	},
	{
		Name = "Mewing Disciple",
		Look = {
			skin = SKIN_DARK,
			shirt = rgb(90, 60, 160),
			pants = rgb(35, 30, 50),
			face = "😑",
			jaw = true,
			acc = { "Headband" },
			accColor = PURPLE,
			buff = 0.25,
		},
	},
	{
		Name = "Jawline Jr.",
		Look = { skin = SKIN, shirt = rgb(25, 25, 30), pants = rgb(70, 70, 80), face = "😏", jaw = true, acc = { "Shades" }, buff = 0.3 },
	},
	{
		Name = "Looksmaxxer",
		Look = {
			skin = SKIN_TAN,
			shirt = rgb(255, 105, 180),
			pants = rgb(250, 250, 250),
			face = "😎",
			jaw = true,
			acc = { "Shades", "Chain" },
			buff = 0.35,
		},
	},
	{
		Name = "Sigma Grinder",
		Look = { skin = SKIN, shirt = rgb(28, 28, 38), pants = rgb(28, 28, 38), face = "🗿", jaw = true, acc = { "Shades" }, buff = 0.4 },
	},
	{
		Name = "Rizz Apprentice",
		Look = {
			skin = SKIN_DARK,
			shirt = rgb(255, 140, 0),
			pants = rgb(40, 40, 50),
			face = "😏",
			jaw = true,
			acc = { "Cap", "Chain" },
			accColor = rgb(255, 140, 0),
			buff = 0.45,
		},
	},
	{
		Name = "Alpha Lifter",
		Look = {
			skin = SKIN_TAN,
			shirt = rgb(180, 0, 0),
			pants = rgb(20, 20, 25),
			face = "😤",
			jaw = true,
			acc = { "Headband", "Chain" },
			accColor = rgb(255, 255, 255),
			buff = 0.6,
			scale = 1.05,
		},
	},
	{
		Name = "Mogger",
		Look = {
			skin = SKIN,
			shirt = rgb(12, 12, 14),
			pants = rgb(12, 12, 14),
			face = "🗿",
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
			face = "🧐",
			jaw = true,
			acc = { "Visor" },
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
			shirt = rgb(120, 60, 200),
			pants = rgb(40, 25, 70),
			face = "😌",
			jaw = true,
			acc = { "Cap" },
			accColor = PURPLE,
			buff = 0.75,
			scale = 1.1,
			aura = PURPLE,
		},
	},
	{
		Name = "Rizzlord",
		Look = {
			skin = SKIN_TAN,
			shirt = rgb(200, 0, 90),
			pants = rgb(30, 10, 25),
			face = "😏",
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
			shirt = rgb(10, 10, 12),
			pants = rgb(10, 10, 12),
			face = "🗿",
			jaw = true,
			acc = { "Cape", "Shades" },
			accColor = rgb(20, 20, 25),
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
			pants = rgb(200, 150, 30),
			material = "Metal",
			face = "😎",
			jaw = true,
			acc = { "Shades", "Chain" },
			buff = 0.9,
			scale = 1.15,
			aura = GOLD,
		},
	},
	{
		Name = "Diamond Chad",
		Look = {
			skin = rgb(170, 230, 255),
			shirt = rgb(120, 200, 255),
			pants = rgb(90, 160, 230),
			material = "Glass",
			face = "😎",
			faceColor = rgb(20, 40, 80),
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
			shirt = rgb(255, 230, 0),
			pants = rgb(30, 30, 40),
			face = "😠",
			jaw = true,
			acc = { "Headband", "Cape" },
			accColor = rgb(255, 240, 80),
			buff = 1,
			scale = 1.2,
			aura = rgb(255, 240, 80),
			glow = rgb(255, 255, 120),
		},
	},
	{
		Name = "Cosmic Mogger",
		Look = {
			skin = rgb(90, 40, 170),
			shirt = rgb(40, 10, 90),
			pants = rgb(20, 5, 50),
			material = "ForceField",
			face = "🗿",
			faceColor = rgb(255, 255, 255),
			jaw = true,
			acc = { "Halo" },
			accColor = rgb(200, 130, 255),
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
			pants = rgb(200, 195, 185),
			material = "Marble",
			face = "😤",
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
			shirt = rgb(255, 0, 120),
			pants = rgb(80, 0, 40),
			face = "😏",
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
			skin = rgb(20, 20, 24),
			shirt = rgb(10, 10, 12),
			pants = rgb(10, 10, 12),
			material = "Slate",
			face = "🗿",
			faceColor = rgb(255, 60, 60),
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
			skin = rgb(240, 240, 255),
			shirt = rgb(220, 235, 255),
			pants = rgb(190, 210, 255),
			material = "Glass",
			face = "😇",
			faceColor = rgb(40, 60, 120),
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
			pants = rgb(180, 130, 20),
			material = "Metal",
			face = "🗿",
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
			skin = rgb(30, 0, 0),
			shirt = rgb(150, 0, 20),
			pants = rgb(20, 0, 0),
			material = "ForceField",
			face = "😈",
			faceColor = rgb(255, 255, 255),
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
			pants = rgb(255, 200, 60),
			material = "Neon",
			face = "🗿",
			faceColor = rgb(60, 40, 0),
			jaw = true,
			acc = { "Crown", "Halo", "Wings", "Chain" },
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
