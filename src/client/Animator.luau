--[[
	Animator: plays the procedural unit animations (Shared.Poses) on the client.

	World units: every model tagged "AnimatedUnit" under Workspace is picked up
	automatically. The server builds them static; each client poses them
	locally every frame (nothing replicates). Units further than FAR studs from
	the camera or off-screen are skipped, and mid-distance ones update at a
	lower rate. All world parts are moved with one BulkMoveTo call per frame.

	Viewport units (Index cards, reward popup): call Animator.attach(model)
	after building the model; they animate while their ViewportFrame is
	visible. Animator.detach(model) stops it (also automatic once the model is
	destroyed).
]]

local CollectionService = game:GetService("CollectionService")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Poses = require(Shared:WaitForChild("Poses"))
local RigPose = require(Shared:WaitForChild("RigPose"))

local Animator = {}

local FAR = 140 -- studs: beyond this units stay frozen
local NEAR = 55 -- studs: closer than this units update every frame
local MID_RATE = 2 -- frames between updates for NEAR..MID
local MID = 95
local FAR_RATE = 4 -- frames between updates for MID..FAR
local SCREEN_MARGIN = 120 -- pixels outside the screen still counted as visible
local VIEWPORT_INTERVAL = 1 / 30 -- viewport units animate at 30 fps
local PRUNE_AFTER = 3 -- seconds an attached model may sit without a parent

type Entry = {
	model: Model,
	rig: RigPose.Rig?,
	viewport: boolean,
	slot: number,
	height: number,
	orphanSince: number?,
	nextViewportUpdate: number,
	connections: { RBXScriptConnection },
}

local entries: { [Model]: Entry } = {}
local slotCounter = 0
local started = false

local function newSeed(): number
	return math.random(0, 99999)
end

local function tryCapture(entry: Entry): RigPose.Rig?
	if entry.rig then
		return entry.rig
	end
	local model = entry.model
	local okScale, modelScale = pcall(function()
		return model:GetScale()
	end)
	local rig = RigPose.capture(model, newSeed())
	if rig and okScale and type(modelScale) == "number" and modelScale ~= 1 then
		-- Someone rescaled the model after it was built: scale the pivots too.
		rig.scale *= modelScale
		for limb, pivot in rig.pivots do
			rig.pivots[limb] = pivot * modelScale
		end
		table.clear(rig.parts)
		table.clear(rig.limbs)
		table.clear(rig.offsets)
		for _, d in model:GetDescendants() do
			if d:IsA("BasePart") then
				RigPose.addPart(rig, d)
			end
		end
	end
	if rig then
		entry.rig = rig
		local height = model:GetAttribute("Height")
		entry.height = if type(height) == "number" then height else 6
	end
	return rig
end

local function register(model: Model, viewport: boolean)
	local existing = entries[model]
	if existing then
		existing.viewport = existing.viewport or viewport
		return
	end
	slotCounter += 1
	local entry: Entry = {
		model = model,
		rig = nil,
		viewport = viewport,
		slot = slotCounter,
		height = 6,
		orphanSince = nil,
		nextViewportUpdate = 0,
		connections = {},
	}
	entries[model] = entry
end

-- Hooked up on the first frame a unit is processed (keeps attach() free of
-- side effects, so tools that load the UI without a frame loop stay happy).
local function connect(entry: Entry)
	local model = entry.model
	-- Parts that stream in later arrive in their rest pose; parts that leave are dropped.
	table.insert(
		entry.connections,
		model.DescendantAdded:Connect(function(d)
			local rig = entry.rig
			if rig and d:IsA("BasePart") then
				RigPose.addPart(rig, d)
			end
		end)
	)
	table.insert(
		entry.connections,
		model.DescendantRemoving:Connect(function(d)
			local rig = entry.rig
			if rig and d:IsA("BasePart") then
				if d == rig.root then
					-- Streamed out: forget it; it re-registers when it streams back in.
					task.defer(Animator.detach, entry.model)
				else
					RigPose.removePart(rig, d)
				end
			end
		end)
	)
