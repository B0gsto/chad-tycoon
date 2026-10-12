--[[
	Kit: the design system for the code-built UI.

	Visual language: glass windows, toy controls. Windows are translucent
	blue-tinted panes with a thin light edge over the blurred world, and their
	rows and cards are lighter glass (Kit.window, Kit.glass, Kit.panel Glass;
	tokens in Theme.Glass). HUD panels, popups and buttons read as chunky
	moulded plastic: lighter at the top, a thin white highlight along the top
	inner edge, a darker blue lip along the bottom and a soft navy shadow.
	Wells are a deeper blue. Sunny yellow (orange lip, Ink text) is the one
	call-to-action colour; mint is money, sky blue the premium currency, orange
	the surge, coral close/danger. Text is light on blue; outlines only on text
	over the 3D world (Shadow = true). Icons are built from shapes (Kit.icon) or
	come from the optional Shared.Assets icon atlas.

	Motion: everything eases. Kit.appear / Kit.disappear (scale + fade),
	Kit.stagger (rows in), Kit.countTo (number rolls), Kit.pop (landing pop),
	Kit.breathe (idle CTA). Buttons squash on press and spring back.

	Tokens
	  Kit.TEXT    type scale (TextSize in design pixels; the ScreenGui UIScale
	              scales the whole 1280x720 design to the device)
	  Kit.RADIUS  corner radii
	  Kit.input   "touch" | "gamepad" | "keyboard", the input used last
	              (Kit.touch / Kit.gamepad follow it; Kit.onInput re-flows)
	              Kit.onInput(fn) -> disconnect; Kit.tenFoot on TV consoles
	  Kit.keyHint prompt text per mode: Kit.keyHint("confirm"|"back"|"jump")
	              ("TAP" / "A" / "SPACE"...); Kit.hint(touch, keyboard, gamepad)
	  Kit.focus   gamepad selection: Kit.focus(target) selects target's first
	              visible button (FocusFirst attribute wins), Kit.focus(nil)
	              clears, Kit.unfocus(container) releases, Kit.confine(holder)
	              traps the D-pad; Kit.selectable(button) + Kit.selectionRing()
	              give buttons built elsewhere the shared selection ring
	  Kit.ICONS   names accepted by Kit.icon (and Kit.button's Icon prop)

	Every builder keeps its public signature; see the headers below.
]]

local Lighting = game:GetService("Lighting")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local GuiService = game:GetService("GuiService")
local UserInputService = game:GetService("UserInputService")

local Theme = require(ReplicatedStorage:WaitForChild("Theme"))
local CharacterFactory = require(ReplicatedStorage.Shared.CharacterFactory)
local Animator = require(script.Parent.Parent.Animator)
local Sprites = require(script.Parent.Parent.Fx.Sprites)

local Kit = {}
Kit.Theme = Theme
Kit.C = Theme.Colors
Kit.F = Theme.Fonts

Kit.TEXT = {
	Hero = 40,
	H1 = 28,
	H2 = 22,
	H3 = 18,
	Body = 16,
	Small = 14,
	Tiny = 12,
}

Kit.RADIUS = {
	S = 10,
	M = 14,
	L = 18,
	XL = 22,
}

-- Input mode ----------------------------------------------------------------------------
--[[
	Kit.input is "touch", "gamepad" or "keyboard" (keyboard + mouse): the kind of
	input the player used last, starting from what the device offers (a console
	is gamepad, a phone touch, a laptop keyboard even with a touch screen until it
	is tapped). Kit.touch and Kit.gamepad follow it. Kit.onInput(fn) runs fn(mode)
	now and whenever the mode changes, so layouts and hints can re-flow when a
	player picks up a controller or plugs in a keyboard. Kit.tenFoot is true on a
	TV-distance (10-foot) console interface (Kit.console is the same flag).
]]
export type InputMode = "touch" | "gamepad" | "keyboard"
Kit.input = "keyboard" :: InputMode
Kit.touch = false
Kit.gamepad = false
Kit.tenFoot = false
pcall(function()
	Kit.tenFoot = GuiService:IsTenFootInterface() == true
end)
Kit.console = Kit.tenFoot
local inputListeners: { (InputMode) -> () } = {}

-- Maps a UserInputType to a mode; nil for types that say nothing (Focus, TextInput...).
local function classifyInput(inputType: Enum.UserInputType?): InputMode?
	if inputType == nil then
		return nil
	end
	if inputType == Enum.UserInputType.Touch then
		return "touch"
	end
	local name = inputType.Name
	if string.sub(name, 1, 7) == "Gamepad" then
		return "gamepad"
	end
	if name == "Keyboard" or string.sub(name, 1, 5) == "Mouse" then
		return "keyboard"
	end
	return nil
end

local function applyInput(mode: InputMode)
	Kit.input = mode
	Kit.touch = mode == "touch"
	Kit.gamepad = mode == "gamepad"
end

local function setInput(mode: InputMode)
	if mode == Kit.input then
		return
	end
	applyInput(mode)
	for _, fn in table.clone(inputListeners) do
		task.spawn(fn, mode)
	end
end

pcall(function()
	local mode: InputMode = "keyboard"
	local touch, keyboard, gamepad = UserInputService.TouchEnabled, UserInputService.KeyboardEnabled, UserInputService.GamepadEnabled
	if gamepad and not keyboard and not touch then
		mode = "gamepad"
	elseif touch and not keyboard then
		mode = "touch"
	end
	if Kit.tenFoot then
		mode = "gamepad"
	end
	applyInput(mode)
end)
-- A controller counts as "in use" on a button press or a clear stick / trigger move; a
-- resting stick's drift (reported as gamepad input) must not re-flow a keyboard player's HUD.
local STICK_DEADZONE = 0.35
local function gamepadIntent(input: InputObject): boolean
	local key = input.KeyCode
	if key == Enum.KeyCode.Thumbstick1 or key == Enum.KeyCode.Thumbstick2 then
		return input.Position.Magnitude >= STICK_DEADZONE
	end
	if key == Enum.KeyCode.ButtonL2 or key == Enum.KeyCode.ButtonR2 then
		return input.Position.Z >= STICK_DEADZONE
	end
	return input.UserInputState == Enum.UserInputState.Begin
end
pcall(function()
	UserInputService.LastInputTypeChanged:Connect(function(inputType: Enum.UserInputType)
		local mode = classifyInput(inputType)
		if mode and mode ~= "gamepad" then
			setInput(mode)
		end
	end)
	local function onGamepad(input: InputObject)
		if classifyInput(input.UserInputType) == "gamepad" and gamepadIntent(input) then
			setInput("gamepad")
		end
	end
	UserInputService.InputBegan:Connect(onGamepad)
	UserInputService.InputChanged:Connect(onGamepad)
end)

-- Runs fn(Kit.input) now and on every change; returns a disconnect function.
function Kit.onInput(fn: (InputMode) -> ()): () -> ()
	table.insert(inputListeners, fn)
	task.spawn(fn, Kit.input)
	return function()
		local i = table.find(inputListeners, fn)
		if i then
			table.remove(inputListeners, i)
		end
	end
end

local KEY_HINTS: { [string]: { [string]: string } } = {
	touch = { confirm = "TAP", back = "TAP", jump = "TAP" },
	gamepad = { confirm = "A", back = "B", jump = "A" },
	keyboard = { confirm = "SPACE", back = "ESC", jump = "SPACE" },
}

-- Prompt text for an action in the current mode: Kit.keyHint("confirm") -> "TAP" / "A" / "SPACE".
function Kit.keyHint(action: "confirm" | "back" | "jump"): string
	local hints = KEY_HINTS[Kit.input] or KEY_HINTS.keyboard
	return hints[action] or hints.confirm
end

-- Picks free wording for the current input: Kit.hint("TAP", "SPACE", "A").
function Kit.hint(touch: string, keyboard: string, gamepad: string): string
	if Kit.touch then
		return touch
	elseif Kit.gamepad then
		return gamepad
	end
	return keyboard
end

local WHITE = Color3.new(1, 1, 1)
local BLACK = Color3.new(0, 0, 0)
local C = Kit.C
local F = Kit.F
local G = Theme.Glass

-- Face colour of disabled buttons (a quiet blue-grey that still reads as plastic).
local DISABLED = Color3.fromRGB(150, 166, 212)

-- The Lune preview exporter stubs TweenInfo with a plain table and jumps every
-- tween to its end state; transient effects (pops, breathing) are skipped there
-- so captures show the resting layout.
local PREVIEW = typeof(TweenInfo.new(0)) ~= "TweenInfo"

-- Roblox's built-in Robux glyph (drawn by the Gotham/Builder fonts); plain "R$"
-- in the web preview. Every Robux price in the UI is written with it.
Kit.ROBUX = if PREVIEW then "R$" else utf8.char(0xE002)

-- Sounds are injected by Main so Kit stays free of client state.
local soundPlayer: ((string) -> ())? = nil
function Kit.setSoundPlayer(fn: (string) -> ())
	soundPlayer = fn
end
function Kit.sound(name: string)
	if soundPlayer then
		soundPlayer(name)
	end
end

function Kit.new(className: string, props: { [string]: any }?, children: { Instance }?): any
	local inst = Instance.new(className)
	local parent = nil
	local properties: { [string]: any } = props or {}
	for key, value in properties do
		if key == "Parent" then
			parent = value
		else
			(inst :: any)[key] = value
		end
	end
	local childList: { Instance } = children or {}
	for _, child in childList do
		child.Parent = inst
	end
	if parent then
		inst.Parent = parent
	end
	return inst
end

-- Gamepad selection -------------------------------------------------------------------
--[[
	Console players move a selection (GuiService.SelectedObject) between
	GuiButtons with the D-pad / left stick. Every Kit control is Selectable and
	wears Kit.selectionRing() (a sunny rounded outline with a soft glow) so the
	focus reads in the toy style; decorative hit areas and backdrops are not
	Selectable. Kit.selectable(button) does the same for buttons built elsewhere.

	Kit.focus(target) selects the first visible, Selectable button under target
	(a descendant with attribute FocusFirst = true wins; else lowest LayoutOrder,
	then topmost-leftmost) on gamepad / 10-foot only; Kit.focus(nil) clears the
	selection in every mode. Kit.unfocus(container) clears it when it sits inside
	container (or always for nil). Kit.confine(holder) makes holder a
	SelectionGroup the D-pad cannot leave (Kit.window does this).
]]
local selectionRing: Frame? = nil

function Kit.selectionRing(): Frame
	if selectionRing then
		return selectionRing
	end
	local frame = Kit.new("Frame", {
		Name = "SelectionRing",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 12, 1, 12),
		Position = UDim2.fromOffset(-6, -6),
		ZIndex = 50,
	})
	Kit.new("UICorner", { CornerRadius = UDim.new(0, Kit.RADIUS.M), Parent = frame })
	Kit.new("UIStroke", {
		Thickness = 3,
		Color = C.Primary,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
		Parent = frame,
	})
	-- Inner white hairline so the ring reads on yellow buttons too.
	local inner = Kit.new("Frame", {
		Name = "Inner",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, -6, 1, -6),
		Position = UDim2.fromOffset(3, 3),
		ZIndex = 50,
		Parent = frame,
	})
	Kit.new("UICorner", { CornerRadius = UDim.new(0, Kit.RADIUS.M - 3), Parent = inner })
	Kit.new("UIStroke", { Thickness = 1.5, Color = WHITE, Transparency = 0.15, Parent = inner })
	-- Soft outer glow: two wider, fading strokes.
	for i, spec in { { 4, 0.55 }, { 9, 0.8 } } do
		local glow = Kit.new("Frame", {
			Name = "Glow" .. i,
			BackgroundTransparency = 1,
			Size = UDim2.new(1, spec[1] * 2, 1, spec[1] * 2),
			Position = UDim2.fromOffset(-spec[1], -spec[1]),
			ZIndex = 49,
			Parent = frame,
		})
		Kit.new("UICorner", { CornerRadius = UDim.new(0, Kit.RADIUS.M + spec[1]), Parent = glow })
		Kit.new("UIStroke", { Thickness = spec[1], Color = C.Primary, Transparency = spec[2], Parent = glow })
	end
	selectionRing = frame
	return frame
end
Kit.SELECTION = Kit.selectionRing()

-- Makes a button navigable by gamepad with the shared ring (`on` = false opts out).
function Kit.selectable(button: GuiObject, on: boolean?)
	pcall(function()
		button.Selectable = on ~= false
		if on ~= false then
			button.SelectionImageObject = Kit.selectionRing()
		end
	end)
end

local function currentSelection(): GuiObject?
	local ok, selected = pcall(function()
		return GuiService.SelectedObject
	end)
	return if ok then selected else nil
end

local function setSelection(gui: GuiObject?)
	pcall(function()
		GuiService.SelectedObject = gui
	end)
end

function Kit.selectedIn(holder: Instance?): boolean
	local selected = currentSelection()
	return selected ~= nil and holder ~= nil and (selected == holder or selected:IsDescendantOf(holder))
end

-- Moves the selection to `gui` on gamepad only, so mouse and touch are never hijacked.
function Kit.select(gui: GuiObject?)
	if Kit.gamepad or Kit.tenFoot then
		setSelection(gui)
	end
end

local function navigable(inst: Instance): boolean
	if not inst:IsA("GuiButton") then
		return false
	end
	local ok, result = pcall(function()
		return inst.Selectable and inst.Visible and inst.AbsoluteSize.X > 0
	end)
	return ok and result == true
end

-- First visible, Selectable GuiButton under `root` (FocusFirst, then LayoutOrder,
-- then topmost-leftmost). Hidden branches are skipped.
function Kit.firstSelectable(root: Instance): GuiObject?
	local best: GuiObject? = nil
	local bestKey: { number }? = nil
	local function better(a: { number }, b: { number }?): boolean
		if b == nil then
			return true
		end
		for i = 1, #a do
			if a[i] ~= b[i] then
				return a[i] < b[i]
			end
		end
		return false
	end
	local function visit(inst: Instance)
		if inst:IsA("GuiObject") and not inst.Visible then
			return
		end
		if navigable(inst) then
			local gui = inst :: GuiObject
			local pos = gui.AbsolutePosition
			local key = {
				if gui:GetAttribute("FocusFirst") == true then 0 else 1,
				gui.LayoutOrder,
				math.floor(pos.Y),
				math.floor(pos.X),
			}
			if better(key, bestKey) then
				best, bestKey = gui, key
			end
		end
		for _, child in inst:GetChildren() do
			visit(child)
		end
	end
	for _, child in root:GetChildren() do
		visit(child)
	end
	return best
end

-- Keeps the D-pad inside `holder` (a SelectionGroup that stops at its edges).
function Kit.confine(holder: GuiObject, on: boolean?)
	pcall(function()
		holder.SelectionGroup = on ~= false
		local stop = if on ~= false then Enum.SelectionBehavior.Stop else Enum.SelectionBehavior.Escape
		holder.SelectionBehaviorUp = stop
		holder.SelectionBehaviorDown = stop
		holder.SelectionBehaviorLeft = stop
		holder.SelectionBehaviorRight = stop
	end)
end

-- Selects the first navigable button in `target` (or target itself) on gamepad;
-- nil clears the selection in every mode. `preferred` overrides the search.
function Kit.focus(target: GuiObject?, preferred: GuiObject?)
	if target == nil then
		setSelection(nil)
		return
	end
	if not (Kit.gamepad or Kit.tenFoot) then
		return
	end
	local pick = preferred
	if pick == nil then
		local ok, found = pcall(function()
			if navigable(target) then
				return target
			end
			return Kit.firstSelectable(target)
		end)
		pick = if ok then found else nil
	end
	if pick then
		setSelection(pick)
	end
end

-- Drops the selection if it is inside `container` (nil: always).
function Kit.unfocus(container: GuiObject?)
	if container == nil or Kit.selectedIn(container) then
		setSelection(nil)
	end
end
Kit.blur = Kit.unfocus

-- Colour helpers ----------------------------------------------------------------------

function Kit.lighten(color: Color3, amount: number): Color3
	return color:Lerp(WHITE, amount)
end

function Kit.darken(color: Color3, amount: number): Color3
	return color:Lerp(BLACK, amount)
end

function Kit.hex(color: Color3): string
	return string.format("#%02X%02X%02X", math.floor(color.R * 255 + 0.5), math.floor(color.G * 255 + 0.5), math.floor(color.B * 255 + 0.5))
end

-- Perceived brightness (0..1): picks ink or white text on a coloured face.
local function luminance(color: Color3): number
	return 0.299 * color.R + 0.587 * color.G + 0.114 * color.B
end
function Kit.inkOn(color: Color3): Color3
	return if luminance(color) > 0.62 then C.GoldInk else C.Text
end

-- The darker "moulded plastic" lip under a coloured face: the named deep tone
-- for the accent colours (orange under sunny yellow), else the colour pushed
-- toward navy (never toward black).
local LIPS: { [string]: Color3 } = {
	[Kit.hex(C.Gold)] = C.GoldDeep,
	[Kit.hex(C.Cash)] = C.CashDeep,
	[Kit.hex(C.Good)] = C.CashDeep,
	[Kit.hex(C.Rizz)] = C.RizzDeep,
	[Kit.hex(C.Violet)] = C.VioletDeep,
	[Kit.hex(C.Surface)] = C.Edge,
	[Kit.hex(C.SurfaceHi)] = C.Edge,
}
function Kit.lip(color: Color3): Color3
	return LIPS[Kit.hex(color)] or color:Lerp(C.Ink, 0.42)
