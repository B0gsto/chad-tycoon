--[[
	Preview exporter.

	Runs the game's REAL server and client code from a built place file under
	Lune (with small stubs for engine features Lune lacks), lets a simulated
	session play for a few seconds, then exports:
	  out/<variant>/world.json        every visible part, light, SurfaceGui and BillboardGui
	  out/<variant>/world_held.json   same, with the player holding a crate
	  out/<variant>/showcase.json     all 25 unit tiers lined up
	  out/<variant>/gui/<shot>.json   the HUD / windows / popups for each screenshot

	Usage: lune run preview/export/export.luau [chad] [--viewport WxH] [--touch | --gamepad]

	--viewport sizes the screen (default 1280x720) and --touch / --gamepad make
	UserInputService report that device, so Kit picks its touch / console
	layout. Either option writes to out/<variant>-<WxH>[-touch|-gamepad]
	(e.g. out/chad-844x390-touch) so the normal export is untouched; render
	its HUD with `GUI_ONLY=1 node preview/render/shoot.mjs chad-844x390-touch`.
]]

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local process = require("@lune/process")
local roblox = require("@lune/roblox")
local serde = require("@lune/serde")
local task = require("@lune/task")

local variant = "chad"
local VIEW_W, VIEW_H = 1280, 720
local device: string? = nil -- "touch" | "gamepad" (nil: keyboard + mouse)
local custom = false
do
	local i = 1
	while i <= #process.args do
		local arg = process.args[i]
		if arg == "--viewport" then
			i += 1
			local w, h = string.match(process.args[i] or "", "^(%d+)x(%d+)$")
			assert(w and h, "--viewport wants WxH, e.g. 844x390")
			VIEW_W, VIEW_H = tonumber(w) :: number, tonumber(h) :: number
			custom = true
		elseif arg == "--touch" or arg == "--gamepad" then
			device = string.sub(arg, 3)
			custom = true
		else
			variant = arg
		end
		i += 1
	end
end
local PLACES = { chad = "build/ChadAuraTycoon.rbxlx", bot = "build/BotFactoryTycoon.rbxlx" }
-- PREVIEW_PLACE / PREVIEW_OUT let several exports run side by side (private build + output dir).
local OUT = process.env.PREVIEW_OUT
	or (
		"preview/out/"
		.. variant
		.. (if custom then string.format("-%dx%d", VIEW_W, VIEW_H) .. (if device then "-" .. device else "") else "")
	)
fs.writeDir(OUT .. "/gui")

math.randomseed(if variant == "chad" then 7 else 11)

local game = roblox.deserializePlace(fs.readFile(process.env.PREVIEW_PLACE or PLACES[variant]))
local Instance = roblox.Instance
local Enum = roblox.Enum
local CFrame = roblox.CFrame
local Vector3 = roblox.Vector3
local Vector2 = roblox.Vector2
local Color3 = roblox.Color3

local mode = "server"
local FIXED_NOW = 1791230000 -- fixed clock so timers/surge render deterministically

-- Signals -----------------------------------------------------------------------

local function newSignal()
	local signal = { connections = {} }
	function signal:Connect(fn)
		local record = { fn = fn, connected = true }
		table.insert(self.connections, record)
		return {
			Connected = true,
			Disconnect = function()
				record.connected = false
			end,
		}
	end
	function signal:Once(fn)
		local conn
		conn = self:Connect(function(...)
			conn.Disconnect()
			fn(...)
		end)
		return conn
	end
	function signal:Wait()
		return task.wait()
	end
	function signal:Fire(...)
		for _, record in self.connections do
			if record.connected then
				record.fn(...)
			end
		end
	end
	return signal
end

local idCounter = 0
local signals: { [string]: any } = {}
local extraProps: { [string]: any } = {}

local function idOf(inst): number
	local id = inst:GetAttribute("__pid")
	if not id then
		idCounter += 1
		id = idCounter
		inst:SetAttribute("__pid", id)
	end
	return id
end

local function signalFor(inst, name: string)
	local key = idOf(inst) .. ":" .. name
	if not signals[key] then
		signals[key] = newSignal()
	end
	return signals[key]
end

local EVENTS = {
	TextButton = {
		"Activated",
		"MouseEnter",
		"MouseLeave",
		"MouseButton1Down",
		"MouseButton1Up",
		"MouseButton1Click",
		"SelectionGained",
		"SelectionLost",
	},
	ImageButton = {
		"Activated",
		"MouseEnter",
		"MouseLeave",
		"MouseButton1Down",
		"MouseButton1Up",
		"MouseButton1Click",
		"SelectionGained",
		"SelectionLost",
	},
	BindableEvent = { "Event" },
	RemoteEvent = { "OnClientEvent", "OnServerEvent" },
	Player = { "CharacterAdded", "CharacterRemoving" },
	Players = { "PlayerAdded", "PlayerRemoving" },
	RunService = { "Heartbeat", "RenderStepped", "Stepped" },
	MarketplaceService = { "PromptGamePassPurchaseFinished" },
	UserInputService = { "InputBegan", "InputEnded", "InputChanged", "LastInputTypeChanged" },
	ProximityPrompt = { "Triggered", "TriggerEnded", "PromptShown", "PromptHidden", "PromptButtonHoldBegan", "PromptButtonHoldEnded" },
}
for className, names in EVENTS do
	for _, name in names do
		roblox.implementProperty(className, name, function(self)
			return signalFor(self, name)
		end)
	end
end

-- Methods / properties Lune lacks ----------------------------------------------------

roblox.implementMethod("Instance", "WaitForChild", function(self, name)
	local child = self:FindFirstChild(name)
	assert(child, "WaitForChild: missing " .. tostring(name) .. " under " .. self:GetFullName())
	return child
end)
roblox.implementMethod("Instance", "GetAttributeChangedSignal", function(self, name)
	return signalFor(self, "attr:" .. name)
end)
roblox.implementMethod("Instance", "GetPropertyChangedSignal", function(self, name)
	return signalFor(self, "prop:" .. name)
end)
roblox.implementMethod("BindableEvent", "Fire", function(self, ...)
	signalFor(self, "Event"):Fire(...)
end)

