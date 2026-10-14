--!strict
--[[
	Fx.Bowling: the 3D side of DUMBBELL BOWL (Modes.Bowling; docs/minigames.md). UI.BowlingHud draws
	the screen and drives the aim guide through Bowling.setAim.

	Nothing here is Roblox physics: the server plays each ball in pure code (BowlingRules.roll)
	and sends the path and every pin's fall; this module animates them on its own clones.

	  Pins       on "start" the arena's shared pins (World.BowlingLane, Folder "Pins") are
	             hidden on this client (LocalTransparencyModifier) and cloned into a local
	             folder, so other bowlers never see this game's pins. A fall tips the pin over
	             its base edge toward the sent direction with a bounce, a hop and a slide
	             (struck pins fly farther than knocked ones). On "ready" the knocked pins
	             sink away and, for a fresh rack, every pin drops back in from above.
	  Bowler     the player's own R15 avatar bowls (Fx.PlayerPose, poses Bowl* in Poses): from
	             the countdown it stands on the approach (moved there, walking and jumping
	             off), turned along the aim, holding the picked dumbbell in its right hand (a
	             local, scaled clone welded to the RightHand); on "roll" it runs up (push-away
	             step, backswing step, slide) and lets go `windup` seconds later, holds the
	             follow-through, then reacts to the ball: a leaping roar and flex for a strike,
	             a double fist pump for a spare, a facepalm and a slump when nothing fell, a
	             point at the deck otherwise. On the next "ready" it hops back to its spot
	             with a fresh dumbbell. The lobby, the results, a stop and a respawn hand the
	             joints and the controls back. No glow on the player: the avatar does it all.
	  Dumbbell   a clone of the rack's roller (attribute Roller). With a bowler it leaves the
	             hand at the release and grows to full size as it joins the path; without one
	             (an R6 avatar) it waits at the foul line, turned toward the aim and pulled
	             back with the power. On "roll" it runs the path keypoints spinning on its
	             plates (a wild ball hooks; it drops into a gutter when the path does) and
	             sinks into the pit.
	  Guide      seven sunny dots along the aim line (they swell and warm toward pink with the
	             power); hidden while a ball rolls.
	  Camera     Scriptable from the countdown to the results: behind the bowler while it aims
	             and runs up, then chasing the dumbbell from behind and above, easing to a
	             pin-deck view as it nears the pins (a small shake on the first hit, bigger on
	             a strike), round in front of the bowler for its reaction, and behind it again
	             on the next "ready". Back to Custom in the lobby, the results or a stop.
	  Bursts     a strike or spare bursts stars, confetti and sparkles over the pin deck.
	  Ball pick  the HUD's lobby picker (setBall) paints the dumbbells' plates in the chosen
	             colour and marks the matching rack dumbbell (BallChoice1..4 under the arena
	             Model): its neon "Glow" strip lit (the others dimmed), a highlight and a
	             bobbing arrow; a "roll" carries `ball` (1..4).
	  Lobby      the run starts in the lobby: the lane info may come with "start" or with any
	             later event that carries `lane`. setMode("countdown") from the HUD puts the
	             bowler on its spot; setMode("lobby" | "results") hands the avatar and the
	             camera back and racks a fresh set of pins.

	Main.client.luau calls init() once (it is in the Fx list); nothing else needs editing:
	  init()                       connects the Notify listener
	  start(payload) / stop(payload)
	  setAim(aim, power?, phase)   from BowlingHud each frame of the player's turn
	                               (phase "aim" | "power" | "off")
	  setMode(mode)                from BowlingHud when the run's phase changes
	  setBall(choice)              from BowlingHud's ball picker (1..4)
	  ballColor(choice)            the colour of rack dumbbell `choice` (for the HUD swatches)
	  arena()                      the arena Model (BowlingHud fills its BestBoard)
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Net = require(ReplicatedStorage.Shared.Net)
local Theme = require(ReplicatedStorage:WaitForChild("Theme")) :: any

local Client = script.Parent.Parent
local Sounds = require(Client.Sounds) :: any
local State = require(Client.State) :: any
local Sprites = require(script.Parent.Sprites)
local PlayerPose = require(script.Parent.PlayerPose)

local Bowling = {}

local W = Theme.World
local player = Players.LocalPlayer

local CAMERA_BIND = "BowlingCamera"
-- How a pin falls: seconds to tip over (Bounce out), the slide along its direction and the
-- hop off the deck (struck pins fly farther than knocked ones), the slide's seconds.
local FALL = { Time = 0.45, SlideTime = 0.8, Slide = { struck = 2.8, chain = 1.2 }, Hop = { struck = 1.1, chain = 0.3 } }
-- Clearing the deck: knocked pins sink this far over Sink seconds; a fresh rack drops in from
-- Drop studs over DropTime (Bounce), Stagger seconds apart.
local RESET = { Sink = 0.35, SinkBy = 3, Drop = 5, DropTime = 0.5, Stagger = 0.04 }
-- The aim guide: dots, first one this far down the lane, then this far apart.
local GUIDE = { Count = 7, From = 5, Gap = 4.4, Size = 0.55, PowerGrow = 0.5 }
-- The camera from the countdown to the results: the aim view (behind the bowler's spot,
-- studs back and up, looking AimLook studs down the lane), the chase (studs behind / above
-- the dumbbell, and how far ahead it looks), where the pin view sits (from the head pin: back
-- along the lane, up), its smoothing rate and, without a bowler, the seconds it stays on the
-- pins before going back to the aim view.
local CAMERA = {
	AimBack = 11,
	AimUp = 7.5,
	AimSide = -1,
	AimLook = 40,
	Back = 13,
	Up = 5.5,
	Ahead = 12,
	PinBack = 15,
	PinUp = 6.5,
	SwitchBefore = 18,
	Rate = 5,
	Hold = 1.2,
}
-- Burst sizes over the pin deck on a strike / spare.
local BURST = { strike = 22, spare = 14, Size = 1.6, Spread = 7, Life = 1.4 }
-- The ball picker: plate colours when the arena's BallChoiceN models can't be read, and the
-- arrow over the chosen rack dumbbell (studs above it, bob height and speed).
local BALL_COLORS = { W.Coral, W.Blue, W.Mint, W.Grape }
local MARKER = { Up = 3.2, Bob = 0.35, Rate = 4 }

-- The bowler (the player's avatar): its spot (studs behind the foul line, and left of the
-- lane centre times the avatar's scale so the right hand swings down the centre line), how
-- far the run-up carries the body forward (root offset, studs at scale 1), the held
-- dumbbell's scale and how far under the fist's centre it hangs, the seconds the released
-- dumbbell takes to join its path from the hand, and the default wind-up (the "roll"
-- payload's `windup`: seconds from the event to the release).
local BOWLER = { Back = 6, Side = 1.6, RunUp = 3.2, Carry = 0.5, Grip = 0.3, Join = 0.22, Windup = 0.9 }
-- The reaction camera: in front of the bowler (studs to its left, up and down the lane)
-- looking at its chest (studs over the root).
local REACT_CAM = { Side = -3, Up = 2.6, Ahead = 10, Look = 0.8, Rate = 3.5 }

type Pin = { model: Model, base: CFrame, down: boolean, shown: boolean, anim: number }

local running = false
local folder: Folder? = nil
local arena: Model? = nil
local info: any = nil -- the "start" payload (lane, pins, ball, pin, aimSpread)
local pins: { Pin } = {}
local dumbbell: Model? = nil
local guide: { BasePart } = {}
local stepConn: RBXScriptConnection? = nil
-- Per-frame jobs: each returns true when done.
local jobs: { (now: number) -> boolean } = {}
local token = 0 -- bumped by start / stop and each roll, so stale jobs end
local cameraOn = false
local shakeAt, shakeSize = -math.huge, 0
local camFocus: Vector3? = nil
-- "aim" behind the bowler, "ball" chasing the dumbbell then the pins, "react" facing the
-- bowler.
local camMode = "aim"
-- Where the rolling dumbbell is (the chase camera follows it).
local ballNow = Vector3.zero
-- The bowler: the avatar's poser (nil for an R6 avatar: the dumbbell waits at the foul line
-- instead), the dumbbell in its hand, whether its controls are off, the last aim (it faces
-- along it) and whether its body sits forward of the spot after a run-up.
local poser: PlayerPose.Poser? = nil
local poserFor: Model? = nil
local held: Model? = nil
local controlsOff = false
local lastAim = 0
local stepped = false
local ballChoice = 1
local marker: { glow: Highlight, arrow: BillboardGui }? = nil
-- Defined under Lifecycle (onReady calls it first).
local adopt: (p: any) -> ()

local function num(value: any, default: number): number
	return if type(value) == "number" and value == value then value else default
end

local function reducedMotion(): boolean
	local data = State.data
	return type(data) == "table" and type(data.settings) == "table" and data.settings.reducedMotion == true
end

-- World point of lane space (x across, d down the lane) at `y` over the floor top.
local function at(x: number, d: number, y: number): Vector3
	local lane = info.lane
	return Vector3.new(lane.x + x, lane.top + y, lane.z - d)
end

local LANE_TOP = 0.2

local function findArena(): Model?
	local map = Workspace:FindFirstChild("Map")
	if not map then
		return nil
	end
	for _, child in map:GetChildren() do
		if child:IsA("Model") and child:GetAttribute("Mode") == "bowling" then
			return child
		end
	end
	return nil
end

local function setLocalHidden(root: Instance, hidden: boolean)
	for _, part in root:GetDescendants() do
		if part:IsA("BasePart") then
			part.LocalTransparencyModifier = if hidden then 1 else 0
		end
	end
end

local function addJob(fn: (now: number) -> boolean)
	table.insert(jobs, fn)
end

local function ease(alpha: number, style: Enum.EasingStyle): number
	return TweenService:GetValue(math.clamp(alpha, 0, 1), style, Enum.EasingDirection.Out)
end

-- A throwaway invisible anchor for world sprites.
local function sprite(name: string, position: Vector3, opts: { [string]: any })
	if not Sprites.room() then
		return
	end
	local part = Instance.new("Part")
	part.Name = "BowlingFxAnchor"
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Transparency = 1
	part.Size = Vector3.one * 0.2
	part.CFrame = CFrame.new(position)
	part.Parent = folder or Workspace
	task.delay(2.2, function()
		part:Destroy()
	end)
	local o = table.clone(opts) :: any
	o.position = position
	Sprites.billboard(part, name, o)
end

-- Pins --------------------------------------------------------------------------------------

local function buildPins()
	local source = arena and arena:FindFirstChild("Pins")
	if not source or not folder then
		return
	end
	for _, child in source:GetChildren() do
		local index = child:GetAttribute("Index")
		if child:IsA("Model") and type(index) == "number" then
			local copy = child:Clone()
			setLocalHidden(copy, false)
			copy.Parent = folder
			pins[index] = { model = copy, base = child:GetPivot(), down = false, shown = true, anim = 0 }
		end
	end
	setLocalHidden(source, true)
end

local lastCrashAt = -math.huge

-- Tips pin `i` over toward lane direction (dx, dd), starting `delay` seconds from now.
local function fallPin(i: number, delay: number, dx: number, dd: number, struck: boolean)
	local pin = pins[i]
	if not pin or not info then
		return
	end
	pin.down = true
	pin.anim += 1
	local mine = pin.anim
	local dir = Vector3.new(dx, 0, -dd)
	dir = if dir.Magnitude > 1e-3 then dir.Unit else Vector3.new(0, 0, -1)
	local axis = Vector3.yAxis:Cross(dir).Unit
	local radius = num(info.pin and info.pin.radius, 0.6)
	local edge = CFrame.new(pin.base.Position + dir * radius)
	local slide = if struck then FALL.Slide.struck else FALL.Slide.chain
	local hop = if struck then FALL.Hop.struck else FALL.Hop.chain
	-- Each pin lands at a slightly different yaw so the deck looks scattered.
	local twist = (math.random() - 0.5) * (if struck then 1.6 else 0.6)
	local startAt = os.clock() + delay
	local sounded = false
	addJob(function(now: number): boolean
		if pin.anim ~= mine then
			return true
		end
		local t = now - startAt
		if t < 0 then
			return false
		end
		if not sounded then
			sounded = true
			-- One crash for the dumbbell's hit, a light knock for each pin after it (a
			-- stinger per pin drowned a strike in noise).
			if struck and os.clock() - lastCrashAt > 0.25 then
				lastCrashAt = os.clock()
				Sounds.play("MergeBoom", 0.08)
			else
				Sounds.play("Tick", 0.15, 0.8)
			end
		end
		local tip = ease(t / FALL.Time, Enum.EasingStyle.Bounce) * math.pi / 2
		local s = ease(t / FALL.SlideTime, Enum.EasingStyle.Quad) * slide
		local h = math.clamp(t / (FALL.Time * 0.8), 0, 1)
		local lift = hop * 4 * h * (1 - h)
		local spin = CFrame.fromAxisAngle(Vector3.yAxis, twist * math.clamp(t / FALL.SlideTime, 0, 1))
		local turned = edge * spin * CFrame.fromAxisAngle(axis, tip) * edge:Inverse() * pin.base
		pin.model:PivotTo(CFrame.new(dir * s + Vector3.new(0, lift, 0)) * turned)
		return t >= math.max(FALL.Time, FALL.SlideTime)
	end)
end

-- Clears knocked pins (sink and hide) and, for a fresh rack, drops every pin back in.
local function resetPins(standing: { any }, rack: boolean)
	local order = 0
	for i, pin in pins do
		local up = rack or standing[i] == true
		if not up and pin.shown then
			pin.anim += 1
			local mine = pin.anim
			local from = pin.model:GetPivot()
			local startAt = os.clock()
			addJob(function(now: number): boolean
				if pin.anim ~= mine then
					return true
				end
				local a = math.clamp((now - startAt) / RESET.Sink, 0, 1)
				pin.model:PivotTo(from - Vector3.new(0, RESET.SinkBy * a, 0))
				if a >= 1 then
					pin.shown = false
					pin.model.Parent = nil
					return true
				end
				return false
			end)
		elseif up and (pin.down or not pin.shown) then
			pin.anim += 1
			local mine = pin.anim
			pin.down, pin.shown = false, true
			pin.model.Parent = folder
			local startAt = os.clock() + RESET.Sink + order * RESET.Stagger
			order += 1
			pin.model:PivotTo(pin.base + Vector3.new(0, RESET.Drop, 0))
			addJob(function(now: number): boolean
				if pin.anim ~= mine then
					return true
				end
				local a = math.clamp((now - startAt) / RESET.DropTime, 0, 1)
				pin.model:PivotTo(pin.base + Vector3.new(0, RESET.Drop * (1 - ease(a, Enum.EasingStyle.Bounce)), 0))
				return a >= 1
			end)
		end
	end
end

-- Dumbbell and guide ----------------------------------------------------------------------

local function ballRadius(): number
	return num(info and info.ball and info.ball.radius, 1.5)
end

-- Where the dumbbell waits: on the lane just past the foul line, turned toward `aim`.
-- The path's sideways studs per stud down the lane for `aim` (as BowlingRules.roll).
local function slopeOf(aim: number): number
	local headD = num(info.pins and info.pins[1] and info.pins[1].d, 72)
	return aim * num(info.aimSpread, 7.5) / headD
end

-- Where the dumbbell waits: on the lane just past the foul line, turned toward `aim` and
-- pulled back `pull` studs.
local function restCFrame(aim: number, pull: number): CFrame
	return CFrame.new(at(0, 1 - pull, LANE_TOP + ballRadius())) * CFrame.Angles(0, -math.atan(slopeOf(aim)), 0)
end

-- The local avatar's HumanoidRootPart, humanoid and scale.
local function rootPart(): BasePart?
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	return if root and root:IsA("BasePart") then root else nil
end

local function charScale(): number
	local character = player.Character
	return if character then character:GetScale() else 1
end

-- Where the bowler's root stands: BOWLER.Back behind the foul line, its right hand over the
-- centre line, on the approach floor, turned toward `aim`.
local function spotCFrame(aim: number): CFrame?
	local root = rootPart()
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not root or not humanoid or not info then
		return nil
	end
	local y = info.lane.top + humanoid.HipHeight + root.Size.Y / 2
	local pos = Vector3.new(info.lane.x - BOWLER.Side * charScale(), y, info.lane.z + BOWLER.Back)
	return CFrame.new(pos) * CFrame.Angles(0, -math.atan(slopeOf(aim)), 0)
end

local function buildBall()
	local source = arena and arena:FindFirstChild("BowlDumbbell", true)
	if not source or not source:IsA("Model") or not folder then
		return
	end
	local copy = source:Clone()
	for _, part in copy:GetDescendants() do
		if part:IsA("BasePart") then
			part.CanCollide = false
		end
	end
	copy.Name = "RollingDumbbell"
	copy:PivotTo(restCFrame(0, 0))
	copy.Parent = folder
	dumbbell = copy
end

-- The rack dumbbell for pick `choice` (BallChoice1..4 under the arena Model), if built.
local function choiceModel(choice: number): Instance?
	local found = arena and arena:FindFirstChild("BallChoice" .. choice, true)
	return if found and (found:IsA("Model") or found:IsA("BasePart")) then found else nil
end

function Bowling.ballColor(choice: number): Color3
	local i = math.clamp(math.floor(num(choice, 1)), 1, #BALL_COLORS)
	local model = choiceModel(i)
	if model then
		local color = model:GetAttribute("Color")
		if typeof(color) == "Color3" then
			return color
		end
		local plate = if model:IsA("BasePart") then model else model:FindFirstChild("Plate", true)
		if plate and plate:IsA("BasePart") then
			return plate.Color
		end
	end
	return BALL_COLORS[i]
end

-- A part to hang the arrow on: the model's biggest part.
local function anchorOf(model: Instance): BasePart?
	if model:IsA("BasePart") then
		return model
	end
	local best: BasePart? = nil
	for _, part in model:GetDescendants() do
		if part:IsA("BasePart") and (not best or part.Size.Magnitude > best.Size.Magnitude) then
			best = part
		end
	end
	return best
end

-- Lights the picked rack dumbbell's neon "Glow" strip and dims the others (`none`: all lit
-- again, as the arena builds them).
local function lightGlows(none: boolean?)
	for i = 1, #BALL_COLORS do
		local model = choiceModel(i)
		local glow = model and model:FindFirstChild("Glow")
		if glow and glow:IsA("BasePart") then
			glow.Transparency = if none or i == ballChoice then 0 else 0.75
		end
	end
end

local function paintPlates(model: Model?, color: Color3)
	if not model then
		return
	end
	for _, part in model:GetDescendants() do
		if part:IsA("BasePart") and part.Name == "Plate" then
			part.Color = color
		end
	end
end

local function paintBall()
	local color = Bowling.ballColor(ballChoice)
	paintPlates(dumbbell, color)
	paintPlates(held, color)
	lightGlows()
	if marker then
		marker.glow:Destroy()
		marker.arrow:Destroy()
		marker = nil
	end
	local model = choiceModel(ballChoice)
	local anchor = model and anchorOf(model)
	if not model or not anchor or not folder then
		return
	end
	local glow = Instance.new("Highlight")
	glow.Name = "BallPick"
	glow.Adornee = model
	glow.FillColor = W.Sunny
	glow.FillTransparency = 0.7
	glow.OutlineColor = W.Sunny
	glow.OutlineTransparency = 0
	glow.DepthMode = Enum.HighlightDepthMode.Occluded
	glow.Parent = folder
	local arrow = Instance.new("BillboardGui")
	arrow.Name = "BallPickArrow"
	arrow.Adornee = anchor
	arrow.Size = UDim2.fromOffset(44, 44)
	arrow.StudsOffsetWorldSpace = Vector3.new(0, MARKER.Up, 0)
	arrow.LightInfluence = 0
	arrow.MaxDistance = 120
	arrow.Parent = folder
	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromScale(1, 1)
	label.Font = Enum.Font.FredokaOne
	label.Text = "▼"
	label.TextScaled = true
	label.TextColor3 = W.Sunny
	label.TextStrokeColor3 = W.Ink
	label.TextStrokeTransparency = 0
	label.Parent = arrow
	marker = { glow = glow, arrow = arrow }
end

-- The lobby's ball picker (and each "roll"): paints the dumbbell and marks the rack one.
function Bowling.setBall(choice: number)
	local i = math.clamp(math.floor(num(choice, 1)), 1, #BALL_COLORS)
	if i == ballChoice and (marker or not running) then
		return
	end
	ballChoice = i
	if running then
		paintBall()
	end
end

local function buildGuide()
	for i = 1, GUIDE.Count do
		local dot = Instance.new("Part")
		dot.Name = "AimDot"
		dot.Shape = Enum.PartType.Cylinder
		dot.Anchored = true
		dot.CanCollide = false
		dot.CanQuery = false
		dot.CanTouch = false
		dot.Material = Enum.Material.Neon
		dot.Color = W.Sunny
		dot.Size = Vector3.new(0.05, GUIDE.Size, GUIDE.Size)
		-- Fade along the line so it reads as pointing away.
		dot.Transparency = 0.1 + (i - 1) / GUIDE.Count * 0.5
		dot.Parent = folder
		guide[i] = dot
	end
end

local function showGuide(on: boolean)
	for _, dot in guide do
		dot.Parent = if on then folder else nil
	end
end

local lastPhase = "off"
-- While returnBall drops the dumbbell in, setAim leaves its pivot alone (one writer a frame).
local returningUntil = 0
function Bowling.setAim(aim: number, power: number?, phase: string)
	if not running or not info then
		return
	end
	if phase ~= lastPhase then
		showGuide(phase ~= "off")
		lastPhase = phase
	end
	if phase == "off" then
		return
	end
	local spread = num(info.aimSpread, 7.5)
	local headD = num(info.pins and info.pins[1] and info.pins[1].d, 72)
	local p = if phase == "power" then math.clamp(power or 0, 0, 1) else 0
	local size = GUIDE.Size * (1 + p * GUIDE.PowerGrow)
	local color = W.Sunny:Lerp(W.HotPink, p)
	for i, dot in guide do
		local d = GUIDE.From + (i - 1) * GUIDE.Gap
		local x = aim * spread * d / headD
		dot.Size = Vector3.new(0.05, size, size)
		dot.Color = color
		dot.CFrame = CFrame.new(at(x, d, LANE_TOP + 0.03)) * CFrame.Angles(0, 0, math.pi / 2)
	end
	lastAim = aim
	if poser then
		-- The bowler turns to face along the aim line (its dumbbell stays in the hand).
		local spot = spotCFrame(aim)
		local root = rootPart()
		if spot and root and not stepped then
			root.CFrame = spot
		end
		return
	end
	local ball = dumbbell
	if ball and os.clock() >= returningUntil then
		local wobble = if phase == "power" and not reducedMotion() then math.sin(os.clock() * 30) * 0.04 * p else 0
		ball:PivotTo(restCFrame(aim, p * 0.8) * CFrame.new(wobble, 0, 0))
	end
end

-- Pops the dumbbell back at the foul line (it drops in from above).
local function returnBall()
	local ball = dumbbell
	if not ball then
		return
	end
	ball.Parent = folder
	local startAt = os.clock()
	returningUntil = startAt + 0.5
	local mine = token
	addJob(function(now: number): boolean
		if token ~= mine then
			returningUntil = 0
			return true
		end
		local a = math.clamp((now - startAt) / 0.5, 0, 1)
		ball:PivotTo(restCFrame(0, 0) + Vector3.new(0, 3 * (1 - ease(a, Enum.EasingStyle.Bounce)), 0))
		return a >= 1
	end)
end

-- Bowler ------------------------------------------------------------------------------------

local QUAD, BACK, SINE = Enum.EasingStyle.Quad, Enum.EasingStyle.Back, Enum.EasingStyle.Sine
local IN, IN_OUT = Enum.EasingDirection.In, Enum.EasingDirection.InOut

-- A root offset (PlayerPose Key.root): `forward` studs down the lane (at scale 1), leaning
-- `lean` degrees (negative: over the front foot).
local function stepAt(forward: number, lean: number?): CFrame
	return CFrame.new(0, 0, -forward) * CFrame.Angles(math.rad(lean or 0), 0, 0)
end

local controlsModule: any = nil
local function playerControls(): any
	if controlsModule then
		return controlsModule
	end
	local ok, result = pcall(function()
		local scripts = player:FindFirstChild("PlayerScripts")
		local module = scripts and scripts:FindFirstChild("PlayerModule")
		if module and module:IsA("ModuleScript") then
			return (require(module) :: any):GetControls()
		end
		return nil
	end)
	controlsModule = if ok then result else nil
	return controlsModule
end

-- Walking and jumping off (the bowler stays on its spot) or back on.
local function setControls(on: boolean)
	if controlsOff ~= on then
		return
	end
	controlsOff = not on
	local controls = playerControls()
	if controls then
		pcall(function()
			if on then
				controls:Enable()
			else
				controls:Disable()
			end
		end)
	end
end

local function dropHeld()
	if held then
		held:Destroy()
		held = nil
	end
end

-- A fresh dumbbell (the picked colour, BOWLER.Carry of the rolling one) in the right fist.
local function gripHeld()
	dropHeld()
	local character = player.Character
	local hand = character and character:FindFirstChild("RightHand")
	local source = arena and arena:FindFirstChild("BowlDumbbell", true)
	if not hand or not hand:IsA("BasePart") or not source or not source:IsA("Model") or not folder then
		return
	end
	local copy = source:Clone()
	copy.Name = "HeldDumbbell"
	local bar = copy:FindFirstChild("Bar")
	if not bar or not bar:IsA("BasePart") then
		copy:Destroy()
		return
	end
	local scale = charScale()
	copy:ScaleTo(BOWLER.Carry * scale)
	-- The bar runs across the fist (palm forward), as it will roll across the lane.
	local grip = CFrame.new(0, -BOWLER.Grip * scale, 0)
	copy:PivotTo(hand.CFrame * grip)
	for _, part in copy:GetDescendants() do
		if part:IsA("BasePart") then
			part.Anchored = false
			part.CanCollide = false
			part.CanQuery = false
			part.CanTouch = false
			part.Massless = true
			if part ~= bar then
				local link = Instance.new("WeldConstraint")
				link.Part0 = bar
				link.Part1 = part
				link.Parent = part
			end
		end
	end
	local weld = Instance.new("Weld")
	weld.Name = "Grip"
	weld.Part0 = hand
	weld.Part1 = bar
	weld.C0 = grip
	weld.Parent = bar
	paintPlates(copy, Bowling.ballColor(ballChoice))
	copy.Parent = folder
	held = copy
end

-- The avatar's poser (made once per character; nil for an R6 avatar).
local function ensurePoser(): PlayerPose.Poser?
	local character = player.Character
	if poser and poserFor == character and character and character.Parent then
		return poser
	end
	if poser then
		poser:stop()
	end
	poser = PlayerPose.attach(character)
	poserFor = if poser then character else nil
	return poser
end

-- Hands the avatar back: the joints to its animations, the dumbbell out of its hand, the
-- controls back on.
local function releaseBowler()
	if poser then
		poser:stop()
		poser = nil
		poserFor = nil
	end
	dropHeld()
	stepped = false
	setControls(true)
end

-- The bowler on its spot in the ready stance with a dumbbell in hand (`hop`: it hops back
-- from the end of its last run-up). An R6 avatar keeps its controls and the dumbbell waits
-- at the foul line instead.
local function standBowler(hop: boolean)
	if not info then
		return
	end
	local pose = ensurePoser()
	local spot = spotCFrame(lastAim)
	local root = rootPart()
	if not pose or not spot or not root then
		return
	end
	setControls(false)
	root.CFrame = spot
	root.AssemblyLinearVelocity = Vector3.zero
	root.AssemblyAngularVelocity = Vector3.zero
	stepped = false
	if not held then
		gripHeld()
	end
	local ball = dumbbell
	if ball then
		ball.Parent = nil
	end
	pose:play({
		{
			pose = "BowlStance",
			blend = if hop then 0.32 else 0.4,
			ease = SINE,
			dir = IN_OUT,
			hop = if hop then 0.35 else nil,
			hopTime = 0.32,
		},
	})
end

-- The approach: a push-away step, the backswing step and the slide, the release landing
-- `windup` seconds in (the dumbbell leaves the hand then), then the follow-through held.
local function bowlMove(windup: number): { PlayerPose.Key }
	local k = windup / BOWLER.Windup
	local run = BOWLER.RunUp
	return {
		{ pose = "BowlPushaway", blend = 0.26 * k, ease = SINE, dir = IN_OUT, root = stepAt(run * 0.25, -4) },
		{ pose = "BowlBackswing", blend = 0.3 * k, ease = QUAD, root = stepAt(run * 0.6, -8), hold = 0.04 * k },
		-- The swing accelerates down into the release (Quad In).
		{ pose = "BowlRelease", blend = 0.3 * k, ease = QUAD, dir = IN, root = stepAt(run * 0.94, -12) },
		{ pose = "BowlFollow", blend = 0.32, ease = BACK, root = stepAt(run, -8) },
	}
end

-- The bowler's reaction to the ball: a leaping roar and flex for a strike, a double fist pump
-- for a spare, a facepalm and a slump for nothing down, a point at the deck otherwise.
local function reactMove(mark: string?, knocked: number): { PlayerPose.Key }
	local run = BOWLER.RunUp
	if mark == "strike" then
		return {
			{ pose = "BowlStance", blend = 0.14, ease = QUAD, root = stepAt(run, 4), hold = 0.04 },
			{ pose = "Victory", blend = 0.18, ease = BACK, root = stepAt(run, 6), hop = 1.2, hopTime = 0.45, hold = 0.3 },
			{ pose = "BowlRoar", blend = 0.12, ease = QUAD, dir = IN, root = stepAt(run, -2), hold = 0.9 },
			{ pose = "DoubleBiceps", blend = 0.3, ease = BACK, root = stepAt(run, 2) },
		}
	elseif mark == "spare" then
		return {
			{ pose = "BowlPumpUp", blend = 0.16, ease = BACK, root = stepAt(run, 2), hop = 0.4, hopTime = 0.3, hold = 0.08 },
			{ pose = "BowlPumpDown", blend = 0.12, ease = QUAD, dir = IN, root = stepAt(run, -4), hold = 0.12 },
			{ pose = "BowlPumpUp", blend = 0.14, ease = BACK, root = stepAt(run, 2), hold = 0.06 },
			{ pose = "BowlPumpDown", blend = 0.12, ease = QUAD, dir = IN, root = stepAt(run, -4), hold = 0.5 },
			{ pose = "HandsOnHips", blend = 0.4, ease = SINE, dir = IN_OUT, root = stepAt(run) },
		}
	elseif knocked <= 0 then
		return {
			{ pose = "Shock", blend = 0.14, ease = BACK, root = stepAt(run, 6), hold = 0.25 },
			{ pose = "BowlFacepalm", blend = 0.32, ease = SINE, dir = IN_OUT, root = stepAt(run, -2), hold = 1.0 },
			{ pose = "BowlSlump", blend = 0.5, ease = SINE, dir = IN_OUT, root = stepAt(run, -6) },
		}
	end
	return {
		{ pose = "BowlPoint", blend = 0.24, ease = BACK, root = stepAt(run, -2), hold = 0.9 },
		{ pose = "HandsOnHips", blend = 0.4, ease = SINE, dir = IN_OUT, root = stepAt(run) },
	}
end

-- Camera ------------------------------------------------------------------------------------

local function releaseCamera()
	if not cameraOn then
		return
	end
	cameraOn = false
	camFocus = nil
	RunService:UnbindFromRenderStep(CAMERA_BIND)
	local camera = Workspace.CurrentCamera
	if camera then
		local humanoid = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
		if humanoid then
			camera.CameraSubject = humanoid
		end
		camera.CameraType = Enum.CameraType.Custom
	end
end

local function shake(size: number)
	if reducedMotion() then
		return
	end
	shakeAt, shakeSize = os.clock(), size
end

-- Where the camera wants to be and look this frame, and how fast it gets there.
local function cameraGoal(): (Vector3, Vector3, number)
	local headD = num(info.pins and info.pins[1] and info.pins[1].d, 72)
	if camMode == "react" then
		local root = rootPart()
		if root then
			local body = (root.CFrame * CFrame.new(0, 0, -BOWLER.RunUp * charScale())).Position
			local eye = body + Vector3.new(REACT_CAM.Side, REACT_CAM.Up, -REACT_CAM.Ahead)
			return eye, body + Vector3.new(0, REACT_CAM.Look, 0), REACT_CAM.Rate
		end
	elseif camMode == "ball" then
		local pos = ballNow
		local d = info.lane.z - pos.Z
		if d < headD - CAMERA.SwitchBefore then
			local eye = Vector3.new(info.lane.x + (pos.X - info.lane.x) * 0.5, pos.Y + CAMERA.Up, pos.Z + CAMERA.Back)
			return eye, pos + Vector3.new(0, 0.5, -CAMERA.Ahead), CAMERA.Rate
		end
		return at(0, headD - CAMERA.PinBack, CAMERA.PinUp), at(0, headD + 4, 1), CAMERA.Rate
	end
	return at(CAMERA.AimSide, -(BOWLER.Back + CAMERA.AimBack), CAMERA.AimUp), at(0, CAMERA.AimLook, 0), CAMERA.Rate
end

-- The camera is scripted from the countdown until the lobby, the results or a stop.
local function takeCamera()
	local camera = Workspace.CurrentCamera
	if cameraOn or not camera or not info then
		return
	end
	cameraOn = true
	camera.CameraType = Enum.CameraType.Scriptable
	local current: CFrame? = camera.CFrame
	RunService:BindToRenderStep(CAMERA_BIND, Enum.RenderPriority.Camera.Value, function(dt: number)
		local cam = Workspace.CurrentCamera
		if not cam or not info then
			return
		end
		if cam.CameraType ~= Enum.CameraType.Scriptable then
			cam.CameraType = Enum.CameraType.Scriptable
		end
		local eye, focus, rate = cameraGoal()
		camFocus = focus
		local goal = CFrame.lookAt(eye, focus)
		current = if current then current:Lerp(goal, 1 - math.exp(-dt * rate)) else goal
		local out = current :: CFrame
		local since = os.clock() - shakeAt
		if since < 0.4 then
			local k = shakeSize * (1 - since / 0.4)
			out = out * CFrame.new((math.random() - 0.5) * k, (math.random() - 0.5) * k, 0)
		end
		cam.CFrame = out
	end)
end

-- The roll ---------------------------------------------------------------------------------

local function burst(kind: string)
	if not info then
		return
	end
	local headD = num(info.pins and info.pins[1] and info.pins[1].d, 72)
	local centre = at(0, headD + 3, 3)
	local n = if kind == "strike" then BURST.strike else BURST.spare
	for i = 1, n do
		local name = if i % 3 == 0 then "StarPop" elseif i % 3 == 1 then "Confetti" else "Sparkle"
		local angle = (i / n) * math.pi * 2 + math.random() * 0.4
		local out = Vector3.new(math.cos(angle), 0.6 + math.random() * 0.8, math.sin(angle) * 0.5)
		sprite(name, centre + out * 0.8, {
			size = BURST.Size * (0.8 + math.random() * 0.5),
			life = BURST.Life,
			delay = i * 0.015,
			rise = out * BURST.Spread,
			spin = 140,
			color = if name == "Confetti" then nil else (if i % 2 == 0 then W.Sunny else W.HotPink),
		})
	end
end

-- Lane-space position of the dumbbell `t` seconds after the release.
local function pathAt(path: { any }, t: number): (number, number)
	local x, d = path[#path].x, path[#path].d
	for i = 2, #path do
		local a, b = path[i - 1], path[i]
		if t <= b.t then
			local f = if b.t > a.t then math.clamp((t - a.t) / (b.t - a.t), 0, 1) else 1
			return a.x + (b.x - a.x) * f, a.d + (b.d - a.d) * f
		end
	end
	return x, d
end

local function onRoll(p: any)
	if not info or type(p.path) ~= "table" or #p.path < 2 then
		return
	end
	token += 1
	local mine = token
	showGuide(false)
	lastPhase = "off"
	local path: { any } = p.path
	-- The path's times (and the pins') count from the release, `windup` seconds from now
	-- while the avatar runs up and swings.
	local windup = math.max(num(p.windup, num(info.windup, BOWLER.Windup)), 0)
	local releaseAt = os.clock() + windup
	local radius = ballRadius()
	local halfW = num(info.lane.width, 14) / 2
	local endT = num(path[#path].t, 2)
	local knocked = num(p.knocked, 0)
	local mark = p.mark
	ballNow = at(0, 1, LANE_TOP + radius)
	local travelled = 0
	local lastPos = ballNow
	local ball = dumbbell
	local pose = poser
	local bowler = pose ~= nil and held ~= nil and windup > 0
	-- `ball` is the picked colour (1..4); `ballChoice` is accepted too.
	local pick = p.ballChoice or p.ball
	if type(pick) == "number" and pick >= 1 and pick <= #BALL_COLORS and pick ~= ballChoice then
		ballChoice = math.floor(pick)
		paintBall()
	end
	camMode = "aim"
	takeCamera()
	if bowler and pose then
		stepped = true
		pose:play(bowlMove(windup))
		Sounds.play("Step", 0.1)
		task.delay(windup * 0.3, function()
			if token == mine then
				Sounds.play("Step", 0.1, 1.1)
			end
		end)
	end
	-- The dumbbell: out of the hand at the release (growing to full size as it joins its
	-- path), along the keypoints spinning on its plates, then into the pit.
	local joinFrom: CFrame? = nil
	local released = false
	local full = true
	addJob(function(now: number): boolean
		if token ~= mine then
			return true
		end
		local t = now - releaseAt
		if t < 0 then
			return false
		end
		if not released then
			released = true
			camMode = "ball"
			if bowler and held then
				joinFrom = held:GetPivot()
				dropHeld()
				Sounds.play("Click", 0.1, 0.7)
			end
			if ball then
				ball.Parent = folder
			end
		end
		local x, d = pathAt(path, t)
		local inGutter = math.abs(x) > halfW
		local y = LANE_TOP + radius - (if inGutter then 0.5 else 0)
		local sink = math.clamp((t - endT) / 0.35, 0, 1) * 2.5
		local pos = at(x, d, y - sink)
		travelled += (pos - lastPos).Magnitude
		lastPos = pos
		ballNow = pos
		if ball then
			-- Turned along its travel (a hook bends it), spinning on its plates.
			local ax, ad = pathAt(path, t + 0.05)
			local dx, dd = ax - x, ad - d
			local yaw = if inGutter or dd <= 1e-4 then 0 else -math.atan(dx / dd)
			local cf = CFrame.new(pos) * CFrame.Angles(0, yaw, 0) * CFrame.Angles(-travelled / radius, 0, 0)
			local from = joinFrom
			if from and t < BOWLER.Join then
				local a = ease(t / BOWLER.Join, Enum.EasingStyle.Quad)
				local small = BOWLER.Carry * charScale()
				ball:ScaleTo(small + (1 - small) * a)
				full = false
				cf = from:Lerp(cf, a)
			elseif not full then
				ball:ScaleTo(1)
				full = true
			end
			ball:PivotTo(cf)
		end
		if sink >= 2.5 then
			if ball then
				ball.Parent = nil
			end
			return true
		end
		return false
	end)
	-- The pins, each at its own time.
	local firstT = math.huge
	local lastT = 0
	if type(p.falls) == "table" then
		for _, f in p.falls do
			local i, t = num(f.pin, 0), num(f.t, 0)
			fallPin(i, windup + t, num(f.dx, 0), num(f.dd, 1), f.struck == true)
			firstT = math.min(firstT, t)
			lastT = math.max(lastT, t)
		end
	end
	if firstT < math.huge then
		task.delay(windup + firstT, function()
			if token == mine then
				shake(if mark == "strike" then 0.9 else 0.4)
			end
		end)
	end
	if mark == "strike" or mark == "spare" then
		task.delay(windup + lastT + 0.35, function()
			if token == mine then
				burst(mark)
				Sounds.play(if mark == "strike" then "Celebrate" else "Reward")
				shake(if mark == "strike" then 0.7 else 0.3)
			end
		end)
	end
	-- The reaction once the result reads: after the pins settle (a strike's burst first), or
	-- as a gutter ball drops off the lane.
	local reactT
	if knocked > 0 then
		reactT = lastT + (if mark == "strike" then 1.1 elseif mark == "spare" then 0.9 else 0.6)
	elseif p.gutter == true and #path >= 4 then
		reactT = num(path[#path - 2].t, endT) + 0.35
	else
		reactT = endT
	end
	task.delay(windup + reactT, function()
		if token ~= mine then
			return
		end
		local now = poser
		if bowler and now then
			now:play(reactMove(mark, knocked))
			camMode = "react"
		end
	end)
	if not bowler then
		-- No avatar to watch: back to the aim view once the pins settle.
		local hold = math.max(endT, lastT + FALL.SlideTime) + CAMERA.Hold
		task.delay(windup + math.min(hold, num(p.wait, windup + hold + 1) - windup - 0.2), function()
			if token == mine then
				camMode = "aim"
			end
		end)
	end
end

local function onReady(p: any)
	adopt(p)
	if not info then
		return
	end
	token += 1
	camMode = "aim"
	takeCamera()
	local standing = if type(p.standing) == "table" then p.standing else {}
	resetPins(standing, p.rack == true)
	standBowler(stepped)
	if not poser then
		returnBall()
	end
end

-- Lifecycle ---------------------------------------------------------------------------------

local function step()
	local now = os.clock()
	if marker and not reducedMotion() then
		marker.arrow.StudsOffsetWorldSpace = Vector3.new(0, MARKER.Up + math.sin(now * MARKER.Rate) * MARKER.Bob, 0)
	end
	local i = 1
	while i <= #jobs do
		local ok, done = pcall(jobs[i], now)
		if not ok or done then
			table.remove(jobs, i)
		else
			i += 1
		end
	end
end

local function clear()
	token += 1
	releaseCamera()
	releaseBowler()
	lightGlows(true)
	table.clear(jobs)
	if stepConn then
		stepConn:Disconnect()
		stepConn = nil
	end
	local source = arena and arena:FindFirstChild("Pins")
	if source then
		setLocalHidden(source, false)
	end
	if folder then
		folder:Destroy()
		folder = nil
	end
	for _, pin in pins do
		pin.model:Destroy()
	end
	table.clear(pins)
	table.clear(guide)
	dumbbell = nil
	marker = nil
	lastPhase = "off"
	lastAim = 0
end

-- Builds the pins, the dumbbell and the guide from the first payload that carries the lane
-- (the lobby's "start" may not; then "countdown" or "ready" does).
adopt = function(p: any)
	if info or not running or type(p) ~= "table" or type(p.lane) ~= "table" then
		return
	end
	info = p
	arena = arena or findArena()
	buildPins()
	buildBall()
	buildGuide()
	showGuide(false)
	paintBall()
end

function Bowling.start(payload: { [string]: any })
	clear()
	info = nil
	running = true
	arena = findArena()
	local f = Instance.new("Folder")
	f.Name = "BowlingFx"
	f.Parent = Workspace
	folder = f
	stepConn = RunService.RenderStepped:Connect(step)
	adopt(payload)
	if not info then
		-- No lane yet: still mark the picked rack dumbbell in the lobby.
		paintBall()
	end
end

-- The run's phase from BowlingHud. Countdown: the avatar takes its spot on the approach with
-- the dumbbell in hand and the camera goes behind it. Lobby and results: the avatar, its
-- controls and the camera are the player's again, the guide is off and a fresh rack stands.
function Bowling.setMode(mode: string)
	if not running or mode == "play" then
		return
	end
	token += 1
	showGuide(false)
	lastPhase = "off"
	if mode == "countdown" and info then
		resetPins({}, true)
		lastAim = 0
		camMode = "aim"
		takeCamera()
		standBowler(stepped)
		if not poser then
			returnBall()
		end
		return
	end
	releaseCamera()
	releaseBowler()
	if info and mode == "lobby" then
		resetPins({}, true)
		returnBall()
	end
end

function Bowling.arena(): Model?
	if arena and arena.Parent then
		return arena
	end
	arena = findArena()
	return arena
end

function Bowling.stop(_payload: { [string]: any }?)
	if not running then
		return
	end
	running = false
	clear()
	info = nil
end

-- Where the camera looks during a roll (nil otherwise); BowlingHud may place labels by it.
function Bowling.focus(): Vector3?
	return camFocus
end

function Bowling.init()
	Net.event("Notify").OnClientEvent:Connect(function(payload)
		if type(payload) ~= "table" or payload.kind ~= "Mode" or payload.mode ~= "bowling" then
			return
		end
		local event = payload.event
		if event == "start" then
			Bowling.start(payload)
		elseif event == "stop" then
			Bowling.stop(payload)
		elseif not running then
			return
		end
		adopt(payload)
		if event == "roll" then
			onRoll(payload)
		elseif event == "ready" then
			onReady(payload)
		elseif event == "win" then
			burst("strike")
		end
	end)
	-- A respawn mid-game: the old body is gone, so let go of it (the joints go with it) and
	-- give the controls back; the next "ready" or countdown poses the new one.
	player.CharacterAdded:Connect(function()
		token += 1
		releaseBowler()
		if dumbbell and running and info then
			returnBall()
		end
	end)
end

return Bowling
