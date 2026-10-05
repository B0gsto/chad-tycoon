-- Client entry point: builds the UI and routes server messages.

local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterGui = game:GetService("StarterGui")
local Workspace = game:GetService("Workspace")

local Theme = require(ReplicatedStorage:WaitForChild("Theme"))
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Format = require(Shared.Format)
local Net = require(Shared.Net)

local Client = script.Parent
local State = require(Client.State)
local Sounds = require(Client.Sounds)
local Guide = require(Client.Guide)
local Kit = require(Client.UI.Kit)
local Animator = require(Client.Animator)
local Hud = require(Client.UI.Hud)
local Windows = require(Client.UI.Windows)
local Popups = require(Client.UI.Popups)
local Tutorial = require(Client.UI.Tutorial)

local player = Players.LocalPlayer
local C = Theme.Colors
local I = Theme.Icons

local screen = Instance.new("ScreenGui")
screen.Name = "TycoonUI"
screen.ResetOnSpawn = false
screen.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
screen.IgnoreGuiInset = false
pcall(function()
	-- Keep clear of the Roblox top bar buttons and device notches.
	screen.ScreenInsets = Enum.ScreenInsets.CoreUISafeInsets
end)
screen.Parent = player:WaitForChild("PlayerGui")

-- Scale the whole UI from a 1280x720 design size. Touch screens get a little
-- extra so buttons stay comfortably tappable; short screens switch the HUD to
-- its compact layout.
local uiScale = Instance.new("UIScale")
uiScale.Parent = screen
local function rescale()
	local camera = Workspace.CurrentCamera
	if not camera then
		return
	end
	local size = camera.ViewportSize
	local topInset = 58
	pcall(function()
		local topLeft = GuiService:GetGuiInset()
		topInset = topLeft.Y
	end)
	local fit = math.min(size.X / 1280, size.Y / 720)
	if Kit.touch then
		fit *= 1.15
	end
	uiScale.Scale = math.clamp(fit, 0.5, 1.5)
	screen:SetAttribute("Compact", (size.Y - topInset) / uiScale.Scale < 600)
end
rescale()
Workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(rescale)
if Workspace.CurrentCamera then
	Workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(rescale)
end

Kit.setSoundPlayer(function(name)
	Sounds.play(name)
end)

Animator.start()
Popups.build(screen, Sounds)
Windows.build(screen)
Guide.build()
Hud.build(screen, {
	openWindow = Windows.open,
	toast = Popups.toast,
	guide = function(target)
		Guide.navigate(target, "CLAIM!", 45)
	end,
}, Sounds)
Tutorial.build(screen, {
	popups = Popups,
	sounds = Sounds,
	guide = Guide,
	highlight = function(name, on)
		local button = Hud.buttons[name]
		if button then
			Kit.setGlow(button, on)
		end
	end,
})

pcall(function()
	StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Backpack, false)
end)

local action = Net.event("Action")

Net.event("State").OnClientEvent:Connect(function(data)
	State.set(data)
	Sounds.updateMusic()
	if data.freeIn and data.freeIn > 0 then
		Guide.clearNavigate("Free")
	end
	-- Tells the loading screen (ReplicatedFirst) that the game is ready.
	if player:GetAttribute("GameReady") ~= true then
		player:SetAttribute("GameReady", true)
	end
end)

Net.event("Notify").OnClientEvent:Connect(function(payload)
	if type(payload) ~= "table" then
		return
	end
	if payload.kind == "Toast" then
		Popups.toast(payload.text, payload.tone)
	elseif payload.kind == "Reward" then
		Popups.reward(payload)
	elseif payload.kind == "Offline" then
		Popups.offline(payload)
	elseif payload.kind == "Confirm" then
		Popups.confirm(payload.text, function()
			action:FireServer(payload.action)
		end)
	elseif payload.kind == "Tutorial" then
		Tutorial.onNotify(payload)
	end
end)

-- Floating "+X" anchors: beside the tank (the tutorial card sits above it)
-- and next to the wallet.
local TANK = UDim2.new(0.5, 250, 1, -80)
local WALLET = UDim2.fromOffset(200, 40)

Net.event("Effect").OnClientEvent:Connect(function(kind, data)
	if kind == "Collect" then
		Sounds.play("Collect", 0.3)
		Popups.float("+" .. I.Orb .. Format.short(data.amount), C.Orb, TANK)
	elseif kind == "Cash" then
		Sounds.play("Cash")
		Popups.float("+" .. Format.money(data.amount), C.Good, WALLET)
	elseif kind == "Deposit" then
		Sounds.play("Deposit")
		Popups.float(string.format("%s%s x%.1f", I.Orb, Format.short(data.amount), data.mult), C.Primary, TANK)
	elseif kind == "Buy" then
		Sounds.play("Buy")
	elseif kind == "Merge" then
		Sounds.play("Merge")
	elseif kind == "Upgrade" or kind == "ChestOpen" then
		Sounds.play("Reward")
	elseif kind == "ChestPickup" then
		Sounds.play("Pickup")
	end
end)

-- Ask for a fresh snapshot now that every listener is connected.
action:FireServer({ action = "Sync" })
