--[[
	Theme: BOT FACTORY TYCOON

	Second variant of the same game. Only presentation lives here; gameplay
	numbers are in ReplicatedStorage.Shared.Economy. See the chad theme for the
	field reference and monetization notes.
]]

local rgb = Color3.fromRGB

local CYAN = rgb(0, 220, 255)
local ORANGE = rgb(255, 140, 20)
local STEEL = rgb(150, 155, 165)
local GUNMETAL = rgb(70, 74, 84)

local Theme = {}

Theme.Id = "bot"
Theme.GameName = "Bot Factory Tycoon"
Theme.Tagline = "Build bots. Fuse them. Power the mega factory."

Theme.Words = {
	Unit = "Bot",
	Units = "Bots",
	Orb = "Energy",
	Gem = "Chips",
	Chest = "Crate",
	Deposit = "ENERGY REFINERY",
	Process = "Refining energy",
	Collect = "COLLECT CASH",
	Merge = "FUSION PAD",
	Unlocker = "CRATE DECODER",
	PremiumUnlocker = "TURBO DECODER",
	Free = "SUPPLY DROP",
	Surge = "POWER SURGE",
	Multiplier = "Refinery Multiplier",
	BuyTier = "UPGRADE ASSEMBLY",
}

Theme.Icons = {
	Unit = "🤖",
	Orb = "⚡",
	Gem = "💾",
	Money = "$",
	Home = "🏭",
	Ranking = "🏆",
	Index = "📘",
	Shop = "🛒",
	Invite = "📡",
	Settings = "⚙️",
	Surge = "🔋",
	Premium = "⭐",
	Friends = "👥",
	Chest = "📦",
}

Theme.Fonts = {
	Title = Enum.Font.Bangers,
	Body = Enum.Font.GothamBold,
	Mono = Enum.Font.Michroma,
}

Theme.Colors = {
	Primary = CYAN,
	Secondary = ORANGE,
	Accent = rgb(120, 255, 170),
	Good = rgb(60, 220, 120),
	Bad = rgb(240, 70, 60),
	Text = rgb(255, 255, 255),
	TextDim = rgb(170, 190, 205),
	Panel = rgb(20, 28, 36),
	PanelLight = rgb(38, 52, 64),
	PanelDark = rgb(10, 15, 20),
	Stroke = rgb(4, 8, 12),
	Orb = CYAN,
	OrbBig = ORANGE,

	Floor = rgb(48, 52, 58),
	FloorAlt = rgb(58, 62, 70),
	Wall = rgb(66, 72, 82),
	WallTrim = rgb(36, 40, 46),
	Neon = CYAN,
	NeonAlt = ORANGE,
	Pad = rgb(0, 210, 255),
	PadDisabled = rgb(110, 118, 126),
	Hub = rgb(34, 38, 44),
	Sky = rgb(12, 20, 32),

	Window = {
		Shop = rgb(0, 190, 240),
		Index = rgb(255, 130, 20),
		Ranking = rgb(240, 200, 40),
		Settings = rgb(100, 115, 130),
	},

	Rarity = {
		Common = rgb(165, 175, 185),
		Uncommon = rgb(80, 220, 120),
		Rare = rgb(60, 170, 255),
		Epic = rgb(170, 90, 255),
		Legendary = rgb(255, 170, 30),
		Mythic = rgb(255, 60, 90),
	},
}

Theme.Lighting = {
	ClockTime = 0.5,
	Ambient = rgb(80, 95, 110),
	OutdoorAmbient = rgb(90, 110, 130),
	Brightness = 2,
	FogColor = rgb(15, 30, 45),
	FogEnd = 900,
	AtmosphereColor = rgb(90, 160, 210),
	AtmosphereDecay = rgb(30, 60, 90),
	BloomIntensity = 0.7,
	ColorTint = rgb(240, 250, 255),
}

Theme.MusicId = ""

local MONO = Enum.Font.Code
local function bot(fields: { [string]: any }): { [string]: any }
	fields.faceFont = fields.faceFont or MONO
	fields.faceColor = fields.faceColor or CYAN
	return fields
