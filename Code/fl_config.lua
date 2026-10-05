-- Flood configuration. Rates are millimetres per in-game hour, not wall time.
if rawget(_G, "Flood") and Flood.Lifecycle then Flood.Lifecycle.Disable() end
Flood = {}
Flood.Config = {
    ENABLE_MOD = true,
    ENABLE_TEST_UI = true,
    DEBUG_LOGS = true,
    DEBUG_HYDROLOGY = false,
    CELL_SIZE_M = 4,
    MAX_GRID_CELLS = 262144,
    SAMPLE_YIELD_ROWS = 1,
    REBUILD_SLICE_MS = 100,       -- first terrain read and model: real time per slice
    BACKGROUND_SLICE_MS = 15,     -- rebuild while the simulation runs: real time per slice
    TERRAIN_CHECK_MS = 3,                -- real time per tick re-reading terrain (edits, then the rolling check)
    TERRAIN_SETTLE_MS = 6000,            -- real time without new edits before a rebuild
    TERRAIN_YIELD_MS = 4,                -- real time a terrain job runs between yields
    SUBSAMPLE_M = 4,                  -- spacing of the sub-samples whose minimum is a cell's height
    MAX_SUBSAMPLES = 4,               -- per axis (so up to 16 height reads per cell)
    TICK_MS = 3000,                   -- game ms between simulation steps (1/10 game hour)
    RAIN_MM_H = { 5, 15, 40 },
    EVAPORATION_MM_H = 0.4,
    INFILTRATION_MM_H = 1.5,
    RUNOFF_COEFFICIENT = 0.65,
    TEST_STRENGTH = 3,
    TEST_RAIN_MULTIPLIER = 10,
    MIN_VISIBLE_DEPTH_MM = 10,
    RENDER_LEVEL_STEP_MM = 10,        -- rising level change that redraws a pool
    RENDER_LOWER_STEP_MM = 100,       -- falling: drying is slow and each redraw clears and refills
    RENDER_BUDGET_MS = 20,            -- real time per redraw step spent on native water; the rest waits
    MAX_RENDERED_POOLS = 400,         -- largest pools drawn; smaller ones still count in the model
    LARGE_LAKE_PLANES = 2000,         -- lakes this big (native water planes) redraw in coarser steps
    LARGE_LAKE_STEP_MM = 250,         -- level change that redraws a large lake
    SLOW_FILL_MS = 50,                -- a lake whose fill took longer waits proportionally longer to redraw
    MARKER_AREA_SLACK = 1.25,         -- drawn area may exceed the model's wetted area by at most this factor;
                                      -- the engine lowers a surface rather than draw water the model lacks
    MIN_MARKER_AREA_M2 = 600,         -- floor for tiny pools (about two 16 m cells)
    FRESH_COLOR = { 90, 151, 170 },
    TOXIC_COLOR = { 161, 181, 59 },
    UI_LEFT = 24,
    UI_TOP = 200,

    -- Gameplay effects. Each ENABLE_* switch is independent.
    DEBUG_EFFECTS = true,             -- per-pass effect summaries; also requires DEBUG_LOGS
    BACKGROUND_WAKE_MS = 50,          -- real time between background work wakes (any game speed)
    BACKGROUND_BUDGET_MS = 8,         -- real time all background work shares per wake
    WATER_STEP_BUDGET_MS = 6,         -- real time per slice of the water step (rain, balance, drying)
    EFFECT_STEP_BUDGET_MS = 4,        -- real time per slice of the hourly soil pass
    SNAPSHOT_BUDGET_MS = 6,           -- real time per step keeping the depth snapshot current
    RESTYLE_BUDGET_MS = 4,            -- real time per step copying water colours to lake planes
    PROFILE_WINDOW_MS = 10000,        -- real time over which the panel shows Flood's slowest step
    SNAPSHOT_LEVEL_EPS_MM = 1,        -- level change below which a lake's cells are not rewalked
    EFFECT_INTERVAL_HOURS = 1,        -- cadence of building, soil and groundwater effects

    -- 1. Thin, cold air removes standing water fast. EVAPORATION_MM_H is multiplied
    -- by up to EVAPORATION_BARREN_MULTIPLIER at 0% habitability, falling to 1 at
    -- 100%, where habitability = min(Atmosphere, Temperature) terraforming percent.
    ENABLE_CLIMATE_EVAPORATION = true,
    EVAPORATION_BARREN_MULTIPLIER = 25,

    -- 2. Outdoor buildings under deep water stop working; shallow water wears them.
    ENABLE_BUILDING_FLOODING = true,
    FLOOD_SUSPEND_DEPTH_MM = 300,
    FLOOD_RESUME_DEPTH_MM = 250,
    FLOOD_WEAR_PER_HOUR = 0.02,       -- share of maintenance threshold per hour at suspend depth

    -- 3. Fresh water soaking into the ground recharges nearby water deposits.
    ENABLE_GROUNDWATER_RECHARGE = true,
    RECHARGE_RADIUS_M = 150,
    RECHARGE_LITRES_PER_UNIT = 1000,  -- litres per displayed Water resource unit

    -- 4. Toxic water and dried toxic residue lower soil quality locally.
    ENABLE_TOXIC_SOIL = true,
    TOXIC_SOIL_PCT_PER_HOUR = 0.5,    -- soil % lost per hour under fully toxic water
    RESIDUE_SOIL_PCT_PER_HOUR = 0.25, -- soil % lost per hour under a full residue load
    RESIDUE_FULL_EFFECT_MM = 20,      -- residue load (mm of toxic water) for the full rate
    RESIDUE_MAX_RADIUS_M = 60,

    -- Rain-driven effects scale with the nominal storm rate (never the test preview
    -- multiplier) relative to this reference rate.
    RAIN_REFERENCE_MM_H = 15,

    -- 5a. Any rain washes accumulated dust off every object that accumulates it
    -- (buildings, domes, cables, pipes, drones, rovers) in the open air.
    ENABLE_RAIN_DUST_WASHING = true,
    RAIN_DUST_WASH_PER_HOUR = 0.05,   -- share of const.MaxMaintenance washed per hour

    -- 5b. Toxic rain is acidic: it corrodes outdoor buildings (net of the washing above).
    ENABLE_TOXIC_CORROSION = true,
    RAIN_CORROSION_PER_HOUR = 0.08,   -- share of maintenance threshold added per hour

    -- 6. Rovers slow in deep water; building on flooded ground is warned or blocked.
    ENABLE_ROVER_SLOWDOWN = true,
    ROVER_SLOW_DEPTH_MM = 200,
    ROVER_SLOW_PERCENT = 40,
    ENABLE_CONSTRUCTION_RULES = true,

    -- 7. Fresh standing water raises soil quality locally (the game's local vegetation lever).
    ENABLE_FRESH_SOIL = true,
    FRESH_SOIL_PCT_PER_HOUR = 0.2,
    FRESH_SOIL_MAX_PCT = 60,          -- fresh water never raises soil above this

    -- Rovers driven past fording depth can short out and break down (drones repair them).
    ENABLE_ROVER_BREAKDOWN = true,
    ROVER_FORD_DEPTH_MM = 700,
    ROVER_SUBMERGED_BREAKDOWN_PER_HOUR = 0.3, -- chance per hour submerged; toxic water up to double

    -- Drones: slower in rain, battery drain when hovering in deep water, toxic grime.
    ENABLE_DRONE_EFFECTS = true,
    DRONE_RAIN_SLOW_PERCENT = 15,     -- at the reference rate
    DRONE_RAIN_SLOW_MAX_PERCENT = 40,
    DRONE_SHORT_DEPTH_MM = 250,
    DRONE_WATER_BATTERY_PER_HOUR = 0.25, -- share of battery_max lost per hour in deep water
    DRONE_TOXIC_GRIME_PER_HOUR = 0.10,   -- share of the drone's dust limit per hour, at the reference rate

    -- Shuttles: slower in rain; grounded (hubs suspended, as in dust storms) in severe storms.
    ENABLE_SHUTTLE_EFFECTS = true,
    SHUTTLE_RAIN_SLOW_PERCENT = 10,   -- at the reference rate
    SHUTTLE_RAIN_SLOW_MAX_PERCENT = 35,
    SHUTTLE_GROUND_RAIN_MM_H = 40,    -- heavy storms and above ground shuttles

    -- Trains crawl over flooded rails.
    ENABLE_TRAIN_EFFECTS = true,
    TRAIN_WET_DEPTH_MM = 100,         -- rails under water
    TRAIN_WET_SPEED_PERCENT = 50,
    TRAIN_DEEP_DEPTH_MM = 400,        -- water over the axles
    TRAIN_DEEP_SPEED_PERCENT = 15,

    -- Colonists in the open (outside domes, or in opened domes, not inside a building).
    -- Suits seal them while the air is unbreathable, so then toxic rain only stresses them.
    ENABLE_COLONIST_EFFECTS = true,
    TOXIC_RAIN_SANITY_PER_HOUR = 2,   -- stat points per hour exposed, at the reference rate
    TOXIC_RAIN_HEALTH_PER_HOUR = 4,   -- breathable air only (skin exposure)
    TOXIC_WATER_HEALTH_PER_HOUR = 6,  -- per hour in fully toxic water, breathable air only
    FRESH_RAIN_SANITY_PER_HOUR = 1,   -- walking in fresh rain under an open sky
    WADING_DEPTH_MM = 500,
    WADING_SANITY_PER_HOUR = 3,
    DROWNING_DEPTH_MM = 1400,
    DROWNING_HEALTH_PER_HOUR = 30,

    -- Ice: frozen puddles and lakes get a walkable surface (Martian Waters-style plates).
    ENABLE_ICE = true,
    ICE_PLANET_COLD = true,           -- frozen while the planet's water is frozen (vanilla WaterFrozen)
    ICE_FREEZE_HEAT = 100,            -- local heat below this freezes water (const.DefaultFreezeHeat)
    ICE_THAW_MARGIN = 16,             -- heat above the freeze level before ice thaws
    ICE_TILE_M = 30,                  -- ice plate size
    MAX_ICE_PLATES = 4000,
    ICE_BUDGET_MS = 8,                -- real time per ice refresh (passability rebuilds included)
    ICE_BATCH_PLATES = 1,             -- plates per passability rebuild (1: the shortest possible step)
    ICE_DEPTH_BIN_MM = 50,            -- depth classes for laying ice from the shore inward
    ICE_RELEVEL_MM = 250,             -- level change before a frozen lake's plates move
    ICE_SUBLIMATION_FACTOR = 0.1,     -- evaporation share while the planet's water is frozen
}
