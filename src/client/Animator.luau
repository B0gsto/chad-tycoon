--[[
	Animator: plays the procedural unit animations (Shared.Poses) on the client.

	World units: every model tagged "AnimatedUnit" under Workspace is picked up
	automatically. The server builds them static; each client poses them
	locally (nothing replicates). A plot's rack can hold 100 jointed rigs, so
	posing is budgeted every frame:
	  * Units further than FAR studs from the camera, behind it or outside the
	    view cone (a cheap dot-product test, no engine calls) are skipped and
	    hold their last pose.
	  * Of the visible ones, the OWN_FULL nearest on the player's own plot
	    (Animator.setOwnPlot) and the OTHER_FULL nearest on other plots are
	    posed every frame (16 and 4). The hero and units playing a one-off pose
	    jump the queue.
	  * Every other visible unit is refreshed round-robin, OWN_TRICKLE (own
	    plot) and OTHER_TRICKLE (other plots) per frame, so none stays frozen
	    for long (about 6 Hz for a full own rack at 60 fps). At most 24 own and
	    8 other rigs are posed per frame.
	All world parts are moved with one BulkMoveTo call per frame. The hot path
	reuses its tables (no table allocations per frame); only CFrame values are
	created. Animator.stats() reports the last frame's counts.
	On "mid" / "low" devices (Fx.Budget) the full / trickle counts scale with
	Budget.count and on low units past LOW_FAR studs hold their pose.

	Viewport units (Index cards, reward popup): call Animator.attach(model)
	after building the model; they animate while their ViewportFrame is
	visible. Animator.detach(model) stops it (also automatic once the model is
	destroyed).

	Tier flavour (world units with a "Tier" attribute): idle tempo and float
	bob rise with tier, tiers >= 10 now and then hop into a showy pose, and
	every 6-10 s one random fully animated unit flexes.
	Animator.setHero(model, on) marks the shelf's best unit: a slower, prouder
	idle (deep chest breathing, a slight lift) and a power pose every ~8 s.
	Animator.isHeld(model) tells Fx code a unit is mid drop-in.
	Animator.show(model, pose?, duration?, hop?) plays a one-off pose (used by
	Fx.Shelf for the landing power pose). Animator.hold(model) freezes a unit
	in its rest pose (so it can be rescaled); Animator.release(model) re-captures
	its rest pose and resumes.
]]

local CollectionService = game:GetService("CollectionService")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Poses = require(Shared:WaitForChild("Poses"))
local RigPose = require(Shared:WaitForChild("RigPose"))
local Budget = require(script.Parent.Fx.Budget)

local Animator = {}

local FAR = 140 -- studs: beyond this units hold their pose
local LOW_FAR = 100 -- the same on a "low" budget device
local OWN_FULL = 16 -- own-plot rigs posed every frame (nearest visible first)
local OTHER_FULL = 4 -- other plots' rigs posed every frame
local OWN_TRICKLE = 8 -- further visible own-plot rigs refreshed per frame, round-robin
local OTHER_TRICKLE = 4 -- the same for other plots
local POS_REFRESH = 30 -- frames between position re-reads of a unit that is not posed
local VIEW_MARGIN = 1.6 -- unit heights of slack around the view cone
local VIEWPORT_INTERVAL = 1 / 30 -- viewport units animate at 30 fps
local PRUNE_AFTER = 3 -- seconds an attached model may sit without a parent
local SHOW_FADE = 0.25 -- seconds to blend into / out of a one-off pose
local SHOW_PRIORITY = 0.3 -- distance factor for units playing a one-off pose
local FLEX_EVERY = { 6, 10 } -- seconds between random flexes
local FLEX_POSES = { "DoubleBiceps", "MostMuscular", "LatSpread", "SideChest" }
local SHOWY_POSES = { "DoubleBiceps", "MostMuscular", "Point", "SmugTurn" }
local IDENTITY = CFrame.new()

