-- Ice. When it freezes, puddles and lakes get a solid surface that rovers, drones
-- and colonists cross on top of, as Martian Waters' Freeze does: invisible plates
-- of the FL_IcePlate entity (collision on every face, walkable top) tiled over the
-- water with their top at the water surface (efCollision + efApplyToGrids +
-- efWalkable raise the walkable surface). The water is not touched; the frozen
-- surface is tinted icy and its animation stops.
-- Frozen means: the planet's water is frozen (vanilla WaterFrozen, set until
-- terraforming reaches LiquidWater; LandscapeLake.lua:381-424), or the local heat
-- is below ICE_FREEZE_HEAT (cold waves and cold areas cool the heat grid,
-- ColdWave.lua, Heat.lua). Plates are transient: never saved, rebuilt after loads.
local F = Flood
local I = {}
F.Ice = I
local PLATE_CLASS = "FloodIcePlate"
local ENTITY = "FL_IcePlate"
local PLATE_SIZE_WU = 9000 -- entity box edge at scale 100 (90 m)
local PLATE_TOP_WU = 100   -- entity box height at scale 100 (1 m)

DefineClass[PLATE_CLASS] = {
    __parents = { "Object" },
    entity = "InvisibleObject",
    flags = { efCollision = true, efApplyToGrids = true, efWalkable = true, efSelectable = false,
        efCameraRepulse = false, efLightShadow = false, efSunShadow = false, gofScaleSurfaces = true },
}

function I.Available()
    if not IsValidEntity(ENTITY) then return false, ENTITY .. " entity not loaded" end
    if type(rawget(_G, "DeleteOnLoadGame")) ~= "function" then return false, "DeleteOnLoadGame unavailable" end
    return true
end

local function active()
    return F.Config.ENABLE_ICE == true and F.State.features.ice == true
end

function I.PlanetFrozen()
    return F.Config.ICE_PLANET_COLD == true and rawget(_G, "WaterFrozen") == true
end

