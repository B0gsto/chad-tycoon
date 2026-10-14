--[[
	CharacterFactory: builds the unit figures from a theme "look" table.
	Used by the server (display shelves) and the client (Index / reward
	viewports). Everything is made from plain parts, so no uploaded assets are
	needed.

	Every unit is a jointed R15-style rig (15 limbs, see Poses.LIMBS). Each part
	carries a "Limb" attribute naming the limb it moves with; the model carries
	the joint pivots ("J_<Limb>"), its "RigScale", its "AnimSet" and the
	"AnimatedUnit" tag, so the client Animator can pose it. The PrimaryPart
	"Root" sits at the feet (y = 0) and the unit faces -Z.

	Look fields (all optional except the three colours):
	  skin, shirt, pants : Color3 (bots: head/forearm plating, chest, legs;
	               fans: leggings / joggers)
	  anim       : "Chad" | "Bot" | "Fan" — body style and animation set
	               (defaults to the theme's Theme.AnimSet, else "Chad")
	  material   : Enum.Material name for the body ("Metal", "Glass", ...)
	  buff       : 0..1 muscle / bulk (wider chest, thicker arms)
	  scale      : overall size multiplier (1..2; fans 0.85..0.92)
	  acc        : list of accessory names (see ACCESSORIES)
	  accColor   : Color3 for accessories
	  trim       : Color3 secondary colour (chad belt / jacket inner shirt,
	               bot joints and frame, fan shirt emblem)
	  aura       : Color3 particle aura
	  auraRate   : aura particles per second (default 10; low tiers use a faint aura)
	  sparkles   : true for a Sparkles effect
	  fire       : Color3 fire effect
	  glow       : Color3 point light
	  manual     : true to leave off the "AnimatedUnit" tag, for models that
	               code poses itself with RigPose (cutscenes)
	 Chad and Fan:
	  expr       : "Neutral" | "Smirk" | "Smug" | "Determined" | "Angry" |
	               "Happy" | "Stoic" | "Cheer" | "Starry" | "Sad" | "Shock"
	  exprs      : extra expressions to build hidden, switched with
	               CharacterFactory.setExpression(model, name)
	  hair       : Color3 (also the eyebrows)
	  hairStyle  : "Buzz" | "Flat" | "Slick" | "Quiff" | "Spiky" | "Bun" | "Bald" |
	               "Ponytail" | "Pigtails" | "Bob" | "LongHair"
	  beard      : "Stubble" | "Beard"
	  jaw        : true (or 0..1) for a wide chiselled jaw and chin
	  top        : "Tee" | "Tank" | "Shirtless" | "Jacket" | "Hoodie"
	  bottoms    : "Pants" | "Joggers" | "Shorts" | "Skirt" (fans: knee-length
	               over leggings in the pants colour)
	  shoes, sole: Color3 sneaker upper / sole
	  eyeGlow    : Color3 glowing eyes instead of pupils
	 Fan only (smaller, rounder build with big eyes):
	  skirt      : Color3 of the skirt (default accColor)
	  emblem     : "Heart" | "Star" | "Disc" shirt print in the trim colour
	  lashes     : true for eyelashes
	  blush      : false to leave off the cheek blush
	  prop       : accessory held by the fan ("FanSign" | "PomPoms" | "FoamFinger")
	  signText   : text on a FanSign (model attribute "SignText", default "#1 FAN")
	 Bot only:
	  eyes       : "Dots" | "Visor" | "Mono" | "Angry" | "Happy" | "Bars"
	  mouth      : "Grille" | "Bar" | "None"
	  faceColor  : Color3 of the LEDs (eyes, chest core)
]]

local CharacterFactory = {}

export type Look = {
	skin: Color3,
	shirt: Color3,
	pants: Color3,
	anim: string?,
	material: string?,
	buff: number?,
	scale: number?,
	acc: { string }?,
	accColor: Color3?,
	trim: Color3?,
	aura: Color3?,
	auraRate: number?,
	sparkles: boolean?,
	fire: Color3?,
	glow: Color3?,
	expr: string?,
	hair: Color3?,
	hairStyle: string?,
	beard: string?,
	jaw: (boolean | number)?,
	top: string?,
	bottoms: string?,
	shoes: Color3?,
	sole: Color3?,
	eyeGlow: Color3?,
	eyes: string?,
	mouth: string?,
	faceColor: Color3?,
	manual: boolean?,
	exprs: { string }?,
	skirt: Color3?,
	emblem: string?,
	lashes: boolean?,
	blush: boolean?,
	prop: string?,
	signText: string?,
	-- Legacy (ignored): emoji faces cannot render inside ViewportFrames.
	face: string?,
	faceFont: Enum.Font?,
}

local TAG = "AnimatedUnit"
local DETAIL = 0.16 -- parts thinner than this cast no shadow

local BLACK = Color3.new(0, 0, 0)
local WHITE = Color3.new(1, 1, 1)
local EYE_WHITE = Color3.fromRGB(248, 248, 250)
local PUPIL = Color3.fromRGB(28, 26, 34)
local MOUTH = Color3.fromRGB(96, 38, 40)
local GOLD = Color3.fromRGB(255, 200, 50)
local FACEPLATE = Color3.fromRGB(14, 16, 22)
local TONGUE = Color3.fromRGB(255, 128, 140)
local BLUSH = Color3.fromRGB(255, 168, 182)
local STAR = Color3.fromRGB(255, 212, 64) -- Theme.World.Sunny
local INK = Color3.fromRGB(58, 48, 96) -- Theme.World.Ink
local WOOD = Color3.fromRGB(222, 170, 112) -- Theme.World.Wood
local SIGN_TEXT = "#1 FAN"

local function shade(c: Color3, k: number): Color3
	return c:Lerp(BLACK, k)
end

local function tint(c: Color3, k: number): Color3
	return c:Lerp(WHITE, k)
end

local function materialFrom(name: string?): Enum.Material
	if name then
		local ok, value = pcall(function()
			return (Enum.Material :: any)[name]
		end)
		if ok and value then
			return value
		end
	end
	return Enum.Material.SmoothPlastic
end

-- Default animation set, from the place's Theme module when there is one.
local defaultAnim: string? = nil
function CharacterFactory.setDefaultAnim(name: string)
	defaultAnim = name
end
local function themeAnim(): string
	if defaultAnim == nil then
		defaultAnim = "Chad"
		pcall(function()
			local theme = game:GetService("ReplicatedStorage"):FindFirstChild("Theme")
			if theme and theme:IsA("ModuleScript") then
				local loaded = (require :: any)(theme)
				if type(loaded) == "table" and type(loaded.AnimSet) == "string" then
					defaultAnim = loaded.AnimSet
				end
			end
		end)
	end
	return defaultAnim :: string
end

local function animOf(look: Look): string
	return look.anim or themeAnim()
end

-- Build context -------------------------------------------------------------------

type Ctx = {
	model: Model,
	look: Look,
	scale: number,
	mat: Enum.Material,
	acc: Color3,
	trim: Color3,
	isBot: boolean,
	cute: boolean, -- fan build: big eyes, no nose / ears, rounder parts
	exprTag: string?, -- expression the face parts being built belong to
	exprHidden: boolean,
	has: { [string]: boolean },
	top: number,
	parts: { [string]: BasePart },
	-- geometry (unscaled studs, model space)
	W: number,
	chestD: number,
	chestTop: number,
	chestY: number,
	waistW: number,
	hipY: number,
	A: number,
	delt: number,
	armX: number,
	shoulderY: number,
	wristY: number,
	headY: number,
	HW: number,
	HH: number,
	HD: number,
	headTop: number,
	hairTop: number,
	eyeY: number,
	led: Color3,
}

local function trackTop(c: Ctx, size: Vector3, cf: CFrame)
	local _, _, _, _, _, _, r10, r11, r12 = cf:GetComponents()
	local top = cf.Position.Y + (math.abs(r10) * size.X + math.abs(r11) * size.Y + math.abs(r12) * size.Z) / 2
	if top > c.top then
		c.top = top
	end
end

-- Adds a part to the unit. Size and CFrame are in unscaled model space.
local function add(
	c: Ctx,
	limb: string,
	name: string,
	size: Vector3,
	cf: CFrame,
	color: Color3,
	material: Enum.Material?,
	shape: Enum.PartType?
): Part
	local p = Instance.new("Part")
	p.Name = name
	if shape then
		p.Shape = shape
	end
	local s = c.scale
	p.Size = size * s
	p.CFrame = if s == 1 then cf else CFrame.new(cf.Position * s) * cf.Rotation
	p.Color = color
	p.Material = material or c.mat
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	if math.min(size.X, size.Y, size.Z) < DETAIL then
		p.CastShadow = false
	end
	p:SetAttribute("Limb", limb)
	if c.exprTag then
		p:SetAttribute("Expr", c.exprTag)
		if c.exprHidden then
			p.Transparency = 1
		end
	end
	p.Parent = c.model
	trackTop(c, size, cf)
	return p
end

local function at(x: number, y: number, z: number): CFrame
	return CFrame.new(x, y, z)
end

local function rot(x: number, y: number, z: number, rx: number, ry: number, rz: number): CFrame
	return CFrame.new(x, y, z) * CFrame.Angles(math.rad(rx), math.rad(ry), math.rad(rz))
end

local SIDES = { { 1, "Right" }, { -1, "Left" } }

local function setPivot(c: Ctx, limb: string, x: number, y: number, z: number)
	c.model:SetAttribute("J_" .. limb, Vector3.new(x, y, z))
end

-- Wedge whose right angle sits at the top-inner corner (lats under the chest).
local function underWedge(side: number): (Vector3, Vector3)
	return Vector3.new(0, 0, -side), Vector3.new(0, -1, 0)
end
-- Wedge whose right angle sits at the bottom-inner corner (traps by the neck).
local function slopeWedge(side: number): (Vector3, Vector3)
	return Vector3.new(0, 0, side), Vector3.new(0, 1, 0)
end

-- Chad and fan faces --------------------------------------------------------------

type Expr = {
	lid: number, -- eye openness 0..1 (above 1 = wide open)
	look: number, -- pupil shift (+ = unit's right)
	brow: number, -- inner-end drop in degrees (+ = angry, - = worried)
	browY: number,
	browRaise: number, -- extra lift of the unit's left brow (one raised eyebrow)
	mouth: string, -- "Flat" | "Smirk" | "Grin" | "Open" | "Big" | "Frown" | "O"
	mouthW: number,
	mouthTilt: number,
	lookY: number?, -- pupil drop (+ = looking down)
	pupil: number?, -- pupil size multiplier
	star: boolean?, -- star-shaped eyes
}

local EXPRESSIONS: { [string]: Expr } = {
	Neutral = { lid = 1, look = 0, brow = 0, browY = 0, browRaise = 0, mouth = "Flat", mouthW = 0.34, mouthTilt = 0 },
	Smirk = { lid = 0.9, look = 0, brow = 4, browY = 0, browRaise = 0.06, mouth = "Smirk", mouthW = 0.32, mouthTilt = 12 },
	Smug = { lid = 0.55, look = 0, brow = -6, browY = 0.02, browRaise = 0.03, mouth = "Smirk", mouthW = 0.34, mouthTilt = 9 },
	Determined = { lid = 0.85, look = 0, brow = 16, browY = -0.02, browRaise = 0, mouth = "Flat", mouthW = 0.28, mouthTilt = 0 },
	Angry = { lid = 0.8, look = 0, brow = 26, browY = -0.03, browRaise = 0, mouth = "Open", mouthW = 0.34, mouthTilt = 0 },
	Happy = { lid = 0.9, look = 0, brow = -8, browY = 0.04, browRaise = 0, mouth = "Grin", mouthW = 0.4, mouthTilt = 0 },
	Stoic = { lid = 0.62, look = 0.055, brow = 6, browY = -0.03, browRaise = 0, mouth = "Flat", mouthW = 0.3, mouthTilt = 0 },
	Cheer = { lid = 0.95, look = 0, brow = -10, browY = 0.06, browRaise = 0, mouth = "Big", mouthW = 0.42, mouthTilt = 0 },
	Starry = { lid = 1, look = 0, brow = -8, browY = 0.06, browRaise = 0, mouth = "Big", mouthW = 0.38, mouthTilt = 0, star = true },
	Sad = { lid = 0.7, look = 0, brow = -20, browY = 0.03, browRaise = 0, mouth = "Frown", mouthW = 0.3, mouthTilt = 0, lookY = 0.03 },
	Shock = { lid = 1.2, look = 0, brow = -10, browY = 0.1, browRaise = 0, mouth = "O", mouthW = 0.17, mouthTilt = 0, pupil = 0.7 },
}
CharacterFactory.EXPRESSIONS = EXPRESSIONS

-- Eyes, brows and mouth for one expression.
local function buildExpression(c: Ctx, expr: Expr)
	local look = c.look
	local skin = look.skin
	local hair = look.hair or Color3.fromRGB(52, 36, 26)
	local front = -c.HD / 2
	local bottom = c.headY - c.HH / 2
	local eyeY = c.eyeY
	local plain = Enum.Material.SmoothPlastic
	local cute = c.cute

	-- Eyes (hidden behind shades / visor). Fans get big round eyes with a shine.
	if not (c.has.Shades or c.has.Visor) then
		local eyeX = if cute then 0.25 else 0.24
		local eyeW = if cute then 0.27 else 0.25
		local eyeH = (if cute then 0.27 else 0.17) * expr.lid
		local pupilK = expr.pupil or 1
		for _, side in SIDES do
			local s = side[1]
			local x = s * eyeX
			if look.eyeGlow then
				add(
					c,
					"Head",
					"Eye",
					Vector3.new(0.26, 0.13 * expr.lid + 0.03, 0.05),
					at(x, eyeY, front - 0.015),
					look.eyeGlow,
					Enum.Material.Neon
				)
			elseif expr.star then
				-- Two squares turned 45 degrees apart make an eight-point star.
				for _, angle in { 0, 45 } do
					add(c, "Head", "Eye", Vector3.new(0.23, 0.23, 0.04), rot(x, eyeY, front - 0.015, 0, 0, angle), STAR, plain)
				end
				add(c, "Head", "Shine", Vector3.new(0.07, 0.07, 0.03), at(x - s * 0.04, eyeY + 0.05, front - 0.035), WHITE, plain)
			else
				add(c, "Head", "Eye", Vector3.new(eyeW, eyeH, 0.04), at(x, eyeY, front - 0.01), EYE_WHITE, plain)
				local pw = (if cute then 0.17 else 0.12) * pupilK
				local ph = (if cute then 0.22 else 0.15) * math.min(expr.lid, 1) * pupilK
				local px = x - s * 0.02 + expr.look
				local py = eyeY - 0.005 - (expr.lookY or 0)
				add(c, "Head", "Pupil", Vector3.new(pw, ph, 0.04), at(px, py, front - 0.025), PUPIL, plain)
				if cute then
					add(c, "Head", "Shine", Vector3.new(0.06, 0.06, 0.03), at(px + 0.035, py + ph * 0.25, front - 0.045), WHITE, plain)
				end
			end
			if look.lashes and not look.eyeGlow then
				local lashY = eyeY + (if expr.star then 0.1 else eyeH / 2)
				add(
					c,
					"Head",
					"Lash",
					Vector3.new(0.12, 0.05, 0.04),
					rot(x + s * eyeW * 0.5, lashY, front - 0.02, 0, 0, s * 28),
					PUPIL,
					plain
				)
			end
		end
	end
	local browColor = if look.hairStyle == "Bald" then shade(skin, 0.45) else shade(hair, 0.1)
	local browSize = if cute then Vector3.new(0.24, 0.06, 0.06) else Vector3.new(0.3, 0.075, 0.07)
	local browUp = if cute then 0.22 else 0.17
	for _, side in SIDES do
		local s = side[1]
		local lift = expr.browY + (if s < 0 then expr.browRaise else 0)
		add(c, "Head", "Brow", browSize, rot(s * 0.25, eyeY + browUp + lift, front - 0.025, 0, 0, s * expr.brow), browColor, plain)
	end

	-- Mouth.
	local mouthY = bottom + (if cute then 0.24 else 0.22)
	local mz = front - 0.03
	local w = expr.mouthW
	if expr.mouth == "Grin" then
		add(c, "Head", "Mouth", Vector3.new(w, 0.15, 0.04), at(0, mouthY - 0.02, mz), MOUTH, plain)
		add(c, "Head", "Teeth", Vector3.new(w - 0.12, 0.05, 0.04), at(0, mouthY + 0.015, mz - 0.01), EYE_WHITE, plain)
	elseif expr.mouth == "Open" then
		add(c, "Head", "Mouth", Vector3.new(w, 0.15, 0.04), at(0, mouthY - 0.01, mz), MOUTH, plain)
		add(c, "Head", "Teeth", Vector3.new(w - 0.06, 0.05, 0.04), at(0, mouthY + 0.03, mz - 0.01), EYE_WHITE, plain)
	elseif expr.mouth == "Big" then
		-- Wide open cheering smile: teeth along the top, tongue at the bottom.
		add(c, "Head", "Mouth", Vector3.new(w, 0.21, 0.04), at(0, mouthY - 0.04, mz), MOUTH, plain)
		add(c, "Head", "Teeth", Vector3.new(w - 0.08, 0.06, 0.04), at(0, mouthY + 0.03, mz - 0.01), EYE_WHITE, plain)
		add(c, "Head", "Tongue", Vector3.new(w * 0.5, 0.07, 0.04), at(0, mouthY - 0.1, mz - 0.01), TONGUE, plain)
	elseif expr.mouth == "Frown" then
		for _, side in SIDES do
			local s = side[1]
			add(
				c,
				"Head",
				"Mouth",
				Vector3.new(w / 2 + 0.03, 0.06, 0.04),
				rot(s * w / 4, mouthY - 0.02, mz, 0, 0, -s * 18),
				shade(MOUTH, 0.2),
				plain
			)
		end
	elseif expr.mouth == "O" then
		add(c, "Head", "Mouth", Vector3.new(w, w * 1.25, 0.04), at(0, mouthY - 0.03, mz), MOUTH, plain)
	elseif expr.mouth == "Smirk" then
		add(c, "Head", "Mouth", Vector3.new(w, 0.065, 0.04), rot(-0.05, mouthY, mz, 0, 0, -expr.mouthTilt), shade(MOUTH, 0.2), plain)
	else
		add(c, "Head", "Mouth", Vector3.new(w, 0.065, 0.04), at(0, mouthY, mz), shade(MOUTH, 0.2), plain)
	end
end

local GIRL_HAIR = { Ponytail = true, Pigtails = true, Bob = true, LongHair = true }

-- The longer fan hairstyles: a cap, a fringe and a back / sides / tails.
local function buildLongHair(c: Ctx, style: string, hair: Color3, hatted: boolean)
	local HW, HD, top = c.HW, c.HD, c.headTop
	local front = -HD / 2
	local back = HD / 2
	local dark = shade(hair, 0.06)
	add(c, "Head", "Hair", Vector3.new(HW + 0.08, 0.22, HD + 0.08), at(0, top + 0.04, 0.01), hair)
	if not hatted then
		add(c, "Head", "Bangs", Vector3.new(HW + 0.04, 0.2, 0.14), at(0, top - 0.09, front + 0.02), tint(hair, 0.05))
	end
	if style == "Ponytail" then
		add(c, "Head", "HairBack", Vector3.new(HW + 0.06, 0.7, 0.12), at(0, top - 0.33, back + 0.04), hair)
		local tieY = top - 0.1
		add(c, "Head", "HairTie", Vector3.one * 0.24, at(0, tieY, back + 0.14), c.acc, nil, Enum.PartType.Ball)
		add(c, "Head", "Ponytail", Vector3.new(0.36, 1.0, 0.32), rot(0, tieY - 0.48, back + 0.3, -18, 0, 0), dark)
	elseif style == "Pigtails" then
		add(c, "Head", "HairBack", Vector3.new(HW + 0.06, 0.7, 0.12), at(0, top - 0.33, back + 0.04), hair)
		for _, side in SIDES do
			local s = side[1]
			local x = s * (HW / 2 + 0.1)
			local y = c.headY + 0.14
			add(c, "Head", "HairTie", Vector3.one * 0.22, at(x, y, 0.1), c.acc, nil, Enum.PartType.Ball)
			add(c, "Head", "Pigtail", Vector3.new(0.34, 0.86, 0.34), rot(x + s * 0.12, y - 0.44, 0.12, 0, 0, s * 14), dark)
		end
	elseif style == "Bob" then
		add(c, "Head", "HairBack", Vector3.new(HW + 0.08, 0.92, 0.14), at(0, top - 0.44, back + 0.05), hair)
		for _, side in SIDES do
			local s = side[1]
			add(c, "Head", "HairSide", Vector3.new(0.14, 0.84, HD * 0.86), at(s * (HW / 2 + 0.05), top - 0.42, 0.06), hair)
		end
	else -- LongHair: down past the shoulders at the back.
		add(c, "Head", "HairBack", Vector3.new(HW + 0.1, 1.7, 0.16), at(0, top - 0.82, back + 0.06), hair)
		for _, side in SIDES do
			local s = side[1]
			add(c, "Head", "HairSide", Vector3.new(0.14, 1.2, HD * 0.8), at(s * (HW / 2 + 0.05), top - 0.58, 0.1), hair)
		end
	end
end

local function buildChadFace(c: Ctx)
	local look = c.look
	local skin = look.skin
	local hair = look.hair or Color3.fromRGB(52, 36, 26)
	local HW, HD = c.HW, c.HD
	local front = -HD / 2
	local bottom = c.headY - c.HH / 2
	local eyeY = c.eyeY
	local jawValue = look.jaw
	local jaw = if jawValue == true then 1 elseif type(jawValue) == "number" then jawValue else 0
	local plain = Enum.Material.SmoothPlastic

	if jaw > 0 then
		add(c, "Head", "Jaw", Vector3.new(HW + 0.08 * jaw, 0.4, HD - 0.1), at(0, bottom + 0.1, -0.03), shade(skin, 0.03))
		add(c, "Head", "Chin", Vector3.new(0.46, 0.24, 0.12), at(0, bottom - 0.03, front + 0.02), shade(skin, 0.04))
	end
	if c.cute then
		if look.blush ~= false then
			for _, side in SIDES do
				add(
					c,
					"Head",
					"Blush",
					Vector3.new(0.02, 0.17, 0.17),
					rot(side[1] * 0.38, eyeY - 0.2, front - 0.005, 0, 90, 0),
					BLUSH,
					plain,
					Enum.PartType.Cylinder
				)
			end
		end
	else
		-- Both ears as one block through the head (saves a part).
		add(c, "Head", "Ears", Vector3.new(HW + 0.08, 0.28, 0.22), at(0, eyeY - 0.12, 0.06), skin)
		add(c, "Head", "Nose", Vector3.new(0.16, 0.24, 0.14), at(0, eyeY - 0.17, front - 0.06), shade(skin, 0.06))
	end

	-- Eyes, brows and mouth. With `exprs`, every listed expression is built and
	-- all but the current one are hidden (see CharacterFactory.setExpression).
	local current = look.expr or (if c.cute then "Cheer" else "Neutral")
	if look.exprs and #look.exprs > 0 then
		local list = table.clone(look.exprs)
		if not table.find(list, current) then
			table.insert(list, 1, current)
		end
		for _, name in list do
			c.exprTag = name
			c.exprHidden = name ~= current
			buildExpression(c, EXPRESSIONS[name] or EXPRESSIONS.Neutral)
		end
		c.exprTag = nil
		c.exprHidden = false
		c.model:SetAttribute("Expression", current)
	else
		buildExpression(c, EXPRESSIONS[current] or EXPRESSIONS.Neutral)
	end

	-- Facial hair.
	if look.beard == "Stubble" then
		add(c, "Head", "Stubble", Vector3.new(HW * 0.84, 0.38, 0.03), at(0, bottom + 0.13, front - 0.005), shade(skin, 0.22), plain)
	elseif look.beard == "Beard" then
		add(c, "Head", "Beard", Vector3.new(HW + 0.08 + 0.1 * jaw, 0.5, HD * 0.86), at(0, bottom + 0.07, -0.08), hair)
		add(c, "Head", "Moustache", Vector3.new(0.46, 0.09, 0.06), at(0, bottom + 0.32, front - 0.04), hair)
	end

	-- Hair.
	local style = look.hairStyle or "Buzz"
	local top = c.headTop
	local hatted = c.has.Cap or c.has.CapBack or c.has.Crown or c.has.Mohawk
	if GIRL_HAIR[style] then
		buildLongHair(c, style, hair, hatted == true)
	elseif style ~= "Bald" then
		local backH = if style == "Buzz" then 0.48 else 0.62
		add(c, "Head", "HairBack", Vector3.new(HW + 0.05, backH, 0.08), at(0, top - backH / 2 + 0.02, HD / 2 + 0.03), hair)
		if hatted then
			add(c, "Head", "Hair", Vector3.new(HW + 0.04, 0.1, HD + 0.04), at(0, top + 0.02, 0), hair)
		elseif style == "Buzz" then
			add(c, "Head", "Hair", Vector3.new(HW + 0.04, 0.1, HD + 0.04), at(0, top + 0.02, 0.02), hair)
		elseif style == "Flat" then
			add(c, "Head", "Hair", Vector3.new(HW + 0.06, 0.38, HD + 0.04), at(0, top + 0.11, 0.01), hair)
		elseif style == "Slick" then
			add(c, "Head", "Hair", Vector3.new(HW + 0.06, 0.2, HD + 0.06), at(0, top + 0.05, 0.01), hair)
			add(c, "Head", "HairFront", Vector3.new(HW * 0.92, 0.14, 0.4), rot(0, top + 0.16, front + 0.22, 12, 0, 0), tint(hair, 0.08))
		elseif style == "Quiff" then
			add(c, "Head", "Hair", Vector3.new(HW + 0.05, 0.16, HD + 0.05), at(0, top + 0.03, 0.01), hair)
			add(c, "Head", "Quiff", Vector3.new(HW * 0.84, 0.36, 0.56), rot(0, top + 0.2, front + 0.26, 24, 0, 0), tint(hair, 0.06))
		elseif style == "Spiky" then
			add(c, "Head", "Hair", Vector3.new(HW + 0.05, 0.16, HD + 0.05), at(0, top + 0.03, 0.01), hair)
			local spikes = { { -0.26, -0.18, 16, -18 }, { 0.26, -0.18, 16, 18 }, { 0, 0.22, -20, 0 } }
			for _, sp in spikes do
				add(
					c,
					"Head",
					"Spike",
					Vector3.new(0.3, 0.42, 0.3),
					CFrame.new(sp[1], top + 0.2, sp[2])
						* CFrame.Angles(math.rad(sp[3]), 0, math.rad(sp[4]))
						* CFrame.Angles(0, math.rad(45), 0),
					hair
				)
			end
		elseif style == "Bun" then
			add(c, "Head", "Hair", Vector3.new(HW + 0.05, 0.16, HD + 0.05), at(0, top + 0.03, 0.01), hair)
			add(c, "Head", "Bun", Vector3.new(0.44, 0.44, 0.44), at(0, top - 0.02, HD / 2 + 0.16), hair, nil, Enum.PartType.Ball)
			if c.cute and not hatted then
				add(c, "Head", "Bangs", Vector3.new(HW + 0.04, 0.2, 0.14), at(0, top - 0.09, front + 0.02), tint(hair, 0.05))
			end
		end
	end
	c.hairTop = c.top
end

-- Chad body -----------------------------------------------------------------------

local function buildChad(c: Ctx)
	local look = c.look
	local b = math.clamp(look.buff or 0, 0, 1)
	local skin, shirt, pants = look.skin, look.shirt, look.pants
	local topStyle = look.top or "Tee"
	local bottoms = look.bottoms or "Pants"
	local shirtless = topStyle == "Shirtless"
	local sleeved = topStyle == "Jacket" or topStyle == "Hoodie"
	local torsoColor = if shirtless then skin else shirt

	local hipX = 0.4 + 0.06 * b
	local legT = 0.64 + 0.14 * b
	local hipY, kneeY, ankleY = 2.05, 1.12, 0.32
	local waistY = 2.5
	local waistW = 1.42 + 0.22 * b
	local W = 1.72 + 0.9 * b
	local chestD = 0.92 + 0.14 * b
	local A = 0.54 + 0.34 * b
	local armX = W / 2 + A / 2 - 0.06
	local shoulderY = 3.95
	local elbowY = shoulderY - 0.96
	local wristY = elbowY - 0.84
	local neckY = 4.3
	local HW, HH, HD = 1.1, 1.16, 1.06
	local headY = neckY + 0.14 + HH / 2

	c.W, c.chestD, c.chestTop, c.chestY, c.waistW, c.hipY = W, chestD, 4.21, 3.72, waistW, hipY
	c.A, c.armX, c.shoulderY, c.wristY = A, armX, shoulderY, wristY
	c.delt = A + 0.16
	c.headY, c.HW, c.HH, c.HD = headY, HW, HH, HD
	c.headTop = headY + HH / 2
	c.eyeY = headY + 0.08

	setPivot(c, "LowerTorso", 0, hipY, 0)
	setPivot(c, "UpperTorso", 0, waistY, 0)
	setPivot(c, "Head", 0, neckY, 0)

	-- Legs.
	local shoes = look.shoes or Color3.fromRGB(240, 240, 244)
	local sole = look.sole or Color3.fromRGB(250, 250, 250)
	local plainShoes = look.shoes == nil and look.sole == nil
	for _, side in SIDES do
		local s, n = side[1], side[2]
		setPivot(c, n .. "UpperLeg", s * hipX, hipY, 0)
		setPivot(c, n .. "LowerLeg", s * hipX, kneeY, 0)
		setPivot(c, n .. "Foot", s * hipX, ankleY, 0)
		if plainShoes then
			add(c, n .. "Foot", "Shoe", Vector3.new(legT + 0.08, 0.36, 1.06), at(s * hipX, 0.18, -0.15), shoes)
		else
			add(c, n .. "Foot", "Shoe", Vector3.new(legT + 0.06, 0.28, 1.02), at(s * hipX, 0.22, -0.14), shoes)
			add(c, n .. "Foot", "Sole", Vector3.new(legT + 0.1, 0.1, 1.08), at(s * hipX, 0.05, -0.15), sole)
		end
		local shin = if bottoms == "Shorts" then skin else pants
		add(
			c,
			n .. "LowerLeg",
			n .. "LowerLeg",
			Vector3.new(legT * 0.9, kneeY - ankleY + 0.04, legT * 0.92),
			at(s * hipX, (kneeY + ankleY) / 2, 0),
			shin
		)
		add(
			c,
			n .. "UpperLeg",
			n .. "UpperLeg",
			Vector3.new(legT, hipY - kneeY + 0.08, legT * 1.02),
			at(s * hipX, (hipY + kneeY) / 2, 0),
			pants
		)
	end

	-- Hips.
	local hipsW = math.max(waistW, 2 * hipX + legT) + 0.04
	local hipsD = 0.88 + 0.1 * b
	c.parts.LowerTorso = add(c, "LowerTorso", "LowerTorso", Vector3.new(hipsW, 0.58, hipsD), at(0, 2.2, 0), pants)
	if look.trim and not c.has.ChampBelt then
		add(c, "LowerTorso", "Belt", Vector3.new(hipsW + 0.04, 0.13, hipsD + 0.04), at(0, 2.43, 0), look.trim)
	end

	-- Torso: V-taper from the waist to the chest.
	add(c, "UpperTorso", "Abs", Vector3.new(waistW, 0.8, chestD * 0.9), at(0, 2.88, 0), torsoColor)
	c.parts.UpperTorso = add(c, "UpperTorso", "UpperTorso", Vector3.new(W, 0.98, chestD), at(0, 3.72, 0), torsoColor)
	local latW = (W - waistW) / 2
	if latW > 0.12 then
		for _, side in SIDES do
			local s = side[1]
			local x, y = underWedge(s)
			add(
				c,
				"UpperTorso",
				"Lat",
				Vector3.new(chestD * 0.86, 0.6, latW),
				CFrame.fromMatrix(Vector3.new(s * (waistW / 2 + latW / 2), 2.93, 0.02), x, y),
				shade(torsoColor, 0.03),
				nil,
				Enum.PartType.Wedge
			)
		end
	end
	if b >= 0.15 then
		local pecColor = if shirtless then shade(skin, 0.04) else torsoColor
		for _, side in SIDES do
			local s = side[1]
			add(c, "UpperTorso", "Pec", Vector3.new(W / 2 - 0.1, 0.44, 0.1), at(s * (W / 4 - 0.01), 3.84, -chestD / 2 - 0.03), pecColor)
		end
	end
	if shirtless and b >= 0.3 then
		-- Two rows of abs split by a centre line.
		local absZ = -chestD * 0.45 - 0.02
		for row = 0, 1 do
			add(c, "UpperTorso", "Abs", Vector3.new(0.66, 0.2, 0.06), at(0, 3.06 - row * 0.25, absZ), shade(skin, 0.07))
		end
		add(c, "UpperTorso", "AbLine", Vector3.new(0.05, 0.48, 0.07), at(0, 2.94, absZ - 0.01), shade(skin, 0.3))
	end
	if topStyle == "Jacket" then
		add(c, "UpperTorso", "InnerShirt", Vector3.new(W * 0.34, 1.7, 0.06), at(0, 3.3, -chestD / 2 - 0.0), look.trim or WHITE)
	elseif topStyle == "Hoodie" then
		add(c, "UpperTorso", "Hood", Vector3.new(W * 0.56, 0.42, 0.42), at(0, 4.2, chestD / 2 - 0.05), shade(shirt, 0.08))
	end
	local neckW = 0.46 + 0.26 * b
	add(c, "UpperTorso", "Neck", Vector3.new(neckW, 0.38, 0.48 + 0.16 * b), at(0, 4.3, 0.03), skin)
	if b >= 0.5 then
		local trapColor = if topStyle == "Tank" then skin else torsoColor
		local trapW = W / 2 - neckW / 2 - 0.12
		local trapH = 0.26 + 0.12 * b
		for _, side in SIDES do
			local s = side[1]
			local x, y = slopeWedge(s)
			add(
				c,
				"UpperTorso",
				"Trap",
				Vector3.new(0.56, trapH, trapW),
				CFrame.fromMatrix(Vector3.new(s * (neckW / 2 + trapW / 2 - 0.02), 4.2 + trapH / 2, 0.08), x, y),
				trapColor,
				nil,
				Enum.PartType.Wedge
			)
		end
	end

	-- Arms.
	local sleeveColor = if topStyle == "Tee" or sleeved then shirt else skin
	local armColor = if sleeved then shirt else skin
	for _, side in SIDES do
		local s, n = side[1], side[2]
		local x = s * armX
		setPivot(c, n .. "UpperArm", x, shoulderY, 0)
		setPivot(c, n .. "LowerArm", x, elbowY, 0)
		setPivot(c, n .. "Hand", x, wristY, 0)
		add(c, n .. "UpperArm", "Delt", Vector3.one * c.delt, at(x, shoulderY - 0.1, 0), sleeveColor, nil, Enum.PartType.Ball)
		add(c, n .. "UpperArm", n .. "UpperArm", Vector3.new(A, 0.98, A * 0.98), at(x, shoulderY - 0.49, 0), armColor)
		if topStyle == "Tee" then
			add(c, n .. "UpperArm", "Sleeve", Vector3.new(A + 0.06, 0.32, A + 0.06), at(x, shoulderY - 0.2, 0), shirt)
		end
		if b >= 0.3 and not sleeved then
			add(c, n .. "UpperArm", "Bicep", Vector3.new(A * 0.72, 0.44, 0.2), at(x, shoulderY - 0.62, -A / 2 - 0.05), shade(skin, 0.03))
		end
		add(c, n .. "LowerArm", n .. "LowerArm", Vector3.new(A * 0.9, 0.86, A * 0.92), at(x, elbowY - 0.43, 0), armColor)
		add(c, n .. "Hand", n .. "Hand", Vector3.new(A * 0.8, 0.42, A * 0.88), at(x, wristY - 0.2, -0.02), skin)
	end

	-- Head.
	setPivot(c, "Head", 0, neckY, 0)
	c.parts.Head = add(c, "Head", "Head", Vector3.new(HW, HH, HD), at(0, headY, 0), skin)
	buildChadFace(c)
end

-- Fan body ------------------------------------------------------------------------

-- Shirt print on the chest: a heart, a star or a plain disc in the trim colour.
local function addEmblem(c: Ctx, y: number)
	local kind = c.look.emblem
	if not kind then
		return
	end
	local color = c.look.trim or WHITE
	local z = -c.chestD / 2 - 0.02
	local plain = Enum.Material.SmoothPlastic
	if kind == "Heart" then
		for _, side in SIDES do
			add(
				c,
				"UpperTorso",
				"Emblem",
				Vector3.new(0.05, 0.25, 0.25),
				rot(side[1] * 0.1, y + 0.05, z, 0, 90, 0),
				color,
				plain,
				Enum.PartType.Cylinder
			)
		end
		add(c, "UpperTorso", "Emblem", Vector3.new(0.25, 0.25, 0.05), rot(0, y - 0.05, z, 0, 0, 45), color, plain)
	elseif kind == "Star" then
		for _, angle in { 0, 45 } do
			add(c, "UpperTorso", "Emblem", Vector3.new(0.3, 0.3, 0.05), rot(0, y, z, 0, 0, angle), color, plain)
		end
	else
		add(c, "UpperTorso", "Emblem", Vector3.new(0.05, 0.4, 0.4), rot(0, y, z, 0, 90, 0), color, plain, Enum.PartType.Cylinder)
	end
end

-- A small, round, cheerful build: big head, ball hands and shoulders, sneakers.
local function buildFan(c: Ctx)
	local look = c.look
	local skin, shirt, pants = look.skin, look.shirt, look.pants
	local topStyle = if look.top == "Hoodie" then "Hoodie" else "Tee"
	local bottoms = look.bottoms or "Joggers"
	local hoodie = topStyle == "Hoodie"

	local hipX = 0.33
	local legT = 0.5
	local hipY, kneeY, ankleY = 1.8, 1.02, 0.3
	local waistY = 2.15
	local waistW = 1.22
	local W = 1.42
	local chestD = 0.8
	local A = 0.42
	local armX = W / 2 + A / 2 - 0.01
	local shoulderY = 3.28
	local elbowY = shoulderY - 0.78
	local wristY = elbowY - 0.7
	local neckY = 3.56
	local HW, HH, HD = 1.18, 1.12, 1.08
	local headY = neckY + 0.12 + HH / 2

	c.W, c.chestD, c.chestTop, c.chestY, c.waistW, c.hipY = W, chestD, 3.47, 3.05, waistW, hipY
	c.A, c.armX, c.shoulderY, c.wristY = A, armX, shoulderY, wristY
	c.delt = A + 0.1
	c.headY, c.HW, c.HH, c.HD = headY, HW, HH, HD
	c.headTop = headY + HH / 2
	c.eyeY = headY + 0.02

	setPivot(c, "LowerTorso", 0, hipY, 0)
	setPivot(c, "UpperTorso", 0, waistY, 0)
	setPivot(c, "Head", 0, neckY, 0)

	-- Legs: leggings or joggers and chunky sneakers.
	local shoes = look.shoes or WHITE
	local sole = look.sole or Color3.fromRGB(250, 250, 250)
	for _, side in SIDES do
		local s, n = side[1], side[2]
		local x = s * hipX
		setPivot(c, n .. "UpperLeg", x, hipY, 0)
		setPivot(c, n .. "LowerLeg", x, kneeY, 0)
		setPivot(c, n .. "Foot", x, ankleY, 0)
		add(c, n .. "Foot", "Shoe", Vector3.new(legT + 0.1, 0.3, 0.9), at(x, 0.22, -0.1), shoes)
		add(c, n .. "Foot", "Sole", Vector3.new(legT + 0.14, 0.1, 0.96), at(x, 0.05, -0.11), sole)
		local shin = if bottoms == "Shorts" then skin else pants
		add(
			c,
			n .. "LowerLeg",
			n .. "LowerLeg",
			Vector3.new(legT * 0.88, kneeY - ankleY + 0.06, legT * 0.9),
			at(x, (kneeY + ankleY) / 2, 0),
			shin
		)
		if bottoms == "Joggers" then
			add(
				c,
				n .. "LowerLeg",
				"Cuff",
				Vector3.new(legT * 0.88 + 0.06, 0.14, legT * 0.9 + 0.06),
				at(x, ankleY + 0.13, 0),
				shade(pants, 0.1)
			)
		end
		add(c, n .. "UpperLeg", n .. "UpperLeg", Vector3.new(legT, hipY - kneeY + 0.08, legT), at(x, (hipY + kneeY) / 2, 0), pants)
	end

	-- Hips, and a knee-length skirt with a white hem over the leggings.
	local hipsW = 2 * hipX + legT + 0.08
	local hipsD = 0.8
	local skirt = look.skirt or look.accColor or shirt
	c.parts.LowerTorso = add(
		c,
		"LowerTorso",
		"LowerTorso",
		Vector3.new(hipsW, 0.52, hipsD),
		at(0, hipY + 0.12, 0),
		if bottoms == "Skirt" then skirt else pants
	)
	if bottoms == "Skirt" then
		add(c, "LowerTorso", "Skirt", Vector3.new(hipsW + 0.3, 0.84, hipsD + 0.24), at(0, hipY - 0.2, 0), skirt)
		add(c, "LowerTorso", "SkirtHem", Vector3.new(hipsW + 0.36, 0.12, hipsD + 0.3), at(0, hipY - 0.58, 0), WHITE)
	end

	-- Torso.
	add(c, "UpperTorso", "Waist", Vector3.new(waistW, 0.76, chestD * 0.94), at(0, 2.5, 0), shirt)
	c.parts.UpperTorso = add(c, "UpperTorso", "UpperTorso", Vector3.new(W, 0.86, chestD), at(0, 3.05, 0), shirt)
	add(c, "UpperTorso", "Neck", Vector3.new(0.36, 0.3, 0.38), at(0, neckY + 0.02, 0.02), skin)
	if hoodie then
		add(c, "UpperTorso", "Hood", Vector3.new(W * 0.62, 0.4, 0.4), at(0, 3.5, chestD / 2 - 0.02), shade(shirt, 0.08))
		add(c, "UpperTorso", "Pocket", Vector3.new(W * 0.56, 0.3, 0.06), at(0, 2.45, -chestD * 0.47 - 0.02), shade(shirt, 0.06))
	end
	addEmblem(c, 2.98)

	-- Arms: round shoulders, tee sleeves or hoodie sleeves, ball hands.
	local armColor = if hoodie then shirt else skin
	for _, side in SIDES do
		local s, n = side[1], side[2]
		local x = s * armX
		setPivot(c, n .. "UpperArm", x, shoulderY, 0)
		setPivot(c, n .. "LowerArm", x, elbowY, 0)
		setPivot(c, n .. "Hand", x, wristY, 0)
		add(c, n .. "UpperArm", "Shoulder", Vector3.one * c.delt, at(x, shoulderY - 0.06, 0), shirt, nil, Enum.PartType.Ball)
		add(c, n .. "UpperArm", n .. "UpperArm", Vector3.new(A, 0.8, A), at(x, shoulderY - 0.4, 0), armColor)
		if not hoodie then
			add(c, n .. "UpperArm", "Sleeve", Vector3.new(A + 0.08, 0.34, A + 0.08), at(x, shoulderY - 0.2, 0), shirt)
		end
		add(c, n .. "LowerArm", n .. "LowerArm", Vector3.new(A * 0.92, 0.74, A * 0.92), at(x, elbowY - 0.36, 0), armColor)
		add(c, n .. "Hand", n .. "Hand", Vector3.one * (A + 0.06), at(x, wristY - 0.16, -0.02), skin, nil, Enum.PartType.Ball)
	end

	-- Head.
	c.parts.Head = add(c, "Head", "Head", Vector3.new(HW, HH, HD), at(0, headY, 0), skin)
	buildChadFace(c)
end

-- Bot body ------------------------------------------------------------------------

local function buildBotFace(c: Ctx)
	local look = c.look
	local HW, HD, headY = c.HW, c.HD, c.headY
	local front = -HD / 2
	local led = c.led
	local neon = Enum.Material.Neon
	local plain = Enum.Material.SmoothPlastic
	local eyeY = c.eyeY
	local z = front - 0.06

	add(c, "Head", "Faceplate", Vector3.new(HW - 0.18, 0.58, 0.06), at(0, headY + 0.06, front - 0.02), FACEPLATE, plain)
	local eyes = look.eyes or "Dots"
	if c.has.Visor then
		eyes = "None"
	end
	if eyes == "Visor" then
		add(c, "Head", "Eye", Vector3.new(HW - 0.36, 0.15, 0.04), at(0, eyeY, z), led, neon)
	elseif eyes == "Mono" then
		add(c, "Head", "Eye", Vector3.new(0.04, 0.36, 0.36), rot(0, eyeY - 0.02, z, 0, 90, 0), led, neon, Enum.PartType.Cylinder)
		-- A bright lens gets a dark iris, a coloured one a white-hot core.
		local bright = led.R + led.G + led.B > 2.4
		local core = if bright then FACEPLATE else WHITE
		add(
			c,
			"Head",
			"Pupil",
			Vector3.new(0.04, 0.14, 0.14),
			rot(0, eyeY - 0.02, z - 0.02, 0, 90, 0),
			core,
			if bright then plain else neon,
			Enum.PartType.Cylinder
		)
	elseif eyes ~= "None" then
		for _, side in SIDES do
			local s = side[1]
			local x = s * 0.26
			if eyes == "Angry" then
				add(c, "Head", "Eye", Vector3.new(0.3, 0.1, 0.04), rot(x, eyeY, z, 0, 0, s * 18), led, neon)
			elseif eyes == "Happy" then
				add(c, "Head", "Eye", Vector3.new(0.17, 0.06, 0.04), rot(x - 0.06, eyeY, z, 0, 0, 35), led, neon)
				add(c, "Head", "Eye", Vector3.new(0.17, 0.06, 0.04), rot(x + 0.06, eyeY, z, 0, 0, -35), led, neon)
			elseif eyes == "Bars" then
				add(c, "Head", "Eye", Vector3.new(0.3, 0.08, 0.04), at(x, eyeY, z), led, neon)
			else
				add(c, "Head", "Eye", Vector3.new(0.04, 0.22, 0.22), rot(x, eyeY, z, 0, 90, 0), led, neon, Enum.PartType.Cylinder)
			end
		end
	end
	local mouth = look.mouth or "Grille"
	if mouth == "Grille" then
		for row = 0, 2 do
			add(
				c,
				"Head",
				"Grille",
				Vector3.new(0.46, 0.045, 0.04),
				at(0, headY - 0.3 - row * 0.085, front - 0.01),
				shade(c.trim, 0.3),
				plain
			)
		end
	elseif mouth == "Bar" then
		add(c, "Head", "Mouth", Vector3.new(0.42, 0.06, 0.04), at(0, headY - 0.14, z), led, neon)
	end
	-- Both ear bolts as one cylinder through the head.
	add(c, "Head", "EarBolts", Vector3.new(HW + 0.14, 0.38, 0.38), at(0, headY, 0), c.trim, Enum.Material.Metal, Enum.PartType.Cylinder)
	if not c.has.Mohawk then
		add(c, "Head", "Crest", Vector3.new(0.2, 0.12, HD * 0.78), at(0, c.headTop + 0.05, 0.02), shade(look.skin, 0.15))
	end
	c.hairTop = c.top
end

local function buildBot(c: Ctx)
	local look = c.look
	local b = math.clamp(look.buff or 0, 0, 1)
	local skin, shirt, pants, trim = look.skin, look.shirt, look.pants, c.trim
	local metal = Enum.Material.Metal
	local plain = Enum.Material.SmoothPlastic

	local hipX = 0.46 + 0.06 * b
	local legT = 0.56 + 0.1 * b
	local hipY, kneeY, ankleY = 2.1, 1.22, 0.4
	local waistY = 2.45
	local W = 1.85 + 0.75 * b
	local chestD = 1.05 + 0.15 * b
	local A = 0.55 + 0.3 * b
	local armX = W / 2 + 0.3 + 0.12 * b
	local shoulderY = 3.8
	local elbowY, wristY = 2.98, 2.16
	local neckY = 4.12
	local HW, HH, HD = 1.28, 1.0, 1.12
	local headY = neckY + 0.12 + HH / 2

	c.W, c.chestD, c.chestTop, c.chestY, c.waistW, c.hipY = W, chestD, 4.05, 3.4, 1.4, hipY
	c.A, c.armX, c.shoulderY, c.wristY = A, armX, shoulderY, wristY
	c.delt = 0.62 + 0.12 * b
	c.headY, c.HW, c.HH, c.HD = headY, HW, HH, HD
	c.headTop = headY + HH / 2
	c.eyeY = headY + 0.1

	setPivot(c, "LowerTorso", 0, hipY, 0)
	setPivot(c, "UpperTorso", 0, waistY, 0)
	setPivot(c, "Head", 0, neckY, 0)

	for _, side in SIDES do
		local s, n = side[1], side[2]
		local x = s * hipX
		setPivot(c, n .. "UpperLeg", x, hipY, 0)
		setPivot(c, n .. "LowerLeg", x, kneeY, 0)
		setPivot(c, n .. "Foot", x, ankleY, 0)
		add(c, n .. "Foot", "Boot", Vector3.new(legT + 0.2, 0.4, 1.1), at(x, 0.2, -0.12), trim, metal)
		add(c, n .. "Foot", "ToeCap", Vector3.new(legT + 0.12, 0.14, 0.42), at(x, 0.42, -0.44), pants)
		add(c, n .. "LowerLeg", n .. "LowerLeg", Vector3.new(legT + 0.08, 0.86, legT + 0.14), at(x, 0.8, -0.02), pants)
		add(c, n .. "LowerLeg", "Knee", Vector3.one * (legT * 0.8), at(x, kneeY, 0), trim, metal, Enum.PartType.Ball)
		add(c, n .. "UpperLeg", n .. "UpperLeg", Vector3.new(legT * 0.78, 0.86, legT * 0.78), at(x, 1.66, 0), trim, metal)
	end

	c.parts.LowerTorso = add(c, "LowerTorso", "LowerTorso", Vector3.new(2 * hipX + legT * 0.8 + 0.12, 0.52, 0.86), at(0, 2.2, 0), pants)
	add(c, "UpperTorso", "Waist", Vector3.new(0.44, 0.95, 0.95), rot(0, 2.6, 0, 0, 0, 90), trim, metal, Enum.PartType.Cylinder)
	c.parts.UpperTorso = add(c, "UpperTorso", "UpperTorso", Vector3.new(W, 1.3, chestD), at(0, 3.4, 0), shirt)
	add(c, "UpperTorso", "ChestPlate", Vector3.new(W * 0.64, 0.74, 0.1), at(0, 3.5, -chestD / 2 - 0.04), skin)
	add(
		c,
		"UpperTorso",
		"Core",
		Vector3.new(0.1, 0.44, 0.44),
		rot(0, 3.5, -chestD / 2 - 0.12, 0, 90, 0),
		c.led,
		Enum.Material.Neon,
		Enum.PartType.Cylinder
	)
	add(c, "UpperTorso", "Vent", Vector3.new(W * 0.44, 0.16, 0.05), at(0, 2.96, -chestD / 2 - 0.01), shade(trim, 0.35), plain)
	for _, side in SIDES do
		add(
			c,
			"UpperTorso",
			"Bolt",
			Vector3.one * 0.12,
			at(side[1] * W * 0.28, 3.8, -chestD / 2 - 0.1),
			tint(trim, 0.3),
			metal,
			Enum.PartType.Ball
		)
	end
	add(c, "UpperTorso", "Neck", Vector3.new(0.34, 0.5, 0.5), rot(0, 4.15, 0, 0, 0, 90), trim, metal, Enum.PartType.Cylinder)

	for _, side in SIDES do
		local s, n = side[1], side[2]
		local x = s * armX
		setPivot(c, n .. "UpperArm", x, shoulderY, 0)
		setPivot(c, n .. "LowerArm", x, elbowY, 0)
		setPivot(c, n .. "Hand", x, wristY, 0)
		add(c, n .. "UpperArm", "ShoulderJoint", Vector3.one * c.delt, at(x, shoulderY, 0), trim, metal, Enum.PartType.Ball)
		add(c, n .. "UpperArm", n .. "UpperArm", Vector3.new(0.36, 0.84, 0.36), at(x, shoulderY - 0.42, 0), trim, metal)
		add(c, n .. "LowerArm", "Elbow", Vector3.one * 0.48, at(x, elbowY, 0), trim, metal, Enum.PartType.Ball)
		add(c, n .. "LowerArm", n .. "LowerArm", Vector3.new(A, 0.78, A + 0.04), at(x, elbowY - 0.42, 0), skin)
		add(c, n .. "Hand", n .. "Hand", Vector3.new(0.42 + 0.1 * b, 0.36, 0.5), at(x, wristY - 0.2, -0.02), trim, metal)
	end

	c.parts.Head = add(c, "Head", "Head", Vector3.new(HW, HH, HD), at(0, headY, 0), skin)
	buildBotFace(c)
end

-- Accessories ---------------------------------------------------------------------

local ACCESSORIES: { [string]: (Ctx) -> () } = {}

local function capCrown(c: Ctx): number
	local y = c.headTop + 0.06
	add(c, "Head", "Cap", Vector3.new(c.HW + 0.1, 0.3, c.HD + 0.1), at(0, y, 0), c.acc, Enum.Material.SmoothPlastic)
	return y
end

ACCESSORIES.Cap = function(c)
	local y = capCrown(c)
	add(
		c,
		"Head",
		"Brim",
		Vector3.new(c.HW * 0.92, 0.07, 0.56),
		rot(0, y - 0.12, -c.HD / 2 - 0.22, -6, 0, 0),
		shade(c.acc, 0.15),
		Enum.Material.SmoothPlastic
	)
end

ACCESSORIES.CapBack = function(c)
	local y = capCrown(c)
	add(
		c,
		"Head",
		"Brim",
		Vector3.new(c.HW * 0.92, 0.07, 0.5),
		rot(0, y - 0.1, c.HD / 2 + 0.2, 8, 0, 0),
		shade(c.acc, 0.15),
		Enum.Material.SmoothPlastic
	)
end

ACCESSORIES.Headband = function(c)
	if c.cute then
		-- Fans: a hair band over the crown from ear to ear.
		local top = c.headTop
		add(c, "Head", "Headband", Vector3.new(c.HW + 0.2, 0.12, 0.22), at(0, top + 0.2, -0.14), c.acc)
		for _, side in SIDES do
			add(c, "Head", "BandSide", Vector3.new(0.12, 0.5, 0.22), at(side[1] * (c.HW / 2 + 0.14), top - 0.06, -0.14), c.acc)
		end
		return
	end
	local y = if c.isBot then c.headTop - 0.16 else c.eyeY + 0.36
	add(c, "Head", "Headband", Vector3.new(c.HW + 0.08, 0.16, c.HD + 0.08), at(0, y, 0), c.acc, Enum.Material.Fabric)
	add(c, "Head", "BandTail", Vector3.new(0.16, 0.42, 0.05), rot(0.12, y - 0.2, c.HD / 2 + 0.07, 0, 0, 18), c.acc, Enum.Material.Fabric)
end

ACCESSORIES.Shades = function(c)
	local front = -c.HD / 2
	local lens = Color3.fromRGB(16, 16, 22)
	add(c, "Head", "Shades", Vector3.new(c.HW + 0.04, 0.07, 0.07), at(0, c.eyeY + 0.09, front - 0.04), BLACK, Enum.Material.SmoothPlastic)
	for _, side in SIDES do
		add(
			c,
			"Head",
			"Lens",
			Vector3.new(0.42, 0.22, 0.06),
			at(side[1] * 0.25, c.eyeY - 0.02, front - 0.05),
			lens,
			Enum.Material.SmoothPlastic
		)
	end
	add(c, "Head", "Glint", Vector3.new(0.1, 0.05, 0.02), rot(0.32, c.eyeY + 0.02, front - 0.085, 0, 0, 25), WHITE, Enum.Material.Neon)
end

ACCESSORIES.Visor = function(c)
	local front = -c.HD / 2
	add(c, "Head", "Visor", Vector3.new(c.HW + 0.06, 0.22, 0.1), at(0, c.eyeY, front - 0.06), c.acc, Enum.Material.Neon)
	add(
		c,
		"Head",
		"VisorBand",
		Vector3.new(c.HW + 0.08, 0.08, c.HD + 0.08),
		at(0, c.eyeY + 0.14, 0),
		Color3.fromRGB(30, 30, 36),
		Enum.Material.Metal
	)
end

ACCESSORIES.Chain = function(c)
	local front = -c.chestD / 2 - (if c.isBot then 0.13 else 0.1)
	local top = c.chestTop - 0.02
	for _, side in SIDES do
		local s = side[1]
		add(
			c,
			"UpperTorso",
			"Chain",
			Vector3.new(0.08, 0.7, 0.08),
			rot(s * 0.19, top - 0.3, front, 0, 0, s * 32),
			GOLD,
			Enum.Material.Metal
		)
	end
	add(
		c,
		"UpperTorso",
		"Medal",
		Vector3.new(0.08, 0.38, 0.38),
		rot(0, top - 0.7, front - 0.02, 0, 90, 0),
		GOLD,
		Enum.Material.Metal,
		Enum.PartType.Cylinder
	)
end

ACCESSORIES.Crown = function(c)
	local y = c.hairTop - 0.04
	local gold = c.acc
	add(c, "Head", "Crown", Vector3.new(c.HW + 0.14, 0.28, c.HD + 0.14), at(0, y + 0.1, 0), gold, Enum.Material.Metal)
	local w, d = (c.HW + 0.14) / 2 - 0.1, (c.HD + 0.14) / 2 - 0.1
	for _, corner in { { -w, -d }, { w, -d }, { 0, d } } do
		add(c, "Head", "CrownPoint", Vector3.new(0.2, 0.32, 0.2), rot(corner[1], y + 0.36, corner[2], 0, 45, 0), gold, Enum.Material.Metal)
	end
	add(
		c,
		"Head",
		"CrownGem",
		Vector3.new(0.16, 0.16, 0.05),
		rot(0, y + 0.1, -(c.HD + 0.14) / 2 - 0.02, 0, 0, 45),
		Color3.fromRGB(255, 40, 90),
		Enum.Material.Neon
	)
end

ACCESSORIES.Halo = function(c)
	local y = c.hairTop + (if c.has.Crown then 0.78 else 0.42)
	local r = 0.62
	for i = 0, 5 do
		local angle = i * 60
		local a = math.rad(angle)
		add(
			c,
			"Head",
			"Halo",
			Vector3.new(0.74, 0.09, 0.12),
			rot(math.sin(a) * r, y, math.cos(a) * r, 0, angle, 0),
			c.acc,
			Enum.Material.Neon
		)
	end
end

ACCESSORIES.Horns = function(c)
	local y = c.headTop
	for _, side in SIDES do
		local s = side[1]
		local x = s * (c.HW / 2 - 0.12)
		add(
			c,
			"Head",
			"Horn",
			Vector3.new(0.24, 0.4, 0.24),
			rot(x + s * 0.06, y + 0.14, -0.1, 0, 0, -s * 28),
			shade(c.acc, 0.2),
			Enum.Material.SmoothPlastic
		)
		add(c, "Head", "HornTip", Vector3.new(0.15, 0.36, 0.15), rot(x + s * 0.12, y + 0.44, -0.1, 0, 0, s * 8), c.acc, Enum.Material.Neon)
	end
end

ACCESSORIES.Antenna = function(c)
	local y = c.hairTop
	local x = if c.isBot then c.HW / 2 - 0.2 else 0
	add(c, "Head", "AntennaRod", Vector3.new(0.08, 0.8, 0.08), at(x, y + 0.38, 0.1), Color3.fromRGB(80, 80, 90), Enum.Material.Metal)
	add(c, "Head", "AntennaTip", Vector3.one * 0.26, at(x, y + 0.82, 0.1), c.acc, Enum.Material.Neon, Enum.PartType.Ball)
end

ACCESSORIES.Mohawk = function(c)
	local y = c.headTop
	add(c, "Head", "Mohawk", Vector3.new(0.18, 0.34, c.HD * 0.8), at(0, y + 0.15, 0.06), c.acc)
	add(c, "Head", "MohawkFront", Vector3.new(0.18, 0.38, 0.32), rot(0, y + 0.28, -c.HD / 2 + 0.16, 26, 0, 0), c.acc)
end

ACCESSORIES.Headphones = function(c)
	local y = c.hairTop
	add(
		c,
		"Head",
		"Headband",
		Vector3.new(c.HW + 0.22, 0.1, 0.18),
		at(0, y + 0.03, 0.04),
		Color3.fromRGB(30, 30, 36),
		Enum.Material.SmoothPlastic
	)
	for _, side in SIDES do
		local s = side[1]
		add(
			c,
			"Head",
			"EarCup",
			Vector3.new(0.2, 0.5, 0.5),
			at(s * (c.HW / 2 + 0.1), c.eyeY - 0.12, 0.04),
			c.acc,
			Enum.Material.SmoothPlastic,
			Enum.PartType.Cylinder
		)
	end
end

ACCESSORIES.Cape = function(c)
	local back = c.chestD / 2
	add(
		c,
		"UpperTorso",
		"CapeCollar",
		Vector3.new(c.W + 0.12, 0.26, 0.34),
		at(0, c.chestTop - 0.02, back),
		shade(c.acc, 0.15),
		Enum.Material.Fabric
	)
	add(
		c,
		"UpperTorso",
		"Cape",
		Vector3.new(c.W * 0.94, 2.8, 0.08),
		rot(0, c.chestTop - 1.42, back + 0.3, -9, 0, 0),
		c.acc,
		Enum.Material.Fabric
	)
end

ACCESSORIES.Wings = function(c)
	local back = c.chestD / 2 + 0.2
	local y = c.chestTop - 0.2
	for _, side in SIDES do
		local s = side[1]
		local feathers = { { 2.5, 0.9, 28, 0, 0 }, { 1.9, 0.82, 2, -0.5, 0.25 } }
		for _, f in feathers do
			local length, height, angle, drop = f[1], f[2], f[3], f[4]
			local a = math.rad(angle)
			local cx = s * (0.3 + math.cos(a) * length / 2)
			local cy = y + drop + math.sin(a) * length / 2
			local p = add(
				c,
				"UpperTorso",
				"Wing",
				Vector3.new(length, height, 0.08),
				CFrame.new(cx, cy, back) * CFrame.Angles(0, math.rad(-s * 18), math.rad(s * angle)),
				tint(c.acc, f[5]),
				Enum.Material.Neon
			)
			p.Transparency = 0.15
		end
	end
end

ACCESSORIES.Backpack = function(c)
	local back = c.chestD / 2
	add(c, "UpperTorso", "Pack", Vector3.new(c.W * 0.6, 1.2, 0.56), at(0, c.chestY - 0.15, back + 0.26), c.acc, Enum.Material.Metal)
	add(
		c,
		"UpperTorso",
		"PackFlap",
		Vector3.new(c.W * 0.62, 0.3, 0.62),
		at(0, c.chestY + 0.38, back + 0.26),
		shade(c.acc, 0.25),
		Enum.Material.Metal
	)
end

ACCESSORIES.Jetpack = function(c)
	local back = c.chestD / 2
	add(
		c,
		"UpperTorso",
		"Jetpack",
		Vector3.new(c.W * 0.56, 1.1, 0.5),
		at(0, c.chestY - 0.1, back + 0.24),
		Color3.fromRGB(70, 74, 84),
		Enum.Material.Metal
	)
	for _, side in SIDES do
		local x = side[1] * c.W * 0.2
		add(
			c,
			"UpperTorso",
			"Thruster",
			Vector3.new(0.6, 0.38, 0.38),
			rot(x, c.chestY - 0.75, back + 0.3, 0, 0, 90),
			c.acc,
			Enum.Material.Metal,
			Enum.PartType.Cylinder
		)
		add(
			c,
			"UpperTorso",
			"Flame",
			Vector3.one * 0.3,
			at(x, c.chestY - 1.12, back + 0.3),
			Color3.fromRGB(255, 170, 60),
			Enum.Material.Neon,
			Enum.PartType.Ball
		)
	end
end

-- Pauldrons: a top plate plus a side plate hanging over the upper arm.
ACCESSORIES.Shoulders = function(c)
	local size = c.delt + 0.26
	for _, side in SIDES do
		local s, n = side[1], side[2]
		local x = s * (c.armX + 0.04)
		local top = Vector3.new(size, 0.3, size)
		add(c, n .. "UpperArm", "Pad", top, rot(x, c.shoulderY + 0.2, 0, 0, 0, -s * 12), c.acc, Enum.Material.Metal)
		local plate = Vector3.new(0.14, 0.62, size - 0.08)
		local px = x + s * (size / 2 - 0.02)
		add(c, n .. "UpperArm", "PadSide", plate, rot(px, c.shoulderY - 0.14, 0, 0, 0, -s * 12), shade(c.acc, 0.25), Enum.Material.Metal)
	end
end

ACCESSORIES.Dumbbell = function(c)
	local x = c.armX
	local y = c.wristY - 0.2
	local iron = Color3.fromRGB(45, 45, 52)
	add(
		c,
		"RightHand",
		"DumbbellBar",
		Vector3.new(1.0, 0.12, 0.12),
		rot(x, y, -0.02, 0, 90, 0),
		Color3.fromRGB(180, 180, 190),
		Enum.Material.Metal,
		Enum.PartType.Cylinder
	)
	for _, z in { -0.42, 0.38 } do
		add(
			c,
			"RightHand",
			"DumbbellPlate",
			Vector3.new(0.16, 0.56, 0.56),
			rot(x, y, z, 0, 90, 0),
			iron,
			Enum.Material.Metal,
			Enum.PartType.Cylinder
		)
	end
end

ACCESSORIES.Towel = function(c)
	local x = -(c.W / 2 - 0.35)
	local towel = c.acc
	add(c, "UpperTorso", "Towel", Vector3.new(0.5, 0.12, c.chestD + 0.16), at(x, c.chestTop + 0.04, 0), towel, Enum.Material.Fabric)
	add(
		c,
		"UpperTorso",
		"TowelEnd",
		Vector3.new(0.48, 0.9, 0.08),
		at(x, c.chestTop - 0.4, -c.chestD / 2 - 0.12),
		towel,
		Enum.Material.Fabric
	)
end

ACCESSORIES.Wristbands = function(c)
	for _, side in SIDES do
		local s, n = side[1], side[2]
		add(
			c,
			n .. "LowerArm",
			"Wristband",
			Vector3.new(c.A * 0.98, 0.18, c.A),
			at(s * c.armX, c.wristY + 0.12, 0),
			c.acc,
			Enum.Material.Fabric
		)
	end
end

ACCESSORIES.ChampBelt = function(c)
	local d = (if c.isBot then 0.86 else 0.92) + 0.06
	local w = math.max(c.waistW, 1.5) + 0.26
	add(c, "LowerTorso", "Belt", Vector3.new(w, 0.26, d), at(0, 2.4, 0), Color3.fromRGB(30, 26, 22), Enum.Material.Fabric)
	add(c, "LowerTorso", "BeltPlate", Vector3.new(0.66, 0.44, 0.08), at(0, 2.4, -d / 2 - 0.03), c.acc, Enum.Material.Metal)
end

ACCESSORIES.Cannon = function(c)
	local x = c.armX
	local dark = Color3.fromRGB(50, 52, 60)
	add(c, "RightLowerArm", "CannonHousing", Vector3.new(c.A + 0.16, 0.56, c.A + 0.2), at(x, c.wristY + 0.36, 0), dark, Enum.Material.Metal)
	add(
		c,
		"RightLowerArm",
		"CannonBarrel",
		Vector3.new(0.9, 0.42, 0.42),
		rot(x, c.wristY - 0.1, 0, 0, 0, 90),
		dark,
		Enum.Material.Metal,
		Enum.PartType.Cylinder
	)
	add(
		c,
		"RightLowerArm",
		"CannonMuzzle",
		Vector3.new(0.08, 0.34, 0.34),
		rot(x, c.wristY - 0.58, 0, 0, 0, 90),
		c.acc,
		Enum.Material.Neon,
		Enum.PartType.Cylinder
	)
end

-- Fan accessories -----------------------------------------------------------------

-- A bow on the top right of the head.
ACCESSORIES.Bow = function(c)
	local x = c.HW * 0.28
	local y = c.headTop + 0.16
	local z = -0.12
	local plain = Enum.Material.SmoothPlastic
	for _, side in SIDES do
		local s = side[1]
		add(c, "Head", "Bow", Vector3.new(0.3, 0.26, 0.12), rot(x + s * 0.17, y, z, 0, 0, s * 15), c.acc, plain)
	end
	add(c, "Head", "BowKnot", Vector3.new(0.14, 0.16, 0.15), at(x, y, z), shade(c.acc, 0.12), plain)
end

local function signLabel(card: BasePart, face: Enum.NormalId, text: string): TextLabel
	local gui = Instance.new("SurfaceGui")
	gui.Name = "SignGui"
	gui.Face = face
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 60
	gui.MaxDistance = 120
	gui.Parent = card
	local label = Instance.new("TextLabel")
	label.Name = "SignText"
	label.BackgroundTransparency = 1
	-- (The Lune unit-test environment has no UDim2.)
	if UDim2 ~= nil then
		label.Position = UDim2.fromScale(0.05, 0.27)
		label.Size = UDim2.fromScale(0.9, 0.66)
	end
	label.Font = Enum.Font.FredokaOne
	label.TextScaled = true
	label.TextColor3 = INK
	label.Text = text
	label.Parent = gui
	return label
end

-- A white card with a coloured header band on a wooden stick, held in the
-- right hand. The text (both faces) is the model's "SignText" attribute.
ACCESSORIES.FanSign = function(c)
	local x = c.armX + c.A / 2 + 0.08
	local bottom = c.wristY - 0.48
	-- Big enough to read as a sign from the plot's entrance.
	local stick = 2.2
	local cardW, cardH = 2.5, 1.55
	local cx = x + 0.5
	local cy = bottom + stick + cardH / 2 - 0.12
	local plain = Enum.Material.SmoothPlastic
	add(c, "RightHand", "SignStick", Vector3.new(0.1, stick, 0.1), at(x, bottom + stick / 2, 0), WOOD, plain)
	local card = add(c, "RightHand", "SignCard", Vector3.new(cardW, cardH, 0.1), at(cx, cy, 0), WHITE, plain)
	add(c, "RightHand", "SignHeader", Vector3.new(cardW + 0.02, 0.24, 0.12), at(cx, cy + cardH / 2 - 0.12, 0), c.acc, plain)
	local text = c.look.signText or SIGN_TEXT
	c.model:SetAttribute("SignText", text)
	local labels = { signLabel(card, Enum.NormalId.Front, text), signLabel(card, Enum.NormalId.Back, text) }
	-- Keep the text in sync with the attribute (no signals under Lune, hence pcall).
	local model = c.model
	pcall(function()
		model:GetAttributeChangedSignal("SignText"):Connect(function()
			local value = model:GetAttribute("SignText")
			for _, label in labels do
				label.Text = if type(value) == "string" then value else SIGN_TEXT
			end
		end)
	end)
end

-- Fluffy pom-poms in both hands.
ACCESSORIES.PomPoms = function(c)
	for _, side in SIDES do
		local s, n = side[1], side[2]
		local x, y = s * c.armX, c.wristY - 0.2
		add(c, n .. "Hand", "PomPom", Vector3.one * 0.8, at(x, y - 0.1, -0.04), c.acc, Enum.Material.Fabric, Enum.PartType.Ball)
		add(
			c,
			n .. "Hand",
			"PomPomPuff",
			Vector3.one * 0.5,
			at(x + s * 0.2, y - 0.4, -0.2),
			tint(c.acc, 0.4),
			Enum.Material.Fabric,
			Enum.PartType.Ball
		)
	end
end

-- A big foam "#1" hand on the right hand, index finger out along the arm.
ACCESSORIES.FoamFinger = function(c)
	local x, y = c.armX, c.wristY - 0.2
	local plain = Enum.Material.SmoothPlastic
	add(c, "RightHand", "FoamPalm", Vector3.new(0.66, 0.62, 0.38), at(x, y - 0.12, -0.02), c.acc, plain)
	add(c, "RightHand", "FoamFinger", Vector3.new(0.24, 0.8, 0.26), at(x - 0.15, y - 0.8, -0.02), c.acc, plain)
	add(c, "RightHand", "FoamThumb", Vector3.new(0.22, 0.36, 0.24), rot(x - 0.38, y - 0.2, -0.06, 0, 0, -30), shade(c.acc, 0.06), plain)
end

CharacterFactory.ACCESSORIES = ACCESSORIES

-- Effects -------------------------------------------------------------------------

-- Every size, rate and place of a unit's particles. They are kept small and start behind
-- the shoulders (a unit faces -Z), rising, so the body's silhouette reads from the front:
-- on the rack a tier is told by its aura's colour and rate and by its flame, not by a cloud.
-- Sizes and offsets are per unit of the look's scale.
local FX = {
	AuraSize = 0.32, -- particle size at birth (it shrinks to nothing)
	AuraRate = 5, -- particles per second when the look gives no auraRate ...
	AuraRateMax = 6, -- ... and the most any look gets
	AuraEmission = 0.6,
	AuraAlpha = 0.4, -- transparency at birth
	AuraLife = NumberRange.new(0.7, 1.1),
	AuraSpeed = { 0.8, 1.7 },
	AuraSpread = 70, -- degrees round straight up
	AuraLift = 4, -- upward acceleration
	AuraBack = 0.6, -- behind the chest's centre ...
	AuraUp = 0.3, -- ... and above it
	FireSize = 1.6, -- Fire.Size (it was 4: a blob over the whole torso)
	FireHeat = 9,
	FireBack = 0.75,
	FireUp = 0.7,
}

local function addEffects(c: Ctx)
	local look = c.look
	local chest = c.parts.UpperTorso
	local s = c.scale
	-- A point behind the shoulders for the aura and the flame.
	local function behind(name: string, back: number, up: number): Attachment
		local attachment = Instance.new("Attachment")
		attachment.Name = name
		attachment.Position = Vector3.new(0, up * s, back * s)
		attachment.Parent = chest
		return attachment
	end
	if look.aura then
		local emitter = Instance.new("ParticleEmitter")
		emitter.Name = "Aura"
		emitter.Color = ColorSequence.new(look.aura)
		emitter.LightEmission = FX.AuraEmission
		emitter.Size = NumberSequence.new({
			NumberSequenceKeypoint.new(0, FX.AuraSize * s),
			NumberSequenceKeypoint.new(1, 0),
		})
		emitter.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, FX.AuraAlpha),
			NumberSequenceKeypoint.new(1, 1),
		})
		emitter.Lifetime = FX.AuraLife
		emitter.Rate = math.min(look.auraRate or FX.AuraRate, FX.AuraRateMax)
		emitter.Speed = NumberRange.new(FX.AuraSpeed[1] * s, FX.AuraSpeed[2] * s)
		emitter.EmissionDirection = Enum.NormalId.Top
		emitter.SpreadAngle = Vector2.new(FX.AuraSpread, FX.AuraSpread)
		emitter.Acceleration = Vector3.new(0, FX.AuraLift, 0)
		emitter.Parent = behind("AuraAt", FX.AuraBack, FX.AuraUp)
	end
	if look.sparkles then
		local sparkles = Instance.new("Sparkles")
		sparkles.SparkleColor = look.aura or Color3.new(1, 1, 1)
		sparkles.Parent = chest
	end
	if look.fire then
		local fire = Instance.new("Fire")
		fire.Color = look.fire
		fire.SecondaryColor = Color3.new(1, 1, 1)
		fire.Size = FX.FireSize * s
		fire.Heat = FX.FireHeat
		fire.Parent = behind("FireAt", FX.FireBack, FX.FireUp)
	end
	if look.glow or look.aura then
		local light = Instance.new("PointLight")
		light.Color = look.glow or look.aura :: Color3
		-- Faint auras (low tiers) get a dimmer, smaller light.
		local strength = if look.glow then 1 else math.clamp((look.auraRate or 10) / 10, 0.35, 1)
		light.Brightness = 1.5 * strength
		light.Range = (5 + 3 * strength) * s
		light.Parent = chest
	end
