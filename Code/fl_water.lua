-- Uses the TerrainWaterObject approach in Martian Waters and shipped Water.lua.
-- A distinct class keeps Flood markers out of Martian Waters' adoption filter.
-- Only Flood objects are deleted or styled. No shared presets are modified.
local F = Flood
local W = {}
F.Water = W
DefineClass.FloodWaterMarker = { __parents = { "TerrainWaterObject" } }

local function dirty_union(a, b)
    if not a then return b end
    if not b then return a end
    return AddRects(a, b)
end

-- Clears the native water grid in box and refills every water object whose extent
-- touches it. Same engine calls as ApplyAllWaterObjects (Water.lua:292-320), but
-- without its recursive growth of the box over every intersecting object: on a
-- flooded map that grew to nearly every lake (in-game: 2.4 s per lowered lake).
-- Water outside box is untouched, so refilling the touching objects suffices.
-- Its passability step only concerns TerrainWaterMod objects, which these aren't.
local function rebuild_box(map, box)
    local t0 = GetPreciseTicks()
    map:SuspendPassEdits("FloodRebuildBox")
    terrain.ClearWater(map, box)
    local t1, refilled = GetPreciseTicks(), 0
    for _, obj in ipairs(map:MapGet("map", "TerrainWaterObject")) do
        local extent = obj.invalidation_box
        if extent and box:Intersect2D(extent) ~= const.irOutside then
            -- Other mods' water keeps the default ApplyAllWaterObjects behaviour.
            obj:UpdateGridAndVisuals(IsKindOf(obj, "FloodWaterMarker") or nil)
            refilled = refilled + 1
        end
    end
    local t2 = GetPreciseTicks()
    terrain.CompactWater(map, box)
    map:ResumePassEdits("FloodRebuildBox")
    F.State.last_rebuild = { clear_ms = t1 - t0, refill_ms = t2 - t1, compact_ms = GetPreciseTicks() - t2,
        refilled = refilled, box_m = math.floor(box:sizex() / guim) .. "x" .. math.floor(box:sizey() / guim) }
end

local function style(obj, concentration)
    local fresh, toxic = F.Config.FRESH_COLOR, F.Config.TOXIC_COLOR
    local channels = {}
    for i = 1, 3 do channels[i] = math.floor(fresh[i] + (toxic[i] - fresh[i]) * concentration + 0.5) end
    obj:Setwaterpreset("Water_Default")
    obj:Setwaterpreset("")
    obj:SetColorModifier(RGB(channels[1], channels[2], channels[3]))
    -- Calm, shallow water with depth-dependent opacity; toxic water is murkier.
    obj:SetProperty("WaterParam1", 8)
    obj:SetProperty("WaterParam6", 35)
    obj:SetProperty("WaterParam9", math.floor(32 + 45 * concentration))
    obj:SetProperty("WaterParam10", math.floor(64 + 90 * concentration))
    obj:SetProperty("WaterParam14", 0)
    obj:WaterPropChanged()
end

-- Per-cell depth (mm) and toxic concentration for gameplay effects. Computing
-- this walks every cell, so effects read a snapshot refreshed on a cadence.
function W.Snapshot()
    local s = F.State
    if not s.model then s.wet, s.wet_concentration, s.pool_cells, s.pools = false, false, false, false; return end
    s.wet, s.wet_concentration, s.pool_cells, s.pools = F.Hydrology.WetCells(s.model)
end

-- Water tint in 5 % steps: restyling touches every plane of a marker, and toxic
-- rain changes concentrations a little on every redraw.
local function tint_of(concentration)
    return math.floor(concentration * 20 + 0.5) * 5
end

function W.DepthAt(x, y)
    local s = F.State
    if not s.wet or not s.grid then return 0, 0 end
    local i = F.Terrain.Cell(s.grid, x, y)
    local depth = i and s.wet[i]
    if not depth then return 0, 0 end
    return depth, s.wet_concentration[i]
end

-- Deepest water under a hex footprint. Shape offsets are unrotated, as
-- GetBuildShape returns them; rotation follows Building.lua's own loop.
function W.FootprintDepth(pos, angle, shape)
    local deepest = W.DepthAt(pos:xy())
    if shape and #shape > 0 then
        local dir = HexAngleToDirection(angle)
        local cq, cr = WorldToHex(pos)
        for _, offset in ipairs(shape) do
            local q, r = HexRotate(offset:x(), offset:y(), dir)
            deepest = math.max(deepest, (W.DepthAt(HexToWorld(cq + q, cr + r))))
        end
    end
    return deepest
