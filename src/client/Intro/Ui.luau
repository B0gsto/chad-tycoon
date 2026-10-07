--!strict
--[[
	Intro.Ui: the cutscene's screen overlay and world bubbles.

	Screen (ScreenGui "IntroUI", DisplayOrder 80: above the HUD, below the loading screen):
	letterbox bars, the subtitle card (cream card with Ink text, sized to its line and
	kept just above the bottom bar), a quiet Skip button bottom-right, the MAX GIGA CHAD
	name card, the game title card, a white flash and a full-screen fade.

	Layout is computed in pixels from the real screen size (and recomputed when it
	changes): every card is clamped inside a safe area (6% / 5% margins plus the Roblox
	top-bar inset), scaled by `k` = screen size relative to 1280x720 (clamped 0.6..1.6).
	Text uses TextScaled under a UITextSizeConstraint, so it shrinks instead of clipping.
	Nothing uses CanvasGroup: cards fade by tweening each element's own transparency.

	World (BillboardGuis under the stage): speech / thought bubbles and the hero's name
	and AURA tag. Everything tweens in and out.
]]

local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local TextService = game:GetService("TextService")
local Workspace = game:GetService("Workspace")

local Kit = require(script.Parent.Parent.UI.Kit)

local Ui = {}
Ui.__index = Ui

local BAR = 0.1 -- letterbox bar height (screen fraction)
local SAFE_X = 0.06 -- side margins (screen fraction), clears phone notches
local SAFE_Y = 0.05 -- top / bottom margins
local OUT = Enum.EasingStyle.Quad
local BACK = Enum.EasingStyle.Back

export type Ui = typeof(setmetatable(
	{} :: {
		theme: any,
		gui: ScreenGui,
		k: number,
		width: number,
		height: number,
		safe: Rect,
		top: Frame,
		bottom: Frame,
		caption: Frame,
		captionScale: UIScale,
		captionLabel: TextLabel,
		captionText: string,
		captionToken: number,
		skip: TextButton,
		skipHit: TextButton,
		nameCardGui: Frame?,
		titleCardGui: Frame?,
		flashFrame: Frame,
		fadeFrame: Frame,
		world: Folder,
		tag: BillboardGui?,
		tagStat: TextLabel?,
		tagPill: Frame?,
		tagPillScale: UIScale?,
		statFrom: number,
		statTo: number,
		statStart: number,
		statDur: number,
		statShown: number,
		clock: number,
		connections: { RBXScriptConnection },
	},
	Ui
))

local function new(className: string, props: { [string]: any }, parent: Instance?): any
	local inst = Instance.new(className)
	for key, value in props do
		(inst :: any)[key] = value
	end
	if parent then
		inst.Parent = parent
	end
	return inst
end

local function corner(parent: Instance, radius: number)
	new("UICorner", { CornerRadius = UDim.new(0, radius) }, parent)
end

-- A TextScaled label that never grows past `maxSize` and never clips.
local function scaledText(parent: Instance, props: { [string]: any }, maxSize: number): TextLabel
	props.BackgroundTransparency = 1
	props.TextScaled = true
	props.TextWrapped = if props.TextWrapped == nil then true else props.TextWrapped
	local label = new("TextLabel", props, parent)
	new("UITextSizeConstraint", { MaxTextSize = math.max(math.floor(maxSize), 9), MinTextSize = 8 }, label)
	return label
end

local function setMaxText(label: Instance, maxSize: number)
	local c = label:FindFirstChildOfClass("UITextSizeConstraint")
	if c then
		c.MaxTextSize = math.max(math.floor(maxSize), 9)
	end
end

