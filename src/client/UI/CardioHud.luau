--!strict
--[[
	CardioHud: the screen side of CARDIO, the keyboard runner (Fx.Cardio does the 3D side,
	including the floating "+N" step pops). Laid out like "+1 Speed Keyboard Escape".
	Everything shows only during a run (snapshot modes.cardio.running or a "start" Notify).

	  Speed box     bottom centre, where the dumbbell sits (the Hud's "Dumbbell" group is
	                hidden while a run is active and shown again after): a BIG outlined
	                "12.85K Speed" that counts up smoothly, a chunky bar under it toward the
	                next stage's need ("Stage 3 · 968 / 1.1K", gold until the need is met,
	                then mint), and small lines beside it ("Multiplier x1.25 (Stages)",
	                "Treadmill Lv 3", "Best plate 5": the deepest WIN plate claimed, the
	                personal best, "No best plate yet" before the first); on narrow screens
	                those lines sit above the number.
	                The bar runs on past the need to the recommended Speed (snapshot
	                `recommended`, 15% above the need): a dark tick marks the need, and from
	                there the text reads "Stage 3 · 1.12K · recommended 1.27K", then
	                "... · ready!".
	  Stage line    top centre in the run-pill slot (y 92): a persistent "STAGE 4 · NAME";
	                in a safe zone what its WIN pad does right now: gold "WIN plate: +$12.4K
	                · it ends this run" (and, for a first clear, "Skip it and this first win
	                stays for later": true in Modes.Cardio, first clears are kept per plate),
	                or white "NO REWARD on this WIN plate right now" with when it pays again
	                and the same warning; while Speed < need, a pulsing coral "Need more
	                speed!" hint. Inside the reward cooldown the best plate and deeper ones
	                pay the run again bonus (snapshot `repeats`, `repeatFrom`,
	                `repeatReadyAt`): "WIN plate: run again bonus +$2.4K", and where it is
	                not paid the line says from which plate or in how many seconds it is.
	  Title         a big bubbly "STAGE n" (plus the stage's name) under it whenever you
	                enter a stage; also "STAGE 3 CLEAR!" (reaching a safe zone: nothing is
	                paid until you step on its WIN plate), "YOU WIN!" (cashed out; "NEW
	                BEST!" with "Plate n" when the claim is deeper than the best plate,
	                with more confetti; "RUN OVER" when the plate paid nothing), and for a fall "TOO SLOW!" / "OOPS!"
	                / "CAUGHT!" with what happened (Speed below the stage's need, the custom
	                speed cap, a plain fall, the chaser), "TREADMILL LV 4!" banners.
	  WIN plates    the floating "Amount" line over every WIN pad (tag "CardioWinPad",
	                World.CardioTrack) is written here: "+$12.4K", "NO REWARD", or
	                "+$2.4K in 0:12" while the run again bonus waits for its gap.
	  Right column  centre right: Custom Speed (title, "Your Max Speed: N", a number box
	                + green OK that fires CardioSpeedCap { cap } with 0 / empty = no cap,
	                "Current speed: N"; a small "Custom Speed" chip by default on every
	                screen: tapping it expands the box, OK and the run's end fold it),
	                the treadmill card (on / near a treadmill), SPEED UP
	                (near the upgrade pad, fires CardioUpgrade) and a QUIT pill that asks
	                "QUIT?" before ModeQuit.
	  Finish card   centre, on the last WIN plate: CARDIO CHAMPION!, the reward, RUN AGAIN /
	                HOME, confetti.

	Snapshot fields read (modes.cardio): running, speed, walkSpeed, maxWalkSpeed?,
	speedCap?, multiplier, bestStage, treadmill, treadmillRate, nextCost, stage, wins?, firsts?,
	repeats?, repeatFrom?, repeatReadyAt?, cooldownEnds, onTreadmill, stageCount, needs, recommended?, names. Main routes Notify (kind "Mode", mode "cardio")
	to CardioHud.onNotify, every State snapshot to CardioHud.onState and the "CardioSteps"
	effect to CardioHud.onSteps.
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Theme = require(ReplicatedStorage:WaitForChild("Theme")) :: any
local Economy = require(ReplicatedStorage.Shared.Economy)
local Format = require(ReplicatedStorage.Shared.Format) :: any
local Net = require(ReplicatedStorage.Shared.Net)

local Client = script.Parent.Parent
local Kit = require(script.Parent.Kit) :: any
local Popups = require(script.Parent.Popups) :: any
local Sounds = require(Client.Sounds) :: any
local State = require(Client.State) :: any

local CardioHud = {}

local C = Kit.C
local F = Kit.F
local W = Theme.World

local MINT: Color3 = W.Mint or Color3.fromRGB(98, 224, 160)
local CORAL: Color3 = W.Coral or C.Bad
local GOLD: Color3 = C.Gold
local GRAPE: Color3 = W.Grape or Color3.fromRGB(176, 132, 255)
local WHITE = Color3.new(1, 1, 1)
local HINT_DIM = CORAL
local HINT_BRIGHT = Color3.new(1, 0.86, 0.8)

local STRIP_Y = 92 -- Hud's run-pill slot (Tutorial steps aside while "RunActive")
local TITLE_Y = 128
local BOX_W = 400
local SPEED_TEXT = 78 -- the big bottom-centre number (1.4x the old 56)
local SPEED_H = 84
local BOX_H = SPEED_H + 4 + 30 + 10
local BAR_H = 30
local SIDE_W = 210
local COLUMN_W = 250
local WALLET_RIGHT = 340 -- px the desktop wallet (bottom left) reaches
local NEAR_PAD = 16 -- studs (flat) from the upgrade pad that show the SPEED UP card
local NEAR_TREADMILL = 14
local PROXIMITY_EVERY = 0.15
local PADS_EVERY = 1 -- seconds between repaints of the WIN pads' floating amounts
local WIN_TAG = "CardioWinPad"
local MAX_LEVEL = 10
local MAX_CAP = 100000

local player = Players.LocalPlayer
local action = Net.event("Action")

local screen: ScreenGui? = nil
local root: Frame
local column: Frame
-- Speed box (bottom centre)
local box: Frame
local boxBody: Frame
local boxScale: UIScale
local speedLabel: TextLabel
local barFill: Frame
local barTick: Frame
local barText: TextLabel
local side: Frame
local sideLayout: UIListLayout
local multLine: TextLabel
local bestLine: TextLabel
local treadLine: TextLabel
-- Custom speed
local customCard: Frame
local customBody: Frame
local customToggle: TextButton
local customTitle: TextLabel
local customChip: TextButton
local maxLabel: TextLabel
local currentLabel: TextLabel
local capBox: TextBox
local capButton: TextButton
local customOpen = false
-- Collapsed Custom Speed chip width.
local CHIP_W = 176
local quitButton: TextButton
-- Treadmill card
local treadCard: Frame
local treadTitle: TextLabel
local treadRate: TextLabel
local treadBelt: Frame
-- Upgrade card
local upCard: Frame
local upLevel: TextLabel
local upRate: TextLabel
local upPips: { Frame } = {}
local upButton: TextButton
-- Stage line
local stageLine: Frame
local stageLabel: TextLabel
local winLabel: TextLabel
local winNote: TextLabel
local hintLabel: TextLabel
-- Banner, finish
local banner: Frame
local bannerTitle: TextLabel
local bannerSub: TextLabel
local finishCard: Frame
local finishSub: TextLabel
local finishReward: TextLabel

-- Run state
local active = false
local startedAt = 0
local snap: { [string]: any } = {}
local targetSpeed = 0
local shownSpeed = 0
local walkSpeed = 16
local maxSeen = 16
local stage = 0
local stageCount = 10
-- The deepest WIN plate claimed so far (the personal best; 0 = none yet).
local bestStage = 0
local nearPad = false
local nearTreadmill = false
-- Safe zone the player stands in (0 = none), and what each zone's WIN pad paid when its
-- "zone" Notify came (used until a snapshot brings `wins`).
local zoneIn = 0
local zoneCash: { [number]: number } = {}
local zoneFirst: { [number]: boolean } = {}
-- Speed recommended for a stage when the snapshot has none: this far above its need.
local RECOMMEND = 1.15
local padsAt = 0
local quitArmed = false
local bannerToken = 0
local renderConn: RBXScriptConnection? = nil
local proximityAt = 0
local hintShown = false
local compactTouch = false
local quitPress: () -> () = function() end

local function num(value: any, default: number): number
	return if type(value) == "number" and value == value then value else default
end

local function speedText(n: number): string
	return Format.short(math.floor(n))
end

local function multText(m: number): string
	if m == math.floor(m) then
		return tostring(m)
	end
	local text = string.format("%.2f", m)
	return (string.gsub(text, "0$", ""))
end

local function needOf(index: number): number?
	local needs = snap.needs
	if type(needs) == "table" then
		local v = needs[index]
		if type(v) == "number" then
			return v
		end
	end
	return nil
end

-- The Speed to run stage `index` with comfortably (>= its need).
local function recommendedOf(index: number, need: number): number
	local list = snap.recommended
	local v = if type(list) == "table" then list[index] else nil
	return math.max(need, if type(v) == "number" then v else math.ceil(need * RECOMMEND))
end

local function nameOf(index: number): string?
	local names = snap.names
	if type(names) == "table" and type(names[index]) == "string" and names[index] ~= "" then
		return names[index]
	end
	return nil
end

local function iconName(): string
	return Kit.pickIcon("Cardio", "Surge")
end

-- Banner / big stage title --------------------------------------------------------------------

local function showBanner(title: string, sub: string?, color: Color3, hold: number, delay: number?)
	bannerToken += 1
	local mine = bannerToken
	local function run()
		if bannerToken ~= mine then
			return
		end
		bannerTitle.Text = title
		bannerTitle.TextColor3 = color
		bannerSub.Text = sub or ""
		bannerSub.Visible = sub ~= nil
		Kit.appear(banner, { from = 0.35, time = 0.4 })
		task.delay(hold, function()
			if bannerToken == mine then
				Kit.disappear(banner)
			end
		end)
	end
	if delay and delay > 0 then
		task.delay(delay, run)
	else
		run()
	end
end

-- "STAGE n" for the stage you are about to run (n = safe zone + 1), after `delay`.
local function stageTitle(delay: number?)
	local n = math.min(stage + 1, stageCount)
	if stage >= stageCount then
		return
	end
	local name = nameOf(n)
	showBanner("STAGE " .. n, if name then string.upper(name) else nil, WHITE, 1.8, delay)
end

-- Why a WIN plate paid nothing: the run again bonus starts at a deeper plate (the best one),
-- or it was paid a moment ago, or "plates pay again in 12:30".
local function noRewardText(p: any): string
	local left = math.max(0, math.ceil(num(p.cooldownEnds, 0) - os.time()))
	local from = math.floor(num(p.repeatFrom, 0))
	local wait = math.max(0, math.ceil(num(p.repeatReadyAt, 0) - os.time()))
	if p.pay == "resting" then
		return if wait > 0 then "Bonus is resting, back in " .. Format.time(wait) else "Bonus is resting"
	elseif left > 0 and num(p.stage, from) < from then
		return "No reward: the run again bonus starts at plate " .. from
	elseif left > 0 and wait > 0 then
		return "No reward this time: run again bonus in " .. Format.time(wait)
	end
	return if left > 0 then "No reward this time: plates pay again in " .. Format.time(left) else "No reward this time"
end

local function rewardText(p: any): string?
	local cash = num(p.cash, 0)
	if cash <= 0 then
		return if p.full == false then noRewardText(p) else nil
	end
	-- Inside the reward cooldown a real run still pays its share (`pay` = "repeat").
	if p.pay == "repeat" or p.full == false then
		local share = math.floor(num(p.repeatShare, Economy.MODE_REPEAT_SHARE) * 100 + 0.5)
		return string.format("Run again bonus +%s (%d%%)", Format.money(cash), share)
	end
	return "+" .. Format.money(cash)
end

-- "Best plate 5" beside the Speed: the personal best. `pop` marks a new one.
local function setBest(best: number, pop: boolean?)
	bestStage = math.clamp(math.floor(best), 0, 10)
	local text = if bestStage > 0 then "Best plate " .. bestStage else "No best plate yet"
	if bestLine.Text ~= text then
		bestLine.Text = text
		if pop then
			Kit.pop(bestLine, 1.5)
		end
	end
end

-- WIN plates ----------------------------------------------------------------------------------

-- Seconds until the run again bonus is paid again (0 = it is now): it has a short gap after
-- every plate that paid.
local function repeatLeft(): number
	return math.max(0, math.ceil(num(snap.repeatReadyAt, 0) - os.time()))
end

-- The run again bonus safe zone n's WIN pad pays inside the reward cooldown (0 = none: the
-- pad pays in full, or it is before the best plate).
local function repeatCash(n: number): number
	local repeats = snap.repeats
	return if type(repeats) == "table" and type(repeats[n]) == "number" then repeats[n] else 0
end

-- What safe zone n's WIN pad pays right now (0 = nothing), if known.
local function winCash(n: number): number?
	local wins = snap.wins
	if type(wins) == "table" and type(wins[n]) == "number" then
		-- The snapshot can be older than the bonus' gap: once that is over the bonus counts.
		return if wins[n] <= 0 and repeatLeft() <= 0 then repeatCash(n) else wins[n]
	end
	return zoneCash[n]
end

-- Seconds until a WIN pad that pays nothing pays again (0 when it should pay already).
local function cooldownLeft(): number
	return math.max(0, math.ceil(num(snap.cooldownEnds, 0) - os.time()))
end

-- Is safe zone n's WIN pad still a first clear (always paid, and kept if you run past)?
local function winFirst(n: number): boolean
	local firsts = snap.firsts
	if type(firsts) == "table" and type(firsts[n]) == "boolean" then
		return firsts[n]
	end
	return zoneFirst[n] == true
end

-- Does a WIN pad deeper than zone n pay right now?
local function deeperPays(n: number): boolean
	for m = n + 1, stageCount do
		local cash = winCash(m)
		if cash and cash > 0 then
			return true
		end
	end
	return false
end

-- The stage line while standing in a safe zone: what its WIN plate pays right now, that
-- stepping on it ends the run, and what happens to the reward if you run past.
local function paintWin()
	local cash = if zoneIn > 0 then winCash(zoneIn) else nil
	local show = active and cash ~= nil
	local note: string? = nil
	if show then
		local left = cooldownLeft()
		local pays = (cash :: number) > 0
		local bonus = repeatCash(zoneIn) > 0
		if pays then
			winLabel.Text = (if bonus then "WIN plate: run again bonus +" else "WIN plate: +")
				.. Format.money(cash)
				.. "  ·  it ends this run"
			-- True in Modes.Cardio: first clears are kept per plate (profile.cardio.firsts).
			if winFirst(zoneIn) and zoneIn < stageCount then
				note = "Skip it and this first win stays for later"
			end
		else
			winLabel.Text = "NO REWARD on this WIN plate right now"
			local from = math.floor(num(snap.repeatFrom, 0))
			note = if bonus
				then "Run again bonus in " .. Format.time(repeatLeft()) .. ". Stepping on it ends this run!"
				elseif left > 0 and zoneIn < from then "Run again bonus from plate " .. from .. ". Stepping here ends this run!"
				elseif left > 0 then "Pays again in " .. Format.time(left) .. ". Stepping on it ends this run!"
				else "Stepping on it ends this run!"
		end
		winLabel.TextColor3 = if pays then GOLD else WHITE
		winNote.Text = note or ""
	end
	winNote.Visible = show and note ~= nil
	if show ~= winLabel.Visible then
		winLabel.Visible = show
		if show then
			Kit.appear(winLabel, { from = 0.7 })
		end
	end
	-- The need hint steps down while the win lines are up.
	hintLabel.Position = UDim2.fromOffset(0, if not show then 30 elseif note then 72 else 52)
end

-- The floating amount over every WIN pad: what it pays this player right now.
local function paintPads()
	for _, pad in CollectionService:GetTagged(WIN_TAG) do
		local gui = pad:FindFirstChild("WinLabel")
		local amount = gui and gui:FindFirstChild("Amount")
		if amount and amount:IsA("TextLabel") then
			local n = math.floor(num(pad:GetAttribute("Stage"), 0))
			local cash = winCash(n)
			local text = "CASH OUT"
			if active and cash then
				-- A pad that pays nothing right now says so (stepping on it still ends the run);
				-- one whose run again bonus waits for its gap counts down to it.
				local bonus = repeatCash(n)
				text = if cash > 0
					then "+" .. Format.money(cash)
					elseif bonus > 0 then "+" .. Format.money(bonus) .. " in " .. Format.time(repeatLeft())
					elseif cooldownLeft() > 0 then "NO REWARD"
					else "CASH OUT"
			end
			if amount.Text ~= text then
				amount.Text = text
			end
		end
	end
end

-- The safe zone (1..10) whose deck is under `pos`, from the WIN pads' zone attributes.
local function zoneAt(pos: Vector3): number
	for _, pad in CollectionService:GetTagged(WIN_TAG) do
		local x0, x1 = num(pad:GetAttribute("ZoneX0"), 0), num(pad:GetAttribute("ZoneX1"), 0)
		local z0, z1 = num(pad:GetAttribute("ZoneZ0"), 0), num(pad:GetAttribute("ZoneZ1"), 0)
		if pos.X >= x0 and pos.X <= x1 and pos.Z >= z0 and pos.Z <= z1 then
			return math.floor(num(pad:GetAttribute("Stage"), 0))
		end
	end
	return 0
end

-- Speed box, stage line, custom speed ---------------------------------------------------------

local function paintSpeedText()
	speedLabel.Text = speedText(shownSpeed + 0.5) .. ' <font size="42">Speed</font>'
end

-- Bar, stage line and hint; cheap, runs every frame while active.
local function paintNeed()
	local next = stage + 1
	if stage >= stageCount then
		stageLabel.Text = "ALL STAGES CLEAR!"
		barText.Text = "MAX STAGE!"
		barFill.Size = UDim2.fromScale(1, 1)
		barFill.BackgroundColor3 = MINT
		barTick.Visible = false
		hintLabel.Visible = false
		hintShown = false
		return
	end
	local name = nameOf(next)
	stageLabel.Text = string.format("STAGE %d%s", next, if name then "  ·  " .. string.upper(name) else "")
	local need = needOf(next)
	if not need then
		barText.Text = "Stage " .. next
		barFill.Size = UDim2.fromScale(0, 1)
		barTick.Visible = false
		hintLabel.Visible = false
		hintShown = false
		return
	end
	-- The bar runs to the recommended Speed; a tick marks the need on the way.
	local best = recommendedOf(next, need)
	local full = math.max(best, 1)
	local ready = targetSpeed >= need
	barText.Text = if not ready
		then string.format("Stage %d  ·  %s / %s", next, speedText(shownSpeed), speedText(need))
		elseif targetSpeed < best then string.format(
			"Stage %d  ·  %s  ·  recommended %s",
			next,
			speedText(shownSpeed),
			speedText(best)
		)
		else string.format("Stage %d  ·  %s  ·  ready!", next, speedText(shownSpeed))
	local k = math.clamp(shownSpeed / full, 0, 1)
	barFill.Size = UDim2.fromScale(math.max(k, 0.04), 1)
	barFill.BackgroundColor3 = if ready then MINT else GOLD
	barTick.Visible = best > need
	barTick.Position = UDim2.fromScale(need / full, 0)
	if (not ready) ~= hintShown then
		hintShown = not ready
		hintLabel.Visible = hintShown
		if hintShown then
			Kit.appear(hintLabel, { from = 0.7 })
		end
	end
	if hintShown then
		-- A gentle colour pulse so the hint reads as a call to action.
		hintLabel.TextColor3 = HINT_DIM:Lerp(HINT_BRIGHT, 0.5 + 0.5 * math.sin(os.clock() * 6))
	end
end

local function setTarget(speed: number, exact: boolean?)
	if exact then
		targetSpeed = speed
		shownSpeed = speed
		paintSpeedText()
	elseif speed > targetSpeed then
		targetSpeed = speed
	end
end

local function paintCustom()
	local cap = snap.speedCap
	if type(cap) ~= "number" or cap <= 0 then
		maxSeen = math.max(walkSpeed, num(snap.maxWalkSpeed, 0))
	end
	local maxWalk = num(snap.maxWalkSpeed, maxSeen)
	maxLabel.Text = "Your Max Speed: " .. math.floor(maxWalk + 0.5)
	currentLabel.Text = "Current speed: " .. math.floor(walkSpeed + 0.5)
	if not capBox:IsFocused() then
		capBox.Text = if type(cap) == "number" and cap > 0 then tostring(math.floor(cap)) else ""
	end
end

local function setWalk(ws: number)
	walkSpeed = ws
	paintCustom()
end

local function setMultiplier(mult: number)
	local text = "Multiplier x" .. multText(mult) .. " (Stages)"
	if multLine.Text ~= text then
		local grew = multLine.Text ~= "" and active
		multLine.Text = text
		if grew then
			Kit.pop(multLine, 1.3)
		end
	end
	treadLine.Text = "Treadmill Lv " .. math.clamp(math.floor(num(snap.treadmill, 0)), 0, MAX_LEVEL)
	setBest(num(snap.bestStage, bestStage))
end

-- Custom Speed is a small chip until tapped; OK and the run's end fold it again.
local function setCustomOpen(open: boolean)
	customOpen = open
	customBody.Visible = open
	customChip.Visible = not open
	customCard.Size = UDim2.fromOffset(if open then COLUMN_W else CHIP_W, if open then 168 else 40)
	customTitle.TextSize = if open then 22 else 17
	customTitle.Size = UDim2.fromOffset((if open then COLUMN_W else CHIP_W) - 54, 26)
	customTitle.Position = UDim2.fromOffset(14, if open then 9 else 7)
	customToggle.Position = UDim2.new(1, -8, 0, if open then 8 else 6)
	Kit.setButton(customToggle, if open then "–" else "+", C.SurfaceHi)
	if not open and capBox:IsFocused() then
		capBox:ReleaseFocus()
	end
end

local function sendCap()
	local digits = string.gsub(capBox.Text, "%D", "")
	local cap = math.clamp(tonumber(digits) or 0, 0, MAX_CAP)
	capBox:ReleaseFocus()
	action:FireServer({ action = "CardioSpeedCap", cap = cap })
	Kit.pop(capButton, 1.2)
	snap.speedCap = if cap > 0 then cap else nil
	paintCustom()
	setCustomOpen(false)
end

-- Cards ---------------------------------------------------------------------------------------

local function paintTreadmill()
	local rate = num(snap.treadmillRate, 0)
	local on = snap.onTreadmill == true
	-- Compact touch: the SPEED UP card takes the treadmill card's place near the pad.
	local show = active and (on or nearTreadmill) and not (compactTouch and nearPad and not on)
	if show ~= treadCard.Visible then
		if show then
			Kit.appear(treadCard, { from = 0.8 })
		else
			Kit.disappear(treadCard)
		end
	end
	treadTitle.Text = if on then "RUNNING!" else "TREADMILL"
	treadTitle.TextColor3 = if on then MINT else C.Text
	treadRate.Text = if rate > 0 then "+" .. speedText(rate) .. " speed/s" else "Hop on to train!"
end

local function paintUpgrade()
	local level = math.clamp(math.floor(num(snap.treadmill, 0)), 0, MAX_LEVEL)
	local cost = num(snap.nextCost, 0)
	local show = active and nearPad
	if show ~= upCard.Visible then
		if show then
			Kit.appear(upCard, { from = 0.8 })
		else
			Kit.disappear(upCard)
		end
	end
	upLevel.Text = string.format("Treadmill Lv %d/%d", level, MAX_LEVEL)
	upRate.Text = "+" .. speedText(num(snap.treadmillRate, 0)) .. "/s"
	for i, pip in upPips do
		pip.BackgroundColor3 = if i <= level then GOLD else C.Well
	end
	if level >= MAX_LEVEL then
		Kit.setButton(upButton, "MAX!", C.SurfaceHi)
		Kit.setEnabled(upButton, false)
	else
		local money = 0
		local data = State.data
		if type(data) == "table" then
			money = num(data.money, 0)
		end
		Kit.setEnabled(upButton, true)
		Kit.setButton(upButton, if cost > 0 then Format.money(cost) else "UPGRADE", if money >= cost then C.Good else C.SurfaceHi)
	end
end

-- Proximity to the upgrade pad and treadmills (flat distance, every PROXIMITY_EVERY s).
local function pivotOf(inst: Instance): Vector3?
	if inst:IsA("BasePart") then
		return inst.Position
	elseif inst:IsA("Model") then
		return inst:GetPivot().Position
	end
	return nil
end

local function nearTagged(tag: string, from: Vector3, radius: number): boolean
	for _, inst in CollectionService:GetTagged(tag) do
		local pos = pivotOf(inst)
		if pos then
			local flat = Vector3.new(pos.X - from.X, 0, pos.Z - from.Z).Magnitude
			if flat <= radius and math.abs(pos.Y - from.Y) < 14 then
				return true
			end
		end
	end
	return false
end

local function checkProximity()
	local char = player.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	local pad, tread = false, false
	zoneIn = 0
	if hrp and hrp:IsA("BasePart") then
		pad = nearTagged("CardioUpgradePad", hrp.Position, NEAR_PAD)
		tread = nearTagged("CardioTreadmill", hrp.Position, NEAR_TREADMILL)
		zoneIn = zoneAt(hrp.Position)
	end
	paintWin()
	if pad ~= nearPad then
		nearPad = pad
		paintUpgrade()
	end
	if tread ~= nearTreadmill then
		nearTreadmill = tread
		paintTreadmill()
	end
end

-- Per frame -----------------------------------------------------------------------------------

local function render(dt: number)
	-- Smooth count-up toward the server's Speed (eased, at least 1 per frame).
	if shownSpeed ~= targetSpeed then
		local gap = targetSpeed - shownSpeed
		local stepBy = gap * math.min(1, dt * 7)
		if math.abs(stepBy) < 1 then
			stepBy = math.sign(gap) * math.min(math.abs(gap), math.max(1, math.abs(gap) * dt * 7))
		end
		shownSpeed += stepBy
		if math.abs(targetSpeed - shownSpeed) < 0.5 then
			shownSpeed = targetSpeed
		end
		paintSpeedText()
	end
	paintNeed()
	-- Treadmill stripes scroll while on it.
	if treadCard.Visible then
		local rate = if snap.onTreadmill == true then 60 else 14
		for _, stripe in treadBelt:GetChildren() do
			if stripe:IsA("Frame") then
				local base = num(stripe:GetAttribute("Base"), 0)
				local x = (base - os.clock() * rate) % 72 - 12
				stripe.Position = UDim2.fromOffset(x, 0)
			end
		end
	end
	local now = os.clock()
	if now - proximityAt >= PROXIMITY_EVERY then
		proximityAt = now
		checkProximity()
	end
	-- The pads' cooldown countdowns tick on their own (and the stage line's, in a safe zone).
	if now - padsAt >= PADS_EVERY then
		padsAt = now
		paintPads()
		if zoneIn > 0 then
			paintWin()
		end
	end
end

-- Show / hide ---------------------------------------------------------------------------------

-- The Hud's bottom-centre dumbbell steps aside for the speed box during a run.
local CLUTTER = { "Dumbbell", "Menu", "Units", "Wallet", "DepositStrip", "FreeCorner", "Version", "ChestPanel" }
local stashed: { [GuiObject]: boolean } = {}
local function setRunActive(on: boolean)
	local gui = screen
	if not gui then
		return
	end
	gui:SetAttribute("RunActive", on)
	gui:SetAttribute("CardioActive", on)
	-- The Hud's other blocks (icon grid, cash, bonus strip, gift, chad counter, crate
	-- panel) step aside too, so only the run, QUIT and the Settings gear stay. The Promo
	-- hides itself on "CardioActive" (Hud). Each block gets back the Visible it had.
	if on then
		for _, name in CLUTTER do
			local gui2 = gui:FindFirstChild(name)
			if gui2 and gui2:IsA("GuiObject") and stashed[gui2] == nil then
				stashed[gui2] = gui2.Visible
				gui2.Visible = false
			end
		end
	else
		for gui2, was in stashed do
			gui2.Visible = was
		end
		table.clear(stashed)
	end
