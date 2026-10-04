-- Ground vehicles and drones. Vanilla rain has no effect on them.
-- Rovers: slower in deep water (id-tagged move_speed modifier, Modifiers.lua:181);
--   driven past their fording depth they can short out and break down (the vanilla
--   Malfunction command that drones repair, rolled with SessionRandom like dust devils,
--   DustDevils.lua:508-511).
-- Drones: rain slows them (city "Drone" label modifier, covers new drones); ground
--   drones in deep water drain their battery (Drone:UseBattery, Drone.lua:1760);
--   toxic rain leaves corrosive grime (AddDust, which malfunctions a drone at its
--   dust limit exactly as dust storms do). Rain washing is fl_dust.lua.
local F = Flood
local V = {}
F.Vehicles = V
local ROVER_MODIFIER = "FloodDeepWater"
local DRONE_RAIN_MODIFIER = "FloodRainDrones"

-- Hours each rover spent past fording depth since the last hourly pass.
local submerged = setmetatable({}, { __mode = "k" })

function V.Available()
    if type(rawget(_G, "BaseRover")) ~= "table" or type(BaseRover.SetModifier) ~= "function" then
        return false, "BaseRover.SetModifier unavailable"
    end
    if type(rawget(_G, "Drone")) ~= "table" or type(Drone.UseBattery) ~= "function" then
        return false, "Drone.UseBattery unavailable"
    end
    if type(rawget(_G, "Modifier")) ~= "table" or type(rawget(_G, "SessionRandom")) ~= "table" then
        return false, "Modifier or SessionRandom unavailable"
    end
    return true
end

local function on(flag)
    return F.Config[flag] == true and F.State.features.vehicles == true
end

local function city()
    local map = F.State.map
    return map and map.City
end

local function labels(name)
    local c = city()
    return c and c.labels[name] or {}
end

-- Percent slowdown from rain, proportional to intensity and capped.
function V.RainSlowdown(rain_mm_h, percent_at_reference, max_percent)
    if rain_mm_h <= 0 then return 0 end
    local slow = percent_at_reference * rain_mm_h * 1.0 / F.Config.RAIN_REFERENCE_MM_H
    return math.floor(math.min(max_percent, slow) + 0.5)
end

-- RCHarvester sets its own harvesting speed (RCHarvester.lua:164); a modifier change
-- there would overwrite it, so harvesters keep their speed.
local function ground_rover(rover)
    return IsValid(rover) and IsKindOf(rover, "BaseRover") and rover:IsValidPos()
end

local function update_rovers(hours)
    local cfg = F.Config
    local slow_on, breakdown_on = on("ENABLE_ROVER_SLOWDOWN"), on("ENABLE_ROVER_BREAKDOWN")
    if not slow_on and not breakdown_on then return end
    local slowed = 0
    for _, rover in ipairs(labels("Rover")) do
        if ground_rover(rover) then
            local depth, concentration = F.Water.DepthAt(rover:GetPos():xy())
            if slow_on and not IsKindOf(rover, "RCHarvester") then
                local deep = depth >= cfg.ROVER_SLOW_DEPTH_MM
                rover:SetModifier("move_speed", ROVER_MODIFIER, 0, deep and -cfg.ROVER_SLOW_PERCENT or 0)
                if deep then slowed = slowed + 1 end
            end
            -- Toxic water corrodes exposed electronics faster.
            if breakdown_on and depth >= cfg.ROVER_FORD_DEPTH_MM then
                submerged[rover] = (submerged[rover] or 0) + hours * (1 + concentration)
            end
        end
    end
    if slowed ~= F.State.slowed_rovers then
        F.State.slowed_rovers = slowed
        F.Log("Vehicles", "rovers in deep water changed", { slowed = slowed,
            depth_mm = cfg.ROVER_SLOW_DEPTH_MM, percent = -cfg.ROVER_SLOW_PERCENT })
    end
end

