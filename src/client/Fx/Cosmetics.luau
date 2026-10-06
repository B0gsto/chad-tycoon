--[[
	Fx.Cosmetics: the local player's own cosmetic effects (client-side only).

	The server (Server.Cosmetics) sets two Player attributes:
	  CosDoubleJump   owned and switched on: a second jump in mid-air
	  CosSpeed        Speedy Sneakers on: little speed puffs at the feet while running
	Trails, aura and crown are server-made on the character, so everyone sees them.

	Double jump listens to UserInputService.JumpRequest (keyboard, gamepad and the
	mobile jump button all raise it). Holding jump repeats the request every frame,
	so only a request after a short gap counts as a new press. One air jump per
	flight, reset on landing; never while the intro cutscene plays.

	Nothing runs per frame: every connection is event-driven and only exists while
	its cosmetic is on.
]]

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Sprites = require(script.Parent.Sprites)

local CosmeticsFx = {}

-- A JumpRequest this long after the previous one is a new press, not a held key.
local PRESS_GAP = 0.12
-- Seconds in the air before the second jump is allowed (keeps one press from doing both).
local MIN_AIR_TIME = 0.12
-- Running faster than this (studs/s) shows the speed puffs.
local PUFF_SPEED = 10

local player = Players.LocalPlayer
local jumpConns: { RBXScriptConnection } = {}
local speedConns: { RBXScriptConnection } = {}
local puffEmitter: ParticleEmitter? = nil

local function disconnect(list: { RBXScriptConnection })
	for _, conn in list do
		conn:Disconnect()
	end
	table.clear(list)
end

local function characterParts(): (Humanoid?, BasePart?)
	local character = player.Character
	if not character then
		return nil, nil
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local root = character:FindFirstChild("HumanoidRootPart")
	return humanoid, if root and root:IsA("BasePart") then root else nil
end

local function jumpVelocity(humanoid: Humanoid): number
	if humanoid.UseJumpPower then
		return humanoid.JumpPower
	end
	return math.sqrt(2 * Workspace.Gravity * humanoid.JumpHeight)
end

-- Star burst under the feet (sprites; a plain puff when they are missing).
local function burst(root: BasePart, humanoid: Humanoid)
	local feet = root.Position - Vector3.new(0, humanoid.HipHeight + root.Size.Y / 2, 0)
	local shown = Sprites.billboard(root, "StarPop", {
		position = feet,
		size = 2.2,
		rise = Vector3.new(0, -0.6, 0),
		life = 0.45,
		spin = 90,
		maxDistance = 60,
	})
	for i = 1, 3 do
		local angle = (i / 3 + math.random() * 0.2) * math.pi * 2
		Sprites.billboard(root, "Puff", {
			position = feet,
			size = 1.3,
			rise = Vector3.new(math.cos(angle) * 1.6, -0.3, math.sin(angle) * 1.6),
			life = 0.5,
			color = Color3.new(1, 1, 1),
			maxDistance = 60,
		})
	end
	if not shown then
		Sprites.billboard(root, "Sparkle", { position = feet, size = 1.6, life = 0.4 })
	end
end

-- Double jump -----------------------------------------------------------------------------

local function hookJump(humanoid: Humanoid)
	disconnect(jumpConns)
	local airborneAt: number? = nil
	local used = false
	local lastRequest = 0

	table.insert(
		jumpConns,
		humanoid.StateChanged:Connect(function(_, new)
			if new == Enum.HumanoidStateType.Landed or new == Enum.HumanoidStateType.Running then
				airborneAt = nil
				used = false
			elseif (new == Enum.HumanoidStateType.Jumping or new == Enum.HumanoidStateType.Freefall) and airborneAt == nil then
				airborneAt = os.clock()
			end
		end)
	)
	table.insert(
		jumpConns,
		UserInputService.JumpRequest:Connect(function()
			local now = os.clock()
			local newPress = now - lastRequest > PRESS_GAP
			lastRequest = now
			if not newPress or used or airborneAt == nil or now - (airborneAt :: number) < MIN_AIR_TIME then
				return
			end
			if player:GetAttribute("IntroPlaying") == true or humanoid.Health <= 0 then
				return
			end
			local state = humanoid:GetState()
			if state ~= Enum.HumanoidStateType.Freefall and state ~= Enum.HumanoidStateType.Jumping then
				return
			end
			local _, root = characterParts()
			if not root then
				return
			end
			used = true
			humanoid:ChangeState(Enum.HumanoidStateType.Jumping)
			local v = root.AssemblyLinearVelocity
			root.AssemblyLinearVelocity = Vector3.new(v.X, jumpVelocity(humanoid), v.Z)
			burst(root, humanoid)
		end)
	)
