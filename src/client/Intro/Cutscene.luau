--[[
	Intro.Cutscene: plays the opening story (Intro.Timeline) once for new
	players, and again whenever Cutscene.play is called (e.g. a "Watch intro"
	button).

	While it plays: the player's "IntroPlaying" attribute is true (the tutorial
	and guide hide on it), the HUD and the Roblox player list are hidden, the
	character's controls are off and the camera is Scriptable. Finishing or
	skipping (button, Esc, gamepad B) puts all of that back. Any error, or the
	45 s watchdog, ends it the same way, so it can never lock the player in.

	  Cutscene.play(opts?) -> boolean   false if one is already playing
	    opts.delay      seconds to hold the first shot before the story starts
	                    (the loading screen fades out over it)
	    opts.startBeat  beat index to start from (earlier beats fast-forward)
	    opts.pauseAt    freeze the story this many seconds into startBeat
	    opts.onDone     fn(skipped) after everything is restored
	  Cutscene.preview(beatIndex, pauseAt?)  play from a beat (review tool)
	  Cutscene.skip()                        end it now
	  Cutscene.isPlaying() -> boolean
]]

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local StarterGui = game:GetService("StarterGui")
local Workspace = game:GetService("Workspace")

local Theme = require(ReplicatedStorage:WaitForChild("Theme")) :: any

local Intro = script.Parent
local Actors = require(Intro.Actors)
local Effects = require(Intro.Effects)
local Framing = require(Intro.Framing)
local Stage = require(Intro.Stage)
local Timeline = require(Intro.Timeline)
local Ui = require(Intro.Ui)
local Sounds = require(Intro.Parent.Sounds)
local FxCamera = require(Intro.Parent.Fx.Camera)

local Cutscene = {}

local WATCHDOG = 45
local SKIP_AFTER = 1
local BIND_NAME = "IntroCutscene"
local DEFAULT_FOV = 70
-- Matches Fx.Camera's spawn framing, so the hand-off to the follow camera is seamless.
local BEHIND_DISTANCE = 13
local BEHIND_HEIGHT = 5.5

export type Options = {
	delay: number?,
	startBeat: number?,
	pauseAt: number?,
	onDone: ((skipped: boolean) -> ())?,
}

type Session = {
	opts: Options,
	ended: boolean,
	started: number,
	clock: number, -- seconds into the current beat
	preroll: number,
	beat: number,
	fired: { [any]: boolean },
	pausedAt: number?,
	skipShown: boolean,
	stage: Stage.Stage?,
	fx: Effects.Effects?,
	cast: Actors.Cast?,
	ui: Ui.Ui?,
	plotFrame: CFrame?,
	fov: number,
	shakeAmp: number,
	shakeUntil: number,
	shakeLen: number,
	hidden: { ScreenGui },
	playerList: boolean?,
	cameraType: Enum.CameraType?,
	cameraFov: number?,
	controls: any,
	camSmooth: CFrame?,
	camKey: Timeline.CameraKey?,
}

local active: Session? = nil

-- Easing ---------------------------------------------------------------------------------

local EASE: { [string]: (number) -> number } = {
	Linear = function(u)
		return u
	end,
	Sine = function(u)
		return 0.5 - math.cos(math.pi * u) * 0.5
	end,
	Quad = function(u)
		return if u < 0.5 then 2 * u * u else 1 - (-2 * u + 2) ^ 2 / 2
	end,
	QuadIn = function(u)
		return u * u
	end,
	QuadOut = function(u)
		return 1 - (1 - u) * (1 - u)
	end,
	Cubic = function(u)
		return if u < 0.5 then 4 * u * u * u else 1 - (-2 * u + 2) ^ 3 / 2
	end,
	Back = function(u)
		local s = 1.4
		local k = u - 1
		return 1 + (s + 1) * k * k * k + s * k * k
	end,
}

-- Helpers ---------------------------------------------------------------------------------

