--[[
	Poses: the procedural animation library for unit models.

	Pure Luau (CFrame maths only, no services or instances), so the same code
	runs in the client Animator and in the Lune preview exporter.

	Rig: every unit is a 15-limb R15-style rig (see LIMBS). Each limb rotates
	about a joint pivot. Pivots are positions relative to the model's Root part
	(the feet) and are written onto the model by CharacterFactory. At rest every
	limb frame is CFrame.new(pivot) with no rotation, so a joint transform is
	simply the rotation applied at that pivot:

	  frame[limb] = frame[parent] * CFrame.new(pivot[limb] - pivot[parent]) * transform[limb]

	Axes (model space): +X is the unit's right, +Y up, the unit faces -Z.
	Pose angles are degrees, applied as CFrame.Angles(x, y, z) (Z first, then Y,
	then X). Useful directions for the right arm/leg (left limbs are mirrored):
	  UpperArm  +z raises the arm sideways, +x raises it forwards, +y swings a
	            raised arm forwards
	  LowerArm  +x bends the elbow forwards, +z bends it outwards/up
	  UpperLeg  +x lifts the knee forwards, +z spreads the leg
	  LowerLeg  -x bends the knee
	  Torso     +x leans back, +y turns to the unit's left
	  Head      +x looks up, +y turns to the unit's left

	Animation: each animation set ("Chad" / "Bot" / "Fan" / "Story") is a looping
	sequence of poses held for a couple of seconds with eased blends between
	them, plus an idle overlay (breathing / hovering / bouncing). The sequence
	order and phase come from a per-model seed so a shelf of units never moves
	in sync.

	Explicit poses (cutscenes, code-driven models): samplePose / samplePoseInto
	give one named pose, blendInto mixes two, and the Walk / Run / Strut gaits
	are cycles of time; gaitTime(gait, distance, scale) turns the distance a
	model has travelled into the time that keeps its feet planted. Pose names
	are looked up in the model's set first, then in Story, Fan, Chad and Bot.
]]

local Poses = {}

Poses.LIMBS = {
	"LowerTorso",
	"UpperTorso",
	"Head",
	"LeftUpperArm",
	"LeftLowerArm",
	"LeftHand",
	"RightUpperArm",
	"RightLowerArm",
	"RightHand",
	"LeftUpperLeg",
	"LeftLowerLeg",
	"LeftFoot",
	"RightUpperLeg",
	"RightLowerLeg",
	"RightFoot",
}

Poses.PARENT = {
	UpperTorso = "LowerTorso",
	Head = "UpperTorso",
	LeftUpperArm = "UpperTorso",
	LeftLowerArm = "LeftUpperArm",
	LeftHand = "LeftLowerArm",
	RightUpperArm = "UpperTorso",
	RightLowerArm = "RightUpperArm",
	RightHand = "RightLowerArm",
	LeftUpperLeg = "LowerTorso",
	LeftLowerLeg = "LeftUpperLeg",
	LeftFoot = "LeftLowerLeg",
	RightUpperLeg = "LowerTorso",
	RightLowerLeg = "RightUpperLeg",
	RightFoot = "RightLowerLeg",
}

-- Attribute names CharacterFactory writes on each unit model.
Poses.PIVOT_PREFIX = "J_" -- Vector3 joint pivot per limb, relative to Root, before scaling
Poses.SCALE_ATTRIBUTE = "RigScale"
Poses.SET_ATTRIBUTE = "AnimSet"
Poses.LIMB_ATTRIBUTE = "Limb"
Poses.TAG = "AnimatedUnit"

local LIMBS = Poses.LIMBS
local N = #LIMBS
local SIZE = N * 3 + 1 -- three angles per limb, then the root's vertical offset
local ROOT_Y = SIZE

local INDEX: { [string]: number } = {}
for i, limb in LIMBS do
	INDEX[limb] = i
end

local MIRROR = {
	LeftUpperArm = "RightUpperArm",
	LeftLowerArm = "RightLowerArm",
	LeftHand = "RightHand",
	LeftUpperLeg = "RightUpperLeg",
	LeftLowerLeg = "RightLowerLeg",
	LeftFoot = "RightFoot",
}

type Vec = { number }
type PoseDef = {
	base: Vec,
	anim: ((v: Vec, t: number, seed: number) -> ())?,
}

-- Builds a pose vector. Right-side limbs are mirrored onto the left unless
-- the left limb is given explicitly.
local function P(def: { [string]: { number } }, rootY: number?): Vec
	local v = table.create(SIZE, 0)
	local function set(limb: string, x: number, y: number, z: number)
		local i = INDEX[limb] * 3
		v[i - 2], v[i - 1], v[i] = x, y, z
	end
	for limb, a in def do
		set(limb, a[1] or 0, a[2] or 0, a[3] or 0)
	end
	for left, right in MIRROR do
		local a = def[right]
		if def[left] == nil and a then
			set(left, a[1] or 0, -(a[2] or 0), -(a[3] or 0))
		end
	end
	v[ROOT_Y] = rootY or 0
	return v
end

local function add(v: Vec, limb: string, x: number, y: number, z: number)
	local i = INDEX[limb] * 3
	v[i - 2] += x
	v[i - 1] += y
	v[i] += z
end

-- Deterministic 0..1 noise.
local function hash(n: number): number
	local x = math.sin(n * 12.9898 + 78.233) * 43758.5453
	return x - math.floor(x)
end

local function smooth(a: number): number
	a = math.clamp(a, 0, 1)
	return a * a * (3 - 2 * a)
end

local function easeInOutCubic(a: number): number
	a = math.clamp(a, 0, 1)
	if a < 0.5 then
		return 4 * a * a * a
	end
	local f = -2 * a + 2
	return 1 - f * f * f / 2
end

-- Stepped random value that snaps to a new target every `period` seconds
-- (servo-like), easing over `snap` seconds.
local function servo(t: number, period: number, snap: number, seed: number, lo: number, hi: number): number
	local k = math.floor(t / period)
	local a = lo + (hi - lo) * hash(k * 7.13 + seed)
	local b = lo + (hi - lo) * hash((k - 1) * 7.13 + seed)
	local w = smooth((t - k * period) / snap)
	return b + (a - b) * w
end

-- Chad poses ---------------------------------------------------------------------

