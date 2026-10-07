--!strict
--[[
	Rules: the pure parts of a Parkour run (no Roblox dependencies, unit-tested).

	A run records its Course level and the server time it started. There are no checkpoints:
	a run is one leg from the map's start deck to its finish deck, and a fall only sends the
	runner back to the start deck (the clock keeps running). The finish counts only when the
	run took at least the level's MIN_SECONDS (its PATH_LENGTH at MAX_PLAUSIBLE_SPEED: nobody
	crosses the map faster). That minimum assumes WalkSpeed 16: a run that wore the speed coil
	passes `speedScale` (28/16) to Rules.finish so it may be that much quicker. A map bought
	with a paid Skip Map (Rules.skip) has no minimum.
]]

local Course = require(script.Parent.Course)

local Rules = {}

export type Run = {
	-- The Course level being run (Course.LEVELS[i]).
	level: Course.Level,
	startedAt: number,
	-- The map was skipped with a paid Skip Map: no minimum time.
	skipped: boolean,
}

function Rules.newRun(now: number, level: Course.Level?): Run
	return { level = level or Course.LEVELS[1], startedAt = now, skipped = false }
end

-- Marks the run's map as skipped (paid Skip Map): Rules.finish accepts it at any time.
function Rules.skip(run: Run)
	run.skipped = true
end

-- Validates a finish at `now`: (true, seconds) or (false, "fast") when the run was quicker
-- than possible. `speedScale` (default 1) is how much faster than WalkSpeed 16 the runner
-- could move.
function Rules.finish(run: Run, now: number, speedScale: number?): (boolean, number | string)
	local scale = if type(speedScale) == "number" and speedScale >= 1 then speedScale else 1
	local minimum = run.level.MIN_SECONDS
	if not run.skipped and (type(minimum) ~= "number" or now - run.startedAt < minimum / scale) then
		return false, "fast"
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
