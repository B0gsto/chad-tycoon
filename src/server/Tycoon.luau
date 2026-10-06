--[[
	Tycoon: the core game loop for every player.

	One Session per player: owns a plot, the saved profile and all runtime
	objects on that plot (displayed units, orbs, floor crates, the held crate).

	Loops:
	  fast (0.1s)  pad detection, orb pickup, automatic crate pickup
	  slow (1s)    production, processing, auto passes, boards, state push
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Economy = require(Shared.Economy)
local OrbLook = require(Shared.OrbLook)
local CratePickup = require(Shared.CratePickup)
local Format = require(Shared.Format)
local Net = require(Shared.Net)
local CharacterFactory = require(Shared.CharacterFactory)

local WorldBuilder = require(script.Parent.WorldBuilder)
local Layout = require(script.Parent.PlotLayout)
local Shelves = require(script.Parent.World.Shelves)
local Props = require(script.Parent.World.Props)

type Profile = any
type Plot = WorldBuilder.Plot

-- `cell` is the pile slot the orb rests in (see orbCells): 1..n on the floor, PILE_TOP + k on top.
-- `due`: Auto Aura collects the orb at this os.clock() (after its roll-in lands and rests);
-- `windup`: when the "Auto" wind-up started (collected AUTO_WINDUP later).
type Orb = { part: BasePart, value: number, count: number, cell: number, tier: number, due: number?, windup: number? }
-- `landsAt`: os.clock() by which the client's arrival has landed (CratePickup.landTime);
-- `blocked`: in range when the last held crate was released, until the player leaves its range.
type FloorChest = { model: Model, rarity: string, position: Vector3, landsAt: number, blocked: boolean }
type DisplaySlot = { tier: number, model: Model }

export type Session = {
	player: Player,
	profile: Profile,
	canSave: boolean,
	plot: Plot,
	passes: { [string]: boolean },
	premium: boolean,
	friendBonus: number,
	inside: { [string]: boolean },
	converterPos: Vector3?,
	orbs: { Orb },
	floorChests: { FloorChest },
	heldModel: Model?,
	display: { [number]: DisplaySlot },
	displayCounts: string,
	dirty: boolean,
	chestTimer: number,
	collectBuffer: number,
	actionBudget: number,
	lastPickupFlush: number,
	crateRearmUntil: number,
	lastToast: { [string]: number },
	alive: boolean,
}

local Tycoon = {}

local theme: any
local world: WorldBuilder.World
local sessions: { [Player]: Session } = {}
local plotOwners: { [number]: Player } = {}
local rng = Random.new()

-- Pen fill: every produced orb lands as its own ball until the pen holds OrbLook.CAP balls (or
-- the pile has no free slot); after that a new orb joins an existing ball (OrbLook.feedTarget)
-- and that ball's Count goes up.
local ORB_SIZE = Layout.ORB_RADIUS * 2
-- The pile: floor slots on a jittered grid around PILE_FOCUS (plot-local), and top slots
-- resting in the hollow between four occupied floor slots.
local PILE_SPACING = 1.8
local PILE_JITTER = 0.1
local PILE_SCATTER = 6 -- random studs added to each slot's distance when picking one
local PILE_TOP = 1000 -- cell ids above this are top-layer slots
local PILE_TOP_FROM = 40 -- floor orbs needed before the pile grows a partial second layer
local PILE_TOP_CHANCE = 0.3
local ORB_PICKUP_RADIUS = 6
local ORB_PICKED_POSITIONS = 12
local AUTO_WINDUP = 0.25 -- seconds between the "Auto" attribute (client squash) and collection
-- Merge effects per action; more steps are sent as one summarised effect.
local MAX_MERGE_EFFECTS = 6
local MERGE_FROM_POSITIONS = 4
-- Crates keep this far apart (centre to centre) when they land in the pen.
local CHEST_SPACING = 6
-- Landing spots tried before a crate drop is skipped (the pen front is full).
local CHEST_SPOT_TRIES = 12
local ACTIONS_PER_SECOND = 15
-- Orb pickups push State right away (so the HUD tank keeps up), at most this often.
local PICKUP_FLUSH_INTERVAL = 0.09
-- Plot-local height window for the HumanoidRootPart to count as standing on a
-- pad (pads sit on the main floor at y = 0).
local PAD_MIN_Y = 0.5
local PAD_MAX_Y = 10
-- Orbs can be collected only from inside the pen (walls and stair tops included),
-- up to this high above its floor.
local POOL_REACH_Y = 12

local NotifyRemote: RemoteEvent
local EffectRemote: RemoteEvent
local StateRemote: RemoteEvent
local ActionRemote: RemoteEvent

-- Filled in by Main so Tycoon does not depend on Monetization directly.
Tycoon.hooks = {
	promptPass = function(_player: Player, _name: string) end,
	promptProduct = function(_player: Player, _kind: string, _index: number) end,
	promptCrate = function(_player: Player, _rarity: string) end,
	-- May this player buy instant crate opens (paid random items)? Monetization
	-- answers from PolicyService; this default only serves previews and tests.
	crateRobuxAllowed = function(_player: Player): boolean
		return true
	end,
	-- Called after setPass records a newly bought pass (Cosmetics applies it).
	passGranted = function(_session: Session, _name: string) end,
	-- The State snapshot's `cosmetics` field (filled in by Cosmetics).
	cosmetics = function(_session: Session): { [string]: any }?
		return nil
	end,
	-- The State snapshot's `modes` field (filled in by GameModes).
	modes = function(_session: Session): { [string]: any }?
		return nil
	end,
}

-- Gameplay event listeners (used by the tutorial): fn(session, name, data).
-- Names: "Buy", "Pickup", "Deposit", "Cash", "Merge".
Tycoon.listeners = {} :: { (Session, string, { [string]: any }) -> () }

local function emit(session: Session, name: string, data: { [string]: any })
	for _, listener in Tycoon.listeners do
		task.spawn(listener, session, name, data)
	end
end

local function random(): number
	return rng:NextNumber()
end

local function serverNow(): number
	return Workspace:GetServerTimeNow()
end

-- Helpers ----------------------------------------------------------------------

function Tycoon.getSession(player: Player): Session?
	return sessions[player]
end

function Tycoon.getSessionByUserId(userId: number): Session?
	for player, session in sessions do
		if player.UserId == userId then
			return session
		end
	end
	return nil
end

function Tycoon.allSessions(): { [Player]: Session }
	return sessions
end

local function notify(session: Session, payload: { [string]: any })
	NotifyRemote:FireClient(session.player, payload)
end

local function toast(session: Session, text: string, tone: string?)
	-- Pads fire repeatedly if a player hops on them; avoid spamming the same text.
	local now = os.clock()
	if session.lastToast[text] and now - session.lastToast[text] < 1 then
		return
	end
	session.lastToast[text] = now
	notify(session, { kind = "Toast", text = text, tone = tone or "info" })
end
Tycoon.toast = toast
Tycoon.notify = notify

local function effect(session: Session, kind: string, data: { [string]: any }?)
	EffectRemote:FireClient(session.player, kind, data or {})
end

local function markDirty(session: Session)
	session.dirty = true
end
Tycoon.markDirty = markDirty

local function tierName(tier: number): string
	local entry = theme.Tiers[tier]
	return if entry then entry.Name else ("Tier " .. tier)
end

function Tycoon.moneyMultiplier(session: Session): number
	local mult = if session.passes.DoubleMoney then 2 else 1
	local bonus = session.friendBonus + (if session.premium then Economy.PREMIUM_BONUS else 0)
	return mult * (1 + bonus)
end

function Tycoon.orbMultiplier(session: Session): number
	local mult = if session.passes.DoubleAura then 2 else 1
	local surge = Economy.surgeState(serverNow())
	if surge then
		mult *= Economy.SURGE_MULTIPLIER
	end
	return mult
end

function Tycoon.production(session: Session): number
	return Economy.productionPerSecond(session.profile.units) * Tycoon.orbMultiplier(session)
end

function Tycoon.income(session: Session): number
	local p = session.profile
	return Economy.incomePerSecond(Tycoon.production(session), Economy.processRate(p.processLevel), Tycoon.moneyMultiplier(session))
end

local function highestTier(session: Session): number
	return Economy.highestTier(session.profile.discovered)
end

local function canAfford(session: Session, cost: number): boolean
	return session.profile.money >= cost - 1e-6
end

-- Tells the client a pad action was refused (shake / buzz on the pad).
local function refusePad(session: Session, name: string, reason: string)
	local pad = session.plot.padByName[name]
	effect(session, "Pad", { name = name, padPos = pad and pad.part.Position, ok = false, reason = reason })
end

-- `padName` = the pad that asked for the purchase (gets a "money" refusal effect).
local function spend(session: Session, cost: number, padName: string?): boolean
	if not canAfford(session, cost) then
		toast(session, "Not enough cash! Need " .. Format.money(cost), "bad")
		if padName then
			refusePad(session, padName, "money")
		end
		return false
	end
	session.profile.money = math.max(0, session.profile.money - cost)
	return true
end

local function spendGems(session: Session, cost: number): boolean
	if session.profile.gems < cost then
		toast(session, string.format("Not enough %s! Need %d %s", theme.Words.Gem, cost, theme.Icons.Gem), "bad")
		return false
	end
	session.profile.gems -= cost
	return true
end

local function addMoney(session: Session, amount: number)
	session.profile.money += amount
	session.profile.totalEarned += amount
end

-- Unit display -------------------------------------------------------------------

-- Every owned unit stands on the rack as its own model (the unit cap keeps the total
-- within Economy.DISPLAY_SLOTS). Shelf models are built display-scaled so tall tiers fit
-- under the shelf above (Layout.displayScale); viewports elsewhere keep true sizes.
local displayLooks: { [number]: any } = {}

local function displayLook(tier: number): any
	local cached = displayLooks[tier]
	if cached then
		return cached
	end
	local look = theme.Tiers[tier].Look
	local scale = Layout.displayScale(CharacterFactory.height(look))
	local shown = look
	if scale < 1 then
		shown = table.clone(look)
		shown.scale = (look.scale or 1) * scale
	end
	displayLooks[tier] = shown
	return shown
end

-- World positions of shelf models by tier: consumed (destroyed), newly created,
-- and everything shown after the refresh.
type ShelfDiff = {
	removed: { [number]: { Vector3 } },
	added: { [number]: { Vector3 } },
	shown: { [number]: { Vector3 } },
}

local function pushPos(map: { [number]: { Vector3 } }, tier: number, pos: Vector3)
	local list = map[tier]
	if not list then
		list = {}
		map[tier] = list
	end
	table.insert(list, pos)
end

-- Tags a display model with its slot and the top front edge of the shelf lip under its feet
-- (Fx.Plates hangs the unit's name plate from that edge, facing the pen).
local function markSlot(model: Model, slotIndex: number, slot: CFrame)
	local s = Layout.SHELF
	local lift = s.standY + (if slotIndex == 1 then s.championRise else 0)
	model:SetAttribute("Slot", slotIndex)
	model:SetAttribute("PlateAt", slot * CFrame.new(0, -lift, -(s.depth / 2 + s.frontReach)))
end

-- Diffs the shelf against the unit counts: models that keep their tier stay put,
-- models whose tier moved to another slot are re-pivoted, only new units get new
-- models, and surplus models are destroyed (after recording their positions). Then shows
-- just the rack shelves those units need (Shelves.setRows).
local function refreshDisplay(session: Session): ShelfDiff
	local units = session.profile.units
	local slots = session.plot.slots
	local wanted: { number } = {}
	for tier = Economy.MAX_TIER, 1, -1 do
		local count = units[tier] or 0
		local shown = math.min(count, Economy.DISPLAY_SLOTS - #wanted)
		for _ = 1, shown do
			table.insert(wanted, tier)
		end
		if #wanted >= Economy.DISPLAY_SLOTS then
			break
		end
	end

	local diff: ShelfDiff = { removed = {}, added = {}, shown = {} }
	local old = session.display
	local nextDisplay: { [number]: DisplaySlot } = {}

	-- Keep models already standing in a slot that still shows their tier.
	for slotIndex = 1, Economy.DISPLAY_SLOTS do
		local current = old[slotIndex]
		if current and wanted[slotIndex] == current.tier then
			nextDisplay[slotIndex] = current
		end
	end
	-- Everything else is up for reuse, per tier, in slot order.
	local spare: { [number]: { DisplaySlot } } = {}
	for slotIndex = 1, Economy.DISPLAY_SLOTS do
		local current = old[slotIndex]
		if current and nextDisplay[slotIndex] ~= current then
			local list = spare[current.tier]
			if not list then
				list = {}
				spare[current.tier] = list
			end
			table.insert(list, current)
		end
	end

	for slotIndex = 1, Economy.DISPLAY_SLOTS do
		local tier = wanted[slotIndex]
		if tier and not nextDisplay[slotIndex] then
			local list = spare[tier]
			if list and #list > 0 then
				local entry = table.remove(list, 1) :: DisplaySlot
				entry.model:PivotTo(slots[slotIndex])
				markSlot(entry.model, slotIndex, slots[slotIndex])
				nextDisplay[slotIndex] = entry
			else
				local model = CharacterFactory.build(displayLook(tier), tierName(tier))
				model:PivotTo(slots[slotIndex])
				model:SetAttribute("Tier", tier)
				model:SetAttribute("Spawned", serverNow())
				markSlot(model, slotIndex, slots[slotIndex])
				model.Parent = session.plot.unitFolder
				nextDisplay[slotIndex] = { tier = tier, model = model }
				pushPos(diff.added, tier, model:GetPivot().Position)
			end
		end
	end

	for tier, list in spare do
		for _, entry in list do
			pushPos(diff.removed, tier, entry.model:GetPivot().Position)
			entry.model:Destroy()
		end
	end

	for slotIndex = 1, Economy.DISPLAY_SLOTS do
		local entry = nextDisplay[slotIndex]
		if entry then
			pushPos(diff.shown, entry.tier, entry.model:GetPivot().Position)
		end
	end

	session.display = nextDisplay
	Shelves.setRows(session.plot.folder, Layout.rackRows(#wanted))
	return diff
end

-- Merge effects --------------------------------------------------------------------

local function mergeTarget(diff: ShelfDiff, tier: number): Vector3?
	local added = diff.added[tier]
	if added and added[1] then
		return added[1]
	end
	local shown = diff.shown[tier]
	return shown and shown[1]
end

-- One "Merge" effect per merge step (fromTier -> fromTier + 1), or a single
-- summarised effect when a batch cascades through many tiers.
local function sendMergeEffects(session: Session, steps: { Economy.MergeStep }, auto: boolean, diff: ShelfDiff)
	if #steps == 0 then
		return
	end
	if #steps > MAX_MERGE_EFFECTS then
		local from: { Vector3 } = {}
		local total = 0
		for _, step in steps do
			total += step.made
			local removed: { Vector3 } = diff.removed[step.tier] or {}
			for _, pos in removed do
				if #from < MERGE_FROM_POSITIONS then
					table.insert(from, pos)
				end
			end
		end
		local toTier = steps[#steps].tier + 1
		effect(session, "Merge", {
			fromTier = steps[1].tier,
			toTier = toTier,
			from = from,
			to = mergeTarget(diff, toTier),
			auto = auto,
			count = total,
			summary = true,
		})
		return
	end
	-- A cascade feeds each step's result into the next one, so a step whose
	-- consumed unit was never on the shelf starts from the previous result.
	local carry: Vector3? = nil
	for _, step in steps do
		local from: { Vector3 } = {}
		local removed: { Vector3 } = diff.removed[step.tier] or {}
		for _, pos in removed do
			if #from >= MERGE_FROM_POSITIONS then
				break
			end
			table.insert(from, pos)
		end
		if #from < 2 and carry then
			table.insert(from, carry)
		end
		local to = mergeTarget(diff, step.tier + 1)
		effect(session, "Merge", {
			fromTier = step.tier,
			toTier = step.tier + 1,
			from = from,
			to = to,
			auto = auto,
			count = step.made,
		})
		carry = to or from[1]
	end
end

-- One summarised "Merge" effect (overflow = true) for the merges the unit cap forced
-- (Economy.addUnitsCapped): lowest consumed tier -> highest created tier, `count` merges.
local function sendOverflowEffect(session: Session, steps: { Economy.MergeStep }, diff: ShelfDiff)
	if #steps == 0 then
		return
	end
	local low, high, total = math.huge, 0, 0
	local from: { Vector3 } = {}
	for _, step in steps do
		low = math.min(low, step.tier)
		high = math.max(high, step.tier + 1)
		total += step.made
		local removed: { Vector3 } = diff.removed[step.tier] or {}
		for _, pos in removed do
			if #from < MERGE_FROM_POSITIONS and not table.find(from, pos) then
				table.insert(from, pos)
			end
		end
	end
	effect(session, "Merge", {
		fromTier = low,
		toTier = high,
		from = from,
		to = mergeTarget(diff, high),
		auto = true,
		count = total,
		summary = true,
		overflow = true,
	})
end

-- Unit cap ------------------------------------------------------------------------

-- Copies an Economy.addUnitsCapped result into the profile (in place: State shares the table).
local function applyCapped(session: Session, result: Economy.CapResult)
	local units = session.profile.units
	for tier = 1, Economy.MAX_TIER do
		units[tier] = result.units[tier]
	end
end

-- Discovery / rewards ------------------------------------------------------------

-- Marks every owned tier (plus `extra` tiers, e.g. ones a merge passed through)
-- as discovered and announces the newest one.
local function discoverAll(session: Session, extra: { number }?)
	local p = session.profile
	local newest = 0
	local gems = 0
	local found: { number } = {}
	local function mark(tier: number)
		if tier >= 1 and tier <= Economy.MAX_TIER and p.discovered[tier] == 0 then
			p.discovered[tier] = os.time()
			gems += Economy.discoveryGems(tier)
			newest = math.max(newest, tier)
			table.insert(found, tier)
		end
	end
	for _, tier in extra or ({} :: { number }) do
		mark(tier)
	end
	for tier = 1, Economy.MAX_TIER do
		if (p.units[tier] or 0) > 0 then
			mark(tier)
		end
	end
	if newest > 0 then
		p.gems += gems
		table.sort(found)
		notify(session, { kind = "Reward", tier = newest, tiers = found, new = true, gems = gems })
	end
end

local function stepTiers(steps: { Economy.MergeStep }, base: { number }?): { number }
	local tiers = table.clone(base or {})
	for _, step in steps do
		table.insert(tiers, step.tier)
		table.insert(tiers, step.tier + 1)
	end
	return tiers
end

local function autoMergeIfOn(session: Session): { Economy.MergeStep }
	if session.profile.autoMerge then
		local _, _, steps = Economy.mergeAll(session.profile.units)
		return steps
	end
	return {}
end

-- Gives one unit (crate rewards). At the unit cap the lowest pair merges first; the unit is
-- refused only when nothing at all can merge (see Economy.addUnitsCapped).
local function awardUnit(session: Session, tier: number, source: string)
	local p = session.profile
	local isNew = p.discovered[tier] == 0
	local fit = Economy.addUnitsCapped(p.units, tier, 1)
	if fit.accepted == 0 then
		toast(session, string.format("Your rack is full! (%d %s max)", Economy.UNIT_CAP, theme.Words.Units), "bad")
		return
	end
	applyCapped(session, fit)
	p.totalObtained += 1
	local steps = autoMergeIfOn(session)
	local diff = refreshDisplay(session)
	sendOverflowEffect(session, fit.steps, diff)
	sendMergeEffects(session, steps, true, diff)
	if not isNew then
		notify(session, { kind = "Reward", tier = tier, new = false, source = source })
	end
	discoverAll(session, stepTiers(steps, stepTiers(fit.steps, { tier })))
	markDirty(session)
end

-- Crates --------------------------------------------------------------------------

-- Defined with the state code below; crate prompts push state right away.
local flush: (session: Session) -> ()

local function rootPart(session: Session): BasePart?
	local character = session.player.Character
	return character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
end

-- Over the orb pen (walls included)? Pads never fire from there and orbs can
-- only be collected from there (crates land in the pen and are grabbed anywhere).
-- Returns (overPool, inPool) for a world position.
local function poolState(plot: Plot, pos: Vector3): (boolean, boolean)
	local localPos = plot.cframe:PointToObjectSpace(pos)
	local pool = plot.pool
	local overPool = localPos.X >= pool.minX and localPos.X <= pool.maxX and localPos.Z >= pool.minZ and localPos.Z <= pool.maxZ
	return overPool, overPool and localPos.Y < plot.orbFloorY + POOL_REACH_Y
end

local function buildChest(rarity: string): Model
	local c = theme.Colors
	local model = Instance.new("Model")
	model.Name = rarity .. "Crate"
	local rarityColor = c.Rarity[rarity]
	local function piece(name: string, size: Vector3, offset: CFrame, color: Color3, material: Enum.Material): Part
		local p = Instance.new("Part")
		p.Name = name
		p.Size = size
		p.CFrame = offset
		p.Color = color
		p.Material = material
		p.Anchored = true
		p.CanCollide = false
		p.CanQuery = false
		p.CanTouch = false
		p.TopSurface = Enum.SurfaceType.Smooth
		p.BottomSurface = Enum.SurfaceType.Smooth
		p.Parent = model
		return p
	end
	local wood = Color3.fromRGB(130, 85, 45):Lerp(rarityColor, if rarity == "Common" then 0 else 0.35)
	local body = piece("Body", Vector3.new(3.4, 2.2, 2.4), CFrame.new(0, 1.1, 0), wood, Enum.Material.WoodPlanks)
	-- The Blender crate (warm wood, gold lock on the -Z front) stands on the model origin; the
	-- invisible Body keeps the pivot, prompt and sparkles. Rarity-coloured straps cover its
	-- white corner bands, so every rarity reads at a glance (Fx.Crates adds a rarity chip
	-- client-side when the player comes close).
	local mesh = Props.mesh("Crate", CFrame.new(), 1, model)
	if mesh then
		body.Transparency = 1
		for _, x in { -1.36, 1.36 } do
			piece("Band", Vector3.new(0.46, 2.68, 2.78), CFrame.new(x, 1.46, 0.07), rarityColor, Enum.Material.SmoothPlastic)
		end
	else
		piece("Lid", Vector3.new(3.6, 0.6, 2.6), CFrame.new(0, 2.5, 0), wood:Lerp(Color3.new(0, 0, 0), 0.15), Enum.Material.WoodPlanks)
		for _, x in { -1.45, 1.45 } do
			piece(
				"Band",
				Vector3.new(0.3, 2.9, 2.7),
				CFrame.new(x, 1.45, 0),
				rarityColor,
				if rarity == "Common" then Enum.Material.Metal else Enum.Material.SmoothPlastic
			)
		end
		piece("Lock", Vector3.new(0.6, 0.7, 0.25), CFrame.new(0, 2, -1.3), Color3.fromRGB(255, 205, 60), Enum.Material.Metal)
	end
	model.PrimaryPart = body

	if rarity ~= "Common" then
		local sparkles = Instance.new("Sparkles")
		sparkles.SparkleColor = rarityColor
		sparkles.Parent = body
	end
	return model
end

local function removeHeldModel(session: Session)
	if session.heldModel then
		session.heldModel:Destroy()
		session.heldModel = nil
	end
end

local function attachHeldModel(session: Session)
	removeHeldModel(session)
	local rarity = session.profile.heldChest
	if rarity == "" then
		return
	end
	local character = session.player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not character or not root then
		return
	end
	local model = buildChest(rarity)
	model:PivotTo(root.CFrame * CFrame.new(0, 0.6, -2.4))
	local primary = model.PrimaryPart :: BasePart
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then
			d.Anchored = false
			d.Massless = true
			d.CanCollide = false
			if d ~= primary then
				local weld = Instance.new("WeldConstraint")
				weld.Part0 = primary
				weld.Part1 = d
				weld.Parent = d
			end
		end
	end
	local weld = Instance.new("WeldConstraint")
	weld.Part0 = root
	weld.Part1 = primary
	weld.Parent = primary
	model.Parent = character
	session.heldModel = model
end

-- Releasing the held crate re-arms the automatic pickup: nothing for CratePickup.REARM
-- seconds, and crates in range right now wait until the player has left their range.
local function clearHeld(session: Session)
	session.profile.heldChest = ""
	removeHeldModel(session)
	session.crateRearmUntil = os.clock() + CratePickup.REARM
	local root = rootPart(session)
	for _, chest in session.floorChests do
		local offset = if root then chest.position - root.Position else nil
		chest.blocked = offset ~= nil and CratePickup.inRange(offset.X, offset.Y, offset.Z)
	end
	markDirty(session)
end

local function pickUpChest(session: Session, chest: FloorChest)
	local index = table.find(session.floorChests, chest)
	if not index or not session.alive then
		return
	end
	if session.profile.heldChest ~= "" then
		toast(session, "You're already carrying a " .. theme.Words.Chest .. "!", "info")
		return
	end
	if not rootPart(session) then
		return
	end
	chest.model:Destroy()
	table.remove(session.floorChests, index)
	session.profile.heldChest = chest.rarity
	attachHeldModel(session)
	effect(session, "ChestPickup", { rarity = chest.rarity })
	markDirty(session)
	flush(session)
end

-- The displayed unit that drops the next crate: the higher tier of two random picks, so
-- better units drop crates a little more often. Returns its pivot (feet) or nil.
local function crateSource(session: Session): Vector3?
	local shown: { DisplaySlot } = {}
	for slotIndex = 1, Economy.DISPLAY_SLOTS do
		local slot = session.display[slotIndex]
		if slot and slot.model.Parent then
			table.insert(shown, slot)
		end
	end
	if #shown == 0 then
		return nil
	end
	local a = shown[rng:NextInteger(1, #shown)]
	local b = shown[rng:NextInteger(1, #shown)]
	local pick = if b.tier > a.tier then b else a
	return pick.model:GetPivot().Position
end

-- What each waypoint of a Layout.orbPath / Layout.cratePath route is (clients read it as
-- <prefix>Kinds; Fx.Orbs.readRoute infers the roles when it is missing or does not match).
local ROUTE_KINDS = "feet,drop,gutter,chuteTop,chuteBottom,land"
local ROUTE_KIND_COUNT = #string.split(ROUTE_KINDS, ",")

-- A unit on the ledge drops a crate: it slides down the gutter and chute like an orb and
-- lands in the front half of the pen. The server places it anchored on its landing spot
-- with `Origin` (the dropping unit's feet) and the route Path1..PathN + PathCount + PathKinds
-- (world-space crate-pivot waypoints, see Layout.cratePath); Fx.Crates animates the trip.
-- It can be picked up (by walking to it, see crateTick) once CratePickup.landTime has passed.
local function spawnFloorChest(session: Session)
	if #session.floorChests >= Economy.MAX_FLOOR_CHESTS then
		return
	end
	local plot = session.plot
	-- A landing spot in the pen's crate zone, clear of the other crates.
	local localPos: Vector3? = nil
	for _ = 1, CHEST_SPOT_TRIES do
		local area = plot.chestAreas[rng:NextInteger(1, #plot.chestAreas)]
		local candidate = Vector3.new(rng:NextNumber(area.minX, area.maxX), 0, rng:NextNumber(area.minZ, area.maxZ))
		local clear = true
		for _, other in session.floorChests do
			local offset = plot.cframe:PointToObjectSpace(other.position) - candidate
			if Vector2.new(offset.X, offset.Z).Magnitude < CHEST_SPACING then
				clear = false
				break
			end
		end
		if clear then
			localPos = candidate
			break
		end
	end
	if not localPos then
		return
	end
	local rarity = Economy.rollChestRarity(random)
	local landY = Layout.PEN.floorY + Layout.CRATE_LIFT
	local world0 = plot.cframe * CFrame.new(localPos.X, landY, localPos.Z) * CFrame.Angles(0, rng:NextNumber(0, math.pi * 2), 0)

	-- The route from the dropping unit (or the middle of the ledge when none is shown).
	local origin = crateSource(session)
	local from = if origin then plot.cframe:PointToObjectSpace(origin) else Vector3.new(0, 0, Layout.SHELF.firstZ)
	local route = Layout.cratePath(from.X, from.Z, localPos.X, localPos.Z, landY)
	if not origin then
		local p = route[1]
		origin = plot.cframe:PointToWorldSpace(Vector3.new(p.x, p.y - Layout.CRATE_LIFT, p.z))
	end

	local model = buildChest(rarity)
	model:PivotTo(world0)
	model:SetAttribute("Rarity", rarity)
	model:SetAttribute("Origin", origin)
	for i, p in route do
		model:SetAttribute("Path" .. i, plot.cframe:PointToWorldSpace(Vector3.new(p.x, p.y, p.z)))
	end
	model:SetAttribute("PathCount", #route)
	model:SetAttribute("PathKinds", if #route == ROUTE_KIND_COUNT then ROUTE_KINDS else nil)
	local length = 0
	for i = 2, #route do
		local p, q = route[i - 1], route[i]
		length += Vector3.new(q.x - p.x, q.y - p.y, q.z - p.z).Magnitude
	end
	local chest: FloorChest = {
		model = model,
		rarity = rarity,
		position = world0.Position,
		landsAt = os.clock() + CratePickup.landTime(length),
		blocked = false,
	}
	model.Parent = plot.chestFolder
	table.insert(session.floorChests, chest)
	if rarity ~= "Common" then
		toast(session, string.format("A %s %s is on its way!", rarity, theme.Words.Chest), "good")
	end
end

local function openChest(session: Session, rarity: string, source: string)
	local tier = Economy.rollChest(rarity, highestTier(session), random)
	awardUnit(session, tier, source)
	effect(session, "ChestOpen", { rarity = rarity, tier = tier })
end

-- Orbs ------------------------------------------------------------------------------

-- Units on the display ledge drop orbs that roll down the gutter and chute into
-- the pen in front of them. The server only places the orb at its landing spot;
-- clients animate the trip (`Origin` and the waypoint attributes), the bob, feed
-- pulses and the pickup magnet.
-- Returns (origin above the unit, the unit's feet, its tier) for a random displayed unit.
local function orbSource(session: Session): (Vector3?, Vector3?, number?)
	local count = 0
	for slotIndex = 1, Economy.DISPLAY_SLOTS do
		if session.display[slotIndex] then
			count = slotIndex
		end
	end
	if count == 0 then
		return nil, nil, nil
	end
	local slot = session.display[rng:NextInteger(1, count)]
	if not slot then
		return nil, nil, nil
	end
	local pivot = slot.model:GetPivot()
	return (pivot * CFrame.new(0, 4, 0)).Position, pivot.Position, slot.tier
end

-- World-space orb-centre waypoints from a unit's feet to `landing` (see Layout.orbPath).
local function orbRoute(session: Session, feet: Vector3?, landing: Vector3): { Vector3 }?
	if not feet then
		return nil
	end
	local cf = session.plot.cframe
	local from = cf:PointToObjectSpace(feet)
	local to = cf:PointToObjectSpace(landing)
	local out: { Vector3 } = {}
	for _, p in Layout.orbPath(from.X, from.Z, to.X, to.Z, to.Y) do
		table.insert(out, cf:PointToWorldSpace(Vector3.new(p.x, p.y, p.z)))
	end
	return out
end

-- Stores a route as Vector3 attributes <prefix>1..<prefix>N, <prefix>Count and <prefix>Kinds.
local function setRoute(inst: Instance, prefix: string, route: { Vector3 }?)
	if not route then
		return
	end
	for i, point in route do
		inst:SetAttribute(prefix .. i, point)
	end
	inst:SetAttribute(prefix .. "Count", #route)
	inst:SetAttribute(prefix .. "Kinds", if #route == ROUTE_KIND_COUNT then ROUTE_KINDS else nil)
end

-- Paint colour of an orb produced by a unit of `tier` (Theme.OrbColors, cycled by tier).
local function orbTint(tier: number?): Color3
	local palette = theme.OrbColors
	if palette and #palette > 0 then
		return OrbLook.tierColor(tier, palette)
	end
	return theme.Colors.Orb
end

-- Pile grid (plot-local): floor slot centres on a PILE_SPACING grid centred in the orb area.
type PileGrid = { cols: number, rows: number, x0: number, z0: number, focusX: number, focusZ: number }

local function pileGrid(area: { minX: number, maxX: number, minZ: number, maxZ: number }): PileGrid
	local cols = math.floor((area.maxX - area.minX) / PILE_SPACING) + 1
	local rows = math.floor((area.maxZ - area.minZ) / PILE_SPACING) + 1
	local cx, cz = (area.minX + area.maxX) / 2, (area.minZ + area.maxZ) / 2
	return {
		cols = cols,
		rows = rows,
		x0 = cx - (cols - 1) * PILE_SPACING / 2,
		z0 = cz - (rows - 1) * PILE_SPACING / 2,
		-- The heap gathers a little toward the chute mouth (the pen's back, +Z).
		focusX = cx,
		focusZ = cz + 1.5,
	}
end

local function floorCell(g: PileGrid, col: number, row: number): number
	return (row - 1) * g.cols + col
end

-- The four floor cells a top-layer cell rests on.
local function topSupports(g: PileGrid, cell: number): (number, number, number, number)
	local k = cell - PILE_TOP - 1
	local col, row = k % (g.cols - 1) + 1, k // (g.cols - 1) + 1
	return floorCell(g, col, row), floorCell(g, col + 1, row), floorCell(g, col, row + 1), floorCell(g, col + 1, row + 1)
end

-- Plot-local centres of the occupied pile cells, and how many orbs sit on the floor.
local function pileTaken(session: Session): ({ [number]: Vector3 }, number)
	local cf = session.plot.cframe
	local taken: { [number]: Vector3 } = {}
	local floorCount = 0
	for _, orb in session.orbs do
		taken[orb.cell] = cf:PointToObjectSpace(orb.part.CFrame.Position)
		if orb.cell < PILE_TOP then
			floorCount += 1
		end
	end
	return taken, floorCount
end

-- Picks a free pile cell: floor cells near the focus first (with random scatter so the heap
-- looks natural), and once the floor is crowded sometimes a hollow on top of four floor orbs.
-- Returns (cell, world landing CFrame), or nil when the pile has no room.
local function orbLanding(session: Session): (number?, CFrame?)
	local plot = session.plot
	local g = pileGrid(plot.orbArea)
	local r = ORB_SIZE / 2
	local restY = plot.orbFloorY + r
	local taken, floorCount = pileTaken(session)

	if floorCount >= PILE_TOP_FROM and rng:NextNumber() < PILE_TOP_CHANCE then
		local best: number?, bestScore, bestPos = nil, math.huge, Vector3.zero
		for k = 1, (g.cols - 1) * (g.rows - 1) do
			local cell = PILE_TOP + k
			if taken[cell] then
				continue
			end
			local a, b, c, d = topSupports(g, cell)
			local pa, pb, pc, pd = taken[a], taken[b], taken[c], taken[d]
			if not (pa and pb and pc and pd) then
				continue
			end
			local x, z = (pa.X + pb.X + pc.X + pd.X) / 4, (pa.Z + pb.Z + pc.Z + pd.Z) / 4
			local score = math.sqrt((x - g.focusX) ^ 2 + (z - g.focusZ) ^ 2) + rng:NextNumber(0, PILE_SCATTER)
			if score < bestScore then
				-- Rest in the hollow: high enough to clear every support.
				local lift = 0
				for _, sp in { pa, pb, pc, pd } do
					local h2 = (sp.X - x) ^ 2 + (sp.Z - z) ^ 2
					lift = math.max(lift, math.sqrt(math.max(0, ORB_SIZE * ORB_SIZE - h2)))
				end
				best, bestScore, bestPos = cell, score, Vector3.new(x, restY + lift, z)
			end
		end
		if best then
			return best, plot.cframe * CFrame.new(bestPos)
		end
	end

	local best: number?, bestScore, bestPos = nil, math.huge, Vector3.zero
	for row = 1, g.rows do
		for col = 1, g.cols do
			local cell = floorCell(g, col, row)
			if taken[cell] then
				continue
			end
			local x, z = g.x0 + (col - 1) * PILE_SPACING, g.z0 + (row - 1) * PILE_SPACING
			local score = math.sqrt((x - g.focusX) ^ 2 + (z - g.focusZ) ^ 2) + rng:NextNumber(0, PILE_SCATTER)
			if score < bestScore then
				local jx, jz = rng:NextNumber(-PILE_JITTER, PILE_JITTER), rng:NextNumber(-PILE_JITTER, PILE_JITTER)
				best, bestScore, bestPos = cell, score, Vector3.new(x + jx, restY, z + jz)
			end
		end
	end
	if best then
		return best, plot.cframe * CFrame.new(bestPos)
	end
	return nil, nil
end

-- True while every floor orb under a top-layer cell is still there.
local function orbSupported(session: Session, cell: number, taken: { [number]: Vector3 }): boolean
	if cell < PILE_TOP then
		return true
	end
	local a, b, c, d = topSupports(pileGrid(session.plot.orbArea), cell)
	return taken[a] ~= nil and taken[b] ~= nil and taken[c] ~= nil and taken[d] ~= nil
end

-- Auto Aura: the orb is collected once its roll-in (an upper bound of the client's timing for
-- this route, including the chute queue) has landed and rested OrbLook.SETTLE seconds.
local function scheduleAuto(session: Session, orb: Orb, origin: Vector3?, route: { Vector3 }?)
	if not session.passes.AutoLoot then
		return
	end
	local length = 0
	local last = origin
	local points: { Vector3 } = route or {}
	for _, point in points do
		if last then
			length += (point - last).Magnitude
		end
		last = point
	end
	orb.due = math.max(orb.due or 0, os.clock() + OrbLook.autoCollectDelay(length, 2.5))
end

local function spawnOrb(session: Session, value: number, cell: number, target: CFrame, origin: Vector3?, route: { Vector3 }?, tier: number?)
	local plot = session.plot
	local tint = orbTint(tier)
	local part = Instance.new("Part")
	part.Name = "Orb"
	part.Shape = Enum.PartType.Ball
	part.Size = Vector3.new(ORB_SIZE, ORB_SIZE, ORB_SIZE)
	part.Material = Enum.Material.SmoothPlastic
	part.Color = tint
	part.CastShadow = false
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CFrame = target
	if origin then
		part:SetAttribute("Origin", origin)
	end
	setRoute(part, "Path", route)
	part:SetAttribute("Value", value)
	part:SetAttribute("Count", 1)
	part:SetAttribute("Tier", tier or 1)
	part:SetAttribute("Tint", tint)
	-- Centre height of an orb resting on the pen floor (clients roll orbs along it).
	part:SetAttribute("RestY", (plot.cframe * CFrame.new(0, plot.orbFloorY + ORB_SIZE / 2, 0)).Position.Y)
	part:SetAttribute("Spawned", serverNow())
	part.Parent = plot.orbFolder
	local orb: Orb = { part = part, value = value, count = 1, cell = cell, tier = tier or 1 }
	scheduleAuto(session, orb, origin, route)
	table.insert(session.orbs, orb)
end

-- Adds a produced orb to an existing ball (the pen is full): its value joins the ball, Count
-- goes up by one and Feed/FeedFrom/FeedPath/FeedTint tell clients to roll the orb in from the
-- unit and let it vanish into the ball. The ball keeps its own colour.
local function feedOrb(session: Session, orb: Orb, value: number, origin: Vector3?, route: { Vector3 }?, tier: number?)
	orb.value += value
	orb.count += 1
	local part = orb.part
	part:SetAttribute("Value", orb.value)
	part:SetAttribute("Count", orb.count)
	if origin then
		part:SetAttribute("FeedFrom", origin)
	end
	setRoute(part, "FeedPath", route)
	part:SetAttribute("FeedTint", orbTint(tier))
	if not orb.windup then
		scheduleAuto(session, orb, origin, route)
	end
	part:SetAttribute("Feed", ((part:GetAttribute("Feed") :: number?) or 0) + 1)
end

-- The ball a produced orb joins once the pen is full (balls about to be auto-collected are
-- skipped while others remain).
local function feedTargetOrb(session: Session, tier: number?, cap: number): Orb?
	local candidates: { Orb } = {}
	for _, orb in session.orbs do
		if not orb.windup then
			table.insert(candidates, orb)
		end
	end
	if #candidates == 0 then
		candidates = session.orbs
	end
	local balls: { OrbLook.Ball } = table.create(#candidates)
	for i, orb in candidates do
		balls[i] = { tier = orb.tier, count = orb.count }
	end
	local index = OrbLook.feedTarget(balls, tier, math.min(cap, #balls), rng:NextNumber())
	return if index then candidates[index] else nil
end

local function produceOrbs(session: Session, amount: number)
	if amount <= 0 then
		return
	end
	local pieces = if amount >= 4 then 2 else 1
	for _ = 1, pieces do
		local value = amount / pieces
		local origin, feet, tier = orbSource(session)
		local cell, target = nil, nil
		if #session.orbs < OrbLook.CAP then
			cell, target = orbLanding(session)
		end
		if cell and target then
			spawnOrb(session, value, cell, target, origin, orbRoute(session, feet, target.Position), tier)
		else
			-- Pen full (or no free slot): the orb joins an existing ball and its Count goes up.
			local orb = feedTargetOrb(session, tier, #session.orbs)
			if orb then
				feedOrb(session, orb, value, origin, orbRoute(session, feet, orb.part.CFrame.Position), tier)
			end
		end
	end
end

local function clearOrbs(session: Session)
	for _, orb in session.orbs do
		orb.part:Destroy()
	end
	table.clear(session.orbs)
end

-- Pads ---------------------------------------------------------------------------------

local padHandlers: { [string]: (Session) -> () } = {}

local function padPos(session: Session, name: string): Vector3?
	local pad = session.plot.padByName[name]
	return pad and pad.part.Position
end

-- Where deposited orbs enter the converter (falls back to the deposit pad).
local function converterPos(session: Session): Vector3
	if session.converterPos then
		return session.converterPos
	end
	local part = session.plot.folder:FindFirstChild("ConverterIntake", true) or session.plot.folder:FindFirstChild("ConverterCore", true)
	local pos = if part and part:IsA("BasePart") then part.Position else padPos(session, "Deposit") or session.plot.cframe.Position
	session.converterPos = pos
	return pos
end

-- Buys up to `amount` units at the current buy tier. Past the unit cap the lowest pairs
-- merge to make room (Economy.addUnitsCapped); units that still do not fit are not bought
-- and not charged.
local function buy(session: Session, amount: number)
	local p = session.profile
	local padName = "Buy" .. amount
	local tier = p.buyTier
	local fit = Economy.addUnitsCapped(p.units, tier, amount)
	local bought = fit.accepted
	if bought == 0 then
		toast(session, string.format("Your rack is full! (%d %s max)", Economy.UNIT_CAP, theme.Words.Units), "bad")
		refusePad(session, padName, "locked")
		return
	end
	local cost = Economy.bulkPrice(p.buyTier, p.boughtAtTier, bought)
	if not spend(session, cost, padName) then
		return
	end
	applyCapped(session, fit)
	p.boughtAtTier += bought
	p.totalObtained += bought
	local steps = autoMergeIfOn(session)
	local diff = refreshDisplay(session)
	effect(session, "Buy", { amount = bought, tier = tier, cost = cost, padPos = padPos(session, padName) })
	sendOverflowEffect(session, fit.steps, diff)
	sendMergeEffects(session, steps, true, diff)
	discoverAll(session, stepTiers(steps, stepTiers(fit.steps, { tier })))
	if bought < amount then
		toast(session, string.format("Rack full: bought %d of %d", bought, amount), "info")
	end
	emit(session, "Buy", { amount = bought })
	markDirty(session)
end

for _, amount in Economy.BUY_AMOUNTS do
	padHandlers["Buy" .. amount] = function(session)
		buy(session, amount)
	end
end

local function doMerge(session: Session, verbose: boolean, auto: boolean)
	local p = session.profile
	local merges, top, steps = Economy.mergeAll(p.units)
	if merges > 0 then
		local diff = refreshDisplay(session)
		sendMergeEffects(session, steps, auto, diff)
		discoverAll(session, stepTiers(steps))
		emit(session, "Merge", { merges = merges, top = top })
		if verbose then
			toast(session, string.format("Merged %s times! Best: %s", Format.short(merges), tierName(top)), "good")
		end
		markDirty(session)
	elseif verbose then
		toast(session, "Nothing to merge yet. You need 2 of the same tier.", "info")
		refusePad(session, "Merge", "locked")
	end
end

padHandlers.Merge = function(session)
	doMerge(session, true, false)
end

padHandlers.AutoMerge = function(session)
	local p = session.profile
	if not p.autoMergeOwned then
		if spend(session, Economy.AUTO_MERGE_COST, "AutoMerge") then
			p.autoMergeOwned = true
			p.autoMerge = true
			effect(session, "Upgrade", { pad = "AutoMerge", padPos = padPos(session, "AutoMerge") })
			doMerge(session, false, true)
			toast(session, "Auto Merge unlocked and ON!", "good")
			markDirty(session)
		end
		return
	end
	p.autoMerge = not p.autoMerge
	if p.autoMerge then
		doMerge(session, false, true)
	end
	toast(session, "Auto Merge " .. (if p.autoMerge then "ON" else "OFF"), "info")
	markDirty(session)
end

padHandlers.BuyTier = function(session)
	local p = session.profile
	if p.buyTier >= Economy.MAX_BUY_TIER then
		toast(session, "Buy tier is maxed out!", "info")
		refusePad(session, "BuyTier", "locked")
		return
	end
	local req = Economy.buyTierRequirement(p.buyTier)
	if p.boughtAtTier < req then
		toast(session, string.format("Buy %s more %s first!", Format.short(req - p.boughtAtTier), theme.Words.Units), "bad")
		refusePad(session, "BuyTier", "locked")
		return
	end
	if not spend(session, Economy.buyTierUpgradeCost(p.buyTier), "BuyTier") then
		return
	end
	p.buyTier += 1
	p.boughtAtTier = 0
	toast(session, "You now buy " .. tierName(p.buyTier) .. "!", "good")
	effect(session, "Upgrade", { pad = "BuyTier", padPos = padPos(session, "BuyTier"), level = p.buyTier })
	markDirty(session)
end

padHandlers.Deposit = function(session)
	local p = session.profile
	if p.carried <= 0 then
		toast(session, "Your tank is empty! Walk over " .. theme.Words.Orb .. " orbs first.", "info")
		refusePad(session, "Deposit", "locked")
		return
	end
	local mult = ReplicatedStorage:GetAttribute("DepositMult") or 1
	local amount = p.carried * mult
	p.queue += amount
	p.carried = 0
	local root = rootPart(session)
	local to = converterPos(session)
	effect(session, "Deposit", { amount = amount, mult = mult, from = if root then root.Position else to, to = to })
	emit(session, "Deposit", { amount = amount })
	markDirty(session)
end

padHandlers.Collect = function(session)
	local p = session.profile
	if p.pending < 1 then
		toast(session, "No cash ready yet. Deposit " .. theme.Words.Orb .. " first!", "info")
		refusePad(session, "Collect", "locked")
		return
	end
	local amount = p.pending
	addMoney(session, amount)
	p.pending = 0
	effect(session, "Cash", { amount = amount, source = "Collect", padPos = padPos(session, "Collect") })
	emit(session, "Cash", { amount = amount })
	markDirty(session)
end

local function procUpgrade(session: Session, amount: number, padName: string)
	local p = session.profile
	if spend(session, Economy.processBulkCost(p.processLevel, amount), padName) then
		p.processLevel += amount
		effect(session, "Upgrade", { pad = padName, padPos = padPos(session, padName), level = p.processLevel })
		markDirty(session)
	end
end
padHandlers.ProcUp1 = function(session)
	procUpgrade(session, 1, "ProcUp1")
end
padHandlers.ProcUp10 = function(session)
	procUpgrade(session, Economy.PROCESS_BULK, "ProcUp10")
end

local function useUnlocker(session: Session, slotIndex: number)
	local p = session.profile
	if slotIndex == 2 and not session.passes.PremiumUnlocker then
		refusePad(session, "Unlock2", "locked")
		Tycoon.hooks.promptPass(session.player, "PremiumUnlocker")
		return
	end
	local slot = p.unlockers[slotIndex]
	if slot.rarity ~= "" then
		local left = slot.endsAt - os.time()
		if left <= 0 then
			local rarity = slot.rarity
			slot.rarity = ""
			slot.endsAt = 0
			openChest(session, rarity, "unlocker")
		else
			local cost = Economy.finishGemCost(left)
			notify(session, {
				kind = "Confirm",
				text = string.format("Finish now for %d %s?", cost, theme.Icons.Gem),
				action = { action = "FinishUnlocker", slot = slotIndex },
			})
		end
		markDirty(session)
		return
	end
	if p.heldChest == "" then
		toast(session, "Bring a " .. theme.Words.Chest .. " here to open it for free over time.", "info")
		refusePad(session, "Unlock" .. slotIndex, "locked")
		return
	end
	slot.rarity = p.heldChest
	slot.endsAt = os.time() + Economy.unlockSeconds(p.heldChest, slotIndex == 2)
	clearHeld(session)
	toast(session, "Unlocking... come back when the timer ends!", "good")
	markDirty(session)
end
padHandlers.Unlock1 = function(session)
	useUnlocker(session, 1)
end
padHandlers.Unlock2 = function(session)
	useUnlocker(session, 2)
end

padHandlers.Free = function(session)
	local p = session.profile
	local left = p.lastFreeReward + Economy.FREE_REWARD_COOLDOWN - os.time()
	if left > 0 then
		toast(session, "Next free reward in " .. Format.time(left), "info")
		refusePad(session, "Free", "locked")
		return
	end
	local cash = math.max(Economy.FREE_REWARD_MIN, Tycoon.income(session) * Economy.FREE_REWARD_SECONDS)
	addMoney(session, cash)
	p.gems += Economy.FREE_REWARD_GEMS
	p.lastFreeReward = os.time()
	toast(session, string.format("Free reward: +%s and +%d %s", Format.money(cash), Economy.FREE_REWARD_GEMS, theme.Icons.Gem), "good")
	effect(session, "Cash", { amount = cash, source = "Free", padPos = padPos(session, "Free") })
	markDirty(session)
end

-- Boards ------------------------------------------------------------------------------

local function setPad(session: Session, name: string, title: string?, sub: string, affordable: boolean?)
	local pad = session.plot.padByName[name]
	if not pad then
		return
	end
	if title then
		pad.title.Text = title
	end
	pad.sub.Text = sub
	if affordable ~= nil then
		pad.sub.TextColor3 = if affordable then theme.Colors.Good else theme.Colors.Bad
	end
end

local function updateBoards(session: Session)
	local p = session.profile
	local labels = session.plot.labels
	local now = os.time()

	for _, amount in Economy.BUY_AMOUNTS do
		local cost = Economy.bulkPrice(p.buyTier, p.boughtAtTier, amount)
		setPad(session, "Buy" .. amount, "Buy " .. amount .. " " .. tierName(p.buyTier), Format.money(cost), canAfford(session, cost))
	end

	if p.autoMergeOwned then
		setPad(session, "AutoMerge", "Auto Merge", if p.autoMerge then "ON" else "OFF", p.autoMerge)
	else
		setPad(session, "AutoMerge", "Auto Merge", Format.money(Economy.AUTO_MERGE_COST), canAfford(session, Economy.AUTO_MERGE_COST))
	end

	if p.buyTier >= Economy.MAX_BUY_TIER then
		labels.BuyTierFromTo.Text = tierName(p.buyTier)
		labels.BuyTierProgress.Text = "MAXED"
		labels.BuyTierCost.Text = ""
		setPad(session, "BuyTier", nil, "MAX", true)
	else
		local req = Economy.buyTierRequirement(p.buyTier)
		local cost = Economy.buyTierUpgradeCost(p.buyTier)
		labels.BuyTierFromTo.Text = tierName(p.buyTier) .. "  >>  " .. tierName(p.buyTier + 1)
		labels.BuyTierProgress.Text =
			string.format("%s %s / %s", theme.Icons.Unit, Format.short(math.min(p.boughtAtTier, req)), Format.short(req))
		labels.BuyTierCost.Text = Format.money(cost)
		setPad(session, "BuyTier", nil, Format.money(cost), p.boughtAtTier >= req and canAfford(session, cost))
	end

	local procCost = Economy.processUpgradeCost(p.processLevel)
	local procBulk = Economy.processBulkCost(p.processLevel, Economy.PROCESS_BULK)
	local rateNow = Economy.processRate(p.processLevel)
	local growth = Economy.PROCESS_GROWTH
	setPad(
		session,
		"ProcUp1",
		string.format("+%d%% speed", math.floor((growth - 1) * 100 + 0.5)),
		Format.money(procCost),
		canAfford(session, procCost)
	)
	setPad(
		session,
		"ProcUp10",
		string.format("+%.1fx speed", growth ^ Economy.PROCESS_BULK),
		Format.money(procBulk),
		canAfford(session, procBulk)
	)

	local moneyMult = Tycoon.moneyMultiplier(session)
	labels.ProcessQueue.Text = theme.Icons.Orb .. " " .. Format.short(p.queue)
	local cashRate = Format.money(math.min(p.queue, rateNow) * moneyMult) .. " per second"
	labels.ProcessRate.Text = if p.queue > 0 then cashRate .. "  |  Done in " .. Format.time(math.ceil(p.queue / rateNow)) else cashRate
	labels.ProcessSpeed.Text = string.format("Speed: %s %s/sec  (Lv %d)", Format.short(rateNow), theme.Words.Orb, p.processLevel)

	setPad(session, "Collect", nil, Format.money(p.pending), p.pending >= 1)

	local mult = ReplicatedStorage:GetAttribute("DepositMult") or 1
	local nextAt = ReplicatedStorage:GetAttribute("DepositNextAt") or 0
	labels.DepositMult.Text = "x" .. string.format("%.1f", mult)
	labels.DepositMult.TextColor3 = if mult >= 1.2 then theme.Colors.Good elseif mult < 1 then theme.Colors.Bad else theme.Colors.Primary
	labels.DepositNext.Text = "next change in " .. math.max(0, math.ceil(nextAt - serverNow())) .. "s"
	setPad(session, "Deposit", nil, theme.Icons.Orb .. Format.short(p.carried) .. "  x" .. string.format("%.1f", mult), p.carried > 0)

	local freeLeft = p.lastFreeReward + Economy.FREE_REWARD_COOLDOWN - now
	labels.FreeStatus.Text = if freeLeft <= 0 then "READY!" else Format.time(freeLeft)
	labels.FreeStatus.TextColor3 = if freeLeft <= 0 then theme.Colors.Good else theme.Colors.Text
	setPad(session, "Free", nil, if freeLeft <= 0 then "Claim!" else Format.time(freeLeft), freeLeft <= 0)

	for i, screen in session.plot.unlockerScreens do
		local slot = p.unlockers[i]
		local locked = i == 2 and not session.passes.PremiumUnlocker
		if locked then
			screen.status.Text = "🔒 3x faster"
			screen.timer.Text = "UNLOCK"
			setPad(session, "Unlock" .. i, nil, "🔒 Game Pass", false)
		elseif slot.rarity == "" then
			screen.status.Text = "EMPTY"
			screen.timer.Text = "--:--:--"
			setPad(session, "Unlock" .. i, nil, if p.heldChest ~= "" then "Drop crate here" else "Empty", p.heldChest ~= "")
		else
			local left = slot.endsAt - now
			screen.status.Text = slot.rarity .. " " .. theme.Words.Chest
			screen.status.TextColor3 = theme.Colors.Rarity[slot.rarity]
			if left <= 0 then
				screen.timer.Text = "READY!"
				setPad(session, "Unlock" .. i, nil, "Open!", true)
			else
				screen.timer.Text = Format.clock(left)
				setPad(session, "Unlock" .. i, nil, Format.clock(left), false)
			end
		end
	end
end

-- State ------------------------------------------------------------------------------

local function snapshot(session: Session): { [string]: any }
	local p = session.profile
	local now = os.time()
	local unlockers = {}
	for i, slot in p.unlockers do
		unlockers[i] = {
			rarity = slot.rarity,
			secondsLeft = if slot.rarity ~= "" then math.max(0, slot.endsAt - now) else 0,
		}
	end
	local production = Tycoon.production(session)
	local rate = Economy.processRate(p.processLevel)
	local moneyMult = Tycoon.moneyMultiplier(session)
	return {
		now = now,
		money = p.money,
		gems = p.gems,
		carried = p.carried,
		queue = p.queue,
		pending = p.pending,
		units = p.units,
		discovered = p.discovered,
		totalObtained = p.totalObtained,
		-- Units owned right now (all shown on the rack) and the most a player can hold.
		unitTotal = Economy.totalUnits(p.units),
		unitCap = Economy.UNIT_CAP,
		buyTier = p.buyTier,
		boughtAtTier = p.boughtAtTier,
		processLevel = p.processLevel,
		heldChest = p.heldChest,
		crateRobux = Tycoon.hooks.crateRobuxAllowed(session.player),
		highestTier = highestTier(session),
		unlockers = unlockers,
		autoMergeOwned = p.autoMergeOwned,
		autoMerge = p.autoMerge,
		settings = p.settings,
		passes = session.passes,
		premium = session.premium,
		friendBonus = session.friendBonus,
		moneyMult = moneyMult,
		orbMult = Tycoon.orbMultiplier(session),
		production = production,
		processRate = rate,
		income = Economy.incomePerSecond(production, rate, moneyMult),
		freeIn = math.max(0, p.lastFreeReward + Economy.FREE_REWARD_COOLDOWN - now),
		plotIndex = session.plot.index,
		tutorialStep = p.tutorialStep,
		tutorialDone = p.tutorialDone,
		cosmetics = Tycoon.hooks.cosmetics(session),
		modes = Tycoon.hooks.modes(session),
	}
end

local function updateLeaderstats(session: Session)
	local stats = session.player:FindFirstChild("leaderstats")
	if not stats then
		return
	end
	local units = stats:FindFirstChild(theme.Words.Units) :: StringValue?
	local cash = stats:FindFirstChild("Cash") :: StringValue?
	if units then
		units.Value = Format.short(session.profile.totalObtained)
	end
	if cash then
		cash.Value = Format.short(session.profile.money)
	end
end

function flush(session: Session)
	if not session.dirty or not session.alive then
		return
	end
	session.dirty = false
	updateBoards(session)
	updateLeaderstats(session)
	StateRemote:FireClient(session.player, snapshot(session))
end

-- Ticks --------------------------------------------------------------------------------

-- Credits picked-up orbs to the tank: the same path for walking over them and for Auto Aura.
-- `auto` tells the client to play the auto-collect cue instead of the walk-over magnet.
local function creditPicked(session: Session, collected: number, positions: { Vector3 }, counts: { number }, now: number, auto: boolean)
	if collected <= 0 then
		return
	end
	session.profile.carried += collected
	session.collectBuffer += collected
	effect(session, "OrbsPicked", { amount = collected, positions = positions, counts = counts, auto = auto })
	emit(session, "Pickup", { amount = collected })
	markDirty(session)
	if now - session.lastPickupFlush >= PICKUP_FLUSH_INTERVAL then
		session.lastPickupFlush = now
		flush(session)
	end
end

-- Auto Aura: orbs past their `due` time get the "Auto" attribute (the client winds them up),
-- then are collected AUTO_WINDUP later, wherever the player is.
local function autoCollect(session: Session, now: number)
	if not session.passes.AutoLoot or #session.orbs == 0 then
		return
	end
	local values: { number } = {}
	local positions: { Vector3 } = {}
	local counts: { number } = {}
	for i = #session.orbs, 1, -1 do
		local orb = session.orbs[i]
		if orb.due == nil then
			orb.due = now + 0.3 + 0.15 * i -- pass bought with orbs already in the pen
		elseif orb.windup then
			if now - orb.windup >= AUTO_WINDUP then
				table.insert(values, orb.value)
				if #positions < ORB_PICKED_POSITIONS then
					table.insert(positions, orb.part.CFrame.Position)
					table.insert(counts, orb.count)
				end
				orb.part:Destroy()
				table.remove(session.orbs, i)
			end
		elseif now >= orb.due then
			orb.windup = now
			orb.part:SetAttribute("Auto", true)
		end
	end
	creditPicked(session, OrbLook.credit(values), positions, counts, now, true)
end

-- Automatic crate pickup: the plot owner walks to a landed crate in their pen and picks up
-- the nearest one in range (CratePickup.mayPick: not holding one, re-armed after a release).
local function crateTick(session: Session, pos: Vector3, now: number)
	local holding = session.profile.heldChest ~= ""
	local best: FloorChest? = nil
	local bestDist = math.huge
	for _, chest in session.floorChests do
		local offset = chest.position - pos
		local inRange = CratePickup.inRange(offset.X, offset.Y, offset.Z)
		chest.blocked = CratePickup.stillBlocked(chest.blocked, inRange)
		local may = CratePickup.mayPick({
			now = now,
			landsAt = chest.landsAt,
			inRange = inRange,
			holding = holding,
			rearmUntil = session.crateRearmUntil,
			blocked = chest.blocked,
		})
		local dist = Vector2.new(offset.X, offset.Z).Magnitude
		if may and dist < bestDist then
			best, bestDist = chest, dist
		end
	end
	if best then
		pickUpChest(session, best)
	end
end

local function fastTick(session: Session)
	autoCollect(session, os.clock())
	local root = rootPart(session)
	if not root then
		-- Respawning: forget pad visits so a fresh character starts clean.
		table.clear(session.inside)
		return
	end
	local plot = session.plot
	local pos = root.Position
	local localPos = plot.cframe:PointToObjectSpace(pos)
	local overPool, inPool = poolState(plot, pos)

	local now = os.clock()

	-- Pads fire once per visit, the moment the player steps on them; stepping off and
	-- on again fires them again.
	for _, pad in plot.pads do
		local name = pad.name
		local inside = not overPool
			and math.abs(localPos.X - pad.center.X) <= pad.half.X
			and math.abs(localPos.Z - pad.center.Z) <= pad.half.Y
			and localPos.Y > PAD_MIN_Y
			and localPos.Y < PAD_MAX_Y
		if inside then
			if not session.inside[name] then
				session.inside[name] = true
				local handler = padHandlers[name]
				if handler then
					handler(session)
					flush(session)
				end
			end
		else
			session.inside[name] = nil
		end
	end

	-- Orb pickup: only from inside the pen (so standing beside it doesn't
	-- vacuum it), by horizontal distance so jumping still collects.
	local collected = 0
	local positions: { Vector3 } = {}
	local counts: { number } = {}
	local function collect(i: number)
		local orb = session.orbs[i]
		collected += OrbLook.credit({ orb.value })
		if #positions < ORB_PICKED_POSITIONS then
			table.insert(positions, orb.part.CFrame.Position)
			table.insert(counts, orb.count)
		end
		orb.part:Destroy()
		table.remove(session.orbs, i)
	end
	for i = if inPool then #session.orbs else 0, 1, -1 do
		local offset = session.orbs[i].part.CFrame.Position - pos
		if Vector2.new(offset.X, offset.Z).Magnitude <= ORB_PICKUP_RADIUS and math.abs(offset.Y) < 8 then
			collect(i)
		end
	end
	-- Top-layer orbs that lost a floor orb under them tumble into the pickup too.
	if collected > 0 then
		local taken = pileTaken(session)
		for i = #session.orbs, 1, -1 do
			if not orbSupported(session, session.orbs[i].cell, taken) then
				collect(i)
			end
		end
	end
	creditPicked(session, collected, positions, counts, now, false)
	crateTick(session, pos, now)
end

local function slowTick(session: Session)
	local p = session.profile
	local production = Tycoon.production(session)

	produceOrbs(session, production)

	local rate = Economy.processRate(p.processLevel)
	local processed = math.min(p.queue, rate)
	if processed > 0 then
		p.queue -= processed
		p.pending += processed * Economy.CASH_PER_POINT * Tycoon.moneyMultiplier(session)
	end
	if session.passes.AutoCash and p.pending > 0 then
		emit(session, "Cash", { amount = p.pending })
		effect(session, "Cash", { amount = p.pending, source = "Auto" })
		addMoney(session, p.pending)
		p.pending = 0
	end

	session.chestTimer += 1
	if session.chestTimer >= Economy.CHEST_SPAWN_INTERVAL then
		session.chestTimer = 0
		if rng:NextNumber() < Economy.CHEST_SPAWN_CHANCE then
			spawnFloorChest(session)
		end
	end

	if session.collectBuffer > 0 then
		effect(session, "Collect", { amount = session.collectBuffer })
		session.collectBuffer = 0
	end

	-- Re-attach a held crate after respawning.
	if p.heldChest ~= "" and (not session.heldModel or not session.heldModel.Parent) then
		attachHeldModel(session)
	end

	markDirty(session)
	flush(session)
end

local function rerollDeposit()
	ReplicatedStorage:SetAttribute("DepositMult", Economy.rollDepositMultiplier(random))
	ReplicatedStorage:SetAttribute("DepositNextAt", serverNow() + Economy.DEPOSIT_REROLL_SECONDS)
end

-- Actions from the client ---------------------------------------------------------------

local actionHandlers: { [string]: (Session, { [string]: any }) -> () } = {}

-- Opens a held crate of `rarity` right now (Crate Master owners, crate receipts).
local function openCrateNow(session: Session, rarity: string)
	if session.profile.heldChest == rarity then
		clearHeld(session)
	else
		toast(session, string.format("Your %s %s is opening!", rarity, theme.Words.Chest), "good")
	end
	openChest(session, rarity, "unlock")
	markDirty(session)
	flush(session)
end

-- Instant opening of the held crate. Crate Master (pass CrateKey) owners open it
-- free. Everyone else is prompted the single "Open Crate" developer product, which
-- Monetization refuses where paid random items are restricted; that crate is opened
-- only when the receipt arrives (Tycoon.openCrateProduct).
actionHandlers.OpenCrateNow = function(session)
	local rarity = session.profile.heldChest
	if rarity == "" or not Economy.isRarity(rarity) then
		return
	end
	if session.passes.CrateKey then
		openCrateNow(session, rarity)
		return
	end
	Tycoon.hooks.promptCrate(session.player, rarity)
end

actionHandlers.DiscardChest = function(session)
	if session.profile.heldChest ~= "" then
		clearHeld(session)
		toast(session, theme.Words.Chest .. " discarded.", "info")
	end
end

actionHandlers.FinishUnlocker = function(session, data)
	local slotIndex = data.slot
	if slotIndex ~= 1 and slotIndex ~= 2 then
		return
	end
	local slot = session.profile.unlockers[slotIndex]
	if slot.rarity == "" then
		return
	end
	local left = slot.endsAt - os.time()
	if left > 0 and not spendGems(session, Economy.finishGemCost(left)) then
		return
	end
	local rarity = slot.rarity
	slot.rarity = ""
	slot.endsAt = 0
	openChest(session, rarity, "unlocker")
end

actionHandlers.PromptPass = function(session, data)
	if type(data.name) == "string" and theme.Monetization.Passes[data.name] then
		Tycoon.hooks.promptPass(session.player, data.name)
	end
end

actionHandlers.PromptProduct = function(session, data)
	if (data.kind == "Money" or data.kind == "Gems" or data.kind == "Aura") and type(data.index) == "number" then
		Tycoon.hooks.promptProduct(session.player, data.kind, data.index)
	end
end

actionHandlers.SetSetting = function(session, data)
	local p = session.profile
	if data.key == "autoMerge" then
		if p.autoMergeOwned and type(data.value) == "boolean" then
			p.autoMerge = data.value
			if p.autoMerge then
				doMerge(session, false, true)
			end
		elseif not p.autoMergeOwned then
			toast(session, "Unlock Auto Merge on the pad next to the buy pads first.", "info")
		end
	elseif type(data.key) == "string" and type(p.settings[data.key]) == "boolean" and type(data.value) == "boolean" then
		p.settings[data.key] = data.value
	end
	markDirty(session)
end

actionHandlers.Home = function(session)
	local character = session.player.Character
	if character then
		character:PivotTo(session.plot.spawn)
	end
end

-- Sent by the client once its UI is ready; the caller flushes fresh state.
actionHandlers.Sync = function(_session) end

actionHandlers.Merge = function(session)
	doMerge(session, true, false)
end

-- Same as standing on the Free pad (cooldown checked there; the action budget
-- rate-limits the remote).
actionHandlers.ClaimFree = function(session)
	padHandlers.Free(session)
end

-- Lets other server modules (e.g. Tutorial) accept their own client actions.
function Tycoon.addAction(name: string, handler: (Session, { [string]: any }) -> ())
	actionHandlers[name] = handler
end

-- Players ---------------------------------------------------------------------------------

local function freePlot(): number?
	for index = 1, #world.plots do
		if not plotOwners[index] then
			return index
		end
	end
	return nil
end

local function setOwnerSign(plot: Plot, player: Player?)
	if player then
		plot.labels.Owner.Text = player.DisplayName .. "'s " .. (if theme.Id == "chad" then "Gym" else "Factory")
		plot.ownerImage.Image = string.format("rbxthumb://type=AvatarHeadShot&id=%d&w=150&h=150", player.UserId)
	else
		plot.labels.Owner.Text = "EMPTY PLOT"
		plot.ownerImage.Image = ""
		for _, pad in plot.pads do
			pad.sub.Text = ""
		end
		for _, screen in plot.unlockerScreens do
			screen.status.Text = ""
			screen.timer.Text = ""
		end
		-- Clear the previous owner's numbers from the dynamic boards.
		for _, key in
			{
				"BuyTierFromTo",
				"BuyTierProgress",
				"BuyTierCost",
				"ProcessQueue",
				"ProcessRate",
				"ProcessSpeed",
				"FreeStatus",
				"DepositNext",
			}
		do
			local boardLabel = plot.labels[key]
			if boardLabel then
				boardLabel.Text = ""
			end
		end
	end
end

local function refreshFriendBonuses()
	local list = Players:GetPlayers()
	for _, player in list do
		local session = sessions[player]
		if session then
			task.spawn(function()
				local friends = 0
				for _, other in list do
					if other ~= player and other.Parent then
						local ok, isFriend = pcall(player.IsFriendsWith, player, other.UserId)
						if ok and isFriend then
							friends += 1
						end
					end
				end
				session.friendBonus = math.min(friends * Economy.FRIEND_BONUS, Economy.MAX_FRIEND_BONUS)
				markDirty(session)
			end)
		end
	end
end

local function applyOffline(session: Session)
	local p = session.profile
	if p.lastOnline <= 0 then
		return
	end
	local elapsed = math.min(os.time() - p.lastOnline, Economy.OFFLINE_CAP_SECONDS)
	if elapsed < Economy.OFFLINE_MIN_SECONDS then
		return
	end
	local produced = Economy.productionPerSecond(p.units)
		* (if session.passes.DoubleAura then 2 else 1)
		* elapsed
		* Economy.OFFLINE_EFFICIENCY
	p.queue += produced
	local processed = math.min(p.queue, Economy.processRate(p.processLevel) * elapsed)
	p.queue -= processed
	local cash = processed * Economy.CASH_PER_POINT * (if session.passes.DoubleMoney then 2 else 1)
	p.pending += cash
	notify(session, { kind = "Offline", seconds = elapsed, orbs = produced, cash = cash })
end

function Tycoon.addPlayer(player: Player, profile: Profile, canSave: boolean, passes: { [string]: boolean }): Session?
	local index = freePlot()
	if not index then
		player:Kick("This server is full. Please join another server!")
		return nil
	end
	plotOwners[index] = player
	local plot = world.plots[index]

	local session: Session = {
		player = player,
		profile = profile,
		canSave = canSave,
		plot = plot,
		passes = passes,
		premium = player.MembershipType == Enum.MembershipType.Premium,
		friendBonus = 0,
		inside = {},
		converterPos = nil,
		orbs = {},
		floorChests = {},
		heldModel = nil,
		display = {},
		displayCounts = "",
		dirty = true,
		chestTimer = 0,
		collectBuffer = 0,
		actionBudget = ACTIONS_PER_SECOND,
		lastPickupFlush = 0,
		crateRearmUntil = 0,
		lastToast = {},
		alive = true,
	}
	sessions[player] = session

	local leaderstats = Instance.new("Folder")
	leaderstats.Name = "leaderstats"
	local unitsStat = Instance.new("StringValue")
	unitsStat.Name = theme.Words.Units
	unitsStat.Parent = leaderstats
	local cashStat = Instance.new("StringValue")
	cashStat.Name = "Cash"
	cashStat.Parent = leaderstats
	leaderstats.Parent = player

	setOwnerSign(plot, player)
	-- Saves from before the unit cap: merge the lowest pairs until they fit.
	local fit = Economy.addUnitsCapped(profile.units, 1, 0)
	if #fit.steps > 0 then
		applyCapped(session, fit)
		discoverAll(session, stepTiers(fit.steps))
	end
	refreshDisplay(session)
	applyOffline(session)

	local function onCharacter(character: Model)
		local root = character:WaitForChild("HumanoidRootPart", 10)
		if not root or not session.alive then
			return
		end
		task.wait(0.1)
		character:PivotTo(plot.spawn)
		session.heldModel = nil
		attachHeldModel(session)
	end
	player.CharacterAdded:Connect(onCharacter)
	if player.Character then
		task.spawn(onCharacter, player.Character)
	end

	-- Studio-only test hook: a Server script sets the player attribute "DebugGrant" to
	-- "cash,<n>", "gems,<n>", "units,<total>" (Tier 1..5 spread), "pass,<Name>", "crate" or "pickup".
	if RunService:IsStudio() then
		player:GetAttributeChangedSignal("DebugGrant"):Connect(function()
			local kind, arg = string.match(tostring(player:GetAttribute("DebugGrant")), "^(%a+),?(.*)$")
			local n = tonumber(arg) or 0
			if kind == "cash" then
				Tycoon.grantMoney(session, n)
			elseif kind == "gems" then
				Tycoon.grantGems(session, n)
			elseif kind == "units" then
				local units = table.create(Economy.MAX_TIER, 0)
				for i = 0, n - 1 do
					units[i % 5 + 1] += 1
				end
				session.profile.units = units
				discoverAll(session)
				refreshDisplay(session)
			elseif kind == "pass" then
				Tycoon.setPass(player, arg)
			elseif kind == "crate" then
				spawnFloorChest(session)
			elseif kind == "pickup" and session.floorChests[1] then
				pickUpChest(session, session.floorChests[1])
			end
			markDirty(session)
			flush(session)
		end)
	end

	refreshFriendBonuses()
	markDirty(session)
	flush(session)
	return session
end

function Tycoon.removePlayer(player: Player): Session?
	local session = sessions[player]
	if not session then
		return nil
	end
	session.alive = false
	sessions[player] = nil
	plotOwners[session.plot.index] = nil

	clearOrbs(session)
	for _, chest in session.floorChests do
		chest.model:Destroy()
	end
	for _, slot in session.display do
		slot.model:Destroy()
	end
	Shelves.setRows(session.plot.folder, 1)
	removeHeldModel(session)
	setOwnerSign(session.plot, nil)
	refreshFriendBonuses()
	return session
end

function Tycoon.setPass(player: Player, name: string)
	local session = sessions[player]
	if session then
		session.passes[name] = true
		Tycoon.hooks.passGranted(session, name)
		markDirty(session)
		flush(session)
	end
end

-- A paid instant crate open (the single "Open Crate" developer product, any rarity).
-- Opens the held crate if there is one; otherwise (dropped, discarded, rejoined) the
-- player still gets a crate of the rarity recorded when the prompt was issued
-- (profile.pendingCrate), or a Common one, so a purchase always pays out.
function Tycoon.openCrateProduct(session: Session)
	local p = session.profile
	local rarity = p.heldChest
	if not Economy.isRarity(rarity) then
		rarity = if Economy.isRarity(p.pendingCrate) then p.pendingCrate else "Common"
	end
	p.pendingCrate = ""
	openCrateNow(session, rarity)
end

-- Pushes a fresh State snapshot (e.g. after a purchase policy lookup finishes).
function Tycoon.refresh(player: Player)
	local session = sessions[player]
	if session then
		markDirty(session)
		flush(session)
	end
end

function Tycoon.grantMoney(session: Session, amount: number)
	addMoney(session, amount)
	local root = rootPart(session)
	effect(session, "Cash", { amount = amount, source = "Purchase", padPos = root and root.Position })
	markDirty(session)
	flush(session)
end

function Tycoon.grantGems(session: Session, amount: number)
	session.profile.gems += amount
	toast(session, string.format("+%d %s %s", amount, theme.Words.Gem, theme.Icons.Gem), "good")
	markDirty(session)
	flush(session)
end

-- Aura pack: aura straight into the tank, ready for the converter. Not a pickup (no
-- "Pickup" event, so quests and the orb collect counter ignore it); flush refreshes the
-- Deposit pad label (updateBoards) and the HUD tank (State).
function Tycoon.grantAura(session: Session, amount: number)
	session.profile.carried += amount
	toast(session, "+" .. Format.short(amount) .. " " .. string.lower(theme.Words.Orb) .. " in your tank!", "good")
	effect(session, "AuraGrant", { amount = amount })
	markDirty(session)
	flush(session)
end

function Tycoon.init(builtWorld: WorldBuilder.World, themeModule: any)
	world = builtWorld
	theme = themeModule

	NotifyRemote = Net.event("Notify")
	EffectRemote = Net.event("Effect")
	StateRemote = Net.event("State")
	ActionRemote = Net.event("Action")

	rerollDeposit()

	ActionRemote.OnServerEvent:Connect(function(player, data)
		local session = sessions[player]
		if not session or type(data) ~= "table" or type(data.action) ~= "string" then
			return
		end
		if session.actionBudget <= 0 then
			return
		end
		session.actionBudget -= 1
		local handler = actionHandlers[data.action]
		if handler then
			handler(session, data)
			markDirty(session)
			flush(session)
		end
	end)

	task.spawn(function()
		while true do
			task.wait(0.1)
			for _, session in sessions do
				local ok, err = pcall(fastTick, session)
				if not ok then
					warn("[Tycoon] fastTick:", err)
				end
			end
		end
	end)

	task.spawn(function()
		while true do
			task.wait(1)
			if serverNow() >= (ReplicatedStorage:GetAttribute("DepositNextAt") or 0) then
				rerollDeposit()
			end
			for _, session in sessions do
				session.actionBudget = ACTIONS_PER_SECOND
				local ok, err = pcall(slowTick, session)
				if not ok then
					warn("[Tycoon] slowTick:", err)
				end
			end
		end
	end)
end

return Tycoon