end

-- Music level during a Cardio run (1 = normal).
local MUSIC_DUCK = 0.25
-- Seconds after a run ends before the root frame hides (past the blocks' Kit.disappear).
local ROOT_HIDE = 0.3
local hideToken = 0

local function show()
	if active then
		return
	end
	active = true
	hideToken += 1
	-- Music a bit quieter during a run so the key clicks come through.
	Sounds.setMusicDuck(MUSIC_DUCK)
	quitArmed = false
	Kit.setButton(quitButton, "QUIT", C.SurfaceHi)
	hintShown = false
	hintLabel.Visible = false
	nearPad, nearTreadmill = false, false
	zoneIn = 0
	table.clear(zoneCash)
	table.clear(zoneFirst)
	paintWin()
	paintPads()
	treadCard.Visible = false
	upCard.Visible = false
	root.Visible = true
	Kit.appear(stageLine, { from = 0.7, time = 0.3 })
	Kit.appear(boxBody, { from = 0.7, time = 0.3 })
	Kit.appear(customCard, { from = 0.8, time = 0.3, delay = 0.05 })
	Kit.appear(quitButton, { from = 0.8, time = 0.3, delay = 0.1 })
	setRunActive(true)
	paintCustom()
	if not renderConn then
		renderConn = RunService.RenderStepped:Connect(render)
	end
end

-- Closes the finish card and drops a gamepad selection left on its buttons, so the stick
-- goes back to running.
local function hideFinish()
	Kit.unfocus(finishCard)
	if finishCard.Visible then
		Kit.disappear(finishCard)
	end
end

-- The one way out of a run: the "stop" Notify (a quit, Home, a mode switch, a respawn,
-- leaving the track) and the snapshot's `running` going false. Nothing of the run stays on
-- screen: no banner (a queued "STAGE n" title included), no finish card, and the
-- full-screen root goes once its blocks have eased out.
local function hide()
	bannerToken += 1
	if banner.Visible then
		Kit.disappear(banner)
	end
	hideFinish()
	if not active then
		return
	end
	active = false
	hideToken += 1
	local mine = hideToken
	task.delay(ROOT_HIDE, function()
		if hideToken == mine and not active then
			root.Visible = false
		end
	end)
	Sounds.setMusicDuck(1)
	setRunActive(false)
	if renderConn then
		renderConn:Disconnect()
		renderConn = nil
	end
	zoneIn = 0
	paintWin()
	paintPads()
	capBox:ReleaseFocus()
	setCustomOpen(false)
	Kit.disappear(stageLine)
	Kit.disappear(boxBody)
	Kit.disappear(customCard)
	Kit.disappear(quitButton)
	Kit.disappear(treadCard)
	Kit.disappear(upCard)
end

local function applySnapshot(s: { [string]: any }, exact: boolean)
	snap = s
	stageCount = math.clamp(math.floor(num(s.stageCount, 10)), 1, 10)
	stage = math.floor(num(s.stage, stage))
	setTarget(num(s.speed, targetSpeed), exact)
	setWalk(num(s.walkSpeed, walkSpeed))
	setMultiplier(num(s.multiplier, 1))
	if active then
		paintTreadmill()
		paintUpgrade()
		paintWin()
		paintPads()
	end
end

local function showFinish(p: any)
	finishSub.Text = string.format("You cleared all %d stages!", stageCount)
	finishReward.Text = rewardText(p) or ""
	finishReward.Visible = finishReward.Text ~= ""
	Kit.appear(finishCard, { from = 0.5, time = 0.35 })
	Kit.confetti(screen :: any, { Count = 28, Origin = UDim2.fromScale(0.5, 0.35), Power = 1.2 })
	Sounds.play("Celebrate")
	if Kit.gamepad then
		Kit.select(Kit.firstSelectable(finishCard))
	end
end

-- Notify / state / steps ----------------------------------------------------------------------

function CardioHud.onNotify(p: any)
	if not screen or type(p) ~= "table" then
		return
	end
	local event = tostring(p.event)
	if event == "start" then
		startedAt = os.clock()
		hideFinish()
		-- A run always starts in the lobby (stage 1).
		stage = 0
		setTarget(num(p.speed, targetSpeed), true)
		setWalk(num(p.walkSpeed, walkSpeed))
		setMultiplier(num(p.multiplier, 1))
		setBest(num(p.bestStage, bestStage))
		show()
		Sounds.play("Ready")
		-- The personal best to chase, once there is one.
		local chase = if bestStage <= 0
			then "Every key you step on = +Speed!"
			elseif bestStage >= stageCount then "Best plate " .. bestStage .. ": all the way!"
			else "Best plate " .. bestStage .. ". Can you go deeper?"
		showBanner("CARDIO!", chase, MINT, 2)
		stageTitle(2.4)
	elseif event == "zone" then
		-- Reached a safe zone: nothing is paid yet, its WIN plate shows what it would pay.
		local n = math.floor(num(p.stage, stage))
		stage = n
		local cash = num(p.cash, 0)
		zoneCash[n] = cash
		zoneFirst[n] = p.first == true
		-- What this zone's WIN plate does right now; never a promise the plates can't keep.
		local sub
		if cash > 0 and p.pay == "repeat" then
			sub = "WIN plate: run again bonus +" .. Format.money(cash) .. " (ends this run)"
		elseif cash > 0 then
			sub = "WIN plate: +" .. Format.money(cash) .. " (it ends this run)"
		elseif deeperPays(n) then
			sub = "No reward on this plate now. A deeper one pays!"
		else
			local left = math.max(0, math.ceil(num(p.cooldownEnds, 0) - os.time()))
			sub = if left > 0 then noRewardText(p) else "No reward on this plate right now"
		end
		showBanner("STAGE " .. n .. " CLEAR!", sub, MINT, 2.4)
		stageTitle(2.8)
		Sounds.play("Step")
		paintWin()
		paintPads()
	elseif event == "win" then
		-- Cashed out on a WIN plate: paid, and back in the lobby for the next run.
		stage = 0
		zoneIn = 0
		table.clear(zoneCash)
		table.clear(zoneFirst)
		paintWin()
		-- A claim deeper than the best plate is a new personal best.
		local newBest = p.newBest == true
		setBest(num(p.bestStage, bestStage), newBest)
		if p.final == true then
			showFinish(p)
		elseif newBest then
			local reward = rewardText(p)
			local plate = "Plate " .. math.floor(num(p.stage, bestStage))
			showBanner("NEW BEST!", if reward then plate .. "  ·  " .. reward else plate, GOLD, 2.6)
			stageTitle(3)
			Sounds.play("Celebrate")
			if screen then
				Kit.confetti(screen, { Count = 26, Origin = UDim2.fromScale(0.5, 0.3), Power = 1.2 })
			end
		elseif num(p.cash, 0) <= 0 then
			-- The plate paid nothing (the cooldown) and still ended the run: say so, no party.
			showBanner("RUN OVER", noRewardText(p), WHITE, 2.4)
			stageTitle(2.8)
			Sounds.play("Step")
		else
			showBanner("YOU WIN!", rewardText(p), GOLD, 2.4)
			stageTitle(2.8)
			Sounds.play("Reward")
			if screen then
				Kit.confetti(screen, { Count = 18, Origin = UDim2.fromScale(0.5, 0.3) })
			end
		end
	elseif event == "fall" then
		-- A fall or a catch: the run starts over in the lobby (the chaser's own "MOGGED!"
		-- splash plays first on a catch).
		stage = 0
		zoneIn = 0
		table.clear(zoneCash)
		table.clear(zoneFirst)
		paintWin()
		local caught = p.reason == "caught"
		-- What happened, from the server: the run was slower than the stage's need gives (not
		-- enough Speed, or the player's own speed cap), or it was fast enough and just fell /
		-- got caught.
		local from = math.floor(num(p.from, 1))
		local need = num(p.need, needOf(from) or 0)
		local title, sub
		if p.capped == true then
			title = if caught then "CAUGHT!" else "TOO SLOW!"
			sub = "Your Custom Speed is too low for Stage " .. from .. ". Raise it!"
		elseif p.slow == true then
			title = if caught then "CAUGHT!" else "TOO SLOW!"
			sub = "Stage " .. from .. " needs " .. speedText(need) .. " Speed. Back to Stage 1."
		elseif caught then
			title = "CAUGHT!"
			sub = "Keep running, don't stop! Back to Stage 1."
		else
			title = "OOPS!"
			sub = "You fell in Stage " .. from .. ". Back to Stage 1."
		end
		showBanner(title, sub, CORAL, 2.2, if caught then 1.2 else nil)
		Sounds.play("Error")
	elseif event == "refused" then
		-- The server already toasted why; just shake the button.
		Sounds.play("Error")
		if upCard.Visible then
			Kit.pop(upButton, 1.2)
		end
	elseif event == "upgrade" then
		local level = math.floor(num(p.level, num(snap.treadmill, 0)))
		snap.treadmill = level
		Sounds.play("Upgrade")
		showBanner("TREADMILL LV " .. level .. "!", "Treadmills give more Speed", GOLD, 1.8)
		paintUpgrade()
		setMultiplier(num(p.multiplier, num(snap.multiplier, 1)))
		Kit.pop(treadLine, 1.4)
		for i = 1, math.min(level, #upPips) do
			task.delay(0.03 * i, function()
				Kit.pop(upPips[i], 1.6)
			end)
		end
	elseif event == "stop" then
		hide()
		local reason = p.reason
		if reason == "left" then
			Popups.toast("You left Cardio. Run ended", "info")
		elseif reason == "respawn" then
			Popups.toast("Run reset. Hop back in at the gate!", "info")
		elseif reason == "quit" then
			Popups.toast("Cardio run ended", "info")
		end
	end
end

function CardioHud.onState(data: any)
	if not screen or type(data) ~= "table" then
		return
	end
	local modes = data.modes
	local s = type(modes) == "table" and modes.cardio
	if type(s) ~= "table" then
		return
	end
	local exact = not active
	applySnapshot(s, exact)
	if s.running == true and not active then
		show()
	elseif s.running == false and active and os.clock() - startedAt > 2 then
		hide()
	end
end

-- The step pops themselves float in 3D (Fx.Cardio); here the number just counts up.
function CardioHud.onSteps(data: any)
	if not screen or type(data) ~= "table" then
		return
	end
	local gained = num(data.gained, 0)
	if data.speed ~= nil then
		setTarget(num(data.speed, targetSpeed))
	elseif gained > 0 then
		setTarget(targetSpeed + gained)
	end
	if data.walkSpeed ~= nil then
		setWalk(num(data.walkSpeed, walkSpeed))
	end
	-- The treadmill rate grows with Speed: keep "+X speed/s" live.
	if type(data.rate) == "number" and data.rate ~= snap.treadmillRate then
		snap.treadmillRate = data.rate
		if active then
			paintTreadmill()
			paintUpgrade()
		end
	end
	-- Every gain pops the number (bigger gains, bigger bounce).
	if active and gained > 0 then
		Kit.pop(speedLabel, math.clamp(0.45 + gained / 60, 0.45, 1.1))
	end
end

-- Build ---------------------------------------------------------------------------------------

local function buildBox()
	box = Kit.new("Frame", {
		Name = "CardioSpeed",
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(BOX_W, BOX_H),
		Position = UDim2.new(0.5, 0, 1, -16),
		AnchorPoint = Vector2.new(0.5, 1),
		ZIndex = 20,
		Parent = root,
	})
	-- The holder carries the layout scale; the body is what appears (Kit.appear tweens
	-- the first UIScale it finds).
	boxScale = Kit.new("UIScale", { Parent = box })
	local body = Kit.new("Frame", {
		Name = "Body",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		Visible = false,
		ZIndex = 20,
		Parent = box,
	})
	boxBody = body
	speedLabel = Kit.hudText(body, {
		Name = "Speed",
		Text = "0",
		RichText = true,
		TextSize = SPEED_TEXT,
		Size = UDim2.new(1, 0, 0, SPEED_H),
		Position = UDim2.fromOffset(0, 0),
		ZIndex = 22,
		StrokeThickness = 6,
	})
	Kit.gradient(speedLabel, WHITE, Color3.fromRGB(214, 226, 255), 90)

	-- Chunky bar toward the next stage's need.
	local track = Kit.new("Frame", {
		Name = "NeedBar",
		BackgroundColor3 = C.Ink,
		BackgroundTransparency = 0.1,
		BorderSizePixel = 0,
		Size = UDim2.new(1, -24, 0, BAR_H),
		Position = UDim2.new(0.5, 0, 0, SPEED_H + 4),
		AnchorPoint = Vector2.new(0.5, 0),
		ZIndex = 21,
		Parent = body,
	})
	Kit.round(track)
	Kit.new("UIStroke", { Color = C.Ink, Thickness = 3, Parent = track })
	local inner = Kit.new("Frame", {
		Name = "Inner",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, -8, 1, -8),
		Position = UDim2.fromScale(0.5, 0.5),
		AnchorPoint = Vector2.new(0.5, 0.5),
		ZIndex = 22,
		Parent = track,
	})
	barFill = Kit.new("Frame", {
		Name = "Fill",
		BackgroundColor3 = GOLD,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(0.04, 1),
		ZIndex = 22,
		Parent = inner,
	})
	Kit.round(barFill)
	Kit.gradient(barFill, WHITE, Color3.new(0.78, 0.78, 0.84), 90)
	-- The need: the bar itself runs on to the recommended Speed (paintNeed places the tick).
	barTick = Kit.new("Frame", {
		Name = "NeedTick",
		BackgroundColor3 = C.Ink,
		BorderSizePixel = 0,
		Size = UDim2.new(0, 3, 1, 0),
		Position = UDim2.fromScale(1 / RECOMMEND, 0),
		AnchorPoint = Vector2.new(0.5, 0),
		Visible = false,
		ZIndex = 23,
		Parent = inner,
	})
	barText = Kit.hudText(track, {
		Name = "Need",
		Text = "",
		TextSize = 18,
		Size = UDim2.fromScale(1, 1),
		ZIndex = 24,
	})

	-- Multiplier lines: beside the number on wide screens, above it on narrow ones.
	side = Kit.new("Frame", {
		Name = "Lines",
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(SIDE_W, 50),
		ZIndex = 21,
		Parent = body,
	})
	sideLayout = Kit.new("UIListLayout", {
		Padding = UDim.new(0, 2),
		SortOrder = Enum.SortOrder.LayoutOrder,
		Parent = side,
	})
	multLine = Kit.hudText(side, {
		Name = "Multiplier",
		Text = "",
		TextSize = 17,
		TextColor3 = Kit.lighten(GRAPE, 0.3),
		AutomaticSize = Enum.AutomaticSize.X,
		Size = UDim2.fromOffset(0, 22),
		LayoutOrder = 1,
		ZIndex = 22,
	})
	treadLine = Kit.hudText(side, {
		Name = "Treadmill",
		Text = "Treadmill Lv 0",
		TextSize = 17,
		TextColor3 = Kit.lighten(MINT, 0.2),
		AutomaticSize = Enum.AutomaticSize.X,
		Size = UDim2.fromOffset(0, 22),
		LayoutOrder = 2,
		ZIndex = 22,
	})
	-- The personal best: the deepest WIN plate claimed.
	bestLine = Kit.hudText(side, {
		Name = "Best",
		Text = "No best plate yet",
		TextSize = 17,
		TextColor3 = Kit.lighten(GOLD, 0.2),
		AutomaticSize = Enum.AutomaticSize.X,
		Size = UDim2.fromOffset(0, 22),
		LayoutOrder = 3,
		ZIndex = 22,
	})
end

local function buildCustom()
	customCard = Kit.panel(column, {
		Name = "CustomSpeed",
		Size = UDim2.fromOffset(CHIP_W, 40),
		LayoutOrder = 1,
		Radius = 18,
		Visible = false,
	})
	customTitle = Kit.title(customCard, {
		Name = "Title",
		Text = "Custom Speed",
		TextSize = 17,
		TextXAlignment = Enum.TextXAlignment.Left,
		Size = UDim2.fromOffset(CHIP_W - 54, 26),
		Position = UDim2.fromOffset(14, 7),
		ZIndex = 3,
	})
	customToggle = Kit.button(customCard, {
		Name = "Toggle",
		Text = "+",
		Color = C.SurfaceHi,
		TextSize = 18,
		Size = UDim2.fromOffset(30, 28),
		Position = UDim2.new(1, -8, 0, 8),
		AnchorPoint = Vector2.new(1, 0),
		Radius = 14,
		Depth = 2,
		ZIndex = 4,
	}, function()
		setCustomOpen(not customOpen)
	end)
	Kit.selectable(customToggle)
	-- The whole collapsed chip opens the box (not just the + button).
	customChip = Kit.new("TextButton", {
		Name = "Chip",
		Text = "",
		BackgroundTransparency = 1,
		AutoButtonColor = false,
		Size = UDim2.fromScale(1, 1),
		ZIndex = 5,
		Parent = customCard,
	})
	customChip.Activated:Connect(function()
		setCustomOpen(true)
	end)
	customBody = Kit.new("Frame", {
		Name = "Body",
		Visible = false,
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 1, -44),
		Position = UDim2.fromOffset(0, 40),
		ZIndex = 3,
		Parent = customCard,
	})
	maxLabel = Kit.text(customBody, {
		Name = "Max",
		Text = "Your Max Speed: 16",
		Font = F.UI,
		TextSize = 15,
		TextColor3 = C.Text,
		TextXAlignment = Enum.TextXAlignment.Left,
		Size = UDim2.new(1, -28, 0, 20),
		Position = UDim2.fromOffset(14, 0),
		ZIndex = 3,
	})
	capBox = Kit.new("TextBox", {
		Name = "Cap",
		Text = "",
		PlaceholderText = "No limit",
		PlaceholderColor3 = C.TextDim,
		ClearTextOnFocus = false,
		Font = F.Display,
		TextSize = 22,
		TextColor3 = C.Text,
		BackgroundColor3 = C.Well,
		BorderSizePixel = 0,
		Size = UDim2.new(1, -28 - 72, 0, 40),
		Position = UDim2.fromOffset(14, 26),
		ZIndex = 4,
		Parent = customBody,
	})
	Kit.corner(capBox, 12)
	Kit.stroke(capBox, 2, C.SurfaceHi)
	capBox:GetPropertyChangedSignal("Text"):Connect(function()
		local digits = string.sub(string.gsub(capBox.Text, "%D", ""), 1, 6)
		if digits ~= capBox.Text then
			capBox.Text = digits
		end
	end)
	capBox.FocusLost:Connect(function(enter)
		if enter then
			sendCap()
		end
	end)
	capButton = Kit.button(customBody, {
		Name = "Ok",
		Text = "OK",
		Color = C.Good,
		Font = F.Display,
		TextSize = 20,
		Size = UDim2.fromOffset(64, 40),
		Position = UDim2.new(1, -14, 0, 26),
		AnchorPoint = Vector2.new(1, 0),
		Radius = 12,
		ZIndex = 4,
	}, sendCap)
	Kit.selectable(capButton)
	currentLabel = Kit.text(customBody, {
		Name = "Current",
		Text = "Current speed: 16",
		Font = F.UI,
		TextSize = 15,
		TextColor3 = MINT,
		TextXAlignment = Enum.TextXAlignment.Left,
		Size = UDim2.new(1, -28, 0, 20),
		Position = UDim2.fromOffset(14, 72),
		ZIndex = 3,
	})
	Kit.text(customBody, {
		Name = "Hint",
		Text = "Empty or 0 = no limit",
		Font = F.UI,
		TextSize = 12,
		TextColor3 = C.TextDim,
		TextXAlignment = Enum.TextXAlignment.Left,
		Size = UDim2.new(1, -28, 0, 16),
		Position = UDim2.fromOffset(14, 94),
		ZIndex = 3,
	})

	quitButton = Kit.button(column, {
		Name = "Quit",
		Text = "QUIT",
		Color = C.SurfaceHi,
		Font = F.Display,
		TextSize = 15,
		Size = UDim2.fromOffset(96, 34),
		LayoutOrder = 9,
		Radius = 14,
		Depth = 2,
		ZIndex = 4,
	}, function()
		quitPress()
	end)
	quitButton.Visible = false
	Kit.selectable(quitButton)
	local quitHit = Kit.hitArea(quitButton, 48, function()
		Kit.sound("Click")
		quitPress()
	end)
	quitHit.Visible = Kit.touch
	Kit.onInput(function()
		quitHit.Visible = Kit.touch
	end)
	quitPress = function()
		if quitArmed then
			quitArmed = false
			action:FireServer({ action = "ModeQuit" })
			return
		end
		quitArmed = true
		Kit.setButton(quitButton, "QUIT?", C.Bad)
		Kit.pop(quitButton, 1.2)
		task.delay(3, function()
			if quitArmed then
				quitArmed = false
				Kit.setButton(quitButton, "QUIT", C.SurfaceHi)
			end
		end)
	end
