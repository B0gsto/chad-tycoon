--[[
	Kit: the design system for the code-built UI.

	Everything on screen is made from these pieces so the game looks the same
	everywhere: rounded panels with a heavy outline, chunky 3D buttons (a darker
	base the face presses down into), pills, badges, progress bars, switches and
	modal windows.

	Tokens
	  Kit.TEXT    type scale (TextSize in design pixels; the ScreenGui UIScale
	              scales the whole 1280x720 design to the device)
	  Kit.RADIUS  corner radii
	  Kit.touch   true on touch-first devices (bigger targets)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local Theme = require(ReplicatedStorage:WaitForChild("Theme"))
local CharacterFactory = require(ReplicatedStorage.Shared.CharacterFactory)

local Kit = {}
Kit.Theme = Theme
Kit.C = Theme.Colors

Kit.TEXT = {
	Hero = 44,
	H1 = 32,
	H2 = 26,
	H3 = 21,
	Body = 18,
	Small = 15,
	Tiny = 13,
}

Kit.RADIUS = {
	S = 8,
	M = 12,
	L = 16,
	XL = 22,
}

Kit.touch = false
pcall(function()
	Kit.touch = UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled
end)

local WHITE = Color3.new(1, 1, 1)

-- Sounds are injected by Main so Kit stays free of client state.
local soundPlayer: ((string) -> ())? = nil
function Kit.setSoundPlayer(fn: (string) -> ())
	soundPlayer = fn
end
function Kit.setClickSound(fn: () -> ())
	soundPlayer = function(name: string)
		if name == "Click" then
			fn()
		end
	end
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

function Kit.corner(parent: Instance, radius: number?): UICorner
	return Kit.new("UICorner", { CornerRadius = UDim.new(0, radius or Kit.RADIUS.M), Parent = parent })
end

function Kit.round(parent: Instance): UICorner
	return Kit.new("UICorner", { CornerRadius = UDim.new(1, 0), Parent = parent })
end

function Kit.stroke(parent: Instance, thickness: number?, color: Color3?): UIStroke
	return Kit.new("UIStroke", {
		Thickness = thickness or 3,
		Color = color or Kit.C.Stroke,
		ApplyStrokeMode = if parent:IsA("TextLabel") or parent:IsA("TextButton")
			then Enum.ApplyStrokeMode.Border
			else Enum.ApplyStrokeMode.Contextual,
		Parent = parent,
	})
end

function Kit.textStroke(parent: Instance, thickness: number?)
	return Kit.new("UIStroke", {
		Thickness = thickness or 2,
		Color = Kit.C.Stroke,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual,
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
	Text. Pass TextSize for a fixed size from the type scale (preferred), or
	leave it out for TextScaled (optionally capped with MaxTextSize).
]]
function Kit.text(parent: Instance, props: { [string]: any }): TextLabel
	local fixed = props.TextSize ~= nil and props.TextScaled ~= true
	local label = Kit.new("TextLabel", {
		BackgroundTransparency = 1,
		Font = Theme.Fonts.Body,
		TextColor3 = Kit.C.Text,
		TextScaled = not fixed,
		TextWrapped = true,
		Size = UDim2.fromScale(1, 1),
		Parent = parent,
	})
	local maxSize = props.MaxTextSize
	local strokeThickness = props.StrokeThickness
	for key, value in props do
		if key ~= "MaxTextSize" and key ~= "StrokeThickness" then
			(label :: any)[key] = value
		end
	end
	if maxSize then
		Kit.new("UITextSizeConstraint", { MaxTextSize = maxSize, MinTextSize = 8, Parent = label })
	end
	if strokeThickness ~= 0 then
		local thickness = strokeThickness or (if fixed then math.clamp(label.TextSize / 12, 1.2, 3) else 2)
		Kit.textStroke(label, thickness)
	end
	return label
end

function Kit.title(parent: Instance, props: { [string]: any }): TextLabel
	props.Font = props.Font or Theme.Fonts.Title
	return Kit.text(parent, props)
end

function Kit.tween(obj: Instance, time: number, props: { [string]: any }, style: Enum.EasingStyle?, direction: Enum.EasingDirection?): Tween
	local tween =
		TweenService:Create(obj, TweenInfo.new(time, style or Enum.EasingStyle.Quad, direction or Enum.EasingDirection.Out), props)
	tween:Play()
	return tween
end

function Kit.lighten(color: Color3, amount: number): Color3
	return color:Lerp(WHITE, amount)
end

function Kit.darken(color: Color3, amount: number): Color3
	return color:Lerp(Color3.new(0, 0, 0), amount)
end

function Kit.hex(color: Color3): string
	return string.format("#%02X%02X%02X", math.floor(color.R * 255 + 0.5), math.floor(color.G * 255 + 0.5), math.floor(color.B * 255 + 0.5))
end

-- Adds a UIScale that grows on hover and squashes on press. Returns the scale.
function Kit.bouncy(button: GuiButton, hover: number?): UIScale
	local scale = Kit.new("UIScale", { Parent = button })
	local up = hover or 1.05
	button.MouseEnter:Connect(function()
		Kit.tween(scale, 0.12, { Scale = up })
	end)
	button.MouseLeave:Connect(function()
		Kit.tween(scale, 0.12, { Scale = 1 })
	end)
	button.MouseButton1Down:Connect(function()
		Kit.tween(scale, 0.08, { Scale = 0.95 })
	end)
	button.MouseButton1Up:Connect(function()
		Kit.tween(scale, 0.14, { Scale = up }, Enum.EasingStyle.Back)
	end)
	return scale
end

-- Buttons ---------------------------------------------------------------------------

type ButtonState = {
	face: Frame,
	base: Frame,
	gradient: UIGradient,
	label: TextLabel,
	icon: TextLabel?,
	color: Color3,
	enabled: boolean,
	depth: number,
}

local buttons: { [Instance]: ButtonState } = setmetatable({}, { __mode = "k" }) :: any

local FACE_IDLE = Color3.fromRGB(236, 236, 236)

local function paintButton(state: ButtonState)
	local color = if state.enabled then state.color else Kit.C.PadDisabled
	state.gradient.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Kit.lighten(color, 0.32)),
		ColorSequenceKeypoint.new(0.5, Kit.lighten(color, 0.08)),
		ColorSequenceKeypoint.new(1, Kit.darken(color, 0.06)),
	})
	state.base.BackgroundColor3 = Kit.darken(color, 0.5)
	state.label.TextTransparency = if state.enabled then 0 else 0.3
	if state.icon then
		state.icon.TextTransparency = if state.enabled then 0 else 0.4
	end
