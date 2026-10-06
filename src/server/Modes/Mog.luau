--[[
	Mog: the MOG TEST game mode, a skill-check duel on the MOG STAGE out at sea
	(World.MogStage, numbers in Modes.MogLayout, rules in Modes.MogRules).

	- Walking west through gate 2 or the "ModeStart" action starts a run: the player is
	  teleported to a free duel spot (MogLayout.SPOTS; refused when all are taken), facing a
	  rival chad, and held still (HumanoidRootPart anchored, no jumping) until the run ends.
	- Skill checks come one after another (MogRules.check); the client answers with the
	  "MogPress" action { id, at } (at = its workspace:GetServerTimeNow() at the press). The
	  server judges the press from `at`; a check nobody answers is a "timeout" miss.
	- Hits wear the rival down; a mogged rival makes way for a tougher one. Mogging
	  MogRules.PASS_RIVALS rivals passes the test and pays Economy.modeReward (same rules as
	  Parkour: first pass ever, then once per Economy.MODE_REWARD_COOLDOWN). The run then goes
	  on for a high score until the lives run out; afterwards the player is sent back to the
	  gates (GameModes.returnLater).

	Notify payloads (kind = "Mode", mode = "mog"):
	  { event = "start", lives, maxLives, startedAt, best, spot, playerPos, rivalPos, rival,
	    passRivals, score = 0 }                      playerPos / rivalPos: feet (Vector3)
	  { event = "check", id, n, appearAt, speed, dir, zoneStart, zoneSize, perfectSize,
	    duration }                                   sent `lead` seconds before appearAt
	  { event = "result", id, result, reason?, travel?, score, combo, lives, rivalHp, rivalMax }
	  { event = "rival", mogged, rival, rivals, passed, cash?, gems?, full? }
	  { event = "finish", score, rivals, best, newBest, passed, cash, gems, full,
	    cooldownEnds, rank? }
	  { event = "stop", reason }                     ended without a finish ("full" = no free spot)
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
	local serverBest: { MogRules.BestEntry } = {}
	local nextCheckId = 0

	local tierNames: { string } = {}
	for _, tier in theme.Tiers do
		table.insert(tierNames, tier.Name)
	end

	local function now(): number
		return workspace:GetServerTimeNow()
	end

	local function record(session: any): { best: number, rivals: number, clears: number, lastRewardAt: number }
		return session.profile.modes.mog
	end

	local function rewardFor(session: any): Economy.ModeReward
		local p = session.profile
		local rec = record(session)
		local pack = theme.Monetization.MoneyPacks[1]
		local progression = Economy.progression(Economy.highestTier(p.discovered), p.processLevel)
		return Economy.modeReward(Tycoon.income(session), progression, pack.Seconds, pack.Min, rec.clears == 0, rec.lastRewardAt, os.time())
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

	local function freeSpot(player: Player): number?
		-- A player who plays again within RETURN_AFTER still holds their spot: reuse it.
		for i = 1, #MogLayout.SPOTS do
			if spotOwner[i] == player then
				return i
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

	-- Holds the character still on its pad: anchored root, no jumping.
	local function hold(player: Player, state: State)
		local root = GameModes.root(player)
		if not root then
			return
		end
		local humanoid = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
		state.saved = {
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
	end

	-- Undoes hold() and frees the spot. Must run before any teleport away from the stage.
	local function release(player: Player, state: State)
		local saved = state.saved
		state.saved = nil
		if saved then
			saved.root.Anchored = false
			if saved.humanoid then
				saved.humanoid.JumpHeight = saved.jumpHeight
				saved.humanoid.JumpPower = saved.jumpPower
			end
		end
		if spotOwner[state.spot] == player then
			-- The player stands on the pad a few more seconds after a finish (RETURN_AFTER):
			-- keep the spot until they are gone so nobody is teleported onto them.
			local spot = state.spot
			task.delay(RETURN_AFTER + 1, function()
				if spotOwner[spot] == player then
					spotOwner[spot] = nil
				end
			end)
		end
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

	local function payPass(player: Player, state: State): Economy.ModeReward?
		local session = GameModes.session(player)
		if not session then
			return nil
		end
		local rec = record(session)
		local reward = GameModes.hooks.reward(session, ID, rewardFor(session))
		rec.clears += 1
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
				padPos = if root then root.Position else vec(MogLayout.SPOTS[state.spot].player),
			})
		end
		p.gems += reward.gems
		GameModes.hooks.rewarded(session, ID, reward)
		Tycoon.markDirty(session)
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
			gems = if reward then reward.gems else 0,
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
				payload.gems = if reward then reward.gems else 0
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

	local def = {} :: any
	def.id = ID

	function def.running(player: Player): boolean
		return runs[player] ~= nil
	end

	function def.start(player: Player, _teleport: boolean, _options: { [string]: any }?): boolean
		if runs[player] then
			return true
		end
		local session = GameModes.session(player)
		if not session or not GameModes.root(player) then
			return false
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
		-- The stage is teleport-only, so every start teleports.
		local spot = MogLayout.SPOTS[index]
		GameModes.teleport(player, vec(spot.player), Vector3.new(spot.faceX, 0, spot.faceZ))
		lastX[player] = spot.player.x
		hold(player, state)
		local best = record(session).best
		GameModes.notify(player, "start", ID, {
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

	function def.stop(player: Player, reason: string)
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
		local state = runs[player]
		if not state then
			if
				prevX
				and prevX > Course.GATE_X
				and x <= Course.GATE_X
				and math.abs(z - Course.GATES[2].z) <= Course.GATE_HALF + 1
				and pos.Y - FEET_BELOW_ROOT < Course.PLAZA.top + 8
			then
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
		local state = runs[player]
		local check = state and state.check
		if not state or not check or not state.pending then
			return
		end
		local id, at = data.id, data.at
		if type(id) ~= "number" or type(at) ~= "number" or at ~= at or id ~= state.checkId then
			return
		end
		local t = now()
		if at < state.appearAt - LAP_SLACK or at > state.appearAt + check.duration + LAP_SLACK then
			return
		end
		if at < t - PRESS_PAST or at > t + PRESS_FUTURE then
			return
		end
		local travel = check.speed * (at - state.appearAt)
		local result, reason = MogRules.judge(check, travel)
		resolve(player, state, result, reason, travel)
	end)

	function def.rewardPreview(player: Player): { [string]: any }
		local session = GameModes.session(player)
		if not session then
			return { cash = 0, gems = 0, full = false, packCash = 0 }
		end
		local r = rewardFor(session)
		return { cash = r.cash, gems = r.gems, full = r.full, packCash = r.packCash }
	end

	function def.snapshot(player: Player): { [string]: any }
		local session = GameModes.session(player)
		local state = runs[player]
		local rec = session and record(session)
		return {
			best = if rec then rec.best else 0,
			rivals = if rec then rec.rivals else 0,
			clears = if rec then rec.clears else 0,
			running = state ~= nil,
			score = if state then state.run.score else 0,
			lives = if state then state.run.lives else MogRules.LIVES,
			cooldownEnds = if rec and rec.lastRewardAt > 0 then rec.lastRewardAt + Economy.MODE_REWARD_COOLDOWN else 0,
			rewardPreview = def.rewardPreview(player),
			passRivals = MogRules.PASS_RIVALS,
		}
	end

	Players.PlayerRemoving:Connect(function(player)
		local state = runs[player]
		if state then
			release(player, state)
		end
		lastX[player] = nil
	end)
	updateBoard()
	return def
end

return { create = create }
