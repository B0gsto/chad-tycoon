--!nocheck
--[[
	Harness for the cloud tests (docs/testing-on-roblox.md). tools/cloud_test.py sends ONE Luau Execution task:

		local META = <JSON from cloud_test.py: target, git, versions, assetModels>
		<this file>
		T.file("boot.luau", function() <tests/cloud/boot.luau> end)
		...
		return T.finish()

	so every test file sees `T` and `META`. Tests run in order inside a real Roblox server of the published place
	(no players). A test fails by erroring (T.ok / T.eq / error()); T.skip(reason) skips it.
	T.finish() returns { passed, failed, skipped, failures = { "file > test: message" }, skips, seconds },
	which cloud_test.py reads from the task output.
]]
local T = {
	meta = META or {},
	passed = 0,
	failed = 0,
	skipped = 0,
	failures = {},
	skips = {},
	current = "?",
	started = os.clock(),
}

local function log(line)
	print("[cloud-test] " .. line)
end

-- Error object that marks a skip rather than a failure.
local SKIP = {}

function T.skip(reason)
	error({ [SKIP] = true, reason = tostring(reason) }, 0)
end

function T.ok(cond, message)
	if not cond then
		error(message or "assertion failed", 2)
	end
	return cond
end

function T.eq(actual, expected, message)
	if actual ~= expected then
		error(string.format("%s: expected %s, got %s", message or "values differ", tostring(expected), tostring(actual)), 2)
	end
end

-- Polls fn() until it returns a truthy value or `timeout` seconds pass; returns that value or nil.
function T.waitFor(fn, timeout, interval)
	local deadline = os.clock() + (timeout or 10)
	repeat
		local value = fn()
		if value then
			return value
		end
		task.wait(interval or 0.25)
	until os.clock() > deadline
	return fn()
end

function T.test(name, fn)
	local full = T.current .. " > " .. name
	local t0 = os.clock()
	local ok, err = xpcall(fn, function(e)
		if type(e) == "table" then
			return e
		end
		return tostring(e) .. "\n" .. debug.traceback(nil, 2)
	end)
	local took = string.format("%.2fs", os.clock() - t0)
	if ok then
		T.passed += 1
		log("PASS " .. full .. " (" .. took .. ")")
	elseif type(err) == "table" and err[SKIP] then
		T.skipped += 1
		table.insert(T.skips, full .. ": " .. err.reason)
		log("SKIP " .. full .. ": " .. err.reason)
	else
		local message = if type(err) == "table" then tostring(err.reason or err) else tostring(err)
		T.failed += 1
		table.insert(T.failures, full .. ": " .. message)
		log("FAIL " .. full .. " (" .. took .. "): " .. message)
	end
end

-- Runs one test file's body; an error outside T.test counts as a failure of the file.
function T.file(name, body)
	T.current = name
	local ok, err = pcall(body)
	if not ok then
		T.failed += 1
		table.insert(T.failures, name .. " (file body): " .. tostring(err))
		log("FAIL " .. name .. " (file body): " .. tostring(err))
	end
end

function T.finish()
	local summary = {
		passed = T.passed,
		failed = T.failed,
		skipped = T.skipped,
		failures = T.failures,
		skips = T.skips,
		seconds = math.floor((os.clock() - T.started) * 100) / 100,
	}
	log(string.format("done: %d passed, %d failed, %d skipped", T.passed, T.failed, T.skipped))
	return summary
end
