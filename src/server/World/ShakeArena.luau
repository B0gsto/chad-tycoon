--!strict
--[[
	ShakeArena: the SHAKE CATCH arena out at sea (teleport-only; Modes.Shake brings players here).
	Numbers live in Modes.ShakeRules.ARENA; the shell (deck, spawn pad, exit arch) comes from
	World.Arena. Dressed as a sunny beach court:
	  * a sand deck with white court lines round the catch area (where items land);
	  * the Smoothie Bar on its own deck past the far (-Z) edge, facing the spawn: a pink
	    counter with blenders, a striped awning, a "SMOOTHIE BAR" sign and a giant shake
	    cup on the roof, surfboards leaning on its sides;
	  * striped sun awnings on posts along both side edges (outside the catch area), with
	    bunting between them; palms in the four corners (the PalmTree mesh, or a part-built
	    one when the mesh is missing).
	Nothing solid stands inside the catch area; the falling items are client-side (Fx.Shake).

	build() -> Built: everything World.Arena.Base has ({ folder, floor, spawn, exit,
	exitRadius, center, top }) plus
	catchArea  floor rectangle (world x0, x1, z0, z1) where shakes and junk food may land
	dropY      height falling items spawn at
	items      empty Folder "Items" for the falling props (Modes.Shake / Fx.Shake fill it)
]]

local Arena = require(script.Parent.Arena)
local Common = require(script.Parent.Common)
local Props = require(script.Parent.Props)
local ShakeRules = require(script.Parent.Parent.Modes.ShakeRules)

local W = Common.theme.World
local make = Common.make
local UPRIGHT = Common.UPRIGHT
local CYLINDER = Enum.PartType.Cylinder
local BALL = Enum.PartType.Ball

local ShakeArena = {}

-- Studs between the deck's edge and the catch area (the awnings and palms stand in it).
local INSET = 6
local PALM_HEIGHT = 15

export type Built = Arena.Base & {
	catchArea: { x0: number, x1: number, z0: number, z1: number },
	dropY: number,
	items: Folder,
}

-- A plain anchored part in `parent` (no collisions unless props say CanCollide = true).
local function piece(parent: Instance, name: string, size: Vector3, cf: CFrame, color: Color3, props: { [string]: any }?): BasePart
	local p: { [string]: any } = { Name = name, Size = size, CFrame = cf, Color = color, Parent = parent, CanCollide = false }
	local className = "Part"
	for key, value in (props or {}) :: { [string]: any } do
		if key == "ClassName" then
			className = value
		else
			p[key] = value
		end
	end
	return make(className, p)
end

-- A big SurfaceGui word on `part`'s front face.
local function word(part: BasePart, text: string, color: Color3)
	local gui = Instance.new("SurfaceGui")
	gui.Face = Enum.NormalId.Front
	gui.PixelsPerStud = 30
	gui.Parent = part
	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromScale(1, 1)
	label.Text = text
	label.TextScaled = true
	label.Font = Common.theme.Fonts.Display
	label.TextColor3 = color
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 4
	stroke.Color = W.Ink
	stroke.Parent = label
	label.Parent = gui
end

-- A part-built palm (when the PalmTree mesh is missing): a leaning ringed trunk and fronds.
local function partPalm(parent: Instance, base: Vector3)
	local lean = CFrame.Angles(0, 0, math.rad(6))
	for i = 0, 4 do
		local y = 1.5 + i * 2.8
		piece(
			parent,
			"PalmTrunk",
			Vector3.new(3, 1.6 - i * 0.12, 1.6 - i * 0.12),
			CFrame.new(base + Vector3.new(i * 0.3, y, 0)) * lean * UPRIGHT,
			if i % 2 == 0 then W.Wood else W.WoodDark,
			{ Shape = CYLINDER, CanCollide = i == 0 }
		)
	end
	local crown = base + Vector3.new(1.5, PALM_HEIGHT - 1, 0)
	for k = 0, 5 do
		local yaw = math.rad(k * 60)
		piece(
			parent,
			"PalmFrond",
			Vector3.new(1.6, 0.4, 7),
			CFrame.new(crown) * CFrame.Angles(0, yaw, 0) * CFrame.Angles(math.rad(-22), 0, 0) * CFrame.new(0, 0, -3.2),
			if k % 2 == 0 then W.Grass else W.GrassDark
		)
	end
	piece(parent, "PalmCoconuts", Vector3.new(1.6, 1.6, 1.6), CFrame.new(crown - Vector3.new(0, 0.9, 0)), W.WoodDark, { Shape = BALL })
