--[[
	CharacterFactory: builds the blocky unit figures from a theme "look" table.
	Used by the server (display shelves) and the client (Index / reward
	viewports). Everything is made from plain parts, so no uploaded assets are
	needed.

	Look fields (all optional except colours):
	  skin, shirt, pants : Color3
	  face               : string drawn on the head (emoji or text)
	  faceColor          : Color3 for text faces
	  material           : Enum.Material name for the body ("Metal", "Glass", ...)
	  buff               : 0..1 extra width on torso/arms
	  scale              : overall size multiplier
	  jaw                : true for a wide chin block
	  acc                : list of accessory names (see ACCESSORIES)
	  accColor           : Color3 for accessories
	  aura               : Color3 particle aura
	  sparkles           : true for a Sparkles effect
	  fire               : Color3 fire effect
	  glow               : Color3 point light
]]

local CharacterFactory = {}

export type Look = {
	skin: Color3,
	shirt: Color3,
	pants: Color3,
	face: string?,
	faceColor: Color3?,
	faceFont: Enum.Font?,
	material: string?,
	buff: number?,
	scale: number?,
	jaw: boolean?,
	acc: { string }?,
	accColor: Color3?,
	aura: Color3?,
	sparkles: boolean?,
	fire: Color3?,
	glow: Color3?,
}

local function part(model: Model, name: string, size: Vector3, cframe: CFrame, color: Color3, material: Enum.Material?): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Size = size
	p.CFrame = cframe
	p.Color = color
	p.Material = material or Enum.Material.SmoothPlastic
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Parent = model
	return p
end

local function materialFrom(name: string?): Enum.Material
	if name then
		local ok, value = pcall(function()
			return (Enum.Material :: any)[name]
		end)
		if ok and value then
			return value
		end
	end
	return Enum.Material.SmoothPlastic
end

type Ctx = {
	model: Model,
	head: Part,
	torso: Part,
	headTop: number,
	torsoWidth: number,
	color: Color3,
}

local ACCESSORIES: { [string]: (Ctx) -> () } = {}

ACCESSORIES.Cap = function(c)
	local y = c.headTop
	part(c.model, "Cap", Vector3.new(1.4, 0.4, 1.4), CFrame.new(0, y + 0.1, 0), c.color)
	part(c.model, "Brim", Vector3.new(1.3, 0.12, 0.7), CFrame.new(0, y - 0.05, -0.95), c.color)
end

ACCESSORIES.Headband = function(c)
	part(c.model, "Headband", Vector3.new(1.42, 0.25, 1.42), CFrame.new(0, c.headTop - 0.35, 0), c.color)
end

ACCESSORIES.Shades = function(c)
	local y = c.headTop - 0.6
	part(c.model, "Shades", Vector3.new(1.36, 0.28, 0.12), CFrame.new(0, y, -0.68), Color3.new(0.05, 0.05, 0.05), Enum.Material.Glass)
end

ACCESSORIES.Visor = function(c)
	local y = c.headTop - 0.6
	part(c.model, "Visor", Vector3.new(1.4, 0.3, 0.12), CFrame.new(0, y, -0.68), c.color, Enum.Material.Neon)
end

ACCESSORIES.Chain = function(c)
	local gold = Color3.fromRGB(255, 205, 60)
	part(c.model, "ChainBand", Vector3.new(c.torsoWidth * 0.7, 0.14, 0.08), CFrame.new(0, 3.75, -0.55), gold, Enum.Material.Metal)
	local medal = part(
		c.model,
		"Medal",
		Vector3.new(0.1, 0.55, 0.55),
		CFrame.new(0, 3.3, -0.56) * CFrame.Angles(0, math.rad(90), 0),
		gold,
		Enum.Material.Metal
	)
	medal.Shape = Enum.PartType.Cylinder
end

ACCESSORIES.Crown = function(c)
	local y = c.headTop
	local gold = c.color
	part(c.model, "CrownBase", Vector3.new(1.45, 0.35, 1.45), CFrame.new(0, y + 0.15, 0), gold, Enum.Material.Metal)
	for i = 0, 3 do
		local angle = math.rad(i * 90 + 45)
		local spike = part(
			c.model,
			"Spike",
			Vector3.new(0.3, 0.45, 0.3),
			CFrame.new(math.cos(angle) * 0.55, y + 0.5, math.sin(angle) * 0.55),
			gold,
			Enum.Material.Metal
		)
		spike.Shape = Enum.PartType.Ball
	end
