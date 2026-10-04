-- In-game scenarios for smr-harness (D:\PROJS\SMR\smr-harness, PLAN section 8).
-- Run in order: flood_00_new_game starts a fresh colony map, flood_10_rain runs real
-- storms, flood_20_effects floods a basin and checks each gameplay effect live.
-- Flood's table lives behind its mod environment (ModEnvMeta.__index), so it is
-- reached through Mods.Flood.env rather than the harness global table.

local function FL() return Mods and Mods.Flood and Mods.Flood.env and Mods.Flood.env.Flood end

-- Waits until the budgeted redraw has caught up with the model.
local function wait_render(ctx, timeout_ms)
    local s = FL().State
    return ctx:wait_for(function() return (s.render_backlog or 1) == 0 end, timeout_ms or 120000)
end

local function wait_real(ms) Sleep(ms) end

-- Waits for the given number of Flood effect passes (hourly game time).
local function wait_effect_passes(ctx, n, timeout_ms)
    local s = FL().State
    local seen, last = 0, s.last_effects
    return ctx:wait_for(function()
        if s.last_effects ~= last then seen = seen + 1; last = s.last_effects end
        return seen >= n
    end, timeout_ms or 120000)
end

local function no_flood_error(ctx, where)
    local s = FL().State
    ctx:assert(not s.error, where .. ": Flood reports no error (" .. tostring(s.error) .. ")")
    ctx:assert(s.enabled == true, where .. ": Flood simulation running")
end

