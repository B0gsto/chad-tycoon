--[[
	Unit tests for the plot's visible progress (src/client/Fx/PlotRank.luau): the plot rank
	steps, the own plot's fan count and extra standing spots (checked against the server's
	fan zones), the rack units' sizes (checked against the rack's real head room), the dressing
	built on the roof, the fences and the entrance pillars, the champion's stage in front of
	its pedestal, and the home shot that keeps the roof dressing in the spawn frame. PlotRank is loaded with
	@lune/roblox datatypes and stub services, so its parts are real instances.
	Loaded by tests/run.luau with its harness: { test, check, eq }. Run alone with
	`lune run tests/plot_rank` it uses the small harness at the end of this file.
]]

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local process = require("@lune/process")
local roblox = require("@lune/roblox")
local task = require("@lune/task")

local Economy = require("../src/shared/Economy")
local Layout = require("../src/server/PlotLayout")

local Instance = roblox.Instance
local Vector3 = roblox.Vector3
local CFrame = roblox.CFrame

local function robloxEnv(): { [string]: any }
	local env: { [string]: any } = setmetatable({}, { __index = _G }) :: any
	for _, name in
		{
			"Instance",
			"Vector3",
			"Vector2",
			"CFrame",
			"Color3",
			"Enum",
			"ColorSequence",
			"NumberSequence",
			"NumberSequenceKeypoint",
			"NumberRange",
			"UDim",
			"UDim2",
		}
	do
		env[name] = (roblox :: any)[name]
	end
	return env
end

local function loadTheme(): any
	local path = "src/themes/chad/Theme.luau"
	return luau.load(fs.readFile(path), { debugName = path, environment = robloxEnv() })()
end

-- PlotRank with the real Economy and Theme, a "high" (or "low") effects budget and no engine.
local function loadPlotRank(theme: any, low: boolean): any
	local path = "src/client/Fx/PlotRank.luau"
	local shared = {
		WaitForChild = function(_, name: string)
			return ({ Economy = Economy })[name]
		end,
	}
	local services = {
		ReplicatedStorage = {
			WaitForChild = function(_, name: string)
				return if name == "Theme" then theme else shared
			end,
		},
		RunService = {},
		TweenService = {},
		Workspace = {},
	}
	local budget = {
		low = function()
			return low
		end,
		count = function(n: number)
			return if low then math.max(1, math.floor(n * 0.4 + 0.5)) else n
		end,
	}
	local env = robloxEnv()
	env.game = {
		GetService = function(_, name: string)
			return services[name]
		end,
	}
	env.script = { Parent = { Budget = budget, Parent = { State = { data = nil } } } }
	env.require = function(module: any): any
		return module
	end
	return luau.load(fs.readFile(path), { debugName = path, environment = env })()
end

local function baseParts(root: any): { any }
	local out = {}
	for _, d in root:GetDescendants() do
		if d:IsA("BasePart") then
			table.insert(out, d)
		end
	end
	return out
end

local function named(root: any, name: string): { any }
	local out = {}
	for _, d in root:GetDescendants() do
		if d.Name == name then
			table.insert(out, d)
		end
	end
	return out
end

-- The rack roof as World.Shelves builds it over shelf 1, at the origin: its top centre and size.
local function roof(): (any, any)
	local s = Layout.SHELF
	local size = Vector3.new(s.width + s.postWidth * 2 + 0.6, s.boardThick, s.depth + 0.4 + 0.6)
	return CFrame.new(0, Layout.rowTop(2), Layout.rowFrontZ(1) - 0.3 + size.Z / 2), size
end

-- CFrames are stored in single precision: compare with a little slack.
local function sameFrame(a: any, b: any): boolean
	return (a.Position - b.Position).Magnitude < 1e-3 and a.LookVector:Dot(b.LookVector) > 0.9999 and a.UpVector:Dot(b.UpVector) > 0.9999
end

local ran = false

