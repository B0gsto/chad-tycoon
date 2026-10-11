--!strict
--[[
	Fx.Cardio: the 3D side of CARDIO, the keyboard runner (UI.CardioHud draws the screen).
	Runs only while the local player is in a run (snapshot modes.cardio.running or a
	"start" Notify); everything is restored on "stop" / "finish".

	  Key presses   the floor is ~12,000 keycap MeshParts (tag "CardioKey", attrs Letter, Stage,
	                Index, Kind "space" for spacebars; the letter is baked into the mesh).
	                Keys never collide: an invisible slab per surface (CardioTrack/Colliders)
	                sits the CardioTrack folder's PressDepth attribute below the key tops.
	                Keys are indexed once into a KeyPitch grid hash, so the key under a foot is
	                one bucket lookup, never a scan. The key under the local player and the
	                nearest other players (Budget.count(6) within 90 studs) sinks exactly
	                PressDepth (onto the slab, so feet rest on the pressed key), stays down
	                while a foot is on it, then springs back with a small Back overshoot
	                (one BulkMoveTo per frame, rest CFrames cached); nothing glows. Sliding keys (tag "ModeMover")
	                belong to Fx.Modes and never move here. Blinking keys (tag
	                "CardioBlinkKey", attrs BlinkOn / BlinkPeriod / BlinkPhase) fade here in
	                sync with their platform's slab (a "BlinkPad" Fx.Modes toggles): faded
	                while ((t + phase) % period) >= on, flashing in the last BLINK_WARN s.
	  Step pops     the "CardioSteps" effect (gained) floats a purple "+N" with the Speedy
	                Sneakers icon up off the character (a pool of POP_POOL BillboardGuis);
	                on a treadmill an "x{multiplier} SPEED" tag rides above the head.
	  Treadmills    the Texture(s) on each "Belt" (inside models tagged "CardioTreadmill")
	                scroll backwards under the runner (OffsetStudsV); the belt under the
	                local player scrolls at their WalkSpeed. While standing on a belt the
	                character turns to the belt's LookVector and plays its own run
	                animation in place (Animate.run.RunAnim) at WalkSpeed / 16 speed, with dust puffs and the odd sweat drop.
	  Speed         radial speed lines (a pooled ScreenGui under the HUD) and a gentle FOV
	                kick, both scaling with the horizontal speed above ~50 studs/s; reduced
	                motion skips the FOV and halves the lines.
	  Bursts        safe zone reached: stars and confetti; WIN pad claimed: a bigger ring of
	                both (largest on the last pad); fall: a landing ring + puff,
	                upgrade: sparkles over the upgrade pad (Fx.Sprites, budgeted).
	  Doors         timed exit doors (parts tagged "CardioDoor", attrs DoorOpen, DoorPeriod,
	                DoorPhase: open while ((t + phase) % period) < open, t = server time) drive
	                the TextLabel "Countdown" on their sign (searched in the door's parent):
	                green "GO! 2.1" (seconds left open) / red "1.34" (seconds until it opens),
	                DOOR_RATE times a second, only within DOOR_RADIUS studs of the camera.
	  Sound         Sounds.play("KeyClick") each time the local player's foot
	                lands on a new key, at most CLICK_RATE per second (Sounds has no volume
	                control, so other players' steps stay silent).
]]

local CollectionService = game:GetService("CollectionService")
local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Net = require(ReplicatedStorage.Shared.Net)
local Theme = require(ReplicatedStorage:WaitForChild("Theme")) :: any
local Client = script.Parent.Parent
local State = require(Client.State) :: any
local Sprites = require(script.Parent.Sprites)
local Budget = require(script.Parent.Budget)
local Sounds = require(Client.Sounds) :: any
local Assets = require(ReplicatedStorage.Shared.Assets) :: any

local CardioFx = {}

local player = Players.LocalPlayer
local W = Theme.World
local C = Theme.Colors

local KEY_TAG = "CardioKey"
local TREADMILL_TAG = "CardioTreadmill"
local PAD_TAG = "CardioUpgradePad"

local PRESS_DEFAULT = 1 -- studs a pressed key sinks when the track has no PressDepth attribute
local BLINK_TAG = "CardioBlinkKey"
local BLINK_WARN = 0.5 -- seconds of warning flashes before a blinking key fades (as Fx.Modes)
local BLINK_FLASH_HZ = 6
local BLINK_DIM = 0.4 -- key transparency on a warning flash frame
local BLINK_OFF = 0.75 -- ... while its platform is off
local BLINK_RADIUS = 250 -- studs from the camera
local DOOR_TAG = "CardioDoor"
local DOOR_RATE = 10 -- countdown label updates per second
local DOOR_RADIUS = 250 -- studs from the camera
local DOOR_RETRY = 2 -- seconds between searches for a door's missing Countdown label
local DOOR_GO = Color3.fromRGB(70, 235, 110)
local DOOR_WAIT = Color3.fromRGB(255, 60, 60)
local PRESS_UP = 0.18 -- seconds to spring back (after the last foot leaves it)
local BUCKET_DEFAULT = 2.8 -- studs per spatial-hash cell without the track's KeyPitch (one keycap)
local OTHER_RADIUS = 90 -- other players' presses within this many studs
local OTHER_MAX = 6 -- at most this many other players (scaled by Budget.count)
local LINE_COUNT = 28
local LINES_FROM = 50 -- studs/s: speed lines and FOV start above this
local LINES_FULL = 110 -- studs/s: full effect
local FOV_MAX = 12
local CLICK_RATE = 12 -- local key clicks per second at most
local POP_POOL = 8
local POP_LIFE = 0.9
local POP_COLOR = Color3.fromRGB(176, 92, 255)
local SNEAKER_COLOR = Color3.fromRGB(255, 70, 80)
local BELT_SPEED = 6 -- studs/s for treadmills nobody local is on
local RUN_ANIM_MAX = 4 -- fastest run-in-place playback (x the 16 studs/s pace)
local TAU = math.pi * 2

local RAINBOW: { Color3 } = {
	W.Pink or Color3.fromRGB(255, 138, 190),
	W.Orange or Color3.fromRGB(255, 170, 70),
	W.Sunny or Color3.fromRGB(255, 220, 80),
	W.Mint or Color3.fromRGB(98, 224, 160),
	W.Blue or Color3.fromRGB(90, 170, 255),
	W.Grape or Color3.fromRGB(170, 132, 255),
}
local WHITE = Color3.new(1, 1, 1)
local INK: Color3 = C.Ink or Color3.fromRGB(30, 34, 60)

export type Key = {
	part: BasePart,
	parts: { BasePart },
	rest: { CFrame },
	frame: CFrame, -- the key part's rest CFrame
	hx: number,
	hz: number,
	top: number,
	fixed: boolean, -- blink / mover keys: never moved here
	cells: { number },
}

type Treadmill = { model: Instance, belt: BasePart, textures: { Texture }, dir: number, phase: number }
type Line = { frame: Frame, angle: number, r: number, speed: number }

local keys: { [BasePart]: Key } = {}
-- Grid cell size (studs): the track's KeyPitch, read when the keys are indexed.
local bucket = BUCKET_DEFAULT
local buckets: { [number]: { Key } } = {}
local pressed: { [Key]: number } = {}
-- Studs each pressed key sinks (the track's PressDepth when it was pressed).
local pressShare: { [Key]: number } = {}
type Door = { part: BasePart, label: TextLabel?, lookedAt: number, scaled: boolean? }
local doors: { [BasePart]: Door } = {}
local doorAt = 0
local treadmills: { [Instance]: Treadmill } = {}
local lines: { Line } = {}
local otherLast: { [Player]: Key? } = {}

local active = false
local startedAt = 0
local snap: { [string]: any } = {}
local stepConn: RBXScriptConnection? = nil
local folder: Folder? = nil
local linesGui: ScreenGui? = nil
local lastClick = 0
local localKey: Key? = nil
-- Keys under other players' feet this frame (kept pressed down).
local heldOther: { Key } = {}
local speedK = 0
local fovBase: number? = nil
local runTrack: AnimationTrack? = nil
local runTrackOwner: Humanoid? = nil
local puffAt = 0
local sweatAt = 0
local indexed = false

-- Reused per-frame buffers (no allocations in the hot path beyond CFrames).
local moveParts: { BasePart } = {}
local moveFrames: { CFrame } = {}

local function num(value: any, default: number): number
	return if type(value) == "number" and value == value then value else default
end

local function cellId(bx: number, bz: number): number
	return (bx + 4096) * 8192 + (bz + 4096)
end

local function reducedMotion(): boolean
	local data = State.data
	return type(data) == "table" and type(data.settings) == "table" and data.settings.reducedMotion == true
end

local function character(): (Humanoid?, BasePart?)
	local char = player.Character
	if not char then
		return nil, nil
	end
	local humanoid = char:FindFirstChildOfClass("Humanoid")
	local root = char:FindFirstChild("HumanoidRootPart")
	if humanoid and humanoid.Health > 0 and root and root:IsA("BasePart") then
		return humanoid, root
	end
	return nil, nil
end

local function feetY(humanoid: Humanoid, root: BasePart): number
	local legs = if humanoid.RigType == Enum.HumanoidRigType.R6 then 2 else humanoid.HipHeight
	return root.Position.Y - root.Size.Y / 2 - legs
end

local function fxFolder(): Folder
	local f = folder
	if f and f.Parent then
		return f
	end
	local made = Instance.new("Folder")
	made.Name = "CardioFx"
	made.Parent = Workspace
	folder = made
	return made
end

-- Key index -----------------------------------------------------------------------------------

local function tagged(inst: Instance, tag: string): boolean
	return CollectionService:HasTag(inst, tag) or (inst.Parent ~= nil and CollectionService:HasTag(inst.Parent :: Instance, tag))
end

local function addKey(inst: Instance)
	if not inst:IsA("BasePart") or keys[inst] then
		return
	end
	local part = inst :: BasePart
	local mover = tagged(part, "ModeMover") or part:GetAttribute("Mover") ~= nil
	local parts: { BasePart } = { part }
	local rest: { CFrame } = { part.CFrame }
	for _, d in part:GetDescendants() do
		if d:IsA("BasePart") and d.Anchored then
			table.insert(parts, d)
			table.insert(rest, d.CFrame)
		end
	end
	local key: Key = {
		part = part,
		parts = parts,
		rest = rest,
		frame = part.CFrame,
		hx = part.Size.X / 2,
		hz = part.Size.Z / 2,
		top = part.Position.Y + part.Size.Y / 2,
		fixed = mover,
		cells = {},
	}
	keys[part] = key
	-- Every cell the key's footprint covers (wide keys span several).
	local reach = math.max(key.hx, key.hz) + 0.5
	local p = part.Position
	for bx = math.floor((p.X - reach) / bucket), math.floor((p.X + reach) / bucket) do
		for bz = math.floor((p.Z - reach) / bucket), math.floor((p.Z + reach) / bucket) do
			local id = cellId(bx, bz)
			local list = buckets[id]
			if not list then
				list = {}
				buckets[id] = list
			end
			table.insert(list, key)
			table.insert(key.cells, id)
		end
	end
end

local function restore(key: Key)
	if key.part.Parent then
		Workspace:BulkMoveTo(key.parts, key.rest, Enum.BulkMoveMode.FireCFrameChanged)
	end
end

local function removeKey(inst: Instance)
	local key = keys[inst :: BasePart]
	if not key then
		return
	end
	keys[inst :: BasePart] = nil
	pressed[key] = nil
	pressShare[key] = nil
	for _, id in key.cells do
		local list = buckets[id]
		if list then
			local i = table.find(list, key)
			if i then
				table.remove(list, i)
			end
		end
	end
	if localKey == key then
		localKey = nil
	end
end

local function indexKeys()
	if indexed then
		return
	end
	indexed = true
	local track = Workspace:FindFirstChild("CardioTrack")
	bucket = math.max(num(track and track:GetAttribute("KeyPitch"), BUCKET_DEFAULT), 0.5)
	for _, inst in CollectionService:GetTagged(KEY_TAG) do
		addKey(inst)
	end
	CollectionService:GetInstanceAddedSignal(KEY_TAG):Connect(addKey)
	CollectionService:GetInstanceRemovedSignal(KEY_TAG):Connect(removeKey)
end

-- The key whose cap is under (x, z) with the feet at `feet` (nil when airborne / off keys).
local function keyAt(pos: Vector3, feet: number, below: number, above: number): Key?
	local list = buckets[cellId(math.floor(pos.X / bucket), math.floor(pos.Z / bucket))]
	if not list then
		return nil
	end
	for _, key in list do
		local rise = feet - key.top
		if rise >= below and rise <= above then
			local lp = key.frame:PointToObjectSpace(pos)
			if math.abs(lp.X) <= key.hx + 0.3 and math.abs(lp.Z) <= key.hz + 0.3 then
				return key
			end
		end
	end
	return nil
end

-- Presses -------------------------------------------------------------------------------------

local function click(_key: Key)
	local now = os.clock()
	if now - lastClick < 1 / CLICK_RATE then
		return
	end
	lastClick = now
	Sounds.play("KeyClick", 0.08)
end

-- Studs a pressed key sinks: the track's PressDepth (its collision slabs sit that far below
-- the key tops), the same at every WalkSpeed.
local function pressTravel(): number
	local track = Workspace:FindFirstChild("CardioTrack")
	return num(track and track:GetAttribute("PressDepth"), PRESS_DEFAULT)
end

local function press(key: Key, mine: boolean, _walk: number)
	if mine then
		click(key)
	end
	if key.fixed then
		return
	end
	pressed[key] = os.clock()
	pressShare[key] = pressTravel()
end

-- Depth `elapsed` seconds after the last foot left: fully down (the feet already stand on the
-- slab at that level, so there is no sink animation), then the spring back.
local function pressDepth(elapsed: number, travel: number): number?
	local u = elapsed / PRESS_UP
	if u >= 1 then
		return nil
	end
	-- Back-out return: a little pop above the rest height before settling.
	local s = 1.4
	local v = u - 1
	local back = 1 + (s + 1) * v * v * v + s * v * v
	return travel * (1 - back)
end

local function stepKeys(now: number)
	table.clear(moveParts)
	table.clear(moveFrames)
	for key, t0 in pressed do
		-- Held fully down while a foot is still on it; the return starts on release.
		if key == localKey or table.find(heldOther, key) then
			t0 = now
			pressed[key] = t0
		end
		local depth = pressDepth(now - t0, pressShare[key] or PRESS_DEFAULT)
		if depth == nil then
			pressed[key] = nil
			pressShare[key] = nil
			depth = 0
		end
		if key.part.Parent then
			local offset = Vector3.new(0, -(depth :: number), 0)
			for i, part in key.parts do
				table.insert(moveParts, part)
				table.insert(moveFrames, key.rest[i] + offset)
			end
		end
	end
	if #moveParts > 0 then
		Workspace:BulkMoveTo(moveParts, moveFrames, Enum.BulkMoveMode.FireCFrameChanged)
	end
end

local function stepPlayers(humanoid: Humanoid?, root: BasePart?)
	-- Local player: a new key under the feet while on the ground.
	if humanoid and root then
		local grounded = humanoid.FloorMaterial ~= Enum.Material.Air
		local key = if grounded then keyAt(root.Position, feetY(humanoid, root), -2, 1.6) else nil
		if key and key ~= localKey then
			press(key, true, humanoid.WalkSpeed)
		end
		localKey = key
	end
	-- Other players nearby (budgeted, nearest first is not needed: the cap is small).
	table.clear(heldOther)
	local cap = Budget.count(OTHER_MAX)
	local done = 0
	local from = if root then root.Position else nil
	for _, other in Players:GetPlayers() do
		if other ~= player and done < cap then
			local char = other.Character
			local oRoot = char and char:FindFirstChild("HumanoidRootPart")
			local oHum = char and char:FindFirstChildOfClass("Humanoid")
			if oRoot and oRoot:IsA("BasePart") and oHum and from and (oRoot.Position - from).Magnitude <= OTHER_RADIUS then
				done += 1
				local key = keyAt(oRoot.Position, feetY(oHum, oRoot), -2, 1.2)
				if key and key ~= otherLast[other] then
					press(key, false, oHum.WalkSpeed)
				end
				otherLast[other] = key
				if key then
					table.insert(heldOther, key)
				end
			else
				otherLast[other] = nil
			end
		end
	end
end

-- Treadmills ----------------------------------------------------------------------------------

local function addTreadmill(model: Instance)
	if treadmills[model] then
		return
	end
	local belt = if model:IsA("BasePart") and model.Name == "Belt" then model else model:FindFirstChild("Belt", true)
	if not belt or not belt:IsA("BasePart") then
		-- Streaming may deliver the belt later.
		task.delay(2, function()
			if model.Parent and not treadmills[model] and CollectionService:HasTag(model, TREADMILL_TAG) then
				local late = model:FindFirstChild("Belt", true)
				if late and late:IsA("BasePart") then
					addTreadmill(model)
				end
			end
		end)
		return
	end
	local textures: { Texture } = {}
	for _, d in belt:GetChildren() do
		if d:IsA("Texture") then
			table.insert(textures, d)
		end
	end
	treadmills[model] = {
		model = model,
		belt = belt :: BasePart,
		textures = textures,
		dir = num(belt:GetAttribute("BeltDir"), num(model:GetAttribute("BeltDir"), 1)),
		phase = 0,
	}
end

local function removeTreadmill(model: Instance)
	treadmills[model] = nil
end

-- The treadmill whose belt the local player stands on, if any.
local function beltUnder(humanoid: Humanoid, root: BasePart): Treadmill?
	local feet = feetY(humanoid, root)
	for _, t in treadmills do
		local belt = t.belt
		if belt.Parent then
			local lp = belt.CFrame:PointToObjectSpace(root.Position)
			local half = belt.Size / 2
			local top = belt.Position.Y + half.Y
			local rise = feet - top
			if math.abs(lp.X) <= half.X + 0.5 and math.abs(lp.Z) <= half.Z + 0.5 and rise > -1.2 and rise < 2.5 then
				return t
			end
		end
	end
	return nil
end

local function runAnimation(humanoid: Humanoid): AnimationTrack?
	if runTrack and runTrackOwner == humanoid then
		return runTrack
	end
	runTrack, runTrackOwner = nil, nil
	local animator = humanoid:FindFirstChildOfClass("Animator")
	local char = humanoid.Parent
	if not animator or not char then
		return nil
	end
	local animate = char:FindFirstChild("Animate")
	local run = animate and animate:FindFirstChild("run")
	local source = run and run:FindFirstChildOfClass("Animation")
	local id = if source then source.AnimationId else ""
	if id == "" then
		id = if humanoid.RigType == Enum.HumanoidRigType.R6 then "rbxassetid://180426354" else "rbxassetid://913376220"
	end
	local anim = Instance.new("Animation")
	anim.AnimationId = id
	local ok, track = pcall(function()
		return animator:LoadAnimation(anim)
	end)
	if not ok or not track then
		return nil
	end
	track.Priority = Enum.AnimationPriority.Movement
	track.Looped = true
	runTrack, runTrackOwner = track, humanoid
	return track
end

local function stopRun()
	local track = runTrack
	if track and track.IsPlaying then
		track:Stop(0.2)
	end
end

local function anchorAt(position: Vector3, life: number): BasePart
	local part = Instance.new("Part")
	part.Name = "CardioFxAnchor"
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Transparency = 1
	part.Size = Vector3.one * 0.2
	part.CFrame = CFrame.new(position)
	part.Parent = fxFolder()
	task.delay(life, function()
		part:Destroy()
	end)
	return part
end

local function stepTreadmills(dt: number, now: number, humanoid: Humanoid?, root: BasePart?)
	local on: Treadmill? = nil
	if humanoid and root then
		on = beltUnder(humanoid, root)
	end
	local camera = Workspace.CurrentCamera
	local eye = if camera then camera.CFrame.Position else Vector3.zero
	-- The belt under you scrolls at your own WalkSpeed, so faster runners visibly run faster.
	local walk = if humanoid then math.max(humanoid.WalkSpeed, BELT_SPEED) else BELT_SPEED
	for _, t in treadmills do
		if #t.textures > 0 and t.belt.Parent and (t.belt.Position - eye).Magnitude < 180 then
			local speed = if t == on then walk else BELT_SPEED
			t.phase += dt * speed * t.dir
			for _, texture in t.textures do
				local tile = math.max(texture.StudsPerTileV, 0.1)
				texture.OffsetStudsV = t.phase % tile
			end
		end
	end
	if not (humanoid and root) then
		stopRun()
		return
	end
	local h = humanoid :: Humanoid
	local r = root :: BasePart
	local idle = h.MoveDirection.Magnitude < 0.2 and h.FloorMaterial ~= Enum.Material.Air
	if on and idle then
		local track = runAnimation(h)
		if track then
			if not track.IsPlaying then
				track:Play(0.2)
			end
			-- The run cycle is paced for 16 studs/s (as Animate does): match the WalkSpeed.
			track:AdjustSpeed(math.clamp(walk / 16, 1, RUN_ANIM_MAX))
		end
		-- Turn to face along the belt.
		local fwd = on.belt.CFrame.LookVector
		local flat = Vector3.new(fwd.X, 0, fwd.Z)
		if flat.Magnitude > 0.1 then
			local look = r.CFrame.LookVector
			local want = flat.Unit
			if look:Dot(want) < 0.999 then
				local goal = CFrame.lookAt(r.Position, r.Position + want)
				r.CFrame = r.CFrame:Lerp(goal, math.min(1, dt * 8))
			end
		end
		-- Dust puffs behind the feet and the odd sweat drop.
		if now - puffAt > (if Budget.low() then 0.7 else 0.35) and Sprites.room() then
			puffAt = now
			local feet = Vector3.new(r.Position.X, feetY(h, r) + 0.4, r.Position.Z) - flat.Unit * 2
			local anchor = anchorAt(feet, 1.5)
			Sprites.billboard(anchor, "Puff", {
				position = feet,
				size = 1.6,
				life = 0.7,
				rise = Vector3.new(0, 1.2, 0) - flat.Unit * 2.5,
				color = Color3.fromRGB(235, 240, 255),
			})
		end
		if now - sweatAt > 1.3 and Sprites.room() then
			sweatAt = now
			local head = r.Position + Vector3.new((math.random() - 0.5) * 1.5, 2.6, 0)
			local anchor = anchorAt(head, 1.5)
			Sprites.billboard(anchor, "Sweat", {
				position = head,
				size = 0.9,
				life = 0.8,
				rise = Vector3.new((math.random() - 0.5) * 2, -1.6, 0),
			})
		end
	else
		stopRun()
	end
end

-- Speed lines and FOV -------------------------------------------------------------------------

local function resetLine(line: Line, fresh: boolean)
	line.angle = math.random() * TAU
	line.r = if fresh then 0.3 + math.random() * 0.8 else 0.35 + math.random() * 0.25
	line.speed = 1.6 + math.random() * 1.4
	line.frame.Rotation = math.deg(line.angle)
end

local function ensureLines()
	if linesGui and linesGui.Parent then
		return
	end
	local gui = Instance.new("ScreenGui")
	gui.Name = "CardioSpeedLines"
	gui.IgnoreGuiInset = true
	gui.ResetOnSpawn = false
	gui.DisplayOrder = -1
	gui.Enabled = false
	gui.Parent = player:WaitForChild("PlayerGui")
	linesGui = gui
	table.clear(lines)
	for _ = 1, Budget.count(LINE_COUNT) do
		local frame = Instance.new("Frame")
		frame.Name = "Line"
		frame.BorderSizePixel = 0
		frame.BackgroundColor3 = WHITE
		frame.AnchorPoint = Vector2.new(0.5, 0.5)
		frame.BackgroundTransparency = 1
		local gradient = Instance.new("UIGradient")
		gradient.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 1),
			NumberSequenceKeypoint.new(0.4, 0.2),
			NumberSequenceKeypoint.new(1, 0.9),
		})
		gradient.Parent = frame
		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(1, 0)
		corner.Parent = frame
		frame.Parent = gui
		local line: Line = { frame = frame, angle = 0, r = 0, speed = 1 }
		resetLine(line, true)
		table.insert(lines, line)
	end
