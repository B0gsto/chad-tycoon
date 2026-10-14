--!strict
--[[
	Fx.Shake: the 3D side of SHAKE CATCH (Modes.Shake; docs/minigames.md). UI.ShakeHud draws
	the screen.

	The server sends each wave's drops ("wave" { drops = { id, kind, x, z, spawnAt, landAt } },
	server-clock times) and judges every catch; this module animates them locally against
	workspace:GetServerTimeNow():
	  * items: part-built and bright: a pink protein shake (lid, dome, straw, cherry), a shiny
	    golden dumbbell, a glowing aura orb; junk food: a burger, a pink donut, a soda can.
	    They fall with a gravity ease and a slow spin, tumbling junk wobbles;
	  * a landing mark under each: a dark shadow that grows as the item nears and a ring the
	    size of the catch radius (mint for good items, coral for junk);
	  * the player's tray: a big striped tray over their head and a faint ring at their feet
	    showing how far they reach (both local only);
	  * at the land time an item over the tray waits there for the server's word ("catch":
	    sparkles and a floating "+1" / "+3"; "splat": a junk splat and "OUCH!"); anything else
	    hits the sand and fades (junk squashes flat).
	Parts live in the arena's "Items" folder (World.ShakeArena), never collide or query.

	Main.client.luau calls init() once (it is in the Fx list); nothing else needs editing:
	  init()            connects the Notify listener
	  start(payload)    a run began ("start")
	  stop(payload)     the run ended ("stop", "win", "lose")
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Net = require(ReplicatedStorage.Shared.Net)
local Theme = require(ReplicatedStorage:WaitForChild("Theme")) :: any

local Sounds = require(script.Parent.Parent.Sounds) :: any

local W = Theme.World

local Shake = {}

-- Mirrors of ShakeRules (server-only): catch radius of good items and junk, the drop height
-- above the floor and the tray's height above the root.
local CATCH_RADIUS = 4.5
local JUNK_RADIUS = 3
local DROP_HEIGHT = 40
local TRAY_ABOVE_ROOT = 3.4
-- Items reach the tray's height (above the floor) at their land time.
local CATCH_HEIGHT = 6.4
-- Seconds an item rests on the tray waiting for the server's word before it slips off.
local HOLD_WAIT = 0.7
-- Seconds a missed item lies on the sand before it is gone.
local FLOOR_FADE = 0.7

type Drop = { id: number, kind: string, x: number, z: number, spawnAt: number, landAt: number }
type Item = {
	drop: Drop,
	model: Model?,
	shadow: BasePart?,
	ring: BasePart?,
	-- "wait" (not shown yet), "fall", "held", "floor", "done"
	state: string,
	heldAt: number,
	spin: number,
}

local running = false
local items: { [number]: Item } = {}
-- Server verdicts that came in before the item landed (id -> "catch" / "splat" payload).
local verdicts: { [number]: { [string]: any } } = {}
local arena: Model? = nil
local folder: Instance? = nil
local top = 6
local tray: Model? = nil
local footRing: BasePart? = nil
local stepConn: RBXScriptConnection? = nil

local function isJunk(kind: string): boolean
	return kind == "burger" or kind == "donut" or kind == "soda"
end

local function findArena(): Model?
	if arena and arena.Parent then
		return arena
	end
	for _, inst in Workspace:GetDescendants() do
		if inst:IsA("Model") and inst:GetAttribute("Mode") == "shake" then
			arena = inst
			local floor = inst:FindFirstChild("ArenaFloor")
			if floor and floor:IsA("BasePart") then
				top = floor.Position.Y + floor.Size.Y / 2
			end
			folder = inst:FindFirstChild("Items") or inst
			return inst
		end
	end
	return nil
end

-- Parts --------------------------------------------------------------------------------------

local function part(parent: Instance, size: Vector3, offset: CFrame, color: Color3, props: { [string]: any }?): BasePart
	local p: BasePart = if props and props.Wedge then Instance.new("WedgePart") else Instance.new("Part")
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Material = Enum.Material.SmoothPlastic
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Size = size
	p.Color = color
	p.CFrame = offset
	for key, value in (props or {}) :: { [string]: any } do
		if key ~= "Wedge" then
			(p :: any)[key] = value
		end
	end
	p.Parent = parent
	return p
end

local UP = CFrame.Angles(0, 0, math.rad(90)) -- a cylinder standing up
local CYL = Enum.PartType.Cylinder
local BALL = Enum.PartType.Ball

