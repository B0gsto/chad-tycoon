--!strict
--[[
	Intro.Framing: shots defined relative to their subjects.

	Pure maths (plain number tables, no Roblox types) so the unit tests can load it.
	Points are { x, y, z } in stage-local studs (+Y up). The camera follows Roblox
	conventions: CFrame.lookAt(eye, look) with +Y up, a vertical field of view, and
	screen right = forward x up.

	A shot (Timeline camera key field `shot`):
	  subjects  actor names to keep in frame (feet to head, plus headroom)
	  size      "close" | "medium" | "full" | "wide": how much of the frame height
	            the group fills (FILL) and the lens (LENS)
	  place     "left" | "center" | "right": where the group's centre sits
	            (left / right = the screen thirds)
	  angle     "ground" | "low" | "eye" | "high": camera pitch (PITCH, degrees,
	            positive looks up); pitch = n overrides it
	  yaw       degrees; the direction the camera looks (0 = +Z, 90 = +X)
	  headroom  extra studs kept clear above the tallest head (props such as the
	            rain cloud or the lightbulb)
	  lift      vertical screen offset of the group centre (-1..1, + is up)
	  push      distance multiplier >= 1 (pulls back from the tightest fit; a dolly
	            in is two keys going from a looser size to a tighter one)
	  fov       overrides the lens
	  focus     subject name whose centre goes to `place` (default: the whole group)

	Framing.solve returns the eye, the look-at point and the field of view that
	put every subject's head and feet inside the SAFE area at the given aspect
	ratio. Cutscene re-solves every frame, so shots follow moving actors.
]]

export type Point = { number }
export type Subject = { feet: Point, height: number, radius: number?, name: string? }
export type Shot = {
	subjects: { string },
	size: string?,
	place: string?,
	angle: string?,
	pitch: number?,
	yaw: number?,
	headroom: number?,
	lift: number?,
	push: number?,
	fov: number?,
	focus: string?,
}

local Framing = {}

-- Fraction of the screen (from its centre) that counts as safe: 5% - 95%.
Framing.SAFE = 0.9
Framing.FILL = { close = 0.84, medium = 0.74, full = 0.62, wide = 0.42 }
Framing.LENS = { close = 32, medium = 36, full = 40, wide = 48 }
Framing.PITCH = { ground = 15, low = 8, eye = 0, high = -12 }
Framing.PLACE = { left = -1 / 3, center = 0, right = 1 / 3 }
Framing.MIN_EYE_Y = 0.6

local function add(a: Point, b: Point, k: number): Point
	return { a[1] + b[1] * k, a[2] + b[2] * k, a[3] + b[3] * k }
end

local function sub(a: Point, b: Point): Point
	return { a[1] - b[1], a[2] - b[2], a[3] - b[3] }
end

local function dot(a: Point, b: Point): number
	return a[1] * b[1] + a[2] * b[2] + a[3] * b[3]
end

local function cross(a: Point, b: Point): Point
	return { a[2] * b[3] - a[3] * b[2], a[3] * b[1] - a[1] * b[3], a[1] * b[2] - a[2] * b[1] }
end

local function unit(a: Point): Point
	local m = math.sqrt(dot(a, a))
	if m < 1e-9 then
		return { 0, 0, 1 }
	end
	return { a[1] / m, a[2] / m, a[3] / m }
end

-- Camera basis of a look direction: forward, right, up.
local function basis(forward: Point): (Point, Point, Point)
	local f = unit(forward)
	local r = unit(cross(f, { 0, 1, 0 }))
	local u = cross(r, f)
	return f, r, u
end

-- Screen position of `p` seen from eye toward look: x, y in -1..1 across the
-- viewport (+x right, +y up) and the depth in studs (<= 0 is behind the camera).
function Framing.project(eye: Point, look: Point, fov: number, aspect: number, p: Point): (number, number, number)
	local f, r, u = basis(sub(look, eye))
	local d = sub(p, eye)
	local z = dot(d, f)
	local th = math.tan(math.rad(fov) / 2)
	if z <= 1e-3 then
		return math.huge, math.huge, z
	end
	return dot(d, r) / (z * th * aspect), dot(d, u) / (z * th), z
