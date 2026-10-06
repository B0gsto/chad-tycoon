--[[
	ShopScenes: the little looping animations on the shop's pass banners and pack cards.

	  ShopScenes.pass(stage, name, tint)  one banner scene per game pass key (AutoLoot,
	                                      AutoCash, DoubleAura, DoubleMoney, PremiumUnlocker,
	                                      CrateKey, StarterPack, AllCosmetics; anything else
	                                      gets a sparkling star)
	  ShopScenes.pack(stage, kind, index) a pack card scene: kind "Money" | "Aura" | "Gems",
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

-- Swaps the atlas cell an image icon shows (crate rarity), keeping the frame.
local function retexture(iconFrame: Instance, name: string)
	local image = iconFrame:FindFirstChild("Image")
	local icons = Assets and Assets.Icons
	local entry = if type(icons) == "table" then icons[name] else nil
	if image and image:IsA("ImageLabel") and type(entry) == "table" and type(entry.image) == "string" then
		image.Image = entry.image
		image.ImageRectOffset = Vector2.new(tonumber(entry.x) or 0, tonumber(entry.y) or 0)
		image.ImageRectSize = Vector2.new(tonumber(entry.w) or 0, tonumber(entry.h) or 0)
	end
end

-- The gold coin: the Blender CoinSpin sprite, or the shape coin.
local function coin(parent: Instance, props: { [string]: any }): GuiObject
	if COIN_IMAGE then
		local gui = node("ImageLabel", parent, { Name = "Coin", Image = COIN_IMAGE, ScaleType = Enum.ScaleType.Fit })
		for key, value in props do
			gui[key] = value
		end
		return gui
	end
	return icon(parent, { "Coin" }, C.Gold, props)
end

-- A glossy candy aura ball.
local function orb(parent: Instance, color: Color3, props: { [string]: any }): GuiObject
	local f = node("Frame", parent, props)
	paint(f, Kit.lighten(color, 0.08), -1, Kit.darken(color, 0.38), 1.5)
	return f
end

-- Chunky display text (sticker style): coloured fill, thick navy outline.
local function sticker(parent: Instance, text: string, color: Color3, props: { [string]: any }): TextLabel
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
		Thickness = 2.5,
		LineJoinMode = Enum.LineJoinMode.Round,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual,
		Parent = label,
	})
	return label
end

-- Sparkle twinkle: scales in with a quarter spin, holds, scales out.
local function twinkle(ctx: Ctx, gui: GuiObject, size: UDim2, hold: number?)
	gui.Visible = true
	gui.Size = ZERO
	gui.Rotation = 0
	tw(ctx, gui, 0.2, { Size = size }, BACK, OUT)
	tw(ctx, gui, 0.6 + (hold or 0.1), { Rotation = 90 }, LINEAR)
	later(ctx, 0.2 + (hold or 0.1), function()
		tw(ctx, gui, 0.25, { Size = ZERO }, QUAD, IN)
	end)
end

-- Purchase burst: star pops flying out of (x, y) plus a puff of Kit confetti.
local function burst(ctx: Ctx, x: number, y: number, stars: number, confetti: number, reach: number?)
	local A = ctx.aspect
	local id = Sprites.image("StarPop")
	local dist = reach or 0.55
	for i = 1, stars do
		local star = sprite(ctx.root, "StarPop", if id then WHITE else WC.Sunny, {
			Size = sq(ctx, 0.22),
			Position = at(x, y),
			ZIndex = 9,
		})
		temp(ctx, star)
		local angle = (i / stars) * math.pi * 2 + math.random() * 0.7
		fly(ctx, star, 0.6 + math.random() * 0.15, function(a)
			local e = 1 - (1 - a) ^ 3
			star.Position = at((x * A + math.cos(angle) * dist * e) / A, y + math.sin(angle) * dist * e)
			star.Size = sq(ctx, 0.26 * (1 - a * a) + 0.01)
			star.Rotation = 140 * a
		end, function()
			star:Destroy()
		end)
	end
	if confetti > 0 then
		Kit.confetti(ctx.root, { Count = confetti, Power = 0.4, Origin = at(x, y), ZIndex = 10 })
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

local PASSES: { [string]: (Ctx, Color3) -> () } = {}