local CHAD: { [string]: PoseDef } = {}

CHAD.Relaxed = {
	base = P({
		RightUpperArm = { 0, 0, 9 },
		RightLowerArm = { 10, 0, 0 },
		RightUpperLeg = { 0, 0, 4 },
		RightFoot = { 0, 0, -4 },
	}),
}

-- Front double biceps: upper arms out level, forearms up beside the head.
CHAD.DoubleBiceps = {
	base = P({
		UpperTorso = { 5, 0, 0 },
		Head = { 6, 0, 0 },
		RightUpperArm = { 0, 14, 94 },
		RightLowerArm = { 0, 0, 104 },
		RightHand = { 0, 0, 18 },
		RightUpperLeg = { 3, 0, 9 },
		RightLowerLeg = { -5, 0, 0 },
		RightFoot = { 2, 0, -9 },
	}, -0.03),
	anim = function(v, t)
		-- Squeeze the peaks.
		local s = math.sin(t * 5) * 3
		add(v, "RightLowerArm", 0, 0, s)
		add(v, "LeftLowerArm", 0, 0, -s)
	end,
}

-- Side chest: torso turned, both forearms across the belly.
CHAD.SideChest = {
	base = P({
		LowerTorso = { 0, -22, 0 },
		UpperTorso = { 3, -12, 0 },
		Head = { 4, 30, 0 },
		RightUpperArm = { 22, 55, 10 },
		RightLowerArm = { 92, 0, 0 },
		LeftUpperArm = { 34, -48, -4 },
		LeftLowerArm = { 76, 0, 0 },
		RightUpperLeg = { 14, 0, 4 },
		RightLowerLeg = { -30, 0, 0 },
		RightFoot = { -10, 0, 0 },
		LeftUpperLeg = { 0, 0, -6 },
		LeftFoot = { 0, 0, 6 },
	}, -0.06),
}

-- Lat spread: fists on the waist, elbows flared forwards.
CHAD.LatSpread = {
	base = P({
		UpperTorso = { 6, 0, 0 },
		Head = { 4, 0, 0 },
		RightUpperArm = { 0, 26, 50 },
		RightLowerArm = { 24, 0, -104 },
		RightHand = { 0, 0, -10 },
		RightUpperLeg = { 2, 0, 8 },
		RightLowerLeg = { -4, 0, 0 },
		RightFoot = { 2, 0, -8 },
	}, -0.02),
	anim = function(v, t)
		local s = (math.sin(t * 2.2) + 1) * 3
		add(v, "RightUpperArm", 0, 0, s)
		add(v, "LeftUpperArm", 0, 0, -s)
	end,
}

-- "Most muscular" crab: leaning in, fists together in front of the belly.
CHAD.MostMuscular = {
	base = P({
		UpperTorso = { -16, 0, 0 },
		Head = { 12, 0, 0 },
		RightUpperArm = { 30, 36, 40 },
		RightLowerArm = { 34, 0, -78 },
		RightHand = { 0, 0, -12 },
		RightUpperLeg = { 14, 0, 12 },
		RightLowerLeg = { -24, 0, 0 },
		RightFoot = { 10, 0, -12 },
	}, -0.12),
	anim = function(v, t)
		local s = math.sin(t * 9) * 1.2
		add(v, "UpperTorso", s, 0, 0)
	end,
}

CHAD.HandsOnHips = {
	base = P({
		UpperTorso = { 3, 0, 0 },
		Head = { 8, -14, 0 },
		RightUpperArm = { 0, -14, 40 },
		RightLowerArm = { 14, 0, -102 },
		RightHand = { 0, 0, -18 },
		RightUpperLeg = { 0, 0, 8 },
		RightFoot = { 0, 0, -8 },
	}),
}

-- Chin up, jaw out, one hand stroking the jaw, the other on the hip.
CHAD.Mewing = {
	base = P({
		UpperTorso = { 4, 0, 0 },
		Head = { 20, -8, 5 },
		RightUpperArm = { 79, 0, -14 },
		RightLowerArm = { 140, 0, -44 },
		RightHand = { 0, 0, -10 },
		LeftUpperArm = { 0, 14, -40 },
		LeftLowerArm = { 14, 0, 102 },
		LeftHand = { 0, 0, 18 },
		RightUpperLeg = { 0, 0, 5 },
		RightFoot = { 0, 0, -5 },
	}),
	anim = function(v, t)
		add(v, "Head", math.sin(t * 1.4) * 3, 0, 0)
	end,
}

-- Arms crossed, slow smug look from side to side.
CHAD.SmugTurn = {
	base = P({
		UpperTorso = { 4, 0, 0 },
		Head = { 10, 0, 0 },
		RightUpperArm = { 28, 42, -6 },
		RightLowerArm = { 98, 0, 0 },
		LeftUpperArm = { 22, -36, 6 },
		LeftLowerArm = { 106, 0, 0 },
		RightUpperLeg = { 0, 0, 6 },
		RightFoot = { 0, 0, -6 },
	}),
	anim = function(v, t)
		local turn = math.sin(t * 0.9)
		add(v, "Head", 0, turn * 34, turn * 4)
		add(v, "UpperTorso", 0, turn * 6, 0)
	end,
}

-- Pointing at the viewer, other hand on the hip.
CHAD.Point = {
	base = P({
		UpperTorso = { 0, 12, 0 },
		Head = { 4, -6, -7 },
		RightUpperArm = { 86, 14, 2 },
		RightLowerArm = { 4, 0, 0 },
		LeftUpperArm = { 0, 14, -40 },
		LeftLowerArm = { 14, 0, 102 },
		LeftHand = { 0, 0, 18 },
		RightUpperLeg = { 4, 0, 6 },
		RightLowerLeg = { -6, 0, 0 },
		RightFoot = { 0, 0, -6 },
	}),
	anim = function(v, t)
		-- Little "you!" jabs.
		local jab = math.max(0, math.sin(t * 6)) ^ 4 * 6
		add(v, "RightUpperArm", jab, 0, 0)
	end,
}

