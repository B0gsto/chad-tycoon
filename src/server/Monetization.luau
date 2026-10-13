--[[
	Monetization: game passes and developer products.

	Developer products: cash packs (Theme.Monetization.MoneyPacks),
	aura packs (AuraPacks: the pack's aura blended into cash at once, Shared.ShopMath) and
	the instant crate open. Pack amounts follow the buyer's progression (Shared.Economy).

	IDs come from the theme. While an ID is 0:
	  - in Studio, "buying" grants it immediately (so every feature is testable)
	  - on a live server, the player is told it is coming soon.

	Instant crate opening is one developer product for every crate rarity
	(Theme.Monetization.CrateOpen), for the held crate or one still in a smasher; the
	prompted crate's rarity (and smasher slot) is recorded in profile.pendingCrate
	(pendingUnlocker) so the receipt can pay out even if the crate is gone.
	Crates are paid random items, so the product is only offered where PolicyService
	allows them (unknown or failed lookup = not allowed). The Crate Master pass
	(Passes.CrateKey) opens every crate free; Tycoon handles that without a prompt.
]]

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local PolicyService = game:GetService("PolicyService")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Economy = require(ReplicatedStorage.Shared.Economy)
local Format = require(ReplicatedStorage.Shared.Format)
local ShopMath = require(ReplicatedStorage.Shared.ShopMath)

local Analytics = require(script.Parent.Analytics)
local DataService = require(script.Parent.DataService)
local Tycoon = require(script.Parent.Tycoon)

local Monetization = {}

local theme: any
local MAX_RECEIPTS = 50

-- Players whose policy allows paid random items (crate products). Absent = not
-- allowed: still loading, the lookup failed, or restricted.
local crateAllowed: { [Player]: boolean } = {}

local function loadPolicy(player: Player)
	local ok, info = pcall(PolicyService.GetPolicyInfoForPlayerAsync, PolicyService, player)
	if not player.Parent then
		return
	end
	local allowed = ok and type(info) == "table" and info.ArePaidRandomItemsRestricted == false
	if allowed then
		crateAllowed[player] = true
	end
	Tycoon.refresh(player)
end

function Monetization.crateRobuxAllowed(player: Player): boolean
	return crateAllowed[player] == true
end

local function passByName(name: string): any
	return theme.Monetization.Passes[name]
end

local function productList(kind: string): { any }?
	if kind == "Money" then
		return theme.Monetization.MoneyPacks
	elseif kind == "Aura" then
		return theme.Monetization.AuraPacks
	elseif kind == "LegacyMoney" then
		-- Retired packs: only reachable through a receipt (Tycoon never prompts this kind).
		return theme.Monetization.LegacyMoneyPacks
	end
	return nil
end

-- Checks which passes a player already owns. Studio play tests start with none: the
-- place's creator owns every pass, and Auto Aura would turn the orb loop off (passes
-- are still granted there by test purchases).
function Monetization.ownedPasses(player: Player): { [string]: boolean }
	local owned = {}
	if RunService:IsStudio() then
		return owned
	end
	for name, pass in theme.Monetization.Passes do
		if pass.Id ~= 0 then
			local ok, result = pcall(MarketplaceService.UserOwnsGamePassAsync, MarketplaceService, player.UserId, pass.Id)
			if ok and result then
				owned[name] = true
			end
		end
	end
	return owned
end

