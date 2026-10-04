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

function S.Hourly(hours)
    local s, cfg = F.State, F.Config
    if s.features.soil ~= true or s.map ~= MainMap or not SoilGrid or not s.model then return end
    local toxic_on = cfg.ENABLE_TOXIC_SOIL == true
    local fresh_on = cfg.ENABLE_FRESH_SOIL == true
    if not toxic_on and not fresh_on then return end
    local hexes = {}
    local function hex(q, r)
        local key = q .. ":" .. r
        local h = hexes[key]
        if not h then h = { q = q, r = r, sum = 0, cells = 0, residue = 0 }; hexes[key] = h end
        return h
    end
    -- Standing water: average the per-cell rate over the cells inside each hex.
    for i, depth in pairs(s.wet or {}) do
        if depth >= cfg.MIN_VISIBLE_DEPTH_MM then
            local c = s.wet_concentration[i]
            local rate = (toxic_on and -cfg.TOXIC_SOIL_PCT_PER_HOUR * c or 0)
                + (fresh_on and cfg.FRESH_SOIL_PCT_PER_HOUR * (1 - c) or 0)
            local h = hex(WorldToHex(F.Terrain.Position(s.grid, i)))
            h.sum, h.cells = h.sum + rate, h.cells + 1
        end
    end
    -- Dry residue: load is toxic water depth equivalent spread over the dried basin.
    if toxic_on then
        for _, residue in ipairs(F.Hydrology.Residues(s.model)) do
            local area_m2 = residue.cells * s.model.area
            local strength = math.min(1, residue.mass * 1.0 / area_m2 / cfg.RESIDUE_FULL_EFFECT_MM)
            local radius_m = math.min(cfg.RESIDUE_MAX_RADIUS_M, math.sqrt(area_m2 / math.pi))
            local x, y = F.Terrain.Position(s.grid, residue.seed)
            ForEachHexInCircle(point(x, y), math.max(1, math.floor(radius_m * guim)), function(q, r)
                local wx, wy = HexToWorld(q, r)
                if wx >= 0 and wy >= 0 and wx < s.grid.sx and wy < s.grid.sy then
                    local h = hex(q, r)
                    h.residue = h.residue + cfg.RESIDUE_SOIL_PCT_PER_HOUR * strength
                end
            end)
        end
    end
    local scale = const.SoilGridScale
    local lowered, raised = 0, 0
    for _, h in pairs(hexes) do
        local pct = ((h.cells > 0 and h.sum * 1.0 / h.cells or 0) - h.residue) * hours
        local current = GetSoilQuality(h.q, h.r)
        if pct < 0 then
            pct = math.max(pct, -current)
        elseif pct > 0 then
            pct = math.min(pct, math.max(0, cfg.FRESH_SOIL_MAX_PCT - current))
        end
        local delta = pct < 0 and -math.floor(-pct * scale + 0.5) or math.floor(pct * scale + 0.5)
        if delta ~= 0 then
            SoilAdd(h.q, h.r, delta)
            if delta < 0 then lowered = lowered + 1 else raised = raised + 1 end
        end
    end
    if lowered + raised > 0 then OnSoilGridChanged() end
    if cfg.DEBUG_EFFECTS == true then
        F.Log("Soil", "soil pass", { hexes_lowered = lowered, hexes_raised = raised, hours = hours })
    end
end
