--[[
	Flyover: the loading screen's camera. While the game loads it circles high
	over the map; once the player's character stands on its plot it comes down
	in one move, still turning, to the follow camera's spawn shot behind the
	character, so the game starts where the flight lands.
]]

local RunService = game:GetService("RunService")

local Flyover = {}

export type Flight = {
	-- Comes down to `root` (the character's root part) and hands the camera
	-- back; yields until then. Without a root it hands back at once.
	land: (root: BasePart?, speed: number?) -> (),
	-- Hands the camera back where it is.
	stop: () -> (),
}

-- The circle: round the middle of the island (the hub plaza), looking down at it.
local CENTER = Vector3.new(0, 6, 0)
local ORBIT_DISTANCE = 210
local ORBIT_PITCH = math.rad(34)
local ORBIT_TURN = math.rad(14) -- per second
local START_YAW = math.rad(200)

-- The shot it lands on is Fx.Camera's spawn framing: the client puts the
-- follow camera there when a scripted camera hands back, so the hand-over
-- doesn't jump. Keep these three in step with FRAME_DISTANCE, FRAME_PITCH and
-- HEAD_OFFSET in src/client/Fx/Camera.luau.
local END_DISTANCE = 15
local END_PITCH = math.rad(20)
local HEAD_OFFSET = Vector3.new(0, 1.5, 0)
local LAND_TIME = 3

local function smoother(t: number): number
	return t * t * t * (t * (t * 6 - 15) + 10)
end

-- The camera `distance` from `focus`, `pitch` above it, on the side `yaw` points to.
local function place(focus: Vector3, distance: number, pitch: number, yaw: number)
	local camera = workspace.CurrentCamera
	if not camera then
		return
	end
	if camera.CameraType ~= Enum.CameraType.Scriptable then
		camera.CameraType = Enum.CameraType.Scriptable
	end
	local side = Vector3.new(math.cos(yaw), 0, math.sin(yaw))
	local eye = focus + side * (distance * math.cos(pitch)) + Vector3.yAxis * (distance * math.sin(pitch))
	camera.CFrame = CFrame.lookAt(eye, focus)
	camera.Focus = CFrame.new(focus)
end

-- Takes the camera and starts circling. `speed` scales time (1 = real time).
function Flyover.start(speed: number?): Flight
	local yaw = START_YAW
	local circling = true
	local over = false
	local rate = speed or 1

	place(CENTER, ORBIT_DISTANCE, ORBIT_PITCH, yaw)
	local connection = RunService.RenderStepped:Connect(function(dt)
		if circling then
			yaw += ORBIT_TURN * dt * rate
			place(CENTER, ORBIT_DISTANCE, ORBIT_PITCH, yaw)
		end
	end)

	local function stop()
		if over then
			return
		end
		over = true
		circling = false
		connection:Disconnect()
		local camera = workspace.CurrentCamera
		if camera and camera.CameraType == Enum.CameraType.Scriptable then
			camera.CameraType = Enum.CameraType.Custom
		end
	end

	local function land(root: BasePart?, landSpeed: number?)
		if over then
			return
		end
		circling = false
		local from = yaw
		-- The turn per unit of landing time: the move starts at the circle's pace.
		local pace = ORBIT_TURN * LAND_TIME
		local t = 0
		while root and root.Parent and t < LAND_TIME do
			t += RunService.RenderStepped:Wait() * (landSpeed or rate)
			local k = math.min(t / LAND_TIME, 1)
			local eased = smoother(k)
			-- Behind the character, the way it faces.
			local look = root.CFrame.LookVector
			local to = math.atan2(-look.Z, -look.X)
			-- Of the ways round, the one nearest to carrying on as it was going.
			to += math.round((from + pace * 0.5 - to) / (2 * math.pi)) * 2 * math.pi
			local turn = from + pace * (k - 2 * k * k + k * k * k) + (to - from) * (3 * k * k - 2 * k * k * k)
			place(
				CENTER:Lerp(root.Position + HEAD_OFFSET, eased),
				ORBIT_DISTANCE + (END_DISTANCE - ORBIT_DISTANCE) * eased,
				ORBIT_PITCH + (END_PITCH - ORBIT_PITCH) * eased,
				turn
			)
		end
		stop()
	end

	return { land = land, stop = stop }
end

return Flyover
