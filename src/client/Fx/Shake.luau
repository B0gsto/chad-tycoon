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
	  * the player's own avatar does the catching (Fx.PlayerPose, layered so the legs keep
	    walking): it carries a striped tray in both hands (the tray rides on the hands every
	    frame, the arms hold a carry pose). A catch is a quick knee dip and a lift of the
	    tray, a golden one a deep coil and a hop with the tray pressed overhead; junk food
	    makes it flinch back, head turned away; a win hoists the tray like a trophy with two
	    hops, a loss slumps. The joints go back to the avatar's own animations when the tray
	    goes (lobby, practice area left, the visit over). A faint ring on the ground under the
	    tray shows how far it reaches. Nothing on the player glows;
	  * in the lobby (phase "lobby") a practice warm-up: slow demo drops (a good item, now and
	    then a junk one) into the arena's "PracticeArea" part, judged here only (nothing is
	    sent or scored), with "NICE!" / "OUCH!" / "DODGED!" feedback and the tray shown while
	    the player stands in the practice area;
	  * a short camera kick when junk food costs a heart;
	  * catches are predicted here at the land time, from the same point the server judges
	    (the tray, ShakeRules.TRAY_AHEAD in front of the root, inside the kind's catch radius
	    within its window): the catch pops at once (sparkles, "+1" / "+3", the sound, the
	    tray dip; junk: the splat, "OUCH!", the flinch). The server's "catch" / "splat" only
	    confirms it (the HUD's hearts follow the server; its score shows predicted catches at
	    once, through onPredict, and settles on the server's); a prediction the server
	    never confirms gets a gentle correction ("MISSED" / "PHEW!") after holdWait(), and a
	    server catch the client did not predict pops when it comes. Junk is predicted with a
	    smaller radius than the server's (PREDICT_JUNK_RADIUS): the client checks the tray
	    every frame, the server only on its ticks, so a graze here must not cry "OUCH!" for a
	    hit the server never sees. Anything not caught
	    hits the sand and fades (junk squashes flat).
	Parts live in the arena's "Items" folder (World.ShakeArena), never collide or query.

	Main.client.luau calls init() once (it is in the Fx list); nothing else needs editing:
	  init()            connects the Notify and State listeners
	  start(payload)    "start": the lobby (phase "lobby"), or a run on an older server
	  stop(payload)     the player left the mode ("stop")
	  onPredict(fn)     UI.ShakeHud listens: fn("catch", id, points) when a good item is
	                    predicted caught here, fn("missed", id, points) when the server never
	                    confirmed it
	Phases follow docs/minigames.md: "start" { phase = "lobby" } and a snapshot phase of
	"lobby" start the practice; "countdown" (or the first "wave") starts the run; "win" /
	"lose" clear its drops while the avatar reacts with the tray; "lobby" takes the tray.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Net = require(ReplicatedStorage.Shared.Net)
local Theme = require(ReplicatedStorage:WaitForChild("Theme")) :: any

local PlayerPose = require(script.Parent.PlayerPose)
local Sounds = require(script.Parent.Parent.Sounds) :: any

local W = Theme.World

local Shake = {}

-- Mirrors of ShakeRules (server-only): catch radius of good items and junk, the drop height
-- above the floor and (roughly) the tray's height above the root.
local CATCH_RADIUS = 4.5
local JUNK_RADIUS = 3
-- Junk is only predicted a hit inside this (smaller) radius: the server judges root samples
-- from its ~10 Hz ticks inside a 0.2 s window (Modes.Shake, ShakeRules.JUNK), this module the
-- tray every frame, so a near-graze must err toward "no hit".
local PREDICT_JUNK_RADIUS = JUNK_RADIUS * 0.7
local DROP_HEIGHT = 40
local TRAY_ABOVE_ROOT = 0.8
-- Items reach the tray's height (above the floor) at their land time.
local CATCH_HEIGHT = 4.2
-- The tray: its diameter, how far its centre sits past the hands (they hold its back half
-- from under it) and how high its centre sits over the hands' centres.
local TRAY_SIZE = 5.4
local TRAY_REACH = 1.3
local TRAY_ON_HANDS = 0.38
-- Catch windows (seconds before / after the land time) and the tray's judge point in front
-- of the root: mirrors of ShakeRules.CATCH, ShakeRules.JUNK and ShakeRules.TRAY_AHEAD.
local CATCH_EARLY = 0.3
local CATCH_LATE = 0.3
local JUNK_LATE = 0.2
local TRAY_AHEAD = 2
-- A predicted catch waits at least HOLD_WAIT seconds after the land time for the server's
-- word before it is corrected; more on a slow connection (holdWait: the server judges
-- SETTLE plus its lag, at most LAG_MAX, after the land, then the word takes half a round
-- trip back).
local HOLD_WAIT = 1.0
local SETTLE = 0.3
local LAG_MAX = 0.4
-- Seconds of the tray's judge points kept for the early part of the catch window.
local TRAIL_KEEP = 0.5
-- How long the flinch plays: a loss right after junk food waits for it.
local FLINCH_TIME = 0.5
-- Speed (studs/s) an uncaught item drops past the tray in the late part of its window.
local LATE_DROP = 14
local MISS_COLOR = Color3.fromRGB(205, 210, 222)
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
	-- "wait" (not shown yet), "fall", "landing" (the late window), "predicted" (popped here,
	-- waiting for the server's word), "floor", "done"
	state: string,
	heldAt: number,
	spin: number,
}

-- UI.ShakeHud's provisional score (Shake.onPredict).
local predictListeners: { (string, number, number) -> () } = {}
local function tellPredict(event: string, d: Drop)
	local points = if d.kind == "gold" then 3 else 1
	for _, fn in predictListeners do
		task.spawn(fn, event, d.id, points)
	end
end

function Shake.onPredict(fn: (event: string, id: number, points: number) -> ())
	table.insert(predictListeners, fn)
end

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
-- Tray wobble after a catch (1 = full, decays with time).
local trayKick = 0
-- The tray's judge points (server time, x, z) of the last TRAIL_KEEP seconds of a run.
local trail: { { t: number, x: number, z: number } } = {}
-- os.clock() the last flinch started (a loss waits for it).
local flinchAt = -math.huge
-- The local avatar holding the tray (Fx.PlayerPose, layered) and the character it holds.
local poser: PlayerPose.Poser? = nil
local posedFor: Model? = nil
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

-- Where catches are judged: TRAY_AHEAD studs in front of the root along its flat look
-- (ShakeRules.judgePoint), at the root's height.
local function judgePoint(root: BasePart): Vector3
	local look = root.CFrame.LookVector
	local flat = Vector3.new(look.X, 0, look.Z)
	if flat.Magnitude < 1e-3 then
		return root.Position
	end
	return root.Position + flat.Unit * TRAY_AHEAD
end

-- True when the judge point (x, z) is inside the drop's predicted catch radius (junk:
-- PREDICT_JUNK_RADIUS, a little inside the server's).
local function reaches(x: number, z: number, d: Drop): boolean
	local r = if isJunk(d.kind) then PREDICT_JUNK_RADIUS else CATCH_RADIUS
	local dx, dz = x - d.x, z - d.z
	return dx * dx + dz * dz <= r * r
end

-- The tray's top centre (where caught items rest), or over the root while there is no tray.
local function trayPoint(): Vector3?
	local t = tray
	if t then
		return (t:GetPivot() * CFrame.new(0, 0.3, 0)).Position
	end
	local root = rootPart()
	return root and root.Position + Vector3.new(0, TRAY_ABOVE_ROOT + 0.6, 0)
end

-- The avatar ---------------------------------------------------------------------------------

local SINE, QUAD, BACK = Enum.EasingStyle.Sine, Enum.EasingStyle.Quad, Enum.EasingStyle.Back
local IN, IN_OUT = Enum.EasingDirection.In, Enum.EasingDirection.InOut

-- A root offset: `back` studs backward, leaning back `lean` degrees, turned `turn` degrees to
-- the avatar's left, rolled `roll`.
local function at(back: number, lean: number?, turn: number?, roll: number?): CFrame
	return CFrame.new(0, 0, back) * CFrame.Angles(math.rad(lean or 0), math.rad(turn or 0), math.rad(roll or 0))
end

local CARRY: PlayerPose.Key = { pose = "ShakeCarry", blend = 0.3, ease = BACK }

local MOVES: { [string]: { PlayerPose.Key } } = {
	-- Picking the tray up.
	carry = { CARRY },
	-- A catch: knee dip, then the tray lifted with a little bounce, back to the carry.
	catch = {
		{ pose = "ShakeDip", blend = 0.08, ease = QUAD, hold = 0.03 },
		{ pose = "ShakeLift", blend = 0.13, ease = BACK, hop = 0.14, hopTime = 0.22, hold = 0.06 },
		{ pose = "ShakeCarry", blend = 0.26, ease = SINE, dir = IN_OUT },
	},
	-- A golden catch: a deep coil, a hop with the tray pressed overhead, a soft landing.
	gold = {
		{ pose = "ShakeGoldCrouch", blend = 0.1, ease = QUAD, hold = 0.04 },
		{ pose = "ShakeGoldPop", blend = 0.16, ease = BACK, hop = 1.1, hopTime = 0.42, hold = 0.3 },
		{ pose = "ShakeDip", blend = 0.1, ease = QUAD, dir = IN, hold = 0.05 },
		{ pose = "ShakeCarry", blend = 0.3, ease = BACK },
	},
	-- Junk food hit: a recoil back and away, a sway, then the tray back up.
	flinch = {
		{ pose = "ShakeFlinch", blend = 0.07, ease = QUAD, root = at(0.55, 12, -10, 4), hop = 0.18, hopTime = 0.2, hold = 0.14 },
		{ pose = "ShakeFlinch", blend = 0.2, ease = SINE, dir = IN_OUT, root = at(0.25, 5, 6, -3), hold = 0.14 },
		{ pose = "ShakeCarry", blend = 0.34, ease = BACK },
	},
	-- A win: coil, a trophy hop with the tray overhead, again, then back to the carry.
	win = {
		{ pose = "ShakeGoldCrouch", blend = 0.12, ease = QUAD, hold = 0.05 },
		{ pose = "ShakeCheer", blend = 0.18, ease = BACK, hop = 1.3, hopTime = 0.46, hold = 0.32 },
		{ pose = "ShakeGoldCrouch", blend = 0.1, ease = QUAD, dir = IN, hold = 0.05 },
		{ pose = "ShakeCheer", blend = 0.16, ease = BACK, hop = 0.9, hopTime = 0.4, hold = 1.1 },
		{ pose = "ShakeCarry", blend = 0.45, ease = SINE, dir = IN_OUT },
	},
	-- A loss: a jolt back, then a long slump, then the tray picked back up.
	lose = {
		{ pose = "ShakeFlinch", blend = 0.12, ease = QUAD, root = at(0.3, 8), hold = 0.12 },
		{ pose = "ShakeSlump", blend = 0.5, ease = SINE, dir = IN_OUT, root = at(0.1, -4), hold = 1.8 },
		{ pose = "ShakeCarry", blend = 0.6, ease = SINE, dir = IN_OUT },
	},
}

-- Lets the local avatar go: its joints go back to its own animations.
local function releaseAvatar()
	if poser then
		poser:stop()
	end
	poser = nil
	posedFor = nil
end

-- The poser holding the local avatar (attached again after a respawn), nil for an R6 avatar.
local function holdAvatar(): PlayerPose.Poser?
	local character = Players.LocalPlayer.Character
	if posedFor == character and (poser == nil or (character and character.Parent)) then
		return poser
	end
	releaseAvatar()
	posedFor = character
	poser = PlayerPose.attach(character, true)
	if poser then
		poser:play(MOVES.carry)
	end
	return poser
end

-- Plays one of MOVES on the avatar while it holds the tray.
local function move(name: string)
	local p = if tray then holdAvatar() else nil
	if p then
		p:play(MOVES[name])
	end
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

-- A catch: the avatar dips and lifts the tray (a golden one: the hop with the tray overhead),
-- a few crumbs of the item off the tray, the floating word and the sound.
local function catchPop(at: Vector3, kind: string, text: string)
	local gold = kind == "gold"
	move(if gold then "gold" else "catch")
	burst(
		at,
		if gold
			then { W.Gold, W.Sunny, W.White }
			elseif kind == "orb" then { W.Grape, W.SkyBlue, W.White }
			else { W.Mint, W.Sunny, W.Pink, W.White },
		8,
		3.5,
		false
	)
	floatText(at + Vector3.new(0, 1.5, 0), text, if gold then W.Gold else W.Mint, if gold then 46 else 36)
	Sounds.play(if gold then "Cash" else "Collect", 0.08, if kind == "orb" then 1.2 else 1)
	trayKick = if gold then 0.4 else 0.6
end

-- Junk food on the tray: the avatar flinches back, goo off the tray, "OUCH!", the sound and
-- (in a run) the camera kick.
local function splatPop(at: Vector3, kick: boolean)
	move("flinch")
	flinchAt = os.clock()
	burst(at - Vector3.new(0, 0.3, 0), { W.WoodDark, W.Coral, W.Honey }, 10, 4.5, true)
	floatText(at + Vector3.new(0, 1.5, 0), "OUCH!", W.Coral, 42)
	Sounds.play("Error")
	trayKick = 1
	if kick then
		cameraKick(0.9, 0.3)
	end
end

-- The item's parts go (its record stays: a predicted catch still waits for the word).
local function dropParts(item: Item)
	for _, key in { "model", "ring", "shadow" } do
		local inst = (item :: any)[key]
		if inst then
			inst:Destroy();
			(item :: any)[key] = nil
		end
	end
end

-- A catch predicted at the land time: the pop plays now; the server's word only confirms it.
local function predict(item: Item)
	local d = item.drop
	local at = trayPoint() or Vector3.new(d.x, item.catchY, d.z)
	if isJunk(d.kind) then
		splatPop(at, true)
	else
		catchPop(at, d.kind, if d.kind == "gold" then "+3" else "+1")
		tellPredict("catch", d)
	end
	dropParts(item)
	item.state = "predicted"
end

-- The server never confirmed a predicted catch: a gentle word instead of a second pop.
local function correct(item: Item)
	local d = item.drop
	local at = (trayPoint() or Vector3.new(d.x, item.catchY, d.z)) + Vector3.new(0, 2.2, 0)
	if isJunk(d.kind) then
		floatText(at, "PHEW!", W.Mint, 24)
	else
		floatText(at, "MISSED", MISS_COLOR, 24)
		tellPredict("missed", d)
	end
end

-- Seconds after the land time a predicted catch waits for the server's word.
local function holdWait(): number
	local ok, ping = pcall(function()
		return Players.LocalPlayer:GetNetworkPing()
	end)
	local rtt = if ok and type(ping) == "number" and ping == ping then math.clamp(ping, 0, 2) else 0.2
	return math.max(HOLD_WAIT, SETTLE + math.min(rtt / 2 + 1 / 30, LAG_MAX) + 0.1 + rtt / 2 + 0.25)
end

-- True when the tray was over the drop in the early part of its window (the trail).
local function trailHit(d: Drop): boolean
	local from = d.landAt - (if isJunk(d.kind) then 0 else CATCH_EARLY)
	for _, s in trail do
		if s.t >= from and reaches(s.x, s.z, d) then
			return true
		end
	end
	return false
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

-- The tray the avatar carries: a white rim, a pink face with a sunny centre and a raised lip.
-- Its pivot is the middle of the plate (the step loop seats it on the hands every frame).
local function buildTray(parent: Instance)
	local m = Instance.new("Model")
	m.Name = "ShakeTray"
	part(m, Vector3.new(0.24, TRAY_SIZE, TRAY_SIZE), UP, W.White, { Shape = CYL })
	part(m, Vector3.new(0.26, TRAY_SIZE - 0.7, TRAY_SIZE - 0.7), CFrame.new(0, 0.02, 0) * UP, W.Pink, { Shape = CYL })
	part(m, Vector3.new(0.28, TRAY_SIZE * 0.45, TRAY_SIZE * 0.45), CFrame.new(0, 0.04, 0) * UP, W.Sunny, { Shape = CYL })
	-- The lip: short white blocks round the rim.
	local segments = 16
	for i = 1, segments do
		local a = (i / segments) * math.pi * 2
		local r = TRAY_SIZE / 2 - 0.12
		part(
			m,
			Vector3.new(0.24, 0.3, TRAY_SIZE * math.pi / segments + 0.05),
			CFrame.new(math.cos(a) * r, 0.2, math.sin(a) * r) * CFrame.Angles(0, -a, 0),
			W.White
		)
	end
	m.WorldPivot = CFrame.identity
	m.Parent = parent
	tray = m
	footRing = part(parent, Vector3.new(0.05, CATCH_RADIUS * 2, CATCH_RADIUS * 2), UP, W.Mint, {
		Shape = CYL,
		Transparency = 0.72,
		Name = "ShakeReach",
	})
end

local function clearTray()
	releaseAvatar()
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
	local point = judgePoint(root)
	local flat = Vector2.new(point.X - d.x, point.Z - d.z).Magnitude
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

-- Where the tray sits: on the avatar's hands (its back half over them, level across them, so
-- it tilts and rises with every arm move), or just over the head of an avatar without hands.
local function trayFrame(root: BasePart): CFrame
	local character = root.Parent
	local left = character and character:FindFirstChild("LeftHand")
	local right = character and character:FindFirstChild("RightHand")
	if left and right and left:IsA("BasePart") and right:IsA("BasePart") then
		local across = right.Position - left.Position
		local side = if across.Magnitude > 0.2 then across.Unit else root.CFrame.RightVector
		local up = Vector3.yAxis - side * side.Y
		up = if up.Magnitude > 1e-3 then up.Unit else Vector3.yAxis
		local hands = CFrame.fromMatrix((left.Position + right.Position) / 2, side, up)
		return hands * CFrame.new(0, TRAY_ON_HANDS, -TRAY_REACH)
	end
	return CFrame.new(root.Position + Vector3.new(0, 3.4, 0))