end

-- Build ---------------------------------------------------------------------------

-- Builds a model standing on y = 0 at the origin, facing -Z. Its PrimaryPart
-- "Root" is at the feet, so model:PivotTo(CFrame) places the feet.
function CharacterFactory.build(look: Look, name: string?): Model
	local model = Instance.new("Model")
	model.Name = name or "Unit"
	local anim = animOf(look)
	local scale = look.scale or 1

	local accList: { string } = table.clone(look.acc or {})
	if look.prop and not table.find(accList, look.prop) then
		table.insert(accList, look.prop)
	end
	local has: { [string]: boolean } = {}
	for _, accName in accList do
		has[accName] = true
	end

	local c: Ctx = {
		model = model,
		look = look,
		scale = scale,
		mat = materialFrom(look.material),
		acc = look.accColor or Color3.fromRGB(255, 205, 60),
		trim = look.trim or Color3.fromRGB(58, 62, 72),
		isBot = anim == "Bot",
		cute = anim == "Fan",
		exprTag = nil,
		exprHidden = false,
		has = has,
		top = 0,
		parts = {},
		W = 2,
		chestD = 1,
		chestTop = 4,
		chestY = 3.5,
		waistW = 1.5,
		hipY = 2,
		A = 0.6,
		delt = 0.7,
		armX = 1.3,
		shoulderY = 3.9,
		wristY = 2.1,
		headY = 5,
		HW = 1.1,
		HH = 1.1,
		HD = 1.1,
		headTop = 5.6,
		hairTop = 5.6,
		eyeY = 5.1,
		led = look.faceColor or Color3.fromRGB(0, 220, 255),
	}

	-- Root sits at the feet so PivotTo keeps the unit standing on the floor.
	local root = Instance.new("Part")
	root.Name = "Root"
	root.Size = Vector3.new(0.2, 0.2, 0.2)
	root.CFrame = CFrame.new()
	root.Transparency = 1
	root.Anchored = true
	root.CanCollide = false
	root.CanQuery = false
	root.CanTouch = false
	root.CastShadow = false
	root.Parent = model
	model.PrimaryPart = root

	if c.isBot then
		buildBot(c)
	elseif c.cute then
		buildFan(c)
	else
		buildChad(c)
	end
	for _, accName in accList do
		local builder = ACCESSORIES[accName]
		if builder then
			builder(c)
		end
	end
	addEffects(c)

	model:SetAttribute("RigScale", scale)
	model:SetAttribute("AnimSet", anim)
	model:SetAttribute("Height", c.top * scale)
	if not look.manual then
		model:AddTag(TAG)
	end
	return model
