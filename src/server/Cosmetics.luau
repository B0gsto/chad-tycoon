--[[
	Cosmetics: the cosmetic game passes (Theme.Cosmetics) and the Starter pack.

	Ownership: an item is owned through its own pass, or the Bundle pass (every item
	except Starter ones), or, for a Starter item, the Starter pack pass.

	Saved in profile.cosmetics: the equipped trail ("" = none) and the on/off switch of
	each toggle item (perk / wear; missing = on). profile.starterGranted marks the
	Starter pack's one-time cash as given.

	On every character (and whenever ownership or equipment changes) the server puts
	the visible pieces on the character so everyone sees them: Humanoid.WalkSpeed, the
	trail (two attachments on the HumanoidRootPart), the aura emitters and the crown.
	Local-only effects (double jump, speed puffs) live in Client.Fx.Cosmetics, which
	reads the Player attributes "CosDoubleJump" and "CosSpeed".

	Speed: WalkSpeed = Humanoid attribute "BaseWalkSpeed" (default
	Theme.Cosmetics.BaseWalkSpeed) x the boost. Code that changes a player's normal speed
	sets that attribute and calls Cosmetics.refresh(player) instead of writing WalkSpeed.

	Client actions:
	  EquipTrail      { name = "<trail item>" | "" }   "" unequips
	  ToggleCosmetic  { name = "<perk/wear item>", value = boolean? }   nil flips
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Economy = require(Shared.Economy)
local AssetModels = require(Shared.AssetModels)

local DataService = require(script.Parent.DataService)
local Tycoon = require(script.Parent.Tycoon)

local Cosmetics = {}

type Session = Tycoon.Session

-- Name of every instance the server adds to a character.
local PIECE_ATTR = "Cosmetic"
-- Trail ribbon: attachment offsets on the HumanoidRootPart (behind the hips).
local TRAIL_TOP = Vector3.new(0, 0.55, 0.45)
local TRAIL_BOTTOM = Vector3.new(0, -1.05, 0.45)
-- Crown width as a fraction of the head's width, and how far it sinks onto the head.
local CROWN_WIDTH = 1.05
local CROWN_SINK = 0.18
-- Seconds before the join-time Starter popup is sent, so the client UI is listening.
local STARTER_NOTIFY_DELAY = 4

local theme: any
-- Per player: the cosmetic instances on the current character, and its connections.
local pieces: { [Player]: { Instance } } = {}
local pieceConns: { [Player]: { RBXScriptConnection } } = {}

-- Sprite image ids from the generated Assets module (nil when missing).
local images: { [string]: string }? = nil
do
	local module = Shared:FindFirstChild("Assets")
	if module and module:IsA("ModuleScript") then
		local ok, result = pcall(require, module :: any)
		if ok and type(result) == "table" and type((result :: any).Images) == "table" then
			images = (result :: any).Images
		end
	end
end

local function sprite(name: string): string?
	local id = images and images["vfx/" .. name]
	return if type(id) == "string" and id ~= "" then id else nil
end

-- Pure rules (also used by the unit tests) -------------------------------------------------

local function config(t: any): any
	return t and t.Cosmetics
end

-- Does a player with `passes` own cosmetic `name`?
function Cosmetics.owns(t: any, passes: { [string]: boolean }, name: string): boolean
	local c = config(t)
	local item = c and c.Items[name]
	if not item then
		return false
	end
	if item.Starter then
		return passes[c.Starter.Pass] == true
	end
	return (item.Pass ~= nil and passes[item.Pass] == true) or passes[c.Bundle] == true
end

-- { [name] = true } for every owned cosmetic.
function Cosmetics.ownedSet(t: any, passes: { [string]: boolean }): { [string]: boolean }
	local owned = {}
	local c = config(t)
	if c then
		for name in c.Items do
			if Cosmetics.owns(t, passes, name) then
				owned[name] = true
			end
		end
	end
	return owned
end

local function isToggle(item: any): boolean
	return item ~= nil and item.Kind ~= "trail"
end

-- Is toggle item `name` switched on in this profile (missing = on)?
function Cosmetics.toggleOn(profile: any, name: string): boolean
	return profile.cosmetics.toggles[name] ~= false
end

-- Is cosmetic `name` owned and in use (equipped trail / toggle switched on)?
function Cosmetics.active(t: any, profile: any, passes: { [string]: boolean }, name: string): boolean
	local c = config(t)
	local item = c and c.Items[name]
	if not item or not Cosmetics.owns(t, passes, name) then
		return false
	end
	if item.Kind == "trail" then
		return profile.cosmetics.trail == name
	end
	return Cosmetics.toggleOn(profile, name)
end

-- The equipped trail if it is still owned, else "".
function Cosmetics.trail(t: any, profile: any, passes: { [string]: boolean }): string
	local name = profile.cosmetics.trail
	if name ~= "" and Cosmetics.active(t, profile, passes, name) then
		return name
	end
	return ""
end

-- Marks the Starter pack as granted. True exactly once, the first time the pass is owned.
function Cosmetics.claimStarter(t: any, profile: any, passes: { [string]: boolean }): boolean
	local c = config(t)
	if not c or passes[c.Starter.Pass] ~= true or profile.starterGranted then
		return false
	end
	profile.starterGranted = true
	return true
end

-- The Starter pack's cash for a player at `income` cash/s and `progression`.
function Cosmetics.starterCash(t: any, income: number, progression: Economy.Progression): number
	local starter = t.Cosmetics.Starter
	return Economy.moneyPackAmount(income, starter.CashSeconds, starter.CashMin, progression)
end

-- The State snapshot's `cosmetics` field.
function Cosmetics.state(t: any, profile: any, passes: { [string]: boolean }): { [string]: any }
	local c = config(t)
	local toggles = {}
	for name, item in c.Items do
		if isToggle(item) then
			toggles[name] = Cosmetics.toggleOn(profile, name)
		end
	end
	return {
		owned = Cosmetics.ownedSet(t, passes),
		trail = Cosmetics.trail(t, profile, passes),
		toggles = toggles,
		bundleOwned = passes[c.Bundle] == true,
		starterOwned = passes[c.Starter.Pass] == true,
		starterGranted = profile.starterGranted == true,
	}
end

-- Character pieces -------------------------------------------------------------------------

local function clearPieces(player: Player)
	local conns: { RBXScriptConnection } = pieceConns[player] or {}
	for _, conn in conns do
		conn:Disconnect()
	end
	local made: { Instance } = pieces[player] or {}
	for _, inst in made do
		inst:Destroy()
	end
	pieces[player] = {}
	pieceConns[player] = {}
end

local function keep(player: Player, inst: Instance): Instance
	inst:SetAttribute(PIECE_ATTR, true)
	table.insert(pieces[player], inst)
	return inst
end

local function sequence(colors: { Color3 }): ColorSequence
	if #colors == 1 then
		return ColorSequence.new(colors[1])
	end
	local keys = {}
	for i, color in colors do
		table.insert(keys, ColorSequenceKeypoint.new((i - 1) / (#colors - 1), color))
	end
	return ColorSequence.new(keys)
end

local function addTrail(player: Player, root: BasePart, item: any)
	local top = keep(player, Instance.new("Attachment")) :: Attachment
	top.Name = "CosTrailTop"
	top.Position = TRAIL_TOP
	top.Parent = root
	local bottom = keep(player, Instance.new("Attachment")) :: Attachment
	bottom.Name = "CosTrailBottom"
	bottom.Position = TRAIL_BOTTOM
	bottom.Parent = root

	local trail = keep(player, Instance.new("Trail")) :: Trail
	trail.Name = "CosTrail"
	trail.Attachment0 = top
	trail.Attachment1 = bottom
	trail.Color = sequence(item.Colors or { item.Color })
	trail.Lifetime = 0.55
	trail.MinLength = 0.05
	trail.FaceCamera = true
	trail.LightEmission = 0
	trail.LightInfluence = 0.35
	trail.WidthScale = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(1, 0.35),
	})
	trail.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.1),
		NumberSequenceKeypoint.new(0.7, 0.45),
		NumberSequenceKeypoint.new(1, 1),
	})
	trail.Parent = root

	local starId = if item.Stars then sprite("StarPop") else nil
	if starId then
		local stars = keep(player, Instance.new("ParticleEmitter")) :: ParticleEmitter
		stars.Name = "CosTrailStars"
		stars.Texture = starId
		stars.Rate = 5
		stars.Enabled = true
		stars.LightEmission = 0
		stars.LightInfluence = 0
		stars.Lifetime = NumberRange.new(0.7, 1.1)
		stars.Speed = NumberRange.new(0.5, 1.5)
		stars.SpreadAngle = Vector2.new(60, 60)
		stars.Acceleration = Vector3.new(0, -3, 0)
		stars.Drag = 2
		stars.Rotation = NumberRange.new(-180, 180)
		stars.RotSpeed = NumberRange.new(-60, 60)
		stars.Size = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0),
			NumberSequenceKeypoint.new(0.15, 0.45),
			NumberSequenceKeypoint.new(0.7, 0.35),
			NumberSequenceKeypoint.new(1, 0),
		})
		stars.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0),
			NumberSequenceKeypoint.new(0.6, 0),
			NumberSequenceKeypoint.new(1, 1),
		})
		stars.Parent = bottom
		-- Stars only fall while the player is moving.
		local humanoid = root.Parent and root.Parent:FindFirstChildOfClass("Humanoid")
		if humanoid then
			table.insert(
				pieceConns[player],
				humanoid.Running:Connect(function(speed)
					stars.Enabled = speed > 2
				end)
			)
		end
	end
