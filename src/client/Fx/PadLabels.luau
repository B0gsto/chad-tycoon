--[[
	Fx.PadLabels: keeps the pads' floating labels from ballooning up close.

	World.Pads tags every pad label (BillboardGui "PadLabel") with "PadLabel" and stores its
	stud + pixel size in the "BaseSize" attribute. Every frame each label's depth in front of
	the camera gives its natural on-screen size; past Shared.PadLabelSize's cap (a share of the
	viewport's height) the label is pinned at the capped pixel size, and it gets its stud size
	back once the camera is far enough again. Labels are only written when they cross the cap
	or the capped size changes (viewport resize, FOV kick), so the far labels cost a dot product.
]]

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local PadLabelSize = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("PadLabelSize"))

local TAG = "PadLabel"
-- Pixel change below which a capped label is not resized again.
local EPSILON = 0.5

local PadLabels = {}

type Entry = { base: UDim2, capped: boolean, w: number, h: number }

local entries: { [BillboardGui]: Entry } = {}

local function baseOf(gui: BillboardGui): UDim2
	local base = gui:GetAttribute("BaseSize")
	return if typeof(base) == "UDim2" then base else gui.Size
end

local function add(gui: Instance)
	if not gui:IsA("BillboardGui") or entries[gui] then
		return
	end
	entries[gui] = { base = baseOf(gui), capped = false, w = 0, h = 0 }
end

local function remove(gui: Instance)
	entries[gui :: BillboardGui] = nil
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
