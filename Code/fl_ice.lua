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

-- The whole map frozen: the planet's frozen water.
function I.MapFrozen()
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
    if I.MapFrozen() then return true end
    local limit = F.Config.ICE_FREEZE_HEAT + (was_frozen and F.Config.ICE_THAW_MARGIN or 0)
    return heat_at(x, y) < limit
end

local function plate_scale(span_wu)
    -- Slightly larger than the cell so neighbouring plates meet without gaps.
    return math.floor(span_wu * 102.0 / PLATE_SIZE_WU + 0.5)
end

-- Ice is built, moved and melted in small batches. Every plate applies to the
-- passability grids, and each ResumePassEdits rebuilds them over the box of the
-- plates edited since the matching SuspendPassEdits (realm.lua:7): one plate on
-- its own costs ~10 ms, a few hundred spread over a lake or the map in one go
-- stall the game. So each batch edits at most ICE_BATCH_PLATES plates of one
-- lake (a small, local box), and a refresh starts new batches only while it is
-- within ICE_BUDGET_MS of real time, the passability rebuild included.
-- A lake's ice:
--   entry.ice = { z = level the plates should sit at, plate_z = level they sit
--     at, plates = all plates, plate_batches = plates per laid batch, bins =
--     cells by depth bin, bin = bin being laid, bin_j = next cell in it, max_bin,
--     seen = scanned cells, planes = water planes still to scan, plane_i = next
--     plane, scan_cur = position inside the plane being scanned, move_i = next
--     plate batch to move to z }
-- Removed ice (thaw, retired lakes) waits in F.State.ice_melt, deleted in batches.
-- As on real lakes, ice forms from the shore inward and melts from the shore:
-- shallow water holds less heat and loses it to the ground (and a deep middle
-- must first cool through its whole column). Scanned cells go into depth bins
-- of ICE_DEPTH_BIN_MM; plates are laid by walking the bins from the shallowest,
-- so no sort is needed (sorting thousands of cells at once stalled the game).
-- Plates melt batch by batch in the order they were laid.
local PASS_EDITS = "FloodIce"

local function batched(map, fn, ...)
    map:SuspendPassEdits(PASS_EDITS)
    local ok, a, b = pcall(fn, ...)
    map:ResumePassEdits(PASS_EDITS)
    if not ok then error(a, 0) end
    return a, b
end

local function surface_z(obj)
    local _, _, z = obj:GetVisualPosXYZ()
    return z + (obj.zoffset or 0)
end

local function tile_wu() return F.Config.ICE_TILE_M * guim end

local function new_ice(entry)
    local z = surface_z(entry.obj)
    return { z = z, plate_z = z, plates = {}, plate_batches = {}, bins = {}, bin = 0, bin_j = 1, max_bin = -1, seen = {},
        planes = entry.obj:GetWaterPlanes(), plane_i = 1 }
end

-- The next cell to cover, shallowest first, or nil when all are covered.
local function next_cell(ice)
    while ice.bin <= ice.max_bin do
        local bin = ice.bins[ice.bin]
        if bin and ice.bin_j <= #bin then
            local cell = bin[ice.bin_j]
            ice.bin_j = ice.bin_j + 1
            return cell
        end
        ice.bin, ice.bin_j = ice.bin + 1, 1
    end
end

