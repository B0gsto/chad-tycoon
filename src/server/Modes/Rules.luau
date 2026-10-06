--!strict
--[[
	Rules: the pure parts of a Parkour run (no Roblox dependencies, unit-tested).

	A run records its Course level, the server time it started and the server time each checkpoint was
	reached. Checkpoints only count in order (touching #4 while on #2 does nothing); the
	finish only counts after the level's last checkpoint, and only when every leg took at
	least the level's MIN_LEG_SECONDS (nobody can cross the course faster than MAX_PLAUSIBLE_SPEED).
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
}

function Rules.newRun(now: number, level: Course.Level?): Run
	return { level = level or Course.LEVELS[1], startedAt = now, checkpoint = 0, times = {} }
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

-- Validates a finish at `now`: (true, seconds) or (false, reason) with reason
-- "checkpoints" (not all taken) or "fast" (a leg was quicker than possible).
function Rules.finish(run: Run, now: number): (boolean, number | string)
	local count = run.level.CHECKPOINT_COUNT
	local minimum = run.level.MIN_LEG_SECONDS
	if run.checkpoint ~= count then
		return false, "checkpoints"
	end
	local previous = run.startedAt
	for k = 1, count + 1 do
		local at = if k <= count then run.times[k] else now
		if type(at) ~= "number" or at - previous < minimum[k] then
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