end

local function auraEmitter(player: Player, root: BasePart, name: string, props: { [string]: any })
	local id = sprite(name)
	if not id then
		return
	end
	local emitter = keep(player, Instance.new("ParticleEmitter")) :: ParticleEmitter
	emitter.Name = "CosAura" .. name
	emitter.Texture = id
	emitter.LightEmission = 0
	emitter.LightInfluence = 0
	emitter.Shape = Enum.ParticleEmitterShape.Box
	emitter.ShapeStyle = Enum.ParticleEmitterShapeStyle.Volume
	emitter.EmissionDirection = Enum.NormalId.Top
	emitter.SpreadAngle = Vector2.new(25, 25)
	emitter.Rotation = NumberRange.new(-180, 180)
	emitter.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(0.2, 0.15),
		NumberSequenceKeypoint.new(0.7, 0.3),
		NumberSequenceKeypoint.new(1, 1),
	})
	for key, value in props do
		(emitter :: any)[key] = value
	end
	emitter.Parent = root
end

local function addAura(player: Player, root: BasePart, item: any)
	local color = item.Color
	auraEmitter(player, root, "Sparkle", {
		Color = ColorSequence.new(color, theme.World.Cream),
		Rate = 6,
		Lifetime = NumberRange.new(0.9, 1.4),
		Speed = NumberRange.new(1, 2),
		Drag = 1,
		RotSpeed = NumberRange.new(-90, 90),
		Size = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0),
			NumberSequenceKeypoint.new(0.25, 0.5),
			NumberSequenceKeypoint.new(1, 0),
		}),
	})
	auraEmitter(player, root, "SoftDot", {
		Color = ColorSequence.new(color),
		Rate = 3,
		Lifetime = NumberRange.new(1.4, 2),
		Speed = NumberRange.new(0.4, 1),
		Drag = 0.5,
		RotSpeed = NumberRange.new(0, 0),
		Size = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 1.2),
			NumberSequenceKeypoint.new(1, 2.4),
		}),
		Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 1),
			NumberSequenceKeypoint.new(0.3, 0.7),
			NumberSequenceKeypoint.new(1, 1),
		}),
	})
