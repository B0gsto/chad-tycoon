--[[
	ShopScenes: the little looping animations on the shop's pass banners and pack cards.

	  ShopScenes.pass(stage, name, tint)  one banner scene per game pass key (AutoLoot, AutoMerge,
	                                      AutoCash, DoubleAura, DoubleMoney, PremiumUnlocker,
	                                      CrateKey, StarterPack, AllCosmetics; anything else
	                                      gets a sparkling star)
	  ShopScenes.pack(stage, kind, index) a pack card scene: kind "Money" | "Aura",
	                                      index 1..4 (bigger = bigger pile, more particles)

	Both return a Scene { play, stop, celebrate, destroy }:
	  play()       starts the idle loop (call while the shop is open and the scene shows)
	  stop()       pauses every tween and loop and puts the scene back in its resting pose
	  celebrate()  a one-shot burst (purchase landed), then back to idle
	  destroy()    disconnects everything and destroys the scene's GUI

	All GUI lives in one transparent "Scene" canvas inside `stage`, letterboxed to the
	design aspect (pass 230x120, pack 1:1) and sized with Scale only, so the caller sizes
	(and clips) the stage. Motion is TweenService tweens plus at most one Heartbeat per
	scene (connected only while something is flying). In the Lune preview (TweenInfo
	stubbed) nothing animates: scenes show a still frame. Missing sprites or atlas icons
	fall back to plain rounded Frames and shape icons.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local OrbLook = require(ReplicatedStorage.Shared.OrbLook)
local Kit = require(script.Parent.Kit)
local Sprites = require(script.Parent.Parent.Fx.Sprites)

local Theme = Kit.Theme
local C = Kit.C
local F = Kit.F
local WC = Theme.World

-- Same test as Kit: the preview exporter stubs TweenInfo with a plain table.
local PREVIEW = typeof(TweenInfo.new(0)) ~= "TweenInfo"

local WHITE = Color3.new(1, 1, 1)
local ZERO = UDim2.fromScale(0, 0)
local FULL = UDim2.fromScale(1, 1)
local CENTER = Vector2.new(0.5, 0.5)
local BOTTOM = Vector2.new(0.5, 1)

local QUAD = Enum.EasingStyle.Quad
local SINE = Enum.EasingStyle.Sine
local BACK = Enum.EasingStyle.Back
local LINEAR = Enum.EasingStyle.Linear
local BOUNCE = Enum.EasingStyle.Bounce
local ELASTIC = Enum.EasingStyle.Elastic
local IN = Enum.EasingDirection.In
local OUT = Enum.EasingDirection.Out
local INOUT = Enum.EasingDirection.InOut

local PASS_ASPECT = 230 / 120
local PACK_ASPECT = 1

local HOT_PINK = Theme.OrbColors[2] or WC.Pink

-- Shared.Assets (atlas cells), for swapping a crate icon's image in place; nil when missing.
local Assets: any = (function()
	local shared = ReplicatedStorage:FindFirstChild("Shared")
	local module = shared and shared:FindFirstChild("Assets")
	if module and module:IsA("ModuleScript") then
		local ok, result = pcall(require, module :: any)
		if ok and type(result) == "table" then
			return result
		end
	end
	return nil
end)()

local COIN_IMAGE = Sprites.image("CoinSpin")

local ShopScenes = {}

export type Scene = { play: () -> (), stop: () -> (), celebrate: () -> (), destroy: () -> () }

type Flight = { gui: Instance, t0: number, dur: number, step: (number) -> (), done: (() -> ())? }
type Pool = { items: { GuiObject }, busy: { [GuiObject]: boolean } }
type Ctx = {
	root: Frame,
	aspect: number,
	gen: number,
	playing: boolean,
	dead: boolean,
	tweens: { Tween },
	threads: { thread },
	flights: { Flight },
	temps: { Instance },
	pools: { Pool },
	heartbeat: RBXScriptConnection?,
	destroying: RBXScriptConnection?,
	onPlay: { () -> () },
	onRest: { () -> () },
	onCelebrate: { () -> () },
}

-- Scene runtime -----------------------------------------------------------------------

local function newCtx(stage: Frame, aspect: number): Ctx
	local root = Kit.new("Frame", {
		Name = "Scene",
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Size = FULL,
		Position = UDim2.fromScale(0.5, 0.5),
		AnchorPoint = CENTER,
		Parent = stage,
	})
	Kit.new("UIAspectRatioConstraint", {
		AspectRatio = aspect,
		AspectType = Enum.AspectType.FitWithinMaxSize,
		DominantAxis = Enum.DominantAxis.Width,
		Parent = root,
	})
	return {
		root = root,
		aspect = aspect,
		gen = 0,
		playing = false,
		dead = false,
		tweens = {},
		threads = {},
		flights = {},
		temps = {},
		pools = {},
		heartbeat = nil,
		destroying = nil,
		onPlay = {},
		onRest = {},
		onCelebrate = {},
	}
end

local function alive(ctx: Ctx, gen: number): boolean
	return not ctx.dead and ctx.gen == gen and ctx.root.Parent ~= nil
end

local function track(ctx: Ctx, thread: thread)
	if #ctx.threads > 32 then
		local live = {}
		for _, th in ctx.threads do
			if coroutine.status(th) ~= "dead" then
				table.insert(live, th)
			end
		end
		ctx.threads = live
	end
	table.insert(ctx.threads, thread)
end

-- A tween the scene owns (cancelled by stop).
local function tw(
	ctx: Ctx,
	obj: Instance,
	time: number,
	props: { [string]: any },
	style: Enum.EasingStyle?,
	direction: Enum.EasingDirection?,
	repeats: number?,
	reverses: boolean?
): Tween
	local info = TweenInfo.new(time, style or QUAD, direction or OUT, repeats or 0, reverses or false, 0)
	local tween = TweenService:Create(obj, info, props)
	tween:Play()
	if #ctx.tweens > 40 then
		local live = {}
		for _, t in ctx.tweens do
			local state = t.PlaybackState
			if state == Enum.PlaybackState.Playing or state == Enum.PlaybackState.Delayed or state == Enum.PlaybackState.Begin then
				table.insert(live, t)
			end
		end
		ctx.tweens = live
	end
	table.insert(ctx.tweens, tween)
	return tween
end

-- Runs `fn` after `t` seconds unless the scene was stopped or replayed meanwhile.
local function later(ctx: Ctx, t: number, fn: () -> ())
	local gen = ctx.gen
	track(
		ctx,
		task.delay(t, function()
			if alive(ctx, gen) then
				fn()
			end
		end)
	)
end

-- Repeats `body(nap)` while the scene plays; `nap(t)` sleeps and returns false once stopped.
local function loop(ctx: Ctx, body: ((number) -> boolean) -> (), firstDelay: number?)
	local gen = ctx.gen
	local function nap(t: number): boolean
		task.wait(t)
		return alive(ctx, gen)
	end
	track(
		ctx,
		task.spawn(function()
			if firstDelay and not nap(firstDelay) then
				return
			end
			while alive(ctx, gen) do
				local before = os.clock()
				body(nap)
				if os.clock() == before and not nap(0.5) then
					return
				end
			end
		end)
	)
end

local halt: (Ctx) -> ()

local function stepFlights(ctx: Ctx)
	if ctx.dead or ctx.root.Parent == nil then
		halt(ctx)
		return
	end
	local now = os.clock()
	local list = ctx.flights
	local i = 1
	while i <= #list do
		local flight = list[i]
		local a = math.clamp((now - flight.t0) / flight.dur, 0, 1)
		flight.step(a)
		if a >= 1 then
			table.remove(list, i)
			if flight.done then
				flight.done()
			end
		else
			i += 1
		end
	end
	if #ctx.flights == 0 and ctx.heartbeat then
		ctx.heartbeat:Disconnect()
		ctx.heartbeat = nil
	end
end

-- Drives `gui` along `step(alpha 0..1)` for `dur` seconds on the scene's one Heartbeat.
local function fly(ctx: Ctx, gui: Instance, dur: number, step: (number) -> (), done: (() -> ())?)
	if ctx.dead or PREVIEW then
		return
	end
	table.insert(ctx.flights, { gui = gui, t0 = os.clock(), dur = math.max(dur, 0.01), step = step, done = done })
	step(0)
	if not ctx.heartbeat then
		ctx.heartbeat = RunService.Heartbeat:Connect(function()
			stepFlights(ctx)
		end)
	end
end

local function pool(ctx: Ctx, items: { GuiObject }): Pool
	local p: Pool = { items = items, busy = {} }
	table.insert(ctx.pools, p)
	return p
end

local function take(p: Pool): GuiObject?
	for _, gui in p.items do
		if not p.busy[gui] then
			p.busy[gui] = true
			gui.Visible = true
			return gui
		end
	end
	return nil
end

local function free(p: Pool, gui: GuiObject)
	p.busy[gui] = nil
	gui.Visible = false
end

-- A short-lived object (burst piece); destroyed by stop if still around.
local function temp(ctx: Ctx, inst: Instance)
	if #ctx.temps > 16 then
		local live = {}
		for _, t in ctx.temps do
			if t.Parent ~= nil then
				table.insert(live, t)
			end
		end
		ctx.temps = live
	end
	table.insert(ctx.temps, inst)
end

halt = function(ctx: Ctx)
	ctx.gen += 1
	ctx.playing = false
	local current = coroutine.running()
	for _, th in ctx.threads do
		if th ~= current and coroutine.status(th) ~= "dead" then
			pcall(task.cancel, th)
		end
	end
	table.clear(ctx.threads)
	for _, tween in ctx.tweens do
		tween:Cancel()
	end
	table.clear(ctx.tweens)
	table.clear(ctx.flights)
	if ctx.heartbeat then
		ctx.heartbeat:Disconnect()
		ctx.heartbeat = nil
	end
	for _, inst in ctx.temps do
		inst:Destroy()
	end
	table.clear(ctx.temps)
	for _, p in ctx.pools do
		for _, gui in p.items do
			p.busy[gui] = nil
			gui.Visible = false
		end
	end
	if not ctx.dead and ctx.root.Parent ~= nil then
		for _, fn in ctx.onRest do
			fn()
		end
	end
end

local function finish(ctx: Ctx): Scene
	-- Resting pose from the start (the preview still frame too).
	for _, fn in ctx.onRest do
		fn()
	end
	local scene: Scene
	local function destroy()
		if ctx.dead then
			return
		end
		ctx.dead = true
		halt(ctx)
		if ctx.destroying then
			ctx.destroying:Disconnect()
			ctx.destroying = nil
		end
		ctx.root:Destroy()
	end
	if not PREVIEW then
		pcall(function()
			ctx.destroying = ctx.root.Destroying:Connect(function()
				if not ctx.dead then
					ctx.dead = true
					halt(ctx)
				end
			end)
		end)
	end
	scene = {
		play = function()
			if ctx.dead or ctx.playing then
				return
			end
			ctx.playing = true
			if PREVIEW then
				return
			end
			ctx.gen += 1
			for _, fn in ctx.onPlay do
				fn()
			end
		end,
		stop = function()
			if not ctx.dead then
				halt(ctx)
			end
		end,
		celebrate = function()
			if ctx.dead or PREVIEW or ctx.root.Parent == nil then
				return
			end
			for _, fn in ctx.onCelebrate do
				fn()
			end
		end,
		destroy = destroy,
	}
	return scene
end

-- GUI helpers ---------------------------------------------------------------------------

-- A square `s` stage-heights on a side.
local function sq(ctx: Ctx, s: number): UDim2
	return UDim2.fromScale(s / ctx.aspect, s)
end

-- A box `w` by `h` stage-heights.
local function box(ctx: Ctx, w: number, h: number): UDim2
	return UDim2.fromScale(w / ctx.aspect, h)
end

local function at(x: number, y: number): UDim2
	return UDim2.fromScale(x, y)
end

-- An instance with transparent, centred GUI defaults, then `props`, then the parent.
local function node(className: string, parent: Instance, props: { [string]: any }): any
	local inst: any = Instance.new(className)
	if inst:IsA("GuiObject") then
		inst.BackgroundTransparency = 1
		inst.BorderSizePixel = 0
		inst.AnchorPoint = CENTER
	end
	for key, value in props do
		inst[key] = value
	end
	inst.Parent = parent
	return inst
end

-- Candy plastic fill: lighter top, the colour below, optional chunky outline.
-- radius < 0 = fully round.
local function paint(f: GuiObject, color: Color3, radius: number?, strokeColor: Color3?, thickness: number?): GuiObject
	f.BackgroundColor3 = WHITE
	f.BackgroundTransparency = 0
	if radius then
		if radius < 0 then
			Kit.round(f)
		else
			Kit.corner(f, radius)
		end
	end
	Kit.gradient(f, Kit.lighten(color, 0.32), Kit.darken(color, 0.04))
	if strokeColor then
		Kit.new("UIStroke", {
			Color = strokeColor,
			Thickness = thickness or 2,
			ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
			LineJoinMode = Enum.LineJoinMode.Round,
			Parent = f,
		})
	end
	return f
end

-- A Blender sprite (white ones tinted `color`), or a rounded Frame stand-in.
local function sprite(parent: Instance, name: string, color: Color3?, props: { [string]: any }): GuiObject
	local id = Sprites.image(name)
	local tint = color or WHITE
	local gui: any
	if id then
		gui = node("ImageLabel", parent, { Name = name, Image = id, ImageColor3 = tint, ScaleType = Enum.ScaleType.Fit })
	else
		gui = node("Frame", parent, { Name = name, BackgroundColor3 = tint, BackgroundTransparency = 0 })
		if name == "Ring" then
			gui.BackgroundTransparency = 1
			Kit.round(gui)
			Kit.new("UIStroke", { Color = tint, Thickness = 3, Parent = gui })
			gui:SetAttribute("StrokeAlpha", true)
		elseif name == "Sparkle" or name == "StarPop" then
			Kit.corner(gui, 3)
			gui.Rotation = 45
		elseif name == "Confetti" then
			Kit.corner(gui, 2)
		else
			Kit.round(gui)
		end
	end
	for key, value in props do
		gui[key] = value
	end
	return gui
end

local function alphaTarget(gui: Instance): (Instance, string)
	if gui:IsA("ImageLabel") then
		return gui, "ImageTransparency"
	end
	if gui:GetAttribute("StrokeAlpha") then
		local stroke = gui:FindFirstChildOfClass("UIStroke")
		if stroke then
			return stroke, "Transparency"
		end
	end
	return gui, "BackgroundTransparency"
end

local function setAlpha(gui: Instance, a: number)
	local inst, prop = alphaTarget(gui);
	(inst :: any)[prop] = a
end

local function fade(ctx: Ctx, gui: Instance, time: number, a: number, style: Enum.EasingStyle?, direction: Enum.EasingDirection?)
	local inst, prop = alphaTarget(gui)
	return tw(ctx, inst, time, { [prop] = a }, style, direction)
end

local function hasArt(name: string): boolean
	return Kit.hasImageIcon(name) or Kit.ICONS[name] ~= nil
end

local function pick(names: { string }): string
	for _, name in names do
		if hasArt(name) then
			return name
		end
	end
	return names[#names]
end

-- The first available icon of `names` (atlas art, else a shape icon tinted `color`).
local function icon(parent: Instance, names: { string }, color: Color3?, props: { [string]: any }): Frame
	local f = Kit.icon(parent, pick(names), 64, color, {
		Name = props.Name,
		Position = props.Position or at(0.5, 0.5),
		AnchorPoint = props.AnchorPoint or CENTER,
		ZIndex = props.ZIndex or 1,
	})
	f.Size = props.Size or FULL
	if props.Visible ~= nil then
		f.Visible = props.Visible
	end
	return f
end

-- Swaps the atlas cell an image icon (and its shade) shows, keeping the frame.
local function retexture(iconFrame: Instance, name: string)
	local icons = Assets and Assets.Icons
	local entry = if type(icons) == "table" then icons[name] else nil
	if type(entry) ~= "table" or type(entry.image) ~= "string" then
		return
	end
	for _, childName in { "Image", "Shade" } do
		local image = iconFrame:FindFirstChild(childName)
		if image and image:IsA("ImageLabel") then
			image.Image = entry.image
			image.ImageRectOffset = Vector2.new(tonumber(entry.x) or 0, tonumber(entry.y) or 0)
			image.ImageRectSize = Vector2.new(tonumber(entry.w) or 0, tonumber(entry.h) or 0)
		end
	end
end

-- A dark copy of `gui`'s image (the ImageLabel itself, or a Kit.icon's "Image") a little
-- below-right of it: a drop shadow, so the art reads on light and dark stage tints alike.
local function shade(gui: Instance, alpha: number?)
	local found = if gui:IsA("ImageLabel") then gui else gui:FindFirstChild("Image")
	if not found or not found:IsA("ImageLabel") then
		return
	end
	local image = found :: ImageLabel
	local copy = image:Clone()
	copy.Name = "Shade"
	copy.ImageColor3 = WC.Ink
	copy.ImageTransparency = alpha or 0.45
	copy.Position = image.Position + UDim2.fromScale(0.03, 0.06)
	copy.ZIndex = math.max(image.ZIndex - 1, 1)
	copy.Parent = image.Parent
end

-- The gold coin: the Blender CoinSpin sprite, or the shape coin. `shaded` wraps it in a
-- Frame with a drop shadow (size, move and pop the returned wrapper).
local function coin(parent: Instance, props: { [string]: any }, shaded: boolean?): GuiObject
	if COIN_IMAGE then
		local gui: any
		if shaded then
			gui = node("Frame", parent, { Name = "Coin" })
			local image = node("ImageLabel", gui, {
				Name = "Image",
				Image = COIN_IMAGE,
				ScaleType = Enum.ScaleType.Fit,
				Size = FULL,
				Position = at(0.5, 0.5),
				ZIndex = props.ZIndex or 1,
			})
			shade(image)
		else
			gui = node("ImageLabel", parent, { Name = "Coin", Image = COIN_IMAGE, ScaleType = Enum.ScaleType.Fit })
		end
		for key, value in props do
			gui[key] = value
		end
		return gui
	end
	local f = icon(parent, { "Coin" }, C.Gold, props)
	if shaded then
		shade(f)
	end
	return f
end

-- A glossy candy aura ball.
local function orb(parent: Instance, color: Color3, props: { [string]: any }): GuiObject
	local f = node("Frame", parent, props)
	paint(f, Kit.lighten(color, 0.08), -1, Kit.darken(color, 0.38), 1.5)
	return f
end

-- Chunky display text (sticker style): coloured fill, thick navy outline.
local function sticker(parent: Instance, text: string, color: Color3, props: { [string]: any }, thickness: number?): TextLabel
	local label = node("TextLabel", parent, {
		Text = text,
		Font = F.Display,
		TextScaled = true,
		TextColor3 = color,
	})
	for key, value in props do
		label[key] = value
	end
	Kit.new("UIStroke", {
		Color = WC.Ink,
		Thickness = thickness or 2.5,
		LineJoinMode = Enum.LineJoinMode.Round,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual,
		Parent = label,
	})
	return label
end

-- Sparkle twinkle: scales in with a quarter spin (Back overshoot ~10 %), holds, scales out.
local function twinkle(ctx: Ctx, gui: GuiObject, size: UDim2, hold: number?)
	gui.Visible = true
	gui.Size = ZERO
	gui.Rotation = 0
	tw(ctx, gui, 0.18, { Size = size }, BACK, OUT)
	tw(ctx, gui, 0.5 + (hold or 0.1), { Rotation = 90 }, LINEAR)
	later(ctx, 0.18 + (hold or 0.1), function()
		tw(ctx, gui, 0.22, { Size = ZERO }, QUAD, IN)
	end)
end

-- Sets a sprite's alpha to `peak`, then fades it back to `rest`.
local function flash(ctx: Ctx, gui: Instance, peak: number, rest: number, time: number?)
	setAlpha(gui, peak)
	fade(ctx, gui, time or 0.5, rest)
end

-- Purchase burst: star pops flying out of (x, y) plus a puff of Kit confetti. Each star's
-- end point is clamped 0.2 stage-heights inside the edges, so none leaves the stage.
local function burst(ctx: Ctx, x: number, y: number, stars: number, confetti: number, reach: number?)
	local A = ctx.aspect
	local id = Sprites.image("StarPop")
	local dist = reach or 0.6
	local x0 = x * A
	for i = 1, stars do
		local star = sprite(ctx.root, "StarPop", if id then WHITE else WC.Sunny, {
			Size = sq(ctx, 0.3),
			Position = at(x, y),
			ZIndex = 9,
		})
		temp(ctx, star)
		local angle = (i / stars) * math.pi * 2 + math.random() * 0.6
		local ex = math.clamp(x0 + math.cos(angle) * dist, 0.2, A - 0.2)
		local ey = math.clamp(y + math.sin(angle) * dist, 0.2, 0.8)
		fly(ctx, star, 0.55 + math.random() * 0.15, function(a)
			local e = 1 - (1 - a) ^ 3
			star.Position = at((x0 + (ex - x0) * e) / A, y + (ey - y) * e)
			star.Size = sq(ctx, 0.3 * (1 - a * a) + 0.01)
			star.Rotation = 160 * a
		end, function()
			star:Destroy()
		end)
	end
	if confetti > 0 then
		Kit.confetti(ctx.root, { Count = confetti, Power = 0.3, Origin = at(x, y), ZIndex = 10 })
	end
end

local function onPlay(ctx: Ctx, fn: () -> ())
	table.insert(ctx.onPlay, fn)
end
local function onRest(ctx: Ctx, fn: () -> ())
	table.insert(ctx.onRest, fn)
end
local function onCelebrate(ctx: Ctx, fn: () -> ())
	table.insert(ctx.onCelebrate, fn)
end

-- Pass scenes ---------------------------------------------------------------------------
--[[
	Geometry is worked in stage-height units ("h"): the stage is A = 230/120 ≈ 1.92 h wide
	and 1 h tall. Everything that moves keeps ≥ 0.05 h (≈ 6 px) from the edges at its
	largest (idle breathing x pops x Back overshoot x rotation), except things that
	deliberately enter from an edge (Auto Aura orbs, Auto Cash drops, falling crates) and
	soft light (SoftDot glows, aura rings, crate rays), which fade at the edges.
]]

local PASSES: { [string]: (Ctx, Color3) -> () } = {}

-- Auto Aura: candy orbs spiral in from the edges into a big glowing dumbbell.
PASSES.AutoLoot = function(ctx, _tint)
	local root, A = ctx.root, ctx.aspect
	local cx, cy = 0.5, 0.52
	local GLOW = 0.4
	local glow = sprite(root, "SoftDot", C.Violet, { Size = box(ctx, 2.1, 1.35), Position = at(cx, cy), ZIndex = 1 })
	local core = sprite(root, "SoftDot", WHITE, { Size = sq(ctx, 0.4), Position = at(cx, cy), ZIndex = 2 })
	local rings = {}
	for i = 1, 2 do
		rings[i] = sprite(root, "Ring", Kit.lighten(C.Violet, 0.4), { Size = sq(ctx, 0.5), Position = at(cx, cy), ZIndex = 2 })
	end
	-- 1.55 x 0.68 h; with breathing 1.04 and a 0.9 pop it peaks at 1.79 x 0.78 h.
	local dumbbell = Sprites.image("hud/Dumbbell")
	local holder = node("Frame", root, {
		Name = "Dumbbell",
		Size = if dumbbell then box(ctx, 1.55, 0.68) else sq(ctx, 0.74),
		Position = at(cx, cy),
		ZIndex = 3,
	})
	local holderScale = Kit.new("UIScale", { Parent = holder })
	local hero = node("Frame", holder, { Name = "Hero", Size = FULL, Position = at(0.5, 0.5), ZIndex = 3 })
	if dumbbell then
		shade(node("ImageLabel", hero, {
			Name = "Image",
			Image = dumbbell,
			ScaleType = Enum.ScaleType.Fit,
			Size = FULL,
			Position = at(0.5, 0.5),
			ZIndex = 4,
		}))
		-- The art's dark plaque is blank (the HUD prints the carried amount on it): here it
		-- carries the word, so it reads as the aura dumbbell and not as a missing picture.
		-- Plaque in image pixels: x 310-714, y 66-316 of 1024 x 448 (art/out/ui/HudDumbbell.json).
		sticker(hero, string.upper(Theme.Words.Orb), C.GoldLight, {
			Name = "Label",
			Size = UDim2.fromScale(0.34, 0.4),
			Position = at(0.5, 0.426),
			ZIndex = 5,
		}, 2)
	else
		shade(icon(hero, { "Orb" }, C.Orb, { ZIndex = 4 }))
	end
	-- A sparkle over each bell, alternating per catch.
	local sparkles = {}
	for k, dx in { -0.3, 0.3 } do
		sparkles[k] = sprite(root, "Sparkle", if k == 1 then WHITE else WC.Butter, {
			Size = ZERO,
			Position = at(cx + dx, cy - 0.24),
			ZIndex = 6,
			Visible = false,
		})
	end
	local orbs = {}
	for i = 1, 5 do
		orbs[i] = orb(root, OrbLook.tierColor(i, Theme.OrbColors), { Size = sq(ctx, 0.26), ZIndex = 5, Visible = false })
	end
	local orbPool = pool(ctx, orbs)

	local turn = 0
	local function catch()
		Kit.pop(hero, 0.6)
		flash(ctx, glow, 0.05, GLOW, 0.5)
		core.Size = sq(ctx, 0.4)
		setAlpha(core, 0.15)
		tw(ctx, core, 0.35, { Size = sq(ctx, 0.85) }, QUAD, OUT)
		fade(ctx, core, 0.35, 1, QUAD, IN)
		turn = turn % #sparkles + 1
		twinkle(ctx, sparkles[turn], sq(ctx, 0.34), 0)
	end
	local function launch()
		local o = take(orbPool)
		if not o then
			return
		end
		local theta0 = math.random() * math.pi * 2
		local spin = (if math.random() < 0.5 then -1 else 1) * math.pi * (1.6 + math.random() * 0.6)
		local rx, ry = 0.62 * A, 0.78
		fly(ctx, o, 1.1 + math.random() * 0.25, function(a)
			local r = 1 - a * a
			local theta = theta0 + spin * a
			o.Position = at((cx * A + rx * r * math.cos(theta)) / A, cy + ry * r * math.sin(theta))
			o.Size = sq(ctx, 0.26 * (0.45 + 0.55 * r))
		end, function()
			free(orbPool, o)
			catch()
		end)
	end
	local ringTurn = 0
	local function ringPulse()
		ringTurn = ringTurn % 2 + 1
		local ring = rings[ringTurn]
		ring.Size = sq(ctx, 1.9)
		setAlpha(ring, 1)
		tw(ctx, ring, 1.3, { Size = sq(ctx, 0.45) }, QUAD, IN)
		fade(ctx, ring, 1.3, 0.35, QUAD, IN)
		later(ctx, 1.3, function()
			setAlpha(ring, 1)
		end)
	end

	onPlay(ctx, function()
		tw(ctx, holderScale, 1.0, { Scale = 1.04 }, SINE, INOUT, -1, true)
		loop(ctx, function(nap)
			launch()
			nap(0.34)
		end)
		loop(ctx, function(nap)
			ringPulse()
			nap(0.7)
		end)
	end)
	onRest(ctx, function()
		holderScale.Scale = 1
		glow.Size = box(ctx, 2.1, 1.35)
		setAlpha(glow, GLOW)
		setAlpha(core, 1)
		for _, ring in rings do
			ring.Size = sq(ctx, 0.5)
			setAlpha(ring, 1)
		end
		for _, s in sparkles do
			s.Visible = false
		end
		if PREVIEW then
			-- Still frame: three orbs on their way in.
			local spots = { { 0.14, 0.3 }, { 0.86, 0.7 }, { 0.26, 0.8 } }
			for i, spot in spots do
				orbs[i].Visible = true
				orbs[i].Position = at(spot[1], spot[2])
			end
		end
	end)
	onCelebrate(ctx, function()
		for i = 1, 5 do
			later(ctx, (i - 1) * 0.06, launch)
		end
		Kit.pop(hero, 0.9)
		flash(ctx, glow, 0, GLOW, 0.8)
		burst(ctx, cx, cy, 6, 14)
	end)
end

-- Auto Merge: two matching Chads hop, slide together and fuse into one bigger Chad of the
-- next tier (a star pop, a ring and an "AUTO-MERGED!" sticker), then a new pair pops in.
PASSES.AutoMerge = function(ctx, _tint)
	local root, A = ctx.root, ctx.aspect
	local cx, cy = 0.5, 0.6
	local lxh, rxh = 0.46, A - 0.46 -- pair centres (x in h)
	local PAIR, BIG = 0.46, 0.62
	local GLOW = 0.5
	local tier = math.clamp(3, 1, math.max(#Theme.OrbColors - 1, 1))
	local glow = sprite(root, "SoftDot", WC.Sunny, { Size = box(ctx, 1.6, 1.1), Position = at(cx, cy), ZIndex = 1 })
	local ring = sprite(root, "Ring", Kit.lighten(WC.Sunny, 0.3), { Size = sq(ctx, 0.5), Position = at(cx, cy), ZIndex = 2 })
	-- The merge mark between the pair; it shrinks away while they slide in.
	local mark = icon(root, { "Merge" }, C.Cash, { Size = sq(ctx, 0.3), Position = at(cx, cy), ZIndex = 3 })
	shade(mark)

	-- A tier-coloured candy disc with a Chad on it and a tier tag (pops ~1.2: a 0.62 h
	-- unit at y 0.6 peaks 0.23 .. 0.97).
	local function unit(name: string, t: number, size: number, x: number): GuiObject
		local holder = node("Frame", root, { Name = name, Size = sq(ctx, size), Position = at(x, cy), ZIndex = 4 })
		orb(holder, OrbLook.tierColor(t, Theme.OrbColors), { Size = FULL, Position = at(0.5, 0.5), ZIndex = 4 })
		shade(icon(holder, { "Chad" }, C.Text, { Size = UDim2.fromScale(0.74, 0.74), Position = at(0.5, 0.47), ZIndex = 5 }))
		local tag = node("Frame", holder, { Size = UDim2.fromScale(0.4, 0.4), Position = at(0.84, 0.84), ZIndex = 6 })
		paint(tag, WC.Sunny, -1, WC.Ink, 2)
		sticker(tag, tostring(t), WHITE, { Size = UDim2.fromScale(0.68, 0.68), Position = at(0.5, 0.5), ZIndex = 7 }, 2)
		return holder
	end
	local left = unit("Left", tier, PAIR, lxh / A)
	local right = unit("Right", tier, PAIR, rxh / A)
	local fused = unit("Fused", tier + 1, BIG, cx)
	-- 1.3 x 0.2 h across the top (0.03 .. 0.23 at a 1.1 pop).
	local label = sticker(root, "AUTO-MERGED!", WC.Sunny, {
		Name = "Merged",
		Size = box(ctx, 1.3, 0.2),
		Position = at(cx, 0.13),
		Rotation = -4,
		ZIndex = 8,
	}, 3)
	local spots = { { 0.2, 0.25 }, { 0.8, 0.3 }, { 0.68, 0.86 } }
	local sparkles = {}
	for i, spot in spots do
		sparkles[i] = sprite(root, "Sparkle", WC.Butter, { Size = ZERO, Position = at(spot[1], spot[2]), ZIndex = 7, Visible = false })
	end

	local function ringPulse(strength: number)
		ring.Size = sq(ctx, 0.4)
		setAlpha(ring, 0.05)
		tw(ctx, ring, 0.9, { Size = sq(ctx, 1.25 * strength) }, QUAD, OUT)
		fade(ctx, ring, 0.9, 1, QUAD, OUT)
	end
	local turn = 0
	local function fuse()
		left.Visible = false
		right.Visible = false
		fused.Visible = true
		fused.Size = sq(ctx, 0.3)
		tw(ctx, fused, 0.32, { Size = sq(ctx, BIG) }, BACK, OUT)
		flash(ctx, glow, 0.05, GLOW, 0.6)
		ringPulse(1)
		burst(ctx, cx, cy, 4, 0, 0.45)
		label.Visible = true
		label.Size = ZERO
		tw(ctx, label, 0.28, { Size = box(ctx, 1.3, 0.2) }, BACK, OUT)
		turn = turn % #sparkles + 1
		twinkle(ctx, sparkles[turn], sq(ctx, 0.26), 0.15)
	end

	onPlay(ctx, function()
		tw(ctx, glow, 1.1, { Size = box(ctx, 1.8, 1.25) }, SINE, INOUT, -1, true)
		loop(ctx, function(nap)
			-- Hop, then slide together.
			Kit.pop(left, 0.5)
			Kit.pop(right, 0.5)
			if not nap(0.45) then
				return
			end
			tw(ctx, left, 0.42, { Position = at((cx * A - 0.08) / A, cy) }, QUAD, IN)
			tw(ctx, right, 0.42, { Position = at((cx * A + 0.08) / A, cy) }, QUAD, IN)
			tw(ctx, mark, 0.25, { Size = ZERO }, QUAD, IN)
			if not nap(0.42) then
				return
			end
			fuse()
			if not nap(1.3) then
				return
			end
			-- Out with the big one, in with a fresh pair.
			tw(ctx, fused, 0.2, { Size = ZERO }, QUAD, IN)
			tw(ctx, label, 0.2, { Size = ZERO }, QUAD, IN)
			if not nap(0.22) then
				return
			end
			fused.Visible = false
			label.Visible = false
			for k, u in { left, right } do
				u.Position = at((if k == 1 then lxh else rxh) / A, cy)
				u.Size = ZERO
				u.Visible = true
				tw(ctx, u, 0.3, { Size = sq(ctx, PAIR) }, BACK, OUT)
			end
			tw(ctx, mark, 0.3, { Size = sq(ctx, 0.3) }, BACK, OUT)
			nap(0.7)
		end, 0.3)
	end)
	onRest(ctx, function()
		glow.Size = box(ctx, 1.6, 1.1)
		setAlpha(glow, GLOW)
		ring.Size = sq(ctx, 0.5)
		setAlpha(ring, 1)
		left.Position = at(lxh / A, cy)
		right.Position = at(rxh / A, cy)
		for _, u in { left, right } do
			u.Size = sq(ctx, PAIR)
			u.Visible = true
		end
		fused.Size = sq(ctx, BIG)
		fused.Visible = false
		mark.Size = sq(ctx, 0.3)
		label.Size = box(ctx, 1.3, 0.2)
		label.Visible = PREVIEW
		for _, s in sparkles do
			s.Visible = PREVIEW
			s.Size = if PREVIEW then sq(ctx, 0.22) else ZERO
		end
	end)
	onCelebrate(ctx, function()
		ringPulse(1.3)
		later(ctx, 0.12, function()
			ringPulse(1.3)
		end)
		for _, u in { left, right, fused } do
			Kit.pop(u, 1)
		end
		flash(ctx, glow, 0, GLOW, 0.8)
		burst(ctx, cx, cy, 7, 14)
	end)
end

-- Auto Cash: an orb drops into a converter box, a coin arcs out into a wallet that bulges,
-- and a little pill counts the cash up (+$5 .. +$95, then round again).
PASSES.AutoCash = function(ctx, _tint)
	local root, A = ctx.root, ctx.aspect
	local bxh, by = 0.4, 0.6 -- converter centre (x in h)
	local wxh, wy = 1.42, 0.4 -- wallet centre
	local bx, wx = bxh / A, wxh / A
	local GLOW = 0.55
	local glow = sprite(root, "SoftDot", WC.Sunny, { Size = box(ctx, 1.4, 1.05), Position = at(wx, wy), ZIndex = 1 })
	local shadow = node("Frame", root, {
		Name = "Shadow",
		BackgroundColor3 = C.Ink,
		BackgroundTransparency = 0.6,
		Size = box(ctx, 0.66, 0.08),
		Position = at(bx, 0.9),
		ZIndex = 2,
	})
	Kit.round(shadow)

	-- Converter 0.6 x 0.62 h (0.29 .. 0.91 tall; pops 0.5).
	local converter = node("Frame", root, { Name = "Converter", Size = box(ctx, 0.6, 0.62), Position = at(bx, by), ZIndex = 3 })
	paint(converter, WC.Teal, 10, WC.Ink, 3)
	local slot = node("Frame", converter, { Size = UDim2.fromScale(0.62, 0.13), Position = at(0.5, 0.16), ZIndex = 4 })
	paint(slot, WC.TealDeep, -1)
	sticker(converter, "$", WC.Sunny, { Size = UDim2.fromScale(0.62, 0.58), Position = at(0.5, 0.6), ZIndex = 4 }, 3)

	-- Wallet 0.8 x 0.54 h (pops 0.6: right edge 1.85 h, top 0.11).
	local wallet = node("Frame", root, { Name = "Wallet", Size = box(ctx, 0.8, 0.54), Position = at(wx, wy), ZIndex = 3 })
	paint(wallet, WC.Mint, 10, WC.Ink, 3)
	local flap = node("Frame", wallet, {
		Size = UDim2.fromScale(1, 0.48),
		Position = at(0.5, 0),
		AnchorPoint = Vector2.new(0.5, 0),
		ZIndex = 4,
	})
	paint(flap, C.CashDeep, 10)
	local clasp = node("Frame", flap, { Size = UDim2.fromScale(0.17, 0.5), Position = at(0.84, 0.78), ZIndex = 5 })
	paint(clasp, WC.Sunny, -1, WC.Ink, 1.5)

	-- The counter pill: bottom-right, 42 % of the stage wide, well inside the edges.
	local pill = node("Frame", root, {
		Name = "Counter",
		AnchorPoint = Vector2.new(1, 1),
		Position = at(0.955, 0.92),
		Size = UDim2.fromScale(0.42, 0.26),
		ZIndex = 6,
	})
	paint(pill, WC.Ink, -1, WC.Sunny, 2)
	local counter = node("TextLabel", pill, {
		Name = "Amount",
		Text = "+$0",
		Font = F.Display,
		TextScaled = true,
		TextColor3 = WC.Sunny,
		Size = UDim2.fromScale(0.84, 0.76),
		Position = at(0.5, 0.52),
		ZIndex = 7,
	})
	Kit.new("UITextSizeConstraint", { MaxTextSize = 26, MinTextSize = 6, Parent = counter })
	local earned = 0
	local function show()
		counter.Text = "+$" .. tostring(earned)
	end

	local sparkle = sprite(root, "Sparkle", WC.Butter, { Size = ZERO, Position = at(1.62 / A, 0.22), ZIndex = 7, Visible = false })
	local coins = {}
	for i = 1, 4 do
		coins[i] = coin(root, { Size = sq(ctx, 0.26), ZIndex = 5, Visible = false })
	end
	local coinPool = pool(ctx, coins)
	local drops = {}
	for i = 1, 2 do
		drops[i] = orb(root, OrbLook.tierColor(i, Theme.OrbColors), { Size = sq(ctx, 0.2), ZIndex = 2, Visible = false })
	end
	local dropPool = pool(ctx, drops)

	-- The coin leaves the slot (0.32) and lands in the wallet; its arc tops out at 0.2.
	local x0, y0 = bxh, 0.32
	local x1, y1 = wxh - 0.1, 0.36
	local function launchCoin(amount: number)
		local c = take(coinPool)
		if not c then
			return
		end
		Kit.pop(converter, 0.5)
		fly(ctx, c, 0.62, function(a)
			local s = 0.26 * math.min(1, 0.4 + a * 3)
			c.Position = at((x0 + (x1 - x0) * a) / A, y0 + (y1 - y0) * a - 0.14 * 4 * a * (1 - a))
			c.Size = box(ctx, s * math.max(math.abs(math.cos(a * math.pi * 3)), 0.15), s)
		end, function()
			free(coinPool, c)
			Kit.pop(wallet, 0.6)
			flash(ctx, glow, 0.1, GLOW, 0.45)
			earned += amount
			if earned > 95 then
				earned = amount
			end
			show()
			Kit.pop(pill, 0.5)
			twinkle(ctx, sparkle, sq(ctx, 0.28), 0)
		end)
	end
	local function dropOrb()
		local o = take(dropPool)
		if not o then
			return
		end
		fly(ctx, o, 0.26, function(a)
			o.Position = at(bx, -0.12 + 0.54 * a * a)
			o.Size = sq(ctx, 0.2 * (1 - 0.4 * a))
		end, function()
			free(dropPool, o)
		end)
	end

	onPlay(ctx, function()
		loop(ctx, function(nap)
			dropOrb()
			if not nap(0.24) then
				return
			end
			launchCoin(5)
			nap(0.36)
		end)
	end)
	onRest(ctx, function()
		setAlpha(glow, GLOW)
		sparkle.Visible = false
		if PREVIEW then
			earned = 45
			local still = coins[1]
			still.Visible = true
			still.Position = at((x0 + x1) * 0.5 / A, 0.22)
		end
		show()
	end)
	onCelebrate(ctx, function()
		for i = 1, 4 do
			later(ctx, (i - 1) * 0.08, function()
				launchCoin(10)
			end)
		end
		burst(ctx, wx, wy, 5, 12)
	end)
end

-- Double Aura: a Chad with violet aura rings pulsing out alternately, and a bouncy 2X badge.
PASSES.DoubleAura = function(ctx, _tint)
	local root = ctx.root
	local cx, cy = 0.5, 0.52
	local glow = sprite(root, "SoftDot", C.Violet, { Size = box(ctx, 2.0, 1.3), Position = at(cx, cy), ZIndex = 1 })
	local rings = {}
	for i = 1, 2 do
		rings[i] = sprite(root, "Ring", Kit.lighten(C.Violet, 0.15), { Size = sq(ctx, 0.45), Position = at(cx, cy), ZIndex = 2 })
	end
	local tier = math.min(8, #Theme.Tiers)
	local ok = pcall(function()
		local viewport = Kit.unitViewport(root, tier, { Size = sq(ctx, 1.0), Position = at(cx, 0.5), AnchorPoint = CENTER })
		viewport.ZIndex = 3
	end)
	if not ok then
		shade(icon(root, { "Chad" }, C.Text, { Size = sq(ctx, 0.84), Position = at(cx, cy), ZIndex = 3 }))
	end
	-- Badge 0.7 x 0.4 h at (1.44 h, 0.33), tilted ±8°; a 1.2 pop still clears the edges.
	local badge = node("Frame", root, { Name = "Badge", Size = box(ctx, 0.7, 0.4), Position = at(0.75, 0.33), Rotation = -8, ZIndex = 5 })
	paint(badge, C.Gold, -1, WC.Ink, 3)
	sticker(badge, "2X", WHITE, { Size = UDim2.fromScale(0.78, 0.8), Position = at(0.5, 0.52), ZIndex = 6 }, 3)
	local spots = { { 0.24, 0.28 }, { 0.72, 0.78 }, { 0.27, 0.76 } }
	local sparkles = {}
	for i, spot in spots do
		sparkles[i] = sprite(root, "Sparkle", WC.Butter, { Size = ZERO, Position = at(spot[1], spot[2]), ZIndex = 4, Visible = false })
	end

	local ringTurn = 0
	local function ringPulse(strength: number)
		ringTurn = ringTurn % 2 + 1
		local ring = rings[ringTurn]
		ring.Size = sq(ctx, 0.4)
		setAlpha(ring, 0.05)
		tw(ctx, ring, 1.3, { Size = sq(ctx, 1.3 * strength) }, QUAD, OUT)
		fade(ctx, ring, 1.3, 1, QUAD, OUT)
	end
	local function wiggle(strength: number)
		Kit.pop(badge, strength)
		tw(ctx, badge, 0.08, { Rotation = 8 }, QUAD, OUT)
		later(ctx, 0.08, function()
			tw(ctx, badge, 0.55, { Rotation = -8 }, ELASTIC, OUT)
		end)
	end

	onPlay(ctx, function()
		tw(ctx, glow, 1.0, { Size = box(ctx, 2.3, 1.5) }, SINE, INOUT, -1, true)
		loop(ctx, function(nap)
			ringPulse(1)
			nap(0.65)
		end)
		loop(ctx, function(nap)
			wiggle(1)
			nap(1.4)
		end, 0.3)
		local turn = 0
		loop(ctx, function(nap)
			turn = turn % #sparkles + 1
			twinkle(ctx, sparkles[turn], sq(ctx, 0.28), 0.1)
			nap(0.42)
		end, 0.2)
	end)
	onRest(ctx, function()
		glow.Size = box(ctx, 2.0, 1.3)
		for _, ring in rings do
			ring.Size = sq(ctx, 0.45)
			setAlpha(ring, 1)
		end
		badge.Rotation = -8
		for _, s in sparkles do
			s.Visible = PREVIEW
			s.Size = if PREVIEW then sq(ctx, 0.22) else ZERO
		end
		if PREVIEW then
			rings[1].Size = sq(ctx, 1.0)
			setAlpha(rings[1], 0.45)
		end
	end)
	onCelebrate(ctx, function()
		ringPulse(1.3)
		later(ctx, 0.12, function()
			ringPulse(1.3)
		end)
		wiggle(1.2)
		flash(ctx, glow, 0, 0.5, 0.8)
		burst(ctx, cx, cy, 6, 14)
	end)
end

-- 2X Cash: a coin flips and splits into two coins that clink apart, then a 2X stamp pops in.
PASSES.DoubleMoney = function(ctx, _tint)
	local root, A = ctx.root, ctx.aspect
	local cy = 0.5
	-- In h: the merged coin at 0.63, the pair at 0.42 / 0.84 (0.66 h each, pops 0.5),
	-- the stamp at 1.4 (0.74 x 0.6 h, -10°; Back overshoot x pop stays ≤ 1.11).
	local cx, leftX, rightX = 0.63 / A, 0.42 / A, 0.84 / A
	local stampX = 1.4 / A
	local BIG, SMALL = 0.8, 0.66
	local GLOW = 0.4
	local glow = sprite(root, "SoftDot", WC.Sunny, { Size = box(ctx, 2.1, 1.35), Position = at(0.5, cy), ZIndex = 1 })
	local big = coin(root, { Size = sq(ctx, BIG), Position = at(cx, cy), ZIndex = 3 }, true)
	local left = coin(root, { Size = sq(ctx, SMALL), Position = at(leftX, cy), ZIndex = 3 }, true)
	local right = coin(root, { Size = sq(ctx, SMALL), Position = at(rightX, cy), ZIndex = 4 }, true)
	local starId = Sprites.image("StarPop")
	local star = sprite(root, "StarPop", if starId then WHITE else WC.Sunny, {
		Size = ZERO,
		Position = at(stampX, cy),
		ZIndex = 5,
		Visible = false,
	})
	local stampSize = box(ctx, 0.74, 0.6)
	local stamp = sticker(root, "2X", WC.Sunny, { Size = stampSize, Position = at(stampX, cy), Rotation = -10, ZIndex = 6 }, 3.5)
	local sparkles = {
		sprite(root, "Sparkle", WHITE, { Size = ZERO, Position = at(cx, 0.2), ZIndex = 6, Visible = false }),
		sprite(root, "Sparkle", WC.Butter, { Size = ZERO, Position = at(cx + 0.05, 0.82), ZIndex = 6, Visible = false }),
	}

	local function slam(strength: number)
		stamp.Visible = true
		stamp.Size = ZERO
		stamp.Rotation = -40
		tw(ctx, stamp, 0.28, { Size = stampSize, Rotation = -10 }, BACK, OUT)
		later(ctx, 0.12, function()
			Kit.pop(left, 0.5)
			Kit.pop(right, 0.5)
			flash(ctx, glow, 0.05, GLOW, 0.5)
			star.Visible = true
			star.Size = sq(ctx, 0.3)
			setAlpha(star, 0)
			tw(ctx, star, 0.4, { Size = sq(ctx, 0.86) }, QUAD, OUT)
			fade(ctx, star, 0.4, 1, QUAD, IN)
		end)
		later(ctx, 0.28, function()
			Kit.pop(stamp, strength)
		end)
	end

	onPlay(ctx, function()
		loop(ctx, function(nap)
			if not nap(1.0) then
				return
			end
			-- Merge back into one coin.
			tw(ctx, stamp, 0.16, { Size = ZERO, Rotation = 10 }, BACK, IN)
			tw(ctx, left, 0.2, { Position = at(cx, cy) }, QUAD, IN)
			tw(ctx, right, 0.2, { Position = at(cx, cy) }, QUAD, IN)
			if not nap(0.2) then
				return
			end
			left.Visible = false
			right.Visible = false
			stamp.Visible = false
			star.Visible = false
			big.Visible = true
			big.Size = sq(ctx, BIG)
			Kit.pop(big, 0.7)
			if not nap(0.3) then
				return
			end
			-- Flip, flip...
			for _ = 1, 2 do
				tw(ctx, big, 0.09, { Size = box(ctx, 0.04, BIG) }, QUAD, IN)
				if not nap(0.09) then
					return
				end
				tw(ctx, big, 0.09, { Size = sq(ctx, BIG) }, QUAD, OUT)
				if not nap(0.1) then
					return
				end
			end
			-- ...split! The two coins clink apart.
			big.Visible = false
			left.Position = at(cx, cy)
			right.Position = at(cx, cy)
			left.Visible = true
			right.Visible = true
			tw(ctx, left, 0.28, { Position = at(leftX, cy) }, BACK, OUT)
			tw(ctx, right, 0.28, { Position = at(rightX, cy) }, BACK, OUT)
			if not nap(0.18) then
				return
			end
			twinkle(ctx, sparkles[1], sq(ctx, 0.26), 0.05)
			twinkle(ctx, sparkles[2], sq(ctx, 0.2), 0.05)
			if not nap(0.1) then
				return
			end
			slam(0.7)
			nap(0.5)
		end)
	end)
	onRest(ctx, function()
		-- Resting pose is the payoff: two coins and the 2X stamp.
		big.Visible = false
		big.Size = sq(ctx, BIG)
		left.Visible = true
		right.Visible = true
		left.Position = at(leftX, cy)
		right.Position = at(rightX, cy)
		stamp.Visible = true
		stamp.Size = stampSize
		stamp.Rotation = -10
		star.Visible = false
		setAlpha(glow, GLOW)
		for _, s in sparkles do
			s.Visible = false
		end
	end)
	onCelebrate(ctx, function()
		slam(0.9)
		burst(ctx, stampX, cy, 6, 14)
	end)
end

-- VIP Smasher: a pink-and-gold hammer smashes a crate (puff, star, debris); the next crate
-- is already dropping in while the puff fades, so the stage is never empty.
PASSES.PremiumUnlocker = function(ctx, _tint)
	local root, A = ctx.root, ctx.aspect
	-- Crate frame 0.86 h on the floor at x 0.62 h (the atlas art shows ~0.65 h of it).
	local crateXh, crateBottom, CRATE = 0.62, 0.98, 0.86
	local crateX = crateXh / A
	local crateMid = crateBottom - CRATE * 0.5
	local CRATES = { "CrateRare", "CrateEpic", "CrateLegendary" }
	local GLOW = 0.5
	local glow = sprite(root, "SoftDot", WC.Sunny, { Size = sq(ctx, 1.25), Position = at(crateX, crateMid), ZIndex = 1 })
	local shadow = node("Frame", root, {
		Name = "Shadow",
		BackgroundColor3 = C.Ink,
		BackgroundTransparency = 0.6,
		Size = box(ctx, 0.66, 0.08),
		Position = at(crateX, 0.9),
		ZIndex = 2,
	})
	Kit.round(shadow)
	local crate = icon(root, { "CrateRare", "Gift2", "Star" }, WC.Sunny, {
		Size = sq(ctx, CRATE),
		Position = at(crateX, crateBottom),
		AnchorPoint = BOTTOM,
		ZIndex = 3,
	})
	shade(crate)
	local puff = sprite(root, "Puff", WHITE, { Size = ZERO, Position = at(crateX, crateMid), ZIndex = 5, Visible = false })
	local starId = Sprites.image("StarPop")
	local star = sprite(root, "StarPop", if starId then WHITE else WC.Sunny, {
		Size = ZERO,
		Position = at(crateX, crateMid),
		ZIndex = 4,
		Visible = false,
	})
	local bits = {}
	for i, color in { WC.Sunny, WC.Mint, HOT_PINK, WC.Blue, WC.Butter } do
		bits[i] = sprite(root, "Confetti", color, { Size = sq(ctx, 0.18), ZIndex = 6, Visible = false })
	end
	local bitPool = pool(ctx, bits)

	-- The hammer swings round its handle end P = (1.45 h, 0.88), the arm's centre; the
	-- head (0.56 x 0.26 h) sits 0.66 h up the handle. Rest -6°, wind-up +7°, strike -58°
	-- keep the head ≥ 0.05 h inside the stage (strike lands on the crate's right half).
	local REST, WINDUP, STRIKE = -6, 7, -58
	local ARM = 1.32
	local arm = node("Frame", root, { Name = "Hammer", Size = sq(ctx, ARM), Position = at(1.45 / A, 0.88), Rotation = REST, ZIndex = 7 })
	local handle = node("Frame", arm, { Size = UDim2.fromScale(0.07, 0.52), Position = at(0.5, 0.545), AnchorPoint = BOTTOM, ZIndex = 7 })
	paint(handle, WC.Sunny, 5, WC.Ink, 2.5)
	local head = node("Frame", arm, { Size = UDim2.fromScale(0.56 / ARM, 0.26 / ARM), Position = at(0.5, 0), ZIndex = 8 })
	paint(head, HOT_PINK, 9, WC.Ink, 3)
	for _, x in { 0.07, 0.93 } do
		local cap = node("Frame", head, { Size = UDim2.fromScale(0.12, 1.1), Position = at(x, 0.5), ZIndex = 9 })
		paint(cap, WC.Sunny, 5, WC.Ink, 2)
	end
	sticker(head, "VIP", WC.Sunny, { Size = UDim2.fromScale(0.66, 0.74), Position = at(0.5, 0.53), ZIndex = 10 })

	local crateTurn = 1
	local function smashFx(power: number)
		crate.Visible = false
		flash(ctx, glow, 0, GLOW, 0.6)
		puff.Visible = true
		puff.Size = sq(ctx, 0.3)
		setAlpha(puff, 0)
		tw(ctx, puff, 0.45, { Size = sq(ctx, 0.8 * power) }, QUAD, OUT)
		fade(ctx, puff, 0.45, 1, QUAD, IN)
		star.Visible = true
		star.Size = sq(ctx, 0.2)
		setAlpha(star, 0)
		tw(ctx, star, 0.38, { Size = sq(ctx, 0.78 * power) }, QUAD, OUT)
		fade(ctx, star, 0.38, 1, QUAD, IN)
		for k = 1, #bits do
			local bit = take(bitPool)
			if bit then
				local dx = (k - 3) * 0.17 + (math.random() - 0.5) * 0.1
				local rise = 0.28 + math.random() * 0.1
				local spin0 = math.random(0, 360)
				setAlpha(bit, 0)
				fly(ctx, bit, 0.65, function(a)
					bit.Position = at((crateXh + dx * a) / A, crateMid - rise * 4 * a * (1 - a) + 0.3 * a * a)
					bit.Rotation = spin0 + 320 * a
					if a > 0.7 then
						setAlpha(bit, (a - 0.7) / 0.3)
					end
				end, function()
					free(bitPool, bit)
				end)
			end
		end
	end
	local function dropCrate()
		crateTurn = crateTurn % #CRATES + 1
		retexture(crate, CRATES[crateTurn])
		crate.Size = sq(ctx, CRATE)
		crate.Position = at(crateX, crateBottom - 1)
		crate.Visible = true
		tw(ctx, crate, 0.45, { Position = at(crateX, crateBottom) }, BOUNCE, OUT)
		shadow.Size = box(ctx, 0.3, 0.05)
		tw(ctx, shadow, 0.45, { Size = box(ctx, 0.66, 0.08) }, BOUNCE, OUT)
	end

	onPlay(ctx, function()
		loop(ctx, function(nap)
			if not nap(0.3) then
				return
			end
			tw(ctx, arm, 0.22, { Rotation = WINDUP }, SINE, OUT)
			if not nap(0.24) then
				return
			end
			tw(ctx, arm, 0.1, { Rotation = STRIKE }, QUAD, IN)
			if not nap(0.1) then
				return
			end
			tw(ctx, crate, 0.06, { Size = box(ctx, CRATE * 1.25, CRATE * 0.7) }, QUAD, OUT)
			if not nap(0.06) then
				return
			end
			smashFx(1)
			tw(ctx, arm, 0.45, { Rotation = REST }, BACK, OUT)
			-- The next crate falls in while the puff is still fading.
			if not nap(0.12) then
				return
			end
			dropCrate()
			if not nap(0.4) then
				return
			end
			puff.Visible = false
			star.Visible = false
			nap(0.45)
		end)
	end)
	onRest(ctx, function()
		arm.Rotation = REST
		crate.Visible = true
		crate.Size = sq(ctx, CRATE)
		crate.Position = at(crateX, crateBottom)
		shadow.Size = box(ctx, 0.66, 0.08)
		setAlpha(glow, GLOW)
		puff.Visible = false
		star.Visible = false
	end)
	onCelebrate(ctx, function()
		flash(ctx, glow, 0, GLOW, 0.8)
		burst(ctx, crateX, 0.5, 6, 14)
		Kit.pop(head, 0.5)
	end)
end

-- Crate Master: a golden key slides into a legendary crate and turns, the crate jumps open
-- with a star flash, sun rays and sparkles, then the key slides back out.
PASSES.CrateKey = function(ctx, _tint)
	local root, A = ctx.root, ctx.aspect
	-- Crate frame 0.96 h (art ~0.73 h) at x 0.9 h; keyhole at y 0.58.
	local cxh, crateBottom, CRATE = 0.9, 0.99, 0.96
	local cx = cxh / A
	local holeY = 0.58
	local KEY = 1.0
	local keyIn, keyOut = at(cx, holeY), at((cxh + 0.25) / A, holeY)
	local GLOW = 0.45
	local rays = node("Frame", root, { Name = "Rays", Size = sq(ctx, 2.2), Position = at(cx, 0.5), ZIndex = 1 })
	local bars = {}
	for k = 0, 2 do
		local bar = node("Frame", rays, {
			BackgroundColor3 = WC.Butter,
			BackgroundTransparency = 0.6,
			Size = UDim2.fromScale(0.15, 1),
			Position = at(0.5, 0.5),
			Rotation = k * 60,
			ZIndex = 1,
		})
		Kit.round(bar)
		Kit.new("UIGradient", {
			Rotation = 90,
			Transparency = NumberSequence.new({
				NumberSequenceKeypoint.new(0, 1),
				NumberSequenceKeypoint.new(0.3, 0.1),
				NumberSequenceKeypoint.new(0.7, 0.1),
				NumberSequenceKeypoint.new(1, 1),
			}),
			Parent = bar,
		})
		table.insert(bars, bar)
	end
	local glow = sprite(root, "SoftDot", WC.Sunny, { Size = box(ctx, 1.8, 1.3), Position = at(cx, 0.5), ZIndex = 2 })
	local starId = Sprites.image("StarPop")
	local star = sprite(root, "StarPop", if starId then WHITE else WC.Sunny, {
		Size = ZERO,
		Position = at(cx, 0.5),
		ZIndex = 2,
		Visible = false,
	})
	local crate = icon(root, { "CrateLegendary", "Gift2", "Star" }, WC.Sunny, {
		Size = sq(ctx, CRATE),
		Position = at(cx, crateBottom),
		AnchorPoint = BOTTOM,
		ZIndex = 3,
	})
	shade(crate)

	-- The key's tip sits in the keyhole (the holder's centre), shaft and bow to the right;
	-- turned -90° the bow points up (top 0.07).
	local key = node("Frame", root, { Name = "Key", Size = sq(ctx, KEY), Position = keyOut, ZIndex = 5 })
	local shaft =
		node("Frame", key, { Size = UDim2.fromScale(0.38, 0.1), Position = at(0.5, 0.5), AnchorPoint = Vector2.new(0, 0.5), ZIndex = 5 })
	paint(shaft, C.Gold, 3, WC.Ink, 2.5)
	local tooth =
		node("Frame", key, { Size = UDim2.fromScale(0.07, 0.12), Position = at(0.57, 0.52), AnchorPoint = Vector2.new(0, 0), ZIndex = 5 })
	paint(tooth, C.Gold, 2, WC.Ink, 2.5)
	local bow = node("Frame", key, { Size = UDim2.fromScale(0.26, 0.26), Position = at(0.88, 0.5), ZIndex = 6 })
	paint(bow, C.Gold, -1, WC.Ink, 3)
	local hole = node("Frame", bow, { Size = UDim2.fromScale(0.36, 0.36), Position = at(0.5, 0.5), ZIndex = 7 })
	paint(hole, C.GoldDeep, -1)

	local sparkles = {
		sprite(root, "Sparkle", WHITE, { Size = sq(ctx, 0.3), ZIndex = 6, Visible = false }),
		sprite(root, "Sparkle", WC.Butter, { Size = sq(ctx, 0.3), ZIndex = 6, Visible = false }),
	}
	local sparklePool = pool(ctx, sparkles)

	local function open(power: number)
		tw(ctx, crate, 0.08, { Size = box(ctx, CRATE * 1.1, CRATE * 0.92) }, QUAD, OUT)
		later(ctx, 0.08, function()
			tw(ctx, crate, 0.3, { Size = sq(ctx, CRATE) }, BACK, OUT)
		end)
		star.Visible = true
		star.Size = sq(ctx, 0.2)
		setAlpha(star, 0)
		tw(ctx, star, 0.45, { Size = sq(ctx, 0.85) }, QUAD, OUT)
		fade(ctx, star, 0.45, 1, QUAD, IN)
		tw(ctx, glow, 0.25, { Size = box(ctx, 2.3 * power, 1.6) }, QUAD, OUT)
		fade(ctx, glow, 0.25, 0.05)
		for _, bar in bars do
			tw(ctx, bar, 0.25, { BackgroundTransparency = 0.1 }, QUAD, OUT)
		end
		for i = 1, #sparkles do
			local s = take(sparklePool)
			if s then
				local side = if i == 1 then -1 else 1
				fly(ctx, s, 0.75, function(a)
					s.Position = at((cxh + side * 0.65 * power * a) / A, 0.35 - 0.2 * 4 * a * (1 - a) + 0.3 * a)
					s.Size = sq(ctx, 0.3 * math.sin(math.pi * math.min(a * 1.2, 1)) + 0.01)
					s.Rotation = 180 * a
				end, function()
					free(sparklePool, s)
				end)
			end
		end
	end
	local function close()
		star.Visible = false
		for _, bar in bars do
			tw(ctx, bar, 0.6, { BackgroundTransparency = 0.6 }, QUAD, OUT)
		end
		tw(ctx, glow, 0.6, { Size = box(ctx, 1.8, 1.3) }, QUAD, OUT)
		fade(ctx, glow, 0.6, GLOW)
		Kit.pop(crate, 0.4)
	end

	onPlay(ctx, function()
		tw(ctx, rays, 8, { Rotation = 360 }, LINEAR, INOUT, -1)
		loop(ctx, function(nap)
			if not nap(0.4) then
				return
			end
			tw(ctx, key, 0.2, { Position = keyIn }, QUAD, OUT)
			if not nap(0.22) then
				return
			end
			tw(ctx, key, 0.25, { Rotation = -90 }, BACK, OUT)
			if not nap(0.27) then
				return
			end
			for _, r in { -6, 6, -4, 0 } do
				tw(ctx, crate, 0.05, { Rotation = r }, QUAD, OUT)
				if not nap(0.05) then
					return
				end
			end
			open(1)
			if not nap(1.0) then
				return
			end
			close()
			tw(ctx, key, 0.2, { Rotation = 0 }, QUAD, OUT)
			if not nap(0.22) then
				return
			end
			tw(ctx, key, 0.25, { Position = keyOut }, QUAD, OUT)
			nap(0.3)
		end)
	end)
	onRest(ctx, function()
		rays.Rotation = 0
		for _, bar in bars do
			bar.BackgroundTransparency = if PREVIEW then 0.35 else 0.6
		end
		glow.Size = box(ctx, 1.8, 1.3)
		setAlpha(glow, GLOW)
		star.Visible = false
		crate.Rotation = 0
		crate.Size = sq(ctx, CRATE)
		key.Rotation = 0
		key.Position = keyOut
		if PREVIEW then
			sparkles[1].Visible = true
			sparkles[1].Position = at((cxh - 0.5) / A, 0.24)
			sparkles[2].Visible = true
			sparkles[2].Position = at((cxh + 0.6) / A, 0.26)
		end
	end)
	onCelebrate(ctx, function()
		open(1.25)
		later(ctx, 1.0, close)
		burst(ctx, cx, 0.45, 6, 14)
	end)
end

-- Starter Pack / All Cosmetics / anything else: a big gift or star that breathes and hops,
-- with sparkles twinkling round it and a sheen sweeping across.
local function giftScene(ctx: Ctx, tint: Color3, names: { string })
	local root = ctx.root
	local cx, cy = 0.5, 0.5
	local GLOW = 0.35
	local glow = sprite(root, "SoftDot", Kit.lighten(tint, 0.3), { Size = box(ctx, 2.0, 1.3), Position = at(cx, cy), ZIndex = 1 })
	-- 0.92 h frame (art ~0.7 h); breathing 1.03 and a 1.2 pop keep the art inside.
	local holder = node("Frame", root, { Name = "Hero", Size = sq(ctx, 0.92), Position = at(cx, cy), ZIndex = 3 })
	local holderScale = Kit.new("UIScale", { Parent = holder })
	local hero = icon(holder, names, WC.Sunny, { ZIndex = 3 })
	shade(hero)
	local spots = { { 0.2, 0.28 }, { 0.8, 0.3 }, { 0.76, 0.74 }, { 0.27, 0.76 } }
	local sparkles = {}
	for i, spot in spots do
		sparkles[i] = sprite(root, "Sparkle", if i % 2 == 0 then WC.Butter else WHITE, {
			Size = ZERO,
			Position = at(spot[1], spot[2]),
			ZIndex = 4,
			Visible = false,
		})
	end
	local sheen = node("Frame", root, {
		Name = "Sheen",
		BackgroundColor3 = WHITE,
		BackgroundTransparency = 0,
		Size = UDim2.fromScale(0.12, 1.8),
		Position = at(-0.3, 0.5),
		Rotation = 20,
		ZIndex = 5,
	})
	Kit.new("UIGradient", {
		Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 1),
			NumberSequenceKeypoint.new(0.5, 0.6),
			NumberSequenceKeypoint.new(1, 1),
		}),
		Parent = sheen,
	})

	onPlay(ctx, function()
		tw(ctx, holderScale, 1.1, { Scale = 1.03 }, SINE, INOUT, -1, true)
		tw(ctx, holder, 1.4, { Position = at(cx, cy - 0.02) }, SINE, INOUT, -1, true)
		tw(ctx, glow, 1.1, { Size = box(ctx, 2.3, 1.5) }, SINE, INOUT, -1, true)
		local turn = 0
		loop(ctx, function(nap)
			turn = turn % #sparkles + 1
			twinkle(ctx, sparkles[turn], sq(ctx, 0.3), 0.1)
			nap(0.35)
		end)
		loop(ctx, function(nap)
			Kit.pop(hero, 0.5)
			flash(ctx, glow, 0.1, GLOW, 0.5)
			nap(2.2)
		end, 0.6)
		loop(ctx, function(nap)
			sheen.Position = at(-0.3, 0.5)
			tw(ctx, sheen, 1.0, { Position = at(1.3, 0.5) }, SINE, INOUT)
			nap(3.2)
		end, 0.8)
	end)
	onRest(ctx, function()
		holderScale.Scale = 1
		holder.Position = at(cx, cy)
		glow.Size = box(ctx, 2.0, 1.3)
		setAlpha(glow, GLOW)
		sheen.Position = at(-0.3, 0.5)
		for _, s in sparkles do
			s.Visible = PREVIEW
			s.Size = if PREVIEW then sq(ctx, 0.22) else ZERO
		end
	end)
	onCelebrate(ctx, function()
		Kit.pop(hero, 1.2)
		flash(ctx, glow, 0, GLOW, 0.8)
		burst(ctx, cx, cy, 6, 14)
	end)
end

PASSES.StarterPack = function(ctx, tint)
	giftScene(ctx, tint, { "Gift2", "CosStarter", "Star" })
end
PASSES.AllCosmetics = function(ctx, tint)
	giftScene(ctx, tint, { "CosAll", "Crown", "Star" })
end

--[[
	Animated art for one pass banner. `stage` is a transparent Frame the caller sizes
	(about 230x120 design px, at least ~150x80 for the art to read) and clips; `name` the
	pass key; `tint` the banner colour.
]]
function ShopScenes.pass(stage: Frame, name: string, tint: Color3): Scene
	local ctx = newCtx(stage, PASS_ASPECT)
	ctx.root.Name = "Scene" .. tostring(name)
	local build = PASSES[name]
	if build then
		build(ctx, tint or WC.Sunny)
	else
		giftScene(ctx, tint or WC.Sunny, { "Star" })
	end
	return finish(ctx)
end

-- Pack scenes ---------------------------------------------------------------------------

local CASH_ICONS = { "CashPack1", "CashPack3", "CashPack5", "CashPack6" }

--[[
	Animated art for one pack card: kind "Money" | "Aura", index 1..4 (the size
	ladder: bigger index = bigger pile, more particles, stronger glow). `stage` about
	110x110 or larger (1:1). The pile frame is 0.98 of the stage (art ~0.75); coins rain
	in from the top edge and land on it, orbs float up out of it.
]]
function ShopScenes.pack(stage: Frame, kind: string, index: number): Scene
	local i = math.clamp(math.floor(tonumber(index) or 1), 1, 4)
	local ctx = newCtx(stage, PACK_ASPECT)
	ctx.root.Name = "Scene" .. tostring(kind) .. tostring(i)
	local root = ctx.root
	local cx, cy = 0.5, 0.52

	local glowColor = if kind == "Aura" then C.Violet else WC.Sunny
	local glowAlpha = 0.66 - 0.09 * i
	local glowSize = 0.9 + 0.1 * i
	local glow = sprite(root, "SoftDot", glowColor, { Size = sq(ctx, glowSize), Position = at(cx, cy), ZIndex = 1 })
	local shadow = node("Frame", root, {
		Name = "Shadow",
		BackgroundColor3 = C.Ink,
		BackgroundTransparency = 0.68,
		Size = box(ctx, 0.56, 0.08),
		Position = at(cx, 0.9),
		ZIndex = 2,
	})
	Kit.round(shadow)
	local holder = node("Frame", root, { Name = "Pile", Size = sq(ctx, 0.98), Position = at(cx, cy), ZIndex = 3 })
	local holderScale = Kit.new("UIScale", { Parent = holder })

	local hero: GuiObject
	if kind == "Aura" then
		local art = "AuraPack" .. i
		if Kit.hasImageIcon(art) then
			hero = icon(holder, { art }, nil, { ZIndex = 3 })
			shade(hero)
		else
			-- A little heap of candy orbs, one more per size step.
			hero = node("Frame", holder, { Size = FULL, Position = at(0.5, 0.5), ZIndex = 3 })
			local heap = { { 0.5, 0.62, 0.5 }, { 0.3, 0.7, 0.36 }, { 0.72, 0.7, 0.38 }, { 0.5, 0.34, 0.34 } }
			for k = 1, math.min(i + 1, #heap) do
				local h = heap[k]
				orb(hero, OrbLook.tierColor(k, Theme.OrbColors), {
					Size = UDim2.fromScale(h[3], h[3]),
					Position = at(h[1], h[2]),
					ZIndex = 3 + k,
				})
			end
		end
	else
		hero = icon(holder, { CASH_ICONS[i], "Coin" }, C.Gold, { ZIndex = 3 })
		shade(hero)
	end

	-- Particles: coins raining onto the pile (Money), orbs floating up out of it (Aura);
	-- sparkles glint where a coin lands / an orb pops.
	local flyers: { GuiObject } = {}
	if kind == "Money" then
		for k = 1, i + 1 do
			flyers[k] = coin(root, { Size = sq(ctx, 0.22), ZIndex = 5, Visible = false })
		end
	elseif kind == "Aura" then
		for k = 1, i + 1 do
			flyers[k] = orb(root, OrbLook.tierColor(k, Theme.OrbColors), { Size = sq(ctx, 0.17), ZIndex = 5, Visible = false })
		end
	end
	local flyerPool = pool(ctx, flyers)
	local sparkles: { GuiObject } = {}
	for k = 1, 2 do
		sparkles[k] = sprite(root, "Sparkle", if k % 2 == 0 then WC.Butter else WHITE, { Size = ZERO, ZIndex = 6, Visible = false })
	end

	local sparkleTurn = 0
	local function glint(x: number, y: number, size: number)
		sparkleTurn = sparkleTurn % #sparkles + 1
		local s = sparkles[sparkleTurn]
		s.Position = at(x, y)
		twinkle(ctx, s, sq(ctx, size), 0.05)
	end

	local function launch()
		local p = take(flyerPool)
		if not p then
			return
		end
		if kind == "Money" then
			-- Falls in from the top edge, spinning, lands on the pile, hops, sinks in.
			local x0 = 0.3 + math.random() * 0.4
			local drift = (math.random() - 0.5) * 0.12
			local land = 0.3 + math.random() * 0.14
			fly(ctx, p, 0.85 + math.random() * 0.15, function(a)
				local y
				if a < 0.6 then
					local f = a / 0.6
					y = -0.12 + (land + 0.12) * f * f
				else
					y = land - 0.08 * math.sin(math.pi * math.min((a - 0.6) / 0.4 * 1.4, 1))
				end
				local s = if a > 0.82 then 1 - (a - 0.82) / 0.18 else 1
				p.Position = at(x0 + drift * a, y)
				p.Size = box(ctx, 0.22 * s * math.max(math.abs(math.cos(a * math.pi * 3)), 0.15), 0.22 * s)
			end, function()
				free(flyerPool, p)
				glint(x0 + drift, land - 0.02, 0.2 + 0.02 * i)
			end)
		else
			-- Floats up out of the pile with a sway, eases to a stop near the top, pops.
			local x0 = 0.3 + math.random() * 0.4
			local sway = 0.05 + math.random() * 0.04
			local phase = math.random() * math.pi * 2
			local top = 0.14 + math.random() * 0.08
			local xEnd = x0 + sway * math.sin(phase + math.pi * 2.5)
			fly(ctx, p, 1.3 + math.random() * 0.3, function(a)
				local s = if a > 0.85 then 1 - (a - 0.85) / 0.15 else math.min(a / 0.15, 1)
				p.Position = at(x0 + sway * math.sin(phase + a * math.pi * 2.5), 0.5 + (top - 0.5) * (1 - (1 - a) ^ 2))
				p.Size = sq(ctx, 0.17 * s + 0.005)
			end, function()
				free(flyerPool, p)
				glint(xEnd, top, 0.2 + 0.02 * i)
			end)
		end
	end
	onPlay(ctx, function()
		tw(ctx, holderScale, 1.2, { Scale = 1.035 }, SINE, INOUT, -1, true)
		tw(ctx, glow, 1.0, { Size = sq(ctx, glowSize * 1.12) }, SINE, INOUT, -1, true)
		if #flyers > 0 then
			loop(ctx, function(nap)
				launch()
				nap(if kind == "Money" then 0.75 - 0.12 * i else 0.85 - 0.13 * i)
			end, math.random() * 0.4)
		end
	end)
	onRest(ctx, function()
		holderScale.Scale = 1
		glow.Size = sq(ctx, glowSize)
		setAlpha(glow, glowAlpha)
		for _, s in sparkles do
			s.Visible = false
		end
		if PREVIEW then
			-- Still frame: a couple of particles and a sparkle in the air.
			if flyers[1] then
				flyers[1].Visible = true
				flyers[1].Position = at(0.24, 0.22)
			end
			if flyers[2] then
				flyers[2].Visible = true
				flyers[2].Position = at(0.78, 0.28)
			end
			sparkles[1].Visible = true
			sparkles[1].Size = sq(ctx, 0.18)
			sparkles[1].Position = at(0.78, 0.7)
		end
	end)
	onCelebrate(ctx, function()
		Kit.pop(hero, 0.9)
		flash(ctx, glow, 0, glowAlpha, 0.8)
		for k = 1, #flyers do
			later(ctx, (k - 1) * 0.05, launch)
		end
		burst(ctx, cx, cy, 5, 10, 0.45)
	end)

	return finish(ctx)
end

return ShopScenes
