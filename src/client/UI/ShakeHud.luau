--!strict
--[[
	ShakeHud: the screen side of SHAKE CATCH (Modes.Shake; docs/minigames.md, "Lobby first,
	then the game"). Fx.Shake does the 3D side (falling items, the tray, the practice drops).

	Phases (modes.shake.phase in the snapshot, mirrored by the Notify events):
	  lobby      the lobby card (right edge, mid-height): SHAKE CATCH, the goal, best and
	             clears, the reward status (full pack ready, or the wait and the repeat
	             share), a big PLAY (tap, Enter, gamepad X: "ShakeBegin"; gamepad A stays
	             jump; Enter is left alone while a window is open or a TextBox has focus) and
	             LEAVE ("ModeQuit"). The run HUD is hidden.
	  countdown  a big "3, 2, 1, GO!" in the centre ("go" ends it); the run column comes up.
	  play       the run column (right edge, mid-height, like the Mog test): a glass score pill
	             ("12 / 25" with a star, the quiet X that asks "QUIT?" before ModeQuit; gamepad
	             Y presses it, a Y badge shows while a gamepad is in use), a
	             chunky bar toward the target, three hearts and the clock with the wave
	             ("0:42 · WAVE 2/4"). Wave banners and "TARGET HIT!" in the centre; a red
	             edge flash when a heart goes.
	  results    the results card on "win" / "lose": title, catches and score, best (a
	             flashing NEW BEST!), the pay (or why none), the three stars (ShakeRules.STARS:
	             lit for each tier reached, with the star bonus or the next star's points),
	             PLAY AGAIN ("ShakeBegin"; Enter,
	             gamepad X) and LOBBY ("ShakeLobby", counting down to the server's returnAt).
	             It goes on the "lobby" event (or the snapshot's phase back to lobby).

	The arena's "BestBoard" SurfaceGui (under the arena Model, attribute Mode = "shake") gets
	its TextLabels "Best", "Clears" and "Reward" (each optional) filled from the snapshot, and
	"RewardCaption" says what the reward value is (the pack ready, a star bonus ready, or the
	wait for the pack).

	Touch: the lobby card and the run column sit higher on the right edge, clear of the jump
	button (and the thumbstick on the left).

	Wired from Main.client.luau (nothing else needs editing):
	  init(screen)        once, builds the HUD (hidden)
	  onNotify(payload)   every Notify with kind = "Mode" and mode = "shake"
	  onState(data)       every State snapshot (phase changes, best board, safety net)
	  start(payload) / stop(payload)
]]

local ContextActionService = game:GetService("ContextActionService")
local UserInputService = game:GetService("UserInputService")
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
-- On touch the column and the lobby card ride higher (the jump button owns the bottom right).
local TOUCH_RIGHT = 16
local TOUCH_DY = -40
local PILL_W = 250
local BAR_W = 230
-- The lobby card (same spot as the run column).
local LOBBY_W = 300
local LOBBY_H = 250
-- HUD chrome that steps aside while the player is in the mode (the gift corner, the crates).
local CLUTTER = { "FreeCorner", "ChestPanel" }
-- Enter / gamepad X: PLAY in the lobby, PLAY AGAIN on the results card (gamepad A is jump).
local PLAY_ACTION = "ShakeHudPlay"
local PRIORITY = Enum.ContextActionPriority.High.Value + 40
-- Gamepad Y during a run: the quit button (first press arms "QUIT?", the second quits).
local QUIT_ACTION = "ShakeHudQuit"
local PAD_Y_COLOR = Color3.fromRGB(232, 178, 30)
-- Screen attributes that mean another window owns the keys (Enter is left alone).
local BUSY = { "WindowOpen", "ModalOpen", "PopupBusy" }
-- The results card's stars (ShakeRules.STARS).
local STAR_COUNT = 3
local STAR_DIM = Color3.fromRGB(70, 74, 96)
-- A second PLAY press within this many seconds is ignored (the server answers with "countdown").
local BEGIN_GAP = 1.5
-- The results card closes itself this many seconds after the server's returnAt (or after
-- FINISH_HOLD with no returnAt) if the server never says "lobby".
local FINISH_GRACE = 3
local FINISH_HOLD = 20
-- The gamepad X button's colour (its glyph on PLAY and PLAY AGAIN).
local PAD_X_COLOR = Color3.fromRGB(40, 122, 232)

local screen: ScreenGui? = nil
local root: Frame
local scoreLabel: TextLabel
local barFill: Frame
local heartsRow: Frame
local clockLabel: TextLabel
local quitButton: TextButton
local banner: TextLabel
local bannerSub: TextLabel
local countLabel: TextLabel
local countSub: TextLabel
local hurtFlash: Frame
local lobbyCard: Frame
local lobbyGoal: TextLabel
local lobbyStats: TextLabel
local lobbyReward: TextLabel
local lobbyRewardSub: TextLabel
local lobbyHint: TextLabel
local playButton: TextButton
local finishCard: Frame
local finishTitle: TextLabel
local finishSub: TextLabel
local finishReward: TextLabel
local finishBest: TextLabel
local finishNew: TextLabel
local lobbyButton: TextButton
local finishStars: { GuiObject } = {}
local finishStarNote: TextLabel
local quitBadge: TextLabel
-- The gamepad X glyphs (shown while a gamepad is in use).
local padGlyphs: { GuiObject } = {}
-- Server time the server brings the player back to the lobby (the results card's countdown).
local returnAt = 0
local lobbyLeft = -1
-- "" (not in the mode), "lobby", "countdown", "play", "results".
local phase = ""
-- The run column is up (countdown and play).
local running = false
local quitArmed = false
local score = 0
local target = 25
local runSeconds = 60
local hearts = 3
local maxHearts = 3
-- Hearts a run starts with (the lobby's goal line).
local startHearts = 3
local goAt = 0
local endAt = 0
local wave = 1
local waves = 4
local targetShown = false
local lastCount = -1
-- Last known stats (start payload and snapshot): best, clears, rewardPreview, cooldownEnds.
local best = 0
local clears = 0
local reward: { [string]: any } = {}
local cooldownEnds = 0
local lastRewardText = ""
local beganAt = -math.huge
-- Banners: hide() bumps bannerEpoch to cancel every pending one; each banner has its own id
-- and only hides itself if it is still the one on screen (so they never cancel each other).
local bannerEpoch = 0
local bannerSeq = 0
local bannerShown = 0
local countToken = 0
-- Bumped on every results card show / hide; the card's auto-dismiss checks it.
local finishToken = 0
local stopNewBest: (() -> ())? = nil
local stepConn: RBXScriptConnection? = nil
local bound = false
local quitBound = false
-- The arena's best board.
local arena: Instance? = nil
local board: Instance? = nil
local boardLookAt = -math.huge

local function num(value: any, default: number): number
	return if type(value) == "number" and value == value then value else default
end

-- Best board (the arena's "BestBoard" SurfaceGui) -------------------------------------------

local function findArena(): Instance?
	if arena and arena.Parent then
		return arena
	end
	arena = nil
	local map = Workspace:FindFirstChild("Map")
	for _, holder in { map or Workspace, Workspace } do
		for _, child in holder:GetChildren() do
			if child:IsA("Model") and child:GetAttribute("Mode") == "shake" then
				arena = child
				return child
			end
		end
	end
	return nil
end

local function findBoard(): Instance?
	if board and board.Parent then
		return board
	end
	board = nil
	-- The arena may stream in later: look again every few seconds, not every snapshot.
	local now = os.clock()
	if now - boardLookAt < 4 then
		return nil
	end
	boardLookAt = now
	local model = findArena()
	board = model and model:FindFirstChild("BestBoard", true)
	return board
end

-- The reward line, its sub line, whether the full pack is ready, and the wait in seconds.
local function rewardStatus(): (string, string, boolean, number)
	local cash = num(reward.packCash, num(reward.cash, 0))
	if reward.full == true then
		return if clears == 0 then "FIRST CLEAR: +" .. Format.money(cash) else "FULL PACK READY: +" .. Format.money(cash),
			"Clear it to win the full cash pack!",
			true,
			0
	end
	local wait = math.max(0, math.ceil(cooldownEnds - os.time()))
	local repeatCash = num(reward.repeatCash, 0)
	return "Full pack in " .. Format.clock(wait),
		if repeatCash > 0 then "Clear it now for +" .. Format.money(repeatCash) else "Play for a new best!",
		false,
		wait
end

-- The lowest star tier whose bonus is ready (rewardPreview.stars): its points and cash.
local function readyStar(): (number?, number)
	local list = reward.stars
	if type(list) ~= "table" then
		return nil, 0
	end
	for _, star in list do
		if type(star) == "table" and star.ready == true and num(star.cash, 0) > 0 then
			return num(star.at, 0), num(star.cash, 0)
		end
	end
	return nil, 0
end

local function setBoardLabel(name: string, text: string)
	local b = board
	local label = b and b:FindFirstChild(name, true)
	if label and label:IsA("TextLabel") and label.Text ~= text then
		label.Text = text
	end
end

local function paintBoard()
	if not findBoard() then
		return
	end
	setBoardLabel("Best", if best > 0 then tostring(best) else "--")
	setBoardLabel("Clears", tostring(clears))
	local _, _, ready, wait = rewardStatus()
	if ready then
		setBoardLabel("RewardCaption", if clears == 0 then "FIRST CLEAR" else "FULL PACK")
		setBoardLabel("Reward", "+" .. Format.money(num(reward.packCash, num(reward.cash, 0))))
	else
		local at, cash = readyStar()
		if at then
			setBoardLabel("RewardCaption", string.format("STAR BONUS AT %d", at))
			setBoardLabel("Reward", "+" .. Format.money(cash))
		else
			setBoardLabel("RewardCaption", "NEXT PACK IN")
			setBoardLabel("Reward", Format.clock(wait))
		end
	end
end

-- Stats from a start payload or the snapshot.
local function absorb(p: { [string]: any })
	best = num(p.best, best)
	clears = num(p.clears, clears)
	target = num(p.target, target)
	cooldownEnds = num(p.cooldownEnds, cooldownEnds)
	if type(p.rewardPreview) == "table" then
		reward = p.rewardPreview
	end
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
				pop.Scale = if full then 0.4 else 1.8
				Kit.tween(pop, 0.5, { Scale = 1 }, Enum.EasingStyle.Back)
			end
		end
	end
	hearts = newHearts
end

-- A heart went: the red edge flash, the hearts shake and the warning when one is left.
local function hurt(newHearts: number)
	if newHearts >= hearts then
		return
	end
	setHearts(newHearts, true)
	Kit.pop(heartsRow, 1.3)
	hurtFlash.Visible = true
	hurtFlash.BackgroundTransparency = 0.55
	Kit.tween(hurtFlash, 0.45, { BackgroundTransparency = 1 })
	task.delay(0.5, function()
		if hurtFlash.BackgroundTransparency >= 0.99 then
			hurtFlash.Visible = false
		end
	end)
end

-- Score, banner, countdown, clock -------------------------------------------------------------

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

-- One beat of the big centre count: punches in large, settles, fades.
local function showCount(text: string, color: Color3, sub: string, hold: number)
	countToken += 1
	local token = countToken
	countLabel.Text = text
	countLabel.TextColor3 = color
	countSub.Text = sub
	-- Not "resuming" a fade-out: every beat punches in from big.
	countLabel.Visible = false
	Kit.appear(countLabel, { from = 2, time = 0.3 })
	task.delay(hold, function()
		if token == countToken then
			Kit.disappear(countLabel)
		end
	end)
end

local function hideCount()
	countToken += 1
	countLabel.Visible = false
end

local function render()
	local now = Workspace:GetServerTimeNow()
	if running then
		local left = math.max(0, math.ceil(endAt - now))
		local toGo = goAt - now
		if toGo > 0 then
			local n = math.ceil(toGo)
			if n ~= lastCount then
				lastCount = n
				showCount(tostring(n), if n == 1 then W.Coral elseif n == 2 then W.Sunny else C.Gold, "Get under the shakes!", 0.8)
				Sounds.play("Tick")
			end
			left = math.ceil(endAt - goAt)
		elseif lastCount > 0 then
			lastCount = 0
			if phase == "countdown" then
				phase = "play"
			end
			showCount("GO!", C.Good, "Catch shakes, dodge junk food!", 1)
			Sounds.play("Ready")
		end
		clockLabel.Text = string.format("%s · WAVE %d/%d", Format.clock(left), wave, waves)
		clockLabel.TextColor3 = if left <= 10 and toGo <= 0 then C.Bad else Color3.new(1, 1, 1)
	end
	if finishCard.Visible and returnAt > 0 then
		local left = math.max(0, math.ceil(returnAt - now))
		if left ~= lobbyLeft then
			lobbyLeft = left
			Kit.setButton(lobbyButton, if left > 0 then string.format("LOBBY %d", left) else "LOBBY")
		end
	end
	if lobbyCard.Visible or board then
		-- The cooldown counts down: repaint when the text changes (about once a second).
		local line, sub = rewardStatus()
		if line ~= lastRewardText then
			lastRewardText = line
			lobbyReward.Text = line
			lobbyRewardSub.Text = sub
			paintBoard()
		end
	end
end

-- Chrome, keys -------------------------------------------------------------------------------

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

local function sendBegin()
	local now = os.clock()
	if now - beganAt < BEGIN_GAP then
		return
	end
	beganAt = now
	action:FireServer({ action = "ShakeBegin" })
	if lobbyCard.Visible then
		Kit.setButton(playButton, "GET READY…")
		task.delay(3, function()
			if phase == "lobby" then
				Kit.setButton(playButton, "PLAY")
			end
		end)
	end
end

local function onPlayKey(_: string, state: Enum.UserInputState, input: InputObject): Enum.ContextActionResult
	if state ~= Enum.UserInputState.Begin then
		return Enum.ContextActionResult.Pass
	end
	-- Another window (the shop, a popup) or a TextBox owns the keys: leave them alone.
	if UserInputService:GetFocusedTextBox() ~= nil then
		return Enum.ContextActionResult.Pass
	end
	local gui = screen
	if gui then
		for _, name in BUSY do
			if gui:GetAttribute(name) == true then
				return Enum.ContextActionResult.Pass
			end
		end
	end
	-- Enter with a button selected on one of the cards presses that button instead.
	if input.KeyCode ~= Enum.KeyCode.ButtonX and (Kit.selectedIn(lobbyCard) or Kit.selectedIn(finishCard)) then
		return Enum.ContextActionResult.Pass
	end
	if (phase == "lobby" and lobbyCard.Visible) or (phase == "results" and finishCard.Visible) then
		if finishCard.Visible then
			finishToken += 1
			Kit.unfocus(finishCard)
			Kit.disappear(finishCard)
		end
		sendBegin()
		return Enum.ContextActionResult.Sink
	end
	return Enum.ContextActionResult.Pass
end

local function bind(on: boolean)
	if on == bound then
		return
	end
	bound = on
	if on then
		ContextActionService:BindActionAtPriority(
			PLAY_ACTION,
			onPlayKey,
			false,
			PRIORITY,
			Enum.KeyCode.Return,
			Enum.KeyCode.KeypadEnter,
			Enum.KeyCode.ButtonX
		)
	else
		ContextActionService:UnbindAction(PLAY_ACTION)
	end
end

local function resetQuit()
	quitArmed = false
	Kit.setButton(quitButton, "X", C.SurfaceHi)
	quitButton.Size = UDim2.fromOffset(44, 44)
end

local function pressQuit()
	if quitArmed then
		resetQuit()
		action:FireServer({ action = "ModeQuit" })
		return
	end
	-- First press arms it: "QUIT?" for a few seconds.
	quitArmed = true
	Kit.setButton(quitButton, "QUIT?", C.Bad)
	Kit.tween(quitButton, 0.2, { Size = UDim2.fromOffset(96, 44) }, Enum.EasingStyle.Back)
	task.delay(3, function()
		if quitArmed then
			resetQuit()
		end
	end)
end

local function onQuitKey(_: string, state: Enum.UserInputState, _input: InputObject): Enum.ContextActionResult
	if state ~= Enum.UserInputState.Begin or not running then
		return Enum.ContextActionResult.Pass
	end
	local gui = screen
	if gui then
		for _, name in BUSY do
			if gui:GetAttribute(name) == true then
				return Enum.ContextActionResult.Pass
			end
		end
	end
	pressQuit()
	return Enum.ContextActionResult.Sink
end

-- Gamepad Y reaches the quit button during the countdown and play.
local function bindQuit(on: boolean)
	if on == quitBound then
		return
	end
	quitBound = on
	if on then
		ContextActionService:BindActionAtPriority(QUIT_ACTION, onQuitKey, false, PRIORITY, Enum.KeyCode.ButtonY)
	else
		ContextActionService:UnbindAction(QUIT_ACTION)
	end
end

local function ensureStep(on: boolean)
	if on and not stepConn then
		stepConn = RunService.RenderStepped:Connect(render)
	elseif not on and stepConn then
		stepConn:Disconnect()
		stepConn = nil
	end
end

-- Lobby card ---------------------------------------------------------------------------------

local function paintLobby()
	lobbyGoal.Text = string.format("Score %d points — gold = 3! %d hearts", target, startHearts)
	lobbyStats.Text = string.format("BEST %d   ·   CLEARS %d", best, clears)
	local line, sub, ready = rewardStatus()
	lastRewardText = line
	lobbyReward.Text = line
	lobbyReward.TextColor3 = if ready then C.MoneyText else C.Text
	lobbyRewardSub.Text = sub
	lobbyHint.Text =
		Kit.hint("Tap PLAY or step on the START pad", "ENTER to play · or step on the START pad", "X to play · or step on the START pad")
end

local function hideLobby()
	Kit.unfocus(lobbyCard)
	if lobbyCard.Visible then
		Kit.disappear(lobbyCard)
	end
end

local function showLobby()
	paintLobby()
	Kit.setButton(playButton, "PLAY")
	if not lobbyCard.Visible then
		Kit.appear(lobbyCard, { from = 0.7, time = 0.3 })
	end
end

-- Results card -------------------------------------------------------------------------------

local function hideFinish()
	finishToken += 1
	if stopNewBest then
		stopNewBest()
		stopNewBest = nil
	end
	Kit.unfocus(finishCard)
	if finishCard.Visible then
		Kit.disappear(finishCard)
	end
end

local function showFinish(p: { [string]: any }, won: boolean)
	local s, t = num(p.score, score), num(p.target, target)
	best = math.max(best, num(p.best, best))
	local newBest = p.newBest == true and s > 0
	finishTitle.Text = if won then "SHAKE CHAMP!" elseif p.why == "hearts" then "OUT OF HEARTS!" else "SO CLOSE!"
	finishTitle.TextColor3 = if won then C.Gold else W.Coral
	local caught = num(p.caught, s)
	finishSub.Text = string.format("%d catches  ·  Score %d / %d", caught, s, t)
	finishBest.Text = if newBest then string.format("Best %d  (was %d)", s, num(p.prevBest, 0)) else "Best " .. best
	finishNew.Visible = false
	local cash = num(p.cash, 0)
	if not won then
		finishReward.Text = if p.why == "hearts"
			then "Dodge the junk food! Catch " .. t .. " to win cash."
			else "Catch " .. t .. " to win cash!"
		finishReward.TextColor3 = C.Text
	elseif cash > 0 then
		finishReward.Text = (if p.pay == "repeat" then "Repeat bonus +" else "+") .. Format.money(cash)
		finishReward.TextColor3 = C.MoneyText
	elseif p.pay == "resting" then
		finishReward.Text = "Bonus is resting. Play again soon!"
		finishReward.TextColor3 = C.Text
	else
		local wait = math.max(0, num(p.cooldownEnds, cooldownEnds) - os.time())
		finishReward.Text = "Full reward in " .. Format.clock(wait)
		finishReward.TextColor3 = C.Text
	end
	if type(p.cooldownEnds) == "number" then
		cooldownEnds = p.cooldownEnds
	end
	-- The stars: one per tier reached (a pass is one), popping in one by one.
	local stars = math.clamp(math.floor(num(p.stars, if won then 1 else 0)), 0, STAR_COUNT)
	local starCash = num(p.starCash, 0)
	local nextStar = p.starNext
	for i, star in finishStars do
		star.Visible = false
		if i <= stars then
			task.delay(0.25 + i * 0.18, function()
				if finishCard.Visible and finishStars[i] == star then
					Kit.appear(star, { from = 2.2, time = 0.3 })
					Sounds.play("Collect", 0.05, 1 + i * 0.12)
				end
			end)
		end
	end
	if starCash > 0 then
		finishStarNote.Text = string.format("%d STARS! Star bonus +%s", stars, Format.money(starCash))
		finishStarNote.TextColor3 = C.Gold
	elseif won and type(nextStar) == "number" then
		finishStarNote.Text = string.format("Next star at %d points", nextStar)
		finishStarNote.TextColor3 = C.TextDim
	else
		finishStarNote.Text = if stars >= STAR_COUNT then "All 3 stars!" else ""
		finishStarNote.TextColor3 = C.Gold
	end
	returnAt = num(p.returnAt, 0)
	lobbyLeft = -1
	Kit.setButton(lobbyButton, "LOBBY")
	finishCard.Visible = true
	Kit.appear(finishCard, { from = 0.5, time = 0.35 })
	finishToken += 1
	local token = finishToken
	local hold = if returnAt > 0 then math.max(1, returnAt - Workspace:GetServerTimeNow()) + FINISH_GRACE else FINISH_HOLD
	task.delay(hold, function()
		if token == finishToken and finishCard.Visible then
			hideFinish()
			if phase == "results" then
				phase = "lobby"
				showLobby()
			end
		end
	end)
	if newBest then
		finishNew.Rotation = -6
		Kit.appear(finishNew, { from = 2.2, time = 0.45, delay = 0.35 })
		task.delay(0.4, function()
			if token == finishToken then
				Sounds.play("Upgrade")
			end
		end)
		task.delay(0.9, function()
			if token == finishToken and not stopNewBest then
				stopNewBest = Kit.breathe(finishNew, 0.12)
			end
		end)
	end
	-- No gamepad focus on the card: A stays jump and the stick keeps walking (X plays again).
	if won then
		Kit.confetti(finishCard, { Count = if cash > 0 then 36 else 20, Origin = UDim2.fromScale(0.5, 0.2), ZIndex = 55 })
		Sounds.play(if p.first == true then "CelebrateLegendary" else "Celebrate")
		if cash > 0 then
			Kit.countTo(finishReward, 0, cash, function(n: number)
				return (if p.pay == "repeat" then "Repeat bonus +" else "+") .. Format.money(n)
			end, 0.9)
		end
	else
		Sounds.play("Close")
	end
end

-- Lifecycle ----------------------------------------------------------------------------------

-- Takes the run column down (banners, count, flash).
local function endRun()
	running = false
	bindQuit(false)
	bannerEpoch += 1
	bannerShown = 0
	banner.Visible = false
	hideCount()
	hurtFlash.Visible = false
	if root.Visible then
		Kit.disappear(root)
	end
end

local function enterLobby(p: { [string]: any }?)
	if p then
		absorb(p)
	end
	if running then
		endRun()
	end
	hideFinish()
	phase = "lobby"
	setChrome(true)
	ensureStep(true)
	bind(true)
	showLobby()
	paintBoard()
end

-- Countdown (and play): the run column comes up. `p`: the "countdown" payload, a legacy
-- "start" { goAt, endAt, ... } or a snapshot that skipped the Notify.
local function beginRun(p: { [string]: any })
	absorb(p)
	hideLobby()
	hideFinish()
	bind(false)
	phase = if p.phase == "play" then "play" else "countdown"
	running = true
	score = num(p.score, 0)
	-- (A snapshot's hearts are the ones left, so they only ever raise the maximum.)
	maxHearts = num(p.maxHearts, math.max(maxHearts, num(p.hearts, 0)))
	hearts = maxHearts
	local now = Workspace:GetServerTimeNow()
	local fallback = if p.phase == "play" then now - 1 else now + num(p.seconds, 3)
	goAt = num(p.goAt, fallback)
	endAt = num(p.endAt, goAt + runSeconds)
	wave, waves = 1, num(p.waves, waves)
	targetShown = false
	-- A snapshot in play has no count to show.
	lastCount = if goAt > now then -1 else 0
	resetQuit()
	bindQuit(true)
	for _, child in heartsRow:GetChildren() do
		if child:IsA("Frame") then
			child:Destroy()
		end
	end
	setHearts(hearts, false)
	if type(p.hearts) == "number" then
		setHearts(p.hearts, false)
	end
	paintScore(false)
	root.Visible = true
	Kit.appear(root, { from = 0.6, time = 0.3 })
	setChrome(true)
	ensureStep(true)
	render()
end

local function leaveMode()
	phase = ""
	if running then
		endRun()
	end
	hideLobby()
	bind(false)
	bindQuit(false)
	ensureStep(false)
	setChrome(false)
end

function ShakeHud.start(payload: { [string]: any }?)
	if not screen then
		return
	end
	local p: { [string]: any } = payload or {}
	if type(p.seconds) == "number" then
		runSeconds = p.seconds
	end
	if type(p.hearts) == "number" and p.hearts > 0 then
		startHearts = p.hearts
	end
	if p.phase == "lobby" or type(p.goAt) ~= "number" then
		enterLobby(p)
	else
		-- An older server: "start" begins the run straight away.
		beginRun(p)
	end
end

function ShakeHud.stop(payload: { [string]: any }?)
	if not root then
		return
	end
	local was = running
	leaveMode()
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
	elseif event == "go" then
		-- The countdown is over (render shows GO! from the clock; this pins the times).
		if running then
			phase = "play"
			goAt = num(payload.goAt, goAt)
			endAt = num(payload.endAt, endAt)
		elseif phase == "lobby" or phase == "" then
			beginRun(payload)
		end
	elseif event == "stop" then
		ShakeHud.stop(payload)
	elseif event == "lobby" then
		enterLobby(payload)
	elseif event == "countdown" then
		beginRun(payload)
	elseif event == "win" or event == "lose" then
		if running then
			endRun()
		end
		hideLobby()
		phase = "results"
		bind(true)
		showFinish(payload, event == "win")
		paintBoard()
	elseif event == "wave" and not running then
		-- The countdown Notify never came: the first wave says when play starts.
		if phase == "lobby" then
			local first = num(payload.wave, 1) == 1
			beginRun({ goAt = if first then payload.at else nil, waves = payload.waves })
		end
	elseif not running then
		return
	elseif event == "wave" then
		local n = num(payload.wave, 1)
		waves = num(payload.waves, waves)
		if n > 1 then
			local delay = math.max(0, num(payload.at, 0) - Workspace:GetServerTimeNow())
			task.delay(delay, function()
				if running then
					wave = n
				end
			end)
			local last = n >= waves
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
	elseif event == "splat" or event == "miss" then
		-- "miss" only costs a heart if the server says so.
		if type(payload.hearts) == "number" then
			hurt(payload.hearts)
		elseif event == "splat" then
			hurt(hearts - 1)
		end
	end
end

function ShakeHud.onState(data: any)
	if not screen or type(data) ~= "table" or type(data.modes) ~= "table" then
		return
	end
	local info = data.modes.shake
	if type(info) ~= "table" then
		return
	end
	absorb(info)
	paintBoard()
	if info.running ~= true then
		if phase == "results" then
			-- An older server: nothing runs after a finish, the card stays until dismissed.
			for _, other in data.modes do
				if type(other) == "table" and other.running == true then
					-- Another mode started: the card is stale.
					ShakeHud.stop(nil)
					break
				end
			end
		elseif phase ~= "" then
			ShakeHud.stop(nil)
		end
		return
	end
	local p = if type(info.phase) == "string" then info.phase else "play"
	if p == "lobby" then
		if phase ~= "lobby" then
			enterLobby(nil)
		elseif lobbyCard.Visible then
			paintLobby()
		end
	elseif p == "countdown" or p == "play" then
		if phase == "" or phase == "lobby" then
			beginRun(info)
		elseif running then
			-- Safety net for a lost "catch" / "splat": the server's numbers win.
			local s = num(info.score, score)
			if s > score then
				score = s
				paintScore(false)
			end
			local h = num(info.hearts, hearts)
			if h < hearts then
				hurt(h)
			end
			if p == "play" then
				endAt = num(info.endAt, endAt)
			end
		end
	elseif p == "results" and running then
		-- The finish Notify is late (or lost): take the run column down and wait for it.
		endRun()
	end
end

-- Build --------------------------------------------------------------------------------------

-- The gamepad X glyph on a button's face (left end), shown while a gamepad is in use.
local function padGlyph(button: TextButton)
	local glyph = Kit.new("TextLabel", {
		Name = "PadX",
		Text = "X",
		Font = F.Display,
		TextSize = 18,
		TextColor3 = Color3.new(1, 1, 1),
		BackgroundColor3 = PAD_X_COLOR,
		Size = UDim2.fromOffset(28, 28),
		Position = UDim2.new(0, 10, 0.5, 0),
		AnchorPoint = Vector2.new(0, 0.5),
		ZIndex = (button.ZIndex or 1) + 4,
		Visible = Kit.gamepad == true,
		Parent = Kit.buttonFace(button) or button,
	})
	Kit.round(glyph)
	Kit.stroke(glyph, 2, W.Ink)
	table.insert(padGlyphs, glyph)
end

local function buildLobby(screenGui: ScreenGui)
	lobbyCard = Kit.panel(screenGui, {
		Name = "ShakeLobby",
		Size = UDim2.fromOffset(LOBBY_W, LOBBY_H),
		Position = UDim2.new(1, -ROOT_RIGHT + 12, 0.5, 20),
		AnchorPoint = Vector2.new(1, 0.5),
		Visible = false,
		ZIndex = 20,
		Elevated = true,
		StrokeColor = W.Pink,
		StrokeThickness = 3,
	})
	Kit.icon(lobbyCard, "Star", 30, C.Gold, {
		Position = UDim2.fromOffset(14, 14),
		ZIndex = 22,
	})
	Kit.title(lobbyCard, {
		Name = "Title",
		Text = "SHAKE CATCH",
		TextSize = 30,
		TextColor3 = W.Pink,
		TextXAlignment = Enum.TextXAlignment.Left,
		Size = UDim2.new(1, -66, 0, 34),
		Position = UDim2.fromOffset(52, 12),
		ZIndex = 21,
	})
	lobbyGoal = Kit.text(lobbyCard, {
		Name = "Goal",
		Text = "",
		Font = F.UI,
		MaxTextSize = 16,
		TextColor3 = C.Text,
		TextXAlignment = Enum.TextXAlignment.Left,
		Size = UDim2.new(1, -28, 0, 20),
		Position = UDim2.fromOffset(14, 50),
		ZIndex = 21,
	})
	lobbyStats = Kit.number(lobbyCard, {
		Name = "Stats",
		Text = "",
		TextSize = 18,
		TextColor3 = C.Gold,
		TextXAlignment = Enum.TextXAlignment.Left,
		Size = UDim2.new(1, -28, 0, 22),
		Position = UDim2.fromOffset(14, 74),
		ZIndex = 21,
	})
	local well = Kit.well(lobbyCard, {
		Name = "RewardWell",
		Size = UDim2.new(1, -24, 0, 50),
		Position = UDim2.fromOffset(12, 102),
		ZIndex = 21,
	})
	lobbyReward = Kit.text(well, {
		Name = "Reward",
		Text = "",
		Font = F.Display,
		TextSize = 17,
		TextColor3 = C.MoneyText,
		Size = UDim2.new(1, -16, 0, 22),
		Position = UDim2.fromOffset(8, 4),
		ZIndex = 22,
	})
	lobbyRewardSub = Kit.text(well, {
		Name = "Sub",
		Text = "",
		Font = F.UI,
		TextSize = 14,
		TextColor3 = C.TextDim,
		Size = UDim2.new(1, -16, 0, 18),
		Position = UDim2.fromOffset(8, 27),
		ZIndex = 22,
	})
	playButton = Kit.button(lobbyCard, {
		Name = "Play",
		Text = "PLAY",
		Color = C.Good,
		Font = F.Display,
		TextSize = 28,
		Size = UDim2.new(1, -136, 0, 58),
		Position = UDim2.fromOffset(12, 162),
		ZIndex = 22,
		Breathe = true,
	}, sendBegin)
	playButton:SetAttribute("FocusFirst", true)
	padGlyph(playButton)
	local leave = Kit.button(lobbyCard, {
		Name = "Leave",
		Text = "LEAVE",
		Color = C.SurfaceHi,
		Font = F.Display,
		TextSize = 18,
		Size = UDim2.fromOffset(104, 58),
		Position = UDim2.new(1, -12, 0, 162),
		AnchorPoint = Vector2.new(1, 0),
		ZIndex = 22,
	}, function()
		action:FireServer({ action = "ModeQuit" })
	end)
	Kit.selectable(playButton)
	Kit.selectable(leave)
	lobbyHint = Kit.text(lobbyCard, {
		Name = "Hint",
		Text = "",
		Font = F.UI,
		TextSize = 13,
		TextColor3 = C.TextDim,
		Size = UDim2.new(1, -24, 0, 18),
		Position = UDim2.new(0, 12, 1, -24),
		ZIndex = 21,
	})
	Kit.onInput(function()
		for _, glyph in padGlyphs do
			glyph.Visible = Kit.gamepad == true
		end
		if quitBadge then
			quitBadge.Visible = Kit.gamepad == true
		end
		-- Touch: the column and the card ride higher, clear of the jump button.
		local right = if Kit.touch then TOUCH_RIGHT else ROOT_RIGHT
		root.Position = UDim2.new(1, -right, 0.5, if Kit.touch then TOUCH_DY else ROOT_DY)
		lobbyCard.Position = UDim2.new(1, -right + (if Kit.touch then 0 else 12), 0.5, if Kit.touch then TOUCH_DY + 10 else 20)
		if lobbyCard.Visible then
			paintLobby()
		end
	end)
end

local function buildFinish(screenGui: ScreenGui)
	finishCard = Kit.panel(screenGui, {
		Name = "ShakeFinish",
		Size = UDim2.fromOffset(420, 330),
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
		TextSize = 16,
		TextColor3 = C.TextDim,
		Size = UDim2.new(1, -20, 0, 20),
		Position = UDim2.fromOffset(10, 114),
		ZIndex = 51,
	})
	finishNew = Kit.pill(finishCard, {
		Name = "NewBest",
		Text = "NEW BEST!",
		Font = F.Display,
		TextSize = 18,
		Color = C.Gold,
		Solid = true,
		Size = UDim2.fromOffset(130, 30),
		Position = UDim2.new(1, -16, 0, 14),
		AnchorPoint = Vector2.new(1, 0),
		ZIndex = 53,
		Visible = false,
	})
	finishReward = Kit.number(finishCard, {
		Name = "Reward",
		Text = "",
		TextSize = 24,
		TextColor3 = C.MoneyText,
		Size = UDim2.new(1, -20, 0, 32),
		Position = UDim2.fromOffset(10, 144),
		ZIndex = 51,
	})
	-- The stars: a dim star per tier, a lit one over it that pops in when reached.
	local starSize, starGap = 34, 10
	local rowW = STAR_COUNT * starSize + (STAR_COUNT - 1) * starGap
	for i = 1, STAR_COUNT do
		local x = (i - 1) * (starSize + starGap) - rowW / 2
		local dim = Kit.icon(finishCard, "Star", starSize, STAR_DIM, {
			Name = "StarSlot" .. i,
			Position = UDim2.new(0.5, x, 0, 180),
			ZIndex = 51,
		})
		for _, inst in dim:GetDescendants() do
			if inst:IsA("ImageLabel") then
				inst.ImageColor3 = STAR_DIM
				inst.ImageTransparency = 0.3
			end
		end
		local lit = Kit.icon(finishCard, "Star", starSize, C.Gold, {
			Name = "Star" .. i,
			Position = UDim2.new(0.5, x, 0, 180),
			ZIndex = 52,
		})
		lit.Visible = false
		finishStars[i] = lit
	end
	finishStarNote = Kit.text(finishCard, {
		Name = "StarNote",
		Text = "",
		Font = F.UI,
		MaxTextSize = 16,
		TextColor3 = C.TextDim,
		Size = UDim2.new(1, -20, 0, 20),
		Position = UDim2.fromOffset(10, 220),
		ZIndex = 51,
	})
	local again = Kit.button(finishCard, {
		Name = "Again",
		Text = "PLAY AGAIN",
		Color = C.Good,
		Font = F.Display,
		TextSize = 20,
		Size = UDim2.fromOffset(200, 54),
		Position = UDim2.new(0.5, -8, 1, -20),
		AnchorPoint = Vector2.new(1, 1),
		ZIndex = 52,
		Breathe = true,
	}, function()
		hideFinish()
		sendBegin()
	end)
	again:SetAttribute("FocusFirst", true)
	padGlyph(again)
	lobbyButton = Kit.button(finishCard, {
		Name = "Lobby",
		Text = "LOBBY",
		Color = C.SurfaceHi,
		Font = F.Display,
		TextSize = 20,
		Size = UDim2.fromOffset(150, 54),
		Position = UDim2.new(0.5, 8, 1, -20),
		AnchorPoint = Vector2.new(0, 1),
		ZIndex = 52,
	}, function()
		hideFinish()
		-- Back to the lobby now (the server would do it at returnAt anyway); the lobby card
		-- (PLAY works from results too) is up straight away, the "lobby" event confirms it.
		action:FireServer({ action = "ShakeLobby" })
		if phase == "results" then
			phase = "lobby"
			showLobby()
		end
	end)
	Kit.selectable(again)
	Kit.selectable(lobbyButton)
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
	}, pressQuit)
	Kit.selectable(quitButton)
	-- The gamepad Y badge on the quit button's corner.
	quitBadge = Kit.new("TextLabel", {
		Name = "PadY",
		Text = "Y",
		Font = F.Display,
		TextSize = 14,
		TextColor3 = W.Ink,
		BackgroundColor3 = PAD_Y_COLOR,
		Size = UDim2.fromOffset(20, 20),
		Position = UDim2.fromOffset(-6, -6),
		ZIndex = 8,
		Visible = Kit.gamepad == true,
		Parent = quitButton,
	})
	Kit.round(quitBadge)
	Kit.stroke(quitBadge, 2, W.Ink)

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

	-- The centre banner (waves, target).
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

	-- The big "3, 2, 1, GO!".
	countLabel = Kit.hudText(screenGui, {
		Name = "ShakeCount",
		Text = "",
		Font = F.Display,
		TextSize = 150,
		StrokeThickness = 7,
		Size = UDim2.fromOffset(500, 160),
		Position = UDim2.fromScale(0.5, 0.36),
		AnchorPoint = Vector2.new(0.5, 0.5),
		Visible = false,
		ZIndex = 32,
	})
	countSub = Kit.hudText(countLabel, {
		Name = "Sub",
		Text = "",
		Font = F.Display,
		TextSize = 26,
		Size = UDim2.new(1, 200, 0, 32),
		Position = UDim2.new(0.5, 0, 1, 0),
		AnchorPoint = Vector2.new(0.5, 0),
		ZIndex = 32,
	})

	-- Red edge flash when a heart goes (a soft vignette: transparent in the middle).
	hurtFlash = Kit.new("Frame", {
		Name = "ShakeHurt",
		BackgroundColor3 = C.Bad,
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1),
		Visible = false,
		ZIndex = 15,
		Parent = screenGui,
	})
	Kit.new("UIGradient", {
		Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0),
			NumberSequenceKeypoint.new(0.22, 0.85),
			NumberSequenceKeypoint.new(0.5, 1),
			NumberSequenceKeypoint.new(0.78, 0.85),
			NumberSequenceKeypoint.new(1, 0),
		}),
		Parent = hurtFlash,
	})

	buildLobby(screenGui)
	buildFinish(screenGui)
end

return ShakeHud
