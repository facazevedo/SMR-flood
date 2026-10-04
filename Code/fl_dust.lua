-- Rain washes accumulated dust off every object that accumulates it. The set of
-- objects mirrors the vanilla dust storm (DustStorm.lua:337-348): the Building,
-- Drone, Rover and Dome labels plus every element of the water and electricity
-- grids. Each object's own AddDust is called with a negative amount, so buildings
-- go through RequiresMaintenance:AddDust (dust modifiers, maintenance points),
-- cables and pipes through DustGridElement:AddDust, drones and rovers through
-- DroneBase/BaseRover:AddDust; all clamp at zero. Storms add the same amount to
-- every object, so washing removes the same const.MaxMaintenance-scaled amount.
-- Only objects in the open are reached by rain (IsObjInOpenAir, Dome.lua:461).
local F = Flood
local D = {}
F.Dust = D

local DUST_LABELS = { "Building", "Drone", "Rover", "Dome" }
local DUST_GRIDS = { "water", "electricity" }

function D.Available()
    if type(rawget(_G, "IsObjInOpenAir")) ~= "function" then return false, "IsObjInOpenAir unavailable" end
    if type(const.MaxMaintenance) ~= "number" then return false, "const.MaxMaintenance unavailable" end
    return true
end

function D.Hourly(hours, rain_mm_h)
    local s, cfg = F.State, F.Config
    if cfg.ENABLE_RAIN_DUST_WASHING ~= true or s.features.dust ~= true or rain_mm_h <= 0 then return end
    local city = s.map and s.map.City
    if not city then return end
    local wash = math.floor(const.MaxMaintenance * cfg.RAIN_DUST_WASH_PER_HOUR * hours
        * rain_mm_h * 1.0 / cfg.RAIN_REFERENCE_MM_H)
    if wash <= 0 then return end
    local seen, washed = {}, 0
    -- Grid elements are dusted by storms without a dome test (DustStorm.lua:84-103).
    local function rinse(obj, in_open)
        if seen[obj] or not IsValid(obj) or not obj.AddDust or not (in_open or IsObjInOpenAir(obj)) then return end
        seen[obj] = true
        obj:AddDust(-wash)
        washed = washed + 1
    end
    for _, name in ipairs(DUST_LABELS) do
        for _, obj in ipairs(city.labels[name] or {}) do rinse(obj) end
    end
    for _, grid_name in ipairs(DUST_GRIDS) do
        for _, grid in ipairs(city[grid_name] or {}) do
            for _, element in ipairs(grid.elements or {}) do
                local obj = element.building
                if IsKindOf(obj, "DustGridElement") and obj:GetMap() == s.map then rinse(obj, true) end
            end
        end
    end
    if cfg.DEBUG_EFFECTS == true then
        F.Log("Dust", "rain washed dust", { objects = washed, amount = wash, rain_mm_h = rain_mm_h, hours = hours })
    end
end
