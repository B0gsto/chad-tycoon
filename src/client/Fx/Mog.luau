--!strict
--[[
	Fx.Mog: the 3D side of the MOG TEST (MogHud draws the skill-check ring), vs rivals or
	in a 1v1 duel (start / round / finish carry vs = "pvp").

	  Rival        built locally with CharacterFactory from the rival's tier look (so only
	               this client sees its own rival), standing at rivalPos facing the player,
	               in its own outfit (RIVAL_OUTFITS by rival index) with a name tag pill.
	               Hit: a shocked flinch back and a burst of sparks off its chest (bigger
	               on a perfect, which also adds a star pop). Miss: an angry flex pose with
	               a hop and a puff over its head. Mogged: sad face, it shrinks and pops
	               with stars, confetti and a puff, and the next rival walks in after a beat
	               with its own puff.
	  Player       the player's own avatar does the mogging, nothing is drawn on or around
	               it: every result plays a full-body move on the real R15 rig (Fx.PlayerPose
	               keys, MOVES below). Hit: coil down, then step in hard into a flex from
	               the bag (STRIKE_POSES) with a hop, and bounce back to the spot. Perfect:
	               a deep coil, a knee-up leap into a double biceps and a stomp into a wide
	               stance that punches the camera in, a Most Muscular squeeze, then back.
	               Miss: knocked back off the spot in Shock, a wheeling stagger, a head shake
	               and a walk back. Rival mogged: a leaping Victory, a stomped double biceps
	               and a bicep kiss turned to the camera. The combo puts more spring in the
	               step-ins and hops. Finish: a win jumps, stomps and holds a Most Muscular;
	               a loss reels back and slumps Sad; then the avatar is handed back (at once
	               if the player walks).
	  Camera       Scriptable duel framing over the player's shoulder looking at the
	               rival, with a slow sideways drift; on finish / stop the camera goes back
	               to Custom on the humanoid (Fx.Camera then frames it behind the player).
	  Duel         no rival model: the opponent is the real character of
	               Players:GetPlayerByUserId(opponent.userId), followed live (rivalPos is
	               the fallback) and sized from its extents, and its avatar plays the same
	               moves from its own result, so both players see the mog-off. On "round":
	               a star pop (your perfect) or a cream ring (your hit) over their head, a
	               red puff when they missed. On the finish both avatars play their win /
	               loss, with stars and confetti over the loser when you won.
	  Sounds       Celebrate when a rival is mogged; the UI sounds belong to MogHud.

	Listens to Notify (kind "Mode", mode "mog") on its own; everything it makes is
	removed by clear(), the one way out: "finish" and "stop" (a quit, Home, a mode switch,
	a respawn), the character leaving, and the snapshot's modes.mog.running going false
	while the stage is still up (a lost Notify never leaves the camera scripted). On a finish
	the avatars outlive it for their last move (finales) and hand themselves back; the next
	start or the character leaving stops them sooner.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Net = require(ReplicatedStorage.Shared.Net)
local CharacterFactory = require(ReplicatedStorage.Shared:WaitForChild("CharacterFactory")) :: any
local Theme = require(ReplicatedStorage:WaitForChild("Theme")) :: any
local Client = script.Parent.Parent
local Sounds = require(Client.Sounds) :: any
local Sprites = require(script.Parent.Sprites)
local Budget = require(script.Parent.Budget)
local Animator = require(Client.Animator) :: any
local State = require(Client.State) :: any
local PlayerPose = require(script.Parent.PlayerPose)
local Camera = require(script.Parent.Camera) :: any

local MogFx = {}

local player = Players.LocalPlayer
local W = Theme.World
local C = Theme.Colors

local CAMERA_BIND = "FxMogCamera"

-- The avatars' moves (studs and degrees in the avatar's own frame; it faces its rival). Each
-- combo step up to MaxCombo adds ComboSpring of extra step-in and hop.
local MOVES = {
	StepIn = 0.7, -- studs a hit's strike lunges toward the rival
	PerfectStepIn = 1.1,
	Lean = 5, -- degrees forward at the strike
	Hop = 0.35, -- studs of a hit's hop
	PerfectHop = 0.95, -- the perfect's knee-up leap
	Recoil = 0.9, -- studs a miss knocks the avatar back...
	Stagger = 1.35, -- ...and how far it stumbles on
	ComboSpring = 0.04, -- x per combo step
	MaxCombo = 10,
}
-- Flexes a hit strikes (from a shuffled bag): the Chad rotation's showy ones.
local STRIKE_POSES = {
	"DoubleBiceps",
	"SideChest",
	"LatSpread",
	"MostMuscular",
	"Point",
	"FingerGuns",
	"BicepKiss",
	"AbsAndThigh",
	"SmugTurn",
	"Dab",
}

