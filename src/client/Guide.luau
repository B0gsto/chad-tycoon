--[[
	Guide: points the player at something on their plot.

	  - a small chevron (BillboardGui, ~2.2 studs, 70% opacity, MaxDistance 120)
	    gently bobbing above the target, tinted with the target pad's colour
	  - an optional small tag on top of it (the "navigate" label, e.g. "CLAIM!")
	  - a trail of flat chevrons on the floor from the player to the target, flowing
	    toward it. It follows a walkable route: round the pen's corner posts, and over
	    the pen's side stairs when the target (or the player) is inside the pen. During
	    the tutorial it is always shown; for a "navigate" request only while the player
	    is far away (> TRAIL_DISTANCE studs) or has been standing still for IDLE_SECONDS
	  - during the tutorial, a tall soft beam of light over the target (three layered
	    Beams and a thin glowing core, no texture), so the next pad is seen from the spawn

	Everything fades in and out (eased per frame) and stays hidden while the
	intro cutscene plays (Players.LocalPlayer attribute "IntroPlaying").

	Targets are pad names ("Buy1", "Deposit", ...; found as
	workspace.Map.Plot<n>.Pad_<name>) or "Orbs" (the nearest orb in the pen,
	else the middle of the field). Everything is client-only.

	Three sources can ask for a target: the tutorial (persistent), a short
	"navigate" request (e.g. the Free reward button), which wins while active, and a
	standing "hint" (the HUD's goal strip: the upgrade pad while the blender is full,
	MOG MERGE when the next tier is one step away). The hint comes last and is the
	quietest: the chevron over the pad, a floor trail for its first HINT_TRAIL_SECONDS
	(and whenever the player stands still), nothing at all from further than HINT_RANGE.
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
-- Clears the pads' floating titles (World.Pads: LABEL_LIFT 5.6, up to 7.2, plus their height).
local MARKER_HEIGHT = 10.5
local MARKER_BOB = 0.3
local MAX_DISTANCE = 120
-- Trail: chevron count, spacing along the route, first chevron's distance ahead of the player,
-- and the open floor kept between the last one and the target's edge.
local CHEVRONS = 18
local CHEVRON_SPACING = 3.2
local TRAIL_LEAD = 3
local TRAIL_END_GAP = 0.6
-- One chevron: half its width across the route, tip-to-tail depth, bar width, and the dark
-- rim that shows round each bar (it keeps a pale pad colour readable on the pale floor).
local CHEVRON_HALF = 1.15
local CHEVRON_DEPTH = 1
local CHEVRON_BAR = 0.46
local CHEVRON_RIM = 0.16
-- Studs per second the chevrons travel toward the target.
local CHEVRON_FLOW = 3.4
-- Above the floor paint (World.Decor: its top layer ends 0.12 over the floor).
local CHEVRON_LIFT = 0.15
-- A "navigate" trail shows only from this far, or after standing still this long.
local TRAIL_DISTANCE = 12
local IDLE_SECONDS = 4
-- A standing hint: how long its trail shows after it is set, and the distance from which
-- it shows nothing (the player is off the plot, in the plaza or on a course).
local HINT_TRAIL_SECONDS = 20
local HINT_RANGE = 110
-- Route: how close a leg may pass the pen's footprint (a character's half width), and how
-- far off its corners the route turns.
local ROUTE_BODY = 1.2
local ROUTE_TURN = 3
-- Beam of light over the tutorial's target: height, and each layer's width and transparency
-- at the foot (wide and faint to narrow and bright; every layer fades out to the top).
-- It fades away within BEAM_NEAR studs so the pad's own label is not washed out.
local BEAM_HEIGHT = 70
local BEAM_LAYERS = { { width = 7, base = 0.86 }, { width = 4, base = 0.74 }, { width = 1.8, base = 0.5 } }
local BEAM_CORE = 0.5
local BEAM_CORE_OPACITY = 0.4
local BEAM_NEAR = 9
-- Fade speed (per second, exponential ease toward the goal).
local FADE_RATE = 6

type Chevron = { fills: { Part }, rims: { Part }, shown: boolean }
-- The pen as the route sees it, in the frame of its floor (plot axes): the open floor's half
-- size, the footprint's (corner posts included; 0 = none found) and the stairs over the side
-- walls (`outer` / `inner`: how far from the centre line the steps start outside and end inside).
type Stair = { side: number, z: number, outer: number, inner: number }
type Pen = { field: BasePart, frame: CFrame, top: number, inX: number, inZ: number, halfX: number, halfZ: number, stairs: { Stair } }

local folder: Folder
local anchor: Part
local marker: BillboardGui
local markerBars: { Frame } = {}
local tag: BillboardGui
local tagLabel: TextLabel
local tagEdge: UIStroke?
local chevrons: { Chevron } = {}
local trailShown = false
local beams: { Beam } = {}
local beamCore: Part? = nil
local rayParams: RaycastParams? = nil

local pen: Pen? = nil
local penPlot: Instance? = nil
local penLooked = 0

local tutorialTarget: string? = nil
local tutorialText = ""
local navTarget: string? = nil
local navText = ""
local navUntil = 0
local hintTarget: string? = nil
local hintText = ""
local hintSince = 0

local currentPart: BasePart? = nil
local currentName: string? = nil
local lastResolve = 0

-- Eased visibility (0..1) of the marker, the trail and the beam.
local markerAlpha = 0
local trailAlpha = 0
local beamAlpha = 0
local beamPainted = -1
local beamColor: Color3? = nil
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

-- Reads the pen off the plot's parts (World.Pen: "Field", "PenPost", "PenStep", all built on
-- the plot's axes): the client has no PlotLayout.
local function findPen(plot: Instance): Pen?
	local field = plot:FindFirstChild("Field", true)
	if not field or not field:IsA("BasePart") or not field.Parent then
		return nil
	end
	local frame = field.CFrame
	local halfX, halfZ = 0, 0
	local bySide: { [number]: Stair } = {}
	for _, child in field.Parent:GetChildren() do
		if child:IsA("BasePart") and (child.Name == "PenPost" or child.Name == "PenStep") then
			local at = frame:PointToObjectSpace(child.CFrame.Position)
			local reach, half = math.abs(at.X), child.Size.X / 2
			if child.Name == "PenPost" then
				halfX = math.max(halfX, reach + half)
				halfZ = math.max(halfZ, math.abs(at.Z) + child.Size.Z / 2)
			else
				local side = if at.X < 0 then -1 else 1
				local stair = bySide[side]
				if stair then
					stair.outer = math.max(stair.outer, reach + half)
					stair.inner = math.min(stair.inner, reach - half)
				else
					bySide[side] = { side = side, z = at.Z, outer = reach + half, inner = reach - half }
				end
			end
		end
	end
	local stairs: { Stair } = {}
	for _, stair in bySide do
		table.insert(stairs, stair)
	end
	return {
		field = field,
		frame = frame,
		top = frame.Position.Y + field.Size.Y / 2,
		inX = field.Size.X / 2,
		inZ = field.Size.Z / 2,
		halfX = halfX,
		halfZ = halfZ,
		stairs = stairs,
	}
end

-- The player's plot's pen, looked up once (and again every other second while it is missing
-- or incomplete).
local function currentPen(): Pen?
	local plot = plotFolder()
	if not plot then
		return nil
	end
	local known = pen
	local complete = known ~= nil and plot == penPlot and known.field.Parent ~= nil and known.halfX > 0 and #known.stairs > 0
	if not complete and (plot ~= penPlot or os.clock() - penLooked > 2) then
		penLooked = os.clock()
		penPlot = plot
		pen = findPen(plot)
	end
	return pen
end

-- True when the pen-frame point (x, z) is on the pen's floor (or the inner half of a wall top).
local function inPen(p: Pen, x: number, z: number): boolean
	return math.abs(x) < p.inX + 0.8 and math.abs(z) < p.inZ + 0.8
end

--[[
	Routing, in the pen's frame as Vector2 (x, z). The pen is the one thing on a plot that a
	straight walk between two pads clips (its corner posts) or cannot cross (its walls).
]]

-- True when the leg a-b passes through the box |x| < hx, |z| < hz. Touching an edge is not
-- crossing: the box is taken a hair smaller, as a point put on an edge (pushOut) is stored
-- in single precision and may land just inside it.
local function crosses(a: Vector2, b: Vector2, hx: number, hz: number): boolean
	local t0, t1 = 0, 1
	for axis = 1, 2 do
		local from = if axis == 1 then a.X else a.Y
		local step = if axis == 1 then b.X - a.X else b.Y - a.Y
		local half = (if axis == 1 then hx else hz) - 0.01
		if math.abs(step) < 1e-6 then
			if math.abs(from) >= half then
				return false
			end
		else
			local enter, leave = (-half - from) / step, (half - from) / step
			if enter > leave then
				enter, leave = leave, enter
			end
			t0, t1 = math.max(t0, enter), math.min(t1, leave)
			if t0 >= t1 then
				return false
			end
		end
	end
	return true
end

-- A point inside the box moved to its nearest edge (a character leaning on the pen's wall).
local function pushOut(point: Vector2, hx: number, hz: number): Vector2
	local dx, dz = hx - math.abs(point.X), hz - math.abs(point.Y)
	if dx <= 0 or dz <= 0 then
		return point
	end
	if dx < dz then
		return Vector2.new(if point.X < 0 then -hx else hx, point.Y)
	end
	return Vector2.new(point.X, if point.Y < 0 then -hz else hz)
end

-- The corners to turn at on the shortest walk from a to b round the pen (none when the
-- straight leg is clear), both points outside it. Only its two front corners (-Z, toward
-- the entrance) are used: the gutter and the chute stand behind it.
local function aroundPen(p: Pen, a: Vector2, b: Vector2): { Vector2 }
	if p.halfX <= 0 then
		return {}
	end
	local hx, hz = p.halfX + ROUTE_BODY, p.halfZ + ROUTE_BODY
	a, b = pushOut(a, hx, hz), pushOut(b, hx, hz)
	if not crosses(a, b, hx, hz) then
		return {}
	end
	local tx, tz = p.halfX + ROUTE_TURN, p.halfZ + ROUTE_TURN
	local corners = { Vector2.new(tx, -tz), Vector2.new(-tx, -tz) }
	local best: { Vector2 } = {}
	local bestLength = math.huge
	for i, first in corners do
		if not crosses(a, first, hx, hz) then
			local reach = (first - a).Magnitude
			local second = corners[3 - i]
			if not crosses(first, b, hx, hz) then
				local length = reach + (b - first).Magnitude
				if length < bestLength then
					best, bestLength = { first }, length
				end
			elseif not crosses(second, b, hx, hz) then
				-- Along the front of the pen to its other corner.
				local length = reach + (second - first).Magnitude + (b - second).Magnitude
				if length < bestLength then
					best, bestLength = { first, second }, length
				end
			end
		end
	end
	return best
end

local function pathLength(points: { Vector2 }): number
	local length = 0
	for i = 2, #points do
		length += (points[i] - points[i - 1]).Magnitude
	end
	return length
end

-- The walk from a to b: straight where it can be, round the pen's corners, and over the
-- nearer side stairs when exactly one end is inside the pen.
local function routeInPen(p: Pen, a: Vector2, b: Vector2): { Vector2 }
	local aIn, bIn = inPen(p, a.X, a.Y), inPen(p, b.X, b.Y)
	if aIn and bIn then
		return { a, b }
	end
	if aIn == bIn or #p.stairs == 0 then
		local points = { a }
		table.move(aroundPen(p, a, b), 1, 2, 2, points)
		table.insert(points, b)
		return points
	end
	-- `inner` is the end inside the pen; the route is built outside-in and turned round after.
	local inner, outer = if aIn then a else b, if aIn then b else a
	local best: { Vector2 } = {}
	local bestLength = math.huge
	for _, stair in p.stairs do
		local foot = Vector2.new(stair.side * (stair.outer + 1), stair.z)
		local landing = Vector2.new(stair.side * (stair.inner - 0.6), stair.z)
		local points = { outer }
		table.move(aroundPen(p, outer, foot), 1, 2, 2, points)
		table.insert(points, foot)
		-- Already on these steps (or the target is right at their foot): no step back to the landing.
		local onSteps = stair.side * inner.X >= stair.side * landing.X and math.abs(inner.Y - stair.z) < 2.5
		if not onSteps then
			table.insert(points, landing)
		end
		table.insert(points, inner)
		local length = pathLength(points)
		if length < bestLength then
			best, bestLength = points, length
		end
	end
	if aIn then
		local turned = table.create(#best)
		for i = #best, 1, -1 do
			table.insert(turned, best[i])
		end
		return turned
	end
	return best
end

-- The route from `from` to `to` as flat world points (y = 0), the two ends included.
local function route(from: Vector3, to: Vector3): { Vector3 }
	local p = currentPen()
	if not p then
		return { Vector3.new(from.X, 0, from.Z), Vector3.new(to.X, 0, to.Z) }
	end
	local a, b = p.frame:PointToObjectSpace(from), p.frame:PointToObjectSpace(to)
	local points: { Vector3 } = {}
	for _, point in routeInPen(p, Vector2.new(a.X, a.Z), Vector2.new(b.X, b.Z)) do
		local world = p.frame:PointToWorldSpace(Vector3.new(point.X, 0, point.Y))
		table.insert(points, Vector3.new(world.X, 0, world.Z))
	end
	return points
end

local function resolve(name: string): BasePart?
	local plot = plotFolder()
	if not plot then
		return nil
	end
	if name == "Orbs" then
		local orbs = plot:FindFirstChild("Orbs", true)
		local root = rootPart()
		-- An orb on the pen floor first: one still rolling down the gutter is behind the pen.
		local p = currentPen()
		local best: BasePart? = nil
		local bestDistance = math.huge
		local bestInPen = false
		if orbs and root then
			local from = root.CFrame.Position
			for _, orb in orbs:GetChildren() do
				if orb:IsA("BasePart") then
					local d = (orb.CFrame.Position - from).Magnitude
					local at = if p then p.frame:PointToObjectSpace(orb.CFrame.Position) else nil
					local inside = p ~= nil and at ~= nil and inPen(p, at.X, at.Z)
					if (inside and not bestInPen) or (inside == bestInPen and d < bestDistance) then
						best, bestDistance, bestInPen = orb, d, inside
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

-- The target, its tag text, and who asked for it: the tutorial (not a "navigate" request),
-- or the standing hint.
local function activeTarget(): (string?, string, boolean, boolean)
	if navTarget and os.clock() < navUntil then
		return navTarget, navText, false, false
	end
	navTarget = nil
	if tutorialTarget then
		return tutorialTarget, tutorialText, true, false
	end
	return hintTarget, hintText, false, hintTarget ~= nil
end

-- The palette colour that matches what the target does.
local function colorFor(name: string): Color3
	local pads = World.Pads
	if name == "Orbs" then
		return World.Pink
	elseif string.sub(name, 1, 3) == "Buy" then
		return pads.Buy
	elseif string.sub(name, 1, 6) == "ProcUp" then
		return pads.Process
	elseif name == "Unlock1" then
		return pads.Unlock
	elseif name == "Unlock2" then
		return pads.UnlockVip
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

local function ghost(part: Part, name: string): Part
	part.Name = name
	part.Transparency = 1
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Parent = folder
	return part
end

-- Each chevron is two glowing bars meeting at the tip, each on a slightly larger dark bar.
local function buildTrail()
	local length = math.sqrt(CHEVRON_DEPTH ^ 2 + CHEVRON_HALF ^ 2) + CHEVRON_BAR * 0.6
	for i = 1, CHEVRONS do
		local chevron: Chevron = { fills = {}, rims = {}, shown = false }
		for side = 1, 2 do
			local rim = ghost(Instance.new("Part"), "GuideChevronRim" .. i)
			rim.Size = Vector3.new(CHEVRON_BAR + CHEVRON_RIM * 2, 0.04, length + CHEVRON_RIM * 2)
			rim.Material = Enum.Material.SmoothPlastic
			rim.Color = World.Ink
			chevron.rims[side] = rim
			local fill = ghost(Instance.new("Part"), "GuideChevron" .. i)
			fill.Size = Vector3.new(CHEVRON_BAR, 0.05, length)
			fill.Material = Enum.Material.Neon
			fill.Color = World.Sunny
			chevron.fills[side] = fill
		end
		chevrons[i] = chevron
	end
end

-- The beam hangs on the marker's anchor, so it glides to a new target with the marker.
-- Optional: an environment without Beams (or Attachments) just has no beam.
local function buildBeam(parent: Instance)
	pcall(function()
		local foot = Instance.new("Attachment")
		foot.Name = "BeamFoot"
		foot.Parent = parent
		local top = Instance.new("Attachment")
		top.Name = "BeamTop"
		top.CFrame = CFrame.new(0, BEAM_HEIGHT, 0)
		top.Parent = parent
		for i in BEAM_LAYERS do
			local beam = Instance.new("Beam")
			beam.Name = "GuideBeam" .. i
			beam.Attachment0 = foot
			beam.Attachment1 = top
			beam.FaceCamera = true
			-- Enough segments for the fade along its height to be smooth.
			beam.Segments = 12
			beam.LightEmission = 0.7
			beam.LightInfluence = 0
			beam.Transparency = NumberSequence.new(1)
			beam.Enabled = false
			beam.Parent = parent
			beams[i] = beam
		end
		local core = ghost(Instance.new("Part"), "GuideBeamCore")
		core.Shape = Enum.PartType.Cylinder
		core.Size = Vector3.new(BEAM_HEIGHT * 0.5, BEAM_CORE, BEAM_CORE)
		core.Material = Enum.Material.Neon
		beamCore = core
	end)
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

	-- Optional: the preview exporter has no raycasts (the trail then lies at foot level).
	pcall(function()
		local params = RaycastParams.new()
		params.FilterType = Enum.RaycastFilterType.Exclude
		params.IgnoreWater = true
		rayParams = params
	end)

	buildMarker(anchor)
	buildTrail()
	buildBeam(anchor)

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

-- The beam at `beamAlpha`, tinted toward `color` and breathing a little. The sequences are
-- rebuilt only when the fade or the colour moved.
local function paintBeam(clock: number, color: Color3)
	local core = beamCore
	if #beams == 0 or not core then
		return
	end
	local on = beamAlpha > 0.01
	if on then
		local breath = 1 + 0.07 * math.sin(clock * 2.4)
		for i, beam in beams do
			local width = BEAM_LAYERS[i].width * breath
			beam.Width0 = width
			beam.Width1 = width * 0.55
		end
		-- The core starts above the pad's labels and the marker.
		local at = anchor.CFrame.Position + Vector3.new(0, MARKER_HEIGHT + 3 + core.Size.X / 2, 0)
		core.CFrame = CFrame.new(at) * CFrame.Angles(0, 0, math.rad(90))
	end
	if color ~= beamColor then
		beamColor = color
		local light = color:Lerp(World.White, 0.35)
		for _, beam in beams do
			beam.Color = ColorSequence.new(light, World.White)
		end
		core.Color = light
	end
	if math.abs(beamAlpha - beamPainted) < 0.01 and on == beams[1].Enabled then
		return
	end
	beamPainted = beamAlpha
	for i, beam in beams do
		beam.Enabled = on
		local foot = 1 - (1 - BEAM_LAYERS[i].base) * beamAlpha
		beam.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, foot),
			NumberSequenceKeypoint.new(0.3, foot + (1 - foot) * 0.25),
			NumberSequenceKeypoint.new(1, 1),
		})
	end
	core.Transparency = if on then 1 - BEAM_CORE_OPACITY * beamAlpha else 1
