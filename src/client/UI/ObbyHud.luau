--!strict
--[[
	ObbyHud: the sky obby's run HUD (docs/sky-obby.md, Client), styled like a classic
	rainbow obby. Shown while the local player is on a parkour run (Main calls show on the
	run's start Notify) and hidden on finish / stop / invalid (Main calls hide).

	  Bar       top centre (y 14, 46% of the width): a chunky rainbow bar (UIGradient) with
	            a trophy at its end; the stretch past the local player is dimmed. Every
	            player with a ParkourStage attribute above 0 rides its top edge as a round
	            avatar head (Players:GetUserThumbnailAsync HeadShot 48 px, cached per user)
	            at ParkourStage / stageCount; the local head sits on top with a white caret
	            under the bar. Attributes are followed live (PlayerAdded / Removing too).
	  Row       one line under the bar: Hud's run pill (docked through deps.dockRun) on the
	            left, "STAGE n / N" in the centre, SKIP STAGE (pink, with the Rizz cost from
	            Economy.PARKOUR_SKIP_GEMS, else 15; fires ParkourSkip) on the right.
	  Gear      a 3-slot hotbar 8 px above the dumbbell (deps.tank): Speed, Jump and Gravity
	            coils with key badges 1 / 2 / 3. Keys or a tap toggle; the chosen slot is
	            outlined gold; tapping it again picks "none". Fires ParkourGear { gear } and
	            follows State.data.modes.parkour.gear.

	Phones (viewport under 700 px wide): the bar takes 70% of the width and the row wraps to
	two lines (timer + stage, then skip). Every engine call that the Lune preview cannot run
	(thumbnails, AbsoluteSize) is wrapped in pcall.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Net = require(ReplicatedStorage.Shared.Net)

local Kit = require(script.Parent.Kit)
local State = require(script.Parent.Parent.State)

local C = Kit.C
local F = Kit.F
local World = (Kit.Theme :: any).World

local ObbyHud = {}

-- Filled in by build(); safe no-ops before that.
ObbyHud.show = function(_stage: number?, _stageCount: number?) end
ObbyHud.setStage = function(_stage: number?, _stageCount: number?) end
ObbyHud.hide = function() end
ObbyHud.isShown = function(): boolean
	return false
end

export type Deps = {
	sounds: any?,
	-- Hud.dockRun: moves the run pill into the row (nil puts it back).
	dockRun: ((UDim2?, Vector2?) -> ())?,
	-- Hud's dumbbell group: the hotbar rides 8 px above it.
	tank: GuiObject?,
}

-- Layout (design px, 1280x720).
local BAR_Y = 14
local BAR_H = 22
local BAR_FRACTION = 0.46
local BAR_FRACTION_PHONE = 0.7
local PHONE_PX = 700 -- viewport px
local HEAD = 40
local CARET_H = 12 -- the local caret under the bar
local ROW_Y = BAR_Y + BAR_H + CARET_H + 8 -- the row clears the heads and the caret
local ROW_H = 46
local ROW_GAP = 12
local RUN_W = 236 -- Hud's run pill
local STAGE_W = 190
local SKIP_W = 186
local SLOT = 66
local SLOT_GAP = 10
local HOTBAR_GAP = 8
local HOTBAR_BOTTOM = 129 -- fallback: Hud's dumbbell (264 * 448 / 1024 + 6) + 8
local DEFAULT_SKIP = 15

local RAINBOW_KEYS =
	{ "RainbowRed", "RainbowOrange", "RainbowYellow", "RainbowGreen", "RainbowCyan", "RainbowBlue", "RainbowPurple", "RainbowPink" }
local RAINBOW_FALLBACK = {
	Color3.fromRGB(255, 80, 80),
	Color3.fromRGB(255, 150, 50),
	Color3.fromRGB(255, 225, 60),
	Color3.fromRGB(90, 220, 100),
	Color3.fromRGB(70, 220, 230),
	Color3.fromRGB(70, 140, 255),
	Color3.fromRGB(170, 110, 255),
	Color3.fromRGB(255, 120, 200),
}
local WHITE = Color3.new(1, 1, 1)
local GOLD = C.Gold

type GearDef = { key: string, label: string, color: Color3, keyCode: Enum.KeyCode }
local GEARS: { GearDef } = {
	{ key = "speed", label = "SPEED", color = Color3.fromRGB(255, 80, 80), keyCode = Enum.KeyCode.One },
	{ key = "jump", label = "JUMP", color = Color3.fromRGB(90, 220, 100), keyCode = Enum.KeyCode.Two },
	{ key = "gravity", label = "GRAVITY", color = Color3.fromRGB(170, 110, 255), keyCode = Enum.KeyCode.Three },
}

local function rainbow(i: number): Color3
	local color = World and World[RAINBOW_KEYS[i]]
	return if typeof(color) == "Color3" then color else RAINBOW_FALLBACK[i]
end

local function skipCost(): number
	local ok, Economy = pcall(require, ReplicatedStorage.Shared.Economy)
	local cost = if ok and type(Economy) == "table" then tonumber((Economy :: any).PARKOUR_SKIP_GEMS) else nil
	return cost or DEFAULT_SKIP
end

-- The course's last stage from the world: Parkour folder's Levels and the last level
-- folder's StageLast (0 when the world is not there yet).
local function worldStageCount(): number
	local map = workspace:FindFirstChild("Map")
	local modes = map and map:FindFirstChild("GameModes")
	local parkour = modes and modes:FindFirstChild("Parkour")
	if not parkour then
		return 0
	end
	local best = 0
	local levels = tonumber(parkour:GetAttribute("Levels")) or 0
	local last = if levels > 0 then parkour:FindFirstChild("Level" .. levels) else nil
	if last then
		best = tonumber(last:GetAttribute("StageLast")) or 0
	end
	if best <= 0 then
		for _, child in parkour:GetChildren() do
			best = math.max(best, tonumber(child:GetAttribute("StageLast")) or 0)
		end
	end
	return best
end

-- Avatar headshots, fetched once per user (nil while loading or when unavailable).
local thumbs: { [number]: string } = {}
local pending: { [number]: { (string) -> () } } = {}
local function headshot(userId: number, onReady: (string) -> ())
	local cached = thumbs[userId]
	if cached then
		onReady(cached)
		return
	end
	if userId <= 0 then
		return -- Studio test players have no avatar
	end
	local waiting = pending[userId]
	if waiting then
		table.insert(waiting, onReady)
		return
	end
	pending[userId] = { onReady }
	task.spawn(function()
		local ok, image = pcall(function()
			return Players:GetUserThumbnailAsync(userId, Enum.ThumbnailType.HeadShot, Enum.ThumbnailSize.Size48x48)
		end)
		local callbacks: { (string) -> () } = pending[userId] or {}
		pending[userId] = nil
		if ok and type(image) == "string" and image ~= "" then
			thumbs[userId] = image
			for _, callback in callbacks do
				callback(image)
			end
		end
	end)
end

-- A coil spring glyph: a little grey handle over five overlapping rings in `color`.
local function coil(parent: Instance, color: Color3, size: number): Frame
	local root = Kit.new("Frame", {
		Name = "Coil",
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(size, size),
		Position = UDim2.new(0.5, 0, 0, 6),
		AnchorPoint = Vector2.new(0.5, 0),
		ZIndex = 3,
		Parent = parent,
	})
	local handle = Kit.new("Frame", {
		Name = "Handle",
		BackgroundColor3 = Color3.fromRGB(120, 128, 150),
		Size = UDim2.new(0.22, 0, 0.2, 0),
		Position = UDim2.fromScale(0.5, 0),
		AnchorPoint = Vector2.new(0.5, 0),
		ZIndex = 3,
		Parent = root,
	})
	Kit.corner(handle, 3)
	local rings = 5
	for i = 1, rings do
		local ring = Kit.new("Frame", {
			Name = "Ring" .. i,
			BackgroundTransparency = 1,
			Size = UDim2.new(0.82, 0, 0.2, 0),
			Position = UDim2.new(0.5, 0, 0.16 + (i - 1) * 0.15, 0),
			AnchorPoint = Vector2.new(0.5, 0),
			ZIndex = 4,
			Parent = root,
		})
		Kit.round(ring)
		Kit.new("UIStroke", {
			Thickness = 3.5,
			Color = if i % 2 == 0 then Kit.lighten(color, 0.25) else color,
			Parent = ring,
		})
	end
	return root
end

function ObbyHud.build(screen: ScreenGui, deps: Deps?)
	local dockRun = deps and deps.dockRun
	local tank = deps and deps.tank
	local action = Net.event("Action")
	local me = Players.LocalPlayer
	local shown = false
	local myStage = 0
	local stageCount = 0
	local cost = skipCost()

	local root = Kit.new("Frame", {
		Name = "ObbyHud",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		Visible = false,
		Parent = screen,
	})

	-- Bar --------------------------------------------------------------------------------
	local barHolder = Kit.new("Frame", {
		Name = "Bar",
		BackgroundTransparency = 1,
		Size = UDim2.new(BAR_FRACTION, 0, 0, BAR_H),
		Position = UDim2.new(0.5, 0, 0, BAR_Y),
		AnchorPoint = Vector2.new(0.5, 0),
		Parent = root,
	})
	local track = Kit.new("Frame", {
		Name = "Track",
		BackgroundColor3 = WHITE,
		Size = UDim2.fromScale(1, 1),
		ZIndex = 2,
		Parent = barHolder,
	})
	Kit.round(track)
	Kit.new("UIStroke", { Thickness = 3, Color = C.Ink, Parent = track })
	local keypoints = {}
	for i = 1, #RAINBOW_KEYS do
		table.insert(keypoints, ColorSequenceKeypoint.new((i - 1) / (#RAINBOW_KEYS - 1), rainbow(i)))
	end
	Kit.new("UIGradient", { Color = ColorSequence.new(keypoints), Parent = track })
	-- A glossy top half.
	local gloss = Kit.new("Frame", {
		Name = "Gloss",
		BackgroundColor3 = WHITE,
		BackgroundTransparency = 0.6,
		Size = UDim2.new(1, -10, 0.36, 0),
		Position = UDim2.new(0.5, 0, 0, 2),
		AnchorPoint = Vector2.new(0.5, 0),
		ZIndex = 3,
		Parent = track,
	})
	Kit.round(gloss)
	-- The stretch still ahead of the local player, dimmed.
	local ahead = Kit.new("Frame", {
		Name = "Ahead",
		BackgroundColor3 = C.Ink,
		BackgroundTransparency = 0.5,
		Size = UDim2.fromScale(1, 1),
		Position = UDim2.fromScale(1, 0),
		AnchorPoint = Vector2.new(1, 0),
		ZIndex = 4,
		Parent = track,
	})
	Kit.round(ahead)
	-- Start dot and trophy.
	local startDot = Kit.new("Frame", {
		Name = "Start",
		BackgroundColor3 = WHITE,
		Size = UDim2.fromOffset(BAR_H + 6, BAR_H + 6),
		Position = UDim2.new(0, 0, 0.5, 0),
		AnchorPoint = Vector2.new(0.5, 0.5),
		ZIndex = 5,
		Parent = barHolder,
	})
	Kit.round(startDot)
	Kit.new("UIStroke", { Thickness = 3, Color = C.Ink, Parent = startDot })
	local trophyBack = Kit.new("Frame", {
		Name = "Trophy",
		BackgroundColor3 = GOLD,
		Size = UDim2.fromOffset(46, 46),
		Position = UDim2.new(1, 8, 0.5, 0),
		AnchorPoint = Vector2.new(0.5, 0.5),
		ZIndex = 6,
		Parent = barHolder,
	})
	Kit.round(trophyBack)
	Kit.new("UIStroke", { Thickness = 3, Color = C.Ink, Parent = trophyBack })
	Kit.gradient(trophyBack, Kit.lighten(GOLD, 0.3), GOLD)
	Kit.icon(trophyBack, "Ranking", 30, C.GoldInk, {
		Position = UDim2.fromScale(0.5, 0.5),
		AnchorPoint = Vector2.new(0.5, 0.5),
		ZIndex = 7,
	})

	-- Heads.
	type Head = { frame: Frame, image: ImageLabel, conn: RBXScriptConnection?, stage: number }
	local heads: { [Player]: Head } = {}
	local function headX(stage: number): number
		local total = if stageCount > 0 then stageCount else math.max(stage, 1)
		return math.clamp(stage / total, 0, 1)
	end
	local function makeHead(p: Player): Head
		local mine = p == me
		local size = HEAD
		local frame = Kit.new("Frame", {
			Name = "Head" .. p.UserId,
			BackgroundColor3 = Color3.fromRGB(205, 220, 245),
			Size = UDim2.fromOffset(size, size),
			Position = UDim2.new(0, 0, 1, 2),
			AnchorPoint = Vector2.new(0.5, 1),
			ZIndex = if mine then 12 else 8,
			Parent = barHolder,
		})
		Kit.round(frame)
		Kit.new("UIStroke", { Thickness = if mine then 3.5 else 2.5, Color = if mine then WHITE else C.Ink, Parent = frame })
		local initial = Kit.text(frame, {
			Name = "Initial",
			Text = string.upper(string.sub(p.DisplayName ~= "" and p.DisplayName or p.Name, 1, 1)),
			Font = F.Display,
			TextSize = math.floor(size * 0.5),
			TextColor3 = C.Ink,
			StrokeThickness = 0,
			ZIndex = frame.ZIndex + 1,
		})
		local image = Kit.new("ImageLabel", {
			Name = "Avatar",
			BackgroundTransparency = 1,
			Size = UDim2.fromScale(1, 1),
			Image = "",
			ZIndex = frame.ZIndex + 2,
			Parent = frame,
		})
		Kit.round(image)
		if mine then
			-- White caret under the local head (below the bar, above the row).
			local caret = Kit.text(frame, {
				Name = "Caret",
				Text = "▲",
				Font = F.Display,
				TextSize = 14,
				TextColor3 = WHITE,
				Size = UDim2.fromOffset(18, CARET_H),
				Position = UDim2.new(0.5, 0, 1, 0),
				AnchorPoint = Vector2.new(0.5, 0),
				ZIndex = frame.ZIndex + 3,
			})
			Kit.textStroke(caret, 2, 0)
		end
		headshot(p.UserId, function(id)
			if image.Parent then
				image.Image = id
				initial.Visible = false
			end
		end)
		return { frame = frame, image = image, conn = nil, stage = 0 }
	end

	local function placeHead(p: Player, stage: number, animate: boolean)
		local head = heads[p]
		if stage <= 0 and p ~= me then
			if head then
				head.frame.Visible = false
				head.stage = 0
			end
			return
		end
		if not head then
			head = makeHead(p)
			heads[p] = head
		end
		local h = head :: Head
		h.frame.Visible = true
		-- Bottoms just under the bar's bottom edge: the heads ride on top of it.
		local target = UDim2.new(headX(stage), 0, 1, 2)
		if animate and h.stage > 0 and shown then
			Kit.tween(h.frame, 0.45, { Position = target }, Enum.EasingStyle.Back)
		else
			h.frame.Position = target
		end
		h.stage = stage
	end

	local function stageOf(p: Player): number
		return tonumber(p:GetAttribute("ParkourStage")) or 0
	end

	-- Re-places every head (the stage count changed).
	local function placeAll()
		for _, p in Players:GetPlayers() do
			if p == me then
				placeHead(p, myStage, false)
			else
				placeHead(p, stageOf(p), false)
			end
		end
		ahead.Size = UDim2.fromScale(1 - headX(myStage), 1)
	end

	local watched: { [Player]: RBXScriptConnection } = {}
	local function watch(p: Player)
		if watched[p] or p == me then
			return
		end
		watched[p] = p:GetAttributeChangedSignal("ParkourStage"):Connect(function()
			placeHead(p, stageOf(p), true)
		end)
		placeHead(p, stageOf(p), false)
	end
	for _, p in Players:GetPlayers() do
		watch(p)
	end
	Players.PlayerAdded:Connect(watch)
	Players.PlayerRemoving:Connect(function(p)
		local conn = watched[p]
		if conn then
			conn:Disconnect()
			watched[p] = nil
		end
		local head = heads[p]
		if head then
			head.frame:Destroy()
			heads[p] = nil
		end
	end)

	-- Counter and skip -----------------------------------------------------------------
	local counter = Kit.hudText(root, {
		Name = "Stage",
		Text = "STAGE 1",
		RichText = true,
		Font = F.Display,
		TextSize = 30,
		StrokeThickness = 3,
		Size = UDim2.fromOffset(STAGE_W, ROW_H),
		Position = UDim2.new(0.5, 0, 0, ROW_Y),
		AnchorPoint = Vector2.new(0.5, 0),
	})
	local counterScale = Kit.new("UIScale", { Parent = counter })
	local skip = Kit.button(root, {
		Name = "Skip",
		Text = "SKIP STAGE  " .. tostring(cost),
		Icon = "Gem",
		IconColor = C.Rizz,
		Font = F.Display,
		Color = Color3.fromRGB(255, 95, 150),
		TextSize = 17,
		Size = UDim2.fromOffset(SKIP_W, ROW_H),
		Position = UDim2.new(0.5, STAGE_W / 2 + ROW_GAP, 0, ROW_Y),
	}, function()
		if not shown then
			return
		end
		action:FireServer({ action = "ParkourSkip" })
	end)

	local function renderCounter()
		local total = if stageCount > 0 then string.format(' <font size="18" transparency="0.25">/ %d</font>', stageCount) else ""
		counter.Text = string.format("STAGE %d%s", math.max(myStage, 1), total)
	end

	-- Gear hotbar --------------------------------------------------------------------------
	local hotbar = Kit.new("Frame", {
		Name = "Gear",
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(SLOT * 3 + SLOT_GAP * 2, SLOT + 14),
		Position = UDim2.new(0.5, 0, 1, -HOTBAR_BOTTOM),
		AnchorPoint = Vector2.new(0.5, 1),
		Parent = root,
	})
	local chosen = "none"
	type Slot = { button: TextButton, stroke: UIStroke, scale: UIScale, def: GearDef }
	local slots: { Slot } = {}
	local function renderGear()
		for _, slot in slots do
			local on = slot.def.key == chosen
			slot.stroke.Color = if on then GOLD else WHITE
			slot.stroke.Thickness = if on then 4.5 else 2.5
			Kit.tween(slot.scale, 0.15, { Scale = if on then 1.08 else 1 }, Enum.EasingStyle.Back)
			slot.button.BackgroundTransparency = if on then 0.15 else 0.35
		end
	end
	local function pick(key: string)
		if not shown then
			return
		end
		chosen = if chosen == key then "none" else key
		renderGear()
		Kit.sound("Click")
		action:FireServer({ action = "ParkourGear", gear = chosen })
	end
	for i, def in GEARS do
		local button = Kit.new("TextButton", {
			Name = def.label,
			Text = "",
			AutoButtonColor = false,
			BackgroundColor3 = C.Ink,
			BackgroundTransparency = 0.35,
			Size = UDim2.fromOffset(SLOT, SLOT),
			Position = UDim2.fromOffset((i - 1) * (SLOT + SLOT_GAP), 0),
			Parent = hotbar,
		})
		Kit.corner(button, 12)
		Kit.selectable(button)
		local stroke = Kit.new("UIStroke", {
			Thickness = 2.5,
			Color = WHITE,
			ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
			Parent = button,
		})
		local scale = Kit.new("UIScale", { Parent = button })
		coil(button, def.color, 38)
		Kit.hudText(button, {
			Name = "Label",
			Text = def.label,
			Font = F.UI,
			TextSize = 12,
			StrokeThickness = 1.5,
			Size = UDim2.new(1, 0, 0, 14),
			Position = UDim2.new(0.5, 0, 1, -3),
			AnchorPoint = Vector2.new(0.5, 1),
			ZIndex = 5,
		})
		-- Key badge in the top-left corner, like a Roblox backpack slot.
		local badge = Kit.new("Frame", {
			Name = "Key",
			BackgroundColor3 = C.Ink,
			Size = UDim2.fromOffset(20, 20),
			Position = UDim2.fromOffset(-5, -5),
			ZIndex = 6,
			Parent = button,
		})
		Kit.round(badge)
		Kit.new("UIStroke", { Thickness = 2, Color = WHITE, Parent = badge })
		Kit.hudText(badge, {
			Name = "Number",
			Text = tostring(i),
			Font = F.Display,
			TextSize = 14,
			StrokeThickness = 0,
			Size = UDim2.fromScale(1, 1),
			ZIndex = 7,
		})
		button.Activated:Connect(function()
			pick(def.key)
		end)
		table.insert(slots, { button = button, stroke = stroke, scale = scale, def = def })
	end
	UserInputService.InputBegan:Connect(function(input, processed)
		if processed or not shown or input.UserInputType ~= Enum.UserInputType.Keyboard then
			return
		end
		for _, def in GEARS do
			if input.KeyCode == def.keyCode then
				pick(def.key)
			end
		end
	end)

	local function syncGear()
		local data = State.data
		local info = data and data.modes and data.modes.parkour
		local gear = if type(info) == "table" then info.gear else nil
		local key = if type(gear) == "string" then gear else "none"
		if key ~= chosen then
			chosen = key
			renderGear()
		end
	end
	State.changed.Event:Connect(syncGear)

	-- Layout -----------------------------------------------------------------------------
	local function viewport(): Vector2
		local ok, size = pcall(function()
			return screen.AbsoluteSize
		end)
		return if ok and typeof(size) == "Vector2" and size.X > 0 then size else Vector2.new(1280, 720)
	end
	-- Row positions, as offsets from the screen centre (design px). Desktop:
	-- [run pill][STAGE n / N][SKIP] on one line, the stage centred. Phones: the run pill
	-- and the stage share line 1, the skip button is centred on line 2.
	local phone = false
	local function rowLayout(): (UDim2, Vector2)
		phone = viewport().X < PHONE_PX
		barHolder.Size = UDim2.new(if phone then BAR_FRACTION_PHONE else BAR_FRACTION, 0, 0, BAR_H)
		counter.AnchorPoint = Vector2.new(0.5, 0)
		counter.TextXAlignment = Enum.TextXAlignment.Center
		skip.AnchorPoint = Vector2.new(0.5, 0)
		local runPos: UDim2
		if phone then
			-- Line 1: [run pill][stage] centred as a pair; line 2: skip.
			local left = -(RUN_W + ROW_GAP + STAGE_W) / 2
			runPos = UDim2.new(0.5, left + RUN_W, 0, ROW_Y)
			counter.Position = UDim2.new(0.5, left + RUN_W + ROW_GAP + STAGE_W / 2, 0, ROW_Y)
			skip.Position = UDim2.new(0.5, 0, 0, ROW_Y + ROW_H + 8)
		else
			runPos = UDim2.new(0.5, -STAGE_W / 2 - ROW_GAP, 0, ROW_Y)
			counter.Position = UDim2.new(0.5, 0, 0, ROW_Y)
			skip.Position = UDim2.new(0.5, STAGE_W / 2 + ROW_GAP + SKIP_W / 2, 0, ROW_Y)
		end
		-- The run pill is anchored by its right edge so "QUIT?" widens it to the left,
		-- away from the stage counter.
		return runPos, Vector2.new(1, 0)
	end
	local function placeHotbar()
		local y = -HOTBAR_BOTTOM
		local x = 0
		if tank then
			local pos, size = tank.Position, tank.Size
			-- The dumbbell is anchored bottom centre (Hud): its top is pos.Y - height.
			y = pos.Y.Offset - size.Y.Offset * tank.AnchorPoint.Y - HOTBAR_GAP
			x = pos.X.Offset
			hotbar.Position = UDim2.new(pos.X.Scale, x, pos.Y.Scale, y)
			return
		end
		local compact = screen:GetAttribute("Compact") == true
		hotbar.Position = UDim2.new(0.5, x, 1, if compact then -100 else y)
	end
	local function relayout()
		local runPos, runAnchor = rowLayout()
		if shown and dockRun then
			dockRun(runPos, runAnchor)
		end
		placeHotbar()
	end
	relayout()
	pcall(function()
		screen:GetPropertyChangedSignal("AbsoluteSize"):Connect(relayout)
	end)
	screen:GetAttributeChangedSignal("Compact"):Connect(relayout)
	if tank then
		-- Follows the dumbbell as it resizes (compact) or slides away under a window.
		tank:GetPropertyChangedSignal("Position"):Connect(placeHotbar)
		tank:GetPropertyChangedSignal("Size"):Connect(placeHotbar)
	end

	-- API ----------------------------------------------------------------------------------
	local function setCount(count: number?)
		local n = tonumber(count) or 0
		if n <= 0 then
			n = worldStageCount()
		end
		if n > 0 and n ~= stageCount then
			stageCount = n
			placeAll()
		end
	end

	ObbyHud.setStage = function(stage: number?, count: number?)
		setCount(count)
		local n = tonumber(stage) or myStage
		local changed = n ~= myStage
		myStage = n
		placeHead(me, myStage, true)
		Kit.tween(ahead, 0.45, { Size = UDim2.fromScale(1 - headX(myStage), 1) }, Enum.EasingStyle.Quad)
		renderCounter()
		if changed and shown then
			counterScale.Scale = 1.3
			Kit.tween(counterScale, 0.3, { Scale = 1 }, Enum.EasingStyle.Back)
		end
	end

	ObbyHud.show = function(stage: number?, count: number?)
		local was = shown
		shown = true
		root.Visible = true
		syncGear()
		renderGear()
		relayout() -- docks Hud's run pill into the row
		ObbyHud.setStage(stage, count)
		if not was then
			-- The bar drops in from above the screen.
			barHolder.Position = UDim2.new(0.5, 0, 0, BAR_Y - 60)
			Kit.tween(barHolder, 0.35, { Position = UDim2.new(0.5, 0, 0, BAR_Y) }, Enum.EasingStyle.Back)
			Kit.appear(hotbar, { from = 0.6, time = 0.3, delay = 0.08 })
		end
	end

	ObbyHud.hide = function()
		if not shown then
			return
		end
		shown = false
		root.Visible = false
		if dockRun then
			dockRun(nil, nil)
		end
	end

	ObbyHud.isShown = function(): boolean
		return shown
	end

	renderCounter()
	renderGear()
	setCount(nil)
end

return ObbyHud