end

local function buildTreadmillCard()
	treadCard = Kit.panel(column, {
		Name = "Treadmill",
		Size = UDim2.fromOffset(COLUMN_W, 62),
		LayoutOrder = 2,
		Radius = 18,
		Visible = false,
	})
	-- A little belt with scrolling stripes.
	treadBelt = Kit.new("Frame", {
		Name = "Belt",
		BackgroundColor3 = C.Ink,
		BorderSizePixel = 0,
		ClipsDescendants = true,
		Size = UDim2.fromOffset(60, 22),
		Position = UDim2.fromOffset(12, 31),
		AnchorPoint = Vector2.new(0, 0.5),
		ZIndex = 3,
		Parent = treadCard,
	})
	Kit.corner(treadBelt, 8)
	Kit.stroke(treadBelt, 2, MINT)
	for i = 0, 5 do
		local stripe = Kit.new("Frame", {
			Name = "Stripe",
			BackgroundColor3 = MINT,
			BackgroundTransparency = 0.25,
			BorderSizePixel = 0,
			Size = UDim2.fromOffset(5, 30),
			Position = UDim2.fromOffset(i * 12, 0),
			Rotation = 20,
			ZIndex = 4,
			Parent = treadBelt,
		})
		stripe:SetAttribute("Base", i * 12)
	end
	treadTitle = Kit.text(treadCard, {
		Name = "Title",
		Text = "TREADMILL",
		Font = F.Display,
		TextSize = 16,
		TextXAlignment = Enum.TextXAlignment.Left,
		Size = UDim2.fromOffset(170, 20),
		Position = UDim2.fromOffset(84, 8),
		ZIndex = 3,
	})
	treadRate = Kit.number(treadCard, {
		Name = "Rate",
		Text = "",
		TextSize = 22,
		TextColor3 = MINT,
		TextXAlignment = Enum.TextXAlignment.Left,
		Size = UDim2.fromOffset(170, 26),
		Position = UDim2.fromOffset(84, 28),
		ZIndex = 3,
	})
