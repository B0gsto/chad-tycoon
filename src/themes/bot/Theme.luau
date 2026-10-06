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

-- Onboarding tutorial and loading screen (see the chad theme for the format).
Theme.Tutorial = {
	Title = "FACTORY ORIENTATION",
	Steps = {
		{
			Title = "Build your first Bot",
			Text = "Step on the glowing BUY 1 pad.",
			Icon = "🛒",
		},
		{
			Title = "Harvest energy",
			Text = "Your Bots drop energy cells. Walk over them to fill your tank.",
			Icon = "⚡",
		},
		{
			Title = "Refine the energy",
			Text = "Step on the ENERGY REFINERY pad to send your tank in.",
			Icon = "🏭",
		},
		{
			Title = "Cash out",
			Text = "Step on COLLECT CASH to bank what the refinery made.",
			Icon = "💵",
		},
		{
			Title = "Fuse two Bots",
			Text = "Two Bots of the same tier fuse into a stronger one. Step on the FUSION PAD.",
			Hint = "You need two of the same tier: build one more on BUY 1 first.",
			Icon = "🔀",
		},
	},
	DoneTitle = "ORIENTATION COMPLETE!",
	DoneText = "The factory is yours. Time to build the mega factory.",
	Skip = "Skip",
	SkipConfirm = "Skip the orientation? You'll miss the completion reward.",
	Follow = "Follow the arrow",
}

