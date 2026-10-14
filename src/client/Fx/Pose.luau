--!strict
--[[
	Fx.Pose: the 3D side of POSE COPY (Modes.Pose; docs/minigames.md). UI.PoseHud draws
	the screen and drives the show's beats through Pose.rivalFlex / Pose.playerFlex.

	A stay goes lobby -> countdown -> play -> results -> lobby (docs/minigames.md):
	  Lobby     the rival chad stands on his podium warming up (a random flex now and then);
	            the follow camera is the player's. Standing at the arena's "RehearsalSpot"
	            the HUD's flex pad calls Pose.rehearse(i): the avatar strikes the flex with
	            the same aura as a game (nothing is sent; walking off lets the pose go).
	  Countdown the pose camera takes over and the avatar is posed on its podium.
	  Play      Rival: a chad built locally with CharacterFactory (manual rig, posed here
	            with RigPose) on the rival's podium, facing the audience; every flex snaps
	            in with a hop, a ring on the podium and its lamp on the stage's D-pad.
	            Player: the local avatar strikes each flex it presses (Fx.PlayerPose): a
	            right one bursts a sparkle aura in the flex's colour; a wrong one reels.
	            Stage: "FlexLamp<i>" tiles light up with the flex shown or struck; the
	            "PodiumGlow" rings take the flex colour and fade back.
	  Camera    Scriptable, from the audience: both chads side by side, a slow drift, a
	            short push-in on every cleared round. Short (phone) screens frame the chads
	            lower and clear of the flex pad (Pose.compact()). Back to the follow
	            camera a moment after "win" / "lose", in the lobby and on leave.
	  Moments   "clear": both chads hop into a flex; "pass": confetti, stars and Victory;
	            "miss": the player's Shock and the rival's Smug; "win" / "lose": a last
	            pose each, then back to the lobby look.

	Main.client.luau calls init() once (it is in the Fx list); nothing else needs editing:
	  init()                connects the Notify listener
	  FLEXES                the client's copy of Modes.PoseRules.FLEXES (same order, colours)
	  rivalFlex(i, hold)    the rival shows flex i (hold: seconds it stays lit)
	  playerFlex(i, ok)     the player struck flex i; ok = it was the right one
	  rehearse(i)           lobby warm-up: the avatar strikes flex i (no game running)
	  compact()             true on short (phone) screens: the HUD puts its pad aside
	  arena() / find(name)  the arena Model (attribute Mode = "pose") and a named part in it
	  sync(inMode, phase)   the State snapshot's view (a safety net for a lost Notify)
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Net = require(ReplicatedStorage.Shared.Net)
local CharacterFactory = require(ReplicatedStorage.Shared:WaitForChild("CharacterFactory")) :: any
local RigPose = require(ReplicatedStorage.Shared:WaitForChild("RigPose")) :: any
local Sprites = require(script.Parent.Sprites)
local PlayerPose = require(script.Parent.PlayerPose)

local Pose = {}

export type Flex = { pose: string, label: string, dir: string, color: Color3 }

-- Same order and colours as Modes.PoseRules.FLEXES (the index is what "PoseInput" sends).
Pose.FLEXES = {
	{ pose = "DoubleBiceps", label = "DOUBLE BICEPS", dir = "Up", color = Color3.fromRGB(255, 196, 40) },
	{ pose = "SideChest", label = "SIDE CHEST", dir = "Left", color = Color3.fromRGB(255, 64, 158) },
	{ pose = "LatSpread", label = "LAT SPREAD", dir = "Right", color = Color3.fromRGB(70, 140, 255) },
	{ pose = "MostMuscular", label = "MOST MUSCULAR", dir = "Down", color = Color3.fromRGB(60, 206, 120) },
} :: { Flex }

local player = Players.LocalPlayer

local CAMERA_BIND = "FxPoseCamera"
local REST = "HandsOnHips"
local BLEND = 0.16 -- seconds for the rival to snap into a flex
local HOP = { Time = 0.3, Height = 0.7 }
local SETTLE = 0.85 -- seconds a flex holds before easing back to REST
-- Camera framing: distance in front of the chads, height over their feet, look height.
local CAM = { Back = 17, Up = 5.2, Look = 2.3, Drift = 1.2, Push = 2.4, CompactLift = 2.2 }
local END_HOLD = 2.6 -- seconds the last poses stay after "win" / "lose"

-- The rival's look (CharacterFactory fields): a tanned beach chad in a grape tank.
local RIVAL_LOOK = {
	skin = Color3.fromRGB(214, 160, 116),
	shirt = Color3.fromRGB(150, 96, 255),
	pants = Color3.fromRGB(40, 44, 92),
	anim = "Chad",
	buff = 1,
	scale = 1.15,
	top = "Tank",
	bottoms = "Shorts",
	hair = Color3.fromRGB(70, 46, 30),
	hairStyle = "Quiff",
	jaw = true,
	shoes = Color3.fromRGB(255, 255, 255),
	sole = Color3.fromRGB(150, 96, 255),
	trim = Color3.fromRGB(255, 214, 64),
	expr = "Smug",
	exprs = { "Smug", "Happy", "Shock", "Determined", "Cheer" },
	manual = true,
}

-- inMode: in the arena (lobby included); running: a game is on (countdown, play, results
-- hold). The rival stays up for the whole stay; the camera and the avatar's poser only
-- while running.
local inMode = false
local running = false
local runId = 0
local idleConn: RBXScriptConnection? = nil
local idleAt = 0
local folder: Folder? = nil
local playerPos = Vector3.zero
local rivalPos = Vector3.new(0, 0, -14)
local facing = Vector3.new(0, 0, 1)
local cameraOn = false
local pushAt = -math.huge

local rival: Model? = nil
local rig: any = nil
local rivalBase = CFrame.identity
local rivalPose, rivalFrom = REST, REST
local rivalAt, rivalHopAt = -math.huge, -math.huge
local rivalToken = 0
local rivalConn: RBXScriptConnection? = nil

local selfPoser: PlayerPose.Poser? = nil
local selfToken = 0

local lamps: { [number]: BasePart } = {}
local glows: { [string]: BasePart } = {}
-- Every player podium's glow (one per lane); start() keeps the one under this player.
local playerGlows: { BasePart } = {}

local function flexOf(index: any): Flex?
	return if type(index) == "number" then Pose.FLEXES[index] else nil
end

-- Tweens -----------------------------------------------------------------------------------

local function tween(obj: Instance, time: number, props: { [string]: any }, style: Enum.EasingStyle?)
	TweenService:Create(obj, TweenInfo.new(time, style or Enum.EasingStyle.Quad, Enum.EasingDirection.Out), props):Play()
end

-- A short-lived invisible anchor part for sprites and particles.
local function anchorAt(position: Vector3, life: number): BasePart
	local part = Instance.new("Part")
	part.Name = "PoseFxAnchor"
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Transparency = 1
	part.Size = Vector3.one * 0.2
	part.CFrame = CFrame.new(position)
	part.Parent = folder or Workspace
	task.delay(life, function()
		part:Destroy()
	end)
	return part
end

local function sprite(name: string, position: Vector3, opts: { [string]: any })
	local o = table.clone(opts) :: any
	o.position = position
	Sprites.billboard(anchorAt(position, 2.2), name, o)
end

-- A burst of `count` sparkles in `color` around `position` (the aura pop of a right flex).
local function burst(position: Vector3, color: Color3, count: number)
	local anchor = anchorAt(position, 2)
	local emitter = Sprites.emitter(anchor, "Sparkle", {
		Color = ColorSequence.new(color),
		LightEmission = 0.8,
		Speed = NumberRange.new(7, 13),
		SpreadAngle = Vector2.new(180, 180),
		Lifetime = NumberRange.new(0.45, 0.8),
		Size = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.2),
			NumberSequenceKeypoint.new(0.3, 0.9),
			NumberSequenceKeypoint.new(1, 0),
		}),
		Drag = 6,
	})
	if emitter then
		emitter:Emit(count)
	end
	local light = Instance.new("PointLight")
	light.Color = color
	light.Range = 14
	light.Brightness = 4
	light.Parent = anchor
	tween(light, 0.6, { Brightness = 0 })