end

-- Shows one of the expressions a model was built with (look.exprs) and hides
-- the others. Returns false if the model has no such expression.
function CharacterFactory.setExpression(model: Model, name: string): boolean
	local found = false
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") and d:GetAttribute("Expr") == name then
			found = true
			break
		end
	end
	if not found then
		return false
	end
	for _, d in model:GetDescendants() do
		local tag = d:GetAttribute("Expr")
		if tag ~= nil and d:IsA("BasePart") then
			d.Transparency = if tag == name then 0 else 1
		end
	end
	model:SetAttribute("Expression", name)
	return true
end

-- Changes the text on a model's FanSign (both faces).
function CharacterFactory.setSignText(model: Model, text: string)
	model:SetAttribute("SignText", text)
	for _, d in model:GetDescendants() do
		if d:IsA("TextLabel") and d.Name == "SignText" then
			d.Text = text
		end
	end
end

-- Turns a model into a black silhouette (for undiscovered Index entries).
function CharacterFactory.silhouette(model: Model)
	-- Collect first, destroy after, so we never visit children of a destroyed instance.
	local remove: { Instance } = {}
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then
			if d.Transparency < 1 then
				d.Color = Color3.fromRGB(15, 15, 20)
				d.Material = Enum.Material.SmoothPlastic
				d.Transparency = 0
			end
		elseif d:IsA("ParticleEmitter") or d:IsA("Sparkles") or d:IsA("Fire") or d:IsA("Light") or d:IsA("SurfaceGui") then
			table.insert(remove, d)
		end
	end
	for _, d in remove do
		d:Destroy()
	end
end

-- Height of the built model in studs (for placing labels above it).
local heights: { [Look]: number } = setmetatable({}, { __mode = "k" }) :: any
function CharacterFactory.height(look: Look): number
	local cached = heights[look]
	if cached then
		return cached
	end
	local model = CharacterFactory.build(look)
	local value = model:GetAttribute("Height")
	model:Destroy()
	local h = if type(value) == "number" then value else 5.6 * (look.scale or 1)
	heights[look] = h
	return h
end

return CharacterFactory
