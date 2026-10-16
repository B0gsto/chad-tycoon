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
	label of the pad the player stands at (nearest to the character) is never faded. The plot's
	other floating signs (tagged "PlotSign" by the server, e.g. a crate cracker's READY! pill)
	join the declutter at their own size, so a nearer sign hides a farther one whatever its
	kind; they are never resized or moved. A label
	has no transparency of its own, so a fading label's elements are moved into a CanvasGroup
	("Declutter") whose GroupTransparency is tweened; once back in full they are moved out
	again and the group is dropped, so a shown label renders exactly as World.Pads built it.
	A BillboardGui does not honour GroupTransparency (the TEST bridge's `labels` showed a group
	at 1 holding every element while the sign still drew), so once faded out the group is also
	hidden (Visible = false) and shown again as it starts back in.

	The HUD's top-centre stack (count/surge row, NEXT plate with its afford hint, run or
	tutorial pill; up to three rows) also hides what is under it: it joins the declutter as a
	shown sign, so a label it covers fades like any other. The kept label is moved down instead
	(along the camera's down, by just enough pixels for its top to clear the stack), easing
	there and back over NUDGE_RATE.
]]

local CollectionService = game:GetService("CollectionService")
local GuiService = game:GetService("GuiService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local PadLabelSize = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("PadLabelSize"))
local State = require(script.Parent.Parent.State)

local TAG = "PadLabel"
-- The plot's other floating signs: decluttered with the pad labels, nothing else.
local SIGN_TAG = "PlotSign"
-- Pixel change below which a capped label is not resized again.
local EPSILON = 0.5
-- Blend change (0..1) below which a gliding label is not moved again (under 0.02 studs here).
local BLEND_EPSILON = 0.004
-- Seconds between declutter passes, and how long a label takes to fade out or back in.
local DECLUTTER_PERIOD = 0.1
local FADE_TIME = 0.15
local FADE_INFO = TweenInfo.new(FADE_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
-- The HUD's top-centre stack (direct children of a ScreenGui, by name).
local HUD_FRAMES = { Units = true, DepositStrip = true, NextGoal = true, RunPill = true, TutorialPill = true }
-- Pixels the kept label's top keeps under the stack, the most it is moved (share of the
-- viewport's height), and how fast (per second, exponential) it eases to its nudge.
local HUD_MARGIN = 6
local NUDGE_LIMIT = 0.35
local NUDGE_RATE = 12

local PadLabels = {}

type Entry = { base: UDim2, capped: boolean, w: number, h: number, offset: Vector3 }
-- A label with two placements and how far (0 near .. 1 far) it currently sits between them.
type Glide = { near: Vector3, far: Vector3, t: number }

local entries: { [BillboardGui]: Entry } = {}
-- PlotSign signs and their own size.
local signs: { [BillboardGui]: UDim2 } = {}
local glides: { [BillboardGui]: Glide } = {}
-- Labels faded (or fading back in) by the declutter: the group holding their elements.
type Fade = { group: CanvasGroup, out: boolean, tween: Tween? }
local fades: { [BillboardGui]: Fade } = {}
-- Labels moved down clear of the HUD stack: studs along the camera's down now and wanted.
type Nudge = { studs: number, target: number }
local nudges: { [BillboardGui]: Nudge } = {}
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
	hudRect = nil :: { number }?,
	hudFrames = {} :: { string },
	inset = nil :: { number }?,
}

local function baseOf(gui: BillboardGui): UDim2
	local base = gui:GetAttribute("BaseSize")
	return if typeof(base) == "UDim2" then base else gui.Size
end

local function add(gui: Instance)
	if not gui:IsA("BillboardGui") or entries[gui] then
		return
	end
	entries[gui] = { base = baseOf(gui), capped = false, w = 0, h = 0, offset = gui.StudsOffsetWorldSpace }
	local near, far = gui:GetAttribute("NearOffset"), gui:GetAttribute("FarOffset")
	if typeof(near) == "Vector3" and typeof(far) == "Vector3" and (near - far).Magnitude > 0.01 then
		glides[gui] = { near = near, far = far, t = 1 }
	end
end

local function addSign(gui: Instance)
	if gui:IsA("BillboardGui") and not entries[gui] then
		signs[gui] = gui.Size
	end
end

local function remove(gui: Instance)
	entries[gui :: BillboardGui] = nil
	glides[gui :: BillboardGui] = nil
	signs[gui :: BillboardGui] = nil
	nudges[gui :: BillboardGui] = nil
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
	if not out then
		f.group.Visible = true
	end
	local tween = TweenService:Create(f.group, FADE_INFO, { GroupTransparency = if out then 1 else 0 })
	f.tween = tween
	tween.Completed:Connect(function(state)
		if state ~= Enum.PlaybackState.Completed or fades[gui] ~= f then
			return
		end
		if f.out then
			f.group.Visible = false
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
			if not nudges[gui] then
				gui.StudsOffsetWorldSpace = g.near:Lerp(g.far, t)
			end
		end
	end
end

local function anchorOf(gui: BillboardGui, adornee: BasePart): Vector3
	return adornee.Position + adornee.CFrame:VectorToWorldSpace(gui.StudsOffsetWorldSpace)
end

-- A label's offset before any HUD nudge: its glide's blend, or where World.Pads put it.
local function baseOffset(gui: BillboardGui): Vector3
	local g = glides[gui]
	if g then
		return g.near:Lerp(g.far, g.t)
	end
	local entry = entries[gui]
	return if entry then entry.offset else gui.StudsOffsetWorldSpace
end

-- Eases the nudged labels toward their wanted nudge and places them (base + nudge along the
-- camera's down); a label eased back to none gets its base offset and leaves the table.
local function placeNudged(camera: Camera, dt: number)
	if next(nudges) == nil then
		return
	end
	local alpha = 1 - math.exp(-NUDGE_RATE * dt)
	local down = -camera.CFrame.UpVector
	for gui, n in nudges do
		local adornee = gui.Adornee
		n.studs += (n.target - n.studs) * alpha
		if n.target == 0 and n.studs < 0.01 then
			nudges[gui] = nil
			gui.StudsOffsetWorldSpace = baseOffset(gui)
		elseif adornee and adornee:IsA("BasePart") then
			gui.StudsOffsetWorldSpace = baseOffset(gui) + adornee.CFrame:VectorToObjectSpace(down * n.studs)
		end
	end
end

-- The HUD's top-centre stack on screen (viewport px, a centre rect) and the frames in it.
local function hudStack(): (PadLabelSize.Rect?, { string })
	local playerGui = Players.LocalPlayer:FindFirstChildOfClass("PlayerGui")
	if not playerGui then
		return nil, {}
	end
	local inset = GuiService:GetGuiInset()
	diag.inset = { math.round(inset.X), math.round(inset.Y) }
	local left, top, right, bottom = math.huge, math.huge, -math.huge, -math.huge
	local names = {}
	for _, screen in playerGui:GetChildren() do
		if not (screen:IsA("ScreenGui") and screen.Enabled) then
			continue
		end
		local shift = if screen.IgnoreGuiInset then Vector2.zero else inset
		for _, child in screen:GetChildren() do
			if not (HUD_FRAMES[child.Name] and child:IsA("GuiObject") and child.Visible) then
				continue
			end
			local pos, size = child.AbsolutePosition + shift, child.AbsoluteSize
			if size.X <= 0 or size.Y <= 0 then
				continue
			end
			left, top = math.min(left, pos.X), math.min(top, pos.Y)
			right, bottom = math.max(right, pos.X + size.X), math.max(bottom, pos.Y + size.Y)
			table.insert(names, child.Name)
		end
	end
	if #names == 0 then
		return nil, names
	end
	return { x = (left + right) / 2, y = (top + bottom) / 2, w = right - left, h = bottom - top }, names
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

type Candidate = {
	gui: BillboardGui,
	rect: PadLabelSize.Rect,
	distance: number,
	depth: number,
	keep: boolean,
	sign: boolean,
}

-- A sign's name in the diagnostics: a pad label by its pad, another sign by its own name and
-- where it stands (the two crackers' READY! pills share a name).
local function nameOf(gui: BillboardGui, sign: boolean): string
	local adornee = gui.Adornee
	if not adornee then
		return gui:GetFullName()
	end
	if not sign then
		return adornee.Name
	end
	local p = (adornee :: BasePart).Position
	return string.format("%s(%d,%d)", gui.Name, math.round(p.X), math.round(p.Z))
end

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
	local function skip(gui: BillboardGui, sign: boolean, why: string)
		local adornee = gui.Adornee
		table.insert(skipped, {
			name = nameOf(gui, sign),
			kind = if sign then "sign" else "pad",
			skipped = why,
			distance = if adornee then math.round((adornee.Position - eye).Magnitude * 10) / 10 else nil,
		})
	end
	-- Projects a sign (`base` its UDim2 size; `sign` when not a pad label, so never capped and
	-- never kept) and adds it to the list when it is on screen.
	local function consider(gui: BillboardGui, base: UDim2, sign: boolean)
		local adornee = gui.Adornee
		if not (adornee and adornee:IsA("BasePart") and gui.Enabled and gui:IsDescendantOf(plot :: Instance)) then
			if gui:IsDescendantOf(plot :: Instance) then
				skip(gui, sign, if not gui.Enabled then "disabled" else "no adornee")
			end
			return
		end
		-- Judged at its base offset: the HUD nudge is worked out below and must not feed back.
		local pos = adornee.Position + adornee.CFrame:VectorToWorldSpace(baseOffset(gui))
		local distance = (pos - eye).Magnitude
		local depth = (pos - eye):Dot(look)
		if depth <= 0 or (adornee.Position - eye).Magnitude > gui.MaxDistance then
			skip(gui, sign, if depth <= 0 then "behind camera" else "past MaxDistance")
			return
		end
		local point = camera:WorldToViewportPoint(pos)
		local w, h
		if sign then
			local k = PadLabelSize.pixelsPerStud(depth, viewport.Y, fov)
			w, h = base.X.Scale * k + base.X.Offset, base.Y.Scale * k + base.Y.Offset
		else
			w, h = PadLabelSize.size(base.X.Scale, base.X.Offset, base.Y.Scale, base.Y.Offset, depth, viewport.Y, fov)
		end
		if point.X + w / 2 < 0 or point.X - w / 2 > viewport.X or point.Y + h / 2 < 0 or point.Y - h / 2 > viewport.Y then
			skip(gui, sign, "off screen")
			return
		end
		local c: Candidate = {
			gui = gui,
			rect = { x = point.X, y = point.Y, w = w, h = h },
			distance = distance,
			depth = depth,
			keep = false,
			sign = sign,
		}
		table.insert(list, c)
		if feet and not sign then
			local gap = Vector2.new(adornee.Position.X - feet.X, adornee.Position.Z - feet.Z).Magnitude
			if gap < nearestGap then
				nearest, nearestGap = c, gap
			end
		end
	end
	if plot then
		for gui, entry in entries do
			consider(gui, entry.base, false)
		end
		for gui, base in signs do
			consider(gui, base, true)
		end
	end
	-- The HUD stack: the kept label moves down clear of it (its rect judged where it is going),
	-- every other label it covers fades.
	local hud, hudNames = hudStack()
	diag.hudFrames = hudNames
	local nudgePx = 0
	if nearest then
		nearest.keep = true
		if hud then
			nudgePx = PadLabelSize.clearBelow(nearest.rect, hud, HUD_MARGIN, NUDGE_LIMIT * viewport.Y)
			nearest.rect.y += nudgePx
		end
		local studs = nudgePx / PadLabelSize.pixelsPerStud(nearest.depth, viewport.Y, fov)
		local n = nudges[nearest.gui]
		if n then
			n.target = studs
		elseif studs > 0 then
			nudges[nearest.gui] = { studs = 0, target = studs }
		end
	end
	for gui, n in nudges do
		if not (nearest and gui == nearest.gui) then
			n.target = 0
		end
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
	local result, shares, covers = PadLabelSize.declutter(rects, faded, keep, hud)
	local seen: { [BillboardGui]: boolean } = {}
	local report: { any } = {}
	for i, c in list do
		seen[c.gui] = true
		if result[i] ~= faded[i] then
			setFaded(c.gui, result[i])
		end
		local r = c.rect
		local cover = list[covers[i]]
		local fade = fades[c.gui]
		local n = nudges[c.gui]
		table.insert(report, {
			name = nameOf(c.gui, c.sign),
			kind = if c.sign then "sign" else "pad",
			distance = math.round(c.distance * 10) / 10,
			rect = { math.round(r.x - r.w / 2), math.round(r.y - r.h / 2), math.round(r.w), math.round(r.h) },
			onScreen = true,
			keep = c.keep,
			faded = result[i],
			fadeGroup = if fade then groupReport(c.gui, fade) else nil,
			overlap = math.round(shares[i] * 1000) / 1000,
			cover = if covers[i] == -1 then "HUD" elseif cover then nameOf(cover.gui, cover.sign) else nil,
			hudOverlap = if hud then math.round(PadLabelSize.coverShare(r, hud) * 1000) / 1000 else 0,
			nudge = if n then { px = math.round(if c.keep then nudgePx else 0), studs = math.round(n.studs * 100) / 100 } else nil,
		})
	end
	for _, s in skipped do
		table.insert(report, s)
	end
	diag.labels = report
	diag.plot = if plot then plot.Name else nil
	diag.viewport = { math.round(viewport.X), math.round(viewport.Y) }
	diag.hudRect = if hud
		then { math.round(hud.x - hud.w / 2), math.round(hud.y - hud.h / 2), math.round(hud.w), math.round(hud.h) }
		else nil
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
	placeNudged(camera, dt)
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
		signs = (function()
			local n = 0
			for _ in signs do
				n += 1
			end
			return n
		end)(),
		plot = diag.plot,
		viewport = diag.viewport,
		inset = diag.inset,
		hudRect = diag.hudRect,
		hudFrames = diag.hudFrames,
		labels = diag.labels,
	}
end

function PadLabels.init()
	for _, gui in CollectionService:GetTagged(TAG) do
		add(gui)
	end
	CollectionService:GetInstanceAddedSignal(TAG):Connect(add)
	CollectionService:GetInstanceRemovedSignal(TAG):Connect(remove)
	for _, gui in CollectionService:GetTagged(SIGN_TAG) do
		addSign(gui)
	end
	CollectionService:GetInstanceAddedSignal(SIGN_TAG):Connect(addSign)
	CollectionService:GetInstanceRemovedSignal(SIGN_TAG):Connect(remove)
	RunService.RenderStepped:Connect(step)
end

return PadLabels
