--[[
	Client half of the agent test bridge (Server.TestBridge, docs/agent-playtest.md).

	Inert unless Shared.TestEnv.isTest() (the TEST experience only). Listens on
	ReplicatedStorage.TestBridgeClient (created by the server only in test) for:

	  { cmd = "ui", panel }        a window/popup spec for the client's UiPreview hook
	                               (Main.client: "Shop", "Shop,Passes", "close", "gift", ...)
	  { cmd = "camera", preset?, pos?, look?, fov?, distance? }
	                               preset "reset" | "front" | "back" | "overhead", or a fixed
	                               pos -> look; held every frame until "reset"
	  { cmd = "hideui", hidden? }  hide/show every ScreenGui and the core UI (toggle when nil)
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local StarterGui = game:GetService("StarterGui")
local Workspace = game:GetService("Workspace")

local TestEnv = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("TestEnv"))

if not TestEnv.isTest() then
	return
end

local player = Players.LocalPlayer
local remote = ReplicatedStorage:WaitForChild("TestBridgeClient", 60) :: RemoteEvent?
if not remote then
	return
end

local BIND = "TestBridgeCamera"
local held: (() -> CFrame?)? = nil
local savedFov: number? = nil

local function root(): BasePart?
	local character = player.Character
	local part = character and character:FindFirstChild("HumanoidRootPart")
	return if part and part:IsA("BasePart") then part else nil
end

local function flatLook(part: BasePart): Vector3
	local look = Vector3.new(part.CFrame.LookVector.X, 0, part.CFrame.LookVector.Z)
	return if look.Magnitude > 0.01 then look.Unit else Vector3.new(0, 0, -1)
end

-- Camera CFrame for a preset, relative to the character (nil when there is none).
local function presetFrame(preset: string, distance: number?): CFrame?
	local part = root()
	if not part then
		return nil
	end
	local at = part.Position
	local look = flatLook(part)
	if preset == "front" then
		local d = distance or 9
		return CFrame.lookAt(at + look * d + Vector3.new(0, 1.5, 0), at + Vector3.new(0, 0.5, 0))
	elseif preset == "back" then
		local d = distance or 14
		return CFrame.lookAt(at - look * d + Vector3.new(0, 6, 0), at + look * 10)
	elseif preset == "overhead" then
		local d = distance or 70
		return CFrame.lookAt(at + Vector3.new(0, d, 0) - look * 0.01, at)
	end
	return nil
end

local function release()
	RunService:UnbindFromRenderStep(BIND)
	held = nil
	local camera = Workspace.CurrentCamera
	if camera then
		camera.CameraType = Enum.CameraType.Custom
		local character = player.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if humanoid then
			camera.CameraSubject = humanoid
		end
		if savedFov then
			camera.FieldOfView = savedFov
		end
	end
	savedFov = nil
end

local function hold(frame: () -> CFrame?, fov: number?)
	local camera = Workspace.CurrentCamera
	if not camera then
		return
	end
	if fov and not savedFov then
		savedFov = camera.FieldOfView
	end
	held = frame
	RunService:UnbindFromRenderStep(BIND)
	-- After the default camera and any Fx camera, so the shot stays put.
	RunService:BindToRenderStep(BIND, Enum.RenderPriority.Last.Value, function()
		local cam = Workspace.CurrentCamera
		local cf = held and held()
		if cam and cf then
			cam.CameraType = Enum.CameraType.Scriptable
			cam.CFrame = cf
			if fov then
				cam.FieldOfView = fov
			end
		end
	end)
end

-- UI hiding: remembers which ScreenGuis it turned off, so showing again restores exactly those.
local hiddenGuis: { [ScreenGui]: boolean } = {}
local uiHidden = false

local function setHidden(hidden: boolean)
	if hidden == uiHidden then
		return
	end
	uiHidden = hidden
	local gui = player:FindFirstChildOfClass("PlayerGui")
	if hidden then
		for _, child in (if gui then gui:GetChildren() else {}) do
			if child:IsA("ScreenGui") and child.Enabled then
				child.Enabled = false
				hiddenGuis[child] = true
			end
		end
	else
		for screen in hiddenGuis do
			if screen.Parent then
				screen.Enabled = true
			end
		end
		table.clear(hiddenGuis)
	end
	pcall(StarterGui.SetCoreGuiEnabled, StarterGui, Enum.CoreGuiType.All, not hidden)
end

remote.OnClientEvent:Connect(function(payload: any)
	if type(payload) ~= "table" then
		return
	end
	if payload.cmd == "ui" and type(payload.panel) == "string" then
		-- Re-arm the hook so the same spec twice still fires.
		player:SetAttribute("UiPreview", "")
		player:SetAttribute("UiPreview", payload.panel)
	elseif payload.cmd == "camera" then
		local fov = tonumber(payload.fov)
		if payload.preset == "reset" then
			release()
		elseif type(payload.preset) == "string" then
			local preset, distance = payload.preset, tonumber(payload.distance)
			-- Follows the character: a preset framed on it keeps it framed while it moves.
			hold(function()
				return presetFrame(preset, distance)
			end, fov)
		elseif typeof(payload.pos) == "Vector3" and typeof(payload.look) == "Vector3" then
			local cf = CFrame.lookAt(payload.pos, payload.look)
			hold(function()
				return cf
			end, fov)
		end
	elseif payload.cmd == "hideui" then
		if type(payload.hidden) == "boolean" then
			setHidden(payload.hidden)
		else
			setHidden(not uiHidden)
		end
	end
end)
