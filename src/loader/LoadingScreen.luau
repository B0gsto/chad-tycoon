--[[
	LoadingScreen: full-screen splash shown from ReplicatedFirst until the
	first State snapshot arrives. Standalone (the client Kit isn't replicated
	yet when this runs): it takes the theme later, once ReplicatedStorage has
	arrived, for the game name, tagline, tips and colours, and the Blender art
	(brand/KeyArt background, brand/Logo wordmark) once Shared.Assets is there.

	Look: the key art covers the screen under a soft navy gradient (clear at
	the top, deeper at the bottom so text reads); the logo bobs gently above a
	chunky sunny progress bar; tips sit in a rounded navy pill near the bottom.
	Without art ids it keeps the code-drawn sky gradient, bands and title text.
	Art fades in only once its image has loaded; the whole screen fades out.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

-- The Lune preview exporter stubs TweenInfo: show loaded art at once there.
local PREVIEW = typeof(TweenInfo.new(0)) ~= "TweenInfo"

local LoadingScreen = {}

export type Art = { keyArt: string?, logo: string? }

export type Handle = {
	root: CanvasGroup,
	applyTheme: (any) -> (),
	applyArt: (Art?) -> (),
	setStatus: (string) -> (),
	finish: () -> (),
}

local DEFAULT = {
	Primary = Color3.fromRGB(255, 212, 64),
	PrimaryDeep = Color3.fromRGB(244, 150, 44),
	Secondary = Color3.fromRGB(170, 132, 255),
	Sky = Color3.fromRGB(118, 200, 255),
	PanelDark = Color3.fromRGB(46, 62, 136),
	Ink = Color3.fromRGB(42, 54, 114),
	Text = Color3.new(1, 1, 1),
	TextDim = Color3.fromRGB(212, 224, 255),
}

local WHITE = Color3.new(1, 1, 1)

-- Layout of the centre column (design pixels; scaled to the viewport).
local CENTER = Vector2.new(900, 430)

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

local function stroke(parent: Instance, thickness: number, color: Color3, transparency: number?): UIStroke
	return new("UIStroke", { Thickness = thickness, Color = color, Transparency = transparency or 0, Parent = parent })
end

local function round(parent: Instance)
	new("UICorner", { CornerRadius = UDim.new(1, 0), Parent = parent })
end

local function tween(obj: Instance, time: number, props: { [string]: any }, style: Enum.EasingStyle?)
	TweenService:Create(obj, TweenInfo.new(time, style or Enum.EasingStyle.Quad, Enum.EasingDirection.Out), props):Play()
end

--[[
	The brand art ids from ReplicatedStorage.Shared.Assets (the generated asset
	table, a plain data module). Waits up to `timeout` seconds for it to
	replicate (0 = look once). Returns nil when the module or both ids are
	missing (not uploaded, rejected, or not replicated in time).
]]
function LoadingScreen.findArt(timeout: number?): Art?
	local wait = timeout or 0
	local shared = if wait > 0 then ReplicatedStorage:WaitForChild("Shared", wait) else ReplicatedStorage:FindFirstChild("Shared")
	if not shared then
		return nil
	end
	local module = if wait > 0 then shared:WaitForChild("Assets", wait) else shared:FindFirstChild("Assets")
	if not module or not module:IsA("ModuleScript") then
		return nil
	end
	local ok, assets = pcall(require, module :: any)
	if not ok or type(assets) ~= "table" or type((assets :: any).Images) ~= "table" then
		return nil
	end
	local images = (assets :: any).Images
	local function id(key: string): string?
		local value = images[key]
		return if type(value) == "string" and value ~= "" then value else nil
	end
	local art = { keyArt = id("brand/KeyArt"), logo = id("brand/Logo") }
	if not art.keyArt and not art.logo then
		return nil
	end
	return art
end

function LoadingScreen.build(parent: Instance, theme: any?): Handle
	local colors = DEFAULT
	local root = new("CanvasGroup", {
		Name = "Loading",
		BackgroundColor3 = WHITE,
		Size = UDim2.fromScale(1, 1),
		ZIndex = 100,
		Parent = parent,
	})
	local background = new("UIGradient", { Rotation = 90, Parent = root })

	-- Code-drawn backdrop: big soft diagonal bands over the sky gradient.
	local bands = {}
	for i = 1, 4 do
		local band = new("Frame", {
			Name = "Band",
			BackgroundColor3 = WHITE,
			BackgroundTransparency = 0.92,
			BorderSizePixel = 0,
			Size = UDim2.new(0.16, 0, 2.5, 0),
			Position = UDim2.fromScale(-0.2 + i * 0.3, -0.7),
			Rotation = 28,
			Parent = root,
		})
		table.insert(bands, band)
	end

	-- Key art (cover), faded in once loaded, under a soft readability gradient.
	local keyArt = new("ImageLabel", {
		Name = "KeyArt",
		BackgroundTransparency = 1,
		Image = "",
		ImageTransparency = 1,
		ScaleType = Enum.ScaleType.Crop,
		Size = UDim2.fromScale(1, 1),
		Visible = false,
		Parent = root,
	})
	local shade = new("Frame", {
		Name = "Shade",
		BackgroundColor3 = colors.Ink,
		BorderSizePixel = 0,
		BackgroundTransparency = 0,
		Size = UDim2.fromScale(1, 1),
		Visible = false,
		Parent = root,
	})
	new("UIGradient", {
		Rotation = 90,
		Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.82),
			NumberSequenceKeypoint.new(0.4, 0.9),
			NumberSequenceKeypoint.new(0.62, 0.62),
			NumberSequenceKeypoint.new(1, 0.25),
		}),
		Parent = shade,
	})

	local center = new("Frame", {
		Name = "Center",
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(CENTER.X, CENTER.Y),
		Position = UDim2.fromScale(0.5, 0.48),
		AnchorPoint = Vector2.new(0.5, 0.5),
		Parent = root,
	})
	local scale = new("UIScale", { Parent = center })

	-- Wordmark area (the top 290 px): the logo image, or the title text without it.
	local logo = new("ImageLabel", {
		Name = "Logo",
		BackgroundTransparency = 1,
		Image = "",
		ImageTransparency = 1,
		ScaleType = Enum.ScaleType.Fit,
		Size = UDim2.fromOffset(580, 290),
		Position = UDim2.new(0.5, 0, 0, 145),
		AnchorPoint = Vector2.new(0.5, 0.5),
		Visible = false,
		Parent = center,
	})
	local title = new("TextLabel", {
		Name = "Title",
		BackgroundTransparency = 1,
		Text = "",
		Font = Enum.Font.FredokaOne,
		TextSize = 76,
		TextColor3 = WHITE,
		Size = UDim2.new(1, 0, 0, 90),
		Position = UDim2.new(0, 0, 0, 160),
		AnchorPoint = Vector2.new(0, 0.5),
		Parent = center,
	})
	local titleStroke = stroke(title, 5, colors.Ink)
	local titleGradient = new("UIGradient", { Rotation = 90, Parent = title })
	local tagline = new("TextLabel", {
		Name = "Tagline",
		BackgroundTransparency = 1,
		Text = "",
		Font = Enum.Font.FredokaOne,
		TextSize = 26,
		TextColor3 = WHITE,
		Size = UDim2.new(1, 0, 0, 34),
		Position = UDim2.fromOffset(0, 292),
		Parent = center,
	})
	stroke(tagline, 2.5, colors.Ink, 0.2)

	-- Chunky sunny progress bar: a navy track with a white rim and a moulded
	-- yellow fill (lighter on top, white gloss line, orange lip).
	local track = new("Frame", {
		Name = "Bar",
		BackgroundColor3 = colors.Ink,
		BackgroundTransparency = 0.25,
		BorderSizePixel = 0,
		Size = UDim2.fromOffset(460, 30),
		Position = UDim2.new(0.5, 0, 0, 348),
		AnchorPoint = Vector2.new(0.5, 0),
		Parent = center,
	})
	round(track)
	stroke(track, 3, WHITE, 0.1)
	local lipFill = new("Frame", {
		Name = "Lip",
		BackgroundColor3 = colors.PrimaryDeep,
		BorderSizePixel = 0,
		Size = UDim2.new(0.06, 0, 1, -6),
		Position = UDim2.fromOffset(3, 3),
		Parent = track,
	})
	round(lipFill)
	local fill = new("Frame", {
		Name = "Fill",
		BackgroundColor3 = WHITE,
		BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 1, -3),
		Parent = lipFill,
	})
	round(fill)
	local fillGradient = new("UIGradient", {
		Rotation = 90,
		Color = ColorSequence.new(colors.Primary:Lerp(WHITE, 0.35), colors.Primary),
		Parent = fill,
	})
	local gloss = new("Frame", {
		Name = "Gloss",
		BackgroundColor3 = WHITE,
		BackgroundTransparency = 0.45,
		BorderSizePixel = 0,
		Size = UDim2.new(1, -14, 0, 3),
		Position = UDim2.fromOffset(7, 3),
		Parent = fill,
	})
	round(gloss)

	local status = new("TextLabel", {
		Name = "Status",
		BackgroundTransparency = 1,
		Text = "Loading...",
		Font = Enum.Font.FredokaOne,
		TextSize = 22,
		TextColor3 = WHITE,
		Size = UDim2.new(1, 0, 0, 30),
		Position = UDim2.fromOffset(0, 388),
		Parent = center,
	})
	stroke(status, 2, colors.Ink, 0.2)

	-- Tip in a rounded navy pill near the bottom edge.
	local tipPill = new("Frame", {
		Name = "TipPill",
		BackgroundColor3 = colors.Ink,
		BackgroundTransparency = 0.25,
		BorderSizePixel = 0,
		Size = UDim2.new(0.8, 0, 0, 48),
		Position = UDim2.new(0.5, 0, 1, -28),
		AnchorPoint = Vector2.new(0.5, 1),
		Visible = false,
		Parent = root,
	})
	round(tipPill)
	stroke(tipPill, 2, WHITE, 0.6)
	new("UISizeConstraint", { MaxSize = Vector2.new(760, 48), Parent = tipPill })
	local tip = new("TextLabel", {
		Name = "Tip",
		BackgroundTransparency = 1,
		Text = "",
		Font = Enum.Font.GothamBold,
		TextColor3 = WHITE,
		TextScaled = true,
		TextWrapped = true,
		Size = UDim2.new(1, -36, 1, -12),
		Position = UDim2.fromOffset(18, 6),
		Parent = tipPill,
	})
	new("UITextSizeConstraint", { MaxTextSize = 18, MinTextSize = 11, Parent = tip })

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
		local ink = c.Ink or DEFAULT.Ink
		background.Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, sky),
			ColorSequenceKeypoint.new(0.65, sky:Lerp(dark, 0.55)),
			ColorSequenceKeypoint.new(1, dark),
		})
		for _, band in bands do
			band.BackgroundColor3 = WHITE
		end
		local fonts = t.Fonts or {}
		title.Text = string.upper(t.GameName or "")
		title.Font = fonts.Title or Enum.Font.FredokaOne
		titleGradient.Color = ColorSequence.new(primary:Lerp(WHITE, 0.45), primary)
		titleStroke.Color = ink
		tagline.Text = t.Tagline or ""
		tagline.Font = fonts.Bold or fonts.Body or Enum.Font.FredokaOne
		status.Font = fonts.Title or Enum.Font.FredokaOne
		tip.Font = fonts.Bold or Enum.Font.GothamBold
		fillGradient.Color = ColorSequence.new(primary:Lerp(WHITE, 0.35), primary)
		lipFill.BackgroundColor3 = c.GoldDeep or DEFAULT.PrimaryDeep
		local loading = t.Loading or {}
		status.Text = loading.Status or "Loading..."
		tips = loading.Tips or {}
		if #tips > 0 then
			tipIndex = 1
			tip.Text = tips[1]
			tipPill.Visible = true
		end
	end
	applyTheme(theme)

	-- Art waiting for its image to load, with what to do once it has.
	local pending: { { label: ImageLabel, show: () -> () } } = {}
	local function whenLoaded(label: ImageLabel, show: () -> ())
		if PREVIEW then
			show()
			return
		end
		table.insert(pending, { label = label, show = show })
	end

	local function applyArt(art: Art?)
		if not art then
			return
		end
		if art.keyArt and keyArt.Image ~= art.keyArt then
			keyArt.Image = art.keyArt
			keyArt.Visible = true
			whenLoaded(keyArt, function()
				shade.Visible = true
				shade.BackgroundTransparency = 1
				if PREVIEW then
					keyArt.ImageTransparency = 0
					shade.BackgroundTransparency = 0
				else
					tween(keyArt, 0.5, { ImageTransparency = 0 })
					tween(shade, 0.5, { BackgroundTransparency = 0 })
				end
				for _, band in bands do
					band.Visible = false
				end
			end)
		end
		if art.logo and logo.Image ~= art.logo then
			logo.Image = art.logo
			logo.Visible = true
			whenLoaded(logo, function()
				if PREVIEW then
					logo.ImageTransparency = 0
					title.TextTransparency = 1
					titleStroke.Transparency = 1
				else
					tween(logo, 0.4, { ImageTransparency = 0 })
					tween(title, 0.25, { TextTransparency = 1 })
					tween(titleStroke, 0.25, { Transparency = 1 })
				end
			end)
		end
	end
	-- Pick up art that is already there (in Studio and the preview it usually is).
	applyArt(LoadingScreen.findArt(0))

	local alive = true
	local clock = 0
	local nextTip = 5
	local progress = 0.06
	local target = 0.9
	local function setProgress(p: number)
		local r = math.clamp(p, 0.06, 1)
		lipFill.Size = UDim2.new(r, -6 * r, 1, -6)
	end
	setProgress(progress)

	local connection = RunService.RenderStepped:Connect(function(dt)
		clock += dt
		-- The bar creeps toward 90% while loading and fills on finish.
		progress += (target - progress) * math.min(1, dt * (if alive then 0.7 else 8))
		setProgress(progress)
		-- Gentle bob for the logo and title.
		local bob = math.sin(clock * 1.8) * 6
		logo.Position = UDim2.new(0.5, 0, 0, 145 + bob)
		logo.Rotation = math.sin(clock * 0.9) * 1.2
		title.Position = UDim2.new(0, 0, 0, 160 + bob)
		if clock >= nextTip and #tips > 1 then
			nextTip = clock + 5
			tipIndex = tipIndex % #tips + 1
			local nextText = tips[tipIndex]
			tween(tip, 0.18, { TextTransparency = 1 })
			task.delay(0.2, function()
				tip.Text = nextText
				tween(tip, 0.25, { TextTransparency = 0 })
			end)
		end
		for i = #pending, 1, -1 do
			local entry = pending[i]
			local ok, loaded = pcall(function()
				return entry.label.IsLoaded
			end)
			if not ok or loaded then
				table.remove(pending, i)
				entry.show()
			end
		end
		local camera = workspace.CurrentCamera
		if camera then
			local size = camera.ViewportSize
			scale.Scale = math.clamp(math.min(size.X / 1000, size.Y / 620), 0.4, 1.4)
		end
	end)

	local function finish()
		if not alive then
			return
		end
		alive = false
		target = 1
		task.delay(0.3, function()
			tween(root, 0.6, { GroupTransparency = 1 })
			tween(scale, 0.6, { Scale = scale.Scale * 1.04 })
		end)
		task.delay(0.95, function()
			connection:Disconnect()
			root:Destroy()
		end)
	end

	return {
		root = root,
		applyTheme = applyTheme,
		applyArt = applyArt,
		setStatus = function(text: string)
			status.Text = text
		end,
		finish = finish,
	}
end

return LoadingScreen
