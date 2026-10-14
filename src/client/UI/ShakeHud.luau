--!strict
--[[
	ShakeHud: the screen side of SHAKE CATCH (Modes.Shake; docs/minigames.md). Fx.Shake
	does the 3D side (falling items, the tray, the "+1" pops).

	  Run column   right edge, mid-height (like the Mog test): a glass score pill ("12 / 25"
	               with a star, the quiet X that asks "QUIT?" before ModeQuit), a chunky
	               bar toward the target (gold, mint once it is reached), three hearts and
	               the clock with the wave ("0:42 · WAVE 2/4").
	  Centre       the "3, 2, 1, GO!" count-in, the wave banners ("WAVE 3!", "FINAL WAVE!"),
	               "TARGET HIT!" when the score reaches the target.
	  Finish card  centre, on "win" / "lose": the title (SHAKE CHAMP! / NEW BEST! / OUT OF
	               HEARTS! / SO CLOSE!), score, target and best, the cash paid (or why none),
	               PLAY AGAIN / HOME, confetti on a win. It stays up after the run ends.

	Wired from Main.client.luau (nothing else needs editing):
	  init(screen)        once, builds the HUD (hidden)
	  onNotify(payload)   every Notify with kind = "Mode" and mode = "shake"; routes
	                      "start" -> start(payload) and "stop" -> stop(payload), plus this
	                      mode's "wave", "catch", "splat", "win", "lose"
	  onState(data)       every State snapshot (safety net: hides when modes.shake is not running)
	  start(payload) / stop(payload)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Format = require(ReplicatedStorage.Shared.Format) :: any
local Net = require(ReplicatedStorage.Shared.Net)

local Client = script.Parent.Parent
local Kit = require(script.Parent.Kit) :: any
local Popups = require(script.Parent.Popups) :: any
local Sounds = require(Client.Sounds) :: any

local ShakeHud = {}

local C = Kit.C
local F = Kit.F
local W = Kit.Theme.World

local action = Net.event("Action")

-- The run column (right edge, mid-height, like the Mog test).
local ROOT_W = 280
local ROOT_H = 160
local ROOT_RIGHT = 36
local ROOT_DY = 60
local PILL_W = 250
local BAR_W = 230
-- HUD chrome that steps aside during a run (the gift corner and the crate panel).
local CLUTTER = { "FreeCorner", "ChestPanel" }

local screen: ScreenGui? = nil
local root: Frame
local scoreLabel: TextLabel
local barFill: Frame
local heartsRow: Frame
local clockLabel: TextLabel
local quitButton: TextButton
local banner: TextLabel
local bannerSub: TextLabel
local finishCard: Frame
local finishTitle: TextLabel
local finishSub: TextLabel
local finishReward: TextLabel
local finishBest: TextLabel

local running = false
local quitArmed = false
local score = 0
local target = 25
local hearts = 3
local maxHearts = 3
local goAt = 0
local endAt = 0
local wave = 1
local waves = 4
local targetShown = false
local lastCount = -1
-- Banners: hide() bumps bannerEpoch to cancel every pending one; each banner has its own id
-- and only hides itself if it is still the one on screen (so they never cancel each other).
local bannerEpoch = 0
local bannerSeq = 0
local bannerShown = 0
-- Bumped on every finish card show / hide; the card's auto-dismiss checks it.
local finishToken = 0
-- The finish card closes itself after this many seconds.
local FINISH_HOLD = 20
local stepConn: RBXScriptConnection? = nil

local function num(value: any, default: number): number
	return if type(value) == "number" and value == value then value else default
end

-- Hearts (two discs and a 45-degree square, like the Mog test's) ---------------------------------

local function heart(parent: Instance, index: number): Frame
	local holder = Kit.new("Frame", {
		Name = "Heart" .. index,
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(30, 28),
		LayoutOrder = index,
		Parent = parent,
	})
	local scale = Kit.new("UIScale", { Parent = holder })
	scale.Name = "Pop"
	local function piece(name: string, x: number, y: number, rotation: number, round: boolean)
		local f = Kit.new("Frame", {
			Name = name,
			BackgroundColor3 = C.Bad,
			BorderSizePixel = 0,
			Size = UDim2.fromOffset(15, 15),
			Position = UDim2.fromOffset(x, y),
			AnchorPoint = Vector2.new(0.5, 0.5),
			Rotation = rotation,
			Parent = holder,
		})
		if round then
			Kit.round(f)
		else
			Kit.corner(f, 3)
		end
	end
	piece("Left", 10, 10, 0, true)
	piece("Right", 20, 10, 0, true)
	piece("Point", 15, 15.5, 45, false)
	return holder
end

local function setHearts(newHearts: number, animate: boolean)
	if #heartsRow:GetChildren() <= 1 then
		for i = 1, maxHearts do
			heart(heartsRow, i)
		end
	end
	for i = 1, maxHearts do
		local holder = heartsRow:FindFirstChild("Heart" .. i)
		if holder then
			local full = i <= newHearts
			local was = i <= hearts
			for _, f in holder:GetChildren() do
				if f:IsA("Frame") then
					Kit.tween(f, 0.25, { BackgroundColor3 = if full then C.Bad else C.Well })
				end
			end
			local pop = holder:FindFirstChild("Pop") :: UIScale?
			if animate and pop and was ~= full then
				pop.Scale = if full then 0.4 else 1.6
				Kit.tween(pop, 0.45, { Scale = 1 }, Enum.EasingStyle.Back)
			end
		end
	end
	hearts = newHearts
end

-- Score, banner, clock ---------------------------------------------------------------------------

local function paintScore(pop: boolean)
	scoreLabel.Text = string.format("%d / %d", score, target)
	local passed = score >= target
	local fill = math.clamp(score / math.max(target, 1), 0, 1)
	Kit.tween(barFill, 0.25, { Size = UDim2.fromScale(fill, 1), BackgroundColor3 = if passed then C.Good else C.Gold })
	if pop then
		Kit.pop(scoreLabel, 1.25)
	end
end

local function showBanner(title: string, sub: string?, color: Color3, hold: number, delay: number?)
	bannerSeq += 1
	local id, epoch = bannerSeq, bannerEpoch
	task.delay(delay or 0, function()
		if epoch ~= bannerEpoch or not running then
			return
		end
		bannerShown = id
		banner.Text = title
		banner.TextColor3 = color
		bannerSub.Text = sub or ""
		banner.Visible = true
		Kit.appear(banner, { from = 0.35, time = 0.35 })
		task.delay(hold, function()
			if epoch == bannerEpoch and bannerShown == id then
				Kit.disappear(banner)
			end
		end)
	end)
end

local function render()
	if not running then
		return
	end
	local now = Workspace:GetServerTimeNow()
	local left = math.max(0, math.ceil(endAt - now))
	local toGo = goAt - now
	if toGo > 0 then
		local n = math.ceil(toGo)
		if n ~= lastCount then
			lastCount = n
			showBanner(tostring(n), "Get under the shakes!", W.Sunny, 0.8)
			Sounds.play("Tick")
		end
		left = math.ceil(endAt - goAt)
	elseif lastCount > 0 then
		lastCount = 0
		showBanner("GO!", "Catch shakes, dodge junk food!", C.Good, 1.2)
		Sounds.play("Ready")
	end
	clockLabel.Text = string.format("%s · WAVE %d/%d", Format.clock(left), wave, waves)
	clockLabel.TextColor3 = if left <= 10 and toGo <= 0 then C.Bad else Color3.new(1, 1, 1)
end

-- Chrome -------------------------------------------------------------------------------------

local stashed: { [GuiObject]: boolean } = {}
local function setChrome(on: boolean)
	Kit.hidePlayerList("shake", on)
	local gui = screen
	if not gui then
		return
	end
	gui:SetAttribute("RunActive", on)
	if on then
		for _, name in CLUTTER do
			local block = gui:FindFirstChild(name)
			if block and block:IsA("GuiObject") and stashed[block] == nil then
				stashed[block] = block.Visible
				block.Visible = false
			end
		end
	else
		for block, was in stashed do
			block.Visible = was
		end
		table.clear(stashed)
	end
end

local function resetQuit()
	quitArmed = false
	Kit.setButton(quitButton, "X", C.SurfaceHi)
	quitButton.Size = UDim2.fromOffset(44, 44)
end

local function hideFinish()
	finishToken += 1
	Kit.unfocus(finishCard)
	if finishCard.Visible then
		Kit.disappear(finishCard)
	end
end

-- Finish card --------------------------------------------------------------------------------

local function showFinish(p: { [string]: any }, won: boolean)
	local s, t, best = num(p.score, score), num(p.target, target), num(p.best, 0)
	local newBest = p.newBest == true and s > 0
	finishTitle.Text = if won
		then (if newBest then "NEW BEST!" else "SHAKE CHAMP!")
		elseif p.why == "hearts" then "OUT OF HEARTS!"
		else "SO CLOSE!"
	finishTitle.TextColor3 = if won then C.Gold else W.Coral
	finishSub.Text = string.format("Score %d  ·  Target %d", s, t)
	finishBest.Text = if newBest then "Best: " .. s .. " (new!)" else "Best: " .. best
	local cash = num(p.cash, 0)
	if not won then
		finishReward.Text = if p.why == "hearts"
			then "Dodge the junk food! Catch " .. t .. " to win cash."
			else "Catch " .. t .. " to win cash!"
		finishReward.TextColor3 = C.Text
	elseif cash > 0 then
		finishReward.Text = (if p.pay == "repeat" then "Run again bonus +" else "+") .. Format.money(cash)
		finishReward.TextColor3 = C.MoneyText
	elseif p.pay == "resting" then
		finishReward.Text = "Bonus is resting. Play again soon!"
		finishReward.TextColor3 = C.Text
	else
		local wait = math.max(0, num(p.cooldownEnds, 0) - os.time())
		finishReward.Text = "Full reward in " .. Format.clock(wait)
		finishReward.TextColor3 = C.Text
	end
	finishCard.Visible = true
	Kit.appear(finishCard, { from = 0.5, time = 0.35 })
	finishToken += 1
	local token = finishToken
	task.delay(FINISH_HOLD, function()
		if token == finishToken and finishCard.Visible then
			hideFinish()
		end
	end)
	Kit.focus(finishCard)
	task.defer(function()
		Kit.select(Kit.firstSelectable(finishCard))
	end)
	if won then
		Kit.confetti(finishCard, { Count = if cash > 0 then 36 else 20, Origin = UDim2.fromScale(0.5, 0.2), ZIndex = 55 })
		Sounds.play(if p.first == true then "CelebrateLegendary" else "Celebrate")
		if cash > 0 then
			Kit.countTo(finishReward, 0, cash, function(n: number)
				return (if p.pay == "repeat" then "Run again bonus +" else "+") .. Format.money(n)
			end, 0.9)
		end
	else
		Sounds.play("Close")
	end
end

-- Lifecycle ----------------------------------------------------------------------------------

local function hide()
	running = false
	bannerEpoch += 1
	bannerShown = 0
	banner.Visible = false
	if stepConn then
		stepConn:Disconnect()
		stepConn = nil
	end
	setChrome(false)
	if root.Visible then
		Kit.disappear(root)
	end
end

function ShakeHud.start(payload: { [string]: any }?)
	if not screen then
		return
	end
	local p: { [string]: any } = payload or {}
	hideFinish()
	running = true
	score = 0
	target = num(p.target, 25)
	maxHearts = num(p.hearts, 3)
	hearts = maxHearts
	goAt = num(p.goAt, Workspace:GetServerTimeNow() + 3)
	endAt = num(p.endAt, goAt + num(p.seconds, 60))
	wave, waves = 1, num(p.waves, 4)
	targetShown = false
	lastCount = -1
	resetQuit()
	for _, child in heartsRow:GetChildren() do
		if child:IsA("Frame") then
			child:Destroy()
		end
	end
	setHearts(hearts, false)
	paintScore(false)
	root.Visible = true
	Kit.appear(root, { from = 0.6, time = 0.3 })
	setChrome(true)
	if not stepConn then
		stepConn = RunService.RenderStepped:Connect(render)
	end
	render()
end

function ShakeHud.stop(payload: { [string]: any }?)
	local was = running
	if not root then
		return
	end
	hide()
	hideFinish()
	if was and payload and payload.reason == "quit" then
		Popups.toast("Shake Catch ended", "info")
	end
end

function ShakeHud.onNotify(payload: { [string]: any })
	if not screen or type(payload) ~= "table" then
		return
	end
	local event = payload.event
	if event == "start" then
		ShakeHud.start(payload)
	elseif event == "stop" then
		ShakeHud.stop(payload)
	elseif event == "win" or event == "lose" then
		hide()
		showFinish(payload, event == "win")
	elseif not running then
		return
	elseif event == "wave" then
		local n = num(payload.wave, 1)
		if n > 1 then
			local delay = math.max(0, num(payload.at, 0) - Workspace:GetServerTimeNow())
			task.delay(delay, function()
				if running then
					wave = n
				end
			end)
			local last = n >= num(payload.waves, waves)
			showBanner(
				if last then "FINAL WAVE!" else "WAVE " .. n .. "!",
				if last then "Faster and faster!" else "Faster!",
				if last then W.Coral else W.Sunny,
				1.6,
				delay
			)
			task.delay(delay, function()
				if running then
					Sounds.play("Ready")
				end
			end)
		end
	elseif event == "catch" then
		score = num(payload.score, score)
		paintScore(true)
		if score >= target and not targetShown then
			targetShown = true
			showBanner("TARGET HIT!", "Keep catching for a best!", C.Gold, 1.6)
			Sounds.play("Upgrade")
		end
	elseif event == "splat" then
		setHearts(num(payload.hearts, hearts - 1), true)
		Kit.pop(heartsRow, 1.2)
	end
end

function ShakeHud.onState(data: any)
	local info = type(data) == "table" and type(data.modes) == "table" and data.modes.shake
	if running and not (type(info) == "table" and info.running == true) then
		ShakeHud.stop(nil)
	elseif not running and finishCard and finishCard.Visible and type(data) == "table" and type(data.modes) == "table" then
		-- Not running any more and another mode has started: the finish card is stale.
		-- (Right after a finish nothing runs, so the card stays until dismissed or timed out.)
		for _, other in data.modes do
			if type(other) == "table" and other.running == true then
				hideFinish()
				break
			end
		end
	end
end

-- Build --------------------------------------------------------------------------------------

local function buildFinish(screenGui: ScreenGui)
	finishCard = Kit.panel(screenGui, {
		Name = "ShakeFinish",
		Size = UDim2.fromOffset(420, 270),
		Position = UDim2.fromScale(0.5, 0.48),
		AnchorPoint = Vector2.new(0.5, 0.5),
		Visible = false,
		ZIndex = 50,
		Elevated = true,
		StrokeColor = C.Gold,
		StrokeThickness = 3,
	})
	Kit.icon(finishCard, "Star", 64, C.Gold, {
		Position = UDim2.new(0.5, 0, 0, -30),
		AnchorPoint = Vector2.new(0.5, 0),
		ZIndex = 52,
	})
	finishTitle = Kit.title(finishCard, {
		Name = "Title",
		Text = "SHAKE CHAMP!",
		TextSize = 38,
		TextColor3 = C.Gold,
		Size = UDim2.new(1, -20, 0, 44),
		Position = UDim2.fromOffset(10, 40),
		ZIndex = 51,
	})
	finishSub = Kit.text(finishCard, {
		Name = "Sub",
		Text = "",
		Font = F.UI,
		TextSize = 18,
		TextColor3 = C.Text,
		Size = UDim2.new(1, -20, 0, 22),
		Position = UDim2.fromOffset(10, 88),
		ZIndex = 51,
	})
	finishBest = Kit.text(finishCard, {
		Name = "Best",
		Text = "",
		Font = F.UI,
		TextSize = 15,
		TextColor3 = C.TextDim,
		Size = UDim2.new(1, -20, 0, 20),
		Position = UDim2.fromOffset(10, 112),
		ZIndex = 51,
	})
	finishReward = Kit.number(finishCard, {
		Name = "Reward",
		Text = "",
		TextSize = 24,
		TextColor3 = C.MoneyText,
		Size = UDim2.new(1, -20, 0, 32),
		Position = UDim2.fromOffset(10, 140),
		ZIndex = 51,
	})
	local again = Kit.button(finishCard, {
		Name = "Again",
		Text = "PLAY AGAIN",
		Color = C.Good,
		Font = F.Display,
		TextSize = 20,
		Size = UDim2.fromOffset(170, 50),
		Position = UDim2.new(0.5, -8, 1, -18),
		AnchorPoint = Vector2.new(1, 1),
		ZIndex = 52,
		Breathe = true,
	}, function()
		hideFinish()
		action:FireServer({ action = "ModeStart", mode = "shake" })
	end)
	local home = Kit.button(finishCard, {
		Name = "Home",
		Text = "HOME",
		Color = C.SurfaceHi,
		Font = F.Display,
		TextSize = 20,
		Size = UDim2.fromOffset(150, 50),
		Position = UDim2.new(0.5, 8, 1, -18),
		AnchorPoint = Vector2.new(0, 1),
		ZIndex = 52,
	}, function()
		hideFinish()
		action:FireServer({ action = "Home" })
	end)
	Kit.selectable(again)
	Kit.selectable(home)
end

function ShakeHud.init(screenGui: ScreenGui)
	screen = screenGui
	root = Kit.new("Frame", {
		Name = "ShakeHud",
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(ROOT_W, ROOT_H),
		Position = UDim2.new(1, -ROOT_RIGHT, 0.5, ROOT_DY),
		AnchorPoint = Vector2.new(1, 0.5),
		Visible = false,
		ZIndex = 20,
		Parent = screenGui,
	})

	-- Score pill with the quiet quit button on its right end.
	local pill = Kit.hudGlass(root, {
		Name = "Score",
		Size = UDim2.fromOffset(PILL_W, 54),
		Position = UDim2.new(0.5, 0, 0, 0),
		AnchorPoint = Vector2.new(0.5, 0),
	})
	Kit.icon(pill, "Star", 26, C.Gold, { Position = UDim2.new(0, 10, 0.5, 0), AnchorPoint = Vector2.new(0, 0.5), ZIndex = 3 })
	scoreLabel = Kit.hudText(pill, {
		Name = "Value",
		Text = "0 / 25",
		Font = F.Number,
		TextSize = 26,
		StrokeThickness = 2,
		TextXAlignment = Enum.TextXAlignment.Left,
		Size = UDim2.new(1, -100, 1, 0),
		Position = UDim2.fromOffset(44, 0),
		ZIndex = 3,
	})
	quitButton = Kit.button(pill, {
		Name = "Quit",
		Text = "X",
		Color = C.SurfaceHi,
		TextSize = 18,
		Size = UDim2.fromOffset(44, 44),
		Position = UDim2.new(1, -5, 0.5, 0),
		AnchorPoint = Vector2.new(1, 0.5),
		Radius = 22,
		Depth = 2,
		ZIndex = 4,
	}, function()
		if quitArmed then
			resetQuit()
			action:FireServer({ action = "ModeQuit" })
			return
		end
		-- First tap arms it: "QUIT?" for a few seconds.
		quitArmed = true
		Kit.setButton(quitButton, "QUIT?", C.Bad)
		Kit.tween(quitButton, 0.2, { Size = UDim2.fromOffset(96, 44) }, Enum.EasingStyle.Back)
		task.delay(3, function()
			if quitArmed then
				resetQuit()
			end
		end)
	end)
	Kit.selectable(quitButton)

	-- The bar toward the target.
	local bar = Kit.new("Frame", {
		Name = "TargetBar",
		BackgroundColor3 = C.Well,
		BorderSizePixel = 0,
		Size = UDim2.fromOffset(BAR_W, 14),
		Position = UDim2.new(0.5, 0, 0, 62),
		AnchorPoint = Vector2.new(0.5, 0),
		Parent = root,
	})
	Kit.round(bar)
	Kit.stroke(bar, 2, W.Ink)
	barFill = Kit.new("Frame", {
		Name = "Fill",
		BackgroundColor3 = C.Gold,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(0, 1),
		Parent = bar,
	})
	Kit.round(barFill)

	heartsRow = Kit.new("Frame", {
		Name = "Hearts",
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(200, 28),
		Position = UDim2.new(0.5, 0, 0, 86),
		AnchorPoint = Vector2.new(0.5, 0),
		Parent = root,
	})
	Kit.list(heartsRow, 6, true, Enum.HorizontalAlignment.Center)

	clockLabel = Kit.hudText(root, {
		Name = "Clock",
		Text = "1:00 · WAVE 1/4",
		Font = F.Display,
		TextSize = 22,
		Size = UDim2.new(1, 0, 0, 28),
		Position = UDim2.fromOffset(0, 122),
	})

	-- The centre banner (count-in, waves, target).
	banner = Kit.hudText(screenGui, {
		Name = "ShakeBanner",
		Text = "",
		Font = F.Display,
		TextSize = 64,
		StrokeThickness = 4,
		Size = UDim2.fromOffset(600, 76),
		Position = UDim2.fromScale(0.5, 0.26),
		AnchorPoint = Vector2.new(0.5, 0.5),
		Visible = false,
		ZIndex = 30,
	})
	bannerSub = Kit.hudText(banner, {
		Name = "Sub",
		Text = "",
		Font = F.Display,
		TextSize = 24,
		Size = UDim2.new(1, 0, 0, 30),
		Position = UDim2.new(0, 0, 1, 2),
		ZIndex = 30,
	})

	buildFinish(screenGui)
end

return ShakeHud
