--[[
	Fx.Surge: the "golden hour hype" mood while an Aura Surge is on (x2 aura).

	The surge is a fixed slice of a server-time cycle (Economy.surgeState), so the
	look is a pure function of the server clock: a player who joins mid-surge gets
	the full look at once, and one who joins in the last second before the end
	sees it fade out like everyone else.

	While the surge look is up the client adds its own post-effects to Lighting
	(the server's ColorCorrection / Bloom / SunRays are left untouched):
	  SurgeGrade  ColorCorrectionEffect: warm peach-gold tint, more saturation
	              (with a slow, small 2.2 s pulse), a little contrast and brightness
	  SurgeBloom  BloomEffect: a soft, wide bloom on the brightest surfaces only
	  SurgeRays   SunRaysEffect: a faint sun glow
	plus large, soft gold sparkles drifting up over the local player's plot (their
	rate scaled by Fx.Budget on phones). The
	look eases in over FADE_IN seconds and out over FADE_OUT seconds, after which
	every instance is removed. No flashing: every value moves smoothly.

	It also sets the music mood (Sounds.setMood("surge") / nil) for as long as the
	surge lasts.

	The module's top level stays free of requires so the tests can load the pure
	helpers (Surge.weight, Surge.grade) without Roblox services.
]]

local Surge = {}

Surge.FADE_IN = 1.2
Surge.FADE_OUT = 1.5
Surge.PULSE_PERIOD = 2.2

-- Full-strength grade values (scaled by the surge weight).
Surge.TINT_RGB = { 255, 244, 226 }
Surge.SATURATION = 0.12
Surge.SATURATION_PULSE = 0.05
Surge.CONTRAST = 0.08
Surge.BRIGHTNESS = 0.02
Surge.BLOOM_INTENSITY = 0.15
Surge.RAYS_INTENSITY = 0.04

local function smooth(x: number): number
	local s = math.clamp(x, 0, 1)
	return s * s * (3 - 2 * s)
end

-- Strength of the surge look (0..1) from Economy.surgeState's (active, left) and the
-- surge timing: eases in over FADE_IN after the surge starts and out over FADE_OUT
-- after it ends.
function Surge.weight(active: boolean, left: number, duration: number, cycle: number): number
	if active then
		return smooth((duration - left) / Surge.FADE_IN)
	end
	local sinceEnd = (cycle - duration) - left
	return 1 - smooth(sinceEnd / Surge.FADE_OUT)
end

export type Grade = {
	tint: number, -- 0..1 blend from white toward TINT_RGB
	saturation: number,
	contrast: number,
	brightness: number,
	bloom: number,
	rays: number,
	sparkles: number, -- 0..1 share of the full sparkle rate
}

-- The post-effect values for surge weight `weight` at clock time `clock` (seconds).
function Surge.grade(weight: number, clock: number): Grade
	local pulse = math.sin(clock * 2 * math.pi / Surge.PULSE_PERIOD)
	return {
		tint = weight,
		saturation = weight * (Surge.SATURATION + Surge.SATURATION_PULSE * pulse),
		contrast = weight * Surge.CONTRAST,
		brightness = weight * Surge.BRIGHTNESS,
		bloom = weight * Surge.BLOOM_INTENSITY,
		rays = weight * Surge.RAYS_INTENSITY,
		sparkles = weight,
	}
end

-- Runtime ------------------------------------------------------------------------------

local SPARKLE_RATE = 2.5
local DOT_RATE = 1.5