local function update_drones(hours, rain_mm_h)
    if not on("ENABLE_DRONE_EFFECTS") then return end
    local cfg, s = F.Config, F.State
    local percent = V.RainSlowdown(rain_mm_h, cfg.DRONE_RAIN_SLOW_PERCENT, cfg.DRONE_RAIN_SLOW_MAX_PERCENT)
    if percent ~= (s.drone_rain_percent or 0) then
        local c = city()
        if c then
            c:SetLabelModifier("Drone", DRONE_RAIN_MODIFIER, percent > 0 and Modifier:new{
                prop = "move_speed", percent = -percent, amount = 0, id = DRONE_RAIN_MODIFIER } or nil)
            s.drone_rain_percent = percent
            F.Log("Vehicles", "drone rain slowdown changed", { percent = -percent, rain_mm_h = rain_mm_h })
        end
    end
    -- Hovering ground drones short out in deep water; flying drones stay above it.
    for _, drone in ipairs(labels("Drone")) do
        if IsValid(drone) and IsKindOf(drone, "Drone") and not IsKindOf(drone, "FlyingDrone")
            and not drone:IsDead() and not drone:GetParent() and drone:IsValidPos() then
            if F.Water.DepthAt(drone:GetPos():xy()) >= cfg.DRONE_SHORT_DEPTH_MM then
                local drain = math.floor(drone.battery_max * cfg.DRONE_WATER_BATTERY_PER_HOUR * hours)
                if drain > 0 then drone:UseBattery(drain) end
            end
        end
    end
end

function V.Tick()
    local s = F.State
    local hours = F.Config.TICK_MS * 1.0 / const.HourDuration
    update_rovers(hours)
    update_drones(hours, s.last_nominal_rate or 0)
end

function V.Hourly(hours, rain_mm_h, toxic)
    local cfg = F.Config
    -- Rovers driven past fording depth: chance of an electrical breakdown.
    local broken = 0
    for rover, wet_hours in pairs(submerged) do
        if on("ENABLE_ROVER_BREAKDOWN") and IsValid(rover) and rover.command ~= "Malfunction" then
            local chance = 1 - (1 - cfg.ROVER_SUBMERGED_BREAKDOWN_PER_HOUR) ^ wet_hours
            if SessionRandom:Random(100) < math.floor(chance * 100 + 0.5) then
                rover:SetCommand("Malfunction"); broken = broken + 1
            end
        end
        submerged[rover] = nil
    end
    -- Toxic rain leaves corrosive grime on drones (dust washing is fl_dust.lua).
    local grimed = 0
    if toxic and rain_mm_h > 0 and on("ENABLE_DRONE_EFFECTS") then
        local intensity = hours * rain_mm_h * 1.0 / cfg.RAIN_REFERENCE_MM_H
        for _, drone in ipairs(labels("Drone")) do
            if IsValid(drone) and IsKindOf(drone, "Drone") and not drone:IsDead() then
                local grime = math.floor(drone:GetDustMax() * cfg.DRONE_TOXIC_GRIME_PER_HOUR * intensity)
                if grime > 0 then drone:AddDust(grime); grimed = grimed + 1 end
            end
        end
    end
    if cfg.DEBUG_EFFECTS == true then
        F.Log("Vehicles", "hourly pass", { rovers_broken = broken, drones_grimed = grimed,
            rain_mm_h = rain_mm_h, toxic = toxic })
    end
end

-- Remove every Flood speed modifier and pending exposure. Idempotent.
function V.Restore()
    local checked = 0
    for _, rover in ipairs(labels("Rover")) do
        if IsValid(rover) and IsKindOf(rover, "BaseRover") then
            rover:SetModifier("move_speed", ROVER_MODIFIER, 0, 0); checked = checked + 1
        end
    end
    local c = city()
    if c and (F.State.drone_rain_percent or 0) ~= 0 then c:SetLabelModifier("Drone", DRONE_RAIN_MODIFIER, nil) end
    F.State.drone_rain_percent, F.State.slowed_rovers = 0, 0
    for rover in pairs(submerged) do submerged[rover] = nil end
    F.Log("Vehicles", "vehicle modifiers removed", { rovers_checked = checked })
end

-- Before a save: drop speed modifiers; the next tick reapplies them.
V.PreSave = V.Restore