end

-- Stage ------------------------------------------------------------------------------------

-- The arena Model: World.PoseStage's (attribute Mode = "pose"), cached while it lives.
local arenaModel: Instance? = nil
local arenaLookedAt = -math.huge
function Pose.arena(): Instance?
	if arenaModel and arenaModel.Parent then
		return arenaModel
	end
	arenaModel = nil
	-- A missing arena (still streaming in) is looked for again at most once a second.
	if os.clock() - arenaLookedAt < 1 then
		return nil
	end
	arenaLookedAt = os.clock()
	local map = Workspace:FindFirstChild("Map")
	if map then
		local named = map:FindFirstChild("PoseStage")
		if named and named:GetAttribute("Mode") ~= nil and named:GetAttribute("Mode") ~= "pose" then
			named = nil
		end
		arenaModel = named
		if not arenaModel then
			for _, child in map:GetChildren() do
				if child:GetAttribute("Mode") == "pose" then
					arenaModel = child
					break
				end
			end
		end
	end
	return arenaModel
end

-- A named descendant of the arena (nil when the arena or the part is not there).
function Pose.find(name: string): Instance?
	local stage = Pose.arena()
	return if stage then stage:FindFirstChild(name, true) else nil
end

-- Short screens (phones in landscape): the HUD moves the flex pad to the right and the
-- camera frames the chads lower, so the pad never covers them.
function Pose.compact(): boolean
	local camera = Workspace.CurrentCamera
	return camera ~= nil and camera.ViewportSize.Y < 560