-- Both fists punched up in a V, pumping.
CHAD.Victory = {
	base = P({
		UpperTorso = { 8, 0, 0 },
		Head = { 16, 0, 0 },
		RightUpperArm = { 0, 8, 150 },
		RightLowerArm = { 0, 0, 14 },
		RightUpperLeg = { 0, 0, 10 },
		RightFoot = { 0, 0, -10 },
	}),
	anim = function(v, t)
		local pump = math.abs(math.sin(t * 4.5))
		add(v, "RightUpperArm", 0, 0, pump * 8)
		add(v, "LeftUpperArm", 0, 0, -pump * 8)
		v[ROOT_Y] += 0.05 * pump
	end,
}

-- Abs and thigh: hands behind the head, abs crunched, one leg forward.
CHAD.AbsAndThigh = {
	base = P({
		UpperTorso = { -10, 0, 0 },
		Head = { 4, 0, 0 },
		RightUpperArm = { 0, -30, 108 },
		RightLowerArm = { 0, 0, 150 },
		RightUpperLeg = { 20, 0, 6 },
		RightLowerLeg = { -12, 0, 0 },
		RightFoot = { 6, 0, -6 },
		LeftUpperLeg = { -4, 0, -6 },
		LeftFoot = { 0, 0, 6 },
	}, -0.04),
	anim = function(v, t)
		add(v, "UpperTorso", -math.abs(math.sin(t * 3)) * 4, 0, 0)
	end,
}

-- Flexes the right arm and kisses the peak, other hand on the hip.
CHAD.BicepKiss = {
	base = P({
		UpperTorso = { 4, -10, 0 },
		Head = { 4, -44, -10 },
		RightUpperArm = { 0, 12, 96 },
		RightLowerArm = { 0, 0, 112 },
		RightHand = { 0, 0, 14 },
		LeftUpperArm = { 0, 14, -40 },
		LeftLowerArm = { 14, 0, 102 },
		LeftHand = { 0, 0, 18 },
		RightUpperLeg = { 0, 0, 6 },
		RightFoot = { 0, 0, -6 },
	}),
	anim = function(v, t)
		local kiss = math.max(0, math.sin(t * 3)) ^ 6
		add(v, "Head", -kiss * 6, -kiss * 6, 0)
	end,
}

-- Dab: face in the right elbow, left arm flung up and out.
CHAD.Dab = {
	base = P({
		UpperTorso = { -6, 14, 8 },
		Head = { -22, 30, 12 },
		RightUpperArm = { 25, 125, 90 },
		RightLowerArm = { 0, 0, 80 },
		LeftUpperArm = { 0, 0, -135 },
		LeftLowerArm = { 0, 0, 0 },
		LeftHand = { 0, 0, 0 },
		RightUpperLeg = { 0, 0, 10 },
		RightFoot = { 0, 0, -10 },
	}, -0.02),
}

-- Finger guns at the viewer, firing in turn.
CHAD.FingerGuns = {
	base = P({
		UpperTorso = { 2, 6, 0 },
		Head = { 6, -6, -6 },
		RightUpperArm = { 88, -4, 6 },
		RightLowerArm = { 4, 0, 0 },
		RightUpperLeg = { 4, 0, 8 },
		RightLowerLeg = { -6, 0, 0 },
		RightFoot = { 0, 0, -8 },
	}),
	anim = function(v, t)
		local right = math.max(0, math.sin(t * 5)) ^ 8
		local left = math.max(0, -math.sin(t * 5)) ^ 8
		add(v, "RightUpperArm", right * 14, 0, 0)
		add(v, "LeftUpperArm", left * 14, 0, 0)
	end,
}

-- "Too easy" shrug: forearms out, palms up, head tilted.
CHAD.Shrug = {
	base = P({
		UpperTorso = { 6, 0, 0 },
		Head = { 8, 0, 20 },
		RightUpperArm = { 0, 0, 36 },
		RightLowerArm = { 80, 0, 42 },
		RightHand = { 0, 0, 20 },
		RightUpperLeg = { 0, 0, 6 },
		RightFoot = { 0, 0, -6 },
	}),
	anim = function(v, t)
		local s = math.max(0, math.sin(t * 3)) ^ 2 * 6
		add(v, "RightUpperArm", 0, 0, s)
		add(v, "LeftUpperArm", 0, 0, -s)
	end,
}

-- Bot poses ----------------------------------------------------------------------

local BOT: { [string]: PoseDef } = {}

BOT.Hover = {
	base = P({
		RightUpperArm = { 0, 0, 10 },
		RightLowerArm = { 16, 0, 0 },
		RightUpperLeg = { 0, 0, 3 },
		RightFoot = { 0, 0, -3 },
	}),
}

-- Servo twitch: the head and forearms snap between random targets.
BOT.Twitch = {
	base = BOT.Hover.base,
	anim = function(v, t, seed)
		add(v, "Head", servo(t, 0.55, 0.07, seed, -12, 12), servo(t, 0.55, 0.07, seed + 3, -40, 40), servo(t, 0.55, 0.07, seed + 5, -8, 8))
		add(v, "RightLowerArm", servo(t, 0.8, 0.09, seed + 11, 0, 50), 0, 0)
		add(v, "LeftLowerArm", servo(t, 0.7, 0.09, seed + 13, 0, 50), 0, 0)
	end,
}

-- Head scan: a slow radar sweep, torso following a little.
BOT.Scan = {
	base = P({
		RightUpperArm = { 0, 0, 12 },
		RightLowerArm = { 20, 0, 0 },
		RightUpperLeg = { 0, 0, 5 },
		RightFoot = { 0, 0, -5 },
	}),
	anim = function(v, t)
		local s = math.sin(t * 1.25)
		add(v, "Head", 4, s * 55, 0)
		add(v, "UpperTorso", 0, math.sin(t * 1.25 - 0.5) * 14, 0)
	end,
}

-- Arm cannon aimed forward, braced by the other hand, with recoil.
BOT.Aim = {
	base = P({
		UpperTorso = { 0, 14, 0 },
		Head = { -2, -12, 0 },
		RightUpperArm = { 88, -4, 0 },
		RightLowerArm = { 0, 0, 0 },
		LeftUpperArm = { 56, -38, -8 },
		LeftLowerArm = { 58, 0, 0 },
		RightUpperLeg = { 6, 0, 8 },
		RightLowerLeg = { -8, 0, 0 },
		RightFoot = { 2, 0, -8 },
		LeftUpperLeg = { -8, 0, -8 },
		LeftFoot = { 8, 0, 8 },
	}, -0.05),
	anim = function(v, t)
		local phase = t % 1.3
		local kick = if phase < 0.35 then (1 - phase / 0.35) ^ 2 * 14 else 0
		add(v, "RightUpperArm", kick, 0, 0)
		add(v, "UpperTorso", kick * 0.25, 0, 0)
	end,
}

