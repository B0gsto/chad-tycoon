--!strict
--[[
	AssetModels: clones of the Blender-made models stored in ReplicatedStorage.AssetModels.

	Rojo maps assets/models/*.rbxm (downloaded back by pipeline/upload.py, MeshParts with collision data) into that
	folder. A model's key is its pin key ("props/dumbbell"); the instance is named after the .rbxm file, with "/"
	written as "__" ("props__dumbbell"). Every function returns nil / false when the folder or the model is missing,
	so game code keeps its part-built fallback.
]]
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local AssetModels = {}

-- Instance name of `key` inside the AssetModels folder.
function AssetModels.name(key: string): string
	return (string.gsub(key, "/", "__"))
end

local function find(key: string): Instance?
	local folder = ReplicatedStorage:FindFirstChild("AssetModels")
	if folder == nil then
		return nil
	end
	return folder:FindFirstChild(AssetModels.name(key))
end

-- True when the model for `key` is in the place.
function AssetModels.has(key: string): boolean
	return find(key) ~= nil
end

-- A fresh, unparented clone of the model for `key` (usually a Model holding MeshParts), or nil when missing.
function AssetModels.clone(key: string): Instance?
	local source = find(key)
	if source == nil then
		return nil
	end
	return source:Clone()
end

return AssetModels