end

--[[
	A chunky 3D button. props:
	  Text, Icon (emoji), Layout ("Inline" | "Stack": icon above text),
	  Color, Size, Position, AnchorPoint, LayoutOrder, Name, ZIndex,
	  Font, TextSize, TextColor, RichText, Radius, Depth, Sound (default "Click")
	Returns the TextButton (the hit area). Recolour/relabel with Kit.setButton,
	enable/disable with Kit.setEnabled.
]]
function Kit.button(parent: Instance, props: { [string]: any }, onClick: (() -> ())?): TextButton
	local color = props.Color or Kit.C.Good
	local size: UDim2 = props.Size or UDim2.fromOffset(160, 52)
	local fixedHeight = if size.Y.Scale == 0 then size.Y.Offset else nil
	local depth = props.Depth or (if fixedHeight and fixedHeight < 44 then 4 else 6)
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

	local base = Kit.new("Frame", {
		Name = "Base",
		BackgroundColor3 = Kit.darken(color, 0.5),
		Size = UDim2.new(1, 0, 1, -depth),
		Position = UDim2.fromOffset(0, depth),
		Parent = button,
	})
	Kit.corner(base, radius)
	Kit.stroke(base, 3)

	local face = Kit.new("Frame", {
		Name = "Face",
		BackgroundColor3 = FACE_IDLE,
		Size = UDim2.new(1, 0, 1, -depth),
		Parent = button,
	})
	Kit.corner(face, radius)
	Kit.stroke(face, 3)
	local gradient = Kit.gradient(face, color, color)

	-- Glossy highlight across the top of the face.
	local shine = Kit.new("Frame", {
		Name = "Shine",
		BackgroundColor3 = WHITE,
		BackgroundTransparency = 0.8,
		Size = UDim2.new(1, -10, 0.36, 0),
		Position = UDim2.fromOffset(5, 3),
		Parent = face,
	})
	Kit.corner(shine, math.max(radius - 4, 4))

	local faceHeight = if fixedHeight then fixedHeight - depth else nil
	local font = props.Font or Theme.Fonts.Title
	local textColor = props.TextColor or Kit.C.Text
	local label: TextLabel
	local icon: TextLabel? = nil
	if props.Layout == "Stack" then
		icon = Kit.text(face, {
			Name = "Icon",
			Text = props.Icon or "",
			TextSize = if faceHeight then math.floor(faceHeight * 0.42) else nil,
			Size = UDim2.new(1, 0, 0.56, 0),
			Position = UDim2.fromScale(0, 0.04),
			StrokeThickness = 0,
		})
		label = Kit.text(face, {
			Name = "Label",
			Text = props.Text or "",
			Font = font,
			TextSize = props.TextSize or (if faceHeight then math.clamp(math.floor(faceHeight * 0.2), 11, 22) else nil),
			TextColor3 = textColor,
			TextWrapped = false,
			Size = UDim2.new(1, -6, 0.34, 0),
			Position = UDim2.new(0, 3, 0.6, 0),
		})
	else
		local text = props.Text or ""
		if props.Icon then
			text = props.Icon .. "  " .. text
		end
		label = Kit.text(face, {
			Name = "Label",
			Text = text,
			Font = font,
			RichText = props.RichText or false,
			TextSize = props.TextSize or (if faceHeight then math.clamp(math.floor(faceHeight * 0.5), 12, 34) else nil),
			MaxTextSize = if faceHeight or props.TextSize then nil else 30,
			TextColor3 = textColor,
			Size = UDim2.new(1, -14, 1, -4),
			Position = UDim2.fromOffset(7, 2),
		})
	end

	local state: ButtonState = {
		face = face,
		base = base,
		gradient = gradient,
		label = label,
		icon = icon,
		color = color,
		enabled = true,
		depth = depth,
	}
	buttons[button] = state
	paintButton(state)

	local scale = Kit.new("UIScale", { Parent = button })
	local function rest()
		face.Position = UDim2.new()
	end
	button.MouseEnter:Connect(function()
		if state.enabled then
			Kit.tween(scale, 0.12, { Scale = 1.04 })
			face.BackgroundColor3 = WHITE
		end
	end)
	button.MouseLeave:Connect(function()
		Kit.tween(scale, 0.12, { Scale = 1 })
		face.BackgroundColor3 = FACE_IDLE
		rest()
	end)
	button.MouseButton1Down:Connect(function()
		if state.enabled then
			Kit.tween(face, 0.06, { Position = UDim2.fromOffset(0, depth - 1) })
		end
	end)
	button.MouseButton1Up:Connect(function()
		Kit.tween(face, 0.12, { Position = UDim2.new() }, Enum.EasingStyle.Back)
	end)
	button.Activated:Connect(function()
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
		state.label.Text = text
	end
	if color then
		state.color = color
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

-- Panels / pills ----------------------------------------------------------------------

-- Panel with a soft vertical gradient and a heavy outline.
function Kit.panel(parent: Instance, props: { [string]: any }): Frame
	local color = props.Color or Kit.C.Panel
	local frame = Kit.new("Frame", {
		BackgroundColor3 = WHITE,
		Size = props.Size or UDim2.fromOffset(200, 100),
		Position = props.Position or UDim2.new(),
		AnchorPoint = props.AnchorPoint or Vector2.zero,
		LayoutOrder = props.LayoutOrder or 0,
		Visible = if props.Visible == nil then true else props.Visible,
		Name = props.Name or "Panel",
		ZIndex = props.ZIndex or 1,
		Parent = parent,
	})
	Kit.corner(frame, props.Radius or Kit.RADIUS.L)
	Kit.stroke(frame, props.StrokeThickness or 3, props.StrokeColor)
	Kit.gradient(frame, Kit.lighten(color, 0.07), Kit.darken(color, 0.14))
	return frame
end

-- A flat inset well (darker area inside a panel).
function Kit.well(parent: Instance, props: { [string]: any }): Frame
	local frame = Kit.new("Frame", {
		Name = props.Name or "Well",
		BackgroundColor3 = props.Color or Kit.C.PanelDark,
		BackgroundTransparency = props.Transparency or 0.15,
		Size = props.Size or UDim2.fromScale(1, 1),
		Position = props.Position or UDim2.new(),
		AnchorPoint = props.AnchorPoint or Vector2.zero,
		LayoutOrder = props.LayoutOrder or 0,
		Parent = parent,
	})
	Kit.corner(frame, props.Radius or Kit.RADIUS.M)
	return frame
end

-- Small rounded label with a coloured background ("chips", tags).
function Kit.pill(parent: Instance, props: { [string]: any }): TextLabel
	local color = props.Color or Kit.C.PanelLight
	local label = Kit.text(parent, {
		Name = props.Name or "Pill",
		Text = props.Text or "",
		Font = props.Font or Theme.Fonts.Title,
		TextSize = props.TextSize or Kit.TEXT.Small,
		TextColor3 = props.TextColor or Kit.C.Text,
		TextWrapped = false,
		BackgroundTransparency = 0,
		BackgroundColor3 = color,
		Size = props.Size or UDim2.fromOffset(80, 26),
		Position = props.Position or UDim2.new(),
		AnchorPoint = props.AnchorPoint or Vector2.zero,
		LayoutOrder = props.LayoutOrder or 0,
		Rotation = props.Rotation or 0,
		ZIndex = props.ZIndex or 1,
		AutomaticSize = props.AutomaticSize or Enum.AutomaticSize.None,
		Visible = if props.Visible == nil then true else props.Visible,
		RichText = props.RichText or false,
	})
	if props.AutomaticSize then
		Kit.padding(label, 0, 10)
	end
	Kit.round(label)
	Kit.new("UIStroke", {
		Thickness = 2.5,
		Color = Kit.C.Stroke,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
		Parent = label,
	})
	return label
end

-- Red notification dot on the top-right corner of `target` (nil text hides it).
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
			Color = Kit.C.Bad,
			TextSize = Kit.TEXT.Small,
			Size = UDim2.fromOffset(26, 26),
			Position = UDim2.new(1, 7, 0, -7),
			AnchorPoint = Vector2.new(1, 0),
			ZIndex = 5,
			Visible = false,
		})
		Kit.new("UIScale", { Name = "Pop", Scale = 1, Parent = created })
		badge = created
	end
	local b = badge :: TextLabel
	b.Text = text
	b.Size = UDim2.fromOffset(math.max(26, 12 + utf8.len(text) :: number * 9), 26)
	if not b.Visible then
		b.Visible = true
		local pop = b:FindFirstChild("Pop") :: UIScale
		pop.Scale = 0.4
		Kit.tween(pop, 0.3, { Scale = 1 }, Enum.EasingStyle.Back)
	end
