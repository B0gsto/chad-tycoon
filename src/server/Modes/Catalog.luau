--!strict
--[[
	Catalog: the game modes shown on the plaza, one per gate slot (pure data).

	World.Modes builds a gate per entry (locked "COMING SOON" when not enabled); Server.GameModes
	attaches the implementation of every enabled entry by id. To add a mode: give its entry
	`enabled = true`, write its module (see Modes.Parkour for the interface) and add it to
	GameModes' BUILTIN list.
]]

export type Entry = {
	id: string,
	title: string,
	blurb: string,
	slot: number,
	enabled: boolean,
	-- Theme.World colour key of the gate's sign header.
	color: string,
}

local Catalog: { Entry } = {
	{ id = "parkour", title = "PARKOUR", blurb = "Run, jump and bounce over the sea!", slot = 1, enabled = true, color = "Coral" },
	{ id = "soon2", title = "COMING SOON", blurb = "A new game mode is on its way!", slot = 2, enabled = false, color = "Steel" },
	{ id = "soon3", title = "COMING SOON", blurb = "A new game mode is on its way!", slot = 3, enabled = false, color = "Steel" },
}

return Catalog
