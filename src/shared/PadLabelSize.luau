--!strict
--[[
	PadLabelSize: how big a pad's floating label (World.Pads' "PadLabel" BillboardGui) may be
	on screen (pure maths, no services; Fx.PadLabels applies it every frame).

	A label is sized in studs plus a few fixed pixels, so it shrinks with distance and reads
	from the plot's spawn. Close up the stud part alone filled a third of the screen and the
	sign of the pad the player stood on covered its neighbours'. So its width is capped at
	MAX_SHARE of the viewport's height (its height follows, keeping the label's shape): from
	the spawn every label keeps its world size, and a label never grows past about twice that.

	A label may also have two placements (World.Pads' "NearOffset" / "FarOffset" attributes):
	one that reads with the camera beside its pad, one that reads from the plot's entrance.
	placement blends them by the camera's distance from the pad (NEAR_DISTANCE..FAR_DISTANCE).
]]

local PadLabelSize = {}

-- Widest a label may be on screen, as a share of the viewport's height.
PadLabelSize.MAX_SHARE = 0.2
-- Nearest depth (studs in front of the camera) the maths uses, so a label at or behind the
-- camera counts as close rather than dividing by zero.
PadLabelSize.MIN_DEPTH = 0.5

-- Pixels per stud at `depth` studs in front of a camera with a vertical field of view of
-- `fov` degrees and a viewport `viewportY` pixels tall.
function PadLabelSize.pixelsPerStud(depth: number, viewportY: number, fov: number): number
	local d = math.max(depth, PadLabelSize.MIN_DEPTH)
	return viewportY / (2 * d * math.tan(math.rad(fov) / 2))
end

-- On-screen size (pixels) of a label `studsW` x `studsH` studs plus `pxW` x `pxH` pixels (its
-- UDim2 Size's Scale and Offset parts) at `depth`: its natural size, or the capped one. The
-- second result is true when capped.
function PadLabelSize.size(
	studsW: number,
	pxW: number,
	studsH: number,
	pxH: number,
	depth: number,
	viewportY: number,
	fov: number
): (number, number, boolean)
	local k = PadLabelSize.pixelsPerStud(depth, viewportY, fov)
	local w = studsW * k + pxW
	local h = studsH * k + pxH
	local cap = PadLabelSize.MAX_SHARE * viewportY
	if w <= cap or w <= 0 then
		return w, h, false
	end
	return cap, h * cap / w, true
end

-- Camera distances (studs from the pad; the default follow camera stands ~15-20 studs off a
-- pad the player is on, the spawn view ~50+) at and inside which a label sits at its near
-- placement, and at and past which it sits at its far one; between them it glides across.
PadLabelSize.NEAR_DISTANCE = 22
PadLabelSize.FAR_DISTANCE = 36

-- How far (0 = near, 1 = far) along from its near placement a label is with the camera
-- `distance` studs from its pad: a smoothstep, so it starts and ends its glide gently.
function PadLabelSize.blend(distance: number): number
	local t = (distance - PadLabelSize.NEAR_DISTANCE) / (PadLabelSize.FAR_DISTANCE - PadLabelSize.NEAR_DISTANCE)
	t = math.clamp(t, 0, 1)
	return t * t * (3 - 2 * t)
end

-- A label's offset with the camera `distance` studs from its pad, between its `near` and
-- `far` offsets (both in the frame the label's StudsOffsetWorldSpace uses).
function PadLabelSize.placement(near: Vector3, far: Vector3, distance: number): Vector3
	return near:Lerp(far, PadLabelSize.blend(distance))
end

return PadLabelSize
