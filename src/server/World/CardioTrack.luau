--[[
	CardioTrack: the CARDIO keyboard escape out at sea (teleport-only; Modes.Cardio runs it): a
	lobby, then ten THEMED bridge rooms (tall candy walls with orange neon X-truss frames, a
	themed hazard floor, a narrow key bridge, neon-edged key blocks, a doorway in each end
	wall) with a safe zone after each. Everything is placed from Modes.CardioLayout.LAYOUT
	(pure numbers) and Modes.CardioRules; this module only builds parts at their rest pose and
	never moves or toggles anything.

	Instance contract (all anchored, under Workspace.CardioTrack, a Folder):

	  Keys/Stage<n>/Key   one BasePart per LAYOUT.keys entry (decks and blocks included), n =
	                      0..10: the `props/Key_<letter>` MeshPart (`props/KeyBlank` when a
	                      letter mesh is missing), SmoothPlastic, Color = CardioLayout.tintOf(key)
	                      (the baked dark letter stays dark). Keys are visual only (CanCollide,
	                      CanQuery, CanTouch false): see Colliders. Without any key asset "Key"
	                      is a plain tinted Part. Size (cap, KEY.height, cap) scales the mesh; top = layout y.
	                      Tag "CardioKey"; attributes Letter (string), Stage (number), Index
	                      (number, position in LAYOUT.keys), Kind ("deck"|"key"|"blink"|
	                      "mover"|"block"), Group (platform id, 0 for decks and blocks).
	    blink keys        also tag "CardioBlinkKey" + BlinkOn, BlinkPeriod, BlinkPhase (seconds):
	                      Client.Fx.Cardio fades them in sync with their platform's slab.
	    mover keys        also tag "ModeMover" + Mover = "slide", MoveAxis = (0, 0, 1),
	                      MoveDistance = travel, MovePeriod = period, MovePhase (radians) =
	                      2 pi * phase / period: Client.Fx.Modes slides them (parkour contract).
	  Colliders/KeySlab   one invisible anchored slab per LAYOUT.platforms entry, zone deck and
	                      block (its rectangle), top = key tops - PRESS (CardioLayout.PRESS, the
	                      folder's PressDepth attribute: the depth Fx.Cardio sinks pressed keys;
	                      KeyPitch = KEY.size, its lookup grid cell). Blink platform slabs: tag "BlinkPad" + BlinkOn / BlinkPeriod / BlinkPhase;
	                      mover platform slabs: tag "ModeMover" + the keys' slide attributes.
	  Zone<n>             Model per safe zone (n = 0 lobby .. 10), attribute Stage:
	    Deck              the chocolate base slab under the zone's keys (LAYOUT.bases, group 0).
	    Treadmill         Models, tag "CardioTreadmill", attributes Zone (stage), Index (1..);
	                      holds the `props/CardioTreadmill` mesh (or a part-built fallback) and
	                      a flat "Belt" part on the belt rectangle whose LookVector is the
	                      runner's forward (+X) and whose Top face carries a Texture
	                      "BeltTexture" for the client to scroll (OffsetStudsV).
	    UpgradePad        (lobby) tag "CardioUpgradePad" with the "SPEED UP" UpgradeConsole.
	    LobbyDecor        (lobby) orange Neon X trusses on its three walls and roof joists, the
	                      back-wall CARDIO title, candy clusters and warm lamps; decor only.
	  Room<n>             Model per bridge room (n = stage), attributes Stage, Theme:
	    Hazard            the hazard slab (top = room floorY over the room's inside), the
	                      theme's colour / material (liquids glossy), tag "CardioHazard",
	                      attributes Stage, Theme. Falling in is the server's killY check; the
	                      slab is solid. "HazardDecor" parts on it (candy tiles, flow streaks,
	                      wave crests, cloud puffs, neon grid, rainbow stripes) never collide.
	    Truss             orange Neon beams of the X frames (collinear beams merged; beams hidden
	                      behind wall props skipped), no collide.
	    Props             candy meshes (`props/Candy*`, vertex coloured, never tinted; a
	                      coloured ball when missing), decor only (fall through them).
	    Base / BlinkRail  chocolate slabs under the static platforms, Neon rails under blinking
	                      ones; Block<k> pillars (theme-tinted, down to the hazard) with Neon
	                      "BlockEdge" strips.
	  Walls               one part per LAYOUT.walls box in the room theme's wall colour, a
	                      dotted Texture on the faces you see, a Neon "WallTrim" on top.
	  Doors/Door<i>       Model per LAYOUT.doors entry (i = index), attributes Stage, Side, Timed:
	    DoorFrame         Neon theme-edge jambs + header through the wall.
	    DoorSlab          (timed doors only) the slab filling the doorway, tag "CardioDoor" and
	                      "BlinkPad" (BlinkPeriod = period, BlinkOn = period - open, BlinkPhase
	                      = (phase - open) mod period: solid exactly while the door is closed,
	                      CardioLayout.doorOpen), attributes DoorIndex, DoorOpen, DoorPeriod,
	                      DoorPhase, Stage.
	    CountdownSign     (timed doors) board above the doorway on its west face, tag
	                      "CardioDoorSign", attribute DoorIndex; its SurfaceGui holds a
	                      TextLabel "Countdown" (default "GO!") the client drives.
	  Signs               StageSign<n> through the west wall of bridge room n, above the
	                      doorway: "STAGE n" / name / "NEED x SPEED" on both faces; the lobby
	                      side of room 1 also carries the giant CARDIO title; FinishSign on the
	                      finish cap wall.
	  FinishPodium        Model on the stage-10 deck (LAYOUT.finish).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Common = require(script.Parent.Common)
local AssetModels = require(ReplicatedStorage.Shared.AssetModels)
local Assets = require(ReplicatedStorage.Shared.Assets)
local Format = require(ReplicatedStorage.Shared.Format)
local Layout = require(script.Parent.Parent.Modes.CardioLayout)
local Rules = require(script.Parent.Parent.Modes.CardioRules)

local theme = Common.theme
local make = Common.make
local UPRIGHT = Common.UPRIGHT
local W = theme.World
local CYLINDER = Enum.PartType.Cylinder
local BALL = Enum.PartType.Ball
local NEON = Enum.Material.Neon

local CardioTrack = {}

export type Built = {
	folder: Folder,
	-- Key parts by LAYOUT.keys index.
	keys: { BasePart },
	-- Safe zone models and their deck base slabs by stage (0 = lobby).
	zones: { [number]: Model },
	decks: { [number]: BasePart },
	upgradePad: BasePart,
	treadmills: { Model },
	-- Bridge room models and hazard slabs by stage; timed door slabs by LAYOUT.doors index.
	rooms: { [number]: Model },
	hazards: { [number]: BasePart },
	doors: { [number]: BasePart },
}

local LAYOUT = Layout.LAYOUT
local O = Layout.ORIGIN
local TOP = O.y
local KEY = Layout.KEY
-- Keys are visual only: each walkable surface has one invisible collision slab whose top is
-- PRESS below the key tops, and Fx.Cardio sinks the keys under feet by exactly PRESS (the
-- folder's PressDepth attribute), so feet rest on fully pressed keys and never bounce.
local PRESS = Layout.PRESS
local DW = Layout.DOOR_WALL
-- props/CardioTreadmill belt in mesh space (origin = base centre, runner faces -Z).
local BELT = { top = 1.4, chevronTop = 1.435, x0 = -2.15, x1 = 2.15, z0 = -3.236, z1 = 5.364 }
local BELT_W = BELT.x1 - BELT.x0
local BELT_L = BELT.z1 - BELT.z0
local BELT_CZ = (BELT.z0 + BELT.z1) / 2
local BELT_COLOUR = Color3.fromRGB(70, 72, 92)
local BELT_PRINT = Color3.fromRGB(34, 34, 48)
local CHOCOLATE_DARK = Color3.fromRGB(62, 34, 22)
-- PointLights stay under this many.
local MAX_LIGHTS = 38
local lightCount = 0

local function decor(p: BasePart): BasePart
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	return p
end

local function add(parent: Instance, props: { [string]: any }): BasePart
	props.Parent = parent
	return make("Part", props)
end

local function glow(parent: Instance, props: { [string]: any }): BasePart
	props.Material = NEON
	props.CastShadow = false
	return decor(add(parent, props))
end

local function disc(parent: Instance, name: string, pos: Vector3, d: number, h: number, colour: Color3): BasePart
	return add(parent, {
		Name = name,
		Shape = CYLINDER,
		Size = Vector3.new(h, d, d),
		CFrame = CFrame.new(pos) * UPRIGHT,
		Color = colour,
	})
end

local function folderIn(parent: Instance, name: string, className: string?): Instance
	local f = Instance.new(className or "Folder")
	f.Name = name
	f.Parent = parent
	return f
end

local function c3(c: Layout.RGB): Color3
	return Color3.fromRGB(c.r, c.g, c.b)
end

local function themeOf(stage: number): Layout.Theme
	return Layout.themeOf(math.max(stage, 0))
end

-- Accent colour of a stage (its theme's neon edge).
local function stageColour(stage: number): Color3
	return c3(themeOf(stage).edge)
end

local function light(parent: BasePart, colour: Color3, range: number, brightness: number)
	if lightCount >= MAX_LIGHTS then
		return
	end
	lightCount += 1
	local l = Instance.new("PointLight")
	l.Color = colour
	l.Range = range
	l.Brightness = brightness
	l.Shadows = false
	l.Parent = parent
end

-- Park-Miller LCG for the decor scatter (deterministic per stage).
local function rng(seed: number): () -> number
	local state = (seed * 7919 + 17) % 2147483647
	return function()
		state = (state * 16807) % 2147483647
		return state / 2147483647
	end
end

-- Signs ----------------------------------------------------------------------------------

-- A SurfaceGui on `face` of p; labels go straight into it (no wrapper frames: instance budget).
local function surface(p: BasePart, face: Enum.NormalId, pixelsPerStud: number): SurfaceGui
	local gui = Instance.new("SurfaceGui")
	gui.Face = face
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = pixelsPerStud
	gui.LightInfluence = 0
	gui.Parent = p
	return gui
end

local function text(parent: Instance, props: { [string]: any }): TextLabel
	local l = Instance.new("TextLabel")
	l.BackgroundTransparency = 1
	l.BorderSizePixel = 0
	l.TextScaled = true
	l.Font = theme.Fonts.Display
	l.TextColor3 = W.Ink
	l.Size = UDim2.fromScale(1, 1)
	for key, value in props do
		(l :: any)[key] = value
	end
	l.Parent = parent
	return l
end

-- A bubbly outline on a label's glyphs.
local function outline(label: TextLabel, colour: Color3, thickness: number)
	local s = Instance.new("UIStroke")
	s.Color = colour
	s.Thickness = thickness
	s.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
	s.Parent = label
end

-- Keys -----------------------------------------------------------------------------------

local templates: { [string]: MeshPart | false } = {}

-- A fresh MeshPart of the model `key` (cached template), or nil when it is missing.
local function meshOf(key: string): MeshPart?
	local cached = templates[key]
	if cached == nil then
		cached = false
		local clone = AssetModels.clone(key)
		if clone then
			local found = if clone:IsA("MeshPart") then clone else clone:FindFirstChildWhichIsA("MeshPart", true)
			if found then
				local mesh = found :: MeshPart
				mesh.Parent = nil
				cached = mesh
			end
			if clone ~= found then
				clone:Destroy()
			end
		end
		templates[key] = cached
	end
	if cached then
		local m = (cached :: MeshPart):Clone()
		m.Anchored = true
		return m
	end
	return nil
end

local function keyMesh(letter: string): MeshPart?
	return meshOf("props/Key_" .. letter) or meshOf("props/KeyBlank")
end

local function setKeyAttributes(part: BasePart, key: Layout.Key, index: number)
	part.Name = "Key"
	part:AddTag("CardioKey")
	part:SetAttribute("Letter", key.letter)
	part:SetAttribute("Stage", key.stage)
	part:SetAttribute("Index", index)
	part:SetAttribute("Kind", key.kind)
	part:SetAttribute("Group", key.group)
	if key.kind == "blink" then
		part:SetAttribute("BlinkOn", key.blinkOn)
		part:SetAttribute("BlinkPeriod", key.blinkPeriod)
		part:SetAttribute("BlinkPhase", key.phase or 0)
		-- Not "BlinkPad": keys never collide (the platform's slab blinks); Fx.Cardio fades them.
		part:AddTag("CardioBlinkKey")
	elseif key.kind == "mover" then
		local period = key.period :: number
		part:SetAttribute("Mover", "slide")
		part:SetAttribute("MoveAxis", Vector3.new(0, 0, 1))
		part:SetAttribute("MoveDistance", key.travel)
		part:SetAttribute("MovePeriod", period)
		part:SetAttribute("MovePhase", 2 * math.pi * (key.phase or 0) / period)
		part:AddTag("ModeMover")
	end
end

local function buildKey(parent: Instance, key: Layout.Key, index: number): BasePart
	local gap = KEY.size - KEY.cap
	local size = Vector3.new(key.sx - gap, KEY.height, key.sz - gap)
	local cf = CFrame.new(key.x, key.y - KEY.height / 2, key.z)
	local tint = Layout.tintOf(key)
	local colour = Color3.fromRGB(tint.r, tint.g, tint.b)
	local mesh = keyMesh(key.letter)
	local root: BasePart
	if mesh then
		mesh.Size = size
		mesh.CFrame = cf
		mesh.Color = colour
		mesh.Material = Enum.Material.SmoothPlastic
		-- Visual only: the surface's collision slab (PRESS below the tops) carries feet.
		mesh.CanCollide = false
		mesh.CanQuery = false
		mesh.CanTouch = false
		mesh.CastShadow = true
		mesh.Parent = parent
		root = mesh
	else
		root = add(parent, { Size = size, CFrame = cf, Color = colour, CanCollide = false, CanQuery = false, CanTouch = false })
	end
	setKeyAttributes(root, key, index)
	return root
end

-- Hazard floors -------------------------------------------------------------------------

local RAINBOW = {
	Color3.fromRGB(255, 120, 130),
	Color3.fromRGB(255, 180, 100),
	Color3.fromRGB(255, 236, 120),
	Color3.fromRGB(140, 236, 140),
	Color3.fromRGB(120, 210, 255),
	Color3.fromRGB(150, 150, 255),
	Color3.fromRGB(220, 140, 255),
}

-- A flat decor plate lying on the hazard (top just above floorY).
local function plate(parent: Instance, x: number, z: number, sx: number, sz: number, y: number, props: { [string]: any }): BasePart
	props.Name = props.Name or "HazardDecor"
	props.Size = Vector3.new(sx, 0.4, sz)
	props.CFrame = CFrame.new(x, y - 0.1, z)
	props.CastShadow = false
	return decor(add(parent, props))
end

-- The hazard slab of a bridge room plus its theme's surface pattern.
local function hazard(model: Instance, room: Layout.Room): BasePart
	local look = themeOf(room.stage)
	local hz = look.hazard
	local ix0, ix1 = room.x0 + DW, room.x1 - DW
	local sx, sz = ix1 - ix0, room.z1 - room.z0
	local cx, cz = (ix0 + ix1) / 2, (room.z0 + room.z1) / 2
	local y = room.floorY
	local colour = c3(hz.color)
	local material = (Enum.Material :: any)[hz.material] or Enum.Material.SmoothPlastic
	local slabColour, slabMaterial = colour, material
	if hz.pattern == "grid" then
		slabColour, slabMaterial = Color3.fromRGB(92, 64, 190), Enum.Material.SmoothPlastic
	elseif hz.pattern == "stripes" then
		slabColour, slabMaterial = Color3.fromRGB(255, 248, 255), Enum.Material.SmoothPlastic
	end
	local bottom = Layout.WALL.bottom
	local slab = add(model, {
		Name = "Hazard",
		Size = Vector3.new(sx, y - bottom, sz),
		CFrame = CFrame.new(cx, (y + bottom) / 2, cz),
		Color = slabColour,
		Material = slabMaterial,
		-- Glossy candy: liquids shine, hard candy floors get a light sheen.
		Reflectance = if material == NEON then 0 elseif hz.liquid then 0.2 else 0.08,
		CastShadow = false,
		CanTouch = false,
	})
	slab:AddTag("CardioHazard")
	slab:SetAttribute("Stage", room.stage)
	slab:SetAttribute("Theme", room.theme)

	local rand = rng(room.stage)
	local pattern = hz.pattern
	if pattern == "tiles" then
		-- Glossy hard-candy tiles: a checker of a lighter second shade over the slab.
		local rows = 6
		local cell = sz / rows
		local cols = math.max(1, math.floor(sx / cell + 0.5))
		local cw = sx / cols
		local shade = colour:Lerp(if colour.B > 0.6 then Color3.fromRGB(190, 140, 255) else Color3.fromRGB(255, 214, 220), 0.5)
		for i = 0, cols - 1 do
			for j = 0, rows - 1 do
				if (i + j) % 2 == 0 then
					plate(model, ix0 + (i + 0.5) * cw, room.z0 + (j + 0.5) * cell, cw, cell, y, { Color = shade, Reflectance = 0.12 })
				end
			end
		end
	elseif pattern == "river" then
		-- Glossy flow streaks along the river: creamy swirls in two lighter shades.
		local cream = Color3.fromRGB(255, 236, 205)
		for i = 1, 14 do
			local len = sx * (0.18 + rand() * 0.3)
			plate(model, ix0 + len / 2 + rand() * (sx - len), room.z0 + 5 + rand() * (sz - 10), len, 1.4 + rand() * 2.4, y, {
				Color = colour:Lerp(cream, if i % 2 == 0 then 0.55 else 0.3),
				Material = if material == NEON then NEON else Enum.Material.SmoothPlastic,
				Reflectance = if material == NEON then 0 else 0.3,
				Transparency = 0.15,
			})
		end
	elseif pattern == "waves" then
		-- Pale wave crests across the room.
		local crest = colour:Lerp(Color3.new(1, 1, 1), 0.45)
		local count = math.floor(sx / 18)
		for i = 1, count do
			plate(model, ix0 + (i - 0.5) * sx / count, cz, 1.6, sz, y, {
				Color = crest,
				Material = material,
				Reflectance = 0.2,
				Transparency = 0.35,
			})
		end
	elseif pattern == "clouds" then
		-- Fluffy puffs half-sunk in the cotton candy.
		for _ = 1, 16 do
			local d = 10 + rand() * 10
			decor(add(model, {
				Name = "HazardDecor",
				Shape = BALL,
				Size = Vector3.new(d, d, d),
				CFrame = CFrame.new(ix0 + d / 2 + rand() * (sx - d), y - d * 0.36, room.z0 + d / 2 + rand() * (sz - d)),
				Color = colour:Lerp(if rand() < 0.5 then Color3.new(1, 1, 1) else Color3.fromRGB(200, 215, 255), 0.5),
				CastShadow = false,
			}))
		end
	elseif pattern == "grid" then
		-- A neon grid on a midnight floor.
		local step = 14
		for i = 1, math.floor(sx / step) do
			plate(model, ix0 + i * step, cz, 0.6, sz, y, { Color = colour, Material = NEON })
		end
		for j = 1, math.floor(sz / step) do
			plate(model, cx, room.z0 + j * step, sx, 0.6, y, { Color = colour, Material = NEON })
		end
	elseif pattern == "stripes" then
		-- Rainbow bands across the room with thin neon seams.
		local bands = 14
		local bw = sx / bands
		for i = 0, bands - 1 do
			plate(model, ix0 + (i + 0.5) * bw, cz, bw, sz, y, { Color = RAINBOW[i % #RAINBOW + 1], Reflectance = 0.1 })
			if i > 0 then
				plate(model, ix0 + i * bw, cz, 0.5, sz, y + 0.05, { Color = Color3.new(1, 1, 1), Material = NEON })
			end
		end
	end
	return slab
end

-- Walls ------------------------------------------------------------------------------------

local WALL_FACES: { [string]: { Enum.NormalId } } = {
	south = { Enum.NormalId.Back },
	north = { Enum.NormalId.Front },
	west = { Enum.NormalId.Right },
	east = { Enum.NormalId.Left },
}

-- One part per layout wall box: theme wall colour, a dotted candy texture on the faces you
-- see (both faces of the door walls), a Neon edge-colour trim along the top.
local function buildWalls(parent: Instance)
	local dots = Assets.image("vfx/SoftDot")
	for _, w in LAYOUT.walls do
		local look = themeOf(w.stage)
		local colour = c3(look.wall)
		local p = add(parent, {
			Name = "Wall",
			Size = Vector3.new(w.sx, w.sy, w.sz),
			CFrame = CFrame.new(w.x, w.y, w.z),
			Color = colour,
		})
		p:SetAttribute("Stage", w.stage)
		if w.part == "under" then
			continue
		end
		local faces = if w.part == "full" then WALL_FACES[w.side] else { Enum.NormalId.Left, Enum.NormalId.Right }
		if dots and faces then
			local bright = colour.R + colour.G + colour.B > 1.2
			for _, face in faces do
				local tex = Instance.new("Texture")
				tex.Name = "WallDots"
				tex.Face = face
				tex.Texture = dots
				tex.Color3 = if bright then colour:Lerp(c3(look.edge), 0.35) else colour:Lerp(Color3.new(1, 1, 1), 0.25)
				tex.StudsPerTileU = 7
				tex.StudsPerTileV = 7
				tex.Transparency = 0.25
				tex.Parent = p
			end
		end
		local top = w.y + w.sy / 2
		glow(parent, {
			Name = "WallTrim",
			Size = Vector3.new(w.sx + 0.2, 0.8, w.sz + 0.2),
			CFrame = CFrame.new(w.x, top + 0.4, w.z),
			Color = c3(look.edge),
		})
	end
end

-- Doors ------------------------------------------------------------------------------------

local FRAME = 1.2

-- A doorway: Neon jambs and header through the wall; timed doors also get the closing slab
-- (a BlinkPad solid exactly while the door is closed) and a countdown board above.
local function door(parent: Instance, d: Layout.Door, index: number): BasePart?
	local edge = stageColour(d.stage)
	local model = folderIn(parent, "Door" .. index, "Model")
	model:SetAttribute("Stage", d.stage)
	model:SetAttribute("Side", d.side)
	model:SetAttribute("Timed", d.timed)
	model:SetAttribute("DoorIndex", index)
	local depth = DW + 0.8
	for _, s in { -1, 1 } do
		glow(model, {
			Name = "DoorFrame",
			Size = Vector3.new(depth, d.height + FRAME, FRAME),
			CFrame = CFrame.new(d.x, d.y + (d.height + FRAME) / 2, d.z + s * (d.width + FRAME) / 2),
			Color = edge,
		})
	end
	glow(model, {
		Name = "DoorFrame",
		Size = Vector3.new(depth, FRAME, d.width + 2 * FRAME),
		CFrame = CFrame.new(d.x, d.y + d.height + FRAME / 2, d.z),
		Color = edge,
	})
	if not d.timed then
		return nil
	end
	local slab = add(model, {
		Name = "DoorSlab",
		Size = Vector3.new(0.8, d.height, d.width),
		CFrame = CFrame.new(d.x, d.y + d.height / 2, d.z),
		Color = edge:Lerp(W.White, 0.35),
		Transparency = 0.1,
		CanTouch = false,
		CastShadow = false,
	})
	local dots = Assets.image("vfx/SoftDot")
	if dots then
		for _, face in { Enum.NormalId.Left, Enum.NormalId.Right } do
			local tex = Instance.new("Texture")
			tex.Face = face
			tex.Texture = dots
			tex.Color3 = edge
			tex.StudsPerTileU = KEY.size
			tex.StudsPerTileV = KEY.size
			tex.Parent = slab
		end
	end
	slab:AddTag("CardioDoor")
	slab:AddTag("BlinkPad")
	slab:SetAttribute("DoorIndex", index)
	slab:SetAttribute("Stage", d.stage)
	slab:SetAttribute("DoorOpen", d.open)
	slab:SetAttribute("DoorPeriod", d.period)
	slab:SetAttribute("DoorPhase", d.phase)
	-- Blink pads are solid while ((t + BlinkPhase) % BlinkPeriod) < BlinkOn; the door is
	-- closed while ((t + phase) % period) >= open.
	slab:SetAttribute("BlinkPeriod", d.period)
	slab:SetAttribute("BlinkOn", d.period - d.open)
	slab:SetAttribute("BlinkPhase", (d.phase - d.open) % d.period)

	-- Countdown board on the wall's west face, above the doorway: a big Ink board in a Neon
	-- frame with one huge, thick-outlined number the client writes.
	local w = math.max(d.width + 8, 22)
	local h = 11
	local x = d.x - DW / 2
	local y = d.y + d.height + FRAME + 1.5 + h / 2
	glow(model, {
		Name = "CountdownGlow",
		Size = Vector3.new(0.4, h + 1.6, w + 1.6),
		CFrame = CFrame.new(x - 0.2, y, d.z),
		Color = edge,
	})
	local board = decor(add(model, {
		Name = "CountdownSign",
		Size = Vector3.new(0.6, h, w),
		CFrame = CFrame.new(x - 0.3, y, d.z),
		Color = W.Ink,
	}))
	board:AddTag("CardioDoorSign")
	board:SetAttribute("DoorIndex", index)
	local label = text(surface(board, Enum.NormalId.Left, 20), {
		Name = "Countdown",
		Text = "GO!",
		TextColor3 = Color3.fromRGB(120, 255, 140),
		Size = UDim2.fromScale(0.94, 0.9),
		Position = UDim2.fromScale(0.03, 0.05),
	})
	outline(label, Color3.new(0, 0, 0), 10)
	light(board, edge, 20, 1.2)
	return slab
end

-- Trusses ------------------------------------------------------------------------------------

-- The layout's beams with collinear axis-aligned runs merged and duplicates dropped; returns
-- { a, b, thick, stage } segments.
local function mergedBeams(): { { a: Vector3, b: Vector3, thick: number, stage: number } }
	local out = {}
	local function r(v: number): string
		return string.format("%.2f", v)
	end
	type Run = { axis: number, lo: number, hi: number, fixed: Vector3, thick: number, stage: number }
	local lines: { [string]: { Run } } = {}
	local seen: { [string]: boolean } = {}
	for _, beam in LAYOUT.trusses do
		local a = Vector3.new(beam.a.x, beam.a.y, beam.a.z)
		local b = Vector3.new(beam.b.x, beam.b.y, beam.b.z)
		local d = b - a
		local axis = 0
		if math.abs(d.Y) < 1e-3 and math.abs(d.Z) < 1e-3 then
			axis = 1
		elseif math.abs(d.X) < 1e-3 and math.abs(d.Z) < 1e-3 then
			axis = 2
		elseif math.abs(d.X) < 1e-3 and math.abs(d.Y) < 1e-3 then
			axis = 3
		end
		if axis == 0 then
			local k1, k2 = r(a.X) .. r(a.Y) .. r(a.Z), r(b.X) .. r(b.Y) .. r(b.Z)
			local id = if k1 < k2 then k1 .. k2 else k2 .. k1
			if not seen[id] then
				seen[id] = true
				table.insert(out, { a = a, b = b, thick = beam.thick, stage = beam.stage })
			end
		else
			local comp = { a.X, a.Y, a.Z }
			local compB = { b.X, b.Y, b.Z }
			local fixed = Vector3.new(if axis == 1 then 0 else a.X, if axis == 2 then 0 else a.Y, if axis == 3 then 0 else a.Z)
			local id = axis .. ":" .. r(fixed.X) .. r(fixed.Y) .. r(fixed.Z) .. ":" .. beam.stage
			local list = lines[id]
			if not list then
				list = {}
				lines[id] = list
			end
			table.insert(list, {
				axis = axis,
				lo = math.min(comp[axis], compB[axis]),
				hi = math.max(comp[axis], compB[axis]),
				fixed = fixed,
				thick = beam.thick,
				stage = beam.stage,
			})
		end
	end
	local ids = {}
	for id in lines do
		table.insert(ids, id)
	end
	table.sort(ids)
	for _, id in ids do
		local list = lines[id]
		table.sort(list, function(p: Run, q: Run)
			return p.lo < q.lo
		end)
		local cur: Run? = nil
		local function flush()
			if cur then
				local c = cur :: Run
				local unit = if c.axis == 1 then Vector3.xAxis elseif c.axis == 2 then Vector3.yAxis else Vector3.zAxis
				table.insert(out, { a = c.fixed + unit * c.lo, b = c.fixed + unit * c.hi, thick = c.thick, stage = c.stage })
			end
		end
		for _, run in list do
			if cur and run.lo <= (cur :: Run).hi + 0.01 then
				(cur :: Run).hi = math.max((cur :: Run).hi, run.hi)
			else
				flush()
				cur = { axis = run.axis, lo = run.lo, hi = run.hi, fixed = run.fixed, thick = run.thick, stage = run.stage }
			end
		end
		flush()
	end
	return out
end

-- Orange Neon X-frame beams into each room's Truss folder; returns the part count.
local function buildTrusses(trussFolders: { [number]: Instance }): number
	-- Wall props hide the beams right behind them: skip those (instance budget).
	local hiders: { [number]: { { pos: Vector3, r: number } } } = {}
	for _, p in LAYOUT.props do
		if p.wall then
			local list = hiders[p.stage] or {}
			hiders[p.stage] = list
			table.insert(list, { pos = Vector3.new(p.x, p.y, p.z), r = p.scale * 0.45 })
		end
	end
	local function hidden(stage: number, mid: Vector3): boolean
		local list = hiders[stage]
		if not list then
			return false
		end
		for _, h in list do
			if math.abs(h.pos.Z - mid.Z) < 3 and Vector2.new(h.pos.X - mid.X, h.pos.Y - mid.Y).Magnitude < h.r then
				return true
			end
		end
		return false
	end
	local count = 0
	for _, beam in mergedBeams() do
		local parent = trussFolders[beam.stage]
		if parent and not hidden(beam.stage, (beam.a + beam.b) / 2) then
			local len = (beam.b - beam.a).Magnitude
			local mid = (beam.a + beam.b) / 2
			local d = beam.b - beam.a
			local vertical = math.abs(d.X) < 1e-3 and math.abs(d.Z) < 1e-3
			glow(parent, {
				Name = "Truss",
				-- Overlap the joints by one beam thickness.
				Size = if vertical
					then Vector3.new(beam.thick, len + beam.thick, beam.thick)
					else Vector3.new(beam.thick, beam.thick, len + beam.thick),
				CFrame = if vertical then CFrame.new(mid) else CFrame.lookAt(mid, beam.b),
				Color = c3(themeOf(beam.stage).truss),
			})
			count += 1
		end
	end
	return count
end

-- Pads, treadmills --------------------------------------------------------------

local function upgradePad(parent: Instance, zone: Layout.Zone): BasePart
	local pad = zone.upgradePad :: Layout.Pad
	local s = pad.size
	decor(add(parent, {
		Name = "UpgradeGlow",
		Size = Vector3.new(s + 1, 0.3, s + 1),
		CFrame = CFrame.new(pad.x, TOP + 0.15, pad.z),
		Color = W.Orange,
		Material = Enum.Material.Neon,
		CastShadow = false,
	}))
	local part = add(parent, {
		Name = "UpgradePad",
		Size = Vector3.new(s, 0.5, s),
		CFrame = CFrame.new(pad.x, TOP + 0.25, pad.z),
		Color = W.Orange:Lerp(W.White, 0.2),
	})
	part:AddTag("CardioUpgradePad")
	-- Console on the pad's outer (-Z) side, its screen facing the corridor's centre line.
	local console = folderIn(parent, "UpgradeConsole", "Model")
	local cz = pad.z - s / 2 - 1.2
	add(console, {
		Name = "ConsolePost",
		Size = Vector3.new(1.4, 4.2, 1.4),
		CFrame = CFrame.new(pad.x, TOP + 2.1, cz),
		Color = W.Teal,
	})
	local screen = add(console, {
		Name = "ConsoleScreen",
		Size = Vector3.new(8, 4.4, 0.8),
		CFrame = CFrame.new(pad.x, TOP + 6, cz) * CFrame.Angles(math.rad(-15), math.pi, 0),
		Color = W.Cream,
	})
	local gui = surface(screen, Enum.NormalId.Front, 40)
	text(gui, {
		Text = "TREADMILL",
		TextColor3 = W.White,
		BackgroundTransparency = 0,
		BackgroundColor3 = W.Orange,
		Size = UDim2.fromScale(1, 0.36),
	})
	text(gui, { Text = "SPEED UP", Size = UDim2.fromScale(0.9, 0.5), Position = UDim2.fromScale(0.05, 0.42) })
	return part
end

local function fallbackTreadmill(model: Model, cf: CFrame)
	add(model, {
		Name = "TreadmillBase",
		Size = Vector3.new(BELT_W + 1.6, BELT.top, 12),
		CFrame = cf * CFrame.new(0, BELT.top / 2, 0),
		Color = W.Teal,
	})
	add(model, {
		Name = "TreadmillConsole",
		Size = Vector3.new(BELT_W + 1.6, 1.6, 1),
		CFrame = cf * CFrame.new(0, BELT.top + 4.4, -5) * CFrame.Angles(math.rad(-25), 0, 0),
		Color = W.Coral,
	})
end

local function treadmill(parent: Instance, stage: number, index: number, tm: Layout.Treadmill): Model
	local model = folderIn(parent, "Treadmill", "Model") :: Model
	model:SetAttribute("Zone", stage)
	model:SetAttribute("Index", index)
	model:AddTag("CardioTreadmill")
	local floor = tm.y - Layout.TREADMILL.height
	-- Belt centre on (x, z), the runner facing the yaw's look vector.
	local beltCentre = CFrame.new(tm.x, floor + BELT.top, tm.z) * CFrame.Angles(0, tm.yaw, 0)
	local cf = beltCentre * CFrame.new(0, -BELT.top, -BELT_CZ)
	local mesh = meshOf("props/CardioTreadmill")
	if mesh then
		mesh.Name = "TreadmillMesh"
		mesh.CFrame = cf * CFrame.new(0, mesh.Size.Y / 2, 0)
		mesh.Parent = model
		model.PrimaryPart = mesh
	else
		fallbackTreadmill(model, cf)
	end
	local t = 0.1
	local belt = add(model, {
		Name = "Belt",
		Size = Vector3.new(BELT_W, t, BELT_L),
		CFrame = beltCentre * CFrame.new(0, BELT.chevronTop - BELT.top + 0.02 + t / 2, 0),
		Color = BELT_COLOUR,
		CastShadow = false,
	})
	local tex = Instance.new("Texture")
	tex.Name = "BeltTexture"
	tex.Face = Enum.NormalId.Top
	tex.Texture = Assets.image("vfx/SoftDot") or ""
	tex.Color3 = BELT_PRINT
	tex.StudsPerTileU = 1.4
	tex.StudsPerTileV = 1.4
	tex.Parent = belt
	if not model.PrimaryPart then
		model.PrimaryPart = belt
	end
	return model
end

-- Bases, blocks, props -----------------------------------------------------------------------

local function base(parent: Instance, b: Layout.Base, name: string): BasePart
	local p = add(parent, {
		Name = name,
		Size = Vector3.new(b.sx, b.sy, b.sz),
		CFrame = CFrame.new(b.x, b.y, b.z),
		Color = CHOCOLATE_DARK,
		CastShadow = false,
	})
	p:SetAttribute("Group", b.group)
	return p
end

-- A raised key block's pillar (theme-tinted, down to the hazard) with a Neon edge rim just
-- under the keys.
local function blockPillar(parent: Instance, b: Layout.Base)
	local look = themeOf(b.stage)
	local model = folderIn(parent, "Block" .. (b.block :: number), "Model")
	model:SetAttribute("Block", b.block)
	local pillar = base(model, b, "BlockPillar")
	pillar.Color = c3(look.wall):Lerp(c3(look.keys[1]), 0.5)
	local edge = c3(look.edge)
	local top = b.y + b.sy / 2
	local x0, x1, z0, z1 = b.x - b.sx / 2, b.x + b.sx / 2, b.z - b.sz / 2, b.z + b.sz / 2
	local s = 0.6
	for _, z in { z0, z1 } do
		glow(model, { Name = "BlockEdge", Size = Vector3.new(b.sx + s, s, s), CFrame = CFrame.new(b.x, top - s / 2, z), Color = edge })
	end
	for _, x in { x0, x1 } do
		glow(model, { Name = "BlockEdge", Size = Vector3.new(s, s, b.sz + s), CFrame = CFrame.new(x, top - s / 2, b.z), Color = edge })
	end
end

-- Candy meshes lying this flat (depth / largest side) lie down on the floor.
local FLAT = 0.4

-- One candy prop: the vertex-coloured `props/<kind>` mesh scaled so its largest side is
-- `scale` (never tinted), or a coloured ball when the mesh is missing. Decor only.
local function prop(parent: Instance, p: Layout.Prop)
	local mesh = meshOf("props/" .. p.kind)
	local part: BasePart
	local size: Vector3
	if mesh then
		local s = mesh.Size
		size = s * (p.scale / math.max(s.X, s.Y, s.Z))
		mesh.Size = size
		mesh.Parent = parent
		part = mesh
	else
		size = Vector3.new(p.scale, p.scale * 0.8, p.scale)
		local keys = themeOf(p.stage).keys
		part = add(parent, {
			Shape = BALL,
			Size = size,
			Color = c3(keys[(math.floor(p.x + p.z) % #keys) + 1]),
		})
	end
	part.Name = p.kind
	decor(part)
	if p.wall then
		local nv = p.normal or { x = 0, y = 0, z = 1 }
		local n = Vector3.new(nv.x, nv.y, nv.z)
		local pos = Vector3.new(p.x, p.y, p.z) + n * (size.Z / 2)
		-- Front (-Z) into the room, a playful tilt about the normal.
		part.CFrame = CFrame.lookAt(pos, pos + n) * CFrame.Angles(0, 0, (p.yaw % 1) - 0.5)
	elseif size.Z < FLAT * math.max(size.X, size.Y) then
		-- Lollipops, bars, swirls, cookies: lying on their back, front up.
		local bottom = if p.float then p.y + 0.3 * p.scale - 0.4 * size.Z else p.y
		part.CFrame = CFrame.new(p.x, bottom + size.Z / 2, p.z) * CFrame.Angles(0, p.yaw, 0) * CFrame.Angles(math.pi / 2, 0, 0)
	else
		part.CFrame = CFrame.new(p.x, p.y + size.Y / 2, p.z) * CFrame.Angles(0, p.yaw, 0)
	end
end

-- Signs, finish --------------------------------------------------------------------------------

-- A 3-line stage card: an accent header band ("STAGE n"), the stage name in big outlined
-- accent letters, and an Ink foot band with Sunny text.
local function stageCard(p: BasePart, face: Enum.NormalId, accent: Color3, header: string, title: string, foot: string)
	local gui = surface(p, face, 12)
	outline(
		text(gui, {
			Text = header,
			TextColor3 = W.White,
			BackgroundTransparency = 0,
			BackgroundColor3 = accent,
			Size = UDim2.fromScale(1, 0.28),
		}),
		W.Ink,
		3
	)
	outline(
		text(gui, {
			Text = title,
			TextColor3 = accent,
			Size = UDim2.fromScale(0.94, 0.38),
			Position = UDim2.fromScale(0.03, 0.31),
		}),
		W.Ink,
		5
	)
	text(gui, {
		Text = foot,
		TextColor3 = W.Sunny,
		BackgroundTransparency = 0,
		BackgroundColor3 = W.Ink,
		Size = UDim2.fromScale(1, 0.26),
		Position = UDim2.fromScale(0, 0.74),
	})
end

local function cardioTitle(model: Instance, x: number, y: number, z: number)
	local w, h = 64, 16
	glow(model, { Name = "TitleGlow", Size = Vector3.new(DW + 0.6, h + 2, w + 2), CFrame = CFrame.new(x, y, z), Color = W.Coral })
	local title = decor(add(model, {
		Name = "CardioTitle",
		Size = Vector3.new(DW + 1, h, w),
		CFrame = CFrame.new(x, y, z),
		Color = W.Cream,
	}))
	light(title, W.Coral, 40, 1.5)
	local icon = Assets.image("cardio/Cardio")
	for _, face in { Enum.NormalId.Left, Enum.NormalId.Right } do
		local gui = surface(title, face, 8)
		if icon then
			local img = Instance.new("ImageLabel")
			img.BackgroundTransparency = 1
			img.Image = icon
			img.ScaleType = Enum.ScaleType.Fit
			img.Size = UDim2.fromScale(0.16, 0.9)
			img.Position = UDim2.fromScale(0.02, 0.05)
			img.Parent = gui
		end
		outline(
			text(gui, { Text = "CARDIO", TextColor3 = W.Coral, Size = UDim2.fromScale(0.62, 0.7), Position = UDim2.fromScale(0.2, 0.04) }),
			W.Ink,
			6
		)
		text(gui, {
			Text = "STEP ON KEYS = +SPEED",
			Font = theme.Fonts.UI,
			Size = UDim2.fromScale(0.6, 0.2),
			Position = UDim2.fromScale(0.21, 0.76),
		})
	end
end

-- Lobby room ----------------------------------------------------------------------------------

local WARM = Color3.fromRGB(255, 196, 140)

-- An orange Neon beam from a to b (square section) into parent.
local function beamPart(parent: Instance, a: Vector3, b: Vector3, thick: number, colour: Color3)
	local len = (b - a).Magnitude
	local mid = (a + b) / 2
	local d = b - a
	local vertical = math.abs(d.X) < 1e-3 and math.abs(d.Z) < 1e-3
	glow(parent, {
		Name = "Truss",
		Size = if vertical then Vector3.new(thick, len + thick, thick) else Vector3.new(thick, thick, len + thick),
		CFrame = if vertical then CFrame.new(mid) else CFrame.lookAt(mid, b),
		Color = colour,
	})
end

-- X-truss frame on a lobby wall face: `at(u, y)` maps along-wall u and height y to world;
-- `skip(u, y)` drops beams whose midpoint is hidden (behind the title board).
local function lobbyFrame(
	parent: Instance,
	u0: number,
	u1: number,
	y0: number,
	y1: number,
	at: (number, number) -> Vector3,
	skip: (Vector3) -> boolean
)
	local thick = Layout.TRUSS.thick
	local colour = c3(themeOf(0).truss)
	local bays = math.max(1, math.floor((u1 - u0) / 15 + 0.5))
	local bw = (u1 - u0) / bays
	local function put(a: Vector3, b: Vector3)
		if not skip((a + b) / 2) then
			beamPart(parent, a, b, thick, colour)
		end
	end
	put(at(u0, y0), at(u1, y0))
	put(at(u0, y1), at(u1, y1))
	for i = 0, bays do
		put(at(u0 + i * bw, y0), at(u0 + i * bw, y1))
	end
	for i = 0, bays - 1 do
		local ua, ub = u0 + i * bw, u0 + (i + 1) * bw
		put(at(ua, y0), at(ub, y1))
		put(at(ua, y1), at(ub, y0))
	end
end

-- The Warm-Up lobby as a full room: orange X trusses on its three walls, roof joists at wall
-- height, candy clusters on the side walls and in the back corners, a giant CARDIO title on
-- the back (west) wall and a few warm lamps. Decor only.
local function lobbyRoom(model: Instance, zone: Layout.Zone)
	local look = themeOf(0)
	local decorFolder = folderIn(model, "LobbyDecor")
	local thick = Layout.TRUSS.thick
	local top = TOP + Layout.ZONE_WALL_HEIGHT - thick / 2
	local y0 = zone.top + 2
	local x0, x1, z0, z1 = zone.x0, zone.x1, zone.z0, zone.z1
	-- The back-wall title board (west wall, facing the room).
	local titleY, titleW, titleH = TOP + 19, 64, 16
	local function behindTitle(p: Vector3): boolean
		return p.X < x0 + 3 and math.abs(p.Y - titleY) < titleH / 2 + 1 and math.abs(p.Z - O.z) < titleW / 2 + 1
	end
	local function none(_: Vector3): boolean
		return false
	end
	lobbyFrame(decorFolder, x0, x1, y0, top, function(u, y)
		return Vector3.new(u, y, z0 + thick / 2)
	end, none)
	lobbyFrame(decorFolder, x0, x1, y0, top, function(u, y)
		return Vector3.new(u, y, z1 - thick / 2)
	end, none)
	lobbyFrame(decorFolder, z0, z1, y0, top, function(u, y)
		return Vector3.new(x0 + thick / 2, y, u)
	end, behindTitle)
	-- Roof joists across the room at wall height (wall to wall).
	local colour = c3(look.truss)
	for _, f in { 0.25, 0.5, 0.75 } do
		local x = x0 + (x1 - x0) * f
		beamPart(decorFolder, Vector3.new(x, top, z0), Vector3.new(x, top, z1), thick, colour)
	end
	beamPart(decorFolder, Vector3.new(x0, top, O.z), Vector3.new(x1, top, O.z), thick, colour)
	cardioTitle(decorFolder, x0 - Layout.WALL.thick / 2, titleY, O.z)

	-- Candy clusters: three on each side wall, a big pair in each back corner.
	local kinds = look.props
	local rand = rng(4242)
	local function pick(): string
		return kinds[math.floor(rand() * #kinds) + 1]
	end
	for _, north in { false, true } do
		local z = if north then z1 else z0
		local normal = { x = 0, y = 0, z = if north then -1 else 1 }
		for g = 0, 2 do
			local ax = x0 + (g + 0.5) * (x1 - x0) / 3
			local ay = TOP + 15 + rand() * 6
			for c = 1, 3 do
				local scale = if c == 1 then 9 + rand() * 3 else 5 + rand() * 2
				local dx = if c == 1 then 0 else (c - 2.5) * 2 * (scale / 2 + 5)
				prop(
					decorFolder,
					{
						kind = pick(),
						x = ax + dx,
						y = math.clamp(ay + (if c == 1 then 0 else (rand() - 0.5) * 8), TOP + 6, top - scale / 2),
						z = z,
						yaw = rand() * 6.28,
						scale = scale,
						stage = 0,
						wall = true,
						normal = normal,
						float = false,
					} :: any
				)
			end
		end
		for c = 1, 2 do
			local scale = if c == 1 then 8 else 5
			prop(
				decorFolder,
				{
					kind = pick(),
					x = x0 + 1 + scale / 2 + (c - 1) * 7,
					y = zone.top,
					z = if north then z1 - scale / 2 - 1 else z0 + scale / 2 + 1,
					yaw = rand() * 6.28,
					scale = scale,
					stage = 0,
					wall = false,
					normal = nil,
					float = false,
				} :: any
			)
		end
	end

	-- Warm lamps under the roof joists.
	for i, f in { 0.25, 0.75 } do
		for _, s in { -1, 1 } do
			local lamp = glow(decorFolder, {
				Name = "Lamp",
				Shape = BALL,
				Size = Vector3.new(2.4, 2.4, 2.4),
				CFrame = CFrame.new(x0 + (x1 - x0) * f, top - 2, O.z + s * 18),
				Color = WARM,
			})
			light(lamp, WARM, 42, if i == 1 then 1.3 else 1.1)
		end
	end
end

-- The stage banner through bridge room n's west wall, above its doorway (both faces).
local function stageSign(parent: Instance, sign: Layout.Sign, room: Layout.Room)
	local accent = stageColour(sign.stage)
	local model = folderIn(parent, "StageSign" .. sign.stage, "Model")
	model:SetAttribute("Stage", sign.stage)
	local w, h = 40, 15
	local x = room.x0 + DW / 2
	local z = math.clamp(sign.z, room.z0 + w / 2 + 2, room.z1 - w / 2 - 2)
	glow(model, { Name = "SignGlow", Size = Vector3.new(DW + 0.6, h + 1.6, w + 1.6), CFrame = CFrame.new(x, sign.y, z), Color = accent })
	local board = decor(add(model, {
		Name = "StageSign",
		Size = Vector3.new(DW + 1, h, w),
		CFrame = CFrame.new(x, sign.y, z),
		Color = W.Cream,
	}))
	light(board, accent, 30, 1.2)
	local foot = if sign.need > 0 then "NEED " .. Format.commas(sign.need) .. " SPEED" else "NO SPEED NEEDED"
	for _, face in { Enum.NormalId.Left, Enum.NormalId.Right } do
		stageCard(board, face, accent, "STAGE " .. sign.stage, string.upper(sign.name), foot)
	end
	if sign.stage == 1 then
		-- The lobby's exit wall: the giant CARDIO title above the first banner.
		cardioTitle(model, x, sign.y + h / 2 + 10, z)
	end
end

local function finish(parent: Instance)
	local f = LAYOUT.finish
	local podium = folderIn(parent, "FinishPodium", "Model")
	local tiers = { { 14, W.Teal }, { 10, W.Coral }, { 6, W.Sunny } }
	for i, tier in tiers do
		disc(podium, "PodiumTier", Vector3.new(f.x, f.y + (i - 0.5) * 1.5, f.z), tier[1] :: number, 1.5, tier[2] :: Color3)
	end
	local star = glow(podium, {
		Name = "PodiumStar",
		Shape = BALL,
		Size = Vector3.new(3, 3, 3),
		CFrame = CFrame.new(f.x, f.y + 4.5 + 6, f.z),
		Color = W.Sunny,
	})
	light(star, W.Sunny, 24, 2)
	-- FINISH! board on the cap wall's inner face.
	for _, w in LAYOUT.walls do
		if w.side == "east" and w.part == "full" then
			local x = w.x - w.sx / 2
			local y = TOP + 22
			glow(parent, { Name = "FinishGlow", Size = Vector3.new(0.6, 16, 52), CFrame = CFrame.new(x - 0.3, y, O.z), Color = W.Coral })
			local board = decor(add(parent, {
				Name = "FinishSign",
				Size = Vector3.new(1, 14, 50),
				CFrame = CFrame.new(x - 0.5, y, O.z),
				Color = W.Cream,
			}))
			local gui = surface(board, Enum.NormalId.Left, 12)
			outline(
				text(
					gui,
					{ Text = "FINISH!", TextColor3 = W.Coral, Size = UDim2.fromScale(0.9, 0.62), Position = UDim2.fromScale(0.05, 0.06) }
				),
				W.Ink,
				6
			)
			text(gui, { Text = "KEYBOARD CHAMPION", Size = UDim2.fromScale(0.8, 0.24), Position = UDim2.fromScale(0.1, 0.7) })
		end
	end
end

-- Build ------------------------------------------------------------------------------------

-- One invisible anchored collision slab per walkable key surface (x0..x1, z0..z1, key tops
-- at `top`): its top is PRESS below the key tops, so feet rest where pressed keys
-- bottom out. Blink / mover platforms pass their blink / slide attributes (Fx.Modes toggles
-- the slab's collision / slides it with its keys).
local SLAB_DEPTH = 1
local function collider(parent: Instance, x0: number, x1: number, z0: number, z1: number, top: number, platform: Layout.Platform?): BasePart
	local y = top - PRESS
	local slab = add(parent, {
		Name = "KeySlab",
		Size = Vector3.new(x1 - x0, SLAB_DEPTH, z1 - z0),
		CFrame = CFrame.new((x0 + x1) / 2, y - SLAB_DEPTH / 2, (z0 + z1) / 2),
		Transparency = 1,
		CastShadow = false,
		CanCollide = true,
		CanQuery = true,
		CanTouch = false,
	})
	if platform and platform.kind == "blink" then
		slab:SetAttribute("BlinkOn", platform.blinkOn)
		slab:SetAttribute("BlinkPeriod", platform.blinkPeriod)
		slab:SetAttribute("BlinkPhase", platform.phase or 0)
		slab:AddTag("BlinkPad")
	elseif platform and platform.kind == "mover" then
		local period = platform.period :: number
		slab:SetAttribute("Mover", "slide")
		slab:SetAttribute("MoveAxis", Vector3.new(0, 0, 1))
		slab:SetAttribute("MoveDistance", platform.travel)
		slab:SetAttribute("MovePeriod", period)
		slab:SetAttribute("MovePhase", 2 * math.pi * (platform.phase or 0) / period)
		slab:AddTag("ModeMover")
	end
	return slab
end

function CardioTrack.build(): Built
	lightCount = 0
	local folder = Instance.new("Folder")
	folder.Name = "CardioTrack"
	folder:SetAttribute("Mode", "cardio")
	local keysFolder = folderIn(folder, "Keys")

	local stageFolders: { [number]: Instance } = {}
	for n = 0, Rules.STAGE_COUNT do
		stageFolders[n] = folderIn(keysFolder, "Stage" .. n)
	end

	local keys: { BasePart } = {}
	for i, key in LAYOUT.keys do
		keys[i] = buildKey(stageFolders[key.stage], key, i)
	end
	folder:SetAttribute("PressDepth", PRESS)
	folder:SetAttribute("KeyPitch", KEY.size)
	local slabs = folderIn(folder, "Colliders")
	for _, p in LAYOUT.platforms do
		collider(slabs, p.x0, p.x1, p.z0, p.z1, p.top, p)
	end
	for _, zone in LAYOUT.zones do
		collider(slabs, zone.x0, zone.x1, zone.z0, zone.z1, zone.top, nil)
	end
	for _, b in LAYOUT.blocks do
		collider(slabs, b.x0, b.x1, b.z0, b.z1, b.top, nil)
	end

	-- Bridge rooms: hazard floor, truss and prop folders.
	local rooms: { [number]: Model } = {}
	local hazards: { [number]: BasePart } = {}
	local trussFolders: { [number]: Instance } = {}
	local propFolders: { [number]: Instance } = {}
	local roomOf: { [number]: Layout.Room } = {}
	for _, room in LAYOUT.rooms do
		if room.kind == "bridge" then
			local model = folderIn(folder, "Room" .. room.stage, "Model") :: Model
			model:SetAttribute("Stage", room.stage)
			model:SetAttribute("Theme", room.theme)
			rooms[room.stage] = model
			roomOf[room.stage] = room
			hazards[room.stage] = hazard(model, room)
			trussFolders[room.stage] = folderIn(model, "Truss")
			propFolders[room.stage] = folderIn(model, "Props")
		end
	end
	local trussCount = buildTrusses(trussFolders)
	folder:SetAttribute("TrussParts", trussCount)
	for _, p in LAYOUT.props do
		local parent = propFolders[p.stage]
		if parent then
			prop(parent, p)
		end
	end

	-- Blinking platforms get a Neon rail under their keys (the keys fade; the rail stays).
	for _, p in LAYOUT.platforms do
		if p.kind == "blink" then
			glow(rooms[p.stage], {
				Name = "BlinkRail",
				Size = Vector3.new(p.x1 - p.x0 + 0.6, 0.4, p.z1 - p.z0 + 0.6),
				CFrame = CFrame.new((p.x0 + p.x1) / 2, p.top - KEY.height - 0.6, (p.z0 + p.z1) / 2),
				Color = stageColour(p.stage):Lerp(W.White, 0.3),
			})
		end
	end

	local zones: { [number]: Model } = {}
	local decks: { [number]: BasePart } = {}
	local treadmills: { Model } = {}
	local upgrade: BasePart? = nil
	for _, zone in LAYOUT.zones do
		local model = folderIn(folder, "Zone" .. zone.stage, "Model") :: Model
		model:SetAttribute("Stage", zone.stage)
		zones[zone.stage] = model
		for i, tm in zone.treadmills do
			table.insert(treadmills, treadmill(model, zone.stage, i, tm))
		end
		if zone.upgradePad then
			upgrade = upgradePad(model, zone)
		end
		if zone.stage == 0 then
			lobbyRoom(model, zone)
		end
	end

	-- Chocolate slabs: decks into their zone models, block pillars and platform bases into
	-- their bridge rooms.
	for _, b in LAYOUT.bases do
		if b.block then
			blockPillar(rooms[b.stage], b)
		elseif b.group == 0 then
			decks[b.stage] = base(zones[b.stage], b, "Deck")
		else
			base(rooms[b.stage], b, "Base")
		end
	end

	buildWalls(folderIn(folder, "Walls"))
	local doorFolder = folderIn(folder, "Doors")
	local doors: { [number]: BasePart } = {}
	for i, d in LAYOUT.doors do
		local slab = door(doorFolder, d, i)
		if slab then
			doors[i] = slab
		end
	end
	local signs = folderIn(folder, "Signs")
	for _, sign in LAYOUT.signs do
		local room = roomOf[sign.stage]
		if room then
			stageSign(signs, sign, room)
		end
	end
	finish(folder)

	folder.Parent = Workspace
	return {
		folder = folder,
		keys = keys,
		zones = zones,
		decks = decks,
		upgradePad = upgrade :: BasePart,
		treadmills = treadmills,
		rooms = rooms,
		hazards = hazards,
		doors = doors,
	}
end

return CardioTrack
