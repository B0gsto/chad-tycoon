--[[
	Fx.BuyArrows: "you can buy this now!" pointers on the local player's own plot.

	  - a chunky "BUY!" arrow, tinted with the pad's colour and rimmed in ink, bobbing over
	    the pad's floating label when the pad becomes affordable (Shared.BuyNext.affordable).
	    It pops in, and shrinks away when the pad is used (a Buy / Upgrade effect from it),
	    is no longer affordable, or after ARROW_SECONDS. A pad gets a new one only after it
	    was out of reach again. At most MAX_ARROWS at once (the biggest pads first)
	  - one edge pointer while BuyNext.best's pad is off screen: a round chip in the pad's
	    colour with a "$" on it, held inside the HUD's safe margins, and a chevron on its rim
	    turned toward the pad. Tapping it draws the guide's path there. Not while the guide
	    runs a "navigate" request or the tutorial: its own trail leads then

	The pad the guide's chevron marks (Guide.current) gets no arrow of its own, and pads in
	reach already when the player joins get none. Everything hides while the tutorial runs,
	the intro plays, a window, a modal, a popup card or a reveal is up, a run is on, or the
	player is more than PLOT_RANGE studs from the plot.
]]

local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local BuyNext = require(Shared:WaitForChild("BuyNext"))
local Net = require(Shared:WaitForChild("Net"))

local Client = script.Parent.Parent
local Guide = require(Client.Guide)
local Kit = require(Client.UI.Kit)
local State = require(Client.State)

local World = Kit.Theme.World
local F = Kit.F

local BuyArrows = {}

-- Arrows: how many at once, how long one stays, how often the affordable set is looked at.
local MAX_ARROWS = 3
local ARROW_SECONDS = 20
local TICK = 0.25
-- One arrow: width in studs plus fixed pixels (it shrinks less than the world with distance,
-- like the pad labels), its height for one unit of width, the gap over the label's top, the
-- bob, and the pop in / out.
local ARROW_STUDS = 2.2
local ARROW_PX = 16
local ARROW_TALL = 1.45
local ARROW_GAP = 0.6
local ARROW_BOB = 0.35
local ARROW_BOB_SPEED = 3.4
local POP_IN = 0.28
local POP_OUT = 0.2
local ARROW_MAX_DISTANCE = 110
-- The ink rim round every shape of the arrow and the pointer (px).
local RIM = 3
-- Edge pointer: chip size, how far its chevron sits off the chip's centre, the screen's safe
-- margins (design px at 1280x720, scaled with the HUD: clear of the top stack, the wallet and
-- the bottom bar, and the left menu grid) and how far it eases per second. At the bottom edge
-- the chevron hangs POINTER_TIP below the chip, so SAFE_BOTTOM keeps it clear of the AURA
-- dumbbell (about 122 px tall).
local POINTER_PX = 50
local POINTER_TIP = 36
local SAFE_TOP = 96
local SAFE_BOTTOM = 156
local SAFE_LEFT = 150
local SAFE_RIGHT = 40
local POINTER_EASE = 10
-- Further than this from the plot (the plaza, a course) nothing shows.
local PLOT_RANGE = 110
-- The HUD's busy flags (ScreenGui "TycoonUI" attributes).
local BUSY = { "WindowOpen", "ModalOpen", "PopupBusy", "RevealOpen", "RunActive", "ObbyMode", "CardioActive" }

type Arrow = {
	pad: string,
	part: BasePart?,
	gui: BillboardGui,
	body: Frame,
	since: number,
	-- os.clock() it started to go (nil while it stays), and its pop scale now.
	leaving: number?,
	scale: number,
}

local started = false
local player = Players.LocalPlayer
local arrows: { [string]: Arrow } = {}
-- Pads in reach that have had their turn (an arrow, the overflow past MAX_ARROWS, or in reach
-- already when the player joined). A pad leaves it when it goes out of reach.
local seen: { [string]: boolean } = {}
-- Whether the first look at the affordable set (at join) has been taken.
local seeded = false
local folder: Folder? = nil
-- Looked up on the tick, read every frame: the plot, its floor, its pad parts, and the pad
-- BuyNext.best picks with its part.
local cache = {
	index = nil :: number?,
	plot = nil :: Instance?,
	floor = nil :: BasePart?,
	pads = {} :: { [string]: BasePart },
	best = nil :: string?,
	bestPart = nil :: BasePart?,
}