end

local function buildUpgradeCard()
	upCard = Kit.panel(column, {
		Name = "SpeedUp",
		Size = UDim2.fromOffset(COLUMN_W, 112),
		LayoutOrder = 3,
		Radius = 18,
		Visible = false,
		StrokeColor = GOLD,
		StrokeThickness = 2,
	})
	Kit.title(upCard, {
		Name = "Title",
		Text = "SPEED UP",
		TextSize = 22,
		TextColor3 = GOLD,
		TextXAlignment = Enum.TextXAlignment.Left,
		Size = UDim2.fromOffset(140, 26),
		Position = UDim2.fromOffset(14, 8),
		ZIndex = 3,
	})
	upRate = Kit.number(upCard, {
		Name = "Rate",
		Text = "",
		TextSize = 18,
		TextColor3 = MINT,
		TextXAlignment = Enum.TextXAlignment.Right,
		Size = UDim2.fromOffset(100, 26),
		Position = UDim2.new(1, -14, 0, 8),
		AnchorPoint = Vector2.new(1, 0),
		ZIndex = 3,
	})
	upLevel = Kit.text(upCard, {
		Name = "Level",
		Text = "Treadmill Lv 0/10",
		Font = F.UI,
		TextSize = 14,
		TextColor3 = C.TextDim,
		TextXAlignment = Enum.TextXAlignment.Left,
		Size = UDim2.fromOffset(150, 18),
		Position = UDim2.fromOffset(14, 36),
		ZIndex = 3,
	})
	local pipRow = Kit.new("Frame", {
		Name = "Pips",
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(110, 30),
		Position = UDim2.fromOffset(14, 62),
		ZIndex = 3,
		Parent = upCard,
	})
	Kit.new("UIGridLayout", {
		CellSize = UDim2.fromOffset(18, 12),
		CellPadding = UDim2.fromOffset(4, 6),
		SortOrder = Enum.SortOrder.LayoutOrder,
		Parent = pipRow,
	})
	for i = 1, MAX_LEVEL do
		local pip = Kit.new("Frame", {
			Name = "Pip" .. i,
			BackgroundColor3 = C.Well,
			BorderSizePixel = 0,
			LayoutOrder = i,
			ZIndex = 4,
			Parent = pipRow,
		})
		Kit.corner(pip, 4)
		table.insert(upPips, pip)
	end
	upButton = Kit.button(upCard, {
		Name = "Buy",
		Text = "UPGRADE",
		Color = C.Good,
		Font = F.Display,
		TextSize = 20,
		Size = UDim2.fromOffset(112, 46),
		Position = UDim2.new(1, -12, 1, -12),
		AnchorPoint = Vector2.new(1, 1),
		Radius = 14,
		ZIndex = 4,
		Shimmer = true,
	}, function()
		action:FireServer({ action = "CardioUpgrade" })
	end)
	Kit.selectable(upButton)