end

-- The top of a part along world Y (podium discs are rotated cylinders).
local function topOf(part: BasePart): number
	local cf, size = part.CFrame, part.Size
	local half = (math.abs(cf.RightVector.Y) * size.X + math.abs(cf.UpVector.Y) * size.Y + math.abs(cf.LookVector.Y) * size.Z) / 2
	return part.Position.Y + half
end

local function findStage()
	table.clear(lamps)
	table.clear(glows)
	table.clear(playerGlows)
	local stage = Pose.arena()
	if not stage then
		return
	end
	for _, part in stage:GetDescendants() do
		if not part:IsA("BasePart") then
			continue
		end
		local flex = part:GetAttribute("Flex")
		if type(flex) == "number" and string.sub(part.Name, 1, 8) == "FlexLamp" then
			lamps[flex] = part
		elseif part.Name == "PodiumGlow" then
			local side = part:GetAttribute("Side")
			if side == "player" then
				table.insert(playerGlows, part)
			elseif type(side) == "string" then
				glows[side] = part
			end
		end
	end
end

-- The rival's feet on his podium, read from the stage ("RivalPad"), else nil.
local function stageRivalPos(): Vector3?
	local pad = Pose.find("RivalPad")
	if pad and pad:IsA("BasePart") then
		return Vector3.new(pad.Position.X, topOf(pad), pad.Position.Z)
	end
	local glow = glows.rival
	return if glow then Vector3.new(glow.Position.X, topOf(glow), glow.Position.Z) else nil
end

-- Lights flex `index`'s lamp for `hold` seconds (Neon, a pop of size), then dims it back.
local lampTokens: { [number]: number } = {}
local function lightLamp(index: number, hold: number)
	local lamp = lamps[index]
	if not lamp then
		return
	end
	local mine = (lampTokens[index] or 0) + 1
	lampTokens[index] = mine
	lamp.Material = Enum.Material.Neon
	lamp.Transparency = 0
	lamp.Size = Vector3.new(3.3, 3.3, 0.5)
	tween(lamp, 0.2, { Size = Vector3.new(2.8, 2.8, 0.5) }, Enum.EasingStyle.Back)
	task.delay(hold, function()
		if lampTokens[index] == mine and lamp.Parent then
			lamp.Material = Enum.Material.SmoothPlastic
			lamp.Transparency = 0.15
			tween(lamp, 0.2, { Size = Vector3.new(2.6, 2.6, 0.5) })
		end
	end)
end

local function lampsOff()
	for index, lamp in lamps do
		lampTokens[index] = (lampTokens[index] or 0) + 1
		lamp.Material = Enum.Material.SmoothPlastic
		lamp.Transparency = 0.15
		lamp.Size = Vector3.new(2.6, 2.6, 0.5)
	end
end

local function flashGlow(side: string, color: Color3)
	local glow = glows[side]
	if glow then
		glow.Color = color
		tween(glow, 0.7, { Color = Color3.new(1, 1, 1) })
	end
end

-- Rival ------------------------------------------------------------------------------------

local function rivalStrike(pose: string, hop: boolean, settle: number?)
	if not rig then
		return
	end
	rivalToken += 1
	local mine = rivalToken
	-- Blend from wherever the last flex had got to (a fresh one mid-blend snaps from it).
	rivalFrom = if os.clock() - rivalAt >= BLEND then rivalPose else rivalFrom
	rivalPose = pose
	rivalAt = os.clock()
	if hop then
		rivalHopAt = rivalAt
	end
	if settle then
		task.delay(settle, function()
			if rivalToken == mine then
				rivalStrike(REST, false)
			end
		end)
	end
