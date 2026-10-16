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
]]

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local PadLabelSize = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("PadLabelSize"))
local State = require(script.Parent.Parent.State)

local TAG = "PadLabel"
-- Pixel change below which a capped label is not resized again.
local EPSILON = 0.5
-- Blend change (0..1) below which a gliding label is not moved again (under 0.02 studs here).
local BLEND_EPSILON = 0.004

local PadLabels = {}

type Entry = { base: UDim2, capped: boolean, w: number, h: number }
-- A label with two placements and how far (0 near .. 1 far) it currently sits between them.
type Glide = { near: Vector3, far: Vector3, t: number }

local entries: { [BillboardGui]: Entry } = {}
local glides: { [BillboardGui]: Glide } = {}

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

local function step()
	local camera = Workspace.CurrentCamera
	if not camera then
		return
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
		local pos = adornee.Position + adornee.CFrame:VectorToWorldSpace(gui.StudsOffsetWorldSpace)
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

function PadLabels.init()
	for _, gui in CollectionService:GetTagged(TAG) do
		add(gui)
	end
	CollectionService:GetInstanceAddedSignal(TAG):Connect(add)
	CollectionService:GetInstanceRemovedSignal(TAG):Connect(remove)
	RunService.RenderStepped:Connect(step)
end

return PadLabels
