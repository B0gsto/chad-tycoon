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

	Animation: each animation set ("Chad" / "Bot") is a looping sequence of
	poses held for a couple of seconds with eased blends between them, plus an
	idle overlay (breathing / hovering). The sequence order and phase come from
	a per-model seed so a shelf of units never moves in sync.
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
}

local SETS: { [string]: Set } = {
	Chad = {
		poses = CHAD,
		order = { "DoubleBiceps", "SideChest", "LatSpread", "MostMuscular", "HandsOnHips", "Mewing", "SmugTurn", "Point" },
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
}

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

-- Transforms for one named pose (no blending or overlay); for tools and tests.
function Poses.samplePose(animSet: string, pose: string, time: number?, seed: number?): { [string]: CFrame }
	local _, set = resolveSet(animSet)
	local def = set.poses[pose]
	assert(def, "unknown pose " .. pose)
	evalPose(bufferA, def, time or 0, seed or 0)
	return toTransforms(bufferA, {})
end

-- Names of the poses in a set (the rest pose first).
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