-- Auto Aura: candy orbs spiral in from the edges into a glowing dumbbell.
PASSES.AutoLoot = function(ctx, _tint)
	local root, A = ctx.root, ctx.aspect
	local cx, cy = 0.5, 0.54
	local glow = sprite(root, "SoftDot", C.Violet, { Size = sq(ctx, 1.15), Position = at(cx, cy), ZIndex = 1 })
	local rings = {}
	for i = 1, 2 do
		rings[i] = sprite(root, "Ring", Kit.lighten(C.Violet, 0.4), { Size = sq(ctx, 0.5), Position = at(cx, cy), ZIndex = 2 })
	end
	local dumbbell = Sprites.image("hud/Dumbbell")
	local holder = node("Frame", root, {
		Name = "Dumbbell",
		Size = if dumbbell then box(ctx, 1.02, 0.45) else sq(ctx, 0.62),
		Position = at(cx, cy),
		ZIndex = 3,
	})
	local holderScale = Kit.new("UIScale", { Parent = holder })
	local hero: GuiObject = if dumbbell
		then node(
			"ImageLabel",
			holder,
			{ Image = dumbbell, ScaleType = Enum.ScaleType.Fit, Size = FULL, Position = at(0.5, 0.5), ZIndex = 3 }
		)
		else icon(holder, { "Orb" }, C.Orb, { ZIndex = 3 })
	local sparkle = sprite(root, "Sparkle", WC.Butter, { Size = ZERO, Position = at(cx + 0.08, cy - 0.2), ZIndex = 6, Visible = false })
	local orbs = {}
	for i = 1, 5 do
		orbs[i] = orb(root, OrbLook.tierColor(i, Theme.OrbColors), { Size = sq(ctx, 0.2), ZIndex = 4, Visible = false })
	end
	local orbPool = pool(ctx, orbs)

	local function catch()
		Kit.pop(hero, 0.7)
		setAlpha(glow, 0.15)
		fade(ctx, glow, 0.5, 0.5)
		twinkle(ctx, sparkle, sq(ctx, 0.26), 0)
	end
	local function launch()
		local o = take(orbPool)
		if not o then
			return
		end
		local theta0 = math.random() * math.pi * 2
		local spin = (if math.random() < 0.5 then -1 else 1) * math.pi * (1.6 + math.random() * 0.6)
		local rx, ry = 0.62 * A, 0.78
		fly(ctx, o, 1.25 + math.random() * 0.3, function(a)
			local r = 1 - a * a
			local theta = theta0 + spin * a
			o.Position = at((cx * A + rx * r * math.cos(theta)) / A, cy + ry * r * math.sin(theta))
			o.Size = sq(ctx, 0.2 * (0.5 + 0.5 * r))
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
		tw(ctx, ring, 1.5, { Size = sq(ctx, 0.45) }, QUAD, IN)
		fade(ctx, ring, 1.5, 0.5, QUAD, IN)
		later(ctx, 1.5, function()
			setAlpha(ring, 1)
		end)
	end

	onPlay(ctx, function()
		tw(ctx, holderScale, 1.1, { Scale = 1.05 }, SINE, INOUT, -1, true)
		loop(ctx, function(nap)
			launch()
			nap(0.42)
		end)
		loop(ctx, function(nap)
			ringPulse()
			nap(0.8)
		end)
	end)
	onRest(ctx, function()
		holderScale.Scale = 1
		glow.Size = sq(ctx, 1.15)
		setAlpha(glow, 0.5)
		for _, ring in rings do
			ring.Size = sq(ctx, 0.5)
			setAlpha(ring, 1)
		end
		sparkle.Visible = false
		if PREVIEW then
			-- Still frame: three orbs on their way in.
			local spots = { { 0.2, 0.3 }, { 0.8, 0.72 }, { 0.3, 0.84 } }
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
		Kit.pop(hero, 2)
		burst(ctx, cx, cy, 5, 12)
	end)
end

-- Auto Cash: an orb drops into a converter box, a coin arcs out into a wallet that bulges.
PASSES.AutoCash = function(ctx, _tint)
	local root = ctx.root
	local bx, by = 0.16, 0.64
	local wx, wy = 0.83, 0.62
	local converter = node("Frame", root, { Name = "Converter", Size = box(ctx, 0.46, 0.46), Position = at(bx, by), ZIndex = 3 })
	paint(converter, WC.Teal, 9, WC.Ink, 2.5)
	local slot = node("Frame", converter, { Size = UDim2.fromScale(0.62, 0.14), Position = at(0.5, 0.18), ZIndex = 4 })
	paint(slot, WC.TealDeep, -1)
	sticker(converter, "$", WC.Sunny, { Size = UDim2.fromScale(0.62, 0.56), Position = at(0.5, 0.62), ZIndex = 4 })

	local wallet = node("Frame", root, { Name = "Wallet", Size = box(ctx, 0.6, 0.44), Position = at(wx, wy), ZIndex = 3 })
	paint(wallet, WC.Mint, 9, C.CashDeep, 2.5)
	local flap = node("Frame", wallet, {
		Size = UDim2.fromScale(1, 0.48),
		Position = at(0.5, 0),
		AnchorPoint = Vector2.new(0.5, 0),
		ZIndex = 4,
	})
	paint(flap, C.CashDeep, 9)
	local clasp = node("Frame", flap, { Size = UDim2.fromScale(0.17, 0.5), Position = at(0.84, 0.78), ZIndex = 5 })
	paint(clasp, WC.Sunny, -1, C.GoldDeep, 1.5)

	local counter = sticker(root, "+$0", WC.Sunny, { Size = box(ctx, 0.9, 0.3), Position = at(wx, 0.18), ZIndex = 6 })
	local earned = 0
	local function show()
		counter.Text = "+$" .. tostring(earned)
	end

	local coins = {}
	for i = 1, 4 do
		coins[i] = coin(root, { Size = sq(ctx, 0.26), ZIndex = 5, Visible = false })
	end
	local coinPool = pool(ctx, coins)
	local drops = {}
	for i = 1, 2 do
		drops[i] = orb(root, OrbLook.tierColor(i, Theme.OrbColors), { Size = sq(ctx, 0.17), ZIndex = 2, Visible = false })
	end
	local dropPool = pool(ctx, drops)

	local x0, y0 = bx, by - 0.24
	local x1, y1 = wx, wy - 0.04
	local function launchCoin(amount: number)
		local c = take(coinPool)
		if not c then
			return
		end
		Kit.pop(converter, 0.9)
		fly(ctx, c, 0.78, function(a)
			c.Position = at(x0 + (x1 - x0) * a, y0 + (y1 - y0) * a - 0.55 * 4 * a * (1 - a))
			c.Size = box(ctx, 0.26 * math.max(math.abs(math.cos(a * math.pi * 3)), 0.15), 0.26)
		end, function()
			free(coinPool, c)
			Kit.pop(wallet, 1)
			earned = if earned + amount > 9999 then amount else earned + amount
			show()
			Kit.pop(counter, 0.6)
		end)
	end
	local function dropOrb()
		local o = take(dropPool)
		if not o then
			return
		end
		fly(ctx, o, 0.3, function(a)
			o.Position = at(bx, -0.12 + (by - 0.12) * a * a)
			o.Size = sq(ctx, 0.17 * (1 - 0.5 * a))
		end, function()
			free(dropPool, o)
		end)
	end

	onPlay(ctx, function()
		loop(ctx, function(nap)
			dropOrb()
			if not nap(0.3) then
				return
			end
			launchCoin(5)
			nap(0.42)
		end)
	end)
	onRest(ctx, function()
		if PREVIEW then
			earned = 100
			local still = coins[1]
			still.Visible = true
			still.Position = at(0.5, 0.12)
		end
		show()
	end)
	onCelebrate(ctx, function()
		for i = 1, 5 do
			later(ctx, (i - 1) * 0.09, function()
				launchCoin(20)
			end)
		end
		burst(ctx, wx, wy - 0.1, 4, 12)
	end)
end

-- Double Aura: a Chad with two violet aura rings pulsing out alternately, and a bouncy 2X badge.
PASSES.DoubleAura = function(ctx, _tint)
	local root = ctx.root
	local cx, cy = 0.5, 0.52
	local glow = sprite(root, "SoftDot", C.Violet, { Size = sq(ctx, 1.05), Position = at(cx, cy), ZIndex = 1 })
	local rings = {}
	for i = 1, 2 do
		rings[i] = sprite(root, "Ring", Kit.lighten(C.Violet, 0.15), { Size = sq(ctx, 0.45), Position = at(cx, cy), ZIndex = 2 })
	end
	local tier = math.min(8, #Theme.Tiers)
	local ok = pcall(function()
		local viewport = Kit.unitViewport(root, tier, { Size = sq(ctx, 1.04), Position = at(cx, 0.5), AnchorPoint = CENTER })
		viewport.ZIndex = 3
	end)
	if not ok then
		icon(root, { "Chad" }, C.Text, { Size = sq(ctx, 0.8), Position = at(cx, cy), ZIndex = 3 })
	end
	local badge = node("Frame", root, { Name = "Badge", Size = box(ctx, 0.62, 0.36), Position = at(0.8, 0.27), Rotation = -8, ZIndex = 5 })
	paint(badge, C.Gold, -1, C.GoldDeep, 3)
	sticker(badge, "2X", WHITE, { Size = UDim2.fromScale(0.78, 0.8), Position = at(0.5, 0.52), ZIndex = 6 })
	local spots = { { 0.29, 0.27 }, { 0.7, 0.8 }, { 0.26, 0.76 } }
	local sparkles = {}
	for i, spot in spots do
		sparkles[i] = sprite(root, "Sparkle", WC.Butter, { Size = ZERO, Position = at(spot[1], spot[2]), ZIndex = 4, Visible = false })
	end

	local ringTurn = 0
	local function ringPulse(strength: number)
		ringTurn = ringTurn % 2 + 1
		local ring = rings[ringTurn]
		ring.Size = sq(ctx, 0.45)
		setAlpha(ring, 0.1)
		tw(ctx, ring, 1.6, { Size = sq(ctx, 1.55 * strength) }, QUAD, OUT)
		fade(ctx, ring, 1.6, 1, SINE, IN)
	end
	local function wiggle(strength: number)
		Kit.pop(badge, strength)
		tw(ctx, badge, 0.1, { Rotation = 8 }, QUAD, OUT)
		later(ctx, 0.1, function()
			tw(ctx, badge, 0.6, { Rotation = -8 }, ELASTIC, OUT)
		end)
	end

	onPlay(ctx, function()
		tw(ctx, glow, 1.2, { Size = sq(ctx, 1.22) }, SINE, INOUT, -1, true)
		loop(ctx, function(nap)
			ringPulse(1)
			nap(0.8)
		end)
		loop(ctx, function(nap)
			wiggle(1.4)
			nap(1.8)
		end, 0.4)
		local turn = 0
		loop(ctx, function(nap)
			turn = turn % #sparkles + 1
			twinkle(ctx, sparkles[turn], sq(ctx, 0.2), 0.15)
			nap(0.55)
		end, 0.2)
	end)
	onRest(ctx, function()
		glow.Size = sq(ctx, 1.05)
		for _, ring in rings do
			ring.Size = sq(ctx, 0.45)
			setAlpha(ring, 1)
		end
		badge.Rotation = -8
		for _, s in sparkles do
			s.Visible = PREVIEW
			s.Size = if PREVIEW then sq(ctx, 0.16) else ZERO
		end
		if PREVIEW then
			rings[1].Size = sq(ctx, 1.1)
			setAlpha(rings[1], 0.45)
		end
	end)
	onCelebrate(ctx, function()
		ringPulse(1.3)
		later(ctx, 0.12, function()
			ringPulse(1.3)
		end)
		wiggle(2.5)
		burst(ctx, cx, cy, 5, 12)
	end)
end

-- 2X Cash: a coin flips and splits into two coins that clink apart, then a 2X stamp slams in.
PASSES.DoubleMoney = function(ctx, _tint)
	local root = ctx.root
	local cx, cy = 0.38, 0.52
	local leftX, rightX = 0.25, 0.51
	local stampX, stampY = 0.81, 0.5
	local BIG, SMALL = 0.62, 0.52
	local glow = sprite(root, "SoftDot", WC.Sunny, { Size = sq(ctx, 1.0), Position = at(cx, cy), ZIndex = 1 })
	local big = coin(root, { Size = sq(ctx, BIG), Position = at(cx, cy), ZIndex = 3 })
	local left = coin(root, { Size = sq(ctx, SMALL), Position = at(leftX, cy), ZIndex = 3 })
	local right = coin(root, { Size = sq(ctx, SMALL), Position = at(rightX, cy), ZIndex = 4 })
	local starId = Sprites.image("StarPop")
	local star = sprite(root, "StarPop", if starId then WHITE else WC.Sunny, {
		Size = ZERO,
		Position = at(stampX, stampY),
		ZIndex = 5,
		Visible = false,
	})
	local stampSize = box(ctx, 0.82, 0.62)
	local stamp = sticker(root, "2X", WC.Sunny, { Size = stampSize, Position = at(stampX, stampY), Rotation = -10, ZIndex = 6 })
	local sparkles = {
		sprite(root, "Sparkle", WHITE, { Size = ZERO, Position = at(cx, 0.24), ZIndex = 6, Visible = false }),
		sprite(root, "Sparkle", WC.Butter, { Size = ZERO, Position = at(cx + 0.03, 0.8), ZIndex = 6, Visible = false }),
	}

	local function slam(strength: number)
		stamp.Visible = true
		stamp.Size = box(ctx, 0.82 * 2.4, 0.62 * 2.4)
		stamp.Rotation = -30
		tw(ctx, stamp, 0.16, { Size = stampSize, Rotation = -10 }, QUAD, IN)
		later(ctx, 0.16, function()
			Kit.pop(stamp, strength)
			Kit.pop(left, 0.6)
			Kit.pop(right, 0.6)
			star.Visible = true
			star.Size = sq(ctx, 0.3)
			setAlpha(star, 0)
			tw(ctx, star, 0.45, { Size = sq(ctx, 1.25) }, QUAD, OUT)
			fade(ctx, star, 0.45, 1, QUAD, IN)
		end)
	end

	onPlay(ctx, function()
		loop(ctx, function(nap)
			if not nap(1.3) then
				return
			end
			-- Merge back into one coin.
			tw(ctx, stamp, 0.18, { Size = ZERO, Rotation = 10 }, BACK, IN)
			tw(ctx, left, 0.22, { Position = at(cx, cy) }, QUAD, IN)
			tw(ctx, right, 0.22, { Position = at(cx, cy) }, QUAD, IN)
			if not nap(0.22) then
				return
			end
			left.Visible = false
			right.Visible = false
			stamp.Visible = false
			star.Visible = false
			big.Visible = true
			big.Size = sq(ctx, BIG)
			Kit.pop(big, 0.8)
			if not nap(0.4) then
				return
			end
			-- Flip, flip...
			for _ = 1, 2 do
				tw(ctx, big, 0.11, { Size = box(ctx, 0.04, BIG) }, QUAD, IN)
				if not nap(0.11) then
					return
				end
				tw(ctx, big, 0.11, { Size = sq(ctx, BIG) }, QUAD, OUT)
				if not nap(0.12) then
					return
				end
			end
			-- ...split! The two coins clink apart.
			big.Visible = false
			left.Position = at(cx, cy)
			right.Position = at(cx, cy)
			left.Visible = true
			right.Visible = true
			tw(ctx, left, 0.32, { Position = at(leftX, cy) }, BACK, OUT)
			tw(ctx, right, 0.32, { Position = at(rightX, cy) }, BACK, OUT)
			if not nap(0.22) then
				return
			end
			twinkle(ctx, sparkles[1], sq(ctx, 0.24), 0.05)
			twinkle(ctx, sparkles[2], sq(ctx, 0.17), 0.05)
			if not nap(0.15) then
				return
			end
			slam(1.2)
			nap(0.65)
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
		setAlpha(glow, 0.5)
		for _, s in sparkles do
			s.Visible = false
		end
	end)
	onCelebrate(ctx, function()
		slam(2.4)
		burst(ctx, stampX, stampY, 5, 12)
	end)
end

-- VIP Smasher: a pink-and-gold hammer smashes a crate (puff + confetti), a new crate drops in.
PASSES.PremiumUnlocker = function(ctx, _tint)
	local root = ctx.root
	local crateX, crateBottom, CRATE = 0.34, 0.94, 0.56
	local crateMid = crateBottom - CRATE * 0.5
	local CRATES = { "CrateRare", "CrateEpic", "CrateLegendary" }
	local shadow = node("Frame", root, {
		Name = "Shadow",
		BackgroundColor3 = C.Ink,
		BackgroundTransparency = 0.72,
		Size = box(ctx, 0.62, 0.1),
		Position = at(crateX, crateBottom),
		ZIndex = 1,
	})
	Kit.round(shadow)
	local crate = icon(root, { "CrateRare", "Gift2", "Star" }, WC.Sunny, {
		Size = sq(ctx, CRATE),
		Position = at(crateX, crateBottom),
		AnchorPoint = BOTTOM,
		ZIndex = 3,
	})
	local puff = sprite(root, "Puff", WHITE, { Size = ZERO, Position = at(crateX, crateMid), ZIndex = 5, Visible = false })
	local starId = Sprites.image("StarPop")
	local star = sprite(root, "StarPop", if starId then WHITE else WC.Sunny, {
		Size = ZERO,
		Position = at(crateX, crateMid),
		ZIndex = 4,
		Visible = false,
	})
	local confettiColors = { WC.Sunny, WC.Mint, WC.Blue }
	local bits = {}
	for i, color in confettiColors do
		bits[i] = sprite(root, "Confetti", color, { Size = sq(ctx, 0.15), ZIndex = 6, Visible = false })
	end
	local bitPool = pool(ctx, bits)

	-- The hammer swings round its handle end (the arm's centre).
	local REST, WINDUP, STRIKE = 50, 64, -68
	local arm = node("Frame", root, { Name = "Hammer", Size = sq(ctx, 1.3), Position = at(0.625, 0.53), Rotation = REST, ZIndex = 7 })
	local handle = node("Frame", arm, { Size = UDim2.fromScale(0.1, 0.45), Position = at(0.5, 0.53), AnchorPoint = BOTTOM, ZIndex = 7 })
	paint(handle, WC.Sunny, 5, C.GoldDeep, 2)
	local head = node("Frame", arm, { Size = UDim2.fromScale(0.5, 0.22), Position = at(0.5, 0.09), ZIndex = 8 })
	paint(head, HOT_PINK, 9, WC.Sunny, 3)
	sticker(head, "VIP", WC.Sunny, { Size = UDim2.fromScale(0.78, 0.7), Position = at(0.5, 0.53), ZIndex = 9 })

	local crateTurn = 1
	local function smashFx(power: number)
		crate.Visible = false
		puff.Visible = true
		puff.Size = sq(ctx, 0.3)
		setAlpha(puff, 0)
		tw(ctx, puff, 0.45, { Size = sq(ctx, 1.05 * power) }, QUAD, OUT)
		fade(ctx, puff, 0.45, 1, QUAD, IN)
		star.Visible = true
		star.Size = sq(ctx, 0.2)
		setAlpha(star, 0)
		tw(ctx, star, 0.4, { Size = sq(ctx, 0.95 * power) }, QUAD, OUT)
		fade(ctx, star, 0.4, 1, QUAD, IN)
		local A = ctx.aspect
		for i = 1, #bits do
			local bit = take(bitPool)
			if bit then
				local dx = (i - 2) * 0.32 + (math.random() - 0.5) * 0.12
				local rise = 0.5 + math.random() * 0.2
				local spin0 = math.random(0, 360)
				fly(ctx, bit, 0.7, function(a)
					bit.Position = at((crateX * A + dx * a * power) / A, crateMid - rise * 4 * a * (1 - a) + 0.25 * a * a)
					bit.Rotation = spin0 + 300 * a
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
		crate.Position = at(crateX, -0.05)
		crate.Visible = true
		tw(ctx, crate, 0.55, { Position = at(crateX, crateBottom) }, BOUNCE, OUT)
	end

	onPlay(ctx, function()
		loop(ctx, function(nap)
			if not nap(0.5) then
				return
			end
			tw(ctx, arm, 0.3, { Rotation = WINDUP }, SINE, OUT)
			if not nap(0.32) then
				return
			end
			tw(ctx, arm, 0.13, { Rotation = STRIKE }, QUAD, IN)
			if not nap(0.13) then
				return
			end
			tw(ctx, crate, 0.07, { Size = box(ctx, CRATE * 1.3, CRATE * 0.62) }, QUAD, OUT)
			if not nap(0.08) then
				return
			end
			smashFx(1)
			if not nap(0.25) then
				return
			end
			tw(ctx, arm, 0.5, { Rotation = REST }, BACK, OUT)
			if not nap(0.45) then
				return
			end
			puff.Visible = false
			star.Visible = false
			dropCrate()
			nap(0.6)
		end)
	end)
	onRest(ctx, function()
		arm.Rotation = REST
		crate.Visible = true
		crate.Size = sq(ctx, CRATE)
		crate.Position = at(crateX, crateBottom)
		puff.Visible = false
		star.Visible = false
	end)
	onCelebrate(ctx, function()
		burst(ctx, crateX, crateMid, 5, 14)
		Kit.pop(head, 2)
	end)
end

-- Crate Master: a golden key turns in a legendary crate, the lid pops, sun rays and sparkles burst.
PASSES.CrateKey = function(ctx, _tint)
	local root, A = ctx.root, ctx.aspect
	local cx, crateBottom, CRATE = 0.46, 0.95, 0.62
	local crateTop = crateBottom - CRATE
	local rays = node("Frame", root, { Name = "Rays", Size = sq(ctx, 1.75), Position = at(cx, 0.5), ZIndex = 1 })
	local bars = {}
	for k = 0, 2 do
		local bar = node("Frame", rays, {
			BackgroundColor3 = WC.Butter,
			BackgroundTransparency = 0.75,
			Size = UDim2.fromScale(0.16, 1),
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
	local glow = sprite(root, "SoftDot", WC.Sunny, { Size = sq(ctx, 1.0), Position = at(cx, 0.5), ZIndex = 2 })
	local crate = icon(root, { "CrateLegendary", "Gift2", "Star" }, WC.Sunny, {
		Size = sq(ctx, CRATE),
		Position = at(cx, crateBottom),
		AnchorPoint = BOTTOM,
		ZIndex = 3,
	})
	local lidClosed = at(cx, crateTop + 0.08)
	local lid = node("Frame", root, { Name = "Lid", Size = box(ctx, CRATE * 0.9, 0.13), Position = lidClosed, ZIndex = 4, Visible = false })
	paint(lid, C.Gold, 5, C.GoldDeep, 2.5)

	-- The key's tip sits in the keyhole (the holder's centre), shaft and bow to the right.
	local key = node("Frame", root, { Name = "Key", Size = sq(ctx, 0.72), Position = at(cx, crateBottom - CRATE * 0.42), ZIndex = 5 })
	local shaft =
		node("Frame", key, { Size = UDim2.fromScale(0.36, 0.1), Position = at(0.5, 0.5), AnchorPoint = Vector2.new(0, 0.5), ZIndex = 5 })
	paint(shaft, C.Gold, 3, WC.Ink, 2)
	local tooth =
		node("Frame", key, { Size = UDim2.fromScale(0.07, 0.11), Position = at(0.57, 0.52), AnchorPoint = Vector2.new(0, 0), ZIndex = 5 })
	paint(tooth, C.Gold, 2, WC.Ink, 2)
	local bow = node("Frame", key, { Size = UDim2.fromScale(0.25, 0.25), Position = at(0.88, 0.5), ZIndex = 6 })
	paint(bow, C.Gold, -1, WC.Ink, 2.5)

	local sparkles = {
		sprite(root, "Sparkle", WHITE, { Size = sq(ctx, 0.2), ZIndex = 6, Visible = false }),
		sprite(root, "Sparkle", WC.Butter, { Size = sq(ctx, 0.2), ZIndex = 6, Visible = false }),
	}
	local sparklePool = pool(ctx, sparkles)

	local function open(power: number)
		tw(ctx, crate, 0.1, { Size = box(ctx, CRATE * 0.9, CRATE * 1.15) }, QUAD, OUT)
		later(ctx, 0.1, function()
			tw(ctx, crate, 0.35, { Size = sq(ctx, CRATE) }, BACK, OUT)
		end)
		lid.Visible = true
		lid.Position = lidClosed
		lid.Rotation = 0
		tw(ctx, lid, 0.25, { Position = at(cx + 0.04, crateTop - 0.2), Rotation = -22 }, BACK, OUT)
		tw(ctx, glow, 0.25, { Size = sq(ctx, 1.5 * power) }, QUAD, OUT)
		fade(ctx, glow, 0.25, 0.1)
		for _, bar in bars do
			tw(ctx, bar, 0.25, { BackgroundTransparency = 0.2 }, QUAD, OUT)
		end
		for i = 1, #sparkles do
			local s = take(sparklePool)
			if s then
				local side = if i == 1 then -1 else 1
				local x0, y0 = cx * A, crateTop
				fly(ctx, s, 0.8, function(a)
					s.Position = at((x0 + side * 0.55 * power * a) / A, y0 - 0.5 * 4 * a * (1 - a) + 0.15 * a)
					s.Size = sq(ctx, 0.24 * math.sin(math.pi * math.min(a * 1.2, 1)) + 0.01)
					s.Rotation = 180 * a
				end, function()
					free(sparklePool, s)
				end)
			end
		end
	end
	local function close()
		tw(ctx, lid, 0.2, { Position = lidClosed, Rotation = 0 }, QUAD, IN)
		later(ctx, 0.2, function()
			lid.Visible = false
			Kit.pop(crate, 0.5)
		end)
		for _, bar in bars do
			tw(ctx, bar, 0.6, { BackgroundTransparency = 0.75 }, QUAD, OUT)
		end
		tw(ctx, glow, 0.6, { Size = sq(ctx, 1.0) }, QUAD, OUT)
		fade(ctx, glow, 0.6, 0.45)
	end

	onPlay(ctx, function()
		tw(ctx, rays, 9, { Rotation = 360 }, LINEAR, INOUT, -1)
		loop(ctx, function(nap)
			if not nap(0.6) then
				return
			end
			tw(ctx, key, 0.3, { Rotation = 90 }, BACK, OUT)
			if not nap(0.32) then
				return
			end
			for _, r in { -6, 6, 0 } do
				tw(ctx, crate, 0.06, { Rotation = r }, QUAD, OUT)
				if not nap(0.06) then
					return
				end
			end
			open(1)
			if not nap(1.2) then
				return
			end
			close()
			tw(ctx, key, 0.25, { Rotation = 0 }, QUAD, OUT)
			nap(0.7)
		end)
	end)
	onRest(ctx, function()
		rays.Rotation = 0
		for _, bar in bars do
			bar.BackgroundTransparency = if PREVIEW then 0.45 else 0.75
		end
		glow.Size = sq(ctx, 1.0)
		setAlpha(glow, 0.45)
		crate.Rotation = 0
		crate.Size = sq(ctx, CRATE)
		lid.Visible = false
		key.Rotation = 0
		if PREVIEW then
			sparkles[1].Visible = true
			sparkles[1].Position = at(cx - 0.2, 0.22)
			sparkles[2].Visible = true
			sparkles[2].Position = at(cx + 0.24, 0.3)
		end
	end)
	onCelebrate(ctx, function()
		open(1.25)
		later(ctx, 1.1, close)
		burst(ctx, cx, crateTop, 5, 14)
	end)
end

-- Starter Pack / All Cosmetics / anything else: a gift or star with orbiting sparkles and a sheen.
local function giftScene(ctx: Ctx, tint: Color3, names: { string })
	local root = ctx.root
	local cx, cy = 0.5, 0.5
	local glow = sprite(root, "SoftDot", Kit.lighten(tint, 0.55), { Size = sq(ctx, 1.05), Position = at(cx, cy), ZIndex = 1 })
	local holder = node("Frame", root, { Name = "Hero", Size = sq(ctx, 0.78), Position = at(cx, cy), ZIndex = 3 })
	local holderScale = Kit.new("UIScale", { Parent = holder })
	local hero = icon(holder, names, WC.Sunny, { ZIndex = 3 })
	local orbit = node("Frame", root, { Name = "Orbit", Size = sq(ctx, 1.0), Position = at(cx, cy), ZIndex = 4 })
	local spots = { { 0.5, 0.02 }, { 0.93, 0.74 }, { 0.07, 0.74 } }
	for i, spot in spots do
		sprite(orbit, "Sparkle", if i == 2 then WC.Butter else WHITE, {
			Size = UDim2.fromScale(0.17, 0.17),
			Position = at(spot[1], spot[2]),
			ZIndex = 4,
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
			NumberSequenceKeypoint.new(0.5, 0.7),
			NumberSequenceKeypoint.new(1, 1),
		}),
		Parent = sheen,
	})

	onPlay(ctx, function()
		tw(ctx, holderScale, 1.3, { Scale = 1.05 }, SINE, INOUT, -1, true)
		tw(ctx, holder, 1.6, { Position = at(cx, cy - 0.04) }, SINE, INOUT, -1, true)
		tw(ctx, orbit, 7, { Rotation = 360 }, LINEAR, INOUT, -1)
		tw(ctx, glow, 1.3, { Size = sq(ctx, 1.2) }, SINE, INOUT, -1, true)
		loop(ctx, function(nap)
			sheen.Position = at(-0.3, 0.5)
			tw(ctx, sheen, 1.3, { Position = at(1.3, 0.5) }, SINE, INOUT)
			nap(4.5)
		end, 0.8)
	end)
	onRest(ctx, function()
		holderScale.Scale = 1
		holder.Position = at(cx, cy)
		orbit.Rotation = 0
		glow.Size = sq(ctx, 1.05)
		setAlpha(glow, 0.45)
		sheen.Position = at(-0.3, 0.5)
	end)
	onCelebrate(ctx, function()
		Kit.pop(hero, 2.2)
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
	(about 230x120 design px) and clips; `name` the pass key; `tint` the banner colour.
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
	Animated art for one pack card: kind "Money" | "Aura" | "Gems", index 1..4 (the size
	ladder: bigger index = bigger pile, more particles, stronger glow). `stage` about 110x110.
]]
function ShopScenes.pack(stage: Frame, kind: string, index: number): Scene
	local i = math.clamp(math.floor(tonumber(index) or 1), 1, 4)
	local ctx = newCtx(stage, PACK_ASPECT)
	ctx.root.Name = "Scene" .. tostring(kind) .. tostring(i)
	local root = ctx.root
	local cx, cy = 0.5, 0.54

	local glowColor = if kind == "Aura" then C.Violet elseif kind == "Gems" then C.Rizz else WC.Sunny
	local glowAlpha = 0.82 - 0.1 * i
	local glowSize = 0.72 + 0.08 * i
	local glow = sprite(root, "SoftDot", glowColor, { Size = sq(ctx, glowSize), Position = at(cx, cy), ZIndex = 1 })
	local holder = node("Frame", root, { Name = "Pile", Size = sq(ctx, 0.8), Position = at(cx, cy), ZIndex = 3 })
	local holderScale = Kit.new("UIScale", { Parent = holder })

	local hero: GuiObject
	if kind == "Aura" then
		local art = "AuraPack" .. i
		if Kit.hasImageIcon(art) then
			hero = icon(holder, { art }, nil, { ZIndex = 3 })
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
	elseif kind == "Gems" then
		hero = icon(holder, { "GemPack" .. math.min(i, 3), "Gem" }, C.Rizz, { ZIndex = 3 })
	else
		hero = icon(holder, { CASH_ICONS[i], "Coin" }, C.Gold, { ZIndex = 3 })
	end

	-- Particles: coins sprinkling (Money), orbs drifting up (Aura); sparkles twinkle on all.
	local flyers: { GuiObject } = {}
	if kind == "Money" then
		for k = 1, i + 1 do
			flyers[k] = coin(root, { Size = sq(ctx, 0.2), ZIndex = 5, Visible = false })
		end
	elseif kind == "Aura" then
		for k = 1, i + 1 do
			flyers[k] = orb(root, OrbLook.tierColor(k, Theme.OrbColors), { Size = sq(ctx, 0.13), ZIndex = 2, Visible = false })
		end
	end
	local flyerPool = pool(ctx, flyers)
	local sparkleCount = if kind == "Gems" then math.min(2 + i, 5) else (if kind == "Aura" then 2 else 1)
	local sparkles: { GuiObject } = {}
	for k = 1, sparkleCount do
		sparkles[k] = sprite(root, "Sparkle", if k % 2 == 0 then WC.Butter else WHITE, { Size = ZERO, ZIndex = 6, Visible = false })
	end

	local function launch()
		local p = take(flyerPool)
		if not p then
			return
		end
		if kind == "Money" then
			local x0 = cx + (math.random() - 0.5) * 0.3
			local vx = (math.random() - 0.5) * 0.7
			local up = 1.3 + math.random() * 0.25 + 0.05 * i
			local y0 = 0.45
			local down = 0.92 - y0 + up
			fly(ctx, p, 0.95 + math.random() * 0.2, function(a)
				p.Position = at(x0 + vx * a, y0 - up * a + down * a * a)
				local shrink = if a > 0.75 then 1 - (a - 0.75) * 4 else 1
				p.Size = box(ctx, 0.2 * shrink * math.max(math.abs(math.cos(a * math.pi * 2.5)), 0.15), 0.2 * shrink)
			end, function()
				free(flyerPool, p)
			end)
		else
			local x0 = cx + (math.random() - 0.5) * 0.5
			local sway = (math.random() - 0.5) * 0.12
			local phase = math.random() * math.pi * 2
			fly(ctx, p, 1.5 + math.random() * 0.4, function(a)
				p.Position = at(x0 + sway * math.sin(phase + a * math.pi * 2), 0.78 - 0.7 * a)
				p.Size = sq(ctx, 0.13 * (1 - a * a) + 0.005)
			end, function()
				free(flyerPool, p)
			end)
		end
	end
	local sparkleTurn = 0
	local function sparkleOnce()
		sparkleTurn = sparkleTurn % #sparkles + 1
		local s = sparkles[sparkleTurn]
		local angle = math.random() * math.pi * 2
		local radius = 0.24 + math.random() * 0.14
		s.Position = at(cx + math.cos(angle) * radius, cy - 0.04 + math.sin(angle) * radius)
		twinkle(ctx, s, sq(ctx, 0.15 + 0.02 * i), 0.1)
	end

	onPlay(ctx, function()
		tw(ctx, holderScale, 1.3, { Scale = 1.045 }, SINE, INOUT, -1, true)
		if i == 4 then
			tw(ctx, glow, 0.9, { Size = sq(ctx, glowSize * 1.18) }, SINE, INOUT, -1, true)
			local glowTarget, prop = alphaTarget(glow)
			tw(ctx, glowTarget, 0.9, { [prop] = 0.12 }, SINE, INOUT, -1, true)
		end
		if #flyers > 0 then
			loop(ctx, function(nap)
				launch()
				nap(1.05 - 0.17 * i)
			end, math.random() * 0.5)
		end
		loop(ctx, function(nap)
			sparkleOnce()
			nap(if kind == "Gems" then 0.62 - 0.08 * i else 0.9)
		end, math.random() * 0.6)
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
				flyers[1].Position = at(0.24, 0.2)
			end
			if flyers[2] then
				flyers[2].Visible = true
				flyers[2].Position = at(0.78, 0.26)
			end
			sparkles[1].Visible = true
			sparkles[1].Size = sq(ctx, 0.16)
			sparkles[1].Position = at(0.8, 0.72)
		end
	end)
	onCelebrate(ctx, function()
		Kit.pop(hero, 2)
		for k = 1, #flyers do
			later(ctx, (k - 1) * 0.05, launch)
		end
		for k = 1, math.min(#sparkles, 3) do
			later(ctx, (k - 1) * 0.08, sparkleOnce)
		end
		burst(ctx, cx, cy, 4, 10, 0.5)
	end)

	return finish(ctx)
end

return ShopScenes
