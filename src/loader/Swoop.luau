--[[
	Swoop: the camera move under the loading screen's reveal. It starts out
	wide, high and round to one side of the player's character and sweeps in
	to the follow camera's spawn shot behind it, so the iris opens on a camera
	that is already arriving at the player and the game starts where it lands.
]]

local RunService = game:GetService("RunService")

local Swoop = {}

-- The shot it ends on is Fx.Camera's spawn framing: the client puts the follow
-- camera there when a scripted camera hands back, so the hand-over doesn't
-- jump. Keep these three in step with FRAME_DISTANCE, FRAME_PITCH and
-- HEAD_OFFSET in src/client/Fx/Camera.luau.
local END_DISTANCE = 15
local END_PITCH = math.rad(20)
local HEAD_OFFSET = Vector3.new(0, 1.5, 0)

-- Where it starts: further out, higher up and round to one side.
local START_DISTANCE = 46
local START_PITCH = math.rad(40)
local START_YAW = math.rad(50)
local TIME = 2.2

-- The point the camera looks at (the character's head).
function Swoop.focus(root: BasePart): Vector3
	return root.Position + HEAD_OFFSET
end

-- Plays the move round `root` and returns once the follow camera has it back.
-- Does nothing unless the follow camera is in charge; lets go at once when the
-- character goes or something else takes the camera. `speed` scales time.
function Swoop.play(root: BasePart, speed: number?)
	local camera = workspace.CurrentCamera
	if not camera or camera.CameraType ~= Enum.CameraType.Custom then
		return
	end
	camera.CameraType = Enum.CameraType.Scriptable

	local function pose(k: number)
		local eased = 1 - (1 - k) ^ 3
		local look = root.CFrame.LookVector
		local flat = Vector3.new(look.X, 0, look.Z)
		flat = if flat.Magnitude < 1e-3 then -Vector3.zAxis else flat.Unit
		local distance = START_DISTANCE + (END_DISTANCE - START_DISTANCE) * eased
		local pitch = START_PITCH + (END_PITCH - START_PITCH) * eased
		local back = CFrame.Angles(0, START_YAW * (1 - eased), 0):VectorToWorldSpace(-flat)
		local focus = Swoop.focus(root)
		local eye = focus + back * (distance * math.cos(pitch)) + Vector3.yAxis * (distance * math.sin(pitch))
		camera.CFrame = CFrame.lookAt(eye, focus)
		camera.Focus = CFrame.new(focus)
	end

	local t = 0
	pose(0)
	while t < TIME do
		t += RunService.RenderStepped:Wait() * (speed or 1)
		if not root.Parent or workspace.CurrentCamera ~= camera or camera.CameraType ~= Enum.CameraType.Scriptable then
			break
		end
		pose(math.min(t / TIME, 1))
	end
	if workspace.CurrentCamera == camera and camera.CameraType == Enum.CameraType.Scriptable then
		camera.CameraType = Enum.CameraType.Custom
	end
end

return Swoop
