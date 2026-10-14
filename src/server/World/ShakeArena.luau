--!strict
--[[
	ShakeArena: the SHAKE CATCH arena, its own beach spot far out at sea (teleport-only;
	Modes.Shake brings players here). Numbers live in Modes.ShakeRules (ARENA: the court's
	centre and the size of everything walkable, EXIT: the exit pad); the court's shell (deck,
	play spot pad, exit arch) comes from World.Arena, built for the 64 x 64 COURT.
	Players land in the lobby (docs/minigames.md "Lobby first, then the game"), a plank deck past
	the court's +Z edge:
	  * the START gate at the court entrance: a glowing "StartPad" under candy-striped posts
	    and the "SHAKE CATCH" crest, rope fences either side;
	  * the HOW TO PLAY board (three illustrated steps, hearts and the pass mark) and the
	    YOUR BEST board (SurfaceGui "BestBoard": labels Best, Clears and Reward the client
	    fills), both angled at the lobby spawn;
	  * the practice mat under a low cloud (Fx drops slow demo items on it), the Tiki
	    Shakes hut, palms, and the EXIT arch (moved here from the court's corner).
	Round it all: a sand island under the decks (wet-sand rim, foam ring, umbrellas, a jetty
	with a ladder, a giant shake, a beach ball and a flamingo float on the back beach), its own
	sea (World.Hub's sea line), a light lagoon, sandbars, a candy-striped lighthouse, a palm
	cluster islet, a hot-air balloon, palm islands on the horizon and clouds. The court itself is dressed as a sunny beach court:
	  * a sand deck with a coloured court over the catch area (where items land): a soft
	    two-teal checker in a deep-teal edge band, a wide hot-pink border, white court lines, a
	    big target in the middle and a catch ring in each quadrant;
	  * the Shake Chute over the far margin (outside every drop column): a candy-striped
	    gantry carrying the "SHAKE CATCH!" title, a cloud bank, three giant blenders tipped
	    at the court and sample shakes and fruit;
	  * bleachers on their own deck past the +X edge: three tiers of cheering fan cut-outs
	    and a score / timer board;
	  * the Smoothie Bar on its own deck past the far (-Z) edge, facing the spawn: a pink
	    counter with blenders, a striped awning and a "SMOOTHIE BAR" sign, a giant shake cup
	    and surfboards at its ends, palms framing it (the PalmTree mesh, or a part-built one);
	  * striped sun awnings on four posts along both side edges (outside the catch area),
	    with bunting between them.
	Nothing solid stands inside the catch area; the falling items are client-side (Fx.Shake).

	build() -> Built: everything World.Arena.Base has ({ folder, floor, spawn, exit,
	exitRadius, center, top }; spawn is the play spot on the court, exit sits in the lobby) plus
	catchArea      floor rectangle (world x0, x1, z0, z1) where shakes and junk food may land
	dropY          height falling items spawn at
	items          empty Folder "Items" for the falling props (Modes.Shake / Fx.Shake fill it)
	lobbySpawn     feet position + facing where a player lands from the gate (looks at START)
	startPad       the "StartPad" part; feet within startRadius of it in phase lobby = Begin
	startRadius    studs
	board          the YOUR BEST SurfaceGui ("BestBoard"; TextLabels Best, Clears, Reward)
	practiceArea   floor rectangle (world x0, x1, z0, z1) of the practice mat's demo drops (also
	               an invisible "PracticeArea" part on the mat, attribute DropY, for Fx.Shake)
	practiceDropY  height the demo items spawn at (just under the mat's cloud)
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

-- The catch court's deck (studs, square, centred on ShakeRules.ARENA's x / z).
local COURT = 64
-- The lobby deck past the court's +Z edge: its depth, and in lobby-local studs (z from the
-- court's edge) the spawn, the START pad and the practice mat.
local LOBBY_DEPTH = 50
local LOBBY_SPAWN_Z = 40
local START_Z = 9
local START_RADIUS = 6
local PRACTICE = { x = -17, z = 37, half = 5.5 }
-- The practice mat's diameter.
local PRACTICE_MAT = 17
-- Demo items spawn this high over the practice mat (just under its cloud).
local PRACTICE_DROP = 12
-- World.Hub's sea line and ocean tile size.
local OCEAN_TOP = -1.2
local OCEAN_TILE = 2048
-- The sand island under the decks (studs from ARENA's centre): half its width, its -Z and +Z
-- edges and its corner radius.
local ISLAND = { halfX = 56, z0 = -62, z1 = 90, r = 14 }

-- Studs between the deck's edge and the catch area (the awnings stand in it, clear of every
-- drop column; the palms stand on the Smoothie Bar's deck past the far edge).
local INSET = 9
-- The side awnings' centre line (studs from the arena's centre along X).
local AWNING_X = 28.5
local PALM_HEIGHT = 15
-- The Shake Chute gantry's centre line (studs in from the deck's -Z edge: between the catch
-- area and the edge) and its beam's height above the floor.
local CHUTE_INSET = 4.5
local CHUTE_HEIGHT = 30

export type Built = Arena.Base & {
	catchArea: { x0: number, x1: number, z0: number, z1: number },
	dropY: number,
	items: Folder,
	lobbySpawn: CFrame,
	startPad: BasePart,
	startRadius: number,
	board: SurfaceGui,
	practiceArea: { x0: number, x1: number, z0: number, z1: number },
	practiceDropY: number,
}

type Lobby = {
	lobbySpawn: CFrame,
	startPad: BasePart,
	board: SurfaceGui,
	practiceArea: { x0: number, x1: number, z0: number, z1: number },
	practiceDropY: number,
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

-- A big SurfaceGui word on `part`'s `face` (default Back: +Z, toward the spawn).
local function word(part: BasePart, text: string, color: Color3, face: Enum.NormalId?)
	local gui = Instance.new("SurfaceGui")
	gui.Face = face or Enum.NormalId.Back
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 30
	gui.LightInfluence = 0
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

local function palm(parent: Instance, base: Vector3, facing: number, height: number?)
	local cf = CFrame.new(base) * CFrame.Angles(0, facing, 0)
	local size = Props.size("PalmTree")
	local mesh = size and Props.mesh("PalmTree", cf, (height or PALM_HEIGHT) / size.Y, parent)
	if not mesh then
		partPalm(parent, base)
	end
end

-- A sun awning on two posts along an edge: red-and-white style stripes, sloping outward.
local function awning(parent: Instance, center: Vector3, length: number, outward: number)
	local postH = 9
	-- Four posts (the canopy slopes down outward: the inner pair stands taller), each on a
	-- little pink foot.
	for _, s in { -1, 1 } do
		for _, side in { -1, 1 } do
			local h = postH + 0.4 - side * 2.1 * math.tan(math.rad(14))
			local foot = center + Vector3.new(outward * side * 2.1, 0, s * (length / 2 - 0.6))
			piece(
				parent,
				"AwningPost",
				Vector3.new(h, 0.5, 0.5),
				CFrame.new(foot + Vector3.new(0, h / 2, 0)) * UPRIGHT,
				W.White,
				{ Shape = CYLINDER, CanCollide = true }
			)
			piece(
				parent,
				"AwningFoot",
				Vector3.new(0.5, 1.3, 1.3),
				CFrame.new(foot + Vector3.new(0, 0.25, 0)) * UPRIGHT,
				W.Pink,
				{ Shape = CYLINDER }
			)
		end
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
	piece(parent, "BarDeck", Vector3.new(64, 2, 12), CFrame.new(deck - Vector3.new(0, 1, 0)), W.Wood, { CanCollide = true })
	piece(parent, "BarDeckRim", Vector3.new(66, 1.2, 13), CFrame.new(deck - Vector3.new(0, 1.5, 0)), W.White)
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
	local sign = piece(parent, "BarSign", Vector3.new(30, 6, 0.6), CFrame.new(deck + Vector3.new(0, 17, -3.6)), W.HotPink)
	piece(parent, "BarSignBack", Vector3.new(31.5, 7.4, 0.4), CFrame.new(deck + Vector3.new(0, 17, -4)), W.White)
	word(sign, "SMOOTHIE BAR", W.White)
	-- A giant protein shake standing on the deck's left end: cup, lid, straw and a cherry.
	local cup = deck + Vector3.new(-22, 0, -1)
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
		{ x = 18, color = W.Mint, tilt = -1 },
		{ x = 20.5, color = W.Sunny, tilt = -1 },
		{ x = 23, color = W.Blue, tilt = -1 },
	}
	for _, b in boards do
		local x, color, tilt = b.x, b.color, b.tilt
		local board = CFrame.new(deck + Vector3.new(x, 4.3, -1)) * CFrame.Angles(math.rad(-12), 0, math.rad(tilt * 8))
		piece(parent, "Surfboard", Vector3.new(2.6, 9, 0.4), board, color)
		piece(parent, "SurfboardStripe", Vector3.new(0.5, 9.05, 0.45), board, W.White)
	end
	-- Palms framing both ends of the bar (outside the court: no fronds over a drop column).
	for _, sx in { -1, 1 } do
		palm(parent, deck + Vector3.new(sx * 29.5, 0, -1.5), math.rad(if sx < 0 then 30 else 210))
	end
end

-- Bunting: little upside-down wedge flags sagging on a line between two points (the flags
-- turn with the line).
local function bunting(parent: Instance, from: Vector3, to: Vector3, count: number)
	local colors = { W.Pink, W.Sunny, W.Mint, W.Blue, W.Coral }
	local yaw = math.atan2(to.X - from.X, to.Z - from.Z)
	piece(parent, "BuntingLine", Vector3.new(0.08, 0.08, (to - from).Magnitude), CFrame.lookAt(from:Lerp(to, 0.5), to), W.White)
	for i = 1, count do
		local t = i / (count + 1)
		local p = from:Lerp(to, t) - Vector3.new(0, 0.55 + math.sin(t * math.pi) * 0.4, 0)
		piece(
			parent,
			"Bunting",
			Vector3.new(0.1, 1.1, 1),
			CFrame.new(p) * CFrame.Angles(0, yaw, 0) * CFrame.Angles(0, 0, math.pi),
			colors[(i - 1) % #colors + 1],
			{ ClassName = "WedgePart" }
		)
	end
end

-- The Shake Chute: a candy-striped gantry over the far margin (between the catch area's -Z
-- edge and the deck's, so it stands outside every drop column) whose beam is the "SHAKE
-- CATCH!" title, with a cloud bank and three giant blenders that "fire" the shakes onto the court.
local function chute(parent: Instance, a: Arena.Spec, top: number)
	local gz = a.z - a.sizeZ / 2 + CHUTE_INSET
	local beamY = top + CHUTE_HEIGHT
	local stripes = { W.HotPink, W.White }
	for _, sx in { -1, 1 } do
		local base = Vector3.new(a.x + sx * 29, top, gz)
		piece(parent, "ChuteFoot", Vector3.new(4, 1, 4), CFrame.new(base + Vector3.new(0, 0.5, 0)), W.Teal, { CanCollide = true })
		for i = 0, 7 do
			piece(
				parent,
				"ChutePillar",
				Vector3.new(4.4, 2.4, 2.4),
				CFrame.new(base + Vector3.new(0, 1 + 2.2 + i * 4.4, 0)) * UPRIGHT,
				stripes[i % 2 + 1],
				{ Shape = CYLINDER, CanCollide = i == 0 }
			)
		end
		piece(parent, "ChutePillarTop", Vector3.new(3, 3, 3), CFrame.new(base + Vector3.new(0, 37.5, 0)), W.Sunny, { Shape = BALL })
	end
	-- The beam is the title board: a white frame, a hot-pink face with the words facing the
	-- spawn and a neon trim under it.
	piece(parent, "ChuteBeam", Vector3.new(62, 8, 2), CFrame.new(a.x, beamY, gz - 0.4), W.White)
	local title = piece(parent, "TitleBoard", Vector3.new(58, 6.6, 0.6), CFrame.new(a.x, beamY, gz + 0.8), W.HotPink)
	word(title, "SHAKE CATCH!", W.Sunny)
	piece(
		parent,
		"TitleTrim",
		Vector3.new(62, 0.6, 2.4),
		CFrame.new(a.x, beamY - 4.2, gz - 0.4),
		W.Sunny,
		{ Material = Enum.Material.Neon }
	)
	local deckY = beamY + 4
	piece(parent, "ChuteShelf", Vector3.new(62, 0.6, 3.6), CFrame.new(a.x, deckY - 0.3, gz - 1), W.Teal)
	-- A cloud bank along the beam (kept behind its front face).
	local puffs = { { -27, 4.6 }, { -21, 6 }, { -8, 5 }, { 8, 5.4 }, { 21, 6.2 }, { 27, 4.4 } }
	for _, puff in puffs do
		piece(
			parent,
			"ChuteCloud",
			Vector3.new(puff[2], puff[2] * 0.8, puff[2] * 0.75),
			CFrame.new(a.x + puff[1], deckY + 1.2, gz - 1),
			W.White,
			{ Shape = BALL }
		)
	end
	-- Three giant blenders tipped toward the court, a smoothie inside each.
	local fills = { W.Grape, W.HotPink, W.Orange }
	for i, fill in fills do
		local at = CFrame.new(a.x + (i - 2) * 14.5, deckY, gz - 1) * CFrame.Angles(math.rad(10), 0, 0)
		piece(parent, "CannonBase", Vector3.new(4, 2, 4), at * CFrame.new(0, 1, 0), W.Steel)
		piece(
			parent,
			"CannonJug",
			Vector3.new(5, 4.2, 4.2),
			at * CFrame.new(0, 4.5, 0) * UPRIGHT,
			W.White,
			{ Shape = CYLINDER, Transparency = 0.4, Material = Enum.Material.Glass }
		)
		piece(parent, "CannonFill", Vector3.new(3.8, 3.7, 3.7), at * CFrame.new(0, 4, 0) * UPRIGHT, fill, { Shape = CYLINDER })
		piece(parent, "CannonLid", Vector3.new(0.8, 4.6, 4.6), at * CFrame.new(0, 7.3, 0) * UPRIGHT, W.Teal, { Shape = CYLINDER })
		piece(parent, "CannonKnob", Vector3.new(1.4, 1.4, 1.4), at * CFrame.new(0, 8, 0), W.Sunny, { Shape = BALL })
	end
	-- Sample shakes and fruit between the blenders.
	for _, sx in { -1, 1 } do
		local cup = Vector3.new(a.x + sx * 7.2, deckY, gz - 1)
		piece(
			parent,
			"SampleCup",
			Vector3.new(3.2, 2.4, 2.4),
			CFrame.new(cup + Vector3.new(0, 1.6, 0)) * UPRIGHT,
			if sx < 0 then W.Mint else W.Pink,
			{ Shape = CYLINDER }
		)
		piece(parent, "SampleCream", Vector3.new(2.4, 1.6, 2.4), CFrame.new(cup + Vector3.new(0, 3.3, 0)), W.Cream, { Shape = BALL })
		piece(
			parent,
			"SampleStraw",
			Vector3.new(0.4, 3, 0.4),
			CFrame.new(cup + Vector3.new(0.4, 4.2, 0)) * CFrame.Angles(0, 0, math.rad(-15)),
			W.HotPink
		)
		piece(parent, "SampleCherry", Vector3.new(0.9, 0.9, 0.9), CFrame.new(cup + Vector3.new(-0.3, 4.2, 0)), W.Coral, { Shape = BALL })
		local fruit = Vector3.new(a.x + sx * 23.5, deckY + 1.2, gz - 1.2)
		piece(parent, "SampleOrange", Vector3.new(2.4, 2.4, 2.4), CFrame.new(fruit), W.Orange, { Shape = BALL })
		piece(
			parent,
			"SampleStrawberry",
			Vector3.new(1.8, 2.2, 1.8),
			CFrame.new(fruit + Vector3.new(sx * 2.2, -0.2, 0)),
			W.Coral,
			{ Shape = BALL }
		)
		piece(parent, "SampleLeaf", Vector3.new(1.4, 0.4, 1.4), CFrame.new(fruit + Vector3.new(sx * 2.2, 1, 0)), W.Grass)
	end
end

-- A cheering fan cut-out on the bleachers, facing -X (the court): a blocky body, a yellow
-- head with a painted smile and both arms up.
local function fan(parent: Instance, feet: Vector3, shirt: Color3)
	local face = CFrame.new(feet) * CFrame.Angles(0, math.rad(90), 0)
	piece(parent, "FanLegs", Vector3.new(1.6, 1.4, 0.3), face * CFrame.new(0, 0.7, 0), W.Navy)
	piece(parent, "FanBody", Vector3.new(1.9, 1.8, 0.3), face * CFrame.new(0, 2.3, 0), shirt)
	local head = piece(parent, "FanHead", Vector3.new(1.2, 1.2, 0.3), face * CFrame.new(0, 3.85, 0), W.Sunny)
	for _, s in { -1, 1 } do
		piece(
			parent,
			"FanArm",
			Vector3.new(0.5, 1.7, 0.3),
			face * CFrame.new(s * 1.2, 3.6, 0) * CFrame.Angles(0, 0, math.rad(-s * 25)),
			W.Sunny
		)
	end
	local gui = Instance.new("SurfaceGui")
	gui.Face = Enum.NormalId.Front
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 40
	gui.LightInfluence = 0
	gui.Parent = head
	local function blob(x: number, y: number, sw: number, sh: number)
		local f = Instance.new("Frame")
		f.BackgroundColor3 = W.Ink
		f.BorderSizePixel = 0
		f.AnchorPoint = Vector2.new(0.5, 0.5)
		f.Position = UDim2.fromScale(x, y)
		f.Size = UDim2.fromScale(sw, sh)
		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0.5, 0)
		corner.Parent = f
		f.Parent = gui
	end
	blob(0.32, 0.38, 0.14, 0.2)
	blob(0.68, 0.38, 0.14, 0.2)
	blob(0.5, 0.7, 0.46, 0.14)
end

-- Bleachers on their own deck past the +X edge: three stepped tiers of cheering fans and a
-- score / timer board at the far end, angled toward the court.
local function bleachers(parent: Instance, a: Arena.Spec, top: number)
	local x0 = a.x + a.sizeX / 2 + 1
	local zc, len = a.z + 1, 28
	piece(parent, "StandDeck", Vector3.new(14, 2, 40), CFrame.new(x0 + 7, top - 1, a.z - 4), W.Wood, { CanCollide = true })
	piece(parent, "StandDeckRim", Vector3.new(15, 1.2, 41), CFrame.new(x0 + 7, top - 1.5, a.z - 4), W.White)
	local fronts = { W.Teal, W.Sunny, W.HotPink }
	local shirts = { W.Coral, W.Blue, W.Mint, W.Grape, W.Orange, W.HotPink, W.Teal }
	for k = 0, 2 do
		local h = 1.4 * (k + 1)
		local x = x0 + 3 + k * 3.4
		piece(parent, "StandTier", Vector3.new(3.4, h, len), CFrame.new(x, top + h / 2, zc), fronts[k + 1], { CanCollide = true })
		piece(parent, "StandSeat", Vector3.new(3.6, 0.3, len + 0.2), CFrame.new(x, top + h + 0.15, zc), W.White)
		for n = 0, 4 do
			local z = zc - len / 2 + 3 + n * 5.5 + (k % 2) * 2.2
			fan(parent, Vector3.new(x + 0.4, top + h + 0.3, z), shirts[(n + k * 2) % #shirts + 1])
		end
	end
	-- Pennants on a line over the top tier.
	bunting(parent, Vector3.new(x0 + 11, top + 11.5, zc - len / 2), Vector3.new(x0 + 11, top + 11.5, zc + len / 2), 8)
	for _, sz in { -1, 1 } do
		piece(parent, "StandPole", Vector3.new(0.4, 11.5, 0.4), CFrame.new(x0 + 11, top + 5.75, zc + sz * len / 2), W.White)
	end
	-- The score board: two posts and a navy panel facing the court's centre.
	local at = Vector3.new(x0 + 7, top, a.z - 17.5)
	local look = CFrame.lookAt(at, Vector3.new(a.x, top, a.z + 6))
	for _, s in { -1, 1 } do
		piece(parent, "BoardPost", Vector3.new(0.9, 9, 0.9), look * CFrame.new(s * 6, 4.5, 0), W.White, { CanCollide = true })
	end
	piece(parent, "ScoreFrame", Vector3.new(16, 9.6, 0.6), look * CFrame.new(0, 13, 0.2), W.Sunny)
	local panel = piece(parent, "ScoreBoard", Vector3.new(15, 8.6, 0.6), look * CFrame.new(0, 13, -0.1), W.Navy)
	for i = -1, 1 do
		piece(
			parent,
			"ScoreLight",
			Vector3.new(1.2, 1.2, 1.2),
			look * CFrame.new(i * 5, 18.4, 0),
			W.Sunny,
			{ Shape = BALL, Material = Enum.Material.Neon }
		)
	end
	local gui = Instance.new("SurfaceGui")
	gui.Face = Enum.NormalId.Front
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 30
	gui.LightInfluence = 0
	gui.Parent = panel
	local rows: { { text: string, color: Color3, y: number, h: number } } = {
		{ text = "SHAKES", color = W.White, y = 0.03, h = 0.22 },
		{ text = "128", color = W.Sunny, y = 0.25, h = 0.42 },
		{ text = "TIME 0:45", color = W.Mint, y = 0.7, h = 0.26 },
	}
	for _, row in rows do
		local label = Instance.new("TextLabel")
		label.BackgroundTransparency = 1
		label.Position = UDim2.fromScale(0.05, row.y)
		label.Size = UDim2.fromScale(0.9, row.h)
		label.Text = row.text
		label.TextScaled = true
		label.Font = Common.theme.Fonts.Display
		label.TextColor3 = row.color
		label.Parent = gui
	end
end

-- Lobby, sea and horizon ----------------------------------------------------------------------

-- Flat 2D drawing on a SurfaceGui in pixel offsets (centre-anchored), so circles stay round.
type Draw = {
	round: number?,
	rot: number?,
	stroke: Color3?,
	thick: number?,
	alpha: number?,
	z: number?,
	name: string?,
}

local function surface(part: BasePart, face: Enum.NormalId, pixelsPerStud: number, name: string?): SurfaceGui
	local gui = Instance.new("SurfaceGui")
	gui.Name = name or "SurfaceGui"
	gui.Face = face
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = pixelsPerStud
	gui.LightInfluence = 0
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Parent = part
	return gui
end

local function box(parent: Instance, color: Color3, x: number, y: number, w: number, h: number, o: Draw?): Frame
	local opts: Draw = o or {}
	local f = Instance.new("Frame")
	f.Name = opts.name or "Shape"
	f.BackgroundColor3 = color
	f.BackgroundTransparency = opts.alpha or 0
	f.BorderSizePixel = 0
	f.AnchorPoint = Vector2.new(0.5, 0.5)
	f.Position = UDim2.fromOffset(x, y)
	f.Size = UDim2.fromOffset(w, h)
	f.Rotation = opts.rot or 0
	f.ZIndex = opts.z or 1
	if opts.round then
		local corner = Instance.new("UICorner")
		corner.CornerRadius = if opts.round >= 0.5 then UDim.new(0.5, 0) else UDim.new(0, opts.round * math.min(w, h))
		corner.Parent = f
	end
	if opts.stroke then
		local s = Instance.new("UIStroke")
		s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
		s.Color = opts.stroke
		s.Thickness = opts.thick or 3
		s.Parent = f
	end
	f.Parent = parent
	return f
end

local function circle(parent: Instance, color: Color3, x: number, y: number, d: number, o: Draw?): Frame
	local opts: Draw = table.clone(o or {})
	opts.round = 0.5
	return box(parent, color, x, y, d, d, opts)
end

type TextOpts = { stroke: number?, align: Enum.TextXAlignment?, name: string?, z: number? }

local function text(parent: Instance, str: string, color: Color3, x: number, y: number, w: number, h: number, o: TextOpts?): TextLabel
	local opts: TextOpts = o or {}
	local label = Instance.new("TextLabel")
	label.Name = opts.name or "Text"
	label.BackgroundTransparency = 1
	label.AnchorPoint = Vector2.new(0.5, 0.5)
	label.Position = UDim2.fromOffset(x, y)
	label.Size = UDim2.fromOffset(w, h)
	label.Text = str
	label.TextScaled = true
	label.TextWrapped = true
	label.Font = Common.theme.Fonts.Display
	label.TextColor3 = color
	label.TextXAlignment = opts.align or Enum.TextXAlignment.Center
	label.ZIndex = opts.z or 5
	if opts.stroke then
		local s = Instance.new("UIStroke")
		s.Thickness = opts.stroke
		s.Color = W.Ink
		s.Parent = label
	end
	label.Parent = parent
	return label
end

-- A transparent holder whose children draw above `z` siblings (icons keep their own order).
local function layer(parent: Instance, z: number): Frame
	local f = Instance.new("Frame")
	f.Name = "Icon"
	f.BackgroundTransparency = 1
	f.Size = UDim2.fromScale(1, 1)
	f.ZIndex = z
	f.Parent = parent
	return f
end

-- The board icons (they match Fx.Shake's falling items).
local function drawShake(parent: Instance, x: number, y: number, s: number)
	local g = layer(parent, 3)
	box(g, W.Mint, x + s * 0.14, y - s * 0.92, s * 0.1, s * 0.62, { rot = 15, z = 1 })
	circle(g, W.Cream, x, y - s * 0.62, s * 0.62, { z = 2 })
	box(g, W.White, x, y - s * 0.5, s * 0.86, s * 0.14, { round = 0.5, z = 3 })
	box(g, W.Pink, x, y, s * 0.7, s * 0.9, { round = 0.18, z = 2 })
	box(g, W.White, x, y + s * 0.08, s * 0.7, s * 0.2, { z = 3 })
	circle(g, W.Coral, x - s * 0.12, y - s * 0.96, s * 0.24, { z = 4 })
end

local function drawDumbbell(parent: Instance, x: number, y: number, s: number)
	local g = layer(parent, 3)
	box(g, W.Gold, x, y, s * 1.1, s * 0.14, { round = 0.5, z = 1 })
	for _, side in { -1, 1 } do
		box(g, W.Gold, x + side * s * 0.36, y, s * 0.2, s * 0.72, { round = 0.25, z = 2 })
		box(g, W.GoldDeep, x + side * s * 0.53, y, s * 0.14, s * 0.5, { round = 0.25, z = 2 })
	end
	box(g, W.White, x - s * 0.36, y - s * 0.18, s * 0.06, s * 0.22, { round = 0.5, z = 3, alpha = 0.3 })
end

local function drawOrb(parent: Instance, x: number, y: number, s: number)
	local g = layer(parent, 3)
	circle(g, W.SkyBlue, x, y, s, { alpha = 0.45, z = 1 })
	circle(g, W.Grape, x, y, s * 0.62, { z = 2, stroke = W.White, thick = 2 })
	circle(g, W.White, x - s * 0.1, y - s * 0.1, s * 0.16, { z = 3 })
end

local function drawBurger(parent: Instance, x: number, y: number, s: number)
	local g = layer(parent, 3)
	box(g, W.Honey, x, y + s * 0.3, s * 0.92, s * 0.2, { round = 0.5, z = 1 })
	box(g, W.WoodDark, x, y + s * 0.13, s * 1, s * 0.2, { round = 0.5, z = 2 })
	box(g, W.Sunny, x + s * 0.08, y + s * 0.02, s * 0.8, s * 0.1, { z = 3 })
	box(g, W.Grass, x, y - s * 0.04, s * 1.04, s * 0.1, { round = 0.5, z = 3 })
	box(g, W.Honey, x, y - s * 0.24, s * 0.96, s * 0.42, { round = 0.5, z = 4 })
	for i = -1, 1 do
		box(g, W.Cream, x + i * s * 0.22, y - s * (0.3 - math.abs(i) * 0.04), s * 0.08, s * 0.05, { round = 0.5, z = 5 })
	end
end

local function drawDonut(parent: Instance, x: number, y: number, s: number, hole: Color3)
	local g = layer(parent, 3)
	circle(g, W.Honey, x, y, s, { z = 1 })
	circle(g, W.HotPink, x, y - s * 0.03, s * 0.84, { z = 2 })
	circle(g, hole, x, y, s * 0.3, { z = 3, stroke = W.Honey, thick = 2 })
	local sprinkles = { W.Sunny, W.Mint, W.White, W.Blue, W.Sunny }
	for i, c in sprinkles do
		local a = math.rad(i * 72 + 10)
		box(g, c, x + math.cos(a) * s * 0.3, y + math.sin(a) * s * 0.3, s * 0.13, s * 0.05, { round = 0.5, rot = i * 47, z = 4 })
	end
end

local function drawSoda(parent: Instance, x: number, y: number, s: number)
	local g = layer(parent, 3)
	box(g, W.Coral, x, y, s * 0.6, s, { round = 0.16, z = 1 })
	box(g, W.White, x, y + s * 0.02, s * 0.6, s * 0.26, { z = 2 })
	box(g, W.Steel, x, y - s * 0.52, s * 0.5, s * 0.08, { round = 0.5, z = 2 })
	box(g, W.Steel, x + s * 0.06, y - s * 0.62, s * 0.06, s * 0.2, { rot = 20, z = 2 })
end

local function drawHeart(parent: Instance, x: number, y: number, s: number, color: Color3)
	local g = layer(parent, 3)
	local a = s / 1.707
	local cy = y + 0.073 * a
	box(g, color, x, cy, a, a, { rot = 45, z = 1 })
	for _, side in { -1, 1 } do
		circle(g, color, x + side * 0.354 * a, cy - 0.354 * a, a, { z = 1 })
	end
	circle(g, W.White, x - 0.42 * a, cy - 0.45 * a, a * 0.26, { z = 2, alpha = 0.25 })
end

local function drawCheck(parent: Instance, x: number, y: number, s: number)
	local g = layer(parent, 4)
	circle(g, W.Mint, x, y, s, { z = 1, stroke = W.Ink, thick = 3 })
	box(g, W.White, x - s * 0.13, y + s * 0.08, s * 0.14, s * 0.34, { round = 0.5, rot = -45, z = 2 })
	box(g, W.White, x + s * 0.1, y - s * 0.02, s * 0.14, s * 0.58, { round = 0.5, rot = 38, z = 2 })
end

-- A blocky player (front view) for the board's first step.
local function drawPlayer(parent: Instance, x: number, y: number, s: number)
	local g = layer(parent, 3)
	for _, side in { -1, 1 } do
		box(g, W.Navy, x + side * s * 0.11, y + s * 0.36, s * 0.18, s * 0.3, { z = 1 })
		box(g, W.Sunny, x + side * s * 0.3, y + s * 0.02, s * 0.14, s * 0.36, { z = 1 })
	end
	box(g, W.Blue, x, y + s * 0.04, s * 0.42, s * 0.4, { z = 2 })
	box(g, W.Sunny, x, y - s * 0.34, s * 0.32, s * 0.32, { round = 0.18, z = 2 })
	for _, side in { -1, 1 } do
		circle(g, W.Ink, x + side * s * 0.07, y - s * 0.37, s * 0.06, { z = 3 })
	end
	box(g, W.Ink, x, y - s * 0.26, s * 0.12, s * 0.035, { round = 0.5, z = 3 })
end

-- The HOW TO PLAY face (22 x 12 studs at 25 px/stud: 550 x 300 px): a hot-pink header, three
-- illustrated step cards and a navy footer with the hearts and the pass mark.
local function howToFace(gui: SurfaceGui)
	box(gui, W.HotPink, 275, 28, 550, 56, { z = 1 })
	text(gui, "HOW TO PLAY", W.White, 275, 29, 420, 44, { stroke = 3 })
	local steps: { { caption: string, bg: Color3 } } = {
		{ caption = "MOVE UNDER THE DROPS", bg = W.SkyBlue },
		{ caption = "CATCH SHAKES, DUMBBELLS & ORBS", bg = W.MintPale },
		{ caption = "DODGE JUNK FOOD!", bg = W.Apricot },
	}
	for i, step in steps do
		local card = box(gui, W.White, 95 + (i - 1) * 180, 156, 170, 180, { round = 0.08, stroke = W.Ink, thick = 3, z = 1 })
		local art = box(card, step.bg, 85, 64, 154, 112, { round = 0.09, z = 1 })
		text(card, step.caption, W.Ink, 85, 150, 156, 48, { z = 2 })
		local badge = circle(card, W.Sunny, 12, 12, 38, { stroke = W.Ink, thick = 3, z = 6 })
		text(badge, tostring(i), W.Ink, 19, 21, 26, 30, { z = 7 })
		if i == 1 then
			-- Sand, the catch ring with the drop's shadow, a shake falling into it and the
			-- player stepping over.
			box(art, W.Sand, 77, 98, 154, 28, { round = 0.3, z = 1 })
			box(art, W.Ink, 104, 94, 28, 8, { round = 0.5, alpha = 0.65, z = 2 })
			box(art, W.Mint, 104, 94, 58, 18, { round = 0.5, alpha = 1, stroke = W.Mint, thick = 4, z = 2 })
			for k, dx in { -8, 0, 8 } do
				box(art, W.White, 104 + dx, 10 + (k % 2) * 4, 3, 12, { round = 0.5, alpha = 0.2, z = 2 })
			end
			drawShake(art, 104, 52, 28)
			drawPlayer(art, 40, 68, 48)
			box(art, W.White, 69, 72, 18, 6, { round = 0.5, stroke = W.Ink, thick = 1, z = 4 })
			box(art, W.White, 80, 68, 12, 6, { round = 0.5, rot = 40, z = 4 })
			box(art, W.White, 80, 76, 12, 6, { round = 0.5, rot = -40, z = 4 })
		elseif i == 2 then
			drawShake(art, 30, 58, 30)
			drawDumbbell(art, 77, 50, 34)
			drawOrb(art, 124, 50, 34)
			drawCheck(art, 77, 90, 30)
		else
			drawDonut(art, 30, 74, 32, step.bg)
			drawSoda(art, 125, 72, 30)
			drawBurger(art, 77, 50, 42)
			local no = layer(art, 5)
			circle(no, W.Coral, 77, 50, 62, { alpha = 1, stroke = W.Coral, thick = 6, z = 1 })
			box(no, W.Coral, 77, 50, 6, 62, { rot = 45, z = 1 })
		end
	end
	-- Footer: three hearts, then the pass mark.
	local foot = box(gui, W.Navy, 275, 274, 530, 40, { round = 0.5, z = 1 })
	for k = 0, 2 do
		drawHeart(foot, 28 + k * 34, 20, 30, W.Coral)
	end
	text(foot, "3 HEARTS", W.White, 186, 21, 110, 28, { z = 4 })
	text(foot, "CATCH 25 TO PASS!", W.Sunny, 385, 21, 250, 30, { z = 4 })
end

-- A sign board on two wooden posts at `cf` (feet centre, facing its LookVector): a coloured
-- frame and a face part whose Front face carries the SurfaceGui. Returns the face.
local function signBoard(
	parent: Instance,
	name: string,
	cf: CFrame,
	w: number,
	h: number,
	bottom: number,
	frame: Color3,
	face: Color3
): BasePart
	local mid = bottom + h / 2
	for _, s in { -1, 1 } do
		piece(
			parent,
			name .. "Post",
			Vector3.new(0.9, mid + h / 2 - 0.5, 0.9),
			cf * CFrame.new(s * (w / 2 - 1.5), (mid + h / 2 - 0.5) / 2, 0.5),
			W.Wood,
			{ CanCollide = true }
		)
		piece(parent, name .. "Foot", Vector3.new(1.8, 0.5, 1.8), cf * CFrame.new(s * (w / 2 - 1.5), 0.25, 0.5), W.WoodDark)
	end
	piece(parent, name .. "Frame", Vector3.new(w + 1.2, h + 1.2, 0.5), cf * CFrame.new(0, mid, 0.15), frame, { CanCollide = true })
	return piece(parent, name, Vector3.new(w, h, 0.4), cf * CFrame.new(0, mid, -0.1), face)
end

-- The YOUR BEST board (15 x 10 studs at 30 px/stud: 450 x 300 px), styled like the bleachers'
-- score board. Fx / the HUD fill the labels Best, Clears and Reward by name.
local function bestBoard(parent: Instance, cf: CFrame): SurfaceGui
	local panel = signBoard(parent, "BestPanel", cf, 15, 10, 4, W.Sunny, W.Navy)
	for i = -1, 1 do
		piece(
			parent,
			"BestLight",
			Vector3.new(1.2, 1.2, 1.2),
			cf * CFrame.new(i * 5, 14.9, 0.1),
			W.Sunny,
			{ Shape = BALL, Material = Enum.Material.Neon }
		)
	end
	local gui = surface(panel, Enum.NormalId.Front, 30, "BestBoard")
	text(gui, "YOUR BEST", W.Sunny, 225, 40, 380, 56, { stroke = 3, name = "Title" })
	box(gui, W.White, 225, 78, 400, 3, { alpha = 0.6 })
	local rows: { { key: string, caption: string, value: string, color: Color3 } } = {
		{ key = "Best", caption = "BEST SCORE", value = "--", color = W.Sunny },
		{ key = "Clears", caption = "CLEARS", value = "0", color = W.Mint },
		{ key = "Reward", caption = "REWARD", value = "--", color = W.Orange },
	}
	for i, row in rows do
		local y = 118 + (i - 1) * 66
		box(gui, W.White, 225, y, 420, 54, { round = 0.3, alpha = 0.92 })
		text(gui, row.caption, W.White, 128, y, 210, 38, { align = Enum.TextXAlignment.Left, name = row.key .. "Caption" })
		text(gui, row.value, row.color, 330, y, 190, 44, { align = Enum.TextXAlignment.Right, name = row.key })
	end
	return gui
end

-- A candy-striped post (feet at `base`): a teal foot, `segments` stripes `len` studs long and
-- maybe a sunny ball on top.
local function candyPost(parent: Instance, base: Vector3, segments: number, len: number, ball: boolean)
	piece(parent, "PostFoot", Vector3.new(2.6, 0.8, 2.6), CFrame.new(base + Vector3.new(0, 0.4, 0)), W.Teal, { CanCollide = true })
	for i = 0, segments - 1 do
		piece(
			parent,
			"PostStripe",
			Vector3.new(len, 1.5, 1.5),
			CFrame.new(base + Vector3.new(0, 0.8 + len / 2 + i * len, 0)) * UPRIGHT,
			if i % 2 == 0 then W.HotPink else W.White,
			{ Shape = CYLINDER, CanCollide = true }
		)
	end
	if ball then
		piece(
			parent,
			"PostBall",
			Vector3.new(2.2, 2.2, 2.2),
			CFrame.new(base + Vector3.new(0, 0.8 + segments * len + 0.9, 0)),
			W.Sunny,
			{ Shape = BALL }
		)
	end
end

-- A small shake (cup, band, lid, cream, straw, cherry) standing at `base`, `s` = cup height.
local function shakeProp(parent: Instance, base: Vector3, s: number, cup: Color3)
	piece(
		parent,
		"PropCup",
		Vector3.new(s, s * 0.72, s * 0.72),
		CFrame.new(base + Vector3.new(0, s / 2, 0)) * UPRIGHT,
		cup,
		{ Shape = CYLINDER }
	)
	piece(
		parent,
		"PropBand",
		Vector3.new(s * 0.24, s * 0.76, s * 0.76),
		CFrame.new(base + Vector3.new(0, s * 0.42, 0)) * UPRIGHT,
		W.White,
		{ Shape = CYLINDER }
	)
	piece(
		parent,
		"PropCream",
		Vector3.new(s * 0.7, s * 0.5, s * 0.7),
		CFrame.new(base + Vector3.new(0, s * 1.08, 0)),
		W.Cream,
		{ Shape = BALL }
	)
	piece(
		parent,
		"PropStraw",
		Vector3.new(s * 0.12, s * 0.9, s * 0.12),
		CFrame.new(base + Vector3.new(s * 0.14, s * 1.4, 0)) * CFrame.Angles(0, 0, math.rad(-14)),
		W.Mint
	)
	piece(
		parent,
		"PropCherry",
		Vector3.new(s * 0.26, s * 0.26, s * 0.26),
		CFrame.new(base + Vector3.new(-s * 0.1, s * 1.36, s * 0.08)),
		W.Coral,
		{ Shape = BALL }
	)
end

-- A puffy cloud of white balls (no collisions, no shadow) centred at `at`.
local function cloud(parent: Instance, at: Vector3, size: number, shadow: boolean)
	local puffs =
		{ { 0, 0, 0, 1 }, { -0.75, -0.15, 0.1, 0.72 }, { 0.8, -0.2, -0.1, 0.68 }, { 0.3, 0.35, 0.15, 0.62 }, { -0.35, 0.28, -0.2, 0.55 } }
	for _, p in puffs do
		local d = size * p[4]
		piece(
			parent,
			"CloudPuff",
			Vector3.new(d, d, d),
			CFrame.new(at + Vector3.new(p[1], p[2], p[3]) * size),
			W.White,
			{ Shape = BALL, CanQuery = false, CanTouch = false, CastShadow = shadow }
		)
	end
end

-- The lobby deck past the court's +Z edge (lobby-local x from the court's centre line, z from
-- its +Z edge): a plank boardwalk with the START gate at the court entrance, the HOW TO PLAY
-- and YOUR BEST boards angled at the spawn, the practice mat under its cloud on the left and
-- the Tiki Shakes hut on the right; rope fences either side of the gate.
local function lobby(parent: Instance, c: Arena.Spec, top: number): Lobby
	local z0 = c.z + c.sizeZ / 2
	local function L(x: number, y: number, z: number): Vector3
		return Vector3.new(c.x + x, top + y, z0 + z)
	end
	local spawnAt = L(0, 0, LOBBY_SPAWN_Z)
	local function facingSpawn(x: number, z: number): CFrame
		local at = L(x, 0, z)
		return CFrame.lookAt(at, Vector3.new(spawnAt.X, at.Y, spawnAt.Z))
	end

	-- Deck: a warm apricot boardwalk, planks running across (a lighter / darker stripe drawn
	-- on its top) inside a pastel trim border (pink, white, mint), a pink rim and two more
	-- pink floats under the far corners.
	local deck = piece(
		parent,
		"LobbyDeck",
		Vector3.new(c.sizeX, 2, LOBBY_DEPTH),
		CFrame.new(L(0, -1, LOBBY_DEPTH / 2)),
		W.Apricot,
		{ CanCollide = true }
	)
	piece(parent, "LobbyDeckRim", Vector3.new(c.sizeX + 2, 1.2, LOBBY_DEPTH + 1), CFrame.new(L(0, -1.5, LOBBY_DEPTH / 2 + 0.5)), W.Pink)
	local planks = surface(deck, Enum.NormalId.Top, 4, "Planks")
	local count = LOBBY_DEPTH / 2.5
	for i = 0, count - 1 do
		local stripe = Instance.new("Frame")
		stripe.BorderSizePixel = 0
		stripe.BackgroundColor3 = W.Terracotta
		stripe.BackgroundTransparency = if i % 2 == 1 then 0.8 else 0.92
		stripe.Position = UDim2.fromScale(0, i / count)
		stripe.Size = UDim2.fromScale(1, 1 / count)
		stripe.Parent = planks
		local seam = Instance.new("Frame")
		seam.BorderSizePixel = 0
		seam.BackgroundColor3 = W.Terracotta
		seam.BackgroundTransparency = 0.55
		seam.Position = UDim2.fromScale(0, i / count)
		seam.Size = UDim2.new(1, 0, 0, 1)
		seam.ZIndex = 2
		seam.Parent = planks
	end
	-- The trim: nested bands in from every edge (studs in, studs wide, colour).
	local px = 4
	local deckW, deckD = c.sizeX * px, LOBBY_DEPTH * px
	local bands: { { inset: number, width: number, color: Color3 } } = {
		{ inset = 0, width = 1.6, color = W.Pink },
		{ inset = 1.6, width = 0.5, color = W.White },
		{ inset = 2.1, width = 1, color = W.Mint },
	}
	for _, band in bands do
		local i, bw = band.inset * px, band.width * px
		local edges = {
			{ i, i, deckW - 2 * i, bw },
			{ i, deckD - i - bw, deckW - 2 * i, bw },
			{ i, i, bw, deckD - 2 * i },
			{ deckW - i - bw, i, bw, deckD - 2 * i },
		}
		for _, e in edges do
			local f = Instance.new("Frame")
			f.Name = "Trim"
			f.BorderSizePixel = 0
			f.BackgroundColor3 = band.color
			f.Position = UDim2.fromOffset(e[1], e[2])
			f.Size = UDim2.fromOffset(e[3], e[4])
			f.ZIndex = 3
			f.Parent = planks
		end
	end
	local floatH = math.max(top - 2, 1)
	for _, sx in { -1, 1 } do
		piece(
			parent,
			"LobbyPontoon",
			Vector3.new(floatH, 6, 6),
			CFrame.new(c.x + sx * (c.sizeX / 2 - 4), floatH / 2, z0 + LOBBY_DEPTH - 4) * UPRIGHT,
			W.Pink,
			{ Shape = CYLINDER }
		)
	end

	-- The spawn mat and a teal path of sunny stepping dots up to the START pad.
	piece(
		parent,
		"LobbySpawnRim",
		Vector3.new(0.15, 8.4, 8.4),
		CFrame.new(spawnAt + Vector3.new(0, 0.07, 0)) * UPRIGHT,
		W.White,
		{ Shape = CYLINDER }
	)
	piece(
		parent,
		"LobbySpawnPad",
		Vector3.new(0.2, 7, 7),
		CFrame.new(spawnAt + Vector3.new(0, 0.1, 0)) * UPRIGHT,
		W.Sunny,
		{ Shape = CYLINDER }
	)
	local pathFrom, pathTo = START_Z + START_RADIUS + 1.8, LOBBY_SPAWN_Z - 4.4
	local pathLen = pathTo - pathFrom
	piece(parent, "LobbyPath", Vector3.new(8, 0.05, pathLen), CFrame.new(L(0, 0.03, pathFrom + pathLen / 2)), W.Teal)
	for _, sx in { -1, 1 } do
		piece(parent, "LobbyPathEdge", Vector3.new(0.6, 0.06, pathLen), CFrame.new(L(sx * 4.3, 0.03, pathFrom + pathLen / 2)), W.White)
	end
	for k = 0, 3 do
		local z = pathFrom + pathLen * (k + 0.5) / 4
		piece(
			parent,
			"LobbyPathDot",
			Vector3.new(0.06, 3.6, 3.6),
			CFrame.new(L(0, 0.07, z)) * UPRIGHT,
			if k % 2 == 0 then W.Sunny else W.White,
			{ Shape = CYLINDER }
		)
	end

	-- Rope fences along the court's edge, open at the gate; tall flag poles at the ends.
	for _, sx in { -1, 1 } do
		local xs = { 7, 15, 23, 31 }
		for i, x in xs do
			local tall = i == #xs
			local h = if tall then 10 else 3
			piece(
				parent,
				"FencePost",
				Vector3.new(h, 0.6, 0.6),
				CFrame.new(L(sx * x, h / 2, 1.2)) * UPRIGHT,
				W.White,
				{ Shape = CYLINDER, CanCollide = true }
			)
			piece(
				parent,
				"FenceCap",
				Vector3.new(1, 1, 1) * (if tall then 1.3 else 0.9),
				CFrame.new(L(sx * x, h + 0.3, 1.2)),
				W.Sunny,
				{ Shape = BALL }
			)
			if i > 1 then
				piece(
					parent,
					"FenceRope",
					Vector3.new(8, 0.3, 0.3),
					CFrame.new(L(sx * (x - 4), 2.5, 1.2)),
					W.HotPink,
					{ CanCollide = true }
				)
			end
		end
	end

	-- The START gate at the court entrance: a glowing sunny bullseye pad in a hot-pink neon
	-- ring and a soft halo, a light column, a floating "START" label with an arrow down to it,
	-- candy-striped posts and the "SHAKE CATCH" crest (it hides the Shake Chute's own title
	-- as seen from the spawn), a shake on top.
	local sp = L(0, 0, START_Z)
	piece(
		parent,
		"StartHalo",
		Vector3.new(0.06, START_RADIUS * 2 + 7, START_RADIUS * 2 + 7),
		CFrame.new(sp + Vector3.new(0, 0.04, 0)) * UPRIGHT,
		W.Sunny,
		{ Shape = CYLINDER, Material = Enum.Material.Neon, Transparency = 0.55, CastShadow = false }
	)
	piece(
		parent,
		"StartGlowRing",
		Vector3.new(0.12, START_RADIUS * 2 + 4, START_RADIUS * 2 + 4),
		CFrame.new(sp + Vector3.new(0, 0.07, 0)) * UPRIGHT,
		W.HotPink,
		{ Shape = CYLINDER, Material = Enum.Material.Neon, CastShadow = false }
	)
	piece(
		parent,
		"StartPadRim",
		Vector3.new(0.2, START_RADIUS * 2 + 1.6, START_RADIUS * 2 + 1.6),
		CFrame.new(sp + Vector3.new(0, 0.1, 0)) * UPRIGHT,
		W.White,
		{ Shape = CYLINDER }
	)
	local pad = piece(
		parent,
		"StartPad",
		Vector3.new(0.3, START_RADIUS * 2, START_RADIUS * 2),
		CFrame.new(sp + Vector3.new(0, 0.15, 0)) * UPRIGHT,
		W.Sunny,
		{ Shape = CYLINDER, Material = Enum.Material.Neon }
	)
	local light = Instance.new("PointLight")
	light.Color = W.Sunny
	light.Range = 20
	light.Brightness = 2
	light.Parent = pad
	-- A bullseye on the pad: a hot-pink ring and a white centre.
	piece(
		parent,
		"StartPadRing",
		Vector3.new(0.05, START_RADIUS * 1.2, START_RADIUS * 1.2),
		CFrame.new(sp + Vector3.new(0, 0.32, 0)) * UPRIGHT,
		W.HotPink,
		{ Shape = CYLINDER, CanQuery = false, CanTouch = false }
	)
	piece(
		parent,
		"StartPadDot",
		Vector3.new(0.05, START_RADIUS * 0.75, START_RADIUS * 0.75),
		CFrame.new(sp + Vector3.new(0, 0.35, 0)) * UPRIGHT,
		W.White,
		{ Shape = CYLINDER, CanQuery = false, CanTouch = false }
	)
	piece(
		parent,
		"StartGlow",
		Vector3.new(6, START_RADIUS * 2 - 0.8, START_RADIUS * 2 - 0.8),
		CFrame.new(sp + Vector3.new(0, 3.15, 0)) * UPRIGHT,
		W.Sunny,
		{ Shape = CYLINDER, Material = Enum.Material.Neon, Transparency = 0.88, CastShadow = false, CanQuery = false, CanTouch = false }
	)
	-- The floating "START" label over the pad (facing the spawn) and a hot-pink arrow under it.
	local labelY = 8
	piece(
		parent,
		"StartLabelFrame",
		Vector3.new(14, 4.4, 0.4),
		CFrame.new(sp + Vector3.new(0, labelY, -0.1)),
		W.White,
		{ CastShadow = false }
	)
	local label = piece(
		parent,
		"StartLabel",
		Vector3.new(13, 3.6, 0.4),
		CFrame.new(sp + Vector3.new(0, labelY, 0.1)),
		W.HotPink,
		{ CastShadow = false }
	)
	word(label, "START", W.Sunny)
	for _, side in { -1, 1 } do
		piece(
			parent,
			"StartArrow",
			Vector3.new(0.3, 2.2, 1.4),
			CFrame.new(sp + Vector3.new(side * 0.7, labelY - 3.5, 0.1))
				* CFrame.Angles(0, math.rad(-side * 90), 0)
				* CFrame.Angles(0, 0, math.pi),
			W.HotPink,
			{ ClassName = "WedgePart", CastShadow = false }
		)
	end
	for _, sx in { -1, 1 } do
		candyPost(parent, sp + Vector3.new(sx * (START_RADIUS + 4.5), 0, 0), 3, 3.6, false)
	end
	local crestY = 15
	piece(parent, "TitleFrame", Vector3.new(23.4, 5.8, 0.5), CFrame.new(sp + Vector3.new(0, crestY, -0.15)), W.White)
	local title = piece(parent, "TitleSign", Vector3.new(22, 4.6, 0.4), CFrame.new(sp + Vector3.new(0, crestY, 0.1)), W.HotPink)
	word(title, "SHAKE CATCH", W.Sunny)
	piece(
		parent,
		"TitleTrim",
		Vector3.new(22.6, 0.4, 0.9),
		CFrame.new(sp + Vector3.new(0, crestY - 3.1, 0)),
		W.Sunny,
		{ Material = Enum.Material.Neon }
	)
	for _, sx in { -1, 1 } do
		piece(
			parent,
			"TitleBall",
			Vector3.new(1.6, 1.6, 1.6),
			CFrame.new(sp + Vector3.new(sx * 11.7, crestY + 3.4, -0.15)),
			W.Sunny,
			{ Shape = BALL }
		)
		bunting(parent, sp + Vector3.new(sx * 11.7, crestY - 3, 0), L(sx * 31, 9.8, 1.2), 7)
	end
	shakeProp(parent, sp + Vector3.new(0, crestY + 2.9, -0.15), 3.2, W.Pink)

	-- The boards, angled at the spawn: HOW TO PLAY on the left, YOUR BEST on the right.
	local howTo = signBoard(parent, "HowToBoard", facingSpawn(-17, 18), 22, 12, 2.5, W.Teal, W.Cream)
	howToFace(surface(howTo, Enum.NormalId.Front, 25, "HowToPlay"))
	local board = bestBoard(parent, facingSpawn(16, 18))

	-- The practice mat (Fx drops slow demo items on it from under its little cloud) and its
	-- big sign on the deck's left edge, turned between the spawn and the aisle behind it.
	local pc = L(PRACTICE.x, 0, PRACTICE.z)
	piece(
		parent,
		"PracticeRim",
		Vector3.new(0.2, PRACTICE_MAT + 1.6, PRACTICE_MAT + 1.6),
		CFrame.new(pc + Vector3.new(0, 0.1, 0)) * UPRIGHT,
		W.White,
		{ Shape = CYLINDER }
	)
	piece(
		parent,
		"PracticeMat",
		Vector3.new(0.3, PRACTICE_MAT, PRACTICE_MAT),
		CFrame.new(pc + Vector3.new(0, 0.15, 0)) * UPRIGHT,
		W.Grape,
		{ Shape = CYLINDER }
	)
	local rings: { { d: number, color: Color3 } } = {
		{ d = 13, color = W.White },
		{ d = 11.2, color = W.Teal },
		{ d = 6.4, color = W.White },
		{ d = 4.6, color = W.Mint },
		{ d = 1.8, color = W.White },
	}
	for i, ring in rings do
		piece(
			parent,
			"PracticeRing",
			Vector3.new(0.05, ring.d, ring.d),
			CFrame.new(pc + Vector3.new(0, 0.3 + i * 0.03, 0)) * UPRIGHT,
			ring.color,
			{ Shape = CYLINDER }
		)
	end
	-- The invisible "PracticeArea" Fx.Shake looks up by name: a thin plate the size of the
	-- demo drop square, its top on the mat; DropY is where the demo items start.
	local practiceArea = piece(
		parent,
		"PracticeArea",
		Vector3.new(PRACTICE.half * 2, 0.2, PRACTICE.half * 2),
		CFrame.new(pc + Vector3.new(0, 0.2, 0)),
		W.Teal,
		{ Transparency = 1, CanQuery = false, CanTouch = false, CastShadow = false }
	)
	practiceArea:SetAttribute("DropY", top + PRACTICE_DROP)
	cloud(parent, pc + Vector3.new(0, PRACTICE_DROP + 4.2, 0), 8.5, true)
	local signAt = L(-29, 0, PRACTICE.z)
	local signLook = CFrame.lookAt(signAt, L(2, 0, 56))
	local practiceSign = signBoard(parent, "PracticeSign", signLook, 13, 3.6, 4.6, W.Sunny, W.Grape)
	word(practiceSign, "PRACTICE", W.White, Enum.NormalId.Front)

	-- The Tiki Shakes hut on the right: a counter facing the aisle, a thatched roof sloping
	-- toward it with a fringe, its sign on the ridge, shakes on the counter and two stools.
	local hz = 44
	piece(parent, "TikiWall", Vector3.new(1, 11.5, 12), CFrame.new(L(30.5, 5.75, hz)), W.WoodDark, { CanCollide = true })
	piece(parent, "TikiCounter", Vector3.new(2.4, 4, 10), CFrame.new(L(20, 2, hz)), W.Wood, { CanCollide = true })
	piece(parent, "TikiCounterTop", Vector3.new(3, 0.5, 11), CFrame.new(L(20, 4.25, hz)), W.White)
	piece(parent, "TikiKick", Vector3.new(0.2, 0.6, 10), CFrame.new(L(18.75, 0.5, hz)), W.Mint, { Material = Enum.Material.Neon })
	for k = -1, 1 do
		piece(parent, "TikiSlat", Vector3.new(0.2, 3, 0.7), CFrame.new(L(18.75, 2.3, hz + k * 3.3)), W.Honey)
	end
	for _, sz in { -1, 1 } do
		piece(
			parent,
			"TikiPole",
			Vector3.new(9.6, 0.8, 0.8),
			CFrame.new(L(19, 4.8, hz + sz * 5.4)) * UPRIGHT,
			W.Honey,
			{ Shape = CYLINDER, CanCollide = true }
		)
	end
	local slope = CFrame.Angles(0, 0, math.rad(12))
	piece(parent, "TikiRoof", Vector3.new(14, 0.8, 13.6), CFrame.new(L(24.5, 10.6, hz)) * slope, W.SandDark)
	piece(parent, "TikiThatch", Vector3.new(13, 0.6, 12.8), CFrame.new(L(24.6, 11.2, hz)) * slope, W.Honey)
	for k = 0, 7 do
		piece(
			parent,
			"TikiFringe",
			Vector3.new(0.2, 1.4, 1.6),
			CFrame.new(L(17.7, 8.5, hz - 5.95 + k * 1.7)) * CFrame.Angles(0, 0, math.pi),
			if k % 2 == 0 then W.Honey else W.SandDark,
			{ ClassName = "WedgePart" }
		)
	end
	piece(parent, "TikiSignBack", Vector3.new(0.3, 3, 10.4), CFrame.new(L(21.3, 12, hz)), W.White)
	local hutSign = piece(parent, "TikiSign", Vector3.new(0.4, 2.4, 9.6), CFrame.new(L(21.1, 12, hz)), W.HotPink)
	word(hutSign, "TIKI SHAKES", W.Sunny, Enum.NormalId.Left)
	local cups: { { z: number, color: Color3, s: number } } =
		{ { z = -3.4, color = W.Pink, s = 1.4 }, { z = 0, color = W.Mint, s = 1.7 }, { z = 3.4, color = W.Grape, s = 1.4 } }
	for _, cup in cups do
		shakeProp(parent, L(20, 4.5, hz + cup.z), cup.s, cup.color)
	end
	for i, sz in { -2.5, 2.5 } do
		piece(
			parent,
			"StoolLeg",
			Vector3.new(2.6, 0.4, 0.4),
			CFrame.new(L(16.4, 1.3, hz + sz)) * UPRIGHT,
			W.Steel,
			{ Shape = CYLINDER, CanCollide = true }
		)
		piece(
			parent,
			"StoolSeat",
			Vector3.new(0.5, 2, 2),
			CFrame.new(L(16.4, 2.85, hz + sz)) * UPRIGHT,
			if i == 1 then W.Coral else W.Mint,
			{ Shape = CYLINDER, CanCollide = true }
		)
	end

	-- Palms framing the gate and the practice corner.
	palm(parent, L(-27, 0, 5), math.rad(-40))
	palm(parent, L(27, 0, 5), math.rad(220))
	palm(parent, L(-29, 0, 47.5), math.rad(130))

	return {
		lobbySpawn = CFrame.lookAt(spawnAt, L(0, 0, 0)),
		startPad = pad,
		board = board,
		practiceArea = { x0 = pc.X - PRACTICE.half, x1 = pc.X + PRACTICE.half, z0 = pc.Z - PRACTICE.half, z1 = pc.Z + PRACTICE.half },
		practiceDropY = top + PRACTICE_DROP,
	}
end

-- Moves World.Arena's EXIT pad and arch (built in the court's +X / +Z corner) onto the lobby
-- deck at `at`, the arch facing `toward`, and dresses its sign with a frame and a hint plate.
local function moveExit(folder: Model, parent: Instance, at: Vector3, toward: Vector3)
	local look = CFrame.lookAt(at, Vector3.new(toward.X, at.Y, toward.Z))
	local side = -1
	for _, child in folder:GetChildren() do
		if child:IsA("BasePart") then
			if child.Name == "ArenaExit" then
				child.CFrame = look * CFrame.new(0, 0.15, 0) * UPRIGHT
			elseif child.Name == "ArenaExitPost" then
				child.CFrame = look * CFrame.new(side * 3.5, 4, 0) * UPRIGHT
				side = 1
			elseif child.Name == "ArenaExitSign" then
				child.CFrame = look * CFrame.new(0, 8.6, 0)
			end
		end
	end
	piece(parent, "ExitPadRim", Vector3.new(0.2, 7.4, 7.4), look * CFrame.new(0, 0.1, 0) * UPRIGHT, W.White, { Shape = CYLINDER })
	piece(parent, "ExitSignFrame", Vector3.new(9, 2.6, 0.4), look * CFrame.new(0, 8.6, 0.45), W.White)
	for _, s in { -1, 1 } do
		piece(
			parent,
			"ExitBall",
			Vector3.new(1.3, 1.3, 1.3),
			look * CFrame.new(s * 4.5, 10.2, 0.4),
			W.Mint,
			{ Shape = BALL, Material = Enum.Material.Neon }
		)
	end
	local hint = piece(parent, "ExitHint", Vector3.new(5.6, 1, 0.3), look * CFrame.new(0, 6.9, 0), W.Mint)
	word(hint, "TO PLAZA", W.White, Enum.NormalId.Front)
end

-- The arena's own sea (World.Hub's sea line and tiles: the hub's ocean ends ~3000 studs out),
-- a light lagoon round the sand island under the decks (its beach props and jetty), sandbars
-- close by, the horizon landmarks, palm islands on the horizon and clouds.
-- Nothing here collides: a fall goes into the sea and Modes.Shake puts the player back.
local function surroundings(parent: Instance, cx: number, cz: number)
	local still: { [string]: any } = { CanCollide = false, CanQuery = false, CanTouch = false, CastShadow = false }
	for ix = -1, 1 do
		for iz = -1, 1 do
			local props = table.clone(still)
			props.Reflectance = 0.05
			piece(
				parent,
				"Ocean",
				Vector3.new(OCEAN_TILE, 2, OCEAN_TILE),
				CFrame.new(cx + ix * OCEAN_TILE, OCEAN_TOP - 1, cz + iz * OCEAN_TILE),
				W.Ocean,
				props
			)
		end
	end
	local function disc(name: string, radius: number, topY: number, height: number, color: Color3, x: number, z: number)
		local props = table.clone(still)
		props.Shape = CYLINDER
		piece(parent, name, Vector3.new(height, radius * 2, radius * 2), CFrame.new(x, topY - height / 2, z) * UPRIGHT, color, props)
	end
	disc("Lagoon", 132, OCEAN_TOP + 0.2, 0.2, W.Shallows, cx, cz + 15)
	-- An anchored, non-colliding prop (the `still` defaults plus `extra`).
	local function deco(name: string, size: Vector3, cf: CFrame, color: Color3, extra: { [string]: any }?): BasePart
		local props = table.clone(still)
		for key, value in (extra or {}) :: { [string]: any } do
			props[key] = value
		end
		return piece(parent, name, size, cf, color, props)
	end

	-- The island under the decks: a rounded sand beach (round corners, ISLAND.r) with a wet-sand
	-- rim and a white foam ring at the water line, so the shore reads against the lagoon.
	local function roundRect(name: string, grow: number, topY: number, height: number, color: Color3)
		local x0, x1 = cx - ISLAND.halfX - grow, cx + ISLAND.halfX + grow
		local z0, z1 = cz + ISLAND.z0 - grow, cz + ISLAND.z1 + grow
		local r = ISLAND.r + grow
		local midX, midZ = (x0 + x1) / 2, (z0 + z1) / 2
		local y = topY - height / 2
		deco(name, Vector3.new(x1 - x0 - 2 * r, height, z1 - z0), CFrame.new(midX, y, midZ), color)
		deco(name, Vector3.new(x1 - x0, height, z1 - z0 - 2 * r), CFrame.new(midX, y, midZ), color)
		for _, corner in { { x0 + r, z0 + r }, { x1 - r, z0 + r }, { x0 + r, z1 - r }, { x1 - r, z1 - r } } do
			deco(name, Vector3.new(height, r * 2, r * 2), CFrame.new(corner[1], y, corner[2]) * UPRIGHT, color, { Shape = CYLINDER })
		end
	end
	roundRect("ShoreFoam", 4.5, OCEAN_TOP + 0.4, 0.3, W.White)
	roundRect("WetSand", 1.6, 0.2, 1.6, W.SandDark)
	roundRect("Beach", 0, 0.7, 2, W.Sand)
	local beachY = 0.7

	-- Beach umbrellas and towels on the sand beside the decks.
	local umbrellas: { { x: number, z: number, color: Color3, towel: Color3 } } = {
		{ x = -45, z = -8, color = W.Coral, towel = W.SkyBlue },
		{ x = -45, z = 44, color = W.Mint, towel = W.Pink },
		{ x = 52, z = 40, color = W.Grape, towel = W.Sunny },
	}
	for _, u in umbrellas do
		local at = Vector3.new(cx + u.x, beachY, cz + u.z)
		deco("UmbrellaPole", Vector3.new(9, 0.5, 0.5), CFrame.new(at + Vector3.new(0, 4.5, 0)) * UPRIGHT, W.White, { Shape = CYLINDER })
		deco("UmbrellaCanopy", Vector3.new(0.8, 10, 10), CFrame.new(at + Vector3.new(0, 8.6, 0)) * UPRIGHT, u.color, { Shape = CYLINDER })
		deco("UmbrellaTop", Vector3.new(0.9, 6, 6), CFrame.new(at + Vector3.new(0, 9.3, 0)) * UPRIGHT, W.White, { Shape = CYLINDER })
		deco("UmbrellaKnob", Vector3.new(1.2, 1.2, 1.2), CFrame.new(at + Vector3.new(0, 10, 0)), u.color, { Shape = BALL })
		deco("BeachTowel", Vector3.new(4, 0.1, 7), CFrame.new(at + Vector3.new(3.4, 0.05, 1)) * CFrame.Angles(0, 0.3, 0), u.towel)
	end

	-- A jetty off the beach on the +X side: planks on posts out over the lagoon, a ladder at
	-- its end and two swim rings bobbing beside it.
	local jz = cz + 24
	local jx0, jx1 = cx + ISLAND.halfX - 8, cx + ISLAND.halfX + 22
	local jy = beachY + 1.6
	deco("Jetty", Vector3.new(jx1 - jx0, 0.8, 6), CFrame.new((jx0 + jx1) / 2, jy, jz), W.Honey)
	for _, sz in { -1, 1 } do
		deco("JettyEdge", Vector3.new(jx1 - jx0, 0.4, 0.5), CFrame.new((jx0 + jx1) / 2, jy + 0.6, jz + sz * 2.9), W.White)
		for k = 0, 3 do
			local x = jx0 + 3 + k * (jx1 - jx0 - 6) / 3
			deco("JettyPost", Vector3.new(6, 0.9, 0.9), CFrame.new(x, jy - 2.2, jz + sz * 2.6) * UPRIGHT, W.WoodDark, { Shape = CYLINDER })
		end
		deco("LadderRail", Vector3.new(0.4, 7, 0.4), CFrame.new(jx1 + 0.4, jy - 0.6, jz + sz * 1.3), W.Steel)
	end
	for k = 0, 3 do
		deco("LadderRung", Vector3.new(0.3, 0.3, 2.6), CFrame.new(jx1 + 0.4, jy + 0.2 - k * 1.4, jz), W.Steel)
	end
	local swimRings: { { x: number, z: number, color: Color3 } } =
		{ { x = 6, z = 9, color = W.Coral }, { x = 14, z = -8, color = W.Sunny } }
	for i, ring in swimRings do
		local at = Vector3.new(jx1 - ring.x, OCEAN_TOP + 0.3, jz + ring.z)
		deco("SwimRing", Vector3.new(1, 5, 5), CFrame.new(at) * UPRIGHT, ring.color, { Shape = CYLINDER })
		deco("SwimRingHole", Vector3.new(1.05, 2.2, 2.2), CFrame.new(at) * UPRIGHT, W.Shallows, { Shape = CYLINDER })
		for q = 0, 1 do
			local a = q * math.pi + i
			deco(
				"SwimRingBand",
				Vector3.new(1.1, 1, 1.4),
				CFrame.new(at + Vector3.new(math.cos(a) * 1.8, 0, math.sin(a) * 1.8)) * CFrame.Angles(0, -a, 0),
				W.White
			)
		end
	end

	-- Bold props on the back beach past the Smoothie Bar (outside its deck's ends): a giant
	-- shake on the left, a striped beach ball on the right, and a flamingo float in the water.
	local back = cz + ISLAND.z0 + 10
	local giant = Vector3.new(cx - 44, beachY, back)
	deco("GiantShakeBase", Vector3.new(1, 12, 12), CFrame.new(giant + Vector3.new(0, 0.5, 0)) * UPRIGHT, W.HotPink, { Shape = CYLINDER })
	local gs = 12
	deco(
		"GiantShakeCup",
		Vector3.new(gs, gs * 0.72, gs * 0.72),
		CFrame.new(giant + Vector3.new(0, 1 + gs / 2, 0)) * UPRIGHT,
		W.Mint,
		{ Shape = CYLINDER }
	)
	deco(
		"GiantShakeBand",
		Vector3.new(gs * 0.24, gs * 0.76, gs * 0.76),
		CFrame.new(giant + Vector3.new(0, 1 + gs * 0.42, 0)) * UPRIGHT,
		W.White,
		{ Shape = CYLINDER }
	)
	deco(
		"GiantShakeCream",
		Vector3.new(gs * 0.72, gs * 0.72, gs * 0.72),
		CFrame.new(giant + Vector3.new(0, 1 + gs * 1.04, 0)),
		W.Cream,
		{ Shape = BALL }
	)
	deco(
		"GiantShakeStraw",
		Vector3.new(gs * 0.12, gs * 0.9, gs * 0.12),
		CFrame.new(giant + Vector3.new(gs * 0.16, 1 + gs * 1.42, 0)) * CFrame.Angles(0, 0, math.rad(-14)),
		W.HotPink
	)
	deco(
		"GiantShakeCherry",
		Vector3.new(gs * 0.28, gs * 0.28, gs * 0.28),
		CFrame.new(giant + Vector3.new(-gs * 0.1, 1 + gs * 1.38, gs * 0.06)),
		W.Coral,
		{ Shape = BALL }
	)
	local ball = Vector3.new(cx + 45, beachY + 6, back - 2)
	deco("BeachBall", Vector3.new(12, 12, 12), CFrame.new(ball), W.White, { Shape = BALL })
	for i, color in { W.Coral, W.Sunny, W.Blue } do
		local tilt = CFrame.new(ball) * CFrame.Angles(math.rad(25), 0, math.rad(10))
		deco("BeachBallBand", Vector3.new(2.6, 12.15, 12.15), tilt * CFrame.Angles(0, math.rad(i * 60), 0), color, { Shape = CYLINDER })
	end
	local flamingo = Vector3.new(cx + 22, OCEAN_TOP, cz + ISLAND.z0 - 20)
	deco("FlamingoRing", Vector3.new(1.4, 14, 14), CFrame.new(flamingo + Vector3.new(0, 0.5, 0)) * UPRIGHT, W.Pink, { Shape = CYLINDER })
	deco("FlamingoBody", Vector3.new(8, 8, 8), CFrame.new(flamingo + Vector3.new(0, 3.2, 0)), W.HotPink, { Shape = BALL })
	deco(
		"FlamingoNeck",
		Vector3.new(1.8, 9, 1.8),
		CFrame.new(flamingo + Vector3.new(3.2, 8.4, 0)) * CFrame.Angles(0, 0, math.rad(-12)),
		W.HotPink
	)
	deco("FlamingoHead", Vector3.new(3.4, 3.4, 3.4), CFrame.new(flamingo + Vector3.new(4.4, 13, 0)), W.HotPink, { Shape = BALL })
	deco(
		"FlamingoBeak",
		Vector3.new(2.6, 1, 1.1),
		CFrame.new(flamingo + Vector3.new(6.3, 12.5, 0)) * CFrame.Angles(0, 0, math.rad(-25)),
		W.Ink
	)
	for _, sz in { -1, 1 } do
		deco("FlamingoEye", Vector3.new(0.6, 0.6, 0.6), CFrame.new(flamingo + Vector3.new(5, 13.6, sz * 1.5)), W.Ink, { Shape = BALL })
		deco(
			"FlamingoWing",
			Vector3.new(5, 3, 1),
			CFrame.new(flamingo + Vector3.new(-0.6, 4.2, sz * 3.8)) * CFrame.Angles(0, 0, math.rad(15)),
			W.Pink
		)
	end

	-- Sandbars: two overlapping sand humps in a foam ring and shallows, a palm or two.
	local bars: { { x: number, z: number, r: number, turn: number, palms: number } } = {
		{ x = -175, z = 95, r = 18, turn = 0.6, palms = 1 },
		{ x = 190, z = -40, r = 22, turn = 2.2, palms = 2 },
		{ x = -95, z = -205, r = 15, turn = 1.3, palms = 1 },
	}
	for _, bar in bars do
		local x, z = cx + bar.x, cz + bar.z
		local ox, oz = math.cos(bar.turn) * bar.r * 0.9, math.sin(bar.turn) * bar.r * 0.9
		disc("SandbarShallows", bar.r * 1.6 + 12, OCEAN_TOP + 0.15, 0.2, W.Shallows, x + ox * 0.4, z + oz * 0.4)
		disc("SandbarFoam", bar.r + 2.5, OCEAN_TOP + 0.35, 0.3, W.White, x, z)
		disc("SandbarFoam", bar.r * 0.7 + 2.5, OCEAN_TOP + 0.35, 0.3, W.White, x + ox, z + oz)
		disc("Sandbar", bar.r, 0.5, 2.5, W.Sand, x, z)
		disc("Sandbar", bar.r * 0.7, 0.3, 2.3, W.SandDark, x + ox, z + oz)
		for k = 1, bar.palms do
			local a = bar.turn + math.pi * (0.7 + k * 0.5)
			palm(parent, Vector3.new(x + math.cos(a) * bar.r * 0.35, 0.5, z + math.sin(a) * bar.r * 0.35), a + k, 16 + k * 3)
		end
	end

	-- Palm islands on the horizon (like World.Hub's far islands), most of them behind the
	-- court as seen from the lobby.
	local isles: { { x: number, z: number, r: number } } = {
		{ x = -480, z = -640, r = 55 },
		{ x = 430, z = -780, r = 62 },
		{ x = -840, z = 150, r = 46 },
		{ x = 780, z = 240, r = 44 },
		{ x = 140, z = 900, r = 52 },
	}
	for n, isle in isles do
		local x, z = cx + isle.x, cz + isle.z
		disc("FarShallows", isle.r + 16, OCEAN_TOP + 0.15, 0.2, W.Shallows, x, z)
		disc("FarIsland", isle.r, 1.4, 5, W.Sand, x, z)
		disc("FarHill", isle.r * 0.6, 3.4, 3, W.Grass, x, z)
		disc("FarHillTop", isle.r * 0.3, 5.4, 3, W.GrassDark, x, z)
		local spots = { { 0.82, 0.4, 1.4 }, { 0.78, 2.5, 1.4 }, { 0.45, 4.3, 3.4 }, { 0.15, 1.2, 5.4 } }
		for i, spot in spots do
			local a = n + spot[2]
			palm(
				parent,
				Vector3.new(x + math.cos(a) * isle.r * spot[1], spot[3], z + math.sin(a) * isle.r * spot[1]),
				a + i,
				24 + (i % 3) * 4
			)
		end
	end

	-- Horizon landmarks behind the court as seen from the lobby: a candy-striped lighthouse on a
	-- rocky islet (right), a tall palm cluster on its own islet (left) and a striped hot-air
	-- balloon over the sea.
	local lx, lz = cx + 170, cz - 230
	disc("LighthouseShallows", 34, OCEAN_TOP + 0.15, 0.2, W.Shallows, lx, lz)
	disc("LighthouseFoam", 24, OCEAN_TOP + 0.35, 0.3, W.White, lx, lz)
	disc("LighthouseIslet", 21, 1.2, 3, W.Sand, lx, lz)
	local rocks = { { -14, 6, 9 }, { 12, -9, 8 }, { -6, -15, 7 }, { 15, 9, 6 }, { -16, -6, 6 } }
	for _, r in rocks do
		deco(
			"LighthouseRock",
			Vector3.new(r[3], r[3], r[3]),
			CFrame.new(lx + r[1], 1, lz + r[2]),
			if r[3] > 7 then W.Steel else W.Slate,
			{ Shape = BALL }
		)
	end
	deco("LighthouseBase", Vector3.new(4, 16, 16), CFrame.new(lx, 3.2, lz) * UPRIGHT, W.White, { Shape = CYLINDER })
	local towerY = 5.2
	for i = 0, 5 do
		local dia = 12 - i * 0.7
		deco(
			"LighthouseStripe",
			Vector3.new(8, dia, dia),
			CFrame.new(lx, towerY + 4 + i * 8, lz) * UPRIGHT,
			if i % 2 == 0 then W.HotPink else W.White,
			{ Shape = CYLINDER }
		)
	end
	local galleryY = towerY + 48
	deco("LighthouseGallery", Vector3.new(1.2, 13, 13), CFrame.new(lx, galleryY + 0.6, lz) * UPRIGHT, W.Navy, { Shape = CYLINDER })
	deco(
		"LighthouseLamp",
		Vector3.new(5, 7, 7),
		CFrame.new(lx, galleryY + 3.7, lz) * UPRIGHT,
		W.Sunny,
		{ Shape = CYLINDER, Material = Enum.Material.Neon }
	)
	deco("LighthouseRoofRim", Vector3.new(1.2, 10, 10), CFrame.new(lx, galleryY + 6.8, lz) * UPRIGHT, W.HotPink, { Shape = CYLINDER })
	deco("LighthouseDome", Vector3.new(8, 8, 8), CFrame.new(lx, galleryY + 7.4, lz), W.HotPink, { Shape = BALL })
	deco("LighthouseTip", Vector3.new(2, 2, 2), CFrame.new(lx, galleryY + 11.8, lz), W.Sunny, { Shape = BALL })

	local px, pz = cx - 210, cz - 230
	disc("PalmIsleShallows", 50, OCEAN_TOP + 0.15, 0.2, W.Shallows, px, pz)
	disc("PalmIsleFoam", 38, OCEAN_TOP + 0.35, 0.3, W.White, px, pz)
	disc("PalmIsle", 35, 1.4, 3, W.Sand, px, pz)
	disc("PalmIsleHill", 20, 3, 3, W.Grass, px + 4, pz - 3)
	local cluster = { { 0, 0, 40 }, { 7, 5, 34 }, { -6, 6, 31 }, { 5, -7, 36 }, { -8, -4, 29 }, { 15, 1, 26 }, { -15, 8, 24 } }
	for i, t in cluster do
		palm(parent, Vector3.new(px + 4 + t[1], 2.4, pz - 3 + t[2]), i * 1.3, t[3])
	end

	local bx, by, bz = cx - 150, 100, cz - 300
	local envelope = Vector3.new(bx, by, bz)
	deco("BalloonEnvelope", Vector3.new(26, 26, 26), CFrame.new(envelope), W.HotPink, { Shape = BALL })
	for i, color in { W.Sunny, W.White, W.Sunny } do
		deco(
			"BalloonBand",
			Vector3.new(3.2, 26.2, 26.2),
			CFrame.new(envelope) * CFrame.Angles(0, math.rad(i * 60), 0),
			color,
			{ Shape = CYLINDER }
		)
	end
	deco("BalloonSkirt", Vector3.new(4, 9, 9), CFrame.new(envelope - Vector3.new(0, 13, 0)) * UPRIGHT, W.Sunny, { Shape = CYLINDER })
	for _, q in { { -1, -1 }, { 1, -1 }, { -1, 1 }, { 1, 1 } } do
		local top = envelope + Vector3.new(q[1] * 3.6, -14.5, q[2] * 3.6)
		local bottom = envelope + Vector3.new(q[1] * 2, -22, q[2] * 2)
		deco("BalloonRope", Vector3.new(0.3, 0.3, (top - bottom).Magnitude), CFrame.lookAt(top:Lerp(bottom, 0.5), bottom), W.WoodDark)
	end
	deco("BalloonBasket", Vector3.new(5, 4, 5), CFrame.new(envelope - Vector3.new(0, 24, 0)), W.Honey)
	deco("BalloonBasketRim", Vector3.new(5.4, 0.8, 5.4), CFrame.new(envelope - Vector3.new(0, 22.2, 0)), W.Coral)

	-- Puffy clouds high over the sea.
	local clouds = {
		{ -380, 200, -420, 1.4 },
		{ 340, 230, -560, 1.2 },
		{ 560, 180, 120, 1.3 },
		{ -600, 240, -80, 1.5 },
		{ -160, 260, 620, 1.2 },
		{ 420, 210, 520, 1.4 },
	}
	for _, c in clouds do
		cloud(parent, Vector3.new(cx + c[1], c[2], cz + c[3]), 40 * c[4], false)
	end
end

function ShakeArena.build(): Built
	-- The court (and World.Arena's shell) is COURT square on ARENA's centre; ARENA's own size
	-- also covers the lobby and the side decks.
	local arena = ShakeRules.ARENA
	local a: Arena.Spec = { x = arena.x, y = arena.y, z = arena.z, sizeX = COURT, sizeZ = COURT }
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
	local lineY = top + 0.08
	for _, s in { -1, 1 } do
		piece(decor, "CourtLine", Vector3.new(w + 0.6, 0.06, 0.6), CFrame.new(a.x, lineY, a.z + s * d / 2), W.White)
		piece(decor, "CourtLine", Vector3.new(0.6, 0.06, d + 0.6), CFrame.new(a.x + s * w / 2, lineY, a.z), W.White)
	end
	-- The coloured court: one teal plate with a soft light-teal checker and a deep-teal edge
	-- band drawn on its top (a SurfaceGui, no extra parts; calm under the landing rings), a
	-- wide hot-pink border band edged in white, then the drop-zone target in the middle and a
	-- catch ring in each quadrant.
	piece(decor, "CourtEdge", Vector3.new(w + 7, 0.02, d + 7), CFrame.new(a.x, top + 0.01, a.z), W.White)
	piece(decor, "CourtBorder", Vector3.new(w + 6, 0.02, d + 6), CFrame.new(a.x, top + 0.025, a.z), W.HotPink)
	local court = piece(decor, "CourtFloor", Vector3.new(w, 0.05, d), CFrame.new(a.x, top + 0.04, a.z), W.Teal)
	local gui = Instance.new("SurfaceGui")
	gui.Face = Enum.NormalId.Top
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 4
	gui.Parent = court
	local cells = 8
	for i = 0, cells - 1 do
		for j = 0, cells - 1 do
			if (i + j) % 2 == 0 then
				local cell = Instance.new("Frame")
				cell.BackgroundColor3 = W.TealLight
				cell.BorderSizePixel = 0
				cell.Position = UDim2.fromScale(i / cells, j / cells)
				cell.Size = UDim2.fromScale(1 / cells, 1 / cells)
				cell.Parent = gui
			end
		end
	end
	-- A deep-teal band round the play zone's edge (inside the white court line).
	local band = 2 / w
	local bandZ = 2 / d
	for _, e in { { 0, 0, 1, bandZ }, { 0, 1 - bandZ, 1, bandZ }, { 0, 0, band, 1 }, { 1 - band, 0, band, 1 } } do
		local f = Instance.new("Frame")
		f.Name = "PlayZoneEdge"
		f.BackgroundColor3 = W.TealDeep
		f.BorderSizePixel = 0
		f.Position = UDim2.fromScale(e[1], e[2])
		f.Size = UDim2.fromScale(e[3], e[4])
		f.ZIndex = 2
		f.Parent = gui
	end
	local function disc(at: Vector3, diameter: number, color: Color3, lift: number)
		piece(
			decor,
			"CourtDisc",
			Vector3.new(0.05, diameter, diameter),
			CFrame.new(at + Vector3.new(0, lift, 0)) * UPRIGHT,
			color,
			{ Shape = CYLINDER }
		)
	end
	local mid = Vector3.new(a.x, top, a.z)
	disc(mid, 20, W.White, 0.08)
	disc(mid, 17.6, W.HotPink, 0.11)
	disc(mid, 11, W.White, 0.14)
	disc(mid, 8.6, W.Orange, 0.17)
	disc(mid, 3.4, W.White, 0.20)
	for _, q in { { -1, -1 }, { 1, -1 }, { -1, 1 }, { 1, 1 } } do
		local at = mid + Vector3.new(q[1] * w / 4, 0, q[2] * d / 4)
		disc(at, 10, W.White, 0.08)
		disc(at, 8.2, if q[2] < 0 then W.Grape else W.Blue, 0.11)
		disc(at, 3, W.White, 0.14)
	end

	smoothieBar(decor, a, top)
	chute(decor, a, top)
	bleachers(decor, a, top)

	-- Side awnings with bunting (their inner valance stays outside every drop column).
	local length = 18
	for _, sx in { -1, 1 } do
		local x = a.x + sx * AWNING_X
		for _, sz in { -1, 1 } do
			awning(decor, Vector3.new(x, top, a.z + sz * 12), length, sx)
		end
		bunting(decor, Vector3.new(x - sx * 0.5, top + 9.6, a.z - 3), Vector3.new(x - sx * 0.5, top + 9.6, a.z + 3), 4)
	end

	-- The lobby past the +Z edge, the EXIT moved onto it, and the sea all round.
	local lobbyModel = Instance.new("Model")
	lobbyModel.Name = "Lobby"
	lobbyModel.Parent = folder
	local lobbyBuilt = lobby(lobbyModel, a, top)
	moveExit(folder, lobbyModel, Vector3.new(ShakeRules.EXIT.x, top, ShakeRules.EXIT.z), lobbyBuilt.lobbySpawn.Position)
	local sea = Instance.new("Model")
	sea.Name = "Surroundings"
	sea.Parent = folder
	surroundings(sea, a.x, a.z)

	local built: any = base
	built.catchArea = area
	built.dropY = top + 40
	built.items = items
	built.lobbySpawn = lobbyBuilt.lobbySpawn
	built.startPad = lobbyBuilt.startPad
	built.startRadius = START_RADIUS
	built.board = lobbyBuilt.board
	built.practiceArea = lobbyBuilt.practiceArea
	built.practiceDropY = lobbyBuilt.practiceDropY
	return built :: Built
end

return ShakeArena