local function characterRoot(): BasePart?
	local character = Players.LocalPlayer and Players.LocalPlayer.Character
	if not character then
		return nil
	end
	local root = character:FindFirstChild("HumanoidRootPart") or character.PrimaryPart
	return if root and root:IsA("BasePart") then root else nil
end

local function flatLook(root: BasePart): Vector3
	local look = root.CFrame.LookVector
	local flat = Vector3.new(look.X, 0, look.Z)
	return if flat.Magnitude > 1e-3 then flat.Unit else Vector3.new(0, 0, -1)
end

-- The normal follow-camera shot behind the character (eye, look-at).
local function behindShot(): (Vector3?, Vector3?)
	local root = characterRoot()
	if not root then
		return nil, nil
	end
	-- The gameplay camera's own spawn framing (Fx.Camera), so the hand-off is seamless.
	local eye, focus = FxCamera.spawnShot(root)
	if eye and focus then
		return eye, focus
	end
	local flat = flatLook(root)
	local head = root.Position + Vector3.new(0, 1.5, 0)
	return head - flat * BEHIND_DISTANCE + Vector3.new(0, BEHIND_HEIGHT, 0), head + flat * 6
end

local function vec(p: { number }?): Vector3
	if not p then
		return Vector3.zero
	end
	return Vector3.new(p[1], p[2], p[3])
end

local function playerControls(): any
	local ok, controls = pcall(function()
		local scripts = Players.LocalPlayer:WaitForChild("PlayerScripts", 5)
		local module = scripts and scripts:WaitForChild("PlayerModule", 5)
		if module and module:IsA("ModuleScript") then
			return (require(module) :: any):GetControls()
		end
		return nil
	end)
	return if ok then controls else nil
end

-- Camera ----------------------------------------------------------------------------------

-- Aspect ratio of the real viewport.
local function viewAspect(): number
	local camera = Workspace.CurrentCamera
	local size = if camera then camera.ViewportSize else Vector2.new(16, 9)
	return if size.Y > 1 then size.X / size.Y else 16 / 9
end

-- Stage-local subjects of a shot: each listed, visible actor's feet and real height.
local function shotSubjects(s: Session, shot: Framing.Shot): { Framing.Subject }
	local out = {}
	local cast = s.cast
	if not cast then
		return out
	end
	for _, name in shot.subjects do
		local actor = Actors.get(cast, name)
		if actor and actor.visible then
			local p = actor.pos
			table.insert(out, {
				feet = { p.X, p.Y, p.Z },
				height = actor.height,
				radius = 0.35 * actor.height,
				name = name,
			})
		end
	end
	return out
end

-- World eye, look-at and field of view of a camera key (nil when its space is
-- unavailable). Shot keys are solved from their subjects' current positions.
local function keyPoints(s: Session, key: Timeline.CameraKey): (Vector3?, Vector3?, number?)
	local space = key.space or "stage"
	if space == "behind" then
		local eye, look = behindShot()
		return eye, look, nil
	elseif space == "plot" then
		if not s.plotFrame then
			local root = characterRoot()
			if not root then
				return nil, nil, nil
			end
			s.plotFrame = CFrame.lookAt(root.Position, root.Position + flatLook(root))
		end
		local frame = s.plotFrame :: CFrame
		return frame * vec(key.pos), frame * vec(key.look), nil
	end
	local stage = s.stage
	if not stage then
		return nil, nil, nil
	end
	local shot = key.shot :: Framing.Shot?
	if shot then
		local subjects = shotSubjects(s, shot)
		if #subjects > 0 then
			local eye, look, fov = Framing.solve(subjects, shot, viewAspect())
			return stage.cframe * vec(eye), stage.cframe * vec(look), fov
		end
	end
	return stage.cframe * vec(key.pos), stage.cframe * vec(key.look), nil
end

-- Field of view of every key (inherited from the previous key when unset).
local fovCache: { [Timeline.CameraKey]: number } = {}
local function resolveFovs()
	local fov = DEFAULT_FOV
	for _, beat in Timeline.BEATS do
		for _, key in beat.camera do
			local shot = key.shot :: Framing.Shot?
			fov = key.fov or (if shot then shot.fov or Framing.LENS[shot.size or "full"] else nil) or fov
			fovCache[key] = fov
		end
	end
