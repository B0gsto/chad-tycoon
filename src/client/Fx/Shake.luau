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
	  * in the lobby (phase "lobby") a practice warm-up: slow demo drops (a good item, now and
	    then a junk one) into the arena's "PracticeArea" part, judged here only (nothing is
	    sent or scored), with "NICE!" / "OUCH!" / "DODGED!" feedback and the tray shown while
	    the player stands in the practice area;
	  * a short camera kick when junk food costs a heart;
	  * at the land time an item over the tray waits there for the server's word ("catch":
	    sparkles and a floating "+1" / "+3"; "splat": a junk splat and "OUCH!"); anything else
	    hits the sand and fades (junk squashes flat).
	Parts live in the arena's "Items" folder (World.ShakeArena), never collide or query.

	Main.client.luau calls init() once (it is in the Fx list); nothing else needs editing:
	  init()            connects the Notify and State listeners
	  start(payload)    "start": the lobby (phase "lobby"), or a run on an older server
	  stop(payload)     the player left the mode ("stop")
	Phases follow docs/minigames.md: "start" { phase = "lobby" } and a snapshot phase of
	"lobby" start the practice; "countdown" (or the first "wave") starts the run; "win" /
	"lose" clear it.
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
-- Practice drops (lobby): one every PRACTICE_GAP seconds, PRACTICE_FALL seconds in the air,
-- from PRACTICE_DROP studs above the catch height (or the PracticeArea's DropY attribute),
-- only while the player is within PRACTICE_NEAR studs of the area; at most PRACTICE_MAX alive.
local PRACTICE_GAP = 2.6
local PRACTICE_FALL = 2.6
local PRACTICE_DROP = 22
local PRACTICE_NEAR = 70
local PRACTICE_MAX = 3
-- Every PRACTICE_JUNK-th practice drop also brings a junk item.
local PRACTICE_JUNK = 3
local PRACTICE_GOOD = { "shake", "shake", "gold", "orb" }
local PRACTICE_BAD = { "burger", "donut", "soda" }
local CAM_STEP = "ShakeCatchCamKick"

type Drop = { id: number, kind: string, x: number, z: number, spawnAt: number, landAt: number }
type Item = {
	drop: Drop,
	-- Practice drops are judged here (nothing is sent); run drops wait for the server's word.
	practice: boolean,
	-- The ground the mark sits on, the catch height and the start height (world y).
	floorY: number,
	catchY: number,
	fromY: number,
	model: Model?,
	shadow: BasePart?,
	ring: BasePart?,
	-- "wait" (not shown yet), "fall", "held", "floor", "done"
	state: string,
	heldAt: number,
	spin: number,
}

-- "" (not in the mode), "lobby" (practice), "run" (countdown and play), "results".
local mode = ""
local items: { [number]: Item } = {}
-- Server verdicts that came in before the item landed (id -> "catch" / "splat" payload).
local verdicts: { [number]: { [string]: any } } = {}
local arena: Model? = nil
local folder: Instance? = nil
local top = 6
local tray: Model? = nil
local footRing: BasePart? = nil
local stepConn: RBXScriptConnection? = nil
-- The arena's practice tray (from the "PracticeArea" part), nil if the arena has none.
type Practice = { x0: number, x1: number, z0: number, z1: number, floor: number, dropY: number }
local practice: Practice? = nil
local practiceLookAt = -math.huge
local nextPracticeAt = 0
local practiceCount = 0
local practiceId = 0
-- Tray dip after a catch (1 = full dip, decays with time).
local trayKick = 0
-- Camera kick (heart lost).
local kickEnd = 0
local kickTime = 0.3
local kickMag = 0
local kickBound = false

local function isJunk(kind: string): boolean
	return kind == "burger" or kind == "donut" or kind == "soda"
end

local function findArena(): Model?
	if arena and arena.Parent then
		return arena
	end
	-- Arenas are children of the map folder (World.Arena).
	local map = Workspace:FindFirstChild("Map")
	for _, holder in { map or Workspace, Workspace } do
		for _, inst in holder:GetChildren() do
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
	end
	return nil
end

-- The practice tray's bounds from the arena's "PracticeArea" part (world box, any rotation).
-- A thin part (up to 4 studs) is the tray itself: drops land on its top face; a taller one is
-- a volume: they land on its bottom face. Optional attribute DropY: the drops' start height.
local function findPractice(): Practice?
	local now = os.clock()
	if practice or now - practiceLookAt < 3 then
		return practice
	end
	practiceLookAt = now
	local model = findArena()
	local area = model and model:FindFirstChild("PracticeArea", true)
	if not (area and area:IsA("BasePart")) then
		return nil
	end
	local cf, half = area.CFrame, area.Size / 2
	local function extent(axis: Vector3): number
		return math.abs(cf.RightVector:Dot(axis)) * half.X
			+ math.abs(cf.UpVector:Dot(axis)) * half.Y
			+ math.abs(cf.LookVector:Dot(axis)) * half.Z
	end
	local ex, ey, ez = extent(Vector3.xAxis), extent(Vector3.yAxis), extent(Vector3.zAxis)
	local pos = area.Position
	local floor = if area.Size.Y <= 4 then pos.Y + ey else pos.Y - ey
	local dropY = area:GetAttribute("DropY")
	practice = {
		x0 = pos.X - ex,
		x1 = pos.X + ex,
		z0 = pos.Z - ez,
		z1 = pos.Z + ez,
		floor = floor,
		dropY = if type(dropY) == "number" then dropY else floor + CATCH_HEIGHT + PRACTICE_DROP,
	}
	return practice
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
-- Junk also gets a cross in its ring (coral and mint alone are hard to tell apart for some
-- colour-blind players); gold's ring is gold (worth 3).
local function buildMark(parent: Instance, drop: Drop, floorY: number): (BasePart, BasePart)
	local junk = isJunk(drop.kind)
	local d = (if junk then JUNK_RADIUS else CATCH_RADIUS) * 2
	local at = Vector3.new(drop.x, floorY + 0.06, drop.z)
	local color = if junk then W.Coral elseif drop.kind == "gold" then W.Gold else W.Mint
	local ring = part(parent, Vector3.new(0.05, d, d), CFrame.new(at) * UP, color, {
		Shape = CYL,
		Material = Enum.Material.Neon,
		Transparency = 0.75,
		Name = "ShakeRing",
	})
	if junk then
		for _, a in { 45, -45 } do
			part(
				ring,
				Vector3.new(d * 0.62, 0.06, 0.5),
				CFrame.new(at + Vector3.new(0, 0.03, 0)) * CFrame.Angles(0, math.rad(a), 0),
				W.Coral,
				{
					Material = Enum.Material.Neon,
					Transparency = 0.35,
					Name = "Cross",
				}
			)
		end
	end
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

-- A short camera kick (a heart lost): applied after the camera scripts, fading out.
local function cameraKick(strength: number, time: number)
	kickEnd = os.clock() + time
	kickTime = time
	kickMag = strength
	if kickBound then
		return
	end
	kickBound = true
	RunService:BindToRenderStep(CAM_STEP, Enum.RenderPriority.Camera.Value + 1, function()
		local left = kickEnd - os.clock()
		local camera = Workspace.CurrentCamera
		if left <= 0 or not camera then
			kickBound = false
			RunService:UnbindFromRenderStep(CAM_STEP)
			return
		end
		local k = kickMag * left / kickTime
		camera.CFrame = camera.CFrame
			* CFrame.new((math.random() - 0.5) * k, (math.random() - 0.5) * k, 0)
			* CFrame.Angles(0, 0, (math.random() - 0.5) * k * 0.06)
	end)
end

-- The catch pop on the tray: sparkles, the floating word, the sound and the tray dip.
local function catchPop(at: Vector3, kind: string, text: string)
	local gold = kind == "gold"
	burst(
		at,
		if gold
			then { W.Gold, W.Sunny, W.White }
			elseif kind == "orb" then { W.Grape, W.SkyBlue, W.White }
			else { W.Mint, W.Sunny, W.Pink, W.White },
		if gold then 14 else 10,
		if gold then 6 else 4.5,
		false
	)
	floatText(at + Vector3.new(0, 1.5, 0), text, if gold then W.Gold else W.Mint, if gold then 46 else 36)
	Sounds.play(if gold then "Cash" else "Collect", 0.08, if kind == "orb" then 1.2 else 1)
	trayKick = 1
end

-- The splat on the player: goo, "OUCH!", the sound and (in a run) the camera kick.
local function splatPop(at: Vector3, kick: boolean)
	burst(at - Vector3.new(0, 0.5, 0), { W.WoodDark, W.Coral, W.Honey }, 12, 5.5, true)
	floatText(at + Vector3.new(0, 1.5, 0), "OUCH!", W.Coral, 42)
	Sounds.play("Error")
	trayKick = 1.4
	if kick then
		cameraKick(0.9, 0.3)
	end
end

-- The server's word on an item: a catch pops it on the tray, a splat squashes it on the player.
local function resolve(item: Item, verdict: { [string]: any })
	local at = trayPoint() or Vector3.new(item.drop.x, item.catchY, item.drop.z)
	if verdict.event == "catch" then
		catchPop(at, item.drop.kind, "+" .. tostring(verdict.points or 1))
	else
		splatPop(at, true)
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

local function clearTray()
	if tray then
		tray:Destroy()
		tray = nil
	end
	if footRing then
		footRing:Destroy()
		footRing = nil
	end
end

-- Practice (lobby) ----------------------------------------------------------------------------

local function inPractice(area: Practice, pos: Vector3, margin: number): boolean
	return pos.X >= area.x0 - margin
		and pos.X <= area.x1 + margin
		and pos.Z >= area.z0 - margin
		and pos.Z <= area.z1 + margin
		and math.abs(pos.Y - area.floor) < 14
end

local function addPractice(area: Practice, kind: string, x: number, z: number, now: number)
	practiceId -= 1
	local catchY = area.floor + CATCH_HEIGHT
	items[practiceId] = {
		drop = { id = practiceId, kind = kind, x = x, z = z, spawnAt = now, landAt = now + PRACTICE_FALL },
		practice = true,
		floorY = area.floor,
		catchY = catchY,
		fromY = math.max(area.dropY, catchY + 4),
		state = "wait",
		heldAt = 0,
		spin = if practiceId % 2 == 0 then 1 else -1,
	}
end

-- Drops the next demo item(s) when it is time and the player is close enough to see them.
local function practiceTick(root: BasePart?, now: number)
	local area = findPractice()
	if not area or not root or now < nextPracticeAt then
		return
	end
	nextPracticeAt = now + PRACTICE_GAP
	if not inPractice(area, root.Position, PRACTICE_NEAR) then
		return
	end
	local alive = 0
	for id, item in items do
		if id < 0 and item.state ~= "done" then
			alive += 1
		end
	end
	if alive >= PRACTICE_MAX then
		return
	end
	local pad = math.min(2.5, (area.x1 - area.x0) / 4, (area.z1 - area.z0) / 4)
	local function spot(): (number, number)
		return area.x0 + pad + math.random() * math.max(0, area.x1 - area.x0 - 2 * pad),
			area.z0 + pad + math.random() * math.max(0, area.z1 - area.z0 - 2 * pad)
	end
	practiceCount += 1
	local gx, gz = spot()
	addPractice(area, PRACTICE_GOOD[(practiceCount - 1) % #PRACTICE_GOOD + 1], gx, gz, now)
	if practiceCount % PRACTICE_JUNK == 0 then
		-- The junk lands clear of the good one (if the tray is big enough for that).
		local jx, jz = spot()
		for _ = 1, 6 do
			if Vector2.new(jx - gx, jz - gz).Magnitude >= CATCH_RADIUS + JUNK_RADIUS + 1 then
				break
			end
			jx, jz = spot()
		end
		if Vector2.new(jx - gx, jz - gz).Magnitude >= CATCH_RADIUS + JUNK_RADIUS + 1 then
			addPractice(area, PRACTICE_BAD[math.random(#PRACTICE_BAD)], jx, jz, now + 0.6)
		end
	end
end

-- A practice drop reached the tray height: judged here, nothing is sent.
local function judgePractice(item: Item, root: BasePart?): boolean
	local d = item.drop
	local junk = isJunk(d.kind)
	if not root then
		return false
	end
	local flat = Vector2.new(root.Position.X - d.x, root.Position.Z - d.z).Magnitude
	local level = math.abs(root.Position.Y - TRAY_ABOVE_ROOT - item.floorY) < 6
	local at = trayPoint() or Vector3.new(d.x, item.catchY, d.z)
	if level and flat <= (if junk then JUNK_RADIUS else CATCH_RADIUS) + 0.5 then
		if junk then
			splatPop(at, false)
		else
			catchPop(at, d.kind, "NICE!")
		end
		clearItem(item)
		return true
	end
	if junk and level and flat <= JUNK_RADIUS + 7 then
		floatText(Vector3.new(d.x, item.catchY, d.z), "DODGED!", W.Mint, 30)
	end
	return false
end

-- The frame loop ------------------------------------------------------------------------------

local function step(dt: number)
	local now = Workspace:GetServerTimeNow()
	local root = rootPart()
	local clock = os.clock()
	if mode == "lobby" then
		practiceTick(root, now)
		-- The tray only shows while the player stands in the practice area.
		local area = practice
		local want = area ~= nil and root ~= nil and inPractice(area, root.Position, 3)
		if want and not tray then
			buildTray(folder or Workspace)
		elseif not want and tray then
			clearTray()
		end
	end
	trayKick = math.max(0, trayKick - dt * 5)
	if tray and root then
		local dip = 0.45 * math.min(trayKick, 1)
		local tilt = math.sin(trayKick * 8) * 0.06 * trayKick
		tray:PivotTo(CFrame.new(root.Position + Vector3.new(0, TRAY_ABOVE_ROOT - dip, 0)) * CFrame.Angles(tilt, clock * 0.6, tilt * 0.5))
		if footRing then
			local ground = if mode == "lobby" and practice then practice.floor else top
			footRing.CFrame = CFrame.new(root.Position.X, ground + 0.05, root.Position.Z) * UP
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
		local fall = math.max(d.landAt - d.spawnAt, 0.05)
		local alpha = (now - d.spawnAt) / fall
		local junk = isJunk(d.kind)
		if item.state == "wait" then
			if alpha < 0 then
				continue
			end
			local parent = folder or Workspace
			item.ring, item.shadow = buildMark(parent, d, item.floorY)
			local model = buildItem(d.kind)
			-- Start on the landing column (a drop first seen late would otherwise sit at the origin).
			local a = math.clamp(alpha, 0, 1)
			model:PivotTo(CFrame.new(d.x, item.catchY + (item.fromY - item.catchY) * (1 - a * a), d.z))
			model.Parent = parent
			item.model = model
			item.state = "fall"
		end
		local model = item.model :: Model
		if item.state == "fall" then
			if alpha < 1 then
				-- Gravity ease: slow at the top, fast near the tray.
				local y = item.catchY + (item.fromY - item.catchY) * (1 - alpha * alpha)
				local wobble = if junk
					then CFrame.Angles(math.sin(clock * 6 + id) * 0.4, 0, math.cos(clock * 5 + id) * 0.3)
					else CFrame.new()
				model:PivotTo(CFrame.new(d.x, y, d.z) * CFrame.Angles(0, item.spin * clock, 0) * wobble)
				local shadow = item.shadow :: BasePart
				local grow = 1 + alpha * (if junk then JUNK_RADIUS else CATCH_RADIUS) * 1.4
				shadow.Size = Vector3.new(0.06, grow, grow)
				shadow.Transparency = 0.85 - 0.45 * alpha
				local ring = item.ring :: BasePart
				-- The ring pulses faster in the last half second (it is about to land).
				local pulse = if alpha > 1 - 0.5 / fall then 18 else 8
				ring.Transparency = 0.72 - 0.32 * alpha + math.sin(clock * pulse) * 0.08 * alpha
			else
				if item.practice then
					if judgePractice(item, root) then
						continue
					end
					item.state = "floor"
					item.heldAt = clock
				else
					local verdict = verdicts[id]
					if verdict then
						verdicts[id] = nil
						resolve(item, verdict)
						continue
					end
					local reach = if junk then JUNK_RADIUS else CATCH_RADIUS
					local near = root and Vector2.new(root.Position.X - d.x, root.Position.Z - d.z).Magnitude <= reach + 0.75
					item.state = if near then "held" else "floor"
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
				local rest = item.floorY + 0.8
				local y = math.max(rest, pos.Y - 60 * dt)
				local flat = junk and y <= rest + 0.01
				model:PivotTo(CFrame.new(pos.X, y, pos.Z) * CFrame.Angles(0, item.spin * clock, if flat then math.rad(80) else 0))
				for _, p in model:GetDescendants() do
					if p:IsA("BasePart") and p.Transparency < 1 then
						p.Transparency = math.max(p.Transparency, t / FLOOR_FADE)
					end
				end
			end
		end
	end
	if (mode == "" or mode == "results") and not alive and stepConn then
		stepConn:Disconnect()
		stepConn = nil
	end
end

local function ensureStep()
	if not stepConn then
		stepConn = RunService.RenderStepped:Connect(step)
	end
end

local function clearAll()
	for _, item in items do
		clearItem(item)
	end
	table.clear(items)
	table.clear(verdicts)
	clearTray()
end

local function onWave(payload: { [string]: any })
	if type(payload.drops) ~= "table" then
		return
	end
	for _, d in payload.drops do
		if type(d) == "table" and type(d.id) == "number" and type(d.landAt) == "number" and type(d.spawnAt) == "number" then
			items[d.id] = {
				drop = d :: any,
				practice = false,
				floorY = top,
				catchY = top + CATCH_HEIGHT,
				fromY = top + CATCH_HEIGHT + DROP_HEIGHT,
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
			practice = false,
			floorY = top,
			catchY = top + CATCH_HEIGHT,
			fromY = top + CATCH_HEIGHT,
			state = "done",
			heldAt = 0,
			spin = 0,
		}, payload)
	end
end

-- Lobby: the practice warm-up (the run's items and tray go).
local function enterLobby()
	if mode == "lobby" then
		return
	end
	clearAll()
	mode = "lobby"
	findArena()
	practice = nil
	practiceLookAt = -math.huge
	nextPracticeAt = Workspace:GetServerTimeNow() + 0.8
	ensureStep()
end

-- Countdown and play: practice drops go, the tray comes up.
local function enterRun()
	if mode == "run" then
		return
	end
	clearAll()
	mode = "run"
	findArena()
	buildTray(folder or Workspace)
	ensureStep()
end

function Shake.start(payload: { [string]: any })
	if payload.phase == "lobby" or type(payload.goAt) ~= "number" then
		enterLobby()
	else
		-- An older server: "start" begins the run straight away.
		enterRun()
	end
end

function Shake.stop(_payload: { [string]: any })
	if mode == "" then
		return
	end
	mode = ""
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
		elseif event == "stop" then
			Shake.stop(payload)
		elseif event == "lobby" then
			enterLobby()
		elseif event == "countdown" then
			enterRun()
		elseif event == "win" or event == "lose" then
			if mode ~= "" then
				clearAll()
				mode = "results"
			end
		elseif event == "wave" then
			-- The first wave can beat a lost "countdown".
			if mode == "lobby" then
				enterRun()
			end
			if mode == "run" then
				onWave(payload)
			end
		elseif mode == "run" and (event == "catch" or event == "splat") then
			onVerdict(payload)
		end
	end)
	-- The snapshot's phase is the safety net for a lost Notify (and the way back to the lobby).
	Net.event("State").OnClientEvent:Connect(function(data)
		local modes = type(data) == "table" and data.modes
		local info = type(modes) == "table" and modes.shake
		if type(info) ~= "table" then
			return
		end
		if info.running ~= true then
			if mode == "lobby" or mode == "run" then
				Shake.stop({})
			end
			return
		end
		local phase = info.phase
		if phase == "lobby" then
			enterLobby()
		elseif (phase == "countdown" or phase == "play") and (mode == "" or mode == "lobby") then
			enterRun()
		elseif phase == "results" and mode == "run" then
			-- The finish Notify is late or lost: the run's drops go.
			clearAll()
			mode = "results"
		end
	end)
end

return Shake