end

function W.Clear(map)
    local dirty
    if map and map:IsValid() then
        for _, obj in ipairs(map:MapGet("map", "FloodWaterMarker")) do
            dirty = dirty_union(dirty, obj.invalidation_box)
            DoneObject(obj)
        end
        if dirty then rebuild_box(map, dirty) end
    end
    F.State.markers, F.State.retiring = {}, {}
end

-- Moves a marker to its pool's lowest point and level. The model samples terrain
-- at cell resolution, so its level can exceed the real rim of a notch narrower
-- than a sub-sample; unguarded, the engine floods everything connected below that
-- level (seen in-game: one lake across the whole 37.7 km^2 map). With avoid_spill
-- the engine lowers the surface in guim/10 steps until the filled area is within
-- original_area (+ spill_tolerance %), in height tiles (Water.lua:236-259).
-- A lake with this many planes takes most of a second to refill (in-game: a
-- 12.9 km^2 lake, 11,905 planes, 0.8 s).
local function is_large(obj)
    return IsValid(obj) and #obj:GetWaterPlanes() > F.Config.LARGE_LAKE_PLANES
end

-- True when clearing box would force a large lake other than self to refill.
local function touches_large_lake(box, self_obj)
    for _, entry in pairs(F.State.markers) do
        local o = entry.obj
        if o ~= self_obj and is_large(o) and o.invalidation_box
            and box:Intersect2D(o.invalidation_box) ~= const.irOutside then
            return true
        end
    end
    return false
end

local function place(entry, x, y, z)
    local s, cfg = F.State, F.Config
    local obj = entry.obj
    local old_box, old_z = obj.invalidation_box, entry.z
    local moved = entry.x ~= x or entry.y ~= y
    obj.zoffset = 0
    obj:SetPos(x, y, z)
    local tile_m2 = (const.HeightTileSize * 1.0 / guim) ^ 2
    obj.original_area = math.floor(math.max(cfg.MIN_MARKER_AREA_M2,
        entry.expected_m2 * cfg.MARKER_AREA_SLACK) / tile_m2)
    if old_box and (moved or (old_z and z < old_z)) then
        if touches_large_lake(old_box, obj) then
            -- Deferred: clearing here would refill a neighbouring large lake. The
            -- old extent stays drawn until that lake's own redraw clears its box.
            obj:UpdateGridAndVisuals(true)
            entry.z, entry.x, entry.y = z, x, y
            return "deferred"
        end
        -- A lower or relocated surface must first clear its old extent; the engine
        -- then refills every marker touching that box, this one included.
        rebuild_box(s.map, old_box)
        entry.z, entry.x, entry.y = z, x, y
        return "refill"
    end
    -- A rising surface only adds water: fill this marker alone.
    obj:UpdateGridAndVisuals(true)
    entry.z, entry.x, entry.y = z, x, y
    return "fill"
end

local function retire(map, obj)
    if not IsValid(obj) then return end
    local box = obj.invalidation_box
    local defer = box and touches_large_lake(box, obj)
    DoneObject(obj)
    -- Near a large lake the dried extent is cleared by that lake's next redraw.
    if box and not defer then rebuild_box(map, box) end
end