local captured = { state = {}, notify = {} }
roblox.implementMethod("RemoteEvent", "FireClient", function(self, player, payload, ...)
	if self.Name == "State" then
		captured.state[player.Name] = payload
	elseif self.Name == "Notify" then
		table.insert(captured.notify, payload)
	end
end)
roblox.implementMethod("RemoteEvent", "FireServer", function() end)
roblox.implementMethod("RemoteEvent", "FireAllClients", function() end)

local rankingEntries = {}
roblox.implementMethod("RemoteFunction", "InvokeServer", function(_self, kind)
	if kind == "Ranking" then
		return { entries = rankingEntries, updatedAt = os.time() - 95 }
	end
	return nil
end)

local function modelPivot(model)
	local primary = model.PrimaryPart
	if primary then
		return primary.CFrame
	end
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then
			return d.CFrame
		end
	end
	return CFrame.new()
end

roblox.implementMethod("Model", "GetPivot", modelPivot)
roblox.implementMethod("Model", "PivotTo", function(self, target)
	local delta = target * modelPivot(self):Inverse()
	for _, d in self:GetDescendants() do
		if d:IsA("BasePart") then
			d.CFrame = delta * d.CFrame
		end
	end
end)
roblox.implementMethod("Model", "ScaleTo", function(self, scale)
	local pivot = modelPivot(self)
	for _, d in self:GetDescendants() do
		if d:IsA("BasePart") then
			local rel = pivot:ToObjectSpace(d.CFrame)
			local x, y, z, r00, r01, r02, r10, r11, r12, r20, r21, r22 = rel:GetComponents()
			d.Size = d.Size * scale
			d.CFrame = pivot * CFrame.new(x * scale, y * scale, z * scale, r00, r01, r02, r10, r11, r12, r20, r21, r22)
		end
	end
end)

roblox.implementMethod("HttpService", "GenerateGUID", function()
	return "preview-guid"
end)
roblox.implementMethod("Workspace", "GetServerTimeNow", function()
	return FIXED_NOW
end)

roblox.implementProperty("ViewportFrame", "CurrentCamera", function(self)
	return extraProps[idOf(self) .. ":cam"]
end, function(self, value)
	extraProps[idOf(self) .. ":cam"] = value
end)

roblox.implementProperty("Player", "Character", function(self)
	return extraProps[idOf(self) .. ":char"]
end, function(self, value)
	extraProps[idOf(self) .. ":char"] = value
end)
roblox.implementMethod("Player", "Kick", function(self, msg)
	print("[kick]", self.Name, msg)
end)
roblox.implementMethod("Player", "IsFriendsWith", function()
	return false
end)

local fakePlayers = {}
local localIndex = 1 -- which fake player the client UI belongs to
roblox.implementMethod("Players", "GetPlayers", function()
	return fakePlayers
end)
roblox.implementProperty("Players", "LocalPlayer", function()
	return fakePlayers[localIndex]
end)

roblox.implementMethod("RunService", "IsServer", function()
	return mode == "server"
end)
roblox.implementMethod("RunService", "IsClient", function()
	return mode == "client"
end)
roblox.implementMethod("RunService", "IsStudio", function()
	return false
end)

roblox.implementMethod("TweenService", "Create", function(_self, obj, _info, props)
	-- Jump straight to the end state.
	for key, value in props do
		obj[key] = value
	end
	return { Play = function() end, Cancel = function() end, Completed = newSignal() }
end)
roblox.implementMethod("SoundService", "PlayLocalSound", function() end)
roblox.implementMethod("SocialService", "PromptGameInvite", function() end)
roblox.implementMethod("StarterGui", "SetCoreGuiEnabled", function() end)
roblox.implementMethod("DataStoreService", "GetDataStore", function()
	error("DataStores are not available in the preview")
end)
roblox.implementMethod("DataStoreService", "GetOrderedDataStore", function()
	error("DataStores are not available in the preview")
end)

-- Module loader -----------------------------------------------------------------------

local Random = {
	new = function(_seed)
		return {
			NextNumber = function(_self, a, b)
				a = a or 0
				b = b or 1
				return a + math.random() * (b - a)
			end,
			NextInteger = function(_self, a, b)
				return math.random(a, b)
			end,
		}
	end,
}
local TweenInfo = {
	new = function()
		return {}
	end,
}

local moduleCache = {}
local requireModule

local function makeEnv(scriptInstance)
	return setmetatable({
		game = game,
		workspace = game:GetService("Workspace"),
		script = scriptInstance,
		require = function(target)
			return requireModule(target)
		end,
		Instance = Instance,
		Vector3 = Vector3,
		Vector2 = Vector2,
		CFrame = CFrame,
		Color3 = Color3,
		ColorSequence = roblox.ColorSequence,
		ColorSequenceKeypoint = roblox.ColorSequenceKeypoint,
		NumberSequence = roblox.NumberSequence,
		NumberSequenceKeypoint = roblox.NumberSequenceKeypoint,
		NumberRange = roblox.NumberRange,
		UDim = roblox.UDim,
		UDim2 = roblox.UDim2,
		Enum = Enum,
		TweenInfo = TweenInfo,
		Random = Random,
		task = task,
		__previewLocalPlayer = function()
			return fakePlayers[localIndex]
		end,
		warn = function(...)
			print("[warn]", ...)
		end,
	}, { __index = _G })
end