local function suite(h: { [string]: any })
	ran = true
	local test, check, eq = h.test, h.check, h.eq
	local theme = loadTheme()
	local PlotRank = loadPlotRank(theme, false)
	local CFG = PlotRank.CFG

	test("PlotRank: a rank step every five tiers", function()
		eq(#CFG.RankTiers, #CFG.Features, "one piece of dressing per rank")
		eq(PlotRank.rank(0), 0, "an unclaimed plot has no rank")
		eq(PlotRank.rank(4), 0, "tier 4")
		eq(PlotRank.rank(5), 1, "tier 5")
		eq(PlotRank.rank(9), 1, "tier 9")
		eq(PlotRank.rank(10), 2, "tier 10")
		eq(PlotRank.rank(15), 3, "tier 15")
		eq(PlotRank.rank(20), 4, "tier 20")
		eq(PlotRank.rank(24), 4, "tier 24")
		eq(PlotRank.rank(Economy.MAX_TIER), 5, "the top tier has every step")
		eq(table.concat(PlotRank.features(4), ","), "", "nothing before tier 5")
		eq(table.concat(PlotRank.features(17), ","), "Pennants,GoldTrim,Trophies", "tier 17 keeps the earlier steps")
		eq(table.concat(PlotRank.features(25), ","), "Pennants,GoldTrim,Trophies,NeonSign,CrownBeam", "tier 25")
		local previous = 0
		for tier = 1, Economy.MAX_TIER do
			check(PlotRank.rank(tier) >= previous, "the rank never drops as the best tier rises")
			previous = PlotRank.rank(tier)
		end
	end)

	test("PlotRank: the best tier standing on the rack", function()
		local function plot(tiers: { number }?): any
			local units = {}
			for _, tier in tiers or {} do
				table.insert(units, {
					GetAttribute = function(_, name)
						return if name == "Tier" then tier else nil
					end,
				})
			end
			return {
				FindFirstChild = function(_, name)
					if name == "Units" and tiers then
						return {
							GetChildren = function()
								return units
							end,
						}
					end
					return nil
				end,
			}
		end
		eq(PlotRank.bestTier(plot(nil)), 0, "a free plot")
		eq(PlotRank.bestTier(plot({})), 0, "an empty rack")
		eq(PlotRank.bestTier(plot({ 3, 7, 5 })), 7, "the best unit")
		eq(PlotRank.rank(PlotRank.bestTier(plot({ 20, 1 }))), 4, "which is what the dressing goes by")
	end)

	test("PlotRank: fans on the own plot", function()
		local fans = theme.Fans
		eq(PlotRank.ownFans(0, fans.Base, fans.PerTier, CFG.OwnFansMax), 0, "no units, no fans")
		eq(PlotRank.ownFans(Economy.MAX_TIER, fans.Base, fans.PerTier, CFG.OwnFansMax), 20, "20 fans at the top tier")
		eq(PlotRank.ownFans(Economy.MAX_TIER, fans.Base, fans.PerTier, fans.Max), fans.Max, "a low device keeps Theme.Fans.Max")
		local previous = 0
		for tier = 1, Economy.MAX_TIER do
			local own = PlotRank.ownFans(tier, fans.Base, fans.PerTier, CFG.OwnFansMax)
			local before = math.clamp(fans.Base + math.floor(tier * fans.PerTier), 1, fans.Max)
			check(own >= previous, "tier " .. tier .. ": the crowd never shrinks as the best tier rises")
			check(own >= before, "tier " .. tier .. ": never fewer fans than before")
			check(own <= CFG.OwnFansMax, "tier " .. tier .. ": at most OwnFansMax")
			previous = own
		end
		check(
			PlotRank.ownFans(5, fans.Base, fans.PerTier, 99) > PlotRank.ownFans(4, fans.Base, fans.PerTier, 99),
			"a rank step brings a fan"
		)
	end)

	test("PlotRank: extra standing spots fit the fan zones", function()
		local spots = {}
		for i, spot in Layout.fanSpots() do
			local backZ = spot.z
			for _, zone in Layout.FAN_ZONES do
				if Layout.contains(zone.rect, spot.x, spot.z) then
					backZ = zone.rect.maxZ + 0.5
				end
			end
			spots[i] = {
				pos = Vector3.new(spot.x, 0, spot.z),
				look = Vector3.new(spot.faceX, 0, spot.faceZ),
				entrance = Vector3.new(spot.x, 0, backZ),
				order = i,
			}
		end
		check(#spots < CFG.OwnFansMax, "the server builds fewer spots than the own crowd needs")
		local need = CFG.OwnFansMax - #spots
		local extra = PlotRank.extraSpots(spots, need)
		eq(#extra, need, "every fan of the biggest crowd has a spot")
		eq(#PlotRank.extraSpots(spots, 0), 0, "none asked, none made")
		local sides = 0
		for i, spot in extra do
			eq(spot.order, #spots + i, "extra spots fill after the server's")
			local inZone = false
			for _, zone in Layout.FAN_ZONES do
				inZone = inZone or Layout.contains(zone.rect, spot.pos.X, spot.pos.Z)
			end
			check(inZone, "extra spot " .. i .. " stands in a fan zone")
			for _, other in spots do
				check((other.pos - spot.pos).Magnitude >= 2.5, "extra spot " .. i .. " is clear of the server's spots")
			end
			for j = i + 1, #extra do
				check((extra[j].pos - spot.pos).Magnitude >= 2.5, "extra spots are clear of each other")
			end
			local toFocus = Vector3.new(Layout.FAN_FOCUS.x - spot.pos.X, 0, Layout.FAN_FOCUS.z - spot.pos.Z)
			check(spot.look:Dot(toFocus) > 0, "extra spot " .. i .. " faces the display")
			check(math.abs(spot.look.Magnitude - 1) < 1e-4, "its facing is a unit vector")
			check(spot.entrance ~= nil and spot.entrance.Z > spot.pos.Z, "its fan joins from the back of the zone")
			sides += if spot.pos.X > 0 then 1 else -1
		end
		eq(sides, 0, "both zones get the same number")
		local again = PlotRank.extraSpots(spots, need)
		for i, spot in extra do
			check((again[i].pos - spot.pos).Magnitude < 1e-6, "the same spots every scan")
		end
	end)

	test("PlotRank: rarity rings by band", function()
		eq(PlotRank.bandIndex(1), 1, "tier 1 is Common")
		eq(PlotRank.bandIndex(Economy.MAX_TIER), #Economy.TIER_BANDS, "the top tier is the top band")
		eq(#CFG.RingAlpha, #Economy.TIER_BANDS, "a ring look per band")
		local previous = 1
		for tier = 1, Economy.MAX_TIER do
			local alpha, material = PlotRank.ringLook(tier)
			check(alpha <= previous, "tier " .. tier .. ": a rarer ring is never fainter")
			previous = alpha
			eq(
				material.Name,
				if PlotRank.bandIndex(tier) >= CFG.RingNeonBand then "Neon" else "SmoothPlastic",
				"tier " .. tier .. " ring material"
			)
			eq(PlotRank.bandColor(tier), theme.Colors.Rarity[Economy.tierBand(tier)], "tier " .. tier .. " ring colour")
		end
		eq(previous, 0, "the Mythic ring is solid")
	end)

	test("PlotRank: rack unit sizes fit the rack", function()
		local s = Layout.SHELF
		eq(CFG.FrontSlots, s.rowCols[1], "FrontSlots is the front shelf's slot count")
		local best, second = PlotRank.topTiers({ 3, 24, 2, 24, 22, 7 })
		eq(best, 24, "best tier")
		eq(second, 22, "second-best tier")
		best, second = PlotRank.topTiers({ 4, 4 })
		eq(second, 4, "one tier only: it is both")
		eq(PlotRank.wantScale(24, 1, 24, 22), CFG.StarScale, "the best tier is big")
		eq(PlotRank.wantScale(22, 40, 24, 22), CFG.StarScale, "the second-best tier is big on any shelf")
		eq(PlotRank.wantScale(21, 5, 24, 22), 1, "the rest are as built")
		eq(PlotRank.wantScale(2, 40, 24, 22), CFG.LowScale, "low tiers behind the front shelf are small")
		eq(PlotRank.wantScale(2, CFG.FrontSlots, 24, 22), 1, "a low tier on the front shelf keeps its size")
		eq(PlotRank.wantScale(24 - CFG.LowGap + 1, 40, 24, 22), 1, "a tier near the best keeps its size")
		eq(PlotRank.wantScale(1, 40, 3, 2), 1, "an early rack has no low tiers")

		-- Head room under the board above: the champion on its pedestal, the rest of the
		-- front shelf, and every shelf behind it.
		local height = s.unitMaxHeight
		local front = Layout.rowTop(2) - s.boardThick - Layout.rowTop(1)
		local champion = front - s.championRise
		local behind = s.rowRise - s.boardThick
		local championScale = PlotRank.fitScale(CFG.StarScale, height, champion, nil)
		for _, room in { front, champion, behind } do
			local scale = PlotRank.fitScale(CFG.StarScale, height, room, championScale)
			check(scale >= 1 and scale <= CFG.StarScale, "a star unit is drawn between 1x and StarScale")
			check(scale * height + CFG.HeadGap <= room + 0.01 or scale == 1, "a scaled unit stays under the board above")
			check(scale <= championScale, "no unit is drawn bigger than the champion")
		end
		eq(PlotRank.fitScale(CFG.StarScale, height, nil, nil), CFG.StarScale, "open sky: the full size")
		eq(PlotRank.fitScale(CFG.StarScale, height, height - 1, nil), 1, "a unit never shrinks to fit")
		eq(PlotRank.fitScale(CFG.LowScale, height, behind, championScale), CFG.LowScale, "a small unit always fits")
		eq(PlotRank.fitScale(1, height, behind, championScale), 1, "an as-built unit is left alone")
		check(CFG.LowScale < 1 and CFG.StarScale > 1, "small is under 1x, big over")
	end)

	test("PlotRank: the dressing stands on the roof", function()
		local top, size = roof()
		local s = Layout.SHELF
		local counts = {}
		for rank = 0, #CFG.Features do
			local parent = Instance.new("Folder")
			local features = PlotRank.dress(rank, top, size, parent)
			local n = 0
			for name, feature in features do
				n += 1
				check(table.find(CFG.Features, name) ~= nil and table.find(CFG.Features, name) <= rank, name .. " belongs to rank " .. rank)
				check(feature.roof ~= nil and feature.roof.PrimaryPart ~= nil, name .. " has a roof model with a pivot part")
				check(sameFrame(feature.roof.PrimaryPart.CFrame, top), name .. " pivots on the roof's top centre")
			end
			eq(n, rank, "rank " .. rank .. " shows " .. rank .. " pieces")
			local parts = baseParts(parent)
			counts[rank] = #parts
			for _, part in parts do
				check(
					part.Anchored == true and part.CanCollide == false and part.CanQuery == false,
					part.Name .. " is anchored and never blocks the player or the camera"
				)
				local at = top:PointToObjectSpace(part.CFrame.Position)
				check(math.abs(at.X) <= size.X / 2 + 1, part.Name .. " stays within the rack's width")
				if string.sub(part.Name, 1, 5) == "Crown" then
					-- The crown is wider than the roof is deep: it floats over the neon sign.
					check(at.Y > CFG.NeonSign.Y + CFG.NeonSign.Height / 2 - CFG.CrownBeam.Bob, part.Name .. " floats above the neon sign")
					check(math.abs(at.Z) <= CFG.CrownBeam.Diameter / 2 + 1.5, part.Name .. " stays round the crown's centre")
				else
					check(at.Y >= -1 and math.abs(at.Z) <= size.Z / 2 + 1, part.Name .. " stays over the roof, never in front of the units")
				end
				-- The server's "YOUR CHADS" marquee: 16 wide, from 6.4 to 10.3 above the roof.
				check(not (math.abs(at.X) < 8.3 and at.Y > 6.3 and at.Y < 10.4), part.Name .. " keeps clear of the marquee")
			end
			for _, d in parent:GetDescendants() do
				check(d.ClassName ~= "Highlight", "no Highlight instances (Fx.Crates needs the 31 Roblox draws)")
			end
		end
		eq(counts[0], 0, "an unranked plot is bare")
		for rank = 1, #CFG.Features do
			check(counts[rank] > counts[rank - 1], "rank " .. rank .. " adds parts")
		end
		check(counts[#CFG.Features] <= 260, "a fully dressed plot stays under 260 parts, got " .. counts[#CFG.Features])

		-- Pennants: every triangle hangs from the line, above the roof and below the mast tops.
		local parent = Instance.new("Folder")
		PlotRank.dress(1, top, size, parent)
		local pennants = named(parent, "Pennant")
		eq(#pennants, CFG.Pennants.Count * 2, "two triangles per pennant")
		for _, wedge in pennants do
			local half = wedge.Size / 2
			-- A wedge's three corners in its Y-Z plane: both bottom ones and the top back one.
			for _, corner in { Vector3.new(0, -half.Y, -half.Z), Vector3.new(0, -half.Y, half.Z), Vector3.new(0, half.Y, half.Z) } do
				local y = top:PointToObjectSpace(wedge.CFrame:PointToWorldSpace(corner)).Y
				check(y > 0.1 and y < CFG.Pennants.MastHeight, "a pennant corner is between the roof and the mast tops")
			end
		end
		eq(#named(parent, "PennantMast"), 2, "two masts")
		for _, mast in named(parent, "PennantMast") do
			local x = math.abs(top:PointToObjectSpace(mast.CFrame.Position).X)
			-- The roof's white corner knobs stand over the side posts.
			check(x < s.width / 2 - 1, "the masts stand inside the roof's corner knobs")
		end

		-- A "low" device gets less of everything, and no particles.
		local LowRank = loadPlotRank(theme, true)
		local lowParent = Instance.new("Folder")
		LowRank.dress(#CFG.Features, top, size, lowParent, true)
		check(#baseParts(lowParent) < counts[#CFG.Features], "a low device builds fewer parts")
		for _, d in lowParent:GetDescendants() do
			check(d.ClassName ~= "ParticleEmitter", "a low device gets no particles")
		end

		-- Gold collars go on the front shelf's posts, which stand on the floor.
		local post = Instance.new("Part")
		post.Size = Vector3.new(s.postWidth, 10, s.depth + 0.4)
		post.CFrame = CFrame.new(s.width / 2 + s.postWidth / 2, 5, Layout.rowFrontZ(1) + 2.2)
		local collared = Instance.new("Folder")
		local trim = PlotRank.dress(2, top, size, collared, false, { post }).GoldTrim
		eq(#named(trim.ground, "GoldCollar"), 2, "a collar near each end of a post")
		for _, collar in named(trim.ground, "GoldCollar") do
			local y = collar.CFrame.Position.Y
			check(y > 0 and y < 10, "a collar sits on its post")
		end

		-- Tier 10: a glowing gold tube along the top of every fence cap (World.Shell's FenceCap:
		-- a cylinder lying along the fence), and tier 15: a big cup on each entrance pillar.
		local caps, knobs = {}, {}
		for i, run in { CFrame.new(-51.2, 3.35, 0) * CFrame.Angles(0, math.pi / 2, 0), CFrame.new(20, 3.35, -51.2) } do
			local cap = Instance.new("Part")
			cap.Size = Vector3.new(9.4, 1.3, 1.3)
			cap.CFrame = run
			caps[i] = cap
		end
		for i, x in { -8.2, 8.2 } do
			local knob = Instance.new("Part")
			knob.Size = Vector3.new(3.4, 3.4, 3.4)
			knob.CFrame = CFrame.new(x, 12, -51.2)
			knobs[i] = knob
		end
		local postKnobs = {}
		for i = 1, 30 do
			local knob = Instance.new("Part")
			knob.Size = Vector3.new(1.5, 1.5, 1.5)
			knob.CFrame = CFrame.new(-51.2, 4.1, -40 + i * 2.5)
			postKnobs[i] = knob
		end
		local outlined = Instance.new("Folder")
		local dressed = PlotRank.dress(3, top, size, outlined, false, { post }, caps, knobs, postKnobs)
		local rails = named(dressed.GoldTrim.ground, "GoldRail")
		eq(#rails, #caps, "a gold tube on every fence cap")
		for i, rail in rails do
			eq(rail.Material.Name, "Neon", "the tube glows")
			check(rail.Size.X >= caps[i].Size.X, "it runs the cap's whole length")
			check(rail.Size.Y >= 0.6, "it is thick enough to see from the hub")
			local at = caps[i].CFrame:PointToObjectSpace(rail.CFrame.Position)
			check(math.abs(at.X) < 0.01 and math.abs(at.Z) < 0.01, "it lies along its cap")
			check(at.Y >= caps[i].Size.Y / 2, "on top of it, seen from both sides of the fence")
			check(rail.Color ~= theme.World.Sunny, "in a gold that stands out from the sunny cap")
		end
		local beads = named(dressed.GoldTrim.ground, "RailBead")
		eq(#beads, #postKnobs, "a gold bead on every fence post")
		local lit = 0
		for i, bead in beads do
			eq(bead.Material.Name, "Neon", "the bead glows")
			check(bead.CFrame.Position.Y > postKnobs[i].CFrame.Position.Y, "on top of its knob")
			if bead:FindFirstChildOfClass("PointLight") then
				lit += 1
			end
		end
		eq(lit, CFG.GoldTrim.PostLights, "lights in some of them, up to the cap")
		local early = Instance.new("Folder")
		PlotRank.dress(1, top, size, early, false, { post }, caps, knobs)
		eq(#named(early, "GoldRail"), 0, "no outline before tier 10")
		local pillarCups = named(dressed.Trophies.ground, "TrophyCup")
		eq(#pillarCups, #knobs, "a cup on each entrance pillar")
		for i, cup in pillarCups do
			check(cup.CFrame.Position.Y > knobs[i].CFrame.Position.Y + knobs[i].Size.Y / 2, "it stands on top of the pillar's knob")
			check(cup.Size.Y >= 2.5, "it is a big cup")
			check(2.1 * CFG.Trophies.Pillar >= 6, "about 6 studs tall")
		end
		eq(#named(dressed.Trophies.ground, "PillarRing"), #knobs, "each on a glowing ring")
		eq(#named(early, "PillarRing"), 0, "not before tier 15")
		-- And a big gold cup on each end of the roof.
		local big = 0
		for _, cup in named(dressed.Trophies.roof, "TrophyCup") do
			if cup.Size.Y >= CFG.Trophies.Big then
				big += 1
				check(math.abs(top:PointToObjectSpace(cup.CFrame.Position).X) > s.width / 2 - 2, "a big cup stands over a side post")
			end
		end
		eq(big, 2, "a big cup on each end of the roof")

		-- The crown turns about its own centre, over the neon sign.
		local crowned = Instance.new("Folder")
		local crown = PlotRank.dress(5, top, size, crowned).CrownBeam
		check(crown.spin ~= nil and crown.spinAt ~= nil, "the crown is a model of its own")
		check(sameFrame(crown.spin.PrimaryPart.CFrame, top * crown.spinAt), "it pivots where it spins")
		eq(#named(crown.spin, "CrownPoint"), CFG.CrownBeam.Points * 2, "two triangles per crown point")
		check(CFG.CrownBeam.Diameter >= 18, "the crown is three times the old 6-stud one")
		eq(#named(crowned, "CrownLight"), 1, "a shaft of light that faces the camera")
		check(named(crowned, "CrownLight")[1].Width0 >= 12, "which is wide enough to read from the hub")
		eq(#named(crowned, "ShaftSparkles"), 1, "sparkles drift up the shaft")
		eq(#named(crowned, "FireworkBurst"), 1, "and fireworks burst over the crown")
		check(type(crown.start) == "function", "which its start sets going")
		eq(#named(crown.spin, "CrownRay"), CFG.CrownBeam.Rays, "sheets of light that turn with the crown")
		for _, ray in named(crown.spin, "CrownRay") do
			eq(ray.FaceCamera, false, "a sheet does not face the camera: its turning is seen")
		end
		check(
			CFG.CrownBeam.Y - CFG.CrownBeam.Band / 2 - CFG.CrownBeam.Bob > CFG.NeonSign.Y + CFG.NeonSign.Height / 2,
			"the crown floats above the neon sign"
		)
		check(CFG.NeonSign.Y - CFG.NeonSign.Height / 2 > 10.4, "the neon sign hangs above the marquee")
		local label = named(crowned, "NeonText")[1]:FindFirstChildOfClass("TextLabel")
		eq(label.Text, "GIGA GYM", "the neon sign's words")
	end)

	test("PlotRank: the champion stands on a stage in front of its pedestal", function()
		-- The pedestal as World.Shelves builds it at the front shelf's centre.
		local s = Layout.SHELF
		local c = CFG.Champion
		local deck, stand = Layout.rowTop(1), Layout.rowTop(1) + s.championRise
		local z = Layout.rowFrontZ(1) + s.depth / 2
		local upright = CFrame.Angles(0, 0, math.pi / 2)
		local function cylinder(height: number, diameter: number, y: number): any
			local p = Instance.new("Part")
			p.Size = Vector3.new(height, diameter, diameter)
			p.CFrame = CFrame.new(0, y, z) * upright
			return p
		end
		local foot = cylinder(0.25, 3.6, deck + 0.125)
		local drum = cylinder(stand - 0.3 - (deck + 0.25), 3, (deck + 0.25 + stand - 0.3) / 2)
		local rim = cylinder(0.3, 3.4, stand - 0.15)

		-- Where the champion is shown: in front of the pedestal, above it, facing the entrance.
		local home, stage = PlotRank.championHome(rim), PlotRank.championPivot(rim)
		check(sameFrame(home, CFrame.new(0, stand, z)), "the server stands the champion on the pedestal's rim")
		check(sameFrame(stage, CFrame.new(0, stand + c.Rise, z - c.Out)), "it is shown Out in front of and Rise above it")
		eq(PlotRank.championScale(12), c.Scale, "a champion is drawn 1.4x")
		eq(c.Scale, 1.4, "which is the size asked for")
		check(PlotRank.championScale(Economy.MAX_TIER) > c.Scale, "a tier 25 champion is bigger still")
		-- The roof over a one-shelf rack (and every shelf board above) starts behind this line:
		-- the stage and the champion stand in front of it, under open sky.
		local roofFront = Layout.rowFrontZ(1) - 0.3 - 0.08
		local gutter = Layout.GUTTER
		check(stage.Position.Z > gutter.rect.minZ and stage.Position.Z < gutter.rect.maxZ, "the stage stands over the gutter")
		local roofUnder = Layout.rowTop(2) - s.boardThick
		local panelFace = stage.Position.Z + c.Panel.Back - c.Panel.Thick / 2
		check(panelFace + c.Panel.Thick < roofFront, "the panel behind the champion stands in front of the roof")
		for _, tier in { 12, Economy.MAX_TIER } do
			local scale = PlotRank.championScale(tier)
			-- A unit's back (hair, cape, props) is at most 0.9 studs behind its pivot at scale 1.
			check(stage.Position.Z + 0.9 * scale < panelFace, "a " .. scale .. "x champion stands clear of the panel")
			check(stand + c.Rise + c.UnitHeight * scale > roofUnder, "a " .. scale .. "x champion would not fit under the shelf above")
		end

		local parent = Instance.new("Folder")
		local model, start, spins = PlotRank.showcase(parent, drum, rim, foot, 12)
		check(type(start) == "function", "it returns the function that starts its tweens")
		eq(#named(model, "GlowBand"), 1, "a glow band round the drum")
		eq(#named(model, "GlowHalo"), 1, "a halo on the board")
		eq(named(model, "GlowBand")[1].Color, theme.Colors.Rarity[Economy.tierBand(12)], "the glow is the band's colour")
		eq(named(model, "GlowBand")[1].Material.Name, "Neon", "the glow band is neon")
		local halo = named(model, "GlowHalo")[1]
		check(halo.Size.Y <= s.depth, "the halo stays on the shelf board")
		check(math.abs(halo.CFrame.Position.Y - deck) < 0.1, "the halo lies on the deck")
		eq(#named(model, "StageDisc"), 1, "a stage disc")
		eq(#named(model, "SpotPanel"), 1, "a dark panel behind the champion")
		eq(#named(model, "RimGlow"), 1, "a gold back light")
		check(named(model, "RimGlow")[1]:FindFirstChildOfClass("PointLight") ~= nil, "which lights the champion's edges")
		eq(#named(model, "HaloTile"), c.Halo.Tiles, "a ring of tiles over its head")
		eq(#spins, 1, "which turns")
		eq(#named(model, "CrownPoint"), 0, "no crown under the top tier")
		eq(#named(model, "CapeStrip"), 0, "no cape under the top tier")
		eq(#named(model, "ChampionBeam"), 0, "no sky beam at Rare")
		eq(#named(model, "StageSparkles"), 0, "no sparkles at Rare")
		local panel = named(model, "SpotPanel")[1]
		local color = panel.Color
		check(color.R + color.G + color.B < 0.8, "the panel is dark")
		local behind = stage:PointToObjectSpace(panel.CFrame.Position)
		check(
			behind.Z > 1 and behind.Z + panel.Size.Z / 2 <= roofFront - stage.Position.Z,
			"it stands behind the champion, in front of the roof"
		)
		check(panel.Size.X >= 6 and behind.Y + panel.Size.Y / 2 >= c.UnitHeight * c.Scale, "it is wider and taller than the champion")
		-- The plaque names the unit.
		local plaque = named(model, "NamePlaque")[1]
		local label = named(model, "NameText")[1]:FindFirstChildOfClass("TextLabel")
		eq(label.Text, string.upper(theme.Tiers[12].Name), "the plaque names the champion")
		check(plaque.Size.X >= 8 and plaque.Size.Y >= 2, "it is big enough to read from the walkway")
		-- Orbs roll under the stage along the gutter, and under the plaque down the chute.
		local orb = Layout.ORB_RADIUS * 2
		local disc = named(model, "StageDisc")[1]
		check(disc.CFrame.Position.Y - disc.Size.X / 2 > Layout.gutterY(disc.Size.Y / 2) + orb + 0.5, "orbs roll under the stage")
		local chute = Layout.CHUTE
		local along = math.clamp((chute.topZ - plaque.CFrame.Position.Z) / (chute.topZ - chute.bottomZ), 0, 1)
		local chuteY = chute.topY + (chute.bottomY - chute.topY) * along
		check(plaque.CFrame.Position.Y - plaque.Size.Y / 2 > chuteY + orb + 0.2, "orbs roll under the plaque")
		-- It hangs over the champion's head, above its ring (the pen's crate labels covered it
		-- under the stage), in the panel's plane, on two gold rods from the panel's top.
		local plaqueAt = stage:PointToObjectSpace(plaque.CFrame.Position)
		local ringTop = -math.huge
		for _, tile in named(model, "HaloTile") do
			ringTop = math.max(ringTop, stage:PointToObjectSpace(tile.CFrame.Position).Y + tile.Size.Y / 2)
		end
		check(plaqueAt.Y - plaque.Size.Y / 2 > ringTop, "it hangs above the ring over the champion's head")
		check(plaqueAt.Y - plaque.Size.Y / 2 > c.UnitHeight * c.Scale, "above the champion")
		check(math.abs(plaqueAt.Z - c.Panel.Back) < 0.01, "in the panel's plane")
		eq(#named(model, "PlaqueRod"), 2, "on two rods")

		-- Rarity: sparkles from Epic, a sky beam from Legendary.
		local epic = PlotRank.showcase(parent, drum, rim, foot, 17)
		eq(#named(epic, "StageSparkles"), 1, "an Epic stage sparkles")
		eq(#named(epic, "ChampionBeam"), 0, "no sky beam at Epic")
		local legend = PlotRank.showcase(parent, drum, rim, foot, 23)
		eq(#named(legend, "ChampionBeam"), 1, "a Legendary champion stands in a sky beam")

		-- Tier 25 is clearly grander than tier 23.
		local top, _, topSpins = PlotRank.showcase(parent, drum, rim, foot, Economy.MAX_TIER)
		eq(#named(top, "CrownPoint"), CFG.CrownPoints, "a crown round the stage")
		eq(#named(top, "CapeStrip"), CFG.Cape.Strips, "the cape's strips")
		for _, strip in named(top, "CapeStrip") do
			check(strip.Color.R > strip.Color.G * 3 and strip.Color.R < 0.6, "a solid dark-red cloth")
			check(strip.Transparency == 0, "not see-through")
		end
		check(CFG.Cape.Width >= CFG.Cape.BottomStep, "the strips overlap: no gaps")
		for _, tile in named(top, "HaloTile") do
			check(tile.Color.B < 0.3 and tile.Color.R > 0.9, "the ring is deep gold, not a white glow")
		end
		eq(#named(top, "BodySparkles"), 1, "gold sparkles rise round a tier 25 champion")
		check(named(top, "RimGlow")[1]:FindFirstChildOfClass("PointLight").Brightness <= c.RimLight.Brightness / 2 + 0.01, "half the glare")
		eq(#named(top, "SunRay"), c.SunRays, "a sunburst behind it")
		eq(#named(top, "ChampionRay"), c.Rays, "sheets of light in its beam")
		eq(#topSpins, 3, "the ring, the sunburst and the sheets of light turn")
		eq(named(top, "GlowBand")[1].Color, theme.Colors.Rarity.Mythic, "a Mythic glow")
		check(#baseParts(top) > #baseParts(legend) + 20, "far more to it than a tier 23 stage")
		check(named(top, "StageDisc")[1].Size.Y > named(legend, "StageDisc")[1].Size.Y, "a wider stage")
		check(named(top, "ChampionBeam")[1].Width0 > named(legend, "ChampionBeam")[1].Width0, "a wider beam")
		check(named(top, "SpotPanel")[1].Size.Y > named(legend, "SpotPanel")[1].Size.Y, "a taller panel for a bigger champion")
		for _, built in { model, top } do
			for _, part in baseParts(built) do
				check(
					part.Anchored == true and part.CanCollide == false and part.CanQuery == false,
					part.Name .. " never blocks the player or the camera"
				)
				local at = part.CFrame.Position
				-- Whatever reaches as high as the shelf above stands in front of it (the ring over
				-- the champion's head may turn a little past the edge, short of the roof's pennants).
				if at.Y + math.max(part.Size.X, part.Size.Y, part.Size.Z) / 2 > roofUnder then
					local limit = if part.Name == "HaloTile" then roofFront + 0.45 else roofFront
					check(at.Z <= limit, part.Name .. " stands in front of the roof's edge")
				end
				check(math.abs(at.X) <= s.spacing, part.Name .. " keeps off the neighbours' spots")
			end
		end
		for _, strip in named(top, "CapeStrip") do
			local at = stage:PointToObjectSpace(strip.CFrame.Position)
			check(at.Z > 0.3 and at.Z < c.Panel.Back, "the cape hangs behind the champion, in front of the panel")
			check(at.Y > 0 and at.Y < CFG.Cape.Top * c.MythicScale, "the cape hangs between the shoulders and the stage")
		end
		for _, point in named(top, "CrownPoint") do
			local at = stage:PointToObjectSpace(point.CFrame.Position)
			check(math.abs(at.Y) < 0.1, "a crown point sits on the stage's rim")
			check(
				math.abs(math.sqrt(at.X * at.X + at.Z * at.Z) - (c.MythicStage / 2 - 0.1)) < 0.01,
				"a crown point stands on the rim's edge"
			)
		end
		for _, d in parent:GetDescendants() do
			check(d.ClassName ~= "Highlight", "no Highlight instances")
		end
	end)

	test("PlotRank: the home shot frames the rack and its roof dressing", function()
		local s = Layout.SHELF
		local shot = CFG.Shot
		-- The spawn: on the walkway facing the rack; the follow camera looks at the head.
		local headY = 4.5
		local function frame(rows: number, tier: number): (number, number, boolean, number)
			local roofTop = Layout.rowTop(rows + 1)
			local roofZ = Layout.rowFrontZ(rows) - 0.3 + (s.depth + 0.4 + 0.6) / 2
			local rise = roofTop + PlotRank.dressTop(tier) - headY
			local run = roofZ - Layout.SPAWN.z
			local pitch, distance, fits = PlotRank.homeShot(rise, run, shot.Fov)
			-- The angle of the dressing's top above the camera's axis, from where the eye ends up.
			local above = math.atan2(rise - distance * math.sin(pitch), run + distance * math.cos(pitch)) + pitch
			return pitch, distance, fits, math.deg(above)
		end
		check(PlotRank.dressTop(1) >= 10.6, "the server's marquee counts at every rank")
		check(PlotRank.dressTop(20) > PlotRank.dressTop(19), "the neon sign raises the top")
		check(PlotRank.dressTop(25) > PlotRank.dressTop(24) + 8, "the crown raises it a lot")
		check(
			PlotRank.dressTop(25) >= CFG.CrownBeam.Y + CFG.CrownBeam.Band / 2 + CFG.CrownBeam.PointHeight + CFG.CrownBeam.Bob,
			"up to the crown's tips at the top of its bob"
		)

		local pitch, distance, fits = frame(1, 1)
		check(fits, "a new plot fits")
		eq(math.floor(math.deg(pitch) + 0.5), shot.Pitch, "a new plot keeps the old spawn pitch")
		eq(distance, shot.Distance, "and the old spawn distance")

		-- The shot never tilts down or closes in as the rack grows or gains dressing.
		local lastPitch, lastDistance = math.huge, 0
		for _, case in { { 1, 1 }, { 2, 8 }, { 3, 10 }, { 3, 15 }, { 3, 20 }, { 3, 25 }, { 4, 25 } } do
			local p, d, ok, above = frame(case[1], case[2])
			local label = case[1] .. " shelves at tier " .. case[2]
			check(ok, label .. ": the whole rack and its dressing are in frame")
			check(above <= shot.Fov / 2 - shot.Margin + 0.01, label .. ": the top is under the screen's top edge")
			check(p <= lastPitch + 1e-6, label .. ": tilts up, never down")
			check(d >= lastDistance - 1e-6, label .. ": pulls back, never in")
			check(d <= shot.LevelDistance, label .. ": the eye stays inside the plot's entrance")
			check(math.deg(p) >= 0, label .. ": the camera still looks down or level")
			lastPitch, lastDistance = p, d
		end
		-- From tier 20 the shot looks further up, the eye staying above the floor.
		for rows = 1, s.rows do
			for _, tier in { 19, 20, 25 } do
				local p, d = frame(rows, tier)
				local tp, td = PlotRank.homeTilt(p, d, tier)
				if tier < 20 then
					check(tp == p and td == d, rows .. " shelves at tier " .. tier .. ": no extra tilt")
				else
					check(math.abs(math.deg(p - tp) - shot.HighTilt) < 1e-6, rows .. " shelves at tier " .. tier .. ": looks further up")
					check(headY + td * math.sin(tp) > 1, rows .. " shelves at tier " .. tier .. ": the eye stays above the floor")
					check(td >= shot.Distance and td <= d, rows .. " shelves at tier " .. tier .. ": never further, never too close")
				end
			end
		end
		-- The tier 25 view is not the tier 10 view (the complaint this shot answers).
		local p10, d10 = frame(3, 10)
		local p25, d25 = frame(3, 25)
		check(math.deg(p10 - p25) > 5 and d25 - d10 > 5, "tier 25 tilts up and pulls back well past tier 10")

		-- Every rack height: the roof itself is always in frame, and the eye stays above the floor.
		for rows = 1, s.rows do
			for _, tier in { 1, 20, 25 } do
				local p, d, ok, above = frame(rows, tier)
				local eyeY = headY + d * math.sin(p)
				check(eyeY > 1, rows .. " shelves: the eye is above the floor")
				check(d >= shot.Distance and d <= shot.LevelDistance, rows .. " shelves: a sane distance")
				if not ok then
					-- The widest shot: level or looking up, as far back as it goes.
					check(math.deg(p) <= 0, rows .. " shelves: the widest shot is used when the top is cropped")
				end
				check(above ~= nil, "a shot for every height")
			end
			local roofRise = Layout.rowTop(rows + 1) - headY
			local run = Layout.rowFrontZ(rows) - Layout.SPAWN.z
			local p, d = frame(rows, 25)
			local roofAbove = math.deg(math.atan2(roofRise - d * math.sin(p), run + d * math.cos(p)) + p)
			check(roofAbove < shot.Fov / 2, rows .. " shelves: the rack's roof is on screen")
		end
		-- Up to here the tier 25 crown is whole; a taller rack crops its tips (see the report).
		for rows = 1, 5 do
			local _, _, _, above = frame(rows, 25)
			check(above < shot.Fov / 2, rows .. " shelves at tier 25: the crown is on screen")
		end
	end)

	test("PlotRank: wired into the client within Studio's limits", function()
		local source = fs.readFile("src/client/Fx/PlotRank.luau")
		check(string.find(source, '"Highlight"', 1, true) == nil, "PlotRank creates no Highlight")
		check(string.find(fs.readFile("src/client/Main.client.luau"), '"PlotRank",', 1, true) ~= nil, "Main starts Fx.PlotRank")
		check(
			string.find(fs.readFile("src/client/Fx/Fans.luau"), "PlotRank.ownFans(", 1, true) ~= nil,
			"Fans counts the own crowd with PlotRank"
		)
		check(string.find(fs.readFile("src/client/Fx/Shelf.luau"), "PlotRank.fitScale(", 1, true) ~= nil, "Shelf sizes units with PlotRank")
		local shelf = fs.readFile("src/client/Fx/Shelf.luau")
		check(string.find(shelf, "PlotRank.championPivot(", 1, true) ~= nil, "Shelf shows the champion on its stage")
		check(string.find(shelf, "PlotRank.championScale(", 1, true) ~= nil, "Shelf draws the champion at its size")
		check(string.find(shelf, "Camera.punch(k.punch)", 1, true) ~= nil, "a merge punches the camera through Fx.Camera")
		check(string.find(shelf, '"Highlight"', 1, true) == nil, "Shelf creates no Highlight")
		local camera = fs.readFile("src/client/Fx/Camera.luau")
		check(string.find(camera, "PlotRank.homeShot(", 1, true) ~= nil, "the spawn camera frames the rack with PlotRank")
		check(string.find(camera, "PlotRank.dressTop(", 1, true) ~= nil, "up to the top of its dressing")
		local fans = fs.readFile("src/client/Fx/Fans.luau")
		check(string.find(fans, "PlotRank.championPivot(", 1, true) ~= nil, "fans face the champion's stage")
		check(string.find(fans, '"Highlight"', 1, true) == nil, "Fans creates no Highlight")
		-- Studio compiles with full debug info: at most 200 locals per function.
		for _, name in { "Fx/PlotRank", "Fx/Fans", "Fx/Shelf", "Fx/Camera", "Main.client" } do
			local path = "src/client/" .. name .. ".luau"
			local ok, err = pcall(luau.compile, fs.readFile(path), { optimizationLevel = 1, debugLevel = 2 })
			check(ok, path .. ": " .. string.sub(tostring(err), 1, 160))
		end
	end)
end

-- Run alone: tests/run.luau calls the returned function at once; when nobody has by the time
-- this file is done, run it here.
task.defer(function()
	if ran then
		return
	end
	local passed, failed = 0, 0
	local current = ""
	local function check(condition: boolean, message: string)
		if condition then
			passed += 1
		else
			failed += 1
			print(string.format("  FAIL [%s] %s", current, message))
		end
	end
	suite({
		check = check,
		eq = function(actual: any, expected: any, message: string?)
			check(actual == expected, string.format("%s: expected %s, got %s", message or "value", tostring(expected), tostring(actual)))
		end,
		test = function(name: string, fn: () -> ())
			current = name
			local ok, err = pcall(fn)
			if not ok then
				failed += 1
				print(string.format("  ERROR [%s] %s", name, tostring(err)))
			end
		end,
	})
	print(string.format("\n%d passed, %d failed", passed, failed))
	if failed > 0 then
		process.exit(1)
	end
end)

return suite
