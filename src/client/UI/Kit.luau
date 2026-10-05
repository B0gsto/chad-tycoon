--[[
	Kit: small helpers for building the code-driven UI in a consistent style
	(rounded panels, heavy outlines, gradient buttons, bouncy hover).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Theme = require(ReplicatedStorage:WaitForChild("Theme"))
local CharacterFactory = require(ReplicatedStorage.Shared.CharacterFactory)

local Kit = {}
Kit.Theme = Theme
Kit.C = Theme.Colors

local clickSound: (() -> ())? = nil
function Kit.setClickSound(fn: () -> ())
	clickSound = fn
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
	return Kit.new("UICorner", { CornerRadius = UDim.new(0, radius or 12), Parent = parent })
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

function Kit.padding(parent: Instance, px: number)
	return Kit.new("UIPadding", {
		PaddingTop = UDim.new(0, px),
		PaddingBottom = UDim.new(0, px),
		PaddingLeft = UDim.new(0, px),
		PaddingRight = UDim.new(0, px),
		Parent = parent,
	})
end

function Kit.text(parent: Instance, props: { [string]: any }): TextLabel
	local label = Kit.new("TextLabel", {
		BackgroundTransparency = 1,
		Font = Theme.Fonts.Body,
		TextColor3 = Kit.C.Text,
		TextScaled = true,
		Size = UDim2.fromScale(1, 1),
		Parent = parent,
	})
	for key, value in props do
		(label :: any)[key] = value
	end
	Kit.textStroke(label, props.TextScaled == false and 1.5 or 2)
	return label
end

function Kit.title(parent: Instance, props: { [string]: any }): TextLabel
	props.Font = props.Font or Theme.Fonts.Title
	return Kit.text(parent, props)
end

function Kit.tween(obj: Instance, time: number, props: { [string]: any }, style: Enum.EasingStyle?): Tween
	local tween = TweenService:Create(obj, TweenInfo.new(time, style or Enum.EasingStyle.Quad, Enum.EasingDirection.Out), props)
	tween:Play()
	return tween
end

function Kit.lighten(color: Color3, amount: number): Color3
	return color:Lerp(Color3.new(1, 1, 1), amount)
end

function Kit.darken(color: Color3, amount: number): Color3
	return color:Lerp(Color3.new(0, 0, 0), amount)
end

-- Adds a UIScale that pops on hover/press. Returns the scale object.
function Kit.bouncy(button: GuiButton): UIScale
	local scale = Kit.new("UIScale", { Parent = button })
	button.MouseEnter:Connect(function()
		Kit.tween(scale, 0.12, { Scale = 1.06 })
	end)
	button.MouseLeave:Connect(function()
		Kit.tween(scale, 0.12, { Scale = 1 })
	end)
	button.MouseButton1Down:Connect(function()
		Kit.tween(scale, 0.08, { Scale = 0.94 })
	end)
	button.MouseButton1Up:Connect(function()
		Kit.tween(scale, 0.12, { Scale = 1.06 })
	end)
	return scale
end

-- A chunky coloured button with text.
function Kit.button(parent: Instance, props: { [string]: any }, onClick: (() -> ())?): TextButton
	local color = props.Color or Kit.C.Good
	local button = Kit.new("TextButton", {
		AutoButtonColor = false,
		BackgroundColor3 = Color3.new(1, 1, 1),
		Text = "",
		Size = props.Size or UDim2.fromOffset(160, 50),
		Position = props.Position or UDim2.new(),
		AnchorPoint = props.AnchorPoint or Vector2.zero,
		LayoutOrder = props.LayoutOrder or 0,
		Parent = parent,
	})
	Kit.corner(button, props.Radius or 10)
	Kit.stroke(button, 3)
	local gradient = Kit.gradient(button, Kit.lighten(color, 0.15), Kit.darken(color, 0.15))
	local label = Kit.text(button, {
		Name = "Label",
		Text = props.Text or "",
		Font = props.Font or Theme.Fonts.Title,
		Size = UDim2.new(1, -12, 1, -8),
		Position = UDim2.fromOffset(6, 4),
		RichText = props.RichText or false,
	})
	Kit.bouncy(button)
	button.Activated:Connect(function()
		if clickSound then
			clickSound()
		end
		if onClick then
			onClick()
		end
	end);
	(button :: any):SetAttribute("BaseColor", color)
	-- Recolour helper used by callers to grey out disabled buttons.
	local function setColor(newColor: Color3)
		gradient.Color = ColorSequence.new(Kit.lighten(newColor, 0.15), Kit.darken(newColor, 0.15))
	end
	button:SetAttribute("Recolor", true)
	button:GetAttributeChangedSignal("Tint"):Connect(function()
		local tint = button:GetAttribute("Tint")
		if typeof(tint) == "Color3" then
			setColor(tint)
		end
	end)
	label.Name = "Label"
	return button
end

function Kit.setButton(button: TextButton, text: string?, color: Color3?)
	local label = button:FindFirstChild("Label") :: TextLabel?
	if text and label then
		label.Text = text
	end
	if color then
		button:SetAttribute("Tint", color)
	end
end

-- Panel with gradient background and outline.
function Kit.panel(parent: Instance, props: { [string]: any }): Frame
	local color = props.Color or Kit.C.Panel
	local frame = Kit.new("Frame", {
		BackgroundColor3 = Color3.new(1, 1, 1),
		Size = props.Size or UDim2.fromOffset(200, 100),
		Position = props.Position or UDim2.new(),
		AnchorPoint = props.AnchorPoint or Vector2.zero,
		LayoutOrder = props.LayoutOrder or 0,
		Visible = if props.Visible == nil then true else props.Visible,
		Name = props.Name or "Panel",
		Parent = parent,
	})
	Kit.corner(frame, props.Radius or 14)
	Kit.stroke(frame, props.StrokeThickness or 3)
	Kit.gradient(frame, Kit.lighten(color, 0.06), Kit.darken(color, 0.12))
	return frame
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

-- Standard modal window with a coloured title bar and close button.
export type Window = {
	frame: Frame,
	content: Frame,
	setOpen: (boolean) -> (),
	isOpen: () -> boolean,
	onOpen: BindableEvent,
}

function Kit.window(screen: ScreenGui, name: string, title: string, icon: string, color: Color3, size: Vector2): Window
	local frame = Kit.panel(screen, {
		Name = name,
		Size = UDim2.fromOffset(size.X, size.Y),
		Position = UDim2.fromScale(0.5, 0.5),
		AnchorPoint = Vector2.new(0.5, 0.5),
		Color = Kit.C.Panel,
		Visible = false,
		StrokeThickness = 4,
	})
	frame.ZIndex = 10
	local scale = Kit.new("UIScale", { Parent = frame })

	local bar = Kit.new("Frame", {
		Name = "TitleBar",
		BackgroundColor3 = Color3.new(1, 1, 1),
		Size = UDim2.new(1, -90, 0, 54),
		Position = UDim2.fromOffset(12, 12),
		Parent = frame,
	})
	Kit.corner(bar, 10)
	Kit.stroke(bar, 3)
	Kit.gradient(bar, Kit.lighten(color, 0.1), Kit.darken(color, 0.1))
	Kit.title(bar, { Text = icon, Size = UDim2.fromOffset(60, 60), Position = UDim2.fromOffset(-14, -10), TextScaled = true })
	Kit.title(bar, {
		Text = string.upper(title),
		Size = UDim2.new(1, -70, 0.8, 0),
		Position = UDim2.fromOffset(56, 6),
		TextXAlignment = Enum.TextXAlignment.Left,
	})

	local content = Kit.new("Frame", {
		Name = "Content",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, -24, 1, -86),
		Position = UDim2.fromOffset(12, 76),
		Parent = frame,
	})

	local open = false
	local onOpen = Instance.new("BindableEvent")
	local function setOpen(value: boolean)
		if value == open then
			return
		end
		open = value
		if value then
			frame.Visible = true
			scale.Scale = 0.8
			Kit.tween(scale, 0.18, { Scale = 1 }, Enum.EasingStyle.Back)
			onOpen:Fire()
		else
			frame.Visible = false
		end
	end

	Kit.button(frame, {
		Text = "X",
		Color = Kit.C.Bad,
		Size = UDim2.fromOffset(60, 54),
		Position = UDim2.new(1, -72, 0, 12),
	}, function()
		setOpen(false)
	end)

	return {
		frame = frame,
		content = content,
		setOpen = setOpen,
		isOpen = function()
			return open
		end,
		onOpen = onOpen,
	}
end

function Kit.scrolling(parent: Instance, props: { [string]: any }?): ScrollingFrame
	local p = props or {}
	return Kit.new("ScrollingFrame", {
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Size = p.Size or UDim2.fromScale(1, 1),
		Position = p.Position or UDim2.new(),
		ScrollBarThickness = 8,
		ScrollBarImageColor3 = Kit.C.Primary,
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		CanvasSize = UDim2.new(),
		ScrollingDirection = Enum.ScrollingDirection.Y,
		Parent = parent,
	})
end

return Kit