-- How thick a pad is: a round pad is a cylinder lying on its X axis.
local function thickness(part: BasePart): number
	return if part:IsA("Part") and part.Shape == Enum.PartType.Cylinder then part.Size.X else part.Size.Y
end

-- Refreshes the plot and its floor when the plot changed or either left the world.
local function refreshPlot()
	local data = State.data
	local index = data and data.plotIndex
	local plot = cache.plot
	if index ~= cache.index or not (plot and plot.Parent) then
		local map = Workspace:FindFirstChild("Map")
		plot = if map and index then map:FindFirstChild("Plot" .. tostring(index)) else nil
		cache.index = index
		cache.plot = plot
		cache.floor = nil
		table.clear(cache.pads)
	end
	local floor = cache.floor
	if plot and not (floor and floor.Parent) then
		local found = plot:FindFirstChild("Floor", true)
		cache.floor = if found and found:IsA("BasePart") then found else nil
	end
end

-- A pad's part on the plot (cached; looked up again once it left the world).
local function padPart(name: string): BasePart?
	local part = cache.pads[name]
	if part and part.Parent then
		return part
	end
	cache.pads[name] = nil
	local plot = cache.plot
	local found = plot and plot:FindFirstChild("Pad_" .. name, true)
	if found and found:IsA("BasePart") then
		cache.pads[name] = found
		return found
	end
	return nil
end

-- A rounded shape with an ink copy RIM px bigger behind it, so overlapping shapes share one
-- clean outline. Returns the coloured one.
local function shape(parent: Instance, name: string, color: Color3, props: { [string]: any }): Frame
	local function make(rim: boolean): Frame
		local frame = Kit.new("Frame", {
			Name = if rim then name .. "Rim" else name,
			BackgroundColor3 = if rim then World.Ink else color,
			BorderSizePixel = 0,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = props.Position,
			Size = if rim then props.Size + UDim2.fromOffset(RIM * 2, RIM * 2) else props.Size,
			Rotation = props.Rotation or 0,
			ZIndex = if rim then 1 else 2,
			Parent = parent,
		})
		Kit.new("UICorner", { CornerRadius = props.Corner or UDim.new(0.5, 0), Parent = frame })
		return frame
	end
	make(true)
	return make(false)
end

-- The arrow's billboard: "BUY!" over a thick down arrow (a shaft into a rounded chevron).
local function buildArrow(name: string, part: BasePart): Arrow
	local color = Guide.colorFor(name)
	local gui = Kit.new("BillboardGui", {
		Name = "BuyArrow_" .. name,
		Adornee = part,
		Size = UDim2.new(ARROW_STUDS, ARROW_PX, ARROW_STUDS * ARROW_TALL, ARROW_PX * ARROW_TALL),
		AlwaysOnTop = true,
		LightInfluence = 0,
		MaxDistance = ARROW_MAX_DISTANCE,
		ResetOnSpawn = false,
		Parent = folder,
	})
	-- Scaled as one piece for the pop (UIScale on the body).
	local body = Kit.new("Frame", {
		Name = "Body",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		Parent = gui,
	})
	Kit.new("UIScale", { Scale = 0, Parent = body })
	local word = Kit.new("TextLabel", {
		Name = "Word",
		Text = "BUY!",
		Font = F.Display,
		TextScaled = true,
		TextColor3 = World.White,
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1.1, 0.3),
		Position = UDim2.fromScale(0.5, 0),
		AnchorPoint = Vector2.new(0.5, 0),
		ZIndex = 3,
		Parent = body,
	})
	Kit.new("UIStroke", { Color = World.Ink, Thickness = RIM, LineJoinMode = Enum.LineJoinMode.Round, Parent = word })
	-- The arrow in a square under the word (its own coordinates are square).
	local square = Kit.new("Frame", {
		Name = "Arrow",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1 / ARROW_TALL),
		Position = UDim2.fromScale(0, 1),
		AnchorPoint = Vector2.new(0, 1),
		Parent = body,
	})
	shape(square, "Shaft", color, { Size = UDim2.fromScale(0.34, 0.62), Position = UDim2.fromScale(0.5, 0.36), Corner = UDim.new(0.3, 0) })
	for _, side in { -1, 1 } do
		shape(square, if side < 0 then "Left" else "Right", color, {
			Size = UDim2.fromScale(0.66, 0.28),
			Position = UDim2.fromScale(0.5 + side * 0.215, 0.64),
			Rotation = side * -45,
		})
	end
	-- A light glint down the shaft, like the moulded pads.
	Kit.new("Frame", {
		Name = "Glint",
		BackgroundColor3 = World.White,
		BackgroundTransparency = 0.45,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(0.08, 0.36),
		Position = UDim2.fromScale(0.44, 0.3),
		AnchorPoint = Vector2.new(0.5, 0.5),
		ZIndex = 3,
		Parent = square,
	}, { Kit.new("UICorner", { CornerRadius = UDim.new(0.5, 0) }) })
	return { pad = name, part = part, gui = gui, body = body, since = os.clock(), leaving = nil, scale = 0 }