end

local function palm(parent: Instance, base: Vector3, facing: number)
	local cf = CFrame.new(base) * CFrame.Angles(0, facing, 0)
	local size = Props.size("PalmTree")
	local mesh = size and Props.mesh("PalmTree", cf, PALM_HEIGHT / size.Y, parent)
	if not mesh then
		partPalm(parent, base)
	end
end

-- A sun awning on two posts along an edge: red-and-white style stripes, sloping outward.
local function awning(parent: Instance, center: Vector3, length: number, outward: number)
	local postH = 9
	for _, s in { -1, 1 } do
		piece(
			parent,
			"AwningPost",
			Vector3.new(postH, 0.6, 0.6),
			CFrame.new(center + Vector3.new(outward * 2.2, postH / 2, s * (length / 2 - 0.5))) * UPRIGHT,
			W.White,
			{ Shape = CYLINDER, CanCollide = true }
		)
	end
	local stripes = 8
	local w = length / stripes
	for i = 0, stripes - 1 do
		local z = -length / 2 + w * (i + 0.5)
		piece(
			parent,
			"AwningStripe",
			Vector3.new(5, 0.3, w),
			CFrame.new(center + Vector3.new(0, postH + 0.4, z)) * CFrame.Angles(0, 0, math.rad(-outward * 14)),
			if i % 2 == 0 then W.Pink else W.White
		)
		-- The scalloped valance on the inner edge.
		piece(
			parent,
			"AwningFlap",
			Vector3.new(0.25, 0.9, w * 0.92),
			CFrame.new(center + Vector3.new(-outward * 2.4, postH + 0.4, z)),
			if i % 2 == 0 then W.Pink else W.White
		)
	end
end