-- Redraws pools within a time budget, largest changes first; the rest follow on
-- later redraws. Markers follow their water when basins merge or split instead of
-- being deleted and recreated, because both cost a native fill.
function W.Refresh()
    local s, cfg = F.State, F.Config
    if s.saving or not s.model then return end
    local started = GetPreciseTicks()
    local nodes = s.model.nodes
    local step = cfg.RENDER_LEVEL_STEP_MM * guim / 1000.0
    local large_step = cfg.LARGE_LAKE_STEP_MM * guim / 1000.0
    local lower_step = cfg.RENDER_LOWER_STEP_MM * guim / 1000.0
    -- Each rendered pool costs a native fill, so only the largest (by wetted area)
    -- are drawn; the model, and every gameplay effect, still use all of them.
    local candidates = {}
    for _, pool in ipairs(s.pools or F.Hydrology.Pools(s.model)) do
        if pool.level - s.model.elevations[pool.seed] >= cfg.MIN_VISIBLE_DEPTH_MM then
            candidates[#candidates + 1] = pool
        end
    end
    local cells = s.pool_cells or {}
    if #candidates > cfg.MAX_RENDERED_POOLS then
        table.sort(candidates, function(a, b)
            local ca, cb = cells[a.node] or 0, cells[b.node] or 0
            if ca ~= cb then return ca > cb end
            return a.node < b.node
        end)
    end
    local pools, visible = {}, math.min(#candidates, cfg.MAX_RENDERED_POOLS)
    for i = 1, visible do pools[candidates[i].node] = candidates[i] end
    s.wet_pools = #candidates
    -- Entries whose node is no longer a visible pool.
    local stale = {}
    for id, entry in pairs(s.markers) do
        if not pools[id] or not IsValid(entry.obj) then stale[id] = entry; s.markers[id] = nil end
    end
    if next(stale) then
        -- Merge: an old pool is now inside a larger one (an ancestor).
        for id, entry in pairs(stale) do
            local up = id
            while up ~= 0 and not pools[up] do up = nodes[up].parent end
            if up ~= 0 and not s.markers[up] and IsValid(entry.obj) then
                s.markers[up] = entry; stale[id] = nil
            end
        end
        -- Split: a new pool sits below an old one (a descendant).
        for id in pairs(pools) do
            if not s.markers[id] then
                local up = nodes[id].parent
                while up ~= 0 and not stale[up] do up = nodes[up].parent end
                if up ~= 0 and IsValid(stale[up].obj) then s.markers[id] = stale[up]; stale[up] = nil end
            end
        end
        for _, entry in pairs(stale) do s.retiring[#s.retiring + 1] = entry.obj end
    end
    -- Work list: retire dry markers first, then the largest level changes.
    local work = {}
    for id, pool in pairs(pools) do
        local entry = s.markers[id]
        local z = math.floor(pool.level * guim / 1000.0)
        local x, y = F.Terrain.LowPoint(s.grid, pool.seed)
        local change = (not entry or entry.z == false or entry.x ~= x) and math.huge or math.abs(z - entry.z)
        local needed = entry and is_large(entry.obj) and large_step
            or (entry and entry.z and z < entry.z and lower_step) or step
        if change >= needed then work[#work + 1] = { id = id, pool = pool, x = x, y = y, z = z, change = change } end
        if entry then
            entry.expected_m2 = (s.pool_cells and s.pool_cells[id] or 0) * s.model.area
            local tint = tint_of(pool.concentration)
            if entry.tint ~= tint then style(entry.obj, tint / 100.0); entry.tint = tint end
        end
    end
    table.sort(work, function(a, b) return a.change > b.change end)
    -- The budget covers native water work only, and every redraw makes progress.
    local budget, native_start = cfg.RENDER_BUDGET_MS, GetPreciseTicks()
    local function within_budget(n) return n == 0 or GetPreciseTicks() - native_start < budget end
    local retired = 0
    local worst_ms, worst_kind = 0, "none"
    local function measure(kind, t0)
        local ms = GetPreciseTicks() - t0
        if ms > worst_ms then worst_ms, worst_kind = ms, kind end
    end
    while #s.retiring > 0 and within_budget(retired) do
        local t0 = GetPreciseTicks()
        retire(s.map, table.remove(s.retiring))
        measure("retire", t0)
        retired = retired + 1
    end
    local done = 0
    for _, item in ipairs(work) do
        if not within_budget(done + retired) then break end
        local entry = s.markers[item.id]
        if not entry then
            local obj = PlaceObject("FloodWaterMarker", nil, s.map)
            assert(obj, "could not place Flood water marker")
            obj:ClearEnumFlags(const.efVisible)
            entry = { obj = obj, z = false, tint = false }
            s.markers[item.id] = entry
        end
        entry.expected_m2 = (s.pool_cells and s.pool_cells[item.id] or 0) * s.model.area
        local t0 = GetPreciseTicks()
        measure(place(entry, item.x, item.y, item.z), t0)
        local tint = tint_of(item.pool.concentration)
        if entry.tint ~= tint then style(entry.obj, tint / 100.0); entry.tint = tint end
        done = done + 1
    end
    s.visible_pools = visible
    s.render_backlog = #work - done + #s.retiring
    s.render_worst_ms, s.render_worst_kind = worst_ms, worst_kind
    if done + retired > 0 then
        s.render_ms_per_marker = (GetPreciseTicks() - native_start) * 1.0 / (done + retired)
    end
    -- Native water rebuilding is the costly part; keep it observable.
    s.refresh_ms = GetPreciseTicks() - started
    if F.Config.DEBUG_HYDROLOGY == true then
        F.Log("Water", "redraw", { visible = visible, updated = done, backlog = s.render_backlog, ms = s.refresh_ms })
    end
end

