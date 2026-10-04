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
-- Announced terrain edits; the terrain module re-reads only their area.
-- LandscapeCompleted fires after the landscape is deleted: its pass_bbox (world
-- box, Landscaping.lua:259-264) is still on the table.
function OnMsg.LandscapeCompleted(landscape)
    if landscape then F.Terrain.MarkChanged(landscape.map, landscape.pass_bbox, "landscaping") end
end
-- Meteor craters, landscape lakes, crystals, level prefabs (PrefabMarker.lua:930).
function OnMsg.PrefabPlaced(map, name, objs, inv_bbox) F.Terrain.MarkChanged(map, inv_bbox, "prefab") end
-- Domes and other buildings with height surfaces apply them on completion.
function OnMsg.ConstructionComplete(bld)
    if IsValid(bld) then F.Terrain.MarkChanged(bld:GetMap(), bld:GetObjectBBox(), "construction complete") end
end
function OnMsg.ClassesBuilt() F.Lifecycle.Enable() end

