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

	Labels always face the camera, so looking along the buy row from one end the far labels
	pile up on screen (and the plot's other floating signs, like a crate cracker's READY! pill,
	join in). declutter decides which of them to fade: nearest first, a label whose
	screen rect covers more than FADE_OUT_SHARE of a nearer shown label's (or its own, whichever
	is smaller) fades out, and comes back once that is under FADE_IN_SHARE (the gap keeps it
	from flickering).
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

-- Overlap (share of the smaller rect) past which a farther label fades out, and under which a
-- faded one comes back.
-- At 0.25 a nearer sign still hid most of a farther one's price row (both are three rows, the
-- price at the bottom); from the spawn view the row's signs overlap under 0.05.
PadLabelSize.FADE_OUT_SHARE = 0.15
PadLabelSize.FADE_IN_SHARE = 0.06

-- A label's rect on screen: centre `x`, `y` and size `w` x `h` (pixels).
export type Rect = { x: number, y: number, w: number, h: number }

-- How much of the smaller of rects `a` and `b` their overlap covers (0..1).
function PadLabelSize.overlapShare(a: Rect, b: Rect): number
	local ox = math.min(a.x + a.w / 2, b.x + b.w / 2) - math.max(a.x - a.w / 2, b.x - b.w / 2)
	local oy = math.min(a.y + a.h / 2, b.y + b.h / 2) - math.max(a.y - a.h / 2, b.y - b.h / 2)
	if ox <= 0 or oy <= 0 then
		return 0
	end
	local smaller = math.min(a.w * a.h, b.w * b.h)
	if smaller <= 0 then
		return 0
	end
	return math.min(ox * oy / smaller, 1)
end

-- Which labels to fade. `rects` are the labels' screen rects nearest the camera first,
-- `faded[i]` whether label i is faded now and `keep[i]` (optional) whether it must stay shown
-- (the pad the player is at). Returns the new faded flags: each label is checked against the
-- nearer labels left shown, a shown one fading past FADE_OUT_SHARE, a faded one coming back
-- under FADE_IN_SHARE. Also returns each label's worst overlap share and the index of the
-- shown label giving it (0 when none), for diagnostics.
function PadLabelSize.declutter(rects: { Rect }, faded: { boolean }, keep: { boolean }?): ({ boolean }, { number }, { number })
	local result = table.create(#rects, false)
	local shares = table.create(#rects, 0)
	local covers = table.create(#rects, 0)
	local shown: { number } = {}
	for i, rect in rects do
		local worst, cover = 0, 0
		if not (keep and keep[i]) then
			for _, j in shown do
				local share = PadLabelSize.overlapShare(rect, rects[j])
				if share > worst then
					worst, cover = share, j
				end
			end
		end
		local out = if faded[i] then worst >= PadLabelSize.FADE_IN_SHARE else worst > PadLabelSize.FADE_OUT_SHARE
		result[i] = out
		shares[i] = worst
		covers[i] = cover
		if not out then
			table.insert(shown, i)
		end
	end
	return result, shares, covers
end

return PadLabelSize
