local F = Flood
local T = {}
F.Terrain = T

-- A rebuild (sampling, the depression hierarchy, restoring saved water) costs
-- about 30M Lua lines on a 6 km map. The engine's infinite-loop watchdog stops a
-- thread at about 30M lines, and in-game it counted straight through the
-- rebuild's Sleep(0) yields ("sleeps 65" and "sleeps 78" in its reports). So a
-- rebuild runs as a coroutine job resumed for at most REBUILD_SLICE_MS of real
-- time per simulation tick. Each slice's tick then ends with a timed game-time
-- Sleep (REBUILD_SLICE_SLEEP_MS), the same kind of wait that ends every tick.
local job_co = false

-- Yield point inside the heavy loops: suspends the rebuild job, and does nothing
-- when called outside it.
function T.Yield()
    if job_co and coroutine.running() == job_co then coroutine.yield() end
end

function T.Sample(map)
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
    local n = math.max(1, math.min(F.Config.MAX_SUBSAMPLES,
        math.ceil(dx / (F.Config.SUBSAMPLE_M * guim))))
    local sub_x, sub_y = dx / n, dy / n
    local heights, low_x, low_y = {}, {}, {}
    local get_height = terrain.GetHeight
    for y = 1, h do
        for x = 1, w do
            local best, bx, by
            for j = 1, n do
                local wy = math.floor((y - 1) * dy + (j - 0.5) * sub_y)
                for i = 1, n do
                    local wx = math.floor((x - 1) * dx + (i - 0.5) * sub_x)
                    local z = get_height(map, point(wx, wy))
                    if not best or z < best then best, bx, by = z, wx, wy end
                end
            end
            local k = #heights + 1
            heights[k], low_x[k], low_y[k] = best * 1000.0 / guim, bx, by
        end
        if y % F.Config.SAMPLE_YIELD_ROWS == 0 then T.Yield() end
    end
    return { width = w, height = h, sx = sx, sy = sy, dx = dx, dy = dy, subsamples = n,
        elevations = heights, low_x = low_x, low_y = low_y, area = dx * dy / (guim * guim * 1.0) }
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

-- The job body: pure Lua plus terrain reads (no engine waits, so it can run as
-- a coroutine). Returns nothing when the terrain is unchanged.
local function compute(map)
    local s = F.State
    local grid = T.Sample(map)
    local old = s.grid
    local changed = not old or old.width ~= grid.width or old.height ~= grid.height
    if not changed then
        for i, z in ipairs(grid.elevations) do
            if old.elevations[i] ~= z then changed = true; break end
        end
    end
    if not changed then return end
    local records = s.model and F.Save.Capture() or map.fl_saved
    local model = F.Hydrology.Build(grid.width, grid.height, grid.elevations, grid.area, T.Yield)
    if records then F.Save.Import(model, grid, records, T.Yield) end
    return grid, model, records ~= false and records ~= nil
end

-- Starts a rebuild job; the old model stays in use (frozen) until it finishes.
function T.StartRebuild(map)
    local s = F.State
    s.building = true
    s.status = "Scanning terrain..."
    s.rebuild_job = { co = coroutine.create(compute), map = map, slices = 0, started = GameTime() }
end

-- Resumes the job for one slice. Returns true once it has finished and its
-- result is installed. A failure cancels the job and raises its error.
function T.StepRebuild()
    local s = F.State
    local job = s.rebuild_job
    local started = GetPreciseTicks()
    job.slices = job.slices + 1
    repeat
        job_co = job.co
        local ok, grid, model, restored = coroutine.resume(job.co, job.map)
        job_co = false
        if not ok then
            T.CancelRebuild()
            error("terrain rebuild failed: " .. tostring(grid), 0)
        end
        if coroutine.status(job.co) == "dead" then
            s.rebuild_job, s.building, s.dirty = false, false, false
            if grid then
                F.Water.Clear(job.map)
                s.grid, s.model = grid, model
                F.Log("Terrain", "depression hierarchy rebuilt", { cells = grid.width * grid.height,
                    basins = #model.nodes, cell_width_m = grid.dx * 1.0 / guim,
                    cell_height_m = grid.dy * 1.0 / guim, restored = restored, slices = job.slices })
            end
            return true
        end
    until GetPreciseTicks() - started >= F.Config.REBUILD_SLICE_MS
    return false
end

-- Drops an unfinished job (save, disable, map change, error); the terrain is
-- scanned again later. Idempotent.
function T.CancelRebuild()
    local s = F.State
    if s.rebuild_job then
        F.Log("Terrain", "rebuild cancelled", { slices = s.rebuild_job.slices })
        s.dirty = true
    end
    s.rebuild_job, s.building = false, false
    job_co = false
end