end

function Kit.tween(obj: Instance, time: number, props: { [string]: any }, style: Enum.EasingStyle?, direction: Enum.EasingDirection?): Tween
	local tween =
		TweenService:Create(obj, TweenInfo.new(time, style or Enum.EasingStyle.Quad, direction or Enum.EasingDirection.Out), props)
	tween:Play()
	return tween
end

-- Tween with a start delay (stagger), same defaults as Kit.tween.
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

-- Modifiers ---------------------------------------------------------------------------

function Kit.corner(parent: Instance, radius: number?): UICorner
	return Kit.new("UICorner", { CornerRadius = UDim.new(0, radius or Kit.RADIUS.M), Parent = parent })
end

function Kit.round(parent: Instance): UICorner
	return Kit.new("UICorner", { CornerRadius = UDim.new(1, 0), Parent = parent })
end

--[[
	Edge stroke. On frames: a 1.5 px outline in the darker blue Edge colour (pass
	a colour to tint it). On text objects: a border stroke around the box.
]]
function Kit.stroke(parent: Instance, thickness: number?, color: Color3?): UIStroke
	local isText = parent:IsA("TextLabel") or parent:IsA("TextButton")
	return Kit.new("UIStroke", {
		Thickness = thickness or 1.5,
		Color = color or C.Edge,
		Transparency = 0.1,
		ApplyStrokeMode = if isText then Enum.ApplyStrokeMode.Border else Enum.ApplyStrokeMode.Contextual,
		Parent = parent,
	})
end

--[[
	Moulded-plastic chrome shared by panels, buttons and tab pills. Chrome
	children carry the attribute KitChrome = true so screen code can skip them
	when clearing a container.
]]
local function chrome(inst: Instance)
	inst:SetAttribute("KitChrome", true)
end

-- Thin white highlight line along the top inner edge of `parent`.
local function highlight(parent: GuiObject, radius: number, transparency: number?): Frame
	local inset = math.max(math.floor(radius * 0.75), 6)
	local line = Kit.new("Frame", {
		Name = "Highlight",
		BackgroundColor3 = WHITE,
		BackgroundTransparency = transparency or 0.45,
		BorderSizePixel = 0,
		Size = UDim2.new(1, -inset * 2, 0, 2),
		Position = UDim2.fromOffset(inset, 2),
		ZIndex = parent.ZIndex,
		Parent = parent,
	})
	Kit.round(line)
	chrome(line)
	return line
end

--[[
	Darker lip that peeks out below the bottom edge of `parent` (children draw
	over their parent, so the lip is a strip whose upper part is transparent and
	only the `depth` px under the edge show). Slightly inset so it reads as the
	rounded base the panel sits on.
]]
local function lip(parent: GuiObject, radius: number, depth: number, color: Color3): Frame
	local height = radius + depth
	local inset = math.floor(radius * 0.3)
	local strip = Kit.new("Frame", {
		Name = "Lip",
		BackgroundColor3 = color,
		BorderSizePixel = 0,
		Size = UDim2.new(1, -inset * 2, 0, height),
		Position = UDim2.new(0, inset, 1, depth - height),
		ZIndex = parent.ZIndex,
		Parent = parent,
	})
	Kit.corner(strip, radius)
	local cut = math.clamp(radius / height, 0, 0.98)
	Kit.new("UIGradient", {
		Rotation = 90,
		Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 1),
			NumberSequenceKeypoint.new(cut, 1),
			NumberSequenceKeypoint.new(math.min(cut + 0.01, 0.99), 0),
			NumberSequenceKeypoint.new(1, 0),
		}),
		Parent = strip,
	})
	chrome(strip)
	return strip
end

-- Soft navy halo around glyphs (for text over the 3D world).
function Kit.textStroke(parent: Instance, thickness: number?, transparency: number?)
	return Kit.new("UIStroke", {
		Thickness = thickness or 1.5,
		Color = C.Ink,
		Transparency = transparency or 0.4,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual,
		LineJoinMode = Enum.LineJoinMode.Round,
		Parent = parent,
	})
end

function Kit.gradient(parent: Instance, top: Color3, bottom: Color3, rotation: number?): UIGradient
	return Kit.new("UIGradient", {
		Color = ColorSequence.new(top, bottom),
		Rotation = rotation or 90,
		Parent = parent,
	})
end

function Kit.padding(parent: Instance, px: number, horizontal: number?)
	return Kit.new("UIPadding", {
		PaddingTop = UDim.new(0, px),
		PaddingBottom = UDim.new(0, px),
		PaddingLeft = UDim.new(0, horizontal or px),
		PaddingRight = UDim.new(0, horizontal or px),
		Parent = parent,
	})
end

function Kit.list(parent: Instance, gap: number?, horizontal: boolean?, align: Enum.HorizontalAlignment?): UIListLayout
	return Kit.new("UIListLayout", {
		Padding = UDim.new(0, gap or 8),
		FillDirection = if horizontal then Enum.FillDirection.Horizontal else Enum.FillDirection.Vertical,
		HorizontalAlignment = align or Enum.HorizontalAlignment.Left,
		VerticalAlignment = if horizontal then Enum.VerticalAlignment.Center else Enum.VerticalAlignment.Top,
		SortOrder = Enum.SortOrder.LayoutOrder,
		Parent = parent,
	})
end

--[[
	Soft navy drop shadow under `parent`: a fading strip that peeks out below
	the bottom edge (and below the lip), so it never covers the body. `offset`
	is how far below the edge it starts (the lip depth). Call after the
	UICorner is set.
]]
function Kit.shadow(parent: GuiObject, radius: number?, strength: number?, offset: number?): Frame
	local r = radius or Kit.RADIUS.L
	local s = strength or 1
	local below = offset or 0
	local height = r + below + 6 + 4 * s
	local shadow = Kit.new("Frame", {
		Name = "Shadow",
		BackgroundColor3 = C.Ink,
		BackgroundTransparency = 0.45,
		BorderSizePixel = 0,
		Size = UDim2.new(1, -math.floor(r * 0.5), 0, height),
		Position = UDim2.new(0, math.floor(r * 0.25), 1, below + 6 + 4 * s - height),
		ZIndex = parent.ZIndex,
		Parent = parent,
	})
	Kit.corner(shadow, r)
	-- Hidden behind the body down to the lip, then a soft fade.
	local cut = math.clamp((r + below - 2) / height, 0, 0.9)
	Kit.new("UIGradient", {
		Rotation = 90,
		Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 1),
			NumberSequenceKeypoint.new(cut, 1),
			NumberSequenceKeypoint.new(math.min(cut + 0.02, 0.95), 0.25),
			NumberSequenceKeypoint.new(1, 1),
		}),
		Parent = shadow,
	})
	chrome(shadow)
	return shadow
end

-- Text ----------------------------------------------------------------------------------

-- The dark outline of light text on glass.
local function inkStroke(label: Instance, thickness: number): UIStroke
	local stroke = Kit.textStroke(label, thickness, Theme.Glass.TextStrokeFade)
	stroke.Color = Theme.Glass.TextInk
	return stroke
end

--[[
	Text. Pass TextSize for a fixed size from the type scale (preferred), or
	leave it out for TextScaled (optionally capped with MaxTextSize).
	  Font            any Theme.Fonts role (Display, UI, Bold, Body, Number)
	  Shadow = true   navy outline (only for text directly over the 3D world)
	  StrokeThickness explicit outline thickness (0 = none)
	The outline follows the size of the text (Kit.outlineFor): titles, prices and
	big numbers get the thick one, mid sizes a thin one, and small text (under
	Theme.Glass.TextStrokeFrom) none, or a 1 px hairline when the caller asked for
	an outline. Small text therefore belongs on a card or a chip dark enough to
	read; only text over the bare world (Shadow, Kit.hudText) is outlined at any size.
]]

-- Outline thickness for light text `size` px tall on glass (0 = none).
function Kit.outlineFor(size: number): number
	if size < G.TextStrokeFrom then
		return 0
	end
	return math.clamp(size / G.TextStrokePer, G.TextStrokeThin, G.TextStrokeMax)
end

--[[
	Sizes in screen pixels. A TextSize is in design px: the ScreenGui's UIScale shrinks the
	1280x720 design on a small screen (x0.57 to 0.66 on a phone) and Kit.fit scales a holder
	once more, so a 14 px caption can land at 8 px on the glass. Text that has to stay
	readable names its size on the glass instead:
	  Kit.pixelScale(gui)       screen px per design px at `gui` (the ScreenGui's UIScale
	                            times the "Fit" / "Compact" scales above it)
	  Kit.px(px, design?, gui?) the design size that shows at least `px` on screen there
	                            (never under `design`)
	  Kit.captionPx()           the smallest caption: G.TextMin, G.TextMinPhone on touch
	  Kit.holdText(label, px, design?)  sizes a fixed-size label that way and keeps it so when
	                            the screen is rescaled (Kit.reflowText, called by Main)
	Kit.text takes the same as the prop MinPx (a number, or true for a caption).
]]
local LAYOUT_SCALES = { "Fit", "Compact" }
local screenScale: UIScale? = nil
function Kit.pixelScale(from: Instance?): number
	local scale = 1
	local current = from
	while current do
		if current.ClassName == "ScreenGui" then
			-- The first ScreenGui seen (Main registers the game's own) is the one remembered.
			local own = current:FindFirstChildOfClass("UIScale")
			screenScale = screenScale or own
			return math.max(scale * (if own then own.Scale else 1), 0.01)
		end
		for _, name in LAYOUT_SCALES do
			local layout = current:FindFirstChild(name)
			if layout and layout:IsA("UIScale") then
				scale *= layout.Scale
			end
		end
		current = current.Parent
	end
	-- A label built before its holder is on screen still counts the screen's own scale.
	if screenScale then
		scale *= screenScale.Scale
	end
	return math.max(scale, 0.01)
end

function Kit.px(screenPx: number, design: number?, from: Instance?): number
	return math.max(design or 0, math.ceil(screenPx / Kit.pixelScale(from) - 0.5))
end

function Kit.captionPx(): number
	return if Kit.touch then G.TextMinPhone else G.TextMin
end

type HeldText = { px: number, design: number }
local heldText: { [TextLabel]: HeldText } = setmetatable({}, { __mode = "k" }) :: any
function Kit.holdText(label: TextLabel, screenPx: number, design: number?)
	local held: HeldText = { px = screenPx, design = design or label.TextSize }
	heldText[label] = held
	label.TextSize = Kit.px(held.px, held.design, label)
end

-- The screen was rescaled: every held label takes its size again.
function Kit.reflowText()
	for label, held in heldText do
		if label.Parent then
			label.TextSize = Kit.px(held.px, held.design, label)
		end
	end
end

function Kit.text(parent: Instance, props: { [string]: any }): TextLabel
	local fixed = props.TextSize ~= nil and props.TextScaled ~= true
	local label = Kit.new("TextLabel", {
		BackgroundTransparency = 1,
		Font = F.Body,
		TextColor3 = C.Text,
		TextScaled = not fixed,
		TextWrapped = true,
		Size = UDim2.fromScale(1, 1),
		Parent = parent,
	})
	local maxSize = props.MaxTextSize
	local strokeThickness = props.StrokeThickness
	local shadow = props.Shadow
	local minPx: number? = if props.MinPx == true then Kit.captionPx() else props.MinPx
	for key, value in props do
		if key ~= "MaxTextSize" and key ~= "StrokeThickness" and key ~= "Shadow" and key ~= "MinPx" then
			(label :: any)[key] = value
		end
	end
	-- Nothing under the smallest readable size (Theme.Glass.TextMin, in design px; MinPx
	-- holds a size on the glass).
	local floor = if Kit.touch then Theme.Glass.TextMin + 1 else Theme.Glass.TextMin
	if fixed then
		label.TextSize = math.max(label.TextSize, floor)
		if minPx then
			Kit.holdText(label, minPx)
		end
	end
	if maxSize then
		-- Scaled text may shrink to fit its box, but not under its size on the glass.
		maxSize = if minPx then Kit.px(minPx, maxSize, label) else maxSize
		Kit.new("UITextSizeConstraint", {
			MaxTextSize = math.max(maxSize, floor),
			MinTextSize = if minPx then math.min(Kit.px(minPx, nil, label), math.max(maxSize, floor)) else Theme.Glass.TextMinPhone,
			Parent = label,
		})
	end
	-- The tallest the glyphs can be: the fixed size, the cap of scaled text, or the
	-- height of a fixed-height box. Unknown (a scaled label in a scaled box) counts as a title.
	local size: number = if fixed
		then label.TextSize
		elseif maxSize then math.max(maxSize, floor)
		elseif label.Size.Y.Scale == 0 and label.Size.Y.Offset > 0 then label.Size.Y.Offset
		else G.TextStrokeFrom * 1.5
	local outline = Kit.outlineFor(size)
	local light = luminance(label.TextColor3) >= 0.45
	if strokeThickness == 0 then
		return label
	end
	if shadow then
		-- Text over the 3D world: a readable navy outline at any size.
		if strokeThickness then
			Kit.textStroke(label, math.clamp(strokeThickness, 1.3, 3), 0.3)
		else
			Kit.textStroke(label, if shadow == true then 1.8 else 1.3, 0.3)
		end
	elseif strokeThickness then
		-- An outline was asked for: never thicker than the size carries, a hairline on small text.
		local thickness = math.min(strokeThickness, math.max(outline * 1.25, 1))
		if light then
			inkStroke(label, math.clamp(thickness, 1, G.TextStrokeMax))
		else
			Kit.textStroke(label, math.clamp(thickness * 0.6, 1, 2.5), 0.35)
		end
	elseif light and label.Font ~= F.Body then
		-- Light titles, names, prices and numbers on glass: a dark outline from TextStrokeFrom up.
		if outline > 0 then
			inkStroke(label, outline)
		end
	elseif label.Font == F.Display then
		-- Dark display titles on solid faces: a faint embossed edge, not an outline.
		Kit.textStroke(label, 1.4, 0.65)
	end
	return label
end

function Kit.title(parent: Instance, props: { [string]: any }): TextLabel
	props.Font = props.Font or F.Display
	return Kit.text(parent, props)
end

-- Number label (tabular, never scaled).
function Kit.number(parent: Instance, props: { [string]: any }): TextLabel
	props.Font = props.Font or F.Number
	props.TextWrapped = if props.TextWrapped == nil then false else props.TextWrapped
	return Kit.text(parent, props)
end

-- Icons ----------------------------------------------------------------------------------

-- A filled shape: frame + corner + gradient (+ optional stroke). Sizes are scales of the icon box.
local function shape(parent: Instance, props: { [string]: any }): Frame
	local color: Color3 = props.Color or C.Text
	local frame = Kit.new("Frame", {
		Name = props.Name or "Shape",
		BackgroundColor3 = color,
		BackgroundTransparency = props.Transparency or 0,
		Size = props.Size or UDim2.fromScale(0.5, 0.5),
		Position = props.Position or UDim2.fromScale(0.5, 0.5),
		AnchorPoint = props.AnchorPoint or Vector2.new(0.5, 0.5),
		Rotation = props.Rotation or 0,
		ZIndex = props.ZIndex or 1,
		ClipsDescendants = props.Clip == true,
		Parent = parent,
	})
	if props.Round then
		Kit.round(frame)
	else
		Kit.new("UICorner", { CornerRadius = UDim.new(props.RadiusScale or 0, props.Radius or 0), Parent = frame })
	end
	if props.Light ~= false and (props.Transparency or 0) == 0 then
		Kit.gradient(frame, Kit.lighten(color, props.Light or 0.28), Kit.darken(color, 0.08))
	end
	if props.Stroke then
		Kit.new("UIStroke", {
			Thickness = props.Stroke,
			Color = props.StrokeColor or color,
			ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
			Parent = frame,
		})
	end
	return frame
end

local ICONS: { [string]: (Frame, Color3) -> () } = {}
Kit.ICONS = ICONS

ICONS.Coin = function(root, color)
	shape(root, { Name = "Disc", Color = color, Size = UDim2.fromScale(0.92, 0.92), Round = true, Light = 0.35 })
	shape(root, {
		Name = "Ring",
		Color = Kit.darken(color, 0.35),
		Transparency = 1,
		Size = UDim2.fromScale(0.68, 0.68),
		Round = true,
		Stroke = 2,
		StrokeColor = Kit.darken(color, 0.3),
		ZIndex = 2,
	})
	Kit.number(root, {
		Name = "Glyph",
		Text = "$",
		TextScaled = true,
		TextColor3 = Kit.darken(color, 0.62),
		Size = UDim2.fromScale(0.5, 0.56),
		Position = UDim2.fromScale(0.5, 0.5),
		AnchorPoint = Vector2.new(0.5, 0.5),
		ZIndex = 3,
		StrokeThickness = 0,
	})
end

ICONS.Gem = function(root, color)
	shape(root, { Name = "Stone", Color = color, Size = UDim2.fromScale(0.6, 0.6), Rotation = 45, Radius = 3, Light = 0.3 })
	shape(root, {
		Name = "Facet",
		Color = WHITE,
		Transparency = 0.55,
		Size = UDim2.fromScale(0.26, 0.26),
		Position = UDim2.fromScale(0.4, 0.38),
		Rotation = 45,
		Radius = 2,
		ZIndex = 2,
	})
end

ICONS.Shop = function(root, color)
	-- Shopping cart: basket, handle, two wheels.
	shape(root, {
		Name = "Handle",
		Color = color,
		Size = UDim2.fromScale(0.3, 0.11),
		Position = UDim2.fromScale(0.17, 0.2),
		Radius = 2,
		Light = false,
	})
	shape(root, {
		Name = "Post",
		Color = color,
		Size = UDim2.fromScale(0.11, 0.5),
		Position = UDim2.fromScale(0.27, 0.42),
		Radius = 2,
		Light = false,
	})
	local basket = shape(root, {
		Name = "Basket",
		Color = color,
		Size = UDim2.fromScale(0.66, 0.4),
		Position = UDim2.fromScale(0.58, 0.46),
		Radius = 3,
		ZIndex = 2,
	})
	for i = 1, 2 do
		shape(basket, {
			Name = "Slot",
			Color = Kit.darken(color, 0.55),
			Size = UDim2.fromScale(0.1, 0.62),
			Position = UDim2.fromScale(0.34 * i, 0.5),
			Radius = 1,
			Light = false,
			ZIndex = 3,
		})
	end
	for _, x in { 0.42, 0.76 } do
		shape(root, {
			Name = "Wheel",
			Color = color,
			Size = UDim2.fromScale(0.2, 0.2),
			Position = UDim2.fromScale(x, 0.84),
			Round = true,
			Light = false,
			ZIndex = 2,
		})
	end
end

ICONS.Index = function(root, color)
	shape(root, {
		Name = "Back",
		Color = Kit.darken(color, 0.35),
		Size = UDim2.fromScale(0.58, 0.74),
		Position = UDim2.fromScale(0.58, 0.54),
		Radius = 4,
	})
	local front = shape(root, {
		Name = "Front",
		Color = color,
		Size = UDim2.fromScale(0.58, 0.74),
		Position = UDim2.fromScale(0.45, 0.47),
		Radius = 4,
		ZIndex = 2,
	})
	shape(front, {
		Name = "Spine",
		Color = Kit.darken(color, 0.4),
		Size = UDim2.fromScale(0.12, 1),
		Position = UDim2.fromScale(0.06, 0.5),
		Light = false,
		ZIndex = 3,
	})
	for i = 1, 2 do
		shape(front, {
			Name = "Line",
			Color = WHITE,
			Transparency = 0.5,
			Size = UDim2.fromScale(0.5, 0.08),
			Position = UDim2.fromScale(0.58, 0.3 + (i - 1) * 0.22),
			Radius = 2,
			ZIndex = 3,
		})
	end
end

ICONS.Ranking = function(root, color)
	for _, x in { 0.17, 0.83 } do
		shape(root, {
			Name = "Handle",
			Color = color,
			Transparency = 1,
			Size = UDim2.fromScale(0.3, 0.3),
			Position = UDim2.fromScale(x, 0.4),
			Round = true,
			Stroke = 3,
		})
	end
	shape(root, {
		Name = "Cup",
		Color = color,
		Size = UDim2.fromScale(0.54, 0.46),
		Position = UDim2.fromScale(0.5, 0.42),
		RadiusScale = 0.35,
		ZIndex = 2,
	})
	shape(root, {
		Name = "Stem",
		Color = Kit.darken(color, 0.15),
		Size = UDim2.fromScale(0.16, 0.18),
		Position = UDim2.fromScale(0.5, 0.72),
		Light = false,
	})
	shape(root, { Name = "Base", Color = color, Size = UDim2.fromScale(0.5, 0.12), Position = UDim2.fromScale(0.5, 0.86), Radius = 3 })
end

ICONS.Home = function(root, color)
	shape(root, {
		Name = "Walls",
		Color = color,
		Size = UDim2.fromScale(0.58, 0.44),
		Position = UDim2.fromScale(0.5, 0.92),
		AnchorPoint = Vector2.new(0.5, 1),
		Radius = 3,
	})
	local roofClip = Kit.new("Frame", {
		Name = "RoofClip",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 0.5),
		ClipsDescendants = true,
		ZIndex = 2,
		Parent = root,
	})
	shape(roofClip, {
		Name = "Roof",
		Color = Kit.lighten(color, 0.15),
		Size = UDim2.fromScale(0.56, 1.1),
		Position = UDim2.fromScale(0.5, 1),
		Rotation = 45,
		Radius = 3,
	})
	shape(root, {
		Name = "Door",
		Color = C.Gold,
		Size = UDim2.fromScale(0.18, 0.26),
		Position = UDim2.fromScale(0.5, 0.92),
		AnchorPoint = Vector2.new(0.5, 1),
		Radius = 2,
		ZIndex = 3,
	})