end

local function rivalStep()
	if not rig or not rig.root.Parent then
		return
	end
	local now = os.clock()
	local alpha = math.clamp((now - rivalAt) / BLEND, 0, 1)
	local eased = TweenService:GetValue(alpha, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)
	local hopT = now - rivalHopAt
	local lift = if hopT < HOP.Time then math.sin(hopT / HOP.Time * math.pi) * HOP.Height else 0
	-- A squash-and-stretch read from the hop: tall at the top, a slight lean in on landing.
	local lean = if hopT < HOP.Time then math.sin(hopT / HOP.Time * math.pi * 2) * math.rad(4) else 0
	rig.root.CFrame = rivalBase * CFrame.new(0, lift, 0) * CFrame.Angles(lean, 0, 0)
	RigPose.applyPose(rig, rivalPose, now, rivalFrom, eased)
end

local function setExpr(name: string)
	if rival then
		CharacterFactory.setExpression(rival, name)
	end
end

local function removeRival()
	if rivalConn then
		rivalConn:Disconnect()
		rivalConn = nil
	end
	rivalToken += 1
	rig = nil
	if rival then
		rival:Destroy()
		rival = nil
	end
end

local function spawnRival()
	removeRival()
	local ok, model = pcall(CharacterFactory.build, RIVAL_LOOK, "PoseRival")
	if not ok or not model then
		warn("[Fx.Pose] rival build failed: " .. tostring(model))
		return
	end
	local m = model :: Model
	rivalBase = CFrame.lookAt(rivalPos, rivalPos + facing)
	m:PivotTo(rivalBase)
	m.Parent = folder
	rival = m
	rig = RigPose.capture(m)
	if not rig then
		return
	end
	rivalBase = rig.root.CFrame
	rivalPose, rivalFrom, rivalAt = REST, REST, -math.huge
	rivalConn = RunService.RenderStepped:Connect(rivalStep)
	sprite("Puff", rivalPos + Vector3.new(0, 1, 0), { size = 6, life = 0.7, rise = Vector3.new(0, 2, 0) })
end

-- Player -----------------------------------------------------------------------------------

local function selfStrike(pose: string, hop: number?, settle: number?)
	local poser = selfPoser
	if not poser then
		return
	end
	selfToken += 1
	local mine = selfToken
	poser:strike(pose, hop)
	if settle then
		task.delay(settle, function()
			if selfToken == mine and selfPoser == poser then
				poser:strike(REST)
			end
		end)
	end
end

-- Feet position of a character (HumanoidRootPart centre minus hip height and half the root).
local function feetOf(character: Model?): Vector3?
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root or not root:IsA("BasePart") then
		return nil
	end
	local humanoid = (character :: Model):FindFirstChildOfClass("Humanoid")
	local hip = if humanoid then humanoid.HipHeight else 2
	return root.Position - Vector3.new(0, hip + root.Size.Y / 2, 0)
end

-- Where the local avatar poses: the player podium nearest `at` (default: its feet; the
-- server put it on one), else that point itself. Also picks that podium's glow ring.
local function locatePlayer(at: Vector3?)
	local feet = at or feetOf(player.Character)
	if not feet then
		return
	end
	local best, nearest = nil :: BasePart?, 8
	for _, glow in playerGlows do
		local d = (Vector3.new(glow.Position.X, feet.Y, glow.Position.Z) - feet).Magnitude
		if d < nearest then
			nearest, best = d, glow
		end
	end
	if best then
		glows.player = best
	end
	playerPos = if best and not at then Vector3.new(best.Position.X, feet.Y, best.Position.Z) else feet
end

-- Camera ------------------------------------------------------------------------------------

local function releaseCamera()
	if not cameraOn then
		return
	end
	cameraOn = false
	RunService:UnbindFromRenderStep(CAMERA_BIND)
	local camera = Workspace.CurrentCamera
	if camera then
		local humanoid = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
		if humanoid then
			camera.CameraSubject = humanoid
		end
		camera.CameraType = Enum.CameraType.Custom
	end
end