end

-- What the trail's ground rays skip: the guide itself, every character and the orbs.
local function refreshRayFilter()
	local params = rayParams
	if not params then
		return
	end
	local ignore: { Instance } = { folder }
	for _, other in Players:GetPlayers() do
		if other.Character then
			table.insert(ignore, other.Character)
		end
	end
	local plot = plotFolder()
	local orbs = plot and plot:FindFirstChild("Orbs", true)
	if orbs then
		table.insert(ignore, orbs)
	end
	params.FilterDescendantsInstances = ignore
end

-- Floor height at the flat point (x, z), looked for between `high` and `low`. Anything
-- taller than a step above `floor` (a prop, a machine) is not floor: the trail stays under it.
local function groundY(x: number, z: number, high: number, low: number, floor: number?): number
	local fallback = floor or low
	local params = rayParams
	if not params then
		return fallback
	end
	local hit = Workspace:Raycast(Vector3.new(x, high + 4, z), Vector3.new(0, low - high - 7, 0), params)
	if not hit or (floor and hit.Position.Y > floor + 2.5) then
		return fallback
	end
	return hit.Position.Y
end

local function hideTrail()
	if not trailShown then
		return
	end
	trailShown = false
	for _, chevron in chevrons do
		if chevron.shown then
			chevron.shown = false
			for side = 1, 2 do
				chevron.fills[side].Transparency = 1
				chevron.rims[side].Transparency = 1
			end
		end
	end
