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
	KeyArt = "rbxassetid://104998274435310",
	Logo = "rbxassetid://128398060676282",
	LogoShine = "rbxassetid://110172388449160",
	SoftDot = "rbxassetid://105240966552716",
	Sparkle = "rbxassetid://130168407424147",
	Orb = { image = "rbxassetid://110910493203649", x = 204, y = 816, w = 204, h = 204 },
	Loading = { Status = "Warming up the gym..." },
}
