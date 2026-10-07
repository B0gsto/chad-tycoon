--[[
	Popups: toasts, reward reveals, the held-crate panel, confirm dialogs,
	offline earnings and floating "+X" text.

	Everything eases: popups come in with Kit.appear and leave with
	Kit.disappear, toasts slide into a stack, floats rise on an arc, numbers
	count up. Celebrations use the candy colours of Theme.World (confetti,
	soft rays, a white ring on bursts); nothing flashes.

	Z order (ScreenGui uses Sibling ZIndex):
	  floats 20, toasts 25, reward 30, offline 44-45, starter 46-47, confirm 49-50,
	  cash rain 50
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local GuiService = game:GetService("GuiService")
local ContextActionService = game:GetService("ContextActionService")

local Economy = require(ReplicatedStorage.Shared.Economy)
local Format = require(ReplicatedStorage.Shared.Format)
local Net = require(ReplicatedStorage.Shared.Net)

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
	A short stack under the top bar, newest on top. Each toast is a small blue
	panel with a coloured icon chip; it slides down into place, the others
	slide to make room, and it fades up and away after 3 s.
]]

local TONES = {
	good = { color = C.Cash, icon = "Check" },
	bad = { color = C.Danger, icon = "!" },
	info = { color = C.Gold, icon = "i" },
}

local TOAST_H = 44
local TOAST_STEP = 54 -- toast + lip/shadow + gap
local MAX_TOASTS = 4

local toasts: { Frame } = {}

