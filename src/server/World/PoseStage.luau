--!strict
--[[
	PoseStage: the POSE COPY arena out at sea (teleport-only; Modes.Pose brings players here).
	Numbers live in Modes.PoseRules.ARENA; the shell (floor, spawn pad, exit arch) comes from
	World.Arena.

	A sunny posing show at the deck's -Z end: a raised stage with a sky-blue back wall and a
	"POSE COPY" banner, two podiums side by side (the rival's "CHAD" on the left, the
	player's "YOU" on the right as the audience sees them), both chads facing the audience
	(+Z, toward the spawn). Over them a D-pad of four "FlexLamp<i>" tiles in the flexes'
	colours (PoseRules.FLEXES; Fx.Pose lights the one being shown), "PodiumGlow" rings that
	Fx.Pose tints, two spotlight towers, a pink runway from the spawn to the stage steps and
	a judges' table on the left with three "10" cards.

	build() -> Built: everything World.Arena.Base has ({ folder, floor, spawn, exit,
	exitRadius, center, top }) plus
	playerSpot feet CFrame on the player's podium, facing the audience
	rivalSpot  feet CFrame on the rival's podium, facing the audience
	rival      empty Model "Rival" (the rival rig is built on each client by Fx.Pose, so
	           every player sees their own rival's show)
]]

local Common = require(script.Parent.Common)
local Arena = require(script.Parent.Arena)
local PoseRules = require(script.Parent.Parent.Modes.PoseRules)

local W = Common.theme.World
local make = Common.make
local UPRIGHT = Common.UPRIGHT
local CYLINDER = Enum.PartType.Cylinder

-- Stage layout (studs, from the arena centre): deck depth span and height, podium spread.
local STAGE = {
	Front = -4, -- deck front edge, z offset from the centre
	Back = -22, -- deck back edge
	HalfW = 22,
	Height = 1.2,
	PodiumX = 7, -- each podium's x offset
	PodiumZ = -12,
	PodiumD = 7,
	PodiumH = 1.4,
	WallH = 19,
}

local PoseStage = {}

export type Built = Arena.Base & {
	playerSpot: CFrame,
	rivalSpot: CFrame,
	rival: Model,
}

local function sign(part: BasePart, face: Enum.NormalId, text: string, color: Color3, ppu: number?)
	local gui = Instance.new("SurfaceGui")
	gui.Face = face
	gui.PixelsPerStud = ppu or 40
	gui.LightInfluence = 0
	gui.Parent = part
	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromScale(1, 1)
	label.Text = text
	label.TextScaled = true
	label.Font = Common.theme.Fonts.Display
	label.TextColor3 = color
	label.Parent = gui
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 3
	stroke.Color = W.Ink
	stroke.Transparency = 0.35
	stroke.Parent = label
end

function PoseStage.build(): Built
	local a = PoseRules.ARENA
	local base = Arena.base("pose", "PoseStage", a, { floor = "Cream", trim = "Blue" })
	local folder = base.folder
	local top = base.top
	local cx, cz = a.x, a.z
	local deckTop = top + STAGE.Height
	local depth = STAGE.Front - STAGE.Back
	local midZ = cz + (STAGE.Front + STAGE.Back) / 2

	local function box(name: string, size: Vector3, cf: CFrame, color: Color3, material: Enum.Material?): BasePart
		return make("Part", {
			Name = name,
			Size = size,
			CFrame = cf,
			Color = color,
			Material = material or Enum.Material.SmoothPlastic,
			Parent = folder,
		})
	end
	local function disc(name: string, diameter: number, height: number, pos: Vector3, color: Color3, material: Enum.Material?): BasePart
		return make("Part", {
			Name = name,
			Shape = CYLINDER,
			Size = Vector3.new(height, diameter, diameter),
			CFrame = CFrame.new(pos) * UPRIGHT,
			Color = color,
			Material = material or Enum.Material.SmoothPlastic,
			Parent = folder,
		})
	end

	-- Stage deck: white body, a blue top, a glowing front strip and three steps to the runway.
	box("StageDeck", Vector3.new(STAGE.HalfW * 2, STAGE.Height, depth), CFrame.new(cx, top + STAGE.Height / 2, midZ), W.White)
	box("StageTop", Vector3.new(STAGE.HalfW * 2 - 1, 0.1, depth - 1), CFrame.new(cx, deckTop + 0.05, midZ - 0.5), W.SkyBlue)
	box(
		"StageEdge",
		Vector3.new(STAGE.HalfW * 2, 0.3, 0.3),
		CFrame.new(cx, deckTop - 0.25, cz + STAGE.Front + 0.05),
		W.Sunny,
		Enum.Material.Neon
	)
	for i = 1, 2 do
		local h = STAGE.Height * i / 3
		box("StageStep", Vector3.new(8, h, 1.4), CFrame.new(cx, top + h / 2, cz + STAGE.Front + 1.4 * (3 - i) - 0.7), W.Cream)
	end
	-- Runway from the spawn to the steps.
	local runFrom, runTo = cz + STAGE.Front + 2.8, cz + a.sizeZ / 2 - 10
	box("Runway", Vector3.new(6, 0.12, runTo - runFrom), CFrame.new(cx, top + 0.06, (runFrom + runTo) / 2), W.HotPink)
	for _, side in { -1, 1 } do
		box("RunwayEdge", Vector3.new(0.3, 0.16, runTo - runFrom), CFrame.new(cx + side * 3.15, top + 0.08, (runFrom + runTo) / 2), W.White)
	end

	-- Back wall with a framed banner on top.
	local wallZ = cz + STAGE.Back + 0.6
	box("StageWall", Vector3.new(STAGE.HalfW * 2, STAGE.WallH, 1), CFrame.new(cx, deckTop + STAGE.WallH / 2, wallZ), W.SkyBlue)
	box("StageWallFrame", Vector3.new(STAGE.HalfW * 2 + 1.2, 1.2, 1.4), CFrame.new(cx, deckTop + STAGE.WallH, wallZ), W.Blue)
	for _, side in { -1, 1 } do
		box(
			"StageWallFrame",
			Vector3.new(1.2, STAGE.WallH, 1.4),
			CFrame.new(cx + side * (STAGE.HalfW + 0.1), deckTop + STAGE.WallH / 2, wallZ),
			W.Blue
		)
	end
	local banner = box("PoseBanner", Vector3.new(26, 4.6, 0.6), CFrame.new(cx, deckTop + STAGE.WallH - 3.2, wallZ + 0.8), W.HotPink)
	sign(banner, Enum.NormalId.Front, "POSE COPY", W.White)
	box("PoseBannerTrim", Vector3.new(27, 0.4, 0.7), CFrame.new(cx, deckTop + STAGE.WallH - 5.6, wallZ + 0.8), W.Sunny, Enum.Material.Neon)

	-- The flex lamps: a D-pad of four tiles between the chads (up, left, right, down).
	local padY = deckTop + 9.4
	local padZ = wallZ + 0.7
	local offsets: { [string]: Vector2 } = {
		Up = Vector2.new(0, 1),
		Left = Vector2.new(-1, 0),
		Right = Vector2.new(1, 0),
		Down = Vector2.new(0, -1),
	}
	box("FlexPadBack", Vector3.new(9.6, 9.6, 0.4), CFrame.new(cx, padY, padZ - 0.3) * CFrame.Angles(0, 0, math.rad(45)), W.Navy)
	for i, flex in PoseRules.FLEXES do
		local o = offsets[flex.dir] or Vector2.zero
		local lamp = box(
			"FlexLamp" .. i,
			Vector3.new(2.6, 2.6, 0.5),
			CFrame.new(cx + o.X * 2.7, padY + o.Y * 2.7, padZ) * CFrame.Angles(0, 0, math.rad(45)),
			Color3.fromRGB(flex.rgb[1], flex.rgb[2], flex.rgb[3])
		)
		lamp:SetAttribute("Flex", i)
		lamp.Transparency = 0.15
	end

	-- Podiums: rival on the audience's left (-X), the player on the right (+X).
	local facing = Vector3.new(0, 0, 1)
	local podiumZ = cz + STAGE.PodiumZ
	local feetY = deckTop + STAGE.PodiumH
	local rivalPos = Vector3.new(cx - STAGE.PodiumX, feetY, podiumZ)
	local playerPos = Vector3.new(cx + STAGE.PodiumX, feetY, podiumZ)
	local podiums = {
		{ pos = rivalPos, color = W.Grape, name = "RivalPad", text = "CHAD" },
		{ pos = playerPos, color = W.Sunny, name = "PlayerPad", text = "YOU" },
	}
	for _, pod in podiums do
		local p = pod.pos
		disc(pod.name, STAGE.PodiumD, STAGE.PodiumH, Vector3.new(p.X, deckTop + STAGE.PodiumH / 2, p.Z), pod.color)
		local glow =
			disc("PodiumGlow", STAGE.PodiumD + 0.6, 0.25, Vector3.new(p.X, deckTop + STAGE.PodiumH - 0.3, p.Z), W.White, Enum.Material.Neon)
		glow:SetAttribute("Side", if pod.name == "RivalPad" then "rival" else "player")
		local plate = box("PodiumPlate", Vector3.new(4, 1, 0.2), CFrame.new(p.X, deckTop + 0.7, p.Z + STAGE.PodiumD / 2 + 0.05), W.White)
		plate.CanCollide = false
		sign(plate, Enum.NormalId.Front, pod.text, pod.color)
	end

	-- Spotlight towers at the stage's front corners, aimed at the podiums.
	for _, side in { -1, 1 } do
		local x = cx + side * (STAGE.HalfW + 2.5)
		local z = cz + STAGE.Front - 1
		local h = 15
		disc("SpotBase", 3, 0.6, Vector3.new(x, top + 0.3, z), W.Navy)
		box("SpotTower", Vector3.new(0.8, h, 0.8), CFrame.new(x, top + h / 2, z), W.Steel)
		local target = (if side < 0 then rivalPos else playerPos) + Vector3.new(0, 3, 0)
		local headPos = Vector3.new(x, top + h + 0.6, z)
		local head = make("Part", {
			Name = "SpotHead",
			Shape = CYLINDER,
			Size = Vector3.new(2.2, 2, 2),
			-- A cylinder's axis is its X: point it from the head at the podium.
			CFrame = CFrame.lookAt(headPos, target) * CFrame.Angles(0, math.rad(90), 0),
			Color = W.Navy,
			Parent = folder,
		})
		local lens = make("Part", {
			Name = "SpotLens",
			Shape = CYLINDER,
			Size = Vector3.new(0.2, 1.7, 1.7),
			CFrame = CFrame.lookAt(headPos + (target - headPos).Unit * 1.15, target) * CFrame.Angles(0, math.rad(90), 0),
			Color = Color3.fromRGB(255, 244, 200),
			Material = Enum.Material.Neon,
			CanCollide = false,
			Parent = folder,
		})
		local light = Instance.new("SpotLight")
		light.Face = Enum.NormalId.Right
		light.Angle = 40
		light.Range = 30
		light.Brightness = 2.5
		light.Color = Color3.fromRGB(255, 240, 210)
		light.Parent = lens
		head.CanCollide = false
	end

	-- Judges' table on the audience's left, angled at the stage, with three "10" cards.
	local judge = CFrame.new(cx - 16, top, cz + 10) * CFrame.Angles(0, math.rad(-25), 0)
	box("JudgeTable", Vector3.new(11, 0.4, 3), judge * CFrame.new(0, 2.8, 0), W.White)
	box("JudgeSkirt", Vector3.new(11, 2.6, 0.3), judge * CFrame.new(0, 1.3, -1.35), W.Blue)
	for _, dx in { -5.2, 5.2 } do
		box("JudgeLeg", Vector3.new(0.4, 2.6, 2.6), judge * CFrame.new(dx, 1.3, 0), W.Blue)
	end
	local judgeSign = box("JudgeSign", Vector3.new(6, 1.2, 0.2), judge * CFrame.new(0, 1.6, -1.55), W.Sunny)
	sign(judgeSign, Enum.NormalId.Front, "JUDGES", W.White)
	for i = -1, 1 do
		local seat = judge * CFrame.new(i * 3.4, 0, 2.6)
		box("JudgeChair", Vector3.new(2.2, 0.4, 2.2), seat * CFrame.new(0, 1.9, 0), W.Coral)
		box("JudgeChairBack", Vector3.new(2.2, 2.6, 0.3), seat * CFrame.new(0, 3.2, 1.0), W.Coral)
		box("JudgeChairLeg", Vector3.new(0.4, 1.7, 0.4), seat * CFrame.new(0, 0.85, 0), W.Steel)
		local card =
			box("ScoreCard", Vector3.new(1.6, 1.4, 0.15), seat * CFrame.new(0, 3.85, -2.4) * CFrame.Angles(math.rad(-12), 0, 0), W.White)
		card.CanCollide = false
		sign(card, Enum.NormalId.Front, "10", W.HotPink)
	end

	-- A few beach balls and pom-pom flowers around the deck for colour.
	local props = {
		{ Vector3.new(cx + 20, top, cz + 12), W.Pink },
		{ Vector3.new(cx + 22, top, cz - 1), W.Mint },
		{ Vector3.new(cx - 22, top, cz - 1), W.Sunny },
	}
	for _, prop in props do
		local p, color = prop[1], prop[2]
		make("Part", {
			Name = "BeachBall",
			Shape = Enum.PartType.Ball,
			Size = Vector3.one * 2.4,
			CFrame = CFrame.new(p + Vector3.new(0, 1.2, 0)),
			Color = color,
			Parent = folder,
		})
	end

	local rival = Instance.new("Model")
	rival.Name = "Rival"
	rival.Parent = folder
	local built: any = base
	built.playerSpot = CFrame.lookAt(playerPos, playerPos + facing)
	built.rivalSpot = CFrame.lookAt(rivalPos, rivalPos + facing)
	built.rival = rival
	return built :: Built
end

return PoseStage
