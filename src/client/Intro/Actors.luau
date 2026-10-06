--!strict
--[[
	Intro.Actors: the cutscene cast (built by CharacterFactory, posed with
	RigPose) and everything they do on screen: poses with smooth blends,
	walking / running / strutting along eased paths with the feet in step,
	turning, dumbbell curls, expressions and the fan sign flip.

	The hero is the local player's real avatar when it can be cloned and is an
	R15 rig (Intro.Avatar builds a RigPose-shaped rig for it, so everything
	below drives it like any other actor). The part-built hero is built anyway
	and kept as the fallback: it is used when the avatar is unavailable and
	swapped in if posing the avatar ever fails. Expressions are the emotions in
	Avatar.EMOTIONS: on a real avatar only its face changes (Avatar.setFace,
	or nothing when its head cannot show them); the part-built hero shows the
	nearest of its own faces (Avatar.FALLBACK).

	Actors stand on the stage floor (stage-local y = 0) at ground points
	{ x, z }; each faces a ground point (models face -Z). Cutscene calls
	cast:update(dt) every frame, after the timeline has fired its actions.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local CharacterFactory = require(Shared:WaitForChild("CharacterFactory"))
local Poses = require(Shared:WaitForChild("Poses"))
local RigPose = require(Shared:WaitForChild("RigPose"))
local Avatar = require(script.Parent:WaitForChild("Avatar"))

local Actors = {}

local SIGN_PARTS = { SignStick = true, SignCard = true, SignHeader = true }

type Move = {
	from: Vector3,
	to: Vector3,
	start: number,
	dur: number,
	gait: string,
	face: Vector3?,
	trail: boolean,
	vanish: boolean,
	lastDrop: number,
}

export type Actor = {
	name: string,
	model: Model,
	rig: any,
	scale: number,
	height: number,
	visible: boolean,
	pos: Vector3, -- stage-local ground point (y = 0)
	yaw: number,
	turnFrom: number,
	turnTo: number,
	turnStart: number,
	turnDur: number,
	basePose: string,
	baseSpeed: number,
	-- Displayed pose and the one it is blending from.
	pose: string,
	poseT0: number,
	poseRate: number,
	poseTime: number,
	fromPose: string?,
	fromTime: number,
	fromRate: number,
	blendStart: number,
	blendDur: number,
	move: Move?,
	curl: number, -- 0..1 curl weight
	curlTarget: number,
	sign: { parts: { number }, offsets: { CFrame }, pivot: CFrame, upright: boolean? }?,
	signSpin: { start: number, text: string, swapped: boolean }?,
	hand: CFrame?,
	seed: number,
	-- True while the actor is the player's real avatar; `fallback` is the
	-- part-built model it swaps to if posing the avatar fails.
	avatar: boolean,
	fallback: { model: Model, rig: any, scale: number, height: number }?,
	-- The avatar's face (nil keeps its own face) and the last expression shown.
	face: Avatar.Face?,
	expr: string?,
}

export type Cast = {
	stage: CFrame,
	parent: Instance,
	clock: number,
	actors: { [string]: Actor },
	order: { Actor },
	-- Called with a stage-local ground point while a "trail" move travels.
	onTrail: ((ground: Vector3) -> ())?,
	scratchA: { [string]: CFrame },
	scratchB: { [string]: CFrame },
	scratchOut: { [string]: CFrame },
}

local function clone(look: any): any
	local copy = table.clone(look)
	if look.acc then
		copy.acc = table.clone(look.acc)
	end
	return copy
end

-- Looks ---------------------------------------------------------------------------

-- The hero: the tier 1 look in the player's own body colours when Roblox has them.
function Actors.heroLook(theme: any, player: Player?): any
	local look = clone(theme.Tiers[1].Look)
	look.anim = "Chad"
	look.manual = true
	look.expr = "Happy"
	look.exprs = { "Happy", "Sad", "Shock", "Determined" }
	look.scale = 1
	look.avatarPlayer = player
	if player and player.UserId > 0 then
		local ok, desc = pcall(function()
			return Players:GetHumanoidDescriptionFromUserId(player.UserId)
		end)
		if ok and desc then
			local d = desc :: HumanoidDescription
			look.skin = d.HeadColor
			look.shirt = d.TorsoColor
			look.pants = d.RightLegColor
		end
	end
	return look
end

-- The #1 fan: the first fan look, holding a sign.
function Actors.fanLook(theme: any): any
	local look = clone(theme.Fans.Looks[1])
	look.manual = true
	look.prop = "FanSign"
	look.signText = theme.Intro.SignBefore
	look.expr = "Cheer"
	look.exprs = { "Cheer", "Starry", "Sad", "Shock" }
	return look
end

-- MAX GIGA CHAD: the top tier look, twice the size, with shades. His body is painted
-- (SmoothPlastic, golden tan skin) so his face and muscles read; the aura ring and the
-- sparkles carry the glow.
function Actors.rivalLook(theme: any): any
	local look = clone(theme.Tiers[#theme.Tiers].Look)
	look.anim = "Chad"
	look.manual = true
	look.scale = 2
	look.material = nil
	look.skin = Color3.fromRGB(232, 178, 110)
	look.shirt = theme.World.Cream
	look.pants = theme.World.Orange
	look.fire = nil
	look.glow = nil
	look.aura = theme.World.Sunny
	look.auraRate = 18
	local acc = look.acc or {}
	if not table.find(acc, "Shades") then
		table.insert(acc, 1, "Shades")
	end
	look.acc = acc
	return look
end

function Actors.crowdLook(theme: any, index: number): any
	local looks = theme.Fans.Looks
	local look = clone(looks[(index - 1) % #looks + 1])
	look.manual = true
	if look.prop == "FanSign" then
		look.signText = theme.Intro.SignAfter
	end
	return look
end

-- Building ------------------------------------------------------------------------

local function ground(p: { number }): Vector3
	return Vector3.new(p[1], 0, p[2])
end

local function yawTo(from: Vector3, to: Vector3, fallback: number): number
	local d = to - from
	if d.X * d.X + d.Z * d.Z < 1e-4 then
		return fallback
	end
	-- Models face -Z: yaw 0 looks toward -Z.
	return math.atan2(-d.X, -d.Z)
end

local function wrapAngle(a: number): number
	return (a + math.pi) % (2 * math.pi) - math.pi
end

-- Records the fan sign's parts so it can spin about its stick.
local function captureSign(rig: any): any
	local parts, offsets = {}, {}
	local pivot: CFrame? = nil
	for i, p in rig.parts do
		if SIGN_PARTS[p.Name] then
			table.insert(parts, i)
			table.insert(offsets, rig.offsets[i])
			if p.Name == "SignStick" then
				pivot = rig.offsets[i]
			end
		end
	end
	if #parts == 0 or not pivot then
		return nil
	end
	return { parts = parts, offsets = offsets, pivot = pivot }
end

-- Blows a fan sign up to a big readable card held up in front of the fan's
-- chest: the fist grips a short handle at the card's top edge. updateActor
-- places the sign at the hand's position with the actor's own facing (not the
-- hand's rotation), so the card stays upright and readable however the arm is
-- posed, and below the fan's name tag.
local SIGN_GROW = 1.75
local SIGN_FORWARD = 0.6
local SIGN_INWARD = 0.7

local function enlargeSign(rig: any, sign: any)
	if not sign then
		return
	end
	local stick, card, header
	for _, index in sign.parts do
		local p = rig.parts[index]
		if p.Name == "SignStick" then
			stick = p
		elseif p.Name == "SignCard" then
			card = p
		elseif p.Name == "SignHeader" then
			header = p
		end
	end
	if not (stick and card) then
		return
	end
	stick.Size = Vector3.new(stick.Size.X * 1.4, 1.5, stick.Size.Z * 1.4)
	card.Size = Vector3.new(card.Size.X * SIGN_GROW, card.Size.Y * SIGN_GROW, card.Size.Z * 1.5)
	local cardY = -0.5 - card.Size.Y / 2
	local layout = {
		[stick] = CFrame.new(0, -0.45, -SIGN_FORWARD + 0.15),
		[card] = CFrame.new(-SIGN_INWARD, cardY, -SIGN_FORWARD),
	}
	if header then
		header.Size = Vector3.new(card.Size.X + 0.04, header.Size.Y * SIGN_GROW, card.Size.Z + 0.04)
		layout[header] = CFrame.new(-SIGN_INWARD, cardY + card.Size.Y / 2 - header.Size.Y / 2, -SIGN_FORWARD)
	end
	for j, index in sign.parts do
		local offset = layout[rig.parts[index]] or sign.offsets[j]
		sign.offsets[j] = offset
		rig.offsets[index] = offset
	end
	sign.pivot = CFrame.new(-SIGN_INWARD, 0, -SIGN_FORWARD)
	sign.upright = true
end

function Actors.new(stage: CFrame, parent: Instance): Cast
	return {
		stage = stage,
		parent = parent,
		clock = 0,
		actors = {},
		order = {},
		onTrail = nil,
		scratchA = {},
		scratchB = {},
		scratchOut = {},
	}
end

-- Builds one actor at ground point `at` facing ground point `face`.
function Actors.add(cast: Cast, name: string, look: any, at: { number }, face: { number }, hidden: boolean?): Actor
	local model = CharacterFactory.build(look, name)
	local rig = RigPose.capture(model, #cast.order * 7 + 3)
	assert(rig, "intro actor without a rig: " .. name)
	local scaleValue = model:GetAttribute("RigScale")
	local heightValue = model:GetAttribute("Height")
	local scale = if type(scaleValue) == "number" then scaleValue else 1
	local height = if type(heightValue) == "number" then heightValue else 6

	-- The player's own avatar, with the part-built model kept as the fallback.
	local fallback = nil
	local player = look.avatarPlayer
	if typeof(player) == "Instance" and player:IsA("Player") then
		local hip = rig.pivots.LeftUpperLeg.Y
		local ok, built = pcall(Avatar.build, player, name, hip, rig.seed, rig.animSet)
		if ok and built then
			fallback = { model = model, rig = rig, scale = scale, height = height }
			model, rig, scale, height = built.model, built.rig, built.scale, built.height
		elseif not ok then
			warn("[Intro] avatar hero failed: " .. tostring(built))
		end
	end

	local pos = ground(at)
	local yaw = yawTo(pos, ground(face), 0)
	local rest = if model:GetAttribute("AnimSet") == "Fan" then "Idle" else "Stand"
	local actor: Actor = {
		name = name,
		model = model,
		rig = rig,
		scale = scale,
		height = height,
		visible = not hidden,
		pos = pos,
		yaw = yaw,
		turnFrom = yaw,
		turnTo = yaw,
		turnStart = 0,
		turnDur = 0,
		basePose = rest,
		baseSpeed = 1,
		pose = rest,
		poseT0 = 0,
		poseRate = 1,
		poseTime = 0,
		fromPose = nil,
		fromTime = 0,
		fromRate = 0,
		blendStart = 0,
		blendDur = 0,
		move = nil,
		curl = 0,
		curlTarget = 0,
		sign = if fallback then nil else captureSign(rig),
		signSpin = nil,
		hand = nil,
		seed = #cast.order * 13 + 5,
		avatar = fallback ~= nil,
		fallback = fallback,
		face = if fallback then Avatar.attachFace(model) else nil,
		expr = nil,
	}
	enlargeSign(rig, actor.sign)
	model.Parent = if hidden then nil else cast.parent
	cast.actors[name] = actor
	table.insert(cast.order, actor)
	return actor
end

-- Actions ---------------------------------------------------------------------------

function Actors.get(cast: Cast, name: string): Actor?
	return cast.actors[name]
end

-- Stage-local ground point of an actor.
function Actors.groundOf(actor: Actor): Vector3
	return actor.pos
end

-- Stage-local chest / head heights of an actor.
function Actors.chest(actor: Actor): Vector3
	return actor.pos + Vector3.new(0, actor.height * 0.62, 0)
end

function Actors.head(actor: Actor): Vector3
	return actor.pos + Vector3.new(0, actor.height, 0)
end

function Actors.setVisible(cast: Cast, actor: Actor, on: boolean)
	actor.visible = on
	actor.model.Parent = if on then cast.parent else nil
end

-- Switches the displayed pose with a blend (seconds).
local function switchPose(cast: Cast, actor: Actor, pose: string, rate: number, blend: number, freezeFrom: boolean?)
	if actor.pose == pose and actor.poseRate == rate then
		return
	end
	if blend > 0 then
		actor.fromPose = actor.pose
		actor.fromTime = actor.poseTime
		actor.fromRate = if freezeFrom then 0 else actor.poseRate
		actor.blendStart = cast.clock
		actor.blendDur = blend
	else
		actor.fromPose = nil
	end
	actor.pose = pose
	actor.poseT0 = cast.clock
	actor.poseRate = rate
	actor.poseTime = 0
end

-- The actor's held pose (played whenever it is not moving).
function Actors.pose(cast: Cast, actor: Actor, pose: string, blend: number?, speed: number?)
	actor.basePose = pose
	actor.baseSpeed = speed or 1
	if not actor.move then
		switchPose(cast, actor, pose, actor.baseSpeed, blend or 0.35)
	end
end

function Actors.turn(cast: Cast, actor: Actor, face: { number } | Vector3, dur: number)
	local target = if typeof(face) == "Vector3" then face else ground(face :: { number })
	local yaw = yawTo(actor.pos, target, actor.yaw)
	actor.turnFrom = actor.yaw
	actor.turnTo = actor.yaw + wrapAngle(yaw - actor.yaw)
	actor.turnStart = cast.clock
	actor.turnDur = math.max(dur, 0)
	if dur <= 0 then
		actor.yaw = actor.turnTo
	end
end

-- Walks / runs / struts to a ground point. `face` is turned to on arrival.
function Actors.move(
	cast: Cast,
	actor: Actor,
	to: { number },
	dur: number,
	gait: string,
	face: { number }?,
	trail: boolean?,
	vanish: boolean?
)
	local target = ground(to)
	actor.move = {
		from = actor.pos,
		to = target,
		start = cast.clock,
		dur = math.max(dur, 0.05),
		gait = gait,
		face = if face then ground(face) else nil,
		trail = trail == true,
		vanish = vanish == true,
		lastDrop = -math.huge,
	}
	Actors.turn(cast, actor, target, 0.22)
	switchPose(cast, actor, gait, 0, 0.2)
end

-- Jumps straight to the end of a move (preview fast-forward).
function Actors.place(cast: Cast, actor: Actor, at: { number } | Vector3, face: { number }?)
	actor.move = nil
	actor.pos = if typeof(at) == "Vector3" then at else ground(at :: { number })
	if face then
		Actors.turn(cast, actor, face, 0)
	end
	switchPose(cast, actor, actor.basePose, actor.baseSpeed, 0)
end

function Actors.curl(_cast: Cast, actor: Actor, on: boolean)
	actor.curlTarget = if on then 1 else 0
end

function Actors.expression(actor: Actor, name: string)
	actor.expr = name
	if actor.avatar then
		if actor.face then
			Avatar.setFace(actor.face, name)
		end
		return
	end
	CharacterFactory.setExpression(actor.model, Avatar.FALLBACK[name] or name)
end

-- Spins the sign once about its stick, swapping the text while it is edge-on.
function Actors.flipSign(cast: Cast, actor: Actor, text: string, instant: boolean?)
	if instant or not actor.sign then
		CharacterFactory.setSignText(actor.model, text)
		return
	end
	actor.signSpin = { start = cast.clock, text = text, swapped = false }
end

-- Frame update ----------------------------------------------------------------------

local SPIN_TIME = 0.55

local function easeInOut(u: number): number
	return u * u * (3 - 2 * u)
end

-- Distance along a move at progress u: quick ease in and out, steady between.
local function travel(u: number): number
	return 0.6 * u + 0.4 * (0.5 - math.cos(math.pi * u) * 0.5)
end

local function sample(out: { [string]: CFrame }, set: string, pose: string, time: number, seed: number)
	Poses.samplePoseInto(out, set, pose, time, seed)
end

local function updateActor(cast: Cast, actor: Actor, dt: number)
	local now = cast.clock
	local rig = actor.rig

	-- Movement.
	local move = actor.move
	if move then
		local u = math.clamp((now - move.start) / move.dur, 0, 1)
		local k = travel(u)
		actor.pos = move.from:Lerp(move.to, k)
		local distance = (move.to - move.from).Magnitude * k
		actor.poseTime = Poses.gaitTime(move.gait, distance, actor.scale)
		if move.trail and cast.onTrail and distance - move.lastDrop >= 1.3 then
			move.lastDrop = distance
			cast.onTrail(actor.pos)
		end
		if u >= 1 then
			actor.move = nil
			if move.vanish then
				Actors.setVisible(cast, actor, false)
				return
			end
			if move.face then
				Actors.turn(cast, actor, move.face, 0.35)
			end
			-- Feet stop where they are while the held pose blends back in.
			switchPose(cast, actor, actor.basePose, actor.baseSpeed, 0.3, true)
		end
	else
		actor.poseTime = (now - actor.poseT0) * actor.poseRate
	end

	-- Turning.
	if actor.turnDur > 0 then
		local u = math.clamp((now - actor.turnStart) / actor.turnDur, 0, 1)
		actor.yaw = actor.turnFrom + (actor.turnTo - actor.turnFrom) * easeInOut(u)
		if u >= 1 then
			actor.turnDur = 0
		end
	end

	-- Curl weight eases toward its target.
	actor.curl += (actor.curlTarget - actor.curl) * math.min(1, dt * 6)

	-- Root, then the pose.
	local rootCF = cast.stage * CFrame.new(actor.pos) * CFrame.Angles(0, actor.yaw, 0)
	rig.root.CFrame = rootCF

	local set = rig.animSet
	local out = cast.scratchOut
	local blendW = 1
	if actor.fromPose then
		blendW = math.clamp((now - actor.blendStart) / actor.blendDur, 0, 1)
		if blendW >= 1 then
			actor.fromPose = nil
		end
	end
	if actor.fromPose then
		local fromTime = actor.fromTime + (now - actor.blendStart) * actor.fromRate
		sample(cast.scratchA, set, actor.fromPose :: string, fromTime, actor.seed)
		sample(cast.scratchB, set, actor.pose, actor.poseTime, actor.seed)
		local w = easeInOut(blendW)
		for limb, cf in cast.scratchB do
			local a = cast.scratchA[limb]
			out[limb] = if a then a:Lerp(cf, w) else cf
		end
	else
		sample(out, set, actor.pose, actor.poseTime, actor.seed)
	end

	-- Dumbbell curls: the right forearm pumps between waist and chest height,
	-- holding near the top so the dumbbell reads at chest level.
	if actor.curl > 0.01 then
		local wave = 0.5 - math.cos(now * 3.4) * 0.5
		local lift = (0.35 + 0.65 * math.sqrt(wave)) * 125 * actor.curl
		out.RightUpperArm = out.RightUpperArm * CFrame.Angles(math.rad(24 * actor.curl), 0, math.rad(-6 * actor.curl))
		out.RightLowerArm = out.RightLowerArm * CFrame.Angles(math.rad(lift), 0, 0)
	end

	local parts, cframes = RigPose.computeFrom(rig, out)

	-- The sign spins about its stick.
	-- (An enlarged sign stays upright at the hand, facing the actor's way.)
	local spin = actor.signSpin
	local sign = actor.sign
	if sign and (spin or sign.upright) then
		local angle = 0
		if spin then
			local u = math.clamp((now - spin.start) / SPIN_TIME, 0, 1)
			angle = easeInOut(u) * math.pi * 2
			if not spin.swapped and u >= 0.25 then
				spin.swapped = true
				CharacterFactory.setSignText(actor.model, spin.text)
			end
			if u >= 1 then
				actor.signSpin = nil
			end
		end
		local pivot = sign.pivot
		local turn = pivot * CFrame.Angles(0, angle, 0) * pivot:Inverse()
		local handFrame = rootCF * rig.frames.RightHand
		if sign.upright then
			handFrame = CFrame.new(handFrame.Position) * rootCF.Rotation
		end
		for j, index in sign.parts do
			cframes[index] = handFrame * turn * sign.offsets[j]
		end
	end

	Workspace:BulkMoveTo(parts, cframes, Enum.BulkMoveMode.FireCFrameChanged)

	local hand = rig.frames.RightHand
	if hand then
		actor.hand = rootCF * hand * CFrame.new(0, -0.42 * actor.scale, -0.05)
	end
end

-- Replaces a failing avatar with the part-built hero, keeping the avatar's
-- root part (the head tag and bubbles are attached to it).
local function useFallback(cast: Cast, actor: Actor, err: any)
	local fallback = actor.fallback :: any
	warn("[Intro] avatar hero swapped for the part-built hero: " .. tostring(err))
	local root = actor.rig.root
	actor.avatar = false
	actor.fallback = nil
	actor.face = nil
	root.Parent = fallback.model
	fallback.rig.root = root
	actor.model:Destroy()
	actor.model = fallback.model
	actor.rig = fallback.rig
	actor.scale = fallback.scale
	actor.height = fallback.height
	actor.sign = captureSign(fallback.rig)
	if actor.expr then
		CharacterFactory.setExpression(actor.model, Avatar.FALLBACK[actor.expr] or actor.expr)
	end
	actor.model.Parent = if actor.visible then cast.parent else nil
end

function Actors.update(cast: Cast, dt: number)
	cast.clock += dt
	for _, actor in cast.order do
		if actor.visible then
			if actor.avatar then
				local ok, err = pcall(function()
					updateActor(cast, actor, dt)
				end)
				if not ok then
					useFallback(cast, actor, err)
					updateActor(cast, actor, 0)
				end
			else
				updateActor(cast, actor, dt)
			end
		end
	end
end

function Actors.destroy(cast: Cast)
	for _, actor in cast.order do
		actor.model:Destroy()
		if actor.fallback then
			actor.fallback.model:Destroy()
		end
	end
	table.clear(cast.actors)
	table.clear(cast.order)
end

return Actors
