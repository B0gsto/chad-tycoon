--[[
	Intro: server side of the opening cutscene (client: Client.Intro.Cutscene).

	The saved profile field introSeen says whether the player has watched it.
	When a session starts it is copied to the Player attribute "IntroSeen";
	the client plays the cutscene when that is false and sends the "IntroSeen"
	action when it ends (finished or skipped), which saves it as true.
]]

local Tycoon = require(script.Parent.Tycoon)

local Intro = {}

-- Call before Tycoon.addPlayer sends the first State snapshot.
function Intro.onSessionStart(player: Player, profile: { [string]: any })
	player:SetAttribute("IntroSeen", profile.introSeen == true)
end

function Intro.init()
	Tycoon.addAction("IntroSeen", function(session)
		if not session.alive then
			return
		end
		session.player:SetAttribute("IntroSeen", true)
		if session.profile.introSeen ~= true then
			session.profile.introSeen = true
			Tycoon.markDirty(session)
		end
	end)
end

return Intro