end

-- Pulsing coloured ring around `target` to draw the eye (tutorial / ready).
local glowing: { [Instance]: boolean } = setmetatable({}, { __mode = "k" }) :: any
function Kit.setGlow(target: GuiObject, on: boolean, color: Color3?)
	local holder: GuiObject = buttons[target] and buttons[target].face or target
	local ring = holder:FindFirstChild("Glow") :: Frame?
	if not on then
		glowing[holder] = nil
		if ring then
			ring.Visible = false
		end
		return
	end
	if not ring then
		local created = Kit.new("Frame", {
			Name = "Glow",
			BackgroundTransparency = 1,
			Size = UDim2.new(1, 12, 1, 12),
			Position = UDim2.fromOffset(-6, -6),
			ZIndex = 4,
			Parent = holder,
		})
		local corner = holder:FindFirstChildOfClass("UICorner")
		Kit.corner(created, (if corner then corner.CornerRadius.Offset else Kit.RADIUS.M) + 6)
		Kit.new("UIStroke", { Name = "Ring", Thickness = 4, Color = color or Kit.C.Primary, Parent = created })
		ring = created
	end
	local r = ring :: Frame
	r.Visible = true
	local stroke = r:FindFirstChild("Ring") :: UIStroke
	stroke.Color = color or Kit.C.Primary
	if glowing[holder] then
		return
	end
	glowing[holder] = true
	task.spawn(function()
		local on2 = true
		while glowing[holder] and holder.Parent do
			Kit.tween(stroke, 0.5, { Transparency = if on2 then 0.75 else 0 }, Enum.EasingStyle.Sine)
			on2 = not on2
			task.wait(0.55)
		end
		stroke.Transparency = 0
	end)
