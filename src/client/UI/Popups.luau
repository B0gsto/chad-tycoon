--[[
	Popups: toasts, reward reveals, the held-crate panel, confirm dialogs,
	offline earnings and floating "+X" text.

	Everything eases: popups come in with Kit.appear and leave with
	Kit.disappear, toasts slide into a stack, floats rise on an arc, numbers
	count up. Celebrations use the candy colours of Theme.World (confetti,
	soft rays, a white ring on bursts); nothing flashes the whole screen.

	A unit reveal is not a dialog: the unit floats over the dimmed world with
	its text straight on the scene, and a new discovery flies off into the
	HUD's Index button (see showReveal).

	Z order (ScreenGui uses Sibling ZIndex):
	  floats 20, toasts 25, reward 30, offline 44-45, starter 46-47, confirm 49-50,
	  cash rain 50
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

-- Where the stack sits (y, design px) and how many toasts it may show there. Under the
-- HUD's top strips (and the tutorial card) normally; while a window or modal is open, at
-- the very top, as many as fit above it: none when the window reaches the top of the
-- screen or the tutorial pill holds that slot.
local function toastRoom(): (number, number)
	local card = screen:GetAttribute("TopCardHeight")
	local cardH: number = if type(card) == "number" then card else 0
	if screen:GetAttribute("WindowOpen") ~= true then
		return TOAST_Y + cardH, MAX_TOASTS
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
		mergeTally += math.max(1, math.floor(tonumber(data.count) or 1))
		mergeTallyAt = now
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
	effect so the 3D fusion is seen before the reveal covers it.
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

local function isBigBand(band: string): boolean
	return band == "Legendary" or band == "Mythic"
end

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
local HERO = 320
local EXTRAS_H = 66
local EXTRA_SLOTS = 5
local VEIL = Kit.darken(C.Ink, 0.4)

-- Timing (seconds). Left alone, a discovery takes REVEAL_HOLD + ORB_MORPH +
-- ORB_FLIGHT = 2.5 s, and input is free again from the moment the hold ends.
local REVEAL_MIN = 0.35 -- an earlier tap waits until the unit has popped in
local REVEAL_HOLD = 1.9 -- entrance (0.3) + hold (1.6) before it leaves by itself
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

	A new discovery then leaves for the Index. After REVEAL_HOLD, or on any tap,
	click, A, B or Escape, input is free again, the HUD slides back and the unit
	shrinks into an orb that flies into the Index button (Hud.indexPoint), which
	bounces and counts it (Hud.punchIndex); the other units follow one by one.
	With no button to land on (a window is open, the menu is hidden) the orbs
	leave by the top-left corner. A unit that is not new, and any unit under the
	reduced-motion setting, just fades where it stands.
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
	-- A merge batch brought this discovery: its "xN MERGES!" line gets a row under the
	-- stats (the text itself may still be on its way: Fx.Shelf floats it at the last pop).
	local now = os.clock()
	local mergesSeen: string? = if isNew and now - mergesAt < MERGES_FRESH then mergesText else nil
	local mergesRow = isNew and (mergesSeen ~= nil or (now - mergeTallyAt < MERGES_FRESH and mergeTally >= MERGES_MIN))
	mergesAt, mergeTally = 0, 0
	-- Text sizes held on the glass: a phone's UI scale would take the 30 px label to 19 and
	-- the 22 px tier line to 14. What the text gains the unit gives up, so the stage keeps
	-- its height (and Kit.fit does not shrink it all again).
	-- Kit.fit may still scale the stage a little (a short screen): the sizes count that in.
	local area = Kit.designArea(screen)
	local share = if Kit.touch then Theme.Glass.FitTouch else Theme.Glass.Fit
	local stageBase = 196 + HERO + (if #extras > 0 then EXTRAS_H else 0) + (if mergesRow then 32 else 0)
	local fit = if area then math.min(1, area.X * share / STAGE_W, area.Y * share / stageBase) else 1
	local bannerSize = Kit.px(28 / fit, 30, screen)
	local nameSize = Kit.px(30 / fit, 48, screen)
	local tierSize = Kit.px(18 / fit, 22, screen)
	local statSize = Kit.px(18 / fit, 26, screen)
	local heroSize = math.max(HERO - (bannerSize - 30) - (nameSize - 48) - (tierSize - 22) - (statSize - 26), 200)
	local heroY = bannerSize + 6 + heroSize / 2
	local nameY = heroY + heroSize / 2
	local tierY = nameY + nameSize + 8
	local statsY = tierY + tierSize + 12
	local mergesY = statsY + statSize + 10
	local stageH = statsY + statSize + 8 + (if mergesRow then tierSize + 10 else 0) + 36
	local height = stageH + (if #extras > 0 then EXTRAS_H else 0)

	-- A window underneath (the shop, the Index) is busy: the veil goes deep and even over it,
	-- the window dims to about Theme.Glass.RevealDim behind the name and comes back when the
	-- veil lifts. Toasts and the tutorial pill step out (setReveal).
	local overWindow = screen:GetAttribute("WindowOpen") == true
	local openKey = "Reward:" .. tostring(os.clock())
	setReveal(true)
	-- The lighter frost: the Chad's plot stays readable behind the reveal.
	Kit.setBlur(true, true)

	local root = Kit.new("Frame", {
		Name = "Reward",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		ZIndex = 30,
		Parent = screen,
	})
	-- Veil: navy across the middle band (about 40 %), thinning out toward the edges.
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
	local window = 1 - Theme.Glass.RevealDim
	Kit.new("UIGradient", {
		Rotation = 90,
		Transparency = if overWindow
			then NumberSequence.new({
				NumberSequenceKeypoint.new(0, window),
				NumberSequenceKeypoint.new(0.3, window * 0.5),
				NumberSequenceKeypoint.new(0.8, window * 0.4),
				NumberSequenceKeypoint.new(1, window),
			})
			else NumberSequence.new({
				NumberSequenceKeypoint.new(0, 0.92),
				NumberSequenceKeypoint.new(0.36, 0.62),
				NumberSequenceKeypoint.new(0.74, 0.6),
				NumberSequenceKeypoint.new(1, 0.78),
			}),
		Parent = veil,
	})
	-- The count behind WindowOpen is given back if the reveal's gui is destroyed.
	Kit.markOpen(screen, openKey, true, root)
	Kit.tween(veil, 0.25, { BackgroundTransparency = 0 })

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
	local rays = Popups.rays(stage, Kit.lighten(color, 0.55), 600 + rank * 24, heroAt, 1, 6 + rank)
	Kit.appear(rays, { from = 0.3, time = 0.5, style = Enum.EasingStyle.Quart })
	table.insert(lights, rays)
	if isNew then
		-- A white counter-layer turning the other way for a fresh discovery.
		local inner = Popups.rays(stage, WHITE, 440, heroAt, 1, 9, true)
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
	local viewport = Kit.unitViewport(hero, tier, { Size = UDim2.fromScale(1, 1) })
	Kit.appear(hero, { from = 0.15, time = 0.4 + 0.02 * rank })
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
		-- Epic and up land with a second bump.
		if rank >= 4 then
			task.delay(0.5 + 0.02 * rank, function()
				if hero.Parent then
					Kit.pop(hero, 0.3 * (rank - 2))
				end
			end)
		end
	end
	if isNew and not calm then
		Kit.confetti(stage, {
			Origin = heroAt,
			Count = 12 + rank * 4,
			ZIndex = 4,
			Colors = { color, CANDY[1], CANDY[2], CANDY[3], CANDY[4], CANDY[5], CANDY[7] },
			Power = 0.95 + 0.08 * rank,
		})
	end

	if isNew then
		sounds.play(if isBigBand(band) then "CelebrateLegendary" else "Celebrate")
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
			viewport.Position = UDim2.fromOffset(0, math.sin(t * 2.4) * BOB * math.min(1, t / 0.6))
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
			Text = if isNew then "NEW " .. string.upper(W.Unit) .. "!" else "YOU GOT",
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
		-- A soft dark plate behind the name and the stats (no box, no border: a tinted
		-- soft dot stretched wide) so they hold over a busy plot.
		local plate = softDot(stage, "Plate", Theme.Glass.Tint, UDim2.fromOffset(STAGE_W, 250), 0.22, 2)
		plate.Position = UDim2.new(0.5, 0, 0, (nameY + statsY + statSize + 8) / 2)
		table.insert(lines, plate)
		Kit.appear(plate, { from = 0.9, time = 0.3 })
		-- Big name in the rarity colour, scaled down to fit on one line.
		arrive(Kit.hudText(stage, {
			Name = "UnitName",
			Text = string.upper(Theme.Tiers[tier].Name),
			TextSize = nameSize,
			TextScaled = true,
			MaxTextSize = nameSize,
			TextColor3 = Kit.lighten(color, 0.15),
			StrokeColor = Theme.Glass.TextInk,
			Size = UDim2.new(1, -40, 0, nameSize + 6),
			Position = UDim2.fromOffset(20, nameY),
			StrokeThickness = 3,
			ZIndex = 5,
		}))
		sounds.play("Tick", 0.02, 1.2)
	end)
	after(0.38, function()
		if not alive() then
			return
		end
		arrive(Kit.hudText(stage, {
			Name = "Tier",
			Text = string.format("TIER %d  •  %s", tier, string.upper(band)),
			TextSize = tierSize,
			TextColor3 = Kit.lighten(color, 0.55),
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
		local rate = statPair(stats, "Orb", C.Orb, perSecond(Economy.unitRate(tier)), Kit.lighten(C.Orb, 0.4), 1, statSize)
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
		Kit.countTo(rate, 0, Economy.unitRate(tier), perSecond, 0.45)
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
	local function leave()
		if closed then
			return
		end
		closed = true
		openModals[leave] = nil
		if spin then
			spin:Disconnect()
		end
		if back then
			dropBack(back)
		end
		release(root, previous)
		skip:Destroy()
		Kit.setBlur(false, true)
		Kit.markOpen(screen, openKey, false)
		endReveal()
		Kit.tween(veil, 0.35, { BackgroundTransparency = 1 })
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

		if not isNew or calm then
			-- Nothing flies: the units fade where they stand (a calm discovery still
			-- counts on the Index).
			Kit.disappear(hero, { time = 0.2, to = 0.85 })
			for _, portrait in portraits do
				Kit.disappear(portrait.gui, { time = 0.2, to = 0.85 })
			end
			task.delay(0.3, function()
				if isNew and Hud.indexPoint() then
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
	-- Popups.closeModals (the capture hook, the preview) ends a reveal too.
	openModals[leave] = true
	back = pushBack(30, dismiss)
	if not PREVIEW and (Kit.gamepad or Kit.tenFoot) then
		-- Gamepad: the catcher holds the selection (with no ring), so A continues too.
		skip.Selectable = true
		skip.SelectionImageObject = Kit.new("Frame", { BackgroundTransparency = 1 })
		Kit.focus(skip, skip)
	end

	-- A small faded hint, only for a player who has not continued after a second.
	after(REVEAL_HINT, function()
		if not alive() then
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
		local hold = if tutorial then REVEAL_HOLD_TUTORIAL else REVEAL_HOLD
		task.delay(hold + (if #portraits > 0 then 0.25 else 0), leave)
	end
end

-- Crate reveal: rising shakes (more for rarer crates, with a halo and a soft
-- tint building up), a burst (white ring, rays, confetti; a held breath before
-- Legendary+), a quick roll through the possible units, then the unit reveal.
-- 1.5-3 s; tap to skip.
local function crateReveal(reward: { [string]: any }, done: () -> ())
	if PREVIEW then
		showReveal(reward, done)
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
			showReveal(reward, done)
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
			showReveal(data, done)
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
	The Parkour finish card: "LEVEL n CLEAR!" (or "NEW BEST!") over the level's name,
	the run time, best and the rank on this server's board, the cash reward rolling up or a
	calm "Reward again in m:ss" line while the full reward is cooling down,
	and a popping "Level n+1 unlocked!" chip when this clear opened the next level.
	Buttons: "Next level" (gold, when there is one) beside "Run again", with slim "Choose
	map" (opens the Maps window) and "Back to my gym" under them; on the last level "Run
	again" beside "Back to my gym" with a slim "Choose map" under them. `data` is the finish Notify payload (time, best, newBest, rank?, cash, full,
	cooldownEnds, level, levelName, nextLevel?, unlockedNew, assisted?). An assisted run (gear or a
	skipped stage) shows "Assisted run" instead of the best / rank line.
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

function Popups.modeFinish(data: { [string]: any }, onAgain: () -> (), onHome: () -> (), onNext: (() -> ())?, onPick: (() -> ())?)
	Popups.enqueue("ModeFinish", Popups.PRIORITY.Normal, function(done)
		local cashTotal = tonumber(data.cash) or 0
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
			Text = if data.newBest and data.assisted ~= true
				then "NEW BEST!"
				elseif level then "LEVEL " .. tostring(level) .. " CLEAR!"
				else "COURSE CLEAR!",
			TextSize = T.H1,
			TextWrapped = false,
			Size = UDim2.new(1, -20, 0, 34),
			Position = UDim2.fromOffset(10, 48),
			TextColor3 = C.Gold,
		})
		local levelLine = if type(data.levelName) == "string" then data.levelName else ""
		if level and data.newBest and data.assisted ~= true then
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
		-- An assisted run (worn gear) never sets a best or a board entry.
		local assisted = data.assisted == true
		local sub = "Best " .. runTime(tonumber(data.best) or tonumber(data.time) or 0)
		if type(data.rank) == "number" then
			sub ..= "  ·  #" .. tostring(data.rank) .. " on this server"
		end
		Kit.text(box, {
			Name = if assisted then "Assisted" else "Best",
			Text = if assisted then "Assisted run" else sub,
			Font = if assisted then Kit.F.UI else nil,
			TextSize = T.Body,
			Size = UDim2.new(1, -30, 0, 22),
			Position = UDim2.fromOffset(15, 156),
			TextColor3 = if assisted then C.Rizz else C.TextDim,
			StrokeThickness = 0,
		})
		local well = Kit.well(box, { Glass = true, Size = UDim2.new(1, -40, 0, 62), Position = UDim2.fromOffset(20, 184) })
		-- Runs inside the reward cooldown pay nothing: no empty "+$0" row.
		well.Visible = cashTotal > 0
		local cashLabel = cashRow(well, cashTotal)
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
	"NEW BEST!", rivals mogged, best and the rank on this server's board, the reward rolling up or the
	"Reward again in m:ss" line while the full reward cools down. "Mog again" and
	"Back to my gym". `data` is the mog finish Notify payload (score, rivals, best,
	newBest, passed, cash, full, cooldownEnds, rank?).

	A 1v1 duel (data.vs == "pvp": won, reason "ko" | "forfeit", opponent { userId, name },
	score, wins, played, cash, full, cooldownEnds, afk?, rounds?, draw?, close?) uses the
	same card: "YOU MOGGED <name>!" in gold, "<name> MOGGED YOU" in red or a plain "DRAW!",
	duels won / played, the reward (the winner's) and "Duel again" instead of "Mog again".
	The line under the reward says how it ended: an idle forfeit (afk), a player who left
	(forfeit), a draw, and "So close!" only for a loss the server calls close (data.close: a
	small HP margin or sudden death).
]]
function Popups.mogFinish(data: { [string]: any }, onAgain: () -> (), onHome: () -> ())
	Popups.enqueue("MogFinish", Popups.PRIORITY.Normal, function(done)
		local score = tonumber(data.score) or 0
		local cashTotal = tonumber(data.cash) or 0
		local cooling = data.full == false and (tonumber(data.cooldownEnds) or 0) > os.time()
		local duel = data.vs == "pvp"
		local won = duel and data.won == true
		local draw = duel and data.draw == true
		local lost = duel and not won and not draw
		local foe = if duel and type(data.opponent) == "table" then tostring(data.opponent.name or "Opponent") else "Opponent"
		local box, close = modal("MogFinish", Vector2.new(480, 380), 45, nil, done)
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
		end
		local color = C.Rarity[rarity] or C.Gold
		local key = rarity .. ":" .. data.highestTier
		if key ~= shownFor then
			shownFor = key
			title.Text = string.upper(rarity .. " " .. W.Chest)
			title.TextColor3 = Kit.lighten(color, 0.3)
			divider.BackgroundColor3 = Kit.lighten(color, 0.2)
			halo.BackgroundColor3 = Kit.lighten(color, 0.45)
			-- The Smasher's timer for this rarity (its first slot).
			freePrice.Text = if Economy.CHEST_INFO[rarity]
				then "FREE  •  " .. Format.time(Economy.unlockSeconds(rarity, false))
				else "FREE"
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
	end
	screen:GetAttributeChangedSignal("TopCardHeight"):Connect(function()
		placeHolder()
		flushToasts()
	end)
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
