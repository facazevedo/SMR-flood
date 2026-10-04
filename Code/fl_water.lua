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
    if not s.model then s.wet, s.wet_concentration = false, false; return end
    s.wet, s.wet_concentration = F.Hydrology.WetCells(s.model)
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
        if dirty then ApplyAllWaterObjects(map, dirty) end
    end
    F.State.markers = {}
end

function W.Refresh()
    local s, cfg = F.State, F.Config
    if s.saving or not s.model then return end
    local wanted, dirty = {}, nil
    local visible = 0
    for _, pool in ipairs(F.Hydrology.Pools(s.model)) do
        local depth = pool.level - s.model.elevations[pool.seed]
        if depth >= cfg.MIN_VISIBLE_DEPTH_MM then
            wanted[pool.node] = true
            local entry = s.markers[pool.node]
            local x, y = F.Terrain.Position(s.grid, pool.seed)
            local z = math.floor(pool.level * guim / 1000.0)
            local tint = math.floor(pool.concentration * 100)
            if not entry or not IsValid(entry.obj) then
                entry = { obj = PlaceObject("FloodWaterMarker", nil, s.map), z = false, tint = false }
                assert(entry.obj, "could not place Flood water marker")
                s.markers[pool.node] = entry
                entry.obj:ClearEnumFlags(const.efVisible)
            end
            if entry.z == false or math.abs(z - entry.z) >= cfg.RENDER_LEVEL_STEP_MM * guim / 1000.0 then
                dirty = dirty_union(dirty, entry.obj.invalidation_box)
                entry.obj.zoffset = 0
                entry.obj:SetPos(x, y, z)
                entry.obj:UpdateGridAndVisuals(false)
                dirty = dirty_union(dirty, entry.obj.invalidation_box)
                entry.z = z
            end
            if entry.tint ~= tint then style(entry.obj, pool.concentration); entry.tint = tint end
            visible = visible + 1
        end
    end
    for id, entry in pairs(s.markers) do
        if not wanted[id] then
            if IsValid(entry.obj) then
                dirty = dirty_union(dirty, entry.obj.invalidation_box)
                DoneObject(entry.obj)
            end
            s.markers[id] = nil
        end
    end
    if dirty then ApplyAllWaterObjects(s.map, dirty) end
    s.visible_pools = visible
end

