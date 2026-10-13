--[[
	LoadingScreen: what is drawn over the join, from ReplicatedFirst until the
	player is in the game. There is no splash picture: the loading screen is
	the camera circling high over the map (Flyover) and this is only what sits
	on top of it. Standalone (the client Kit isn't replicated yet when this
	runs): it takes the theme later, once ReplicatedStorage has arrived, for
	the game name, tagline, tips and colours.

	Look: until the world has arrived a sky gradient covers the screen; open()
	fades it off the flight. The logo sits at the top centre, bobbing, with
	twinkles and a shine sweep; one band along the bottom holds the tagline, a
	chunky sunny progress bar (an aura orb riding its leading edge), the status
	under it and the tip card, over a soft navy shade. Without a logo id it
	shows the title text. finish() lifts the logo off the top and drops the
	band off the bottom while the camera comes down to the player.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

-- The Lune preview exporter stubs TweenInfo: show loaded art at once there.
local PREVIEW = typeof(TweenInfo.new(0)) ~= "TweenInfo"

local LoadingScreen = {}

export type Cell = { image: string, x: number, y: number, w: number, h: number }

export type Art = {
	logo: string?,
	logoShine: string?,
	softDot: string?,
	sparkle: string?,
	orb: Cell?,
}

export type Handle = {
	root: Frame,
	applyTheme: (any) -> (),
	applyArt: (Art?) -> (),
	setStatus: (string) -> (),
	setProgress: (number) -> (),
	-- The world is there: fades the sky cover off the camera's flight. `speed`
	-- scales time from here on (1 = real time).
	open: (number?) -> (),
	-- Takes the logo and the band off the screen at `speed` (1 = real time)
	-- and returns the seconds until they are gone.
	finish: (number?) -> number,
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

-- Art waiting for its image starts this faint, not at 1: the engine never
-- loads a fully transparent image, so its IsLoaded would stay false for good.
local UNLOADED = 0.99

-- Design pixels: the logo box (scaled to the viewport) and the bottom band
-- (tagline, bar, status, tip card; scaled a little larger on phones so it stays readable).
local LOGO = Vector2.new(430, 215)
local BAND = Vector2.new(640, 162)
local BAR = Vector2.new(640, 36)
local BAR_Y = 36
local STATUS_Y = 82

-- Seconds: the sky cover's fade once the world is there, and the logo and
-- band leaving the screen.
local OPEN = 0.9
local LEAVE = 0.7

-- Twinkles round the logo: position in the logo box, size (of its height),
-- speed, phase.
local TWINKLES = {
	{ x = 0.06, y = 0.30, size = 0.16, speed = 2.3, phase = 0.0 },
	{ x = 0.95, y = 0.22, size = 0.20, speed = 1.9, phase = 1.7 },
	{ x = 0.90, y = 0.84, size = 0.13, speed = 2.7, phase = 3.1 },
	{ x = 0.10, y = 0.86, size = 0.12, speed = 2.1, phase = 4.4 },
}

local SHINE_EVERY = 4.2
local SHINE_TIME = 0.9

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

local function round(parent: Instance, radius: UDim?)
	new("UICorner", { CornerRadius = radius or UDim.new(1, 0), Parent = parent })
end

local function image(name: string, parent: Instance, props: { [string]: any }?): ImageLabel
	local label = new("ImageLabel", {
		Name = name,
		BackgroundTransparency = 1,
		Image = "",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Parent = parent,
	})
	if props then
		for key, value in props do
			(label :: any)[key] = value
		end
	end
	return label
end

local function tween(obj: Instance, time: number, props: { [string]: any }, style: Enum.EasingStyle?)
	TweenService:Create(obj, TweenInfo.new(time, style or Enum.EasingStyle.Quad, Enum.EasingDirection.Out), props):Play()
end

-- Overshooting ease for the logo's pop-in.
local function backOut(t: number): number
	local c = 1.70158
	local u = t - 1
	return 1 + (c + 1) * u * u * u + c * u * u
end

-- Winds up the other way first: the logo and band dip before they leave.
local function backIn(t: number): number
	local c = 1.70158
	return (c + 1) * t * t * t - c * t * t
end

local function smooth(t: number): number
	return t * t * (3 - 2 * t)
end

--[[
	The brand art ids from ReplicatedStorage.Shared.Assets (the generated asset
	table, a plain data module). Waits up to `timeout` seconds for it to
	replicate (0 = look once). Returns nil when the module or both the key art
	and the logo are missing (not uploaded, rejected, or not replicated in time).
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
	local icons = (assets :: any).Icons
	local orb = if type(icons) == "table" and type(icons.Orb) == "table" then icons.Orb else nil
	local art: Art = {
		logo = id("brand/Logo"),
		logoShine = id("brand/LogoShine"),
		softDot = id("vfx/SoftDot"),
		sparkle = id("vfx/Sparkle"),
		orb = orb,
	}
	if not art.logo then
		return nil
	end
	return art
end

function LoadingScreen.build(parent: Instance, theme: any?): Handle
	local colors = DEFAULT
	-- A plain Frame, not a CanvasGroup: a full-screen CanvasGroup on a large
	-- high-DPI window drew only its own gradient and none of its children.
	local root = new("Frame", {
		Name = "Loading",
		BackgroundTransparency = 1,
		ClipsDescendants = true,
		Size = UDim2.fromScale(1, 1),
		Parent = parent,
	})
	-- The sky cover: all there is to see until the world has arrived.
	local cover = new("Frame", {
		Name = "Cover",
		BackgroundColor3 = WHITE,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1),
		Parent = root,
	})
	local background = new("UIGradient", { Rotation = 90, Parent = cover })

	-- Readability shade under the bottom band only: clear at its top edge.
	local shade = new("Frame", {
		Name = "Shade",
		BackgroundColor3 = colors.Ink,
		BorderSizePixel = 0,
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.fromScale(0, 1),
		Size = UDim2.fromScale(1, 0.4),
		Parent = root,
	})
	new("UIGradient", {
		Rotation = 90,
		Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 1),
			NumberSequenceKeypoint.new(0.45, 0.55),
			NumberSequenceKeypoint.new(1, 0.2),
		}),
		Parent = shade,
	})

	-- Wordmark at the top centre: the logo image, or the title text without it.
	local logo = image("Logo", root, {
		ImageTransparency = UNLOADED,
		ScaleType = Enum.ScaleType.Fit,
		Visible = false,
	})
	local shine = image("Shine", logo, {
		ImageTransparency = 0.15,
		ScaleType = Enum.ScaleType.Fit,
		Size = UDim2.fromScale(1, 1),
		Position = UDim2.fromScale(0.5, 0.5),
		Visible = false,
	})
	local shineGradient = new("UIGradient", {
		Rotation = 18,
		Offset = Vector2.new(-1.5, 0),
		Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 1),
			NumberSequenceKeypoint.new(0.4, 1),
			NumberSequenceKeypoint.new(0.5, 0.1),
			NumberSequenceKeypoint.new(0.6, 1),
			NumberSequenceKeypoint.new(1, 1),
		}),
		Parent = shine,
	})
	local twinkles = {}
	for i, spec in TWINKLES do
		local label = image("Twinkle" .. i, logo, {
			ImageTransparency = 1,
			Position = UDim2.fromScale(spec.x, spec.y),
			Visible = false,
		})
		table.insert(twinkles, { spec = spec, label = label })
	end
	local title = new("TextLabel", {
		Name = "Title",
		BackgroundTransparency = 1,
		Text = "",
		Font = Enum.Font.FredokaOne,
		TextScaled = true,
		TextColor3 = WHITE,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Parent = root,
	})
	local titleStroke = stroke(title, 5, colors.Ink)
	local titleGradient = new("UIGradient", { Rotation = 90, Parent = title })

	-- Bottom band: tagline, progress bar, status, tip card.
	local bottom = new("Frame", {
		Name = "Bottom",
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(BAND.X, BAND.Y),
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.fromScale(0.5, 1),
		Parent = root,
	})
	local bandScale = new("UIScale", { Parent = bottom })
	local tagline = new("TextLabel", {
		Name = "Tagline",
		BackgroundTransparency = 1,
		Text = "",
		Font = Enum.Font.FredokaOne,
		TextSize = 23,
		TextColor3 = WHITE,
		Size = UDim2.new(1, 0, 0, 28),
		Parent = bottom,
	})
	local taglineStroke = stroke(tagline, 3, colors.Ink)

	-- Chunky sunny progress bar: a navy track with a white rim and a moulded
	-- yellow fill (lighter on top, white gloss line, orange lip).
	local track = new("Frame", {
		Name = "Bar",
		BackgroundColor3 = colors.Ink,
		BackgroundTransparency = 0.15,
		BorderSizePixel = 0,
		Size = UDim2.fromOffset(BAR.X, BAR.Y),
		Position = UDim2.new(0.5, 0, 0, BAR_Y),
		AnchorPoint = Vector2.new(0.5, 0),
		Parent = bottom,
	})
	round(track)
	stroke(track, 3, WHITE, 0.05)
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
		Size = UDim2.new(1, 0, 1, -4),
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
		BackgroundTransparency = 0.4,
		BorderSizePixel = 0,
		Size = UDim2.new(1, -16, 0, 4),
		Position = UDim2.fromOffset(8, 4),
		Parent = fill,
	})
	round(gloss)

	-- The aura orb riding the bar's leading edge, with a soft glow behind it.
	local riderGlow = image("RiderGlow", bottom, {
		ImageColor3 = colors.Primary,
		ImageTransparency = 1,
		Size = UDim2.fromOffset(84, 84),
	})
	local rider = image("Rider", bottom, { ImageTransparency = 1, Size = UDim2.fromOffset(50, 50) })

	-- The status has its own line under the bar, clear of the rider (inside the
	-- bar the orb crossed the words and the white text washed out on the fill).
	local status = new("TextLabel", {
		Name = "Status",
		BackgroundTransparency = 1,
		Text = "Loading...",
		Font = Enum.Font.FredokaOne,
		TextSize = 18,
		TextColor3 = WHITE,
		Size = UDim2.fromOffset(BAR.X, 22),
		Position = UDim2.new(0.5, 0, 0, STATUS_Y),
		AnchorPoint = Vector2.new(0.5, 0),
		Parent = bottom,
	})
	local statusStroke = stroke(status, 2.5, colors.Ink)

	-- Tip card: a navy pill with a sunny "TIP" chip.
	local tipPill = new("Frame", {
		Name = "TipPill",
		BackgroundColor3 = colors.Ink,
		BackgroundTransparency = 0.12,
		BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 0, 42),
		Position = UDim2.fromOffset(0, BAND.Y - 42),
		Visible = false,
		Parent = bottom,
	})
	round(tipPill)
	stroke(tipPill, 2, WHITE, 0.45)
	local chip = new("TextLabel", {
		Name = "Chip",
		BackgroundColor3 = colors.Primary,
		BorderSizePixel = 0,
		Text = "TIP",
		Font = Enum.Font.FredokaOne,
		TextSize = 16,
		TextColor3 = colors.Ink,
		Size = UDim2.fromOffset(52, 28),
		Position = UDim2.new(0, 8, 0.5, 0),
		AnchorPoint = Vector2.new(0, 0.5),
		Parent = tipPill,
	})
	round(chip)
	local tip = new("TextLabel", {
		Name = "Tip",
		BackgroundTransparency = 1,
		Text = "",
		Font = Enum.Font.GothamBold,
		TextColor3 = WHITE,
		TextSize = 18,
		TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Left,
		Size = UDim2.new(1, -90, 1, -8),
		Position = UDim2.fromOffset(70, 4),
		Parent = tipPill,
	})

	local tips: { string } = {}
	local tipIndex = 0
	-- One line at full size; a long tip wraps onto two smaller lines.
	local function showTip(text: string)
		tip.Text = text
		tip.TextSize = if #text > 60 then 15 else 18
	end

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
		local fonts = t.Fonts or {}
		title.Text = string.upper(t.GameName or "")
		title.Font = fonts.Title or Enum.Font.FredokaOne
		titleGradient.Color = ColorSequence.new(primary:Lerp(WHITE, 0.45), primary)
		titleStroke.Color = ink
		tagline.Text = t.Tagline or ""
		tagline.Font = fonts.UI or fonts.Bold or Enum.Font.FredokaOne
		taglineStroke.Color = ink
		status.Font = fonts.Title or Enum.Font.FredokaOne
		statusStroke.Color = ink
		tip.Font = fonts.Bold or Enum.Font.GothamBold
		chip.Font = fonts.UI or fonts.Bold or Enum.Font.FredokaOne
		chip.BackgroundColor3 = primary
		chip.TextColor3 = ink
		shade.BackgroundColor3 = ink
		track.BackgroundColor3 = ink
		tipPill.BackgroundColor3 = ink
		riderGlow.ImageColor3 = primary
		fillGradient.Color = ColorSequence.new(primary:Lerp(WHITE, 0.35), primary)
		lipFill.BackgroundColor3 = c.GoldDeep or DEFAULT.PrimaryDeep
		local loading = t.Loading or {}
		status.Text = loading.Status or "Loading..."
		local list = {}
		for _, text in loading.Tips or {} do
			-- The chip already says "TIP".
			local body = string.gsub(text, "^Tip:%s*", "")
			table.insert(list, string.upper(string.sub(body, 1, 1)) .. string.sub(body, 2))
		end
		tips = list
		if #tips > 0 then
			tipIndex = 1
			showTip(tips[1])
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

	local clock = 0
	local logoShownAt: number? = nil
	local alive = true
	-- The sky cover fades once the world may be seen (open); leaving takes the
	-- logo and the band off the screen (finish).
	local opened = false
	local coverK = 0
	local leaving = false
	local leaveT = 0
	local rate = 1
	local connection: RBXScriptConnection? = nil

	local function applyArt(art: Art?)
		-- Art arriving during the fade-out would fight its tweens.
		if not art or not alive then
			return
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
					logoShownAt = clock
					tween(logo, 0.3, { ImageTransparency = 0 })
					tween(title, 0.2, { TextTransparency = 1 })
					tween(titleStroke, 0.2, { Transparency = 1 })
					-- The preview can't draw a gradient-masked image: no shine there.
					shine.Visible = true
				end
				for _, twinkle in twinkles do
					twinkle.label.Visible = true
				end
			end)
		end
		if art.logoShine then
			shine.Image = art.logoShine
		end
		if art.softDot then
			riderGlow.Image = art.softDot
		end
		if art.sparkle then
			for _, twinkle in twinkles do
				twinkle.label.Image = art.sparkle
			end
		end
		local cell = art.orb
		if cell and rider.Image ~= cell.image then
			rider.Image = cell.image
			rider.ImageRectOffset = Vector2.new(cell.x, cell.y)
			rider.ImageRectSize = Vector2.new(cell.w, cell.h)
			rider.ImageTransparency = 0
			riderGlow.ImageTransparency = 0.35
		end
	end
	-- Pick up art that is already there (in Studio and the preview it usually is).
	applyArt(LoadingScreen.findArt(0))

	local nextTip = 5
	local progress = 0.06
	local target = 0.3

	local function layout()
		local camera = workspace.CurrentCamera
		if not camera then
			return
		end
		local size = camera.ViewportSize
		local w, h = size.X, size.Y
		if w < 1 or h < 1 then
			return
		end
		local scale = math.clamp(math.min(w / 1000, h / 620), 0.4, 1.7)
		-- Phones are short: keep the band's text readable there.
		local bandS = math.max(scale, math.min(1, w / 800, h / 480))
		bandScale.Scale = bandS

		-- Leaving: the band dips and drops off the bottom, the logo lifts off the top.
		local away = if leaving then backIn(math.clamp(leaveT / LEAVE, 0, 1)) else 0
		local logoH = LOGO.Y * scale
		local top = math.max(10 * scale, 6)
		local margin = 16 * bandS
		bottom.Position = UDim2.new(0.5, 0, 1, -margin + away * (BAND.Y * bandS + margin + 40))
		shade.Size = UDim2.new(1, 0, 0, BAND.Y * bandS + margin + 90 * bandS)
		shade.BackgroundTransparency = math.clamp(away, 0, 1)

		-- Gentle bob for the logo and title; the logo pops in when it arrives.
		local bob = math.sin(clock * 1.8) * 5 * scale
		local pop = 1
		if logoShownAt then
			pop = 0.75 + 0.25 * backOut(math.clamp((clock - logoShownAt) / 0.45, 0, 1))
		end
		local logoY = top + logoH / 2 + bob - away * (top + logoH * 1.2 + 40)
		logo.Size = UDim2.fromOffset(LOGO.X * scale * pop, logoH * pop)
		logo.Position = UDim2.new(0.5, 0, 0, logoY)
		logo.Rotation = math.sin(clock * 0.9) * 1.2
		title.Size = UDim2.fromOffset(math.min(w * 0.92, 760 * scale), 84 * scale)
		title.Position = UDim2.new(0.5, 0, 0, logoY)

		-- The rider sits on the fill's leading edge.
		local edge = (BAND.X - BAR.X) / 2 + 3 + progress * (BAR.X - 6)
		local riderY = BAR_Y + BAR.Y / 2 + math.sin(clock * 5) * 1.5
		rider.Position = UDim2.fromOffset(edge, riderY)
		rider.Rotation = math.sin(clock * 2.6) * 10
		riderGlow.Position = UDim2.fromOffset(edge, riderY)
		riderGlow.ImageTransparency = if rider.Image ~= "" then 0.35 + 0.2 * math.sin(clock * 3) else 1

		for _, twinkle in twinkles do
			local spec = twinkle.spec
			local k = math.max(0, math.sin(clock * spec.speed + spec.phase))
			local d = logoH * spec.size * (0.35 + 0.65 * k)
			twinkle.label.Size = UDim2.fromOffset(d, d)
			twinkle.label.Rotation = clock * 30 + spec.phase * 40
			twinkle.label.ImageTransparency = 1 - k
		end

		-- A band of light sweeps across the logo every few seconds.
		if logoShownAt then
			local t = ((clock - logoShownAt) % SHINE_EVERY) / SHINE_TIME
			shineGradient.Offset = Vector2.new(if t < 1 then -0.8 + 1.6 * t else -1.5, 0)
		end
	end

	local function showProgress()
		local r = math.clamp(progress, 0.06, 1)
		lipFill.Size = UDim2.new(r, -6 * r, 1, -6)
	end
	showProgress()

	connection = RunService.RenderStepped:Connect(function(dt)
		dt *= rate
		clock += dt
		if opened and coverK < 1 then
			coverK = math.min(1, coverK + dt / OPEN)
			cover.BackgroundTransparency = smooth(coverK)
			cover.Visible = coverK < 1
		end
		if leaving then
			leaveT += dt
			if leaveT >= LEAVE then
				if connection then
					connection:Disconnect()
				end
				root:Destroy()
				return
			end
		end
		-- The bar eases toward the stage the loader has reached and fills on finish.
		progress += (target - progress) * math.min(1, dt * (if alive then 1.6 else 8))
		showProgress()
		if clock >= nextTip and #tips > 1 and alive then
			nextTip = clock + 5
			tipIndex = tipIndex % #tips + 1
			local nextText = tips[tipIndex]
			tween(tip, 0.18, { TextTransparency = 1 })
			task.delay(0.2, function()
				if alive then
					showTip(nextText)
					tween(tip, 0.25, { TextTransparency = 0 })
				end
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
		layout()
	end)
	layout()

	local function finish(speed: number?): number
		if not alive then
			return 0
		end
		alive = false
		target = 1
		table.clear(pending)
		opened = true
		leaving = true
		rate = speed or 1
		return LEAVE / rate
	end

	return {
		root = root,
		applyTheme = applyTheme,
		applyArt = applyArt,
		setStatus = function(text: string)
			status.Text = text
		end,
		-- How far the load has come (0..1); the bar eases there.
		setProgress = function(p: number)
			if alive then
				target = math.max(target, math.clamp(p, 0, 0.97))
			end
		end,
		open = function(speed: number?)
			opened = true
			rate = speed or 1
		end,
		finish = finish,
	}
end

return LoadingScreen
