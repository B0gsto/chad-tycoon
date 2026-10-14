--!strict
--[[
	Arena: the shared shell of a solo mini-game arena (World.ShakeArena, World.PoseStage,
	World.BowlingLane; docs/minigames.md). Shared plumbing: mode builders do not edit it.

	base(id, name, arena, style) builds, in a Model `name` (attribute Mode = id) under the map
	folder, a floating deck out at sea:
	  "ArenaFloor"   the walkable slab, top at arena.y, arena.sizeX x arena.sizeZ, centred on
	                 (arena.x, arena.z); a white "ArenaRim" lip under it and four
	                 "ArenaPontoon" floats down to the sea.
	  "ArenaSpawn"   a sunny pad near the +Z edge where runs start (`spawn`: feet position,
	                 looking -Z across the arena).
	  "ArenaExit"    a glowing pad under an arch at the +Z edge's right corner; Modes.<Mode>
	                 ends the run when the player's feet come within `exitRadius` of it.
	Returns Base = { folder, floor, spawn, exit, exitRadius, center, top }.
]]

local Common = require(script.Parent.Common)

local W = Common.theme.World
local make = Common.make
local UPRIGHT = Common.UPRIGHT
local CYLINDER = Enum.PartType.Cylinder

local Arena = {}

export type Spec = { x: number, y: number, z: number, sizeX: number, sizeZ: number }

export type Base = {
	folder: Model,
	floor: BasePart,
	-- Feet position and facing of a run's start (GameModes.teleport(player, spawn.Position, spawn.LookVector)).
	spawn: CFrame,
	exit: BasePart,
	exitRadius: number,
	-- Floor top centre.
	center: Vector3,
	top: number,
}

-- style: { floor = Theme.World key of the deck, trim = key of the rim and arch }.
function Arena.base(id: string, name: string, arena: Spec, style: { floor: string, trim: string }): Base
	local folder = Instance.new("Model")
	folder.Name = name
	folder:SetAttribute("Mode", id)
	folder.Parent = Common.mapFolder
	local top = arena.y
	local floorColor: Color3 = (W :: any)[style.floor] or W.Cream
	local trim: Color3 = (W :: any)[style.trim] or W.White
	local floor = make("Part", {
		Name = "ArenaFloor",
		Size = Vector3.new(arena.sizeX, 2, arena.sizeZ),
		CFrame = CFrame.new(arena.x, top - 1, arena.z),
		Color = floorColor,
		Parent = folder,
	})
	make("Part", {
		Name = "ArenaRim",
		Size = Vector3.new(arena.sizeX + 2, 1.2, arena.sizeZ + 2),
		CFrame = CFrame.new(arena.x, top - 1.5, arena.z),
		Color = W.White,
		Parent = folder,
	})
	local floatH = math.max(top - 2, 1)
	for _, sx in { -1, 1 } do
		for _, sz in { -1, 1 } do
			make("Part", {
				Name = "ArenaPontoon",
				Shape = CYLINDER,
				Size = Vector3.new(floatH, 6, 6),
				CFrame = CFrame.new(arena.x + sx * (arena.sizeX / 2 - 4), floatH / 2, arena.z + sz * (arena.sizeZ / 2 - 4)) * UPRIGHT,
				Color = trim,
				Parent = folder,
			})
		end
	end
	local spawnZ = arena.z + arena.sizeZ / 2 - 6
	make("Part", {
		Name = "ArenaSpawn",
		Shape = CYLINDER,
		Size = Vector3.new(0.2, 7, 7),
		CFrame = CFrame.new(arena.x, top + 0.1, spawnZ) * UPRIGHT,
		Color = W.Sunny,
		CanCollide = false,
		Parent = folder,
	})
	local spawn = CFrame.lookAt(Vector3.new(arena.x, top, spawnZ), Vector3.new(arena.x, top, arena.z - arena.sizeZ))
	-- The exit: a mint pad under a small arch in the +X, +Z corner.
	local ex, ez = arena.x + arena.sizeX / 2 - 5, arena.z + arena.sizeZ / 2 - 5
	local exit = make("Part", {
		Name = "ArenaExit",
		Shape = CYLINDER,
		Size = Vector3.new(0.3, 6, 6),
		CFrame = CFrame.new(ex, top + 0.15, ez) * UPRIGHT,
		Color = W.Mint,
		Material = Enum.Material.Neon,
		CanCollide = false,
		Parent = folder,
	})
	for _, side in { -1, 1 } do
		make("Part", {
			Name = "ArenaExitPost",
			Shape = CYLINDER,
			Size = Vector3.new(8, 1, 1),
			CFrame = CFrame.new(ex + side * 3.5, top + 4, ez) * UPRIGHT,
			Color = trim,
			Parent = folder,
		})
	end
	local beam = make("Part", {
		Name = "ArenaExitSign",
		Size = Vector3.new(8, 1.8, 0.6),
		CFrame = CFrame.new(ex, top + 8.6, ez),
		Color = trim,
		Parent = folder,
	})
	local gui = Instance.new("SurfaceGui")
	gui.Face = Enum.NormalId.Front
	gui.PixelsPerStud = 40
	gui.Parent = beam
	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromScale(1, 1)
	label.Text = "EXIT"
	label.TextScaled = true
	label.Font = Common.theme.Fonts.Display
	label.TextColor3 = W.White
	label.Parent = gui
	return {
		folder = folder,
		floor = floor,
		spawn = spawn,
		exit = exit,
		exitRadius = 4,
		center = Vector3.new(arena.x, top, arena.z),
		top = top,
	}
end

return Arena