end

ICONS.Free = function(root, color)
	shape(root, {
		Name = "Box",
		Color = color,
		Size = UDim2.fromScale(0.66, 0.46),
		Position = UDim2.fromScale(0.5, 0.94),
		AnchorPoint = Vector2.new(0.5, 1),
		Radius = 4,
	})
	shape(root, {
		Name = "Lid",
		Color = Kit.lighten(color, 0.15),
		Size = UDim2.fromScale(0.78, 0.2),
		Position = UDim2.fromScale(0.5, 0.5),
		AnchorPoint = Vector2.new(0.5, 1),
		Radius = 4,
		ZIndex = 2,
	})
	shape(root, {
		Name = "RibbonV",
		Color = C.Gold,
		Size = UDim2.fromScale(0.14, 0.64),
		Position = UDim2.fromScale(0.5, 0.94),
		AnchorPoint = Vector2.new(0.5, 1),
		Light = false,
		ZIndex = 3,
	})
	shape(root, {
		Name = "RibbonH",
		Color = C.Gold,
		Size = UDim2.fromScale(0.78, 0.1),
		Position = UDim2.fromScale(0.5, 0.4),
		Light = false,
		ZIndex = 3,
	})
	for _, x in { 0.4, 0.6 } do
		shape(root, {
			Name = "Bow",
			Color = C.Gold,
			Transparency = 1,
			Size = UDim2.fromScale(0.2, 0.2),
			Position = UDim2.fromScale(x, 0.2),
			Round = true,
			Stroke = 2.5,
			ZIndex = 3,
		})
	end
end

ICONS.Invite = function(root, color)
	local back = Kit.darken(color, 0.3)
	shape(root, { Name = "HeadB", Color = back, Size = UDim2.fromScale(0.3, 0.3), Position = UDim2.fromScale(0.66, 0.3), Round = true })
	shape(root, {
		Name = "BodyB",
		Color = back,
		Size = UDim2.fromScale(0.46, 0.36),
		Position = UDim2.fromScale(0.68, 0.9),
		AnchorPoint = Vector2.new(0.5, 1),
		RadiusScale = 0.45,
	})
	shape(root, {
		Name = "HeadA",
		Color = color,
		Size = UDim2.fromScale(0.34, 0.34),
		Position = UDim2.fromScale(0.38, 0.34),
		Round = true,
		ZIndex = 2,
	})
	shape(root, {
		Name = "BodyA",
		Color = color,
		Size = UDim2.fromScale(0.54, 0.4),
		Position = UDim2.fromScale(0.38, 0.94),
		AnchorPoint = Vector2.new(0.5, 1),
		RadiusScale = 0.45,
		ZIndex = 2,
	})
end

ICONS.Settings = function(root, color)
	for i = 0, 3 do
		shape(root, { Name = "Tooth", Color = color, Size = UDim2.fromScale(0.24, 0.98), Rotation = i * 45, Radius = 2, Light = false })
	end
	shape(root, { Name = "Ring", Color = color, Size = UDim2.fromScale(0.7, 0.7), Round = true, ZIndex = 2, Light = 0.2 })
	shape(
		root,
		{ Name = "Hub", Color = Kit.darken(color, 0.55), Size = UDim2.fromScale(0.3, 0.3), Round = true, ZIndex = 3, Light = false }
	)
end

ICONS.Surge = function(root, color)
	-- Lightning bolt: two thick slanted bars joined by a short cross bar.
	shape(root, {
		Name = "Top",
		Color = color,
		Size = UDim2.fromScale(0.34, 0.58),
		Position = UDim2.fromScale(0.58, 0.3),
		Rotation = 24,
		Radius = 3,
		Light = false,
	})
	shape(root, {
		Name = "Bottom",
		Color = color,
		Size = UDim2.fromScale(0.34, 0.58),
		Position = UDim2.fromScale(0.42, 0.7),
		Rotation = 24,
		Radius = 3,
		Light = false,
	})
	shape(root, {
		Name = "Mid",
		Color = color,
		Size = UDim2.fromScale(0.62, 0.24),
		Position = UDim2.fromScale(0.5, 0.5),
		Rotation = -20,
		Radius = 3,
		Light = false,
		ZIndex = 2,
	})
end

ICONS.Orb = function(root, color)
	shape(root, { Name = "Glow", Color = color, Transparency = 0.75, Size = UDim2.fromScale(1, 1), Round = true })
	shape(root, { Name = "Core", Color = color, Size = UDim2.fromScale(0.64, 0.64), Round = true, Light = 0.4, ZIndex = 2 })
	shape(root, {
		Name = "Spark",
		Color = WHITE,
		Transparency = 0.25,
		Size = UDim2.fromScale(0.2, 0.2),
		Position = UDim2.fromScale(0.4, 0.38),
		Round = true,
		ZIndex = 3,
	})
end

ICONS.Chad = function(root, color)
	shape(root, { Name = "Disc", Color = color, Size = UDim2.fromScale(0.96, 0.96), Round = true, Light = 0.2 })
	shape(root, {
		Name = "Head",
		Color = Color3.fromRGB(234, 184, 146),
		Size = UDim2.fromScale(0.34, 0.34),
		Position = UDim2.fromScale(0.5, 0.36),
		Round = true,
		ZIndex = 2,
	})
	local clip = Kit.new("Frame", {
		Name = "Clip",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		ClipsDescendants = true,
		ZIndex = 2,
		Parent = root,
	})
	Kit.round(clip)
	shape(clip, {
		Name = "Torso",
		Color = Color3.fromRGB(245, 245, 248),
		Size = UDim2.fromScale(0.64, 0.5),
		Position = UDim2.fromScale(0.5, 0.62),
		AnchorPoint = Vector2.new(0.5, 0),
		RadiusScale = 0.5,
		ZIndex = 2,
	})
end

ICONS.Plus = function(root, color)
	shape(root, { Name = "V", Color = color, Size = UDim2.fromScale(0.22, 0.74), Radius = 2, Light = false })
	shape(root, { Name = "H", Color = color, Size = UDim2.fromScale(0.74, 0.22), Radius = 2, Light = false })
end

ICONS.Close = function(root, color)
	shape(root, { Name = "A", Color = color, Size = UDim2.fromScale(0.2, 0.86), Rotation = 45, Radius = 2, Light = false })
	shape(root, { Name = "B", Color = color, Size = UDim2.fromScale(0.2, 0.86), Rotation = -45, Radius = 2, Light = false })
end

ICONS.Check = function(root, color)
	shape(root, {
		Name = "Short",
		Color = color,
		Size = UDim2.fromScale(0.2, 0.42),
		Position = UDim2.fromScale(0.33, 0.62),
		Rotation = -45,
		Radius = 2,
		Light = false,
	})
	shape(root, {
		Name = "Long",
		Color = color,
		Size = UDim2.fromScale(0.2, 0.78),
		Position = UDim2.fromScale(0.58, 0.48),
		Rotation = 40,
		Radius = 2,
		Light = false,
	})
end

ICONS.Star = function(root, color)
	Kit.text(root, {
		Name = "Glyph",
		Text = "★",
		Font = F.UI,
		TextScaled = true,
		TextColor3 = color,
		Size = UDim2.fromScale(1, 1),
		StrokeThickness = 0,
	})
end

ICONS.Music = function(root, color)
	shape(root, {
		Name = "Head",
		Color = color,
		Size = UDim2.fromScale(0.34, 0.28),
		Position = UDim2.fromScale(0.36, 0.76),
		Round = true,
		Light = false,
	})
	shape(root, {
		Name = "Stem",
		Color = color,
		Size = UDim2.fromScale(0.12, 0.62),
		Position = UDim2.fromScale(0.5, 0.44),
		Radius = 2,
		Light = false,
	})
	shape(root, {
		Name = "Flag",
		Color = color,
		Size = UDim2.fromScale(0.34, 0.14),
		Position = UDim2.fromScale(0.64, 0.2),
		Rotation = 24,
		Radius = 2,
		Light = false,
	})
end

ICONS.Sound = function(root, color)
	shape(root, {
		Name = "Box",
		Color = color,
		Size = UDim2.fromScale(0.22, 0.34),
		Position = UDim2.fromScale(0.24, 0.5),
		Radius = 2,
		Light = false,
	})
	shape(root, {
		Name = "Cone",
		Color = color,
		Size = UDim2.fromScale(0.3, 0.3),
		Position = UDim2.fromScale(0.4, 0.5),
		Rotation = 45,
		Radius = 2,
		Light = false,
	})
	-- Sound waves: ring strokes clipped to the right half.
	local clip = Kit.new("Frame", {
		Name = "Waves",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(0.5, 1),
		Position = UDim2.fromScale(0.52, 0),
		ClipsDescendants = true,
		Parent = root,
	})
	for i = 1, 2 do
		shape(clip, {
			Name = "Wave",
			Color = color,
			Transparency = 1,
			Size = UDim2.fromScale(0.6 + i * 0.5, 0.3 + i * 0.25),
			Position = UDim2.fromScale(0, 0.5),
			Round = true,
			Stroke = 2,
		})
	end
end

ICONS.Hash = function(root, color)
	Kit.text(root, {
		Name = "Glyph",
		Text = "#",
		Font = F.UI,
		TextScaled = true,
		TextColor3 = color,
		Size = UDim2.fromScale(1, 1),
		StrokeThickness = 0,
	})
end

ICONS.Merge = function(root, color)
	shape(root, {
		Name = "A",
		Color = Kit.darken(color, 0.3),
		Size = UDim2.fromScale(0.34, 0.34),
		Position = UDim2.fromScale(0.24, 0.3),
		Round = true,
	})
	shape(root, {
		Name = "B",
		Color = Kit.darken(color, 0.3),
		Size = UDim2.fromScale(0.34, 0.34),
		Position = UDim2.fromScale(0.24, 0.7),
		Round = true,
	})
	shape(root, {
		Name = "Arrow",
		Color = color,
		Size = UDim2.fromScale(0.3, 0.12),
		Position = UDim2.fromScale(0.5, 0.5),
		Radius = 2,
		Light = false,
	})
	shape(root, {
		Name = "Result",
		Color = color,
		Size = UDim2.fromScale(0.44, 0.44),
		Position = UDim2.fromScale(0.76, 0.5),
		Round = true,
		ZIndex = 2,
	})
end

ICONS.Lock = function(root, color)
	shape(root, {
		Name = "Shackle",
		Color = color,
		Transparency = 1,
		Size = UDim2.fromScale(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.36),
		Round = true,
		Stroke = 3,
	})
	shape(root, {
		Name = "Body",
		Color = color,
		Size = UDim2.fromScale(0.66, 0.48),
		Position = UDim2.fromScale(0.5, 0.94),
		AnchorPoint = Vector2.new(0.5, 1),
		Radius = 4,
		ZIndex = 2,
	})
end

-- Emoji keys from Theme.Icons map to shape names so callers can pass either.
local EMOJI_TO_ICON: { [string]: string } = {}
for name, glyph in Theme.Icons do
	if ICONS[name] then
		EMOJI_TO_ICON[glyph] = name
	end
end
EMOJI_TO_ICON["💰"] = "Coin"
EMOJI_TO_ICON["💵"] = "Coin"
EMOJI_TO_ICON["🔒"] = "Lock"
EMOJI_TO_ICON["✓"] = "Check"
EMOJI_TO_ICON["X"] = "Close"
EMOJI_TO_ICON["⭐"] = "Star"
EMOJI_TO_ICON["★"] = "Star"

function Kit.iconName(icon: string?): string?
	if not icon then
		return nil
	end
	if ICONS[icon] then
		return icon
	end
	local mapped = EMOJI_TO_ICON[icon]
	if mapped then
		return mapped
	end
	-- Image-only icons (Shared.Assets Icons with no shape builder, e.g. "Modes")
	-- are icons too, so buttons draw them instead of printing the name.
	return if Kit.hasImageIcon(icon) then icon else nil
end

-- Optional image icons: ReplicatedStorage.Shared.Assets may export
-- Icons[name] = { image = "rbxassetid://...", x?, y?, w?, h? } (an atlas cell).
-- Looked up once; a missing module or key falls back to the shape icon.
local assetIcons: { [string]: any }? = nil
local assetsLoaded = false
local function imageIcon(name: string, resolved: string?): { [string]: any }?
	if not assetsLoaded then
		assetsLoaded = true
		local shared = ReplicatedStorage:FindFirstChild("Shared")
		local module = shared and shared:FindFirstChild("Assets")
		if module and module:IsA("ModuleScript") then
			local ok, result = pcall(require, module :: any)
			if ok and type(result) == "table" and type((result :: any).Icons) == "table" then
				assetIcons = (result :: any).Icons
			end
		end
	end
	local icons = assetIcons
	if not icons then
		return nil
	end
	local entry = icons[name] or (if resolved then icons[resolved] else nil)
	if type(entry) == "table" and type(entry.image) == "string" and entry.image ~= "" then
		return entry
	end
	return nil
end