local function takeCamera()
	local camera = Workspace.CurrentCamera
	if not camera or cameraOn then
		return
	end
	cameraOn = true
	camera.CameraType = Enum.CameraType.Scriptable
	local started = os.clock()
	local current: CFrame? = nil
	RunService:BindToRenderStep(CAMERA_BIND, Enum.RenderPriority.Camera.Value, function(dt: number)
		local cam = Workspace.CurrentCamera
		if not cam then
			return
		end
		if cam.CameraType ~= Enum.CameraType.Scriptable then
			cam.CameraType = Enum.CameraType.Scriptable
		end
		local t = os.clock() - started
		local mid = (playerPos + rivalPos) / 2
		local right = facing:Cross(Vector3.yAxis)
		local look = CAM.Look
		local shift = Vector3.zero
		if Pose.compact() then
			-- Phones: the chads sit lower (clear of the round pill and banner) and, on a
			-- narrow-ish screen, left of centre (clear of the flex pad at the bottom right).
			look += CAM.CompactLift
			local view = cam.ViewportSize
			local halfW = CAM.Back * math.tan(math.rad(cam.FieldOfView) / 2) * view.X / math.max(view.Y, 1)
			shift = -right * math.max(0, 9.5 - 0.42 * halfW)
		end
		-- From the audience, both chads in frame, drifting slowly side to side.
		local since = os.clock() - pushAt
		local push = if since < 0.9 then math.sin(math.clamp(since / 0.9, 0, 1) * math.pi) * CAM.Push else 0
		local eye = mid
			+ shift
			+ facing * (CAM.Back - push)
			+ right * math.sin(t * 0.3) * CAM.Drift
			+ Vector3.new(0, CAM.Up + math.sin(t * 0.23) * 0.25, 0)
		local goal = CFrame.lookAt(eye, mid + shift + Vector3.new(0, look, 0))
		current = if current then current:Lerp(goal, 1 - math.exp(-dt * 5)) else goal
		cam.CFrame = current :: CFrame
	end)
end

-- Rehearsal mirror (lobby) -------------------------------------------------------------------

local rehearsePoser: PlayerPose.Poser? = nil
local rehearseChar: Model? = nil
local rehearseToken = 0
local rehearseConn: RBXScriptConnection? = nil

local function endRehearse()
	rehearseToken += 1
	if rehearseConn then
		rehearseConn:Disconnect()
		rehearseConn = nil
	end
	if rehearsePoser then
		rehearsePoser:stop()
	end
	rehearsePoser, rehearseChar = nil, nil
end

-- Lobby warm-up: the avatar strikes flex `index` with a game's aura. Nothing is sent; the
-- pose lets go after a beat, or at once when the player walks off.
function Pose.rehearse(index: number)
	local flex = flexOf(index)
	local character = player.Character
	local feet = feetOf(character)
	if not flex or not inMode or running or not character or not feet then
		return
	end
	if rehearseChar ~= character or not rehearsePoser then
		endRehearse()
		rehearsePoser = PlayerPose.attach(character)
		rehearseChar = character
	end
	local poser = rehearsePoser
	if not poser then
		return
	end
	rehearseToken += 1
	local mine = rehearseToken
	poser:strike(flex.pose, 0.5)
	burst(feet + Vector3.new(0, 3.2, 0), flex.color, 14)
	sprite("Ring", feet + Vector3.new(0, 0.3, 0), { size = 6, life = 0.5, rise = Vector3.zero, color = flex.color })
	if not rehearseConn then
		local moving = 0
		rehearseConn = RunService.Heartbeat:Connect(function(dt: number)
			local humanoid = character:FindFirstChildOfClass("Humanoid")
			if humanoid and humanoid.MoveDirection.Magnitude > 0.1 then
				moving += dt
				if moving > 0.25 then
					endRehearse()
				end
			else
				moving = 0
			end
		end)
	end
	task.delay(SETTLE + 0.4, function()
		if rehearseToken == mine then
			endRehearse()
		end
	end)
end

-- Lobby, game, leave ------------------------------------------------------------------------