end

local function applyFov(delta: number)
	local camera = Workspace.CurrentCamera
	if not camera then
		return
	end
	if delta > 0.01 then
		if not fovBase then
			fovBase = camera.FieldOfView
		end
		camera.FieldOfView = (fovBase :: number) + delta
	elseif fovBase then
		camera.FieldOfView = fovBase :: number
		fovBase = nil
	end
end

local function stepSpeed(dt: number, root: BasePart?)
	local hv = 0
	if root then
		local v = root.AssemblyLinearVelocity
		hv = Vector3.new(v.X, 0, v.Z).Magnitude
	end
	local goal = math.clamp((hv - LINES_FROM) / (LINES_FULL - LINES_FROM), 0, 1)
	speedK += (goal - speedK) * math.min(1, dt * 4)
	if speedK < 0.005 then
		speedK = 0
	end
	local reduced = reducedMotion()
	applyFov(if reduced then 0 else FOV_MAX * speedK)
	if speedK <= 0 then
		if linesGui then
			linesGui.Enabled = false
		end
		return
	end
	ensureLines()
	local gui = linesGui :: ScreenGui
	gui.Enabled = true
	local camera = Workspace.CurrentCamera
	local view = if camera then camera.ViewportSize else Vector2.new(1280, 720)
	local centre = view / 2
	local reach = centre.Magnitude
	local strength = speedK * (if reduced then 0.5 else 1)
	for _, line in lines do
		line.r += dt * line.speed * (0.6 + strength)
		if line.r > 1.15 then
			resetLine(line, false)
		end
		local dir = Vector2.new(math.cos(line.angle), math.sin(line.angle))
		local pos = centre + dir * line.r * reach
		local len = (40 + 140 * strength) * (0.5 + line.r)
		line.frame.Position = UDim2.fromOffset(pos.X, pos.Y)
		line.frame.Size = UDim2.fromOffset(len, 2 + 2 * strength)
		-- Fade in from the centre, strongest near the edges.
		local edge = math.clamp((line.r - 0.35) / 0.4, 0, 1)
		line.frame.BackgroundTransparency = 1 - 0.55 * strength * edge
	end
