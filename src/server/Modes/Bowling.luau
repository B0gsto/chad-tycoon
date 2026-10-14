--!strict
--[[
	Modes.Bowling: DUMBBELL BOWL, a solo mini-game (docs/minigames.md). Arena: World.BowlingLane
	(context.world.bowling); rules: Modes.BowlingRules (pure, tested in tests/bowling.luau).

	A run goes lobby -> countdown -> play -> results -> lobby (docs/minigames.md, "Lobby
	first, then the game"). The plaza gate or "ModeStart" { mode = "bowling" } lands the
	player on the lobby spawn (phase "lobby": nothing timed, scored or paid). The START pad
	(feet within startRadius, after BowlingRules.REARM seconds in the lobby) or "BowlingBegin"
	moves them to the foul line (rollStart) for a BowlingRules.COUNTDOWN "3, 2, 1"; then a game
	of BowlingRules.FRAMES frames. On the player's turn ("ready") the HUD sweeps an aim arrow
	and a power meter and sends "BowlingRoll" { aim, power }; the server clamps both, plays
	the ball in pure code (BowlingRules.roll with a fresh seed) and sends the result ("roll")
	for the client to animate, so nothing on the lane is Roblox physics. The next "ready"
	comes when that animation is over. After the last ball: "win" (score >= PASS_SCORE: best,
	clears and the pay) or "lose", phase "results"; PLAY AGAIN is "BowlingBegin", LOBBY is
	"BowlingLobby", and with no input the player is back in the lobby after
	BowlingRules.RESULTS_SECONDS. A game earns stars at BowlingRules.STAR_TIERS (50 / 80 / 105);
	each star pays a small bonus, capped per BowlingRules.REPEAT_GAP window by the game's
	stars (BowlingRules "STARS": more stars, a higher cap), and the most stars ever
	(BowlingRules.starsEver: the best score's and the saved profile.modes.bowling.topStars)
	unlock dumbbells (BowlingRules.BALL_STARS: rack 3 at 1 star, rack 4 at 2, the
	gold-striped PRO at 3). Once the bowler's reaction has played (BowlingRules.skipAt: a
	strike's whole celebration, a second of the others) "BowlingSkip" ends the rest of the
	settle, except after the last ball. A turn left BowlingRules.AFK_SECONDS bowls a weak
	centre ball for the player (the friendlier choice: the game waits for them instead of
	ending); a game with BowlingRules.AUTO_LIMIT such balls pays nothing and counts for no best, clears or stars.
	Other players see the bowler through the character attributes "BowlFlex" = "<move>#<n>"
	(move: stance, bowl, strike, spare, miss, point; nil when not bowling) and "BowlBall" (the
	picked dumbbell 1..BALL_CHOICES); their clients pose that avatar and put a dumbbell of
	that colour in its hand. The EXIT arch (lobby or results only) or "ModeQuit" ends the
	run (stop "quit", back to the gates). A fall goes back to the lobby spawn in the lobby,
	else to the foul line.

	PROTOCOL (for the client). Notify: kind = "Mode", mode = "bowling", event =
	  "start"     { phase = "lobby", best, clears, rewardPreview, target, maxScore, frames,
	              choice, balls, lane, pins, ball, pin, aimSpread, pocket, power, windup,
	              countdown, resultsSeconds, tiers, starsEver, ballStars }
	              tiers = BowlingRules.STAR_TIERS (the star scores); pocket =
	              BowlingRules.POCKET (|aim| at or under it is the gold "PERFECT AIM!" band);
	              starsEver = the most stars of any game, ballStars = BowlingRules.BALL_STARS
	              (the stars each dumbbell needs; a locked one is refused)
	              lane = { x, z (foul line), top, width, length, gutter }, pins = { { x, d } }
	              (lane space: BowlingRules header); ball / pin = their sizes ({ radius,
	              halfLength } / { radius, height }); choice = the picked dumbbell (1..balls);
	              power = { sweetLo, sweetHi } (the meter's sweet spot); windup = seconds
	              from "roll" to the release
	  "lobby"     { best, clears, rewardPreview, choice, starsEver } (back in the lobby: hide the
	              results card; also sent after "BowlingLobby" and the auto-return)
	  "ball"      { choice } (a "BowlingBall" pick was taken)
	  "countdown" { seconds } (3, 2, 1; the first "ready" follows when it ends)
	  "ready"     { frame, shot, ball, standing, card, total, rack, seq } (your turn; shot =
	              ball number in the frame 1..3, ball = the picked dumbbell, rack = a full
	              set, seq = the turn's number in the run: a resend keeps it)
	  "roll"      { aim, power, zone, hook, windup, path, falls, knocked, gutter, mark, reset,
	              frame, shot, ball, card, total, over, wait, react, skipAt, auto, autoGame }
	              (path /
	              falls: BowlingRules.Roll,
	              their times count from the release, `windup` seconds after this event while
	              the player's avatar runs up and swings; zone = "soft" | "sweet" | "wild";
	              ball = the picked dumbbell 1..4 for its colour; mark = "strike" | "spare" |
	              "gutter" | nil; wait = seconds until the next event; react = seconds from the
	              release to the bowler's reaction; skipAt = seconds from this event after
	              which "BowlingSkip" is taken (nil after the last ball: none); auto =
	              the server bowled it (AFK); autoGame = this game no longer counts)
	  "win"       { score, target, best, newBest, first, cash, full, pay, packCash,
	              repeatCash, cooldownEnds, repeatEnds, lobbyIn, stars, bonus, starsEver,
	              unlocked } (stars = 0..3, unlocked = dumbbells this game unlocked,
	              bonus = the stars' cash this game (0: the window's bonuses are spent);
	              pay = "full" | "repeat" |
	              "none": the repeat share pays once per BowlingRules.REPEAT_GAP; repeatEnds =
	              when the next is due, 0 = now; lobbyIn = seconds until the auto-return)
	  "lose"      { score, target, best, newBest, lobbyIn, stars, starsEver, unlocked, auto }
	              (auto = an auto-bowled game: nothing counted, even a passing score)
	  "stop"      { reason }
	Actions (Tycoon "Action" remote, fields on the action table):
	  "BowlingBegin" {}          lobby or results only: a new game (countdown, then play).
	                             "BowlingAgain" is an alias (older clients).
	  "BowlingBall" { choice }   lobby or results only; integer 1..BowlingRules.BALL_CHOICES,
	                             unlocked (BowlingRules.ballUnlocked).
	  "BowlingRoll" { aim, power } play, on the player's turn only, at least
	                             BowlingRules.READY_GAP after its "ready"; aim -1..1, power
	                             0..1 (clamped; a non-number is no roll: "ready" again).
	  "BowlingSkip" {}           play, while a ball settles, from the roll's skipAt (not
	                             after the last ball): the next "ready" now.
	  "BowlingLobby" {}          results only: back to the lobby now.
	Snapshot modes.bowling: { running, phase, turn, ready, choice, best, clears, cooldownEnds,
	  rewardPreview, repeatEnds, target, tiers, starsEver } (phase = "lobby" | "countdown" | "play" |
	  "results"; turn = "none" | "aim" | "rolling"; ready = the open turn's "ready" payload
	  while turn is "aim", so a HUD that lost the event can show its controls).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Economy = require(ReplicatedStorage.Shared.Economy)

local Course = require(script.Parent.Course)
local BowlingRules = require(script.Parent.BowlingRules)

local ID = "bowling"
-- Feet are about this far under the HumanoidRootPart's centre (R15 default rig).
local FEET_BELOW_ROOT = 3
-- After a ball's last pin falls the pins settle and the bowler reacts
-- (BowlingRules.settle(mark)); a reset rack adds the sweep.
local RESET = 1.0
-- A roll sooner than this after the last one is ignored (the turn gate already blocks
-- rolls mid-animation; this stops a flood of remote calls).
local MIN_ROLL_GAP = 0.5
-- The character attribute other clients pose this bowler from ("<move>#<n>").
local FLEX_ATTR = "BowlFlex"
-- ...and the dumbbell it holds (the pick, 1..BowlingRules.BALL_CHOICES).
local BALL_ATTR = "BowlBall"

local Bowling = {}

type Run = {
	startedAt: number,
	game: BowlingRules.Game,
	-- "lobby" | "countdown" | "play" | "results" (BowlingRules.PHASES).
	phase: string,
	-- In play: "aim" waiting for this player's roll, "rolling" a ball is being animated.
	turn: string,
	-- Bumped by every phase change and roll, so a stale delayed step does nothing.
	token: number,
	lastRollAt: number,
	-- The picked dumbbell (1..BowlingRules.BALL_CHOICES); run state only, not saved.
	choice: number,
	-- os.clock() from which the START pad works (BowlingRules.REARM after landing in the lobby).
	armAt: number,
	-- The open turn: when its "ready" went out (os.clock) and its number in the run.
	readyAt: number,
	readySeq: number,
	-- While a ball settles: os.clock() from which "BowlingSkip" is taken.
	skipFrom: number,
	-- Balls bowled this run, and the server's AFK balls in this game.
	balls: number,
	autoBalls: number,
}

-- World y of a part's top face, whatever way the part is turned (an upright cylinder's Size.Y
-- is its diameter, not its height).
local function partTop(part: BasePart): number
	local cf, s = part.CFrame, part.Size
	return cf.Position.Y + (math.abs(cf.XVector.Y) * s.X + math.abs(cf.YVector.Y) * s.Y + math.abs(cf.ZVector.Y) * s.Z) / 2
end

function Bowling.create(GameModes: any, context: { [string]: any }): any
	local built = context.world and context.world.bowling
	local Tycoon = context.Tycoon
	local def: any = { id = ID }
	local runs: { [Player]: Run } = {}
	local lastPos: { [Player]: Vector3 } = {}
	local seeds = Random.new()

	local function record(session: any): { best: number, clears: number, lastRewardAt: number }
		return session.profile.modes[ID]
	end

	-- The most stars any counted game reached (the dumbbell unlocks).
	local function starsEver(rec: any): number
		return BowlingRules.starsEver(rec.best, rec.topStars)
	end

	-- A saved extra field (os.time stamps, shares) that may be missing or broken: 0 then.
	local function stamp(value: any): number
		return if type(value) == "number" and value == value and value >= 0 and value < math.huge then value else 0
	end

	-- Tells every other client which move this bowler's avatar makes (FLEX_ATTR); nil clears.
	local cueCount = 0
	local function cue(player: Player, move: string?)
		local character = player.Character
		if not character then
			return
		end
		if move then
			local run = runs[player]
			local ball = if run then run.choice else 1
			if character:GetAttribute(BALL_ATTR) ~= ball then
				character:SetAttribute(BALL_ATTR, ball)
			end
			cueCount += 1
			character:SetAttribute(FLEX_ATTR, move .. "#" .. cueCount)
		elseif character:GetAttribute(FLEX_ATTR) ~= nil or character:GetAttribute(BALL_ATTR) ~= nil then
			character:SetAttribute(FLEX_ATTR, nil)
			character:SetAttribute(BALL_ATTR, nil)
		end
	end

	-- When the next repeat share is due (os.time); 0 when it already is.
	local function repeatEnds(rec: any): number
		local last = rec.lastRepeatAt
		if BowlingRules.repeatDue(os.time(), last) then
			return 0
		end
		return last + BowlingRules.REPEAT_GAP
	end

	-- Where a game is played: the foul line (the arena's spawn if the lane has none).
	local function toPlay(player: Player)
		local at = built.rollStart or built.spawn
		GameModes.teleport(player, at.Position, at.LookVector)
	end

	-- The lobby spawn (the arena's spawn until the lobby is built).
	local function toLobby(player: Player)
		local at = built.lobbySpawn or built.spawn
		GameModes.teleport(player, at.Position, at.LookVector)
	end

	-- Feet on a pad part (its top face, within `radius` across).
	local function feetOn(pad: BasePart?, radius: number?, pos: Vector3, feetY: number): boolean
		if not pad or type(radius) ~= "number" then
			return false
		end
		local c = pad.Position
		return BowlingRules.onPad(pos.X - c.X, feetY - partTop(pad), pos.Z - c.Z, radius)
	end

	-- What the client needs to draw the lane, the pins and the dumbbell (lane space).
	local function laneInfo(): { [string]: any }
		local lane = BowlingRules.LANE
		local foul = (built.rollStart or built.spawn).Position
		local pins = {}
		for i, spot in BowlingRules.PIN_SPOTS do
			pins[i] = { x = spot.x, d = spot.d }
		end
		return {
			lane = {
				x = if built.lane then built.lane.Position.X else foul.X,
				z = foul.Z - 3,
				top = built.top,
				width = lane.width,
				length = lane.length,
				gutter = lane.gutter,
			},
			pins = pins,
			ball = { radius = BowlingRules.BALL.radius, halfLength = BowlingRules.BALL.halfLength },
			pin = { radius = BowlingRules.PIN.radius, height = BowlingRules.PIN.height },
			aimSpread = BowlingRules.AIM_SPREAD,
			pocket = BowlingRules.POCKET,
			power = { sweetLo = BowlingRules.POWER.sweetLo, sweetHi = BowlingRules.POWER.sweetHi },
			windup = BowlingRules.WINDUP,
		}
	end

	local function cardOf(run: Run): ({ BowlingRules.CardFrame }, number)
		return BowlingRules.card(run.game.frames)
	end

	-- The open turn's "ready" payload (also the snapshot's `ready`).
	local function readyInfo(run: Run): { [string]: any }
		local game = run.game
		local card, total = cardOf(run)
		local rack = true
		for _, up in game.standing do
			rack = rack and up
		end
		return {
			frame = game.frame,
			shot = #game.frames[game.frame] + 1,
			ball = run.choice,
			standing = table.clone(game.standing),
			card = card,
			total = total,
			rack = rack,
			seq = run.readySeq,
		}
	end

	-- Defined below (the AFK timer bowls through it).
	local bowl: (player: Player, run: Run, aim: number, power: number, auto: boolean) -> ()

	-- The player's turn: the next ball of the current frame. `again` re-sends the open turn
	-- (a refused roll) without restarting its clocks.
	local function sendReady(player: Player, run: Run, again: boolean?)
		run.turn = "aim"
		if not again then
			run.readyAt = os.clock()
			run.readySeq += 1
			cue(player, "stance")
			-- AFK: a turn left too long bowls a weak centre ball for the player.
			local seq = run.readySeq
			task.delay(BowlingRules.AFK_SECONDS, function()
				if runs[player] == run and run.phase == "play" and run.turn == "aim" and run.readySeq == seq then
					bowl(player, run, BowlingRules.AFK_AIM, BowlingRules.AFK_POWER, true)
				end
			end)
		end
		GameModes.notify(player, "ready", ID, readyInfo(run))
		if not again then
			-- The snapshot's turn too (a HUD that lost the event shows its controls from it).
			GameModes.refresh(player)
		end
	end

	-- Back in the lobby (entry, the results card's LOBBY, or its auto-return).
	local function enterLobby(player: Player, run: Run, teleport: boolean)
		run.phase = "lobby"
		run.turn = "none"
		run.token += 1
		cue(player, nil)
		run.armAt = os.clock() + BowlingRules.REARM
		if teleport then
			toLobby(player)
		end
	end

	local function lobbyInfo(session: any, run: Run): { [string]: any }
		local rec = record(session)
		return {
			best = rec.best,
			clears = rec.clears,
			rewardPreview = def.rewardPreview(session.player),
			choice = run.choice,
			starsEver = starsEver(rec),
		}
	end

	-- Results card up: back to the lobby after RESULTS_SECONDS unless the player moved on.
	local function returnLater(player: Player, run: Run)
		local mine = run.token
		task.delay(BowlingRules.RESULTS_SECONDS, function()
			if runs[player] ~= run or run.token ~= mine or run.phase ~= "results" then
				return
			end
			local session = GameModes.session(player)
			if not session then
				return
			end
			enterLobby(player, run, true)
			GameModes.notify(player, "lobby", ID, lobbyInfo(session, run))
			GameModes.refresh(player)
		end)
	end

	-- The last ball is down: best, clears and the pay on a pass; then the results card.
	local function finish(player: Player, run: Run)
		run.phase = "results"
		run.turn = "none"
		run.token += 1
		-- Other players' view lets the bowler go a beat later, like this client's (Fx.Bowling).
		local mine = run.token
		task.delay(0.5, function()
			if runs[player] == run and run.token == mine then
				cue(player, nil)
			end
		end)
		local session = GameModes.session(player)
		if not session then
			return
		end
		local rec = record(session)
		local score = BowlingRules.score(run.game.frames)
		returnLater(player, run)
		-- An auto-bowled game (AFK balls) counts for nothing: no best, clears, stars or pay.
		if BowlingRules.autoGame(run.autoBalls) then
			GameModes.notify(player, "lose", ID, {
				score = score,
				target = BowlingRules.PASS_SCORE,
				best = rec.best,
				newBest = false,
				lobbyIn = BowlingRules.RESULTS_SECONDS,
				stars = 0,
				starsEver = starsEver(rec),
				unlocked = {},
				auto = true,
			})
			GameModes.refresh(player)
			return
		end
		local stars = BowlingRules.stars(score)
		-- The dumbbells this game's stars unlock (the record keeps the most stars ever).
		local before = starsEver(rec)
		local newBest = score > rec.best
		if newBest then
			rec.best = score
		end
		local unlocked = {}
		if stars > before then
			for choice, need in BowlingRules.BALL_STARS do
				if need > before and need <= stars then
					table.insert(unlocked, choice)
				end
			end
		end
		local stamps = rec :: any
		if stars > stamp(stamps.topStars) then
			stamps.topStars = stars
		end
		if not BowlingRules.passed(score) then
			Tycoon.markDirty(session)
			GameModes.notify(player, "lose", ID, {
				score = score,
				target = BowlingRules.PASS_SCORE,
				best = rec.best,
				newBest = newBest,
				lobbyIn = BowlingRules.RESULTS_SECONDS,
				stars = stars,
				starsEver = starsEver(rec),
				unlocked = unlocked,
			})
			GameModes.refresh(player)
			return
		end
		local first = rec.clears == 0
		local reward = GameModes.modeReward(session, ID, first)
		-- Inside the cooldown a pass still pays the smaller "run again" share, but only once
		-- per BowlingRules.REPEAT_GAP (stamped on the save, so a rejoin doesn't reset it).
		local pay = "full"
		local now = os.time()
		if not reward.full then
			if BowlingRules.repeatDue(now, stamps.lastRepeatAt) then
				reward.cash = reward.repeatCash
				pay = "repeat"
				stamps.lastRepeatAt = now
			else
				reward.cash = 0
				pay = "none"
			end
		end
		rec.clears += 1
		local paid = GameModes.payReward(player, ID, reward)
		-- The stars' bonus (BowlingRules "STARS"): repeat shares, capped per REPEAT_GAP
		-- window by this game's stars; never a full pay, so the pack's cooldown is untouched.
		local bonus = 0
		local wanted = BowlingRules.starShare(stars)
		if wanted > 0 then
			local share, windowAt, used = BowlingRules.bonusTake(stamp(stamps.bonusAt), stamp(stamps.bonusUsed), now, wanted, stars)
			stamps.bonusAt, stamps.bonusUsed = windowAt, used
			local priced = GameModes.modeReward(session, ID, false)
			local cash = BowlingRules.bonusCash(priced.repeatCash, share)
			if cash > 0 then
				local extra = GameModes.payReward(
					player,
					ID,
					{ cash = cash, full = false, packCash = priced.packCash, repeatCash = priced.repeatCash }
				)
				bonus = extra.cash
			end
			Tycoon.markDirty(session)
		end
		GameModes.notify(player, "win", ID, {
			score = score,
			target = BowlingRules.PASS_SCORE,
			best = rec.best,
			newBest = newBest,
			first = first,
			cash = paid.cash,
			full = paid.full,
			pay = pay,
			packCash = paid.packCash,
			repeatCash = paid.repeatCash,
			cooldownEnds = rec.lastRewardAt + Economy.MODE_REWARD_COOLDOWN,
			repeatEnds = repeatEnds(rec),
			lobbyIn = BowlingRules.RESULTS_SECONDS,
			stars = stars,
			bonus = bonus,
			starsEver = starsEver(rec),
			unlocked = unlocked,
		})
		GameModes.refresh(player)
	end

	-- "BowlingBegin" (or the START pad): a fresh game at the foul line after the countdown.
	local function begin(player: Player, run: Run)
		if not BowlingRules.canBegin(run.phase) then
			return
		end
		run.phase = "countdown"
		run.turn = "none"
		run.game = BowlingRules.newGame()
		run.token += 1
		run.startedAt = os.clock()
		run.readySeq = 0
		run.autoBalls = 0
		local mine = run.token
		toPlay(player)
		cue(player, "stance")
		GameModes.notify(player, "countdown", ID, { seconds = BowlingRules.COUNTDOWN })
		GameModes.refresh(player)
		task.delay(BowlingRules.COUNTDOWN, function()
			if runs[player] ~= run or run.token ~= mine then
				return
			end
			run.phase = "play"
			-- The first ball can go straight away.
			run.lastRollAt = 0
			sendReady(player, run)
		end)
	end

	function def.running(player: Player): boolean
		return runs[player] ~= nil
	end

	function def.start(player: Player, teleport: boolean, _options: { [string]: any }?): boolean
		local session = GameModes.session(player)
		if not session or not built then
			return false
		end
		-- "ModeStart" again mid-run starts over in the lobby but keeps the picked dumbbell.
		local old = runs[player]
		if old then
			old.token += 1
		end
		local keep = if old and BowlingRules.ballUnlocked(old.choice, starsEver(record(session))) then old.choice else 1
		local run: Run = {
			startedAt = os.clock(),
			game = BowlingRules.newGame(),
			phase = "lobby",
			turn = "none",
			token = 0,
			lastRollAt = 0,
			choice = keep,
			armAt = 0,
			readyAt = 0,
			readySeq = 0,
			skipFrom = math.huge,
			balls = 0,
			autoBalls = 0,
		}
		runs[player] = run
		enterLobby(player, run, teleport)
		local payload = laneInfo()
		for key, value in lobbyInfo(session, run) do
			payload[key] = value
		end
		payload.phase = run.phase
		payload.target = BowlingRules.PASS_SCORE
		payload.maxScore = BowlingRules.MAX_SCORE
		payload.frames = BowlingRules.FRAMES
		payload.balls = BowlingRules.BALL_CHOICES
		payload.countdown = BowlingRules.COUNTDOWN
		payload.resultsSeconds = BowlingRules.RESULTS_SECONDS
		payload.tiers = table.clone(BowlingRules.STAR_TIERS)
		payload.ballStars = table.clone(BowlingRules.BALL_STARS)
		GameModes.notify(player, "start", ID, payload)
		GameModes.refresh(player)
		return true
	end

	function def.stop(player: Player, reason: string)
		local run = runs[player]
		if not run then
			return
		end
		run.token += 1
		runs[player] = nil
		cue(player, nil)
		if reason ~= "leave" then
			GameModes.notify(player, "stop", ID, { reason = reason })
			GameModes.refresh(player)
		end
	end

	function def.tick(player: Player, root: BasePart, _now: number)
		local pos = root.Position
		local prev = lastPos[player]
		lastPos[player] = pos
		local feetY = pos.Y - FEET_BELOW_ROOT
		local run = runs[player]
		if not run then
			if prev and feetY < Course.PLAZA.top + 8 and Course.crossedGate(def.slot, prev.X, prev.Z, pos.X, pos.Z) then
				GameModes.start(player, ID, true)
			end
			return
		end
		if not built then
			return
		end
		if BowlingRules.canExit(run.phase) and feetOn(built.exit, built.exitRadius, pos, feetY) then
			def.stop(player, "quit")
			GameModes.toGates(player)
			return
		end
		if feetY < built.top - BowlingRules.FALL_BELOW then
			if BowlingRules.fallTo(run.phase) == "lobby" then
				toLobby(player)
			else
				toPlay(player)
			end
			return
		end
		local onStart = feetOn(built.startPad, built.startRadius, pos, feetY)
		if BowlingRules.padStarts(run.phase, onStart, os.clock(), run.armAt) then
			begin(player, run)
		end
	end

	function def.rewardPreview(player: Player): { [string]: any }
		local session = GameModes.session(player)
		if not session then
			return { cash = 0, full = false, packCash = 0, repeatCash = 0 }
		end
		local rec = record(session)
		local r = GameModes.modeReward(session, ID, rec.clears == 0)
		-- The repeat share reads 0 until its gap is over.
		local repeatCash = if repeatEnds(rec) == 0 then r.repeatCash else 0
		return { cash = r.cash, full = r.full, packCash = r.packCash, repeatCash = repeatCash }
	end

	function def.snapshot(player: Player): { [string]: any }
		local session = GameModes.session(player)
		if not session then
			return { running = false }
		end
		local rec = record(session)
		local run = runs[player]
		return {
			running = run ~= nil,
			phase = if run then run.phase else nil,
			turn = if run then run.turn else nil,
			ready = if run and run.phase == "play" and run.turn == "aim" then readyInfo(run) else nil,
			choice = if run then run.choice else nil,
			best = rec.best,
			clears = rec.clears,
			cooldownEnds = rec.lastRewardAt + Economy.MODE_REWARD_COOLDOWN,
			rewardPreview = def.rewardPreview(player),
			repeatEnds = repeatEnds(rec),
			target = BowlingRules.PASS_SCORE,
			tiers = table.clone(BowlingRules.STAR_TIERS),
			starsEver = starsEver(rec),
		}
	end

	-- After a ball: the next turn, or the results once the game is over.
	local function afterBall(player: Player, run: Run)
		run.skipFrom = math.huge
		if run.game.over then
			finish(player, run)
		else
			sendReady(player, run)
		end
	end

	-- One ball at (aim, power), already checked and clamped: played in pure code, sent to the
	-- client to animate, then the next turn once it has settled.
	bowl = function(player: Player, run: Run, aim: number, power: number, auto: boolean)
		local clock = os.clock()
		run.lastRollAt = clock
		run.balls += 1
		if auto then
			run.autoBalls += 1
		end
		local ballNo = run.balls
		local game = run.game
		local frame = game.frame
		local shot = #game.frames[frame] + 1
		local result = BowlingRules.roll(game.standing, aim, power, seeds:NextInteger(1, 2147483646))
		local fallen = {}
		for _, fall in result.falls do
			table.insert(fallen, fall.pin)
		end
		local mark, reset = BowlingRules.applyRoll(game, fallen)
		local card, total = cardOf(run)
		local wait = BowlingRules.WINDUP + result.duration + BowlingRules.settle(mark) + (if reset and not game.over then RESET else 0)
		local react = BowlingRules.reactAt(result, mark)
		-- No skip after the last ball: it would cut the final reaction (the results follow).
		local skipAt: number? = if game.over then nil else BowlingRules.skipAt(result, mark)
		run.turn = "rolling"
		run.skipFrom = if skipAt then clock + skipAt else math.huge
		run.token += 1
		local mine = run.token
		GameModes.notify(player, "roll", ID, {
			aim = result.aim,
			power = result.power,
			zone = BowlingRules.powerZone(result.power),
			hook = result.hook,
			windup = BowlingRules.WINDUP,
			path = result.path,
			falls = result.falls,
			knocked = result.knocked,
			gutter = result.gutter,
			mark = mark,
			reset = reset,
			frame = frame,
			shot = shot,
			ball = run.choice,
			card = card,
			total = total,
			over = game.over,
			wait = wait,
			react = react,
			skipAt = skipAt,
			auto = auto,
			autoGame = BowlingRules.autoGame(run.autoBalls),
		})
		-- Other players' view: the run-up now, the reaction once the pins have settled.
		cue(player, "bowl")
		local reaction = if mark == "strike"
			then "strike"
			elseif mark == "spare" then "spare"
			elseif result.knocked <= 0 then "miss"
			else "point"
		-- Keyed to the ball, not the token: a skip (which only opens after the reaction has
		-- started) never cancels it.
		task.delay(BowlingRules.WINDUP + react, function()
			if runs[player] == run and run.balls == ballNo and run.phase ~= "lobby" then
				cue(player, reaction)
			end
		end)
		task.delay(wait, function()
			if runs[player] ~= run or run.token ~= mine then
				return
			end
			afterBall(player, run)
		end)
	end

	-- One ball: only in play, on the player's turn, READY_GAP after its "ready", at most
	-- every MIN_ROLL_GAP; aim and power must be numbers (then clamped).
	Tycoon.addAction("BowlingRoll", function(session: any, data: { [string]: any })
		local player = session.player
		local run = runs[player]
		local clock = os.clock()
		if not run or not BowlingRules.canRoll(run.phase) then
			return
		end
		local aim, power = BowlingRules.rollInput(data.aim, data.power)
		if
			run.turn ~= "aim"
			or clock - run.lastRollAt < MIN_ROLL_GAP
			or BowlingRules.tooEarly(clock, run.readyAt)
			or aim == nil
			or power == nil
		then
			-- A refused roll on the player's turn: say "ready" again so the HUD shows its
			-- aim controls instead of waiting for a "roll" that never comes. (Mid-ball the
			-- delayed "ready" is on its way.)
			if run.turn == "aim" then
				sendReady(player, run, true)
			end
			return
		end
		bowl(player, run, aim :: number, power :: number, false)
	end)

	-- A tap during the reaction: once the ball's pins are down, the next turn now.
	Tycoon.addAction("BowlingSkip", function(session: any, _data: { [string]: any })
		local player = session.player
		local run = runs[player]
		if
			not run
			or run.phase ~= "play"
			or run.turn ~= "rolling"
			or run.game.over
			or not BowlingRules.canSkip(os.clock(), run.skipFrom)
		then
			return
		end
		run.token += 1
		afterBall(player, run)
	end)

	-- A new game: from the lobby (the HUD's PLAY) or the results card (PLAY AGAIN).
	local function onBegin(session: any, _data: { [string]: any })
		local run = runs[session.player]
		if run then
			begin(session.player, run)
		end
	end
	Tycoon.addAction("BowlingBegin", onBegin)
	-- The old results card's "again" button.
	Tycoon.addAction("BowlingAgain", onBegin)

	-- The ball rack: pick a dumbbell colour (lobby or results only).
	Tycoon.addAction("BowlingBall", function(session: any, data: { [string]: any })
		local player = session.player
		local run = runs[player]
		local choice = BowlingRules.ballChoice(data.choice)
		if not run or not choice or not BowlingRules.canPickBall(run.phase) then
			return
		end
		if not BowlingRules.ballUnlocked(choice, starsEver(record(session))) then
			-- Locked: say the current pick again so the HUD snaps back to it.
			GameModes.notify(player, "ball", ID, { choice = run.choice, locked = choice })
			return
		end
		run.choice = choice
		GameModes.notify(player, "ball", ID, { choice = choice })
		GameModes.refresh(player)
	end)

	-- The results card's LOBBY button.
	Tycoon.addAction("BowlingLobby", function(session: any, _data: { [string]: any })
		local player = session.player
		local run = runs[player]
		if not run or run.phase ~= "results" then
			return
		end
		enterLobby(player, run, true)
		GameModes.notify(player, "lobby", ID, lobbyInfo(session, run))
		-- The snapshot's phase too, so every client view drops the results card now.
		GameModes.refresh(player)
	end)

	Players.PlayerRemoving:Connect(function(player)
		lastPos[player] = nil
	end)

	return def
end

return Bowling