end

-- 25 tiers, weakest to strongest. Each pair of tier N fuses into tier N+1.
Theme.Tiers = {
	{
		Name = "Scrap Bot",
		Look = bot({
			skin = rgb(130, 110, 90),
			shirt = rgb(120, 95, 70),
			pants = rgb(90, 75, 60),
			material = "CorrodedMetal",
			face = "o_o",
			faceColor = rgb(255, 200, 120),
		}),
	},
	{
		Name = "Bolt Buddy",
		Look = bot({
			skin = STEEL,
			shirt = rgb(120, 125, 135),
			pants = GUNMETAL,
			material = "Metal",
			face = "^_^",
			acc = { "Antenna" },
			accColor = rgb(255, 80, 80),
		}),
	},
	{
		Name = "Gear Grunt",
		Look = bot({
			skin = rgb(200, 170, 60),
			shirt = rgb(180, 150, 40),
			pants = GUNMETAL,
			material = "Metal",
			face = "-_-",
			acc = { "Backpack" },
			accColor = GUNMETAL,
			buff = 0.2,
		}),
	},
	{
		Name = "Spark Unit",
		Look = bot({
			skin = STEEL,
			shirt = rgb(255, 210, 40),
			pants = GUNMETAL,
			material = "Metal",
			face = "*_*",
			acc = { "Antenna" },
			accColor = rgb(255, 230, 60),
			glow = rgb(255, 230, 80),
		}),
	},
	{
		Name = "Drill Drone",
		Look = bot({
			skin = rgb(230, 120, 30),
			shirt = rgb(210, 100, 20),
			pants = rgb(60, 60, 66),
			material = "DiamondPlate",
			face = ">_<",
			acc = { "Visor" },
			accColor = ORANGE,
			buff = 0.3,
		}),
	},
	{
		Name = "Servo Soldier",
		Look = bot({
			skin = rgb(90, 110, 70),
			shirt = rgb(70, 90, 55),
			pants = rgb(50, 60, 40),
			material = "Metal",
			face = "■_■",
			acc = { "Visor", "Backpack" },
			accColor = rgb(120, 255, 120),
			buff = 0.4,
		}),
	},
	{
		Name = "Pulse Guard",
		Look = bot({
			skin = rgb(40, 90, 160),
			shirt = rgb(30, 70, 140),
			pants = rgb(20, 40, 80),
			material = "Metal",
			face = "◉_◉",
			acc = { "Shoulders" },
			accColor = CYAN,
			buff = 0.45,
			glow = CYAN,
		}),
	},
	{
		Name = "Copper Knight",
		Look = bot({
			skin = rgb(200, 110, 60),
			shirt = rgb(185, 100, 55),
			pants = rgb(140, 75, 40),
			material = "Metal",
			face = "=_=",
			acc = { "Shoulders", "Cape" },
			accColor = rgb(150, 30, 30),
			buff = 0.5,
			scale = 1.05,
		}),
	},
	{
		Name = "Turbo Tank",
		Look = bot({
			skin = GUNMETAL,
			shirt = rgb(85, 90, 100),
			pants = rgb(50, 54, 60),
			material = "DiamondPlate",
			face = "ò_ó",
			acc = { "Shoulders", "Backpack" },
			accColor = ORANGE,
			buff = 1,
			scale = 1.1,
		}),
	},
	{
		Name = "Laser Ranger",
		Look = bot({
			skin = rgb(230, 235, 240),
			shirt = rgb(200, 30, 40),
			pants = rgb(40, 40, 46),
			material = "Metal",
			face = "⊙_⊙",
			faceColor = rgb(255, 60, 60),
			acc = { "Visor", "Antenna" },
			accColor = rgb(255, 40, 40),
			buff = 0.5,
			scale = 1.1,
			glow = rgb(255, 50, 50),
		}),
	},
	{
		Name = "Neon Ninja",
		Look = bot({
			skin = rgb(25, 25, 30),
			shirt = rgb(20, 20, 24),
			pants = rgb(15, 15, 18),
			material = "Metal",
			face = "≡_≡",
			faceColor = rgb(120, 255, 170),
			acc = { "Headband" },
			accColor = rgb(120, 255, 170),
			buff = 0.4,
			scale = 1.1,
			aura = rgb(120, 255, 170),
		}),
	},
	{
		Name = "Plasma Brute",
		Look = bot({
			skin = rgb(150, 60, 220),
			shirt = rgb(120, 40, 190),
			pants = rgb(60, 20, 100),
			material = "Metal",
			face = "Ò_Ó",
			faceColor = rgb(255, 120, 255),
			acc = { "Shoulders" },
			accColor = rgb(220, 120, 255),
			buff = 1,
			scale = 1.15,
			aura = rgb(200, 100, 255),
		}),
	},
	{
		Name = "Chrome Captain",
		Look = bot({
			skin = rgb(220, 225, 235),
			shirt = rgb(200, 205, 215),
			pants = rgb(160, 165, 175),
			material = "Foil",
			face = "•_•",
			acc = { "Cape", "Shoulders" },
			accColor = rgb(40, 90, 200),
			buff = 0.6,
			scale = 1.15,
			sparkles = true,
		}),
	},
	{
		Name = "Quantum Scout",
		Look = bot({
			skin = rgb(40, 200, 220),
			shirt = rgb(20, 150, 180),
			pants = rgb(10, 80, 100),
			material = "Glass",
			face = "◇_◇",
			faceColor = rgb(255, 255, 255),
			acc = { "Antenna", "Visor" },
			accColor = rgb(255, 255, 255),
			buff = 0.5,
			scale = 1.15,
			aura = CYAN,
		}),
	},
	{
		Name = "Fusion Titan",
		Look = bot({
			skin = rgb(255, 120, 0),
			shirt = rgb(60, 60, 66),
			pants = rgb(40, 40, 46),
			material = "Metal",
			face = "O_O",
			faceColor = ORANGE,
			acc = { "Shoulders", "Backpack" },
			accColor = ORANGE,
			buff = 1,
			scale = 1.2,
			fire = ORANGE,
		}),
	},
	{
		Name = "Nova Sentinel",
		Look = bot({
			skin = rgb(250, 250, 255),
			shirt = rgb(255, 220, 90),
			pants = rgb(230, 230, 240),
			material = "Metal",
			face = "✦_✦",
			faceColor = rgb(255, 200, 40),
			acc = { "Halo", "Shoulders" },
			accColor = rgb(255, 220, 90),
			buff = 0.8,
			scale = 1.2,
			aura = rgb(255, 230, 120),
		}),
	},
	{
		Name = "Gravity Golem",
		Look = bot({
			skin = rgb(60, 50, 80),
			shirt = rgb(45, 35, 65),
			pants = rgb(30, 25, 45),
			material = "Slate",
			face = "◎_◎",
			faceColor = rgb(170, 120, 255),
			acc = { "Shoulders", "Horns" },
			accColor = rgb(170, 120, 255),
			buff = 1,
			scale = 1.3,
			aura = rgb(130, 80, 255),
		}),
	},
	{
		Name = "Photon Paladin",
		Look = bot({
			skin = rgb(255, 255, 240),
			shirt = rgb(255, 245, 200),
			pants = rgb(220, 210, 170),
			material = "Marble",
			face = "☼_☼",
			faceColor = rgb(255, 190, 40),
			acc = { "Halo", "Cape", "Shoulders" },
			accColor = rgb(255, 210, 60),
			buff = 0.9,
			scale = 1.3,
			sparkles = true,
			aura = rgb(255, 240, 160),
		}),
	},
	{
		Name = "Hyper Warden",
		Look = bot({
			skin = rgb(0, 160, 255),
			shirt = rgb(0, 120, 220),
			pants = rgb(0, 60, 130),
			material = "ForceField",
			face = "▣_▣",
			faceColor = rgb(255, 255, 255),
			acc = { "Wings", "Visor" },
			accColor = CYAN,
			buff = 0.9,
			scale = 1.35,
			aura = CYAN,
		}),
	},
	{
		Name = "Singularity Mk I",
		Look = bot({
			skin = rgb(10, 10, 14),
			shirt = rgb(5, 5, 8),
			pants = rgb(5, 5, 8),
			material = "Glass",
			face = "●_●",
			faceColor = rgb(255, 255, 255),
			acc = { "Halo", "Shoulders" },
			accColor = rgb(255, 255, 255),
			buff = 1,
			scale = 1.35,
			aura = rgb(255, 255, 255),
			sparkles = true,
		}),
	},
	{
		Name = "Void Walker",
		Look = bot({
			skin = rgb(40, 0, 60),
			shirt = rgb(30, 0, 50),
			pants = rgb(15, 0, 25),
			material = "ForceField",
			face = "◈_◈",
			faceColor = rgb(255, 60, 255),
			acc = { "Horns", "Cape" },
			accColor = rgb(255, 60, 255),
			buff = 1,
			scale = 1.4,
			aura = rgb(220, 40, 255),
		}),
	},
	{
		Name = "Star Forge",
		Look = bot({
			skin = rgb(255, 170, 40),
			shirt = rgb(255, 120, 20),
			pants = rgb(120, 50, 10),
			material = "Neon",
			face = "★_★",
			faceColor = rgb(80, 30, 0),
			acc = { "Halo", "Backpack", "Shoulders" },
			accColor = rgb(255, 230, 120),
			buff = 1,
			scale = 1.45,
			fire = ORANGE,
			aura = ORANGE,
		}),
	},
	{
		Name = "Nebula Prime",
		Look = bot({
			skin = rgb(120, 70, 255),
			shirt = rgb(255, 80, 200),
			pants = rgb(60, 30, 140),
			material = "Glass",
			face = "✧_✧",
			faceColor = rgb(255, 255, 255),
			acc = { "Wings", "Halo" },
			accColor = rgb(255, 150, 255),
			buff = 1,
			scale = 1.5,
			aura = rgb(255, 120, 230),
			sparkles = true,
		}),
	},
	{
		Name = "Omega Core",
		Look = bot({
			skin = rgb(255, 40, 40),
			shirt = rgb(30, 30, 34),
			pants = rgb(20, 20, 24),
			material = "DiamondPlate",
			face = "Ω_Ω",
			faceColor = rgb(255, 60, 60),
			acc = { "Wings", "Horns", "Shoulders" },
			accColor = rgb(255, 40, 40),
			buff = 1,
			scale = 1.55,
			aura = rgb(255, 40, 40),
			fire = rgb(255, 60, 30),
		}),
	},
	{
		Name = "Infinity Engine",
		Look = bot({
			skin = rgb(200, 255, 255),
			shirt = CYAN,
			pants = rgb(0, 120, 160),
			material = "Neon",
			face = "∞_∞",
			faceColor = rgb(0, 40, 60),
			acc = { "Halo", "Wings", "Antenna", "Shoulders" },
			accColor = rgb(255, 255, 255),
			buff = 1,
			scale = 1.6,
			aura = CYAN,
			sparkles = true,
			fire = CYAN,
		}),
	},
}

Theme.Monetization = {
	Passes = {
		AutoLoot = { Id = 0, Price = 99, Title = "Auto Energy", Desc = "Energy flows straight into your tank", Color = rgb(255, 160, 30) },
		AutoCash = {
			Id = 0,
			Price = 49,
			Title = "Auto Cash",
			Desc = "Refined cash goes straight to your wallet",
			Color = rgb(60, 200, 110),
		},
		DoubleAura = { Id = 0, Price = 299, Title = "Double Energy", Desc = "Every bot outputs 2x energy", Color = rgb(0, 190, 240) },
		DoubleMoney = { Id = 0, Price = 199, Title = "2X Cash", Desc = "Permanent 2x cash from the refinery", Color = rgb(70, 120, 255) },
		PremiumUnlocker = {
			Id = 0,
			Price = 149,
			Title = "Turbo Decoder",
			Desc = "Second crate decoder, 3x faster",
			Color = rgb(255, 90, 90),
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