-- Width that hugs the text (TextService when available, else an estimate).
local function toastWidth(text: string): number
	local width = 0
	pcall(function()
		local TextService = game:GetService("TextService")
		width = TextService:GetTextSize(text, 16, Theme.Fonts.UI, Vector2.new(1000, 40)).X
	end)
	if width <= 0 then
		width = (utf8.len(text) or #text) * 8.5
	end
	return math.clamp(math.ceil(width) + 72, 220, 520)
end

local function placeToasts()
	for i = #toasts, 1, -1 do
		if toasts[i].Parent ~= toastHolder then
			table.remove(toasts, i)
		end
	end
	for index, toast in toasts do
		Kit.tween(toast, 0.3, { Position = UDim2.new(0.5, 0, 0, (index - 1) * TOAST_STEP) }, Enum.EasingStyle.Quint)
	end
end

local function dismissToast(toast: Frame)
	local index = table.find(toasts, toast)
	if not index then
		return
	end
	table.remove(toasts, index)
	Kit.tween(toast, 0.18, { Position = toast.Position + UDim2.fromOffset(0, -12) }, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
	Kit.disappear(toast, { time = 0.18, destroy = true })
	placeToasts()
end

function Popups.toast(text: string, tone: string?)
	local style = TONES[tone or "info"] or TONES.info
	local toast = Kit.new("Frame", {
		Name = "Toast",
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(toastWidth(text), TOAST_H),
		Position = UDim2.new(0.5, 0, 0, -16),
		AnchorPoint = Vector2.new(0.5, 0),
		Parent = toastHolder,
	})
	local card = Kit.panel(toast, {
		Name = "Card",
		Size = UDim2.fromScale(1, 1),
		Radius = Kit.RADIUS.M,
	})
	local chip = Kit.new("Frame", {
		Name = "Icon",
		BackgroundColor3 = WHITE,
		Size = UDim2.fromOffset(30, 30),
		Position = UDim2.new(0, 8, 0.5, 0),
		AnchorPoint = Vector2.new(0, 0.5),
		ZIndex = 2,
		Parent = card,
	})
	Kit.round(chip)
	Kit.gradient(chip, Kit.lighten(style.color, 0.25), style.color)
	Kit.stroke(chip, 2, Kit.lip(style.color))
	local ink = Kit.inkOn(style.color)
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
	Kit.text(card, {
		Name = "Text",
		Text = text,
		Font = Theme.Fonts.UI,
		TextSize = 16,
		TextWrapped = false,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Size = UDim2.new(1, -60, 1, -4),
		Position = UDim2.fromOffset(48, 1),
		TextXAlignment = Enum.TextXAlignment.Left,
		StrokeThickness = 0,
		ZIndex = 2,
	})

	table.insert(toasts, 1, toast)
	while #toasts > MAX_TOASTS do
		dismissToast(toasts[#toasts])
	end
	placeToasts()
	Kit.appear(toast, { from = 0.9, time = 0.24 })
	if tone == "bad" then
		sounds.play("Error")
	else
		sounds.play("Toast")
	end
	task.delay(3, function()
		dismissToast(toast)
	end)
end

-- Floating text -------------------------------------------------------------------

-- "+$120" over the world: pops in, rises on a soft arc (steady sideways drift,
-- easing-out climb) and fades near the top.
function Popups.float(text: string, color: Color3, anchor: UDim2)
	local mover = Kit.new("Frame", {
		Name = "Float",
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(300, 44),
		Position = anchor,
		AnchorPoint = Vector2.new(0.5, 0.5),
		ZIndex = 20,
		Parent = screen,
	})
	local label = Kit.title(mover, {
		Name = "Text",
		Text = text,
		TextSize = 30,
		TextWrapped = false,
		Size = UDim2.fromScale(1, 1),
		TextColor3 = color,
		StrokeThickness = 0,
	})
	-- Over the 3D world: a solid navy outline.
	local outline = Kit.textStroke(label, 2.5, 0)
	local pop = Kit.new("UIScale", { Scale = 0.55, Parent = label })
	Kit.tween(pop, 0.28, { Scale = 1 }, Enum.EasingStyle.Back)
	local drift = math.random(-36, 36)
	Kit.tween(mover, 1.1, { Position = anchor + UDim2.fromOffset(drift, 0) }, Enum.EasingStyle.Linear)
	Kit.tween(label, 1.1, { Position = UDim2.fromOffset(0, -80) }, Enum.EasingStyle.Quad)
	tweenAfter(label, 0.4, 0.7, { TextTransparency = 1 })
	tweenAfter(outline, 0.4, 0.7, { Transparency = 1 })
	tweenAfter(pop, 0.4, 0.7, { Scale = 0.85 })
	task.delay(1.15, function()
		mover:Destroy()
	end)
end

-- Modal queue -------------------------------------------------------------------------
--[[
	One modal at a time: rewards, crate reveals, offline earnings, confirms and the
	tutorial completion card all go through here. Highest priority first, then
	arrival order. New arrivals wait a short "gather" window so cards that arrive
	together sort correctly, and the whole queue holds for 1 s after a Merge
	effect so the 3D fusion is seen before the card covers it.
]]

Popups.PRIORITY = { NewTier = 3, Tutorial = 2, Normal = 1 }

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
		schedule(0.05)
	end
	local ok, err = pcall(entry.show, done)
	if not ok then
		warn("[Popups] " .. entry.kind .. " failed: " .. tostring(err))
		done()
	end
end

-- Queue a modal. `show(done)` builds it and must call `done()` once it closes.
function Popups.enqueue(kind: string, priority: number, show: (done: () -> ()) -> (), data: { [string]: any }?)
	if PREVIEW then
		-- The preview captures right after the call: show it at once.
		local ok, err = pcall(show, function() end)
		if not ok then
			warn("[Popups] " .. kind .. " failed: " .. tostring(err))
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
	schedule(GATHER + 0.01)
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
	Every open overlay (modal, reward card, crate reveal) pushes a Back entry. B /
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
	local dim = Kit.backdrop(screen, zindex - 1)
	dim.Name = name .. "Backdrop"
	Kit.fadeBackdrop(dim, true, 0.55)
	Kit.setBlur(true)
	Kit.markOpen(screen, openKey, true)
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
	local box = Kit.panel(holder, {
		Name = "Box",
		Size = UDim2.fromOffset(size.X, size.Y),
		Position = UDim2.fromScale(0.5, 0.5),
		AnchorPoint = Vector2.new(0.5, 0.5),
		StrokeThickness = 2,
		Radius = Kit.RADIUS.XL,
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

-- Round toy badge: a coloured face with a white rim on a darker lip, sitting
-- across the top edge of a modal.
local function medallion(parent: Instance, icon: string, color: Color3, size: number, position: UDim2): Frame
	local depth = math.max(math.floor(size * 0.06), 3)
	local medal = Kit.new("Frame", {
		Name = "Medal",
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(size, size),
		Position = position,
		AnchorPoint = Vector2.new(0.5, 0.5),
		ZIndex = 3,
		Parent = parent,
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
local function crateIcon(parent: Instance, color: Color3, size: number, props: { [string]: any }?): Frame
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

-- Reward card ----------------------------------------------------------------------------

local function isBigBand(band: string): boolean
	return band == "Legendary" or band == "Mythic"
end

-- Other tiers discovered by the same action (payload.tiers minus the headline tier).
local function extraTiers(reward: { [string]: any }): { number }
	local extras = {}
	if type(reward.tiers) == "table" then
		for _, t in reward.tiers do
			if type(t) == "number" and t ~= reward.tier and Theme.Tiers[t] and not table.find(extras, t) then
				table.insert(extras, t)
			end
		end
	end
	return extras
end

local STRIP_HEIGHT = 78
local STRIP_SLOTS = 5
local CARD_WIDTH = 380
local CARD_HEIGHT = 500

-- "+N more new Chads!" strip: small tier medallions that pop in one by one
-- from `start` seconds.
local function discoveryStrip(card: Frame, extras: { number }, y: number, start: number, alive: () -> boolean)
	local strip = Kit.well(card, {
		Name = "MoreNew",
		Size = UDim2.new(1, -28, 0, STRIP_HEIGHT - 8),
		Position = UDim2.fromOffset(14, y),
		Radius = Kit.RADIUS.M,
	})
	Kit.title(strip, {
		Name = "Header",
		Text = string.format("+%d MORE NEW %s!", #extras, string.upper(if #extras == 1 then W.Unit else W.Units)),
		TextSize = T.Small,
		TextWrapped = false,
		Size = UDim2.new(1, -10, 0, 18),
		Position = UDim2.fromOffset(5, 3),
		TextColor3 = C.Gold,
		StrokeThickness = 0,
	})
	-- Before the slots exist, so the strip fade does not touch them.
	Kit.appear(strip, { from = 0.9, delay = start - 0.1 })
	local row = Kit.new("Frame", {
		Name = "Row",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, -10, 0, 46),
		Position = UDim2.fromOffset(5, 22),
		Parent = strip,
	})
	Kit.list(row, 4, true, Enum.HorizontalAlignment.Center)
	local shown = if #extras > STRIP_SLOTS then STRIP_SLOTS - 1 else #extras
	local function slot(order: number): Frame
		return Kit.new("Frame", {
			Name = "Slot" .. order,
			BackgroundTransparency = 1,
			Size = UDim2.fromOffset(62, 46),
			LayoutOrder = order,
			Parent = row,
		})
	end
	-- Hidden at once (keeping its layout slot), then eased in at `at`.
	local function popIn(frame: Frame, at: number, pitch: number?)
		Kit.appear(frame, { from = 0.3, time = 0.3, delay = at })
		if pitch then
			after(at, function()
				if alive() then
					sounds.play("Tick", 0.03, pitch)
				end
			end)
		end
	end
	for i = 1, shown do
		local t = extras[i]
		local tierColor = C.Rarity[Economy.tierBand(t)] or C.Gold
		local frame = slot(i)
		local medal = Kit.new("Frame", {
			Name = "Medal",
			BackgroundColor3 = WHITE,
			Size = UDim2.fromOffset(34, 34),
			Position = UDim2.fromScale(0.5, 0.5),
			AnchorPoint = Vector2.new(0.5, 0.5),
			Parent = frame,
		})
		Kit.round(medal)
		Kit.stroke(medal, 2, Kit.lip(tierColor))
		Kit.gradient(medal, Kit.lighten(tierColor, 0.3), tierColor)
		Kit.title(medal, {
			Text = tostring(t),
			TextSize = 16,
			TextWrapped = false,
			Size = UDim2.fromScale(1, 1),
			Position = UDim2.fromOffset(0, 1),
			TextColor3 = Kit.inkOn(tierColor),
			StrokeThickness = 0,
		})
		-- (No name under the chip: at this width it could only be tiny.)
		popIn(frame, start + i * 0.09, 1 + i * 0.08)
	end
	if shown < #extras then
		local frame = slot(STRIP_SLOTS)
		Kit.title(frame, {
			Text = "+" .. (#extras - shown),
			TextSize = 22,
			TextWrapped = false,
			Size = UDim2.new(1, 0, 0, 30),
			TextColor3 = C.Gold,
			StrokeThickness = 0,
		})
		popIn(frame, start + STRIP_SLOTS * 0.09, nil)
	end
end

-- One stat in the reward card's stat row: icon, caption, rolling number.
local function statCell(
	parent: Instance,
	icon: string,
	iconColor: Color3,
	caption: string,
	valueColor: Color3,
	order: number,
	width: UDim2
): TextLabel
	local cell = Kit.new("Frame", {
		Name = "Stat" .. order,
		BackgroundTransparency = 1,
		Size = width,
		LayoutOrder = order,
		Parent = parent,
	})
	Kit.icon(cell, icon, 30, iconColor, {
		Position = UDim2.new(0, 10, 0.5, 0),
		AnchorPoint = Vector2.new(0, 0.5),
	})
	Kit.text(cell, {
		Name = "Caption",
		Text = caption,
		Font = Theme.Fonts.UI,
		TextSize = 14,
		MaxTextSize = 14,
		TextScaled = true,
		TextWrapped = false,
		Size = UDim2.new(1, -52, 0, 17),
		Position = UDim2.fromOffset(46, 3),
		TextXAlignment = Enum.TextXAlignment.Left,
		TextColor3 = C.Text:Lerp(C.TextDim, 0.4),
		StrokeThickness = 0,
	})
	return Kit.number(cell, {
		Name = "Value",
		Text = "0",
		TextSize = 22,
		Size = UDim2.new(1, -52, 0, 24),
		Position = UDim2.fromOffset(46, 21),
		TextXAlignment = Enum.TextXAlignment.Left,
		TextColor3 = valueColor,
		StrokeThickness = 0,
	})
end

--[[
	The reward card builds in steps within about a second: card and banner,
	then the unit spins in on its stage, then its name and tier, then the stats
	roll up, then the button. Tap anywhere (or the button) to continue; it
	also closes by itself after a few seconds.
]]
local function showRewardCard(reward: { [string]: any }, done: () -> ())
	local tier = reward.tier
	local band = Economy.tierBand(tier)
	local color = C.Rarity[band] or C.Gold
	local extras = extraTiers(reward)
	local extraHeight = if #extras > 0 then STRIP_HEIGHT else 0

	-- "Reward" is kept inside the visible area by Kit.fit; "Body" inside it
	-- carries the appear / disappear animation.
	local root = Kit.new("Frame", {
		Name = "Reward",
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(CARD_WIDTH, CARD_HEIGHT + extraHeight),
		Position = UDim2.fromScale(0.5, 0.5),
		AnchorPoint = Vector2.new(0.5, 0.5),
		ZIndex = 30,
		Parent = screen,
	})
	Kit.fit(root, screen, Vector2.new(CARD_WIDTH, CARD_HEIGHT + extraHeight))
	local openKey = "Reward:" .. tostring(os.clock())
	Kit.markOpen(screen, openKey, true)
	local holder = Kit.new("Frame", {
		Name = "Body",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		ZIndex = 30,
		Parent = root,
	})
	local dim = cover(holder, "Dim", C.Ink, 0.45)
	Kit.appear(dim, { from = 1, time = 0.25 })
	local rays = Popups.rays(holder, Kit.lighten(color, 0.55), 660, UDim2.new(0.5, 0, 0, 200), 1, 7)
	Kit.appear(rays, { from = 0.3, time = 0.5, style = Enum.EasingStyle.Quart })
	if reward.new then
		-- A white counter-layer turning the other way for a fresh discovery.
		local inner = Popups.rays(holder, WHITE, 500, UDim2.new(0.5, 0, 0, 200), 1, 9, true)
		Kit.appear(inner, { from = 0.3, time = 0.55, style = Enum.EasingStyle.Quart })
	end

	local card = Kit.panel(holder, {
		Name = "Card",
		Size = UDim2.new(1, 0, 1, -24),
		Position = UDim2.fromOffset(0, 24),
		StrokeColor = color,
		StrokeThickness = 3,
		Radius = Kit.RADIUS.XL,
		ZIndex = 2,
	})
	-- Pastel stage in the rarity colour behind the unit, with a soft white
	-- sunburst turning slowly behind it (a CanvasGroup clips the rotating rays
	-- to the stage's rounded corners).
	local stage = Kit.new("Frame", {
		Name = "Stage",
		BackgroundColor3 = WHITE,
		BorderSizePixel = 0,
		Size = UDim2.new(1, -28, 0, 226),
		Position = UDim2.fromOffset(14, 34),
		ZIndex = 2,
		Parent = card,
	})
	Kit.corner(stage, Kit.RADIUS.L)
	Kit.gradient(stage, Kit.lighten(color, 0.55), color:Lerp(C.Surface, 0.25))
	Kit.new("UIStroke", { Thickness = 2, Color = WHITE, Transparency = 0.45, Parent = stage })
	local burst = Kit.new("CanvasGroup", {
		Name = "Burst",
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1),
		GroupTransparency = 0.25,
		ZIndex = 2,
		Parent = stage,
	})
	Kit.corner(burst, Kit.RADIUS.L)
	Popups.rays(burst, WHITE, 420, UDim2.fromScale(0.5, 0.56), 2, 10)
	local sun = circle(burst, "Sun", WHITE, 0.45, 2)
	sun.Size = UDim2.fromOffset(150, 150)
	sun.Position = UDim2.fromScale(0.5, 0.56)
	local spot = Kit.new("Frame", {
		Name = "Spot",
		BackgroundColor3 = Kit.lip(color),
		BackgroundTransparency = 0.55,
		BorderSizePixel = 0,
		Size = UDim2.fromOffset(170, 30),
		Position = UDim2.new(0.5, 0, 1, -26),
		AnchorPoint = Vector2.new(0.5, 0.5),
		ZIndex = 3,
		Parent = stage,
	})
	Kit.round(spot)
	Kit.appear(card, { from = 0.7, time = 0.32 })

	local banner = Kit.pill(holder, {
		Name = "Banner",
		Text = if reward.new then "NEW " .. string.upper(W.Unit) .. "!" else "YOU GOT",
		Solid = true,
		Color = if reward.new then C.Gold else C.SurfaceHi,
		Font = Theme.Fonts.Display,
		TextSize = 26,
		Size = UDim2.fromOffset(240, 46),
		Position = UDim2.new(0.5, 0, 0, 2),
		AnchorPoint = Vector2.new(0.5, 0),
		ZIndex = 3,
	})
	Kit.appear(banner, { from = 0.4, time = 0.32, delay = 0.08 })

	if reward.new then
		sounds.play(if isBigBand(band) then "CelebrateLegendary" else "Celebrate")
	elseif not reward._sounded then
		-- The crate reveal already played "Reward" when it landed.
		sounds.play("Reward")
	end

	local closed = false
	local spin: RBXScriptConnection? = nil
	local previous = selectedNow()
	local back: Back? = nil
	local function alive(): boolean
		return not closed and root.Parent ~= nil
	end
	local function close()
		if closed then
			return
		end
		closed = true
		if spin then
			spin:Disconnect()
		end
		if back then
			dropBack(back)
		end
		release(holder, previous)
		Kit.markOpen(screen, openKey, false)
		Kit.disappear(holder, {
			time = 0.18,
			onDone = function()
				root:Destroy()
				done()
			end,
		})
		-- The queue must never stall (done is idempotent).
		task.delay(0.4, done)
	end
	catcher(holder, 5).Activated:Connect(close)
	back = pushBack(30, close)

	-- Step 2: the unit turns in on its stage. It starts a little past its rest
	-- pose (never side-on or from behind), eases to the front three-quarter
	-- view the viewport camera frames, then idles with a gentle sway around it.
	after(0.14, function()
		if not alive() then
			return
		end
		local viewport = Kit.unitViewport(stage, tier, { Size = UDim2.fromScale(1, 1) })
		viewport.ZIndex = 4
		Kit.appear(viewport, { from = 0.35, time = 0.42 })
		local model = viewport:FindFirstChildOfClass("Model")
		if model and not PREVIEW then
			local rest = model:GetPivot()
			local started = os.clock()
			local TURN, FROM, SWAY = 0.9, -0.8, 0.2
			model:PivotTo(rest * CFrame.Angles(0, FROM, 0))
			spin = RunService.RenderStepped:Connect(function()
				if not root.Parent then
					if spin then
						spin:Disconnect()
					end
					return
				end
				local t = os.clock() - started
				local yaw
				if t < TURN then
					-- Back-out ease: a small overshoot past the front, then settle.
					local u = t / TURN - 1
					local eased = 1 + 2.2 * u * u * u + 1.2 * u * u
					yaw = FROM * (1 - eased)
				else
					local idle = t - TURN
					yaw = SWAY * math.sin(idle * 0.8) * math.min(1, idle / 1.5)
				end
				model:PivotTo(rest * CFrame.Angles(0, yaw, 0))
			end)
		end
		if reward.new then
			Kit.confetti(holder, {
				Origin = UDim2.new(0.5, 0, 0, 170),
				Count = if isBigBand(band) then 54 else 38,
				ZIndex = 4,
				Colors = { color, CANDY[1], CANDY[2], CANDY[3], CANDY[4], CANDY[5], CANDY[7] },
				Power = 1.15,
			})
		end
	end)

	-- Step 3: name and tier.
	after(0.4, function()
		if not alive() then
			return
		end
		-- Big name in the rarity colour, scaled down to fit on one line.
		local name = Kit.title(card, {
			Name = "UnitName",
			Text = string.upper(Theme.Tiers[tier].Name),
			TextSize = 38,
			TextScaled = true,
			MaxTextSize = 38,
			TextWrapped = false,
			Size = UDim2.new(1, -28, 0, 42),
			Position = UDim2.fromOffset(14, 266),
			TextColor3 = Kit.lighten(color, 0.12),
			StrokeThickness = 3,
			ZIndex = 2,
		})
		Kit.appear(name, { from = 0.6, time = 0.28 })
		local pill = Kit.pill(card, {
			Name = "Tier",
			Text = string.format("TIER %d  •  %s", tier, string.upper(band)),
			Solid = true,
			Color = color,
			TextSize = T.Small,
			Size = UDim2.fromOffset(0, 28),
			AutomaticSize = Enum.AutomaticSize.X,
			Position = UDim2.new(0.5, 0, 0, 312),
			AnchorPoint = Vector2.new(0.5, 0),
			ZIndex = 2,
		})
		Kit.appear(pill, { from = 0.6, time = 0.26, delay = 0.06 })
		sounds.play("Tick", 0.02, 1.2)
	end)

	-- Step 4: stats roll up.
	after(0.58, function()
		if not alive() then
			return
		end
		local stats = Kit.well(card, {
			Name = "Stats",
			Size = UDim2.new(1, -28, 0, 50),
			Position = UDim2.fromOffset(14, 348),
			Radius = Kit.RADIUS.M,
		})
		stats.ZIndex = 2
		Kit.list(stats, 0, true, Enum.HorizontalAlignment.Center)
		local hasGems = reward.gems and reward.gems > 0
		local width = if hasGems then UDim2.fromScale(0.5, 1) else UDim2.fromScale(1, 1)
		local rate = statCell(stats, "Orb", C.Orb, string.upper(W.Orb) .. " / SEC", Kit.lighten(C.Orb, 0.35), 1, width)
		Kit.appear(stats, { from = 0.9, time = 0.24 })
		Kit.countTo(rate, 0, Economy.unitRate(tier), function(n)
			return Format.short(n) .. "/s"
		end, 0.5)
		if hasGems then
			local gems = statCell(stats, "Gem", C.Rizz, "+" .. string.upper(W.Gem), Kit.lighten(C.Rizz, 0.35), 2, width)
			Kit.countTo(gems, 0, reward.gems, function(n)
				return "+" .. tostring(n)
			end, 0.55)
		end
	end)

	-- Step 5: the button.
	after(0.85, function()
		if not alive() then
			return
		end
		local button = Kit.button(holder, {
			Name = "Continue",
			Text = if reward.new then "AWESOME!" else "NICE!",
			Font = Theme.Fonts.Display,
			Color = C.Gold,
			Breathe = true,
			TextSize = 28,
			Size = UDim2.fromOffset(250, 58),
			Position = UDim2.new(0.5, 0, 1, -14),
			AnchorPoint = Vector2.new(0.5, 1),
			ZIndex = 6,
		}, close)
		button:SetAttribute("FocusFirst", true)
		Kit.appear(button, { from = 0.6, time = 0.28 })
		if not PREVIEW then
			Kit.focus(holder, button)
		end
	end)

	if #extras > 0 then
		discoveryStrip(card, extras, 404, 0.95, alive)
	end

	if not PREVIEW then
		task.delay((if reward.new then 4 else 3.4) + (if #extras > 0 then 0.4 + 0.11 * math.min(#extras, STRIP_SLOTS) else 0), close)
	end
end

local RARITY_RANK = { Common = 1, Uncommon = 2, Rare = 3, Epic = 4, Legendary = 5, Mythic = 6 }

-- Crate reveal: rising shakes (more for rarer crates, with a halo and a soft
-- tint building up), a burst (white ring, rays, confetti; a held breath before
-- Legendary+), a quick roll through the possible units, then the reward card.
-- 1.5-3 s; tap to skip.
local function crateReveal(reward: { [string]: any }, done: () -> ())
	if PREVIEW then
		showRewardCard(reward, done)
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
	local dim = cover(holder, "Dim", C.Ink, 0.66)
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
			showRewardCard(reward, done)
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
		-- One sound per reveal: a new discovery celebrates on the card instead.
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
			showRewardCard(data, done)
		end
	end, data)
end

-- Confirm dialog ---------------------------------------------------------------------------

function Popups.confirm(text: string, onYes: () -> (), options: { [string]: any }?)
	local opts = options or {}
	Popups.enqueue("Confirm", Popups.PRIORITY.Normal, function(done)
		local box, close = modal("Confirm", Vector2.new(460, 256), 50, nil, done)
		local medal = medallion(box, opts.icon or "?", C.Gold, 70, UDim2.new(0.5, 0, 0, 0))
		Kit.title(box, {
			Text = opts.title or "ARE YOU SURE?",
			TextSize = T.H2,
			TextWrapped = false,
			Size = UDim2.new(1, -30, 0, 32),
			Position = UDim2.fromOffset(15, 44),
			TextColor3 = C.Gold,
		})
		Kit.text(box, {
			Name = "Text",
			Text = text,
			TextSize = T.Body,
			Size = UDim2.new(1, -40, 0, 70),
			Position = UDim2.fromOffset(20, 80),
			StrokeThickness = 0,
		})
		local yes = Kit.button(box, {
			Text = opts.yes or "Yes",
			Color = C.Gold,
			Size = UDim2.new(0.5, -24, 0, 58),
			Position = UDim2.new(0, 16, 1, -76),
		}, function()
			close()
			onYes()
		end)
		local no = Kit.button(box, {
			Text = opts.no or "No",
			Color = C.SurfaceHi,
			Size = UDim2.new(0.5, -24, 0, 58),
			Position = UDim2.new(0.5, 8, 1, -76),
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

function Popups.offline(data: { [string]: any })
	Popups.enqueue("Offline", Popups.PRIORITY.Normal, function(done)
		local box, close = modal("Offline", Vector2.new(500, 330), 45, nil, done)
		local medal = medallion(box, "💤", C.Rizz, 84, UDim2.new(0.5, 0, 0, 0))
		Kit.title(box, {
			Text = "WELCOME BACK!",
			TextSize = T.H1,
			TextWrapped = false,
			Size = UDim2.new(1, -20, 0, 36),
			Position = UDim2.fromOffset(10, 50),
			TextColor3 = C.Gold,
		})
		Kit.text(box, {
			Text = string.format("Your %s kept grinding for %s.", W.Units, Format.time(data.seconds)),
			TextSize = T.Body,
			Size = UDim2.new(1, -30, 0, 24),
			Position = UDim2.fromOffset(15, 88),
			TextColor3 = C.TextDim,
			StrokeThickness = 0,
		})
		local well = Kit.well(box, { Size = UDim2.new(1, -40, 0, 66), Position = UDim2.fromOffset(20, 120) })
		local function amount(icon: string, iconColor: Color3, x: number, textColor: Color3): TextLabel
			local cell = Kit.new("Frame", {
				BackgroundTransparency = 1,
				Size = UDim2.new(0.42, 0, 1, 0),
				Position = UDim2.fromScale(x, 0),
				Parent = well,
			})
			Kit.icon(cell, icon, 30, iconColor, { Position = UDim2.new(0, 14, 0.5, 0), AnchorPoint = Vector2.new(0, 0.5) })
			return Kit.number(cell, {
				Text = "0",
				TextSize = 26,
				Size = UDim2.new(1, -54, 1, 0),
				Position = UDim2.fromOffset(50, 0),
				TextXAlignment = Enum.TextXAlignment.Left,
				TextColor3 = textColor,
				StrokeThickness = 0,
			})
		end
		local orbs = amount("Orb", C.Orb, 0, Kit.lighten(C.Orb, 0.35))
		Kit.title(well, {
			Text = "→",
			TextSize = 28,
			TextWrapped = false,
			Size = UDim2.new(0.16, 0, 1, 0),
			Position = UDim2.fromScale(0.42, 0),
			TextColor3 = C.TextMute,
			StrokeThickness = 0,
		})
		local cash = amount("Coin", C.Gold, 0.58, C.MoneyText)
		Kit.text(box, {
			Text = "Your cash is waiting on the Collect pad.",
			TextSize = T.Small,
			Size = UDim2.new(1, -40, 0, 34),
			Position = UDim2.fromOffset(20, 192),
			TextColor3 = C.TextDim,
			StrokeThickness = 0,
		})
		local go = Kit.button(box, {
			Text = "Let's go!",
			Font = Theme.Fonts.Display,
			Color = C.Gold,
			Breathe = true,
			Size = UDim2.new(1, -40, 0, 58),
			Position = UDim2.new(0, 20, 1, -76),
		}, close)
		go:SetAttribute("FocusFirst", true)
		Kit.appear(box)
		Kit.appear(medal, { from = 0.4, time = 0.32, delay = 0.06 })
		Kit.appear(go, { from = 0.8, time = 0.26, delay = 0.14 })
		local orbTotal = tonumber(data.orbs) or 0
		local cashTotal = tonumber(data.cash) or 0
		after(0.18, function()
			Kit.countTo(orbs, 0, orbTotal, Format.short, 0.7)
		end)
		after(0.32, function()
			Kit.countTo(cash, 0, cashTotal, Format.money, 0.8)
		end)
		sounds.play("Reward")
	end)
end

-- Game mode finish ----------------------------------------------------------------------------
--[[
	The Parkour finish card: "LEVEL n CLEAR!" (or "NEW BEST!") over the level's name,
	the run time, best and today's rank, the reward rolling up (cash; Rizz on the first
	clear) or a calm "Reward again in m:ss" line while the full reward is cooling down,
	and a popping "Level n+1 unlocked!" chip when this clear opened the next level.
	Buttons: "Next level" (gold, when there is one) beside "Run again", with slim "Choose
	map" (opens the Maps window) and "Back to my gym" under them; on the last level "Run
	again" beside "Back to my gym" with a slim "Choose map" under them. `data` is the finish Notify payload (time, best, newBest, rank?, cash, gems, full,
	cooldownEnds, level, levelName, nextLevel?, unlockedNew).
]]

local function runTime(seconds: number): string
	local tenths = math.floor(math.max(seconds, 0) * 10 + 0.5)
	return string.format("%d:%02d.%d", tenths // 600, (tenths // 10) % 60, tenths % 10)
end
Popups.runTime = runTime

function Popups.modeFinish(data: { [string]: any }, onAgain: () -> (), onHome: () -> (), onNext: (() -> ())?, onPick: (() -> ())?)
	Popups.enqueue("ModeFinish", Popups.PRIORITY.Normal, function(done)
		local cashTotal = tonumber(data.cash) or 0
		local gemTotal = tonumber(data.gems) or 0
		local cooling = data.full == false and (tonumber(data.cooldownEnds) or 0) > os.time()
		local level = tonumber(data.level)
		local nextLevel = tonumber(data.nextLevel)
		local hasNext = nextLevel ~= nil and onNext ~= nil
		local unlockedNew = data.unlockedNew == true and nextLevel ~= nil
		-- Height grows with the unlock chip and the third (slim) button.
		local noteY = if unlockedNew then 284 else 254
		local hasPick = onPick ~= nil
		local buttonsH = if hasNext or hasPick then 128 else 74
		local box, close = modal("ModeFinish", Vector2.new(480, noteY + 22 + 14 + buttonsH), 45, nil, done)
		local medal = medallion(box, "🏁", C.Gold, 84, UDim2.new(0.5, 0, 0, 0))
		Kit.title(box, {
			Text = if data.newBest then "NEW BEST!" elseif level then "LEVEL " .. tostring(level) .. " CLEAR!" else "COURSE CLEAR!",
			TextSize = T.H1,
			TextWrapped = false,
			Size = UDim2.new(1, -20, 0, 34),
			Position = UDim2.fromOffset(10, 48),
			TextColor3 = C.Gold,
		})
		local levelLine = if type(data.levelName) == "string" then data.levelName else ""
		if level and data.newBest then
			levelLine = "Level " .. tostring(level) .. (if levelLine ~= "" then "  ·  " .. levelLine else "")
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
			TextColor3 = C.Text,
		})
		local sub = "Best " .. runTime(tonumber(data.best) or tonumber(data.time) or 0)
		if type(data.rank) == "number" then
			sub ..= "  ·  #" .. tostring(data.rank) .. " today"
		end
		Kit.text(box, {
			Text = sub,
			TextSize = T.Body,
			Size = UDim2.new(1, -30, 0, 22),
			Position = UDim2.fromOffset(15, 156),
			TextColor3 = C.TextDim,
			StrokeThickness = 0,
		})
		local well = Kit.well(box, { Size = UDim2.new(1, -40, 0, 62), Position = UDim2.fromOffset(20, 184) })
		-- Runs inside the reward cooldown pay nothing: no empty "+$0" row.
		well.Visible = cashTotal > 0 or gemTotal > 0
		local function amount(icon: string, iconColor: Color3, x: number, width: number, textColor: Color3): TextLabel
			local cell = Kit.new("Frame", {
				BackgroundTransparency = 1,
				Size = UDim2.new(width, 0, 1, 0),
				Position = UDim2.fromScale(x, 0),
				Parent = well,
			})
			Kit.icon(cell, icon, 30, iconColor, { Position = UDim2.new(0, 14, 0.5, 0), AnchorPoint = Vector2.new(0, 0.5) })
			return Kit.number(cell, {
				Text = "+0",
				TextSize = 26,
				Size = UDim2.new(1, -54, 1, 0),
				Position = UDim2.fromOffset(50, 0),
				TextXAlignment = Enum.TextXAlignment.Left,
				TextColor3 = textColor,
				StrokeThickness = 0,
			})
		end
		local cashLabel = amount("Coin", C.Gold, 0, if gemTotal > 0 then 0.6 else 1, C.MoneyText)
		local gemLabel = if gemTotal > 0 then amount("Gem", C.Rizz, 0.6, 0.4, Kit.lighten(C.Rizz, 0.35)) else nil
		local note = Kit.text(box, {
			Text = if cooling
				then "Reward again in " .. Format.time(math.max(0, data.cooldownEnds - os.time()))
				else "Nice run! Try to beat your best.",
			TextSize = T.Small,
			Size = UDim2.new(1, -40, 0, 22),
			Position = UDim2.fromOffset(20, noteY),
			TextColor3 = C.TextDim,
			StrokeThickness = 0,
		})
		local unlockChip: TextLabel? = nil
		if unlockedNew then
			unlockChip = Kit.pill(box, {
				Name = "Unlocked",
				Text = "Level " .. tostring(nextLevel) .. " unlocked!",
				Font = Theme.Fonts.Display,
				TextSize = T.Small,
				Color = C.Good,
				Solid = true,
				Size = UDim2.fromOffset(200, 26),
				Position = UDim2.new(0.5, 0, 0, 252),
				AnchorPoint = Vector2.new(0.5, 0),
				ZIndex = 3,
			})
		end
		-- With a next level: [Next level] [Run again] and a slim "Back to my gym" below.
		local rowY = if hasNext or hasPick then -128 else -74
		local nextButton: TextButton? = nil
		if hasNext then
			nextButton = Kit.button(box, {
				Name = "Next",
				Text = "Next level ▶",
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
		if unlockChip then
			local chip = unlockChip
			chip.Visible = false
			after(0.7, function()
				chip.Visible = true
				Kit.pop(chip, 1.3)
				sounds.play("BuyPop")
			end)
		end
		Kit.confetti(box, { Origin = UDim2.fromScale(0.5, 0.1), Count = 24, ZIndex = 60 })
		after(0.12, function()
			Kit.pop(timeLabel, 1.2)
		end)
		after(0.25, function()
			Kit.countTo(cashLabel, 0, cashTotal, function(n)
				return "+" .. Format.money(n)
			end, 0.8)
		end)
		if gemLabel then
			after(0.45, function()
				Kit.countTo(gemLabel, 0, gemTotal, function(n)
					return "+" .. tostring(math.floor(n + 0.5))
				end, 0.6)
			end)
		end
		if cooling then
			-- The countdown line ticks while the card is up.
			task.spawn(function()
				while note.Parent do
					local left = (tonumber(data.cooldownEnds) or 0) - os.time()
					note.Text = if left > 0 then "Reward again in " .. Format.time(left) else "Reward ready next run!"
					task.wait(1)
				end
			end)
		end
		sounds.play("Reward")
	end)
end

--[[
	The MOG TEST finish card, in the same language as the Parkour one: the score,
	"NEW BEST!", rivals mogged, best and today's rank, the reward rolling up or the
	"Reward again in m:ss" line while the full reward cools down. "Mog again" and
	"Back to my gym". `data` is the mog finish Notify payload (score, rivals, best,
	newBest, passed, cash, gems, full, cooldownEnds, rank?).

	A 1v1 duel (data.vs == "pvp": won, reason "ko" | "forfeit", opponent { userId, name },
	score, wins, played, cash, gems, full, cooldownEnds) uses the same card: "YOU MOGGED
	<name>!" in gold or "<name> MOGGED YOU" in red, duels won / played, the reward (the
	winner's) and "Duel again" instead of "Mog again".
]]
function Popups.mogFinish(data: { [string]: any }, onAgain: () -> (), onHome: () -> ())
	Popups.enqueue("MogFinish", Popups.PRIORITY.Normal, function(done)
		local score = tonumber(data.score) or 0
		local cashTotal = tonumber(data.cash) or 0
		local gemTotal = tonumber(data.gems) or 0
		local cooling = data.full == false and (tonumber(data.cooldownEnds) or 0) > os.time()
		local duel = data.vs == "pvp"
		local won = duel and data.won == true
		local foe = if duel and type(data.opponent) == "table" then tostring(data.opponent.name or "Opponent") else "Opponent"
		local box, close = modal("MogFinish", Vector2.new(480, 380), 45, nil, done)
		local medal = medallion(
			box,
			if duel and not won then "😤" else "💪",
			if duel and not won then C.Bad else C.Gold,
			84,
			UDim2.new(0.5, 0, 0, 0)
		)
		Kit.title(box, {
			Text = if duel
				then (if won then "YOU MOGGED " .. string.upper(foe) .. "!" else string.upper(foe) .. " MOGGED YOU")
				elseif data.newBest then "NEW BEST!"
				else "MOG TEST OVER",
			TextScaled = duel,
			TextSize = T.H1,
			TextWrapped = false,
			Size = UDim2.new(1, -20, 0, 34),
			Position = UDim2.fromOffset(10, 48),
			TextColor3 = if duel and not won then C.Bad else C.Gold,
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
		elseif type(data.rank) == "number" then
			sub ..= "  ·  #" .. tostring(data.rank) .. " today"
		end
		Kit.text(box, {
			Text = sub,
			TextSize = T.Body,
			Size = UDim2.new(1, -30, 0, 22),
			Position = UDim2.fromOffset(15, 134),
			TextColor3 = C.TextDim,
			StrokeThickness = 0,
		})
		local well = Kit.well(box, { Size = UDim2.new(1, -40, 0, 62), Position = UDim2.fromOffset(20, 164) })
		well.Visible = cashTotal > 0 or gemTotal > 0
		local function amount(icon: string, iconColor: Color3, x: number, width: number, textColor: Color3): TextLabel
			local cell = Kit.new("Frame", {
				BackgroundTransparency = 1,
				Size = UDim2.new(width, 0, 1, 0),
				Position = UDim2.fromScale(x, 0),
				Parent = well,
			})
			Kit.icon(cell, icon, 30, iconColor, { Position = UDim2.new(0, 14, 0.5, 0), AnchorPoint = Vector2.new(0, 0.5) })
			return Kit.number(cell, {
				Text = "+0",
				TextSize = 26,
				Size = UDim2.new(1, -54, 1, 0),
				Position = UDim2.fromOffset(50, 0),
				TextXAlignment = Enum.TextXAlignment.Left,
				TextColor3 = textColor,
				StrokeThickness = 0,
			})
		end
		local cashLabel = amount("Coin", C.Gold, 0, if gemTotal > 0 then 0.6 else 1, C.MoneyText)
		local gemLabel = if gemTotal > 0 then amount("Gem", C.Rizz, 0.6, 0.4, Kit.lighten(C.Rizz, 0.35)) else nil
		local note = Kit.text(box, {
			Text = if duel and data.reason == "forfeit"
				then (if won then foe .. " left the duel. The win is yours!" else "You left the duel.")
				elseif duel and not won then "So close! Hit PERFECT to deal double damage."
				elseif cooling then "Reward again in " .. Format.time(math.max(0, data.cooldownEnds - os.time()))
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
		if gemLabel then
			after(0.45, function()
				Kit.countTo(gemLabel, 0, gemTotal, function(n)
					return "+" .. tostring(math.floor(n + 0.5))
				end, 0.6)
			end)
		end
		if cooling and not (duel and (not won or data.reason == "forfeit")) then
			task.spawn(function()
				while note.Parent do
					local left = (tonumber(data.cooldownEnds) or 0) - os.time()
					note.Text = if left > 0 then "Reward again in " .. Format.time(left) else "Reward ready next run!"
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

-- The three things in the pack in a well: cash, Rizz and the Rookie Trail. Returns the
-- amount labels and the trail's icon (for the celebration's pop-in).
local function starterContents(box: Frame, y: number, trailCaption: string): (TextLabel, TextLabel, Frame)
	local well = Kit.well(box, { Name = "Contents", Size = UDim2.new(1, -40, 0, 100), Position = UDim2.fromOffset(20, y) })
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
			Size = UDim2.new(1 / 3, 0, 1, 0),
			Position = UDim2.fromScale((index - 1) / 3, 0),
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
	local gems = cell(2, "Gem", "Gem", C.Rizz, Kit.lighten(C.Rizz, 0.35), W.Gem)
	local item = Theme.Cosmetics.Items[STARTER.Item]
	local trail, trailArt = cell(3, item.Icon, "Star", item.Color, C.Text, trailCaption)
	trail.Text = item.Title
	return cash, gems, trailArt
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
		local cash, gems = starterContents(box, 142, "only in this pack")
		local cashAmount, gemAmount = Windows.starterAmounts(data)
		cash.Text = State.money(cashAmount)
		gems.Text = "+" .. Format.commas(gemAmount)
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

-- The grant landed: what the pack gave, cash and Rizz rolling up and the trail popping in.
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
		local cash, gems, trailArt = starterContents(box, 142, "now in your shop")
		cash.Text = State.money(0)
		gems.Text = "+0"
		local go = Kit.button(box, {
			Name = "Go",
			Text = "Awesome!",
			Font = Theme.Fonts.Display,
			Color = C.Gold,
			Breathe = true,
			Size = UDim2.new(1, -40, 0, 58),
			Position = UDim2.new(0, 20, 1, -76),
		}, close)
		go:SetAttribute("FocusFirst", true)
		Kit.appear(box)
		Kit.appear(art, { from = 0.4, time = 0.34, delay = 0.06 })
		Kit.appear(go, { from = 0.8, time = 0.26, delay = 0.2 })
		local cashTotal = tonumber(data.cash) or 0
		local gemTotal = tonumber(data.gems) or 0
		after(0.2, function()
			Kit.countTo(cash, 0, cashTotal, State.money, 0.8)
		end)
		after(0.35, function()
			Kit.countTo(gems, 0, gemTotal, function(n: number): string
				return "+" .. Format.commas(n)
			end, 0.8)
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

--[[
	Side panel while the player carries a crate: rarity header, the crate, the
	odds (a scrolling list of rarity-dot rows; bars fill), then one primary
	"Open now" button, the free route as a plain line, a quiet text link to the
	Crate Master pass, and at the bottom (well apart from "Open now") a red
	Discard button (discards at once, any rarity). The "ChestPanel" holder carries the compact-mode
	UIScale; the "Card" inside eases in and out with Kit.appear / Kit.disappear.
	While it is up the ScreenGui attribute "CratePanelOpen" is true (the held
	crate's world chip hides then, so the two labels never show together).
]]
local function buildChestPanel()
	local action = Net.event("Action")
	-- Card geometry: header band, crate, odds well, then the button rows from BUTTON_Y.
	local PANEL_W = 320
	local ODDS_Y = 172
	local ODDS_H = 128
	local BUTTON_Y = ODDS_Y + ODDS_H + 12
	local holder = Kit.new("Frame", {
		Name = "ChestPanel",
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(PANEL_W, 440),
		Position = UDim2.new(1, -12, 0.5, 30),
		AnchorPoint = Vector2.new(1, 0.5),
		Parent = screen,
	})
	local compactScale = Kit.new("UIScale", { Name = "Compact", Parent = holder })
	local panel = Kit.panel(holder, {
		Name = "Card",
		Size = UDim2.fromScale(1, 1),
		Position = UDim2.fromScale(0.5, 0.5),
		AnchorPoint = Vector2.new(0.5, 0.5),
		Visible = false,
		StrokeThickness = 2,
		Radius = Kit.RADIUS.XL,
	})
	local band = Kit.new("Frame", {
		Name = "Band",
		BackgroundColor3 = WHITE,
		BorderSizePixel = 0,
		Size = UDim2.new(1, -16, 0, 46),
		Position = UDim2.fromOffset(8, 8),
		Parent = panel,
	})
	Kit.corner(band, Kit.RADIUS.L)
	local bandStroke = Kit.stroke(band, 2, Kit.lip(C.Gold))
	local bandGradient = Kit.gradient(band, C.Gold, C.Gold)
	local bandShine = Kit.new("Frame", {
		Name = "Highlight",
		BackgroundColor3 = WHITE,
		BackgroundTransparency = 0.4,
		BorderSizePixel = 0,
		Size = UDim2.new(1, -28, 0, 2),
		Position = UDim2.fromOffset(14, 3),
		Parent = band,
	})
	Kit.round(bandShine)
	local title = Kit.title(band, {
		Text = "",
		TextSize = T.H2,
		TextWrapped = false,
		Size = UDim2.fromScale(1, 1),
		Position = UDim2.fromOffset(0, 1),
		StrokeThickness = 0,
	})

	local halo = Kit.new("Frame", {
		Name = "IconGlow",
		BackgroundColor3 = WHITE,
		BackgroundTransparency = 0.6,
		BorderSizePixel = 0,
		Size = UDim2.fromOffset(88, 88),
		Position = UDim2.new(0.5, 0, 0, 102),
		AnchorPoint = Vector2.new(0.5, 0.5),
		Parent = panel,
	})
	Kit.round(halo)
	local crate: Frame? = nil

	Kit.title(panel, {
		Text = "POSSIBLE " .. string.upper(W.Units),
		Font = Theme.Fonts.UI,
		TextSize = T.Small,
		TextWrapped = false,
		Size = UDim2.new(1, -28, 0, 18),
		Position = UDim2.fromOffset(14, ODDS_Y - 22),
		TextXAlignment = Enum.TextXAlignment.Left,
		TextColor3 = C.TextDim,
		StrokeThickness = 0,
	})
	local oddsWell = Kit.well(panel, { Name = "Odds", Size = UDim2.new(1, -24, 0, ODDS_H), Position = UDim2.fromOffset(12, ODDS_Y) })
	local odds = Kit.scrolling(oddsWell, { Name = "List", Size = UDim2.new(1, -8, 1, -8), Position = UDim2.fromOffset(4, 4) })
	Kit.padding(odds, 2, 4)
	Kit.list(odds, 3)

	-- Instant open: free for Crate Master owners ("owner"); otherwise one developer
	-- product (same price for every rarity) with the Crate Master pass as a quiet text
	-- link under it ("buy"). Both purchases are hidden where paid random items are not
	-- allowed ("none"). The free route is always a plain readable line.
	local crateOpen = Theme.Monetization.CrateOpen
	local crateKey = Theme.Monetization.Passes.CrateKey
	local mode = "none"
	local openButton = Kit.button(panel, {
		Name = "OpenNow",
		Text = "Open now",
		Color = C.Gold,
		Size = UDim2.new(1, -24, 0, 56),
		Position = UDim2.fromOffset(12, BUTTON_Y),
		TextSize = 24,
	}, function()
		action:FireServer({ action = "OpenCrateNow" })
	end)
	openButton:SetAttribute("FocusFirst", true)
	local masterTag = Kit.pill(panel, {
		Name = "MasterTag",
		Text = string.upper(crateKey.Title),
		Color = crateKey.Color,
		Solid = true,
		TextSize = T.Small,
		Size = UDim2.fromOffset(0, 22),
		AutomaticSize = Enum.AutomaticSize.X,
		Position = UDim2.fromOffset(PANEL_W - 8, BUTTON_Y - 10),
		AnchorPoint = Vector2.new(1, 0),
		ZIndex = 6,
		Visible = false,
	})
	local crackerName = string.gsub(string.lower(W.Unlocker), "%f[%a]%a", string.upper)
	local freeLine = Kit.text(panel, {
		Name = "FreeRoute",
		Text = "Carry it to a " .. crackerName .. ": free",
		TextSize = T.Small,
		Size = UDim2.new(1, -32, 0, 22),
		Position = UDim2.fromOffset(16, BUTTON_Y + 64),
		TextColor3 = C.Text,
		StrokeThickness = 0,
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
		BUTTON_Y + 88,
		PANEL_W - 40,
		function()
			Kit.sound("Click")
			action:FireServer({ action = "PromptPass", name = "CrateKey" })
		end
	)
	-- Discard: a red button at the bottom of the card, DISCARD_GAP below the rows above it.
	-- It discards the held crate at once, whatever its rarity.
	local DISCARD_H, DISCARD_GAP = 44, 14
	local discard = Kit.button(panel, {
		Name = "Discard",
		Text = "Discard",
		Icon = "Close",
		IconColor = WHITE,
		TextColor = WHITE,
		Color = C.Danger,
		Size = UDim2.fromOffset(150, DISCARD_H),
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, BUTTON_Y + 48 + DISCARD_GAP),
		TextSize = T.Body,
		Sound = "Close",
	}, function()
		action:FireServer({ action = "DiscardChest" })
	end)

	-- Lays the panel out for `newMode` (rows from BUTTON_Y down): the open button, the
	-- free-route line, the pass link (buy only), Discard. Without an open button the
	-- free route takes the button's place at body size.
	local function setMode(newMode: string)
		if newMode == mode then
			return
		end
		local wasButton = mode ~= "none"
		mode = newMode
		local hasButton = newMode ~= "none"
		local buying = newMode == "buy"
		if hasButton and not wasButton then
			Kit.appear(openButton, { from = 0.9, time = 0.2 })
		elseif not hasButton and wasButton then
			Kit.disappear(openButton)
		end
		if newMode == "owner" then
			Kit.setButton(openButton, "Open now")
			Kit.appear(masterTag, { from = 0.6, time = 0.25 })
		else
			Kit.setButton(openButton, "Open now   " .. Kit.ROBUX .. " " .. crateOpen.Price)
			if masterTag.Visible then
				Kit.disappear(masterTag)
			end
		end
		if buying then
			Kit.appear(passLink, { from = 0.9, time = 0.2, delay = 0.05 })
		elseif passLink.Visible then
			Kit.disappear(passLink)
		end
		local y = BUTTON_Y
		if hasButton then
			y += 56 + 8
		end
		local freeHeight = if hasButton then 22 else 44
		Kit.tween(freeLine, 0.25, {
			Position = UDim2.fromOffset(16, y),
			Size = UDim2.new(1, -32, 0, freeHeight),
			TextSize = if hasButton then T.Small else T.Body,
		})
		y += freeHeight + 4
		if buying then
			passLink.Position = UDim2.new(0.5, 0, 0, y)
			y += 30 + 2
		end
		y += DISCARD_GAP
		Kit.tween(discard, 0.25, { Position = UDim2.new(0.5, 0, 0, y) })
		Kit.tween(holder, 0.25, { Size = UDim2.fromOffset(PANEL_W, y + DISCARD_H + 12) })
	end
	openButton.Visible = false
	passLink.Visible = false
	freeLine.Position = UDim2.fromOffset(16, BUTTON_Y)
	freeLine.Size = UDim2.new(1, -32, 0, 44)
	freeLine.TextSize = T.Body
	holder.Size = UDim2.fromOffset(PANEL_W, BUTTON_Y + 48 + DISCARD_GAP + DISCARD_H + 12)

	local function fullScale(): number
		return if screen:GetAttribute("Compact") == true then 0.8 else 1
	end
	screen:GetAttributeChangedSignal("Compact"):Connect(function()
		compactScale.Scale = fullScale()
	end)
	compactScale.Scale = fullScale()

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
				Size = UDim2.new(1, 0, 0, 24),
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
				Size = UDim2.new(0, 36, 1, 0),
				Position = UDim2.fromOffset(24, 0),
				TextXAlignment = Enum.TextXAlignment.Left,
				TextColor3 = C.TextDim,
				StrokeThickness = 0,
			})
			Kit.text(row, {
				Text = Theme.Tiers[entry.tier].Name,
				Font = Theme.Fonts.UI,
				TextSize = T.Small,
				TextWrapped = false,
				TextTruncate = Enum.TextTruncate.AtEnd,
				Size = UDim2.new(1, -118, 1, 0),
				Position = UDim2.fromOffset(60, 0),
				TextXAlignment = Enum.TextXAlignment.Left,
				TextColor3 = Kit.lighten(tierColor, 0.35),
				StrokeThickness = 0,
			})
			Kit.number(row, {
				Text = entry.chance .. "%",
				TextSize = T.Small,
				Size = UDim2.new(0, 54, 1, 0),
				Position = UDim2.new(1, -4, 0, 0),
				AnchorPoint = Vector2.new(1, 0),
				TextXAlignment = Enum.TextXAlignment.Right,
				StrokeThickness = 0,
			})
			table.insert(rows, row)
		end
		Kit.stagger(rows)
	end

	local shownFor = ""
	local open = false
	State.changed.Event:Connect(function(data)
		local rarity = data.heldChest
		if rarity == nil or rarity == "" then
			shownFor = ""
			if open then
				open = false
				Kit.unfocus(panel)
				Kit.disappear(panel)
				Kit.hidePlayerList("crate", false)
				screen:SetAttribute("CratePanelOpen", false)
			end
			return
		end
		if not open then
			open = true
			-- Fx/Crates hides the held crate's own world chip while this is true.
			screen:SetAttribute("CratePanelOpen", true)
			Kit.appear(panel, { from = 0.85, time = 0.26 })
			-- The default player list sits over the panel's header on short screens.
			Kit.hidePlayerList("crate", true)
		end
		local color = C.Rarity[rarity] or C.Gold
		local key = rarity .. ":" .. data.highestTier
		if key ~= shownFor then
			shownFor = key
			title.Text = string.upper(rarity .. " " .. W.Chest)
			title.TextColor3 = Kit.inkOn(color)
			bandGradient.Color = ColorSequence.new(Kit.lighten(color, 0.22), color)
			bandStroke.Color = Kit.lip(color)
			halo.BackgroundColor3 = Kit.lighten(color, 0.45)
			if crate then
				crate:Destroy()
			end
			local icon = crateIcon(panel, color, 80, {
				Rarity = rarity,
				Position = UDim2.new(0.5, 0, 0, 102),
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

function Popups.build(screenGui: ScreenGui, soundModule: any)
	screen = screenGui
	sounds = soundModule
	toastHolder = Kit.new("Frame", {
		Name = "Toasts",
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(560, 230),
		Position = UDim2.new(0.5, 0, 0, TOAST_Y),
		AnchorPoint = Vector2.new(0.5, 0),
		ZIndex = 25,
		Parent = screen,
	})
	-- Slide toasts below the tutorial card while it sits at the top centre.
	local function placeHolder()
		local offset = screen:GetAttribute("TopCardHeight")
		local y = TOAST_Y + (if type(offset) == "number" then offset else 0)
		Kit.tween(toastHolder, 0.3, { Position = UDim2.new(0.5, 0, 0, y) }, Enum.EasingStyle.Quad)
	end
	screen:GetAttributeChangedSignal("TopCardHeight"):Connect(placeHolder)
	placeHolder()
	buildChestPanel()
	if not PREVIEW then
		-- The server's one-time Starter grant (other Notify kinds are routed by Main).
		Net.event("Notify").OnClientEvent:Connect(function(payload)
			if type(payload) == "table" and payload.kind == "Starter" then
				Popups.starter(payload)
			end
		end)
	end
	watchStarterOffer()
end

return Popups