end

-- Lays the chevrons along the route from the player to `target`, `endGap` short of it. They
-- are spaced back from the target's end and travel toward it, so walking does not drag them.
local function paintTrail(clock: number, root: BasePart?, target: Vector3?, endGap: number, color: Color3)
	if trailAlpha < 0.01 or not root or not target then
		hideTrail()
		return
	end
	local rootPos = root.CFrame.Position
	local points = route(rootPos, target)
	local lengths = table.create(#points - 1)
	local total = 0
	for i = 1, #points - 1 do
		lengths[i] = (points[i + 1] - points[i]).Magnitude
		total += lengths[i]
	end
	local first, last = TRAIL_LEAD, total - endGap
	if last - first <= 0.5 then
		hideTrail()
		return
	end
	local character = Players.LocalPlayer.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local footY = rootPos.Y - root.Size.Y * 0.5 - (if humanoid then humanoid.HipHeight else 2)
	-- The plot's floor (the pen floor lies 0.15 above it), when the player is on or near it.
	local p = pen
	local floor: number? = if p and math.abs(footY - p.top) < 30 then p.top - 0.15 else nil
	local high, low = math.max(footY, floor or footY), math.min(footY, floor or footY)
	local phase = (clock * CHEVRON_FLOW) % CHEVRON_SPACING
	trailShown = true
	for k, chevron in chevrons do
		local s = last - (k * CHEVRON_SPACING - phase)
		-- Eased in ahead of the player and out at the target.
		local fade = trailAlpha * math.clamp((s - first) / 2.5, 0, 1) * math.clamp((last - s) / 1.5, 0, 1)
		if fade < 0.02 then
			if chevron.shown then
				chevron.shown = false
				for side = 1, 2 do
					chevron.fills[side].Transparency = 1
					chevron.rims[side].Transparency = 1
				end
			end
			continue
		end
		local leg, along = 1, s
		while leg < #lengths and along > lengths[leg] do
			along -= lengths[leg]
			leg += 1
		end
		if lengths[leg] < 0.01 then
			continue
		end
		local direction = (points[leg + 1] - points[leg]) / lengths[leg]
		local across = Vector3.new(-direction.Z, 0, direction.X)
		local at = points[leg] + direction * along
		local y = groundY(at.X, at.Z, high, low, floor) + CHEVRON_LIFT
		local tip = Vector3.new(at.X, y, at.Z) + direction * (CHEVRON_DEPTH / 2)
		chevron.shown = true
		for side = 1, 2 do
			local tail = tip - direction * CHEVRON_DEPTH + across * (if side == 1 then -CHEVRON_HALF else CHEVRON_HALF)
			local frame = CFrame.lookAt((tip + tail) / 2, tip)
			local fill, rim = chevron.fills[side], chevron.rims[side]
			rim.CFrame = frame
			rim.Transparency = 1 - 0.55 * fade
			fill.CFrame = frame + Vector3.new(0, 0.05, 0)
			fill.Color = color
			fill.Transparency = 1 - 0.95 * fade
		end
	end
end

-- How far short of a target's centre the trail ends: at the edge of its footprint.
local function reachOf(part: BasePart): number
	local size = part.Size
	local smallest = math.min(size.X, size.Y, size.Z)
	local largest = math.max(size.X, size.Y, size.Z)
	return (size.X + size.Y + size.Z - smallest - largest) / 2 + TRAIL_END_GAP
end

local function hideAll(clock: number, dt: number?)
	markerAlpha = approach(markerAlpha, 0, dt)
	trailAlpha = approach(trailAlpha, 0, dt)
	beamAlpha = approach(beamAlpha, 0, dt)
	paintMarker()
	paintBeam(clock, beamColor or World.Sunny)
	hideTrail()
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
	local name, text, fromTutorial, fromHint = activeTarget()
	if not name or (player and player:GetAttribute("IntroPlaying") == true) then
		hideAll(clock, dt)
		return
	end
	if name ~= currentName or os.clock() - lastResolve > 0.25 or not currentPart or not currentPart.Parent then
		lastResolve = os.clock()
		currentName = name
		currentPart = resolve(name)
		refreshRayFilter()
	end
	local part = currentPart
	if not part then
		hideAll(clock, dt)
		return
	end
	local color = colorFor(name)
	local position = part.CFrame.Position
	local root = rootPart()
	-- A hint is for a player on the plot: from the plaza or a course it shows nothing.
	if fromHint and root then
		local rootPos = root.CFrame.Position
		if Vector3.new(position.X - rootPos.X, 0, position.Z - rootPos.Z).Magnitude > HINT_RANGE then
			hideAll(clock, dt)
			return
		end
	end
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

	local wantTrail = false
	local wantBeam = false
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
		-- The tutorial's path is always there; a "navigate" one only when it is needed; a
		-- hint's only while it is new, or for a player who stands still.
		local far = distance > TRAIL_DISTANCE and not (fromHint and os.clock() - hintSince > HINT_TRAIL_SECONDS)
		-- A "navigate" request was asked for (the crate panel's "Carry it to the Crate
		-- Smasher"): it gets the whole path, floor trail and beam, like a tutorial step.
		local asked = fromTutorial or not fromHint
		wantTrail = asked or far or idleFor >= IDLE_SECONDS
		wantBeam = asked and distance > BEAM_NEAR
	end
	trailAlpha = approach(trailAlpha, if wantTrail then 1 else 0, dt)
	beamAlpha = approach(beamAlpha, if wantBeam then 1 else 0, dt)
	paintBeam(clock, color)
	paintTrail(clock, root, position, reachOf(part), color)
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

-- The standing hint (nil clears it): shown while neither the tutorial nor a "navigate"
-- request has a target. Setting the same target again changes nothing (its trail timer
-- keeps running), so callers may repeat it on every refresh.
function Guide.setHint(name: string?, text: string?)
	if name ~= hintTarget then
		hintTarget = name
		hintSince = os.clock()
		currentPart = nil
	end
	hintText = text or ""
end

return Guide
