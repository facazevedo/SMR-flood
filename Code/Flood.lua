-- High-level lifecycle wiring only. Domain modules are loaded by metadata.lua.
local F = Flood
function OnMsg.NewMapLoaded() F.Lifecycle.Enable() end
function OnMsg.ChangeMapDone() F.Lifecycle.Enable() end
function OnMsg.PostLoadGame() F.Lifecycle.Enable() end
function OnMsg.DoneMap(map) F.Lifecycle.MapDone(map) end
function OnMsg.SaveGameStart() F.Lifecycle.SaveStart() end
function OnMsg.SaveGameDone() F.Lifecycle.SaveDone() end
function OnMsg.RainDisasterStart() F.Lifecycle.Advance() end
function OnMsg.RainDisasterEnd() F.Lifecycle.Advance() end
function OnMsg.LandscapeCompleted(landscape)
    if landscape and landscape.map == F.State.map then F.State.dirty = true end
end
function OnMsg.ClassesBuilt() F.Lifecycle.Enable() end