end

-- Bursts --------------------------------------------------------------------------------------

local function burst(position: Vector3, count: number, spread: number, big: boolean)
	local anchor = anchorAt(position, 3)
	Sprites.billboard(anchor, "StarPop", {
		position = position + Vector3.new(0, 2, 0),
		size = if big then 4 else 2.6,
		life = 1,
		rise = Vector3.new(0, 3, 0),
		spin = 60,
	})
	local n = Budget.count(count)
	for i = 1, n do
		if not Sprites.room() then
			break -- decorative: the device's sprite budget is full
		end
		local a = i / n * TAU
		local star = big and i % 3 == 0
		Sprites.billboard(anchor, if star then "StarPop" else "Confetti", {
			position = position + Vector3.new(0, 2, 0),
			size = if star then 1.8 else 1,
			life = 1.4,
			delay = 0.025 * i,
			rise = Vector3.new(math.cos(a) * spread, 5 + (i % 3), math.sin(a) * spread),
			color = if star then nil else RAINBOW[(i % #RAINBOW) + 1],
			spin = 220,
		})
	end
end

local function sparkle(position: Vector3, count: number, color: Color3)
	local anchor = anchorAt(position, 3)
	local n = Budget.count(count)
	for i = 1, n do
		if not Sprites.room() then
			break
		end
		local a = i / n * TAU
		Sprites.billboard(anchor, "Sparkle", {
			position = position,
			size = 1.2,
			life = 0.8,
			delay = 0.03 * i,
			rise = Vector3.new(math.cos(a) * 3, 3, math.sin(a) * 3),
			color = color,
			spin = 90,
		})
	end
end

local function playerPos(): Vector3?
	local _, root = character()
	return if root then root.Position else nil
end

-- Step pops ------------------------------------------------------------------------------------

type Pop = { gui: BillboardGui, text: TextLabel, icon: GuiObject, scale: UIScale, token: number }

local pops: { Pop } = {}
local popIndex = 0
local popFolder: Folder? = nil
local speedTag: BillboardGui? = nil
local speedTagText: TextLabel? = nil

local function guiFolder(): Folder
	local f = popFolder
	if f and f.Parent then
		return f
	end
	local made = Instance.new("Folder")
	made.Name = "CardioPops"
	made.Parent = player:WaitForChild("PlayerGui")
	popFolder = made
	table.clear(pops)
	speedTag = nil
	return made
end

local function outlined(parent: Instance, size: number, color: Color3): TextLabel
	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.FredokaOne
	label.TextSize = size
	label.TextColor3 = color
	label.Text = ""
	label.AutomaticSize = Enum.AutomaticSize.X
	label.Size = UDim2.fromOffset(0, size + 4)
	local stroke = Instance.new("UIStroke")
	stroke.Color = INK
	stroke.Thickness = math.max(2, size / 10)
	stroke.LineJoinMode = Enum.LineJoinMode.Round
	stroke.Parent = label
	label.Parent = parent
	return label
end

-- The Speedy Sneakers icon (atlas "CosSpeed"), or a text glyph when the atlas is missing.
local function sneaker(parent: Instance, size: number): GuiObject
	local cell = Assets.icon and Assets.icon("CosSpeed")
	if type(cell) == "table" and type(cell.image) == "string" then
		local image = Instance.new("ImageLabel")
		image.Name = "Sneaker"
		image.BackgroundTransparency = 1
		image.Image = cell.image
		image.ImageRectOffset = Vector2.new(num(cell.x, 0), num(cell.y, 0))
		image.ImageRectSize = Vector2.new(num(cell.w, 0), num(cell.h, 0))
		image.ScaleType = Enum.ScaleType.Fit
		image.Size = UDim2.fromOffset(size, size)
		image.Parent = parent
		return image
	end
	local glyph = outlined(parent, size - 4, SNEAKER_COLOR)
	glyph.Name = "Sneaker"
	glyph.Text = utf8.char(0x1F45F)
	return glyph
end

local function makePop(): Pop
	local gui = Instance.new("BillboardGui")
	gui.Name = "StepPop"
	gui.Size = UDim2.fromOffset(170, 44)
	gui.AlwaysOnTop = true
	gui.LightInfluence = 0
	gui.MaxDistance = 120
	gui.ResetOnSpawn = false
	gui.Enabled = false
	local row = Instance.new("Frame")
	row.BackgroundTransparency = 1
	row.Size = UDim2.fromScale(1, 1)
	row.Parent = gui
	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.VerticalAlignment = Enum.VerticalAlignment.Center
	layout.Padding = UDim.new(0, 4)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = row
	local icon = sneaker(row, 34)
	icon.LayoutOrder = 1
	local text = outlined(row, 32, POP_COLOR)
	text.Name = "Amount"
	text.LayoutOrder = 2
	local scale = Instance.new("UIScale")
	scale.Parent = row
	gui.Parent = guiFolder()
	return { gui = gui, text = text, icon = icon, scale = scale, token = 0 }
end

local function hidePops()
	for _, pop in pops do
		pop.token += 1
		pop.gui.Enabled = false
		(pop.gui :: any).Adornee = nil
	end
	if speedTag then
		speedTag.Enabled = false
	end
end

local function popStep(gained: number)
	local _, root = character()
	if not root then
		return
	end
	guiFolder()
	if #pops < Budget.count(POP_POOL) then
		table.insert(pops, makePop())
	end
	popIndex = popIndex % #pops + 1
	local pop = pops[popIndex]
	pop.token += 1
	local mine = pop.token
	local whole = math.max(1, math.floor(gained + 0.5))
	pop.text.Text = "+" .. (if whole < 1e4 then tostring(whole) else string.format("%.1fK", whole / 1000))
	pop.text.TextTransparency = 0
	local start = Vector3.new((math.random() - 0.5) * 3, 1.6 + math.random() * 0.8, (math.random() - 0.5) * 1.5)
	pop.gui.StudsOffsetWorldSpace = start
	pop.gui.Adornee = root
	pop.gui.Enabled = true
	pop.scale.Scale = 0.3
	local big = whole >= 10
	TweenService:Create(pop.scale, TweenInfo.new(0.22, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = if big then 1.2 else 1 })
		:Play()
	TweenService:Create(pop.gui, TweenInfo.new(POP_LIFE, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		StudsOffsetWorldSpace = start + Vector3.new(0, 3.2, 0),
	}):Play()
	local fade = TweenInfo.new(POP_LIFE * 0.45, Enum.EasingStyle.Quad, Enum.EasingDirection.In, 0, false, POP_LIFE * 0.55)
	TweenService:Create(pop.text, fade, { TextTransparency = 1 }):Play()
	local stroke = pop.text:FindFirstChildOfClass("UIStroke")
	if stroke then
		stroke.Transparency = 0
		TweenService:Create(stroke, fade, { Transparency = 1 }):Play()
	end
	if pop.icon:IsA("ImageLabel") then
		pop.icon.ImageTransparency = 0
		TweenService:Create(pop.icon, fade, { ImageTransparency = 1 }):Play()
	elseif pop.icon:IsA("TextLabel") then
		pop.icon.TextTransparency = 0
		TweenService:Create(pop.icon, fade, { TextTransparency = 1 }):Play()
	end
	task.delay(POP_LIFE + 0.05, function()
		if pop.token == mine then
			pop.gui.Enabled = false
		end
	end)
end

local function multText(m: number): string
	return if m == math.floor(m) then tostring(m) else string.format("%.2f", m):gsub("0$", "")
end

-- "x{multiplier} SPEED" above the head while on a treadmill.
local function paintSpeedTag(on: boolean)
	local _, root = character()
	if not on or not root then
		if speedTag then
			speedTag.Enabled = false
		end
		return
	end
	local folder = guiFolder()
	local tag = speedTag
	if not tag then
		local gui = Instance.new("BillboardGui")
		gui.Name = "TreadmillSpeed"
		gui.Size = UDim2.fromOffset(200, 40)
		gui.StudsOffsetWorldSpace = Vector3.new(0, 4.6, 0)
		gui.AlwaysOnTop = true
		gui.LightInfluence = 0
		gui.MaxDistance = 120
		gui.ResetOnSpawn = false
		local text = outlined(gui, 30, Color3.fromRGB(255, 226, 92))
		text.AutomaticSize = Enum.AutomaticSize.None
		text.Size = UDim2.fromScale(1, 1)
		gui.Parent = folder
		speedTag, speedTagText = gui, text
		tag = gui
	end
	local gui = tag :: BillboardGui
	local m = num(snap.treadmillMult, num(snap.multiplier, 1))
	local label = speedTagText :: TextLabel
	label.Text = "x" .. multText(m) .. " SPEED"
	gui.Adornee = root
	gui.Enabled = true
end

function CardioFx.onSteps(data: any)
	if not active or type(data) ~= "table" then
		return
	end
	if type(data.treadmill) == "boolean" then
		snap.onTreadmill = data.treadmill
	end
	paintSpeedTag(snap.onTreadmill == true)
	local gained = num(data.gained, 0)
	if gained > 0 then
		popStep(gained)
	end
end

-- Activation ----------------------------------------------------------------------------------

local function restoreAll()
	for key in pressed do
		restore(key)
	end
	table.clear(pressed)
	table.clear(pressShare)
	hidePops()
	localKey = nil
	table.clear(otherLast)
end

-- Doors --------------------------------------------------------------------------------------

local function addDoor(inst: Instance)
	if inst:IsA("BasePart") then
		doors[inst] = { part = inst, label = nil, lookedAt = -math.huge }
	end
end

local function removeDoor(inst: Instance)
	doors[inst :: BasePart] = nil
end

-- The door's sign label: "Countdown" inside the door, else inside its parent model.
local function doorLabel(door: Door, now: number): TextLabel?
	local label = door.label
	if label and label.Parent then
		return label
	end
	door.label = nil
	if now - door.lookedAt < DOOR_RETRY then
		return nil
	end
	door.lookedAt = now
	local found = door.part:FindFirstChild("Countdown", true)
	local parent = door.part.Parent
	if not (found and found:IsA("TextLabel")) and parent and parent ~= Workspace then
		found = parent:FindFirstChild("Countdown", true)
	end
	if found and found:IsA("TextLabel") then
		door.label = found
		return found
	end
	return nil
end

-- Blinking keys --------------------------------------------------------------------------------

type BlinkKey = { part: BasePart, rest: number, on: number, period: number, phase: number, state: string }
local blinkKeys: { [BasePart]: BlinkKey } = {}

local function addBlinkKey(inst: Instance)
	if inst:IsA("BasePart") and not blinkKeys[inst] then
		blinkKeys[inst] = {
			part = inst,
			rest = inst.Transparency,
			on = num(inst:GetAttribute("BlinkOn"), 2),
			period = math.max(num(inst:GetAttribute("BlinkPeriod"), 3), 0.2),
			phase = num(inst:GetAttribute("BlinkPhase"), 0),
			state = "",
		}
	end
end

local function setBlinkKey(b: BlinkKey, state: string)
	if b.state == state then
		return
	end
	b.state = state
	b.part.Transparency = if state == "off" then BLINK_OFF elseif state == "dim" then math.max(b.rest, BLINK_DIM) else b.rest
end

-- Same formula as Fx.Modes' blink pads (the platform's slab): off while
-- ((t + phase) % period) >= on, a flash frame every 1 / (2 BLINK_FLASH_HZ) s in the last BLINK_WARN s.
local function stepBlinkKeys()
	local camera = Workspace.CurrentCamera
	if not camera or next(blinkKeys) == nil then
		return
	end
	local eye = camera.CFrame.Position
	local t = Workspace:GetServerTimeNow()
	for part, b in blinkKeys do
		if not part.Parent then
			blinkKeys[part] = nil
		elseif (part.Position - eye).Magnitude <= BLINK_RADIUS then
			local into = (t + b.phase) % b.period
			local state = "on"
			if into >= b.on then
				state = "off"
			else
				local left = b.on - into
				if left < BLINK_WARN and math.floor(left * BLINK_FLASH_HZ * 2) % 2 == 0 then
					state = "dim"
				end
			end
			setBlinkKey(b, state)
		end
	end
end

local function stepDoors(now: number)
	if now - doorAt < 1 / DOOR_RATE then
		return
	end
	doorAt = now
	local camera = Workspace.CurrentCamera
	if not camera then
		return
	end
	local eye = camera.CFrame.Position
	local t = Workspace:GetServerTimeNow()
	for part, door in doors do
		if part.Parent and (part.Position - eye).Magnitude <= DOOR_RADIUS then
			local label = doorLabel(door, now)
			if label then
				local open = num(part:GetAttribute("DoorOpen"), 0)
				local period = num(part:GetAttribute("DoorPeriod"), 0)
				local phase = num(part:GetAttribute("DoorPhase"), 0)
				local text, color
				local closed = false
				if period <= 0 or open >= period then
					text, color = "GO!", DOOR_GO
				else
					local at = (t + phase) % period
					if at < open then
						text, color = string.format("GO! %.1f", open - at), DOOR_GO
					else
						text, color = string.format("%.2f", period - at), DOOR_WAIT
						closed = true
					end
				end
				-- Closed: the number with a smaller "Wait..." line under it (rich text at
				-- sizes fitted to the sign); open: the label's own scaled text.
				if door.scaled == nil then
					door.scaled = label.TextScaled
				end
				if closed then
					local box = label.AbsoluteSize
					local big = math.floor(math.min(box.Y * 0.62, box.X / (#text * 0.62)))
					if big >= 8 then
						text = string.format('%s<br/><font size="%d">Wait...</font>', text, math.max(6, math.floor(big * 0.45)))
						label.RichText = true
						label.TextScaled = false
						if label.TextSize ~= big then
							label.TextSize = big
						end
					end
				elseif label.TextScaled ~= door.scaled then
					label.TextScaled = door.scaled == true
				end
				if label.Text ~= text then
					label.Text = text
				end
				if label.TextColor3 ~= color then
					label.TextColor3 = color
				end
			end
		end
	end
end

local function step(dt: number)
	local now = os.clock()
	local humanoid, root = character()
	stepPlayers(humanoid, root)
	stepKeys(now)
	stepTreadmills(dt, now, humanoid, root)
	stepSpeed(dt, root)
	stepDoors(now)
	stepBlinkKeys()
end

-- Run glow: our own bloom + a touch more saturation so the neon trusses glow (Fx.Surge
-- keeps its own SurgeBloom / SurgeGrade; these are separate instances, removed on stop).
local runBloom: BloomEffect? = nil
local runGrade: ColorCorrectionEffect? = nil
local function setGlow(on: boolean)
	if runBloom then
		runBloom:Destroy()
		runBloom = nil
	end
	if runGrade then
		runGrade:Destroy()
		runGrade = nil
	end
	if not on then
		return
	end
	local bloom = Instance.new("BloomEffect")
	bloom.Name = "CardioBloom"
	bloom.Intensity = 0.6
	bloom.Size = 24
	bloom.Threshold = 0.9
	bloom.Parent = Lighting
	runBloom = bloom
	local grade = Instance.new("ColorCorrectionEffect")
	grade.Name = "CardioGrade"
	grade.Saturation = 0.1
	grade.Parent = Lighting
	runGrade = grade
end

local function activate()
	if active then
		return
	end
	active = true
	setGlow(true)
	startedAt = os.clock()
	indexKeys()
	if not stepConn then
		stepConn = RunService.RenderStepped:Connect(step)
	end
end

local function deactivate()
	if not active then
		return
	end
	active = false
	setGlow(false)
	if stepConn then
		stepConn:Disconnect()
		stepConn = nil
	end
	restoreAll()
	stopRun()
	speedK = 0
	applyFov(0)
	if linesGui then
		linesGui.Enabled = false
	end
end

function CardioFx.onNotify(p: any)
	local event = p.event
	if event == "start" then
		activate()
		startedAt = os.clock()
	elseif event == "zone" then
		local pos = playerPos()
		if pos then
			burst(pos, 7, 4, false)
		end
	elseif event == "win" then
		-- Cashed out on a WIN pad (the last one is the finish); the run goes on in the lobby.
		local pos = playerPos()
		if pos then
			local final = p.final == true
			burst(pos, if final then 20 else 14, if final then 8 else 6, true)
		end
	elseif event == "fall" then
		task.delay(0.35, function()
			local pos = playerPos()
			if pos and active then
				local anchor = anchorAt(pos, 3)
				Sprites.billboard(anchor, "Ring", { position = pos - Vector3.new(0, 2.5, 0), size = 6, life = 0.7, rise = Vector3.zero })
				Sprites.billboard(anchor, "Puff", { position = pos, size = 3.5, life = 0.8, rise = Vector3.new(0, 2.5, 0) })
			end
		end)
	elseif event == "upgrade" then
		if p.reason == nil and p.ok ~= false then
			local pos = playerPos()
			for _, pad in CollectionService:GetTagged(PAD_TAG) do
				local at = if pad:IsA("BasePart") then pad.Position elseif pad:IsA("Model") then pad:GetPivot().Position else nil
				if at and pos and (at - pos).Magnitude < 30 then
					pos = at + Vector3.new(0, 2, 0)
					break
				end
			end
			if pos then
				sparkle(pos, 10, W.Sunny or WHITE)
			end
		end
	elseif event == "stop" then
		deactivate()
	end
end

local function onState(data: any)
	if type(data) ~= "table" or type(data.modes) ~= "table" then
		return
	end
	local s = data.modes.cardio
	if type(s) ~= "table" then
		return
	end
	snap = s
	if s.running == true then
		activate()
		paintSpeedTag(s.onTreadmill == true)
	elseif s.running == false and active and os.clock() - startedAt > 2 then
		deactivate()
	end
end

function CardioFx.init()
	for _, model in CollectionService:GetTagged(TREADMILL_TAG) do
		addTreadmill(model)
	end
	CollectionService:GetInstanceAddedSignal(TREADMILL_TAG):Connect(addTreadmill)
	CollectionService:GetInstanceRemovedSignal(TREADMILL_TAG):Connect(removeTreadmill)
	for _, door in CollectionService:GetTagged(DOOR_TAG) do
		addDoor(door)
	end
	for _, k in CollectionService:GetTagged(BLINK_TAG) do
		addBlinkKey(k)
	end
	CollectionService:GetInstanceAddedSignal(BLINK_TAG):Connect(addBlinkKey)
	CollectionService:GetInstanceAddedSignal(DOOR_TAG):Connect(addDoor)
	CollectionService:GetInstanceRemovedSignal(DOOR_TAG):Connect(removeDoor)
	Net.event("Notify").OnClientEvent:Connect(function(payload)
		if type(payload) == "table" and payload.kind == "Mode" and payload.mode == "cardio" then
			CardioFx.onNotify(payload)
		end
	end)
	Net.event("Effect").OnClientEvent:Connect(function(kind, data)
		if kind == "CardioSteps" then
			CardioFx.onSteps(data)
		end
	end)
	State.changed.Event:Connect(onState)
	if State.data then
		onState(State.data)
	end
	Players.PlayerRemoving:Connect(function(other)
		otherLast[other] = nil
	end)
	player.CharacterAdded:Connect(function()
		runTrack, runTrackOwner = nil, nil
		localKey = nil
		hidePops()
	end)
	Budget.onChange(function()
		-- Rebuild the speed lines at the new count next time they show.
		if linesGui then
			linesGui:Destroy()
			linesGui = nil
		end
	end)
end

return CardioFx
