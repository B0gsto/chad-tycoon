--[[
	Windows: Shop, Index, Ranking and Settings (Maps and Daily Reward live in
	MapPicker.luau and DailyWindow.luau and register here).

	Only one is open at a time. A dimmed backdrop sits behind the open window;
	clicking it, the X button, Escape or the gamepad B button closes it.

	Look: glass. Each window is a translucent pane over the blurred, lightly
	dimmed world (Kit.window); rows and tiles are lighter glass and shop cards
	are glass in their own colour, with one accent colour per window. Every shop
	price sits on the same solid mint button (one height, one text size) with an
	idle sheen.
	Motion: a window pops open; its cards ripple in the first time it opens,
	numbers count, bars and switches ease.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local Comeback = require(ReplicatedStorage.Shared.Comeback)
local Economy = require(ReplicatedStorage.Shared.Economy)
local Format = require(ReplicatedStorage.Shared.Format)
local IndexRewards = require(ReplicatedStorage.Shared.IndexRewards)
local Net = require(ReplicatedStorage.Shared.Net)
local ShopMath = require(ReplicatedStorage.Shared.ShopMath)

local Kit = require(script.Parent.Kit)
local DailyWindow = require(script.Parent.DailyWindow)
local MapPicker = require(script.Parent.MapPicker)
local ShopScenes = require(script.Parent.ShopScenes)
local Sprites = require(script.Parent.Parent.Fx.Sprites)
local State = require(script.Parent.Parent.State)

local Theme = Kit.Theme
local C = Kit.C
local T = Kit.TEXT
local F = Kit.F
local W = Theme.Words
local I = Theme.Icons

-- The Lune preview exporter has no real tweens or frame time: finish
-- transitions immediately there.
local PREVIEW = typeof(TweenInfo.new(0)) ~= "TweenInfo"

local Windows = {}

local windows: { [string]: Kit.Window } = {}
-- Runs just before a window opens (while it is still hidden), so content can
-- be refreshed and its cards set up to ripple in with the window.
local beforeOpen: { [string]: () -> () } = {}
local backdrop: TextButton
Windows.changed = Instance.new("BindableEvent")

local function anyOpen(): boolean
	for _, window in windows do
		if window.isOpen() then
			return true
		end
	end
	return false
end
Windows.isAnyOpen = anyOpen

-- Gamepad: a window can name the control its selection should land on when it opens
-- (Shop: the card it was opened at); otherwise its FocusFirst control or first button.
local focusPick: { [string]: () -> GuiObject? } = {}

-- Re-runs gamepad focus one frame after a window's content is (re)built, so the
-- selection lands on its first card or button rather than a stale one.
local function focusWindow(name: string)
	local window = windows[name]
	if not window or PREVIEW then
		return
	end
	task.defer(function()
		if not window.isOpen() then
			return
		end
		local pick = focusPick[name]
		local preferred = if pick then pick() else nil
		if preferred then
			Kit.focus(window.content, preferred)
		else
			window.focus()
		end
	end)
end

-- opts.focus (Shop only): a pass or cosmetic name, or a section ("Passes", "Cosmetics", "Cash",
-- "Aura"), to open scrolled to. opts.origin: the button that opened it (the window grows out
-- of it and closes back into it; without one it pops at the centre).
function Windows.open(name: string, opts: { focus: string?, origin: GuiObject? }?)
	if opts and opts.focus and name == "Shop" then
		Windows.shopFocus = opts.focus
	end
	local origin: Vector2? = nil
	local button = opts and opts.origin
	if button then
		local ok, point = pcall(function()
			return button.AbsolutePosition + button.AbsoluteSize / 2
		end)
		origin = if ok and typeof(point) == "Vector2" then point else nil
	end
	local target = windows[name]
	if target and not target.isOpen() and beforeOpen[name] then
		beforeOpen[name]()
	end
	for key, window in windows do
		window.setOpen(key == name and not window.isOpen(), origin)
	end
	if target and target.isOpen() then
		focusWindow(name)
	end
	Kit.fadeBackdrop(backdrop, anyOpen(), Kit.GLASS_DIM)
	Windows.changed:Fire()
	if name == "Shop" and target and target.isOpen() then
		-- Shop funnel step 1 (Server.Analytics).
		Net.event("Action"):FireServer({ action = "ShopOpened" })
	end
end

function Windows.closeAll()
	for _, window in windows do
		window.setOpen(false)
	end
	if backdrop then
		Kit.fadeBackdrop(backdrop, false)
	end
	Windows.changed:Fire()
end

local function register(name: string, window: Kit.Window)
	windows[name] = window
	window.onClose.Event:Connect(function()
		Kit.fadeBackdrop(backdrop, anyOpen(), Kit.GLASS_DIM)
		Windows.changed:Fire()
	end)
end

-- Removes content children, keeping panel chrome (Highlight, Lip, Shadow).
local function clearChildren(parent: Instance, className: string?)
	for _, child in parent:GetChildren() do
		if child:IsA(className or "GuiObject") and not child:GetAttribute("KitChrome") then
			child:Destroy()
		end
	end
end

-- Cards that have made their entrance: each one eases in the first time its
-- window opens and is simply there on every later open.
local entered: { [Instance]: boolean } = setmetatable({}, { __mode = "k" }) :: any
local function firstTime(cards: { GuiObject }): { GuiObject }
	local fresh: { GuiObject } = {}
	for _, gui in cards do
		if not entered[gui] then
			entered[gui] = true
			table.insert(fresh, gui)
		end
	end
	return fresh
end

--[[
	Cards ease in one after another, 25 ms apart, the first time they are shown
	(scale only: the window's own fade covers transparency, so a card never
	keeps a half-faded look when the window closes mid-animation).
]]
local function ripple(cards: { GuiObject })
	for i, gui in firstTime(cards) do
		Kit.appear(gui, { from = 0.9, time = 0.26, delay = math.min(i - 1, 12) * 0.025, fade = false })
	end
end

-- Phone: touch input on a short screen (the "Compact" attribute, Main.client). Kit.fit
-- hands it a shorter window scaled up, so text grows; the windows re-flow their content.
local function isPhone(screen: Instance): boolean
	return Kit.touch and screen:GetAttribute("Compact") == true
end

-- Runs `fn` now and whenever isPhone may have changed (input mode, the Compact attribute).
local function onPhone(screen: Instance, fn: () -> ())
	Kit.onInput(function()
		fn()
	end)
	screen:GetAttributeChangedSignal("Compact"):Connect(fn)
end

-- A caption that has to be read (a goal line, a milestone, "Before you go"): held on the
-- glass at the caption size, rounded up and never under 13 px (a phone's 12 px captions
-- included), whatever the screen and the window's own scale.
local function readable(label: TextLabel): TextLabel
	Kit.holdText(label, math.max(Kit.captionPx(), 13), nil, true)
	return label
end

--[[
	Tinted tag on a glass card (a rarity, a state): Kit.pill's soft fill of `Color` under
	a light label in that colour (small text: no outline). Sizes to its text. props: Name, Text, Color, Position, AnchorPoint, ZIndex.
]]
local function tag(parent: Instance, props: { [string]: any }): TextLabel
	local color: Color3 = props.Color
	local label = Kit.text(parent, {
		Name = props.Name or "Tag",
		Text = props.Text,
		Font = F.UI,
		TextSize = props.TextSize or 15,
		MinPx = props.TextSize or true,
		TextColor3 = Kit.lighten(color, 0.65),
		TextWrapped = false,
		BackgroundColor3 = color,
		BackgroundTransparency = 0.6,
		Size = UDim2.fromOffset(0, 26),
		AutomaticSize = Enum.AutomaticSize.X,
		Position = props.Position or UDim2.new(),
		AnchorPoint = props.AnchorPoint or Vector2.zero,
		ZIndex = props.ZIndex or 1,
	})
	Kit.padding(label, 0, 10)
	Kit.round(label)
	return label
end

-- Shop ------------------------------------------------------------------------------

--[[
	Four tabs under a pill switcher, each its own scrolling page: Passes (the
	Starter Pack hero card until owned, then a full-width animated banner per
	game pass), Cosmetics (All Cosmetics bundle + a card grid), Cash and Aura
	(pack cards). A tab shows its section and nothing else; its canvas ends
	PAGE_BOTTOM under its last row. Every banner and pack card has a ShopScenes stage that plays
	only while the shop is open, so a closed shop costs nothing per frame.
]]

-- Each pass banner is fully tinted with its own candy colour (mint is kept for the price buttons).
local PASS_TINTS: { [string]: Color3 } = {
	AutoLoot = Theme.World.Sunny,
	AutoMerge = Theme.World.Orange,
	AutoCash = Theme.World.Coral,
	DoubleAura = Theme.World.Grape,
	DoubleMoney = Theme.World.Blue,
	PremiumUnlocker = Theme.World.Pink,
	CrateKey = Theme.World.Orange,
}

-- Ribbon candy colours, one per kind of tag (a cosmetic's OWNED keeps the mint "good" green;
-- passes and the bundle say OWNED on their button instead).
local RIBBON_SUNNY = Theme.World.Sunny -- popular, savings
local RIBBON_PINK = Color3.fromRGB(255, 84, 168) -- best seller, starter deal, exclusive
local RIBBON_CORAL = Theme.World.Coral -- best value

-- Corner tags on pass banners, hidden once the pass is owned (each contrasts with its banner).
local PASS_TAGS: { [string]: { text: string, color: Color3 } } = {
	AutoLoot = { text = "BEST SELLER", color = RIBBON_PINK },
	DoubleMoney = { text = "POPULAR", color = RIBBON_SUNNY },
}

-- Small text (12 px and under) on blue: near-white, never blue-grey.
local SMALL_TEXT = C.Text:Lerp(C.TextDim, 0.5)

-- Robux prices use Kit's shared glyph (see Kit.ROBUX).
local ROBUX = Kit.ROBUX
local function price(amount: number): string
	return ROBUX .. " " .. tostring(amount)
end

--[[
	Corner tag ("POPULAR", "BEST VALUE", "OWNED"): a solid candy pill with white
	text in a dark outline, overlapping the card's top-right corner by ~6 px,
	over a soft drop shadow. The returned label is the shadow (it sizes to the
	text); the coloured face is its child, so Visible and pop/breathe scale
	move both together.
]]
local RIBBON_PAD = 12
-- Width of a ribbon's text (TextService when available, else an estimate). The ribbon
-- is sized explicitly: AutomaticSize would include its face child, which pokes out past
-- the ribbon for the shadow effect, and grow without bound.
local function ribbonTextWidth(text: string): number
	local width = 0
	pcall(function()
		local TextService = game:GetService("TextService")
		width = TextService:GetTextSize(text, 16, F.UI, Vector2.new(1000, 26)).X
	end)
	if width <= 0 then
		width = (utf8.len(text) or #text) * 9
	end
	return math.ceil(width)
end

local function ribbon(parent: Instance, text: string, color: Color3): TextLabel
	local shadow = Kit.text(parent, {
		Name = "Ribbon",
		Text = text,
		Font = F.UI,
		TextSize = 16,
		MinPx = false, -- the ribbon is sized from its text at this size
		TextTransparency = 1,
		TextWrapped = false,
		BackgroundColor3 = C.Ink,
		BackgroundTransparency = 0.45,
		Size = UDim2.fromOffset(ribbonTextWidth(text) + RIBBON_PAD * 2, 26),
		Position = UDim2.new(1, 8, 0, -5),
		AnchorPoint = Vector2.new(1, 0),
		StrokeThickness = 0,
		ZIndex = 7,
	})
	Kit.padding(shadow, 0, RIBBON_PAD)
	Kit.round(shadow)
	local face = Kit.text(shadow, {
		Name = "Face",
		Text = text,
		Font = F.UI,
		TextSize = 16,
		MinPx = false, -- the ribbon is sized from its text at this size
		TextWrapped = false,
		TextColor3 = Color3.new(1, 1, 1),
		BackgroundColor3 = color,
		BackgroundTransparency = 0,
		Size = UDim2.new(1, RIBBON_PAD * 2, 1, 0),
		Position = UDim2.fromOffset(-RIBBON_PAD - 2, -3),
		StrokeThickness = 0,
		ZIndex = 7,
	})
	Kit.round(face)
	Kit.gradient(face, Color3.new(1, 1, 1), Color3.new(0.86, 0.86, 0.9))
	Kit.new("UIStroke", {
		Thickness = 2,
		Color = Kit.darken(Kit.lip(color), 0.35),
		ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual,
		LineJoinMode = Enum.LineJoinMode.Round,
		Parent = face,
	})
	-- The outline ring sits on a transparent child so the face can outline its glyphs too.
	local edge = Kit.new("Frame", {
		Name = "Edge",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		ZIndex = 7,
		Parent = face,
	})
	Kit.round(edge)
	Kit.new("UIStroke", {
		Thickness = 2,
		Color = Kit.lip(color),
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
		Parent = edge,
	})
	return shadow
end

-- Product art: the atlas icon `art` drawn large, or the `fallback` shape icon tinted `color`.
local function productArt(parent: Instance, art: string, fallback: string, color: Color3, size: number): GuiObject
	local props = {
		Name = "Art",
		Position = UDim2.fromScale(0.5, 0.5),
		AnchorPoint = Vector2.new(0.5, 0.5),
		ZIndex = 4,
	}
	if Kit.hasImageIcon(art) then
		return Kit.icon(parent, art, size, nil, props)
	end
	return Kit.icon(parent, fallback, math.floor(size * 0.7), color, props)
end

-- Section ids in page order, the switcher's pill text and each section's header (icon,
-- title, caption and the colour of its glowing underline).
local SECTIONS = {
	{ key = "Passes", pill = "Passes", title = "GAME PASSES", caption = "Permanent upgrades", icon = "Star", color = C.Gold },
	{
		key = "Cosmetics",
		pill = "Cosmetics",
		title = "COSMETICS",
		caption = "Look cool. Move faster.",
		icon = "Crown",
		color = C.Accent,
	},
	{
		key = "Cash",
		pill = "Cash",
		title = "CASH",
		caption = "Grows as your " .. W.Unit .. "s get stronger",
		icon = "Coin",
		color = C.Cash,
	},
	{
		key = "Aura",
		pill = W.Orb,
		title = string.upper(W.Orb),
		caption = "Blended into cash at once",
		icon = "Orb",
		color = C.Violet,
	},
}

local function iconColor(icon: string): Color3
	return Kit.ICON_COLORS[icon] or C.Gold
end

-- "15 min", "1 h", "24 h": how much income or aura a pack is worth.
local function durationText(seconds: number): string
	if seconds < 3600 then
		return string.format("%d min", math.floor(seconds / 60 + 0.5))
	end
	local hours = seconds / 3600
	return if hours == math.floor(hours) then string.format("%d h", hours) else string.format("%.1f h", hours)
end

--[[
	Shop sizes (design pixels at the 860x600 window). At the default window the
	free card, the Starter card, the GAME PASSES header and the top of the first
	pass banner fit the visible page (the shade along its bottom edge says it
	scrolls on); on the 620x400 minimum everything keeps one row per banner and
	the page (244 px under the pinned title and switcher) still shows the tallest
	card, a pack, whole. A phone gets that short window scaled up x1.25.
]]
local BANNER_H = 130 -- pass banner height: title 10-44, description inset 48-92, PERMANENT 98-118
local BANNER_DESC_Y = 48
local BANNER_DESC_H = 44
local BANNER_PERK_Y = 98
local BANNER_TEXT_X = 8 -- the title, the description and PERMANENT share this left text edge
local STAGE_W = 230 -- a banner's animated stage, at the default window...
local STAGE_MIN_W = 140 -- ...and the narrowest it shrinks to
local COS_H = 204 -- cosmetic card height
local COS_SWITCH_W = 72 -- a cosmetic's on/off switch on its own pane, left of the price button
local PACK_H = 238 -- cash / aura card height (stage, amount, one-line caption, price)
local PACK_STAGE = 125 -- pack card stage (square) on a PACK_H card; it grows and shrinks with the card
local PACK_MAX_H = 260 -- tallest a pack card grows to fill a page its row fits in
local PACK_FILL = 0.9 -- share of the free page height such a card takes
local PACK_ICON = 26 -- currency icon left of a pack's amount
-- The free and Starter cards are kept low so the first pass banner fits the default page
-- whole under them and the GAME PASSES header (12 + 98 + 16 + 98 + 12 + 54 + 10 + 130 = 430
-- of the 444 px page at 860x600).
local STARTER_H = 98 -- Starter pack card, under the free card
local FREE_H = 98 -- free gift card heading the Passes page: never smaller than the paid card under it
local WIDE_ART = 86 -- the art on the left of the free and Starter cards
local WIDE_TITLE_Y = 8 -- a wide card's title row (32 px tall)...
local WIDE_CHIPS_Y = 44 -- ...and its row of contents chips under it
local WIDE_CHIP_H = 46
local STARTER_GAP = 12 -- under the Starter card, over the GAME PASSES header
local PASSES_HEAD_GAP = 10 -- under that header, over the first banner
local BUNDLE_H = 120 -- All Cosmetics card heading the cosmetics section
local GAP = 16
local HEAD_H = 54 -- section header height (icon row + glowing underline)
local SWITCH_H = 44 -- section switcher bar (36 px pills inside)
local PAGE_TOP = SWITCH_H + 8 -- the scrolling page starts below the switcher
local PRICE_H = 42 -- every price button
local PRICE_TEXT = 20
local FADE_H = 56 -- shade along the bottom edge of the page: the hint that it scrolls on (with Kit.scrollCue's arrow)
-- The slow sheen across each grid's BEST VALUE card: seconds between two, band width (px),
-- the band's transparency at its brightest and seconds to cross the card.
local BEST_SHINE = { Every = 3.4, Width = 90, Fade = 0.45, Time = 1.8 }
-- Every banner and card: its own sheen, ENTRY_SHINE.Every seconds apart plus up to
-- ENTRY_SHINE.Spread (staggered by card), bright and wide enough to catch in a still.
local ENTRY_SHINE = { Every = 3.2, Spread = 1.2, Width = 64, Fade = 0.4, Time = 1.4 }
local PACK_SUB = 16 -- a pack card's caption ("1 h of income"), design px...
local PACK_SUB_PX = 14 -- ...and its floor on the glass, whatever the screen and window scale
local CHIP_CAPTION = 16 -- a contents chip's caption ("every 10 min", "cash"), px on the glass
local PAGE_BOTTOM = 14 -- room under the last row of a section, clear of that shade
local PAGE_PAD = 12 -- UIPadding over the first row: a ribbon overlaps its card's top edge by 8 px
local PAGE_FIT_BOTTOM = 4 -- room under a row of cards that fills the page
local PAGE_SHORT = 330 -- a page under this (a phone) drops the section header: the cards are the page
local MIN_TEXT = 14 -- no fixed-size shop text is smaller (Kit.WINDOW.TextPx on a desktop screen)
local MIN_SCALED = 14 -- ...and a TextScaled label never shrinks under this to fit its box
local CART = 52 -- header cart art (inside the pane)
local WALLET_CASH = 140 -- header wallet pill: the cash half...
local WALLET_AURA = 112 -- ...and the tank half
local INSET = 0.4 -- darker panes inside a glass card (descriptions, contents chips)
-- The same panes on a bright banner (Theme.Glass.Banner): a deeper tone of its tint, more
-- solid, so white text keeps its contrast on the saturated fill.
local BANNER_INSET = Theme.Glass.BannerInset
local BANNER_INSET_DEEP = Theme.Glass.BannerInsetDeep

-- TextScaled labels in the shop never shrink below MIN_SCALED.
local function minText(label: TextLabel): TextLabel
	local constraint = label:FindFirstChildOfClass("UITextSizeConstraint")
	if constraint then
		constraint.MinTextSize = math.min(MIN_SCALED, constraint.MaxTextSize)
	end
	return label
end

-- Small text on a candy tint: white glyphs in a 1 px outline of the tint's deep tone (a
-- thicker one smudges text this size).
local function outline(label: TextLabel, tint: Color3): UIStroke
	return Kit.new("UIStroke", {
		Thickness = 1,
		Color = Kit.darken(Kit.lip(tint), 0.3),
		ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual,
		LineJoinMode = Enum.LineJoinMode.Round,
		Parent = label,
	})
end

--[[
	Banner look shared by the pass banners, the Starter and All Cosmetics cards
	and the pack cards, on top of Kit.panel's coloured glass card: a diagonal
	two-tone candy tint that thins out toward the far corner (so more of the
	world shows through there), a light edge in the card's colour, and a clipped
	holder for the idle sheen. The holder is inset by half the corner radius so
	the sheen never pokes past the rounded corners.
]]
local function bannerPaint(body: Frame, tint: Color3, radius: number, strokeColor: Color3?, bright: boolean?): Frame
	local gradient = body:FindFirstChildOfClass("UIGradient")
	if gradient then
		gradient.Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, Kit.lighten(tint, if bright then 0.14 else 0.24)),
			ColorSequenceKeypoint.new(0.5, tint),
			ColorSequenceKeypoint.new(1, Kit.darken(tint, 0.16)),
		})
		-- A bright banner keeps its colour edge to edge (the blurred world under a thin
		-- tint turns it muddy); the others thin out toward the far corner.
		gradient.Transparency = if bright then NumberSequence.new(0) else NumberSequence.new(0, 0.3)
		gradient.Rotation = 24
	end
	local stroke = body:FindFirstChildOfClass("UIStroke")
	if stroke then
		stroke.Thickness = 2
		stroke.Color = strokeColor or Kit.lighten(tint, if bright then Theme.Glass.BannerEdge else 0.55)
		if bright then
			-- The lighter edge in the banner's hue runs all the way round.
			stroke.Transparency = 0
			local fade = stroke:FindFirstChildOfClass("UIGradient")
			if fade then
				fade.Transparency = NumberSequence.new(0)
			end
		end
	end
	return Kit.new("Frame", {
		Name = "SheenClip",
		BackgroundTransparency = 1,
		ClipsDescendants = true,
		Size = UDim2.new(1, -radius, 1, -8),
		Position = UDim2.fromOffset(radius // 2, 4),
		ZIndex = 3,
		Parent = body,
	})
end

-- Cosmetics: card tints (the world's candy paint) and the grid order, with the
-- Starter-only items last so the purchasable ones fill the first rows.
local COS = Theme.Cosmetics
local COS_TINTS: { [string]: Color3 } = {
	SpeedBoost = Theme.World.Blue,
	DoubleJump = Theme.World.Grape,
	TrailRainbow = Theme.World.Pink,
	TrailStar = Theme.World.Sunny,
	TrailRookie = Theme.World.Mint,
	AuraGlow = Theme.World.Orange,
	Crown = Theme.World.Coral,
}
local COS_ORDER: { string } = {}
for _, name in COS.Order do
	if not COS.Items[name].Starter then
		table.insert(COS_ORDER, name)
	end
end
for _, name in COS.Order do
	if COS.Items[name].Starter then
		table.insert(COS_ORDER, name)
	end
end

-- The All Cosmetics pass's saving against buying every cosmetic pass on its own, in percent.
local function bundleSaving(): number
	local total = 0
	for _, name in COS_ORDER do
		local item = COS.Items[name]
		local pass = item.Pass and Theme.Monetization.Passes[item.Pass]
		if pass and not item.Starter then
			total += pass.Price
		end
	end
	local bundle = Theme.Monetization.Passes[COS.Bundle].Price
	return if total > bundle then math.floor((1 - bundle / total) * 100) else 0
end

--[[
	The Starter pack's cash for this player right now, from the same Economy
	functions (and the same progression) the server grants with.
]]
function Windows.starterAmounts(data: { [string]: any }): number
	local starter = COS.Starter
	local progression = Economy.progression(data.highestTier or 1, data.processLevel or 0)
	return Economy.moneyPackAmount(data.rewardIncome or data.income or 0, starter.CashSeconds, starter.CashMin, progression)
end

-- The cosmetics part of a snapshot, empty when the server sent none.
local NO_COSMETICS = { owned = {}, trail = "", toggles = {}, canSwitch = {}, bundleOwned = false, starterOwned = false }
local function cosmeticsOf(data: { [string]: any }): { [string]: any }
	local cosmetics = data.cosmetics
	return if type(cosmetics) == "table" then cosmetics else NO_COSMETICS
end
Windows.cosmeticsOf = cosmeticsOf

-- Pending focus for the next shop open: a section ("Cosmetics", "Cash", "Aura" ...), a
-- pass ("DoubleMoney", "StarterPack", "AllCosmetics") or a cosmetic, set by Windows.open.
Windows.shopFocus = nil :: string?
-- Opens the MOG TEST picker (VS RIVALS / 1v1 DUEL); Main points it at MogHud.choose
-- (Windows cannot require MogHud: MogHud -> Popups -> Windows).
Windows.onMogPlay = nil :: (() -> ())?

-- Candy colours the header divider drifts through.
local CANDY = ColorSequence.new({
	ColorSequenceKeypoint.new(0, Theme.World.Pink),
	ColorSequenceKeypoint.new(0.25, Theme.World.Sunny),
	ColorSequenceKeypoint.new(0.5, Theme.World.Mint),
	ColorSequenceKeypoint.new(0.75, C.Rizz),
	ColorSequenceKeypoint.new(1, Theme.World.Grape),
})

type Scene = ShopScenes.Scene

local function buildShop(screen: ScreenGui)
	local window = Kit.window(screen, "Shop", "Shop", I.Shop, C.Window.Shop, Vector2.new(860, 600), Vector2.new(620, 400))
	register("Shop", window)
	local action = Net.event("Action")
	local content = window.content
	local frame = window.frame

	-- Every open/close starts a new session; idle loops and delayed steps stop when it changes.
	local session = 0
	local idleStops: { () -> () } = {}
	-- Repeating idle tweens (header divider, glows): played on open; on close they
	-- stop and snap back to their resting values, so every open starts from the same look.
	local idleTweens: { { tween: Tween, gui: Instance, rest: { [string]: any } } } = {}
	local function idleTween(gui: Instance, time: number, props: { [string]: any }, delay: number?)
		if PREVIEW then
			return
		end
		local info = TweenInfo.new(time, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true, delay or 0)
		local rest = {}
		for key in props do
			rest[key] = (gui :: any)[key]
		end
		table.insert(idleTweens, { tween = TweenService:Create(gui, info, props), gui = gui, rest = rest })
	end

	-- Header: the cart art in place of the icon chip (inside the pane's corner, it never
	-- overhangs the edge) and one wallet pill with both balances at the right.
	local chip = window.header:FindFirstChild("Chip")
	if chip and chip:IsA("GuiObject") then
		chip.Visible = false
	end
	local headerTitle = window.header:FindFirstChild("Title")
	if headerTitle and headerTitle:IsA("TextLabel") then
		headerTitle.Position = UDim2.fromOffset(CART + 24, 2)
		headerTitle.Size = UDim2.new(0, 120, 1, 0)
		headerTitle.TextSize = 33
	end
	local cart = Kit.new("Frame", {
		Name = "Cart",
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(CART, CART),
		Position = UDim2.fromOffset(14, 3),
		ZIndex = 8,
		Parent = frame,
	})
	local cartScale = Kit.new("UIScale", { Parent = cart })
	productArt(cart, "Shop", "Shop", C.Gold, CART)

	-- Header polish: the divider under the title runs as a slow rainbow and a sheen sweeps the
	-- top of the glass now and then (both only while open).
	local shade = window.header:FindFirstChild("Shade")
	if shade and shade:IsA("Frame") then
		shade.Size = UDim2.new(1, -28, 0, 3)
		local shadeGradient = shade:FindFirstChildOfClass("UIGradient")
		if shadeGradient then
			shadeGradient.Color = CANDY
			shadeGradient.Transparency = NumberSequence.new(0.1, 0.45)
			shadeGradient.Offset = Vector2.new(-0.25, 0)
			idleTween(shadeGradient, 4, { Offset = Vector2.new(0.25, 0) })
		end
	end
	local headerSheen = Kit.new("Frame", {
		Name = "SheenClip",
		BackgroundTransparency = 1,
		ClipsDescendants = true,
		Size = UDim2.new(1, -Theme.Glass.Radius, 1, -6),
		Position = UDim2.fromOffset(Theme.Glass.Radius // 2, 3),
		ZIndex = 2,
		Parent = window.header,
	})

	-- Wallet: the one balance readout, an inset pill (like the tab bar) left of the close
	-- button with cash and the tank (aura carried, like the HUD's dumbbell plaque) side by
	-- side. Bought cash and aura fly to their half of it.
	local wallet = Kit.well(window.header, {
		Name = "Wallet",
		Glass = true,
		Size = UDim2.fromOffset(WALLET_CASH + WALLET_AURA, 38),
		Position = UDim2.new(1, -64, 0.5, -1),
		AnchorPoint = Vector2.new(1, 0.5),
		Radius = 19,
		ZIndex = 3,
	})
	local function walletAmount(name: string, icon: string, color: Color3, x: number, width: number): TextLabel
		local holder = Kit.new("Frame", {
			Name = name,
			BackgroundTransparency = 1,
			Size = UDim2.new(0, width, 1, 0),
			Position = UDim2.fromOffset(x, 0),
			ZIndex = 3,
			Parent = wallet,
		})
		Kit.icon(holder, icon, 28, color, {
			Name = "Icon",
			Position = UDim2.new(0, 6, 0.5, 0),
			AnchorPoint = Vector2.new(0, 0.5),
			ZIndex = 4,
		})
		return minText(Kit.number(holder, {
			Name = "Amount",
			Text = "0",
			TextSize = 20,
			MaxTextSize = 20,
			TextScaled = true,
			Size = UDim2.new(1, -46, 0, 26),
			Position = UDim2.new(0, 37, 0.5, 0),
			AnchorPoint = Vector2.new(0, 0.5),
			TextXAlignment = Enum.TextXAlignment.Left,
			TextColor3 = color,
			ZIndex = 4,
		}))
	end
	local cashChip = walletAmount("Cash", "Coin", C.MoneyText, 0, WALLET_CASH)
	local auraChip = walletAmount("Aura", "Orb", C.Orb, WALLET_CASH, WALLET_AURA)

	--[[
		Section switcher: one pill (icon + label) per section in a well, with a
		sunny indicator gliding under the section in view (Kit.tabs' selected
		style: ink text on the light pill). The indicator follows the page as it
		scrolls; tapping a pill scrolls that section's header to the top. On a
		narrow window the pills drop their icons so the labels keep their size.
	]]
	local count = #SECTIONS
	local switcher = Kit.well(content, {
		Name = "Switcher",
		Size = UDim2.fromOffset(150 * count, SWITCH_H),
		Position = UDim2.new(0.5, 0, 0, 0),
		AnchorPoint = Vector2.new(0.5, 0),
		Radius = SWITCH_H // 2,
		ZIndex = 2,
		Glass = true,
	})
	local function slot(i: number): (UDim2, UDim2)
		return UDim2.new((i - 1) / count, 4, 0, 4), UDim2.new(1 / count, -8, 1, -8)
	end
	local slotPos, slotSize = slot(1)
	local highlight = Kit.new("Frame", {
		Name = "Highlight",
		BackgroundColor3 = Color3.new(1, 1, 1),
		Size = slotSize,
		Position = slotPos,
		ZIndex = 2,
		Parent = switcher,
	})
	Kit.round(highlight)
	Kit.gradient(highlight, Kit.lighten(C.Gold, 0.24), C.Gold)
	Kit.new("UIStroke", { Thickness = 1.5, Color = Kit.lip(C.Gold), Parent = highlight })
	local SELECTED_TEXT = Kit.inkOn(C.Gold)

	local scroll = Kit.scrolling(content, {
		Name = "Scroll",
		Size = UDim2.new(1, 0, 1, -PAGE_TOP),
		Position = UDim2.fromOffset(0, PAGE_TOP),
	})
	scroll.ZIndex = 2
	scroll.AutomaticCanvasSize = Enum.AutomaticSize.None
	local SCROLL_BAR = scroll.ScrollBarThickness
	-- Ribbons (POPULAR, BEST VALUE, STARTER DEAL) overlap the top edge of their card by
	-- 8 px: the page starts PAGE_PAD lower, so the first row's are not cut by the clip.
	Kit.new("UIPadding", { PaddingTop = UDim.new(0, PAGE_PAD), Parent = scroll })
	-- Gamepad selection moves between the cards; the engine scrolls the page to them.
	scroll.Selectable = false

	-- A shade along the bottom edge of the page while it scrolls on (stacked strips of the
	-- glass tint, so it also renders without gradient transparency): FADE_H px, clear at its
	-- top and nearly solid at the edge, so the row under it visibly runs on. It fades out at
	-- the end of the page.
	local fade = Kit.new("Frame", {
		Name = "Fade",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, -8, 0, FADE_H),
		Position = UDim2.new(0, 0, 1, 0),
		AnchorPoint = Vector2.new(0, 1),
		ZIndex = 9,
		Parent = content,
	})
	local FADE_STEPS = 8
	local fadeStrips: { [Frame]: number } = {}
	for i = 1, FADE_STEPS do
		local strip = Kit.new("Frame", {
			Name = "Strip" .. i,
			BackgroundColor3 = Theme.Glass.Tint,
			BackgroundTransparency = 1 - (i / FADE_STEPS) ^ 1.5 * 0.88,
			BorderSizePixel = 0,
			-- One pixel of overlap, so no seam shows between two strips at a fractional scale.
			Size = UDim2.new(1, 0, 1 / FADE_STEPS, 1),
			Position = UDim2.fromScale(0, (i - 1) / FADE_STEPS),
			ZIndex = 9,
			Parent = fade,
		})
		fadeStrips[strip] = strip.BackgroundTransparency
	end
	-- ...and Kit.scrollCue's bouncing arrow over it, while the page runs on (the Passes tab's
	-- game passes start under the fold).
	Kit.scrollCue(scroll, { Fade = false, ZIndex = 10 })
	local fadeShown = true
	local function showFade(on: boolean)
		if on == fadeShown then
			return
		end
		fadeShown = on
		for strip, transparency in fadeStrips do
			if PREVIEW then
				strip.BackgroundTransparency = if on then transparency else 1
			else
				Kit.tween(strip, 0.2, { BackgroundTransparency = if on then transparency else 1 })
			end
		end
	end

	local pills: { TextButton } = {}
	local pillLabels: { TextLabel } = {}
	local pillIcons: { GuiObject } = {}
	local heads: { Frame } = {}
	local sectionY: { number } = {}
	local current = 1
	local canvasH = 0
	local previewShift = 0
	local layout: (Vector2) -> ()
	-- Visible page height: the window minus its chrome (header 72, bottom 12, padding 20) and the switcher.
	local function pageH(): number
		return window.size().Y - 104 - PAGE_TOP
	end
	-- Farthest the page scrolls: canvas height minus the visible height.
	local function maxScroll(): number
		return math.max(0, canvasH - pageH())
	end
	-- While a pill's scroll runs, the indicator stays on the tapped section.
	local pinUntil = 0
	local syncSection: () -> ()
	-- Scrolls the page so canvas height `y` is at the top (clamped to the page).
	local function scrollTo(y: number, instant: boolean?)
		local target = Vector2.new(0, math.max(0, math.min(y, maxScroll())))
		if PREVIEW then
			-- The preview exporter has no canvas scrolling: shift the page instead.
			previewShift = target.Y
			layout(window.size())
			syncSection()
		elseif instant then
			scroll.CanvasPosition = target
		else
			pinUntil = os.clock() + 0.45
			Kit.tween(scroll, 0.4, { CanvasPosition = target }, Enum.EasingStyle.Quint)
			task.delay(0.5, function()
				if window.isOpen() and os.clock() >= pinUntil then
					syncSection()
				end
			end)
		end
	end

	local function setCurrent(index: number, animate: boolean)
		if index == current and animate then
			return
		end
		current = index
		local pos = slot(index)
		if animate and not PREVIEW then
			Kit.tween(highlight, 0.24, { Position = pos }, Enum.EasingStyle.Back)
			if heads[index] then
				Kit.pop(heads[index], 0.5)
			end
		else
			highlight.Position = pos
		end
		for i, label in pillLabels do
			local color = if i == index then SELECTED_TEXT else C.Text
			if animate and not PREVIEW then
				Kit.tween(label, 0.18, { TextColor3 = color })
			else
				label.TextColor3 = color
			end
		end
	end
	-- A tab is its own page: only the picked section is laid out (layout), from the top.
	local function showSection(index: number, animate: boolean)
		local changed = index ~= current
		setCurrent(index, animate)
		if changed then
			previewShift = 0
			layout(window.size())
		end
	end
	local function scrollToSection(index: number, instant: boolean?)
		showSection(index, not instant)
		scrollTo(0, true)
		showFade(maxScroll() > 2)
	end
	for i, section in SECTIONS do
		local pos, size = slot(i)
		local pill = Kit.new("TextButton", {
			Name = section.key,
			AutoButtonColor = false,
			BackgroundTransparency = 1,
			Text = "",
			Size = size,
			Position = pos,
			ZIndex = 3,
			Parent = switcher,
		})
		Kit.list(pill, 6, true, Enum.HorizontalAlignment.Center)
		pillIcons[i] = Kit.icon(pill, section.icon, 26, iconColor(section.icon), {
			Name = "Icon",
			LayoutOrder = 1,
			ZIndex = 4,
		})
		pillLabels[i] = Kit.text(pill, {
			Name = "Label",
			Text = string.upper(section.pill),
			Font = F.UI,
			TextSize = 18,
			TextWrapped = false,
			TextColor3 = if i == 1 then SELECTED_TEXT else C.Text,
			Size = UDim2.new(0, 0, 1, 0),
			AutomaticSize = Enum.AutomaticSize.X,
			LayoutOrder = 2,
			StrokeThickness = 0,
			ZIndex = 4,
		})
		Kit.bouncy(pill, 1)
		Kit.selectable(pill)
		if i == 1 then
			pill:SetAttribute("FocusFirst", true)
		end
		local function pick()
			Kit.sound("Click")
			scrollToSection(i)
		end
		pill.Activated:Connect(pick)
		-- On touch the pill (36 px) takes taps over its whole slot of the 44 px bar.
		local hit = Kit.new("TextButton", {
			Name = "Hit" .. section.key,
			Text = "",
			AutoButtonColor = false,
			BackgroundTransparency = 1,
			Selectable = false,
			Size = UDim2.new(1 / #SECTIONS, 0, 1, 0),
			Position = UDim2.fromScale((i - 1) / #SECTIONS, 0),
			Visible = Kit.touch,
			ZIndex = 5,
			Parent = switcher,
		})
		hit.Activated:Connect(pick)
		Kit.onInput(function()
			hit.Visible = Kit.touch
		end)
		pills[i] = pill
	end

	-- Section header: a big icon, chunky outlined title and caption in one row over a
	-- glowing underline in the section's colour (the glow breathes while open).
	local function sectionHead(index: number): Frame
		local section = SECTIONS[index]
		local head = Kit.new("Frame", { Name = "Head" .. section.key, BackgroundTransparency = 1, Parent = scroll })
		local row = Kit.new("Frame", {
			Name = "Row",
			BackgroundTransparency = 1,
			Size = UDim2.new(1, 0, 0, 44),
			Parent = head,
		})
		Kit.list(row, 10, true).VerticalAlignment = Enum.VerticalAlignment.Center
		Kit.icon(row, section.icon, 40, iconColor(section.icon), { Name = "Icon", LayoutOrder = 1 })
		Kit.title(row, {
			Name = "Title",
			Text = section.title,
			TextSize = 30,
			TextWrapped = false,
			Size = UDim2.new(0, 0, 0, 36),
			AutomaticSize = Enum.AutomaticSize.X,
			LayoutOrder = 2,
			StrokeThickness = 3,
		})
		Kit.text(row, {
			Name = "Caption",
			Text = section.caption,
			Font = F.Bold,
			TextSize = 15,
			TextWrapped = false,
			Size = UDim2.new(0, 0, 0, 20),
			AutomaticSize = Enum.AutomaticSize.X,
			LayoutOrder = 3,
			TextColor3 = SMALL_TEXT,
		})
		-- Underline: a soft wide glow with a bright core, both fading out to the right.
		local fadeRight = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0),
			NumberSequenceKeypoint.new(0.6, 0.3),
			NumberSequenceKeypoint.new(1, 1),
		})
		local glow = Kit.new("Frame", {
			Name = "Glow",
			BackgroundColor3 = section.color,
			BackgroundTransparency = 0.78,
			BorderSizePixel = 0,
			Size = UDim2.new(0.62, 0, 0, 10),
			Position = UDim2.new(0, 0, 0, 43),
			Parent = head,
		})
		Kit.corner(glow, 5)
		Kit.new("UIGradient", { Transparency = fadeRight, Parent = glow })
		local line = Kit.new("Frame", {
			Name = "Underline",
			BackgroundColor3 = Kit.lighten(section.color, 0.2),
			BorderSizePixel = 0,
			Size = UDim2.new(0.6, 0, 0, 4),
			Position = UDim2.new(0, 0, 0, 46),
			Parent = head,
		})
		Kit.corner(line, 2)
		Kit.new("UIGradient", { Transparency = fadeRight, Parent = line })
		idleTween(glow, 1.4, { BackgroundTransparency = 0.5 }, index * 0.2)
		heads[index] = head
		return head
	end

	-- A grid cell holds a "Body" panel, so hover can lift the body while the grid owns the cell.
	-- `art` is static product art that bobs and tilts; animated stages leave it nil.
	type Entry = {
		cell: Frame,
		body: Frame,
		art: GuiObject?,
		artHolder: GuiObject,
		button: TextButton,
		sheen: Frame?,
		clip: Frame?,
	}
	local cascade: { GuiObject } = {}
	local entries: { Entry } = {}
	local shopFocusButton: GuiObject? = nil
	local scenes: { Scene } = {}
	local refresh: () -> ()

	-- Little stars burst from a point (frame-local pixels) on tap.
	local function stars(at: Vector2)
		if PREVIEW then
			return
		end
		for i = 1, 5 do
			local angle = math.rad(i * 72 + math.random(-15, 15))
			local star = Kit.icon(frame, "Star", 14, C.Gold, {
				Name = "TapStar",
				Position = UDim2.fromOffset(at.X, at.Y),
				AnchorPoint = Vector2.new(0.5, 0.5),
				ZIndex = 40,
			})
			local reach = math.random(26, 40)
			Kit.tween(star, 0.35, {
				Position = UDim2.fromOffset(at.X + math.cos(angle) * reach, at.Y + math.sin(angle) * reach),
				Size = UDim2.fromOffset(0, 0),
				Rotation = math.random(-90, 90),
			}, Enum.EasingStyle.Quad)
			task.delay(0.36, function()
				star:Destroy()
			end)
		end
	end

	-- Absolute screen point -> pixels inside the window frame (the window may be scaled by Kit.fit).
	local function local_(point: Vector2): Vector2
		local s = frame.AbsoluteSize.X / math.max(1, window.size().X)
		return (point - frame.AbsolutePosition) / math.max(s, 0.01)
	end
	local function centreOf(gui: GuiObject): Vector2
		return local_(gui.AbsolutePosition + gui.AbsoluteSize / 2)
	end

	local function makeEntry(
		parent: Instance,
		name: string,
		order: number,
		color: Color3,
		artName: string,
		fallback: string,
		artSize: number,
		artPos: UDim2,
		tile: boolean?
	)
		local cell = Kit.new("Frame", { Name = name, BackgroundTransparency = 1, LayoutOrder = order, Parent = parent })
		-- A banner is a coloured glass card; a tile is the dark content card, tinted with its
		-- colour and wearing it on its edge.
		local body = if tile
			then Kit.glass(cell, {
				Name = "Body",
				Color = color,
				Size = UDim2.fromScale(1, 1),
				Radius = Kit.RADIUS.M + 4,
				StrokeThickness = 1.5,
			})
			else Kit.panel(cell, {
				Name = "Body",
				Glass = true,
				Color = color,
				Transparency = Theme.Glass.Banner,
				Size = UDim2.fromScale(1, 1),
				Radius = Kit.RADIUS.M + 4,
			})
		local artHolder = Kit.new("Frame", {
			Name = "ArtHolder",
			BackgroundTransparency = 1,
			Size = UDim2.fromOffset(artSize, artSize),
			Position = artPos,
			AnchorPoint = Vector2.new(0.5, 0.5),
			ZIndex = 4,
			Parent = body,
		})
		local art = productArt(artHolder, artName, fallback, color, artSize)
		table.insert(cascade, cell)
		return cell, body, artHolder, art
	end

	-- Price button with an idle sheen bar parked off its left edge; squashes on press, stars on tap.
	local function priceButton(body: Frame, props: { [string]: any }, onClick: () -> ()): (TextButton, Frame?)
		props.Name = "Buy"
		props.Font = F.Number
		props.TextColor = C.Ink
		props.Color = C.Cash
		props.TextSize = PRICE_TEXT
		local button = Kit.button(body, props, onClick)
		button.ZIndex = 5
		local face = Kit.buttonFace(button)
		local sheen: Frame? = nil
		if face then
			face.ClipsDescendants = true
			local bar = Kit.new("Frame", {
				Name = "Sheen",
				BackgroundColor3 = Color3.new(1, 1, 1),
				BackgroundTransparency = 0.55,
				BorderSizePixel = 0,
				Size = UDim2.new(0, 26, 1.6, 0),
				Position = UDim2.new(0, -40, -0.3, 0),
				Rotation = 18,
				ZIndex = 8,
				Parent = face,
			})
			Kit.new("UIGradient", {
				Transparency = NumberSequence.new({
					NumberSequenceKeypoint.new(0, 1),
					NumberSequenceKeypoint.new(0.5, 0.2),
					NumberSequenceKeypoint.new(1, 1),
				}),
				Parent = bar,
			})
			sheen = bar
		end
		button.MouseButton1Down:Connect(function()
			stars(centreOf(button))
		end)
		return button, sheen
	end

	-- Hover / touch: the body lifts 3 px, static art tilts and the art or stage pops.
	local function hoverable(entry: Entry)
		if PREVIEW then
			return
		end
		local function lift(on: boolean)
			Kit.tween(entry.body, 0.16, { Position = UDim2.fromOffset(0, if on then -3 else 0) }, Enum.EasingStyle.Quad)
			local art = entry.art
			if art then
				Kit.tween(art, 0.22, { Rotation = if on then -8 else 0 }, Enum.EasingStyle.Back)
			end
			if on then
				Kit.pop(entry.artHolder, if art then 0.6 else 0.25)
			end
		end
		entry.body.MouseEnter:Connect(function()
			lift(true)
		end)
		entry.body.MouseLeave:Connect(function()
			lift(false)
		end)
		-- Gamepad: the selected card lifts like a hovered one.
		entry.button.SelectionGained:Connect(function()
			lift(true)
		end)
		entry.button.SelectionLost:Connect(function()
			lift(false)
		end)
		entry.button.MouseButton1Down:Connect(function()
			if Kit.touch then
				lift(true)
				task.delay(0.25, function()
					lift(false)
				end)
			end
		end)
	end

	-- The last product prompted (or free gift claimed), so the cash that lands flies from its card.
	local lastPrompt: { kind: string, entry: Entry, index: number, at: number }? = nil

	-- Cosmetic tile, a dark card in its candy colour: art, outlined title, an inset in the
	-- colour's deep tone with the description (14-15 px, up to two lines) and the price
	-- button along the bottom.
	type PassCard = Entry & { tag: TextLabel?, owned: TextLabel, desc: TextLabel, wasOwned: boolean? }
	local function tileCard(
		grid: Frame,
		name: string,
		order: number,
		tint: Color3,
		art: { string },
		title: string,
		descText: string,
		buttonText: string,
		onClick: () -> ()
	): PassCard
		local cell, body, artHolder, artGui = makeEntry(grid, name, order, tint, art[1], art[2], 74, UDim2.new(0.5, 0, 0, 43), true)
		minText(Kit.title(body, {
			Name = "Title",
			Text = string.upper(title),
			TextSize = 24,
			MaxTextSize = 24,
			TextScaled = true,
			TextWrapped = false,
			Size = UDim2.new(1, -20, 0, 26),
			Position = UDim2.fromOffset(10, 81),
			TextColor3 = C.Text,
			StrokeThickness = 2.5,
			ZIndex = 4,
		}))
		local inset = Kit.new("Frame", {
			Name = "Inset",
			BackgroundColor3 = Kit.darken(tint, 0.34),
			BackgroundTransparency = INSET,
			Size = UDim2.new(1, -20, 0, 40),
			Position = UDim2.fromOffset(10, 110),
			ZIndex = 3,
			Parent = body,
		})
		Kit.corner(inset, 10)
		local desc = minText(Kit.text(inset, {
			Name = "Desc",
			Text = descText,
			Font = F.Bold,
			TextSize = 15,
			MaxTextSize = 15,
			TextScaled = true,
			Size = UDim2.new(1, -12, 1, -4),
			Position = UDim2.fromOffset(6, 2),
			TextColor3 = Color3.new(1, 1, 1),
			ZIndex = 4,
		}))
		local button, sheen = priceButton(body, {
			Text = buttonText,
			Size = UDim2.new(1, -20, 0, PRICE_H),
			Position = UDim2.new(0, 10, 1, -10),
			AnchorPoint = Vector2.new(0, 1),
		}, onClick)
		local owned = ribbon(body, "OWNED", C.Good)
		owned.Visible = false
		local entry: PassCard = {
			cell = cell,
			body = body,
			art = artGui,
			artHolder = artHolder,
			button = button,
			sheen = sheen,
			owned = owned,
			desc = desc,
		}
		hoverable(entry)
		table.insert(entries, entry)
		return entry
	end

	-- Wide cards: art on the left (WIDE_LEFT px), text in the middle, the price button on the right.
	local WIDE_LEFT = 136
	local WIDE_PRICE_W = 150
	local WIDE_TEXT_W = -(WIDE_LEFT + WIDE_PRICE_W + 34) -- text column width (scale 1 plus this)
	local WIDE_R = Kit.RADIUS.M + 4

	-- Wide card text: an outlined title and, when given, a one-line caption under it.
	local function wideText(body: Frame, tint: Color3, title: string, caption: string?): (TextLabel, TextLabel?)
		local titleLabel = minText(Kit.title(body, {
			Name = "Title",
			Text = title,
			TextSize = 28,
			MaxTextSize = 28,
			TextScaled = true,
			TextWrapped = false,
			Size = UDim2.new(1, WIDE_TEXT_W, 0, 32),
			Position = UDim2.fromOffset(WIDE_LEFT, WIDE_TITLE_Y),
			TextXAlignment = Enum.TextXAlignment.Left,
			TextColor3 = Color3.new(1, 1, 1),
			StrokeThickness = 0,
			ZIndex = 4,
		}))
		Kit.new("UIStroke", { Thickness = 3, Color = Kit.darken(Kit.lip(tint), 0.3), Parent = titleLabel })
		local captionLabel: TextLabel? = nil
		if caption then
			local label = Kit.text(body, {
				Name = "Caption",
				Text = caption,
				Font = F.Bold,
				TextSize = 15,
				TextWrapped = false,
				TextTruncate = Enum.TextTruncate.AtEnd,
				Size = UDim2.new(1, WIDE_TEXT_W, 0, 18),
				Position = UDim2.fromOffset(WIDE_LEFT + 2, 42),
				TextXAlignment = Enum.TextXAlignment.Left,
				TextColor3 = Color3.new(1, 1, 1),
				ZIndex = 4,
			})
			outline(label, tint)
			captionLabel = label
		end
		return titleLabel, captionLabel
	end

	-- The price button on the right of a wide card, vertically centred (same style as every card).
	local function widePrice(body: Frame, text: string, onClick: () -> ()): (TextButton, Frame?)
		return priceButton(body, {
			Text = text,
			Size = UDim2.fromOffset(WIDE_PRICE_W, PRICE_H),
			Position = UDim2.new(1, -18, 0.5, 0),
			AnchorPoint = Vector2.new(1, 0.5),
		}, onClick)
	end

	-- What is inside a wide card: a row of two chips on the card's own dark inset under the
	-- title, each an icon, an amount and a caption. Returns the function that adds a chip
	-- (its amount label, its caption and the chip itself).
	local function contentChips(body: Frame, tint: Color3): (number, string, string, Color3, string) -> (TextLabel, TextLabel, Frame)
		local chips = Kit.new("Frame", {
			Name = "Contents",
			BackgroundTransparency = 1,
			Size = UDim2.new(1, WIDE_TEXT_W, 0, WIDE_CHIP_H),
			Position = UDim2.fromOffset(WIDE_LEFT, WIDE_CHIPS_Y),
			ZIndex = 4,
			Parent = body,
		})
		Kit.list(chips, 8, true)
		return function(order: number, icon: string, fallback: string, color: Color3, caption: string): (TextLabel, TextLabel, Frame)
			local chip = Kit.new("Frame", {
				Name = "Chip" .. order,
				BackgroundColor3 = Kit.darken(tint, BANNER_INSET_DEEP),
				BackgroundTransparency = BANNER_INSET,
				Size = UDim2.new(1 / 2, -4, 1, 0),
				LayoutOrder = order,
				ZIndex = 3,
				Parent = chips,
			})
			Kit.corner(chip, 12)
			Kit.icon(chip, Kit.pickIcon(icon, fallback), 34, color, {
				Name = "Icon",
				Position = UDim2.new(0, 6, 0.5, 0),
				AnchorPoint = Vector2.new(0, 0.5),
				ZIndex = 4,
			})
			local amount = minText(Kit.number(chip, {
				Name = "Amount",
				Text = "",
				TextSize = 20,
				MaxTextSize = 20,
				TextScaled = true,
				Size = UDim2.new(1, -50, 0, 24),
				Position = UDim2.fromOffset(44, 3),
				TextXAlignment = Enum.TextXAlignment.Left,
				TextColor3 = Color3.new(1, 1, 1),
				ZIndex = 4,
			}))
			local captionLabel = Kit.text(chip, {
				Name = "Caption",
				Text = caption,
				Font = F.Bold,
				TextSize = CHIP_CAPTION,
				MinPx = CHIP_CAPTION,
				TextWrapped = false,
				TextTruncate = Enum.TextTruncate.AtEnd,
				Size = UDim2.new(1, -50, 0, 18),
				Position = UDim2.fromOffset(44, 26),
				TextXAlignment = Enum.TextXAlignment.Left,
				TextColor3 = C.Text,
				ZIndex = 4,
			})
			return amount, captionLabel, chip
		end
	end

	--[[
		Free first: the page opens on what costs nothing. A wide sunny card built like the
		paid Starter card under it (same height, title and two contents chips): the free gift
		(this player's own amount, the server's Free pad pays the same, and how often) with
		CLAIM or the time left on its button, and the Daily Reward, whose chip opens its
		window. No countdown here is a sales timer: both only say when the next free thing is
		ready.
	]]
	local freeTint = Theme.World.Sunny
	local freeCell, freeBody, freeArtHolder, freeArt =
		makeEntry(scroll, "Free", 0, freeTint, "Free", "Star", WIDE_ART, UDim2.new(0, 68, 0.5, 0))
	local freeEntry: Entry
	local freeShownCash: number? = nil
	-- The gift's amount, its button (CLAIM or the time left) and the Daily chip; runs with
	-- every snapshot and twice a second while the shop is open (the countdowns).
	local refreshFree: () -> ()
	do
		local clip = bannerPaint(freeBody, freeTint, WIDE_R, nil, true)
		wideText(freeBody, freeTint, string.upper(W.Free))
		local addChip = contentChips(freeBody, freeTint)
		local giftAmount = addChip(1, "Coin", "Coin", C.Gold, "every " .. durationText(Economy.FREE_REWARD_COOLDOWN))
		local dailyAmount, dailyCaption, dailyChip = addChip(2, "Gift2", "Star", C.Gold, "")
		dailyAmount.Text = "DAILY REWARD"
		dailyChip.Visible = false
		local dailyHit = Kit.new("TextButton", {
			Name = "Daily",
			AutoButtonColor = false,
			Text = "",
			BackgroundTransparency = 1,
			Size = UDim2.fromScale(1, 1),
			ZIndex = 6,
			Parent = dailyChip,
		})
		Kit.corner(dailyHit, 12)
		Kit.selectable(dailyHit)
		dailyHit.Activated:Connect(function()
			Kit.sound("Click")
			Windows.open("Daily")
		end)
		local button, sheen = widePrice(freeBody, "CLAIM", function()
			local data = State.data
			if not data or (data.freeIn or 0) - State.age() > 0 then
				return
			end
			-- The same action as the HUD's gift button; the cash that lands flies from this card.
			lastPrompt = { kind = "Free", entry = freeEntry, index = 0, at = os.clock() }
			action:FireServer({ action = "ClaimFree" })
		end)
		ribbon(freeBody, "FREE", C.Good)
		freeEntry = {
			cell = freeCell,
			body = freeBody,
			art = freeArt,
			artHolder = freeArtHolder,
			button = button,
			sheen = sheen,
			clip = clip,
		}
		hoverable(freeEntry)
		table.insert(entries, freeEntry)
		local shownButton: string? = nil
		local dailyShown: string? = nil
		refreshFree = function()
			local data = State.data
			if not data then
				return
			end
			local cash = ShopMath.freeGiftCash(data.rewardIncome or data.income or 0)
			if cash ~= freeShownCash then
				freeShownCash = cash
				giftAmount.Text = "+" .. State.money(cash)
			end
			local left = math.max(0, (data.freeIn or 0) - State.age())
			local buttonText = if left <= 0 then "CLAIM" else Format.time(left)
			if buttonText ~= shownButton then
				shownButton = buttonText
				Kit.setEnabled(button, left <= 0)
				Kit.setButton(button, buttonText)
			end
			local daily = data.daily
			local dailyText = ""
			if type(daily) == "table" then
				dailyText = if daily.claimable == true
					then "Ready to claim!"
					else "in " .. Format.time(math.max(0, (tonumber(daily.nextIn) or 0) - State.age()))
			end
			if dailyText ~= dailyShown then
				dailyShown = dailyText
				dailyCaption.Text = dailyText
				dailyCaption.TextColor3 = if dailyText == "Ready to claim!" then C.GoldLight else C.Text
				dailyChip.Visible = dailyText ~= ""
			end
		end
	end

	-- Starter pack: a wide mint hero card under the free card while the player does not own it --
	local starterPass = Theme.Monetization.Passes[COS.Starter.Pass]
	local starterTint = Theme.World.Mint
	local starterCell, starterBody, starterArtHolder, starterArt =
		makeEntry(scroll, "Starter", 0, starterTint, COS.Starter.Icon, "Star", WIDE_ART, UDim2.new(0, 68, 0.5, 0))
	local starterClip = bannerPaint(starterBody, starterTint, WIDE_R, nil, true)
	wideText(starterBody, starterTint, "STARTER PACK")
	-- What is inside: two chips, this player's own cash amount and the exclusive trail.
	local contentChip = contentChips(starterBody, starterTint)
	local starterCash = contentChip(1, "Coin", "Coin", C.Gold, "cash")
	local rookie = COS.Items[COS.Starter.Item]
	local rookieLabel = contentChip(2, rookie.Icon, "Star", rookie.Color, "exclusive")
	rookieLabel.Text = rookie.Title
	local starterButton, starterSheen = widePrice(starterBody, price(starterPass.Price), function()
		action:FireServer({ action = "PromptPass", name = COS.Starter.Pass })
	end)
	local starterTag = ribbon(starterBody, "STARTER DEAL", RIBBON_PINK)
	local starterEntry: Entry = {
		cell = starterCell,
		body = starterBody,
		art = starterArt,
		artHolder = starterArtHolder,
		button = starterButton,
		sheen = starterSheen,
		clip = starterClip,
	}
	hoverable(starterEntry)
	table.insert(entries, starterEntry)
	-- Shown until the pass is owned (a fresh purchase celebrates first, then folds away).
	local starterShown = true
	local starterWasOwned: boolean? = nil
	local starterShownCash: number? = nil

	--[[
		Section 1: game passes, one full-width banner each. Left: the pass's
		animated stage (ShopScenes.pass); middle: chunky outlined title, the
		description on a dark inset and a quiet PERMANENT caption; right: the price button. On a narrow
		window the stage gives up width first so the text column keeps its size.
	]]
	sectionHead(1)
	local passList = Kit.new("Frame", { Name = "Passes", BackgroundTransparency = 1, Parent = scroll })
	Kit.list(passList, GAP)
	type Banner = Entry & {
		tag: TextLabel?,
		desc: TextLabel,
		info: Frame,
		stage: Frame,
		scene: Scene,
		wasOwned: boolean?,
	}
	local BANNER_R = Kit.RADIUS.L + 2
	local banners: { [string]: Banner } = {}
	local bannerList: { Banner } = {}
	for order, name in Theme.Monetization.PassOrder do
		local pass = Theme.Monetization.Passes[name]
		local tint = PASS_TINTS[name] or pass.Color
		local cell = Kit.new("Frame", {
			Name = name,
			BackgroundTransparency = 1,
			LayoutOrder = order,
			Size = UDim2.new(1, 0, 0, BANNER_H),
			Parent = passList,
		})
		-- The fill is the pass's saturated colour, nearly solid (Theme.Glass.Banner), inside a
		-- lighter edge of the same hue: a thin tint over the blurred world reads as mud.
		local body = Kit.panel(cell, {
			Name = "Body",
			Glass = true,
			Color = tint,
			Transparency = Theme.Glass.Banner,
			Size = UDim2.fromScale(1, 1),
			Radius = BANNER_R,
		})
		local clip = bannerPaint(body, tint, BANNER_R, nil, true)
		-- The stage: a lit pane in the banner's own tint (a diagonal light-to-deep
		-- gradient, a lighter rim and a glassy sheen along its top) the pass's little
		-- scene plays in. It clips the scene, so nothing it draws reaches the text.
		local stage = Kit.new("Frame", {
			Name = "Stage",
			BackgroundColor3 = Color3.new(1, 1, 1),
			BackgroundTransparency = 0.25,
			ClipsDescendants = true,
			Size = UDim2.fromOffset(STAGE_W, BANNER_H - 18),
			Position = UDim2.fromOffset(9, 9),
			ZIndex = 4,
			Parent = body,
		})
		Kit.corner(stage, BANNER_R - 6)
		Kit.new("UIGradient", {
			Color = ColorSequence.new(Kit.lighten(tint, 0.15), Kit.darken(tint, 0.1)),
			Rotation = 35,
			Parent = stage,
		})
		Kit.new("UIStroke", {
			Thickness = 2,
			Color = Kit.lighten(tint, 0.5),
			ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
			Parent = stage,
		})
		-- Extra room on the right: counters a scene draws at its right edge stay whole
		-- inside the stage instead of being cut off right next to the title.
		Kit.new("UIPadding", {
			PaddingLeft = UDim.new(0, 6),
			PaddingRight = UDim.new(0, 22),
			Parent = stage,
		})
		-- Created before the scene, so the scene draws over it (offsets undo the padding).
		local stageSheen = Kit.new("Frame", {
			Name = "Sheen",
			BackgroundColor3 = Color3.new(1, 1, 1),
			BackgroundTransparency = 0.6,
			BorderSizePixel = 0,
			Size = UDim2.new(1, 12, 0, 22),
			Position = UDim2.fromOffset(2, 4),
			ZIndex = 1,
			Parent = stage,
		})
		Kit.corner(stageSheen, 11)
		Kit.new("UIGradient", {
			Transparency = NumberSequence.new(0.35, 1),
			Rotation = 90,
			Parent = stageSheen,
		})
		local scene: Scene = ShopScenes.pass(stage, name, tint)
		-- The text column sits above the stage (and anything its scene draws).
		local info = Kit.new("Frame", {
			Name = "Info",
			BackgroundTransparency = 1,
			Size = UDim2.fromScale(1, 1),
			ZIndex = 6,
			Parent = body,
		})
		local title = minText(Kit.title(info, {
			Name = "Title",
			Text = string.upper(pass.Title),
			TextSize = 30,
			MaxTextSize = 30,
			TextScaled = true,
			TextWrapped = false,
			Size = UDim2.new(1, -BANNER_TEXT_X, 0, 34),
			Position = UDim2.fromOffset(BANNER_TEXT_X, 10),
			TextXAlignment = Enum.TextXAlignment.Left,
			TextColor3 = Color3.new(1, 1, 1),
			StrokeThickness = 0,
			ZIndex = 6,
		}))
		Kit.new("UIStroke", {
			Thickness = 3,
			Color = Kit.darken(Kit.lip(tint), 0.3),
			LineJoinMode = Enum.LineJoinMode.Round,
			Parent = title,
		})
		-- The description sits on a darker inset of the banner's tint: plain white text, no
		-- outline (small text smudges under one), two lines at most.
		local inset = Kit.new("Frame", {
			Name = "Inset",
			BackgroundColor3 = Kit.darken(tint, BANNER_INSET_DEEP),
			BackgroundTransparency = BANNER_INSET,
			Size = UDim2.new(1, 0, 0, BANNER_DESC_H),
			Position = UDim2.fromOffset(0, BANNER_DESC_Y),
			ZIndex = 6,
			Parent = info,
		})
		Kit.corner(inset, 10)
		local desc = Kit.text(inset, {
			Name = "Desc",
			Text = pass.Desc,
			Font = F.Bold,
			TextSize = 16,
			TextWrapped = true,
			Size = UDim2.new(1, -BANNER_TEXT_X * 2, 1, -4),
			Position = UDim2.fromOffset(BANNER_TEXT_X, 2),
			TextXAlignment = Enum.TextXAlignment.Left,
			TextColor3 = Color3.new(1, 1, 1),
			StrokeThickness = 0,
			ZIndex = 6,
		})
		-- PERMANENT: a quiet tag on the same dark inset (no solid fill, no border), its text on
		-- the description's left edge.
		local perk = Kit.text(info, {
			Name = "Perk",
			Text = "PERMANENT",
			Font = F.UI,
			TextSize = MIN_TEXT,
			TextWrapped = false,
			TextColor3 = Color3.new(1, 1, 1),
			TextTransparency = 0.1,
			BackgroundColor3 = Kit.darken(tint, BANNER_INSET_DEEP),
			BackgroundTransparency = BANNER_INSET,
			Size = UDim2.fromOffset(math.ceil(ribbonTextWidth("PERMANENT") * MIN_TEXT / 16) + BANNER_TEXT_X * 2, 22),
			Position = UDim2.fromOffset(0, BANNER_PERK_Y),
			StrokeThickness = 0,
			ZIndex = 6,
		})
		Kit.round(perk)
		local button, sheen = priceButton(body, {
			Text = price(pass.Price),
			Size = UDim2.fromOffset(150, PRICE_H),
			Position = UDim2.new(1, -16, 0.5, 0),
			AnchorPoint = Vector2.new(1, 0.5),
		}, function()
			action:FireServer({ action = "PromptPass", name = name })
		end)
		-- Owned shows once, on the button ("✓ OWNED", greyed): no ribbon repeats it.
		local tagInfo = PASS_TAGS[name]
		local banner: Banner = {
			cell = cell,
			body = body,
			art = nil,
			artHolder = stage,
			button = button,
			sheen = sheen,
			clip = clip,
			tag = if tagInfo then ribbon(body, tagInfo.text, tagInfo.color) else nil,
			desc = desc,
			info = info,
			stage = stage,
			scene = scene,
		}
		hoverable(banner)
		table.insert(entries, banner)
		table.insert(cascade, cell)
		table.insert(scenes, scene)
		banners[name] = banner
		table.insert(bannerList, banner)
	end
	-- Fits a banner to the window: stage width, the text column between it and the price.
	local function placeBanner(banner: Banner, stageW: number, priceW: number)
		banner.stage.Size = UDim2.fromOffset(stageW, BANNER_H - 18)
		-- A wide gap: the scene's counters stop at the stage edge, the title starts well clear of it.
		local left = 9 + stageW + 28 - BANNER_TEXT_X
		banner.info.Position = UDim2.fromOffset(left, 0)
		banner.info.Size = UDim2.new(1, -(left + priceW + 16 + 14), 1, 0)
		banner.button.Size = UDim2.fromOffset(priceW, PRICE_H)
	end

	-- Section 2: cosmetics -------------------------------------------------------------
	sectionHead(2)
	-- Taps wait for the server; until its next snapshot (or 1.5 s) the card shows the choice.
	local pendingCos: { [string]: { value: any, at: number } } = {}
	local function shownChoice(key: string, serverValue: any): any
		local pending = pendingCos[key]
		if pending and os.clock() - pending.at < 1.5 and pending.value ~= serverValue then
			return pending.value
		end
		pendingCos[key] = nil
		return serverValue
	end

	-- All Cosmetics: a wide coral banner with every cosmetic it unlocks in a row.
	local bundlePass = Theme.Monetization.Passes[COS.Bundle]
	local bundleTint = Theme.World.Coral
	local bundleCell, bundleBody, bundleArtHolder, bundleArt =
		makeEntry(scroll, "Bundle", 0, bundleTint, COS.BundleIcon, "Crown", 100, UDim2.new(0, 68, 0.5, 0))
	local bundleClip = bannerPaint(bundleBody, bundleTint, WIDE_R, nil, true)
	wideText(bundleBody, bundleTint, string.upper(bundlePass.Title), "Everything below, forever")
	local included = 0
	for _, name in COS_ORDER do
		if not COS.Items[name].Starter then
			included += 1
		end
	end
	local includes = Kit.new("Frame", {
		Name = "Includes",
		BackgroundColor3 = Kit.darken(bundleTint, BANNER_INSET_DEEP),
		BackgroundTransparency = BANNER_INSET,
		Size = UDim2.fromOffset(included * 40 - 6 + 16, 44),
		Position = UDim2.fromOffset(WIDE_LEFT, 64),
		ZIndex = 4,
		Parent = bundleBody,
	})
	Kit.corner(includes, 12)
	Kit.padding(includes, 5, 8)
	Kit.list(includes, 6, true).VerticalAlignment = Enum.VerticalAlignment.Center
	for i, name in COS_ORDER do
		local item = COS.Items[name]
		if not item.Starter then
			Kit.icon(includes, Kit.pickIcon(item.Icon, "Star"), 34, item.Color, { Name = name, LayoutOrder = i, ZIndex = 4 })
		end
	end
	local bundleButton, bundleSheen = widePrice(bundleBody, price(bundlePass.Price), function()
		action:FireServer({ action = "PromptPass", name = COS.Bundle })
	end)
	local saving = bundleSaving()
	local bundleSave = ribbon(bundleBody, string.format("SAVE %d%%", saving), RIBBON_SUNNY)
	bundleSave.Visible = saving > 0
	local bundleEntry: Entry = {
		cell = bundleCell,
		body = bundleBody,
		art = bundleArt,
		artHolder = bundleArtHolder,
		button = bundleButton,
		sheen = bundleSheen,
		clip = bundleClip,
	}
	hoverable(bundleEntry)
	table.insert(entries, bundleEntry)
	local bundleWasOwned: boolean? = nil

	-- One card per cosmetic. Owned trails show EQUIP / EQUIPPED, owned perks and wearables an
	-- on/off switch; a Starter-only item stays locked until the Starter pack is owned.
	local cosGrid = Kit.new("Frame", { Name = "Cosmetics", BackgroundTransparency = 1, Parent = scroll })
	local cosLayout = Kit.new("UIGridLayout", {
		CellSize = UDim2.new(1 / 3, -11, 0, COS_H),
		CellPadding = UDim2.fromOffset(GAP, GAP),
		SortOrder = Enum.SortOrder.LayoutOrder,
		Parent = cosGrid,
	})
	type CosCard = PassCard & {
		lock: GuiObject?,
		control: Frame?,
		setSwitch: ((boolean, boolean?) -> ())?,
		switchShown: boolean?,
		-- The switch beside the price (true) or in its place (false): see refreshCosmetics.
		beside: boolean?,
	}
	local cosCards: { [string]: CosCard } = {}
	local function cosTap(name: string)
		local data = State.data
		if not data then
			return
		end
		local cos = cosmeticsOf(data)
		local item = COS.Items[name]
		if cos.owned[name] then
			if item.Kind == "trail" then
				local current = shownChoice("trail", cos.trail or "")
				local value = if current == name then "" else name
				pendingCos.trail = { value = value, at = os.clock() }
				action:FireServer({ action = "EquipTrail", name = value })
				refresh()
			end
		elseif item.Starter then
			-- Only the Starter pack gives it: bring that card into view.
			scrollTo(0)
			Kit.pop(starterCell, 1)
		elseif item.Pass then
			action:FireServer({ action = "PromptPass", name = item.Pass })
		end
	end
	for order, name in COS_ORDER do
		local item = COS.Items[name]
		local pass = item.Pass and Theme.Monetization.Passes[item.Pass]
		local tint = COS_TINTS[name] or item.Color
		local card = tileCard(
			cosGrid,
			name,
			order,
			tint,
			{ item.Icon, "Star" },
			item.Title,
			if item.Starter then "Starter Pack exclusive" else item.Desc,
			if pass then price(pass.Price) else "STARTER PACK",
			function()
				cosTap(name)
			end
		) :: CosCard
		if item.Starter then
			card.tag = ribbon(card.body, "EXCLUSIVE", RIBBON_PINK)
			card.lock = Kit.icon(card.body, "Lock", 30, C.Text, {
				Name = "Lock",
				Position = UDim2.fromOffset(14, 12),
				ZIndex = 5,
			})
		end
		if item.Kind ~= "trail" then
			-- Owned perk / wearable: "ACTIVE" with an on/off switch where the price was.
			local control = Kit.new("Frame", {
				Name = "Control",
				BackgroundColor3 = Kit.darken(tint, 0.34),
				BackgroundTransparency = INSET,
				Size = UDim2.new(1, -20, 0, 42),
				Position = UDim2.new(0, 10, 1, -10),
				AnchorPoint = Vector2.new(0, 1),
				Visible = false,
				ZIndex = 4,
				Parent = card.body,
			})
			Kit.corner(control, 12)
			Kit.text(control, {
				Name = "Label",
				Text = "ACTIVE",
				Font = F.UI,
				TextSize = 17,
				TextWrapped = false,
				Size = UDim2.new(1, -90, 1, 0),
				Position = UDim2.fromOffset(14, 0),
				TextXAlignment = Enum.TextXAlignment.Left,
				TextColor3 = Color3.new(1, 1, 1),
				ZIndex = 5,
			})
			local toggle, set = Kit.switch(control, {
				Name = "Toggle",
				Position = UDim2.new(1, -8, 0.5, 0),
				AnchorPoint = Vector2.new(1, 0.5),
			}, function()
				local data = State.data
				if not data then
					return
				end
				local cos = cosmeticsOf(data)
				if not (cos.owned[name] or cos.canSwitch[name]) then
					return
				end
				local value = not shownChoice(name, cos.toggles[name] ~= false)
				pendingCos[name] = { value = value, at = os.clock() }
				action:FireServer({ action = "ToggleCosmetic", name = name, value = value })
				refresh()
			end)
			-- The switch's ON / OFF word at 14 px: all the small switch's track has room for.
			local state = toggle:FindFirstChild("State")
			if state and state:IsA("TextLabel") then
				state.TextSize = MIN_SCALED
				state.TextWrapped = false
			end
			card.control = control
			card.setSwitch = set
		end
		cosCards[name] = card
	end

	--[[
		Sections 3-4: cash and aura pack cards. Each card: the pack's
		animated stage (ShopScenes.pack) on a soft halo, the amount this player
		gets (it rolls when it changes), a short caption and the price button.
		The cards sit on a deep version of the section colour so the mint price
		buttons stay the brightest thing on them.
	]]
	type Pack = Entry & { amount: TextLabel, sub: TextLabel, scene: Scene, place: (number, number) -> () }
	type PackGrid = {
		grid: Frame,
		layout: UIGridLayout,
		count: number,
		wide: number,
		narrow: number,
		columns: number,
		cardW: number,
		cardH: number,
		packs: { Pack },
	}
	local packGrids: { PackGrid } = {}
	-- `wide` / `narrow`: columns on a wide / narrow window (the cell size follows them; a row
	-- with fewer cards than columns is centred).
	local function packGrid(name: string, packCount: number, wide: number, narrow: number): PackGrid
		local grid = Kit.new("Frame", { Name = name, BackgroundTransparency = 1, Parent = scroll })
		local gridLayout = Kit.new("UIGridLayout", {
			CellSize = UDim2.new(1 / wide, 0, 0, PACK_H),
			CellPadding = UDim2.fromOffset(GAP, GAP),
			SortOrder = Enum.SortOrder.LayoutOrder,
			HorizontalAlignment = Enum.HorizontalAlignment.Center,
			Parent = grid,
		})
		local packs: PackGrid = {
			grid = grid,
			layout = gridLayout,
			count = packCount,
			wide = wide,
			narrow = narrow,
			columns = wide,
			cardW = 180,
			cardH = PACK_H,
			packs = {},
		}
		table.insert(packGrids, packs)
		return packs
	end
	--[[
		Amounts are the hero of a pack card: the currency icon and a big bold number
		in the pack colour with a dark outline. The number's size follows its length
		and the card width (28 px, never under 24 px for the short number format), and grows
		with a card taller than PACK_H.
	]]
	local amountGrid: { [TextLabel]: PackGrid } = {}
	local function fitAmount(label: TextLabel, text: string)
		local packs = amountGrid[label]
		local room = (if packs then packs.cardW else 180) - 20 - PACK_ICON - 4
		local top = math.floor(28 * math.clamp((if packs then packs.cardH else PACK_H) / PACK_H, 1, 1.25))
		label.TextSize = math.clamp(math.floor(room / (0.68 * math.max(#text, 1))), 16, top)
	end
	local function setAmount(label: TextLabel, text: string)
		fitAmount(label, text)
		label.Text = text
	end
	local function packCard(
		packs: PackGrid,
		kind: string,
		index: number,
		packPrice: number,
		accent: Color3,
		amountColor: Color3,
		icon: string
	): Pack
		local grid = packs.grid
		local cell = Kit.new("Frame", { Name = kind .. index, BackgroundTransparency = 1, LayoutOrder = index, Parent = grid })
		local radius = Kit.RADIUS.L
		local deep = Kit.darken(accent, 0.45)
		local body = Kit.panel(cell, {
			Name = "Body",
			Glass = true,
			Color = deep,
			GlowColor = accent,
			Size = UDim2.fromScale(1, 1),
			Radius = radius,
		})
		local clip = bannerPaint(body, deep, radius, Kit.lighten(accent, 0.15))
		-- Glassy highlight along the top of the card.
		local shine = Kit.new("Frame", {
			Name = "Shine",
			BackgroundColor3 = Color3.new(1, 1, 1),
			BackgroundTransparency = 0.72,
			BorderSizePixel = 0,
			Size = UDim2.new(1, -12, 0, 30),
			Position = UDim2.fromOffset(6, 4),
			ZIndex = 2,
			Parent = body,
		})
		Kit.corner(shine, radius - 4)
		Kit.new("UIGradient", { Transparency = NumberSequence.new(0.3, 1), Rotation = 90, Parent = shine })
		-- A soft glow in the pack colour behind the stage, bigger and brighter up the ladder.
		local glowSize = math.floor(PACK_STAGE * (0.85 + 0.1 * index))
		local glowId = Sprites.image("SoftDot")
		local glowProps = {
			Name = "Halo",
			BackgroundTransparency = 1,
			Size = UDim2.fromOffset(glowSize, glowSize),
			Position = UDim2.new(0.5, 0, 0, 8 + PACK_STAGE // 2),
			AnchorPoint = Vector2.new(0.5, 0.5),
			ZIndex = 3,
			Parent = body,
		}
		local halo: GuiObject
		if glowId then
			local glow = Kit.new("ImageLabel", glowProps)
			glow.Image = glowId
			glow.ImageColor3 = Kit.lighten(accent, 0.2)
			glow.ImageTransparency = math.max(0.1, 0.5 - 0.1 * index)
			glow.ScaleType = Enum.ScaleType.Fit
			halo = glow
		else
			local glow = Kit.new("Frame", glowProps)
			glow.BackgroundColor3 = accent
			glow.BackgroundTransparency = math.max(0.45, 0.8 - 0.08 * index)
			Kit.round(glow)
			halo = glow
		end
		local stage = Kit.new("Frame", {
			Name = "Stage",
			BackgroundTransparency = 1,
			ClipsDescendants = true,
			Size = UDim2.fromOffset(PACK_STAGE, PACK_STAGE),
			Position = UDim2.new(0.5, 0, 0, 8),
			AnchorPoint = Vector2.new(0.5, 0),
			ZIndex = 4,
			Parent = body,
		})
		local scene: Scene = ShopScenes.pack(stage, kind, index)
		local amountRow = Kit.new("Frame", {
			Name = "AmountRow",
			BackgroundTransparency = 1,
			Size = UDim2.new(1, -12, 0, 32),
			Position = UDim2.fromOffset(6, PACK_STAGE + 8),
			ZIndex = 4,
			Parent = body,
		})
		Kit.list(amountRow, 4, true, Enum.HorizontalAlignment.Center).VerticalAlignment = Enum.VerticalAlignment.Center
		Kit.icon(amountRow, icon, PACK_ICON, iconColor(icon), { Name = "Icon", LayoutOrder = 1, ZIndex = 4 })
		local amount = Kit.number(amountRow, {
			Name = "Amount",
			Text = "",
			TextSize = 28,
			Size = UDim2.new(0, 0, 1, 0),
			AutomaticSize = Enum.AutomaticSize.X,
			TextColor3 = amountColor,
			LayoutOrder = 2,
			StrokeThickness = 0,
			ZIndex = 4,
		})
		Kit.new("UIStroke", {
			Thickness = 1.6,
			Color = C.Ink,
			ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual,
			LineJoinMode = Enum.LineJoinMode.Round,
			Parent = amount,
		})
		amountGrid[amount] = packs
		local sub = Kit.text(body, {
			Name = "Sub",
			Text = "",
			Font = F.Bold,
			TextSize = PACK_SUB,
			MinPx = PACK_SUB_PX,
			TextWrapped = false,
			TextTruncate = Enum.TextTruncate.AtEnd,
			Size = UDim2.new(1, -12, 0, 20),
			Position = UDim2.fromOffset(6, PACK_STAGE + 41),
			TextColor3 = Color3.new(1, 1, 1),
			ZIndex = 4,
		})
		outline(sub, deep)
		local pack: Pack
		local button, sheen = priceButton(body, {
			Text = price(packPrice),
			Size = UDim2.new(1, -16, 0, PRICE_H),
			Position = UDim2.new(0, 8, 1, -8),
			AnchorPoint = Vector2.new(0, 1),
		}, function()
			lastPrompt = { kind = kind, entry = pack, index = index, at = os.clock() }
			action:FireServer({ action = "PromptProduct", kind = kind, index = index })
		end)
		-- The card takes the height its grid hands it: the stage (square, the scene inside is
		-- laid out in scale) takes what the amount, caption and price leave, up to the card's
		-- width, and the rest of the column follows it.
		local function place(cardW: number, cardH: number)
			local side = math.floor(math.clamp(cardH - (PACK_H - PACK_STAGE), 72, math.max(72, cardW - 16)))
			-- Spare height (a card much taller than wide) goes above and below the column.
			local top = 8 + math.max(0, cardH - (PACK_H - PACK_STAGE) - side) // 2
			local haloSide = math.floor(side * (0.85 + 0.1 * index))
			stage.Size = UDim2.fromOffset(side, side)
			stage.Position = UDim2.new(0.5, 0, 0, top)
			halo.Size = UDim2.fromOffset(haloSide, haloSide)
			halo.Position = UDim2.new(0.5, 0, 0, top + side // 2)
			amountRow.Position = UDim2.fromOffset(6, top + side)
			sub.Position = UDim2.fromOffset(6, top + side + 33)
		end
		pack = {
			cell = cell,
			body = body,
			art = nil,
			artHolder = stage,
			button = button,
			sheen = sheen,
			clip = clip,
			amount = amount,
			sub = sub,
			scene = scene,
			place = place,
		}
		table.insert(packs.packs, pack)
		hoverable(pack)
		table.insert(entries, pack)
		table.insert(cascade, cell)
		table.insert(scenes, scene)
		return pack
	end
	-- Cash and aura: the second pack is the popular one, the biggest the best value.
	local function packTags(pack: Pack, index: number, total: number)
		if index == total then
			ribbon(pack.body, "BEST VALUE", RIBBON_CORAL)
		elseif index == 2 and total >= 3 then
			ribbon(pack.body, "POPULAR", RIBBON_SUNNY)
		end
	end

	sectionHead(3)
	local moneyPacks = Theme.Monetization.MoneyPacks
	local cashPacks = packGrid("Cash", #moneyPacks, math.min(#moneyPacks, 4), 2)
	local cashGrid = cashPacks.grid
	local moneyLabels: { TextLabel } = {}
	local moneyShown: { [number]: number } = {}
	for index, pack in moneyPacks do
		local card = packCard(cashPacks, "Money", index, pack.Price, C.Cash, C.MoneyText, "Coin")
		moneyLabels[index] = card.amount
		card.sub.Text = string.format("%s of income", durationText(pack.Seconds))
		packTags(card, index, #moneyPacks)
	end

	sectionHead(4)
	local auraPacks = Theme.Monetization.AuraPacks
	local auraPackGrid = packGrid("Aura", #auraPacks, math.min(#auraPacks, 4), 2)
	local auraGrid = auraPackGrid.grid
	local auraLabels: { TextLabel } = {}
	local auraShown: { [number]: number } = {}
	for index, pack in auraPacks do
		-- The stage shows the pack's aura; the number is the cash it is blended into.
		local card = packCard(auraPackGrid, "Aura", index, pack.Price, C.Violet, C.MoneyText, "Coin")
		auraLabels[index] = card.amount
		card.sub.Text = string.format("%s of %s", durationText(pack.Seconds), string.lower(W.Orb))
		packTags(card, index, #auraPacks)
	end

	-- Layout: explicit positions so the switcher knows where each section starts,
	-- and the grids reflow (cosmetics 3 -> 2 columns, cash and aura 4 -> 2) when the window narrows.
	local columnsNow = 3
	local gridTop: { [Frame]: number } = {}
	local headY: { number } = {} -- canvas height of each section header
	local passesY = 0
	-- Marks the end of the page, so the bottom can be found from on-screen positions.
	local pageEnd = Kit.new("Frame", {
		Name = "PageEnd",
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(1, 0),
		Parent = scroll,
	})
	local function gridH(cards: number, columns: number, cellH: number): number
		local rows = math.ceil(cards / columns)
		return rows * cellH + (rows - 1) * GAP
	end
	local function cellSize(columns: number, cellH: number): UDim2
		return UDim2.new(1 / columns, -math.ceil(GAP * (columns - 1) / columns), 0, cellH)
	end
	function layout(size: Vector2)
		local wide = size.X >= 760
		local columns = if wide then 3 else 2
		columnsNow = columns
		cosLayout.CellSize = cellSize(columns, COS_H)
		-- A short page (a phone) has no room for a section header over its cards: the tab
		-- already names the section, so the cards are the page.
		local page = pageH()
		local short = page < PAGE_SHORT
		-- Free height for a row of pack cards: the page under its top padding and header.
		local free = page - PAGE_PAD - PAGE_FIT_BOTTOM - (if short then 0 else HEAD_H + 14)
		local packFits: { boolean } = {}
		for i, packs in packGrids do
			packs.columns = if wide then packs.wide else packs.narrow
			packs.cardW = (size.X - 62 - 18 - GAP * (packs.columns - 1)) / packs.columns
			-- One row of packs fills the page instead of leaving its lower half empty: on a
			-- short page the cards take all of it (buy button and ribbon in view, nothing to
			-- scroll), otherwise PACK_FILL of it up to PACK_MAX_H, centred under the header.
			packFits[i] = packs.count <= packs.columns
			packs.cardH = if packFits[i]
				then math.floor(math.clamp(if short then free else free * PACK_FILL, 180, PACK_MAX_H))
				else math.min(PACK_H, math.max(180, free))
			packs.layout.CellSize = cellSize(packs.columns, packs.cardH)
			for _, pack in packs.packs do
				pack.place(packs.cardW, packs.cardH)
			end
		end
		for label in amountGrid do
			if label.Text ~= "" then
				fitAmount(label, label.Text)
			end
		end
		-- Banners: the page width (window minus the well's inset, padding and scrollbar
		-- gutter) sets the stage width; the text column keeps at least ~240 px.
		local pageW = size.X - 62
		local stageW = math.clamp(pageW - 568, STAGE_MIN_W, STAGE_W)
		local priceW = if wide then 150 else 132
		for _, banner in bannerList do
			placeBanner(banner, stageW, priceW)
		end
		-- One section per tab: the picked one is laid out from the top of the page, the others
		-- are hidden. The free card heads the Passes tab, over the Starter card.
		-- `before`: room above the block (a row of cards centred in the page). `fills`: the
		-- block was sized to the page, which then ends with it.
		type Block = { gui: GuiObject, h: number, gapAfter: number, head: boolean?, shown: boolean?, before: number?, fills: boolean? }
		local pages: { { Block } } = {
			{
				-- Free first, then the Starter card; without the header they lead the one list.
				{ gui = freeCell, h = FREE_H, gapAfter = GAP },
				{ gui = starterCell, h = STARTER_H, gapAfter = if short then GAP else STARTER_GAP, shown = starterShown },
				{ gui = heads[1], h = HEAD_H, gapAfter = PASSES_HEAD_GAP, head = true, shown = not short },
				{ gui = passList, h = gridH(#bannerList, 1, BANNER_H), gapAfter = 26 },
			},
			{
				{ gui = heads[2], h = HEAD_H, gapAfter = 14, head = true, shown = not short },
				{ gui = bundleCell, h = BUNDLE_H, gapAfter = GAP + 6 },
				{ gui = cosGrid, h = gridH(#COS_ORDER, columns, COS_H), gapAfter = 26 },
			},
		}
		for i, grid in { cashGrid, auraGrid } do
			local packs = packGrids[i]
			local fits = packFits[i]
			table.insert(pages, {
				{ gui = heads[2 + i], h = HEAD_H, gapAfter = 14, head = true, shown = not short },
				{
					gui = grid,
					h = gridH(packs.count, packs.columns, packs.cardH),
					gapAfter = 26,
					before = if fits then math.max(0, free - packs.cardH) // 2 else 0,
					fills = fits,
				},
			})
		end
		-- Rows are placed from 0: the page's UIPadding (PAGE_PAD) keeps a ribbon that
		-- overlaps the top edge of the first card inside the clip.
		local pageBottom = 0
		local filled = false
		for index, blocks in pages do
			local picked = index == current
			local y = 0
			for _, block in blocks do
				local shown = block.shown ~= false
				block.gui.Visible = picked and shown
				-- A hidden header hands its place (what a focus scrolls to) to the block after it.
				if block.head then
					headY[index] = y
				end
				if shown then
					y += block.before or 0
					block.gui.Position = UDim2.fromOffset(4, y - (if picked then previewShift else 0))
					block.gui.Size = UDim2.new(1, -18, 0, block.h)
					if block.gui:IsA("Frame") then
						gridTop[block.gui] = y
					end
					if picked then
						pageBottom = y + block.h
						filled = block.fills == true
					end
					y += block.h + block.gapAfter
				end
			end
			-- Every tab opens at its own top.
			sectionY[index] = 0
		end
		-- Banner focus scrolls to the Passes header (under the Starter card).
		passesY = headY[1] or 0
		-- The canvas is the section and no more: the last row ends PAGE_BOTTOM above the edge
		-- when scrolled to the end. A section that fits does not scroll at all: no wheel or
		-- drag, no scroll bar.
		canvasH = if filled then page else PAGE_PAD + pageBottom + PAGE_BOTTOM
		local scrolls = canvasH > page + 1
		pageEnd.Position = UDim2.fromOffset(0, canvasH - PAGE_PAD - previewShift)
		scroll.CanvasSize = UDim2.fromOffset(0, canvasH)
		scroll.ScrollingEnabled = scrolls
		scroll.ScrollBarThickness = if scrolls then SCROLL_BAR else 0
		-- The switcher keeps its pills roomy but never wider than the page; narrow pills
		-- drop their icons so the labels stay at full size.
		local switchW = math.min(150 * count, size.X - 44)
		switcher.Size = UDim2.fromOffset(switchW, SWITCH_H)
		for _, icon in pillIcons do
			icon.Visible = switchW / count >= 140
		end
	end
	layout(window.size())
	window.onResize.Event:Connect(layout)

	-- Canvas height that brings item `order` of `grid` into view (its section header for the first row).
	local function cardY(grid: Frame, order: number, headY: number, cellH: number, columns: number): number
		local row = (order - 1) // columns
		if row == 0 then
			return headY
		end
		return (gridTop[grid] or 0) + row * (cellH + GAP) - 12
	end

	--[[
		The section in view is the picked tab (each tab is its own page). What scrolling
		changes is the shade along the bottom edge: it shows while the page goes on and
		fades out at its end, measured from where the page end really is on screen (so
		window and screen scaling cannot skew it).
	]]
	local function sectionInView(): number
		local page = pageH()
		local endOffset: number
		local scale = if PREVIEW then 0 else scroll.AbsoluteSize.Y / math.max(1, page)
		if scale > 0.05 then
			endOffset = (pageEnd.AbsolutePosition.Y - scroll.AbsolutePosition.Y) / scale
		else
			endOffset = canvasH - (if PREVIEW then previewShift else scroll.CanvasPosition.Y)
		end
		showFade(endOffset > page + 2)
		return current
	end
	function syncSection()
		setCurrent(sectionInView(), window.isOpen())
	end
	-- Scrolling re-checks on the next frame, once the engine has placed the page.
	local syncQueued = false
	scroll:GetPropertyChangedSignal("CanvasPosition"):Connect(function()
		if PREVIEW or syncQueued or not window.isOpen() or os.clock() < pinUntil then
			return
		end
		syncQueued = true
		RunService.Heartbeat:Once(function()
			syncQueued = false
			if window.isOpen() and os.clock() >= pinUntil then
				syncSection()
			end
		end)
	end)

	-- Wallet ---------------------------------------------------------------------------
	local chipMoney: number? = nil
	local chipAura: number? = nil

	-- Coins or orbs fly from a row to their half of the header wallet.
	local function flyTo(from: GuiObject, chipLabel: TextLabel, icon: string, color: Color3)
		if PREVIEW then
			return
		end
		local mine = session
		local start = centreOf(from)
		local finish = centreOf(chipLabel.Parent :: GuiObject)
		for i = 1, 7 do
			local piece = Kit.icon(frame, icon, 26, color, {
				Name = "Fly",
				Position = UDim2.fromOffset(start.X + math.random(-24, 24), start.Y + math.random(-14, 14)),
				AnchorPoint = Vector2.new(0.5, 0.5),
				ZIndex = 40,
			})
			task.delay(i * 0.05, function()
				if session ~= mine then
					piece:Destroy()
					return
				end
				Kit.tween(
					piece,
					0.5,
					{ Position = UDim2.fromOffset(finish.X, finish.Y), Size = UDim2.fromOffset(16, 16) },
					Enum.EasingStyle.Quad,
					Enum.EasingDirection.In
				)
				task.delay(0.5, function()
					piece:Destroy()
					if i == 1 and session == mine then
						Kit.pop(chipLabel.Parent :: GuiObject, 1)
					end
				end)
			end)
		end
	end

	-- A card just became owned while the shop is open: it pops and its OWNED ribbon lands.
	local function celebrate(card: PassCard, delay: number, burst: boolean)
		local function go()
			if not window.isOpen() then
				card.owned.Visible = true
				return
			end
			Kit.pop(card.cell, 1.6)
			Kit.appear(card.owned, { from = 0.4, time = 0.3 })
			if burst then
				local spot = centreOf(card.cell)
				Kit.confetti(frame, { Origin = UDim2.fromOffset(spot.X, spot.Y), Count = 24, ZIndex = 45 })
				Kit.sound("Reward")
			end
		end
		if delay > 0 and not PREVIEW then
			task.delay(delay, go)
		else
			go()
		end
	end

	-- Starter card, All Cosmetics card and cosmetic cards from the snapshot.
	local function refreshCosmetics(data: { [string]: any }, open: boolean)
		local cos = cosmeticsOf(data)

		-- Starter pack: this player's amounts roll; a purchase celebrates, then the card folds away.
		local starterOwned = cos.starterOwned == true
		local starterJust = starterOwned and starterWasOwned == false and open
		local cash = Windows.starterAmounts(data)
		if starterShownCash and starterShownCash ~= cash and open then
			Kit.countTo(starterCash, starterShownCash, cash, State.money)
		elseif starterShownCash ~= cash then
			starterCash.Text = State.money(cash)
		end
		starterShownCash = cash
		Kit.setEnabled(starterButton, not starterOwned)
		Kit.setButton(starterButton, if starterOwned then "✓ OWNED" else price(starterPass.Price))
		starterTag.Visible = not starterOwned
		if starterOwned and starterShown then
			local mine = session
			local function fold()
				starterShown = false
				layout(window.size())
			end
			if starterJust and not PREVIEW then
				local spot = centreOf(starterCell)
				Kit.pop(starterCell, 1.6)
				Kit.confetti(frame, { Origin = UDim2.fromOffset(spot.X, spot.Y), Count = 30, ZIndex = 45 })
				Kit.sound("Reward")
				task.delay(1.6, function()
					if session ~= mine then
						fold()
						return
					end
					Kit.disappear(starterCell, { to = 0.9, time = 0.25, onDone = fold })
				end)
			else
				fold()
			end
		elseif not starterOwned and not starterShown then
			starterShown = true
			layout(window.size())
		end
		starterWasOwned = starterOwned

		-- All Cosmetics: owning it flips every card at once in one cascade.
		local bundleOwned = cos.bundleOwned == true
		local bundleJust = bundleOwned and bundleWasOwned == false and open
		Kit.setEnabled(bundleButton, not bundleOwned)
		Kit.setButton(bundleButton, if bundleOwned then "✓ OWNED" else price(bundlePass.Price))
		bundleSave.Visible = not bundleOwned and saving > 0
		if bundleJust then
			local spot = centreOf(bundleCell)
			Kit.pop(bundleCell, 1.6)
			Kit.confetti(frame, { Origin = UDim2.fromOffset(spot.X, spot.Y), Count = 36, ZIndex = 45 })
			Kit.pop(bundleButton, 1)
			Kit.sound("Reward")
		end
		bundleWasOwned = bundleOwned

		local trail = shownChoice("trail", cos.trail or "")
		local wave = 0
		for _, name in COS_ORDER do
			local card = cosCards[name]
			local item = COS.Items[name]
			local owned = cos.owned[name] == true
			-- The switch is the owner's and, on the Chad Aura, a Champion's too (the server's
			-- `canSwitch`): the Index's aura goes off here without the pass. A Champion who has
			-- not bought the pass keeps its price button: the switch moves to the left of it.
			local switched = owned or cos.canSwitch[name] == true
			local beside = switched and not owned and item.Pass ~= nil and card.control ~= nil
			if card.lock then
				card.lock.Visible = not owned
			end
			if card.tag then
				card.tag.Visible = not owned
			end
			card.desc.Text = if item.Starter and not owned then "Starter Pack exclusive" else item.Desc
			local control = card.control
			if owned and item.Kind == "trail" then
				local on = trail == name
				Kit.setEnabled(card.button, true)
				Kit.setButton(card.button, if on then "✓ EQUIPPED" else "EQUIP", if on then C.Gold else C.Cash)
			elseif switched and control and card.setSwitch then
				local on = shownChoice(name, cos.toggles[name] ~= false) == true
				if card.switchShown ~= on then
					card.switchShown = on
					card.setSwitch(on)
				end
				if beside then
					Kit.setEnabled(card.button, true)
					Kit.setButton(card.button, price(Theme.Monetization.Passes[item.Pass].Price), C.Cash)
				end
			elseif item.Pass then
				local pass = Theme.Monetization.Passes[item.Pass]
				Kit.setEnabled(card.button, true)
				Kit.setButton(card.button, price(pass.Price), C.Cash)
			else
				Kit.setEnabled(card.button, true)
				Kit.setButton(card.button, "STARTER PACK", C.SurfaceHi)
			end
			card.button.Visible = beside or not (switched and control ~= nil)
			if control then
				control.Visible = switched
				if card.beside ~= beside then
					-- Beside the price: the switch alone on its dark pane (COS_SWITCH_W wide), the
					-- button on the rest of the row. Alone: the pane spans the row, with ACTIVE.
					card.beside = beside
					local label = control:FindFirstChild("Label")
					if label and label:IsA("GuiObject") then
						label.Visible = not beside
					end
					control.Size = if beside then UDim2.fromOffset(COS_SWITCH_W, PRICE_H) else UDim2.new(1, -20, 0, PRICE_H)
					card.button.Size = if beside then UDim2.new(1, -(COS_SWITCH_W + 28), 0, PRICE_H) else UDim2.new(1, -20, 0, PRICE_H)
					card.button.Position = if beside then UDim2.new(0, COS_SWITCH_W + 18, 1, -10) else UDim2.new(0, 10, 1, -10)
				end
			end
			if owned and card.wasOwned == false and open then
				-- With the bundle, every card flips in one wave; a single purchase bursts on its own
				-- (the Starter pack's trail lets the Starter card do the bursting).
				wave += 1
				celebrate(card, if bundleJust then wave * 0.07 else 0, not bundleJust and not (item.Starter and starterJust))
			else
				card.owned.Visible = owned
			end
			card.wasOwned = owned
		end
	end

	function refresh()
		local data = State.data
		if not data then
			return
		end
		local open = window.isOpen()
		-- The wallet rolls; a landed purchase (cash and aura packs both pay cash) or free gift
		-- flies in from its card. The wallet also grows from collecting, so only a jump of
		-- about the card's size counts.
		local money, carried = data.money, data.carried or 0
		if chipMoney and money ~= chipMoney and open then
			Kit.countTo(cashChip, chipMoney, money, State.money)
			local prompt = lastPrompt
			if prompt and money > chipMoney then
				local expected: number? = if prompt.kind == "Money"
					then moneyShown[prompt.index]
					elseif prompt.kind == "Aura" then auraShown[prompt.index]
					else freeShownCash
				local within = if prompt.kind == "Free" then 5 else 120
				if os.clock() - prompt.at < within and money - chipMoney >= (expected or 0) * 0.5 then
					flyTo(prompt.entry.button, cashChip, "Coin", C.Gold)
					lastPrompt = nil
				end
			end
		elseif money ~= chipMoney then
			cashChip.Text = State.money(money)
		end
		if chipAura and carried ~= chipAura and open then
			Kit.countTo(auraChip, chipAura, carried, State.num)
		elseif carried ~= chipAura then
			auraChip.Text = State.num(carried)
		end
		chipMoney, chipAura = money, carried
		refreshFree()

		-- Each player sees their own pack sizes (the server grants with the same functions and
		-- the same surge-free income and production: State.rewardIncome / rewardProduction).
		local progression = Economy.progression(data.highestTier or 1, data.processLevel or 0)
		for index, pack in moneyPacks do
			local amount = Economy.moneyPackAmount(data.rewardIncome or data.income or 0, pack.Seconds, pack.Min, progression)
			local shown = moneyShown[index]
			moneyShown[index] = amount
			if shown and shown ~= amount and open then
				fitAmount(moneyLabels[index], State.num(amount))
				Kit.countTo(moneyLabels[index], shown, amount, State.num)
			elseif shown ~= amount then
				setAmount(moneyLabels[index], State.num(amount))
			end
		end
		-- An aura pack is blended into cash at once: the card shows that cash, with the same
		-- money multiplier the server pays with (State.moneyMult).
		local moneyMult = tonumber(data.moneyMult) or 1
		for index, pack in auraPacks do
			local aura = Economy.auraPackAmount(data.rewardProduction or data.production or 0, pack.Seconds, pack.Min, progression)
			local amount = ShopMath.auraPackCash(aura, moneyMult)
			local shown = auraShown[index]
			auraShown[index] = amount
			if shown and shown ~= amount and open then
				fitAmount(auraLabels[index], State.num(amount))
				Kit.countTo(auraLabels[index], shown, amount, State.num)
			elseif shown ~= amount then
				setAmount(auraLabels[index], State.num(amount))
			end
		end
		for name, banner in banners do
			local pass = Theme.Monetization.Passes[name]
			local owned = data.passes[name] == true
			-- Crate Master opens paid random items: not sold where those are restricted.
			local blocked = name == "CrateKey" and not owned and data.crateRobux ~= true
			if banner.tag then
				banner.tag.Visible = not owned
			end
			Kit.setEnabled(banner.button, not owned and not blocked)
			Kit.setButton(banner.button, if owned then "✓ OWNED" elseif blocked then "UNAVAILABLE" else price(pass.Price))
			banner.desc.Text = if blocked then "Not available here" else pass.Desc
			if owned and banner.wasOwned == false and open then
				-- Just bought: the banner celebrates, its scene throws a party and the button turns to OWNED.
				Kit.pop(banner.cell, 1.2)
				banner.scene.celebrate()
				local spot = centreOf(banner.cell)
				Kit.confetti(frame, { Origin = UDim2.fromOffset(spot.X, spot.Y), Count = 24, ZIndex = 45 })
				Kit.pop(banner.button, 1)
				Kit.sound("Reward")
			end
			banner.wasOwned = owned
		end
		refreshCosmetics(data, open)
	end
	State.changed.Event:Connect(refresh)

	-- Idle motion while open: every scene plays, static art bobs out of phase, ribbons
	-- breathe, banners catch a slow sheen, the header drifts through candy colours,
	-- and one price button at a time gets a sheen.
	local function startIdle()
		if PREVIEW then
			return
		end
		local mine = session
		for _, scene in scenes do
			scene.play()
			table.insert(idleStops, scene.stop)
		end
		for _, idle in idleTweens do
			idle.tween:Play()
			table.insert(idleStops, function()
				idle.tween:Cancel()
				for key, value in idle.rest do
					(idle.gui :: any)[key] = value
				end
			end)
		end
		table.insert(idleStops, Kit.shimmer(headerSheen, 6, 2))
		for i, entry in entries do
			local art = entry.art
			if art then
				local base = art.Position
				local tween = TweenService:Create(
					art,
					TweenInfo.new(1.6 + (i % 3) * 0.2, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true, (i % 5) * 0.3),
					{ Position = base + UDim2.fromOffset(0, -4) }
				)
				tween:Play()
				table.insert(idleStops, function()
					tween:Cancel()
					Kit.tween(art, 0.15, { Position = base })
				end)
			end
			if entry.clip and entry.cell.Visible then
				table.insert(idleStops, Kit.shimmer(entry.clip, ENTRY_SHINE.Every + (i % 4) / 3 * ENTRY_SHINE.Spread, 3, ENTRY_SHINE))
			end
		end
		-- The BEST VALUE card of each pack grid: a wide, slow sheen on top of its own.
		for _, grid in packGrids do
			local best = grid.packs[#grid.packs]
			if best and best.clip and best.cell.Visible then
				table.insert(idleStops, Kit.shimmer(best.clip, BEST_SHINE.Every, 4, BEST_SHINE))
			end
		end
		local tagged: { { tag: TextLabel? } } = {}
		for _, banner in bannerList do
			table.insert(tagged, banner)
		end
		for _, card in cosCards do
			table.insert(tagged, card)
		end
		for _, card in tagged do
			local tag = card.tag
			if tag and tag.Visible then
				table.insert(idleStops, Kit.breathe(tag, 0.05))
			end
		end
		task.spawn(function()
			local turn = 0
			task.wait(1.2)
			while session == mine do
				for _ = 1, #entries do
					turn = turn % #entries + 1
					local entry = entries[turn]
					local state = entry.button.Active and entry.button.Visible and entry.cell.Visible and entry.sheen
					if state then
						local sheen = entry.sheen :: Frame
						sheen.Position = UDim2.new(0, -40, -0.3, 0)
						Kit.tween(sheen, 0.7, { Position = UDim2.new(1, 20, -0.3, 0) }, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut)
						break
					end
				end
				task.wait(2.2)
			end
		end)
	end
	-- Closing (or reopening) stops every idle loop: scenes, tweens, sheens and timers.
	local function stopIdle()
		session += 1
		for _, stop in idleStops do
			stop()
		end
		table.clear(idleStops)
	end
	window.onClose.Event:Connect(stopIdle)

	focusPick.Shop = function()
		return shopFocusButton
	end
	beforeOpen.Shop = function()
		stopIdle()
		local mine = session
		refresh()
		-- The free card's countdowns tick between snapshots while the shop is open.
		if not PREVIEW then
			task.spawn(function()
				while session == mine do
					task.wait(0.5)
					if session == mine then
						refreshFree()
					end
				end
			end)
		end
		local focus = Windows.shopFocus or screen:GetAttribute("ShopFocus")
		Windows.shopFocus = nil
		screen:SetAttribute("ShopFocus", nil)
		-- Where the page opens: the focused banner, card or section, otherwise the top.
		local index = 1
		local y = 0
		local focusCell: GuiObject? = nil
		local passOrder: number? = nil
		local cosOrder: number? = nil
		if type(focus) == "string" then
			for i, section in SECTIONS do
				if section.key == focus then
					index = i
				end
			end
			passOrder = table.find(Theme.Monetization.PassOrder, focus)
			cosOrder = table.find(COS_ORDER, focus)
			if passOrder and banners[focus] then
				focusCell = banners[focus].cell
			elseif focus == COS.Starter.Pass and starterShown then
				focusCell = starterCell
			elseif focus == COS.Bundle then
				index = 2
				focusCell = bundleCell
			elseif cosOrder then
				index = 2
				focusCell = cosCards[focus].cell
			end
		end
		-- The focused card's tab is laid out first: its rows are measured on that page.
		previewShift = 0
		current = index
		layout(window.size())
		if focusCell == starterCell then
			-- Scrolled only as far as the whole Starter card needs: the free card stays over it when both fit.
			y = math.max(0, PAGE_PAD + (gridTop[starterCell] or 0) + STARTER_H + PAGE_FIT_BOTTOM - pageH())
		elseif focusCell and passOrder then
			y = cardY(passList, passOrder, passesY, BANNER_H, 1)
		elseif focusCell and cosOrder then
			-- The first cosmetics row sits under the All Cosmetics card.
			y = cardY(cosGrid, cosOrder, 0, COS_H, columnsNow)
		end
		scrollTo(y, true)
		setCurrent(index, false)
		showFade(math.min(y, maxScroll()) < maxScroll() - 2)
		-- Gamepad: opened at a card, the selection starts on its buy button.
		shopFocusButton = nil
		if focusCell then
			for _, entry in entries do
				if entry.cell == focusCell then
					shopFocusButton = entry.button
				end
			end
		end

		-- Opening choreography: section headers slide in, cards and banners ripple in the first time (scale +
		-- fade, 28 ms apart), the cart lands a beat later with an overshoot and wiggle.
		for i, head in heads do
			-- Not a header the layout has hidden (a short page, a phone, has none): Kit.appear
			-- would show it again, over the first card.
			if not PREVIEW and i == current and head.Visible then
				local target = head.Position
				head.Position = target + UDim2.fromOffset(-24, 0)
				Kit.tween(head, 0.32, { Position = target }, Enum.EasingStyle.Back)
				Kit.appear(head, { from = 1, time = 0.2 })
			end
		end
		local shown: { GuiObject } = {}
		for _, cell in cascade do
			if cell.Visible then
				table.insert(shown, cell)
			end
		end
		Kit.stagger(firstTime(shown), 0.028)
		if not PREVIEW then
			cartScale.Scale = 0
			cart.Rotation = -18
			task.delay(0.14, function()
				if session ~= mine then
					cartScale.Scale = 1
					cart.Rotation = 0
					return
				end
				Kit.tween(cartScale, 0.34, { Scale = 1 }, Enum.EasingStyle.Back)
				Kit.tween(cart, 0.16, { Rotation = 10 }, Enum.EasingStyle.Quad)
				task.delay(0.16, function()
					Kit.tween(cart, 0.3, { Rotation = 0 }, Enum.EasingStyle.Back)
				end)
			end)
			task.delay(0.5, function()
				if session ~= mine then
					return
				end
				startIdle()
				if focusCell then
					Kit.pop(focusCell, 1)
				end
			end)
		end
	end

	-- Kept for callers that pick a section by name ("Passes", "Cosmetics", "Cash", "Aura").
	Windows.selectShopTab = function(key: string)
		for i, section in SECTIONS do
			if section.key == key then
				scrollToSection(i, true)
				setCurrent(i, false)
			end
		end
	end
end

-- Index -----------------------------------------------------------------------------

-- Where the sparkle stars burst around a freshly discovered card (card scale).
local SPARKLE_SPOTS = {
	{ 0.12, 0.18, 18 },
	{ 0.86, 0.14, 22 },
	{ 0.5, 0.06, 14 },
	{ 0.1, 0.72, 14 },
	{ 0.9, 0.66, 18 },
}

-- A soft "new!" moment: the card pops and a few stars twinkle around it.
local function sparkle(frame: Frame)
	if PREVIEW then
		return
	end
	Kit.pop(frame, 0.6)
	for i, spot in SPARKLE_SPOTS do
		local star = Kit.icon(frame, "Star", spot[3], C.GoldLight, {
			Name = "Sparkle",
			Position = UDim2.fromScale(spot[1], spot[2]),
			AnchorPoint = Vector2.new(0.5, 0.5),
			ZIndex = 6,
		})
		Kit.appear(star, { from = 0.2, time = 0.3, delay = (i - 1) * 0.06 })
		Kit.tween(star, 0.9, { Position = UDim2.new(spot[1], 0, spot[2], -10) })
		task.delay(0.55 + (i - 1) * 0.06, function()
			Kit.disappear(star, { to = 0.5, time = 0.25, destroy = true })
		end)
	end
end

-- Index card height (design px): number row, character, two-line name, rarity tag.
local CARD_H = 218

--[[
	Every size, time and count of the Index's celebration (all tiers found), its claim
	buttons and its NEW markers.
]]
local INDEX = {
	-- All found: a crown sits on the corner of the progress pill and bobs, a sheen crosses
	-- the pill and stars twinkle around it.
	Crown = 40,
	CrownTilt = -18,
	CrownBob = 5,
	CrownBeat = 0.55,
	PillShine = 1.8, -- seconds between sheens
	PillTwinkle = 0.3, -- seconds between stars
	PillStar = 18,
	-- A milestone to claim: a bright sheen sweeps its button.
	ClaimShine = 1.4, -- seconds between sweeps
	ClaimShineWidth = 30,
	ClaimShineFade = 0.3, -- transparency of the band (lower = brighter)
	ClaimShineTime = 0.6, -- seconds to cross the button
	ClaimText = 15, -- "CLAIM $171.44T" has to fit a fifth of the track
	-- CLAIM ALL: shown while more than one milestone waits; claims them one after another.
	AllText = 22,
	AllGap = 0.3, -- seconds between two claims
	AllWait = 1.6, -- longest wait for the server's answer to one
	-- NEW: cleared once its card has been in view this long (checked every NewCheck seconds),
	-- one marker after another.
	NewSeen = 2.5,
	NewCheck = 0.5,
	NewStep = 0.07,
	NewPill = Vector2.new(58, 26),
	NewText = 17,
	-- At most this many cards wear NEW at once: the most recent finds since the Index was
	-- last opened (a burst of finds marks only the newest, not the whole page).
	NewMax = 2,
	-- Text on the glass (screen px): a card's rarity chip and the legend's band bars.
	ChipText = 16,
	LegendText = 15,
	-- A card's name (two lines at most) and the pale rarity line of a card still to find.
	NameText = 16,
	NamePx = 15, -- held at this size on the glass
	NameBox = 44, -- two lines of NameText
	GridGap = 8, -- between the legend and the first row of cards (the track's labels crowded it)

	-- Track heights: one-line captions (a narrow window, a phone) and two-line ones.
	TrackLow = 66,
	TrackTall = 90,
	CaptionLow = 22,
	CaptionTall = 44,
}

local function buildIndex(screen: ScreenGui)
	-- Minimum 386 tall: a phone gets that window at x1.3, one row of cards and the top of the next.
	local window = Kit.window(screen, "Index", "Index", I.Index, C.Window.Index, Vector2.new(880, 560), Vector2.new(560, 386))
	register("Index", window)
	local action = Net.event("Action")

	-- Discovered count: a bar in the header row, left of the close button. It turns gold
	-- once every tier is found.
	local progress, setProgress, progressLabel = Kit.progress(window.header, {
		Name = "Found",
		Glass = true,
		Color = C.Window.Index,
		Size = UDim2.fromOffset(250, 32),
		Position = UDim2.new(1, -62, 0.5, -1),
		AnchorPoint = Vector2.new(1, 0.5),
		TextSize = T.Body,
		MinFill = 0.08,
	})
	local function foundText(n: number): string
		return if n >= Economy.MAX_TIER
			then string.format("ALL %d FOUND!", Economy.MAX_TIER)
			else string.format("%d / %d FOUND", n, Economy.MAX_TIER)
	end
	local function paintBar(bar: Frame, color: Color3)
		local fill = bar:FindFirstChild("Fill")
		local gradient = fill and fill:FindFirstChildOfClass("UIGradient")
		if gradient then
			gradient.Color = ColorSequence.new(Kit.lighten(color, 0.25), color)
		end
	end

	-- The complete state: a gold ribbon over the legend once every tier is found and every
	-- milestone below is claimed (it takes the milestone track's row), and a gold frame
	-- around the window: the last milestone's reward.
	local COMPLETE_H = 44
	local complete = Kit.panel(window.content, {
		Name = "Complete",
		Color = C.Gold,
		Size = UDim2.new(1, -14, 0, COMPLETE_H - 8),
		Radius = Kit.RADIUS.M,
		Visible = false,
	})
	Kit.icon(complete, Kit.pickIcon("Crown", "Star"), 30, C.GoldInk, {
		Position = UDim2.new(0, 12, 0.5, 0),
		AnchorPoint = Vector2.new(0, 0.5),
		ZIndex = 2,
	})
	Kit.title(complete, {
		Name = "Title",
		Text = "INDEX COMPLETE!",
		TextSize = T.H2,
		MinPx = 16,
		TextWrapped = false,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextColor3 = C.GoldInk,
		Size = UDim2.new(0.5, -50, 1, 0),
		Position = UDim2.fromOffset(50, 1),
		ZIndex = 2,
	})
	Kit.text(complete, {
		Name = "Line",
		Text = string.format("You found every %s. Legend!", W.Unit),
		Font = F.UI,
		TextSize = T.Small,
		MinPx = true,
		TextWrapped = false,
		TextTruncate = Enum.TextTruncate.AtEnd,
		TextXAlignment = Enum.TextXAlignment.Right,
		TextColor3 = C.GoldInk,
		Size = UDim2.new(0.5, -14, 1, 0),
		Position = UDim2.fromScale(0.5, 0),
		StrokeThickness = 0,
		ZIndex = 2,
	})

	local paneCorner = window.frame:FindFirstChildOfClass("UICorner")
	local goldFrame = Kit.new("Frame", {
		Name = "GoldFrame",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		Visible = false,
		ZIndex = 3,
		Parent = window.frame,
	})
	Kit.new(
		"UICorner",
		{ CornerRadius = if paneCorner then paneCorner.CornerRadius else UDim.new(0, Theme.Glass.Radius), Parent = goldFrame }
	)
	Kit.new("UIStroke", {
		Thickness = 3,
		Color = C.Gold,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
		Parent = goldFrame,
	})

	-- Milestone track: a cell per Index milestone (Shared.IndexRewards) in one row over the
	-- legend. Each names what it asks for and its bonus (two lines on a wide window: "20 ·
	-- LEGENDARY CRATE" wraps) over what it pays: a dim chip with the cash still to earn (flat,
	-- so it does not read as a button), a breathing CLAIM button once the Index is there, a
	-- gold CLAIMED tag after. The server sends every amount (the snapshot's `index`), so a
	-- cell shows what a claim pays.
	local TRACK_H = { low = INDEX.TrackLow, tall = INDEX.TrackTall }
	local trackH = TRACK_H.low
	local track = Kit.new("Frame", {
		Name = "Rewards",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, -14, 0, trackH - 8),
		Visible = false,
		Parent = window.content,
	})
	type Cell = {
		frame: Frame,
		caption: TextLabel,
		button: TextButton,
		done: TextLabel,
		hit: TextButton,
		shown: string,
		state: string,
		stop: (() -> ())?,
		shine: (() -> ())?,
	}
	local cells: { Cell } = {}
	-- os.clock() of the claim sent for each cell: its button waits for the server's answer.
	local claimSent: { [number]: number } = {}
	local CLAIM_WAIT = 2
	local refreshTrack: () -> ()
	local function claim(order: number)
		local data = State.data
		local index = data and data.index
		local entry = if type(index) == "table" and type(index.milestones) == "table" then index.milestones[order] else nil
		if type(entry) ~= "table" or entry.reached ~= true or entry.claimed == true then
			return
		end
		if os.clock() - (claimSent[order] or -CLAIM_WAIT) < CLAIM_WAIT then
			return
		end
		claimSent[order] = os.clock()
		action:FireServer({ action = "ClaimIndex", found = entry.found })
		refreshTrack()
		-- No answer (a lost remote): the button comes back.
		task.delay(CLAIM_WAIT + 0.1, refreshTrack)
	end
	local milestoneCount = #IndexRewards.MILESTONES
	for order, milestone in IndexRewards.MILESTONES do
		local cell = Kit.new("Frame", {
			Name = "Milestone" .. milestone.found,
			BackgroundTransparency = 1,
			Size = UDim2.new(1 / milestoneCount, -6, 1, 0),
			Position = UDim2.fromScale((order - 1) / milestoneCount, 0),
			Parent = track,
		})
		-- Bottom-aligned: a one-line caption sits on its button, a second line goes above it.
		local caption = readable(Kit.text(cell, {
			Name = "Caption",
			Text = "",
			Font = F.UI,
			TextSize = T.Small,
			TextWrapped = true,
			TextTruncate = Enum.TextTruncate.AtEnd,
			TextYAlignment = Enum.TextYAlignment.Bottom,
			TextColor3 = SMALL_TEXT,
			Size = UDim2.new(1, 0, 0, 18),
			StrokeThickness = 0,
		}))
		local button = Kit.button(cell, {
			Name = "Claim",
			Text = "",
			Color = C.Good,
			TextSize = INDEX.ClaimText,
			Size = UDim2.new(1, 0, 0, 36),
			Position = UDim2.fromOffset(0, 20),
			Sound = "Reward",
		}, function()
			claim(order)
		end)
		local done = Kit.pill(cell, {
			Name = "Done",
			Text = "",
			Color = C.Gold,
			Solid = true,
			TextColor = C.GoldInk,
			TextSize = T.Small,
			Size = UDim2.new(1, 0, 0, 26),
			Position = UDim2.fromOffset(0, 24),
			Visible = false,
		})
		readable(done)
		local buttonLabel = Kit.buttonLabel(button)
		if buttonLabel then
			readable(buttonLabel)
		end
		-- Touch: the whole cell takes the tap (the button alone is a small target on a phone).
		local hit = Kit.new("TextButton", {
			Name = "Hit",
			BackgroundTransparency = 1,
			AutoButtonColor = false,
			Text = "",
			Size = UDim2.fromScale(1, 1),
			ZIndex = 5,
			Selectable = false,
			Visible = false,
			Parent = cell,
		})
		hit.Activated:Connect(function()
			if cells[order].state == "ready" then
				Kit.sound("Reward")
				Kit.pop(button, 0.5)
				claim(order)
			end
		end)
		cells[order] = { frame = cell, caption = caption, button = button, done = done, hit = hit, shown = "", state = "" }
	end

	-- CLAIM ALL: the first column of the track while more than one milestone waits. The
	-- server pays one milestone per request, so the waiting ones are claimed in order, each
	-- after the answer to the one before (claim() ignores a milestone that is already paid).
	local claimAll: TextButton
	local claimingAll = false
	local showAll = false
	do
		local function run()
			if claimingAll then
				return
			end
			claimingAll = true
			task.spawn(function()
				for order in cells do
					local function entryOf(): any
						local data = State.data
						local index = data and data.index
						return if type(index) == "table" and type(index.milestones) == "table" then index.milestones[order] else nil
					end
					local entry = entryOf()
					if type(entry) == "table" and entry.reached == true and entry.claimed ~= true then
						claim(order)
						local sent = os.clock()
						while os.clock() - sent < INDEX.AllWait do
							task.wait(0.05)
							local now = entryOf()
							if type(now) == "table" and now.claimed == true then
								break
							end
						end
						task.wait(INDEX.AllGap)
					end
				end
				claimingAll = false
				refreshTrack()
			end)
		end
		claimAll = Kit.button(track, {
			Name = "ClaimAll",
			Text = "CLAIM ALL",
			Font = F.Display,
			Color = C.Gold,
			TextSize = INDEX.AllText,
			Size = UDim2.new(1 / (milestoneCount + 1), -6, 1, 0),
			Sound = "Reward",
			Visible = false,
		}, run)
		local face = Kit.buttonFace(claimAll)
		if face and not PREVIEW then
			Kit.shimmer(
				face,
				INDEX.ClaimShine,
				5,
				{ Width = INDEX.ClaimShineWidth, Fade = INDEX.ClaimShineFade, Time = INDEX.ClaimShineTime }
			)
		end
	end
	-- The cells share the track with CLAIM ALL while it shows.
	local function placeTrack()
		local shift = if showAll then 1 else 0
		local columns = milestoneCount + shift
		for order, cell in cells do
			cell.frame.Size = UDim2.new(1 / columns, -6, 1, 0)
			cell.frame.Position = UDim2.fromScale((order - 1 + shift) / columns, 0)
		end
		claimAll.Visible = showAll
	end

	-- All found: the crown on the corner of the progress pill, a sheen across the pill and
	-- stars around it, for as long as the Index is open (completeFx).
	local completeFx: (boolean) -> ()
	do
		local crown = Kit.icon(window.header, Kit.pickIcon("Crown", "Star"), INDEX.Crown, C.Gold, {
			Name = "Crown",
			Position = UDim2.new(1, -62 - 250 + 8, 0.5, -13),
			AnchorPoint = Vector2.new(0.5, 0.5),
			ZIndex = 6,
		})
		crown.Rotation = INDEX.CrownTilt
		crown.Visible = false
		local stars = Kit.new("Frame", {
			Name = "FoundStars",
			BackgroundTransparency = 1,
			Size = UDim2.fromOffset(250 + 28, 52),
			Position = UDim2.new(1, -62 + 14, 0.5, -1),
			AnchorPoint = Vector2.new(1, 0.5),
			ZIndex = 5,
			Parent = window.header,
		})
		local stops: { () -> () } = {}
		local running = false
		completeFx = function(on: boolean)
			crown.Visible = on
			if on == running or PREVIEW then
				return
			end
			running = on
			for _, stop in stops do
				stop()
			end
			table.clear(stops)
			if on then
				Kit.pop(crown, 0.9)
				table.insert(stops, Kit.bob(crown, INDEX.CrownBob, INDEX.CrownBeat))
				table.insert(stops, Kit.shimmer(progress, INDEX.PillShine, 4, { Fade = 0.4, Time = 0.8 }))
				table.insert(stops, Kit.twinkle(stars, { Every = INDEX.PillTwinkle, Size = INDEX.PillStar, Inset = 0.04, ZIndex = 6 }))
			end
		end
	end

	-- Rarity legend: one slim row above the grid, a bar per band that fills with the tiers
	-- found in it ("RARE 3/5"), so a finished rarity reads as a solid chip of its colour.
	local LEGEND_H = 34
	local legend = Kit.new("Frame", {
		Name = "Legend",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, -14, 0, 26),
		Parent = window.content,
	})
	type BandBar = { name: string, from: number, upTo: number, set: (number) -> (), label: TextLabel, found: number }
	local bands: { BandBar } = {}
	local bandCount = #Economy.TIER_BANDS
	for order, band in Economy.TIER_BANDS do
		local previous = Economy.TIER_BANDS[order - 1]
		local _, set, label = Kit.progress(legend, {
			Name = band.name,
			Glass = true,
			Color = C.Rarity[band.name],
			Size = UDim2.new(1 / bandCount, -6, 1, 0),
			Position = UDim2.fromScale((order - 1) / bandCount, 0),
			TextSize = INDEX.LegendText,
			MinFill = 0.12,
		})
		label.TextWrapped = false
		Kit.holdText(label, math.max(Kit.captionPx(), INDEX.LegendText))
		bands[order] =
			{ name = band.name, from = if previous then previous.upTo + 1 else 1, upTo = band.upTo, set = set, label = label, found = -1 }
	end

	local scroll = Kit.scrolling(window.content, { Size = UDim2.new(1, 0, 1, -LEGEND_H), Position = UDim2.fromOffset(0, LEGEND_H) })
	-- Gamepad: a milestone waiting to be claimed is selected first; with none the grid itself
	-- is, so the stick scrolls it.
	Kit.selectable(scroll)
	focusPick.Index = function()
		for _, cell in cells do
			if cell.state == "ready" and track.Visible then
				return cell.button
			end
		end
		return scroll
	end
	Kit.new("UIPadding", {
		PaddingTop = UDim.new(0, 10),
		PaddingLeft = UDim.new(0, 4),
		PaddingRight = UDim.new(0, 14),
		PaddingBottom = UDim.new(0, 12),
		Parent = scroll,
	})
	local grid = Kit.new("UIGridLayout", {
		CellSize = UDim2.new(0.2, -12, 0, CARD_H),
		CellPadding = UDim2.fromOffset(14, 16),
		SortOrder = Enum.SortOrder.LayoutOrder,
		Parent = scroll,
	})
	-- 5 columns at full width, 4 or 3 as the window narrows on small screens; a phone
	-- always shows 3, so the characters and their names stay big.
	-- The legend's bars name their band where there is room for it, else only count.
	local wideLegend = true
	local function bandText(band: BandBar): string
		local count = string.format("%d/%d", math.max(band.found, 0), band.upTo - band.from + 1)
		return if wideLegend then string.upper(band.name) .. " " .. count else count
	end
	local isComplete = false
	-- The track shows while a milestone is still to claim; the ribbon takes over after the last.
	local showTrack = false
	-- Paints the track's cells from the snapshot's `index` (nothing is rebuilt: only what
	-- changed is set). A cell claimed while the Index is open pops with confetti.
	refreshTrack = function()
		local data = State.data
		local index = data and data.index
		local milestones = if type(index) == "table" and type(index.milestones) == "table" then index.milestones else nil
		local open = false
		-- More than one milestone waits: CLAIM ALL takes the first column (and stays through its run).
		local ready = 0
		for order in cells do
			local entry = milestones and milestones[order]
			if type(entry) == "table" and entry.reached == true and entry.claimed ~= true then
				ready += 1
			end
		end
		local all = ready > 1 or (claimingAll and ready > 0)
		if all ~= showAll then
			showAll = all
			placeTrack()
		end
		Kit.setEnabled(claimAll, not claimingAll)
		for order, cell in cells do
			local entry = milestones and milestones[order]
			if type(entry) ~= "table" then
				continue
			end
			local waiting = os.clock() - (claimSent[order] or -CLAIM_WAIT) < CLAIM_WAIT
			local state = if entry.claimed == true then "claimed" elseif entry.reached == true then "ready" else "locked"
			open = open or state ~= "claimed"
			local bonus: string? = nil
			if type(entry.crate) == "string" then
				bonus = if wideLegend then string.upper(entry.crate .. " " .. W.Chest) else "+" .. string.upper(W.Chest)
			elseif entry.champion == true then
				bonus = if wideLegend then "CHAMPION AURA" else "+AURA"
			end
			local found = tonumber(entry.found) or 0
			local captionText = if not bonus
				then string.format("%d FOUND", found)
				elseif wideLegend then string.format("%d · %s", found, bonus)
				else string.format("%d %s", found, bonus)
			local cash = Format.money(tonumber(entry.cash) or 0)
			local buttonText = if state == "claimed"
				then (if wideLegend then "CLAIMED" else "DONE")
				elseif state ~= "ready" then cash
				elseif waiting then "..."
				elseif wideLegend and showAll then "+" .. cash -- a narrower column: CLAIM ALL says the verb
				elseif wideLegend then "CLAIM " .. cash
				else "CLAIM"
			local key = state .. "|" .. captionText .. "|" .. buttonText
			if cell.shown ~= key then
				local was = cell.state
				cell.shown = key
				cell.state = state
				cell.caption.Text = captionText
				cell.caption.TextColor3 = if state == "locked" then SMALL_TEXT else C.GoldLight
				-- Only a milestone that can be claimed shows a button, and that one breathes.
				cell.button.Visible = state == "ready"
				cell.done.Visible = state ~= "ready"
				cell.done.Text = buttonText
				if was ~= state then
					local locked = state == "locked"
					cell.done.BackgroundColor3 = if locked then C.Ink else C.Gold
					cell.done.BackgroundTransparency = if locked then 0.6 else 0
					cell.done.TextColor3 = if locked then SMALL_TEXT else C.GoldInk
					cell.done.TextTransparency = if locked then 0.25 else 0
					local edge = cell.done:FindFirstChild("Edge")
					if edge and edge:IsA("UIStroke") then
						edge.Transparency = if locked then 0.8 else 0
					end
					if cell.stop then
						cell.stop()
						cell.stop = nil
					end
					if cell.shine then
						cell.shine()
						cell.shine = nil
					end
					if state == "ready" then
						cell.stop = Kit.breathe(cell.button)
						local face = Kit.buttonFace(cell.button)
						if face and not PREVIEW then
							cell.shine = Kit.shimmer(
								face,
								INDEX.ClaimShine,
								5,
								{ Width = INDEX.ClaimShineWidth, Fade = INDEX.ClaimShineFade, Time = INDEX.ClaimShineTime }
							)
						end
					end
				end
				Kit.setButton(cell.button, buttonText)
				Kit.setEnabled(cell.button, state == "ready" and not waiting)
				if was == "ready" and state == "claimed" and window.isOpen() and not PREVIEW then
					Kit.pop(cell.frame, 0.8)
					local pane = window.frame
					local scale = pane.AbsoluteSize.X / math.max(1, window.size().X)
					local spot = (cell.frame.AbsolutePosition + cell.frame.AbsoluteSize / 2 - pane.AbsolutePosition) / math.max(scale, 0.01)
					Kit.confetti(
						pane,
						{ Origin = UDim2.fromOffset(spot.X, spot.Y), Count = if entry.champion == true then 36 else 24, ZIndex = 45 }
					)
					-- Gamepad: the claimed button is gone, the selection moves to the next one.
					if Kit.gamepad then
						focusWindow("Index")
					end
				end
			end
			cell.hit.Visible = Kit.touch and state == "ready"
		end
		showTrack = open
		goldFrame.Visible = type(index) == "table" and index.champion == true
	end
	local function layoutGrid()
		local width = window.size().X
		local columns = if isPhone(screen) then 3 elseif width >= 820 then 5 elseif width >= 680 then 4 else 3
		grid.CellSize = UDim2.new(1 / columns, -12, 0, CARD_H)
		wideLegend = width >= 820 and not isPhone(screen)
		for _, band in bands do
			band.label.Text = bandText(band)
		end
		refreshTrack()
		-- A wide window's captions name the bonus in full and may take a second line.
		local captionH = if wideLegend then INDEX.CaptionTall else INDEX.CaptionLow
		trackH = if wideLegend then TRACK_H.tall else TRACK_H.low
		track.Size = UDim2.new(1, -14, 0, trackH - 8)
		for _, cell in cells do
			cell.caption.Size = UDim2.new(1, 0, 0, captionH)
			cell.button.Position = UDim2.fromOffset(0, captionH + 2)
			cell.done.Position = UDim2.fromOffset(0, captionH + 6)
		end
		placeTrack()
		-- The track, or the ribbon after it, takes its row above the legend. A short window (a
		-- phone) gives it the legend's row instead: the rarity is on every card.
		local ribbon = isComplete and not showTrack
		local strip = if showTrack then trackH elseif ribbon then COMPLETE_H else 0
		local folded = strip > 0 and window.size().Y < 440
		local top = strip + (if folded then 0 else LEGEND_H + INDEX.GridGap)
		complete.Visible = ribbon
		track.Visible = showTrack
		legend.Visible = not folded
		legend.Position = UDim2.fromOffset(0, strip)
		scroll.Position = UDim2.fromOffset(0, top)
		scroll.Size = UDim2.new(1, 0, 1, -top)
	end
	layoutGrid()
	window.onResize.Event:Connect(layoutGrid)
	onPhone(screen, layoutGrid)

	local cards: { { frame: Frame, shown: string } } = {}
	local cardFrames: { GuiObject } = {}
	for tier = 1, Economy.MAX_TIER do
		local frame = Kit.glass(scroll, { Name = "Tier" .. tier, LayoutOrder = tier, Radius = Kit.RADIUS.M + 2, StrokeThickness = 1.5 })
		cards[tier] = { frame = frame, shown = "" }
		cardFrames[tier] = frame
	end

	-- Tiers discovered this session that the player hasn't looked at yet, and
	-- the ones whose "new" sparkle already played.
	local seen: { [number]: boolean } = {}
	local sparkled: { [number]: boolean } = {}
	local sessionStart: number? = nil

	-- The tiers that wear NEW: found this session and not looked at yet, newest first, at
	-- most INDEX.NewMax of them (ties on the time go to the higher tier).
	local function newTiers(data): { [number]: boolean }
		local fresh = {}
		if not sessionStart then
			return fresh
		end
		local order = {}
		for tier = 1, Economy.MAX_TIER do
			local at = data.discovered[tier] or 0
			if at > 0 and at >= (sessionStart :: number) and not seen[tier] then
				table.insert(order, tier)
			end
		end
		table.sort(order, function(a, b)
			local atA, atB = data.discovered[a], data.discovered[b]
			if atA ~= atB then
				return atA > atB
			end
			return a > b
		end)
		for i = 1, math.min(#order, INDEX.NewMax) do
			fresh[order[i]] = true
		end
		return fresh
	end

	local function fillCard(tier: number, discoveredAt: number, isNew: boolean)
		local entry = cards[tier]
		local key = (if discoveredAt > 0 then "known" else "unknown") .. (if isNew then "+new" else "")
		if entry.shown == key then
			return
		end
		local wasKnown = string.sub(entry.shown, 1, 5) == "known"
		entry.shown = key
		local frame = entry.frame
		clearChildren(frame)
		local band = Economy.tierBand(tier)
		local rarity = C.Rarity[band]
		local known = discoveredAt > 0
		-- Found: a card of glass in its rarity's colour with a bold outline of it. Unknown:
		-- the plain dark card, so the page fills with colour as the Index does.
		if known then
			Kit.paintGlass(frame, rarity, Theme.Glass.SurfaceHi, rarity)
		else
			Kit.paintGlass(frame)
		end
		local edge = frame:FindFirstChildOfClass("UIStroke")
		if edge then
			edge.Thickness = if known then 2.5 else 1.5
		end

		Kit.number(frame, {
			Name = "Tier",
			Text = "#" .. tier,
			TextSize = T.Small,
			MinPx = true,
			Size = UDim2.new(0, 44, 0, 24),
			Position = UDim2.fromOffset(12, 8),
			TextXAlignment = Enum.TextXAlignment.Left,
			TextColor3 = if known then C.Text else C.TextMute,
		})
		-- Name under the character: INDEX.NameText, up to two lines (never scaled down).
		Kit.text(frame, {
			Name = "Name",
			Text = if known then string.upper(Theme.Tiers[tier].Name) else "???",
			Font = F.UI,
			TextSize = INDEX.NameText,
			MinPx = INDEX.NamePx,
			TextWrapped = true,
			Size = UDim2.new(1, -16, 0, INDEX.NameBox),
			Position = UDim2.new(0, 8, 1, -(36 + INDEX.NameBox)),
			TextColor3 = if known then C.Text else C.TextMute,
			ZIndex = 3,
		})
		if known then
			-- Soft rarity-tinted spot behind the character.
			local spot = Kit.new("Frame", {
				Name = "Spot",
				BackgroundColor3 = Kit.lighten(rarity, 0.3),
				BackgroundTransparency = 0.72,
				Size = UDim2.new(1, -40, 1, -40),
				Position = UDim2.new(0.5, 0, 0, 86),
				AnchorPoint = Vector2.new(0.5, 0.5),
				Parent = frame,
			})
			Kit.new("UIAspectRatioConstraint", { AspectRatio = 1, Parent = spot })
			-- Wide cards (3 columns): the spot stays behind the character, clear of the name.
			Kit.new("UISizeConstraint", { MaxSize = Vector2.new(124, 124), Parent = spot })
			Kit.round(spot)
		end
		-- Unknown tiers: a smaller soft-blue silhouette (Kit.unitViewport tints it).
		local viewport = if known
			then Kit.unitViewport(frame, tier, { Size = UDim2.new(1, -16, 1, -118), Position = UDim2.fromOffset(8, 32), Statue = true })
			else Kit.unitViewport(frame, tier, {
				Size = UDim2.new(1, -60, 1, -136),
				Position = UDim2.new(0.5, 0, 0, 40),
				AnchorPoint = Vector2.new(0.5, 0),
			}, true)
		viewport.ZIndex = 2
		if known then
			tag(frame, {
				Name = "Footer",
				Text = string.upper(band),
				Color = rarity,
				TextSize = INDEX.ChipText,
				Position = UDim2.new(0.5, 0, 1, -8),
				AnchorPoint = Vector2.new(0.5, 1),
				ZIndex = 3,
			})
		else
			-- Still to find: its rarity in a pale wash of that rarity's colour.
			Kit.text(frame, {
				Name = "Footer",
				Text = string.upper(band),
				Font = F.UI,
				TextSize = INDEX.NameText,
				MinPx = INDEX.NamePx,
				TextWrapped = false,
				Size = UDim2.new(1, -16, 0, 24),
				Position = UDim2.new(0, 8, 1, -32),
				TextColor3 = SMALL_TEXT:Lerp(rarity, 0.45),
			})
		end
		if isNew then
			-- Fully inside the card's top-right corner.
			Kit.pill(frame, {
				Name = "New",
				Text = "NEW",
				Color = C.Danger,
				Solid = true,
				TextColor = C.Text,
				TextSize = INDEX.NewText,
				Size = UDim2.fromOffset(INDEX.NewPill.X, INDEX.NewPill.Y),
				Position = UDim2.new(1, -8, 0, 8),
				AnchorPoint = Vector2.new(1, 0),
				ZIndex = 5,
			})
		end
		if window.isOpen() and known and not wasKnown then
			-- Discovered while the Index is open: ease the character in and celebrate.
			viewport.ImageTransparency = 1
			Kit.tween(viewport, 0.3, { ImageTransparency = 0 })
			if not sparkled[tier] then
				sparkled[tier] = true
				sparkle(frame)
			end
		end
	end

	local found = 0
	local prebuilt = false
	-- The ribbon's entrance has played (once per session, the first time it is seen).
	local celebrated = false
	local function celebrate()
		if celebrated or PREVIEW or not complete.Visible then
			return
		end
		celebrated = true
		task.delay(0.35, function()
			if window.isOpen() then
				sparkle(complete)
				Kit.pop(progress, 0.5)
			end
		end)
	end
	local function refresh(force: boolean?)
		local data = State.data
		if not data or not (force or window.isOpen()) then
			return
		end
		if not sessionStart then
			sessionStart = State.now() - 2
		end
		local count = 0
		local fresh = newTiers(data)
		for tier = 1, Economy.MAX_TIER do
			local at = data.discovered[tier] or 0
			if at > 0 then
				count += 1
			end
			fillCard(tier, at, fresh[tier] == true)
		end
		-- Per rarity: the bar of each band fills with the tiers found in it.
		for _, band in bands do
			local inBand = 0
			for tier = band.from, band.upTo do
				if (data.discovered[tier] or 0) > 0 then
					inBand += 1
				end
			end
			if inBand ~= band.found then
				band.found = inBand
				band.label.Text = bandText(band)
				band.set(inBand / (band.upTo - band.from + 1))
			end
		end
		if count ~= found and window.isOpen() then
			Kit.countTo(progressLabel, found, count, foundText)
		elseif count ~= found or progressLabel.Text == "" then
			progressLabel.Text = foundText(count)
		end
		found = count
		setProgress(count / Economy.MAX_TIER)
		local done = count >= Economy.MAX_TIER
		local hadTrack, hadRibbon = showTrack, complete.Visible
		refreshTrack()
		if done ~= isComplete or showTrack ~= hadTrack then
			if done ~= isComplete then
				isComplete = done
				paintBar(progress, if done then C.Gold else C.Window.Index)
				completeFx(done and window.isOpen())
			end
			layoutGrid()
			-- The last milestone claimed with the Index open: the ribbon lands at once.
			if window.isOpen() and complete.Visible and not hadRibbon then
				celebrate()
			end
		end
	end
	State.changed.Event:Connect(function()
		refresh()
	end)

	beforeOpen.Index = function()
		refresh(true)
		ripple(cardFrames)
		-- The bar refills from empty each time the Index opens.
		setProgress(0, true)
		setProgress(found / Economy.MAX_TIER)
		celebrate()
		-- First look at tiers discovered since the last visit: sparkle once,
		-- right after the card has rippled in.
		local data = State.data
		if not data or not sessionStart then
			return
		end
		local fresh = newTiers(data)
		for tier = 1, Economy.MAX_TIER do
			-- The older finds of a burst count as looked at, so clearing the newest NEW
			-- markers never hands theirs to the next ones in line.
			if not fresh[tier] and (data.discovered[tier] or 0) > 0 then
				seen[tier] = true
			end
			if fresh[tier] and not sparkled[tier] then
				sparkled[tier] = true
				local frame = cards[tier].frame
				if not PREVIEW then
					task.delay(math.min(tier - 1, 12) * 0.025 + 0.3, function()
						if window.isOpen() then
							sparkle(frame)
						end
					end)
				end
			end
		end
	end
	-- NEW markers clear by themselves once their card has been looked at: in view for
	-- INDEX.NewSeen seconds with the Index open (the rest go when it closes).
	local watching = 0
	window.onOpen.Event:Connect(function()
		completeFx(isComplete)
		if PREVIEW then
			return
		end
		watching += 1
		local mine = watching
		task.spawn(function()
			local inView: { [number]: number } = {}
			while window.isOpen() and watching == mine do
				task.wait(INDEX.NewCheck)
				local top = scroll.AbsolutePosition.Y
				local bottom = top + scroll.AbsoluteSize.Y
				local cleared = 0
				for tier, card in cards do
					local pill = card.frame:FindFirstChild("New")
					if not pill or not pill:IsA("GuiObject") or seen[tier] then
						continue
					end
					local middle = card.frame.AbsolutePosition.Y + card.frame.AbsoluteSize.Y / 2
					if middle < top or middle > bottom then
						continue
					end
					inView[tier] = (inView[tier] or 0) + INDEX.NewCheck
					if inView[tier] >= INDEX.NewSeen then
						seen[tier] = true
						-- The card keeps its look: only the marker goes (no rebuild on the next refresh).
						card.shown = "known"
						local marker = pill
						task.delay(cleared * INDEX.NewStep, function()
							if marker.Parent then
								Kit.disappear(marker, { to = 0.3, time = 0.25, destroy = true })
							end
						end)
						cleared += 1
					end
				end
			end
		end)
	end)
	Kit.scrollCue(scroll)
	window.onClose.Event:Connect(function()
		watching += 1
		completeFx(false)
		local data = State.data
		if data then
			for tier = 1, Economy.MAX_TIER do
				if (data.discovered[tier] or 0) > 0 then
					seen[tier] = true
				end
			end
		end
	end)
	State.changed.Event:Connect(function()
		if not sessionStart then
			sessionStart = State.now() - 2
		end
		-- Build every card in the background (a couple per frame) after the
		-- first snapshot, so opening the Index never pops viewports in.
		if not prebuilt then
			prebuilt = true
			task.spawn(function()
				local data = State.data
				for tier = 1, Economy.MAX_TIER do
					if data then
						fillCard(tier, data.discovered[tier] or 0, newTiers(data)[tier] == true)
					end
					if tier % 2 == 0 then
						task.wait()
					end
					data = State.data
				end
				refresh()
			end)
		end
	end)
end

-- Ranking -----------------------------------------------------------------------------

--[[
	Every size, colour, time and count of the Ranking window (design px; text in the window
	is also held at Kit.WINDOW.TextPx on the glass).
]]
local RANK = {
	-- The podium: gold, silver and bronze rows, each taller and bolder than a plain row.
	Medals = { C.Gold, C.Chrome, C.Amber },
	-- The three steps (taken or open) always show in full at 1280x720, also while the
	-- leader's trophy card wants its room (LeadKeep only takes rows past the podium).
	PodiumH = { 60, 52, 52 },
	MedalSize = { 50, 42, 42 }, -- the medal coin
	MedalText = { 28, 22, 22 }, -- the place on it
	PodiumName = { 22, 20, 20 },
	PodiumValue = { 28, 24, 24 },
	PodiumEdge = 2.5, -- outline of a podium row in its medal colour
	GoldShine = 3.2, -- seconds between the sheens across the gold row
	-- A young board (one or two players): the podium's empty steps still show, as faint
	-- medal rows that are a spot to take, never a made-up player.
	OpenTint = 0.82, -- transparency of the medal tint on the glass
	OpenEdge = 0.35, -- transparency of the medal outline
	OpenCoin = 0.55, -- transparency of the medal coin
	OpenBreathe = 1.4, -- seconds per half breath of the outline (0.35 <-> 0.75)
	OpenName = "Your spot!", -- the player is not on the board yet
	OpenOther = "Open spot: bring a friend!", -- the player already holds a higher step
	-- The card under the list pops when the player takes #1: from its centre, and gently,
	-- so the pop never reaches past the window's right edge.
	LeadPop = 0.35,
	-- A plain row.
	RowH = 50,
	RowGap = 8,
	NameText = 18,
	ValueText = 20,
	ExtraText = 18, -- the clears column
	RankText = 17,
	HeadText = 16, -- the column heads (RANK, PLAYER, COLLECTED ...)
	HeadPx = 15, -- ... held at this size on the glass
	YouPill = Vector2.new(56, 26),
	MineEdge = 3, -- gold outline of the player's own row
	PinAfter = 5, -- the own row is also pinned under the list once it sits below this place
	ButtonText = 15, -- tabs, number format, refresh (held at Kit.WINDOW.TextPx on the glass)
	-- The pinned card: the own row over the goal pill and its bar.
	MineH = 56,
	GoalH = 60,
	GoalPillH = 30,
	GoalBarH = 10,
	GoalText = 18,
	-- The card under the list (headline, goal in full, the player's numbers). It takes all
	-- the room that is left, so the window is never mostly blank.
	InfoMin = 92, -- hidden under this height
	InfoStats = 172, -- from this height the stat tiles show too
	LeadKeep = 150, -- room kept for it while the player leads (the list gives way)
	Art = 96, -- the trophy
	ArtLead = 128, -- ... while the player is #1
	TitleText = 26,
	TitleLead = 40,
	LineText = 18,
	StatH = 64,
	StatValue = 24,
	StatCaption = 17,
	-- #1: the trophy bobs in turning rays, stars twinkle, a sheen crosses the card.
	TrophyBob = 9,
	TrophyBeat = 0.65,
	Rays = 6, -- bars through the trophy (two rays each)
	RayWidth = 0.2, -- of the trophy's size
	RayReach = 1.7, -- ray length, in trophy sizes
	RayFade = 0.4, -- transparency of a ray at the trophy
	RayTurn = 12, -- seconds per turn
	GlowSize = 1.5,
	GlowFade = { 0.55, 0.82 }, -- the glow disc pulses between these transparencies
	GlowBeat = 0.9,
	TwinkleEvery = 0.28,
	ShineEvery = 2.2,
}
local MEDAL_COLORS = RANK.Medals

type RowLabels = { rank: TextLabel, chip: Frame, value: TextLabel, extra: TextLabel? }

-- Boards: total units (the original board) and the sky obby's highest stage (with clears).
type Board = "units" | "stage"

-- The next round count to aim for when there is nobody ahead to pass: 10, 25, 50, 100, 250 ...
local function nextMilestone(n: number): number
	if n ~= n or n >= 1e15 then
		return n
	end
	local step = 10
	while true do
		for _, k in { 1, 2.5, 5 } do
			if step * k > n then
				return step * k
			end
		end
		step *= 10
	end
end

local function countOf(n: number, word: string): string
	return string.format("%d more %s", n, if n == 1 then word else word .. "s")
end

-- The local player's highest obby stage and total clears, from the snapshot (falling back to
-- the replicated ParkourBestStage attribute).
local function myStage(): (number, number)
	local data = State.data
	local info = data and data.modes and data.modes.parkour
	local stage = tonumber(Players.LocalPlayer:GetAttribute("ParkourBestStage")) or 0
	local clears = 0
	if type(info) == "table" then
		stage = math.max(stage, tonumber(info.stage) or tonumber(info.bestStage) or 0)
		if type(info.clears) == "number" then
			clears = info.clears
		elseif type(info.levels) == "table" then
			for _, lv in info.levels do
				if type(lv) == "table" then
					clears += tonumber(lv.clears) or 0
				end
			end
		end
	end
	return stage, clears
end

--[[
	The card under the Ranking list: a trophy, a headline and the goal in full over three
	tiles with the player's own numbers. It is given whatever height the list leaves
	(layout), so a young board is shown as it is (no made-up names) and the window is still
	full. While the player leads it is the loudest thing in the window: a gold card, the
	trophy bigger and bobbing in turning rays, "YOU'RE #1!" in the biggest type, stars and a
	sheen. All motion runs only while the window is open (play).
]]
type RankInfo = {
	frame: Frame,
	layout: (number) -> (),
	paint: (string, string, boolean) -> (),
	stat: (number, string, string) -> (),
	play: (boolean) -> (),
}
local function rankingInfo(parent: Instance): RankInfo
	local BASE = 100 -- the art is built at this size and scaled
	local frame = Kit.glass(parent, {
		Name = "Info",
		Size = UDim2.new(1, -14, 0, RANK.InfoMin),
		AnchorPoint = Vector2.new(0.5, 0),
		Radius = Kit.RADIUS.L,
		StrokeThickness = 2,
		Visible = false,
	})
	frame.ClipsDescendants = true
	local art = Kit.new("Frame", {
		Name = "Art",
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(BASE, BASE),
		AnchorPoint = Vector2.new(0.5, 0.5),
		ZIndex = 2,
		Parent = frame,
	})
	local artScale = Kit.new("UIScale", { Name = "Size", Parent = art })
	local rays = Kit.new("Frame", {
		Name = "Rays",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(RANK.RayReach * 2, RANK.RayReach * 2),
		Position = UDim2.fromScale(0.5, 0.5),
		AnchorPoint = Vector2.new(0.5, 0.5),
		Visible = false,
		ZIndex = 2,
		Parent = art,
	})
	for i = 1, RANK.Rays do
		local ray = Kit.new("Frame", {
			Name = "Ray" .. i,
			BackgroundColor3 = C.GoldLight,
			BorderSizePixel = 0,
			Size = UDim2.new(0, BASE * RANK.RayWidth, 1, 0),
			Position = UDim2.fromScale(0.5, 0.5),
			AnchorPoint = Vector2.new(0.5, 0.5),
			Rotation = (i - 1) * 180 / RANK.Rays,
			ZIndex = 2,
			Parent = rays,
		})
		-- Brightest at the trophy, gone at both ends.
		Kit.new("UIGradient", {
			Rotation = 90,
			Transparency = NumberSequence.new({
				NumberSequenceKeypoint.new(0, 1),
				NumberSequenceKeypoint.new(0.5, RANK.RayFade),
				NumberSequenceKeypoint.new(1, 1),
			}),
			Parent = ray,
		})
	end
	local glow = Kit.new("Frame", {
		Name = "Glow",
		BackgroundColor3 = C.Gold,
		BackgroundTransparency = RANK.GlowFade[2],
		Size = UDim2.fromScale(RANK.GlowSize, RANK.GlowSize),
		Position = UDim2.fromScale(0.5, 0.5),
		AnchorPoint = Vector2.new(0.5, 0.5),
		ZIndex = 2,
		Parent = art,
	})
	Kit.round(glow)
	local icon = Kit.icon(art, Kit.iconName(I.Ranking) or "Star", BASE, C.Gold, {
		Name = "Trophy",
		Position = UDim2.fromScale(0.5, 0.5),
		AnchorPoint = Vector2.new(0.5, 0.5),
		ZIndex = 4,
	})
	local title = Kit.title(frame, {
		Name = "Title",
		Text = "",
		TextSize = RANK.TitleText,
		TextWrapped = false,
		TextTruncate = Enum.TextTruncate.AtEnd,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextColor3 = C.Gold,
		ZIndex = 5,
	})
	local line = Kit.text(frame, {
		Name = "Line",
		Text = "",
		Font = F.UI,
		TextSize = RANK.LineText,
		TextWrapped = true,
		TextTruncate = Enum.TextTruncate.AtEnd,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
		TextColor3 = C.Text,
		StrokeThickness = 1.5,
		ZIndex = 5,
	})
	local stats = Kit.new("Frame", {
		Name = "Stats",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, -24, 0, RANK.StatH),
		Position = UDim2.new(0, 12, 1, -12),
		AnchorPoint = Vector2.new(0, 1),
		ZIndex = 5,
		Parent = frame,
	})
	local tiles: { { value: TextLabel, caption: TextLabel } } = {}
	for i = 1, 3 do
		local tile = Kit.new("Frame", {
			Name = "Stat" .. i,
			BackgroundColor3 = C.Ink,
			BackgroundTransparency = Theme.Glass.Inset,
			BorderSizePixel = 0,
			Size = UDim2.new(1 / 3, -6, 1, 0),
			Position = UDim2.new((i - 1) / 3, 3, 0, 0),
			ZIndex = 5,
			Parent = stats,
		})
		Kit.corner(tile, Kit.RADIUS.M)
		Kit.new("UIStroke", { Thickness = 1, Color = Theme.Glass.Edge, Transparency = 0.75, Parent = tile })
		tiles[i] = {
			value = Kit.number(tile, {
				Name = "Value",
				Text = "",
				TextSize = RANK.StatValue,
				TextTruncate = Enum.TextTruncate.AtEnd,
				TextColor3 = C.GoldLight,
				Size = UDim2.new(1, -12, 0, RANK.StatValue + 6),
				Position = UDim2.fromOffset(6, 6),
				ZIndex = 6,
			}),
			caption = Kit.text(tile, {
				Name = "Caption",
				Text = "",
				Font = F.UI,
				TextSize = RANK.StatCaption,
				TextWrapped = false,
				TextTruncate = Enum.TextTruncate.AtEnd,
				TextColor3 = SMALL_TEXT,
				Size = UDim2.new(1, -12, 0, RANK.StatCaption + 5),
				Position = UDim2.new(0, 6, 1, -6),
				AnchorPoint = Vector2.new(0, 1),
				StrokeThickness = 0,
				ZIndex = 6,
			}),
		}
	end

	local leading = false
	local playing = false
	local height = RANK.InfoMin
	local stops: { () -> () } = {}
	local function layout(h: number)
		height = h
		local withStats = h >= RANK.InfoStats
		stats.Visible = withStats
		-- The trophy and the words share what the tiles leave.
		local top = h - (if withStats then RANK.StatH + 18 else 0)
		local size = math.clamp(top - 20, 44, if leading then RANK.ArtLead else RANK.Art)
		artScale.Scale = size / BASE
		art.Position = UDim2.fromOffset(20 + size / 2, top / 2 + (if withStats then 4 else 0))
		local x = 20 + size + 20
		local titleSize = math.min(if leading then RANK.TitleLead else RANK.TitleText, math.max(RANK.TitleText - 4, top - 44))
		title.TextSize = titleSize
		-- Two lines of goal where there is room for them.
		local lineH = if top - titleSize - 26 >= RANK.LineText * 2.4 then math.ceil(RANK.LineText * 2.5) else RANK.LineText + 6
		local y = math.max(4, (top - (titleSize + 8 + lineH)) / 2) + (if withStats then 4 else 0)
		title.Size = UDim2.new(1, -(x + 14), 0, titleSize + 6)
		title.Position = UDim2.fromOffset(x, y)
		line.TextWrapped = lineH > RANK.LineText + 6
		line.Size = UDim2.new(1, -(x + 14), 0, lineH)
		line.Position = UDim2.fromOffset(x, y + titleSize + 8)
	end
	local function motion()
		for _, stop in stops do
			stop()
		end
		table.clear(stops)
		if not playing or PREVIEW then
			return
		end
		-- The trophy always floats a little; the rest is the leader's.
		table.insert(
			stops,
			Kit.bob(
				icon,
				if leading then RANK.TrophyBob else RANK.TrophyBob / 2,
				if leading then RANK.TrophyBeat else RANK.TrophyBeat * 1.6
			)
		)
		if not leading then
			return
		end
		local turn = TweenService:Create(
			rays,
			TweenInfo.new(RANK.RayTurn, Enum.EasingStyle.Linear, Enum.EasingDirection.InOut, -1),
			{ Rotation = rays.Rotation + 360 }
		)
		turn:Play()
		local pulse = TweenService:Create(
			glow,
			TweenInfo.new(RANK.GlowBeat, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
			{ BackgroundTransparency = RANK.GlowFade[1] }
		)
		glow.BackgroundTransparency = RANK.GlowFade[2]
		pulse:Play()
		table.insert(stops, function()
			turn:Cancel()
			pulse:Cancel()
			glow.BackgroundTransparency = RANK.GlowFade[2]
		end)
		-- Stars around the trophy (a little past its edges), clear of the words.
		table.insert(stops, Kit.twinkle(art, { Every = RANK.TwinkleEvery, Inset = -0.3, ZIndex = 5 }))
		table.insert(stops, Kit.shimmer(frame, RANK.ShineEvery, 6))
	end
	return {
		frame = frame,
		layout = layout,
		paint = function(headline: string, goal: string, lead: boolean)
			title.Text = headline
			line.Text = goal
			if lead == leading then
				return
			end
			leading = lead
			rays.Visible = lead
			if lead then
				Kit.paintGlass(frame, C.Gold, Theme.Glass.SurfaceHi, C.Gold)
			else
				Kit.paintGlass(frame)
			end
			layout(height)
			motion()
			if lead and playing and not PREVIEW then
				Kit.pop(frame, RANK.LeadPop)
			end
		end,
		stat = function(i: number, value: string, caption: string)
			tiles[i].value.Text = value
			tiles[i].caption.Text = caption
		end,
		play = function(on: boolean)
			playing = on
			motion()
		end,
	}
end

local function buildRanking(screen: ScreenGui)
	-- Minimum 386 tall: a phone gets that window at x1.3 (see layoutRows).
	local window = Kit.window(screen, "Ranking", "Ranking", I.Ranking, C.Window.Ranking, Vector2.new(780, 560), Vector2.new(600, 386))
	register("Ranking", window)
	local query = Net.func("Query")
	local action = Net.event("Action")
	local board: Board = "units"

	-- Toolbar: the board tabs on the left, number format and refresh on the right.
	local formatButton = Kit.button(window.content, {
		Name = "Format",
		Text = "Full numbers",
		Color = C.SurfaceHi,
		Size = UDim2.fromOffset(150, 42),
		Position = UDim2.new(1, -140, 0, 0),
		AnchorPoint = Vector2.new(1, 0),
		TextSize = RANK.ButtonText,
	})
	local refreshButton = Kit.button(window.content, {
		Name = "Refresh",
		Text = "Refresh",
		Color = C.Window.Ranking,
		Size = UDim2.fromOffset(130, 42),
		Position = UDim2.new(1, 0, 0, 0),
		AnchorPoint = Vector2.new(1, 0),
		TextSize = RANK.ButtonText,
	})
	local subtitle = Kit.text(window.content, {
		Name = "Subtitle",
		Text = "Most " .. W.Units .. " collected",
		Font = F.UI,
		TextSize = T.Body,
		MinPx = true,
		TextWrapped = false,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Size = UDim2.new(1, -14, 0, 22),
		Position = UDim2.fromOffset(4, 48),
		TextXAlignment = Enum.TextXAlignment.Left,
		TextColor3 = C.GoldLight,
	})

	local header = Kit.new("Frame", {
		Name = "Columns",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, -14, 0, 24),
		Position = UDim2.fromOffset(0, 72),
		Parent = window.content,
	})
	local headers: { [Board]: { TextLabel } } = { units = {}, stage = {} }
	local function headerText(boards: { Board }, text: string, x: number, w: number, align: Enum.TextXAlignment)
		local label = Kit.text(header, {
			Text = text,
			Font = F.UI,
			TextSize = RANK.HeadText,
			MinPx = RANK.HeadPx,
			TextWrapped = false,
			Size = UDim2.new(w, 0, 1, 0),
			Position = UDim2.fromScale(x, 0),
			TextXAlignment = align,
			TextColor3 = SMALL_TEXT,
		})
		for _, key in boards do
			table.insert(headers[key], label)
		end
	end
	headerText({ "units", "stage" }, "RANK", 0.02, 0.14, Enum.TextXAlignment.Left)
	headerText({ "units", "stage" }, "PLAYER", 0.17, 0.4, Enum.TextXAlignment.Left)
	headerText({ "units" }, "COLLECTED", 0.62, 0.36, Enum.TextXAlignment.Right)
	headerText({ "stage" }, "STAGE", 0.64, 0.16, Enum.TextXAlignment.Right)
	headerText({ "stage" }, "CLEARS", 0.82, 0.16, Enum.TextXAlignment.Right)

	local list = Kit.scrolling(window.content, { Size = UDim2.new(1, 0, 1, -174), Position = UDim2.fromOffset(0, 100) })
	-- Rows are not buttons: the list itself is selectable so a gamepad can scroll it.
	Kit.selectable(list)
	Kit.new("UIPadding", {
		PaddingRight = UDim.new(0, 14),
		PaddingTop = UDim.new(0, 4),
		PaddingLeft = UDim.new(0, 2),
		PaddingBottom = UDim.new(0, 10),
		Parent = list,
	})
	Kit.list(list, 8)

	-- The player's own card, pinned right under the list with a sunny outline: their row (one
	-- face per board, only while they are not in the list itself) over the goal, which
	-- always names a target: "12 more to pass <name>" on a dark pill, over a slim bar filled
	-- as far as they have come.
	local MINE_H, GOAL_H = RANK.MineH, RANK.GoalH
	local mine = Kit.panel(window.content, {
		Name = "Mine",
		Glass = true,
		Elevated = true,
		StrokeColor = C.Gold,
		StrokeThickness = 2.5,
		Size = UDim2.new(1, -14, 0, MINE_H + GOAL_H),
		Radius = Kit.RADIUS.M,
	})
	local function mineFace(name: string): Frame
		return Kit.new("Frame", { Name = name, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, MINE_H), Parent = mine })
	end
	local mineUnits = mineFace("Units")
	local mineStage = mineFace("Stage")
	local goalLabel: TextLabel
	local setGoal: (number, boolean?) -> ()
	do
		-- The text is not on the bar: over the gold fill it could not be read.
		local pill = Kit.new("Frame", {
			Name = "GoalLine",
			BackgroundColor3 = C.Ink,
			BackgroundTransparency = 0.25,
			BorderSizePixel = 0,
			Size = UDim2.new(1, -20, 0, RANK.GoalPillH),
			Position = UDim2.new(0, 10, 1, -(RANK.GoalBarH + 14)),
			AnchorPoint = Vector2.new(0, 1),
			Parent = mine,
		})
		Kit.round(pill)
		goalLabel = readable(Kit.text(pill, {
			Name = "Label",
			Text = "",
			Font = F.Bold,
			TextSize = RANK.GoalText,
			TextWrapped = false,
			TextTruncate = Enum.TextTruncate.AtEnd,
			TextColor3 = Color3.new(1, 1, 1),
			Size = UDim2.new(1, -24, 1, 0),
			Position = UDim2.fromOffset(12, 0),
			StrokeThickness = 0,
		}))
		local _, set, barLabel = Kit.progress(mine, {
			Name = "Goal",
			Glass = true,
			Color = C.Gold,
			Size = UDim2.new(1, -20, 0, RANK.GoalBarH),
			Position = UDim2.new(0, 10, 1, -8),
			AnchorPoint = Vector2.new(0, 1),
			MinFill = 0.04,
		})
		barLabel.Visible = false
		setGoal = set
	end

	-- The card under the pinned one takes the room the list leaves (rankingInfo): a young
	-- board is shown as it is, and its empty half goes to the player's own goal and numbers.
	local info = rankingInfo(window.content)

	-- The list is as tall as its rows (it scrolls once they pass the room there is), the
	-- pinned card sits right under it and the info card fills what is left under that.
	-- Short windows (a phone): the subtitle goes and the columns and list move up into its row.
	local ROW_GAP = RANK.RowGap
	local rowCount = 0
	local rowsTall = 0 -- the rows' heights and the gaps between them
	local podiumTall = 0 -- ... of the first three (the podium, taken or open)
	local pinned = true
	-- The player's own row is on the board / is its first row.
	local listed = false
	local leading = false
	local function layoutRows(size: Vector2)
		local short = size.Y < 440
		local top = if short then 48 else 72
		subtitle.Visible = not short
		header.Position = UDim2.fromOffset(0, top)
		local inner = size.Y - 104 -- window chrome and the content padding
		local y = top + 28
		-- The goal bar alone while the player's row is in the list.
		local mineH = if pinned then MINE_H + GOAL_H else GOAL_H
		local pinH = mineH + ROW_GAP
		-- Rows plus the list's own padding (4 above, 10 below).
		local rowsH = if rowCount > 0 then rowsTall + 14 else 0
		-- The leader's trophy card keeps its room: a long list gives way to it.
		local keep = if leading and not short then RANK.LeadKeep else 0
		-- ... but never the podium: its three steps show in full while there is room at all.
		local podiumH = if rowCount > 0 then podiumTall + 14 else 0
		local room = inner - y - pinH
		local listH = math.max(0, math.min(room, rowsH, math.max(podiumH, room - keep)))
		list.Position = UDim2.fromOffset(0, y)
		list.Size = UDim2.new(1, 0, 0, listH)
		list.Visible = listH > 0
		y += listH
		mine.Size = UDim2.new(1, -14, 0, mineH)
		mine.Position = UDim2.fromOffset(0, y)
		y += pinH
		local left = inner - y
		info.frame.Visible = left >= RANK.InfoMin
		info.frame.Position = UDim2.new(0.5, -7, 0, y)
		info.frame.Size = UDim2.new(1, -14, 0, math.max(left, RANK.InfoMin))
		info.layout(math.max(left, RANK.InfoMin))
	end
	layoutRows(window.size())
	window.onResize.Event:Connect(layoutRows)
	Kit.scrollCue(list)

	-- One row: rank chip, name, the board value and (stage board) the clears column.
	local function row(
		parent: Instance,
		rank: number?,
		rankText: string,
		name: string,
		value: string,
		isMe: boolean,
		extra: string?
	): RowLabels
		local color = rank and MEDAL_COLORS[rank]
		local place = if color then rank :: number else 0
		local medal = if color then RANK.MedalSize[place] else 0
		local rankChip = Kit.new("Frame", {
			Name = "Rank",
			BackgroundColor3 = color or C.Ink,
			BackgroundTransparency = if color then 0 else Theme.Glass.Inset,
			Size = UDim2.fromOffset(if color then medal else 52, if color then medal else 32),
			Position = UDim2.new(0.02, if color then (52 - medal) // 2 else 0, 0.5, 0),
			AnchorPoint = Vector2.new(0, 0.5),
			Parent = parent,
		})
		if color then
			-- Solid medal coin, lighter on top, with a darker rim.
			Kit.round(rankChip)
			Kit.gradient(rankChip, Color3.new(1, 1, 1), Color3.new(0.86, 0.86, 0.9))
			Kit.new("UIStroke", { Thickness = 2.5, Color = Kit.lip(color), Parent = rankChip })
		else
			Kit.corner(rankChip, 10)
			Kit.new("UIStroke", { Thickness = 1, Color = Theme.Glass.Edge, Transparency = 0.8, Parent = rankChip })
		end
		local rankLabel = Kit.number(rankChip, {
			Text = if color then tostring(rank) else rankText,
			TextSize = if color then RANK.MedalText[place] else RANK.RankText,
			Size = UDim2.fromScale(1, 1),
			TextColor3 = if color then C.GoldInk else C.TextDim,
			StrokeThickness = if color then 0 else nil,
		})
		Kit.text(parent, {
			Name = "Name",
			Text = name,
			Font = F.UI,
			TextSize = if color then RANK.PodiumName[place] else RANK.NameText,
			TextWrapped = false,
			TextTruncate = Enum.TextTruncate.AtEnd,
			Size = UDim2.new(0.38, 0, 1, 0),
			Position = UDim2.fromScale(0.17, 0),
			TextXAlignment = Enum.TextXAlignment.Left,
			TextColor3 = C.Text,
		})
		if isMe then
			Kit.pill(parent, {
				Text = "YOU",
				Color = C.Gold,
				Solid = true,
				TextSize = RANK.RankText,
				Size = UDim2.fromOffset(RANK.YouPill.X, RANK.YouPill.Y),
				Position = UDim2.new(0.62, 0, 0.5, 0),
				AnchorPoint = Vector2.new(1, 0.5),
			})
		end
		local valueLabel = Kit.number(parent, {
			Name = "Value",
			Text = value,
			TextSize = if color then RANK.PodiumValue[place] else RANK.ValueText,
			Size = UDim2.new(if extra then 0.16 else 0.34, 0, 1, 0),
			Position = UDim2.new(if extra then 0.8 else 0.98, 0, 0, 0),
			AnchorPoint = Vector2.new(1, 0),
			TextXAlignment = Enum.TextXAlignment.Right,
			TextColor3 = if color then C.GoldLight else C.Text,
		})
		local extraLabel: TextLabel? = nil
		if extra then
			extraLabel = Kit.number(parent, {
				Name = "Clears",
				Text = extra,
				TextSize = RANK.ExtraText,
				Size = UDim2.new(0.16, 0, 1, 0),
				Position = UDim2.new(0.98, 0, 0, 0),
				AnchorPoint = Vector2.new(1, 0),
				TextXAlignment = Enum.TextXAlignment.Right,
				TextColor3 = C.TextDim,
			})
		end
		return { rank = rankLabel, chip = rankChip, value = valueLabel, extra = extraLabel }
	end

	local entries: { any } = {}
	local stageEntries: { any } = {}
	-- The server's Standing per board (Ranking.standing): rank, the players right above and below.
	local standing: { [string]: any } = {}
	local global = true
	local loaded = false
	local updatedAt = 0
	local listFull: boolean? = nil
	local mineLabels: RowLabels = row(mineUnits, nil, "--", Players.LocalPlayer.Name, "0", false)
	local mineStageLabels: RowLabels = row(mineStage, nil, "--", Players.LocalPlayer.Name, "0", false, "0")
	local mineValue: number? = nil

	local function fullNumbers(): boolean
		local data = State.data
		return data ~= nil and data.settings.fullNumbers == true
	end
	local function fmt(n: number): string
		return if fullNumbers() then Format.commas(n) else Format.short(n)
	end
	local function isMine(entry: any): boolean
		local me = Players.LocalPlayer
		if entry.userId ~= nil then
			return tonumber(entry.userId) == me.UserId
		end
		return entry.name == me.Name or entry.name == me.DisplayName
	end

	-- An empty podium step: the medal row at `rank`, faint, its coin numbered, the name
	-- `text` and no score. Its outline breathes while the window is open.
	local function openSpot(rank: number, text: string): Frame
		local medal = MEDAL_COLORS[rank]
		local frame = Kit.glass(list, {
			Name = "Open" .. rank,
			Size = UDim2.new(1, 0, 0, RANK.PodiumH[rank]),
			LayoutOrder = rank,
			Radius = Kit.RADIUS.M + 2,
			StrokeThickness = RANK.PodiumEdge,
		})
		Kit.paintGlass(frame, medal, RANK.OpenTint, medal)
		local edge = frame:FindFirstChildOfClass("UIStroke")
		if edge then
			edge.Transparency = RANK.OpenEdge
			if not PREVIEW then
				TweenService:Create(
					edge,
					TweenInfo.new(RANK.OpenBreathe, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
					{ Transparency = 0.75 }
				):Play()
			end
		end
		local labels = row(frame, rank, "#" .. rank, text, "", false)
		labels.chip.BackgroundTransparency = RANK.OpenCoin
		labels.rank.TextTransparency = 0.25
		local name = frame:FindFirstChild("Name")
		if name and name:IsA("TextLabel") then
			name.TextColor3 = Kit.lighten(medal, 0.55)
			name.Size = UDim2.new(0.8, 0, 1, 0)
		end
		return frame
	end

	-- Rebuilds the leaderboard rows; `animate` ripples them in. The top three are the podium:
	-- taller rows of glass in their medal's colour with a big medal coin, the gold one under a
	-- passing sheen. The player's own row wears a thick gold outline wherever it is.
	local function renderList(animate: boolean)
		clearChildren(list)
		listFull = fullNumbers()
		local rows: { GuiObject } = {}
		local shown = if board == "stage" then stageEntries else entries
		local mineAt = 0
		rowsTall = 0
		podiumTall = 0
		for i, entry in shown do
			if type(entry) ~= "table" then
				continue
			end
			local isMe = isMine(entry)
			local rank = tonumber(entry.rank) or i
			local medal = MEDAL_COLORS[rank]
			local frame: Frame
			if medal then
				frame = Kit.glass(list, {
					Name = "Row" .. i,
					Size = UDim2.new(1, 0, 0, RANK.PodiumH[rank]),
					LayoutOrder = i,
					Radius = Kit.RADIUS.M + 2,
					StrokeThickness = if isMe then RANK.MineEdge else RANK.PodiumEdge,
				})
				Kit.paintGlass(frame, medal, Theme.Glass.SurfaceHi, if isMe then C.Gold else medal)
				if rank == 1 and not PREVIEW then
					Kit.shimmer(frame, RANK.GoldShine, 4)
				end
			else
				frame = Kit.panel(list, {
					Name = "Row" .. i,
					Glass = true,
					Elevated = isMe,
					StrokeColor = if isMe then C.Gold else nil,
					StrokeThickness = if isMe then RANK.MineEdge else nil,
					Size = UDim2.new(1, 0, 0, RANK.RowH),
					LayoutOrder = i,
					Radius = Kit.RADIUS.M,
				})
			end
			if isMe then
				mineAt = #rows + 1
			end
			rowsTall += (if medal then RANK.PodiumH[rank] else RANK.RowH) + (if #rows > 0 then ROW_GAP else 0)
			if #rows < #MEDAL_COLORS then
				podiumTall = rowsTall
			end
			local name = tostring(entry.name or "?")
			if board == "stage" then
				local stage = tonumber(entry.stage) or tonumber(entry.value) or 0
				row(frame, rank, "#" .. rank, name, tostring(stage), isMe, Format.commas(tonumber(entry.clears) or 0))
			else
				row(frame, rank, "#" .. rank, name, fmt(tonumber(entry.value) or 0), isMe)
			end
			table.insert(rows, frame)
		end
		-- One or two players: the empty podium steps under them, faint and waiting.
		if #rows > 0 and #rows < #MEDAL_COLORS then
			for rank = #rows + 1, #MEDAL_COLORS do
				local frame = openSpot(rank, if mineAt > 0 then RANK.OpenOther else RANK.OpenName)
				rowsTall += RANK.PodiumH[rank] + ROW_GAP
				podiumTall = rowsTall
				table.insert(rows, frame)
			end
		end
		rowCount = #rows
		listed = mineAt > 0
		local first = shown[1]
		leading = type(first) == "table" and isMine(first)
		-- High on the board the player's row is in sight: no second, pinned copy of it. Lower
		-- down it scrolls away, so it is pinned under the list as well.
		pinned = not listed or mineAt > RANK.PinAfter
		layoutRows(window.size())
		if animate then
			Kit.stagger(rows)
		end
	end

	local fetch: () -> ()
	-- A target passed since the last fetch asks for fresh ranks, once per target.
	local passedKey = ""
	local function passed(name: string, score: number): (string, number)
		local key = name .. ":" .. score
		if passedKey ~= key and window.isOpen() then
			passedKey = key
			task.delay(3, function()
				if window.isOpen() then
					fetch()
				end
			end)
		end
		return string.format("You passed %s!", name), 1
	end

	-- Without a Standing from the server: the row above the player's own in the list.
	local function rowAbove(rows: { any }): any
		for i, entry in rows do
			if type(entry) == "table" and isMine(entry) then
				return rows[i - 1]
			end
		end
		return nil
	end

	-- The goal bar of the units board: text and how far along (0..1). Somebody ahead: how
	-- many more it takes to pass them. Nobody ahead: the next round count.
	local function unitsGoal(total: number): (string, number)
		local you = standing.units
		local above = if type(you) == "table" then you.above else rowAbove(entries)
		if type(above) == "table" then
			local theirs = tonumber(above.value) or 0
			local gap = theirs - total + 1
			local name = tostring(above.name or "?")
			if gap <= 0 then
				return passed(name, theirs)
			end
			-- Under the listed top with nobody from this server in between: the last listed
			-- place is the target.
			local cap = if type(you) == "table" then tonumber(you.cap) or 0 else 0
			local text = if cap > 0
					and you.rank == nil
					and not you.aboveHere
				then string.format("%s more to reach the top %d", fmt(gap), cap)
				else string.format("%s more to pass %s", fmt(gap), name)
			return text, total / (theirs + 1)
		end
		local goal = nextMilestone(total)
		if goal <= total then
			return string.format("%s collected", fmt(total)), 1
		end
		return string.format("Next goal: %s more to reach %s collected", fmt(goal - total), fmt(goal)), total / goal
	end

	-- The same for the stage board: stages to catch the player ahead, then clears to pass them.
	local function stageGoal(stage: number, clears: number): (string, number)
		if stage <= 0 then
			return "Finish Parkour map 1 to get on this board", 0
		end
		local you = standing.stage
		local above = if type(you) == "table" then you.above else rowAbove(stageEntries)
		if type(above) ~= "table" then
			return "Clear more maps to stay ahead", 1
		end
		local name = tostring(above.name or "?")
		local theirStage = tonumber(above.stage) or 0
		local theirClears = tonumber(above.clears) or 0
		if theirStage > stage then
			return string.format("%s to catch %s", countOf(theirStage - stage, "stage"), name), stage / theirStage
		end
		local gap = theirClears - clears + 1
		if theirStage < stage or gap <= 0 then
			return passed(name, theirStage * 1e6 + theirClears)
		end
		return string.format("%s to pass %s", countOf(gap, "clear"), name), clears / (theirClears + 1)
	end

	-- The info card's headline and its goal in full, for the board as it is: a young board is
	-- not padded with made-up names, the player is told what to do on it.
	local function infoWords(total: number): (string, string)
		local shown = if board == "stage" then stageEntries else entries
		local first, second = shown[1], shown[2]
		local firstName = if type(first) == "table" then tostring(first.name or "them") else "them"
		if not loaded then
			return "LOADING...", "Fetching the top players"
		elseif leading then
			return "YOU'RE #1!",
				if type(second) == "table"
					then string.format("%s is right behind you. Stay ahead!", tostring(second.name or "Someone"))
					elseif board == "stage" then "Nobody else has cleared a stage yet. Stay on top!"
					else string.format("Nobody else is here yet. Every %s counts: build your lead!", W.Unit)
		elseif board == "stage" then
			if listed then
				return "TAKE THE #1 SPOT!", string.format("Pass %s and the gold medal is yours.", firstName)
			elseif rowCount == 0 then
				return "NO STAGES CLEARED YET", "Finish Parkour map 1 and your name is the first one here."
			end
			return "JOIN THE BOARD!", "Finish Parkour map 1 to put your name on this board."
		end
		local you = standing.units
		local cap = if type(you) == "table" then tonumber(you.cap) or 0 else 0
		local count = if type(you) == "table" then tonumber(you.count) or rowCount else rowCount
		local edge = if type(you) == "table" then you.edge else nil
		-- Under a full board: the last listed row is the way in.
		if not listed and type(edge) == "table" and cap > 0 then
			local gap = math.max(1, (tonumber(edge.value) or 0) - total + 1)
			return string.format("REACH THE TOP %d!", cap),
				string.format("Collect %s more %s to reach the top %d.", fmt(gap), if gap == 1 then W.Unit else W.Units, cap)
		elseif type(first) ~= "table" then
			return "TAKE THE #1 SPOT!", "Be the first name on the board!"
		end
		local gap = (tonumber(first.value) or 0) - total + 1
		local goal = if gap > 0
			then string.format(
				"Collect %s more %s to pass %s and take the gold medal.",
				fmt(gap),
				if gap == 1 then W.Unit else W.Units,
				firstName
			)
			else string.format("Pass %s and the gold medal is yours.", firstName)
		-- A young board: everybody on it is in the listed top already.
		if listed and cap > 0 and count < cap then
			goal ..= string.format(" Only %d on the board so far: you are in the top %d!", count, cap)
		end
		return "TAKE THE #1 SPOT!", goal
	end

	-- Pinned card, format button, column headers and subtitle.
	local function renderInfo()
		local data = State.data
		local myRank: number? = nil
		local myStageRank: number? = nil
		for i, entry in entries do
			if type(entry) == "table" and isMine(entry) then
				myRank = tonumber(entry.rank) or i
			end
		end
		for i, entry in stageEntries do
			if type(entry) == "table" and isMine(entry) then
				myStageRank = tonumber(entry.rank) or i
			end
		end
		mineUnits.Visible = pinned and board == "units"
		mineStage.Visible = pinned and board == "stage"
		for _, labels in headers do
			for _, label in labels do
				label.Visible = false
			end
		end
		for _, label in headers[board] do
			label.Visible = true
		end
		-- Under the listed top the place is not known: "50+".
		local function rankText(rank: number?, you: any): string
			if rank then
				return "#" .. rank
			end
			local cap = if type(you) == "table" and not you.unranked then tonumber(you.cap) else nil
			return if cap then cap .. "+" else "--"
		end
		mineLabels.rank.Text = rankText(myRank, standing.units)
		local total = data and data.totalObtained or 0
		if mineValue and mineValue ~= total and window.isOpen() then
			Kit.countTo(mineLabels.value, mineValue, total, fmt)
		else
			mineLabels.value.Text = fmt(total)
		end
		mineValue = total
		local stage, clears = myStage()
		mineStageLabels.rank.Text = rankText(myStageRank, standing.stage)
		mineStageLabels.value.Text = tostring(stage)
		local clearsLabel = mineStageLabels.extra
		if clearsLabel then
			clearsLabel.Text = Format.commas(clears)
		end
		Kit.setButton(formatButton, if fullNumbers() then "Short numbers" else "Full numbers")
		formatButton.Visible = board == "units"
		local updated = ""
		if loaded and updatedAt > 0 then
			local ago = math.max(0, State.now() - updatedAt)
			updated = if ago < 60
				then "  •  updated just now"
				elseif ago < 3600 then string.format("  •  updated %dm ago", ago // 60)
				else string.format("  •  updated %dh ago", ago // 3600)
		end
		local where = if loaded and not global then "  •  this server" else ""
		subtitle.Text = (if board == "stage" then "Highest sky obby stage" else "Most " .. W.Units .. " collected") .. where .. updated
		local goalText, ratio
		if board == "stage" then
			goalText, ratio = stageGoal(stage, clears)
		else
			goalText, ratio = unitsGoal(total)
		end
		goalLabel.Text = goalText
		setGoal(if ratio == ratio then ratio else 0)
		-- The info card: headline and goal, then the player's own numbers.
		do
			local headline, goal = infoWords(total)
			info.paint(headline, goal, leading and loaded)
			if board == "stage" then
				info.stat(1, tostring(stage), "BEST STAGE")
				info.stat(2, Format.commas(clears), "MAP CLEARS")
				info.stat(3, rankText(myStageRank, standing.stage), "YOUR RANK")
			else
				info.stat(1, fmt(total), "YOUR " .. string.upper(W.Units))
				info.stat(2, rankText(myRank, standing.units), if global then "WORLD RANK" else "YOUR RANK")
				local you = standing.units
				local here = if type(you) == "table" then tonumber(you.serverCount) or 0 else 0
				if global and here > 0 and (tonumber(you.serverRank) or 0) > 0 then
					info.stat(3, string.format("#%d of %d", you.serverRank, here), "IN THIS SERVER")
				else
					info.stat(3, tostring(stage), "BEST STAGE")
				end
			end
		end
	end

	-- Board tabs (built after the rows' helpers: Kit.tabs selects the first one at once).
	local tabsReady = false
	Kit.tabs(window.content, {
		Name = "Boards",
		Items = { { key = "units", text = W.Units }, { key = "stage", text = "Stage" } },
		Color = C.Window.Ranking,
		Size = UDim2.fromOffset(230, 42),
		TextSize = RANK.ButtonText,
	}, function(key: string)
		board = if key == "stage" then "stage" else "units"
		if tabsReady and window.isOpen() then
			renderList(true)
			renderInfo()
		end
	end)
	tabsReady = true

	formatButton.Activated:Connect(function()
		local data = State.data
		if data then
			action:FireServer({ action = "SetSetting", key = "fullNumbers", value = not data.settings.fullNumbers })
		end
	end)

	local fetching = false
	local lastFetch = -math.huge
	function fetch()
		if fetching or os.clock() - lastFetch < 3 then
			return
		end
		fetching = true
		lastFetch = os.clock()
		Kit.setEnabled(refreshButton, false)
		task.spawn(function()
			local ok, result = pcall(query.InvokeServer, query, "Ranking")
			fetching = false
			Kit.setEnabled(refreshButton, true)
			if ok and type(result) == "table" then
				entries = if type(result.entries) == "table" then result.entries else {}
				stageEntries = if type(result.stage) == "table" then result.stage else {}
				standing = if type(result.you) == "table" then result.you else {}
				global = result.global ~= false
				updatedAt = result.updatedAt or State.now()
				loaded = true
				if window.isOpen() then
					renderList(true)
					renderInfo()
				end
			end
		end)
	end
	refreshButton.Activated:Connect(fetch)

	window.onOpen.Event:Connect(function()
		-- Rows are rebuilt (and ripple in) on every open; they are created after
		-- the window's own fade starts, so they fade themselves.
		renderList(true)
		renderInfo()
		info.play(true)
		fetch()
	end)
	window.onClose.Event:Connect(function()
		info.play(false)
	end)
	State.changed.Event:Connect(function()
		if not window.isOpen() then
			return
		end
		if listFull ~= fullNumbers() then
			renderList(false)
		end
		renderInfo()
	end)
end

-- Settings ------------------------------------------------------------------------------

local SETTINGS_LABEL = 20 -- a setting's name, px on a desktop screen (its sub-line is a window caption)
local function buildSettings(screen: ScreenGui)
	-- Sized to its four rows and the two-line "Before you go" row: 4 x 70 + 40 + 4 x 10 gaps
	-- + 20 padding + 84 of header and margins. The rows share the height left by that row,
	-- so the 386 minimum (a phone, scaled up x1.3) has 50 px rows.
	local window = Kit.window(screen, "Settings", "Settings", I.Settings, C.Window.Settings, Vector2.new(560, 464), Vector2.new(560, 386))
	register("Settings", window)
	local action = Net.event("Action")

	Kit.list(window.content, 10)

	local rows: { GuiObject } = {}
	local toggles: { { key: string, set: (boolean, boolean?) -> (), sub: TextLabel, medal: Frame } } = {}
	local function toggle(order: number, icon: string, text: string, desc: string, key: string)
		local row = Kit.panel(window.content, {
			Name = key,
			Glass = true,
			Size = UDim2.new(1, 0, 0.25, -20),
			LayoutOrder = order,
			Radius = Kit.RADIUS.M + 2,
		})
		table.insert(rows, row)
		-- Icon tile: a dark pane that warms to the window's teal while the setting is on.
		local medal = Kit.new("Frame", {
			Name = "Medal",
			BackgroundColor3 = C.Ink,
			BackgroundTransparency = Theme.Glass.Inset,
			Size = UDim2.fromOffset(46, 46),
			Position = UDim2.new(0, 12, 0.5, 0),
			AnchorPoint = Vector2.new(0, 0.5),
			Parent = row,
		})
		Kit.corner(medal, 14)
		Kit.new("UIStroke", { Thickness = 1.5, Color = Theme.Glass.Edge, Transparency = 0.75, Parent = medal })
		Kit.icon(medal, icon, 26, Kit.ICON_COLORS[icon] or C.Text, {
			Position = UDim2.fromScale(0.5, 0.5),
			AnchorPoint = Vector2.new(0.5, 0.5),
			ZIndex = 2,
		})
		-- The row's label is body text (SETTINGS_LABEL px on a desktop screen), its sub-line a
		-- caption (Kit.WINDOW.TextPx): both are held on the glass, so a fitted window cannot
		-- shrink them under that.
		Kit.text(row, {
			Text = string.upper(text),
			Font = F.UI,
			TextSize = T.Body,
			MinPx = if Kit.touch then Kit.captionPx() + 2 else SETTINGS_LABEL,
			TextWrapped = false,
			Size = UDim2.new(1, -170, 0, 24),
			Position = UDim2.new(0, 72, 0.5, -26),
			TextXAlignment = Enum.TextXAlignment.Left,
		})
		local sub = Kit.text(row, {
			Text = desc,
			TextSize = T.Small,
			MinPx = true,
			TextWrapped = false,
			TextTruncate = Enum.TextTruncate.AtEnd,
			Size = UDim2.new(1, -176, 0, 22),
			Position = UDim2.new(0, 72, 0.5, 1),
			TextXAlignment = Enum.TextXAlignment.Left,
			TextYAlignment = Enum.TextYAlignment.Top,
			TextColor3 = C.TextDim,
		})
		local _, set = Kit.switch(row, {
			Name = "Switch",
			Large = true,
			Position = UDim2.new(1, -16, 0.5, 0),
			AnchorPoint = Vector2.new(1, 0.5),
		}, function()
			local data = State.data
			if not data then
				return
			end
			local current = if key == "autoMerge" then data.autoMerge else data.settings[key]
			action:FireServer({ action = "SetSetting", key = key, value = not current })
		end)
		table.insert(toggles, { key = key, set = set, sub = sub, medal = medal })
	end
	toggle(1, "Music", "Music", "Background music", "music")
	toggle(2, "Sound", "Sound Effects", "Clicks, pickups and rewards", "sfx")
	toggle(3, "Hash", "Full Numbers", "Show 1,234,567 instead of 1.23M", "fullNumbers")
	toggle(4, "Merge", "Auto Merge", "Merge pairs automatically", "autoMerge")
	-- "Before you go" (Shared.Comeback): what waits for the player next time, under the
	-- switches (Settings is where a player goes last): a gift icon and up to two lines of
	-- light text, since it explains what a child comes back to.
	local leaveRow = Kit.new("Frame", {
		Name = "Leave",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 44),
		LayoutOrder = 5,
		Visible = false,
		Parent = window.content,
	})
	Kit.icon(leaveRow, Kit.pickIcon("Gift2", "Star"), 26, C.Gold, {
		Name = "Icon",
		Position = UDim2.new(0, 6, 0.5, 0),
		AnchorPoint = Vector2.new(0, 0.5),
	})
	local leave = readable(Kit.text(leaveRow, {
		Name = "Line",
		Text = "",
		TextSize = T.Small,
		TextColor3 = C.Text,
		TextWrapped = true,
		TextTruncate = Enum.TextTruncate.AtEnd,
		TextXAlignment = Enum.TextXAlignment.Left,
		Size = UDim2.new(1, -44, 1, 0),
		Position = UDim2.fromOffset(40, 0),
		StrokeThickness = 0,
	}))

	local ON_TILE = C.Ink:Lerp(C.Window.Settings, 0.55)
	local function refresh()
		local data = State.data
		if not data then
			return
		end
		leave.Text = Comeback.leaveLine(data, { money = State.money, words = W, age = State.age() })
		leaveRow.Visible = leave.Text ~= ""
		for _, t in toggles do
			local on: boolean
			if t.key == "autoMerge" then
				on = data.autoMergeOwned == true and data.autoMerge == true
				if data.autoMergeOwned then
					t.set(data.autoMerge)
					t.sub.Text = "Merge pairs automatically"
				else
					t.set(false, true)
					t.sub.Text = "Game pass: "
						.. Kit.hint("tap", "click", "press")
						.. " to get it ("
						.. price(Theme.Monetization.Passes.AutoMerge.Price)
						.. ")"
				end
			else
				on = data.settings[t.key] == true
				t.set(on)
			end
			Kit.tween(t.medal, 0.2, {
				BackgroundColor3 = if on then ON_TILE else C.Ink,
				BackgroundTransparency = if on then 0.25 else Theme.Glass.Inset,
			})
		end
	end
	State.changed.Event:Connect(refresh)
	window.onOpen.Event:Connect(refresh)

	beforeOpen.Settings = function()
		refresh()
		ripple(rows)
	end
end

-- Game Modes --------------------------------------------------------------------------------
--[[
	The plaza game modes, one card each in the same arrangement, tinted in the mode's own
	colour: a thumbnail (a sea scene for Parkour, the player's best unit for MOG TEST; a
	narrow window shrinks it to a medal), title, blurb, stats, the reward chip (solid mint
	while the full reward is up, dim through the cooldown) and a gold PLAY that fires
	ModeStart and closes the window, then one slim "More modes coming soon" row.

	Parkour shows the preselected map (the player's unlocked level, re-synced whenever the
	window opens): its name, difficulty (10 pips), best and clears and what finishing it
	pays, beside PLAY (starts that map) and CHOOSE MAP (opens the Maps window,
	MapPicker.luau, where every map is picked from a card grid with a 3D preview).

	MOG TEST: best score, rivals mogged and passes, reward line, PLAY (disabled
	"PLAYING" while a test runs) opens the VS RIVALS / 1v1 DUEL picker (Windows.onMogPlay). Reads State.data.modes.parkour and .mog.
]]
local function runTime(seconds: number): string
	local tenths = math.floor(math.max(seconds, 0) * 10 + 0.5)
	return string.format("%d:%02d.%d", tenths // 600, (tenths // 10) % 60, tenths % 10)
end

local function plural(n: number, word: string, many: string?): string
	return string.format("%d %s", n, if n == 1 then word else many or word .. "s")
end

-- The reward chip of a mode card. `full`: the whole reward is up (solid mint, the card's
-- one highlight beside PLAY); else the dim chip of a cooldown. No text hides it.
local function paintReward(label: TextLabel, text: string, full: boolean)
	label.Text = text
	label.Visible = text ~= ""
	label.BackgroundTransparency = if full then 0 else 0.72
	label.BackgroundColor3 = if full then C.Good else C.Ink
	label.TextColor3 = if full then Kit.inkOn(C.Good) else C.TextDim
	local edge = label:FindFirstChild("Edge")
	if edge and edge:IsA("UIStroke") then
		edge.Color = if full then Kit.lip(C.Good) else Theme.Glass.Edge
		edge.Transparency = if full then 0 else 0.7
	end
end

-- Seconds a reward preview's run again bonus still rests (`repeatRest`, counted down by the
-- snapshot's age); 0 = awake.
local function previewRest(preview: { [string]: any }): number
	return math.max(0, math.ceil((tonumber(preview.repeatRest) or 0) - State.age()))
end

-- "Finish: +$X" or the cooldown countdown; `bonus` adds a "(xB)" tag. `repeatCash`: what a
-- finish really pays inside the cooldown (the run again bonus: a share of the reward; 0 or
-- nil when it pays nothing, e.g. Parkour gear), named beside the countdown to the full reward.
-- `rest`: seconds that bonus still rests (it was paid a moment ago), said instead.
local function setRewardLine(
	label: TextLabel,
	cash: number,
	full: boolean,
	cooldownEnds: number,
	bonus: number?,
	repeatCash: number?,
	rest: number?
)
	local left = cooldownEnds - os.time()
	if not full and left > 0 then
		paintReward(
			label,
			if rest and rest > 0
				then "Bonus is resting, back in " .. Format.time(rest)
				elseif repeatCash and repeatCash >= 1 then string.format(
					"Run again: +%s  ·  full reward in %s",
					Format.money(repeatCash),
					Format.time(left)
				)
				else "Reward again in " .. Format.time(left),
			false
		)
		return
	end
	local text = "Finish: +" .. Format.money(cash)
	if bonus and bonus > 1.001 then
		text ..= string.format("  (×%s)", (string.format("%.1f", bonus):gsub("%.0$", "")))
	end
	paintReward(label, text, true)
end

local PIP_COUNT = 10

-- Width of a difficulty row's "Difficulty n/10" label and the gap between its items.
local PIP_LABEL_W = 112
local PIP_GAP = 3

-- Difficulty row: a fire icon, "Difficulty n/10" and 10 pips (gold warming to red). The number
-- always carries its word; in a row too narrow for everything the pips hide, never the
-- words. props: Name, Size, Position, Pip (pip size, default 10). Returns the setter.
local function difficultyPips(parent: Instance, props: { [string]: any }): (number) -> ()
	local pipSize = props.Pip or 10
	local row = Kit.new("Frame", {
		Name = props.Name or "Difficulty",
		BackgroundTransparency = 1,
		Size = props.Size,
		Position = props.Position,
		ZIndex = 2,
		Parent = parent,
	})
	Kit.list(row, PIP_GAP, true).VerticalAlignment = Enum.VerticalAlignment.Center
	Kit.icon(row, "Fire", pipSize + 6, C.Gold, { LayoutOrder = 0, ZIndex = 2 })
	local of = Kit.text(row, {
		Name = "Of10",
		Text = "",
		Font = F.UI,
		TextSize = T.Small,
		MinPx = true,
		TextWrapped = false,
		TextXAlignment = Enum.TextXAlignment.Left,
		Size = UDim2.fromOffset(PIP_LABEL_W, pipSize + 6),
		LayoutOrder = 1,
		TextColor3 = C.TextDim,
		ZIndex = 2,
	})
	local pips: { Frame } = {}
	for i = 1, PIP_COUNT do
		local pip = Kit.new("Frame", {
			Name = "Pip" .. i,
			BackgroundColor3 = C.Well,
			Size = UDim2.fromOffset(pipSize, pipSize),
			LayoutOrder = i + 1,
			ZIndex = 2,
			Parent = row,
		})
		Kit.corner(pip, 3)
		pips[i] = pip
	end
	-- The pips show only while the whole row fits (a row not laid out yet counts as wide).
	local need = (pipSize + 6) + PIP_GAP + PIP_LABEL_W + (pipSize + PIP_GAP) * PIP_COUNT
	local function fitPips()
		local width = row.AbsoluteSize.X
		local fits = width <= 0 or width >= need
		for _, pip in pips do
			pip.Visible = fits
		end
	end
	row:GetPropertyChangedSignal("AbsoluteSize"):Connect(fitPips)
	fitPips()
	return function(value: number)
		local difficulty = math.clamp(math.floor(value), 1, PIP_COUNT)
		for i, pip in pips do
			local on = i <= difficulty
			pip.BackgroundColor3 = if on then C.Gold:Lerp(C.Bad, (i - 1) / (PIP_COUNT - 1)) else C.Well
			pip.BackgroundTransparency = if on then 0 else 0.3
		end
		of.Text = string.format("Difficulty %d/%d", difficulty, PIP_COUNT)
	end
end

-- What finishing parkour `level` pays, from the snapshot `info` (modes.parkour).
-- rewardPreview is priced for info.level; its cash is rescaled to `level`'s bonus.
local function parkourReward(label: TextLabel, info: { [string]: any }, level: number)
	local list = if type(info.levels) == "table" then info.levels else {}
	local lv = list[level]
	local preview = info.rewardPreview
	if type(preview) ~= "table" or type(lv) ~= "table" then
		paintReward(label, "", false)
		return
	end
	local current = list[tonumber(info.level) or 1]
	local currentBonus = if type(current) == "table" then tonumber(current.bonus) or 1 else 1
	local bonus = tonumber(lv.bonus) or 1
	local cash = math.floor((tonumber(preview.packCash) or 0) / math.max(currentBonus, 0.01) * bonus + 0.5)
	-- A level's first clear always pays in full.
	local first = (tonumber(lv.clears) or 0) == 0
	local cooldownEnds = tonumber(info.cooldownEnds) or 0
	local full = first or cooldownEnds <= os.time()
	-- Inside the cooldown a clean finish pays the repeat share of this map's reward: nothing
	-- with gear chosen or worn, and for the map the server priced its own number (0 while
	-- that map's bonus rests).
	local share = tonumber(preview.repeatShare) or Economy.MODE_REPEAT_SHARE
	local repeatCash = math.floor(cash * share)
	local rest = 0
	if (type(info.gear) == "string" and info.gear ~= "none") or info.assisted == true then
		repeatCash = 0
	elseif type(lv.repeatRest) == "number" then
		-- The server says how long each map's bonus still rests (this map's two minutes, or
		-- the minute after any map's bonus).
		rest = previewRest(lv)
	elseif level == (tonumber(info.level) or 1) and preview.full == false then
		-- (An older server priced only info.level.) A bonus that rested when the snapshot
		-- was taken is awake once its seconds are up.
		rest = previewRest(preview)
		if (tonumber(preview.repeatRest) or 0) <= 0 then
			repeatCash = tonumber(preview.cash) or repeatCash
		end
	end
	setRewardLine(label, cash, full, cooldownEnds, bonus, repeatCash, rest)
end

type ModeRow = {
	panel: Frame,
	thumb: Frame,
	title: TextLabel,
	blurb: TextLabel,
	stats: TextLabel,
	reward: TextLabel,
	play: TextButton,
}

-- A mode card's thumbnail is this wide where the window has room; a narrow window keeps
-- the small medal by the title.
local THUMB_W, MEDAL_W = 104, 46
-- Under this window width the cards go narrow.
local MODES_WIDE = 520

-- One mode card: thumbnail, title, blurb, stats line, reward chip and the PLAY button.
-- props: Name, Height, LayoutOrder, Medal (the emoji on the thumbnail), Title, Blurb, Tint
-- (the card's colour), Sky (the thumbnail's top colour; it runs down into Tint).
local function modeRow(parent: Instance, props: { [string]: any }, onPlay: () -> ()): ModeRow
	local tint: Color3 = props.Tint
	local panel = Kit.panel(parent, {
		Name = props.Name,
		Glass = true,
		Color = tint,
		Size = UDim2.new(1, 0, 0, props.Height),
		LayoutOrder = props.LayoutOrder,
		Radius = Kit.RADIUS.M + 2,
	})
	-- Thumbnail: a bright tile in the mode's colours with its emoji; buildModes adds the scene.
	local thumb = Kit.new("Frame", {
		Name = "Thumb",
		BackgroundColor3 = Color3.new(1, 1, 1),
		Size = UDim2.fromOffset(THUMB_W, props.Height - 24),
		Position = UDim2.fromOffset(12, 12),
		ClipsDescendants = true,
		Parent = panel,
	})
	Kit.corner(thumb, 14)
	Kit.gradient(thumb, props.Sky or Kit.lighten(tint, 0.35), tint, 90)
	Kit.new("UIStroke", { Thickness = 2, Color = Kit.lighten(tint, 0.6), Transparency = 0.1, Parent = thumb })
	Kit.text(thumb, {
		Name = "Medal",
		Text = props.Medal,
		TextScaled = true,
		Size = UDim2.fromScale(0.62, 0.5),
		Position = UDim2.fromScale(0.5, 0.42),
		AnchorPoint = Vector2.new(0.5, 0.5),
		StrokeThickness = 0,
		ZIndex = 3,
	})
	local title = Kit.title(panel, {
		Text = props.Title,
		TextSize = T.H2,
		TextWrapped = false,
		TextXAlignment = Enum.TextXAlignment.Left,
		Size = UDim2.new(1, -140, 0, 26),
		Position = UDim2.fromOffset(128, 12),
		TextColor3 = C.Text,
	})
	local blurb = Kit.text(panel, {
		Text = props.Blurb,
		TextSize = T.Small,
		MinPx = true,
		TextWrapped = false,
		TextTruncate = Enum.TextTruncate.AtEnd,
		TextXAlignment = Enum.TextXAlignment.Left,
		Size = UDim2.new(1, -140, 0, 20),
		Position = UDim2.fromOffset(128, 38),
		TextColor3 = C.TextDim,
		StrokeThickness = 0,
	})
	local stats = Kit.text(panel, {
		Name = "Stats",
		Text = "",
		Font = F.UI,
		TextSize = T.Small,
		MinPx = true,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextWrapped = false,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Size = UDim2.new(1, -140, 0, 20),
		Position = UDim2.fromOffset(128, 62),
		TextColor3 = C.Text,
	})
	-- Reward chip: sized to its text, bottom-left of the text column (see paintReward).
	local reward = Kit.text(panel, {
		Name = "Reward",
		Text = "",
		Font = F.UI,
		TextSize = T.Body,
		MinPx = true,
		TextWrapped = false,
		BackgroundColor3 = C.Good,
		BackgroundTransparency = 0,
		Size = UDim2.fromOffset(0, 26),
		AutomaticSize = Enum.AutomaticSize.X,
		Position = UDim2.new(0, 128, 1, -10),
		AnchorPoint = Vector2.new(0, 1),
		TextColor3 = Kit.inkOn(C.Good),
		StrokeThickness = 0,
		Visible = false,
		ZIndex = 2,
	})
	Kit.padding(reward, 0, 10)
	Kit.round(reward)
	Kit.new("UIStroke", {
		Name = "Edge",
		Thickness = 1.5,
		Color = Kit.lip(C.Good),
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
		Parent = reward,
	})
	local play = Kit.button(panel, {
		Name = "Play",
		Text = "PLAY",
		Font = Theme.Fonts.Display,
		Color = C.Gold,
		Breathe = true,
		Size = UDim2.fromOffset(130, 50),
		Position = UDim2.new(1, -12, 1, -12),
		AnchorPoint = Vector2.new(1, 1),
	}, onPlay)
	return { panel = panel, thumb = thumb, title = title, blurb = blurb, stats = stats, reward = reward, play = play }
end

-- Sizes a mode card and its header for a wide or a narrow window: wide, the thumbnail fills
-- the card's left edge and everything sits beside it; narrow, it is a medal by the title.
-- Returns the x the card's text column starts at, and the x of the rows under the header.
local function placeMode(row: ModeRow, wide: boolean, height: number): (number, number)
	local x = (if wide then THUMB_W else MEDAL_W) + 24
	row.panel.Size = UDim2.new(1, 0, 0, height)
	row.thumb.Size = if wide then UDim2.fromOffset(THUMB_W, height - 24) else UDim2.fromOffset(MEDAL_W, MEDAL_W)
	row.thumb.Position = UDim2.fromOffset(12, if wide then 12 else 14)
	for _, child in row.thumb:GetChildren() do
		-- The scene behind the emoji only reads at thumbnail size.
		if child:IsA("GuiObject") and child:GetAttribute("Scene") then
			child.Visible = wide
		end
	end
	row.title.Position = UDim2.fromOffset(x, 12)
	row.title.Size = UDim2.new(1, -(x + 12), 0, 26)
	row.blurb.Position = UDim2.fromOffset(x, 38)
	row.blurb.Size = UDim2.new(1, -(x + 12), 0, 20)
	return x, if wide then x else 12
end

local maps: MapPicker.Picker? = nil

-- Opens the Maps window (MapPicker) with `level` selected (nil: the player's unlocked map).
-- Already open: just moves the selection.
function Windows.openMaps(level: number?)
	local picker = maps
	if not picker then
		return
	end
	if picker.window.isOpen() then
		if level then
			picker.select(level)
		end
		return
	end
	picker.preselect(level)
	Windows.open("Maps")
end

local function buildModes(screen: ScreenGui)
	local accent = Theme.World.Mint
	-- 168 (Parkour) + 10 + 150 (Mog) + 10 + 44 (coming soon) + 20 padding + 84 of header and
	-- margins. Short screens get a tighter stack (layoutRows) down to the 400 minimum, which
	-- a phone shows scaled up x1.25.
	local window = Kit.window(screen, "Modes", "Game Modes", "🏁", accent, Vector2.new(600, 486), Vector2.new(420, 400))
	register("Modes", window)
	local action = Net.event("Action")
	Kit.list(window.content, 10)

	local rows: { GuiObject } = {}
	local selected = 1

	-- Parkour ---------------------------------------------------------------------------
	local parkour = modeRow(window.content, {
		Name = "PARKOUR",
		Height = 168,
		LayoutOrder = 1,
		Medal = "🏃",
		Title = "PARKOUR",
		Blurb = "Ten sea maps: jump, bounce and slide!",
		Tint = Theme.World.Ocean,
		Sky = Theme.World.Sky,
	}, function()
		action:FireServer({ action = "ModeStart", mode = "parkour", level = selected })
		Windows.closeAll()
	end)
	table.insert(rows, parkour.panel)
	-- Its thumbnail: three stepping platforms climbing out of the sea to the finish flag.
	for i = 1, 3 do
		local step = Kit.new("Frame", {
			Name = "Step" .. i,
			BackgroundColor3 = Theme.World.Path,
			Size = UDim2.fromScale(0.3, 0.055),
			Position = UDim2.fromScale(0.05 + (i - 1) * 0.31, 0.9 - (i - 1) * 0.09),
			ZIndex = 2,
			Parent = parkour.thumb,
		})
		step:SetAttribute("Scene", true)
		Kit.round(step)
		Kit.new("UIStroke", { Thickness = 1.5, Color = Theme.World.Mint, Parent = step })
	end
	Kit.text(parkour.thumb, {
		Name = "Flag",
		Text = "🏁",
		TextScaled = true,
		Size = UDim2.fromScale(0.3, 0.16),
		Position = UDim2.fromScale(0.82, 0.62),
		AnchorPoint = Vector2.new(0.5, 0.5),
		StrokeThickness = 0,
		ZIndex = 2,
	}):SetAttribute("Scene", true)
	-- CHOOSE MAP sits above PLAY and opens the Maps window on the preselected map.
	Kit.button(parkour.panel, {
		Name = "ChooseMap",
		Text = "CHOOSE MAP",
		Font = Theme.Fonts.Display,
		TextSize = T.Small,
		Color = C.SurfaceHi,
		Size = UDim2.fromOffset(130, 38),
		Position = UDim2.new(1, -12, 1, -70),
		AnchorPoint = Vector2.new(1, 1),
	}, function()
		Windows.openMaps(selected)
	end)
	-- The preselected map's details sit in the text column above the reward chip.
	local levelName = Kit.title(parkour.panel, {
		Name = "LevelName",
		Text = "",
		TextSize = T.Body,
		MinPx = true,
		TextWrapped = false,
		TextTruncate = Enum.TextTruncate.AtEnd,
		TextXAlignment = Enum.TextXAlignment.Left,
		Size = UDim2.new(1, -164, 0, 22),
		Position = UDim2.fromOffset(12, 66),
		TextColor3 = C.Text,
	})
	local setPips = difficultyPips(parkour.panel, {
		Name = "Difficulty",
		Size = UDim2.new(1, -164, 0, 16),
		Position = UDim2.fromOffset(12, 90),
	})
	local pipRow = parkour.panel:FindFirstChild("Difficulty") :: Frame

	-- MOG TEST --------------------------------------------------------------------------
	-- Gamepad starts on the loud PLAY of the first mode.
	parkour.play:SetAttribute("FocusFirst", true)
	local mog = modeRow(window.content, {
		Name = "MOGTEST",
		Height = 150,
		LayoutOrder = 2,
		Medal = "💪",
		Title = "MOG TEST",
		Blurb = "Out-mog 3 rivals, or duel a real player 1v1!",
		Tint = Theme.World.Grape,
		Sky = Theme.World.Pink,
	}, function()
		local pick = Windows.onMogPlay
		if pick then
			pick()
		else
			action:FireServer({ action = "ModeStart", mode = "mog", vs = "rivals" })
		end
		Windows.closeAll()
	end)
	table.insert(rows, mog.panel)
	-- Its thumbnail: the player's best unit, the one that walks into the test (the emoji
	-- stays as a badge in the corner). Rebuilt when a better one is discovered.
	local mogStar: ViewportFrame? = nil
	local mogTier = 0
	local function showMogStar()
		local data = State.data
		local best = 0
		if data and type(data.discovered) == "table" then
			for tier = 1, Economy.MAX_TIER do
				if (tonumber(data.discovered[tier]) or 0) > 0 then
					best = tier
				end
			end
		end
		if best == mogTier or best < 1 then
			return
		end
		mogTier = best
		if mogStar then
			mogStar:Destroy()
		end
		local viewport = Kit.unitViewport(mog.thumb, best, { Size = UDim2.fromScale(1, 1) })
		viewport.Name = "Star"
		viewport.ZIndex = 2
		viewport:SetAttribute("Scene", true)
		viewport.Visible = window.size().X >= MODES_WIDE
		mogStar = viewport
	end

	-- Every other mode: one slim, quiet row.
	local soon = Kit.panel(window.content, {
		Name = "ComingSoon",
		Glass = true,
		Size = UDim2.new(1, 0, 0, 44),
		LayoutOrder = 3,
		Radius = Kit.RADIUS.M,
		Transparency = Theme.Glass.Dimmed,
	})
	table.insert(rows, soon)
	Kit.icon(soon, "Lock", 18, C.TextMute, {
		Position = UDim2.new(0, 16, 0.5, 0),
		AnchorPoint = Vector2.new(0, 0.5),
		ZIndex = 2,
	})
	Kit.text(soon, {
		Text = "More modes coming soon",
		Font = F.UI,
		TextSize = T.Small,
		TextWrapped = false,
		TextXAlignment = Enum.TextXAlignment.Left,
		Size = UDim2.new(1, -60, 1, 0),
		Position = UDim2.fromOffset(44, 0),
		TextColor3 = C.TextMute,
		ZIndex = 2,
	})

	-- Wide windows: each card's thumbnail fills its left edge and the text sits beside it.
	-- Narrow ones: the medal by the title, the map's details under it. Short windows: the
	-- Mog card is 118 px (narrow too: its stats fold under the medal) and the "coming
	-- soon" row goes while there is no room for it: 168 + 10 + 118 fills the 400 minimum.
	local function layoutRows(size: Vector2)
		local short = size.Y < 486
		local wide = size.X >= MODES_WIDE
		local _, px = placeMode(parkour, wide, 168)
		local top = if wide then 62 else 66
		levelName.Position = UDim2.fromOffset(px, top)
		levelName.Size = UDim2.new(1, -(px + 152), 0, 22)
		pipRow.Position = UDim2.fromOffset(px, top + 24)
		pipRow.Size = UDim2.new(1, -(px + 152), 0, 16)
		parkour.stats.Position = UDim2.fromOffset(px, top + 44)
		parkour.stats.Size = UDim2.new(1, -(px + 152), 0, 20)
		parkour.reward.Position = UDim2.new(0, px, 1, -10)

		local mx, under = placeMode(mog, wide, if short then 118 else 150)
		-- A short card: the stats stop at PLAY. A tall one: they run over it, full width.
		local sx = if short then under else mx
		mog.stats.Position = UDim2.fromOffset(sx, if wide then 62 elseif short then 64 else 60)
		mog.stats.Size = UDim2.new(1, -(sx + (if short then 152 else 12)), 0, 20)
		mog.reward.Position = UDim2.new(0, under, 1, -10)
		-- The medal is a corner badge only on the thumbnail; alone on the small tile it is centred.
		local medal = mog.thumb:FindFirstChild("Medal")
		if medal and medal:IsA("TextLabel") then
			local badge = wide and mogStar ~= nil
			medal.Size = if badge then UDim2.fromScale(0.34, 0.26) else UDim2.fromScale(0.62, 0.5)
			medal.Position = if badge then UDim2.fromScale(0.8, 0.84) else UDim2.fromScale(0.5, 0.42)
		end
		soon.Visible = not short or size.Y >= 454
	end
	layoutRows(window.size())
	window.onResize.Event:Connect(layoutRows)

	local function refreshParkour()
		local data = State.data
		local info = data and data.modes and data.modes.parkour
		local list = if type(info) == "table" and type(info.levels) == "table" then info.levels else {}
		local count = math.max(#list, 1)
		local unlocked = math.clamp(if type(info) == "table" then tonumber(info.unlocked) or 1 else 1, 1, count)
		selected = math.clamp(selected, 1, unlocked)
		local lv = list[selected]
		if type(info) ~= "table" or type(lv) ~= "table" then
			levelName.Text = "MAP 1"
			setPips(1)
			parkour.stats.Text = "Best --  ·  0 clears"
			paintReward(parkour.reward, "", false)
			return
		end
		local icon = if type(lv.icon) == "string" and lv.icon ~= "" then lv.icon .. " " else ""
		levelName.Text = string.format("MAP %d  ·  %s%s", selected, icon, tostring(lv.name or ""))
		setPips(tonumber(lv.difficulty) or selected)
		local best = tonumber(lv.best) or 0
		local clears = tonumber(lv.clears) or 0
		parkour.stats.Text = string.format("Best %s  ·  %s", if best > 0 then runTime(best) else "--", plural(clears, "clear"))
		parkourReward(parkour.reward, info, selected)
		local runningHere = info.running and tonumber(info.level) == selected
		Kit.setButton(parkour.play, if runningHere then "RESTART" else "PLAY")
	end

	local function refreshMog()
		local data = State.data
		local info = data and data.modes and data.modes.mog
		if type(info) ~= "table" then
			mog.stats.Text = "Best score --  ·  0 rivals  ·  0 passes"
			paintReward(mog.reward, "", false)
			return
		end
		local best = tonumber(info.best) or 0
		mog.stats.Text = string.format(
			"Best score %s  ·  %s  ·  %s",
			if best > 0 then tostring(best) else "--",
			plural(tonumber(info.rivals) or 0, "rival"),
			plural(tonumber(info.clears) or 0, "pass", "passes")
		)
		local preview = info.rewardPreview
		if type(preview) ~= "table" then
			paintReward(mog.reward, "", false)
		else
			-- Inside the cooldown a pass pays the run again bonus, unless it rests.
			setRewardLine(
				mog.reward,
				tonumber(preview.packCash) or tonumber(preview.cash) or 0,
				preview.full ~= false,
				tonumber(info.cooldownEnds) or 0,
				nil,
				if preview.full == false then tonumber(preview.repeatCash) or tonumber(preview.cash) else nil,
				if preview.full == false then previewRest(preview) else 0
			)
		end
		Kit.setButton(mog.play, if info.running then "PLAYING" else "PLAY")
		Kit.setEnabled(mog.play, not info.running)
	end

	local function refresh()
		refreshParkour()
		refreshMog()
		local had = mogStar
		showMogStar()
		if mogStar ~= had then
			layoutRows(window.size())
		end
	end
	-- Re-centre the selection on the level to play (the lowest unlocked, uncleared one).
	local function resync()
		local info = State.data and State.data.modes and State.data.modes.parkour
		selected = if type(info) == "table" then tonumber(info.unlocked) or 1 else 1
		refresh()
	end
	State.changed.Event:Connect(refresh)
	window.onOpen.Event:Connect(function()
		resync()
		-- The cooldown lines count down while the window is open.
		task.spawn(function()
			while window.isOpen() do
				task.wait(1)
				refresh()
			end
		end)
	end)

	beforeOpen.Modes = function()
		resync()
		ripple(rows)
	end
	resync()
end

function Windows.build(screen: ScreenGui)
	backdrop = Kit.backdrop(screen, 9, function()
		Windows.closeAll()
	end)
	buildShop(screen)
	buildIndex(screen)
	buildRanking(screen)
	buildSettings(screen)
	buildModes(screen)
	local picker = MapPicker.build(screen, {
		register = register,
		closeAll = Windows.closeAll,
		parkourReward = parkourReward,
		pips = difficultyPips,
		runTime = runTime,
		plural = plural,
		ripple = ripple,
	})
	maps = picker
	beforeOpen.Maps = picker.beforeOpen
	-- Daily Reward (DailyWindow.luau): opens from the HUD and by itself once per session.
	local daily = DailyWindow.build(screen, {
		register = register,
		ripple = ripple,
		open = function()
			Windows.open("Daily")
		end,
		close = Windows.closeAll,
	})
	beforeOpen.Daily = daily.beforeOpen

	-- B / Escape closes the open window. gameProcessedEvent is not checked: ButtonB
	-- comes in processed while a button is selected, and that is when it matters.
	-- A modal on top (Popups sets ModalOpen) handles the press itself.
	UserInputService.InputBegan:Connect(function(input)
		if input.KeyCode == Enum.KeyCode.Escape or input.KeyCode == Enum.KeyCode.ButtonB then
			if screen:GetAttribute("ModalOpen") == true then
				return
			end
			if anyOpen() then
				Kit.sound("Close")
				Windows.closeAll()
			end
		end
	end)
end

return Windows