-- Width/height of `text` at `size`, wrapped at `maxWidth`.
local function measure(text: string, size: number, font: Enum.Font, maxWidth: number): Vector2
	local ok, bounds = pcall(function()
		return TextService:GetTextSize(text, size, font, Vector2.new(maxWidth, 10000))
	end)
	if ok and bounds.X > 0 then
		return bounds
	end
	local w = (utf8.len(text) or #text) * size * 0.55
	local lines = math.max(math.ceil(w / maxWidth), 1)
	return Vector2.new(math.min(w, maxWidth), lines * size * 1.2)
end

-- Fades a whole card (every background, text and stroke) to its built look or out.
-- The built transparencies are remembered as attributes on first use.
local function fadeTree(root: Instance, visible: boolean, t: number)
	local items = root:GetDescendants()
	table.insert(items, root)
	for _, inst in items do
		local props: { [string]: number } = {}
		local function track(attr: string, prop: string)
			local base = inst:GetAttribute(attr)
			if base == nil then
				base = (inst :: any)[prop]
				inst:SetAttribute(attr, base)
			end
			props[prop] = if visible then base :: number else 1
		end
		if inst:IsA("GuiObject") then
			track("FadeBg", "BackgroundTransparency")
			if inst:IsA("TextLabel") or inst:IsA("TextButton") then
				track("FadeText", "TextTransparency")
			end
		elseif inst:IsA("UIStroke") then
			track("FadeStroke", "Transparency")
		end
		if next(props) then
			if t <= 0 then
				for prop, value in props do
					(inst :: any)[prop] = value
				end
			else
				Kit.tween(inst, t, props, OUT)
			end
		end
	end
end

-- A rounded card with a coloured header band (the band's lower corners squared off).
local function bandCard(parent: Instance, W: any, bandColor: Color3, bandFrac: number, radius: number): (Frame, Frame)
	local card = new("Frame", {
		BackgroundColor3 = W.Cream,
		BorderSizePixel = 0,
		AnchorPoint = Vector2.new(0.5, 0.5),
		ZIndex = 10,
	}, parent)
	corner(card, radius)
	new("UIStroke", { Color = W.Ink, Thickness = 3, Transparency = 0.1 }, card)
	local band = new("Frame", {
		Name = "Band",
		BackgroundColor3 = bandColor,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, bandFrac),
		ZIndex = 11,
	}, card)
	corner(band, radius)
	new("Frame", {
		Name = "BandFill",
		BackgroundColor3 = bandColor,
		BorderSizePixel = 0,
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.fromScale(0, bandFrac),
		Size = UDim2.new(1, 0, bandFrac * 0.5, 0),
		ZIndex = 11,
	}, card)
	return card, band
end

function Ui.new(theme: any, worldParent: Instance, onSkip: () -> ()): Ui
	local W = theme.World
	local C = theme.Colors
	local F = theme.Fonts
	local player = Players.LocalPlayer

	local gui = new("ScreenGui", {
		Name = "IntroUI",
		Enabled = true,
		ResetOnSpawn = false,
		IgnoreGuiInset = true,
		DisplayOrder = 80,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
	})

	-- Letterbox bars (they slide in from the screen edges).
	local top = new("Frame", {
		Name = "BarTop",
		BackgroundColor3 = C.Ink,
		BorderSizePixel = 0,
		AnchorPoint = Vector2.new(0, 1),
		Size = UDim2.fromScale(1, BAR),
		Position = UDim2.fromScale(0, 0),
		ZIndex = 1,
	}, gui)
	local bottom = new("Frame", {
		Name = "BarBottom",
		BackgroundColor3 = C.Ink,
		BorderSizePixel = 0,
		AnchorPoint = Vector2.new(0, 0),
		Size = UDim2.fromScale(1, BAR),
		Position = UDim2.fromScale(0, 1),
		ZIndex = 1,
	}, gui)

	-- Subtitle card: sized to its line in relayout, sitting just above the bottom bar.
	local caption = new("Frame", {
		Name = "Caption",
		BackgroundColor3 = W.Cream,
		BorderSizePixel = 0,
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1 - BAR, -12),
		Size = UDim2.fromOffset(200, 54),
		Visible = false,
		ZIndex = 15,
	}, gui)
	corner(caption, 18)
	new("UIStroke", { Color = W.Ink, Thickness = 2.5, Transparency = 0.15 }, caption)
	local captionScale = new("UIScale", {}, caption)
	local captionLabel = scaledText(caption, {
		Name = "Text",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(1, 1),
		Font = F.UI,
		TextColor3 = W.Ink,
		Text = "",
		ZIndex = 16,
	}, 26)
	fadeTree(caption, false, 0)

	-- Skip: small and quiet, bottom-right inside the letterbox bar.
	local skip = new("TextButton", {
		Name = "Skip",
		AutoButtonColor = false,
		BackgroundColor3 = W.White,
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1 - SAFE_X, 0, 1 - BAR / 2, 0),
		Size = UDim2.fromOffset(92, 34),
		Font = F.UI,
		TextScaled = true,
		TextColor3 = W.Ink,
		TextTransparency = 1,
		Text = theme.Intro.Skip .. "  »",
		Visible = false,
		ZIndex = 18,
	}, gui)
	new("UICorner", { CornerRadius = UDim.new(0.5, 0) }, skip)
	new("UIPadding", {
		PaddingTop = UDim.new(0.2, 0),
		PaddingBottom = UDim.new(0.2, 0),
		PaddingLeft = UDim.new(0.12, 0),
		PaddingRight = UDim.new(0.12, 0),
	}, skip)
	new("UITextSizeConstraint", { MaxTextSize = 20, MinTextSize = 10 }, skip)
	skip.Activated:Connect(onSkip)
	-- Gamepad: Skip takes the shared selection ring (B also skips, see Cutscene).
	pcall(Kit.selectable, skip)
	-- Touch: an invisible hit area at least 48 px each way, centred on the pill (sized in
	-- _layout), so the quiet button keeps its look but takes a thumb.
	local skipHit = new("TextButton", {
		Name = "Hit",
		AutoButtonColor = false,
		BackgroundTransparency = 1,
		Selectable = false,
		Text = "",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(104, 48),
		ZIndex = 19,
	}, skip)
	skipHit.Activated:Connect(onSkip)

	local flashFrame = new("Frame", {
		Name = "Flash",
		BackgroundColor3 = W.White,
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1),
		ZIndex = 40,
	}, gui)
	local fadeFrame = new("Frame", {
		Name = "Fade",
		BackgroundColor3 = W.Cream,
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1),
		ZIndex = 50,
	}, gui)

	local world = new("Folder", { Name = "IntroBubbles" }, worldParent)

	local self = setmetatable({
		theme = theme,
		gui = gui,
		k = 1,
		width = 1280,
		height = 720,
		safe = Rect.new(0, 0, 1280, 720),
		top = top,
		bottom = bottom,
		caption = caption,
		captionScale = captionScale,
		captionLabel = captionLabel,
		captionText = "",
		captionToken = 0,
		skip = skip,
		skipHit = skipHit,
		nameCardGui = nil,
		titleCardGui = nil,
		flashFrame = flashFrame,
		fadeFrame = fadeFrame,
		world = world,
		tag = nil,
		tagStat = nil,
		tagPill = nil,
		tagPillScale = nil,
		statFrom = 0,
		statTo = 0,
		statStart = 0,
		statDur = 0,
		statShown = -1,
		clock = 0,
		connections = {},
	}, Ui)

	gui.Parent = player and player:FindFirstChildOfClass("PlayerGui")

	local function relayout()
		self:_relayout()
	end
	relayout()
	local camera = Workspace.CurrentCamera
	if camera then
		table.insert(self.connections, camera:GetPropertyChangedSignal("ViewportSize"):Connect(relayout))
	end
	table.insert(self.connections, gui:GetPropertyChangedSignal("AbsoluteSize"):Connect(relayout))
	return self
