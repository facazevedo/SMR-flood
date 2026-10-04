local F = Flood
local T = {}
F.Terrain = T

-- Terrain is read once per map (TERRAIN READ below) and kept in F.State.terrain.
-- Afterwards only changed areas are read again:
--   * announced edits: construction flattening (every building, track, cable,
--     pipe, passage, demolition: FlattenTerrainInBuildShape, wrapped below),
--     prefabs (meteor craters, lakes, crystals: PrefabPlaced), landscaping
--     (LandscapeCompleted) and dome height surfaces (ConstructionComplete);
--   * silent edits (excavators, regolith extractors, Mirror Sphere digging send
--     no message): a rolling check re-reads TERRAIN_CHECK_ROWS_PER_TICK rows per
--     tick and cycles over the whole map.
-- When heights changed, the depression hierarchy is rebuilt in the background
-- while the simulation keeps running on the current model, then handed over.
--
-- The heavy work (first read, hierarchy, restoring water) costs about 30M Lua
-- lines on a 6 km map. The engine's infinite-loop watchdog stops a thread at
-- about 30M lines and in-game counted straight through Sleep(0) yields
-- ("sleeps 65", "sleeps 78" in its reports). So that work runs as a coroutine
-- job resumed for a few milliseconds at a time; between resumes the simulation
-- thread takes a timed Sleep (REBUILD_SLICE_SLEEP_MS), the kind of wait that ends
-- every simulation tick.
local job_co = false
local phase = "read" -- the job's current phase, for slice diagnostics
local resumed_at = 0

-- Yield point inside the heavy loops, which call it every few hundred steps: it
-- suspends the job once TERRAIN_YIELD_MS of real time has passed since the job
-- was resumed, and does nothing outside the job. Checking the clock instead of
-- counting steps keeps every step short whatever the loop and the machine.
function T.Yield()
    if job_co and coroutine.running() == job_co and GetPreciseTicks() - resumed_at >= F.Config.TERRAIN_YIELD_MS then
        coroutine.yield()
    end
end

-- Cell layout for a map: about CELL_SIZE_M cells, coarser if the map is large.
local function new_grid(map)
    local sx, sy = terrain.GetMapSize(map)
    local step = math.max(F.Config.CELL_SIZE_M * guim, const.HeightTileSize)
    local w, h = math.ceil(sx * 1.0 / step), math.ceil(sy * 1.0 / step)
    while w * h > F.Config.MAX_GRID_CELLS do
        step = step * 2
        w, h = math.ceil(sx * 1.0 / step), math.ceil(sy * 1.0 / step)
    end
    assert(w >= 3 and h >= 3, "surface map too small for hydrology")
    local dx, dy = sx * 1.0 / w, sy * 1.0 / h
    -- Each cell takes the LOWEST of n x n sub-samples, not its centre: a single
    -- centre sample misses notches narrower than a cell, so the model would hold
    -- water above the real rim and the native fill would flood the surroundings
    -- (seen in-game: one lake spread across the whole map).
    local n = math.max(1, math.min(F.Config.MAX_SUBSAMPLES, math.ceil(dx / (F.Config.SUBSAMPLE_M * guim))))
    return { width = w, height = h, sx = sx, sy = sy, dx = dx, dy = dy, subsamples = n,
        elevations = {}, low_x = {}, low_y = {}, area = dx * dy / (guim * guim * 1.0) }
end

-- Reads cells [x0, x1] x [y0, y1] (0-based) into grid. Returns how many cells
-- changed height (cells read for the first time count as changed).
local function read_cells(map, grid, x0, x1, y0, y1)
    local n, dx, dy = grid.subsamples, grid.dx, grid.dy
    local sub_x, sub_y = dx / n, dy / n
    local heights, low_x, low_y, w = grid.elevations, grid.low_x, grid.low_y, grid.width
    local get_height = terrain.GetHeight
    local changed = 0
    for y = y0, y1 do
        for x = x0, x1 do
            local best, bx, by
            for j = 1, n do
                local wy = math.floor(y * dy + (j - 0.5) * sub_y)
                for i = 1, n do
                    local wx = math.floor(x * dx + (i - 0.5) * sub_x)
                    local z = get_height(map, point(wx, wy))
                    if not best or z < best then best, bx, by = z, wx, wy end
                end
            end
            local k = y * w + x + 1
            local height = best * 1000.0 / guim
            if heights[k] ~= height then changed = changed + 1 end
            heights[k], low_x[k], low_y[k] = height, bx, by
        end
    end
    return changed
