--[[
	Fx.Sprites: the Blender-rendered effect sprites (Assets.Images "vfx/<Name>").

	  Heart, StarPop, CoinSpin   full colour (leave the tint white)
	  Sparkle, SoftDot, Ring,    white: tint them with the effect colour
	  Puff, Confetti, Note
	  Sweat                      light blue

	Sprites.image(name) returns the image id ("Heart" or "vfx/Heart"), or nil when
	the asset is missing (not uploaded, rejected, or the Assets module failed to
	load). Every caller keeps its own code-drawn fallback for that case.

	Sprites.emitter(parent, name, props) makes a ParticleEmitter with the sprite and
	calm defaults: Rate 0 (call :Emit), LightEmission 0 (the sprite's paint, no
	glow), grow-then-shrink size, fade out, LockedToPart off. `props` overrides
	any emitter property.

	Sprites.billboard(parent, name, opts) is a one-off sprite pop in the world: it
	scales in (Back out), drifts by `rise`, fades and cleans itself up.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Sprites = {}

local WHITE = Color3.new(1, 1, 1)

-- Assets.Images, looked up once; nil when the generated module is missing or fails.
local images: { [string]: string }? = nil
local loaded = false

local function imageTable(): { [string]: string }?
	if not loaded then
		loaded = true
		local shared = ReplicatedStorage:FindFirstChild("Shared")
		local module = shared and shared:FindFirstChild("Assets")
		if module and module:IsA("ModuleScript") then
			local ok, result = pcall(require, module :: any)
			if ok and type(result) == "table" and type((result :: any).Images) == "table" then
				images = (result :: any).Images
			end
		end
	end
	return images
end

-- The image id of sprite `name` ("Heart" or "vfx/Heart"), or nil when missing.
function Sprites.image(name: string): string?
	local list = imageTable()
	if not list then
		return nil
	end
	local key = if string.find(name, "/", 1, true) then name else "vfx/" .. name
	local id = list[key]
	if type(id) == "string" and id ~= "" then
		return id
	end
	return nil
end

-- A ParticleEmitter showing sprite `name` under `parent` (nil when the sprite is
-- missing). Defaults: no glow, no sustained rate, 0.6-1 s lives, a soft
-- grow-then-shrink size of about `props.Size` studs, fade out, random spin.
function Sprites.emitter(parent: Instance, name: string, props: { [string]: any }?): ParticleEmitter?
	local id = Sprites.image(name)
	if not id then
		return nil
	end
	local emitter = Instance.new("ParticleEmitter")
	emitter.Name = "Sprite" .. (string.gsub(name, "^vfx/", ""))
	emitter.Texture = id
	emitter.Rate = 0
	emitter.LightEmission = 0
	emitter.LightInfluence = 0
	emitter.LockedToPart = false
	emitter.Orientation = Enum.ParticleOrientation.FacingCamera
	emitter.Color = ColorSequence.new(WHITE)
	emitter.Lifetime = NumberRange.new(0.6, 1)
	emitter.Speed = NumberRange.new(2, 4)
	emitter.Drag = 3
	emitter.SpreadAngle = Vector2.new(35, 35)
	emitter.Rotation = NumberRange.new(-180, 180)
	emitter.RotSpeed = NumberRange.new(-40, 40)
	emitter.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0),
		NumberSequenceKeypoint.new(0.15, 0.6),
		NumberSequenceKeypoint.new(0.7, 0.5),
		NumberSequenceKeypoint.new(1, 0),
	})
	emitter.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0),
		NumberSequenceKeypoint.new(0.6, 0),
		NumberSequenceKeypoint.new(1, 1),
	})
	if props then
		for key, value in props do
			(emitter :: any)[key] = value
		end
	end
	emitter.Parent = parent
	return emitter
end

export type BillboardOptions = {
	position: Vector3, -- world start point
	size: number?, -- studs (default 1.1)
	rise: Vector3?, -- world offset travelled over the life (default 3 studs up)
	life: number?, -- seconds from appearing to gone (default 1.5, at most 2)
	delay: number?, -- seconds before it appears
	color: Color3?, -- tint (white keeps the sprite's own colours)
	spin: number?, -- degrees turned over the life
	maxDistance: number?, -- studs (default 80)
}

-- A one-off sprite at `opts.position` on an attachment under `parent` (a part):
-- scales in, drifts by `rise` (Quad out), fades over the last 40% and is destroyed.
-- Returns the BillboardGui, or nil when the sprite is missing.
function Sprites.billboard(parent: BasePart, name: string, opts: BillboardOptions): BillboardGui?
	local id = Sprites.image(name)
	if not id then
		return nil
	end
	local life = math.min(opts.life or 1.5, 2)
	local delay = opts.delay or 0
	local size = opts.size or 1.1
	local rise = opts.rise or Vector3.new(0, 3, 0)
	local frame = parent.CFrame
	local start = frame:PointToObjectSpace(opts.position)

	local attachment = Instance.new("Attachment")
	attachment.Name = "SpritePop"
	attachment.Position = start
	local gui = Instance.new("BillboardGui")
	gui.Size = UDim2.fromScale(size, size)
	gui.LightInfluence = 0
	gui.MaxDistance = opts.maxDistance or 80
	gui.Adornee = attachment
	gui.Parent = attachment
	local scale = Instance.new("UIScale")
	scale.Scale = 0
	scale.Parent = gui
	local image = Instance.new("ImageLabel")
	image.Name = "Sprite"
	image.BackgroundTransparency = 1
	image.Size = UDim2.fromScale(1, 1)
	image.Image = id
	image.ImageColor3 = opts.color or WHITE
	image.ScaleType = Enum.ScaleType.Fit
	image.Rotation = (math.random() - 0.5) * 24
	image.Parent = gui
	attachment.Parent = parent

	local function play(target: Instance, info: TweenInfo, goal: { [string]: any })
		TweenService:Create(target, info, goal):Play()
	end
	play(scale, TweenInfo.new(0.28, Enum.EasingStyle.Back, Enum.EasingDirection.Out, 0, false, delay), { Scale = 1 })
	play(
		attachment,
		TweenInfo.new(life, Enum.EasingStyle.Quad, Enum.EasingDirection.Out, 0, false, delay),
		{ Position = start + frame:VectorToObjectSpace(rise) }
	)
	if opts.spin then
		play(
			image,
			TweenInfo.new(life, Enum.EasingStyle.Sine, Enum.EasingDirection.Out, 0, false, delay),
			{ Rotation = image.Rotation + opts.spin }
		)
	end
	play(
		image,
		TweenInfo.new(life * 0.4, Enum.EasingStyle.Quad, Enum.EasingDirection.In, 0, false, delay + life * 0.6),
		{ ImageTransparency = 1 }
	)
	task.delay(delay + life + 0.05, function()
		attachment:Destroy()
	end)
	return gui
end

return Sprites
