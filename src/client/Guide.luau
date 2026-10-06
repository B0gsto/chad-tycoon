--[[
	Guide: points the player at something on their plot, softly.

	  - a small chevron (BillboardGui, ~2.2 studs, 70% opacity, MaxDistance 120)
	    gently bobbing above the target, tinted with the target pad's colour
	  - an optional small tag on top of it (the "navigate" label, e.g. "CLAIM!")
	  - a short trail of ground dots from the player toward the target that
	    brighten one after another, shown only while the player is far away
	    (> TRAIL_DISTANCE studs) or has been standing still for IDLE_SECONDS

	Everything fades in and out (eased per frame) and stays hidden while the
	intro cutscene plays (Players.LocalPlayer attribute "IntroPlaying").

	Targets are pad names ("Buy1", "Deposit", ...; found as
	workspace.Map.Plot<n>.Pad_<name>) or "Orbs" (the nearest orb on the plot,
	else the middle of the field). Everything is client-only.

	Two sources can ask for a target: the tutorial (persistent) and a short
	"navigate" request (e.g. the Free reward button), which wins while active.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Kit = require(script.Parent.UI.Kit)
local State = require(script.Parent.State)

local World = Kit.Theme.World

local Guide = {}

-- Marker: size in studs, opacity at full fade-in, height above the target's top.
local MARKER_STUDS = 2.2
local MARKER_OPACITY = 0.7
-- Clears the pads' floating labels (World.Pads: about 2.6..6 studs above the top).
local MARKER_HEIGHT = 7
local MARKER_BOB = 0.3
local MAX_DISTANCE = 120
-- Trail: dot count, first dot distance ahead of the player, spacing, gap kept before the target.
local DOTS = 5
local DOT_SIZE = 0.8
local TRAIL_LEAD = 3
local TRAIL_SPACING = 2.4
local TRAIL_END_GAP = 2.5
local TRAIL_DISTANCE = 12
local IDLE_SECONDS = 4
-- Fade speed (per second, exponential ease toward the goal).
local FADE_RATE = 6

local folder: Folder
local anchor: Part
local marker: BillboardGui
local markerBars: { Frame } = {}
local tag: BillboardGui
local tagLabel: TextLabel
local tagEdge: UIStroke?
local dots: { Part } = {}
local rayParams: RaycastParams? = nil

local tutorialTarget: string? = nil
local tutorialText = ""
local navTarget: string? = nil
local navText = ""
local navUntil = 0

local currentPart: BasePart? = nil
local currentName: string? = nil
local lastResolve = 0

-- Eased visibility (0..1) of the marker and the trail.
local markerAlpha = 0
local trailAlpha = 0
local idleFor = 0
local lastRootPos: Vector3? = nil
-- Where the marker floats now (it glides to a new target instead of jumping).
local markerPos: Vector3? = nil

local function plotFolder(): Instance?
	local data = State.data
	local map = Workspace:FindFirstChild("Map")
	if not data or not map or not data.plotIndex then
		return nil
	end
	return map:FindFirstChild("Plot" .. data.plotIndex)
end

local function rootPart(): BasePart?
	local character = Players.LocalPlayer.Character
	return character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
end

local function resolve(name: string): BasePart?
	local plot = plotFolder()
	if not plot then
		return nil
	end
	if name == "Orbs" then
		local orbs = plot:FindFirstChild("Orbs", true)
		local root = rootPart()
		local best: BasePart? = nil
		local bestDistance = math.huge
		if orbs and root then
			local from = root.CFrame.Position
			for _, orb in orbs:GetChildren() do
				if orb:IsA("BasePart") then
					local d = (orb.CFrame.Position - from).Magnitude
					if d < bestDistance then
						best, bestDistance = orb, d
					end
				end
			end
		end
		if best then
			return best
		end
		return (plot:FindFirstChild("Field", true) or plot:FindFirstChild("Floor", true)) :: BasePart?
	end
	return plot:FindFirstChild("Pad_" .. name, true) :: BasePart?
end

local function activeTarget(): (string?, string)
	if navTarget and os.clock() < navUntil then
		return navTarget, navText
	end
	navTarget = nil
	return tutorialTarget, tutorialText
end

-- The palette colour that matches what the target does.
local function colorFor(name: string): Color3
	local pads = World.Pads
	if name == "Orbs" then
		return World.Pink
	elseif string.sub(name, 1, 3) == "Buy" then
		return if name == "BuyTier" then pads.BuyTier else pads.Buy
	end
	return pads[name] or World.Sunny
end

local function buildMarker(parent: Instance)
	marker = Kit.new("BillboardGui", {
		Name = "GuideMarker",
		Size = UDim2.fromScale(MARKER_STUDS, MARKER_STUDS),
		StudsOffsetWorldSpace = Vector3.new(0, MARKER_HEIGHT, 0),
		AlwaysOnTop = true,
		LightInfluence = 0,
		MaxDistance = MAX_DISTANCE,
		ResetOnSpawn = false,
		Enabled = false,
		Parent = parent,
	})
	-- A soft downward chevron: two rounded bars meeting at the bottom centre.
	for i, side in { -1, 1 } do
		local bar = Kit.new("Frame", {
			Name = if side < 0 then "Left" else "Right",
			BackgroundColor3 = World.Sunny,
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			Size = UDim2.fromScale(0.62, 0.24),
			Position = UDim2.fromScale(0.5 + side * 0.19, 0.44),
			AnchorPoint = Vector2.new(0.5, 0.5),
			Rotation = side * -40,
			ZIndex = 2,
			Parent = marker,
		})
		Kit.round(bar)
		Kit.new("UIStroke", {
			Name = "Rim",
			Color = World.White,
			Thickness = 1.5,
			Transparency = 1,
			Parent = bar,
		})
		markerBars[i] = bar
	end

	tag = Kit.new("BillboardGui", {
		Name = "GuideTag",
		Size = UDim2.fromOffset(140, 26),
		StudsOffsetWorldSpace = Vector3.new(0, MARKER_HEIGHT + MARKER_STUDS * 0.5 + 0.9, 0),
		AlwaysOnTop = true,
		LightInfluence = 0,
		MaxDistance = 60,
		ResetOnSpawn = false,
		Enabled = false,
		Parent = parent,
	})
	tagLabel = Kit.pill(tag, {
		Name = "Label",
		Text = "",
		Color = World.Cream,
		Solid = true,
		TextColor = World.Ink,
		TextSize = 13,
		Size = UDim2.fromOffset(0, 22),
		AutomaticSize = Enum.AutomaticSize.X,
		Position = UDim2.fromScale(0.5, 0.5),
		AnchorPoint = Vector2.new(0.5, 0.5),
	})
	tagEdge = tagLabel:FindFirstChild("Edge") :: UIStroke?
end

local function buildTrail()
	for i = 1, DOTS do
		local dot = Instance.new("Part")
		dot.Name = "GuideDot" .. i
		dot.Shape = Enum.PartType.Cylinder
		dot.Size = Vector3.new(0.12, DOT_SIZE, DOT_SIZE)
		dot.Material = Enum.Material.SmoothPlastic
		dot.Color = World.Sunny
		dot.Transparency = 1
		dot.Anchored = true
		dot.CanCollide = false
		dot.CanQuery = false
		dot.CanTouch = false
		dot.CastShadow = false
		dot.Parent = folder
		dots[i] = dot
	end
end

function Guide.build()
	folder = Instance.new("Folder")
	folder.Name = "ClientGuide"
	folder.Parent = Workspace

	anchor = Instance.new("Part")
	anchor.Name = "GuideAnchor"
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanQuery = false
	anchor.CanTouch = false
	anchor.Transparency = 1
	anchor.Size = Vector3.new(1, 1, 1)
	anchor.Parent = folder

	-- Optional: the preview exporter has no raycasts (dots then sit at foot level).
	pcall(function()
		local params = RaycastParams.new()
		params.FilterType = Enum.RaycastFilterType.Exclude
		params.IgnoreWater = true
		rayParams = params
	end)

	buildMarker(anchor)
	buildTrail()

	local clock = 0
	RunService.Heartbeat:Connect(function(dt)
		clock += dt
		Guide.update(clock, dt)
	end)
end

-- Eases `value` toward `goal`; with no dt (a direct call) it snaps.
local function approach(value: number, goal: number, dt: number?): number
	if not dt then
		return goal
	end
	return value + (goal - value) * (1 - math.exp(-FADE_RATE * dt))
end

local function paintMarker()
	local enabled = markerAlpha > 0.01
	marker.Enabled = enabled
	local fill = 1 - MARKER_OPACITY * markerAlpha
	local rim = 1 - 0.6 * markerAlpha
	for _, bar in markerBars do
		bar.BackgroundTransparency = fill
		local stroke = bar:FindFirstChild("Rim") :: UIStroke?
		if stroke then
			stroke.Transparency = rim
		end
	end
	tag.Enabled = enabled and tagLabel.Text ~= ""
	tagLabel.BackgroundTransparency = 1 - 0.92 * markerAlpha
	tagLabel.TextTransparency = 1 - markerAlpha
	if tagEdge then
		tagEdge.Transparency = 1 - 0.5 * markerAlpha
	end
end

-- Ground height under `point` (falls back to `fallback` when nothing is hit).
local function groundY(point: Vector3, fallback: number): number
	local params = rayParams
	if not params then
		return fallback
	end
	local hit = Workspace:Raycast(point + Vector3.new(0, 3, 0), Vector3.new(0, -10, 0), params)
	return if hit then hit.Position.Y else fallback
end

local function paintTrail(clock: number, root: BasePart?, target: Vector3?, color: Color3)
	if trailAlpha < 0.01 or not root or not target then
		for _, dot in dots do
			dot.Transparency = 1
		end
		return
	end
	local rootPos = root.CFrame.Position
	local flat = Vector3.new(target.X - rootPos.X, 0, target.Z - rootPos.Z)
	local distance = flat.Magnitude
	local span = distance - TRAIL_LEAD - TRAIL_END_GAP
	if span <= 0.5 then
		for _, dot in dots do
			dot.Transparency = 1
		end
		return
	end
	local direction = flat.Unit
	local spacing = math.min(TRAIL_SPACING, span / (DOTS - 1))
	local character = Players.LocalPlayer.Character
	local plot = plotFolder()
	local orbs = plot and plot:FindFirstChild("Orbs", true)
	local ignore: { Instance } = { folder }
	if character then
		table.insert(ignore, character)
	end
	if orbs then
		table.insert(ignore, orbs)
	end
	if rayParams then
		rayParams.FilterDescendantsInstances = ignore
	end
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local footY = rootPos.Y - root.Size.Y * 0.5 - (if humanoid then humanoid.HipHeight else 2)
	-- A soft highlight travels from the player toward the target, dot by dot.
	local wave = (clock * 0.8) % 1 * (DOTS + 2) - 1
	for i, dot in dots do
		local point = rootPos + direction * (TRAIL_LEAD + (i - 1) * spacing)
		local y = groundY(Vector3.new(point.X, footY, point.Z), footY)
		local glow = math.max(0, 1 - math.abs(wave - (i - 1)) / 1.5)
		local size = DOT_SIZE * (0.8 + 0.25 * glow)
		dot.Size = Vector3.new(0.12, size, size)
		dot.CFrame = CFrame.new(point.X, y + 0.08, point.Z) * CFrame.Angles(0, 0, math.rad(90))
		dot.Color = color
		dot.Transparency = 1 - trailAlpha * (0.3 + 0.45 * glow)
	end
end

local function hideAll(dt: number?)
	markerAlpha = approach(markerAlpha, 0, dt)
	trailAlpha = approach(trailAlpha, 0, dt)
	paintMarker()
	paintTrail(0, nil, nil, World.Sunny)
	if markerAlpha <= 0.01 then
		currentPart = nil
	end
end

--[[
	One frame of guide work. `dt` is the frame time; the preview exporter
	calls it directly without one, which snaps every fade to its end state.
]]
function Guide.update(clock: number, dt: number?)
	local player = Players.LocalPlayer
	local name, text = activeTarget()
	if not name or (player and player:GetAttribute("IntroPlaying") == true) then
		hideAll(dt)
		return
	end
	if name ~= currentName or os.clock() - lastResolve > 0.25 or not currentPart or not currentPart.Parent then
		lastResolve = os.clock()
		currentName = name
		currentPart = resolve(name)
	end
	local part = currentPart
	if not part then
		hideAll(dt)
		return
	end
	local color = colorFor(name)
	local position = part.CFrame.Position
	local goal = position + Vector3.new(0, part.Size.Y * 0.5, 0)
	local from = markerPos
	if from and dt and markerAlpha > 0.05 then
		markerPos = from:Lerp(goal, 1 - math.exp(-8 * dt))
	else
		markerPos = goal
	end
	anchor.CFrame = CFrame.new(markerPos :: Vector3)
	marker.StudsOffsetWorldSpace = Vector3.new(0, MARKER_HEIGHT + math.sin(clock * 2.2) * MARKER_BOB, 0)
	tag.StudsOffsetWorldSpace = Vector3.new(0, MARKER_HEIGHT + MARKER_STUDS * 0.5 + 0.9 + math.sin(clock * 2.2) * MARKER_BOB, 0)
	if tagLabel.Text ~= text then
		tagLabel.Text = text
	end
	for _, bar in markerBars do
		bar.BackgroundColor3 = color
	end
	markerAlpha = approach(markerAlpha, 1, dt)
	paintMarker()

	local root = rootPart()
	local wantTrail = false
	if root then
		local rootPos = root.CFrame.Position
		-- Idle = the character has barely moved since the last frame.
		local moved = if lastRootPos then Vector3.new(rootPos.X - lastRootPos.X, 0, rootPos.Z - lastRootPos.Z).Magnitude else 0
		lastRootPos = rootPos
		if dt and moved < dt * 1.5 then
			idleFor += dt
		else
			idleFor = 0
		end
		local distance = Vector3.new(position.X - rootPos.X, 0, position.Z - rootPos.Z).Magnitude
		wantTrail = distance > TRAIL_DISTANCE or idleFor >= IDLE_SECONDS
	end
	trailAlpha = approach(trailAlpha, if wantTrail then 1 else 0, dt)
	paintTrail(clock, root, position, color)
end

function Guide.setTutorialTarget(name: string?, text: string?)
	if name ~= tutorialTarget then
		currentPart = nil
	end
	tutorialTarget = name
	tutorialText = text or ""
end

-- Temporary target that overrides the tutorial for `seconds`.
function Guide.navigate(name: string?, text: string?, seconds: number?)
	navTarget = name
	navText = text or ""
	navUntil = os.clock() + (seconds or 30)
	currentPart = nil
end

function Guide.clearNavigate(name: string)
	if navTarget == name then
		navTarget = nil
		currentPart = nil
	end
end

return Guide