-- Rival juice tunables. Each rival (by its index in the run) wears its own outfit over its tier
-- look and carries a name tag in the outfit's colour; every hit bursts on the rival, and a
-- perfect also punches the duel camera in.
local RIVAL_OUTFITS: { { [string]: any } } = {
	{
		shirt = Color3.fromRGB(232, 64, 58),
		pants = Color3.fromRGB(38, 36, 62),
		top = "Jacket",
		trim = Color3.fromRGB(255, 214, 64),
		emblem = "Star",
		shoes = Color3.fromRGB(255, 255, 255),
	},
	{
		shirt = Color3.fromRGB(150, 96, 255),
		pants = Color3.fromRGB(56, 44, 110),
		top = "Hoodie",
		trim = Color3.fromRGB(98, 236, 170),
		emblem = "Heart",
		shoes = Color3.fromRGB(98, 236, 170),
	},
	{
		shirt = Color3.fromRGB(28, 190, 196),
		pants = Color3.fromRGB(30, 48, 80),
		top = "Tee",
		trim = Color3.fromRGB(255, 226, 80),
		emblem = "Star",
		shoes = Color3.fromRGB(255, 120, 60),
	},
	{
		shirt = Color3.fromRGB(255, 196, 40),
		pants = Color3.fromRGB(34, 30, 40),
		top = "Jacket",
		trim = Color3.fromRGB(240, 70, 90),
		emblem = "Disc",
		shoes = Color3.fromRGB(34, 30, 40),
	},
	{
		shirt = Color3.fromRGB(255, 110, 178),
		pants = Color3.fromRGB(44, 54, 120),
		top = "Tee",
		trim = Color3.fromRGB(255, 255, 255),
		emblem = "Heart",
		shoes = Color3.fromRGB(255, 255, 255),
	},
	{
		shirt = Color3.fromRGB(70, 200, 90),
		pants = Color3.fromRGB(26, 70, 40),
		top = "Hoodie",
		trim = Color3.fromRGB(255, 255, 255),
		emblem = "Star",
		shoes = Color3.fromRGB(255, 214, 64),
	},
}
local NAME_TAG = {
	Width = 8, -- studs
	Height = 1.9,
	Lift = 2.2, -- studs above the head's top
	-- Drawn over the hit bursts (AlwaysOnTop puts it above every other billboard), so a burst
	-- never hides the rival's name.
	OnTop = true,
	TextColor = Color3.fromRGB(255, 255, 255),
	Stroke = 3, -- px, dark pill outline
	MaxDistance = 140,
}
local HIT_BURST = {
	Sparks = 10, -- pieces on a hit ("NICE!")
	PerfectSparks = 18, -- ...and on a perfect
	SparkSize = 2.2, -- studs
	Spread = 6, -- studs the pieces fly out
	Life = 0.8,
	Ring = 8, -- ring sprite size on the rival's chest (perfect: x1.4)
	Color = Color3.fromRGB(255, 226, 80),
	-- The pieces fan out sideways and down, never into the cone above the chest that holds the
	-- head and the name tag (degrees either side of straight up), and the ring sits low.
	TopGap = 50,
	RingDrop = 0.15, -- share of the rival's height the ring sits under the chest
}
-- The rival stands this much larger than its tier look, so it fills more of the duel frame.
local RIVAL = {
	Scale = 1.3,
}
-- The crowd jumps on every hit: the fan rows of the stands near you (World.MogStage moves
-- one anchored "FanRow" root per row in a slow wave) get an extra local jump on top of the
-- server's wave, bigger on a perfect, and the rows go off in a quick ripple.
local CHEER = {
	Height = 4.6, -- studs at the top of a hit's jump
	PerfectBoost = 1.6, -- x Height on a perfect
	Time = 0.55, -- seconds of one jump
	Bounces = 2, -- jumps per cheer (each Rebound x the one before)
	Rebound = 0.55,
	Ripple = 0.06, -- seconds between neighbouring rows taking off
	Range = 160, -- studs from the player: rows of these stands jump
	Resync = 0.05, -- studs: a root this far from what we wrote was moved by the server
}
local PUNCH = {
	Dist = 3.4, -- studs the camera dollies toward the rival on a perfect
	Fov = 9, -- degrees narrower at the peak
	In = 0.08, -- seconds to the peak
	Out = 0.55, -- seconds back
}

local folder: Folder? = nil
local rival: Model? = nil
local rivalHeight = 6
local rivalPivot = CFrame.identity
local playerPos = Vector3.zero
local rivalPos = Vector3.new(0, 0, -12)
local running = false
local startedAt = 0
local runId = 0 -- bumps on every start and clear, so a finished run's timers stop
local duel = false -- a 1v1 duel: the opponent is a real player's character
local opponentId = 0
local cameraOn = false
local token = 0 -- bumps on every rival change so stale tweens stop
local selfPoser: PlayerPose.Poser? = nil
local foePoser: PlayerPose.Poser? = nil
local finales: { PlayerPose.Poser } = {} -- avatars still playing a finish move
local punchAt = -math.huge
local outfitColor = HIT_BURST.Color

local INK: Color3 = C.Ink or Color3.fromRGB(30, 34, 60)

local function reducedMotion(): boolean
	local data = State.data
	return type(data) == "table" and type(data.settings) == "table" and data.settings.reducedMotion == true
end

local function num(value: any, default: number): number
	return if type(value) == "number" and value == value then value else default
end