-- Temporary test control (the panel's Frost button): "on" freezes and "off" thaws
-- every pool on the map; "auto" (no override) follows the climate. It only
-- drives Flood's water: vanilla heat, cold waves and WaterFrozen are untouched.
-- Transient: never saved, cleared on Disable and on a map change.
local FROST_NEXT = { auto = "on", on = "off", off = "auto" }

function I.TestFrost()
    return F.State.test_frost or "auto"
end

function I.CycleTestFrost()
    if not active() then return false, "Ice is unavailable or switched off (ENABLE_ICE)" end
    local mode = FROST_NEXT[I.TestFrost()]
    F.State.test_frost = mode ~= "auto" and mode or nil
    -- The next simulation tick restyles the pools and builds or removes the ice.
    F.State.ice_backlog = math.max(1, F.State.ice_backlog or 0)
    F.Log("Ice", "test frost changed", { mode = mode, planet_frozen = I.PlanetFrozen() })
    return true
end

function I.StopTestFrost()
    if F.State.test_frost then
        F.Log("Ice", "test frost cleared", { mode = F.State.test_frost })
        F.State.test_frost = nil
    end
end

-- The whole map frozen: the test override, else the planet's frozen water.
function I.MapFrozen()
    local mode = F.State.test_frost
    if mode == "on" then return true end
    if mode == "off" then return false end
    return I.PlanetFrozen()
end

-- Local heat at a world position (MaxHeat when unknown, as vanilla GetHeatAt).
-- The heat grid covers the map minus const.HeatGridBorder on each side
-- (HeatGrid.new, Heat.lua:31-37) and Heat_Get errors outside it; pools at the
-- map edge read the nearest covered tile.
local function heat_at(x, y)
    local map = F.State.map
    local grid = map and map.heat_grid
    local border = const.HeatGridBorder
    if not grid or not border or (grid.map_width or -1) <= 2 * border or (grid.map_height or -1) <= 2 * border then
        return const.MaxHeat or 255
    end
    x = Clamp(x, border, grid.map_width - border - 1)
    y = Clamp(y, border, grid.map_height - border - 1)
    return grid:GetHeatAtXY(x, y)
end

-- Frozen at a position, with thaw hysteresis when a previous state is given.
function I.FrozenAt(x, y, was_frozen)
    if not active() then return false end
    if F.State.test_frost == "off" then return false end
    if I.MapFrozen() then return true end
    local limit = F.Config.ICE_FREEZE_HEAT + (was_frozen and F.Config.ICE_THAW_MARGIN or 0)
    return heat_at(x, y) < limit
end

local function plate_scale(span_wu)
    -- Slightly larger than the cell so neighbouring plates meet without gaps.
    return math.floor(span_wu * 102.0 / PLATE_SIZE_WU + 0.5)
end

-- Cells of size tile covering the marker's water planes that hold water below z,
-- sampled on a 3 x 3 lattice (Martian Waters' approach, mw_freeze_cover.lua).
local function wet_cells(map, obj, water_z, tile)
    local cells, list = {}, {}
    for _, plane in ipairs(obj:GetWaterPlanes()) do
        if IsValid(plane) then
            local bbox = plane:GetObjectBBox()
            local x0, y0 = bbox:minx() // tile, bbox:miny() // tile
            local x1, y1 = bbox:maxx() // tile, bbox:maxy() // tile
            for ix = x0, x1 do
                for iy = y0, y1 do
                    local key = ix * 65536 + iy
                    if not cells[key] then
                        cells[key] = true
                        for sx = 1, 3 do
                            local px = ix * tile + (sx - 0.5) * tile / 3
                            local hit = false
                            for sy = 1, 3 do
                                local py = iy * tile + (sy - 0.5) * tile / 3
                                if terrain.GetHeight(map, point(math.floor(px), math.floor(py))) < water_z then
                                    hit = true
                                    break
                                end
                            end
                            if hit then list[#list + 1] = { ix, iy }; break end
                        end
                    end
                end
            end
        end
    end
    return list
end

-- Plates apply to the passability grids; each one placed or deleted on its own
-- rebuilds them (~10 ms). Placing many inside SuspendPassEdits/ResumePassEdits
-- rebuilds once (realm.lua:7, as Building.Destroy does): ~0.7 ms a plate.
local PASS_EDITS = "FloodIce"
local function batched(map, fn, ...)
    map:SuspendPassEdits(PASS_EDITS)
    local ok, a, b = pcall(fn, ...)
    map:ResumePassEdits(PASS_EDITS)
    if not ok then error(a, 0) end
    return a, b
end

local function remove_plates(entry)
    local ice = entry.ice
    if not ice then return 0 end
    for _, plate in ipairs(ice.plates) do
        if IsValid(plate) then DoneObject(plate) end
    end
    local n = #ice.plates
    F.State.ice_plates = math.max(0, (F.State.ice_plates or 0) - n)
    entry.ice = nil
    return n
end

-- The wet cells of one pool and its water surface height.
local function wet_cells_of(entry)
    local s, cfg = F.State, F.Config
    local _, _, water_z = entry.obj:GetVisualPosXYZ()
    water_z = water_z + (entry.obj.zoffset or 0)
    return wet_cells(s.map, entry.obj, water_z, cfg.ICE_TILE_M * guim), water_z
end

local function build_plates(entry, cells, water_z)
    local s, cfg = F.State, F.Config
    local map = s.map
    local tile = cfg.ICE_TILE_M * guim
    local scale = plate_scale(tile)
    local top = PLATE_TOP_WU * scale // 100
    local plates = {}
    for _, cell in ipairs(cells) do
        if (s.ice_plates or 0) >= cfg.MAX_ICE_PLATES then break end
        local plate = PlaceObject(PLATE_CLASS, nil, map)
        plate:ChangeEntity(ENTITY)
        plate:SetScale(scale)
        -- Flags must be set after ChangeEntity, as mw_freeze_cover.lua:329-350 and
        -- :562-576 do; the walkable top only counts on a visible object.
        plate:SetEnumFlags(const.efCollision + const.efApplyToGrids + const.efWalkable)
        plate:ClearEnumFlags(const.efSelectable + const.efCameraRepulse + const.efLightShadow + const.efSunShadow)
        plate:SetOpacity(0)
        plate:SetVisible(true)
        plate:SetPos(cell[1] * tile + tile // 2, cell[2] * tile + tile // 2, water_z - top)
        DeleteOnLoadGame(plate)
        plates[#plates + 1] = plate
        s.ice_plates = (s.ice_plates or 0) + 1
    end
    entry.ice = { plates = plates, z = water_z }
    return #plates
end

local function surface_z(obj)
    local _, _, z = obj:GetVisualPosXYZ()
    return z + (obj.zoffset or 0)
end

-- Brings drawn pools' ice in line with their frozen state, largest pools first,
-- within ICE_BUDGET_MS (restyles and plate edits; the plate allowance follows
-- the measured cost per plate). s.ice_backlog counts pools still waiting.
function I.Refresh()
    local s, cfg = F.State, F.Config
    if not s.map or not s.markers then return end
    local started = GetPreciseTicks()
    local frozen_pools, work = 0, {}
    for _, entry in pairs(s.markers) do
        local obj = entry.obj
        if IsValid(obj) and entry.x then
            local frozen = I.FrozenAt(entry.x, entry.y, entry.frozen)
            if frozen then frozen_pools = frozen_pools + 1 end
            local stale = entry.ice and (not frozen or entry.ice.z ~= surface_z(obj))
            if frozen ~= (entry.frozen == true) or stale or (frozen and not entry.ice) then
                work[#work + 1] = { entry = entry, frozen = frozen, size = entry.expected_m2 or 0 }
            end
        end
    end
    s.frozen_pools = frozen_pools
    table.sort(work, function(a, b) return a.size > b.size end)
    local ms_per_plate = s.ice_ms_per_plate or 1
    local built, removed, done, edited_ms = 0, 0, 0, 0
    local function pass()
        for _, item in ipairs(work) do
            local elapsed = GetPreciseTicks() - started
            if elapsed >= cfg.ICE_BUDGET_MS then break end
            local entry = item.entry
            if item.frozen ~= (entry.frozen == true) then
                entry.frozen = item.frozen
                F.Water.Restyle(entry)
            end
            if entry.ice and (not item.frozen or entry.ice.z ~= surface_z(entry.obj)) then
                removed = removed + remove_plates(entry)
            end
            if item.frozen and not entry.ice then
                local cells, water_z = wet_cells_of(entry)
                -- Always progress by one pool; otherwise stay within the budget.
                if done > 0 and elapsed + #cells * ms_per_plate > cfg.ICE_BUDGET_MS then break end
                built = built + build_plates(entry, cells, water_z)
            end
            done = done + 1
        end
    end
    local edit_started = GetPreciseTicks()
    batched(s.map, pass)
    edited_ms = GetPreciseTicks() - edit_started
    if built + removed > 0 then
        -- Exponential average of the measured cost per plate edit.
        s.ice_ms_per_plate = 0.7 * ms_per_plate + 0.3 * (edited_ms / (built + removed))
    end
    s.ice_backlog = #work - done
    if cfg.DEBUG_EFFECTS == true and (built > 0 or removed > 0) then
        F.Log("Ice", "ice refreshed", { frozen_pools = frozen_pools, plates_built = built,
            plates_removed = removed, plates = s.ice_plates or 0, backlog = s.ice_backlog,
            ms = edited_ms, ms_per_plate = s.ice_ms_per_plate, map_frozen = I.MapFrozen() })
    end
end

-- Remove the ice of one marker (before it is retired or cleared).
function I.Remove(entry)
    if not entry.ice then return 0 end
    local map = F.State.map
    if not map or not map:IsValid() then return remove_plates(entry) end
    return batched(map, remove_plates, entry)
end

-- Remove every Flood ice plate on the map. Idempotent.
function I.ClearAll()
    local s = F.State
    local map = s.map
    if map and map:IsValid() then
        batched(map, function()
            for _, entry in pairs(s.markers or {}) do remove_plates(entry) end
            for _, plate in ipairs(map:MapGet("map", PLATE_CLASS) or {}) do DoneObject(plate) end
        end)
    end
    s.ice_plates, s.frozen_pools, s.ice_backlog = 0, 0, 0
end

I.Restore = I.ClearAll

function OnMsg.PostLoadGame()
    -- Plates are DeleteOnLoadGame; this also removes any left by older saves.
    local map = rawget(_G, "MainMap")
    if map and map:IsValid() then
        for _, plate in ipairs(map:MapGet("map", PLATE_CLASS) or {}) do DoneObject(plate) end
    end
end