-- The Smoothie Bar backdrop on its own deck past the -Z edge, facing +Z (the spawn).
local function smoothieBar(parent: Instance, a: Arena.Spec, top: number)
	local bz = a.z - a.sizeZ / 2 - 6
	local deck = Vector3.new(a.x, top, bz)
	piece(parent, "BarDeck", Vector3.new(44, 2, 12), CFrame.new(deck - Vector3.new(0, 1, 0)), W.Wood, { CanCollide = true })
	piece(parent, "BarDeckRim", Vector3.new(46, 1.2, 13), CFrame.new(deck - Vector3.new(0, 1.5, 0)), W.White)
	-- Back wall and side pillars.
	piece(parent, "BarWall", Vector3.new(30, 14, 1), CFrame.new(deck + Vector3.new(0, 7, -4)), W.Butter, { CanCollide = true })
	for _, s in { -1, 1 } do
		piece(parent, "BarPillar", Vector3.new(1.4, 14, 1.4), CFrame.new(deck + Vector3.new(s * 15, 7, 3)), W.White, { CanCollide = true })
	end
	-- Counter: pink front, white top, mint kick strip.
	piece(parent, "BarCounter", Vector3.new(28, 4, 2.4), CFrame.new(deck + Vector3.new(0, 2, 2.4)), W.Pink, { CanCollide = true })
	piece(parent, "BarCounterTop", Vector3.new(29, 0.5, 3), CFrame.new(deck + Vector3.new(0, 4.25, 2.4)), W.White)
	piece(
		parent,
		"BarKick",
		Vector3.new(28, 0.6, 0.2),
		CFrame.new(deck + Vector3.new(0, 0.5, 3.65)),
		W.Mint,
		{ Material = Enum.Material.Neon }
	)
	-- Blenders on the counter: a base, a glass jug and a coloured smoothie inside.
	local fills = { W.Pink, W.Mint, W.Orange, W.Grape }
	for i, fill in fills do
		local x = -10.5 + (i - 1) * 7
		local at = deck + Vector3.new(x, 4.5, 2.2)
		piece(parent, "BlenderBase", Vector3.new(1.6, 0.9, 1.6), CFrame.new(at + Vector3.new(0, 0.45, 0)), W.Steel)
		piece(
			parent,
			"BlenderJug",
			Vector3.new(2.4, 1.4, 1.4),
			CFrame.new(at + Vector3.new(0, 2.1, 0)) * UPRIGHT,
			W.White,
			{ Shape = CYLINDER, Transparency = 0.45, Material = Enum.Material.Glass }
		)
		piece(
			parent,
			"BlenderFill",
			Vector3.new(1.5, 1.2, 1.2),
			CFrame.new(at + Vector3.new(0, 1.7, 0)) * UPRIGHT,
			fill,
			{ Shape = CYLINDER }
		)
	end
	-- Striped awning over the counter.
	for i = 0, 9 do
		local x = -14.4 + i * 3.2
		piece(
			parent,
			"BarAwning",
			Vector3.new(3.2, 0.3, 6),
			CFrame.new(deck + Vector3.new(x, 11.6, 3.2)) * CFrame.Angles(math.rad(18), 0, 0),
			if i % 2 == 0 then W.Coral else W.White
		)
		piece(
			parent,
			"BarAwningFlap",
			Vector3.new(3.2, 1, 0.25),
			CFrame.new(deck + Vector3.new(x, 10.2, 6.1)),
			if i % 2 == 0 then W.Coral else W.White
		)
	end
	-- The sign on the roof line.
	local sign = piece(parent, "BarSign", Vector3.new(22, 4, 0.6), CFrame.new(deck + Vector3.new(0, 16, -3.6)), W.Pink)
	piece(parent, "BarSignBack", Vector3.new(23, 5, 0.4), CFrame.new(deck + Vector3.new(0, 16, -4)), W.White)
	word(sign, "SMOOTHIE BAR", W.White)
	-- A giant protein shake on the roof: cup, lid, straw and a cherry.
	local cup = deck + Vector3.new(14, 14, -3)
	piece(parent, "GiantCup", Vector3.new(7, 5, 5), CFrame.new(cup + Vector3.new(0, 3.5, 0)) * UPRIGHT, W.Pink, { Shape = CYLINDER })
	piece(
		parent,
		"GiantCupBand",
		Vector3.new(1.4, 5.3, 5.3),
		CFrame.new(cup + Vector3.new(0, 3.2, 0)) * UPRIGHT,
		W.White,
		{ Shape = CYLINDER }
	)
	piece(parent, "GiantLid", Vector3.new(1, 5.8, 5.8), CFrame.new(cup + Vector3.new(0, 7.3, 0)) * UPRIGHT, W.White, { Shape = CYLINDER })
	piece(parent, "GiantDome", Vector3.new(4.6, 2.6, 4.6), CFrame.new(cup + Vector3.new(0, 7.9, 0)), W.Cream, { Shape = BALL })
	piece(
		parent,
		"GiantStraw",
		Vector3.new(0.8, 6, 0.8),
		CFrame.new(cup + Vector3.new(0.6, 11, 0)) * CFrame.Angles(0, 0, math.rad(-12)),
		W.Mint
	)
	piece(parent, "GiantCherry", Vector3.new(1.4, 1.4, 1.4), CFrame.new(cup + Vector3.new(-1, 9.3, 0.6)), W.Coral, { Shape = BALL })
	-- Surfboards leaning on the deck's ends.
	local boards: { { x: number, color: Color3, tilt: number } } = {
		{ x = -19, color = W.Mint, tilt = 1 },
		{ x = 19, color = W.Sunny, tilt = -1 },
		{ x = -21, color = W.Blue, tilt = 1 },
	}
	for _, b in boards do
		local x, color, tilt = b.x, b.color, b.tilt
		local board = CFrame.new(deck + Vector3.new(x, 4.3, -1)) * CFrame.Angles(math.rad(-12), 0, math.rad(tilt * 8))
		piece(parent, "Surfboard", Vector3.new(2.6, 9, 0.4), board, color)
		piece(parent, "SurfboardStripe", Vector3.new(0.5, 9.05, 0.45), board, W.White)
	end
