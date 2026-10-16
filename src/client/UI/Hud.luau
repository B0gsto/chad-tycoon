--[[
	Hud: always-on screen elements (design space 1280x720, below the top bar).
	Laid out like the owner's reference game: chunky icons and bold white
	Ink-outlined text straight over the world; only the menu buttons sit on plates.

	  top bar right  Settings gear alone (Roblox's player list sits under it)
	  top centre     two rows and no more, y 2 to 88 at 720p (the world's signs and Buy pad
	                 labels start lower: nothing of the HUD overlays them). Every piece
	                 sits on the same navy plate (`plate`: 90 % opaque, 2 px light edge)
	                 so it reads over a crowded rack.
	                 Row 1, side by side: the count plate (Chad icon + "37/100"; the number
	                 ticks, the plate pops and the icon wiggles on every change; at
	                 100/100 the plate turns orange-red with an "AUTO-MERGING" pill and a
	                 pulsing ring, and shakes on each buy that auto-merges) and the status
	                 plate ("Deposit bonus: x1.3 · 12s"; during a surge a crimson plate with
	                 the gold bolt, "AURA SURGE x2 · 1:23", a draining gold bar, a pulsing
	                 edge, a sheen and a gold vignette round the screen).
	                 Row 2, once the tutorial is done: the "Next:" goal plate ("Next:
	                 Protein Bro 63%" over "1,240 more Normies · about 2 h" and a
	                 progress bar, Shared.NextGoal; it turns green, breathes and says
	                 "READY: step on MOG MERGE" when one merge finds the tier, sparkles
	                 sweeping across it, inside a steady green glow). With every tier found it is the gold CHAMPION
	                 plate: a big bobbing crown, "CHAMPION" and the count of top-tier
	                 Chads, a slow sheen and sparkles, over "Index reward: tap to claim it" behind
	                 the Index icon and its red dot while a milestone is unclaimed, then
	                 the violet LEGEND plate (gold edge, gold title, a haloed crown) over
	                 "All 25 Chads found!" (above the dumbbell on compact screens). A
	                 "nearer goal" takes the plate's second line, one at a time, behind its
	                 icon ("Blender is full: upgrade its speed", "Crate ready at the
	                 Smasher", "Try a Game Mode: +$X", "New! Open MODES" right after the
	                 tutorial): a tap on the plate then does it, and
	                 Client.Guide points at its pad on the plot. No row is ever added
	                 under the plate. The tutorial quest pill and the parkour run pill
	                 have their own slot under the stack. On touch the wallet shares the
	                 top left, so the three plates stack in one column instead.
	  left edge      menu grid: Home Ranking Modes Index / Shop Invite Daily, each an
	                 icon and its caption on its own dark glass plate, all the same
	                 size, on one dark backing plate (Daily: a dot while a reward waits,
	                 else its countdown). Only one button calls at a time (MENU_RANK): its
	                 badge beats and it glows or breathes; Modes, new after the tutorial,
	                 wears a gold ring and a bobbing arrow
	                 promo under it, only after the tutorial, below tier 15 and until it
	                 is opened once: a small green-tinted glass card three buttons wide,
	                 STARTER PACK (then 2X CASH under a tilted "PERMANENT" tag) with a
	                 solid price chip and a slow sheen (quieter than the menu plates)
	  bottom left    bonus chips, each a small plate on screen only while it is on
	                 ("Premium +10%", "Friends +20%", a gold "SURGE x2"), "Cash [ x1.0 ]",
	                 the big cash amount + square "+" on the cash plate (it flashes green
	                 and floats "+$X" on income, wears a pulsing gold edge during a surge)
	                 and under it the income, "+$X/s" (not on touch)
	  bottom centre  the dumbbell: "AURA" + the carried amount on its plaque
	  bottom right   FREE gift with its countdown (ready: a "!" dot, the gift hopping and
	                 a sunny "CLAIM!": the gift is announced here and nowhere else),
	                 version in the corner

	Numbers roll, things pop, every badge dot beats and the HUD staggers in when it is built
	(sizes, colours and timings of all of it: TUNE, below). While a
	window, modal or reveal is open (Kit.onWindowOpen, the one count behind the
	"WindowOpen" attribute) every group fades out in 0.15 s, parks off its edge
	so it takes no input or gamepad selection, and fades back on close. Toasts
	and the tutorial pill are not the HUD's: they stay.
	Short screens (attribute "Compact") get smaller grid icons, drop the promo
	and hide Roblox's player list.
	A game-mode run (attribute "RunActive") owns the screen: the menu grid, the
	promo, the dumbbell and the wallet's rows above the cash amount step out; the
	cash amount stays.

	Input (Kit.onInput, re-placed live): on touch the wallet moves to the top
	left with the grid under it (one row on phones, the bonus chips beside the
	"Cash" line on tablets and gone on phones) so nothing sits on Roblox's
	thumbstick (bottom-left third, lower half) or jump button, the FREE gift
	rises above the jump button, the gear leaves the top bar and every button is
	at least 44 screen px (invisible hit pads on the small ones). On gamepad / TV
	the edges get a title-safe margin; every HUD button is Selectable (the Kit
	ring, hover scale on SelectionGained) unless a window or dialog is open.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local SocialService = game:GetService("SocialService")
local TextService = game:GetService("TextService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local BuyNext = require(ReplicatedStorage.Shared.BuyNext)
local Economy = require(ReplicatedStorage.Shared.Economy)
local Format = require(ReplicatedStorage.Shared.Format)
local Net = require(ReplicatedStorage.Shared.Net)
local NextGoal = require(ReplicatedStorage.Shared.NextGoal)

local Guide = require(script.Parent.Parent.Guide)
local Kit = require(script.Parent.Kit)
local State = require(script.Parent.Parent.State)

local Theme = Kit.Theme
local C = Kit.C
local G = Theme.Glass
local F = Kit.F
local W = Theme.Words

local Hud = {}

export type Handlers = {
	openWindow: (string, { focus: string?, origin: GuiObject? }?) -> (),
	guide: ((string?) -> ())?,
	toast: ((string, string?) -> ())?,
}

-- Buttons by name (Shop, Index, Ranking, Free, Home, Invite, Daily, Settings, Modes) so
-- other modules (tutorial, guide) can badge, glow or aim coin bursts at them.
Hud.buttons = {} :: { [string]: TextButton }

-- Filled in by build(); safe no-ops before that.
Hud.pulseTank = function(_big: boolean?) end
Hud.coinBurst = function(_amount: number, _padPos: Vector3?, _fromGui: GuiObject?) end
-- os.clock() of the last free-reward claim from the HUD (Main flies those coins from it).
Hud.freeClaimedAt = 0
-- Red shake on the cash amount ("can't afford").
Hud.shakeWallet = function() end
-- Game-mode run pill (timer + checkpoints + quit).
Hud.runStart = function(_startedAt: number, _checkpoint: number, _checkpoints: number, _level: number?) end
Hud.runCheckpoint = function(_index: number, _checkpoints: number) end
Hud.runStop = function() end
-- The sky obby docks the run pill into its own row (pos + anchor; nil puts it back).
Hud.dockRun = function(_pos: UDim2?, _anchor: Vector2?) end
-- A parkour run is on: the tycoon's top centre (units, deposit strip), the quest pill,
-- the promo and the FREE gift step aside for the obby HUD; off brings them back.
Hud.setObbyMode = function(_on: boolean) end
-- The dumbbell group (the obby gear hotbar sits on top of it).
Hud.tank = nil :: Frame?
-- True once the cash counter has finished rolling.
Hud.walletIdle = function(): boolean
	return true
end
-- Where a discovery flies to (Popups): the centre of the Index button at rest, in screen
-- pixels. nil while it is no landing spot (a window keeps the HUD away, the menu is hidden
-- or off screen).
Hud.indexPoint = function(): Vector2?
	return nil
end
-- A discovery landed on the Index button: it bounces, flashes and counts "+1".
Hud.punchIndex = function() end

-- Tunables of the top stack's plates, the wallet's and the HUD's motion: every size (design
-- px), colour, duration (seconds) and count in one place. The effects are judged on 1280x720
-- stills and 3-frame bursts, so "on change" is meant to be seen; idle motion stays slow.
local TUNE = {
	-- The plate of the count, the status strip, the goal strip, the cash block and the chips:
	-- navy, 90 % opaque, a 2 px light edge (fading a little toward the bottom).
	PlateColor = G.TintTop,
	PlateAlpha = 0.1,
	PlateEdge = Color3.fromRGB(206, 220, 255),
	PlateEdgeAlpha = 0.12,
	PlateEdgeFade = 0.45,
	PlateEdgeWidth = 2,
	PlateRadius = 12,
	-- The top stack: row 1 (count plate + status plate, side by side) is y 2..38 and the goal
	-- plate under it y 42..88 at 720p (from TopY + RowH + StackGap, GoalH and 2 for its 17 px
	-- second line; the CHAMPION plate's bigger title makes it y 42..90).
	TopY = 2,
	RowH = 36,
	RowGap = 6, -- between the two plates of row 1
	RowPad = 12, -- a plate's edge to its content
	StackGap = 4, -- between the rows
	GoalH = 44,
	GoalMaxW = 440,
	StripMinW = 230,
	-- Text of the stack: nothing under 17.
	CountText = 26,
	CountIcon = 30,
	StripLead = 18,
	StripValue = 22,
	StripNext = 17,
	GoalLead = 18,
	GoalTitle = 18,
	GoalCount = 17,
	-- The goal plate's second line is BuilderSans, which draws about 0.77 of its size (17
	-- read as 13 px): 20 reads as 15 px. Its line and the plate grow with it.
	GoalHint = 20,
	-- The count changes: the plate pops, the number flashes and the Chad icon wiggles.
	CountPop = 1.6, -- Kit.pop strength (1 = +12 %)
	CountFlash = 0.55,
	CountUp = C.Cash,
	CountDown = C.Gold,
	CountTilt = 16, -- degrees
	CountEdgeFlash = 5, -- the edge's width at the flash
	CountPlateFlash = Color3.fromRGB(84, 110, 224), -- the plate's fill at the flash
	-- A full rack: an orange-red plate, the "AUTO-MERGING" pill and a shake on every buy.
	FullPlate = Color3.fromRGB(236, 84, 38),
	FullEdge = Color3.fromRGB(255, 214, 160),
	FullFlash = Color3.fromRGB(255, 176, 64),
	FullText = 19, -- LuckiestGuy draws about 0.8 of its size: 19 reads as 15 px
	FullPillH = 28,
	-- ...and the plate pulses: a glowing ring just outside it swells and fades, for good.
	FullRingColor = Color3.fromRGB(255, 196, 92),
	FullRingOut = 4, -- px outside the plate
	FullRingWidth = { 2, 6 }, -- the ring's stroke, at rest and at its swell
	FullRingAlpha = { 0.75, 0 }, -- its transparency, at rest and at its swell
	FullRingBeat = 0.55,
	FullShake = { 8, -7, 6, -4, 2, 0 }, -- px, one per step
	FullShakeStep = 0.04,
	FullBeatPop = 0.9, -- the pill's idle beat
	-- Aura Surge: the status plate turns hot crimson (not gold: the CHAMPION plate under it is
	-- gold, and not the full rack's orange beside it) with the gold bolt, a big gold "x2" and a
	-- gold bar along its bottom that drains with the time left; the cash plate's edge pulses
	-- gold; the SURGE chip is gold; a gold vignette glows round the screen's edge.
	SurgePlate = Color3.fromRGB(214, 32, 92),
	SurgeEdge = Color3.fromRGB(255, 214, 96),
	SurgeText = Color3.fromRGB(255, 224, 90), -- "x2"
	SurgeBarH = 5,
	SurgeBarInset = 10,
	SurgeBarColor = Color3.fromRGB(255, 218, 72),
	SurgeVignette = Color3.fromRGB(255, 196, 40),
	-- The vignette is a band along the edges only (the middle of the screen keeps its colours):
	-- its depth is a share of the screen's height (top, bottom bands) and width (sides), solid
	-- for the first SurgeVignetteCore of it, then fading out inward.
	SurgeVignetteDepth = { 0.075, 0.05 },
	SurgeVignetteCore = 0.25,
	SurgeVignetteAlpha = { 0.2, 0.5 }, -- the edge's transparency, at its swell and at rest
	SurgeVignetteBeat = 1.1,
	-- ...and gold motes rise along the side edges while it runs: one every SurgeMoteEvery
	-- seconds, SurgeMoteSize screen px, from the lower half up SurgeMoteRise of the height
	-- within SurgeMoteBand of the width from an edge, over SurgeMoteLife seconds.
	SurgeMoteEvery = 0.09,
	SurgeMoteSize = { 12, 22 },
	SurgeMoteRise = { 0.22, 0.4 },
	SurgeMoteBand = 0.045,
	SurgeMoteLife = { 1.6, 2.4 },
	SurgeMoteColors = { Color3.fromRGB(255, 214, 72), Color3.fromRGB(255, 244, 180), Color3.fromRGB(255, 176, 40) },
	SurgeIcon = 28, -- the bolt's dark medallion (the bolt itself is 6 smaller)
	SurgeValue = 26,
	SurgeSheenEvery = 0.9, -- pause between two sheens
	SurgeEdgeWidth = 5, -- the pulsing edges swell to this
	SurgeEdgeBeat = 0.45,
	SurgeChipText = 19,
	SurgeChipEdge = 3,
	SurgeChipBreathe = 0.08,
	-- A sheen: a slanted light band that crosses a plate.
	SheenTime = 1.1,
	SheenAlpha = 0.5, -- the band's transparency at its brightest
	SheenTilt = 20,
	-- The cash plate behind the amount and the "+": a green flash and a floating "+$X" on
	-- income, a red edge when something is too dear.
	CashPlateH = 60,
	-- The cash amount: big lime digits in a thick black outline, readable on any floor. Cash
	-- going down (a buy, an upgrade) flashes it red, easing back over MoneyDropTime.
	MoneyText = 50,
	MoneyColor = Color3.fromRGB(150, 255, 60),
	MoneyStroke = 4.5,
	MoneyStrokeColor = Color3.fromRGB(0, 0, 0),
	MoneyDrop = C.Bad,
	MoneyDropTime = 0.35,
	MoneyDropPop = 0.3,
	CashFlash = C.CashDeep,
	CashFlashTime = 0.45,
	GainText = 22,
	GainRise = 34,
	GainTime = 0.9,
	GainEvery = 0.9, -- at most one "+$X" in this long (gains in between add up)
	-- Wallet chips: one plate height and text size for all of them.
	ChipH = 32,
	ChipIcon = 22,
	ChipText = 17,
	ChipGap = 8,
	-- px from the chips' bottom up from the "Cash" line: clear of the SURGE chip's 3 px gold
	-- edge and its breathing (r5: at 4 it sat tight on CASH), about 6 px of air left.
	ChipLift = 11,
	ChipPad = 10,
	ChipRadius = 10,
	-- The beat: every badge dot on a HUD button pops ("!" harder than a count), one button
	-- after another; every PlusEvery-th beat the "+" pops too.
	BeatEvery = 1.2,
	BeatStagger = 0.1,
	BadgePop = 2.6,
	BadgePopCount = 1.5,
	PlusEvery = 4,
	PlusPop = 1.4,
	-- The FREE gift while it waits: it hops (up, tilted, then down with a bounce) and its
	-- "CLAIM!" breathes.
	GiftHop = 16,
	GiftTilt = 12,
	GiftUp = 0.16,
	GiftDown = 0.5,
	GiftEvery = 1.2, -- rest between two hops
	GiftWordBreathe = 0.12,
	-- The promo card: three menu buttons wide, lower than a menu plate, a slow sheen.
	PromoW = 216,
	PromoH = 40,
	PromoChipW = 62,
	PromoChipH = 26,
	PromoText = 18,
	PromoPrice = 15,
	PromoSheenEvery = 2.8,
	-- CHAMPION (every tier found): the goal plate in gold with a big crown that bobs and rocks
	-- over its medallion (it overhangs it), a slow sheen and sparkles that follow the sheen.
	ChampPlate = Color3.fromRGB(244, 170, 28),
	ChampEdge = C.GoldLight,
	ChampTitle = 20,
	ChampCrown = 44, -- over the thumbnail's 36 px medallion
	ChampCrownTilt = 9,
	ChampCrownBeat = 0.8,
	ChampCrownBob = 5, -- px up and down
	ChampCrownBobBeat = 1.1,
	ChampSheenEvery = 1.8,
	ChampSparkColor = Color3.fromRGB(255, 255, 230),
	-- LEGEND (every tier found and every Index milestone claimed): the plate's last state,
	-- crown-lit royal violet with a thick gold edge, a gold title, a gold halo beating round
	-- the crown's medallion and a slower sheen.
	LegendWords = "LEGEND",
	LegendPlate = Color3.fromRGB(112, 38, 196),
	LegendEdge = Color3.fromRGB(255, 214, 72),
	LegendEdgeWidth = 4,
	LegendTitle = Color3.fromRGB(255, 222, 80),
	LegendSheenEvery = 2.6,
	LegendHalo = 4, -- px outside the medallion
	LegendHaloWidth = { 3, 6 },
	-- READY (one merge finds the tier): the green goal plate breathes under a quick sheen and a
	-- sweep of sparkles that crosses it with the sheen.
	ReadyBreathe = 0.05,
	-- ...inside a steady glow (on for as long as it is ready): rings round the plate, `out` px
	-- outside it, their stroke from width[1] (beating to width[2]) at `alpha`.
	ReadyGlow = {
		{ out = 3, width = { 4, 7 }, alpha = 0, color = Color3.fromRGB(236, 255, 120) },
		{ out = 9, width = { 8, 8 }, alpha = 0.55, color = Color3.fromRGB(120, 255, 110) },
		{ out = 13, width = { 6, 6 }, alpha = 0.78, color = Color3.fromRGB(120, 255, 110) },
	},
	ReadyGlowBeat = 0.5,
	ReadySheenEvery = 1.4,
	ReadySparkColor = Color3.fromRGB(255, 255, 210),
	-- A sparkle sweep: Sparks stars ride across the plate with the sheen's band, each SparkSize
	-- px (from SparkSize[1] to [2]), popping up and fading as they go.
	Sparks = 9,
	SparkSize = { 14, 24 },
	SparkSpin = 140, -- degrees over the sweep
	SparkJitter = 0.18, -- of the sweep's time: each star starts up to this much late
	IndexDot = 9, -- the red dot on the Index icon of an unclaimed milestone
	-- The left menu: 4 + 3 plates on one dark backing plate, so a world label never shows
	-- between two rows.
	MenuBackColor = G.TintTop,
	MenuBackAlpha = 0.28,
	MenuBackPad = 6,
	MenuBackRadius = 14,
	-- Only one menu button calls at a time (MENU_RANK): its badge beats and it wears its ring
	-- (Index, Modes) or breathes (Daily); the others keep a still badge.
	-- Modes is new (the tutorial was finished this session): after ModesNewDelay its gold ring
	-- pulses, a gold arrow bobs over it and the goal plate's second line says so, until Modes
	-- is opened or for ModesNewSeconds.
	ModesNewDelay = 3,
	ModesNewSeconds = 240,
	ModesArrow = 26, -- the arrow's head, px
	ModesArrowStem = { 10, 12 }, -- its stem, w x h
	ModesArrowGap = 4, -- its tip over the plate
	ModesArrowBob = 9, -- px
	ModesArrowBeat = 0.42,
	ModesArrowColor = C.Gold,
	ModesNewPop = 0.7, -- the Modes plate's beat (Kit.pop strength)
	-- ...and the moment it first lights: a gold burst on the plate (a ring blowing out to
	-- ModesUnlockRing px, ModesUnlockRays rays flying ModesUnlockRayReach px, gold confetti)
	-- and a gold "MODES UNLOCKED!" pill to the right of the menu for ModesUnlockHold seconds.
	ModesUnlockColor = C.Gold,
	ModesUnlockTime = 0.8,
	ModesUnlockRing = 190,
	ModesUnlockRingWidth = 9,
	ModesUnlockRays = 12,
	ModesUnlockRayLength = { 14, 40 },
	ModesUnlockRayWidth = 7,
	ModesUnlockRayReach = 96,
	ModesUnlockConfetti = 26,
	ModesUnlockPop = 2.2,
	ModesUnlockWords = "MODES UNLOCKED!",
	ModesUnlockText = 26,
	ModesUnlockPillH = 44,
	ModesUnlockGap = 22, -- the menu's right edge to the pill's pointer
	ModesUnlockHold = 4.5,
	ModesUnlockAfter = 0.4, -- s after the YOU DID IT banner has gone
	ModesUnlockWaitMax = 20, -- s it waits for that banner at most
	ModesUnlockBeat = 0.45,
	-- The FREE gift's "CLAIM!" when ready: a gold tab (ink edge that beats wider) behind the word.
	ClaimTab = C.Gold,
	ClaimTabEdge = G.TextInk,
	ClaimTabEdgeWidth = { 2, 4 },
	ClaimTabW = 80,
	ClaimTabPad = 6, -- px taller than the word's line
	ClaimTabBeat = 0.35,
	-- The wallet: "+$X/s" on its own navy chip under the cash plate (the snapshot's income
	-- without a surge), behind a green up-arrow; it pops and flashes green on each payout.
	-- F.Number draws about 0.7 of its size: 23 reads as 16 px.
	IncomeText = 23,
	IncomeColor = C.MoneyText,
	IncomeGap = 2, -- under the cash plate
	IncomeChipH = 26, -- its bottom overhangs the wallet's 168 by 4, into the 6 px margin
	IncomeArrow = 16,
	IncomeArrowColor = C.Cash,
	IncomePop = 1.3,
	IncomeFlash = C.CashDeep,
	IncomeFlashEdge = 4,
}

-- Layout (design px). The top centre stack sits just under the top bar (TUNE).
local EDGE_X = 14
local RUN_Y = 92 -- run pill slot, under the stack (the tutorial pill takes the goal slot instead)
local HIDE_TIME = 0.15 -- the HUD's fade while a window is open
local GOAL_TEXT_X = 50
local GOAL_BAR_X = 12 -- the progress bar's inset, clear of the strip's round corners
local GOAL_BAR_H = 4
local NEAR_GAP = 4 -- the "nearer goal" on the strip's second line: its icon to its words
local NEAR_TICK = 0.5 -- seconds between two looks at what the nearer goal should be
local NEAR_SNOOZE = 300 -- a nearer goal the player tapped stays away this long
local AFFORD_SECONDS = 45 -- "You can afford ...!" gives way after this long on the strip
local BLENDER_FULL_SECONDS = 60 -- aura waiting in the blender for longer than this: "full"
local BROKE_SECONDS = 60 -- nothing affordable for this long: a Game Mode pays sooner
local FAR_SECONDS = 300 -- so does it when the next tier is further off than a mode's pay (5 min of income)
local GRID_Y = 104 -- left menu grid, first row
local GRID_ICON = 56 -- the icon on a menu plate
local GRID_ICON_COMPACT = 44
local GRID_GAP = 6 -- between two plates
local GRID_PAD = 6 -- a plate's edge to its icon and caption
local CAPTION = 14 -- plate captions; never under Kit.captionPx on the glass
local PROMO_GAP = 4 -- the grid to the promo (whose tag overhangs its card by 12 more)
local PROMO_MAX_TIER = 15 -- from this best tier on the HUD stops advertising (the Shop keeps the offers)
local GEAR = 44
local DUMBBELL_W = 264
local DUMBBELL_W_COMPACT = 200
local DUMBBELL_ASPECT = 448 / 1024
local NARROW_PX = 900
local TAP_PX = 44 -- smallest touch target, in screen px
local TOP_BAR_PX = 58
local SAFE_X = 40 -- gamepad / TV title-safe edge (design px)
local SAFE_BOTTOM = 24
local PREMIUM_BONUS = 10

-- The menu grid's rows and captions; the promo's two offers (a tag only says what is true: the
-- Starter Pack has no deadline, so it wears none); the run pill's sizes (the "MAP 3" chip of a
-- run with levels, and where the clock starts beside the star otherwise).
local GRID_ROWS = { { "Home", "Ranking", "Modes", "Index" }, { "Shop", "Invite", "Daily" } }
-- Which menu button calls when several want to (the first one that does): Modes while it is
-- new (a few minutes right after the tutorial, the one moment it is pointed at), then a reward
-- to claim, then news, then a count.
local MENU_RANK = { "ModesNew", "Daily!", "Index!", "Index" }
local MENU_BUTTON: { [string]: string } = { ["Daily!"] = "Daily", ["Index!"] = "Index", ModesNew = "Modes", Index = "Index" }
local CAPTIONS: { [string]: string } = {
	Home = "Home",
	Ranking = "Ranking",
	Modes = "Modes",
	Index = "Index",
	Shop = "Shop",
	Invite = "Invite",
	Daily = "Daily",
}
local PROMOS: { [string]: { tag: string?, text: string, price: number, focus: string } } = {
	Starter = { text = "STARTER PACK", price = 59, focus = Theme.Cosmetics.Starter.Pass },
	DoubleMoney = { tag = "PERMANENT", text = "2X CASH", price = 199, focus = "DoubleMoney" },
}
local RUN_W, RUN_H = 236, 36
local RUN_MAP_W, RUN_CLOCK_X = 60, 42

-- The preview stage has no tweens that repeat: endless motion is skipped there (as in Kit).
local PREVIEW = typeof(TweenInfo.new(0)) ~= "TweenInfo"

-- The HUD's plate: Kit.hudGlass at TUNE's opacity with the 2 px light edge. Its fill is the
-- BackgroundColor3 (shaded toward the bottom), so `tint` and `flash` may recolour it.
local function plate(parent: Instance, props: { [string]: any }): GuiObject
	props.Color = props.Color or TUNE.PlateColor
	props.Transparency = TUNE.PlateAlpha
	props.Radius = props.Radius or TUNE.PlateRadius
	props.Shadow = false
	local frame = Kit.hudGlass(parent, props)
	local edge = frame:FindFirstChild("Edge")
	if edge and edge:IsA("UIStroke") then
		edge.Color = TUNE.PlateEdge
		edge.Thickness = TUNE.PlateEdgeWidth
		edge.Transparency = TUNE.PlateEdgeAlpha
		local fade = edge:FindFirstChildOfClass("UIGradient")
		if fade then
			fade.Transparency = NumberSequence.new(0, TUNE.PlateEdgeFade)
		end
	end
	return frame
end

local function edgeOf(frame: Instance): UIStroke?
	local edge = frame:FindFirstChild("Edge")
	return if edge and edge:IsA("UIStroke") then edge else nil
end

-- A plate eases to another fill and edge colour (nil: the plain plate's).
local function tint(frame: GuiObject, fill: Color3?, edge: Color3?)
	Kit.tween(frame, 0.3, { BackgroundColor3 = fill or TUNE.PlateColor })
	local stroke = edgeOf(frame)
	if stroke then
		Kit.tween(stroke, 0.3, { Color = edge or TUNE.PlateEdge })
	end
end

-- A plate jumps to `color` (its edge to `edge`, swollen to `width`) and eases back to `rest`
-- and `restEdge`. Colours and widths only: transparencies belong to Kit.fade, which hides the
-- HUD behind a window.
local function flash(frame: GuiObject, color: Color3, rest: Color3, time: number, edge: Color3?, restEdge: Color3?, width: number?)
	frame.BackgroundColor3 = rest:Lerp(color, 0.7)
	Kit.tween(frame, time, { BackgroundColor3 = rest }, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
	local stroke = edgeOf(frame)
	if stroke and edge then
		stroke.Color = edge
		stroke.Thickness = width or TUNE.PlateEdgeWidth
		Kit.tween(
			stroke,
			time,
			{ Color = restEdge or TUNE.PlateEdge, Thickness = TUNE.PlateEdgeWidth },
			Enum.EasingStyle.Quad,
			Enum.EasingDirection.In
		)
	end
end

-- An endless there-and-back tween (nothing in the preview); Cancel() stops it.
local function pulse(obj: Instance, beat: number, props: { [string]: any }): Tween?
	if PREVIEW then
		return nil
	end
	local tween = TweenService:Create(obj, TweenInfo.new(beat, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true), props)
	tween:Play()
	return tween
end

-- A sheen for a rounded plate: a light overlay whose slanted band slides across it, drawn
-- under the plate's content. No clipping and no rotated frame (a rotated child is not
-- clipped): the band is the overlay's gradient, moved by its Offset. Returns the switch:
-- (true, pause) runs it for ever with `pause` seconds between two passes, (false) stops it.
local function sheen(face: GuiObject, radius: number, color: Color3?): (boolean, number?) -> ()
	local overlay = Kit.new("Frame", {
		Name = "Sheen",
		BackgroundColor3 = color or Color3.new(1, 1, 1),
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1),
		Visible = false,
		ZIndex = 0,
		Parent = face,
	})
	overlay:SetAttribute("KitChrome", true)
	Kit.corner(overlay, radius)
	local band = Kit.new("UIGradient", {
		Rotation = TUNE.SheenTilt,
		Offset = Vector2.new(-1, 0),
		Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 1),
			NumberSequenceKeypoint.new(0.36, 1),
			NumberSequenceKeypoint.new(0.5, TUNE.SheenAlpha),
			NumberSequenceKeypoint.new(0.64, 1),
			NumberSequenceKeypoint.new(1, 1),
		}),
		Parent = overlay,
	})
	local turn = 0
	return function(on: boolean, pause: number?)
		turn += 1
		local mine = turn
		band.Offset = Vector2.new(-1, 0)
		overlay.Visible = on and not PREVIEW
		if not on or PREVIEW then
			return
		end
		task.spawn(function()
			while turn == mine and overlay.Parent do
				band.Offset = Vector2.new(-1, 0)
				Kit.tween(band, TUNE.SheenTime, { Offset = Vector2.new(1, 0) }, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut)
				task.wait(TUNE.SheenTime + (pause or 2))
			end
		end)
	end
