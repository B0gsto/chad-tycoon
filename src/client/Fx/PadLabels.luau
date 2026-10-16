--[[
	Fx.PadLabels: keeps the pads' floating labels from ballooning up close.

	World.Pads tags every pad label (BillboardGui "PadLabel") with "PadLabel" and stores its
	stud + pixel size in the "BaseSize" attribute. Every frame each label's depth in front of
	the camera gives its natural on-screen size; past Shared.PadLabelSize's cap (a share of the
	viewport's height) the label is pinned at the capped pixel size, and it gets its stud size
	back once the camera is far enough again. Labels are only written when they cross the cap
	or the capped size changes (viewport resize, FOV kick), so the far labels cost a dot product.

	A label with two placements ("NearOffset" / "FarOffset", in its StudsOffsetWorldSpace frame,
	e.g. Buy 1's: over its pad up close, high and back from the plot's entrance) glides between
	them by the camera's distance from its pad (Shared.PadLabelSize.placement). Only labels whose
	placements differ, on the local player's plot and within their MaxDistance are moved, and
	only when the blend changed by more than BLEND_EPSILON.

	Every DECLUTTER_PERIOD the local plot's labels in view are projected to screen rects and
	Shared.PadLabelSize.declutter picks the ones that hide behind a nearer label (looking along
	the buy row the far ones stack up): those fade out over FADE_TIME and back once clear. The
	label of the pad the player stands at (nearest to the character) is never faded. A label
	has no transparency of its own, so a fading label's elements are moved into a CanvasGroup
	("Declutter") whose GroupTransparency is tweened; once back in full they are moved out
	again and the group is dropped, so a shown label renders exactly as World.Pads built it.
]]

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local PadLabelSize = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("PadLabelSize"))
local State = require(script.Parent.Parent.State)

local TAG = "PadLabel"
-- Pixel change below which a capped label is not resized again.
local EPSILON = 0.5
-- Blend change (0..1) below which a gliding label is not moved again (under 0.02 studs here).
local BLEND_EPSILON = 0.004
-- Seconds between declutter passes, and how long a label takes to fade out or back in.
local DECLUTTER_PERIOD = 0.1
local FADE_TIME = 0.15
local FADE_INFO = TweenInfo.new(FADE_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

local PadLabels = {}

type Entry = { base: UDim2, capped: boolean, w: number, h: number }
-- A label with two placements and how far (0 near .. 1 far) it currently sits between them.
type Glide = { near: Vector3, far: Vector3, t: number }

local entries: { [BillboardGui]: Entry } = {}
local glides: { [BillboardGui]: Glide } = {}
-- Labels faded (or fading back in) by the declutter: the group holding their elements.
type Fade = { group: CanvasGroup, out: boolean, tween: Tween? }
local fades: { [BillboardGui]: Fade } = {}
local sinceDeclutter = 0
-- Diagnostics for the TEST bridge (PadLabels.diagnostics): passes run, the last error and the
-- last pass's labels, with why each was skipped or how it was judged.
local diag = {
	passes = 0,
	errors = 0,
	lastError = nil :: string?,
	labels = {} :: { any },
	at = 0,
	plot = nil :: string?,
	viewport = nil :: { number }?,
}

local function baseOf(gui: BillboardGui): UDim2
	local base = gui:GetAttribute("BaseSize")
	return if typeof(base) == "UDim2" then base else gui.Size
end

local function add(gui: Instance)
	if not gui:IsA("BillboardGui") or entries[gui] then
		return
	end
	entries[gui] = { base = baseOf(gui), capped = false, w = 0, h = 0 }
	local near, far = gui:GetAttribute("NearOffset"), gui:GetAttribute("FarOffset")
	if typeof(near) == "Vector3" and typeof(far) == "Vector3" and (near - far).Magnitude > 0.01 then
		glides[gui] = { near = near, far = far, t = 1 }
	end
end

local function remove(gui: Instance)
	entries[gui :: BillboardGui] = nil
	glides[gui :: BillboardGui] = nil
	local fade = fades[gui :: BillboardGui]
	if fade then
		fades[gui :: BillboardGui] = nil
		if fade.tween then
			fade.tween:Cancel()
		end
	end
end

-- Fades a label out (`out`) or back in. Fading out wraps its elements in a CanvasGroup;
-- once back in they are unwrapped and the group goes.
local function setFaded(gui: BillboardGui, out: boolean)
	local fade = fades[gui]
	if not fade then
		if not out then
			return
		end
		local group = Instance.new("CanvasGroup")
		group.Name = "Declutter"
		group.Size = UDim2.fromScale(1, 1)
		group.BackgroundTransparency = 1
		group.BorderSizePixel = 0
		group.GroupTransparency = 0
		for _, child in gui:GetChildren() do
			if child:IsA("GuiObject") then
				child.Parent = group
			end
		end
		group.Parent = gui
		fade = { group = group, out = false, tween = nil }
		fades[gui] = fade
	end
	local f = fade :: Fade
	if f.out == out and f.tween then
		return
	end
	f.out = out
	if f.tween then
		f.tween:Cancel()
	end
	local tween = TweenService:Create(f.group, FADE_INFO, { GroupTransparency = if out then 1 else 0 })
	f.tween = tween
	tween.Completed:Connect(function(state)
		if state ~= Enum.PlaybackState.Completed or fades[gui] ~= f or f.out then
			return
		end
		fades[gui] = nil
		for _, child in f.group:GetChildren() do
			child.Parent = gui
		end
		f.group:Destroy()
	end)
	tween:Play()
end

local function ownPlot(): Instance?
	local data = State.data
	local map = Workspace:FindFirstChild("Map")
	if not data or not map or not data.plotIndex then
		return nil
	end
	return map:FindFirstChild("Plot" .. data.plotIndex)
end

-- Glides the labels with two placements on the player's own plot (labels elsewhere go back to
-- their far placement, the one World.Pads gave them).
local function glide(eye: Vector3)
	if next(glides) == nil then
		return
	end
	local plot = ownPlot()
	for gui, g in glides do
		local adornee = gui.Adornee
		if not (adornee and adornee:IsA("BasePart")) then
			continue
		end
		local t = 1
		if plot and gui.Enabled and gui:IsDescendantOf(plot) then
			local distance = (adornee.Position - eye).Magnitude
			if distance > gui.MaxDistance then
				continue
			end
			t = PadLabelSize.blend(distance)
		end
		-- Always land exactly on either end; in between only move past BLEND_EPSILON.
		if t ~= g.t and (t == 0 or t == 1 or math.abs(t - g.t) > BLEND_EPSILON) then
			g.t = t
			gui.StudsOffsetWorldSpace = g.near:Lerp(g.far, t)
		end
	end