function Surge.init()
	local Lighting = game:GetService("Lighting")
	local ReplicatedStorage = game:GetService("ReplicatedStorage")
	local RunService = game:GetService("RunService")
	local Workspace = game:GetService("Workspace")

	local Economy = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Economy")) :: any
	local State = require(script.Parent.Parent.State) :: any
	local Sounds = require(script.Parent.Parent.Sounds) :: any
	local Sprites = require(script.Parent.Sprites) :: any
	local Budget = require(script.Parent.Budget) :: any

	local WHITE = Color3.new(1, 1, 1)
	local TINT = Color3.fromRGB(Surge.TINT_RGB[1], Surge.TINT_RGB[2], Surge.TINT_RGB[3])

	local grade: ColorCorrectionEffect? = nil
	local bloom: BloomEffect? = nil
	local rays: SunRaysEffect? = nil
	local sparkPart: BasePart? = nil
	local emitters: { [ParticleEmitter]: number } = {} -- emitter -> full rate
	local sparkPlot: number? = nil
	local nextSparkTry = 0
	local mood: string? = nil

	-- Stops new sparkles; the ones in the air finish their drift before the box goes.
	local function clearSparkles()
		local part = sparkPart
		if part then
			for emitter in emitters do
				emitter.Rate = 0
			end
			task.delay(6, function()
				part:Destroy()
			end)
		end
		sparkPart = nil
		sparkPlot = nil
		table.clear(emitters)
	end

	local function clearEffects()
		if grade then
			grade:Destroy()
		end
		if bloom then
			bloom:Destroy()
		end
		if rays then
			rays:Destroy()
		end
		grade, bloom, rays = nil, nil, nil
		clearSparkles()
	end

	local function ensureEffects()
		if not grade then
			local cc = Instance.new("ColorCorrectionEffect")
			cc.Name = "SurgeGrade"
			cc.Parent = Lighting
			grade = cc
		end
		if not bloom then
			local b = Instance.new("BloomEffect")
			b.Name = "SurgeBloom"
			b.Intensity = 0
			b.Size = 36
			b.Threshold = 1.5
			b.Parent = Lighting
			bloom = b
		end
		if not rays then
			local r = Instance.new("SunRaysEffect")
			r.Name = "SurgeRays"
			r.Intensity = 0
			r.Spread = 0.5
			r.Parent = Lighting
			rays = r
		end
	end

	-- A box over the local player's plot floor that slowly releases gold sparkles.
	local function ensureSparkles(now: number)
		local data = State.data
		local index = data and data.plotIndex
		if sparkPart and sparkPlot == index then
			return
		end
		if now < nextSparkTry then
			return
		end
		nextSparkTry = now + 1
		clearSparkles()
		if type(index) ~= "number" then
			return
		end
		local map = Workspace:FindFirstChild("Map")
		local plot = map and map:FindFirstChild("Plot" .. index)
		local floor = plot and plot:FindFirstChild("Floor", true)
		if not (floor and floor:IsA("BasePart")) then
			return
		end
		local part = Instance.new("Part")
		part.Name = "SurgeSparkles"
		part.Anchored = true
		part.CanCollide = false
		part.CanQuery = false
		part.CanTouch = false
		part.CastShadow = false
		part.Transparency = 1
		part.Size = Vector3.new(floor.Size.X * 0.9, 1, floor.Size.Z * 0.9)
		part.CFrame = floor.CFrame * CFrame.new(0, floor.Size.Y / 2 + 1.5, 0)
		local gold = ColorSequence.new(Color3.fromRGB(255, 214, 120), Color3.fromRGB(255, 240, 205))
		local function fadeInOut(peak: number): NumberSequence
			return NumberSequence.new({
				NumberSequenceKeypoint.new(0, 1),
				NumberSequenceKeypoint.new(0.2, peak),
				NumberSequenceKeypoint.new(0.75, peak),
				NumberSequenceKeypoint.new(1, 1),
			})
		end
		local function sizeCurve(size: number): NumberSequence
			return NumberSequence.new({
				NumberSequenceKeypoint.new(0, size * 0.4),
				NumberSequenceKeypoint.new(0.3, size),
				NumberSequenceKeypoint.new(1, size * 0.7),
			})
		end
		local common = {
			Shape = Enum.ParticleEmitterShape.Box,
			ShapeStyle = Enum.ParticleEmitterShapeStyle.Volume,
			EmissionDirection = Enum.NormalId.Top,
			Lifetime = NumberRange.new(4, 6),
			Speed = NumberRange.new(1.2, 2.4),
			Drag = 0.2,
			Acceleration = Vector3.new(0, 0.3, 0),
			SpreadAngle = Vector2.new(20, 20),
			RotSpeed = NumberRange.new(-20, 20),
			Color = gold,
		}
		local function add(name: string, rate: number, size: number, peak: number)
			local props = table.clone(common) :: { [string]: any }
			props.Size = sizeCurve(size)
			props.Transparency = fadeInOut(peak)
			local emitter = Sprites.emitter(part, name, props)
			if emitter then
				emitters[emitter] = rate
			end
		end
		add("Sparkle", SPARKLE_RATE, 1.8, 0.2)
		add("SoftDot", DOT_RATE, 3, 0.55)
		part.Parent = Workspace.CurrentCamera or Workspace
		sparkPart = part
		sparkPlot = index
	end

	RunService.Heartbeat:Connect(function()
		local now = Workspace:GetServerTimeNow()
		-- A player still in the tutorial has no surge (Economy.surgeFor): no grade, no
		-- sparkles, no music, not even the fade-out of one that just ended.
		local data = State.data
		local met = data ~= nil and data.tutorialDone == true
		local active, left = Economy.surgeFor(now, met)
		local wantMood = if active then "surge" else nil
		if wantMood ~= mood then
			mood = wantMood
			Sounds.setMood(mood)
		end

		local weight = if met then Surge.weight(active, left, Economy.SURGE_DURATION, Economy.SURGE_CYCLE) else 0
		if weight <= 0.001 then
			if grade or sparkPart then
				clearEffects()
			end
			return
		end
		ensureEffects()
		local g = Surge.grade(weight, os.clock())
		local cc = grade :: ColorCorrectionEffect
		cc.TintColor = WHITE:Lerp(TINT, g.tint)
		cc.Saturation = g.saturation
		cc.Contrast = g.contrast
		cc.Brightness = g.brightness
		local b = bloom :: BloomEffect
		b.Intensity = g.bloom
		local r = rays :: SunRaysEffect
		r.Intensity = g.rays

		ensureSparkles(os.clock())
		local budget = Budget.scale() -- fewer drifting sparkles on phones (Fx.Budget)
		for emitter, rate in emitters do
			emitter.Rate = rate * g.sparkles * budget
		end
	end)
end

return Surge