end

local function dropArrow(name: string)
	local arrow = arrows[name]
	if arrow and not arrow.leaving then
		arrow.leaving = os.clock()
	end
end

-- The pad an effect came from: by name, else the arrow's pad nearest its `padPos`.
local function usedPad(data: { [string]: any })
	if type(data.pad) == "string" then
		dropArrow(data.pad)
		return
	end
	local at = data.padPos
	if typeof(at) ~= "Vector3" then
		return
	end
	for name, arrow in arrows do
		local part = arrow.part
		if part and part.Parent and (part.Position - at).Magnitude < 6 then
			dropArrow(name)
		end
	end
end

-- Nothing shows: the tutorial, the intro, a window, a run, or far from the plot.
local function hiddenNow(screen: Instance?): boolean
	local data = State.data
	if not data or data.tutorialDone ~= true or player:GetAttribute("IntroPlaying") == true then
		return true
	end
	if screen then
		for _, flag in BUSY do
			if screen:GetAttribute(flag) == true then
				return true
			end
		end
	end
	local plot = cache.plot
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not (plot and plot.Parent) or not root then
		return true
	end
	local floor = cache.floor
	if not (floor and floor.Parent) then
		return false
	end
	local offset = root.Position - floor.Position
	return Vector3.new(offset.X, 0, offset.Z).Magnitude > PLOT_RANGE
end

-- Looks at the affordable set: new arrows for pads that just came in reach, away with the
-- ones whose pad went out of it or that have had their time. Also picks the pointer's pad.
local function tick(hidden: boolean, marked: string?)
	local data = State.data
	cache.best = nil
	cache.bestPart = nil
	if not data then
		return
	end
	if data.tutorialDone ~= true then
		-- The tutorial's pads are the tutorial's: what is affordable when it ends is new.
		seeded = true
		table.clear(seen)
		for name in arrows do
			dropArrow(name)
		end
		return
	end
	local now = os.clock()
	local list = BuyNext.affordable(data)
	local inReach: { [string]: boolean } = {}
	for _, name in list do
		inReach[name] = true
	end
	cache.best = BuyNext.best(data)
	cache.bestPart = if cache.best then padPart(cache.best) else nil
	-- Pads out of reach may get an arrow again the next time they come in reach.
	for name in seen do
		if not inReach[name] then
			seen[name] = nil
		end
	end
	for name, arrow in arrows do
		if not inReach[name] or now - arrow.since > ARROW_SECONDS then
			dropArrow(name)
		end
	end
	-- What is affordable at join is not news.
	if not seeded then
		seeded = true
		for name in inReach do
			seen[name] = true
		end
		return
	end
	-- While hidden no arrow is built: a pad that came in reach meanwhile still gets its arrow
	-- once the screen is clear.
	if hidden then
		return
	end
	local count = 0
	for _, arrow in arrows do
		if not arrow.leaving then
			count += 1
		end
	end
	-- The biggest pads first (the list runs small to big). The guide's pad waits its turn
	-- (its chevron leads already); a pad whose part is not streamed in yet is tried again.
	for i = #list, 1, -1 do
		local name = list[i]
		if seen[name] or arrows[name] or name == marked then
			continue
		end
		if count >= MAX_ARROWS then
			seen[name] = true
			continue
		end
		local part = padPart(name)
		if part then
			arrows[name] = buildArrow(name, part)
			seen[name] = true
			count += 1
		end
	end
end

local function easeBack(t: number): number
	local c = 1.70158
	local x = t - 1
	return 1 + (c + 1) * x * x * x + c * x * x
end