end

local function anchorOf(gui: BillboardGui, adornee: BasePart): Vector3
	return adornee.Position + adornee.CFrame:VectorToWorldSpace(gui.StudsOffsetWorldSpace)
end

-- The fade group's state for the diagnostics: what it holds and what is left outside it.
local function groupReport(gui: BillboardGui, fade: Fade): { [string]: any }
	local outside = {}
	for _, child in gui:GetChildren() do
		if child ~= fade.group and child:IsA("GuiObject") and child.Visible then
			table.insert(outside, child.Name)
		end
	end
	local size = fade.group.AbsoluteSize
	return {
		out = fade.out,
		transparency = math.round(fade.group.GroupTransparency * 100) / 100,
		visible = fade.group.Visible,
		parented = fade.group.Parent == gui,
		inside = #fade.group:GetChildren(),
		outside = outside,
		absSize = { math.round(size.X), math.round(size.Y) },
	}
end

type Candidate = { gui: BillboardGui, rect: PadLabelSize.Rect, distance: number, keep: boolean }

-- Fades the local plot's labels that a nearer label covers on screen (see the header).
local function declutter(camera: Camera)
	local plot = ownPlot()
	local eye = camera.CFrame.Position
	local look = camera.CFrame.LookVector
	local viewport = camera.ViewportSize
	local fov = camera.FieldOfView
	local character = Players.LocalPlayer.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	local feet = if root and root:IsA("BasePart") then root.Position else nil
	local list: { Candidate } = {}
	local skipped: { any } = {}
	local nearest: Candidate?, nearestGap = nil, math.huge
	local function skip(gui: BillboardGui, why: string)
		local adornee = gui.Adornee
		table.insert(skipped, {
			name = if adornee then adornee.Name else gui:GetFullName(),
			skipped = why,
			distance = if adornee then math.round((adornee.Position - eye).Magnitude * 10) / 10 else nil,
		})
	end
	if plot then
		for gui, entry in entries do
			local adornee = gui.Adornee
			if not (adornee and adornee:IsA("BasePart") and gui.Enabled and gui:IsDescendantOf(plot)) then
				if gui:IsDescendantOf(plot) then
					skip(gui, if not gui.Enabled then "disabled" else "no adornee")
				end
				continue
			end
			local pos = anchorOf(gui, adornee)
			local distance = (pos - eye).Magnitude
			local depth = (pos - eye):Dot(look)
			if depth <= 0 or (adornee.Position - eye).Magnitude > gui.MaxDistance then
				skip(gui, if depth <= 0 then "behind camera" else "past MaxDistance")
				continue
			end
			local point = camera:WorldToViewportPoint(pos)
			local base = entry.base
			local w, h = PadLabelSize.size(base.X.Scale, base.X.Offset, base.Y.Scale, base.Y.Offset, depth, viewport.Y, fov)
			if point.X + w / 2 < 0 or point.X - w / 2 > viewport.X or point.Y + h / 2 < 0 or point.Y - h / 2 > viewport.Y then
				skip(gui, "off screen")
				continue
			end
			local c: Candidate = { gui = gui, rect = { x = point.X, y = point.Y, w = w, h = h }, distance = distance, keep = false }
			table.insert(list, c)
			if feet then
				local gap = Vector2.new(adornee.Position.X - feet.X, adornee.Position.Z - feet.Z).Magnitude
				if gap < nearestGap then
					nearest, nearestGap = c, gap
				end
			end
		end
	end
	if nearest then
		nearest.keep = true
	end
	-- The kept label first (so it always counts as shown), then nearest the camera first.
	table.sort(list, function(a, b)
		if a.keep ~= b.keep then
			return a.keep
		end
		return a.distance < b.distance
	end)
	local rects, faded, keep = {}, {}, {}
	for i, c in list do
		rects[i] = c.rect
		local fade = fades[c.gui]
		faded[i] = fade ~= nil and fade.out
		keep[i] = c.keep
	end
	local result, shares, covers = PadLabelSize.declutter(rects, faded, keep)
	local seen: { [BillboardGui]: boolean } = {}
	local report: { any } = {}
	for i, c in list do
		seen[c.gui] = true
		if result[i] ~= faded[i] then
			setFaded(c.gui, result[i])
		end
		local r = c.rect
		local cover = list[covers[i]]
		local adornee = c.gui.Adornee :: BasePart
		local fade = fades[c.gui]
		table.insert(report, {
			name = adornee.Name,
			distance = math.round(c.distance * 10) / 10,
			rect = { math.round(r.x - r.w / 2), math.round(r.y - r.h / 2), math.round(r.w), math.round(r.h) },
			onScreen = true,
			keep = c.keep,
			faded = result[i],
			fadeGroup = if fade then groupReport(c.gui, fade) else nil,
			overlap = math.round(shares[i] * 1000) / 1000,
			cover = if cover then (cover.gui.Adornee :: BasePart).Name else nil,
		})
	end
	for _, s in skipped do
		table.insert(report, s)
	end
	diag.labels = report
	diag.plot = if plot then plot.Name else nil
	diag.viewport = { math.round(viewport.X), math.round(viewport.Y) }
	diag.at = os.clock()
	-- Labels out of view or off the plot come back.
	for gui, fade in fades do
		if fade.out and not seen[gui] then
			setFaded(gui, false)
		end
	end
