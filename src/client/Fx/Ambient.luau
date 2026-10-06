--[[
	Fx.Ambient: gentle idle life for the whole map (client-side only).

	Picks up anchored world parts and models by name or attribute, at load and
	whenever they stream or get built in:
	  "Flag" / "Bunting"   sway about their top edge (a part's optional
	                       Vector3 attribute "SwayPivot", in part space, moves
	                       the hinge; models sway about their pivot). All
	                       sway shares one wind axis, phased along the wind
	                       so pennants on a cord swing together
	  "Prop_PalmTree"      sways very slightly about the trunk base
	  "Cloud"              drifts slowly back and forth across the sky
	  attribute Spin       (number, rad/s) turns about its own up axis
	  attribute Bob        (number, studs) bobs up and down
	A model that matches moves as one piece; its parts are not matched again.

	One Heartbeat loop moves everything with a single BulkMoveTo. Things far
	from the camera (clouds excepted) hold still, mid-range ones update every
	few frames, and every motion is a function of time, so nothing drifts.
]]

local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Ambient = {}

local FAR = 220 -- studs: beyond this nothing moves (clouds excepted)
local NEAR = 90 -- studs: closer than this things update every frame
local MID_RATE = 3 -- frames between updates beyond NEAR
local CLOUD_RATE = 4 -- frames between cloud updates
local BEHIND = -40 -- studs behind the camera plane still updated
local MODEL_DELAY = 0.5 -- seconds to let a model's parts arrive before capturing it

local FLAG_SWAY = math.rad(6)
local FLAG_SPEED = { 1.6, 2.3 }
local PALM_SWAY = math.rad(1.2)
local PALM_SPEED = { 0.55, 0.8 }
local CLOUD_DRIFT = 26 -- studs either side of the rest position
local CLOUD_SPEED = 2 * math.pi / 240 -- one back-and-forth every 4 minutes
local WIND = Vector3.new(1, 0, 0.35).Unit
-- Swaying things all tip about the same world axes (X across the wind), so pennants on one
-- cord swing together; WAVE turns position into phase, sending a gentle ripple downwind.
local WIND_FRAME = CFrame.lookAt(Vector3.zero, WIND)
local WAVE = 0.12 -- radians of phase per stud along the wind
local BOB_SPEED = 1.8

type Target = {
	owner: Instance,
	parts: { BasePart },
	offsets: { CFrame },
	hinge: CFrame,
	sway: number, -- radians about the hinge's X axis (Z gets half)
	swaySpeed: number,
	spin: number,
	bob: number,
	drift: number,
	phase: number,
	sky: boolean,
	slot: number,
}

local targets: { Target } = {}
local byOwner: { [Instance]: Target } = {}
local claimed: { [BasePart]: Target } = {}
local bulkParts: { BasePart } = {}
local bulkCFrames: { CFrame } = {}
local frameCount = 0
local slotCounter = 0
local clockStart = os.clock()
local started = false

-- The motion of a target at time t, as a CFrame applied to its hinge.
local function motion(target: Target, t: number): CFrame
	local p = target.phase
	local x, y, z = 0, 0, 0
	if target.drift ~= 0 then
		local d = target.drift * math.sin(t * CLOUD_SPEED + p)
		x, z = WIND.X * d, WIND.Z * d
	end
	if target.bob ~= 0 then
		y = target.bob * math.sin(t * BOB_SPEED + p)
	end
	local rx, ry, rz = 0, 0, 0
	if target.sway ~= 0 then
		local s = target.swaySpeed
		rx = target.sway * math.sin(t * s + p)
		rz = target.sway * 0.5 * math.sin(t * s * 0.73 + p * 1.7)
	end
	if target.spin ~= 0 then
		ry = (t * target.spin) % (2 * math.pi)
	end
	return CFrame.new(x, y, z) * target.hinge * CFrame.fromEulerAnglesYXZ(rx, ry, rz)
end

-- Puts a target's parts back where they were captured.
local function rest(target: Target)
	for i, part in target.parts do
		if part.Parent then
			part.CFrame = target.hinge * target.offsets[i]
		end
	end
end

