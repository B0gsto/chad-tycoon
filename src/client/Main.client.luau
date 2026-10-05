-- Client entry point: builds the UI and routes server messages.

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
local Kit = require(Client.UI.Kit)
local Hud = require(Client.UI.Hud)
local Windows = require(Client.UI.Windows)
local Popups = require(Client.UI.Popups)

local player = Players.LocalPlayer
local C = Theme.Colors
local I = Theme.Icons

local screen = Instance.new("ScreenGui")
screen.Name = "TycoonUI"
screen.ResetOnSpawn = false
screen.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
screen.IgnoreGuiInset = false
screen.Parent = player:WaitForChild("PlayerGui")

-- Scale the whole UI from a 1280x720 design size.
local uiScale = Instance.new("UIScale")
uiScale.Parent = screen
local function rescale()
	local camera = Workspace.CurrentCamera
	if not camera then
		return
	end
	local size = camera.ViewportSize
	uiScale.Scale = math.clamp(math.min(size.X / 1280, size.Y / 720), 0.55, 1.5)
end
rescale()
Workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(rescale)
if Workspace.CurrentCamera then
	Workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(rescale)
end

Kit.setClickSound(function()
	Sounds.play("Click")
end)

Popups.build(screen, Sounds)
Windows.build(screen)
Hud.build(screen, { openWindow = Windows.open }, Sounds)

pcall(function()
	StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Backpack, false)
end)

local action = Net.event("Action")

Net.event("State").OnClientEvent:Connect(function(data)
	State.set(data)
	Sounds.updateMusic()
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
	end
end)

local TANK = UDim2.new(0.5, 0, 1, -150)
local WALLET = UDim2.new(0, 190, 1, -110)

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
	elseif kind == "Upgrade" then
		Sounds.play("Reward")
	elseif kind == "ChestPickup" then
		Sounds.play("Click")
	end
end)

-- Ask for a fresh snapshot now that every listener is connected.
action:FireServer({ action = "Sync" })