-- Builds an item's model around the origin (the model is pivoted every frame).
local function buildItem(kind: string): Model
	local m = Instance.new("Model")
	m.Name = "Shake_" .. kind
	if kind == "shake" then
		part(m, Vector3.new(2.4, 1.7, 1.7), UP, W.Pink, { Shape = CYL })
		part(m, Vector3.new(0.6, 1.78, 1.78), CFrame.new(0, -0.1, 0) * UP, W.White, { Shape = CYL })
		part(m, Vector3.new(0.3, 2, 2), CFrame.new(0, 1.3, 0) * UP, W.White, { Shape = CYL })
		part(m, Vector3.new(1.7, 1.1, 1.7), CFrame.new(0, 1.45, 0), W.Cream, { Shape = BALL })
		part(m, Vector3.new(0.3, 2.2, 0.3), CFrame.new(0.3, 2.4, 0) * CFrame.Angles(0, 0, math.rad(-15)), W.Mint)
		part(m, Vector3.new(0.6, 0.6, 0.6), CFrame.new(-0.35, 2.05, 0.3), W.Coral, { Shape = BALL })
	elseif kind == "gold" then
		local gold = { Reflectance = 0.25, Material = Enum.Material.Metal }
		part(m, Vector3.new(3.4, 0.45, 0.45), CFrame.new(), W.Gold, { Shape = CYL, Reflectance = 0.25, Material = Enum.Material.Metal })
		for _, s in { -1, 1 } do
			part(
				m,
				Vector3.new(0.5, 2.2, 2.2),
				CFrame.new(s * 1.2, 0, 0),
				W.Gold,
				{ Shape = CYL, Reflectance = gold.Reflectance, Material = gold.Material }
			)
			part(m, Vector3.new(0.4, 1.6, 1.6), CFrame.new(s * 1.65, 0, 0), W.GoldDeep, { Shape = CYL })
		end
		local core = m:GetChildren()[1] :: BasePart
		local light = Instance.new("PointLight")
		light.Color = W.Gold
		light.Range = 8
		light.Brightness = 1.5
		light.Parent = core
	elseif kind == "orb" then
		local core = part(m, Vector3.new(1.5, 1.5, 1.5), CFrame.new(), W.Grape, { Shape = BALL, Material = Enum.Material.Neon })
		part(m, Vector3.new(2.4, 2.4, 2.4), CFrame.new(), W.SkyBlue, { Shape = BALL, Material = Enum.Material.ForceField })
		local light = Instance.new("PointLight")
		light.Color = W.Grape
		light.Range = 10
		light.Brightness = 2
		light.Parent = core
	elseif kind == "burger" then
		part(m, Vector3.new(0.5, 2.2, 2.2), CFrame.new(0, -0.55, 0) * UP, W.Honey, { Shape = CYL })
		part(m, Vector3.new(0.45, 2.3, 2.3), CFrame.new(0, -0.1, 0) * UP, W.WoodDark, { Shape = CYL })
		part(m, Vector3.new(1.7, 0.12, 1.7), CFrame.new(0, 0.18, 0) * CFrame.Angles(0, math.rad(45), 0), W.Sunny)
		part(m, Vector3.new(0.15, 2.45, 2.45), CFrame.new(0, 0.28, 0) * UP, W.Grass, { Shape = CYL })
		part(m, Vector3.new(2.3, 1.3, 2.3), CFrame.new(0, 0.7, 0), W.Honey, { Shape = BALL })
	elseif kind == "donut" then
		part(m, Vector3.new(0.7, 2.5, 2.5), UP, W.Honey, { Shape = CYL })
		part(m, Vector3.new(0.2, 2.3, 2.3), CFrame.new(0, 0.4, 0) * UP, W.HotPink, { Shape = CYL })
		part(m, Vector3.new(0.92, 0.8, 0.8), UP, W.Ink, { Shape = CYL })
		local sprinkles = { W.Sunny, W.Mint, W.White, W.Blue }
		for i, c in sprinkles do
			local a = math.rad(i * 90 + 20)
			part(m, Vector3.new(0.4, 0.12, 0.12), CFrame.new(math.cos(a) * 0.8, 0.52, math.sin(a) * 0.8) * CFrame.Angles(0, a, 0), c)
		end
		m:PivotTo(CFrame.Angles(math.rad(35), 0, 0))
	else -- soda
		part(m, Vector3.new(2.2, 1.3, 1.3), UP, W.Coral, { Shape = CYL })
		part(m, Vector3.new(0.6, 1.36, 1.36), CFrame.new(0, 0.1, 0) * UP, W.White, { Shape = CYL })
		part(m, Vector3.new(0.12, 1.2, 1.2), CFrame.new(0, 1.12, 0) * UP, W.Steel, { Shape = CYL, Material = Enum.Material.Metal })
		part(m, Vector3.new(0.3, 0.12, 0.5), CFrame.new(0, 1.22, 0.15), W.Steel)
	end
	return m
