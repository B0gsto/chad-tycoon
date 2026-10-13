--[[
	Fx.Camera: spawn framing, camera punch / shake and the pad signs' near lines.

	- On every spawn, whenever the character is teleported (e.g. Home) and when the intro
	  cutscene hands the camera back (CameraType returns to Custom), the Custom camera is
	  placed FRAME_DISTANCE studs behind the character's head, raised so it looks FRAME_PITCH
	  down the way the character faces. Spawning on a plot (facing the pen) that puts the pen
	  and the rack's lower shelves in the upper middle of the screen with the buy pads either
	  side. The follow camera keeps that angle; its zoom is set to FRAME_DISTANCE once.
	  Camera.spawnShot(root) returns the same eye / focus for other camera code.
	  In front of a mode gate (where ModeQuit puts the player, back to the gate) the shot is
	  shortened so the eye never sits behind the gate's see-through portal; the zoom goes
	  back to FRAME_DISTANCE once the player has walked clear of it.
	- Camera.punch(intensity): FOV kick plus a tiny shake (intensity ~0.2..1.5).
	- Camera.setFov(key, delta): a held FOV offset for `key` (Fx.Cardio's speed widen; 0
	  drops it). The kick and every held offset are added to one base FOV here, so no effect
	  reads another's widened value as its base and leaves it behind when it ends.
	- Camera.shake(intensity, duration): positional shake only (no rotation,
	  so the default camera scripts never drift).
	- Camera.reducedMotion = true turns punches/shakes into no-ops.
	- Pad sign near lines (SurfaceGuis tagged "PadSignNear" by World.Pads, attribute
	  NearDistance): faded in when the character is within NearDistance studs and out
	  past it, tweened, scanned every NEAR_SCAN seconds.
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local State = require(script.Parent.Parent.State)

local Camera = {}

Camera.reducedMotion = false

local TELEPORT_DISTANCE = 12 -- studs moved in one frame that count as a teleport
local FRAME_DISTANCE = 15 -- studs from the camera to the character's head
local FRAME_PITCH = math.rad(20) -- how far the camera looks down
local HEAD_OFFSET = Vector3.new(0, 1.5, 0) -- the follow camera's focus above the root
local MAX_FOV_KICK = 9
local PORTAL_CLEAR = 2.5 -- studs the eye stays in front of a gate portal's disc
local PORTAL_PAD = 3 -- studs past the disc's rim that still count as looking through it
local MIN_FRAME = 5 -- the shortest shot in front of a portal
local WIDEN_SCAN = 0.25

local NEAR_TAG = "PadSignNear"
local NEAR_SCAN = 0.15
local NEAR_BAND = 4 -- studs over which a near line fades
local NEAR_TWEEN = TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

local fovKick = 0 -- current extra FOV (decays)
local baseFov: number? = nil -- FOV before the punch (or the first held offset) started
local fovHeld: { [string]: number } = {} -- Camera.setFov offsets by owner
local fovExtra = 0 -- their sum
local shakeAmp = 0
local shakeUntil = 0
local shakeLength = 0
local started = false
local zoomBusy = false
local frameToken = 0 -- bumps on every spawn shot (a pending widen belongs to one)

local function reduced(): boolean
	if Camera.reducedMotion then
		return true
	end
	local data = State.data
	return data ~= nil and data.settings ~= nil and data.settings.reducedMotion == true
end

-- The spawn shot for `root`: the camera's eye and the focus it looks at (the character's
-- head), behind the character and looking FRAME_PITCH down the way it faces.
function Camera.spawnShot(root: BasePart): (Vector3?, Vector3?)
	local look = root.CFrame.LookVector
	local flat = Vector3.new(look.X, 0, look.Z)
	if flat.Magnitude < 1e-3 then
		return nil, nil
	end
	flat = flat.Unit
	local focus = root.Position + HEAD_OFFSET
	local back = flat * (FRAME_DISTANCE * math.cos(FRAME_PITCH))
	local up = Vector3.new(0, FRAME_DISTANCE * math.sin(FRAME_PITCH), 0)
	return focus - back + up, focus
end

-- Mode gates ---------------------------------------------------------------------------
-- An open gate holds a swirling see-through portal (World.Modes: the "PortalVeil" disc and
-- its Neon rings have no collision, so the follow camera's own occlusion ignores them).
-- ModeQuit and the return from a far arena put the player a few studs in front of a gate
-- with their back to it (Course.QUIT): the spawn shot's eye would sit behind the portal and
-- the swirl would fill the screen.

-- The portal discs of both plazas (Map.GameModes.Plaza*.Gate*.PortalVeil).
local function portalVeils(): { BasePart }
	local found: { BasePart } = {}
	local map = Workspace:FindFirstChild("Map")
	local modes = map and map:FindFirstChild("GameModes")
	if not modes then
		return found
	end
	for _, plaza in modes:GetChildren() do
		if string.sub(plaza.Name, 1, 5) == "Plaza" then
			for _, gate in plaza:GetChildren() do
				local veil = gate:FindFirstChild("PortalVeil")
				if veil and veil:IsA("BasePart") then
					table.insert(found, veil)
				end
			end
		end
	end
	return found
end

-- How far along the way from `focus` to `eye` the camera may go before it comes within
-- PORTAL_CLEAR studs of a gate portal's disc (1 = all the way).
local function portalLimit(focus: Vector3, eye: Vector3): number
	local limit = 1
	for _, veil in portalVeils() do
		-- The disc is a cylinder: its axis (the part's X) points through the gate.
		local normal = veil.CFrame.RightVector
		local from = (focus - veil.Position):Dot(normal)
		local to = (eye - veil.Position):Dot(normal)
		local side = if from >= 0 then 1 else -1
		local travel = from - to
		if to * side < PORTAL_CLEAR and travel * side > 1e-3 then
			-- Where the line meets the disc's plane (or ends just short of it): inside the rim?
			local at = focus:Lerp(eye, math.clamp(from / travel, 0, 1))
			local off = at - veil.Position
			local radial = (off - normal * off:Dot(normal)).Magnitude
			if radial <= math.max(veil.Size.Y, veil.Size.Z) / 2 + PORTAL_PAD then
				limit = math.min(limit, math.clamp((from - side * PORTAL_CLEAR) / travel, 0, 1))
			end
		end
	end
	return limit
end

-- Sets the follow camera's zoom to `distance` by pinning the player's zoom limits to it for
-- a frame (the camera scripts clamp their zoom to the limits), then restoring them. Returns
-- false when it could not (another zoom is being set, or the distance is outside the limits).
local function setZoom(distance: number): boolean
	local player = Players.LocalPlayer
	local lo, hi = player.CameraMinZoomDistance, player.CameraMaxZoomDistance
	if zoomBusy or distance < lo or distance > hi then
		return false
	end
	zoomBusy = true
	task.spawn(function()
		player.CameraMaxZoomDistance = distance
		player.CameraMinZoomDistance = distance
		RunService.RenderStepped:Wait()
		RunService.RenderStepped:Wait()
		if player.CameraMinZoomDistance == distance then
			player.CameraMinZoomDistance = lo
		end
		if player.CameraMaxZoomDistance == distance then
			player.CameraMaxZoomDistance = hi
		end
		zoomBusy = false
	end)
	return true
end

-- A shot shortened in front of a portal: once the full shot along the camera's own view
-- would clear every portal (the player walked on, or turned the camera), the zoom goes back
-- to FRAME_DISTANCE. Ends with the next spawn shot, the character or a scripted camera.
local function widenLater(root: BasePart, mine: number)
	task.spawn(function()
		while true do
			task.wait(WIDEN_SCAN)
			local camera = Workspace.CurrentCamera
			if frameToken ~= mine or not root.Parent or not camera or camera.CameraType ~= Enum.CameraType.Custom then
				return
			end
			local focus = root.Position + HEAD_OFFSET
			if portalLimit(focus, focus - camera.CFrame.LookVector * FRAME_DISTANCE) >= 1 and setZoom(FRAME_DISTANCE) then
				return
			end
		end
	end)
end

-- Places the Custom camera on the spawn shot for `root`.
local function frameBehind(root: BasePart)
	local camera = Workspace.CurrentCamera
	if not camera or camera.CameraType ~= Enum.CameraType.Custom then
		return
	end
	local eye, focus = Camera.spawnShot(root)
	if not eye or not focus then
		return
	end
	frameToken += 1
	local distance = FRAME_DISTANCE
	local limit = portalLimit(focus, eye)
	if limit < 1 then
		distance = math.max(MIN_FRAME, FRAME_DISTANCE * limit)
		eye = focus + (eye - focus).Unit * distance
		widenLater(root, frameToken)
	end
	camera.CFrame = CFrame.lookAt(eye, focus)
	setZoom(distance)
end

local function onCharacter(character: Model)
	local root = character:WaitForChild("HumanoidRootPart", 10) :: BasePart?
	if not root then
		return
	end
	-- Wait for the camera scripts to adopt the new humanoid, then frame once.
	local deadline = os.clock() + 2
	while os.clock() < deadline do
		local camera = Workspace.CurrentCamera
		local subject = camera and camera.CameraSubject
		if subject and subject:IsDescendantOf(character) then
			break
		end
		RunService.RenderStepped:Wait()
	end
	RunService.RenderStepped:Wait()
	frameBehind(root)
	-- Re-frame after teleports (Home button, plot changes).
	local last = root.Position
	local connection
	connection = RunService.Heartbeat:Connect(function()
		if not root.Parent or character.Parent == nil then
			connection:Disconnect()
			return
		end
		local pos = root.Position
		if (pos - last).Magnitude > TELEPORT_DISTANCE then
			task.defer(function()
				RunService.RenderStepped:Wait()
				frameBehind(root)
			end)
		end
		last = pos
	end)
end

-- Re-frames when a scripted camera (the intro cutscene) hands back the follow camera, so
-- the first follow frame is the spawn shot.
local function watchCameraType(camera: Camera)
	local was = camera.CameraType
	camera:GetPropertyChangedSignal("CameraType"):Connect(function()
		local now = camera.CameraType
		if now == Enum.CameraType.Custom and was == Enum.CameraType.Scriptable then
			local character = Players.LocalPlayer.Character
			local root = character and character:FindFirstChild("HumanoidRootPart")
			if root and root:IsA("BasePart") then
				frameBehind(root)
			end
		end
		was = now
	end)
end

-- Pad sign near lines -------------------------------------------------------------------

type NearItem = { inst: Instance, prop: string, base: number }
type NearEntry = { part: BasePart, distance: number, items: { NearItem }, shown: number }
local nearEntries: { [SurfaceGui]: NearEntry } = {}

-- The faded properties of a near line's pill, label and strokes, each hidden to start with.
local function collectNear(gui: SurfaceGui): { NearItem }
	local items: { NearItem } = {}
	for _, inst in gui:GetDescendants() do
		if inst:IsA("TextLabel") and inst.Visible then
			table.insert(items, { inst = inst, prop = "TextTransparency", base = inst.TextTransparency })
		elseif inst:IsA("Frame") then
			table.insert(items, { inst = inst, prop = "BackgroundTransparency", base = inst.BackgroundTransparency })
		elseif inst:IsA("UIStroke") then
			table.insert(items, { inst = inst, prop = "Transparency", base = inst.Transparency })
		end
	end
	for _, item in items do
		(item.inst :: any)[item.prop] = 1
	end
	return items
end

local function addNear(gui: Instance)
	if not gui:IsA("SurfaceGui") or nearEntries[gui] then
		return
	end
	local part = gui.Parent
	if not part or not part:IsA("BasePart") then
		return
	end
	local distance = gui:GetAttribute("NearDistance")
	nearEntries[gui] = {
		part = part,
		distance = if type(distance) == "number" then distance else 20,
		-- Collected on the first scan, once the GUI's children have replicated.
		items = {},
		shown = 0,
	}
end

local function scanNear()
	local character = Players.LocalPlayer.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	local from: Vector3? = if root and root:IsA("BasePart") then root.Position else nil
	for gui, entry in nearEntries do
		if not gui.Parent then
			nearEntries[gui] = nil
			continue
		end
		if #entry.items == 0 then
			entry.items = collectNear(gui)
			if #entry.items == 0 then
				continue
			end
		end
		local shown = 0
		if from then
			local d = (entry.part.Position - from).Magnitude
			shown = math.clamp((entry.distance - d) / NEAR_BAND, 0, 1)
		end
		if math.abs(shown - entry.shown) > 0.05 or (shown ~= entry.shown and (shown == 0 or shown == 1)) then
			entry.shown = shown
			for _, item in entry.items do
				local target = 1 - (1 - item.base) * shown
				TweenService:Create(item.inst, NEAR_TWEEN, { [item.prop] = target }):Play()
			end
		end
	end
end

-- FOV kick plus a small shake. Intensity ~0.2 (light) .. 1.5 (huge).
function Camera.punch(intensity: number?)
	if reduced() then
		return
	end
	local k = math.clamp(intensity or 1, 0, 2)
	local camera = Workspace.CurrentCamera
	if not camera then
		return
	end
	if not baseFov then
		baseFov = camera.FieldOfView
	end
	fovKick = math.min(MAX_FOV_KICK, fovKick + 5 * k)
	Camera.shake(0.18 * k, 0.25 + 0.1 * k)
end

-- A held FOV offset for `key`, added to the base FOV with the punch's kick (0 drops it).
function Camera.setFov(key: string, delta: number)
	if (fovHeld[key] or 0) == delta then
		return
	end
	if delta ~= 0 then
		fovHeld[key] = delta
	else
		fovHeld[key] = nil
	end
	local sum = 0
	for _, held in fovHeld do
		sum += held
	end
	fovExtra = sum
	local camera = Workspace.CurrentCamera
	if sum ~= 0 and not baseFov and camera then
		baseFov = camera.FieldOfView
	end
end

-- Positional shake (studs) that fades out over `duration` seconds.
function Camera.shake(intensity: number?, duration: number?)
	if reduced() then
		return
	end
	local now = os.clock()
	local amp = math.clamp(intensity or 0.3, 0, 1.5)
	local length = math.max(duration or 0.3, 0.05)
	local remaining = if now < shakeUntil then shakeAmp * (shakeUntil - now) / shakeLength else 0
	shakeAmp = math.max(amp, remaining)
	shakeLength = length
	shakeUntil = now + length
end

local function step(dt: number)
	local camera = Workspace.CurrentCamera
	if not camera then
		return
	end
	if baseFov then
		if fovKick > 0.01 or fovExtra ~= 0 then
			-- Fast spring back toward the base FOV (plus whatever is held).
			fovKick = if fovKick > 0.01 then fovKick * math.exp(-dt * 7) else 0
			camera.FieldOfView = baseFov + fovKick + fovExtra
		else
			camera.FieldOfView = baseFov
			baseFov = nil
			fovKick = 0
		end
	end
	local now = os.clock()
	if now < shakeUntil then
		local fade = (shakeUntil - now) / shakeLength
		local a = shakeAmp * fade * fade
		local t = now * 38
		local offset = Vector3.new(math.noise(t, 1.3) * a, math.noise(t, 7.1) * a, math.noise(t, 13.7) * a) * 2
		camera.CFrame += offset
	end
end

function Camera.init()
	if started then
		return
	end
	started = true
	local player = Players.LocalPlayer
	player.CharacterAdded:Connect(onCharacter)
	if player.Character then
		task.spawn(onCharacter, player.Character)
	end
	RunService:BindToRenderStep("FxCamera", Enum.RenderPriority.Camera.Value + 1, step)
	if Workspace.CurrentCamera then
		watchCameraType(Workspace.CurrentCamera)
	end
	CollectionService:GetInstanceAddedSignal(NEAR_TAG):Connect(addNear)
	for _, gui in CollectionService:GetTagged(NEAR_TAG) do
		addNear(gui)
	end
	task.spawn(function()
		while true do
			task.wait(NEAR_SCAN)
			scanNear()
		end
	end)
end

return Camera
