--[[
	Fx.Highlights: one budget for every Highlight in the world. Roblox draws at most 31 at
	once and silently drops the rest, so the client keeps the total at or under CAP and
	switches off the least important ones first.

	  Highlights.claim(h, priority, wanted?)  registers `h` (again: sets its priority);
	                                          wanted defaults to h.Enabled on the first claim
	  Highlights.want(h, on)                  the owner's "show it" in place of h.Enabled
	  Highlights.PRIORITY                     the classes below

	Every Highlight that lands in Workspace without a claim (the server's "PastelOverlay"
	booth washes on all six plots, anything new) is claimed at Other. Among the wanted ones the
	highest priority wins, then the newest. Worst case today: 12 booth washes (2 Smashers x 6
	plots), 8 pen-floor crates (Fx.Crates' MAX_CRATES), 2 Smasher crates, the held crate and
	CardioChase's outline = 24; past CAP the other plots' booth washes go first.
]]

local Workspace = game:GetService("Workspace")

local Highlights = {}

Highlights.CAP = 24
Highlights.PRIORITY = {
	Other = 0, -- unclaimed: other plots' booth washes, anything new
	Booth = 1, -- the local plot's Smasher booth washes
	PenCrate = 2, -- + rank / 10: rarer pen-floor crates keep theirs longer
	SmasherCrate = 3, -- the crate standing in a Smasher
	Held = 4, -- the crate in the player's hands
	Ritual = 5, -- a Smasher crate shaking open (its always-on-top silhouette)
	Chase = 6, -- CardioChase's red outline
}

type Entry = { priority: number, wanted: boolean, seq: number }

local entries: { [Highlight]: Entry } = {}
local seq = 0
local dirty = false

local function refresh()
	dirty = false
	local list: { Highlight } = {}
	for h, e in entries do
		if h.Parent == nil then
			entries[h] = nil
		elseif e.wanted then
			table.insert(list, h)
		elseif h.Enabled then
			h.Enabled = false
		end
	end
	table.sort(list, function(a: Highlight, b: Highlight): boolean
		local ea, eb = entries[a], entries[b]
		if ea.priority ~= eb.priority then
			return ea.priority > eb.priority
		end
		return ea.seq > eb.seq
	end)
	for i, h in list do
		local on = i <= Highlights.CAP
		if h.Enabled ~= on then
			h.Enabled = on
		end
	end
end

local function schedule()
	if not dirty then
		dirty = true
		task.defer(refresh)
	end
end

function Highlights.claim(h: Highlight, priority: number, wanted: boolean?): Highlight
	local e = entries[h]
	if e then
		e.priority = priority
		if wanted ~= nil then
			e.wanted = wanted
		end
	else
		seq += 1
		entries[h] = { priority = priority, wanted = if wanted == nil then h.Enabled else wanted, seq = seq }
		pcall(function()
			h.Destroying:Once(function()
				entries[h] = nil
				schedule()
			end)
			h.AncestryChanged:Connect(schedule)
		end)
	end
	schedule()
	return h
end

function Highlights.want(h: Highlight, on: boolean)
	local e = entries[h]
	if not e then
		Highlights.claim(h, Highlights.PRIORITY.Other, on)
	elseif e.wanted ~= on then
		e.wanted = on
		schedule()
	end
end

-- The catch-all: whatever nobody claimed counts at Other.
local function adopt(d: Instance)
	if d:IsA("Highlight") and not entries[d] then
		Highlights.claim(d, Highlights.PRIORITY.Other)
	end
end
pcall(function()
	Workspace.DescendantAdded:Connect(adopt)
	for _, d in Workspace:GetDescendants() do
		adopt(d)
	end
end)

return Highlights
