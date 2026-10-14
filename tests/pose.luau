--[[
	Unit tests for the Pose rules (src/server/Modes/PoseRules.luau; docs/minigames.md).
	Loaded by tests/run.luau with its harness: { test, check, eq, near, seeded }.
]]

local fs = require("@lune/fs")
local luau = require("@lune/luau")

return function(h: { [string]: any })
	local test, check, eq = h.test, h.check, h.eq
	local PoseRules = luau.load(fs.readFile("src/server/Modes/PoseRules.luau"), { debugName = "PoseRules" })()

	test("Pose: the rules module loads", function()
		local a = PoseRules.ARENA
		check(type(a) == "table" and a.sizeX > 0 and a.sizeZ > 0, "ARENA has a size")
		check(PoseRules.FALL_BELOW > 0, "FALL_BELOW is positive")
		eq(#PoseRules.FLEXES, 4, "four flexes")
		local dirs = {}
		for _, flex in PoseRules.FLEXES do
			check(type(flex.pose) == "string" and type(flex.label) == "string", "flex has a pose and label")
			check(not dirs[flex.dir], "flex directions are unique")
			dirs[flex.dir] = true
		end
	end)

	test("Pose: sequences are seeded, in range and never triple", function()
		local a = PoseRules.sequence(1234, PoseRules.MAX_ROUND)
		local b = PoseRules.sequence(1234, PoseRules.MAX_ROUND)
		eq(#a, PoseRules.MAX_ROUND, "full length")
		for i = 1, #a do
			eq(a[i], b[i], "same seed, same flex " .. i)
		end
		for seed = 1, 200 do
			local seq = PoseRules.sequence(seed * 7919, 40)
			for i, flex in seq do
				check(flex >= 1 and flex <= 4 and flex == math.floor(flex), "flex index in 1..4")
				if i >= 3 then
					check(not (seq[i - 1] == flex and seq[i - 2] == flex), "no flex three times in a row")
				end
			end
		end
		local c = PoseRules.sequence(99, 30)
		local differs = false
		for i = 1, 30 do
			differs = differs or c[i] ~= a[i]
		end
		check(differs, "another seed gives another sequence")
		local short = PoseRules.sequence(1234, 5)
		for i = 1, 5 do
			eq(short[i], a[i], "a shorter sequence is a prefix")
		end
		eq(#PoseRules.sequence(5, 0), 0, "zero length")
	end)

	test("Pose: a round is copied flex by flex", function()
		local seq = { 2, 4, 1, 3 }
		eq(PoseRules.press(seq, 1, 0, 2), "clear", "round 1: one right flex clears it")
		eq(PoseRules.press(seq, 1, 0, 3), "wrong", "round 1: a wrong flex")
		eq(PoseRules.press(seq, 3, 0, 2), "good", "round 3, first")
		eq(PoseRules.press(seq, 3, 1, 4), "good", "round 3, second")
		eq(PoseRules.press(seq, 3, 2, 1), "clear", "round 3, last")
		eq(PoseRules.press(seq, 3, 2, 3), "wrong", "round 3, wrong last")
		eq(PoseRules.press(seq, 3, 3, 3), "wrong", "nothing to press after the round is done")
		eq(PoseRules.press(seq, 6, 4, 1), "wrong", "past the sequence's end")
	end)

	test("Pose: pass mark, best and show timing", function()
		check(not PoseRules.passed(PoseRules.PASS_ROUND - 1), "one short of the pass")
		check(PoseRules.passed(PoseRules.PASS_ROUND), "the pass round passes")
		check(PoseRules.HEARTS >= 1 and PoseRules.MAX_ROUND > PoseRules.PASS_ROUND, "hearts and a cap")
		eq(PoseRules.newBest(5, 3), 5, "a shorter run keeps the best")
		eq(PoseRules.newBest(5, 9), 9, "a longer run sets it")
		eq(PoseRules.showStep(1), PoseRules.STEP_START, "round 1 is the slowest")
		local prev = math.huge
		for round = 1, PoseRules.MAX_ROUND do
			local step = PoseRules.showStep(round)
			check(step <= prev and step >= PoseRules.STEP_MIN, "the show speeds up, down to the floor")
			prev = step
			check(PoseRules.showLength(round) > round * step, "the show fits every flex")
		end
		eq(PoseRules.showStep(PoseRules.MAX_ROUND), PoseRules.STEP_MIN, "the fastest step is reached")
		check(PoseRules.INPUT_TIMEOUT >= 4, "the turn is generous")
	end)

	test("Pose: the repeat share rests between pays", function()
		local gap = PoseRules.REPEAT_GAP
		check(gap >= 60, "the repeat gap is minutes, not seconds")
		check(PoseRules.repeatReady(0, 1000), "never paid: ready")
		check(not PoseRules.repeatReady(1000, 1000 + gap - 1), "inside the gap: resting")
		check(PoseRules.repeatReady(1000, 1000 + gap), "after the gap: ready")
	end)

	test("Pose: replay milestones pay a capped bonus (REPLAY rule)", function()
		check(not PoseRules.milestone(PoseRules.PASS_ROUND), "the pass itself is no milestone")
		check(PoseRules.MILESTONE_FIRST > PoseRules.PASS_ROUND, "milestones come after the pass")
		local hits = {}
		for cleared = 1, 30 do
			if PoseRules.milestone(cleared) then
				table.insert(hits, cleared)
			end
		end
		eq(hits[1], 12, "first milestone at 12")
		eq(hits[2], 16, "then 16")
		eq(hits[3], 20, "then every 4")
		check(not PoseRules.milestone(13.5), "whole flexes only")
		eq(PoseRules.bonusCash(1000, 0.5), 500, "half a repeat share")
		eq(PoseRules.bonusCash(999, 0.5), 499, "rounded down")
		eq(PoseRules.bonusCash(1000, 0), 0, "nothing for nothing")
		-- One window: 12 and 16 pay half each, then the window is spent.
		local share = PoseRules.MILESTONE_SHARE
		local paid, at, used = PoseRules.bonusTake(0, 0, 1000, share)
		eq(paid, share, "first bonus pays")
		eq(at, 1000, "the window starts")
		paid, at, used = PoseRules.bonusTake(at, used, 1010, share)
		eq(paid, share, "second bonus pays")
		paid, at, used = PoseRules.bonusTake(at, used, 1020, share)
		eq(paid, 0, "the window's cap is spent")
		eq(used, PoseRules.BONUS_CAP, "used stays at the cap")
		paid, at = PoseRules.bonusTake(at, used, 1000 + PoseRules.REPEAT_GAP, share)
		eq(paid, share, "a new window pays again")
		eq(at, 1000 + PoseRules.REPEAT_GAP, "and starts now")
		paid = PoseRules.bonusTake(5000, 0.75, 4000, share)
		eq(paid, share, "a clock that went back opens a fresh window")
		-- The rule: a bot or a grinder running back to back for an hour earns at most two
		-- repeat shares per REPEAT_GAP outside the full pack (one pass share, BONUS_CAP bonus).
		local repeatCash = 1000
		local windowAt, windowUsed, repeatLast = 0, 0, 0
		local total = 0
		for t = 1000, 1000 + 3600 - 1, 20 do -- a run reaching 20 flexes every 20 s (os.time 0 is "never")
			if PoseRules.repeatReady(repeatLast, t) then
				total += repeatCash
				repeatLast = t
			end
			for _, m in { 12, 16, 20 } do
				if PoseRules.milestone(m) then
					local s
					s, windowAt, windowUsed = PoseRules.bonusTake(windowAt, windowUsed, t, share)
					total += PoseRules.bonusCash(repeatCash, s)
				end
			end
		end
		local windows = 3600 / PoseRules.REPEAT_GAP
		check(total <= windows * (1 + PoseRules.BONUS_CAP) * repeatCash, "at most 2 repeat shares per window")
		check(total > windows * repeatCash, "replays pay more than the pass share alone")
	end)

	test("Pose: lobby phases gate Begin, input and falls", function()
		check(PoseRules.canBegin("lobby"), "Begin from the lobby")
		check(PoseRules.canBegin("results"), "Begin from the results card (PLAY AGAIN)")
		check(not PoseRules.canBegin("countdown"), "no Begin during the countdown")
		check(not PoseRules.canBegin("play"), "no Begin during play")
		check(not PoseRules.canBegin(nil), "no Begin outside the mode")
		check(PoseRules.acceptsInput("play"), "input counts in play")
		for _, phase in { "lobby", "countdown", "results" } do
			check(not PoseRules.acceptsInput(phase), "no scored input in " .. phase)
		end
		eq(PoseRules.fallBack("lobby"), "lobby", "lobby fall: lobby spawn")
		eq(PoseRules.fallBack("results"), "lobby", "results fall: lobby spawn")
		eq(PoseRules.fallBack("countdown"), "podium", "countdown fall: podium")
		eq(PoseRules.fallBack("play"), "podium", "play fall: podium")
		eq(PoseRules.COUNTDOWN, 3, "3-2-1")
		check(PoseRules.RESULTS_TIME >= 4 and PoseRules.RESULTS_TIME <= 8, "results card about 6 s")
	end)

	test("Pose: the START pad needs a step off and a re-arm", function()
		check(PoseRules.onPad(0, 0, 0, 5), "centre")
		check(PoseRules.onPad(3, 1, 4, 5), "on the rim")
		check(not PoseRules.onPad(4, 0, 4, 5), "outside the radius")
		check(not PoseRules.onPad(0, PoseRules.PAD_HEIGHT, 0, 5), "too far above")
		check(not PoseRules.onPad(0, -PoseRules.PAD_HEIGHT - 1, 0, 5), "too far below")
		local pad = PoseRules.newPad(100)
		check(not PoseRules.padStep(pad, true, 100), "landing on it does not fire")
		check(not PoseRules.padStep(pad, true, 200), "standing on it never fires without a step off")
		check(not PoseRules.padStep(pad, false, 200), "stepped off")
		check(PoseRules.padStep(pad, true, 200.1), "stepping back on fires")
		check(not PoseRules.padStep(pad, true, 200.2), "fires once")
		check(not PoseRules.padStep(pad, false, 200.3), "off again")
		check(not PoseRules.padStep(pad, true, 200.4), "too soon after the last: re-arming")
		check(PoseRules.padStep(pad, true, 200.1 + PoseRules.PAD_REARM), "re-armed")
		local fresh = PoseRules.newPad(50)
		PoseRules.padStep(fresh, false, 50)
		check(not PoseRules.padStep(fresh, true, 50.5), "a fresh pad waits PAD_REARM")
		check(PoseRules.padStep(fresh, true, 50 + PoseRules.PAD_REARM), "then fires")
	end)

	test("Pose: podium lanes for a Begin", function()
		local lane, bump = PoseRules.pickLane({}, 3)
		eq(lane, 1, "first free lane")
		eq(bump, false, "nothing to bump")
		lane = PoseRules.pickLane({ [1] = "busy" }, 3)
		eq(lane, 2, "skips a busy lane")
		lane = PoseRules.pickLane({}, 3, 3)
		eq(lane, 3, "keeps the preferred lane (PLAY AGAIN on the same podium)")
		lane = PoseRules.pickLane({ [3] = "busy" }, 3, 3)
		eq(lane, 1, "preferred lane taken: another")
		lane, bump = PoseRules.pickLane({ [1] = "busy", [2] = "results", [3] = "busy" }, 3)
		eq(lane, 2, "a results card's podium is free")
		eq(bump, true, "its player goes to the lobby")
		lane, bump = PoseRules.pickLane({ [1] = "results", [2] = nil, [3] = "busy" }, 3)
		eq(lane, 2, "an empty lane before a results one")
		eq(bump, false, "no bump needed")
		lane = PoseRules.pickLane({ [1] = "busy", [2] = "busy", [3] = "busy" }, 3)
		eq(lane, nil, "all busy: full")
		lane = PoseRules.pickLane({ [1] = "busy", [2] = "busy", [3] = "busy" }, 5)
		eq(lane, nil, "at most MAX_LANES podiums")
		lane = PoseRules.pickLane({}, 0)
		eq(lane, nil, "no podiums")
	end)

	test("Pose: the show stays readable and the turn fair", function()
		check(PoseRules.STEP_MIN >= 0.5, "the fastest flex is still readable")
		local passShow = PoseRules.showLength(PoseRules.PASS_ROUND)
		check(passShow <= 8, "the pass round's show is short enough to remember")
		check(PoseRules.MAX_ROUND >= 50, "after the pass the chase for a best is endless")
		check(#PoseRules.sequence(7, PoseRules.MAX_ROUND) == PoseRules.MAX_ROUND, "the sequence covers every round")
	end)
	test("Pose: the lobby is on the deck and the leave margin sits outside it", function()
		local a, l = PoseRules.ARENA, PoseRules.LOBBY
		check(l.x0 >= 28, "the green room starts past the 56-stud show")
		for _, p in { { l.spawnX, l.spawnZ }, { l.spotX, l.mirrorZ }, { l.x0, 0 } } do
			check(not PoseRules.outsideArena(p[1], p[2], 0), "lobby point on the deck")
		end
		check(l.spotX + 4 <= a.sizeX / 2, "room for the mirror past the RehearsalSpot")
		check(PoseRules.LEAVE_MARGIN > 0, "a margin past the deck")
		check(not PoseRules.outsideArena(a.sizeX / 2 + PoseRules.LEAVE_MARGIN - 1, 0, PoseRules.LEAVE_MARGIN), "inside the margin")
		check(PoseRules.outsideArena(a.sizeX / 2 + PoseRules.LEAVE_MARGIN + 1, 0, PoseRules.LEAVE_MARGIN), "past the margin")
		check(PoseRules.outsideArena(0, -(a.sizeZ / 2 + PoseRules.LEAVE_MARGIN + 1), PoseRules.LEAVE_MARGIN), "past the margin in z")
	end)
end
