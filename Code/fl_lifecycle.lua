local F = Flood
local L = {}
F.Lifecycle = L

-- Gameplay effect modules: each owns one domain, checks its own ENABLE_* switch
-- and reports engine API availability once per enable. Optional hooks:
-- Tick() every simulation tick, Hourly(hours, nominal_rain_mm_h, toxic),
-- PreSave() to drop transient modifiers before serialization, Restore().
local EFFECTS = {
    { key = "climate", module = "Climate" },
    { key = "buildings", module = "Buildings" },
    { key = "dust", module = "Dust" },
    { key = "vehicles", module = "Vehicles" },
    { key = "shuttles", module = "Shuttles" },
    { key = "trains", module = "Trains" },
    { key = "colonists", module = "Colonists" },
    { key = "groundwater", module = "Groundwater" },
    { key = "soil", module = "Soil" },
    { key = "construction", module = "Construction" },
    { key = "ice", module = "Ice" },
}

local BOOLEAN_KEYS = { "ENABLE_MOD", "ENABLE_TEST_UI", "DEBUG_LOGS", "DEBUG_HYDROLOGY", "DEBUG_EFFECTS",
    "ENABLE_CLIMATE_EVAPORATION", "ENABLE_BUILDING_FLOODING", "ENABLE_GROUNDWATER_RECHARGE",
    "ENABLE_TOXIC_SOIL", "ENABLE_RAIN_DUST_WASHING", "ENABLE_TOXIC_CORROSION", "ENABLE_ROVER_SLOWDOWN",
    "ENABLE_CONSTRUCTION_RULES", "ENABLE_FRESH_SOIL", "ENABLE_ROVER_BREAKDOWN", "ENABLE_DRONE_EFFECTS",
    "ENABLE_SHUTTLE_EFFECTS", "ENABLE_TRAIN_EFFECTS", "ENABLE_COLONIST_EFFECTS", "ENABLE_ICE",
    "ICE_PLANET_COLD" }

local POSITIVE_KEYS = { "CELL_SIZE_M", "MAX_GRID_CELLS", "SAMPLE_YIELD_ROWS", "REBUILD_SLICE_MS", "REBUILD_SLICE_SLEEP_MS", "PAUSED_TICK_MS", "TICK_MS",
    "BACKGROUND_SLICE_MS", "TERRAIN_CHECK_ROWS_PER_TICK", "TERRAIN_BOX_CELLS_PER_TICK", "TERRAIN_SETTLE_MS", "TERRAIN_YIELD_MS",
    "TEST_RAIN_MULTIPLIER", "SNAPSHOT_BUDGET_MS", "RESTYLE_BUDGET_MS", "EFFECT_INTERVAL_HOURS",
    "EVAPORATION_BARREN_MULTIPLIER", "FLOOD_SUSPEND_DEPTH_MM", "FLOOD_RESUME_DEPTH_MM",
    "RECHARGE_RADIUS_M", "RECHARGE_LITRES_PER_UNIT", "RESIDUE_FULL_EFFECT_MM", "RESIDUE_MAX_RADIUS_M",
    "RAIN_REFERENCE_MM_H", "ROVER_SLOW_DEPTH_MM", "ROVER_FORD_DEPTH_MM", "DRONE_SHORT_DEPTH_MM",
    "SHUTTLE_GROUND_RAIN_MM_H", "TRAIN_WET_DEPTH_MM", "TRAIN_DEEP_DEPTH_MM", "TRAIN_WET_SPEED_PERCENT",
    "TRAIN_DEEP_SPEED_PERCENT", "WADING_DEPTH_MM", "DROWNING_DEPTH_MM",
    "MARKER_AREA_SLACK", "MIN_MARKER_AREA_M2", "SUBSAMPLE_M", "MAX_SUBSAMPLES", "RENDER_BUDGET_MS", "MAX_RENDERED_POOLS",
    "LARGE_LAKE_PLANES", "LARGE_LAKE_STEP_MM", "RENDER_LOWER_STEP_MM", "ICE_FREEZE_HEAT",
    "ICE_TILE_M", "MAX_ICE_PLATES", "ICE_BUDGET_MS", "ICE_BATCH_PLATES", "ICE_DEPTH_BIN_MM", "ICE_RELEVEL_MM" }

