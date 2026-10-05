--[[
	Tycoon: the core game loop for every player.

	One Session per player: owns a plot, the saved profile and all runtime
	objects on that plot (displayed units, orbs, floor crates, the held crate).

	Loops:
	  fast (0.1s)  pad enter detection, orb + crate pickup
	  slow (1s)    production, processing, auto passes, boards, state push
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Economy = require(Shared.Economy)
local Format = require(Shared.Format)
local Net = require(Shared.Net)
local CharacterFactory = require(Shared.CharacterFactory)

local WorldBuilder = require(script.Parent.WorldBuilder)

type Profile = any
type Plot = WorldBuilder.Plot

type Orb = { part: BasePart, label: TextLabel, value: number }
type FloorChest = { model: Model, rarity: string, position: Vector3 }
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
	orbs: { Orb },
	floorChests: { FloorChest },
	heldModel: Model?,
	display: { [number]: DisplaySlot },
	displayCounts: string,
	dirty: boolean,
	chestTimer: number,
	collectBuffer: number,
	actionBudget: number,
	lastToast: { [string]: number },
	alive: boolean,
}

local Tycoon = {}

local theme: any
local world: WorldBuilder.World
local sessions: { [Player]: Session } = {}
local plotOwners: { [number]: Player } = {}
local rng = Random.new()

local MAX_ORBS = 60
local ORB_PICKUP_RADIUS = 6
local CHEST_PICKUP_RADIUS = 5
local ACTIONS_PER_SECOND = 15

local NotifyRemote: RemoteEvent
local EffectRemote: RemoteEvent
local StateRemote: RemoteEvent
local ActionRemote: RemoteEvent

-- Filled in by Main so Tycoon does not depend on Monetization directly.
Tycoon.hooks = {
	promptPass = function(_player: Player, _name: string) end,
	promptProduct = function(_player: Player, _kind: string, _index: number) end,
}

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

local function spend(session: Session, cost: number): boolean
	if not canAfford(session, cost) then
		toast(session, "Not enough cash! Need " .. Format.money(cost), "bad")
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

local function unitBillboard(model: Model, tier: number, count: number?)
	local look = theme.Tiers[tier].Look
	local root = model.PrimaryPart :: BasePart
	local gui = WorldBuilder.billboard(root, CharacterFactory.height(look) + 0.6, 6, 2)
	gui.MaxDistance = 70
	local band = Economy.tierBand(tier)
	WorldBuilder.label(gui, { Text = tierName(tier), Size = UDim2.fromScale(1, 0.55), TextColor3 = theme.Colors.Rarity[band] })
	local sub = "Tier " .. tier
	if count and count > 1 then
		sub ..= "  x" .. Format.short(count)
	end
	WorldBuilder.label(gui, {
		Text = sub,
		Font = theme.Fonts.Body,
		Size = UDim2.fromScale(1, 0.4),
		Position = UDim2.fromScale(0, 0.58),
		TextColor3 = theme.Colors.TextDim,
	})
end

local function refreshDisplay(session: Session)
	local units = session.profile.units
	local wanted: { number } = {}
	local firstOfTier: { [number]: number } = {}
	for tier = Economy.MAX_TIER, 1, -1 do
		local count = units[tier] or 0
		local shown = math.min(count, Economy.DISPLAY_SLOTS - #wanted)
		for _ = 1, shown do
			table.insert(wanted, tier)
			if not firstOfTier[tier] then
				firstOfTier[tier] = #wanted
			end
		end
		if #wanted >= Economy.DISPLAY_SLOTS then
			break
		end
	end

	-- Labels show counts, so rebuild a tier's first model when its count changes.
	local countsKey = {}
	for tier, slotIndex in firstOfTier do
		countsKey[slotIndex] = tier .. ":" .. (units[tier] or 0)
	end

	for slotIndex = 1, Economy.DISPLAY_SLOTS do
		local tier = wanted[slotIndex]
		local current = session.display[slotIndex]
		local needsLabelCount = firstOfTier[tier or 0] == slotIndex
		local key = if needsLabelCount then countsKey[slotIndex] else tostring(tier)
		if current and (current.tier ~= tier or (current.model:GetAttribute("Key") ~= key)) then
			current.model:Destroy()
			session.display[slotIndex] = nil
			current = nil
		end
		if tier and not current then
			local look = theme.Tiers[tier].Look
			local model = CharacterFactory.build(look, tierName(tier))
			model:PivotTo(session.plot.slots[slotIndex])
			model:SetAttribute("Key", key)
			unitBillboard(model, tier, if needsLabelCount then units[tier] else nil)
			model.Parent = session.plot.unitFolder
			session.display[slotIndex] = { tier = tier, model = model }
		end
	end
end

-- Discovery / rewards ------------------------------------------------------------

local function discoverAll(session: Session)
	local p = session.profile
	local newest = 0
	local gems = 0
	for tier = 1, Economy.MAX_TIER do
		if (p.units[tier] or 0) > 0 and p.discovered[tier] == 0 then
			p.discovered[tier] = os.time()
			gems += Economy.discoveryGems(tier)
			newest = tier
		end
	end
	if newest > 0 then
		p.gems += gems
		notify(session, { kind = "Reward", tier = newest, new = true, gems = gems })
	end
end

local function autoMergeIfOn(session: Session)
	if session.profile.autoMerge then
		Economy.mergeAll(session.profile.units)
	end
end

local function awardUnit(session: Session, tier: number, source: string)
	local p = session.profile
	local isNew = p.discovered[tier] == 0
	p.units[tier] += 1
	p.totalObtained += 1
	if not isNew then
		notify(session, { kind = "Reward", tier = tier, new = false, source = source })
	end
	discoverAll(session)
	autoMergeIfOn(session)
	discoverAll(session)
	refreshDisplay(session)
	markDirty(session)
end

-- Crates --------------------------------------------------------------------------

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
	piece("Lid", Vector3.new(3.6, 0.6, 2.6), CFrame.new(0, 2.5, 0), wood:Lerp(Color3.new(0, 0, 0), 0.15), Enum.Material.WoodPlanks)
	for _, x in { -1.45, 1.45 } do
		piece(
			"Band",
			Vector3.new(0.3, 2.9, 2.7),
			CFrame.new(x, 1.45, 0),
			rarityColor,
			if rarity == "Common" then Enum.Material.Metal else Enum.Material.Neon
		)
	end
	piece("Lock", Vector3.new(0.6, 0.7, 0.25), CFrame.new(0, 2, -1.3), Color3.fromRGB(255, 205, 60), Enum.Material.Metal)
	model.PrimaryPart = body

	local gui = WorldBuilder.billboard(body, 3, 6, 1.4)
	gui.MaxDistance = 80
	WorldBuilder.label(gui, { Text = rarity, Size = UDim2.fromScale(1, 1), TextColor3 = rarityColor })
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

local function clearHeld(session: Session)
	session.profile.heldChest = ""
	removeHeldModel(session)
	markDirty(session)
end

local function spawnFloorChest(session: Session)
	if #session.floorChests >= Economy.MAX_FLOOR_CHESTS then
		return
	end
	local rarity = Economy.rollChestRarity(random)
	local area = session.plot.orbArea
	local localPos = Vector3.new(rng:NextNumber(area.minX, area.maxX), 0, rng:NextNumber(area.minZ, area.maxZ))
	local world0 = session.plot.cframe * CFrame.new(localPos + Vector3.new(0, 1.1, 0)) * CFrame.Angles(0, rng:NextNumber(0, math.pi * 2), 0)
	local model = buildChest(rarity)
	model:PivotTo(world0)
	model.Parent = session.plot.chestFolder
	table.insert(session.floorChests, { model = model, rarity = rarity, position = world0.Position })
	if rarity ~= "Common" then
		toast(session, string.format("A %s %s appeared!", rarity, theme.Words.Chest), "good")
	end
end

local function openChest(session: Session, rarity: string, source: string)
	local tier = Economy.rollChest(rarity, highestTier(session), random)
	awardUnit(session, tier, source)
	effect(session, "ChestOpen", { rarity = rarity })
end

-- Orbs ------------------------------------------------------------------------------

local function setOrbLabel(orb: Orb)
	orb.label.Text = theme.Icons.Orb .. Format.short(orb.value)
end

local function spawnOrb(session: Session, value: number)
	local plot = session.plot
	local area = plot.orbArea
	local target = plot.cframe * CFrame.new(rng:NextNumber(area.minX, area.maxX), 1, rng:NextNumber(area.minZ, area.maxZ))

	local origin = target
	local slotIndex = rng:NextInteger(1, math.max(1, math.min(Economy.DISPLAY_SLOTS, #session.display)))
	local slot = session.display[slotIndex]
	if slot then
		origin = slot.model:GetPivot() * CFrame.new(0, 4, 0)
	end

	local big = value >= Economy.productionPerSecond(session.profile.units) * 0.5 and value > 10
	local part = Instance.new("Part")
	part.Name = "Orb"
	part.Shape = Enum.PartType.Ball
	part.Size = Vector3.new(1.6, 1.6, 1.6)
	part.Material = Enum.Material.Neon
	part.Color = if big then theme.Colors.OrbBig else theme.Colors.Orb
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CFrame = origin
	local gui = WorldBuilder.billboard(part, 1.6, 3.2, 1)
	gui.MaxDistance = 45
	local label = WorldBuilder.label(gui, { Text = "", Font = theme.Fonts.Body, Size = UDim2.fromScale(1, 1) })
	part.Parent = plot.orbFolder

	local orb: Orb = { part = part, label = label, value = value }
	setOrbLabel(orb)
	table.insert(session.orbs, orb)
	if origin ~= target then
		TweenService:Create(part, TweenInfo.new(0.7, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { CFrame = target }):Play()
	end
end

local function produceOrbs(session: Session, amount: number)
	if amount <= 0 then
		return
	end
	if #session.orbs >= MAX_ORBS then
		local orb = session.orbs[rng:NextInteger(1, #session.orbs)]
		orb.value += amount
		setOrbLabel(orb)
		return
	end
	local pieces = if amount >= 4 then 2 else 1
	for _ = 1, pieces do
		spawnOrb(session, amount / pieces)
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

local function buy(session: Session, amount: number)
	local p = session.profile
	local cost = Economy.bulkPrice(p.buyTier, p.boughtAtTier, amount)
	if not spend(session, cost) then
		return
	end
	p.units[p.buyTier] += amount
	p.boughtAtTier += amount
	p.totalObtained += amount
	autoMergeIfOn(session)
	discoverAll(session)
	refreshDisplay(session)
	effect(session, "Buy", { amount = amount })
	markDirty(session)
end

for _, amount in Economy.BUY_AMOUNTS do
	padHandlers["Buy" .. amount] = function(session)
		buy(session, amount)
	end
end

local function doMerge(session: Session, verbose: boolean)
	local p = session.profile
	local merges, top = Economy.mergeAll(p.units)
	if merges > 0 then
		discoverAll(session)
		refreshDisplay(session)
		effect(session, "Merge", { merges = merges })
		if verbose then
			toast(session, string.format("Merged %s times! Best: %s", Format.short(merges), tierName(top)), "good")
		end
		markDirty(session)
	elseif verbose then
		toast(session, "Nothing to merge yet. You need 2 of the same tier.", "info")
	end
end

padHandlers.Merge = function(session)
	doMerge(session, true)
end

padHandlers.AutoMerge = function(session)
	local p = session.profile
	if not p.autoMergeOwned then
		if spend(session, Economy.AUTO_MERGE_COST) then
			p.autoMergeOwned = true
			p.autoMerge = true
			doMerge(session, false)
			toast(session, "Auto Merge unlocked and ON!", "good")
			markDirty(session)
		end
		return
	end
	p.autoMerge = not p.autoMerge
	if p.autoMerge then
		doMerge(session, false)
	end
	toast(session, "Auto Merge " .. (if p.autoMerge then "ON" else "OFF"), "info")
	markDirty(session)
end

padHandlers.BuyTier = function(session)
	local p = session.profile
	if p.buyTier >= Economy.MAX_BUY_TIER then
		toast(session, "Buy tier is maxed out!", "info")
		return
	end
	local req = Economy.buyTierRequirement(p.buyTier)
	if p.boughtAtTier < req then
		toast(session, string.format("Buy %s more %s first!", Format.short(req - p.boughtAtTier), theme.Words.Units), "bad")
		return
	end
	if not spend(session, Economy.buyTierUpgradeCost(p.buyTier)) then
		return
	end
	p.buyTier += 1
	p.boughtAtTier = 0
	toast(session, "You now buy " .. tierName(p.buyTier) .. "!", "good")
	effect(session, "Upgrade", {})
	markDirty(session)
end

padHandlers.Deposit = function(session)
	local p = session.profile
	if p.carried <= 0 then
		toast(session, "Your tank is empty! Walk over " .. theme.Words.Orb .. " orbs first.", "info")
		return
	end
	local mult = ReplicatedStorage:GetAttribute("DepositMult") or 1
	local amount = p.carried * mult
	p.queue += amount
	p.carried = 0
	effect(session, "Deposit", { amount = amount, mult = mult })
	markDirty(session)
end

padHandlers.Collect = function(session)
	local p = session.profile
	if p.pending < 1 then
		toast(session, "No cash ready yet. Deposit " .. theme.Words.Orb .. " first!", "info")
		return
	end
	local amount = p.pending
	addMoney(session, amount)
	p.pending = 0
	effect(session, "Cash", { amount = amount })
	markDirty(session)
end

local function procUpgrade(session: Session, amount: number)
	local p = session.profile
	if spend(session, Economy.processBulkCost(p.processLevel, amount)) then
		p.processLevel += amount
		effect(session, "Upgrade", {})
		markDirty(session)
	end
end
padHandlers.ProcUp1 = function(session)
	procUpgrade(session, 1)
end
padHandlers.ProcUp10 = function(session)
	procUpgrade(session, Economy.PROCESS_BULK)
end

local function useUnlocker(session: Session, slotIndex: number)
	local p = session.profile
	if slotIndex == 2 and not session.passes.PremiumUnlocker then
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
		return
	end
	local cash = math.max(Economy.FREE_REWARD_MIN, Tycoon.income(session) * Economy.FREE_REWARD_SECONDS)
	addMoney(session, cash)
	p.gems += Economy.FREE_REWARD_GEMS
	p.lastFreeReward = os.time()
	toast(session, string.format("Free reward: +%s and +%d %s", Format.money(cash), Economy.FREE_REWARD_GEMS, theme.Icons.Gem), "good")
	effect(session, "Cash", { amount = cash })
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
	setPad(
		session,
		"ProcUp1",
		string.format("+%s/sec", Format.short(Economy.processRate(p.processLevel + 1) - rateNow)),
		Format.money(procCost),
		canAfford(session, procCost)
	)
	setPad(
		session,
		"ProcUp10",
		string.format(
			"+%s/sec (x%d)",
			Format.short(Economy.processRate(p.processLevel + Economy.PROCESS_BULK) - rateNow),
			Economy.PROCESS_BULK
		),
		Format.money(procBulk),
		canAfford(session, procBulk)
	)

	local moneyMult = Tycoon.moneyMultiplier(session)
	labels.ProcessQueue.Text = theme.Icons.Orb .. " " .. Format.short(p.queue)
	labels.ProcessRate.Text = Format.money(math.min(p.queue, rateNow) * moneyMult) .. " per second"
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
		buyTier = p.buyTier,
		boughtAtTier = p.boughtAtTier,
		processLevel = p.processLevel,
		heldChest = p.heldChest,
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

local function flush(session: Session)
	if not session.dirty or not session.alive then
		return
	end
	session.dirty = false
	updateBoards(session)
	updateLeaderstats(session)
	StateRemote:FireClient(session.player, snapshot(session))
end

-- Ticks --------------------------------------------------------------------------------

local function fastTick(session: Session)
	local character = session.player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not root then
		return
	end
	local plot = session.plot
	local pos = root.Position
	local localPos = plot.cframe:PointToObjectSpace(pos)

	for _, pad in plot.pads do
		local inside = math.abs(localPos.X - pad.center.X) <= pad.half.X
			and math.abs(localPos.Z - pad.center.Z) <= pad.half.Y
			and localPos.Y > -2
			and localPos.Y < 9
		if inside and not session.inside[pad.name] then
			session.inside[pad.name] = true
			local handler = padHandlers[pad.name]
			if handler then
				handler(session)
				flush(session)
			end
		elseif not inside and session.inside[pad.name] then
			session.inside[pad.name] = nil
		end
	end

	-- Orb pickup (horizontal distance so jumping still collects).
	local collected = 0
	for i = #session.orbs, 1, -1 do
		local orb = session.orbs[i]
		local offset = orb.part.Position - pos
		if Vector2.new(offset.X, offset.Z).Magnitude <= ORB_PICKUP_RADIUS and math.abs(offset.Y) < 8 then
			collected += orb.value
			orb.part:Destroy()
			table.remove(session.orbs, i)
		end
	end
	if collected > 0 then
		session.profile.carried += collected
		session.collectBuffer += collected
		markDirty(session)
	end

	if session.profile.heldChest == "" then
		for i, chest in session.floorChests do
			local offset = chest.position - pos
			if Vector2.new(offset.X, offset.Z).Magnitude <= CHEST_PICKUP_RADIUS then
				chest.model:Destroy()
				table.remove(session.floorChests, i)
				session.profile.heldChest = chest.rarity
				attachHeldModel(session)
				effect(session, "ChestPickup", { rarity = chest.rarity })
				markDirty(session)
				break
			end
		end
	end
end

local function slowTick(session: Session)
	local p = session.profile
	local production = Tycoon.production(session)

	if session.passes.AutoLoot then
		p.carried += production
		if #session.orbs > 0 then
			local sum = 0
			for _, orb in session.orbs do
				sum += orb.value
			end
			p.carried += sum
			clearOrbs(session)
		end
	else
		produceOrbs(session, production)
	end

	local rate = Economy.processRate(p.processLevel)
	local processed = math.min(p.queue, rate)
	if processed > 0 then
		p.queue -= processed
		p.pending += processed * Economy.CASH_PER_POINT * Tycoon.moneyMultiplier(session)
	end
	if session.passes.AutoCash and p.pending > 0 then
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

actionHandlers.UnlockChest = function(session, data)
	local p = session.profile
	local rarity = p.heldChest
	if rarity == "" then
		return
	end
	if data.method == "gems" then
		if not spendGems(session, Economy.CHEST_INFO[rarity].gemPrice) then
			return
		end
	else
		if not spend(session, Economy.chestMoneyPrice(rarity, highestTier(session))) then
			return
		end
	end
	clearHeld(session)
	openChest(session, rarity, "unlock")
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
	if (data.kind == "Money" or data.kind == "Gems") and type(data.index) == "number" then
		Tycoon.hooks.promptProduct(session.player, data.kind, data.index)
	end
end

actionHandlers.SetSetting = function(session, data)
	local p = session.profile
	if data.key == "autoMerge" then
		if p.autoMergeOwned and type(data.value) == "boolean" then
			p.autoMerge = data.value
			if p.autoMerge then
				doMerge(session, false)
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
	doMerge(session, true)
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
		orbs = {},
		floorChests = {},
		heldModel = nil,
		display = {},
		displayCounts = "",
		dirty = true,
		chestTimer = 0,
		collectBuffer = 0,
		actionBudget = ACTIONS_PER_SECOND,
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
	removeHeldModel(session)
	setOwnerSign(session.plot, nil)
	refreshFriendBonuses()
	return session
end

function Tycoon.setPass(player: Player, name: string)
	local session = sessions[player]
	if session then
		session.passes[name] = true
		markDirty(session)
		flush(session)
	end
end

function Tycoon.grantMoney(session: Session, amount: number)
	addMoney(session, amount)
	effect(session, "Cash", { amount = amount })
	markDirty(session)
	flush(session)
end

function Tycoon.grantGems(session: Session, amount: number)
	session.profile.gems += amount
	toast(session, string.format("+%d %s %s", amount, theme.Words.Gem, theme.Icons.Gem), "good")
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
