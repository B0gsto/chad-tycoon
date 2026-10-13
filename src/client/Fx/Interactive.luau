--!strict
--[[
	Fx.Interactive: brings the interactive gym props on every plot to life (World.Decor builds
	them as Interactive_<Kind> models under Workspace.Map, with attribute Interactive and the
	invisible marker parts named below). Cosmetic fun only, nothing touches the economy; the one
	thing the server takes part in is the bench press (who lies on it and their rep count).

	  trampoline  Standing or landing on the bounce pad ("BounceAnchor", attribute Radius)
	              launches the local character 3-4 jumps high (InteractiveRules: higher out
	              of a bounce and while jump is held), almost straight up. The pad squashes
	              and springs back, with a puff and a pop.
	  punchbag    A jump press (Space, gamepad A, the mobile jump button) within Reach studs of
	              the bag's "HitZone", the "PunchPrompt" (tap / Space / gamepad X) or simply
	              running into the bag is a hit, at most 4 a second: the bag swings away from
	              the player and settles like a damped pendulum, the local avatar throws a
	              quick punch (alternating fists) and a combo counter pops over the bag. At the
	              bag the avatar does not hop: jump is a punch there. A part-built bag hangs
	              from "BagPivot"; the one-piece Blender mesh (bag and stand in one) rocks on
	              its base instead, more gently.
	  bench       The "LiftPrompt" (E) lies the player down at "BenchSeat": the server anchors
	              their root there and sets the model's attributes Lifter (UserId) and Reps.
	              Every client poses that player in a bench press and gives them a barbell.
	              The lifter spams jump: each press is one rep, a quick down-and-up of the bar
	              (presses during a rep wait behind it and speed the reps up), played at once and sent to the server
	              (action BenchRep), which counts it in Reps for everybody else to play. The
	              bar moves on the rep itself, through the place the pose puts the hands, so
	              it moves even on an avatar that cannot be posed. Moving (action BenchStop)
	              or the prompt (now "Stop") ends it, and the server stands the lifter up on
	              "StandSpot" beside the bench.

	Jump presses come from UserInputService.JumpRequest, which fires every frame while jump is
	held: only its rising edge counts (InteractiveRules.newPress), and so does Space or gamepad
	A going down, so that mashing faster than that edge can tell still counts. A prop that takes jump for
	itself switches the local humanoid's Jumping state off through holdStates, which counts its
	holders, so the bag and the bench never switch it back on under one another. Not on touch:
	Roblox hides the jump button of a humanoid that cannot jump, so there the state stays on
	(a lifter is anchored and cannot hop anyway; at the bag a touch player hops with the punch).

	Avatars are posed like Fx.PlayerPose does it: joint transforms (of the Motor6Ds, or of the
	AnimationConstraints an avatar with upgraded joints has instead) overridden after the
	avatar's own animations have run, from the gym poses in Shared.Poses (R15 only; an R6
	avatar still bounces, hits and lifts, just without the pose).

	Each client writes what it plays onto the Interactive_ model (local attributes, for
	playtests): trampoline Bounces, BounceHeight (in jumps); punchbag Hits, Combo; bench
	Lifting (the lifter's name, or nil), RepsPlayed (reps this client has animated) and
	BarTravel (studs the bar moves in a rep).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Rules = require(Shared:WaitForChild("InteractiveRules"))
local Net = require(Shared:WaitForChild("Net"))
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
local PUNCH_REACH = 2.5 -- studs round the HitZone from which jump punches (its attribute Reach)
local BLEND_IN = 0.25 -- seconds for a lifter to settle into the bench press
local STAND_TIME = 0.5 -- seconds a lifter needs to get up, before jump is theirs again
local STOP_GAP = 0.4 -- seconds between two asks to stop lifting
local BAR_TRAVEL = 1.2 -- studs the bar moves over the chest of an avatar that cannot be posed
local SAME_PRESS = 0.05 -- seconds within which JumpRequest and the key going down are one press
local MIN_TRAVEL = 1 -- studs the bar moves in a rep at the least, however short the arms

local UPPER_BODY = { "UpperTorso", "Head", "LeftUpperArm", "LeftLowerArm", "LeftHand", "RightUpperArm", "RightLowerArm", "RightHand" }

-- The local character ------------------------------------------------------------------------

-- A limb's joint to its parent limb: the Motor6D, or on an avatar with upgraded joints the
-- AnimationConstraint between two rig attachments that stands in for it (C0 = Attachment0,
-- C1 = Attachment1). Both are animated, and posed, through their Transform.
type Joint = { motor: Motor6D | AnimationConstraint, c0: CFrame, c1: CFrame, rot: CFrame, rotInv: CFrame }
type Rig = { joints: { [string]: Joint }, scale: number }
type Me = { model: Model, humanoid: Humanoid, root: BasePart }

type Handler = {
	destroy: () -> (),
	step: ((now: number, dt: number) -> ())?,
	pose: ((now: number) -> ())?,
	jumped: ((me: Me) -> ())?,
	pressed: ((now: number) -> ())?, -- a new jump press (not a held one)
}

local live: { [Instance]: Handler } = {}
local pending: { [Instance]: boolean } = {}
local me: Me? = nil
local meConns: { RBXScriptConnection } = {}
local lastJumpRequest: number? = nil
local actionRemote: RemoteEvent? = nil
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
	return humanoid.Jump or os.clock() - (lastJumpRequest or -math.huge) < 0.2
end

-- The device in the player's hands, going by what they touched last.
local function inputKind(): "keyboard" | "gamepad" | "touch"
	local last = UserInputService:GetLastInputType()
	if string.sub(last.Name, 1, 7) == "Gamepad" then
		return "gamepad"
	elseif last == Enum.UserInputType.Touch or (UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled) then
		return "touch"
	end
	return "keyboard"
end

-- Humanoid states switched off on the local character, by how many props hold each one.
local stateHolds: { [Enum.HumanoidStateType]: number } = {}
local stateOff: { [Enum.HumanoidStateType]: Humanoid } = {}

-- Brings the local humanoid in line with the holds (every frame): also after a respawn, and
-- the old character gets its states back. On touch Jumping stays on: Roblox hides the jump
-- button of a humanoid that cannot jump, and that button is how a touch player presses jump.
local function syncStates()
	local who = localChar()
	local touch = inputKind() == "touch"
	for state, holds in stateHolds do
		local off = holds > 0 and not (touch and state == Enum.HumanoidStateType.Jumping)
		local want = if off and who then who.humanoid else nil
		local had = stateOff[state]
		if had ~= want then
			if had and had.Parent then
				had:SetStateEnabled(state, true)
			end
			stateOff[state] = want :: Humanoid
			if want then
				want:SetStateEnabled(state, false)
			end
		end
	end
end

-- Switches `states` off on the local humanoid until the returned function is called (calling
-- it again does nothing). Holds are counted: a state comes back on with its last holder.
local function holdStates(states: { Enum.HumanoidStateType }): () -> ()
	for _, state in states do
		stateHolds[state] = (stateHolds[state] or 0) + 1
	end
	syncStates()
	local held = true
	return function()
		if held then
			held = false
			for _, state in states do
				stateHolds[state] -= 1
			end
			syncStates()
		end
	end
end

local JUMP = { Enum.HumanoidStateType.Jumping }
-- A lifter lies flat with an anchored root: the humanoid must not take that for a fall.
local LYING = { Enum.HumanoidStateType.Jumping, Enum.HumanoidStateType.FallingDown, Enum.HumanoidStateType.Ragdoll }

-- What spamming jump is called on that device.
local JUMP_HINT = { keyboard = "SPAM SPACE", gamepad = "PRESS A", touch = "TAP JUMP" }

local function send(action: string)
	if actionRemote then
		actionRemote:FireServer({ action = action })
	end
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
	local function add(motor: Motor6D | AnimationConstraint, limb: string, c0: CFrame, c1: CFrame)
		if not joints[limb] and table.find(Poses.LIMBS, limb) then
			local rot = c0.Rotation
			joints[limb] = { motor = motor, c0 = c0, c1 = c1, rot = rot, rotInv = rot:Inverse() }
		end
	end
	for _, d in character:GetDescendants() do
		if d:IsA("Motor6D") then
			if d.Part1 then
				add(d, d.Part1.Name, d.C0, d.C1)
			end
		elseif d:IsA("AnimationConstraint") then
			local a0, a1 = d.Attachment0, d.Attachment1
			local limb = a1 and a1.Parent
			if a0 and a1 and limb and limb:IsA("BasePart") then
				add(d, limb.Name, a0.CFrame, a1.CFrame)
			end
		end
	end
	if not joints.LowerTorso or not joints.UpperTorso then
		return nil
	end
	return { joints = joints, scale = character:GetScale() }
end

-- The R15 joints of `character` (Motor6Ds or AnimationConstraints), looked up again (at most once a second) when the avatar was
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

-- The Motor6D transform that puts `limb` in pose transform `cf`.
local function jointTransform(rig: Rig, joint: Joint, limb: string, cf: CFrame): CFrame
	local transform = joint.rotInv * cf.Rotation * joint.rot
	if limb == "LowerTorso" then
		transform = CFrame.new(joint.rotInv * Vector3.new(0, cf.Y * rig.scale, 0)) * transform
	end
	return transform
end

-- Poses `limbs` part way (alpha) from pose `a` to pose `b`, mixed over the avatar's own
-- animation by `weight`. Call from PreSimulation, after the animations have run.
local function poseRig(rig: Rig, a: { [string]: CFrame }, b: { [string]: CFrame }, alpha: number, weight: number, limbs: { string })
	for _, limb in limbs do
		local joint = rig.joints[limb]
		if not joint or not joint.motor.Parent then
			continue
		end
		local transform = jointTransform(rig, joint, limb, a[limb]:Lerp(b[limb], alpha))
		-- Both joint classes have Transform; the union hides it from the type checker.
		local motor = joint.motor :: any
		motor.Transform = if weight >= 1 then transform else motor.Transform:Lerp(transform, weight)
	end
end

local ARM = { "LowerTorso", "UpperTorso", "UpperArm", "LowerArm", "Hand" }

-- Where poseRig(rig, a, b, alpha, 1) puts the middle between the two hands, in the root's
-- frame: worked out from the joints and the pose alone, so it holds whether or not the pose
-- shows on the avatar. Nil when an arm is incomplete.
local function handsCentre(rig: Rig, a: { [string]: CFrame }, b: { [string]: CFrame }, alpha: number): Vector3?
	local sum = Vector3.zero
	for _, side in { "Left", "Right" } do
		local frame = CFrame.identity
		for i, name in ARM do
			local limb = if i > 2 then side .. name else name
			local joint = rig.joints[limb]
			if not joint or not joint.motor.Parent then
				return nil
			end
			frame = frame * joint.c0 * jointTransform(rig, joint, limb, a[limb]:Lerp(b[limb], alpha)) * joint.c1:Inverse()
		end
		sum += frame.Position
	end
	return sum / 2
end

-- Hands `limbs` back to the avatar's own animations.
local function restRig(rig: Rig, limbs: { string })
	for _, limb in limbs do
		local joint = rig.joints[limb]
		if joint and joint.motor.Parent then
			(joint.motor :: any).Transform = CFrame.identity
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
	if toward and who.humanoid.MoveDirection.Magnitude < 0.1 and who.humanoid.SeatPart == nil and not who.root.Anchored then
		local at = who.root.Position
		who.root.CFrame = CFrame.lookAt(at, at + toward)
	end
end

local function posePunch(now: number)
	local t = now - punchAt
	local who = if t < Rules.PUNCH_TIME then localChar() else nil
	local rig = if who and who.humanoid.SeatPart == nil and not who.root.Anchored then rigFor(who.model, now) else nil
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
	hint: (text: string) -> (),
	hide: () -> (),
	destroy: () -> (),
}

-- A number that pops over a prop: Display type in `color` with the world signs' ink outline,
-- and under it a small second line (hint; empty until set).
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
	local hint = Instance.new("TextLabel")
	hint.Name = "Hint"
	hint.BackgroundTransparency = 1
	hint.AnchorPoint = Vector2.new(0.5, 0)
	hint.Position = UDim2.fromScale(0.5, 0.79)
	hint.Size = UDim2.fromScale(0.6, 0.19)
	hint.Font = Theme.Fonts.Display
	hint.TextScaled = true
	hint.TextColor3 = W.Cream
	hint.Text = ""
	hint.Parent = gui
	local hintStroke = stroke:Clone()
	hintStroke.Thickness = 2
	hintStroke.Parent = hint
	local token = 0

	local self = {} :: Counter
	function self.show(text: string, color: Color3, size: number)
		token += 1
		gui.Enabled = true
		label.Text = text
		label.TextColor3 = color
		label.TextTransparency = 0
		stroke.Transparency = 0
		hint.TextTransparency = 0
		hintStroke.Transparency = 0
		scale.Scale = size * 0.55
		TweenService:Create(scale, TweenInfo.new(0.22, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = size }):Play()
	end
	function self.hint(text: string)
		hint.Text = text
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
		TweenService:Create(hint, fade, { TextTransparency = 1 }):Play()
		TweenService:Create(hintStroke, fade, { Transparency = 1 }):Play()
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
	local reachValue = zone:GetAttribute("Reach")
	local reach: number = if type(reachValue) == "number" then reachValue else PUNCH_REACH

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
	local atBag: (() -> ())? = nil -- set while the local character is in reach: gives jump back
	local board = counter(pivot, "ComboCounter", 2.4)

	-- Within `grow` studs of the zone (and no more than a jump above it).
	local function within(who: Me, grow: number): boolean
		local p = zone.CFrame:PointToObjectSpace(who.root.Position)
		local half = zone.Size / 2
		return math.abs(p.X) <= half.X + grow and math.abs(p.Z) <= half.Z + grow and math.abs(p.Y) <= half.Y + 3
	end

	-- In reach of the bag jump is a punch, so the avatar must not hop: Jumping is held off
	-- from the frame the character comes in reach to the frame it leaves, dies or is gone.
	local function reaching(who: Me?): boolean
		local can = who ~= nil and who.humanoid.Health > 0 and within(who, reach)
		if can and not atBag then
			atBag = holdStates(JUMP)
		elseif not can and atBag then
			atBag()
			atBag = nil
		end
		return can
	end

	-- `aimed` hits (the prompt, a jump press) turn a standing avatar to face the bag.
	local function hit(who: Me, aimed: boolean)
		local now = os.clock()
		-- An anchored root lies on the bench press: its presses are reps.
		if not Rules.canHit(lastHit, now) or who.humanoid.Health <= 0 or who.humanoid.SeatPart ~= nil or who.root.Anchored then
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

		throwPunch(who, if aimed then away else nil)
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
			reaching(nil)
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
				reaching(nil)
				return
			end
			reaching(who)
			-- Running into the bag: a hit on the way in, and again while pushing on into it.
			local nowInside = within(who, 0.5)
			if nowInside then
				local toward = flat(zone.Position - who.root.Position)
				local pushing = toward.Magnitude > 0.05 and who.humanoid.MoveDirection:Dot(toward.Unit) > 0.3
				if not inside or (pushing and now - (lastHit or -math.huge) >= WALK_GAP) then
					hit(who, false)
				end
			end
			inside = nowInside
		end,
		-- One press can come in twice, as the prompt (Space) and as a jump: HIT_GAP keeps it one hit.
		pressed = function()
			local who = localChar()
			if who and reaching(who) then
				hit(who, true)
			end
		end,
	}
	return handler
