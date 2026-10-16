-- The private TEST experience (deploy/test-target.json, docs/agent-playtest.md).
--
-- isTest() is the security boundary of the agent test bridge (Server.TestBridge,
-- Client.TestBridge): it is true only in a running server or client of the TEST universe.
-- The live game (deploy/target.json) and unpublished Studio places (GameId 0) never match,
-- so the bridge stays completely inert there. Only the holder of the Open Cloud API key can
-- publish the MessagingService messages that drive it.

local TestEnv = {}

-- Universe id of the TEST experience (deploy/test-target.json "universeId"); 0 = not set up yet.
TestEnv.TEST_UNIVERSE_ID = 10771313560

-- The live experience; never the test one, whatever TEST_UNIVERSE_ID says.
TestEnv.LIVE_UNIVERSE_ID = 10769596890

function TestEnv.isTest(): boolean
	local id = TestEnv.TEST_UNIVERSE_ID
	return id ~= 0 and id ~= TestEnv.LIVE_UNIVERSE_ID and game.GameId == id
end

return TestEnv