end

local function dressPart(part: BasePart)
	part.Anchored = false
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Massless = true
	part.CastShadow = false
end

-- A part-built crown (used when the props/Crown mesh is missing): a gold band with
-- round points and a coral gem at the front. `width` studs across, pointing up +Y,
-- centred on the origin.
local function partCrown(width: number, color: Color3): Model
	local model = Instance.new("Model")
	local bandHeight = width * 0.38
	local function piece(shape: Enum.PartType, size: Vector3, cf: CFrame, tint: Color3): BasePart
		local part = Instance.new("Part")
		part.Shape = shape
		part.Size = size
		part.CFrame = cf
		part.Color = tint
		part.Material = Enum.Material.SmoothPlastic
		part.TopSurface = Enum.SurfaceType.Smooth
		part.BottomSurface = Enum.SurfaceType.Smooth
		part.Parent = model
		return part
	end
	local band = piece(Enum.PartType.Cylinder, Vector3.new(bandHeight, width, width), CFrame.Angles(0, 0, math.rad(90)), color)
	band.Name = "Band"
	model.PrimaryPart = band
	local ball = width * 0.26
	for i = 0, 4 do
		local angle = i / 5 * math.pi * 2
		local offset = Vector3.new(math.sin(angle), 0, -math.cos(angle)) * (width * 0.4)
		piece(Enum.PartType.Ball, Vector3.one * ball, CFrame.new(offset + Vector3.new(0, bandHeight * 0.5 + ball * 0.3, 0)), color).Name =
			"Point"
	end
	piece(Enum.PartType.Ball, Vector3.one * width * 0.2, CFrame.new(0, 0, -width * 0.48), theme.World.Coral).Name = "Gem"
	return model
