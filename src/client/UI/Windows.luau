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

local Economy = require(ReplicatedStorage.Shared.Economy)
local Format = require(ReplicatedStorage.Shared.Format)
local Net = require(ReplicatedStorage.Shared.Net)

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

--[[
	Tinted tag on a glass card (a rarity, a state): Kit.pill's soft fill of `Color` with
	the label in the dark outline of text on glass (a pill's stroke is its border, so its
	text has none). Sizes to its text. props: Name, Text, Color, Position, AnchorPoint, ZIndex.
]]
local function tag(parent: Instance, props: { [string]: any }): TextLabel
	local color: Color3 = props.Color
	local label = Kit.text(parent, {
		Name = props.Name or "Tag",
		Text = props.Text,
		Font = F.UI,
		TextSize = T.Small,
		TextColor3 = Kit.lighten(color, 0.55),
		TextWrapped = false,
		BackgroundColor3 = color,
		BackgroundTransparency = 0.7,
		Size = UDim2.fromOffset(0, 24),
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
	One long page under a pill switcher, top to bottom: the Starter Pack hero
	card (until owned), a full-width animated banner per game pass, the
	cosmetics (All Cosmetics bundle + a card grid), then cash and aura pack
	cards. Every banner and pack card has a ShopScenes stage that plays
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

-- Ribbon candy colours, one per kind of tag (OWNED keeps the mint "good" green).
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
		caption = "Lands straight in your tank",
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
	Starter card, the GAME PASSES header and the first pass banner fit the
	visible page; on the 620x400 minimum everything keeps one row per banner and
	the page (244 px under the pinned title and switcher) still shows the tallest
	card, a pack, whole. A phone gets that short window scaled up x1.25.
]]
local BANNER_H = 130 -- pass banner height
local STAGE_W = 230 -- a banner's animated stage, at the default window...
local STAGE_MIN_W = 140 -- ...and the narrowest it shrinks to
local COS_H = 204 -- cosmetic card height
local PACK_H = 238 -- cash / aura card height (stage, amount, one-line caption, price)
local PACK_STAGE = 125 -- pack card stage (square)
local PACK_ICON = 26 -- currency icon left of a pack's amount
local STARTER_H = 120 -- Starter pack card at the top of the page
local BUNDLE_H = 120 -- All Cosmetics card heading the cosmetics section
local GAP = 16
local HEAD_H = 54 -- section header height (icon row + glowing underline)
local SWITCH_H = 44 -- section switcher bar (36 px pills inside)
local PAGE_TOP = SWITCH_H + 8 -- the scrolling page starts below the switcher
local PRICE_H = 42 -- every price button
local PRICE_TEXT = 20
local FADE_H = 30 -- soft fade along the bottom edge of the page
local MIN_TEXT = 14 -- no shop text renders smaller (TextScaled labels included)
local CART = 52 -- header cart art (inside the pane)
local WALLET_CASH = 140 -- header wallet pill: the cash half...
local WALLET_AURA = 112 -- ...and the tank half
local INSET = 0.4 -- darker panes inside a glass card (descriptions, contents chips)

-- TextScaled labels in the shop never shrink below MIN_TEXT.
local function minText(label: TextLabel): TextLabel
	local constraint = label:FindFirstChildOfClass("UITextSizeConstraint")
	if constraint then
		constraint.MinTextSize = math.min(MIN_TEXT, constraint.MaxTextSize)
	end
	return label
end

-- Small text on a candy tint: white glyphs in a 1.5 px outline of the tint's deep tone.
local function outline(label: TextLabel, tint: Color3): UIStroke
	return Kit.new("UIStroke", {
		Thickness = 1.5,
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
local function bannerPaint(body: Frame, tint: Color3, radius: number, strokeColor: Color3?): Frame
	local gradient = body:FindFirstChildOfClass("UIGradient")
	if gradient then
		gradient.Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, Kit.lighten(tint, 0.24)),
			ColorSequenceKeypoint.new(0.5, tint),
			ColorSequenceKeypoint.new(1, Kit.darken(tint, 0.16)),
		})
		gradient.Transparency = NumberSequence.new(0, 0.3)
		gradient.Rotation = 24
	end
	local stroke = body:FindFirstChildOfClass("UIStroke")
	if stroke then
		stroke.Thickness = 2
		stroke.Color = strokeColor or Kit.lighten(tint, 0.55)
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
	return Economy.moneyPackAmount(data.income or 0, starter.CashSeconds, starter.CashMin, progression)
end

-- The cosmetics part of a snapshot, empty when the server sent none.
local NO_COSMETICS = { owned = {}, trail = "", toggles = {}, bundleOwned = false, starterOwned = false }
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