end
resolveFovs()

-- Camera of a beat at time t, and the key it is on (moves between keys with the
-- next key's ease; shot keys re-solve every frame so they follow their actors).
local function cameraAt(s: Session, beat: Timeline.Beat, t: number): (CFrame?, number, Timeline.CameraKey)
	local keys = beat.camera
	local prev, nextKey = keys[1], nil
	for i, key in keys do
		if key.t <= t then
			prev = key
			nextKey = keys[i + 1]
		end
	end
	local pos, look, solved = keyPoints(s, prev)
	local fov = solved or fovCache[prev] or DEFAULT_FOV
	if nextKey and not nextKey.cut and pos and look then
		local pos2, look2, solved2 = keyPoints(s, nextKey)
		if pos2 and look2 then
			local u = math.clamp((t - prev.t) / math.max(nextKey.t - prev.t, 1e-3), 0, 1)
			local w = (EASE[nextKey.ease or "Sine"] or EASE.Sine)(u)
			pos = pos:Lerp(pos2, w)
			look = look:Lerp(look2, w)
			fov += ((solved2 or fovCache[nextKey] or fov) - fov) * w
		end
	end
	if not pos or not look then
		return nil, fov, prev
	end
	return CFrame.lookAt(pos, look), fov, prev
end

-- Restore ---------------------------------------------------------------------------------

local function try(label: string, fn: () -> ())
	local ok, err = pcall(fn)
	if not ok then
		warn("[Intro] " .. label .. ": " .. tostring(err))
	end
end

local function teardown(s: Session, skipped: boolean)
	RunService:UnbindFromRenderStep(BIND_NAME)
	try("input", function()
		ContextActionService:UnbindAction(BIND_NAME)
	end)
	try("camera", function()
		local camera = Workspace.CurrentCamera
		if camera then
			local eye, look = behindShot()
			if eye and look then
				camera.CFrame = CFrame.lookAt(eye, look)
			end
			camera.FieldOfView = s.cameraFov or DEFAULT_FOV
			-- Before the character spawns the camera is still Fixed; hand back the
			-- normal follow camera in that case.
			camera.CameraType = if s.cameraType == nil or s.cameraType == Enum.CameraType.Fixed
				then Enum.CameraType.Custom
				else s.cameraType
			local humanoid = Players.LocalPlayer.Character and Players.LocalPlayer.Character:FindFirstChildOfClass("Humanoid")
			if humanoid then
				camera.CameraSubject = humanoid
			end
		end
	end)
	try("controls", function()
		if s.controls then
			s.controls:Enable()
		end
	end)
	try("hud", function()
		for _, gui in s.hidden do
			gui.Enabled = true
		end
		if s.playerList ~= nil then
			StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.PlayerList, s.playerList)
		end
	end)
	try("stage", function()
		if s.cast then
			Actors.destroy(s.cast)
		end
		if s.fx then
			s.fx:destroy()
		end
		if s.stage then
			s.stage.destroy()
		end
	end)
	local ui = s.ui
	if ui then
		try("ui", function()
			ui:letterbox(false)
			ui:hideCaption()
			ui:fade(false, 0.35)
			task.delay(0.5, function()
				ui:destroy()
			end)
		end)
	end
	try("attribute", function()
		Players.LocalPlayer:SetAttribute("IntroPlaying", false)
	end)
	if active == s then
		active = nil
	end
	local onDone = s.opts.onDone
	if onDone then
		try("onDone", function()
			onDone(skipped)
		end)
	end
end

local function finish(s: Session, skipped: boolean)
	if s.ended then
		return
	end
	s.ended = true
	RunService:UnbindFromRenderStep(BIND_NAME)
	if skipped and s.ui then
		-- Cover the cut back to the plot with a quick soft fade.
		local ui = s.ui :: Ui.Ui
		try("fade", function()
			ui:fade(true, 0.22)
		end)
		task.delay(0.24, function()
			teardown(s, true)
		end)
	else
		teardown(s, skipped)
	end