end

-- Horizontal progress bar. Returns the frame and a setter (0..1).
function Kit.progress(parent: Instance, props: { [string]: any }): (Frame, (number) -> (), TextLabel)
	local color = props.Color or Kit.C.Good
	local track = Kit.new("Frame", {
		Name = props.Name or "Progress",
		BackgroundColor3 = props.TrackColor or Kit.C.PanelDark,
		Size = props.Size or UDim2.new(1, 0, 0, 22),
		Position = props.Position or UDim2.new(),
		AnchorPoint = props.AnchorPoint or Vector2.zero,
		LayoutOrder = props.LayoutOrder or 0,
		ClipsDescendants = false,
		Parent = parent,
	})
	Kit.round(track)
	Kit.stroke(track, 2.5)
	local fill = Kit.new("Frame", {
		Name = "Fill",
		BackgroundColor3 = WHITE,
		Size = UDim2.fromScale(0, 1),
		Parent = track,
	})
	Kit.round(fill)
	Kit.gradient(fill, Kit.lighten(color, 0.3), color)
	local gloss = Kit.new("Frame", {
		Name = "Gloss",
		BackgroundColor3 = WHITE,
		BackgroundTransparency = 0.75,
		Size = UDim2.new(1, -8, 0.32, 0),
		Position = UDim2.fromOffset(4, 2),
		Parent = fill,
	})
	Kit.round(gloss)
	local label = Kit.title(track, {
		Name = "Label",
		Text = props.Text or "",
		TextSize = props.TextSize or Kit.TEXT.Small,
		Size = UDim2.fromScale(1, 1),
		ZIndex = 3,
	})
	local minVisible = props.MinFill or 0.06
	local function set(ratio: number, instant: boolean?)
		local r = math.clamp(ratio, 0, 1)
		fill.Visible = r > 0
		local target = UDim2.fromScale(math.max(r, minVisible), 1)
		if instant then
			fill.Size = target
		else
			Kit.tween(fill, 0.35, { Size = target })
		end
	end
	return track, set, label
