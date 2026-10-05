local F = Flood
local L = {}
F.Lifecycle = L

-- Gameplay effect modules: each owns one domain, checks its own ENABLE_* switch
-- and reports engine API availability once per enable. Optional hooks:
-- Tick() every simulation tick, Hourly(hours, nominal_rain_mm_h, toxic),
-- PreSave() to lift anything saved state must not hold (modifiers, Flood
-- suspensions) and PostSave() to put it back, Restore().
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

local POSITIVE_KEYS = { "CELL_SIZE_M", "MAX_GRID_CELLS", "SAMPLE_YIELD_ROWS", "REBUILD_SLICE_MS", "TICK_MS",
    "BACKGROUND_SLICE_MS", "TERRAIN_CHECK_MS", "TERRAIN_SETTLE_MS", "TERRAIN_YIELD_MS",
    "TEST_RAIN_MULTIPLIER", "WATER_STEP_BUDGET_MS", "EFFECT_STEP_BUDGET_MS", "BACKGROUND_WAKE_MS", "BACKGROUND_BUDGET_MS", "SNAPSHOT_BUDGET_MS", "RESTYLE_BUDGET_MS", "PROFILE_WINDOW_MS", "EFFECT_INTERVAL_HOURS",
    "EVAPORATION_BARREN_MULTIPLIER", "FLOOD_SUSPEND_DEPTH_MM", "FLOOD_RESUME_DEPTH_MM",
    "RECHARGE_RADIUS_M", "RECHARGE_LITRES_PER_UNIT", "RESIDUE_FULL_EFFECT_MM", "RESIDUE_MAX_RADIUS_M",
    "RAIN_REFERENCE_MM_H", "ROVER_SLOW_DEPTH_MM", "ROVER_FORD_DEPTH_MM", "DRONE_SHORT_DEPTH_MM",
    "SHUTTLE_GROUND_RAIN_MM_H", "TRAIN_WET_DEPTH_MM", "TRAIN_DEEP_DEPTH_MM", "TRAIN_WET_SPEED_PERCENT",
    "TRAIN_DEEP_SPEED_PERCENT", "WADING_DEPTH_MM", "DROWNING_DEPTH_MM",
    "MARKER_AREA_SLACK", "MIN_MARKER_AREA_M2", "SUBSAMPLE_M", "MAX_SUBSAMPLES", "RENDER_BUDGET_MS", "MAX_RENDERED_POOLS",
    "LARGE_LAKE_PLANES", "LARGE_LAKE_STEP_MM", "SLOW_FILL_MS", "RENDER_LOWER_STEP_MM", "ICE_FREEZE_HEAT",
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
    local measure = F.Diagnostics.Measure
    for _, effect in ipairs(EFFECTS) do
        local fn = F[effect.module][hook]
        if fn then measure(effect.key .. " " .. hook, fn, ...) end
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

-- The water step (rain, balance, evaporation, seepage over every basin) costs
-- hundreds of milliseconds on a flooded map, so it runs as a coroutine job in
-- WATER_STEP_BUDGET_MS slices: started on full ticks, continued on the 100 ms
-- wakes. While it runs, the snapshot and terrain handover wait (they read the
-- model); effects use the last complete depths. Saves, disabling and rain
-- changes finish it at once (L.Advance(true)).
local water_co, water_started, water_budget = false, 0, 0

local function water_yield()
    if water_co and coroutine.running() == water_co and GetPreciseTicks() - water_started >= water_budget then
        coroutine.yield()
    end
end

-- Resumes the running water step for one slice of budget_ms (or to the end when
-- sync). Returns true when no step is running any more.
local function continue_step(sync, budget_ms)
    local s = F.State
    local job = s.water_job
    if not job then return true end
    water_budget = math.min(budget_ms or F.Config.WATER_STEP_BUDGET_MS, F.Config.WATER_STEP_BUDGET_MS)
    repeat
        water_co, water_started = job.co, GetPreciseTicks()
        local ok, err = coroutine.resume(job.co)
        water_co = false
        if not ok then
            s.water_job = false
            error("water step failed: " .. tostring(err), 0)
        end
        if coroutine.status(job.co) == "dead" then
            s.water_job = false
            s.snapshot_due = true -- the next step waits for a snapshot pass and redraw
            return true
        end
    until not sync
    return false
end

function L.WaterStepRunning()
    return F.State.water_job ~= false and F.State.water_job ~= nil
end

-- Advances the water to the current game time: finishes a running step if sync
-- (otherwise lets it continue), then starts a step covering the time since the
-- last one, running its first slice (or all of it when sync).
function L.Advance(sync)
    local s = F.State
    if not s.enabled or s.saving or not s.model or s.building then return end
    if s.water_job and not continue_step(sync) then return end
    -- Steps and snapshot passes alternate, so the drawn water keeps up on a busy
    -- map (each step then covers all the time since the last one).
    if s.snapshot_due and not sync then return end
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
        local model, hours, rate, toxic, evaporation = s.model, elapsed * 1.0 / const.HourDuration,
            s.last_rate or 0, s.last_toxic == true, s.evaporation_mm_h
        s.water_job = { co = coroutine.create(function()
            F.Hydrology.Step(model, hours, rate, toxic, evaporation, infiltration, F.Config.RUNOFF_COEFFICIENT, water_yield)
            F.Groundwater.Collect(model.seepage)
        end) }
        s.last_tick = now
        s.last_rate, s.last_toxic, s.last_nominal_rate = F.Rain.Read()
        if sync then continue_step(true) end -- otherwise the pacer runs it in slices
        return
    end
    s.last_tick = now
    s.last_rate, s.last_toxic, s.last_nominal_rate = F.Rain.Read()
end

-- Starts the first build when there is no model, then runs one slice of the
-- terrain job if one is running (never while a water step is mid-way: the
-- handover captures the model the step is changing).
local function rebuild_slice(budget_ms)
    local s = F.State
    if s.water_job then return false end
    if not s.rebuild_job and not s.model then F.Terrain.StartRebuild(s.map) end
    if not s.rebuild_job then return false end
    if F.Terrain.StepRebuild(budget_ms) and not s.last_tick then
        s.last_tick = GameTime()
        s.last_rate, s.last_toxic, s.last_nominal_rate = F.Rain.Read()
    end
    return true
end

-- THE PACER. All of Flood's background work runs here, from a real-time thread
-- every BACKGROUND_WAKE_MS, whatever the game speed. Each wake shares one
-- BACKGROUND_BUDGET_MS of real time among the pending jobs, so Flood's
-- background share of the CPU is at most BACKGROUND_BUDGET_MS /
-- BACKGROUND_WAKE_MS and no single moment exceeds the budget plus one engine
-- call. The job with first claim on the budget rotates every wake, so a long job
-- (a background terrain rebuild, a big water step) never starves the others.
-- The snapshot and the terrain job run only between water steps: they read the
-- model a step changes. Before the first model exists (after a load) the build
-- gets REBUILD_SLICE_MS slices, so water appears quickly.
local PACER_JOBS = {
    function(s, budget) -- terrain rebuild (background: the model is in use)
        if not s.rebuild_job or s.water_job then return end
        F.Diagnostics.Measure("terrain rebuild", rebuild_slice, budget)
    end,
    function(s, budget) -- water step
        if not s.water_job then return end
        F.Diagnostics.Measure("water step", continue_step, false, budget)
    end,
    function(s, budget) -- depth snapshot
        if s.water_job or not (s.snapshot_due or not s.wet or F.Water.SnapshotPending()) then return end
        -- The first pass after a load gets a build slice; later ones their own cap.
        budget = (s.pools and s.wet) and math.min(budget, F.Config.SNAPSHOT_BUDGET_MS) or F.Config.REBUILD_SLICE_MS
        if F.Diagnostics.Measure("water snapshot", F.Water.SnapshotStep, budget) then
            s.snapshot_due, s.redraw_due, s.ice_due = false, true, true
            if s.recheck_flooding then
                -- After a load: saves hold no Flood suspensions (fl_buildings.lua).
                s.recheck_flooding = false
                F.Diagnostics.Measure("buildings recheck", F.Buildings.UpdateFlooding, 0)
            end
        end
    end,
    function(s, budget) -- lake redraw
        if not (s.redraw_due or (s.render_backlog or 0) > 0) then return end
        s.redraw_due = false
        F.Diagnostics.Measure("water redraw", F.Water.Refresh, budget)
    end,
    function(s, budget) -- ice
        if not (s.ice_due or (s.ice_backlog or 0) > 0) then return end
        s.ice_due = false
        F.Diagnostics.Measure("ice", F.Ice.Refresh, budget)
    end,
    function(s, budget) -- plane colours
        if F.Water.RestylePending() then
            F.Diagnostics.Measure("water colours", F.Water.RestyleStep, math.min(budget, F.Config.RESTYLE_BUDGET_MS))
        end
    end,
    function(s, budget) -- soil
        if F.Soil.Pending() then F.Diagnostics.Measure("soil", F.Soil.Step, math.min(budget, F.Config.EFFECT_STEP_BUDGET_MS)) end
    end,
}

local function background()
    local s, cfg = F.State, F.Config
    if not s.model then
        F.Diagnostics.Measure("terrain rebuild", rebuild_slice, cfg.REBUILD_SLICE_MS)
        return
    end
    local deadline = GetPreciseTicks() + cfg.BACKGROUND_BUDGET_MS
    local function left() return deadline - GetPreciseTicks() end
    local n = #PACER_JOBS
    s.pacer_turn = (s.pacer_turn or 0) % n + 1
    for i = 0, n - 1 do
        -- The first job always runs (at least one slice per wake); the rest share what is left.
        local budget = left()
        if not s.model or (i > 0 and budget <= 0) then return end
        PACER_JOBS[(s.pacer_turn + i - 1) % n + 1](s, math.max(1, budget))
    end
end

local function update_effects()
    local s = F.State
    s.ticks = s.ticks + 1
    -- Cold waves and other conditions change without the water moving.
    s.ice_due = true
    each_effect("Tick")
    local now = GameTime()
    if not s.last_effects then s.last_effects = now; return end
    local elapsed = now - s.last_effects
    if elapsed < F.Config.EFFECT_INTERVAL_HOURS * const.HourDuration then return end
    s.last_effects = now
    each_effect("Hourly", elapsed * 1.0 / const.HourDuration, s.last_nominal_rate or 0, s.last_toxic == true)
    F.Diagnostics.Report()
end

-- The full tick, every TICK_MS of game time: rain, a new water step (run by the
-- pacer), terrain tracking, effects. Short: the heavy work is the pacer's.
function L.Tick()
    local s = F.State
    if F.Config.ENABLE_MOD ~= true then L.Disable(); return end
    if s.saving then return end
    if not s.model then F.UI.Refresh(); return end -- first build still running (pacer)
    s.last_full_tick = GameTime()
    F.Rain.Sync()
    F.Diagnostics.Measure("water step start", L.Advance)
    F.Diagnostics.Measure("terrain check", F.Terrain.Track)
    F.ColdWave.Keep()
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

-- One pacer wake (real time; also while paused). While paused, game-time
-- threads stand still, so the wake also tracks terrain edits (construction can
-- be placed while paused) and starts rebuilds; it never steps the water or runs
-- effects: those follow game time.
function L.PacerTick()
    local s = F.State
    if F.Config.ENABLE_MOD ~= true or not s.enabled or s.saving or not s.map then return end
    -- New maps are generated and switched while paused; work only on a settled map
    -- (the same readiness test as vanilla AgentPlayTest.lua:181).
    if not GameState.gameplay or IsChangingMap() or rawget(_G, "GeneratingMap") then return end
    if IsPaused() and s.model then
        F.Terrain.Track()
        if F.Terrain.WantsRebuild() then F.Terrain.StartRebuild(s.map) end
        s.ice_due = true
    end
    background()
    if IsPaused() then F.UI.Refresh() end
end

-- Kept for callers and tests: a paused-time wake is a pacer wake.
L.PausedTick = L.PacerTick

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
        s.map, s.dirty, s.recheck_flooding = MainMap, true, true
    end
    s.enabled, s.error = true, false
    L.DetectFeatures()
    -- A map-owned game-time thread pauses with the game and dies with its map.
    s.thread = s.map:CreateGameTimeThread(function()
        Sleep(1) -- let all PostLoadGame handlers finish before creating transient visuals
        while s.enabled do
            if not guarded(L.Tick) then return end
            Sleep(F.Config.TICK_MS)
        end
    end)
    -- The pacer (background work, see background()). Real-time threads are not
    -- saved with the game.
    local map = s.map
    s.paused_thread = CreateRealTimeThread(function()
        Sleep(F.Config.BACKGROUND_WAKE_MS)
        while s.enabled and s.map == map do
            if not guarded(L.PacerTick) then return end
            Sleep(F.Config.BACKGROUND_WAKE_MS)
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
    if s.water_job then continue_step(true) end -- never leave the model half-stepped
end

function L.Disable()
    local s = F.State
    L.Advance(true)
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
    L.Advance(true)
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
    each_effect("PostSave")
    s.last_tick = GameTime()
    if s.resume_after_save then
        s.resume_after_save = false
        L.Enable()
    end
end