end

ACCESSORIES.Halo = function(c)
	local y = c.headTop + 0.6
	for i = 0, 9 do
		local angle = math.rad(i * 36)
		local bead = part(
			c.model,
			"Halo",
			Vector3.new(0.22, 0.22, 0.22),
			CFrame.new(math.cos(angle) * 0.75, y, math.sin(angle) * 0.75),
			c.color,
			Enum.Material.Neon
		)
		bead.Shape = Enum.PartType.Ball
	end
end

ACCESSORIES.Horns = function(c)
	local y = c.headTop + 0.15
	for side = -1, 1, 2 do
		local horn = part(
			c.model,
			"Horn",
			Vector3.new(0.25, 0.7, 0.25),
			CFrame.new(side * 0.5, y, 0) * CFrame.Angles(0, 0, math.rad(-side * 25)),
			c.color,
			Enum.Material.Neon
		)
		horn.Shape = Enum.PartType.Block
	end
end

ACCESSORIES.Antenna = function(c)
	local y = c.headTop
	part(c.model, "AntennaRod", Vector3.new(0.1, 0.8, 0.1), CFrame.new(0, y + 0.4, 0), Color3.fromRGB(80, 80, 90), Enum.Material.Metal)
	local tip = part(c.model, "AntennaTip", Vector3.new(0.3, 0.3, 0.3), CFrame.new(0, y + 0.85, 0), c.color, Enum.Material.Neon)
	tip.Shape = Enum.PartType.Ball
end

ACCESSORIES.Cape = function(c)
	part(
		c.model,
		"Cape",
		Vector3.new(c.torsoWidth * 0.95, 2.6, 0.1),
		CFrame.new(0, 2.75, 0.6) * CFrame.Angles(math.rad(-8), 0, 0),
		c.color,
		Enum.Material.Fabric
	)
end

ACCESSORIES.Wings = function(c)
	for side = -1, 1, 2 do
		part(
			c.model,
			"Wing",
			Vector3.new(2.2, 1.6, 0.1),
			CFrame.new(side * (c.torsoWidth / 2 + 0.7), 3.4, 0.75) * CFrame.Angles(0, math.rad(side * 25), math.rad(side * 20)),
			c.color,
			Enum.Material.Neon
		).Transparency =
			0.25
	end
end

ACCESSORIES.Backpack = function(c)
	part(c.model, "Pack", Vector3.new(c.torsoWidth * 0.7, 1.4, 0.6), CFrame.new(0, 3, 0.8), c.color, Enum.Material.Metal)
end

ACCESSORIES.Shoulders = function(c)
	for side = -1, 1, 2 do
		part(
			c.model,
			"Pad",
			Vector3.new(1.3, 0.4, 1.3),
			CFrame.new(side * (c.torsoWidth / 2 + 0.45), 4.05, 0),
			c.color,
			Enum.Material.Metal
		)
	end
end