--[[
	Icon. `name` is a Kit.ICONS key (or an emoji from Theme.Icons that maps to
	one). Returns a transparent square frame of `size` holding the shapes;
	recolour by rebuilding. When Shared.Assets provides Icons[name], the frame
	holds an ImageLabel ("Image") instead and `color` is not applied.
	props: Position, AnchorPoint, ZIndex, LayoutOrder, Name.
]]
function Kit.icon(parent: Instance, name: string, size: number, color: Color3?, props: { [string]: any }?): Frame
	local p = props or {}
	local root = Kit.new("Frame", {
		Name = p.Name or ("Icon" .. name),
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(size, size),
		Position = p.Position or UDim2.new(),
		AnchorPoint = p.AnchorPoint or Vector2.zero,
		ZIndex = p.ZIndex or 1,
		LayoutOrder = p.LayoutOrder or 0,
		Parent = parent,
	})
	root:SetAttribute("Icon", name)
	local resolved = Kit.iconName(name)
	local image = imageIcon(name, resolved)
	if image then
		local w, h = tonumber(image.w), tonumber(image.h)
		Kit.new("ImageLabel", {
			Name = "Image",
			BackgroundTransparency = 1,
			Image = image.image,
			ImageRectOffset = if w and h then Vector2.new(tonumber(image.x) or 0, tonumber(image.y) or 0) else Vector2.zero,
			ImageRectSize = if w and h then Vector2.new(w, h) else Vector2.zero,
			ScaleType = Enum.ScaleType.Fit,
			Size = UDim2.fromScale(1, 1),
			ZIndex = root.ZIndex,
			Parent = root,
		})
		root:SetAttribute("IconImage", true)
		return root
	end
	local builder = ICONS[resolved or ""]
	if builder then
		builder(root, color or C.Text)
	end
	return root
end

-- True when the Shared.Assets atlas has an image icon called `name`.
function Kit.hasImageIcon(name: string): boolean
	return imageIcon(name, nil) ~= nil
end

-- `preferred` (an atlas-only icon such as "PassDoubleCash") when the atlas has
-- it, else `fallback` (a shape icon), so art that failed to load degrades.
function Kit.pickIcon(preferred: string, fallback: string): string
	return if imageIcon(preferred, nil) then preferred else fallback
end

-- Default accent per icon so menus stay quiet (only the icon carries colour).
Kit.ICON_COLORS = {
	Coin = C.Gold,
	Gem = C.Rizz,
	Shop = C.Gold,
	Index = C.Violet,
	Ranking = C.Gold,
	Home = Color3.fromRGB(220, 232, 255),
	Free = C.Cash,
	Invite = C.Rizz,
	Settings = Color3.fromRGB(220, 232, 255),
	Surge = C.Amber,
	Orb = C.Orb,
	Chad = C.Rizz,
	Plus = C.Text,
	Close = C.Text,
	Check = C.Text,
	Star = C.Gold,
	Lock = C.TextDim,
	Music = C.Violet,
	Sound = C.Rizz,
	Hash = C.Gold,
	Merge = C.Cash,
}

-- Motion helpers -------------------------------------------------------------------------

type ButtonState = {
	face: Frame,
	base: Frame,
	gradient: UIGradient,
	rim: UIStroke,
	shine: Frame,
	label: TextLabel,
	icon: GuiObject?,
	color: Color3,
	enabled: boolean,
	depth: number,
	hover: boolean,
}

local buttons: { [Instance]: ButtonState } = setmetatable({}, { __mode = "k" }) :: any

-- The UIScale a gui animates with (reuses an existing one: a gui honours only one).
local function scaleOf(gui: GuiObject): UIScale
	local existing = gui:FindFirstChildOfClass("UIScale")
	if existing then
		return existing
	end
	return Kit.new("UIScale", { Name = "Scale", Parent = gui })
end

type FadeEntry = { inst: Instance, prop: string, value: number }

-- Per-gui animation state. `token` invalidates the delayed step of an older
-- appear/disappear; `entries` holds the resting transparencies while a fade
-- runs; `pop` invalidates the second half of an older pop.
type Motion = { token: number, entries: { FadeEntry }?, pop: number }
local motions: { [Instance]: Motion } = setmetatable({}, { __mode = "k" }) :: any
local function motionOf(gui: Instance): Motion
	local existing = motions[gui]
	if existing then
		return existing
	end
	local m: Motion = { token = 0, entries = nil, pop = 0 }
	motions[gui] = m
	return m
end

local FADE_PROPS: { { string } } = {
	{ "GuiObject", "BackgroundTransparency" },
	{ "TextLabel", "TextTransparency" },
	{ "TextButton", "TextTransparency" },
	{ "TextBox", "TextTransparency" },
	{ "ImageLabel", "ImageTransparency" },
	{ "ImageButton", "ImageTransparency" },
	{ "ViewportFrame", "ImageTransparency" },
	{ "ScrollingFrame", "ScrollBarImageTransparency" },
	{ "UIStroke", "Transparency" },
}

-- Everything visible in `gui` (itself included) with its resting transparency.
local function collectFade(gui: GuiObject): { FadeEntry }
	local entries: { FadeEntry } = {}
	local function add(inst: Instance)
		for _, spec in FADE_PROPS do
			if inst:IsA(spec[1]) then
				local value = (inst :: any)[spec[2]]
				if value < 1 then
					table.insert(entries, { inst = inst, prop = spec[2], value = value })
				end
			end
		end
	end
	add(gui)
	for _, descendant in gui:GetDescendants() do
		add(descendant)
	end
	return entries
end

local function setFade(entries: { FadeEntry }, hidden: boolean)
	for _, entry in entries do
		(entry.inst :: any)[entry.prop] = if hidden then 1 else entry.value
	end
end

--[[
	Kit.appear(gui, opts?): shows `gui` and eases it in: scale from 0.92 with a
	soft Back overshoot while everything inside fades in. Cancel-safe: called
	during a Kit.disappear it turns around from where it is. opts:
	  from   start scale (0.92)          time   seconds (0.22)
	  delay  start delay (0)             fade   false = scale only
	  style  Enum.EasingStyle (Back)
]]
function Kit.appear(gui: GuiObject, opts: { [string]: any }?)
	local o = opts or {}
	local m = motionOf(gui)
	m.token += 1
	local mine = m.token
	local time: number = o.time or 0.22
	local delay: number = o.delay or 0
	local scale = scaleOf(gui)
	local resuming = m.entries ~= nil and gui.Visible
	if not resuming then
		scale.Scale = o.from or 0.92
	end
	gui.Visible = true
	-- The scale tween is the longest one: the resting look is set when it completes.
	local last = tweenAfter(scale, time, delay, { Scale = 1 }, o.style or Enum.EasingStyle.Back, Enum.EasingDirection.Out)
	local tweens: { Tween } = { last }
	local entries: { FadeEntry }? = nil
	if o.fade ~= false or m.entries then
		local fading = m.entries or collectFade(gui)
		if not resuming then
			setFade(fading, true)
		end
		m.entries = fading
		entries = fading
		local fadeTime = time * 0.8
		for _, entry in fading do
			table.insert(tweens, tweenAfter(entry.inst, fadeTime, delay, { [entry.prop] = entry.value }))
		end
	end
	-- A timer alone can fire before the tweens' last step after a frame hitch: the entries
	-- would be dropped while the fade is still part-way, and the next fade or disappear would
	-- record that half-faded look as the resting one. So the tweens are stopped and the
	-- resting look is set by hand, once, when the scale tween completes (the timer is only
	-- the net under a tween that never reports).
	local settled = false
	local function settle()
		if settled or m.token ~= mine then
			return
		end
		settled = true
		-- Another tween took the scale over (a Kit.pop on the way in): it is left alone.
		local taken = not PREVIEW and last.PlaybackState == Enum.PlaybackState.Cancelled
		for _, tween in tweens do
			tween:Cancel()
		end
		if not taken then
			scale.Scale = 1
		end
		if entries then
			m.entries = nil
			setFade(entries, false)
		end
	end
	if PREVIEW then
		settle()
	else
		last.Completed:Connect(function(state)
			if state == Enum.PlaybackState.Completed then
				settle()
			end
		end)
		task.delay(delay + time + 0.5, settle)
	end
end

--[[
	Kit.disappear(gui, opts?): eases `gui` out (scale to 0.94 + fade, 0.14 s),
	then hides it and restores its resting look for the next Kit.appear.
	Cancel-safe: a later Kit.appear takes over mid-way. opts:
	  to       end scale (0.94)          time     seconds (0.14)
	  destroy  destroy instead of hide   onDone   called once it is gone
]]
function Kit.disappear(gui: GuiObject, opts: { [string]: any }?)
	local o = opts or {}
	local m = motionOf(gui)
	m.token += 1
	local mine = m.token
	local tweens: { Tween } = {}
	local function finish()
		if m.token ~= mine then
			return
		end
		-- A frame hitch can leave the tweens running past this timer: stop them, or they
		-- would undo the restored look below (and the next Kit.appear would find nothing to fade in).
		for _, tween in tweens do
			tween:Cancel()
		end
		local entries = m.entries
		m.entries = nil
		if o.destroy then
			gui:Destroy()
		else
			gui.Visible = false
			if entries then
				setFade(entries, false)
			end
			scaleOf(gui).Scale = 1
		end
		if o.onDone then
			o.onDone()
		end
	end
	if not gui.Visible then
		finish()
		return
	end
	local time: number = o.time or 0.14
	table.insert(tweens, Kit.tween(scaleOf(gui), time, { Scale = o.to or 0.94 }, Enum.EasingStyle.Quad, Enum.EasingDirection.In))
	local entries = m.entries or collectFade(gui)
	m.entries = entries
	for _, entry in entries do
		table.insert(tweens, Kit.tween(entry.inst, time, { [entry.prop] = 1 }))
	end
	if PREVIEW then
		finish()
	else
		task.delay(time + 0.05, finish)
	end
end

--[[
	Kit.fade(gui, show, time?, onHidden?): fades everything inside `gui` out or
	back in (0.15 s) without touching its Visible or scale, for groups whose
	owner manages those (the HUD while a window is open). Once faded out
	`onHidden` runs (park the group off screen there) and the resting look is
	restored, so whatever changes while it is away is painted normally.
	Cancel-safe both ways, like Kit.appear / Kit.disappear.
]]
function Kit.fade(gui: GuiObject, show: boolean, time: number?, onHidden: (() -> ())?)
	local m = motionOf(gui)
	m.token += 1
	local mine = m.token
	local t = time or 0.15
	local resuming = m.entries ~= nil
	local entries = m.entries or collectFade(gui)
	m.entries = entries
	if show and not resuming then
		setFade(entries, true)
	end
	local tweens: { Tween } = {}
	for _, entry in entries do
		table.insert(tweens, Kit.tween(entry.inst, t, { [entry.prop] = if show then entry.value else 1 }))
	end
	local function finish()
		if m.token ~= mine then
			return
		end
		m.entries = nil
		-- A frame hitch can leave the tweens running past this timer: stop them and set the
		-- resting look by hand, or a late fade-out tween would undo it (and the next fade-in
		-- would find nothing to show: the group stays invisible).
		for _, tween in tweens do
			tween:Cancel()
		end
		if not show and onHidden then
			onHidden()
		end
		setFade(entries, false)
	end
	if PREVIEW then
		finish()
	else
		task.delay(t + 0.03, finish)
	end
end

--[[
	Kit.stagger(children, step?): eases rows in one after another, `step`
	seconds apart (0.025). Rows past the 12th share the last delay so long lists
	stay quick. `children` is an array of GuiObjects, or a container whose
	visible GuiObject children are used in LayoutOrder.
]]
function Kit.stagger(children: { GuiObject } | Instance, step: number?)
	local list: { GuiObject } = {}
	if typeof(children) == "Instance" then
		for _, child in (children :: Instance):GetChildren() do
			if child:IsA("GuiObject") and child.Visible and not child:GetAttribute("KitChrome") then
				table.insert(list, child)
			end
		end
		table.sort(list, function(a, b)
			return a.LayoutOrder < b.LayoutOrder
		end)
	else
		list = children :: { GuiObject }
	end
	local gap = step or 0.025
	for i, gui in list do
		Kit.appear(gui, { from = 0.9, time = 0.24, delay = math.min(i - 1, 12) * gap })
	end
end

