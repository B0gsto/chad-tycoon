--[[
	Brand: what the loading screen shows from its very first frame. It lives in
	ReplicatedFirst because ReplicatedStorage (Theme, Shared.Assets) only
	replicates near the end of the join, so without this the splash is a bare
	sky gradient for most of the load. The Theme and Assets still override it
	once they arrive; tests/run checks the two stay in sync.
]]

return {
	GameName = "Chad Aura Tycoon",
	Tagline = "Farm aura. Merge Chads. Mog the server.",
	KeyArt = "rbxassetid://71618244352821",
	Logo = "rbxassetid://128398060676282",
}