function L.Validate()
    for _, name in ipairs({ "PlaceObject", "DoneObject", "ApplyAllWaterObjects", "AddRects",
        "IsValid", "IsValidThread", "CreateGameTimeThread", "DeleteThread", "GameTime", "Sleep",
        "CreateRealTimeThread", "IsPaused", "IsChangingMap", "RealTime", "IsBox",
        "GetPreciseTicks",
        "RainProcedure", "StopRainsDisaster", "IsDisasterActive", "GetHUD", "HasGameLogic" }) do
        if type(rawget(_G, name)) ~= "function" then return false, name .. " API unavailable" end
    end
    if type(GameState) ~= "table" then return false, "GameState unavailable (paused redraw readiness)" end
    if type(coroutine) ~= "table" or type(coroutine.create) ~= "function" then
        return false, "coroutine library unavailable (terrain rebuild job)"
    end
    if not terrain or type(terrain.GetHeight) ~= "function" or type(terrain.GetMapSize) ~= "function" then
        return false, "Terrain sampling APIs unavailable"
    end
    if not g_Classes.FloodWaterMarker or not WaterObjPresets or not WaterObjPresets.Water_Default then
        return false, "Terrain water class or Water_Default preset unavailable"
    end
    if not const.HourDuration or not const.HeightTileSize or not guim then return false, "Engine unit constants unavailable" end
    if not Presets.MapSettings or not Presets.MapSettings.RainsDisaster then return false, "Rain presets unavailable" end
    if F.Config.ENABLE_TEST_UI == true and (not XWindow or not XText or not XTextButton) then return false, "Rain UI classes unavailable" end
    for _, key in ipairs(BOOLEAN_KEYS) do
        if type(F.Config[key]) ~= "boolean" then return false, key .. " must be a boolean" end
    end
    for _, key in ipairs(POSITIVE_KEYS) do
        if type(F.Config[key]) ~= "number" or F.Config[key] <= 0 then return false, key .. " must be positive" end
    end
    if F.Config.MAX_GRID_CELLS < 9 then return false, "MAX_GRID_CELLS must be at least 9" end
    if F.Config.RUNOFF_COEFFICIENT < 0 or F.Config.RUNOFF_COEFFICIENT > 1 then return false, "RUNOFF_COEFFICIENT must be in [0,1]" end
    if F.Config.FLOOD_RESUME_DEPTH_MM > F.Config.FLOOD_SUSPEND_DEPTH_MM then
        return false, "FLOOD_RESUME_DEPTH_MM must not exceed FLOOD_SUSPEND_DEPTH_MM"
    end
    return true
end

-- A missing engine API turns off only the effect that needs it, and says so.
function L.DetectFeatures()
    local s = F.State
    for _, effect in ipairs(EFFECTS) do
        local ok, reason = F[effect.module].Available()
        s.features[effect.key] = ok == true
        F.Log("Lifecycle", "effect availability", { effect = effect.key, available = ok == true,
            reason = reason or "ok" })
    end
end

local function each_effect(hook, ...)
    for _, effect in ipairs(EFFECTS) do
        local fn = F[effect.module][hook]
        if fn then fn(...) end
    end
end

