--!strict
--[[
	Fx.Mog: the 3D side of the MOG TEST (MogHud draws the skill-check ring).

	  Rival        built locally with CharacterFactory from the rival's tier look (so only
	               this client sees its own rival), standing at rivalPos facing the player.
	               Hit: a shocked flinch back; perfect adds a star pop. Miss: an angry
	               flex pose with a hop and a red ring at the player's feet. Mogged:
	               sad face, it shrinks and pops with stars, confetti and a puff, and the
	               next rival walks in after a beat with its own puff.
	  Aura         a glowing neon disc and light at the player's feet that grows with the
	               combo and pulses on every hit (gold), flickers red on a miss.
	  Camera       Scriptable duel framing over the player's shoulder looking at the
	               rival, with a slow sideways drift; on finish / stop the camera goes back
	               to Custom on the humanoid (Fx.Camera then frames it behind the player).
	  Sounds       Celebrate when a rival is mogged; the UI sounds belong to MogHud.

	Listens to Notify (kind "Mode", mode "mog") on its own; everything it makes is
	removed on finish and stop.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Net = require(ReplicatedStorage.Shared.Net)
local CharacterFactory = require(ReplicatedStorage.Shared:WaitForChild("CharacterFactory")) :: any
local Theme = require(ReplicatedStorage:WaitForChild("Theme")) :: any
local Client = script.Parent.Parent
local Sounds = require(Client.Sounds) :: any
local Sprites = require(script.Parent.Sprites)
local Animator = require(Client.Animator) :: any

local MogFx = {}

local player = Players.LocalPlayer
local W = Theme.World
local C = Theme.Colors

local CAMERA_BIND = "FxMogCamera"
local AURA_BASE = 4.5 -- aura disc diameter at combo 0 (studs)
local AURA_PER_COMBO = 0.55
local AURA_MAX_COMBO = 10

local folder: Folder? = nil
local rival: Model? = nil
local rivalHeight = 6
local rivalPivot = CFrame.identity
local aura: Part? = nil
local auraLight: PointLight? = nil
local playerPos = Vector3.zero
local rivalPos = Vector3.new(0, 0, -12)
local running = false
local cameraOn = false
local token = 0 -- bumps on every rival change so stale tweens stop

local function num(value: any, default: number): number
	return if type(value) == "number" and value == value then value else default
end

-- A throwaway invisible anchor for world sprites.
local function anchorAt(position: Vector3, life: number): BasePart
	local part = Instance.new("Part")
	part.Name = "MogFxAnchor"
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

-- Runs `fn(alpha)` over `time` seconds (Quad out) on a NumberValue tween; stops early when
-- the rival changes.
local function animate(time: number, style: Enum.EasingStyle, fn: (number) -> ())
	local mine = token
	local value = Instance.new("NumberValue")
	local conn = value.Changed:Connect(function(alpha: number)
		if token == mine then
			fn(alpha)
		end
	end)
	local tween = TweenService:Create(value, TweenInfo.new(time, style, Enum.EasingDirection.Out), { Value = 1 })
	tween.Completed:Connect(function()
		conn:Disconnect()
		value:Destroy()
	end)
	tween:Play()
end

-- Rival -------------------------------------------------------------------------------------

local function tierLook(tier: number): any
	local tiers = Theme.Tiers
	local entry = tiers[math.clamp(math.floor(tier), 1, #tiers)]
	return entry and entry.Look
end

local function removeRival()
	token += 1
	if rival then
		rival:Destroy()
		rival = nil
	end
end

local function spawnRival(info: any)
	removeRival()
	if type(info) ~= "table" then
		return
	end
	local base = tierLook(num(info.tier, 1))
	if not base or not folder then
		return
	end
	local look = table.clone(base)
	look.exprs = { "Smug", "Shock", "Angry", "Sad", "Determined" }
	look.expr = "Smug"
	local ok, model = pcall(CharacterFactory.build, look, "MogRival")
	if not ok or not model then
		warn("[Fx.Mog] rival build failed: " .. tostring(model))
		return
	end
	local m = model :: Model
	local height = m:GetAttribute("Height")
	rivalHeight = if type(height) == "number" then height else 6
	local face = Vector3.new(playerPos.X, rivalPos.Y, playerPos.Z)
	rivalPivot = if (face - rivalPos).Magnitude > 0.1 then CFrame.lookAt(rivalPos, face) else CFrame.new(rivalPos)
	m:PivotTo(rivalPivot)
	m.Parent = folder
	rival = m
	CharacterFactory.setExpression(m, "Smug")
	-- Walk-in pop: grows from small with a puff (the Animator holds it while it scales,
	-- then re-captures its rest pose).
	Animator.hold(m)
	local full = m:GetScale()
	m:ScaleTo(full * 0.2)
	animate(0.45, Enum.EasingStyle.Back, function(a)
		m:ScaleTo(full * (0.2 + 0.8 * a))
		m:PivotTo(rivalPivot)
	end)
	task.delay(0.5, function()
		if rival == m then
			m:ScaleTo(full)
			m:PivotTo(rivalPivot)
			Animator.release(m)
		end
	end)
	sprite("Puff", rivalPos + Vector3.new(0, 1, 0), { size = 6, life = 0.7, rise = Vector3.new(0, 2, 0) })
end

local function setExpr(name: string, back: number?)
	local m = rival
	if not m then
		return
	end
	CharacterFactory.setExpression(m, name)
	if back then
		local mine = token
		task.delay(back, function()
			if token == mine and rival == m then
				CharacterFactory.setExpression(m, "Smug")
			end
		end)
	end
end

-- The rival leans back a little (away from the player) and settles.
local function flinch(distance: number)
	local m = rival
	if not m then
		return
	end
	local away = -rivalPivot.LookVector
	animate(0.5, Enum.EasingStyle.Quad, function(a)
		local push = math.sin(a * math.pi) * distance
		m:PivotTo(rivalPivot * CFrame.Angles(math.rad(8) * math.sin(a * math.pi), 0, 0) + away * push)
	end)
end

-- The rival puffs up: a quick flex pose with a little hop.
local function puffUp()
	local m = rival
	if m then
		Animator.show(m, "DoubleBiceps", 1.2, 0.4)
	end
end

local function moggedPop()
	local m = rival
	if not m then
		return
	end
	CharacterFactory.setExpression(m, "Sad")
	Animator.hold(m)
	token += 1 -- this model is leaving; the shrink below owns it now
	rival = nil
	local full = m:GetScale()
	local head = rivalPos + Vector3.new(0, rivalHeight * 0.6, 0)
	local value = Instance.new("NumberValue")
	value.Changed:Connect(function(a: number)
		if not m.Parent then
			return
		end
		m:ScaleTo(math.max(full * (1 - a), 0.02))
		m:PivotTo(rivalPivot * CFrame.Angles(0, math.rad(540 * a), 0))
	end)
	local tween = TweenService:Create(value, TweenInfo.new(0.5, Enum.EasingStyle.Back, Enum.EasingDirection.In), { Value = 0.98 })
	tween.Completed:Connect(function()
		value:Destroy()
		m:Destroy()
	end)
	task.delay(0.25, function()
		tween:Play()
	end)
	task.delay(0.7, function()
		sprite("Puff", head, { size = 7, life = 0.8, rise = Vector3.new(0, 2, 0) })
		sprite("Ring", head, { size = 8, life = 0.6, rise = Vector3.zero, color = W.Sunny })
		for i = 1, 6 do
			local angle = i / 6 * math.pi * 2
			local offset = Vector3.new(math.cos(angle) * 1.5, math.sin(angle) * 1.2, 0)
			sprite(if i % 2 == 0 then "StarPop" else "Confetti", head + offset, {
				size = 2.6,
				life = 1,
				delay = i * 0.03,
				rise = Vector3.new(math.cos(angle) * 4, 3 + math.sin(angle) * 2, 0),
				spin = 90,
			})
		end
		Sounds.play("Celebrate")
	end)
end

-- Aura --------------------------------------------------------------------------------------

local function auraSize(combo: number): number
	return AURA_BASE + math.min(combo, AURA_MAX_COMBO) * AURA_PER_COMBO
end

local function buildAura()
	local part = Instance.new("Part")
	part.Name = "MogAura"
	part.Shape = Enum.PartType.Cylinder
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Material = Enum.Material.Neon
	part.Color = C.Gold
	part.Transparency = 0.6
	part.Size = Vector3.new(0.12, AURA_BASE, AURA_BASE)
	part.CFrame = CFrame.new(playerPos + Vector3.new(0, 0.08, 0)) * CFrame.Angles(0, 0, math.rad(90))
	part.Parent = folder
	local light = Instance.new("PointLight")
	light.Color = C.Gold
	light.Range = 10
	light.Brightness = 1.2
	light.Parent = part
	aura, auraLight = part, light
end

local function pulseAura(combo: number, color: Color3)
	local part, light = aura, auraLight
	if not part or not light then
		return
	end
	local d = auraSize(combo)
	part.Color = color
	part.Transparency = 0.25
	part.Size = Vector3.new(0.12, d * 1.25, d * 1.25)
	light.Color = color
	light.Brightness = 3
	TweenService:Create(part, TweenInfo.new(0.5, Enum.EasingStyle.Quad), {
		Size = Vector3.new(0.12, d, d),
		Transparency = 0.6 - math.min(combo, AURA_MAX_COMBO) * 0.025,
		Color = C.Gold,
	}):Play()
	TweenService:Create(light, TweenInfo.new(0.5), { Brightness = 1.2 + math.min(combo, AURA_MAX_COMBO) * 0.15, Color = C.Gold }):Play()
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
		local flat = Vector3.new(rivalPos.X - playerPos.X, 0, rivalPos.Z - playerPos.Z)
		local forward = if flat.Magnitude > 0.1 then flat.Unit else Vector3.new(0, 0, -1)
		local right = forward:Cross(Vector3.yAxis)
		local t = os.clock() - started
		-- Over the right shoulder, raised for taller rivals; a slow sideways drift.
		local lift = 5.5 + math.max(rivalHeight - 6, 0) * 0.35
		local eye = playerPos - forward * 9 + right * (3.4 + math.sin(t * 0.35) * 0.8) + Vector3.new(0, lift + math.sin(t * 0.27) * 0.3, 0)
		local focus = rivalPos + Vector3.new(0, rivalHeight * 0.55, 0) - forward * 2
		local goal = CFrame.lookAt(eye, focus)
		current = if current then current:Lerp(goal, 1 - math.exp(-dt * 4)) else goal
		cam.CFrame = current :: CFrame
	end)
end

-- Run ---------------------------------------------------------------------------------------

local function clear()
	running = false
	releaseCamera()
	removeRival()
	if folder then
		folder:Destroy()
		folder = nil
	end
	aura, auraLight = nil, nil
end

local function onStart(p: any)
	clear()
	running = true
	if typeof(p.playerPos) == "Vector3" then
		playerPos = p.playerPos
	else
		local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
		playerPos = if root and root:IsA("BasePart") then root.Position - Vector3.new(0, 3, 0) else Vector3.zero
	end
	rivalPos = if typeof(p.rivalPos) == "Vector3" then p.rivalPos else playerPos + Vector3.new(0, 0, -14)
	local f = Instance.new("Folder")
	f.Name = "MogFx"
	f.Parent = Workspace
	folder = f
	buildAura()
	spawnRival(p.rival)
	takeCamera()
end

local function onResult(p: any)
	local combo = num(p.combo, 0)
	local head = rivalPos + Vector3.new(0, rivalHeight * 0.85, 0)
	if p.result == "perfect" then
		setExpr("Shock", 0.8)
		flinch(1.4)
		pulseAura(combo, W.Sunny)
		sprite("StarPop", head, { size = 3, life = 0.8, rise = Vector3.new(0, 2, 0), spin = 60 })
		sprite(
			"Ring",
			playerPos + Vector3.new(0, 0.3, 0),
			{ size = auraSize(combo) * 1.4, life = 0.5, rise = Vector3.zero, color = W.Sunny }
		)
	elseif p.result == "hit" then
		setExpr("Shock", 0.6)
		flinch(0.8)
		pulseAura(combo, W.Cream)
	else
		setExpr("Angry", 1)
		puffUp()
		pulseAura(0, C.Bad)
		sprite("Ring", playerPos + Vector3.new(0, 0.3, 0), { size = 6, life = 0.5, rise = Vector3.zero, color = C.Bad })
		sprite("Puff", head, { size = 3, life = 0.6, rise = Vector3.new(0, 1.5, 0), color = C.Bad })
	end
end

function MogFx.onNotify(p: any)
	if type(p) ~= "table" then
		return
	end
	local event = p.event
	if event == "start" then
		onStart(p)
	elseif not running then
		return
	elseif event == "check" then
		setExpr("Determined")
	elseif event == "result" then
		onResult(p)
	elseif event == "rival" then
		moggedPop()
		local nextRival = p.rival
		task.delay(1.1, function()
			if running and type(nextRival) == "table" then
				spawnRival(nextRival)
			end
		end)
	elseif event == "finish" or event == "stop" then
		clear()
	end
end

function MogFx.init()
	Net.event("Notify").OnClientEvent:Connect(function(payload)
		if type(payload) == "table" and payload.kind == "Mode" and payload.mode == "mog" then
			MogFx.onNotify(payload)
		end
	end)
	player.CharacterRemoving:Connect(function()
		if running then
			clear()
		end
	end)
end

return MogFx