-- Faint sparkles drifting behind the page: scale position on the page and size in pixels.
local DRIFT_SPOTS = {
	{ 0.06, 0.2, 8 },
	{ 0.3, 0.55, 6 },
	{ 0.52, 0.12, 10 },
	{ 0.74, 0.7, 7 },
	{ 0.93, 0.32, 9 },
	{ 0.18, 0.86, 7 },
	{ 0.62, 0.42, 6 },
	{ 0.86, 0.9, 8 },
}

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
	-- Repeating idle tweens (header divider, sparkles, glows): played on open; on close they
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

	-- Faint sparkles drift behind the page (under the scroll, so cards always cover them).
	local sparkles = Kit.new("Frame", {
		Name = "Sparkles",
		BackgroundTransparency = 1,
		ClipsDescendants = true,
		Size = UDim2.new(1, 0, 1, -PAGE_TOP),
		Position = UDim2.fromOffset(0, PAGE_TOP),
		ZIndex = 1,
		Parent = content,
	})
	for i, spot in DRIFT_SPOTS do
		local sparkle = Kit.new("Frame", {
			Name = "Sparkle" .. i,
			BackgroundColor3 = if i % 3 == 0 then C.GoldLight else Color3.new(1, 1, 1),
			BackgroundTransparency = 0.8,
			BorderSizePixel = 0,
			Size = UDim2.fromOffset(spot[3], spot[3]),
			Position = UDim2.fromScale(spot[1], spot[2]),
			AnchorPoint = Vector2.new(0.5, 0.5),
			Rotation = 45,
			ZIndex = 1,
			Parent = sparkles,
		})
		Kit.corner(sparkle, 2)
		idleTween(sparkle, 3 + (i % 3) * 0.8, {
			Position = UDim2.new(spot[1], 0, spot[2], -28),
			Rotation = 135,
			BackgroundTransparency = 0.5,
		}, (i % 4) * 0.5)
	end

	local scroll = Kit.scrolling(content, {
		Name = "Scroll",
		Size = UDim2.new(1, 0, 1, -PAGE_TOP),
		Position = UDim2.fromOffset(0, PAGE_TOP),
	})
	scroll.ZIndex = 2
	scroll.AutomaticCanvasSize = Enum.AutomaticSize.None
	-- Gamepad selection moves between the cards; the engine scrolls the page to them.
	scroll.Selectable = false

	-- Soft shade along the bottom edge of the page (stacked strips of the glass tint, so it
	-- also renders without gradient transparency); it fades out at the end of the page.
	local fade = Kit.new("Frame", {
		Name = "Fade",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, -8, 0, FADE_H),
		Position = UDim2.new(0, 0, 1, 0),
		AnchorPoint = Vector2.new(0, 1),
		ZIndex = 9,
		Parent = content,
	})
	local FADE_STEPS = 6
	local fadeStrips: { [Frame]: number } = {}
	for i = 1, FADE_STEPS do
		local strip = Kit.new("Frame", {
			Name = "Strip" .. i,
			BackgroundColor3 = Theme.Glass.Tint,
			BackgroundTransparency = 1 - (i / FADE_STEPS) ^ 1.6 * 0.5,
			BorderSizePixel = 0,
			Size = UDim2.new(1, 0, 1 / FADE_STEPS, 0),
			Position = UDim2.fromScale(0, (i - 1) / FADE_STEPS),
			ZIndex = 9,
			Parent = fade,
		})
		fadeStrips[strip] = strip.BackgroundTransparency
	end
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
	local function scrollToSection(index: number, instant: boolean?)
		setCurrent(index, not instant)
		scrollTo(sectionY[index] or 0, instant)
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

	-- Purchases: the last product prompted, so landed cash or aura flies from its card.
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
	local function wideText(body: Frame, tint: Color3, title: string, caption: string?): TextLabel
		local titleLabel = minText(Kit.title(body, {
			Name = "Title",
			Text = title,
			TextSize = 28,
			MaxTextSize = 28,
			TextScaled = true,
			TextWrapped = false,
			Size = UDim2.new(1, WIDE_TEXT_W, 0, 32),
			Position = UDim2.fromOffset(WIDE_LEFT, 10),
			TextXAlignment = Enum.TextXAlignment.Left,
			TextColor3 = Color3.new(1, 1, 1),
			StrokeThickness = 0,
			ZIndex = 4,
		}))
		Kit.new("UIStroke", { Thickness = 3, Color = Kit.lip(tint), Parent = titleLabel })
		if caption then
			local captionLabel = Kit.text(body, {
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
			outline(captionLabel, tint)
		end
		return titleLabel
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

	-- Starter pack: a wide mint hero card at the very top while the player does not own it --
	local starterPass = Theme.Monetization.Passes[COS.Starter.Pass]
	local starterTint = Theme.World.Mint
	local starterCell, starterBody, starterArtHolder, starterArt =
		makeEntry(scroll, "Starter", 0, starterTint, COS.Starter.Icon, "Star", 104, UDim2.new(0, 68, 0.5, 0))
	local starterClip = bannerPaint(starterBody, starterTint, WIDE_R)
	wideText(starterBody, starterTint, "STARTER PACK")
	-- What is inside: two chips, this player's own cash amount and the exclusive trail.
	local chips = Kit.new("Frame", {
		Name = "Contents",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, WIDE_TEXT_W, 0, 56),
		Position = UDim2.fromOffset(WIDE_LEFT, 50),
		ZIndex = 4,
		Parent = starterBody,
	})
	Kit.list(chips, 8, true)
	local function contentChip(order: number, icon: string, fallback: string, color: Color3, caption: string): TextLabel
		local chip = Kit.new("Frame", {
			Name = "Chip" .. order,
			BackgroundColor3 = Kit.darken(starterTint, 0.34),
			BackgroundTransparency = INSET,
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
			Position = UDim2.fromOffset(44, 6),
			TextXAlignment = Enum.TextXAlignment.Left,
			TextColor3 = Color3.new(1, 1, 1),
			ZIndex = 4,
		}))
		Kit.text(chip, {
			Name = "Caption",
			Text = caption,
			Font = F.Bold,
			TextSize = 14,
			TextWrapped = false,
			TextTruncate = Enum.TextTruncate.AtEnd,
			Size = UDim2.new(1, -50, 0, 18),
			Position = UDim2.fromOffset(44, 31),
			TextXAlignment = Enum.TextXAlignment.Left,
			TextColor3 = C.Text,
			ZIndex = 4,
		})
		return amount
	end
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
		animated stage (ShopScenes.pass); middle: chunky outlined title, a
		description and a PERMANENT pill; right: the price button. On a narrow
		window the stage gives up width first so the text column keeps its size.
	]]
	sectionHead(1)
	local passList = Kit.new("Frame", { Name = "Passes", BackgroundTransparency = 1, Parent = scroll })
	Kit.list(passList, GAP)
	type Banner = Entry & {
		tag: TextLabel?,
		owned: TextLabel,
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
		local body = Kit.panel(cell, { Name = "Body", Glass = true, Color = tint, Size = UDim2.fromScale(1, 1), Radius = BANNER_R })
		local clip = bannerPaint(body, tint, BANNER_R)
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
			Size = UDim2.new(1, 0, 0, 34),
			Position = UDim2.fromOffset(0, 12),
			TextXAlignment = Enum.TextXAlignment.Left,
			TextColor3 = Color3.new(1, 1, 1),
			StrokeThickness = 0,
			ZIndex = 6,
		}))
		Kit.new("UIStroke", {
			Thickness = 3,
			Color = Kit.lip(tint),
			LineJoinMode = Enum.LineJoinMode.Round,
			Parent = title,
		})
		local desc = Kit.text(info, {
			Name = "Desc",
			Text = pass.Desc,
			Font = F.Bold,
			TextSize = 16,
			TextWrapped = true,
			Size = UDim2.new(1, 0, 0, 40),
			Position = UDim2.fromOffset(1, 49),
			TextXAlignment = Enum.TextXAlignment.Left,
			TextYAlignment = Enum.TextYAlignment.Top,
			TextColor3 = Color3.new(1, 1, 1),
			ZIndex = 6,
		})
		outline(desc, tint)
		-- PERMANENT: white on the tint's deep navy-leaning tone, so it reads on every banner.
		Kit.pill(info, {
			Name = "Perk",
			Text = "PERMANENT",
			Color = Kit.darken(Kit.lip(tint), 0.25),
			Solid = true,
			TextColor = Color3.new(1, 1, 1),
			TextSize = 15,
			Size = UDim2.fromOffset(0, 26),
			AutomaticSize = Enum.AutomaticSize.X,
			Position = UDim2.new(0, 0, 1, -12),
			AnchorPoint = Vector2.new(0, 1),
			ZIndex = 6,
		})
		local button, sheen = priceButton(body, {
			Text = price(pass.Price),
			Size = UDim2.fromOffset(150, PRICE_H),
			Position = UDim2.new(1, -16, 0.5, 0),
			AnchorPoint = Vector2.new(1, 0.5),
		}, function()
			action:FireServer({ action = "PromptPass", name = name })
		end)
		local tagInfo = PASS_TAGS[name]
		local owned = ribbon(body, "OWNED", C.Good)
		owned.Visible = false
		local banner: Banner = {
			cell = cell,
			body = body,
			art = nil,
			artHolder = stage,
			button = button,
			sheen = sheen,
			clip = clip,
			tag = if tagInfo then ribbon(body, tagInfo.text, tagInfo.color) else nil,
			owned = owned,
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
		local left = 9 + stageW + 28
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
	local bundleClip = bannerPaint(bundleBody, bundleTint, WIDE_R)
	wideText(bundleBody, bundleTint, string.upper(bundlePass.Title), "Everything below, forever")
	local included = 0
	for _, name in COS_ORDER do
		if not COS.Items[name].Starter then
			included += 1
		end
	end
	local includes = Kit.new("Frame", {
		Name = "Includes",
		BackgroundColor3 = Kit.darken(bundleTint, 0.34),
		BackgroundTransparency = INSET,
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
	local bundleOwnedTag = ribbon(bundleBody, "OWNED", C.Good)
	bundleOwnedTag.Visible = false
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
				if not cos.owned[name] then
					return
				end
				local value = not shownChoice(name, cos.toggles[name] ~= false)
				pendingCos[name] = { value = value, at = os.clock() }
				action:FireServer({ action = "ToggleCosmetic", name = name, value = value })
				refresh()
			end)
			-- The switch's ON / OFF word at the shop's 14 px floor.
			local state = toggle:FindFirstChild("State")
			if state and state:IsA("TextLabel") then
				state.TextSize = MIN_TEXT
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
	type Pack = Entry & { amount: TextLabel, sub: TextLabel, scene: Scene }
	type PackGrid = {
		grid: Frame,
		layout: UIGridLayout,
		count: number,
		wide: number,
		narrow: number,
		columns: number,
		cardW: number,
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
		local packs: PackGrid =
			{ grid = grid, layout = gridLayout, count = packCount, wide = wide, narrow = narrow, columns = wide, cardW = 180 }
		table.insert(packGrids, packs)
		return packs
	end
	--[[
		Amounts are the hero of a pack card: the currency icon and a big bold number
		in the pack colour with a dark outline. The number's size follows its length
		and the card width (28 px, never under 24 px for the short number format).
	]]
	local amountGrid: { [TextLabel]: PackGrid } = {}
	local function fitAmount(label: TextLabel, text: string)
		local packs = amountGrid[label]
		local room = (if packs then packs.cardW else 180) - 20 - PACK_ICON - 4
		label.TextSize = math.clamp(math.floor(room / (0.68 * math.max(#text, 1))), 16, 28)
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
		if glowId then
			local glow = Kit.new("ImageLabel", glowProps)
			glow.Image = glowId
			glow.ImageColor3 = Kit.lighten(accent, 0.2)
			glow.ImageTransparency = math.max(0.1, 0.5 - 0.1 * index)
			glow.ScaleType = Enum.ScaleType.Fit
		else
			local glow = Kit.new("Frame", glowProps)
			glow.BackgroundColor3 = accent
			glow.BackgroundTransparency = math.max(0.45, 0.8 - 0.08 * index)
			Kit.round(glow)
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
			TextSize = 15,
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
		}
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
		local card = packCard(auraPackGrid, "Aura", index, pack.Price, C.Violet, Kit.lighten(C.Orb, 0.55), "Orb")
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
		for _, packs in packGrids do
			packs.columns = if wide then packs.wide else packs.narrow
			packs.layout.CellSize = cellSize(packs.columns, PACK_H)
			packs.cardW = (size.X - 62 - 18 - GAP * (packs.columns - 1)) / packs.columns
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
		starterCell.Visible = starterShown
		local blocks: { { gui: GuiObject, h: number, gapAfter: number, section: number? } } = {
			{ gui = starterCell, h = if starterShown then STARTER_H else 0, gapAfter = if starterShown then 18 else 0 },
			{ gui = heads[1], h = HEAD_H, gapAfter = 14, section = 1 },
			{ gui = passList, h = gridH(#bannerList, 1, BANNER_H), gapAfter = 26 },
			{ gui = heads[2], h = HEAD_H, gapAfter = 14, section = 2 },
			{ gui = bundleCell, h = BUNDLE_H, gapAfter = GAP + 6 },
			{ gui = cosGrid, h = gridH(#COS_ORDER, columns, COS_H), gapAfter = 26 },
		}
		local packSections = { { 3, cashGrid }, { 4, auraGrid } }
		for i, entry in packSections do
			local packs = packGrids[i]
			table.insert(blocks, { gui = heads[entry[1]], h = HEAD_H, gapAfter = 14, section = entry[1] })
			table.insert(blocks, {
				gui = entry[2],
				h = gridH(packs.count, packs.columns, PACK_H),
				gapAfter = 26,
			})
		end
		-- The Starter card's ribbon overlaps its top edge: start a little lower for it.
		local y = if starterShown then 12 else 4
		for _, block in blocks do
			block.gui.Position = UDim2.fromOffset(4, y - previewShift)
			block.gui.Size = UDim2.new(1, -18, 0, block.h)
			if block.section then
				headY[block.section] = y
				sectionY[block.section] = y - 4
			end
			if block.gui:IsA("Frame") then
				gridTop[block.gui] = y
			end
			y += block.h + block.gapAfter
		end
		-- The Passes pill opens the page at the very top, Starter card included.
		passesY = sectionY[1]
		sectionY[1] = 0
		-- The last section is short: room below it lets its header scroll all the way to the top.
		canvasH = math.max(y, sectionY[count] + pageH())
		pageEnd.Position = UDim2.fromOffset(0, canvasH - previewShift)
		scroll.CanvasSize = UDim2.fromOffset(0, canvasH)
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
		Section in view: the last section whose header sits in the top part of the
		visible page (at or above 40% of its height), measured from where the
		headers really are on screen (so window and screen scaling cannot skew
		it). Moving to another section needs its header 18 px past that line, so
		the indicator does not flicker at a boundary. At the very bottom of the
		page the last section wins. Also fades the bottom-edge hint out there.
	]]
	local HYSTERESIS = 18
	local function sectionInView(): number
		local page = pageH()
		local offsets: { number } = {}
		local endOffset: number
		local scale = if PREVIEW then 0 else scroll.AbsoluteSize.Y / math.max(1, page)
		if scale > 0.05 then
			local top = scroll.AbsolutePosition.Y
			for i, head in heads do
				offsets[i] = (head.AbsolutePosition.Y - top) / scale
			end
			endOffset = (pageEnd.AbsolutePosition.Y - top) / scale
		else
			local top = if PREVIEW then previewShift else scroll.CanvasPosition.Y
			for i in heads do
				offsets[i] = (headY[i] or 0) - top
			end
			endOffset = canvasH - top
		end
		local atBottom = endOffset <= page + 2
		showFade(not atBottom)
		if atBottom then
			return count
		end
		local line = page * 0.4
		local function lastAbove(y: number): number
			local index = 1
			for i, offset in offsets do
				if offset <= y then
					index = i
				end
			end
			return index
		end
		local ahead = lastAbove(line - HYSTERESIS)
		local back = lastAbove(line + HYSTERESIS)
		if ahead > current then
			return ahead
		elseif back < current then
			return back
		end
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
			Kit.appear(bundleOwnedTag, { from = 0.4, time = 0.3 })
			Kit.sound("Reward")
		else
			bundleOwnedTag.Visible = bundleOwned
		end
		bundleWasOwned = bundleOwned

		local trail = shownChoice("trail", cos.trail or "")
		local wave = 0
		for _, name in COS_ORDER do
			local card = cosCards[name]
			local item = COS.Items[name]
			local owned = cos.owned[name] == true
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
			elseif owned and control and card.setSwitch then
				local on = shownChoice(name, cos.toggles[name] ~= false) == true
				if card.switchShown ~= on then
					card.switchShown = on
					card.setSwitch(on)
				end
			elseif item.Pass then
				local pass = Theme.Monetization.Passes[item.Pass]
				Kit.setEnabled(card.button, true)
				Kit.setButton(card.button, price(pass.Price), C.Cash)
			else
				Kit.setEnabled(card.button, true)
				Kit.setButton(card.button, "STARTER PACK", C.SurfaceHi)
			end
			card.button.Visible = not (owned and control ~= nil)
			if control then
				control.Visible = owned
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
		-- The wallet rolls; a landed purchase flies in from the card that was bought.
		local money, carried = data.money, data.carried or 0
		if chipMoney and money ~= chipMoney and open then
			Kit.countTo(cashChip, chipMoney, money, State.money)
			if money > chipMoney and lastPrompt and lastPrompt.kind == "Money" and os.clock() - lastPrompt.at < 120 then
				flyTo(lastPrompt.entry.button, cashChip, "Coin", C.Gold)
				lastPrompt = nil
			end
		elseif money ~= chipMoney then
			cashChip.Text = State.money(money)
		end
		-- The tank also fills from collecting, so only a jump of about a pack's size counts as the purchase.
		if chipAura and carried ~= chipAura and open then
			Kit.countTo(auraChip, chipAura, carried, State.num)
			local prompt = lastPrompt
			if
				prompt
				and prompt.kind == "Aura"
				and os.clock() - prompt.at < 120
				and carried - chipAura >= (auraShown[prompt.index] or 0) * 0.5
			then
				flyTo(prompt.entry.button, auraChip, "Orb", C.Orb)
				lastPrompt = nil
			end
		elseif carried ~= chipAura then
			auraChip.Text = State.num(carried)
		end
		chipMoney, chipAura = money, carried

		-- Each player sees their own pack sizes (the server grants with the same functions).
		local progression = Economy.progression(data.highestTier or 1, data.processLevel or 0)
		for index, pack in moneyPacks do
			local amount = Economy.moneyPackAmount(data.income, pack.Seconds, pack.Min, progression)
			local shown = moneyShown[index]
			moneyShown[index] = amount
			if shown and shown ~= amount and open then
				fitAmount(moneyLabels[index], State.num(amount))
				Kit.countTo(moneyLabels[index], shown, amount, State.num)
			elseif shown ~= amount then
				setAmount(moneyLabels[index], State.num(amount))
			end
		end
		for index, pack in auraPacks do
			local amount = Economy.auraPackAmount(data.production or 0, pack.Seconds, pack.Min, progression)
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
				-- Just bought: the banner celebrates, its scene throws a party and the OWNED ribbon lands.
				Kit.pop(banner.cell, 1.2)
				banner.scene.celebrate()
				local spot = centreOf(banner.cell)
				Kit.confetti(frame, { Origin = UDim2.fromOffset(spot.X, spot.Y), Count = 24, ZIndex = 45 })
				Kit.appear(banner.owned, { from = 0.4, time = 0.3 })
				Kit.sound("Reward")
			else
				banner.owned.Visible = owned
			end
			banner.wasOwned = owned
		end
		refreshCosmetics(data, open)
	end
	State.changed.Event:Connect(refresh)

	-- Idle motion while open: every scene plays, static art bobs out of phase, ribbons
	-- breathe, banners catch a slow sheen, the header drifts through candy colours,
	-- sparkles float behind the page, and one price button at a time gets a sheen.
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
				table.insert(idleStops, Kit.shimmer(entry.clip, 5 + (i % 4) * 0.8, 3))
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
		local focus = Windows.shopFocus or screen:GetAttribute("ShopFocus")
		Windows.shopFocus = nil
		screen:SetAttribute("ShopFocus", nil)
		-- Where the page opens: the focused banner, card or section, otherwise the top.
		local index = 1
		local y = 0
		local focusCell: GuiObject? = nil
		if type(focus) == "string" then
			for i, section in SECTIONS do
				if section.key == focus then
					index = i
					y = sectionY[i] or 0
				end
			end
			local passOrder = table.find(Theme.Monetization.PassOrder, focus)
			local cosOrder = table.find(COS_ORDER, focus)
			if passOrder and banners[focus] then
				y = cardY(passList, passOrder, passesY, BANNER_H, 1)
				focusCell = banners[focus].cell
			elseif focus == COS.Starter.Pass and starterShown then
				focusCell = starterCell
			elseif focus == COS.Bundle then
				index, y = 2, sectionY[2]
				focusCell = bundleCell
			elseif cosOrder then
				-- The first cosmetics row sits under the All Cosmetics card.
				index, y = 2, cardY(cosGrid, cosOrder, sectionY[2], COS_H, columnsNow)
				focusCell = cosCards[focus].cell
			end
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
			if not PREVIEW then
				local target = head.Position
				head.Position = target + UDim2.fromOffset(-24, 0)
				Kit.tween(head, 0.32, { Position = target }, Enum.EasingStyle.Back)
				Kit.appear(head, { from = 1, time = 0.2, delay = (i - 1) * 0.05 })
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
local CARD_H = 212

local function buildIndex(screen: ScreenGui)
	-- Minimum 386 tall: a phone gets that window at x1.3, one row of cards and the top of the next.
	local window = Kit.window(screen, "Index", "Index", I.Index, C.Window.Index, Vector2.new(880, 560), Vector2.new(560, 386))
	register("Index", window)

	-- Discovered count: a compact bar in the header row, left of the close button.
	local _, setProgress, progressLabel = Kit.progress(window.header, {
		Name = "Found",
		Glass = true,
		Color = C.Window.Index,
		Size = UDim2.fromOffset(210, 28),
		Position = UDim2.new(1, -62, 0.5, -1),
		AnchorPoint = Vector2.new(1, 0.5),
		TextSize = T.Small,
		MinFill = 0.08,
	})
	local function foundText(n: number): string
		return string.format("%d / %d FOUND", n, Economy.MAX_TIER)
	end

	-- Rarity legend: one slim row of tags above the grid.
	local legend = Kit.new("Frame", {
		Name = "Legend",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, -14, 0, 26),
		Parent = window.content,
	})
	Kit.list(legend, 6, true, Enum.HorizontalAlignment.Left)
	for order, band in Economy.TIER_BANDS do
		Kit.pill(legend, {
			Text = string.upper(band.name),
			Color = C.Rarity[band.name],
			Solid = true,
			TextSize = T.Small,
			Size = UDim2.fromOffset(0, 24),
			AutomaticSize = Enum.AutomaticSize.X,
			LayoutOrder = order,
		})
	end

	local scroll = Kit.scrolling(window.content, { Size = UDim2.new(1, 0, 1, -30), Position = UDim2.fromOffset(0, 30) })
	-- The Index has no buttons: on gamepad the grid itself is selected so the stick scrolls it.
	Kit.selectable(scroll)
	focusPick.Index = function()
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
	local function layoutGrid()
		local width = window.size().X
		local columns = if isPhone(screen) then 3 elseif width >= 820 then 5 elseif width >= 680 then 4 else 3
		grid.CellSize = UDim2.new(1 / columns, -12, 0, CARD_H)
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
		-- Found: a raised card with a rarity outline. Unknown: the plain dark card.
		if known then
			Kit.paintGlass(frame, nil, Theme.Glass.SurfaceHi, rarity)
		else
			Kit.paintGlass(frame)
		end

		Kit.number(frame, {
			Name = "Tier",
			Text = "#" .. tier,
			TextSize = T.Small,
			Size = UDim2.new(0, 44, 0, 24),
			Position = UDim2.fromOffset(12, 8),
			TextXAlignment = Enum.TextXAlignment.Left,
			TextColor3 = if known then C.TextDim else C.TextMute,
		})
		-- Name under the character: 14 px, up to two lines (never scaled down).
		Kit.text(frame, {
			Name = "Name",
			Text = if known then string.upper(Theme.Tiers[tier].Name) else "???",
			Font = F.UI,
			TextSize = T.Small,
			TextWrapped = true,
			Size = UDim2.new(1, -16, 0, 36),
			Position = UDim2.new(0, 8, 1, -70),
			TextColor3 = if known then C.Text else C.TextMute,
			ZIndex = 3,
		})
		if known then
			-- Soft rarity-tinted spot behind the character.
			local spot = Kit.new("Frame", {
				Name = "Spot",
				BackgroundColor3 = rarity,
				BackgroundTransparency = 0.78,
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
			then Kit.unitViewport(frame, tier, { Size = UDim2.new(1, -16, 1, -112), Position = UDim2.fromOffset(8, 32) })
			else Kit.unitViewport(frame, tier, {
				Size = UDim2.new(1, -60, 1, -130),
				Position = UDim2.new(0.5, 0, 0, 40),
				AnchorPoint = Vector2.new(0.5, 0),
			}, true)
		viewport.ZIndex = 2
		if known then
			tag(frame, {
				Name = "Footer",
				Text = string.upper(band),
				Color = rarity,
				Position = UDim2.new(0.5, 0, 1, -8),
				AnchorPoint = Vector2.new(0.5, 1),
				ZIndex = 3,
			})
		else
			Kit.text(frame, {
				Name = "Footer",
				Text = string.upper(band),
				Font = F.UI,
				TextSize = T.Small,
				TextWrapped = false,
				Size = UDim2.new(1, -16, 0, 24),
				Position = UDim2.new(0, 8, 1, -32),
				TextColor3 = SMALL_TEXT,
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
				TextSize = T.Small,
				Size = UDim2.fromOffset(48, 22),
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
	local function refresh(force: boolean?)
		local data = State.data
		if not data or not (force or window.isOpen()) then
			return
		end
		if not sessionStart then
			sessionStart = State.now() - 2
		end
		local count = 0
		for tier = 1, Economy.MAX_TIER do
			local at = data.discovered[tier] or 0
			if at > 0 then
				count += 1
			end
			local isNew = at > 0 and at >= (sessionStart :: number) and not seen[tier]
			fillCard(tier, at, isNew)
		end
		if count ~= found and window.isOpen() then
			Kit.countTo(progressLabel, found, count, foundText)
		elseif count ~= found or progressLabel.Text == "" then
			progressLabel.Text = foundText(count)
		end
		found = count
		setProgress(count / Economy.MAX_TIER)
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
		-- First look at tiers discovered since the last visit: sparkle once,
		-- right after the card has rippled in.
		local data = State.data
		if not data or not sessionStart then
			return
		end
		for tier = 1, Economy.MAX_TIER do
			local at = data.discovered[tier] or 0
			if at > 0 and at >= (sessionStart :: number) and not seen[tier] and not sparkled[tier] then
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
	window.onClose.Event:Connect(function()
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
						local at = data.discovered[tier] or 0
						fillCard(tier, at, at > 0 and at >= (sessionStart :: number) and not seen[tier])
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

-- Gold, silver and bronze medal chips for the top three.
local MEDAL_COLORS = { C.Gold, C.Chrome, C.Amber }

type RowLabels = { rank: TextLabel, chip: Frame, value: TextLabel, extra: TextLabel? }

-- Boards: total units (the original board) and the sky obby's highest stage (with clears).
type Board = "units" | "stage"

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
		TextSize = 14,
	})
	local refreshButton = Kit.button(window.content, {
		Name = "Refresh",
		Text = "Refresh",
		Color = C.Window.Ranking,
		Size = UDim2.fromOffset(130, 42),
		Position = UDim2.new(1, 0, 0, 0),
		AnchorPoint = Vector2.new(1, 0),
		TextSize = 14,
	})
	local subtitle = Kit.text(window.content, {
		Name = "Subtitle",
		Text = "Top players by total " .. W.Units,
		TextSize = T.Small,
		TextWrapped = false,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Size = UDim2.new(1, -14, 0, 22),
		Position = UDim2.fromOffset(4, 48),
		TextXAlignment = Enum.TextXAlignment.Left,
		TextColor3 = C.TextDim,
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
			TextSize = T.Small,
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
	headerText({ "units" }, string.upper(W.Units), 0.62, 0.36, Enum.TextXAlignment.Right)
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
	-- Short windows (a phone): the subtitle goes and the columns and list move up into its
	-- row, so the list keeps two rows and a half above the pinned one.
	local function layoutRows(size: Vector2)
		local short = size.Y < 440
		local top = if short then 48 else 72
		subtitle.Visible = not short
		header.Position = UDim2.fromOffset(0, top)
		list.Position = UDim2.fromOffset(0, top + 28)
		list.Size = UDim2.new(1, 0, 1, -(top + 102))
	end
	layoutRows(window.size())
	window.onResize.Event:Connect(layoutRows)

	-- The player's own row, pinned under the list with a sunny outline (one face per board).
	local mine = Kit.panel(window.content, {
		Name = "Mine",
		Glass = true,
		Elevated = true,
		StrokeColor = C.Gold,
		StrokeThickness = 2.5,
		Size = UDim2.new(1, -14, 0, 54),
		Position = UDim2.new(0, 0, 1, -62),
		Radius = Kit.RADIUS.M,
	})
	local function mineFace(name: string): Frame
		return Kit.new("Frame", { Name = name, BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Parent = mine })
	end
	local mineUnits = mineFace("Units")
	local mineStage = mineFace("Stage")

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
		local rankChip = Kit.new("Frame", {
			Name = "Rank",
			BackgroundColor3 = color or C.Ink,
			BackgroundTransparency = if color then 0 else Theme.Glass.Inset,
			Size = UDim2.fromOffset(if color then 34 else 46, if color then 34 else 30),
			Position = UDim2.new(0.02, if color then 6 else 0, 0.5, 0),
			AnchorPoint = Vector2.new(0, 0.5),
			Parent = parent,
		})
		if color then
			-- Solid medal coin, lighter on top, with a darker rim.
			Kit.round(rankChip)
			Kit.gradient(rankChip, Color3.new(1, 1, 1), Color3.new(0.86, 0.86, 0.9))
			Kit.new("UIStroke", { Thickness = 2, Color = Kit.lip(color), Parent = rankChip })
		else
			Kit.corner(rankChip, 10)
			Kit.new("UIStroke", { Thickness = 1, Color = Theme.Glass.Edge, Transparency = 0.8, Parent = rankChip })
		end
		local rankLabel = Kit.number(rankChip, {
			Text = if color then tostring(rank) else rankText,
			TextSize = if color then T.Body else T.Small,
			Size = UDim2.fromScale(1, 1),
			TextColor3 = if color then C.GoldInk else C.TextDim,
			StrokeThickness = if color then 0 else nil,
		})
		Kit.text(parent, {
			Name = "Name",
			Text = name,
			Font = F.UI,
			TextSize = T.Body,
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
				TextSize = T.Small,
				Size = UDim2.fromOffset(46, 22),
				Position = UDim2.new(0.62, 0, 0.5, 0),
				AnchorPoint = Vector2.new(1, 0.5),
			})
		end
		local valueLabel = Kit.number(parent, {
			Name = "Value",
			Text = value,
			TextSize = T.Body,
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
				TextSize = T.Body,
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

	-- Rebuilds the leaderboard rows; `animate` ripples them in.
	local function renderList(animate: boolean)
		clearChildren(list)
		listFull = fullNumbers()
		local rows: { GuiObject } = {}
		local shown = if board == "stage" then stageEntries else entries
		for i, entry in shown do
			if type(entry) ~= "table" then
				continue
			end
			local isMe = isMine(entry)
			local rank = tonumber(entry.rank) or i
			local frame = Kit.panel(list, {
				Name = "Row" .. i,
				Glass = true,
				Elevated = isMe,
				StrokeColor = if isMe then C.Gold else nil,
				StrokeThickness = if isMe then 2.5 else nil,
				Size = UDim2.new(1, 0, 0, 46),
				LayoutOrder = i,
				Radius = Kit.RADIUS.M,
			})
			local name = tostring(entry.name or "?")
			if board == "stage" then
				local stage = tonumber(entry.stage) or tonumber(entry.value) or 0
				row(frame, rank, "#" .. rank, name, tostring(stage), isMe, Format.commas(tonumber(entry.clears) or 0))
			else
				row(frame, rank, "#" .. rank, name, fmt(tonumber(entry.value) or 0), isMe)
			end
			table.insert(rows, frame)
		end
		if #rows == 0 then
			local empty = Kit.text(list, {
				Text = if loaded then "No rankings yet - be the first!" else "Loading...",
				TextSize = T.Body,
				Size = UDim2.new(1, 0, 0, 60),
				TextColor3 = C.TextDim,
			})
			table.insert(rows, empty)
		end
		if animate then
			Kit.stagger(rows)
		end
	end

	-- Pinned row, format button, column headers and subtitle.
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
		mineUnits.Visible = board == "units"
		mineStage.Visible = board == "stage"
		for _, labels in headers do
			for _, label in labels do
				label.Visible = false
			end
		end
		for _, label in headers[board] do
			label.Visible = true
		end
		mineLabels.rank.Text = if myRank then "#" .. myRank else "--"
		local total = data and data.totalObtained or 0
		if mineValue and mineValue ~= total and window.isOpen() then
			Kit.countTo(mineLabels.value, mineValue, total, fmt)
		else
			mineLabels.value.Text = fmt(total)
		end
		mineValue = total
		local stage, clears = myStage()
		mineStageLabels.rank.Text = if myStageRank then "#" .. myStageRank else "--"
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
		subtitle.Text = (if board == "stage" then "Highest sky obby stage reached" else "Top players by total " .. W.Units) .. updated
	end

	-- Board tabs (built after the rows' helpers: Kit.tabs selects the first one at once).
	local tabsReady = false
	Kit.tabs(window.content, {
		Name = "Boards",
		Items = { { key = "units", text = W.Units }, { key = "stage", text = "Stage" } },
		Color = C.Window.Ranking,
		Size = UDim2.fromOffset(230, 42),
		TextSize = 14,
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
	local function fetch()
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
		fetch()
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

local function buildSettings(screen: ScreenGui)
	-- Sized to its four rows: 4 x 70 + 3 x 10 gaps + 20 padding + 84 of header and margins.
	-- The rows share the height, so the 386 minimum (a phone, scaled up x1.3) has 63 px rows.
	local window = Kit.window(screen, "Settings", "Settings", I.Settings, C.Window.Settings, Vector2.new(560, 414), Vector2.new(560, 386))
	register("Settings", window)
	local action = Net.event("Action")

	Kit.list(window.content, 10)

	local rows: { GuiObject } = {}
	local toggles: { { key: string, set: (boolean, boolean?) -> (), sub: TextLabel, medal: Frame } } = {}
	local function toggle(order: number, icon: string, text: string, desc: string, key: string)
		local row = Kit.panel(window.content, {
			Name = key,
			Glass = true,
			Size = UDim2.new(1, 0, 0.25, -8),
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
		Kit.text(row, {
			Text = string.upper(text),
			Font = F.UI,
			TextSize = T.Body,
			TextWrapped = false,
			Size = UDim2.new(1, -170, 0, 22),
			Position = UDim2.new(0, 72, 0.5, -23),
			TextXAlignment = Enum.TextXAlignment.Left,
		})
		local sub = Kit.text(row, {
			Text = desc,
			TextSize = T.Small,
			TextWrapped = false,
			TextTruncate = Enum.TextTruncate.AtEnd,
			Size = UDim2.new(1, -176, 0, 20),
			Position = UDim2.new(0, 72, 0.5, 2),
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

	local ON_TILE = C.Ink:Lerp(C.Window.Settings, 0.55)
	local function refresh()
		local data = State.data
		if not data then
			return
		end
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
	The plaza game modes, one full row each in the same arrangement (quiet medal, title,
	blurb, stats, reward line and a gold PLAY that fires ModeStart and closes the window;
	PLAY is the one loud element per row), then one slim "More modes coming soon" row.

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

-- "Finish: +$X" or the cooldown countdown; `bonus` adds a "(xB)" tag.
local function setRewardLine(label: TextLabel, cash: number, full: boolean, cooldownEnds: number, bonus: number?)
	local left = cooldownEnds - os.time()
	if not full and left > 0 then
		label.TextColor3 = C.TextDim
		label.Text = "Reward again in " .. Format.time(left)
		return
	end
	label.TextColor3 = C.MoneyText
	local text = "Finish: +" .. Format.money(cash)
	if bonus and bonus > 1.001 then
		text ..= string.format("  (×%s)", (string.format("%.1f", bonus):gsub("%.0$", "")))
	end
	label.Text = text
end

local PIP_COUNT = 10

-- Difficulty row: a fire icon, 10 pips (gold warming to red) and "n/10". props: Name, Size,
-- Position, Pip (pip size, default 10). Returns the setter.
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
	Kit.list(row, 3, true).VerticalAlignment = Enum.VerticalAlignment.Center
	Kit.icon(row, "Fire", pipSize + 6, C.Gold, { LayoutOrder = 0, ZIndex = 2 })
	local pips: { Frame } = {}
	for i = 1, PIP_COUNT do
		local pip = Kit.new("Frame", {
			Name = "Pip" .. i,
			BackgroundColor3 = C.Well,
			Size = UDim2.fromOffset(pipSize, pipSize),
			LayoutOrder = i,
			ZIndex = 2,
			Parent = row,
		})
		Kit.corner(pip, 3)
		pips[i] = pip
	end
	local of = Kit.text(row, {
		Name = "Of10",
		Text = "",
		Font = F.UI,
		TextSize = T.Small,
		TextWrapped = false,
		TextXAlignment = Enum.TextXAlignment.Left,
		Size = UDim2.fromOffset(44, pipSize + 6),
		LayoutOrder = PIP_COUNT + 1,
		TextColor3 = C.TextDim,
		ZIndex = 2,
	})
	return function(value: number)
		local difficulty = math.clamp(math.floor(value), 1, PIP_COUNT)
		for i, pip in pips do
			local on = i <= difficulty
			pip.BackgroundColor3 = if on then C.Gold:Lerp(C.Bad, (i - 1) / (PIP_COUNT - 1)) else C.Well
			pip.BackgroundTransparency = if on then 0 else 0.3
		end
		of.Text = string.format("%d/%d", difficulty, PIP_COUNT)
	end
end

-- What finishing parkour `level` pays, from the snapshot `info` (modes.parkour).
-- rewardPreview is priced for info.level; its cash is rescaled to `level`'s bonus.
local function parkourReward(label: TextLabel, info: { [string]: any }, level: number)
	local list = if type(info.levels) == "table" then info.levels else {}
	local lv = list[level]
	local preview = info.rewardPreview
	if type(preview) ~= "table" or type(lv) ~= "table" then
		label.Text = ""
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
	setRewardLine(label, cash, full, cooldownEnds, bonus)
end

type ModeRow = { panel: Frame, stats: TextLabel, reward: TextLabel, play: TextButton }

-- One mode row: medal, title, blurb, stats line, reward line and the PLAY button.
local function modeRow(parent: Instance, props: { [string]: any }, accent: Color3, onPlay: () -> ()): ModeRow
	local panel = Kit.panel(parent, {
		Name = props.Name,
		Glass = true,
		Size = UDim2.new(1, 0, 0, props.Height),
		LayoutOrder = props.LayoutOrder,
		Radius = Kit.RADIUS.M + 2,
	})
	-- Quiet medal (an accent rim only), so the PLAY button is the one loud thing here.
	local medal = Kit.new("Frame", {
		Name = "Medal",
		BackgroundColor3 = C.Ink,
		BackgroundTransparency = Theme.Glass.Inset,
		Size = UDim2.fromOffset(46, 46),
		Position = UDim2.fromOffset(12, 14),
		Parent = panel,
	})
	Kit.corner(medal, 14)
	Kit.new("UIStroke", { Thickness = 2, Color = accent, Transparency = 0.2, Parent = medal })
	Kit.text(medal, { Text = props.Medal, TextSize = 26, Size = UDim2.fromScale(1, 1), ZIndex = 2 })
	Kit.title(panel, {
		Text = props.Title,
		TextSize = T.H3,
		TextWrapped = false,
		TextXAlignment = Enum.TextXAlignment.Left,
		Size = UDim2.new(1, -80, 0, 24),
		Position = UDim2.fromOffset(70, 14),
		TextColor3 = C.Text,
	})
	Kit.text(panel, {
		Text = props.Blurb,
		TextSize = T.Small,
		TextXAlignment = Enum.TextXAlignment.Left,
		Size = UDim2.new(1, -80, 0, 20),
		Position = UDim2.fromOffset(70, 38),
		TextColor3 = C.TextDim,
		StrokeThickness = 0,
	})
	local stats = Kit.text(panel, {
		Name = "Stats",
		Text = "",
		Font = F.UI,
		TextSize = T.Small,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextWrapped = false,
		Size = UDim2.new(1, -80, 0, 20),
		Position = UDim2.fromOffset(70, 60),
		TextColor3 = C.Text,
	})
	local reward = Kit.text(panel, {
		Name = "Reward",
		Text = "",
		Font = F.UI,
		TextSize = T.Small,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextWrapped = false,
		Size = UDim2.new(1, -164, 0, 20),
		Position = UDim2.new(0, 12, 1, -40),
		AnchorPoint = Vector2.new(0, 0.5),
		TextColor3 = C.MoneyText,
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
	return { panel = panel, stats = stats, reward = reward, play = play }
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
	local window = Kit.window(screen, "Modes", "Game Modes", "🏁", accent, Vector2.new(540, 486), Vector2.new(420, 400))
	register("Modes", window)
	local action = Net.event("Action")
	Kit.list(window.content, 10)

	local rows: { GuiObject } = {}
	local selected = 1

	-- Parkour ---------------------------------------------------------------------------
	local parkour = modeRow(
		window.content,
		{
			Name = "PARKOUR",
			Height = 168,
			LayoutOrder = 1,
			Medal = "🏃",
			Title = "PARKOUR",
			Blurb = "Ten sea maps: jump, bounce and slide!",
		},
		accent,
		function()
			action:FireServer({ action = "ModeStart", mode = "parkour", level = selected })
			Windows.closeAll()
		end
	)
	table.insert(rows, parkour.panel)
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
	-- The preselected map's details sit in the left column above the reward line.
	local levelName = Kit.title(parkour.panel, {
		Name = "LevelName",
		Text = "",
		TextSize = T.Body,
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
	parkour.stats.Position = UDim2.fromOffset(12, 110)
	parkour.stats.Size = UDim2.new(1, -164, 0, 20)
	parkour.reward.Position = UDim2.new(0, 12, 1, -24)

	-- MOG TEST --------------------------------------------------------------------------
	-- Gamepad starts on the loud PLAY of the first mode.
	parkour.play:SetAttribute("FocusFirst", true)
	local mog = modeRow(
		window.content,
		{
			Name = "MOGTEST",
			Height = 150,
			LayoutOrder = 2,
			Medal = "💪",
			Title = "MOG TEST",
			Blurb = "Out-mog 3 rivals, or duel a real player 1v1!",
		},
		accent,
		function()
			local pick = Windows.onMogPlay
			if pick then
				pick()
			else
				action:FireServer({ action = "ModeStart", mode = "mog", vs = "rivals" })
			end
			Windows.closeAll()
		end
	)
	table.insert(rows, mog.panel)

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

	-- Short windows: the Mog row folds its stats under the medal (like Parkour's, 118 px),
	-- and the "coming soon" row goes while there is no room for it: 168 + 10 + 118 fills
	-- the 400 minimum.
	local function layoutRows(size: Vector2)
		local short = size.Y < 486
		mog.panel.Size = UDim2.new(1, 0, 0, if short then 118 else 150)
		mog.stats.Position = if short then UDim2.fromOffset(12, 66) else UDim2.fromOffset(70, 60)
		mog.stats.Size = UDim2.new(1, if short then -164 else -80, 0, 20)
		mog.reward.Position = UDim2.new(0, 12, 1, if short then -22 else -40)
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
			levelName.Text = "Level 1"
			setPips(1)
			parkour.stats.Text = "Best --  ·  0 clears"
			parkour.reward.Text = ""
			return
		end
		local icon = if type(lv.icon) == "string" and lv.icon ~= "" then lv.icon .. " " else ""
		levelName.Text = string.format("Level %d  ·  %s%s", selected, icon, tostring(lv.name or ""))
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
			mog.reward.Text = ""
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
			mog.reward.Text = ""
		else
			setRewardLine(
				mog.reward,
				tonumber(preview.packCash) or tonumber(preview.cash) or 0,
				preview.full ~= false,
				tonumber(info.cooldownEnds) or 0
			)
		end
		Kit.setButton(mog.play, if info.running then "PLAYING" else "PLAY")
		Kit.setEnabled(mog.play, not info.running)
	end

	local function refresh()
		refreshParkour()
		refreshMog()
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
