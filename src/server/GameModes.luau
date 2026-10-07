--[[
	GameModes: the registry of plaza game modes and their shared plumbing.

	A mode is a catalog entry (Modes.Catalog: id, title, blurb, gate slot, enabled) plus an
	implementation registered here (see Modes.Parkour):

	  start(player, teleport, options)
	                           begin a run (teleport = move the player to the mode's start;
	                           options = the "ModeStart" action's data table, or nil);
	                           returns false when refused
	  stop(player, reason)     end the player's run: "quit" | "left" | "respawn" | "leave" |
	                           "switch" | "invalid"
	  running(player)          is the player in a run of this mode?
	  tick(player, root, now)  every TICK seconds for every player with a character
	                           (position polling: start lines, checkpoints, falls)
	  snapshot(player)         the State snapshot's modes[id] table
	  rewardPreview(player)    what finishing right now would pay ({ cash, full, ... })

	Every implementation's create() receives (GameModes, context) with context = { built =
	World.Modes' Built, theme, Tycoon, world = WorldBuilder's whole result }.

	GameModes keeps which mode each player is in, stops runs on leave / respawn, provides the
	teleports (mode start, plaza, own plot) and the Notify / Effect helpers, and adds the
	actions "ModeStart" { mode }, "ModeQuit" and "GoModes".

	Notify payloads all have kind = "Mode", `event` and `mode` (see Modes.Parkour for each
	event's fields). Effects are fired on the "Effect" remote as (kind, data).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Net = require(ReplicatedStorage.Shared.Net)

local Catalog = require(script.Parent.Modes.Catalog)
local Course = require(script.Parent.Modes.Course)

local GameModes = {}

export type ModeDef = {
	id: string,
	title: string,
	blurb: string,
	slot: number,
	enabled: boolean,
	start: (player: Player, teleport: boolean, options: { [string]: any }?) -> boolean,
	stop: (player: Player, reason: string) -> (),
	running: (player: Player) -> boolean,
	tick: (player: Player, root: BasePart, now: number) -> (),
	snapshot: (player: Player) -> { [string]: any },
	rewardPreview: (player: Player) -> { [string]: any },
}

-- Implementations of the built-in modes, by catalog id. Each module returns
-- { create = function(GameModes, context) -> ModeDef }.
local BUILTIN = {
	parkour = script.Parent.Modes.Parkour,
	mog = script.Parent.Modes.Mog,
}

local TICK = 0.1

local modes: { [string]: ModeDef } = {}
local order: { string } = {}
local Tycoon: any

-- Reward hooks: `reward` may change a reward before it is paid (events, boosts);
-- `rewarded` is told after it was paid. reward = { cash, full, packCash }.
GameModes.hooks = {
	reward = function(_session: any, _modeId: string, reward: { [string]: any }): { [string]: any }
		return reward
	end,
	rewarded = function(_session: any, _modeId: string, _reward: { [string]: any }) end,
}

local function catalogEntry(id: string): Catalog.Entry?
	for _, entry in Catalog do
		if entry.id == id then
			return entry
		end
	end
	return nil
end

-- Registers a mode implementation; title, blurb, slot and enabled come from the catalog.
function GameModes.register(def: ModeDef)
	local entry = catalogEntry(def.id)
	assert(entry, "unknown game mode " .. tostring(def.id))
	def.title = entry.title
	def.blurb = entry.blurb
	def.slot = entry.slot
	def.enabled = entry.enabled
	if not modes[def.id] then
		table.insert(order, def.id)
	end
	modes[def.id] = def
end

function GameModes.get(id: string): ModeDef?
	return modes[id]
end

function GameModes.list(): { ModeDef }
	local out = {}
	for _, id in order do
		table.insert(out, modes[id])
	end
	return out
end

-- The mode the player is running right now, if any.
function GameModes.active(player: Player): ModeDef?
	for _, id in order do
		local def = modes[id]
		if def.running(player) then
			return def
		end
	end
	return nil
end

function GameModes.start(player: Player, id: string, teleport: boolean, options: { [string]: any }?): boolean
	local def = modes[id]
	if not def or not def.enabled then
		return false
	end
	local current = GameModes.active(player)
	if current and current ~= def then
		current.stop(player, "switch")
	end
	local ok = def.start(player, teleport, options)
	if not ok and current then
		-- The old run is over and the new one was refused: never leave the player standing
		-- on a far arena with no run.
		GameModes.toGates(player)
	end
	return ok
end

function GameModes.stop(player: Player, reason: string)
	local current = GameModes.active(player)
	if current then
		current.stop(player, reason)
	end
end

-- Helpers for mode implementations ---------------------------------------------------------

function GameModes.session(player: Player): any
	return Tycoon and Tycoon.getSession(player)
end

function GameModes.notify(player: Player, event: string, modeId: string, data: { [string]: any }?)
	local session = GameModes.session(player)
	if not session then
		return
	end
	local payload: { [string]: any } = { kind = "Mode", event = event, mode = modeId }
	if data then
		for key, value in data do
			payload[key] = value
		end
	end
	Tycoon.notify(session, payload)
end

function GameModes.effect(player: Player, kind: string, data: { [string]: any })
	Net.event("Effect"):FireClient(player, kind, data)
end

-- Pushes a fresh State snapshot to the player.
function GameModes.refresh(player: Player)
	if Tycoon then
		Tycoon.refresh(player)
	end
end

function GameModes.root(player: Player): BasePart?
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	return if root and root:IsA("BasePart") then root else nil
end

-- Moves the player's character so its feet stand at `feet`, facing `look` (horizontal).
function GameModes.teleport(player: Player, feet: Vector3, look: Vector3)
	local character = player.Character
	local root = GameModes.root(player)
	if not character or not root then
		return
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local hip = if humanoid then humanoid.HipHeight else 2
	local pos = feet + Vector3.new(0, hip + root.Size.Y / 2 + 0.2, 0)
	character:PivotTo(CFrame.lookAt(pos, pos + Vector3.new(look.X, 0, look.Z)))
	root.AssemblyLinearVelocity = Vector3.zero
end

local function spot(s: { x: number, y: number, z: number }): Vector3
	return Vector3.new(s.x, s.y, s.z)
end

-- The plaza's arrival point (end of the spur), facing the gates.
function GameModes.toPlaza(player: Player)
	GameModes.teleport(player, spot(Course.ARRIVAL), Vector3.new(-1, 0, 0))
end

-- In front of the gates, facing back toward the hub (after quitting a run).
function GameModes.toGates(player: Player)
	GameModes.teleport(player, spot(Course.QUIT), Vector3.new(1, 0, 0))
end

-- Brings a player back from a teleport-only arena (a far Parkour level, the Mog stage):
-- after `seconds`, unless they started another run or `stillThere` says they already left,
-- they stand in front of the gates again.
function GameModes.returnLater(player: Player, seconds: number, stillThere: ((root: BasePart) -> boolean)?)
	task.delay(seconds, function()
		local root = GameModes.root(player)
		if not root or GameModes.active(player) then
			return
		end
		if stillThere and not stillThere(root) then
			return
		end
		GameModes.toGates(player)
	end)
end

-- The State snapshot's `modes` table: modes[id] for every registered mode.
function GameModes.snapshot(player: Player): { [string]: any }
	local out = {}
	for _, id in order do
		out[id] = modes[id].snapshot(player)
	end
	return out
end

-- Setup --------------------------------------------------------------------------------------

local function watchPlayer(player: Player)
	player.CharacterAdded:Connect(function()
		GameModes.stop(player, "respawn")
	end)
end

function GameModes.init(built: any, theme: any, tycoon: any, world: any)
	Tycoon = tycoon
	for id, module in BUILTIN do
		local impl = (require :: any)(module)
		GameModes.register(impl.create(GameModes, { built = built, theme = theme, Tycoon = tycoon, world = world }))
		assert(modes[id], "mode " .. id .. " did not register")
	end

	Tycoon.hooks.modes = function(session: any)
		return GameModes.snapshot(session.player)
	end
	-- "Home" during a run ends it first (un-anchors a Mog player, no "left" stop later).
	Tycoon.hooks.leavingForHome = function(session: any)
		GameModes.stop(session.player, "quit")
	end

	Tycoon.addAction("ModeStart", function(session, data)
		if type(data.mode) == "string" then
			GameModes.start(session.player, data.mode, true, data)
		end
	end)
	Tycoon.addAction("ModeQuit", function(session)
		if GameModes.active(session.player) then
			GameModes.stop(session.player, "quit")
			GameModes.toGates(session.player)
		end
	end)
	Tycoon.addAction("GoModes", function(session)
		GameModes.stop(session.player, "quit")
		GameModes.toPlaza(session.player)
	end)

	Players.PlayerAdded:Connect(watchPlayer)
	for _, player in Players:GetPlayers() do
		watchPlayer(player)
	end
	Players.PlayerRemoving:Connect(function(player)
		GameModes.stop(player, "leave")
	end)

	task.spawn(function()
		while true do
			task.wait(TICK)
			local now = Workspace:GetServerTimeNow()
			for _, player in Players:GetPlayers() do
				local root = GameModes.root(player)
				if root and Tycoon.getSession(player) then
					for _, id in order do
						local ok, err = pcall(modes[id].tick, player, root, now)
						if not ok then
							warn("[GameModes] tick:", err)
						end
					end
				end
			end
		end
	end)
end

return GameModes