-- Packs are sized by the buyer's progression at the moment the receipt is processed, with
-- the same shared functions the shop uses to show each player their own amounts.
local function grantProduct(session: Tycoon.Session, kind: string, index: number)
	local p = session.profile
	local progression = Economy.progression(Economy.highestTier(p.discovered), p.processLevel)
	if kind == "Money" or kind == "LegacyMoney" then
		local pack = (productList(kind) :: { any })[index]
		local amount = Economy.moneyPackAmount(Tycoon.income(session), pack.Seconds, pack.Min, progression)
		Tycoon.grantMoney(session, amount)
	elseif kind == "Aura" then
		local pack = theme.Monetization.AuraPacks[index]
		-- Surge-free production (the shop card's State.rewardProduction): a pack bought during an
		-- Aura Surge is not doubled by accident, and is what the card showed.
		local aura = Economy.auraPackAmount(Tycoon.steadyProduction(session), pack.Seconds, pack.Min, progression)
		-- Blended at once: the pack used to fill a tank the converter needed hours (the largest
		-- pack, days) to empty. The buyer gets the cash that aura is worth, straight away. A
		-- receipt for a pack sold before this change is paid the same way (same product ids).
		local cash = ShopMath.auraPackCash(aura, Tycoon.moneyMultiplier(session))
		Tycoon.grantMoney(session, cash)
		Tycoon.toast(session, "Blended instantly! +" .. Format.money(cash), "good")
	end
end

-- Instant crate open for a held crate of `rarity`, or for the crate in smasher `slot`
-- (see Tycoon.openCrateProduct).
function Monetization.promptCrate(player: Player, rarity: string, slot: number?)
	local session = Tycoon.getSession(player)
	local product = theme.Monetization.CrateOpen
	if not session or not Economy.isRarity(rarity) then
		return
	end
	if not Monetization.crateRobuxAllowed(player) then
		if slot then
			Tycoon.toast(session, "Come back when the timer ends!", "info")
		else
			Tycoon.toast(session, "Carry it to a " .. theme.Words.Unlocker .. " to open it free!", "info")
		end
		return
	end
	-- The product is the same for every rarity: remember which crate this prompt is for.
	session.profile.pendingCrate = rarity
	session.profile.pendingUnlocker = slot or 0
	if product.Id == 0 then
		if RunService:IsStudio() then
			Tycoon.openCrateProduct(session)
			Tycoon.toast(session, "[Studio test] Crate opened", "good")
		else
			Tycoon.toast(session, "Opening crates instantly is coming soon!", "info")
		end
		return
	end
	Analytics.shop(player, 2, "Prompted")
	MarketplaceService:PromptProductPurchase(player, product.Id)
end

function Monetization.promptPass(player: Player, name: string)
	local session = Tycoon.getSession(player)
	local pass = passByName(name)
	if not session or not pass then
		return
	end
	if session.passes[name] then
		Tycoon.toast(session, "You already own " .. pass.Title .. "!", "info")
		return
	end
	-- Cosmetic passes are not random items: never behind the paid-random-items policy.
	local cosmetics = theme.Cosmetics
	local item = cosmetics and cosmetics.Items[name]
	if item and not item.Starter and session.passes[cosmetics.Bundle] then
		Tycoon.toast(session, pass.Title .. " is already in your " .. theme.Monetization.Passes[cosmetics.Bundle].Title .. "!", "info")
		return
	end
	-- Crate Master opens paid random items: only sold where those are allowed.
	if name == "CrateKey" and not Monetization.crateRobuxAllowed(player) then
		Tycoon.toast(session, pass.Title .. " is not available here.", "info")
		return
	end
	if pass.Id == 0 then
		if RunService:IsStudio() then
			Tycoon.setPass(player, name)
			Tycoon.toast(session, "[Studio test] Granted " .. pass.Title, "good")
		else
			Tycoon.toast(session, pass.Title .. " is coming soon!", "info")
		end
		return
	end
	Analytics.shop(player, 2, "Prompted")
	MarketplaceService:PromptGamePassPurchase(player, pass.Id)
end

function Monetization.promptProduct(player: Player, kind: string, index: number)
	local session = Tycoon.getSession(player)
	local list = productList(kind)
	local product = list and list[index]
	if not session or not product then
		return
	end
	if product.Id == 0 then
		if RunService:IsStudio() then
			grantProduct(session, kind, index)
			Tycoon.toast(session, "[Studio test] Product granted", "good")
		else
			Tycoon.toast(session, "This pack is coming soon!", "info")
		end
		return
	end
	Analytics.shop(player, 2, "Prompted")
	MarketplaceService:PromptProductPurchase(player, product.Id)
end

-- (kind, index) of a pack, or ("Crate", true) for the crate product.
local function findProduct(productId: number): (string?, any)
	for _, kind in { "Money", "Aura", "LegacyMoney" } do
		for index, product in productList(kind) :: { any } do
			if product.Id ~= 0 and product.Id == productId then
				return kind, index
			end
		end
	end
	local crate = theme.Monetization.CrateOpen
	if crate.Id ~= 0 and crate.Id == productId then
		return "Crate", true
	end
	return nil, nil
end

-- Persists the profile; only report the purchase as granted once it is saved.
local function saveOrRetry(session: Tycoon.Session): Enum.ProductPurchaseDecision
	if not session.canSave then
		-- Studio without API access: nothing to persist.
		return Enum.ProductPurchaseDecision.PurchaseGranted
	end
	if DataService.save(session.player, session.profile) then
		return Enum.ProductPurchaseDecision.PurchaseGranted
	end
	return Enum.ProductPurchaseDecision.NotProcessedYet
end

local function processReceipt(receipt: any): Enum.ProductPurchaseDecision
	local session = Tycoon.getSessionByUserId(receipt.PlayerId)
	if not session then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	local profile = session.profile
	if table.find(profile.receipts, receipt.PurchaseId) then
		-- Already granted in this session; make sure it is persisted.
		return saveOrRetry(session)
	end
	local kind, index = findProduct(receipt.ProductId)
	if not kind or not index then
		warn("[Monetization] Unknown product", receipt.ProductId)
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	-- Grant and record the receipt together. If the save below fails, Roblox
	-- retries this callback; the recorded receipt makes the retry a no-op grant
	-- that only re-attempts the save, so the player is never paid twice.
	-- A crate product always pays out, even if the crate was dropped or the
	-- player rejoined (no session = NotProcessedYet above, retried on rejoin):
	-- the prompted smasher's crate, else the held crate, else the saved pendingCrate
	-- rarity, else a Common crate.
	if kind == "Crate" then
		Tycoon.openCrateProduct(session)
	else
		grantProduct(session, kind, index)
	end
	Analytics.shop(session.player, 3, "Purchased")
	table.insert(profile.receipts, receipt.PurchaseId)
	while #profile.receipts > MAX_RECEIPTS do
		table.remove(profile.receipts, 1)
	end
	return saveOrRetry(session)
end

function Monetization.init(themeModule: any)
	theme = themeModule
	MarketplaceService.ProcessReceipt = processReceipt
	MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(player, passId, purchased)
		if not purchased then
			return
		end
		for name, pass in theme.Monetization.Passes do
			if pass.Id == passId then
				Analytics.shop(player, 3, "Purchased")
				Tycoon.setPass(player, name)
				local session = Tycoon.getSession(player)
				if session then
					Tycoon.toast(session, "Thanks! " .. pass.Title .. " is active.", "good")
				end
			end
		end
	end)
	Tycoon.hooks.promptPass = Monetization.promptPass
	Tycoon.hooks.promptProduct = Monetization.promptProduct
	Tycoon.hooks.promptCrate = Monetization.promptCrate
	Tycoon.hooks.crateRobuxAllowed = Monetization.crateRobuxAllowed
	Players.PlayerAdded:Connect(loadPolicy)
	for _, player in Players:GetPlayers() do
		task.spawn(loadPolicy, player)
	end
	Players.PlayerRemoving:Connect(function(player)
		crateAllowed[player] = nil
	end)
end

return Monetization
