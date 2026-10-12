--[[
	Unit tests for the plot's interactive gym props: the pure rules
	(src/shared/InteractiveRules.luau) and the gym poses Client.Fx.Interactive plays
	(src/shared/Poses.luau, Story set).
	Loaded by tests/run.luau with its harness: { test, check, eq, near, loadShared }.
]]

local roblox = require("@lune/roblox")

local Rules = require("../src/shared/InteractiveRules")

local Vector3 = roblox.Vector3

return function(h: { [string]: any })
	local test, check, eq, near = h.test, h.check, h.eq, h.near
	local Poses = h.loadShared("Poses")

	test("Interactive: trampoline bounce", function()
		local gravity, jumpPower = 196.2, 50
		near(Rules.jumpSpeed(gravity, jumpPower * jumpPower / (2 * gravity)), jumpPower, "jump speed from its height")
		eq(Rules.bounceHeight(jumpPower, 0, false), 3, "standing bounce")
		eq(Rules.bounceHeight(jumpPower, 0, true), 3.5, "standing bounce, jump held")
		local first = Rules.bounceSpeed(jumpPower, 0, false)
		eq(Rules.bounceHeight(jumpPower, first, false), 3.5, "chained bounce")
		eq(Rules.bounceHeight(jumpPower, first, true), 4, "chained bounce, jump held")
		-- A plain jump onto the pad lands slower than a bounce: part of the chain bonus.
		local hop = Rules.bounceHeight(jumpPower, jumpPower, false)
		check(hop > 3 and hop < 3.5, "a jump onto the pad bounces a little higher")
		-- Chained bounces settle instead of growing for ever.
		local speed = 0
		for i = 1, 20 do
			speed = Rules.bounceSpeed(jumpPower, speed, true)
			local height = speed * speed / (2 * gravity)
			local jumps = height / (jumpPower * jumpPower / (2 * gravity))
			check(jumps >= 3 - 1e-6 and jumps <= 4 + 1e-6, "bounce " .. i .. " is 3-4 jumps high")
		end
		check(Rules.bounceSpeed(jumpPower, 1e6, true) <= jumpPower * 2 + 1e-6, "a huge fall still bounces 4 jumps high")
		eq(Rules.bounceSpeed(0, 30, true), 0, "no jump, no bounce")

		local x, z = Rules.drift(3, -4)
		check(x == 3 and z == -4, "slow drift is kept")
		x, z = Rules.drift(30, -40)
		near(math.sqrt(x * x + z * z), Rules.BOUNCE_DRIFT, "fast drift is capped")
		near(x / z, 30 / -40, "capped drift keeps its direction")
		x, z = Rules.drift(0, 0)
		check(x == 0 and z == 0, "no drift")
	end)

	test("Interactive: punch combo", function()
		check(Rules.canHit(nil, 0), "first hit")
		check(not Rules.canHit(10, 10.1), "too soon")
		check(Rules.canHit(10, 10 + Rules.HIT_GAP), "after the gap")
		check(1 / Rules.HIT_GAP <= 4 + 1e-9, "at most 4 hits a second")

		eq(Rules.combo(0, nil, 5), 1, "first hit starts the combo")
		eq(Rules.combo(1, 5, 5.3), 2, "second hit")
		eq(Rules.combo(7, 5, 5 + Rules.COMBO_RESET), 8, "just in time")
		eq(Rules.combo(7, 5, 5 + Rules.COMBO_RESET + 0.01), 1, "too late: starts over")
		check(Rules.comboAlive(5, 6) and not Rules.comboAlive(5, 8) and not Rules.comboAlive(nil, 0), "comboAlive")

		for _, n in { 10, 25, 50 } do
			check(Rules.milestone(n), n .. " is a milestone")
			check(Rules.comboScale(n) > Rules.comboScale(n - 1) * 1.25, n .. " shows bigger")
			check(Rules.comboScale(n) > Rules.comboScale(n + 1), n .. " is bigger than the next hit")
		end
		check(not Rules.milestone(1) and not Rules.milestone(11) and not Rules.milestone(100), "plain hits")
		eq(Rules.comboScale(1), 1, "first hit at normal size")
		check(Rules.comboScale(200) <= 1.8, "text size is capped")
	end)

	test("Interactive: bag swing", function()
		local function run(fps: number, hits: number, gap: number, seconds: number): (number, number, number)
			local angle, speed, peak = 0, 0, 0
			local dt = 1 / fps
			local nextHit, done = 0, 0
			local first = 0
			for i = 0, math.floor(seconds * fps) do
				local t = i * dt
				if done < hits and t >= nextHit then
					done += 1
					nextHit += gap
					speed += Rules.kick(done)
				end
				angle, speed = Rules.swingStep(angle, speed, dt)
				if first == 0 and math.abs(angle) > math.rad(1) then
					first = math.sign(angle)
				end
				peak = math.max(peak, math.abs(angle))
				check(math.abs(angle) <= Rules.SWING_MAX + 1e-9, "swing within its limit")
				check(angle == angle and speed == speed, "swing stays a number")
			end
			return angle, speed, peak * first
		end
		local angle, speed, peak = run(60, 1, 1, 5)
		check(peak > math.rad(12) and peak < math.rad(28), "one hit swings the bag away " .. math.deg(peak))
		check(Rules.swingStill(angle, speed), "settled 5 s after one hit")
		check(not Rules.swingStill(math.rad(5), 0) and not Rules.swingStill(0, 1), "swingStill")
		local _, _, slow = run(20, 1, 1, 5)
		check(math.abs(slow - peak) < math.rad(1.5), "same swing at 20 fps")
		-- A long combo at full speed stays inside the limit and still settles.
		angle, speed = run(60, 60, Rules.HIT_GAP, 15 + 6)
		check(Rules.swingStill(angle, speed), "settled after a long combo")
		check(Rules.kick(1) < Rules.kick(10) and Rules.kick(10) == Rules.kick(500), "kick grows, then caps")
		-- A stalled frame (huge dt) never blows the swing up.
		angle, speed = Rules.swingStep(0.2, 3, 10)
		check(math.abs(angle) <= Rules.SWING_MAX and math.abs(speed) < 10, "huge dt is clamped")
	end)

	test("Interactive: punch timing", function()
		local reach, weight = Rules.punch(-0.1)
		check(reach == 0 and weight == 0, "before the punch")
		reach, weight = Rules.punch(Rules.PUNCH_TIME)
		check(reach == 0 and weight == 0, "after the punch")
		reach, weight = Rules.punch(Rules.PUNCH_TIME * 0.45)
		check(reach == 1 and weight == 1, "fist out, pose fully on")
		local lastReach = 0
		for i = 0, 36 do
			reach, weight = Rules.punch(i * 0.01)
			check(reach >= lastReach or i * 0.01 >= Rules.PUNCH_TIME, "the fist only goes out")
			check(weight >= 0 and weight <= 1, "weight in range")
			lastReach = reach
		end
		_, weight = Rules.punch(Rules.PUNCH_TIME - 0.005)
		check(weight < 0.05, "the pose fades out, no snap")
		check(Rules.PUNCH_TIME > Rules.HIT_GAP, "a punch outlasts the hit gap, so combos keep the fists up")
	end)

	test("Interactive: jump presses", function()
		check(Rules.newPress(nil, 0), "the first request is a press")
		-- Held: a request every frame is one press, even at 10 fps.
		local last: number? = nil
		local presses = 0
		for i = 0, 30 do
			local t = i * 0.1
			if Rules.newPress(last, t) then
				presses += 1
			end
			last = t
		end
		eq(presses, 1, "holding jump is one press")
		check(not Rules.newPress(1, 1 + 1 / 60), "the next frame is the same press")
		check(Rules.newPress(1, 1 + Rules.PRESS_GAP + 0.01), "released and pressed again")
		check(Rules.PRESS_GAP < Rules.HIT_GAP and Rules.PRESS_GAP < Rules.REP_GAP, "spam is never slowed by the press gap")
	end)

	test("Interactive: bench reps", function()
		local T = Rules.REP_TIME
		check(T >= 0.3 and T <= 0.6, "a rep is quick")
		eq(Rules.press(0), 1, "starts with the arms out")
		eq(Rules.press(-1), 1, "rests at arms' length before a rep")
		eq(Rules.press(T), 1, "back at arms' length")
		eq(Rules.press(T + 5), 1, "rests at arms' length after a rep")
		local last, lowest, lowestAt = 1, 1, 0
		for i = 1, 200 do
			local t = i * T / 200
			local p = Rules.press(t)
			check(p >= 0 and p <= 1, "press in range")
			check(math.abs(p - last) < 0.06, "the bar never jumps")
			if p < lowest then
				lowest, lowestAt = p, t
			end
			last = p
		end
		check(lowest < 0.01, "every rep reaches the chest")
		check(lowestAt > T * 0.3 and lowestAt < T * 0.6, "down, then up")

		-- One press: one rep, then the bar rests.
		local at, queued, started = Rules.repStep(nil, false, 10, true)
		check(at == 10 and not queued and started, "a press at rest starts a rep")
		at, queued, started = Rules.repStep(at, queued, 10 + T / 2, false)
		check(at == 10 and not queued and not started, "the rep plays on")
		at, queued, started = Rules.repStep(at, queued, 10 + T + 0.01, false)
		check(at == nil and not queued and not started, "the bar rests after the rep")
		at, queued, started = Rules.repStep(at, queued, 20, false)
		check(at == nil and not started, "no press, no rep")

		-- A press during a rep queues one more, which starts exactly when the first ends.
		at, queued = Rules.repStep(nil, false, 0, true)
		at, queued, started = Rules.repStep(at, queued, 0.1, true)
		check(at == 0 and queued and not started, "a press during a rep queues one")
		at, queued, started = Rules.repStep(at, queued, 0.2, true)
		check(at == 0 and queued and not started, "at most one rep is queued")
		at, queued, started = Rules.repStep(at, queued, T + 0.004, false)
		check(started and not queued, "the queued rep starts")
		near(at, T, "back to back: no frame lost between reps")
		-- A stalled frame never leaves the queue playing in the past.
		at, queued, started = Rules.repStep(0, true, 9, false)
		check(at == 9 and started and not queued, "a late queued rep starts now")
		-- The press that ends one rep's wait may queue the next on the same step.
		at, queued, started = Rules.repStep(0, true, T + 0.01, true)
		check(started and queued, "start one, queue the next")

		-- Spamming faster than the reps play: reps chain at one per REP_TIME, none lost.
		local function spam(pressEvery: number, seconds: number, fps: number): number
			local a: number?, q, reps = nil, false, 0
			local nextPress = 0
			for i = 0, math.floor(seconds * fps) do
				local t = i / fps
				local pressed = t >= nextPress
				if pressed then
					nextPress += pressEvery
				end
				local s
				a, q, s = Rules.repStep(a, q, t, pressed)
				if s then
					reps += 1
				end
			end
			return reps
		end
		local fast = spam(0.1, 9, 60)
		check(math.abs(fast - 9 / T) <= 1, "fast spam: a rep every REP_TIME (" .. fast .. ")")
		check(math.abs(spam(0.1, 9, 20) - fast) <= 1, "the same rhythm at 20 fps")
		eq(spam(1, 9.5, 60), 10, "slow presses: one rep each")
		eq(spam(100, 9, 60), 1, "one press, one rep")

		-- The server counts chained reps, with a rep of slack for jitter, and no more.
		local nextAt: number? = nil
		local ok
		ok, nextAt = Rules.repAllowed(nextAt, 100)
		check(ok, "first rep counts")
		local counted = 1
		for i = 1, 20 do
			ok, nextAt = Rules.repAllowed(nextAt, 100 + i * T)
			counted += if ok then 1 else 0
		end
		eq(counted, 21, "reps a REP_TIME apart all count")
		-- Two reps arriving together (jitter) both count; a flood does not.
		nextAt = nil
		counted = 0
		for _ = 1, 50 do
			ok, nextAt = Rules.repAllowed(nextAt, 200)
			counted += if ok then 1 else 0
		end
		eq(counted, 2, "one rep of slack")
		counted = 0
		nextAt = nil
		for i = 0, 999 do
			ok, nextAt = Rules.repAllowed(nextAt, 300 + i * 0.01)
			counted += if ok then 1 else 0
		end
		check(counted <= 10 / Rules.REP_GAP + 2, "a flood counts at most one rep per REP_GAP (" .. counted .. ")")
		check(Rules.REP_GAP < T, "chained reps are slower than the server's limit")
	end)

	test("Interactive: gym poses", function()
		local names = Poses.allPoseNames("Story")
		for _, name in { "PunchGuard", "PunchRight", "PunchLeft", "BenchUp", "BenchDown" } do
			check(table.find(names, name) ~= nil, "Story pose " .. name)
			check(table.find(Poses.poseNames("Story"), name) == nil, name .. " is not in the cutscene rotation")
		end

		-- A plain R15-shaped rig: +X right, +Y up, facing -Z; arm segments 1 stud long.
		local pivots = {
			LowerTorso = Vector3.new(0, 2, 0),
			UpperTorso = Vector3.new(0, 2.4, 0),
			Head = Vector3.new(0, 4, 0),
			RightUpperArm = Vector3.new(1.25, 3.7, 0),
			RightLowerArm = Vector3.new(1.25, 2.7, 0),
			RightHand = Vector3.new(1.25, 1.7, 0),
			RightUpperLeg = Vector3.new(0.5, 2, 0),
			RightLowerLeg = Vector3.new(0.5, 1.1, 0),
			RightFoot = Vector3.new(0.5, 0.2, 0),
		}
		for _, limb in { "UpperArm", "LowerArm", "Hand", "UpperLeg", "LowerLeg", "Foot" } do
			local right = pivots["Right" .. limb]
			pivots["Left" .. limb] = Vector3.new(-right.X, right.Y, right.Z)
		end
		local function solve(pose: string): { [string]: any }
			return Poses.solve(pivots, Poses.samplePose("Story", pose, 0, 0), 1)
		end
		local shoulder = pivots.RightUpperArm

		-- Bench press: the rig lies on its back, so "in front of the chest" (-Z) is up.
		local up, down = solve("BenchUp"), solve("BenchDown")
		for name, frames in { BenchUp = up, BenchDown = down } do
			local r, l = frames.RightHand.Position, frames.LeftHand.Position
			check(math.abs(r.X + l.X) < 1e-4 and math.abs(r.Y - l.Y) < 1e-4 and math.abs(r.Z - l.Z) < 1e-4, name .. " is symmetric")
			check(r.X > shoulder.X + 0.3, name .. ": hands wider than the shoulders")
			-- Knees bent over the end of the bench: the feet hang behind (below) the thighs.
			check(frames.RightFoot.Position.Z > 0.7, name .. ": shins hang down")
			check(math.abs(frames.RightLowerLeg.Position.Z) < 0.1, name .. ": thighs lie flat")
		end
		local top, bottom = up.RightHand.Position, down.RightHand.Position
		near(top.Y, shoulder.Y, "arms out: hands over the shoulders")
		check(top.Z < -1.7, "arms out: straight in front of the chest")
		check(bottom.Z < -0.5 and bottom.Z > -1.1, "bar down: hands just in front of the chest")
		check(bottom.Y < shoulder.Y - 0.3, "bar down: over the lower chest")
		check(top.Z < bottom.Z - 0.9, "a rep moves the bar about a stud")
		check(math.abs(top.X - bottom.X) < 0.15, "the grip keeps its width")
		check(down.RightLowerArm.Position.Z > 0.1, "bar down: elbows drop below the chest line")

		-- Punches: the fist goes out in front, near the middle; the other stays on guard.
		local guard = solve("PunchGuard")
		check(guard.RightHand.Position.Y > shoulder.Y - 0.6 and guard.RightHand.Position.Z < -0.3, "guard: fists up in front")
		for _, side in { "Right", "Left" } do
			local other = if side == "Right" then "Left" else "Right"
			local frames = solve("Punch" .. side)
			local fist, back = frames[side .. "Hand"].Position, frames[other .. "Hand"].Position
			check(fist.Z < guard[side .. "Hand"].Position.Z - 0.9, side .. " punch reaches out")
			check(fist.Z < -1.6, side .. " punch: arm nearly straight in front")
			check(math.abs(fist.X) < 1.3, side .. " punch lands near the middle")
			check(math.abs(fist.Y - shoulder.Y) < 0.5, side .. " punch at shoulder height")
			check(back.Z > fist.Z + 0.7 and back.Y > shoulder.Y - 0.8, other .. " fist stays on guard")
		end
		local right, left = solve("PunchRight"), solve("PunchLeft")
		near(right.RightHand.Position.X, -left.LeftHand.Position.X, "left punch mirrors the right")
		near(right.RightHand.Position.Z, left.LeftHand.Position.Z, "left punch mirrors the right (reach)")
	end)
end