end

-- The landing mark: a dark shadow (grows) and the catch ring (good: mint, junk: coral).
local function buildMark(parent: Instance, drop: Drop): (BasePart, BasePart)
	local junk = isJunk(drop.kind)
	local d = (if junk then JUNK_RADIUS else CATCH_RADIUS) * 2
	local at = Vector3.new(drop.x, top + 0.06, drop.z)
	local ring = part(parent, Vector3.new(0.05, d, d), CFrame.new(at) * UP, if junk then W.Coral else W.Mint, {
		Shape = CYL,
		Material = Enum.Material.Neon,
		Transparency = 0.75,
		Name = "ShakeRing",
	})
	local shadow = part(parent, Vector3.new(0.06, 1, 1), CFrame.new(at + Vector3.new(0, 0.02, 0)) * UP, W.Ink, {
		Shape = CYL,
		Transparency = 0.85,
		Name = "ShakeShadow",
	})
	return ring, shadow
end

-- Effects -------------------------------------------------------------------------------------

local function tween(inst: Instance, time: number, props: { [string]: any }, style: Enum.EasingStyle?)
	local t = TweenService:Create(inst, TweenInfo.new(time, style or Enum.EasingStyle.Quad, Enum.EasingDirection.Out), props)
	t:Play()
end

-- A floating word ("+3", "OUCH!") rising from `at`.
local function floatText(at: Vector3, text: string, color: Color3, size: number)
	local anchor = part(folder or Workspace, Vector3.new(0.2, 0.2, 0.2), CFrame.new(at), color, { Transparency = 1 })
	local gui = Instance.new("BillboardGui")
	gui.Size = UDim2.fromOffset(160, 70)
	gui.AlwaysOnTop = true
	gui.LightInfluence = 0
	gui.Parent = anchor
	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromScale(1, 1)
	label.Text = text
	label.TextSize = size
	label.Font = Theme.Fonts.Display
	label.TextColor3 = color
	label.Parent = gui
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 3
	stroke.Color = W.Ink
	stroke.Parent = label
	local scale = Instance.new("UIScale")
	scale.Scale = 0.3
	scale.Parent = label
	tween(scale, 0.3, { Scale = 1 }, Enum.EasingStyle.Back)
	tween(anchor, 1.1, { CFrame = CFrame.new(at + Vector3.new(0, 4, 0)) })
	task.delay(0.7, function()
		tween(label, 0.4, { TextTransparency = 1 })
		tween(stroke, 0.4, { Transparency = 1 })
	end)
	task.delay(1.2, function()
		anchor:Destroy()
	end)
end

-- Little neon bits flying out of `at` and fading (sparkles for a catch, goo for a splat).
local function burst(at: Vector3, colors: { Color3 }, count: number, speed: number, flat: boolean)
	for i = 1, count do
		local a = (i / count) * math.pi * 2 + math.random() * 0.5
		local dir = Vector3.new(math.cos(a), if flat then 0.15 else 0.4 + math.random() * 0.8, math.sin(a))
		local s = 0.35 + math.random() * 0.3
		local bit =
			part(folder or Workspace, Vector3.new(s, if flat then s * 0.4 else s, s), CFrame.new(at), colors[(i - 1) % #colors + 1], {
				Shape = if flat then CYL else BALL,
				Material = if flat then Enum.Material.SmoothPlastic else Enum.Material.Neon,
			})
		if flat then
			bit.CFrame = CFrame.new(at) * UP
		end
		local to = at + dir * speed * (0.6 + math.random() * 0.4)
		tween(bit, 0.5, { Position = to, Transparency = 1, Size = bit.Size * 0.4 })
		task.delay(0.55, function()
			bit:Destroy()
		end)
	end
end

local function clearItem(item: Item)
	item.state = "done"
	if item.model then
		item.model:Destroy()
		item.model = nil
	end
	if item.ring then
		item.ring:Destroy()
		item.ring = nil
	end
	if item.shadow then
		item.shadow:Destroy()
		item.shadow = nil
	end
end

local function rootPart(): BasePart?
	local character = Players.LocalPlayer.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	return if root and root:IsA("BasePart") then root else nil
end

local function trayPoint(): Vector3?
	local root = rootPart()
	return root and root.Position + Vector3.new(0, TRAY_ABOVE_ROOT + 0.6, 0)
