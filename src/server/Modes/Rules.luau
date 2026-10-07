--!strict
--[[
	Rules: the pure parts of a Parkour run (no Roblox dependencies, unit-tested).

	A run records its Course level, the server time it started and the server time each checkpoint was
	reached. Checkpoints only count in order (touching #4 while on #2 does nothing); the
	finish only counts after the level's last checkpoint, and only when every leg took at
	least the level's MIN_LEG_SECONDS (nobody can cross the course faster than MAX_PLAUSIBLE_SPEED).
Those minimums assume WalkSpeed 16: a run that wore the speed coil passes `speedScale`
(28/16) to Rules.finish so its legs may be that much quicker. Legs bought with a stage skip
(Rules.skip) have no minimum.
]]

local Course = require(script.Parent.Course)

local Rules = {}

export type Run = {
	-- The Course level being run (Course.LEVELS[i]).
	level: Course.Level,
	startedAt: number,
	checkpoint: number,
	-- Server time each checkpoint was reached (index 1..n).
	times: { number },
	-- Legs skipped with a paid stage skip (leg k ends at checkpoint k; CHECKPOINT_COUNT + 1
	-- is the finish leg): no minimum time.
	skipped: { [number]: boolean },
}

function Rules.newRun(now: number, level: Course.Level?): Run
	return { level = level or Course.LEVELS[1], startedAt = now, checkpoint = 0, times = {}, skipped = {} }
end

-- "ok" when `index` is the next checkpoint (the run advances), "old" when it was already
-- taken, "skip" when it is ahead of the next one (ignored).
function Rules.touchCheckpoint(run: Run, index: number, now: number): string
	if index <= run.checkpoint then
		return "old"
	elseif index ~= run.checkpoint + 1 then
		return "skip"
	end
	run.checkpoint = index
	run.times[index] = now
	return "ok"
end

-- Skips the run's next leg at `now`: the next checkpoint counts as touched (or, after the
-- last one, the finish leg is marked so Rules.finish accepts it). Returns the skipped leg.
function Rules.skip(run: Run, now: number): number
	local leg = run.checkpoint + 1
	run.skipped[leg] = true
	if leg <= run.level.CHECKPOINT_COUNT then
		Rules.touchCheckpoint(run, leg, now)
	end
	return leg
end

-- Validates a finish at `now`: (true, seconds) or (false, reason) with reason
-- "checkpoints" (not all taken) or "fast" (a leg was quicker than possible). `speedScale`
-- (default 1) is how much faster than WalkSpeed 16 the runner could move.
function Rules.finish(run: Run, now: number, speedScale: number?): (boolean, number | string)
	local count = run.level.CHECKPOINT_COUNT
	local minimum = run.level.MIN_LEG_SECONDS
	local scale = if type(speedScale) == "number" and speedScale >= 1 then speedScale else 1
	if run.checkpoint ~= count then
		return false, "checkpoints"
	end
	local previous = run.startedAt
	for k = 1, count + 1 do
		local at = if k <= count then run.times[k] else now
		if type(at) ~= "number" or (not run.skipped[k] and at - previous < minimum[k] / scale) then
			return false, "fast"
		end
		previous = at
	end
	return true, now - run.startedAt
end

-- Seconds rounded to hundredths (what boards and saves store).
function Rules.roundTime(seconds: number): number
	return math.floor(seconds * 100 + 0.5) / 100
end

export type BestEntry = { userId: number, name: string, time: number }

-- Records a time on a best list (one entry per player, fastest first, at most `size`
-- entries). The list is plain data so an OrderedDataStore board (key userId, value
-- centiseconds) can mirror it later. Returns the player's rank on it, or nil.
function Rules.recordBest(list: { BestEntry }, userId: number, name: string, time: number, size: number): number?
	local found = nil
	for i, entry in list do
		if entry.userId == userId then
			found = i
			break
		end
	end
	if found then
		if list[found].time <= time then
			return found
		end
		table.remove(list, found)
	end
	table.insert(list, { userId = userId, name = name, time = time })
	table.sort(list, function(a, b)
		return a.time < b.time
	end)
	while #list > size do
		table.remove(list)
	end
	for i, entry in list do
		if entry.userId == userId then
			return i
		end
	end
	return nil
end

return Rules