end

local function step(dt: number)
	local camera = Workspace.CurrentCamera
	if not camera then
		return
	end
	sinceDeclutter += dt
	if sinceDeclutter >= DECLUTTER_PERIOD then
		sinceDeclutter = 0
		diag.passes += 1
		local ok, err = pcall(declutter, camera)
		if not ok then
			diag.errors += 1
			diag.lastError = tostring(err)
		end
	end
	local eye = camera.CFrame.Position
	local look = camera.CFrame.LookVector
	local viewportY = camera.ViewportSize.Y
	local fov = camera.FieldOfView
	glide(eye)
	for gui, entry in entries do
		local adornee = gui.Adornee
		if not (adornee and adornee:IsA("BasePart") and gui.Enabled) then
			continue
		end
		local pos = anchorOf(gui, adornee)
		local depth = (pos - eye):Dot(look)
		local base = entry.base
		local w, h, capped = PadLabelSize.size(base.X.Scale, base.X.Offset, base.Y.Scale, base.Y.Offset, depth, viewportY, fov)
		if capped then
			if not entry.capped or math.abs(w - entry.w) > EPSILON or math.abs(h - entry.h) > EPSILON then
				entry.capped, entry.w, entry.h = true, w, h
				gui.Size = UDim2.fromOffset(w, h)
			end
		elseif entry.capped then
			entry.capped = false
			gui.Size = base
		end
	end
end

-- What the last declutter pass saw (TEST bridge `labels`): passes run, errors caught, the last
-- error and every label on the local plot (rect = left, top, width, height in viewport px).
function PadLabels.diagnostics(): { [string]: any }
	local tracked = 0
	for _ in entries do
		tracked += 1
	end
	return {
		passes = diag.passes,
		errors = diag.errors,
		lastError = diag.lastError,
		secondsSincePass = math.round((os.clock() - diag.at) * 100) / 100,
		tracked = tracked,
		plot = diag.plot,
		viewport = diag.viewport,
		labels = diag.labels,
	}
end

function PadLabels.init()
	for _, gui in CollectionService:GetTagged(TAG) do
		add(gui)
	end
	CollectionService:GetInstanceAddedSignal(TAG):Connect(add)
	CollectionService:GetInstanceRemovedSignal(TAG):Connect(remove)
	RunService.RenderStepped:Connect(step)
end

return PadLabels