end

-- Bench press -----------------------------------------------------------------------------------

type Lift = {
	userId: number,
	mine: boolean,
	startedAt: number,
	repAt: number?, -- when the rep being played started, nil while the bar rests (Rules.repStep)
	repTime: number, -- seconds the rep being played takes (Rules.repTime)
	queued: number, -- presses waiting behind it
	played: number, -- reps this client has started for the lifter
	seen: number, -- of the server's Reps, how many this client has turned into reps
	shown: number, -- the count on the board
	rig: Rig?, -- the lifter's joints, once posed
	boost: number, -- studs the bar goes beyond the hands at the top, for arms too short for MIN_TRAVEL
	boostRig: Rig?,
	bar: Model,
	barParts: { BasePart },
	barOffsets: { CFrame },
	armed: boolean, -- the local lifter has let go of the stick since lying down
	stopAt: number,
	release: (() -> ())?, -- the local lifter's hold on jumping
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
	local lieSpot = marker(model, "BenchSeat")
	local liftAnchor = marker(model, "LiftAnchor")
	if not lieSpot or not liftAnchor then
		return nil
	end
	local found = liftAnchor:WaitForChild("LiftPrompt", MARKER_WAIT)
	local prompt = if found and found:IsA("ProximityPrompt") then found else nil
	local board = counter(liftAnchor, "RepCounter", 4.2)

	local lift: Lift? = nil

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
		if current.rig then
			restRig(current.rig, Poses.LIMBS)
		end
		current.bar:Destroy()
		showRack(true)
		board.hide()
		model:SetAttribute("Lifting", nil)
		-- The server stands the lifter up; jump is theirs again once they are on their feet.
		if current.release then
			task.delay(STAND_TIME, current.release)
		end
	end

	local function start(userId: number)
		local who = Players:GetPlayerByUserId(userId)
		local bar, barParts, barOffsets = buildBar(model)
		local mine = userId == player.UserId
		local reps = model:GetAttribute("Reps")
		local seen: number = if type(reps) == "number" then reps else 0
		lift = {
			userId = userId,
			mine = mine,
			startedAt = os.clock(),
			repAt = nil,
			repTime = Rules.REP_TIME,
			queued = 0,
			played = 0,
			-- Joining a lift under way: its earlier reps are only counted, not replayed.
			seen = seen,
			shown = seen,
			rig = nil,
			boost = 0,
			boostRig = nil,
			bar = bar,
			barParts = barParts,
			barOffsets = barOffsets,
			armed = false,
			stopAt = -math.huge,
			release = if mine then holdStates(LYING) else nil,
		}
		showRack(false)
		board.hint(if mine then JUMP_HINT[inputKind()] else "")
		board.show(seen .. (if seen == 1 then " REP" else " REPS"), W.White, 1)
		model:SetAttribute("Lifting", if who then who.Name else tostring(userId))
		model:SetAttribute("RepsPlayed", 0)
	end

	local function refresh()
		local value = model:GetAttribute("Lifter")
		local userId: number? = if type(value) == "number" then value else nil
		local current = lift
		if current and current.userId ~= userId then
			finish()
		end
		if userId and not lift then
			start(userId)
		end
		if prompt then
			local mine = lift ~= nil and lift.mine
			prompt.ActionText = if mine then "Stop" else "Lift"
			prompt.Enabled = mine or userId == nil
		end
	end

	-- Moves the lifter's rep queue on: `pressed` is the local lifter's jump press, or a rep
	-- the server counted for somebody else's lifter.
	local function advance(current: Lift, now: number, pressed: boolean)
		local began
		current.repAt, current.repTime, current.queued, began = Rules.repStep(current.repAt, current.repTime, current.queued, now, pressed)
		if began then
			current.played += 1
			model:SetAttribute("RepsPlayed", current.played)
			if current.mine then
				send("BenchRep")
			end
		end
	end

	local conns: { RBXScriptConnection } = {
		model:GetAttributeChangedSignal("Lifter"):Connect(refresh),
	}
	refresh()

	local handler: Handler = {
		destroy = function()
			for _, conn in conns do
				conn:Disconnect()
			end
			local current = lift
			finish()
			-- No standing up to wait for: the bench itself is gone.
			if current and current.release then
				current.release()
			end
			board.destroy()
		end,
		step = function(now: number)
			local current = lift
			if not current then
				return
			end
			local counted = model:GetAttribute("Reps")
			local reps: number = if type(counted) == "number" then counted else 0
			if current.mine then
				-- The local lifter's reps were played on the press: the server's count only
				-- confirms them. Moving ends the lift, once the stick has been let go after
				-- lying down.
				local who = localChar()
				local moving = if who then who.humanoid.MoveDirection.Magnitude else 0
				if not current.armed then
					current.armed = moving < 0.1 and now - current.startedAt > 0.3
				elseif moving > 0.3 and now - current.stopAt >= STOP_GAP then
					current.stopAt = now
					send("BenchStop")
				end
				advance(current, now, false)
				-- Presses still waiting for their rep count at once: every press shows.
				reps = math.max(reps, current.played + current.queued)
			else
				-- Somebody else's reps play as the server counts them; a burst too long to
				-- queue is only counted.
				local pressed = reps > current.seen
				if pressed then
					current.seen = if reps - current.seen > Rules.REP_QUEUE then reps - 1 else current.seen + 1
				end
				advance(current, now, pressed)
			end

			-- The bar moves on the rep, through the middle between the posed hands (worked
			-- out from the pose, not read off the avatar, so it moves whatever the avatar
			-- shows); over the chest of an avatar that cannot be posed.
			local out = Rules.press(if current.repAt then now - current.repAt else 0, current.repTime)
			local frame = lieSpot.CFrame
			local rig = current.rig
			if rig and current.boostRig ~= rig then
				current.boostRig = rig
				local top = handsCentre(rig, POSE.BenchDown, POSE.BenchUp, 1)
				local bottom = handsCentre(rig, POSE.BenchDown, POSE.BenchUp, 0)
				-- The root's front (-Z) faces the sky.
				local travel = if top and bottom then bottom.Z - top.Z else MIN_TRAVEL
				current.boost = math.max(0, MIN_TRAVEL - travel)
				model:SetAttribute("BarTravel", travel + current.boost)
			end
			local hands = if rig then handsCentre(rig, POSE.BenchDown, POSE.BenchUp, out) else nil
			local centre = if hands
				then frame * (hands - Vector3.new(0, 0, current.boost * out))
				else frame * Vector3.new(0, 0.4, -(1 + BAR_TRAVEL * out))
			if not hands and model:GetAttribute("BarTravel") ~= BAR_TRAVEL then
				model:SetAttribute("BarTravel", BAR_TRAVEL)
			end
			local base = CFrame.fromMatrix(centre, frame.RightVector, frame.UpVector)
			for i, part in current.barParts do
				part.CFrame = base * current.barOffsets[i]
			end

			if reps ~= current.shown then
				current.shown = reps
				local big = reps > 0 and reps % 10 == 0
				if current.mine then
					board.hint(JUMP_HINT[inputKind()])
				end
				board.show(reps .. (if reps == 1 then " REP" else " REPS"), if big then W.Sunny else W.White, 1)
				if current.mine then
					Sounds.play("Tick", 0.04)
					if big then
						Sounds.play("Step")
						starBurst(liftAnchor, liftAnchor.Position + Vector3.new(0, 4.2, 0), 6)
					end
				end
			end
		end,
		pose = function(now: number)
			local current = lift
			if not current then
				return
			end
			local who = Players:GetPlayerByUserId(current.userId)
			local character = who and who.Character
			local rig = if character then rigFor(character, now) else nil
			if current.rig and current.rig ~= rig then
				restRig(current.rig, Poses.LIMBS)
			end
			current.rig = rig
			if rig then
				-- Every limb, at full weight once settled: nothing of the avatar's own
				-- animations (idle, fall) shows on a lifter.
				local out = Rules.press(if current.repAt then now - current.repAt else 0, current.repTime)
				poseRig(rig, POSE.BenchDown, POSE.BenchUp, out, math.min(1, (now - current.startedAt) / BLEND_IN), Poses.LIMBS)
			end
		end,
		pressed = function(now: number)
			local current = lift
			if current and current.mine then
				advance(current, now, true)
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

	task.spawn(function()
		actionRemote = Net.event("Action")
	end)
	-- Hands a new jump press to the props (once, when both signals below report it).
	local lastPress = -math.huge
	local function press(now: number)
		if now - lastPress < SAME_PRESS then
			return
		end
		lastPress = now
		for instance, handler in live do
			if handler.pressed then
				local ok, err = pcall(handler.pressed :: any, now)
				if not ok then
					report(instance.Name, err)
				end
			end
		end
	end
	-- JumpRequest fires every frame while jump is held: props get its rising edge.
	UserInputService.JumpRequest:Connect(function()
		local now = os.clock()
		local fresh = Rules.newPress(lastJumpRequest, now)
		lastJumpRequest = now
		if fresh then
			press(now)
		end
	end)
	-- The jump key or button going down is a new press however short the pause before it:
	-- mashing can leave gaps too short to tell from a held key by JumpRequest alone.
	UserInputService.InputBegan:Connect(function(input: InputObject)
		local key = input.KeyCode
		if (key == Enum.KeyCode.Space or key == Enum.KeyCode.ButtonA) and not UserInputService:GetFocusedTextBox() then
			local now = os.clock()
			lastJumpRequest = now
			press(now)
		end
	end)
	-- A new character starts clean: its connections go with the old one.
	player.CharacterRemoving:Connect(function()
		dropMe()
		punchAt = -math.huge
		punchRig = nil
	end)
	RunService.Heartbeat:Connect(function(dt: number)
		local now = os.clock()
		syncStates()
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
