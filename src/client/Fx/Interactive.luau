--!strict
--[[
	Fx.Interactive: brings the interactive gym props on every plot to life (World.Decor builds
	them as Interactive_<Kind> models under Workspace.Map, with attribute Interactive and the
	invisible marker parts named below). Cosmetic fun only: no remotes, no economy.

	  trampoline  Standing or landing on the bounce pad ("BounceAnchor", attribute Radius)
	              launches the local character 3-4 jumps high (InteractiveRules: higher out
	              of a bounce and while jump is held), almost straight up. The pad squashes
	              and springs back, with a puff and a pop.
	  punchbag    The "PunchPrompt" (tap / E / gamepad X) or simply running into the bag
	              ("HitZone") is a hit, at most 4 a second: the bag swings away from the
	              player and settles like a damped pendulum, the local avatar throws a quick
	              punch (alternating fists) and a combo counter pops over the bag. A part-built
	              bag hangs from "BagPivot"; the one-piece Blender mesh (bag and stand in one)
	              rocks on its base instead, more gently.
	  bench       The "LiftPrompt" lies the player down on "BenchSeat" (the server seats
	              them: one lifter at a time, seen by everyone). Every client poses whoever
	              lies there in a bench press, moves a barbell with their hands and counts
	              the reps. Jumping, moving or the prompt (now "Stop") ends it, and the lifter
	              gets up on "StandSpot" beside the bench.

	Avatars are posed like Fx.PlayerPose does it: Motor6D transforms overridden after the
	avatar's own animations have run, from the gym poses in Shared.Poses (R15 only; an R6
	avatar still bounces, hits and lifts, just without the pose).

	Each client writes what it plays onto the Interactive_ model (local attributes, for
	playtests): trampoline Bounces, BounceHeight (in jumps); punchbag Hits, Combo; bench
	Lifting (the lifter's name, or nil) and Reps.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Rules = require(Shared:WaitForChild("InteractiveRules"))
local Poses = require(Shared:WaitForChild("Poses")) :: any
local Theme = require(ReplicatedStorage:WaitForChild("Theme")) :: any
local Sounds = require(script.Parent.Parent.Sounds) :: any
local Sprites = require(script.Parent.Sprites)
local Budget = require(script.Parent.Budget)

local Interactive = {}

local player = Players.LocalPlayer
local W = Theme.World
local INK: Color3 = Theme.Colors.Stroke

local MODEL_DELAY = 0.5 -- seconds to let a model's parts arrive before setting it up
local MARKER_WAIT = 5 -- seconds to wait for a marker part before giving up on a model
local COUNTER_RANGE = 70 -- studs: the combo / rep counters fade out beyond this
local NEAR = 14 -- studs from a prop within which the local character is checked every frame

local PAD_SQUASH = 0.45 -- studs the bounce pad dips
local BOUNCE_REACH = 8 -- studs above the pad a character's root still counts as on it
local WALK_GAP = 0.5 -- seconds between hits while the player keeps pushing into the bag
local MESH_ROCK = 0.3 -- share of the swing a one-piece bag-and-stand mesh rocks on its base
local BLEND_IN = 0.25 -- seconds for a lifter to settle into the bench press
local STAND_WAIT = 1.5 -- seconds to wait for the seat to let go before giving up on standing

local UPPER_BODY = { "UpperTorso", "Head", "LeftUpperArm", "LeftLowerArm", "LeftHand", "RightUpperArm", "RightLowerArm", "RightHand" }

-- The local character ------------------------------------------------------------------------

type Joint = { motor: Motor6D, rot: CFrame, rotInv: CFrame }
type Rig = { joints: { [string]: Joint }, scale: number }
type Me = { model: Model, humanoid: Humanoid, root: BasePart }

type Handler = {
	destroy: () -> (),
	step: ((now: number, dt: number) -> ())?,
	pose: ((now: number) -> ())?,
	jumped: ((me: Me) -> ())?,
}

local live: { [Instance]: Handler } = {}
local pending: { [Instance]: boolean } = {}
local me: Me? = nil
local meConns: { RBXScriptConnection } = {}
local lastJumpRequest = -math.huge
local started = false

local function dropMe()
	for _, conn in meConns do
		conn:Disconnect()
	end
	table.clear(meConns)
	me = nil
end

-- The local character's humanoid and root, or nil while it is missing or still loading.
local function localChar(): Me?
	local character = player.Character
	local current = me
	if current and current.model == character and current.root.Parent and current.humanoid.Parent then
		return current
	end
	dropMe()
	if not character then
		return nil
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local root = character:FindFirstChild("HumanoidRootPart")
	if not humanoid or not root or not root:IsA("BasePart") then
		return nil
	end
	local fresh: Me = { model = character, humanoid = humanoid, root = root }
	me = fresh
	-- Landing with jump held jumps before any frame sees the character on the ground.
	table.insert(
		meConns,
		humanoid.StateChanged:Connect(function(_old, new)
			if new == Enum.HumanoidStateType.Jumping then
				for _, handler in live do
					if handler.jumped then
						handler.jumped(fresh)
					end
				end
			end
		end)
	)
	return fresh
end

local function holdingJump(humanoid: Humanoid): boolean
	return humanoid.Jump or os.clock() - lastJumpRequest < 0.2
end

-- Normal take-off speed of the avatar's jump.
local function jumpSpeed(humanoid: Humanoid): number
	local speed = if humanoid.UseJumpPower then humanoid.JumpPower else Rules.jumpSpeed(Workspace.Gravity, humanoid.JumpHeight)
	-- A mode may have switched jumping off: the pad still bounces like a default avatar.
	return if speed >= 10 then speed else 50
end

-- Posing --------------------------------------------------------------------------------------

local POSE: { [string]: { [string]: CFrame } } = {}
local rigs: { [Model]: { rig: Rig?, at: number } } = setmetatable({}, { __mode = "k" }) :: any

local function collectRig(character: Model): Rig?
	local joints: { [string]: Joint } = {}
	for _, d in character:GetDescendants() do
		if d:IsA("Motor6D") and d.Part1 then
			local limb = d.Part1.Name
			if not joints[limb] and table.find(Poses.LIMBS, limb) then
				local rot = d.C0.Rotation
				joints[limb] = { motor = d, rot = rot, rotInv = rot:Inverse() }
			end
		end
	end
	if not joints.LowerTorso or not joints.UpperTorso then
		return nil
	end
	return { joints = joints, scale = character:GetScale() }
end

-- The R15 joints of `character`, looked up again (at most once a second) when the avatar was
-- rebuilt or had not finished loading; nil for an R6 or missing avatar.
local function rigFor(character: Model, now: number): Rig?
	local entry = rigs[character]
	if entry then
		local rig = entry.rig
		if rig and rig.joints.UpperTorso.motor.Parent then
			return rig
		end
		if now - entry.at < 1 then
			return nil
		end
	end
	local rig = collectRig(character)
	rigs[character] = { rig = rig, at = now }
	return rig
end

-- Poses `limbs` part way (alpha) from pose `a` to pose `b`, mixed over the avatar's own
-- animation by `weight`. Call from PreSimulation, after the animations have run.
local function poseRig(rig: Rig, a: { [string]: CFrame }, b: { [string]: CFrame }, alpha: number, weight: number, limbs: { string })
	for _, limb in limbs do
		local joint = rig.joints[limb]
		if not joint or not joint.motor.Parent then
			continue
		end
		local cf = a[limb]:Lerp(b[limb], alpha)
		local transform = joint.rotInv * cf.Rotation * joint.rot
		if limb == "LowerTorso" then
			transform = CFrame.new(joint.rotInv * Vector3.new(0, cf.Y * rig.scale, 0)) * transform
		end
		joint.motor.Transform = if weight >= 1 then transform else joint.motor.Transform:Lerp(transform, weight)
	end
end

-- Hands `limbs` back to the avatar's own animations.
local function restRig(rig: Rig, limbs: { string })
	for _, limb in limbs do
		local joint = rig.joints[limb]
		if joint and joint.motor.Parent then
			joint.motor.Transform = CFrame.identity
		end
	end
end

-- The local avatar's punch: one at a time, alternating fists.
local punchAt = -math.huge
local punchSide = "Left"
local punchRig: Rig? = nil

local function throwPunch(who: Me, toward: Vector3?)
	punchSide = if punchSide == "Right" then "Left" else "Right"
	punchAt = os.clock()
	-- A punch from the prompt while standing about: turn to face the bag first.
	if toward and who.humanoid.MoveDirection.Magnitude < 0.1 and who.humanoid.SeatPart == nil then
		local at = who.root.Position
		who.root.CFrame = CFrame.lookAt(at, at + toward)
	end
end

local function posePunch(now: number)
	local t = now - punchAt
	local who = if t < Rules.PUNCH_TIME then localChar() else nil
	local rig = if who and who.humanoid.SeatPart == nil then rigFor(who.model, now) else nil
	if not rig then
		if punchRig then
			restRig(punchRig, UPPER_BODY)
			punchRig = nil
		end
		return
	end
	local reach, weight = Rules.punch(t)
	poseRig(rig, POSE.PunchGuard, POSE["Punch" .. punchSide], reach, weight, UPPER_BODY)
	punchRig = rig
end

-- Small pieces ----------------------------------------------------------------------------------

local function flat(v: Vector3): Vector3
	return Vector3.new(v.X, 0, v.Z)
end

local function marker(model: Instance, name: string): BasePart?
	local found = model:WaitForChild(name, MARKER_WAIT)
	return if found and found:IsA("BasePart") then found else nil
end

type Counter = {
	show: (text: string, color: Color3, size: number) -> (),
	hide: () -> (),
	destroy: () -> (),
}

-- A number that pops over a prop: Display type in `color` with the world signs' ink outline.
local function counter(adornee: BasePart, name: string, above: number): Counter
	local gui = Instance.new("BillboardGui")
	gui.Name = name
	gui.Adornee = adornee
	gui.Size = UDim2.fromScale(11, 3.8)
	gui.StudsOffset = Vector3.new(0, above, 0)
	gui.LightInfluence = 0
	gui.MaxDistance = COUNTER_RANGE
	gui.Enabled = false
	gui.Parent = adornee
	-- Half the board at size 1, so the milestone sizes still fit inside it.
	local label = Instance.new("TextLabel")
	label.Name = "Count"
	label.BackgroundTransparency = 1
	label.AnchorPoint = Vector2.new(0.5, 0.5)
	label.Position = UDim2.fromScale(0.5, 0.5)
	label.Size = UDim2.fromScale(0.5, 0.5)
	label.Font = Theme.Fonts.Display
	label.TextScaled = true
	label.Text = ""
	label.Parent = gui
	local stroke = Instance.new("UIStroke")
	stroke.Color = INK
	stroke.Thickness = 3
	stroke.LineJoinMode = Enum.LineJoinMode.Round
	stroke.Parent = label
	local scale = Instance.new("UIScale")
	scale.Parent = label
	local token = 0

	local self = {} :: Counter
	function self.show(text: string, color: Color3, size: number)
		token += 1
		gui.Enabled = true
		label.Text = text
		label.TextColor3 = color
		label.TextTransparency = 0
		stroke.Transparency = 0
		scale.Scale = size * 0.55
		TweenService:Create(scale, TweenInfo.new(0.22, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = size }):Play()
	end
	function self.hide()
		if not gui.Enabled then
			return
		end
		token += 1
		local mine = token
		local fade = TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
		TweenService:Create(label, fade, { TextTransparency = 1 }):Play()
		TweenService:Create(stroke, fade, { Transparency = 1 }):Play()
		task.delay(0.32, function()
			if token == mine then
				gui.Enabled = false
			end
		end)
	end
	function self.destroy()
		token += 1
		gui:Destroy()
	end
	return self
end

-- A burst of stars for a milestone; decorative, so it gives way on busy or small devices.
local function starBurst(anchor: BasePart, at: Vector3, count: number)
	for i = 1, Budget.count(count) do
		if not Sprites.room() then
			return
		end
		local a = (i / count) * 2 * math.pi + math.random()
		Sprites.billboard(anchor, "StarPop", {
			position = at,
			size = 1 + math.random() * 0.5,
			rise = Vector3.new(math.cos(a) * 2.2, 1.4 + math.random() * 1.6, math.sin(a) * 2.2),
			life = 0.9,
			spin = (math.random() - 0.5) * 120,
		})
	end
end

-- Trampoline ------------------------------------------------------------------------------------

local function trampoline(model: Model): Handler?
	local anchor = marker(model, "BounceAnchor")
	if not anchor then
		return nil
	end
	local top = anchor.Position
	local radiusValue = anchor:GetAttribute("Radius")
	local radius: number = if type(radiusValue) == "number" then radiusValue else 2.9

	-- The part-built pad and the springs under it dip on a bounce (absent is fine).
	local pads: { { part: BasePart, rest: CFrame, give: number } } = {}
	for name, give in { TrampolinePad = 1, TrampolineSprings = 0.5 } :: { [string]: number } do
		local part = model:FindFirstChild(name)
		if part and part:IsA("BasePart") then
			table.insert(pads, { part = part, rest = part.CFrame, give = give })
		end
	end

	local lastBounce = -math.huge
	local bounceSpeed = 0
	local bounces = 0
	local fallSpeed = 0 -- fastest the character has fallen since it last stood on something
	local squashToken = 0
	local emitter: ParticleEmitter? = nil
	local triedEmitter = false

	local function squash()
		squashToken += 1
		local mine = squashToken
		local down = TweenInfo.new(0.06, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
		for _, pad in pads do
			if pad.part.Parent then
				TweenService:Create(pad.part, down, { CFrame = pad.rest - Vector3.new(0, PAD_SQUASH * pad.give, 0) }):Play()
			end
		end
		task.delay(0.06, function()
			if mine ~= squashToken then
				return
			end
			local back = TweenInfo.new(0.55, Enum.EasingStyle.Elastic, Enum.EasingDirection.Out)
			for _, pad in pads do
				if pad.part.Parent then
					TweenService:Create(pad.part, back, { CFrame = pad.rest }):Play()
				end
			end
		end)
	end

	local function puff()
		if not triedEmitter then
			triedEmitter = true
			emitter = Sprites.emitter(anchor, "Puff", {
				Color = ColorSequence.new(W.Cream),
				EmissionDirection = Enum.NormalId.Top,
				SpreadAngle = Vector2.new(75, 75),
				Speed = NumberRange.new(5, 9),
				Lifetime = NumberRange.new(0.35, 0.6),
				Size = NumberSequence.new({
					NumberSequenceKeypoint.new(0, 0.3),
					NumberSequenceKeypoint.new(0.3, 1.2),
					NumberSequenceKeypoint.new(1, 0),
				}),
			})
		end
		if emitter then
			emitter:Emit(Budget.count(8))
		end
	end

	-- Over the pad: within its radius and no more than a jump's start above it.
	local function over(root: BasePart): boolean
		local d = root.Position - top
		return d.X * d.X + d.Z * d.Z <= radius * radius and d.Y > 0.5 and d.Y < BOUNCE_REACH
	end

	local function launch(who: Me)
		local v = who.root.AssemblyLinearVelocity
		local x, z = Rules.drift(v.X, v.Z)
		who.humanoid:ChangeState(Enum.HumanoidStateType.Freefall)
		who.root.AssemblyLinearVelocity = Vector3.new(x, bounceSpeed, z)
	end

	local function bounce(who: Me, holding: boolean)
		local now = os.clock()
		if now - lastBounce < Rules.BOUNCE_GAP or who.humanoid.Health <= 0 or who.humanoid.SeatPart ~= nil then
			return
		end
		lastBounce = now
		local jump = jumpSpeed(who.humanoid)
		local height = Rules.bounceHeight(jump, fallSpeed, holding)
		bounceSpeed = Rules.bounceSpeed(jump, fallSpeed, holding)
		fallSpeed = 0
		launch(who)
		squash()
		puff()
		Sounds.play("Pickup", 0.05, 0.85 + 0.3 * (height - Rules.BOUNCE_BASE))
		bounces += 1
		model:SetAttribute("Bounces", bounces)
		model:SetAttribute("BounceHeight", height)
	end

	local handler: Handler = {
		destroy = function()
			squashToken += 1
			if emitter then
				emitter:Destroy()
			end
		end,
		step = function(now: number)
			local who = localChar()
			if not who then
				return
			end
			local root = who.root
			if flat(root.Position - top).Magnitude > radius + NEAR then
				fallSpeed = 0
				return
			end
			local vy = root.AssemblyLinearVelocity.Y
			-- The humanoid's landing or jump can swallow the launch on the frame it happens:
			-- give it again while the character is clearly slower than the bounce.
			local since = now - lastBounce
			if since < 0.1 and vy < bounceSpeed - Workspace.Gravity * since - 15 then
				launch(who)
				return
			end
			local grounded = who.humanoid.FloorMaterial ~= Enum.Material.Air
			if not grounded then
				fallSpeed = math.max(fallSpeed, -vy)
			elseif over(root) and vy < 1 then
				bounce(who, holdingJump(who.humanoid))
			else
				fallSpeed = 0
			end
		end,
		jumped = function(who: Me)
			if over(who.root) then
				bounce(who, true)
			end
		end,
	}
	return handler
end

-- Punch bag -------------------------------------------------------------------------------------

local function punchBag(model: Model): Handler?
	local pivot = marker(model, "BagPivot")
	local zone = marker(model, "HitZone")
	if not pivot or not zone then
		return nil
	end
	local found = zone:WaitForChild("PunchPrompt", MARKER_WAIT)
	local prompt = if found and found:IsA("ProximityPrompt") then found else nil

	-- What swings: the part-built bag about the hook it hangs from, or (bag and stand in one
	-- mesh) the whole body rocking on its base.
	local parts: { BasePart } = {}
	local rests: { CFrame } = {}
	local cframes: { CFrame } = {}
	local hinge = pivot.Position
	local gain = 1
	local tiltX, tiltZ = 0, 0 -- the swing, as a lean (radians) along world X and Z
	local speedX, speedZ = 0, 0
	local swinging = false
	local captureToken = 0

	local function settle()
		tiltX, tiltZ, speedX, speedZ = 0, 0, 0, 0
		swinging = false
		for i, part in parts do
			if part.Parent then
				part.CFrame = rests[i]
			end
		end
	end

	local function capture()
		settle()
		table.clear(parts)
		table.clear(rests)
		table.clear(cframes)
		local prop = model:FindFirstChild("Prop_PunchBag")
		if not prop then
			return
		end
		local bag: { BasePart } = {}
		local body: { BasePart } = {}
		for _, d in prop:GetDescendants() do
			if d:IsA("BasePart") and d.Name ~= "PropRoot" and d.Name ~= "PropCollider" then
				table.insert(body, d)
				if string.sub(d.Name, 1, 3) == "Bag" and string.sub(d.Name, 1, 8) ~= "BagStand" then
					table.insert(bag, d)
				end
			end
		end
		if #bag > 0 then
			parts, hinge, gain = bag, pivot.Position, 1
		else
			local base = prop:FindFirstChild("PropRoot")
			parts = body
			hinge = if base and base:IsA("BasePart")
				then base.Position
				else Vector3.new(pivot.Position.X, zone.Position.Y - zone.Size.Y / 2, pivot.Position.Z)
			gain = -MESH_ROCK
		end
		for i, part in parts do
			rests[i] = part.CFrame
		end
	end

	-- The body changed under us (its mesh arrived, a part streamed): start again from rest.
	local function recapture(d: Instance)
		if not d:IsA("BasePart") then
			return
		end
		captureToken += 1
		local mine = captureToken
		settle()
		task.delay(MODEL_DELAY, function()
			if mine == captureToken and model.Parent then
				capture()
			end
		end)
	end

	local function swing(dt: number)
		tiltX, speedX = Rules.swingStep(tiltX, speedX, dt)
		tiltZ, speedZ = Rules.swingStep(tiltZ, speedZ, dt)
		local angle = math.sqrt(tiltX * tiltX + tiltZ * tiltZ)
		if angle > Rules.SWING_MAX then
			local k = Rules.SWING_MAX / angle
			tiltX, tiltZ, angle = tiltX * k, tiltZ * k, Rules.SWING_MAX
		end
		if Rules.swingStill(tiltX, speedX) and Rules.swingStill(tiltZ, speedZ) then
			settle()
			return
		end
		-- Leaning toward (tiltX, tiltZ) is a turn about the level axis across it.
		local turn = if angle > 1e-5
			then CFrame.fromAxisAngle(Vector3.new(-tiltZ, 0, tiltX) * gain, angle * math.abs(gain))
			else CFrame.identity
		local frame = CFrame.new(hinge) * turn * CFrame.new(-hinge)
		local n = 0
		for i, part in parts do
			if part.Parent then
				n += 1
				cframes[i] = frame * rests[i]
			end
		end
		if n == #parts and n > 0 then
			Workspace:BulkMoveTo(parts, cframes, Enum.BulkMoveMode.FireCFrameChanged)
		end
	end

	local combo = 0
	local hits = 0
	local lastHit: number? = nil
	local inside = false
	local board = counter(pivot, "ComboCounter", 2.4)

	local function hit(who: Me, viaPrompt: boolean)
		local now = os.clock()
		if not Rules.canHit(lastHit, now) or who.humanoid.Health <= 0 or who.humanoid.SeatPart ~= nil then
			return
		end
		local away = flat(zone.Position - who.root.Position)
		away = if away.Magnitude > 0.05 then away.Unit else flat(who.root.CFrame.LookVector).Unit
		combo = Rules.combo(combo, lastHit, now)
		lastHit = now
		hits += 1
		local kick = Rules.kick(combo)
		speedX += away.X * kick
		speedZ += away.Z * kick
		swinging = true

		throwPunch(who, if viaPrompt then away else nil)
		local big = Rules.milestone(combo)
		board.show("x" .. combo, if big then W.Sunny else W.White, Rules.comboScale(combo))
		Sounds.play("Deposit", 0.06, 0.9 + 0.4 * math.clamp((combo - 1) / 24, 0, 1))
		if big then
			Sounds.play("Step")
			starBurst(pivot, pivot.Position + Vector3.new(0, 2.4, 0), 8)
		end
		model:SetAttribute("Hits", hits)
		model:SetAttribute("Combo", combo)
	end

	local conns: { RBXScriptConnection } = {}
	if prompt then
		table.insert(
			conns,
			prompt.Triggered:Connect(function(who: Player)
				local mine = localChar()
				if who == player and mine then
					hit(mine, true)
				end
			end)
		)
	end
	table.insert(conns, model.DescendantAdded:Connect(recapture))
	table.insert(conns, model.DescendantRemoving:Connect(recapture))
	capture()

	local handler: Handler = {
		destroy = function()
			captureToken += 1
			for _, conn in conns do
				conn:Disconnect()
			end
			settle()
			board.destroy()
		end,
		step = function(now: number, dt: number)
			if swinging then
				swing(dt)
			end
			if combo > 0 and not Rules.comboAlive(lastHit, now) then
				combo = 0
				board.hide()
				model:SetAttribute("Combo", 0)
			end
			local who = localChar()
			if not who or flat(who.root.Position - zone.Position).Magnitude > NEAR then
				inside = false
				return
			end
			-- Running into the bag: a hit on the way in, and again while pushing on into it.
			local p = zone.CFrame:PointToObjectSpace(who.root.Position)
			local half = zone.Size / 2
			local nowInside = math.abs(p.X) <= half.X + 0.5 and math.abs(p.Z) <= half.Z + 0.5 and math.abs(p.Y) <= half.Y + 3
			if nowInside then
				local toward = flat(zone.Position - who.root.Position)
				local pushing = toward.Magnitude > 0.05 and who.humanoid.MoveDirection:Dot(toward.Unit) > 0.3
				if not inside or (pushing and now - (lastHit or -math.huge) >= WALK_GAP) then
					hit(who, false)
				end
			end
			inside = nowInside
		end,
	}
	return handler
end

-- Bench press -----------------------------------------------------------------------------------

type Lift = {
	humanoid: Humanoid,
	character: Model?,
	mine: boolean,
	startedAt: number,
	reps: number,
	bar: Model,
	barParts: { BasePart },
	barOffsets: { CFrame },
}

local function barPart(parent: Instance, name: string, length: number, diameter: number, tint: Color3): BasePart
	local p = Instance.new("Part")
	p.Name = name
	p.Shape = Enum.PartType.Cylinder
	p.Size = Vector3.new(length, diameter, diameter)
	p.Color = tint
	p.Material = Enum.Material.SmoothPlastic
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.Parent = parent
	return p
end

-- The barbell a lifter presses: a chrome bar along X with sunny plates outside the hands.
local function buildBar(parent: Instance): (Model, { BasePart }, { CFrame })
	local bar = Instance.new("Model")
	bar.Name = "RepBarbell"
	local parts: { BasePart } = { barPart(bar, "RepBar", 8, 0.3, W.Chrome) }
	local offsets: { CFrame } = { CFrame.identity }
	for _, side in { -1, 1 } do
		for _, piece in
			{
				{ name = "RepPlate", x = 3.25, length = 0.4, diameter = 2.1, tint = W.Sunny },
				{ name = "RepPlate", x = 3.62, length = 0.32, diameter = 1.5, tint = W.Sunny:Lerp(W.White, 0.35) },
				{ name = "RepCollar", x = 3.88, length = 0.2, diameter = 0.55, tint = W.Chrome },
			}
		do
			table.insert(parts, barPart(bar, piece.name, piece.length, piece.diameter, piece.tint))
			table.insert(offsets, CFrame.new(side * piece.x, 0, 0))
		end
	end
	bar.Parent = parent
	return bar, parts, offsets
end

local function bench(model: Model): Handler?
	local seatPart = marker(model, "BenchSeat")
	local standSpot = marker(model, "StandSpot")
	local liftAnchor = marker(model, "LiftAnchor")
	if not seatPart or not seatPart:IsA("Seat") or not standSpot or not liftAnchor then
		return nil
	end
	local seat: Seat = seatPart
	local found = liftAnchor:WaitForChild("LiftPrompt", MARKER_WAIT)
	local prompt = if found and found:IsA("ProximityPrompt") then found else nil
	local board = counter(liftAnchor, "RepCounter", 4.2)

	local lift: Lift? = nil
	local armed = false -- the local lifter has let go of the stick since lying down
	local leavingAt = -math.huge
	local standBy: number? = nil -- the local lifter gets up once the seat has let go, until then

	-- The barbell resting in the rack hides while somebody presses theirs.
	local function showRack(shown: boolean)
		local rack = model:FindFirstChild("Prop_Barbell")
		if rack then
			for _, d in rack:GetDescendants() do
				if d:IsA("BasePart") then
					d.LocalTransparencyModifier = if shown then 0 else 1
				end
			end
		end
	end

	local function finish()
		local current = lift
		if not current then
			return
		end
		lift = nil
		local rig = if current.character then rigs[current.character] else nil
		if rig and rig.rig then
			restRig(rig.rig, Poses.LIMBS)
		end
		current.bar:Destroy()
		showRack(true)
		board.hide()
		model:SetAttribute("Lifting", nil)
		if current.mine then
			standBy = os.clock() + STAND_WAIT
		end
	end

	local function start(humanoid: Humanoid)
		local character = humanoid.Parent
		local bar, barParts, barOffsets = buildBar(model)
		local now = os.clock()
		local current: Lift = {
			humanoid = humanoid,
			character = if character and character:IsA("Model") then character else nil,
			mine = character ~= nil and character == player.Character,
			startedAt = now,
			reps = 0,
			bar = bar,
			barParts = barParts,
			barOffsets = barOffsets,
		}
		lift = current
		showRack(false)
		board.show("0 REPS", W.White, 1)
		model:SetAttribute("Lifting", if character then character.Name else humanoid.Name)
		model:SetAttribute("Reps", 0)
		if current.mine then
			armed = false
			leavingAt = -math.huge
			standBy = nil
		end
	end

	local function refresh()
		local who = seat.Occupant
		local current = lift
		if current and current.humanoid ~= who then
			finish()
		end
		if who and not lift then
			start(who)
		end
		if prompt then
			local mine = lift ~= nil and lift.mine
			prompt.ActionText = if mine then "Stop" else "Lift"
			prompt.Enabled = mine or who == nil
		end
	end

	-- Asks the seat to let the local lifter go; jumping is the fallback that always works.
	local function leave(who: Me, now: number)
		if now - leavingAt < 0.4 then
			return
		end
		if leavingAt > -math.huge then
			who.humanoid.Jump = true
		end
		leavingAt = now
		who.humanoid.Sit = false
	end

	-- Stands the local lifter up beside the bench (never after the server has moved them away).
	local function standUp(who: Me)
		if who.humanoid.Health <= 0 or (who.root.Position - seat.Position).Magnitude > 6 then
			return
		end
		local hip = if who.humanoid.RigType == Enum.HumanoidRigType.R15 then who.humanoid.HipHeight else 2
		local at = standSpot.Position + Vector3.new(0, hip + who.root.Size.Y / 2 + 0.1, 0)
		local look = flat(standSpot.CFrame.LookVector)
		who.root.CFrame = CFrame.lookAt(at, at + (if look.Magnitude > 0.1 then look.Unit else Vector3.new(0, 0, -1)))
		who.root.AssemblyLinearVelocity = Vector3.zero
		who.root.AssemblyAngularVelocity = Vector3.zero
		who.humanoid:ChangeState(Enum.HumanoidStateType.GettingUp)
	end

	local conns: { RBXScriptConnection } = {
		seat:GetPropertyChangedSignal("Occupant"):Connect(refresh),
	}
	if prompt then
		table.insert(
			conns,
			prompt.Triggered:Connect(function(who: Player)
				-- The server seats a new lifter and lets its own one go; this only hurries the "Stop".
				local mine = localChar()
				if who == player and mine and lift and lift.mine then
					leave(mine, os.clock())
				end
			end)
		)
	end
	refresh()

	local handler: Handler = {
		destroy = function()
			for _, conn in conns do
				conn:Disconnect()
			end
			finish()
			standBy = nil
			board.destroy()
		end,
		step = function(now: number)
			local who = localChar()
			local deadline = standBy
			if deadline then
				if not who or now > deadline then
					standBy = nil
				elseif who.humanoid.SeatPart == nil and seat:FindFirstChild("SeatWeld") == nil then
					standBy = nil
					standUp(who)
				end
			end
			local current = lift
			if not current then
				return
			end
			-- A lifter who is gone, dead or no longer on this seat (a missed signal) is done.
			if seat.Occupant ~= current.humanoid or current.humanoid.Health <= 0 or current.humanoid.Parent == nil then
				refresh()
				current = lift
				if not current then
					return
				end
			end
			local t = now - current.startedAt
			if current.mine and who then
				-- Moving ends the lift, once the stick has been let go after lying down.
				local moving = who.humanoid.MoveDirection.Magnitude
				if not armed then
					armed = moving < 0.1 and t > 0.3
				elseif moving > 0.3 then
					leave(who, now)
				end
			end

			-- The bar rides between the hands; without hands (R6) it moves over the chest.
			local character = current.character
			local left = character and character:FindFirstChild("LeftHand")
			local right = character and character:FindFirstChild("RightHand")
			local frame = seat.CFrame
			local centre
			if left and right and left:IsA("BasePart") and right:IsA("BasePart") then
				centre = (left.Position + right.Position) / 2
			else
				centre = frame * Vector3.new(0, 0.4, -(1 + 1.2 * Rules.press(t)))
			end
			local base = CFrame.fromMatrix(centre, frame.RightVector, frame.UpVector)
			for i, part in current.barParts do
				part.CFrame = base * current.barOffsets[i]
			end

			local reps = Rules.reps(t)
			if reps ~= current.reps then
				current.reps = reps
				board.show(reps .. (if reps == 1 then " REP" else " REPS"), if reps % 10 == 0 then W.Sunny else W.White, 1)
				model:SetAttribute("Reps", reps)
				if current.mine then
					Sounds.play("Tick", 0.04)
					if reps % 10 == 0 then
						Sounds.play("Step")
						starBurst(liftAnchor, liftAnchor.Position + Vector3.new(0, 4.2, 0), 6)
					end
				end
			end
		end,
		pose = function(now: number)
			local current = lift
			local character = current and current.character
			if not current or not character then
				return
			end
			local rig = rigFor(character, now)
			if rig then
				local t = now - current.startedAt
				poseRig(rig, POSE.BenchDown, POSE.BenchUp, Rules.press(t), math.min(1, t / BLEND_IN), Poses.LIMBS)
			end
		end,
	}
	return handler
end

-- Models -----------------------------------------------------------------------------------------

local BUILDERS: { [string]: (Model) -> Handler? } = {
	trampoline = trampoline,
	punchbag = punchBag,
	bench = bench,
}

-- Sets `model` up (this waits for its marker parts, so it runs in its own thread).
local function setup(model: Model)
	pending[model] = nil
	local kind = model:GetAttribute("Interactive")
	local build = if type(kind) == "string" then BUILDERS[kind] else nil
	if not build or live[model] or not model:IsDescendantOf(Workspace) then
		return
	end
	local ok, result = pcall(build, model)
	if not ok then
		warn("[Fx.Interactive] " .. model.Name .. " failed: " .. tostring(result))
		return
	end
	local handler = result :: Handler?
	if not handler then
		return
	end
	if live[model] or not model:IsDescendantOf(Workspace) then
		handler.destroy()
		return
	end
	live[model] = handler
end

local function consider(instance: Instance)
	if instance:IsA("Model") and instance:GetAttribute("Interactive") ~= nil and not live[instance] and not pending[instance] then
		pending[instance] = true
		-- Give the model's parts a moment to arrive (building / streaming).
		task.delay(MODEL_DELAY, setup, instance)
	end
end

local function onRemoving(instance: Instance)
	pending[instance] = nil
	local handler = live[instance]
	if handler then
		live[instance] = nil
		handler.destroy()
	end
end

-- One warning per prop: a broken one must not flood the output every frame.
local warned: { [string]: boolean } = {}
local function report(name: string, err: any)
	if not warned[name] then
		warned[name] = true
		warn("[Fx.Interactive] " .. name .. ": " .. tostring(err))
	end
end

function Interactive.init()
	if started then
		return
	end
	started = true
	for _, name in { "PunchGuard", "PunchRight", "PunchLeft", "BenchUp", "BenchDown" } do
		POSE[name] = Poses.samplePose("Story", name, 0, 0)
	end

	UserInputService.JumpRequest:Connect(function()
		lastJumpRequest = os.clock()
	end)
	-- A new character starts clean: its connections go with the old one.
	player.CharacterRemoving:Connect(function()
		dropMe()
		punchAt = -math.huge
		punchRig = nil
	end)
	RunService.Heartbeat:Connect(function(dt: number)
		local now = os.clock()
		for instance, handler in live do
			if handler.step then
				local ok, err = pcall(handler.step :: any, now, dt)
				if not ok then
					report(instance.Name, err)
				end
			end
		end
	end)
	-- After the avatars' own animations, like Fx.PlayerPose.
	RunService.PreSimulation:Connect(function()
		local now = os.clock()
		local ok, err = pcall(posePunch :: any, now)
		if not ok then
			report("punch", err)
		end
		for instance, handler in live do
			if handler.pose then
				ok, err = pcall(handler.pose :: any, now)
				if not ok then
					report(instance.Name, err)
				end
			end
		end
	end)

	task.spawn(function()
		local map = Workspace:WaitForChild("Map", 60)
		if not map then
			return
		end
		map.DescendantAdded:Connect(consider)
		map.DescendantRemoving:Connect(onRemoving)
		for _, d in map:GetDescendants() do
			consider(d)
		end
	end)
end

return Interactive
