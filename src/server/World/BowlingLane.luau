--!strict
--[[
	BowlingLane: the DUMBBELL BOWL arena out at sea (teleport-only; Modes.Bowling brings players here).
	Numbers live in Modes.BowlingRules.ARENA; the shell (floor, spawn pad, exit arch) comes from
	World.Arena. TODO(bowling builder): dress it (props, signs, fans) and add the game's parts.

	build() -> Built: everything World.Arena.Base has ({ folder, floor, spawn, exit,
	exitRadius, center, top }) plus
	lane       the lane slab ("BowlingLane", runs -Z from the foul line)
	rollStart  feet CFrame at the foul line, looking down the lane (-Z)
	pinSpots   10 CFrames (pin base centres) in the classic triangle at the far end, head pin first
	pins       empty Folder "Pins" for the pin parts (Modes.Bowling fills it)
]]

local Common = require(script.Parent.Common)
local Arena = require(script.Parent.Arena)
local BowlingRules = require(script.Parent.Parent.Modes.BowlingRules)

local W = Common.theme.World
local make = Common.make

local BowlingLane = {}

export type Built = Arena.Base & {
	lane: BasePart,
	rollStart: CFrame,
	pinSpots: { CFrame },
	pins: Folder,
}

function BowlingLane.build(): Built
	local a = BowlingRules.ARENA
	local base = Arena.base("bowling", "BowlingLane", a, { floor = "Cream", trim = "RedOrange" })
	local top = base.top
	local laneW, laneL = 14, a.sizeZ - 24
	local foulZ = a.z + a.sizeZ / 2 - 14
	local lane = make("Part", {
		Name = "BowlingLane",
		Size = Vector3.new(laneW, 0.2, laneL),
		CFrame = CFrame.new(a.x, top + 0.1, foulZ - laneL / 2),
		Color = W.Wood,
		Material = Enum.Material.WoodPlanks,
		Parent = base.folder,
	})
	for _, side in { -1, 1 } do
		make("Part", {
			Name = "BowlingGutter",
			Size = Vector3.new(2, 0.3, laneL),
			CFrame = CFrame.new(a.x + side * (laneW / 2 + 1), top + 0.15, foulZ - laneL / 2),
			Color = W.Steel,
			Parent = base.folder,
		})
	end
	make("Part", {
		Name = "FoulLine",
		Size = Vector3.new(laneW, 0.25, 0.6),
		CFrame = CFrame.new(a.x, top + 0.13, foulZ),
		Color = W.Coral,
		Parent = base.folder,
	})
	-- Pins: rows of 1-4 from the head pin, PIN_GAP studs apart.
	local PIN_GAP = 3
	local headZ = foulZ - laneL + 14
	local pinSpots = {}
	for row = 0, 3 do
		for i = 0, row do
			local x = a.x + (i - row / 2) * PIN_GAP
			table.insert(pinSpots, CFrame.new(x, top + 0.2, headZ - row * PIN_GAP * 0.87))
		end
	end
	local pins = Instance.new("Folder")
	pins.Name = "Pins"
	pins.Parent = base.folder
	local built: any = base
	built.lane = lane
	built.rollStart = CFrame.lookAt(Vector3.new(a.x, top, foulZ + 3), Vector3.new(a.x, top, foulZ - laneL))
	built.pinSpots = pinSpots
	built.pins = pins
	return built :: Built
end

return BowlingLane
