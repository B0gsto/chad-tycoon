--!strict
-- Number and time formatting. Pure Luau so it can be unit-tested with Lune.

local Format = {}

local SUFFIXES = {
	"",
	"K",
	"M",
	"B",
	"T",
	"Qa",
	"Qi",
	"Sx",
	"Sp",
	"Oc",
	"No",
	"Dc",
	"Ud",
	"Dd",
	"Td",
	"Qad",
	"Qid",
	"Sxd",
	"Spd",
	"Ocd",
	"Nod",
	"Vg",
}

-- 1234 -> "1.23K", 999 -> "999", 1e6 -> "1.00M"
function Format.short(n: number): string
	if n ~= n or n == math.huge or n == -math.huge then
		return "0"
	end
	local sign = if n < 0 then "-" else ""
	n = math.abs(n)
	if n < 1000 then
		return sign .. tostring(math.floor(n))
	end
	local index = math.floor(math.log10(n) / 3)
	if index >= #SUFFIXES then
		return sign .. string.format("%.2e", n)
	end
	local scaled = n / 10 ^ (index * 3)
	-- log10 can round up just below a power of 1000 (e.g. 0.99T); step back.
	if scaled < 1 and index > 1 then
		index -= 1
		scaled = n / 10 ^ (index * 3)
	end
	-- Truncate (not round) so displayed balances never overstate what you have.
	scaled = math.floor(scaled * 100) / 100
	return sign .. string.format("%.2f", scaled) .. SUFFIXES[index + 1]
end

-- 1234567 -> "1,234,567". Very large numbers fall back to short form.
function Format.commas(n: number): string
	if n ~= n then
		return "0"
	end
	if math.abs(n) >= 1e15 then
		return Format.short(n)
	end
	local sign = if n < 0 then "-" else ""
	local digits = tostring(math.floor(math.abs(n)))
	local out = digits:reverse():gsub("(%d%d%d)", "%1,"):reverse()
	if out:sub(1, 1) == "," then
		out = out:sub(2)
	end
	return sign .. out
end

function Format.money(n: number): string
	return "$" .. Format.short(n)
end

function Format.multiplier(n: number): string
	return string.format("%.1fx", n)
end

-- 75 -> "1:15", 3725 -> "1:02:05"
function Format.time(seconds: number): string
	seconds = math.max(0, math.floor(seconds))
	local h = seconds // 3600
	local m = (seconds % 3600) // 60
	local s = seconds % 60
	if h > 0 then
		return string.format("%d:%02d:%02d", h, m, s)
	end
	return string.format("%d:%02d", m, s)
end

-- Always "HH:MM:SS" (for unlocker screens).
function Format.clock(seconds: number): string
	seconds = math.max(0, math.floor(seconds))
	return string.format("%02d:%02d:%02d", seconds // 3600, (seconds % 3600) // 60, seconds % 60)
end

function Format.date(timestamp: number): string
	local t = os.date("*t", math.floor(timestamp)) :: any
	return string.format("%d/%d/%d", t.month, t.day, t.year)
end

return Format
