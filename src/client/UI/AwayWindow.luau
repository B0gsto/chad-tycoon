--[[
	AwayWindow: the "While you were away" card (rules: Shared.Comeback; built by
	DailyWindow, which owns the calm-screen gate the two share; Main routes the
	Offline notify here).

	Shown once per join to a player who was away long enough to earn something
	(Server.Tycoon's Offline notify): the cash the units earned, the crate the Smasher
	finished, today's daily card, the streak and the free gift, one row each and only
	the ones that are true. It stands in for the "Welcome back" popup, so a returning
	player gets one card, not two.

	It waits for a calm screen (`free`: the loading screen and the intro are gone, no
	window, popup, reward card or mode run is up), so it never sits on the Daily window
	or a reward card, and the Daily window's own auto-open waits for it
	(AwayWindow.holding). A player still in the tutorial gets the plain popup as before
	(`fallback`); one who stays busy for PATIENCE seconds gets a toast instead of a card
	that is no longer news.

	The one button leads on: CLAIM DAILY opens the Daily window when today's card is
	waiting, otherwise it closes the card.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Comeback = require(ReplicatedStorage.Shared.Comeback)
local Net = require(ReplicatedStorage.Shared.Net)

local Kit = require(script.Parent.Kit)
local State = require(script.Parent.Parent.State)

local Theme = Kit.Theme
local C = Kit.C
local T = Kit.TEXT
local F = Kit.F
local W = Theme.Words

local AwayWindow = {}

export type Deps = {
	register: (string, Kit.Window) -> (),
	-- Opens the Daily window (through Windows.open).
	openDaily: () -> (),
	close: () -> (),
	-- True while nothing the card may not cover is on screen.
	free: () -> boolean,
}

export type Hooks = {
	-- Opens a registered window by name (Windows.open).
	open: (string) -> (),
	-- The plain offline popup (Popups.offline), for a player still in the tutorial.
	fallback: ({ [string]: any }) -> (),
	toast: (string, string?) -> (),
}

local NAME = "Away"
local ACCENT = C.Rizz
local WIDTH = 560
local ROW_H = 64
local GAP = 8
local SECTION = 14
local NOTE_H = 22
local BUTTON_H = 56
local ICON = 44
local TEXT_LEFT = 12 + ICON + 12
local AMOUNT_W = 170
-- Seconds of calm before the card opens, and how long it waits for them.
local CALM = 1
local PATIENCE = 120
local ROLL = 0.6

-- Art per row: the atlas icon, the shape icon behind it when the atlas failed to load,
-- and that shape's colour.
type Art = { icon: string, fallback: string, color: Color3 }
local ART: { [string]: Art } = {
	cash = { icon = "Coin", fallback = "Coin", color = C.Gold },
	crate = { icon = "Free", fallback = "Free", color = C.Gold },
	daily = { icon = "Gift2", fallback = "Free", color = C.Gold },
	streak = { icon = "Fire", fallback = "Star", color = C.Amber },
	free = { icon = "Free", fallback = "Free", color = C.Good },
}

local screen: ScreenGui? = nil
local deps: Deps? = nil
local hooks: Hooks? = nil
local window: Kit.Window? = nil
-- A card is waiting for its calm moment.
local waiting = false

local function options(): Comeback.Options
	return { money = State.money, words = W, age = State.age() }
end

local function buildRow(parent: Instance, row: Comeback.Row, y: number): TextLabel?
	local art = ART[row.kind] or ART.free
	local frame = Kit.glass(parent, {
		Name = "Row" .. row.kind,
		Radius = Kit.RADIUS.M,
		Size = UDim2.new(1, 0, 0, ROW_H),
		Position = UDim2.fromOffset(0, y),
	})
	-- A crate row wears its rarity's crate and colour.
	local preferred = if row.rarity then "Crate" .. row.rarity else art.icon
	local tint: Color3 = if row.rarity then C.Rarity[row.rarity] or art.color else art.color
	Kit.icon(frame, Kit.pickIcon(preferred, art.fallback), ICON, tint, {
		Name = "Art",
		Position = UDim2.new(0, 12, 0.5, 0),
		AnchorPoint = Vector2.new(0, 0.5),
		ZIndex = 2,
	})
	local right = if row.cash then AMOUNT_W + 20 else 12
	Kit.text(frame, {
		Name = "Title",
		Text = row.title,
		Font = F.UI,
		TextSize = T.H3,
		MinPx = true,
		TextWrapped = false,
		TextTruncate = Enum.TextTruncate.AtEnd,
		TextXAlignment = Enum.TextXAlignment.Left,
		Size = UDim2.new(1, -(TEXT_LEFT + right), 0, 24),
		Position = UDim2.fromOffset(TEXT_LEFT, 9),
		ZIndex = 2,
	})
	Kit.text(frame, {
		Name = "Detail",
		Text = row.detail,
		TextSize = T.Small,
		MinPx = true,
		TextColor3 = C.Text,
		TextWrapped = false,
		TextTruncate = Enum.TextTruncate.AtEnd,
		TextXAlignment = Enum.TextXAlignment.Left,
		Size = UDim2.new(1, -(TEXT_LEFT + right), 0, 20),
		Position = UDim2.fromOffset(TEXT_LEFT, 35),
		ZIndex = 2,
	})
	if not row.cash then
		return nil
	end
	-- The cash is the card's key number: big, on the right, rolling up as the card opens.
	return Kit.number(frame, {
		Name = "Amount",
		Text = "+" .. State.money(row.cash),
		MaxTextSize = 28,
		MinPx = 18,
		TextColor3 = C.MoneyText,
		TextXAlignment = Enum.TextXAlignment.Right,
		Size = UDim2.new(0, AMOUNT_W, 0, 36),
		Position = UDim2.new(1, -12, 0.5, 0),
		AnchorPoint = Vector2.new(1, 0.5),
		ZIndex = 2,
	})
end

-- Builds the card for what is true right now and opens it. False when there is nothing
-- to say (or nothing to show it with).
local function present(offline: { [string]: any }?): boolean
	local data = State.data
	local gui, d, h = screen, deps, hooks
	if not data or not gui or not d or not h then
		return false
	end
	if window then
		-- Built already (the Studio preview hook asked again): the same card.
		if not window.isOpen() then
			h.open(NAME)
		end
		return true
	end
	local rows = Comeback.away(data, offline, options())
	if #rows == 0 then
		return false
	end
	local cash: number? = rows[1].cash
	local claimable = type(data.daily) == "table" and data.daily.claimable == true
	local listH = #rows * ROW_H + (#rows - 1) * GAP
	local noteH = if cash then GAP + NOTE_H else 0
	-- Window chrome (104) + rows + the note + the button on its lip.
	local height = 104 + listH + noteH + SECTION + BUTTON_H + 6
	local built = Kit.window(
		gui,
		NAME,
		"While you were away",
		Kit.pickIcon("Timer", "Home"),
		ACCENT,
		Vector2.new(WIDTH, height),
		Vector2.new(420, height)
	)
	window = built
	d.register(NAME, built)

	local amount: TextLabel? = nil
	for i, row in rows do
		amount = buildRow(built.content, row, (i - 1) * (ROW_H + GAP)) or amount
	end
	if cash then
		Kit.text(built.content, {
			Name = "Note",
			Text = Comeback.cashNote(data),
			TextSize = T.Small,
			MinPx = true,
			TextColor3 = C.Text,
			TextWrapped = false,
			TextTruncate = Enum.TextTruncate.AtEnd,
			Size = UDim2.new(1, 0, 0, NOTE_H),
			Position = UDim2.fromOffset(0, listH + GAP),
			StrokeThickness = 1,
			ZIndex = 2,
		})
	end
	local button = Kit.button(built.content, {
		Name = "Go",
		Text = if claimable then "CLAIM DAILY" else "LET'S GO!",
		Font = F.Display,
		TextSize = 24,
		Color = C.Gold,
		Size = UDim2.new(1, 0, 0, BUTTON_H),
		Position = UDim2.new(0, 0, 1, -6),
		AnchorPoint = Vector2.new(0, 1),
		ZIndex = 2,
	}, function()
		-- Read again at the press: the card may have been open over midnight or a claim.
		local now = State.data
		if now and type(now.daily) == "table" and now.daily.claimable == true then
			d.openDaily()
		else
			d.close()
		end
	end)
	button:SetAttribute("FocusFirst", true)
	-- Today's card was claimed (or a new day began) while the card was up: the button follows.
	State.changed.Event:Connect(function()
		local now = State.data
		local ready = now ~= nil and type(now.daily) == "table" and now.daily.claimable == true
		if ready ~= claimable then
			claimable = ready
			Kit.setButton(button, if ready then "CLAIM DAILY" else "LET'S GO!", C.Gold)
		end
	end)
	if amount and cash then
		local label, total = amount, cash
		built.onOpen.Event:Connect(function()
			Kit.countTo(label, 0, total, function(value: number): string
				return "+" .. State.money(value)
			end, ROLL)
		end)
	end
	h.open(NAME)
	-- Tells Analytics what the card listed (the server counts it once per session).
	local listed: { [string]: any } = { action = "AwayShown", cash = cash, crate = false, daily = false }
	for _, row in rows do
		if row.kind == "crate" then
			listed.crate = row.rarity or true
		elseif row.kind == "daily" then
			listed.daily = true
		end
	end
	Net.event("Action"):FireServer(listed)
	return true
end

-- A card is waiting for a calm screen: the Daily window does not open by itself ahead of it.
function AwayWindow.holding(): boolean
	return waiting
end

-- Called by DailyWindow.build (it holds the window registry and the calm-screen gate).
function AwayWindow.build(screenGui: ScreenGui, buildDeps: Deps)
	screen = screenGui
	deps = buildDeps
end

-- Called by Main once the windows and popups exist.
function AwayWindow.connect(mainHooks: Hooks)
	hooks = mainHooks
end

--[[
	The Offline notify arrived ({ seconds, cash, orbs }): show the card at the next calm
	moment. `now` (the Studio preview hook) skips the wait.
]]
function AwayWindow.show(offline: { [string]: any }, now: boolean?)
	local d, h = deps, hooks
	if not h then
		return
	end
	if not d then
		-- No windows to build it in (the Lune preview): the plain popup.
		h.fallback(offline)
		return
	end
	if now then
		present(offline)
		return
	end
	if waiting or window then
		return
	end
	waiting = true
	task.spawn(function()
		local calm, waited = 0, 0
		while true do
			local step = task.wait(0.25)
			local data = State.data
			if data and data.tutorialDone ~= true then
				-- Back in the middle of the tutorial: the plain popup in the popup queue, which
				-- knows how to wait for the tutorial's own cards.
				waiting = false
				h.fallback(offline)
				return
			end
			if data and d.free() then
				calm += step
			else
				calm = 0
				waited += if data then step else 0
			end
			if calm >= CALM then
				waiting = false
				present(offline)
				return
			end
			if waited >= PATIENCE then
				-- Busy for minutes (a mode run, the shop): the card would be old news. The
				-- cash is still named once, quietly.
				waiting = false
				local cash = tonumber(offline.cash) or 0
				if cash >= 1 then
					local text = "Your %s earned %s while you were away"
					h.toast(string.format(text, W.Units, State.money(cash)), "good")
				end
				return
			end
		end
	end)
end

return AwayWindow