-- Power-up: fists down and out, chest up, vibrating with energy.
BOT.PowerUp = {
	base = P({
		UpperTorso = { 9, 0, 0 },
		Head = { 16, 0, 0 },
		RightUpperArm = { -10, 0, 30 },
		RightLowerArm = { 26, 0, -22 },
		RightHand = { 0, 0, -10 },
		RightUpperLeg = { 4, 0, 10 },
		RightLowerLeg = { -8, 0, 0 },
		RightFoot = { 4, 0, -10 },
	}, 0.12),
	anim = function(v, t)
		local j = math.sin(t * 47) * 1.4
		add(v, "UpperTorso", j, 0, j * 0.5)
		add(v, "RightUpperArm", 0, 0, j)
		add(v, "LeftUpperArm", 0, 0, -j)
		v[ROOT_Y] += math.sin(t * 3) * 0.05
	end,
}

BOT.Wave = {
	base = P({
		UpperTorso = { 0, -6, 0 },
		Head = { 0, -8, 9 },
		RightUpperArm = { 0, 0, 150 },
		RightLowerArm = { 0, 0, 22 },
		LeftUpperArm = { 0, 0, -10 },
		LeftLowerArm = { 16, 0, 0 },
		RightUpperLeg = { 0, 0, 4 },
		RightFoot = { 0, 0, -4 },
	}),
	anim = function(v, t)
		add(v, "RightLowerArm", 0, 0, math.sin(t * 8) * 26)
		add(v, "Head", 0, 0, math.sin(t * 4) * 4)
	end,
}

-- Fan poses ----------------------------------------------------------------------

local FAN: { [string]: PoseDef } = {}
local TAU = math.pi * 2

-- 0..1..0 pulse with period `period` seconds.
local function pulse(t: number, period: number, phase: number?): number
	return 0.5 - 0.5 * math.cos(TAU * t / period + (phase or 0))
end

-- A light bounce on the toes: heels lift, knees give a little at the bottom.
local function toeBounce(v: Vec, u: number, height: number)
	v[ROOT_Y] += height * u - 0.02 * (1 - u)
	add(v, "RightFoot", -10 * u, 0, 0)
	add(v, "LeftFoot", -10 * u, 0, 0)
	add(v, "RightLowerLeg", -6 * (1 - u), 0, 0)
	add(v, "LeftLowerLeg", -6 * (1 - u), 0, 0)
	add(v, "RightUpperLeg", 3 * (1 - u), 0, 0)
	add(v, "LeftUpperLeg", 3 * (1 - u), 0, 0)
end

-- Fist on the hip (left arm).
local LEFT_HIP = { LeftUpperArm = { 0, 16, -42 }, LeftLowerArm = { 16, 0, 100 }, LeftHand = { 0, 0, 18 } }

local function withLeftHip(def: { [string]: { number } }): { [string]: { number } }
	for limb, a in LEFT_HIP do
		def[limb] = a
	end
	return def
end

FAN.Idle = {
	base = P({
		RightUpperArm = { 4, 0, 8 },
		RightLowerArm = { 16, 0, 0 },
		RightUpperLeg = { 0, 0, 3 },
		RightFoot = { 0, 0, -3 },
	}),
	anim = function(v, t, seed)
		local u = pulse(t, 0.8, seed * 0.37)
		toeBounce(v, u, 0.07)
		add(v, "RightUpperArm", 0, 0, 3 * u)
		add(v, "LeftUpperArm", 0, 0, -3 * u)
		add(v, "Head", -2 * u, 0, math.sin(t * 0.9 + seed) * 3)
	end,
}

-- Both arms up in a V, little hops.
FAN.Cheer = {
	base = P({
		UpperTorso = { 4, 0, 0 },
		Head = { 10, 0, 0 },
		RightUpperArm = { 0, 8, 150 },
		RightLowerArm = { 0, 0, 12 },
		RightHand = { 0, 0, 8 },
		RightUpperLeg = { 0, 0, 4 },
		RightFoot = { 0, 0, -4 },
	}),
	anim = function(v, t, seed)
		local hop = math.abs(math.sin(math.pi * t / 0.62 + seed * 0.29))
		local land = (1 - hop) ^ 2
		v[ROOT_Y] += 0.24 * hop - 0.06 * land
		add(v, "RightUpperLeg", 9 * land, 0, 0)
		add(v, "LeftUpperLeg", 9 * land, 0, 0)
		add(v, "RightLowerLeg", -18 * land, 0, 0)
		add(v, "LeftLowerLeg", -18 * land, 0, 0)
		add(v, "RightFoot", 9 * land - 12 * hop, 0, 0)
		add(v, "LeftFoot", 9 * land - 12 * hop, 0, 0)
		add(v, "RightUpperArm", 0, 0, 10 * hop)
		add(v, "LeftUpperArm", 0, 0, -10 * hop)
		add(v, "Head", 4 * hop, 0, 0)
	end,
}

FAN.Wave = {
	base = P(withLeftHip({
		UpperTorso = { 0, -6, 0 },
		Head = { 2, -8, 8 },
		RightUpperArm = { 0, 0, 148 },
		RightLowerArm = { 0, 0, 20 },
		RightUpperLeg = { 0, 0, 4 },
		RightFoot = { 0, 0, -4 },
	})),
	anim = function(v, t, seed)
		add(v, "RightLowerArm", 0, 0, math.sin(t * 7 + seed) * 26)
		add(v, "Head", 0, 0, math.sin(t * 3.5 + seed) * 4)
		toeBounce(v, pulse(t, 0.9, seed), 0.04)
	end,
}

-- Clapping in front of the chest.
FAN.Clap = {
	base = P({
		UpperTorso = { -2, 0, 0 },
		Head = { 4, 0, 0 },
		RightUpperArm = { 52, 62, 0 },
		RightLowerArm = { 58, 0, 0 },
		RightUpperLeg = { 0, 0, 4 },
		RightFoot = { 0, 0, -4 },
	}),
	anim = function(v, t, seed)
		-- Hands meet at the bottom of a quick sine (about two claps a second).
		local open = pulse(t, 0.46, seed)
		add(v, "RightUpperArm", 0, -16 * open, 0)
		add(v, "LeftUpperArm", 0, 16 * open, 0)
		add(v, "RightLowerArm", 0, 0, 10 * open)
		add(v, "LeftLowerArm", 0, 0, -10 * open)
		toeBounce(v, pulse(t, 0.92, seed), 0.05)
	end,
}