end

local function buildStageLine()
	stageLine = Kit.new("Frame", {
		Name = "CardioStage",
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(460, 50),
		Position = UDim2.new(0.5, 0, 0, STRIP_Y),
		AnchorPoint = Vector2.new(0.5, 0),
		Visible = false,
		ZIndex = 20,
		Parent = root,
	})
	stageLabel = Kit.hudText(stageLine, {
		Name = "Stage",
		Text = "",
		TextSize = 24,
		Size = UDim2.new(1, 0, 0, 28),
		ZIndex = 22,
		StrokeThickness = 3,
	})
	winLabel = Kit.hudText(stageLine, {
		Name = "Win",
		Text = "",
		TextSize = 18,
		TextColor3 = GOLD,
		Size = UDim2.new(1, 0, 0, 22),
		Position = UDim2.fromOffset(0, 29),
		Visible = false,
		ZIndex = 22,
		StrokeThickness = 3,
	})
	-- Under the win line: what skipping the plate does, or when it pays again.
	winNote = Kit.hudText(stageLine, {
		Name = "WinNote",
		Text = "",
		TextSize = 15,
		Size = UDim2.new(1, 0, 0, 20),
		Position = UDim2.fromOffset(0, 51),
		Visible = false,
		ZIndex = 22,
	})
	hintLabel = Kit.hudText(stageLine, {
		Name = "Hint",
		Text = "Need more speed! Run on keys or hop on a treadmill",
		TextSize = 16,
		TextColor3 = Kit.lighten(CORAL, 0.15),
		Size = UDim2.new(1, 0, 0, 20),
		Position = UDim2.fromOffset(0, 30),
		Visible = false,
		ZIndex = 22,
	})