--[[
	Kit.pop(gui, strength?): a quick scale bump that springs back (a landing
	pop for counters, badges, rewards). strength 1 = +12 %. Skipped while the
	gui is appearing or disappearing.
]]
function Kit.pop(gui: GuiObject, strength: number?)
	local m = motionOf(gui)
	if PREVIEW or m.entries then
		return
	end
	m.pop += 1
	local mine = m.pop
	local scale = scaleOf(gui)
	Kit.tween(scale, 0.08, { Scale = 1 + 0.12 * (strength or 1) }, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	task.delay(0.08, function()
		if m.pop == mine and not m.entries then
			Kit.tween(scale, 0.24, { Scale = 1 }, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
		end
	end)
end

type Roll = { value: number, active: boolean, driver: NumberValue, conn: RBXScriptConnection?, tween: Tween? }
local rolls: { [Instance]: Roll } = setmetatable({}, { __mode = "k" }) :: any

--[[
	Kit.countTo(label, from, to, format?, duration?): rolls the number shown in
	`label` from `from` to `to` (eased, 0.45 s), then gives a small landing
	pop. Cancel-safe: called again mid-roll it continues from the number on
	screen. `format(n)` turns the number into text (default: tostring); n is
	rounded to a whole number when `from` and `to` are whole.
]]
function Kit.countTo(label: TextLabel | TextButton, from: number, to: number, format: ((number) -> string)?, duration: number?)
	local fmt: (number) -> string = format or tostring
	local whole = from == math.floor(from) and to == math.floor(to)
	local function show(n: number)
		(label :: any).Text = fmt(if whole then math.floor(n + 0.5) else n)
	end
	local roll = rolls[label]
	if not roll then
		roll = { value = from, active = false, driver = Instance.new("NumberValue"), conn = nil, tween = nil }
		rolls[label] = roll
	end
	local r = roll :: Roll
	local old = r.tween
	r.tween = nil
	if old then
		old:Cancel()
	end
	if r.conn then
		r.conn:Disconnect()
		r.conn = nil
	end
	local start = if r.active then r.value else from
	if PREVIEW or start == to then
		r.active = false
		r.value = to
		show(to)
		return
	end
	r.active = true
	r.value = start
	r.driver.Value = start
	show(start)
	local conn = r.driver:GetPropertyChangedSignal("Value"):Connect(function()
		r.value = r.driver.Value
		show(r.value)
	end)
	r.conn = conn
	local tween = Kit.tween(r.driver, duration or 0.45, { Value = to }, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	r.tween = tween
	tween.Completed:Connect(function(state)
		if r.tween ~= tween then
			return
		end
		conn:Disconnect()
		r.conn = nil
		r.tween = nil
		r.active = false
		r.value = to
		show(to)
		if state == Enum.PlaybackState.Completed then
			Kit.pop(label, 0.5)
		end
	end)
end

--[[
	Kit.breathe(gui, amount?): slow idle breathing scale (+4 %) for the single
	most important call to action on screen. One repeating tween, no per-frame
	work. On a Kit.button the face and lip breathe, so hover and press keep
	working. Returns a stop function that eases back to rest.
]]
function Kit.breathe(gui: GuiObject, amount: number?): () -> ()
	if PREVIEW then
		return function() end
	end
	local state = buttons[gui]
	local targets: { GuiObject } = if state then { state.face, state.base } else { gui }
	local info = TweenInfo.new(1.2, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true)
	local tweens: { Tween } = {}
	local scales: { UIScale } = {}
	for _, target in targets do
		local scale = scaleOf(target)
		scale.Scale = 1
		local tween = TweenService:Create(scale, info, { Scale = 1 + (amount or 0.04) })
		tween:Play()
		table.insert(tweens, tween)
		table.insert(scales, scale)
	end
	local stopped = false
	return function()
		if stopped then
			return
		end
		stopped = true
		for i, tween in tweens do
			tween:Cancel()
			Kit.tween(scales[i], 0.2, { Scale = 1 })
		end
	end
end

-- Hover lift and press squash (0.94) with a springy release.
function Kit.bouncy(button: GuiButton, hover: number?): UIScale
	local scale = scaleOf(button)
	local up = hover or 1.03
	Kit.selectable(button)
	-- A finger tap fires MouseEnter but not always MouseLeave, so touch never hovers.
	button.MouseEnter:Connect(function()
		if not Kit.touch then
			Kit.tween(scale, 0.12, { Scale = up })
		end
	end)
	button.MouseLeave:Connect(function()
		Kit.tween(scale, 0.12, { Scale = 1 })
	end)
	-- The gamepad selection lifts the button like a hover (pcall: the preview has no Selection* events).
	pcall(function()
		button.SelectionGained:Connect(function()
			Kit.tween(scale, 0.12, { Scale = up })
		end)
		button.SelectionLost:Connect(function()
			Kit.tween(scale, 0.12, { Scale = 1 })
		end)
	end)
	button.MouseButton1Down:Connect(function()
		Kit.tween(scale, 0.07, { Scale = 0.94 }, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
	end)
	button.MouseButton1Up:Connect(function()
		Kit.tween(scale, 0.28, { Scale = if Kit.touch then 1 else up }, Enum.EasingStyle.Back)
	end)
	button.Activated:Connect(function()
		if Kit.gamepad then
			-- A press from the controller squashes and springs like a click.
			Kit.tween(scale, 0.07, { Scale = 0.94 }, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
			task.delay(0.08, function()
				Kit.tween(scale, 0.28, { Scale = up }, Enum.EasingStyle.Back)
			end)
		end
	end)
	return scale
end

--[[
	Idle sheen: a soft light band that glides across `face` every `every`
	seconds (for the one call to action on screen). `face` must clip.
	Returns a stop function.
]]
function Kit.shimmer(face: GuiObject, every: number?, zindex: number?): () -> ()
	face.ClipsDescendants = true
	local bar = Kit.new("Frame", {
		Name = "Sheen",
		BackgroundColor3 = WHITE,
		BorderSizePixel = 0,
		Size = UDim2.new(0, 40, 1.6, 0),
		Position = UDim2.fromScale(-0.4, -0.3),
		Rotation = 18,
		ZIndex = zindex or 3,
		Parent = face,
	})
	chrome(bar)
	Kit.new("UIGradient", {
		Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 1),
			NumberSequenceKeypoint.new(0.5, 0.65),
			NumberSequenceKeypoint.new(1, 1),
		}),
		Parent = bar,
	})
	local alive = true
	local period = every or 4.5
	task.spawn(function()
		task.wait(math.random() * period)
		while alive and bar.Parent do
			bar.Position = UDim2.fromScale(-0.4, -0.3)
			Kit.tween(bar, 1.2, { Position = UDim2.fromScale(1.2, -0.3) }, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut)
			task.wait(period)
		end
	end)
	return function()
		alive = false
		bar:Destroy()
	end
end

-- Buttons ---------------------------------------------------------------------------

-- Face of a moulded button: lighter at the top, the true colour below.
local function faceColors(color: Color3, hover: boolean): ColorSequence
	local lift = if hover then 0.08 else 0
	return ColorSequence.new({
		ColorSequenceKeypoint.new(0, Kit.lighten(color, 0.24 + lift)),
		ColorSequenceKeypoint.new(0.5, Kit.lighten(color, 0.04 + lift)),
		ColorSequenceKeypoint.new(1, Kit.lighten(color, lift * 0.5)),
	})
end

local function paintButton(state: ButtonState)
	local color = if state.enabled then state.color else DISABLED
	local lipColor = Kit.lip(color)
	state.gradient.Color = faceColors(color, state.hover and state.enabled)
	state.base.BackgroundColor3 = lipColor
	state.rim.Color = lipColor
	state.shine.BackgroundTransparency = if state.enabled then 0.4 else 0.7
	state.label.TextTransparency = if state.enabled then 0 else 0.35
	if state.icon then
		if state.icon:IsA("TextLabel") then
			state.icon.TextTransparency = if state.enabled then 0 else 0.4
		end
	end
end

--[[
	A chunky moulded button: coloured face (lighter at the top, white highlight
	line) on a darker lip; squashes on press and springs back. props:
	  Text, Icon (Kit.ICONS name or emoji), IconColor, Layout ("Inline" | "Stack": icon above text),
	  Color, Size, Position, AnchorPoint, LayoutOrder, Name, ZIndex,
	  Font, TextSize, TextColor, RichText, Radius, Depth, Sound (default "Click"),
	  Shimmer (idle sheen for the call to action), Breathe (idle breathing scale
	  for the single most important call to action).
	Returns the TextButton (the hit area). Recolour/relabel with Kit.setButton,
	enable/disable with Kit.setEnabled.
]]
function Kit.button(parent: Instance, props: { [string]: any }, onClick: (() -> ())?): TextButton
	local color: Color3 = props.Color or C.Good
	local size: UDim2 = props.Size or UDim2.fromOffset(160, 48)
	local fixedHeight = if size.Y.Scale == 0 then size.Y.Offset else nil
	local depth = props.Depth or (if fixedHeight and fixedHeight < 44 then 4 else 5)
	local radius = props.Radius or Kit.RADIUS.M

	local button = Kit.new("TextButton", {
		Name = props.Name or "Button",
		AutoButtonColor = false,
		BackgroundTransparency = 1,
		Text = "",
		Size = size,
		Position = props.Position or UDim2.new(),
		AnchorPoint = props.AnchorPoint or Vector2.zero,
		LayoutOrder = props.LayoutOrder or 0,
		ZIndex = props.ZIndex or 1,
		Parent = parent,
	})

	-- Soft navy contact shadow under the lip.
	local contact = Kit.new("Frame", {
		Name = "Shadow",
		BackgroundColor3 = C.Ink,
		BackgroundTransparency = 0.72,
		BorderSizePixel = 0,
		Size = UDim2.new(1, -4, 1, -depth),
		Position = UDim2.fromOffset(2, depth + 3),
		Parent = button,
	})
	Kit.corner(contact, radius)

	local base = Kit.new("Frame", {
		Name = "Base",
		BackgroundColor3 = Kit.lip(color),
		Size = UDim2.new(1, 0, 1, -depth),
		Position = UDim2.new(0.5, 0, 0, depth),
		AnchorPoint = Vector2.new(0.5, 0),
		Parent = button,
	})
	Kit.corner(base, radius)

	local face = Kit.new("Frame", {
		Name = "Face",
		BackgroundColor3 = WHITE,
		Size = UDim2.new(1, 0, 1, -depth),
		-- Centred so Breathe's UIScale grows both sides evenly, not off the right edge.
		Position = UDim2.fromScale(0.5, 0),
		AnchorPoint = Vector2.new(0.5, 0),
		Parent = button,
	})
	Kit.corner(face, radius)
	local rim = Kit.new("UIStroke", {
		Thickness = 1.5,
		Color = Kit.lip(color),
		Transparency = 0.2,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual,
		Parent = face,
	})
	local gradient = Kit.gradient(face, color, color)
	local shine = highlight(face, radius, 0.4)
	shine.ZIndex = 2

	local faceHeight = if fixedHeight then fixedHeight - depth else nil
	local font = props.Font or F.UI
	local textColor = props.TextColor or Kit.inkOn(color)
	local label: TextLabel
	local icon: GuiObject? = nil
	local iconName = Kit.iconName(props.Icon)
	local iconColor = props.IconColor or (if iconName then Kit.ICON_COLORS[iconName] else nil) or textColor
	if props.Layout == "Stack" then
		local iconSize = if faceHeight then math.floor(faceHeight * 0.5) else 32
		if iconName then
			icon = Kit.icon(face, iconName, iconSize, iconColor, {
				Name = "Icon",
				Position = UDim2.new(0.5, 0, 0.08, 0),
				AnchorPoint = Vector2.new(0.5, 0),
				ZIndex = 2,
			})
		elseif props.Icon then
			icon = Kit.text(face, {
				Name = "Icon",
				Text = props.Icon,
				TextSize = iconSize,
				Size = UDim2.new(1, 0, 0.56, 0),
				Position = UDim2.fromScale(0, 0.04),
				StrokeThickness = 0,
				ZIndex = 2,
			})
		end
		label = Kit.text(face, {
			Name = "Label",
			Text = string.upper(props.Text or ""),
			Font = font,
			TextSize = props.TextSize or (if faceHeight then math.clamp(math.floor(faceHeight * 0.2), 12, 18) else nil),
			TextColor3 = textColor,
			TextWrapped = false,
			Size = UDim2.new(1, -4, 0.28, 0),
			Position = UDim2.new(0, 2, 0.68, 0),
			StrokeThickness = 0,
			ZIndex = 2,
		})
	else
		local textSize = props.TextSize or (if faceHeight then math.clamp(math.floor(faceHeight * 0.42), 12, 30) else nil)
		local inset = 10
		if iconName then
			local iconSize = if faceHeight then math.floor(faceHeight * 0.6) else 24
			icon = Kit.icon(face, iconName, iconSize, iconColor, {
				Name = "Icon",
				Position = UDim2.new(0, 10, 0.5, 0),
				AnchorPoint = Vector2.new(0, 0.5),
				ZIndex = 2,
			})
			inset = 10 + iconSize + 6
		end
		local text = props.Text or ""
		if props.Icon and not iconName then
			text = props.Icon .. "  " .. text
		end
		label = Kit.text(face, {
			Name = "Label",
			Text = text,
			Font = font,
			RichText = props.RichText or false,
			TextSize = textSize,
			MaxTextSize = if faceHeight or props.TextSize then nil else 28,
			TextColor3 = textColor,
			TextWrapped = false,
			Size = UDim2.new(1, -(inset + 10), 1, -4),
			Position = UDim2.fromOffset(inset, 2),
			TextXAlignment = if iconName then Enum.TextXAlignment.Left else Enum.TextXAlignment.Center,
			StrokeThickness = 0,
			ZIndex = 2,
		})
		if iconName and props.Center ~= false then
			-- Centre the icon+text pair.
			label.TextXAlignment = Enum.TextXAlignment.Center
			label.Size = UDim2.new(1, -inset, 1, -4)
		end
	end
	if props.Shimmer then
		Kit.shimmer(face, 4.5, 3)
	end

	local state: ButtonState = {
		face = face,
		base = base,
		gradient = gradient,
		rim = rim,
		shine = shine,
		label = label,
		icon = icon,
		color = color,
		enabled = true,
		depth = depth,
		hover = false,
	}
	buttons[button] = state
	paintButton(state)

	if props.Breathe then
		Kit.breathe(button)
	end

	local scale = scaleOf(button)
	local function rest()
		face.Position = UDim2.fromScale(0.5, 0)
		base.Visible = true
	end
	Kit.selectable(button)
	local function hoverOn()
		if state.enabled then
			state.hover = true
			Kit.tween(scale, 0.12, { Scale = 1.03 })
			paintButton(state)
		end
	end
	local function hoverOff()
		state.hover = false
		Kit.tween(scale, 0.12, { Scale = 1 })
		paintButton(state)
		rest()
	end
	local function press()
		if state.enabled then
			Kit.tween(scale, 0.07, { Scale = 0.94 }, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
			Kit.tween(face, 0.07, { Position = UDim2.new(0.5, 0, 0, depth - 1) }, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
		end
	end
	local function release()
		Kit.tween(scale, 0.28, { Scale = if state.hover then 1.03 else 1 }, Enum.EasingStyle.Back)
		Kit.tween(face, 0.22, { Position = UDim2.fromScale(0.5, 0) }, Enum.EasingStyle.Back)
	end
	-- A finger tap fires MouseEnter but not always MouseLeave, so touch never hovers
	-- (a stuck hover would leave the button enlarged and lit after the tap).
	button.MouseEnter:Connect(function()
		if not Kit.touch then
			hoverOn()
		end
	end)
	button.MouseLeave:Connect(hoverOff)
	pcall(function()
		button.SelectionGained:Connect(hoverOn)
		button.SelectionLost:Connect(hoverOff)
	end)
	button.MouseButton1Down:Connect(press)
	button.MouseButton1Up:Connect(function()
		if Kit.touch then
			state.hover = false
			paintButton(state)
		end
		release()
	end)
	button.Activated:Connect(function()
		if Kit.gamepad then
			press()
			task.delay(0.08, release)
		end
		if not state.enabled then
			Kit.sound("Error")
			return
		end
		Kit.sound(props.Sound or "Click")
		if onClick then
			onClick()
		end
	end)
	button:SetAttribute("BaseColor", color)
	return button
end

function Kit.setButton(button: TextButton, text: string?, color: Color3?)
	local state = buttons[button]
	if not state then
		return
	end
	if text then
		state.label.Text = if state.icon
				and state.icon:IsA("Frame")
				and state.label.Position.Y.Scale > 0.5
			then string.upper(text)
			else text
	end
	if color then
		state.color = color
		if not state.label:GetAttribute("FixedTextColor") then
			state.label.TextColor3 = Kit.inkOn(color)
		end
	end
	paintButton(state)
end

function Kit.setEnabled(button: TextButton, enabled: boolean)
	local state = buttons[button]
	if not state or state.enabled == enabled then
		return
	end
	state.enabled = enabled
	button.Active = enabled
	paintButton(state)
end

function Kit.buttonFace(button: TextButton): Frame?
	local state = buttons[button]
	return if state then state.face else nil
end

function Kit.buttonLabel(button: TextButton): TextLabel?
	local state = buttons[button]
	return if state then state.label else nil
end

-- Invisible square hit area `size` px wide, centred on a small button (close
-- buttons), so a 36-40 px button still takes 44+ px taps. Calls `onClick`.
function Kit.hitArea(button: GuiButton, size: number, onClick: () -> ()): TextButton
	local hit = Kit.new("TextButton", {
		Name = "Hit",
		BackgroundTransparency = 1,
		AutoButtonColor = false,
		Text = "",
		Size = UDim2.fromOffset(size, size),
		Position = UDim2.fromScale(0.5, 0.5),
		AnchorPoint = Vector2.new(0.5, 0.5),
		ZIndex = button.ZIndex + 3,
		Selectable = false,
		Parent = button,
	})
	hit.Activated:Connect(onClick)
	return hit
end

-- Glass ---------------------------------------------------------------------------------
--[[
	Windows are glass: translucent panes over the world, which Kit.setBlur blurs
	and the caller's backdrop dims lightly while one is open (Roblox has no
	backdrop blur per frame, so the frosting is the world blur under a tint).
	All of it is static instances: nothing here runs per frame. Tokens live in
	Theme.Glass. Text on glass is white; primary buttons, rarity colours,
	currency chips and badges stay solid so the eye lands on them.
]]

-- The glass edge: a thin stroke, brightest along the top (`top` transparency)
-- and fading toward `bottom`. The fade lives in the stroke's UIGradient, so
-- Color and Transparency may be repainted.
local function glassEdge(parent: Instance, color: Color3, thickness: number, top: number, bottom: number): UIStroke
	local stroke = Kit.new("UIStroke", {
		Name = "Edge",
		Thickness = thickness,
		Color = color,
		Transparency = top,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual,
		Parent = parent,
	})
	local fade = 1 - (1 - math.max(bottom, top)) / math.max(1 - top, 0.01)
	Kit.new("UIGradient", { Rotation = 90, Transparency = NumberSequence.new(0, fade), Parent = stroke })
	return stroke
end

-- Soft ring just outside the edge of `parent` (a coloured glow, or a pane's
-- navy halo): a hollow frame with a wide faint stroke, so nothing is drawn
-- behind the translucent body.
local function halo(parent: GuiObject, name: string, radius: number, color: Color3, thickness: number, transparency: number): Frame
	local ring = Kit.new("Frame", {
		Name = name,
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 4, 1, 4),
		Position = UDim2.fromOffset(-2, -2),
		ZIndex = parent.ZIndex,
		Parent = parent,
	})
	Kit.corner(ring, radius + 2)
	Kit.new("UIStroke", { Thickness = thickness, Color = color, Transparency = transparency, Parent = ring })
	chrome(ring)
	return ring
end

--[[
	Kit.paintGlass(frame, tint?, transparency?, edge?): repaints a glass surface
	(Kit.glass, or a Kit.panel built with Glass). tint nil = plain white glass,
	else glass in that colour (G.Tinted). `transparency` overrides the fill.
	`edge` is a solid outline colour (a rarity, the player's own row); without
	it the edge is the faint white one, or the tint itself. The fill is the dark
	card fill (G.Cell) with a share of the tint mixed in; it is never more
	see-through than G.Dimmed, so a card always holds its text.
]]
local GLASS_FILL = ColorSequence.new(G.CellTop, G.Cell)
function Kit.paintGlass(frame: GuiObject, tint: Color3?, transparency: number?, edge: Color3?)
	frame.BackgroundTransparency = math.min(transparency or (if tint then G.Tinted else G.Surface), G.Dimmed)
	local gradient = frame:FindFirstChildOfClass("UIGradient")
	if gradient then
		gradient.Color = if tint then ColorSequence.new(G.CellTop:Lerp(tint, G.TintMix), G.Cell:Lerp(tint, G.TintMix)) else GLASS_FILL
	end
	local stroke = frame:FindFirstChildOfClass("UIStroke")
	if stroke then
		stroke.Color = edge or tint or G.Edge
		stroke.Transparency = if edge then 0.05 elseif tint then G.TintedEdge else G.SurfaceEdge
	end
end

--[[
	Glass surface for the rows, cells and stat boxes inside a window: white
	glass with a thin light edge. props: Size, Position, AnchorPoint,
	LayoutOrder, Visible, Name, ZIndex, Radius, Color (tints it), Transparency
	(fill), Raised (a brighter pane), StrokeThickness, StrokeColor. As with
	Kit.panel the fill colour lives in the frame's UIGradient (the frame itself
	is white) and the edge is its UIStroke; Kit.paintGlass repaints both. Adds
	no child frames, so it is safe as a layout container.
]]
function Kit.glass(parent: Instance, props: { [string]: any }): Frame
	local frame = Kit.new("Frame", {
		Name = props.Name or "Glass",
		BackgroundColor3 = WHITE,
		BorderSizePixel = 0,
		Size = props.Size or UDim2.fromOffset(200, 100),
		Position = props.Position or UDim2.new(),
		AnchorPoint = props.AnchorPoint or Vector2.zero,
		LayoutOrder = props.LayoutOrder or 0,
		Visible = if props.Visible == nil then true else props.Visible,
		ZIndex = props.ZIndex or 1,
		Parent = parent,
	})
	Kit.corner(frame, props.Radius or Kit.RADIUS.M)
	Kit.new("UIGradient", { Rotation = 90, Parent = frame })
	glassEdge(frame, G.Edge, props.StrokeThickness or 1, G.SurfaceEdge, G.SurfaceEdge + 0.1)
	Kit.paintGlass(
		frame,
		props.Color,
		props.Transparency or (if props.Raised and not props.Color then G.SurfaceHi else nil),
		props.StrokeColor
	)
	return frame
end

--[[
	Kit.hudGlass(parent, props): the glass pill of a notification that sits
	straight over the unblurred world (toasts, the quest pill, the HUD strips):
	the window tint as glass the world shows through (G.Pill), the thin light
	edge and a soft navy halo and shadow. Text on it is Kit.hudText (outlined).
	props: Size (its offset height rounds the ends), Position, AnchorPoint,
	LayoutOrder, Visible, Name, ZIndex, Radius, Color (tint), Transparency,
	Edge (edge colour), Shadow (false = none), Button (true = a TextButton), Accent (a
	coloured bar down the left edge: the notification's tier), Quiet (true = a permanent
	strip: more see-through, no halo or shadow). The tint is the
	BackgroundColor3, shaded toward the bottom by a multiplying gradient, so it
	may be tweened to another colour. Chrome children: Halo, Shadow.
]]
local HUD_SHADE = ColorSequence.new(WHITE, WHITE:Lerp(G.Tint, 0.45))
function Kit.hudGlass(parent: Instance, props: { [string]: any }): GuiObject
	local size: UDim2 = props.Size or UDim2.fromOffset(240, 44)
	local radius: number = props.Radius or math.max(size.Y.Offset // 2, 8)
	local frame = Kit.new(if props.Button then "TextButton" else "Frame", {
		Name = props.Name or "Pill",
		BackgroundColor3 = props.Color or G.TintTop,
		BackgroundTransparency = props.Transparency or (if props.Quiet then G.Quiet else G.Pill),
		BorderSizePixel = 0,
		Size = size,
		Position = props.Position or UDim2.new(),
		AnchorPoint = props.AnchorPoint or Vector2.zero,
		LayoutOrder = props.LayoutOrder or 0,
		Visible = if props.Visible == nil then true else props.Visible,
		ZIndex = props.ZIndex or 1,
		Parent = parent,
	})
	if props.Button then
		frame.Text = ""
		frame.AutoButtonColor = false
	end
	Kit.corner(frame, radius)
	Kit.new("UIGradient", { Rotation = 90, Color = HUD_SHADE, Parent = frame })
	-- Border mode: on a TextButton a contextual stroke would outline the text instead.
	glassEdge(frame, props.Edge or G.Edge, G.EdgeThickness, G.EdgeTop, G.EdgeBottom).ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	if props.Shadow ~= false and not props.Quiet then
		halo(frame, "Halo", radius, G.Tint, 3, G.Shadow)
		Kit.shadow(frame, radius, 1, 0)
	end
	if props.Accent then
		-- Notification tier: a bar in the notification's colour down the left edge.
		local bar = Kit.new("Frame", {
			Name = "Accent",
			BackgroundColor3 = props.Accent,
			BorderSizePixel = 0,
			Size = UDim2.new(0, 5, 1, -math.max(radius, 12)),
			Position = UDim2.new(0, math.max(radius // 2, 6), 0.5, 0),
			AnchorPoint = Vector2.new(0, 0.5),
			ZIndex = frame.ZIndex + 1,
			Parent = frame,
		})
		Kit.round(bar)
		chrome(bar)
	end
	return frame
end

-- Kit.panel's glass builds: "body" is a window pane, a Color makes a coloured
-- card with a glow in its own colour, and anything else is a Kit.glass surface.
local function glassPanel(parent: Instance, props: { [string]: any }): Frame
	local body = props.Glass == "body"
	local color: Color3? = props.Color
	if not body and not color then
		props.Name = props.Name or "Panel"
		props.Radius = props.Radius or Kit.RADIUS.L
		props.Raised = props.Elevated
		return Kit.glass(parent, props)
	end
	local radius = props.Radius or (if body then G.Radius else Kit.RADIUS.L)
	local frame = Kit.new("Frame", {
		Name = props.Name or "Panel",
		BackgroundColor3 = WHITE,
		-- Every body pane wears the same token: no per-window opacity.
		BackgroundTransparency = if body then G.Body else (props.Transparency or G.Card),
		BorderSizePixel = 0,
		Size = props.Size or UDim2.fromOffset(200, 100),
		Position = props.Position or UDim2.new(),
		AnchorPoint = props.AnchorPoint or Vector2.zero,
		LayoutOrder = props.LayoutOrder or 0,
		Visible = if props.Visible == nil then true else props.Visible,
		ZIndex = props.ZIndex or 1,
		Parent = parent,
	})
	Kit.corner(frame, radius)
	if color then
		Kit.gradient(frame, Kit.lighten(color, 0.2), Kit.darken(color, 0.1))
		glassEdge(frame, props.StrokeColor or Kit.lighten(color, 0.5), props.StrokeThickness or 2, 0, 0.65)
		highlight(frame, radius, G.Highlight)
		halo(frame, "Aura", radius, props.GlowColor or color, 5, G.CardGlow)
	else
		Kit.gradient(frame, G.TintTop, G.Tint)
		glassEdge(frame, props.StrokeColor or G.Edge, props.StrokeThickness or G.EdgeThickness, G.EdgeTop, G.EdgeBottom)
		highlight(frame, radius, G.Highlight)
		-- A soft navy halo, tighter near the edge, in place of the plastic lip.
		halo(frame, "Halo", radius, G.Tint, 4, G.Shadow)
		halo(frame, "HaloWide", radius, G.Tint, 10, 1 - (1 - G.Shadow) * 0.5)
	end
	if props.Shadow ~= false then
		Kit.shadow(frame, radius, if body then 2 else 1, 0)
	end
	return frame
end

-- Panels / pills ----------------------------------------------------------------------

--[[
	Moulded plastic panel: royal-blue body (lighter at the top), a white
	highlight line along the top inner edge, a darker blue lip under the bottom
	edge and a soft navy shadow. props: Color (body tint), Elevated (SurfaceHi),
	Size, Position, AnchorPoint, LayoutOrder, Visible, Name, ZIndex, Radius,
	StrokeThickness, StrokeColor, Shadow (false = no lip and no shadow),
	Transparency. The body colour lives in the frame's UIGradient (the frame
	itself is white) and the outline is its UIStroke; both may be recoloured.
	Chrome children (Highlight, Lip, Shadow) carry the KitChrome attribute.

	Glass = true builds the panel as glass instead, for anything inside a window
	(notifications over the unblurred world use Kit.hudGlass): a Kit.glass surface, or
	with a Color a coloured glass card (tinted gradient, light edge, a glow in
	its own colour or GlowColor: chrome Highlight, Aura, Shadow). Glass = "body" is the
	window pane itself (Kit.window).
]]
function Kit.panel(parent: Instance, props: { [string]: any }): Frame
	if props.Glass then
		return glassPanel(parent, props)
	end
	local color: Color3 = props.Color or (if props.Elevated then C.SurfaceHi else C.Surface)
	local frame = Kit.new("Frame", {
		BackgroundColor3 = WHITE,
		BackgroundTransparency = props.Transparency or 0,
		BorderSizePixel = 0,
		Size = props.Size or UDim2.fromOffset(200, 100),
		Position = props.Position or UDim2.new(),
		AnchorPoint = props.AnchorPoint or Vector2.zero,
		LayoutOrder = props.LayoutOrder or 0,
		Visible = if props.Visible == nil then true else props.Visible,
		Name = props.Name or "Panel",
		ZIndex = props.ZIndex or 1,
		Parent = parent,
	})
	local radius = props.Radius or Kit.RADIUS.L
	local lipColor = Kit.lip(color)
	Kit.corner(frame, radius)
	Kit.stroke(frame, props.StrokeThickness or 1.5, props.StrokeColor or lipColor)
	Kit.gradient(frame, Kit.lighten(color, 0.1), color:Lerp(lipColor, 0.12))
	highlight(frame, radius, 0.55)
	if props.Shadow ~= false then
		local depth = if radius >= 14 then 4 else 3
		lip(frame, radius, depth, lipColor)
		Kit.shadow(frame, radius, 1, depth)
	end
	return frame
end

-- Deeper-blue inset well inside a panel: slightly shaded along its top edge
-- (a multiplying gradient, so BackgroundColor3 can be recoloured) and a thin
-- darker outline. Adds no child frames, so it is safe as a layout container.
-- Glass = true: the inset of a glass window (tab bars, tracks), a darker pane
-- of Ink (G.Inset) with a faint light edge.
function Kit.well(parent: Instance, props: { [string]: any }): Frame
	local glass = props.Glass == true
	local frame = Kit.new("Frame", {
		Name = props.Name or "Well",
		BackgroundColor3 = props.Color or (if glass then C.Ink else C.Well),
		BackgroundTransparency = props.Transparency or (if glass then G.Inset else 0),
		BorderSizePixel = 0,
		Size = props.Size or UDim2.fromScale(1, 1),
		Position = props.Position or UDim2.new(),
		AnchorPoint = props.AnchorPoint or Vector2.zero,
		LayoutOrder = props.LayoutOrder or 0,
		ZIndex = props.ZIndex or 1,
		Parent = parent,
	})
	local radius = props.Radius or Kit.RADIUS.M
	Kit.corner(frame, radius)
	Kit.new("UIGradient", {
		Rotation = 90,
		Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, Color3.new(0.84, 0.86, 0.92)),
			ColorSequenceKeypoint.new(0.18, WHITE),
			ColorSequenceKeypoint.new(1, WHITE),
		}),
		Parent = frame,
	})
	Kit.new("UIStroke", {
		Thickness = 1,
		Color = if glass then G.Edge else C.Edge,
		Transparency = if glass then 0.8 else 0.3,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual,
		Parent = frame,
	})
	return frame
end

--[[
	Small rounded chip. Tinted by default (soft fill of the colour, light text);
	Solid = true for badges and tags (full colour, darker lip outline, ink or
	white text by contrast). Rotation is ignored (chips sit flat).
]]
function Kit.pill(parent: Instance, props: { [string]: any }): TextLabel
	local color: Color3 = props.Color or C.SurfaceHi
	local solid = props.Solid == true
	local label = Kit.text(parent, {
		Name = props.Name or "Pill",
		Text = props.Text or "",
		Font = props.Font or F.UI,
		TextSize = props.TextSize or Kit.TEXT.Tiny,
		MinPx = props.MinPx,
		TextColor3 = props.TextColor or (if solid then Kit.inkOn(color) else Kit.lighten(color, 0.55)),
		TextWrapped = false,
		BackgroundTransparency = if solid then 0 else 0.7,
		BackgroundColor3 = color,
		Size = props.Size or UDim2.fromOffset(80, 22),
		Position = props.Position or UDim2.new(),
		AnchorPoint = props.AnchorPoint or Vector2.zero,
		LayoutOrder = props.LayoutOrder or 0,
		ZIndex = props.ZIndex or 1,
		AutomaticSize = props.AutomaticSize or Enum.AutomaticSize.None,
		Visible = if props.Visible == nil then true else props.Visible,
		RichText = props.RichText or false,
		StrokeThickness = 0,
	})
	if props.AutomaticSize then
		Kit.padding(label, 0, 10)
	end
	Kit.round(label)
	if solid then
		-- Multiplying gradient: a touch lighter at the top, like moulded plastic.
		Kit.gradient(label, WHITE, Color3.new(0.88, 0.88, 0.92))
	end
	Kit.new("UIStroke", {
		Name = "Edge",
		Thickness = if solid then 1.5 else 1,
		Color = if solid then Kit.lip(color) else color,
		Transparency = if solid then 0 else 0.35,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
		Parent = label,
	})
	return label
end

-- Coral notification dot centred on the top-right corner of `target` (nil text
-- hides it), so it overhangs the rim instead of covering the icon. Pops in when
-- shown and pops again when its text changes.
function Kit.setBadge(target: GuiObject, text: string?)
	local holder: GuiObject = buttons[target] and buttons[target].face or target
	local badge = holder:FindFirstChild("Badge") :: TextLabel?
	if not text then
		if badge then
			badge.Visible = false
		end
		return
	end
	if not badge then
		local created = Kit.pill(holder, {
			Name = "Badge",
			Text = text,
			Color = C.Danger,
			Solid = true,
			TextColor = C.Text,
			TextSize = Kit.TEXT.Small,
			Size = UDim2.fromOffset(20, 20),
			Position = UDim2.new(1, -3, 0, 3),
			AnchorPoint = Vector2.new(0.5, 0.5),
			ZIndex = 5,
			Visible = false,
		})
		local edge = created:FindFirstChild("Edge") :: UIStroke
		edge.Color = WHITE
		edge.Thickness = 2
		Kit.new("UIScale", { Name = "Pop", Scale = 1, Parent = created })
		badge = created
	end
	local b = badge :: TextLabel
	local changed = b.Text ~= text
	b.Text = text
	b.Size = UDim2.fromOffset(math.max(20, 8 + utf8.len(text) :: number * 8), 20)
	if not b.Visible then
		b.Visible = true
		local pop = b:FindFirstChild("Pop") :: UIScale
		pop.Scale = 0.4
		Kit.tween(pop, 0.26, { Scale = 1 }, Enum.EasingStyle.Back)
	elseif changed then
		Kit.pop(b, 0.8)
	end
end

-- Softly pulsing ring around `target` to draw the eye (tutorial / ready). One
-- repeating tween per ring.
local glowTweens: { [Instance]: Tween } = setmetatable({}, { __mode = "k" }) :: any
function Kit.setGlow(target: GuiObject, on: boolean, color: Color3?)
	local holder: GuiObject = buttons[target] and buttons[target].face or target
	local ring = holder:FindFirstChild("Glow") :: Frame?
	if not on then
		local tween = glowTweens[holder]
		glowTweens[holder] = nil
		if tween then
			tween:Cancel()
		end
		if ring then
			ring.Visible = false
		end
		return
	end
	if not ring then
		local created = Kit.new("Frame", {
			Name = "Glow",
			BackgroundTransparency = 1,
			Size = UDim2.new(1, 10, 1, 10),
			Position = UDim2.fromOffset(-5, -5),
			ZIndex = 4,
			Parent = holder,
		})
		chrome(created)
		local corner = holder:FindFirstChildOfClass("UICorner")
		Kit.corner(created, (if corner then corner.CornerRadius.Offset else Kit.RADIUS.M) + 5)
		Kit.new("UIStroke", { Name = "Ring", Thickness = 3, Color = color or C.Gold, Parent = created })
		ring = created
	end
	local r = ring :: Frame
	r.Visible = true
	local stroke = r:FindFirstChild("Ring") :: UIStroke
	stroke.Color = color or C.Gold
	if glowTweens[holder] or PREVIEW then
		return
	end
	stroke.Transparency = 0
	local info = TweenInfo.new(0.7, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true)
	local tween = TweenService:Create(stroke, info, { Transparency = 0.7 })
	tween:Play()
	glowTweens[holder] = tween
end

-- Horizontal progress bar in a deep-blue track (props.Glass: a dark glass
-- track): the fill is a moulded strip (lighter on top, white highlight) that
-- eases to each new value. Returns the frame, a setter (0..1, instant?) and
-- the label.
function Kit.progress(parent: Instance, props: { [string]: any }): (Frame, (number) -> (), TextLabel)
	local color: Color3 = props.Color or C.Good
	local glass = props.Glass == true
	local track = Kit.new("Frame", {
		Name = props.Name or "Progress",
		BackgroundColor3 = props.TrackColor or (if glass then C.Ink else C.Well),
		BackgroundTransparency = if glass then G.Inset - 0.2 else 0,
		BorderSizePixel = 0,
		Size = props.Size or UDim2.new(1, 0, 0, 20),
		Position = props.Position or UDim2.new(),
		AnchorPoint = props.AnchorPoint or Vector2.zero,
		LayoutOrder = props.LayoutOrder or 0,
		ClipsDescendants = false,
		Parent = parent,
	})
	Kit.round(track)
	Kit.new("UIStroke", {
		Thickness = 1.5,
		Color = if glass then G.Edge else C.Edge,
		Transparency = if glass then 0.6 else 0.15,
		Parent = track,
	})
	local fill = Kit.new("Frame", {
		Name = "Fill",
		BackgroundColor3 = WHITE,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(0, 1),
		Parent = track,
	})
	Kit.round(fill)
	Kit.gradient(fill, Kit.lighten(color, 0.25), color, 90)
	local gloss = Kit.new("Frame", {
		Name = "Gloss",
		BackgroundColor3 = WHITE,
		BackgroundTransparency = 0.5,
		BorderSizePixel = 0,
		Size = UDim2.new(1, -10, 0, 2),
		Position = UDim2.fromOffset(5, 2),
		Parent = fill,
	})
	Kit.round(gloss)
	local label = Kit.text(track, {
		Name = "Label",
		Text = props.Text or "",
		Font = props.Font or F.UI,
		TextSize = props.TextSize or Kit.TEXT.Small,
		Size = UDim2.fromScale(1, 1),
		ZIndex = 3,
		StrokeThickness = 2,
	})
	local minVisible = props.MinFill or 0.06
	local function set(ratio: number, instant: boolean?)
		local r = math.clamp(ratio, 0, 1)
		fill.Visible = r > 0
		local target = UDim2.fromScale(math.max(r, minVisible), 1)
		if instant then
			fill.Size = target
		else
			Kit.tween(fill, 0.4, { Size = target }, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
		end
	end
	return track, set, label
end

-- On/off switch: a dark glass track that turns solid mint when on, white knob
-- that springs across. props.Large: a 70x32 track with a 14 px ON/OFF label (else
-- 56x30 with a 10 px label). Returns the hit button and a setter (value, locked?).
local SWITCH_OFF = G.Inset - 0.25
function Kit.switch(parent: Instance, props: { [string]: any }, onToggle: () -> ()): (TextButton, (boolean, boolean?) -> ())
	local large = props.Large == true
	local w, h = if large then 70 else 56, if large then 32 else 30
	local button = Kit.new("TextButton", {
		Name = props.Name or "Switch",
		AutoButtonColor = false,
		BackgroundColor3 = C.Ink,
		BackgroundTransparency = SWITCH_OFF,
		Text = "",
		Size = UDim2.fromOffset(w, h),
		Position = props.Position or UDim2.new(),
		AnchorPoint = props.AnchorPoint or Vector2.zero,
		LayoutOrder = props.LayoutOrder or 0,
		Parent = parent,
	})
	Kit.round(button)
	local edge = Kit.new("UIStroke", { Thickness = 1.5, Color = G.Edge, Transparency = 0.6, Parent = button })
	local stateLabel = Kit.text(button, {
		Name = "State",
		Text = "",
		Font = F.UI,
		TextSize = if large then Kit.TEXT.Small else 10,
		TextColor3 = C.Text,
		Size = UDim2.new(1, -h, 1, 0),
		Position = UDim2.fromOffset(0, 0),
		StrokeThickness = 0,
	})
	local lockIcon = Kit.icon(button, "Lock", 14, C.TextDim, {
		Name = "LockIcon",
		Position = UDim2.new(0, h, 0.5, 0),
		AnchorPoint = Vector2.new(0, 0.5),
	})
	lockIcon.Visible = false
	local knob = Kit.new("Frame", {
		Name = "Knob",
		BackgroundColor3 = WHITE,
		Size = UDim2.fromOffset(h - 8, h - 8),
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 4, 0.5, 0),
		Parent = button,
	})
	Kit.round(knob)
	Kit.gradient(knob, WHITE, Color3.fromRGB(218, 226, 246))
	Kit.shadow(knob, math.floor((h - 8) / 2), 0.3)
	Kit.bouncy(button, 1.03)
	local locked = false
	button.Activated:Connect(function()
		Kit.sound(if locked then "Error" else "Toggle")
		onToggle()
	end)
	local function set(value: boolean, isLocked: boolean?)
		locked = isLocked == true
		lockIcon.Visible = locked
		if locked then
			Kit.tween(button, 0.18, { BackgroundColor3 = C.Ink, BackgroundTransparency = SWITCH_OFF })
			edge.Color = G.Edge
			edge.Transparency = 0.6
			stateLabel.Text = ""
			Kit.tween(knob, 0.22, { Position = UDim2.new(0, 4, 0.5, 0) }, Enum.EasingStyle.Back)
			return
		end
		Kit.tween(button, 0.18, {
			BackgroundColor3 = if value then C.Cash else C.Ink,
			BackgroundTransparency = if value then 0 else SWITCH_OFF,
		})
		edge.Color = if value then C.CashDeep else G.Edge
		edge.Transparency = if value then 0 else 0.6
		stateLabel.Text = if value then "ON" else "OFF"
		stateLabel.TextColor3 = if value then C.GoldInk else C.TextDim
		stateLabel.Position = if value then UDim2.fromOffset(4, 0) else UDim2.fromOffset(h - 4, 0)
		Kit.tween(
			knob,
			0.22,
			{ Position = if value then UDim2.new(1, -(h - 4), 0.5, 0) else UDim2.new(0, 4, 0.5, 0) },
			Enum.EasingStyle.Back
		)
	end
	set(false)
	return button, set
end

--[[
	Segmented tab bar: a dark glass pill. The selected tab is a solid, bright
	moulded pill in the accent colour that glides between slots. props:
	  Items = { { key = "Passes", text = "Passes", icon = "Star"? }, ... }
	  Color (indicator), Size, Position, AnchorPoint, LayoutOrder, TextSize
	Returns the bar and a `select(key)` function; `onSelect(key)` fires on change.
]]
function Kit.tabs(parent: Instance, props: { [string]: any }, onSelect: (string) -> ()): (Frame, (string) -> ())
	local items: { { key: string, text: string, icon: string? } } = props.Items
	local color: Color3 = props.Color or C.Gold
	local bar = Kit.well(parent, {
		Name = props.Name or "Tabs",
		Size = props.Size or UDim2.new(1, 0, 0, 40),
		Position = props.Position or UDim2.new(),
		AnchorPoint = props.AnchorPoint or Vector2.zero,
		LayoutOrder = props.LayoutOrder or 0,
		Radius = 20,
		Glass = true,
	})
	local n = #items
	local function slot(i: number): (UDim2, UDim2)
		return UDim2.new((i - 1) / n, 4, 0, 4), UDim2.new(1 / n, -8, 1, -8)
	end
	local indicatorPos, indicatorSize = slot(1)
	local indicator = Kit.new("Frame", {
		Name = "Indicator",
		BackgroundColor3 = WHITE,
		Position = indicatorPos,
		Size = indicatorSize,
		ZIndex = 2,
		Parent = bar,
	})
	Kit.round(indicator)
	Kit.gradient(indicator, Kit.lighten(color, 0.24), color)
	Kit.new("UIStroke", { Thickness = 1.5, Color = Kit.lip(color), Parent = indicator })
	highlight(indicator, 12, 0.4).ZIndex = 2
	local labels: { [string]: TextLabel } = {}
	local selected: string? = nil
	local function selectTab(key: string)
		local index = 1
		for i, item in items do
			if item.key == key then
				index = i
			end
		end
		local pos, size = slot(index)
		Kit.tween(indicator, 0.24, { Position = pos, Size = size }, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
		for k, label in labels do
			Kit.tween(label, 0.18, { TextColor3 = if k == key then Kit.inkOn(color) else C.Text })
		end
		if selected ~= key then
			selected = key
			onSelect(key)
		end
	end
	for i, item in items do
		local pos, size = slot(i)
		local hit = Kit.new("TextButton", {
			Name = item.key,
			AutoButtonColor = false,
			BackgroundTransparency = 1,
			Text = "",
			Position = pos,
			Size = size,
			ZIndex = 3,
			Parent = bar,
		})
		local label = Kit.text(hit, {
			Name = "Label",
			Text = string.upper(item.text),
			Font = F.UI,
			TextSize = props.TextSize or Kit.TEXT.Small,
			TextColor3 = C.Text,
			TextWrapped = false,
			ZIndex = 3,
			StrokeThickness = 0,
		})
		labels[item.key] = label
		Kit.bouncy(hit, 1)
		hit.Activated:Connect(function()
			if selected ~= item.key then
				Kit.sound("Click")
				selectTab(item.key)
			end
		end)
	end
	if items[1] then
		selectTab(items[1].key)
	end
	return bar, selectTab
end

-- Builds a ViewportFrame showing a unit tier (`silhouette`: an undiscovered tier,
-- drawn as one soft mid-blue shape).
local SILHOUETTE = Color3.fromRGB(122, 146, 220)
function Kit.unitViewport(parent: Instance, tier: number, props: { [string]: any }, silhouette: boolean?): ViewportFrame
	local look = Theme.Tiers[tier].Look
	local viewport = Kit.new("ViewportFrame", {
		BackgroundTransparency = 1,
		Size = props.Size or UDim2.fromScale(1, 1),
		Position = props.Position or UDim2.new(),
		AnchorPoint = props.AnchorPoint or Vector2.zero,
		Ambient = Color3.fromRGB(200, 200, 210),
		LightColor = Color3.new(1, 1, 1),
		LightDirection = Vector3.new(-0.5, -1, 0.6),
		Parent = parent,
	})
	-- Tagged so tooling (preview renderer) can identify what the viewport shows.
	viewport:SetAttribute("Tier", tier)
	viewport:SetAttribute("Silhouette", silhouette == true)
	local model = CharacterFactory.build(look, Theme.Tiers[tier].Name)
	if silhouette then
		-- A soft mid-blue shape (lighter than the tile's ink, never black), lit flat.
		CharacterFactory.silhouette(model)
		for _, part in model:GetDescendants() do
			if part:IsA("BasePart") and part.Transparency < 1 then
				part.Color = SILHOUETTE
			end
		end
		viewport.Ambient = Color3.new(1, 1, 1)
		viewport.LightColor = Color3.fromRGB(70, 70, 80)
		viewport.ImageTransparency = 0.15
	end
	model.Parent = viewport
	Animator.attach(model)
	local height = CharacterFactory.height(look)
	local camera = Instance.new("Camera")
	camera.FieldOfView = 40
	local focus = Vector3.new(0, height * 0.5, 0)
	camera.CFrame = CFrame.lookAt(Vector3.new(height * 0.35, height * 0.62, -height * 1.75), focus)
	camera.Parent = viewport
	viewport.CurrentCamera = camera
	return viewport
end

-- Windows ------------------------------------------------------------------------------

-- Scene blur while any window or modal is open: one shared BlurEffect,
-- reference counted (every opener calls it once with true and once with false),
-- so nested windows and popups ease it in and out once.
-- `light` openers (the discovery reveal) ask for the lighter frost; any window wins.
local blurCount = 0
local blurLight = 0
local blur: BlurEffect? = nil
function Kit.setBlur(on: boolean, light: boolean?)
	local step = if on then 1 else -1
	if light then
		blurLight = math.max(0, blurLight + step)
	else
		blurCount = math.max(0, blurCount + step)
	end
	local size = if blurCount > 0 then G.Blur elseif blurLight > 0 then G.BlurLight else 0
	if size > 0 then
		if not blur then
			local effect = Instance.new("BlurEffect")
			effect.Name = "UiBlur"
			effect.Size = 0
			effect.Parent = Lighting
			blur = effect
		end
		Kit.tween(blur :: BlurEffect, 0.22, { Size = size })
	elseif blur then
		Kit.tween(blur :: BlurEffect, 0.18, { Size = 0 })
	end
end

-- Roblox's top bar (the preview has no layout, so its safe area is worked out by hand).
local TOP_BAR_PX = 58

--[[
	Visible design area of a ScreenGui: its AbsoluteSize (already inside the
	top bar and safe-area insets) divided by the screen's own UIScale. nil when
	the engine cannot tell (the Lune preview has no layout).
]]
function Kit.designArea(screen: Instance): Vector2?
	local ok, absolute = pcall(function()
		return (screen :: any).AbsoluteSize
	end)
	if not ok or typeof(absolute) ~= "Vector2" or absolute.X < 1 or absolute.Y < 1 then
		if not PREVIEW then
			return nil
		end
		-- The preview exporter patches the viewport size into this expression.
		local view = Workspace.CurrentCamera.ViewportSize
		absolute = Vector2.new(view.X, view.Y - TOP_BAR_PX)
	end
	local uiScale = screen:FindFirstChildOfClass("UIScale")
	local scale = if uiScale and uiScale.Scale > 0 then uiScale.Scale else 1
	return absolute / scale
end

--[[
	Kit.fit(holder, screen, design, minSize?, onResize?): keeps a centred
	holder inside G.Fit (92%, touch G.FitTouch 94%) of the screen's visible
	design area. The holder first narrows / shortens toward `minSize` (so its
	content can reflow), then shrinks as a whole with its own UIScale ("Fit").
	On a phone (touch + Compact) it goes on toward `minSize` so the UIScale can
	grow past 1 (up to G.FitGrow): the window fills the safe area and its text
	grows with it. Re-fits whenever the
	viewport or the screen's UIScale changes. `onResize(size)` runs with the
	holder's design size after every change (and once at the start). The holder
	must not be animated with Kit.appear (a gui honours one UIScale): animate a
	child instead.
]]
function Kit.fit(holder: GuiObject, screen: Instance, design: Vector2, minSize: Vector2?, onResize: ((Vector2) -> ())?)
	local fitScale = Kit.new("UIScale", { Name = "Fit", Parent = holder })
	local low = minSize or design
	local minW, minH = math.min(low.X, design.X), math.min(low.Y, design.Y)
	local current: Vector2? = nil
	local function apply()
		local w, h, s = design.X, design.Y, 1
		local area = Kit.designArea(screen)
		if area then
			local share = if Kit.touch then G.FitTouch else G.Fit
			local maxW, maxH = area.X * share, area.Y * share
			w = math.floor(math.clamp(maxW, minW, design.X))
			h = math.floor(math.clamp(maxH, minH, design.Y))
			s = math.min(1, maxW / w, maxH / h)
			if Kit.touch and screen:GetAttribute("Compact") == true then
				local grow = math.min(G.FitGrow, maxW / minW, maxH / minH)
				if grow > s then
					w = math.floor(math.clamp(maxW / grow, minW, design.X))
					h = math.floor(math.clamp(maxH / grow, minH, design.Y))
					-- Never past the grow share: a small card (a dialog) stays a card.
					s = math.min(grow, maxW / w, maxH / h)
				end
			end
		end
		fitScale.Scale = s
		local size = Vector2.new(w, h)
		if size ~= current then
			current = size
			holder.Size = UDim2.fromOffset(w, h)
			if onResize then
				onResize(size)
			end
		end
	end
	apply()
	pcall(function()
		local connections: { RBXScriptConnection } = {}
		table.insert(connections, (screen :: any):GetPropertyChangedSignal("AbsoluteSize"):Connect(apply))
		table.insert(connections, screen:GetAttributeChangedSignal("Compact"):Connect(apply))
		local uiScale = screen:FindFirstChildOfClass("UIScale")
		if uiScale then
			table.insert(connections, uiScale:GetPropertyChangedSignal("Scale"):Connect(apply))
		end
		table.insert(
			connections,
			holder.AncestryChanged:Connect(function()
				if not holder:IsDescendantOf(game) then
					for _, connection in connections do
						connection:Disconnect()
					end
				end
			end)
		)
	end)
end

--[[
	WindowOpen contract: the ScreenGui attribute WindowOpen is true while any
	window or blocking modal is up, so the HUD can fade back under the dim.
	`key` names the opener; the flag clears once every opener has closed.
]]
local openers: { [Instance]: { [string]: boolean } } = setmetatable({}, { __mode = "k" }) :: any
local openListeners: { (boolean) -> () } = {}
local openWatched: { [Instance]: string } = setmetatable({}, { __mode = "k" }) :: any
function Kit.markOpen(screen: Instance, key: string, on: boolean, owner: Instance?)
	local set = openers[screen] or {}
	openers[screen] = set
	set[key] = if on then true else nil
	local any = next(set) ~= nil
	if (screen:GetAttribute("WindowOpen") == true) ~= any then
		screen:SetAttribute("WindowOpen", any)
		for _, fn in openListeners do
			fn(any)
		end
	end
	Kit.hidePlayerList("window", any)
	Kit.hideTouchControls("window", any)
	-- `owner` (the opener's own gui) destroyed without closing: the count is given back,
	-- so the HUD and the touch controls never stay hidden behind a window that is gone.
	if on and owner and not PREVIEW and openWatched[owner] ~= key then
		-- Once per owner: a window's holder opens many times under the same key.
		openWatched[owner] = key
		pcall(function()
			local connection: RBXScriptConnection
			connection = owner.AncestryChanged:Connect(function()
				if not owner:IsDescendantOf(game) then
					connection:Disconnect()
					if set[key] then
						Kit.markOpen(screen, key, false)
					end
				end
			end)
		end)
	end
end

-- Kit.onWindowOpen(fn): fn(open) runs when the first window or modal opens and when the
-- last one closes (the one reference count behind WindowOpen). The HUD hides on it, so no
-- window, popup or reveal has to remember the HUD.
function Kit.onWindowOpen(fn: (boolean) -> ())
	table.insert(openListeners, fn)
end

--[[
	Roblox's thumbstick and jump button sit over the lower corners of a phone screen: on a
	window's footer, its CLAIM / GOT IT / buy buttons and the answers of a dialog. They are
	hidden (GuiService.TouchControlsEnabled) while any `reason` is on ("window": the one
	count behind WindowOpen) and the input is touch, and come back when the last reason
	goes. The wanted state is applied again when the input mode changes and when the
	character respawns, so a window closed, destroyed or left open across a respawn never
	leaves the player without controls.
]]
local touchReasons: { [string]: boolean } = {}
local touchHidden = false
local function applyTouchControls(force: boolean?)
	if PREVIEW then
		return
	end
	local hide = Kit.touch and next(touchReasons) ~= nil
	if hide == touchHidden and not force then
		return
	end
	touchHidden = hide
	pcall(function()
		GuiService.TouchControlsEnabled = not hide
	end)
end
function Kit.hideTouchControls(reason: string, on: boolean)
	if on then
		touchReasons[reason] = true
	else
		touchReasons[reason] = nil
	end
	applyTouchControls()
end
if not PREVIEW then
	table.insert(inputListeners, function()
		applyTouchControls()
	end)
	task.spawn(function()
		local player = game:GetService("Players").LocalPlayer
		if player then
			player.CharacterAdded:Connect(function()
				applyTouchControls(true)
			end)
		end
	end)
end

--[[
	Roblox's default player list (top-right leaderstats) covers the window
	header chips and the held-crate panel, so it is hidden while any of them is
	up. `reason` names the caller ("window", "crate", "intro"); the list stays
	hidden while any reason is on and goes back to the state it had before the
	first reason once every reason is off. Each call re-applies the wanted
	state, so a caller that restores the list on its own (the intro) is
	overridden while other reasons remain. CoreGui calls can fail early in a
	session: a failed set is retried for a few seconds.
]]
local listReasons: { [string]: boolean } = {}
local listBase: boolean? = nil
local listToken = 0
function Kit.hidePlayerList(reason: string, on: boolean)
	if on then
		listReasons[reason] = true
	else
		listReasons[reason] = nil
	end
	if PREVIEW then
		return
	end
	local hide = next(listReasons) ~= nil
	if hide and listBase == nil then
		-- The intro hides the list itself and puts back what it found, so while
		-- it plays the list's own state is not the player's.
		local player = game:GetService("Players").LocalPlayer
		local ok, enabled = pcall(function()
			return game:GetService("StarterGui"):GetCoreGuiEnabled(Enum.CoreGuiType.PlayerList)
		end)
		listBase = if player and player:GetAttribute("IntroPlaying") == true then true elseif ok then enabled else true
	elseif not hide and listBase == nil then
		return
	end
	local want = if hide then false else listBase == true
	if not hide then
		listBase = nil
	end
	listToken += 1
	local token = listToken
	task.spawn(function()
		for _ = 1, 12 do
			if token ~= listToken then
				return
			end
			local ok = pcall(function()
				game:GetService("StarterGui"):SetCoreGuiEnabled(Enum.CoreGuiType.PlayerList, want)
			end)
			if ok then
				return
			end
			task.wait(0.5)
		end
	end)
end

export type Window = {
	frame: Frame,
	content: Frame,
	header: Frame,
	-- `origin` (screen pixels, the centre of the button that opened it): the window
	-- scales up from that point and closes back into it; nil pops at the centre.
	setOpen: (boolean, Vector2?) -> (),
	isOpen: () -> boolean,
	onOpen: BindableEvent,
	onClose: BindableEvent,
	-- Current design size of the window (after narrowing to fit the screen).
	size: () -> Vector2,
	-- Fires with the new design size when the window narrows or widens.
	onResize: BindableEvent,
	-- Gamepad: re-selects the first button in content (call after re-rendering it).
	focus: () -> (),
}

--[[
	Standard window: a glass pane (Kit.panel Glass = "body": translucent blue
	tint, light edge, soft halo) the blurred world shows through. No title bar:
	the icon and the chunky outlined title sit straight on the glass over a thin
	divider line that starts in the window's accent `color`. Coral close button;
	the content area is clear, so rows and cards (Kit.glass, Kit.panel Glass)
	sit on the pane itself. Opens with a quick pop (Kit.appear: scale + fade,
	0.2 s Back) and closes faster (Kit.disappear, 0.11 s); input is live from
	the first frame. Blurs the scene while open and sets the WindowOpen
	attribute; the caller owns the dimming backdrop (Kit.backdrop +
	Kit.fadeBackdrop at Kit.GLASS_DIM).

	The pane ("Panel") sits in a centred holder named `name` that Kit.fit
	keeps inside the visible area: it narrows toward `minSize` first (content
	built with scale sizes reflows; listen to onResize for column counts), then
	scales down as a whole. Header children: Chip (the icon), Title, Shade (the
	divider), Close.
]]
Kit.GLASS_DIM = 1 - G.Dim
function Kit.window(screen: ScreenGui, name: string, title: string, icon: string, color: Color3, size: Vector2, minSize: Vector2?): Window
	local holder = Kit.new("Frame", {
		Name = name,
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(size.X, size.Y),
		Position = UDim2.new(0.5, 0, 0.5, 4),
		AnchorPoint = Vector2.new(0.5, 0.5),
		Visible = false,
		ZIndex = 10,
		Parent = screen,
	})
	local frame = Kit.panel(holder, {
		Name = "Panel",
		Glass = "body",
		Size = UDim2.fromScale(1, 1),
		Position = UDim2.fromScale(0.5, 0.5),
		AnchorPoint = Vector2.new(0.5, 0.5),
		Visible = false,
	})
	frame.ZIndex = 10
	scaleOf(frame)

	-- Header row: clear, so the title reads as HUD text on the glass.
	local header = Kit.new("Frame", {
		Name = "Header",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 56),
		ZIndex = 2,
		Parent = frame,
	})
	-- Divider: a thin line under the row, the accent colour running out into clear glass.
	local shade = Kit.new("Frame", {
		Name = "Shade",
		BackgroundColor3 = WHITE,
		BorderSizePixel = 0,
		Size = UDim2.new(1, -28, 0, 2),
		Position = UDim2.new(0, 14, 1, 3),
		ZIndex = 2,
		Parent = header,
	})
	Kit.round(shade)
	Kit.new("UIGradient", {
		Color = ColorSequence.new(Kit.lighten(color, 0.2), WHITE),
		Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.05),
			NumberSequenceKeypoint.new(0.45, 0.55),
			NumberSequenceKeypoint.new(1, 0.9),
		}),
		Parent = shade,
	})

	-- The icon, straight on the glass with a soft shadow (no chip behind it).
	local chip = Kit.new("Frame", {
		Name = "Chip",
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(42, 42),
		Position = UDim2.new(0, 14, 0.5, 1),
		AnchorPoint = Vector2.new(0, 0.5),
		ZIndex = 3,
		Parent = header,
	})
	local iconName = Kit.iconName(icon)
	if iconName then
		Kit.hudIcon(chip, iconName, 38, Kit.lighten(color, 0.15), {
			Name = "Icon",
			Position = UDim2.fromScale(0.5, 0.5),
			AnchorPoint = Vector2.new(0.5, 0.5),
			ZIndex = 4,
		})
	else
		Kit.text(chip, { Name = "Icon", Text = icon, TextSize = 30, Size = UDim2.fromScale(1, 1), StrokeThickness = 0, ZIndex = 4 })
	end

	Kit.hudText(header, {
		Name = "Title",
		Text = string.upper(title),
		TextSize = Kit.TEXT.H1 + 2,
		TextColor3 = C.Text,
		StrokeColor = G.TextInk,
		Size = UDim2.new(1, -134, 1, 0),
		Position = UDim2.fromOffset(66, 2),
		TextXAlignment = Enum.TextXAlignment.Left,
		ZIndex = 3,
	})

	-- Content: clear glass (the pane is the surface), same box and padding as ever.
	local content = Kit.new("Frame", {
		Name = "Content",
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Size = UDim2.new(1, -24, 1, -84),
		Position = UDim2.fromOffset(12, 72),
		Parent = frame,
	})
	Kit.padding(content, 10)

	-- The D-pad never leaves an open window.
	Kit.confine(holder)

	local open = false
	local onOpen = Instance.new("BindableEvent")
	local onClose = Instance.new("BindableEvent")
	local onResize = Instance.new("BindableEvent")
	local current = size
	Kit.fit(holder, screen, size, minSize, function(fitted: Vector2)
		current = fitted
		onResize:Fire(fitted)
	end)
	-- Where the window grew from: the opening button's offset from the window centre, in
	-- the pane's own design pixels.
	local CENTRE = UDim2.fromScale(0.5, 0.5)
	local from: UDim2? = nil
	local function originOf(point: Vector2?): UDim2?
		if not point then
			return nil
		end
		local ok, centre = pcall(function()
			return screen.AbsolutePosition + screen.AbsoluteSize / 2
		end)
		if not ok or typeof(centre) ~= "Vector2" then
			return nil
		end
		local uiScale = screen:FindFirstChildOfClass("UIScale")
		local fitScale = holder:FindFirstChild("Fit")
		local scale = (if uiScale then uiScale.Scale else 1) * (if fitScale and fitScale:IsA("UIScale") then fitScale.Scale else 1)
		local offset = (point - centre) / math.max(scale, 0.01)
		return UDim2.new(0.5, offset.X, 0.5, offset.Y)
	end
	local function setOpen(value: boolean, origin: Vector2?)
		if value == open then
			return
		end
		open = value
		Kit.markOpen(screen, "Window:" .. name, value, holder)
		if value then
			holder.Visible = true
			from = originOf(origin)
			if from then
				frame.Position = from
				Kit.tween(frame, 0.24, { Position = CENTRE }, Enum.EasingStyle.Quint)
				Kit.appear(frame, { from = G.OriginScale, time = 0.24 })
			else
				frame.Position = CENTRE
				Kit.appear(frame, { from = 0.9, time = 0.2 })
			end
			Kit.setBlur(true)
			Kit.sound("Open")
			onOpen:Fire()
			-- Gamepad: the selection lands on the first button once the content is built.
			task.defer(function()
				if open then
					Kit.focus(content)
				end
			end)
		else
			Kit.unfocus(holder)
			if from then
				Kit.tween(frame, 0.16, { Position = from }, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
			end
			Kit.disappear(frame, {
				time = if from then 0.16 else 0.11,
				to = if from then G.OriginScale else nil,
				onDone = function()
					holder.Visible = false
					frame.Position = CENTRE
				end,
			})
			Kit.setBlur(false)
			onClose:Fire()
		end
	end
	-- Touch: a 44 px button under a pad that is 44 screen px on the smallest phone scale.
	local closeSize = if Kit.touch then 44 else 40
	local close = Kit.button(header, {
		Name = "Close",
		Icon = "Close",
		IconColor = C.Text,
		Color = C.Danger,
		Size = UDim2.fromOffset(closeSize, closeSize),
		Position = UDim2.new(1, -12, 0.5, 1),
		AnchorPoint = Vector2.new(1, 0.5),
		Radius = closeSize // 2,
		Depth = 4,
		Sound = "Close",
		ZIndex = 3,
	}, function()
		setOpen(false)
	end)
	local closeIcon = (Kit.buttonFace(close) :: Frame):FindFirstChild("Icon") :: Frame
	closeIcon.Position = UDim2.fromScale(0.5, 0.5)
	closeIcon.AnchorPoint = Vector2.new(0.5, 0.5)
	closeIcon.Size = UDim2.fromOffset(16, 16)
	Kit.hitArea(close, if Kit.touch then 72 else 52, function()
		Kit.sound("Close")
		setOpen(false)
	end)

	return {
		frame = frame,
		content = content,
		header = header,
		setOpen = setOpen,
		isOpen = function()
			return open
		end,
		onOpen = onOpen,
		onClose = onClose,
		size = function()
			return current
		end,
		onResize = onResize,
		focus = function()
			if open then
				Kit.focus(content)
			end
		end,
	}
end

function Kit.scrolling(parent: Instance, props: { [string]: any }?): ScrollingFrame
	local p = props or {}
	return Kit.new("ScrollingFrame", {
		Name = p.Name or "Scroll",
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Size = p.Size or UDim2.fromScale(1, 1),
		Position = p.Position or UDim2.new(),
		ScrollBarThickness = 4,
		ScrollBarImageColor3 = WHITE,
		ScrollBarImageTransparency = 0.45,
		VerticalScrollBarInset = Enum.ScrollBarInset.ScrollBar,
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		CanvasSize = UDim2.new(),
		ScrollingDirection = Enum.ScrollingDirection.Y,
		Parent = parent,
	})
end

-- Confetti burst from a point inside `parent` (scale position). Pieces shoot
-- outward and upward, then fall and fade. Cleans itself up. With the Blender
-- sprites, pieces are curled confetti tinted with `Colors` plus a few yellow
-- star pops; without them, rounded colour chips. At most CONFETTI_MAX pieces.
local CONFETTI_MAX = 28
local CONFETTI_IMAGE = Sprites.image("Confetti")
local STAR_IMAGE = Sprites.image("StarPop")
function Kit.confetti(parent: Instance, options: { [string]: any }?)
	local opts = options or {}
	local W = Theme.World
	local colors = opts.Colors or { W.Sunny, W.Pink, W.Mint, W.Blue, W.Grape, W.Orange, W.Coral }
	local origin: UDim2 = opts.Origin or UDim2.fromScale(0.5, 0.4)
	local count = math.min(opts.Count or 24, CONFETTI_MAX)
	local zindex = opts.ZIndex or 45
	local power = opts.Power or 1
	for i = 1, count do
		local angle = math.rad(math.random(200, 340))
		local speed = math.random(160, 380) * power
		local piece: GuiObject
		local fadeProp = "BackgroundTransparency"
		if CONFETTI_IMAGE then
			local star = STAR_IMAGE ~= nil and i % 7 == 0
			local side = if star then math.random(22, 28) else math.random(16, 24)
			piece = Kit.new("ImageLabel", {
				Name = "Confetti",
				BackgroundTransparency = 1,
				Image = if star then STAR_IMAGE else CONFETTI_IMAGE,
				ImageColor3 = if star then Color3.new(1, 1, 1) else colors[(i % #colors) + 1],
				ScaleType = Enum.ScaleType.Fit,
				Size = UDim2.fromOffset(side, side),
				Position = origin,
				AnchorPoint = Vector2.new(0.5, 0.5),
				Rotation = math.random(0, 360),
				ZIndex = zindex,
				Parent = parent,
			})
			fadeProp = "ImageTransparency"
		else
			piece = Kit.new("Frame", {
				Name = "Confetti",
				BackgroundColor3 = colors[(i % #colors) + 1],
				Size = UDim2.fromOffset(math.random(8, 14), math.random(14, 22)),
				Position = origin,
				AnchorPoint = Vector2.new(0.5, 0.5),
				Rotation = math.random(0, 360),
				ZIndex = zindex,
				Parent = parent,
			})
			Kit.corner(piece, 3)
		end
		local apex = origin + UDim2.fromOffset(math.cos(angle) * speed, math.sin(angle) * speed)
		local burst = 0.3 + math.random() * 0.15
		Kit.tween(piece, burst, { Position = apex, Rotation = piece.Rotation + math.random(-180, 180) }, Enum.EasingStyle.Quad)
		task.delay(burst, function()
			if not piece.Parent then
				return
			end
			local fall = 1 + math.random() * 0.5
			Kit.tween(piece, fall, {
				Position = apex + UDim2.fromOffset(math.random(-50, 50), math.random(220, 380)),
				Rotation = piece.Rotation + math.random(-360, 360),
				[fadeProp] = 1,
			}, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
			task.delay(fall + 0.05, function()
				piece:Destroy()
			end)
		end)
	end
end

-- Full-screen black dimmer (G.DimColor); returns the (clickable) frame. Starts hidden;
-- show and hide it with Kit.fadeBackdrop.
function Kit.backdrop(parent: Instance, zindex: number, onClick: (() -> ())?): TextButton
	local dim = Kit.new("TextButton", {
		Name = "Backdrop",
		AutoButtonColor = false,
		Text = "",
		BackgroundColor3 = G.DimColor,
		BackgroundTransparency = 1,
		Size = UDim2.new(2, 0, 2, 0),
		Position = UDim2.fromScale(-0.5, -0.5),
		ZIndex = zindex,
		Visible = false,
		Selectable = false,
		Parent = parent,
	})
	if onClick then
		dim.Activated:Connect(onClick)
	end
	return dim
end

-- Eases a backdrop in (to `opacity`, default Kit.GLASS_DIM) or out, then hides it.
local fadeTokens: { [Instance]: number } = setmetatable({}, { __mode = "k" }) :: any
function Kit.fadeBackdrop(dim: GuiObject, show: boolean, opacity: number?)
	local token = (fadeTokens[dim] or 0) + 1
	fadeTokens[dim] = token
	if show then
		if not dim.Visible then
			dim.BackgroundTransparency = 1
		end
		dim.Visible = true
		Kit.tween(dim, 0.22, { BackgroundTransparency = 1 - (opacity or Kit.GLASS_DIM) }, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	else
		Kit.tween(dim, 0.16, { BackgroundTransparency = 1 }, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
		task.delay(0.17, function()
			if fadeTokens[dim] == token then
				dim.Visible = false
			end
		end)
	end
end

-- HUD text drawn straight over the world: bold display font, white, with a solid
-- Ink outline (2.5 px by default, prop StrokeThickness overrides) so it reads on
-- sky, sand or a busy plot alike.
function Kit.hudText(parent: Instance, props: { [string]: any }): TextLabel
	local thickness = props.StrokeThickness or 2.5
	local strokeColor: Color3? = props.StrokeColor
	props.StrokeColor = nil
	props.Font = props.Font or F.Display
	props.TextColor3 = props.TextColor3 or Color3.new(1, 1, 1)
	props.TextWrapped = if props.TextWrapped == nil then false else props.TextWrapped
	props.StrokeThickness = 0
	local label = Kit.text(parent, props)
	local stroke = Kit.textStroke(label, thickness, 0)
	stroke.Name = "Outline"
	if strokeColor then
		stroke.Color = strokeColor
	end
	return label
end

-- A HUD icon with a soft drop shadow under it (a darkened copy 3 px lower), for
-- icons that sit straight over the world with no panel behind them.
function Kit.hudIcon(parent: Instance, name: string, size: number, color: Color3?, props: { [string]: any }?): Frame
	local p = props or {}
	local icon = Kit.icon(parent, name, size, color, p)
	local shade = Kit.icon(icon, name, size, C.Ink, { Name = "Shade", Position = UDim2.fromOffset(0, 3) })
	-- Follows the icon when callers resize it (e.g. Size = fromScale(1, 1) on a button).
	shade.Size = UDim2.fromScale(1, 1)
	shade.ZIndex = math.max(icon.ZIndex - 1, 0)
	for _, part in shade:GetDescendants() do
		if part:IsA("ImageLabel") then
			part.ImageColor3 = C.Ink
			part.ImageTransparency = 0.6
			part.ZIndex = shade.ZIndex
		elseif part:IsA("Frame") then
			part.BackgroundColor3 = C.Ink
			part.BackgroundTransparency = math.max(part.BackgroundTransparency, 0.6)
			part.ZIndex = shade.ZIndex
		elseif part:IsA("UIStroke") then
			part.Enabled = false
		end
	end
	return icon
end

return Kit