end

-- Actions ---------------------------------------------------------------------------------

local function shake(s: Session, amp: number, dur: number)
	s.shakeAmp = math.max(s.shakeAmp * math.max(s.shakeUntil - os.clock(), 0) / math.max(s.shakeLen, 1e-3), amp)
	s.shakeUntil = os.clock() + dur
	s.shakeLen = dur
end

local function sound(name: string, pitch: number?)
	Sounds.playCutscene(name, 0.04, pitch)
end

local function run(s: Session, a: Timeline.Action, instant: boolean)
	local cast = s.cast :: Actors.Cast
	local fx = s.fx :: Effects.Effects
	local ui = s.ui :: Ui.Ui
	local stage = s.stage :: Stage.Stage
	local intro = Theme.Intro
	local act = a.act
	local actor = if type(a.actor) == "string" then Actors.get(cast, a.actor) else nil
	local hero = Actors.get(cast, "Hero")
	local function world(p: Vector3): Vector3
		return stage.cframe * p
	end
	-- Stage-local ground point from a { x, z } field (nil when malformed).
	local function point(v: any): Vector3?
		if type(v) == "table" and type(v[1]) == "number" and type(v[2]) == "number" then
			return Vector3.new(v[1], 0, v[2])
		end
		return nil
	end
	-- World point `up` studs above an actor's real head (re-read every frame).
	local function above(who: Actors.Actor, offset: Vector3): () -> Vector3
		return function()
			return world(Actors.head(who) + offset)
		end
	end

	if act == "show" and actor then
		Actors.setVisible(cast, actor, true)
		if a.poof and not instant then
			fx:poof(world(actor.pos), actor.height)
		end
	elseif act == "pop" and actor then
		Actors.place(cast, actor, a.at, a.face)
		if a.pose then
			Actors.pose(cast, actor, a.pose, 0)
		end
		Actors.setVisible(cast, actor, true)
		if not instant then
			fx:poof(world(actor.pos), actor.height)
			sound("BuyPop")
		end
	elseif act == "pose" and actor then
		Actors.pose(cast, actor, a.pose, if instant then 0 else a.blend, a.speed)
	elseif act == "curl" and actor then
		Actors.curl(cast, actor, a.on == true)
	elseif act == "move" and actor then
		if instant then
			local from = actor.pos
			local to = Vector3.new(a.to[1], 0, a.to[2])
			if a.trail then
				local length = (to - from).Magnitude
				for d = 0, length, 1.3 do
					fx:trailDrop(world(from:Lerp(to, d / math.max(length, 1e-3))))
				end
			end
			Actors.place(cast, actor, to, a.face)
			if a.vanish then
				Actors.setVisible(cast, actor, false)
			end
		else
			Actors.move(cast, actor, a.to, a.dur, a.gait, a.face, a.trail, a.vanish)
		end
	elseif act == "turn" and actor then
		Actors.turn(cast, actor, a.face, if instant then 0 else a.dur)
	elseif act == "expr" and actor then
		Actors.expression(actor, a.name)
	elseif act == "sign" and actor then
		Actors.flipSign(cast, actor, intro[a.key] or "", instant)
		if not instant then
			sound("Toggle")
		end
	elseif act == "bubble" and actor and not instant then
		local text = intro.Bubbles[a.key] or a.key
		-- The hero's bubbles sit beside his head, clear of his tag and rain cloud.
		local offset = if actor == hero then Vector3.new(2.3, actor.height - 0.3, 0) else Vector3.new(0, actor.height + 1.8, 0)
		ui:bubble(actor.rig.root, offset, text, a.dur or 1.2, a.thought)
		sound("Pickup", 1.1)
	elseif act == "stat" then
		if instant then
			ui:countStat(a.to, a.to, 0)
		else
			ui:countStat(a.from, a.to, a.dur)
		end
	elseif act == "aura" and actor then
		local key = "halo:" .. actor.name
		if a.on == false then
			fx:stopProp(key, instant)
		else
			if not instant then
				fx:aura(world(Actors.chest(actor)), world(actor.pos), actor.scale)
				sound("Upgrade")
			end
			local who = actor
			fx:halo(key, function()
				return world(Actors.chest(who))
			end, math.max(who.height * 0.48, 2.4), if type(a.dur) == "number" then a.dur else 5.5, instant)
		end
	elseif act == "thump" and not instant then
		local at: Vector3
		if type(a.at) == "string" then
			local target = Actors.get(cast, a.at)
			at = if target then target.pos else Vector3.zero
		else
			at = Vector3.new(a.at[1], 0, a.at[2])
		end
		fx:dust(world(at), 10, 3.2)
		fx:ring(world(at), 5.5)
		shake(s, 0.35, 0.35)
		sound("MergeBoom", 0.6)
	elseif act == "shake" and not instant then
		shake(s, a.amp, a.dur)
	elseif act == "dumbbell" then
		if a.state == "rattle" and not instant then
			fx:dumbbellRattle(0.7)
		elseif a.state == "drop" then
			fx:dumbbellDrop(instant)
		elseif a.state == "roll" then
			local to = a.to or { 0, 0 }
			fx:dumbbellRoll(Vector3.new(to[1], 0, to[2]), a.dur or 1.8, instant)
		end
	elseif act == "cloud" and hero then
		if a.state == "form" then
			-- The cloud's belly sits ~1.5 studs above the hero's real head.
			fx:cloudForm(above(hero, Vector3.new(0, 2.6, 0)), instant)
		elseif a.state == "burst" then
			fx:cloudBurst(instant)
			if not instant then
				sound("Reward")
			end
		end
	elseif act == "bulb" and hero then
		-- A head-height above his head, a little to the front of the rain cloud.
		fx:bulb(above(hero, Vector3.new(-0.6, 2.7, -2)), instant)
		if not instant then
			sound("Ready")
		end
	elseif act == "sweat" and actor then
		fx:sweat("sweat:" .. actor.name, above(actor, Vector3.new(0, -0.35, 0)), a.on == true)
	elseif act == "stars" and actor then
		local dur = if type(a.dur) == "number" then a.dur else 1.8
		fx:stars("stars:" .. actor.name, above(actor, Vector3.new(0, 0.2, 0)), dur, instant)
		if not instant then
			sound("Pickup", 1.4)
		end
	elseif act == "confetti" and not instant then
		local target = if type(a.at) == "string" then Actors.get(cast, a.at) else nil
		local at = if target then Actors.chest(target) else point(a.at)
		if at then
			fx:confetti(world(at))
			sound("Reward", 1.15)
		end
	elseif act == "tumbleweed" and not instant then
		local from, to = point(a.from), point(a.to)
		if from and to then
			fx:tumbleweed(world(from), world(to), if type(a.dur) == "number" then a.dur else 3)
		end
	elseif act == "marker" then
		fx:marker(a.on == true)
	elseif act == "tag" then
		ui:tagShown(a.on == true)
	elseif act == "namecard" then
		-- Shown until a namecard key with on = false (story time, so a paused
		-- preview keeps it).
		if a.on == false then
			ui:hideNameCard()
		elseif not instant then
			ui:nameCard(function()
				shake(s, 0.25, 0.25)
			end)
		end
	elseif act == "title" then
		ui:title(a.on == true, instant)
	elseif act == "flash" and not instant then
		ui:flash(a.dur or 0.6)
	elseif act == "letterbox" then
		ui:letterbox(a.on == true, instant)
	elseif act == "sound" and not instant then
		sound(a.name, a.pitch)
	end
