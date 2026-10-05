-- Remote events/functions. The server creates them, clients wait for them.
--
--   State   (server -> client)  full public snapshot of the player's tycoon
--   Notify  (server -> client)  toasts, popups, reward reveals, confirms
--   Effect  (server -> client)  cosmetic feedback (collect sounds, floating text)
--   Action  (client -> server)  button presses from the UI
--   Query   (client -> server)  request/response data (ranking)

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Net = {}

local EVENTS = { "State", "Notify", "Effect", "Action" }
local FUNCTIONS = { "Query" }

local folder: Folder? = nil

local function getFolder(): Folder
	if folder then
		return folder
	end
	if RunService:IsServer() then
		local f = ReplicatedStorage:FindFirstChild("Remotes") :: Folder?
		if not f then
			local created = Instance.new("Folder")
			created.Name = "Remotes"
			f = created
		end
		assert(f, "Remotes folder missing")
		for _, name in EVENTS do
			if not f:FindFirstChild(name) then
				local remote = Instance.new("RemoteEvent")
				remote.Name = name
				remote.Parent = f
			end
		end
		for _, name in FUNCTIONS do
			if not f:FindFirstChild(name) then
				local remote = Instance.new("RemoteFunction")
				remote.Name = name
				remote.Parent = f
			end
		end
		f.Parent = ReplicatedStorage
		folder = f
		return f
	end
	local f = ReplicatedStorage:WaitForChild("Remotes") :: Folder
	folder = f
	return f
end

function Net.event(name: string): RemoteEvent
	return getFolder():WaitForChild(name) :: RemoteEvent
end

function Net.func(name: string): RemoteFunction
	return getFolder():WaitForChild(name) :: RemoteFunction
end

return Net