-- Lift effects that persist on game objects (suspensions, speed modifiers).
-- Each restore runs even if an earlier one fails; failures are logged and returned.
local function restore_effects(reason)
    local failures = {}
    for _, effect in ipairs(EFFECTS) do
        local fn = F[effect.module].Restore
        if fn then
            local ok, err = pcall(fn)
            if not ok then
                failures[#failures + 1] = effect.key .. ": " .. tostring(err)
                F.Log("Lifecycle", "effect restore failed", { effect = effect.key, error = err, reason = reason })
            end
        end
    end
    return #failures == 0, table.concat(failures, "; ")
end

function L.Advance()
    local s = F.State
    if not s.enabled or s.saving or not s.model or s.building then return end
    local now = GameTime()
    local elapsed = math.max(0, now - (s.last_tick or now))
    if elapsed > 0 then
        s.evaporation_mm_h = F.Climate.EvaporationRate()
        local infiltration = F.Config.INFILTRATION_MM_H
        if F.Ice.MapFrozen() then
            -- Frozen water only sublimates, and frozen ground takes no water in.
            s.evaporation_mm_h = s.evaporation_mm_h * F.Config.ICE_SUBLIMATION_FACTOR
            infiltration = 0
        end
        F.Hydrology.Step(s.model, elapsed * 1.0 / const.HourDuration,
            s.last_rate or 0, s.last_toxic == true, s.evaporation_mm_h,
            infiltration, F.Config.RUNOFF_COEFFICIENT)
        F.Groundwater.Collect(s.model.seepage)
    end
    s.last_tick = now
    s.last_rate, s.last_toxic, s.last_nominal_rate = F.Rain.Read()
end

-- Draw the water and ice in short steps. start begins a snapshot pass (every
-- full tick: the water moved); otherwise only a pass under way continues. A
-- completed pass redraws the lakes; redraw and ice work left over continue on
-- later wakes. Before the first completed pass the steps are longer, so water
-- appears quickly after a load.
-- check_ice re-checks every lake's frozen state (full and paused ticks): the
-- conditions can change without the water moving (cold waves, the Terraformed
-- button while paused).
local function draw(start, check_ice)
    local s = F.State
    local cfg = F.Config
    if start or not s.wet or F.Water.SnapshotPending() then
        local budget = (s.pools and s.wet) and cfg.SNAPSHOT_BUDGET_MS or cfg.REBUILD_SLICE_MS
        if F.Water.SnapshotStep(budget) then
            F.Water.Refresh()
            F.Ice.Refresh()
            return
        end
    end
    if (s.render_backlog or 0) > 0 then F.Water.Refresh() end
    if check_ice or (s.ice_backlog or 0) > 0 then F.Ice.Refresh() end
    if F.Water.RestylePending() then F.Water.RestyleStep(cfg.RESTYLE_BUDGET_MS) end
end

-- Work that continues between full ticks (every REBUILD_SLICE_SLEEP_MS).
local function pending_work()
    local s = F.State
    return s.rebuild_job or F.Water.SnapshotPending() or (s.render_backlog or 0) > 0 or (s.ice_backlog or 0) > 0
        or F.Water.RestylePending()
end

local function update_effects()
    local s = F.State
    s.ticks = s.ticks + 1
    draw(true, true)
    each_effect("Tick")
    local now = GameTime()
    if not s.last_effects then s.last_effects = now; return end
    local elapsed = now - s.last_effects
    if elapsed < F.Config.EFFECT_INTERVAL_HOURS * const.HourDuration then return end
    s.last_effects = now
    each_effect("Hourly", elapsed * 1.0 / const.HourDuration, s.last_nominal_rate or 0, s.last_toxic == true)
end

-- Starts the first build when there is no model, then runs one slice of the
-- terrain job if one is running. Returns true when a job slice ran.
local function rebuild_slice()
    local s = F.State
    if not s.rebuild_job and not s.model then F.Terrain.StartRebuild(s.map) end
    if not s.rebuild_job then return false end
    if F.Terrain.StepRebuild() and not s.last_tick then
        s.last_tick = GameTime()
        s.last_rate, s.last_toxic, s.last_nominal_rate = F.Rain.Read()
    end
    return true
end

-- The simulation thread wakes every TICK_MS, or every REBUILD_SLICE_SLEEP_MS
-- while a terrain job runs. Each wake runs one job slice; the full tick (rain,
-- water step, terrain tracking, effects, drawing) runs once per TICK_MS. A
-- background rebuild therefore never pauses the simulation.
function L.Tick()
    local s = F.State
    if F.Config.ENABLE_MOD ~= true then L.Disable(); return end
    if s.saving then return end
    local sliced = rebuild_slice()
    if not s.model then F.UI.Refresh(); return end -- first build still running
    local now = GameTime()
    if s.last_full_tick and now - s.last_full_tick < F.Config.TICK_MS then
        -- Between full ticks: snapshot, redraw and ice work left by the last one.
        draw(false)
        return
    end
    s.last_full_tick = now
    F.Rain.Sync()
    L.Advance()
    F.Terrain.Track()
    if F.Terrain.WantsRebuild() then F.Terrain.StartRebuild(s.map) end
    update_effects()
    s.status = s.last_rate > 0 and "Rain feeding catchments" or "Dry weather: evaporation and infiltration"
    F.UI.Refresh()
    if F.Config.DEBUG_HYDROLOGY == true then
        F.Log("Hydrology", "water balance", { litres = F.Hydrology.Total(s.model), pools = s.visible_pools,
            rain_mm_h = s.last_rate, outflow_l = s.model.budget.outflow,
            evaporation_mm_h = s.evaporation_mm_h })
    end
end

-- While the game is paused, game-time threads stand still. The paused tick keeps
-- the picture current: it finishes a terrain scan (same slices) and draws the
-- water and ice, so water appears after loading a save that opens paused. It
-- never steps the water or runs effects: those follow game time.
function L.PausedTick()
    local s = F.State
    if F.Config.ENABLE_MOD ~= true or not s.enabled or s.saving or not s.map then return end
    -- New maps are generated and switched while paused; scan only a settled map
    -- (the same readiness test as vanilla AgentPlayTest.lua:181).
    if not GameState.gameplay or IsChangingMap() or rawget(_G, "GeneratingMap") then return end
    rebuild_slice()
    if s.model then
        -- Construction can be placed while paused: keep the terrain current too.
        F.Terrain.Track()
        if F.Terrain.WantsRebuild() then F.Terrain.StartRebuild(s.map) end
        draw(not s.pools, true) -- start the first pass after a load or rebuild; otherwise continue
    end
    F.UI.Refresh()
end

-- Runs one tick function; an engine-boundary error stops the simulation,
-- restores vanilla object state and is shown in the panel and logs.
local function guarded(tick)
    local s = F.State
    local ok, tick_error = pcall(tick)
    if ok then return true end
    F.SetError("Lifecycle", tick_error)
    s.enabled = false
    F.Terrain.CancelRebuild()
    F.Rain.StopOwned()
    restore_effects("tick_error")
    F.UI.Refresh()
    return false
end

function L.Enable()
    local s = F.State
    if F.Config.ENABLE_MOD ~= true then return false end
    if not MainMap or not MainMap:IsValid() or not HasGameLogic(MainMap) then return false end
    if s.saving or s.thread and IsValidThread(s.thread) then return true end
    local valid, err = L.Validate()
    if not valid then F.SetError("Validation", err); return false end
    if s.map ~= MainMap then
        F.Terrain.Reset()
        s.model, s.grid, s.last_tick, s.last_full_tick = false, false, nil, nil
        s.wet, s.wet_concentration, s.last_effects, s.recharge = false, false, false, {}
        s.map, s.dirty = MainMap, true
    end
    s.enabled, s.error = true, false
    L.DetectFeatures()
    -- A map-owned game-time thread pauses with the game and dies with its map.
    s.thread = s.map:CreateGameTimeThread(function()
        Sleep(1) -- let all PostLoadGame handlers finish before creating transient visuals
        while s.enabled do
            if not guarded(L.Tick) then return end
            -- A rebuild or ice work in progress continues after a short timed sleep.
            Sleep(pending_work() and F.Config.REBUILD_SLICE_SLEEP_MS or F.Config.TICK_MS)
        end
    end)
    -- Real-time companion: works only while the game is paused (see PausedTick).
    -- Real-time threads are not saved with the game.
    local map = s.map
    s.paused_thread = CreateRealTimeThread(function()
        Sleep(F.Config.PAUSED_TICK_MS)
        while s.enabled and s.map == map do
            if IsPaused() and not guarded(L.PausedTick) then return end
            Sleep(pending_work() and F.Config.REBUILD_SLICE_SLEEP_MS or F.Config.PAUSED_TICK_MS)
        end
    end)
    F.Log("Lifecycle", "enabled", { cell_m = F.Config.CELL_SIZE_M, debug = F.Config.DEBUG_LOGS,
        evaporation_mm_h = F.Config.EVAPORATION_MM_H, infiltration_mm_h = F.Config.INFILTRATION_MM_H })
    return true
end

local function stop_thread()
    local s = F.State
    if s.thread and IsValidThread(s.thread) and s.thread ~= CurrentThread() then DeleteThread(s.thread) end
    if s.paused_thread and IsValidThread(s.paused_thread) and s.paused_thread ~= CurrentThread() then
        DeleteThread(s.paused_thread)
    end
    s.thread, s.paused_thread = false, false
    F.Terrain.CancelRebuild()
end

function L.Disable()
    local s = F.State
    L.Advance()
    F.Save.Capture()
    s.enabled = false
    F.Rain.StopOwned()
    F.ColdWave.Stop()
    F.Terraforming.Restore()
    stop_thread()
    restore_effects("disable")
    F.Water.Clear(s.map)
    F.UI.Hide()
    s.last_tick, s.last_effects, s.wet, s.wet_concentration = nil, false, false, false
    F.Log("Lifecycle", "vanilla water and object state restored; owned rain and UI removed", {})
end

function L.MapDone(map)
    local s = F.State
    if s.map ~= map then return end
    F.UI.Hide()
    s.enabled, s.thread, s.map, s.model, s.grid = false, false, false, false, false
    s.paused_thread = false -- its loop ends once the map is gone
    s.markers, s.retiring, s.rain_thread, s.rain_strength = {}, {}, false, 0
    s.last_tick, s.last_full_tick, s.saving = nil, nil, false
    F.Terrain.Reset()
    s.wet, s.wet_concentration, s.last_effects, s.recharge = false, false, false, {}
    s.flooded_buildings, s.slowed_rovers = 0, 0
    -- Label modifiers lived on the map's city and are gone with it.
    s.drone_rain_percent, s.shuttle_rain_percent = 0, 0
end

function L.SaveStart()
    local s = F.State
    if not s.map then return end
    L.Advance()
    F.Save.Capture()
    s.saving = true
    -- Game-time threads are serialized with the map. Stop the ticker so the
    -- save holds neither its closure nor the in-memory model; SaveDone restarts it.
    s.resume_after_save = s.enabled and s.thread ~= false
    stop_thread()
    -- Speed modifiers are reapplied on the next tick; a save never carries them,
    -- so removing Flood leaves no permanent slowdown behind.
    each_effect("PreSave")
    -- Save only numerical water data. With Flood disabled, this save contains
    -- no custom markers or unexplained water planes that could survive removal.
    F.Water.Clear(s.map)
end

function L.SaveDone()
    local s = F.State
    s.saving = false
    s.last_tick = GameTime()
    if s.resume_after_save then
        s.resume_after_save = false
        L.Enable()
    end
end