end

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
		holdAvatar()
		local tilt = math.sin(trayKick * 8) * 0.07 * trayKick
		tray:PivotTo(trayFrame(root) * CFrame.Angles(tilt, 0, tilt * 0.6))
		if footRing then
			-- Under the tray: the ring is the reach the server judges.
			local ground = if mode == "lobby" and practice then practice.floor else top
			local point = judgePoint(root)
			footRing.CFrame = CFrame.new(point.X, ground + 0.05, point.Z) * UP
		end
	end
	if mode == "run" and root then
		local point = judgePoint(root)
		table.insert(trail, { t = now, x = point.X, z = point.Z })
		while trail[1] and trail[1].t < now - TRAIL_KEEP do
			table.remove(trail, 1)
		end
	end
	local holdFor: number? = nil
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
				if item.ring then
					item.ring:Destroy()
					item.ring = nil
				end
				if item.shadow then
					item.shadow:Destroy()
					item.shadow = nil
				end
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
					if trailHit(d) then
						predict(item)
						continue
					end
					item.state = "landing"
				end
			end
		elseif item.state == "landing" then
			-- The late part of the window: the item drops on past the tray height, and a tray
			-- arriving now still catches it.
			if root then
				local point = judgePoint(root)
				if reaches(point.X, point.Z, d) then
					predict(item)
					continue
				end
			end
			local since = now - d.landAt
			local y = math.max(item.floorY + 0.8, item.catchY - since * LATE_DROP)
			model:PivotTo(CFrame.new(d.x, y, d.z) * CFrame.Angles(0, item.spin * clock, 0))
			if since > (if junk then JUNK_LATE else CATCH_LATE) then
				item.state = "floor"
				item.heldAt = clock
			end
		elseif item.state == "predicted" then
			holdFor = holdFor or holdWait()
			if now > d.landAt + (holdFor :: number) then
				-- No word from the server: it did not count.
				correct(item)
				item.state = "done"
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
	if (mode == "" or mode == "results") and not alive and not tray and stepConn then
		stepConn:Disconnect()
		stepConn = nil
	end
