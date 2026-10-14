--!strict
--[[
	ShakeArena: the SHAKE CATCH arena out at sea (teleport-only; Modes.Shake brings players here).
	Numbers live in Modes.ShakeRules.ARENA; the shell (floor, spawn pad, exit arch) comes from
	World.Arena. TODO(shake builder): dress it (props, signs, fans) and add the game's parts.

	build() -> Built: everything World.Arena.Base has ({ folder, floor, spawn, exit,
	exitRadius, center, top }) plus
	catchArea  floor rectangle (world x0, x1, z0, z1) where shakes and junk food may land
	dropY      height falling items spawn at
	items      empty Folder "Items" for the falling props (Modes.Shake / Fx.Shake fill it)
]]

local Arena = require(script.Parent.Arena)
local ShakeRules = require(script.Parent.Parent.Modes.ShakeRules)

local ShakeArena = {}

export type Built = Arena.Base & {
	catchArea: { x0: number, x1: number, z0: number, z1: number },
	dropY: number,
	items: Folder,
}

function ShakeArena.build(): Built
	local a = ShakeRules.ARENA
	local base = Arena.base("shake", "ShakeArena", a, { floor = "Cream", trim = "Pink" })
	local inset = 4
	local items = Instance.new("Folder")
	items.Name = "Items"
	items.Parent = base.folder
	local built: any = base
	built.catchArea = {
		x0 = a.x - a.sizeX / 2 + inset,
		x1 = a.x + a.sizeX / 2 - inset,
		z0 = a.z - a.sizeZ / 2 + inset,
		z1 = a.z + a.sizeZ / 2 - inset,
	}
	built.dropY = base.top + 40
	built.items = items
	return built :: Built
end

return ShakeArena