-- Amazed: hands on the cheeks, swaying side to side.
FAN.Swoon = {
	base = P({
		UpperTorso = { 4, 0, 0 },
		Head = { 8, 0, 0 },
		RightUpperArm = { 80, 40, 50 },
		RightLowerArm = { 120, 0, 0 },
		RightUpperLeg = { 0, 0, 3 },
		RightLowerLeg = { -4, 0, 0 },
		RightFoot = { 0, 0, -3 },
	}),
	anim = function(v, t, seed)
		local s = math.sin(t * 2.1 + seed)
		add(v, "LowerTorso", 0, 0, s * 3)
		add(v, "UpperTorso", 0, 0, s * 3)
		add(v, "Head", 0, s * 3, s * 7)
		v[ROOT_Y] += 0.02 * math.abs(s)
	end,
}

-- The fan sign held high (right hand), bobbing; the other fist pumps.
FAN.SignUp = {
	base = P({
		UpperTorso = { 4, 0, 0 },
		Head = { 12, 0, 0 },
		RightUpperArm = { 0, 0, 166 },
		RightLowerArm = { 0, 0, 6 },
		LeftUpperArm = { 0, 0, -16 },
		LeftLowerArm = { 60, 0, 0 },
		RightUpperLeg = { 0, 0, 4 },
		RightFoot = { 0, 0, -4 },
	}),
	anim = function(v, t, seed)
		local u = pulse(t, 0.7, seed)
		add(v, "RightUpperArm", 0, 0, -8 * u)
		add(v, "RightLowerArm", 0, 0, 6 * u)
		add(v, "LeftUpperArm", 0, 0, -10 * u)
		add(v, "LeftLowerArm", 30 * u, 0, 0)
		toeBounce(v, u, 0.06)
	end,
}

-- Pointing at the stage with a hand on the hip.
FAN.Point = {
	base = P(withLeftHip({
		UpperTorso = { -3, 10, 0 },
		Head = { 6, -6, -5 },
		RightUpperArm = { 84, 12, 2 },
		RightLowerArm = { 6, 0, 0 },
		RightUpperLeg = { 4, 0, 6 },
		RightLowerLeg = { -6, 0, 0 },
		RightFoot = { 0, 0, -6 },
	})),
	anim = function(v, t, seed)
		local jab = math.max(0, math.sin(t * 5 + seed)) ^ 4 * 7
		add(v, "RightUpperArm", jab, 0, 0)
		toeBounce(v, pulse(t, 0.84, seed), 0.04)
	end,
}

-- A big jump: crouch, spring up with arms high and knees tucked, land.
FAN.Jump = {
	base = P({
		RightUpperArm = { 0, 0, 10 },
		RightLowerArm = { 12, 0, 0 },
		RightUpperLeg = { 0, 0, 3 },
		RightFoot = { 0, 0, -3 },
	}),
	anim = function(v, t, seed)
		local p = (t / 1.3 + seed * 0.13) % 1
		local crouch, air, h = 0, 0, 0
		if p < 0.25 then
			crouch = math.sin(math.pi * p / 0.25)
		elseif p < 0.8 then
			local q = (p - 0.25) / 0.55
			air = math.sin(math.pi * q)
			h = 4 * q * (1 - q) * 0.85
		else
			crouch = 0.8 * math.sin(math.pi * (p - 0.8) / 0.2)
		end
		v[ROOT_Y] += h - 0.26 * crouch
		for _, n in { "Right", "Left" } do
			local s = if n == "Right" then 1 else -1
			add(v, n .. "UpperLeg", 22 * crouch + 26 * air, 0, 0)
			add(v, n .. "LowerLeg", -44 * crouch - 40 * air, 0, 0)
			add(v, n .. "Foot", 22 * crouch - 10 * air, 0, 0)
			add(v, n .. "UpperArm", -30 * crouch, 0, s * 140 * air)
			add(v, n .. "LowerArm", 0, 0, s * 14 * air)
		end
		add(v, "UpperTorso", -10 * crouch + 4 * air, 0, 0)
		add(v, "Head", 6 * crouch + 8 * air, 0, 0)
	end,
}

-- Story poses (intro cutscene; playable by every set) -----------------------------

local STORY: { [string]: PoseDef } = {}

STORY.Stand = CHAD.Relaxed

-- Head down, shoulders slumped, a slow sad sway.
STORY.Sad = {
	base = P({
		UpperTorso = { -12, 0, 0 },
		Head = { -24, 0, 0 },
		RightUpperArm = { 6, 0, 3 },
		RightLowerArm = { 8, 0, 0 },
		RightUpperLeg = { 0, 0, 2 },
		RightFoot = { 0, 0, -2 },
	}, -0.02),
	anim = function(v, t)
		local s = math.sin(t * 1.1)
		add(v, "LowerTorso", 0, 0, s * 2)
		add(v, "UpperTorso", 2 * math.sin(t * 0.7), s * 2, 0)
		add(v, "Head", 0, 0, -s * 3)
	end,
}

-- Arms flung out, leaning back.
STORY.Shock = {
	base = P({
		UpperTorso = { 14, 0, 0 },
		Head = { 10, 0, 0 },
		RightUpperArm = { 10, 0, 64 },
		RightLowerArm = { 0, 0, 34 },
		RightHand = { 0, 0, 14 },
		RightUpperLeg = { -10, 0, 6 },
		RightLowerLeg = { -4, 0, 0 },
		RightFoot = { 6, 0, -6 },
		LeftUpperLeg = { 6, 0, -5 },
		LeftLowerLeg = { -8, 0, 0 },
		LeftFoot = { 0, 0, 5 },
	}, -0.04),
	anim = function(v, t)
		local s = math.sin(t * 2.6)
		add(v, "UpperTorso", 1.5 * s, 0, 0)
		add(v, "RightUpperArm", 0, 0, 3 * s)
		add(v, "LeftUpperArm", 0, 0, -3 * s)
	end,
}

