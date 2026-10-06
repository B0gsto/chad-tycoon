--!strict
--[[
	Intro.Timeline: the opening cutscene as data. Cutscene.luau plays it.

	Pure data (no services, no Roblox types) so the unit tests can load it.

	Coordinates are stage-local studs: the yard floor is y = 0 with its centre at
	the origin, the backdrop is toward +Z and the camera usually sits at -Z
	looking +Z (so +X is screen LEFT). Ground points are { x, z }, camera
	points { x, y, z }. Text keys refer to Theme.Intro (captions: Lines,
	bubbles: Bubbles, signs: the top-level keys).

	Beat fields:
	  name      unique beat name
	  duration  seconds
	  camera    keys { t, shot | pos+look, fov?, ease?, cut?, space? } sorted by t;
	            the camera moves from the previous key to each key with that
	            key's ease (EASES). cut = true jumps straight to the key. shot
	            frames actors wherever they are (Intro.Framing documents its
	            fields: subjects, size, place, angle, yaw, headroom, push); pos
	            and look are fixed points. space is
	            "stage" (default), "plot" (relative to the player's character
	            on their plot: -Z is the way they face, +Y up) or "behind" (the
	            normal follow camera behind the player; pos/look unused).
	  captions  { t, key } (Theme.Intro.Lines key) or { t, hide = true }
	  actions   { t, act, ... } (ACTIONS lists each act and its fields)

	Retime a beat by editing its duration and the t values inside it; nothing
	else depends on absolute times.
]]

export type Point = { number }
export type CameraKey = {
	t: number,
	pos: Point?,
	look: Point?,
	fov: number?,
	ease: string?,
	cut: boolean?,
	space: string?,
	shot: { [string]: any }?,
}
export type Caption = { t: number, key: string?, hide: boolean? }
export type Action = { [string]: any }
export type Beat = {
	name: string,
	duration: number,
	camera: { CameraKey },
	captions: { Caption },
	actions: { Action },
}

local Timeline = {}

-- Easing names the camera keys may use.
Timeline.EASES = { "Linear", "Sine", "Quad", "QuadIn", "QuadOut", "Cubic", "Back" }

