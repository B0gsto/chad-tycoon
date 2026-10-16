--!nocheck
-- ReplicatedStorage.AssetModels holds every assets/models/*.rbxm (names sent by cloud_test.py in META.assetModels)
-- with real mesh data, and src/shared/AssetModels.luau can clone them on a live server.
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local AssetModels = require(ReplicatedStorage.Shared.AssetModels)

T.test("every assets/models/*.rbxm is in ReplicatedStorage.AssetModels", function()
	local folder = T.ok(ReplicatedStorage:FindFirstChild("AssetModels"), "ReplicatedStorage.AssetModels is missing")
	local expected = T.meta.assetModels or {}
	T.ok(#expected > 0, "META.assetModels is empty")
	local missing = {}
	for _, name in expected do
		if not folder:FindFirstChild(name) then
			table.insert(missing, name)
		end
	end
	T.ok(#missing == 0, "missing: " .. table.concat(missing, ", "))
end)

T.test("every asset model has a MeshPart with a mesh", function()
	local bad = {}
	for _, model in ReplicatedStorage.AssetModels:GetChildren() do
		local mesh = if model:IsA("MeshPart") then model else model:FindFirstChildWhichIsA("MeshPart", true)
		if not mesh or mesh.MeshId == "" or mesh.MeshSize.Magnitude <= 0 then
			table.insert(bad, model.Name)
		end
	end
	T.ok(#bad == 0, "no usable MeshPart in: " .. table.concat(bad, ", "))
end)

T.test("AssetModels.clone works on a live server", function()
	local name = T.ok((T.meta.assetModels or {})[1], "no asset model to clone")
	local key = string.gsub(name, "__", "/")
	local copy = T.ok(AssetModels.clone(key), "AssetModels.clone(" .. key .. ") returned nil")
	copy:Destroy()
end)
