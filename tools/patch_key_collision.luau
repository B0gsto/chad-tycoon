--!nocheck
--[[
	Sets CollisionFidelity = Box and RenderFidelity = Automatic on every MeshPart in the CARDIO
	keycap models (assets/models/props__Key_A..Z, props__KeySpace, props__KeyBlank .rbxm), in
	place. Scripts can't set MeshPart.CollisionFidelity at runtime, so World.CardioTrack relies
	on the stored models carrying Box collision (no hidden collider per key).

	Roblox stores CollisionFidelity inside the MeshPart's PhysicalConfigData shared string; Box
	is the blob "CSGPHS" .. 4 zero bytes .. "BLOCK". Lune adds that blob when the property is set
	but leaves PhysicalConfigData on the old collision mesh and can't read the property back, so
	this tool repoints PhysicalConfigData in the binary file itself and verifies by reading the
	PROP / SSTR chunks directly (the old mesh blob stays behind, unreferenced).

	pipeline/upload.py runs this on each keycap model it downloads. By hand:
	  lune run tools/patch_key_collision.luau                 patch every keycap model, verify
	  lune run tools/patch_key_collision.luau <file.rbxm>...  patch just these files, verify
	  lune run tools/patch_key_collision.luau --check         verify only (exit 1 if any isn't Box)
]]
local fs = require("@lune/fs")
local process = require("@lune/process")
local roblox = require("@lune/roblox")

local DIR = "assets/models"
local BOX_BLOB = "CSGPHS\0\0\0\0BLOCK"

local checkOnly = false
local files = {}
for _, arg in process.args do
	if arg == "--check" then
		checkOnly = true
	else
		table.insert(files, arg)
	end
end
if #files == 0 then
	for _, name in fs.readDir(DIR) do
		if string.match(name, "^props__Key_%u%.rbxm$") or name == "props__KeySpace.rbxm" or name == "props__KeyBlank.rbxm" then
			table.insert(files, DIR .. "/" .. name)
		end
	end
	table.sort(files)
end
assert(#files > 0, "no keycap models in " .. DIR)

-- LZ4 block decompression (the rbxm chunk codec).
local function lz4(src: string, size: number): string
	local out = buffer.create(size)
	local o, i, n = 0, 1, #src
	while i <= n do
		local token = string.byte(src, i)
		i += 1
		local len = bit32.rshift(token, 4)
		if len == 15 then
			repeat
				local b = string.byte(src, i)
				i += 1
				len += b
			until b ~= 255
		end
		buffer.writestring(out, o, string.sub(src, i, i + len - 1))
		o += len
		i += len
		if i > n then
			break
		end
		local offset = string.byte(src, i) + 256 * string.byte(src, i + 1)
		i += 2
		local m = bit32.band(token, 15)
		if m == 15 then
			repeat
				local b = string.byte(src, i)
				i += 1
				m += b
			until b ~= 255
		end
		for _ = 1, m + 4 do
			buffer.writeu8(out, o, buffer.readu8(out, o - offset))
			o += 1
		end
	end
	return buffer.tostring(out)
end

type Chunk = { name: string, raw: string, body: string }

-- The chunks of a binary model (raw = header + stored bytes, body = decompressed), the file header.
local function chunks(data: string): ({ Chunk }, string)
	assert(string.sub(data, 1, 8) == "<roblox!", "not a binary model")
	local list = {}
	local p = 33
	while p <= #data do
		local name = string.sub(data, p, p + 3)
		local clen, ulen = string.unpack("<I4I4", data, p + 4)
		local stored = if clen == 0 then ulen else clen
		local bytes = string.sub(data, p + 16, p + 15 + stored)
		table.insert(list, {
			name = name,
			raw = string.sub(data, p, p + 15 + stored),
			body = if clen == 0 then bytes else lz4(bytes, ulen),
		})
		p += 16 + stored
		if name == "END\0" then
			break
		end
	end
	return list, string.sub(data, 1, 32)
end

-- Shared strings by 0-based index.
local function sharedStrings(list: { Chunk }): { [number]: string }
	local out = {}
	for _, c in list do
		if c.name == "SSTR" then
			local _, count = string.unpack("<I4I4", c.body)
			local p = 9
			for i = 0, count - 1 do
				local len = string.unpack("<I4", c.body, p + 16)
				out[i] = string.sub(c.body, p + 20, p + 19 + len)
				p += 20 + len
			end
		end
	end
	return out
end

-- If `c` is a PhysicalConfigData PROP chunk: its header length (bytes before the values) and the
-- instance count.
local function configProp(c: Chunk): (number?, number)
	if c.name ~= "PROP" then
		return nil, 0
	end
	local len = string.unpack("<I4", c.body, 5)
	if string.sub(c.body, 9, 8 + len) ~= "PhysicalConfigData" then
		return nil, 0
	end
	local head = 8 + len + 1
	return head, (#c.body - head) // 4
end

-- The shared-string indices of every PhysicalConfigData value (interleaved big-endian u32).
local function configIndices(list: { Chunk }): { number }
	local out = {}
	for _, c in list do
		local head, n = configProp(c)
		if head then
			for i = 0, n - 1 do
				local v = 0
				for b = 0, 3 do
					v = v * 256 + string.byte(c.body, head + 1 + b * n + i)
				end
				table.insert(out, v)
			end
		end
	end
	return out
end

-- Points every PhysicalConfigData at shared string `index` (rewritten chunks stored uncompressed).
local function retarget(data: string, index: number): string
	local list, header = chunks(data)
	local parts = { header }
	for _, c in list do
		local head, n = configProp(c)
		if head then
			local values = {}
			for b = 3, 0, -1 do
				local byte = bit32.band(bit32.rshift(index, b * 8), 255)
				table.insert(values, string.rep(string.char(byte), n))
			end
			local body = string.sub(c.body, 1, head) .. table.concat(values)
			table.insert(parts, "PROP" .. string.pack("<I4I4I4", 0, #body, 0) .. body)
		else
			table.insert(parts, c.raw)
		end
	end
	return table.concat(parts)
end

local function meshParts(roots): { any }
	local out = {}
	for _, root in roots do
		if root:IsA("MeshPart") then
			table.insert(out, root)
		end
		for _, d in root:GetDescendants() do
			if d:IsA("MeshPart") then
				table.insert(out, d)
			end
		end
	end
	return out
end

local bad = 0
for _, path in files do
	if not checkOnly then
		local roots = roblox.deserializeModel(fs.readFile(path))
		local parts = meshParts(roots)
		assert(#parts > 0, path .. ": no MeshPart")
		for _, part in parts do
			part.CollisionFidelity = roblox.Enum.CollisionFidelity.Box
			part.RenderFidelity = roblox.Enum.RenderFidelity.Automatic
		end
		-- Lune adds the Box blob to the shared strings but keeps PhysicalConfigData pointing at the
		-- old collision data: point it at the Box blob.
		local data = roblox.serializeModel(roots)
		local box: number? = nil
		for i, blob in sharedStrings((chunks(data))) do
			if blob == BOX_BLOB then
				box = i
			end
		end
		assert(box, path .. ": Lune wrote no Box blob")
		fs.writeFile(path, retarget(data, box))
	end
	-- Read the file back: every MeshPart's PhysicalConfigData must be the Box blob.
	local data = fs.readFile(path)
	local list = chunks(data)
	local strings = sharedStrings(list)
	local indices = configIndices(list)
	local boxed = 0
	for _, i in indices do
		if strings[i] == BOX_BLOB then
			boxed += 1
		end
	end
	local parts = #meshParts(roblox.deserializeModel(data))
	if parts == 0 or boxed ~= parts or #indices ~= parts then
		bad += 1
		print(`{path}: {boxed} of {parts} MeshPart(s) Box`)
	end
end
print(`{#files} keycap model(s) {if checkOnly then "checked" else "patched"}, {bad} not Box`)
if bad > 0 then
	process.exit(1)
end