-- A throwaway invisible anchor for world sprites.
local function anchorAt(position: Vector3, life: number): BasePart
	local part = Instance.new("Part")
	part.Name = "MogFxAnchor"
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Transparency = 1
	part.Size = Vector3.one * 0.2
	part.CFrame = CFrame.new(position)
	part.Parent = folder or Workspace
	task.delay(life, function()
		part:Destroy()
	end)
	return part
end

local function sprite(name: string, position: Vector3, opts: { [string]: any })
	local o = table.clone(opts) :: any
	o.position = position
	Sprites.billboard(anchorAt(position, 2.2), name, o)
end

-- Runs `fn(alpha)` over `time` seconds (Quad out) on a NumberValue tween; stops early when
-- the rival changes.
local function animate(time: number, style: Enum.EasingStyle, fn: (number) -> ())
	local mine = token
	local value = Instance.new("NumberValue")
	local conn = value.Changed:Connect(function(alpha: number)
		if token == mine then
			fn(alpha)
		end
	end)
	local tween = TweenService:Create(value, TweenInfo.new(time, style, Enum.EasingDirection.Out), { Value = 1 })
	tween.Completed:Connect(function()
		conn:Disconnect()
		value:Destroy()
	end)
	tween:Play()
end

-- Duel opponent ---------------------------------------------------------------------------

-- The opponent's live root part, or nil (left, respawning or not streamed in).
local function opponentRoot(): BasePart?
	local other = Players:GetPlayerByUserId(opponentId)
	local root = other and other.Character and other.Character:FindFirstChild("HumanoidRootPart")
	return if root and root:IsA("BasePart") then root else nil
end

-- Follows the opponent's feet and height (rivalPos / rivalHeight); keeps the last values
-- when the character is gone.
local function trackOpponent()
	local root = opponentRoot()
	local model = root and root.Parent
	if not root or not model or not model:IsA("Model") then
		return
	end
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	local hip = if humanoid then humanoid.HipHeight else 2
	rivalPos = root.Position - Vector3.new(0, root.Size.Y / 2 + hip, 0)
	rivalHeight = math.clamp(model:GetExtentsSize().Y, 3, 14)
end

-- Moves -------------------------------------------------------------------------------------

type Keys = { PlayerPose.Key }

local QUAD, BACK, SINE = Enum.EasingStyle.Quad, Enum.EasingStyle.Back, Enum.EasingStyle.Sine
local IN, IN_OUT = Enum.EasingDirection.In, Enum.EasingDirection.InOut

-- A root offset: `back` studs away from the rival (negative: toward it), leaning back `lean`
-- degrees (negative: forward), turned `turn` degrees to the avatar's left, rolled `roll`.
local function at(back: number, lean: number?, turn: number?, roll: number?): CFrame
	return CFrame.new(0, 0, back) * CFrame.Angles(math.rad(lean or 0), math.rad(turn or 0), math.rad(roll or 0))
end

local function spring(combo: number): number
	return 1 + math.clamp(combo, 0, MOVES.MaxCombo) * MOVES.ComboSpring
end

-- Back onto the spot with a little bounce.
local SETTLE: PlayerPose.Key = { pose = "HandsOnHips", blend = 0.34, ease = SINE, dir = IN_OUT, hop = 0.12, hopTime = 0.26 }

-- Coil down and back, step in hard into a flex (overshooting), bounce back.
local function hitMove(combo: number): Keys
	local k = spring(combo)
	return {
		{ pose = "MogWindup", blend = 0.09, ease = QUAD, root = at(0.25), hold = 0.03 },
		{
			pose = PlayerPose.nextPose(STRIKE_POSES),
			legs = "MogLunge",
			blend = 0.16,
			ease = BACK,
			root = at(-MOVES.StepIn * k, -MOVES.Lean),
			hop = MOVES.Hop * k,
			hold = 0.42,
		},
		SETTLE,
	}
end

-- The signature: a deep coil, a knee-up leap into a double biceps, a stomp into a wide stance
-- as it lands (`impact`), a Most Muscular squeeze, back.
local function perfectMove(combo: number, impact: (() -> ())?): Keys
	local k = spring(combo)
	local step = -MOVES.PerfectStepIn * k
	return {
		{ pose = "MogWindup", blend = 0.12, ease = QUAD, root = at(0.45, 6), hold = 0.05 },
		{
			pose = "DoubleBiceps",
			legs = "MogKneeUp",
			blend = 0.14,
			ease = BACK,
			root = at(step, -4),
			hop = MOVES.PerfectHop * k,
			hopTime = 0.36,
			hold = 0.14,
		},
		{ pose = "DoubleBiceps", legs = "MogStomp", blend = 0.08, ease = QUAD, dir = IN, root = at(step, -7), cue = impact, hold = 0.22 },
		{ pose = "MostMuscular", legs = "MogStomp", blend = 0.2, ease = BACK, root = at(step, -3), hold = 0.4 },
		SETTLE,
	}
end

