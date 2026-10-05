--[[
	Guide: points the player at something on their plot.

	  - a glowing Beam from the character's feet to the target
	  - a bouncing arrow (BillboardGui) above the target with a short label
	  - a Highlight on the target part

	Targets are pad names ("Buy1", "Deposit", ...; found as
	workspace.Map.Plot<n>.Pad_<name>) or "Orbs" (the nearest orb on the plot,
	else the middle of the field). Everything is client-only.

	Two sources can ask for a target: the tutorial (persistent) and a short
	"navigate" request (e.g. the Free reward button), which wins while active.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Kit = require(script.Parent.UI.Kit)
local State = require(script.Parent.State)

local C = Kit.C

local Guide = {}

local folder: Folder
local anchor: Part
local beam: Beam
local arrow: BillboardGui
local arrowLabel: TextLabel
local distanceLabel: TextLabel
local highlight: Highlight

local tutorialTarget: string? = nil
local tutorialText = ""
local navTarget: string? = nil
local navText = ""
local navUntil = 0

local currentPart: BasePart? = nil
local lastResolve = 0

local function plotFolder(): Instance?
	local data = State.data
	local map = Workspace:FindFirstChild("Map")
	if not data or not map or not data.plotIndex then
		return nil
	end
	return map:FindFirstChild("Plot" .. data.plotIndex)
end

local function rootPart(): BasePart?
	local character = Players.LocalPlayer.Character
	return character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
end

local function resolve(name: string): BasePart?
	local plot = plotFolder()
	if not plot then
		return nil
	end
	if name == "Orbs" then
		local orbs = plot:FindFirstChild("Orbs", true)
		local root = rootPart()
		local best: BasePart? = nil
		local bestDistance = math.huge
		if orbs and root then
			local from = root.CFrame.Position
			for _, orb in orbs:GetChildren() do
				if orb:IsA("BasePart") then
					local d = (orb.CFrame.Position - from).Magnitude
					if d < bestDistance then
						best, bestDistance = orb, d
					end
				end
			end
		end
		if best then
			return best
		end
		return (plot:FindFirstChild("Field", true) or plot:FindFirstChild("Floor", true)) :: BasePart?
	end
	return plot:FindFirstChild("Pad_" .. name, true) :: BasePart?
end

local function activeTarget(): (string?, string)
	if navTarget and os.clock() < navUntil then
		return navTarget, navText
	end
	navTarget = nil
	return tutorialTarget, tutorialText
end

local function buildArrow(parent: Instance)
	arrow = Kit.new("BillboardGui", {
		Name = "GuideArrow",
		Size = UDim2.fromOffset(150, 170),
		StudsOffsetWorldSpace = Vector3.new(0, 7, 0),
		AlwaysOnTop = true,
		LightInfluence = 0,
		MaxDistance = 1000,
		ResetOnSpawn = false,
		Enabled = false,
		Parent = parent,
	})
	arrowLabel = Kit.pill(arrow, {
		Name = "Label",
		Text = "",
		Color = C.Panel,
		TextColor = C.Primary,
		TextSize = 20,
		Size = UDim2.fromOffset(0, 32),
		AutomaticSize = Enum.AutomaticSize.X,
		Position = UDim2.new(0.5, 0, 0, 0),
		AnchorPoint = Vector2.new(0.5, 0),
	})
	local shaft = Kit.new("Frame", {
		Name = "Shaft",
		BackgroundColor3 = C.Primary,
		Size = UDim2.fromOffset(30, 46),
		Position = UDim2.new(0.5, 0, 0, 44),
		AnchorPoint = Vector2.new(0.5, 0),
		Parent = arrow,
	})
	Kit.corner(shaft, 6)
	Kit.stroke(shaft, 4)
	local head = Kit.new("Frame", {
		Name = "Head",
		BackgroundColor3 = C.Primary,
		Size = UDim2.fromOffset(56, 56),
		Position = UDim2.new(0.5, 0, 0, 98),
		AnchorPoint = Vector2.new(0.5, 0.5),
		Rotation = 45,
		ZIndex = 2,
		Parent = arrow,
	})
	Kit.corner(head, 6)
	Kit.stroke(head, 4)
	Kit.gradient(head, Kit.lighten(C.Primary, 0.3), C.Primary, -45)
	-- Covers the head's upper outline so the shaft flows into it.
	Kit.new("Frame", {
		Name = "Join",
		BackgroundColor3 = C.Primary,
		BorderSizePixel = 0,
		Size = UDim2.fromOffset(30, 42),
		Position = UDim2.new(0.5, 0, 0, 56),
		AnchorPoint = Vector2.new(0.5, 0),
		ZIndex = 3,
		Parent = arrow,
	})
	distanceLabel = Kit.title(arrow, {
		Name = "Distance",
		Text = "",
		TextSize = 18,
		TextWrapped = false,
		Size = UDim2.new(1, 0, 0, 22),
		Position = UDim2.new(0, 0, 1, -22),
		StrokeThickness = 2,
	})
end

function Guide.build()
	folder = Instance.new("Folder")
	folder.Name = "ClientGuide"
	folder.Parent = Workspace

	anchor = Instance.new("Part")
	anchor.Name = "GuideAnchor"
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanQuery = false
	anchor.CanTouch = false
	anchor.Transparency = 1
	anchor.Size = Vector3.new(1, 1, 1)
	anchor.Parent = folder
	local targetAttachment = Instance.new("Attachment")
	targetAttachment.Name = "To"
	targetAttachment.Parent = anchor

	beam = Instance.new("Beam")
	beam.Name = "GuideBeam"
	beam.Attachment1 = targetAttachment
	beam.Color = ColorSequence.new(C.Primary)
	beam.LightEmission = 1
	beam.LightInfluence = 0
	beam.FaceCamera = true
	beam.Width0 = 1.1
	beam.Width1 = 1.6
	beam.Segments = 20
	beam.Enabled = false
	beam.Parent = folder

	highlight = Instance.new("Highlight")
	highlight.Name = "GuideHighlight"
	highlight.FillColor = C.Primary
	highlight.OutlineColor = Color3.new(1, 1, 1)
	highlight.FillTransparency = 0.55
	highlight.DepthMode = Enum.HighlightDepthMode.Occluded
	highlight.Enabled = false
	highlight.Parent = folder

	buildArrow(anchor)

	local clock = 0
	RunService.Heartbeat:Connect(function(dt)
		clock += dt
		Guide.update(clock)
	end)
end

local function setVisible(on: boolean)
	arrow.Enabled = on
	highlight.Enabled = on
	if not on then
		beam.Enabled = false
		currentPart = nil
	end
end

-- One frame of guide work (also called directly by the preview exporter).
function Guide.update(clock: number)
	local name, text = activeTarget()
	if not name then
		setVisible(false)
		return
	end
	if os.clock() - lastResolve > 0.25 or not currentPart or not currentPart.Parent then
		lastResolve = os.clock()
		currentPart = resolve(name)
	end
	local part = currentPart
	if not part then
		setVisible(false)
		return
	end
	setVisible(true)
	arrowLabel.Text = text
	highlight.Adornee = part
	local position = part.CFrame.Position
	anchor.CFrame = CFrame.new(position + Vector3.new(0, 0.6, 0))
	arrow.StudsOffsetWorldSpace = Vector3.new(0, 7 + math.sin(clock * 4) * 0.7, 0)

	local root = rootPart()
	if root then
		local from = root:FindFirstChild("GuideFrom") :: Attachment?
		if not from then
			local created = Instance.new("Attachment")
			created.Name = "GuideFrom"
			created.CFrame = CFrame.new(0, -2.5, 0)
			created.Parent = root
			from = created
		end
		beam.Attachment0 = from
		local distance = (root.CFrame.Position - position).Magnitude
		beam.Enabled = distance > 9
		distanceLabel.Text = if distance > 9 then string.format("%dm", math.floor(distance / 3.5 + 0.5)) else ""
		-- Bright bands flowing toward the target.
		local phase = (clock * 0.9) % 1
		local points = { NumberSequenceKeypoint.new(0, 0.85) }
		for i = 0, 2 do
			local center = (phase + i / 3) % 1
			if center > 0.06 and center < 0.94 then
				table.insert(points, NumberSequenceKeypoint.new(center - 0.05, 0.75))
				table.insert(points, NumberSequenceKeypoint.new(center, 0.1))
				table.insert(points, NumberSequenceKeypoint.new(center + 0.05, 0.75))
			end
		end
		table.insert(points, NumberSequenceKeypoint.new(1, 0.4))
		table.sort(points, function(a, b)
			return a.Time < b.Time
		end)
		beam.Transparency = NumberSequence.new(points)
	end
	highlight.FillTransparency = 0.55 + math.sin(clock * 5) * 0.2
end

function Guide.setTutorialTarget(name: string?, text: string?)
	if name ~= tutorialTarget then
		currentPart = nil
	end
	tutorialTarget = name
	tutorialText = text or ""
end

-- Temporary target that overrides the tutorial for `seconds`.
function Guide.navigate(name: string?, text: string?, seconds: number?)
	navTarget = name
	navText = text or ""
	navUntil = os.clock() + (seconds or 30)
	currentPart = nil
end

function Guide.clearNavigate(name: string)
	if navTarget == name then
		navTarget = nil
		currentPart = nil
	end
end

return Guide
