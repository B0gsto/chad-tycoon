--[[
	LoadingScreen: full-screen splash shown from ReplicatedFirst until the
	first State snapshot arrives. Standalone (the client Kit isn't replicated
	yet when this runs); it takes the theme later, once ReplicatedStorage has
	arrived, to show the game name, tagline and colours.
]]

local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local LoadingScreen = {}

export type Handle = {
	root: CanvasGroup,
	applyTheme: (any) -> (),
	setStatus: (string) -> (),
	finish: () -> (),
}

local DEFAULT = {
	Primary = Color3.fromRGB(255, 200, 45),
	Secondary = Color3.fromRGB(165, 80, 255),
	Panel = Color3.fromRGB(24, 20, 36),
	PanelDark = Color3.fromRGB(12, 10, 20),
	Sky = Color3.fromRGB(30, 20, 52),
	Stroke = Color3.fromRGB(8, 6, 14),
	Text = Color3.new(1, 1, 1),
	TextDim = Color3.fromRGB(190, 185, 210),
}

local function new(className: string, props: { [string]: any }): any
	local inst = Instance.new(className)
	local parent = props.Parent
	for key, value in props do
		if key ~= "Parent" then
			(inst :: any)[key] = value
		end
	end
	inst.Parent = parent
	return inst
end

local function stroke(parent: Instance, thickness: number, color: Color3): UIStroke
	return new("UIStroke", { Thickness = thickness, Color = color, Parent = parent })
end

local function tween(obj: Instance, time: number, props: { [string]: any })
	TweenService:Create(obj, TweenInfo.new(time, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), props):Play()
end