end

local function unregister(model: Model)
	local entry = entries[model]
	if not entry then
		return
	end
	entries[model] = nil
	for _, connection in entry.connections do
		connection:Disconnect()
	end
end

-- Animate a model that lives outside Workspace (e.g. in a ViewportFrame).
function Animator.attach(model: Model)
	register(model, true)
end

function Animator.detach(model: Model)
	unregister(model)
end

-- Is the ViewportFrame (or other GUI) holding this model actually on screen?
local function guiVisible(model: Model): boolean
	local node: Instance? = model.Parent
	while node do
		if node:IsA("GuiObject") then
			if not node.Visible then
				return false
			end
		elseif node:IsA("LayerCollector") then
			return node.Enabled and node:FindFirstAncestorWhichIsA("PlayerGui") ~= nil
		end
		node = node.Parent
	end
	return false
end

local worldParts: { BasePart } = {}
local worldCFrames: { CFrame } = {}
local frameCount = 0

local function step()
	frameCount += 1
	local now = os.clock()
	local camera = Workspace.CurrentCamera
	local camPos = if camera then camera.CFrame.Position else Vector3.zero
	local viewSize = if camera then camera.ViewportSize else Vector2.new(1920, 1080)
	table.clear(worldParts)
	table.clear(worldCFrames)

	for model, entry in entries do
		if not model.Parent then
			entry.orphanSince = entry.orphanSince or now
			if now - (entry.orphanSince :: number) > PRUNE_AFTER then
				unregister(model)
			end
			continue
		end
		entry.orphanSince = nil
		if #entry.connections == 0 then
			connect(entry)
		end
		local rig = tryCapture(entry)
		if not rig then
			continue
		end

		if entry.viewport then
			if now >= entry.nextViewportUpdate and guiVisible(model) then
				entry.nextViewportUpdate = now + VIEWPORT_INTERVAL
				RigPose.apply(rig, now)
			end
			continue
		end

		if not model:IsDescendantOf(Workspace) then
			continue
		end
		local rootPos = rig.root.Position
		local distance = (rootPos - camPos).Magnitude
		if distance > FAR then
			continue
		end
		local rate = if distance < NEAR then 1 elseif distance < MID then MID_RATE else FAR_RATE
		if rate > 1 and (frameCount + entry.slot) % rate ~= 0 then
			continue
		end
		if camera and distance > entry.height * 1.5 then
			local center = rootPos + Vector3.new(0, entry.height * 0.5, 0)
			local screen, inFront = camera:WorldToViewportPoint(center)
			if
				not inFront
				or screen.X < -SCREEN_MARGIN
				or screen.Y < -SCREEN_MARGIN
				or screen.X > viewSize.X + SCREEN_MARGIN
				or screen.Y > viewSize.Y + SCREEN_MARGIN
			then
				continue
			end
		end
		local parts, cframes = RigPose.compute(rig, now)
		table.move(parts, 1, #parts, #worldParts + 1, worldParts)
		table.move(cframes, 1, #parts, #worldCFrames + 1, worldCFrames)
	end

	if #worldParts > 0 then
		Workspace:BulkMoveTo(worldParts, worldCFrames, Enum.BulkMoveMode.FireCFrameChanged)
	end
end

local function onTagged(instance: Instance)
	if instance:IsA("Model") and instance:IsDescendantOf(Workspace) then
		register(instance, false)
	end
end

function Animator.start()
	if started then
		return
	end
	started = true
	CollectionService:GetInstanceAddedSignal(Poses.TAG):Connect(onTagged)
	CollectionService:GetInstanceRemovedSignal(Poses.TAG):Connect(function(instance)
		local entry = entries[instance :: Model]
		if entry and not entry.viewport then
			unregister(instance :: Model)
		end
	end)
	for _, instance in CollectionService:GetTagged(Poses.TAG) do
		onTagged(instance)
	end
	RunService.RenderStepped:Connect(step)
end

return Animator