-- Builds a model standing on y = 0 at the origin, facing -Z.
function CharacterFactory.build(look: Look, name: string?): Model
	local model = Instance.new("Model")
	model.Name = name or "Unit"

	local buff = look.buff or 0
	local bodyMaterial = materialFrom(look.material)
	local torsoWidth = 2 + buff * 0.8
	local armWidth = 1 + buff * 0.45

	-- Root sits at the feet so PivotTo/ScaleTo keep the unit standing on the floor.
	local root = part(model, "Root", Vector3.new(0.2, 0.2, 0.2), CFrame.new(0, 0, 0), Color3.new(1, 1, 1))
	root.Transparency = 1
	model.PrimaryPart = root

	part(model, "LeftLeg", Vector3.new(0.95, 2, 1), CFrame.new(-0.5, 1, 0), look.pants, bodyMaterial)
	part(model, "RightLeg", Vector3.new(0.95, 2, 1), CFrame.new(0.5, 1, 0), look.pants, bodyMaterial)
	local torso = part(model, "Torso", Vector3.new(torsoWidth, 2, 1), CFrame.new(0, 3, 0), look.shirt, bodyMaterial)
	local armX = torsoWidth / 2 + armWidth / 2
	part(model, "LeftArm", Vector3.new(armWidth, 2, 1), CFrame.new(-armX, 3, 0), look.skin, bodyMaterial)
	part(model, "RightArm", Vector3.new(armWidth, 2, 1), CFrame.new(armX, 3, 0), look.skin, bodyMaterial)

	local head = part(model, "Head", Vector3.new(1.3, 1.3, 1.3), CFrame.new(0, 4.65, 0), look.skin, bodyMaterial)
	local headTop = 5.3
	if look.jaw then
		part(model, "Jaw", Vector3.new(1.45, 0.45, 1.2), CFrame.new(0, 4.1, -0.05), look.skin, bodyMaterial)
	end

	if look.face and look.face ~= "" then
		local gui = Instance.new("SurfaceGui")
		gui.Name = "Face"
		gui.Face = Enum.NormalId.Front
		gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
		gui.PixelsPerStud = 60
		gui.LightInfluence = 0
		gui.Parent = head
		local label = Instance.new("TextLabel")
		label.BackgroundTransparency = 1
		label.Size = UDim2.fromScale(1, 1)
		label.Text = look.face
		label.TextScaled = true
		label.Font = look.faceFont or Enum.Font.GothamBold
		label.TextColor3 = look.faceColor or Color3.new(0.1, 0.1, 0.1)
		label.Parent = gui
	end

	local ctx: Ctx = {
		model = model,
		head = head,
		torso = torso,
		headTop = headTop,
		torsoWidth = torsoWidth,
		color = look.accColor or Color3.fromRGB(255, 205, 60),
	}
	local accessories: { string } = look.acc or {}
	for _, accName in accessories do
		local builder = ACCESSORIES[accName]
		if builder then
			builder(ctx)
		end
	end

	if look.aura then
		local emitter = Instance.new("ParticleEmitter")
		emitter.Name = "Aura"
		emitter.Color = ColorSequence.new(look.aura)
		emitter.LightEmission = 1
		emitter.Size = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.6),
			NumberSequenceKeypoint.new(1, 0),
		})
		emitter.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.2),
			NumberSequenceKeypoint.new(1, 1),
		})
		emitter.Lifetime = NumberRange.new(0.8, 1.4)
		emitter.Rate = 10
		emitter.Speed = NumberRange.new(1.5, 3)
		emitter.SpreadAngle = Vector2.new(180, 180)
		emitter.Acceleration = Vector3.new(0, 3, 0)
		emitter.Parent = torso
	end
	if look.sparkles then
		local sparkles = Instance.new("Sparkles")
		sparkles.SparkleColor = look.aura or Color3.new(1, 1, 1)
		sparkles.Parent = torso
	end
	if look.fire then
		local fire = Instance.new("Fire")
		fire.Color = look.fire
		fire.SecondaryColor = Color3.new(1, 1, 1)
		fire.Size = 4
		fire.Heat = 6
		fire.Parent = torso
	end
	if look.glow or look.aura then
		local light = Instance.new("PointLight")
		light.Color = look.glow or look.aura :: Color3
		light.Brightness = 1.5
		light.Range = 8
		light.Parent = torso
	end

	local scale = look.scale or 1
	if scale ~= 1 then
		model:ScaleTo(scale)
	end
	return model
end

-- Turns a model into a black silhouette (for undiscovered Index entries).
function CharacterFactory.silhouette(model: Model)
	-- Collect first, destroy after, so we never visit children of a destroyed instance.
	local remove: { Instance } = {}
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then
			if d.Transparency < 1 then
				d.Color = Color3.fromRGB(15, 15, 20)
				d.Material = Enum.Material.SmoothPlastic
				d.Transparency = 0
			end
		elseif d:IsA("ParticleEmitter") or d:IsA("Sparkles") or d:IsA("Fire") or d:IsA("Light") or d:IsA("SurfaceGui") then
			table.insert(remove, d)
		end
	end
	for _, d in remove do
		d:Destroy()
	end
end

-- Height of the built model (for placing labels above it).
function CharacterFactory.height(look: Look): number
	local h = 5.3
	local acc = look.acc or {}
	if table.find(acc, "Halo") then
		h += 0.8
	elseif table.find(acc, "Crown") or table.find(acc, "Antenna") then
		h += 0.6
	end
	return h * (look.scale or 1)
end

return CharacterFactory