function LoadingScreen.build(parent: Instance, theme: any?): Handle
	local colors = DEFAULT
	local root = new("CanvasGroup", {
		Name = "Loading",
		BackgroundColor3 = Color3.new(1, 1, 1),
		Size = UDim2.fromScale(1, 1),
		ZIndex = 100,
		Parent = parent,
	})
	local background = new("UIGradient", { Rotation = 90, Parent = root })

	-- Big soft diagonal bands for depth.
	local bands = {}
	for i = 1, 4 do
		local band = new("Frame", {
			Name = "Band",
			BackgroundColor3 = Color3.new(1, 1, 1),
			BackgroundTransparency = 0.94,
			BorderSizePixel = 0,
			Size = UDim2.new(0.16, 0, 2.5, 0),
			Position = UDim2.fromScale(-0.2 + i * 0.3, -0.7),
			Rotation = 28,
			Parent = root,
		})
		table.insert(bands, band)
	end

	local center = new("Frame", {
		Name = "Center",
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(900, 360),
		Position = UDim2.fromScale(0.5, 0.46),
		AnchorPoint = Vector2.new(0.5, 0.5),
		Parent = root,
	})
	new("UISizeConstraint", { MaxSize = Vector2.new(900, 360), Parent = center })
	local scale = new("UIScale", { Parent = center })

	local title = new("TextLabel", {
		Name = "Title",
		BackgroundTransparency = 1,
		Text = "",
		Font = Enum.Font.FredokaOne,
		TextSize = 76,
		TextColor3 = Color3.new(1, 1, 1),
		Size = UDim2.new(1, 0, 0, 90),
		Position = UDim2.fromOffset(0, 40),
		Parent = center,
	})
	local titleStroke = stroke(title, 5, colors.Stroke)
	local titleGradient = new("UIGradient", { Rotation = 90, Parent = title })
	local tagline = new("TextLabel", {
		Name = "Tagline",
		BackgroundTransparency = 1,
		Text = "",
		Font = Enum.Font.FredokaOne,
		TextSize = 26,
		TextColor3 = colors.TextDim,
		Size = UDim2.new(1, 0, 0, 34),
		Position = UDim2.fromOffset(0, 134),
		Parent = center,
	})
	stroke(tagline, 2, colors.Stroke)

	-- Spinner: a ring of dots that fades around.
	local spinner = new("Frame", {
		Name = "Spinner",
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(70, 70),
		Position = UDim2.new(0.5, 0, 0, 230),
		AnchorPoint = Vector2.new(0.5, 0.5),
		Parent = center,
	})
	local dots: { Frame } = {}
	local DOTS = 10
	for i = 1, DOTS do
		local angle = (i - 1) / DOTS * math.pi * 2
		local dot = new("Frame", {
			Name = "Dot",
			BackgroundColor3 = colors.Primary,
			BackgroundTransparency = (i - 1) / DOTS * 0.85,
			Size = UDim2.fromOffset(13, 13),
			Position = UDim2.new(0.5 + math.sin(angle) * 0.42, 0, 0.5 - math.cos(angle) * 0.42, 0),
			AnchorPoint = Vector2.new(0.5, 0.5),
			Parent = spinner,
		})
		new("UICorner", { CornerRadius = UDim.new(1, 0), Parent = dot })
		stroke(dot, 2, colors.Stroke)
		dots[i] = dot
	end

	local status = new("TextLabel", {
		Name = "Status",
		BackgroundTransparency = 1,
		Text = "Loading...",
		Font = Enum.Font.FredokaOne,
		TextSize = 22,
		TextColor3 = colors.Text,
		Size = UDim2.new(1, 0, 0, 30),
		Position = UDim2.fromOffset(0, 284),
		Parent = center,
	})
	stroke(status, 2, colors.Stroke)

	local tip = new("TextLabel", {
		Name = "Tip",
		BackgroundTransparency = 1,
		Text = "",
		Font = Enum.Font.GothamBold,
		TextSize = 18,
		TextColor3 = colors.TextDim,
		TextWrapped = true,
		Size = UDim2.new(1, -40, 0, 50),
		Position = UDim2.new(0, 20, 1, -80),
		Parent = root,
	})
	stroke(tip, 1.5, colors.Stroke)

	local tips: { string } = {}
	local tipIndex = 0

	local function applyTheme(t: any)
		if type(t) ~= "table" then
			t = {}
		end
		local c = t.Colors or {}
		local primary = c.Primary or DEFAULT.Primary
		local sky = c.Sky or DEFAULT.Sky
		local dark = c.PanelDark or DEFAULT.PanelDark
		background.Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, sky:Lerp(Color3.new(1, 1, 1), 0.05)),
			ColorSequenceKeypoint.new(0.6, dark),
			ColorSequenceKeypoint.new(1, dark:Lerp(Color3.new(0, 0, 0), 0.4)),
		})
		for _, band in bands do
			band.BackgroundColor3 = c.Secondary or DEFAULT.Secondary
			band.BackgroundTransparency = 0.94
		end
		local fonts = t.Fonts or {}
		title.Text = string.upper(t.GameName or "")
		title.Font = fonts.Title or Enum.Font.FredokaOne
		titleGradient.Color = ColorSequence.new(primary:Lerp(Color3.new(1, 1, 1), 0.45), primary)
		titleStroke.Color = c.Stroke or DEFAULT.Stroke
		tagline.Text = t.Tagline or ""
		tagline.Font = fonts.Body or Enum.Font.FredokaOne
		status.Font = fonts.Title or Enum.Font.FredokaOne
		for _, dot in dots do
			dot.BackgroundColor3 = primary
		end
		local loading = t.Loading or {}
		status.Text = loading.Status or "Loading..."
		tips = loading.Tips or {}
		if #tips > 0 then
			tipIndex = 1
			tip.Text = tips[1]
		end
	end
	applyTheme(theme)

	local alive = true
	local clock = 0
	local nextTip = 4
	local connection = RunService.RenderStepped:Connect(function(dt)
		clock += dt
		spinner.Rotation = math.floor(clock * 12) * (360 / DOTS)
		if clock >= nextTip and #tips > 1 then
			nextTip = clock + 4
			tipIndex = tipIndex % #tips + 1
			tip.Text = tips[tipIndex]
		end
		local camera = workspace.CurrentCamera
		if camera then
			local size = camera.ViewportSize
			scale.Scale = math.clamp(math.min(size.X / 1000, size.Y / 560), 0.45, 1.4)
		end
	end)

	local function finish()
		if not alive then
			return
		end
		alive = false
		tween(root, 0.6, { GroupTransparency = 1 })
		tween(scale, 0.6, { Scale = scale.Scale * 1.08 })
		task.delay(0.65, function()
			connection:Disconnect()
			root:Destroy()
		end)
	end

	return {
		root = root,
		applyTheme = applyTheme,
		setStatus = function(text: string)
			status.Text = text
		end,
		finish = finish,
	}
end

return LoadingScreen