end

-- TERRAIN READ: the whole map, once (yields every SAMPLE_YIELD_ROWS rows).
function T.Sample(map)
    local grid = new_grid(map)
    for y = 0, grid.height - 1 do
        read_cells(map, grid, 0, grid.width - 1, y, y)
        if (y + 1) % F.Config.SAMPLE_YIELD_ROWS == 0 then T.Yield() end
    end
    return grid
end

-- Lowest sampled point of a cell: where a water surface at the cell's level
-- is guaranteed to stand on real terrain (a native fill must start in water).
function T.LowPoint(grid, index)
    return grid.low_x[index], grid.low_y[index]
end

function T.Position(grid, index)
    local x = (index - 1) % grid.width
    local y = math.floor((index - 1) * 1.0 / grid.width)
    return math.floor((x + 0.5) * grid.dx), math.floor((y + 0.5) * grid.dy)
end

-- Grid cell containing a world position, or nil outside the sampled map.
function T.Cell(grid, x, y)
    local cx = math.floor(x * 1.0 / grid.dx)
    local cy = math.floor(y * 1.0 / grid.dy)
    if cx < 0 or cy < 0 or cx >= grid.width or cy >= grid.height then return nil end
    return cy * grid.width + cx + 1
end

---------------------------------------------------------------------------
-- Change tracking
---------------------------------------------------------------------------

