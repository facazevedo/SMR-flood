-- Save compatibility scenarios for smr-harness. Not part of the suite: run by
-- name, loaded together with flood_ingame.lua (its helpers, FloodScenarioKit),
-- with Flood switched between them (TurnModOff/TurnModOn + reload --full):
--   Flood on:  flood_compat_a_save_with_flood    (water, ice, flooded building, slowed rover; save)
--   Flood off: flood_compat_b_load_without_flood (load that save: nothing of Flood left behind)
--   Flood off: flood_compat_c_save_without_flood (a colony that never had Flood; save)
--   Flood on:  flood_compat_d_load_with_flood    (load it: Flood starts on the old save)

local K = rawget(_G, "FloodScenarioKit")
local SAVE_WITH, SAVE_WITHOUT = "FloodCompatWith", "FloodCompatWithout"

local function flood_loaded() return table.find(ModsLoaded or {}, "id", "Flood") ~= nil end

-- The test colonies have sponsor "None", whose filter refuses to load a save
-- (Lua/Savegame.lua:33-40); save them under a real sponsor (as flood_30 does).
local function save(name)
    Game.idMissionSponsor = "IMM"
    return SaveGame(name, {})
end

-- Random story events open popups with choices that pause the game and that
-- the harness does not answer; these colonies use the vanilla game rule that
-- switches them off (IsStoryBitsDisabled, MarsStoryBits.lua:33-35).
local function no_story_events()
    Game.game_rules = Game.game_rules or {}
    Game.game_rules.StoryBitsDisabled = true
end

local function find_save(display_name)
    local err, list = Savegame.ListForTag("savegame")
    if err then return nil, err end
    local best
    for _, entry in ipairs(list or {}) do
        if entry.displayname == display_name and (not best or (entry.timestamp or 0) > (best.timestamp or 0)) then
            best = entry
        end
    end
    return best and best.savename
end

local function delete_saves(display_name)
    local name = find_save(display_name)
    while name do
        DeleteGame(name)
        local next_name = find_save(display_name)
        if next_name == name then break end
        name = next_name
    end
end

