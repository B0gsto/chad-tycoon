--[[
	Popups: toasts, reward reveals, the held-crate panel, confirm dialogs,
	offline earnings, the rebirth cards and floating "+X" text.

	Everything eases: popups come in with Kit.appear and leave with
	Kit.disappear, toasts slide into a stack, floats rise on an arc, numbers
	count up. Celebrations use the candy colours of Theme.World (confetti,
	soft rays, a white ring on bursts). The one whole-screen flash is a short white
	one under an Epic or rarer discovery (never with reduced motion).

	A unit reveal is not a dialog: the unit floats over the dimmed world with
	its text straight on the scene, and a new discovery flies off into the
	HUD's Index button (see showReveal). An action that discovers several tiers
	plays one reveal per tier, lowest first (revealChain).

	Not modal, straight over the game: the free gift card (Popups.gift), the centre
	banner (Popups.banner: surge start, tutorial done) and the surge countdown chip.

	Z order (ScreenGui uses Sibling ZIndex):
	  floats 20, toasts and the surge chip 25, gift card 27, banner 28, reward 30,
	  offline 44-45, starter and the rebirth cards 46-47, confirm 49-50, cash rain 50
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local GuiService = game:GetService("GuiService")
local Workspace = game:GetService("Workspace")
local ContextActionService = game:GetService("ContextActionService")

local Economy = require(ReplicatedStorage.Shared.Economy)
local Format = require(ReplicatedStorage.Shared.Format)
local Net = require(ReplicatedStorage.Shared.Net)

local Guide = require(script.Parent.Parent.Guide)
local Hud = require(script.Parent.Hud)
local Kit = require(script.Parent.Kit)
local State = require(script.Parent.Parent.State)
local Sprites = require(script.Parent.Parent.Fx.Sprites)
local Windows = require(script.Parent.Windows)

local Theme = Kit.Theme
local C = Kit.C
local T = Kit.TEXT
local W = Theme.Words
local World = Theme.World

local WHITE = Color3.new(1, 1, 1)

-- Candy colours for confetti (the world's paint, never neon).
local CANDY = { World.Sunny, World.Pink, World.Mint, World.Blue, World.Grape, World.Orange, World.White }

-- The Lune preview exporter stubs TweenInfo and captures synchronously: there,
-- modals skip the queue and staged reveals build at once.
local PREVIEW = typeof(TweenInfo.new(0)) ~= "TweenInfo"

local Popups = {}

local screen: ScreenGui
local toastHolder: Frame
local sounds: any

local TOAST_Y = 146
-- A touch phone (attribute "Compact") has the HUD's menu as one row along the top left
-- (Hud's measure(): from y 88, a tap target tall), and that row reaches under the stack:
-- there the toasts start below it.
local PHONE_MENU_Y = 88
local PHONE_MENU_H = 76
local PHONE_TAP_PX = 44
local PHONE_MENU_GAP = 8

-- Defined with the held-crate art below; toasts that name a crate draw it too.
local crateIcon: (parent: Instance, color: Color3, size: number, props: { [string]: any }?) -> Frame

-- Motion helpers -------------------------------------------------------------------

-- Runs `fn` after `t` seconds (at once in the preview).
local function after(t: number, fn: () -> ())
	if PREVIEW then
		fn()
	else
		task.delay(t, fn)
	end
end

-- Tween with a start delay.
local function tweenAfter(
	obj: Instance,
	time: number,
	delay: number,
	props: { [string]: any },
	style: Enum.EasingStyle?,
	direction: Enum.EasingDirection?
): Tween
	local info = TweenInfo.new(time, style or Enum.EasingStyle.Quad, direction or Enum.EasingDirection.Out, 0, false, delay)
	local tween = TweenService:Create(obj, info, props)
	tween:Play()
	return tween
end

-- Screen-covering layer inside a centred holder (a soft navy dim or a tint).
local function cover(parent: Instance, name: string, color: Color3, transparency: number): Frame
	return Kit.new("Frame", {
		Name = name,
		BackgroundColor3 = color,
		BackgroundTransparency = transparency,
		BorderSizePixel = 0,
		Size = UDim2.fromOffset(6000, 6000),
		Position = UDim2.fromScale(0.5, 0.5),
		AnchorPoint = Vector2.new(0.5, 0.5),
		ZIndex = 0,
		Parent = parent,
	})
end

-- Transparent full-screen tap catcher inside a centred holder.
local function catcher(parent: Instance, zindex: number): TextButton
	return Kit.new("TextButton", {
		Name = "Skip",
		AutoButtonColor = false,
		BackgroundTransparency = 1,
		Selectable = false,
		Text = "",
		Size = UDim2.fromOffset(6000, 6000),
		Position = UDim2.fromScale(0.5, 0.5),
		AnchorPoint = Vector2.new(0.5, 0.5),
		ZIndex = zindex,
		Parent = parent,
	})
end

local function circle(parent: Instance, name: string, color: Color3, transparency: number, zindex: number): Frame
	local frame = Kit.new("Frame", {
		Name = name,
		BackgroundColor3 = color,
		BackgroundTransparency = transparency,
		BorderSizePixel = 0,
		Position = UDim2.fromScale(0.5, 0.5),
		AnchorPoint = Vector2.new(0.5, 0.5),
		ZIndex = zindex,
		Parent = parent,
	})
	Kit.round(frame)
	return frame
end

-- Toasts ------------------------------------------------------------------------
--[[
	A short stack under the HUD's top strips, newest on top. Each toast is a glass
	card (Kit.hudGlass: the world shows through, no blur) a tier above those quiet
	strips: denser, with an accent bar down its left edge and an icon chip in the
	notification's colour (green success, gold info, orange warning, coral error,
	a crate's rarity) and outlined HUD text a size up from the strips'. It drops in 12 px with a fade
	and a slight scale, the others glide down to make room, and it fades up and
	away after 3 s. A toast that names a crate ("A Rare Crate is on its way!")
	carries that rarity's colour and a little crate instead of the tone's chip.
]]

local TONES = {
	good = { color = C.Cash, icon = "Check" },
	bad = { color = C.Danger, icon = "!" },
	info = { color = C.Gold, icon = "i" },
	warn = { color = C.Amber, icon = "!" },
}

local TOAST_H = 44
local TOAST_STEP = 52 -- toast + shadow + gap
local TOAST_SLIDE = 12
local TOAST_IN = 0.18
local TOAST_TEXT = 18
local TOAST_TEXT_X = 60
local TOAST_ICON_X = 19 -- past the accent bar
local MAX_TOASTS = 4
-- While a window or modal is open the stack sits at the very top of the safe area, over
-- the margin above the window: TOAST_TOP from the edge. A toast may reach HEADER_CLEAR into
-- the window (the empty band of its title row, above the title), never further: its tabs
-- and content stay clear.
local TOAST_TOP = 6
local HEADER_CLEAR = 16
-- Errors and warnings ("Not enough cash", "Rack full") answer what the player just did:
-- they never wait behind an open window. Over one they show at once on a layer above every
-- window, modal and dim (TOAST_FRONT): in the top slot when a toast fits above the window
-- (the informational ones there step out and wait), else along the bottom of the safe area.
local URGENT: { [string]: boolean } = { bad = true, warn = true }
local TOAST_FRONT = 100

type HeldToast = { text: string, tone: string? }
local toasts: { Frame } = {}
-- Urgent toasts along the bottom edge (newest lowest), in their own holder.
local lowToasts: { Frame } = {}
local toastInfo: { [Frame]: HeldToast } = {}
local frontHolder: Frame
local lowHolder: Frame

local function isUrgent(tone: string?): boolean
	return tone ~= nil and URGENT[tone] == true
end
-- Toasts that wait (the last MAX_TOASTS). A unit reveal owns the screen (setReveal): the
-- toasts on screen hide and new ones wait, then drop in once it has gone. Over an open
-- window, the ones there is no room for above it wait until it closes.
local revealCount = 0
local heldToasts: { HeldToast } = {}

-- Height the surge countdown chip takes at the head of the stack (0 while it is away).
local chipRoom = 0
-- Glides the stack to its place (set in Popups.build).
local placeToastHolder: (() -> ())? = nil

-- Top of the stack with nothing above it (design px): under the HUD's top strips, and on a
-- touch phone under its menu row too.
local function toastBase(): number
	if not Kit.touch or screen:GetAttribute("Compact") ~= true then
		return TOAST_Y
	end
	local uiScale = screen:FindFirstChildOfClass("UIScale")
	local scale = if uiScale and uiScale.Scale > 0 then uiScale.Scale else 1
	local bottom = PHONE_MENU_Y + math.max(PHONE_MENU_H, math.ceil(PHONE_TAP_PX / scale))
	-- The row itself once it is laid out (its y holds while the HUD parks it off the left
	-- edge); the estimate above until then, or if the plate is somewhere unexpected.
	local plate = Hud.buttons.Home
	if plate and plate.AbsoluteSize.Y > 0 then
		local measured = (plate.AbsolutePosition.Y + plate.AbsoluteSize.Y - screen.AbsolutePosition.Y) / scale
		if measured > TOAST_Y - TOAST_H and measured < TOAST_Y + 120 then
			bottom = measured
		end
	end
	return math.max(TOAST_Y, math.ceil(bottom) + PHONE_MENU_GAP)
end

-- Where the stack sits (y, design px) and how many toasts it may show there. Under the
-- HUD's top strips (and the tutorial card and the surge chip) normally; while a window or
-- modal is open, at the very top, as many as fit above it: none when the window reaches the
-- top of the screen or the tutorial pill holds that slot.
local function toastRoom(): (number, number)
	local card = screen:GetAttribute("TopCardHeight")
	local cardH: number = if type(card) == "number" then card else 0
	if screen:GetAttribute("WindowOpen") ~= true then
		return toastBase() + cardH + chipRoom, MAX_TOASTS
	end
	local top = Kit.openTop(screen)
	if not top or cardH > 0 then
		return TOAST_TOP, 0
	end
	local free = top + HEADER_CLEAR - TOAST_TOP
	return TOAST_TOP, math.clamp(math.floor((free - TOAST_H) / TOAST_STEP) + 1, 0, MAX_TOASTS)
end

local function holdToast(held: HeldToast)
	table.insert(heldToasts, held)
	while #heldToasts > MAX_TOASTS do
		table.remove(heldToasts, 1)
	end
end

-- Drops in the toasts that waited, as far as there is room for them now.
local function flushToasts()
	if revealCount > 0 then
		return
	end
	local _, room = toastRoom()
	local released = 0
	while #heldToasts > 0 and #toasts + released < room do
		local held = table.remove(heldToasts, 1) :: HeldToast
		task.delay(released * 0.12, function()
			Popups.toast(held.text, held.tone)
		end)
		released += 1
	end
end

-- Width that hugs the text (TextService when available, else an estimate).
local function toastWidth(text: string): number
	local width = 0
	pcall(function()
		local TextService = game:GetService("TextService")
		width = TextService:GetTextSize(text, TOAST_TEXT, Theme.Fonts.Display, Vector2.new(1000, 40)).X
	end)
	if width <= 0 then
		width = (utf8.len(text) or #text) * 9.2
	end
	return math.clamp(math.ceil(width) + TOAST_TEXT_X + 28, 220, 540)
end

-- The rarity a toast's text names next to the crate word, if any.
local function toastRarity(text: string): string?
	for rarity in C.Rarity do
		if string.find(text, rarity .. " " .. W.Chest, 1, true) then
			return rarity
		end
	end
	return nil
end

-- Glides every toast to its slot; `fresh` (the one dropping in) takes the quicker ease.
local function placeToasts(fresh: Frame?)
	-- The top stack is one list in two holders of the same place and size (the usual one
	-- and the front layer), so its toasts never overlap whichever they are in.
	for i = #toasts, 1, -1 do
		if toasts[i].Parent ~= toastHolder and toasts[i].Parent ~= frontHolder then
			table.remove(toasts, i)
		end
	end
	for i = #lowToasts, 1, -1 do
		if lowToasts[i].Parent ~= lowHolder then
			table.remove(lowToasts, i)
		end
	end
	local function glide(toast: Frame, goal: { [string]: any })
		if toast == fresh then
			Kit.tween(toast, TOAST_IN, goal, Enum.EasingStyle.Quad)
		else
			Kit.tween(toast, 0.26, goal, Enum.EasingStyle.Quint)
		end
	end
	for index, toast in toasts do
		glide(toast, { Position = UDim2.new(0.5, 0, 0, (index - 1) * TOAST_STEP) })
	end
	-- The bottom stack grows upward from the edge.
	for index, toast in lowToasts do
		glide(toast, { Position = UDim2.new(0.5, 0, 1, -(index - 1) * TOAST_STEP) })
	end
end

local function dismissToast(toast: Frame)
	local low = false
	local index = table.find(toasts, toast)
	if not index then
		index = table.find(lowToasts, toast)
		low = true
	end
	if not index then
		return
	end
	table.remove(if low then lowToasts else toasts, index)
	toastInfo[toast] = nil
	-- Out the way it came: up from the top stack, down from the bottom one.
	local slide = if low then TOAST_SLIDE else -TOAST_SLIDE
	Kit.tween(toast, 0.2, { Position = toast.Position + UDim2.fromOffset(0, slide) }, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
	Kit.disappear(toast, { time = 0.2, to = 0.97, destroy = true })
	placeToasts()
	-- Its slot is free once it has faded: the next waiting toast takes it.
	if #heldToasts > 0 then
		task.delay(0.22, flushToasts)
	end
end

-- Keeps the top stack inside its room over a window: the informational toasts past it
-- (the oldest first) step out and wait; errors and warnings stay, on the front layer.
local function clearForWindow(room: number)
	local kept = 0
	local waiting: { Frame } = {}
	for _, toast in toasts do
		local info = toastInfo[toast]
		if info and isUrgent(info.tone) then
			toast.Parent = frontHolder
			kept += 1
		elseif kept < room then
			kept += 1
		else
			table.insert(waiting, 1, toast)
		end
	end
	for _, toast in waiting do
		local info = toastInfo[toast]
		if info then
			holdToast(info)
		end
		dismissToast(toast)
	end
end

function Popups.toast(text: string, tone: string?)
	-- The stack's place may have moved since it was last set (a phone's menu row is only
	-- measured once the HUD is laid out).
	if placeToastHolder then
		placeToastHolder()
	end
	local _, room = toastRoom()
	local windowUp = screen:GetAttribute("WindowOpen") == true
	local urgent = isUrgent(tone)
	-- A reveal holds every toast for its few seconds; a window only the ones that can wait.
	if revealCount > 0 or (windowUp and not urgent and #toasts >= room) then
		holdToast({ text = text, tone = tone })
		return
	end
	-- An error or warning over a window: on the front layer, at the bottom edge when no
	-- toast fits above the window (a phone).
	local front = windowUp and urgent
	local low = front and room < 1
	local style = TONES[tone or "info"] or TONES.info
	local rarity = toastRarity(text)
	local color: Color3 = if rarity then C.Rarity[rarity] else style.color
	local toast = Kit.new("Frame", {
		Name = "Toast",
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(toastWidth(text), TOAST_H),
		Position = if low then UDim2.new(0.5, 0, 1, TOAST_SLIDE) else UDim2.new(0.5, 0, 0, -TOAST_SLIDE),
		AnchorPoint = Vector2.new(0.5, if low then 1 else 0),
		Parent = if low then lowHolder elseif front then frontHolder else toastHolder,
	})
	local card = Kit.hudGlass(toast, { Name = "Card", Size = UDim2.new(1, 0, 0, TOAST_H), Radius = Kit.RADIUS.M, Accent = color })
	if rarity then
		-- The crate itself, in its rarity's colour.
		crateIcon(card, color, 32, {
			Name = "Icon",
			Rarity = rarity,
			Position = UDim2.new(0, TOAST_ICON_X + 15, 0.5, 0),
			AnchorPoint = Vector2.new(0.5, 0.5),
			ZIndex = 2,
		})
	else
		local chip = Kit.new("Frame", {
			Name = "Icon",
			BackgroundColor3 = WHITE,
			Size = UDim2.fromOffset(30, 30),
			Position = UDim2.new(0, TOAST_ICON_X, 0.5, 0),
			AnchorPoint = Vector2.new(0, 0.5),
			ZIndex = 2,
			Parent = card,
		})
		Kit.round(chip)
		Kit.gradient(chip, Kit.lighten(color, 0.25), color)
		Kit.stroke(chip, 2, Kit.lip(color))
		local ink = Kit.inkOn(color)
		if Kit.ICONS[style.icon] then
			Kit.icon(chip, style.icon, 16, ink, { Position = UDim2.fromScale(0.5, 0.5), AnchorPoint = Vector2.new(0.5, 0.5), ZIndex = 3 })
		else
			Kit.text(chip, {
				Text = style.icon,
				Font = Theme.Fonts.Display,
				TextSize = 18,
				TextColor3 = ink,
				Size = UDim2.fromScale(1, 1),
				Position = UDim2.fromOffset(0, 1),
				StrokeThickness = 0,
				ZIndex = 3,
			})
		end
	end
	Kit.hudText(card, {
		Name = "Text",
		Text = text,
		MaxTextSize = TOAST_TEXT,
		Size = UDim2.new(1, -(TOAST_TEXT_X + 14), 0, TOAST_TEXT + 6),
		Position = UDim2.new(0, TOAST_TEXT_X, 0.5, 1),
		AnchorPoint = Vector2.new(0, 0.5),
		TextXAlignment = Enum.TextXAlignment.Left,
		StrokeThickness = 2,
		ZIndex = 2,
	})

	local stack = if low then lowToasts else toasts
	table.insert(stack, 1, toast)
	toastInfo[toast] = { text = text, tone = tone }
	if front and not low then
		-- It takes the slot above the window: what was informational there waits.
		clearForWindow(room)
	end
	while #stack > MAX_TOASTS do
		dismissToast(stack[#stack])
	end
	placeToasts(toast)
	Kit.appear(toast, { from = 0.94, time = TOAST_IN, style = Enum.EasingStyle.Quad })
	if tone == "bad" then
		sounds.play("Error")
	else
		sounds.play("Toast")
	end
	task.delay(3, function()
		dismissToast(toast)
	end)
end

--[[
	Merge count on the reveal. Fx.Shelf floats "xN MERGES!" over the rack as world text
	(Fx.Orbs.text: a part with a BillboardGui, in Workspace.ClientFx) and marks that part
	with the attribute MERGES_ATTRIBUTE, which holds the text. A discovery's reveal comes up
	a moment later and its "NEW CHAD!" banner landed on that text. So while a reveal is up
	the world text is hidden, and the reveal shows the same line under its name plate
	instead (showReveal).
]]
-- Fx.Shelf.MERGES_ATTRIBUTE (not required here: the Fx modules may be missing or fail).
local MERGES_ATTRIBUTE = "MergesText"
local MERGES_FRESH = 4 -- seconds a merge count still belongs to the next reveal
local MERGES_MIN = 3 -- Fx.Shelf floats no count under three merges
local mergeTexts: { Instance } = {} -- the world texts still alive
local mergesText, mergesAt = "", 0 -- the last one seen
local mergeTally, mergeTallyAt = 0, 0 -- merges of the last batch ("Merge" effects)
local mergesOnReveal: ((text: string) -> ())? = nil -- the reveal on screen takes the line

--[[
	What a merge gained. The units' aura per second is worked out from every snapshot (from
	the units, so a surge does not count) and kept for a few seconds; the gain of an action
	is the newest value minus the one from just before it. That is only the fallback: the
	server sends the real numbers (`productionBefore` / `productionAfter`, aura per second
	without the surge, on the Reward notify and on every "Merge" effect), which win.

	A merge batch that discovers nothing gets no card: a float over the rack, "+24 merges ·
	Aura +1.2K/sec", MERGE_SETTLE after its last "Merge" effect (by then its Reward notify
	would have arrived, and its snapshot has). It stands in for the world's "xN MERGES!"
	text, which is hidden like under a reveal. Auto merges (on a buy) only float from
	MERGES_MIN up, manual ones always.
]]
local PROD_KEEP = 8 -- seconds of history
local PROD_LEAD = 0.25 -- a snapshot this close before an action is taken as the action's own
local MERGE_SETTLE = 0.7
local MERGE_FLOAT_LIFE = 2
local RACK_FALLBACK = UDim2.fromScale(0.5, 0.36)
local RACK_LIFT = 6 -- studs above the merged unit's spot

type MergeBatch = { count: number, startedAt: number, to: Vector3?, manual: boolean, token: number, gain: number? }
local prodHistory: { { at: number, value: number } } = {}
local mergeBatch: MergeBatch? = nil
local mergeFloatAt = 0
local lastDiscoveryAt = 0 -- os.clock() of the last Reward notify with a new tier

local function noteProduction(data: any)
	if type(data) ~= "table" or type(data.units) ~= "table" then
		return
	end
	local ok, value = pcall(Economy.productionPerSecond, data.units)
	if not ok or type(value) ~= "number" then
		return
	end
	local last = prodHistory[#prodHistory]
	if last and last.value == value then
		return
	end
	local now = os.clock()
	table.insert(prodHistory, { at = now, value = value })
	-- Always keeps the newest sample older than the window: the value "before".
	while #prodHistory > 2 and now - prodHistory[2].at > PROD_KEEP do
		table.remove(prodHistory, 1)
	end
end

-- Aura per second gained since `since` (os.clock()); nil when unknown or nothing gained.
local function productionGain(since: number): number?
	local base: number? = nil
	for _, sample in prodHistory do
		if sample.at > since then
			break
		end
		base = sample.value
	end
	local newest = prodHistory[#prodHistory]
	if not base or not newest or newest.value <= base then
		return nil
	end
	return newest.value - base
end

-- "+1.20K Aura/sec": one decimal under 10 so a small gain never reads as zero.
local function gainText(amount: number): string
	local number = if amount < 10 then string.format("%.1f", amount) else Format.short(amount)
	return string.format("%s +%s/sec", W.Orb, number)
end

-- A world point as a spot on the ScreenGui (design px), kept inside the screen; `fallback`
-- when it is off screen or behind the camera.
local function worldAnchor(pos: Vector3?, fallback: UDim2): UDim2
	local camera = Workspace.CurrentCamera
	if not pos or not camera then
		return fallback
	end
	local point, visible = camera:WorldToScreenPoint(pos)
	if not visible then
		return fallback
	end
	local uiScale = screen:FindFirstChildOfClass("UIScale")
	local scale = if uiScale and uiScale.Scale > 0 then uiScale.Scale else 1
	local size = screen.AbsoluteSize / scale
	local x = (point.X - screen.AbsolutePosition.X) / scale
	local y = (point.Y - screen.AbsolutePosition.Y) / scale
	if x < 0 or x > size.X or y < 0 or y > size.Y or size.X < 600 or size.Y < 340 then
		return fallback
	end
	return UDim2.fromOffset(math.clamp(x, 280, size.X - 280), math.clamp(y, 150, size.Y - 170))
end

-- Hides the live world texts (they fade and go by themselves) and forgets the dead ones.
local function hideMergeTexts(hide: boolean)
	for i = #mergeTexts, 1, -1 do
		local part = mergeTexts[i]
		local gui = if part.Parent then part:FindFirstChildWhichIsA("BillboardGui") else nil
		if not gui then
			table.remove(mergeTexts, i)
		elseif hide then
			gui.Enabled = false
		end
	end
end

local function mergeFloat(batch: MergeBatch)
	-- A discovery's reveal carries the count and the gain itself; a window covers the rack.
	if revealCount > 0 or lastDiscoveryAt >= batch.startedAt - 0.5 or screen:GetAttribute("WindowOpen") == true then
		return
	end
	if not batch.manual and batch.count < MERGES_MIN then
		return
	end
	local text = string.format("+%s %s", Format.short(batch.count), if batch.count == 1 then "merge" else "merges")
	local gain = batch.gain or productionGain(batch.startedAt - PROD_LEAD)
	if gain and gain > 0 then
		text ..= " · " .. gainText(gain)
	end
	mergeFloatAt = os.clock()
	mergesAt, mergeTally = 0, 0
	hideMergeTexts(true)
	local spot = if batch.to then batch.to + Vector3.new(0, RACK_LIFT, 0) else nil
	Popups.float(text, C.GoldLight, worldAnchor(spot, RACK_FALLBACK), { life = MERGE_FLOAT_LIFE, size = 28, width = 560, drift = false })
	sounds.play("Tick", 0.02, 1.3)
end

-- A reveal starts or ends. While one is up the ScreenGui attribute "RevealOpen" is true
-- (the tutorial pill steps out on it), the toast stack is hidden and so is the world's
-- "xN MERGES!" text.
local function setReveal(on: boolean)
	revealCount = math.max(0, revealCount + (if on then 1 else -1))
	local up = revealCount > 0
	screen:SetAttribute("RevealOpen", up)
	toastHolder.Visible = not up
	if up then
		hideMergeTexts(true)
	else
		flushToasts()
	end
end

-- Watches Fx.Orbs' folder for the "xN MERGES!" texts, and the "Merge" effects for the size
-- of the batch (the text can land after the reveal has started).
local function watchMerges()
	local function onText(part: Instance)
		-- Set by Fx.Shelf before the part is parented.
		local text = part:GetAttribute(MERGES_ATTRIBUTE)
		if type(text) ~= "string" or text == "" then
			return
		end
		-- Orbs.text parents the part first and builds its BillboardGui in the same step.
		task.defer(function()
			hideMergeTexts(false)
			table.insert(mergeTexts, part)
			mergesText, mergesAt = text, os.clock()
			if revealCount > 0 then
				hideMergeTexts(true)
				if mergesOnReveal then
					mergesOnReveal(text)
				end
			elseif mergeBatch or os.clock() - mergeFloatAt < MERGES_FRESH then
				-- The float over the rack says it (mergeFloat).
				hideMergeTexts(true)
			end
		end)
	end
	local function bind(child: Instance)
		if child.Name == "ClientFx" and child:IsA("Folder") then
			child.ChildAdded:Connect(onText)
		end
	end
	for _, child in Workspace:GetChildren() do
		bind(child)
	end
	Workspace.ChildAdded:Connect(bind)
	Net.event("Effect").OnClientEvent:Connect(function(kind, data)
		if kind ~= "Merge" or type(data) ~= "table" or data.overflow == true then
			return
		end
		local now = os.clock()
		if now - mergeTallyAt > MERGES_FRESH then
			mergeTally = 0
		end
		local count = math.max(1, math.floor(tonumber(data.count) or 1))
		mergeTally += count
		mergeTallyAt = now
		-- The batch for the float: every step of one action arrives in the same moment.
		local batch = mergeBatch
		if not batch then
			batch = { count = 0, startedAt = now, to = nil, manual = false, token = 0, gain = nil }
			mergeBatch = batch
		end
		batch.count += count
		batch.token += 1
		if typeof(data.to) == "Vector3" then
			batch.to = data.to
		end
		if data.auto ~= true then
			batch.manual = true
		end
		-- Every step of one action carries the same pair: what the whole action added.
		local before, after = tonumber(data.productionBefore), tonumber(data.productionAfter)
		if before and after then
			batch.gain = after - before
		end
		local token = batch.token
		task.delay(MERGE_SETTLE, function()
			if mergeBatch == batch and batch.token == token then
				mergeBatch = nil
				mergeFloat(batch)
			end
		end)
	end)
	State.changed.Event:Connect(noteProduction)
	noteProduction(State.data)
end

-- Floating text -------------------------------------------------------------------

-- "+$120" over the world: pops in, rises on a soft arc (steady sideways drift,
-- easing-out climb) and fades near the top. opts: life (seconds, 1.1), size (text, 30),
-- width (300), drift (false = straight up).
function Popups.float(text: string, color: Color3, anchor: UDim2, opts: { [string]: any }?)
	local o = opts or {}
	local life: number = o.life or 1.1
	local fadeAt = life - 0.4
	local mover = Kit.new("Frame", {
		Name = "Float",
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(o.width or 300, 44),
		Position = anchor,
		AnchorPoint = Vector2.new(0.5, 0.5),
		ZIndex = 20,
		Parent = screen,
	})
	local label = Kit.title(mover, {
		Name = "Text",
		Text = text,
		TextSize = o.size or 30,
		TextWrapped = false,
		Size = UDim2.fromScale(1, 1),
		TextColor3 = color,
		StrokeThickness = 0,
	})
	-- Over the 3D world: a solid navy outline.
	local outline = Kit.textStroke(label, 2.5, 0)
	local pop = Kit.new("UIScale", { Scale = 0.55, Parent = label })
	Kit.tween(pop, 0.28, { Scale = 1 }, Enum.EasingStyle.Back)
	local drift = if o.drift == false then 0 else math.random(-36, 36)
	Kit.tween(mover, life, { Position = anchor + UDim2.fromOffset(drift, 0) }, Enum.EasingStyle.Linear)
	Kit.tween(label, life, { Position = UDim2.fromOffset(0, -80) }, Enum.EasingStyle.Quad)
	tweenAfter(label, 0.4, fadeAt, { TextTransparency = 1 })
	tweenAfter(outline, 0.4, fadeAt, { Transparency = 1 })
	tweenAfter(pop, 0.4, fadeAt, { Scale = 0.85 })
	task.delay(life + 0.05, function()
		mover:Destroy()
	end)
end

-- Modal queue -------------------------------------------------------------------------
--[[
	One modal at a time: rewards, crate reveals, offline earnings, confirms and the
	tutorial completion card all go through here. Highest priority first, then
	arrival order. New arrivals wait a short "gather" window so cards that arrive
	together sort correctly, and the whole queue holds for 1 s after a Merge
	effect so the 3D fusion is seen before the reveal covers it.
]]

Popups.PRIORITY = { NewTier = 3, Tutorial = 2, Normal = 1 }
-- Per kind of card: what its caller takes back when `show` threw (its own "a card is open"
-- state). The queue runs it after closing what the card had built.
Popups.FAILED = {} :: { [string]: () -> () }
-- The modals open right now, and closing the ones opened since (set under `modal`, which
-- keeps the list): the queue takes down what a card that threw half-way left on screen.
Popups.modalsNow = function(): { [() -> ()]: boolean }
	return {}
end
Popups.closeModalsSince = function(_before: { [() -> ()]: boolean }) end

type Entry = {
	kind: string,
	priority: number,
	seq: number,
	readyAt: number,
	show: (done: () -> ()) -> (),
	data: { [string]: any }?,
}

local GATHER = 0.15
local MERGE_HOLD = 1.0
local CRATE_LINK = 0.6

local queue: { Entry } = {}
local busy = false
local seqCounter = 0
local holdUntil = 0
local pendingChest: { rarity: string, at: number }? = nil
-- os.clock() when the last modal closed (the Starter offer waits for a calm moment).
local lastModalAt = 0

local pump: () -> ()

local function schedule(delay: number)
	task.delay(math.max(delay, 0), pump)
end

-- ScreenGui attribute "PopupBusy": a queued card is waiting or up, or the free gift's card
-- is on screen. The Daily window and the "While you were away" card never open by
-- themselves meanwhile (a reveal can wait in the queue for as long as the merges go on,
-- much longer than the Daily window's own quiet time after a Reward notify).
Popups.giftUntil = 0
function Popups.syncBusy()
	if screen then
		screen:SetAttribute("PopupBusy", busy or #queue > 0 or os.clock() < Popups.giftUntil)
	end
end

pump = function()
	if busy or #queue == 0 then
		return
	end
	local now = os.clock()
	if now < holdUntil then
		schedule(holdUntil - now + 0.01)
		return
	end
	local best: number? = nil
	local soonest = math.huge
	for index, entry in queue do
		if entry.readyAt <= now then
			local current = if best then queue[best] else nil
			if not current or entry.priority > current.priority or (entry.priority == current.priority and entry.seq < current.seq) then
				best = index
			end
		else
			soonest = math.min(soonest, entry.readyAt)
		end
	end
	if not best then
		schedule(soonest - now + 0.01)
		return
	end
	local entry = table.remove(queue, best) :: Entry
	busy = true
	local finished = false
	local function done()
		if finished then
			return
		end
		finished = true
		busy = false
		lastModalAt = os.clock()
		Popups.syncBusy()
		schedule(0.05)
	end
	-- A card that throws half-way must not stay up: its modal, its dim and its Back entry
	-- (ModalOpen) go, the caller resets its own state (Popups.FAILED) and the queue moves on.
	local before = Popups.modalsNow()
	local ok, err = pcall(entry.show, done)
	if not ok then
		warn("[Popups] " .. entry.kind .. " failed: " .. tostring(err))
		Popups.closeModalsSince(before)
		local failed = Popups.FAILED[entry.kind]
		if failed then
			pcall(failed)
		end
		done()
	end
end

-- Queue a modal. `show(done)` builds it and must call `done()` once it closes. If it throws,
-- the queue closes what it built and runs Popups.FAILED[kind].
function Popups.enqueue(kind: string, priority: number, show: (done: () -> ()) -> (), data: { [string]: any }?)
	if PREVIEW then
		-- The preview captures right after the call: show it at once.
		local ok, err = pcall(show, function() end)
		if not ok then
			warn("[Popups] " .. kind .. " failed: " .. tostring(err))
			local failed = Popups.FAILED[kind]
			if failed then
				pcall(failed)
			end
		end
		return
	end
	seqCounter += 1
	table.insert(queue, {
		kind = kind,
		priority = priority,
		seq = seqCounter,
		readyAt = os.clock() + GATHER,
		show = show,
		data = data,
	})
	Popups.syncBusy()
	schedule(GATHER + 0.01)
end

--[[
	Finish cards (Popups.modeFinish, Popups.mogFinish). A card that is up is in
	Popups.finishCards under its own token, as its close function. Popups.closeFinish
	closes them all and drops the ones still waiting in the queue: Main calls it when a
	mode starts or stops (the card's mode is over, or another one has begun), and
	Popups.watchFinish when the player is back on their own plot (the Home button, or a
	walk home), so a card never stays up, with its dim and its blur, over another mode or
	the gym.
]]
Popups.finishCards = {} :: { [any]: () -> () }
function Popups.closeFinish()
	for i = #queue, 1, -1 do
		local kind = queue[i].kind
		if kind == "ModeFinish" or kind == "MogFinish" then
			table.remove(queue, i)
		end
	end
	for token, close in table.clone(Popups.finishCards) do
		Popups.finishCards[token] = nil
		close()
	end
	Popups.syncBusy()
end

-- The player's character stands on their own plot (its "Floor" slab, World.Shell).
function Popups.atHome(): boolean
	local data = State.data
	local map = Workspace:FindFirstChild("Map")
	local plot = if data and map and data.plotIndex then map:FindFirstChild("Plot" .. tostring(data.plotIndex)) else nil
	local floor = plot and plot:FindFirstChild("Floor", true)
	local character = Players.LocalPlayer.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not floor or not floor:IsA("BasePart") or not root or not root:IsA("BasePart") then
		return false
	end
	local at = floor.CFrame:PointToObjectSpace(root.Position)
	return math.abs(at.X) <= floor.Size.X / 2 and math.abs(at.Z) <= floor.Size.Z / 2 and at.Y > -8 and at.Y < 60
end

-- The finish card `token` just opened as `close`: it is closed with the others, and by
-- itself once the player is Home.
function Popups.watchFinish(token: any, close: () -> ())
	Popups.finishCards[token] = close
	if PREVIEW then
		return
	end
	task.spawn(function()
		while Popups.finishCards[token] do
			task.wait(0.25)
			if Popups.finishCards[token] and Popups.atHome() then
				Popups.closeFinish()
				return
			end
		end
	end)
end

-- Main calls this on every "Merge" effect.
function Popups.noteMerge()
	holdUntil = math.max(holdUntil, os.clock() + MERGE_HOLD)
end

-- Main calls this on "ChestOpen": tags the reward it produced so it plays the
-- crate reveal (the Reward notify usually arrives just before the effect).
function Popups.noteChestOpen(rarity: string?)
	local now = os.clock()
	for i = #queue, 1, -1 do
		local data = queue[i].data
		if queue[i].kind == "Reward" and data and now - data._at <= CRATE_LINK and not data.crateRarity then
			data.crate = true
			data.crateRarity = rarity
			return
		end
	end
	pendingChest = { rarity = rarity or "Common", at = now }
end

-- Shared modal pieces ------------------------------------------------------------------

--[[
	Dimmed, blurred modal: a moulded blue panel. The caller fills it, then calls
	Kit.appear(box). `close()` eases it out with Kit.disappear and calls
	`onClosed` once it is gone.
]]
-- Gamepad and keyboard "back" ------------------------------------------------------------------
--[[
	Every open overlay (modal, unit reveal, crate reveal) pushes a Back entry. B /
	Escape runs the top-most one (highest ZIndex, newest first); an entry with no
	`fn` swallows the press (nothing dismissable). The ScreenGui's ModalOpen
	attribute is true while any entry is up, so Windows leaves its own B / Escape
	alone underneath a modal.
]]
type Back = { z: number, seq: number, fn: (() -> ())? }
local backStack: { Back } = {}
local backSeq = 0
local BACK_ACTION = "PopupsBack"
local backBound = false
local runBack: () -> ()
local function syncModalFlag()
	local up = #backStack > 0
	if screen then
		screen:SetAttribute("ModalOpen", up)
	end
	if up == backBound or PREVIEW then
		return
	end
	backBound = up
	-- B / Escape bound (sunk, high priority) only while an overlay is up.
	pcall(function()
		if up then
			ContextActionService:BindActionAtPriority(BACK_ACTION, function(_, state)
				if state ~= Enum.UserInputState.Begin then
					return Enum.ContextActionResult.Pass
				end
				runBack()
				return Enum.ContextActionResult.Sink
			end, false, Enum.ContextActionPriority.High.Value + 10, Enum.KeyCode.ButtonB, Enum.KeyCode.Escape)
		else
			ContextActionService:UnbindAction(BACK_ACTION)
		end
	end)
end
local function pushBack(z: number, fn: (() -> ())?): Back
	backSeq += 1
	local entry: Back = { z = z, seq = backSeq, fn = fn }
	table.insert(backStack, entry)
	syncModalFlag()
	return entry
end
local function dropBack(entry: Back)
	local i = table.find(backStack, entry)
	if i then
		table.remove(backStack, i)
		syncModalFlag()
	end
end
local function topBack(): Back?
	local top: Back? = nil
	for _, entry in backStack do
		if not top or entry.z > top.z or (entry.z == top.z and entry.seq > top.seq) then
			top = entry
		end
	end
	return top
end

-- Runs the top-most overlay's back action (deferred, so Windows still sees ModalOpen
-- for this same press and leaves the window under the modal open).
runBack = function()
	local top = topBack()
	local fn = top and top.fn
	if fn then
		task.defer(fn)
	end
end

local function selectedNow(): GuiObject?
	local ok, selected = pcall(function()
		return GuiService.SelectedObject
	end)
	return if ok then selected else nil
end

-- Gamepad: once the caller has filled the card (next frame), select its FocusFirst
-- button, or its first button, and keep the selection inside it.
local function focusCard(card: GuiObject)
	if PREVIEW then
		return
	end
	task.defer(function()
		if card.Parent then
			Kit.confine(card)
			Kit.focus(card)
		end
	end)
end

-- Drops the selection out of a closing card and hands it back to what was selected
-- before it opened (a button in an open window), if that is still on screen.
local function release(card: GuiObject, previous: GuiObject?)
	if PREVIEW then
		return
	end
	Kit.unfocus(card)
	if previous and previous ~= card and previous.Visible and previous:IsDescendantOf(game) and not previous:IsDescendantOf(card) then
		local current = selectedNow()
		if current == nil or current == card or current:IsDescendantOf(card) then
			Kit.select(previous)
		end
	end
end

local modalCount = 0
local openModals: { [() -> ()]: boolean } = {}
local backOf: { [() -> ()]: Back } = {}
local function modal(name: string, size: Vector2, zindex: number, onBackdrop: (() -> ())?, onClosed: (() -> ())?): (Frame, () -> ())
	modalCount += 1
	local openKey = "Modal:" .. name .. modalCount
	-- The dim sits above everything under the card (windows are at ZIndex 10). Over an open
	-- window it goes deeper, so none of the window's text reads through the card's glass.
	local over = screen:GetAttribute("WindowOpen") == true
	local dim = Kit.backdrop(screen, zindex - 1)
	dim.Name = name .. "Backdrop"
	Kit.fadeBackdrop(dim, true, if over then 1 - Theme.Glass.DimOver else Kit.GLASS_DIM)
	Kit.setBlur(true)
	-- Centred holder (named `name`) that Kit.fit keeps on screen; it leaves
	-- room above for the medallion that overlaps the top edge.
	local holder = Kit.new("Frame", {
		Name = name,
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(size.X, size.Y + 96),
		Position = UDim2.fromScale(0.5, 0.5),
		AnchorPoint = Vector2.new(0.5, 0.5),
		ZIndex = zindex,
		Parent = screen,
	})
	Kit.fit(holder, screen, Vector2.new(size.X, size.Y + 96))
	Kit.markOpen(screen, openKey, true, holder)
	-- The card is a glass pane like the windows (over the blurred, dimmed world).
	local box = Kit.panel(holder, {
		Name = "Box",
		Glass = "body",
		Size = UDim2.fromOffset(size.X, size.Y),
		Position = UDim2.fromScale(0.5, 0.5),
		AnchorPoint = Vector2.new(0.5, 0.5),
		ZIndex = zindex,
	})
	local closed = false
	local previous = selectedNow()
	local back: Back? = nil
	local function close()
		if closed then
			return
		end
		closed = true
		openModals[close] = nil
		backOf[close] = nil
		if back then
			dropBack(back)
		end
		release(box, previous)
		Kit.setBlur(false)
		Kit.markOpen(screen, openKey, false)
		Kit.fadeBackdrop(dim, false)
		Kit.disappear(box, {
			onDone = function()
				holder:Destroy()
			end,
		})
		task.delay(0.3, function()
			dim:Destroy()
			if holder.Parent then
				holder:Destroy()
			end
		end)
		if onClosed then
			task.delay(0.15, onClosed)
		end
	end
	local function backdropTap()
		if onBackdrop then
			onBackdrop()
		end
		close()
	end
	dim.Activated:Connect(backdropTap)
	openModals[close] = true
	-- B / Escape acts like a backdrop tap unless the card overrides it (onBack).
	back = pushBack(zindex, backdropTap)
	backOf[close] = back :: Back
	focusCard(box)
	return box, close
end

-- Overrides what B / Escape does on the modal `close` belongs to (nil: ignore it).
local function onBack(close: () -> (), fn: (() -> ())?)
	local entry = backOf[close]
	if entry then
		entry.fn = fn
	end
end

-- Closes every open modal (Studio capture hook "UiPreview" = "close").
function Popups.closeModals()
	for close in openModals do
		close()
	end
end

-- For the queue (`pump`, declared above with the queue's own state).
Popups.modalsNow = function(): { [() -> ()]: boolean }
	return table.clone(openModals)
end
Popups.closeModalsSince = function(before: { [() -> ()]: boolean })
	for close in table.clone(openModals) do
		if not before[close] then
			close()
		end
	end
end

-- Round toy badge: a coloured face with a white rim on a darker lip, sitting
-- across the top edge of a modal. It draws above the pane's own chrome (the
-- highlight line shares the pane's ZIndex) on a collar in the body colour, so
-- the pane's edge and highlight stop cleanly at a ring round the badge.
local MEDAL_COLLAR = 8
local function medallion(parent: Instance, icon: string, color: Color3, size: number, position: UDim2): Frame
	local depth = math.max(math.floor(size * 0.06), 3)
	local medal = Kit.new("Frame", {
		Name = "Medal",
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(size, size),
		Position = position,
		AnchorPoint = Vector2.new(0.5, 0.5),
		ZIndex = math.max((if parent:IsA("GuiObject") then parent.ZIndex else 0) + 1, 3),
		Parent = parent,
	})
	local collar = circle(medal, "Collar", WHITE, 0, 0)
	collar.Size = UDim2.new(1, MEDAL_COLLAR * 2, 1, MEDAL_COLLAR * 2 + depth)
	collar.Position = UDim2.new(0.5, 0, 0.5, depth / 2)
	Kit.gradient(collar, Theme.Glass.TintTop, Theme.Glass.Tint)
	Kit.new("UIStroke", {
		Thickness = Theme.Glass.EdgeThickness,
		Color = Theme.Glass.Edge,
		Transparency = Theme.Glass.EdgeTop + 0.25,
		Parent = collar,
	})
	local shadow = circle(medal, "Shadow", C.Ink, 0.72, 1)
	shadow.Size = UDim2.fromScale(0.92, 0.92)
	shadow.Position = UDim2.new(0.5, 0, 0.5, depth + 5)
	local base = circle(medal, "Base", Kit.lip(color), 0, 2)
	base.Size = UDim2.fromScale(1, 1)
	base.Position = UDim2.new(0.5, 0, 0.5, depth)
	local face = circle(medal, "Face", WHITE, 0, 3)
	face.Size = UDim2.fromScale(1, 1)
	Kit.gradient(face, Kit.lighten(color, 0.3), color)
	Kit.new("UIStroke", { Thickness = 3, Color = WHITE, Transparency = 0.1, Parent = face })
	local gloss = circle(face, "Gloss", WHITE, 0.6, 4)
	gloss.Size = UDim2.fromScale(0.36, 0.2)
	gloss.Position = UDim2.fromScale(0.36, 0.22)
	gloss.Rotation = -20
	local ink = Kit.inkOn(color)
	local iconName = Kit.iconName(icon)
	if iconName then
		Kit.icon(face, iconName, math.floor(size * 0.56), ink, {
			Position = UDim2.fromScale(0.5, 0.5),
			AnchorPoint = Vector2.new(0.5, 0.5),
			ZIndex = 5,
		})
	else
		Kit.title(face, {
			Text = icon,
			TextSize = math.floor(size * 0.52),
			TextColor3 = ink,
			Size = UDim2.fromScale(1, 1),
			Position = UDim2.fromOffset(0, 2),
			StrokeThickness = 0,
			ZIndex = 5,
		})
	end
	return medal
end

--[[
	Soft light rays behind something celebratory: wide bars that fade toward
	both ends, turning slowly with one repeating tween. `reverse` spins the
	other way (for a counter-layer).
]]
function Popups.rays(
	parent: Instance,
	color: Color3,
	size: number,
	position: UDim2,
	zindex: number?,
	count: number?,
	reverse: boolean?
): Frame
	local holder = Kit.new("Frame", {
		Name = "Rays",
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(size, size),
		Position = position,
		AnchorPoint = Vector2.new(0.5, 0.5),
		ZIndex = zindex or 1,
		Parent = parent,
	})
	local n = count or 6
	local fade = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(0.32, 0.35),
		NumberSequenceKeypoint.new(0.5, 0.1),
		NumberSequenceKeypoint.new(0.68, 0.35),
		NumberSequenceKeypoint.new(1, 1),
	})
	for i = 0, n - 1 do
		local ray = Kit.new("Frame", {
			Name = "Ray",
			BackgroundColor3 = color,
			BackgroundTransparency = 0.72,
			BorderSizePixel = 0,
			Size = UDim2.new(0, 36, 1, 0),
			Position = UDim2.fromScale(0.5, 0.5),
			AnchorPoint = Vector2.new(0.5, 0.5),
			Rotation = i * (180 / n),
			ZIndex = zindex or 1,
			Parent = holder,
		})
		Kit.round(ray)
		Kit.new("UIGradient", { Rotation = 90, Transparency = fade, Parent = ray })
	end
	if not PREVIEW then
		local info = TweenInfo.new(22, Enum.EasingStyle.Linear, Enum.EasingDirection.InOut, -1)
		TweenService:Create(holder, info, { Rotation = if reverse then -360 else 360 }):Play()
	end
	return holder
end

-- Atlas crate art per crate rarity (Mythic shares the Legendary crate).
local CRATE_ART: { [string]: string } = {
	Common = "CrateCommon",
	Uncommon = "CrateUncommon",
	Rare = "CrateRare",
	Epic = "CrateEpic",
	Legendary = "CrateLegendary",
	Mythic = "CrateLegendary",
}

--[[
	A chunky toy crate: the rarity's atlas art when props.Rarity is given and
	the art loaded, else drawn from frames: a rounded box in `color` (lighter at
	the top) on a darker lip, a lid band, two straps and a sunny clasp.
]]
function crateIcon(parent: Instance, color: Color3, size: number, props: { [string]: any }?): Frame
	local p = props or {}
	-- The Blender crate for this rarity from the icon atlas (p.Rarity), drawn a
	-- little larger since the art has its own padding.
	local art = p.Rarity and CRATE_ART[p.Rarity]
	if art and Kit.hasImageIcon(art) then
		return Kit.icon(parent, art, math.floor(size * 1.15), nil, {
			Name = p.Name or "Crate",
			Position = p.Position or UDim2.new(),
			AnchorPoint = p.AnchorPoint or Vector2.zero,
			ZIndex = p.ZIndex or 1,
		})
	end
	local root = Kit.new("Frame", {
		Name = p.Name or "Crate",
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(size, size),
		Position = p.Position or UDim2.new(),
		AnchorPoint = p.AnchorPoint or Vector2.zero,
		ZIndex = p.ZIndex or 1,
		Parent = parent,
	})
	local lipColor = Kit.lip(color)
	local r = math.max(math.floor(size * 0.12), 6)
	local depth = math.max(math.floor(size * 0.05), 3)
	-- `round` = pill corners instead of the crate radius.
	local function part(name: string, z: number, props2: { [string]: any }, round: boolean?): Frame
		props2.Name = name
		props2.BorderSizePixel = 0
		props2.ZIndex = z
		props2.Parent = root
		local frame = Kit.new("Frame", props2)
		if round then
			Kit.round(frame)
		else
			Kit.corner(frame, r)
		end
		return frame
	end
	part("Shadow", 1, {
		BackgroundColor3 = C.Ink,
		BackgroundTransparency = 0.72,
		Size = UDim2.fromScale(0.86, 0.12),
		Position = UDim2.fromScale(0.5, 0.93),
		AnchorPoint = Vector2.new(0.5, 0.5),
	}, true)
	part("Base", 2, {
		BackgroundColor3 = lipColor,
		Size = UDim2.fromScale(0.8, 0.6),
		Position = UDim2.fromScale(0.5, 0.92),
		AnchorPoint = Vector2.new(0.5, 1),
	})
	local body = part("Body", 3, {
		BackgroundColor3 = WHITE,
		Size = UDim2.new(0.8, 0, 0.6, -depth),
		Position = UDim2.new(0.5, 0, 0.92, -depth),
		AnchorPoint = Vector2.new(0.5, 1),
	})
	Kit.gradient(body, Kit.lighten(color, 0.3), color)
	Kit.stroke(body, 2, lipColor)
	for _, x in { 0.28, 0.72 } do
		part("Strap", 4, {
			BackgroundColor3 = Kit.lighten(color, 0.55),
			BackgroundTransparency = 0.25,
			Size = UDim2.new(0.09, 0, 0.6, -depth - 6),
			Position = UDim2.new(x, 0, 0.92, -depth - 3),
			AnchorPoint = Vector2.new(0.5, 1),
		})
	end
	part("LidLip", 5, {
		BackgroundColor3 = lipColor,
		Size = UDim2.fromScale(0.92, 0.22),
		Position = UDim2.new(0.5, 0, 0.2, depth),
		AnchorPoint = Vector2.new(0.5, 0),
	})
	local lid = part("Lid", 6, {
		BackgroundColor3 = WHITE,
		Size = UDim2.fromScale(0.92, 0.22),
		Position = UDim2.fromScale(0.5, 0.2),
		AnchorPoint = Vector2.new(0.5, 0),
	})
	Kit.gradient(lid, Kit.lighten(color, 0.42), Kit.lighten(color, 0.08))
	Kit.stroke(lid, 2, lipColor)
	part("Highlight", 7, {
		BackgroundColor3 = WHITE,
		BackgroundTransparency = 0.45,
		Size = UDim2.new(0.7, 0, 0, math.max(math.floor(size * 0.025), 2)),
		Position = UDim2.new(0.5, 0, 0.2, 3),
		AnchorPoint = Vector2.new(0.5, 0),
	}, true)
	local clasp = part("Clasp", 8, {
		BackgroundColor3 = WHITE,
		Size = UDim2.fromScale(0.22, 0.2),
		Position = UDim2.fromScale(0.5, 0.42),
		AnchorPoint = Vector2.new(0.5, 0.5),
	})
	Kit.gradient(clasp, C.GoldLight, C.Gold)
	Kit.stroke(clasp, 2, C.GoldDeep)
	return root
end

-- Discovery reveal -----------------------------------------------------------------------

local RARITY_RANK = { Common = 1, Uncommon = 2, Rare = 3, Epic = 4, Legendary = 5, Mythic = 6 }

-- Other tiers discovered by the same action (payload.tiers minus the headline
-- tier), highest first.
local function extraTiers(reward: { [string]: any }): { number }
	local extras = {}
	if type(reward.tiers) == "table" then
		for _, t in reward.tiers do
			if type(t) == "number" and t ~= reward.tier and Theme.Tiers[t] and not table.find(extras, t) then
				table.insert(extras, t)
			end
		end
	end
	table.sort(extras, function(a, b)
		return a > b
	end)
	return extras
end

local SOFT_DOT = Sprites.image("SoftDot")
local SPARKLE = Sprites.image("Sparkle")
local RING = Sprites.image("Ring")

-- Stage layout (design px; Kit.fit shrinks the whole stage on small screens).
local STAGE_W = 620
local HERO = 350
-- The unit's viewport is drawn this much larger than its box (Kit.unitViewport leaves a
-- margin round the unit), so the unit itself fills the box: about half the screen's height.
local HERO_ZOOM = 1.22
local HERO_PUSH = 0.3 -- the viewport's camera starts this much further back and pushes in
local EXTRAS_H = 66
local EXTRA_SLOTS = 5
local VEIL = Kit.darken(C.Ink, 0.4)

-- Timing (seconds). A discovery stays until it is dismissed (REVEAL_IDLE is only there so
-- a player who is away is not left behind the veil); the ones before it in a chain, and a
-- unit that is not new, leave by themselves.
local REVEAL_MIN = 0.35 -- an earlier tap waits until the unit has popped in
local REVEAL_HOLD = 1.9 -- entrance (0.3) + hold (1.6) before a unit that is not new leaves
local REVEAL_CHAIN = 1.6 -- each discovery of a chain but the last
local REVEAL_IDLE = 10 -- the last (or only) discovery, if nobody taps
local REVEAL_QUEUED = 3 -- the same discovery once another card waits behind it ("YOU DID IT!")
local CHAIN_MAX = 6 -- reveals in a row; older tiers of a bigger jump ride on the last one
local REVEAL_HOLD_TUTORIAL = 1.3 -- shorter while the tutorial is pointing somewhere
local REVEAL_HINT = 1.0 -- "tap to continue" only shows this late
local ORB_MORPH = 0.14 -- the unit shrinks into an orb
local ORB_FLIGHT = 0.46 -- the orb's arc to the Index button
local ORB_STAGGER = 0.07 -- between the orbs of a multi-discovery

local function reducedMotion(): boolean
	local data = State.data
	return data ~= nil and type(data.settings) == "table" and data.settings.reducedMotion == true
end

-- A soft round light centred in `parent`: the SoftDot sprite tinted `color` (a
-- round frame when the sprite is missing). Returns it and the property that fades it.
local function softDot(
	parent: Instance,
	name: string,
	color: Color3,
	size: UDim2,
	transparency: number,
	zindex: number
): (GuiObject, string)
	if SOFT_DOT then
		local image = Kit.new("ImageLabel", {
			Name = name,
			BackgroundTransparency = 1,
			Image = SOFT_DOT,
			ImageColor3 = color,
			ImageTransparency = transparency,
			Size = size,
			Position = UDim2.fromScale(0.5, 0.5),
			AnchorPoint = Vector2.new(0.5, 0.5),
			ZIndex = zindex,
			Parent = parent,
		})
		return image, "ImageTransparency"
	end
	local dot = circle(parent, name, color, 1 - (1 - transparency) * 0.5, zindex)
	dot.Size = size
	return dot, "BackgroundTransparency"
end

-- Sparkles scattered on a ring of `radius` around the centre of `parent`, twinkling
-- (one repeating tween each, out of phase) unless `still`.
local function sparkles(parent: Instance, color: Color3, count: number, radius: number, still: boolean)
	if not SPARKLE then
		return
	end
	for i = 1, count do
		local angle = (i + math.random() * 0.6) / count * math.pi * 2
		local reach = radius * (0.74 + math.random() * 0.4)
		local size = math.random(18, 36)
		local star = Kit.new("ImageLabel", {
			Name = "Sparkle",
			BackgroundTransparency = 1,
			Image = SPARKLE,
			ImageColor3 = if i % 3 == 0 then color else WHITE,
			ImageTransparency = 0.05,
			Size = UDim2.fromOffset(size, size),
			Position = UDim2.new(0.5, math.cos(angle) * reach, 0.5, math.sin(angle) * reach * 0.92),
			AnchorPoint = Vector2.new(0.5, 0.5),
			Rotation = math.random(-20, 20),
			Parent = parent,
		})
		if not still and not PREVIEW then
			-- Size and rotation only: the group's fade (Kit.appear) owns the transparency.
			local info =
				TweenInfo.new(0.45 + math.random() * 0.5, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true, math.random() * 0.4)
			TweenService:Create(star, info, { Size = UDim2.fromOffset(size * 0.3, size * 0.3), Rotation = star.Rotation + 50 }):Play()
		end
	end
end

-- Width of one line of Display text (TextService when available, else an estimate).
local function displayWidth(text: string, size: number): number
	local width = 0
	pcall(function()
		local TextService = game:GetService("TextService")
		width = TextService:GetTextSize(text, size, Theme.Fonts.Display, Vector2.new(1000, 60)).X
	end)
	if width <= 0 then
		width = (utf8.len(text) or #text) * size * 0.58
	end
	return math.ceil(width)
end

-- One stat on the reveal: an icon and an outlined number, no box. `final` (the
-- text it ends on) sizes the pair, so a rolling number does not shake the row.
local function statPair(
	parent: Instance,
	icon: string,
	iconColor: Color3,
	final: string,
	color: Color3,
	order: number,
	size: number
): TextLabel
	local width = displayWidth(final, size) + 6
	local pair = Kit.new("Frame", {
		Name = "Stat" .. order,
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(36 + width, size + 8),
		LayoutOrder = order,
		Parent = parent,
	})
	Kit.hudIcon(pair, icon, 30, iconColor, {
		Position = UDim2.new(0, 0, 0.5, 0),
		AnchorPoint = Vector2.new(0, 0.5),
		ZIndex = 2,
	})
	return Kit.hudText(pair, {
		Name = "Value",
		Text = final,
		TextSize = size,
		Size = UDim2.new(0, width, 1, 0),
		Position = UDim2.fromOffset(36, 1),
		TextXAlignment = Enum.TextXAlignment.Left,
		TextColor3 = color,
		StrokeColor = Theme.Glass.TextInk,
		StrokeThickness = 3,
		ZIndex = 2,
	})
end

type Portrait = { gui: GuiObject, color: Color3 }

-- The other units the same action discovered: small frameless portraits in a row
-- at `y`, popping in one by one from `start` seconds (past EXTRA_SLOTS, a "+N").
-- Returns the portraits, which fly to the Index after the hero.
local function extrasRow(stage: Frame, extras: { number }, y: number, start: number, alive: () -> boolean): { Portrait }
	local row = Kit.new("Frame", {
		Name = "MoreNew",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, EXTRAS_H - 6),
		Position = UDim2.fromOffset(0, y),
		ZIndex = 5,
		Parent = stage,
	})
	Kit.list(row, 4, true, Enum.HorizontalAlignment.Center)
	local portraits: { Portrait } = {}
	local shown = if #extras > EXTRA_SLOTS then EXTRA_SLOTS - 1 else #extras
	local function slot(order: number): Frame
		return Kit.new("Frame", {
			Name = "Slot" .. order,
			BackgroundTransparency = 1,
			Size = UDim2.fromOffset(EXTRAS_H - 6, EXTRAS_H - 6),
			LayoutOrder = order,
			Parent = row,
		})
	end
	for i = 1, shown do
		local t = extras[i]
		local tierColor = C.Rarity[Economy.tierBand(t)] or C.Gold
		local frame = slot(i)
		softDot(frame, "Glow", Kit.lighten(tierColor, 0.25), UDim2.fromScale(1.3, 1.3), 0.3, 1)
		Kit.unitViewport(frame, t, { Size = UDim2.fromScale(1, 1) }).ZIndex = 2
		local at = start + i * 0.08
		Kit.appear(frame, { from = 0.3, time = 0.3, delay = at })
		after(at, function()
			if alive() then
				sounds.play("Tick", 0.03, 1 + i * 0.08)
			end
		end)
		table.insert(portraits, { gui = frame, color = tierColor })
	end
	if shown < #extras then
		local frame = slot(EXTRA_SLOTS)
		Kit.hudText(frame, { Text = "+" .. (#extras - shown), TextSize = 26, TextColor3 = C.Gold })
		Kit.appear(frame, { from = 0.3, time = 0.3, delay = start + EXTRA_SLOTS * 0.08 })
	end
	return portraits
end

--[[
	A glowing orb of `color` flies from `from` to `goal` (design px inside
	`layer`) along an arc that swings upward first: it swells out of nothing,
	speeds up and shrinks on the way, and sheds a short trail of fading dots and
	sparkles. `onLand` runs when it arrives.
]]
local function flyOrb(layer: Frame, from: Vector2, goal: Vector2, color: Color3, size: number, onLand: () -> ())
	local orb = Kit.new("Frame", {
		Name = "Orb",
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(size, size),
		Position = UDim2.fromOffset(from.X, from.Y),
		AnchorPoint = Vector2.new(0.5, 0.5),
		ZIndex = 8,
		Parent = layer,
	})
	-- A ball in the rarity colour (lighter on top, a light rim and a small highlight) in a
	-- wide glow of the same colour: it reads as the unit's orb, not as a white spark.
	local tint = Kit.lighten(color, 0.3)
	softDot(orb, "Glow", color, UDim2.fromScale(2.1, 2.1), 0.25, 1)
	local ball = circle(orb, "Ball", WHITE, 0, 2)
	ball.Size = UDim2.fromScale(0.62, 0.62)
	Kit.gradient(ball, Kit.lighten(color, 0.45), color)
	Kit.new("UIStroke", { Thickness = 3, Color = Kit.lighten(color, 0.7), Parent = ball })
	local glint = circle(ball, "Glint", WHITE, 0.15, 3)
	glint.Size = UDim2.fromScale(0.3, 0.3)
	glint.Position = UDim2.fromScale(0.32, 0.3)
	local scale = Kit.new("UIScale", { Scale = 0.2, Parent = orb })
	Kit.tween(scale, ORB_MORPH, { Scale = 1 }, Enum.EasingStyle.Back)

	local span = goal - from
	local normal = Vector2.new(span.Y, -span.X)
	if normal.Y > 0 then
		normal = -normal
	end
	local lift = if normal.Magnitude > 1 then normal.Unit * math.min(span.Magnitude * 0.4, 240) else Vector2.new(0, -80)
	local control = from + span * 0.3 + lift

	local started = os.clock() + ORB_MORPH
	local shedAt = from
	local shed = 0
	local conn: RBXScriptConnection
	conn = RunService.RenderStepped:Connect(function()
		if not layer.Parent then
			conn:Disconnect()
			return
		end
		local u = math.clamp((os.clock() - started) / ORB_FLIGHT, 0, 1)
		local eased = u * u
		local point = from:Lerp(control, eased):Lerp(control:Lerp(goal, eased), eased)
		orb.Position = UDim2.fromOffset(point.X, point.Y)
		if u > 0 then
			scale.Scale = 1 - 0.5 * eased
		end
		if (point - shedAt).Magnitude >= 14 then
			-- Trail: a dot of the orb's colour left behind that shrinks away (every fourth
			-- one a sparkle). Short: each lasts 0.3 s.
			shedAt = point
			shed += 1
			local side = size * (0.8 - 0.35 * eased)
			local ghost, fade = softDot(layer, "Trail", tint, UDim2.fromOffset(side, side), 0.15, 7)
			if SPARKLE and shed % 4 == 0 and ghost:IsA("ImageLabel") then
				ghost.Image = SPARKLE
				ghost.ImageColor3 = WHITE
			end
			ghost.Position = UDim2.fromOffset(point.X + math.random(-5, 5), point.Y + math.random(-5, 5))
			Kit.tween(ghost, 0.3, { Size = UDim2.fromOffset(side * 0.2, side * 0.2), [fade] = 1 })
			task.delay(0.32, function()
				ghost:Destroy()
			end)
		end
		if u >= 1 then
			conn:Disconnect()
			orb:Destroy()
			onLand()
		end
	end)
end

--[[
	The reveal has no card and no button. The world stays in view under a soft
	navy veil and a short blur, the HUD steps aside, and the unit floats in the
	middle of the screen on turning rays and a glow in its rarity colour, bobbing
	and swaying. It lands with a pop, a white bloom and (from Rare up) a ring;
	rarer units land harder. The text sits straight on the world in the HUD's
	outlined style and arrives a line at a time: label, name, tier, stats, then
	any other units the same action discovered.

	The rarity band (Economy.tierBand) colours it all: rays, glow, the plate behind
	the name, the confetti and a thin wash over the whole screen; rarer bands turn
	it up, and from Epic the landing comes with a short white flash and the longer
	fanfare. The unit fills about half the screen's height and its camera pushes in.
	Under the name, "+X Aura/sec" counts up: what the action added (reward.gain).

	A new discovery then leaves for the Index. On any tap, click, A, B or Escape
	(or after REVEAL_IDLE), input is free again, the HUD slides back and the unit
	shrinks into an orb that flies into the Index button (Hud.indexPoint), which
	bounces and counts it (Hud.punchIndex); the other units follow one by one.
	With no button to land on (a window is open, the menu is hidden) the orbs
	leave by the top-left corner. A unit that is not new, and any unit under the
	reduced-motion setting, just fades where it stands.

	In a chain (revealChain) every reveal but the last has reward._next: it holds
	REVEAL_CHAIN, starts the next one as it leaves (so the veil, the blur and the
	"RevealOpen" attribute never drop in between) and fades quickly without an orb.
]]
local function showReveal(reward: { [string]: any }, done: () -> ())
	local tier = reward.tier
	local band = Economy.tierBand(tier)
	local color = C.Rarity[band] or C.Gold
	local rank = RARITY_RANK[band] or 1
	local isNew = reward.new == true
	local extras = if isNew then extraTiers(reward) else {}
	local calm = reducedMotion()
	local data = State.data
	local nextReveal: (() -> ())? = if type(reward._next) == "function" then reward._next else nil
	local chained = nextReveal ~= nil
	local gain: number? = if type(reward.gain) == "number" and reward.gain > 0 then reward.gain else nil
	-- A merge batch brought this discovery: its "xN MERGES!" line gets a row under the
	-- stats (the text itself may still be on its way: Fx.Shelf floats it at the last pop).
	-- In a chain it waits for the last reveal, judged from when the chain started.
	local now = if type(reward._startedAt) == "number" then reward._startedAt else os.clock()
	local mergesSeen: string? = if isNew and not chained and now - mergesAt < MERGES_FRESH then mergesText else nil
	local mergesRow = isNew and not chained and (mergesSeen ~= nil or (now - mergeTallyAt < MERGES_FRESH and mergeTally >= MERGES_MIN))
	if not chained then
		mergesAt, mergeTally = 0, 0
	end
	-- Text sizes held on the glass: a phone's UI scale would take the 30 px label to 19 and
	-- the 22 px tier line to 14. What the text gains the unit gives up, so the stage keeps
	-- its height (and Kit.fit does not shrink it all again).
	-- Kit.fit may still scale the stage a little (a short screen): the sizes count that in.
	local area = Kit.designArea(screen)
	local share = if Kit.touch then Theme.Glass.FitTouch else Theme.Glass.Fit
	local stageBase = 204 + HERO + (if #extras > 0 then EXTRAS_H else 0) + (if mergesRow then 32 else 0) + (if gain then 38 else 0)
	local fit = if area then math.min(1, area.X * share / STAGE_W, area.Y * share / stageBase) else 1
	local bannerSize = Kit.px(28 / fit, 38, screen)
	local nameSize = Kit.px(30 / fit, 48, screen)
	local gainSize = Kit.px(20 / fit, 30, screen)
	local tierSize = Kit.px(18 / fit, 22, screen)
	local statSize = Kit.px(18 / fit, 26, screen)
	local heroSize =
		math.max(HERO - (bannerSize - 38) - (nameSize - 48) - (tierSize - 22) - (statSize - 26) - (if gain then gainSize - 30 else 0), 200)
	local heroY = bannerSize + 6 + heroSize / 2
	local nameY = heroY + heroSize / 2
	local gainY = nameY + nameSize + 6
	local tierY = (if gain then gainY + gainSize + 2 else nameY + nameSize) + 8
	local statsY = tierY + tierSize + 12
	local mergesY = statsY + statSize + 10
	local stageH = statsY + statSize + 8 + (if mergesRow then tierSize + 10 else 0) + 36
	local height = stageH + (if #extras > 0 then EXTRAS_H else 0)

	-- Toasts and the tutorial pill step out (setReveal); the veil below hides an open window.
	local openKey = "Reward:" .. tostring(os.clock())
	setReveal(true)
	-- The lighter frost, under a dark veil.
	Kit.setBlur(true, true)

	local root = Kit.new("Frame", {
		Name = "Reward",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		ZIndex = 30,
		Parent = screen,
	})
	-- Veil: navy, about 80 % across the middle band and a little thinner toward the edges, so
	-- the unit and its name stand on a dark stage whatever the plot shows behind them.
	local veil = Kit.new("Frame", {
		Name = "Dim",
		BackgroundColor3 = VEIL,
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Size = UDim2.new(3, 0, 1, 400),
		Position = UDim2.fromScale(0.5, 0.5),
		AnchorPoint = Vector2.new(0.5, 0.5),
		ZIndex = 0,
		Parent = root,
	})
	do
		-- An open window (the Shop, the Daily window, the Index) is hidden for as long as the
		-- reveal or its chain plays: over one the veil is solid, also when the window opens
		-- half-way through, and the window is back as the veil lifts. Nothing of it reads
		-- through behind the unit.
		local gradient = Kit.new("UIGradient", { Rotation = 90, Parent = veil })
		local function paint()
			gradient.Transparency = if Windows.isAnyOpen()
				then NumberSequence.new(0)
				else NumberSequence.new({
					NumberSequenceKeypoint.new(0, 0.3),
					NumberSequenceKeypoint.new(0.3, 0.2),
					NumberSequenceKeypoint.new(0.8, 0.18),
					NumberSequenceKeypoint.new(1, 0.26),
				})
		end
		paint()
		if not PREVIEW then
			local watch: RBXScriptConnection
			watch = Windows.changed.Event:Connect(function()
				if root:IsDescendantOf(game) then
					paint()
				else
					watch:Disconnect()
				end
			end)
		end
	end
	-- The count behind WindowOpen is given back if the reveal's gui is destroyed.
	Kit.markOpen(screen, openKey, true, root)
	Kit.tween(veil, 0.25, { BackgroundTransparency = 0 })
	-- A thin wash of the rarity colour over the whole screen, stronger for rarer bands.
	local wash = Kit.new("Frame", {
		Name = "Wash",
		BackgroundColor3 = color,
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Size = UDim2.new(3, 0, 1, 400),
		Position = UDim2.fromScale(0.5, 0.5),
		AnchorPoint = Vector2.new(0.5, 0.5),
		ZIndex = 0,
		Parent = root,
	})
	Kit.tween(wash, 0.3, { BackgroundTransparency = 0.9 - 0.022 * rank })

	-- The stage sits a little lower while the tutorial card holds the top centre.
	local topCard = screen:GetAttribute("TopCardHeight")
	local shift = if type(topCard) == "number" and screen:GetAttribute("Compact") ~= true then math.min(topCard / 2, 40) else 0
	local stage = Kit.new("Frame", {
		Name = "Stage",
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(STAGE_W, height),
		Position = UDim2.new(0.5, 0, 0.5, shift),
		AnchorPoint = Vector2.new(0.5, 0.5),
		ZIndex = 1,
		Parent = root,
	})
	Kit.fit(stage, screen, Vector2.new(STAGE_W, height))
	local heroAt = UDim2.new(0.5, 0, 0, heroY)

	-- Light behind the unit: a navy pool for contrast, rays, and the rarity glow.
	local lights: { GuiObject } = {}
	if SOFT_DOT then
		local pool = softDot(stage, "Pool", VEIL, UDim2.fromOffset(980, 760), 0.8, 0)
		pool.Position = UDim2.new(0.5, 0, 0, heroY + 70)
		table.insert(lights, pool)
	end
	local rays = Popups.rays(stage, Kit.lighten(color, 0.12), 640 + rank * 28, heroAt, 1, 6 + rank)
	Kit.appear(rays, { from = 0.3, time = 0.5, style = Enum.EasingStyle.Quart })
	table.insert(lights, rays)
	if isNew then
		-- A lighter counter-layer turning the other way for a fresh discovery (white from Epic).
		local inner = Popups.rays(stage, if rank >= 4 then WHITE else Kit.lighten(color, 0.6), 470, heroAt, 1, 9, true)
		Kit.appear(inner, { from = 0.3, time = 0.55, style = Enum.EasingStyle.Quart })
		table.insert(lights, inner)
	end
	local glow = softDot(stage, "Glow", Kit.lighten(color, 0.2), UDim2.fromOffset(heroSize * 1.45, heroSize * 1.45), 0.3, 2)
	glow.Position = heroAt
	Kit.appear(glow, { from = 0.4, time = 0.4 })
	table.insert(lights, glow)

	-- The unit: frameless, popping in with an overshoot.
	local hero = Kit.new("Frame", {
		Name = "Hero",
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(heroSize, heroSize),
		Position = heroAt,
		AnchorPoint = Vector2.new(0.5, 0.5),
		ZIndex = 3,
		Parent = stage,
	})
	local viewport = Kit.unitViewport(hero, tier, {
		Size = UDim2.fromScale(HERO_ZOOM, HERO_ZOOM),
		Position = UDim2.fromScale(0.5, 0.5),
		AnchorPoint = Vector2.new(0.5, 0.5),
	})
	Kit.appear(hero, { from = 0.15, time = 0.4 + 0.02 * rank })
	local lens = viewport.CurrentCamera
	if lens and not calm and not PREVIEW then
		-- Camera push: from a little further back, in onto the unit.
		local rest = lens.CFrame
		lens.CFrame = rest * CFrame.new(0, 0, rest.Position.Magnitude * HERO_PUSH)
		Kit.tween(lens, 0.6, { CFrame = rest }, Enum.EasingStyle.Quart)
	end
	local twinkle = Kit.new("Frame", {
		Name = "Sparkles",
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(heroSize, heroSize),
		Position = heroAt,
		AnchorPoint = Vector2.new(0.5, 0.5),
		ZIndex = 4,
		Parent = stage,
	})
	sparkles(twinkle, Kit.lighten(color, 0.4), 5 + rank * 2, heroSize * 0.5, calm)
	Kit.appear(twinkle, { from = 0.5, time = 0.4, delay = 0.1 })
	table.insert(lights, twinkle)

	if not calm and not PREVIEW then
		-- A soft white bloom behind the pop (no full-screen flash), bigger for rarer units.
		local bloom, fade = softDot(stage, "Bloom", WHITE, UDim2.fromOffset(heroSize * 0.7, heroSize * 0.7), 0.05, 4)
		bloom.Position = heroAt
		local reach = heroSize * (1.5 + 0.2 * rank)
		Kit.tween(bloom, 0.34, { Size = UDim2.fromOffset(reach, reach), [fade] = 1 }, Enum.EasingStyle.Quart)
		task.delay(0.36, function()
			bloom:Destroy()
		end)
		-- Rare and up: a ring spreads from the landing; Legendary and up, a second one.
		local rings = if not RING or rank < 3 then 0 elseif rank >= 5 then 2 else 1
		for i = 1, rings do
			local ring = Kit.new("ImageLabel", {
				Name = "Ring",
				BackgroundTransparency = 1,
				Image = RING,
				ImageColor3 = if i == 1 then WHITE else Kit.lighten(color, 0.4),
				ImageTransparency = 0.1,
				Size = UDim2.fromOffset(heroSize * 0.5, heroSize * 0.5),
				Position = heroAt,
				AnchorPoint = Vector2.new(0.5, 0.5),
				ZIndex = 2,
				Visible = false,
				Parent = stage,
			})
			local spread = heroSize * (1.3 + 0.2 * rank)
			task.delay(0.1 + (i - 1) * 0.14, function()
				ring.Visible = true
				Kit.tween(ring, 0.55, { Size = UDim2.fromOffset(spread, spread), ImageTransparency = 1 }, Enum.EasingStyle.Quart)
				task.delay(0.6, function()
					ring:Destroy()
				end)
			end)
		end
		-- Epic and up land with a second bump, and a short white flash over the screen.
		if rank >= 4 then
			task.delay(0.5 + 0.02 * rank, function()
				if hero.Parent then
					Kit.pop(hero, 0.3 * (rank - 2))
				end
			end)
			if isNew then
				local flash = Kit.new("Frame", {
					Name = "Flash",
					BackgroundColor3 = WHITE,
					BackgroundTransparency = 0.5 - 0.06 * (rank - 4),
					BorderSizePixel = 0,
					Size = UDim2.new(3, 0, 1, 400),
					Position = UDim2.fromScale(0.5, 0.5),
					AnchorPoint = Vector2.new(0.5, 0.5),
					ZIndex = 9,
					Parent = root,
				})
				Kit.tween(flash, 0.3 + 0.05 * (rank - 4), { BackgroundTransparency = 1 }, Enum.EasingStyle.Quad)
				task.delay(0.45, function()
					flash:Destroy()
				end)
			end
		end
	end
	if isNew and not calm then
		-- Confetti in the band's colour (its shades and white), more of it for rarer bands.
		Kit.confetti(stage, {
			Origin = heroAt,
			Count = 12 + rank * 5,
			ZIndex = 4,
			Colors = { color, Kit.lighten(color, 0.35), WHITE, color, Kit.darken(color, 0.18), Kit.lighten(color, 0.6) },
			Power = 0.95 + 0.08 * rank,
		})
	end

	if isNew then
		-- The same fanfares, pitched by band: brighter for the common ones; from Epic the
		-- longer one, deeper (and so longer still) toward Mythic.
		if rank >= 4 then
			sounds.play("CelebrateLegendary", 0, if rank == 4 then 1.08 elseif rank >= 6 then 0.92 else 1)
		else
			sounds.play("Celebrate", 0, 1.1 - 0.05 * (rank - 1))
		end
	elseif not reward._sounded then
		-- The crate reveal already played "Reward" when it landed.
		sounds.play("Reward")
	end

	local closed = false
	local startedAt = os.clock()
	local spin: RBXScriptConnection? = nil
	local previous = selectedNow()
	local back: Back? = nil
	local function alive(): boolean
		return not closed and root.Parent ~= nil
	end

	-- Idle: the unit turns in from a little past its rest pose (never side-on or
	-- from behind), settles with a small overshoot, then sways and bobs gently.
	local model = viewport:FindFirstChildOfClass("Model")
	if model and not calm and not PREVIEW then
		local rest = model:GetPivot()
		local TURN, FROM, SWAY, BOB = 0.9, -0.8, 0.22, 7
		model:PivotTo(rest * CFrame.Angles(0, FROM, 0))
		spin = RunService.RenderStepped:Connect(function()
			if not root.Parent then
				if spin then
					spin:Disconnect()
				end
				return
			end
			local t = os.clock() - startedAt
			local yaw
			if t < TURN then
				-- Back-out ease: a small overshoot past the front, then settle.
				local u = t / TURN - 1
				local eased = 1 + 2.2 * u * u * u + 1.2 * u * u
				yaw = FROM * (1 - eased)
			else
				local idle = t - TURN
				yaw = SWAY * math.sin(idle * 0.9) * math.min(1, idle / 1.5)
			end
			model:PivotTo(rest * CFrame.Angles(0, yaw, 0))
			viewport.Position = UDim2.new(0.5, 0, 0.5, math.sin(t * 2.4) * BOB * math.min(1, t / 0.6))
		end)
	end

	-- Text, a line at a time: each fades in and slides up into place.
	local lines: { GuiObject } = {}
	local function arrive(gui: GuiObject)
		table.insert(lines, gui)
		if not calm then
			local rest = gui.Position
			gui.Position = rest + UDim2.fromOffset(0, 16)
			Kit.tween(gui, 0.3, { Position = rest }, Enum.EasingStyle.Quart)
		end
		Kit.appear(gui, { from = 0.9, time = 0.26 })
	end
	after(0.18, function()
		if not alive() then
			return
		end
		arrive(Kit.hudText(stage, {
			Name = "Banner",
			Text = if not isNew
				then "YOU GOT"
				elseif type(reward._count) == "number" and reward._count > 1 then string.format(
					"NEW %s!  %d/%d",
					string.upper(W.Unit),
					reward._index or 1,
					reward._count
				)
				else "NEW " .. string.upper(W.Unit) .. "!",
			TextSize = bannerSize,
			TextColor3 = if isNew then C.Gold else C.Text,
			StrokeColor = Theme.Glass.TextInk,
			StrokeThickness = 3,
			Size = UDim2.new(1, 0, 0, bannerSize + 6),
			ZIndex = 5,
		}))
	end)
	after(0.28, function()
		if not alive() then
			return
		end
		-- A soft dark plate behind the name and the stats (no box, no border: a soft dot
		-- stretched wide, the glass tint with the rarity colour in it) so they hold over a
		-- busy plot.
		local plateH = statsY + statSize - nameY + 110
		local plate = softDot(stage, "Plate", VEIL:Lerp(color, 0.12), UDim2.fromOffset(STAGE_W, plateH), 0.1, 2)
		plate.Position = UDim2.new(0.5, 0, 0, (nameY + statsY + statSize + 8) / 2)
		table.insert(lines, plate)
		Kit.appear(plate, { from = 0.9, time = 0.3 })
		-- Big name in the rarity colour, scaled down to fit on one line. It reads on every
		-- rarity: a pale colour with little hue of its own (Common's grey) goes most of the
		-- way to white, and every name wears a thick ink outline over the dark plate.
		local _, saturation = color:ToHSV()
		arrive(Kit.hudText(stage, {
			Name = "UnitName",
			Text = string.upper(Theme.Tiers[tier].Name),
			TextSize = nameSize,
			TextScaled = true,
			MaxTextSize = nameSize,
			TextColor3 = Kit.lighten(color, if saturation < 0.25 then 0.7 else 0.2),
			StrokeColor = Theme.Glass.TextInk,
			Size = UDim2.new(1, -40, 0, nameSize + 6),
			Position = UDim2.fromOffset(20, nameY),
			StrokeThickness = 4,
			ZIndex = 5,
		}))
		sounds.play("Tick", 0.02, 1.2)
	end)
	if gain then
		-- What the action added to the aura made per second, counting up.
		after(0.34, function()
			if not alive() then
				return
			end
			local row = Kit.new("Frame", {
				Name = "Gain",
				BackgroundTransparency = 1,
				Size = UDim2.new(1, 0, 0, gainSize + 8),
				Position = UDim2.fromOffset(0, gainY),
				ZIndex = 5,
				Parent = stage,
			})
			Kit.list(row, 0, true, Enum.HorizontalAlignment.Center)
			local function gained(n: number): string
				return "+" .. (if n < 10 then string.format("%.1f", n) else Format.short(n)) .. " " .. W.Orb .. "/sec"
			end
			local label = statPair(row, "Orb", C.Orb, gained(gain), Kit.lighten(C.Cash, 0.25), 1, gainSize)
			arrive(row)
			Kit.countTo(label, 0, gain, gained, 0.7)
		end)
	end
	after(0.38, function()
		if not alive() then
			return
		end
		arrive(Kit.hudText(stage, {
			Name = "Tier",
			Text = string.format("TIER %d  •  %s", tier, string.upper(band)),
			TextSize = tierSize,
			TextColor3 = Kit.lighten(color, 0.3),
			StrokeColor = Theme.Glass.TextInk,
			Size = UDim2.new(1, 0, 0, tierSize + 4),
			Position = UDim2.fromOffset(0, tierY),
			StrokeThickness = 2.5,
			ZIndex = 5,
		}))
	end)
	after(0.48, function()
		if not alive() then
			return
		end
		-- Stats as icon + number pairs: aura per second, and for a discovery how far
		-- the Index has come.
		local stats = Kit.new("Frame", {
			Name = "Stats",
			BackgroundTransparency = 1,
			Size = UDim2.new(1, 0, 0, statSize + 8),
			Position = UDim2.fromOffset(0, statsY),
			ZIndex = 5,
			Parent = stage,
		})
		Kit.list(stats, 30, true, Enum.HorizontalAlignment.Center)
		local function perSecond(n: number): string
			return Format.short(n) .. "/s"
		end
		-- The server may send the unit's rate (reward.rate, see revealChain).
		local unitRate: number = if type(reward.rate) == "number" then reward.rate else Economy.unitRate(tier)
		local rate = statPair(stats, "Orb", C.Orb, perSecond(unitRate), Kit.lighten(C.Orb, 0.4), 1, statSize)
		if isNew and data and type(data.discovered) == "table" then
			local found = 0
			for t = 1, Economy.MAX_TIER do
				if (data.discovered[t] or 0) > 0 then
					found += 1
				end
			end
			statPair(stats, "Index", C.Gold, string.format("%d/%d", found, Economy.MAX_TIER), C.GoldLight, 2, statSize)
		end
		arrive(stats)
		Kit.countTo(rate, 0, unitRate, perSecond, 0.45)
	end)
	-- "xN MERGES!" under the name plate, never behind the banner: the world text of the
	-- same batch (hidden while the reveal is up), once the stats are in and it is known.
	local mergesReady = false
	local function showMerges(text: string)
		mergesSeen = text
		if not mergesRow or not mergesReady or not alive() or stage:FindFirstChild("Merges") then
			return
		end
		arrive(Kit.hudText(stage, {
			Name = "Merges",
			Text = text,
			TextSize = tierSize,
			TextColor3 = C.GoldLight,
			StrokeColor = Theme.Glass.TextInk,
			Size = UDim2.new(1, 0, 0, tierSize + 4),
			Position = UDim2.fromOffset(0, mergesY),
			StrokeThickness = 2.5,
			ZIndex = 5,
		}))
	end
	if mergesRow then
		mergesOnReveal = showMerges
		after(0.58, function()
			mergesReady = true
			if mergesSeen then
				showMerges(mergesSeen)
			end
		end)
	end
	local portraits: { Portrait } = {}
	if #extras > 0 then
		portraits = extrasRow(stage, extras, stageH - 28, 0.6, alive)
	end

	-- Leaving: input is released first, then the stage clears and the units go.
	local skip = catcher(root, 6)
	local revealed = true
	local function endReveal()
		if revealed then
			revealed = false
			if mergesOnReveal == showMerges then
				mergesOnReveal = nil
			end
			setReveal(false)
		end
	end
	if not PREVIEW then
		root.AncestryChanged:Connect(function()
			if not root:IsDescendantOf(game) then
				endReveal()
			end
		end)
	end
	local function finish()
		if root.Parent then
			root:Destroy()
		end
		done()
	end
	local leave: () -> ()
	local function abort()
		-- The rest of the chain is dropped: the queue moves on once this one has gone.
		if nextReveal then
			nextReveal = nil
			if type(reward._chainDone) == "function" then
				task.delay(0.4, reward._chainDone)
			end
		end
		leave()
	end
	leave = function()
		if closed then
			return
		end
		closed = true
		openModals[abort] = nil
		if spin then
			spin:Disconnect()
		end
		if back then
			dropBack(back)
		end
		release(root, previous)
		skip:Destroy()
		-- The next reveal of the chain comes up first: the blur, the open count and the
		-- "RevealOpen" attribute never drop in between.
		local follow = nextReveal
		nextReveal = nil
		if follow then
			follow()
		end
		Kit.setBlur(false, true)
		Kit.markOpen(screen, openKey, false)
		endReveal()
		Kit.tween(veil, 0.35, { BackgroundTransparency = 1 })
		Kit.tween(wash, 0.3, { BackgroundTransparency = 1 })
		for _, gui in lines do
			Kit.disappear(gui, { time = 0.16, to = 0.96 })
		end
		for _, gui in lights do
			Kit.disappear(gui, { time = 0.28, to = 0.7 })
		end
		local hint = stage:FindFirstChild("Hint")
		if hint and hint:IsA("GuiObject") then
			Kit.disappear(hint, { time = 0.12 })
		end
		-- The queue must never stall (finish and done are idempotent).
		task.delay(1.6, finish)

		if not isNew or calm or chained then
			-- Nothing flies: the units fade where they stand (a calm discovery still
			-- counts on the Index; in a chain the last reveal's orb does).
			Kit.disappear(hero, { time = 0.2, to = 0.85 })
			for _, portrait in portraits do
				Kit.disappear(portrait.gui, { time = 0.2, to = 0.85 })
			end
			task.delay(0.3, function()
				if isNew and not chained and Hud.indexPoint() then
					Hud.punchIndex()
				end
				finish()
			end)
			return
		end

		-- Screen pixels to design px inside `root` (the ScreenGui carries the UI scale).
		local uiScale = screen:FindFirstChildOfClass("UIScale")
		local pixel = if uiScale and uiScale.Scale > 0 then uiScale.Scale else 1
		local function toRoot(point: Vector2): Vector2
			return (point - root.AbsolutePosition) / pixel
		end
		local spot = Hud.indexPoint()
		local goal = if spot then toRoot(spot) else Vector2.new(36, 36)
		local flying = 1 + #portraits
		local function landed()
			-- Punch only a button that is still there (a window may have opened meanwhile).
			if spot and Hud.indexPoint() then
				Hud.punchIndex()
			end
			flying -= 1
			if flying == 0 then
				-- A beat for the last trail dots to fade.
				task.delay(0.32, finish)
			end
		end
		local function launch(source: GuiObject, tint: Color3, size: number, wait: number)
			task.delay(wait, function()
				if not root.Parent then
					return
				end
				local from = toRoot(source.AbsolutePosition + source.AbsoluteSize / 2)
				Kit.disappear(source, { time = ORB_MORPH + 0.04, to = 0.15 })
				flyOrb(root, from, goal, tint, size, landed)
			end)
		end
		sounds.play("Open", 0, 1.3)
		launch(hero, color, 120, 0)
		for i, portrait in portraits do
			launch(portrait.gui, portrait.color, 60, 0.08 + i * ORB_STAGGER)
		end
	end
	-- Any tap, click, B or Escape continues, but never before the unit has popped in.
	local function dismiss()
		local wait = REVEAL_MIN - (os.clock() - startedAt)
		if wait > 0 then
			task.delay(wait, leave)
		else
			leave()
		end
	end
	skip.Activated:Connect(dismiss)
	-- Popups.closeModals (the capture hook, the preview) ends a reveal too, and with it
	-- the rest of its chain.
	openModals[abort] = true
	back = pushBack(30, dismiss)
	if not PREVIEW and (Kit.gamepad or Kit.tenFoot) then
		-- Gamepad: the catcher holds the selection (with no ring), so A continues too.
		skip.Selectable = true
		skip.SelectionImageObject = Kit.new("Frame", { BackgroundTransparency = 1 })
		Kit.focus(skip, skip)
	end

	-- A small faded hint, only for a player who has not continued after a second (a
	-- reveal with more behind it moves on by itself).
	after(REVEAL_HINT, function()
		if not alive() or chained then
			return
		end
		local hint = Kit.hudText(stage, {
			Name = "Hint",
			Text = Kit.hint("tap to continue", "click to continue", "press A to continue"),
			Font = Theme.Fonts.UI,
			TextSize = 15,
			MinPx = true,
			TextTransparency = 0.25,
			Size = UDim2.new(1, 0, 0, 20),
			Position = UDim2.new(0, 0, 1, -22),
			StrokeThickness = 1.5,
			ZIndex = 5,
		})
		local outline = hint:FindFirstChild("Outline")
		if outline and outline:IsA("UIStroke") then
			outline.Transparency = 0.6
		end
		Kit.appear(hint, { from = 1, time = 0.3 })
	end)

	if not PREVIEW then
		local tutorial = data ~= nil and data.tutorialDone ~= true
		local hold = if chained then REVEAL_CHAIN elseif isNew then REVEAL_IDLE else (if tutorial then REVEAL_HOLD_TUTORIAL else REVEAL_HOLD)
		task.delay(hold, leave)
		-- The long hold is for the last card only: once something waits in the queue (the
		-- tutorial's "YOU DID IT!", a finish card, the next reveal) this one makes room.
		if hold > REVEAL_QUEUED then
			task.spawn(function()
				while not closed and root.Parent do
					if #queue > 0 and os.clock() - startedAt >= REVEAL_QUEUED then
						leave()
						return
					end
					task.wait(0.25)
				end
			end)
		end
	end
end

--[[
	One reveal per newly discovered tier, lowest first: every one but the last holds
	REVEAL_CHAIN and hands over (reward._next), the last stays until it is dismissed. At most
	CHAIN_MAX in a row: a bigger jump keeps its newest tiers and the older ones ride on the
	last reveal as small portraits.

	Payload fields the server adds (Tycoon.discoverAll); without them the client works them out:
	  productionBefore, productionAfter  aura per second before and after the action, without
	                 the surge (else from the snapshots; "before" is absent on a join or debug grant)
	  rates          { [tier] = aura per second of one unit }, 1..newest (else Economy.unitRate)
]]
local function revealChain(reward: { [string]: any }, done: () -> ())
	local startedAt = os.clock()
	local before, after = tonumber(reward.productionBefore), tonumber(reward.productionAfter)
	local gain: number? = if before and after
		then after - before
		else productionGain((if type(reward._at) == "number" then reward._at else startedAt) - PROD_LEAD)
	local rates: { [any]: any } = if type(reward.rates) == "table" then reward.rates else {}
	local function rateOf(t: number): number?
		-- A sparse table crosses the remote with string keys.
		return tonumber(rates[t]) or tonumber(rates[tostring(t)])
	end
	local tiers: { number } = {}
	if reward.new == true and type(reward.tiers) == "table" then
		for _, t in reward.tiers do
			if type(t) == "number" and Theme.Tiers[t] and not table.find(tiers, t) then
				table.insert(tiers, t)
			end
		end
	end
	if not table.find(tiers, reward.tier) then
		table.insert(tiers, reward.tier)
	end
	table.sort(tiers)
	if #tiers <= 1 or PREVIEW then
		reward._startedAt = startedAt
		reward.gain = gain
		reward.rate = rateOf(reward.tier)
		showReveal(reward, done)
		return
	end
	local first = math.max(1, #tiers - CHAIN_MAX + 1)
	local count = #tiers - first + 1
	local function show(index: number)
		local t = tiers[first + index - 1]
		local last = index == count
		local shown = { t }
		if last then
			for i = 1, first - 1 do
				table.insert(shown, tiers[i])
			end
		end
		local entry: { [string]: any } = {
			kind = "Reward",
			tier = t,
			tiers = shown,
			new = true,
			rate = rateOf(t),
			gain = if last then gain else nil,
			_at = reward._at,
			_startedAt = startedAt,
			_index = index,
			_count = count,
			_chainDone = done,
		}
		if not last then
			entry._next = function()
				show(index + 1)
			end
		end
		local ok, err = pcall(showReveal, entry, if last then done else function() end)
		if not ok then
			warn("[Popups] reveal " .. tostring(t) .. " failed: " .. tostring(err))
			done()
		end
	end
	show(1)
end

-- Crate reveal: rising shakes (more for rarer crates, with a halo and a soft
-- tint building up), a burst (white ring, rays, confetti; a held breath before
-- Legendary+), a quick roll through the possible units, then the unit reveal.
-- 1.5-3 s; tap to skip.
local function crateReveal(reward: { [string]: any }, done: () -> ())
	if PREVIEW then
		revealChain(reward, done)
		return
	end
	local rarity = reward.crateRarity or Economy.tierBand(reward.tier)
	local color = C.Rarity[rarity] or C.Gold
	local rank = RARITY_RANK[rarity] or 1

	local holder = Kit.new("Frame", {
		Name = "CrateReveal",
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(420, 420),
		Position = UDim2.fromScale(0.5, 0.5),
		AnchorPoint = Vector2.new(0.5, 0.5),
		ZIndex = 30,
		Parent = screen,
	})
	-- As dark as the unit reveal's veil that follows, and solid over an open window (the
	-- window is hidden for the whole reveal).
	local dim = cover(holder, "Dim", VEIL, if Windows.isAnyOpen() then 0 else 0.2)
	Kit.appear(dim, { from = 1, time = 0.25 })
	local tint: Frame? = if rank >= 3 then cover(holder, "Tint", color, 1) else nil

	local beam = Kit.new("Frame", {
		Name = "Beam",
		BackgroundColor3 = Kit.lighten(color, 0.45),
		BackgroundTransparency = 0.35,
		BorderSizePixel = 0,
		Size = UDim2.fromOffset(90, 0),
		Position = UDim2.fromScale(0.5, 0.55),
		AnchorPoint = Vector2.new(0.5, 1),
		ZIndex = 1,
		Parent = holder,
	})
	Kit.corner(beam, 45)
	Kit.new("UIGradient", {
		Rotation = -90,
		Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0),
			NumberSequenceKeypoint.new(0.6, 0.5),
			NumberSequenceKeypoint.new(1, 1),
		}),
		Parent = beam,
	})
	local halo = circle(holder, "Glow", Kit.lighten(color, 0.4), 0.7, 2)
	halo.Size = UDim2.fromOffset(170, 170)
	Kit.new("UIStroke", { Thickness = 3, Color = WHITE, Transparency = 0.45, Parent = halo })
	local crate = crateIcon(holder, color, 160, {
		Rarity = rarity,
		Position = UDim2.fromScale(0.5, 0.5),
		AnchorPoint = Vector2.new(0.5, 0.5),
		ZIndex = 3,
	})
	local crateScale = Kit.new("UIScale", { Parent = crate })
	Kit.appear(crate, { from = 0.4, time = 0.3 })
	local rarityPill = Kit.pill(holder, {
		Name = "Rarity",
		Text = string.upper(rarity .. " " .. W.Chest),
		Solid = true,
		Color = color,
		TextSize = T.Small,
		Size = UDim2.fromOffset(0, 32),
		AutomaticSize = Enum.AutomaticSize.X,
		Position = UDim2.new(0.5, 0, 1, -36),
		AnchorPoint = Vector2.new(0.5, 0.5),
		ZIndex = 4,
	})
	Kit.appear(rarityPill, { from = 0.6, delay = 0.12 })
	local rollLabel = Kit.title(holder, {
		Name = "Roll",
		Text = "",
		TextSize = 40,
		TextScaled = true,
		MaxTextSize = 40,
		Size = UDim2.new(1, 0, 0, 50),
		Position = UDim2.fromScale(0.5, 0.5),
		AnchorPoint = Vector2.new(0.5, 0.5),
		ZIndex = 5,
		StrokeThickness = 0,
		Visible = false,
	})
	Kit.textStroke(rollLabel, 2.5, 0)

	local skipped = false
	local finished = false
	local skipBack: Back? = nil
	local function finish()
		if finished then
			return
		end
		finished = true
		if skipBack then
			dropBack(skipBack)
		end
		Kit.disappear(holder, { to = 1.08, time = 0.2, destroy = true })
		task.delay(0.1, function()
			revealChain(reward, done)
		end)
	end
	catcher(holder, 6).Activated:Connect(function()
		skipped = true
		finish()
	end)
	skipBack = pushBack(30, function()
		skipped = true
		finish()
	end)
	local function pause(t: number): boolean
		task.wait(t)
		return skipped
	end

	task.spawn(function()
		-- Rising shakes: 2 for Common up to 6 for Legendary/Mythic.
		local shakes = math.min(rank + 1, 6)
		for i = 1, shakes do
			local k = i / shakes
			if pause(math.max(0.24 - i * 0.02, 0.13)) then
				return
			end
			sounds.play("CrateShake", 0.04, 0.85 + k * 0.6)
			local a = (6 + 14 * k) * (if i % 2 == 0 then 1 else -1)
			Kit.tween(crate, 0.05, { Rotation = a })
			Kit.tween(crateScale, 0.06, { Scale = 1.08 + 0.12 * k })
			task.delay(0.05, function()
				Kit.tween(crate, 0.2, { Rotation = 0 }, Enum.EasingStyle.Back)
				Kit.tween(crateScale, 0.22, { Scale = 1 + 0.06 * k }, Enum.EasingStyle.Back)
			end)
			local haloSize = 170 + (40 + rank * 12) * k
			Kit.tween(halo, 0.2, {
				BackgroundTransparency = 0.7 - (0.15 + rank * 0.03) * k,
				Size = UDim2.fromOffset(haloSize, haloSize),
			})
			if tint then
				Kit.tween(tint, 0.25, { BackgroundTransparency = 1 - (0.04 + rank * 0.015) * k })
			end
		end

		-- Legendary+: a held breath (trembling, swelling, halo growing) before the pop.
		if rank >= 5 then
			sounds.play("Ready", 0, 0.8)
			Kit.tween(crateScale, 0.7, { Scale = 1.25 }, Enum.EasingStyle.Sine)
			Kit.tween(halo, 0.7, { BackgroundTransparency = 0.3, Size = UDim2.fromOffset(320, 320) }, Enum.EasingStyle.Sine)
			local held = 0
			while held < 0.7 do
				crate.Rotation = (math.random() - 0.5) * 6
				crate.Position = UDim2.new(0.5, math.random(-2, 2), 0.5, math.random(-2, 2))
				if pause(0.04) then
					return
				end
				held += 0.04
			end
			crate.Rotation = 0
			crate.Position = UDim2.fromScale(0.5, 0.5)
		elseif pause(0.14) then
			return
		end

		-- Burst: the crate puffs away, a white ring spreads, rays and confetti.
		sounds.play("CrateBurst", 0, if rank >= 5 then 0.85 else 1)
		Kit.disappear(crate, { to = 1.6, time = 0.2, destroy = true })
		local ring = circle(holder, "Ring", WHITE, 1, 4)
		ring.Size = UDim2.fromOffset(90, 90)
		local ringStroke = Kit.new("UIStroke", { Thickness = 10, Color = WHITE, Transparency = 0.15, Parent = ring })
		local ringSize = 360 + rank * 40
		Kit.tween(ring, 0.5, { Size = UDim2.fromOffset(ringSize, ringSize) }, Enum.EasingStyle.Quart)
		Kit.tween(ringStroke, 0.5, { Transparency = 1, Thickness = 2 }, Enum.EasingStyle.Quart)
		if tint then
			Kit.tween(tint, 0.6, { BackgroundTransparency = 0.92 })
		end
		Kit.tween(beam, 0.35, { Size = UDim2.fromOffset(90 + rank * 10, 900) }, Enum.EasingStyle.Quart)
		local haloSize = 240 + rank * 15
		Kit.tween(halo, 0.3, { BackgroundTransparency = 0.55, Size = UDim2.fromOffset(haloSize, haloSize) })
		local raySize = 560 + rank * 40
		local rays = Popups.rays(holder, Kit.lighten(color, 0.5), raySize, UDim2.fromScale(0.5, 0.5), 1, 6 + rank)
		Kit.appear(rays, { from = 0.2, time = 0.4, style = Enum.EasingStyle.Quart })
		if rank >= 4 then
			local inner = Popups.rays(holder, WHITE, raySize * 0.7, UDim2.fromScale(0.5, 0.5), 1, 9, true)
			Kit.appear(inner, { from = 0.2, time = 0.45, style = Enum.EasingStyle.Quart })
		end
		Kit.pop(holder, 0.15 + 0.05 * rank)
		Kit.confetti(holder, {
			Origin = UDim2.fromScale(0.5, 0.5),
			Count = 12 + rank * 8,
			ZIndex = 4,
			Colors = { color, CANDY[1], CANDY[2], CANDY[3], CANDY[4], CANDY[7] },
			Power = 0.7 + rank * 0.12,
		})
		if pause(0.22) then
			return
		end

		-- Roll through the possible units, slowing down, then land.
		local pool = {}
		local data = State.data
		if reward.crateRarity and data then
			for _, entry in Economy.chestOdds(reward.crateRarity, data.highestTier) do
				table.insert(pool, entry.tier)
			end
		end
		if #pool < 2 then
			pool = {}
			for t = math.max(1, reward.tier - 2), math.min(Economy.MAX_TIER, reward.tier + 1) do
				table.insert(pool, t)
			end
		end
		Kit.appear(rollLabel, { from = 0.6, time = 0.18 })
		local elapsed = 0
		local step = 0.05
		local last = 0
		local pitch = 1
		while elapsed < 0.72 do
			local pick = pool[math.random(1, #pool)]
			if pick == last and #pool > 1 then
				pick = pool[(table.find(pool, pick) :: number) % #pool + 1]
			end
			last = pick
			rollLabel.Text = Theme.Tiers[pick].Name
			rollLabel.TextColor3 = Kit.lighten(C.Rarity[Economy.tierBand(pick)], 0.2)
			Kit.pop(rollLabel, 0.6)
			sounds.play("Tick", 0.05, pitch)
			pitch = math.min(pitch + 0.04, 1.4)
			if pause(step) then
				return
			end
			elapsed += step
			step *= 1.28
		end
		local final = reward.tier
		local finalBand = Economy.tierBand(final)
		rollLabel.Text = Theme.Tiers[final].Name
		rollLabel.TextColor3 = Kit.lighten(C.Rarity[finalBand], 0.25)
		rarityPill.Text = string.upper(finalBand)
		Kit.pop(rollLabel, 2.5)
		Kit.pop(rarityPill, 1)
		-- One sound per reveal: a new discovery celebrates on the unit reveal instead.
		reward._sounded = true
		if not reward.new then
			sounds.play("Reward")
		end
		if pause(0.32) then
			return
		end
		finish()
	end)
end

function Popups.reward(data: { [string]: any })
	data._at = os.clock()
	if data.new then
		lastDiscoveryAt = data._at
	end
	if data.source == "unlock" or data.source == "unlocker" then
		data.crate = true
	end
	if pendingChest and os.clock() - pendingChest.at <= CRATE_LINK then
		data.crate = true
		data.crateRarity = pendingChest.rarity
		pendingChest = nil
	end
	if not data.new then
		-- Ignore anything beyond a handful queued (e.g. huge cascades).
		local queued = 0
		for _, entry in queue do
			if entry.kind == "Reward" then
				queued += 1
			end
		end
		if queued >= 4 then
			return
		end
	end
	local priority = if data.new then Popups.PRIORITY.NewTier else Popups.PRIORITY.Normal
	Popups.enqueue("Reward", priority, function(done)
		if data.crate then
			crateReveal(data, done)
		else
			revealChain(data, done)
		end
	end, data)
end

-- Confirm dialog ---------------------------------------------------------------------------

-- Height of `text` wrapped to `width` in the body font (TextService when available, else an
-- estimate from its length).
local function bodyHeight(text: string, size: number, width: number): number
	local height = 0
	pcall(function()
		local TextService = game:GetService("TextService")
		height = TextService:GetTextSize(text, size, Kit.F.Body, Vector2.new(width, 1000)).Y
	end)
	if height <= 0 then
		local lines = 0
		for line in string.gmatch(text .. "\n", "(.-)\n") do
			lines += math.max(1, math.ceil((utf8.len(line) or #line) * size * 0.5 / width))
		end
		height = lines * math.ceil(size * 1.25)
	end
	return math.ceil(height)
end

-- The card is as tall as its question: title, the text (one to five lines) and the two
-- answers, 16 px apart, under the medallion's lower half.
function Popups.confirm(text: string, onYes: () -> (), options: { [string]: any }?)
	local opts = options or {}
	Popups.enqueue("Confirm", Popups.PRIORITY.Normal, function(done)
		local WIDTH, PAD, GAP = 460, 20, 16
		-- Title and question sizes on the glass (22+ and 16): the card grows with them.
		local titleSize = Kit.px(22, T.H2 + 2, screen)
		local textSize = Kit.px(if Kit.touch then 14 else 16, T.H3, screen)
		local titleY = 50
		local plateY = titleY + titleSize + 8 + 6
		local textH = math.clamp(bodyHeight(text, textSize, WIDTH - PAD * 2 - 24), textSize + 4, textSize * 5 + 12)
		local plateH = textH + 20
		local buttonY = plateY + plateH + GAP
		local box, close = modal("Confirm", Vector2.new(WIDTH, buttonY + 56 + PAD), 50, nil, done)
		local medal = medallion(box, opts.icon or "?", C.Gold, 70, UDim2.new(0.5, 0, 0, 0))
		Kit.title(box, {
			Text = opts.title or "ARE YOU SURE?",
			TextSize = titleSize,
			TextWrapped = false,
			Size = UDim2.new(1, -PAD * 2, 0, titleSize + 8),
			Position = UDim2.fromOffset(PAD, titleY),
			TextColor3 = C.Gold,
		})
		-- The question sits on a darker plate, like the amounts of the Welcome Back card.
		local plate = Kit.well(box, {
			Name = "Plate",
			Glass = true,
			Size = UDim2.new(1, -PAD * 2, 0, plateH),
			Position = UDim2.fromOffset(PAD, plateY),
		})
		Kit.text(plate, {
			Name = "Text",
			Text = text,
			TextSize = textSize,
			Size = UDim2.new(1, -24, 1, -20),
			Position = UDim2.fromOffset(12, 10),
			StrokeThickness = 0,
		})
		local yes = Kit.button(box, {
			Text = opts.yes or "Yes",
			Color = C.Gold,
			Size = UDim2.new(0.5, -PAD - 6, 0, 56),
			Position = UDim2.fromOffset(PAD, buttonY),
		}, function()
			close()
			onYes()
		end)
		local no = Kit.button(box, {
			Text = opts.no or "No",
			Color = C.SurfaceHi,
			Size = UDim2.new(0.5, -PAD - 6, 0, 56),
			Position = UDim2.new(0.5, 6, 0, buttonY),
			Sound = "Close",
		}, close)
		-- Gamepad lands on the safe answer; B also answers "No".
		no:SetAttribute("FocusFirst", true)
		Kit.appear(box)
		Kit.appear(medal, { from = 0.4, time = 0.32, delay = 0.06 })
		local buttons: { GuiObject } = { yes, no }
		Kit.stagger(buttons, 0.04)
	end)
end

-- Offline earnings ---------------------------------------------------------------------------

-- Width of one line of Number text (TextService when available, else an estimate).
local function numberWidth(text: string, size: number): number
	local width = 0
	pcall(function()
		local TextService = game:GetService("TextService")
		width = TextService:GetTextSize(text, size, Kit.F.Number, Vector2.new(2000, 80)).X
	end)
	if width <= 0 then
		width = (utf8.len(text) or #text) * size * 0.66
	end
	return math.ceil(width)
end

--[[
	"Welcome back": what the units earned while the player was away. The card is sized to
	its content on one 16 px rhythm: medallion, title, the duration (secondary), the aura ->
	cash row and the Collect hint, then the button. The cash is the hero: the biggest text,
	rolling up from 0 with ticks. Each amount is centred in its half of the row, so the pair
	sits symmetrically round the arrow whatever the numbers are.
]]
local OFFLINE = {
	Width = 540,
	Pad = 20,
	Gap = 16,
	LineGap = 12, -- between a plain line of text and the amounts panel
	Body = 18, -- the two one-line texts, in screen px on a desktop
	Title = 56, -- under the medallion's lower half
	Row = 92,
	Arrow = 44,
	Aura = 28,
	Cash = Kit.TEXT.Hero,
	Button = 58,
	Roll = 0.6,
}

function Popups.offline(data: { [string]: any })
	Popups.enqueue("Offline", Popups.PRIORITY.Normal, function(done)
		local L = OFFLINE
		-- The two one-line texts are held on the glass: body text (L.Body px) on a desktop, a
		-- caption at least on a phone. They are plain lines; only the amounts sit on a panel.
		local bodyPx = if Kit.touch then Kit.captionPx() else L.Body
		local subSize = Kit.px(bodyPx, T.H3, screen)
		local noteSize = Kit.px(bodyPx, if Kit.touch then T.Body else T.H3, screen)
		local subY = L.Title + 34 + 6
		local rowY = subY + subSize + 6 + L.LineGap
		local noteY = rowY + L.Row + L.LineGap
		local buttonY = noteY + noteSize + 6 + L.Gap
		local height = buttonY + L.Button + L.Pad
		local box, close = modal("Offline", Vector2.new(L.Width, height), 45, nil, done)
		local medal = medallion(box, "💤", C.Rizz, 84, UDim2.new(0.5, 0, 0, 0))
		Kit.title(box, {
			Text = "WELCOME BACK!",
			TextSize = T.H1,
			TextWrapped = false,
			Size = UDim2.new(1, -L.Pad * 2, 0, 34),
			Position = UDim2.fromOffset(L.Pad, L.Title),
			TextColor3 = C.Gold,
		})
		-- A line of body text straight on the glass (no plate of its own: a full-width bar
		-- behind one line reads as a box in a box), in a hairline of ink so it holds over a
		-- bright world.
		local function plainLine(name: string, line: string, size: number, y: number)
			Kit.text(box, {
				Name = name,
				Text = line,
				TextSize = size,
				TextWrapped = false,
				TextTruncate = Enum.TextTruncate.AtEnd,
				BackgroundTransparency = 1,
				Size = UDim2.new(1, -L.Pad * 2, 0, size + 6),
				Position = UDim2.fromOffset(L.Pad, y),
				TextColor3 = C.Text,
				StrokeThickness = 1,
			})
		end
		plainLine("Away", string.format("Your %s kept grinding for %s.", W.Units, Format.time(data.seconds)), subSize, subY)
		local well = Kit.well(box, {
			Name = "Earned",
			Glass = true,
			Size = UDim2.new(1, -L.Pad * 2, 0, L.Row),
			Position = UDim2.fromOffset(L.Pad, rowY),
		})
		local orbTotal = tonumber(data.orbs) or 0
		local cashTotal = tonumber(data.cash) or 0
		local half = (L.Width - L.Pad * 2 - L.Arrow) / 2
		-- One amount: an icon and a number as a group sized for the final text (so it holds
		-- still while it rolls), centred in the half of the row on `side` (0 left, 1 right).
		local function amount(
			name: string,
			icon: string,
			iconColor: Color3,
			side: number,
			final: string,
			size: number,
			color: Color3
		): TextLabel
			local iconSize = math.floor(size * 0.9)
			local room = half - 24 - iconSize - 8
			local width = math.min(numberWidth(final, size) + 4, room)
			local cell = Kit.new("Frame", {
				Name = name,
				BackgroundTransparency = 1,
				Size = UDim2.new(0, iconSize + 8 + width, 1, 0),
				Position = UDim2.new(side, (0.5 - side) * half, 0, 0),
				AnchorPoint = Vector2.new(0.5, 0),
				Parent = well,
			})
			Kit.icon(cell, icon, iconSize, iconColor, { Position = UDim2.new(0, 0, 0.5, 0), AnchorPoint = Vector2.new(0, 0.5) })
			return Kit.number(cell, {
				Name = "Value",
				Text = final,
				MaxTextSize = size,
				Size = UDim2.new(0, width, 0, size + 8),
				Position = UDim2.new(0, iconSize + 8, 0.5, 0),
				AnchorPoint = Vector2.new(0, 0.5),
				TextXAlignment = Enum.TextXAlignment.Left,
				TextColor3 = color,
			})
		end
		local orbs = amount("Aura", "Orb", C.Orb, 0, Format.short(orbTotal), L.Aura, Kit.lighten(C.Orb, 0.35))
		Kit.title(well, {
			Name = "Arrow",
			Text = "→",
			TextSize = 26,
			TextWrapped = false,
			Size = UDim2.new(0, L.Arrow, 1, 0),
			Position = UDim2.fromScale(0.5, 0),
			AnchorPoint = Vector2.new(0.5, 0),
			TextColor3 = C.TextMute,
			StrokeThickness = 0,
		})
		local cash = amount("Cash", "Coin", C.Gold, 1, Format.money(cashTotal), L.Cash, C.MoneyText)
		plainLine("Hint", "Your cash is waiting on the Collect pad.", noteSize, noteY)
		local go = Kit.button(box, {
			Text = "Let's go!",
			Font = Theme.Fonts.Display,
			Color = C.Gold,
			Breathe = true,
			Size = UDim2.new(1, -L.Pad * 2, 0, L.Button),
			Position = UDim2.fromOffset(L.Pad, buttonY),
		}, close)
		go:SetAttribute("FocusFirst", true)
		Kit.appear(box)
		Kit.appear(medal, { from = 0.4, time = 0.32, delay = 0.06 })
		Kit.appear(go, { from = 0.8, time = 0.26, delay = 0.14 })
		after(0.18, function()
			Kit.countTo(orbs, 0, orbTotal, Format.short, L.Roll)
		end)
		after(0.3, function()
			if not cash.Parent then
				return
			end
			Kit.countTo(cash, 0, cashTotal, Format.money, L.Roll)
			-- The cash rolls up with ticks that climb in pitch.
			if cashTotal > 0 and not PREVIEW then
				task.spawn(function()
					local ticks = 8
					for i = 1, ticks do
						if not cash.Parent then
							return
						end
						sounds.play("Tick", 0.03, 1 + i * 0.05)
						task.wait(L.Roll / ticks)
					end
				end)
			end
		end)
		sounds.play("Reward")
	end)
end

-- Game mode finish ----------------------------------------------------------------------------
--[[
	The Parkour finish card: "MAP n CLEAR!" (or "NEW BEST!") over the map's name and the
	falls of the run, the run time, best and the rank on this server's board, the cash
	reward rolling up and a line saying why it is what it is. Four states (payload `first`,
	`pay`, `assisted`, `level` / `levels`):
	  first clean clear  rays and sparkles round the medal, rows of confetti, and a wide
	                     "MAP n+1 UNLOCKED!" banner popping in when the clear opened a map;
	  all maps cleared   the run that makes every map cleared without gear (payload
	                     `complete`): "SKY OBBY COMPLETE!", a star medal, more confetti and
	                     an "ALL 10 MAPS CLEARED!" banner;
	  repeat             a clean run inside the cooldown: "RUN AGAIN  +$X  +20%" in the
	                     reward well and the cooldown as a clock bar under a padlock
	                     ("Full reward in m:ss", filling until the full reward is back);
	                     while the map's bonus rests (pay "resting") no well, and a note
	                     saying when it is back;
	  assisted           gear on: grey medal, white title, an "ASSISTED RUN · NO BEST TIME"
	                     ribbon instead of the best line, no confetti.
	While the card is up the server holds the sky course's return to the gates: the card
	fires the "ModeCard" action { mode, open } when it opens and when it closes.
	Buttons: "Next level" (gold, when there is one) beside "Run again", with slim "Choose
	map" (opens the Maps window) and "Back to my gym" under them; on the last level "Run
	again" beside "Back to my gym" with a slim "Choose map" under them. `data` is the finish Notify payload (time, best, newBest, rank?, cash, full,
	cooldownEnds, level, levelName, levels?, nextLevel?, unlockedNew, first?, assisted?, falls?,
	pay?, repeatShare?, mode).
]]

local function runTime(seconds: number): string
	local tenths = math.floor(math.max(seconds, 0) * 10 + 0.5)
	return string.format("%d:%02d.%d", tenths // 600, (tenths // 10) % 60, tenths % 10)
end
Popups.runTime = runTime

-- A finish card's reward well: the coin and a rolling "+$N", centred as one group sized
-- for the final amount so it holds still while it counts.
local function cashRow(well: Frame, total: number): TextLabel
	local final = "+" .. Format.money(total)
	local width = 0
	pcall(function()
		local TextService = game:GetService("TextService")
		width = TextService:GetTextSize(final, 26, Kit.F.Number, Vector2.new(1000, 40)).X
	end)
	if width <= 0 then
		width = (utf8.len(final) or #final) * 16
	end
	local cell = Kit.new("Frame", {
		Name = "Cash",
		BackgroundTransparency = 1,
		Size = UDim2.new(0, 38 + math.ceil(width) + 4, 1, 0),
		Position = UDim2.fromScale(0.5, 0),
		AnchorPoint = Vector2.new(0.5, 0),
		Parent = well,
	})
	Kit.icon(cell, "Coin", 30, C.Gold, { Position = UDim2.new(0, 0, 0.5, 0), AnchorPoint = Vector2.new(0, 0.5) })
	return Kit.number(cell, {
		Text = "+0",
		TextSize = 26,
		Size = UDim2.new(1, -38, 1, 0),
		Position = UDim2.fromOffset(38, 0),
		TextXAlignment = Enum.TextXAlignment.Left,
		TextColor3 = C.MoneyText,
		StrokeThickness = 0,
	})
end

-- Finish card tuning. Nothing here was judged on screen yet: adjust in Studio.
local FINISH = {
	Medal = 84,
	Rays = 250, -- px across, behind the medal on a first clear
	Sparkles = 7, -- twinkles round the medal on a first clear
	Confetti = 28, -- pieces per burst (Kit.confetti caps at 28)
	FirstBursts = 2, -- bursts on a map's first clean clear
	CompleteBursts = 4, -- ... on the last map's (the whole sky obby)
	BurstGap = 0.35, -- seconds between bursts
	CashRoll = 0.9, -- seconds the "+$N" counts up
	UnlockH = 40, -- the "MAP n UNLOCKED!" banner
	UnlockAt = 0.7, -- seconds after the card opens
	CoolH = 26, -- the cooldown clock bar
	AssistedMedal = World.Steel, -- the grey medal of a run with gear on
	CoolColor = C.Rizz,
}

function Popups.modeFinish(data: { [string]: any }, onAgain: () -> (), onHome: () -> (), onNext: (() -> ())?, onPick: (() -> ())?)
	Popups.enqueue("ModeFinish", Popups.PRIORITY.Normal, function(done)
		local cashTotal = tonumber(data.cash) or 0
		local cooldownEnds = tonumber(data.cooldownEnds) or 0
		local cooling = data.full == false and cooldownEnds > os.time()
		local level = tonumber(data.level)
		local levels = tonumber(data.levels)
		local nextLevel = tonumber(data.nextLevel)
		local hasNext = nextLevel ~= nil and onNext ~= nil
		local unlockedNew = data.unlockedNew == true and nextLevel ~= nil
		-- An assisted run (worn gear) never sets a best or a board entry.
		local assisted = data.assisted == true
		-- The card's state: a map's first clean clear is the loud one, the last map's the
		-- loudest ("SKY OBBY COMPLETE!"); a clean run inside the cooldown shows its share and
		-- the clock; an assisted run is grey and calm.
		-- `complete` is the server's word: this run made it every map cleared without gear,
		-- for the first time (so a map 10 first cleared with gear still gets its card later).
		local complete = data.complete == true and not assisted
		local firstClear = (data.first == true and not assisted) or complete
		local repeatRun = data.pay == "repeat" and not assisted
		-- A clean run while this map's run again bonus rests (it was paid a moment ago).
		local resting = data.pay == "resting"
		local restLeft = math.max(0, math.floor(tonumber(data.repeatRest) or 0))
		local calm = reducedMotion()
		-- Rows under the best line, top to bottom: reward well, cooldown clock, banner, note.
		local hasWell = cashTotal > 0
		local banner: string? = if complete
			then string.format("ALL %d MAPS CLEARED!", levels or level or 10)
			elseif unlockedNew then "MAP " .. tostring(nextLevel) .. " UNLOCKED!"
			else nil
		local y = 184
		local wellY = y
		if hasWell then
			y += 62 + 8
		end
		local coolY = y
		if cooling then
			y += FINISH.CoolH + 10
		end
		local bannerY = y
		if banner then
			y += FINISH.UnlockH + 8
		end
		local noteY = y
		local hasPick = onPick ~= nil
		local buttonsH = if hasNext or hasPick then 128 else 74
		-- The sky course's return to the gates waits while this card is up: the server is told
		-- when it opens and when it closes.
		local action = Net.event("Action")
		local box, close = modal("ModeFinish", Vector2.new(480, noteY + 22 + 14 + buttonsH), 45, nil, function()
			Popups.finishCards[done] = nil
			action:FireServer({ action = "ModeCard", mode = data.mode, open = false })
			done()
		end)
		-- Closed with the mode's next start or stop, and once the player is Home.
		Popups.watchFinish(done, close)
		action:FireServer({ action = "ModeCard", mode = data.mode, open = true })
		local medalAt = UDim2.new(0.5, 0, 0, 0)
		if firstClear then
			-- Behind the medal and (made first) under the title: rays, and twinkles on a ring
			-- lifted so its lower edge stays off the title.
			if not calm then
				Popups.rays(box, Kit.lighten(C.Gold, 0.3), FINISH.Rays, medalAt, 1, if complete then 9 else 6)
			end
			local twinkle = Kit.new("Frame", {
				Name = "MedalSparkles",
				BackgroundTransparency = 1,
				Size = UDim2.fromOffset(FINISH.Medal, FINISH.Medal),
				Position = UDim2.new(0.5, 0, 0, -math.floor(FINISH.Medal * 0.35)),
				AnchorPoint = Vector2.new(0.5, 0.5),
				Parent = box,
			})
			sparkles(twinkle, Kit.lighten(C.Gold, 0.5), FINISH.Sparkles, FINISH.Medal * 0.85, calm)
		end
		local medal =
			medallion(box, if complete then "⭐" else "🏁", if assisted then FINISH.AssistedMedal else C.Gold, FINISH.Medal, medalAt)
		-- "NEW BEST!" only when an older best was beaten: a first clear names the map.
		local namesMap = not complete and (firstClear or assisted or not data.newBest)
		Kit.title(box, {
			Text = if complete
				then "SKY OBBY COMPLETE!"
				elseif not namesMap then "NEW BEST!"
				elseif level then "MAP " .. tostring(level) .. " CLEAR!"
				else "COURSE CLEAR!",
			TextSize = T.H1,
			TextWrapped = false,
			Size = UDim2.new(1, -20, 0, 34),
			Position = UDim2.fromOffset(10, 48),
			TextColor3 = if assisted then C.Text else C.Gold,
		})
		local levelLine = if type(data.levelName) == "string" then data.levelName else ""
		if level and not namesMap then
			levelLine = "Map " .. tostring(level) .. (if levelLine ~= "" then "  ·  " .. levelLine else "")
		end
		-- The falls of the run (Parkour counts them; other modes send none).
		local falls = tonumber(data.falls)
		if falls then
			local fallsText = if falls <= 0 then "No falls!" elseif falls == 1 then "1 fall" else string.format("%d falls", falls)
			levelLine = if levelLine ~= "" then levelLine .. "  ·  " .. fallsText else fallsText
		end
		Kit.text(box, {
			Name = "LevelName",
			Text = levelLine,
			Font = Kit.F.UI,
			TextSize = T.Body,
			TextWrapped = false,
			Size = UDim2.new(1, -30, 0, 22),
			Position = UDim2.fromOffset(15, 82),
			TextColor3 = C.Text,
			StrokeThickness = 0,
		})
		local timeLabel = Kit.number(box, {
			Text = runTime(tonumber(data.time) or 0),
			TextSize = 44,
			Size = UDim2.new(1, -20, 0, 48),
			Position = UDim2.fromOffset(10, 106),
			TextColor3 = if assisted then C.TextDim else C.Text,
		})
		if assisted then
			-- A grey ribbon instead of the best / rank line.
			Kit.pill(box, {
				Name = "Assisted",
				Text = "ASSISTED RUN  ·  NO BEST TIME",
				Font = Theme.Fonts.Display,
				TextSize = T.Small,
				Color = FINISH.AssistedMedal,
				Solid = true,
				Size = UDim2.fromOffset(290, 24),
				Position = UDim2.new(0.5, 0, 0, 155),
				AnchorPoint = Vector2.new(0.5, 0),
				ZIndex = 3,
			})
		else
			local sub = "Best " .. runTime(tonumber(data.best) or tonumber(data.time) or 0)
			if type(data.rank) == "number" then
				sub ..= "  ·  #" .. tostring(data.rank) .. " on this server"
			end
			Kit.text(box, {
				Name = "Best",
				Text = sub,
				TextSize = T.Body,
				Size = UDim2.new(1, -30, 0, 22),
				Position = UDim2.fromOffset(15, 156),
				TextColor3 = C.TextDim,
				StrokeThickness = 0,
			})
		end
		-- Runs that pay nothing (gear on inside the cooldown) get no empty "+$0" row.
		local well = Kit.well(box, { Glass = true, Size = UDim2.new(1, -40, 0, 62), Position = UDim2.fromOffset(20, wellY) })
		well.Visible = hasWell
		local cashLabel = cashRow(well, cashTotal)
		if repeatRun then
			-- A clean run inside the cooldown pays a share of the map's reward: say which.
			local share = math.floor((tonumber(data.repeatShare) or Economy.MODE_REPEAT_SHARE) * 100 + 0.5)
			Kit.text(well, {
				Name = "RepeatCaption",
				Text = "RUN AGAIN",
				Font = Theme.Fonts.Display,
				TextSize = T.Small,
				TextXAlignment = Enum.TextXAlignment.Left,
				Size = UDim2.new(0, 110, 1, 0),
				Position = UDim2.fromOffset(14, 0),
				TextColor3 = C.TextDim,
				StrokeThickness = 0,
			})
			Kit.pill(well, {
				Name = "RepeatShare",
				Text = string.format("+%d%%", share),
				Font = Theme.Fonts.Display,
				TextSize = T.Body,
				Color = FINISH.CoolColor,
				Solid = true,
				Size = UDim2.fromOffset(70, 28),
				Position = UDim2.new(1, -12, 0.5, 0),
				AnchorPoint = Vector2.new(1, 0.5),
				ZIndex = 3,
			})
		end
		-- The cooldown as a clock: a padlock and a bar that fills until the full reward is back.
		if cooling then
			local span = math.max(Economy.MODE_REWARD_COOLDOWN, 1)
			Kit.icon(box, "Lock", FINISH.CoolH - 2, C.Gold, { Position = UDim2.fromOffset(22, coolY + 1) })
			local track, setCool, coolLabel = Kit.progress(box, {
				Name = "Cooldown",
				Glass = true,
				Color = FINISH.CoolColor,
				TextSize = T.Small,
				Size = UDim2.new(1, -76, 0, FINISH.CoolH),
				Position = UDim2.fromOffset(56, coolY),
			})
			coolLabel.TextColor3 = C.Text
			task.spawn(function()
				local first = true
				while track.Parent do
					local left = cooldownEnds - os.time()
					coolLabel.Text = if left > 0 then "Full reward in " .. Format.time(left) else "Full reward ready next run!"
					setCool(1 - left / span, first)
					first = false
					task.wait(1)
				end
			end)
		end
		local unlockChip: TextLabel? = nil
		if banner then
			unlockChip = Kit.pill(box, {
				Name = "Unlocked",
				Text = banner,
				Font = Theme.Fonts.Display,
				TextSize = T.H2,
				Color = if complete then C.Gold else C.Good,
				Solid = true,
				Size = UDim2.new(1, -40, 0, FINISH.UnlockH),
				Position = UDim2.fromOffset(20, bannerY),
				ZIndex = 3,
			})
		end
		Kit.text(box, {
			Name = "Note",
			Text = if complete
				then "Every map cleared. Now beat your best times!"
				elseif data.pay == "assisted" then "Gear on: no bonus"
				elseif resting and restLeft > 0 then "Bonus is resting, back in " .. Format.time(restLeft)
				elseif resting then "Bonus is resting"
				elseif repeatRun then "The full reward comes back when the bar fills."
				elseif firstClear then "First clear reward!"
				else "Nice run! Try to beat your best.",
			TextSize = T.Small,
			Size = UDim2.new(1, -40, 0, 22),
			Position = UDim2.fromOffset(20, noteY),
			TextColor3 = C.Text,
			StrokeThickness = 0,
		})
		-- With a next level: [Next level] [Run again] and a slim "Back to my gym" below.
		local rowY = if hasNext or hasPick then -128 else -74
		local nextButton: TextButton? = nil
		if hasNext then
			nextButton = Kit.button(box, {
				Name = "Next",
				Text = "Next map ▶",
				Font = Theme.Fonts.Display,
				Color = C.Gold,
				Breathe = true,
				Size = UDim2.new(0.5, -26, 0, 56),
				Position = UDim2.new(0, 20, 1, rowY),
			}, function()
				close()
				if onNext then
					onNext()
				end
			end)
		end
		local again = Kit.button(box, {
			Text = "Run again",
			Font = Theme.Fonts.Display,
			Color = if hasNext then C.SurfaceHi else C.Gold,
			Breathe = not hasNext,
			Size = UDim2.new(0.5, -26, 0, 56),
			Position = if hasNext then UDim2.new(0.5, 6, 1, rowY) else UDim2.new(0, 20, 1, rowY),
		}, function()
			close()
			onAgain()
		end)
		-- Slim second row: [Choose map] [Back to my gym] with a next level, else a full-width
		-- [Choose map] under [Run again] [Back to my gym].
		local homeSize = UDim2.new(0.5, -26, 0, 56)
		local homePos = UDim2.new(0.5, 6, 1, rowY)
		if hasNext then
			homeSize = if hasPick then UDim2.new(0.5, -26, 0, 42) else UDim2.new(1, -40, 0, 42)
			homePos = if hasPick then UDim2.new(0.5, 6, 1, -60) else UDim2.new(0, 20, 1, -60)
		end
		local home = Kit.button(box, {
			Text = "Back to my gym",
			Color = C.SurfaceHi,
			TextSize = if hasNext then T.Body else nil,
			Size = homeSize,
			Position = homePos,
		}, function()
			close()
			onHome()
		end)
		local pick: TextButton? = nil
		if onPick then
			pick = Kit.button(box, {
				Name = "ChooseMap",
				Text = "Choose map",
				Color = C.SurfaceHi,
				TextSize = T.Body,
				Size = if hasNext then UDim2.new(0.5, -26, 0, 42) else UDim2.new(1, -40, 0, 42),
				Position = UDim2.new(0, 20, 1, -60),
			}, function()
				close()
				onPick()
			end)
		end
		-- Gamepad starts on the loud button; B is "Back to my gym".
		local primary: GuiObject = nextButton or again
		primary:SetAttribute("FocusFirst", true)
		onBack(close, function()
			close()
			onHome()
		end)
		Kit.appear(box)
		Kit.appear(medal, { from = 0.4, time = 0.32, delay = 0.06 })
		if nextButton then
			Kit.appear(nextButton, { from = 0.8, time = 0.26, delay = 0.12 })
		end
		Kit.appear(again, { from = 0.8, time = 0.26, delay = 0.14 })
		Kit.appear(home, { from = 0.8, time = 0.26, delay = 0.18 })
		if pick then
			Kit.appear(pick, { from = 0.8, time = 0.26, delay = 0.2 })
		end
		-- Confetti: none for an assisted run, one burst for a clean one, a row of bursts from
		-- across the card's top for a first clear.
		local bursts = if assisted then 0 elseif complete then FINISH.CompleteBursts elseif firstClear then FINISH.FirstBursts else 1
		if calm then
			bursts = math.min(bursts, 1)
		end
		for i = 1, bursts do
			local x = if i == 1 then 0.5 elseif i % 2 == 0 then 0.14 else 0.86
			after((i - 1) * FINISH.BurstGap, function()
				if box.Parent then
					Kit.confetti(box, {
						Origin = UDim2.fromScale(x, 0.1),
						Count = if firstClear then FINISH.Confetti else 24,
						ZIndex = 60,
						Power = if firstClear then 1.15 else 1,
					})
				end
			end)
		end
		if unlockChip then
			local chip = unlockChip
			chip.Visible = false
			after(FINISH.UnlockAt, function()
				if not chip.Parent then
					return
				end
				chip.Visible = true
				Kit.pop(chip, 1.3)
				sounds.play("BuyPop")
			end)
		end
		after(0.12, function()
			Kit.pop(timeLabel, 1.2)
		end)
		after(0.25, function()
			Kit.countTo(cashLabel, 0, cashTotal, function(n)
				return "+" .. Format.money(n)
			end, FINISH.CashRoll)
		end)
		if hasWell and not calm then
			-- The amount lands with a pop once it has counted up.
			after(0.25 + FINISH.CashRoll, function()
				if cashLabel.Parent then
					Kit.pop(cashLabel, 1.18)
				end
			end)
		end
		sounds.play("Reward")
	end)
end

--[[
	The MOG TEST finish card, in the same language as the Parkour one: the score,
	"NEW BEST!", rivals mogged, best and the rank ("#N all-time" from `globalRank`, the saved
	best's place on the all-time TOP MOGGERS list, else "#N on this server" from `rank`), the
	reward rolling up, and under it "Run again bonus +$X (20%)" for a pass inside the cooldown
	(`pay` = "repeat"), "Bonus is resting, back in m:ss" for one inside the repeat gap (`pay` =
	"resting", `repeatRest` seconds) or the "Reward again in m:ss" line while the full reward
	cools down.
	"Mog again" and "Back to my gym". `data` is the mog finish Notify payload (score, rivals,
	best, newBest, passed, cash, full, cooldownEnds, rank?, globalRank?, pay?, repeatShare?).

	A 1v1 duel (data.vs == "pvp": won, reason "ko" | "forfeit", opponent { userId, name },
	score, wins, played, cash, full, cooldownEnds, afk?, rounds?, draw?, close?) uses the
	same card: "YOU MOGGED <name>!" in gold, "<name> MOGGED YOU" in red or a plain "DRAW!",
	duels won / played, the reward (the winner's) and "Duel again" instead of "Mog again".
	The line under the reward says how it ended: an idle forfeit (afk), a player who left
	(forfeit), a draw, and "So close!" only for a loss the server calls close (data.close: a
	small HP margin or sudden death).
]]
function Popups.mogFinish(data: { [string]: any }, onAgain: () -> (), onHome: () -> ())
	-- Nothing to show: the player left the duel themselves, or the test ended with no score,
	-- no pass and no cash. A line says so; no card stands in the way out.
	if not PREVIEW then
		if data.vs == "pvp" then
			if data.won ~= true and data.draw ~= true and data.reason == "forfeit" and data.afk ~= true then
				Popups.toast("You left the duel", "info")
				return
			end
		elseif (tonumber(data.score) or 0) <= 0 and data.passed ~= true and (tonumber(data.cash) or 0) <= 0 then
			Popups.toast("Mog test over. Try again at the gate!", "info")
			return
		end
	end
	Popups.enqueue("MogFinish", Popups.PRIORITY.Normal, function(done)
		local score = tonumber(data.score) or 0
		local cashTotal = tonumber(data.cash) or 0
		local cooldownLeft = math.max(0, (tonumber(data.cooldownEnds) or 0) - os.time())
		local cooling = data.full == false and cooldownLeft > 0
		-- Inside the cooldown a pass (or a duel really fought and won) pays the run again bonus.
		local repeatLine: string? = nil
		if data.pay == "repeat" and cashTotal > 0 then
			local share = math.floor((tonumber(data.repeatShare) or Economy.MODE_REPEAT_SHARE) * 100 + 0.5)
			repeatLine = string.format("Run again bonus +%s (%d%%)", Format.money(cashTotal), share)
		end
		-- Earned, but the last bonus was paid a moment ago (the server's repeat gap).
		local restEnds = os.clock() + math.max(0, tonumber(data.repeatRest) or 0)
		local function restLine(): string
			local left = math.ceil(restEnds - os.clock())
			return if left > 0 then "Bonus is resting, back in " .. Format.time(left) else "Bonus is resting"
		end
		if data.pay == "resting" then
			repeatLine = restLine()
		end
		local duel = data.vs == "pvp"
		local won = duel and data.won == true
		local draw = duel and data.draw == true
		local lost = duel and not won and not draw
		local foe = if duel and type(data.opponent) == "table" then tostring(data.opponent.name or "Opponent") else "Opponent"
		local box, close = modal("MogFinish", Vector2.new(480, 380), 45, nil, function()
			Popups.finishCards[done] = nil
			done()
		end)
		Popups.watchFinish(done, close)
		local medal = medallion(
			box,
			if lost then "😤" elseif draw then "🤝" else "💪",
			if lost then C.Bad elseif draw then C.SurfaceHi else C.Gold,
			84,
			UDim2.new(0.5, 0, 0, 0)
		)
		Kit.title(box, {
			Text = if draw
				then "DRAW!"
				elseif duel then (if won then "YOU MOGGED " .. string.upper(foe) .. "!" else string.upper(foe) .. " MOGGED YOU")
				elseif data.newBest then "NEW BEST!"
				else "MOG TEST OVER",
			TextScaled = duel,
			TextSize = T.H1,
			TextWrapped = false,
			Size = UDim2.new(1, -20, 0, 34),
			Position = UDim2.fromOffset(10, 48),
			TextColor3 = if lost then C.Bad elseif draw then C.Text else C.Gold,
		})
		local scoreLabel = Kit.number(box, {
			Text = "0",
			TextSize = 44,
			Size = UDim2.new(1, -20, 0, 48),
			Position = UDim2.fromOffset(10, 84),
			TextColor3 = C.Text,
		})
		local sub = "Rivals mogged " .. tostring(tonumber(data.rivals) or 0)
		sub ..= "  ·  Best " .. Format.short(math.max(tonumber(data.best) or 0, score))
		if duel then
			sub = "Duels won " .. tostring(tonumber(data.wins) or 0) .. "  ·  Played " .. tostring(tonumber(data.played) or 0)
		elseif type(data.globalRank) == "number" then
			-- The saved best's place on the all-time TOP MOGGERS list.
			sub ..= "  ·  #" .. tostring(data.globalRank) .. " all-time"
		elseif type(data.rank) == "number" then
			sub ..= "  ·  #" .. tostring(data.rank) .. " on this server"
		end
		Kit.text(box, {
			Text = sub,
			TextSize = T.Body,
			Size = UDim2.new(1, -30, 0, 22),
			Position = UDim2.fromOffset(15, 134),
			TextColor3 = C.TextDim,
			StrokeThickness = 0,
		})
		local well = Kit.well(box, { Glass = true, Size = UDim2.new(1, -40, 0, 62), Position = UDim2.fromOffset(20, 164) })
		well.Visible = cashTotal > 0
		local cashLabel = cashRow(well, cashTotal)
		local note = Kit.text(box, {
			Text = if draw
				then "Draw! Nobody won."
				elseif duel and data.afk == true then (if won
					then foe .. " stopped pressing. The win is yours!"
					else "You stopped pressing, so the duel ended.")
				elseif duel and data.reason == "forfeit" then (if won
					then foe .. " left the duel. The win is yours!"
					else "You left the duel.")
				elseif lost and data.close == true then "So close! Hit PERFECT to deal double damage."
				elseif lost then "Good duel! Hit PERFECT to deal double damage."
				elseif repeatLine and cooling then repeatLine .. "  ·  full reward in " .. Format.time(cooldownLeft)
				elseif repeatLine then repeatLine
				elseif cooling then "Reward again in " .. Format.time(cooldownLeft)
				elseif duel then "Total mog! Can you win another?"
				elseif data.passed then "MOG TEST PASSED! Can you mog even more?"
				else "Nice try! Mog more rivals to pass.",
			TextSize = T.Small,
			Size = UDim2.new(1, -40, 0, 22),
			Position = UDim2.fromOffset(20, 232),
			TextColor3 = C.TextDim,
			StrokeThickness = 0,
		})
		local again = Kit.button(box, {
			Text = if duel then "Duel again" else "Mog again",
			Font = Theme.Fonts.Display,
			Color = C.Gold,
			Breathe = true,
			Size = UDim2.new(0.5, -26, 0, 56),
			Position = UDim2.new(0, 20, 1, -74),
		}, function()
			close()
			onAgain()
		end)
		local home = Kit.button(box, {
			Text = "Back to my gym",
			Color = C.SurfaceHi,
			Size = UDim2.new(0.5, -26, 0, 56),
			Position = UDim2.new(0.5, 6, 1, -74),
		}, function()
			close()
			onHome()
		end)
		again:SetAttribute("FocusFirst", true)
		onBack(close, function()
			close()
			onHome()
		end)
		Kit.appear(box)
		Kit.appear(medal, { from = 0.4, time = 0.32, delay = 0.06 })
		Kit.appear(again, { from = 0.8, time = 0.26, delay = 0.14 })
		Kit.appear(home, { from = 0.8, time = 0.26, delay = 0.18 })
		if data.newBest or data.passed or won then
			Kit.confetti(box, { Origin = UDim2.fromScale(0.5, 0.1), Count = 24, ZIndex = 60 })
		end
		after(0.1, function()
			Kit.countTo(scoreLabel, 0, score, Format.short, 0.6)
		end)
		after(0.72, function()
			Kit.pop(scoreLabel, 1.2)
		end)
		after(0.25, function()
			Kit.countTo(cashLabel, 0, cashTotal, function(n)
				return "+" .. Format.money(n)
			end, 0.8)
		end)
		if cooling and not (duel and (not won or data.reason == "forfeit")) then
			task.spawn(function()
				while note.Parent do
					local left = (tonumber(data.cooldownEnds) or 0) - os.time()
					-- The bonus line stays in front of the clock (a resting one counts down too).
					local lead = if data.pay == "resting" then restLine() else repeatLine
					note.Text = if lead and left > 0
						then lead .. "  ·  full reward in " .. Format.time(left)
						elseif left > 0 then "Reward again in " .. Format.time(left)
						else "Reward ready next run!"
					task.wait(1)
				end
			end)
		end
		sounds.play("Reward")
	end)
end

--[[
	The MOG TEST picker, opened by walking through the mog gate (Notify "choose") or the
	Modes window's PLAY: two big cards side by side. VS RIVALS (solo: mog 3 rival chads to
	pass) and 1v1 DUEL (out-mog a real player; hit = 1 damage, perfect = 2, a miss hurts
	you; the winner takes the reward). Each card's button closes the picker and runs its
	callback; the backdrop just closes it. `onClosed` runs once the picker is gone either way.
]]
function Popups.mogChoose(onRivals: () -> (), onPvp: () -> (), onClosed: (() -> ())?)
	Popups.enqueue("MogChoose", Popups.PRIORITY.Normal, function(done)
		local box, close = modal("MogChoose", Vector2.new(560, 374), 45, nil, function()
			done()
			if onClosed then
				onClosed()
			end
		end)
		-- The badge sits astride the card's top edge (raised a little so its lip and
		-- shadow clear the title below).
		local medal = medallion(box, "💪", C.Gold, 84, UDim2.new(0.5, 0, 0, -8))
		Kit.title(box, {
			Text = "MOG TEST",
			TextSize = T.H1,
			TextWrapped = false,
			Size = UDim2.new(1, -20, 0, 34),
			Position = UDim2.fromOffset(10, 56),
			TextColor3 = C.Gold,
		})
		Kit.text(box, {
			Text = "Who do you want to mog?",
			TextSize = T.Body,
			Size = UDim2.new(1, -30, 0, 22),
			Position = UDim2.fromOffset(15, 92),
			TextColor3 = C.TextDim,
			StrokeThickness = 0,
		})
		local function card(
			x: number,
			icon: string,
			color: Color3,
			title: string,
			blurb: string,
			label: string,
			pick: () -> ()
		): (Frame, TextButton)
			local panel = Kit.panel(box, {
				Name = title,
				Glass = true,
				Elevated = true,
				Size = UDim2.new(0.5, -28, 0, 226),
				Position = UDim2.new(x, if x == 0 then 20 else 8, 0, 128),
				Radius = Kit.RADIUS.L,
				StrokeThickness = 3,
				StrokeColor = color,
				ZIndex = 46,
			})
			Kit.title(panel, {
				Text = icon,
				TextSize = 44,
				Size = UDim2.new(1, 0, 0, 52),
				Position = UDim2.fromOffset(0, 8),
				StrokeThickness = 0,
				ZIndex = 47,
			})
			Kit.title(panel, {
				Text = title,
				TextSize = 26,
				TextWrapped = false,
				TextColor3 = color,
				Size = UDim2.new(1, -16, 0, 30),
				Position = UDim2.fromOffset(8, 62),
				ZIndex = 47,
			})
			Kit.text(panel, {
				-- Full-white body text: TextDim at Small size was too faint on the card.
				Text = blurb,
				TextSize = T.Small + 2,
				TextColor3 = C.Text,
				Size = UDim2.new(1, -20, 0, 62),
				Position = UDim2.fromOffset(10, 94),
				StrokeThickness = 0,
				ZIndex = 47,
			})
			local button = Kit.button(panel, {
				Text = label,
				Font = Theme.Fonts.Display,
				Color = color,
				Size = UDim2.new(1, -24, 0, 52),
				Position = UDim2.new(0, 12, 1, -64),
				ZIndex = 48,
			}, function()
				close()
				pick()
			end)
			return panel, button
		end
		local rivals, rivalsGo = card(0, "🏋️", C.Gold, "VS RIVALS", "Solo: mog 3 rival chads to pass the test!", "PLAY", onRivals)
		local duel, duelGo =
			card(0.5, "⚔️", C.Bad, "1v1 DUEL", "Out-mog a real player! PERFECT hits twice. Winner gets the reward.", "FIND DUEL", onPvp)
		Kit.breathe(duelGo)
		rivalsGo:SetAttribute("FocusFirst", true)
		Kit.appear(box)
		Kit.appear(medal, { from = 0.4, time = 0.32, delay = 0.06 })
		Kit.appear(rivals, { from = 0.8, time = 0.26, delay = 0.1 })
		Kit.appear(duel, { from = 0.8, time = 0.26, delay = 0.16 })
		Kit.appear(rivalsGo, { from = 0.8, time = 0.24, delay = 0.2 })
		sounds.play("Toast")
	end)
end

-- Starter pack -------------------------------------------------------------------------------
--[[
	The one-time Starter pack offer and the card that celebrates the grant.
	The offer shows at most once per session, only to players who do not own the
	pack: a few seconds after the tutorial finishes, or a minute after joining for
	returning players. It waits while the intro plays, while a window, another
	popup or the held-crate panel is up, and for a few calm seconds after a popup
	closes. A plain close button, no timers.
]]

local STARTER = Theme.Cosmetics.Starter
local OFFER_AFTER_JOIN = 60
local OFFER_AFTER_TUTORIAL = 6
local CALM = 4

-- The two things in the pack in a well: cash and the Rookie Trail. Returns the cash
-- amount label and the trail's icon (for the celebration's pop-in).
local function starterContents(box: Frame, y: number, trailCaption: string): (TextLabel, Frame)
	local well = Kit.well(box, { Name = "Contents", Glass = true, Size = UDim2.new(1, -40, 0, 100), Position = UDim2.fromOffset(20, y) })
	local function cell(
		index: number,
		icon: string,
		fallback: string,
		color: Color3,
		textColor: Color3,
		caption: string
	): (TextLabel, Frame)
		local holder = Kit.new("Frame", {
			Name = "Item" .. index,
			BackgroundTransparency = 1,
			Size = UDim2.new(1 / 2, 0, 1, 0),
			Position = UDim2.fromScale((index - 1) / 2, 0),
			Parent = well,
		})
		local art = Kit.icon(holder, Kit.pickIcon(icon, fallback), 46, color, {
			Name = "Icon",
			Position = UDim2.new(0.5, 0, 0, 6),
			AnchorPoint = Vector2.new(0.5, 0),
		})
		local amount = Kit.number(holder, {
			Name = "Amount",
			Text = "",
			TextSize = 22,
			MaxTextSize = 22,
			TextScaled = true,
			Size = UDim2.new(1, -16, 0, 24),
			Position = UDim2.fromOffset(8, 54),
			TextColor3 = textColor,
			StrokeThickness = 0,
		})
		Kit.text(holder, {
			Name = "Caption",
			Text = caption,
			TextSize = T.Small,
			TextWrapped = false,
			Size = UDim2.new(1, -12, 0, 18),
			Position = UDim2.fromOffset(6, 77),
			TextColor3 = C.TextDim,
			StrokeThickness = 0,
		})
		return amount, art
	end
	local cash = cell(1, "Coin", "Coin", C.Gold, C.MoneyText, "cash")
	local item = Theme.Cosmetics.Items[STARTER.Item]
	local trail, trailArt = cell(2, item.Icon, "Star", item.Color, C.Text, trailCaption)
	trail.Text = item.Title
	return cash, trailArt
end

-- The pack's art standing over the top edge of a modal, with slow mint rays behind the box.
local function starterArt(box: Frame, size: number): Frame
	local holder = box.Parent :: Frame
	local top = (holder.Size.Y.Offset - box.Size.Y.Offset) / 2
	local rays = Popups.rays(holder, World.Mint, size * 2.2, UDim2.new(0.5, 0, 0, top - 4), 1, 7)
	rays.ZIndex = 0
	Kit.appear(rays, { from = 0.3, time = 0.5, style = Enum.EasingStyle.Quart })
	local art = Kit.icon(box, Kit.pickIcon(STARTER.Icon, "Star"), size, C.Gold, {
		Name = "Art",
		Position = UDim2.new(0.5, 0, 0, -4),
		AnchorPoint = Vector2.new(0.5, 0.5),
		ZIndex = 4,
	})
	return art
end

-- A round coral X in the top-right corner of a modal (52 px hit area).
local function closeButton(box: Frame, onClick: () -> ()): TextButton
	local close = Kit.button(box, {
		Name = "Close",
		Icon = "Close",
		IconColor = C.Text,
		Color = C.Danger,
		Size = UDim2.fromOffset(40, 40),
		Position = UDim2.new(1, -12, 0, 12),
		AnchorPoint = Vector2.new(1, 0),
		Radius = 20,
		Depth = 4,
		Sound = "Close",
		ZIndex = 5,
	}, onClick)
	local face = Kit.buttonFace(close)
	local icon = face and face:FindFirstChild("Icon")
	if icon and icon:IsA("GuiObject") then
		icon.Position = UDim2.fromScale(0.5, 0.5)
		icon.AnchorPoint = Vector2.new(0.5, 0.5)
	end
	Kit.hitArea(close, 52, function()
		Kit.sound("Close")
		onClick()
	end)
	return close
end

-- The offer: what is inside (with this player's own amounts), the price and "Not now".
function Popups.starterOffer()
	Popups.enqueue("StarterOffer", Popups.PRIORITY.Normal, function(done)
		local data = State.data
		if not data or Windows.cosmeticsOf(data).starterOwned == true then
			done()
			return
		end
		local pass = Theme.Monetization.Passes[STARTER.Pass]
		local box, close = modal("StarterOffer", Vector2.new(520, 360), 47, nil, done)
		local art = starterArt(box, 132)
		Kit.title(box, {
			Name = "Title",
			Text = "STARTER PACK",
			TextSize = T.H1,
			TextWrapped = false,
			Size = UDim2.new(1, -120, 0, 36),
			Position = UDim2.fromOffset(60, 70),
			TextColor3 = C.Gold,
		})
		Kit.text(box, {
			Name = "Text",
			Text = "A head start for your gym, once per player.",
			TextSize = T.Body,
			TextWrapped = false,
			Size = UDim2.new(1, -40, 0, 22),
			Position = UDim2.fromOffset(20, 108),
			TextColor3 = C.TextDim,
			StrokeThickness = 0,
		})
		local cash = starterContents(box, 142, "only in this pack")
		cash.Text = State.money(Windows.starterAmounts(data))
		local buy = Kit.button(box, {
			Name = "Buy",
			Text = Kit.ROBUX .. " " .. tostring(pass.Price),
			Font = Theme.Fonts.Number,
			Color = C.Gold,
			Shimmer = true,
			Size = UDim2.new(0.5, -24, 0, 58),
			Position = UDim2.new(0, 16, 1, -76),
		}, function()
			close()
			Net.event("Action"):FireServer({ action = "PromptPass", name = STARTER.Pass })
		end)
		buy:SetAttribute("FocusFirst", true)
		local later = Kit.button(box, {
			Name = "Later",
			Text = "Not now",
			Color = C.SurfaceHi,
			Size = UDim2.new(0.5, -24, 0, 58),
			Position = UDim2.new(0.5, 8, 1, -76),
			Sound = "Close",
		}, close)
		local x = closeButton(box, close)
		Kit.appear(box)
		Kit.appear(art, { from = 0.4, time = 0.34, delay = 0.06 })
		local buttons: { GuiObject } = { buy, later, x }
		Kit.stagger(buttons, 0.04)
	end)
end

-- The grant landed: what the pack gave, cash rolling up and the trail popping in.
function Popups.starter(data: { [string]: any })
	-- Never over the intro: hold the card until it has finished.
	local player = Players.LocalPlayer
	if not PREVIEW and player and player:GetAttribute("IntroPlaying") == true then
		task.spawn(function()
			while player:GetAttribute("IntroPlaying") == true do
				task.wait(0.5)
			end
			task.wait(1)
			Popups.starter(data)
		end)
		return
	end
	Popups.enqueue("Starter", Popups.PRIORITY.Normal, function(done)
		local box, close = modal("StarterDone", Vector2.new(520, 344), 47, nil, done)
		local art = starterArt(box, 132)
		Kit.title(box, {
			Name = "Title",
			Text = "STARTER PACK UNLOCKED!",
			TextSize = T.H1,
			MaxTextSize = T.H1,
			TextScaled = true,
			TextWrapped = false,
			Size = UDim2.new(1, -60, 0, 36),
			Position = UDim2.fromOffset(30, 70),
			TextColor3 = C.Gold,
		})
		Kit.text(box, {
			Name = "Text",
			Text = "Thanks for the support! Here is what you got:",
			TextSize = T.Body,
			TextWrapped = false,
			Size = UDim2.new(1, -40, 0, 22),
			Position = UDim2.fromOffset(20, 108),
			TextColor3 = C.TextDim,
			StrokeThickness = 0,
		})
		local cash, trailArt = starterContents(box, 142, "now in your shop")
		cash.Text = State.money(0)
		local go = Kit.button(box, {
			Name = "Go",
			Text = "Awesome!",
			Font = Theme.Fonts.Display,
			Color = C.Gold,
			Breathe = true,
			Size = UDim2.new(1, -40, 0, 58),
			Position = UDim2.new(0.5, 0, 1, -18),
			AnchorPoint = Vector2.new(0.5, 1),
		}, close)
		go:SetAttribute("FocusFirst", true)
		Kit.appear(box)
		Kit.appear(art, { from = 0.4, time = 0.34, delay = 0.06 })
		Kit.appear(go, { from = 0.8, time = 0.26, delay = 0.2 })
		local cashTotal = tonumber(data.cash) or 0
		after(0.2, function()
			Kit.countTo(cash, 0, cashTotal, State.money, 0.8)
		end)
		trailArt.Visible = false
		after(0.6, function()
			Kit.appear(trailArt, { from = 0.3, time = 0.34 })
			after(0.36, function()
				Kit.pop(trailArt, 1.4)
			end)
		end)
		if not PREVIEW then
			Kit.confetti(box, { Origin = UDim2.fromScale(0.5, 0.1), Count = 28, ZIndex = 60 })
		end
		sounds.play("Reward")
	end)
end

-- Finds a calm moment for the one Starter offer of this session (see the header above).
local function watchStarterOffer()
	if PREVIEW then
		return
	end
	local player = Players.LocalPlayer
	local eligibleAt: number? = nil
	local first = true
	local sawTutorial = false
	State.changed.Event:Connect(function(data)
		if eligibleAt then
			return
		end
		if first then
			first = false
			if data.tutorialDone == true then
				eligibleAt = os.clock() + OFFER_AFTER_JOIN
				return
			end
			sawTutorial = true
		elseif sawTutorial and data.tutorialDone == true then
			eligibleAt = os.clock() + OFFER_AFTER_TUTORIAL
		end
	end)
	task.spawn(function()
		while true do
			task.wait(2)
			local data = State.data
			if data and Windows.cosmeticsOf(data).starterOwned == true then
				return
			end
			local now = os.clock()
			local calm = data ~= nil
				and eligibleAt ~= nil
				and now >= eligibleAt
				and not busy
				and #queue == 0
				and now - lastModalAt >= CALM
				and screen:GetAttribute("WindowOpen") ~= true
				and player:GetAttribute("IntroPlaying") ~= true
				and data.heldChest == nil
			if calm then
				Popups.starterOffer()
				return
			end
		end
	end)
end

-- Held crate panel -----------------------------------------------------------------------------

-- The Crate Smasher's first pad (a Guide target) and how long the panel's arrow points at it.
local SMASHER_PAD = "Unlock1"
local SMASHER_ARROW = 30

--[[
	Side panel while the player carries a crate: the crate and its rarity in the
	header, the odds (rarity-dot rows; bars fill), then the ways to open it, the free
	one first. A gold "Carry it to the Crate Smasher / FREE" button with the Smasher's
	timer for this rarity leads (tapping it points the guide arrow at the Smasher); the
	paid "Open now" is a small neutral button under it, the Crate Master pass a quiet
	text link, and at the bottom, well apart, sits a red Discard button (Rare and better
	ask first, with Popups.confirm). A Crate Master owner opens free, so for them "Open
	now" is the gold button and comes first. The card is solid (the world never shows
	through it), PANEL_W wide and as tall as its rows. It never shows while the tutorial
	is running. The "ChestPanel" holder carries the compact-mode UIScale; the "Card"
	inside eases in and out with Kit.appear / Kit.disappear.
	While it is up the ScreenGui attribute "CratePanelOpen" is true (the held
	crate's world chip hides then, so the two labels never show together).
]]
local function buildChestPanel()
	local action = Net.event("Action")
	-- Card geometry: header (crate + rarity), the odds well, then the rows under it.
	-- A phone (touch on a Compact screen) gets the header and the rows only, no odds
	-- list, so the card sits between the gear and the jump button.
	local PANEL_W = 240
	local EDGE = 8
	local HEAD_H = 44
	local ODDS_Y = EDGE + HEAD_H + 24
	local ODDS_ROW, ODDS_GAP = 26, 3
	local FREE_H, OPEN_H, ROW_GAP = 60, 44, 8
	local oddsRows = 1
	local phone = false
	local function measure()
		phone = Kit.touch and screen:GetAttribute("Compact") == true
	end
	measure()
	-- The odds well is as tall as its rows (one row for a first crate, never a list of air).
	local function oddsHeight(): number
		local rows = math.clamp(oddsRows, 1, 4)
		return rows * ODDS_ROW + (rows - 1) * ODDS_GAP + 12
	end
	local holder = Kit.new("Frame", {
		Name = "ChestPanel",
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(PANEL_W, 300),
		Position = UDim2.new(1, -12, 0.5, 30),
		AnchorPoint = Vector2.new(1, 0.5),
		Parent = screen,
	})
	local compactScale = Kit.new("UIScale", { Name = "Compact", Parent = holder })
	-- A solid card, not the windows' glass: it stands over the plot's signs and price
	-- pads all the time, and their text read through a glass pane.
	local panel = Kit.panel(holder, {
		Name = "Card",
		Color = C.Surface,
		Size = UDim2.fromScale(1, 1),
		Position = UDim2.fromScale(0.5, 0.5),
		AnchorPoint = Vector2.new(0.5, 0.5),
		Visible = false,
	})
	-- Header: the crate on the left, its rarity beside it (the name's colour, the divider
	-- under it and the crate itself are painted per crate below).
	local band = Kit.new("Frame", {
		Name = "Band",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, -EDGE * 2, 0, HEAD_H),
		Position = UDim2.fromOffset(EDGE, EDGE),
		Parent = panel,
	})
	local divider = Kit.new("Frame", {
		Name = "Divider",
		BackgroundColor3 = C.Gold,
		BackgroundTransparency = Theme.Glass.Divider,
		BorderSizePixel = 0,
		Size = UDim2.new(1, -4, 0, 1),
		Position = UDim2.new(0.5, 0, 1, 0),
		AnchorPoint = Vector2.new(0.5, 1),
		Parent = band,
	})
	local title = Kit.title(band, {
		Text = "",
		TextSize = T.H3,
		MinPx = 16,
		TextWrapped = false,
		TextXAlignment = Enum.TextXAlignment.Left,
		Size = UDim2.new(1, -52, 1, -4),
		Position = UDim2.fromOffset(50, 0),
	})

	local CRATE_AT = UDim2.fromOffset(EDGE + 24, EDGE + HEAD_H / 2 - 2)
	local halo = Kit.new("Frame", {
		Name = "IconGlow",
		BackgroundColor3 = WHITE,
		BackgroundTransparency = 0.6,
		BorderSizePixel = 0,
		Size = UDim2.fromOffset(42, 42),
		Position = CRATE_AT,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Parent = panel,
	})
	Kit.round(halo)

	local oddsTitle = Kit.title(panel, {
		Name = "OddsTitle",
		Text = "POSSIBLE " .. string.upper(W.Units),
		Font = Theme.Fonts.UI,
		TextSize = 14,
		MinPx = true,
		TextWrapped = false,
		Size = UDim2.new(1, -EDGE * 2 - 8, 0, 18),
		Position = UDim2.fromOffset(EDGE + 4, ODDS_Y - 21),
		TextXAlignment = Enum.TextXAlignment.Left,
		TextColor3 = C.Text,
		StrokeThickness = 0,
	})
	local oddsWell = Kit.well(panel, {
		Name = "Odds",
		Size = UDim2.new(1, -EDGE * 2, 0, oddsHeight()),
		Position = UDim2.fromOffset(EDGE, ODDS_Y),
	})
	local odds = Kit.scrolling(oddsWell, { Name = "List", Size = UDim2.new(1, -8, 1, -8), Position = UDim2.fromOffset(4, 4) })
	Kit.padding(odds, 2, 4)
	Kit.list(odds, ODDS_GAP)

	-- The free route leads: one gold button, two lines ("Carry it to the Crate Smasher",
	-- then FREE and the Smasher's timer for this rarity). Tapping it points the guide
	-- arrow at the Smasher's pad for a while.
	local crackerName = string.gsub(string.lower(W.Unlocker), "%f[%a]%a", string.upper)
	local freeButton = Kit.button(panel, {
		Name = "FreeRoute",
		Text = "",
		Color = C.Gold,
		Size = UDim2.new(1, -EDGE * 2, 0, FREE_H),
		Position = UDim2.fromOffset(EDGE, ODDS_Y),
	}, function()
		Guide.navigate(SMASHER_PAD, string.upper(W.Unlocker), SMASHER_ARROW)
	end)
	freeButton:SetAttribute("FocusFirst", true)
	local freeFace: Instance = Kit.buttonFace(freeButton) or freeButton
	local freeRoute = Kit.text(freeFace, {
		Name = "Route",
		Text = "Carry it to the " .. crackerName,
		Font = Theme.Fonts.UI,
		TextScaled = true,
		MaxTextSize = 15,
		TextWrapped = false,
		TextColor3 = Kit.inkOn(C.Gold),
		Size = UDim2.new(1, -16, 0.38, 0),
		Position = UDim2.new(0, 8, 0.1, 0),
		StrokeThickness = 0,
		ZIndex = 2,
	})
	local freePrice = Kit.title(freeFace, {
		Name = "Free",
		Text = "FREE",
		TextScaled = true,
		MaxTextSize = 22,
		TextWrapped = false,
		TextColor3 = Kit.inkOn(C.Gold),
		Size = UDim2.new(1, -16, 0.44, 0),
		Position = UDim2.new(0, 8, 0.48, 0),
		StrokeThickness = 0,
		ZIndex = 2,
	})

	-- Instant open: free for Crate Master owners ("owner"); otherwise one developer
	-- product (same price for every rarity) with the Crate Master pass as a quiet text
	-- link under it ("buy"). Both purchases are hidden where paid random items are not
	-- allowed ("none"). For a buyer it is the small neutral button under the free route.
	local crateOpen = Theme.Monetization.CrateOpen
	local crateKey = Theme.Monetization.Passes.CrateKey
	local mode = "none"
	local openButton = Kit.button(panel, {
		Name = "OpenNow",
		Text = "Open now",
		Color = C.SurfaceHi,
		Size = UDim2.new(1, -EDGE * 2, 0, OPEN_H),
		Position = UDim2.fromOffset(EDGE, ODDS_Y),
		TextSize = T.Body,
	}, function()
		action:FireServer({ action = "OpenCrateNow" })
	end)
	local masterTag = Kit.pill(panel, {
		Name = "MasterTag",
		Text = string.upper(crateKey.Title),
		Color = crateKey.Color,
		Solid = true,
		TextSize = T.Small,
		Size = UDim2.fromOffset(0, 22),
		AutomaticSize = Enum.AutomaticSize.X,
		Position = UDim2.fromOffset(PANEL_W - 4, ODDS_Y - 10),
		AnchorPoint = Vector2.new(1, 0),
		ZIndex = 6,
		Visible = false,
	})
	-- Quiet text link: the pass that opens every crate free.
	local function textLink(
		name: string,
		text: string,
		color: Color3,
		hover: Color3,
		y: number,
		width: number,
		onClick: () -> ()
	): TextButton
		local link = Kit.new("TextButton", {
			Name = name,
			BackgroundTransparency = 1,
			AutoButtonColor = false,
			RichText = true,
			Text = "<u>" .. text .. "</u>",
			Font = Theme.Fonts.UI,
			TextSize = T.Small,
			TextWrapped = true,
			TextColor3 = color,
			Size = UDim2.fromOffset(width, 30),
			Position = UDim2.new(0.5, 0, 0, y),
			AnchorPoint = Vector2.new(0.5, 0),
			Parent = panel,
		})
		Kit.bouncy(link, 1.04)
		local function lit(on: boolean)
			Kit.tween(link, 0.12, { TextColor3 = if on then hover else color })
		end
		link.MouseEnter:Connect(function()
			lit(true)
		end)
		link.MouseLeave:Connect(function()
			lit(false)
		end)
		link.SelectionGained:Connect(function()
			lit(true)
		end)
		link.SelectionLost:Connect(function()
			lit(false)
		end)
		link.Activated:Connect(onClick)
		-- The link reads 30 px tall; its tap area is 44 (an invisible strip over it).
		local hit = Kit.new("TextButton", {
			Name = "Hit",
			BackgroundTransparency = 1,
			AutoButtonColor = false,
			Selectable = false,
			Text = "",
			Size = UDim2.new(1, 0, 0, 44),
			Position = UDim2.fromScale(0.5, 0.5),
			AnchorPoint = Vector2.new(0.5, 0.5),
			ZIndex = link.ZIndex + 1,
			Parent = link,
		})
		hit.Activated:Connect(onClick)
		return link
	end
	local passLink = textLink(
		"BuyCrateMaster",
		"Open every crate free  " .. Kit.ROBUX .. " " .. crateKey.Price,
		C.TextDim,
		C.GoldLight,
		ODDS_Y,
		PANEL_W - EDGE * 3,
		function()
			Kit.sound("Click")
			action:FireServer({ action = "PromptPass", name = "CrateKey" })
		end
	)
	-- Discard: a red button at the bottom of the card, DISCARD_GAP below the rows above it.
	-- A Common or Uncommon crate goes at once; Rare and better ask first (the same confirm
	-- card as the Smasher's "Smash it now"), so one stray tap never throws away a good crate.
	local DISCARD_H, DISCARD_GAP = 40, 12
	local heldRarity = ""
	local function discardNow()
		action:FireServer({ action = "DiscardChest" })
	end
	local discard = Kit.button(panel, {
		Name = "Discard",
		Text = "Discard",
		Icon = "Close",
		IconColor = WHITE,
		TextColor = WHITE,
		Color = C.Danger,
		Size = UDim2.fromOffset(140, DISCARD_H),
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, ODDS_Y),
		TextSize = T.Body,
		Sound = "Close",
	}, function()
		local rarity = heldRarity
		if (RARITY_RANK[rarity] or 0) < RARITY_RANK.Rare then
			discardNow()
			return
		end
		Popups.confirm(string.format("Discard this %s %s?", rarity, string.lower(W.Chest)), function()
			-- Only the crate that was asked about: it may have been opened meanwhile.
			if heldRarity == rarity then
				discardNow()
			end
		end, { title = "DISCARD?", yes = "Discard", no = "Keep it" })
	end)

	-- Lays the rows out under the odds for the current mode: the free route, the open
	-- button (the other way round for a Crate Master owner), the pass link (buy only),
	-- Discard; the card ends under Discard. Small text holds its size on the glass.
	local function arrange(animate: boolean)
		local hasButton = mode ~= "none"
		local owner = mode == "owner"
		local small = Kit.px(Kit.captionPx(), T.Small, holder)
		local body = Kit.px(Kit.captionPx(), T.Body, holder)
		local wellH = oddsHeight()
		oddsWell.Size = UDim2.new(1, -EDGE * 2, 0, wellH)
		local y = if phone then EDGE + HEAD_H + ROW_GAP else ODDS_Y + wellH + 10
		local freeY, openY = y, y
		if owner then
			freeY = openY + OPEN_H + ROW_GAP
			y = freeY + FREE_H
		else
			openY = freeY + FREE_H + ROW_GAP
			y = if hasButton then openY + OPEN_H else freeY + FREE_H
		end
		openButton.Position = UDim2.fromOffset(EDGE, openY)
		masterTag.Position = UDim2.fromOffset(PANEL_W - 4, openY - 10)
		y += 4
		local linkH = small * 2 + 8
		passLink.TextSize = small
		passLink.Size = UDim2.fromOffset(PANEL_W - EDGE * 3, linkH)
		if mode == "buy" then
			passLink.Position = UDim2.new(0.5, 0, 0, y)
			y += linkH
		end
		y += DISCARD_GAP
		local discardLabel = Kit.buttonLabel(discard)
		if discardLabel then
			discardLabel.TextSize = body
		end
		local freeGoal = { Position = UDim2.fromOffset(EDGE, freeY) }
		local discardGoal = { Position = UDim2.new(0.5, 0, 0, y) }
		local holderGoal = { Size = UDim2.fromOffset(PANEL_W, y + DISCARD_H + 10) }
		if animate then
			Kit.tween(freeButton, 0.25, freeGoal)
			Kit.tween(discard, 0.25, discardGoal)
			Kit.tween(holder, 0.25, holderGoal)
		else
			freeButton.Position = freeGoal.Position
			discard.Position = discardGoal.Position
			holder.Size = holderGoal.Size
		end
	end
	local function setMode(newMode: string)
		if newMode == mode then
			return
		end
		local wasButton = mode ~= "none"
		mode = newMode
		local hasButton = newMode ~= "none"
		local owner = newMode == "owner"
		if hasButton and not wasButton then
			Kit.appear(openButton, { from = 0.9, time = 0.2 })
		elseif not hasButton and wasButton then
			Kit.disappear(openButton)
		end
		-- One gold button per card: the instant open for a Crate Master owner (it is free
		-- for them), the walk to the Smasher for everyone else.
		local freeColor = if owner then C.SurfaceHi else C.Gold
		Kit.setButton(freeButton, nil, freeColor)
		freeRoute.TextColor3 = Kit.inkOn(freeColor)
		freePrice.TextColor3 = Kit.inkOn(freeColor)
		freeButton:SetAttribute("FocusFirst", not owner)
		openButton:SetAttribute("FocusFirst", owner)
		if owner then
			Kit.setButton(openButton, "Open now", C.Gold)
			Kit.appear(masterTag, { from = 0.6, time = 0.25 })
		else
			Kit.setButton(openButton, "Open now   " .. Kit.ROBUX .. " " .. crateOpen.Price, C.SurfaceHi)
			if masterTag.Visible then
				Kit.disappear(masterTag)
			end
		end
		if newMode == "buy" then
			Kit.appear(passLink, { from = 0.9, time = 0.2, delay = 0.05 })
		elseif passLink.Visible then
			Kit.disappear(passLink)
		end
		arrange(true)
	end
	openButton.Visible = false
	passLink.Visible = false

	-- A window, modal or reveal is up: the card would show through its glass pane (and
	-- the dim takes its taps anyway), so it parks off the right edge like the HUD groups.
	local rest = holder.Position
	local away = rest
	local parked = false
	-- Places everything that depends on the card's shape (desktop / phone); the Compact
	-- scale shrinks the desktop card on a short window, the phone card is already small.
	local crate: Frame? = nil
	local function place()
		measure()
		compactScale.Scale = if not phone and screen:GetAttribute("Compact") == true then 0.8 else 1
		rest = if phone then UDim2.new(1, -12, 0.5, -14) else UDim2.new(1, -12, 0.5, 30)
		away = UDim2.new(1, PANEL_W + 40, rest.Y.Scale, rest.Y.Offset)
		holder.Position = if parked then away else rest
		oddsTitle.Visible = not phone
		oddsWell.Visible = not phone
		arrange(false)
	end
	place()
	screen:GetAttributeChangedSignal("Compact"):Connect(place)
	Kit.onInput(function()
		place()
	end)
	Kit.onWindowOpen(function(up: boolean)
		parked = up
		Kit.tween(holder, 0.15, { Position = if up then away else rest }, Enum.EasingStyle.Quad)
	end)

	local function fillOdds(rarity: string, highestTier: number)
		for _, child in odds:GetChildren() do
			if child:IsA("Frame") then
				child:Destroy()
			end
		end
		local rows: { GuiObject } = {}
		for order, entry in Economy.chestOdds(rarity, highestTier) do
			local row = Kit.new("Frame", {
				Name = "Odds" .. order,
				BackgroundTransparency = 1,
				Size = UDim2.new(1, 0, 0, ODDS_ROW),
				LayoutOrder = order,
				Parent = odds,
			})
			local tierBand = Economy.tierBand(entry.tier)
			local tierColor = C.Rarity[tierBand] or C.Gold
			local bar = Kit.new("Frame", {
				Name = "Bar",
				BackgroundColor3 = tierColor,
				BackgroundTransparency = 0.7,
				BorderSizePixel = 0,
				Size = UDim2.fromScale(0, 1),
				Parent = row,
			})
			Kit.corner(bar, 8)
			tweenAfter(bar, 0.5, 0.06 + order * 0.04, { Size = UDim2.fromScale(entry.chance / 100, 1) }, Enum.EasingStyle.Quint)
			-- Rarity dot, then tier number, name and chance.
			local dot = Kit.new("Frame", {
				Name = "Dot",
				BackgroundColor3 = tierColor,
				BorderSizePixel = 0,
				Size = UDim2.fromOffset(10, 10),
				Position = UDim2.new(0, 8, 0.5, 0),
				AnchorPoint = Vector2.new(0, 0.5),
				Parent = row,
			})
			Kit.round(dot)
			Kit.new("UIStroke", { Thickness = 1.5, Color = WHITE, Transparency = 0.2, Parent = dot })
			Kit.number(row, {
				Text = "#" .. entry.tier,
				TextSize = T.Small,
				MinPx = true,
				Size = UDim2.new(0, 28, 1, 0),
				Position = UDim2.fromOffset(24, 0),
				TextXAlignment = Enum.TextXAlignment.Left,
				TextColor3 = C.TextDim,
				StrokeThickness = 0,
			})
			Kit.text(row, {
				Text = Theme.Tiers[entry.tier].Name,
				Font = Theme.Fonts.UI,
				TextSize = 14,
				MinPx = true,
				TextWrapped = false,
				TextTruncate = Enum.TextTruncate.AtEnd,
				Size = UDim2.new(1, -100, 1, 0),
				Position = UDim2.fromOffset(52, 0),
				TextXAlignment = Enum.TextXAlignment.Left,
				TextColor3 = Kit.lighten(tierColor, 0.35),
				StrokeThickness = 0,
			})
			Kit.number(row, {
				Text = entry.chance .. "%",
				TextSize = T.Body,
				MinPx = true,
				Size = UDim2.new(0, 46, 1, 0),
				Position = UDim2.new(1, -4, 0, 0),
				AnchorPoint = Vector2.new(1, 0),
				TextXAlignment = Enum.TextXAlignment.Right,
				StrokeThickness = 0,
			})
			table.insert(rows, row)
		end
		Kit.stagger(rows)
		-- The well, and the rows under it, follow the number of odds rows.
		oddsRows = #rows
		arrange(false)
	end

	local shownFor = ""
	local open = false
	State.changed.Event:Connect(function(data)
		-- No panel (and no Robux button) over the tutorial: a crate held then is still
		-- carried to the Smasher by hand.
		local rarity = if data.tutorialDone == true then data.heldChest else nil
		if rarity == nil or rarity == "" then
			shownFor = ""
			heldRarity = ""
			if open then
				open = false
				Guide.clearNavigate(SMASHER_PAD)
				Kit.unfocus(panel)
				Kit.disappear(panel)
				Kit.hidePlayerList("crate", false)
				screen:SetAttribute("CratePanelOpen", false)
			end
			return
		end
		heldRarity = rarity
		if not open then
			open = true
			-- Fx/Crates hides the held crate's own world chip while this is true.
			screen:SetAttribute("CratePanelOpen", true)
			Kit.appear(panel, { from = 0.85, time = 0.26 })
			-- The default player list sits over the panel's header on short screens.
			Kit.hidePlayerList("crate", true)
			-- The first few crates a player ever holds: the path to the Smasher shows by
			-- itself (later ones on a tap of the gold button).
			if data.crateGuide == true then
				Guide.navigate(SMASHER_PAD, string.upper(W.Unlocker), SMASHER_ARROW * 2)
			end
		end
		local color = C.Rarity[rarity] or C.Gold
		-- The Smasher's time for this very crate, from the server (a profile's first crate
		-- opens in Economy.FIRST_CRATE_SECONDS, not in its rarity's time).
		local freeSeconds = tonumber(data.heldSeconds)
		local key = rarity .. ":" .. data.highestTier .. ":" .. (freeSeconds or -1)
		if key ~= shownFor then
			shownFor = key
			title.Text = string.upper(rarity .. " " .. W.Chest)
			title.TextColor3 = Kit.lighten(color, 0.3)
			divider.BackgroundColor3 = Kit.lighten(color, 0.2)
			halo.BackgroundColor3 = Kit.lighten(color, 0.45)
			freePrice.Text = if freeSeconds then "FREE  •  " .. Format.time(freeSeconds) else "FREE"
			if crate then
				crate:Destroy()
			end
			local icon = crateIcon(panel, color, 40, {
				Rarity = rarity,
				Position = CRATE_AT,
				AnchorPoint = Vector2.new(0.5, 0.5),
				ZIndex = 2,
			})
			crate = icon
			Kit.appear(icon, { from = 0.6, time = 0.3 })
			fillOdds(rarity, data.highestTier)
		end
		-- Pass owners open free; everyone else only where paid random items are allowed.
		local owner = type(data.passes) == "table" and data.passes.CrateKey == true
		setMode(if owner then "owner" elseif data.crateRobux == true then "buy" else "none")
	end)
end

-- Cash pack purchase: full-screen money rain + big count-up (non-blocking) ----------------

-- The Blender gold coin for the rain; the code-drawn "$" coin without it.
local COIN_IMAGE = Sprites.image("CoinSpin")

local function moneyPiece(parent: Instance, bill: boolean, zindex: number): GuiObject
	if not bill and COIN_IMAGE then
		return Kit.new("ImageLabel", {
			Name = "Coin",
			BackgroundTransparency = 1,
			Image = COIN_IMAGE,
			ScaleType = Enum.ScaleType.Fit,
			Size = UDim2.fromOffset(38, 38),
			AnchorPoint = Vector2.new(0.5, 0.5),
			ZIndex = zindex,
			Parent = parent,
		})
	end
	local piece = Kit.new("Frame", {
		Name = if bill then "Bill" else "Coin",
		BackgroundColor3 = WHITE,
		Size = if bill then UDim2.fromOffset(58, 30) else UDim2.fromOffset(34, 34),
		AnchorPoint = Vector2.new(0.5, 0.5),
		ZIndex = zindex,
		Parent = parent,
	})
	if bill then
		Kit.corner(piece, 6)
		Kit.stroke(piece, 2, C.CashDeep)
		Kit.gradient(piece, Kit.lighten(C.Cash, 0.35), C.Cash)
	else
		Kit.round(piece)
		Kit.stroke(piece, 2, C.GoldDeep)
		Kit.gradient(piece, C.GoldLight, C.Gold)
	end
	Kit.title(piece, {
		Text = "$",
		TextSize = 20,
		TextWrapped = false,
		Size = UDim2.fromScale(1, 1),
		Position = UDim2.fromOffset(0, 1),
		TextColor3 = if bill then C.CashDeep else C.GoldDeep,
		ZIndex = zindex,
		StrokeThickness = 0,
	})
	return piece
end

function Popups.purchase(amount: number)
	amount = math.max(tonumber(amount) or 0, 0)
	local old = screen:FindFirstChild("CashRain")
	if old then
		old:Destroy()
	end
	local layer = Kit.new("Frame", {
		Name = "CashRain",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		ZIndex = 50,
		Parent = screen,
	})
	local dim = Kit.new("Frame", {
		Name = "Dim",
		BackgroundColor3 = C.Ink,
		BackgroundTransparency = 0.5,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(2, 2),
		Position = UDim2.fromScale(0.5, 0.5),
		AnchorPoint = Vector2.new(0.5, 0.5),
		ZIndex = 50,
		Parent = layer,
	})
	Kit.appear(dim, { from = 1, time = 0.3 })
	local rays = Popups.rays(layer, Kit.lighten(C.Cash, 0.4), 760, UDim2.fromScale(0.5, 0.42), 51, 10)
	Kit.appear(rays, { from = 0.15, time = 0.5, style = Enum.EasingStyle.Quart })

	local headline = Kit.title(layer, {
		Name = "Amount",
		Text = "+" .. State.money(0) .. "!",
		TextSize = 96,
		TextWrapped = false,
		Size = UDim2.fromOffset(900, 110),
		Position = UDim2.fromScale(0.5, 0.42),
		AnchorPoint = Vector2.new(0.5, 0.5),
		TextColor3 = WHITE,
		StrokeThickness = 0,
		ZIndex = 54,
	})
	Kit.textStroke(headline, 4, 0)
	Kit.new("UIGradient", {
		Color = ColorSequence.new(Color3.fromRGB(240, 255, 246), C.MoneyText),
		Rotation = 90,
		Parent = headline,
	})
	Kit.appear(headline, { from = 0.3, time = 0.4 })
	local sub = Kit.pill(layer, {
		Name = "Sub",
		Text = "💰 CASH PACK! THANK YOU!",
		Solid = true,
		Color = C.Cash,
		TextSize = T.H3,
		Size = UDim2.fromOffset(0, 40),
		AutomaticSize = Enum.AutomaticSize.X,
		Position = UDim2.fromScale(0.5, 0.53),
		AnchorPoint = Vector2.new(0.5, 0.5),
		ZIndex = 54,
	})
	Kit.appear(sub, { from = 0.4, time = 0.32, delay = 0.25 })
	sounds.play("Celebrate")

	-- Count-up (ease-out) with coin ticks and a landing pop.
	local COUNT_TIME = 1.3
	after(0.15, function()
		Kit.countTo(headline, 0, amount, function(n)
			return "+" .. State.money(n) .. "!"
		end, COUNT_TIME)
	end)
	task.spawn(function()
		task.wait(0.15)
		local t = 0
		while t < COUNT_TIME - 0.1 and layer.Parent do
			sounds.play("Coin", 0.03, 0.9 + (t / COUNT_TIME) * 0.6)
			task.wait(0.1)
			t += 0.1
		end
		if layer.Parent then
			sounds.play("Cash")
		end
	end)

	-- Bills and coins raining across the whole UI.
	task.spawn(function()
		for i = 1, 46 do
			if not layer.Parent then
				return
			end
			local piece = moneyPiece(layer, i % 3 ~= 0, if i % 2 == 0 then 52 else 55)
			local x = math.random()
			piece.Position = UDim2.new(x, 0, -0.08, 0)
			piece.Rotation = math.random(-40, 40)
			local fall = 1.3 + math.random() * 0.9
			Kit.tween(piece, fall, {
				Position = UDim2.new(x + (math.random() - 0.5) * 0.15, 0, 1.1, 0),
				Rotation = piece.Rotation + math.random(-280, 280),
			}, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
			task.delay(fall, function()
				piece:Destroy()
			end)
			task.wait(0.035)
		end
	end)
	Kit.confetti(layer, {
		Origin = UDim2.fromScale(0.5, 0.42),
		Count = 40,
		ZIndex = 53,
		Colors = { C.Cash, World.Sunny, World.Mint, World.Blue, WHITE },
		Power = 1.3,
	})

	task.delay(3.3, function()
		if layer.Parent then
			Kit.disappear(layer, { to = 1, time = 0.35, destroy = true })
		end
	end)
end

-- Centre banner, gift card, surge chip (not modal) ------------------------------------------

-- A run on a course owns the screen: no surge notice over it.
local function inRun(): boolean
	for _, name in { "RunActive", "ObbyMode", "CardioActive" } do
		if screen:GetAttribute(name) == true then
			return true
		end
	end
	return false
end

--[[
	Popups.banner(opts): a band of colour right across the screen with one big line on it,
	for a moment that outranks a toast (the surge starting, the tutorial done). It pops in,
	holds and fades by itself; nothing waits for it and it takes no input. opts:
	  Text      the line                    Color     the band (gold)
	  Amount    cash counted up on a dark chip under the line
	  Life      seconds on screen (2)       Confetti  pieces (0), none with reduced motion
	  Sound     name, Pitch                 OnClosed  runs when it has gone
]]
local BANNER_Y = 0.34
function Popups.banner(opts: { [string]: any })
	local color: Color3 = opts.Color or C.Gold
	local life: number = opts.Life or 2
	local amount: number? = if type(opts.Amount) == "number" then opts.Amount else nil
	local titleSize = Kit.px(26, 46, screen)
	local chipH = Kit.px(24, 40, screen) + 8
	local height = 28 + titleSize + (if amount then chipH + 10 else 0) + 24
	local old = screen:FindFirstChild("Banner")
	if old then
		old:Destroy()
	end
	local holder = Kit.new("Frame", {
		Name = "Banner",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, height),
		Position = UDim2.fromScale(0.5, BANNER_Y),
		AnchorPoint = Vector2.new(0.5, 0.5),
		ZIndex = 28,
		Parent = screen,
	})
	-- Wider than any screen, so its ends are never seen (also past the safe area).
	local band = Kit.new("Frame", {
		Name = "Band",
		BackgroundColor3 = WHITE,
		BackgroundTransparency = 0.06,
		BorderSizePixel = 0,
		Size = UDim2.new(3, 0, 1, 0),
		Position = UDim2.fromScale(0.5, 0.5),
		AnchorPoint = Vector2.new(0.5, 0.5),
		ZIndex = 28,
		Parent = holder,
	})
	Kit.gradient(band, Kit.lighten(color, 0.32), Kit.darken(color, 0.1))
	for _, y in { 0, 1 } do
		Kit.new("Frame", {
			Name = "Edge",
			BackgroundColor3 = if y == 0 then WHITE else Kit.lip(color),
			BackgroundTransparency = if y == 0 then 0.3 else 0,
			BorderSizePixel = 0,
			Size = UDim2.new(1, 0, 0, 4),
			Position = UDim2.fromScale(0, y),
			AnchorPoint = Vector2.new(0, y),
			ZIndex = 29,
			Parent = band,
		})
	end
	Kit.hudText(holder, {
		Name = "Title",
		Text = opts.Text or "",
		TextSize = titleSize,
		TextScaled = true,
		MaxTextSize = titleSize,
		Size = UDim2.new(1, -48, 0, titleSize + 8),
		Position = UDim2.fromOffset(24, 22),
		StrokeColor = Theme.Glass.TextInk,
		StrokeThickness = 3.5,
		ZIndex = 29,
	})
	if amount then
		-- The reward: a coin and the amount, on a dark chip so the green holds on the band.
		local chip = Kit.new("Frame", {
			Name = "Reward",
			BackgroundColor3 = C.Ink,
			BackgroundTransparency = 0.12,
			Size = UDim2.fromOffset(0, chipH),
			AutomaticSize = Enum.AutomaticSize.X,
			Position = UDim2.new(0.5, 0, 0, 22 + titleSize + 14),
			AnchorPoint = Vector2.new(0.5, 0),
			ZIndex = 29,
			Parent = holder,
		})
		Kit.round(chip)
		Kit.padding(chip, 0, 16)
		Kit.list(chip, 8, true)
		Kit.icon(chip, "Coin", chipH - 12, C.Gold, { Name = "Coin", LayoutOrder = 1, ZIndex = 30 })
		local label = Kit.number(chip, {
			Name = "Amount",
			Text = "+" .. State.money(amount),
			TextSize = chipH - 10,
			TextColor3 = C.MoneyText,
			Size = UDim2.fromOffset(0, chipH),
			AutomaticSize = Enum.AutomaticSize.X,
			LayoutOrder = 2,
			ZIndex = 30,
		})
		after(0.2, function()
			if holder.Parent then
				Kit.countTo(label, 0, amount, function(n)
					return "+" .. State.money(n)
				end, 0.8)
			end
		end)
	end
	Kit.appear(holder, { from = 0.6, time = 0.32 })
	local confetti: number = if reducedMotion() then 0 else (opts.Confetti or 0)
	if confetti > 0 then
		-- From both ends of the band and its middle.
		for i, x in { 0.5, 0.2, 0.8 } do
			after((i - 1) * 0.12, function()
				if holder.Parent then
					Kit.confetti(holder, { Origin = UDim2.fromScale(x, 0.5), Count = math.ceil(confetti / 3), ZIndex = 30, Power = 1.15 })
				end
			end)
		end
	end
	if opts.Sound then
		sounds.play(opts.Sound, 0, opts.Pitch)
	end
	local closed = false
	local function close()
		if closed then
			return
		end
		closed = true
		if holder.Parent then
			Kit.disappear(holder, { time = 0.25, to = 1.04, destroy = true })
		end
		if opts.OnClosed then
			task.delay(0.25, opts.OnClosed)
		end
	end
	if not PREVIEW then
		task.delay(life, close)
		-- Replaced by a newer banner: its OnClosed still runs.
		holder.AncestryChanged:Connect(function()
			if not holder:IsDescendantOf(game) then
				close()
			end
		end)
	end
end

-- The tutorial's last step is done: "YOU DID IT!" and the cash, with confetti. Goes
-- through the modal queue (`done`), so it never lands on a reveal.
function Popups.tutorialDone(cash: number, done: () -> ())
	Popups.banner({
		Text = "YOU DID IT!",
		Amount = math.max(tonumber(cash) or 0, 0),
		Color = C.Gold,
		Life = 2.5,
		Confetti = 42,
		Sound = "Celebrate",
		OnClosed = done,
	})
	if PREVIEW then
		done()
	end
end

--[[
	The free gift: a small solid card in the middle of the screen (the crate panel's solid
	style: it stands over the plot's signs, and their text read through glass) with the gift
	badge, the cash counting up over a toss of coins, and when the next one is due. Not modal
	and it takes no input: it goes by itself after GIFT_LIFE. data: cash, nextIn (seconds; the
	cooldown when absent): the server's Gift notify. The "Cash" effect of the same claim
	brings the sound and the coins (Main), not a second card.
]]
local GIFT_LIFE = 3.2
local GIFT_W, GIFT_H = 360, 168
function Popups.gift(data: { [string]: any })
	local now = os.clock()
	local cash = math.max(tonumber(data.cash) or 0, 0)
	local nextIn = tonumber(data.nextIn) or Economy.FREE_REWARD_COOLDOWN
	local old = screen:FindFirstChild("GiftCard")
	if old then
		old:Destroy()
	end
	local holder = Kit.new("Frame", {
		Name = "GiftCard",
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(GIFT_W, GIFT_H),
		-- Centred, a little low: the badge on its top edge stays clear of the HUD's top strips.
		Position = UDim2.fromScale(0.5, 0.44),
		AnchorPoint = Vector2.new(0.5, 0.5),
		ZIndex = 27,
		Parent = screen,
	})
	if not PREVIEW then
		-- Set before the card is filled, so one that fails half-way still goes by itself.
		task.delay(GIFT_LIFE, function()
			if holder.Parent then
				Kit.disappear(holder, { time = 0.22, to = 0.9, destroy = true })
			end
		end)
		-- A reward card is on screen: nothing opens by itself over it ("PopupBusy").
		Popups.giftUntil = os.clock() + GIFT_LIFE + 0.25
		Popups.syncBusy()
		task.delay(GIFT_LIFE + 0.3, Popups.syncBusy)
	end
	local card = Kit.panel(holder, {
		Name = "Card",
		Color = C.Surface,
		StrokeColor = C.Cash,
		StrokeThickness = 2,
		Size = UDim2.fromOffset(GIFT_W, GIFT_H),
		Radius = Kit.RADIUS.L,
		ZIndex = 2,
	})
	medallion(card, Theme.Icons.Free, C.Cash, 68, UDim2.new(0.5, 0, 0, 0))
	Kit.hudText(card, {
		Name = "Title",
		Text = W.Free .. "!",
		TextSize = Kit.px(18, 24, screen),
		TextColor3 = C.GoldLight,
		Size = UDim2.new(1, -24, 0, 30),
		Position = UDim2.fromOffset(12, 40),
		ZIndex = 3,
	})
	local amountSize = Kit.px(28, 46, screen)
	local amount = Kit.hudText(card, {
		Name = "Amount",
		Text = "+" .. State.money(cash),
		Font = Theme.Fonts.Number,
		TextSize = amountSize,
		TextScaled = true,
		MaxTextSize = amountSize,
		TextColor3 = C.MoneyText,
		Size = UDim2.new(1, -32, 0, amountSize + 6),
		Position = UDim2.fromOffset(16, 70),
		StrokeThickness = 3,
		ZIndex = 3,
	})
	local nextLine = Kit.hudText(card, {
		Name = "Next",
		Text = "Next gift in " .. Format.time(nextIn),
		Font = Theme.Fonts.UI,
		TextSize = Kit.px(Kit.captionPx(), 16, screen),
		TextTransparency = 0.1,
		Size = UDim2.new(1, -24, 0, 22),
		Position = UDim2.new(0, 12, 1, -32),
		StrokeThickness = 2,
		ZIndex = 3,
	})
	Kit.appear(holder, { from = 0.6, time = 0.3 })

	local COUNT_TIME = 0.9
	after(0.15, function()
		if holder.Parent then
			Kit.countTo(amount, 0, cash, function(n)
				return "+" .. State.money(n)
			end, COUNT_TIME)
		end
	end)
	if not PREVIEW then
		task.spawn(function()
			-- Coin ticks rising with the count, and the countdown under it.
			task.wait(0.15)
			local t = 0
			while t < COUNT_TIME and holder.Parent do
				sounds.play("Coin", 0.03, 0.9 + (t / COUNT_TIME) * 0.6)
				task.wait(0.1)
				t += 0.1
			end
			while holder.Parent do
				nextLine.Text = "Next gift in " .. Format.time(nextIn - (os.clock() - now))
				task.wait(0.5)
			end
		end)
		if not reducedMotion() then
			-- A toss of coins from behind the card, falling past it.
			for i = 1, 12 do
				local coin = moneyPiece(holder, false, 1)
				local x = 0.5 + (math.random() - 0.5) * 0.5
				coin.Position = UDim2.fromScale(x, 0.3)
				coin.Rotation = math.random(-30, 30)
				local out = x + (x - 0.5) * 1.8 + (math.random() - 0.5) * 0.3
				local up = 0.14 + i * 0.012
				Kit.tween(
					coin,
					up + 0.16,
					{ Position = UDim2.fromScale((x + out) / 2, -0.55 - math.random() * 0.35) },
					Enum.EasingStyle.Quad
				)
				task.delay(up + 0.16, function()
					if not coin.Parent then
						return
					end
					Kit.tween(
						coin,
						0.55,
						{ Position = UDim2.fromScale(out, 1.7), Rotation = coin.Rotation + math.random(-200, 200) },
						Enum.EasingStyle.Quad,
						Enum.EasingDirection.In
					)
					if coin:IsA("ImageLabel") then
						tweenAfter(coin, 0.2, 0.35, { ImageTransparency = 1 })
					end
					task.delay(0.56, function()
						coin:Destroy()
					end)
				end)
			end
		end
	end
end

--[[
	Aura Surge notices. SURGE_WARN seconds before a surge a chip "AURA SURGE in 0:30"
	counts down at the head of the toast stack (the toasts move down for it), and when the
	surge starts a banner crosses the screen for 2 s. The surge is a slice of the server
	clock (Economy.surgeState), so both run off that clock here; the server's Surge notify
	(Popups.surge) only lands them at once. Not shown before the tutorial is done, during
	the intro or on a course.
]]
local SURGE_WARN = 30
local SURGE_CHIP_W, SURGE_CHIP_H = 260, 36
local SURGE_CHIP_STEP = 44
local surgeChip: GuiObject? = nil
local surgeChipText: TextLabel? = nil
local surgeChipSecond = -1
local surgeBannerAt = -math.huge

local function surgeQuiet(): boolean
	local data = State.data
	return data == nil or data.tutorialDone ~= true or inRun() or Players.LocalPlayer:GetAttribute("IntroPlaying") == true
end

-- Shows the chip at `seconds` to go; nil takes it away.
local function setSurgeChip(seconds: number?)
	if not seconds then
		local chip = surgeChip
		if chip then
			surgeChip, surgeChipText, surgeChipSecond = nil, nil, -1
			chipRoom = 0
			Kit.disappear(chip, { time = 0.2, to = 0.94, destroy = true })
			if placeToastHolder then
				placeToastHolder()
			end
		end
		return
	end
	local whole = math.max(0, math.ceil(seconds))
	if not surgeChip then
		local chip = Kit.hudGlass(toastHolder, {
			Name = "SurgeChip",
			Size = UDim2.fromOffset(SURGE_CHIP_W, SURGE_CHIP_H),
			Position = UDim2.new(0.5, 0, 0, -SURGE_CHIP_STEP),
			AnchorPoint = Vector2.new(0.5, 0),
			Accent = C.Amber,
			ZIndex = 2,
		})
		Kit.hudIcon(chip, "Surge", 22, C.Amber, {
			Position = UDim2.new(0, 22, 0.5, 0),
			AnchorPoint = Vector2.new(0, 0.5),
			ZIndex = 2,
		})
		surgeChipText = Kit.hudText(chip, {
			Name = "Text",
			Text = "",
			MaxTextSize = 17,
			Size = UDim2.new(1, -66, 0, 23),
			Position = UDim2.new(0, 52, 0.5, 1),
			AnchorPoint = Vector2.new(0, 0.5),
			TextXAlignment = Enum.TextXAlignment.Left,
			TextColor3 = Kit.lighten(C.Amber, 0.35),
			StrokeThickness = 2,
			ZIndex = 2,
		})
		surgeChip = chip
		chipRoom = SURGE_CHIP_STEP
		chip.Visible = screen:GetAttribute("WindowOpen") ~= true
		if placeToastHolder then
			placeToastHolder()
		end
		Kit.appear(chip, { from = 0.9, time = TOAST_IN, style = Enum.EasingStyle.Quad })
		sounds.play("Toast", 0, 1.2)
	end
	if whole ~= surgeChipSecond and surgeChipText then
		surgeChipSecond = whole
		surgeChipText.Text = string.format("%s in %s", W.Surge, Format.time(whole))
		-- The last five seconds tick.
		if whole <= 5 and whole > 0 and surgeChip and surgeChip.Visible and revealCount == 0 then
			Kit.pop(surgeChip, 0.5)
			sounds.play("Tick", 0, 1 + (5 - whole) * 0.06)
		end
	end
end

-- A surge is told once: `surgeToldUntil` is the os.clock() its telling covers.
local surgeToldUntil = -math.huge

local function surgeBanner()
	local now = os.clock()
	if now - surgeBannerAt < 10 or surgeQuiet() then
		return
	end
	surgeBannerAt = now
	surgeToldUntil = now + Economy.SURGE_DURATION
	Popups.banner({
		Text = string.format("%s x%d: double cash!", W.Surge, Economy.SURGE_MULTIPLIER),
		Color = C.Amber,
		Life = 2,
		Confetti = 18,
	})
end

-- One look at the server clock: the chip while a surge is SURGE_WARN or less away, the
-- banner on the step into a surge. A surge found already running (on join, when the
-- tutorial ends, back from a course) gets a toast with the time left instead, as soon as
-- the screen is free; the server sends nothing for it.
local function surgeTick(wasActive: boolean?): boolean
	local active, left = Economy.surgeState(Workspace:GetServerTimeNow())
	if active and wasActive == false then
		surgeBanner()
	end
	if active and left > 5 and os.clock() >= surgeToldUntil and not surgeQuiet() then
		surgeToldUntil = os.clock() + left + 5
		Popups.toast(string.format("%s x%d is on: %s left", W.Surge, Economy.SURGE_MULTIPLIER, Format.time(left)), "good")
	end
	if not active and left <= SURGE_WARN and not surgeQuiet() then
		setSurgeChip(left)
	else
		setSurgeChip(nil)
	end
	return active
end

-- The server's Surge notify: { phase = "soon", seconds = 30 } | "start" | "end". It is not
-- sent during the tutorial.
function Popups.surge(payload: { [string]: any })
	if payload.phase == "start" then
		setSurgeChip(nil)
		surgeBanner()
	elseif payload.phase == "soon" and not surgeQuiet() then
		local _, left = Economy.surgeState(Workspace:GetServerTimeNow())
		setSurgeChip(math.min(left, tonumber(payload.seconds) or SURGE_WARN))
	elseif payload.phase == "end" then
		setSurgeChip(nil)
	end
end

local function watchSurge()
	task.spawn(function()
		local active: boolean? = nil
		while true do
			active = surgeTick(active)
			task.wait(0.25)
		end
	end)
end

-- Rebirth ------------------------------------------------------------------------------------
--[[
	Three cards round the server's rebirth (Tycoon: the action "Rebirth", the notifies
	"RebirthReady" and "Rebirth", the snapshot's `rebirth` offer). The server decides
	everything; these only show and ask, and nothing here hurries: no timer, no countdown.

	  ready    Popups.rebirthReady, on "RebirthReady" (a run reached the rebirth tier). The
	           first time, with no stars yet: one sentence on what a rebirth is, what it
	           would pay now, and two equal answers, "Later" and "Show me". Someone who
	           has stars knows it: a toast.
	  confirm  Popups.rebirth (the HUD's goal strip and star counter). The stars gained and
	           the cash bonus before -> after, then the server's own lists: what stays
	           first, what starts again beside it, with one more plain line that the cash
	           goes too, bought cash included. Two steps, never one tap: "Rebirth" only
	           asks again, and the second question has its answers on the other sides (a
	           double tap lands on "No, go back") and takes no "Yes" for REBIRTH.Arm
	           seconds. "Yes" sends the action and waits; the card closes on the server's
	           "Rebirth" notify, or quietly after REBIRTH.Wait seconds if it said no (the
	           server toasts why). With nothing on offer the call is a toast instead.
	  reveal   Popups.rebirthDone, on "Rebirth": rays, sparkles and confetti round a star,
	           the stars counting up and the cash bonus rolling from the old value to the
	           new one. One confetti-free still card with reduced motion.

	Defined inside a function of their own (Popups.defineRebirth, called once right under
	it): this chunk has no room left in Luau's 200 locals, not even for a block's.
]]
Popups.rebirth = function(_sample: { [string]: any }?) end
Popups.rebirthReady = function(_payload: { [string]: any }) end
Popups.rebirthDone = function(_payload: { [string]: any }) end
function Popups.defineRebirth()
	-- Tuning. Nothing here was judged on screen yet: adjust in Studio.
	local REBIRTH = {
		Z = 47, -- the three cards (their dim one under)
		Pad = 20,
		Gap = 14,
		Button = 56,
		-- Confirm
		Width = 760,
		Medal = 76,
		Title = 52, -- under the medallion's lower half
		Gain = 66, -- the "+3 stars | x1.2 -> x1.5" panel
		GainText = 30,
		Head = 26, -- a list's heading
		RowIcon = 16,
		RowGap = 6,
		RowPad = 12,
		Rows = 4, -- lines a list shows (what starts again is never cut)
		RowPx = 14, -- a row's text on the glass, at least
		KeepColor = C.Cash, -- green: what stays
		ResetColor = C.Amber, -- orange: what starts again
		Arm = 0.8, -- seconds before the second question takes a "Yes"
		Wait = 5, -- seconds the card waits for the server's answer
		-- Ready
		ReadyWidth = 500,
		LaterColor = C.SurfaceHi, -- neutral, and the same size as "Show me" on purpose
		ShowColor = C.Gold, -- the primary
		-- Reveal
		DoneWidth = 500,
		DoneMedal = 96,
		Rays = 280,
		Sparkles = 8,
		Well = 100,
		Bursts = 3, -- confetti bursts (none with reduced motion)
		BurstGap = 0.35,
		Roll = 0.9, -- seconds the stars count up; the cash bonus rolls after them
		BigStars = 5, -- from this many stars in one rebirth the louder fanfare plays
	}
	-- The card that asks is queued or up; `settle` closes it once the server has answered.
	local S: { open: boolean, settle: (() -> ())? } = { open = false, settle = nil }

	local function starWord(n: number): string
		return if n == 1 then "star" else "stars"
	end
	local function whole(value: any): number
		return math.max(0, math.floor((tonumber(value) or 0) + 0.5))
	end
	local function multText(mult: number): string
		return string.format("x%.1f", mult)
	end
	-- The texts of one of the server's lists ({ key, text } rows), in its order.
	local function rowsOf(list: any): { string }
		local rows: { string } = {}
		if type(list) == "table" then
			for _, entry in list do
				if type(entry) == "table" and type(entry.text) == "string" and entry.text ~= "" then
					table.insert(rows, entry.text)
				end
			end
		end
		return rows
	end
	-- What stays, in at most `room` lines: the stars and the paid passes lead (the rows a
	-- player would miss most), the rest follow in the server's order, and a list that is cut
	-- ends in one honest line for everything left out (all that does not start again stays:
	-- Economy.REBIRTH_KEEPS).
	local function keepRows(list: any, room: number): { string }
		local first: { string } = {}
		local rest: { string } = {}
		if type(list) == "table" then
			for _, entry in list do
				if type(entry) == "table" and type(entry.text) == "string" and entry.text ~= "" then
					table.insert(if entry.key == "stars" or entry.key == "passes" then first else rest, entry.text)
				end
			end
		end
		table.move(rest, 1, #rest, #first + 1, first)
		if #first > room then
			for i = #first, room, -1 do
				table.remove(first, i)
			end
			table.insert(first, "And everything else you own")
		end
		return first
	end
	-- The offer in the snapshot, while the server has one.
	local function liveOffer(): { [string]: any }?
		local data = State.data
		if data and data.canRebirth == true and type(data.rebirth) == "table" then
			return data.rebirth
		end
		return nil
	end
	local function plainLine(box: Frame, name: string, text: string, size: number, y: number, pad: number, color: Color3?): TextLabel
		return Kit.text(box, {
			Name = name,
			Text = text,
			TextSize = size,
			TextWrapped = false,
			Size = UDim2.new(1, -pad * 2, 0, size + 8),
			Position = UDim2.fromOffset(pad, y),
			TextColor3 = color or C.Text,
			StrokeThickness = 1,
		})
	end

	-- `sample`: an offer to show instead of the snapshot's (the Studio capture hook); its
	-- "Yes" sends nothing.
	Popups.rebirth = function(sample: { [string]: any }?)
		if not (sample or liveOffer()) then
			-- Nothing on offer: what the stars do and where the next ones are.
			local data = State.data
			local stars = whole(data and data.stars)
			local tier = whole(data and data.rebirthTier)
			local entry = Theme.Tiers[if tier > 0 then tier else Economy.REBIRTH_MIN_TIER]
			local name = if entry then entry.Name else "a higher tier"
			if stars > 0 then
				local bonus = math.floor(((tonumber(data and data.starMult) or 1) - 1) * 100 + 0.5)
				local line = "Your %d %s give +%d%% cash. Reach %s to rebirth for more!"
				Popups.toast(string.format(line, stars, starWord(stars), bonus, name), "info")
			else
				Popups.toast(string.format("Reach %s to rebirth for stars!", name), "info")
			end
			return
		end
		if S.open then
			return
		end
		S.open = true
		Popups.enqueue("Rebirth", Popups.PRIORITY.Normal, function(done)
			-- The offer as it is now: the run may have moved on while the card waited its turn.
			local offer = sample or liveOffer()
			if not offer then
				S.open = false
				done()
				return
			end
			local L = REBIRTH
			local gained = math.max(1, whole(offer.gained))
			local before = tonumber(offer.starMult) or 1
			local multAfter = tonumber(offer.starMultAfter) or before
			-- Short lists, L.Rows lines each. What starts again is never cut (it is what the
			-- player agrees to): when it runs longer, the list of what stays gives up lines.
			local resets = rowsOf(offer.resets)
			local keeps = keepRows(offer.keeps, math.clamp(L.Rows * 2 - #resets, 2, L.Rows))
			-- Two columns of rows, each as tall as its text wraps; the cash warning closes the
			-- right one.
			local colW = (L.Width - L.Pad * 2 - L.Gap) / 2
			local rowSize = Kit.px(L.RowPx, T.Small, screen)
			local textW = colW - L.RowPad * 2 - L.RowIcon - 8
			local function columnHeight(rows: { string }): number
				local height = L.Head + 6
				for _, text in rows do
					height += bodyHeight(text, rowSize, textW) + L.RowGap
				end
				return height + L.RowPad - L.RowGap
			end
			local warnText = "Your cash starts again too, even cash you bought in packs."
			local warnW = colW - 16 - 34 - 10
			local noteSize = Kit.px(if Kit.touch then 13 else 16, T.Body, screen)
			local gainY = L.Title + 34 + 8
			local listY = gainY + L.Gain + L.Gap
			local warnH, listH, noteY, buttonY = 0, 0, 0, 0
			-- A tall card on a short screen is shrunk by Kit.fit (the modal's "Fit" scale): the
			-- rows grow by what the fit takes and the card is measured again, so they stay
			-- L.RowPx on the glass (three rounds settle it).
			for _ = 1, 3 do
				warnH = bodyHeight(warnText, rowSize, warnW) + 16
				listH = math.max(columnHeight(keeps), columnHeight(resets) + 8 + warnH + 8 - L.RowPad)
				noteY = listY + listH + 10
				buttonY = noteY + noteSize + 8 + 10
				local area = Kit.designArea(screen)
				local share = if Kit.touch then Theme.Glass.FitTouch else Theme.Glass.Fit
				local fit = if area then math.min(1, area.X * share / L.Width, area.Y * share / (buttonY + L.Button + L.Pad + 96)) else 1
				local wanted = Kit.px(L.RowPx / fit, T.Small, screen)
				if wanted <= rowSize then
					break
				end
				rowSize = wanted
			end
			local close: () -> ()
			local box, closeModal = modal("Rebirth", Vector2.new(L.Width, buttonY + L.Button + L.Pad), L.Z, nil, function()
				S.open = false
				if S.settle == close then
					S.settle = nil
				end
				done()
			end)
			close = closeModal
			local medal = medallion(box, "⭐", C.Gold, L.Medal, UDim2.new(0.5, 0, 0, 0))
			Kit.title(box, {
				Text = "REBIRTH FOR STARS?",
				TextSize = T.H1,
				TextWrapped = false,
				Size = UDim2.new(1, -L.Pad * 2, 0, 34),
				Position = UDim2.fromOffset(L.Pad, L.Title),
				TextColor3 = C.Gold,
			})
			-- What it pays: the stars, and the cash bonus they make of the one held now.
			local gain = Kit.well(box, {
				Name = "Gain",
				Glass = true,
				Size = UDim2.new(1, -L.Pad * 2, 0, L.Gain),
				Position = UDim2.fromOffset(L.Pad, gainY),
			})
			local gainText = string.format("+%s %s", Format.commas(gained), starWord(gained))
			local gainW = displayWidth(gainText, L.GainText) + 6
			local starCell = Kit.new("Frame", {
				Name = "Stars",
				BackgroundTransparency = 1,
				Size = UDim2.new(0, 40 + 8 + gainW, 1, 0),
				Position = UDim2.fromScale(0.25, 0),
				AnchorPoint = Vector2.new(0.5, 0),
				Parent = gain,
			})
			Kit.icon(starCell, "Star", 40, C.Gold, { Position = UDim2.new(0, 0, 0.5, 0), AnchorPoint = Vector2.new(0, 0.5) })
			Kit.title(starCell, {
				Name = "Value",
				Text = gainText,
				TextSize = L.GainText,
				TextWrapped = false,
				TextXAlignment = Enum.TextXAlignment.Left,
				Size = UDim2.new(0, gainW, 1, 0),
				Position = UDim2.fromOffset(48, 0),
				TextColor3 = C.Gold,
			})
			Kit.text(gain, {
				Name = "BonusCaption",
				Text = "Cash bonus, forever",
				Font = Kit.F.UI,
				TextSize = T.Small,
				TextWrapped = false,
				Size = UDim2.new(0.5, -12, 0, 18),
				Position = UDim2.new(0.5, 6, 0, 8),
				TextColor3 = C.TextDim,
				StrokeThickness = 0,
			})
			Kit.title(gain, {
				Name = "Bonus",
				Text = string.format('%s  →  <font color="#%s">%s</font>', multText(before), C.MoneyText:ToHex(), multText(multAfter)),
				RichText = true,
				TextSize = 26,
				TextWrapped = false,
				Size = UDim2.new(0.5, -12, 0, 32),
				Position = UDim2.new(0.5, 6, 0, 28),
				TextColor3 = C.TextDim,
			})
			-- The server's lists, word for word: what stays first, what starts again beside it.
			local function column(name: string, x: number, heading: string, color: Color3, rows: { string }, check: boolean): Frame
				local well = Kit.well(box, {
					Name = name,
					Glass = true,
					Size = UDim2.fromOffset(colW, listH),
					Position = UDim2.fromOffset(x, listY),
				})
				Kit.title(well, {
					Name = "Head",
					Text = heading,
					TextSize = T.Body,
					TextWrapped = false,
					TextXAlignment = Enum.TextXAlignment.Left,
					Size = UDim2.new(1, -L.RowPad * 2, 0, L.Head),
					Position = UDim2.fromOffset(L.RowPad, 4),
					TextColor3 = color,
				})
				local y = L.Head + 6
				for i, text in rows do
					local height = bodyHeight(text, rowSize, textW)
					if check then
						Kit.icon(well, "Check", L.RowIcon, color, { Name = "Mark" .. i, Position = UDim2.fromOffset(L.RowPad, y + 1) })
					else
						local dot = circle(well, "Mark" .. i, color, 0, 1)
						dot.Size = UDim2.fromOffset(8, 8)
						dot.Position = UDim2.fromOffset(L.RowPad + L.RowIcon / 2, y + math.floor(rowSize * 0.65))
					end
					-- The rows wear their list's colour too (green stays, orange starts again).
					Kit.text(well, {
						Name = "Row" .. i,
						Text = text,
						TextSize = rowSize,
						TextXAlignment = Enum.TextXAlignment.Left,
						TextYAlignment = Enum.TextYAlignment.Top,
						Size = UDim2.fromOffset(textW, height + 2),
						Position = UDim2.fromOffset(L.RowPad + L.RowIcon + 8, y),
						TextColor3 = Kit.lighten(color, 0.4),
						StrokeThickness = 0,
					})
					y += height + L.RowGap
				end
				return well
			end
			local kept = column("Keeps", L.Pad, "YOU KEEP", L.KeepColor, keeps, true)
			local again = column("Resets", L.Pad + colW + L.Gap, "STARTS AGAIN", L.ResetColor, resets, false)
			-- One more plain line: the wallet goes too, whatever it was paid for.
			local warn = Kit.new("Frame", {
				Name = "CashWarning",
				BackgroundColor3 = L.ResetColor,
				BackgroundTransparency = 0.8,
				BorderSizePixel = 0,
				Size = UDim2.new(1, -16, 0, warnH),
				Position = UDim2.new(0, 8, 1, -8),
				AnchorPoint = Vector2.new(0, 1),
				Parent = again,
			})
			Kit.corner(warn, 8)
			Kit.new("UIStroke", { Thickness = 1, Color = L.ResetColor, Transparency = 0.45, Parent = warn })
			Kit.title(warn, {
				Name = "Mark",
				Text = "!",
				TextSize = 20,
				Size = UDim2.new(0, 34, 1, 0),
				TextColor3 = L.ResetColor,
			})
			Kit.text(warn, {
				Name = "Text",
				Text = warnText,
				Font = Kit.F.UI,
				TextSize = rowSize,
				TextXAlignment = Enum.TextXAlignment.Left,
				Size = UDim2.new(0, warnW, 1, -12),
				Position = UDim2.fromOffset(34, 6),
				TextColor3 = Kit.lighten(L.ResetColor, 0.4),
				StrokeThickness = 0,
			})
			local note = plainLine(box, "Note", "", noteSize, noteY, L.Pad)
			-- Two steps. 1: "Rebirth" | "Not now". 2: "No, go back" | "Yes, rebirth!", the
			-- answers on the other sides, so the tap that asked can never be the one that agrees.
			-- On step 2 the way back is the big primary button and "Yes" a smaller neutral one.
			local step = 1
			local armed = false
			local token = 0
			local left: TextButton
			local right: TextButton
			-- `share` of the row for the left button; the right one is `drop` px shorter.
			local function weigh(share: number, drop: number)
				left.Size = UDim2.new(share, -L.Pad - 6, 0, L.Button)
				right.Size = UDim2.new(1 - share, -L.Pad - 6, 0, L.Button - drop)
				right.Position = UDim2.new(share, 6, 0, buttonY + drop / 2)
			end
			local function paint()
				token += 1
				local mine = token
				armed = false
				if step == 1 then
					weigh(0.5, 0)
					Kit.setButton(left, "Rebirth", C.Gold)
					Kit.setButton(right, "Not now", C.SurfaceHi)
					note.Text = "No rush: you can rebirth whenever you like."
					note.TextColor3 = C.TextDim
				elseif step == 2 then
					weigh(0.62, 12)
					Kit.setButton(left, "No, go back", C.Primary)
					Kit.setButton(right, "Yes, rebirth!", C.SurfaceHi)
					note.Text = "Really start again? A rebirth can't be undone."
					note.TextColor3 = C.Gold
					Kit.pop(note, 0.8)
					after(L.Arm, function()
						armed = token == mine
					end)
				else
					Kit.setButton(right, "One moment...")
					Kit.setEnabled(left, false)
					Kit.setEnabled(right, false)
					note.Text = "Starting your new gym..."
					note.TextColor3 = C.TextDim
				end
			end
			left = Kit.button(box, {
				Name = "Left",
				Text = "Rebirth",
				Color = C.Gold,
				Size = UDim2.new(0.5, -L.Pad - 6, 0, L.Button),
				Position = UDim2.fromOffset(L.Pad, buttonY),
			}, function()
				if step == 1 or step == 2 then
					step = if step == 1 then 2 else 1
					paint()
				end
			end)
			right = Kit.button(box, {
				Name = "Right",
				Text = "Not now",
				Color = C.SurfaceHi,
				Size = UDim2.new(0.5, -L.Pad - 6, 0, L.Button),
				Position = UDim2.new(0.5, 6, 0, buttonY),
			}, function()
				if step == 1 then
					close()
				elseif step == 2 and armed then
					step = 3
					paint()
					if sample then
						after(0.4, close)
						return
					end
					-- The server answers with the "Rebirth" notify (Popups.rebirthDone closes this
					-- card); a refusal is its own toast, and the card just goes.
					S.settle = close
					Net.event("Action"):FireServer({ action = "Rebirth" })
					task.delay(L.Wait, function()
						if S.settle == close then
							S.settle = nil
							close()
						end
					end)
				end
			end)
			-- Gamepad lands on the safe answer; B and a tap beside the card also say "Not now".
			right:SetAttribute("FocusFirst", true)
			paint()
			Kit.appear(box)
			Kit.appear(medal, { from = 0.4, time = 0.32, delay = 0.06 })
			local staged: { GuiObject } = { gain, kept, again, left, right }
			Kit.stagger(staged, 0.04)
			sounds.play("Open")
		end)
	end
	-- The card threw while it was being built (the queue closed what there was of it): the
	-- star counter and the goal strip can ask again.
	Popups.FAILED.Rebirth = function()
		S.open = false
		S.settle = nil
	end

	Popups.rebirthReady = function(payload: { [string]: any })
		-- Never over a run on a course or an open window (the "While you were away" card, the
		-- Daily window, the Index): the card waits for it to end.
		local function held(): boolean
			return inRun() or screen:GetAttribute("WindowOpen") == true
		end
		if not PREVIEW and held() then
			task.spawn(function()
				while held() do
					task.wait(0.5)
				end
				task.wait(1)
				Popups.rebirthReady(payload)
			end)
			return
		end
		local gain = math.max(1, whole(payload.starsOnRebirth))
		if whole(payload.stars) > 0 then
			Popups.toast(string.format("Rebirth is ready again: +%d %s, whenever you like", gain, starWord(gain)), "info")
			return
		end
		Popups.enqueue("RebirthReady", Popups.PRIORITY.Normal, function(done)
			local L = REBIRTH
			local textSize = Kit.px(if Kit.touch then 15 else 18, T.H3, screen)
			local smallSize = Kit.px(if Kit.touch then 13 else 16, T.Body, screen)
			local inner = L.ReadyWidth - L.Pad * 2
			-- The whole idea in one sentence.
			local text = "Rebirth starts your gym again and gives you a gold star: every star makes all your cash bigger, forever!"
			local nowLine = "Right now it gives +%d %s. Find bigger %s first and it gives more. No rush!"
			local now = string.format(nowLine, gain, starWord(gain), W.Units)
			local plateY = L.Title + 34 + 10
			local plateH = bodyHeight(text, textSize, inner - 28) + 24
			local nowY = plateY + plateH + 12
			local nowH = bodyHeight(now, smallSize, inner - 8) + 4
			local buttonY = nowY + nowH + L.Gap
			local wanted = false
			local box, close = modal("RebirthReady", Vector2.new(L.ReadyWidth, buttonY + L.Button + L.Pad), L.Z, nil, function()
				done()
				if wanted then
					Popups.rebirth()
				end
			end)
			local medal = medallion(box, "⭐", C.Gold, L.Medal, UDim2.new(0.5, 0, 0, 0))
			Kit.title(box, {
				Text = "REBIRTH UNLOCKED!",
				TextSize = T.H1,
				TextWrapped = false,
				Size = UDim2.new(1, -L.Pad * 2, 0, 34),
				Position = UDim2.fromOffset(L.Pad, L.Title),
				TextColor3 = C.Gold,
			})
			local plate = Kit.well(box, {
				Name = "Plate",
				Glass = true,
				Size = UDim2.new(1, -L.Pad * 2, 0, plateH),
				Position = UDim2.fromOffset(L.Pad, plateY),
			})
			Kit.text(plate, {
				Name = "Text",
				Text = text,
				TextSize = textSize,
				Size = UDim2.new(1, -28, 1, -20),
				Position = UDim2.fromOffset(14, 10),
				StrokeThickness = 0,
			})
			Kit.text(box, {
				Name = "Now",
				Text = now,
				Font = Kit.F.UI,
				TextSize = smallSize,
				Size = UDim2.new(1, -L.Pad * 2 - 8, 0, nowH),
				Position = UDim2.fromOffset(L.Pad + 4, nowY),
				TextColor3 = C.TextDim,
				StrokeThickness = 1,
			})
			-- "Show me" is the primary; "Later" is neutral but just as big and as easy to tap
			-- (the gamepad starts on it; B and a tap beside the card mean it too).
			local later = Kit.button(box, {
				Name = "Later",
				Text = "Later",
				Color = L.LaterColor,
				Size = UDim2.new(0.5, -L.Pad - 6, 0, L.Button),
				Position = UDim2.fromOffset(L.Pad, buttonY),
			}, close)
			local show = Kit.button(box, {
				Name = "Show",
				Text = "Show me",
				Color = L.ShowColor,
				Size = UDim2.new(0.5, -L.Pad - 6, 0, L.Button),
				Position = UDim2.new(0.5, 6, 0, buttonY),
			}, function()
				wanted = true
				close()
			end)
			later:SetAttribute("FocusFirst", true)
			Kit.appear(box)
			Kit.appear(medal, { from = 0.4, time = 0.32, delay = 0.06 })
			local buttons: { GuiObject } = { later, show }
			Kit.stagger(buttons, 0.04)
			sounds.play("Reward")
		end)
	end

	Popups.rebirthDone = function(payload: { [string]: any })
		-- The card that asked has its answer.
		local settle = S.settle
		S.settle = nil
		if settle then
			settle()
		end
		Popups.enqueue("RebirthDone", Popups.PRIORITY.Normal, function(done)
			local L = REBIRTH
			local gained = whole(payload.gained)
			local stars = math.max(gained, whole(payload.stars))
			local multAfter = tonumber(payload.multiplier) or 1
			local before = math.min(tonumber(payload.multiplierBefore) or 1, multAfter)
			local calm = reducedMotion()
			local subSize = Kit.px(if Kit.touch then 13 else 16, T.Body, screen)
			local subY = L.Title + 8 + 34 + 4
			local wellY = subY + subSize + 8 + 10
			local totalY = wellY + L.Well + 10
			local buttonY = totalY + subSize + 8 + L.Gap
			local box, close = modal("RebirthDone", Vector2.new(L.DoneWidth, buttonY + L.Button + 2 + L.Pad), L.Z, nil, done)
			local medalAt = UDim2.new(0.5, 0, 0, 0)
			-- Behind the medal and (made first) under the title: rays and twinkles.
			if not calm then
				Popups.rays(box, Kit.lighten(C.Gold, 0.3), L.Rays, medalAt, 1, 9)
			end
			local twinkle = Kit.new("Frame", {
				Name = "MedalSparkles",
				BackgroundTransparency = 1,
				Size = UDim2.fromOffset(L.DoneMedal, L.DoneMedal),
				Position = UDim2.new(0.5, 0, 0, -math.floor(L.DoneMedal * 0.35)),
				AnchorPoint = Vector2.new(0.5, 0.5),
				Parent = box,
			})
			sparkles(twinkle, Kit.lighten(C.Gold, 0.5), L.Sparkles, L.DoneMedal * 0.85, calm)
			local medal = medallion(box, "⭐", C.Gold, L.DoneMedal, medalAt)
			Kit.title(box, {
				Text = "REBIRTH!",
				TextSize = T.H1,
				TextWrapped = false,
				Size = UDim2.new(1, -L.Pad * 2, 0, 34),
				Position = UDim2.fromOffset(L.Pad, L.Title + 8),
				TextColor3 = C.Gold,
			})
			plainLine(box, "Sub", "A fresh gym, and your stars stay forever.", subSize, subY, L.Pad)
			local well = Kit.well(box, {
				Name = "Gained",
				Glass = true,
				Size = UDim2.new(1, -L.Pad * 2, 0, L.Well),
				Position = UDim2.fromOffset(L.Pad, wellY),
			})
			local function caption(name: string, text: string, side: number)
				Kit.text(well, {
					Name = name,
					Text = text,
					Font = Kit.F.UI,
					TextSize = T.Small,
					TextWrapped = false,
					Size = UDim2.new(0.5, -12, 0, 18),
					Position = UDim2.new(side * 0.5, 6, 0, 10),
					TextColor3 = C.TextDim,
					StrokeThickness = 0,
				})
			end
			caption("StarsCaption", if gained == 1 then "New star" else "New stars", 0)
			caption("BonusCaption", "Cash bonus", 1)
			-- The stars: an icon and the number, sized for the final text so it holds still
			-- while it counts.
			local function starsText(n: number): string
				return "+" .. Format.commas(n)
			end
			local starsW = numberWidth(starsText(gained), T.Hero) + 6
			local cell = Kit.new("Frame", {
				Name = "Stars",
				BackgroundTransparency = 1,
				Size = UDim2.fromOffset(42 + 8 + starsW, 50),
				Position = UDim2.new(0.25, 0, 0, 34),
				AnchorPoint = Vector2.new(0.5, 0),
				Parent = well,
			})
			Kit.icon(cell, "Star", 42, C.Gold, { Position = UDim2.new(0, 0, 0.5, 0), AnchorPoint = Vector2.new(0, 0.5) })
			local starsLabel = Kit.number(cell, {
				Name = "Value",
				Text = starsText(gained),
				TextSize = T.Hero,
				TextXAlignment = Enum.TextXAlignment.Left,
				Size = UDim2.new(0, starsW, 1, 0),
				Position = UDim2.fromOffset(50, 0),
				TextColor3 = C.Gold,
			})
			-- The cash bonus, in tenths so it rolls a step at a time.
			local function tenths(n: number): string
				return multText(n / 10)
			end
			local multLabel = Kit.number(well, {
				Name = "Bonus",
				Text = multText(before),
				TextSize = 34,
				Size = UDim2.new(0.5, -12, 0, 40),
				Position = UDim2.new(0.5, 6, 0, 30),
				TextColor3 = C.MoneyText,
			})
			Kit.text(well, {
				Name = "Was",
				Text = "was " .. multText(before),
				Font = Kit.F.UI,
				TextSize = T.Small,
				TextWrapped = false,
				Size = UDim2.new(0.5, -12, 0, 18),
				Position = UDim2.new(0.5, 6, 0, 72),
				TextColor3 = C.TextMute,
				StrokeThickness = 0,
				Visible = multAfter > before,
			})
			plainLine(
				box,
				"Total",
				string.format("You have %s %s now!", Format.commas(stars), starWord(stars)),
				subSize,
				totalY,
				L.Pad,
				C.Gold
			)
			local go = Kit.button(box, {
				Name = "Go",
				Text = "Let's go!",
				Font = Theme.Fonts.Display,
				Color = C.Gold,
				Breathe = true,
				Size = UDim2.new(1, -L.Pad * 2, 0, L.Button + 2),
				Position = UDim2.fromOffset(L.Pad, buttonY),
			}, close)
			go:SetAttribute("FocusFirst", true)
			Kit.appear(box)
			Kit.appear(medal, { from = 0.4, time = 0.34, delay = 0.06 })
			Kit.appear(go, { from = 0.8, time = 0.26, delay = 0.2 })
			for i = 1, if calm then 0 else L.Bursts do
				local x = if i == 1 then 0.5 elseif i % 2 == 0 then 0.14 else 0.86
				after((i - 1) * L.BurstGap, function()
					if box.Parent and not PREVIEW then
						Kit.confetti(box, { Origin = UDim2.fromScale(x, 0.1), Count = 28, ZIndex = 60, Power = 1.15 })
					end
				end)
			end
			after(0.25, function()
				if not starsLabel.Parent then
					return
				end
				Kit.countTo(starsLabel, 0, gained, starsText, L.Roll)
				-- The stars count up with ticks that climb in pitch.
				if gained > 0 and not PREVIEW then
					task.spawn(function()
						local ticks = math.min(gained, 8)
						for i = 1, ticks do
							if not starsLabel.Parent then
								return
							end
							sounds.play("Tick", 0.03, 1 + i * 0.05)
							task.wait(L.Roll / ticks)
						end
					end)
				end
			end)
			-- Then the bonus rolls from what it was to what it is, and lands with a pop.
			after(0.25 + L.Roll + 0.15, function()
				if not multLabel.Parent then
					return
				end
				Kit.countTo(multLabel, math.floor(before * 10 + 0.5), math.floor(multAfter * 10 + 0.5), tenths, 0.6)
				sounds.play("Upgrade")
			end)
			sounds.play(if gained >= L.BigStars then "CelebrateLegendary" else "Celebrate")
		end)
	end
end
Popups.defineRebirth()

function Popups.build(screenGui: ScreenGui, soundModule: any)
	screen = screenGui
	sounds = soundModule
	Hud.onRebirth = function()
		Popups.rebirth()
	end
	toastHolder = Kit.new("Frame", {
		Name = "Toasts",
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(560, 230),
		Position = UDim2.new(0.5, 0, 0, TOAST_Y),
		AnchorPoint = Vector2.new(0.5, 0),
		ZIndex = 25,
		Parent = screen,
	})
	-- The front layer of the same stack (errors and warnings over an open window), and the
	-- bottom edge of the safe area for them when nothing fits above the window.
	frontHolder = Kit.new("Frame", {
		Name = "ToastsFront",
		BackgroundTransparency = 1,
		Size = toastHolder.Size,
		Position = toastHolder.Position,
		AnchorPoint = toastHolder.AnchorPoint,
		ZIndex = TOAST_FRONT,
		Parent = screen,
	})
	lowHolder = Kit.new("Frame", {
		Name = "ToastsBottom",
		BackgroundTransparency = 1,
		Size = toastHolder.Size,
		Position = UDim2.new(0.5, 0, 1, -TOAST_TOP),
		AnchorPoint = Vector2.new(0.5, 1),
		ZIndex = TOAST_FRONT,
		Parent = screen,
	})
	-- Slide toasts below the tutorial card while it sits at the top centre, and to the very
	-- top of the screen while a window or modal is open (toastRoom).
	local function placeHolder()
		local y = toastRoom()
		for _, holder in { toastHolder, frontHolder } do
			Kit.tween(holder, 0.3, { Position = UDim2.new(0.5, 0, 0, y) }, Enum.EasingStyle.Quad)
		end
		-- The surge chip rides at the head of the stack; over a window that is off screen.
		if surgeChip then
			surgeChip.Visible = screen:GetAttribute("WindowOpen") ~= true
		end
	end
	placeToastHolder = placeHolder
	screen:GetAttributeChangedSignal("TopCardHeight"):Connect(function()
		placeHolder()
		flushToasts()
	end)
	-- A phone's menu row pushes the stack down (toastBase): follow the layout and the input.
	for _, name in { "Compact", "Input" } do
		screen:GetAttributeChangedSignal(name):Connect(function()
			task.defer(placeHolder)
		end)
	end
	Kit.onWindowOpen(function(up: boolean)
		placeHolder()
		if not up then
			flushToasts()
			return
		end
		-- A window opened under the stack: the informational toasts there is no room for
		-- above it step out and wait for it to close, so none covers its tabs; an error
		-- or warning already showing stays, above the window.
		local _, room = toastRoom()
		clearForWindow(room)
	end)
	placeHolder()
	buildChestPanel()
	if not PREVIEW then
		-- Warm the reveal's sprites so the first discovery already draws its glow.
		task.spawn(function()
			local sprites: { any } = {}
			for _, id in { SOFT_DOT, SPARKLE, RING } :: { any } do
				table.insert(sprites, id)
			end
			pcall(function()
				game:GetService("ContentProvider"):PreloadAsync(sprites)
			end)
		end)
		watchMerges()
		watchSurge()
		-- The server's one-time Starter grant and the two rebirth notifies (other Notify kinds
		-- are routed by Main).
		Net.event("Notify").OnClientEvent:Connect(function(payload)
			if type(payload) ~= "table" then
				return
			end
			if payload.kind == "Starter" then
				Popups.starter(payload)
			elseif payload.kind == "RebirthReady" then
				Popups.rebirthReady(payload)
			elseif payload.kind == "Rebirth" then
				Popups.rebirthDone(payload)
			end
		end)
		-- Studio-only capture hook, beside Main's: "UiPreview" = "rebirthready", "rebirth"
		-- (the snapshot's offer, or a made-up one whose "Yes" sends nothing) or
		-- "rebirthdone,<stars gained>".
		local player = Players.LocalPlayer
		if RunService:IsStudio() and player then
			player:GetAttributeChangedSignal("UiPreview"):Connect(function()
				local spec = player:GetAttribute("UiPreview")
				if typeof(spec) ~= "string" then
					return
				end
				local gained = tonumber(string.match(spec, "^rebirthdone,?(%d*)$"))
				if spec == "rebirthready" then
					Popups.rebirthReady({ kind = "RebirthReady", tier = Economy.REBIRTH_MIN_TIER, starsOnRebirth = 1, stars = 0 })
				elseif spec == "rebirth" then
					local data = State.data
					local live = data ~= nil and data.canRebirth == true and type(data.rebirth) == "table"
					-- The rows only stand in for the server's (never shown to a player).
					local row = { key = "sample", text = "Sample row: the server's own words go here" }
					Popups.rebirth(if live
						then nil
						else {
							tier = 17,
							gained = 3,
							stars = 2,
							starsAfter = 5,
							starMult = 1.2,
							starMultAfter = 1.5,
							keeps = table.create(8, row),
							resets = table.create(5, row),
						})
				elseif gained or spec == "rebirthdone" then
					local n = gained or 3
					Popups.rebirthDone({
						kind = "Rebirth",
						gained = n,
						stars = n + 2,
						rebirths = 2,
						tier = 14 + n,
						multiplier = 1.2 + Economy.STAR_BONUS * n,
						multiplierBefore = 1.2,
					})
				end
			end)
		end
	end
	watchStarterOffer()
end

return Popups