end

-- The Blender-rendered sparkle (Assets.Images "vfx/Sparkle"), looked up once; nil without it.
local sparkImage: string | boolean | nil = nil
local function sparkId(): string?
	if sparkImage == nil then
		sparkImage = false
		pcall(function()
			local module = ReplicatedStorage:FindFirstChild("Shared")
			module = module and module:FindFirstChild("Assets")
			if module and module:IsA("ModuleScript") then
				sparkImage = (require(module) :: any).image("vfx/Sparkle") or false
			end
		end)
	end
	return if type(sparkImage) == "string" then sparkImage else nil
end

-- A sparkle sweep to go with a sheen: TUNE.Sparks stars cross `face` left to right in the
-- sheen's time and at its pace, each popping up, spinning and fading on the way (a turned
-- square stands in for the sparkle image). The same switch as sheen's.
local function sparkles(face: GuiObject, color: Color3): (boolean, number?) -> ()
	local turn = 0
	local function star(): GuiObject
		local id = sparkId()
		local spark: GuiObject
		if id then
			spark = Kit.new("ImageLabel", {
				Image = id,
				ImageColor3 = color,
				BackgroundTransparency = 1,
			})
		else
			spark = Kit.new("Frame", { BackgroundColor3 = color, BorderSizePixel = 0, Rotation = 45 })
			Kit.corner(spark, 2)
		end
		spark.Name = "Spark"
		spark.AnchorPoint = Vector2.new(0.5, 0.5)
		spark.Size = UDim2.fromOffset(0, 0)
		spark.ZIndex = 4
		spark:SetAttribute("KitChrome", true)
		return spark
	end
	return function(on: boolean, pause: number?)
		turn += 1
		local mine = turn
		if not on or PREVIEW then
			return
		end
		task.spawn(function()
			while turn == mine and face.Parent do
				local gui = face:FindFirstAncestorOfClass("ScreenGui")
				if face.Visible and not (gui and gui:GetAttribute("WindowOpen") == true) then
					for _ = 1, TUNE.Sparks do
						local size = math.random(TUNE.SparkSize[1], TUNE.SparkSize[2])
						local spark = star()
						local late = math.random() * TUNE.SparkJitter * TUNE.SheenTime
						local time = TUNE.SheenTime - late
						local y = 0.15 + math.random() * 0.7
						spark.Position = UDim2.fromScale(late / TUNE.SheenTime, y)
						spark.Parent = face
						Kit.tween(
							spark,
							time,
							{ Position = UDim2.fromScale(1.02, y), Rotation = spark.Rotation + TUNE.SparkSpin },
							Enum.EasingStyle.Linear
						)
						Kit.tween(spark, time * 0.3, { Size = UDim2.fromOffset(size, size) }, Enum.EasingStyle.Back)
						task.delay(time * 0.55, function()
							Kit.tween(spark, time * 0.45, { Size = UDim2.fromOffset(0, 0) }, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
						end)
						task.delay(time + 0.05, function()
							spark:Destroy()
						end)
					end
				end
				task.wait(TUNE.SheenTime + (pause or 2))
			end
		end)
	end
end

-- A waiting call to action hops for ever about `rest`: up GiftHop px with a tilt (to one side,
-- then the other), down with a bounce, a pause, again. Returns a stop function that puts it back.
local function hop(gui: GuiObject, rest: UDim2): () -> ()
	local alive = not PREVIEW
	task.spawn(function()
		local side = 1
		while alive and gui.Parent do
			Kit.tween(gui, TUNE.GiftUp, { Position = rest - UDim2.fromOffset(0, TUNE.GiftHop), Rotation = side * TUNE.GiftTilt })
			task.wait(TUNE.GiftUp)
			if not alive then
				break
			end
			Kit.tween(gui, TUNE.GiftDown, { Position = rest, Rotation = 0 }, Enum.EasingStyle.Bounce)
			side = -side
			task.wait(TUNE.GiftDown + TUNE.GiftEvery)
		end
	end)
	return function()
		alive = false
		Kit.tween(gui, 0.15, { Position = rest, Rotation = 0 })
	end
end

-- A short sideways shake about `rest` (`steps` px, `step` seconds each); one at a time.
local function shake(gui: GuiObject, rest: UDim2, steps: { number }, step: number)
	if gui:GetAttribute("Shaking") == true then
		return
	end
	gui:SetAttribute("Shaking", true)
	task.spawn(function()
		for _, dx in steps do
			Kit.tween(gui, step, { Position = rest + UDim2.fromOffset(dx, 0) }, Enum.EasingStyle.Sine)
			task.wait(step)
		end
		gui.Position = rest
		gui:SetAttribute("Shaking", nil)
	end)
end

local function textWidth(text: string, size: number, font: Enum.Font): number
	local plain = string.gsub(text, "<[^>]->", "")
	local ok, bounds = pcall(function()
		return TextService:GetTextSize(plain, size, font, Vector2.new(2000, 200))
	end)
	if ok and typeof(bounds) == "Vector2" and bounds.X > 0 then
		return math.ceil(bounds.X)
	end
	return math.ceil(#plain * size * 0.6)
end

-- A row of guis laid out left to right and centred vertically: icons keep their
-- width, labels are measured. Hidden items take no space. Returns the end x.

function Hud.build(screen: ScreenGui, handlers: Handlers, sounds: any)
	-- Luau allows 200 locals in one function and this one is close to it (a chunk over the
	-- limit does not load at all; tests/fx_juice.luau compiles every script to catch it).
	-- Sections whose locals nothing later needs sit in `do ... end` blocks: keep new state
	-- inside one, or in a block of its own.
	local action = Net.event("Action")
	local compact = false
	local promoFits = true -- touch: the promo only shows where it clears the thumbstick
	local screenScale = screen:FindFirstChildOfClass("UIScale")

	local function toast(text: string, tone: string?)
		if handlers.toast then
			handlers.toast(text, tone)
		end
	end
	-- Where things rest (design px): the edges, the wallet and the grid (measure, in the layout
	-- block below) and the top stack's three plates (measureTop there: count and strip x from
	-- the screen's centre, the strip's and the goal's y). `layoutTop` re-places the stack
	-- after a plate changed its width; it is filled in by the layout block.
	local L = {
		edge = EDGE_X,
		bottom = -6,
		walletTop = false,
		walletY = 0,
		gridY = GRID_Y,
		tap = 0,
		tankX = 0,
		freeY = -20,
		countX = 0,
		stripX = 0,
		stripY = TUNE.TopY,
		goalY = TUNE.TopY + TUNE.RowH + TUNE.StackGap,
		layoutTop = function(_animate: boolean) end,
	}
	local function designSize(): Vector2
		local ok, absolute = pcall(function()
			return screen.AbsoluteSize
		end)
		if not ok or typeof(absolute) ~= "Vector2" then
			return Vector2.zero
		end
		return absolute / (if screenScale then screenScale.Scale else 1)
	end
	-- Text under the screen's UIScale is drawn at a whole pixel size, so on a small screen it
	-- runs a little wider than its design width: measured as drawn.
	local function drawnWidth(text: string, size: number, font: Enum.Font): number
		local scale = if screenScale then screenScale.Scale else 1
		local width = textWidth(text, size, font)
		if scale < 1 then
			width = math.max(width, math.ceil(textWidth(text, math.ceil(size * scale), font) / scale))
		end
		return width
	end

	-- Rolling numbers: each label counts from what it last showed to the new
	-- value (Kit.countTo); unchanged values just re-render (number format setting).
	local rolled: { [Instance]: number } = {}
	local rollEnds: { [Instance]: number } = {}
	local function roll(label: TextLabel, value: number, format: (number) -> string, duration: number?)
		local last = rolled[label]
		rolled[label] = value
		if last == nil or last == value then
			if (rollEnds[label] or 0) <= os.clock() then
				label.Text = format(value)
			end
			return
		end
		local time = duration or 0.45
		Kit.countTo(label, last, value, format, time)
		rollEnds[label] = os.clock() + time
	end
	-- A transparent group frame (HUD blocks have no backing).
	local function group(name: string, props: { [string]: any }): Frame
		props.Name = name
		props.BackgroundTransparency = 1
		props.Parent = props.Parent or screen
		return Kit.new("Frame", props)
	end
	-- Invisible hit pads grow small buttons to TAP_PX on touch (sized in place()).
	local pads: { { pad: TextButton, button: GuiObject } } = {}
	local function hitPad(button: GuiObject, onClick: () -> ())
		local pad = Kit.new("TextButton", {
			Name = "Hit",
			Text = "",
			AutoButtonColor = false,
			BackgroundTransparency = 1,
			Selectable = false,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromScale(1, 1),
			Visible = false,
			ZIndex = 30,
			Parent = button,
		})
		pad.Activated:Connect(function()
			Kit.sound("Click")
			onClick()
		end)
		table.insert(pads, { pad = pad, button = button })
	end
	-- A HUD button's feel: the hover lift (mouse or gamepad selection), the press squash
	-- and the click.
	local function wire(button: TextButton, onClick: () -> ()): TextButton
		local scale = Kit.new("UIScale", { Parent = button })
		Kit.selectable(button)
		local function hover()
			Kit.tween(scale, 0.12, { Scale = 1.07 })
		end
		local function unhover()
			Kit.tween(scale, 0.12, { Scale = 1 })
		end
		button.MouseEnter:Connect(hover)
		button.MouseLeave:Connect(unhover)
		-- Gamepad selection shows the same lift as the mouse hover.
		pcall(function()
			button.SelectionGained:Connect(hover)
			button.SelectionLost:Connect(unhover)
		end)
		button.MouseButton1Down:Connect(function()
			Kit.tween(scale, 0.08, { Scale = 0.92 })
		end)
		button.MouseButton1Up:Connect(function()
			Kit.tween(scale, 0.15, { Scale = 1 }, Enum.EasingStyle.Back)
		end)
		button.Activated:Connect(function()
			Kit.sound("Click")
			onClick()
		end)
		return button
	end
	-- A panel-less tap target: the button itself is the icon square (badges and glow
	-- rings sit on it).
	local function bareButton(parent: Instance, name: string, size: number, onClick: () -> ()): TextButton
		return wire(
			Kit.new("TextButton", {
				Name = name,
				Text = "",
				AutoButtonColor = false,
				BackgroundTransparency = 1,
				Size = UDim2.fromOffset(size, size),
				Parent = parent,
			}),
			onClick
		)
	end

	-- Top bar, far right: the Settings gear alone ----------------------------------------
	-- It sits on the top bar's line (above our safe area) so Roblox's player list,
	-- which starts under the top bar, never covers it.
	local gear: TextButton
	gear = bareButton(screen, "Settings", GEAR, function()
		handlers.openWindow("Settings", { origin = gear })
	end)
	gear.AnchorPoint = Vector2.new(1, 0)
	gear.Position = UDim2.new(1, -10, 0, -GEAR - 7)
	Kit.hudIcon(gear, "Settings", GEAR, C.Text, { Name = "Icon", ZIndex = 2 }).Size = UDim2.fromScale(1, 1)
	Hud.buttons.Settings = gear

	-- Left edge: menu grid, a plate per button --------------------------------------------
	-- Each button is its own dark glass plate (Kit.hudGlass, 70% opaque: world signs behind
	-- the menu do not read through it) holding the icon and, inside it, the caption. The
	-- plates share one size, set by the widest caption as drawn (applyCompact), so two
	-- captions can never meet.
	-- Modes draws the rendered finish-flag image; Star stands in if it is missing. Daily
	-- is the second gift of the atlas (the FREE gift keeps the first).
	local ICON_FOR: { [string]: string } = { Modes = Kit.pickIcon("Modes", "Star"), Daily = Kit.pickIcon("Gift2", "Free") }
	local grid = group("Menu", { Position = UDim2.fromOffset(EDGE_X, GRID_Y) })
	-- One dark backing plate under all of them (a world label never shows between two rows),
	-- as big as the grid and MenuBackPad more on every side.
	do
		local back = Kit.hudGlass(grid, {
			Name = "Backing",
			Shadow = false,
			Color = TUNE.MenuBackColor,
			Transparency = TUNE.MenuBackAlpha,
			Radius = TUNE.MenuBackRadius,
			Size = UDim2.new(1, TUNE.MenuBackPad * 2, 1, TUNE.MenuBackPad * 2),
			Position = UDim2.fromOffset(-TUNE.MenuBackPad, -TUNE.MenuBackPad),
			ZIndex = 0,
		})
		back.Selectable = false
	end
	local captions: { TextLabel } = {}
	local gridIcons: { [string]: Frame } = {}
	local function gridButton(name: string, onClick: () -> ()): TextButton
		local button = Kit.hudGlass(grid, {
			Name = name,
			Button = true,
			Shadow = false,
			Size = UDim2.fromOffset(GRID_ICON + GRID_PAD * 2, GRID_ICON + CAPTION + GRID_PAD * 2),
			Radius = Kit.RADIUS.M,
		}) :: TextButton
		wire(button, onClick)
		gridIcons[name] = Kit.hudIcon(button, ICON_FOR[name] or name, GRID_ICON, C.Text, {
			Name = "Icon",
			Position = UDim2.new(0.5, 0, 0, GRID_PAD),
			AnchorPoint = Vector2.new(0.5, 0),
			ZIndex = 2,
		})
		local caption = Kit.hudText(button, {
			Name = "Caption",
			Text = CAPTIONS[name],
			TextSize = CAPTION,
			MinPx = true,
			StrokeThickness = 2,
			Size = UDim2.new(1, 0, 0, CAPTION + 4),
			Position = UDim2.new(0.5, 0, 1, -3),
			AnchorPoint = Vector2.new(0.5, 1),
			ZIndex = 4,
		})
		table.insert(captions, caption)
		button:SetAttribute("Label", CAPTIONS[name])
		Hud.buttons[name] = button
		return button
	end

	-- One menu button calls at a time: the first of MENU_RANK that wants to (`wants`) is the
	-- focus. Its badge beats (the beat, below), it wears its ring if one is wanted (`ring`:
	-- Index with a reward waiting until it is opened, Modes while new) and Daily breathes.
	-- `modesNewUntil`: os.clock() until which Modes is new (0: it is not).
	local menu = {
		wants = {} :: { [string]: boolean },
		ring = {} :: { [string]: boolean },
		focus = nil :: string?,
		modesNewUntil = 0,
		-- The goal plate says READY: one cue at a time, so the Modes ring and arrow rest.
		goalReady = false,
		stopBreath = nil :: (() -> ())?,
		refocus = function() end,
		modesSeen = function() end,
		unlockBurst = function() end,
		arrow = nil :: Frame?,
	}
	menu.refocus = function()
		local focus: string? = nil
		for _, want in MENU_RANK do
			if menu.wants[want] then
				focus = MENU_BUTTON[want]
				break
			end
		end
		menu.focus = focus
		for name, wanted in menu.ring do
			local button = Hud.buttons[name]
			if button then
				Kit.setGlow(button, wanted and name == focus and not (name == "Modes" and menu.goalReady))
			end
		end
		if menu.arrow then
			menu.arrow.Visible = menu.wants.ModesNew == true and focus == "Modes" and not menu.goalReady
		end
		if focus == "Daily" and Hud.buttons.Daily then
			menu.stopBreath = menu.stopBreath or Kit.breathe(Hud.buttons.Daily, 0.06)
		elseif menu.stopBreath then
			menu.stopBreath()
			menu.stopBreath = nil
		end
	end
	-- Modes was opened (or has been new long enough): it is not new any more.
	menu.modesSeen = function()
		menu.modesNewUntil = 0
		menu.wants.ModesNew = false
		menu.ring.Modes = false
		menu.refocus()
	end

	-- New discoveries since the Index was last opened (badge).
	local seenDiscoveries: number? = nil
	-- Index milestone rewards waiting, as last painted (the glow follows its changes only).
	local indexClaimable = 0
	local function discoveredCount(data: { [string]: any }): number
		local found = 0
		for tier = 1, Economy.MAX_TIER do
			if (data.discovered[tier] or 0) > 0 then
				found += 1
			end
		end
		return found
	end
	local function refreshIndexBadge()
		local data = State.data
		if not data or not seenDiscoveries then
			return
		end
		local fresh = discoveredCount(data) - seenDiscoveries
		-- A milestone reward waiting in the Index window (the snapshot's `indexClaimable`)
		-- goes in front of the count of new finds, and the button glows until the Index is opened.
		local claimable = math.max(0, math.floor(tonumber(data.indexClaimable) or 0))
		-- Every tier found and every milestone claimed: the Index has nothing left to give, so a
		-- count of finds would only read as rewards waiting. No badge from then on.
		if claimable == 0 and discoveredCount(data) >= Economy.MAX_TIER then
			fresh = 0
		end
		Kit.setBadge(Hud.buttons.Index, if claimable > 0 then "!" elseif fresh > 0 then tostring(fresh) else nil)
		if claimable ~= indexClaimable then
			indexClaimable = claimable
			menu.ring.Index = claimable > 0
		end
		menu.wants["Index!"] = claimable > 0
		menu.wants.Index = fresh > 0
		menu.refocus()
	end
	gridButton("Home", function()
		action:FireServer({ action = "Home" })
	end)
	gridButton("Ranking", function()
		handlers.openWindow("Ranking", { origin = Hud.buttons.Ranking })
	end)
	gridButton("Modes", function()
		menu.modesSeen()
		handlers.openWindow("Modes", { origin = Hud.buttons.Modes })
	end)
	-- In a block: its locals stay out of build's 200 (see the note at the top of build).
	do
		-- New Modes: a gold arrow (a stem over a diamond's lower point) bobbing over the plate.
		local arrow = Kit.new("Frame", {
			Name = "NewArrow",
			BackgroundTransparency = 1,
			Size = UDim2.fromOffset(TUNE.ModesArrow, TUNE.ModesArrow + TUNE.ModesArrowStem[2]),
			Position = UDim2.new(0.5, 0, 0, -TUNE.ModesArrowGap),
			AnchorPoint = Vector2.new(0.5, 1),
			Visible = false,
			ZIndex = 8,
			Parent = Hud.buttons.Modes,
		})
		local ink = G.TextInk
		local stem = Kit.new("Frame", {
			Name = "Stem",
			BackgroundColor3 = TUNE.ModesArrowColor,
			BorderSizePixel = 0,
			Size = UDim2.fromOffset(TUNE.ModesArrowStem[1], TUNE.ModesArrowStem[2] + 6),
			Position = UDim2.new(0.5, 0, 0, 0),
			AnchorPoint = Vector2.new(0.5, 0),
			ZIndex = 9,
			Parent = arrow,
		})
		Kit.corner(stem, 3)
		Kit.new("UIStroke", { Thickness = 2, Color = ink, Parent = stem })
		-- The head: a square turned 45 degrees, its upper half under the stem's foot.
		local side = math.floor(TUNE.ModesArrow / math.sqrt(2) + 0.5)
		local head = Kit.new("Frame", {
			Name = "Head",
			BackgroundColor3 = TUNE.ModesArrowColor,
			BorderSizePixel = 0,
			Size = UDim2.fromOffset(side, side),
			Position = UDim2.new(0.5, 0, 1, -TUNE.ModesArrow / 2),
			AnchorPoint = Vector2.new(0.5, 0.5),
			Rotation = 45,
			ZIndex = 8,
			Parent = arrow,
		})
		Kit.corner(head, 3)
		Kit.new("UIStroke", { Thickness = 2, Color = ink, Parent = head })
		local rest = arrow.Position
		pulse(arrow, TUNE.ModesArrowBeat, { Position = rest - UDim2.fromOffset(0, TUNE.ModesArrowBob) })
		menu.arrow = arrow
	end
	-- Modes lights up for the first time: a gold burst on its plate (a ring that blows out,
	-- rays, gold confetti) and a gold "MODES UNLOCKED!" pop to the right of the menu, clear of
	-- it, that holds for a few seconds. In design px on the screen, from the plate's place.
	menu.unlockBurst = function()
		local modes = Hud.buttons.Modes
		local right = Hud.buttons.Index or modes
		if not modes or PREVIEW then
			return
		end
		local scale = if screenScale then screenScale.Scale else 1
		local origin = screen.AbsolutePosition
		local centre = (modes.AbsolutePosition + modes.AbsoluteSize / 2 - origin) / scale
		Kit.pop(modes, TUNE.ModesUnlockPop)
		Kit.confetti(modes, {
			Origin = UDim2.fromScale(0.5, 0.45),
			Count = TUNE.ModesUnlockConfetti,
			ZIndex = 20,
			Colors = { C.Gold, C.GoldLight, Color3.new(1, 1, 1) },
			Power = 0.7,
		})
		local burst = Kit.new("Frame", {
			Name = "UnlockBurst",
			BackgroundTransparency = 1,
			Size = UDim2.fromOffset(0, 0),
			Position = UDim2.fromOffset(centre.X, centre.Y),
			ZIndex = 20,
			Parent = screen,
		})
		local ring = Kit.new("Frame", {
			Name = "Ring",
			BackgroundTransparency = 1,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Size = UDim2.fromOffset(40, 40),
			ZIndex = 20,
			Parent = burst,
		})
		Kit.round(ring)
		local stroke = Kit.new("UIStroke", { Color = TUNE.ModesUnlockColor, Thickness = TUNE.ModesUnlockRingWidth, Parent = ring })
		local grow = TUNE.ModesUnlockRing
		Kit.tween(ring, TUNE.ModesUnlockTime, { Size = UDim2.fromOffset(grow, grow) }, Enum.EasingStyle.Quad)
		Kit.tween(stroke, TUNE.ModesUnlockTime, { Thickness = 1, Transparency = 1 }, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
		for i = 1, TUNE.ModesUnlockRays do
			local turn = (i - 1) / TUNE.ModesUnlockRays * 360 + math.random(-8, 8)
			local ray = Kit.new("Frame", {
				Name = "Ray",
				BackgroundColor3 = if i % 2 == 0 then C.GoldLight else TUNE.ModesUnlockColor,
				BorderSizePixel = 0,
				AnchorPoint = Vector2.new(0, 0.5),
				Size = UDim2.fromOffset(TUNE.ModesUnlockRayLength[1], TUNE.ModesUnlockRayWidth),
				Rotation = turn,
				ZIndex = 21,
				Parent = burst,
			})
			Kit.round(ray)
			-- Each ray shoots out along its angle, stretching, then thins away.
			local a = math.rad(turn)
			local reach = TUNE.ModesUnlockRayReach
			Kit.tween(ray, TUNE.ModesUnlockTime, {
				Position = UDim2.fromOffset(math.cos(a) * reach, math.sin(a) * reach),
				Size = UDim2.fromOffset(TUNE.ModesUnlockRayLength[2], TUNE.ModesUnlockRayWidth),
			}, Enum.EasingStyle.Quad)
			task.delay(TUNE.ModesUnlockTime * 0.55, function()
				Kit.tween(
					ray,
					TUNE.ModesUnlockTime * 0.45,
					{ BackgroundTransparency = 1, Size = UDim2.fromOffset(TUNE.ModesUnlockRayLength[2], 0) }
				)
			end)
		end
		task.delay(TUNE.ModesUnlockTime + 0.1, function()
			burst:Destroy()
		end)
		-- The pop: a gold pill with dark words, to the right of the menu's first row.
		local x = (right.AbsolutePosition.X + right.AbsoluteSize.X - origin.X) / scale + TUNE.ModesUnlockGap
		local pill = Kit.new("Frame", {
			Name = "ModesUnlocked",
			BackgroundColor3 = TUNE.ModesUnlockColor,
			BorderSizePixel = 0,
			AutomaticSize = Enum.AutomaticSize.X,
			AnchorPoint = Vector2.new(0, 0.5),
			Size = UDim2.fromOffset(0, TUNE.ModesUnlockPillH),
			Position = UDim2.fromOffset(x, centre.Y),
			ZIndex = 22,
			Parent = screen,
		})
		Kit.round(pill)
		Kit.padding(pill, 0, 16)
		local edge = Kit.new("UIStroke", { Color = G.TextInk, Thickness = 3, Parent = pill })
		local words = Kit.text(pill, {
			Name = "Words",
			Text = TUNE.ModesUnlockWords,
			Font = F.Display,
			TextSize = TUNE.ModesUnlockText,
			TextWrapped = false,
			TextColor3 = C.GoldInk,
			StrokeThickness = 0,
			AutomaticSize = Enum.AutomaticSize.X,
			Size = UDim2.fromOffset(0, TUNE.ModesUnlockPillH),
			ZIndex = 23,
		})
		-- A gold pointer on its left, at the menu.
		local tip = Kit.new("Frame", {
			Name = "Tip",
			BackgroundColor3 = TUNE.ModesUnlockColor,
			BorderSizePixel = 0,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Size = UDim2.fromOffset(14, 14),
			Position = UDim2.new(0, -16, 0.5, 0),
			Rotation = 45,
			ZIndex = 21,
			Parent = pill,
		})
		Kit.new("UIStroke", { Color = G.TextInk, Thickness = 3, Parent = tip })
		local pillScale = Kit.new("UIScale", { Scale = 0.2, Parent = pill })
		Kit.tween(pillScale, 0.35, { Scale = 1 }, Enum.EasingStyle.Back)
		task.delay(0.4, function()
			if pill.Parent then
				pulse(pillScale, TUNE.ModesUnlockBeat, { Scale = 1.08 })
			end
		end)
		task.delay(TUNE.ModesUnlockHold, function()
			Kit.tween(pill, 0.3, { BackgroundTransparency = 1 })
			Kit.tween(tip, 0.3, { BackgroundTransparency = 1 })
			Kit.tween(words, 0.3, { TextTransparency = 1 })
			Kit.tween(edge, 0.3, { Transparency = 1 })
			for _, child in tip:GetChildren() do
				if child:IsA("UIStroke") then
					Kit.tween(child, 0.3, { Transparency = 1 })
				end
			end
			task.delay(0.35, function()
				pill:Destroy()
			end)
		end)
	end
	local function openIndex()
		menu.ring.Index = false
		local data = State.data
		if data then
			seenDiscoveries = discoveredCount(data)
			refreshIndexBadge()
		end
		handlers.openWindow("Index", { origin = Hud.buttons.Index })
	end
	gridButton("Index", openIndex)
	gridButton("Shop", function()
		handlers.openWindow("Shop", { origin = Hud.buttons.Shop })
	end)
	gridButton("Invite", function()
		pcall(function()
			SocialService:PromptGameInvite(Players.LocalPlayer)
		end)
	end)
	local dailyButton = gridButton("Daily", function()
		handlers.openWindow("Daily", { origin = Hud.buttons.Daily })
	end)
	local dailyCaption = dailyButton:FindFirstChild("Caption") :: TextLabel
	-- Right after the tutorial finishes (watched live this session) Modes is new: its gold ring
	-- and arrow, and the goal plate's second line says so (pickNear). No toast: a third row
	-- under the top stack would sit on the plot's signs.
	local tutorialWasOpen = false
	State.changed.Event:Connect(function(data)
		if data.tutorialDone ~= true then
			tutorialWasOpen = true
		elseif tutorialWasOpen then
			tutorialWasOpen = false
			task.delay(TUNE.ModesNewDelay, function()
				menu.modesNewUntil = os.clock() + TUNE.ModesNewSeconds
				menu.wants.ModesNew = true
				menu.ring.Modes = true
				menu.refocus()
				-- The burst waits for the tutorial's "YOU DID IT!" banner to have come and gone
				-- (Popups sets "TutorialCheered" as it closes) and for nothing to stand in its way
				-- (a window, a modal card, a reveal, another banner), at most ModesUnlockWaitMax s.
				task.spawn(function()
					local function busy(): boolean
						return screen:GetAttribute("WindowOpen") == true
							or screen:GetAttribute("ModalOpen") == true
							or screen:GetAttribute("RevealOpen") == true
							or screen:FindFirstChild("Banner") ~= nil
					end
					local waited = 0
					while waited < TUNE.ModesUnlockWaitMax do
						if screen:GetAttribute("TutorialCheered") == true and not busy() then
							-- A clear moment that lasts ModesUnlockAfter (a surge banner may follow).
							waited += task.wait(TUNE.ModesUnlockAfter)
							if not busy() then
								break
							end
						else
							waited += task.wait(0.1)
						end
					end
					if not busy() and screen:GetAttribute("RunActive") ~= true then
						menu.unlockBurst()
					end
				end)
				task.delay(TUNE.ModesNewSeconds, function()
					if os.clock() >= menu.modesNewUntil then
						menu.modesSeen()
					end
				end)
			end)
		end
	end)

	-- Promo under the grid: tilted tag, button, price chip ----------------------------------
	-- Starter pack until it is owned, then 2X CASH until that is owned, then nothing (PROMOS).
	-- A glass card in the HUD's language, kept quieter than the menu plates over it: three
	-- buttons wide and lower than one, the window tint with the money green mixed in, a green
	-- edge and no pulsing ring (the Modes button's glow is the loud one); a slow sheen crosses
	-- it instead. The offer's name is outlined HUD text and only the price sits on a small
	-- solid chip.
	local promo = group("Promo", { Size = UDim2.fromOffset(TUNE.PromoW, TUNE.PromoH + 16), Visible = false })
	local promoMode = "DoubleMoney"
	-- Opened once: the offer has been seen, so it stays away until the next visit.
	local promoOpened = false
	local promoButton = Kit.hudGlass(promo, {
		Name = "Button",
		Button = true,
		Shadow = false,
		Color = G.TintTop:Lerp(C.CashDeep, 0.4),
		Transparency = G.Tinted,
		Edge = C.Cash,
		Size = UDim2.fromOffset(TUNE.PromoW, TUNE.PromoH),
		Position = UDim2.fromOffset(0, 12),
		Radius = Kit.RADIUS.M,
	}) :: TextButton
	sheen(promoButton, Kit.RADIUS.M)(true, TUNE.PromoSheenEvery)
	Kit.selectable(promoButton)
	Kit.bouncy(promoButton, 1.04)
	promoButton.Activated:Connect(function()
		Kit.sound("Click")
		promoOpened = true
		handlers.openWindow("Shop", { focus = PROMOS[promoMode].focus, origin = promoButton })
	end)
	local promoLabel = Kit.hudText(promoButton, {
		Name = "Label",
		Text = "2X CASH",
		MaxTextSize = TUNE.PromoText,
		MinPx = true,
		Size = UDim2.new(1, -(TUNE.PromoChipW + 26), 1, -12),
		Position = UDim2.new(0, 12, 0.5, 0),
		AnchorPoint = Vector2.new(0, 0.5),
		TextXAlignment = Enum.TextXAlignment.Left,
		StrokeColor = G.TextInk,
		ZIndex = 3,
	})
	local promoTag = Kit.hudText(promo, {
		Name = "Tag",
		Text = "PERMANENT",
		TextSize = 15,
		MinPx = true,
		TextColor3 = C.Gold,
		Size = UDim2.fromOffset(110, 18),
		Position = UDim2.fromOffset(-4, 2),
		Rotation = -8,
		ZIndex = 8,
	})
	local promoPrice = Kit.pill(promoButton, {
		Name = "Price",
		Text = "199 " .. Kit.ROBUX,
		Color = C.Cash,
		Solid = true,
		TextSize = TUNE.PromoPrice,
		MinPx = true,
		Size = UDim2.fromOffset(TUNE.PromoChipW, TUNE.PromoChipH),
		Position = UDim2.new(1, -8, 0.5, 0),
		AnchorPoint = Vector2.new(1, 0.5),
		ZIndex = 3,
	})
	local function dressPromo(mode: string)
		promoMode = mode
		local look = PROMOS[mode]
		promoLabel.Text = look.text
		promoTag.Text = look.tag or ""
		promoTag.Visible = look.tag ~= nil
		promoPrice.Text = string.format("%d %s", look.price, Kit.ROBUX)
	end
	local promoShown = false
	-- An ad for a new player, not a fixture: gone from PROMO_MAX_TIER on and once it has
	-- been opened this visit, and not there at all during the tutorial (the quest pill is the
	-- loudest thing on screen then). The Shop keeps both offers.
	local function wantedPromo(): string?
		local data = State.data
		if not data or promoOpened or data.tutorialDone ~= true then
			return nil
		end
		if type(data.discovered) == "table" then
			for tier = PROMO_MAX_TIER, Economy.MAX_TIER do
				if (data.discovered[tier] or 0) > 0 then
					return nil
				end
			end
		end
		local cosmetics = data.cosmetics
		if not (type(cosmetics) == "table" and cosmetics.starterOwned == true) then
			return "Starter"
		elseif data.passes.DoubleMoney ~= true then
			return "DoubleMoney"
		end
		return nil
	end
	local function updatePromo()
		local mode = wantedPromo()
		local show = mode ~= nil
			and not compact
			and promoFits
			and screen:GetAttribute("WindowOpen") ~= true
			and screen:GetAttribute("ObbyMode") ~= true
			and screen:GetAttribute("RunActive") ~= true -- a game-mode run keeps the screen clear
			and screen:GetAttribute("CardioActive") ~= true
		if show and mode ~= promoMode then
			if promoShown then
				-- Switching offers: the old one eases out, the new one eases in.
				promoShown = false
				Kit.disappear(promo, {
					to = 0.85,
					time = 0.18,
					onDone = function()
						dressPromo(mode :: string)
						updatePromo()
					end,
				})
				return
			end
			dressPromo(mode :: string)
		end
		if show == promoShown then
			return
		end
		promoShown = show
		if show then
			Kit.appear(promo, { from = 0.8, time = 0.26 })
		else
			Kit.disappear(promo, { to = 0.85, time = 0.18 })
		end
	end
	dressPromo("DoubleMoney")

	-- Bottom right: FREE gift + countdown, version in the corner --------------------------
	local corner = group("FreeCorner", {
		Size = UDim2.fromOffset(84, 92),
		AnchorPoint = Vector2.new(1, 1),
	})
	local function claimFree()
		local data = State.data
		if not data then
			return
		end
		local left = math.max(0, (data.freeIn or 0) - State.age())
		if left <= 0 then
			-- Claim straight from the HUD; the server answers with a "Cash" effect
			-- (source "Free") that flies coins into the cash amount.
			action:FireServer({ action = "ClaimFree" })
			Hud.freeClaimedAt = os.clock()
			local button = Hud.buttons.Free
			if button then
				Kit.pop(button, 1.4)
				Kit.confetti(button, {
					Origin = UDim2.fromScale(0.5, 0.4),
					Count = 14,
					ZIndex = 12,
					Colors = { C.Cash, C.GoldLight, Color3.new(1, 1, 1) },
					Power = 0.5,
				})
			end
		else
			toast("Next free reward in " .. Format.time(left), "info")
		end
	end
	local freeButton = bareButton(corner, "Free", 60, claimFree)
	freeButton.AnchorPoint = Vector2.new(0.5, 0)
	freeButton.Position = UDim2.fromScale(0.5, 0)
	freeButton:SetAttribute("Label", "Free")
	Kit.hudIcon(freeButton, Kit.pickIcon("Free", "Gift2"), 60, C.Gold, { Name = "Icon", ZIndex = 2 }).Size = UDim2.fromScale(1, 1)
	Hud.buttons.Free = freeButton
	local freeTimer = Kit.hudText(corner, {
		Name = "Timer",
		Text = "",
		TextSize = 20,
		Size = UDim2.new(1, 0, 0, 22),
		Position = UDim2.new(0.5, 0, 0, 62),
		AnchorPoint = Vector2.new(0.5, 0),
		ZIndex = 3,
	})
	-- The ready gift's "CLAIM!" sits on a gold tab (it breathes with the word, its edge beats).
	-- A sibling under the word, not its child: with Sibling ZIndex a child draws over its
	-- parent's text, and the tab hid the word (r5: a blank gold pill in every capture).
	local claimTab = Kit.new("Frame", {
		Name = "ClaimTab",
		BackgroundColor3 = TUNE.ClaimTab,
		BorderSizePixel = 0,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Visible = false,
		ZIndex = freeTimer.ZIndex - 1,
		Parent = corner,
	})
	local function placeClaimTab()
		local at, size = freeTimer.Position, freeTimer.Size
		claimTab.Position = UDim2.new(at.X.Scale, at.X.Offset, at.Y.Scale, at.Y.Offset + size.Y.Offset / 2)
		claimTab.Size = UDim2.new(0, TUNE.ClaimTabW, 0, size.Y.Offset + TUNE.ClaimTabPad)
	end
	placeClaimTab()
	freeTimer:GetPropertyChangedSignal("Position"):Connect(placeClaimTab)
	freeTimer:GetPropertyChangedSignal("Size"):Connect(placeClaimTab)
	Kit.round(claimTab)
	do
		local edge = Kit.new("UIStroke", { Thickness = TUNE.ClaimTabEdgeWidth[1], Color = TUNE.ClaimTabEdge, Parent = claimTab })
		pulse(edge, TUNE.ClaimTabBeat, { Thickness = TUNE.ClaimTabEdgeWidth[2] })
	end
	local version = Kit.hudText(screen, {
		Name = "Version",
		Text = "v" .. Economy.VERSION,
		Font = F.UI,
		TextSize = G.TextMin,
		StrokeThickness = 1.5,
		Size = UDim2.fromOffset(80, 16),
		Position = UDim2.new(1, -8, 1, -4),
		AnchorPoint = Vector2.new(1, 1),
		TextXAlignment = Enum.TextXAlignment.Right,
		TextTransparency = 0.15,
	})
	version.ZIndex = 1

	-- Run pill: a game-mode run's timer under the multiplier chip (the tutorial pill's
	-- slot; ScreenGui attribute "RunActive" tells Tutorial to step aside). Timer from the
	-- server clock, checkpoint n/N, and an "x" that asks "QUIT?" before firing ModeQuit.
	-- A gold "L3" chip on the left names the Parkour level (the Star shows without one).
	-- Glass like the other top-centre notifications (Kit.hudGlass), with an outlined clock.
	-- (RUN_MAP_W: a run with levels has no checkpoints, so the n/N chip is not in the "MAP 3"
	-- chip's way.)
	local RUN_ANCHOR = Vector2.new(0.5, 0)
	local runRest = UDim2.new(0.5, 0, 0, RUN_Y)
	local runAway = UDim2.new(0.5, 0, 0, -RUN_H - 20)
	local runPill = Kit.hudGlass(screen, {
		Name = "RunPill",
		Size = UDim2.fromOffset(RUN_W, RUN_H),
		Position = runAway,
		AnchorPoint = Vector2.new(0.5, 0),
		Visible = false,
	})
	local runStar =
		Kit.icon(runPill, "Star", 22, C.Gold, { Position = UDim2.new(0, 10, 0.5, 0), AnchorPoint = Vector2.new(0, 0.5), ZIndex = 3 })
	local runLevel = Kit.text(runPill, {
		Name = "Level",
		Text = "MAP 1",
		Font = Theme.Fonts.Display,
		TextSize = 14,
		TextWrapped = false,
		Size = UDim2.fromOffset(RUN_MAP_W, 24),
		Position = UDim2.new(0, 6, 0.5, 0),
		AnchorPoint = Vector2.new(0, 0.5),
		BackgroundColor3 = C.Gold,
		BackgroundTransparency = 0,
		TextColor3 = C.GoldInk,
		StrokeThickness = 0,
		Visible = false,
		ZIndex = 3,
	})
	Kit.round(runLevel)
	local runClock = Kit.hudText(runPill, {
		Name = "Clock",
		Text = "0:00.0",
		Font = F.Number,
		TextSize = 20,
		StrokeThickness = 2,
		TextXAlignment = Enum.TextXAlignment.Left,
		Size = UDim2.fromOffset(82, RUN_H),
		Position = UDim2.fromOffset(RUN_CLOCK_X, 0),
		ZIndex = 3,
	})
	local runCheck = Kit.text(runPill, {
		Name = "Checkpoint",
		Text = "0/0",
		Font = F.UI,
		TextSize = 14,
		TextWrapped = false,
		Size = UDim2.fromOffset(62, 24),
		Position = UDim2.new(0, 124, 0.5, 0),
		AnchorPoint = Vector2.new(0, 0.5),
		BackgroundColor3 = C.Well,
		BackgroundTransparency = 0,
		ZIndex = 3,
	})
	Kit.round(runCheck)
	local runCheckScale = Kit.new("UIScale", { Parent = runCheck })
	local quitArmed = false
	local quitButton: TextButton
	local function onQuit()
		if quitArmed then
			quitArmed = false
			action:FireServer({ action = "ModeQuit" })
			return
		end
		-- First tap arms it: the button widens to "QUIT?" for a few seconds.
		quitArmed = true
		Kit.setButton(quitButton, "QUIT?", C.Bad)
		Kit.tween(quitButton, 0.2, { Size = UDim2.fromOffset(64, 28) }, Enum.EasingStyle.Back)
		-- The pill widens with it so "QUIT?" never covers the checkpoint chip.
		Kit.tween(runPill, 0.2, { Size = UDim2.fromOffset(RUN_W + 36, RUN_H) }, Enum.EasingStyle.Back)
		task.delay(3, function()
			if quitArmed then
				quitArmed = false
				Kit.setButton(quitButton, "X", C.SurfaceHi)
				Kit.tween(quitButton, 0.2, { Size = UDim2.fromOffset(30, 28) })
				Kit.tween(runPill, 0.2, { Size = UDim2.fromOffset(RUN_W, RUN_H) })
			end
		end)
	end
	quitButton = Kit.button(runPill, {
		Name = "Quit",
		Text = "X",
		Color = C.SurfaceHi,
		TextSize = 14,
		Size = UDim2.fromOffset(30, 28),
		Position = UDim2.new(1, -4, 0.5, 0),
		AnchorPoint = Vector2.new(1, 0.5),
		Radius = 14,
		Depth = 2,
		ZIndex = 4,
	}, onQuit)
	hitPad(quitButton, onQuit)
	-- In a block: its locals stay out of build's 200 (see the note at the top of build).
	do
		local runStartedAt = 0
		local runShown = false
		local runConn: RBXScriptConnection? = nil
		local lastClockText = ""
		Hud.runStart = function(startedAt: number, checkpoint: number, checkpoints: number, level: number?)
			runStartedAt = startedAt
			runStar.Visible = level == nil
			runLevel.Visible = level ~= nil
			runClock.Position = UDim2.fromOffset(if level then RUN_MAP_W + 12 else RUN_CLOCK_X, 0)
			if level then
				runLevel.Text = "MAP " .. tostring(level)
			end
			runCheck.Text = string.format("%d/%d", checkpoint, checkpoints)
			-- Modes without checkpoints (the obby, since maps have none) hide the n/N chip.
			runCheck.Visible = checkpoints > 0
			quitArmed = false
			Kit.setButton(quitButton, "X", C.SurfaceHi)
			quitButton.Size = UDim2.fromOffset(30, 28)
			runPill.Size = UDim2.fromOffset(RUN_W, RUN_H)
			runPill.AnchorPoint = RUN_ANCHOR
			screen:SetAttribute("RunActive", true)
			if not runShown then
				runShown = true
				runPill.Visible = true
				runPill.Position = runAway
				Kit.tween(runPill, 0.3, { Position = runRest }, Enum.EasingStyle.Back)
			end
			if not runConn then
				runConn = RunService.Heartbeat:Connect(function()
					local tenths = math.floor(math.max(Workspace:GetServerTimeNow() - runStartedAt, 0) * 10)
					local text = string.format("%d:%02d.%d", tenths // 600, (tenths // 10) % 60, tenths % 10)
					if text ~= lastClockText then
						lastClockText = text
						runClock.Text = text
					end
				end)
			end
		end
		Hud.runCheckpoint = function(index: number, checkpoints: number)
			runCheck.Text = string.format("%d/%d", index, checkpoints)
			runCheckScale.Scale = 1.35
			Kit.tween(runCheckScale, 0.3, { Scale = 1 }, Enum.EasingStyle.Back)
			Kit.tween(runCheck, 0.12, { BackgroundColor3 = C.Good })
			task.delay(0.35, function()
				Kit.tween(runCheck, 0.3, { BackgroundColor3 = C.Well })
			end)
		end
		Hud.runStop = function()
			if runConn then
				runConn:Disconnect()
				runConn = nil
			end
			quitArmed = false
			screen:SetAttribute("RunActive", false)
			if runShown then
				runShown = false
				Kit.tween(runPill, 0.25, { Position = runAway }, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
				task.delay(0.26, function()
					if not runShown then
						runPill.Visible = false
					end
				end)
			end
		end

		Hud.dockRun = function(pos: UDim2?, anchor: Vector2?)
			local rest = pos or UDim2.new(0.5, 0, 0, RUN_Y)
			RUN_ANCHOR = anchor or Vector2.new(0.5, 0)
			runRest = rest
			runAway = UDim2.new(rest.X.Scale, rest.X.Offset, 0, -RUN_H - 20)
			if runShown then
				runPill.AnchorPoint = RUN_ANCHOR
				Kit.tween(runPill, 0.25, { Position = runRest }, Enum.EasingStyle.Quad)
			end
		end
	end

	-- Top centre, row 1: the count plate (Chad icon + unit count) ---------------------------
	-- `units` is the slot the layout moves; the plate inside it pops, flashes and shakes.
	local units = group("Units", {
		Size = UDim2.fromOffset(176, TUNE.RowH),
		Position = UDim2.new(0.5, 0, 0, TUNE.TopY),
		AnchorPoint = Vector2.new(0.5, 0),
	})
	local countPlate = plate(units, {
		Name = "Plate",
		Size = UDim2.fromScale(1, 1),
		Position = UDim2.fromScale(0.5, 0.5),
		AnchorPoint = Vector2.new(0.5, 0.5),
	})
	local unitsRow = Kit.new("Frame", {
		Name = "Row",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		ZIndex = 2,
		Parent = countPlate,
	})
	Kit.new("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal,
		HorizontalAlignment = Enum.HorizontalAlignment.Center,
		VerticalAlignment = Enum.VerticalAlignment.Center,
		Padding = UDim.new(0, 6),
		SortOrder = Enum.SortOrder.LayoutOrder,
		Parent = unitsRow,
	})
	local counter = Kit.hudIcon(unitsRow, "Chad", TUNE.CountIcon, C.Rizz, { Name = "Counter", LayoutOrder = 1, ZIndex = 2 })
	local counterLabel = Kit.hudText(unitsRow, {
		Name = "Count",
		Text = "0/100",
		Font = F.Number,
		TextSize = TUNE.CountText,
		StrokeThickness = 2.5,
		Size = UDim2.fromOffset(110, TUNE.RowH),
		LayoutOrder = 2,
		ZIndex = 3,
	})
	-- A full rack is not a stop: buying goes on and the extra Chads merge on their own. Said
	-- on a pill of its own, beside the count.
	local counterCaption = Kit.pill(unitsRow, {
		Name = "Full",
		Text = "AUTO-MERGING",
		Font = F.Display,
		Color = C.Gold,
		Solid = true,
		TextSize = TUNE.FullText,
		MinPx = true,
		AutomaticSize = Enum.AutomaticSize.X,
		Size = UDim2.fromOffset(0, TUNE.FullPillH),
		LayoutOrder = 3,
		Visible = false,
		ZIndex = 3,
	})
	local unitCap = 100
	local function unitsText(n: number): string
		return string.format("%d/%d", n, unitCap)
	end
	local rackFull: boolean? = nil
	-- The plate is as wide as the fullest count, so it holds still while the number runs, and
	-- grows by the pill at a full rack.
	local function fitCount()
		local numberW = drawnWidth(unitsText(unitCap), counterLabel.TextSize, counterLabel.Font) + 6
		counterLabel.Size = UDim2.fromOffset(numberW, TUNE.RowH)
		local width = TUNE.RowPad * 2 + TUNE.CountIcon + 6 + numberW
		if rackFull then
			width += 6 + drawnWidth(counterCaption.Text, counterCaption.TextSize, counterCaption.Font) + 20
		end
		units.Size = UDim2.fromOffset(width, TUNE.RowH)
		L.layoutTop(true)
	end
	counterCaption:GetPropertyChangedSignal("TextSize"):Connect(fitCount)
	-- 100/100 is a moment: the plate turns orange-red, the pill joins the count and a glowing
	-- ring round the plate swells and fades for as long as the rack is full.
	local fullRing = Kit.new("Frame", {
		Name = "FullRing",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, TUNE.FullRingOut * 2, 1, TUNE.FullRingOut * 2),
		Position = UDim2.fromScale(0.5, 0.5),
		AnchorPoint = Vector2.new(0.5, 0.5),
		Visible = false,
		ZIndex = 0,
		Parent = units,
	})
	fullRing:SetAttribute("KitChrome", true)
	Kit.corner(fullRing, TUNE.PlateRadius + TUNE.FullRingOut)
	do
		local stroke = Kit.new("UIStroke", {
			Color = TUNE.FullRingColor,
			Thickness = TUNE.FullRingWidth[1],
			Transparency = TUNE.FullRingAlpha[1],
			Parent = fullRing,
		})
		pulse(stroke, TUNE.FullRingBeat, { Thickness = TUNE.FullRingWidth[2], Transparency = TUNE.FullRingAlpha[2] })
	end
	local function setRackFull(full: boolean)
		if full == rackFull then
			return
		end
		local first = rackFull == nil
		rackFull = full
		counterCaption.Visible = full
		fullRing.Visible = full
		fitCount()
		tint(countPlate, if full then TUNE.FullPlate else nil, if full then TUNE.FullEdge else nil)
		if full and not first then
			Kit.pop(countPlate, TUNE.CountPop)
		end
	end
	-- The count changed by `delta`: the plate pops, its edge flashes, the number flashes
	-- (green up, gold down: a merge) and the Chad icon wiggles. `mergedBuy`: a buy at a full
	-- rack, which merges on its own: the plate shakes and flares.
	local function countChanged(delta: number, mergedBuy: boolean)
		if (delta == 0 and not mergedBuy) or screen:GetAttribute("WindowOpen") == true then
			return
		end
		local full = rackFull == true
		local fill = if full then TUNE.FullPlate else TUNE.PlateColor
		local edge = if full then TUNE.FullEdge else TUNE.PlateEdge
		local white = Color3.new(1, 1, 1)
		if mergedBuy then
			shake(countPlate, UDim2.fromScale(0.5, 0.5), TUNE.FullShake, TUNE.FullShakeStep)
			Kit.pop(counterCaption, 1.5)
		end
		flash(
			countPlate,
			if mergedBuy then TUNE.FullFlash else TUNE.CountPlateFlash,
			fill,
			TUNE.CountFlash,
			white,
			edge,
			TUNE.CountEdgeFlash
		)
		Kit.pop(countPlate, TUNE.CountPop)
		counterLabel.TextColor3 = if delta < 0 then TUNE.CountDown else TUNE.CountUp
		Kit.tween(counterLabel, TUNE.CountFlash, { TextColor3 = white }, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
		counter.Rotation = if delta < 0 then TUNE.CountTilt else -TUNE.CountTilt
		Kit.tween(counter, 0.4, { Rotation = 0 }, Enum.EasingStyle.Back)
	end

	-- Row 1, beside it: the status plate "Deposit bonus: x1.3 · 12s" ------------------------
	-- The same plate. An Aura Surge turns it gold (paintSurge): the bolt, "AURA SURGE", a big
	-- "x2" and the time left, a sheen crossing it and its edge pulsing.
	local strip = plate(screen, {
		Name = "DepositStrip",
		Size = UDim2.fromOffset(280, TUNE.RowH),
		Position = UDim2.new(0.5, 0, 0, TUNE.TopY),
		AnchorPoint = Vector2.new(0.5, 0),
	})
	local stripRow = Kit.new("Frame", {
		Name = "Row",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		ZIndex = 2,
		Parent = strip,
	})
	Kit.new("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal,
		HorizontalAlignment = Enum.HorizontalAlignment.Center,
		VerticalAlignment = Enum.VerticalAlignment.Center,
		Padding = UDim.new(0, 6),
		SortOrder = Enum.SortOrder.LayoutOrder,
		Parent = stripRow,
	})
	local function stripText(name: string, order: number, size: number): TextLabel
		return Kit.hudText(stripRow, {
			Name = name,
			Text = "",
			TextSize = size,
			StrokeThickness = 2,
			AutomaticSize = Enum.AutomaticSize.X,
			Size = UDim2.fromOffset(0, TUNE.RowH),
			LayoutOrder = order,
			ZIndex = 3,
		})
	end
	local stripLead = stripText("Lead", 1, TUNE.StripLead)
	stripLead.Text = "Deposit bonus:"
	local gaugeValue = stripText("Value", 2, TUNE.StripValue)
	local gaugeNext = stripText("Next", 3, TUNE.StripNext)
	gaugeNext.TextColor3 = C.TextDim
	local STRIP_TEXT: { [TextLabel]: number } =
		{ [stripLead] = TUNE.StripLead, [gaugeValue] = TUNE.StripValue, [gaugeNext] = TUNE.StripNext }
	local surgeActiveNow = false
	-- The plate is as wide as its widest line (the longest value and countdown, and the bolt
	-- of a surge), never under StripMinW: text held at a size on a phone needs more room than
	-- the design's.
	local function fitStrip()
		local width = textWidth(stripLead.Text, stripLead.TextSize, F.Display)
			+ textWidth("x0.0", gaugeValue.TextSize, F.Display)
			+ textWidth("· 0:00", gaugeNext.TextSize, F.Display)
			+ (if surgeActiveNow then TUNE.SurgeIcon + 6 else 0)
		strip.Size = UDim2.fromOffset(math.max(TUNE.StripMinW, width + 6 * 2 + TUNE.RowPad * 2), TUNE.RowH)
		L.layoutTop(true)
	end
	-- A rescale re-sizes held text (Kit.reflowText): the plate follows.
	for label in STRIP_TEXT do
		label:GetPropertyChangedSignal("TextSize"):Connect(fitStrip)
	end
	-- Big-roll cheer: pops out to the right of the plate for a moment.
	local niceLabel = Kit.hudText(strip, {
		Name = "Nice",
		Text = "NICE!",
		TextSize = 24,
		TextColor3 = C.Gold,
		Size = UDim2.fromOffset(96, 30),
		Position = UDim2.new(1, 8, 0.5, 0),
		AnchorPoint = Vector2.new(0, 0.5),
		TextXAlignment = Enum.TextXAlignment.Left,
		Rotation = 6,
		Visible = false,
		ZIndex = 5,
	})
	local paintSurge: (boolean) -> ()
	-- The surge's time left (seconds), every frame while one runs: its bar drains.
	local surgeLeft: (number) -> ()
	-- In a block: its locals stay out of build's 200 (see the note at the top of build).
	do
		-- The bolt on a dark medallion, so it reads on the gold.
		local bolt = Kit.new("Frame", {
			Name = "Bolt",
			BackgroundColor3 = TUNE.PlateColor,
			BorderSizePixel = 0,
			Size = UDim2.fromOffset(TUNE.SurgeIcon, TUNE.SurgeIcon),
			LayoutOrder = 0,
			Visible = false,
			ZIndex = 2,
			Parent = stripRow,
		})
		Kit.round(bolt)
		Kit.new("UIStroke", { Thickness = 1.5, Color = TUNE.SurgeEdge, Parent = bolt })
		Kit.icon(bolt, "Surge", TUNE.SurgeIcon - 6, C.Gold, {
			Position = UDim2.fromScale(0.5, 0.5),
			AnchorPoint = Vector2.new(0.5, 0.5),
			ZIndex = 2,
		})
		local shine = sheen(strip, TUNE.PlateRadius)
		local beat: Tween? = nil
		-- The countdown bar: a dark track along the plate's bottom with the gold fill in it.
		local track = Kit.new("Frame", {
			Name = "SurgeBar",
			BackgroundColor3 = G.TextInk,
			BackgroundTransparency = 0.35,
			BorderSizePixel = 0,
			Size = UDim2.new(1, -TUNE.SurgeBarInset * 2, 0, TUNE.SurgeBarH),
			Position = UDim2.new(0, TUNE.SurgeBarInset, 1, -TUNE.SurgeBarH - 2),
			Visible = false,
			ZIndex = 1, -- under the words
			Parent = strip,
		})
		Kit.round(track)
		local fill = Kit.new("Frame", {
			Name = "Fill",
			BackgroundColor3 = TUNE.SurgeBarColor,
			BorderSizePixel = 0,
			Size = UDim2.fromScale(1, 1),
			ZIndex = 2,
			Parent = track,
		})
		Kit.round(fill)
		surgeLeft = function(left: number)
			fill.Size = UDim2.fromScale(math.clamp(left / Economy.SURGE_DURATION, 0, 1), 1)
		end
		-- The gold vignette: four bands round the screen's edge, fading inward, in a screen of
		-- their own under the HUD's; it breathes while the surge runs and steps away for a
		-- window or a game-mode run.
		local vignette = Instance.new("ScreenGui")
		vignette.Name = "SurgeVignette"
		vignette.ResetOnSpawn = false
		vignette.IgnoreGuiInset = true
		vignette.DisplayOrder = screen.DisplayOrder - 1
		vignette.Enabled = false
		vignette.Parent = screen.Parent
		local depth = TUNE.SurgeVignetteDepth
		for _, spec in
			{
				{ UDim2.new(1, 0, depth[1], 0), UDim2.fromScale(0, 0), 90 },
				{ UDim2.new(1, 0, depth[1], 0), UDim2.fromScale(0, 1 - depth[1]), -90 },
				{ UDim2.new(depth[2], 0, 1, 0), UDim2.fromScale(0, 0), 0 },
				{ UDim2.new(depth[2], 0, 1, 0), UDim2.fromScale(1 - depth[2], 0), 180 },
			}
		do
			local band = Kit.new("Frame", {
				Name = "Band",
				BackgroundColor3 = TUNE.SurgeVignette,
				BackgroundTransparency = TUNE.SurgeVignetteAlpha[2],
				BorderSizePixel = 0,
				Size = spec[1],
				Position = spec[2],
				Parent = vignette,
			})
			Kit.new("UIGradient", {
				Rotation = spec[3],
				Transparency = NumberSequence.new({
					NumberSequenceKeypoint.new(0, 0),
					NumberSequenceKeypoint.new(TUNE.SurgeVignetteCore, 0.15),
					NumberSequenceKeypoint.new(1, 1),
				}),
				Parent = band,
			})
			pulse(band, TUNE.SurgeVignetteBeat, { BackgroundTransparency = TUNE.SurgeVignetteAlpha[1] })
		end
		-- The motes: while the vignette shows, gold sparks rise up both side edges, swaying a
		-- little, popping in and shrinking away.
		if not PREVIEW then
			task.spawn(function()
				local side = 1
				while vignette.Parent do
					if vignette.Enabled then
						side = -side
						local id = sparkId()
						local size = math.random(TUNE.SurgeMoteSize[1], TUNE.SurgeMoteSize[2])
						local color = TUNE.SurgeMoteColors[math.random(1, #TUNE.SurgeMoteColors)]
						local mote: GuiObject
						if id then
							mote = Kit.new("ImageLabel", { Image = id, ImageColor3 = color, BackgroundTransparency = 1 })
						else
							mote = Kit.new("Frame", { BackgroundColor3 = color, BorderSizePixel = 0, Rotation = 45 })
							Kit.corner(mote, 3)
						end
						local inset = math.random() * TUNE.SurgeMoteBand
						local x = if side > 0 then inset else 1 - inset
						local y = 0.55 + math.random() * 0.45
						local rise = TUNE.SurgeMoteRise[1] + math.random() * (TUNE.SurgeMoteRise[2] - TUNE.SurgeMoteRise[1])
						local life = TUNE.SurgeMoteLife[1] + math.random() * (TUNE.SurgeMoteLife[2] - TUNE.SurgeMoteLife[1])
						mote.Name = "Mote"
						mote.AnchorPoint = Vector2.new(0.5, 0.5)
						mote.Size = UDim2.fromOffset(0, 0)
						mote.Position = UDim2.fromScale(x, y)
						mote.ZIndex = 2
						mote.Parent = vignette
						local sway = (math.random() - 0.5) * TUNE.SurgeMoteBand
						Kit.tween(
							mote,
							life,
							{ Position = UDim2.fromScale(math.clamp(x + sway, 0.005, 0.995), y - rise), Rotation = mote.Rotation + 120 },
							Enum.EasingStyle.Linear
						)
						Kit.tween(mote, life * 0.2, { Size = UDim2.fromOffset(size, size) }, Enum.EasingStyle.Back)
						task.delay(life * 0.6, function()
							Kit.tween(mote, life * 0.4, { Size = UDim2.fromOffset(0, 0) }, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
						end)
						task.delay(life + 0.05, function()
							mote:Destroy()
						end)
					end
					task.wait(TUNE.SurgeMoteEvery)
				end
			end)
		end
		local function showVignette()
			local busy = screen:GetAttribute("WindowOpen") == true
			for _, name in { "RunActive", "ObbyMode", "CardioActive" } do
				busy = busy or screen:GetAttribute(name) == true
			end
			vignette.Enabled = surgeActiveNow and not busy
		end
		for _, name in { "WindowOpen", "RunActive", "ObbyMode", "CardioActive" } do
			screen:GetAttributeChangedSignal(name):Connect(showVignette)
		end
		paintSurge = function(active: boolean)
			surgeActiveNow = active
			track.Visible = active
			showVignette()
			stripLead.Text = if active then "AURA SURGE" else "Deposit bonus:"
			bolt.Visible = active
			gaugeNext.TextColor3 = if active then Color3.new(1, 1, 1) else C.TextDim
			-- "x2" is the headline of a surge: it is drawn bigger than a deposit bonus.
			STRIP_TEXT[gaugeValue] = if active then TUNE.SurgeValue else TUNE.StripValue
			Kit.holdText(gaugeValue, Kit.captionPx(), STRIP_TEXT[gaugeValue], true)
			fitStrip()
			tint(strip, if active then TUNE.SurgePlate else nil, if active then TUNE.SurgeEdge else nil)
			shine(active, TUNE.SurgeSheenEvery)
			if beat then
				beat:Cancel()
				beat = nil
			end
			local edge = edgeOf(strip)
			if edge then
				edge.Thickness = TUNE.PlateEdgeWidth
				if active then
					beat = pulse(edge, TUNE.SurgeEdgeBeat, { Thickness = TUNE.SurgeEdgeWidth })
				end
			end
		end
	end

	-- Next goal: "Next: Protein Bro 63%" over "1,240 more Normies · about 2 h" --------------
	-- The same plate as row 1, in the fixed slot under it once the tutorial is done (above the
	-- dumbbell on compact screens): the target's thumbnail (a silhouette until it is
	-- discovered), its name and how far along it is, what it still takes under them (units to
	-- buy and an estimate from the price and the income), and a progress bar along the
	-- bottom. The target and its sums come from Shared.NextGoal; the plate opens the Index.
	-- When one merge would find the tier it turns green, breathes and says "READY: step on
	-- MOG MERGE"; a tap then draws the path to that pad. With every tier found it is the
	-- CHAMPION's: gold, a crown on a dark medallion, "CHAMPION" and the top tier's units on the
	-- rack, with no bar (there is nothing left to fill); its second line names an Index
	-- milestone that is not claimed yet (the Index icon with a red dot; a tap opens the
	-- Index), then, with every milestone claimed, it is the LEGEND's (crown-lit violet) over
	-- "All 25 Chads found!".
	-- The slot is L.goalY: StackGap under row 1, and never under that many pixels on the glass
	-- (a small window's scale would close the gap).
	local goal = plate(screen, {
		Name = "NextGoal",
		Button = true,
		Size = UDim2.fromOffset(280, TUNE.GoalH),
		Position = UDim2.new(0.5, 0, 0, L.goalY),
		AnchorPoint = Vector2.new(0.5, 0),
		Visible = false,
	}) :: TextButton
	Kit.selectable(goal)
	local goalThumb = group("Thumb", {
		Size = UDim2.fromOffset(36, 36),
		Position = UDim2.new(0, 7, 0.5, -2),
		AnchorPoint = Vector2.new(0, 0.5),
		ZIndex = 2,
		Parent = goal,
	})
	local function goalText(name: string, size: number, color: Color3, font: Enum.Font?): TextLabel
		return Kit.hudText(goal, {
			Name = name,
			Text = "",
			Font = font,
			TextSize = size,
			TextColor3 = color,
			StrokeThickness = 2,
			TextXAlignment = Enum.TextXAlignment.Left,
			Size = UDim2.fromOffset(10, 22),
			ZIndex = 3,
		})
	end
	local goalLead = goalText("Lead", TUNE.GoalLead, C.Gold)
	goalLead.Text = "Next:"
	local goalTitle = goalText("Title", TUNE.GoalTitle, C.Text)
	-- The name is never cut off: short of room it is scaled into its box (paintGoal).
	local goalTitleFit = Kit.new("UITextSizeConstraint", { MinTextSize = 1, MaxTextSize = 200, Parent = goalTitle })
	local goalCount = goalText("Count", TUNE.GoalCount, C.Text, F.Number)
	local goalHint = goalText("Hint", TUNE.GoalHint, C.TextDim, F.UI)
	goalHint.Position = UDim2.fromOffset(GOAL_TEXT_X, 20)
	goalHint.Size = UDim2.fromOffset(10, 18)
	-- Each text's design size (held on a phone, applyCompact; the title's grows for "CHAMPION").
	local GOAL_TEXT: { [TextLabel]: number } =
		{ [goalLead] = TUNE.GoalLead, [goalTitle] = TUNE.GoalTitle, [goalCount] = TUNE.GoalCount, [goalHint] = TUNE.GoalHint }
	-- The nearer goal's icon, in front of the second line while it names one (paintGoal).
	local goalNearIcon = group("NearIcon", {
		Size = UDim2.fromOffset(16, 16),
		Position = UDim2.fromOffset(GOAL_TEXT_X, 20),
		Visible = false,
		ZIndex = 3,
		Parent = goal,
	})
	-- A real bar: a dark track the whole width with the gold fill inside it.
	local goalTrack = Kit.new("Frame", {
		Name = "Track",
		BackgroundColor3 = G.TextInk,
		BackgroundTransparency = 0.45,
		BorderSizePixel = 0,
		Size = UDim2.new(1, -GOAL_BAR_X * 2, 0, GOAL_BAR_H),
		Position = UDim2.new(0, GOAL_BAR_X, 1, -GOAL_BAR_H - 2),
		ZIndex = 2,
		Parent = goal,
	})
	Kit.round(goalTrack)
	local goalBar = Kit.new("Frame", {
		Name = "Bar",
		BackgroundColor3 = C.Gold,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(0, 1),
		ZIndex = 3,
		Parent = goalTrack,
	})
	Kit.round(goalBar)
	-- Touch: an invisible pad grows the low strip to a full tap target (sized in applyCompact).
	local goalPad = Kit.new("TextButton", {
		Name = "Hit",
		Text = "",
		AutoButtonColor = false,
		BackgroundTransparency = 1,
		Selectable = false,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(1, 1),
		Visible = false,
		ZIndex = 30,
		Parent = goal,
	})
	local goalReady = false
	-- Something closer than the next tier (pickNear, below): `nearShown` is the pick,
	-- `goalNear` the one the strip's second line is showing, which a tap on the strip does.
	type Near = { kind: string, text: string, short: string, icon: string, color: Color3, pad: string?, tag: string? }
	local nearShown: Near? = nil
	local goalNear: Near? = nil
	goal.MouseEnter:Connect(function()
		Kit.tween(goal, 0.12, { BackgroundTransparency = 0 })
	end)
	goal.MouseLeave:Connect(function()
		Kit.tween(goal, 0.12, { BackgroundTransparency = TUNE.PlateAlpha })
	end)
	local function tierName(tier: number): string
		local entry = Theme.Tiers[tier]
		return if entry then entry.Name else ("Tier " .. tier)
	end
	-- "1,240" while the digits are easy to read, the player's short form past that.
	local function unitCount(n: number): string
		return if n < 100000 then Format.commas(n) else State.num(n)
	end
	-- An estimate, said as one: "about 2 h", never a number of seconds.
	local function about(seconds: number?): string
		if seconds == nil then
			return ""
		elseif seconds <= 0 then
			return "cash ready!"
		elseif seconds < 60 then
			return "under a minute"
		end
		local minutes = math.floor(seconds / 60 + 0.5)
		local hours = math.floor(seconds / 3600 + 0.5)
		local days = math.floor(seconds / 86400 + 0.5)
		if minutes < 60 then
			return string.format("about %d min", minutes)
		elseif hours < 48 then
			return string.format("about %d h", math.max(hours, 1))
		elseif days < 60 then
			return string.format("about %d days", days)
		end
		return "months away"
	end
	-- Ready: the plate turns green, breathes and wears a sheen until the merge is made.
	-- Champion (every tier found): it is gold for good, with a slower sheen.
	local setGoalLook: (boolean, boolean, boolean) -> ()
	-- In a block: its locals stay out of build's 200 (see the note at the top of build).
	do
		local champNow = false
		local stopBreath: (() -> ())? = nil
		local shine = sheen(goal, TUNE.PlateRadius)
		local readySparks = sparkles(goal, TUNE.ReadySparkColor)
		local champSparks = sparkles(goal, TUNE.ChampSparkColor)
		-- READY's glow is a steady state a still always catches: a bright inner ring hugging
		-- the plate (its width beats) inside a wide soft halo, both on for as long as it is ready.
		local readyGlow = Kit.new("Frame", {
			Name = "ReadyGlow",
			BackgroundTransparency = 1,
			Size = UDim2.fromScale(1, 1),
			Visible = false,
			ZIndex = 0,
			Parent = goal,
		})
		readyGlow:SetAttribute("KitChrome", true)
		for i, spec in TUNE.ReadyGlow do
			local ring = Kit.new("Frame", {
				Name = "Ring" .. i,
				BackgroundTransparency = 1,
				Size = UDim2.new(1, spec.out * 2, 1, spec.out * 2),
				Position = UDim2.fromScale(0.5, 0.5),
				AnchorPoint = Vector2.new(0.5, 0.5),
				ZIndex = 0,
				Parent = readyGlow,
			})
			ring:SetAttribute("KitChrome", true)
			Kit.corner(ring, TUNE.PlateRadius + spec.out)
			local stroke = Kit.new("UIStroke", { Color = spec.color, Thickness = spec.width[1], Transparency = spec.alpha, Parent = ring })
			if spec.width[2] ~= spec.width[1] then
				pulse(stroke, TUNE.ReadyGlowBeat, { Thickness = spec.width[2] })
			end
		end
		local legendNow = false
		setGoalLook = function(ready: boolean, champ: boolean, legend: boolean)
			if ready == goalReady and champ == champNow and legend == legendNow then
				return
			end
			goalReady, champNow, legendNow = ready, champ, legend
			if menu.goalReady ~= ready then
				menu.goalReady = ready
				menu.refocus()
			end
			-- LEGEND (every tier found, every milestone claimed): crown-lit royal violet with a
			-- thick gold edge and gold title, a slower sheen; CHAMPION before that is gold.
			local fill = if ready then C.Good elseif legend then TUNE.LegendPlate elseif champ then TUNE.ChampPlate else nil
			tint(goal, fill, if legend then TUNE.LegendEdge elseif champ then TUNE.ChampEdge else nil)
			local edge = edgeOf(goal)
			if edge then
				edge.Thickness = if legend then TUNE.LegendEdgeWidth else TUNE.PlateEdgeWidth
			end
			goalTitle.TextColor3 = if legend then TUNE.LegendTitle else C.Text
			goalBar.BackgroundColor3 = if ready then Color3.new(1, 1, 1) else C.Gold
			readyGlow.Visible = ready
			local every = if legend then TUNE.LegendSheenEvery elseif champ then TUNE.ChampSheenEvery else TUNE.ReadySheenEvery
			shine(ready or champ, every)
			readySparks(ready and not champ, TUNE.ReadySheenEvery)
			champSparks(champ, every)
			-- "CHAMPION" is a title: a size up (the plate lays itself out again).
			GOAL_TEXT[goalTitle] = if champ then TUNE.ChampTitle else TUNE.GoalTitle
			Kit.holdText(goalTitle, Kit.captionPx(), GOAL_TEXT[goalTitle], true)
			if stopBreath then
				stopBreath()
				stopBreath = nil
			end
			if ready then
				stopBreath = Kit.breathe(goal, TUNE.ReadyBreathe)
			end
		end
	end
	local goalKey = ""
	local goalTitleShown = ""
	local goalThumbKey = ""
	local goalWidth = 280
	-- The next tier is further off than a Game Mode's reward is worth (pickNear reads it).
	local goalFar = false
	local function paintGoal(data: { [string]: any })
		if type(data.discovered) ~= "table" or type(data.units) ~= "table" then
			return
		end
		-- The Index milestones the snapshot says are claimed (what is left with every tier found).
		local claimed: { number } = {}
		local index = data.index
		if type(index) == "table" and type(index.milestones) == "table" then
			for _, entry in index.milestones do
				if type(entry) == "table" and entry.claimed == true and type(entry.found) == "number" then
					table.insert(claimed, entry.found)
				end
			end
		end
		-- The pick brings what the tier still takes: first-tier units to buy (two of a tier
		-- make one of the next, so everything owned counts) and the seconds of steady income
		-- (no Aura Surge) until they are paid for, wallet and vault counted.
		local picked = NextGoal.pick({
			discovered = data.discovered,
			units = data.units,
			indexClaimed = claimed,
			bought = tonumber(data.bought),
			money = tonumber(data.money),
			pending = tonumber(data.pending),
			income = tonumber(data.rewardIncome) or tonumber(data.income),
		})
		local missing = picked.missing
		local seconds = picked.seconds
		-- With nothing left to find there is no next tier at all.
		goalFar = picked.kind == "done" or seconds == nil or seconds > FAR_SECONDS
		-- One step on MOG MERGE merges every pair upward, so the tier is found as soon as
		-- nothing is missing (not only with two of the best tier). Auto Merge does it alone.
		local auto = data.autoMerge == true and data.autoMergeOwned == true
		local ready = picked.kind == "merge" and picked.mergeReady and not auto
		-- Every tier is found: the plate is the champion's from here on, and counts the top
		-- tier's units on the rack.
		local champ = picked.kind ~= "merge"
		local top = if picked.kind == "done" then picked.have else math.max(0, math.floor(tonumber(data.units[Economy.MAX_TIER]) or 0))
		local topCount = if top > 0 then string.format("%dx %s", top, tierName(Economy.MAX_TIER)) else ""
		setGoalLook(ready, champ, picked.kind == "done")
		-- Line 1: the lead, the target and how far along it is; line 2: what it still takes,
		-- in fewer words when the strip is short of room (`hints`, longest first).
		local lead, title, count = "Next:", tierName(picked.tier), ""
		local hints: { string }
		if ready then
			lead, title = "READY:", "step on " .. W.Merge
			hints = { string.format("New %s: %s", W.Unit, tierName(picked.tier)) }
		elseif picked.kind == "merge" then
			count = string.format("%d%%", picked.percent)
			local eta = about(seconds)
			local tail = if eta ~= "" then " · " .. eta else ""
			local first = tierName(1)
			local name = if missing == 1 or string.sub(first, -1) == "s" then first else first .. "s"
			hints = { string.format("%s more %s%s", unitCount(missing), name, tail), unitCount(missing) .. " more" .. tail, eta }
		elseif picked.kind == "index" then
			-- An Index milestone is not claimed yet: the champion's second line says so, behind
			-- the Index icon and its red dot (the nearer goal's place), and a tap opens the Index.
			lead, title, count = "", "CHAMPION", topCount
			if picked.ready then
				local claim = Kit.hint("tap to claim it", "click to claim it", "press to claim it")
				hints = { "Index reward: " .. claim, "Index reward waiting" }
			else
				local found = string.format("%d/%d", picked.have, picked.need)
				hints = { string.format("Index reward: %s %s found", found, W.Units), "Index reward: " .. found }
			end
		else
			-- Nothing is left to reach: the LEGEND plate and how complete the Index is.
			lead, title, count = "", TUNE.LegendWords, topCount
			local all = string.format("All %d %s found!", Economy.MAX_TIER, W.Units)
			hints = { all .. " The gym is yours", all, "" }
		end
		-- A nearer goal takes the second line (READY keeps its own words and its own tap), in
		-- fewer words when the plate is short of room. An unclaimed Index milestone is one too,
		-- and comes before the others.
		local near: Near? = nearShown
		if ready then
			near = nil
		elseif picked.kind == "index" then
			near = { kind = "index", text = hints[1], short = hints[2], icon = "Index", color = C.Gold }
		end
		if near then
			hints = { near.text, near.short }
		end
		local hint = hints[1]
		local key = table.concat({ lead, title, count, tostring(compact), table.unpack(hints) }, "|")
		Kit.tween(goalBar, 0.3, { Size = UDim2.fromScale(if ready then 1 else picked.progress, 1) })
		goalTrack.Visible = picked.kind ~= "done"
		if champ then
			-- The champion's plate has no bar at all: a milestone waiting is no progress to fill.
			goalTrack.Visible = false
		end
		if key == goalKey then
			return
		end
		goalKey = key
		-- The strip hugs the wider line up to TUNE.GoalMaxW. Nothing is ever cut off with an
		-- ellipsis: short of room the second line says less, then goes, which leaves the name
		-- both lines to wrap onto, and only then is the name scaled down (to the caption floor
		-- at the least).
		goalLead.Text = lead
		local room = TUNE.GoalMaxW - GOAL_TEXT_X - 12
		-- Text held at its size on a phone (applyCompact) is taller than the design's two
		-- lines: they, and the strip, grow with it.
		local lineH = math.max(20, goalTitle.TextSize + 2)
		local hintH = math.max(16, goalHint.TextSize + 1)
		-- The nearer goal's icon stands in front of its words, as tall as their line.
		local nearX = if near then hintH + NEAR_GAP else 0
		local hintRoom = room - nearX
		local leadW = drawnWidth(goalLead.Text, goalLead.TextSize, goalLead.Font)
		local countW = if count ~= "" then drawnWidth(count, goalCount.TextSize, goalCount.Font) else 0
		local titleRoom = room - leadW - countW - 14
		local titleNeed = drawnWidth(title, goalTitle.TextSize, goalTitle.Font)
		local hintNeed = drawnWidth(hint, goalHint.TextSize, goalHint.Font)
		for i = 2, #hints do
			if hintNeed <= hintRoom or hints[i] == "" then
				break
			end
			hint = hints[i]
			hintNeed = drawnWidth(hint, goalHint.TextSize, goalHint.Font)
		end
		local tight = titleNeed > titleRoom
		-- Above the dumbbell (compact) the strip may grow a line instead: a name that needs
		-- two lines keeps the estimate under it, which is what the strip is for.
		local tall = tight and compact and hint ~= "" and hintNeed <= hintRoom
		local dropHint = (tight and not tall) or hintNeed > hintRoom or hint == ""
		local titleW = math.min(titleNeed, titleRoom)
		local hintW = if dropHint then 0 else nearX + hintNeed
		local x = GOAL_TEXT_X
		local rowH = if tall then lineH * 2 elseif dropHint then lineH + hintH else lineH
		-- Scaled only when it has to shrink: text that fits keeps its exact size. The cap is
		-- the size it would have had (a text size constraint counts screen pixels).
		goalTitle.TextScaled = tight
		goalTitle.TextWrapped = tight
		local cap = if tight then math.ceil(goalTitle.TextSize * math.max(if screenScale then screenScale.Scale else 1, 1)) else 200
		goalTitleFit.MinTextSize = 1
		goalTitleFit.MaxTextSize = cap
		goalTitleFit.MinTextSize = if tight then math.min(Kit.captionPx(), cap) else 1
		local function put(label: TextLabel, text: string, width: number, gap: number)
			label.Text = text
			label.Size = UDim2.fromOffset(width + 4, rowH)
			label.Position = UDim2.fromOffset(x, 2)
			x += width + gap
		end
		put(goalLead, goalLead.Text, leadW, if lead ~= "" then 6 else 0)
		put(goalTitle, title, titleW, 8)
		put(goalCount, count, countW, 0)
		-- (2 px under the first line: the plate is that much taller than its two lines.)
		local hintY = (if tall then lineH * 2 else lineH) + 2
		goalHint.Text = string.upper(string.sub(hint, 1, 1)) .. string.sub(hint, 2)
		goalHint.TextColor3 = if near then C.Text else C.TextDim
		goalHint.Position = UDim2.fromOffset(GOAL_TEXT_X + nearX, hintY)
		goalHint.Size = UDim2.fromOffset(hintNeed + 4, hintH)
		goalHint.Visible = not dropHint
		-- The nearer goal as drawn: the strip's tap goes by it, so one that found no room
		-- (a long name took both lines) is not acted on unseen.
		goalNear = if dropHint then nil else near
		goalNearIcon.Visible = goalNear ~= nil
		if near and goalNear then
			goalNearIcon.Position = UDim2.fromOffset(GOAL_TEXT_X, hintY)
			goalNearIcon.Size = UDim2.fromOffset(hintH, hintH)
			if goalNearIcon:GetAttribute("Kind") ~= near.kind then
				goalNearIcon:SetAttribute("Kind", near.kind)
				local old = goalNearIcon:FindFirstChild("Image")
				if old then
					old:Destroy()
				end
				local image = Kit.hudIcon(goalNearIcon, near.icon, hintH, near.color, { Name = "Image", ZIndex = 2 })
				image.Size = UDim2.fromScale(1, 1)
				if near.kind == "index" then
					-- The Index button's badge in small: a red dot on the icon's corner.
					local dot = Kit.new("Frame", {
						Name = "Dot",
						BackgroundColor3 = C.Danger,
						BorderSizePixel = 0,
						Size = UDim2.fromOffset(TUNE.IndexDot, TUNE.IndexDot),
						Position = UDim2.new(1, -1, 0, 2),
						AnchorPoint = Vector2.new(0.5, 0.5),
						ZIndex = 4,
						Parent = image,
					})
					Kit.round(dot)
					Kit.new("UIStroke", { Thickness = 1.5, Color = Color3.new(1, 1, 1), Parent = dot })
				end
				Kit.pop(goalNearIcon, 0.8)
			end
		end
		goalWidth = math.max(x, GOAL_TEXT_X + hintW) + 12
		goal.Size = UDim2.fromOffset(goalWidth, TUNE.GoalH + (lineH - 20) + (hintH - 16) + (if tall then lineH else 0))
		-- A new target (not just a new count) gets a fresh thumbnail and a pop.
		local legend = picked.kind == "done"
		local thumbKey = if legend then "legend" elseif champ then "champ" else picked.kind .. picked.tier
		if thumbKey ~= goalThumbKey then
			goalThumbKey = thumbKey
			for _, child in goalThumb:GetChildren() do
				child:Destroy()
			end
			if champ then
				-- The champion's crown, rocking on a dark medallion so it reads on the gold.
				local medal = Kit.new("Frame", {
					Name = "Medal",
					BackgroundColor3 = TUNE.PlateColor,
					BorderSizePixel = 0,
					Size = UDim2.fromScale(1, 1),
					Parent = goalThumb,
				})
				Kit.round(medal)
				Kit.new("UIStroke", { Thickness = 2, Color = TUNE.ChampEdge, Parent = medal })
				if legend then
					-- Crown-lit: a gold halo round the medallion, beating.
					local halo = Kit.new("Frame", {
						Name = "Halo",
						BackgroundTransparency = 1,
						Size = UDim2.new(1, TUNE.LegendHalo * 2, 1, TUNE.LegendHalo * 2),
						Position = UDim2.fromScale(0.5, 0.5),
						AnchorPoint = Vector2.new(0.5, 0.5),
						ZIndex = 1,
						Parent = medal,
					})
					Kit.round(halo)
					local ring = Kit.new("UIStroke", { Thickness = TUNE.LegendHaloWidth[1], Color = C.GoldLight, Parent = halo })
					pulse(ring, TUNE.ChampCrownBeat, { Thickness = TUNE.LegendHaloWidth[2] })
				end
				-- The crown is bigger than its medallion and stands out of it: it rocks, and bobs
				-- on a holder of its own (two tweens, two objects).
				local bob = group("Bob", {
					Size = UDim2.fromOffset(TUNE.ChampCrown, TUNE.ChampCrown),
					Position = UDim2.fromScale(0.5, 0.45),
					AnchorPoint = Vector2.new(0.5, 0.5),
					ZIndex = 3,
					Parent = medal,
				})
				local crown = Kit.hudIcon(bob, Kit.pickIcon("Crown", "Star"), TUNE.ChampCrown, C.Gold, {
					Name = "Crown",
					Position = UDim2.fromScale(0.5, 0.5),
					AnchorPoint = Vector2.new(0.5, 0.5),
					ZIndex = 3,
				})
				crown.Rotation = -TUNE.ChampCrownTilt
				pulse(crown, TUNE.ChampCrownBeat, { Rotation = TUNE.ChampCrownTilt })
				pulse(bob, TUNE.ChampCrownBobBeat, { Position = bob.Position - UDim2.fromOffset(0, TUNE.ChampCrownBob) })
			else
				-- A silhouette until the tier is discovered.
				pcall(Kit.unitViewport, goalThumb, picked.tier, { Size = UDim2.fromScale(1, 1) }, true)
			end
		end
		if title ~= goalTitleShown then
			goalTitleShown = title
			-- (Not while it breathes: both move the strip's scale.)
			if not ready then
				Kit.pop(goal, 0.6)
			end
		end
	end

	-- The nearer goal: the strip's second line (paintGoal) ----------------------------------
	-- While the next tier is a long way off there is nearly always something closer worth
	-- doing. One at a time, by priority: the blender is full and a faster one is affordable;
	-- a crate has finished in the Smasher; a pad worth buying is affordable (Shared.BuyNext,
	-- once per pad a session, for AFFORD_SECONDS at most); a Game Mode pays out and nothing
	-- is affordable (or the tier is far); last, the blender is full and the upgrade is still
	-- out of reach. It
	-- takes the place of the estimate and never a row of its own: the top stack ends with
	-- the strip, so the plot's labels behind it stay readable. A tap on the strip does it
	-- (opens Modes) or draws the path to the pad; Client.Guide keeps a chevron over a pad it
	-- names. The free gift is not one of them: its own button in the corner pulses "CLAIM!"
	-- (paintFree).
	local nearSnooze: { [string]: number } = {}
	-- The "afford" pick: the pads it has had its say on, and the one it names since when.
	local afford = { said = {} :: { [string]: boolean }, pad = nil :: string?, since = 0 }
	local brokeSince: number? = nil
	local goalShown = false
	local function pickNear(data: { [string]: any }): Near?
		local now = os.clock()
		local function awake(kind: string): boolean
			return now >= (nearSnooze[kind] or 0)
		end
		local money = tonumber(data.money) or 0
		local rate = tonumber(data.processRate) or 0
		local production = tonumber(data.production) or 0
		-- W2 snapshots send both; older ones are worked out from the queue and the rates.
		local queueSeconds = tonumber(data.queueSeconds) or (if rate > 0 then (tonumber(data.queue) or 0) / rate else 0)
		local gain = tonumber(data.upgradeGain)
			or (math.min(production, rate * Economy.PROCESS_GROWTH) - math.min(production, rate))
				* Economy.CASH_PER_POINT
				* (tonumber(data.moneyMult) or 1)
		local upgradeCost = Economy.processUpgradeCost(tonumber(data.processLevel) or 0)
		local full = queueSeconds > BLENDER_FULL_SECONDS and gain > 0
		-- Broke: not one unit and no useful blender level can be paid for.
		if money >= Economy.unitPrice(tonumber(data.bought) or 0) or (gain > 0 and money >= upgradeCost) then
			brokeSince = nil
		else
			brokeSince = brokeSince or now
		end
		-- Modes are new (the tutorial was just finished): said here, behind the Modes icon, while
		-- the Modes button wears its ring and arrow (menu.wants.ModesNew).
		if menu.wants.ModesNew and now < menu.modesNewUntil then
			local verb = if Kit.touch then "Tap" else "Open"
			return {
				kind = "modesNew",
				text = "New! " .. verb .. " MODES: Parkour + Mog Test",
				short = "New! " .. verb .. " MODES",
				icon = Kit.pickIcon("Modes", "Star"),
				color = C.Gold,
			}
		end
		if full and money >= upgradeCost and awake("blender") then
			return {
				kind = "blender",
				text = "Blender is full: upgrade its speed",
				short = "Upgrade the blender",
				icon = "Orb",
				color = C.Orb,
				pad = "ProcUp1",
				tag = "UPGRADE",
			}
		end
		if type(data.unlockers) == "table" and awake("crate") then
			for i, slot in data.unlockers do
				if
					type(slot) == "table"
					and type(slot.rarity) == "string"
					and slot.rarity ~= ""
					and (tonumber(slot.secondsLeft) or 0) - State.age() <= 0
				then
					return {
						kind = "crate",
						text = W.Chest .. " ready at the Smasher",
						short = W.Chest .. " ready",
						icon = Kit.pickIcon("Crate" .. slot.rarity, "Gift2"),
						color = C.Gold,
						pad = "Unlock" .. i,
						tag = "OPEN!",
					}
				end
			end
		end
		-- A pad worth buying is affordable: said once per pad, and only for so long.
		local best = if awake("afford") then BuyNext.best(data) else nil
		if best ~= afford.pad then
			if afford.pad then
				afford.said[afford.pad] = true
			end
			afford.pad, afford.since = best, now
		end
		if best and not afford.said[best] then
			if now - afford.since <= AFFORD_SECONDS then
				local what = BuyNext.title(best, data)
				local buy = string.sub(best, 1, 3) == "Buy"
				return {
					kind = "afford",
					text = "You can afford " .. what .. "! SHOW ME",
					short = (if buy then what else "Faster Blender") .. "! SHOW ME",
					icon = if buy then "Coin" else "Orb",
					color = C.Cash,
					pad = best,
					tag = "BUY!",
				}
			end
			afford.said[best] = true
		end
		local pays = 0
		if type(data.modes) == "table" then
			for _, info in data.modes do
				local preview = if type(info) == "table" then info.rewardPreview else nil
				if type(preview) == "table" and info.running ~= true then
					pays = math.max(pays, tonumber(preview.cash) or 0)
				end
			end
		end
		if pays > 0 and (goalFar or (brokeSince ~= nil and now - brokeSince >= BROKE_SECONDS)) and awake("mode") then
			return {
				kind = "mode",
				text = "Try a Game Mode: +" .. State.money(pays),
				short = "Try a Game Mode",
				icon = Kit.pickIcon("Modes", "Star"),
				color = C.Gold,
			}
		end
		if full and awake("save") then
			return {
				kind = "save",
				text = string.format("Blender is full: save %s for more speed", State.money(upgradeCost)),
				short = "Blender is full",
				icon = "Orb",
				color = C.Orb,
			}
		end
		return nil
	end
	local function updateNear()
		local data = State.data
		local near = if goalShown and data and not goalReady then pickNear(data) else nil
		local last = nearShown
		nearShown = near
		-- The chevron on the plot: MOG MERGE while the goal is ready, else the nearer goal's pad.
		if goalShown and goalReady then
			Guide.setHint("Merge", W.Merge)
		elseif near and near.pad then
			Guide.setHint(near.pad, near.tag)
		else
			Guide.setHint(nil)
		end
		-- Other words: the strip lays its second line out again.
		if goalShown and data and (if near then near.text else "") ~= (if last then last.text else "") then
			paintGoal(data)
		end
	end
	for _, button in { goal, goalPad } do
		button.Activated:Connect(function()
			Kit.sound("Click")
			local near = goalNear
			if goalReady then
				Guide.navigate("Merge", W.Merge, 30)
			elseif near then
				if near.kind == "index" then
					openIndex()
				elseif near.kind == "mode" or near.kind == "modesNew" then
					if near.kind == "modesNew" then
						menu.modesSeen()
					end
					handlers.openWindow("Modes", { origin = goal })
				else
					Guide.navigate(near.pad or "ProcUp1", near.tag or "UPGRADE", 30)
				end
				-- Said and heard: the blender and crate ones stay (their chevron is the point),
				-- the others give way to the next one for a while.
				if near.kind == "mode" or near.kind == "save" or near.kind == "afford" then
					nearSnooze[near.kind] = os.clock() + NEAR_SNOOZE
				end
				if near.kind == "afford" and near.pad then
					afford.said[near.pad] = true
				end
				updateNear()
			else
				openIndex()
			end
		end)
	end
	-- The plate's texts are held at a readable size on a phone (applyCompact), where 18 and
	-- 17 design px are 11 px: a new size lays the plate out again.
	for label in GOAL_TEXT do
		label:GetPropertyChangedSignal("TextSize"):Connect(function()
			goalKey = ""
			if State.data then
				paintGoal(State.data)
			end
		end)
	end
	-- In a block: its locals stay out of build's 200 (see the note at the top of build).
	do
		-- Shown once the tutorial is done, outside the intro and game-mode runs. A tutorial
		-- finished this session first lets its quest pill slide out of the slot.
		local goalHoldUntil = 0
		local goalSawTutorial = false
		local function updateGoal()
			local data = State.data
			local player = Players.LocalPlayer
			local show = data ~= nil
				and data.tutorialDone == true
				and os.clock() >= goalHoldUntil
				and screen:GetAttribute("RunActive") ~= true
				and screen:GetAttribute("ObbyMode") ~= true
				and screen:GetAttribute("CardioActive") ~= true
				and not (player ~= nil and player:GetAttribute("IntroPlaying") == true)
			if show and data then
				paintGoal(data)
			end
			if show ~= goalShown then
				goalShown = show
				goal.Visible = show
			end
			updateNear()
		end
		State.changed.Event:Connect(function(data)
			if data.tutorialDone ~= true then
				goalSawTutorial = true
			elseif goalSawTutorial then
				goalSawTutorial = false
				goalHoldUntil = os.clock() + 1.5
				task.delay(1.6, updateGoal)
			end
			updateGoal()
		end)
		for _, name in { "RunActive", "ObbyMode", "CardioActive" } do
			screen:GetAttributeChangedSignal(name):Connect(updateGoal)
		end
		pcall(function()
			Players.LocalPlayer:GetAttributeChangedSignal("IntroPlaying"):Connect(updateGoal)
		end)
	end

	-- Bottom centre: the dumbbell with "AURA" and the carried amount ----------------------
	local Assets = (function(): any
		local shared = ReplicatedStorage:FindFirstChild("Shared")
		local module = shared and shared:FindFirstChild("Assets")
		if module and module:IsA("ModuleScript") then
			local ok, result = pcall(require, module)
			if ok and type(result) == "table" then
				return result
			end
		end
		return nil
	end)()
	local images = if Assets and type(Assets.Images) == "table" then Assets.Images else {}
	local plainId: string? = images["hud/Dumbbell"]
	local glowId: string? = images["hud/DumbbellGlow"]
	local tank = group("Dumbbell", {
		Size = UDim2.fromOffset(DUMBBELL_W, DUMBBELL_W * DUMBBELL_ASPECT),
		Position = UDim2.new(0.5, 0, 1, -6),
		AnchorPoint = Vector2.new(0.5, 1),
	})
	local tankScale = Kit.new("UIScale", { Parent = tank })
	local glowImage: ImageLabel? = nil
	-- Text rectangles in image pixels (art/out/ui/HudDumbbell.json, x y w h of 1024x448).
	local function rect(x: number, y: number, w: number, h: number): (UDim2, UDim2)
		return UDim2.fromScale(x / 1024, y / 448), UDim2.fromScale(w / 1024, h / 448)
	end
	local captionPos, captionSize = rect(310, 66, 404, 87)
	local numberPos, numberSize = rect(310, 156, 404, 160)
	if plainId then
		Kit.new("ImageLabel", {
			Name = "Art",
			BackgroundTransparency = 1,
			Image = plainId,
			ScaleType = Enum.ScaleType.Fit,
			Size = UDim2.fromScale(1, 1),
			ZIndex = 1,
			Parent = tank,
		})
		if glowId then
			glowImage = Kit.new("ImageLabel", {
				Name = "Glow",
				BackgroundTransparency = 1,
				Image = glowId,
				ImageTransparency = 1,
				ScaleType = Enum.ScaleType.Fit,
				Size = UDim2.fromScale(1, 1),
				ZIndex = 2,
				Parent = tank,
			})
		end
	else
		-- No art: a code-drawn pill in the plaque's place with the same two lines.
		captionPos, captionSize = UDim2.fromScale(0.25, 0.12), UDim2.fromScale(0.5, 0.22)
		numberPos, numberSize = UDim2.fromScale(0.25, 0.34), UDim2.fromScale(0.5, 0.42)
		local pill = Kit.new("Frame", {
			Name = "Plaque",
			BackgroundColor3 = C.Ink,
			BackgroundTransparency = 0.2,
			Size = UDim2.fromScale(0.56, 0.8),
			Position = UDim2.fromScale(0.22, 0.08),
			ZIndex = 1,
			Parent = tank,
		})
		Kit.corner(pill, 18)
	end
	-- Scaled to its line of the plaque, but never under a phone caption on the glass (the
	-- compact dumbbell's line is 17 design px tall: 11 px on a phone).
	local tankCaption = Kit.hudText(tank, {
		Name = "Caption",
		Text = string.upper(W.Orb),
		TextScaled = true,
		MaxTextSize = 200,
		MinPx = G.TextMinPhone,
		StrokeThickness = 2,
		TextColor3 = C.GoldLight,
		Size = captionSize,
		Position = captionPos,
		ZIndex = 4,
	})
	local carriedLabel = Kit.hudText(tank, {
		Name = "Carried",
		Text = "0",
		Font = F.Number,
		TextScaled = true,
		StrokeThickness = 2.5,
		Size = numberSize,
		Position = numberPos,
		ZIndex = 4,
	})
	tankCaption.TextSize = 20
	carriedLabel.TextSize = 36
	-- A bounce and a short cross-fade to the glow art; deposits bounce a little more.
	local glowToken = 0
	Hud.pulseTank = function(big: boolean?)
		tankScale.Scale = if big then 1.16 else 1.08
		Kit.tween(tankScale, if big then 0.45 else 0.3, { Scale = 1 }, Enum.EasingStyle.Back)
		local glow = glowImage
		if glow then
			glowToken += 1
			local token = glowToken
			Kit.tween(glow, 0.12, { ImageTransparency = 0 })
			task.delay(if big then 0.5 else 0.3, function()
				if token == glowToken then
					Kit.tween(glow, 0.35, { ImageTransparency = 1 })
				end
			end)
		end
	end

	-- Bottom left: bonus chips, cash multiplier line, cash amount + plus -------------------
	-- The cash amount is the anchor: the biggest text, at the corner, and it never moves. It
	-- and the "+" sit on the cash plate. A bonus that is off shows nothing; one that is on is
	-- a chip: a small plate with its icon and words, all chips one height and one text size
	-- (the SURGE chip's words are gold and a size bolder, inside a gold edge).
	local wallet = group("Wallet", {
		Size = UDim2.fromOffset(420, 168),
		Position = UDim2.new(0, EDGE_X, 1, -6),
		AnchorPoint = Vector2.new(0, 1),
	})
	local chips = group("Status", {
		Size = UDim2.fromOffset(400, TUNE.ChipH),
		Position = UDim2.fromOffset(0, 62 - TUNE.ChipH - TUNE.ChipLift),
		Parent = wallet,
	})
	Kit.new("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal,
		VerticalAlignment = Enum.VerticalAlignment.Center,
		Padding = UDim.new(0, TUNE.ChipGap),
		SortOrder = Enum.SortOrder.LayoutOrder,
		Parent = chips,
	})
	-- Each chip's words and their design size (held on a phone, applyCompact).
	local chipTexts: { [TextLabel]: number } = {}
	local function status(
		name: string,
		icon: string,
		color: Color3,
		order: number,
		text: string,
		textColor: Color3?,
		fill: Color3?,
		size: number?
	): (GuiObject, TextLabel)
		local holder = plate(chips, {
			Name = name,
			Color = fill,
			Radius = TUNE.ChipRadius,
			Size = UDim2.fromOffset(0, TUNE.ChipH),
			LayoutOrder = order,
			Visible = false,
		})
		holder.AutomaticSize = Enum.AutomaticSize.X
		Kit.padding(holder, 0, TUNE.ChipPad)
		Kit.new("UIListLayout", {
			FillDirection = Enum.FillDirection.Horizontal,
			VerticalAlignment = Enum.VerticalAlignment.Center,
			Padding = UDim.new(0, 5),
			SortOrder = Enum.SortOrder.LayoutOrder,
			Parent = holder,
		})
		Kit.hudIcon(holder, icon, TUNE.ChipIcon, color, { Name = "Icon", LayoutOrder = 1, ZIndex = 2 })
		local caption = Kit.hudText(holder, {
			Name = "Caption",
			Text = text,
			Font = F.UI,
			TextSize = size or TUNE.ChipText,
			MinPx = true,
			StrokeThickness = 2,
			TextColor3 = textColor,
			AutomaticSize = Enum.AutomaticSize.X,
			Size = UDim2.fromOffset(0, TUNE.ChipH),
			LayoutOrder = 2,
			ZIndex = 3,
		})
		chipTexts[caption] = size or TUNE.ChipText
		return holder, caption
	end
	local premiumRow = status("Premium", Kit.pickIcon("Crown", "Star"), C.Gold, 1, string.format("Premium +%d%%", PREMIUM_BONUS), C.Gold)
	local friendsRow, friendsText = status("Friends", Kit.pickIcon("Invite", "Fans"), C.Rizz, 2, "Friends")
	local boostRow = status("Boost", "Surge", C.Amber, 3, "SURGE x" .. Economy.SURGE_MULTIPLIER, C.Gold, nil, TUNE.SurgeChipText)
	-- In a block: its local stays out of build's 200.
	do
		local edge = edgeOf(boostRow)
		if edge then
			edge.Color = C.Gold
			edge.Thickness = TUNE.SurgeChipEdge
		end
	end
	-- A chip comes on with a pop and goes off without a trace.
	local function setStatus(row: GuiObject, on: boolean)
		if row.Visible == on then
			return
		end
		row.Visible = on
		if on then
			Kit.pop(row, 0.8)
		end
	end
	local multLine = Kit.hudText(wallet, {
		Name = "CashMult",
		Text = "",
		RichText = true,
		TextSize = 20,
		Size = UDim2.fromOffset(200, 22),
		Position = UDim2.fromOffset(0, 62),
		TextXAlignment = Enum.TextXAlignment.Left,
		ZIndex = 3,
	})
	-- The cash plate: behind the amount and the "+", as wide as they are (layoutWallet).
	local cashPlate = plate(wallet, {
		Name = "CashPlate",
		Size = UDim2.fromOffset(200, TUNE.CashPlateH),
		Position = UDim2.fromOffset(-8, 84),
	})
	local moneyLabel = Kit.hudText(wallet, {
		Name = "Money",
		Text = "$0",
		Font = F.Number,
		TextSize = TUNE.MoneyText,
		StrokeThickness = TUNE.MoneyStroke,
		StrokeColor = TUNE.MoneyStrokeColor,
		TextColor3 = TUNE.MoneyColor,
		AutomaticSize = Enum.AutomaticSize.X,
		-- Centred on the cash plate (y 84).
		Size = UDim2.fromOffset(0, TUNE.MoneyText + 4),
		Position = UDim2.fromOffset(0, 84 + (TUNE.CashPlateH - TUNE.MoneyText - 4) // 2),
		TextXAlignment = Enum.TextXAlignment.Left,
		ZIndex = 3,
	})
	local coin = moneyLabel -- coin bursts fly into the cash amount
	-- Income at a glance: "+$1.2K/s" under the cash plate (steady income, no surge in it), on
	-- its own navy chip behind a green up-arrow, so it never sits bare on the floor. The chip
	-- pops and its edge flashes green on each payout (cashGain). Not on touch, where the menu
	-- grid sits right under the top-left wallet.
	local incomeChip = plate(wallet, {
		Name = "IncomeChip",
		Radius = TUNE.ChipRadius,
		Size = UDim2.fromOffset(0, TUNE.IncomeChipH),
		Position = UDim2.fromOffset(-8, 84 + TUNE.CashPlateH + TUNE.IncomeGap),
		Visible = false,
	})
	incomeChip.AutomaticSize = Enum.AutomaticSize.X
	Kit.padding(incomeChip, 0, TUNE.ChipPad)
	Kit.new("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal,
		VerticalAlignment = Enum.VerticalAlignment.Center,
		Padding = UDim.new(0, 6),
		SortOrder = Enum.SortOrder.LayoutOrder,
		Parent = incomeChip,
	})
	-- In a block: its locals stay out of build's 200.
	do
		-- The green up-arrow: a stem under a turned square's upper point, ink-edged.
		local arrowW = TUNE.IncomeArrow
		local arrow = Kit.new("Frame", {
			Name = "Up",
			BackgroundTransparency = 1,
			Size = UDim2.fromOffset(arrowW, arrowW + 2),
			LayoutOrder = 1,
			ZIndex = 3,
			Parent = incomeChip,
		})
		local side = math.floor(arrowW / math.sqrt(2) + 0.5)
		local head = Kit.new("Frame", {
			Name = "Head",
			BackgroundColor3 = TUNE.IncomeArrowColor,
			BorderSizePixel = 0,
			Size = UDim2.fromOffset(side, side),
			Position = UDim2.new(0.5, 0, 0, arrowW / 2),
			AnchorPoint = Vector2.new(0.5, 0.5),
			Rotation = 45,
			ZIndex = 4,
			Parent = arrow,
		})
		Kit.corner(head, 2)
		Kit.new("UIStroke", { Thickness = 2, Color = G.TextInk, Parent = head })
		local stem = Kit.new("Frame", {
			Name = "Stem",
			BackgroundColor3 = TUNE.IncomeArrowColor,
			BorderSizePixel = 0,
			Size = UDim2.fromOffset(math.max(4, arrowW // 3), arrowW // 2 + 2),
			Position = UDim2.new(0.5, 0, 1, 0),
			AnchorPoint = Vector2.new(0.5, 1),
			ZIndex = 5,
			Parent = arrow,
		})
		Kit.corner(stem, 2)
		Kit.new("UIStroke", { Thickness = 2, Color = G.TextInk, Parent = stem })
	end
	local incomeLine = Kit.hudText(incomeChip, {
		Name = "Income",
		Text = "",
		Font = F.Number,
		TextSize = TUNE.IncomeText,
		StrokeThickness = 2.5,
		TextColor3 = TUNE.IncomeColor,
		AutomaticSize = Enum.AutomaticSize.X,
		Size = UDim2.fromOffset(0, TUNE.IncomeChipH),
		TextXAlignment = Enum.TextXAlignment.Left,
		LayoutOrder = 2,
		ZIndex = 4,
	})
	local addButton = Kit.button(wallet, {
		Name = "Add",
		Icon = "Plus",
		IconColor = Color3.new(1, 1, 1),
		Color = C.Cash,
		Size = UDim2.fromOffset(44, 44),
		Radius = 10,
		Depth = 3,
		ZIndex = 3,
	}, function()
		handlers.openWindow("Shop", { focus = "Cash" })
	end)
	hitPad(addButton, function()
		handlers.openWindow("Shop", { focus = "Cash" })
	end)
	-- The plus follows the cash amount's width and the plate holds both (the amount alone
	-- during a run, which hides the plus). The chips sit over the "Cash" line, or beside it
	-- where the wallet is in the top-left corner (touch: nothing above it then).
	local function layoutWallet()
		local x = math.max(textWidth(moneyLabel.Text, moneyLabel.TextSize, moneyLabel.Font) + 4, 60)
		addButton.Position = UDim2.fromOffset(x + 10, 92)
		cashPlate.Size = UDim2.fromOffset(8 + x + (if addButton.Visible then 10 + 44 + 10 else 10), TUNE.CashPlateH)
		chips.Position = if Kit.touch
			then UDim2.fromOffset(drawnWidth(multLine.Text, multLine.TextSize, multLine.Font) + 14, 73 - TUNE.ChipH // 2)
			else UDim2.fromOffset(0, 62 - TUNE.ChipH - TUNE.ChipLift)
	end
	moneyLabel:GetPropertyChangedSignal("Text"):Connect(layoutWallet)
	-- Income (`cashGain`, from refresh): the cash plate flashes green and a "+$X" floats up
	-- beside it, at most once in GainEvery seconds (gains in between add up). An Aura Surge
	-- (`surgeWallet`): the plate's edge turns gold and pulses, and the SURGE chip comes on
	-- and breathes (not on touch, where the chips share the top of the screen with the status
	-- plate that says the same).
	local cashGain: (number) -> ()
	local surgeWallet: (boolean) -> ()
	-- In a block: its locals stay out of build's 200 (see the note at the top of build).
	do
		local owed, lastAt = 0, 0
		cashGain = function(gain: number)
			if screen:GetAttribute("WindowOpen") == true then
				owed = 0
				return
			end
			owed += gain
			local now = os.clock()
			if now - lastAt < TUNE.GainEvery then
				return
			end
			lastAt = now
			-- (The edge is the surge's while one runs: its pulse is not to be cut short.)
			flash(cashPlate, TUNE.CashFlash, TUNE.PlateColor, TUNE.CashFlashTime, if surgeActiveNow then nil else C.Cash, nil, 4)
			-- The income chip beats with the payout: a pop and a green flash of its plate and edge.
			if incomeChip.Visible then
				Kit.pop(incomeChip, TUNE.IncomePop)
				flash(incomeChip, TUNE.IncomeFlash, TUNE.PlateColor, TUNE.CashFlashTime, C.Cash, nil, TUNE.IncomeFlashEdge)
			end
			local float = Kit.hudText(wallet, {
				Name = "Gain",
				Text = "+" .. State.money(owed),
				Font = F.Number,
				TextSize = TUNE.GainText,
				TextColor3 = C.MoneyText,
				StrokeThickness = 2.5,
				TextXAlignment = Enum.TextXAlignment.Left,
				Size = UDim2.fromOffset(220, TUNE.GainText + 4),
				Position = UDim2.fromOffset(cashPlate.Size.X.Offset, 100),
				ZIndex = 6,
			})
			owed = 0
			Kit.pop(float, 1.5)
			Kit.tween(float, TUNE.GainTime, { Position = float.Position - UDim2.fromOffset(0, TUNE.GainRise) })
			local outline = float:FindFirstChild("Outline")
			task.delay(TUNE.GainTime * 0.6, function()
				Kit.tween(float, TUNE.GainTime * 0.4, { TextTransparency = 1 })
				if outline then
					Kit.tween(outline, TUNE.GainTime * 0.4, { Transparency = 1 })
				end
			end)
			task.delay(TUNE.GainTime + 0.05, function()
				float:Destroy()
			end)
		end
		local stopChip: (() -> ())? = nil
		local beat: Tween? = nil
		surgeWallet = function(active: boolean)
			setStatus(boostRow, active and not Kit.touch)
			if stopChip then
				stopChip()
				stopChip = nil
			end
			if beat then
				beat:Cancel()
				beat = nil
			end
			local edge = edgeOf(cashPlate)
			if edge then
				edge.Thickness = TUNE.PlateEdgeWidth
				Kit.tween(edge, 0.3, { Color = if active then C.Gold else TUNE.PlateEdge })
				if active then
					beat = pulse(edge, TUNE.SurgeEdgeBeat, { Thickness = TUNE.SurgeEdgeWidth })
				end
			end
			if active then
				-- After the chip's own pop (both move its scale).
				task.delay(0.45, function()
					if surgeActiveNow and not stopChip then
						stopChip = Kit.breathe(boostRow, TUNE.SurgeChipBreathe)
					end
				end)
			end
		end
	end

	-- A game-mode run (attribute "RunActive": the run pill's modes and Mog) owns the screen:
	-- the menu grid, the promo (updatePromo), the dumbbell and the wallet's rows above the
	-- cash amount step out, the cash amount stays. Cardio hides the HUD's blocks itself and
	-- puts each back as it found it (CardioHud CLUTTER), so nothing is touched during its
	-- runs; the look comes a frame late so it always lands after Cardio's own.
	local runHid = false
	local function applyRun()
		if screen:GetAttribute("CardioActive") == true then
			return
		end
		local run = screen:GetAttribute("RunActive") == true
		if run == runHid then
			return
		end
		runHid = run
		grid.Visible = not run
		tank.Visible = not run
		multLine.Visible = not run
		addButton.Visible = not run
		chips.Visible = not run and not (Kit.touch and compact)
		layoutWallet()
	end
	for _, name in { "RunActive", "CardioActive" } do
		screen:GetAttributeChangedSignal(name):Connect(function()
			task.defer(applyRun)
		end)
	end

	-- Layout mode ------------------------------------------------------------------------
	-- Compact screens: smaller grid icons, no promo, a smaller dumbbell. Touch (live,
	-- Kit.onInput): the wallet moves to the top left with the grid under it (one row
	-- when compact) so the thumbstick's bottom-left third stays clear, the bonus chips
	-- move beside the "Cash" line, the FREE gift rises above the jump button, the gear
	-- leaves the top bar,
	-- and every button is >= TAP_PX on screen. Gamepad / TV: title-safe edges. While a
	-- window is open the grid slides off the left edge, the bottom groups below the
	-- bottom edge and the top groups up, and all glide back.
	local gridIcon = GRID_ICON
	local cellH = GRID_ICON + CAPTION + GRID_PAD * 2
	local oneRow = false
	-- In a block: its locals stay out of build's 200 (see the note at the top of build).
	do
		local function gridRows(): { { string } }
			if oneRow then
				return { { "Home", "Ranking", "Modes", "Index", "Shop", "Invite", "Daily" } }
			end
			return GRID_ROWS
		end
		local function gridHeight(): number
			local rows = #gridRows()
			return rows * cellH + (rows - 1) * GRID_GAP
		end
		-- Viewport (screen px) and the UI scale Main applied.
		local function view(): (Vector2, number)
			local scale = if screenScale then screenScale.Scale else 1
			local ok, size = pcall(function()
				return Workspace.CurrentCamera.ViewportSize
			end)
			if not ok or typeof(size) ~= "Vector2" or size.X <= 0 then
				size = Vector2.new(1280, 720)
			end
			return size, math.max(scale, 0.01)
		end
		local function measure()
			local size, scale = view()
			local touch = Kit.touch
			local pad = Kit.gamepad or Kit.tenFoot
			L.edge = if pad then SAFE_X else EDGE_X
			L.bottom = if pad then -SAFE_BOTTOM else -6
			L.tap = if touch then math.ceil(TAP_PX / scale) else 0
			L.walletTop = touch
			oneRow = touch and compact
			-- The plate is the tap target, so the icon keeps its size on touch; the plate holds
			-- the icon and the caption at its held size (applyCompact holds it first).
			gridIcon = if compact then GRID_ICON_COMPACT else GRID_ICON
			cellH = math.max(GRID_PAD + gridIcon + captions[1].TextSize + 4 + 3, L.tap)
			-- Top-left wallet: nothing sits over the "Cash" line there (the chips move beside
			-- it), so the 62 px above it are dropped.
			local skip = if touch then 62 else 0
			L.walletY = 168 - skip
			L.gridY = if touch then 138 - skip + 12 else GRID_Y
			-- Thumbstick zone: left third, lower half of the screen (design px below the top bar).
			local designW = size.X / scale
			local halfY = (size.Y / 2 - TOP_BAR_PX) / scale
			promoFits = not touch or L.gridY + gridHeight() + PROMO_GAP + TUNE.PromoH + 16 <= halfY
			local tankW = if compact then DUMBBELL_W_COMPACT else DUMBBELL_W
			L.tankX = if touch then math.max(0, designW / 3 + 8 - (designW - tankW) / 2) else 0
			-- Jump button: 70 px at 20 px from the corner on small screens, 120 px 90 px up otherwise.
			local jumpTop = if math.min(size.X, size.Y) <= 500 then 90 else 210
			L.freeY = if touch then -math.ceil((jumpTop + 8) / scale) elseif pad then -SAFE_BOTTOM else -20
		end

		local slots: { { gui: GuiObject, rest: () -> UDim2, away: () -> UDim2 } } = {}
		local function slot(gui: GuiObject, rest: () -> UDim2, away: () -> UDim2)
			table.insert(slots, { gui = gui, rest = rest, away = away })
		end
		slot(grid, function()
			return UDim2.fromOffset(L.edge, L.gridY)
		end, function()
			return UDim2.fromOffset(-600, L.gridY)
		end)
		slot(promo, function()
			return UDim2.fromOffset(L.edge, L.gridY + gridHeight() + PROMO_GAP)
		end, function()
			return UDim2.fromOffset(-TUNE.PromoW - 60, L.gridY + gridHeight() + PROMO_GAP)
		end)
		slot(wallet, function()
			return if L.walletTop then UDim2.new(0, L.edge, 0, L.walletY) else UDim2.new(0, L.edge, 1, L.bottom)
		end, function()
			return if L.walletTop then UDim2.new(0, L.edge, 0, -60) else UDim2.new(0, L.edge, 1, 200)
		end)
		slot(tank, function()
			return UDim2.new(0.5, L.tankX, 1, L.bottom)
		end, function()
			return UDim2.new(0.5, L.tankX, 1, 160)
		end)
		slot(corner, function()
			return UDim2.new(1, -L.edge, 1, L.freeY)
		end, function()
			return UDim2.new(1, 120, 1, L.freeY)
		end)
		-- Row 1 of the top stack: the count plate and the status plate side by side, centred
		-- as a pair. On touch the wallet has the top left (its chips reach toward the centre),
		-- so the plates stack in one column there: count, status, goal.
		local function measureTop()
			local gap = Kit.pxUp(TUNE.StackGap, TUNE.StackGap, screen)
			local countW, stripW = units.Size.X.Offset, strip.Size.X.Offset
			if Kit.touch then
				L.countX, L.stripX = 0, 0
				L.stripY = TUNE.TopY + TUNE.RowH + gap
				L.goalY = L.stripY + TUNE.RowH + gap
			else
				local total = countW + TUNE.RowGap + stripW
				L.countX, L.stripX = math.floor((countW - total) / 2 + 0.5), math.floor((total - stripW) / 2 + 0.5)
				L.stripY = TUNE.TopY
				L.goalY = TUNE.TopY + TUNE.RowH + gap
			end
		end
		slot(units, function()
			return UDim2.new(0.5, L.countX, 0, TUNE.TopY)
		end, function()
			return UDim2.new(0.5, L.countX, 0, -140)
		end)
		slot(strip, function()
			return UDim2.new(0.5, L.stripX, 0, L.stripY)
		end, function()
			return UDim2.new(0.5, L.stripX, 0, -140)
		end)
		-- The goal plate: its slot under row 1, or just above the (compact) dumbbell.
		slot(goal, function()
			if compact then
				return UDim2.new(0.5, L.tankX, 1, L.bottom - math.ceil(DUMBBELL_W_COMPACT * DUMBBELL_ASPECT) - 8)
			end
			return UDim2.new(0.5, 0, 0, L.goalY)
		end, function()
			return if compact then UDim2.new(0.5, L.tankX, 1, 200) else UDim2.new(0.5, 0, 0, -140)
		end)
		local targets: { [GuiObject]: UDim2 } = {}
		-- Groups that have faded out for an open window sit at their away spot.
		local parked: { [GuiObject]: boolean } = {}
		local function place(animate: boolean)
			-- The crate panel (Popups, attribute "CratePanelOpen") covers the right edge
			-- down to the FREE gift, so the gift steps aside while it is up.
			local crate = screen:GetAttribute("CratePanelOpen") == true
			for _, s in slots do
				local pos = if parked[s.gui] or (crate and s.gui == corner) then s.away() else s.rest()
				if targets[s.gui] ~= pos then
					targets[s.gui] = pos
					if animate then
						Kit.tween(s.gui, 0.3, { Position = pos }, Enum.EasingStyle.Quad)
					else
						s.gui.Position = pos
					end
				end
			end
		end
		-- A plate of the top stack changed its width: the pair is centred again.
		L.layoutTop = function(animate: boolean)
			measureTop()
			-- (Nothing glides before the first layout has put everything in its place.)
			place(animate and next(targets) ~= nil)
		end
		local function applyCompact()
			compact = screen:GetAttribute("Compact") == true
			for _, caption in captions do
				-- The size is in design px: a small screen's UI scale would shrink it under the
				-- caption floor, so the size is held on the glass.
				Kit.holdText(caption, Kit.captionPx(), CAPTION)
			end
			measure()
			-- Every plate is as wide as the widest caption as drawn (the Daily countdown
			-- counts), so no caption can reach its neighbour. A phone's single row is the one
			-- exception: there each plate hugs its own caption, or the row would run under the
			-- top centre.
			local textSize = captions[1].TextSize
			local captionH = textSize + 4
			local function captionWidth(name: string): number
				local width = drawnWidth(CAPTIONS[name], textSize, F.Display)
				return if name == "Daily" then math.max(width, drawnWidth("00:00:00", textSize, F.Display)) else width
			end
			local widest = 0
			for name in CAPTIONS do
				widest = math.max(widest, captionWidth(name))
			end
			local gridW = 0
			for row, names in gridRows() do
				local x = 0
				for _, name in names do
					local button = Hud.buttons[name]
					local cellW = math.max((if oneRow then captionWidth(name) else widest) + GRID_PAD * 2, gridIcon + GRID_PAD * 2, L.tap)
					button.Size = UDim2.fromOffset(cellW, cellH)
					button.Position = UDim2.fromOffset(x, (row - 1) * (cellH + GRID_GAP))
					gridIcons[name].Size = UDim2.fromOffset(gridIcon, gridIcon)
					x += cellW + GRID_GAP
				end
				gridW = math.max(gridW, x - GRID_GAP)
			end
			grid.Size = UDim2.fromOffset(gridW, gridHeight())
			for _, caption in captions do
				caption.Size = UDim2.new(1, 0, 0, captionH)
			end
			-- The status plate's three texts are held the same way (a hard floor: 18, 22 and 17
			-- design px are 11 to 14 px on a phone), and the plate widens round them; so does
			-- the count plate round its pill.
			for label, design in STRIP_TEXT do
				Kit.holdText(label, Kit.captionPx(), design, true)
			end
			fitStrip()
			fitCount()
			-- So are the goal strip's (it lays itself out again when a size changes).
			for label, design in GOAL_TEXT do
				Kit.holdText(label, Kit.captionPx(), design, true)
			end
			-- The bonus chips keep their words at a readable size; a touch phone, where the
			-- wallet shares the top-left corner with the menu row, goes without them.
			for label, design in chipTexts do
				Kit.holdText(label, Kit.captionPx(), design)
			end
			chips.Visible = not runHid and not (Kit.touch and compact)
			setStatus(boostRow, surgeActiveNow and not Kit.touch)
			layoutWallet()
			local width = if compact then DUMBBELL_W_COMPACT else DUMBBELL_W
			tank.Size = UDim2.fromOffset(width, width * DUMBBELL_ASPECT)
			-- The caption's line of the compact plaque is shorter than the caption held at its
			-- phone size (MinPx): its box grows round the line to hold it.
			local captionRoom =
				math.max(0, math.ceil(Kit.pxUp(G.TextMinPhone, 0, tankCaption) - width * DUMBBELL_ASPECT * captionSize.Y.Scale))
			tankCaption.Size = captionSize + UDim2.fromOffset(0, captionRoom)
			tankCaption.Position = captionPos - UDim2.fromOffset(0, captionRoom // 2)
			goal.AnchorPoint = Vector2.new(0.5, if compact then 1 else 0)
			goalPad.Size = UDim2.new(1, 0, 0, math.max(TUNE.GoalH, L.tap))
			goalPad.Visible = Kit.touch
			-- Gear: on the top bar's line with a mouse; below it (never on Roblox's bar) otherwise.
			local gearSize = math.max(GEAR, L.tap)
			gear.Size = UDim2.fromOffset(gearSize, gearSize)
			gear.Position = if Kit.input == "keyboard" and not Kit.tenFoot
				then UDim2.new(1, -10, 0, -GEAR - 7)
				else UDim2.new(1, -L.edge, 0, 4)
			-- FREE gift grows to a full touch target; the countdown follows it.
			local freeSize = math.max(60, L.tap)
			freeButton.Size = UDim2.fromOffset(freeSize, freeSize)
			corner.Size = UDim2.fromOffset(math.max(84, freeSize + 16), freeSize + 32)
			freeTimer.Position = UDim2.new(0.5, 0, 0, freeSize + 2)
			for _, p in pads do
				local w, h = p.button.Size.X.Offset, p.button.Size.Y.Offset
				p.pad.Size = UDim2.fromOffset(math.max(w, L.tap), math.max(h, L.tap))
				p.pad.Visible = Kit.touch and (w < L.tap or h < L.tap)
			end
			updatePromo()
			measureTop()
			place(next(targets) ~= nil)
		end
		-- Gamepad: HUD buttons leave the D-pad's reach while a window or dialog is up.
		local selectables: { GuiObject } = { promoButton, addButton, quitButton, goal }
		for _, button in Hud.buttons do
			table.insert(selectables, button)
		end
		local function updateSelectable()
			local blocked = screen:GetAttribute("WindowOpen") == true or screen:GetAttribute("ModalOpen") == true
			for _, button in selectables do
				Kit.selectable(button, not blocked)
			end
		end
		-- A window, modal or reveal is up: the HUD fades out where it stands, then parks off
		-- screen (so nothing in it takes a tap) with its resting look back for whatever changes
		-- meanwhile; closing puts it back and fades it in. The promo eases itself out and in
		-- (updatePromo); toasts and the tutorial pill belong to their own modules and stay.
		local faders: { GuiObject } = { grid, wallet, tank, corner, units, strip, goal, gear }
		local hudHidden = false
		local function setHudHidden(hidden: boolean)
			if hidden == hudHidden then
				return
			end
			hudHidden = hidden
			if hidden then
				for _, gui in faders do
					Kit.fade(gui, false, HIDE_TIME, function()
						if gui == gear then
							gear.Visible = false
						else
							parked[gui] = true
							place(false)
						end
					end)
				end
			else
				table.clear(parked)
				gear.Visible = true
				place(false)
				for _, gui in faders do
					Kit.fade(gui, true, HIDE_TIME)
				end
			end
		end
		Kit.onWindowOpen(function(open: boolean)
			setHudHidden(open)
			updatePromo()
			updateSelectable()
		end)
		screen:GetAttributeChangedSignal("ModalOpen"):Connect(updateSelectable)
		screen:GetAttributeChangedSignal("CardioActive"):Connect(updatePromo)
		screen:GetAttributeChangedSignal("RunActive"):Connect(updatePromo)
		screen:GetAttributeChangedSignal("CratePanelOpen"):Connect(function()
			place(true)
		end)
		State.changed.Event:Connect(updatePromo)
		-- Compact, narrow or touch screens: Roblox's player list would cover the top-right
		-- corner (the gear on touch) and the unit counter, so it stays hidden there.
		local function updatePlayerList()
			local size = designSize()
			local narrow = size.X > 0 and size.X * (if screenScale then screenScale.Scale else 1) < NARROW_PX
			Kit.hidePlayerList("smallscreen", screen:GetAttribute("Compact") == true or narrow or Kit.touch)
		end
		local function relayout()
			applyCompact()
			updatePlayerList()
		end
		screen:GetAttributeChangedSignal("Compact"):Connect(relayout)
		pcall(function()
			screen:GetPropertyChangedSignal("AbsoluteSize"):Connect(updatePlayerList)
		end)
		if screenScale then
			screenScale:GetPropertyChangedSignal("Scale"):Connect(relayout)
		end
		Kit.onInput(relayout)
		updateSelectable()
	end

	-- Updates ------------------------------------------------------------------------------
	local moneyShown: number? = nil
	local moneyRollEnd = 0
	local lastMult: number? = nil
	local lastCarried: number? = nil
	local lastBought: number? = nil
	local function refresh()
		local data = State.data
		if not data then
			return
		end
		-- Cash rolls up (longer for bigger gains) and quickly down when spent; income flashes
		-- the cash plate.
		if moneyShown ~= nil and data.money ~= moneyShown then
			local gain = data.money - (moneyShown :: number)
			local time = if gain > 0 then math.clamp(0.4 + 0.08 * math.log10(math.max(gain, 1)), 0.45, 0.9) else 0.25
			moneyRollEnd = os.clock() + time
			roll(moneyLabel, data.money, State.money, time)
			if gain > 0 then
				cashGain(gain)
			else
				-- Spent: a red flash of the amount and a small pop.
				moneyLabel.TextColor3 = TUNE.MoneyDrop
				Kit.tween(moneyLabel, TUNE.MoneyDropTime, { TextColor3 = TUNE.MoneyColor })
				Kit.pop(moneyLabel, TUNE.MoneyDropPop)
			end
		else
			roll(moneyLabel, data.money, State.money)
		end
		moneyShown = data.money
		if lastMult ~= nil and lastMult ~= data.moneyMult then
			Kit.pop(multLine, 0.8)
		end
		lastMult = data.moneyMult
		multLine.Text = string.format('Cash <font color="#%s">[ x%.1f ]</font>', C.Gold:ToHex(), data.moneyMult)
		local income = tonumber(data.rewardIncome) or tonumber(data.income) or 0
		incomeChip.Visible = income > 0 and not Kit.touch
		incomeLine.Text = "+" .. State.money(income) .. "/s"
		local owned = 0
		if type(data.unitTotal) == "number" then
			owned = data.unitTotal
		elseif type(data.units) == "table" then
			for _, count in data.units do
				if type(count) == "number" then
					owned += count
				end
			end
		end
		if type(data.unitCap) == "number" and data.unitCap ~= unitCap then
			unitCap = data.unitCap
			fitCount()
		end
		-- The count ticks to its new value; a buy at a full rack (it merges on its own) shakes it.
		local before = rolled[counterLabel]
		local bought = tonumber(data.bought) or 0
		roll(counterLabel, owned, unitsText)
		setRackFull(owned >= unitCap)
		if before ~= nil then
			countChanged(owned - before, owned >= unitCap and lastBought ~= nil and bought > lastBought)
		end
		lastBought = bought
		roll(carriedLabel, data.carried, State.num, 0.3)
		-- Carried aura dropping to nothing is a deposit: the bigger bounce.
		if lastCarried ~= nil and lastCarried > 0 and data.carried <= 0 then
			Hud.pulseTank(true)
		end
		lastCarried = data.carried

		setStatus(premiumRow, data.premium == true)
		local friends = math.floor((data.friendBonus or 0) * 100 + 0.5)
		friendsText.Text = string.format("Friends +%d%%", friends)
		setStatus(friendsRow, friends > 0)

		if seenDiscoveries == nil then
			seenDiscoveries = discoveredCount(data)
		end
		refreshIndexBadge()
		layoutWallet()
	end
	State.changed.Event:Connect(refresh)

	-- In a block: its locals stay out of build's 200 (see the note at the top of build).
	do
		-- Coin burst to the wallet ------------------------------------------------------------
		-- Its own ScreenGui with no insets/scale so world->viewport points map 1:1.
		local fxGui = Instance.new("ScreenGui")
		fxGui.Name = "HudFx"
		fxGui.ResetOnSpawn = false
		fxGui.IgnoreGuiInset = true
		fxGui.DisplayOrder = 5
		fxGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
		pcall(function()
			fxGui.ScreenInsets = Enum.ScreenInsets.None
		end)
		fxGui.Parent = screen.Parent
		local fxLayer = Kit.new("Frame", {
			Name = "Layer",
			BackgroundTransparency = 1,
			Size = UDim2.fromScale(1, 1),
			Parent = fxGui,
		})
		local uiScale = screen:FindFirstChildOfClass("UIScale")
		local coinPitch = 1
		local lastCoinAt = 0

		local function makeCoin(size: number): Frame
			return Kit.icon(fxLayer, "Coin", size, C.Gold, { Name = "Coin", AnchorPoint = Vector2.new(0.5, 0.5) })
		end

		Hud.coinBurst = function(amount: number, padPos: Vector3?, fromGui: GuiObject?)
			local layerAt = fxLayer.AbsolutePosition
			local viewport = Workspace.CurrentCamera and Workspace.CurrentCamera.ViewportSize or Vector2.new(1280, 720)
			local origin = Vector2.new(viewport.X * 0.5, viewport.Y * 0.5)
			local camera = Workspace.CurrentCamera
			if fromGui then
				origin = fromGui.AbsolutePosition + fromGui.AbsoluteSize * 0.5 - layerAt
			elseif padPos and camera then
				local point, onScreen = camera:WorldToViewportPoint(padPos)
				if onScreen and point.Z > 0 then
					origin = Vector2.new(point.X, point.Y)
				end
			end
			local target = coin.AbsolutePosition + coin.AbsoluteSize * 0.5 - layerAt
			local scale = if uiScale then uiScale.Scale else 1
			local magnitude = math.log10(math.max(amount, 1))
			local count = math.clamp(8 + math.floor(magnitude * 1.2), 8, 16)
			local size = math.floor(30 * scale)
			if os.clock() - lastCoinAt > 1 then
				coinPitch = 1
			end
			for i = 1, count do
				local c = makeCoin(size)
				c.Position = UDim2.fromOffset(origin.X, origin.Y)
				c.Size = UDim2.fromOffset(size * 0.4, size * 0.4)
				local angle = math.random() * math.pi * 2
				local radius = (40 + math.random() * 90) * scale
				local spread = origin + Vector2.new(math.cos(angle), math.sin(angle) * 0.7 - 0.4) * radius
				Kit.tween(
					c,
					0.3,
					{ Position = UDim2.fromOffset(spread.X, spread.Y), Size = UDim2.fromOffset(size, size) },
					Enum.EasingStyle.Back
				)
				task.delay(0.3 + i * 0.045, function()
					local fly = 0.42 + math.random() * 0.08
					Kit.tween(c, fly, {
						Position = UDim2.fromOffset(target.X, target.Y),
						Size = UDim2.fromOffset(size * 0.6, size * 0.6),
					}, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
					task.delay(fly, function()
						c:Destroy()
						lastCoinAt = os.clock()
						sounds.play("Coin", 0.04, coinPitch)
						coinPitch = math.min(coinPitch + 0.035, 1.5)
						Kit.pop(moneyLabel, 0.4)
					end)
				end)
			end
		end
	end

	local shaking = false
	Hud.shakeWallet = function()
		if shaking then
			return
		end
		shaking = true
		local home = moneyLabel.Position
		moneyLabel.TextColor3 = C.Danger
		Kit.pop(moneyLabel, 0.4)
		-- The cash plate's edge flares red (not during a surge: the edge is its pulse then)
		-- and the "+" pops: more cash is one tap away.
		if not surgeActiveNow then
			flash(cashPlate, C.Danger, TUNE.PlateColor, 0.5, C.Danger, nil, 4)
		end
		Kit.pop(addButton, 2)
		task.spawn(function()
			for _, dx in { 9, -8, 6, -4, 2, 0 } do
				Kit.tween(moneyLabel, 0.045, { Position = home + UDim2.fromOffset(dx, 0) }, Enum.EasingStyle.Sine)
				task.wait(0.045)
			end
			moneyLabel.Position = home
			Kit.tween(moneyLabel, 0.35, { TextColor3 = TUNE.MoneyColor })
			shaking = false
		end)
	end
	Hud.walletIdle = function(): boolean
		return os.clock() >= moneyRollEnd
	end

	-- Discoveries land on the Index button -----------------------------------------------
	Hud.indexPoint = function(): Vector2?
		local button = Hud.buttons.Index
		if screen:GetAttribute("WindowOpen") == true or not (screen.Enabled and grid.Visible and button.Visible) then
			return nil
		end
		-- The rest position, not the current one: the menu may still be sliding back in.
		local scale = if screenScale then screenScale.Scale else 1
		local rest = Vector2.new(
			L.edge + button.Position.X.Offset + button.Size.X.Offset / 2,
			L.gridY + button.Position.Y.Offset + button.Size.Y.Offset / 2
		)
		local point = rest * scale
		local size = screen.AbsoluteSize
		if point.X < 0 or point.Y < 0 or point.X > size.X or point.Y > size.Y then
			return nil
		end
		return screen.AbsolutePosition + point
	end
	Hud.punchIndex = function()
		local button = Hud.buttons.Index
		Kit.pop(button, 2.4)
		sounds.play("Collect", 0.04, 1.25)
		-- A white ring spreads from the icon.
		local ring = Kit.new("Frame", {
			Name = "Punch",
			BackgroundColor3 = Color3.new(1, 1, 1),
			BackgroundTransparency = 0.3,
			Size = UDim2.fromScale(0.8, 0.8),
			Position = UDim2.fromScale(0.5, 0.5),
			AnchorPoint = Vector2.new(0.5, 0.5),
			ZIndex = 3,
			Parent = button,
		})
		Kit.round(ring)
		local edge = Kit.new("UIStroke", { Thickness = 4, Color = Color3.new(1, 1, 1), Transparency = 0.1, Parent = ring })
		Kit.tween(ring, 0.4, { Size = UDim2.fromScale(2, 2), BackgroundTransparency = 1 }, Enum.EasingStyle.Quart)
		Kit.tween(edge, 0.4, { Transparency = 1, Thickness = 1 }, Enum.EasingStyle.Quart)
		-- "+1" pops over the icon itself, big and gold, and rises only as far as the icon's
		-- top: the caption of the button above (Home) sits in the gap over it.
		local plus = Kit.hudText(button, {
			Name = "Plus",
			Text = "+1",
			TextSize = 38,
			MinPx = 22,
			TextColor3 = C.Gold,
			StrokeColor = G.TextInk,
			StrokeThickness = 3,
			Size = UDim2.new(1, 40, 0, 40),
			Position = UDim2.fromScale(0.5, 0.62),
			AnchorPoint = Vector2.new(0.5, 0.5),
			ZIndex = 6,
		})
		Kit.tween(plus, 0.7, { Position = UDim2.fromScale(0.5, 0.34) }, Enum.EasingStyle.Quad)
		local outline = plus:FindFirstChild("Outline")
		task.delay(0.4, function()
			Kit.tween(plus, 0.3, { TextTransparency = 1 })
			if outline then
				Kit.tween(outline, 0.3, { Transparency = 1 })
			end
		end)
		task.delay(0.75, function()
			ring:Destroy()
			plus:Destroy()
		end)
		-- The badge (new since the Index was last opened) pops with it.
		refreshIndexBadge()
		local badge = button:FindFirstChild("Badge")
		if badge and badge:IsA("GuiObject") and badge.Visible then
			Kit.pop(badge, 1.4)
		end
	end

	-- In a block: its locals stay out of build's 200 (see the note at the top of build).
	do
		-- Deposit multiplier re-roll: the value flickers like a slot machine ------------------
		local spinning = false
		-- Never red: a deposit bonus is a bonus (x1 at the least).
		local function multColor(mult: number): Color3
			return if mult >= 1.2 then C.MoneyText else C.Gold
		end
		local depositMult = ReplicatedStorage:GetAttribute("DepositMult") or 1
		local function showMult(mult: number)
			if surgeActiveNow then
				gaugeValue.Text = "x" .. Economy.SURGE_MULTIPLIER
				gaugeValue.TextColor3 = TUNE.SurgeText
			else
				gaugeValue.Text = string.format("x%.1f", mult)
				gaugeValue.TextColor3 = multColor(mult)
			end
		end
		showMult(depositMult)
		ReplicatedStorage:GetAttributeChangedSignal("DepositMult"):Connect(function()
			depositMult = ReplicatedStorage:GetAttribute("DepositMult") or 1
			if spinning or surgeActiveNow then
				showMult(depositMult)
				return
			end
			spinning = true
			task.spawn(function()
				local elapsed = 0
				local step = 0.035
				-- Silent visual roll: the value flickers (from x1 up), then lands with a pop.
				local low = math.max(1, Economy.DEPOSIT_MIN)
				while elapsed < 0.6 do
					showMult(low + math.random() * math.max(0, Economy.DEPOSIT_MAX - low))
					task.wait(step)
					elapsed += step
					step *= 1.22
				end
				depositMult = ReplicatedStorage:GetAttribute("DepositMult") or depositMult
				showMult(depositMult)
				Kit.pop(gaugeValue, 1)
				Kit.pop(strip, 0.4)
				if depositMult >= 1.5 then
					niceLabel.Text = if depositMult >= 2 then "HUGE!" else "NICE!"
					Kit.appear(niceLabel, { from = 0.3, time = 0.3 })
					task.delay(1.4, function()
						Kit.disappear(niceLabel, { to = 1.1, time = 0.25 })
					end)
				end
				spinning = false
			end)
		end)

		-- Aura Surge: the status plate turns gold (paintSurge), the cash plate's edge pulses gold
		-- and the "SURGE x2" chip joins the wallet (surgeWallet); the screen grade and music are
		-- Fx.Surge's.
		local surgeActive: boolean? = nil
		local lastSurgeSecond = -1

		local function setSurge(active: boolean, announce: boolean)
			paintSurge(active)
			showMult(depositMult)
			surgeWallet(active)
			if announce then
				Kit.pop(strip, if active then 1.6 else 0.6)
			end
		end

		-- Free gift: countdown under it; when ready a "!" dot and a sunny "CLAIM!", the gift
		-- hopping and the word breathing (this corner is the one place that announces it).
		local freeText = ""
		local freeReady: boolean? = nil
		local stopFreeBounce: (() -> ())? = nil
		local function paintFree(text: string, ready: boolean)
			if ready ~= freeReady then
				freeReady = ready
				Kit.setBadge(freeButton, if ready then "!" else nil)
				-- White on the gold tab when ready (gold words would vanish on it).
				freeTimer.TextColor3 = Color3.new(1, 1, 1)
				claimTab.Visible = ready
				if ready then
					Kit.pop(freeButton, 0.8)
					local stopGift = hop(freeButton, UDim2.fromScale(0.5, 0))
					local stopWord = Kit.breathe(freeTimer, TUNE.GiftWordBreathe)
					local stopTab = Kit.breathe(claimTab, TUNE.GiftWordBreathe)
					stopFreeBounce = function()
						stopGift()
						stopWord()
						stopTab()
					end
				elseif stopFreeBounce then
					stopFreeBounce()
					stopFreeBounce = nil
				end
			end
			freeTimer.Text = text
		end
		-- Daily reward: a dot, a sunny caption and a gentle bounce while a reward waits (the
		-- bounce while it is the menu's focus: menu.refocus); the countdown to the next one as
		-- the caption otherwise.
		local dailyText = ""
		local dailyReady: boolean? = nil
		local function paintDaily(text: string, ready: boolean)
			if ready ~= dailyReady then
				dailyReady = ready
				Kit.setBadge(dailyButton, if ready then "!" else nil)
				dailyCaption.TextColor3 = if ready then C.Gold else Color3.new(1, 1, 1)
				if ready then
					Kit.pop(dailyButton, 0.8)
				end
				menu.wants["Daily!"] = ready
				menu.refocus()
			end
			dailyCaption.Text = text
		end
		-- The beat: every BeatEvery seconds each badge dot on a HUD button pops, one button
		-- after another ("!" harder than a count: a reward to claim outranks news; of the menu
		-- only the button in focus), the "+"
		-- pops on every PlusEvery-th beat and the "AUTO-MERGING" pill on every other. Not
		-- while a window covers the HUD.
		if not PREVIEW then
			task.spawn(function()
				local beat = 0
				while screen.Parent do
					task.wait(TUNE.BeatEvery)
					beat += 1
					if screen:GetAttribute("WindowOpen") ~= true then
						local nth = 0
						for name, button in Hud.buttons do
							-- On the menu only its focus beats (menu.refocus).
							local badge = if CAPTIONS[name] and name ~= menu.focus then nil else button:FindFirstChild("Badge")
							if badge and badge:IsA("TextLabel") and badge.Visible then
								task.delay(
									nth * TUNE.BeatStagger,
									Kit.pop,
									badge,
									if badge.Text == "!" then TUNE.BadgePop else TUNE.BadgePopCount
								)
								nth += 1
							end
						end
						-- New Modes (no badge of its own): the plate itself beats under its ring.
						if menu.focus == "Modes" and menu.wants.ModesNew then
							Kit.pop(Hud.buttons.Modes, TUNE.ModesNewPop)
						end
						if beat % TUNE.PlusEvery == 0 and addButton.Visible then
							Kit.pop(addButton, TUNE.PlusPop)
						end
						if rackFull and beat % 2 == 0 then
							Kit.pop(counterCaption, TUNE.FullBeatPop)
						end
					end
				end
			end)
		end
		local nextText = ""
		local nearAt = 0
		RunService.Heartbeat:Connect(function()
			-- The nearer goal's timers (crate, "nothing affordable for a minute") run between
			-- two snapshots.
			if os.clock() - nearAt >= NEAR_TICK then
				nearAt = os.clock()
				updateNear()
			end
			local now = Workspace:GetServerTimeNow()
			-- No surge strip or chip for a player still in the tutorial (the server gives
			-- them no surge either).
			local surgeData = State.data
			local active, left = Economy.surgeFor(now, surgeData ~= nil and surgeData.tutorialDone == true)
			if active ~= surgeActive then
				-- Announce only real transitions, not the state found on join.
				setSurge(active, surgeActive ~= nil)
				surgeActive = active
			end
			local text
			if active then
				-- Countdown pop in the last 10 seconds.
				local second = math.ceil(left)
				if left <= 10 and second ~= lastSurgeSecond then
					lastSurgeSecond = second
					Kit.pop(gaugeNext, 0.8)
				end
				text = "· " .. Format.time(left)
				surgeLeft(left)
			else
				local nextAt = ReplicatedStorage:GetAttribute("DepositNextAt") or now
				text = string.format("· %ds", math.max(0, math.ceil(nextAt - now)))
			end
			if text ~= nextText then
				nextText = text
				gaugeNext.Text = text
			end
			local data = State.data
			if data then
				local freeLeft = math.max(0, (data.freeIn or 0) - State.age())
				local ready = freeLeft <= 0
				local label = if ready then "CLAIM!" else Format.time(freeLeft)
				if label ~= freeText then
					freeText = label
					paintFree(label, ready)
				end
				local daily = data.daily
				if type(daily) == "table" then
					-- The dot and the bounce wait for the tutorial, like the window itself.
					local dailyNow = daily.claimable == true and data.tutorialDone == true
					local dailyLabel = if daily.claimable == true
						then CAPTIONS.Daily
						else Format.time(math.max(0, (tonumber(daily.nextIn) or 0) - State.age()))
					if dailyLabel ~= dailyText or dailyNow ~= dailyReady then
						dailyText = dailyLabel
						paintDaily(dailyLabel, dailyNow)
					end
				end
			end
		end)
	end
	refresh()
	layoutWallet()

	-- Obby mode: the run's own HUD owns the top centre ----------------------------------
	Hud.tank = tank
	local obbyOn = false
	local tutorialConn: RBXScriptConnection? = nil
	local tutorialWanted = false
	local forcing = false
	Hud.setObbyMode = function(on: boolean)
		if on == obbyOn then
			return
		end
		obbyOn = on
		screen:SetAttribute("ObbyMode", on)
		for _, gui in { units, strip, corner } :: { GuiObject } do
			gui.Visible = not on
		end
		updatePromo()
		-- The quest pill (Tutorial) stays down even if it re-renders mid-run; whatever
		-- it asked for meanwhile is applied when the run ends.
		local pill = screen:FindFirstChild("TutorialPill")
		if not (pill and pill:IsA("GuiObject")) then
			return
		end
		if on then
			tutorialWanted = pill.Visible
			pill.Visible = false
			tutorialConn = pill:GetPropertyChangedSignal("Visible"):Connect(function()
				if forcing then
					return
				end
				tutorialWanted = pill.Visible
				if pill.Visible then
					forcing = true
					pill.Visible = false
					forcing = false
				end
			end)
		else
			if tutorialConn then
				tutorialConn:Disconnect()
				tutorialConn = nil
			end
			pill.Visible = tutorialWanted
		end
	end

	-- Entrance: the HUD eases in a block at a time, top first.
	local entrance: { GuiObject } = { units, strip, gear }
	for _, row in GRID_ROWS do
		for _, name in row do
			table.insert(entrance, Hud.buttons[name])
		end
	end
	table.insert(entrance, wallet)
	table.insert(entrance, tank)
	table.insert(entrance, corner)
	Kit.stagger(entrance, 0.03)
end

return Hud