end

-- Feet and head points of every subject (head raised by headroom), widened by
-- each subject's radius along the screen's horizontal axis.
function Framing.points(subjects: { Subject }, right: Point, headroom: number): { Point }
	local out = {}
	for _, s in subjects do
		local r = s.radius or 1
		local head = { s.feet[1], s.feet[2] + s.height + headroom, s.feet[3] }
		for _, base in { s.feet, head } do
			table.insert(out, add(base, right, r))
			table.insert(out, add(base, right, -r))
		end
	end
	return out
end

-- Camera eye, look-at and field of view for a shot of these subjects.
function Framing.solve(subjects: { Subject }, shot: Shot, aspect: number): (Point, Point, number)
	local size = shot.size or "full"
	local fov = shot.fov or Framing.LENS[size] or 40
	local fill = Framing.FILL[size] or 0.62
	local pitch = math.rad(shot.pitch or Framing.PITCH[shot.angle or "eye"] or 0)
	local yaw = math.rad(shot.yaw or 0)
	local px = Framing.PLACE[shot.place or "center"] or 0
	local py = shot.lift or 0
	local th = math.tan(math.rad(fov) / 2)

	local f, r, u = basis({ math.sin(yaw) * math.cos(pitch), math.sin(pitch), math.cos(yaw) * math.cos(pitch) })
	local flat = { r[1], 0, r[3] }
	local points = Framing.points(subjects, flat, shot.headroom or 0)
	if #points == 0 then
		return { 0, 5, -20 }, { 0, 4, 0 }, fov
	end
	local focused = points
	for _, s in subjects do
		if shot.focus and s.name == shot.focus then
			focused = Framing.points({ s }, flat, shot.headroom or 0)
		end
	end

	-- Centre of the bounding box of the focus subject (or of the whole group).
	local lo = { math.huge, math.huge, math.huge }
	local hi = { -math.huge, -math.huge, -math.huge }
	for _, p in focused do
		for i = 1, 3 do
			lo[i] = math.min(lo[i], p[i])
			hi[i] = math.max(hi[i], p[i])
		end
	end
	local centre = { (lo[1] + hi[1]) / 2, (lo[2] + hi[2]) / 2, (lo[3] + hi[3]) / 2 }

	-- Eye at distance d: the centre lands at (px, py) on screen.
	-- When the pitch would put the eye under the ground, the camera stays at ground
	-- level and tilts up just enough to look at the centre instead.
	local function at(d: number): (Point, Point)
		local fd, rd, ud = f, r, u
		if centre[2] - f[2] * d - u[2] * py * d * th < Framing.MIN_EYE_Y then
			local sinp = math.clamp((centre[2] - Framing.MIN_EYE_Y) / d, -0.9, 0.9)
			local cosp = math.sqrt(1 - sinp * sinp)
			fd, rd, ud = basis({ math.sin(yaw) * cosp, sinp, math.cos(yaw) * cosp })
		end
		local eye = add(add(add(centre, fd, -d), rd, -px * d * th * aspect), ud, -py * d * th)
		if eye[2] < Framing.MIN_EYE_Y then
			eye[2] = Framing.MIN_EYE_Y
		end
		return eye, add(eye, fd, d)
	end
	local safe = Framing.SAFE
	local function fits(d: number): boolean
		local eye, look = at(d)
		local top, bottom = -math.huge, math.huge
		for _, p in points do
			local x, y, z = Framing.project(eye, look, fov, aspect, p)
			if z < 1 or math.abs(x) > safe or math.abs(y) > safe then
				return false
			end
			top = math.max(top, y)
			bottom = math.min(bottom, y)
		end
		return top - bottom <= 2 * fill
	end

	-- Closest distance that fits (bisection; farther is always looser).
	local near, far = 1, 40
	while not fits(far) and far < 2000 do
		near, far = far, far * 2
	end
	for _ = 1, 32 do
		local mid = (near + far) / 2
		if fits(mid) then
			far = mid
		else
			near = mid
		end
	end
	local eye, look = at(far * math.max(shot.push or 1, 1))
	return eye, look, fov
end

return Framing