local function removeTarget(target: Target, restore: boolean)
	local index = table.find(targets, target)
	if not index then
		return
	end
	targets[index] = targets[#targets]
	targets[#targets] = nil
	byOwner[target.owner] = nil
	for _, part in target.parts do
		if claimed[part] == target then
			claimed[part] = nil
		end
	end
	if restore then
		rest(target)
	end
end

local function claim(target: Target, part: BasePart)
	if not part.Anchored then
		return
	end
	local previous = claimed[part]
	if previous and previous ~= target then
		removeTarget(previous, true)
	end
	claimed[part] = target
	table.insert(target.parts, part)
	table.insert(target.offsets, target.hinge:ToObjectSpace(part.CFrame))
end

local function randomIn(range: { number }): number
	return range[1] + math.random() * (range[2] - range[1])
end

-- A sway hinge at `position`: world-aligned to the wind, phased by where it stands.
local function swayHinge(target: Target, position: Vector3)
	target.hinge = CFrame.new(position) * WIND_FRAME
	target.phase = position:Dot(WIND) * WAVE
end

-- The middle of a part's highest face (pennants hang from it, even when built upside down).
local function topOf(part: BasePart): Vector3
	local cf = part.CFrame
	local half = part.Size / 2
	local best, bestY = cf.Position, -math.huge
	for _, offset in { cf.UpVector * half.Y, cf.RightVector * half.X, cf.LookVector * half.Z } do
		for _, sign in { 1, -1 } do
			local y = offset.Y * sign
			if y > bestY then
				best, bestY = cf.Position + offset * sign, y
			end
		end
	end
	return best
end

local function matches(instance: Instance): boolean
	local name = instance.Name
	return name == "Flag"
		or name == "Bunting"
		or name == "Prop_PalmTree"
		or name == "Cloud"
		or type(instance:GetAttribute("Spin")) == "number"
		or type(instance:GetAttribute("Bob")) == "number"
end

-- The moving target that already owns `instance` through one of its ancestors.
local function ownerAbove(instance: Instance): Target?
	local node = instance.Parent
	while node and node ~= Workspace do
		local target = byOwner[node]
		if target then
			return target
		end
		node = node.Parent
	end
	return nil
end

-- What `instance` should do, or nil when it is not ambient scenery.
local function describe(instance: Instance): Target?
	if not matches(instance) then
		return nil
	end
	local name = instance.Name
	local spin = instance:GetAttribute("Spin")
	local bob = instance:GetAttribute("Bob")
	local isFlag = name == "Flag" or name == "Bunting"
	local isPalm = name == "Prop_PalmTree"
	local isCloud = name == "Cloud"
	slotCounter += 1
	local target: Target = {
		owner = instance,
		parts = {},
		offsets = {},
		hinge = CFrame.identity,
		sway = 0,
		swaySpeed = 0,
		spin = if type(spin) == "number" then spin else 0,
		bob = if type(bob) == "number" then bob else 0,
		drift = 0,
		phase = math.random() * 2 * math.pi,
		sky = isCloud,
		slot = slotCounter,
	}
	if isFlag then
		target.sway = FLAG_SWAY
		target.swaySpeed = randomIn(FLAG_SPEED)
	elseif isPalm then
		target.sway = PALM_SWAY
		target.swaySpeed = randomIn(PALM_SPEED)
	elseif isCloud then
		target.drift = CLOUD_DRIFT
	end
	return target
end

local function capture(instance: Instance)
	if byOwner[instance] or not instance:IsDescendantOf(Workspace) or ownerAbove(instance) then
		return
	end
	local target = describe(instance)
	if not target then
		return
	end
	if instance:IsA("BasePart") then
		if claimed[instance] or not instance.Anchored then
			return
		end
		local pivot = instance:GetAttribute("SwayPivot")
		if target.sway ~= 0 then
			swayHinge(target, if typeof(pivot) == "Vector3" then instance.CFrame * pivot else topOf(instance))
		else
			target.hinge = instance.CFrame
		end
		claim(target, instance)
	elseif instance:IsA("Model") then
		if instance.Name == "Prop_PalmTree" then
			local box, size = instance:GetBoundingBox()
			swayHinge(target, box.Position - Vector3.new(0, size.Y / 2, 0))
		elseif target.sway ~= 0 then
			swayHinge(target, instance:GetPivot().Position)
		else
			target.hinge = instance:GetPivot()
		end
		for _, d in instance:GetDescendants() do
			if d:IsA("BasePart") then
				claim(target, d)
			end
		end
	else
		return
	end
	if #target.parts == 0 then
		return
	end
	table.insert(targets, target)
	byOwner[instance] = target
end

local function consider(instance: Instance)
	if instance:IsA("BasePart") then
		if claimed[instance] then
			return
		end
		-- A part arriving inside a model that is already moving: re-capture the model.
		local above = ownerAbove(instance)
		if above then
			local owner = above.owner
			removeTarget(above, true)
			task.delay(MODEL_DELAY, capture, owner)
			return
		end
		capture(instance)
	elseif instance:IsA("Model") and matches(instance) then
		-- Give the model's parts a moment to arrive (building / streaming).
		task.delay(MODEL_DELAY, capture, instance)
	end
end

local function onRemoving(instance: Instance)
	local target = byOwner[instance]
	if target then
		removeTarget(target, false)
		return
	end
	if instance:IsA("BasePart") then
		local owner = claimed[instance]
		if owner then
			local index = table.find(owner.parts, instance)
			if index then
				table.remove(owner.parts, index)
				table.remove(owner.offsets, index)
			end
			claimed[instance] = nil
		end
	end
end

local function step()
	local count = #targets
	if count == 0 then
		return
	end
	frameCount += 1
	local t = os.clock() - clockStart
	local camera = Workspace.CurrentCamera
	local camPos = if camera then camera.CFrame.Position else Vector3.zero
	local camLook = if camera then camera.CFrame.LookVector else Vector3.new(0, 0, -1)
	table.clear(bulkParts)
	table.clear(bulkCFrames)
	local n = 0
	for i = 1, count do
		local target = targets[i]
		if target.sky then
			if (frameCount + target.slot) % CLOUD_RATE ~= 0 then
				continue
			end
		else
			local offset = target.hinge.Position - camPos
			local distance = offset.Magnitude
			if distance > FAR or offset:Dot(camLook) < BEHIND then
				continue
			end
			if distance > NEAR and (frameCount + target.slot) % MID_RATE ~= 0 then
				continue
			end
		end
		local frame = motion(target, t)
		local offsets = target.offsets
		for k, part in target.parts do
			n += 1
			bulkParts[n] = part
			bulkCFrames[n] = frame * offsets[k]
		end
	end
	if n > 0 then
		Workspace:BulkMoveTo(bulkParts, bulkCFrames, Enum.BulkMoveMode.FireCFrameChanged)
	end
end

function Ambient.init()
	if started then
		return
	end
	started = true
	for _, d in Workspace:GetDescendants() do
		if d:IsA("Model") or d:IsA("BasePart") then
			capture(d)
		end
	end
	Workspace.DescendantAdded:Connect(consider)
	Workspace.DescendantRemoving:Connect(onRemoving)
	RunService.Heartbeat:Connect(step)
end

return Ambient