end

-- On/off switch. Returns the hit button and a setter (value, locked?).
function Kit.switch(parent: Instance, props: { [string]: any }, onToggle: () -> ()): (TextButton, (boolean, boolean?) -> ())
	local w, h = 76, 38
	local button = Kit.new("TextButton", {
		Name = props.Name or "Switch",
		AutoButtonColor = false,
		BackgroundColor3 = Kit.C.PadDisabled,
		Text = "",
		Size = UDim2.fromOffset(w, h),
		Position = props.Position or UDim2.new(),
		AnchorPoint = props.AnchorPoint or Vector2.zero,
		LayoutOrder = props.LayoutOrder or 0,
		Parent = parent,
	})
	Kit.round(button)
	Kit.stroke(button, 3)
	local shade = Kit.new("Frame", {
		Name = "Shade",
		BackgroundColor3 = Color3.new(0, 0, 0),
		BackgroundTransparency = 0.78,
		Size = UDim2.new(1, -8, 0.42, 0),
		Position = UDim2.new(0, 4, 0, 3),
		Parent = button,
	})
	Kit.round(shade)
	local stateLabel = Kit.title(button, {
		Name = "State",
		Text = "",
		TextSize = Kit.TEXT.Tiny,
		Size = UDim2.new(1, -h, 1, 0),
		Position = UDim2.fromOffset(0, 0),
		StrokeThickness = 1.5,
	})
	local knob = Kit.new("Frame", {
		Name = "Knob",
		BackgroundColor3 = WHITE,
		Size = UDim2.fromOffset(h - 8, h - 8),
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 4, 0.5, 0),
		Parent = button,
	})
	Kit.round(knob)
	Kit.stroke(knob, 2.5)
	Kit.gradient(knob, WHITE, Color3.fromRGB(200, 200, 210))
	Kit.bouncy(button, 1.04)
	local locked = false
	button.Activated:Connect(function()
		Kit.sound(if locked then "Error" else "Toggle")
		onToggle()
	end)
	local function set(value: boolean, isLocked: boolean?)
		locked = isLocked == true
		if locked then
			button.BackgroundColor3 = Kit.darken(Kit.C.PadDisabled, 0.35)
			stateLabel.Text = "🔒"
			stateLabel.Position = UDim2.fromOffset(h - 4, 0)
			Kit.tween(knob, 0.18, { Position = UDim2.new(0, 4, 0.5, 0) })
			return
		end
		button.BackgroundColor3 = if value then Kit.C.Good else Kit.darken(Kit.C.PadDisabled, 0.2)
		stateLabel.Text = if value then "ON" else "OFF"
		stateLabel.Position = if value then UDim2.fromOffset(4, 0) else UDim2.fromOffset(h - 4, 0)
		Kit.tween(
			knob,
			0.18,
			{ Position = if value then UDim2.new(1, -(h - 4), 0.5, 0) else UDim2.new(0, 4, 0.5, 0) },
			Enum.EasingStyle.Back
		)
	end
	set(false)
	return button, set