-- One frame of every arrow: pop in / out, bob over the label, none on the guide's pad.
local function stepArrows(clock: number, hidden: boolean, marked: string?)
	for name, arrow in arrows do
		local part = arrow.part
		local leaving = arrow.leaving
		if not part or not part.Parent or (leaving and clock - leaving >= POP_OUT) then
			arrow.gui:Destroy()
			arrows[name] = nil
			if not leaving then
				-- Its part streamed out: it gets a fresh arrow once the part is back.
				seen[name] = nil
			end
			continue
		end
		local scale = if leaving then 1 - (clock - leaving) / POP_OUT else easeBack(math.clamp((clock - arrow.since) / POP_IN, 0, 1))
		arrow.scale = scale
		local show = not hidden and name ~= marked and scale > 0.01
		arrow.gui.Enabled = show
		if show then
			local uiScale = arrow.body:FindFirstChildOfClass("UIScale")
			if uiScale then
				uiScale.Scale = scale
			end
			local tall = ARROW_STUDS * ARROW_TALL
			local bob = math.sin((clock - arrow.since) * ARROW_BOB_SPEED) * ARROW_BOB
			local lift = thickness(part) / 2 + Guide.labelTop(part) + ARROW_GAP + tall / 2 + bob
			-- StudsOffsetWorldSpace runs along the pad's own axes (a round pad is a cylinder on
			-- its side): turn world "up" into them.
			arrow.gui.StudsOffsetWorldSpace = part.CFrame:VectorToObjectSpace(Vector3.new(0, lift, 0))
		end
	end
end

-- The edge pointer: built once, moved per frame.
type Pointer = { gui: ScreenGui, chip: TextButton, tip: Frame, tipBars: { Frame }, chipFills: { Frame }, at: Vector2?, pad: string? }

local function buildPointer(): Pointer
	local gui = Kit.new("ScreenGui", {
		Name = "BuyPointer",
		IgnoreGuiInset = true,
		ResetOnSpawn = false,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		Enabled = false,
		Parent = player:WaitForChild("PlayerGui"),
	})
	local chip = Kit.new("TextButton", {
		Name = "Chip",
		Text = "",
		AutoButtonColor = false,
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(POINTER_PX, POINTER_PX),
		AnchorPoint = Vector2.new(0.5, 0.5),
		Parent = gui,
	})
	Kit.new("UIScale", { Parent = chip })
	local fills: { Frame } = {}
	-- The chevron first, so the chip's rim covers its inner end.
	local tip = Kit.new("Frame", {
		Name = "Tip",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(0.5, 0.5),
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Parent = chip,
	})
	local bars: { Frame } = {}
	for _, side in { -1, 1 } do
		local bar = shape(tip, "Bar", World.Sunny, {
			Size = UDim2.fromScale(0.72, 0.3),
			Position = UDim2.fromScale(0.36, 0.5 + side * 0.2),
			Rotation = side * -40,
		})
		table.insert(bars, bar)
	end
	table.insert(fills, shape(chip, "Disc", World.Sunny, { Size = UDim2.fromScale(1, 1), Position = UDim2.fromScale(0.5, 0.5) }))
	local mark = Kit.new("TextLabel", {
		Name = "Cash",
		Text = "$",
		Font = F.Display,
		TextScaled = true,
		TextColor3 = World.White,
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(0.62, 0.62),
		Position = UDim2.fromScale(0.5, 0.5),
		AnchorPoint = Vector2.new(0.5, 0.5),
		ZIndex = 3,
		Parent = chip,
	})
	Kit.new("UIStroke", { Color = World.Ink, Thickness = 2.5, LineJoinMode = Enum.LineJoinMode.Round, Parent = mark })
	local pointer: Pointer = { gui = gui, chip = chip, tip = tip, tipBars = bars, chipFills = fills, at = nil, pad = nil }
	chip.Activated:Connect(function()
		if pointer.pad then
			Kit.sound("Click")
			Guide.navigate(pointer.pad, "BUY!", 30)
		end
	end)
	return pointer
end

