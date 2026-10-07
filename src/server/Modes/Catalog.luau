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
	{ id = "mog", title = "MOG TEST", blurb = "Out-mog rivals or duel a real player!", slot = 2, enabled = true, color = "Grape" },
	{
		id = "cardio",
		title = "CARDIO",
		blurb = "Run the giant keyboard and get faster with every step!",
		slot = 3,
		enabled = true,
		color = "Mint",
	},
}

return Catalog