end

-- Layout --------------------------------------------------------------------------------

-- Recomputes the screen size, safe area and scale, then re-places every screen card.
function Ui._relayout(self: Ui)
	local size = self.gui.AbsoluteSize
	if size.X < 2 or size.Y < 2 then
		local camera = Workspace.CurrentCamera
		size = if camera then camera.ViewportSize else Vector2.new(1280, 720)
	end
	if size.X < 2 or size.Y < 2 then
		size = Vector2.new(1280, 720)
	end
	local w, h = size.X, size.Y
	local insetTop = 0
	local ok, topLeft = pcall(function()
		return (GuiService:GetGuiInset())
	end)
	if ok and typeof(topLeft) == "Vector2" then
		insetTop = topLeft.Y
	end
	self.width, self.height = w, h
	self.k = math.clamp(math.min(w / 1280, h / 720), 0.6, 1.6)
	self.safe = Rect.new(w * SAFE_X, math.max(h * SAFE_Y, insetTop), w * (1 - SAFE_X), h * (1 - SAFE_Y))

	local k = self.k
	local skipW, skipH = math.floor(96 * k), math.floor(math.min(36 * k, h * BAR * 0.7))
	self.skip.Size = UDim2.fromOffset(skipW, skipH)
	self.skipHit.Size = UDim2.fromOffset(math.max(skipW + 8, 48), math.max(skipH + 12, 48))
	setMaxText(self.skip, 20 * k)

	self:_layoutCaption()
	if self.nameCardGui then
		self:_layoutNameCard(self.nameCardGui)
	end
	if self.titleCardGui then
		self:_layoutTitleCard(self.titleCardGui)
	end