-- Where the pad is on screen, clamped to the safe rectangle along the line from its middle;
-- nil while the pad is in plain view (`dir` is the screen direction toward it).
local function edgeSpot(camera: Camera, world: Vector3, scale: number): (Vector2?, Vector2)
	local view = camera.ViewportSize
	local inset = Vector2.new(0, 0)
	pcall(function()
		inset = GuiService:GetGuiInset()
	end)
	local half = POINTER_PX * scale / 2 + 6
	local left, right = SAFE_LEFT * scale + half, view.X - SAFE_RIGHT * scale - half
	local top, bottom = inset.Y + SAFE_TOP * scale + half, view.Y - SAFE_BOTTOM * scale - half
	-- WorldToViewportPoint's second result is "on screen", not "in front": a pad just below the
	-- screen counted as behind the camera and the pointer flipped to the top edge.
	local point = camera:WorldToViewportPoint(world)
	local inFront = point.Z > 0
	local p = Vector2.new(point.X, point.Y)
	if inFront and p.X >= 0 and p.X <= view.X and p.Y >= 0 and p.Y <= view.Y then
		return nil, Vector2.zero
	end
	local mid = Vector2.new((left + right) / 2, (top + bottom) / 2)
	local dir = p - mid
	if not inFront then
		dir = -dir
	end
	if dir.Magnitude < 1e-3 then
		dir = Vector2.new(0, 1)
	end
	dir = dir.Unit
	-- The first side of the safe rectangle the ray from its middle meets.
	local reach = math.huge
	if dir.X > 1e-6 then
		reach = math.min(reach, (right - mid.X) / dir.X)
	elseif dir.X < -1e-6 then
		reach = math.min(reach, (left - mid.X) / dir.X)
	end
	if dir.Y > 1e-6 then
		reach = math.min(reach, (bottom - mid.Y) / dir.Y)
	elseif dir.Y < -1e-6 then
		reach = math.min(reach, (top - mid.Y) / dir.Y)
	end
	return mid + dir * math.max(0, reach), dir
end

-- `scale` is the HUD's UIScale (the margins and the chip are design px).
local function stepPointer(pointer: Pointer, clock: number, dt: number, hidden: boolean, source: string, scale: number)
	local best = if not hidden and source == "hint" then cache.best else nil
	local part = if best then cache.bestPart else nil
	if part and not part.Parent then
		part = nil
	end
	local camera = Workspace.CurrentCamera
	local spot, dir = nil, Vector2.zero
	if part and camera then
		pointer.chip.Size = UDim2.fromOffset(POINTER_PX * scale, POINTER_PX * scale)
		spot, dir = edgeSpot(camera, part.Position + Vector3.new(0, thickness(part) / 2, 0), scale)
	end
	if not spot or not best then
		pointer.gui.Enabled = false
		pointer.at = nil
		pointer.pad = nil
		return
	end
	if best ~= pointer.pad then
		local color = Guide.colorFor(best)
		for _, fill in pointer.chipFills do
			fill.BackgroundColor3 = color
		end
		for _, bar in pointer.tipBars do
			bar.BackgroundColor3 = color
		end
		if pointer.pad == nil then
			local uiScale = pointer.chip:FindFirstChildOfClass("UIScale")
			if uiScale then
				uiScale.Scale = 0.4
				Kit.tween(uiScale, POP_IN, { Scale = 1 }, Enum.EasingStyle.Back)
			end
		end
		pointer.pad = best
	end
	local at = pointer.at
	pointer.at = if at then at:Lerp(spot, 1 - math.exp(-POINTER_EASE * dt)) else spot
	local now = pointer.at :: Vector2
	pointer.chip.Position = UDim2.fromOffset(now.X, now.Y)
	-- The chevron rides the chip's rim toward the pad and nudges out on a beat.
	local angle = math.atan2(dir.Y, dir.X)
	local reach = POINTER_TIP / POINTER_PX + 0.06 * math.max(0, math.sin(clock * 4))
	pointer.tip.Position = UDim2.fromScale(0.5 + math.cos(angle) * reach, 0.5 + math.sin(angle) * reach)
	pointer.tip.Rotation = math.deg(angle)
	pointer.gui.Enabled = true
end

function BuyArrows.init()
	if started then
		return
	end
	started = true
	local playerGui = player:WaitForChild("PlayerGui")
	-- In the workspace, like Client.Guide's: nothing there is reset on a respawn.
	local made = Instance.new("Folder")
	made.Name = "ClientBuyArrows"
	made.Parent = Workspace
	folder = made
	local pointer = buildPointer()

	Net.event("Effect").OnClientEvent:Connect(function(kind, data)
		if (kind == "Buy" or kind == "Upgrade") and type(data) == "table" then
			usedPad(data)
		end
	end)

	local nextTick = 0
	RunService.Heartbeat:Connect(function(dt)
		local clock = os.clock()
		local hud = playerGui:FindFirstChild("TycoonUI")
		local marked, source = Guide.current()
		local due = clock >= nextTick
		if due then
			nextTick = clock + TICK
			refreshPlot()
		end
		local hidden = hiddenNow(hud)
		if due then
			tick(hidden, marked)
		end
		local uiScale = hud and hud:FindFirstChildOfClass("UIScale")
		stepArrows(clock, hidden, marked)
		stepPointer(pointer, clock, dt, hidden, source, if uiScale then uiScale.Scale else 1)
	end)
end

return BuyArrows
