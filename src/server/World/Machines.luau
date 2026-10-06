--[[
	Machines: the toy-like gym machines on every plot.
	  * Converter: a giant smoothie blender (clear-tint cup, chunky lid, blade disc
	    "ConverterCore" + "ConverterBlade" that the client spins). Orbs drop into
	    "ConverterIntake" on the lid.
	  * Processor: a juice-bar conveyor counter; "ProcessorCup" models ride the belt and the
	    "ProcessorLight" dots on the front show progress (both animated client-side).
	  * Vault: a big friendly piggy bank ("Piggy*" parts) with a coin ("Coin") in its slot.
	  * Unlockers: carnival high-strikers with a soft hammer, a target plinth ("HoloPad"), the
	    empty-slot ghost crate ("HoloCrate"), a puck on a track ("StrikerPuck") and a bell
	    ("StrikerBell" model) on top.
	Everything is painted from Theme.World: SmoothPlastic, teal bodies and kicks, white rims,
	sunny accents, no glow.
	Machine bodies: the uploaded Blender meshes (World.Props: Converter, Vault, CrateCracker,
	CrateCrackerVip) when they are in the place, else the part-built versions below. The crate
smasher meshes get a pastel overlay (pastel teal, VIP sunny; Props.overlay). With a mesh
	the named parts the client animates stay (ConverterCore / Blade / Juice, an invisible
	ConverterIntake on the mesh's fill cap, an invisible PiggySlot and the Coin on the pig's slot,
	HoloCrate, StrikerPuck, and an invisible StrikerBell on the mesh's bell for the ring effect),
	and invisible "PropCollider" parts block the player.
	Part of the world generator; see Server.WorldBuilder for the overview and plot axes.
]]

local Layout = require(script.Parent.Parent.PlotLayout)
local Common = require(script.Parent.Common)
local Props = require(script.Parent.Props)

type Builder = Common.Builder
type Rect = Common.Rect

local UPRIGHT = Common.UPRIGHT
local ALONG_Z = Common.ALONG_Z
local WHITE = Common.WHITE
local theme = Common.theme

local Machines = {}

local function worldColor(key: string, fallback: Color3): Color3
	local palette = theme.World
	return if palette and palette[key] then palette[key] else fallback
end

local function padColor(key: string, fallback: Color3): Color3
	local palette = theme.World
	local pads = palette and palette.Pads
	return if pads and pads[key] then pads[key] else fallback
end

local function decor(part: BasePart): BasePart
	part.CanCollide = false
	part.CastShadow = false
	return part
end

-- Converter: smoothie blender ------------------------------------------------------------------

-- Part-built converter body: motor base on a white foot, three candy buttons facing the pad and
-- a light clear-tint cup.
local function buildConverterBody(B: Builder, x: number, z: number, blue: Color3, blueLight: Color3)
	local L, P = B.L, B.P
	-- Motor base: a fat round body on a white foot, with three candy buttons facing the pad.
	P({
		Name = "ConverterFoot",
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(0.6, 6.6, 6.6),
		CFrame = L(x, 0.3, z) * UPRIGHT,
		Color = WHITE,
	})
	P({
		Name = "ConverterBase",
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(2.4, 6, 6),
		CFrame = L(x, 1.7, z) * UPRIGHT,
		Color = blue,
	})
	P({
		Name = "ConverterBaseRim",
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(0.5, 6.4, 6.4),
		CFrame = L(x, 2.9, z) * UPRIGHT,
		Color = WHITE,
	})
	for i, key in { "Sunny", "TealLight", "RedOrange" } do
		local dz = (i - 2) * 1.3
		local dx = math.sqrt(9 - dz * dz)
		decor(P({
			Name = "ConverterButton",
			Shape = Enum.PartType.Cylinder,
			Size = Vector3.new(0.5, 0.95, 0.95),
			CFrame = L(x + dx, 1.7, z + dz) * CFrame.Angles(0, -math.atan2(dz, dx), 0),
			Color = worldColor(key, WHITE),
		}))
	end
	P({
		Name = "ConverterCollar",
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(0.7, 5.4, 5.4),
		CFrame = L(x, 3.5, z) * UPRIGHT,
		Color = blueLight,
	})

	-- Cup: a light clear tint with the aura smoothie and the blade disc inside.
	local cup = P({
		Name = "ConverterCup",
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(5.6, 5, 5),
		CFrame = L(x, 6.65, z) * UPRIGHT,
		Color = worldColor("Pool", blueLight):Lerp(WHITE, 0.55),
		Transparency = 0.5,
	})
	cup.CastShadow = false
end

-- The aura smoothie and the blade disc the client spins (inside the cup in both versions).
local function buildConverterCore(B: Builder, x: number, z: number, chrome: Color3)
	local L, P = B.L, B.P
	decor(P({
		Name = "ConverterJuice",
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(2.2, 4.5, 4.5),
		CFrame = L(x, 4.95, z) * UPRIGHT,
		Color = worldColor("Grape", B.c.Orb):Lerp(WHITE, 0.2),
		Transparency = 0.3,
	}))
	decor(P({
		Name = "ConverterCore",
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(0.6, 1.5, 1.5),
		CFrame = L(x, 4.4, z) * UPRIGHT,
		Color = chrome,
	}))
	for i = 0, 1 do
		decor(P({
			Name = "ConverterBlade",
			Size = Vector3.new(3.6, 0.3, 0.8),
			CFrame = L(x, 4.55, z) * CFrame.Angles(0, i * math.pi / 2, 0) * CFrame.Angles(0.25, 0, 0),
			Color = chrome,
		}))
	end
end

-- Part-built measuring marks, handle and lid with its sunny fill cap (ConverterIntake).
local function buildConverterLid(B: Builder, x: number, z: number, blue: Color3, cream: Color3)
	local L, P = B.L, B.P
	-- Measuring marks on the front of the cup.
	for i, y in { 5.6, 6.8, 8 } do
		decor(P({
			Name = "ConverterTick",
			Size = Vector3.new(0.2, 0.3, if i == 2 then 1.4 else 0.9),
			CFrame = L(x + 2.5, y, z),
			Color = WHITE,
		}))
	end
	-- Chunky handle on the +Z side.
	for _, y in { 5, 8.3 } do
		P({ Name = "ConverterHandle", Size = Vector3.new(0.8, 0.7, 1.4), CFrame = L(x, y, z + 3), Color = WHITE })
	end
	P({
		Name = "ConverterHandle",
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(4, 1, 1),
		CFrame = L(x, 6.65, z + 3.6) * UPRIGHT,
		Color = WHITE,
	})

	-- Lid with a sunny fill cap: deposited orbs drop into the cap (ConverterIntake).
	P({
		Name = "ConverterLidRim",
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(0.5, 5.5, 5.5),
		CFrame = L(x, 9.7, z) * UPRIGHT,
		Color = WHITE,
	})
	P({
		Name = "ConverterLid",
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(1, 5.2, 5.2),
		CFrame = L(x, 10.45, z) * UPRIGHT,
		Color = blue,
	})
	P({
		Name = "ConverterIntake",
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(0.9, 2.4, 2.4),
		CFrame = L(x + 0.6, 11.4, z) * UPRIGHT,
		Color = worldColor("Sunny", B.c.Primary),
	})
	decor(P({
		Name = "ConverterIntakeTop",
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(0.1, 1.6, 1.6),
		CFrame = L(x + 0.6, 11.86, z) * UPRIGHT,
		Color = cream,
	}))
end

-- Converter mesh: its cup axis (mesh units, from the bounding-box base centre); the blade
-- disc spins on that axis just above the cup floor (y = 4).
local CONVERTER_CUP_AXIS = Vector3.new(-0.67, 0, 0.13)

local function buildConverter(B: Builder, x: number, z: number)
	local L, P = B.L, B.P
	local blue = padColor("Deposit", worldColor("Blue", B.c.Secondary))
	local blueLight = blue:Lerp(WHITE, 0.3)
	local chrome = worldColor("Chrome", WHITE)
	local cream = worldColor("Cream", WHITE)

	-- Mesh body (cup, motor base, buttons, handle, lid) with its front toward the deposit pad
	-- (+X) and its handle on the +Z side.
	local facing = L(x, 0, z) * CFrame.Angles(0, -math.pi / 2, 0)
	local body = Props.mesh("Converter", facing * CFrame.new(-CONVERTER_CUP_AXIS), 1, B.folder)
	if body then
		Props.collider(B.folder, L(x, 5.7, z), Vector3.new(11.4, 6.6, 6.6), true)
	else
		buildConverterBody(B, x, z, blue, blueLight)
	end
	buildConverterCore(B, x, z, chrome)
	if body then
		-- Deposited orbs drop into the mesh's fill cap (0.6 toward the pad).
		decor(P({
			Name = "ConverterIntake",
			Shape = Enum.PartType.Cylinder,
			Size = Vector3.new(0.9, 2.4, 2.4),
			CFrame = L(x + 0.6, 11, z) * UPRIGHT,
			Transparency = 1,
			CanQuery = false,
		}))
	else
		buildConverterLid(B, x, z, blue, cream)
	end
end

-- Processor: juice-bar conveyor -------------------------------------------------------------------

local function buildProcessor(B: Builder)
	local L, P = B.L, B.P
	local r = Layout.MACHINES.Processor
	local x = (r.minX + r.maxX) / 2
	local z = (r.minZ + r.maxZ) / 2
	local w = r.maxX - r.minX
	local d = r.maxZ - r.minZ
	local front = r.maxX
	local sunny = padColor("Process", worldColor("Sunny", B.c.Primary))
	local cream = worldColor("Cream", WHITE)
	local teal = worldColor("Teal", B.c.Secondary)
	local tealLight = worldColor("TealLight", WHITE)
	local coral = worldColor("Coral", B.c.Accent)
	local pink = worldColor("Pink", coral)

	-- Counter body: teal down to its kick strip, a sunny front panel of progress dots, white top.
	P({ Name = "ProcessorKick", Size = Vector3.new(w, 0.6, d), CFrame = L(x, 0.3, z), Color = teal })
	P({ Name = "Processor", Size = Vector3.new(w - 0.2, 3, d - 0.2), CFrame = L(x, 2.1, z), Color = teal })
	P({ Name = "ProcessorPanel", Size = Vector3.new(0.2, 1.4, d - 1.6), CFrame = L(front, 2.1, z), Color = sunny })
	local dots = 5
	for i = 1, dots do
		decor(P({
			Name = "ProcessorLight",
			Shape = Enum.PartType.Cylinder,
			Size = Vector3.new(0.2, 0.9, 0.9),
			CFrame = L(front + 0.12, 2.1, z - (d - 4) / 2 + (i - 1) * (d - 4) / (dots - 1)),
			Color = cream,
		}))
	end
	P({ Name = "ProcessorTop", Size = Vector3.new(w + 0.2, 0.5, d + 0.2), CFrame = L(x, 3.85, z), Color = WHITE })

	-- Conveyor belt with rollers and low side rails.
	local beltX = x + 0.3
	local beltLen = d - 2.4
	P({ Name = "ProcessorBelt", Size = Vector3.new(2.6, 0.3, beltLen), CFrame = L(beltX, 4.25, z), Color = worldColor("Steel", cream) })
	for _, side in { -1, 1 } do
		P({ Name = "ProcessorRail", Size = Vector3.new(0.4, 0.6, beltLen + 0.4), CFrame = L(beltX + side * 1.5, 4.4, z), Color = WHITE })
		P({
			Name = "ProcessorRoller",
			Shape = Enum.PartType.Cylinder,
			Size = Vector3.new(3.4, 1, 1),
			CFrame = L(beltX, 4.25, z + side * beltLen / 2),
			Color = sunny,
		})
	end

	-- Juice jug at the start of the belt.
	local jugZ = r.minZ + 2.6
	P({
		Name = "ProcessorJug",
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(2.4, 2.6, 2.6),
		CFrame = L(beltX, 5.3, jugZ) * UPRIGHT,
		Color = sunny,
	})
	P({
		Name = "ProcessorJugLid",
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(0.4, 2.9, 2.9),
		CFrame = L(beltX, 6.7, jugZ) * UPRIGHT,
		Color = WHITE,
	})
	decor(P({
		Name = "ProcessorSpout",
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(1, 0.7, 0.7),
		CFrame = L(beltX, 5, jugZ + 1.6) * ALONG_Z,
		Color = WHITE,
	}))

	-- Smoothie cups riding the belt (the client slides them while the processor works).
	local spacing = 2.4
	local firstZ = jugZ + 2.4
	for i = 0, 3 do
		local cz = firstZ + i * spacing
		local model = Instance.new("Model")
		model.Name = "ProcessorCup"
		model.Parent = B.folder
		decor(P({
			Name = "Cup",
			Shape = Enum.PartType.Cylinder,
			Size = Vector3.new(1.5, 1.3, 1.3),
			CFrame = L(beltX, 5.15, cz) * UPRIGHT,
			Color = WHITE,
			Parent = model,
		}))
		decor(P({
			Name = "CupBand",
			Shape = Enum.PartType.Cylinder,
			Size = Vector3.new(0.4, 1.4, 1.4),
			CFrame = L(beltX, 5, cz) * UPRIGHT,
			Color = if i % 2 == 0 then sunny else coral,
			Parent = model,
		}))
		decor(P({
			Name = "CupJuice",
			Shape = Enum.PartType.Cylinder,
			Size = Vector3.new(0.2, 1.1, 1.1),
			CFrame = L(beltX, 5.82, cz) * UPRIGHT,
			Color = tealLight,
			Parent = model,
		}))
		decor(P({
			Name = "CupStraw",
			Shape = Enum.PartType.Cylinder,
			Size = Vector3.new(1.3, 0.3, 0.3),
			CFrame = L(beltX + 0.2, 6.2, cz) * CFrame.Angles(0, 0, math.rad(78)),
			Color = pink,
			Parent = model,
		}))
	end
end

-- Vault: piggy bank -----------------------------------------------------------------------------

-- Part-built pig ("Piggy*" parts) facing +X; returns the plot-local x and top of its coin slot.
local function buildPiggy(B: Builder, x: number, z: number, pink: Color3, ink: Color3): (number, number)
	local L, P = B.L, B.P
	local pinkLight = pink:Lerp(WHITE, 0.3)
	local pinkDeep = pink:Lerp(worldColor("Coral", pink), 0.45)
	local by = 2.9
	local fx = x + 0.6
	for _, dx in { -1, 1 } do
		for _, dz in { -1, 1 } do
			P({
				Name = "PiggyLeg",
				Shape = Enum.PartType.Cylinder,
				Size = Vector3.new(1.1, 1, 1),
				CFrame = L(x + dx * 1, 1.25, z + dz * 0.95) * UPRIGHT,
				Color = pinkDeep,
			})
		end
	end
	P({ Name = "PiggyBody", Shape = Enum.PartType.Cylinder, Size = Vector3.new(1.2, 3.6, 3.6), CFrame = L(x, by, z), Color = pink })
	for _, dx in { -0.6, 0.6 } do
		P({ Name = "PiggyBody", Shape = Enum.PartType.Ball, Size = Vector3.new(3.6, 3.6, 3.6), CFrame = L(x + dx, by, z), Color = pink })
	end
	P({
		Name = "PiggySnout",
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(0.6, 1.4, 1.4),
		CFrame = L(fx + 1.85, by - 0.2, z),
		Color = pinkLight,
	})
	for _, dz in { -0.27, 0.27 } do
		decor(P({
			Name = "PiggyNostril",
			Shape = Enum.PartType.Cylinder,
			Size = Vector3.new(0.1, 0.35, 0.35),
			CFrame = L(fx + 2.17, by - 0.2, z + dz),
			Color = pinkDeep,
		}))
	end
	for _, dz in { -0.75, 0.75 } do
		decor(P({
			Name = "PiggyEye",
			Shape = Enum.PartType.Ball,
			Size = Vector3.new(0.5, 0.5, 0.5),
			CFrame = L(fx + 1.4, by + 0.75, z + dz),
			Color = ink,
		}))
		decor(P({
			Name = "PiggyEyeShine",
			Shape = Enum.PartType.Ball,
			Size = Vector3.new(0.18, 0.18, 0.18),
			CFrame = L(fx + 1.62, by + 0.86, z + dz * 0.94),
			Color = WHITE,
		}))
		decor(P({
			Name = "PiggyCheek",
			Shape = Enum.PartType.Ball,
			Size = Vector3.new(0.6, 0.6, 0.6),
			CFrame = L(fx + 1.25, by - 0.35, z + dz * 1.35),
			Color = pinkDeep:Lerp(WHITE, 0.25),
		}))
		-- Round ears: a pink disc with a coral inner disc, leaning back a little.
		local ear = L(x + 0.3, by + 1.65, z + dz * 1.33) * CFrame.Angles(dz * 0.4, 0, -0.3)
		decor(P({ Name = "PiggyEar", Shape = Enum.PartType.Cylinder, Size = Vector3.new(0.3, 1.1, 1.1), CFrame = ear, Color = pink }))
		decor(P({
			Name = "PiggyEar",
			Shape = Enum.PartType.Cylinder,
			Size = Vector3.new(0.3, 0.6, 0.6),
			CFrame = ear * CFrame.new(0.05, 0, 0),
			Color = pinkDeep,
		}))
	end

	-- Coin slot on the back.
	local slotX = x - 0.2
	local top = by + 1.8
	P({ Name = "PiggySlotRim", Size = Vector3.new(0.9, 0.2, 2), CFrame = L(slotX, top + 0.02, z), Color = WHITE })
	decor(P({ Name = "PiggySlot", Size = Vector3.new(0.36, 0.22, 1.6), CFrame = L(slotX, top + 0.04, z), Color = ink }))
	return slotX, top
end

-- Vault mesh: the middle of its coin slot opening (mesh units from the bounding-box base
-- centre, +Z = the pig's back); the slot runs across the pig.
local VAULT_SLOT = Vector3.new(0, 4.08, 0.28)

local function buildVault(B: Builder)
	local L, P = B.L, B.P
	local r = Layout.MACHINES.Vault
	local x = (r.minX + r.maxX) / 2
	local z = (r.minZ + r.maxZ) / 2
	local pink = worldColor("Pink", B.c.Accent)
	local ink = worldColor("Ink", B.c.PanelDark)
	local sunny = worldColor("Sunny", B.c.Primary)

	-- Teal plinth with a white rim.
	P({
		Name = "VaultBase",
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(0.6, 4.8, 4.8),
		CFrame = L(x, 0.3, z) * UPRIGHT,
		Color = worldColor("Teal", B.c.Good),
	})
	P({ Name = "VaultRing", Shape = Enum.PartType.Cylinder, Size = Vector3.new(0.3, 5, 5), CFrame = L(x, 0.65, z) * UPRIGHT, Color = WHITE })

	-- The pig faces +X (toward the Collect pad); its profile faces the entrance. The mesh pig
	-- stands on the ring; its coin slot runs across its back (VAULT_SLOT).
	local slotX: number, top: number
	local pig = Props.mesh("Vault", L(x, 0.8, z) * CFrame.Angles(0, -math.pi / 2, 0), 1, B.folder)
	if pig then
		pig.Name = "PiggyMesh"
		Props.collider(B.folder, pig.CFrame, pig.Size)
		slotX, top = x - VAULT_SLOT.Z, 0.8 + VAULT_SLOT.Y
		-- The client sends coins into the slot and wobbles every "Piggy*" part.
		decor(P({
			Name = "PiggySlot",
			Size = Vector3.new(0.36, 0.22, 1.6),
			CFrame = L(slotX, top + 0.04, z),
			Transparency = 1,
			CanQuery = false,
		}))
	else
		slotX, top = buildPiggy(B, x, z, pink, ink)
	end

	-- A big sunny coin half-way in the slot.
	decor(P({
		Name = "CoinRim",
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(0.3, 2.7, 2.7),
		CFrame = L(slotX, top + 0.7, z),
		Color = WHITE,
	}))
	local coin = decor(P({
		Name = "Coin",
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(0.4, 2.4, 2.4),
		CFrame = L(slotX, top + 0.7, z),
		Color = sunny,
	}))
	for _, face in { Enum.NormalId.Right, Enum.NormalId.Left } do
		local gui = Instance.new("SurfaceGui")
		gui.Face = face
		gui.LightInfluence = 0.4
		gui.Parent = coin
		local mark = Instance.new("TextLabel")
		mark.BackgroundTransparency = 1
		mark.Size = UDim2.fromScale(1, 1)
		mark.Font = theme.Fonts.Title
		mark.TextScaled = true
		mark.Text = "$"
		mark.TextColor3 = ink
		mark.Parent = gui
	end

	-- Two little coin stacks at the pig's feet.
	for i, spot in { Vector3.new(1.9, 0.45, -1.95), Vector3.new(1.75, 0.7, 2) } do
		local h = spot.Y * 2
		P({
			Name = "CoinStack",
			Shape = Enum.PartType.Cylinder,
			Size = Vector3.new(h, 1.2, 1.2),
			CFrame = L(x + spot.X, h / 2, z + spot.Z) * UPRIGHT,
			Color = sunny:Lerp(worldColor("Orange", sunny), if i == 1 then 0.15 else 0.05),
		})
		decor(P({
			Name = "CoinStackTop",
			Shape = Enum.PartType.Cylinder,
			Size = Vector3.new(0.12, 0.8, 0.8),
			CFrame = L(x + spot.X, h + 0.04, z + spot.Z) * UPRIGHT,
			Color = WHITE,
		}))
	end
end

-- Unlockers: carnival high-strikers -------------------------------------------------------------

-- CrateCracker mesh: distance from the rect front (minX) to the mesh's bounding-box base centre.
-- Its plinth, puck track and bell then stand where the part-built ones do.
local CRACKER_FRONT = 2.88

local function buildUnlocker(B: Builder, rect: Rect, fallback: Color3)
	local L, P = B.L, B.P
	local vip = rect == Layout.MACHINES.Unlocker2
	-- Pastel teal booth; the VIP one is sunny.
	local color = if vip then worldColor("Sunny", fallback) else worldColor("PoolDeep", fallback)
	local tint = color:Lerp(WHITE, 0.55)
	local cream = worldColor("Cream", WHITE)
	local z = (rect.minZ + rect.maxZ) / 2
	local depth = rect.maxZ - rect.minZ
	local front = rect.minX
	local bodyMinX = rect.minX + 2.5
	local bodyX = (bodyMinX + rect.maxX) / 2
	local bodyW = rect.maxX - bodyMinX

	local booth = Props.mesh(
		if vip then "CrateCrackerVip" else "CrateCracker",
		L(front + CRACKER_FRONT, 0, z) * CFrame.Angles(0, math.pi / 2, 0),
		1,
		B.folder
	)
	if booth then
		-- The mesh's baked candy colours under a pastel wash (teal, VIP sunny).
		if vip then
			Props.overlay(booth, worldColor("Sunny", fallback), 0.45)
		else
			Props.overlay(booth, worldColor("Pool", fallback), 0.3)
		end
	end
	-- Plot-local spots the client animates: the ghost crate on the plinth, the puck's rest spot
	-- on the track and the bell (hidden with the mesh: its own bell stays put and the client's
	-- ring effect plays at the same spot).
	local holoY: number, puckX: number, bellX: number, bellY: number, bellD: number, bellTransparency: number
	if booth then
		holoY, puckX = 2.2, front + 2.15
		bellX, bellY, bellD, bellTransparency = front + 3, 16, 2.84, 1
		-- Booth and striker tower; the plinth and awning in front stay open.
		Props.collider(B.folder, L(front + 4.25, 7.6, z), Vector3.new(3.5, 15.2, 10.6))
	else
		holoY, puckX = 2.25, bodyMinX - 0.2
		bellX, bellY, bellD, bellTransparency = bodyMinX + 0.5, 15.7, 2, 0
		-- Soft white bumper and mat in front of the booth.
		P({
			Name = "Bumper",
			Shape = Enum.PartType.Cylinder,
			Size = Vector3.new(depth - 1.4, 0.9, 0.9),
			CFrame = L(front + 0.45, 0.45, z) * ALONG_Z,
			Color = WHITE,
		})
		for _, dz in { -1, 1 } do
			P({
				Name = "Bumper",
				Shape = Enum.PartType.Ball,
				Size = Vector3.new(0.9, 0.9, 0.9),
				CFrame = L(front + 0.45, 0.45, z + dz * (depth - 1.4) / 2),
				Color = WHITE,
			})
		end
		P({ Name = "ChamberFloor", Size = Vector3.new(2.6, 0.3, depth - 0.6), CFrame = L(front + 1.3, 0.15, z), Color = tint })

		-- Striker plinth with a bullseye top; the crate sits on it (HoloCrate = empty-slot ghost).
		P({
			Name = "HoloPad",
			Shape = Enum.PartType.Cylinder,
			Size = Vector3.new(0.9, 2.8, 2.8),
			CFrame = L(front + 1.3, 0.75, z) * UPRIGHT,
			Color = color,
		})
		P({
			Name = "HoloPadRim",
			Shape = Enum.PartType.Cylinder,
			Size = Vector3.new(0.3, 3.1, 3.1),
			CFrame = L(front + 1.3, 1.1, z) * UPRIGHT,
			Color = WHITE,
		})
		decor(P({
			Name = "HoloPadEye",
			Shape = Enum.PartType.Cylinder,
			Size = Vector3.new(0.1, 1.2, 1.2),
			CFrame = L(front + 1.3, 1.27, z) * UPRIGHT,
			Color = color,
		}))
	end

	decor(P({
		Name = "HoloCrate",
		Size = Vector3.new(1.8, 1.8, 2.4),
		CFrame = L(front + 1.3, holoY, z) * CFrame.Angles(0, math.rad(20), 0),
		Color = worldColor("Butter", tint),
		Transparency = 0.55,
	}))

	if not booth then
		-- Booth: cream body, teal kick band, white rim, bullseye target behind the crate.
		P({ Name = "Machine", Size = Vector3.new(bodyW, 7, depth - 0.6), CFrame = L(bodyX, 3.5, z), Color = cream })
		P({
			Name = "MachineKick",
			Size = Vector3.new(bodyW + 0.1, 0.8, depth - 0.5),
			CFrame = L(bodyX, 0.4, z),
			Color = worldColor("Teal", color),
		})
		P({ Name = "MachineRim", Size = Vector3.new(bodyW + 0.3, 0.4, depth - 0.2), CFrame = L(bodyX, 7.1, z), Color = WHITE })
		for i, ring in { { 4.2, color }, { 3, WHITE }, { 1.6, color } } do
			decor(P({
				Name = "Target",
				Shape = Enum.PartType.Cylinder,
				Size = Vector3.new(0.2 + i * 0.02, ring[1], ring[1]),
				CFrame = L(bodyMinX - 0.1 - i * 0.02, 3.8, z),
				Color = ring[2],
			}))
		end

		-- Sunny awning over the plinth with scalloped balls on the front edge.
		local stripes = 6
		local stripeW = (depth - 0.4) / stripes
		local slope = math.atan2(0.8, bodyMinX - front)
		local awningLen = (bodyMinX - front) / math.cos(slope) + 0.2
		for i = 1, stripes do
			local sz = z - (depth - 0.4) / 2 + (i - 0.5) * stripeW
			local stripeColor = worldColor("Sunny", color)
			P({
				Name = "Awning",
				Size = Vector3.new(awningLen, 0.3, stripeW),
				CFrame = L((front + bodyMinX) / 2, 6.7, sz) * CFrame.Angles(0, 0, slope),
				Color = stripeColor,
			})
			decor(P({
				Name = "AwningScallop",
				Shape = Enum.PartType.Ball,
				Size = Vector3.new(0.8, 0.8, 0.8),
				CFrame = L(front + 0.05, 6.25, sz),
				Color = stripeColor,
			}))
		end

		-- Striker tower: a tinted board with a white track and candy height ticks.
		P({ Name = "Backboard", Size = Vector3.new(1, 6.4, 8.6), CFrame = L(bodyMinX + 0.85, 10.4, z), Color = tint })
		local trackX = bodyMinX + 0.25
		P({ Name = "StrikerTrack", Size = Vector3.new(0.2, 5.6, 1.3), CFrame = L(trackX, 10.6, z), Color = WHITE })
		for i, key in { "TealLight", "Sunny", "Orange", "RedOrange" } do
			decor(P({
				Name = "StrikerTick",
				Size = Vector3.new(0.24, 0.3, 2.4),
				CFrame = L(trackX - 0.02, 9.1 + i * 1.05, z),
				Color = worldColor(key, color),
			}))
		end
	end
	-- The puck ("StrikerPuck", attribute Rise = studs to the top) the client sends up to the bell.
	local puckY = 9.3
	local puck = decor(P({
		Name = "StrikerPuck",
		Shape = Enum.PartType.Ball,
		Size = Vector3.new(1.1, 1.1, 1.1),
		CFrame = L(puckX, puckY, z),
		Color = worldColor("Sunny", color),
	}))
	puck:SetAttribute("Rise", 13.1 - puckY)

	if not booth then
		-- Candy-striped pillars and a marquee bar with bulbs.
		local pillarX = bodyMinX + 0.5
		local pillarZ = depth / 2 + 0.1
		for _, dz in { -1, 1 } do
			local pz = z + dz * pillarZ
			P({
				Name = "StrikerPillar",
				Shape = Enum.PartType.Cylinder,
				Size = Vector3.new(14, 1, 1),
				CFrame = L(pillarX, 7, pz) * UPRIGHT,
				Color = WHITE,
			})
			for y = 1.2, 13, 1.6 do
				decor(P({
					Name = "StrikerStripe",
					Shape = Enum.PartType.Cylinder,
					Size = Vector3.new(0.7, 1.08, 1.08),
					CFrame = L(pillarX, y, pz) * UPRIGHT,
					Color = color,
				}))
			end
			decor(P({
				Name = "StrikerKnob",
				Shape = Enum.PartType.Ball,
				Size = Vector3.new(1.4, 1.4, 1.4),
				CFrame = L(pillarX, 14.3, pz),
				Color = WHITE,
			}))
		end
		decor(P({
			Name = "StrikerMarquee",
			Shape = Enum.PartType.Cylinder,
			Size = Vector3.new(pillarZ * 2, 1.3, 1.3),
			CFrame = L(pillarX, 14, z) * ALONG_Z,
			Color = color,
		}))
		for i = -2, 2 do
			decor(P({
				Name = "StrikerBulb",
				Shape = Enum.PartType.Ball,
				Size = Vector3.new(0.55, 0.55, 0.55),
				CFrame = L(pillarX - 0.62, 14, z + i * 1.6),
				Color = cream,
			}))
		end
		-- A soft foam hammer leaning against the booth.
		local hz = z + 3.3
		local from = Vector3.new(front + 0.5, 0.3, hz)
		local to = Vector3.new(front + 1.6, 4, hz)
		local tilt = CFrame.Angles(0, 0, math.atan2(to.Y - from.Y, to.X - from.X))
		local mid = (from + to) / 2
		local len = (to - from).Magnitude
		decor(P({
			Name = "HammerHandle",
			Shape = Enum.PartType.Cylinder,
			Size = Vector3.new(len, 0.45, 0.45),
			CFrame = L(mid.X, mid.Y, mid.Z) * tilt,
			Color = worldColor("Wood", cream),
		}))
		decor(P({
			Name = "HammerGrip",
			Shape = Enum.PartType.Cylinder,
			Size = Vector3.new(1.1, 0.6, 0.6),
			CFrame = L(mid.X, mid.Y, mid.Z) * tilt * CFrame.new(-len / 2 + 0.7, 0, 0),
			Color = worldColor("RedOrange", color),
		}))
		local head = L(to.X, to.Y, to.Z) * tilt * CFrame.new(0.3, 0, 0)
		decor(P({
			Name = "HammerHead",
			Shape = Enum.PartType.Cylinder,
			Size = Vector3.new(2.2, 1.6, 1.6),
			CFrame = head * ALONG_Z,
			Color = color,
		}))
		for _, dz in { -1.1, 1.1 } do
			decor(P({
				Name = "HammerCap",
				Shape = Enum.PartType.Cylinder,
				Size = Vector3.new(0.35, 1.72, 1.72),
				CFrame = head * CFrame.new(0, 0, dz) * ALONG_Z,
				Color = WHITE,
			}))
		end
	end

	-- The bell on top ("StrikerBell" model) swings when the puck reaches it.
	local bell = Instance.new("Model")
	bell.Name = "StrikerBell"
	bell.Parent = B.folder
	local sunny = worldColor("Sunny", B.c.Primary)
	decor(P({
		Name = "Bell",
		Shape = Enum.PartType.Ball,
		Size = Vector3.new(bellD, bellD, bellD),
		CFrame = L(bellX, bellY, z),
		Color = sunny,
		Transparency = bellTransparency,
		Parent = bell,
	}))
	decor(P({
		Name = "BellLip",
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(0.45, bellD + 0.3, bellD + 0.3),
		CFrame = L(bellX, bellY - 0.65, z) * UPRIGHT,
		Color = sunny:Lerp(worldColor("Orange", sunny), 0.35),
		Transparency = bellTransparency,
		Parent = bell,
	}))
	decor(P({
		Name = "BellKnob",
		Shape = Enum.PartType.Ball,
		Size = Vector3.new(0.7, 0.7, 0.7),
		CFrame = L(bellX, bellY + bellD / 2 + 0.1, z),
		Color = WHITE,
		Transparency = bellTransparency,
		Parent = bell,
	}))
end

Machines.buildConverter = buildConverter
Machines.buildProcessor = buildProcessor
Machines.buildVault = buildVault
Machines.buildUnlocker = buildUnlocker

return Machines
