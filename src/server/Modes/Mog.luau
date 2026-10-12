--[[
	Mog: the MOG TEST game mode, a skill-check duel on the MOG STAGE out at sea
	(World.MogStage, numbers in Modes.MogLayout, rules in Modes.MogRules).

	- The "ModeStart" action { mode = "mog", vs = "rivals" | "pvp" } starts a run. Without a
	  valid `vs` (walking west through gate 2, old clients) nothing starts: the client gets
	  { event = "choose" } and shows a picker that fires ModeStart again with `vs`.
	- vs = "rivals" (PvE): the player is teleported to a free duel spot (MogLayout.SPOTS;
	  refused when all are taken), facing a rival chad, and held still (HumanoidRootPart
	  anchored, no jumping) until the run ends.
	- Skill checks come one after another (MogRules.check); the client answers with the
	  "MogPress" action { id, at } (at = its workspace:GetServerTimeNow() at the press). The
	  server judges the press from `at`; a check nobody answers is a "timeout" miss.
	- Hits wear the rival down; a mogged rival makes way for a tougher one. Mogging
	  MogRules.PASS_RIVALS rivals passes the test and pays Economy.modeReward (same rules as
	  Parkour: first pass ever, then once per Economy.MODE_REWARD_COOLDOWN). The run then goes
	  on for a high score until the lives run out; afterwards the player is sent back to the
	  gates (GameModes.returnLater).
	- vs = "pvp": 1v1 against a real player. A player waiting in the queue is matched at once;
	  otherwise the player waits (not teleported, def.running is true) for QUEUE_TIMEOUT
	  seconds, then gets stop "noOpponent". The "MogCancel" action leaves the queue. A match
	  needs a whole free spot: the earlier-queued player (side A) stands on spot.player facing
	  inward, the other (side B) on spot.rival facing A; both are held still. Both get the same
	  check at the same time (the first PVP_FIRST_LEAD later), press once each (judged like
	  PvE), and the round ends when both answered or the needle lap timed out (MogRules
	  duelPress / duelRound: hit 1 damage to the opponent, perfect 2, miss 1 to yourself, all
	  at once; KO tie = sudden death at 1 HP). The winner is paid on the same cooldown as a PvE
	  pass, but never as a first clear: that one belongs to the first PvE pass
	  (MogRules.firstPass / countClear). Leaving, respawning, quitting or switching mode
	  mid-duel forfeits: the other side wins at once. So does letting
	  MogRules.PVP_IDLE_FORFEIT checks in a row time out (both sides idle: a draw, nobody
	  wins), and a duel still open after PVP_MAX_ROUNDS rounds goes to the higher HP, then the
	  higher score. PvP never goes on the TOP MOGGERS board.
	- A duel's checks are hidden: "check" carries no zone, and the zone follows in "zone" when
	  the needle starts (a client cannot work out the press before it can see the zone). A
	  press stamped sooner than MogRules.MIN_REACTION after the zone was sent is ignored.

	Notify payloads (kind = "Mode", mode = "mog"):
	  { event = "choose" }                           no `vs` given: show the rivals / PvP picker
	  { event = "start", vs = "rivals", lives, maxLives, startedAt, best, spot, playerPos, rivalPos, rival,
	    passRivals, score = 0 }                      playerPos / rivalPos: feet (Vector3)
	  { event = "check", id, n, appearAt, speed, dir, zoneStart, zoneSize, perfectSize,
	    duration }                                   sent `lead` seconds before appearAt
	  { event = "result", id, result, reason?, travel?, score, combo, lives, rivalHp, rivalMax }
	  { event = "rival", mogged, rival, rivals, passed, cash?, full? }
	  { event = "finish", score, rivals, best, newBest, passed, cash, full,
	    cooldownEnds, rank? }
	  { event = "stop", reason }                     ended without a finish ("full" = no free spot,
	                                                 "noOpponent" = queue timed out, "cancel")
	PvP payloads (every one carries vs = "pvp"; hp values are after the round):
	  { event = "queue", vs, since, timeout }        waiting for an opponent (since: server time)
	  { event = "start", vs, startedAt, spot, playerPos, rivalPos, hp, maxHp,
	    opponent = { userId, name, hp, maxHp }, score = 0, wins }   rivalPos: the opponent's feet
	  { event = "check", vs, hidden = true, pressFrom, id, n, appearAt, speed, dir, duration }
	                                                 the same check for both sides, no zone yet;
	                                                 pressFrom: presses stamped earlier are ignored
	  { event = "zone", vs, id, zoneStart, zoneSize, perfectSize }   sent when the needle starts
	  { event = "result", vs, id, result, reason?, travel?, score, combo }   own press, no HP change
	  { event = "round", vs, id, you = { result, hp, maxHp, combo, score },
	    opp = { result, hp, maxHp }, suddenDeath? }
	  { event = "finish", vs, won, reason ("ko" | "forfeit"), opponent = { userId, name }, score,
	    wins, played, cash, full, cooldownEnds, afk?, rounds?, draw?, close? }
	                                                 afk = true: an idle forfeit (reason "forfeit");
	                                                 rounds = true: decided at the round cap (reason
	                                                 "ko"); draw = true: nobody won (won is false);
	                                                 close = true: a KO or round-cap result by a
	                                                 small HP margin or in sudden death
	                                                 (MogRules.duelClose)
	Rival info: { index, name, tier, hp, maxHp } (tier = Theme.Tiers index the client dresses).
	Effects: the usual "Cash" { amount, source = "Mode", padPos } when the pass pays cash.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Economy = require(ReplicatedStorage.Shared.Economy)
local Course = require(script.Parent.Course)
local MogLayout = require(script.Parent.MogLayout)
local MogRules = require(script.Parent.MogRules)

local ID = "mog"
local BEST_SIZE = 8
-- Seconds from the start to the first check being announced.
local FIRST_CHECK = 2.0
-- Press timing slack (seconds) around the needle's lap and around the server clock.
local LAP_SLACK = 0.05
local PRESS_PAST = 0.6
local PRESS_FUTURE = 0.25
-- An unanswered check becomes a miss this long after the needle's lap ends.
local TIMEOUT_SLACK = 0.35
-- Seconds after finishing before the player is brought back to the gates.
local RETURN_AFTER = 6
-- Seconds a PvP player waits in the queue before giving up.
local QUEUE_TIMEOUT = 45
-- Feet are this far below the HumanoidRootPart's centre on a default character.
local FEET_BELOW_ROOT = 3

type Saved = { root: BasePart, humanoid: Humanoid?, jumpHeight: number, jumpPower: number }

type State = {
	run: MogRules.Run,
	spot: number,
	rng: Random,
	check: MogRules.Check?,
	checkId: number,
	appearAt: number,
	pending: boolean,
	reward: Economy.ModeReward?,
	saved: Saved?,
}

-- A PvP duel shared by both players (players[1] = side A, players[2] = side B).
type Duel = {
	rules: MogRules.Duel,
	players: { Player },
	spot: number,
	rng: Random,
	check: MogRules.Check?,
	checkId: number,
	appearAt: number,
	-- The current check's needle start once its zone was sent (math.huge until then).
	revealAt: number,
	pending: boolean,
	saved: { [Player]: Saved? },
	over: boolean,
}

type QueueEntry = { player: Player, since: number }

local function escape(s: string): string
	return (string.gsub(s, "[&<>]", { ["&"] = "&amp;", ["<"] = "&lt;", [">"] = "&gt;" }))
end

local function vec(p: MogLayout.Point): Vector3
	return Vector3.new(p.x, p.y, p.z)
end

local function info(r: MogRules.Rival): { [string]: any }
	return { index = r.index, name = r.name, tier = r.tier, hp = r.hp, maxHp = r.maxHp }
end

local function create(GameModes: any, context: { built: any, theme: any, Tycoon: any, world: any })
	local theme = context.theme
	local Tycoon = context.Tycoon
	local runs: { [Player]: State } = {}
	local lastX: { [Player]: number } = {}
	local spotOwner: { [number]: Player } = {}
	-- Bumped every time a spot is handed out, so a stale freeLater never frees a reused spot.
	local spotGen: { [number]: number } = {}
	local duels: { [Player]: Duel } = {}
	local queue: { QueueEntry } = {}
	local serverBest: { MogRules.BestEntry } = {}
	local nextCheckId = 0

	local tierNames: { string } = {}
	for _, tier in theme.Tiers do
		table.insert(tierNames, tier.Name)
	end

	local function now(): number
		return workspace:GetServerTimeNow()
	end

	local function record(session: any): {
		best: number,
		rivals: number,
		clears: number,
		lastRewardAt: number,
		pvpWins: number,
		pvpPlayed: number,
	}
		return session.profile.modes.mog
	end

	-- What a PvE pass (vs = "rivals") or a PvP win ("pvp") pays right now. Only a pass can be
	-- the first clear; both share the cooldown.
	local function rewardFor(session: any, vs: string): Economy.ModeReward
		local p = session.profile
		local rec = record(session)
		local pack = theme.Modes.Reward
		local progression = Economy.progression(Economy.highestTier(p.discovered), p.processLevel)
		local first = vs == "rivals" and MogRules.firstPass(rec)
		return Economy.modeReward(Tycoon.income(session), progression, pack.Seconds, pack.Min, first, rec.lastRewardAt, os.time())
	end

	local function updateBoard()
		local label = context.world and context.world.mog and context.world.mog.bestList
		if not label then
			return
		end
		if #serverBest == 0 then
			label.Text = "Be the first to pass!"
			return
		end
		local lines = {}
		for i, entry in serverBest do
			table.insert(lines, string.format("%d. %s  <b>%d</b>", i, escape(entry.name), entry.score))
		end
		label.Text = table.concat(lines, "\n")
	end

	local function freeSpot(player: Player, other: Player?): number?
		-- A solo player who plays again within RETURN_AFTER still holds their spot: reuse it.
		-- A duel never does: the last opponent may still stand on that spot's other pad.
		if not other then
			for i = 1, #MogLayout.SPOTS do
				if spotOwner[i] == player then
					return i
				end
			end
		end
		for i = 1, #MogLayout.SPOTS do
			local owner = spotOwner[i]
			if not owner or owner.Parent == nil then
				return i
			end
		end
		return nil
	end

	-- Holds the character still on its pad: anchored root, no jumping. Returns what unhold needs.
	local function hold(player: Player): Saved?
		local root = GameModes.root(player)
		if not root then
			return nil
		end
		local humanoid = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
		local saved: Saved = {
			root = root,
			humanoid = humanoid,
			jumpHeight = if humanoid then humanoid.JumpHeight else 7.2,
			jumpPower = if humanoid then humanoid.JumpPower else 50,
		}
		root.AssemblyLinearVelocity = Vector3.zero
		root.Anchored = true
		if humanoid then
			humanoid.JumpHeight = 0
			humanoid.JumpPower = 0
		end
		return saved
	end

	local function unhold(saved: Saved?)
		if saved then
			saved.root.Anchored = false
			if saved.humanoid then
				saved.humanoid.JumpHeight = saved.jumpHeight
				saved.humanoid.JumpPower = saved.jumpPower
			end
		end
	end

	-- Frees `spot` once its players are gone: they stand on the pads a few more seconds after a
	-- finish (RETURN_AFTER), so nobody is teleported onto them meanwhile.
	local function freeLater(spot: number, owner: Player)
		if spotOwner[spot] == owner then
			local gen = spotGen[spot]
			task.delay(RETURN_AFTER + 1, function()
				if spotOwner[spot] == owner and spotGen[spot] == gen then
					spotOwner[spot] = nil
				end
			end)
		end
	end

	-- Undoes hold() and frees the spot. Must run before any teleport away from the stage.
	local function release(player: Player, state: State)
		unhold(state.saved)
		state.saved = nil
		freeLater(state.spot, player)
		runs[player] = nil
	end

	local issueCheck: (player: Player, state: State) -> ()

	-- Announces the next check after `delay` seconds, unless this run has ended by then.
	local function scheduleCheck(player: Player, state: State, delay: number)
		task.delay(delay, function()
			if runs[player] == state and not state.pending and not state.run.finished then
				issueCheck(player, state)
			end
		end)
	end

	issueCheck = function(player: Player, state: State)
		local run = state.run
		run.n += 1
		local check = MogRules.check(run.n, function()
			return state.rng:NextNumber()
		end)
		nextCheckId += 1
		state.check = check
		state.checkId = nextCheckId
		state.appearAt = now() + check.lead
		state.pending = true
		GameModes.notify(player, "check", ID, {
			id = state.checkId,
			n = check.n,
			appearAt = state.appearAt,
			speed = check.speed,
			dir = check.dir,
			zoneStart = check.zoneStart,
			zoneSize = check.zoneSize,
			perfectSize = check.perfectSize,
			duration = check.duration,
		})
	end

	-- Pays the mode reward for a PvE pass (vs = "rivals") or a PvP win ("pvp"): one cooldown
	-- for both, the first clear only for a pass. `padPos` places the "Cash" effect when the
	-- character is gone.
	local function payReward(player: Player, padPos: Vector3, vs: string): Economy.ModeReward?
		local session = GameModes.session(player)
		if not session then
			return nil
		end
		local rec = record(session)
		local reward = GameModes.hooks.reward(session, ID, rewardFor(session, vs))
		MogRules.countClear(rec, vs)
		if reward.full then
			rec.lastRewardAt = os.time()
		end
		local p = session.profile
		if reward.cash > 0 then
			p.money += reward.cash
			p.totalEarned += reward.cash
			local root = GameModes.root(player)
			GameModes.effect(player, "Cash", {
				amount = reward.cash,
				source = "Mode",
				padPos = if root then root.Position else padPos,
			})
		end
		GameModes.hooks.rewarded(session, ID, reward)
		Tycoon.markDirty(session)
		return reward
	end

	local function payPass(player: Player, state: State): Economy.ModeReward?
		local reward = payReward(player, vec(MogLayout.SPOTS[state.spot].player), "rivals")
		state.reward = reward
		return reward
	end

	local function finish(player: Player, state: State)
		release(player, state)
		local session = GameModes.session(player)
		if not session then
			return
		end
		local run = state.run
		local rec = record(session)
		local newBest = run.score > rec.best
		if newBest then
			rec.best = run.score
		end
		rec.rivals = math.max(rec.rivals, run.rivals)
		local rank = nil
		if run.score > 0 then
			rank = MogRules.recordBest(serverBest, player.UserId, player.DisplayName, run.score, run.rivals, BEST_SIZE)
			updateBoard()
		end
		local reward = state.reward
		GameModes.notify(player, "finish", ID, {
			score = run.score,
			rivals = run.rivals,
			best = rec.best,
			newBest = newBest,
			passed = run.passed,
			cash = if reward then reward.cash else 0,
			full = if reward then reward.full else false,
			cooldownEnds = rec.lastRewardAt + Economy.MODE_REWARD_COOLDOWN,
			rank = rank,
		})
		Tycoon.markDirty(session)
		GameModes.refresh(player)
		GameModes.returnLater(player, RETURN_AFTER, function(root: BasePart): boolean
			return MogLayout.onStage(root.Position.X, root.Position.Z)
		end)
	end

	-- Settles the current check with `result` and moves the run on.
	local function resolve(player: Player, state: State, result: string, reason: string?, travel: number?)
		local check = state.check :: MogRules.Check
		state.pending = false
		local hitRival = state.run.rival
		local outcome = MogRules.apply(state.run, result)
		local run = state.run
		GameModes.notify(player, "result", ID, {
			id = state.checkId,
			result = result,
			reason = reason,
			travel = travel,
			score = run.score,
			combo = run.combo,
			lives = run.lives,
			rivalHp = hitRival.hp,
			rivalMax = hitRival.maxHp,
		})
		if outcome.moggedRival then
			local payload: { [string]: any } = {
				mogged = info(outcome.moggedRival :: MogRules.Rival),
				rival = info(run.rival),
				rivals = run.rivals,
				passed = outcome.passed == true,
			}
			if outcome.passed then
				local reward = payPass(player, state)
				payload.cash = if reward then reward.cash else 0
				payload.full = if reward then reward.full else false
			end
			GameModes.notify(player, "rival", ID, payload)
			GameModes.refresh(player)
		end
		if outcome.finished then
			finish(player, state)
		else
			scheduleCheck(player, state, check.delay)
		end
	end

	-- Judges a "MogPress" { id, at } against a check announced for `appearAt` with id `checkId`.
	-- Returns nil for a stale, malformed or implausibly timed press; in a duel that includes
	-- one stamped before `from` (sooner after the zone was sent than anyone can react).
	local function judgePress(
		check: MogRules.Check,
		checkId: number,
		appearAt: number,
		data: { [string]: any },
		from: number?
	): (string?, string?, number?)
		local id, at = data.id, data.at
		if type(id) ~= "number" or type(at) ~= "number" or at ~= at or id ~= checkId then
			return nil
		end
		local t = now()
		if at < appearAt - LAP_SLACK or at > appearAt + check.duration + LAP_SLACK then
			return nil
		end
		if from and at < from then
			return nil
		end
		if at < t - PRESS_PAST or at > t + PRESS_FUTURE then
			return nil
		end
		local travel = check.speed * (at - appearAt)
		local result, reason = MogRules.judge(check, travel)
		return result, reason, travel
	end

	-- PvP --------------------------------------------------------------------------------------

	local function queued(player: Player): number?
		for i, entry in queue do
			if entry.player == player then
				return i
			end
		end
		return nil
	end

	local function dequeue(player: Player): boolean
		local i = queued(player)
		if i then
			table.remove(queue, i)
		end
		return i ~= nil
	end

	-- Can this queued player be put in a duel right now?
	local function ready(player: Player): boolean
		return player.Parent ~= nil
			and GameModes.session(player) ~= nil
			and GameModes.root(player) ~= nil
			and not runs[player]
			and not duels[player]
	end

	local function sideOf(duel: Duel, player: Player): number
		return if duel.players[1] == player then 1 else 2
	end

	-- Feet of side `side` on the duel's spot: A on the player pad, B on the rival pad.
	local function padOf(duel: Duel, side: number): Vector3
		local spot = MogLayout.SPOTS[duel.spot]
		return vec(if side == 1 then spot.player else spot.rival)
	end

	local function sendPvp(player: Player, event: string, data: { [string]: any })
		data.vs = "pvp"
		GameModes.notify(player, event, ID, data)
	end

	local issueDuelCheck: (duel: Duel) -> ()

	local function scheduleDuelCheck(duel: Duel, delay: number)
		task.delay(delay, function()
			if not duel.over and not duel.pending then
				issueDuelCheck(duel)
			end
		end)
	end

	-- Both sides get the same check with the same id and appearAt. It is hidden: the zone is
	-- sent only when the needle starts, to both at once.
	issueDuelCheck = function(duel: Duel)
		local rules = duel.rules
		rules.n += 1
		local check = MogRules.check(rules.n, function()
			return duel.rng:NextNumber()
		end, true)
		nextCheckId += 1
		local id = nextCheckId
		local lead = check.lead + (if rules.n == 1 then MogRules.PVP_FIRST_LEAD else 0)
		duel.check = check
		duel.checkId = id
		duel.appearAt = now() + lead
		duel.revealAt = math.huge
		duel.pending = true
		for _, player in duel.players do
			sendPvp(player, "check", {
				id = id,
				n = check.n,
				appearAt = duel.appearAt,
				speed = check.speed,
				dir = check.dir,
				duration = check.duration,
				hidden = true,
				pressFrom = duel.appearAt + MogRules.MIN_REACTION,
			})
		end
		task.delay(lead, function()
			if duel.over or not duel.pending or duel.checkId ~= id then
				return
			end
			-- task.delay never fires early; the stamp is the needle's start, which is also what
			-- the clients' `pressFrom` counts from.
			duel.revealAt = duel.appearAt
			for _, player in duel.players do
				sendPvp(player, "zone", {
					id = id,
					zoneStart = check.zoneStart,
					zoneSize = check.zoneSize,
					perfectSize = check.perfectSize,
				})
			end
		end)
	end

	-- Ends the duel: releases both players, frees the spot (after RETURN_AFTER), counts it on
	-- both records and pays `winner` (nil = a draw: nobody wins). `reason` is "ko", "forfeit"
	-- (left), "afk" (idle forfeit) or "rounds" (the round cap). Everyone but `quitter` (who
	-- gets a stop from def.stop) gets a finish and is sent back to the gates later.
	local function endDuel(duel: Duel, winner: Player?, reason: string, quitter: Player?)
		if duel.over then
			return
		end
		duel.over = true
		-- A forfeit before any round was played pays nothing (no win-trading by quitting).
		local pays = reason ~= "forfeit" or duel.rules.n >= 2
		-- Only a duel fought to the end can have been close (the loser's card says so).
		local close = (reason == "ko" or reason == "rounds") and MogRules.duelClose(duel.rules)
		duel.pending = false
		for _, player in duel.players do
			unhold(duel.saved[player])
			duels[player] = nil
		end
		duel.saved = {}
		freeLater(duel.spot, duel.players[1])
		for i, player in duel.players do
			local session = GameModes.session(player)
			if not session then
				continue
			end
			local won = winner ~= nil and player == winner
			local rec = record(session)
			rec.pvpPlayed += 1
			local reward = nil
			if won then
				rec.pvpWins += 1
				if pays then
					reward = payReward(player, padOf(duel, i), "pvp")
				end
			end
			Tycoon.markDirty(session)
			if player ~= quitter then
				local opponent = duel.players[3 - i]
				sendPvp(player, "finish", {
					won = won,
					-- The finish card knows "ko" and "forfeit"; the flags say which kind.
					reason = if reason == "afk" then "forfeit" elseif reason == "rounds" then "ko" else reason,
					afk = if reason == "afk" then true else nil,
					rounds = if reason == "rounds" then true else nil,
					draw = if winner == nil then true else nil,
					close = if close then true else nil,
					opponent = { userId = opponent.UserId, name = opponent.DisplayName },
					score = duel.rules.sides[i].score,
					wins = rec.pvpWins,
					played = rec.pvpPlayed,
					cash = if reward then reward.cash else 0,
					full = if reward then reward.full else false,
					cooldownEnds = rec.lastRewardAt + Economy.MODE_REWARD_COOLDOWN,
				})
				GameModes.refresh(player)
				GameModes.returnLater(player, RETURN_AFTER, function(root: BasePart): boolean
					return MogLayout.onStage(root.Position.X, root.Position.Z)
				end)
			end
		end
	end

	-- Records `player`'s answer to the current check and tells them (no HP change yet).
	local function answer(duel: Duel, player: Player, result: string, reason: string?, travel: number?)
		local side = sideOf(duel, player)
		if not MogRules.duelPress(duel.rules, side, result) then
			return
		end
		local d = duel.rules.sides[side]
		sendPvp(player, "result", {
			id = duel.checkId,
			result = result,
			reason = reason,
			travel = travel,
			score = d.score,
			combo = d.combo,
		})
	end

	-- Both answered (or timed out): the damage lands, then the duel ends or goes on.
	local function endRound(duel: Duel)
		local check = duel.check :: MogRules.Check
		duel.pending = false
		local round = MogRules.duelRound(duel.rules)
		for i, player in duel.players do
			local you, opp = duel.rules.sides[i], duel.rules.sides[3 - i]
			sendPvp(player, "round", {
				id = duel.checkId,
				you = { result = round.results[i], hp = you.hp, maxHp = you.maxHp, combo = you.combo, score = you.score },
				opp = { result = round.results[3 - i], hp = opp.hp, maxHp = opp.maxHp },
				suddenDeath = if round.suddenDeath then true else nil,
			})
		end
		if round.finished then
			local winner = if round.winner then duel.players[round.winner] else nil
			endDuel(duel, winner, round.reason or "ko", nil)
		else
			scheduleDuelCheck(duel, check.delay)
		end
	end

	local function startDuel(a: Player, b: Player, index: number)
		local t = now()
		local duel: Duel = {
			rules = MogRules.newDuel(),
			players = { a, b },
			spot = index,
			rng = Random.new(),
			check = nil,
			checkId = 0,
			appearAt = 0,
			revealAt = math.huge,
			pending = false,
			saved = {},
			over = false,
		}
		duels[a] = duel
		duels[b] = duel
		spotOwner[index] = a
		spotGen[index] = (spotGen[index] or 0) + 1
		local spot = MogLayout.SPOTS[index]
		local inward = Vector3.new(spot.faceX, 0, spot.faceZ)
		GameModes.teleport(a, padOf(duel, 1), inward)
		GameModes.teleport(b, padOf(duel, 2), -inward)
		lastX[a] = spot.player.x
		lastX[b] = spot.rival.x
		duel.saved[a] = hold(a)
		duel.saved[b] = hold(b)
		for i, player in duel.players do
			local opponent = duel.players[3 - i]
			local session = GameModes.session(player)
			sendPvp(player, "start", {
				startedAt = t,
				spot = index,
				playerPos = padOf(duel, i),
				rivalPos = padOf(duel, 3 - i),
				hp = MogRules.PVP_HP,
				maxHp = MogRules.PVP_HP,
				opponent = {
					userId = opponent.UserId,
					name = opponent.DisplayName,
					hp = MogRules.PVP_HP,
					maxHp = MogRules.PVP_HP,
				},
				score = 0,
				wins = if session then record(session).pvpWins else 0,
			})
			GameModes.refresh(player)
		end
		scheduleDuelCheck(duel, FIRST_CHECK)
	end

	-- Matches the two earliest ready players in the queue when a whole spot is free.
	local function tryMatch()
		local a: Player?, b: Player? = nil, nil
		for _, entry in queue do
			if ready(entry.player) then
				if not a then
					a = entry.player
				else
					b = entry.player
					break
				end
			end
		end
		if not a or not b then
			return
		end
		local index = freeSpot(a, b)
		if not index then
			return
		end
		dequeue(a)
		dequeue(b)
		startDuel(a, b, index)
	end

	-- Settles a duel's check once the needle's lap is over: missing answers are timeouts
	-- (MogRules.duelRound books them as misses and counts them toward the idle forfeit).
	local function duelTimeout(duel: Duel, t: number)
		local check = duel.check
		if not duel.pending or not check or t <= duel.appearAt + check.duration + TIMEOUT_SLACK then
			return
		end
		for i, player in duel.players do
			local d = duel.rules.sides[i]
			if d.result == nil then
				sendPvp(player, "result", {
					id = duel.checkId,
					result = "miss",
					reason = "timeout",
					score = d.score,
					combo = 0,
				})
			end
		end
		endRound(duel)
	end

	local def = {} :: any
	def.id = ID

	-- True during a PvE run, a duel, or while waiting in the PvP queue.
	function def.running(player: Player): boolean
		return runs[player] ~= nil or duels[player] ~= nil or queued(player) ~= nil
	end

	function def.start(player: Player, _teleport: boolean, options: { [string]: any }?): boolean
		local vs = options and options.vs
		if vs ~= "rivals" and vs ~= "pvp" then
			if def.running(player) then
				return true
			end
			GameModes.notify(player, "choose", ID)
			return false
		end
		if runs[player] or duels[player] then
			return true
		end
		if queued(player) then
			if vs == "pvp" then
				return true
			end
			dequeue(player)
		end
		local session = GameModes.session(player)
		if not session or not GameModes.root(player) then
			return false
		end
		if vs == "pvp" then
			local since = now()
			table.insert(queue, { player = player, since = since })
			tryMatch()
			if queued(player) then
				sendPvp(player, "queue", { since = since, timeout = QUEUE_TIMEOUT })
				GameModes.refresh(player)
			end
			return true
		end
		local index = freeSpot(player)
		if not index then
			GameModes.notify(player, "stop", ID, { reason = "full" })
			return false
		end
		local t = now()
		local state: State = {
			run = MogRules.newRun(t, tierNames),
			spot = index,
			rng = Random.new(),
			check = nil,
			checkId = 0,
			appearAt = 0,
			pending = false,
			reward = nil,
			saved = nil,
		}
		runs[player] = state
		spotOwner[index] = player
		spotGen[index] = (spotGen[index] or 0) + 1
		-- The stage is teleport-only, so every start teleports.
		local spot = MogLayout.SPOTS[index]
		GameModes.teleport(player, vec(spot.player), Vector3.new(spot.faceX, 0, spot.faceZ))
		lastX[player] = spot.player.x
		state.saved = hold(player)
		local best = record(session).best
		GameModes.notify(player, "start", ID, {
			vs = "rivals",
			lives = state.run.lives,
			maxLives = MogRules.LIVES,
			startedAt = t,
			best = best,
			spot = index,
			playerPos = vec(spot.player),
			rivalPos = vec(spot.rival),
			rival = info(state.run.rival),
			passRivals = MogRules.PASS_RIVALS,
			score = 0,
		})
		GameModes.refresh(player)
		scheduleCheck(player, state, FIRST_CHECK)
		return true
	end

	-- Leaving the queue just dequeues; leaving a duel forfeits it to the opponent.
	function def.stop(player: Player, reason: string)
		local wasQueued = dequeue(player)
		local duel = duels[player]
		if wasQueued or duel then
			if duel then
				endDuel(duel, duel.players[3 - sideOf(duel, player)], "forfeit", player)
			end
			if reason ~= "leave" then
				sendPvp(player, "stop", { reason = reason })
				GameModes.refresh(player)
			end
			return
		end
		local state = runs[player]
		if not state then
			return
		end
		release(player, state)
		if reason ~= "leave" then
			GameModes.notify(player, "stop", ID, { reason = reason })
			GameModes.refresh(player)
		end
	end

	function def.tick(player: Player, root: BasePart, t: number)
		local pos = root.Position
		local x, z = pos.X, pos.Z
		local prevX = lastX[player]
		lastX[player] = x
		local duel = duels[player]
		if duel then
			duelTimeout(duel, t)
			return
		end
		local waiting = queued(player)
		if waiting then
			if t - queue[waiting].since > QUEUE_TIMEOUT then
				table.remove(queue, waiting)
				sendPvp(player, "stop", { reason = "noOpponent" })
				GameModes.refresh(player)
			else
				tryMatch()
			end
			return
		end
		local state = runs[player]
		if not state then
			if
				prevX
				and prevX > Course.GATE_X
				and x <= Course.GATE_X
				and math.abs(z - Course.GATES[2].z) <= Course.GATE_HALF + 1
				and pos.Y - FEET_BELOW_ROOT < Course.PLAZA.top + 8
			then
				-- No `vs`: the client is asked to choose (rivals or PvP).
				GameModes.start(player, ID, true)
			end
			return
		end
		local check = state.check
		if state.pending and check and t > state.appearAt + check.duration + TIMEOUT_SLACK then
			resolve(player, state, "miss", "timeout", nil)
		end
	end

	Tycoon.addAction("MogPress", function(session: any, data: { [string]: any })
		local player = session.player
		local duel = duels[player]
		if duel then
			local check = duel.check
			if not check or not duel.pending then
				return
			end
			-- No press counts before the zone was sent, nor sooner after it than a reaction takes.
			local from = duel.revealAt + MogRules.MIN_REACTION
			local result, reason, travel = judgePress(check, duel.checkId, duel.appearAt, data, from)
			if result then
				answer(duel, player, result, reason, travel)
				if duel.pending and MogRules.duelAnswered(duel.rules) then
					endRound(duel)
				end
			end
			return
		end
		local state = runs[player]
		local check = state and state.check
		if not state or not check or not state.pending then
			return
		end
		local result, reason, travel = judgePress(check, state.checkId, state.appearAt, data)
		if result then
			resolve(player, state, result, reason, travel)
		end
	end)

	-- Leaves the PvP queue (no teleport: a queued player never left the plaza).
	Tycoon.addAction("MogCancel", function(session: any, _data: { [string]: any })
		local player = session.player
		if dequeue(player) then
			sendPvp(player, "stop", { reason = "cancel" })
			GameModes.refresh(player)
		end
	end)

	function def.rewardPreview(player: Player): { [string]: any }
		local session = GameModes.session(player)
		if not session then
			return { cash = 0, full = false, packCash = 0 }
		end
		local r = rewardFor(session, "rivals")
		return { cash = r.cash, full = r.full, packCash = r.packCash }
	end

	function def.snapshot(player: Player): { [string]: any }
		local session = GameModes.session(player)
		local state = runs[player]
		local duel = duels[player]
		local rec = session and record(session)
		return {
			best = if rec then rec.best else 0,
			rivals = if rec then rec.rivals else 0,
			clears = if rec then rec.clears else 0,
			pvpWins = if rec then rec.pvpWins else 0,
			pvpPlayed = if rec then rec.pvpPlayed else 0,
			running = state ~= nil or duel ~= nil,
			queued = queued(player) ~= nil,
			score = if state then state.run.score elseif duel then duel.rules.sides[sideOf(duel, player)].score else 0,
			lives = if state then state.run.lives else MogRules.LIVES,
			cooldownEnds = if rec and rec.lastRewardAt > 0 then rec.lastRewardAt + Economy.MODE_REWARD_COOLDOWN else 0,
			rewardPreview = def.rewardPreview(player),
			passRivals = MogRules.PASS_RIVALS,
		}
	end

	Players.PlayerRemoving:Connect(function(player)
		-- Releases a PvE run, leaves the queue or forfeits a duel (GameModes also stops it).
		def.stop(player, "leave")
		lastX[player] = nil
	end)
	updateBoard()
	return def
end

return { create = create }