end

-- The crown model (mesh if uploaded, else part-built), `width` studs wide, bottom at y = 0.
local function crownModel(item: any, width: number): Model
	local clone = AssetModels.clone(item.Model or "props/Crown")
	local mesh: MeshPart? = nil
	if clone then
		local found = if clone:IsA("MeshPart") then clone else clone:FindFirstChildWhichIsA("MeshPart", true)
		if found then
			local part = found :: MeshPart
			mesh = part
			if part ~= clone then
				part.Parent = nil
				clone:Destroy()
			end
		else
			clone:Destroy()
		end
	end
	if mesh then
		local size = mesh.Size
		local scale = width / math.max(size.X, size.Z, 1e-3)
		mesh.Size = size * scale
		mesh.CFrame = CFrame.new(0, mesh.Size.Y / 2, 0)
		mesh.Color = Color3.new(1, 1, 1)
		mesh.Name = "CrownMesh"
		local model = Instance.new("Model")
		mesh.Parent = model
		model.PrimaryPart = mesh
		return model
	end
	local model = partCrown(width, item.Color)
	local box, size = model:GetBoundingBox()
	model:PivotTo(model:GetPivot() + Vector3.new(0, size.Y / 2 - box.Position.Y, 0))
	return model
end

local function addCrown(player: Player, head: BasePart, item: any)
	local width = math.min(head.Size.X, head.Size.Z) * CROWN_WIDTH
	local model = keep(player, crownModel(item, width)) :: Model
	model.Name = "CosCrown"
	-- Model space has the crown's base at y = 0: move it onto the top of the head.
	local seat = head.CFrame * CFrame.new(0, head.Size.Y / 2 - CROWN_SINK * head.Size.Y, 0)
	for _, part in model:GetDescendants() do
		if part:IsA("BasePart") then
			dressPart(part)
			local world = seat * part.CFrame
			local weld = Instance.new("Weld")
			weld.Part0 = head
			weld.Part1 = part
			weld.C0 = head.CFrame:ToObjectSpace(world)
			weld.Parent = part
			part.CFrame = world
		end
	end
	model.Parent = head.Parent
end

-- Applying ---------------------------------------------------------------------------------

local function applySpeed(player: Player, humanoid: Humanoid, boosted: boolean)
	local c = config(theme)
	local base = humanoid:GetAttribute("BaseWalkSpeed")
	if type(base) ~= "number" then
		base = c.BaseWalkSpeed
		humanoid:SetAttribute("BaseWalkSpeed", base)
	end
	local mult = if boosted then c.Items.SpeedBoost.SpeedMultiplier else 1
	humanoid:SetAttribute("SpeedMultiplier", mult)
	humanoid.WalkSpeed = base * mult
	player:SetAttribute("CosSpeed", boosted)
end

-- Rebuilds every cosmetic on the player's current character.
local function apply(session: Session)
	local player = session.player
	if not session.alive or not config(theme) then
		return
	end
	local profile, passes = session.profile, session.passes
	local items = theme.Cosmetics.Items
	clearPieces(player)
	player:SetAttribute("CosDoubleJump", Cosmetics.active(theme, profile, passes, "DoubleJump"))
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not character or not humanoid or not root or not root:IsA("BasePart") then
		player:SetAttribute("CosSpeed", false)
		return
	end
	applySpeed(player, humanoid, Cosmetics.active(theme, profile, passes, "SpeedBoost"))
	local trail = Cosmetics.trail(theme, profile, passes)
	if trail ~= "" then
		addTrail(player, root, items[trail])
	end
	if Cosmetics.active(theme, profile, passes, "AuraGlow") then
		addAura(player, root, items.AuraGlow)
	end
	local head = character:FindFirstChild("Head")
	if head and head:IsA("BasePart") and Cosmetics.active(theme, profile, passes, "Crown") then
		local ok, err = pcall(addCrown, player, head, items.Crown)
		if not ok then
			warn("[Cosmetics] crown:", err)
		end
	end
end