end

function Ui._layoutCaption(self: Ui)
	local k = self.k
	local textSize = math.floor(26 * k + 0.5)
	local padX, padY = math.floor(24 * k), math.floor(12 * k)
	local maxWidth = self.width * 0.9
	local text = if self.captionText == "" then " " else self.captionText
	local bounds = measure(text, textSize, self.theme.Fonts.UI, maxWidth - padX * 2)
	local cw = math.min(math.ceil(bounds.X) + padX * 2 + 4, maxWidth)
	local ch = math.ceil(bounds.Y) + padY * 2 + 2
	self.caption.Size = UDim2.fromOffset(cw, ch)
	self.caption.Position = UDim2.new(0.5, 0, 1 - BAR, -math.floor(12 * k))
	local label = self.captionLabel
	label.Size = UDim2.new(1, -padX * 2, 1, -padY * 2)
	setMaxText(label, textSize)
	local c = self.caption:FindFirstChildOfClass("UICorner")
	if c then
		c.CornerRadius = UDim.new(0, math.floor(math.min(18 * k, ch / 2)))
	end
end

function Ui._layoutNameCard(self: Ui, card: Frame)
	local safe, k = self.safe, self.k
	local cw = math.min(safe.Width * 0.46, 430 * k)
	local ch = cw / 2.9
	-- Upper left of the safe area (the rival stands in the right third); 8 px spare
	-- for the tilt.
	local cx = safe.Min.X + cw / 2 + 8
	local cy = math.clamp(self.height * 0.24, safe.Min.Y + ch / 2 + 8, safe.Max.Y - ch / 2 - 8)
	card.Size = UDim2.fromOffset(cw, ch)
	card.Position = UDim2.fromOffset(cx, cy)
	for _, label in card:GetDescendants() do
		if label:IsA("TextLabel") then
			setMaxText(label, (label:GetAttribute("MaxText") :: number? or 40) * k)
		end
	end
end

function Ui._layoutTitleCard(self: Ui, card: Frame)
	local safe, k = self.safe, self.k
	local cw = math.min(self.width * 0.7, safe.Width, 640 * k)
	local ch = cw * 0.26
	local cy = math.clamp(self.height * 0.36, safe.Min.Y + ch / 2, safe.Max.Y - ch / 2)
	card.Size = UDim2.fromOffset(cw, ch)
	card.Position = UDim2.fromOffset(self.width / 2, cy)
	for _, label in card:GetDescendants() do
		if label:IsA("TextLabel") then
			setMaxText(label, 64 * k)
		end
	end
end

-- Letterbox ---------------------------------------------------------------------------

function Ui.letterbox(self: Ui, on: boolean, instant: boolean?)
	local t = if instant then 0 else 0.45
	local topPos = if on then UDim2.fromScale(0, BAR) else UDim2.fromScale(0, 0)
	local bottomPos = if on then UDim2.fromScale(0, 1 - BAR) else UDim2.fromScale(0, 1)
	if t == 0 then
		self.top.Position = topPos
		self.bottom.Position = bottomPos
	else
		Kit.tween(self.top, t, { Position = topPos }, Enum.EasingStyle.Quart)
		Kit.tween(self.bottom, t, { Position = bottomPos }, Enum.EasingStyle.Quart)
	end
end

-- Captions ------------------------------------------------------------------------------

-- Shows `text` at once: the card is fully readable within ~0.2 s.
function Ui.say(self: Ui, text: string)
	self.captionToken += 1
	local caption = self.caption
	local wasShown = caption.Visible and (caption:GetAttribute("Shown") == true)
	self.captionText = text
	self.captionLabel.Text = text
	self:_layoutCaption()
	caption.Visible = true
	caption:SetAttribute("Shown", true)
	if wasShown then
		-- Swapping lines: the card stays up and gives a small pop.
		fadeTree(caption, true, 0.1)
		self.captionScale.Scale = 0.96
		Kit.tween(self.captionScale, 0.18, { Scale = 1 }, BACK)
	else
		self.captionScale.Scale = 0.9
		fadeTree(caption, true, 0.15)
		Kit.tween(self.captionScale, 0.22, { Scale = 1 }, BACK)
	end
end