-- "I've got it!": finger up beside the head, standing tall.
STORY.Idea = {
	base = P(withLeftHip({
		UpperTorso = { 5, 0, 0 },
		Head = { 10, -10, 4 },
		RightUpperArm = { 118, 0, -2 },
		RightLowerArm = { 90, 0, 0 },
		RightUpperLeg = { 0, 0, 4 },
		RightFoot = { 0, 0, -4 },
	})),
	anim = function(v, t)
		local u = pulse(t, 0.9)
		add(v, "RightLowerArm", 5 * u, 0, 0)
		v[ROOT_Y] += 0.03 * u
	end,
}

STORY.Flex = CHAD.DoubleBiceps

-- Walk / run cycles. `period` is one full cycle (two steps); `swing` the hip
-- swing in degrees. Feed them time = distance / (speed * scale) (Poses.gaitTime)
-- so the feet keep pace with a model that code is moving.
type Gait = {
	period: number,
	swing: number,
	knee: number,
	arm: number,
	elbow: number,
	lean: number,
	bounce: number,
	speed: number, -- studs per second at RigScale 1
}

local LEG = 1.95 -- hip height used for the stride / root drop (unscaled studs)

local function gaitSpeed(period: number, swing: number): number
	return 4 * LEG * math.sin(math.rad(swing)) / period
end

local GAITS: { [string]: Gait } = {
	Walk = { period = 1, swing = 24, knee = 34, arm = 20, elbow = 16, lean = 0, bounce = 1, speed = gaitSpeed(1, 24) },
	Run = { period = 0.64, swing = 38, knee = 76, arm = 42, elbow = 84, lean = -10, bounce = 0.6, speed = gaitSpeed(0.64, 38) },
	Strut = { period = 1.15, swing = 20, knee = 26, arm = 16, elbow = 12, lean = 6, bounce = 1, speed = gaitSpeed(1.15, 20) },
}

local function gaitPose(name: string, extra: { [string]: { number } }): PoseDef
	local g = GAITS[name]
	return {
		base = P(extra),
		anim = function(v, t)
			local phase = TAU * t / g.period
			local s, c = math.sin(phase), math.cos(phase)
			local hip = g.swing * s
			-- The knee bends while the leg swings forwards.
			local kneeR = -(6 + g.knee * math.max(0, c) ^ 1.5)
			local kneeL = -(6 + g.knee * math.max(0, -c) ^ 1.5)
			add(v, "RightUpperLeg", hip, 0, 0)
			add(v, "LeftUpperLeg", -hip, 0, 0)
			add(v, "RightLowerLeg", kneeR, 0, 0)
			add(v, "LeftLowerLeg", kneeL, 0, 0)
			add(v, "RightFoot", -0.35 * (hip + kneeR), 0, 0)
			add(v, "LeftFoot", -0.35 * (-hip + kneeL), 0, 0)
			add(v, "RightUpperArm", -g.arm * s, 0, 0)
			add(v, "LeftUpperArm", g.arm * s, 0, 0)
			add(v, "RightLowerArm", g.elbow + 10 * math.max(0, -s), 0, 0)
			add(v, "LeftLowerArm", g.elbow + 10 * math.max(0, s), 0, 0)
			add(v, "LowerTorso", 0, 4 * s, 0)
			add(v, "UpperTorso", g.lean, -7 * s, 0)
			add(v, "Head", -g.lean * 0.6, 3 * s, 0)
			-- Hips drop as the legs spread so the planted foot stays on the floor.
			v[ROOT_Y] += -LEG * (1 - math.cos(math.rad(hip))) * g.bounce
		end,
	}
end

STORY.Walk = gaitPose("Walk", {})
STORY.Run = gaitPose("Run", { Head = { 4, 0, 0 } })
-- Strut: chest up, chin up, arms swinging wide, a swagger in the shoulders.
STORY.Strut = (function()
	local def = gaitPose("Strut", { Head = { 6, 0, 0 }, RightUpperArm = { 0, 0, 12 } })
	local walk = def.anim :: (Vec, number, number) -> ()
	def.anim = function(v, t, seed)
		walk(v, t, seed)
		local s = math.sin(TAU * t / GAITS.Strut.period)
		add(v, "UpperTorso", 0, 0, 3 * s)
		add(v, "Head", 0, -4 * s, -2 * s)
	end
	return def
end)()

-- Gym poses for a player's own avatar at a plot's interactive props (Client.Fx.Interactive
-- blends between them itself, so they hold still).

-- Boxing guard: both fists up by the chin, leaning in a little.
STORY.PunchGuard = {
	base = P({
		UpperTorso = { -6, 0, 0 },
		Head = { 4, 0, 0 },
		RightUpperArm = { 35, 0, 14 },
		RightLowerArm = { 115, 0, 0 },
	}),
}

-- A straight right: the shoulder turned in behind the fist, the left staying on guard.
STORY.PunchRight = {
	base = P({
		UpperTorso = { -8, 28, 0 },
		Head = { 4, -24, 0 },
		RightUpperArm = { 90, 0, 24 },
		RightLowerArm = { 4, 0, 0 },
		LeftUpperArm = { 40, 0, -14 },
		LeftLowerArm = { 120, 0, 0 },
	}),
}

-- The same punch thrown with the left.
STORY.PunchLeft = {
	base = P({
		UpperTorso = { -8, -28, 0 },
		Head = { 4, 24, 0 },
		LeftUpperArm = { 90, 0, -24 },
		LeftLowerArm = { 4, 0, 0 },
		RightUpperArm = { 40, 0, 14 },
		RightLowerArm = { 120, 0, 0 },
	}),
}

-- Bench press, for a rig lying on its back (its front facing the sky): knees bent over the end
-- of the bench. Up: both arms pushed straight out in front of the chest, a little wide.
STORY.BenchUp = {
	base = P({
		RightUpperArm = { 90, 0, 25 },
		RightUpperLeg = { 0, 0, 5 },
		RightLowerLeg = { -85, 0, 0 },
	}),
}

-- Down: elbows dropped out beside the chest, forearms still pointing up, hands the same
-- width apart as in BenchUp.
STORY.BenchDown = {
	base = P({
		RightUpperArm = { 0, -20, 45 },
		RightLowerArm = { 100, 0, 0 },
		RightUpperLeg = { 0, 0, 5 },
		RightLowerLeg = { -85, 0, 0 },
	}),
}