-- Knocked back off the spot, a wheeling stagger, a head shake, back.
local function missMove(): Keys
	return {
		{ pose = "Shock", blend = 0.1, ease = QUAD, root = at(MOVES.Recoil, 9, 0, -4), hop = 0.25, hopTime = 0.26, hold = 0.1 },
		{ pose = "MogStagger", blend = 0.24, ease = SINE, dir = IN_OUT, root = at(MOVES.Stagger, 5, 8, 5), hold = 0.18 },
		{ pose = "MogShakeOff", blend = 0.22, ease = QUAD, root = at(MOVES.Stagger * 0.8), hold = 0.36 },
		{ pose = "HandsOnHips", blend = 0.5, ease = SINE, dir = IN_OUT, hop = 0.14, hopTime = 0.3 },
	}
end

-- A rival mogged: a leaping Victory, a stomped double biceps (`impact`), a bicep kiss turned
-- toward the camera, back.
local function victoryMove(impact: (() -> ())?): Keys
	return {
		{ pose = "MogWindup", blend = 0.1, ease = QUAD, root = at(0.2), hold = 0.04 },
		{ pose = "Victory", blend = 0.16, ease = BACK, root = at(-0.5, 4), hop = 1, hopTime = 0.42, hold = 0.26 },
		{ pose = "DoubleBiceps", legs = "MogStomp", blend = 0.1, ease = QUAD, dir = IN, root = at(-0.6, -5), cue = impact, hold = 0.4 },
		{ pose = "BicepKiss", blend = 0.26, ease = BACK, root = at(-0.4, 0, -22), hold = 0.5 },
		SETTLE,
	}
end

-- The finish, won: a leaping Victory, a stomp, a long Most Muscular, easing out to stand.
local function winMove(): Keys
	return {
		{ pose = "MogWindup", blend = 0.12, ease = QUAD, root = at(0.2), hold = 0.05 },
		{ pose = "Victory", blend = 0.18, ease = BACK, root = at(-0.4, 4), hop = 1.2, hopTime = 0.46, hold = 0.3 },
		{ pose = "DoubleBiceps", legs = "MogStomp", blend = 0.1, ease = QUAD, dir = IN, root = at(-0.5, -5), hold = 0.5 },
		{ pose = "MostMuscular", legs = "MogStomp", blend = 0.24, ease = BACK, root = at(-0.5, -3), hold = 0.9 },
		{ pose = "HandsOnHips", blend = 0.4, ease = SINE, dir = IN_OUT, hold = 1 },
		{ pose = "Relaxed", blend = 0.5, ease = SINE, dir = IN_OUT },
	}
end

-- The finish, lost: reeling back, a stagger, a long sad slump, easing out to stand.
local function loseMove(): Keys
	return {
		{ pose = "Shock", blend = 0.12, ease = QUAD, root = at(MOVES.Recoil, 9), hop = 0.25, hold = 0.2 },
		{ pose = "MogStagger", blend = 0.26, ease = SINE, dir = IN_OUT, root = at(MOVES.Stagger, 5, 8, 5), hold = 0.15 },
		{ pose = "Sad", blend = 0.45, ease = SINE, dir = IN_OUT, root = at(MOVES.Stagger * 0.75), hold = 1.6 },
		{ pose = "Relaxed", blend = 0.6, ease = SINE, dir = IN_OUT },
	}
end

-- A perfect's (or a mog's) stomp lands: the duel camera punches in.
local function punchCamera()
	if not reducedMotion() then
		punchAt = os.clock()
	end
end

-- The move for a skill-check result; `impact` goes off as a perfect's stomp lands.
local function playResult(poser: PlayerPose.Poser?, result: any, combo: number, impact: (() -> ())?)
	if not poser then
		return
	end
	if result == "perfect" then
		poser:play(perfectMove(combo, impact))
	elseif result == "hit" then
		poser:play(hitMove(combo))
	elseif result == "miss" then
		poser:play(missMove())
	end
end

local function stopPosers()
	if selfPoser then
		selfPoser:stop()
	end
	if foePoser then
		foePoser:stop()
	end
	selfPoser, foePoser = nil, nil
end

local function stopFinales()
	for _, poser in finales do
		poser:stop()
	end
	table.clear(finales)
end

-- Gives an avatar its finish move; it hands itself back when that is over.
local function finale(poser: PlayerPose.Poser?, won: boolean)
	if poser then
		poser:play(if won then winMove() else loseMove(), true)
		table.insert(finales, poser)
	end
end

-- Rival -------------------------------------------------------------------------------------

