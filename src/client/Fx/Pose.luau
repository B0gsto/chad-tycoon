--!strict
--[[
	Fx.Pose: the 3D side of POSE COPY (Modes.Pose; docs/minigames.md). UI.PoseHud draws
	the screen and drives the show's beats through Pose.rivalFlex / Pose.playerFlex.

	  Rival     a chad built locally with CharacterFactory (manual rig, posed here with
	            RigPose) on the rival's podium, facing the audience; every flex snaps in
	            with a hop, a ring on the podium and its lamp on the stage's D-pad.
	  Player    the local avatar strikes each flex it presses (Fx.PlayerPose): a correct
	            one bursts a sparkle aura in the flex's colour; a wrong one reels in Shock.
	  Stage     World.PoseStage's "FlexLamp<i>" tiles light up with the flex shown or
	            struck; the "PodiumGlow" rings take the flex colour and fade back.
	  Camera    Scriptable, from the audience: both chads side by side, a slow drift, a
	            short push-in on every cleared round. Back to Custom when the run ends.
	  Moments   "clear": both chads hop into a flex; "pass": confetti, stars and Victory;
	            "miss": the player's Shock and the rival's Smug; "win" / "lose": a last
	            pose each, then everything is put away.

	Main.client.luau calls init() once (it is in the Fx list); nothing else needs editing:
	  init()            connects the Notify listener
	  start(payload)    a run began ("start")
	  stop(payload)     the run ended ("stop", and shortly after "win" / "lose")
	  FLEXES            the client's copy of Modes.PoseRules.FLEXES (same order, colours)
	  rivalFlex(i, hold)        the rival shows flex i (hold: seconds it stays lit)
	  playerFlex(i, ok)         the player struck flex i; ok = it was the right one
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
local CAM = { Back = 17, Up = 5.2, Look = 2.3, Drift = 1.2, Push = 2.4 }
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

local running = false
local runId = 0
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

local function findStage()
	table.clear(lamps)
	table.clear(glows)
	table.clear(playerGlows)
	local map = Workspace:FindFirstChild("Map")
	local stage = map and map:FindFirstChild("PoseStage")
	if not stage then
		return
	end
	for _, part in stage:GetChildren() do
		if not part:IsA("BasePart") then
			continue
		end
		local flex = part:GetAttribute("Flex")
		if type(flex) == "number" then
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
	if not camera then
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
		-- From the audience, both chads in frame, drifting slowly side to side.
		local since = os.clock() - pushAt
		local push = if since < 0.9 then math.sin(math.clamp(since / 0.9, 0, 1) * math.pi) * CAM.Push else 0
		local eye = mid
			+ facing * (CAM.Back - push)
			+ right * math.sin(t * 0.3) * CAM.Drift
			+ Vector3.new(0, CAM.Up + math.sin(t * 0.23) * 0.25, 0)
		local goal = CFrame.lookAt(eye, mid + Vector3.new(0, CAM.Look, 0))
		current = if current then current:Lerp(goal, 1 - math.exp(-dt * 5)) else goal
		cam.CFrame = current :: CFrame
	end)
end

-- Run -------------------------------------------------------------------------------------

local function clear()
	running = false
	runId += 1
	-- The camera first: whatever else fails, the player gets the follow camera back.
	releaseCamera()
	if selfPoser then
		selfPoser:stop()
		selfPoser = nil
	end
	removeRival()
	lampsOff()
	for _, glow in glows do
		glow.Color = Color3.new(1, 1, 1)
	end
	if folder then
		folder:Destroy()
		folder = nil
	end
end

function Pose.start(payload: { [string]: any })
	clear()
	running = true
	if typeof(payload.playerPos) == "Vector3" then
		playerPos = payload.playerPos
	else
		local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
		playerPos = if root and root:IsA("BasePart") then root.Position - Vector3.new(0, 3, 0) else Vector3.zero
	end
	facing = if typeof(payload.facing) == "Vector3" then payload.facing else Vector3.new(0, 0, 1)
	rivalPos = if typeof(payload.rivalPos) == "Vector3" then payload.rivalPos else playerPos - facing:Cross(Vector3.yAxis) * 14
	local f = Instance.new("Folder")
	f.Name = "PoseFx"
	f.Parent = Workspace
	folder = f
	findStage()
	-- This player's podium (lanes: several players can pose at once).
	local nearest = math.huge
	for _, glow in playerGlows do
		local d = (Vector3.new(glow.Position.X, playerPos.Y, glow.Position.Z) - playerPos).Magnitude
		if d < nearest then
			nearest = d
			glows.player = glow
		end
	end
	spawnRival()
	setExpr("Smug")
	-- The avatar may land a frame after the teleport: attach once it is there.
	local mine = runId
	task.delay(0.15, function()
		if running and runId == mine and not selfPoser then
			selfPoser = PlayerPose.attach(player.Character)
		end
	end)
	takeCamera()
end

function Pose.stop(_payload: { [string]: any }?)
	if not running then
		return
	end
	clear()
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
	end
end

-- Notify -----------------------------------------------------------------------------------

local function onRound(p: any)
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
	setExpr("Cheer")
	rivalStrike("Shrug", false, 1.2)
	task.delay(1.2, function()
		setExpr("Smug")
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
	-- The run is over on the server already: hold the last poses a moment, then put away.
	task.delay(END_HOLD, function()
		if runId == mine then
			Pose.stop(nil)
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
end

return Pose
