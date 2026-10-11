--[[
	Intro: server side of the opening cutscene (client: Client.Intro.Cutscene).

	The saved profile field introSeen says whether the player has watched it.
	When a session starts it is copied to the Player attribute "IntroSeen";
	the client plays the cutscene when that is false and sends the "IntroSeen"
	action when it ends (finished or skipped), which saves it as true. The action
	also says how it ended ({ skipped = boolean, seconds = story seconds played }),
	which goes to Analytics once.
]]

local Analytics = require(script.Parent.Analytics)
local Tycoon = require(script.Parent.Tycoon)

-- Longest story time the client may report (the cutscene's watchdog ends it by then).
local MAX_SECONDS = 60

local Intro = {}

-- Call before Tycoon.addPlayer sends the first State snapshot.
function Intro.onSessionStart(player: Player, profile: { [string]: any })
	player:SetAttribute("IntroSeen", profile.introSeen == true)
end

function Intro.init()
	Tycoon.addAction("IntroSeen", function(session, data)
		if not session.alive then
			return
		end
		session.player:SetAttribute("IntroSeen", true)
		if session.profile.introSeen ~= true then
			session.profile.introSeen = true
			local seconds = data.seconds
			if type(data.skipped) == "boolean" and type(seconds) == "number" and seconds == seconds then
				Analytics.intro(session, data.skipped, math.clamp(seconds, 0, MAX_SECONDS))
			end
			Tycoon.markDirty(session)
		end
	end)
end

return Intro