local function tierLook(tier: number): any
	local tiers = Theme.Tiers
	local entry = tiers[math.clamp(math.floor(tier), 1, #tiers)]
	return entry and entry.Look
end

local function removeRival()
	token += 1
	if rival then
		rival:Destroy()
		rival = nil
	end
end

-- A pill over the rival's head with its name, in its outfit's colour.
local function nameTag(m: Model, name: string, color: Color3)
	local head = m:FindFirstChild("Head", true)
	local adornee = if head and head:IsA("BasePart") then head else m.PrimaryPart
	if not adornee then
		return
	end
	local gui = Instance.new("BillboardGui")
	gui.Name = "RivalTag"
	gui.Size = UDim2.fromScale(NAME_TAG.Width, NAME_TAG.Height)
	gui.StudsOffsetWorldSpace = Vector3.new(0, adornee.Size.Y / 2 + NAME_TAG.Lift, 0)
	gui.LightInfluence = 0
	gui.MaxDistance = NAME_TAG.MaxDistance
	gui.AlwaysOnTop = NAME_TAG.OnTop
	gui.Adornee = adornee
	local pill = Instance.new("Frame")
	pill.Size = UDim2.fromScale(1, 1)
	pill.BackgroundColor3 = color
	pill.BorderSizePixel = 0
	pill.Parent = gui
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0.5, 0)
	corner.Parent = pill
	local stroke = Instance.new("UIStroke")
	stroke.Color = INK
	stroke.Thickness = NAME_TAG.Stroke
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Parent = pill
	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromScale(0.88, 0.78)
	label.Position = UDim2.fromScale(0.06, 0.11)
	label.TextScaled = true
	label.Font = Theme.Fonts.Title or Enum.Font.FredokaOne
	label.Text = string.upper(name)
	label.TextColor3 = NAME_TAG.TextColor
	label.TextStrokeColor3 = INK
	label.TextStrokeTransparency = 0
	label.Parent = pill
	gui.Parent = m
end

-- Sparks, stars and a ring bursting off the rival's chest on every hit (bigger on a perfect).
local function rivalBurst(perfect: boolean)
	local chest = rivalPos + Vector3.new(0, rivalHeight * 0.6, 0)
	local ringAt = chest - Vector3.new(0, rivalHeight * HIT_BURST.RingDrop, 0)
	local toward = Vector3.new(playerPos.X - rivalPos.X, 0, playerPos.Z - rivalPos.Z)
	local front = if toward.Magnitude > 0.1 then toward.Unit else Vector3.new(0, 0, 1)
	local side = front:Cross(Vector3.yAxis)
	sprite("Ring", ringAt + front * 1.2, {
		size = HIT_BURST.Ring * (if perfect then 1.4 else 1),
		life = 0.5,
		rise = Vector3.zero,
		color = if perfect then W.Sunny else outfitColor,
	})
	local n = Budget.count(if perfect then HIT_BURST.PerfectSparks else HIT_BURST.Sparks)
	for i = 1, n do
		if not Sprites.room() then
			break -- decorative: the device's sprite budget is full
		end
		-- Round the circle from just past the top cone on one side to just before it on the
		-- other (angle 90 degrees is straight up).
		local gap = math.rad(HIT_BURST.TopGap)
		local angle = math.pi / 2 + gap + (i - 0.5 + math.random() * 0.4) / n * (math.pi * 2 - gap * 2)
		local out = side * math.cos(angle) + Vector3.yAxis * math.sin(angle)
		local kind = if i % 3 == 0 then "StarPop" elseif i % 3 == 1 then "Sparkle" else "Confetti"
		sprite(kind, chest + front * 1.5 + out * 0.6, {
			size = HIT_BURST.SparkSize * (0.8 + math.random() * 0.4),
			life = HIT_BURST.Life,
			delay = i * 0.012,
			rise = out * HIT_BURST.Spread + front * 1.5,
			spin = 120,
			color = if kind == "Confetti" then nil else (if i % 2 == 0 then HIT_BURST.Color else outfitColor),
		})
	end
end

local function spawnRival(info: any)
	removeRival()
	if type(info) ~= "table" then
		return
	end
	local base = tierLook(num(info.tier, 1))
	if not base or not folder then
		return
	end
	local look = table.clone(base)
	local outfit = RIVAL_OUTFITS[(math.max(1, math.floor(num(info.index, 1))) - 1) % #RIVAL_OUTFITS + 1]
	for key, value in outfit do
		look[key] = value
	end
	outfitColor = outfit.shirt
	look.exprs = { "Smug", "Shock", "Angry", "Sad", "Determined" }
	look.expr = "Smug"
	local ok, model = pcall(CharacterFactory.build, look, "MogRival")
	if not ok or not model then
		warn("[Fx.Mog] rival build failed: " .. tostring(model))
		return
	end
	local m = model :: Model
	m:ScaleTo(m:GetScale() * RIVAL.Scale)
	local height = m:GetAttribute("Height")
	rivalHeight = (if type(height) == "number" then height else 6) * RIVAL.Scale
	local face = Vector3.new(playerPos.X, rivalPos.Y, playerPos.Z)
	rivalPivot = if (face - rivalPos).Magnitude > 0.1 then CFrame.lookAt(rivalPos, face) else CFrame.new(rivalPos)
	m:PivotTo(rivalPivot)
	m.Parent = folder
	rival = m
	CharacterFactory.setExpression(m, "Smug")
	nameTag(m, if type(info.name) == "string" then info.name else "RIVAL", outfit.shirt)
	-- Walk-in pop: grows from small with a puff (the Animator holds it while it scales,
	-- then re-captures its rest pose).
	Animator.hold(m)
	local full = m:GetScale()
	m:ScaleTo(full * 0.2)
	animate(0.45, Enum.EasingStyle.Back, function(a)
		m:ScaleTo(full * (0.2 + 0.8 * a))
		m:PivotTo(rivalPivot)
	end)
	task.delay(0.5, function()
		if rival == m then
			m:ScaleTo(full)
			m:PivotTo(rivalPivot)
			Animator.release(m)
		end
	end)
	sprite("Puff", rivalPos + Vector3.new(0, 1, 0), { size = 6, life = 0.7, rise = Vector3.new(0, 2, 0) })
end

local function setExpr(name: string, back: number?)
	local m = rival
	if not m then
		return
	end
	CharacterFactory.setExpression(m, name)
	if back then
		local mine = token
		task.delay(back, function()
			if token == mine and rival == m then
				CharacterFactory.setExpression(m, "Smug")
			end
		end)
	end
end

-- The rival leans back a little (away from the player) and settles.
local function flinch(distance: number)
	local m = rival
	if not m then
		return
	end
	local away = -rivalPivot.LookVector
	animate(0.5, Enum.EasingStyle.Quad, function(a)
		local push = math.sin(a * math.pi) * distance
		m:PivotTo(rivalPivot * CFrame.Angles(math.rad(8) * math.sin(a * math.pi), 0, 0) + away * push)
	end)
end

-- The rival puffs up: a quick flex pose with a little hop.
local function puffUp()
	local m = rival
	if m then
		Animator.show(m, "DoubleBiceps", 1.2, 0.4)
	end
end

local function moggedPop()
	local m = rival
	if not m then
		return
	end
	CharacterFactory.setExpression(m, "Sad")
	Animator.hold(m)
	token += 1 -- this model is leaving; the shrink below owns it now
	rival = nil
	local full = m:GetScale()
	local head = rivalPos + Vector3.new(0, rivalHeight * 0.6, 0)
	local value = Instance.new("NumberValue")
	value.Changed:Connect(function(a: number)
		if not m.Parent then
			return
		end
		m:ScaleTo(math.max(full * (1 - a), 0.02))
		m:PivotTo(rivalPivot * CFrame.Angles(0, math.rad(540 * a), 0))
	end)
	local tween = TweenService:Create(value, TweenInfo.new(0.5, Enum.EasingStyle.Back, Enum.EasingDirection.In), { Value = 0.98 })
	tween.Completed:Connect(function()
		value:Destroy()
		m:Destroy()
	end)
	task.delay(0.25, function()
		tween:Play()
	end)
	task.delay(0.7, function()
		sprite("Puff", head, { size = 7, life = 0.8, rise = Vector3.new(0, 2, 0) })
		sprite("Ring", head, { size = 8, life = 0.6, rise = Vector3.zero, color = W.Sunny })
		local pops = Budget.count(6) -- decorative: fewer on phones (Fx.Budget)
		for i = 1, pops do
			if not Sprites.room() then
				break -- decorative: the device's sprite budget is full
			end
			local angle = i / pops * math.pi * 2
			local offset = Vector3.new(math.cos(angle) * 1.5, math.sin(angle) * 1.2, 0)
			sprite(if i % 2 == 0 then "StarPop" else "Confetti", head + offset, {
				size = 2.6,
				life = 1,
				delay = i * 0.03,
				rise = Vector3.new(math.cos(angle) * 4, 3 + math.sin(angle) * 2, 0),
				spin = 90,
			})
		end
		Sounds.play("Celebrate")
	end)
end

-- Camera ------------------------------------------------------------------------------------

local function releaseCamera()
	if not cameraOn then
		return
	end
	cameraOn = false
	RunService:UnbindFromRenderStep(CAMERA_BIND)
	punchAt = -math.huge
	Camera.setFov("mogPunch", 0)
	local camera = Workspace.CurrentCamera
	if camera then
		local humanoid = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
		if humanoid then
			camera.CameraSubject = humanoid
		end
		camera.CameraType = Enum.CameraType.Custom
	end
end

local function takeCamera()
	local camera = Workspace.CurrentCamera
	if not camera then
		return
	end
	cameraOn = true
	camera.CameraType = Enum.CameraType.Scriptable
	local started = os.clock()
	local current: CFrame? = nil
	RunService:BindToRenderStep(CAMERA_BIND, Enum.RenderPriority.Camera.Value, function(dt: number)
		local cam = Workspace.CurrentCamera
		if not cam then
			return
		end
		if cam.CameraType ~= Enum.CameraType.Scriptable then
			cam.CameraType = Enum.CameraType.Scriptable
		end
		if duel then
			trackOpponent()
		end
		local flat = Vector3.new(rivalPos.X - playerPos.X, 0, rivalPos.Z - playerPos.Z)
		local forward = if flat.Magnitude > 0.1 then flat.Unit else Vector3.new(0, 0, -1)
		local right = forward:Cross(Vector3.yAxis)
		local t = os.clock() - started
		-- Over the right shoulder, raised for taller rivals; a slow sideways drift.
		local lift = 5.5 + math.max(rivalHeight - 6, 0) * 0.35
		local eye = playerPos - forward * 9 + right * (3.4 + math.sin(t * 0.35) * 0.8) + Vector3.new(0, lift + math.sin(t * 0.27) * 0.3, 0)
		local focus = rivalPos + Vector3.new(0, rivalHeight * 0.55, 0) - forward * 2
		local goal = CFrame.lookAt(eye, focus)
		current = if current then current:Lerp(goal, 1 - math.exp(-dt * 4)) else goal
		-- A perfect hit punches in: a quick dolly toward the rival and a narrower FOV, eased back.
		local since = os.clock() - punchAt
		local punch = 0
		if since < PUNCH.In then
			punch = since / PUNCH.In
		elseif since < PUNCH.In + PUNCH.Out then
			punch = (1 - (since - PUNCH.In) / PUNCH.Out) ^ 2
		end
		cam.CFrame = (current :: CFrame) * CFrame.new(0, 0, -PUNCH.Dist * punch)
		Camera.setFov("mogPunch", if punch > 0.01 then -PUNCH.Fov * punch else 0)
	end)
end

-- Crowd jump -----------------------------------------------------------------------------------

type CheerRow = { root: BasePart, server: CFrame, wrote: CFrame?, delay: number }
local cheerRows: { CheerRow } = {}
local cheerAt = -math.huge
local cheerHeight = 0
local cheerConn: RBXScriptConnection? = nil

local function stopCheer()
	if cheerConn then
		cheerConn:Disconnect()
		cheerConn = nil
	end
	for _, row in cheerRows do
		if row.wrote and row.root.Parent then
			row.root.CFrame = row.server
		end
		row.wrote = nil
	end
	table.clear(cheerRows)
end

local function findCheerRows()
	table.clear(cheerRows)
	local map = Workspace:FindFirstChild("Map")
	local stage = map and map:FindFirstChild("MogStage")
	if not stage then
		return
	end
	for _, part in stage:GetChildren() do
		if part.Name == "FanRow" and part:IsA("BasePart") and (part.Position - playerPos).Magnitude <= CHEER.Range then
			table.insert(cheerRows, { root = part, server = part.CFrame, delay = 0 })
		end
	end
	-- The ripple runs round the stand from the row nearest the rival.
	table.sort(cheerRows, function(a, b)
		return (a.root.Position - rivalPos).Magnitude < (b.root.Position - rivalPos).Magnitude
	end)
	for i, row in cheerRows do
		row.delay = (i - 1) * CHEER.Ripple
	end
end

local function cheer(perfect: boolean)
	if reducedMotion() then
		return
	end
	if #cheerRows == 0 then
		findCheerRows()
	end
	cheerAt = os.clock()
	cheerHeight = CHEER.Height * (if perfect then CHEER.PerfectBoost else 1)
	if cheerConn then
		return
	end
	cheerConn = RunService.RenderStepped:Connect(function()
		local t = os.clock() - cheerAt
		local busy = false
		for _, row in cheerRows do
			local root = row.root
			if root.Parent then
				local now = root.CFrame
				local wrote = row.wrote
				if not wrote or (now.Position - wrote.Position).Magnitude > CHEER.Resync then
					row.server = now -- the server's wave moved it since our last write
				end
				local k = (t - row.delay) / CHEER.Time
				if k > 0 and k < CHEER.Bounces then
					busy = true
					local n = math.floor(k)
					local lift = cheerHeight * CHEER.Rebound ^ n * math.sin(math.pi * (k - n))
					local cf = row.server * CFrame.new(0, lift, 0)
					row.wrote = cf
					root.CFrame = cf
				elseif k <= 0 then
					busy = true
				elseif wrote then
					root.CFrame = row.server
					row.wrote = nil
				end
			end
		end
		if not busy and cheerConn then
			cheerConn:Disconnect()
			cheerConn = nil
		end
	end)
end

-- Run ---------------------------------------------------------------------------------------

local function clear()
	running, duel, opponentId = false, false, 0
	runId += 1
	-- The camera first: whatever else fails, the player gets the follow camera back.
	releaseCamera()
	stopPosers()
	removeRival()
	stopCheer()
	if folder then
		folder:Destroy()
		folder = nil
	end
end

local function onStart(p: any)
	clear()
	stopFinales()
	running = true
	startedAt = os.clock()
	if typeof(p.playerPos) == "Vector3" then
		playerPos = p.playerPos
	else
		local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
		playerPos = if root and root:IsA("BasePart") then root.Position - Vector3.new(0, 3, 0) else Vector3.zero
	end
	rivalPos = if typeof(p.rivalPos) == "Vector3" then p.rivalPos else playerPos + Vector3.new(0, 0, -14)
	local f = Instance.new("Folder")
	f.Name = "MogFx"
	f.Parent = Workspace
	folder = f
	if p.vs == "pvp" then
		duel = true
		local opponent = if type(p.opponent) == "table" then p.opponent else {}
		opponentId = math.floor(num(opponent.userId, 0))
		rivalHeight = 6
		trackOpponent()
	else
		spawnRival(p.rival)
	end
	selfPoser = PlayerPose.attach(player.Character)
	takeCamera()
end

local function onResult(p: any)
	local combo = num(p.combo, 0)
	local head = rivalPos + Vector3.new(0, rivalHeight * 0.85, 0)
	playResult(selfPoser, p.result, combo, punchCamera)
	if p.result == "perfect" then
		setExpr("Shock", 0.8)
		flinch(1.4)
		rivalBurst(true)
		cheer(true)
		sprite("StarPop", head, { size = 3, life = 0.8, rise = Vector3.new(0, 2, 0), spin = 60 })
	elseif p.result == "hit" then
		setExpr("Shock", 0.6)
		flinch(0.8)
		rivalBurst(false)
		cheer(false)
	else
		setExpr("Angry", 1)
		puffUp()
		sprite("Puff", head, { size = 3, life = 0.6, rise = Vector3.new(0, 1.5, 0), color = C.Bad })
	end
end

-- The opponent's avatar, posed once it has streamed in (it may come after the start).
local function foe(): PlayerPose.Poser?
	if not foePoser then
		local root = opponentRoot()
		local model = root and root.Parent
		foePoser = if model and model:IsA("Model") then PlayerPose.attach(model) else nil
	end
	return foePoser
end

-- A duel round: both avatars play their own result, sprites over the opponent.
local function onRound(p: any)
	local you = if type(p.you) == "table" then p.you else {}
	local opp = if type(p.opp) == "table" then p.opp else {}
	local head = rivalPos + Vector3.new(0, rivalHeight + 0.6, 0)
	playResult(selfPoser, you.result, num(you.combo, 0), punchCamera)
	playResult(foe(), opp.result, 0)
	if you.result == "perfect" then
		sprite("StarPop", head, { size = 3, life = 0.8, rise = Vector3.new(0, 2, 0), spin = 60 })
	elseif you.result == "hit" then
		sprite("Ring", head, { size = 3.5, life = 0.5, rise = Vector3.new(0, 1, 0), color = W.Cream })
	end
	if opp.result == "miss" then
		-- Their own miss hurts them: a small red puff over their head.
		sprite("Puff", head, { size = 3, life = 0.6, rise = Vector3.new(0, 1.5, 0), color = C.Bad })
	end
end

-- The duel's last word over the loser, made after clear() so the sprites outlive the folder
-- (the avatars' own win / loss moves are their finales).
local function duelFinish(won: boolean, foeHead: Vector3)
	if won then
		sprite("Ring", foeHead, { size = 7, life = 0.6, rise = Vector3.zero, color = W.Sunny })
		local pops = Budget.count(6) -- decorative: fewer on phones (Fx.Budget)
		for i = 1, pops do
			if not Sprites.room() then
				break -- decorative: the device's sprite budget is full
			end
			local angle = i / pops * math.pi * 2
			local offset = Vector3.new(math.cos(angle) * 1.5, math.sin(angle) * 1.2, 0)
			sprite(if i % 2 == 0 then "StarPop" else "Confetti", foeHead + offset, {
				size = 2.6,
				life = 1,
				delay = i * 0.03,
				rise = Vector3.new(math.cos(angle) * 4, 3 + math.sin(angle) * 2, 0),
				spin = 90,
			})
		end
		Sounds.play("Celebrate")
	end
end

-- Ends the run but lets the avatars play out their win / loss first (clear() would stop them).
local function finish(won: boolean, foeWon: boolean)
	local me, them = selfPoser, if duel then foe() else nil
	selfPoser, foePoser = nil, nil
	clear()
	finale(me, won)
	finale(them, foeWon)
end

function MogFx.onNotify(p: any)
	if type(p) ~= "table" then
		return
	end
	local event = p.event
	if event == "start" then
		onStart(p)
	elseif not running then
		return
	elseif event == "check" then
		if not duel then
			setExpr("Determined")
		end
	elseif event == "result" then
		if not duel then
			onResult(p)
		end
	elseif event == "round" then
		if duel then
			onRound(p)
		end
	elseif event == "rival" then
		if selfPoser then
			selfPoser:play(victoryMove(punchCamera))
		end
		moggedPop()
		local nextRival = p.rival
		local run = runId
		task.delay(1.1, function()
			if running and run == runId and type(nextRival) == "table" then
				spawnRival(nextRival)
			end
		end)
	elseif event == "finish" and duel then
		local foeHead = rivalPos + Vector3.new(0, rivalHeight * 0.85, 0)
		local won = p.won == true
		finish(won, not won and p.draw ~= true)
		duelFinish(won, foeHead)
	elseif event == "finish" then
		finish(p.passed == true, false)
	elseif event == "stop" then
		clear()
	end
end

function MogFx.init()
	Net.event("Notify").OnClientEvent:Connect(function(payload)
		if type(payload) == "table" and payload.kind == "Mode" and payload.mode == "mog" then
			MogFx.onNotify(payload)
		end
	end)
	player.CharacterRemoving:Connect(function()
		stopFinales()
		if running then
			clear()
		end
	end)
	-- The safety net: the server says no Mog run is on while the stage is still up here.
	State.changed.Event:Connect(function(data: any)
		local info = type(data) == "table" and type(data.modes) == "table" and data.modes.mog
		if running and type(info) == "table" and info.running == false and os.clock() - startedAt > 2 then
			clear()
		end
	end)
end

return MogFx