end

-- Builds a ViewportFrame showing a unit tier.
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
		CharacterFactory.silhouette(model)
	end
	model.Parent = viewport
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

-- Standard modal window: coloured header with an icon medallion and a close button.
export type Window = {
	frame: Frame,
	content: Frame,
	header: Frame,
	setOpen: (boolean) -> (),
	isOpen: () -> boolean,
	onOpen: BindableEvent,
	onClose: BindableEvent,
}

function Kit.window(screen: ScreenGui, name: string, title: string, icon: string, color: Color3, size: Vector2): Window
	local frame = Kit.panel(screen, {
		Name = name,
		Size = UDim2.fromOffset(size.X, size.Y),
		Position = UDim2.new(0.5, 0, 0.5, 6),
		AnchorPoint = Vector2.new(0.5, 0.5),
		Color = Kit.C.Panel,
		Visible = false,
		StrokeThickness = 4,
		Radius = Kit.RADIUS.XL,
	})
	frame.ZIndex = 10
	local scale = Kit.new("UIScale", { Parent = frame })

	local header = Kit.new("Frame", {
		Name = "Header",
		BackgroundColor3 = WHITE,
		Size = UDim2.new(1, -20, 0, 60),
		Position = UDim2.fromOffset(10, 10),
		Parent = frame,
	})
	Kit.corner(header, Kit.RADIUS.L)
	Kit.stroke(header, 3)
	Kit.gradient(header, Kit.lighten(color, 0.18), Kit.darken(color, 0.12))
	local headerShine = Kit.new("Frame", {
		Name = "Shine",
		BackgroundColor3 = WHITE,
		BackgroundTransparency = 0.82,
		Size = UDim2.new(1, -12, 0.4, 0),
		Position = UDim2.fromOffset(6, 4),
		Parent = header,
	})
	Kit.corner(headerShine, 10)

	-- Icon medallion that pops out of the header's left edge.
	local medal = Kit.new("Frame", {
		Name = "Medal",
		BackgroundColor3 = WHITE,
		Size = UDim2.fromOffset(70, 70),
		Position = UDim2.fromOffset(-8, -14),
		Rotation = -6,
		Parent = header,
	})
	Kit.round(medal)
	Kit.stroke(medal, 3)
	Kit.gradient(medal, Kit.lighten(color, 0.45), color)
	Kit.text(medal, { Name = "Icon", Text = icon, TextSize = 38, Size = UDim2.fromScale(1, 1), StrokeThickness = 0 })

	Kit.title(header, {
		Name = "Title",
		Text = string.upper(title),
		TextSize = Kit.TEXT.H1,
		TextWrapped = false,
		Size = UDim2.new(1, -150, 1, 0),
		Position = UDim2.fromOffset(74, 0),
		TextXAlignment = Enum.TextXAlignment.Left,
		StrokeThickness = 2.5,
	})

	local content = Kit.new("Frame", {
		Name = "Content",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, -32, 1, -98),
		Position = UDim2.fromOffset(16, 84),
		Parent = frame,
	})

	local open = false
	local token = 0
	local onOpen = Instance.new("BindableEvent")
	local onClose = Instance.new("BindableEvent")
	local function setOpen(value: boolean)
		if value == open then
			return
		end
		open = value
		token += 1
		if value then
			frame.Visible = true
			scale.Scale = 0.86
			Kit.tween(scale, 0.22, { Scale = 1 }, Enum.EasingStyle.Back)
			Kit.sound("Open")
			onOpen:Fire()
		else
			local mine = token
			Kit.tween(scale, 0.12, { Scale = 0.9 }, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
			task.delay(0.12, function()
				if token == mine then
					frame.Visible = false
				end
			end)
			onClose:Fire()
		end
	end

	Kit.button(header, {
		Name = "Close",
		Text = "X",
		Color = Kit.C.Bad,
		Size = UDim2.fromOffset(54, 52),
		Position = UDim2.new(1, -4, 0.5, -1),
		AnchorPoint = Vector2.new(1, 0.5),
		TextSize = 28,
		Sound = "Close",
	}, function()
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
		ScrollBarThickness = 6,
		ScrollBarImageColor3 = Kit.C.Primary,
		VerticalScrollBarInset = Enum.ScrollBarInset.ScrollBar,
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		CanvasSize = UDim2.new(),
		ScrollingDirection = Enum.ScrollingDirection.Y,
		Parent = parent,
	})