Theme.Loading = {
	Status = "Booting the factory...",
	Tips = {
		"Tip: two Bots of the same tier fuse into the next tier.",
		"Tip: refine when the Refinery Multiplier is high for more cash.",
		"Tip: during a Power Surge every Bot makes double energy.",
		"Tip: carry crates to the Crate Decoder to open them for free.",
	},
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
	Free = "🎁",
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

	-- Plot decor (Theme.Decor = "factory").
	Hazard = rgb(255, 196, 0),
	Belt = rgb(26, 28, 32),
	Pipe = rgb(120, 128, 140),

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

-- Unit animation set (see ReplicatedStorage.Shared.Poses): servo/hover moves.
Theme.AnimSet = "Bot"

local WHITE = rgb(240, 244, 250)
local DARK = rgb(40, 42, 50)

-- Plot decoration style built by WorldBuilder: "gym" or "factory" (nil = none).
Theme.Decor = "factory"

local function bot(fields: { [string]: any }): { [string]: any }
	fields.faceColor = fields.faceColor or CYAN
	fields.trim = fields.trim or DARK
	return fields
end

-- 25 tiers, weakest to strongest. Each pair of tier N fuses into tier N+1.
-- Looks are built by Shared.CharacterFactory (see its header for every field).
Theme.Tiers = {
	{
		Name = "Scrap Bot",
		Look = bot({
			skin = rgb(140, 116, 92),
			shirt = rgb(122, 96, 70),
			pants = rgb(96, 78, 62),
			trim = rgb(70, 58, 48),
			material = "CorrodedMetal",
			eyes = "Dots",
			faceColor = rgb(255, 190, 110),
		}),
	},
	{
		Name = "Bolt Buddy",
		Look = bot({
			skin = STEEL,
			shirt = rgb(120, 126, 138),
			pants = GUNMETAL,
			material = "Metal",
			eyes = "Happy",
			acc = { "Antenna" },
			accColor = rgb(255, 80, 80),
		}),
	},
	{
		Name = "Gear Grunt",
		Look = bot({
			skin = rgb(210, 175, 60),
			shirt = rgb(186, 152, 40),
			pants = GUNMETAL,
			material = "Metal",
			eyes = "Bars",
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
			eyes = "Dots",
			mouth = "Bar",
			faceColor = rgb(255, 230, 80),
			acc = { "Antenna" },
			accColor = rgb(255, 230, 60),
			glow = rgb(255, 230, 80),
			buff = 0.1,
		}),
	},
	{
		Name = "Drill Drone",
		Look = bot({
			skin = rgb(232, 122, 32),
			shirt = rgb(212, 102, 22),
			pants = rgb(62, 62, 70),
			material = "DiamondPlate",
			faceColor = ORANGE,
			acc = { "Visor" },
			accColor = ORANGE,
			buff = 0.3,
		}),
	},
	{
		Name = "Servo Soldier",
		Look = bot({
			skin = rgb(96, 116, 74),
			shirt = rgb(74, 94, 58),
			pants = rgb(52, 62, 42),
			material = "Metal",
			faceColor = rgb(120, 255, 120),
			acc = { "Visor", "Backpack" },
			accColor = rgb(120, 255, 120),
			buff = 0.4,
		}),
	},
	{
		Name = "Pulse Guard",
		Look = bot({
			skin = rgb(44, 96, 170),
			shirt = rgb(32, 72, 146),
			pants = rgb(22, 42, 84),
			material = "Metal",
			eyes = "Visor",
			mouth = "Bar",
			acc = { "Shoulders" },
			accColor = CYAN,
			buff = 0.45,
			glow = CYAN,
		}),
	},
	{
		Name = "Copper Knight",
		Look = bot({
			skin = rgb(205, 115, 62),
			shirt = rgb(186, 100, 55),
			pants = rgb(140, 75, 40),
			trim = rgb(70, 40, 26),
			material = "Metal",
			eyes = "Bars",
			faceColor = rgb(255, 200, 120),
			acc = { "Shoulders", "Cape" },
			accColor = rgb(160, 30, 30),
			buff = 0.5,
			scale = 1.05,
		}),
	},
	{
		Name = "Turbo Tank",
		Look = bot({
			skin = GUNMETAL,
			shirt = rgb(86, 92, 102),
			pants = rgb(52, 56, 62),
			material = "DiamondPlate",
			eyes = "Angry",
			faceColor = ORANGE,
			acc = { "Shoulders", "Jetpack" },
			accColor = ORANGE,
			buff = 1,
			scale = 1.1,
		}),
	},
	{
		Name = "Laser Ranger",
		Look = bot({
			skin = rgb(232, 236, 242),
			shirt = rgb(205, 30, 42),
			pants = rgb(42, 42, 48),
			material = "Metal",
			faceColor = rgb(255, 60, 60),
			acc = { "Visor", "Antenna", "Cannon" },
			accColor = rgb(255, 40, 40),
			buff = 0.5,
			scale = 1.1,
			glow = rgb(255, 50, 50),
		}),
	},
	{
		Name = "Neon Ninja",
		Look = bot({
			skin = rgb(28, 28, 34),
			shirt = rgb(22, 22, 26),
			pants = rgb(16, 16, 20),
			trim = rgb(12, 12, 14),
			material = "Metal",
			eyes = "Bars",
			mouth = "None",
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
			skin = rgb(152, 62, 222),
			shirt = rgb(122, 42, 192),
			pants = rgb(62, 22, 102),
			material = "Metal",
			eyes = "Angry",
			faceColor = rgb(255, 120, 255),
			acc = { "Shoulders", "Cannon" },
			accColor = rgb(220, 120, 255),
			buff = 1,
			scale = 1.15,
			aura = rgb(200, 100, 255),
		}),
	},
	{
		Name = "Chrome Captain",
		Look = bot({
			skin = rgb(222, 226, 236),
			shirt = rgb(202, 206, 216),
			pants = rgb(162, 166, 176),
			material = "Foil",
			eyes = "Dots",
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
			skin = rgb(42, 202, 222),
			shirt = rgb(22, 152, 182),
			pants = rgb(12, 82, 102),
			material = "Glass",
			eyes = "Mono",
			faceColor = WHITE,
			acc = { "Antenna", "Jetpack" },
			accColor = WHITE,
			buff = 0.5,
			scale = 1.15,
			aura = CYAN,
		}),
	},
	{
		Name = "Fusion Titan",
		Look = bot({
			skin = rgb(255, 122, 0),
			shirt = rgb(62, 62, 68),
			pants = rgb(42, 42, 48),
			material = "Metal",
			eyes = "Visor",
			faceColor = ORANGE,
			acc = { "Shoulders", "Jetpack" },
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
			trim = rgb(90, 80, 60),
			material = "Metal",
			eyes = "Dots",
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
			skin = rgb(64, 54, 86),
			shirt = rgb(48, 38, 70),
			pants = rgb(32, 26, 48),
			trim = rgb(22, 18, 32),
			material = "Slate",
			eyes = "Mono",
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
			skin = rgb(255, 255, 242),
			shirt = rgb(255, 245, 200),
			pants = rgb(220, 210, 170),
			trim = rgb(120, 100, 60),
			material = "Marble",
			eyes = "Visor",
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
			skin = rgb(0, 162, 255),
			shirt = rgb(0, 122, 222),
			pants = rgb(0, 62, 132),
			material = "ForceField",
			faceColor = WHITE,
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
			skin = rgb(14, 14, 18),
			shirt = rgb(8, 8, 12),
			pants = rgb(8, 8, 12),
			trim = rgb(30, 30, 36),
			material = "Glass",
			eyes = "Mono",
			faceColor = WHITE,
			acc = { "Halo", "Shoulders" },
			accColor = WHITE,
			buff = 1,
			scale = 1.35,
			aura = rgb(255, 255, 255),
			sparkles = true,
		}),
	},
	{
		Name = "Void Walker",
		Look = bot({
			skin = rgb(44, 0, 66),
			shirt = rgb(32, 0, 54),
			pants = rgb(18, 0, 30),
			trim = rgb(14, 0, 22),
			material = "ForceField",
			eyes = "Angry",
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
			skin = rgb(255, 172, 42),
			shirt = rgb(255, 122, 22),
			pants = rgb(122, 52, 12),
			trim = rgb(70, 30, 10),
			material = "Neon",
			eyes = "Visor",
			faceColor = rgb(255, 250, 220),
			acc = { "Halo", "Jetpack", "Shoulders" },
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
			skin = rgb(122, 72, 255),
			shirt = rgb(255, 82, 202),
			pants = rgb(62, 32, 142),
			trim = rgb(40, 20, 80),
			material = "Glass",
			eyes = "Happy",
			faceColor = rgb(255, 160, 255),
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
			skin = rgb(255, 42, 42),
			shirt = rgb(32, 32, 36),
			pants = rgb(22, 22, 26),
			trim = rgb(16, 16, 18),
			material = "DiamondPlate",
			eyes = "Angry",
			faceColor = rgb(255, 60, 60),
			acc = { "Wings", "Horns", "Cannon" },
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
			pants = rgb(0, 122, 162),
			trim = rgb(0, 60, 90),
			material = "Neon",
			eyes = "Mono",
			faceColor = WHITE,
			acc = { "Halo", "Wings", "Shoulders" },
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