end

-- The server's word on an item: a catch pops it on the tray, a splat squashes it on the player.
local function resolve(item: Item, verdict: { [string]: any })
	local at = trayPoint() or Vector3.new(item.drop.x, top + CATCH_HEIGHT, item.drop.z)
	if verdict.event == "catch" then
		local gold = item.drop.kind == "gold"
		burst(
			at,
			if gold then { W.Gold, W.Sunny, W.White } else { W.Mint, W.Sunny, W.Pink, W.White },
			if gold then 14 else 9,
			if gold then 6 else 4,
			false
		)
		floatText(
			at + Vector3.new(0, 1.5, 0),
			"+" .. tostring(verdict.points or 1),
			if gold then W.Gold else W.Mint,
			if gold then 46 else 36
		)
		Sounds.play(if gold then "Cash" else "Collect", 0.08, if item.drop.kind == "orb" then 1.2 else 1)
		if tray then
			local scale = tray:GetAttribute("Bounce")
			tray:SetAttribute("Bounce", (if type(scale) == "number" then scale else 0) + 1)
		end
	else
		burst(at - Vector3.new(0, 0.5, 0), { W.WoodDark, W.Coral, W.Honey }, 10, 5, true)
		floatText(at + Vector3.new(0, 1.5, 0), "OUCH!", W.Coral, 40)
		Sounds.play("Error")
	end
	clearItem(item)
end

-- The tray ------------------------------------------------------------------------------------

local function buildTray(parent: Instance)
	local m = Instance.new("Model")
	m.Name = "ShakeTray"
	part(m, Vector3.new(0.3, 7, 7), UP, W.White, { Shape = CYL })
	part(m, Vector3.new(0.32, 6.2, 6.2), CFrame.new(0, 0.02, 0) * UP, W.Pink, { Shape = CYL })
	part(m, Vector3.new(0.34, 3.4, 3.4), CFrame.new(0, 0.04, 0) * UP, W.Sunny, { Shape = CYL })
	part(m, Vector3.new(0.9, 0.5, 0.5), CFrame.new(0, -0.55, 0) * UP, W.Steel, { Shape = CYL })
	m.Parent = parent
	tray = m
	footRing = part(parent, Vector3.new(0.05, CATCH_RADIUS * 2, CATCH_RADIUS * 2), UP, W.Mint, {
		Shape = CYL,
		Material = Enum.Material.Neon,
		Transparency = 0.85,
		Name = "ShakeReach",
	})
end

-- The frame loop ------------------------------------------------------------------------------

