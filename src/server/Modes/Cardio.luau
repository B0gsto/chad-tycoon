--[[
	Cardio: the CARDIO game mode (gate 3), a keyboard runner out at sea (docs/cardio.md).
	Numbers in Modes.CardioRules, the runway in Modes.CardioLayout (built by World.CardioTrack).

	- "ModeStart" { mode = "cardio" } starts a run in the Warm-Up lobby (stage 1), always: the
	  action's other fields are ignored, so no client can start deeper. Starting again restarts.
	- Steps: every CardioRules.KEY_STEP studs of ground run over a key (server-measured, clamped
	  to what the current WalkSpeed allows) add stepMultiplier(bestStage, treadmill) Speed.
	  Standing on a treadmill adds treadmillRate(zone, treadmill, speed) Speed per second instead
	  (it grows with the player's Speed).
	  Speed (profile.cardio.speed) is permanent; in a run, WalkSpeed = CardioRules.walkSpeed(speed)
	  through the Humanoid "BaseWalkSpeed" attribute (Speedy Sneakers still multiplies on top),
	  lowered to the player's own cap if set.
	- "CardioSpeedCap" { cap: number? }: the player's own max WalkSpeed (the "Custom Speed" box).
	  nil / 0 / invalid clears it; else it is rounded and clamped to [16, walkSpeed(speed)].
	  Kept in profile.cardio.speedCap (0 = none); the base WalkSpeed is min(walkSpeed(speed), cap).
	- Steps are measured on the dense key carpet (CardioLayout.KEY.size studs) but paid per
	  CardioRules.KEY_STEP (8) studs, i.e. one step per ~two keys. Every key counts: bridge
	  sills, run-up pieces, jump / blink / mover / end platforms and decor blocks.
	- No checkpoints at all: feet below CardioLayout.killYAt(x) (the room's killY, just above
	  a bridge room's hazard floor, so landing on the hazard is a fall) or a chaser's catch send
	  the player back to the lobby (the start of stage 1) and the run starts over: nothing
	  reached, chasers reset. Speed, the treadmill level and bestStage are permanent.
	- Reaching a safe zone pays nothing. Zones are reached in order from the lobby, on foot
	  (zone n counts only on its deck, after bridge room n was entered this run with zone
	  n - 1 reached, so a teleport deeper or a late position report reaches nothing). Cash is paid only on a WIN pad (CardioLayout zone.winPad, one per safe zone
	  1..10; zone 10's is the finish): the server sees a living runner's feet on the pad of a
	  zone reached this run (CardioLayout.onWinPad) and pays Economy.modeReward x
	  stageBonus(n) for that zone: a first clear the first time that pad is claimed (always
	  paid; kept per pad in profile.cardio.firsts, CardioRules.firstsOf, so a pad that was run
	  past keeps its first clear for later), else only once per
	  Economy.MODE_REWARD_COOLDOWN (modes.cardio.lastRewardAt, shared by all ten pads). A pad
	  inside the cooldown pays the run again bonus, Economy.MODE_REPEAT_SHARE of its pack,
	  but only for a real run (CardioRules.repeatEarned): on the deepest pad claimed before
	  (bestStage, the personal best) or a deeper one, and no sooner than
	  CardioRules.REPEAT_GAP seconds after the last pad that paid; any other pad inside the
	  cooldown pays $0. A claim deeper than bestStage raises it and with it the
	  step multiplier. The claim ends the run: back to the lobby with nothing
	  reached, so one run pays at most once and a pad cannot be stepped on again without
	  running its stages again. Walking past a pad keeps the run going toward a bigger one.
	- Leaving the runway any other way (Home, GoModes...) ends the run ("left").
	- "CardioUpgrade": on the lobby SPEED UP pad, spends treadmillCost(level, income) cash for
	  treadmill level + 1 (max CardioRules.TREADMILL_MAX).

	Notify payloads (kind = "Mode", mode = "cardio"):
	  { event = "start", speed, walkSpeed, bestStage, multiplier }      always in the lobby
	  { event = "zone", stage, name, first, cash, full, cooldownEnds, pay, packCash, repeatCash,
	    repeatShare, repeatFrom, repeatReadyAt }
	                                  reached safe zone `stage`; cash = what its WIN pad pays
	                                  right now (nothing is paid yet)
	  { event = "win", stage, name, final, first, cash, full, cooldownEnds, bestStage, multiplier,
	    newBest, prevBest, pay, packCash, repeatCash, repeatShare, repeatFrom, repeatReadyAt }
	                                  claimed `stage`'s WIN pad (final = stage 10): paid, back
	                                  in the lobby; newBest = deeper than prevBest, the best
	                                  plate before this claim
	  Pay fields (as Parkour's finish): pay = "first" | "full" | "repeat" | "resting" | "none"
	  says why `cash` is what it is ("repeat": the run again bonus, repeatShare of packCash =
	  repeatCash; "resting": a plate that would pay it, inside CardioRules.REPEAT_GAP of the
	  last one); repeatFrom = the first plate that can pay the bonus (the best plate);
	  repeatReadyAt = os.time() from which the bonus is paid again (0 = now).
	  { event = "fall", stage = 0, from, reason, speed, need, slow, capped }
	                                  back in the lobby from stage `from`; reason "fall" |
	                                  "caught"; speed = whole Speed, need = that stage's need,
	                                  slow = the run's WalkSpeed was below what the need gives,
	                                  capped = ...only because of the player's own speed cap
	  { event = "upgrade", level, cost, rate, multiplier, nextCost? }
	  { event = "refused", reason, cost? }        upgrade refused: "run" | "far" | "max" | "cash"
	  { event = "stop", reason }
	Snapshot: running, speed, walkSpeed (effective base, capped), maxWalkSpeed (uncapped),
	speedCap (nil when none), multiplier, bestStage, treadmill, treadmillMax, treadmillRate,
	nextCost, stage, reached (safe zones reached this run), wins (in a run: wins[n] = cash safe
	zone n's WIN pad pays right now), firsts (in a run: firsts[n] = pad n's first clear is
	still there), repeats (in a run: repeats[n] = the run again bonus pad n pays inside the
	cooldown once repeatReadyAt has come, 0 = none), repeatFrom, repeatReadyAt, repeatShare, onTreadmill, cooldownEnds, stageCount, needs, recommended (Speed the HUD
	recommends per stage, CardioRules.recommended), names.
	Effects: "CardioSteps" { gained, speed, walkSpeed, treadmill, multiplier, rate } (at most ~4
	per second while gaining; speed and gained are whole Speed, treadmill is true on a belt,
	multiplier is the step multiplier, rate the current treadmillRate), "ModeSplash" { pos } on a fall, "ModeFinish" { pos, newBest } on a first clear,
	"Cash" { amount, source = "Mode", padPos } when a WIN pad pays.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Economy = require(ReplicatedStorage.Shared.Economy)
local Cosmetics = require(script.Parent.Parent.Cosmetics)
local CardioLayout = require(script.Parent.CardioLayout)
local CardioRules = require(script.Parent.CardioRules)
local CardioChase = require(script.Parent.CardioChase) -- CardioChase hook
local Course = require(script.Parent.Course)

local Cardio = {}

local ID = "cardio"
-- Seconds after a teleport during which position checks are skipped.
local TELEPORT_GRACE = 0.6
-- Feet are this far below the HumanoidRootPart's centre on a default character.
local FEET_BELOW_ROOT = 3
-- Seconds between "CardioSteps" effects.
local EFFECT_EVERY = 0.25
-- Ground distance counted per tick: up to WalkSpeed x dt x STEP_SLACK + STEP_EXTRA studs.
local STEP_SLACK = 1.25
local STEP_EXTRA = 0.5
-- Longest tick counted (server hiccups don't turn into a burst of steps).
local MAX_DT = 0.5
-- WalkSpeed is re-applied when the curve moved this much.
local WALK_STEP = 0.25
-- Studs around the runway bounds that still count as "on the runway" (falls past the edge).
local BOUNDS_MARGIN = 80
-- Seconds off the runway before the run ends (a late position report after a teleport).
local LEAVE_SECONDS = 1.5
-- Reach of the SPEED UP pad, studs past its edge (horizontal) and above the deck.
local PAD_REACH = 6
local PAD_HEIGHT = 10

local LAYOUT = CardioLayout.LAYOUT
local BOUNDS = LAYOUT.bounds
local FORWARD = Vector3.new(1, 0, 0)

local NEEDS = {}
local RECOMMENDED = {}
local NAMES = {}
for n, s in CardioRules.STAGES do
	NEEDS[n] = s.need
	RECOMMENDED[n] = CardioRules.recommended(n)
	NAMES[n] = s.name
end

type State = {
	-- Highest safe zone reached this run, in order from the lobby (0 = none yet), and the
	-- bridge room entered toward the next one (reached + 1, or 0).
	reached: number,
	crossing: number,
	lastPos: Vector3?,
	lastT: number,
	graceUntil: number,
	outsideSince: number?,
	-- Studs of key ground not yet turned into a step.
	stepDist: number,
	-- WalkSpeed currently applied (BaseWalkSpeed).
	walk: number,
	-- Whole Speed last reported by "CardioSteps" and when.
	shownSpeed: number,
	lastEffectAt: number,
	stage: number,
	onTreadmill: boolean,
	treadmillZone: number,
}

local function vec(p: { x: number, y: number, z: number }): Vector3
	return Vector3.new(p.x, p.y, p.z)
end

-- Where every run starts and every fall, catch and WIN pad claim ends: the lobby's spawn.
local LOBBY_SPAWN: CardioLayout.Point = CardioLayout.spawn(0) or LAYOUT.zones[1].spawn

local function inBounds(x: number, z: number, margin: number): boolean
	return x >= BOUNDS.x0 - margin and x <= BOUNDS.x1 + margin and z >= BOUNDS.z0 - margin and z <= BOUNDS.z1 + margin
end

function Cardio.create(GameModes: any, context: { built: any, theme: any, Tycoon: any })
	local theme = context.theme
	local Tycoon = context.Tycoon
	local runs: { [Player]: State } = {}
	-- Server time of each player's last WIN pad that paid cash (the run again bonus' gap).
	local lastPaidAt: { [Player]: number } = {}
	-- CardioChase hook: chaser Chads on stages 3, 6 and 9 (Modes.CardioChase).
	local chaser = CardioChase.serve(function(p: Player, event: string, data: { [string]: any })
		GameModes.notify(p, event, ID, data)
	end)

	local function now(): number
		return workspace:GetServerTimeNow()
	end

	local function record(
		session: any
	): { speed: number, bestStage: number, treadmill: number, clears: number, speedCap: number, firsts: number? }
		return session.profile.cardio
	end

	-- The WIN pads whose first clear was taken (a bit set; DataService.reconcile fills it in on
	-- saves without it, and this read repairs a record that still lacks it).
	local function firstsOf(session: any): number
		local rec = record(session)
		local firsts = CardioRules.firstsOf(rec.firsts, rec.bestStage)
		rec.firsts = firsts
		return firsts
	end

	-- The player's own max WalkSpeed, or nil when none.
	local function capOf(session: any): number?
		local cap = record(session).speedCap
		return if type(cap) == "number" and cap >= CardioRules.BASE_WALK then cap else nil
	end

	-- Base WalkSpeed in a run: the Speed curve, lowered to the player's cap.
	local function walkOf(session: any): number
		local walk = CardioRules.walkSpeed(record(session).speed)
		local cap = capOf(session)
		return if cap then math.min(walk, cap) else walk
	end

	local function cooldown(session: any): { best: number, clears: number, lastRewardAt: number }
		return session.profile.modes.cardio
	end

	local function multiplierOf(session: any): number
		local rec = record(session)
		return CardioRules.stepMultiplier(rec.bestStage, rec.treadmill)
	end

	local function nextCostOf(session: any): number?
		local rec = record(session)
		if rec.treadmill >= CardioRules.TREADMILL_MAX then
			return nil
		end
		return CardioRules.treadmillCost(rec.treadmill, Tycoon.income(session))
	end

	local function cooldownEnds(session: any): number
		local at = cooldown(session).lastRewardAt
		return if at > 0 then at + Economy.MODE_REWARD_COOLDOWN else 0
	end

	local function humanoidOf(player: Player): Humanoid?
		local character = player.Character
		return character and character:FindFirstChildOfClass("Humanoid")
	end

	local function alive(player: Player): boolean
		local humanoid = humanoidOf(player)
		return humanoid ~= nil and humanoid.Health > 0
	end

	-- Feet below the root's centre: hip height + half the root on R15 (scaled avatars too),
	-- FEET_BELOW_ROOT otherwise. Keeps a body standing on a hazard floor below its killY.
	local function feetBelow(player: Player, root: BasePart): number
		local humanoid = humanoidOf(player)
		if humanoid and humanoid.RigType == Enum.HumanoidRigType.R15 and humanoid.HipHeight > 0 then
			return humanoid.HipHeight + root.Size.Y / 2
		end
		return FEET_BELOW_ROOT
	end

	-- Sets the run's WalkSpeed without rebuilding the cosmetics (Sneakers' multiplier kept).
	local function applyWalk(player: Player, state: State, walk: number)
		state.walk = walk
		local humanoid = humanoidOf(player)
		if not humanoid then
			return
		end
		humanoid:SetAttribute("BaseWalkSpeed", walk)
		local mult = humanoid:GetAttribute("SpeedMultiplier")
		humanoid.WalkSpeed = walk * (if type(mult) == "number" then mult else 1)
	end

	-- Seconds until the run again bonus can be paid again (0 = now).
	local function repeatLeft(session: any): number
		local at = lastPaidAt[session.player]
		return if at then math.max(0, at + CardioRules.REPEAT_GAP - now()) else 0
	end

	-- os.time() from which the run again bonus is paid again (0 = now), for the HUD.
	local function repeatReadyAt(session: any): number
		local left = repeatLeft(session)
		return if left > 0 then os.time() + math.ceil(left) else 0
	end

	-- What safe zone `stage`'s WIN pad pays right now and why (CardioRules.payKind): inside
	-- the cooldown only a claim that earned it gets the run again bonus (`repeatCash`).
	local function rewardFor(session: any, stage: number, first: boolean): (Economy.ModeReward, string)
		local p = session.profile
		local pack = theme.Modes.Reward
		local progression = Economy.progression(Economy.highestTier(p.runDiscovered), p.processLevel)
		local r = Economy.modeReward(
			Tycoon.income(session),
			progression,
			pack.Seconds,
			pack.Min,
			first,
			cooldown(session).lastRewardAt,
			os.time()
		)
		r.packCash = math.floor(r.packCash * CardioRules.stageBonus(stage) + 0.5)
		r.repeatCash = math.floor(r.packCash * Economy.MODE_REPEAT_SHARE)
		local sincePaid = CardioRules.REPEAT_GAP - repeatLeft(session)
		local best = record(session).bestStage
		local earned = CardioRules.repeatEarned(stage, best, sincePaid)
		-- A plate deep enough for the bonus, only too soon after the last one: it rests.
		local resting = not earned and CardioRules.repeatEarned(stage, best, CardioRules.REPEAT_GAP)
		local kind = CardioRules.payKind(first, r.full, earned, resting)
		r.cash = if r.full then r.packCash elseif kind == "repeat" then r.repeatCash else 0
		return r, kind
	end

	-- What safe zone `stage`'s WIN pad pays right now, whether it would be a first clear
	-- (this pad was never claimed: always paid; anything else pays once per cooldown, and the
	-- run again bonus inside it) and why it pays that.
	local function winReward(session: any, stage: number): (Economy.ModeReward, boolean, string)
		local first = CardioRules.isFirst(firstsOf(session), stage)
		local reward, kind = rewardFor(session, stage, first)
		return reward, first, kind
	end

	-- The pay fields of a "zone" or "win" payload.
	local function payFields(payload: { [string]: any }, session: any, reward: Economy.ModeReward, kind: string)
		payload.cash = reward.cash
		payload.full = reward.full
		payload.pay = kind
		payload.packCash = reward.packCash
		payload.repeatCash = reward.repeatCash
		payload.repeatShare = Economy.MODE_REPEAT_SHARE
		payload.repeatFrom = CardioRules.repeatFrom(record(session).bestStage)
		payload.repeatReadyAt = repeatReadyAt(session)
		payload.cooldownEnds = cooldownEnds(session)
	end

	local function teleportTo(player: Player, state: State, c: CardioLayout.Point)
		GameModes.teleport(player, vec(c), FORWARD)
		state.lastPos = nil
		state.stepDist = 0
		state.graceUntil = now() + TELEPORT_GRACE
	end

	-- The run starts over (a fall, a catch, a WIN pad claim): back on the lobby spawn with no
	-- safe zone reached and every chaser ready again.
	local function restart(player: Player, state: State, reason: string)
		chaser.stop(player, reason) -- CardioChase hook
		chaser.forget(player) -- CardioChase hook
		state.reached = 0
		state.crossing = 0
		state.stage = 0
		state.onTreadmill = false
		teleportTo(player, state, LOBBY_SPAWN)
	end

	-- Last X seen while not running (plaza gate crossing).
	local lastX: { [Player]: number } = {}

	local def = {} :: any
	def.id = ID

	function def.running(player: Player): boolean
		return runs[player] ~= nil
	end

	-- Every run starts in the lobby (safe zone 0), whatever the "ModeStart" data says: reached
	-- stages (bestStage) are a record, not a place to start from.
	function def.start(player: Player, _teleport: boolean, _options: { [string]: any }?): boolean
		local session = GameModes.session(player)
		if not session then
			return false
		end
		local rec = record(session)
		local t = now()
		chaser.stop(player, "restart") -- CardioChase hook
		chaser.forget(player) -- CardioChase hook
		local state: State = {
			reached = 0,
			crossing = 0,
			lastPos = nil,
			lastT = t,
			graceUntil = t + TELEPORT_GRACE,
			outsideSince = nil,
			stepDist = 0,
			walk = walkOf(session),
			shownSpeed = math.floor(rec.speed),
			lastEffectAt = 0,
			stage = 0,
			onTreadmill = false,
			treadmillZone = 0,
		}
		runs[player] = state
		-- The arena is far out at sea: a run always begins on its deck.
		teleportTo(player, state, LOBBY_SPAWN)
		local humanoid = humanoidOf(player)
		if humanoid then
			humanoid:SetAttribute("BaseWalkSpeed", state.walk)
		end
		Cosmetics.refresh(player)
		GameModes.notify(player, "start", ID, {
			speed = math.floor(rec.speed),
			walkSpeed = state.walk,
			bestStage = rec.bestStage,
			multiplier = multiplierOf(session),
		})
		GameModes.refresh(player)
		return true
	end

	function def.stop(player: Player, reason: string)
		if not runs[player] then
			return
		end
		runs[player] = nil
		chaser.stop(player, reason, reason == "leave") -- CardioChase hook
		chaser.forget(player) -- CardioChase hook
		local humanoid = humanoidOf(player)
		if humanoid then
			humanoid:SetAttribute("BaseWalkSpeed", theme.Cosmetics.BaseWalkSpeed)
		end
		if reason ~= "leave" then
			Cosmetics.refresh(player)
			GameModes.notify(player, "stop", ID, { reason = reason })
			GameModes.refresh(player)
		end
	end

	-- Reached safe zone `stage` (>= 1) this run. Nothing is paid here: the HUD learns what the
	-- zone's WIN pad would pay.
	local function reach(player: Player, session: any, stage: number)
		local reward, first, kind = winReward(session, stage)
		local s = CardioRules.STAGES[stage]
		local payload: { [string]: any } = { stage = stage, name = s and s.name, first = first }
		payFields(payload, session, reward, kind)
		GameModes.notify(player, "zone", ID, payload)
		GameModes.refresh(player)
	end

	-- Stepped on safe zone `stage`'s WIN pad: pays that stage, records it and ends the run
	-- (back to the lobby, nothing reached: one claim per run).
	local function win(player: Player, session: any, state: State, root: BasePart, stage: number)
		local rec = record(session)
		local shared = cooldown(session)
		local firsts = firstsOf(session)
		local first = CardioRules.isFirst(firsts, stage)
		-- Priced against the best plate before this claim.
		local prevBest = rec.bestStage
		local priced, kind = rewardFor(session, stage, first)
		local reward = GameModes.hooks.reward(session, ID, priced)
		rec.clears += 1
		shared.clears = rec.clears
		rec.firsts = CardioRules.claimFirst(firsts, stage)
		if stage > rec.bestStage then
			rec.bestStage = stage
			shared.best = stage
		end
		if reward.full then
			shared.lastRewardAt = os.time()
		end
		local p = session.profile
		if reward.cash > 0 then
			p.money += reward.cash
			p.totalEarned += reward.cash
			lastPaidAt[player] = now()
			GameModes.effect(player, "Cash", { amount = reward.cash, source = "Mode", padPos = root.Position })
		end
		if first then
			GameModes.effect(player, "ModeFinish", { pos = root.Position, newBest = true })
		end
		restart(player, state, "win")
		local s = CardioRules.STAGES[stage]
		local payload: { [string]: any } = {
			stage = stage,
			name = s and s.name,
			final = stage >= CardioRules.STAGE_COUNT,
			first = first,
			bestStage = rec.bestStage,
			prevBest = prevBest,
			newBest = stage > prevBest,
			multiplier = multiplierOf(session),
		}
		payFields(payload, session, reward, kind)
		GameModes.notify(player, "win", ID, payload)
		GameModes.hooks.rewarded(session, ID, reward)
		Tycoon.markDirty(session)
		GameModes.refresh(player)
	end

	function def.tick(player: Player, root: BasePart, t: number)
		local state = runs[player]
		if not state then
			-- Walking through this mode's gate on either plaza (toward -X on the first, toward +X
			-- on the mirrored second) starts a run.
			local gx = root.Position.X
			local prevX = lastX[player]
			lastX[player] = gx
			local gate = Course.GATES[def.slot]
			local gate2 = Course.GATES2 and Course.GATES2[def.slot]
			local gz = root.Position.Z
			local crossed = prevX ~= nil
				and (
					(gate ~= nil and prevX > Course.GATE_X and gx <= Course.GATE_X and math.abs(gz - gate.z) <= Course.GATE_HALF + 1)
					or (gate2 ~= nil and prevX < Course.GATE2_X and gx >= Course.GATE2_X and math.abs(gz - gate2.z) <= Course.GATE_HALF + 1)
				)
			if crossed and root.Position.Y - FEET_BELOW_ROOT < Course.PLAZA.top + 8 then
				lastX[player] = nil
				GameModes.start(player, ID, true)
			end
			return
		end
		lastX[player] = nil
		local session = GameModes.session(player)
		if not session then
			return
		end
		local pos = root.Position
		local x, y, z = pos.X, pos.Y - feetBelow(player, root), pos.Z
		local dt = math.clamp(t - state.lastT, 0, MAX_DT)
		state.lastT = t
		if t < state.graceUntil then
			state.lastPos = pos
			return
		end
		if not inBounds(x, z, BOUNDS_MARGIN) then
			state.outsideSince = state.outsideSince or t
			if t - (state.outsideSince :: number) >= LEAVE_SECONDS then
				def.stop(player, "left")
			end
			state.lastPos = nil
			return
		end
		state.outsideSince = nil
		-- The last safe zone passed (the HUD shows stage + 1 as the stage being run).
		state.stage = CardioLayout.startStageAt(x)
		local killY = CardioLayout.killYAt(x)
		-- No checkpoints: a fall or a catch (CardioChase hook) starts the run over in the lobby.
		local failed: string? = nil
		if y < killY then
			GameModes.effect(player, "ModeSplash", { pos = Vector3.new(x, killY - CardioLayout.KILL_ABOVE, z) })
			failed = "fall"
		elseif chaser.tick(player, x, z, t) then
			failed = "caught"
		end
		if failed then
			local from = state.stage + 1
			-- Why, for the HUD: was the run slower than the stage's need asks for?
			local speed = record(session).speed
			local need = NEEDS[from] or 0
			local slow = state.walk < CardioRules.walkSpeed(need) - WALK_STEP
			restart(player, state, failed)
			GameModes.notify(player, "fall", ID, {
				stage = 0,
				from = from,
				reason = failed,
				speed = math.floor(speed),
				need = need,
				slow = slow,
				capped = slow and speed >= need,
			})
			GameModes.refresh(player)
			return
		end

		-- Speed: treadmill or steps on keys.
		local rec = record(session)
		local before = rec.speed
		local zoneStage = CardioLayout.onTreadmill(x, y, z)
		state.onTreadmill = zoneStage ~= nil
		if zoneStage then
			state.treadmillZone = zoneStage
			state.stepDist = 0
			rec.speed += CardioRules.treadmillRate(zoneStage, rec.treadmill, rec.speed) * dt
		else
			local last = state.lastPos
			if last and CardioLayout.isOverKey(x, y, z, t) then
				local moved = Vector3.new(x - last.X, 0, z - last.Z).Magnitude
				local humanoid = humanoidOf(player)
				local mult = humanoid and humanoid:GetAttribute("SpeedMultiplier")
				local walk = state.walk * (if type(mult) == "number" then mult else 1)
				state.stepDist += math.min(moved, walk * dt * STEP_SLACK + STEP_EXTRA)
				if state.stepDist >= CardioRules.KEY_STEP then
					local steps = math.floor(state.stepDist / CardioRules.KEY_STEP)
					state.stepDist -= steps * CardioRules.KEY_STEP
					rec.speed += steps * multiplierOf(session)
				end
			end
		end
		state.lastPos = pos
		if rec.speed ~= before then
			Tycoon.markDirty(session)
			local walk = walkOf(session)
			local top = math.min(CardioRules.WALK_CAP, capOf(session) or math.huge)
			if math.abs(walk - state.walk) >= WALK_STEP or (walk >= top and state.walk ~= walk) then
				applyWalk(player, state, walk)
			end
			local shown = math.floor(rec.speed)
			if shown > state.shownSpeed and t - state.lastEffectAt >= EFFECT_EVERY then
				GameModes.effect(player, "CardioSteps", {
					gained = shown - state.shownSpeed,
					speed = shown,
					walkSpeed = state.walk,
					treadmill = state.onTreadmill,
					multiplier = multiplierOf(session),
					rate = CardioRules.treadmillRate(state.treadmillZone, rec.treadmill, rec.speed),
				})
				state.shownSpeed = shown
				state.lastEffectAt = t
			end
		end

		-- Safe zones are reached in order and on foot: the next zone counts on its deck once its
		-- bridge room was entered this run (a teleport deeper reaches nothing).
		local room = CardioLayout.roomAt(x)
		if room and room.kind == "bridge" and room.stage == state.reached + 1 then
			state.crossing = room.stage
		end
		local zone = CardioLayout.zoneAt(x, z, y)
		if zone and zone.stage == state.reached + 1 and state.crossing == zone.stage then
			state.reached = zone.stage
			reach(player, session, zone.stage)
		end
		-- WIN pad: a living runner on the pad of a zone reached this run cashes out. The claim
		-- restarts the run (nothing reached), so the pad cannot pay twice.
		local padStage = CardioLayout.onWinPad(x, y, z)
		if padStage and padStage <= state.reached and alive(player) then
			win(player, session, state, root, padStage)
		end
	end

	-- What the WIN pad of the next new stage would pay right now (`repeatCash`: its run again
	-- bonus inside the cooldown, `repeatShare` of `packCash`).
	function def.rewardPreview(player: Player): { [string]: any }
		local session = GameModes.session(player)
		if not session then
			return { cash = 0, full = false, packCash = 0, repeatCash = 0, repeatShare = Economy.MODE_REPEAT_SHARE }
		end
		local rec = record(session)
		local r = winReward(session, math.min(rec.bestStage + 1, CardioRules.STAGE_COUNT))
		return {
			cash = r.cash,
			full = r.full,
			packCash = r.packCash,
			repeatCash = r.repeatCash,
			repeatShare = Economy.MODE_REPEAT_SHARE,
		}
	end

	function def.snapshot(player: Player): { [string]: any }
		local session = GameModes.session(player)
		local state = runs[player]
		local rec = session and record(session)
		local speed = if rec then rec.speed else 0
		local level = if rec then rec.treadmill else 0
		-- In a run: what each safe zone's WIN pad pays right now (the pads' floating labels)
		-- and whether its first clear is still there.
		local wins: { number }? = nil
		local firsts: { boolean }? = nil
		-- ...and the run again bonus each pad pays inside the cooldown once its gap is over.
		local repeats: { number }? = nil
		if session and state then
			local list, firstList, repeatList = {}, {}, {}
			local from = CardioRules.repeatFrom(record(session).bestStage)
			for n = 1, CardioRules.STAGE_COUNT do
				local reward, first = winReward(session, n)
				list[n] = reward.cash
				firstList[n] = first
				repeatList[n] = if not reward.full and n >= from then reward.repeatCash else 0
			end
			wins, firsts, repeats = list, firstList, repeatList
		end
		return {
			running = state ~= nil,
			speed = math.floor(speed),
			walkSpeed = if session then walkOf(session) else CardioRules.walkSpeed(speed),
			maxWalkSpeed = CardioRules.walkSpeed(speed),
			speedCap = if session then capOf(session) else nil,
			multiplier = CardioRules.stepMultiplier(if rec then rec.bestStage else 0, level),
			bestStage = if rec then rec.bestStage else 0,
			treadmill = level,
			treadmillMax = CardioRules.TREADMILL_MAX,
			treadmillRate = CardioRules.treadmillRate(if state then state.treadmillZone else 0, level, speed),
			nextCost = if session then nextCostOf(session) else nil,
			stage = if state then state.stage else 0,
			reached = if state then state.reached else 0,
			wins = wins,
			firsts = firsts,
			repeats = repeats,
			repeatFrom = CardioRules.repeatFrom(if rec then rec.bestStage else 0),
			repeatReadyAt = if session then repeatReadyAt(session) else 0,
			repeatShare = Economy.MODE_REPEAT_SHARE,
			onTreadmill = if state then state.onTreadmill else false,
			cooldownEnds = if session then cooldownEnds(session) else 0,
			stageCount = CardioRules.STAGE_COUNT,
			needs = NEEDS,
			recommended = RECOMMENDED,
			names = NAMES,
		}
	end

	local function refuse(session: any, reason: string, text: string, cost: number?)
		Tycoon.toast(session, text, "bad")
		GameModes.notify(session.player, "refused", ID, { reason = reason, cost = cost })
	end

	Tycoon.addAction("CardioUpgrade", function(session: any)
		local player = session.player
		if not runs[player] then
			refuse(session, "run", "Start a Cardio run to upgrade your treadmill!")
			return
		end
		local root = GameModes.root(player)
		local lobby = CardioLayout.zone(0)
		local pad = lobby and lobby.upgradePad
		if not root or not lobby or not pad then
			return
		end
		local pos = root.Position
		local feet = pos.Y - FEET_BELOW_ROOT
		local reach = pad.size / 2 + PAD_REACH
		if math.abs(pos.X - pad.x) > reach or math.abs(pos.Z - pad.z) > reach or feet < lobby.top - 2 or feet > lobby.top + PAD_HEIGHT then
			refuse(session, "far", "Step on the SPEED UP pad in the Warm-Up lobby!")
			return
		end
		local rec = record(session)
		local cost = nextCostOf(session)
		if not cost then
			refuse(session, "max", "Your treadmill is already at max speed!")
			return
		end
		if session.profile.money < cost then
			refuse(session, "cash", "Not enough cash yet! Keep running and come back.", cost)
			return
		end
		session.profile.money -= cost
		rec.treadmill += 1
		GameModes.notify(player, "upgrade", ID, {
			level = rec.treadmill,
			cost = cost,
			rate = CardioRules.treadmillRate(0, rec.treadmill, rec.speed),
			multiplier = multiplierOf(session),
			nextCost = nextCostOf(session),
		})
		Tycoon.markDirty(session)
		GameModes.refresh(player)
	end)

	Tycoon.addAction("CardioSpeedCap", function(session: any, data: { [string]: any })
		local player = session.player
		local rec = record(session)
		local asked = type(data) == "table" and data.cap or nil
		local cap = 0
		if type(asked) == "number" and asked == asked and asked > 0 and asked ~= math.huge then
			-- Rounded after the clamp: a cap a fraction above the curve still only lowers WalkSpeed
			-- through walkOf's min.
			local max = CardioRules.walkSpeed(rec.speed)
			cap = math.floor(math.clamp(asked, CardioRules.BASE_WALK, max) + 0.5)
		end
		if rec.speedCap == cap then
			return
		end
		rec.speedCap = cap
		local state = runs[player]
		if state then
			applyWalk(player, state, walkOf(session))
		end
		Tycoon.markDirty(session)
		GameModes.refresh(player)
	end)

	game:GetService("Players").PlayerRemoving:Connect(function(player)
		runs[player] = nil
		lastX[player] = nil
		lastPaidAt[player] = nil
		chaser.forget(player) -- CardioChase hook
	end)
	return def
end

return Cardio
