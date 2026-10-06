--!strict
--[[
	SessionLock: pure decision logic for DataStore session locking.

	A profile stores `_lock = { jobId, at }`. A server may only load/save a
	profile it holds the lock for, which prevents two servers (e.g. after a fast
	server hop) from overwriting each other's progress or duplicating purchases.
	Kept pure so it can be unit-tested with Lune.
]]

local SessionLock = {}

-- A lock not refreshed for this long is considered abandoned (server crashed).
-- Autosave refreshes the lock far more often than this.
SessionLock.STALE_SECONDS = 300

export type Lock = { jobId: string, at: number }

export type Decision = "acquire" | "wait" | "steal"

-- Decide whether `jobId` may take the lock at time `now`.
--   acquire: free, ours already, or stale
--   wait:    another live server holds it; retry shortly
--   steal:   we waited long enough; take it anyway (the other server will
--            notice on its next save and stop writing)
function SessionLock.decide(existing: Lock?, jobId: string, now: number, waitedSeconds: number, maxWait: number): Decision
	if existing == nil or type(existing) ~= "table" or type(existing.jobId) ~= "string" then
		return "acquire"
	end
	if existing.jobId == jobId then
		return "acquire"
	end
	if type(existing.at) ~= "number" or now - existing.at >= SessionLock.STALE_SECONDS then
		return "acquire"
	end
	if waitedSeconds >= maxWait then
		return "steal"
	end
	return "wait"
end

-- Whether a save from `jobId` is still allowed (we still own the lock).
function SessionLock.owns(existing: Lock?, jobId: string): boolean
	return existing ~= nil and type(existing) == "table" and existing.jobId == jobId
end

return SessionLock
