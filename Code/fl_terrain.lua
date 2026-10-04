local F = Flood
local T = {}
F.Terrain = T

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
    local heights = {}
    for y = 1, h do
        for x = 1, w do
            local wx, wy = math.floor((x - 0.5) * dx), math.floor((y - 0.5) * dy)
            heights[#heights + 1] = terrain.GetHeight(map, point(wx, wy)) * 1000.0 / guim
        end
        if y % F.Config.SAMPLE_YIELD_ROWS == 0 then Sleep(0) end
    end
    return { width = w, height = h, sx = sx, sy = sy, dx = dx, dy = dy,
        elevations = heights, area = dx * dy / (guim * guim * 1.0) }
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

function T.Rebuild(map)
    local s = F.State
    s.building = true
    s.status = "Scanning terrain..."
    local grid = T.Sample(map)
    local old = s.grid
    local changed = not old or old.width ~= grid.width or old.height ~= grid.height
    if not changed then
        for i, z in ipairs(grid.elevations) do
            if old.elevations[i] ~= z then changed = true; break end
        end
    end
    if not changed then s.building = false; s.dirty = false; return end
    local records = s.model and F.Save.Capture() or map.fl_saved
    local model = F.Hydrology.Build(grid.width, grid.height, grid.elevations, grid.area, function() Sleep(0) end)
    if records then F.Save.Import(model, grid, records) end
    F.Water.Clear(map)
    s.grid, s.model, s.dirty, s.building = grid, model, false, false
    F.Log("Terrain", "depression hierarchy rebuilt", { cells = grid.width * grid.height,
        basins = #model.nodes, cell_width_m = grid.dx * 1.0 / guim,
        cell_height_m = grid.dy * 1.0 / guim, restored = records ~= false and records ~= nil })
end

