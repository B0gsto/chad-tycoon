--[[
	TestBridge: lets AI agents drive a real Roblox TEST server (docs/agent-playtest.md).

	Completely inert unless Shared.TestEnv.isTest() (the TEST universe only: never the live
	game, never an unpublished Studio place). Then:

	  * subscribes to the MessagingService topic "TestBridge". tools/roblox_play.py publishes
	    JSON { id, cmd, args, userId? } through Open Cloud; every server gets it, only the one
	    with the target player (userId, default the owner) acts on it;
	  * runs `cmd` from the fixed COMMANDS table below (no loadstring, no free-form code);
	  * writes { ok, result | error, cmd, jobId, placeVersion, at } to the MemoryStore sorted
	    map "TestBridge" under key `id` (expires after an hour), where the tool polls it;
	  * creates ReplicatedStorage.TestBridgeClient (RemoteEvent) for Client.TestBridge, which
	    does the client-only work: panels, camera presets, hiding the UI.
]]

local HttpService = game:GetService("HttpService")
local MemoryStoreService = game:GetService("MemoryStoreService")
local MessagingService = game:GetService("MessagingService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local TestEnv = require(ReplicatedStorage.Shared.TestEnv)

local Server = script.Parent
local Tycoon = require(Server.Tycoon)
local GameModes = require(Server.GameModes)
local Catalog = require(Server.Modes.Catalog)
local Course = require(Server.Modes.Course)
local CardioLayout = require(Server.Modes.CardioLayout)
local MogLayout = require(Server.Modes.MogLayout)

local TOPIC = "TestBridge"
local MAP = "TestBridge"
local RESULT_TTL = 3600
local OWNER_USER_ID = 11718681576
local MAX_GIVE = 1e15

local TestBridge = {}

type Args = { [string]: any }
type Command = { help: string, run: (player: Player, args: Args) -> any }

local world: any = nil
local clientRemote: RemoteEvent? = nil

-- Spots ------------------------------------------------------------------------------------

type Spot = { feet: Vector3, look: Vector3 }

local function fromCFrame(cf: CFrame): Spot
	return { feet = cf.Position, look = cf.LookVector }
end

local function fromPoint(p: { x: number, y: number, z: number }, look: Vector3?): Spot
	return { feet = Vector3.new(p.x, p.y, p.z), look = look or Vector3.new(0, 0, -1) }
end

-- Named teleport spots: name -> (player) -> Spot? (computed when used: the plot is per player).
local SPOTS: { [string]: { help: string, at: (Player) -> Spot? } } = {
	hub = {
		help = "the hub spawn mat in front of the statue",
		at = function()
			local mat = Workspace:FindFirstChild("HubSpawn", true)
			return if mat and mat:IsA("BasePart") then fromCFrame(mat.CFrame + Vector3.new(0, mat.Size.Y / 2, 0)) else nil
		end,
	},
	plot = {
		help = "the player's own plot spawn",
		at = function(player)
			local session = Tycoon.getSession(player)
			return if session then fromCFrame(session.plot.spawn) else nil
		end,
	},
	plaza = {
		help = "GAME MODES plaza arrival (end of the spur), facing the gates",
		at = function()
			return fromPoint(Course.ARRIVAL, Vector3.new(-1, 0, 0))
		end,
	},
	gates = {
		help = "in front of the mini-game gates, facing the hub",
		at = function()
			return fromPoint(Course.QUIT, Vector3.new(1, 0, 0))
		end,
	},
	mog = {
		help = "MOG TEST stage centre (no run started)",
		at = function()
			local c = MogLayout.CENTER
			return fromPoint({ x = c.x, y = c.y + MogLayout.THICKNESS + 1, z = c.z + MogLayout.DUEL })
		end,
	},
	cardio = {
		help = "CARDIO warm-up lobby (no run started)",
		at = function()
			local p = CardioLayout.spawn(0)
			return if p then fromPoint(p, Vector3.new(1, 0, 0)) else nil
		end,
	},
}
for _, id in { "shake", "pose", "bowling" } do
	SPOTS[id] = {
		help = string.upper(id) .. " island lobby (no run started; use `mode` to enter properly)",
		at = function()
			local built = world and world[id]
			local cf = built and (built.lobbySpawn or built.spawn)
			return if typeof(cf) == "CFrame" then fromCFrame(cf) else nil
		end,
	}
end

local function spotNames(): { string }
	local names = {}
	for name in SPOTS do
		table.insert(names, name)
	end
	table.sort(names)
	return names
end

-- Panels the client can open (Client.TestBridge passes them to the client's UiPreview hook).
local PANELS = {
	"Shop",
	"Index",
	"Ranking",
	"Settings",
	"Modes",
	"Maps",
	"Daily",
	"Shop,Passes",
	"Shop,Cosmetics",
	"Shop,Cash",
	"Shop,Aura",
	"starter",
	"gift",
	"surge",
	"away",
	"tutorialdone",
	"reward,<tier>",
	"rewards,<from>,<to>",
	"crate,<Rarity>,<tier>",
	"close",
}

local CAMERA_PRESETS = { "reset", "front", "back", "overhead", "plot", "spot:<name>", "cframe (args.pos + args.look)" }

-- Helpers ----------------------------------------------------------------------------------

local function vec(v: any): Vector3?
	if type(v) == "table" and type(v[1]) == "number" and type(v[2]) == "number" and type(v[3]) == "number" then
		return Vector3.new(v[1], v[2], v[3])
	end
	return nil
end

local function v3(v: Vector3): { number }
	return { math.round(v.X * 10) / 10, math.round(v.Y * 10) / 10, math.round(v.Z * 10) / 10 }
end

local function rootPos(player: Player): Vector3?
	local root = GameModes.root(player)
	return if root then root.Position else nil
end

local function toClient(player: Player, payload: { [string]: any })
	assert(clientRemote, "bridge remote missing")
	clientRemote:FireClient(player, payload)
end

-- A JSON-safe summary of the profile: every scalar field, and tables as their length.
local function profileSummary(profile: { [string]: any }): { [string]: any }
	local out = {}
	for key, value in profile do
		local t = type(value)
		if t == "number" or t == "boolean" or t == "string" then
			out[key] = value
		elseif t == "table" then
			local n = 0
			for _ in value do
				n += 1
			end
			out[key .. "#"] = n
		end
	end
	return out
end

-- Plot framing for the "plot" camera preset: behind and above the plot's spawn, looking in.
local function plotCamera(player: Player): (Vector3?, Vector3?)
	local session = Tycoon.getSession(player)
	if not session then
		return nil, nil
	end
	local spawn = session.plot.spawn
	local look = Vector3.new(spawn.LookVector.X, 0, spawn.LookVector.Z).Unit
	local pos = spawn.Position - look * 34 + Vector3.new(0, 48, 0)
	return pos, spawn.Position + look * 36
end

-- Commands ---------------------------------------------------------------------------------

local COMMANDS: { [string]: Command } = {}

COMMANDS.ping = {
	help = "server and player info: jobId, placeVersion, players",
	run = function(player)
		local list = {}
		for _, p in Players:GetPlayers() do
			table.insert(list, { userId = p.UserId, name = p.Name, loaded = Tycoon.getSession(p) ~= nil })
		end
		return { userId = player.UserId, name = player.Name, players = list, loaded = Tycoon.getSession(player) ~= nil }
	end,
}

COMMANDS.state = {
	help = "the player's cash, progress (profile scalars), plot, passes, mode and position",
	run = function(player)
		local session = Tycoon.getSession(player)
		if not session then
			error("player has no tycoon session yet (still loading?)")
		end
		local mode = GameModes.active(player)
		local pos = rootPos(player)
		return {
			cash = session.profile.money,
			income = Tycoon.income(session),
			production = Tycoon.production(session),
			plot = session.plot.index,
			passes = session.passes,
			premium = session.premium,
			canSave = session.canSave,
			mode = if mode then mode.id else nil,
			position = if pos then v3(pos) else nil,
			profile = profileSummary(session.profile :: any),
		}
	end,
}

COMMANDS.cash = {
	help = "args {amount}: add cash through Tycoon.grantMoney (the game's own path); returns the new total",
	run = function(player, args)
		local session = Tycoon.getSession(player)
		if not session then
			error("player has no tycoon session yet")
		end
		local amount = tonumber(args.amount)
		if not amount or amount ~= amount or amount <= 0 or amount > MAX_GIVE then
			error("amount must be a number in (0, 1e15]")
		end
		Tycoon.grantMoney(session, amount, "Test")
		return { cash = session.profile.money, added = amount }
	end,
}
COMMANDS.give = { help = "alias of cash", run = COMMANDS.cash.run }

COMMANDS.teleport = {
	help = "args {spot} (see list) or {pos:[x,y,z], look?:[x,y,z]}: move the character's feet there",
	run = function(player, args)
		local spot: Spot? = nil
		local p = vec(args.pos)
		if p then
			spot = { feet = p, look = vec(args.look) or Vector3.new(0, 0, -1) }
		else
			local def = SPOTS[tostring(args.spot)]
			if not def then
				error("unknown spot " .. tostring(args.spot) .. "; spots: " .. table.concat(spotNames(), ", "))
			end
			spot = def.at(player)
		end
		if not spot then
			error("spot not available in this world")
		end
		if not GameModes.root(player) then
			error("player has no character")
		end
		if args.stopMode ~= false and GameModes.active(player) then
			GameModes.stop(player, "quit")
		end
		GameModes.teleport(player, spot.feet, spot.look)
		return { position = v3(spot.feet) }
	end,
}

COMMANDS.mode = {
	help = "args {id, options?}: enter a mini-game the way its gate does (GameModes.start with teleport)",
	run = function(player, args)
		local id = tostring(args.id)
		if not GameModes.get(id) then
			local ids = {}
			for _, entry in Catalog do
				table.insert(ids, entry.id)
			end
			error("unknown mode " .. id .. "; modes: " .. table.concat(ids, ", "))
		end
		local ok = GameModes.start(player, id, true, if type(args.options) == "table" then args.options else nil)
		return { started = ok }
	end,
}

COMMANDS.stopmode = {
	help = "quit the current mini-game run (as the QUIT button)",
	run = function(player)
		GameModes.stop(player, "quit")
		return { mode = nil }
	end,
}

COMMANDS.ui = {
	help = 'args {panel}: open a panel/popup on the client (see list.panels; "close" closes all)',
	run = function(player, args)
		local panel = args.panel or args.name
		if type(panel) ~= "string" or panel == "" then
			error("args.panel required; panels: " .. table.concat(PANELS, ", "))
		end
		toClient(player, { cmd = "ui", panel = panel })
		return { panel = panel }
	end,
}

COMMANDS.camera = {
	help = "args {preset} (reset|front|back|overhead|plot|spot:<name>) or {pos:[x,y,z], look:[x,y,z], fov?}",
	run = function(player, args)
		local preset = if type(args.preset) == "string" then args.preset else nil
		local pos, look = vec(args.pos), vec(args.look)
		if preset == "plot" then
			pos, look = plotCamera(player)
			if not pos then
				error("no plot yet")
			end
			preset = nil
		elseif preset and string.sub(preset, 1, 5) == "spot:" then
			local def = SPOTS[string.sub(preset, 6)]
			local spot = def and def.at(player)
			if not spot then
				error("unknown spot in " .. preset)
			end
			local flat = Vector3.new(spot.look.X, 0, spot.look.Z)
			flat = if flat.Magnitude > 0.01 then flat.Unit else Vector3.new(0, 0, -1)
			pos = spot.feet - flat * 28 + Vector3.new(0, 22, 0)
			look = spot.feet + flat * 20
			preset = nil
		end
		if not preset and not (pos and look) then
			error("camera needs a preset or pos + look")
		end
		toClient(player, {
			cmd = "camera",
			preset = preset,
			pos = pos,
			look = look,
			fov = tonumber(args.fov),
			distance = tonumber(args.distance),
		})
		return { preset = preset or "cframe", pos = if pos then v3(pos) else nil, look = if look then v3(look) else nil }
	end,
}

COMMANDS.hideui = {
	help = "args {hidden?: bool} (default: toggle): hide every ScreenGui and the core UI for clean shots",
	run = function(player, args)
		toClient(player, { cmd = "hideui", hidden = if type(args.hidden) == "boolean" then args.hidden else nil })
		return { hidden = args.hidden }
	end,
}

COMMANDS.list = {
	help = "available commands, teleport spots, panels and camera presets",
	run = function()
		local cmds = {}
		for name, def in COMMANDS do
			cmds[name] = def.help
		end
		local spots = {}
		for name, def in SPOTS do
			spots[name] = def.help
		end
		local modes = {}
		for _, entry in Catalog do
			table.insert(modes, entry.id)
		end
		return { commands = cmds, spots = spots, modes = modes, panels = PANELS, camera = CAMERA_PRESETS }
	end,
}

-- Plumbing ---------------------------------------------------------------------------------

local resultMap: MemoryStoreSortedMap? = nil

local function writeResult(id: string, result: { [string]: any })
	result.jobId = game.JobId
	result.placeVersion = game.PlaceVersion
	result.at = os.time()
	local ok, err = pcall(function()
		assert(resultMap, "result map missing"):SetAsync(id, HttpService:JSONEncode(result), RESULT_TTL)
	end)
	if not ok then
		warn("[TestBridge] result write failed: " .. tostring(err))
	end
end

local function handle(raw: any)
	local okDecode, msg = pcall(HttpService.JSONDecode, HttpService, raw)
	if not okDecode or type(msg) ~= "table" then
		return
	end
	local id = msg.id
	if type(id) ~= "string" or not string.match(id, "^[%w%-_]+$") or #id > 64 then
		return
	end
	local userId = tonumber(msg.userId) or OWNER_USER_ID
	local player = Players:GetPlayerByUserId(userId)
	if not player then
		return -- another server's player (or nobody's): stay silent
	end
	local cmd = COMMANDS[tostring(msg.cmd)]
	if not cmd then
		writeResult(id, { ok = false, cmd = msg.cmd, error = "unknown command; try `list`" })
		return
	end
	local args = if type(msg.args) == "table" then msg.args else {}
	local ok, result = pcall(cmd.run, player, args)
	if ok then
		writeResult(id, { ok = true, cmd = msg.cmd, result = result })
	else
		writeResult(id, { ok = false, cmd = msg.cmd, error = tostring(result) })
	end
end

function TestBridge.init(builtWorld: any)
	if not TestEnv.isTest() then
		return
	end
	world = builtWorld
	local remote = Instance.new("RemoteEvent")
	remote.Name = "TestBridgeClient"
	remote.Parent = ReplicatedStorage
	clientRemote = remote
	resultMap = MemoryStoreService:GetSortedMap(MAP)
	task.spawn(function()
		for attempt = 1, 5 do
			local ok, err = pcall(function()
				MessagingService:SubscribeAsync(TOPIC, function(message)
					task.spawn(handle, message.Data)
				end)
			end)
			if ok then
				print("[TestBridge] listening on " .. TOPIC .. " (job " .. game.JobId .. ")")
				return
			end
			warn("[TestBridge] subscribe failed (" .. attempt .. "): " .. tostring(err))
			task.wait(2 * attempt)
		end
	end)
end

return TestBridge
