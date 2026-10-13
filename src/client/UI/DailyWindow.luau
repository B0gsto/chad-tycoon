--[[
	DailyWindow: the Daily Reward window (rules: Shared.DailyReward; server:
	Server.Daily; the HUD's Daily button opens it).

	Seven day cards in a row (4 + 3 when the window narrows and always on a phone,
	Day 7 double width). A card is sized to its content: the day, its art (a growing
	cash pack, a crate on days 3 and 7), what it pays at the player's income right now
	(the second-largest thing on the card after the art) and, on a crate day, a chip in
	the crate's rarity colour. Claimed cards are dimmed and ticked; today's says TODAY
	in gold and glows (tap it or the CLAIM button); tomorrow's says TOMORROW. The footer
	row names what to do next on the left, with the countdown to the next UTC day, and
	holds the one button on the right.

	The streak saver (DailyReward.status) is free and automatic: the streak line says
	"Miss a day? Your streak is saved once a week.", the card whose claim used it wears
	a small blue shield, and once it is spent the line says so, so a second missed day
	is never a surprise.

	The window opens by itself once per session when a reward is waiting, after a
	calm moment: never during the intro or the tutorial, a game-mode run, or
	under another window or popup, and never within REWARD_QUIET seconds of a
	reward card. A player who finished the tutorial this session first walks one
	full lap (collects cash once), or has had LAP_PATIENCE seconds since it ended
	(a skipped tutorial, a player who never collects). A held crate makes it wait
	too, but not for ever (DailyReward.autoOpenTick): a crate can be carried for minutes.
	After a claim the window closes by itself, CLOSE_AFTER_CLAIM after the coins fly.
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
local G = Theme.Glass
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
-- Space between the streak line, the cards and the footer row (one row of cards).
local SECTION = 16
local HERO_H = 40
local FOOTER_H = 72
local FOOTER_COMPACT = 60
-- One row of tall cards: the day (HEAD_H) under CARD_TOP, then the art, the amount and the
-- crate chip stacked HEAD_GAP / STACK_GAP apart, CARD_BOTTOM above the card's edge.
local CARD_TOP = 10
local HEAD_H = 20
local HEAD_TEXT = 16 -- the day label: bold, a step over a caption
local HEAD_GAP = 8
local STACK_GAP = 6
local CARD_BOTTOM = 12
local ART_MAX = 96
local AMOUNT_H = 28
local AMOUNT_MAX = 24
local AMOUNT_MIN_PX = 18 -- the amount is the card's key number: never under this on the glass
local CHIP_H = 22
-- The design window holds exactly that: chrome (104) + streak + cards + footer.
local CARD_H = CARD_TOP + HEAD_H + HEAD_GAP + ART_MAX + STACK_GAP + AMOUNT_H + STACK_GAP + CHIP_H + CARD_BOTTOM
local DESIGN = Vector2.new(880, 104 + HERO_H + SECTION + CARD_H + SECTION + FOOTER_H)
-- Narrower than this (content width, design px) the cards wrap onto two rows.
local ONE_ROW_MIN = 700
-- Two rows of low, wide cards (a phone's short window): under SIDE_MAX_H tall and at least
-- SIDE_MIN_W wide, a card puts its art (SIDE_ART) beside a SIDE_TEXT wide text column.
local SIDE_MAX_H = 124
local SIDE_MIN_W = 180
local SIDE_ART = 56
local SIDE_TEXT = 112
-- Seconds of calm before the window opens by itself (longer right after the tutorial,
-- whose reward cards are still on their way).
local CALM = 2
local CALM_AFTER_TUTORIAL = 20
-- A player who never collects cash after the tutorial is not waited for longer than this.
local LAP_PATIENCE = 90
-- The window never opens by itself this soon after a reward card (a unit or crate reveal).
local REWARD_QUIET = 20
-- A claimed window closes by itself this long after the coins fly.
local CLOSE_AFTER_CLAIM = 1.5
-- ScreenGui attributes that mean "busy": a window, a popup or a mode run. The held-crate
-- panel ("CratePanelOpen") only holds the window back for a while.
local BUSY = { "WindowOpen", "ModalOpen", "RunActive", "ObbyMode", "CardioActive" }

-- The streak line's right half: the saver's rule, and what it says once the saver is spent.
local SAVER_RULE = "Miss a day? Your streak is saved once a week."
local SAVER_SPENT = "Streak saver used. Come back tomorrow!"
local SAVER_SAVES = "You missed a day: your streak is saved!"

-- Art per card: the cash packs grow with the days; days 3 and 7 show their crate.
local ART = { "CashPack1", "CashPack2", "CrateRare", "CashPack3", "CashPack4", "CashPack5", "CrateLegendary" }

type Card = {
	frame: Frame,
	header: TextLabel,
	art: Frame,
	amount: TextLabel,
	-- Crate days: a chip in the rarity colour ("RARE CRATE", or just "RARE" on a narrow card).
	chip: TextLabel?,
	chipFull: string,
	chipShort: string,
	tick: Frame,
	-- The streak saver's shield, on the card whose claim used it.
	shield: Frame,
	state: string,
}

-- Width of a chip that says `text` (TextService when available, else an estimate).
local function chipWidth(text: string): number
	local width = 0
	pcall(function()
		local TextService = game:GetService("TextService")
		width = TextService:GetTextSize(text, T.Small, F.UI, Vector2.new(1000, 40)).X
	end)
	if width <= 0 then
		width = (utf8.len(text) or #text) * T.Small * 0.62
	end
	return math.ceil(width) + 20
end

-- Repaints a day card: the plain dark card, or tinted `tint`, with an `edge` outline in the
-- state's colour (`edgeFade`: its transparency, for a dimmed card).
local function paint(frame: Frame, tint: Color3?, transparency: number?, edge: Color3?, thickness: number?, edgeFade: number?)
	Kit.paintGlass(frame, tint, transparency, edge)
	local stroke = frame:FindFirstChildOfClass("UIStroke")
	if stroke then
		stroke.Thickness = thickness or 1
		if edgeFade then
			stroke.Transparency = edgeFade
		end
	end
end

function DailyWindow.build(screen: ScreenGui, deps: Deps): Daily
	-- Minimum 386 tall: a phone gets that window at x1.3, with the cards in two low rows.
	local window = Kit.window(screen, "Daily", "Daily Reward", Kit.pickIcon("Gift2", "Free"), ACCENT, DESIGN, Vector2.new(500, 386))
	deps.register("Daily", window)
	local action = Net.event("Action")

	-- Streak line -------------------------------------------------------------------------
	local hero = Kit.new("Frame", {
		Name = "Streak",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, HERO_H),
		Parent = window.content,
	})
	Kit.icon(hero, Kit.pickIcon("Fire", "Star"), 36, C.Amber, {
		Name = "Icon",
		Position = UDim2.new(0, 2, 0.5, 0),
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
		Size = UDim2.new(0.5, -48, 1, 0),
		Position = UDim2.fromOffset(48, 1),
		ZIndex = 2,
	})
	local rule = Kit.text(hero, {
		Name = "Rule",
		Text = SAVER_RULE,
		TextSize = T.Small,
		MinPx = true,
		TextColor3 = C.Text,
		TextXAlignment = Enum.TextXAlignment.Right,
		Size = UDim2.new(0.5, -2, 1, 0),
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
			TextSize = HEAD_TEXT,
			MinPx = true,
			TextWrapped = false,
			Size = UDim2.new(1, 0, 0, HEAD_H),
			Position = UDim2.fromOffset(0, CARD_TOP),
			ZIndex = 3,
		})
		local art: Frame
		if Kit.hasImageIcon(ART[day]) then
			art = Kit.icon(frame, ART[day], ART_MAX, nil, { Name = "Art", ZIndex = 3 })
		else
			art = Kit.icon(frame, if reward.crate then "Free" else "Coin", ART_MAX, if reward.crate then C.Cash else C.Gold, {
				Name = "Art",
				ZIndex = 3,
			})
		end
		art.AnchorPoint = Vector2.new(0.5, 0)
		-- The amount: bold, outlined, the biggest text on the card, with no "+" in front so a
		-- long one ("$179.52M") still fits at 18 px. Scaled down further only when it has to:
		-- full numbers ("$1,234,567") are much longer.
		local amount = Kit.number(frame, {
			Name = "Amount",
			Text = "",
			MaxTextSize = AMOUNT_MAX,
			MinPx = AMOUNT_MIN_PX,
			TextColor3 = C.MoneyText,
			Size = UDim2.new(1, -6, 0, AMOUNT_H),
			AnchorPoint = Vector2.new(0.5, 0),
			ZIndex = 3,
		})
		local chip: TextLabel? = nil
		local chipFull, chipShort = "", ""
		if reward.crate then
			chipFull = string.upper(reward.crate .. " " .. W.Chest)
			chipShort = string.upper(reward.crate)
			chip = Kit.pill(frame, {
				Name = "Crate",
				Text = chipFull,
				Color = C.Rarity[reward.crate] or C.Gold,
				Solid = true,
				TextSize = T.Small,
				MinPx = true,
				Size = UDim2.fromOffset(chipWidth(chipFull), CHIP_H),
				AnchorPoint = Vector2.new(0.5, 0),
				ZIndex = 3,
			})
		end
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
		Kit.new("UIStroke", { Thickness = 2, Color = C.Text, Parent = tick })
		Kit.icon(tick, "Check", 16, Kit.inkOn(C.Good), {
			Position = UDim2.fromScale(0.5, 0.5),
			AnchorPoint = Vector2.new(0.5, 0.5),
			ZIndex = 7,
		})
		-- Blue shield on the other corner of the card whose claim used the streak saver: a
		-- flat top over a point, built from two frames (the atlas has no shield).
		local shield = Kit.new("Frame", {
			Name = "Shield",
			BackgroundColor3 = C.Rizz,
			Size = UDim2.fromOffset(26, 26),
			Position = UDim2.fromOffset(4, 4),
			Visible = false,
			ZIndex = 6,
			Parent = frame,
		})
		Kit.round(shield)
		Kit.new("UIStroke", { Thickness = 2, Color = C.Text, Parent = shield })
		local ink = Kit.inkOn(C.Rizz)
		local top = Kit.new("Frame", {
			Name = "Top",
			BackgroundColor3 = ink,
			BorderSizePixel = 0,
			Size = UDim2.fromOffset(12, 7),
			Position = UDim2.fromOffset(7, 6),
			ZIndex = 7,
			Parent = shield,
		})
		Kit.new("UICorner", { CornerRadius = UDim.new(0, 2), Parent = top })
		Kit.new("Frame", {
			Name = "Point",
			BackgroundColor3 = ink,
			BorderSizePixel = 0,
			Size = UDim2.fromOffset(8, 8),
			Position = UDim2.fromOffset(13, 13),
			AnchorPoint = Vector2.new(0.5, 0.5),
			Rotation = 45,
			ZIndex = 7,
			Parent = shield,
		})
		local card: Card = {
			frame = frame,
			header = header,
			art = art,
			amount = amount,
			chip = chip,
			chipFull = chipFull,
			chipShort = chipShort,
			tick = tick,
			shield = shield,
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

	-- Footer row: what to do next on the left, the one button on the right ------------------
	local footer = Kit.well(window.content, {
		Name = "Footer",
		Glass = true,
		Size = UDim2.new(1, 0, 0, FOOTER_H),
		Position = UDim2.fromScale(0, 1),
		AnchorPoint = Vector2.new(0, 1),
	})
	local BUTTON_W = 200
	-- Headline over detail, centred as a pair on the row's middle line. While today's reward
	-- waits, the card (TODAY) and the CLAIM button already say so: the row keeps only the
	-- detail line. Once claimed, the headline is the countdown to the next one.
	local words = Kit.new("Frame", {
		Name = "Words",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, -(16 + 16 + BUTTON_W + 12), 0, 48),
		Position = UDim2.new(0, 16, 0.5, 0),
		AnchorPoint = Vector2.new(0, 0.5),
		ZIndex = 2,
		Parent = footer,
	})
	local headline = Kit.title(words, {
		Name = "Headline",
		Text = "",
		MaxTextSize = T.H2,
		MinPx = 16,
		TextWrapped = false,
		TextXAlignment = Enum.TextXAlignment.Left,
		Size = UDim2.new(1, 0, 0, 26),
		ZIndex = 2,
	})
	local detail = Kit.text(words, {
		Name = "Detail",
		Text = "",
		TextSize = 15,
		MinPx = true,
		TextColor3 = C.Text,
		TextWrapped = false,
		TextTruncate = Enum.TextTruncate.AtEnd,
		TextXAlignment = Enum.TextXAlignment.Left,
		Size = UDim2.new(1, 0, 0, 20),
		Position = UDim2.fromOffset(0, 28),
		ZIndex = 2,
	})
	local button = Kit.button(footer, {
		Name = "Claim",
		Text = "CLAIM",
		Font = F.Display,
		TextSize = 24,
		Color = C.Gold,
		Size = UDim2.fromOffset(BUTTON_W, 48),
		Position = UDim2.new(1, -12, 0.5, -2),
		AnchorPoint = Vector2.new(1, 0.5),
		ZIndex = 2,
	}, function()
		claim()
	end)
	button:SetAttribute("FocusFirst", true)

	-- State ---------------------------------------------------------------------------------
	local canClaim = false
	local claimSentAt = 0
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
		local fade = if claimed then G.Dimmed else 0
		card.header.TextTransparency = fade
		card.amount.TextTransparency = fade
		if card.chip then
			card.chip.TextTransparency = fade
			card.chip.BackgroundTransparency = fade
			local edge = card.chip:FindFirstChild("Edge")
			if edge and edge:IsA("UIStroke") then
				edge.Transparency = fade
			end
		end
		-- Today: a gold card in a gold outline. Claimed: dimmed, in a faint mint edge under
		-- its tick. Ahead (locked): the plain dark card, as solid as any other.
		if state == "today" then
			paint(card.frame, C.Gold, nil, C.Gold, 2.5)
		elseif claimed then
			paint(card.frame, nil, G.Dimmed, C.Good, 1, G.Dimmed)
		else
			paint(card.frame)
		end
		Kit.setGlow(card.frame, state == "today", C.Gold)
	end

	-- The footer's countdown to the next reward, once a second while open.
	local clockText = ""
	local function updateClock()
		local daily = dailyOf(State.data)
		if not daily or not todayClaimed then
			return
		end
		local text = Format.time(secondsLeft(daily))
		if text == clockText then
			return
		end
		clockText = text
		headline.Text = "Next reward in " .. text
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
		local tomorrowCard = if day < DailyReward.DAYS then day + 1 else 0
		-- The streak saver: the card that used it, whether today's claim does, and whether
		-- it is still there for the next missed day.
		local savedCard = math.floor(tonumber(daily.savedCard) or 0)
		local saves = canClaim and daily.saves == true
		local saverSpent = daily.saver == false
		local progression = Economy.progression(tonumber(data.highestTier) or 1, tonumber(data.processLevel) or 0)
		-- The surge-free income Server.Daily pays with.
		local income = tonumber(data.rewardIncome) or tonumber(data.income) or 0
		-- A player's first day pays today's card up to a cap (Server.Daily does the same).
		local cap = if daily.firstDay == true then DailyReward.firstDayCap(day, tonumber(data.bought) or 0) else nil
		for i, card in cards do
			card.amount.Text = State.money(DailyReward.cash(i, income, progression, if i == day then cap else nil))
			local state = if i <= claimed
				then "claimed"
				elseif i == day and canClaim then "today"
				elseif i == tomorrowCard then "tomorrow"
				else "later"
			if state ~= card.state then
				dress(card, i, state)
			end
			card.shield.Visible = i == savedCard
		end
		rule.Text = if saves then SAVER_SAVES elseif saverSpent then SAVER_SPENT else SAVER_RULE
		streakTitle.Text = if streak >= 2
			then string.format("%d DAY STREAK", streak)
			elseif streak == 1 then "1 DAY STREAK"
			else "START YOUR STREAK"
		headline.Visible = not canClaim
		detail.AnchorPoint = Vector2.new(0, if canClaim then 0.5 else 0)
		detail.Position = if canClaim then UDim2.fromScale(0, 0.5) else UDim2.fromOffset(0, 28)
		if canClaim then
			-- A short window has no streak line: the saver's news goes here instead.
			detail.Text = if saves
				then SAVER_SAVES
				elseif not hero.Visible then (if saverSpent then SAVER_SPENT else SAVER_RULE)
				else "Rewards grow every day, up to the big Day 7 gift"
			Kit.setButton(button, "CLAIM", C.Gold)
		else
			local nextDay = DailyReward.card(day + 1)
			local cash = State.money(DailyReward.cash(nextDay, income, progression))
			detail.Text = string.format("Tomorrow, Day %d: %s", nextDay, DailyReward.describe(nextDay, cash, W.Chest))
			Kit.setButton(button, "GOT IT", C.SurfaceHi)
		end
		clockText = ""
		updateClock()
	end

	-- Layout: one row of seven, or 4 + 3 with Day 7 double width (a narrow window, and
	-- always a phone: touch on a Compact screen, whose window is short and scaled up) -------
	local function layout()
		local size = window.size()
		-- Window chrome (24 wide, 84 tall) and the content well's padding (10 a side).
		local width, height = size.X - 44, size.Y - 104
		local phone = Kit.touch and screen:GetAttribute("Compact") == true
		local big = width >= ONE_ROW_MIN and not phone
		hero.Visible = big
		local between = if big then SECTION else GAP
		local top = if big then HERO_H + between else 0
		local footerH = if big then FOOTER_H else FOOTER_COMPACT
		footer.Size = UDim2.new(1, 0, 0, footerH)
		local gridH = height - top - footerH - between
		grid.Position = UDim2.fromOffset(0, top)
		grid.Size = UDim2.new(1, 0, 0, gridH)
		local columns = if big then DailyReward.DAYS else 4
		local rows = if big then 1 else 2
		local cellW = (width - (columns - 1) * GAP) / columns
		local cellH = (gridH - (rows - 1) * GAP) / rows
		-- Low, wide cards: the art on the left, the amount and the chip stacked beside it.
		local side = not big and cellH < SIDE_MAX_H and cellW >= SIDE_MIN_W
		local headY = if big then CARD_TOP else 6
		local bodyTop = headY + HEAD_H + (if big then HEAD_GAP else 4)
		local bodyH = cellH - bodyTop - (if big then CARD_BOTTOM else 8)
		local stackGap = if big then STACK_GAP else 4
		local amountH = if big then AMOUNT_H else 22
		local chipH = if big then CHIP_H else 20
		-- Every card wears the same art: what a crate day's stack leaves it.
		local artSize = if side
			then math.floor(math.min(SIDE_ART, bodyH))
			else math.floor(math.clamp(bodyH - amountH - chipH - stackGap * 2, 28, math.min(ART_MAX, cellW - 16)))
		for day, card in cards do
			local column = (day - 1) % columns
			local row = (day - 1) // columns
			local wide = not big and day == DailyReward.DAYS
			local cardW = math.floor(if wide then cellW * 2 + GAP else cellW)
			card.frame.Position = UDim2.fromOffset(math.floor(column * (cellW + GAP)), math.floor(row * (cellH + GAP)))
			card.frame.Size = UDim2.fromOffset(cardW, math.floor(cellH))
			card.header.Position = UDim2.fromOffset(0, headY)
			card.art.Size = UDim2.fromOffset(artSize, artSize)
			local chip = card.chip
			local textW = if side then SIDE_TEXT else cardW - 8
			if chip then
				-- The whole name when the card has room for it, else the rarity alone.
				local full = chipWidth(card.chipFull) <= textW
				chip.Text = if full then card.chipFull else card.chipShort
				chip.Size = UDim2.fromOffset(math.min(chipWidth(chip.Text), textW), chipH)
			end
			if side then
				-- Art and text column, centred together in the card under its header.
				local left = (cardW - (artSize + GAP + SIDE_TEXT)) // 2
				local textX = left + artSize + GAP + SIDE_TEXT // 2
				local stack = amountH + (if chip then stackGap + chipH else 0)
				local y = bodyTop + math.floor((bodyH - stack) / 2)
				card.art.Position = UDim2.fromOffset(left + artSize // 2, bodyTop + math.floor((bodyH - artSize) / 2))
				card.amount.Size = UDim2.fromOffset(SIDE_TEXT, amountH)
				card.amount.Position = UDim2.fromOffset(textX, y)
				if chip then
					chip.Position = UDim2.fromOffset(textX, y + amountH + stackGap)
				end
			else
				-- Art, amount and chip as one stack, centred in the card under its header.
				local stack = artSize + stackGap + amountH + (if chip then stackGap + chipH else 0)
				local y = bodyTop + math.max(math.floor((bodyH - stack) / 2), 0)
				card.art.Position = UDim2.new(0.5, 0, 0, y)
				card.amount.Size = UDim2.new(1, -6, 0, amountH)
				card.amount.Position = UDim2.new(0.5, 0, 0, y + artSize + stackGap)
				if chip then
					chip.Position = UDim2.new(0.5, 0, 0, y + artSize + stackGap + amountH + stackGap)
				end
			end
		end
		clockText = ""
		render()
	end
	layout()
	window.onResize.Event:Connect(layout)
	screen:GetAttributeChangedSignal("Compact"):Connect(layout)
	Kit.onInput(function()
		layout()
	end)
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
			-- Claimed: nothing is left to do here, so the window steps out by itself.
			task.delay(CLOSE_AFTER_CLAIM, function()
				if window.isOpen() then
					deps.close()
				end
			end)
		end)

		-- Opens by itself once per session when a reward is waiting and the screen is calm
		-- (not at all once the player has opened it from the HUD).
		local opened = false
		window.onOpen.Event:Connect(function()
			opened = true
		end)
		-- Reward cards: the Reward notify (its card may still be queued) and the reveal
		-- itself, from start to end (ScreenGui attribute "RevealOpen", Popups).
		local rewardAt = -math.huge
		local function noteReward()
			rewardAt = os.clock()
		end
		Net.event("Notify").OnClientEvent:Connect(function(payload)
			if type(payload) == "table" and payload.kind == "Reward" then
				noteReward()
			end
		end)
		screen:GetAttributeChangedSignal("RevealOpen"):Connect(noteReward)
		-- First full lap: cash collected (by hand or by Auto Cash) after the tutorial ended.
		-- The collect that ends the tutorial arrives before its state does, so it never counts.
		local lapped = false
		Net.event("Effect").OnClientEvent:Connect(function(kind, effect)
			if kind ~= "Cash" or type(effect) ~= "table" then
				return
			end
			local data = State.data
			if (effect.source == "Collect" or effect.source == "Auto") and data and data.tutorialDone == true then
				lapped = true
			end
		end)
		task.spawn(function()
			local player = Players.LocalPlayer
			local auto = DailyReward.autoOpen()
			local needed = CALM
			-- The tutorial was running this session: the window waits for the first lap, but
			-- no longer than LAP_PATIENCE after the tutorial ended.
			local sawTutorial = false
			local sinceTutorial = 0
			while not opened do
				local step = task.wait(0.5)
				local data = State.data
				local daily = dailyOf(data)
				if data and data.tutorialDone ~= true then
					sawTutorial = true
					needed = CALM_AFTER_TUTORIAL
				elseif data and sawTutorial and not lapped then
					sinceTutorial += step
					if sinceTutorial >= LAP_PATIENCE then
						lapped = true
					end
				end
				local ready = data ~= nil
					and daily ~= nil
					and daily.claimable == true
					and data.tutorialDone == true
					and (lapped or not sawTutorial)
					and player:GetAttribute("IntroPlaying") ~= true
					and player:GetAttribute("GameReady") == true
				if ready then
					local playerGui = player:FindFirstChildOfClass("PlayerGui")
					ready = not (playerGui and playerGui:FindFirstChild("LoadingScreen"))
				end
				for _, name in BUSY do
					ready = ready and screen:GetAttribute(name) ~= true
				end
				-- A held crate is waited for, then the window stops waiting for it.
				local crate = screen:GetAttribute("CratePanelOpen") == true
				-- A reward card does not restart the calm (the reveal itself does, as a popup):
				-- the window only waits out the rest of REWARD_QUIET.
				local quiet = os.clock() - rewardAt >= REWARD_QUIET
				if DailyReward.autoOpenTick(auto, step, not ready, crate, needed) and quiet and not opened then
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