end

-- Speed puffs -----------------------------------------------------------------------------

local function hookSpeed(humanoid: Humanoid, root: BasePart)
	disconnect(speedConns)
	if puffEmitter then
		puffEmitter:Destroy()
		puffEmitter = nil
	end
	local feet = Instance.new("Attachment")
	feet.Name = "CosSpeedPuffs"
	feet.Position = Vector3.new(0, -(humanoid.HipHeight + root.Size.Y / 2) + 0.3, 0.4)
	feet.Parent = root
	local emitter = Sprites.emitter(feet, "Puff", {
		Rate = 9,
		Enabled = false,
		EmissionDirection = Enum.NormalId.Back,
		Speed = NumberRange.new(3, 5),
		Drag = 4,
		SpreadAngle = Vector2.new(20, 10),
		Lifetime = NumberRange.new(0.35, 0.55),
		Acceleration = Vector3.new(0, 1.5, 0),
		Size = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.3),
			NumberSequenceKeypoint.new(0.3, 0.7),
			NumberSequenceKeypoint.new(1, 0.2),
		}),
		Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.2),
			NumberSequenceKeypoint.new(0.6, 0.4),
			NumberSequenceKeypoint.new(1, 1),
		}),
	})
	if not emitter then
		feet:Destroy()
		return
	end
	puffEmitter = emitter
	local running = false
	local onGround = true
	local function update()
		emitter.Enabled = running and onGround
	end
	table.insert(
		speedConns,
		humanoid.Running:Connect(function(speed)
			running = speed > PUFF_SPEED
			update()
		end)
	)
	table.insert(
		speedConns,
		humanoid.StateChanged:Connect(function(_, new)
			onGround = new == Enum.HumanoidStateType.Running or new == Enum.HumanoidStateType.RunningNoPhysics
			update()
		end)
	)
	table.insert(
		speedConns,
		feet.Destroying:Connect(function()
			if puffEmitter == emitter then
				puffEmitter = nil
			end
		end)
	)
end

local function clearSpeed()
	disconnect(speedConns)
	if puffEmitter then
		local attachment = puffEmitter.Parent
		puffEmitter = nil
		if attachment then
			attachment:Destroy()
		end
	end
end

-- Wiring ----------------------------------------------------------------------------------

local function refresh()
	local humanoid, root = characterParts()
	if humanoid and player:GetAttribute("CosDoubleJump") == true then
		hookJump(humanoid)
	else
		disconnect(jumpConns)
	end
	if humanoid and root and player:GetAttribute("CosSpeed") == true then
		if not puffEmitter or not puffEmitter:IsDescendantOf(root) then
			hookSpeed(humanoid, root)
		end
	else
		clearSpeed()
	end
end

function CosmeticsFx.init()
	if not player then
		return
	end
	player:GetAttributeChangedSignal("CosDoubleJump"):Connect(refresh)
	player:GetAttributeChangedSignal("CosSpeed"):Connect(refresh)
	player.CharacterAdded:Connect(function(character)
		disconnect(jumpConns)
		clearSpeed()
		character:WaitForChild("Humanoid", 10)
		character:WaitForChild("HumanoidRootPart", 10)
		if player.Character == character then
			refresh()
		end
	end)
	refresh()
end

return CosmeticsFx
