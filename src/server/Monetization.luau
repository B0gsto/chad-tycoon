--[[
	Monetization: game passes and developer products.

	IDs come from the theme. While an ID is 0:
	  - in Studio, "buying" grants it immediately (so every feature is testable)
	  - on a live server, the player is told it is coming soon.
]]

local MarketplaceService = game:GetService("MarketplaceService")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Economy = require(ReplicatedStorage.Shared.Economy)

local DataService = require(script.Parent.DataService)
local Tycoon = require(script.Parent.Tycoon)

local Monetization = {}

local theme: any
local MAX_RECEIPTS = 50

local function passByName(name: string): any
	return theme.Monetization.Passes[name]
end

local function productList(kind: string): { any }?
	if kind == "Money" then
		return theme.Monetization.MoneyPacks
	elseif kind == "Gems" then
		return theme.Monetization.GemPacks
	end
	return nil
end

-- Checks which passes a player already owns.
function Monetization.ownedPasses(player: Player): { [string]: boolean }
	local owned = {}
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

local function grantProduct(session: Tycoon.Session, kind: string, index: number)
	if kind == "Money" then
		local pack = theme.Monetization.MoneyPacks[index]
		local amount = Economy.moneyPackAmount(Tycoon.income(session), pack.Seconds, pack.Min)
		Tycoon.grantMoney(session, amount)
	elseif kind == "Gems" then
		local pack = theme.Monetization.GemPacks[index]
		Tycoon.grantGems(session, pack.Amount)
	end
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
	if pass.Id == 0 then
		if RunService:IsStudio() then
			Tycoon.setPass(player, name)
			Tycoon.toast(session, "[Studio test] Granted " .. pass.Title, "good")
		else
			Tycoon.toast(session, pass.Title .. " is coming soon!", "info")
		end
		return
	end
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
	MarketplaceService:PromptProductPurchase(player, product.Id)
end

local function findProduct(productId: number): (string?, number?)
	for _, kind in { "Money", "Gems" } do
		for index, product in productList(kind) :: { any } do
			if product.Id ~= 0 and product.Id == productId then
				return kind, index
			end
		end
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
	grantProduct(session, kind, index)
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
end

return Monetization
