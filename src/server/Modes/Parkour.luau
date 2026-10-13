--[[
	Parkour: the first game mode. Timed runs over the ten levels in Modes.Course.

	- Levels: every level is out at sea and reached only by teleport. A player has unlocked
	  level 1 + (number of consecutive cleared or skipped levels from 1); "ModeStart" may pick
	  any unlocked level (options.level), else the lowest level not yet cleared or skipped
	  (with none left: the lowest not yet cleared). Walking west
	  through gate 1's portal (Course.crossedStart) does not start a run: it sends a "pick"
	  notify so the client opens the Maps window on the default level. Starting again
	  restarts.
	- No checkpoints (owner's call, docs/sky-obby.md): falling below the cloud floor
	  (Course.inWater) or touching lava (Course.inKill) sends the player back to the START
	  DECK of the map they are running; the clock keeps going.
	- Standing on the finish deck ends the run; Rules.finish checks that the start-to-finish
	  time was not impossibly fast (Course level MIN_SECONDS). Valid finishes record the per-level best/clears
	  (profile.parkour; level 1 is mirrored into profile.modes.parkour) and the server best
	  list of that level, and pay Economy.modeReward × Economy.parkourLevelBonus(level):
	  Theme.Modes.Reward (Seconds of income, at least Min, sized like a cash pack) on the
	  first clear OF THAT LEVEL and then once per
	  Economy.MODE_REWARD_COOLDOWN (one cooldown shared by all levels, modes.parkour.
	  lastRewardAt). Inside the cooldown a clean finish (no gear worn) pays
	  Economy.MODE_REPEAT_SHARE of that map's pack, then that map's bonus rests for
	  REPEAT_REST_SECONDS (in memory, per player and map: a run inside the rest finishes as
	  usual and pays nothing); an assisted one pays nothing. After a remote
	  finish the player is brought back to the gates (GameModes.returnLater) wherever they
	  stand on the sky course by then (the finish deck, a bridge, the next map's start deck);
	  while the finish card is up (action "ModeCard" { mode, open }) the return waits, for
	  CARD_HOLD_SECONDS at the most.
	- Leaving the level's bounds for Course.LEAVE_SECONDS ends the run ("left"); on a remote
	  level the player goes back to the gates.
	- Nobody stays on the sky course without a run: a player with no run who is below the
	  cloud floor, or off every map's start and finish deck for STRANDED_SECONDS (a bridge, a
	  map's path), is taken back to the gates with the toast "Back to the gates" (checked on
	  every mode tick).
	- Stages (docs/sky-obby.md): the ten maps are one chained sky obby; a stage is a map (map n
	  is stage n, map 10's finish is Course.STAGE_COUNT = 11). Stage numbers are progress
	  labels only, never a respawn spot. profile.parkour.stage keeps the highest stage
	  reached (finishing map n reaches n + 1); it follows only the maps really cleared in a
	  row from map 1, so a skipped map never counts (the STAGE board reads it). Player
	  attributes "ParkourStage" (this run's stage, 0 when not running), "ParkourBestStage" and
	  "ParkourProgress" (how far along the map's path the runner stands, 0..1 in hundredths
	  from Course.progress, 0 when not running) feed the HUD's progress bar.
	- Gear: action "ParkourGear" { gear = "none" | "speed" | "jump" | "gravity" } saves the
	  choice (profile.parkour.gear); it is worn only during a run (speed: WalkSpeed 16 -> 28
	  through the Humanoid's BaseWalkSpeed; jump: JumpHeight 7.2 -> 14 or JumpPower 50 -> 70;
	  gravity: a "GravityCoil" VectorForce on the root lifting 55% of the weight) and taken off
	  on stop / finish / leave. A run that wore gear at any point is `assisted`.
	- Skip Map: action "ParkourSkip" costs Economy.parkourSkipCost(income) cash (two minutes
	  of income, at least Economy.PARKOUR_SKIP_MIN; the snapshot's `skipCost`; a cash action,
	  no Robux receipt). It only unlocks the next map (profile.parkour.skipped[level] = 1): no
	  reward, no clear, no best time, no stage and no board entry, so the map's real first
	  clear still pays later. The run ends and the player stands in front of the gates with
	  the Maps window opened on the next map (nothing starts by itself). With nothing to
	  unlock (the last map, or the next map already unlocked) it is refused and costs nothing.
	  Assisted runs (gear) pay, unlock and count clears but never record a best time or a
	  board entry.

	Notify payloads (kind = "Mode", mode = "parkour"):
	  { event = "pick", level }                                  crossed gate 1: open the Maps
	                                                             window on `level` (the default)
	  { event = "start", checkpoints = 0, startedAt, best?, level, levelName, levels, remote,
	    stage, stageCount, gear, assisted }
	  { event = "respawn", index = 0, stage, stageCount, reason?, falls }
	                                                             back at the map's start deck
	                                                             reason = "kill" after lava;
	                                                             falls: this run's count
	  { event = "skip", stage, stageCount, index = 0, checkpoints = 0, level, paid = 0,
	    nextLevel, unlocked }                                    paid Skip Map of `level`: it
	                                                             paid nothing; followed by
	                                                             "stop" (reason "skip") and
	                                                             "pick" (level = nextLevel)
	(`checkpoints` / `index` stay 0 for older client code; there is no "checkpoint" event.)
	  { event = "finish", time, best, newBest, first, cash, full, cooldownEnds, rank?,
	    level, levelName, nextLevel?, unlockedNew, unlocked, levels, stage, stageCount,
	    assisted, falls, pay, packCash, repeatCash, repeatShare, repeatRest, complete }
	                                                             assisted: newBest false, no rank
	                                                             pay: why `cash` is what it is:
	                                                             "first" (the map's first clear),
	                                                             "full" (the cooldown was over),
	                                                             "repeat" (a clean run inside the
	                                                             cooldown: repeatCash),
	                                                             "resting" (the same while the
	                                                             map's bonus rests: 0; back in
	                                                             repeatRest seconds) or
	                                                             "assisted" (gear inside the
	                                                             cooldown: 0); packCash and
	                                                             repeatCash are this map's full
	                                                             and repeat pay
	                                                             complete: this run made it all
	                                                             ten maps cleared without gear,
	                                                             for the first time
	`stage` is the global stage (the map being run; its finish deck: the next one).
	  { event = "invalid", reason }                              "fast"
	  { event = "stop", reason }                                 run ended without a finish
	Effects: "ModeSplash" { pos } where the player hit the water; "ModeKill" { pos } where a
	kill brick (Course.inKill) caught them; "ModeFinish" { pos, newBest }; plus the usual "Cash" { amount,
	source = "Mode", padPos } when cash is paid.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Economy = require(ReplicatedStorage.Shared.Economy)
local Format = require(ReplicatedStorage.Shared.Format)
local Course = require(script.Parent.Course)
local Rules = require(script.Parent.Rules)

local Parkour = {}

local ID = "parkour"
local BEST_SIZE = 8
-- Seconds after a teleport during which position checks are skipped (the client may still
-- report its old position).
local TELEPORT_GRACE = 0.6
-- Feet are this far below the HumanoidRootPart's centre on a default character.
local FEET_BELOW_ROOT = 3
-- Seconds after a remote finish before the player is taken back to the gates.
local RETURN_SECONDS = 15
-- The return waits while the finish card is up (action "ModeCard"), checked every
-- CARD_POLL_SECONDS and for CARD_HOLD_SECONDS at the most: a client that never says the card
-- closed cannot keep its player in the sky.
local CARD_HOLD_SECONDS = 20
local CARD_POLL_SECONDS = 1
-- Seconds a map's run again bonus rests after it was paid: runs inside it finish as usual
-- and pay nothing, so the bonus cannot be farmed in a loop on one short map.
local REPEAT_REST_SECONDS = 120
-- Seconds a player with no run may stand off every start / finish deck of the sky course
-- before they are taken back to the gates.
local STRANDED_SECONDS = 2
-- A player with no run is caught down to this far under the cloud floor (the hub lies under
-- some maps, much lower: nobody down there is touched).
local RESCUE_DEPTH = 150
-- Studs around the maps' rectangles that still count as the sky course (the bridges between
-- them, the drift of a fall).
local SKY_MARGIN = 60
-- A deck holds feet this far past its edge, under its top and over it (a jump).
local DECK_EDGE = 1.5
local DECK_UNDER = 2
local DECK_OVER = 20

-- Gear (coils) worn during runs.
local GEARS = { none = true, speed = true, jump = true, gravity = true }
local GEAR_WALK_SPEED = 28
local GEAR_JUMP_HEIGHT = 14
local DEFAULT_JUMP_POWER = 50
local GEAR_JUMP_POWER = 70
-- Share of the character's weight the gravity coil cancels.
local GRAVITY_CANCEL = 0.55
local COIL = "GravityCoil"

type State = {
	run: Rules.Run,
	outsideSince: number?,
	graceUntil: number,
	-- Gear was worn during this run.
	assisted: boolean,
	-- The speed coil was worn during this run (looser anti-cheat minimums).
	speedUsed: boolean,
	-- Times this run went back to the start deck (cloud floor or lava).
	falls: number,
	-- Course.progress of the runner's last trusted position, in hundredths.
	progress: number,
}

type Worn = { gear: string, humanoid: any, root: any, base: any }

-- `skipped` (1 = opened with a paid Skip Map, one slot per level like `clears`) is missing in
-- saves from before it.
type Record = { best: { number }, clears: { number }, stage: number, gear: string, skipped: { number }? }

local function escape(s: string): string
	return (string.gsub(s, "[&<>]", { ["&"] = "&amp;", ["<"] = "&lt;", [">"] = "&gt;" }))
end

local function vec(t: { number }): Vector3
	return Vector3.new(t[1], t[2], t[3])
end

local function stageCount(): number
	return Course.STAGE_COUNT
end

local function setAttribute(player: Player, name: string, value: any)
	if player:GetAttribute(name) ~= value then
		player:SetAttribute(name, value)
	end
end

local function speedMultiplier(humanoid: any): number
	local mult = humanoid:GetAttribute("SpeedMultiplier")
	return if type(mult) == "number" then mult else 1
end

-- Was `level` opened with a paid Skip Map?
local function skippedIn(rec: Record, level: number): boolean
	local list = rec.skipped
	return type(list) == "table" and (tonumber(list[level]) or 0) > 0
end

-- Levels unlocked: 1 + consecutive cleared or skipped levels from level 1 (at most
-- LEVEL_COUNT).
local function unlockedOf(rec: Record): number
	local n = 1
	while n < Course.LEVEL_COUNT and ((rec.clears[n] or 0) > 0 or skippedIn(rec, n)) do
		n += 1
	end
	return n
end

-- The lowest level not cleared or skipped yet; with none left, the lowest level not cleared
-- (the last level once all are cleared).
local function defaultOf(rec: Record): number
	local uncleared: number? = nil
	for i = 1, Course.LEVEL_COUNT do
		if (rec.clears[i] or 0) == 0 then
			if not skippedIn(rec, i) then
				return i
			end
			uncleared = uncleared or i
		end
	end
	return uncleared or Course.LEVEL_COUNT
end

-- The stage a record has earned: one past the maps really cleared in a row from map 1 (a
-- skipped map stops the count).
local function earnedStage(rec: Record): number
	local n = 1
	while n <= Course.LEVEL_COUNT and (rec.clears[n] or 0) > 0 do
		n += 1
	end
	return n
end

-- Has every map been cleared without gear? (Only a clean finish sets a map's best time.)
local function allClean(rec: Record): boolean
	for i = 1, Course.LEVEL_COUNT do
		if (tonumber(rec.best[i]) or 0) <= 0 then
			return false
		end
	end
	return true
end

-- Every map's start and finish deck: where a player with no run may stand.
local DECKS: { Course.Element } = {}
for _, level in Course.LEVELS do
	table.insert(DECKS, level.PATH[1])
	table.insert(DECKS, level.PATH[#level.PATH])
end

-- Are feet at (x, y, z) on one of the DECKS (or hopping over it)?
local function onDeck(x: number, y: number, z: number): boolean
	for _, deck in DECKS do
		if y >= deck.y - DECK_UNDER and y <= deck.y + DECK_OVER and Course.footDistance(deck, x, z) <= DECK_EDGE then
			return true
		end
	end
	return false
end

-- The sky course volume: over any map's rectangle (SKY_MARGIN around it), from RESCUE_DEPTH
-- under the cloud floor up.
local function inSky(x: number, y: number, z: number): boolean
	if y < Course.FLOOR_Y - RESCUE_DEPTH then
		return false
	end
	for _, b in Course.REGIONS do
		if x >= b.x0 - SKY_MARGIN and x <= b.x1 + SKY_MARGIN and z >= b.z0 - SKY_MARGIN and z <= b.z1 + SKY_MARGIN then
			return true
		end
	end
	return false
end

function Parkour.create(GameModes: any, context: { built: any, theme: any, Tycoon: any })
	local theme = context.theme
	local Tycoon = context.Tycoon
	local runs: { [Player]: State } = {}
	local lastX: { [Player]: number } = {}
	-- Players with no run on the sky course: since when they stand off every deck, until
	-- when their position is not trusted (just teleported), and their latest timed return.
	local offDeckSince: { [Player]: number } = {}
	local settleUntil: { [Player]: number } = {}
	local returnTicket: { [Player]: number } = {}
	-- Players whose finish card is up (the client's "ModeCard" action).
	local cardOpen: { [Player]: boolean? } = {}
	-- When each map's run again bonus was last paid, by UserId (kept for the server's life,
	-- so leaving and joining again does not wake it).
	local repeatPaidAt: { [number]: { [number]: number } } = {}
	-- Server best times per level (in memory; see Rules.recordBest for the OrderedDataStore
	-- shape).
	local serverBest: { { Rules.BestEntry } } = {}
	for i = 1, Course.LEVEL_COUNT do
		serverBest[i] = {}
	end

	local function now(): number
		return workspace:GetServerTimeNow()
	end

	-- Shared cooldown + level 1 mirror (old UI).
	local function shared(session: any): { best: number, clears: number, lastRewardAt: number }
		return session.profile.modes.parkour
	end

	local function levels(session: any): Record
		return session.profile.parkour
	end

	-- Seconds until `level`'s run again bonus is paid again (0 = it is awake).
	local function repeatRest(session: any, level: number): number
		local paid = repeatPaidAt[session.player.UserId]
		local at = paid and paid[level]
		return if at then math.max(0, math.ceil(at + REPEAT_REST_SECONDS - now())) else 0
	end

	-- What finishing `level` pays now. Inside the cooldown only a `clean` run (no gear worn)
	-- earns the repeat share of the map's pack, and not while that map's bonus rests.
	local function rewardFor(session: any, level: number, clean: boolean): Economy.ModeReward
		local p = session.profile
		local pack = theme.Modes.Reward
		local progression = Economy.progression(Economy.highestTier(p.runDiscovered), p.processLevel)
		local first = (levels(session).clears[level] or 0) == 0
		local r =
			Economy.modeReward(Tycoon.income(session), progression, pack.Seconds, pack.Min, first, shared(session).lastRewardAt, os.time())
		local bonus = Economy.parkourLevelBonus(level)
		r.packCash = math.floor(r.packCash * bonus + 0.5)
		r.repeatCash = math.floor(r.packCash * Economy.MODE_REPEAT_SHARE)
		r.cash = if r.full then r.packCash elseif clean and repeatRest(session, level) <= 0 then r.repeatCash else 0
		return r
	end

	local function updateBoard()
		local label = context.built and context.built.bestList
		if not label then
			return
		end
		local lines = {}
		for i = 1, Course.LEVEL_COUNT do
			local top = serverBest[i][1]
			if top then
				table.insert(lines, string.format("MAP %d  %s  <b>%.2fs</b>", i, escape(top.name), top.time))
			else
				table.insert(lines, string.format("MAP %d  —", i))
			end
		end
		label.Text = table.concat(lines, "\n")
	end

	-- Puts the player on `level`'s start deck (start, falls, lava).
	local function teleportTo(player: Player, level: Course.Level)
		local at, look = Course.respawn(level)
		GameModes.teleport(player, vec(at), Vector3.new(look[1], 0, look[2]))
		lastX[player] = at[1]
	end

	-- The runner now stands on global `stage` (a map's start or finish deck): attributes +
	-- saved best. The saved best follows earnedStage, never the stage itself: the map after
	-- a skipped one is not progress on the STAGE board.
	local function reach(player: Player, session: any, stage: number)
		setAttribute(player, "ParkourStage", stage)
		local rec = levels(session)
		local earned = earnedStage(rec)
		if earned > rec.stage then
			rec.stage = earned
			Tycoon.markDirty(session)
		end
		setAttribute(player, "ParkourBestStage", rec.stage)
	end

	-- In front of the gates, off the sky course.
	local function backToGates(player: Player, t: number)
		offDeckSince[player] = nil
		settleUntil[player] = t + TELEPORT_GRACE
		GameModes.toGates(player)
		lastX[player] = nil
	end

	-- Nobody stays on the sky course without a run: below the cloud floor, or off every
	-- start / finish deck for STRANDED_SECONDS (a bridge, a map's path), back to the gates.
	local function rescue(player: Player, x: number, y: number, z: number, t: number)
		if t < (settleUntil[player] or 0) or not inSky(x, y, z) then
			offDeckSince[player] = nil
			return
		end
		if not Course.inWater(x, y, z) then
			if onDeck(x, y, z) then
				offDeckSince[player] = nil
				return
			end
			local since = offDeckSince[player] or t
			offDeckSince[player] = since
			if t - since < STRANDED_SECONDS then
				return
			end
		end
		backToGates(player, t)
		local session = GameModes.session(player)
		if session then
			Tycoon.toast(session, "Back to the gates", "info")
		end
	end

	-- Back to the gates after `seconds`, wherever the player then stands on the sky course
	-- (not if they went home, started a run, or a later return took over). While the finish
	-- card is up the return waits, CARD_HOLD_SECONDS at the most.
	local function returnFromSky(player: Player, seconds: number)
		local ticket = (returnTicket[player] or 0) + 1
		returnTicket[player] = ticket
		local holdUntil = now() + seconds + CARD_HOLD_SECONDS
		local function later(wait: number)
			GameModes.returnLater(player, wait, function(r: BasePart): boolean
				local at = r.Position
				if returnTicket[player] ~= ticket or not inSky(at.X, at.Y - FEET_BELOW_ROOT, at.Z) then
					return false
				end
				if cardOpen[player] and now() < holdUntil then
					later(CARD_POLL_SECONDS)
					return false
				end
				return true
			end)
		end
		later(seconds)
	end

	-- Gear -------------------------------------------------------------------------------

	local worn: { [Player]: Worn } = {}

	-- Takes the worn coil off and restores the defaults it changed.
	local function removeGear(player: Player)
		local w = worn[player]
		if not w then
			return
		end
		worn[player] = nil
		local humanoid = w.humanoid
		if w.gear == "speed" then
			local base = if type(w.base) == "number" then w.base else Course.WALK_SPEED
			humanoid:SetAttribute("BaseWalkSpeed", base)
			humanoid.WalkSpeed = base * speedMultiplier(humanoid)
		elseif w.gear == "jump" then
			if humanoid.UseJumpPower then
				humanoid.JumpPower = DEFAULT_JUMP_POWER
			else
				humanoid.JumpHeight = Course.JUMP_HEIGHT
			end
		elseif w.gear == "gravity" then
			for _, name in { COIL, COIL .. "Attachment" } do
				local part = w.root:FindFirstChild(name)
				if part then
					part:Destroy()
				end
			end
		end
	end

	-- Puts `gear` on the player's character (taking any other coil off first). True when a
	-- coil is now worn.
	local function wearGear(player: Player, gear: string): boolean
		removeGear(player)
		if gear == "none" or not GEARS[gear] then
			return false
		end
		local character = player.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid") :: any
		local root = GameModes.root(player) :: any
		if not humanoid or not root then
			return false
		end
		local w: Worn = { gear = gear, humanoid = humanoid, root = root, base = humanoid:GetAttribute("BaseWalkSpeed") }
		if gear == "speed" then
			-- Through BaseWalkSpeed so Cosmetics' speed boost still multiplies it.
			humanoid:SetAttribute("BaseWalkSpeed", GEAR_WALK_SPEED)
			humanoid.WalkSpeed = GEAR_WALK_SPEED * speedMultiplier(humanoid)
		elseif gear == "jump" then
			if humanoid.UseJumpPower then
				humanoid.JumpPower = GEAR_JUMP_POWER
			else
				humanoid.JumpHeight = GEAR_JUMP_HEIGHT
			end
		elseif gear == "gravity" then
			local attachment = Instance.new("Attachment")
			attachment.Name = COIL .. "Attachment"
			attachment.Parent = root
			local force = Instance.new("VectorForce")
			force.Name = COIL
			force.Attachment0 = attachment
			force.RelativeTo = Enum.ActuatorRelativeTo.World
			force.ApplyAtCenterOfMass = true
			force.Force = Vector3.new(0, GRAVITY_CANCEL * root.AssemblyMass * workspace.Gravity, 0)
			force.Parent = root
		end
		worn[player] = w
		return true
	end

	-- Wears the player's chosen gear for the run in `state` (marks the run assisted).
	local function equip(player: Player, session: any, state: State)
		local gear = levels(session).gear
		if wearGear(player, gear) then
			state.assisted = true
			state.speedUsed = state.speedUsed or gear == "speed"
		end
	end

	local def = {} :: any
	def.id = ID

	function def.running(player: Player): boolean
		return runs[player] ~= nil
	end

	function def.start(player: Player, teleport: boolean, options: { [string]: any }?): boolean
		local session = GameModes.session(player)
		if not session then
			return false
		end
		local rec = levels(session)
		local index = defaultOf(rec)
		local asked = options and options.level
		if type(asked) == "number" then
			if asked ~= asked or asked < 1 or asked > unlockedOf(rec) then
				return false
			end
			index = math.floor(asked)
		end
		local level = Course.level(index)
		local t = now()
		local state: State = {
			run = Rules.newRun(t, level),
			outsideSince = nil,
			graceUntil = t + TELEPORT_GRACE,
			assisted = false,
			speedUsed = false,
			falls = 0,
			progress = 0,
		}
		runs[player] = state
		setAttribute(player, "ParkourProgress", 0)
		if teleport or level.remote then
			teleportTo(player, level)
		end
		equip(player, session, state)
		local stage = level.STAGE_FIRST
		reach(player, session, stage)
		local best = rec.best[index] or 0
		GameModes.notify(player, "start", ID, {
			checkpoints = 0,
			startedAt = t,
			best = if best > 0 then best else nil,
			level = index,
			levelName = level.name,
			levels = Course.LEVEL_COUNT,
			remote = level.remote,
			stage = stage,
			stageCount = stageCount(),
			gear = rec.gear,
			assisted = state.assisted,
		})
		GameModes.refresh(player)
		return true
	end

	function def.stop(player: Player, reason: string)
		if not runs[player] then
			return
		end
		runs[player] = nil
		removeGear(player)
		if reason ~= "leave" then
			setAttribute(player, "ParkourStage", 0)
			setAttribute(player, "ParkourProgress", 0)
			settleUntil[player] = now() + TELEPORT_GRACE
		end
		if reason ~= "leave" then
			GameModes.notify(player, "stop", ID, { reason = reason })
			GameModes.refresh(player)
		end
	end

	local function finish(player: Player, state: State, root: BasePart, t: number)
		runs[player] = nil
		removeGear(player)
		setAttribute(player, "ParkourStage", 0)
		setAttribute(player, "ParkourProgress", 0)
		local session = GameModes.session(player)
		if not session then
			return
		end
		local speedScale = if state.speedUsed then GEAR_WALK_SPEED / Course.WALK_SPEED else 1
		local ok, result = Rules.finish(state.run, t, speedScale)
		if not ok then
			GameModes.notify(player, "invalid", ID, { reason = result })
			GameModes.refresh(player)
			if state.run.level.remote then
				GameModes.returnLater(player, 4, nil)
			end
			return
		end
		local level = state.run.level
		local index = level.index
		local time = Rules.roundTime(result :: number)
		local rec = levels(session)
		local cooldown = shared(session)
		local first = rec.clears[index] == 0
		local unlockedBefore = unlockedOf(rec)
		local assisted = state.assisted
		local cleanBefore = allClean(rec)
		-- Inside the cooldown, a clean run while this map's bonus rests: it pays nothing.
		local rest = repeatRest(session, index)
		local reward = GameModes.hooks.reward(session, ID, rewardFor(session, index, not assisted))
		local pay = if first
			then "first"
			elseif reward.full then "full"
			elseif assisted then "assisted"
			elseif rest > 0 then "resting"
			else "repeat"
		rec.clears[index] += 1
		if reward.full then
			cooldown.lastRewardAt = os.time()
		elseif pay == "repeat" then
			local paid = repeatPaidAt[player.UserId] or {}
			repeatPaidAt[player.UserId] = paid
			paid[index] = now()
		end
		-- A new finish, a new card: a card the client never closed holds nothing.
		cardOpen[player] = nil
		local newBest = not assisted and (rec.best[index] <= 0 or time < rec.best[index])
		if newBest then
			rec.best[index] = time
		end
		if index == 1 then
			cooldown.best, cooldown.clears = rec.best[1], rec.clears[1]
		end
		local unlocked = unlockedOf(rec)
		local rank = nil
		if not assisted then
			rank = Rules.recordBest(serverBest[index], player.UserId, player.DisplayName, time, BEST_SIZE)
			updateBoard()
		end
		local stage = level.STAGE_LAST
		reach(player, session, stage)
		setAttribute(player, "ParkourStage", 0)

		local p = session.profile
		if reward.cash > 0 then
			p.money += reward.cash
			p.totalEarned += reward.cash
			GameModes.effect(player, "Cash", { amount = reward.cash, source = "Mode", padPos = root.Position })
		end
		GameModes.effect(player, "ModeFinish", { pos = root.Position, newBest = newBest })
		GameModes.notify(player, "finish", ID, {
			time = time,
			best = rec.best[index],
			newBest = newBest,
			first = first,
			cash = reward.cash,
			full = reward.full,
			cooldownEnds = cooldown.lastRewardAt + Economy.MODE_REWARD_COOLDOWN,
			rank = rank,
			level = index,
			levelName = level.name,
			nextLevel = if index < Course.LEVEL_COUNT then index + 1 else nil,
			unlockedNew = unlocked > unlockedBefore,
			unlocked = unlocked,
			levels = Course.LEVEL_COUNT,
			stage = stage,
			stageCount = stageCount(),
			assisted = assisted,
			falls = state.falls,
			-- For the finish card: why `cash` is what it is, and both of this map's prices.
			pay = pay,
			packCash = reward.packCash,
			repeatCash = reward.repeatCash,
			repeatShare = Economy.MODE_REPEAT_SHARE,
			-- Seconds until this map's run again bonus is awake again (0 = it is).
			repeatRest = repeatRest(session, index),
			-- This run made it all ten maps cleared without gear, for the first time.
			complete = not cleanBefore and allClean(rec),
		})
		GameModes.hooks.rewarded(session, ID, reward)
		Tycoon.markDirty(session)
		GameModes.refresh(player)
		if level.remote then
			returnFromSky(player, RETURN_SECONDS)
		end
	end

	function def.tick(player: Player, root: BasePart, t: number)
		local pos = root.Position
		local x, y, z = pos.X, pos.Y - FEET_BELOW_ROOT, pos.Z
		local prevX = lastX[player]
		lastX[player] = x
		local state = runs[player]
		if prevX and Course.crossedStart(prevX, x, z) and y < Course.PLAZA.top + 8 then
			local session = GameModes.session(player)
			if session then
				GameModes.notify(player, "pick", ID, { level = defaultOf(levels(session)) })
			end
			return
		end
		if not state then
			rescue(player, x, y, z, t)
			return
		end
		offDeckSince[player] = nil
		if t < state.graceUntil then
			return
		end
		local level = state.run.level
		-- Back to the start deck of this map (no checkpoints); the run goes on.
		local function backToStart(reason: string?)
			state.graceUntil = t + TELEPORT_GRACE
			state.outsideSince = nil
			state.falls += 1
			state.progress = 0
			setAttribute(player, "ParkourProgress", 0)
			teleportTo(player, level)
			GameModes.notify(player, "respawn", ID, {
				index = 0,
				stage = level.STAGE_FIRST,
				stageCount = stageCount(),
				reason = reason,
				falls = state.falls,
			})
		end
		if Course.inWater(x, y, z) then
			GameModes.effect(player, "ModeSplash", { pos = Vector3.new(x, level.WATER_BOX.y0 + 1.2, z) })
			backToStart(nil)
			return
		end
		if Course.inBounds(level, x, y, z) then
			state.outsideSince = nil
			if Course.inKill(level, x, y, z, t) then
				GameModes.effect(player, "ModeKill", { pos = pos })
				backToStart("kill")
				return
			end
		else
			state.outsideSince = state.outsideSince or t
			if t - (state.outsideSince :: number) >= Course.LEAVE_SECONDS then
				def.stop(player, "left")
				if level.remote then
					GameModes.toGates(player)
				end
			end
			return
		end
		if Course.inFinish(level, x, y, z) then
			finish(player, state, root, t)
			return
		end
		-- Where the runner is along the map, for the HUD bar (hundredths: a handful of
		-- attribute changes per second at most).
		local progress = math.floor(Course.progress(level, x, z) * 100 + 0.5) / 100
		if progress ~= state.progress then
			state.progress = progress
			setAttribute(player, "ParkourProgress", progress)
		end
	end

	-- Reward preview for `level` (default: the player's default level). `cash` is what a
	-- finish would pay now: inside the cooldown that is the repeat share (`repeatCash`,
	-- `repeatShare` of `packCash`) unless gear is worn (this run's, or the chosen coil).
	function def.rewardPreview(player: Player, level: number?): { [string]: any }
		local session = GameModes.session(player)
		if not session then
			return { cash = 0, full = false, packCash = 0, repeatCash = 0, repeatShare = Economy.MODE_REPEAT_SHARE, repeatRest = 0 }
		end
		local rec = levels(session)
		local state = runs[player]
		local clean = if state then not state.assisted else rec.gear == "none"
		local index = level or defaultOf(rec)
		local r = rewardFor(session, index, clean)
		return {
			cash = r.cash,
			full = r.full,
			packCash = r.packCash,
			repeatCash = r.repeatCash,
			repeatShare = Economy.MODE_REPEAT_SHARE,
			-- Seconds this map's run again bonus still rests (0 = awake).
			repeatRest = if r.full then 0 else repeatRest(session, index),
		}
	end

	function def.snapshot(player: Player): { [string]: any }
		local session = GameModes.session(player)
		local state = runs[player]
		local rec = session and levels(session)
		local cooldown = session and shared(session)
		local default = if rec then defaultOf(rec) else 1
		local current = if state then state.run.level else Course.level(default)
		local list = {}
		for i, level in Course.LEVELS do
			list[i] = {
				name = level.name,
				difficulty = level.difficulty,
				best = if rec then rec.best[i] else 0,
				clears = if rec then rec.clears[i] else 0,
				checkpoints = 0,
				bonus = Economy.parkourLevelBonus(i),
				-- Map look (Course.MAPS); read defensively so older Course data still works.
				theme = (level :: any).theme,
				blurb = (level :: any).blurb,
				icon = (level :: any).icon,
				accent = (level :: any).accent,
			}
		end
		local best = if rec then rec.best[default] else 0
		local stage = if state then current.STAGE_FIRST else 0
		-- Snapshots go out on join too: keep the HUD bar's attributes current.
		setAttribute(player, "ParkourStage", stage)
		if rec then
			setAttribute(player, "ParkourBestStage", rec.stage)
		end
		return {
			best = if best > 0 then best else nil,
			clears = if rec then rec.clears[default] else 0,
			running = state ~= nil,
			checkpoint = 0,
			checkpoints = 0,
			startedAt = if state then state.run.startedAt else nil,
			cooldownEnds = if cooldown and cooldown.lastRewardAt > 0 then cooldown.lastRewardAt + Economy.MODE_REWARD_COOLDOWN else 0,
			rewardPreview = def.rewardPreview(player, current.index),
			level = current.index,
			unlocked = if rec then unlockedOf(rec) else 1,
			levelCount = Course.LEVEL_COUNT,
			levels = list,
			gear = if rec then rec.gear else "none",
			stage = stage,
			bestStage = if rec then rec.stage else 0,
			stageCount = stageCount(),
			assisted = if state then state.assisted else false,
			-- This run so far (the live position is the "ParkourProgress" attribute).
			progress = if state then state.progress else 0,
			falls = if state then state.falls else 0,
			skipCost = if session then Economy.parkourSkipCost(Tycoon.income(session)) else Economy.PARKOUR_SKIP_MIN,
		}
	end

	-- Actions ------------------------------------------------------------------------------

	-- The finish card opened or closed (Client.UI.Popups.modeFinish): returnFromSky waits
	-- while it is up.
	Tycoon.addAction("ModeCard", function(session: any, data: { [string]: any })
		if data.mode == ID then
			cardOpen[session.player] = if data.open == true then true else nil
		end
	end)

	Tycoon.addAction("ParkourGear", function(session: any, data: { [string]: any })
		local gear = data.gear
		if type(gear) ~= "string" or not GEARS[gear] then
			return
		end
		local player = session.player
		levels(session).gear = gear
		Tycoon.markDirty(session)
		local state = runs[player]
		if state then
			equip(player, session, state)
		end
		GameModes.refresh(player)
	end)

	Tycoon.addAction("ParkourSkip", function(session: any)
		local player = session.player
		local state = runs[player]
		if not state or not GameModes.root(player) then
			return
		end
		local level = state.run.level
		local index = level.index
		local rec = levels(session)
		-- A skip only unlocks the next map: with nothing to unlock it is refused, not charged.
		if index >= Course.LEVEL_COUNT then
			Tycoon.toast(session, "This is the last map: there is no map to skip to", "info")
			return
		end
		if unlockedOf(rec) > index then
			Tycoon.toast(session, string.format("Map %d is already unlocked", index + 1), "info")
			return
		end
		local p = session.profile
		local cost = Economy.parkourSkipCost(Tycoon.income(session))
		if p.money < cost then
			Tycoon.toast(session, "Not enough cash! Skip costs " .. Format.money(cost), "bad")
			return
		end
		p.money -= cost
		-- Skip Map: the next map unlocks and nothing else. No finish: no reward, no clear, no
		-- best, no stage and no board entry (the real first clear still pays later).
		local skipped = {}
		for i = 1, Course.LEVEL_COUNT do
			skipped[i] = if skippedIn(rec, i) then 1 else 0
		end
		skipped[index] = 1
		rec.skipped = skipped
		Tycoon.markDirty(session)
		GameModes.notify(player, "skip", ID, {
			stage = level.STAGE_FIRST,
			stageCount = stageCount(),
			index = 0,
			checkpoints = 0,
			level = index,
			paid = 0,
			nextLevel = index + 1,
			unlocked = unlockedOf(rec),
		})
		-- The run is over: back to the gates with the Maps window on the next map, which
		-- starts only when the player presses play (no card over a running clock).
		def.stop(player, "skip")
		backToGates(player, now())
		Tycoon.toast(session, string.format("Map %d skipped. Map %d is unlocked!", index, index + 1), "good")
		GameModes.notify(player, "pick", ID, { level = index + 1 })
	end)

	game:GetService("Players").PlayerRemoving:Connect(function(player)
		runs[player] = nil
		lastX[player] = nil
		offDeckSince[player] = nil
		settleUntil[player] = nil
		returnTicket[player] = nil
		cardOpen[player] = nil
		removeGear(player)
	end)
	updateBoard()
	return def
end

return Parkour
