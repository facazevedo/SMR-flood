-- Effect 2: outdoor buildings under deep water are suspended; shallow water wears them.
-- Toxic rain corrodes outdoor buildings (adds maintenance points).
-- Suspension uses the vanilla reason slot (BaseBuilding:SetSuspended, BaseBuilding.lua:759):
-- clearing with our reason never clears another system's suspension. Wear and
-- corrosion are maintenance points (RequiresMaintenance:AccumulateMaintenancePoints).
local F = Flood
local B = {}
F.Buildings = B
local REASON = "Flooded"

-- Text for the building warning (Building.lua:2782 GetNotWorkingWarningText). It stays
-- registered so a save holding a flooded building still explains itself.
NotWorkingWarning[REASON] = { sort_key = 165,
    text = Untranslated("Flooded: the water here is too deep for this building to operate."),
    short = Untranslated("Flooded") }

function B.Available()
    for _, name in ipairs({ "HexAngleToDirection", "HexRotate", "WorldToHex", "HexToWorld", "IsKindOfClasses" }) do
        if type(rawget(_G, name)) ~= "function" then return false, name .. " unavailable" end
    end
    return true
end

local function feature_on(flag)
    return F.Config[flag] == true and F.State.features.buildings == true
end

local function each_outdoor_building(fn)
    local map = F.State.map
    local city = map and map.City
    for _, bld in ipairs(city and city.labels.Building or {}) do
        if IsValid(bld) and not bld.parent_dome and not bld.destroyed then fn(bld) end
    end
end

-- Only buildings that operate (consume, produce, store power or employ) can be
-- flooded out. Domes are sealed; Landscaping lakes are meant to hold water; cables,
-- pipes, tracks, passages and rockets are Buildings whose logic does not expect a
-- suspension (stations and shuttle hubs are consumers and are included).
local function floodable(bld)
    return IsKindOfClasses(bld, "ElectricityConsumer", "ElectricityProducer", "ElectricityStorage",
            "LifeSupportConsumer", "WaterProducer", "AirProducer", "ResourceProducer", "Workplace")
        and not IsKindOfClasses(bld, "Dome", "LandscapeLake", "DustGridElement", "TrackBase",
            "RocketBase", "PassageBase")
end

-- Adds a share of the building's maintenance threshold; negative cleans.
local function add_maintenance(bld, share)
    if not bld.accumulate_maintenance_points or not bld:DoesRequireMaintenance() then return 0 end
    local raw = bld.maintenance_threshold_current * share
    local points = raw < 0 and -math.floor(-raw) or math.floor(raw)
    if points ~= 0 then bld:AccumulateMaintenancePoints(points) end
    return points
end

function B.UpdateFlooding(hours)
    if not feature_on("ENABLE_BUILDING_FLOODING") then return end
    local cfg = F.Config
    local flooded, suspended, resumed, worn = 0, 0, 0, 0
    each_outdoor_building(function(bld)
        if not floodable(bld) then return end
        local depth = F.Water.FootprintDepth(bld:GetPos(), bld:GetAngle(), bld:GetBuildShape())
        if bld.suspended == REASON then
            if depth < cfg.FLOOD_RESUME_DEPTH_MM then
                bld:SetSuspended(false, REASON); resumed = resumed + 1
            else
                flooded = flooded + 1
            end
        elseif depth >= cfg.FLOOD_SUSPEND_DEPTH_MM then
            -- One reason slot: a dust storm or ion storm keeps priority until it clears.
            if not bld.suspended then
                bld:SetSuspended(true, REASON); suspended = suspended + 1; flooded = flooded + 1
            end
        elseif depth >= cfg.MIN_VISIBLE_DEPTH_MM then
            local share = cfg.FLOOD_WEAR_PER_HOUR * hours * depth * 1.0 / cfg.FLOOD_SUSPEND_DEPTH_MM
            if add_maintenance(bld, share) > 0 then worn = worn + 1 end
        end
    end)
    F.State.flooded_buildings = flooded
    if F.Config.DEBUG_EFFECTS == true then
        F.Log("Buildings", "flooding pass", { flooded = flooded, newly_suspended = suspended,
            resumed = resumed, worn = worn, hours = hours })
    end
end

-- Acidic toxic rain corrodes exposed structures (dust washing is fl_dust.lua).
function B.UpdateCorrosion(hours, rain_mm_h, toxic)
    if not feature_on("ENABLE_TOXIC_CORROSION") or rain_mm_h <= 0 or not toxic then return end
    local share = F.Config.RAIN_CORROSION_PER_HOUR * hours * rain_mm_h * 1.0 / F.Config.RAIN_REFERENCE_MM_H
    local corroded = 0
    each_outdoor_building(function(bld)
        if not IsKindOf(bld, "DustGridElement") and add_maintenance(bld, share) > 0 then corroded = corroded + 1 end
    end)
    if F.Config.DEBUG_EFFECTS == true then
        F.Log("Buildings", "toxic corrosion pass", { rain_mm_h = rain_mm_h, corroded = corroded, hours = hours })
    end
end

function B.Hourly(hours, rain_mm_h, toxic)
    B.UpdateFlooding(hours)
    B.UpdateCorrosion(hours, rain_mm_h, toxic)
end

-- Lift every Flood suspension on the surface map. Idempotent.
function B.Restore()
    local restored = 0
    each_outdoor_building(function(bld)
        if bld.suspended == REASON then bld:SetSuspended(false, REASON); restored = restored + 1 end
    end)
    F.State.flooded_buildings = 0
    F.Log("Buildings", "flood suspensions lifted", { buildings = restored })
end
