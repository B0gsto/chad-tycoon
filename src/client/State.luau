-- Client-side store for the latest server snapshot.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Format = require(ReplicatedStorage.Shared.Format)

local State = {}

State.data = nil :: { [string]: any }?
State.changed = Instance.new("BindableEvent")
State.clockOffset = 0
State.receivedAt = 0

function State.set(data: { [string]: any })
	State.data = data
	State.clockOffset = (data.now or os.time()) - os.time()
	State.receivedAt = os.clock()
	State.changed:Fire(data)
end

-- Server unix time estimate.
function State.now(): number
	return os.time() + State.clockOffset
end

-- Seconds since the snapshot arrived (for smooth countdowns between pushes).
function State.age(): number
	return os.clock() - State.receivedAt
end

-- Formats a number honouring the "full numbers" setting.
function State.num(n: number): string
	local data = State.data
	if data and data.settings and data.settings.fullNumbers then
		return Format.commas(n)
	end
	return Format.short(n)
end

function State.money(n: number): string
	return "$" .. State.num(n)
end

return State