type Entry = {
	model: Model,
	rig: RigPose.Rig?,
	viewport: boolean,
	slot: number,
	index: number, -- position in `list`
	height: number,
	orphanSince: number?,
	nextViewportUpdate: number,
	connections: { RBXScriptConnection },
	plot: Instance?, -- the plot folder holding the unit (Units' parent)
	pos: Vector3?, -- cached root position
	world: { [string]: CFrame }, -- per-limb world frames (reused)
	visibleFrame: number,
	fullFrame: number,
	-- Tier flavour (world units only).
	tier: number,
	tempo: number,
	bob: number,
	clock: number,
	held: boolean,
	showPose: string?,
	showStart: number,
	showLength: number,
	showHop: number,
	nextShowy: number,
	seenFrame: number,
}

local entries: { [Model]: Entry } = {}
local list: { Entry } = {}
local heroes: { [Model]: boolean } = setmetatable({}, { __mode = "k" }) :: any
local HERO_POSES = { "MostMuscular", "DoubleBiceps", "LatSpread", "SideChest" }
local slotCounter = 0
local started = false
local ownPlot: Instance? = nil

local function newSeed(): number
	return math.random(0, 99999)
end

local function tryCapture(entry: Entry): RigPose.Rig?
	if entry.rig then
		return entry.rig
	end
	local model = entry.model
	local okScale, modelScale = pcall(function()
		return model:GetScale()
	end)
	local rig = RigPose.capture(model, newSeed())
	if rig and okScale and type(modelScale) == "number" and modelScale ~= 1 then
		-- Someone rescaled the model after it was built: scale the pivots too.
		rig.scale *= modelScale
		for limb, pivot in rig.pivots do
			rig.pivots[limb] = pivot * modelScale
		end
		table.clear(rig.parts)
		table.clear(rig.limbs)
		table.clear(rig.offsets)
		for _, d in model:GetDescendants() do
			if d:IsA("BasePart") then
				RigPose.addPart(rig, d)
			end
		end
	end
	if rig then
		entry.rig = rig
		local height = model:GetAttribute("Height")
		entry.height = if type(height) == "number" then height else 6
		entry.pos = rig.root.Position
	end
	return rig
end

local function register(model: Model, viewport: boolean)
	local existing = entries[model]
	if existing then
		existing.viewport = existing.viewport or viewport
		return
	end
	slotCounter += 1
	local entry: Entry = {
		model = model,
		rig = nil,
		viewport = viewport,
		slot = slotCounter,
		index = #list + 1,
		height = 6,
		orphanSince = nil,
		nextViewportUpdate = 0,
		connections = {},
		plot = nil,
		pos = nil,
		world = {},
		visibleFrame = 0,
		fullFrame = 0,
		tier = 1,
		tempo = 1,
		bob = 0,
		clock = os.clock(),
		held = false,
		showPose = nil,
		showStart = 0,
		showLength = 0,
		showHop = 0,
		nextShowy = os.clock() + 8 + math.random() * 12,
		seenFrame = 0,
	}
	entries[model] = entry
	list[entry.index] = entry
end

-- Reads the unit's tier and derives its idle tempo and float bob.
local function readTier(entry: Entry)
	local value = entry.model:GetAttribute("Tier")
	local tier = if type(value) == "number" then value else 1
	entry.tier = tier
	entry.tempo = 1 + math.clamp(tier - 1, 0, 24) * 0.025 -- 1.0x .. 1.6x
	entry.bob = math.max(0, tier - 9) * 0.012 -- unscaled studs, 0 .. ~0.19
	if heroes[entry.model] then
		entry.tempo *= 0.8 -- the champion takes its time
	end
end

local function readPlot(entry: Entry)
	local units = entry.model.Parent
	entry.plot = if units then units.Parent else nil
end

-- Hooked up on the first frame a unit is processed (keeps attach() free of
-- side effects, so tools that load the UI without a frame loop stay happy).
local function connect(entry: Entry)
	local model = entry.model
	readTier(entry)
	readPlot(entry)
	table.insert(
		entry.connections,
		model:GetAttributeChangedSignal("Tier"):Connect(function()
			readTier(entry)
		end)
	)
	table.insert(
		entry.connections,
		model.AncestryChanged:Connect(function()
			readPlot(entry)
		end)
	)
	-- Parts that stream in later arrive in their rest pose; parts that leave are dropped.
	table.insert(
		entry.connections,
		model.DescendantAdded:Connect(function(d)
			local rig = entry.rig
			if rig and d:IsA("BasePart") then
				RigPose.addPart(rig, d)
			end
		end)
	)
	table.insert(
		entry.connections,
		model.DescendantRemoving:Connect(function(d)
			local rig = entry.rig
			if rig and d:IsA("BasePart") then
				if d == rig.root then
					-- Streamed out: forget it; it re-registers when it streams back in.
					task.defer(Animator.detach, entry.model)
				else
					RigPose.removePart(rig, d)
				end
			end
		end)
	)
end

local function unregister(model: Model)
	local entry = entries[model]
	if not entry then
		return
	end
	entries[model] = nil
	-- Swap-remove from the list, keeping indices right.
	local last = list[#list]
	list[entry.index] = last
	last.index = entry.index
	list[#list] = nil
	for _, connection in entry.connections do
		connection:Disconnect()
	end
end

-- Animate a model that lives outside Workspace (e.g. in a ViewportFrame).
function Animator.attach(model: Model)
	register(model, true)
end

function Animator.detach(model: Model)
	unregister(model)
end

-- The local player's plot folder: its units get the bigger budgets.
function Animator.setOwnPlot(plot: Instance?)
	ownPlot = plot
end

-- Plays a one-off pose on a world unit (blends in and out); `hop` lifts the
-- root in a small arc (unscaled studs).
function Animator.show(model: Model, pose: string?, duration: number?, hop: number?)
	local entry = entries[model]
	if not entry or entry.held then
		return
	end
	local poses = Poses.poseNames((model:GetAttribute(Poses.SET_ATTRIBUTE) :: string?) or "Chad")
	local name = pose
	if not name or not table.find(poses, name) then
		name = poses[math.random(2, math.max(2, #poses))] or poses[1]
	end
	entry.showPose = name
	entry.showStart = os.clock()
	entry.showLength = duration or 1.6
	entry.showHop = hop or 0
end

-- Marks (or clears) the shelf's hero unit: slower, prouder idle and regular power poses.
function Animator.setHero(model: Model, on: boolean)
	if (heroes[model] == true) == on then
		return
	end
	heroes[model] = (if on then true else nil) :: any
	local entry = entries[model]
	if entry and #entry.connections > 0 then
		readTier(entry)
		if on then
			entry.nextShowy = os.clock() + 1.5
		end
	end
end

function Animator.isHeld(model: Model): boolean
	local entry = entries[model]
	return entry ~= nil and entry.held
end

-- Freezes a world unit in its rest pose (for client-side rescaling).
function Animator.hold(model: Model)
	if not entries[model] then
		register(model, false)
	end
	local entry = entries[model] :: Entry
	entry.held = true
	entry.showPose = nil
	if entry.rig then
		RigPose.reset(entry.rig)
	end
end

-- Resumes a held unit, re-capturing its rest pose (it may have been rescaled).
function Animator.release(model: Model)
	local entry = entries[model]
	if not entry then
		return
	end
	entry.held = false
	entry.rig = nil
end

-- Is the ViewportFrame (or other GUI) holding this model actually on screen?
local function guiVisible(model: Model): boolean
	local node: Instance? = model.Parent
	while node do
		if node:IsA("GuiObject") then
			if not node.Visible then
				return false
			end
		elseif node:IsA("LayerCollector") then
			return node.Enabled and node:FindFirstAncestorWhichIsA("PlayerGui") ~= nil
		end
		node = node.Parent
	end
	return false
end

local worldParts: { BasePart } = {}
local worldCFrames: { CFrame } = {}
local frameCount = 0
local lastStep = os.clock()
local nextFlex = os.clock() + FLEX_EVERY[1]
local showBuffer: { [string]: CFrame } = {}
local showTarget: { [string]: CFrame } = {}
local flexCandidates: { Entry } = {}

-- Nearest-first selections (reused every frame).
local ownPick: { Entry } = {}
local ownKeys: { number } = {}
local otherPick: { Entry } = {}
local otherKeys: { number } = {}
local ownCursor = 1
local otherCursor = 1

local stats = { units = 0, visible = 0, full = 0, trickle = 0, parts = 0 }

local function smooth(x: number): number
	x = math.clamp(x, 0, 1)
	return x * x * (3 - 2 * x)
end

-- Inserts `item` into the ascending `keys`/`picks` arrays holding `n` items, keeping at
-- most `cap` (the largest key drops out). Returns the new count.
local function insertNearest<T>(picks: { T }, keys: { number }, n: number, cap: number, item: T, key: number): number
	if n >= cap then
		if cap <= 0 or key >= keys[n] then
			return n
		end
	else
		n += 1
	end
	local j = n
	while j > 1 and keys[j - 1] > key do
		picks[j] = picks[j - 1]
		keys[j] = keys[j - 1]
		j -= 1
	end
	picks[j] = item
	keys[j] = key
	return n
end

-- Is a sphere of `radius` around `rel` (relative to the camera) inside the view cone?
-- `look`, `right`, `up` are the camera axes; tanX / tanY the half-angle tangents.
local function inView(rel: Vector3, radius: number, look: Vector3, right: Vector3, up: Vector3, tanX: number, tanY: number): boolean
	local z = rel:Dot(look)
	if z < -radius then
		return false
	end
	local slackX = radius * math.sqrt(1 + tanX * tanX)
	local slackY = radius * math.sqrt(1 + tanY * tanY)
	return math.abs(rel:Dot(right)) <= z * tanX + slackX and math.abs(rel:Dot(up)) <= z * tanY + slackY
end

Animator.insertNearest = insertNearest
Animator.inView = inView

-- Joint transforms for a world unit: tier tempo, float bob and any one-off pose.
local function worldTransforms(entry: Entry, rig: RigPose.Rig, now: number): { [string]: CFrame }
	local transforms = Poses.sampleInto(rig.transforms, rig.animSet, entry.clock, rig.seed)
	local lift = 0
	if entry.bob > 0 then
		lift += entry.bob * (1 + math.sin(entry.clock * 1.7 + rig.seed))
	end
	local hero = heroes[entry.model]
	if hero then
		-- Deep, slow chest breathing: rise on the inhale, hold, settle.
		local breath = math.sin(now * 1.3)
		lift += 0.08 + 0.06 * breath * math.abs(breath)
	end
	local pose = entry.showPose
	if pose then
		local t = now - entry.showStart
		if t >= entry.showLength then
			entry.showPose = nil
		else
			local w = smooth(t / SHOW_FADE) * smooth((entry.showLength - t) / SHOW_FADE)
			local target = Poses.samplePoseInto(showTarget, rig.animSet, pose, entry.clock, rig.seed)
			for limb, cf in transforms do
				local goal = target[limb]
				if goal then
					showBuffer[limb] = cf:Lerp(goal, w)
				end
			end
			for limb, cf in showBuffer do
				transforms[limb] = cf
			end
			table.clear(showBuffer)
			if entry.showHop > 0 then
				local p = math.clamp(t / math.min(0.6, entry.showLength), 0, 1)
				lift += entry.showHop * 4 * p * (1 - p)
			end
		end
	end
	if lift ~= 0 then
		transforms.LowerTorso = CFrame.new(0, lift, 0) * (transforms.LowerTorso or IDENTITY)
	end
	return transforms
end

-- Poses one world unit and queues its parts for this frame's BulkMoveTo: one root * limb
-- multiply per limb, then one multiply per part.
local function pose(entry: Entry, rig: RigPose.Rig, now: number)
	local frames = Poses.solve(rig.pivots, worldTransforms(entry, rig, now), rig.scale, rig.frames)
	local root = rig.root.CFrame
	entry.pos = root.Position
	local world = entry.world
	for limb, frame in frames do
		world[limb] = root * frame
	end
	local parts, limbs, offsets = rig.parts, rig.limbs, rig.offsets
	local n = #worldParts
	for i = 1, #parts do
		n += 1
		worldParts[n] = parts[i]
		worldCFrames[n] = world[limbs[i]] * offsets[i]
	end
end

-- Every few seconds a random fully animated unit flexes; high tiers show off on their own.
local function pickFlex(now: number)
	if now < nextFlex then
		return
	end
	nextFlex = now + FLEX_EVERY[1] + math.random() * (FLEX_EVERY[2] - FLEX_EVERY[1])
	table.clear(flexCandidates)
	for _, entry in list do
		if not entry.viewport and not entry.held and not entry.showPose and entry.seenFrame >= frameCount - 2 then
			table.insert(flexCandidates, entry)
		end
	end
	if #flexCandidates > 0 then
		local entry = flexCandidates[math.random(1, #flexCandidates)]
		Animator.show(entry.model, FLEX_POSES[math.random(1, #FLEX_POSES)], 1.8, 0)
	end
	table.clear(flexCandidates)
end

-- A unit in the every-frame set: may start a showy / hero pose, then is posed.
local function poseFull(entry: Entry, now: number)
	local rig = entry.rig
	if not rig or not entry.model:IsDescendantOf(Workspace) then
		return
	end
	entry.fullFrame = frameCount
	entry.seenFrame = frameCount
	if heroes[entry.model] and not entry.showPose and now >= entry.nextShowy then
		-- Hero: a held, proud power pose every ~8 s (no hop: grounded and confident).
		entry.nextShowy = now + 7 + math.random() * 3
		Animator.show(entry.model, HERO_POSES[math.random(1, #HERO_POSES)], 2.6, 0)
	elseif entry.tier >= 10 and not entry.showPose and now >= entry.nextShowy then
		entry.nextShowy = now + 14 + math.random() * 16 - entry.tier * 0.3
		Animator.show(entry.model, SHOWY_POSES[math.random(1, #SHOWY_POSES)], 2, 0.6 + entry.tier * 0.02)
	end
	pose(entry, rig, now)
end

-- Refreshes up to `budget` visible units of one group (own plot or not) that were not in
-- the every-frame set, continuing round-robin from `cursor`. Returns the next cursor.
local function trickle(cursor: number, own: boolean, budget: number, waiting: number, now: number): number
	local count = #list
	local todo = math.min(budget, waiting)
	if todo <= 0 or count == 0 then
		return cursor
	end
	for _ = 1, count do
		if cursor > count then
			cursor = 1
		end
		local entry = list[cursor]
		cursor += 1
		if entry.visibleFrame == frameCount and entry.fullFrame ~= frameCount and (ownPlot == nil or entry.plot == ownPlot) == own then
			local rig = entry.rig
			if rig and entry.model:IsDescendantOf(Workspace) then
				pose(entry, rig, now)
				stats.trickle += 1
			end
			todo -= 1
			if todo <= 0 then
				break
			end
		end
	end
	return cursor
end

local function step()
	frameCount += 1
	local now = os.clock()
	local dt = math.min(now - lastStep, 0.1)
	lastStep = now
	pickFlex(now)
	local camera = Workspace.CurrentCamera
	local camCFrame = if camera then camera.CFrame else IDENTITY
	local camPos = camCFrame.Position
	local look, right, up = camCFrame.LookVector, camCFrame.RightVector, camCFrame.UpVector
	local viewSize = if camera then camera.ViewportSize else Vector2.new(1920, 1080)
	local tanY = math.tan(math.rad((if camera then camera.FieldOfView else 70) / 2))
	local tanX = tanY * viewSize.X / math.max(viewSize.Y, 1)
	table.clear(worldParts)
	table.clear(worldCFrames)
	stats.units, stats.visible, stats.full, stats.trickle = 0, 0, 0, 0
	local far = if Budget.low() then LOW_FAR else FAR
	local ownFull, otherFull = Budget.count(OWN_FULL), Budget.count(OTHER_FULL)

	local ownN, otherN = 0, 0
	local ownVisible, otherVisible = 0, 0
	local i = 1
	while i <= #list do
		local entry = list[i]
		local model = entry.model
		if not model.Parent then
			entry.orphanSince = entry.orphanSince or now
			if now - (entry.orphanSince :: number) > PRUNE_AFTER then
				unregister(model) -- swaps the last entry into slot i
				continue
			end
			i += 1
			continue
		end
		i += 1
		entry.orphanSince = nil
		if #entry.connections == 0 then
			connect(entry)
		end
		if entry.held then
			continue
		end
		local rig = tryCapture(entry)
		if not rig then
			continue
		end

		if entry.viewport then
			if now >= entry.nextViewportUpdate and guiVisible(model) then
				entry.nextViewportUpdate = now + VIEWPORT_INTERVAL
				RigPose.apply(rig, now)
			end
			continue
		end

		stats.units += 1
		entry.clock += dt * entry.tempo
		if (frameCount + entry.slot) % POS_REFRESH == 0 or not entry.pos then
			entry.pos = rig.root.Position
		end
		local half = entry.height * 0.5
		local rel = (entry.pos :: Vector3) + Vector3.new(0, half, 0) - camPos
		local distance = rel.Magnitude
		if distance > far then
			continue
		end
		if distance > entry.height * 1.5 and not inView(rel, half * VIEW_MARGIN, look, right, up, tanX, tanY) then
			continue
		end
		entry.visibleFrame = frameCount
		local key = distance
		if heroes[model] then
			key = 0
		elseif entry.showPose then
			key *= SHOW_PRIORITY
		end
		if ownPlot == nil or entry.plot == ownPlot then
			ownVisible += 1
			ownN = insertNearest(ownPick, ownKeys, ownN, ownFull, entry, key)
		else
			otherVisible += 1
			otherN = insertNearest(otherPick, otherKeys, otherN, otherFull, entry, key)
		end
	end

	for k = 1, ownN do
		poseFull(ownPick[k], now)
	end
	for k = 1, otherN do
		poseFull(otherPick[k], now)
	end
	stats.full = ownN + otherN
	stats.visible = ownVisible + otherVisible
	ownCursor = trickle(ownCursor, true, Budget.count(OWN_TRICKLE), ownVisible - ownN, now)
	otherCursor = trickle(otherCursor, false, Budget.count(OTHER_TRICKLE), otherVisible - otherN, now)
	-- Drop the references so destroyed models can be collected.
	table.clear(ownPick)
	table.clear(otherPick)

	stats.parts = #worldParts
	if #worldParts > 0 then
		Workspace:BulkMoveTo(worldParts, worldCFrames, Enum.BulkMoveMode.FireCFrameChanged)
	end
end

-- Last frame's counts: world units tracked, visible, posed in full, refreshed round-robin,
-- parts moved. For profiling in Studio.
function Animator.stats(): { units: number, visible: number, full: number, trickle: number, parts: number }
	return table.clone(stats)
end

local function onTagged(instance: Instance)
	if instance:IsA("Model") and instance:IsDescendantOf(Workspace) then
		register(instance, false)
	end
end

function Animator.start()
	if started then
		return
	end
	started = true
	CollectionService:GetInstanceAddedSignal(Poses.TAG):Connect(onTagged)
	CollectionService:GetInstanceRemovedSignal(Poses.TAG):Connect(function(instance)
		local entry = entries[instance :: Model]
		if entry and not entry.viewport then
			unregister(instance :: Model)
		end
	end)
	for _, instance in CollectionService:GetTagged(Poses.TAG) do
		onTagged(instance)
	end
	RunService.RenderStepped:Connect(step)
end

return Animator
