-- Shuttles. Vanilla rain has no effect on them.
-- Rain cuts visibility and adds drag and icing: shuttles fly slower, in proportion to
-- intensity. CargoShuttle move_speed is modifiable and reaches flights in the air
-- (FlyingObject:OnModifiableValueChanged, Flight.lua:870). Shuttle objects are created
-- per sortie, so the slowdown is a city "CargoShuttle" label modifier, which
-- LabelContainer applies to newly added shuttles too.
-- A severe storm grounds them: hubs are suspended exactly as dust storms do
-- (const.DustStormSuspendBuildings includes ShuttleHub, DustStorm.lua:592-605);
-- airborne shuttles finish their task and return home (CargoShuttle:Idle).
local F = Flood
local SH = {}
F.Shuttles = SH
local MODIFIER = "FloodRainShuttles"
local REASON = "FloodStormGrounded"

NotWorkingWarning[REASON] = { sort_key = 161,
    text = Untranslated("Grounded: the storm is too heavy for shuttles to fly."),
    short = Untranslated("Storm grounded") }

function SH.Available()
    if type(rawget(_G, "Modifier")) ~= "table" then return false, "Modifier unavailable" end
    if not g_Classes.CargoShuttle or not g_Classes.ShuttleHubBase then return false, "shuttle classes unavailable" end
    return true
end

local function active()
    return F.Config.ENABLE_SHUTTLE_EFFECTS == true and F.State.features.shuttles == true
end

local function hubs()
    local city = F.State.map and F.State.map.City
    return city and city.labels.ShuttleHub or {}
end

local function set_slowdown(percent)
    local s = F.State
    local city = s.map and s.map.City
    if not city or percent == (s.shuttle_rain_percent or 0) then return end
    city:SetLabelModifier("CargoShuttle", MODIFIER, percent > 0 and Modifier:new{
        prop = "move_speed", percent = -percent, amount = 0, id = MODIFIER } or nil)
    s.shuttle_rain_percent = percent
    F.Log("Shuttles", "rain slowdown changed", { percent = -percent })
end

local function set_grounded(grounded)
    local changed = 0
    for _, hub in ipairs(hubs()) do
        if IsValid(hub) and not hub.destroyed then
            if grounded and not hub.suspended then
                hub:SetSuspended(true, REASON); changed = changed + 1
            elseif not grounded and hub.suspended == REASON then
                hub:SetSuspended(false, REASON); changed = changed + 1
            end
        end
    end
    if changed > 0 then F.Log("Shuttles", grounded and "hubs grounded by storm" or "hubs cleared to fly", { hubs = changed }) end
end

function SH.Tick()
    if not active() then return end
    local cfg = F.Config
    local rain = F.State.last_nominal_rate or 0
    set_slowdown(F.Vehicles.RainSlowdown(rain, cfg.SHUTTLE_RAIN_SLOW_PERCENT, cfg.SHUTTLE_RAIN_SLOW_MAX_PERCENT))
    -- Re-checked every tick so hubs built during a storm are grounded too.
    set_grounded(rain >= cfg.SHUTTLE_GROUND_RAIN_MM_H)
end

-- Before a save: drop the label modifier and lift storm groundings, so a save
-- loaded after Flood is removed has no hub grounded for good. Both come back
-- right after the save (groundings) or on the next tick.
local regrounded = false

function SH.PreSave()
    set_slowdown(0)
    regrounded = false
    for _, hub in ipairs(hubs()) do
        if IsValid(hub) and hub.suspended == REASON then regrounded = true end
    end
    set_grounded(false)
end

function SH.PostSave()
    if regrounded then set_grounded(true) end
    regrounded = false
end

-- Remove the slowdown and lift storm groundings. Idempotent.
function SH.Restore()
    set_slowdown(0)
    set_grounded(false)
end
