--!nocheck
-- Measures a downloaded model: lune run pipeline/measure_rbxm.luau <file.rbxm>
-- Prints one JSON line: { root, meshId, size = {x, y, z}, meshParts = n } where meshId is the first
-- MeshPart's mesh content id and size is the world-axis bounding box of every BasePart in the file (studs).
local fs = require("@lune/fs")
local process = require("@lune/process")
local roblox = require("@lune/roblox")
local serde = require("@lune/serde")
local Vector3 = roblox.Vector3

local path = process.args[1]
assert(path, "usage: lune run pipeline/measure_rbxm.luau <file.rbxm>")
local roots = roblox.deserializeModel(fs.readFile(path))

local function contentId(part): string?
	local ok, id = pcall(function()
		return part.MeshId
	end)
	if ok and type(id) == "string" and id ~= "" then
		return id
	end
	local ok2, content = pcall(function()
		return part.MeshContent
	end)
	if ok2 and content ~= nil then
		local s = tostring(content)
		local digits = string.match(s, "%d+")
		if digits then
			return "rbxassetid://" .. digits
		end
	end
	return nil
end

local minV, maxV = nil, nil
local meshId, meshParts = nil, 0
local function visit(inst)
	if inst:IsA("BasePart") then
		local cf, size = inst.CFrame, inst.Size
		for _, sx in { -0.5, 0.5 } do
			for _, sy in { -0.5, 0.5 } do
				for _, sz in { -0.5, 0.5 } do
					local p = cf * Vector3.new(size.X * sx, size.Y * sy, size.Z * sz)
					minV = if minV then minV:Min(p) else p
					maxV = if maxV then maxV:Max(p) else p
				end
			end
		end
	end
	if inst:IsA("MeshPart") then
		meshParts += 1
		meshId = meshId or contentId(inst)
	end
	for _, child in inst:GetChildren() do
		visit(child)
	end
end
for _, r in roots do
	visit(r)
end

local size = if minV and maxV then maxV - minV else Vector3.zero
local function round(n: number): number
	return math.floor(n * 1000 + 0.5) / 1000
end
print(serde.encode("json", {
	root = if roots[1] then roots[1].ClassName .. ":" .. roots[1].Name else nil,
	meshId = meshId,
	meshParts = meshParts,
	size = { round(size.X), round(size.Y), round(size.Z) },
}))
