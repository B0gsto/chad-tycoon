--!strict
--[[
	ObbyHud: the sky obby's run HUD (docs/sky-obby.md, Client), styled like a classic
	rainbow obby. Shown while the local player is on a parkour run (Main calls show on the
	run's start Notify) and hidden on finish / stop / invalid (Main calls hide).

	  Bar       top centre (y 14, 46% of the width): a chunky rainbow bar (UIGradient) with
	            a trophy at its end. It is THIS MAP, start deck to finish deck: the local
	            player's round avatar head (Players:GetUserThumbnailAsync HeadShot 48 px,
	            cached per user) rides its top edge at the player attribute "ParkourProgress"
	            (0..1 along the map's path, set by the server), with a white caret under the
	            bar, and the stretch still ahead is dimmed. Other players running the same
	            map (their "ParkourStage" attribute equals ours) ride it too. Attributes are
	            followed live (PlayerAdded / Removing too).
	  Row       one line under the bar: Hud's run pill (docked through deps.dockRun) on the
	            left, "MAP n / N · <map name>" in the centre (a stage is a map: N =
	            stageCount - 1, map 10's finish being the last stage), a small grey SKIP MAP
	            (with the cash cost from State.data.modes.parkour.skipCost, refreshed on
	            State.changed) on the right. Under the run pill: "Best 0:34.4 · Falls 2"
	            (the map's best time from the start Notify, this run's falls from the respawn
	            Notify). There are no checkpoints.
	  Skip      SKIP MAP only opens a small card under the row: "Skip <map> for $250? You
	            get no reward for a skipped map." with YES, SKIP / NO. YES fires ParkourSkip
	            (the server only unlocks the next map, ends the run and opens the picker at
	            the gates); NO, eight seconds or the end of the run close it.
	  Chip      "ASSISTED: no best time" under the counter from the moment gear is worn in
	            this run (the start Notify, the snapshot's `assisted`, or a coil picked here).
	  Oops      "Oops! Back to the start" in the middle of the screen for 1.5 s on every
	            respawn Notify (a fall or lava).
	  Gear      a 3-slot hotbar 8 px above the dumbbell (deps.tank): Speed, Jump and Gravity
	            coils with key badges 1 / 2 / 3. Keys or a tap toggle; the chosen slot is
	            outlined gold; tapping it again picks "none". Fires ParkourGear { gear } and
	            follows State.data.modes.parkour.gear.

	Phones (viewport under 700 px wide): the bar takes 70% of the width and the row wraps to
	two lines (timer + "MAP n / N", then the map name with best / falls and skip). Every
	engine call that the Lune preview cannot run (thumbnails, AbsoluteSize) is wrapped in
	pcall.

	ObbyHud listens to the Notify remote itself for what Main does not pass on (the start
	payload's best / levelName / assisted and the respawn payload's falls).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Format = require(ReplicatedStorage.Shared.Format)
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
local RUN_H = 36
local STAGE_W = 350 -- "MAP n / N · <map name>"
local STAGE_W_PHONE = 190 -- "MAP n / N"
local STATS_W_PHONE = 250 -- "<map name> · Best · Falls" on a phone's second line
local STATS_H = 20
local SKIP_W = 150
local SKIP_H = 34
local CHIP_H = 26
local CONFIRM_W = 400
local CONFIRM_H = 136
-- Seconds the skip question stays up unanswered, and the "Oops!" line after a fall.
local CONFIRM_SECONDS = 8
local OOPS_SECONDS = 1.5
local SLOT = 66
local SLOT_GAP = 10
local HOTBAR_GAP = 8
local HOTBAR_BOTTOM = 129 -- fallback: Hud's dumbbell (264 * 448 / 1024 + 6) + 8

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

-- The cash cost of a skip from the parkour snapshot (nil before the first snapshot).
local function skipCost(): number?
	local data = State.data
	local info = data and data.modes and data.modes.parkour
	return if type(info) == "table" then tonumber(info.skipCost) else nil
end

local function skipText(cost: number?): string
	return if cost then "SKIP MAP  " .. Format.money(cost) else "SKIP MAP"
end

-- The snapshot's entry for map `level` (name, best, ...), nil before the first snapshot.
local function levelInfo(level: number): { [string]: any }?
	local data = State.data
	local info = data and data.modes and data.modes.parkour
	local list = if type(info) == "table" then info.levels else nil
	local entry = if type(list) == "table" then list[level] else nil
	return if type(entry) == "table" then entry else nil
end

-- "0:34.4", like Hud's run clock.
local function clockText(seconds: number): string
	local tenths = math.floor(math.max(seconds, 0) * 10)
	return string.format("%d:%02d.%d", tenths // 600, (tenths // 10) % 60, tenths % 10)
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
	-- This run, from the Notify remote: the start payload (its map, name and best time),
	-- the falls so far and whether gear was worn.
	local started: { level: number, name: string?, best: number? }? = nil
	local falls = 0
	local assisted = false

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
	type Head = { frame: Frame, image: ImageLabel, placed: boolean }
	local heads: { [Player]: Head } = {}
	local function stageOf(p: Player): number
		return tonumber(p:GetAttribute("ParkourStage")) or 0
	end
	-- How far along its map's path a player is (0..1).
	local function progressOf(p: Player): number
		local progress = tonumber(p:GetAttribute("ParkourProgress")) or 0
		return if progress == progress then math.clamp(progress, 0, 1) else 0
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
		return { frame = frame, image = image, placed = false }
	end

	-- Puts a player's head where they are along the map. Only the local player and players
	-- on the same map are on the bar.
	local function placeHead(p: Player, animate: boolean)
		local head = heads[p]
		if p ~= me and (myStage <= 0 or stageOf(p) ~= myStage) then
			if head then
				head.frame.Visible = false
				head.placed = false
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
		local progress = progressOf(p)
		local target = UDim2.new(progress, 0, 1, 2)
		local glide = animate and h.placed and shown
		if glide then
			Kit.tween(h.frame, 0.3, { Position = target }, Enum.EasingStyle.Quad)
		else
			h.frame.Position = target
		end
		h.placed = true
		if p == me then
			local left = UDim2.fromScale(1 - progress, 1)
			if glide then
				Kit.tween(ahead, 0.3, { Size = left }, Enum.EasingStyle.Quad)
			else
				ahead.Size = left
			end
		end
	end

	-- Re-places every head (the local player's map changed).
	local function placeAll()
		for _, p in Players:GetPlayers() do
			placeHead(p, false)
		end
	end

	local watched: { [Player]: { RBXScriptConnection } } = {}
	local function watch(p: Player)
		if watched[p] then
			return
		end
		local function moved()
			placeHead(p, true)
		end
		local conns = { p:GetAttributeChangedSignal("ParkourProgress"):Connect(moved) }
		if p ~= me then
			-- (The local player's map comes from Main through setStage.)
			table.insert(conns, p:GetAttributeChangedSignal("ParkourStage"):Connect(moved))
		end
		watched[p] = conns
		placeHead(p, false)
	end
	for _, p in Players:GetPlayers() do
		watch(p)
	end
	Players.PlayerAdded:Connect(watch)
	Players.PlayerRemoving:Connect(function(p)
		local conns = watched[p]
		if conns then
			for _, conn in conns do
				conn:Disconnect()
			end
			watched[p] = nil
		end
		local head = heads[p]
		if head then
			head.frame:Destroy()
			heads[p] = nil
		end
	end)

	-- Counter and skip -----------------------------------------------------------------
	local phone = false
	local counter = Kit.hudText(root, {
		Name = "Stage",
		Text = "MAP 1",
		RichText = true,
		Font = F.Display,
		TextSize = 26,
		StrokeThickness = 3,
		TextWrapped = false,
		Size = UDim2.fromOffset(STAGE_W, RUN_H),
		Position = UDim2.new(0.5, 0, 0, ROW_Y),
		AnchorPoint = Vector2.new(0.5, 0),
	})
	local counterScale = Kit.new("UIScale", { Parent = counter })
	-- "Best 0:34.4 · Falls 2" under the run pill (on phones: the second line, with the map
	-- name in front).
	local stats = Kit.hudText(root, {
		Name = "Stats",
		Text = "",
		RichText = true,
		Font = F.UI,
		TextSize = 15,
		StrokeThickness = 2,
		TextWrapped = false,
		Size = UDim2.fromOffset(RUN_W, STATS_H),
		Position = UDim2.new(0.5, -STAGE_W / 2 - ROW_GAP, 0, ROW_Y + RUN_H + 2),
		AnchorPoint = Vector2.new(1, 0),
	})
	local statsScale = Kit.new("UIScale", { Parent = stats })
	-- "ASSISTED: no best time" from the moment gear is worn in this run.
	local chip = Kit.pill(root, {
		Name = "Assisted",
		Text = "ASSISTED: no best time",
		Font = F.Display,
		TextSize = 14,
		Color = C.Rizz,
		Solid = true,
		Size = UDim2.fromOffset(210, CHIP_H),
		Position = UDim2.new(0.5, 0, 0, ROW_Y + RUN_H + 2),
		AnchorPoint = Vector2.new(0.5, 0),
		Visible = false,
		ZIndex = 3,
	})

	-- The map's name and best time: the start Notify's when it is about this map, else the
	-- snapshot's.
	local function mapName(): string?
		if started and started.level == myStage and started.name then
			return started.name
		end
		local info = levelInfo(myStage)
		return if info and type(info.name) == "string" then info.name else nil
	end
	local function mapBest(): number
		if started and started.level == myStage then
			return started.best or 0
		end
		local info = levelInfo(myStage)
		return if info then tonumber(info.best) or 0 else 0
	end

	local function renderCounter()
		-- One stage per map; the last stage is map 10's finish deck, so maps = stageCount - 1.
		local maps = math.max(stageCount - 1, 0)
		local total = if maps > 0 then string.format(' <font size="16" transparency="0.2">/ %d</font>', maps) else ""
		local map = if maps > 0 then math.clamp(myStage, 1, maps) else math.max(myStage, 1)
		local name = mapName()
		local tail = if name and not phone then string.format(' <font size="16">  ·  %s</font>', name) else ""
		counter.Text = string.format("MAP %d%s%s", map, total, tail)
		local parts = {}
		if name and phone then
			table.insert(parts, name)
		end
		local best = mapBest()
		if best > 0 then
			table.insert(parts, "Best " .. clockText(best))
		end
		table.insert(parts, string.format("Falls %d", falls))
		stats.Text = table.concat(parts, "  ·  ")
	end

	local function setAssisted(on: boolean)
		if on ~= assisted then
			assisted = on
			chip.Visible = on
			if on and shown then
				Kit.pop(chip, 1.5)
			end
		end
	end

	-- Skip Map: a small grey button that only asks; the card's YES pays.
	local closeConfirm: () -> ()
	local openConfirm: () -> ()
	local skip = Kit.button(root, {
		Name = "Skip",
		Text = skipText(cost),
		Font = F.UI,
		Color = C.SurfaceHi,
		TextSize = 13,
		Depth = 2,
		Size = UDim2.fromOffset(SKIP_W, SKIP_H),
		Position = UDim2.new(0.5, STAGE_W / 2 + ROW_GAP, 0, ROW_Y + 1),
	}, function()
		if shown then
			openConfirm()
		end
	end)
	local confirm = Kit.hudGlass(root, {
		Name = "SkipConfirm",
		Size = UDim2.fromOffset(CONFIRM_W, CONFIRM_H),
		Position = UDim2.new(0.5, 0, 0, ROW_Y + ROW_H + CHIP_H + 8),
		AnchorPoint = Vector2.new(0.5, 0),
		Radius = 18,
		Visible = false,
		ZIndex = 20,
	})
	local question = Kit.hudText(confirm, {
		Name = "Question",
		Text = "",
		Font = F.UI,
		TextSize = 16,
		StrokeThickness = 2,
		TextWrapped = true,
		Size = UDim2.new(1, -28, 0, 62),
		Position = UDim2.new(0.5, 0, 0, 12),
		AnchorPoint = Vector2.new(0.5, 0),
		ZIndex = 21,
	})
	local confirmToken = 0
	closeConfirm = function()
		confirmToken += 1
		confirm.Visible = false
	end
	openConfirm = function()
		if confirm.Visible then
			closeConfirm()
			return
		end
		confirmToken += 1
		local mine = confirmToken
		local name = mapName() or "this map"
		question.Text = if cost
			then string.format("Skip %s for %s?\nYou get no reward for a skipped map.", name, Format.money(cost))
			else string.format("Skip %s?\nYou get no reward for a skipped map.", name)
		confirm.Visible = true
		Kit.appear(confirm, { from = 0.85, time = 0.2 })
		task.delay(CONFIRM_SECONDS, function()
			if confirmToken == mine then
				closeConfirm()
			end
		end)
	end
	local half = (CONFIRM_W - 28 - 12) / 2
	Kit.button(confirm, {
		Name = "Yes",
		Text = "YES, SKIP",
		Font = F.Display,
		Color = C.SurfaceHi,
		TextSize = 15,
		Size = UDim2.fromOffset(half, 40),
		Position = UDim2.new(0, 14, 1, -12),
		AnchorPoint = Vector2.new(0, 1),
		ZIndex = 21,
	}, function()
		if shown and confirm.Visible then
			closeConfirm()
			action:FireServer({ action = "ParkourSkip" })
		end
	end)
	Kit.button(confirm, {
		Name = "No",
		Text = "NO, KEEP GOING",
		Font = F.Display,
		Color = C.Good,
		TextSize = 15,
		Size = UDim2.fromOffset(half, 40),
		Position = UDim2.new(1, -14, 1, -12),
		AnchorPoint = Vector2.new(1, 1),
		ZIndex = 21,
	}, function()
		closeConfirm()
	end)

	-- "Oops! Back to the start": the beat after a fall (the run goes on).
	local oops = Kit.hudText(root, {
		Name = "Oops",
		Text = "",
		Font = F.Display,
		TextSize = 34,
		StrokeThickness = 3.5,
		TextWrapped = false,
		Size = UDim2.fromOffset(520, 44),
		Position = UDim2.fromScale(0.5, 0.3),
		AnchorPoint = Vector2.new(0.5, 0.5),
		Visible = false,
		ZIndex = 15,
	})
	local oopsScale = Kit.new("UIScale", { Parent = oops })
	local oopsToken = 0
	local function showOops(text: string)
		oopsToken += 1
		local mine = oopsToken
		oops.Text = text
		oops.Visible = true
		oopsScale.Scale = 0.6
		Kit.tween(oopsScale, 0.25, { Scale = 1 }, Enum.EasingStyle.Back)
		task.delay(OOPS_SECONDS, function()
			if oopsToken == mine then
				oops.Visible = false
			end
		end)
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
		if chosen ~= "none" then
			-- Worn at once on the server: the run is assisted from here on.
			setAssisted(true)
		end
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
	-- A new snapshot may bring the map's name and best time after the HUD is up, and says
	-- when the run became assisted (it only ever turns the chip on: a run never stops being
	-- assisted, and the start Notify resets it).
	State.changed.Event:Connect(function()
		if not shown then
			return
		end
		local data = State.data
		local info = data and data.modes and data.modes.parkour
		if type(info) == "table" and info.running == true and info.assisted == true then
			setAssisted(true)
		end
		renderCounter()
	end)

	local function syncSkip()
		local next = skipCost()
		if next ~= cost then
			cost = next
			local label = Kit.buttonLabel(skip)
			if label then
				label.Text = skipText(cost)
			end
		end
	end
	State.changed.Event:Connect(syncSkip)

	-- Layout -----------------------------------------------------------------------------
	local function viewport(): Vector2
		local ok, size = pcall(function()
			return screen.AbsoluteSize
		end)
		return if ok and typeof(size) == "Vector2" and size.X > 0 then size else Vector2.new(1280, 720)
	end
	-- Row positions, as offsets from the screen centre (design px). Desktop:
	-- [run pill][MAP n / N · name][SKIP] on one line, the counter centred, best / falls
	-- under the run pill. Phones: the run pill and "MAP n / N" share line 1; the name with
	-- best / falls and the skip button share line 2. The assisted chip and the skip card
	-- sit under the last line.
	local function rowLayout(): (UDim2, Vector2)
		phone = viewport().X < PHONE_PX
		barHolder.Size = UDim2.new(if phone then BAR_FRACTION_PHONE else BAR_FRACTION, 0, 0, BAR_H)
		counter.AnchorPoint = Vector2.new(0.5, 0)
		counter.TextXAlignment = Enum.TextXAlignment.Center
		skip.AnchorPoint = Vector2.new(0.5, 0)
		local runPos: UDim2
		local below: number -- where the assisted chip and the skip card start
		if phone then
			-- Line 1: [run pill][MAP n / N] centred as a pair; line 2: [name · best · falls]
			-- [skip] centred as a pair.
			local left = -(RUN_W + ROW_GAP + STAGE_W_PHONE) / 2
			local line2 = ROW_Y + ROW_H + 8
			runPos = UDim2.new(0.5, left + RUN_W, 0, ROW_Y)
			counter.Size = UDim2.fromOffset(STAGE_W_PHONE, RUN_H)
			counter.Position = UDim2.new(0.5, left + RUN_W + ROW_GAP + STAGE_W_PHONE / 2, 0, ROW_Y)
			local left2 = -(STATS_W_PHONE + ROW_GAP + SKIP_W) / 2
			stats.Size = UDim2.fromOffset(STATS_W_PHONE, SKIP_H)
			stats.AnchorPoint = Vector2.new(0, 0)
			stats.Position = UDim2.new(0.5, left2, 0, line2)
			skip.Position = UDim2.new(0.5, left2 + STATS_W_PHONE + ROW_GAP + SKIP_W / 2, 0, line2)
			below = line2 + SKIP_H + 6
		else
			runPos = UDim2.new(0.5, -STAGE_W / 2 - ROW_GAP, 0, ROW_Y)
			counter.Size = UDim2.fromOffset(STAGE_W, RUN_H)
			counter.Position = UDim2.new(0.5, 0, 0, ROW_Y)
			stats.Size = UDim2.fromOffset(RUN_W, STATS_H)
			stats.AnchorPoint = Vector2.new(1, 0)
			stats.Position = UDim2.new(0.5, -STAGE_W / 2 - ROW_GAP, 0, ROW_Y + RUN_H + 2)
			skip.Position = UDim2.new(0.5, STAGE_W / 2 + ROW_GAP + SKIP_W / 2, 0, ROW_Y + 1)
			below = ROW_Y + RUN_H + 4
		end
		chip.Position = UDim2.new(0.5, 0, 0, below)
		confirm.Position = UDim2.new(0.5, 0, 0, below + CHIP_H + 8)
		renderCounter()
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
		end
	end

	ObbyHud.setStage = function(stage: number?, count: number?)
		setCount(count)
		local n = tonumber(stage) or myStage
		local changed = n ~= myStage
		myStage = n
		if changed then
			-- Another map: other runners' heads belong to it or not.
			placeAll()
		else
			placeHead(me, true)
		end
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
		closeConfirm()
		oopsToken += 1
		oops.Visible = false
		if dockRun then
			dockRun(nil, nil)
		end
	end

	-- What Main does not pass on: the start payload (map name, best time, assisted) and
	-- the falls counted by the respawn payload.
	Net.event("Notify").OnClientEvent:Connect(function(payload: any)
		if type(payload) ~= "table" or payload.kind ~= "Mode" or payload.mode ~= "parkour" then
			return
		end
		if payload.event == "start" then
			started = {
				level = tonumber(payload.level) or 0,
				name = if type(payload.levelName) == "string" then payload.levelName else nil,
				best = tonumber(payload.best),
			}
			falls = 0
			assisted = payload.assisted == true
			chip.Visible = assisted
			closeConfirm()
			renderCounter()
		elseif payload.event == "respawn" then
			falls = tonumber(payload.falls) or falls + 1
			renderCounter()
			statsScale.Scale = 1.25
			Kit.tween(statsScale, 0.3, { Scale = 1 }, Enum.EasingStyle.Back)
			closeConfirm()
			showOops(if payload.reason == "kill" then "Ouch! Back to the start" else "Oops! Back to the start")
		end
	end)

	ObbyHud.isShown = function(): boolean
		return shown
	end

	renderCounter()
	renderGear()
	setCount(nil)
end

return ObbyHud