-- An announced terrain edit: queues its world box (grown by one cell) for a
-- re-read on the next tick. Ignored before the first read or for other maps.
function T.MarkChanged(map, bbox, reason)
    local s = F.State
    local grid = s.terrain
    -- Only real boxes: the vanilla flatten returns an error string instead when it
    -- cannot flatten ("Trying to build on unbuildable grid location").
    if not grid or map ~= s.map or not IsBox(bbox) then return end
    local x0 = math.max(0, math.floor(bbox:minx() / grid.dx) - 1)
    local y0 = math.max(0, math.floor(bbox:miny() / grid.dy) - 1)
    local x1 = math.min(grid.width - 1, math.floor(bbox:maxx() / grid.dx) + 1)
    local y1 = math.min(grid.height - 1, math.floor(bbox:maxy() / grid.dy) + 1)
    if x1 < x0 or y1 < y0 then return end
    s.terrain_boxes[#s.terrain_boxes + 1] = { x0 = x0, x1 = x1, y0 = y0, y1 = y1, row = y0, reason = reason }
    if F.Config.DEBUG_HYDROLOGY == true then
        F.Log("Terrain", "edit announced", { reason = reason, cells = (x1 - x0 + 1) * (y1 - y0 + 1) })
    end
end

local function note_change(changed, source)
    local s = F.State
    if changed <= 0 then return end
    s.terrain_changed, s.terrain_changed_at = true, RealTime()
    F.Log("Terrain", "terrain heights changed", { cells = changed, source = source })
end

-- Called every simulation tick: re-reads queued edit boxes (at most
-- TERRAIN_BOX_CELLS_PER_TICK cells) and the next TERRAIN_CHECK_ROWS_PER_TICK rows
-- of the rolling check. Cheap; never reads the whole map.
function T.Track()
    local s, cfg = F.State, F.Config
    local grid = s.terrain
    if not grid or not s.map then return end
    local budget = cfg.TERRAIN_BOX_CELLS_PER_TICK
    while budget > 0 and #s.terrain_boxes > 0 do
        local b = s.terrain_boxes[1]
        local rows = math.max(1, math.floor(budget / (b.x1 - b.x0 + 1)))
        local last = math.min(b.y1, b.row + rows - 1)
        note_change(read_cells(s.map, grid, b.x0, b.x1, b.row, last), b.reason or "edit")
        budget = budget - (last - b.row + 1) * (b.x1 - b.x0 + 1)
        b.row = last + 1
        if b.row > b.y1 then table.remove(s.terrain_boxes, 1) end
    end
    local first = s.check_row or 0
    local last = math.min(grid.height - 1, first + cfg.TERRAIN_CHECK_ROWS_PER_TICK - 1)
    note_change(read_cells(s.map, grid, 0, grid.width - 1, first, last), "rolling check")
    s.check_row = last + 1 < grid.height and last + 1 or 0
end

-- A rebuild is due when there is no model yet, or when heights changed and have
-- stayed unchanged for TERRAIN_SETTLE_MS of real time (one rebuild per burst of
-- construction, not one per building; real time, so it also happens while the
-- game is paused).
function T.WantsRebuild()
    local s = F.State
    if s.rebuild_job then return false end
    if not s.model then return true end
    return s.terrain_changed == true and #s.terrain_boxes == 0
        and RealTime() - (s.terrain_changed_at or 0) >= F.Config.TERRAIN_SETTLE_MS
end

---------------------------------------------------------------------------
-- Rebuild job
---------------------------------------------------------------------------

local function copy_grid(grid)
    local copy = {}
    for k, v in pairs(grid) do copy[k] = v end
    copy.elevations, copy.low_x, copy.low_y = {}, {}, {}
    local e, lx, ly = grid.elevations, grid.low_x, grid.low_y
    for i = 1, #e do
        copy.elevations[i], copy.low_x[i], copy.low_y[i] = e[i], lx[i], ly[i]
        if i % 2048 == 0 then T.Yield() end
    end
    return copy
end

-- The job body: pure Lua plus terrain reads (no engine waits, so it can run as
-- a coroutine). Yields "handover" before touching the live water.
local function compute(map)
    local s = F.State
    phase = "read"
    if not s.terrain then s.terrain = T.Sample(map) end
    -- Changes read after this point trigger the next rebuild.
    s.terrain_changed = false
    phase = "copy"
    local grid = copy_grid(s.terrain)
    phase = "build"
    local model = F.Hydrology.Build(grid.width, grid.height, grid.elevations, grid.area, T.Yield)
    -- Handover: from here the water is frozen (Advance skips) until installed.
    coroutine.yield("handover")
    phase = "capture"
    local records = s.model and s.grid and F.Save.Capture(T.Yield) or map.fl_saved
    phase = "restore"
    if records then F.Save.Import(model, grid, records, T.Yield) end
    return grid, model, records ~= false and records ~= nil
end

function T.StartRebuild(map)
    local s = F.State
    s.building = not s.model -- with a model, the simulation keeps running until the handover
    if not s.model then s.status = "Scanning terrain..." end
    s.rebuild_job = { co = coroutine.create(compute), map = map, slices = 0, started = GameTime(),
        background = s.model ~= false, work_ms = 0, max_slice_ms = 0, handover_slices = 0, phase_max_ms = {} }
end

-- Markers are keyed by basin node, and a rebuild renumbers nodes. Each marker is
-- re-keyed by its pool's lowest cell; the next redraw's merge/split matching
-- (fl_water.lua) moves it onto the pool now holding that cell, so the drawn water
-- stays in place instead of being cleared and redrawn.
local function rekey_markers(old_model, new_model)
    local s = F.State
    local rekeyed, retired = {}, 0
    for id, entry in pairs(s.markers) do
        local node = old_model and old_model.nodes[id]
        local leaf = node and new_model.sinks[node.seed]
        if leaf and leaf ~= 0 and not rekeyed[leaf] then
            rekeyed[leaf] = entry
        else
            if F.Ice then F.Ice.Remove(entry) end
            s.retiring[#s.retiring + 1] = entry.obj
            retired = retired + 1
        end
    end
    s.markers = rekeyed
    return retired
end

-- Resumes the job for one slice: BACKGROUND_SLICE_MS while a model is running,
-- REBUILD_SLICE_MS for the first build. Returns true once it has finished and
-- its result is installed. A failure cancels the job and raises its error.
function T.StepRebuild()
    local s = F.State
    local job = s.rebuild_job
    local slice = job.background and F.Config.BACKGROUND_SLICE_MS or F.Config.REBUILD_SLICE_MS
    local started = GetPreciseTicks()
    job.slices = job.slices + 1
    if job.handover then job.handover_slices = job.handover_slices + 1 end
    local function account()
        local ms = GetPreciseTicks() - started
        job.work_ms, job.max_slice_ms = job.work_ms + ms, math.max(job.max_slice_ms, ms)
    end
    repeat
        job_co = job.co
        local resumed = GetPreciseTicks()
        resumed_at = resumed
        local ok, grid, model, restored = coroutine.resume(job.co, job.map)
        job_co = false
        local step_ms = GetPreciseTicks() - resumed
        job.phase_max_ms[phase] = math.max(job.phase_max_ms[phase] or 0, step_ms)
        if not ok then
            T.CancelRebuild()
            error("terrain rebuild failed: " .. tostring(grid), 0)
        end
        if grid == "handover" then
            s.building, job.handover = true, true
        elseif coroutine.status(job.co) == "dead" then
            account()
            local old_model = s.model
            local retired = rekey_markers(old_model, model)
            s.grid, s.model = grid, model
            s.rebuild_job, s.building, s.dirty = false, false, false
            s.wet, s.wet_concentration = false, false
            -- Kept for diagnostics and the in-game test: how smooth the rebuild was.
            s.last_terrain_rebuild = { background = job.background, slices = job.slices, work_ms = job.work_ms,
                max_slice_ms = job.max_slice_ms, handover_slices = job.handover_slices, phase_max_ms = job.phase_max_ms,
                game_ms = GameTime() - job.started, markers_retired = retired }
            F.Log("Terrain", "depression hierarchy rebuilt", { cells = grid.width * grid.height,
                basins = #model.nodes, restored = restored, slices = job.slices, background = job.background,
                work_ms = job.work_ms, max_slice_ms = job.max_slice_ms, markers_retired = retired,
                build_ms = job.phase_max_ms.build, restore_ms = job.phase_max_ms.restore,
                capture_ms = job.phase_max_ms.capture, read_ms = job.phase_max_ms.read })
            return true
        end
    until GetPreciseTicks() - started >= slice
    account()
    return false
end

-- Drops an unfinished job (save, disable, map change, error). A background job
-- leaves the current model in place and is retried; a first build restarts.
-- Idempotent.
function T.CancelRebuild()
    local s = F.State
    if s.rebuild_job then
        F.Log("Terrain", "rebuild cancelled", { slices = s.rebuild_job.slices, background = s.rebuild_job.background })
        if s.model then s.terrain_changed, s.terrain_changed_at = true, 0 else s.dirty = true end
    end
    s.rebuild_job, s.building = false, false
    job_co = false
end

-- Forgets the stored terrain (map change, load): the next build reads it again.
function T.Reset()
    local s = F.State
    T.CancelRebuild()
    s.terrain, s.terrain_boxes, s.check_row = false, {}, 0
    s.terrain_changed, s.terrain_changed_at = false, 0
end

---------------------------------------------------------------------------
-- Construction flattening hook
---------------------------------------------------------------------------

-- Every runtime flatten (construction sites, instant builds, cables, pipes,
-- passages, tracks, demolition and cancel restores) goes through the global
-- FlattenTerrainInBuildShape (Construction.lua:2474-2510), which returns the
-- flattened world box that every caller discards. The wrapper passes everything
-- through unchanged and queues that box.
-- In the mod sandbox, _G is the sandbox itself and rawset would only shadow the
-- global for this mod; a plain assignment to an existing global goes through the
-- sandbox's __newindex to the real global (Mod.lua:1570-1576), which is what
-- vanilla callers see. The original and the wrapper are kept on this mod's
-- ModDef (CurrentModDef, Mod.lua SetupEnv), which outlives reloads of the mod's
-- code, so a reload never wraps the wrapper; after a full Lua reload the global
-- is vanilla again and is wrapped afresh.
function T.FlattenHookAvailable()
    return type(rawget(_G, "CurrentModDef")) == "table" and type(FlattenTerrainInBuildShape) == "function"
        and type(IsBox) == "function"
end

if T.FlattenHookAvailable() then
    local holder = rawget(_G, "CurrentModDef")
    local current = FlattenTerrainInBuildShape
    local vanilla_flatten = current == holder.FloodFlattenWrapper and holder.FloodVanillaFlatten or current
    local function note_flatten(obj, bbox, ...)
        if F.State.terrain and IsValid(obj) and IsBox(bbox) then
            T.MarkChanged(obj:GetMap(), bbox, "construction flattening")
        end
        return bbox, ...
    end
    local function wrapper(shape_data, obj, ...)
        return note_flatten(obj, vanilla_flatten(shape_data, obj, ...))
    end
    holder.FloodVanillaFlatten, holder.FloodFlattenWrapper = vanilla_flatten, wrapper
    FlattenTerrainInBuildShape = wrapper
end