-- Animation sets -----------------------------------------------------------------

type Set = {
	poses: { [string]: PoseDef },
	order: { string },
	rest: string,
	restEvery: number,
	hold: { number },
	restHold: { number },
	blend: number,
	ease: (number) -> number,
	overlay: (v: Vec, t: number, seed: number) -> (),
	extra: { string }?, -- poses of the set that are never in the random rotation
}

local SETS: { [string]: Set } = {
	Chad = {
		poses = CHAD,
		order = {
			"DoubleBiceps",
			"SideChest",
			"LatSpread",
			"MostMuscular",
			"HandsOnHips",
			"Mewing",
			"SmugTurn",
			"Point",
			"Victory",
			"AbsAndThigh",
			"BicepKiss",
			"Dab",
			"FingerGuns",
			"Shrug",
		},
		rest = "Relaxed",
		restEvery = 2,
		hold = { 1.6, 2.8 },
		restHold = { 1.2, 2 },
		blend = 0.6,
		ease = easeInOutCubic,
		overlay = function(v, t, seed)
			-- Breathing.
			local b = math.sin(t * 1.75 + seed)
			add(v, "UpperTorso", b * 1.6, 0, 0)
			add(v, "Head", -b * 1.1, 0, 0)
			add(v, "RightUpperArm", 0, 0, b * 1.5)
			add(v, "LeftUpperArm", 0, 0, -b * 1.5)
		end,
	},
	Bot = {
		poses = BOT,
		order = { "Twitch", "Scan", "Aim", "PowerUp", "Wave" },
		rest = "Hover",
		restEvery = 1,
		hold = { 1.8, 3 },
		restHold = { 1.2, 2.2 },
		blend = 0.32,
		ease = smooth,
		overlay = function(v, t, seed)
			-- Hover bob on the repulsors, arms drifting slightly.
			local b = math.sin(t * 2.3 + seed)
			v[ROOT_Y] += 0.07 + b * 0.06
			add(v, "RightUpperArm", 0, 0, b * 1.5)
			add(v, "LeftUpperArm", 0, 0, -b * 1.5)
			add(v, "RightLowerLeg", -2 - b * 2, 0, 0)
			add(v, "LeftLowerLeg", -2 - b * 2, 0, 0)
		end,
	},
	Fan = {
		poses = FAN,
		order = { "Cheer", "Wave", "Clap", "Swoon", "SignUp", "Point", "Jump" },
		rest = "Idle",
		restEvery = 1,
		hold = { 2.2, 3.6 },
		restHold = { 1.6, 2.6 },
		blend = 0.45,
		ease = easeInOutCubic,
		overlay = function(v, t, seed)
			-- Gentle breathing.
			local b = math.sin(t * 2 + seed)
			add(v, "UpperTorso", b * 1.2, 0, 0)
			add(v, "Head", -b * 0.8, 0, 0)
		end,
	},
	-- The intro cutscene cast. Models normally play these with
	-- Poses.samplePose / RigPose.applyPose rather than the rotation.
	Story = {
		poses = STORY,
		order = { "Sad", "Shock", "Idea", "Flex" },
		rest = "Stand",
		restEvery = 1,
		hold = { 1.6, 2.6 },
		restHold = { 1.2, 2 },
		blend = 0.5,
		ease = easeInOutCubic,
		overlay = function(v, t, seed)
			local b = math.sin(t * 1.75 + seed)
			add(v, "UpperTorso", b * 1.2, 0, 0)
			add(v, "Head", -b * 0.8, 0, 0)
		end,
		extra = { "Walk", "Run", "Strut", "PunchGuard", "PunchRight", "PunchLeft", "BenchUp", "BenchDown" },
	},
}

-- Where a pose name is looked up after the model's own set, so any rig can
-- play any pose (e.g. a Chad hero playing Story "Sad", a fan playing "Walk").
local FALLBACK: { { [string]: PoseDef } } = { STORY, FAN, CHAD, BOT }

local function findPose(set: Set, pose: string): PoseDef?
	local def = set.poses[pose]
	if def then
		return def
	end
	for _, poses in FALLBACK do
		if poses[pose] then
			return poses[pose]
		end
	end
	return nil
end

type Step = { pose: string, start: number, length: number }
type Sequence = { steps: { Step }, total: number }

local VARIANTS = 64
local sequenceCache: { [string]: Sequence } = {}

