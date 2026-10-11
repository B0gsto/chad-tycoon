--[[
	DailyWindow: the Daily Reward window (rules: Shared.DailyReward; server:
	Server.Daily; the HUD's Daily button opens it).

	Seven day cards in a row (two rows when the window narrows, Day 7 double
	width): each shows its art (a growing cash pack, a crate on days 3 and 7) and
	what it pays at the player's income right now. Claimed cards are muted and
	ticked, today's is gold and glowing (tap it or CLAIM), tomorrow's says "Come
	back tomorrow" with a countdown to the next UTC day. The footer names what to
	do next.

	The window opens by itself once per session when a reward is waiting, after a
	calm moment: never during the intro or the tutorial, a game-mode run, or
	under another window or popup.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local DailyReward = require(ReplicatedStorage.Shared.DailyReward)
local Economy = require(ReplicatedStorage.Shared.Economy)
local Format = require(ReplicatedStorage.Shared.Format)
local Net = require(ReplicatedStorage.Shared.Net)

local Kit = require(script.Parent.Kit)
local State = require(script.Parent.Parent.State)

local Theme = Kit.Theme
local C = Kit.C
local T = Kit.TEXT
local F = Kit.F
local W = Theme.Words

-- The Lune preview exporter has no real tweens or frame time.
local PREVIEW = typeof(TweenInfo.new(0)) ~= "TweenInfo"

local DailyWindow = {}

export type Deps = {
	register: (string, Kit.Window) -> (),
	ripple: ({ GuiObject }) -> (),
	-- Opens this window through Windows.open (one window at a time, backdrop).
	open: () -> (),
	close: () -> (),
}

export type Daily = {
	window: Kit.Window,
	-- Runs before the window opens: refresh and card ripple.
	beforeOpen: () -> (),
}

local ACCENT = Theme.World.Sunny
local GAP = 8
local HERO_H = 50
local FOOTER_H = 56
-- Narrower than this (content width, design px) the cards wrap onto two rows.
local ONE_ROW_MIN = 700
-- Seconds of calm before the window opens by itself (longer right after the tutorial,
-- whose reward cards are still on their way).
local CALM = 2
local CALM_AFTER_TUTORIAL = 8
-- ScreenGui attributes that mean "busy": a window, a popup, the crate panel or a mode run.
local BUSY = { "WindowOpen", "ModalOpen", "CratePanelOpen", "RunActive", "ObbyMode", "CardioActive" }

-- Art per card: the cash packs grow with the days; days 3 and 7 show their crate.
local ART = { "CashPack1", "CashPack2", "CrateRare", "CashPack3", "CashPack4", "CashPack5", "CrateLegendary" }

type Card = {
	frame: Frame,
	header: TextLabel,
	art: Frame,
	amount: TextLabel,
	extra: TextLabel?,
	status: TextLabel,
	tick: Frame,
	state: string,
}

-- Repaints a day card's glass: plain, or tinted `tint` with a solid `edge` outline.
local function paint(frame: Frame, tint: Color3?, transparency: number?, edge: Color3?, thickness: number?)
	Kit.paintGlass(frame, tint, transparency, edge)
	local stroke = frame:FindFirstChildOfClass("UIStroke")
	if stroke then
		stroke.Thickness = thickness or 1
	end
end

function DailyWindow.build(screen: ScreenGui, deps: Deps): Daily
	local window =
		Kit.window(screen, "Daily", "Daily Reward", Kit.pickIcon("Gift2", "Free"), ACCENT, Vector2.new(880, 436), Vector2.new(500, 436))
	deps.register("Daily", window)
	local action = Net.event("Action")

	-- Streak line -------------------------------------------------------------------------
	local hero = Kit.new("Frame", {
		Name = "Streak",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, HERO_H),
		Parent = window.content,
	})
	Kit.icon(hero, Kit.pickIcon("Fire", "Star"), 40, C.Amber, {
		Name = "Icon",
		Position = UDim2.new(0, 4, 0.5, 0),
		AnchorPoint = Vector2.new(0, 0.5),
		ZIndex = 2,
	})
	local streakTitle = Kit.title(hero, {
		Name = "Title",
		Text = "",
		TextSize = T.H2 + 2,
		TextColor3 = C.Gold,
		TextWrapped = false,
		TextXAlignment = Enum.TextXAlignment.Left,
		Size = UDim2.new(0.5, -52, 1, 0),
		Position = UDim2.fromOffset(52, 1),
		ZIndex = 2,
	})
	Kit.text(hero, {
		Name = "Rule",
		Text = "Come back every day. Miss one and it starts again at Day 1!",
		TextSize = T.Small,
		TextColor3 = C.TextDim,
		TextXAlignment = Enum.TextXAlignment.Right,
		Size = UDim2.new(0.5, -8, 1, 0),
		Position = UDim2.new(0.5, 0, 0, 0),
		ZIndex = 2,
	})

	-- Day cards ---------------------------------------------------------------------------
	local grid = Kit.new("Frame", {
		Name = "Days",
		BackgroundTransparency = 1,
		Parent = window.content,
	})
	local claim: () -> ()
	local cards: { Card } = {}
	local frames: { GuiObject } = {}
	for day, reward in DailyReward.REWARDS do
		local frame = Kit.glass(grid, { Name = "Day" .. day, Radius = Kit.RADIUS.M })
		local header = Kit.text(frame, {
			Name = "Header",
			Text = "DAY " .. day,
			Font = F.UI,
			TextSize = T.Small,
			TextWrapped = false,
			Size = UDim2.new(1, 0, 0, 18),
			Position = UDim2.fromOffset(0, 8),
			ZIndex = 3,
		})
		local art: Frame
		if Kit.hasImageIcon(ART[day]) then
			art = Kit.icon(frame, ART[day], 64, nil, { Name = "Art", ZIndex = 3 })
		else
			art = Kit.icon(frame, if reward.crate then "Free" else "Coin", 64, if reward.crate then C.Cash else C.Gold, {
				Name = "Art",
				ZIndex = 3,
			})
		end
		art.AnchorPoint = Vector2.new(0.5, 0)
		-- Scaled down to fit: full numbers ("+$1,234,567") are much longer than "+$1.23M".
		local amount = Kit.number(frame, {
			Name = "Amount",
			Text = "",
			MaxTextSize = 17,
			TextColor3 = C.MoneyText,
			Size = UDim2.new(1, -8, 0, 22),
			AnchorPoint = Vector2.new(0.5, 0),
			ZIndex = 3,
		})
		local extra: TextLabel? = nil
		if reward.crate then
			extra = Kit.text(frame, {
				Name = "Crate",
				Text = string.upper(string.format("+ %s %s", reward.crate, W.Chest)),
				Font = F.UI,
				MaxTextSize = T.Tiny,
				TextColor3 = C.Rarity[reward.crate] or C.Gold,
				TextWrapped = false,
				Size = UDim2.new(1, -4, 0, 16),
				AnchorPoint = Vector2.new(0.5, 0),
				ZIndex = 3,
			})
		end
		local status = Kit.text(frame, {
			Name = "Status",
			Text = "",
			Font = F.UI,
			TextSize = T.Tiny,
			TextYAlignment = Enum.TextYAlignment.Bottom,
			Size = UDim2.new(1, -10, 0, 44),
			Position = UDim2.new(0.5, 0, 1, -8),
			AnchorPoint = Vector2.new(0.5, 1),
			ZIndex = 3,
		})
		-- Mint tick on the corner of a claimed card.
		local tick = Kit.new("Frame", {
			Name = "Tick",
			BackgroundColor3 = C.Good,
			Size = UDim2.fromOffset(26, 26),
			Position = UDim2.new(1, -4, 0, 4),
			AnchorPoint = Vector2.new(1, 0),
			Visible = false,
			ZIndex = 6,
			Parent = frame,
		})
		Kit.round(tick)
		Kit.new("UIStroke", { Thickness = 2, Color = Color3.new(1, 1, 1), Parent = tick })
		Kit.icon(tick, "Check", 16, Kit.inkOn(C.Good), {
			Position = UDim2.fromScale(0.5, 0.5),
			AnchorPoint = Vector2.new(0.5, 0.5),
			ZIndex = 7,
		})
		local card: Card = {
			frame = frame,
			header = header,
			art = art,
			amount = amount,
			extra = extra,
			status = status,
			tick = tick,
			state = "",
		}
		-- Tapping today's card claims it (gamepads use the CLAIM button).
		local hit = Kit.new("TextButton", {
			Name = "Hit",
			Text = "",
			AutoButtonColor = false,
			BackgroundTransparency = 1,
			Selectable = false,
			Size = UDim2.fromScale(1, 1),
			ZIndex = 8,
			Parent = frame,
		})
		hit.Activated:Connect(function()
			if card.state == "today" then
				Kit.sound("Click")
				claim()
			end
		end)
		cards[day] = card
		frames[day] = frame
	end

	-- Footer: what to do next + the one button ---------------------------------------------
	local footer = Kit.new("Frame", {
		Name = "Footer",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, FOOTER_H),
		Position = UDim2.fromScale(0, 1),
		AnchorPoint = Vector2.new(0, 1),
		Parent = window.content,
	})
	local headline = Kit.title(footer, {
		Name = "Headline",
		Text = "",
		TextSize = T.H2,
		TextWrapped = false,
		TextTruncate = Enum.TextTruncate.AtEnd,
		TextXAlignment = Enum.TextXAlignment.Left,
		Size = UDim2.new(1, -236, 0, 26),
		Position = UDim2.fromOffset(6, 4),
		ZIndex = 2,
	})
	local detail = Kit.text(footer, {
		Name = "Detail",
		Text = "",
		TextSize = T.Small,
		TextColor3 = C.TextDim,
		TextWrapped = false,
		TextTruncate = Enum.TextTruncate.AtEnd,
		TextXAlignment = Enum.TextXAlignment.Left,
		Size = UDim2.new(1, -236, 0, 20),
		Position = UDim2.fromOffset(6, 31),
		ZIndex = 2,
	})
	local button = Kit.button(footer, {
		Name = "Claim",
		Text = "CLAIM",
		Font = F.Display,
		TextSize = 24,
		Color = C.Gold,
		Size = UDim2.fromOffset(216, 50),
		Position = UDim2.new(1, -2, 0.5, -2),
		AnchorPoint = Vector2.new(1, 0.5),
		ZIndex = 2,
	}, function()
		claim()
	end)
	button:SetAttribute("FocusFirst", true)

	-- State ---------------------------------------------------------------------------------
	local big = true -- one row of tall cards
	local canClaim = false
	local claimSentAt = 0
	local tomorrowCard = 0
	local todayClaimed = false

	local function dailyOf(data: { [string]: any }?): { [string]: any }?
		local daily = data and data.daily
		return if type(daily) == "table" then daily else nil
	end
	local function secondsLeft(daily: { [string]: any }): number
		return math.max(0, (tonumber(daily.nextIn) or 0) - State.age())
	end

	claim = function()
		if not canClaim then
			deps.close()
			return
		end
		-- One request per press; the State snapshot that follows flips the button.
		if os.clock() - claimSentAt < 1.5 then
			return
		end
		claimSentAt = os.clock()
		action:FireServer({ action = "ClaimDaily" })
	end

	local function dress(card: Card, day: number, state: string)
		card.state = state
		local claimed = state == "claimed"
		card.tick.Visible = claimed
		card.header.Text = if state == "today" then "TODAY" elseif state == "tomorrow" then "TOMORROW" else "DAY " .. day
		card.header.TextColor3 = if state == "today" then C.Gold else C.Text
		card.header.TextTransparency = if claimed then 0.4 else 0
		card.amount.TextTransparency = if claimed then 0.4 else 0
		if card.extra then
			card.extra.TextTransparency = if claimed then 0.4 else 0
		end
		-- Today: sunny glass in a gold outline. Claimed: a fainter pane. Ahead: plain glass.
		if state == "today" then
			paint(card.frame, C.Gold, Theme.Glass.Tinted, C.Gold, 2.5)
		elseif claimed then
			paint(card.frame, nil, 0.95)
		else
			paint(card.frame)
		end
		Kit.setGlow(card.frame, state == "today", C.Gold)
	end

	-- The countdown texts (tomorrow's card and the footer), once a second while open.
	local clockText = ""
	local function updateClock()
		local daily = dailyOf(State.data)
		if not daily then
			return
		end
		local text = Format.time(secondsLeft(daily))
		if text == clockText then
			return
		end
		clockText = text
		local card = cards[tomorrowCard]
		if card and todayClaimed then
			card.status.Text = if big then "COME BACK TOMORROW\n" .. text else text
		end
		if todayClaimed then
			detail.Text = "Next reward in " .. text
		end
	end

	local function render()
		local data = State.data
		local daily = dailyOf(data)
		if not data or not daily then
			return
		end
		local day = math.clamp(math.floor(tonumber(daily.day) or 1), 1, DailyReward.DAYS)
		local claimed = math.clamp(math.floor(tonumber(daily.claimed) or 0), 0, DailyReward.DAYS)
		local streak = math.max(0, math.floor(tonumber(daily.streak) or 0))
		canClaim = daily.claimable == true
		todayClaimed = not canClaim
		tomorrowCard = if day < DailyReward.DAYS then day + 1 else 0
		local progression = Economy.progression(tonumber(data.highestTier) or 1, tonumber(data.processLevel) or 0)
		local income = tonumber(data.income) or 0
		for i, card in cards do
			card.amount.Text = "+" .. State.money(DailyReward.cash(i, income, progression))
			local state = if i <= claimed
				then "claimed"
				elseif i == day and canClaim then "today"
				elseif i == tomorrowCard then "tomorrow"
				else "later"
			if state ~= card.state then
				dress(card, i, state)
			end
			card.status.TextColor3 = if state == "today" then C.Gold elseif state == "claimed" then C.Good else C.TextDim
			card.status.Text = if state == "today" then "CLAIM!" elseif state == "claimed" then "CLAIMED" else ""
		end
		streakTitle.Text = if streak >= 2
			then string.format("%d DAY STREAK", streak)
			elseif streak == 1 then "1 DAY STREAK"
			else "START YOUR STREAK"
		if canClaim then
			headline.Text = string.format("Your Day %d reward is ready!", day)
			detail.Text = "Rewards grow every day, up to the big Day 7 gift"
			Kit.setButton(button, "CLAIM", C.Gold)
		else
			local nextDay = DailyReward.card(day + 1)
			local cash = State.money(DailyReward.cash(nextDay, income, progression))
			headline.Text = string.format("Come back tomorrow for Day %d: %s", nextDay, DailyReward.describe(nextDay, cash, W.Chest))
			Kit.setButton(button, "GOT IT", C.SurfaceHi)
		end
		clockText = ""
		updateClock()
	end

	-- Layout: one row of seven, or 4 + 3 with Day 7 double width -----------------------------
	local function layout(size: Vector2)
		-- Window chrome (24 wide, 84 tall) and the content well's padding (10 a side).
		local width, height = size.X - 44, size.Y - 104
		big = width >= ONE_ROW_MIN
		hero.Visible = big
		local top = if big then HERO_H + GAP else 0
		local gridH = height - top - FOOTER_H - GAP
		grid.Position = UDim2.fromOffset(0, top)
		grid.Size = UDim2.new(1, 0, 0, gridH)
		local columns = if big then DailyReward.DAYS else 4
		local rows = if big then 1 else 2
		local cellW = (width - (columns - 1) * GAP) / columns
		local cellH = (gridH - (rows - 1) * GAP) / rows
		local artSize = if big then 64 else 40
		for day, card in cards do
			local column = (day - 1) % columns
			local row = (day - 1) // columns
			local wide = not big and day == DailyReward.DAYS
			card.frame.Position = UDim2.fromOffset(math.floor(column * (cellW + GAP)), math.floor(row * (cellH + GAP)))
			card.frame.Size = UDim2.fromOffset(math.floor(if wide then cellW * 2 + GAP else cellW), math.floor(cellH))
			card.art.Size = UDim2.fromOffset(artSize, artSize)
			card.art.Position = UDim2.new(0.5, 0, 0, 30)
			card.amount.Position = UDim2.new(0.5, 0, 0, 34 + artSize)
			if card.extra then
				card.extra.Position = UDim2.new(0.5, 0, 0, 55 + artSize)
			end
			card.status.Size = UDim2.new(1, -10, 0, if big then 44 else 14)
		end
		clockText = ""
		render()
	end
	layout(window.size())
	window.onResize.Event:Connect(layout)
	State.changed.Event:Connect(render)

	if not PREVIEW then
		RunService.Heartbeat:Connect(function()
			if window.isOpen() then
				updateClock()
			end
		end)

		-- The claim landed: today's card pops under a burst of confetti (the cash, its coins
		-- and the crate reveal come through the usual Cash effect and Reward popup).
		Net.event("Notify").OnClientEvent:Connect(function(payload)
			if type(payload) ~= "table" or payload.kind ~= "Daily" or payload.event ~= "claimed" then
				return
			end
			Kit.sound("Reward")
			local card = cards[tonumber(payload.day) or 0]
			if card and window.isOpen() then
				Kit.pop(card.frame, 1)
				Kit.confetti(window.frame, { Origin = UDim2.fromScale(0.5, 0.45), Count = 24, ZIndex = 12 })
			end
		end)

		-- Opens by itself once per session when a reward is waiting and the screen is calm
		-- (not at all once the player has opened it from the HUD).
		local opened = false
		window.onOpen.Event:Connect(function()
			opened = true
		end)
		task.spawn(function()
			local player = Players.LocalPlayer
			local calm = 0
			local needed = CALM
			while not opened do
				local step = task.wait(0.5)
				local data = State.data
				local daily = dailyOf(data)
				if data and data.tutorialDone ~= true then
					needed = CALM_AFTER_TUTORIAL
				end
				local ready = data ~= nil
					and daily ~= nil
					and daily.claimable == true
					and data.tutorialDone == true
					and player:GetAttribute("IntroPlaying") ~= true
					and player:GetAttribute("GameReady") == true
				if ready then
					local playerGui = player:FindFirstChildOfClass("PlayerGui")
					ready = not (playerGui and playerGui:FindFirstChild("LoadingScreen"))
				end
				for _, name in BUSY do
					ready = ready and screen:GetAttribute(name) ~= true
				end
				calm = if ready then calm + step else 0
				if calm >= needed and not opened then
					deps.open()
					return
				end
			end
		end)
	end

	return {
		window = window,
		beforeOpen = function()
			render()
			deps.ripple(frames)
		end,
	}
end

return DailyWindow