end

-- Bunting: little upside-down wedge flags sagging on a line along Z between two points.
local function bunting(parent: Instance, from: Vector3, to: Vector3, count: number)
	local colors = { W.Pink, W.Sunny, W.Mint, W.Blue, W.Coral }
	piece(parent, "BuntingLine", Vector3.new(0.08, 0.08, (to - from).Magnitude), CFrame.lookAt(from:Lerp(to, 0.5), to), W.White)
	for i = 1, count do
		local t = i / (count + 1)
		local p = from:Lerp(to, t) - Vector3.new(0, 0.55 + math.sin(t * math.pi) * 0.4, 0)
		piece(
			parent,
			"Bunting",
			Vector3.new(0.1, 1.1, 1),
			CFrame.new(p) * CFrame.Angles(0, 0, math.pi),
			colors[(i - 1) % #colors + 1],
			{ ClassName = "WedgePart" }
		)
	end
end

function ShakeArena.build(): Built
	local a = ShakeRules.ARENA
	local base = Arena.base("shake", "ShakeArena", a, { floor = "Sand", trim = "Pink" })
	local folder = base.folder
	local top = base.top
	local items = Instance.new("Folder")
	items.Name = "Items"
	items.Parent = folder
	local area = {
		x0 = a.x - a.sizeX / 2 + INSET,
		x1 = a.x + a.sizeX / 2 - INSET,
		z0 = a.z - a.sizeZ / 2 + INSET,
		z1 = a.z + a.sizeZ / 2 - INSET,
	}
	local decor = Instance.new("Model")
	decor.Name = "Decor"
	decor.Parent = folder

	-- Court lines round the catch area and a centre circle.
	local w, d = area.x1 - area.x0, area.z1 - area.z0
	local lineY = top + 0.03
	for _, s in { -1, 1 } do
		piece(decor, "CourtLine", Vector3.new(w + 0.6, 0.06, 0.6), CFrame.new(a.x, lineY, a.z + s * d / 2), W.White)
		piece(decor, "CourtLine", Vector3.new(0.6, 0.06, d + 0.6), CFrame.new(a.x + s * w / 2, lineY, a.z), W.White)
	end
	piece(decor, "CourtCircle", Vector3.new(0.06, 12, 12), CFrame.new(a.x, lineY, a.z) * UPRIGHT, W.SandDark, { Shape = CYLINDER })

	smoothieBar(decor, a, top)

	-- Side awnings with bunting and the corner palms.
	local length = 18
	for _, sx in { -1, 1 } do
		local x = a.x + sx * (a.sizeX / 2 - INSET / 2)
		for _, sz in { -1, 1 } do
			awning(decor, Vector3.new(x, top, a.z + sz * 12), length, sx)
		end
		bunting(decor, Vector3.new(x - sx * 0.5, top + 9.6, a.z - 3), Vector3.new(x - sx * 0.5, top + 9.6, a.z + 3), 4)
		palm(decor, Vector3.new(a.x + sx * (a.sizeX / 2 - 2.5), top, a.z - a.sizeZ / 2 + 2.5), math.rad(45 * sx))
	end
	-- Only the far corners get palms on the deck: the near +X corner holds the exit arch.
	palm(decor, Vector3.new(a.x - a.sizeX / 2 + 2.5, top, a.z + a.sizeZ / 2 - 2.5), math.rad(200))

	local built: any = base
	built.catchArea = area
	built.dropY = top + 40
	built.items = items
	return built :: Built
end

return ShakeArena