end

-- Fires every action and caption of `beat` due by local time `t`.
local function fireDue(s: Session, beat: Timeline.Beat, t: number, instant: boolean)
	for _, a in beat.actions do
		if not s.fired[a] and a.t <= t then
			s.fired[a] = true
			run(s, a, instant)
		end
	end
	for _, c in beat.captions do
		if not s.fired[c] and c.t <= t then
			s.fired[c] = true
			if not instant and s.ui then
				if c.hide then
					s.ui:hideCaption()
				elseif c.key then
					s.ui:say(Theme.Intro.Lines[c.key] or "")
				end
			end
		end
	end
end

-- Frame -------------------------------------------------------------------------------------

local function step(s: Session, dt: number)
	dt = math.min(dt, 1 / 15)
	local beats = Timeline.BEATS

	if not s.skipShown and os.clock() - s.started >= (s.opts.delay or 0) + SKIP_AFTER then
		s.skipShown = true
		if s.ui then
			s.ui:showSkip()
		end
	end

	-- Advance the story clock (held during the preroll and at pauseAt).
	if s.preroll > 0 then
		s.preroll -= dt
	elseif not s.pausedAt then
		s.clock += dt
		local pauseAt = s.opts.pauseAt
		if pauseAt and s.beat == (s.opts.startBeat or 1) and s.clock >= pauseAt then
			s.clock = pauseAt
			s.pausedAt = pauseAt
		end
		while s.clock >= beats[s.beat].duration do
			fireDue(s, beats[s.beat], math.huge, false)
			s.clock -= beats[s.beat].duration
			s.beat += 1
			if s.beat > #beats then
				finish(s, false)
				return
			end
		end
		fireDue(s, beats[s.beat], s.clock, false)
	end

	-- A paused preview is a frozen frame: actors and props hold still.
	local simDt = if s.pausedAt then 0 else dt
	local cast = s.cast :: Actors.Cast
	Actors.update(cast, simDt)
	local hero = Actors.get(cast, "Hero")
	if s.fx then
		s.fx:update(simDt, hero and hero.hand)
	end
	if s.ui then
		s.ui:update(dt, function()
			Sounds.playCutscene("Tick", 0.05)
		end)
	end

	local camera = Workspace.CurrentCamera
	if camera then
		local cf, fov, key = cameraAt(s, beats[s.beat], s.clock)
		if cf then
			-- Ease toward the target so shots follow moving actors smoothly; cuts
			-- (and the first frame) jump straight there.
			local smooth = s.camSmooth
			if smooth and not (key ~= s.camKey and key.cut) then
				cf = smooth:Lerp(cf, 1 - math.exp(-10 * dt))
			end
			s.camSmooth = cf
			s.camKey = key
			local left = s.shakeUntil - os.clock()
			if left > 0 then
				local k = s.shakeAmp * left / math.max(s.shakeLen, 1e-3)
				local n = os.clock() * 37
				cf *= CFrame.new(math.noise(n, 1.3) * k, math.noise(n, 7.1) * k, 0)
			end
			camera.CameraType = Enum.CameraType.Scriptable
			camera.CFrame = cf
			camera.FieldOfView = fov
		end
	end