-- A save that lists a mod which is not loaded makes vanilla ask "The following
-- mods are missing or outdated ... Load anyway / Cancel" (SavegameMetadata.lua:
-- 344-355, LoadAnyway :112-120). A player answers "Load anyway"; the hidden
-- test game cannot click, so the scenario sets vanilla's own switch for that
-- answer (config.SkipPromptLoadAnyway) around the load and records the prompt.
local function load_save(ctx, display_name)
    local name, err = find_save(display_name)
    ctx:assert(name ~= nil, "save found: " .. display_name .. " " .. tostring(err))
    if not name then ctx:fail("no save " .. display_name) end
    local real_load_anyway, prompts = LoadAnyway, {}
    LoadAnyway = function(text, ...)
        prompts[#prompts + 1] = string.sub(_InternalTranslate(text), 1, 200)
        return real_load_anyway(text, ...)
    end
    local skip = config.SkipPromptLoadAnyway
    config.SkipPromptLoadAnyway = true
    local load_err = LoadGame(name)
    config.SkipPromptLoadAnyway = skip
    LoadAnyway = real_load_anyway
    ctx:record("load_prompts", prompts)
    ctx:assert(not load_err, "game loaded: " .. tostring(load_err))
    if load_err then ctx:fail("load failed") end
    ctx:assert(ctx:wait_for(function()
        return MainMap and MainMap:IsValid() and GameState.gameplay and not IsChangingMap()
    end, 120000), "loaded map in gameplay")
    return name
end

-- Lets game time run (10x) and returns how far it advanced.
local function run_game(ctx, real_ms)
    local t0 = GameTime()
    SetTimeFactor(const.DefaultTimeFactor * 10)
    local stop = RealTime() + real_ms
    while RealTime() < stop do
        if K.popup_blocking(ctx) then break end
        Sleep(500)
    end
    SetTimeFactor(const.DefaultTimeFactor)
    return GameTime() - t0
end

-- Everything a save could carry from Flood: objects of its classes (or their
-- missing-class stand-ins), suspensions, speed modifiers.
local function flood_leftovers()
    local found = { missing_class_objects = #(MainMap:MapGet("map", "UnpersistedMissingClass") or {}),
        flood_objects = 0, suspended = 0, label_modifiers = 0, rover_modifiers = 0 }
    for _, class in ipairs({ "FloodWaterMarker", "FloodIcePlate" }) do
        if g_Classes[class] then found.flood_objects = found.flood_objects + #(MainMap:MapGet("map", class) or {}) end
    end
    for _, bld in ipairs(MainCity.labels.Building or {}) do
        if bld.suspended == "Flooded" or bld.suspended == "FloodStormGrounded" then found.suspended = found.suspended + 1 end
    end
    for _, modifiers in pairs(MainCity.label_modifiers or {}) do
        for id in pairs(modifiers) do
            if tostring(id):find("Flood", 1, true) then found.label_modifiers = found.label_modifiers + 1 end
        end
    end
    for _, rover in ipairs(MainCity.labels.Rover or {}) do
        for _, list in pairs(rover.modifications or {}) do
            for _, m in ipairs(list) do
                if tostring(m.id):find("Flood", 1, true) then found.rover_modifiers = found.rover_modifiers + 1 end
            end
        end
    end
    return found
end

HARNESS.scenario("flood_compat_a_save_with_flood", function(ctx)
    ctx:assert(K ~= nil, "flood_ingame.lua helpers loaded")
    local F = K and K.FL()
    ctx:assert(F ~= nil, "Flood is on")
    if not F then ctx:fail("Flood not loaded") end
    delete_saves(SAVE_WITH)
    K.new_colony(ctx)
    no_story_events()
    local s, cfg = F.State, F.Config
    cfg.ICE_PLANET_COLD = false
    ctx:assert(ctx:wait_for(function() K.popup_blocking(ctx); return s.model ~= false end, 240000), "terrain read")
    local basin = K.pick_basin(ctx, F)
    if not basin then ctx:fail("no suitable basin") end
    K.pour(ctx, F, { { basin.seed, basin.capacity * 0.9, 0 } })
    F.Water.Snapshot()
    local lake = K.at(F, basin.seed)
    local flooded = PlaceBuildingIn("MoistureVaporator", MainMap)
    flooded:SetPos(lake)
    local rover = PlaceObject("RCRover", nil, MainMap)
    rover:SetPos(lake)
    ctx:assert(ctx:wait_for(function() return next(s.markers) ~= nil end, 180000), "lakes drawn")
    -- Flooding and the rover slowdown come with the effect passes. Then freeze:
    -- a rover on ice is (correctly) not slowed, so its modifier is checked first.
    SetTimeFactor(const.DefaultTimeFactor * 10)
    local wet = ctx:wait_for(function()
        K.popup_blocking(ctx)
        return flooded.suspended == "Flooded" and rover:FindModifier("FloodDeepWater", "move_speed")
    end, 300000)
    ctx:assert(wet, "flooded building suspended and rover slowed")
    FreezeEntireMap()
    local iced = ctx:wait_for(function() K.popup_blocking(ctx); return (s.ice_plates or 0) > 0 end, 300000)
    SetTimeFactor(const.DefaultTimeFactor)
    ctx:record("before_save", { suspended = tostring(flooded.suspended), ice_plates = s.ice_plates,
        rover_slowed = rover:FindModifier("FloodDeepWater", "move_speed") ~= nil, markers = table.count(s.markers) })
    ctx:assert(iced, "ice plates in place")

    local err, name = save(SAVE_WITH)
    ctx:assert(not err, "game saved: " .. tostring(err))
    ctx:record("save_name", tostring(name))
    -- Right after the save Flood's state is back (PostSave, restart).
    ctx:assert(flooded.suspended == "Flooded", "flooded building suspended again after the save")
    ctx:assert(ctx:wait_for(function() return s.enabled and next(s.markers) ~= nil end, 120000),
        "Flood running and lakes drawn again after the save")
    -- Ice plates are removed before the save (fl_water.lua W.Clear) and laid again after it.
    SetTimeFactor(const.DefaultTimeFactor * 10)
    ctx:assert(ctx:wait_for(function() K.popup_blocking(ctx); return #(MainMap:MapGet("map", "FloodIcePlate") or {}) > 0 end, 120000),
        "ice plates laid again after the save")
    SetTimeFactor(const.DefaultTimeFactor)
end)

HARNESS.scenario("flood_compat_b_load_without_flood", function(ctx)
    ctx:assert(K ~= nil, "flood_ingame.lua helpers loaded")
    ctx:assert(not flood_loaded() and not g_Classes.FloodWaterMarker, "Flood is off")
    load_save(ctx, SAVE_WITH)
    Sleep(3000)
    local found = flood_leftovers()
    ctx:record("leftovers_after_load", found)
    ctx:assert(found.missing_class_objects == 0, "no objects of Flood's classes survive the load")
    ctx:assert(found.suspended == 0, "no building left suspended by Flood")
    ctx:assert(found.label_modifiers == 0 and found.rover_modifiers == 0, "no Flood speed modifiers")
    ctx:record("map_fields", { fl_saved = type(MainMap.fl_saved), fl_test_cold_wave = tostring(MainMap.fl_test_cold_wave),
        fl_test_terraform = type(MainMap.fl_test_terraform) })
    local advanced = run_game(ctx, 20000)
    ctx:record("game_ms_advanced", advanced)
    ctx:assert(advanced > const.HourDuration, "the game runs on (over an hour of game time)")
    ctx:record("leftovers_after_running", flood_leftovers())
    -- Saving again without Flood works too.
    local err = save(SAVE_WITH .. "Resaved")
    ctx:assert(not err, "re-saved without Flood: " .. tostring(err))
    delete_saves(SAVE_WITH .. "Resaved")
    delete_saves(SAVE_WITH)
end)

HARNESS.scenario("flood_compat_c_save_without_flood", function(ctx)
    ctx:assert(K ~= nil and not flood_loaded() and not g_Classes.FloodWaterMarker, "Flood is off")
    delete_saves(SAVE_WITHOUT)
    K.new_colony(ctx)
    no_story_events()
    run_game(ctx, 5000)
    local err = save(SAVE_WITHOUT)
    ctx:assert(not err, "game saved without Flood: " .. tostring(err))
end)

HARNESS.scenario("flood_compat_d_load_with_flood", function(ctx)
    local F = flood_loaded() and K and K.FL()
    ctx:assert(F, "Flood is on")
    if not F then ctx:fail("Flood not loaded") end
    load_save(ctx, SAVE_WITHOUT)
    local s = F.State
    ctx:record("map_fields", { fl_saved = tostring(MainMap.fl_saved), fl_test_cold_wave = tostring(MainMap.fl_test_cold_wave) })
    F.Config.ICE_PLANET_COLD = false
    ctx:assert(ctx:wait_for(function()
        K.popup_blocking(ctx)
        return s.enabled and s.map == MainMap and s.model ~= false
    end, 240000), "Flood started on a save made without it and read the terrain")
    ctx:record("flood_state", { enabled = s.enabled, error = tostring(s.error), bound = s.map == MainMap,
        model = s.model ~= false, rebuild_job = s.rebuild_job ~= false, thread = s.thread and IsValidThread(s.thread) or false,
        pacer = s.paused_thread and IsValidThread(s.paused_thread) or false, saving = s.saving,
        gameplay = GameState.gameplay == true, changing_map = IsChangingMap(), paused = IsPaused(),
        terrain_rebuild = s.last_terrain_rebuild and s.last_terrain_rebuild.phase or "none", status = tostring(s.status) })
    if not s.model then ctx:fail("no model") end
    ctx:assert(not s.error, "no Flood error: " .. tostring(s.error))
    ctx:assert(F.Hydrology.Total(s.model) == 0, "no water from nowhere: the old save starts dry")
    local basin = K.pick_basin(ctx, F)
    if not basin then ctx:fail("no suitable basin") end
    K.pour(ctx, F, { { basin.seed, basin.capacity * 0.6, 0 } })
    ctx:assert(ctx:wait_for(function() return next(s.markers) ~= nil end, 180000), "water drawn on the old save")
    local advanced = run_game(ctx, 10000)
    ctx:assert(advanced > 0 and s.enabled and not s.error, "Flood keeps running: " .. tostring(s.error))
    delete_saves(SAVE_WITHOUT)
end)