local function step()
	local now = Workspace:GetServerTimeNow()
	local root = rootPart()
	local clock = os.clock()
	if tray and root then
		local bounce = tray:GetAttribute("Bounce")
		local dip = 0
		if type(bounce) == "number" and bounce > 0 then
			dip = 0.35
			tray:SetAttribute("Bounce", math.max(0, bounce - 0.15))
		end
		tray:PivotTo(CFrame.new(root.Position + Vector3.new(0, TRAY_ABOVE_ROOT - dip, 0)) * CFrame.Angles(0, clock * 0.6, 0))
		if footRing then
			footRing.CFrame = CFrame.new(root.Position.X, top + 0.05, root.Position.Z) * UP
		end
	end
	local alive = false
	for id, item in items do
		local d = item.drop
		if item.state == "done" then
			items[id] = nil
			continue
		end
		alive = true
		local fall = d.landAt - d.spawnAt
		local alpha = (now - d.spawnAt) / fall
		if item.state == "wait" then
			if alpha < 0 then
				continue
			end
			local parent = folder or Workspace
			item.ring, item.shadow = buildMark(parent, d)
			local model = buildItem(d.kind)
			model.Parent = parent
			item.model = model
			item.state = "fall"
		end
		local model = item.model :: Model
		if item.state == "fall" then
			if alpha < 1 then
				-- Gravity ease: slow at the top, fast near the tray.
				local y = top + CATCH_HEIGHT + DROP_HEIGHT * (1 - alpha * alpha)
				local wobble = if isJunk(d.kind)
					then CFrame.Angles(math.sin(clock * 6 + id) * 0.4, 0, math.cos(clock * 5 + id) * 0.3)
					else CFrame.new()
				model:PivotTo(CFrame.new(d.x, y, d.z) * CFrame.Angles(0, item.spin * clock, 0) * wobble)
				local shadow = item.shadow :: BasePart
				local grow = 1 + alpha * (if isJunk(d.kind) then JUNK_RADIUS else CATCH_RADIUS) * 1.4
				shadow.Size = Vector3.new(0.06, grow, grow)
				shadow.Transparency = 0.85 - 0.4 * alpha
				local ring = item.ring :: BasePart
				ring.Transparency = 0.75 - 0.25 * alpha + math.sin(clock * 10) * 0.05 * alpha
			else
				local verdict = verdicts[id]
				if verdict then
					verdicts[id] = nil
					resolve(item, verdict)
					continue
				end
				local reach = if isJunk(d.kind) then JUNK_RADIUS else CATCH_RADIUS
				local near = root and Vector2.new(root.Position.X - d.x, root.Position.Z - d.z).Magnitude <= reach + 0.75
				if near then
					item.state = "held"
					item.heldAt = clock
				else
					item.state = "floor"
					item.heldAt = clock
				end
				if item.ring then
					item.ring:Destroy()
					item.ring = nil
				end
				if item.shadow then
					item.shadow:Destroy()
					item.shadow = nil
				end
			end
		elseif item.state == "held" then
			local at = trayPoint()
			if at then
				model:PivotTo(CFrame.new(at + Vector3.new(0, 0.6, 0)) * CFrame.Angles(0, item.spin * clock, 0))
			end
			if clock - item.heldAt > HOLD_WAIT then
				-- No word from the server: it slipped off the tray.
				item.state = "floor"
				item.heldAt = clock
			end
		elseif item.state == "floor" then
			local t = clock - item.heldAt
			if t > FLOOR_FADE then
				clearItem(item)
			else
				local pos = model:GetPivot().Position
				local y = math.max(top + 0.8, pos.Y - 60 * (1 / 60))
				local squash = if isJunk(d.kind) and y <= top + 0.81 then 0.5 else 1
				model:PivotTo(CFrame.new(pos.X, y, pos.Z) * CFrame.Angles(0, item.spin * clock, if squash < 1 then math.rad(80) else 0))
				for _, p in model:GetDescendants() do
					if p:IsA("BasePart") and p.Transparency < 1 then
						p.Transparency = math.max(p.Transparency, t / FLOOR_FADE)
					end
				end
			end
		end
	end
	if not running and not alive and stepConn then
		stepConn:Disconnect()
		stepConn = nil
	end
end

local function clearAll()
	for _, item in items do
		clearItem(item)
	end
	table.clear(items)
	table.clear(verdicts)
	if tray then
		tray:Destroy()
		tray = nil
	end
	if footRing then
		footRing:Destroy()
		footRing = nil
	end
end

local function onWave(payload: { [string]: any })
	if type(payload.drops) ~= "table" then
		return
	end
	for _, d in payload.drops do
		if type(d) == "table" and type(d.id) == "number" and type(d.landAt) == "number" and type(d.spawnAt) == "number" then
			items[d.id] = {
				drop = d :: any,
				state = "wait",
				heldAt = 0,
				spin = (if d.id % 2 == 0 then 1 else -1) * (1 + (d.id % 3) * 0.4),
			}
		end
	end
end

local function onVerdict(payload: { [string]: any })
	local id = payload.id
	if type(id) ~= "number" then
		return
	end
	local item = items[id]
	if item and (item.state == "held" or item.state == "floor") then
		resolve(item, payload)
	elseif item and item.state ~= "done" then
		verdicts[id] = payload
	else
		-- Already gone (a slow word): still show the pop on the player.
		resolve({
			drop = { id = id, kind = tostring(payload.kind), x = 0, z = 0, spawnAt = 0, landAt = 0 },
			state = "done",
			heldAt = 0,
			spin = 0,
		}, payload)
	end
end

function Shake.start(_payload: { [string]: any })
	clearAll()
	running = true
	findArena()
	buildTray(folder or Workspace)
	if not stepConn then
		stepConn = RunService.RenderStepped:Connect(step)
	end
end

function Shake.stop(_payload: { [string]: any })
	if not running then
		return
	end
	running = false
	-- Items still in the air are cleared; the step loop ends once nothing is left.
	clearAll()
end

function Shake.init()
	Net.event("Notify").OnClientEvent:Connect(function(payload)
		if type(payload) ~= "table" or payload.kind ~= "Mode" or payload.mode ~= "shake" then
			return
		end
		local event = payload.event
		if event == "start" then
			Shake.start(payload)
		elseif event == "stop" or event == "win" or event == "lose" then
			Shake.stop(payload)
		elseif not running then
			return
		elseif event == "wave" then
			onWave(payload)
		elseif event == "catch" or event == "splat" then
			onVerdict(payload)
		end
	end)
end

return Shake
