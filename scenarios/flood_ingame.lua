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
-- A modal popup pauses the game. Proven-safe ones are answered by the harness's
-- own UI policy (smr-harness lua/ui.lua, SMR_UI.settle); anything else is
-- recorded and ends the wait instead of timing out.
local function smr_ui()
    local ui = rawget(_G, "SMR_UI")
    if ui == nil then
        -- The harness keeps SMR_UI behind the global metatable. Before its UI
        -- helper is loaded, this lookup logs a harmless strict-mode error.
        local mt = getmetatable(_G)
        ui = mt and mt.__index and mt.__index(_G, "SMR_UI") or nil
    end
    return ui
end

-- A terrain rebuild runs as a job over several ticks and installs a new model
-- built from the water captured when it started. Scenarios that pick basins or
-- pour water straight into the model wait for any job to finish first.
local function model_idle(ctx, F)
    ctx:wait_for(function() return not F.State.rebuild_job and F.State.model end, 240000)
end
local function pour(ctx, F, records)
    model_idle(ctx, F)
    -- The water step runs in pacer slices: finish it, never write mid-step.
    F.Lifecycle.Advance(true)
    F.Hydrology.Import(F.State.model, records)
end

-- Names of the reasons the game is paused (a reason can be a dialog object).
local function pause_reasons()
    local names = {}
    for reason in pairs(rawget(_G, "PauseReasons") or {}) do
        if type(reason) == "table" then
            names[#names + 1] = tostring(rawget(reason, "class") or reason.class or rawget(reason, "Id") or "table")
        else
            names[#names + 1] = tostring(reason)
        end
    end
    return table.concat(names, ",")
end

local function popup_blocking(ctx)
    local popup = GetDialog("PopupNotification")
    if not popup then return false end
    local id = popup.context and popup.context.id or "?"
    local ui = smr_ui()
    if ui and ui.settle then
        local report = ui.settle(8)
        local settled = ctx.settled or {}
        settled[#settled + 1] = tostring(id) .. ":" .. tostring(report and report.status)
        ctx.settled = settled
        ctx:record("settled_popups", settled)
        if not GetDialog("PopupNotification") then return false end
    end
    ctx:record("blocking_popup", tostring(id))
    if id == "?" then
        -- An id-less popup: record what it is, to find its source.
        local context, keys = popup.context or {}, {}
        for k, v in pairs(context) do keys[#keys + 1] = tostring(k) .. "=" .. string.sub(tostring(v), 1, 60) end
        ctx:record("unknown_popup", { class = tostring(popup.class), context = keys,
            title = popup.idTitle and string.sub(tostring(popup.idTitle:GetText()), 1, 120) or "?",
            text = popup.idText and string.sub(tostring(popup.idText:GetText()), 1, 200) or "?" })
    end
    return true
end

-- The hourly soil pass is a background job sharing the pacer's budget; under
-- load (10x speed, a flooded map) it finishes after its hour, with the hours
-- that passed meanwhile folded in. Waits for it and records how long it took.
local function wait_soil(ctx, F, label)
    local t0 = RealTime()
    local done = ctx:wait_for(function() popup_blocking(ctx); return not F.Soil.Pending() end, 120000)
    local waits = ctx.soil_waits or {}
    waits[#waits + 1] = label .. ":" .. (RealTime() - t0) .. "ms"
    ctx.soil_waits = waits
    ctx:record("soil_pass_waits", waits)
    return done
end

local function wait_effect_passes(ctx, n, timeout_ms)
    local s = FL().State
    local seen, last = 0, s.last_effects
    local ok = ctx:wait_for(function()
        if popup_blocking(ctx) then return true end
        if s.last_effects ~= last then seen = seen + 1; last = s.last_effects end
        return seen >= n
    end, timeout_ms or 120000)
    if not ok then
        ctx:record("effect_wait_timeout", { seen = seen, paused = IsPaused(), game_time = GameTime(),
            last_effects = s.last_effects, last_full_tick = s.last_full_tick, last_tick = s.last_tick, ticks = s.ticks,
            enabled = s.enabled, thread = IsValidThread(s.thread), job = s.rebuild_job ~= false, building = s.building,
            snapshot_pending = FL().Water.SnapshotPending(),
            time_factor = GetTimeFactor(), error = tostring(s.error) })
    end
    return ok
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

-- Starts a fresh colony on a fixed random map (works with Flood on or off),
-- from the main menu or from a running game (DoneGame ends it).
local function new_colony(ctx)
    ctx:wait_for(function()
        return (GetDialog("PGMainMenu") or (GameState.gameplay and MainMap and MainMap:IsValid()))
            and not (rawget(_G, "IsChangingMap") and IsChangingMap())
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
end

HARNESS.scenario("flood_00_new_game", function(ctx)
    ctx:assert(FL() ~= nil, "Flood mod code loaded")
    if not FL() then ctx:fail("Flood not loaded") end
    new_colony(ctx)
    local F = FL()
    -- Test maps are unterraformed, so the planet's water is frozen (vanilla
    -- WaterFrozen) and every lake would be ice. The liquid-water scenarios run with
    -- planet ice off; flood_70_ice tests freezing through local cold.
    ctx:record("planet_water_frozen", tostring(rawget(_G, "WaterFrozen")))
    F.Config.ICE_PLANET_COLD = false
    -- The first terrain scan runs in slices of game time, so it waits while a
    -- new-colony popup pauses the game: answer popups while waiting.
    ctx:assert(ctx:wait_for(function() popup_blocking(ctx); return F.State.model ~= false end, 240000),
        "first terrain scan finished")
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
    -- A new colony can open popups that pause the game (the suite runs this
    -- straight after flood_00_new_game): answer them first.
    ctx:assert(not popup_blocking(ctx), "no popup left pausing the game")
    model_idle(ctx, F)
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
    local worst_snapshot, worst_redraw = 0, 0
    ctx:wait_for(function()
        worst_snapshot = math.max(worst_snapshot, s.snapshot_step_ms or 0)
        worst_redraw = math.max(worst_redraw, s.refresh_ms or 0)
        return GameTime() - t0 >= 3 * const.HourDuration
    end, 180000)
    ctx:record("worst_step_ms", { snapshot = worst_snapshot, redraw = worst_redraw })
    ctx:assert(worst_snapshot <= 30, "depth snapshot ran in short steps during the storm")
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
    -- Volume realism: drawn water covers about what the model holds, never the map.
    local drawn_m2, model_m2 = 0, 0
    for _, entry in pairs(s.markers) do
        if IsValid(entry.obj) then
            drawn_m2 = drawn_m2 + (entry.obj.applied_area or 0)
            model_m2 = model_m2 + (entry.expected_m2 or 0)
        end
    end
    local map_x, map_y = terrain.GetMapSize(MainMap)
    ctx:record("drawn_vs_model_area_m2", { drawn = drawn_m2, model = model_m2,
        map = (map_x / guim) * (map_y / guim) })
    ctx:assert(drawn_m2 <= model_m2 * 1.3 + 600 * 400, "drawn water area within 30 % of the model's")
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
local function pick_basin(ctx, F)
    model_idle(ctx, F)
    local s = F.State
    local best
    -- A basin of a few cells or more that can hold water over a colonist's head.
    -- Earlier scenarios leave water and dry toxic residue in many basins: prefer
    -- clean ones (no water, no residue), then dry ones, then any.
    local tiers = {
        function(n) return n.total == 0 and n.total_mass == 0 end,
        function(n) return n.total == 0 end,
        function() return true end,
    }
    for tier, eligible in ipairs(tiers) do
        for _, n in ipairs(s.model.nodes) do
            if eligible(n) and n.initial_count >= 4 and n.initial_count <= 5000 then
                local depth = n.spill - n.base
                if depth >= 2000 and (not best or depth > best.spill - best.base) then best = n end
            end
        end
        if best then
            ctx:record("basin_tier", ({ "clean", "dry", "any" })[tier])
            return best
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
    local basin = pick_basin(ctx, F)
    ctx:assert(basin ~= nil, "found a deep basin to flood")
    if not basin then ctx:fail("no suitable basin") end
    ctx:record("basin_depth_mm", basin.spill - basin.base)
    ctx:record("basin_cells", basin.initial_count)
    pour(ctx, F, { { basin.seed, basin.capacity * 0.95, 0 } })
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
    SetTimeFactor(const.DefaultTimeFactor * 10) -- faster (30x) measured slower: the game cannot keep up
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
        pour(ctx, F, { { s.model.nodes[1].seed, 1000000, 0 } })
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

local function stat_reasons(colonist, log_field)
    -- Colonist:AddToLog keeps flat triples: sol, amount, reason (Colonist.lua:4674).
    local found, log = {}, colonist[log_field] or {}
    for i = 1, #log - 2, 3 do
        if type(log[i + 2]) == "string" then found[log[i + 2]] = true end
    end
    return found
end

-- Groundwater recharge, soil (fresh, toxic, dried residue) and colonist exposure
-- under breathable air, in the open, in an opened dome and in a closed dome.
HARNESS.scenario("flood_40_ground_and_people", function(ctx)
    local F = FL()
    local s, H, cfg = F.State, F.Hydrology, F.Config
    no_flood_error(ctx, "start")
    -- Loading a save (flood_30) restores the default planet ice, and frozen ground
    -- takes no water in: this scenario tests liquid water.
    ctx:record("planet_ice_was", tostring(cfg.ICE_PLANET_COLD))
    cfg.ICE_PLANET_COLD = false
    local basin = pick_basin(ctx, F)
    if not basin then ctx:fail("no suitable basin") end
    local lake = at(F, basin.seed)
    local dry = at(F, highest_cell(F))

    local q, r = WorldToHex(lake)
    -- GetSoilQuality reports whole percents; the default rates (0.2-0.5 %/h) would
    -- not show within a few hours, so the mechanism is tested at raised rates.
    local rates = { cfg.FRESH_SOIL_PCT_PER_HOUR, cfg.TOXIC_SOIL_PCT_PER_HOUR, cfg.RESIDUE_SOIL_PCT_PER_HOUR }
    cfg.FRESH_SOIL_PCT_PER_HOUR, cfg.TOXIC_SOIL_PCT_PER_HOUR, cfg.RESIDUE_SOIL_PCT_PER_HOUR = 5, 5, 5
    local soil_start = GetSoilQuality(q, r)
    pour(ctx, F, { { basin.seed, basin.capacity * 0.6, 0 } })
    -- The poured water may join a larger lake: the topmost ancestor holding
    -- water (an ancestor can hold none of its own between full levels, so walk
    -- all the way up). A lake seeps at its lowest point.
    local surface = s.model.nodes[s.model.sinks[basin.seed]]
    local up = surface
    while up.parent and up.parent ~= 0 do
        up = s.model.nodes[up.parent]
        if up.water > 0 then surface = up end
    end
    -- Earlier toxic storms can leave every lake contaminated (old water or dry
    -- residue); this phase tests fresh water, so clean the whole connected lake.
    local stack, cleared = { surface }, 0
    while #stack > 0 do
        local n = table.remove(stack)
        if n.mass > 0 then cleared = cleared + n.mass; n.mass = 0 end
        for _, id in ipairs(n.children) do stack[#stack + 1] = s.model.nodes[id] end
    end
    pour(ctx, F, {}) -- rebalance: refreshes the tracer totals
    F.Water.Snapshot()
    ctx:record("lake_depth_mm", (F.Water.DepthAt(lake:xy())))
    ctx:record("seepage_point", { merged = surface.id ~= basin.id, distance_m = (at(F, surface.seed) - lake):Len2D() / guim,
        concentration = surface.total > 0 and surface.total_mass / surface.total or 0, map_frozen = F.Ice.MapFrozen(),
        water_l = surface.total, tracer_cleared_l = cleared })

    -- Groundwater: a water deposit beside the lake's lowest point.
    local deposit = PlaceObject("SubsurfaceDepositWater", nil, MainMap)
    deposit:SetPos(at(F, surface.seed) + point(40 * guim, 0, 0))
    deposit.max_amount = 1000 * const.ResourceScale
    deposit.amount = 100 * const.ResourceScale
    SetTimeFactor(const.DefaultTimeFactor * 10) -- faster (30x) measured slower: the game cannot keep up
    wait_effect_passes(ctx, 3)
    wait_soil(ctx, F, "fresh")
    ctx:record("deposit_units", { before = 100, after = deposit.amount / const.ResourceScale })
    ctx:assert(deposit.amount > 100 * const.ResourceScale, "fresh seepage recharged the deposit")
    local soil_fresh = GetSoilQuality(q, r)
    ctx:record("soil_fresh", { before = soil_start, after = soil_fresh })
    ctx:assert(soil_fresh > soil_start or soil_start >= cfg.FRESH_SOIL_MAX_PCT, "fresh water raised soil quality")

    -- Toxic: contaminate all water fully (earlier storms may have left fresh water in
    -- other basins within recharge range); soil falls, the deposit no longer gains.
    model_idle(ctx, F)
    -- Into every lake at its own lowest cell, so the tracer spreads through its water
    -- (a basin tree's lowest cell can be a dry basin elsewhere).
    local contaminate = {}
    for _, pool in ipairs(H.Pools(s.model)) do
        if pool.volume > pool.mass then contaminate[#contaminate + 1] = { pool.seed, 0, pool.volume - pool.mass } end
    end
    pour(ctx, F, contaminate)
    -- Fresh seepage collected before the contamination is applied on the next
    -- effect pass; measure from there.
    wait_effect_passes(ctx, 1)
    local deposit_toxic = deposit.amount
    wait_effect_passes(ctx, 3)
    wait_soil(ctx, F, "toxic")
    local soil_toxic = GetSoilQuality(q, r)
    ctx:record("soil_toxic", soil_toxic)
    ctx:assert(soil_toxic < soil_fresh, "toxic water lowered soil quality")
    ctx:record("deposit_after_toxic", deposit.amount / const.ResourceScale)
    ctx:assert(deposit.amount <= deposit_toxic + const.ResourceScale, "toxic seepage does not recharge")

    -- Residue: evaporate the lake completely; the dried toxic residue keeps lowering
    -- soil where it lies. Soil there is raised first (vanilla SoilAdd) so a fall can show.
    H.Step(s.model, 100000, 0, false, 50, 0, 1)
    local residues = H.Residues(s.model)
    ctx:assert(#residues > 0, "dried lake left toxic residue")
    table.sort(residues, function(a, b) return a.mass > b.mass end)
    local rq, rr = WorldToHex(at(F, residues[1].seed))
    SoilAdd(rq, rr, (40 - GetSoilQuality(rq, rr)) * const.SoilGridScale)
    OnSoilGridChanged()
    F.Water.Snapshot()
    local soil_dry = GetSoilQuality(rq, rr)
    wait_effect_passes(ctx, 3)
    wait_soil(ctx, F, "residue")
    ctx:record("soil_residue", { before = soil_dry, after = GetSoilQuality(rq, rr) })
    ctx:assert(soil_dry >= 35 and GetSoilQuality(rq, rr) < soil_dry, "dried residue lowers soil")
    if IsValid(deposit) then DoneObject(deposit) end
    cfg.FRESH_SOIL_PCT_PER_HOUR, cfg.TOXIC_SOIL_PCT_PER_HOUR, cfg.RESIDUE_SOIL_PCT_PER_HOUR = rates[1], rates[2], rates[3]

    -- Colonists under breathable air: outside, in an opened dome, in a closed dome.
    SetAtmosphereBreathable(true)
    ctx:assert(GetAtmosphereBreathable(MainMap), "atmosphere breathable")
    local function colonist_at(pos)
        local c = GenerateColonistData(MainCity)
        Colonist:new(c, MainMap)
        c:SetPos(pos)
        return c
    end
    local open_dome = PlaceBuildingIn("DomeBasic", MainMap)
    open_dome:SetPos(dry + point(-150 * guim, 0, 0))
    local closed_dome = PlaceBuildingIn("DomeBasic", MainMap)
    closed_dome:SetPos(dry + point(150 * guim, 0, 0))
    wait_real(1500)
    open_dome:ChangeOpenAirState(true)
    ctx:assert(open_dome.open_air == true and not closed_dome.open_air, "one dome opened, one closed")
    local outside = colonist_at(dry + point(0, 120 * guim, 0))
    local in_open = colonist_at(open_dome:GetPos())
    local in_closed = colonist_at(closed_dome:GetPos())
    wait_real(1000)
    ctx:assert(IsObjInOpenAir(outside) and IsObjInOpenAir(in_open) and not IsObjInOpenAir(in_closed),
        "exposure: outside and open dome exposed, closed dome sheltered")
    local h0 = { outside = outside.stat_health, open = in_open.stat_health, closed = in_closed.stat_health }
    s.rain_type = "toxic"
    local ok, err = F.Rain.Start(1)
    ctx:assert(ok == true, "light toxic storm: " .. tostring(err))
    wait_effect_passes(ctx, 2, 300000)
    ctx:record("health_toxic_rain", { outside = { h0.outside, outside.stat_health },
        open_dome = { h0.open, in_open.stat_health }, closed_dome = { h0.closed, in_closed.stat_health } })
    ctx:assert(outside.stat_health < h0.outside and stat_reasons(outside, "log_health").FloodToxicRain,
        "breathable air: toxic rain harms a colonist outside (logged reason)")
    ctx:assert(in_open.stat_health < h0.open, "toxic rain harms a colonist in an opened dome")
    ctx:assert(not stat_reasons(in_closed, "log_health").FloodToxicRain, "closed dome shelters from toxic rain")
    -- Fresh rain under an open, breathable sky lifts sanity. New colonists: vanilla
    -- dehydrates anyone outside for hours (and its first-time popup pauses the game).
    for _, obj in ipairs({ outside, in_open, in_closed, open_dome, closed_dome }) do
        if IsValid(obj) then DoneObject(obj) end
    end
    -- No domes nearby: a homeless colonist would otherwise walk into one to live.
    outside = colonist_at(dry + point(0, 120 * guim, 0))
    in_open, in_closed = nil, nil
    -- The runtime Colonist:ChangeSanity (Colonist.lua:5061) does not log a gain at
    -- full sanity: start the colonist below it.
    outside.stat_sanity = 70 * const.Scale.Stat
    local sanity0 = outside.stat_sanity
    ok, err = F.Rain.ToggleType()
    ctx:assert(ok == true and s.rain_type == "normal", "switched to fresh: " .. tostring(err))
    wait_effect_passes(ctx, 2, 300000)
    local labelled = {}
    for _, c in ipairs(MainCity.labels.Colonist or {}) do
        labelled[#labelled + 1] = { same = c == outside, open_air = IsObjInOpenAir(c), holder = tostring(c.holder),
            command = tostring(c.command), sanity_log = table.concat(table.map(c.log_sanity or {}, tostring), ",") }
    end
    ctx:record("sanity_fresh_rain", { before = sanity0, after = outside.stat_sanity, valid = IsValid(outside),
        open_air = IsValid(outside) and IsObjInOpenAir(outside), command = tostring(outside.command),
        holder = tostring(outside.holder), colonists = labelled })
    ctx:assert(outside.stat_sanity > sanity0 and stat_reasons(outside, "log_sanity").FloodFreshRain,
        "fresh rain cheered the colonist (logged reason)")
    F.Rain.StopOwned()
    SetTimeFactor(const.DefaultTimeFactor)
    for _, obj in ipairs({ outside, in_open, in_closed }) do if IsValid(obj) then DoneObject(obj) end end
    SetAtmosphereBreathable(false)
    no_flood_error(ctx, "end")
end)

-- Instant building through the construction controller, as vanilla scripts do
-- (Sequences/SA_Gameplay.lua:1921): skips statuses and construction sites.
local function place_instant(template, pos)
    local ctrl = GetDefaultConstructionController(MainCity)
    MainCity:SetCableCascadeDeletion(false, "FloodScenario")
    local ok, bld = pcall(ctrl.Place, ctrl, template, HexGetNearestCenter(pos), 0, nil, true)
    MainCity:SetCableCascadeDeletion(true, "FloodScenario")
    return ok and bld or nil, (not ok) and bld or nil
end

-- Real construction mode, real drones from a drone hub, and a train's speed on
-- real track elements in and out of water.
HARNESS.scenario("flood_50_build_drones_trains", function(ctx)
    local F = FL()
    local s, H, cfg = F.State, F.Hydrology, F.Config
    no_flood_error(ctx, "start")
    local basin = pick_basin(ctx, F)
    if not basin then ctx:fail("no suitable basin") end
    pour(ctx, F, { { basin.seed, basin.capacity * 0.6, 0 } })
    F.Water.Snapshot()
    local lake = at(F, basin.seed)
    local dry = at(F, highest_cell(F))
    ctx:record("lake_depth_mm", (F.Water.DepthAt(lake:xy())))

    -- Construction mode, driven like the build menu (X/BuildMenu.lua:859).
    GetInGameInterface():SetMode("construction", { template = "MoistureVaporator" })
    wait_real(1500)
    local ctrl = GetConstructionController("construction")
    ctx:assert(ctrl and ctrl.template == "MoistureVaporator", "construction mode open for a Moisture Vaporator")
    ctrl:UpdateCursor(lake, "force")
    wait_real(300)
    ctx:assert(table.find(ctrl.construction_statuses, ConstructionStatus.FloodSubmerged) ~= nil,
        "cursor over the lake shows the Flooded site error")
    ctx:expect_eq(ctrl:GetConstructionState(), "error", "placement state over the lake")
    local sites_before = #MainMap:MapGet("map", "ConstructionSite")
    ctrl:Place(nil, nil, nil, nil, false, true)
    wait_real(300)
    ctx:expect_eq(#MainMap:MapGet("map", "ConstructionSite"), sites_before, "clicking over the lake places nothing")
    ctx:capture("construction_over_lake")
    ctrl:UpdateCursor(dry, "force")
    wait_real(300)
    ctx:assert(table.find(ctrl.construction_statuses, ConstructionStatus.FloodSubmerged) == nil
        and table.find(ctrl.construction_statuses, ConstructionStatus.FloodWet) == nil,
        "cursor on dry ground has no flood status")
    GetInGameInterface():SetMode("selection")
    wait_real(500)

    -- Drones: a drone hub spawns its own drones; hold one in deep water, one on dry ground.
    local hub, herr = place_instant("DroneHub", dry + point(0, -200 * guim, 0))
    ctx:assert(hub ~= nil, "drone hub placed: " .. tostring(herr))
    ctx:assert(ctx:wait_for(function() return hub and #(hub.drones or {}) >= 2 end, 30000), "hub spawned drones")
    local wet_drone, dry_drone
    for _, d in ipairs(hub and hub.drones or {}) do
        if IsKindOf(d, "Drone") and not IsKindOf(d, "FlyingDrone") then
            if not wet_drone then wet_drone = d elseif not dry_drone then dry_drone = d end
        end
    end
    ctx:assert(wet_drone and dry_drone, "two ground drones available")
    if wet_drone and dry_drone then
        local function hold(d, pos)
            d.battery = d.battery_max
            d:SetHolder(false)
            d:SetPos(pos)
            d:SetCommand(function(self) self:SetState("idle") while true do Sleep(1000) end end)
        end
        -- Earlier storms can leave water near the highest cell: pick a dry spot.
        local dry_spot
        for r = 150, 600, 50 do
            for _, dir in ipairs({ { 0, -1 }, { 1, 0 }, { 0, 1 }, { -1, 0 } }) do
                local p = dry + point(dir[1] * r * guim, dir[2] * r * guim, 0)
                if not dry_spot and terrain.IsPointInBounds(MainMap, p) and F.Water.DepthAt(p:xy()) == 0 then dry_spot = p end
            end
        end
        ctx:assert(dry_spot ~= nil, "dry spot for the second drone")
        hold(wet_drone, lake)
        hold(dry_drone, dry_spot or dry)
        SetTimeFactor(const.DefaultTimeFactor * 10)
        local t0 = GameTime()
        ctx:wait_for(function() return GameTime() - t0 >= const.HourDuration end, 120000)
        SetTimeFactor(const.DefaultTimeFactor)
        local hours = (GameTime() - t0) * 1.0 / const.HourDuration
        ctx:record("drone_battery", { max = wet_drone.battery_max, wet = wet_drone.battery, dry = dry_drone.battery,
            hours = hours, wet_depth_mm = (F.Water.DepthAt(wet_drone:GetPos():xy())),
            dry_depth_mm = (F.Water.DepthAt(dry_drone:GetPos():xy())) })
        ctx:assert(wet_drone.battery < wet_drone.battery_max, "drone in deep water lost battery")
        ctx:expect_eq(dry_drone.battery, dry_drone.battery_max, "drone on dry ground kept its battery")
        for _, d in ipairs({ wet_drone, dry_drone }) do if IsValid(d) then d:SetCommand("Idle") end end
    end

    -- Trains: Train:GetNominalMoveSpeed on real track elements (Train.lua:593), which
    -- the train calls for each element it traverses (WaitTraverseElement, :535).
    local function element_at(pos)
        local track = PlaceObjectIn("TrackBase", MainMap)
        local q, r = WorldToHex(pos)
        local el = TrackGridElement:new({ city = MainCity, q = q, r = r, connections = {}, track_obj = track, node_idx = 1 }, MainMap)
        el:SetPos(point(HexToWorld(q, r)):SetTerrainZ(MainMap))
        return el, track
    end
    local train = PlaceObjectIn("Train", MainMap, { init_with_command = false })
    train:SetPos(dry)
    local wet_el, wet_track = element_at(lake)
    local dry_el, dry_track = element_at(dry + point(100 * guim, 0, 0))
    local dry_speed, dry_turn = train:GetNominalMoveSpeed(dry_el)
    local wet_speed, wet_turn = train:GetNominalMoveSpeed(wet_el)
    local vanilla = Train.FloodVanillaGetNominalMoveSpeed(train, wet_el)
    ctx:record("train_speed", { dry = dry_speed, wet = wet_speed, vanilla_at_wet = vanilla,
        wet_depth_mm = (F.Water.DepthAt(wet_el:GetPos():xy())) })
    ctx:expect_eq(dry_speed, vanilla, "dry rail: vanilla speed")
    ctx:assert(wet_speed < dry_speed and math.abs(wet_speed - vanilla * cfg.TRAIN_DEEP_SPEED_PERCENT / 100) <= 1,
        "flooded rail: train crawls at the configured share")
    for _, obj in ipairs({ train, wet_el, dry_el, wet_track, dry_track }) do if IsValid(obj) then DoneObject(obj) end end
    no_flood_error(ctx, "end")
end)

-- End to end: two stations, a track across a shallow flooded basin, a real train.
-- Following the vanilla call chain: ConstructionController:Place for stations,
-- PlaceTrackLine + construction completion for the track (Tracks.lua:100,
-- TrackElement.lua:841), TrackBase:AssignTrain for the train (Track.lua:428).
HARNESS.scenario("flood_60_train_route", function(ctx)
    local F = FL()
    local s, H, cfg = F.State, F.Hydrology, F.Config
    no_flood_error(ctx, "start")
    -- A shallow, wide basin whose whole station-to-station row is buildable for
    -- rails (Tracks.lua:184-185: buildable zone and TrackBuildableTest).
    local buildable = MainMap.buildable
    local function row_ok(q0, r0, half)
        for q = q0 - half - 8, q0 + half + 8 do
            local pos = point(HexToWorld(q, r0))
            if not buildable:IsBuildableZone(pos) or not TrackBuildableTest(MainMap, pos, q, r0) then return false end
        end
        return true
    end
    local candidates = {}
    for _, n in ipairs(s.model.nodes) do
        local depth = n.spill - n.base
        if depth >= 300 and depth <= 3000 and n.initial_count >= 8 and n.initial_count <= 400 then
            candidates[#candidates + 1] = n
        end
    end
    table.sort(candidates, function(a, b) return a.initial_count > b.initial_count end)
    local best, q0, r0, half
    for _, n in ipairs(candidates) do
        local cx, cy = F.Terrain.LowPoint(s.grid, n.seed)
        local q, r = WorldToHex(cx, cy)
        local h = math.max(6, math.floor(math.sqrt(n.initial_count * s.model.area) / 10 / 2) + 4)
        if row_ok(q, r, h) then best, q0, r0, half = n, q, r, h; break end
    end
    ctx:record("candidates_checked", #candidates)
    if not best then ctx:fail("no shallow basin with a buildable rail row") end
    ctx:record("basin", { cells = best.initial_count, depth_mm = best.spill - best.base, half_hexes = half })
    local sA, eA = place_instant("StationSmall", point(HexToWorld(q0 - half - 4, r0)):SetTerrainZ(MainMap))
    local sB, eB = place_instant("StationSmall", point(HexToWorld(q0 + half + 4, r0)):SetTerrainZ(MainMap))
    ctx:assert(sA and sB, "stations placed: " .. tostring(eA or eB))
    if not (sA and sB) then return end
    wait_real(2000)
    -- Connector pair on one hex axis, closest together.
    local pick
    for i = 1, 4 do for j = 1, 4 do
        local qa, ra = sA:GetConnectorElementDirection(i)
        local qb, rb = sB:GetConnectorElementDirection(j)
        if qa and qb then
            local dir, len = HexGetDirection(qa, ra, qb, rb)
            if dir and len and len > 0 and (not pick or len < pick.len) then
                pick = { qa = qa, ra = ra, dir = dir, len = len, i = i }
            end
        end
    end end
    ctx:assert(pick ~= nil, "station connectors on one hex axis")
    if not pick then return end
    local ok, res = PlaceTrackLine(MainCity, pick.qa, pick.ra, pick.dir, pick.len, false, true, nil, nil, "Default", nil, nil, nil, {})
    ctx:assert(ok and res and res.data and res.data.track_obj, "track line laid")
    if not (ok and res and res.data and res.data.track_obj) then
        ctx:record("track_failure", { can_build = tostring(ok), unbuildable = res and res.unbuildable_chunks and #res.unbuildable_chunks or -1 })
        return
    end
    ProcessTrackElements(MainMap, res.data.track_obj.elements_under_construction)
    wait_real(500)
    CheatCompleteAllConstructions()
    wait_real(2500)
    local el = sA:GetConnectorElement(pick.i)
    local track = el and el.track_obj
    ctx:assert(track and track:CanTrainsRun(), "track complete and runnable")
    RebuildTrainRoutes()
    -- Flood the basin under the track.
    pour(ctx, F, { { best.seed, best.capacity * 0.8, 0 } })
    F.Water.Snapshot()
    local wet_elements, dry_elements = 0, 0
    for _, e in ipairs(track and track.elements or {}) do
        local d = F.Water.DepthAt(e:GetPos():xy())
        if d >= cfg.TRAIN_WET_DEPTH_MM then wet_elements = wet_elements + 1 else dry_elements = dry_elements + 1 end
    end
    ctx:record("track_elements", { wet = wet_elements, dry = dry_elements })
    ctx:assert(wet_elements > 0, "part of the track is under water")
    ColonyAddPrefabs("Train", 1, nil, MainCity)
    track:AssignTrain(sA)
    local train
    ctx:wait_for(function()
        train = (MainMap:MapGet("map", "Train") or {})[1]
        return train ~= nil
    end, 20000)
    ctx:assert(train ~= nil, "train spawned on the route")
    if not train then return end
    -- Drive explicit trips between the stations (Train:GotoStation, Train.lua:338);
    -- an idle train without cargo would otherwise stay near its spawn station.
    local wet_speeds, dry_speeds = {}, {}
    ctx:wait_for(function() return train.current_station ~= nil and train.command ~= "GotoStation" end, 30000)
    for trip = 1, 4 do
        local here = train.current_station
        local dest = here == sA and sB or sA
        train:SetCommand("GotoStation", dest)
        local deadline = GetPreciseTicks() + 60000
        while GetPreciseTicks() < deadline and IsValid(train) do
            local speed = pf.GetSpeed(train)
            if speed and speed > 0 then
                local d = F.Water.DepthAt(train:GetPos():xy())
                local list = d >= cfg.TRAIN_WET_DEPTH_MM and wet_speeds or dry_speeds
                list[#list + 1] = speed
            end
            if train.current_station == dest and train.command ~= "GotoStation" then break end
            Sleep(100)
        end
        ctx:record("trip_" .. trip, { arrived = train.current_station == dest, wet = #wet_speeds, dry = #dry_speeds })
        if #wet_speeds >= 5 and #dry_speeds >= 5 then break end
    end
    local function max_of(t) local m = 0 for _, v in ipairs(t) do m = math.max(m, v) end return m end
    ctx:record("train_speed_samples", { wet = #wet_speeds, dry = #dry_speeds,
        wet_max = max_of(wet_speeds), dry_max = max_of(dry_speeds) })
    ctx:assert(#wet_speeds > 0 and #dry_speeds > 0, "train sampled on wet and dry rail")
    ctx:assert(max_of(wet_speeds) < max_of(dry_speeds), "train runs slower over flooded rail")
    ctx:capture("train_route")
    no_flood_error(ctx, "end")
end)

-- Ice: freeze the map (vanilla FreezeEntireMap cheat zeroes the heat grid), check
-- walkable plates over a lake at the water surface, units crossing on top, then
-- thaw (UnfreezeEntireMap) and check everything is removed.
HARNESS.scenario("flood_70_ice", function(ctx)
    local F = FL()
    local s, H, cfg = F.State, F.Hydrology, F.Config
    no_flood_error(ctx, "start")
    ctx:record("planet_water_frozen", tostring(rawget(_G, "WaterFrozen")))
    ctx:assert(s.features.ice == true, "ice available (FL_IcePlate entity loaded)")
    ctx:assert(IsValidEntity("FL_IcePlate"), "FL_IcePlate entity valid")
    local planet_cold = cfg.ICE_PLANET_COLD
    cfg.ICE_PLANET_COLD = false -- drive freezing through local heat only
    local basin = pick_basin(ctx, F)
    if not basin then ctx:fail("no suitable basin") end
    pour(ctx, F, { { basin.seed, basin.capacity * 0.6, 0 } })
    F.Water.Snapshot()
    local lake = at(F, basin.seed)
    local x, y = lake:xy()
    -- Only the largest pools are drawn; wait for lakes, give the redraw time to
    -- settle (after many storms every level moves, so its queue keeps refilling),
    -- then use the nearest drawn lake.
    local drawn = ctx:wait_for(function() return next(s.markers) ~= nil end, 180000)
    if not drawn then
        ctx:record("no_lakes_diagnostics", { markers = table.count(s.markers), pools = s.pools and #s.pools or -1,
            wet_pools = s.wet_pools, visible = s.visible_pools, backlog = s.render_backlog, retiring = #s.retiring,
            wet = s.wet ~= false, job = s.rebuild_job ~= false, building = s.building, saving = s.saving,
            enabled = s.enabled, paused = IsPaused(), refresh_ms = s.refresh_ms, error = tostring(s.error),
            map_markers = #MainMap:MapGet("map", "FloodWaterMarker") })
    end
    ctx:assert(drawn, "lakes drawn")
    if not drawn then ctx:fail("no lakes drawn") end
    -- Informational only (ctx:wait_for counts a timeout as a failed check).
    local settle_until = RealTime() + 60000
    while (s.render_backlog or 1) > 0 and RealTime() < settle_until do wait_real(500) end
    ctx:record("redraw_settled", (s.render_backlog or 1) == 0)
    local entry
    for _, e in pairs(s.markers) do
        if IsValid(e.obj) and e.x and (not entry or math.abs(e.x - x) + math.abs(e.y - y)
            < math.abs(entry.x - x) + math.abs(entry.y - y)) then entry = e end
    end
    local _, _, water_z = entry.obj:GetVisualPosXYZ()
    water_z = water_z + (entry.obj.zoffset or 0)
    local ex, ey = entry.x, entry.y
    local bed_z = GetWalkableZ(MainMap, ex, ey)
    ctx:record("liquid", { water_z = water_z, walkable_z = bed_z, terrain_z = terrain.GetHeight(MainMap, point(ex, ey)) })
    ctx:assert(bed_z < water_z - guim / 2, "liquid: walkable surface is the lakebed under the water")

    FreezeEntireMap()
    -- Ice spreads plate by plate, the largest lakes first: check the largest drawn
    -- lake once its ice is complete (the rest of the map keeps icing over).
    SetTimeFactor(const.DefaultTimeFactor * 10)
    local covered = ctx:wait_for(function()
        popup_blocking(ctx)
        entry = nil
        for _, e in pairs(s.markers) do
            if IsValid(e.obj) and e.x and e.frozen and (not entry or (e.expected_m2 or 0) > (entry.expected_m2 or 0)) then entry = e end
        end
        return entry and F.Ice.Covered(entry) and #entry.ice.plates > 0
    end, 300000)
    SetTimeFactor(const.DefaultTimeFactor)
    ctx:assert(covered and entry ~= nil, "frozen lake got ice plates")
    if not entry then ctx:fail("no iced lake") end
    ex, ey = entry.x, entry.y
    local plate = entry.ice and entry.ice.plates[1]
    local ice_z = GetWalkableZ(MainMap, ex, ey)
    ctx:record("frozen", { plates = entry.ice and #entry.ice.plates or 0, total_plates = s.ice_plates,
        walkable_z = ice_z, water_z = water_z, walkable_object = tostring(GetWalkableObject(MainMap, point(ex, ey))),
        frozen_pools = s.frozen_pools, ms_per_plate = s.ice_ms_per_plate })
    ctx:assert(plate and plate:GetEnumFlags(const.efWalkable) ~= 0 and plate:GetEnumFlags(const.efCollision) ~= 0,
        "plates are walkable and collide")
    -- The lake can still be rising to its level when first measured: compare
    -- with the surface the ice was built on, and that with the marker's level now.
    local frozen_water_z = entry.ice and entry.ice.z or water_z
    local marker_z = select(3, entry.obj:GetVisualPosXYZ()) + (entry.obj.zoffset or 0)
    ctx:record("frozen_surface", { ice_built_z = frozen_water_z, marker_z = marker_z, walkable_z = ice_z })
    ctx:assert(math.abs(ice_z - frozen_water_z) <= guim / 2 and math.abs(frozen_water_z - marker_z) <= guim / 2,
        "frozen: walkable surface is the ice at the water level")
    ctx:assert(entry.frozen == true and entry.tint == -1, "frozen lake styled as ice")
    -- Units on the ice: no deep-water slowdown, no battery drain, no wading.
    local rover = PlaceObject("RCRover", nil, MainMap)
    rover:SetPos(point(ex, ey))
    local colonist = GenerateColonistData(MainCity)
    Colonist:new(colonist, MainMap)
    colonist:SetPos(point(ex, ey))
    SetTimeFactor(const.DefaultTimeFactor * 10)
    wait_effect_passes(ctx, 1, 180000)
    SetTimeFactor(const.DefaultTimeFactor)
    ctx:record("units_on_ice", { rover_z = select(3, rover:GetVisualPosXYZ()), colonist_health = colonist.stat_health })
    ctx:assert(rover:FindModifier("FloodDeepWater", "move_speed") == nil, "rover on ice is not slowed")
    ctx:assert(colonist.stat_health >= 100000 and not stat_reasons(colonist, "log_health").FloodDrowning,
        "colonist on ice does not drown")
    ctx:capture("frozen_lake")
    if IsValid(colonist) then DoneObject(colonist) end

    UnfreezeEntireMap()
    SetTimeFactor(const.DefaultTimeFactor * 10)
    ctx:assert(ctx:wait_for(function()
        popup_blocking(ctx)
        return not entry.ice and (s.ice_plates or 0) == 0 and (s.ice_backlog or 1) == 0
    end, 300000), "thaw removed the ice")
    SetTimeFactor(const.DefaultTimeFactor)
    ctx:record("thawed_marker_still_drawn", IsValid(entry.obj))
    ctx:assert(#MainMap:MapGet("map", "FloodIcePlate") == 0, "no ice plates left on the map")
    local thaw_z, bed_now = GetWalkableZ(MainMap, ex, ey), terrain.GetHeight(MainMap, point(ex, ey))
    ctx:record("thawed_walkable_z", { walkable_z = thaw_z, terrain_z = bed_now, ice_z = frozen_water_z })
    -- The lake can be shallow (the largest frozen one after earlier scenarios):
    -- the lakebed is the terrain, not necessarily far below the old ice.
    ctx:assert(thaw_z <= bed_now + guim / 10 and thaw_z < frozen_water_z, "thawed: walkable surface back to the lakebed")
    ctx:assert((not IsValid(entry.obj) or entry.frozen == false) and s.frozen_pools == 0, "thawed lake styled as water again")
    if IsValid(rover) then DoneObject(rover) end
    cfg.ICE_PLANET_COLD = planet_cold
    no_flood_error(ctx, "end")
end)

-- The panel's Cold Wave button: pressed through the real button, it starts a
-- vanilla cold wave; as the heat grid cools below the freezing heat, drawn lakes
-- ice over (in small batches); the second press ends the wave and, as it warms,
-- the ice melts.
HARNESS.scenario("flood_80_cold_wave_button", function(ctx)
    local F = FL()
    local s, cfg = F.State, F.Config
    no_flood_error(ctx, "start")
    cfg.ICE_PLANET_COLD = false -- liquid water to start with: only the cold wave freezes
    local panel = s.ui
    ctx:assert(panel and panel.idColdWave, "panel has the Cold Wave button")
    if not (panel and panel.idColdWave) then ctx:fail("no Cold Wave button") end
    local function press() panel.idColdWave:OnPress() end
    local function label() return tostring(panel.idColdWave.Text) end -- XTextButton:SetText stores it (XButton.lua:459)
    ctx:assert(not rawget(_G, "g_ColdWave"), "no cold wave under way")
    local basin = pick_basin(ctx, F)
    if not basin then ctx:fail("no suitable basin") end
    pour(ctx, F, { { basin.seed, basin.capacity * 0.6, 0 } })
    ctx:assert(ctx:wait_for(function() return next(s.markers) ~= nil end, 180000), "lakes drawn")
    local lake = at(F, basin.seed)
    local heat0 = GetHeatAtXY(lake:xy())

    press()
    ctx:assert(F.ColdWave.Active() and label():find("Cold wave: On", 1, true), "first press: cold wave on")
    SetTimeFactor(const.DefaultTimeFactor * 10)
    ctx:assert(ctx:wait_for(function() return rawget(_G, "g_ColdWave") ~= false end, 30000), "vanilla cold wave under way")
    local worst, last = 0, nil
    -- Ice spreads plate by plate within its budget (realistically slowly across a
    -- whole frozen map): check that it forms smoothly rather than wait for all.
    local iced = ctx:wait_for(function()
        popup_blocking(ctx)
        if s.ice_refresh_ms and s.ice_refresh_ms ~= last then last = s.ice_refresh_ms; worst = math.max(worst, last) end
        return (s.frozen_pools or 0) > 0 and ((s.ice_plates or 0) >= 300 or ((s.ice_plates or 0) > 0 and (s.ice_backlog or 1) == 0))
    end, 300000)
    ctx:record("cold", { heat_before = heat0, heat_at_lake = GetHeatAtXY(lake:xy()), freeze_heat = cfg.ICE_FREEZE_HEAT,
        frozen_pools = s.frozen_pools, plates = s.ice_plates, worst_ice_refresh_ms = worst, label = label() })
    ctx:assert(iced, "the cold wave froze lakes (walkable ice)")
    ctx:record("worst_ice_batch_ms", s.ice_worst_batch_ms)
    ctx:record("ice_phase_max_ms", s.ice_phase_max_ms)
    ctx:assert(worst <= 60, "every ice refresh stayed short (at most 60 ms under the debugger)")
    -- Shore first: on the largest iced lake, the first quarter of the plates laid
    -- sits in shallower water than the last quarter.
    local big
    for _, e in pairs(s.markers) do
        if e.ice and #e.ice.plates >= 8 and (not big or #e.ice.plates > #big.ice.plates) then big = e end
    end
    if big then
        local plates, z = big.ice.plates, big.ice.plate_z
        local quarter = #plates // 4
        local function mean_depth(i0, i1)
            local sum = 0
            for i = i0, i1 do sum = sum + (z - terrain.GetHeight(MainMap, plates[i]:GetPos())) end
            return sum / (i1 - i0 + 1)
        end
        local first, last = mean_depth(1, quarter), mean_depth(#plates - quarter + 1, #plates)
        ctx:record("shore_first", { plates = #plates, first_quarter_depth = first, last_quarter_depth = last })
        ctx:assert(first < last, "ice laid from the shore towards the deep middle")
    end
    ctx:capture("cold_wave")

    press()
    ctx:assert(not F.ColdWave.Active() and label():find("Cold wave: Off", 1, true), "second press: cold wave off")
    ctx:assert(ctx:wait_for(function() return rawget(_G, "g_ColdWave") == false end, 30000), "vanilla cold wave ended")
    local melted = ctx:wait_for(function()
        popup_blocking(ctx)
        return (s.ice_plates or 0) == 0 and (s.ice_backlog or 1) == 0
    end, 600000)
    ctx:record("warm", { heat_at_lake = GetHeatAtXY(lake:xy()), frozen_pools = s.frozen_pools, plates = s.ice_plates })
    ctx:assert(melted, "after the cold wave the ice melted")
    SetTimeFactor(const.DefaultTimeFactor)
    no_flood_error(ctx, "end")
end)

-- Paused game: water must still appear. Mimics loading a save that opens paused:
-- with the game paused, the drawn water is removed and the terrain is rescanned;
-- the scan must finish and the lake be drawn again before the game resumes,
-- with game time and the stored water unchanged.
HARNESS.scenario("flood_85_paused_water", function(ctx)
    local F = FL()
    local s, H = F.State, F.Hydrology
    no_flood_error(ctx, "start")
    local basin = pick_basin(ctx, F)
    if not basin then ctx:fail("no suitable basin") end
    pour(ctx, F, { { basin.seed, basin.capacity * 0.6, 0 } })
    ctx:assert(ctx:wait_for(function() return (s.render_backlog or 1) == 0 and next(s.markers) ~= nil end, 180000),
        "lakes drawn before pausing")
    Pause("FloodPausedWaterTest")
    wait_real(500)
    local t0, water0 = GameTime(), H.Total(s.model)
    -- As a load does: the water is captured (the save), the in-memory model and
    -- drawn water are gone, and Flood rebuilds from the capture.
    F.Save.Capture()
    F.Water.Clear(MainMap)
    s.model, s.grid, s.wet, s.wet_concentration = false, false, false, false
    s.dirty = true
    ctx:assert(next(s.markers) == nil and #MainMap:MapGet("map", "FloodWaterMarker") == 0, "paused: drawn water removed")
    local scanned = ctx:wait_for(function() return s.grid and not s.rebuild_job end, 120000)
    ctx:assert(scanned, "paused: terrain scan finished")
    local drawn = ctx:wait_for(function() return #MainMap:MapGet("map", "FloodWaterMarker") > 0 and (s.render_backlog or 1) == 0 end,
        120000)
    ctx:record("paused", { paused = IsPaused(), game_time_moved = GameTime() - t0, water_before_l = water0,
        water_after_l = H.Total(s.model), markers = #MainMap:MapGet("map", "FloodWaterMarker") })
    ctx:assert(drawn, "paused: lakes drawn again")
    ctx:assert(IsPaused() and GameTime() == t0, "game stayed paused, game time unchanged")
    -- A restore regrids saved cells: allow 0.1 % (measured save/load loss: 0.003 %).
    ctx:assert(math.abs(H.Total(s.model) - water0) <= math.max(1, water0 * 0.001), "paused: stored water restored")
    ctx:capture("paused_water")
    Resume("FloodPausedWaterTest")
    no_flood_error(ctx, "end")
end)

-- Terrain edits after the first read: no whole-map re-read, no pause.
-- Silent edit: a pit dug the way the Excavator digs (terrain.SetHeightCircle,
-- TheExcavator.lua:229; no message) must be found by the rolling check and
-- rebuilt in the background while the simulation keeps running, keeping the
-- drawn lakes. Announced edit: the vanilla flatten used for every construction
-- (FlattenTerrainInBuildShape, as cables call it, ElectricityGrid.lua:1000) must
-- queue its box at once.
HARNESS.scenario("flood_90_terrain_edits", function(ctx)
    local F = FL()
    local s, cfg = F.State, F.Config
    no_flood_error(ctx, "start")
    -- Earlier scenarios can leave a popup the harness does not answer; record it.
    -- Rebuilds also run while paused; only the "simulation kept stepping" check
    -- needs a running game.
    local blocked = popup_blocking(ctx)
    if blocked then
        local popup = GetDialog("PopupNotification")
        local ctxt = popup and popup.context or {}
        local keys = {}
        for k, v in pairs(ctxt) do if type(v) ~= "table" and type(v) ~= "userdata" then keys[#keys + 1] = tostring(k) .. "=" .. tostring(v) end end
        ctx:record("unanswered_popup", table.concat(keys, "; "))
    end
    local running = not IsPaused()
    ctx:record("paused_at_start", not running)
    cfg.ICE_PLANET_COLD = false
    local basin = pick_basin(ctx, F)
    if not basin then ctx:fail("no suitable basin") end
    pour(ctx, F, { { basin.seed, basin.capacity * 0.6, 0 } })
    ctx:assert(ctx:wait_for(function() return next(s.markers) ~= nil end, 180000), "lakes drawn")
    local terrain0 = s.terrain
    local objs = {}
    for _, e in pairs(s.markers) do if IsValid(e.obj) then objs[e.obj] = true end end

    -- Silent edit on the highest ground (dry), at the cell's lowest sampled point:
    -- a cell stores the lowest of its samples, so a dent above that point is
    -- (correctly) not a change.
    local cell = highest_cell(F)
    local spot = point(F.Terrain.LowPoint(s.terrain, cell))
    local before = s.terrain.elevations[cell]
    local ground = terrain.GetHeight(MainMap, spot)
    -- As vanilla digging does (RegolithExtractor.lua:716-724), inside suspended pass edits.
    MainMap:SuspendPassEdits("FloodTerrainEditTest")
    terrain.SetHeightCircle(MainMap, spot, 20 * guim, 30 * guim, ground - 8 * guim, const.hsMin)
    MainMap:ResumePassEdits("FloodTerrainEditTest")
    -- A full rolling sweep of a big map takes longer than this scenario may wait;
    -- what is tested is that the check finds the edit, so start it two rows above.
    local pit_row = (cell - 1) // s.terrain.width
    s.check_row, s.check_col = math.max(0, pit_row - 2), 0
    ctx:record("dig", { ground = ground, after = terrain.GetHeight(MainMap, spot), check_row = s.check_row })
    ctx:assert(terrain.GetHeight(MainMap, spot) < ground, "pit dug")
    local model0, last_tick0 = s.model, s.last_tick
    SetTimeFactor(const.DefaultTimeFactor * 10)
    ctx:assert(ctx:wait_for(function() return s.rebuild_job or s.model ~= model0 end, 300000),
        "rolling check found the silent edit; background rebuild started")
    local ran_during, job_last_tick, paused_during = false, s.last_tick, false
    ctx:assert(ctx:wait_for(function()
        if s.rebuild_job and not s.building and s.last_tick ~= job_last_tick then ran_during = true end
        if s.rebuild_job and IsPaused() then paused_during = pause_reasons() end
        return s.model ~= model0 and not s.rebuild_job
    end, 300000), "background rebuild finished")
    ctx:record("paused_during_rebuild", paused_during)
    local kept = 0
    for _, e in pairs(s.markers) do if objs[e.obj] then kept = kept + 1 end end
    ctx:record("silent_edit", { cell_before = before, cell_after = s.model.elevations[cell],
        rebuild = s.last_terrain_rebuild, markers_before = table.count(objs), markers_kept = kept })
    ctx:assert(s.terrain == terrain0, "terrain read once: the stored terrain was updated in place, not re-read")
    ctx:assert(s.model.elevations[cell] < before, "new model has the pit")
    -- Only meaningful while the game runs (rebuilds also run while paused).
    if running and not paused_during then
        ctx:assert(ran_during and s.last_tick ~= last_tick0, "simulation kept running during the rebuild")
    end
    ctx:assert(s.last_terrain_rebuild and s.last_terrain_rebuild.background and s.last_terrain_rebuild.max_slice_ms <= 100,
        "no long stall: every rebuild slice under 100 ms")
    ctx:assert(kept > 0, "drawn lakes kept their markers across the rebuild")

    -- Announced edit: flatten one hex through the real vanilla function, on
    -- buildable ground near the pit (on the pit itself vanilla returns an error
    -- string, which must not queue anything).
    local probe = PlaceObject("RCRover", nil, MainMap)
    probe:SetPos(spot)
    local boxes0 = #s.terrain_boxes
    local refused = FlattenTerrainInBuildShape(nil, probe)
    ctx:record("flatten_on_pit", tostring(refused))
    ctx:assert(IsBox(refused) or #s.terrain_boxes == boxes0, "a refused flatten queues nothing")
    local announced, tries = false, 0
    local buildable = MainMap.buildable
    local base = at(F, basin.seed)
    for r = 60, 1200, 60 do
        for _, dir in ipairs({ { 1, 0 }, { 0, 1 }, { -1, 0 }, { 0, -1 } }) do
            if not announced then
                local p = base + point(dir[1] * r * guim, dir[2] * r * guim, 0)
                local q, hr = WorldToHex(p)
                if terrain.IsPointInBounds(MainMap, p) and buildable:IsBuildable(q, hr)
                    and F.Water.DepthAt(p:xy()) == 0 then
                    tries = tries + 1
                    probe:SetPos(p)
                    local n0 = #s.terrain_boxes
                    if IsBox(FlattenTerrainInBuildShape(nil, probe)) then announced = #s.terrain_boxes > n0 end
                end
            end
        end
    end
    ctx:record("flatten_tries", tries)
    ctx:assert(announced, "construction flattening announced its box at once")
    local model1 = s.model
    ctx:wait_for(function() return #s.terrain_boxes == 0 end, 60000)
    local changed = s.terrain_changed
    ctx:record("announced_edit", { heights_changed = changed })
    if changed then
        ctx:assert(ctx:wait_for(function() return s.model ~= model1 and not s.rebuild_job end, 300000),
            "announced edit rebuilt in the background")
        ctx:record("announced_rebuild", s.last_terrain_rebuild)
        ctx:assert(s.terrain == terrain0, "still no whole-map re-read")
    end
    SetTimeFactor(const.DefaultTimeFactor)
    if IsValid(probe) then DoneObject(probe) end
    no_flood_error(ctx, "end")
end)

-- The panel's Terraformed button: On applies full terraforming through the
-- vanilla parameters (liquid water, breathable air, cold waves and dust storms
-- stopped), Off restores the starting values. Then, with the planet's water
-- frozen again, ice forms in small batches: the longest single ice refresh is
-- recorded and must stay short.
HARNESS.scenario("flood_95_terraformed_button", function(ctx)
    local F = FL()
    local s, cfg = F.State, F.Config
    no_flood_error(ctx, "start")
    local panel = s.ui
    ctx:assert(panel and panel.idTerraform, "panel has the Terraformed button")
    if not (panel and panel.idTerraform) then ctx:fail("no Terraformed button") end
    local function press() panel.idTerraform:OnPress() end
    local function label() return tostring(panel.idTerraform.Text) end
    local before = {}
    for name in pairs(TerraformingParamDefs) do before[name] = GetTerraformParamPct(name) end
    local initial = { water_frozen = rawget(_G, "WaterFrozen"), breathable = GetAtmosphereBreathable(MainMap),
        cold_waves_disabled = rawget(_G, "ColdWavesDisabled") }
    ctx:record("initial", { params = before, conditions = initial, label = label() })

    press()
    local on = {}
    for name in pairs(TerraformingParamDefs) do on[name] = GetTerraformParamPct(name) end
    local conditions_on = { water_frozen = rawget(_G, "WaterFrozen"), breathable = GetAtmosphereBreathable(MainMap),
        cold_waves_disabled = rawget(_G, "ColdWavesDisabled"), dust_storms_disabled = rawget(_G, "DustStormsDisabled") }
    ctx:record("terraformed", { params = on, conditions = conditions_on, label = label() })
    local all_full = true
    for _, pct in pairs(on) do if pct < 100 then all_full = false end end
    ctx:assert(F.Terraforming.Active() and label():find("Terraformed: On", 1, true), "first press: terraformed on")
    ctx:assert(all_full, "every terraforming parameter at 100 %")
    ctx:assert(conditions_on.water_frozen ~= true and conditions_on.breathable == true and conditions_on.cold_waves_disabled == true,
        "full terraforming: liquid water, breathable air, no cold waves")

    press()
    local after = {}
    local restored = true
    for name in pairs(TerraformingParamDefs) do
        after[name] = GetTerraformParamPct(name)
        if after[name] ~= before[name] then restored = false end
    end
    local conditions_off = { water_frozen = rawget(_G, "WaterFrozen"), breathable = GetAtmosphereBreathable(MainMap),
        cold_waves_disabled = rawget(_G, "ColdWavesDisabled") }
    ctx:record("restored", { params = after, conditions = conditions_off, label = label() })
    ctx:assert(not F.Terraforming.Active() and label():find("Terraformed: Off", 1, true), "second press: terraformed off")
    ctx:assert(restored, "every terraforming parameter back to its starting value")
    ctx:assert(conditions_off.water_frozen == initial.water_frozen and conditions_off.breathable == initial.breathable
        and conditions_off.cold_waves_disabled == initial.cold_waves_disabled, "starting conditions restored")

    -- Ice smoothness: the planet's water is frozen again (unterraformed test map),
    -- so with planet ice on every drawn lake freezes; watch each refresh's cost.
    cfg.ICE_PLANET_COLD = true
    local basin = pick_basin(ctx, F)
    if basin then pour(ctx, F, { { basin.seed, basin.capacity * 0.6, 0 } }) end
    ctx:wait_for(function() return next(s.markers) ~= nil end, 180000)
    local worst, samples, last = 0, 0, nil
    ctx:wait_for(function()
        popup_blocking(ctx)
        if s.ice_refresh_ms and s.ice_refresh_ms ~= last then
            last = s.ice_refresh_ms; samples = samples + 1; worst = math.max(worst, s.ice_refresh_ms)
        end
        -- Ice spreads plate by plate (realistically slowly on a frozen map): check
        -- that it forms smoothly rather than wait for every lake.
        return s.frozen_pools > 0 and ((s.ice_backlog or 1) == 0 or (s.ice_plates or 0) >= 300)
    end, 300000)
    ctx:record("ice_formation", { frozen_pools = s.frozen_pools, plates = s.ice_plates, refreshes_seen = samples,
        worst_refresh_ms = worst, paused = IsPaused(), pause_reasons = pause_reasons(),
        planet_frozen = F.Ice.PlanetFrozen(), markers = table.count(s.markers) })
    ctx:assert((s.ice_plates or 0) > 0, "lakes iced over")
    ctx:record("worst_ice_batch_ms", s.ice_worst_batch_ms)
    ctx:record("ice_phase_max_ms", s.ice_phase_max_ms)
    ctx:assert(worst <= 60, "every ice refresh stayed short (at most 60 ms under the debugger)")
    cfg.ICE_PLANET_COLD = false
    ctx:wait_for(function() return (s.ice_plates or 0) == 0 and (s.ice_backlog or 1) == 0 end, 300000)
    no_flood_error(ctx, "end")
end)

-- Shared with scenarios/manual/flood_save_compat.lua (loaded alongside this file and
-- run by name, with Flood switched off and on between its scenarios).
FloodScenarioKit = { FL = FL, new_colony = new_colony, pick_basin = pick_basin, pour = pour,
    popup_blocking = popup_blocking, wait_render = wait_render, at = at }