end

local function buildBanner(screenGui: ScreenGui)
	banner = Kit.new("Frame", {
		Name = "CardioBanner",
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(640, 110),
		Position = UDim2.new(0.5, 0, 0, TITLE_Y + 22),
		AnchorPoint = Vector2.new(0.5, 0),
		Visible = false,
		ZIndex = 30,
		Parent = screenGui,
	})
	bannerTitle = Kit.title(banner, {
		Text = "",
		TextSize = 66,
		TextWrapped = false,
		Size = UDim2.new(1, 0, 0, 72),
		ZIndex = 31,
		StrokeThickness = 0,
	})
	bannerTitle.Font = F.Display
	Kit.textStroke(bannerTitle, 6, 0)
	Kit.gradient(bannerTitle, WHITE, Color3.fromRGB(190, 200, 235), 90)
	bannerSub = Kit.hudText(banner, {
		Text = "",
		TextSize = 24,
		TextColor3 = C.MoneyText,
		Size = UDim2.new(1, 0, 0, 30),
		Position = UDim2.fromOffset(0, 76),
		ZIndex = 31,
		StrokeThickness = 3,
	})
end

local function buildFinish(screenGui: ScreenGui)
	finishCard = Kit.panel(screenGui, {
		Name = "CardioFinish",
		Size = UDim2.fromOffset(420, 250),
		Position = UDim2.fromScale(0.5, 0.48),
		AnchorPoint = Vector2.new(0.5, 0.5),
		Visible = false,
		ZIndex = 50,
		Elevated = true,
		StrokeColor = GOLD,
		StrokeThickness = 3,
	})
	Kit.icon(finishCard, iconName(), 64, MINT, {
		Position = UDim2.new(0.5, 0, 0, -30),
		AnchorPoint = Vector2.new(0.5, 0),
		ZIndex = 52,
	})
	Kit.title(finishCard, {
		Name = "Title",
		Text = "CARDIO CHAMPION!",
		TextSize = 38,
		TextColor3 = GOLD,
		Size = UDim2.new(1, -20, 0, 44),
		Position = UDim2.fromOffset(10, 40),
		ZIndex = 51,
	})
	finishSub = Kit.text(finishCard, {
		Name = "Sub",
		Text = "",
		Font = F.UI,
		TextSize = 17,
		TextColor3 = C.Text,
		Size = UDim2.new(1, -20, 0, 22),
		Position = UDim2.fromOffset(10, 86),
		ZIndex = 51,
	})
	finishReward = Kit.number(finishCard, {
		Name = "Reward",
		Text = "",
		TextSize = 26,
		TextColor3 = C.MoneyText,
		Size = UDim2.new(1, -20, 0, 32),
		Position = UDim2.fromOffset(10, 116),
		ZIndex = 51,
	})
	local again = Kit.button(finishCard, {
		Name = "Again",
		Text = "RUN AGAIN",
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
		action:FireServer({ action = "ModeStart", mode = "cardio" })
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

function CardioHud.build(screenGui: ScreenGui)
	screen = screenGui
	root = Kit.new("Frame", {
		Name = "CardioHud",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		Visible = false,
		ZIndex = 20,
		Parent = screenGui,
	})
	column = Kit.new("Frame", {
		Name = "Column",
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(COLUMN_W, 380),
		Position = UDim2.new(1, -24, 0.5, 0),
		AnchorPoint = Vector2.new(1, 0.5),
		ZIndex = 20,
		Parent = root,
	})
	Kit.list(column, 10, false, Enum.HorizontalAlignment.Right)
	buildBox()
	buildCustom()
	buildTreadmillCard()
	buildUpgradeCard()
	buildStageLine()
	buildBanner(screenGui)
	buildFinish(screenGui)

	-- Layout: compact screens shrink the box and the column; the desktop wallet (bottom
	-- left) keeps its room; touch keeps the jump button's corner (multiplier lines go
	-- above the number and the column rides higher). Custom Speed starts as a chip everywhere.
	local columnScale = Kit.new("UIScale", { Parent = column })
	local function relayout()
		local compact = screenGui:GetAttribute("Compact") == true
		compactTouch = compact and Kit.touch
		local view = screenGui.AbsoluteSize
		local scale = if compact then 0.78 else 1
		if not Kit.touch and view.X > 0 then
			local room = (view.X / 2 - WALLET_RIGHT) * 2
			if room < BOX_W * scale then
				scale = math.max(0.6, room / BOX_W)
			end
		end
		boxScale.Scale = scale
		box.Position = UDim2.new(0.5, 0, 1, if Kit.touch then -10 else -16)
		local wide = not Kit.touch and view.X / 2 >= (BOX_W / 2 + 12 + SIDE_W) * scale + 12
		if wide then
			side.Size = UDim2.fromOffset(SIDE_W, 74)
			side.Position = UDim2.new(1, 12, 0, 8)
			side.AnchorPoint = Vector2.zero
			sideLayout.FillDirection = Enum.FillDirection.Vertical
			sideLayout.HorizontalAlignment = Enum.HorizontalAlignment.Left
		else
			side.Size = UDim2.fromOffset(BOX_W + 80, 22)
			side.Position = UDim2.new(0.5, 0, 0, -4)
			side.AnchorPoint = Vector2.new(0.5, 1)
			sideLayout.FillDirection = Enum.FillDirection.Horizontal
			sideLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
		end
		sideLayout.Padding = UDim.new(0, if wide then 2 else 14)
		columnScale.Scale = if compact then 0.74 else 1
		column.Position = if Kit.touch then UDim2.new(1, -16, 0.5, -40) else UDim2.new(1, -24, 0.5, 0)
		if active then
			paintTreadmill()
		end
	end
	relayout()
	screenGui:GetAttributeChangedSignal("Compact"):Connect(relayout)
	screenGui:GetPropertyChangedSignal("AbsoluteSize"):Connect(relayout)
	Kit.onInput(relayout)
end

return CardioHud
