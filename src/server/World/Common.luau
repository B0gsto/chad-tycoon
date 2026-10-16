--[[
	Common: constants, part/label/billboard primitives and shared types for the world modules.
	Part of the world generator; see Server.WorldBuilder for the overview and plot axes.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Economy = require(ReplicatedStorage.Shared.Economy)
local Layout = require(script.Parent.Parent.PlotLayout)

local Common = {}

-- The theme module and the Map folder every world module builds into.
local theme: any = require(ReplicatedStorage:WaitForChild("Theme"))
local mapFolder = Instance.new("Folder")
mapFolder.Name = "Map"

local PLOT_COUNT = 6
local PLOT_HALF = Layout.PLOT_HALF

-- Rotations for cylinders (a Roblox cylinder's axis is its X axis).
local UPRIGHT = CFrame.Angles(0, 0, math.rad(90))
local ALONG_Z = CFrame.Angles(0, math.rad(90), 0)

local WHITE = Color3.new(1, 1, 1)

-- Shared sign style: a cream card with a thin teal border, a red-orange header band with a
-- white title and Ink body text. Small tags (rack row numbers) fade out beyond SIGN_FADE_TAG
-- studs and plot sign cards beyond SIGN_FADE_CARD, so other plots' signs drop out of view.
local SIGN = {
	Card = theme.World.Cream,
	Header = theme.World.RedOrange,
	Title = theme.World.White,
	Text = theme.World.Ink,
	Border = theme.World.Teal,
}
local SIGN_FADE_TAG = 80
local SIGN_FADE_CARD = 120

-- Warm white used to light the display units.
local SHELF_LIGHT = Color3.fromRGB(255, 236, 205)

export type Rect = Layout.Rect

export type Pad = {
	name: string,
	center: Vector3,
	half: Vector2,
	part: BasePart,
	title: TextLabel,
	sub: TextLabel,
	-- The cyan line between the name and the price: what the pad does ("+5 Chad").
	effect: TextLabel,
	-- Redraws the floating label from `title`, `effect` and `sub`: Server.Tycoon calls it after
	-- writing them.
	redraw: () -> (),
	-- What `title`, `effect` and `sub` say (and sub's tint) on a plot nobody owns:
	-- Server.Tycoon puts them back when the owner leaves.
	defaultTitle: string,
	defaultEffect: string,
	defaultSub: string,
	defaultTint: Color3,
}
-- Primitives ------------------------------------------------------------------------

local function make(className: string, props: { [string]: any }): BasePart
	local p = Instance.new(className) :: BasePart
	p.Anchored = true
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Material = Enum.Material.SmoothPlastic
	for key, value in props do
		if key ~= "Parent" then
			(p :: any)[key] = value
		end
	end
	p.Parent = props.Parent or mapFolder
	return p
end

local function part(props: { [string]: any }): BasePart
	return make("Part", props)
end

local function stroke(parent: Instance, thickness: number?)
	local s = Instance.new("UIStroke")
	s.Thickness = thickness or 2
	s.Color = theme.Colors.Stroke
	s.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
	s.Parent = parent
end

local function label(parent: Instance, props: { [string]: any }): TextLabel
	local l = Instance.new("TextLabel")
	l.BackgroundTransparency = 1
	l.TextScaled = true
	l.Font = theme.Fonts.Title
	l.TextColor3 = theme.Colors.Text
	l.Size = UDim2.fromScale(1, 0.3)
	for key, value in props do
		(l :: any)[key] = value
	end
	stroke(l, props.StrokeThickness)
	l.Parent = parent
	return l
end

local function billboard(adornee: BasePart, offsetY: number, width: number, height: number): BillboardGui
	local gui = Instance.new("BillboardGui")
	gui.Size = UDim2.fromScale(width, height)
	gui.StudsOffset = Vector3.new(0, offsetY, 0)
	gui.LightInfluence = 0
	gui.MaxDistance = 60
	gui.Adornee = adornee
	gui.Parent = adornee
	return gui
end

-- Billboards made by other modules (unit name tags, crate labels) are drawn 25% smaller so the
-- plot stays readable; callers can still override MaxDistance.
local EXTERNAL_BILLBOARD_SCALE = 0.75
local function externalBillboard(adornee: BasePart, offsetY: number, width: number, height: number): BillboardGui
	return billboard(adornee, offsetY, width * EXTERNAL_BILLBOARD_SCALE, height * EXTERNAL_BILLBOARD_SCALE)
end

-- Hub ring: two rows of three plots facing a round plaza. Plot centres sit at
-- (col * PLOT_SPACING_X, row * PLOT_ROW_Z) for col = -1..1, row = +-1, so entrances are at
-- |z| = ENTRANCE_Z. The cross avenue runs along |z| = CROSS_Z between the plaza and the plots.
local HUB_RADIUS = 32
local PLOT_SPACING_X = PLOT_HALF * 2 + 10
local CROSS_Z = HUB_RADIUS + 12
local PLOT_ROW_Z = CROSS_Z + 10 + PLOT_HALF
local ENTRANCE_Z = PLOT_ROW_Z - PLOT_HALF

local function plotCFrame(index: number): CFrame
	local row = if index <= 3 then 1 else -1
	local col = ((index - 1) % 3) - 1
	-- Face the hub: the plot's -Z (its entrance) points toward z = 0. Same result
	-- as CFrame.lookAt, but exact everywhere (Lune's lookAt, used by the preview,
	-- flips this case).
	return CFrame.new(col * PLOT_SPACING_X, 0, row * PLOT_ROW_Z) * CFrame.Angles(0, if row == 1 then 0 else math.pi, 0)
end

export type Builder = {
	cf: CFrame,
	folder: Folder,
	c: any,
	L: (x: number, y: number, z: number) -> CFrame,
	P: (props: { [string]: any }) -> BasePart,
	W: (props: { [string]: any }) -> BasePart,
}
-- Colour of a tier's rarity band (matches the client's tier colours).
local function tierBandColor(tier: number): Color3
	return theme.Colors.Rarity[Economy.tierBand(tier)] or theme.Colors.Primary
end

Common.PLOT_COUNT = PLOT_COUNT
Common.PLOT_HALF = PLOT_HALF
Common.UPRIGHT = UPRIGHT
Common.ALONG_Z = ALONG_Z
Common.WHITE = WHITE
Common.SIGN = SIGN
Common.SIGN_FADE_TAG = SIGN_FADE_TAG
Common.SIGN_FADE_CARD = SIGN_FADE_CARD
Common.SHELF_LIGHT = SHELF_LIGHT
Common.make = make
Common.part = part
Common.label = label
Common.externalBillboard = externalBillboard
Common.plotCFrame = plotCFrame
Common.HUB_RADIUS = HUB_RADIUS
Common.PLOT_SPACING_X = PLOT_SPACING_X
Common.PLOT_ROW_Z = PLOT_ROW_Z
Common.CROSS_Z = CROSS_Z
Common.ENTRANCE_Z = ENTRANCE_Z
Common.tierBandColor = tierBandColor
Common.theme = theme
Common.mapFolder = mapFolder

return Common