-- Fresh game, following Planet Dawn's confirmed StartNewGame-equivalent sequence
-- (planet-dawn/tools/pd_render_probe.lua): sponsor "None" avoids an unrelated
-- vanilla rocket/flight race during direct map generation.
local guarded
local function guard_flight()
    guarded = {}
    for _, name in ipairs({ "Flight", "FlightUnderground" }) do
        local flight = rawget(_G, name)
        if type(flight) == "table" and flight.Mark and flight.Unmark and flight.Remark then
            local orig = { class = flight, Mark = flight.Mark, Unmark = flight.Unmark, Remark = flight.Remark }
            guarded[#guarded + 1] = orig
            local function ensure(self)
                for _, k in ipairs({ "objects_to_unmark", "objects_to_mark", "marked_objects" }) do
                    if type(self[k]) ~= "table" then self[k] = {} end
                end
            end
            function flight:Mark(o) ensure(self); return orig.Mark(self, o) end
            function flight:Unmark(o) ensure(self); return orig.Unmark(self, o) end
            function flight:Remark(o) ensure(self); return orig.Remark(self, o) end
        end
    end
end
local function unguard_flight()
    for _, orig in ipairs(guarded or {}) do
        orig.class.Mark, orig.class.Unmark, orig.class.Remark = orig.Mark, orig.Unmark, orig.Remark
    end
    guarded = nil
end

HARNESS.scenario("flood_00_new_game", function(ctx)
    ctx:assert(FL() ~= nil, "Flood mod code loaded")
    if not FL() then ctx:fail("Flood not loaded") end
    ctx:wait_for(function()
        return GetDialog("PGMainMenu") and not (rawget(_G, "IsChangingMap") and IsChangingMap())
    end, 180000)
    DoneGame()
    NewGame()
    InitNewGameMissionParams()
    SetNewGameDefaultSettings("regular", {})
    -- This build keeps mission settings on Game (PreGameMission.lua:920-932).
    Game.idMissionSponsor = "None"
    Game.idCommanderProfile = "None"
    Game.idRivalColonies = {}
    PauseGame("FloodScenario")
    g_CurrentMapParams = { Concrete = 220, Metals = 58, PreciousMetals = 98, Water = 110 }
    guard_flight()
    local ok, err = pcall(GenerateRandomMap, "BlankBig_01", "MAIN", { Seed = -2056210453724019915 })
    ctx:assert(ok, "random map generated: " .. tostring(err))
    if not ok then unguard_flight(); ctx:fail("map generation failed") end
    if rawget(_G, "ShowInGameInterface") then ShowInGameInterface(true) end
    ResumeGame("FloodScenario")
    wait_real(3000)
    unguard_flight()
    ctx:assert(MainMap and MainMap:IsValid() and HasGameLogic(MainMap), "surface map with game logic")
    ctx:assert(CurrentMap == MainMap, "viewing the surface map")
    local F = FL()
    ctx:wait_for(function() return F.State.model ~= false end, 240000)
    no_flood_error(ctx, "after scan")
    local s = F.State
    ctx:assert(s.map == MainMap, "Flood bound to MainMap")
    ctx:record("grid", s.grid and (s.grid.width .. "x" .. s.grid.height) or "none")
    ctx:record("cell_m", s.grid and s.grid.dx / guim or 0)
    ctx:record("basins", s.model and #s.model.nodes or 0)
    ctx:record("hour_ms", const.HourDuration)
    for key, available in pairs(s.features) do
        ctx:assert(available == true, "effect available: " .. key)
    end
    ctx:assert(s.ui and s.ui.window_state ~= "destroying", "test panel shown")
    ctx:capture("new_game")
end)

HARNESS.scenario("flood_10_rain", function(ctx)
    local F = FL()
    local s, H = F.State, F.Hydrology
    no_flood_error(ctx, "start")
    local before = H.Total(s.model)
    s.rain_type = "normal" -- earlier scenarios may have left the panel on toxic
    local ok, err = F.Rain.Start(3)
    ctx:assert(ok == true, "heavy test storm starts: " .. tostring(err))
    ctx:wait_for(function() return g_RainDisaster == "normal" end, 20000)
    ctx:assert(ctx:wait_for(function()
        local btn = s.ui and s.ui.idRain3
        return btn and tostring(btn:GetText()):find("Stop") ~= nil
    end, 15000), "panel shows Stop Heavy")
    SetTimeFactor(const.DefaultTimeFactor * 10)
    local t0 = GameTime()
    ctx:wait_for(function() return GameTime() - t0 >= 3 * const.HourDuration end, 180000)
    local after = H.Total(s.model)
    ctx:record("water_m3_after_3h_heavy", after / 1000)
    ctx:record("visible_pools", s.visible_pools or 0)
    ctx:record("budget", { rain_l = s.model.budget.rain, ground_l = s.model.budget.ground,
        outflow_l = s.model.budget.outflow, evaporation_l = s.model.budget.evaporation,
        infiltration_l = s.model.budget.infiltration })
    ctx:assert(after > before, "rain stores water in basins")
    ctx:assert((s.visible_pools or 0) > 0, "visible pools formed")
    ctx:assert(s.last_nominal_rate == F.Config.RAIN_MM_H[3], "effects see the nominal heavy rate")
    -- Mid-storm: every level moves each redraw, so only bounds are checked here;
    -- completeness is checked once the storm stops.
    local markers = #MainMap:MapGet("map", "FloodWaterMarker")
    local planes = MainMap:MapCount("map", "WaterObj")
    local max_area, max_planes = 0, 0
    for _, entry in pairs(s.markers) do
        if IsValid(entry.obj) then
            max_area = math.max(max_area, entry.obj.applied_area or 0)
            max_planes = math.max(max_planes, #entry.obj:GetWaterPlanes())
        end
    end
    ctx:record("markers", markers)
    ctx:record("water_planes", planes)
    ctx:record("max_marker_area_m2", max_area)
    ctx:record("max_marker_planes", max_planes)
    ctx:record("refresh_ms", s.refresh_ms)
    ctx:record("render_ms_per_marker", s.render_ms_per_marker)
    ctx:record("wet_pools", s.wet_pools)
    ctx:record("render_backlog", s.render_backlog)
    ctx:assert(markers > 0, "water rendered while raining")
    -- Each lake stays within its spill bound (engine tolerance spill_tolerance %).
    local over = 0
    for _, entry in pairs(s.markers) do
        local o = entry.obj
        if IsValid(o) and (o.original_area or 0) > 0
            and (o.applied_area or 0) > o.original_area * (100 + o.spill_tolerance) / 100 + 1 then
            over = over + 1
        end
    end
    ctx:record("lakes_over_bound", over)
    ctx:assert(over == 0, "every lake within its spill bound")
    -- Largest pool for the camera.
    local best
    for _, pool in ipairs(H.Pools(s.model)) do
        if not best or pool.volume > best.volume then best = pool end
    end
    if best then
        local x, y = F.Terrain.LowPoint(s.grid, best.seed)
        ctx:record("largest_pool_m3", best.volume / 1000)
        ctx:record("largest_pool_depth_mm", best.level - s.model.elevations[best.seed])
        ViewObjectRTS(point(x, y):SetTerrainZ(MainMap), 0)
        wait_real(1500)
        ctx:capture("fresh_lake")
    end
    -- Toxic rain contaminates the water.
    ok, err = F.Rain.ToggleType()
    ctx:assert(ok == true and s.rain_type == "toxic", "switched to toxic storm: " .. tostring(err))
    ctx:wait_for(function() return g_RainDisaster == "toxic" end, 20000)
    SetTimeFactor(const.DefaultTimeFactor * 10)
    t0 = GameTime()
    ctx:wait_for(function() return GameTime() - t0 >= 2 * const.HourDuration end, 180000)
    local max_c = 0
    for _, pool in ipairs(H.Pools(s.model)) do max_c = math.max(max_c, pool.concentration) end
    ctx:record("max_toxic_concentration", max_c)
    ctx:assert(max_c > 0, "toxic rain contaminates pools")
    wait_real(1500)
    ctx:capture("toxic_lake")
    ok = F.Rain.Toggle(3)
    ctx:wait_for(function() return not g_RainDisaster end, 20000)
    ctx:assert(s.rain_thread == false and s.rain_strength == 0, "storm stopped from the panel control")
    SetTimeFactor(const.DefaultTimeFactor)
    -- Calm water: the budgeted redraw catches up with every drawn pool.
    ctx:assert(ctx:wait_for(function() return (s.render_backlog or 1) == 0 end, 240000), "redraw caught up after the storm")
    ctx:record("calm_markers", #MainMap:MapGet("map", "FloodWaterMarker"))
    ctx:record("calm_drawn_pools", s.visible_pools)
    ctx:record("calm_refresh_ms", s.refresh_ms)
    ctx:assert(#MainMap:MapGet("map", "FloodWaterMarker") == s.visible_pools, "one marker per drawn pool")
    no_flood_error(ctx, "end")
end)

-- Deepest leaf basin of moderate size: a lake we can fill on purpose.
local function pick_basin(F)
    local s = F.State
    local best
    -- Any dry basin of a few cells or more that can hold water over a colonist's head.
    for _, n in ipairs(s.model.nodes) do
        if n.total == 0 and n.initial_count >= 4 and n.initial_count <= 5000 then
            local depth = n.spill - n.base
            if depth >= 2000 and (not best or depth > best.spill - best.base) then best = n end
        end
    end
    return best
end

local function highest_cell(F)
    local s, top, best = F.State, nil, nil
    for i, z in ipairs(s.model.elevations) do
        local x = (i - 1) % s.grid.width
        local y = (i - 1) // s.grid.width
        if x > 10 and y > 10 and x < s.grid.width - 10 and y < s.grid.height - 10 and (not top or z > top) then
            top, best = z, i
        end
    end
    return best
end

local function at(F, index)
    local x, y = F.Terrain.Position(F.State.grid, index)
    return point(x, y):SetTerrainZ(MainMap)
end

HARNESS.scenario("flood_20_effects", function(ctx)
    local F = FL()
    local s, H, cfg = F.State, F.Hydrology, F.Config
    no_flood_error(ctx, "start")
    local basin = pick_basin(F)
    ctx:assert(basin ~= nil, "found a deep basin to flood")
    if not basin then ctx:fail("no suitable basin") end
    ctx:record("basin_depth_mm", basin.spill - basin.base)
    ctx:record("basin_cells", basin.initial_count)
    H.Import(s.model, { { basin.seed, basin.capacity * 0.95, 0 } })
    F.Water.Snapshot()
    local lake = at(F, basin.seed)
    local depth = F.Water.DepthAt(lake:xy())
    ctx:record("lake_depth_mm", depth)
    ctx:assert(depth >= cfg.DROWNING_DEPTH_MM, "lake centre deeper than a colonist")
    local dry = at(F, highest_cell(F))
    ctx:assert(F.Water.DepthAt(dry:xy()) == 0, "high ground is dry")

    -- Test subjects.
    local flooded = PlaceBuildingIn("MoistureVaporator", MainMap)
    flooded:SetPos(lake)
    local exposed = PlaceBuildingIn("MoistureVaporator", MainMap)
    exposed:SetPos(dry)
    local hub = PlaceBuildingIn("ShuttleHub", MainMap)
    hub:SetPos(dry + point(60 * guim, 0, 0))
    local rover = PlaceObject("RCRover", nil, MainMap)
    rover:SetPos(lake)
    local colonist = GenerateColonistData(MainCity)
    Colonist:new(colonist, MainMap)
    colonist:SetPos(lake)
    wait_real(1000)
    ctx:assert(table.find(MainCity.labels.Building, flooded) ~= nil, "test building registered")
    ctx:assert(table.find(MainCity.labels.Rover, rover) ~= nil, "test rover registered")
    ctx:assert(table.find(MainCity.labels.Colonist, colonist) ~= nil, "test colonist registered")
    ViewObjectRTS(lake, 0)

    -- Phase A: fresh heavy storm.
    exposed.accumulated_maintenance_points = exposed.maintenance_threshold_current // 2
    local dust_before = exposed.accumulated_maintenance_points
    local health_before, sanity_before = colonist.stat_health, colonist.stat_sanity
    s.rain_type = "normal"
    local ok, err = F.Rain.Start(3)
    ctx:assert(ok == true, "fresh heavy storm: " .. tostring(err))
    SetTimeFactor(const.DefaultTimeFactor * 10)
    wait_effect_passes(ctx, 2)
    ctx:expect_eq(flooded.suspended, "Flooded", "flooded building suspended")
    ctx:assert(flooded:GetUIWarning() ~= nil, "flooded building shows a warning")
    ctx:expect_eq(exposed.suspended, false, "dry building keeps working")
    ctx:assert(exposed.accumulated_maintenance_points < dust_before, "fresh rain washed dust off: "
        .. dust_before .. " -> " .. exposed.accumulated_maintenance_points)
    ctx:expect_eq(hub.suspended, "FloodStormGrounded", "heavy storm grounds the shuttle hub")
    local labels = MainCity.label_modifiers
    ctx:assert(labels.Drone and labels.Drone.FloodRainDrones ~= nil, "drones slowed by rain")
    ctx:assert(labels.CargoShuttle and labels.CargoShuttle.FloodRainShuttles ~= nil, "shuttles slowed by rain")
    ctx:assert(rover:FindModifier("FloodDeepWater", "move_speed") ~= nil or rover.command == "Malfunction",
        "rover slowed (or already broken down) in deep water")
    ctx:record("rover_command", rover.command)
    ctx:record("colonist_health", { before = health_before, after = colonist.stat_health })
    ctx:assert(not IsValid(colonist) or colonist:IsDying() or colonist.stat_health < health_before,
        "colonist over their head loses health")
    -- Take them out before they drown: the game's first-death popup has two
    -- choices and would pause every later scenario.
    if IsValid(colonist) then DoneObject(colonist) end
    ctx:capture("effects_fresh")

    -- Phase B: toxic storm corrodes and stresses.
    local points_before = exposed.accumulated_maintenance_points
    ok, err = F.Rain.ToggleType()
    ctx:assert(ok == true, "switched to toxic: " .. tostring(err))
    local dry_colonist = GenerateColonistData(MainCity)
    Colonist:new(dry_colonist, MainMap)
    dry_colonist:SetPos(dry + point(0, 30 * guim, 0))
    local dry_sanity = dry_colonist.stat_sanity
    wait_effect_passes(ctx, 2)
    ctx:assert(exposed.accumulated_maintenance_points > points_before, "toxic rain corrodes: "
        .. points_before .. " -> " .. exposed.accumulated_maintenance_points)
    ctx:assert(not IsValid(dry_colonist) or dry_colonist.stat_sanity < dry_sanity,
        "suited colonist stressed by toxic rain")
    ctx:record("dry_colonist", { sanity_before = dry_sanity, sanity_after = IsValid(dry_colonist) and dry_colonist.stat_sanity,
        health = IsValid(dry_colonist) and dry_colonist.stat_health })

    -- Storm ends: hubs fly again, slowdowns lift.
    F.Rain.Toggle(3)
    ctx:wait_for(function() return not g_RainDisaster end, 20000)
    wait_real(1500)
    ctx:assert(hub.suspended == false, "shuttle hub cleared after the storm")
    ctx:assert(not (labels.Drone and labels.Drone.FloodRainDrones), "drone rain slowdown lifted")

    -- Disable restores object state; enable resumes.
    F.Lifecycle.Disable()
    ctx:expect_eq(flooded.suspended, false, "disable lifts flood suspension")
    ctx:assert(rover:FindModifier("FloodDeepWater", "move_speed") == nil, "disable removes rover modifier")
    ctx:expect_eq(#MainMap:MapGet("map", "FloodWaterMarker"), 0, "disable removes water markers")
    F.Lifecycle.Disable()
    ctx:assert(true, "second disable is harmless")
    ctx:assert(F.Lifecycle.Enable() == true, "re-enable")
    -- The first pass after enabling only starts the hourly clock.
    wait_effect_passes(ctx, 2)
    ctx:expect_eq(flooded.suspended, "Flooded", "re-enabled: still-flooded building suspended again")
    ctx:assert(H.Total(s.model) > 0, "water survived disable/enable")
    SetTimeFactor(const.DefaultTimeFactor)
    no_flood_error(ctx, "end")
    for _, obj in ipairs({ dry_colonist, rover, flooded, exposed, hub }) do
        if IsValid(obj) then DoneObject(obj) end
    end
end)


-- Save, then load: the simulation thread is stopped for the save and restarted,
-- markers are redrawn, and loading restores the numerical water state. The test
-- save is deleted afterwards.
HARNESS.scenario("flood_30_save_load", function(ctx)
    local F = FL()
    local s, H = F.State, F.Hydrology
    no_flood_error(ctx, "start")
    if H.Total(s.model) <= 0 then
        H.Import(s.model, { { s.model.nodes[1].seed, 1000000, 0 } })
    end
    local water_before = H.Total(s.model)
    ctx:record("water_m3_before", water_before / 1000)
    -- The test colony has sponsor "None", whose filter refuses to load a save
    -- (Lua/Savegame.lua:33-40); save it under a real sponsor.
    Game.idMissionSponsor = "IMM"
    local err, name = SaveGame("FloodHarnessTest", {})
    ctx:assert(not err, "game saved: " .. tostring(err))
    ctx:record("save_name", tostring(name))
    ctx:assert(s.saving == false, "save finished")
    ctx:assert(ctx:wait_for(function() return s.thread and IsValidThread(s.thread) and s.enabled end, 30000),
        "simulation restarted after the save")
    ctx:assert(ctx:wait_for(function() return #MainMap:MapGet("map", "FloodWaterMarker") > 0 end, 120000),
        "water redrawn after the save")
    if err then return end
    err = LoadGame(name)
    ctx:assert(not err, "game loaded: " .. tostring(err))
    if err then ctx:record("delete_save", tostring(DeleteGame(name))); return end
    F = FL()
    s, H = F.State, F.Hydrology
    ctx:assert(ctx:wait_for(function() return s.model ~= false and s.map == MainMap end, 240000), "flood rebuilt after load")
    no_flood_error(ctx, "after load")
    local water_after = H.Total(s.model)
    ctx:record("water_m3_after_load", water_after / 1000)
    ctx:assert(math.abs(water_after - water_before) <= water_before * 0.02 + 1000,
        "saved water restored on load (within 2 %)")
    ctx:assert(ctx:wait_for(function() return #MainMap:MapGet("map", "FloodWaterMarker") > 0 end, 120000),
        "water redrawn after load")
    ctx:capture("after_load")
    ctx:record("delete_save", tostring(DeleteGame(name)))
end)
