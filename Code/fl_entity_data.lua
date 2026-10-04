-- Entity data for Flood's ice plate (Entities/FL_IcePlate.entjson): a 90 x 90 m,
-- 1 m thick box with collision on every face and a walkable top, the same plate
-- Martian Waters uses for its frozen water. Loaded through metadata 'entities'.
if Platform.ged then return end
EntityData["FL_IcePlate"] = {
    collision_meshes = "open",
    editor_artset = "Mods",
    editor_category = "Common",
    editor_subcategory = "Common",
}