end

local function ensureStep()
	if not stepConn then
		stepConn = RunService.RenderStepped:Connect(step)
	end
end

-- The drops in the air go (the tray stays).
local function clearDrops()
	for _, item in items do
		clearItem(item)
	end
	table.clear(verdicts)
end

local function clearAll()
	clearDrops()
	table.clear(items)
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
	if item and item.state == "predicted" then
		-- The server agrees: the pop already played.
		item.state = "done"
	elseif item and (item.state == "landing" or item.state == "floor") then
		-- Caught after all (the server saw the tray there): the pop plays now.
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
	table.clear(trail)
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
		elseif event == "go" then
			-- The countdown is over (the run's drops already ride on "wave"); a lost
			-- "countdown" still brings the tray up here.
			if mode == "" or mode == "lobby" then
				enterRun()
			end
		elseif event == "win" or event == "lose" then
			if mode ~= "" then
				-- The run's drops go; the avatar keeps the tray for its win or loss reaction
				-- until the lobby.
				clearDrops()
				mode = "results"
				-- Junk food that cost the last heart flinches first, then the loss plays.
				local left = flinchAt + FLINCH_TIME - os.clock()
				if left > 0 then
					task.delay(left, function()
						if mode == "results" then
							move(event)
						end
					end)
				else
					move(event)
				end
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
			if mode ~= "" then
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
			clearDrops()
			mode = "results"
		end
	end)
end

return Shake