-- The lobby's rival: on his podium, a random warm-up flex every few seconds.
local function idleStep()
	if running or not rig or os.clock() < idleAt then
		return
	end
	idleAt = os.clock() + 4 + math.random() * 3
	local flex = Pose.FLEXES[math.random(#Pose.FLEXES)]
	rivalStrike(flex.pose, true, 1.1)
end

local function enterLobby(p: { [string]: any })
	if not inMode or not folder or not folder.Parent then
		inMode = true
		local f = Instance.new("Folder")
		f.Name = "PoseFx"
		f.Parent = Workspace
		folder = f
	end
	findStage()
	if typeof(p.facing) == "Vector3" then
		facing = p.facing
	end
	local spot = if typeof(p.rivalPos) == "Vector3" then p.rivalPos else stageRivalPos()
	if spot and (spot - rivalPos).Magnitude > 0.05 then
		rivalPos = spot
		removeRival()
	end
	if not rig and spot then
		spawnRival()
	end
	setExpr("Smug")
	idleAt = os.clock() + 2
	if not idleConn then
		idleConn = RunService.Heartbeat:Connect(idleStep)
	end
end

-- The game is over (or never started): the follow camera, the avatar's own animations and
-- the rival at rest. The rival stays for the lobby.
local function endGame()
	if not running then
		return
	end
	running = false
	runId += 1
	-- The camera first: whatever else fails, the player gets the follow camera back.
	releaseCamera()
	if selfPoser then
		selfPoser:stop()
		selfPoser = nil
	end
	lampsOff()
	for _, glow in glows do
		glow.Color = Color3.new(1, 1, 1)
	end
	rivalStrike(REST, false)
	setExpr("Smug")
	idleAt = os.clock() + 3
end

local playedAt = -math.huge
local givenPos = false

-- Countdown: the pose camera and the avatar's poser for a game on the player's podium.
local function beginPlay(p: { [string]: any })
	if not inMode then
		enterLobby(p)
	elseif next(lamps) == nil then
		findStage()
	end
	endRehearse()
	running = true
	runId += 1
	playedAt = os.clock()
	lampsOff()
	if typeof(p.facing) == "Vector3" then
		facing = p.facing
	end
	givenPos = typeof(p.playerPos) == "Vector3"
	locatePlayer(if givenPos then p.playerPos else nil)
	local spot = if typeof(p.rivalPos) == "Vector3" then p.rivalPos else stageRivalPos()
	if spot and (spot - rivalPos).Magnitude > 0.05 then
		rivalPos = spot
		removeRival()
	end
	if not rig then
		-- No stage to read (still streaming in): the rival two podiums to the player's left.
		if not spot then
			rivalPos = playerPos + facing:Cross(Vector3.yAxis) * 14
		end
		spawnRival()
	end
	rivalStrike(REST, false)
	setExpr("Smug")
	-- The avatar lands on the podium a moment after the teleport: attach (and look again)
	-- once it is there.
	local mine = runId
	for _, wait in { 0.15, 0.4, 1 } do
		task.delay(wait, function()
			if not running or runId ~= mine then
				return
			end
			if not givenPos then
				locatePlayer()
			end
			if not selfPoser then
				selfPoser = PlayerPose.attach(player.Character)
			end
		end)
	end
	takeCamera()
end

local function stopAll()
	endGame()
	endRehearse()
	inMode = false
	running = false
	runId += 1
	releaseCamera()
	if idleConn then
		idleConn:Disconnect()
		idleConn = nil
	end
	removeRival()
	lampsOff()
	if folder then
		folder:Destroy()
		folder = nil
	end
end

function Pose.start(payload: { [string]: any })
	if payload.phase == nil then
		-- An older server: "start" is the game itself.
		enterLobby(payload)
		beginPlay(payload)
	else
		endGame()
		enterLobby(payload)
	end
end

function Pose.stop(_payload: { [string]: any }?)
	stopAll()
end

-- The State snapshot's view: hands the camera back if a "win" / "lose" got lost, puts the
-- arena away if a "stop" did.
function Pose.sync(inArena: boolean, phase: string?)
	if not inArena then
		if inMode then
			stopAll()
		end
	elseif phase == "lobby" and running and os.clock() - playedAt > 2 then
		endGame()
	end
end

-- The rival shows flex `index` (one beat of the "round" show); its lamp stays lit `hold` s.
function Pose.rivalFlex(index: number, hold: number)
	local flex = flexOf(index)
	if not running or not flex then
		return
	end
	rivalStrike(flex.pose, true, math.max(hold, 0.3))
	lightLamp(index, hold)
	flashGlow("rival", flex.color)
	sprite("Ring", rivalPos + Vector3.new(0, 0.4, 0), { size = 7, life = 0.5, rise = Vector3.zero, color = flex.color })
	sprite("Sparkle", rivalPos + Vector3.new(0, 7.5, 0), { size = 2.2, life = 0.6, color = flex.color })
end

-- The player struck flex `index`: right (`ok`) bursts an aura in its colour, wrong reels.
function Pose.playerFlex(index: number, ok: boolean)
	local flex = flexOf(index)
	if not running or not flex then
		return
	end
	lightLamp(index, 0.45)
	if ok then
		selfStrike(flex.pose, 0.5, SETTLE)
		flashGlow("player", flex.color)
		burst(playerPos + Vector3.new(0, 3.2, 0), flex.color, 18)
		sprite("Ring", playerPos + Vector3.new(0, 0.4, 0), { size = 7, life = 0.5, rise = Vector3.zero, color = flex.color })
	else
		selfStrike("Shock", nil, 1.1)
		flashGlow("player", Color3.fromRGB(255, 70, 70))
		sprite(
			"Ring",
			playerPos + Vector3.new(0, 0.4, 0),
			{ size = 6, life = 0.4, rise = Vector3.zero, color = Color3.fromRGB(255, 70, 70) }
		)
	end
end

-- Notify -----------------------------------------------------------------------------------

local function onRound(p: any)
	if not givenPos then
		locatePlayer()
	end
	lampsOff()
	rivalStrike(REST, false)
	setExpr(if p.replay then "Determined" else "Smug")
end

local function onClear(_p: any)
	pushAt = os.clock()
	setExpr("Happy")
	rivalStrike("Point", true, 0.9)
	selfStrike("Victory", 0.6, 0.9)
	sprite("StarPop", playerPos + Vector3.new(0, 7, 0), { size = 3, life = 0.8, rise = Vector3.new(0, 2, 0), spin = 60 })
end

local function onPass(_p: any)
	pushAt = os.clock()
	setExpr("Shock")
	rivalStrike("Shock", false, 1.6)
	selfStrike("Victory", 1, 1.6)
	local gold = Color3.fromRGB(255, 212, 64)
	burst(playerPos + Vector3.new(0, 3.5, 0), gold, 40)
	for i = 1, 6 do
		local offset = Vector3.new((math.random() - 0.5) * 10, 6 + math.random() * 3, (math.random() - 0.5) * 3)
		sprite(if i % 2 == 0 then "Confetti" else "StarPop", playerPos + offset, {
			size = 2.4,
			life = 1.2,
			delay = i * 0.06,
			rise = Vector3.new(0, -3, 0),
			spin = 90,
		})
	end
	for index in Pose.FLEXES do
		lightLamp(index, 1.4)
	end
end

local function onMiss(_p: any)
	local mine = runId
	setExpr("Cheer")
	rivalStrike("Shrug", false, 1.2)
	task.delay(1.2, function()
		if runId == mine and running then
			setExpr("Smug")
		end
	end)
end

local function onFinish(p: any, won: boolean)
	local mine = runId
	if won then
		setExpr("Shock")
		rivalStrike("Shock", false)
		selfStrike("Victory", 0.8)
	else
		setExpr("Happy")
		rivalStrike("Victory", true)
		selfStrike("Shrug")
	end
	if p.newBest then
		sprite("StarPop", playerPos + Vector3.new(0, 7.5, 0), { size = 3.5, life = 1.2, rise = Vector3.new(0, 3, 0), spin = 60 })
	end
	-- Hold the last poses a moment, then the follow camera (PLAY AGAIN meanwhile starts a
	-- new countdown, which keeps the pose camera).
	task.delay(END_HOLD, function()
		if runId == mine then
			endGame()
		end
	end)
end

function Pose.init()
	Net.event("Notify").OnClientEvent:Connect(function(payload)
		if type(payload) ~= "table" or payload.kind ~= "Mode" or payload.mode ~= "pose" then
			return
		end
		local event = payload.event
		if event == "start" then
			Pose.start(payload)
		elseif event == "stop" then
			Pose.stop(payload)
		elseif event == "countdown" then
			beginPlay(payload)
		elseif not running then
			return
		elseif event == "round" then
			onRound(payload)
		elseif event == "clear" then
			onClear(payload)
		elseif event == "pass" then
			onPass(payload)
		elseif event == "miss" then
			onMiss(payload)
		elseif event == "win" or event == "lose" then
			onFinish(payload, event == "win")
		end
	end)
	-- A respawn in the lobby drops the warm-up poser (it held the old body's joints).
	player.CharacterAdded:Connect(function()
		endRehearse()
	end)
end

return Pose