-- Every action and the fields it reads (besides t and act).
Timeline.ACTIONS = {
	show = { "actor" }, -- appear in place (optional poof = true)
	pop = { "actor", "at" }, -- appear at a spot in a puff (optional face, pose)
	pose = { "actor", "pose" }, -- optional blend (s), speed (time scale)
	curl = { "actor", "on" }, -- dumbbell curls with the right arm
	move = { "actor", "to", "dur", "gait" }, -- optional face (after arriving), trail, vanish
	turn = { "actor", "face", "dur" },
	expr = { "actor", "name" },
	sign = { "actor", "key" }, -- spins and flips the fan sign to Theme.Intro[key]
	bubble = { "actor", "key", "dur" }, -- optional thought = true
	stat = { "from", "to", "dur" }, -- the hero's aura tag counts between values
	aura = { "actor" }, -- golden aura burst
	thump = { "at" }, -- ground thump: shake, dust, sound (at = point or actor name)
	shake = { "amp", "dur" },
	dumbbell = { "state" }, -- "rattle" | "drop" | "roll" (roll: to)
	cloud = { "state" }, -- "form" | "burst" (the hero's rain cloud)
	bulb = {}, -- lightbulb pops over the hero's head
	namecard = {}, -- MAX GIGA CHAD name card slams in (on = false hides it)
	title = { "on" }, -- game title card
	flash = { "dur" }, -- white flash (covers a camera cut)
	letterbox = { "on" },
	sound = { "name" }, -- Sounds module name, optional pitch
	sweat = { "actor", "on" }, -- sweat drops flick off the actor's head
	stars = { "actor", "dur" }, -- big cartoon stars circle the actor's head
	confetti = { "at" }, -- confetti burst (at = point or actor name)
	tumbleweed = { "from", "to", "dur" }, -- a tumbleweed bounces across the yard
	marker = { "on" }, -- bouncing marker over the player's own plot
	tag = { "on" }, -- the hero's name / aura tag (switch it on a camera cut)
}

-- Footprints of the set's bulky pieces (Intro.Stage builds them here): { x, z }
-- centre, radius and height in studs. The framing test keeps them off the lens.
Timeline.SET = {
	Cabana = { at = { 11, 18 }, radius = 7, height = 7 },
	Rack = { at = { -7, 9.5 }, radius = 3.5, height = 3 },
	Bench = { at = { 11, 5 }, radius = 3, height = 2.5 },
}

-- The cast. Builds and starting spots; hidden actors appear with show / pop.
Timeline.ACTORS = {
	Hero = { at = { 3.5, 0 }, face = { 1, -10 } },
	Fan = { at = { -1, 0.6 }, face = { 3, -10 } },
	Rival = { at = { -20, 2 }, face = { 0, 1.5 }, hidden = true },
	Crowd1 = { at = { -12, -0.5 }, face = { -9, -8 }, hidden = true, look = 2 },
	Crowd2 = { at = { -4.4, 2.8 }, face = { -8, -8 }, hidden = true, look = 7 },
	Crowd3 = { at = { -11.2, 3.6 }, face = { -8, -6 }, hidden = true, look = 3 },
	Crowd4 = { at = { -13.8, 1.6 }, face = { -10, -8 }, hidden = true, look = 5 },
}

local EXIT_FACE = { -60, 3 }

-- Shots (Intro.Framing): every shot keeps its subjects' heads and feet on screen.
local DUO = { "Hero", "Fan" }
local GYM_WIDE = { subjects = DUO, size = "full", angle = "low", yaw = -8, headroom = 2.2 }
local GYM_TIGHT = { subjects = DUO, size = "medium", angle = "low", yaw = -8, headroom = 2.2 }
local WALK_IN = { subjects = { "Rival", "Hero", "Fan" }, size = "wide", angle = "low", yaw = -12 }
-- Ground level, tilted up, from the yard's open front: the rival towers in the
-- right third, the hero small at the left (clear of the dropped dumbbell), the
-- name card in the upper left.
local GIANT = { subjects = { "Rival", "Hero" }, size = "full", angle = "ground", yaw = -25, focus = "Rival", place = "right" }
local GIANT_IN = { subjects = { "Rival", "Hero" }, size = "medium", angle = "ground", yaw = -25, focus = "Rival", place = "right" }
local TRIO = { subjects = { "Rival", "Fan", "Hero" }, size = "full", angle = "eye", yaw = -10 }
local TRIO_IN = { subjects = { "Rival", "Fan", "Hero" }, size = "medium", angle = "eye", yaw = -10 }
local EXODUS = {
	subjects = { "Rival", "Fan", "Crowd1", "Crowd2", "Crowd3", "Crowd4" },
	size = "full",
	angle = "eye",
	yaw = -15,
}
-- The fan and her sign as it flips to TEAM GIGA (the hero beside her).
local FLIP = { subjects = { "Fan", "Hero" }, size = "medium", angle = "eye", yaw = -10, focus = "Fan", place = "right" }
-- The hero's face as the crowd leaves, then a pull back to the empty yard.
local REACT = { subjects = { "Hero" }, size = "medium", place = "center", angle = "eye", yaw = -40 }
local ALONE = { subjects = { "Hero" }, size = "wide", place = "right", angle = "eye", yaw = -40 }
-- The hero in the lower left third, headroom for the cloud, the empty yard behind.
local SAD = { subjects = { "Hero" }, size = "medium", place = "left", angle = "high", yaw = -30, headroom = 4 }
local SAD_START = { subjects = { "Hero" }, size = "medium", place = "left", angle = "high", yaw = -30, headroom = 4, push = 1.25 }
local NOTICE = { subjects = { "Hero" }, size = "full", place = "right", angle = "eye", yaw = -60, push = 1.4 }
local IDEA = { subjects = { "Hero" }, size = "medium", place = "left", angle = "low", yaw = -30, headroom = 6.5, lift = 0.08 }
local IDEA_IN = { subjects = { "Hero" }, size = "medium", place = "left", angle = "low", yaw = -30, headroom = 6.5, lift = 0.08, fov = 34 }

Timeline.BEATS = {
	-- 1. A sunny little gym yard: the hero curls a big candy dumbbell, his #1 fan cheers.
	{
		name = "Gym",
		duration = 4.2,
		camera = {
			{ t = 0, shot = GYM_WIDE, cut = true },
			{ t = 4.2, shot = GYM_TIGHT, ease = "Sine" },
		},
		captions = {
			{ t = 0.1, key = "Meet" },
			{ t = 2.4, key = "Good" },
		},
		actions = {
			{ t = 0, act = "curl", actor = "Hero", on = true },
			{ t = 0, act = "sweat", actor = "Hero", on = true },
			{ t = 0, act = "expr", actor = "Hero", name = "Proud" },
			{ t = 2.4, act = "expr", actor = "Hero", name = "Happy" },
			{ t = 0, act = "pose", actor = "Fan", pose = "SignUp" },
			{ t = 1.4, act = "pose", actor = "Fan", pose = "Cheer", blend = 0.4 },
			{ t = 1.6, act = "bubble", actor = "Fan", key = "Stars", dur = 1.6 },
		},
	},
	-- 2. Thump, thump: MAX GIGA CHAD strides in and flexes in slow motion.
	{
		name = "Arrive",
		duration = 5.2,
		camera = {
			{ t = 0, shot = GYM_TIGHT },
			{ t = 0.9, shot = GYM_WIDE, ease = "Quad" },
			{ t = 1.6, shot = WALK_IN, ease = "Quad" },
			{ t = 2.9, shot = WALK_IN },
			{ t = 2.95, shot = GIANT, cut = true },
			{ t = 5.2, shot = GIANT_IN, ease = "Sine" },
		},
		captions = {
			{ t = 0.1, key = "Arrive" },
		},
		actions = {
			{ t = 0, act = "thump", at = { 1.8, 1.5 } },
			{ t = 0.05, act = "dumbbell", state = "rattle" },
			{ t = 0.15, act = "expr", actor = "Hero", name = "Shock" },
			{ t = 0.2, act = "pose", actor = "Fan", pose = "Shock", blend = 0.2 },
			{ t = 0.6, act = "sweat", actor = "Hero", on = false },
			{ t = 0.75, act = "thump", at = { -2, 1 } },
			{ t = 0.75, act = "curl", actor = "Hero", on = false },
			{ t = 0.75, act = "pose", actor = "Hero", pose = "Shock", blend = 0.2 },
			{ t = 0.8, act = "dumbbell", state = "drop" },
			{ t = 1, act = "show", actor = "Rival" },
			{ t = 1, act = "move", actor = "Rival", to = { -8, 1.5 }, dur = 2, gait = "Strut", face = { -5, -10 }, trail = true },
			{ t = 1.5, act = "thump", at = "Rival" },
			{ t = 1.6, act = "turn", actor = "Hero", face = { -8, 1.5 }, dur = 0.5 },
			{ t = 1.7, act = "turn", actor = "Fan", face = { -8, 1.5 }, dur = 0.5 },
			{ t = 2.25, act = "thump", at = "Rival" },
			{ t = 2.95, act = "thump", at = "Rival" },
			{ t = 2.95, act = "tag", on = false },
			{ t = 3, act = "pose", actor = "Rival", pose = "Flex", blend = 1, speed = 0.35 },
			{ t = 3.05, act = "aura", actor = "Rival" },
			{ t = 3.1, act = "namecard" },
			{ t = 3.1, act = "sound", name = "SurgeStart" },
			{ t = 5.15, act = "namecard", on = false },
		},
	},
	-- 3. Starry eyes, the sign flips to TEAM GIGA, and the fans leave with him.
	{
		name = "Wow",
		duration = 5,
		camera = {
			{ t = 0, shot = TRIO, cut = true },
			{ t = 0.55, shot = TRIO_IN, ease = "Sine" },
			{ t = 0.6, shot = FLIP, cut = true },
			{ t = 1.45, shot = FLIP },
			{ t = 1.5, shot = EXODUS, cut = true },
			{ t = 4.3, shot = EXODUS },
			{ t = 4.3, shot = REACT, cut = true },
			{ t = 5, shot = ALONE, ease = "Sine" },
		},
		captions = {
			{ t = 0.1, key = "Wow" },
			{ t = 2.6, key = "Leave" },
		},
		actions = {
			{ t = 0, act = "tag", on = true },
			{ t = 0, act = "pose", actor = "Rival", pose = "MostMuscular", blend = 0.6 },
			{ t = 0, act = "turn", actor = "Fan", face = { -4, -10 }, dur = 0.3 },
			{ t = 0, act = "turn", actor = "Hero", face = { 0, -10 }, dur = 0.4 },
			{ t = 0, act = "expr", actor = "Hero", name = "Awe" },
			{ t = 0, act = "expr", actor = "Fan", name = "Starry" },
			{ t = 0, act = "pose", actor = "Fan", pose = "Swoon", blend = 0.3 },
			{ t = 0.05, act = "stars", actor = "Fan", dur = 1.8 },
			{ t = 0.05, act = "bubble", actor = "Fan", key = "Wow", dur = 1.3 },
			{ t = 0.05, act = "sound", name = "Pickup" },
			{ t = 0.75, act = "sign", actor = "Fan", key = "SignAfter" },
			{ t = 1.5, act = "tag", on = false },
			{ t = 1.5, act = "move", actor = "Fan", to = { -4.8, -0.8 }, dur = 0.85, gait = "Run", face = { -7, -6 } },
			{ t = 1.6, act = "pop", actor = "Crowd1", at = { -12, -0.5 }, face = { -9, -8 }, pose = "Cheer" },
			{ t = 1.75, act = "pop", actor = "Crowd2", at = { -4.4, 2.8 }, face = { -8, -8 }, pose = "Jump" },
			{ t = 1.9, act = "pop", actor = "Crowd3", at = { -11.2, 3.6 }, face = { -8, -6 }, pose = "SignUp" },
			{ t = 2.05, act = "pop", actor = "Crowd4", at = { -13.8, 1.6 }, face = { -10, -8 }, pose = "Clap" },
			{ t = 2.1, act = "bubble", actor = "Crowd1", key = "Giga", dur = 1.2 },
			{ t = 2.35, act = "pose", actor = "Fan", pose = "Cheer", blend = 0.3 },
			{ t = 2.4, act = "bubble", actor = "Crowd2", key = "Cool", dur = 1.2 },
			{ t = 2.5, act = "pose", actor = "Rival", pose = "HandsOnHips", blend = 0.4 },
			{
				t = 2.9,
				act = "move",
				actor = "Rival",
				to = { -38, 3 },
				dur = 3.4,
				gait = "Strut",
				face = EXIT_FACE,
				trail = true,
				vanish = true,
			},
			{ t = 3.05, act = "move", actor = "Crowd4", to = { -42, 2 }, dur = 3.2, gait = "Walk", face = EXIT_FACE, vanish = true },
			{ t = 3.15, act = "move", actor = "Crowd1", to = { -40, 0 }, dur = 3.4, gait = "Walk", face = EXIT_FACE, vanish = true },
			{ t = 3.2, act = "move", actor = "Crowd3", to = { -41, 4.5 }, dur = 3.3, gait = "Walk", face = EXIT_FACE, vanish = true },
			{ t = 3.3, act = "bubble", actor = "Crowd3", key = "Stars", dur = 1.2 },
			{ t = 3.35, act = "move", actor = "Fan", to = { -38, -0.5 }, dur = 3.4, gait = "Run", face = EXIT_FACE, vanish = true },
			{ t = 3.4, act = "move", actor = "Crowd2", to = { -40, 3 }, dur = 3.6, gait = "Walk", face = EXIT_FACE, vanish = true },
			{ t = 3.4, act = "expr", actor = "Hero", name = "Sad" },
			{ t = 4.3, act = "tag", on = true },
		},
	},
	-- 4. Alone in an empty yard: a rain cloud, the aura tag counts down to 0, a
	-- tumbleweed rolls by. Silly, not upsetting.
	{
		name = "Sad",
		duration = 4.2,
		camera = {
			{ t = 0, shot = SAD_START, cut = true },
			{ t = 4.2, shot = SAD, ease = "Sine" },
		},
		captions = {
			{ t = 0.1, key = "Sad" },
		},
		actions = {
			{ t = 0, act = "turn", actor = "Hero", face = { 6, -10 }, dur = 0.6 },
			{ t = 0, act = "pose", actor = "Hero", pose = "Sad", blend = 0.8 },
			{ t = 0, act = "expr", actor = "Hero", name = "Sad" },
			{ t = 0.1, act = "sound", name = "Close", pitch = 0.7 },
			{ t = 0.4, act = "cloud", state = "form" },
			{ t = 0.8, act = "stat", from = 12, to = 0, dur = 2 },
			{ t = 1, act = "tumbleweed", from = { -16, 3 }, to = { 0, 1.5 }, dur = 3 },
			{ t = 1.4, act = "dumbbell", state = "roll", to = { 0.5, -1.5 } },
			{ t = 2.6, act = "bubble", actor = "Hero", key = "Dots", dur = 1.5, thought = true },
		},
	},
	-- 5. The idea: the aura trail, a lightbulb, the cloud bursts, he pumps his fist.
	{
		name = "Idea",
		duration = 5,
		camera = {
			{ t = 0, shot = NOTICE, cut = true },
			{ t = 1.45, shot = NOTICE, ease = "Sine" },
			{ t = 1.5, shot = IDEA, cut = true },
			{ t = 5, shot = IDEA_IN, ease = "Sine" },
		},
		captions = {
			{ t = 0.1, key = "Idea1" },
			{ t = 1.6, key = "Idea2" },
			{ t = 3.3, key = "Plan" },
		},
		actions = {
			{ t = 0, act = "turn", actor = "Hero", face = { -10, 1 }, dur = 0.7 },
			{ t = 0.6, act = "bubble", actor = "Hero", key = "Huh", dur = 0.85, thought = true },
			{ t = 1.5, act = "turn", actor = "Hero", face = { 6, -10 }, dur = 0.25 },
			{ t = 1.5, act = "expr", actor = "Hero", name = "Idea" },
			{ t = 1.5, act = "pose", actor = "Hero", pose = "Idea", blend = 0.25 },
			{ t = 1.55, act = "bulb" },
			{ t = 2.2, act = "cloud", state = "burst" },
			{ t = 2.3, act = "expr", actor = "Hero", name = "Fury" },
			{ t = 2.3, act = "pose", actor = "Hero", pose = "Cheer", blend = 0.25 },
			{ t = 2.35, act = "confetti", at = "Hero" },
			{ t = 2.7, act = "stat", from = 0, to = 1, dur = 0.3 },
			{ t = 3.9, act = "pose", actor = "Hero", pose = "Flex", blend = 0.35 },
		},
	},
	-- 6. Up and over to the player's real plot: a low, straight view, the title card
	-- and a bouncing marker on the plot, then gameplay.
	{
		name = "Go",
		duration = 5.4,
		camera = {
			{ t = 0, shot = IDEA_IN },
			{ t = 1.1, pos = { 3, 30, -24 }, look = { 3, 60, 30 }, fov = 55, ease = "QuadIn" },
			-- Plot space: the spawn point facing the pen; the entrance arch and owner
			-- sign are ~19 studs behind it, so the camera stays inside them.
			{ t = 1.15, pos = { 0, 30, 12 }, look = { 0, 2, -22 }, fov = 50, cut = true, space = "plot" },
			{ t = 3.6, pos = { 0, 16, 12 }, look = { 0, 3, -12 }, fov = 58, ease = "Sine", space = "plot" },
			{ t = 5.4, fov = 70, ease = "Cubic", space = "behind" },
		},
		captions = {
			{ t = 1.3, key = "Go" },
			{ t = 4.5, hide = true },
		},
		actions = {
			{ t = 0, act = "expr", actor = "Hero", name = "Smirk" },
			{ t = 0.1, act = "sound", name = "Open" },
			{ t = 0.75, act = "flash", dur = 0.8 },
			{ t = 1.2, act = "marker", on = true },
			{ t = 1.3, act = "title", on = true },
			{ t = 1.3, act = "sound", name = "Celebrate" },
			{ t = 1.3, act = "expr", actor = "Hero", name = "Happy" },
			{ t = 4.3, act = "title", on = false },
			{ t = 4.6, act = "marker", on = false },
			{ t = 4.6, act = "letterbox", on = false },
		},
	},
} :: { Beat }

-- Total running time in seconds.
function Timeline.total(): number
	local sum = 0
	for _, beat in Timeline.BEATS do
		sum += beat.duration
	end
	return sum
end

-- Start time of beat `index` (seconds from the start of the cutscene).
function Timeline.startOf(index: number): number
	local sum = 0
	for i = 1, index - 1 do
		sum += Timeline.BEATS[i].duration
	end
	return sum
end

return Timeline