-- Re-applies the player's cosmetics (e.g. after changing the humanoid's BaseWalkSpeed).
function Cosmetics.refresh(player: Player)
	local session = Tycoon.getSession(player)
	if session then
		apply(session)
	end
end

-- Starter pack -----------------------------------------------------------------------------

local function grantStarter(session: Session, delayNotify: boolean)
	local profile = session.profile
	if not Cosmetics.claimStarter(theme, profile, session.passes) then
		return
	end
	local progression = Economy.progression(Economy.highestTier(profile.runDiscovered), profile.processLevel)
	local cash = Cosmetics.starterCash(theme, Tycoon.income(session), progression)
	local starter = theme.Cosmetics.Starter
	Tycoon.grantMoney(session, cash)
	if profile.cosmetics.trail == "" then
		profile.cosmetics.trail = starter.Item
	end
	apply(session)
	Tycoon.markDirty(session)
	if session.canSave then
		task.spawn(DataService.save, session.player, profile)
	end
	local payload = { kind = "Starter", cash = cash, item = starter.Item }
	if delayNotify then
		task.delay(STARTER_NOTIFY_DELAY, function()
			if session.alive then
				Tycoon.notify(session, payload)
			end
		end)
	else
		Tycoon.notify(session, payload)
	end
end

-- A pass was just bought (or granted in Studio).
local function onPassGranted(session: Session, passName: string)
	local c = config(theme)
	if not c then
		return
	end
	if passName == c.Starter.Pass then
		grantStarter(session, false)
		return
	end
	-- A newly bought trail goes on straight away if none is equipped.
	if session.profile.cosmetics.trail == "" then
		for _, name in c.Order do
			local item = c.Items[name]
			if item.Kind == "trail" and (item.Pass == passName or passName == c.Bundle) and not item.Starter then
				session.profile.cosmetics.trail = name
				break
			end
		end
	end
	apply(session)
end

-- Call right after Tycoon.addPlayer: hooks the character and grants an owed Starter pack.
function Cosmetics.onSessionStart(session: Session)
	if not config(theme) then
		return
	end
	local player = session.player
	local function onCharacter(character: Model)
		local humanoid = character:WaitForChild("Humanoid", 10)
		local root = character:WaitForChild("HumanoidRootPart", 10)
		character:WaitForChild("Head", 5)
		if humanoid and root and session.alive and player.Character == character then
			apply(session)
		end
	end
	player.CharacterAdded:Connect(onCharacter)
	-- The avatar's own parts and accessories can arrive after CharacterAdded.
	player.CharacterAppearanceLoaded:Connect(function(character)
		if session.alive and player.Character == character then
			apply(session)
		end
	end)
	if player.Character then
		task.spawn(onCharacter, player.Character)
	else
		apply(session)
	end
	grantStarter(session, true)
end

function Cosmetics.init(themeModule: any)
	theme = themeModule
	local c = config(theme)
	if not c then
		return
	end

	Tycoon.hooks.passGranted = onPassGranted
	Tycoon.hooks.cosmetics = function(session)
		return Cosmetics.state(theme, session.profile, session.passes)
	end

	Tycoon.addAction("EquipTrail", function(session, data)
		local name = data.name
		if name == "" or name == nil then
			session.profile.cosmetics.trail = ""
		elseif type(name) == "string" then
			local item = c.Items[name]
			if not item or item.Kind ~= "trail" then
				return
			end
			if not Cosmetics.owns(theme, session.passes, name) then
				Tycoon.toast(session, "Unlock " .. item.Title .. " in the shop first!", "info")
				return
			end
			session.profile.cosmetics.trail = name
		else
			return
		end
		apply(session)
	end)

	Tycoon.addAction("ToggleCosmetic", function(session, data)
		local name = data.name
		local item = type(name) == "string" and c.Items[name] or nil
		if not isToggle(item) then
			return
		end
		if not Cosmetics.owns(theme, session.passes, name) then
			Tycoon.toast(session, "Unlock " .. item.Title .. " in the shop first!", "info")
			return
		end
		local value = if type(data.value) == "boolean" then data.value else not Cosmetics.toggleOn(session.profile, name)
		session.profile.cosmetics.toggles[name] = value
		apply(session)
	end)

	Players.PlayerRemoving:Connect(function(player)
		clearPieces(player)
		pieces[player] = nil
		pieceConns[player] = nil
	end)
end

return Cosmetics