end

-- Public ------------------------------------------------------------------------------------

function Cutscene.isPlaying(): boolean
	return active ~= nil
end

function Cutscene.skip()
	local s = active
	if s and not s.ended then
		finish(s, true)
	end
end

local function setup(s: Session)
	local player = Players.LocalPlayer
	player:SetAttribute("IntroPlaying", true)

	-- Hide the HUD (every enabled ScreenGui below the loading screen).
	local playerGui = player:FindFirstChildOfClass("PlayerGui")
	if playerGui then
		for _, gui in playerGui:GetChildren() do
			if gui:IsA("ScreenGui") and gui.Enabled and gui.DisplayOrder < 100 and gui.Name ~= "IntroUI" then
				gui.Enabled = false
				table.insert(s.hidden, gui)
			end
		end
	end
	try("player list", function()
		s.playerList = StarterGui:GetCoreGuiEnabled(Enum.CoreGuiType.PlayerList)
		StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.PlayerList, false)
	end)
	s.controls = playerControls()
	if s.controls then
		s.controls:Disable()
	end
	local camera = Workspace.CurrentCamera
	if camera then
		s.cameraType = camera.CameraType
		s.cameraFov = camera.FieldOfView
		camera.CameraType = Enum.CameraType.Scriptable
	end

	-- The set, the effects, the overlay and the cast.
	local stage = Stage.build(Theme)
	s.stage = stage
	local fx = Effects.new(stage.model, stage.cframe, Theme)
	s.fx = fx
	s.ui = Ui.new(Theme, stage.model, function()
		Cutscene.skip()
	end)
	local cast = Actors.new(stage.cframe, stage.model)
	s.cast = cast
	cast.onTrail = function(ground: Vector3)
		fx:trailDrop(stage.cframe * ground)
	end
	for name, spec: any in Timeline.ACTORS do
		local look
		if name == "Hero" then
			look = Actors.heroLook(Theme, player)
		elseif name == "Fan" then
			look = Actors.fanLook(Theme)
		elseif name == "Rival" then
			look = Actors.rivalLook(Theme)
		else
			look = Actors.crowdLook(Theme, spec.look or 2)
		end
		Actors.add(cast, name, look, spec.at, spec.face, spec.hidden)
	end
	local ui = s.ui :: Ui.Ui
	local hero = Actors.get(cast, "Hero")
	if hero then
		ui:heroTag(hero.rig.root, hero.height + 1.6, player.DisplayName, Theme.Intro.HeroAura)
	end
	ui:letterbox(true, (s.opts.startBeat or 1) > 1)

	-- Fast-forward to the start beat (the dumbbell starts in the hero's hand).
	Actors.update(cast, 0)
	fx:update(0, hero and hero.hand)
	local startBeat = math.clamp(s.opts.startBeat or 1, 1, #Timeline.BEATS)
	for i = 1, startBeat - 1 do
		fireDue(s, Timeline.BEATS[i], math.huge, true)
	end
	s.beat = startBeat
	Actors.update(cast, 0)
	fx:update(0, hero and hero.hand)

	ContextActionService:BindActionAtPriority(BIND_NAME, function(_, state)
		if state == Enum.UserInputState.Begin and s.skipShown then
			Cutscene.skip()
		end
		return Enum.ContextActionResult.Sink
	end, false, Enum.ContextActionPriority.High.Value + 100, Enum.KeyCode.Escape, Enum.KeyCode.ButtonB)
end

function Cutscene.play(opts: Options?): boolean
	if active then
		return false
	end
	local s: Session = {
		opts = opts or {},
		ended = false,
		started = os.clock(),
		clock = 0,
		preroll = 0,
		beat = 1,
		fired = {},
		pausedAt = nil,
		skipShown = false,
		stage = nil,
		fx = nil,
		cast = nil,
		ui = nil,
		plotFrame = nil,
		fov = DEFAULT_FOV,
		shakeAmp = 0,
		shakeUntil = 0,
		shakeLen = 0,
		hidden = {},
		playerList = nil,
		cameraType = nil,
		cameraFov = nil,
		controls = nil,
		camSmooth = nil,
		camKey = nil,
	}
	s.preroll = s.opts.delay or 0
	active = s

	local ok, err = pcall(setup, s)
	if not ok then
		warn("[Intro] could not start: " .. tostring(err))
		s.ended = true
		teardown(s, true)
		return false
	end

	RunService:BindToRenderStep(BIND_NAME, Enum.RenderPriority.Camera.Value + 1, function(dt)
		if s.ended then
			return
		end
		local stepOk, stepErr = pcall(step, s, dt)
		if not stepOk then
			warn("[Intro] stopped: " .. tostring(stepErr))
			finish(s, true)
		end
	end)

	local limit = if s.opts.pauseAt then 300 else WATCHDOG + (s.opts.delay or 0)
	task.delay(limit, function()
		if not s.ended then
			warn("[Intro] watchdog ended the cutscene")
			finish(s, true)
		end
	end)
	return true
end

-- Plays from beat `index` (earlier beats fast-forward); `pauseAt` freezes it
-- that many seconds into the beat (Skip / Esc still ends it).
function Cutscene.preview(index: number, pauseAt: number?): boolean
	return Cutscene.play({ startBeat = index, pauseAt = pauseAt })
end

return Cutscene