end

-- Full-screen dimmer; returns the (clickable) frame. Starts hidden.
function Kit.backdrop(parent: Instance, zindex: number, onClick: (() -> ())?): TextButton
	local dim = Kit.new("TextButton", {
		Name = "Backdrop",
		AutoButtonColor = false,
		Text = "",
		BackgroundColor3 = Color3.fromRGB(4, 2, 10),
		BackgroundTransparency = 0.45,
		Size = UDim2.new(2, 0, 2, 0),
		Position = UDim2.fromScale(-0.5, -0.5),
		ZIndex = zindex,
		Visible = false,
		Parent = parent,
	})
	if onClick then
		dim.Activated:Connect(onClick)
	end
	return dim
end

local fadeTokens: { [Instance]: number } = setmetatable({}, { __mode = "k" }) :: any
function Kit.fadeBackdrop(dim: GuiObject, show: boolean, opacity: number?)
	local token = (fadeTokens[dim] or 0) + 1
	fadeTokens[dim] = token
	if show then
		if not dim.Visible then
			dim.BackgroundTransparency = 1
		end
		dim.Visible = true
		Kit.tween(dim, 0.2, { BackgroundTransparency = 1 - (opacity or 0.55) })
	else
		Kit.tween(dim, 0.15, { BackgroundTransparency = 1 })
		task.delay(0.15, function()
			if fadeTokens[dim] == token then
				dim.Visible = false
			end
		end)
	end
end

return Kit
