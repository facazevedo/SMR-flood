-- Effect 4: toxic water and dried toxic residue lower soil quality locally.
-- Effect 7: fresh standing water raises soil quality locally, up to a cap.
-- The game has no local vegetation-growth API; plants respond to the soil grid
-- (Vegetation_CheckRequirements), which is how toxic pools and Landscaping lakes
-- act locally too. Writes use the per-hex form SoilAdd(q, r, delta) as in
-- SensorTower.lua:111-114, with delta in percent * const.SoilGridScale, followed by
-- one OnSoilGridChanged(). The soil grid exists only on the main map.
local F = Flood
local S = {}
F.Soil = S

function S.Available()
    for _, name in ipairs({ "SoilAdd", "GetSoilQuality", "OnSoilGridChanged", "WorldToHex",
        "HexToWorld", "ForEachHexInCircle" }) do
        if type(rawget(_G, name)) ~= "function" then return false, name .. " unavailable" end
    end
    if type(const.SoilGridScale) ~= "number" then return false, "const.SoilGridScale unavailable" end
    return true
end

-- The pass touches every wet cell and thousands of hexes, so it runs as a job in
-- EFFECT_STEP_BUDGET_MS slices on the 100 ms wakes (S.Step): cells are walked by
-- index (the depth table changes between slices; a pairs walk could not
-- resume), then the residue footprints, then the hex writes, and a single
-- OnSoilGridChanged at the end. An hour ending before the previous pass is done
-- folds its hours into it.
local job = false

local function hex_key(q, r) return (q + 32768) * 65536 + (r + 32768) end

function S.Hourly(hours)
    local s, cfg = F.State, F.Config
    if s.features.soil ~= true or s.map ~= MainMap or not SoilGrid or not s.model then return end
    if cfg.ENABLE_TOXIC_SOIL ~= true and cfg.ENABLE_FRESH_SOIL ~= true then return end
    if job and job.map == s.map and job.grid == s.grid then job.hours = job.hours + hours; return end
    job = { map = s.map, grid = s.grid, model = s.model, hours = hours, phase = "wet", i = 1,
        n = s.grid.width * s.grid.height, hexes = {}, residues = false, r = 1, list = false, k = 1,
        lowered = 0, raised = 0 }
end

function S.Pending() return job ~= false end

local function hex_of(hexes, q, r)
    local key = hex_key(q, r)
    local h = hexes[key]
    if not h then h = { q = q, r = r, sum = 0, cells = 0, residue = 0 }; hexes[key] = h end
    return h
end

-- Advances the pass for at most budget_ms of real time. Returns true while work remains.
function S.Step(budget_ms)
    if not job then return false end
    local s, cfg = F.State, F.Config
    if s.map ~= job.map or s.grid ~= job.grid or not s.wet then job = false; return false end
    local deadline = GetPreciseTicks() + budget_ms
    local toxic_on, fresh_on = cfg.ENABLE_TOXIC_SOIL == true, cfg.ENABLE_FRESH_SOIL == true
    local hexes, grid = job.hexes, job.grid
    if job.phase == "wet" then
        -- Standing water: average the per-cell rate over the cells inside each hex.
        local wet, concentration = s.wet, s.wet_concentration
        for i = job.i, job.n do
            local depth = wet[i]
            if depth and depth >= cfg.MIN_VISIBLE_DEPTH_MM then
                local c = concentration[i] or 0
                local rate = (toxic_on and -cfg.TOXIC_SOIL_PCT_PER_HOUR * c or 0)
                    + (fresh_on and cfg.FRESH_SOIL_PCT_PER_HOUR * (1 - c) or 0)
                local h = hex_of(hexes, WorldToHex(F.Terrain.Position(grid, i)))
                h.sum, h.cells = h.sum + rate, h.cells + 1
            end
            if i % 512 == 0 and GetPreciseTicks() >= deadline then job.i = i + 1; return true end
        end
        job.phase = "residue"
        job.residues = toxic_on and F.Hydrology.Residues(job.model) or {}
    end
    if job.phase == "residue" then
        -- Dry residue: load is toxic water depth equivalent spread over the dried basin.
        while job.r <= #job.residues do
            local residue = job.residues[job.r]
            job.r = job.r + 1
            local area_m2 = residue.cells * job.model.area
            local strength = math.min(1, residue.mass * 1.0 / area_m2 / cfg.RESIDUE_FULL_EFFECT_MM)
            local radius_m = math.min(cfg.RESIDUE_MAX_RADIUS_M, math.sqrt(area_m2 / math.pi))
            local x, y = F.Terrain.Position(grid, residue.seed)
            ForEachHexInCircle(point(x, y), math.max(1, math.floor(radius_m * guim)), function(q, r)
                local wx, wy = HexToWorld(q, r)
                if wx >= 0 and wy >= 0 and wx < grid.sx and wy < grid.sy then
                    local h = hex_of(hexes, q, r)
                    h.residue = h.residue + cfg.RESIDUE_SOIL_PCT_PER_HOUR * strength
                end
            end)
            if GetPreciseTicks() >= deadline then return true end
        end
        job.phase = "apply"
        job.list = {}
        for _, h in pairs(hexes) do job.list[#job.list + 1] = h end
    end
    -- Apply: one SoilAdd per hex, capped (vanilla SoilAdd, SensorTower.lua:111-114).
    local scale = const.SoilGridScale
    local list = job.list
    while job.k <= #list do
        local h = list[job.k]
        job.k = job.k + 1
        local pct = ((h.cells > 0 and h.sum * 1.0 / h.cells or 0) - h.residue) * job.hours
        local current = GetSoilQuality(h.q, h.r)
        if pct < 0 then
            pct = math.max(pct, -current)
        elseif pct > 0 then
            pct = math.min(pct, math.max(0, cfg.FRESH_SOIL_MAX_PCT - current))
        end
        local delta = pct < 0 and -math.floor(-pct * scale + 0.5) or math.floor(pct * scale + 0.5)
        if delta ~= 0 then
            SoilAdd(h.q, h.r, delta)
            if delta < 0 then job.lowered = job.lowered + 1 else job.raised = job.raised + 1 end
        end
        if job.k % 64 == 0 and GetPreciseTicks() >= deadline then return true end
    end
    if job.lowered + job.raised > 0 then OnSoilGridChanged() end
    if cfg.DEBUG_EFFECTS == true then
        F.Log("Soil", "soil pass", { hexes_lowered = job.lowered, hexes_raised = job.raised, hours = job.hours })
    end
    job = false
    return false
end

-- Drops an unfinished pass (disable, map change). Soil changes already made stay.
function S.Restore() job = false end