function Ui.hideCaption(self: Ui)
	self.captionToken += 1
	local token = self.captionToken
	local caption = self.caption
	caption:SetAttribute("Shown", false)
	if not caption.Visible then
		return
	end
	fadeTree(caption, false, 0.22)
	task.delay(0.24, function()
		if token == self.captionToken and caption.Parent then
			caption.Visible = false
		end
	end)
end

-- Skip button ---------------------------------------------------------------------------

function Ui.showSkip(self: Ui)
	local skip = self.skip
	skip.Visible = true
	Kit.tween(skip, 0.35, { BackgroundTransparency = 0.25, TextTransparency = 0.1 }, OUT)
	-- On a controller the selection sits on Skip, so A skips as well as B.
	if Kit.gamepad or Kit.tenFoot then
		pcall(function()
			GuiService.SelectedObject = skip
		end)
	end
end

-- Name card ----------------------------------------------------------------------------

-- MAX GIGA CHAD's card slams in on the right; `onLand` runs when it hits.
function Ui.nameCard(self: Ui, onLand: (() -> ())?)
	local theme = self.theme
	local W, F = theme.World, theme.Fonts
	if self.nameCardGui then
		self.nameCardGui:Destroy()
	end
	local card, band = bandCard(self.gui, W, W.Sunny, 0.56, 20)
	card.Name = "NameCard"
	card.Rotation = -3
	self.nameCardGui = card
	-- The name sits over the band but belongs to the card: the band's square-off fill is a
	-- later sibling of the band and would otherwise draw over the lower half of the letters.
	local bandFrac = band.Size.Y.Scale
	local nameLabel = scaledText(card, {
		Name = "Name",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, bandFrac * 0.52),
		Size = UDim2.fromScale(0.9, bandFrac * 0.72),
		Font = F.Display,
		TextColor3 = W.Ink,
		TextWrapped = false,
		Text = theme.Intro.RivalName,
		ZIndex = 12,
	}, 44)
	nameLabel:SetAttribute("MaxText", 44)
	local statLabel = scaledText(card, {
		Name = "Stat",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.78),
		Size = UDim2.fromScale(0.86, 0.32),
		Font = F.Display,
		TextColor3 = W.Ink,
		TextWrapped = false,
		Text = theme.Intro.RivalStat,
		ZIndex = 12,
	}, 32)
	statLabel:SetAttribute("MaxText", 32)
	self:_layoutNameCard(card)

	-- Slam: drops from big to a touch small, then settles with a Back overshoot.
	local cardScale = new("UIScale", { Scale = 2.2 }, card)
	fadeTree(card, false, 0)
	fadeTree(card, true, 0.1)
	Kit.tween(cardScale, 0.14, { Scale = 0.93 }, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
	task.delay(0.14, function()
		if card.Parent then
			Kit.tween(cardScale, 0.24, { Scale = 1 }, BACK)
			if onLand then
				onLand()
			end
		end
	end)
end

function Ui.hideNameCard(self: Ui)
	local card = self.nameCardGui
	if not card then
		return
	end
	self.nameCardGui = nil
	fadeTree(card, false, 0.28)
	Kit.tween(card, 0.3, { Position = card.Position + UDim2.fromOffset(math.floor(40 * self.k), 0) }, OUT)
	task.delay(0.32, function()
		card:Destroy()
	end)
end

-- Title card ----------------------------------------------------------------------------

function Ui.title(self: Ui, on: boolean, instant: boolean?)
	local theme = self.theme
	local W, F = theme.World, theme.Fonts
	if not on then
		local card = self.titleCardGui
		self.titleCardGui = nil
		if card then
			fadeTree(card, false, 0.28)
			task.delay(0.32, function()
				card:Destroy()
			end)
		end
		return
	end
	if self.titleCardGui then
		return
	end
	local card = new("Frame", {
		Name = "TitleCard",
		BackgroundColor3 = W.Cream,
		BorderSizePixel = 0,
		AnchorPoint = Vector2.new(0.5, 0.5),
		ClipsDescendants = false,
		ZIndex = 10,
	}, self.gui)
	self.titleCardGui = card
	corner(card, 26)
	new("UIStroke", { Color = W.Ink, Thickness = 3, Transparency = 0.1 }, card)
	-- Candy stripe header band, inset so it sits inside the rounded corners.
	local stripes = { W.Coral, W.Sunny, W.Mint, W.Blue, W.Pink }
	local strip = new("Frame", {
		Name = "Stripes",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.fromScale(0.5, 0.1),
		Size = UDim2.fromScale(0.86, 0.1),
		ZIndex = 11,
	}, card)
	for i, color in stripes do
		local s = new("Frame", {
			BackgroundColor3 = color,
			BorderSizePixel = 0,
			Position = UDim2.fromScale((i - 1) / #stripes, 0),
			Size = UDim2.new(1 / #stripes, -4, 1, 0),
			ZIndex = 11,
		}, strip)
		corner(s, 6)
	end
	scaledText(card, {
		Name = "Title",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.6),
		Size = UDim2.fromScale(0.88, 0.56),
		Font = F.Display,
		TextColor3 = W.Ink,
		TextWrapped = false,
		Text = theme.GameName,
		ZIndex = 12,
	}, 64)
	self:_layoutTitleCard(card)
	local cardScale = new("UIScale", { Scale = if instant then 1 else 0.6 }, card)
	if not instant then
		fadeTree(card, false, 0)
		fadeTree(card, true, 0.22)
		Kit.tween(cardScale, 0.4, { Scale = 1 }, BACK)
	end
end

-- Flash and fade ---------------------------------------------------------------------------

function Ui.flash(self: Ui, dur: number)
	local f = self.flashFrame
	local inTime = dur * 0.4
	Kit.tween(f, inTime, { BackgroundTransparency = 0 }, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
	task.delay(inTime, function()
		if f.Parent then
			Kit.tween(f, dur - inTime, { BackgroundTransparency = 1 }, OUT)
		end
	end)
end

function Ui.fade(self: Ui, on: boolean, t: number)
	Kit.tween(self.fadeFrame, t, { BackgroundTransparency = if on then 0 else 1 }, OUT)
end

-- World bubbles ----------------------------------------------------------------------------

-- A speech (or thought) bubble at `offset` (world studs) from `adornee`.
function Ui.bubble(self: Ui, adornee: BasePart, offset: Vector3, text: string, dur: number, thought: boolean?)
	local W, F = self.theme.World, self.theme.Fonts
	local textSize = 38
	local cardH = 70
	local width = math.max(96, math.ceil(measure(text, textSize, F.Display, 1000).X) + 44)
	local bb = new("BillboardGui", {
		Name = "Bubble",
		Adornee = adornee,
		AlwaysOnTop = true,
		LightInfluence = 0,
		MaxDistance = 500,
		Size = UDim2.fromOffset(width + 8, cardH + 40),
		StudsOffsetWorldSpace = offset,
		ResetOnSpawn = false,
	}, self.world)
	local root = new("Frame", { BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1) }, bb)
	local s = new("UIScale", { Scale = 0.05 }, root)
	local card = new("Frame", {
		BackgroundColor3 = W.White,
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 2),
		Size = UDim2.fromOffset(width, cardH),
		ZIndex = 2,
	}, root)
	corner(card, 28)
	new("UIStroke", { Color = W.Ink, Thickness = 3, Transparency = 0.1 }, card)
	scaledText(card, {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.new(1, -24, 1, -14),
		Font = F.Display,
		TextColor3 = W.Ink,
		TextWrapped = false,
		Text = text,
		ZIndex = 3,
	}, textSize)
	if thought then
		for i, d in { 20, 12 } do
			local dot = new("Frame", {
				BackgroundColor3 = W.White,
				AnchorPoint = Vector2.new(0.5, 0),
				Position = UDim2.new(0.5, (i - 1) * 10, 0, cardH + 6 + (i - 1) * 18),
				Size = UDim2.fromOffset(d, d),
				ZIndex = 2,
			}, root)
			corner(dot, d)
			new("UIStroke", { Color = W.Ink, Thickness = 2.5, Transparency = 0.1 }, dot)
		end
	else
		local tail = new("Frame", {
			BackgroundColor3 = W.White,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.new(0.5, 0, 0, cardH + 2),
			Size = UDim2.fromOffset(22, 22),
			Rotation = 45,
			ZIndex = 1,
		}, root)
		new("UIStroke", { Color = W.Ink, Thickness = 3, Transparency = 0.1 }, tail)
	end
	Kit.tween(s, 0.28, { Scale = 1 }, BACK)
	task.delay(math.max(dur - 0.2, 0.1), function()
		if bb.Parent then
			Kit.tween(s, 0.18, { Scale = 0.05 }, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
			task.delay(0.2, function()
				bb:Destroy()
			end)
		end
	end)
end

-- The hero's tag: his name over an "AURA: n" pill (Sunny, turning Coral at zero).
-- Sized in studs, so it reads like a sign above his head in every shot.
-- Shows or hides the hero's tag (switched on camera cuts, so it never pops on screen).
function Ui.tagShown(self: Ui, on: boolean)
	if self.tag then
		self.tag.Enabled = on
	end
end

function Ui.heroTag(self: Ui, adornee: BasePart, height: number, name: string, aura: number)
	local W, F = self.theme.World, self.theme.Fonts
	if self.tag then
		self.tag:Destroy()
	end
	local bb = new("BillboardGui", {
		Name = "HeroTag",
		Adornee = adornee,
		AlwaysOnTop = true,
		LightInfluence = 0,
		MaxDistance = 120,
		Size = UDim2.fromScale(5.2, 2.3),
		StudsOffsetWorldSpace = Vector3.new(0, height, 0),
		ResetOnSpawn = false,
	}, self.world)
	local namePill = new("Frame", {
		Name = "Name",
		BackgroundColor3 = W.White,
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.fromScale(0.5, 0),
		Size = UDim2.fromScale(0.7, 0.4),
	}, bb)
	corner(namePill, 999)
	new("UIStroke", { Color = W.Ink, Thickness = 2, Transparency = 0.2 }, namePill)
	scaledText(namePill, {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(0.86, 0.74),
		Font = F.UI,
		TextColor3 = W.Ink,
		TextWrapped = false,
		Text = name,
	}, 40)
	local pill = new("Frame", {
		Name = "Aura",
		BackgroundColor3 = W.Sunny,
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.fromScale(0.5, 1),
		Size = UDim2.fromScale(1, 0.54),
	}, bb)
	corner(pill, 999)
	new("UIStroke", { Color = W.Ink, Thickness = 3, Transparency = 0.05 }, pill)
	local pillScale = new("UIScale", {}, pill)
	local stat = scaledText(pill, {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(0.84, 0.72),
		Font = F.Display,
		TextColor3 = W.Ink,
		TextWrapped = false,
		Text = string.format(self.theme.Intro.Stat, aura),
	}, 56)
	self.tag = bb
	self.tagStat = stat
	self.tagPill = pill
	self.tagPillScale = pillScale
	self.statFrom, self.statTo, self.statShown = aura, aura, aura
	self:_paintStat(aura)
end

-- Sunny pill with Ink text normally; Coral pill with White text at zero.
function Ui._paintStat(self: Ui, value: number)
	local W = self.theme.World
	local pill, label = self.tagPill, self.tagStat
	if pill and label then
		local zero = value <= 0
		Kit.tween(pill, 0.2, { BackgroundColor3 = if zero then W.Coral else W.Sunny }, OUT)
		label.TextColor3 = if zero then W.White else W.Ink
	end
end

-- Counts the hero's AURA tag between two values over `dur` seconds.
function Ui.countStat(self: Ui, from: number, to: number, dur: number)
	self.statFrom, self.statTo = from, to
	self.statStart = self.clock
	self.statDur = math.max(dur, 0)
end

function Ui.update(self: Ui, dt: number, onTick: (() -> ())?)
	self.clock += dt
	local label = self.tagStat
	if not label then
		return
	end
	local u = if self.statDur > 0 then math.clamp((self.clock - self.statStart) / self.statDur, 0, 1) else 1
	local value = math.floor(self.statFrom + (self.statTo - self.statFrom) * u + 0.5)
	if value ~= self.statShown then
		self.statShown = value
		label.Text = string.format(self.theme.Intro.Stat, value)
		self:_paintStat(value)
		local pillScale = self.tagPillScale
		if pillScale then
			pillScale.Scale = 1.12
			Kit.tween(pillScale, 0.15, { Scale = 1 }, OUT)
		end
		if onTick then
			onTick()
		end
	end
end

function Ui.destroy(self: Ui)
	for _, c in self.connections do
		c:Disconnect()
	end
	pcall(function()
		if GuiService.SelectedObject == self.skip then
			GuiService.SelectedObject = nil
		end
	end)
	self.captionToken += 1
	self.gui:Destroy()
	self.world:Destroy()
end

return Ui