-- Lune cannot read a few engine-only properties; swap them for constants.
local SOURCE_PATCHES = {
	{ "player.MembershipType == Enum.MembershipType.Premium", "false" },
	{ 'if game.JobId ~= "" then game.JobId else', 'if false then "" else' },
	{ "local pos = root.Position", "local pos = root.CFrame.Position" },
	{ "Players.LocalPlayer", "__previewLocalPlayer()" },
	{ "orb.part.Position - pos", "orb.part.CFrame.Position - pos" },
	-- Lune errors on any access to a destroyed instance (Roblox doesn't), and
	-- delayed UI callbacks (fades, spinners) may still touch them: detach instead.
	{ ":Destroy()", ".Parent = nil" },
	{ "camera.ViewportSize", string.format("Vector2.new(%d, %d)", VIEW_W, VIEW_H) },
	{ "Workspace.CurrentCamera.ViewportSize", string.format("Vector2.new(%d, %d)", VIEW_W, VIEW_H) },
	-- Lune can't override reflected properties, so the device flags are patched into the source.
	{ "UserInputService.TouchEnabled", tostring(device == "touch") },
	{ "UserInputService.GamepadEnabled", tostring(device == "gamepad") },
	{ "UserInputService.KeyboardEnabled", tostring(device == nil) },
	{ "UserInputService.MouseEnabled", tostring(device == nil) },
}

function requireModule(target)
	local key = target:GetFullName()
	if moduleCache[key] == nil then
		local source = target.Source
		for _, patch in SOURCE_PATCHES do
			source = source:gsub(patch[1]:gsub("%p", "%%%0"), patch[2])
		end
		local fn = luau.load(source, { debugName = key, environment = makeEnv(target) })
		moduleCache[key] = fn()
	end
	return moduleCache[key]
end

-- Export helpers ------------------------------------------------------------------------

local function rgb(c)
	return { math.floor(c.R * 255 + 0.5), math.floor(c.G * 255 + 0.5), math.floor(c.B * 255 + 0.5) }
end
local function udim2(u)
	return { u.X.Scale, u.X.Offset, u.Y.Scale, u.Y.Offset }
end
local function udim(u)
	return { u.Scale, u.Offset }
end

-- Lune sometimes stores the font only as FontFace; recover a family name either way.
local function fontName(inst): string
	local ok, font = pcall(function()
		return inst.Font.Name
	end)
	if ok and font then
		return font
	end
	local okFace, family = pcall(function()
		return inst.FontFace.Family
	end)
	if okFace and type(family) == "string" then
		local name = family:match("families/([%w_]+)%.json")
		if name then
			return name
		end
	end
	return "GothamBold"
end

-- Reads a property Lune may not have a default for (unset engine properties).
local function prop(inst, name: string, default: any): any
	local ok, value = pcall(function()
		return inst[name]
	end)
	if ok and value ~= nil then
		return value
	end
	return default
end

-- An asset id string ("rbxassetid://...") from a Content property, trying the legacy string property
-- first (`MeshId`, `Image`, `Texture`) and then its Content twin (`MeshContent`, ...). Instances loaded
-- from .rbxm files only carry the Content form. Empty or missing values give nil.
local function contentId(inst, legacy: string, content: string): string?
	local value = prop(inst, legacy, nil)
	if type(value) == "string" and value ~= "" then
		return value
	end
	local c = prop(inst, content, nil)
	if c ~= nil then
		local ok, uri = pcall(function()
			return c.Uri
		end)
		if ok and type(uri) == "string" and uri ~= "" then
			return uri
		end
	end
	return nil
end

local GUI_CLASSES = {
	Frame = true,
	TextLabel = true,
	TextButton = true,
	ImageLabel = true,
	ImageButton = true,
	ViewportFrame = true,
	ScrollingFrame = true,
	CanvasGroup = true,
}

-- UIGradient -> { stops = {{t, r, g, b}}, transparency = {{t, a}}?, rotation }.
local function exportGradient(gradient)
	local stops = {}
	for _, kp in gradient.Color.Keypoints do
		local c = rgb(kp.Value)
		table.insert(stops, { kp.Time, c[1], c[2], c[3] })
	end
	local transparency = nil
	for _, kp in gradient.Transparency.Keypoints do
		if kp.Value > 0 then
			transparency = {}
			for _, point in gradient.Transparency.Keypoints do
				table.insert(transparency, { point.Time, point.Value })
			end
			break
		end
	end
	return { stops = stops, transparency = transparency, rotation = gradient.Rotation }
end

local function exportGui(inst)
	local node: { [string]: any } = { class = inst.ClassName, name = inst.Name, children = {} }
	local isRoot = inst:IsA("LayerCollector")
	if isRoot then
		node.visible = if inst:IsA("ScreenGui") then prop(inst, "Enabled", true) else true
		if inst:IsA("ScreenGui") then
			node.ignoreGuiInset = prop(inst, "IgnoreGuiInset", false)
			node.displayOrder = prop(inst, "DisplayOrder", 0)
		end
		node.zindex = 1
		node.layoutOrder = 0
		node.size = { 1, 0, 1, 0 }
		node.position = { 0, 0, 0, 0 }
		node.anchor = { 0, 0 }
		node.rotation = 0
		node.bg = { 0, 0, 0 }
		node.bgTransparency = 1
	else
		node.visible = inst.Visible
		node.zindex = inst.ZIndex
		node.layoutOrder = inst.LayoutOrder
		node.size = udim2(inst.Size)
		node.position = udim2(inst.Position)
		node.anchor = { inst.AnchorPoint.X, inst.AnchorPoint.Y }
		node.rotation = inst.Rotation
		node.bg = rgb(inst.BackgroundColor3)
		node.bgTransparency = inst.BackgroundTransparency
		node.clips = inst.ClipsDescendants
		node.automaticSize = inst.AutomaticSize.Name
	end
	if inst:IsA("TextLabel") or inst:IsA("TextButton") then
		node.text = inst.Text
		node.richText = inst.RichText
		node.textColor = rgb(inst.TextColor3)
		node.textTransparency = inst.TextTransparency
		node.font = fontName(inst)
		node.textScaled = inst.TextScaled
		node.textSize = inst.TextSize
		node.textWrapped = inst.TextWrapped
		node.xAlign = inst.TextXAlignment.Name
		node.yAlign = inst.TextYAlignment.Name
	end
	if inst:IsA("ImageLabel") or inst:IsA("ImageButton") then
		node.image = contentId(inst, "Image", "ImageContent") or ""
		node.imageColor = rgb(prop(inst, "ImageColor3", Color3.new(1, 1, 1)))
		node.imageTransparency = prop(inst, "ImageTransparency", 0)
		node.scaleType = prop(inst, "ScaleType", Enum.ScaleType.Stretch).Name
		local rectSize = prop(inst, "ImageRectSize", Vector2.zero)
		if rectSize.X > 0 and rectSize.Y > 0 then
			local rectOffset = prop(inst, "ImageRectOffset", Vector2.zero)
			node.imageRect = { rectOffset.X, rectOffset.Y, rectSize.X, rectSize.Y }
		end
	end
	if inst:IsA("ViewportFrame") then
		local tier = inst:GetAttribute("Tier")
		if tier then
			node.image = string.format("thumb:%s:%d:%d", variant, tier, if inst:GetAttribute("Silhouette") then 1 else 0)
		end
	end
	if inst:IsA("CanvasGroup") then
		node.groupTransparency = prop(inst, "GroupTransparency", 0)
	end
	if inst:IsA("ScrollingFrame") then
		node.scrollBarColor = rgb(inst.ScrollBarImageColor3)
		node.scrollBarTransparency = prop(inst, "ScrollBarImageTransparency", 0)
		node.clips = true
	end

	for _, child in inst:GetChildren() do
		local cls = child.ClassName
		if cls == "UICorner" then
			node.corner = udim(child.CornerRadius)
		elseif cls == "UIStroke" then
			node.stroke = {
				thickness = child.Thickness,
				color = rgb(child.Color),
				transparency = child.Transparency,
				mode = child.ApplyStrokeMode.Name,
			}
			-- A gradient inside the stroke (the glass edge fades toward the bottom).
			local strokeGradient = child:FindFirstChildOfClass("UIGradient")
			if strokeGradient then
				node.stroke.gradient = exportGradient(strokeGradient)
			end
		elseif cls == "UIGradient" then
			node.gradient = exportGradient(child)
		elseif cls == "UIPadding" then
			node.padding = { udim(child.PaddingTop), udim(child.PaddingBottom), udim(child.PaddingLeft), udim(child.PaddingRight) }
		elseif cls == "UIListLayout" then
			node.list = {
				fill = child.FillDirection.Name,
				padding = udim(child.Padding),
				hAlign = child.HorizontalAlignment.Name,
				vAlign = child.VerticalAlignment.Name,
				sort = child.SortOrder.Name,
			}
		elseif cls == "UIGridLayout" then
			node.grid = {
				cellSize = udim2(child.CellSize),
				cellPadding = udim2(child.CellPadding),
				fill = child.FillDirection.Name,
				hAlign = child.HorizontalAlignment.Name,
				vAlign = child.VerticalAlignment.Name,
				sort = child.SortOrder.Name,
			}
		elseif cls == "UIScale" then
			node.scale = child.Scale
		elseif cls == "UITextSizeConstraint" then
			node.textSizeConstraint = { min = child.MinTextSize, max = child.MaxTextSize }
		elseif GUI_CLASSES[cls] then
			table.insert(node.children, exportGui(child))
		end
	end
	return node
end

local function cframeComponents(cf)
	return { cf:GetComponents() }
end

local function exportScene(root, extra)
	local parts = {}
	local partIndex: { [number]: number } = {}
	local surfaces = {}
	local billboards = {}
	local lights = {}
	local effects = {}
	local beams = {}
	local decals = {}

	local function partId(p)
		return partIndex[idOf(p)]
	end

	for _, d in root:GetDescendants() do
		if d:IsA("BasePart") and d.Transparency < 1 then
			local shape = "Block"
			if d:IsA("Part") then
				shape = d.Shape.Name
			elseif d:IsA("WedgePart") then
				shape = "Wedge"
			end
			table.insert(parts, {
				name = d.Name,
				shape = shape,
				size = { d.Size.X, d.Size.Y, d.Size.Z },
				cf = cframeComponents(d.CFrame),
				color = rgb(d.Color),
				material = d.Material.Name,
				transparency = d.Transparency,
				group = d:GetAttribute("Group"),
				-- MeshParts: the preview draws a pinned asset's local GLB (preview/web/models/<key>.glb), else a box.
				meshId = if d:IsA("MeshPart") then contentId(d, "MeshId", "MeshContent") else nil,
			})
			partIndex[idOf(d)] = #parts
		end
	end
	for _, d in root:GetDescendants() do
		if d:IsA("SurfaceGui") and d.Parent and d.Parent:IsA("BasePart") then
			local id = partId(d.Parent)
			if id then
				table.insert(surfaces, {
					part = id,
					face = d.Face.Name,
					sizing = d.SizingMode.Name,
					pixelsPerStud = d.PixelsPerStud,
					canvas = { d.CanvasSize.X, d.CanvasSize.Y },
					lightInfluence = d.LightInfluence,
					gui = exportGui(d),
				})
			end
		elseif (d:IsA("Decal") or d:IsA("Texture")) and d.Parent and d.Parent:IsA("BasePart") then
			-- Decals / Textures: the preview draws a pinned image's local source PNG on the face.
			local id = partId(d.Parent)
			local image = contentId(d, "Texture", "TextureContent")
			if id and image and prop(d, "Transparency", 0) < 1 then
				table.insert(decals, {
					part = id,
					face = d.Face.Name,
					image = image,
					color = rgb(prop(d, "Color3", Color3.new(1, 1, 1))),
					transparency = prop(d, "Transparency", 0),
					tile = if d:IsA("Texture")
						then {
							prop(d, "StudsPerTileU", 2),
							prop(d, "StudsPerTileV", 2),
							prop(d, "OffsetStudsU", 0),
							prop(d, "OffsetStudsV", 0),
						}
						else nil,
				})
			end
		elseif d:IsA("BillboardGui") and prop(d, "Enabled", true) then
			local adornee = d.Adornee or d.Parent
			if adornee and adornee:IsA("BasePart") then
				local pos = adornee.CFrame.Position + prop(d, "StudsOffset", Vector3.zero) + prop(d, "StudsOffsetWorldSpace", Vector3.zero)
				-- Pixel-sized billboards keep a constant on-screen size; the renderer
				-- bakes them at 48 px per "stud" and sizes them by camera distance.
				local pixels = d.Size.X.Scale == 0 and d.Size.Y.Scale == 0
				local sx = if pixels then d.Size.X.Offset / 48 else d.Size.X.Scale
				local sy = if pixels then d.Size.Y.Offset / 48 else d.Size.Y.Scale
				table.insert(billboards, {
					pos = { pos.X, pos.Y, pos.Z },
					size = { sx, sy },
					pixels = if pixels then { d.Size.X.Offset, d.Size.Y.Offset } else nil,
					maxDistance = d.MaxDistance,
					alwaysOnTop = prop(d, "AlwaysOnTop", false),
					gui = exportGui(d),
				})
			end
		elseif d:IsA("Beam") and prop(d, "Enabled", true) and prop(d, "Attachment0", nil) and prop(d, "Attachment1", nil) then
			local function worldOf(att)
				return (att.Parent.CFrame * att.CFrame).Position
			end
			local a, b = worldOf(d.Attachment0), worldOf(d.Attachment1)
			table.insert(beams, {
				from = { a.X, a.Y, a.Z },
				to = { b.X, b.Y, b.Z },
				color = rgb(d.Color.Keypoints[1].Value),
				width0 = prop(d, "Width0", 1),
				width1 = prop(d, "Width1", 1),
			})
		elseif d:IsA("Highlight") and prop(d, "Enabled", true) and prop(d, "Adornee", nil) then
			local id = partId(d.Adornee)
			if id then
				parts[id].highlight = rgb(d.FillColor)
			end
		elseif (d:IsA("PointLight") or d:IsA("SpotLight")) and d.Parent and d.Parent:IsA("BasePart") then
			local p = d.Parent.CFrame.Position
			table.insert(lights, {
				kind = d.ClassName,
				pos = { p.X, p.Y, p.Z },
				color = rgb(d.Color),
				range = d.Range,
				brightness = d.Brightness,
			})
		elseif (d:IsA("ParticleEmitter") or d:IsA("Sparkles") or d:IsA("Fire")) and d.Parent and d.Parent:IsA("BasePart") then
			local p = d.Parent.CFrame.Position
			local color
			if d:IsA("ParticleEmitter") then
				color = rgb(d.Color.Keypoints[1].Value)
			elseif d:IsA("Sparkles") then
				color = rgb(d.SparkleColor)
			else
				color = rgb(d.Color)
			end
			table.insert(effects, {
				kind = d.ClassName,
				pos = { p.X, p.Y, p.Z },
				size = { d.Parent.Size.X, d.Parent.Size.Y, d.Parent.Size.Z },
				color = color,
			})
		end
	end
	local scene = {
		variant = variant,
		parts = parts,
		surfaces = surfaces,
		billboards = billboards,
		lights = lights,
		effects = effects,
		beams = beams,
		decals = decals,
	}
	for k, v in extra or {} do
		scene[k] = v
	end
	return scene
end

local function writeJson(path, data)
	fs.writeFile(path, serde.encode("json", data, false))
	print("wrote", path)
end

local function main()
	-- Server: build the world and simulate a few players -------------------------------------------

	local RS = game:GetService("ReplicatedStorage")
	local Workspace = game:GetService("Workspace")
	local Server = game:GetService("ServerScriptService").Server

	local Theme = requireModule(RS.Theme)
	local Economy = requireModule(RS.Shared.Economy)
	local Net = requireModule(RS.Shared.Net)
	local CharacterFactory = requireModule(RS.Shared.CharacterFactory)
	local Poses = requireModule(RS.Shared.Poses)
	local RigPose = requireModule(RS.Shared.RigPose)
	Net.event("State")

	-- Units animate on the client in the game; the preview freezes each one
	-- mid-pose with the same RigPose maths the client Animator uses.
	-- POSE=<name> forces one pose on every unit (handy when tuning poses).
	local forcedPose = process.env.POSE
	local function poseUnits(root, choose: ((number, string) -> string)?)
		local index = 0
		for _, d in root:GetDescendants() do
			-- Player stand-ins (with a HumanoidRootPart) keep their rest pose.
			if d:IsA("Model") and d:HasTag(Poses.TAG) and not d:GetAttribute("__posed") and not d:FindFirstChild("HumanoidRootPart") then
				index += 1
				local seed = math.random(0, 99999)
				local rig = RigPose.capture(d, seed)
				if rig then
					local names = Poses.poseNames(rig.animSet)
					local pose = forcedPose or (if choose then choose(index, rig.animSet) else names[math.random(1, #names)])
					local t = Poses.timeFor(rig.animSet, seed, pose) or math.random() * 30
					if forcedPose then
						rig.seed = 0
						local parts, cframes = RigPose.computeFrom(rig, Poses.samplePose(rig.animSet, pose, 1.3, 0))
						for i, part in parts do
							part.CFrame = cframes[i]
						end
					else
						RigPose.apply(rig, t)
					end
					d:SetAttribute("__posed", true)
				end
			end
		end
	end

	local WorldBuilder = requireModule(Server.WorldBuilder)
	local DataService = requireModule(Server.DataService)
	local Tycoon = requireModule(Server.Tycoon)

	print("[stage] building world")
	local world = WorldBuilder.build(Theme)
	-- Part budget report (static map only: units, orbs and crates come later).
	local hubParts = 0
	for _, child in Workspace.Map:GetChildren() do
		if child:IsA("BasePart") then
			hubParts += 1
		end
	end
	local plotParts = 0
	for _, d in world.plots[1].folder:GetDescendants() do
		if d:IsA("BasePart") then
			plotParts += 1
		end
	end
	print(string.format("[parts] hub %d, per plot %d", hubParts, plotParts))
	-- Crates appear quickly so the preview has some on the floor.
	Economy.CHEST_SPAWN_INTERVAL = 2
	Economy.CHEST_SPAWN_CHANCE = 1
	Tycoon.init(world, Theme)
	print("[stage] tycoon init")

	local NAMES = {
		chad = { "AuraKing", "SigmaSam", "MewMaster", "JawlineJess" },
		bot = { "BoltBoss", "GearGrace", "CircuitCody", "RivetRae" },
	}

	local function avatar(name: string): any
		local look = {
			skin = Color3.fromRGB(245, 205, 160),
			shirt = if variant == "chad" then Color3.fromRGB(30, 30, 36) else Color3.fromRGB(40, 110, 200),
			pants = Color3.fromRGB(45, 50, 70),
			anim = "Chad", -- the player stand-in is a person in both variants
			expr = "Happy",
			hair = Color3.fromRGB(70, 46, 30),
			acc = { "Cap" },
			accColor = if variant == "chad" then Color3.fromRGB(240, 190, 40) else Color3.fromRGB(255, 140, 20),
		}
		local model = CharacterFactory.build(look, name)
		local root = Instance.new("Part")
		root.Name = "HumanoidRootPart"
		root.Size = Vector3.new(2, 2, 1)
		root.CFrame = CFrame.new(0, 3, 0)
		root.Transparency = 1
		root.Anchored = true
		root.Parent = model
		return model
	end

	-- Profiles at different stages of progress.
	local function profileFor(highest: number, money: number)
		local p = DataService.defaultProfile()
		p.money = money
		p.units[1] = 0
		for tier = 1, highest do
			-- More copies of the lower tiers, a few of the top ones.
			p.units[tier] = math.max(1, math.floor((highest - tier + 1) * 0.9))
			p.discovered[tier] = FIXED_NOW - (highest - tier) * 86400 * 0.6
		end
		p.units[highest] = 2
		p.totalObtained = math.floor(2 ^ highest * 1.7)
		p.buyTier = math.max(1, highest - 6)
		p.boughtAtTier = math.floor(Economy.buyTierRequirement(p.buyTier) * 0.62)
		p.processLevel = highest * 9
		p.queue = Economy.processRate(p.processLevel) * 42
		p.pending = Economy.processRate(p.processLevel) * 37
		p.carried = Economy.productionPerSecond(p.units) * 23
		p.autoMergeOwned = true
		p.autoMerge = false
		p.lastFreeReward = FIXED_NOW - 400
		p.lastOnline = 0
		p.unlockers[1] = { rarity = "Rare", endsAt = FIXED_NOW + 734 }
		p.tutorialDone = true
		return p
	end

	-- A brand-new player who just bought their first unit (tutorial step 2).
	local function freshProfile()
		local p = DataService.defaultProfile()
		p.units[1] = 2
		p.boughtAtTier = 1
		p.totalObtained = 2
		p.money = 30
		p.lastOnline = 0
		p.lastFreeReward = FIXED_NOW - 400
		p.tutorialStep = 3
		p.carried = 14
		return p
	end

	local profiles = {
		profileFor(if variant == "chad" then 14 else 13, 3.47e6),
		profileFor(9, 48200),
		profileFor(17, 6.1e8),
		freshProfile(),
	}

	for i, name in NAMES[variant] do
		local player = Instance.new("Player")
		player.Name = name
		player.DisplayName = name
		player.UserId = 1000 + i
		-- Newer Lune only resolves Ref properties (Player.Character) within one DOM, so the
		-- fake players must live in the place's tree alongside their characters.
		player.Parent = game:GetService("Players")
		table.insert(fakePlayers, player)
	end
	for i, player in fakePlayers do
		local session = Tycoon.addPlayer(player, profiles[i], false, if i == 1 then { DoubleAura = true } else {})
		local character = avatar(player.Name)
		character.Parent = Workspace
		player.Character = character
		-- The main player wades through the orb pool; the others wait on their
		-- entrance path (off every pad so the simulation doesn't trigger them).
		local plot = session.plot
		local spot = if i == 1
			then CFrame.new(-7, plot.orbFloorY, plot.pool.minZ + 8.6) * CFrame.Angles(0, math.rad(195), 0)
			else CFrame.new(-6 + i, 0, plot.pool.minZ - 36.4) * CFrame.Angles(0, math.rad(200), 0)
		character:PivotTo(plot.cframe * spot)
	end

	print("[stage] players added")
	-- Let the real server loops run: orbs spawn, crates appear, boards update.
	for _ = 1, 9 do
		task.wait(1)
	end

	print("[stage] simulated")
	poseUnits(Workspace)
	local mainPlayer = fakePlayers[1]
	local mainSession = Tycoon.getSession(mainPlayer)
	local plotCFs = {}
	for i, plot in world.plots do
		plotCFs[i] = cframeComponents(plot.cframe)
	end

	-- Hub ranking boards: use the simulated players plus some fictional rivals.
	rankingEntries = {}
	local rivals = if variant == "chad"
		then { "GigaGrinder", "MogLord99", "RizzWizard", "SigmaStacks", "AuraAddict", "JawDropper", "LooksMaxPro" }
		else { "MechaMaven", "ServoSultan", "VoltVandal", "NanoNoah", "ByteBaron", "CoilQueen", "FluxFinn" }
	for i, name in rivals do
		table.insert(rankingEntries, { rank = 0, userId = 9000 + i, name = name, value = math.floor(4.2e9 / (i ^ 1.6)) })
	end
	for i, player in fakePlayers do
		table.insert(rankingEntries, { rank = 0, userId = player.UserId, name = player.Name, value = profiles[i].totalObtained })
	end
	table.sort(rankingEntries, function(a, b)
		return a.value > b.value
	end)
	for i, entry in rankingEntries do
		entry.rank = i
	end
	local lines = {}
	for i = 1, math.min(10, #rankingEntries) do
		local e = rankingEntries[i]
		local color = if i == 1 then "#FFD23C" elseif i == 2 then "#D8D8E6" elseif i == 3 then "#E08A4A" else "#FFFFFF"
		local formatted = requireModule(RS.Shared.Format).short(e.value)
		table.insert(lines, string.format('<font color="%s">#%d</font>  %s  <font color="#9CF0A0">%s</font>', color, i, e.name, formatted))
	end
	for _, label in world.ranking do
		label.Text = table.concat(lines, "\n")
	end

	local mainCharacter = mainPlayer.Character
	local rootCF = mainCharacter:FindFirstChild("HumanoidRootPart").CFrame
	local sceneExtra = {
		plots = plotCFs,
		player = cframeComponents(rootCF),
		theme = {
			sky = rgb(Theme.Colors.Sky),
			fog = rgb(Theme.Lighting.FogColor),
			ambient = rgb(Theme.Lighting.Ambient),
			outdoor = rgb(Theme.Lighting.OutdoorAmbient),
			atmosphere = rgb(Theme.Lighting.AtmosphereColor),
			clockTime = Theme.Lighting.ClockTime,
			bloom = Theme.Lighting.BloomIntensity,
		},
	}
	writeJson(OUT .. "/world.json", exportScene(Workspace, sceneExtra))
	local stateNormal = captured.state[mainPlayer.Name]

	-- Pick up a crate for the "holding a crate" shot and carry it across the main
	-- floor toward the crate unlockers.
	mainCharacter:PivotTo(mainSession.plot.cframe * CFrame.new(27, 0, -22) * CFrame.Angles(0, math.rad(-140), 0))
	mainSession.profile.heldChest = "Epic"
	-- The crate that was "picked up" (and any others within reach) leave the floor.
	local heldAt = mainCharacter:FindFirstChild("HumanoidRootPart").CFrame.Position
	for i = #mainSession.floorChests, 1, -1 do
		local chest = mainSession.floorChests[i]
		if (chest.position - heldAt).Magnitude < 14 then
			chest.model:Destroy()
			table.remove(mainSession.floorChests, i)
		end
	end
	task.wait(1.1)
	poseUnits(Workspace)
	writeJson(OUT .. "/world_held.json", exportScene(Workspace, sceneExtra))
	local stateHeld = captured.state[mainPlayer.Name]

	-- Showcase: all 25 tiers on a stepped stage (front row = lowest tiers).
	local showcase = Instance.new("Folder")
	showcase.Name = "Showcase"
	local stage = Instance.new("Part")
	stage.Name = "Stage"
	stage.Size = Vector3.new(120, 1, 58)
	stage.CFrame = CFrame.new(0, -0.5, 1007)
	stage.Color = Theme.Colors.Floor
	stage.Material = Enum.Material.Slate
	stage.Anchored = true
	stage.Parent = showcase
	local ROWS = { { first = 1, last = 9 }, { first = 10, last = 17 }, { first = 18, last = 25 } }
	for rowIndex, row in ROWS do
		local rise = (rowIndex - 1) * 6.5
		local z = 990 + (rowIndex - 1) * 15
		if rise > 0 then
			local riser = Instance.new("Part")
			riser.Name = "Riser"
			riser.Size = Vector3.new(104, rise, 14)
			riser.CFrame = CFrame.new(0, rise / 2, z)
			riser.Color = Theme.Colors.WallTrim
			riser.Material = Enum.Material.Metal
			riser.Anchored = true
			riser.Parent = showcase
			local trim = Instance.new("Part")
			trim.Name = "RiserNeon"
			trim.Size = Vector3.new(104, 0.3, 0.4)
			trim.CFrame = CFrame.new(0, rise - 0.1, z - 7.1)
			trim.Color = if rowIndex == 2 then Theme.Colors.Neon else Theme.Colors.NeonAlt
			trim.Material = Enum.Material.Neon
			trim.Anchored = true
			trim.Parent = showcase
		end
		local count = row.last - row.first + 1
		for tier = row.first, row.last do
			local look = Theme.Tiers[tier].Look
			local model = CharacterFactory.build(look, Theme.Tiers[tier].Name)
			-- The camera looks toward +Z, so screen-right is -X: put tier 1 at +X.
			local x = -((tier - row.first) - (count - 1) / 2) * 11
			model:PivotTo(CFrame.new(x, rise, z))
			for _, d in model:GetDescendants() do
				if d:IsA("BasePart") then
					d:SetAttribute("Group", tier)
				end
			end
			local gui = WorldBuilder.billboard(model.PrimaryPart, CharacterFactory.height(look) + 1.1, 9, 2.6)
			local band = Economy.tierBand(tier)
			WorldBuilder.label(
				gui,
				{ Text = Theme.Tiers[tier].Name, Size = roblox.UDim2.fromScale(1, 0.55), TextColor3 = Theme.Colors.Rarity[band] }
			)
			WorldBuilder.label(gui, {
				Text = "Tier " .. tier,
				Font = Theme.Fonts.Body,
				Size = roblox.UDim2.fromScale(1, 0.4),
				Position = roblox.UDim2.fromScale(0, 0.58),
				TextColor3 = Theme.Colors.TextDim,
			})
			model.Parent = showcase
		end
	end
	-- Cycle through every pose across the 25 tiers.
	poseUnits(showcase, function(index, animSet)
		local names = Poses.poseNames(animSet)
		return names[(index - 1) % #names + 1]
	end)
	showcase.Parent = Workspace
	writeJson(OUT .. "/showcase.json", exportScene(showcase, { theme = sceneExtra.theme }))

	-- Client: build the real UI and export each screen ----------------------------------------------

	mode = "client"
	local Client = game:GetService("StarterPlayer").StarterPlayerScripts.Client
	local State = requireModule(Client.State)
	local Sounds = requireModule(Client.Sounds)
	-- Stills are silent, and Lune can't read Sound.SoundId (no default), so mute playback.
	Sounds.play = function() end
	local Guide = requireModule(Client.Guide)
	local Hud = requireModule(Client.UI.Hud)
	local Windows = requireModule(Client.UI.Windows)
	local Popups = requireModule(Client.UI.Popups)
	local TutorialUI = requireModule(Client.UI.Tutorial)

	local screen = Instance.new("ScreenGui")
	screen.Name = "TycoonUI"
	-- Same UI scale and Compact flag as Main.client (58 px top bar, x1.15 on touch).
	local KitEarly = requireModule(Client.UI.Kit)
	local fit = math.min(VIEW_W / 1280, VIEW_H / 720) * (if KitEarly.touch then 1.15 else 1)
	local uiScale = Instance.new("UIScale")
	uiScale.Scale = math.clamp(fit, 0.5, 1.5)
	uiScale.Parent = screen
	screen:SetAttribute("Compact", (VIEW_H - 58) / uiScale.Scale < 600)
	screen:SetAttribute("Input", KitEarly.input)
	Popups.build(screen, Sounds)
	Windows.build(screen)
	Guide.build()
	Hud.build(screen, { openWindow = Windows.open, toast = Popups.toast }, Sounds)
	local Kit = requireModule(Client.UI.Kit)
	TutorialUI.build(screen, {
		popups = Popups,
		sounds = Sounds,
		guide = Guide,
		highlight = function(name, on)
			Kit.setGlow(Hud.buttons[name], on)
		end,
	})

	local RunService = game:GetService("RunService")
	local function settle(state)
		State.set(state)
		signalFor(RunService, "Heartbeat"):Fire(1 / 60)
	end

	local function clearTransient()
		-- Modals and the reveal close through their own paths, so the blur, the dim and the
		-- hidden HUD are released as they are in the game.
		pcall(Popups.closeModals)
		local holder = screen:FindFirstChild("Toasts")
		if holder then
			for _, child in holder:GetChildren() do
				if child:IsA("GuiObject") then
					child.Parent = nil
				end
			end
		end
		local modals = {
			"Reward",
			"Confirm",
			"ConfirmBackdrop",
			"Offline",
			"OfflineBackdrop",
			"StarterOffer",
			"StarterOfferBackdrop",
			"StarterDone",
			"StarterDoneBackdrop",
			"TutorialDone",
			"Float",
		}
		for _, name in modals do
			local existing = screen:FindFirstChild(name)
			while existing do
				existing.Parent = nil
				existing = screen:FindFirstChild(name)
			end
		end
		Windows.closeAll()
		-- Window close animations hide frames after a short delay.
		task.wait(0.3)
	end

	-- `blur` is the scene blur an open window asks for (Kit.setBlur), drawn by the renderer.
	local function shot(name)
		local effect = game:GetService("Lighting"):FindFirstChild("UiBlur")
		writeJson(OUT .. "/gui/" .. name .. ".json", {
			viewport = { VIEW_W, VIEW_H },
			blur = if effect then effect.Size else 0,
			root = exportGui(screen),
		})
	end

	-- Daily reward: day 3 of a streak is waiting (the preview runs no Server.Daily).
	stateNormal.daily = { claimable = true, day = 3, claimed = 2, streak = 2, nextIn = 5 * 3600 + 12 * 60 + 33 }
	settle(stateNormal)
	clearTransient()
	Popups.toast("Merged 12 times! Best: " .. Theme.Tiers[14].Name, "good")
	Popups.toast("A Rare " .. Theme.Words.Chest .. " appeared!", "info")
	shot("hud")

	clearTransient()
	Windows.open("Shop")
	shot("shop")

	clearTransient()
	Windows.open("Shop")
	Windows.selectShopTab("Cash")
	shot("shop_cash")
	Windows.selectShopTab("Aura")
	shot("shop_aura")
	Windows.selectShopTab("Passes")

	-- Cosmetics: this player owns the Rainbow Trail (equipped) and Speedy Sneakers.
	clearTransient()
	local stateCosmetics = table.clone(stateNormal)
	stateCosmetics.cosmetics = {
		owned = { TrailRainbow = true, SpeedBoost = true },
		trail = "TrailRainbow",
		toggles = { SpeedBoost = true, DoubleJump = true, AuraGlow = true, Crown = true },
		bundleOwned = false,
		starterOwned = false,
		starterGranted = false,
	}
	settle(stateCosmetics)
	Windows.open("Shop", { focus = "Cosmetics" })
	shot("shop_cosmetics")
	Windows.selectShopTab("Passes")
	settle(stateNormal)

	clearTransient()
	Windows.open("Index")
	shot("index")

	clearTransient()
	Windows.open("Ranking")
	task.wait(0.1)
	shot("ranking")

	clearTransient()
	Windows.open("Settings")
	shot("settings")

	clearTransient()
	Windows.open("Daily")
	shot("daily")

	clearTransient()
	settle(stateHeld)
	shot("crate")

	clearTransient()
	settle(stateNormal)
	Popups.reward({ tier = 15, new = true })
	-- Mid-hold the HUD is hidden (Kit.onWindowOpen); clearTransient closes the reveal.
	shot("reward")

	clearTransient()
	settle(stateNormal)
	Popups.offline({ seconds = 3 * 3600 + 25 * 60, orbs = 8.4e6, cash = 2.1e6 })
	shot("offline")

	-- Tutorial: the fresh player on plot 4, guided to the nearest orb.
	clearTransient()
	localIndex = 4
	local freshPlayer = fakePlayers[4]
	local stateFresh = captured.state[freshPlayer.Name]
	settle(stateFresh)
	Guide.update(0.3)
	local freshScene = exportScene(Workspace, sceneExtra)
	writeJson(OUT .. "/world_tutorial.json", freshScene)
	shot("tutorial")

	clearTransient()
	local stateDone = table.clone(stateFresh)
	stateDone.tutorialDone = true
	stateDone.tutorialStep = 6
	settle(stateDone)
	TutorialUI.onNotify({ kind = "Tutorial", event = "done", cash = 250 })
	-- The quest pill ticks and slides out, then the "complete" banner drops into its slot.
	task.wait(0.9)
	shot("tutorial_done")
	Kit.setGlow(Hud.buttons.Index, false)
	localIndex = 1

	-- Starter pack: the one-time offer and the card that celebrates the grant (last: preview
	-- modals never close, so they would hide the HUD promo in later shots).
	clearTransient()
	settle(stateNormal)
	Popups.starterOffer()
	shot("starter_offer")
	clearTransient()
	Popups.starter({ kind = "Starter", cash = 25000, item = "TrailRookie" })
	shot("starter_done")

	-- Loading screen (ReplicatedFirst) on its own ScreenGui.
	local LoadingScreen = requireModule(game:GetService("ReplicatedFirst").Loader.LoadingScreen)
	local loadingGui = Instance.new("ScreenGui")
	loadingGui.Name = "LoadingScreen"
	loadingGui.IgnoreGuiInset = true
	LoadingScreen.build(loadingGui, Theme)
	signalFor(RunService, "RenderStepped"):Fire(0.2)
	writeJson(OUT .. "/gui/loading.json", { viewport = { VIEW_W, VIEW_H }, root = exportGui(loadingGui) })

	-- Overview shot has no UI.
	clearTransient()
	local empty = Instance.new("ScreenGui")
	writeJson(OUT .. "/gui/none.json", { viewport = { VIEW_W, VIEW_H }, root = exportGui(empty) })

	print("done", variant)
end

local ok, err = xpcall(main, function(e)
	local okTrace, trace = pcall(debug.traceback)
	return tostring(e) .. "\n" .. (if okTrace then trace else "")
end)
if not ok then
	print("EXPORT FAILED:", err)
	process.exit(1)
end
process.exit(0)