-- The looping pose sequence for a seed: the poses shuffled, a rest pose every
-- few poses, and hold lengths that vary per step.
local function sequenceFor(setName: string, set: Set, seed: number): Sequence
	local variant = math.floor(math.abs(seed)) % VARIANTS
	local key = setName .. variant
	local cached = sequenceCache[key]
	if cached then
		return cached
	end
	local order = table.clone(set.order)
	for i = #order, 2, -1 do
		local j = 1 + math.floor(hash(variant * 31 + i) * i)
		order[i], order[j] = order[j], order[i]
	end
	local steps: { Step } = {}
	local t = 0
	local function push(pose: string, range: { number })
		local hold = range[1] + (range[2] - range[1]) * hash(variant * 17 + #steps * 3.7)
		table.insert(steps, { pose = pose, start = t, length = set.blend + hold })
		t += set.blend + hold
	end
	for i, pose in order do
		push(pose, set.hold)
		if i % set.restEvery == 0 then
			push(set.rest, set.restHold)
		end
	end
	local sequence = { steps = steps, total = t }
	sequenceCache[key] = sequence
	return sequence
end

local function evalPose(out: Vec, def: PoseDef, t: number, seed: number)
	table.move(def.base, 1, SIZE, 1, out)
	if def.anim then
		def.anim(out, t, seed)
	end
end

local bufferA: Vec = table.create(SIZE, 0)
local bufferB: Vec = table.create(SIZE, 0)
local RAD = math.pi / 180

local function toTransforms(v: Vec, out: { [string]: CFrame }): { [string]: CFrame }
	for i, limb in LIMBS do
		local cf = CFrame.Angles(v[i * 3 - 2] * RAD, v[i * 3 - 1] * RAD, v[i * 3] * RAD)
		if i == 1 then
			cf = CFrame.new(0, v[ROOT_Y], 0) * cf
		end
		out[limb] = cf
	end
	return out
end

local function phaseTime(set: Set, sequence: Sequence, time: number, seed: number): number
	local _ = set
	return (time + (seed % 997) * 1.618) % sequence.total
end

local function resolveSet(animSet: string): (string, Set)
	if SETS[animSet] then
		return animSet, SETS[animSet]
	end
	return "Chad", SETS.Chad
end

-- Joint transforms for one model at `time`, written into `out` (reused to avoid
-- allocating every frame). The root offset (hover/bob) is in unscaled studs.
function Poses.sampleInto(out: { [string]: CFrame }, animSet: string, time: number, seed: number): { [string]: CFrame }
	local setName, set = resolveSet(animSet)
	local sequence = sequenceFor(setName, set, seed)
	local t = phaseTime(set, sequence, time, seed)
	local steps = sequence.steps
	local index = #steps
	for i, step in steps do
		if t < step.start + step.length then
			index = i
			break
		end
	end
	local step = steps[index]
	evalPose(bufferA, set.poses[step.pose], time, seed)
	local into = t - step.start
	if into < set.blend then
		local previous = steps[if index == 1 then #steps else index - 1]
		evalPose(bufferB, set.poses[previous.pose], time, seed)
		local w = set.ease(into / set.blend)
		for i = 1, SIZE do
			bufferA[i] = bufferB[i] + (bufferA[i] - bufferB[i]) * w
		end
	end
	set.overlay(bufferA, time, seed)
	return toTransforms(bufferA, out)
end

-- Joint transforms ({ [limb]: CFrame }) for a model of `animSet` at `time`.
function Poses.sample(animSet: string, time: number, seed: number): { [string]: CFrame }
	return Poses.sampleInto({}, animSet, time, seed)
end

-- Transforms for one named pose (no blending or overlay), written into `out`.
-- The pose is looked up in `animSet`, then in the Story, Fan, Chad and Bot
-- sets. Cyclic poses (Walk, Run, Strut, Cheer, ...) move with `time`.
function Poses.samplePoseInto(out: { [string]: CFrame }, animSet: string, pose: string, time: number, seed: number?): { [string]: CFrame }
	local _, set = resolveSet(animSet)
	local def = findPose(set, pose)
	assert(def, "unknown pose " .. pose)
	evalPose(bufferA, def, time, seed or 0)
	return toTransforms(bufferA, out)
end

-- Transforms for one named pose (no blending or overlay); for tools and tests.
function Poses.samplePose(animSet: string, pose: string, time: number?, seed: number?): { [string]: CFrame }
	return Poses.samplePoseInto({}, animSet, pose, time or 0, seed)
end

-- Transforms part way from `fromPose` to `toPose`: alpha 0 is fromPose, 1 is
-- toPose, eased with the set's blend curve. Both poses keep animating.
function Poses.blendInto(
	out: { [string]: CFrame },
	animSet: string,
	fromPose: string,
	toPose: string,
	alpha: number,
	time: number,
	seed: number?
): { [string]: CFrame }
	local _, set = resolveSet(animSet)
	local from, to = findPose(set, fromPose), findPose(set, toPose)
	assert(from, "unknown pose " .. fromPose)
	assert(to, "unknown pose " .. toPose)
	evalPose(bufferA, to, time, seed or 0)
	local w = set.ease(alpha)
	if w < 1 then
		evalPose(bufferB, from, time, seed or 0)
		for i = 1, SIZE do
			bufferA[i] = bufferB[i] + (bufferA[i] - bufferB[i]) * w
		end
	end
	return toTransforms(bufferA, out)
end

-- Gaits for code-driven movement: Walk, Run, Strut. `speed` is in studs per
-- second at RigScale 1, `period` the seconds per full cycle at that speed.
Poses.GAIT = {} :: { [string]: { speed: number, period: number } }
for name, g in GAITS do
	Poses.GAIT[name] = { speed = g.speed, period = g.period }
end

-- The pose time that matches `distance` studs travelled by a rig of `scale`,
-- so the feet stay planted: samplePose(set, gait, gaitTime(gait, d, scale)).
function Poses.gaitTime(gait: string, distance: number, scale: number?): number
	local g = GAITS[gait]
	assert(g, "unknown gait " .. gait)
	return distance / (g.speed * (scale or 1))
end

-- Every pose a set defines, including the ones never played in the rotation
-- (Story: Walk, Run, Strut and the gym poses).
function Poses.allPoseNames(animSet: string): { string }
	local _, set = resolveSet(animSet)
	local names = Poses.poseNames(animSet)
	for _, name in set.extra or {} do
		table.insert(names, name)
	end
	return names
end

-- Names of the poses in a set's rotation (the rest pose first).
function Poses.poseNames(animSet: string): { string }
	local _, set = resolveSet(animSet)
	local names = { set.rest }
	for _, name in set.order do
		table.insert(names, name)
	end
	return names
end

-- A time at which a model with `seed` is in the middle of holding `pose`
-- (used by the preview exporter to capture clean poses).
function Poses.timeFor(animSet: string, seed: number, pose: string): number?
	local setName, set = resolveSet(animSet)
	local sequence = sequenceFor(setName, set, seed)
	for _, step in sequence.steps do
		if step.pose == pose then
			local target = step.start + set.blend + (step.length - set.blend) * 0.5
			local offset = phaseTime(set, sequence, 0, seed)
			return (target - offset) % sequence.total
		end
	end
	return nil
end

-- Limb frames relative to the Root, from joint pivots (already scaled) and
-- joint transforms. `scale` scales the root's hover/bob offset.
function Poses.solve(
	pivots: { [string]: Vector3 },
	transforms: { [string]: CFrame },
	scale: number,
	out: { [string]: CFrame }?
): { [string]: CFrame }
	local frames = out or {}
	local rootTransform = transforms.LowerTorso
	local lift = rootTransform.Position * (scale - 1)
	frames.LowerTorso = CFrame.new(pivots.LowerTorso + lift) * rootTransform
	for i = 2, N do
		local limb = LIMBS[i]
		local parent = Poses.PARENT[limb]
		frames[limb] = frames[parent] * CFrame.new(pivots[limb] - pivots[parent]) * transforms[limb]
	end
	return frames
end

Poses.hash = hash

return Poses