local function cells_left(ice)
    local bin = ice.bins[ice.bin]
    return ice.bin < ice.max_bin or (bin ~= nil and ice.bin_j <= #bin)
end

local function complete(ice)
    return not ice.planes and not cells_left(ice) and not ice.move_i
end

-- Scans water planes for cells holding water below the surface (3 x 3 samples
-- per cell, Martian Waters' approach, mw_freeze_cover.lua) until the deadline,
-- noting each cell's depth (surface minus its lowest sample). Once all planes
-- are scanned the cells are grouped into local batches, shore first.
local function scan_step(ice, map, deadline)
    local tile = tile_wu()
    local planes = ice.planes
    local checked = 0
    while true do
        local cur = ice.scan_cur
        if not cur then
            if ice.plane_i > #planes then break end
            local plane = planes[ice.plane_i]
            ice.plane_i = ice.plane_i + 1
            if IsValid(plane) then
                local bbox = plane:GetObjectBBox()
                cur = { x0 = bbox:minx() // tile, x1 = bbox:maxx() // tile, y1 = bbox:maxy() // tile }
                cur.ix, cur.iy = cur.x0, bbox:miny() // tile
                ice.scan_cur = cur
            end
        end
        if cur then
            -- A large lake's planes can be big tiles: resumable cell by cell.
            while cur.iy <= cur.y1 do
                local ix, iy = cur.ix, cur.iy
                local key = ix * 65536 + iy
                if not ice.seen[key] then
                    ice.seen[key] = true
                    local low
                    for sx = 1, 3 do
                        local px = math.floor(ix * tile + (sx - 0.5) * tile / 3)
                        for sy = 1, 3 do
                            local py = math.floor(iy * tile + (sy - 0.5) * tile / 3)
                            local h = terrain.GetHeight(map, point(px, py))
                            if not low or h < low then low = h end
                        end
                    end
                    if low < ice.z then
                        local b = math.floor((ice.z - low) * 1000 / guim / F.Config.ICE_DEPTH_BIN_MM)
                        local bin = ice.bins[b]
                        if not bin then bin = {}; ice.bins[b] = bin end
                        bin[#bin + 1] = { ix, iy }
                        if b > ice.max_bin then ice.max_bin = b end
                    end
                end
                if ix < cur.x1 then cur.ix = ix + 1 else cur.ix, cur.iy = cur.x0, iy + 1 end
                checked = checked + 1
                if checked % 8 == 0 and GetPreciseTicks() >= deadline then return end
            end
            ice.scan_cur = false
        end
        if GetPreciseTicks() >= deadline then return end
    end
    ice.planes, ice.plane_i = nil, nil
end

local function plate_scale(span_wu)
    -- Slightly larger than the cell so neighbouring plates meet without gaps.
    return math.floor(span_wu * 102.0 / PLATE_SIZE_WU + 0.5)
end

local function plate_top()
    return PLATE_TOP_WU * plate_scale(tile_wu()) // 100
end

-- Lays the lake's next batch of plates. Returns how many.
local function place_batch(ice, map)
    local s, cfg = F.State, F.Config
    local tile, scale, top = tile_wu(), plate_scale(tile_wu()), plate_top()
    local laid = {}
    local placed = 0
    batched(map, function()
        while placed < cfg.ICE_BATCH_PLATES and (s.ice_plates or 0) < cfg.MAX_ICE_PLATES do
            local cell = next_cell(ice)
            if not cell then break end
            local plate = PlaceObject(PLATE_CLASS, nil, map)
            plate:ChangeEntity(ENTITY)
            plate:SetScale(scale)
            -- Flags must be set after ChangeEntity, as mw_freeze_cover.lua:329-350 and
            -- :562-576 do; the walkable top only counts on a visible object.
            plate:SetEnumFlags(const.efCollision + const.efApplyToGrids + const.efWalkable)
            plate:ClearEnumFlags(const.efSelectable + const.efCameraRepulse + const.efLightShadow + const.efSunShadow)
            plate:SetOpacity(0)
            plate:SetVisible(true)
            plate:SetPos(cell[1] * tile + tile // 2, cell[2] * tile + tile // 2, ice.plate_z - top)
            DeleteOnLoadGame(plate)
            ice.plates[#ice.plates + 1] = plate
            laid[#laid + 1] = plate
            s.ice_plates = (s.ice_plates or 0) + 1
            placed = placed + 1
        end
    end)
    if #laid > 0 then ice.plate_batches[#ice.plate_batches + 1] = laid end
    -- At the plate cap the rest of this lake stays open water.
    if (s.ice_plates or 0) >= cfg.MAX_ICE_PLATES then ice.bin, ice.max_bin = 0, -1 end
    return placed
end

-- Moves the lake's next laid batch of plates to its new level.
local function move_batch(ice, map)
    local top = plate_top()
    local moved = 0
    local plates = ice.plate_batches[ice.move_i]
    ice.move_i = ice.move_i + 1
    batched(map, function()
        for _, plate in ipairs(plates or {}) do
            if IsValid(plate) then
                local x, y = plate:GetPos():xy()
                plate:SetPos(x, y, ice.z - top)
                moved = moved + 1
            end
        end
    end)
    if ice.move_i > #ice.plate_batches then ice.move_i, ice.plate_z = nil, ice.z end
    return moved
end

-- Deletes the oldest melting lake's next laid batch: shore first, and local.
local function melt_batch(map)
    local s = F.State
    local melt = s.ice_melt[1]
    local plates = melt.batches[melt.i]
    melt.i = melt.i + 1
    local removed = 0
    batched(map, function()
        for _, plate in ipairs(plates) do
            if IsValid(plate) then DoneObject(plate) end
            removed = removed + 1
        end
    end)
    if melt.i > #melt.batches then table.remove(s.ice_melt, 1) end
    s.ice_plates = math.max(0, (s.ice_plates or 0) - removed)
    return removed
end

-- Hands a lake's plates to the melt queue.
local function melt(entry)
    local ice = entry.ice
    entry.ice = nil
    if ice and #ice.plates > 0 then
        local s = F.State
        s.ice_melt = s.ice_melt or {}
        s.ice_melt[#s.ice_melt + 1] = { batches = ice.plate_batches, i = 1 }
    end
end

-- Brings drawn lakes' ice in line with their frozen state, a little at a time:
-- restyles, melting, scanning, placing and moving all share ICE_BUDGET_MS of
-- real time per call (less when the pacer passes a smaller budget_ms). Melting
-- goes first, then the largest lakes. s.ice_backlog counts lakes and melt lists
-- still waiting; while it is above zero the pacer keeps calling this.
function I.Refresh(budget_ms)
    local s, cfg = F.State, F.Config
    if not s.map or not s.markers then return end
    s.ice_melt = s.ice_melt or {}
    local started = GetPreciseTicks()
    local deadline = started + math.min(budget_ms or cfg.ICE_BUDGET_MS, cfg.ICE_BUDGET_MS)
    local relevel = cfg.ICE_RELEVEL_MM * guim / 1000
    local frozen_pools, work, restyle_pending = 0, {}, 0
    -- Longest time per phase of one refresh (diagnostics and tests).
    local phase = s.ice_phase_max_ms or {}
    s.ice_phase_max_ms = phase
    local function note(name, t0) phase[name] = math.max(phase[name] or 0, GetPreciseTicks() - t0) end
    local classify_t0 = GetPreciseTicks()
    for _, entry in pairs(s.markers) do
        local obj = entry.obj
        if IsValid(obj) and entry.x then
            local frozen = I.FrozenAt(entry.x, entry.y, entry.frozen)
            if frozen then frozen_pools = frozen_pools + 1 end
            if frozen ~= (entry.frozen == true) then
                if GetPreciseTicks() < deadline then
                    entry.frozen = frozen
                    F.Water.Restyle(entry)
                else
                    restyle_pending = restyle_pending + 1
                end
            end
            if entry.frozen then
                local ice = entry.ice
                if not ice then
                    entry.ice = new_ice(entry)
                elseif not ice.move_i and not ice.planes then
                    local z = surface_z(obj)
                    -- Small level changes keep the plates; larger ones move them.
                    if math.abs(z - ice.z) >= relevel then ice.z, ice.move_i = z, 1 end
                end
                if not complete(entry.ice) then
                    work[#work + 1] = { entry = entry, size = entry.expected_m2 or 0 }
                end
            elseif entry.ice then
                melt(entry)
            end
        end
    end
    s.frozen_pools = frozen_pools
    table.sort(work, function(a, b) return a.size > b.size end)
    note("classify", classify_t0)
    local built, moved, removed, batches = 0, 0, 0, 0
    -- One step of work (a batch or a scan step) always runs; more only within
    -- the budget. (A scan step must count: otherwise a big lake's scan ran on,
    -- step after step, past the deadline until the whole lake was scanned.)
    local worked = false
    local function in_budget() return not worked or GetPreciseTicks() < deadline end
    -- The longest single batch (plate edits plus its passability rebuild) is the
    -- longest the game can stall on ice; kept for diagnostics and the tests.
    local function timed(fn, ...)
        local t0 = GetPreciseTicks()
        local n = fn(...)
        s.ice_worst_batch_ms = math.max(s.ice_worst_batch_ms or 0, GetPreciseTicks() - t0)
        batches, worked = batches + 1, true
        return n
    end
    while #s.ice_melt > 0 and in_budget() do
        removed = removed + timed(melt_batch, s.map)
    end
    for _, item in ipairs(work) do
        local ice = item.entry.ice
        while not complete(ice) and in_budget() do
            if ice.planes then
                local t0 = GetPreciseTicks()
                scan_step(ice, s.map, deadline)
                note("scan", t0)
                worked = true
            elseif cells_left(ice) then
                built = built + timed(place_batch, ice, s.map)
            elseif ice.move_i then
                moved = moved + timed(move_batch, ice, s.map)
            end
        end
        if not in_budget() then break end
    end
    local waiting = #s.ice_melt + restyle_pending
    for _, item in ipairs(work) do
        if not complete(item.entry.ice) then waiting = waiting + 1 end
    end
    s.ice_backlog = waiting
    s.ice_refresh_ms = GetPreciseTicks() - started
    if cfg.DEBUG_EFFECTS == true and (built > 0 or removed > 0 or moved > 0) then
        F.Log("Ice", "ice refreshed", { frozen_pools = frozen_pools, plates_built = built, plates_moved = moved,
            plates_removed = removed, plates = s.ice_plates or 0, backlog = s.ice_backlog, batches = batches,
            worst_batch_ms = s.ice_worst_batch_ms, classify_ms = phase.classify, scan_ms = phase.scan,
            ms = s.ice_refresh_ms, map_frozen = I.MapFrozen() })
    end
end

-- True once a lake's ice is complete (scanned, every cell covered, at its level).
function I.Covered(entry)
    return entry.ice ~= nil and complete(entry.ice)
end

-- A lake's marker is retired or cleared: its ice melts in later batches.
function I.Remove(entry)
    if not entry.ice then return 0 end
    local n = #entry.ice.plates
    melt(entry)
    F.State.ice_backlog = math.max(1, F.State.ice_backlog or 0)
    return n
end

-- Removes every Flood ice plate at once (disable, save, map change; not regular
-- play). Idempotent.
function I.ClearAll()
    local s = F.State
    local map = s.map
    if map and map:IsValid() then
        batched(map, function()
            for _, entry in pairs(s.markers or {}) do
                if entry.ice then
                    for _, plate in ipairs(entry.ice.plates) do if IsValid(plate) then DoneObject(plate) end end
                    entry.ice = nil
                end
            end
            for _, melt in ipairs(s.ice_melt or {}) do
                for _, plates in ipairs(melt.batches) do
                    for _, plate in ipairs(plates) do if IsValid(plate) then DoneObject(plate) end end
                end
            end
            for _, plate in ipairs(map:MapGet("map", PLATE_CLASS) or {}) do DoneObject(plate) end
        end)
    end
    s.ice_melt, s.ice_plates, s.frozen_pools, s.ice_backlog = {}, 0, 0, 0
end

I.Restore = I.ClearAll

function OnMsg.PostLoadGame()
    -- Plates are DeleteOnLoadGame; this also removes any left by older saves.
    local map = rawget(_G, "MainMap")
    if map and map:IsValid() then
        for _, plate in ipairs(map:MapGet("map", PLATE_CLASS) or {}) do DoneObject(plate) end
    end
end
